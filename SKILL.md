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
Optimizer (MEMORY.md 줄 수 최적화)와 Scanner (memory/*.md 파일 크기 분리)를 제공한다.

## 사용법

```
/memory-health          → 진단만 (dry-run, 자동 승인 범위)
/memory-health --fix    → Optimizer 실행: MEMORY.md 줄 수 최적화 (승인 게이트 1회)
/memory-health --scan   → Scanner 실행: memory/*.md 파일 크기 스캔 + 분리 (승인 게이트 1회)
/memory-health --fix --json  → dry-run 결과를 JSON 형식으로 출력 (자동화·파이프라인용)
```

기본값은 dry-run이므로 파일이 변경되지 않는다.

실행 흐름:
```
/memory-health         → dry-run 결과 출력 (게이트 없음)
/memory-health --fix   → dry-run 결과 출력 → 승인 게이트 → 실행
/memory-health --scan  → 스캔 결과 출력   → 승인 게이트 → 실행
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

`CLAUDE_MEMORY_DIR` 환경변수가 설정되어 있어야 한다. 설정 방법은 `install.sh` 참조.

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
| hook | `memory-line-check.sh` | 자동 감시 + 경고만 | 없음 |
| skill | `/memory-health` | 대화형 수동 실행 + 실제 최적화 | 파일 변경 |

hook은 경고만 출력한다. 실제 수정은 이 스킬이 담당한다.

---

## Optimizer: MEMORY.md 줄 수 최적화 (`--fix`)

### 전제 조건
- hook(memory-line-check.sh)이 ≥ 180줄 경고를 발생시킨 경우에 실행 권장
- MEMORY.md는 Scanner(`--scan`) 스캔 대상에서 제외 (이 파일만 Optimizer 적용)

### 실행 단계 (7단계)

**1단계 — 진단**
```bash
MEMORY_DIR="${CLAUDE_MEMORY_DIR:?'CLAUDE_MEMORY_DIR is not set'}"
wc -l "${MEMORY_DIR}/MEMORY.md"
wc -c "${MEMORY_DIR}/MEMORY.md"
```
현재 줄 수와 바이트 수를 출력한다.

**2단계 — 분석**
```bash
RULES_VERSION_REQUIRED="1.0.0"
RULES_FILE="${MEMORY_DIR}/memory-health-rules.md"
# rules.md 존재 + 버전 정합 검증
[ -r "$RULES_FILE" ] || { echo "❌ Rules file not found: $RULES_FILE" >&2; exit 1; }
grep -q "^# version: $RULES_VERSION_REQUIRED" "$RULES_FILE" \
  || { echo "❌ Rules version mismatch (required: $RULES_VERSION_REQUIRED)" >&2; exit 1; }
```
판단 기준 R1~R5를 로드하여 최적화 후보를 식별한다.
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

**7단계 — 검증 (의무)**
```bash
LINES=$(wc -l < "${MEMORY_DIR}/MEMORY.md")
if [ "$LINES" -gt 180 ]; then
  echo "⚠ Verification failed: ${LINES} lines (target ≤ 180). Further optimization needed." >&2
else
  echo "✅ Verification passed: ${LINES} lines (target ≤ 180)"
  # 200줄 cap 대비 20줄 안전 마진 (hook 경고 임계값 180과 일치)
  ~/.claude/skills/memory-health/scripts/memory-health-log.sh \
    "F3" "MEMORY.md 최적화" "${BEFORE}줄" "${LINES}줄"
fi
```

### 완료 기준
- MEMORY.md 줄 수 ≤ 180 (`wc -l` 검증 통과)
- skill-audit.log에 실행 이력 기록

---

## Scanner: MD 파일 크기 스캔 + 분리 (`--scan`)

### 전제 조건
- 스캔 대상: `memory/*.md` (MEMORY.md 제외)
- 측정 기준: Python `len()` 기준 문자 수 (bytes 아님)
- 임계: 5000자 초과 파일

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
    if char_count > 5000:
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
- 모든 처리 파일이 5000자 이하
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

## 승인 정책 요약

| 모드 | 승인 필요 | 근거 |
|------|----------|------|
| dry-run (기본) | 불필요 | 자동 승인 범위 (파일 변경 없음) |
| `--fix` | 1회 필요 | MEMORY.md 내용 변경 |
| `--scan` | 1회 필요 | memory/*.md 내용 변경 |
| `--fix --json` | 불필요 | dry-run과 동일, JSON 출력 후 종료 |
