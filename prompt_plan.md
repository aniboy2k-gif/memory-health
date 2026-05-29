# memory-health 지식 카탈로그 (`/memory-health catalog`)

> 확정 계획 (2026-05-29). 3축(MD/게시판/설정계층) 메타데이터 카탈로그 재생성 명령 + 인덱스 파일.

## 결정
- 깊이: 메타데이터 카탈로그 (경로/제목/frontmatter desc/카테고리/크기/mtime). 본문 on-demand.
- 범위 3축: ① 고유 MD 전체(심링크 dedup) ② 게시판 DB(가이드+task log) ③ 설정 계층(CLAUDE.md/rules/rules-canonical)
- 메커니즘: `/memory-health catalog` 재생성 명령 + `catalog/knowledge-catalog.{json,md}`
- 빌더=python3, MD인덱스=요약+JSON분리, task log=게시물별 id/title/status, 검색=미포함(jq/grep)

## Phase
1. MD 스캐너 코어 (build-catalog.py) — realpath dedup + frontmatter/제목 추출 + mount graceful
2. 게시판 인덱서 — bulletin.db {board}_posts, guide/tasklog 분류
3. 설정 계층 축 + 카테고리 규칙
4. MD 네비게이션 인덱스 생성 (10K 캡 정합)
5. CLI 래퍼 catalog.sh + SKILL.md/en 문서화 (Hard Gate ★C)
6. 검증 (dedup 정합·JSON 스키마·board 대조·멱등·mount-graceful)
7. 감사 로그 F6 + completion 검증

## 출력 위치
`${CLAUDE_MEMORY_DIR}/catalog/` (memory-health 자체 scan 대상과 분리)
