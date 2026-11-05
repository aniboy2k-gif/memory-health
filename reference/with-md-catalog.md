# /memory-health — `--with-md`·Catalog 절차 (reference)

## CLAUDE.md 통합 (`--with-md`)

> **전제 조건**: 위 "월간 루틴" 절의 전제 조건과 같다(절차 파일 + 감사 에이전트 정의, 내장 claude-api 스킬 켜짐).

`--with-md`는 다른 플래그와 병용 가능하다: `/memory-health --with-md`, `/memory-health --fix --with-md`, `/memory-health --scan --with-md`.

### 실행 흐름 (3 Phase)

**Phase A — memory health (기존 동작)**
- 기존 dry-run / `--fix` / `--scan` / `--rules` 로직 그대로 수행
- Phase A 완료 후 Phase B로 진행

**Phase B — 월간 루틴 강제 실행 (prompt-audit 감사 + 스킬 업데이트 점검)**

주기와 무관하게 위 "월간 루틴" 절의 두 부분을 그대로 수행한다(독립된 단계 — Phase A 의 쓰기가 끝난 뒤):
`audit-record.sh pre` → 하위 에이전트 `memory-health-prompt-auditor-ro`(포그라운드)에 manifest 경로 전달 →
최종 메시지를 파일로 저장 → `audit-record.sh post` → `audit-record.sh update-check`.
- 결과: 상태(`STATE`), findings 개수, 보고서 + 제안 diff, 업데이트 점검 목록
- **이 단계에서는 파일을 수정하지 않는다** (보고만) — 제안 diff 적용은 별도 승인

**Phase C — 세션 학습 처리**

Phase B 완료 후, 이번 세션에서 나온 학습을 이렇게 다룬다(CLAUDE.md 에 덧붙이지 않는다 — CSR #2435 D3):
- 작업 글(CSR·trader_log 등)이 있으면 그 작업의 G-7 가이드 단계에서 다룬다.
- 없으면 학습을 보고하고 "보고만 했습니다 — 등록되지 않았습니다"라고 밝힌다.

`--fix --with-md` 조합인 경우: Phase A의 `--fix` 완료 후 Phase B→C 순서로 이어진다.

### --with-md 완료 기준
- Phase A: 기존 모드별 완료 기준과 동일
- Phase B: 두 부분의 상태 보고 완료 (파일 변경 없음)
- Phase C: 학습을 G-7 단계로 넘겼거나 "보고만 했습니다 — 등록되지 않았습니다" 명시

---

## Catalog: 지식 인덱스 카탈로그 (`catalog`)

Claude가 참조하는 **모든 MD 파일 + AI 게시판(가이드·task log) + 설정 계층**의
**메타데이터**(본문 아님)를 전수 수집해 재생성 가능한 인덱스로 만든다. "무엇이 어디에
있는지"의 지도 — 특정 파일 본문은 그때그때 on-demand Read.

### 수집 3축

| 축 | 소스 | 수집 메타 |
|----|------|----------|
| ① MD 파일 | `~/.claude`(심링크 follow) · `~/workspace` · L'Atelier workspace | realpath · access_paths(심링크 다중경로) · 카테고리 · 제목(첫 #) · frontmatter description · 크기 · mtime |
| ② AI 게시판 | **라이브 DB** `{board}_posts` (경로 해석은 ★ 아래) | 보드명 · 유형(guide/tasklog) · 게시물 id·title·status·tags·날짜 (**content 제외**) |

> ★ **게시판 라이브 DB 경로 (반드시 이것을 참조)**: 빌더는 게시판 서버(`bulletin-board/src/db/database.js`)와 **동일한 해석 순서**로 DB를 연다 — `$DB_PATH` 환경변수 → `~/Library/Application Support/bulletin-board/bulletin.db` (라이브 기본값) → `$BB_HOME/data/bulletin.db` → `$BB_HOME/database.db` (in-repo 사본, **stale 가능**). **`$BB_HOME/data/bulletin.db`는 stale 보조본**이다 (실측 2026-05-29: live csr 860 vs stale 368, live 31보드 vs stale 19보드, trader_log 357건이 stale엔 부재). 직접 sqlite 조회 시에도 반드시 라이브 경로를 쓸 것. 상세: `feedback_bulletin-board-live-db-path.md`
| ③ 설정 계층 | CLAUDE.md · rules · rules-canonical | ①에서 category 태깅 후 `config_hierarchy`로 재집계 |

### 동작
```bash
bash ~/.claude/skills/memory-health/scripts/catalog.sh
```
- 빌더: `scripts/build-catalog.py` (python3). realpath 중복제거(심링크 1실체=1엔트리),
  본문 미독(파일당 head 4KB만 — frontmatter+첫 제목), mount-graceful(미마운트 루트 skip + coverage 기록).
- 출력 (read-only 보장 — 아래 2파일만 씀, `catalog/` 하위 = memory-health 자체 scan 대상과 분리):
  - `${CLAUDE_MEMORY_DIR}/catalog/knowledge-catalog.json` — 전체 머신 SSOT
  - `${CLAUDE_MEMORY_DIR}/catalog/knowledge-catalog.md` — 카테고리·보드 요약 + jq 조회 가이드 (≤10K 캡)
- 멱등: 출력 dir 자기참조 제외 → 동일 입력 = 동일 출력.

### 조회 (검색 서브명령 없음 — JSON 직접 조회)
```bash
CAT="$CLAUDE_MEMORY_DIR/catalog/knowledge-catalog.json"
jq -r '.md.entries[]|select(.category=="skill")|.realpath' "$CAT"
jq -r '.md.entries[]|select((.title//"")+(.description//"")|test("키워드";"i"))|.realpath' "$CAT"
jq -r '.board.entries[]|select(.board=="csr")|"\(.id)\t\(.status)\t\(.title)"' "$CAT"
```

### 완료 기준
- `knowledge-catalog.json` 유효 + 3축 존재 + 중복 realpath 0
- `knowledge-catalog.md` ≤10,000자
- skill-audit.log에 F6 이력 기록
