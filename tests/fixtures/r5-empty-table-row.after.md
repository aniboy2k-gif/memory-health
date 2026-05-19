# Fixture — R5 빈 테이블 행 (after, R5 적용 후)
#
# 적용: 모든 셀이 빈 값 또는 "—" 인 행 제거. 헤더 + 구분선 + 정상 행 유지.
# Expected: "프로젝트 상태" 테이블의 2 행 제거 (빈 행 1 + "—" 행 1).
# "변경 이력" 테이블의 빈 행 1 제거.

## 프로젝트 상태

| 프로젝트 | 트리거 | 참조 파일 | 비고 |
|---------|--------|----------|------|
| **THETA** | theta 작업 시 | `project_theta.md` | 활성 |
| **IOTA** | iota 작업 시 | `project_iota.md` | 활성 |
| **KAPPA** | kappa 작업 시 | `project_kappa.md` | 활성 |

## 변경 이력

| 일자 | 변경 | 비고 |
|------|------|------|
| 2026-05-19 | Phase E 진입 | TDD fixture |
| 2026-05-18 | Phase D withdrawal | CSR #671 |
