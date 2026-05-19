# Fixture — R4 비활성 feedback (before)
#
# 검증 대상: feedback_ 접두어 파일 + 30일 이상 비활성
# 적용 규칙: memory-health-rules.md R4
# Expected: violation-archive.md 이동 후보 표시 (사용자 확인 필수)

## 피드백 메모리 인덱스

**활성**: `feedback_active_recent.md` [최근 작업 — 30일 이내 갱신]
**활성**: `feedback_active_recurring.md` [반복 사용 — 매주 참조]

**비활성 후보**: `feedback_stale_old_2025_q3.md` [2025 Q3 작업 시 — 마지막 수정 2025-10-15, 30일 초과]
**비활성 후보**: `feedback_archived_legacy.md` [legacy 작업 시 — 마지막 수정 2025-09-01, 60일 초과]

## 분리 파일 포인터

- `feedback_active_recent.md` [최근 작업 시]
- `feedback_active_recurring.md` [매주 반복 작업 시]
- `feedback_stale_old_2025_q3.md` [Q3 작업 시]
- `feedback_archived_legacy.md` [legacy 작업 시]
