# Fixture — R3 과도한 인라인 (before)
#
# 검증 대상: 단일 섹션 (## 헤더 ~ 다음 ## 헤더 사이) 이 10줄 초과
# 적용 규칙: memory-health-rules.md R3
# Expected: 별도 파일 분리 + 포인터로 교체

## ZETA 프로젝트 상세 (12줄 — R3 적용 대상)

ZETA 프로젝트는 다음 단계로 진행한다:
1. 데이터 수집 단계 — 외부 API 호출
2. 전처리 단계 — 결측치 보정 + 이상치 제거
3. 모델 학습 단계 — XGBoost + LightGBM 앙상블
4. 검증 단계 — k-fold cross validation
5. 배포 단계 — 컨테이너 기반 서빙
6. 모니터링 단계 — Grafana 대시보드
7. 재학습 단계 — 월 1회 자동
8. 롤백 정책 — 성능 저하 시 이전 버전 복원
9. 알림 정책 — Slack 채널 #zeta-ops
10. 권한 관리 — IAM role 기반

## ETA 프로젝트 (5줄 — R3 미적용)

ETA 는 간단한 프로젝트다.
주요 작업:
- A 단계
- B 단계
