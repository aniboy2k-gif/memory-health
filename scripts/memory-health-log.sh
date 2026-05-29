#!/usr/bin/env bash
# memory-health-log.sh — audit log writer + rotate
# Args: $1=function(F3|F4) $2=summary $3=before $4=after
# Override log path via MEMORY_DIR environment variable

# CLAUDE_MEMORY_DIR resolution — graceful, no path guessing (Layer 3, 2026-05-29).
if [ -z "${CLAUDE_MEMORY_DIR:-}" ]; then
  echo "❌ CLAUDE_MEMORY_DIR is not set — audit log not written." >&2
  echo "   Set it via one of:" >&2
  echo "     1. ~/.claude/settings.json → \"env\": { \"CLAUDE_MEMORY_DIR\": \"<abs-path>\" }" >&2
  echo "     2. ~/.zshrc                → export CLAUDE_MEMORY_DIR=\"<abs-path>\"" >&2
  echo "     3. run the skill install.sh (auto-detects and persists it)" >&2
  exit 1
fi
MEMORY_DIR="$CLAUDE_MEMORY_DIR"
LOG_FILE="${MEMORY_DIR}/skill-audit.log"
TIMESTAMP=$(date +"%Y-%m-%dT%H:%M:%S%z")

# rotate: when log exceeds 50KB (cp+truncate — avoids data loss if mv is interrupted)
# guard existence first: avoids shell-level redirect stderr leak on first write (file absent)
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt 51200 ]; then
  cp "$LOG_FILE" "$LOG_FILE.old" || { echo "❌ Log rotate failed — logging aborted" >&2; exit 1; }
  truncate -s 0 "$LOG_FILE"
fi

echo "${TIMESTAMP} | ${1} | ${2} | ${3} → ${4}" >> "$LOG_FILE"
