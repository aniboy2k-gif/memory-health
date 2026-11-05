# /memory-health — Optimizer 절차 (reference)

## Contents
- Optimizer: MEMORY.md 줄 수 최적화 (`--fix`)

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
