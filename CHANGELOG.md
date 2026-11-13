# memory-health CHANGELOG

> SKILL.md·SKILL.en.md 본문에서 옮긴 변경 이력과 신설 배경이다(CSR #2486 F-6, R0-M4). 절차를 정하는 규칙·함정·규칙 근거는 본문에 남았다 — 이 파일을 열지 않아도 스킬 실행 결과는 같다.
> Change history and background moved out of SKILL.md / SKILL.en.md (CSR #2486 F-6, R0-M4). Rules, traps and rule rationales stayed in the body — the skill runs the same without opening this file.

## 한국어 (SKILL.md 에서 옮김)

| 일자 | 변경 |
|------|------|
| 2026-11-13 | **CSR #2550 — 적용 절차 보완**. 기준 판 없는 스킬은 `--apply --worktree` 가 (f) 로 거부(종료 2)되므로 루틴 문구와 처분표에 「차이 검토 뒤 `--force-overwrite`, 미채택이면 `--set-baseline` 으로 검토함 기록」을 더함(#2415 사후 검증에서 시험으로 확인). |
| 2026-11-13 | **CSR #2415 — 업데이트 부분 문구 정정**. 「skill-advisor 는 #1806 까지 고정」「`--listing-audit --apply` 금지」 문구 삭제(skill-advisor PR #16 이 이미 바꿈, 자동 listing-audit 은 `--scan` 제외 규칙 사용) · 적용 경로를 `--apply --worktree` + PR 로 · resync 채택 뒤 `--set-baseline` 안내 · `baseline-unconfirmed` 를 보고 줄에 포함(`audit-record.sh` + 시험 1건). |
| 2026-10-29 | **CSR #2450 — 30일 감사 엔진 교체 + 스킬 업데이트 점검 추가**. 엔진을 claude-md-improver(claude-md-management 플러그인)에서 내장 claude-api `prompt-audit` 절차로 교체 — 읽기 전용 하위 에이전트 `memory-health-prompt-auditor-ro`(도구 `Read, Grep, Glob`)가 고정 범위(전역 CLAUDE.md·rules·MEMORY.md·이 스킬 SKILL 두 파일·cwd CLAUDE.md)를 감사하고 `scripts/audit-record.sh`(pre/post/update-check)만 상태를 정한다. 업데이트 점검(skill-advisor `update.py --json`, 적용 없음)과 기록 분리(`claude-md-audit-last`·`skill-update-check-last`). 연동 훅 서술 정정(CSR #2451 A1-P4 배선 해제·플러그인 명령 거부), Phase C 를 G-7 단계로 교체(CSR #2435 D3). 알림 문구에서 플러그인 이름 제거. |
| 2026-08-10 | ★ **CSR #1825 — 캡의 단위가 바이트가 아니라 문자임을 행동실측으로 확정. CSR #807/#806 전제 반증**. 카나리아 8케이스: 24,899자 로드 / 25,099자 절단(경계 25,000문자) · 10,734자·31,534**바이트** 전문 로드(바이트 캡 없음) · 302줄 절단(줄 캡 200 독립) · code point 12,909 / UTF-16 25,409 절단(단위=UTF-16 code unit). 결과: 임계를 문자 체계(25,000/20,000/17,500)와 줄 체계(200/160/140)로 교체, `wc -c` 판정 폐기. 훅을 **A-7(안정 shim + 단일 구현)** 로 재설계 — 배선본은 정책을 담지 않고 이벤트 채널 계약·위임·부재 고발만 한다. `find \| head -1` 대상 결박 폐지(비결정성 실증), 대상 경로 stdout 출력(INV-3), 자기무력화 고발 SessionStart 한정. `cap-constants.env` SSOT(source 금지) + `tests/cap-boundary-probe.sh` 행동 재검증. da_verification=776(Tier 1 · Conditional Y · CRITICAL 0). |
| 2026-06-13 | **프로젝트 CLAUDE.md 크기 모니터 신설 근거**: aria/CLAUDE.md(37.5K자 WARN)·kr-ai-trader/CLAUDE.md(20.4K자 WARN)가 memory-health 크기 관리에서 누락되어 있었음(사용자 (가)안 선택). Optimizer는 MEMORY.md 전용이므로 별도 read-only 모니터로 보강. glob 패턴으로 분리 파일 자동 포함(사용자 추가 요청). 내용 축소는 `/trader-task`. |
| 2026-05-23 | **CSR #807 — 25KB 바이트 캡 + 한글 비율 모니터링 + R7~R8 룰 추가**. memory-line-check.sh에 BYTE_COUNT + 한글 비율 측정 추가 (`CLAUDE_MEMORY_BYTE_WARN=24500` env 지원). memory-health-rules.md R7 자연어 포인터 우선 + R8 path-scoped rules 활용 신설. SKILL.md 7단계 검증을 줄 수 + 바이트 동시 검증으로 확장. rule_version 1.0.0 → 1.1.0. 한글 14%+ 환경 byte cap silent truncation 주의 박제. 근거: CSR #806 (193줄 = 25,849 bytes = 캡 249 bytes 초과 실증) + Anthropic 공식 문서 RAG (ChatGPT·Claude Web 강한 합의). ★ 이 바이트 전제는 2026-08-10 CSR #1825 에서 반증됐다. |
| 2026-05-19 | CSR #656·#658·#659·#671·#779 — R6 Sidecar Fingerprint + 재설계 Phase C·D 시리즈. v2 명령 구조(CSR #656 DA Tier 1 C-7) 도입. 과거 "구현은 후속 PR / Phase E+F" 대기 항목은 종료(해석 기반이 현실의 구현 — CSR #962). 인계 md(`~/.claude/da-archive/memory-health-redesign-handoff-2026-05-19.md`)는 이력 참고용. |

**엔진 교체 이력 (CSR #2450)**: 이전에는 claude-md-management 플러그인의 claude-md-improver 를 불렀다. 코드 저장소용 채점표에 작업 디렉터리만 탐색해 규칙·스킬·MEMORY.md 와 파일 간 모순을 보지 못해 CSR #2450 으로 교체했다.

## English (moved from SKILL.en.md)

| Date | Change |
|------|--------|
| 2026-11-13 | **CSR #2415 — update-part wording corrected**. Removed "skill-advisor frozen until #1806" and "`--listing-audit --apply` forbidden" (skill-advisor PR #16 already changed it; the automatic listing-audit uses the `--scan` exclusions) · apply path is now `--apply --worktree` + PR · `--set-baseline` after a resync adoption · `baseline-unconfirmed` included in the report lines (`audit-record.sh` + one test). |
| 2026-10-29 | **CSR #2450 — 30-day audit engine replaced + skill update check added**. Engine moved from claude-md-improver (claude-md-management plugin) to the bundled claude-api `prompt-audit` procedure — the read-only subagent `memory-health-prompt-auditor-ro` (tools `Read, Grep, Glob`) audits a fixed scope (global CLAUDE.md, rules, MEMORY.md, this skill's two SKILL files, cwd CLAUDE.md) and only `scripts/audit-record.sh` (pre/post/update-check) decides the state. Update check (skill-advisor `update.py --json`, never applied) with separate markers (`claude-md-audit-last`, `skill-update-check-last`). Hook narrative corrected (unwired by CSR #2451 A1-P4, plugin command denied), Phase C replaced by the G-7 step (CSR #2435 D3). Plugin name removed from the notice. |
| 2026-06-13 | Project CLAUDE.md size monitor added: aria/CLAUDE.md (37.5K chars WARN) and kr-ai-trader/CLAUDE.md (20.4K chars WARN) were outside memory-health's size management (user chose option (가)). The Optimizer is MEMORY.md-only, so this read-only monitor backfills it; glob patterns auto-include split files (user follow-up). Content reduction stays in `/trader-task`. |

**Replaced engine (CSR #2450)**: this routine used to call claude-md-improver from the claude-md-management plugin. Its code-repository rubric and working-directory-only discovery never saw rules, skills, MEMORY.md or cross-file contradictions, so CSR #2450 replaced it.
