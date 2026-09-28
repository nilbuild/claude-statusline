#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const os = require("os");

const CLAUDE_DIR = path.join(os.homedir(), ".claude");
const SETTINGS_FILE = path.join(CLAUDE_DIR, "settings.json");
const STATUSLINE_DEST = path.join(CLAUDE_DIR, "statusline.sh");
const STATUSLINE_SRC = path.resolve(__dirname, "statusline.sh");

// Installed alongside the status line: the shared usage refresh, the guard
// hook that stops tool calls near the usage limits, and the /limits skill
// that changes their settings.
const EXTRA_FILES = [
  { src: "usage-refresh.sh", dest: path.join(CLAUDE_DIR, "usage-refresh.sh") },
  { src: "limit-guard.sh", dest: path.join(CLAUDE_DIR, "hooks", "limit-guard.sh") },
  { src: "limits.sh", dest: path.join(CLAUDE_DIR, "skills", "limits", "limits.sh") },
];
const SKILL_DIR = path.join(CLAUDE_DIR, "skills", "limits");
const SKILL_FILE = path.join(SKILL_DIR, "SKILL.md");
const GUARD_COMMAND = 'bash "$HOME/.claude/hooks/limit-guard.sh"';

// allowed-tools is matched against the literal command, so the skill names
// the script by its absolute path rather than through $HOME.
function skillText() {
  const script = path.join(SKILL_DIR, "limits.sh");
  return `---
name: limits
description: Show or change the status line refresh interval and the usage-limit guard (on/off, 5h and weekly thresholds)
disable-model-invocation: true
argument-hint: "[refresh <sec>] [guard on|off] [5h <pct>] [week <pct>]"
allowed-tools: Bash(bash ${script}) Bash(bash ${script} *)
---

!\`bash ${script} $ARGUMENTS 2>&1\`

Report the output above to the user in two or three short lines. If it starts with "error:", say what was wrong and show the usage: \`/limits [refresh <sec>] [guard on|off] [5h <pct>] [week <pct>]\`. Run no tools.
`;
}

function isGuardEntry(entry) {
  return (entry.hooks || []).some(
    (h) => typeof h.command === "string" && h.command.includes("limit-guard.sh")
  );
}

const blue = "\x1b[38;2;0;153;255m";
const green = "\x1b[38;2;0;175;80m";
const red = "\x1b[38;2;255;85;85m";
const yellow = "\x1b[38;2;230;200;0m";
const dim = "\x1b[2m";
const reset = "\x1b[0m";

function log(msg) {
  console.log(`  ${msg}`);
}

function success(msg) {
  console.log(`  ${green}✓${reset} ${msg}`);
}

function warn(msg) {
  console.log(`  ${yellow}!${reset} ${msg}`);
}

function fail(msg) {
  console.error(`  ${red}✗${reset} ${msg}`);
}

function checkDeps() {
  const { execSync } = require("child_process");
  const missing = [];

  try {
    execSync("which jq", { stdio: "ignore" });
  } catch {
    missing.push("jq");
  }

  try {
    execSync("which curl", { stdio: "ignore" });
  } catch {
    missing.push("curl");
  }

  try {
    execSync("which git", { stdio: "ignore" });
  } catch {
    missing.push("git");
  }

  return missing;
}

function uninstall() {
  console.log();
  console.log(`  ${blue}Claude Line Uninstaller${reset}`);
  console.log(`  ${dim}───────────────────────${reset}`);
  console.log();

  const backup = STATUSLINE_DEST + ".bak";

  if (fs.existsSync(backup)) {
    fs.copyFileSync(backup, STATUSLINE_DEST);
    fs.unlinkSync(backup);
    success(`Restored previous statusline from ${dim}statusline.sh.bak${reset}`);
  } else if (fs.existsSync(STATUSLINE_DEST)) {
    fs.unlinkSync(STATUSLINE_DEST);
    success(`Removed ${dim}statusline.sh${reset}`);
  } else {
    warn("No statusline found — nothing to remove");
  }

  for (const f of EXTRA_FILES) {
    if (fs.existsSync(f.dest)) fs.unlinkSync(f.dest);
  }
  if (fs.existsSync(SKILL_FILE)) fs.unlinkSync(SKILL_FILE);
  try {
    fs.rmdirSync(SKILL_DIR);
  } catch {}
  success("Removed the usage refresh, the limit guard and the /limits skill");

  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      const settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf-8"));
      let changed = false;
      if (settings.statusLine) {
        delete settings.statusLine;
        changed = true;
      }
      const pre = settings.hooks && settings.hooks.PreToolUse;
      if (Array.isArray(pre) && pre.some(isGuardEntry)) {
        settings.hooks.PreToolUse = pre.filter((e) => !isGuardEntry(e));
        if (settings.hooks.PreToolUse.length === 0) delete settings.hooks.PreToolUse;
        if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
        changed = true;
      }
      if (changed) {
        fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2) + "\n");
        success(`Removed statusLine and the limit guard hook from ${dim}settings.json${reset}`);
      } else {
        success("Settings already clean");
      }
    } catch {
      fail(`Could not parse ${SETTINGS_FILE} — fix it manually`);
      process.exit(1);
    }
  }

  console.log();
  log(`${green}Done!${reset} Restart Claude Code to apply changes.`);
  console.log();
}

