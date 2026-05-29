#!/usr/bin/env bash
# catalog.sh — /memory-health catalog wrapper.
# Builds the 3-axis knowledge catalog (MD files + board guides/task-logs + config
# hierarchy) into ${CLAUDE_MEMORY_DIR}/catalog/. Read-only except those outputs.
#
# Exit: 0 = built (possibly with coverage gaps), 1 = setup error (env unset).

set -euo pipefail

# --- CLAUDE_MEMORY_DIR resolution — graceful, no path guessing (Layer 3 pattern) ---
if [ -z "${CLAUDE_MEMORY_DIR:-}" ]; then
  echo "❌ CLAUDE_MEMORY_DIR is not set — cannot build catalog." >&2
  echo "   Set it via one of:" >&2
  echo "     1. ~/.claude/settings.json → \"env\": { \"CLAUDE_MEMORY_DIR\": \"<abs-path>\" }" >&2
  echo "     2. ~/.zshrc                → export CLAUDE_MEMORY_DIR=\"<abs-path>\"" >&2
  echo "     3. run the skill install.sh (auto-detects and persists it)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- coverage pre-check: warn on unmounted roots (no silent truncation) ---
for root in "$HOME/.claude" "$HOME/workspace" "/Volumes/L'Atelier de Claude/workspace"; do
  if [ ! -d "$root" ]; then
    echo "⚠ [catalog] root not available (will be skipped): $root" >&2
  fi
done

# --- bulletin board reachability note (non-fatal) ---
# Live DB matches the board server: DB_PATH env || ~/Library/Application Support/...
BB="${BB_HOME:-$HOME/workspace/bulletin-board}"
LIVE_DB="${DB_PATH:-$HOME/Library/Application Support/bulletin-board/bulletin.db}"
if [ ! -f "$LIVE_DB" ] && [ ! -f "$BB/data/bulletin.db" ] && [ ! -f "$BB/database.db" ]; then
  echo "⚠ [catalog] bulletin board DB not found (live: $LIVE_DB) — board axis will be skipped" >&2
fi

# build (capture stdout for audit; stderr flows through for warnings)
set +e
OUT=$(python3 "${SCRIPT_DIR}/build-catalog.py" "$@")
RC=$?
set -e
printf '%s\n' "$OUT"

# F6 audit log on success (best-effort — never blocks the build result)
if [ "$RC" -eq 0 ]; then
  MDN=$(printf '%s' "$OUT" | sed -n 's/.*MD files: \([0-9]*\).*/\1/p' | head -1)
  bash "${SCRIPT_DIR}/memory-health-log.sh" "F6" "catalog build" "-" "${MDN:-?} MD files indexed" 2>/dev/null || true
fi
exit "$RC"
