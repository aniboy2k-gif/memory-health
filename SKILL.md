---
name: memory-health
description: "메모리 파일 건강 상태 진단 + 최적화 (MEMORY.md Optimizer R1~R10 + memory/*.md Scanner + Rules Checker + CLAUDE.md 주기 감사)"
argument-hint: '[check] | fix [--R1...] [--json] | scan | rules [--strict] | --with-md | --fix | --scan | --rules [--strict] | --fix --json | --fix --with-md | --scan --with-md'
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
/memory-health check         → 진단 (hook-safe — 기억 파일 변경 ❌ · 상태 기록 파일·git fetch 는 있음)
                              exit 0=정상, 1=warn, 2=critical
/memory-health fix [--R1...] → Mutating Optimizer (R1~R10, 명시 R번호 — memory-health-rules.md 기준)
/memory-health scan          → Scanner (memory/*.md 분리, 1회 승인)
/memory-health rules         → Rules Checker (자동 로드 파일, read-only)
/memory-health rules --strict → WARN 이상 exit 2
/memory-health catalog       → 지식 카탈로그 빌더 (3축 메타데이터 인덱스 재생성)
/memory-health fix --json    → dry-run JSON 출력
/memory-health --with-md     → CLAUDE.md 품질 감사 (모든 명령 병용)
```

**명령 경계 원칙 (DA C-7)**:
- **check** = 기억 파일(MEMORY.md·memory/*.md)을 바꾸지 않는 진단, hook-safe — 자동화 안전. 단 원격 점검(②)의 `git fetch`·쿨다운 기록과 월간 루틴(③)의 기록·보고서 파일은 쓴다(RD)
- **fix / scan / rules** = 명시적 mutating 또는 read-only — 분리된 surface
- 기본 명령 = `check` (안전 측 default)

### v1 명령 (현재 구현, deprecated alias — 2026-12-31 까지)

```
/memory-health               → 진단 (= v2 check)
/memory-health --fix         → Optimizer (= v2 fix, deprecated warning)
/memory-health --scan        → Scanner (= v2 scan, deprecated warning)
/memory-health --rules       → Rules Checker (= v2 rules, deprecated warning)
/memory-health --rules --strict → (= v2 rules --strict)
/memory-health --fix --json  → (= v2 fix --json)
/memory-health --with-md     → CLAUDE.md 감사 (v2 동일)
```

기본값은 dry-run이므로 기억 파일(MEMORY.md·memory/*.md)은 변경되지 않는다. 원격 점검(②)은 `git fetch` 와 쿨다운 기록(`.remote-check-last`)을, 월간 루틴(③)은 기록·jsonl·보고서 파일을 쓴다.

실행 흐름:
```
/memory-health         → ① dry-run 결과 출력
                          ② skill 원격 최신화 점검 (CSR #962 — 인터넷 fetch, 4h 쿨다운, 비차단)
                          ③ 월간 루틴 (각 부분은 자기 기록이 기한 경과일 때만 — 아래 "월간 루틴" 절)
                             감사 부분: audit-record.sh pre → 읽기 전용 감사 에이전트 → post
                             업데이트 부분: audit-record.sh update-check (점검만, 적용 없음)
                          ℹ️  Rules Checker 미포함 — /memory-health --rules 또는 MEMORY_HEALTH_DEFAULT_RULES=true
/memory-health --fix   → dry-run 결과 출력 → 승인 게이트 → 실행
/memory-health --scan  → 스캔 결과 출력   → 승인 게이트 → 실행
/memory-health --rules → Rules Checker 실행 (파일 변경 없음, 게이트 없음)
/memory-health --with-md → 월간 루틴 두 부분 강제 실행 (주기 미경과도 실행)
```

### --fix --json 모드

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
> - Claude Code v2.1.283+ 는 사용자가 직접 치는 `/doctor prompt-audit` 형식에만 필요하다.
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
`${CLAUDE_MEMORY_DIR}/MEMORY.md` · `~/.claude/skills/memory-health/SKILL.md`·`SKILL.en.md` · 현재 작업 디렉터리의 `CLAUDE.md`(있을 때).

```bash
AR="$HOME/.claude/skills/memory-health/scripts/audit-record.sh"
bash "$AR" pre --cwd "$PWD"      # ① STATE=READY 면 RUN_DIR=<경로> 출력 · 그 밖의 STATE 면 여기서 멈추고 보고
```

② **하위 에이전트 실행 (포그라운드)** — Agent 도구, `subagent_type: "memory-health-prompt-auditor-ro"`, `model: "opus"`,
백그라운드 실행 금지. 프롬프트는 아래 그대로, `<MANIFEST>` 자리에 `$RUN_DIR/manifest.txt` 내용을 한 줄도 바꾸지 않고 넣는다:

```
model: opus (reason: audit)
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

- 출력의 `SKILL: <이름> channel=<채널> status=<상태>` 줄(업데이트 가능·가져오기 실패)을 그대로 보고한다.
- **적용은 자동이 아니다** — `update.py --apply` 는 SKILL.md 를 통째로 바꾸고 대상이 claude-forge 정본이며,
  `/skill-advisor --update --apply` 는 CSR #1806 결정 전 금지된 `--listing-audit --apply` 를 자동 실행한다.
  적용은 사용자 승인 후 claude-forge 작업 트리 + PR 에서 `update.py <skill> --apply` 를 직접 호출하는 별도 단계다.
  skill-advisor 자체는 #1806 결정까지 고정(변경 없음).

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
# 기한인 부분만(--force 는 여섯 부분 전부):
#  P-A 고정 범위 감사 — 위 4단계 → $RI ingest-audit --run-dir "$RUN_DIR" --part A
#  P-B 스킬 업데이트   — bash "$AR" update-check > "$T/upd.txt"; $RI ingest-update --file "$T/upd.txt"
#  P-C 업데이트 채널   — $RI scan-channels        (내장 plugins 채널 + channels.json 의 log_lines·stamp_age 채널)
#  P-D 설치 진단       — $RI ingest-doctor        (claude doctor, 읽기 전용, 60초 상한)
#  P-E 순환 전체 감사  — $RI plan-shards → 조각마다: pre --shard <manifest> → 감사 에이전트 → post → ingest-audit --part E → cover --run-dir … --shard N
#                         (AUDIT_INCOMPLETE 조각은 plan-shards --split N 으로 반으로 나눠 한 번 다시)
#  P-F 안 쓰는 확장    — $RI scan-unused          (~/.claude.json 의 skillUsage·pluginUsage 두 키만 읽는다 — 그 파일엔 자격증명도 있다)
#  한 부분을 아예 못 돌렸으면: $RI part-fail --part X --reason "<사유>"
$RI status --check-refs --run <RUN_ID>   # 처분이 끝날 때까지 반복
```

- P-E 범위 = 공식 `/doctor prompt-audit` 기본 범위(설정 폴더의 CLAUDE.md·rules·skills·commands·agents·output-styles) + `channels.json` 의
  `project_roots` 각 루트의 CLAUDE.md·CLAUDE.local.md·AGENTS.md·`.claude/{rules,skills,commands,agents,output-styles}`. 월 60만 자(7만5천 자 조각 8개),
  그중 30만 자 이상은 한 번도 감사 안 된 파일 → 가장 오래된 파일에, 나머지는 바뀐 파일에. 7만5천 자보다 큰 파일은 줄 범위 조각으로 나눠 여러 달에 걸쳐 덮는다.
  `plan-shards` 는 매번 「미감사 파일 수·최대 감사 경과일」을 출력하고, 목록에 없는 프로젝트 루트(`discover_dirs` 2단계 아래)나 사라진 루트는 `unknown` 항목이 된다.
- 조각(`경로#L시작-끝`)의 `COVERED` 는 주어진 끝 줄을 맞혀야 하므로 「열었다」 증거가 통째 파일보다 약하다(범위를 알려 준다).

**처분** — `$RI dispose <id>... --disp <종류> …` (여러 id 를 한 번에, 하나라도 규칙 위반이면 아무것도 안 쓴다):

| 처분 | 필요한 것 | 받지 않는 경우 |
|---|---|---|
| `fixed` | `--ref` = 커밋 sha · PR URL · `CSR #N c#M`(그 글의 댓글로 확인) | 감사 지적은 그 파일에 인용문이 남아 있으면 거부 · `part_failed` 는 같은 run 의 뒤 PASS 행 `ts` 만 |
| `task` | `--ref "CSR #N"` — 그 글 본문/댓글에 항목 id 가 그대로 있어야 함 | 게시판 접속 불가면 거부 |
| `dismissed` | `--reason` 20자 이상 | 허용 종류만: 감사 지적(high 제외)·update-available·unused-extension·plugin-version-changed·unclassified. 감사 지적의 기각은 그 파일의 sha256 에 묶여, 파일이 바뀌면 다시 열린다 |
| `deferred` | `--goal --deadline(YYYY-MM-DD, 90일 안) --method --revert` 넷 다 | 항목당 한 번만 · sev=high 불가 |
| `verified` | `--reason` 에 근거(명령과 출력 줄) 20자 이상 | `unknown`·`unobserved_plugin` 은 세션이 닫지 못한다 — 다음 스캔이 원천을 다시 읽어야 도구가 `fixed recheck:<run>` 을 쓴다 |

| 항목 종류 | 세션이 할 일 |
|---|---|
| 감사 지적 high | 같은 세션에 `fixed` 또는 `task` |
| 감사 지적 medium/low | 이번 묶음에서 `fixed`, 사유 있는 `dismissed`, 또는 `deferred` |
| claude-forge·memory-health·skill-advisor 수정 | 저장소마다 작업 트리 1개·PR 1개, 병합 승인은 실행 끝에 한 번 |
| 개인 로컬 파일 수정 | 백업 후 직접 수정 |
| 소유자만 정할 것(돈·권한·자격증명·비가역·취향) · doctor 권한 규칙 경고 | 이번 달 후속 CSR 에 `task`, 그 글에 `waiting` 태그 |
| 스킬 업데이트 가능 | 상류 diff 를 읽고 claude-forge 작업 트리에서 `update.py <skill> --apply` + PR, 또는 `dismissed`(일부러 갈라 둔 로컬 수정) |
| 플러그인 판 바뀜 | `claude plugin list --json` 에서 오류 없이 켜져 있는지 보고 `verified` |
| 자동 갱신 마켓 14일 넘게 안 갱신 | `claude plugin marketplace update <이름>` 후 다시 확인·기록 |
| `unobserved_plugin`(자동 갱신 꺼짐 + 45일 안 상류 관찰 없음) | 상류를 확인하는 채널의 관찰 규칙에 넣거나 자동 갱신을 켠다 — 다음 스캔이 닫는다 |
| 실행기 멈춤(`runner-stale`) | `launchctl list`·로그·rc 로 진단, sudo 없이 고칠 수 있으면 고치고 아니면 소유자 `task` |
| `part_failed` | 같은 run 에서 그 부분을 다시 돌려 PASS → `fixed`(그 행 ts). 안 되면 `task` — 실행은 종료 코드 4(완료 아님)로 끝나고 다음 세션에 다시 기한 |
| `cursor_reset` | 로그를 처음부터(교체됐으면 옛 파일도) 읽어 빠진 사건을 받아들이고 `verified` |
| `unclassified` | 채널의 사건/무시 정규식을 보강하고 `verified`(근거=정규식), 또는 `dismissed` |
| `orphaned_task`·`unlinked_task` | 다시 처분 — 새 `task` 또는 그 CSR 에 id 댓글 추가 |

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

## Optimizer: MEMORY.md 줄 수 최적화 (`--fix`)

### 전제 조건
- hook(memory-line-check.sh)이 **≥ 160줄 또는 ≥ 20,000문자** 경고를 발생시킨 경우에 실행 권장 (CSR #1825: 단위=문자)
- ★ 캡 단위는 **문자**다(CSR #1825 행동실측) — 한글 비율이 높아도 바이트가 먼저 캡에 닿지 않으며, 한글은 캡에서 오히려 여유를 준다. 판정은 **문자·줄** 두 축으로만 한다
- MEMORY.md는 Scanner(`--scan`) 스캔 대상에서 제외 (이 파일만 Optimizer 적용)

### 실행 단계 (7단계)

**1단계 — 진단**
```bash
MEMORY_DIR="${CLAUDE_MEMORY_DIR:?'CLAUDE_MEMORY_DIR is not set'}"
wc -l "${MEMORY_DIR}/MEMORY.md"
# 문자 수(UTF-16 code unit) — 바이트(wc -c)가 아니다 (CSR #1825)
MH_T="${MEMORY_DIR}/MEMORY.md" python3 -c 'import os
t=open(os.environ["MH_T"],encoding="utf-8",errors="replace").read()
print(sum(2 if ord(c)>0xFFFF else 1 for c in t))'
```
현재 줄 수와 문자 수를 출력한다.

**2단계 — 분석** (CSR #962: 버전 문자열 grep → drift-check 기반 정합 검증으로 교체)
```bash
RULES_FILE="${MEMORY_DIR}/memory-health-rules.md"
DRIFT="$HOME/.claude/skills/memory-health/scripts/memory-rules-drift-check.sh"
# rules.md 존재 확인
[ -r "$RULES_FILE" ] || { echo "❌ Rules file not found: $RULES_FILE" >&2; exit 1; }
# 정합 검증: 버전 문자열(위조·stale fork 통과 가능)이 아니라 content drift로 판정.
# 기대 버전은 하드코딩하지 않고 번들 템플릿에서 파생(H-3 단일 소스).
bash "$DRIFT" --check || echo "⚠ rules 드리프트 감지 — 위 안내 확인 후 진행 (silent pass 금지)"
```
- **Fix B**: `# version:` 줄은 사람이 읽는 보조 마커로만 사용. 정합의 권위는 drift-check(axis0 canonical↔번들 / axis1 활성본↔base / axis2 번들 version)에 있다. 버전만 올린 stale fork는 axis0/axis2에서 잡힌다.
- **H-3**: 기대 버전을 SKILL.md에 하드코딩하지 않는다(과거 `RULES_VERSION_REQUIRED="1.1.0"` 제거). 번들 템플릿의 `# version:`이 단일 소스.

판단 기준 **R1~R10**(memory-health-rules.md 의 R 절 전부)을 로드하여 최적화 후보를 식별한다.
즉흥적 판단 금지 — 반드시 rules 파일의 기준을 적용한다.

**3단계 — 제안 (dry-run)**
- 후보별 예상 변경 내용 출력
- 적용 후 예상 줄 수 출력
- `--fix --json` 모드인 경우: 위 JSON 스키마로 출력 후 **즉시 종료** (4~7단계 건너뜀)
- 사용자 확인 대기

**4단계 — 승인**
사용자가 명시적으로 수락해야 5단계로 진행한다.
묵시적 동의 불가 ("좋네요", "ㅇㅇ" 단독은 재확인 요청).

**5단계 — 백업 (hard stop 적용)**
```bash
~/.claude/hooks/memory-backup.sh
BACKUP_EXIT=$?
if [ $BACKUP_EXIT -ne 0 ]; then
  echo "❌ Backup failed (exit $BACKUP_EXIT). Aborting." >&2
  echo "For recovery: git log --oneline -5" >&2
  exit 1
fi
```
백업 실패 시 6단계로 진입 불가.

**6단계 — 실행**
승인된 변경 사항을 MEMORY.md에 적용한다.
Scanner 핸들러와 공유 상태(글로벌 변수, 파일 락) 없음.

**7단계 — 검증 (의무)** — 줄 수 + 문자 수 동시 검증

```bash
LINES=$(wc -l < "${MEMORY_DIR}/MEMORY.md")
# ★ 판정 축은 문자(UTF-16 code unit)다. 바이트가 아니다 (CSR #1825 행동실측).
CHARS=$(MH_T="${MEMORY_DIR}/MEMORY.md" python3 -c 'import os
t=open(os.environ["MH_T"],encoding="utf-8",errors="replace").read()
print(sum(2 if ord(c)>0xFFFF else 1 for c in t))')

LINE_FAIL=0
CHAR_FAIL=0
[ "$LINES" -gt 140 ] && LINE_FAIL=1
[ "$CHARS" -gt 17500 ] && CHAR_FAIL=1

if [ "$LINE_FAIL" -eq 1 ] || [ "$CHAR_FAIL" -eq 1 ]; then
  echo "⚠ Verification failed: lines=${LINES}/140 chars=${CHARS}/17500. Further optimization needed." >&2
else
  echo "✅ Verification passed: lines=${LINES}/140 chars=${CHARS}/17500"
  # 200줄·25,000문자 cap 대비 cap×0.7 목표선 (우리 선택 — 플랫폼 권위 아님)
  ~/.claude/skills/memory-health/scripts/memory-health-log.sh \
    "F3" "MEMORY.md 최적화" "${BEFORE}줄" "${LINES}줄/${CHARS}문자"
fi
```

**8단계 — 게시판 #32 동기화 (의무, claude_fail #81 재발 방지)**

MEMORY.md를 변경했으므로 게시판 동기화 페이지(claude-docs #32, "MEMORY.md — Claude Code 동기화 페이지")도 갱신한다. **손동기화 금지** — 결정론적 생성기가 MEMORY.md에서 #32를 전체 자동 생성한다:

```bash
~/.claude/scripts/sync-memory-to-board.sh
SYNC_EXIT=$?
if [ "$SYNC_EXIT" -ne 0 ]; then
  echo "⚠ #32 동기화 실패 (exit $SYNC_EXIT) — 게시판 접근 확인 후 수동 재실행 필요: ~/.claude/scripts/sync-memory-to-board.sh" >&2
fi
```

> **이중 안전망 (defense-in-depth)**: PostToolUse hook `memory-sync-detect.sh`도 MEMORY.md 편집을 감지해 알림하나, 본 스킬은 mutation 주체이므로 **명시적으로** 동기화한다. drift 점검만 필요하면 `--check`(read-only). 패턴 상세·정직 범위(near-forcing advisory, 동시수정 best-effort): `feedback_source-derived-sync-forcing-function`.

### 완료 기준
- MEMORY.md 줄 수 ≤ 140 (`wc -l` 검증 통과)
- MEMORY.md **문자 ≤ 17,500** (UTF-16 code unit) — ★ CSR #1825: `wc -c` 바이트 판정은 **폐기**(한글에서 거짓 경고)
- **게시판 #32 동기화 완료** (`sync-memory-to-board.sh` exit 0, 또는 실패 시 사용자 보고) — claude_fail #81
- skill-audit.log에 실행 이력 기록

### ★ 주의 — 한글 다수 환경 (캡 단위 = 문자, CSR #1825)

**행동실측 (CSR #1825)**: 캡의 단위는 **바이트가 아니라 문자(UTF-16 code unit)** 다. 한글이 바이트를 키워도 캡에 먼저 닿지 않는다.

| 관측 | 결과 |
|---|---|
| 24,899자 (74,353B) | 전문 로드 |
| 25,099자 (74,951B) | **꼬리 절단** |
| 10,734자 (31,534**B**) | 전문 로드 — **바이트 캡 없음** |
| 302줄 (16,534자) | 절단 — 줄 캡 200 독립 실재 |
| 12,909 code point / 25,409 UTF-16단위 | **절단** — 단위는 UTF-16 code unit |

⇒ **한글은 바이트만 부풀릴 뿐 실제 캡에서는 오히려 여유를 준다.** 같은 의미를 한국어가 영어보다
적은 문자로 표현하므로, 문자 캡 아래에서는 **한글이 불리하지 않다**(번역을 캡 압박으로 정당화할 수 없다).

⚠ `wc -c` 로 판정하지 말 것 — 한글에서 3배로 부풀어 **거짓 경고**가 난다.
재검증 = `tests/cap-boundary-probe.sh` (행동 프로브). `strings` 재실측은 판별력이 없다 — 같은 축이기 때문이다.

---

## Scanner: MD 파일 크기 스캔 + 분리 (`--scan`)

### 전제 조건
- 스캔 대상: `memory/*.md` (MEMORY.md 제외)
- 측정 기준: Python `len()` 기준 문자 수 (bytes 아님)
- 임계: 10000자 초과 파일 (Phase F per-file cap 10000 tokens 정합, trader_log #199 2026-05-21)

### 실행 단계 (6단계)

**1단계 — 스캔**
```python
import os, glob
MEMORY_DIR = os.environ.get("CLAUDE_MEMORY_DIR")
if not MEMORY_DIR:
    raise EnvironmentError("CLAUDE_MEMORY_DIR is not set")
results = []
for f in glob.glob(f"{MEMORY_DIR}/*.md"):
    if os.path.basename(f) == "MEMORY.md":
        continue  # Optimizer 전용 파일 — 제외
    content = open(f, encoding="utf-8").read()
    char_count = len(content)
    if char_count > 10000:
        results.append((f, char_count))
results.sort(key=lambda x: x[1], reverse=True)
for f, c in results:
    print(f"{c:,}자  {os.path.basename(f)}")
```

**2단계 — 측정 + 보고**
초과 파일 목록, 초과량, 섹션 헤더를 출력한다.

**3단계 — 제안**
각 파일의 자연스러운 분리 포인트를 제안한다.
분리 후 파일명 예시: `{원본명}-part2.md`

**4단계 — 선택 + 승인**
사용자가 분리할 파일과 분리 포인트를 선택한다.
명시적 수락 후 5단계로 진행.

**5단계 — 백업 + 실행 (2-phase commit)**

*단일 파일 분리:*
```
1. {원본명}-part2.md 생성
2. MEMORY.md 포인터 갱신 (동일 git commit)
   포인터 형식: "상세: {원본명}-part2.md [조건 트리거 1줄]"
3. 검증: len(part1) + len(part2) = len(원본) ± 3자 이내
4. 실패 시: git checkout -- {변경된 파일들}
```

*다중 파일 분리:*
```
Phase 1 (Prepare):
  - 모든 분리 파일을 {원본명}-part2.md.tmp로 생성
  - 포인터 갱신 내용을 {원본명}.patch로 준비
Phase 2 (Commit):
  - 모든 .tmp 파일 len() 합산 검증 통과 후
  - 일괄 rename (.tmp 제거)
  - 포인터 일괄 갱신
  - .patch 파일 삭제
실패 시:
  - .tmp 파일 전체 삭제
  - MEMORY.md 무수정 보장
  - .patch 파일 삭제
```

**Phase2 롤백 판정 (분기 명세)**
```
(a) rename 실패:
    .tmp 파일 전체 삭제, MEMORY.md 포인터 무변경 → 원상복구 완료
    복구 확인: ls "${CLAUDE_MEMORY_DIR}"/*.tmp 2>/dev/null \
              && echo "⚠ tmp 잔여 있음" || echo "✅ 정리 완료"

(b) rename 성공 + 포인터 갱신 실패:
    역방향 mv (part2 → 원본 복원) + git checkout -- MEMORY.md
    복구 확인: git diff --name-only

(c) len() 검증 실패 (양쪽 성공 후):
    git checkout -- {변경된 모든 파일}
    복구 확인: git status
```
각 분기에서 오류 메시지를 stderr에 출력한 뒤 exit 1.

**6단계 — 검증 + 로그**
분리 후 각 파일 len() 재측정. commit 성공 시에만 로그 기록:
```bash
~/.claude/skills/memory-health/scripts/memory-health-log.sh \
  "F4" "${FILE} 분리" "${BEFORE}자" "${AFTER1}자 + ${AFTER2}자"
```

### 완료 기준
- 모든 처리 파일이 10000자 이하 (Phase F per-file cap 정합)
- MEMORY.md 포인터 갱신 완료 + 인덱스 일관성 검증
- skill-audit.log에 실행 이력 기록

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

## Rules Checker: 자동 로드 파일 크기 검사 (`--rules`)

### 전제 조건
- `CLAUDE_RULES_DIR` 환경변수가 절대 경로로 설정되어 있어야 한다 (미설정 시 exit 1)
- `CLAUDE_RULES_DIR` 설정: ① 권장 — `~/.zshrc` 등 shell profile에 `export CLAUDE_RULES_DIR=...` 직접 추가 · ② `install.sh` 실행 중 대화형 프롬프트(기본값 N)에서 저장을 선택하면 `~/.claude/da-tools/` 아래 `env.sh`가 생성되며 이를 source. 저장을 생략하면 `env.sh`는 생성되지 않으므로 ①을 사용
- 스캔 대상: `CLAUDE_RULES_DIR` 직접 자식 `.md` 파일만 (서브디렉토리 무시)
- 파일 수정 없음 (read-only) → 승인 게이트 없음

### 기능 범위 고지
이 기능은 **지정 디렉토리의 MD 파일 크기를 검사**한다.
실제 Claude Code가 해당 파일을 로드하는지 여부는 보장하지 않는다.

### 임계값 체계
| 등급 | 임계값 | 의미 |
|------|--------|------|
| OK | < 20,000자 | 정상 |
| WARN | 20,000 ~ 40,000자 | 조기 경고 (CRITICAL 50% 도달 시점) |
| CRITICAL | > 40,000자 | 자체 선택 임계 (Claude Code 공식 경고와 별개 — 공식 임계는 모델 컨텍스트 창에 비례, CHANGELOG 2.1.169) |

임계값 오버라이드: `CLAUDE_RULES_SIZE_WARN`, `CLAUDE_RULES_SIZE_CRITICAL` 환경변수

### 심볼릭 링크 정책
- symlink target을 한 번만 follow (최대 깊이 20)
- realpath() 해시셋으로 중복 제거 + 순환 감지 (결정적, 순서 무관)
- 순환 감지 시: WARN 출력 + 해당 항목 skip (exit 0)
- 깊이 초과 시: WARN 출력 + skip (exit 0)

### 실행 단계 (4단계)

**1단계 — 환경 확인**
```bash
CLAUDE_RULES_DIR 설정 여부 확인 → 미설정 시 exit 1 (설정 오류)
CLAUDE_RULES_DIR 디렉토리 존재 확인 → 없으면 exit 1 (설정 오류)
```

**2단계 — 스캔 (5초 wall-clock budget)**
`scripts/check-rules.sh`를 실행한다:
```bash
bash ~/.claude/skills/memory-health/scripts/check-rules.sh [--strict]
```
타임아웃 초과 시: 완료된 파일까지 출력 + 미처리 파일 목록 (최대 10개) + exit 0

**3단계 — 결과 출력**
```
=== Rules Checker ===
대상: /path/to/rules
주의: 지정 디렉토리 MD 파일 크기 검사 — 실제 Claude Code 로딩 여부 보장 안함
      서브디렉토리 무시 | 심볼릭 링크: follow once (최대 깊이 20)

🔴 CRITICAL    45,000자  huge-rule.md
🟡 WARN        25,000자  some-large-rule.md
✅ OK           4,000자  small-rule.md

📊 CRITICAL 1건 — 자체 임계 초과 (> 40,000자 · Claude Code 공식 경고 임계는 컨텍스트 창 비례)
   개선 방향:
   1. 파일 L3(핵심 요약 자동 로드) + L4(상세 온디맨드) 구조로 분리
   2. CLAUDE.md 자동 로드에서 제외 후 온디맨드 참조로 전환
```

**4단계 — audit 로그 (F5)**
```bash
memory-health-log.sh "F5" "rules-scan (read-only)" "CRITICAL=N" "WARN=M"
```

### Graceful 실패 정책

| 실패 유형 | 출력 레벨 | exit code |
|----------|----------|-----------|
| CLAUDE_RULES_DIR 미설정 | WARN + skip | **1** |
| 디렉토리 없음 | WARN + skip | **1** |
| 특정 파일 파싱 실패 | ℹ️ skip + 계속 | 0 |
| symlink 순환 감지 | ⚠ WARN + skip | 0 |
| symlink 깊이 초과 | ⚠ WARN + skip | 0 |
| 타임아웃 (기본) | partial result ⚠ + 미처리 목록 | 0 |
| 타임아웃 (--strict) | partial result ⚠ + 미처리 목록 | **2** |
| WARN 이상 (--strict) | 해당 출력 | **2** |
| CRITICAL 파일 존재 | CRITICAL 출력 | 0 (read-only) |

### `--strict` 모드
CI/CD 파이프라인용. WARN 이상 비정상 상황 발생 시 exit 2.
```bash
bash check-rules.sh --strict
```

### 완료 기준
- 스캔 결과 출력 완료
- skill-audit.log에 F5 이력 기록

---

## 프로젝트 CLAUDE.md(+분리 파일) 크기 모니터링 (READ-ONLY)

사용자 MEMORY.md(Optimizer 대상)와 별개로, **외부 프로젝트 CLAUDE.md와 그 분리 파일**(예: aria·kr-ai-trader)의 크기를 점검·경고한다. **읽기 전용 — 파일을 수정하지 않는다.** 실제 내용 최적화는 해당 도메인 워크플로우(ARIA/KRIS = `/trader-task`)로 수행한다 (MEMORY.md 캡은 개인 메모리용이라 프로젝트 문서에 부적합 + 도메인·foreign repo 경계).

```bash
bash ~/.claude/skills/memory-health/scripts/check-project-claudemd.sh [--strict]
```

- **대상 목록**(우선순위): `--list=<경로>` > `$CLAUDE_PROJECT_CLAUDEMD_LIST` > `~/.claude/da-tools/project-claudemd-paths.txt` (한 줄 = 절대경로 **또는 glob 패턴**, `#`·빈 줄 무시)
- **분리 파일 자동 포함**: 목록에 glob 패턴(예: `.../aria/CLAUDE*.md`)을 쓰면, 향후 CLAUDE.md를 분리(`CLAUDE-part2.md` 등)해도 **분리 파일이 자동으로 점검 대상에 포함**된다(realpath dedup). 도메인 워크플로우(`/trader-task`)가 분리 산출 시 별도 등록 불필요.
- **임계(자 수, Rules Checker 정합)**: OK<20,000 / WARN 20,000~40,000 / CRITICAL>40,000 (env `CLAUDE_PROJECT_MD_WARN`·`CLAUDE_PROJECT_MD_CRITICAL`)
- **graceful**: 목록 없음·볼륨 미마운트·매칭 0 = skip/경고 + exit 0 (비차단). `--strict` 시 WARN+ → exit 2 (CI용)
- **통합**: `/memory-health check` 기본 실행과 `--rules`에 포함 권장. CRITICAL 발견 시 사용자에 보고하되 **자동 수정 금지** — 도메인 워크플로우 안내만.

---

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
