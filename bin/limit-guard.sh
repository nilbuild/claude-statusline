#!/bin/bash
# PreToolUse guard: once the 5-hour usage reaches 95% or the weekly usage
# reaches 99%, every tool call is denied with instructions to stop and
# schedule a resume one minute after the reset.
#
# Source: the usage cache shared with the status line, refreshed here through
# ~/.claude/usage-refresh.sh when it is over a minute old. A cache older than
# max_age, or a window whose reset has already passed, never blocks: stale
# data must not lock the session out.
#
# Thresholds: "limit_5h" and "limit_week" in ~/.claude/statusline.json
# (95 and 99 by default); set them with /limits.
# Off: "limit_guard": false in ~/.claude/statusline.json (on by default),
# or, as an emergency switch, touch /tmp/claude/limit-guard-off
# Lower priority: a session where the user ran /low-priority in the current
# 5-hour window is not blocked. The transcript is the only place that records
# it; only the success lines count as switched on. When a
# session is blocked, the user is also told once per reset window that
# /low-priority can keep it going.

cache="/tmp/claude/statusline-usage-cache.json"
max_age=600
five_limit=95
seven_limit=99

input=$(cat)
[ -f /tmp/claude/limit-guard-off ] && exit 0

config="$HOME/.claude/statusline.json"
if [ -f "$config" ]; then
    {
        read -r cfg_guard
        read -r cfg_five
        read -r cfg_seven
    } < <(jq -r '
        (if .limit_guard == false then "off" else "on" end),
        (.limit_5h // "" | if type == "number" and . >= 1 and . <= 100 then floor else "" end),
        (.limit_week // "" | if type == "number" and . >= 1 and . <= 100 then floor else "" end)
    ' "$config" 2>/dev/null)
    [ "$cfg_guard" = "off" ] && exit 0
    case "$cfg_five" in ''|*[!0-9]*) : ;; *) five_limit=$cfg_five ;; esac
    case "$cfg_seven" in ''|*[!0-9]*) : ;; *) seven_limit=$cfg_seven ;; esac
fi

tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
# The tools needed to carry out the instruction itself stay allowed.
# ToolSearch among them: CronCreate may be a deferred tool whose schema has
# to be loaded before it can be called.
case "$tool" in
    ToolSearch|CronCreate|CronList|CronDelete|TaskStop|ScheduleWakeup|AskUserQuestion) exit 0 ;;
esac

# Bring the cache up to date before judging it. Left to the status line, it
# is refreshed only on renders, so the reading can be about 90s old; asked
# here, it is at most a minute old. The same lock and 429 backoff apply, so
# the endpoint still sees at most one request a minute.
[ -f "$HOME/.claude/usage-refresh.sh" ] && . "$HOME/.claude/usage-refresh.sh" >/dev/null 2>&1
[ -f "$cache" ] || exit 0

now=$(date +%s)
mtime=$(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null)
case "$mtime" in ''|*[!0-9]*) exit 0 ;; esac
[ $(( now - mtime )) -gt "$max_age" ] && exit 0

