#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ── Colors ──────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

# ── Helpers ─────────────────────────────────────────────
color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
    fi
}

build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar_color
    bar_color=$(color_for_pct "$pct")

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

format_epoch_time() {
    local epoch=$1
    local style=$2
    [ -z "$epoch" ] || [ "$epoch" = "null" ] || [ "$epoch" = "0" ] && return

    local result=""
    case "$style" in
        time)
            result=$(date -j -r "$epoch" +"%H:%M" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%H:%M" 2>/dev/null)
            result=$(echo "$result" | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        datetime)
            result=$(date -j -r "$epoch" +"%b %-d, %H:%M" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d, %H:%M" 2>/dev/null)
            result=$(echo "$result" | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        *)
            result=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d" 2>/dev/null)
            result=$(echo "$result" | tr '[:upper:]' '[:lower:]')
            ;;
    esac
    printf "%s" "$result"
}

iso_to_epoch() {
    local iso_str="$1"

    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(env TZ=UTC date -d "${stripped/T/ }" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(date -d "${stripped/T/ }" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

skill_names_file="/tmp/claude/statusline-skill-names.txt"
skill_names_max_age=300
skill_names=""

# Index every installed skill and plugin command name. Layouts vary (plain
# skills, plugin skills under cache/<plugin>/<version>/, external_plugins, and
# command-style skills defined as commands/<name>.md), so index by discovery
# rather than by hardcoded paths. Cached because it costs a filesystem walk.
load_skill_names() {
    local age=999999 mtime now
    if [ -f "$skill_names_file" ]; then
        mtime=$(stat -c %Y "$skill_names_file" 2>/dev/null || stat -f %m "$skill_names_file" 2>/dev/null)
        if [ -n "$mtime" ]; then
            now=$(date +%s)
            age=$(( now - mtime ))
        fi
    fi
    if [ "$age" -lt "$skill_names_max_age" ]; then
        skill_names=$(<"$skill_names_file")
        return 0
    fi

    {
        find "$HOME/.claude/skills" "$cwd/.claude/skills" -maxdepth 2 -name "SKILL.md" 2>/dev/null
        find "$HOME/.claude/commands" "$cwd/.claude/commands" -maxdepth 2 -name "*.md" 2>/dev/null
        find "$HOME/.claude/plugins" -maxdepth 8 \
             \( -name "SKILL.md" -o -path "*/commands/*.md" \) 2>/dev/null
    } | sed 's|/SKILL\.md$||; s|\.md$||; s|.*/||' | sort -u > "$skill_names_file" 2>/dev/null
    skill_names=$(<"$skill_names_file")
}

# Keep first-invocation order, drop duplicates, and cap the list so a very
# long session cannot grow the cache without bound.
remember_skill() {
    local n="$1" count
    [ -n "$n" ] || return 0
    case ",$skills_seen," in *",$n,"*) return 0 ;; esac
    if [ -z "$skills_seen" ]; then
        skills_seen="$n"
    else
        skills_seen="$skills_seen,$n"
    fi
    count=${skills_seen//[!,]/}
    if [ ${#count} -ge 40 ]; then
        skills_seen="${skills_seen#*,}"
    fi
}

skill_exists() {
    local n="${1##*:}"
    [ -n "$n" ] || return 1
    case $'\n'"$skill_names"$'\n' in
        *$'\n'"$n"$'\n'*) return 0 ;;
    esac
    return 1
}

# ── Extract JSON data ───────────────────────────────────
# One jq pass for everything on stdin. The script reruns on every assistant
# message, and each extra process costs more than the parsing itself. Fields
# come out one per line, in the same order they are read below — keep the two
# lists in sync. `// ""` rather than `// empty`, so a missing field still
# emits its line and the rest do not shift up.
{
    read -r model_name
    read -r size
    read -r current
    read -r effort
    read -r cwd
    read -r transcript
    read -r session_id
    read -r session_start
    read -r stdin_five_pct
    read -r stdin_five_reset
    read -r stdin_seven_pct
    read -r stdin_seven_reset
} < <(echo "$input" | jq -r '
    (.model.display_name // "Claude"),
    (.context_window.context_window_size // 200000),
    ((.context_window.current_usage.input_tokens // 0)
     + (.context_window.current_usage.cache_creation_input_tokens // 0)
     + (.context_window.current_usage.cache_read_input_tokens // 0)),
    (.effort.level // ""),
    (.cwd // ""),
    (.transcript_path // ""),
    (.session_id // ""),
    (.session.start_time // ""),
    (.rate_limits.five_hour.used_percentage // "" | if . == "" then "" else round end),
    (.rate_limits.five_hour.resets_at // "" | if type == "number" then floor else "" end),
    (.rate_limits.seven_day.used_percentage // "" | if . == "" then "" else round end),
    (.rate_limits.seven_day.resets_at // "" | if type == "number" then floor else "" end)
' 2>/dev/null)

[ -n "$model_name" ] || model_name="Claude"
case "$size" in ''|*[!0-9]*) size=200000 ;; esac
[ "$size" -eq 0 ] && size=200000

pct_used=$(( current * 100 / size ))

# ── LINE 1: Model │ Context % │ Directory (branch) │ Session │ Effort │ Skill ──
pct_color=$(color_for_pct "$pct_used")
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

# ── Current skills (from transcript, incremental) ───────
# Off unless asked for, so upgrading changes nobody's status line. Both
# shapes are accepted: {"skills": true} and the {"blocks": [... "skills"]}
# form used by mpiton/claude-statusline, so a config written for either works.
skills_enabled=false
skills_limit=3
# refresh_interval: seconds between timed reruns of this script (1-3600).
# Claude Code reads it from statusLine.refreshInterval in settings.json, so
# it is copied there when set here and different.
cfg_refresh=""
skills_config="$HOME/.claude/statusline.json"
if [ -f "$skills_config" ]; then
    {
        read -r cfg_skills
        read -r cfg_limit
        read -r cfg_refresh
    } < <(jq -r '
        (((.skills // false) == true) or ((.blocks // []) | index("skills") != null) | tostring),
        (.skills_limit // 3 | if type == "number" and . >= 1 and . <= 10 then floor else 3 end),
        (.refresh_interval // "" | if type == "number" and . >= 1 and . <= 3600 then floor else "" end)
    ' "$skills_config" 2>/dev/null)
    [ "$cfg_skills" = "true" ] && skills_enabled=true
    case "$cfg_limit" in ''|*[!0-9]*) : ;; *) skills_limit=$cfg_limit ;; esac
fi

settings_file="$HOME/.claude/settings.json"
case "$cfg_refresh" in
    ''|*[!0-9]*) : ;;
    *)
        if [ -f "$settings_file" ] && [ ! -L "$settings_file" ]; then
            current_refresh=$(jq -r '.statusLine.refreshInterval // ""' "$settings_file" 2>/dev/null)
            if [ "$current_refresh" != "$cfg_refresh" ] \
                && jq -e '.statusLine | type == "object"' "$settings_file" >/dev/null 2>&1; then
                # Written whole and renamed: a partial settings.json would
                # disable every setting in it.
                jq --argjson r "$cfg_refresh" '.statusLine.refreshInterval = $r' \
                    "$settings_file" > "$settings_file.statusline.$$" 2>/dev/null \
                    && [ -s "$settings_file.statusline.$$" ] \
                    && mv -f "$settings_file.statusline.$$" "$settings_file"
                rm -f "$settings_file.statusline.$$" 2>/dev/null
            fi
        fi
        ;;
esac

skills_seen=""
skill_names_loaded=false

# Only the bytes appended since the last render are read, so the cost does
# not grow with the session. The cache holds that byte offset and the names
# found so far. awk does the byte accounting and pre-filters, since transcript
# lines run to 100KB+ and bash pattern matching over all of them costs more
# than the whole rest of the script.
if $skills_enabled && [ -n "$transcript" ] && [ -f "$transcript" ]; then
    mkdir -p /tmp/claude 2>/dev/null
    skills_cache="/tmp/claude/skills-${session_id:-unknown}"
    skills_offset=0

    if [ -f "$skills_cache" ] && [ ! -L "$skills_cache" ]; then
        IFS=$'\t' read -r cached_offset skills_seen < "$skills_cache"
        case "$cached_offset" in ''|*[!0-9]*) cached_offset=0 ;; esac
        skills_offset=$cached_offset
    fi

    skills_size=$(stat -c %s "$transcript" 2>/dev/null || stat -f %z "$transcript" 2>/dev/null)
    case "$skills_size" in ''|*[!0-9]*) skills_size=0 ;; esac

    # Transcript replaced or truncated: what the offset pointed at is gone.
    if [ "$skills_size" -lt "$skills_offset" ]; then
        skills_offset=0
        skills_seen=""
    fi

    if [ "$skills_size" -gt "$skills_offset" ]; then
        while IFS= read -r scanned; do
            case "$scanned" in
                B*)
                    skills_offset=$(( skills_offset + ${scanned#B} ))
                    ;;
                L*)
                    line=${scanned#L}
                    case "$line" in
                        *'"name":"Skill"'*)
                            # jq rather than a regex over the raw line: the
                            # extraction must not depend on JSON key order.
                            while IFS= read -r found_skill; do
                                remember_skill "$found_skill"
                            done < <(printf '%s' "$line" | jq -r '
                                select(.isSidechain != true)
                                | .message.content[]?
                                | select(.type == "tool_use" and .name == "Skill")
                                | .input.skill // empty' 2>/dev/null)
                            ;;
                    esac
                    case "$line" in
                        *'"content":"<command-name>/'*)
                            if ! $skill_names_loaded; then
                                load_skill_names
                                skill_names_loaded=true
                            fi
                            found_skill="${line#*'"content":"<command-name>/'}"
                            found_skill="${found_skill%%<*}"
                            if [ -n "$found_skill" ] && skill_exists "$found_skill"; then
                                remember_skill "$found_skill"
                            fi
                            ;;
                    esac
                    ;;
            esac
        done < <(tail -c "+$(( skills_offset + 1 ))" "$transcript" 2>/dev/null \
            | awk -v chunk="$(( skills_size - skills_offset ))" '
                function flush() { if (pending != "") { print pending; pending = "" } }
                {
                    # Flushing the previous record here keeps the final one
                    # pending until END, where we know whether it was complete.
                    flush()
                    lastlen = length($0) + 1
                    total += lastlen
                    if ($0 ~ /"name":"Skill"/ || $0 ~ /"content":"<command-name>\//) pending = "L" $0
                }
                END {
                    # A trailing newline the last record never had shows up as
                    # total overshooting the chunk: that record is half-written,
                    # so neither its matches nor its bytes are consumed.
                    if (total <= chunk) {
                        flush()
                        print "B" total
                    } else {
                        print "B" (total - lastlen)
                    }
                }
            ')

        if [ ! -L "$skills_cache" ]; then
            printf '%s\t%s\n' "$skills_offset" "$skills_seen" > "$skills_cache" 2>/dev/null
        fi
    fi
fi

git_branch=""
git_dirty=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
        git_dirty="*"
    fi
fi

session_duration=""
if [ -n "$session_start" ] && [ "$session_start" != "null" ]; then
    start_epoch=$(iso_to_epoch "$session_start")
    if [ -n "$start_epoch" ]; then
        now_epoch=$(date +%s)
        elapsed=$(( now_epoch - start_epoch ))
        if [ "$elapsed" -ge 3600 ]; then
            session_duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
        elif [ "$elapsed" -ge 60 ]; then
            session_duration="$(( elapsed / 60 ))m"
        else
            session_duration="${elapsed}s"
        fi
    fi
fi

skip_perms=""
parent_cmd=$(ps -o args= -p "$PPID" 2>/dev/null)
if [[ "$parent_cmd" == *"--dangerously-skip-permissions"* ]]; then
    skip_perms="⚡  "
fi

line1="${blue}${model_name}${reset}"
line1+="${sep}"
line1+="✎ ${pct_color}${pct_used}%${reset}"
line1+="${sep}"
line1+="${skip_perms}${cyan}${dirname}${reset}"
if [ -n "$git_branch" ]; then
    line1+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
fi
if [ -n "$session_duration" ]; then
    line1+="${sep}"
    line1+="${dim}⏱ ${reset}${white}${session_duration}${reset}"
fi
if [ -n "$effort" ]; then
    line1+="${sep}"
    case "$effort" in
        max|xhigh|high) line1+="${magenta}● ${effort}${reset}" ;;
        medium)         line1+="${dim}◑ ${effort}${reset}" ;;
        low)            line1+="${dim}◔ ${effort}${reset}" ;;
        *)              line1+="${dim}◑ ${effort}${reset}" ;;
    esac
fi
if [ -n "$skills_seen" ]; then
    IFS=',' read -r -a skills_list <<< "$skills_seen"
    skills_total=${#skills_list[@]}
    skills_from=0
    [ "$skills_total" -gt "$skills_limit" ] && skills_from=$(( skills_total - skills_limit ))

    skills_disp=""
    for (( i = skills_from; i < skills_total; i++ )); do
        [ -n "$skills_disp" ] && skills_disp+=","
        skills_disp+="${skills_list[i]}"
    done
    [ "$skills_from" -gt 0 ] && skills_disp+=" ${dim}+${skills_from}${reset}${orange}"

    line1+="${sep}"
    line1+="${orange}✦ ${skills_disp}${reset}"
fi

# ── Usage API (cached) ─────────────────────────────────
usage_data=""
extra_enabled="false"
now=$(date +%s)
# Installed next to this script; without it only stdin's readings are shown.
[ -f "$HOME/.claude/usage-refresh.sh" ] && . "$HOME/.claude/usage-refresh.sh"

api_five_pct=""; api_five_reset=""; api_seven_pct=""; api_seven_reset=""
if parse_usage_data "$usage_data"; then
    api_five_pct="$u_five_pct"
    api_five_reset=$(iso_to_epoch "$u_five_reset_iso")
    api_seven_pct="$u_seven_pct"
    api_seven_reset=$(iso_to_epoch "$u_seven_reset_iso")
    extra_enabled="$u_extra_enabled"
fi

# Two readings of one window, one from stdin and one from the API. A reading
# whose window has already reset is dropped. Of two readings of the same
# window the higher one wins, since usage only grows until the reset. If they
# belong to different windows, the later one is the current window.
pick_window() {
    local a_pct=$1 a_reset=$2 b_pct=$3 b_reset=$4 slack=600
    case "$a_reset" in ''|*[!0-9]*) a_reset=0 ;; esac
    case "$b_reset" in ''|*[!0-9]*) b_reset=0 ;; esac
    case "$a_pct" in ''|*[!0-9]*) a_pct="" ;; esac
    case "$b_pct" in ''|*[!0-9]*) b_pct="" ;; esac
    local expired=false
    [ -n "$a_pct" ] && [ "$a_reset" -gt 0 ] && [ "$a_reset" -le "$now" ] && { a_pct=""; expired=true; }
    [ -n "$b_pct" ] && [ "$b_reset" -gt 0 ] && [ "$b_reset" -le "$now" ] && { b_pct=""; expired=true; }

    win_pct="$a_pct"; win_reset="$a_reset"
    if [ -n "$b_pct" ]; then
        if [ -z "$a_pct" ] || [ "$b_reset" -gt $(( a_reset + slack )) ]; then
            win_pct="$b_pct"; win_reset="$b_reset"
        elif [ "$a_reset" -le $(( b_reset + slack )) ] && [ "$b_pct" -gt "$a_pct" ]; then
            win_pct="$b_pct"
        fi
        [ "$win_reset" -gt 0 ] || win_reset="$b_reset"
    fi
    [ "$win_reset" -gt 0 ] || win_reset=""
    # Every reading is from a window that has since reset. Claude Code drops
    # the window from stdin at that moment and the cache can lag by up to
    # cache_max_age, but a window that has reset has nothing used in it yet.
    if [ -z "$win_pct" ] && $expired; then
        win_pct=0; win_reset=""
    fi
}

pick_window "$stdin_five_pct" "$stdin_five_reset" "$api_five_pct" "$api_five_reset"
five_hour_pct="$win_pct"; five_hour_reset_epoch="$win_reset"
pick_window "$stdin_seven_pct" "$stdin_seven_reset" "$api_seven_pct" "$api_seven_reset"
seven_day_pct="$win_pct"; seven_day_reset_epoch="$win_reset"

# ── Rate limit lines ────────────────────────────────────
rate_lines=""
bar_width=10

if [ -n "$five_hour_pct" ]; then
    five_hour_reset=$(format_epoch_time "$five_hour_reset_epoch" "time")
    five_hour_bar=$(build_bar "$five_hour_pct" "$bar_width")
    five_hour_pct_color=$(color_for_pct "$five_hour_pct")
    five_hour_pct_fmt=$(printf "%3d" "$five_hour_pct")

    rate_lines+="${white}current${reset} ${five_hour_bar} ${five_hour_pct_color}${five_hour_pct_fmt}%${reset}"
    [ -n "$five_hour_reset" ] && rate_lines+=" ${dim}⟳${reset} ${white}${five_hour_reset}${reset}"
fi

if [ -n "$seven_day_pct" ]; then
    seven_day_reset=$(format_epoch_time "$seven_day_reset_epoch" "datetime")
    seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width")
    seven_day_pct_color=$(color_for_pct "$seven_day_pct")
    seven_day_pct_fmt=$(printf "%3d" "$seven_day_pct")

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}weekly${reset}  ${seven_day_bar} ${seven_day_pct_color}${seven_day_pct_fmt}%${reset}"
    [ -n "$seven_day_reset" ] && rate_lines+=" ${dim}⟳${reset} ${white}${seven_day_reset}${reset}"
fi

if [ "$extra_enabled" = "true" ] && [ -n "$usage_data" ]; then
    extra_pct="$u_extra_pct"
    printf -v extra_used '%d.%02d' "$(( u_extra_used / 100 ))" "$(( u_extra_used % 100 ))"
    printf -v extra_limit '%d.%02d' "$(( u_extra_limit / 100 ))" "$(( u_extra_limit % 100 ))"
    extra_bar=$(build_bar "$extra_pct" "$bar_width")
    extra_pct_color=$(color_for_pct "$extra_pct")

    extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [ -z "$extra_reset" ]; then
        extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    fi

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}extra${reset}   ${extra_bar} ${extra_pct_color}\$${extra_used}${dim}/${reset}${white}\$${extra_limit}${reset} ${dim}⟳${reset} ${white}${extra_reset}${reset}"
fi

# ── Output ──────────────────────────────────────────────
printf "%b" "$line1"
[ -n "$rate_lines" ] && printf "\n\n%b" "$rate_lines"

exit 0
