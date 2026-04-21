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

# 백업 디렉토리 생성
mkdir -p "$BACKUP_DIR"

# MEMORY.md와 모든 memory/*.md 파일 백업
if cp -r "${MEMORY_DIR}"/*.md "${BACKUP_DEST}" 2>/dev/null; then
  echo "✅ 백업 완료: $BACKUP_DEST"
else
  echo "❌ 백업 실패: $MEMORY_DIR 내 .md 파일 없거나 접근 불가" >&2
  exit 1
fi

# 오래된 백업 정리 (최근 10개만 유지)
BACKUP_COUNT=$(ls -1d "${BACKUP_DIR}"/memory-* 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt 10 ]; then
  ls -1dt "${BACKUP_DIR}"/memory-* | tail -n +11 | xargs rm -rf
  echo "ℹ️  오래된 백업 정리 완료 (최근 10개 유지)"
fi

exit 0
