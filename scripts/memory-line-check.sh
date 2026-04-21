#!/usr/bin/env bash
# memory-line-check.sh — MEMORY.md 줄 수 감시 hook
#
# 역할: Claude Code 세션 시작 시 MEMORY.md 줄 수를 확인하고 임계값 초과 시 경고 출력
# 계약: INTERFACES.md § memory-line-check.sh 참조
#   - exit 0 항상 (경고가 있어도 hook 차단하지 않음)
#   - 파일 변경 절대 금지 — 경고 출력만
#   - 180줄 미만 시 출력 없음
#
# 설치:
#   cp scripts/memory-line-check.sh ~/.claude/hooks/memory-line-check.sh
#   chmod +x ~/.claude/hooks/memory-line-check.sh
#
# Claude Code hook 등록 (settings.json):
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
  echo "⚠ MEMORY.md ${LINE_COUNT}줄 — /memory-health --fix 권장"
fi

exit 0
