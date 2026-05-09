#!/usr/bin/env bash
# claude-status-line — per-subagent row body for Claude Code's agent panel.
#
# Implements the official subagentStatusLine contract:
#   https://code.claude.com/docs/en/statusline#subagent-status-lines
#
# Per-task layout: <status-glyph> <name> | <description> | <N tokens> | <duration>
# Output: one JSON line per task -> {"id": "...", "content": "..."}
#
# Status glyphs (Unicode shapes, not emojis): ● ✓ ✗ ○
#
# Requires: bash 4+, jq.

set -o pipefail

# --- Constants ---
DIM=$'\033[38;5;245m'
CYN=$'\033[36m'
YEL=$'\033[33m'
RED=$'\033[31m'
GRN=$'\033[32m'
RST=$'\033[0m'

ELLIPSIS='…'
MIN_DESC_BUDGET=10

# --- jq guard ---
command -v jq >/dev/null || exit 0

# --- Helpers ---

status_glyph() {
  # Lower-case the status string for resilience against schema drift.
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$s" in
    running|in_progress)    printf '%s●%s' "$CYN" "$RST" ;;
    completed|done|success) printf '%s✓%s' "$GRN" "$RST" ;;
    failed|error)           printf '%s✗%s' "$RED" "$RST" ;;
    *)                      printf '%s○%s' "$DIM" "$RST" ;;
  esac
}

format_tokens() {
  local n="${1%.*}"
  if   (( n < 1000 ));    then printf '%d tokens'      "$n"
  elif (( n < 1000000 )); then awk -v n="$n" 'BEGIN { printf "%dk tokens",   n/1000 }'
  else                         awk -v n="$n" 'BEGIN { printf "%.1fM tokens", n/1000000 }'
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

token_color() {
  local n="${1%.*}"
  if   (( n > 200000 )); then printf '%s' "$RED"
  elif (( n > 50000 ));  then printf '%s' "$YEL"
  else                        printf '%s' "$DIM"
  fi
}

duration_color() {
  local s="$1"
  if   (( s > 900 )); then printf '%s' "$RED"
  elif (( s > 300 )); then printf '%s' "$YEL"
  else                     printf '%s' "$DIM"
  fi
}

truncate_str() {
  # Truncate $1 to at most $2 chars; append … if shortened.
  local str="$1" max="$2"
  if (( ${#str} > max )); then
    printf '%s%s' "${str:0:$((max-1))}" "$ELLIPSIS"
  else
    printf '%s' "$str"
  fi
}

# --- Read input ---
input=$(cat)
COLUMNS_AVAIL=$(jq -r '.columns // 100' <<<"$input")
NOW=$(date +%s)
SEP="${DIM} | ${RST}"

# --- Stream tasks: 6 fields per task on consecutive lines ---
# Single jq invocation extracts every needed field for every task.
jq -r '.tasks[] | (
    .id,
    .name,
    (.status      // ""),
    (.description // ""),
    (.tokenCount  // 0 | floor),
    (.startTime   // 0)
  )' <<<"$input" |
while IFS= read -r ID; do
  read -r NAME
  read -r STATUS
  read -r DESC
  read -r TOKENS
  read -r START

  # Normalize startTime to seconds (heuristic: > year 2286 in s ⇒ milliseconds).
  if (( START > 10000000000 )); then START=$((START / 1000)); fi
  if (( START > 0 )); then
    DURATION=$((NOW - START))
    (( DURATION < 0 )) && DURATION=0
  else
    DURATION=0
  fi

  glyph=$(status_glyph "$STATUS")
  tokens_fmt=$(format_tokens "$TOKENS")
  duration_fmt=$(format_duration "$DURATION")
  tok_color=$(token_color "$TOKENS")
  dur_color=$(duration_color "$DURATION")

  # Description budget = columns - (glyph 1 + space 1 + name + 3*sep len + tokens + duration)
  base=$(( 1 + 1 + ${#NAME} + 9 + ${#tokens_fmt} + ${#duration_fmt} ))
  budget=$(( COLUMNS_AVAIL - base ))
  (( budget < MIN_DESC_BUDGET )) && budget=$MIN_DESC_BUDGET
  desc_trunc=$(truncate_str "$DESC" "$budget")

  body="${glyph} ${DIM}${NAME}${RST}${SEP}${DIM}${desc_trunc}${RST}${SEP}${tok_color}${tokens_fmt}${RST}${SEP}${dur_color}${duration_fmt}${RST}"

  jq -cn --arg id "$ID" --arg content "$body" '{id: $id, content: $content}'
done
