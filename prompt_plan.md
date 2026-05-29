# memory-health Phase 1 구현 계획 (da-chain 승인, 2026-05-29)

> da-q 4-AI 조사 + da-chain 4-AI 검토(전원 Conditional Y). CSR #956 sweep 발견 → #958 구조 문제 해소.

## 목표
rules 파일 silent divergence 재발 방지: (a) 감지 보장(자동 실행) + (b) canonical 신뢰루트 + (c) acknowledge로 커스터마이즈 양립.

## 영향 파일 (8)
- 신규: `scripts/memory-health-state.sh`(상태 lib), `scripts/memory-rules-drift-check.sh`(SessionStart hook), `tests/` 회귀
- 수정: `SKILL.md`, `SKILL.en.md`, `install.sh`, `~/.claude/settings.json`

## 단계
1. 상태 lib — `rules.manifest.json`(파일별 배열 `[{path,version,bundle_sha256,installed_sha256,installed_at}]`) + self-checksum + atomic write + schema 검증 + 부재/손상 복구
2. 2축+canonical 감지 — axis0(canonical↔번들), axis1(활성본↔installed), axis2(번들 version↔manifest)
3. 자동 트리거(C-1) — drift-check hook + settings.json SessionStart 등록
4. 명령(H-1,H-2) — acknowledge(재기준선), diff
5. 게이트·버전 단일화(Fix B,H-3) — grep 보조 강등+base-hash 정합, RULES_VERSION_REQUIRED 단일소스
6. 정리·테스트(Fix G,M-C) — canonical-draft.md 제거, 회귀 테스트
7. Red-Green 검증 + 박제

## 범위 외(기각): GPG/cosign(위협모델 과적), overlay Fix C(Phase 2). LOW: P7.

## 리스크
- canonical claude-forge 변경 = Tier S + 외부 PR (§7-D-3-A) — 사용자 yes 승인됨
- settings.json hook = advisory만(차단X), sed -i 금지(Edit/cp)

## 이전 계획 (아카이브)

### memory-health 지식 카탈로그 (`/memory-health catalog`) — 2026-05-29
- 깊이: 메타데이터 카탈로그. 범위 3축(MD/게시판/설정계층). `/memory-health catalog` + `catalog/knowledge-catalog.{json,md}`. 빌더=python3. (구현 완료됨 — scripts/build-catalog.py, catalog.sh 존재)