# One line per window over its limit: "<name> <pct> <reset epoch>".
over=$(jq -r --argjson now "$now" --argjson f "$five_limit" --argjson s "$seven_limit" '
    def epoch: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
    [["5h", .five_hour, $f], ["weekly", .seven_day, $s]][]
    | select((.[1] | type) == "object" and (.[1].resets_at | type) == "string")
    | (.[1].resets_at | epoch) as $r
    | select($r > $now and (.[1].utilization // 0) >= .[2])
    | "\(.[0]) \(.[1].utilization | round) \($r)"
' "$cache" 2>/dev/null)
[ -n "$over" ] || exit 0

# Resume after the latest reset among the exceeded windows.
latest=0; summary=""
while read -r name pct reset; do
    [ "$reset" -gt "$latest" ] && latest=$reset
    summary+="${summary:+, }$name ${pct}% (reset $(date -d "@$reset" '+%d.%m %H:%M'))"
done <<< "$over"
# At least a minute after the reset, rounded up to a whole minute: cron has
# minute resolution, and rounding down can land on the reset itself. A
# one-shot CronCreate job on :00 or :30 may fire up to 90s early (seen here:
# reset 02:29:59, job "30 2" fired at 02:28:34 and hit the limit), so those
# two minutes are skipped.
resume=$(( (latest + 60 + 59) / 60 * 60 ))
case "$(date -d "@$resume" '+%M')" in 00|30) resume=$(( resume + 60 )) ;; esac
resume_hm=$(date -d "@$resume" '+%d.%m %H:%M')
cron_expr=$(date -d "@$resume" '+%-M %-H %-d %-m *')

reason="USAGE LIMIT GUARD: $summary. Stop all work now.
- If you are a subagent: do nothing else, end immediately and report that you stopped on the usage limit guard.
- If you are the main session: stop running agents (TaskStop), then call CronCreate with cron \"$cron_expr\" (local time $resume_hm, one minute after the reset) and a prompt that resumes the interrupted task from where it stopped. Then tell the user, in Russian, that work is paused until $resume_hm and why. Make no other tool calls."

# One line per guarded call, to see afterwards which sessions and agents ran
# into the guard and when: local time, mode, levels, session, agent, cwd, tool.
guard_log="$HOME/.claude/limit-guard.log"
log_guard() {
printf '%s\n' "$input" | jq -r --arg t "$(date '+%F %T')" --arg m "$1" --arg s "$summary" --arg r "$resume_hm" '
    [$t, $m, $s, "resume " + $r, "session=" + (.session_id // "?"),
     "agent=" + (.agent_type // .agent_id // "main"), "cwd=" + (.cwd // "?"), "tool=" + (.tool_name // "?")]
    | join("\t")' >> "$guard_log" 2>/dev/null
if [ "$(wc -l < "$guard_log" 2>/dev/null)" -gt 5000 ] 2>/dev/null; then
    tail -n 2500 "$guard_log" > "$guard_log.$$" 2>/dev/null && mv -f "$guard_log.$$" "$guard_log"
fi
}

session=$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null | tr -dc 'A-Za-z0-9-')
marker_dir=/tmp/claude/limit-guard-low
mkdir -p "$marker_dir" 2>/dev/null

# /low-priority is a local command, so it shows up in the transcript as a
# system line with commandRun.command. Only a run since the current 5-hour
# window began counts: lower priority lasts until the reset. Only the last
# run matters, and only the two success lines count ("Continuing now at lower
# priority ..." and "Lower-priority mode is back on ..."): "isn't available",
# the spent-allowance and "taking a break" refusals, and "is off" after a
# stop all mean the mode is not running. Wording from the 2.1.269 binary,
# https://www.thinkfacility.com/errors/lower-priority-mode-isnt-available-right-now/
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null)
if [ -f "$transcript" ]; then
    window_start=$(jq -r --argjson now "$now" '
        def epoch: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
        if (.five_hour.resets_at | type) == "string" then (.five_hour.resets_at | epoch) - 18000 else $now - 18000 end
    ' "$cache" 2>/dev/null)
    case "$window_start" in ''|*[!0-9]*) window_start=$(( now - 18000 )) ;; esac
    lowprio=$(grep -F '"command":"low-priority"' "$transcript" 2>/dev/null | tail -n 1 | jq -r --argjson ws "$window_start" '
        select(.subtype == "local_command" and ((.content // "") | test("Continuing now at lower priority|Lower-priority mode is back on")))
        | (.timestamp // "" | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0)
        | select(. >= $ws)
    ' 2>/dev/null)
    if [ -n "$lowprio" ]; then
        marker="$marker_dir/${session:-unknown}-$latest-skip"
        [ -f "$marker" ] || { : > "$marker"; log_guard "lowprio-skip"; }
        exit 0
    fi
fi

# Tell the user once per session and reset window; hooks cannot run slash
# commands, so /low-priority stays the user's to type. Only the main agent
# gets it: a subagent's systemMessage never reaches the chat, yet it used up
# the marker. Subagent calls carry agent_id (agent_type alone is also set for
# a main session started with --agent). The reset time jitters by a second
# or two across refreshes (20:09:59 vs 20:10:00), so the marker key is the
# reset rounded to 5 minutes.
notice=""
is_sub=$(printf '%s' "$input" | jq -r 'if (.agent_id // "") != "" then 1 else "" end' 2>/dev/null)
marker="$marker_dir/${session:-unknown}-$(( (latest + 150) / 300 * 300 ))"
if [ -z "$is_sub" ] && [ ! -f "$marker" ]; then
    : > "$marker"
    notice="Лимит использования: $summary. Работа остановлена до $resume_hm. Можете попробовать продолжить сейчас через /low-priority (доступен не всем аккаунтам)."
fi

log_guard "deny"

jq -n --arg r "$reason" --arg m "$notice" '{
    hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
    }
} + (if $m == "" then {} else {systemMessage: $m} end)'
