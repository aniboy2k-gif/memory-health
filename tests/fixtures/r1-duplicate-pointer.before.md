# Fixture — R1 중복 포인터 (before)
#
# 검증 대상: 동일 파일 경로를 참조하는 포인터가 2회 이상 등장
# 적용 규칙: memory-health-rules.md R1
# Expected: 가장 구체적인 트리거 1개만 유지, 나머지 제거

## 프로젝트별 규칙

| 프로젝트 | 트리거 | 참조 파일 |
|---------|--------|----------|
| **ALPHA** | alpha 작업 시 | `project_alpha.md` |
| **BETA** | beta 작업 시 | `project_beta.md` |

## 가이드 계층

ALPHA [alpha 작업 시]: `project_alpha.md` 시작

## 분리 파일 포인터

- `project_alpha.md` [ALPHA 트레이딩·ML·리서치 작업 시 — 더 구체적]
- `project_beta.md` [beta 작업 시]
