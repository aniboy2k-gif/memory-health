# Fixture — R2 만료 포인터 (before)
#
# 검증 대상: 참조 파일이 실제 존재하지 않거나 프로젝트가 "완결" 명시
# 적용 규칙: memory-health-rules.md R2
# Expected: 후보 표시만 (자동 삭제 ❌, 사용자 확인 필수)

## 프로젝트별 규칙

| 프로젝트 | 트리거 | 참조 파일 | 상태 |
|---------|--------|----------|------|
| **GAMMA** | gamma 작업 시 | `project_gamma.md` | 완결 (2025-10-30) |
| **DELTA** | delta 작업 시 | `project_delta.md` | 진행 중 |
| **EPSILON** | epsilon 작업 시 | `project_epsilon_DELETED.md` | (참조 파일 부재) |

## 가이드 계층

- GAMMA [gamma 작업 시]: 메인 가이드 (완결 프로젝트)
- DELTA [delta 작업 시]: 진행 중 작업
- EPSILON [epsilon 작업 시]: 참조 파일 없음
