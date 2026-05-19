# Fixture — R2 만료 포인터 (after, R2 적용 후 — 후보 표시)
#
# 적용: R2 는 자동 삭제 ❌. 후보 표시만 (사용자 확인 후 제거).
# Expected: GAMMA + EPSILON 행에 후보 마커 (HTML 주석) 부착. 실제 삭제 없음.
# DELTA (진행 중) 는 변경 없음.

## 프로젝트별 규칙

| 프로젝트 | 트리거 | 참조 파일 | 상태 |
|---------|--------|----------|------|
| **GAMMA** | gamma 작업 시 | `project_gamma.md` | 완결 (2025-10-30) <!-- R2 만료 후보 — 사용자 확인 필요 --> |
| **DELTA** | delta 작업 시 | `project_delta.md` | 진행 중 |
| **EPSILON** | epsilon 작업 시 | `project_epsilon_DELETED.md` | (참조 파일 부재) <!-- R2 만료 후보 — 참조 파일 자동 감지 부재 --> |

## 가이드 계층

- GAMMA [gamma 작업 시]: 메인 가이드 (완결 프로젝트) <!-- R2 만료 후보 -->
- DELTA [delta 작업 시]: 진행 중 작업
- EPSILON [epsilon 작업 시]: 참조 파일 없음 <!-- R2 만료 후보 -->
