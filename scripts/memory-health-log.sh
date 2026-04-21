#!/usr/bin/env bash
# memory-health-log.sh — 감사 로그 기록 + rotate
# 인수: $1=기능(F3|F4) $2=작업요약 $3=변경전 $4=변경후
# MEMORY_DIR 환경 변수로 경로 override 가능

MEMORY_DIR="${CLAUDE_MEMORY_DIR:?'CLAUDE_MEMORY_DIR 환경변수가 설정되지 않았습니다'}"
LOG_FILE="${MEMORY_DIR}/skill-audit.log"
TIMESTAMP=$(date +"%Y-%m-%dT%H:%M:%S%z")

# rotate: 50KB 초과 시 (cp+truncate — mv 중단 시 유실 방지)
if [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 51200 ]; then
  cp "$LOG_FILE" "$LOG_FILE.old" || { echo "❌ rotate 실패 — 로그 기록 중단" >&2; exit 1; }
  truncate -s 0 "$LOG_FILE"
fi

echo "${TIMESTAMP} | ${1} | ${2} | ${3} → ${4}" >> "$LOG_FILE"
