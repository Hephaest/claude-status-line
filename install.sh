#!/usr/bin/env bash
# Symlink claude-status-line scripts into ~/.claude.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TARGET="$HOME/.claude"

mkdir -p "$TARGET"
ln -sf "$REPO_DIR/bin/statusline.sh"          "$TARGET/statusline.sh"
ln -sf "$REPO_DIR/bin/subagent-statusline.sh" "$TARGET/subagent-statusline.sh"

echo "Installed. Next: merge $REPO_DIR/examples/settings.json into $TARGET/settings.json, then restart Claude Code."
