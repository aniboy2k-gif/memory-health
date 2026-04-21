#!/usr/bin/env bash
# memory-health-log.sh — audit log writer + rotate
# Args: $1=function(F3|F4) $2=summary $3=before $4=after
# Override log path via MEMORY_DIR environment variable

MEMORY_DIR="${CLAUDE_MEMORY_DIR:?'CLAUDE_MEMORY_DIR is not set'}"
LOG_FILE="${MEMORY_DIR}/skill-audit.log"
TIMESTAMP=$(date +"%Y-%m-%dT%H:%M:%S%z")

# rotate: when log exceeds 50KB (cp+truncate — avoids data loss if mv is interrupted)
if [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 51200 ]; then
  cp "$LOG_FILE" "$LOG_FILE.old" || { echo "❌ Log rotate failed — logging aborted" >&2; exit 1; }
  truncate -s 0 "$LOG_FILE"
fi

echo "${TIMESTAMP} | ${1} | ${2} | ${3} → ${4}" >> "$LOG_FILE"
