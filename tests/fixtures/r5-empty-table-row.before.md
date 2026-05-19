# Fixture — R5 빈 테이블 행 (before)
#
# 검증 대상: 마크다운 테이블에서 모든 데이터 셀이 빈 값 또는 "—" 인 행
# 적용 규칙: memory-health-rules.md R5
# Expected: 해당 행 제거. 테이블 헤더 + 구분선 유지.

## 프로젝트 상태

| 프로젝트 | 트리거 | 참조 파일 | 비고 |
|---------|--------|----------|------|
| **THETA** | theta 작업 시 | `project_theta.md` | 활성 |
|  |  |  |  |
| **IOTA** | iota 작업 시 | `project_iota.md` | 활성 |
| — | — | — | — |
| **KAPPA** | kappa 작업 시 | `project_kappa.md` | 활성 |

## 변경 이력

| 일자 | 변경 | 비고 |
|------|------|------|
| 2026-05-19 | Phase E 진입 | TDD fixture |
|  |  |  |
| 2026-05-18 | Phase D withdrawal | CSR #671 |
