# claude-statusline

Configure your Claude Code statusline to show limits, directory, git info, reasoning effort and the skills a session has used

![demo](./.github/demo.png)

## Install

Run the command below to set it up

```bash
npx @kamranahmedse/claude-statusline
```

It backups your old status line if any and copies the status line script to `~/.claude/statusline.sh` and configures your Claude Code settings.

The settings entry includes `"refreshInterval": 30`. Claude Code reruns the
script on its own only when the main session has news, so without a timer the
limits stand still while the session waits on subagents. The limits come from
the usage endpoint as well as from Claude Code, since the endpoint counts
every session and subagent on the account. It is asked at most once a minute,
shared by all sessions: asked more often, it answers 429, and after a 429 no
session asks again until its `Retry-After` has passed. Failed requests are
logged to `~/.claude/statusline-usage-errors.log`.

## Usage limit guard

The installer also adds a `PreToolUse` hook, `~/.claude/hooks/limit-guard.sh`.
Once the 5-hour usage reaches 95% or the weekly usage reaches 99%, it denies
every tool call, in the main session and in subagents, and tells Claude to
stop its agents, schedule a `CronCreate` job for one minute after the reset
and tell you when work resumes. The resume time skips `:00` and `:30`, where
one-shot jobs may fire up to 90 seconds early. Denied calls are logged to
`~/.claude/limit-guard.log`.

If you run `/low-priority` and Claude Code confirms it ("Continuing now at
lower priority ..." or "Lower-priority mode is back on ..."), the guard stops
blocking that session until the 5-hour reset. Hooks cannot run slash commands,
so the first blocked call in the main session of each reset window shows you
a message suggesting it. The mode is a server-side rollout and is not offered
to every account; "Lower-priority mode isn't available right now." means it
was not offered, not that it ran out. `ToolSearch` is never blocked, so Claude
can load `CronCreate` when it is a deferred tool.

The guard reads the same usage cache and refreshes it itself when it is more
than a minute old, so its reading is never older than that. A reading that is
over ten minutes old, or whose window has already reset, never blocks.

`/limits` shows the settings and the current usage, and changes them:

```
/limits                      show settings and usage
/limits refresh 30           status line timer, 1-3600 s
/limits guard on|off         turn the guard on or off
/limits 5h 95 week 99        guard thresholds, 1-100 %
```

They live in `~/.claude/statusline.json` as `refresh_interval`,
`limit_guard`, `limit_5h` and `limit_week`. `refresh_interval` is copied to
`statusLine.refreshInterval` in `settings.json`, which is where Claude Code
reads it. `"usage_log": true` also appends every usage reading to
`~/.claude/usage-trend.tsv`, a line a minute, to study how fast the limits
fill; it is off by default.

## Skills block

Off unless you ask for it, so upgrading does not change your status line.
Create `~/.claude/statusline.json`:

```json
{
  "skills": true,
  "skills_limit": 3
}
```

```
Opus │ ✎ 25% │ my-repo (main) │ ● xhigh │ ✦ code-review,artifact-design,dataviz +2
```

`skills_limit` is how many names are shown, 1 to 10, 3 by default; the rest
become the `+N`. The `{"blocks": [..., "skills"]}` form used by
[mpiton/claude-statusline](https://github.com/mpiton/claude-statusline) is
accepted too, so a config written for either works.

Claude Code sends no skill list on stdin, so the names come from the session
transcript: a `Skill` tool call, or a slash command whose name matches an
installed skill or plugin command. That makes it skills the session invoked,
in the order it first invoked them, not skills available to it. Invocations
inside a subagent are not counted. Only the bytes appended since the last
render are read, so the block costs the same however long the session runs.

## Requirements

- [jq](https://jqlang.github.io/jq/) — for parsing JSON
- curl — for fetching rate limit data
- git — for branch info

On macOS:

```bash
brew install jq
```

## Uninstall

```bash
npx @kamranahmedse/claude-statusline --uninstall
```

If you had a previous statusline, it restores it from the backup. Otherwise it removes the script and cleans up your settings.

## License

MIT
