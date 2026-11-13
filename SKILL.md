---
name: memory-health
description: "Claude Code 자동 메모리 파일(MEMORY.md·memory/*.md)과 자동 로드 규칙 파일의 건강 상태를 진단하고 최적화한다 — MEMORY.md Optimizer R1~R10, memory/*.md Scanner, Rules Checker, CLAUDE.md 주기 감사(월간 루틴). MEMORY.md 가 줄·글자 상한에 다가갈 때, memory/*.md 파일이 너무 커졌을 때, CLAUDE.md 나 다른 자동 로드 규칙 파일을 점검·감사할 때, 세션 시작 알림이 '/memory-health routine' 실행을 권할 때, 사용자가 이 메모리 파일들의 점검·정리나 /memory-health 를 요청할 때 사용한다. 대화 내용이나 기억된 사실을 떠올리는 요청에는 쓰지 않는다."
---

# /memory-health

> 🌐 **[다국어 / Multilingual]**
> 영어로 사용하려면 → [`SKILL.en.md`](SKILL.en.md)
> For English → [`SKILL.en.md`](SKILL.en.md)
>
> **언어 자동 감지**: 기본 출력은 한국어다. 영어로 대화하면 자동으로 영어로 출력한다.
> 대화 언어가 불분명하거나 한/영 혼재 시에는 한국어(기본값)로 출력한다.
> **Language auto-detection**: If the conversation is in English, all output from this skill will be in English.
> When the language is unclear or mixed, Korean (default) is used.

> ⚠️ **[SINGLE-SESSION ONLY]** 여러 Claude 탭을 동시에 열어두면 파일이 손상될 수 있다.
> 반드시 단일 세션에서만 실행할 것. 락 메커니즘은 제공되지 않는다.