function run() {
  if (process.argv.includes("--uninstall")) {
    uninstall();
    return;
  }

  console.log();
  console.log(`  ${blue}Claude Line Installer${reset}`);
  console.log(`  ${dim}─────────────────────${reset}`);
  console.log();

  const missing = checkDeps();
  if (missing.length > 0) {
    fail(`Missing required dependencies: ${missing.join(", ")}`);
    log(`  Install them and try again.`);
    if (missing.includes("jq")) {
      log(`  ${dim}brew install jq${reset}`);
    }
    process.exit(1);
  }
  success("Dependencies found (jq, curl, git)");

  if (!fs.existsSync(CLAUDE_DIR)) {
    fs.mkdirSync(CLAUDE_DIR, { recursive: true });
    success(`Created ${CLAUDE_DIR}`);
  }

  const backup = STATUSLINE_DEST + ".bak";
  if (fs.existsSync(STATUSLINE_DEST)) {
    fs.copyFileSync(STATUSLINE_DEST, backup);
    warn(`Backed up existing statusline to ${dim}statusline.sh.bak${reset}`);
  }

  fs.copyFileSync(STATUSLINE_SRC, STATUSLINE_DEST);
  fs.chmodSync(STATUSLINE_DEST, 0o755);
  success(`Installed statusline to ${dim}${STATUSLINE_DEST}${reset}`);

  for (const f of EXTRA_FILES) {
    fs.mkdirSync(path.dirname(f.dest), { recursive: true });
    fs.copyFileSync(path.resolve(__dirname, f.src), f.dest);
    fs.chmodSync(f.dest, 0o755);
  }
  fs.writeFileSync(SKILL_FILE, skillText());
  success(`Installed the usage refresh, the limit guard and the ${dim}/limits${reset} skill`);

  let settings = {};
  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf-8"));
    } catch {
      fail(`Could not parse ${SETTINGS_FILE} — fix it manually`);
      process.exit(1);
    }
  }

  // refreshInterval keeps the rate limits moving while the main session is
  // idle, e.g. while it waits on subagents; events alone stop firing then.
  const statusLineConfig = {
    type: "command",
    command: 'bash "$HOME/.claude/statusline.sh"',
    refreshInterval: 30,
  };

  const current = settings.statusLine || {};
  const sameCommand =
    current.type === "command" && current.command === statusLineConfig.command;

  let changed = false;
  if (!(sameCommand && current.refreshInterval !== undefined)) {
    // An existing entry for this script keeps its other fields (padding and
    // the like); only the missing refreshInterval is added.
    settings.statusLine = sameCommand
      ? { ...current, refreshInterval: statusLineConfig.refreshInterval }
      : statusLineConfig;
    changed = true;
  }

  // The guard runs before every tool call, in the main session and in
  // subagents. It is added once, next to any PreToolUse hooks already there.
  settings.hooks = settings.hooks || {};
  settings.hooks.PreToolUse = settings.hooks.PreToolUse || [];
  if (!settings.hooks.PreToolUse.some(isGuardEntry)) {
    settings.hooks.PreToolUse.push({
      matcher: "*",
      hooks: [{ type: "command", command: GUARD_COMMAND, timeout: 10 }],
    });
    changed = true;
  }

  if (changed) {
    fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2) + "\n");
    success(`Updated ${dim}settings.json${reset} with statusLine and the limit guard hook`);
  } else {
    success("Settings already configured");
  }

  console.log();
  log(`${green}Done!${reset} Restart Claude Code to see your new status line.`);
  console.log();
}

run();
