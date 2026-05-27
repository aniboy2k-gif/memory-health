#!/usr/bin/env bash
# memory-line-check.sh — MEMORY.md size monitoring hook (lines + bytes)
#
# Role: checks MEMORY.md line count + byte count at Claude Code session start
#       and warns when over either threshold
# Contract: see INTERFACES.md § memory-line-check.sh
#   - always exits 0 (warnings do not block the hook)
#   - must never modify files — output warnings only
#   - no output when both lines < 180 AND bytes < BYTE_WARN_THRESHOLD
#
# CSR #807 (2026-05-23): byte threshold added.
#   Anthropic Auto Memory cap = 200 lines OR 25 KB (25,600 bytes) whichever first.
#   Korean-heavy environments hit byte cap before line cap (CSR #806 finding).
#
# Installation:
#   cp scripts/memory-line-check.sh ~/.claude/hooks/memory-line-check.sh
#   chmod +x ~/.claude/hooks/memory-line-check.sh

MEMORY_DIR="${CLAUDE_MEMORY_DIR:-}"

if [ -z "$MEMORY_DIR" ]; then
  exit 0
fi

MEMORY_FILE="${MEMORY_DIR}/MEMORY.md"

if [ ! -f "$MEMORY_FILE" ]; then
  exit 0
fi

# Thresholds (overridable via env)
LINE_WARN_THRESHOLD="${CLAUDE_MEMORY_LINE_WARN:-180}"
BYTE_WARN_THRESHOLD="${CLAUDE_MEMORY_BYTE_WARN:-24500}"

LINE_COUNT=$(wc -l < "$MEMORY_FILE")
BYTE_COUNT=$(wc -c < "$MEMORY_FILE")

# Strip leading whitespace from wc output
LINE_COUNT=$(echo "$LINE_COUNT" | tr -d ' ')
BYTE_COUNT=$(echo "$BYTE_COUNT" | tr -d ' ')

LINE_OVER=0
BYTE_OVER=0

if [ "$LINE_COUNT" -ge "$LINE_WARN_THRESHOLD" ]; then
  LINE_OVER=1
fi

if [ "$BYTE_COUNT" -ge "$BYTE_WARN_THRESHOLD" ]; then
  BYTE_OVER=1
fi

# Korean ratio (CSR #806 — Korean-heavy environments hit byte cap first)
KOREAN_RATIO=0
if command -v python3 >/dev/null 2>&1; then
  KOREAN_RATIO=$(python3 -c "
import sys
try:
    with open('$MEMORY_FILE', 'r', encoding='utf-8') as f:
        text = f.read()
    if not text:
        print(0)
    else:
        korean = sum(1 for c in text if '가' <= c <= '힯')
        print(int(korean * 100 / len(text)))
except Exception:
    print(0)
" 2>/dev/null)
fi

# Emit warnings
if [ "$LINE_OVER" -eq 1 ] || [ "$BYTE_OVER" -eq 1 ]; then
  WARN_PARTS=""
  if [ "$LINE_OVER" -eq 1 ]; then
    WARN_PARTS="${WARN_PARTS}lines=${LINE_COUNT} (≥${LINE_WARN_THRESHOLD}) "
  fi
  if [ "$BYTE_OVER" -eq 1 ]; then
    WARN_PARTS="${WARN_PARTS}bytes=${BYTE_COUNT} (≥${BYTE_WARN_THRESHOLD}) "
  fi

  # Korean-heavy hint
  HINT=""
  if [ "$KOREAN_RATIO" -ge 10 ] && [ "$BYTE_OVER" -eq 1 ] && [ "$LINE_OVER" -eq 0 ]; then
    HINT=" — Korean ratio ${KOREAN_RATIO}% — byte cap reached before line cap (CSR #806)"
  fi

  echo "⚠ MEMORY.md ${WARN_PARTS}— run /memory-health --fix${HINT}"
fi

exit 0
