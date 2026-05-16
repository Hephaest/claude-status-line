#!/usr/bin/env bash
# claude-status-line — main status line for Claude Code.
#
# Implements the official statusLine contract:
#   https://code.claude.com/docs/en/statusline
#
# Output (one or two lines, depending on terminal width vs WRAP_AT):
#   🌿 branch | model | effort | ▓░ bar PCT% | 5h: NN% 7d: NN% | BAT: NN% CPU NN% RAM NN% | 💰 $X.XX | ⏱️ Xh Ym
# When the combined visible width exceeds WRAP_AT, the second half (BAT/CPU/RAM | $ | duration)
# is emitted on its own row.
#
# Requires: bash 4+, jq, git, macOS (top, vm_stat, pmset, sysctl).
#
# JSON contract on stdin (full schema at the URL above):
#   .model.display_name
#   .thinking.enabled, .effort.level
#   .context_window.used_percentage
#   .rate_limits.{five_hour,seven_day}.used_percentage
#   .cost.{total_cost_usd,total_duration_ms}
#   .workspace.current_dir
#
# System samples (top / vm_stat / pmset) are cached for CACHE_MAX_AGE seconds
# in CACHE_FILE; freshness is determined by the file's mtime, per:
#   https://code.claude.com/docs/en/statusline#cache-expensive-operations

set -o pipefail
shopt -s extglob   # for *(…) inside visible_width's ANSI-strip pattern

# --- Constants ---
BRANCH_GLYPH='🌿'
COST_GLYPH='💰'
DURATION_GLYPH='⏱️'
BAR_WIDTH=10
CACHE_FILE="$HOME/.claude/.statusline-cache"
CACHE_MAX_AGE=5   # seconds
WRAP_AT=80        # split the status line into two rows once visible width exceeds this

DIM=$'\033[38;5;245m'
YEL=$'\033[33m'
RED=$'\033[31m'
GRN=$'\033[32m'
RST=$'\033[0m'

# --- Mode ---
# desktop = single line, no BAT/CPU/RAM. Skips system sampling for speed.
# server  = full layout with BAT/CPU/RAM, wraps when wide. (default)
MODE="${1:-server}"
[[ "$MODE" != "desktop" && "$MODE" != "server" ]] && MODE="server"

# --- Colour helpers ---

threshold_forward() {
  local v="${1:-0}" warn="$2" crit="$3"
  v="${v%.*}"
  if   (( v > crit )); then printf '%s' "$RED"
  elif (( v > warn )); then printf '%s' "$YEL"
  else                      printf '%s' "$DIM"
  fi
}

battery_color() {
  local pct="$1" state="$2"
  if [[ "$state" == "charging" || "$state" == "charged" ]]; then
    printf '%s' "$GRN"
    return
  fi
  local v="${pct%.*}"
  if   (( v < 15 )); then printf '%s' "$RED"
  elif (( v < 30 )); then printf '%s' "$YEL"
  else                    printf '%s' "$DIM"
  fi
}

format_duration() {
  local s="$1"
  (( s < 0 )) && s=0
  if   (( s < 60 ));   then printf '%ds'      "$s"
  elif (( s < 3600 )); then printf '%dm %ds'  "$((s/60))"   "$((s%60))"
  else                       printf '%dh %dm' "$((s/3600))" "$(((s%3600)/60))"
  fi
}

visible_width() {
  # Strip CSI escape sequences, then count code points with `wc -m`. *([0-9;])
  # requires extglob: plain bash globs would treat [0-9;]* as "one digit/; then
  # any chars" — so * would greedily eat everything between the first ESC and
  # the last `m`, returning 0. *(…) bounds the match to the bracket class.
  local stripped="${1//$'\033'\[*([0-9;])m/}"
  printf '%s' "$stripped" | wc -m | tr -d ' '
}

# --- System samplers ---

sample_cpu() {
  local idle
  idle=$(top -l 1 -n 0 2>/dev/null | awk '/CPU usage/ { gsub("%",""); print $7; exit }')
  [[ -z "$idle" ]] && { echo 0; return; }
  awk -v i="$idle" 'BEGIN{ v = 100 - i; if (v < 0) v = 0; printf "%d", v }'
}

sample_ram() {
  local total page_size stats free inactive
  total=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  (( total == 0 )) && { echo 0; return; }
  stats=$(vm_stat 2>/dev/null) || { echo 0; return; }
  page_size=$(awk '/page size of/ { print $8 }' <<<"$stats")
  [[ -z "$page_size" ]] && page_size=4096
  free=$(awk     '/Pages free:/     { gsub("[^0-9]",""); print; exit }' <<<"$stats")
  inactive=$(awk '/Pages inactive:/ { gsub("[^0-9]",""); print; exit }' <<<"$stats")
  awk -v t="$total" -v p="$page_size" -v f="${free:-0}" -v i="${inactive:-0}" \
    'BEGIN{ used = t - (f + i) * p; if (used < 0) used = 0; printf "%d", used * 100 / t }'
}

sample_battery() {
  local out pct state
  out=$(pmset -g batt 2>/dev/null)
  if [[ -z "$out" ]] || ! grep -q "InternalBattery" <<<"$out"; then
    echo "0|none"
    return
  fi
  pct=$(grep -Eo '[0-9]+%' <<<"$out" | head -1 | tr -d '%')
  if grep -q "AC Power" <<<"$out"; then
    if grep -q "charged" <<<"$out"; then state=charged
    else                                  state=charging
    fi
  else
    state=discharging
  fi
  echo "${pct:-0}|${state}"
}

# --- Cache (system stats only; mtime-based freshness per docs) ---

