---
name: memory-health
description: "메모리 파일 건강 상태 진단 + 최적화 (MEMORY.md Optimizer R1~R6 + memory/*.md Scanner + Rules Checker + CLAUDE.md 주기 감사)"
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
**CLAUDE.md 주기적 감사** (claude-md-management 연동, 30일 주기 자동 실행)를 제공한다.

> **연동 훅**: 작업 단계 완료 시 `revise-claude-md-stop.sh`(Stop) + `revise-claude-md-inject.sh`(UserPromptSubmit)이
> `/revise-claude-md`를 자동 주입한다. — 별도 설치 불필요 (settings.json 등록 완료)

## 사용법

### v2 명령 구조 (Spec — CSR #656 DA Tier 1 C-7 정합, 2026-05-19)

> **상태**: spec 박제 완료. 구현은 후속 PR (인계 md `~/.claude/da-archive/memory-health-redesign-handoff-2026-05-19.md` 참조). v1 명령은 backward 호환으로 계속 동작.

```
/memory-health check         → READ-ONLY 진단 (hook-safe, 파일 변경 ❌)
                              exit 0=정상, 1=warn, 2=critical
/memory-health fix [--R1...] → Mutating Optimizer (R1~R8, 명시 R번호) — CSR #807 R7·R8 추가
/memory-health scan          → Scanner (memory/*.md 분리, 1회 승인)
/memory-health rules         → Rules Checker (자동 로드 파일, read-only)
/memory-health rules --strict → WARN 이상 exit 2
/memory-health catalog       → 지식 카탈로그 빌더 (3축 메타데이터 인덱스 재생성)
/memory-health fix --json    → dry-run JSON 출력
/memory-health --with-md     → CLAUDE.md 품질 감사 (모든 명령 병용)
```

**명령 경계 원칙 (DA C-7)**:
- **check** = READ-ONLY, hook-safe — 자동화 안전
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

기본값은 dry-run이므로 파일이 변경되지 않는다.

실행 흐름:
```
/memory-health         → ① dry-run 결과 출력
                          ② CLAUDE.md 주기 감사 (30일 경과 or 미실행 시 자동 → claude-md-improver 호출)
                          ℹ️  Rules Checker 미포함 — /memory-health --rules 또는 MEMORY_HEALTH_DEFAULT_RULES=true
/memory-health --fix   → dry-run 결과 출력 → 승인 게이트 → 실행
/memory-health --scan  → 스캔 결과 출력   → 승인 게이트 → 실행
/memory-health --rules → Rules Checker 실행 (파일 변경 없음, 게이트 없음)
/memory-health --with-md → CLAUDE.md 감사 강제 실행 (주기 미경과도 실행)
```

### --fix --json 모드

3단계(dry-run 결과)까지 실행 후 JSON으로 출력하고 **즉시 종료**한다. 파일 변경 없음.

출력 스키마:
```json
{
  "status": "ok | needs_action",
  "current_lines": 0,
  "target_lines": 180,
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
| hook | `revise-claude-md-stop.sh` | 작업 완료 감지 → pending 생성 | 없음 |
| hook | `revise-claude-md-inject.sh` | pending 확인 → /revise-claude-md 자동 주입 | 없음 |
| skill | `/memory-health` | 대화형 수동 실행 + 실제 최적화 + 주기적 CLAUDE.md 감사 | 파일 변경 |

hook은 경고·주입만 한다. 실제 수정은 이 스킬이 담당한다.

---

## CLAUDE.md 주기적 감사 (기본 dry-run에 통합)

> **전제 조건**: `claude-md-management` 플러그인 설치 필요.
> `claude plugin install claude-md-management` 후 사용 가능.

`/memory-health` 기본 실행(dry-run) 종료 후 자동으로 아래 절차를 수행한다.

### 타임스탬프 기반 주기 판정

```bash
AUDIT_LAST="$HOME/.claude/da-tools/claude-md-audit-last"
AUDIT_INTERVAL_DAYS=30   # 기본 30일, CLAUDE_MD_AUDIT_INTERVAL로 오버라이드 가능

if [ ! -f "$AUDIT_LAST" ]; then
  DAYS_SINCE=9999         # 한 번도 실행 안 됨
else
  NOW=$(date +%s)
  LAST=$(cat "$AUDIT_LAST")
  DAYS_SINCE=$(( (NOW - LAST) / 86400 ))
