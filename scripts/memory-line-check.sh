#!/usr/bin/env bash
# memory-line-check.sh — MEMORY.md line count monitoring hook
#
# Role: checks MEMORY.md line count at Claude Code session start and warns when over threshold
# Contract: see INTERFACES.md § memory-line-check.sh
#   - always exits 0 (warnings do not block the hook)
#   - must never modify files — output warnings only
#   - no output when line count is below 180
#
# Installation:
#   cp scripts/memory-line-check.sh ~/.claude/hooks/memory-line-check.sh
#   chmod +x ~/.claude/hooks/memory-line-check.sh
#
# Register as a Claude Code hook (settings.json):
#   {
#     "hooks": {
#       "PreToolUse": [{ "matcher": "", "hooks": [{ "type": "command",
#         "command": "~/.claude/hooks/memory-line-check.sh" }] }]
#     }
#   }

MEMORY_DIR="${CLAUDE_MEMORY_DIR:-}"

if [ -z "$MEMORY_DIR" ]; then
  exit 0
fi

MEMORY_FILE="${MEMORY_DIR}/MEMORY.md"

if [ ! -f "$MEMORY_FILE" ]; then
  exit 0
fi

LINE_COUNT=$(wc -l < "$MEMORY_FILE")

if [ "$LINE_COUNT" -ge 180 ]; then
  echo "⚠ MEMORY.md ${LINE_COUNT} lines — run /memory-health --fix"
fi

exit 0
