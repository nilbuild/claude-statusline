#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const os = require("os");

const CLAUDE_DIR = path.join(os.homedir(), ".claude");
const SETTINGS_FILE = path.join(CLAUDE_DIR, "settings.json");
const STATUSLINE_DEST = path.join(CLAUDE_DIR, "statusline.sh");
const STATUSLINE_SRC = path.resolve(__dirname, "statusline.sh");

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

  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      const settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf-8"));
      if (settings.statusLine) {
        delete settings.statusLine;
        fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2) + "\n");
        success(`Removed statusLine from ${dim}settings.json${reset}`);
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

  if (sameCommand && current.refreshInterval !== undefined) {
    success("Settings already configured");
  } else {
    // An existing entry for this script keeps its other fields (padding and
    // the like); only the missing refreshInterval is added.
    settings.statusLine = sameCommand
      ? { ...current, refreshInterval: statusLineConfig.refreshInterval }
      : statusLineConfig;
    fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2) + "\n");
    success(`Updated ${dim}settings.json${reset} with statusLine config`);
  }

  console.log();
  log(`${green}Done!${reset} Restart Claude Code to see your new status line.`);
  console.log();
}

run();
