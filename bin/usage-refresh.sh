#!/bin/bash
# Shared by the status line and the usage-limit guard hook: brings the usage
# cache up to date and leaves the reading in $usage_data.
#
# Sourced, not run: it sets usage_data, extra_enabled, now and the u_*
# variables of parse_usage_data in the caller. Both callers see the same
# cache, lock and 429 backoff, so the endpoint is asked at most once a
# minute however many sessions, renders and tool calls there are.

# Same one-pass reasoning as the stdin read, for the usage API payload.
# Returns non-zero when the payload is absent or carries neither window, which
# also replaces the separate `jq -e` validity checks. A window that is present
# but null reads as 0% with no reset time: between a reset and the first use
# of the next window there is no window, and nothing has been used.
parse_usage_data() {
    u_ok=""; u_five_pct=""; u_five_reset_iso=""; u_seven_pct=""
    u_seven_reset_iso=""; u_extra_enabled="false"
    u_extra_pct=""; u_extra_used=""; u_extra_limit=""
    [ -n "$1" ] || return 1
    {
        read -r u_ok
        read -r u_five_pct
        read -r u_five_reset_iso
        read -r u_seven_pct
        read -r u_seven_reset_iso
        read -r u_extra_enabled
        read -r u_extra_pct
        read -r u_extra_used
        read -r u_extra_limit
    } < <(printf '%s' "$1" | jq -r '
        (if type == "object" and (has("five_hour") or has("seven_day"))
         then "ok" else "" end),
        (.five_hour.utilization // 0 | round),
        (.five_hour.resets_at // ""),
        (.seven_day.utilization // 0 | round),
        (.seven_day.resets_at // ""),
        (.extra_usage.is_enabled // false),
        (.extra_usage.utilization // 0 | round),
        (.extra_usage.used_credits // 0 | round),
        (.extra_usage.monthly_limit // 0 | round)
    ' 2>/dev/null)
    [ "$u_ok" = "ok" ]
}

# ── Usage API (cached) ─────────────────────────────────
# Queried even when stdin carries rate_limits. stdin is only as fresh as the
# main conversation's last API response, so it stands still while subagents
# or other sessions spend the same account. The endpoint reports the account
# as a whole. The cache is shared by every session, so the endpoint is asked
# at most once per cache_max_age however many sessions render.
cache_file="/tmp/claude/statusline-usage-cache.json"
# Queried more often than about once a minute, the endpoint answers 429.
cache_max_age=60

# Failed endpoint requests, one line each, trimmed to the last 500 lines once
# it passes 1000. The body is flattened and cut, and never holds the token.
usage_error_log="$HOME/.claude/statusline-usage-errors.log"
log_usage_error() {
    local msg=${1//$'\n'/ }
    printf '%s %s\n' "$(date '+%F %T')" "${msg:0:300}" >> "$usage_error_log" 2>/dev/null
    if [ "$(wc -l < "$usage_error_log" 2>/dev/null)" -gt 1000 ] 2>/dev/null; then
        tail -n 500 "$usage_error_log" > "$usage_error_log.$$" 2>/dev/null \
            && mv -f "$usage_error_log.$$" "$usage_error_log"
    fi
}

# With "usage_log": true in ~/.claude/statusline.json, every successful
# reading is appended as one tab-separated line: local time, 5h %, 5h reset,
# weekly %, weekly reset. Off by default, since it writes a line a minute.
# At that rate 30 days is about 43000 lines; past 50000 the oldest go.
usage_trend_log="$HOME/.claude/usage-trend.tsv"
log_usage_trend() {
    [ "$(jq -r '.usage_log == true' "$HOME/.claude/statusline.json" 2>/dev/null)" = "true" ] || return 0
    [ -f "$usage_trend_log" ] || printf 'time\tfive_hour\tfive_hour_reset\tseven_day\tseven_day_reset\n' > "$usage_trend_log" 2>/dev/null
    printf '%s\n' "$1" | jq -r --arg t "$(date '+%F %T')" '
        def fmt: if type == "string" then (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 | strflocaltime("%F %T")) else "" end;
        [$t, (.five_hour.utilization // ""), (.five_hour.resets_at | fmt),
         (.seven_day.utilization // ""), (.seven_day.resets_at | fmt)] | @tsv
    ' >> "$usage_trend_log" 2>/dev/null
    if [ "$(wc -l < "$usage_trend_log" 2>/dev/null)" -gt 50000 ] 2>/dev/null; then
        { head -n 1 "$usage_trend_log"; tail -n 43200 "$usage_trend_log"; } > "$usage_trend_log.$$" 2>/dev/null \
            && mv -f "$usage_trend_log.$$" "$usage_trend_log"
    fi
}

usage_data=""
extra_enabled="false"
now=$(date +%s)
needs_refresh=true

if [ -f "$cache_file" ]; then
    cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
    case "$cache_mtime" in ''|*[!0-9]*) cache_mtime=0 ;; esac
    if [ $(( now - cache_mtime )) -lt "$cache_max_age" ]; then
        needs_refresh=false
        usage_data=$(<"$cache_file")
    fi
fi

# Only one session refreshes at a time. Without this every session whose
# timer fires after the cache goes stale queries at once, and the endpoint
# answers the burst with 429. mkdir is atomic; a lock left behind by a
# render that was killed mid-request is ignored after 30s.
refresh_lock="/tmp/claude/statusline-usage-refresh.lock"
# After a 429 the endpoint names a wait in Retry-After; querying before it
# passes only earns another 429, so no session asks until then.
backoff_file="/tmp/claude/statusline-usage-backoff"
if $needs_refresh && [ -f "$backoff_file" ]; then
    backoff_until=$(<"$backoff_file")
    case "$backoff_until" in ''|*[!0-9]*) backoff_until=0 ;; esac
    if [ "$now" -lt "$backoff_until" ]; then
        needs_refresh=false
        [ -f "$cache_file" ] && usage_data=$(<"$cache_file")
    fi
fi
if $needs_refresh; then
    mkdir -p /tmp/claude 2>/dev/null
    if ! mkdir "$refresh_lock" 2>/dev/null; then
        lock_mtime=$(stat -c %Y "$refresh_lock" 2>/dev/null || stat -f %m "$refresh_lock" 2>/dev/null)
        case "$lock_mtime" in ''|*[!0-9]*) lock_mtime=$now ;; esac
        if [ $(( now - lock_mtime )) -lt 30 ]; then
            needs_refresh=false
            [ -f "$cache_file" ] && usage_data=$(<"$cache_file")
        else
            rm -rf "$refresh_lock" 2>/dev/null
            mkdir "$refresh_lock" 2>/dev/null || needs_refresh=false
        fi
    fi
fi

if $needs_refresh; then
    trap 'rmdir "$refresh_lock" 2>/dev/null' EXIT
    token=""
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        token="$CLAUDE_CODE_OAUTH_TOKEN"
    elif command -v security >/dev/null 2>&1; then
        blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
        fi
    fi
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        creds_file="${HOME}/.claude/.credentials.json"
        if [ -f "$creds_file" ]; then
            token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        fi
    fi
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        if command -v secret-tool >/dev/null 2>&1; then
            blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
            if [ -n "$blob" ]; then
                token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            fi
        fi
    fi

    if [ -z "$token" ] || [ "$token" = "null" ]; then
        log_usage_error "no OAuth token found"
    else
        # The status code rides on the last line so a failure can be logged
        # with it; curl prints 000 when no response arrived at all.
        headers_file="/tmp/claude/statusline-usage-headers.$$"
        response=$(curl -s --max-time 5 -w '\n%{http_code}' -D "$headers_file" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/2.1.34" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        curl_rc=$?
        retry_after=$(grep -i '^retry-after:' "$headers_file" 2>/dev/null | tr -dc '0-9')
        rm -f "$headers_file" 2>/dev/null
        http_code=${response##*$'\n'}
        response=${response%$'\n'*}
        [ "$http_code" = "$response" ] && response=""
        response_ok=false
        [ "$http_code" = "200" ] && parse_usage_data "$response" && response_ok=true
        $response_ok || log_usage_error "curl_rc=$curl_rc http=$http_code retry_after=${retry_after:-none} body=$response"
        if [ "$http_code" = "429" ]; then
            printf '%s\n' "$(( now + ${retry_after:-60} ))" > "$backoff_file" 2>/dev/null
        fi
        if $response_ok; then
            usage_data="$response"
            log_usage_trend "$response"
            # Written whole and renamed, so a session rendering at the same
            # moment never reads a half-written file.
            mkdir -p /tmp/claude 2>/dev/null
            printf '%s\n' "$response" > "$cache_file.$$" 2>/dev/null \
                && mv -f "$cache_file.$$" "$cache_file" 2>/dev/null
        elif [ -f "$cache_file" ]; then
            # A failed request is not retried on every render: each attempt
            # can hold the render for the whole --max-time. Marking the old
            # data fresh is safe, since it is only ever combined with stdin
            # by taking the higher reading of a window that has not reset.
            touch "$cache_file" 2>/dev/null
        fi
    fi
    if [ -z "$usage_data" ] && [ -f "$cache_file" ]; then
        usage_data=$(<"$cache_file")
    fi
    rmdir "$refresh_lock" 2>/dev/null
    trap - EXIT
fi

