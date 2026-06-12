#!/bin/bash
set -euo pipefail

# Only run in remote (Claude Code on the web) sessions.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

REPO_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# Build the TUI binary if missing (fast, cached across sessions once built).
TUI_BIN="$REPO_DIR/tui/.bin/myra-tui"
if [ ! -f "$TUI_BIN" ]; then
  mkdir -p "$REPO_DIR/tui/.bin"
  (cd "$REPO_DIR/tui" && go build -o .bin/myra-tui .) 2>/dev/null || true
fi

# Run bootstrap idempotently in cloud mode (no-tui: no TTY in hook).
# gh is optional here — the proxy handles git auth.
# --no-pull avoids redundant fetches when repos are already fresh.
CLAUDE_CODE_REMOTE=true "$REPO_DIR/bootstrap.sh" --no-pull --no-tui 2>&1 | tail -20

# Refresh the greppable code index so agents can locate symbols without scanning.
"$REPO_DIR/index.sh" --quiet 2>/dev/null || true