cache_is_stale() {
  [[ ! -f "$CACHE_FILE" ]] && return 0
  local now mtime
  now=$(date +%s)
  # BSD `stat -f %m` falls back to GNU `stat -c %Y`
  mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
  (( now - mtime > CACHE_MAX_AGE ))
}

refresh_cache() {
  local cpu ram bat bat_state tmp
  cpu=$(sample_cpu)
  ram=$(sample_ram)
  IFS='|' read -r bat bat_state <<<"$(sample_battery)"
  tmp=$(mktemp "${CACHE_FILE}.XXXXXX") || return 0
  printf '%s|%s|%s|%s\n' "$cpu" "$ram" "$bat" "$bat_state" >"$tmp"
  mv "$tmp" "$CACHE_FILE" || rm -f "$tmp"
}

# --- jq guard ---

if ! command -v jq >/dev/null; then
  printf 'install jq: brew install jq\n'
  exit 0
fi

# --- Read JSON: one jq pass, one field per line, sequential reads ---
# Newline-separated output is more robust than @tsv: bash collapses consecutive
# tabs (an IFS whitespace) and would eat empty fields, but newline reads cleanly
# preserve empties.

input=$(cat)
{
  read -r MODEL_NAME
  read -r THN
  read -r EFF
  read -r CTX_USED
  read -r RL5
  read -r RL7
  read -r COST
  read -r DURATION_MS
  read -r CWD
} <<<"$(
  jq -r '
    .model.display_name                     // "",
    .thinking.enabled                       // false,
    .effort.level                           // "",
    (.context_window.used_percentage        // 0 | floor),
    .rate_limits.five_hour.used_percentage  // "",
    .rate_limits.seven_day.used_percentage  // "",
    .cost.total_cost_usd                    // 0,
    .cost.total_duration_ms                 // 0,
    .workspace.current_dir                  // "."
  ' <<<"$input"
)"

# display_name ships the full friendly label (e.g. "Opus 4.7 (1M context)").
# Tighten "(1M context)" → "(1M)" so the segment stays compact.
MODEL_LABEL="${MODEL_NAME// context)/)}"

# --- Branch (live, uncached: ~10 ms) ---

BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)

# --- System stats (cached; server mode only) ---

if [[ "$MODE" == "server" ]]; then
  cache_is_stale && refresh_cache
  IFS='|' read -r CPU RAM BAT BAT_STATE < "$CACHE_FILE"
fi

# --- Context bar (10 chars, threshold-coloured fill) ---

filled=$(( CTX_USED * BAR_WIDTH / 100 ))
empty=$(( BAR_WIDTH - filled ))
printf -v fill_str "%${filled}s"
printf -v pad_str  "%${empty}s"
ctx_bar="${fill_str// /▓}${pad_str// /░}"
if   (( CTX_USED >= 90 )); then ctx_bar_color=$RED
elif (( CTX_USED >= 70 )); then ctx_bar_color=$YEL
else                            ctx_bar_color=$GRN
fi

# --- Cost & duration (live from JSON) ---

cost_fmt=$(printf '%.2f' "$COST")
duration_sec=$(( DURATION_MS / 1000 ))

# --- Rate-limit segment (omit if both fields absent) ---

rate_parts=()
if [[ -n "$RL5" ]]; then
  rate_parts+=( "$(threshold_forward "$RL5" 70 90)5h: $(printf '%.0f' "$RL5")%${RST}" )
fi
if [[ -n "$RL7" ]]; then
  rate_parts+=( "$(threshold_forward "$RL7" 70 90)7d: $(printf '%.0f' "$RL7")%${RST}" )
fi
rate_segment="${rate_parts[*]}"   # space-joined; empty when no parts

# --- System-stats segment (BAT optional; CPU & RAM always; server mode only) ---

sys_segment=""
if [[ "$MODE" == "server" ]]; then
  bat_color=$(battery_color "$BAT" "$BAT_STATE")
  cpu_color=$(threshold_forward "$CPU" 70 90)
  ram_color=$(threshold_forward "$RAM" 75 90)
  [[ "$BAT_STATE" != "none" ]] && sys_segment="${bat_color}BAT: ${BAT}%${RST} "
  sys_segment="${sys_segment}${cpu_color}CPU ${CPU}%${RST} ${ram_color}RAM ${RAM}%${RST}"
fi

# --- Assemble: two halves, joined as one row when narrow, two rows when wide ---
# Half 1: identity + load (branch, effort, context, rate limits).
# Half 2: resources + spend (system stats, cost, duration).

SEP="${DIM} | ${RST}"

line1=""
[[ -n "$BRANCH" ]]                  && line1="${DIM}${BRANCH_GLYPH} ${BRANCH}${RST}"
[[ -n "$MODEL_LABEL" ]]             && line1="${line1:+${line1}${SEP}}${DIM}${MODEL_LABEL}${RST}"
[[ "$THN" == "true" && -n "$EFF" ]] && line1="${line1:+${line1}${SEP}}${DIM}${EFF}${RST}"
line1="${line1:+${line1}${SEP}}${ctx_bar_color}${ctx_bar}${RST} ${DIM}${CTX_USED}%${RST}"
[[ -n "$rate_segment" ]]            && line1="${line1}${SEP}${rate_segment}"

line2="${sys_segment:+${sys_segment}${SEP}}${DIM}${COST_GLYPH} \$${cost_fmt}${RST}"
line2="${line2}${SEP}${DIM}${DURATION_GLYPH} $(format_duration "$duration_sec")${RST}"

combined="${line1}${SEP}${line2}"
if [[ "$MODE" == "desktop" ]] || (( $(visible_width "$combined") <= WRAP_AT )); then
  printf '%s\n' "$combined"
else
  printf '%s\n%s\n' "$line1" "$line2"
fi
