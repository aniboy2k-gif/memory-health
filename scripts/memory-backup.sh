#!/usr/bin/env bash
# memory-backup.sh — 메모리 디렉토리 백업 샘플
#
# 역할: /memory-health --fix의 5단계 Hard Stop 게이트
# 계약: exit 0 = 백업 성공, exit ≠ 0 = 백업 실패 (Optimizer 실행 차단)
#
# 이 파일은 샘플입니다. 실제 사용 시 ~/.claude/hooks/memory-backup.sh로
# 복사하고 환경에 맞게 수정하세요. INTERFACES.md의 계약을 준수해야 합니다.
#
# 설치:
#   cp scripts/memory-backup.sh ~/.claude/hooks/memory-backup.sh
#   chmod +x ~/.claude/hooks/memory-backup.sh

set -euo pipefail

MEMORY_DIR="${CLAUDE_MEMORY_DIR:?'CLAUDE_MEMORY_DIR 환경변수가 설정되지 않았습니다'}"
BACKUP_DIR="${MEMORY_DIR}/.backups"
TIMESTAMP=$(date +"%Y%m%dT%H%M%S")
BACKUP_DEST="${BACKUP_DIR}/memory-${TIMESTAMP}"

# pre-flight: 쓰기 권한 + 디스크 여유 공간 확인
if [ ! -w "$(dirname "$BACKUP_DIR")" ] && [ ! -w "$BACKUP_DIR" ] 2>/dev/null; then
  echo "❌ 백업 실패: $BACKUP_DIR 상위 경로에 쓰기 권한 없음" >&2
  exit 1
fi
AVAILABLE_KB=$(df -k "$MEMORY_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
SOURCE_KB=$(du -sk "$MEMORY_DIR" 2>/dev/null | awk '{print $1}')
if [ -n "$AVAILABLE_KB" ] && [ -n "$SOURCE_KB" ] && [ "$AVAILABLE_KB" -lt "$SOURCE_KB" ]; then
  echo "❌ 백업 실패: 디스크 여유 공간 부족 (필요: ${SOURCE_KB}KB, 가용: ${AVAILABLE_KB}KB)" >&2
  exit 1
fi

# 백업 디렉토리 생성
mkdir -p "$BACKUP_DEST"

# MEMORY.md와 모든 memory/*.md 파일 백업 (glob 대신 find로 디렉토리 포함 여부 무관하게 동작)
SOURCE_FILES=$(find "${MEMORY_DIR}" -maxdepth 1 -name "*.md" 2>/dev/null)
if [ -z "$SOURCE_FILES" ]; then
  echo "❌ 백업 실패: $MEMORY_DIR 내 .md 파일 없음" >&2
  exit 1
fi

SOURCE_COUNT=$(echo "$SOURCE_FILES" | wc -l | tr -d ' ')
SOURCE_BYTES=$(echo "$SOURCE_FILES" | xargs du -cb 2>/dev/null | tail -1 | awk '{print $1}')

echo "$SOURCE_FILES" | xargs cp -t "$BACKUP_DEST" 2>/dev/null || {
  echo "❌ 백업 실패: 파일 복사 중 오류" >&2
  exit 1
}

# 백업 완전성 검증 (파일 수 + 바이트 크기 대조)
DEST_COUNT=$(find "${BACKUP_DEST}" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
DEST_BYTES=$(find "${BACKUP_DEST}" -maxdepth 1 -name "*.md" 2>/dev/null | xargs du -cb 2>/dev/null | tail -1 | awk '{print $1}')

if [ "$SOURCE_COUNT" != "$DEST_COUNT" ]; then
  echo "❌ 백업 검증 실패: 원본 ${SOURCE_COUNT}개 → 백업 ${DEST_COUNT}개 (불일치)" >&2
  exit 1
fi
if [ -n "$SOURCE_BYTES" ] && [ -n "$DEST_BYTES" ] && [ "$SOURCE_BYTES" != "$DEST_BYTES" ]; then
  echo "❌ 백업 검증 실패: 원본 ${SOURCE_BYTES}B → 백업 ${DEST_BYTES}B (불일치)" >&2
  exit 1
fi

echo "✅ 백업 완료: $BACKUP_DEST (${SOURCE_COUNT}개 파일)"
# 주의: 백업 완료 후 원본이 변경되는 경쟁 조건은 이 스크립트로 방지할 수 없음

# 오래된 백업 정리 (최근 10개만 유지)
BACKUP_COUNT=$(ls -1d "${BACKUP_DIR}"/memory-* 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt 10 ]; then
  ls -1dt "${BACKUP_DIR}"/memory-* | tail -n +11 | xargs rm -rf
  echo "ℹ️  오래된 백업 정리 완료 (최근 10개 유지)"
fi

exit 0
