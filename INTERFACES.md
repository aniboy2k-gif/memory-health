# INTERFACES.md — 컴포넌트 계약 명세

이 파일은 memory-health 스킬과 외부 의존 파일 사이의 입출력 계약을 정의한다.
외부 파일을 직접 구현할 때 이 계약을 반드시 준수해야 한다.

---

## memory-backup.sh

| 항목 | 명세 |
|------|------|
| **위치** | `~/.claude/hooks/memory-backup.sh` |
| **실행 조건** | `CLAUDE_MEMORY_DIR` 환경변수가 설정된 상태에서 호출됨 |
| **입력** | 없음 (인수 없음) |
| **성공 출력** | stdout에 백업 완료 메시지 (내용 자유) |
| **실패 출력** | stderr에 오류 메시지 + exit ≠ 0 |
| **exit 0** | 백업 완료 → Optimizer 5단계 진행 허용 |
| **exit ≠ 0** | 백업 실패 → Optimizer **하드 스톱**, 파일 변경 절대 불가 |
| **요구 사항** | `chmod +x` 실행 권한 필요 |
| **샘플** | `scripts/memory-backup.sh` 참조 |

---

## memory-line-check.sh

| 항목 | 명세 |
|------|------|
| **위치** | `~/.claude/hooks/memory-line-check.sh` (Claude Code hook으로 등록) |
| **실행 조건** | Claude Code 세션 시작 시 자동 실행 (hook) |
| **입력** | 없음 (CLAUDE_MEMORY_DIR 환경변수 읽기) |
| **환경변수 (선택)** | `CLAUDE_MEMORY_LINE_WARN` (기본 180) · `CLAUDE_MEMORY_BYTE_WARN` (기본 24500) |
| **성공 출력** | stdout: `⚠ MEMORY.md lines={n} (≥180) bytes={m} (≥24500) — run /memory-health --fix [— Korean ratio {p}% ...]` (둘 중 하나 이상이 임계값 도달 시) |
| **부작용** | **없음** — 경고 출력만, 파일 변경 절대 금지 |
| **exit 코드** | 0 (항상. 경고가 있어도 hook을 차단하지 않음) |
| **변경 이력** | CSR #807 (2026-05-23): 바이트 캡 + 한글 비율 추가. 25 KB Anthropic Auto Memory cap 대응 |

---

## memory-health-rules.md

| 항목 | 명세 |
|------|------|
| **위치** | `${CLAUDE_MEMORY_DIR}/memory-health-rules.md` |
| **첫 줄** | `# version: {semver}` — Optimizer가 버전 일치 여부를 검사 |
| **현재 필요 버전** | `1.1.0` (CSR #807, 2026-05-23 — R7·R8 추가) |
| **내용** | R1~R8 최적화 규칙 정의 (마크다운 자유 형식) |
| **쓰기 주체** | 사용자 (직접 편집) |
| **읽기 주체** | Optimizer (`--fix` 2단계에서 Read) |
| **버전 불일치 시** | Optimizer가 stderr 오류 출력 후 exit 1 |
| **템플릿** | 이 레포의 `memory-health-rules.md` 참조 |

---

## memory-health-log.sh

| 항목 | 명세 |
|------|------|
| **위치** | `~/.claude/skills/memory-health/scripts/memory-health-log.sh` |
| **인수** | `$1=기능(F3\|F4)` `$2=작업요약` `$3=변경전` `$4=변경후` |
| **환경변수** | `CLAUDE_MEMORY_DIR` 필수 (미설정 시 exit 1) |
| **출력** | `${CLAUDE_MEMORY_DIR}/skill-audit.log`에 1줄 추가 |
| **rotate** | 50KB 초과 시 `.old`로 cp+truncate (유실 방지 패턴) |
| **exit 0** | 로그 기록 성공 |
| **exit ≠ 0** | rotate 실패 시. 단, 메인 기능(파일 분리 등)은 계속 진행 가능. |

---

---

## check-rules.sh

| 항목 | 명세 |
|------|------|
| **위치** | `~/.claude/skills/memory-health/scripts/check-rules.sh` |
| **실행 조건** | `CLAUDE_RULES_DIR` 환경변수가 절대 경로로 설정된 상태에서 호출 |
| **입력** | `[--strict]` 플래그 (선택) |
| **기능** | 지정 디렉토리 직접 자식 `.md` 파일 크기 검사 (read-only) |
| **exit 0** | 정상 또는 CRITICAL 파일 존재 (read-only이므로) |
| **exit 1** | 설정 오류: CLAUDE_RULES_DIR 미설정 또는 디렉토리 없음 |
| **exit 2** | --strict 모드에서 WARN 이상 비정상 상황 발생 |
| **요구 사항** | `chmod +x` 실행 권한, Python 3 필요 |

### 환경변수 계약

| 환경변수 | 필수 | 기본값 | 설명 |
|---------|:----:|--------|------|
| `CLAUDE_RULES_DIR` | **필수** | 없음 | rules 디렉토리 절대 경로. 미설정 시 exit 1 |
| `CLAUDE_RULES_SIZE_WARN` | 선택 | 20000 | WARN 임계값 (문자 수) |
| `CLAUDE_RULES_SIZE_CRITICAL` | 선택 | 40000 | CRITICAL 임계값 (문자 수). Claude Code 성능 경고 기준과 일치 |
| `MEMORY_HEALTH_DEFAULT_RULES` | 선택 | false | `true` 설정 시 기본 dry-run에 Rules Checker 자동 포함 |
| `CLAUDE_MEMORY_DIR` | 선택 | 없음 | audit 로그(skill-audit.log) 기록 위치 |

### CLAUDE_RULES_DIR 설정 방법
```bash
# install.sh 실행 후 생성된 env.sh를 source
source ~/.claude/da-tools/env.sh

# 또는 직접 설정
export CLAUDE_RULES_DIR="/Volumes/L'Atelier de Claude/workspace/claude-forge/rules"
```

### F5 감사 로그 코드

| 코드 | 기능 | 동작 유형 | 형식 |
|------|------|----------|------|
| F3 | MEMORY.md 최적화 | write | `F3 \| MEMORY.md 최적화 \| {before}줄 → {after}줄` |
| F4 | memory/*.md 파일 분리 | write | `F4 \| {file} 분리 \| {before}자 → {after1}자 + {after2}자` |
| **F5** | **rules-scan** | **read-only** | `F5 \| rules-scan (read-only) \| CRITICAL=N → WARN=M` |

---

## 버전 호환성

| 스킬 버전 | rules 최소 버전 | 비고 |
|-----------|---------------|------|
| 1.x       | 1.0.0         | 현재 버전 |
| 1.1.x+    | 1.0.0         | Rules Checker (--rules) 추가 |
