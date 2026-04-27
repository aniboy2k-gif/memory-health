<!--
  동기화 정책: README.ko.md는 README.md(영문)를 원본으로 한다.
  README.md 수정 시 이 파일도 함께 수정해야 한다.
  PR 체크리스트: README.md를 수정했다면 아래를 확인하세요.
    - [ ] README.ko.md에도 동일 내용이 반영되었습니까?
-->

# memory-health

[![ShellCheck](https://github.com/aniboy2k-gif/memory-health/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/aniboy2k-gif/memory-health/actions/workflows/shellcheck.yml)

> 한국어 | [English](README.md)
> **정본: README.md (영문). 이 파일(README.ko.md)은 번역본으로 내용이 최신 버전과 다를 수 있습니다.**

> 🌐 **스킬 파일**: [`SKILL.md`](SKILL.md) (한국어, 기본) · [`SKILL.en.md`](SKILL.en.md) (영어)
> 대화 언어를 자동 감지해서 맞는 파일로 출력한다.
> 영어로 대화하려면 Claude에게 `SKILL.en.md`를 직접 참조하도록 안내하면 된다.

> **메모리는 쌓인다. 컨텍스트는 제한된다. memory-health가 Claude를 예리하게 유지한다.**

Claude Code의 커스텀 메모리 파일을 진단하고 정리하는 스킬 — 메모리가 조용히 잘려나가기 전에 먼저 처리한다.

---

## 이 스킬의 대상

Claude Code를 쓰면서 **직접 메모리 파일을 관리하는 커스텀 시스템**을 구축한 사람을 위한 스킬이다. 이런 시스템은 보통 이렇게 생겼다:

- `MEMORY.md`가 세션 시작 시 Claude에 로드되는 인덱스 역할
- `memory/*.md` 파일이 실제 메모리 내용을 저장
- 로딩 메커니즘이 `MEMORY.md`에 **200줄 hard limit(절대 제한)**을 적용

**문제**: `MEMORY.md`가 200줄을 넘으면 그 이후 내용이 조용히 누락된다. 오류 메시지도 없다. "어제까지 기억하던 설정을 오늘 Claude가 모른다고 하면?" — 그게 이 문제다.

**해당 여부 확인**: `~/.claude/hooks/memory-line-check.sh`가 존재하고 MEMORY.md가 ≥180줄 경고를 발생시키고 있다면 이 스킬의 대상이다.

Claude Code 공식 메모리 기능을 사용 중이라면 이 스킬은 적용되지 않는다.

---

## 문제

| 제약 | 유형 | 값 | 근거 |
|------|------|-----|------|
| MEMORY.md 줄 수 한계 | **Hard limit** | 200줄 | 컨텍스트 주입 메커니즘 설계 제약 |
| MEMORY.md 안전 목표 | 안전 마진 | 180줄 | 200 − 20줄 버퍼 (hook 경고 임계와 정렬) |
| memory/*.md 크기 임계 | **경험칙** | 5,000자 | 실제 운영에서 컨텍스트 혼잡이 관찰된 수치 |

`MEMORY.md`가 200줄을 넘으면 그 이후 내용은 **조용히 잘린다**. 오류 메시지도 없다. 이 사실을 깨달았을 때는 이미 메모리가 없어진 뒤다.

## 해결책

`/memory-health`는 메모리가 사라지기 전에 먼저 실행된다 — 파일 크기를 진단하고, 한계에 가까워지면 경고하고, 안전한 방식으로 정리해준다.

---

## 요구 사항

스킬 사용 전 다음 항목을 준비한다:

- **Claude Code** (스킬 실행 권한 필요)
- **Git** — `--scan` 모드의 롤백에 필요; 대상 파일이 git 추적 중이고 working tree가 clean해야 한다 (`git status --porcelain` 및 대상 파일의 `git ls-files` 확인 권장)
- **`memory-health-rules.md`** — 메모리 디렉토리에 존재해야 함; MEMORY.md 항목의 제거·압축 후보를 결정하는 R1–R5 규칙 정의
- **`memory-backup.sh`** 훅(특정 이벤트에 자동으로 실행되는 스크립트) — 실행 가능한 상태로 구성; `--fix` 모드에서 백업이 실패하면 실행 자체를 막는 안전장치 역할

### 초기 설정 (최초 1회)

`install.sh`를 실행하면 올바른 메모리 디렉토리를 자동 감지하고 `CLAUDE_MEMORY_DIR`을 설정한다:

```bash
bash install.sh
```

또는 수동으로 설정한 뒤 필수 파일을 생성한다:

```bash
export CLAUDE_MEMORY_DIR="<your-memory-dir>"   # 감지 방법은 install.sh 참조
touch "$CLAUDE_MEMORY_DIR/violation-archive.md" && echo "created: violation-archive.md"
touch "$CLAUDE_MEMORY_DIR/skill-audit.log"      && echo "created: skill-audit.log"
```

> **`$(whoami)` 대신 `install.sh`를 쓰는 이유?** Claude Code는 사용자 이름이 아닌 작업 디렉토리의 절대 경로 인코딩으로 프로젝트 경로를 생성한다. 단순한 사용자 이름 치환은 비표준 환경에서 오동작한다. `install.sh`가 실행 시점의 실제 경로를 감지한다.

> `violation-archive.md`는 감사 시스템이 기록하는 규칙 위반 이력을 저장한다. 명시적으로 초기화해서 잘못된 위치에 파일이 생기는 것을 막는다.

---

## 기능

| 기능 | 플래그 | 파일 변경 | 설명 |
|------|--------|:--------:|------|
| 진단 | *(기본값)* | 없음 | Dry-run(실제 변경 없이 결과만 미리 보기): 현재 줄/문자 수 보고 |
| 최적화기 | `--fix` | **있음** | MEMORY.md를 ≤ 180줄로 압축 (승인 게이트 1회) |
| 스캐너 | `--scan` | **있음** | 5,000자 초과 파일 탐지 + `*-part2.md`로 분리 (승인 게이트 1회) |
| JSON 출력 | `--fix --json` | 없음 | Dry-run 결과를 JSON으로 출력 (3단계 후 종료, 파일 변경 없음) |

---

## 사용법

```
/memory-health          → 진단만 (dry-run, 승인 불필요)
/memory-health --fix    → 최적화기: MEMORY.md 줄 수 압축 (승인 게이트 1회)
/memory-health --scan   → 스캐너: 대형 메모리 파일 분리 (승인 게이트 1회)
/memory-health --fix --json  → JSON dry-run 출력 (Propose 단계 후 종료)
```

> **`--fix`와 `--scan`은 파일을 변경한다.** 실행 전 자동으로 백업이 이루어지며, 문제가 생기면 `git checkout -- <파일>`로 복구할 수 있다.
> 플래그 없이 `/memory-health`만 실행하면 파일을 건드리지 않는 안전한 진단만 수행한다.

---

## 작동 방식

### 최적화기 (`--fix`): MEMORY.md 줄 수 관리

Hard stop(오류 시 즉시 중단하는 안전장치)이 포함된 7단계 파이프라인:

1. **진단** — 현재 줄 수·바이트 수 측정
2. **분석** — `memory-health-rules.md`에서 R1–R5 규칙 로드; 즉흥 판단 금지
3. **제안 (dry-run, 실제 변경 없이 결과 미리 보기)** — 후보 변경 내용과 예상 줄 수 출력 — *`--json` 플래그가 있으면 이 단계에서 JSON 출력 후 종료.*
4. **승인** — 명시적 확인 필요. "좋네요" 같은 감상 표현은 재확인 요청 발동
5. **백업** — `memory-backup.sh` 자동 실행; 실패 시 다음 단계 진입 불가
6. **실행** — 승인된 변경 사항을 MEMORY.md에 적용
7. **검증** — `wc -l ≤ 180` 검증; `skill-audit.log`에 결과 기록

**완료 기준**: `wc -l MEMORY.md ≤ 180` + 감사 로그 기록 (1–7단계 모두 완료 시).

### 스캐너 (`--scan`): memory/*.md 크기 관리

2-phase commit(여러 파일을 한 번에 원자적으로 바꾸는 방식 — 중간에 실패하면 전부 롤백)이 포함된 6단계 파이프라인:

1. **스캔** — 5,000자 초과 `memory/*.md` 파일 탐지 (MEMORY.md 제외)
2. **측정 + 보고** — 파일 목록, 문자 수, 섹션 헤더 출력
3. **제안** — 분리 지점 제안 (마크다운 섹션 헤더 또는 논리적 경계); 분리 파일명: `{원본명}-part2.md`
4. **선택 + 승인** — 분리 지점 선택; 명시적 확인 필요
5. **백업 + 실행 (2-phase commit)**:
   - Phase 1 (Prepare): 임시 파일 생성 + MEMORY.md 포인터 업데이트 준비 — 아직 아무것도 확정되지 않은 상태
   - Phase 2 (Commit): 분리가 손실 없이 됐는지 확인(±3자 허용 오차는 LF/CRLF 차이 때문) 후 한 번에 적용
   - 중간에 실패하면 변경된 모든 파일을 `git checkout`으로 자동 복구
6. **검증 + 로그** — 각 출력 파일 재측정; **commit 성공 시에만 감사 로그 기록**

**완료 기준**: 처리된 모든 파일 ≤ 5,000자 + MEMORY.md 포인터 갱신 + commit 성공 + 감사 로그 기록.

> **설계 의도**: 최적화기는 `memory-backup.sh`만으로 복구 (단일 파일). 스캐너는 여러 파일을 동시에 건드리므로 Git이 필요하다. 이 차이는 의도된 설계다.

---

## 역할 경계

| 구분 | 파일 | 역할 | 부작용 |
|------|------|------|--------|
| Hook | `memory-line-check.sh` | 자동 감시 + 경고만 | 없음 |
| Skill | `/memory-health` | 대화형 수동 실행 + 실제 최적화 | **파일 변경** |

hook은 경고만 한다. 실제로 파일을 고치는 건 이 스킬이다.

---

## 감사 로그

```
위치: ${CLAUDE_MEMORY_DIR}/skill-audit.log
형식: {ISO8601} | {기능} | {작업 요약} | {변경 전} → {변경 후}

예시:
  2026-04-21T20:00:00+0900 | F3 | MEMORY.md 최적화 | 195줄 → 142줄
  2026-04-21T20:10:00+0900 | F4 | project-fss.md 분리 | 25,190자 → 4,800자 + 4,200자
```

Rotate: 50KB 초과 시 `.old`로 자동 rotate. 최대 2세대 보존.

로그 경로는 `memory-health-log.sh`의 `$CLAUDE_MEMORY_DIR` 환경변수로 제어된다.

---

## 제약 사항

| 제약 | 내용 |
|------|------|
| **Single-session only** | 락 메커니즘 없음 — 여러 Claude 탭을 동시에 열면 파일 손상 가능 |
| **Local filesystem only** | 원격 동기화, 클라우드 스토리지 미지원 |
| **AI instruction file** | `SKILL.md`는 Claude가 런타임에 해석하는 LLM 지시 파일. 독립 실행 가능한 프로그램이 아님 |
| **Custom auto-memory only** | Claude Code 공식 기능이 아닌 특정 파일 기반 자동 메모리 패턴에서만 동작 |

---

## 파일 구조

```
~/.claude/skills/memory-health/
├── SKILL.md                          # 스킬 정의 및 파이프라인 명세
├── INTERFACES.md                     # 컴포넌트 계약 명세
├── memory-health-rules.md            # R1-R5 최적화 규칙 템플릿
├── install.sh                        # 초기 설정: 메모리 디렉토리 자동 감지 + CLAUDE_MEMORY_DIR 설정
└── scripts/
    ├── memory-health-log.sh          # 감사 로그 기록 + 자동 rotate
    └── memory-backup.sh              # 백업 샘플 (~/.claude/hooks/로 복사 후 사용)

# 외부 의존 파일 (이 저장소 외부):
~/.claude/hooks/
├── memory-line-check.sh              # 감시 훅: MEMORY.md >= 180줄 시 경고
└── memory-backup.sh                  # 백업 훅: --fix의 Hard Stop 게이트

${CLAUDE_MEMORY_DIR}/
├── MEMORY.md                         # 세션 인덱스 (최적화기가 관리)
├── memory-health-rules.md            # R1-R5 최적화 규칙 (필수)
├── skill-audit.log                   # 실행 이력
└── violation-archive.md              # 규칙 위반 이력 파일 (초기 설정에서 생성)
```

---

## 승인 정책

`--fix`나 `--scan`을 쓸 때는 파일이 바뀌기 전에 명시적 확인이 필요하다. "좋네요", "ㅇㅇ" 같은 반응은 재확인 요청을 발동시킨다 — 진행 의사가 분명히 드러나야 한다.

| 모드 | 승인 필요 | 유효한 승인 예시 |
|------|:--------:|----------------|
| dry-run (기본) | 불필요 | — |
| `--fix` | **필요** | "확정해주세요", "진행해주세요", "적용" |
| `--scan` | **필요** | "확정해주세요", "진행해주세요", "적용" |

감상 표현("좋네요", "ㅇㅇ")은 재확인 요청을 발동시킨다.

---

## 관련 파일

- `memory-line-check.sh` — MEMORY.md 줄 수를 감시하는 hook
- `memory-health-rules.md` — 최적화기 판단에 사용되는 R1–R5 규칙셋
- `skill-audit.log` — 전체 실행 이력

---

*[Claude Code Skills](https://github.com/aniboy2k-gif/memory-health) 컬렉션의 일부.*
