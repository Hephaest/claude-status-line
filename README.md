# claude-status-line

A richer status line for [Claude Code](https://code.claude.com/) — branch, context window, rate limits, system health, cost, and elapsed time, all on one line. Plus a per-subagent panel that shows what each running subagent is doing, how many tokens it has spent, and how long it has been alive.

---

## Disclaimer

This project was vibe-coded with Claude Code. The implementation has been reviewed for clean-code practices and is in active personal use, but it has not been battle-tested across every edge case or hardware configuration. Read the scripts before running them — they are short and self-contained — and use at your own discretion.

There is no warranty.

---

## Why you need this

When I work on a remote machine, I want to glance at one place and know:

- How close am I to filling the context window?
- How much of my 5-hour and 7-day rate limit have I burned?
- Is the box hot, low on memory, or about to die on battery?
- What are my subagents doing right now, and how much have they cost me?
- How much have I spent this session, and how long has it been running?

Claude Code's default status line answers some of these. This one answers all of them, in a single line you don't have to look hard at.

---

## What you get

### Main status line

A single line, color-coded by severity, refreshed every render:

```
[branch] main | high | ▓▓▓▓░░░░░░ 38% | 5h: 22% 7d: 14% | BAT: 84% CPU 12% RAM 41% | $ 0.27 | 1m 42s
```

Segments, in order:

| Segment      | Source                          | Notes                                                    |
| ------------ | ------------------------------- | -------------------------------------------------------- |
| Branch       | `git -C $cwd branch --show-current` | Omitted when not in a git repo                       |
| Effort       | `.effort.level` (only when thinking is enabled) | low / medium / high                      |
| Context bar  | `.context_window.used_percentage` | 10-char block: green < 70%, yellow >= 70%, red >= 90%  |
| Rate limits  | `.rate_limits.{five_hour,seven_day}.used_percentage` | Hidden when both are absent       |
| BAT/CPU/RAM  | `pmset`, `top`, `vm_stat`         | Battery hidden on desktops; thresholds turn yellow/red |
| Cost         | `.cost.total_cost_usd`            | Formatted to 2 decimals                                |
| Duration     | `.cost.total_duration_ms`         | `Nm Ss` (or `Hh Mm` for very long sessions)            |

### Subagent status line

One row per running subagent in the agent panel:

```
code-explorer | Tracing auth flow across services | 24k tokens | 2m 14s
code-reviewer | Reviewing PR diff for security    | 8k tokens  | 31s
```

Claude Code prepends its own status indicator before each row, so the script no longer renders one. The description is truncated to fit your terminal width and the cost columns stay aligned.

---

## Requirements

- macOS (uses `top -l`, `vm_stat`, `pmset`, `sysctl hw.memsize`)
- bash 4 or newer
- [`jq`](https://stedolan.github.io/jq/) — install with `brew install jq`
- `git` (already on macOS)
- Claude Code with `statusLine` and `subagentStatusLine` support

---

## Installation

### Quick install

```bash
git clone https://github.com/Hephaest/claude-status-line.git
cd claude-status-line
./install.sh
```

### Manual install

If you don't want to run the installer:

```bash
mkdir -p ~/.claude
cp bin/statusline.sh           ~/.claude/statusline.sh
cp bin/subagent-statusline.sh  ~/.claude/subagent-statusline.sh
chmod +x ~/.claude/statusline.sh ~/.claude/subagent-statusline.sh
```

---

## Setup

Update your `~/.claude/settings.json`.

The keys you need to add:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 2
  },
  "subagentStatusLine": {
    "type": "command",
    "command": "~/.claude/subagent-statusline.sh"
  }
}
```

Restart Claude Code. The new status line should appear at the bottom of the window, and any subagent you spawn will use the per-row format described above.

---

## Features

- Single-line, color-coded output with green / yellow / red thresholds
- Five-second cache for system samples (`top` / `vm_stat` / `pmset`) so the bar stays cheap to render
- Resilient JSON parsing — missing fields default sensibly, no crashes
- Subagent description truncates to fit the terminal's reported `.columns`
- Rate-limit segment auto-hides when Claude Code does not provide the fields
- Battery segment auto-hides on hardware without a battery
- Single `jq` invocation per render — no per-field shell loops
- Zero runtime dependencies beyond `jq`, `bash`, `git`, and macOS coreutils

---

## Customization

All the constants you might want to tweak live at the top of each script.

In [`bin/statusline.sh`](bin/statusline.sh):

| Constant         | Default       | What it does                                    |
| ---------------- | ------------- | ----------------------------------------------- |
| `BAR_WIDTH`      | `10`          | Width of the context-window block               |
| `CACHE_MAX_AGE`  | `5`           | Seconds before system samples are refreshed     |
| `BRANCH_GLYPH`   | leaf emoji    | Replace with whatever glyph you prefer          |
| `COST_GLYPH`     | money emoji   | Same                                            |
| `DURATION_GLYPH` | clock emoji   | Same                                            |
| `DIM`/`YEL`/`RED`/`GRN` | ANSI codes | Adjust the palette                          |

Color thresholds are inline in the relevant functions:

- Context bar — `>= 90` red, `>= 70` yellow, otherwise green (`statusline.sh`, look for `CTX_USED >= 90`)
- Rate limits — `> 90` red, `> 70` yellow (`threshold_forward 70 90`)
- CPU — `> 90` red, `> 70` yellow
- RAM — `> 90` red, `> 75` yellow
- Battery — `< 15%` red, `< 30%` yellow, otherwise dim; green when charging

In [`bin/subagent-statusline.sh`](bin/subagent-statusline.sh):

| Constant            | Default | What it does                                       |
| ------------------- | ------- | -------------------------------------------------- |
| `MIN_DESC_BUDGET`   | `10`    | Minimum chars reserved for the description column  |
| Token color cutoffs | 50k / 200k | Yellow / red thresholds in `token_color`        |
| Duration cutoffs    | 5m / 15m | Yellow / red thresholds in `duration_color`       |

After editing, no rebuild is needed — Claude Code re-runs the script on every render.

---

## FAQ

### Why is the status line blank?

`jq` is probably missing. Install it (`brew install jq`) and restart Claude Code. Also confirm the scripts are executable: `ls -l ~/.claude/statusline.sh`. The scripts exit cleanly when `jq` is absent, which is why a missing dependency shows up as no output rather than an error.

### Why do CPU and RAM show zero?

You're on Linux, or `top` / `vm_stat` / `sysctl` are not in the `PATH` that Claude Code spawns the script with. Every other segment still renders normally — only the system-stats segment depends on those tools.

### What does `stat: illegal option -- f` mean?

You're on Linux. The cache freshness check tries BSD `stat -f %m` first and falls back to GNU `stat -c %Y`. If neither works, the cache is treated as stale on every render — annoying, but not broken.

### My `settings.json` already has a `statusLine` entry. What now?

The installer never touches `settings.json`. If a different status line is already configured, replace its `command` value by hand with the snippet from [`examples/settings.json`](examples/settings.json).

### How do I uninstall?

Remove the two symlinks:

```bash
rm ~/.claude/statusline.sh ~/.claude/subagent-statusline.sh
```

The `statusLine` and `subagentStatusLine` keys in `settings.json` are left for you to remove by hand.

---

## Contributing

PRs are welcome. To keep this small and predictable:

- Keep the scripts macOS-tested. If you add Linux support, make it additive and gate it on `uname`.
- No new runtime dependencies. `jq` is already a stretch; please don't add a Python or Node dep.
- Run [`shellcheck`](https://www.shellcheck.net/) on anything you change. Aim for zero warnings.
- Match the existing code style: constants at the top, short focused functions, prefer `awk` over chains of `grep | cut | sed`, comment intent rather than mechanics.
- Update this README when you add or rename a constant.

For larger changes (new segments, schema additions), open an issue first so we can talk through the design.