fi
```

### 판정 결과

| 조건 | 동작 |
|------|------|
| `DAYS_SINCE >= 30` 또는 파일 없음 | `claude-md-improver` 스킬 호출 → CLAUDE.md 품질 감사 실행 |
| `DAYS_SINCE < 30` | "✅ CLAUDE.md 감사 최신 (N일 전)" 출력 후 skip |
| `--with-md` 플래그 명시 | 30일 미경과여도 강제 실행 |

### 감사 완료 후 타임스탬프 갱신

```bash
date +%s > "$HOME/.claude/da-tools/claude-md-audit-last"
```

### `claude-md-improver` 호출 시 수행 내용

1. 현재 작업 디렉토리의 `CLAUDE.md` 파일 탐색 (`find . -name "CLAUDE.md"`)
2. 각 파일에 대해 품질 평가 (A~F 등급, 6개 기준 × 100점)
3. 품질 보고서 출력 (이슈 + 권장 추가 사항)
4. **파일 변경 없음** — 보고서만 출력, 실제 수정은 사용자 승인 필요

CLAUDE.md가 없는 경우:
```
ℹ️  CLAUDE.md 없음 — 현재 디렉토리에 CLAUDE.md가 없습니다.
   프로젝트 루트에서 실행하거나 CLAUDE.md를 먼저 생성하세요.
```

---

## Optimizer: MEMORY.md 줄 수 최적화 (`--fix`)

### 전제 조건
- hook(memory-line-check.sh)이 **≥ 180줄 또는 ≥ 24,500 bytes** 경고를 발생시킨 경우에 실행 권장
- 한글 비율 14%+ 환경에서는 **바이트가 줄 수보다 먼저 캡 도달** (CSR #806 입증). 줄 수만 추적 시 silent truncation 위험
- MEMORY.md는 Scanner(`--scan`) 스캔 대상에서 제외 (이 파일만 Optimizer 적용)

### 실행 단계 (7단계)

**1단계 — 진단**
```bash
MEMORY_DIR="${CLAUDE_MEMORY_DIR:?'CLAUDE_MEMORY_DIR is not set'}"
wc -l "${MEMORY_DIR}/MEMORY.md"
wc -c "${MEMORY_DIR}/MEMORY.md"
```
현재 줄 수와 바이트 수를 출력한다.

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

판단 기준 **R1~R8**을 로드하여 최적화 후보를 식별한다 (R7·R8 = CSR #807 추가).
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

**7단계 — 검증 (의무)** — CSR #807: 줄 수 + 바이트 동시 검증

```bash
LINES=$(wc -l < "${MEMORY_DIR}/MEMORY.md")
BYTES=$(wc -c < "${MEMORY_DIR}/MEMORY.md")

LINE_FAIL=0
BYTE_FAIL=0
[ "$LINES" -gt 180 ] && LINE_FAIL=1
[ "$BYTES" -gt 24500 ] && BYTE_FAIL=1

if [ "$LINE_FAIL" -eq 1 ] || [ "$BYTE_FAIL" -eq 1 ]; then
  echo "⚠ Verification failed: lines=${LINES}/180 bytes=${BYTES}/24500. Further optimization needed." >&2
else
  echo "✅ Verification passed: lines=${LINES}/180 bytes=${BYTES}/24500"
  # 200줄·25KB cap 대비 20줄·1100바이트 안전 마진 (hook 경고 임계값과 일치)
  ~/.claude/skills/memory-health/scripts/memory-health-log.sh \
    "F3" "MEMORY.md 최적화" "${BEFORE}줄" "${LINES}줄/${BYTES}바이트"