<!-- Sync checklist: SKILL.md를 수정할 때마다 아래 항목을 확인한다.
  - [ ] SKILL.en.md에 동일 내용 반영
  - [ ] reference/*.md 를 고쳤으면 짝 reference/*.en.md 에 동일 반영 (ko/en 파일 구조 1:1)
  - [ ] 새로운 bash 명령/에러 메시지가 있으면 영어로 작성
  - [ ] 버전/임계값 변경 시 양쪽 파일 동시 수정
-->

메모리 파일 건강 상태를 진단하고 최적화하는 스킬.
Optimizer (MEMORY.md 줄 수 최적화), Scanner (memory/*.md 파일 크기 분리),
**월간 루틴** — CLAUDE.md·규칙 감사(내장 claude-api `prompt-audit` 절차를 읽기 전용 하위 에이전트가 실행, 30일 주기)와
스킬 업데이트 점검(30일 주기, 점검만)을 제공한다.

> **세션 학습·훅 (사실, CSR #2450)**: `revise-claude-md-stop.sh`(Stop)·`revise-claude-md-inject.sh`(UserPromptSubmit)는
> CSR #2451 A1-P4 로 `settings.json` 배선이 **해제**됐다(파일은 이력으로 보존). 플러그인 명령 `revise-claude-md` 는
> `settings.json` 에서 **거부(deny)** 된다. 세션 학습은 CLAUDE.md 에 덧붙이지 않고, 해당 작업의 G-7 가이드 단계에서
> 다룬다(CSR #2435 D3).

## 사용법

### v2 명령 구조 (CSR #656)

> **상태 (P7 disposition, CSR #962, 2026-05-29)**: v2 명령은 본 SKILL.md 절차 **해석 기반으로 동작 중** — 별도 dispatcher 스크립트는 불필요하며 추가 구현 예정 없음.
> - `catalog`·`rules`는 전용 스크립트(`scripts/catalog.sh`·`scripts/check-rules.sh`)로 실행
> - `check`·`fix`·`scan`은 본 SKILL.md 절차로 수행 (Claude 해석)
> - v1 명령은 deprecated alias로 계속 동작 (2026-12-31까지)

```
/memory-health check         → 진단 (hook-safe — 기억 파일 변경 ❌ · 상태 기록 파일·git fetch 는 있음) [먼저 Read: reference/optimizer.md 1~3단계]
                              exit 0=정상, 1=warn, 2=critical
/memory-health fix [--R1...] → Mutating Optimizer (R1~R10, 명시 R번호 — memory-health-rules.md 기준) [먼저 Read: reference/optimizer.md]
/memory-health scan          → Scanner (memory/*.md 분리, 1회 승인) [먼저 Read: reference/scanner.md]
/memory-health rules         → Rules Checker (자동 로드 파일, read-only) [먼저 Read: reference/rules-checker.md]
/memory-health rules --strict → WARN 이상 exit 2 [먼저 Read: reference/rules-checker.md]
/memory-health catalog       → 지식 카탈로그 빌더 (3축 메타데이터 인덱스 재생성) [먼저 Read: reference/with-md-catalog.md]
/memory-health fix --json    → dry-run JSON 출력 [먼저 Read: reference/optimizer.md 1~3단계]
/memory-health --with-md     → CLAUDE.md 품질 감사 (모든 명령 병용) [먼저 Read: reference/with-md-catalog.md · Phase A 는 reference/optimizer.md]
```

**명령 경계 원칙 (DA C-7)**:
- **check** = 기억 파일(MEMORY.md·memory/*.md)을 바꾸지 않는 진단, hook-safe — 자동화 안전. 단 원격 점검(②)의 `git fetch`·쿨다운 기록과 월간 루틴(③)의 기록·보고서 파일은 쓴다(RD)
- **fix / scan / rules** = 명시적 mutating 또는 read-only — 분리된 surface
- 기본 명령 = `check` (안전 측 default)

### v1 명령 (deprecated alias — 2026-12-31 까지)

```
/memory-health               → 진단 (= v2 check) [먼저 Read: reference/optimizer.md 1~3단계]
/memory-health --fix         → Optimizer (= v2 fix, deprecated warning) [먼저 Read: reference/optimizer.md]
/memory-health --scan        → Scanner (= v2 scan, deprecated warning) [먼저 Read: reference/scanner.md]
/memory-health --rules       → Rules Checker (= v2 rules, deprecated warning) [먼저 Read: reference/rules-checker.md]
/memory-health --rules --strict → (= v2 rules --strict) [먼저 Read: reference/rules-checker.md]
/memory-health --fix --json  → (= v2 fix --json) [먼저 Read: reference/optimizer.md 1~3단계]
/memory-health --with-md     → CLAUDE.md 감사 (v2 동일) [먼저 Read: reference/with-md-catalog.md · Phase A 는 reference/optimizer.md]
```

기본값은 dry-run이므로 기억 파일(MEMORY.md·memory/*.md)은 변경되지 않는다. 원격 점검(②)은 `git fetch` 와 쿨다운 기록(`.remote-check-last`)을, 월간 루틴(③)은 기록·jsonl·보고서 파일을 쓴다.

실행 흐름:
```
/memory-health         → ① dry-run 결과 출력 [먼저 Read: reference/optimizer.md — ① = 그 1~3단계]
                          ② skill 원격 최신화 점검 (CSR #962 — 인터넷 fetch, 4h 쿨다운, 비차단)
                          ③ 월간 루틴 (각 부분은 자기 기록이 기한 경과일 때만 — 아래 "월간 루틴" 절)
                             감사 부분: audit-record.sh pre → 읽기 전용 감사 에이전트 → post
                             업데이트 부분: audit-record.sh update-check (점검만, 적용 없음)
                          ℹ️  Rules Checker 미포함 — /memory-health --rules 또는 MEMORY_HEALTH_DEFAULT_RULES=true (켜면 먼저 Read: reference/rules-checker.md)
/memory-health --fix   → dry-run 결과 출력 → 승인 게이트 → 실행 [먼저 Read: reference/optimizer.md]
/memory-health --scan  → 스캔 결과 출력   → 승인 게이트 → 실행 [먼저 Read: reference/scanner.md]
/memory-health --rules → Rules Checker 실행 (파일 변경 없음, 게이트 없음) [먼저 Read: reference/rules-checker.md]
/memory-health --with-md → 월간 루틴 두 부분 강제 실행 (주기 미경과도 실행) [먼저 Read: reference/with-md-catalog.md · Phase A 는 reference/optimizer.md]
```

### 절차 파일 (reference/) — 실행 전에 통째로 Read

위 명령 줄의 `[먼저 Read: reference/X.md]` = 그 명령을 실행하기 전에 그 파일을 통째로 Read 한다(절차 본문이 그 파일에 있다).

| 파일 | 내용 | 읽는 진입점 |
|---|---|---|
| `reference/optimizer.md` | Optimizer 단계 전부·완료 기준·한글 캡 주의 | 기본 `/memory-health`(=`check`, ① = 1~3단계) · `fix`/`--fix` · `fix --json`/`--fix --json`(1~3단계) · `--with-md` Phase A |
| `reference/scanner.md` | Scanner 1~6단계·완료 기준 | `scan`/`--scan` |
| `reference/rules-checker.md` | Rules Checker + 프로젝트 CLAUDE.md 크기 모니터링 | `rules`/`--rules`(`--strict`) · `MEMORY_HEALTH_DEFAULT_RULES=true` 인 기본 실행 |
| `reference/with-md-catalog.md` | `--with-md` Phase A~C · Catalog | `--with-md` · `catalog` |

### --fix --json 모드

이 단계 전에 `reference/optimizer.md` 를 통째로 Read 한다(1~3단계).
3단계(dry-run 결과)까지 실행 후 JSON으로 출력하고 **즉시 종료**한다. 파일 변경 없음.

출력 스키마:
```json
{
  "status": "ok | needs_action",
  "current_lines": 0,
  "target_lines": 140,
  "candidates": [
    { "section": "<헤더>", "current_lines": 0, "savings": 0 }
  ]
}
```

## 초기화 (최초 1회 실행)

`CLAUDE_MEMORY_DIR` 환경변수가 설정되어 있어야 한다. 설정 방법 3가지 (하나 이상 권장):
1. `~/.claude/settings.json`의 `env` 필드 → `"CLAUDE_MEMORY_DIR": "<절대경로>"` (Claude Code 실행 방식 무관 주입, 동적 reload — 가장 견고)
2. `~/.zshrc` → `export CLAUDE_MEMORY_DIR="<절대경로>"` (터미널·스크립트 호환)
3. `install.sh` 실행 (자동 감지 후 `~/.zshrc`에 영속화)

미설정 시 helper 스크립트(`memory-backup.sh`·`memory-health-log.sh`)는 크립틱 중단 대신 위 3가지 설정 안내를 출력하고 exit 1로 graceful 종료한다 (Layer 3, 경로 자동추측 없음 — 안전 우선).

스킬 최초 사용 전 아래를 실행하여 필요한 파일을 사전 생성한다:
```bash
MEMORY_DIR="${CLAUDE_MEMORY_DIR:?'CLAUDE_MEMORY_DIR is not set'}"
touch "$MEMORY_DIR/violation-archive.md" && echo "✅ violation-archive.md"
touch "$MEMORY_DIR/skill-audit.log"      && echo "✅ skill-audit.log"
```

---

## 역할 경계 (hook vs skill)

| 구분 | 파일 | 역할 | 부작용 |
|------|------|------|--------|
| hook | `memory-line-check.sh` | MEMORY.md 자동 감시 + 경고만 | 없음 |
| subagent | `memory-health-prompt-auditor-ro` (`~/.claude/agents/`) | 월간 감사 실행자 — 도구는 `Read, Grep, Glob` 뿐(쓰기 도구 없음) | 없음 (보고서 + 제안 diff 만) |
| skill | `/memory-health` | 대화형 수동 실행 + 실제 최적화 + 월간 루틴 진행 | 파일 변경 |

> `revise-claude-md-stop.sh`·`revise-claude-md-inject.sh` 는 배선 해제됐다(CSR #2451 A1-P4) — 실행 경로에 없으므로 이 표에서 뺐다.

hook은 경고만 한다. 실제 수정은 이 스킬이 담당한다.

---

## skill 원격 최신화 점검 (기본 실행 ②, CSR #962)

`/memory-health` 기본 실행(dry-run) 시, 설치된 skill이 **원격(github)보다 뒤처졌는지** 인터넷에서 점검한다. `forge-update-check.sh`의 검증된 패턴을 미러링한다.

```bash
bash ~/.claude/skills/memory-health/scripts/check-skill-update.sh
```

- **동작**: `git fetch origin`(4초 타임아웃) → 로컬 HEAD vs origin 기본 브랜치 비교 → 뒤처지면 advisory 1줄("skill 업데이트 N commit 있음 … git pull")
- **쿨다운 4h**: 매 실행 fetch 방지 (`MEMORY_HEALTH_STATE_DIR/.remote-check-last`). `--force`로 무시(테스트용)
- **비차단**: 오프라인·타임아웃·비-git 모두 exit 0 + 무출력 (graceful). 네트워크 없는 환경 안전
- **결과 처리**: advisory 출력 시 사용자에게 그대로 보고. 업데이트 적용 여부는 사용자 결정(자동 pull ❌)

> forge-update-check.sh(프레임워크 전체, SessionStart)와 별개 — 이쪽은 memory-health **skill repo** 한정, `/memory-health` 기본 실행에 통합.

---

## 월간 루틴 — CLAUDE.md·규칙 감사 + 스킬 업데이트 점검 (기본 dry-run에 통합, CSR #2450)

> **전제 조건**:
> - 절차 파일 `~/.claude/skills/claude-api/shared/prompt-audit.md` 와 감사 에이전트 정의
>   `~/.claude/agents/memory-health-prompt-auditor-ro.md` 가 있어야 한다(없으면 `pre` 가 ENGINE_UNAVAILABLE·AUDITOR_MISCONFIGURED).
> - 내장 claude-api 스킬을 끄지 않아야 한다(`skillOverrides`·`disableBundledSkills`).
> - Claude Code v2.1.283+(공식 문서 기준, CSR #2450 에서 2026-10-28 확인) 는 사용자가 직접 치는 `/doctor prompt-audit` 형식에만 필요하다.
> - 세션을 `--add-dir`·`/add-dir`·`--agents` 없이 시작한 상태에서 실행한다(디스크에 보이지 않아 `pre` 가 못 본다 — RF).

`/memory-health` 기본 실행(dry-run) 종료 후 아래 두 부분을 수행한다. **각 부분은 자기 기록이 기한 경과일 때만**
돈다(`--with-md` 는 둘 다 강제). 둘 다 기한이면 감사 먼저, 그다음 업데이트 점검 — 둘 다 시도·기록하고, 각자 자기 기록만 갱신한다.

**감사는 독립된 단계다** — memory-health 의 쓰기 단계(Optimizer `--fix`·Scanner `--scan`)가 끝난 뒤에 돌리고,
감사 도중에는 어떤 파일도 고치지 않는다. 감사가 낸 제안 diff 의 적용은 이 단계 밖에서 별도 승인으로만 한다.

### 타임스탬프 기반 주기 판정

```bash
AUDIT_LAST="$HOME/.claude/da-tools/claude-md-audit-last"          # 감사 부분 — audit-record.sh post 가 REPORTED 때만 갱신
UPDATE_LAST="$HOME/.claude/da-tools/skill-update-check-last"      # 업데이트 부분 — update-check 가 PASS 때만 갱신
AUDIT_INTERVAL_DAYS="${CLAUDE_MD_AUDIT_INTERVAL:-30}"   # 기본 30일, CLAUDE_MD_AUDIT_INTERVAL로 오버라이드 (두 부분 공통)
[[ $AUDIT_INTERVAL_DAYS =~ ^[1-9][0-9]{0,3}$ ]] || AUDIT_INTERVAL_DAYS=30   # 08·abc·0·음수 → 30 (훅 memory-rules-drift-check.sh mrdc_audit_notice 와 같은 검증 — 함께 고칠 것)

days_since() {   # 파일 없음·읽을 수 없음 = 9999 (기한 경과로 본다)
  local v; v="$(head -n 1 "$1" 2>/dev/null | tr -d '[:space:]')"
  [[ $v =~ ^[1-9][0-9]{0,11}$ ]] || { echo 9999; return; }
  echo $(( ($(date +%s) - v) / 86400 ))
}
AUDIT_DAYS=$(days_since "$AUDIT_LAST"); UPDATE_DAYS=$(days_since "$UPDATE_LAST")
```

### 판정 결과

| 조건 | 동작 |
|------|------|
| `AUDIT_DAYS >= AUDIT_INTERVAL_DAYS` (파일 없음 포함) | 감사 부분 — 아래 4단계 |
| `UPDATE_DAYS >= AUDIT_INTERVAL_DAYS` (파일 없음 포함) | 업데이트 부분 — `audit-record.sh update-check` |
| 둘 다 미경과 | "✅ 월간 루틴 최신 (감사 N일 전 · 업데이트 점검 M일 전)" 출력 후 skip |
| `--with-md` 플래그 명시 | 주기 미경과여도 두 부분 강제 실행 |

### 감사 부분 — 4단계 (상태는 스크립트만 정한다)

감사 범위(고정 목록, `pre` 가 절대경로로 만든다): `~/.claude/CLAUDE.md` · `~/.claude/rules/*.md`(최상위만) ·
`${CLAUDE_MEMORY_DIR}/MEMORY.md` · `~/.claude/skills/memory-health/SKILL.md`·`SKILL.en.md` · `reference/*.md` 8개(optimizer·rules-checker·scanner·with-md-catalog 의 ko/en, 각각 필수) ·
현재 작업 디렉터리의 `CLAUDE.md`(있을 때).

```bash
AR="$HOME/.claude/skills/memory-health/scripts/audit-record.sh"
bash "$AR" pre --cwd "$PWD"      # ① STATE=READY 면 RUN_DIR=<경로> 출력 · 그 밖의 STATE 면 여기서 멈추고 보고
```

② **하위 에이전트 실행 (포그라운드)** — Agent 도구, `subagent_type: "memory-health-prompt-auditor-ro"`, `model: "opus"`,
백그라운드 실행 금지. 프롬프트는 아래 그대로, `<MANIFEST>` 자리에 `$RUN_DIR/manifest.txt` 내용을 한 줄도 바꾸지 않고 넣는다:

```
model: opus (reason: audit)
spawn: why=p proc=memory-health:routine-audit n=1 est=<fixed>+<work>
Apply the prompt-audit procedure (read ~/.claude/skills/claude-api/shared/prompt-audit.md fully first)
to exactly these files, named by absolute path. Report + proposed diff only; do not apply anything.
<MANIFEST>
Do not report these again (dismissed earlier, path | quote): <DO_NOT_REPORT>
Emit one `FINDING <json>` line per finding (one-line JSON object with keys sev, path, line, quote, summary;
quote = the offending file text verbatim, at most 120 characters, JSON-escaped), then one `FINDINGS_TOTAL <n>` line.
End with one `COVERED: <abs path> last_line=<n>` line per path above (n = the last line number your
Read tool showed for that file), then one `FINDINGS high=<n> medium=<n> low=<n>` line.
```

`<DO_NOT_REPORT>` 자리에는 `python3 "$AR_DIR/routine_items.py" do-not-report` 출력을 넣는다(없으면 `none`). `AR_DIR` = `$AR` 가 있는 폴더.

③ 에이전트의 **최종 메시지 전문**을 `$RUN_DIR/report.md` 로 저장한다(Write — 요약·편집 금지).

```bash
bash "$AR" post "$RUN_DIR" "$RUN_DIR/report.md"   # ④ REPORTED 일 때만 claude-md-audit-last 갱신
```

결과 보고: `STATE`, findings 개수, 보고서 사본 경로(`~/.claude/da-tools/claude-md-audit-reports/<ts>.md`, mode 600, 최근 12개 보존).
사본 맨 앞에는 `post` 가 머리말(상태·read_evidence·잔여 위험 RE·RF·RH, `AUDITOR_CHANGED` 면 「신뢰 불가 — AUDITOR_CHANGED」)을 붙이고, 그 아래는 에이전트 원문 그대로다.
에이전트 호출 자체가 오류로 끝나면 ③④를 하지 않고 아래를 실행한 뒤 "감사 엔진 사용 불가(ENGINE_UNAVAILABLE)"로 보고한다 — 기록 갱신 없음:

```bash
bash "$AR" fail "$RUN_DIR" "<에이전트 오류 내용>"   # jsonl 에 ENGINE_UNAVAILABLE 기록 · claude-md-audit-last 는 건드리지 않음
```

### 업데이트 부분 — 스킬 업데이트 점검

```bash
bash "$AR" update-check     # timeout -k 10 300 python3 ~/.claude/skills/skill-advisor/scripts/update.py --json
```

- 출력의 `SKILL: <이름> channel=<채널> status=<상태>` 줄(업데이트 가능·기준 판 미확인·가져오기 실패)을 그대로 보고한다.
  `status=baseline-unconfirmed` = 로컬 파일이 기록된 기준 판 상태와 다르다(복원·병합 안 된 PR·새 로컬 수정) — 검토 뒤 `--set-baseline`.
- **적용은 자동이 아니다** — 사용자 승인 뒤 별도 단계로 한다. `update.py --apply` 는 운영 트리·그 서브모듈·
  패치 세트 스킬에 쓰기를 거부한다. 일상 경로 = claude-forge 연결 작업 트리에서
  `update.py <정확한 스킬 이름> --apply --worktree <작업 트리>` → 커밋 + PR → 병합 → 운영 트리 `git pull --ff-only`.
  기준 판이 없는 스킬은 이 명령이 거부된다(종료 2, `no baseline`) — 상류와의 차이를 검토한 뒤 `--force-overwrite`(경고 줄 · .bak 보존)를 더하거나, 채택하지 않으면 `update.py --set-baseline <스킬> --hash <upstream_norm_hash>` 로 「검토함」을 기록한다.
  `/skill-advisor --update --apply` 뒤 자동 `--listing-audit --apply` 는 `--scan` 과 같은 제외 규칙(utterance_patterns·Hard Gate·`hook_no_opt`)으로 후보를 고른다.
  기준 판이 있는 목록 스킬을 `resync-skill.sh` 로 채택했으면 병합 뒤 `update.py --set-baseline <스킬> --hash <upstream_norm_hash>` — resync 는 그 기준 판을 고치지 않는다.
  판정표·거부 규칙 = skill-advisor `references/update-baseline.md`.

### 상태 표 (`~/.claude/da-tools/claude-md-audit.jsonl`, 필드 `part`)

| 상태 | 단계 | 뜻 | 갱신하는 기록 |
|------|------|----|--------------|
| `READY` | pre | 검사 통과, 실행 디렉터리 생성 | 없음 |
| `AUDITOR_SHADOWED` | pre | 같은 이름의 정의가 둘 이상, 또는 유일한 정의가 사용자 수준(`~/.claude/agents/`) 밖 — 프로젝트 `.claude/agents/`(하위 폴더 포함, cwd 부터 `/` 까지) 검색. 플러그인 폴더·`additionalDirectories` 는 이름이 겹쳐도 그림자가 아니라 검색 안 함 | 없음 |
| `AUDITOR_MISCONFIGURED` | pre | 정의 없음, frontmatter 키가 {name, description, tools, model} 와 다름, `tools` ≠ `Read, Grep, Glob`, `model` ∉ {opus, sonnet, inherit} | 없음 |
| `ENGINE_UNAVAILABLE` | pre · fail | 절차 파일 없음 (pre), 또는 에이전트 호출 오류 (`fail`) | 없음 |
| `SCOPE_UNRESOLVED` | pre | `CLAUDE_MEMORY_DIR` 미설정 또는 그 `MEMORY.md` 없음 (범위 파일 누락 포함) | 없음 |
| `AUDITOR_CHANGED` | post | 정의 파일 sha256 이 pre 와 다름 또는 파일 없음 — 보고서는 남기되 신뢰 불가 | 없음 |
| `SCOPE_CHANGED_DURING_AUDIT` | post | 범위 파일 sha256 이 pre 와 다름 | 없음 |
| `AUDIT_INCOMPLETE` | post | `COVERED` 줄 누락, `last_line` 이 실제 줄 수와 다름, `FINDINGS` 줄 파싱 불가 | 없음 |
| `REPORTED` | post | 모든 파일의 마지막 줄 번호를 정확히 보고 + FINDINGS 파싱 (`read_evidence:"last_line_match"`) | `claude-md-audit-last` |
| `UPDATE_CHECK_PASS` | update | exit 0·1 + JSON 파싱 + `fetch_error < total` | `skill-update-check-last` + `skill-update-failed.json` |
| `UPDATE_CHECK_FAILED` | update | exit 2·124·137·기타, JSON 파싱 불가, `fetch_error == total` | 없음 (`skill-update-failed.json` 그대로) |

`REPORTED` 의 뜻: 감사 에이전트가 줄 수를 받지 않고도 모든 파일의 마지막 줄 번호를 맞혔다 — 각 파일을 열었다는
증거다. 끝까지 읽었다는 것도, 검토 품질도 증명하지 않는다. findings 개수는 에이전트 자신의 집계다.
`--dry-run`(post·update-check)은 기록·jsonl·보고서 사본을 쓰지 않고 레코드를 화면에만 출력한다.

### 관찰 → 받아들이기 → 처분 (`/memory-health routine`, CSR #2491)

「감사 돌렸음, 끝」으로 끝나지 않게 — 루틴이 찾은 것은 전부 **원장의 항목**이 되고, 항목마다 **처분**이 붙어야 실행이 끝난다.
도구 = `scripts/routine_items.py`(stdlib, `/usr/bin/python3` 3.9). 로컬 상태 폴더 `$MH_LOCAL_DIR`(기본: Claude 설정 폴더 안
`memory-health-local/`, 심링크가 아닌 진짜 폴더) — 원장 `items.jsonl`(추가만 하는 단일 기록) · 이 맥의 채널 목록 `channels.json`
(공개 저장소에 올리지 않는다) · 부분 기록 `parts.jsonl`·`part-<C~F>-last` · 감사 범위 진척 `audit-coverage.json`.

**누가·언제**: ① 감지 = 기존 SessionStart 훅 `memory-rules-drift-check.sh` 가 매 세션 맨 먼저 `routine_items.py peek` 을 부른다
(로컬 읽기만, 1초 상한, 출력 600자 이하 — 열린 항목 수·기한 지난 부분·채널 새 사건). peek 이 0 이 아닌 코드로 끝나면 `routine peek FAILED rc=<n>`
한 줄. 훅 자체가 안 돌면 두 번째 SessionStart 명령 `peek-watchdog.sh`(상태 폴더에 **복사**해 설치)가 `routine detector stale` 한 줄을 낸다.
② 받아들이기·처분 = 그 알림을 받은 대화형 세션이 다른 일보다 먼저 아래를 실행한다(`claude -p` 에서는 하지 않는다 — 그쪽 훅 환경은
`CLAUDE_CODE_ENTRYPOINT=sdk-cli` 라서(대화형 = `cli`, 실측) peek 이 실행 안내 없이 개수 줄만 낸다).

```bash
RI="python3 $HOME/.claude/skills/memory-health/scripts/routine_items.py"   # 설치 위치에 맞게
$RI start [--force]          # 실행권(lease) 획득 + run 행(due_parts). 다른 세션이 30분 안에 쓰고 있으면 거부
# 기한인 부분만(--force 는 일곱 부분 전부):
#  P-A 고정 범위 감사 — 위 4단계 → $RI ingest-audit --run-dir "$RUN_DIR" --part A
#  P-B 스킬 업데이트   — bash "$AR" update-check > "$T/upd.txt"; $RI ingest-update --file "$T/upd.txt"; S=$(cd "$HOME/.claude/skills" 2>/dev/null && pwd -P); OP=; [ -n "$S" ] && OP=$(dirname "$S"); if [ -z "$OP" ] || [ "$(git -C "$OP" rev-parse --show-toplevel 2>/dev/null)" != "$OP" ]; then $RI part-fail --part B --reason "vendor-patch: operational tree unresolved"; elif SETS=$(git -C "$OP" ls-tree --name-only HEAD vendor-patches/ 2>/dev/null | grep -cE '^vendor-patches/csr[0-9]+-upstream-files\.txt$'); [ "$SETS" -gt 0 ]; then bash "$OP/vendor-patches/resync-skill.sh" --verify-all || $RI part-fail --part B --reason "vendor-patch verify-all failed rc=$?"; else echo "vendor-patch: no committed sets — verify-all not applicable"; fi
#                         (P-B 를 다시 돌린다 = 이 줄 전체를 다시 돌린다 — 끝의 vendor-patch 검사가 그 실행의 마지막 P-B 행을 쓴다)
#  P-C 업데이트 채널   — $RI scan-channels        (내장 plugins 채널 + channels.json 의 log_lines·stamp_age 채널)
#  P-D 설치 진단       — $RI ingest-doctor        (claude doctor, 읽기 전용, 60초 상한)
#  P-E 순환 전체 감사  — $RI plan-shards → 조각마다: pre --shard <manifest> → 감사 에이전트 → post → ingest-audit --part E → cover --run-dir … --shard N
#                         (AUDIT_INCOMPLETE 조각은 plan-shards --split N 으로 반으로 나눠 한 번 다시)
#  P-F 안 쓰는 확장    — $RI scan-unused          (~/.claude.json 의 skillUsage·pluginUsage 두 키만 읽는다 — 그 파일엔 자격증명도 있다)
#  P-G 내장 npm 부품    — $RI scan-deps          (channels.json 의 dep_roots·npx_specs — 이 두 값은 로컬 channels.json 에만 둔다. 스킬·플러그인 자체는 P-B·P-C 소관)
#  한 부분을 아예 못 돌렸으면: $RI part-fail --part X --reason "<사유>"
$RI status --check-refs --run <RUN_ID>   # 처분이 끝날 때까지 반복
```

- ★ 세는 법: `peek`·`status`(--check-refs 없음)의 `open` 에는 이전에 `task` 로 넘긴 항목이 안 들어간다 — 그 CSR 이 닫히면 `--check-refs` 가 `orphaned_task` 로 다시 연다(CSR #2509: 40건이 78건이 됨). 둘은 각각 `task-unchecked N`·「N task-disposed item(s) not ref-checked」로 알린다. 완료·보고 수는 항상 `--check-refs --run` 결과 기준.
- ★ 진단은 읽기 전용으로: 채널 생산자(`upstream-copy-check.py` 등)를 손으로 돌릴 때는 `--dry-run` 을 쓴다. 그냥 돌리면 로그에 줄이 남아 다음 `scan-channels` 가 항목으로 연다(CSR #2509: 3건).
- ★ 스킬을 `skill-sources.json` 에서 `local_custom` 으로 바꾸면 사본 점검의 추적 대상 수가 줄어 `expected_min_targets` 아래로 떨어진다 → 같은 작업에서 `upstream-copy-check.py --set-floor <새 수> --reason "<전환한 스킬>"` 을 실행한다(안 하면 다음 주간 실행이 `FAIL`).

- P-E 범위 = 공식 `/doctor prompt-audit` 기본 범위(설정 폴더의 CLAUDE.md·rules·skills·commands·agents·output-styles) + `channels.json` 의
  `project_roots` 각 루트의 CLAUDE.md·CLAUDE.local.md·AGENTS.md·`.claude/{rules,skills,commands,agents,output-styles}`. 월 60만 자(7만5천 자 조각 8개),
  그중 30만 자 이상은 한 번도 감사 안 된 파일 → 가장 오래된 파일에, 나머지는 바뀐 파일에. 7만5천 자보다 큰 파일은 줄 범위 조각으로 나눠 여러 달에 걸쳐 덮는다.
  `plan-shards` 는 매번 「미감사 파일 수·최대 감사 경과일」을 출력하고, 목록에 없는 프로젝트 루트(`discover_dirs` 2단계 아래)나 사라진 루트는 `unknown` 항목이 된다.
- 조각(`경로#L시작-끝`)의 `COVERED` 는 주어진 끝 줄을 맞혀야 하므로 「열었다」 증거가 통째 파일보다 약하다(범위를 알려 준다).

**처분** — `$RI dispose <id>... --disp <종류> …` (여러 id 를 한 번에, 하나라도 규칙 위반이면 아무것도 안 쓴다):

| 처분 | 필요한 것 | 받지 않는 경우 |
|---|---|---|
| `fixed` | `--ref` = 커밋 sha · PR URL · `CSR #N c#M`(그 글의 댓글로 확인) | 감사 지적은 그 파일에 인용문이 남아 있으면 거부(예외: `--ref` 가 커밋 sha 이고, 그 커밋이 감사가 기록한 그 줄을 지웠으며 인용문이 다른 줄에만 남은 경우 — 이를테면 고친 커밋이 자기 표지 줄에 같은 문자열을 넣은 경우 — 수락) · `part_failed` 는 그 항목의 마지막 FAILED 행 뒤에 온 같은 부분 PASS 행의 `ts` 만(어느 run 이든, 실패 전 PASS 는 거부) |
| `task` | `--ref "CSR #N"` — 그 글 본문/댓글에 항목 id 가 그대로 있어야 함 | 게시판 접속 불가면 거부 |
| `dismissed` | `--reason` 20자 이상 | 허용 종류만: 감사 지적(high 제외)·update-available·unused-extension·plugin-version-changed·unclassified·dep-outdated·dep-vulnerable(sev=high 제외). 감사 지적의 기각은 그 파일의 sha256 에 묶여, 파일이 바뀌면 다시 열린다 |
| `deferred` | `--goal --deadline(YYYY-MM-DD, 90일 안) --method --revert` 넷 다 | 항목당 한 번만 · sev=high 불가 |
| `verified` | `--reason` 에 근거(명령과 출력 줄) 20자 이상 | `unknown`·`unobserved_plugin` 은 세션이 닫지 못한다 — 다음 스캔이 원천을 다시 읽어야 도구가 `fixed recheck:<run>` 을 쓴다 |

| 항목 종류 | 세션이 할 일 |
|---|---|
| 감사 지적 high | 같은 세션에 `fixed` 또는 `task` |
| 감사 지적 medium/low | 이번 묶음에서 `fixed`, 사유 있는 `dismissed`, 또는 `deferred`(목표·기한·방법·되돌릴 조건 넷 다). `task` 는 넷을 갖춘 `deferred` 가 불가능할 때만 쓴다(이미 한 번 미뤘음 · 90일 안의 기한이나 되돌릴 조건을 세울 수 없음). 그리고 그 지적을 이번 달 후속 CSR 의 표에 적은 뒤에만 쓴다. 다른 열린 CSR 의 표와 겹치는 지적은 다음 행을 따른다. 도구(`check_task_ref`)는 id 가 그 CSR 글(본문이나 댓글)에 있는지를 이미 검사한다. 「넷을 갖춘 `deferred` 가 불가능할 때만」은 도구가 검사하지 않는 세션 규칙이다 |
| 다시 찾은 지적이 이미 열린 CSR 의 표에 있음 | 그 지적은 여기서 처리하지 않는다. 먼저 그 CSR 에 다시 찾은 id 들을 나열한 댓글 1개를 달고, 그 CSR 로 `task --ref "CSR #N"`. `dismissed` 는 쓰지 않는다 — 기각은 「다시 보고 안 함」 목록에 들어가 그 CSR 이 닫힌 뒤에도 돌아오지 않는다. `task` 는 그 CSR 이 닫히면 `--check-refs` 가 `orphaned_task` 로 다시 연다 |
| claude-forge·memory-health·skill-advisor 수정 | 저장소마다 작업 트리 1개·PR 1개, 병합 승인은 실행 끝에 한 번 |
| 개인 로컬 파일 수정 | 백업 후 직접 수정 |
| 소유자만 정할 것(돈·권한·자격증명·비가역·취향) · doctor 권한 규칙 경고 | 이번 달 후속 CSR 에 `task`, 그 글에 `waiting` 태그 |
| 스킬 업데이트 가능 | 그 스킬의 SKILL.md 가 claude-forge `vendor-patches/*-upstream-files.txt` 에 있으면(목록 스킬): `update.py --apply` 를 쓰지 않는다. 운영 HEAD 에서 새로 만든 claude-forge linked worktree 에서 `bash vendor-patches/resync-skill.sh <skill> --expect-upstream-hash <항목의 upstream= 값>` 을 돌리고 종료 코드대로 처분한다 — 목록 스킬에는 `dismissed` 를 쓰지 않는다: UNCHANGED(0) → `verified --reason "resync UNCHANGED upstream <sha256:…> exit 0 (bash vendor-patches/resync-skill.sh <skill> --expect-upstream-hash <sha256:…>)"`(P-B 가 계속 보고하는 한 매번 다시 열려 그때의 기준으로 다시 판정된다) · UPSTREAM-CHANGED(10) → vendor-patches/README 대로 마무리(그 파일을 담은 세트 전부 재생성)·PR, 병합 후 `fixed --ref <PR URL>`, 병합 전 `task --ref "CSR #N"`(그 글에 항목 id) · CONFLICT(2) → 해결·세트 전부 재생성·PR, 병합 전 `task --ref "CSR #N"`(그 글에 충돌과 항목 id), 병합 후 `fixed --ref <PR URL>` · REFUSED(4) → 이름 붙은 전제를 고쳐 같은 세션에 다시 실행, 지금 못 고치면(`upstream moved`·`fetch failed`·`baseline lags`) `task --ref "CSR #N"`(그 글에 항목 id 와 거부 문구) — update.py 금지, `verified` 금지 · NOT-PATCHED(3) → 목록 밖 스킬로 처리. 목록 밖 스킬: `update.py <정확한 스킬 이름> --apply --worktree <claude-forge 연결 작업 트리>`(이름 없는 일괄 적용 금지 · 기준 판이 없으면 거부되므로 차이 검토 뒤 `--force-overwrite`) + PR, 그다음 같은 세션에 `bash vendor-patches/resync-skill.sh --verify-all`, 또는 `dismissed`(일부러 갈라 둔 로컬 수정 — 목록 밖 스킬만) |
| 의존성 취약점(`dep-vulnerable`, `npm audit` 가 낸 것) | critical(sev=high)은 `fixed`(의존성 올림 + 시험)·`task`. high·moderate 는 올림 가능이면 올리고, 아니면 입력 경로(외부 입력이 닿는가)를 근거로 한 `dismissed`. 새 권고가 생기면 id 가 달라져 다시 열린다 |
| 플러그인 판 바뀜 | `claude plugin list --json` 에서 오류 없이 켜져 있는지 보고 `verified` |
| 자동 갱신 마켓 14일 넘게 안 갱신 | `claude plugin marketplace update <이름>` 후 다시 확인·기록 |
| `unobserved_plugin`(자동 갱신 꺼짐 + 45일 안 상류 관찰 없음) | 상류를 확인하는 채널의 관찰 규칙에 넣거나 자동 갱신을 켠다 — 다음 스캔이 닫는다 |
| ponytail 보류(HOLD) — 구조 변경 | 기록된 diff 를 읽고, 소유자의 HOLD 승인 기준(da #1357)을 충족할 때만 `.ponytail-approve` 로 승인한다. 충족하지 않으면 보류를 유지한다. 어느 쪽이든 기준 대조 결과를 근거로 `verified` |
| ponytail 보류(HOLD) — 지운 것을 다시 지울 수 없음 | 소유자 몫(취향 — 소유자가 지운 것): 이번 달 후속 CSR 에 id 를 적고 그 글에 `waiting` 태그를 단 뒤 `task` |
| ponytail 오류·불러오기 실패·롤백 | `ponytail-update.sh --rollback` 을 돌리고 결과를 기록한다. 기록은 커밋·PR·`CSR #N c#M` 을 ref 로 `fixed`. 되돌리지 못하면 `task`. sev=high 이면 `fixed`·`task` 만 받는다 |
| 실행기 멈춤(`runner-stale`, 표식이 채널의 `max_age_h` 보다 오래됨) | `launchctl list`·로그·rc 로 진단한다. sudo 없이 고칠 수 있으면 고치고 기록 — `fixed`(ref = 커밋·PR·진단과 조치를 적은 `CSR #N c#M`) 또는 `verified`(다시 도는 것을 보이는 명령과 출력 줄). sudo 가 필요하면 소유자가 할 일이다. 이번 달 후속 CSR 에 id·진단·소유자가 칠 명령을 적고 그 글에 `waiting` 태그를 단 뒤 `task --ref "CSR #N"` |
| RTK 업데이트 가능 | 릴리스 노트를 읽고 `brew upgrade rtk`(sudo 불필요), 판을 확인하고 기록 — 판 확인 명령과 출력 줄을 근거로 `verified` |
| claude doctor 설치 문제 | sudo 없이 고칠 수 있으면 고치고 `fixed`(ref = 커밋·PR·조치를 적은 `CSR #N c#M`). 아니면 소유자 몫 — 이번 달 후속 CSR 에 id 와 소유자가 칠 명령을 적고 그 글에 `waiting` 태그를 단 뒤 `task` |
| CLI 자동 업데이트 실패 | 진단하고 기록 — 진단 명령과 출력 줄을 근거로 `verified` |
| `part_failed` | 같은 run 에서 그 부분을 다시 돌려 PASS → `fixed`(그 행 ts). 안 되면 `task` — 실행은 종료 코드 4(완료 아님)로 끝나고 다음 세션에 다시 기한 |
| `cursor_reset` | 로그를 처음부터(교체됐으면 옛 파일도) 읽어 빠진 사건을 받아들이고 `verified` |
| `unclassified` | 채널의 사건/무시 정규식을 보강하고 `verified`(근거=정규식), 또는 `dismissed` |
| `unknown`(원천을 못 읽음) | 원천을 되살리거나 채널 목록을 고친다. 다음 스캔이 원천을 제대로 읽으면 도구가 `fixed recheck:<run>` 을 써서 닫는다. 이번 세션에 못 하면 `task`(그 재확인이 통과할 때까지 status 4). 세션은 `fixed`·`verified`·`dismissed` 로 닫지 못한다 |
| claude-forge 업데이트 가능 | `update.py` 가 아니라 `/forge-update` 를 실행하고 확인 → `fixed`(커밋·PR) 또는 `verified`(확인 명령과 출력 줄). 일부러 안 올리면 사유 있는 `dismissed`. 이번에 못 하면 `task` |
| `orphaned_task`(참조한 CSR 이 닫혔는데 항목은 미결) | 원래 항목 종류의 규칙대로 다시 처분한다. 닫힌 CSR 에 id 댓글을 달아도 다시 열리지 않는다. ① 고쳐졌으면 `fixed`: 감사 지적이면 커밋·PR·`CSR #N c#M`(인용문이 파일에서 사라져야 한다. 단 위 `fixed` 칸의 예외에 해당하면 인용문이 남아도 수락한다), `part_failed` 면 `fixed --ref <실패 뒤에 온 같은 부분 PASS 행의 ts>`(어느 run 이든) ② 아직이면 열린 CSR 로 새 `task`(그 글에 id 를 먼저 적는다). 감사 지적 medium/low 는 위 medium/low 행의 조건을 따른다 ③ 소유자 몫이면 이번 달 후속 CSR 에 id 를 적고 그 글에 `waiting` 태그를 단 뒤 `task`. `unknown`·`unobserved_plugin` 에는 ①이 없다 — 원천을 고치면 다음 스캔이 닫는다 |
| `unlinked_task`(참조한 CSR 에 id 가 없음) | 그 CSR 에 id 를 적은 댓글을 달고 다시 처분하거나 새 `task` |

- **후속 CSR 은 달마다 최대 1개**(「월간 루틴 YYYY-MM 후속」, 실행권을 쥔 세션만 만들고 먼저 같은 제목을 찾아 재사용) — 항목마다 CSR 을 만들지 않는다.
- **완료 판정**: `status --check-refs --run <최신 run_id>` 종료 코드가 **0 일 때만** 끝 — 1 열린 항목 · 2 원장 불명/기한 지난 미룸/참조 미확인/기한 부분 PASS 없음 · 4 막힘을 후속 작업에 넘김(완료 아님). 보고는 그 STATUS 줄로 끝낸다.
- **다음 판 관찰**: 판별 관찰 항목을 따로 만들지 않는다 — 채널 점검이 상시(매 세션 peek + 매달 받아들이기)다.
- **공개 저장소 경계**: memory-health·skill-advisor 에 push/PR 하기 전 `$RI boundary-check --repo <저장소> [--body <PR 본문 파일>]` — gitleaks + 차단 목록(`scan-channels` 가 매번 다시 만드는 `boundary-deny.txt`) + 프로젝트 루트 이름 단어 검사. 목록이 없거나 비었거나, gitleaks 오류, 기준 커밋을 못 정하면 막는다.
- `channels.json` 키: `channels[]`(`id`·`type`=`log_lines`|`stamp_age`·`path`·`events[{re,kind,sev,observe,plugin}]`·`ignore[]`·`stale_path`·`max_age_h`) · `required_ids[]` · `project_roots[]` · `discover_dirs[]` · `board_post_url`(`{n}` 자리에 글 번호) · `gitleaks_cmd`(선택).

### 보장 범위 (Covers — Round-8 원문)

> The auditor's tool calls are read-only provided the invoked agent actually uses the validated read-only definition
> and Claude Code enforces its tool allowlist. Pre/post hashing detects persistent definition changes but cannot
> establish that the definition remained unchanged throughout invocation. Concurrent changes, including changes
> subsequently restored and live-reload effects, are excluded from this guarantee. A matching hash does not certify
> runtime definition integrity.

(번역: 감사 에이전트의 도구 호출은, 호출된 에이전트가 검증된 읽기 전용 정의를 실제로 쓰고 Claude Code 가 도구 허용 목록을
지킬 때에 한해 읽기 전용이다. pre/post 해시는 정의의 지속적 변경을 잡지만 호출 내내 정의가 그대로였음을 입증하지 못한다.
되돌려진 변경·실시간 재로딩을 포함한 동시 변경은 이 보장에서 제외된다. 해시 일치는 실행 시점 정의 무결성을 보증하지 않는다.)

### 잔여 위험 (공개)

- **RA** Claude Code 가 `tools` 허용 목록을 지킨다는 데 기댄다(문서화된 동작) — `pre` 는 정의 편집을 잡을 뿐 하네스 회귀는 못 잡는다.
- **RB** 사용자가 직접 치는 `/doctor prompt-audit` 전체 실행은 본 세션에서 모든 도구로 돈다(auto 모드) — 보호는 이 루틴에만 적용된다.
- **RC** 감사 에이전트는 하위 감사자를 띄울 수 없다 — 월간 범위가 한 에이전트에 맞아야 하고, 잘리면 AUDIT_INCOMPLETE 로 드러난다. 감사 범위(D1-scope)가 커지면 V8(범위 전체를 실제 감사 에이전트로 한 번 돌려 REPORTED 를 확인하는 실행)을 다시 돌려야 한다 — `rules/*.md` 는 `pre` 때마다 다시 펼쳐지므로 범위는 누가 일부러 늘리지 않아도 커진다.
- **RD** 보고서·jsonl·두 기록은 본 세션이 쓴다(감사 범위 밖의 고정 경로).
- **RE** 모델이 진행을 조율한다 — 저장된 글이 감사 에이전트에게서 왔음을 스크립트가 증명하지 못하고, findings 개수는 에이전트 자신의 것이다.
- **RF** 세션 한정 `--add-dir`·`/add-dir`·`--agents` 정의는 디스크에 보이지 않아 `pre` 가 못 본다 — 그런 플래그 없이 시작한 세션에서 실행한다.
- **RG** 훅이 일으키는 부수 쓰기는 보장 밖이다 — 범위 파일 sha256 비교는 두 시점 사이의 지속적 바이트 변경만 잡고, 되돌려진 일시 쓰기·같은 내용 재기록·범위 밖 쓰기는 못 잡는다.
- **RH** pre 와 post 사이에 바뀌었다가 같은 바이트로 되돌려진 정의, 그 사이 실시간 재로딩으로 전달된 변경은 바이트 비교로 볼 수 없다.

### 전체 범위 감사 (사용자 직접 실행)

`~/.claude/` 의 스킬·명령·에이전트 전체를 보려면 사용자가 `/doctor prompt-audit`(경로 없이)를 직접 친다.
⚠ 이 실행은 **쓰기 보호가 없다**(RB · claude-code issue #99288: 적용 요청 없이 파일을 고친 사례) — 적용을 승인하기 전에
제안 diff 를 반드시 검토한다. memory-health 는 이 전체 실행을 자동으로 하지 않는다(비용).

> 엔진 교체 이력(claude-md-improver → prompt-audit, CSR #2450): [`CHANGELOG.md`](CHANGELOG.md)

---

## 실패 모드 테이블

| 단계 | 실패 조건 | authoritative 상태 | 복구 명령 |
|------|----------|-------------------|----------|
| 5단계 백업 실패 (Optimizer) | `memory-backup.sh` exit ≠ 0 | 원본 MEMORY.md 유지 | `git log --oneline -5` |
| 6단계 실행 중 오류 (Optimizer) | MEMORY.md 쓰기 실패 | backup 본이 기준 | `git checkout -- MEMORY.md` |
| Phase1 .tmp 생성 실패 (Scanner) | write 오류 | 원본 유지 | `rm -f "${CLAUDE_MEMORY_DIR}"/*.tmp` |
| Phase2 rename 실패 (Scanner) | `mv` exit ≠ 0 | .tmp 잔존 | `rm -f "${CLAUDE_MEMORY_DIR}"/*.tmp` |
| Phase2 포인터 갱신 실패 (Scanner) | MEMORY.md write 오류 | part2 생성됨, MEMORY.md 구버전 | `git checkout -- MEMORY.md && rm {part2-file}` |
| len() 검증 실패 (Scanner) | \|합산 − 원본\| > 3 | 파일 변경됨 | `git checkout -- {변경된 파일들}` |
| audit log rotate 실패 | `cp` exit ≠ 0 | 로그 기록 중단 | `ls -lh "${CLAUDE_MEMORY_DIR}/skill-audit.log"` |
| **WAL init 실패 (Atomicity)** | `memory-wal.sh init` exit ≠ 0 | 변경 시작 전, 원본 유지 | `memory-wal.sh list` |
| **WAL 미commit 발견 (Atomicity)** | 변경 후 process 중단 → WAL 잔존 | 변경 도중 — 파일 무결성 의문 | `memory-wal.sh recover` → `rollback` → `memory-backup.sh` 복구 |
| **Journal chain break (Atomicity)** | `memory-journal.sh verify` exit ≠ 0 | 로그 변조 또는 손상 — 신뢰성 의문 | `memory-journal.sh tail 20` 확인 후 외부 백업과 대조 |
| **Sidecar fingerprint 불일치 (R6)** | sha256 비교 실패 | 사용자 직접 편집 후 도구 재실행 | 정상 — 변경 진행 + sidecar 갱신 |

> **Atomicity 동작 흐름 (Phase C — CSR #658, 2026-05-19)**:
> 1. `wal_id=$(memory-wal.sh init "$files" "$rules")` — prepare phase
> 2. `memory-backup.sh` — 변경 직전 backup 보장 (기존 동작)
> 3. 승인된 R 규칙 적용 — 실제 파일 변경
> 4. `memory-journal.sh log <action> "$files" "$rules" "$wal_id" '{...}'` — append-only audit
> 5. `memory-wal.sh commit "$wal_id"` — atomic 완료 신호 (WAL 삭제)
>
> 중단 시: WAL 잔존 → 다음 실행 시 `memory-wal.sh recover` 가 자동 감지 → 사용자 확인 후 `rollback` + `git checkout` 또는 backup 복구.

---

## 감사 로그 명세

```
위치: ${CLAUDE_MEMORY_DIR}/skill-audit.log
형식: {ISO8601} | {기능} | {작업 요약} | {변경 전} → {변경 후}
예시:
  2026-04-21T20:00:00+0900 | F3 | MEMORY.md 최적화 | 195줄 → 142줄
  2026-04-21T20:10:00+0900 | F4 | project-fss.md 분리 | 25,190자 → 4,800자 + 4,200자
보존: 50KB 초과 시 skill-audit.log.old로 rotate (스킬이 자동 수행)
보존 정책: 최대 2세대 (.old 파일 1개)
```

감사 로그 참조 범위:
- 허용: 표준 셸 명령, Python 내장, 환경 변수(CLAUDE_MEMORY_DIR 등), 이 스킬에 동봉된 scripts/
- 금지: 외부 시스템·개인 게시판·서드파티 트래커 등 이 레포지토리 외부 의존성

---

## 판단 기준 참조

최적화 후보 식별 규칙은 `memory/memory-health-rules.md`를 Read하여 적용한다.
즉흥적 판단 금지. rules 파일에 없는 기준으로 후보를 선정하지 않는다.

---

---

## 승인 정책 요약

| 모드 | 승인 필요 | 근거 |
|------|----------|------|
| dry-run (기본) | 불필요 | 자동 승인 범위 (기억 파일 변경 없음 — 상태 기록·보고서 파일만 씀, RD) |
| `--fix` | 1회 필요 | MEMORY.md 내용 변경 |
| `--scan` | 1회 필요 | memory/*.md 내용 변경 |
| `--rules` | 불필요 | read-only, 파일 변경 없음 |
| `catalog` | 불필요 | read-only (catalog/ 인덱스 2파일만 생성, 원본 무변경) |
| `--fix --json` | 불필요 | dry-run과 동일, JSON 출력 후 종료 |
| `--with-md` (Phase B) | 불필요 | prompt-audit 보고서 + 제안 diff 만 (읽기 전용 감사 에이전트, 파일 변경 없음) |
| `--with-md` Phase B→수정 | 1회 필요 | prompt-audit 제안 diff 적용 시 별도 승인 (감사 단계 밖에서) |

---

변경 이력·신설 근거: [`CHANGELOG.md`](CHANGELOG.md)
