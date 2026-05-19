# Fixture — R4 비활성 feedback (after, R4 적용 후 — 후보 표시)
#
# 적용: R4 는 자동 삭제 ❌. violation-archive.md 이동 후보 표시만 (사용자 확인 필수).
# Expected: feedback_stale_*  + feedback_archived_* 행에 후보 마커 (HTML 주석) 부착.
# 실제 이동은 사용자 명시 결정 후. 활성 feedback 은 변경 없음.

## 피드백 메모리 인덱스

**활성**: `feedback_active_recent.md` [최근 작업 — 30일 이내 갱신]
**활성**: `feedback_active_recurring.md` [반복 사용 — 매주 참조]

**비활성 후보**: `feedback_stale_old_2025_q3.md` [2025 Q3 작업 시 — 마지막 수정 2025-10-15, 30일 초과] <!-- R4 archive 후보 — violation-archive.md 이동 사용자 확인 필요 -->
**비활성 후보**: `feedback_archived_legacy.md` [legacy 작업 시 — 마지막 수정 2025-09-01, 60일 초과] <!-- R4 archive 후보 — violation-archive.md 이동 사용자 확인 필요 -->

## 분리 파일 포인터

- `feedback_active_recent.md` [최근 작업 시]
- `feedback_active_recurring.md` [매주 반복 작업 시]
- `feedback_stale_old_2025_q3.md` [Q3 작업 시] <!-- R4 archive 후보 -->
- `feedback_archived_legacy.md` [legacy 작업 시] <!-- R4 archive 후보 -->