fi
```

### 완료 기준
- MEMORY.md 줄 수 ≤ 180 (`wc -l` 검증 통과)
- MEMORY.md 바이트 ≤ 24,500 (`wc -c` 검증 통과) — **CSR #807 신설**
- skill-audit.log에 실행 이력 기록

### 주의 — 한글 다수 환경 (CSR #807 박제, S4)
한국어는 영문 대비 1.3~1.5배 토큰을 소비하므로 한글 비율 14%+ 환경에서는 **줄 수보다 바이트가 먼저 25KB 캡 도달**한다.
줄 수만 추적할 경우 25KB 캡 초과 silent truncation 발생 가능 (CSR #806 실증: 193줄 = 25,849 bytes = 캡 249 bytes 초과 상태에서 자동 로드 일부 truncate 위험). 줄 수와 바이트 동시 추적 필수.

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
> 3. R1~R6 적용 — 실제 파일 변경
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
| CRITICAL | > 40,000자 | Claude Code 성능 경고 발생 중 |

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

🔴 CRITICAL    53,400자  ai-role-assignment-core.md
🟡 WARN        25,000자  some-large-rule.md
✅ OK           4,000자  small-rule.md

📊 CRITICAL 1건 — Claude Code 성능 경고 발생 중 (> 40,000자)
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

## CLAUDE.md 통합 (`--with-md`)

> **전제 조건**: `claude-md-management` 플러그인이 설치되어 있어야 한다.
> 설치: `claude plugin install claude-md-management`
> 확인: `claude plugin list`

`--with-md`는 다른 플래그와 병용 가능하다: `/memory-health --with-md`, `/memory-health --fix --with-md`, `/memory-health --scan --with-md`.

### 실행 흐름 (3 Phase)

**Phase A — memory health (기존 동작)**
- 기존 dry-run / `--fix` / `--scan` / `--rules` 로직 그대로 수행
- Phase A 완료 후 Phase B로 진행

**Phase B — CLAUDE.md 품질 감사 (`claude-md-improver` 스킬 호출)**

현재 작업 디렉토리의 CLAUDE.md 파일을 감사한다:

```bash
# CLAUDE.md 파일 존재 여부 사전 확인
find . -name "CLAUDE.md" -o -name ".claude.local.md" 2>/dev/null | head -10
```

파일이 존재하면 `claude-md-improver` 스킬의 Phase 1~3(Discovery → Quality Assessment → Quality Report)을 실행한다.
- 품질 점수 출력 (A~F 등급)
- 이슈 및 권장 추가사항 출력
- **이 단계에서는 파일을 수정하지 않는다** (보고만)

파일이 없으면:
```
ℹ️  CLAUDE.md 없음 — 현재 디렉토리에 CLAUDE.md가 없습니다.
   프로젝트 루트에서 실행하거나 CLAUDE.md를 먼저 생성하세요.
```

**Phase C — 세션 학습 캡처 제안**

Phase B 완료 후 다음 안내를 출력한다:

```
💡 세션 학습 캡처
   이번 세션에서 발견한 내용을 CLAUDE.md에 반영하려면:
   /revise-claude-md
   (claude-md-management 플러그인 설치 시 사용 가능)
```

`--fix --with-md` 조합인 경우: Phase A의 `--fix` 완료 후 Phase B→C 순서로 이어진다.

### --with-md 완료 기준
- Phase A: 기존 모드별 완료 기준과 동일
- Phase B: CLAUDE.md 품질 보고서 출력 완료 (파일 변경 없음)
- Phase C: 세션 학습 캡처 안내 출력 완료

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
| dry-run (기본) | 불필요 | 자동 승인 범위 (파일 변경 없음) |
| `--fix` | 1회 필요 | MEMORY.md 내용 변경 |
| `--scan` | 1회 필요 | memory/*.md 내용 변경 |
| `--rules` | 불필요 | read-only, 파일 변경 없음 |
| `catalog` | 불필요 | read-only (catalog/ 인덱스 2파일만 생성, 원본 무변경) |
| `--fix --json` | 불필요 | dry-run과 동일, JSON 출력 후 종료 |
| `--with-md` (Phase B) | 불필요 | claude-md-improver 보고만 (파일 변경 없음) |
| `--with-md` Phase B→수정 | 1회 필요 | claude-md-improver 수정 적용 시 별도 승인 |

---

## CHANGELOG

| 일자 | 변경 |
|------|------|
| 2026-05-23 | **CSR #807 — 25KB 바이트 캡 + 한글 비율 모니터링 + R7~R8 룰 추가**. memory-line-check.sh에 BYTE_COUNT + 한글 비율 측정 추가 (`CLAUDE_MEMORY_BYTE_WARN=24500` env 지원). memory-health-rules.md R7 자연어 포인터 우선 + R8 path-scoped rules 활용 신설. SKILL.md 7단계 검증을 줄 수 + 바이트 동시 검증으로 확장. rule_version 1.0.0 → 1.1.0. 한글 14%+ 환경 byte cap silent truncation 주의 박제. 근거: CSR #806 (193줄 = 25,849 bytes = 캡 249 bytes 초과 실증) + Anthropic 공식 문서 RAG (ChatGPT·Claude Web 강한 합의). |
| 2026-05-19 | CSR #656·#658·#659·#671·#779 — R6 Sidecar Fingerprint + 재설계 Phase C·D 시리즈. |
