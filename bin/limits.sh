#!/bin/bash
# Show or change the status line refresh and the usage-limit guard settings
# kept in ~/.claude/statusline.json.
#
#   limits.sh                 show settings and current usage
#   limits.sh refresh <sec>   status line timer, 1-3600 (copied to settings.json)
#   limits.sh guard on|off    usage-limit guard
#   limits.sh 5h <pct>        guard threshold for the 5-hour window, 1-100
#   limits.sh week <pct>      guard threshold for the weekly window, 1-100
#
# Several changes can go in one call: limits.sh 5h 85 week 95

config="$HOME/.claude/statusline.json"
settings="$HOME/.claude/settings.json"
cache="/tmp/claude/statusline-usage-cache.json"

die() { echo "error: $*" >&2; exit 1; }

number_in() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

# Written whole and renamed: a half-written settings file disables every
# setting in it.
write_json() {
    local file=$1 filter=$2; shift 2
    jq "$@" "$filter" "$file" > "$file.limits.$$" 2>/dev/null \
        && [ -s "$file.limits.$$" ] \
        && mv -f "$file.limits.$$" "$file" \
        || { rm -f "$file.limits.$$"; die "could not write $file"; }
}

[ -f "$config" ] || echo '{}' > "$config"
jq empty "$config" 2>/dev/null || die "$config is not valid JSON"

while [ $# -gt 0 ]; do
    key=$1; value=$2
    case "$key" in
        refresh)
            number_in "$value" 1 3600 || die "refresh takes seconds, 1-3600"
            write_json "$config" '.refresh_interval = $v' --argjson v "$value"
            if [ -f "$settings" ] && jq -e '.statusLine | type == "object"' "$settings" >/dev/null 2>&1; then
                write_json "$settings" '.statusLine.refreshInterval = $v' --argjson v "$value"
            fi
            ;;
        guard)
            case "$value" in
                on) write_json "$config" '.limit_guard = true' ;;
                off) write_json "$config" '.limit_guard = false' ;;
                *) die "guard takes on or off" ;;
            esac
            ;;
        5h)
            number_in "$value" 1 100 || die "5h takes a percentage, 1-100"
            write_json "$config" '.limit_5h = $v' --argjson v "$value"
            ;;
        week)
            number_in "$value" 1 100 || die "week takes a percentage, 1-100"
            write_json "$config" '.limit_week = $v' --argjson v "$value"
            ;;
        *) die "unknown setting '$key' (refresh, guard, 5h, week)" ;;
    esac
    shift 2
done

jq -r '
    "refresh:    \(.refresh_interval // 30)s",
    "guard:      \(if .limit_guard == false then "off" else "on" end)",
    "5h limit:   \(.limit_5h // 95)%",
    "week limit: \(.limit_week // 99)%"
' "$config"
if [ -f "$cache" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$cache") ))
    jq -r --arg age "$age" '
        "usage now: 5h \(.five_hour.utilization // "?")%, week \(.seven_day.utilization // "?")% (data \($age)s old)"
    ' "$cache" 2>/dev/null
fi
