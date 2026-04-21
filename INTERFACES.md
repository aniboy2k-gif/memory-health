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
| **성공 출력** | stdout: `⚠ MEMORY.md {n}줄 — /memory-health --fix 권장` (180줄 이상일 때만) |
| **부작용** | **없음** — 경고 출력만, 파일 변경 절대 금지 |
| **exit 코드** | 0 (항상. 경고가 있어도 hook을 차단하지 않음) |

---

## memory-health-rules.md

| 항목 | 명세 |
|------|------|
| **위치** | `${CLAUDE_MEMORY_DIR}/memory-health-rules.md` |
| **첫 줄** | `# version: {semver}` — Optimizer가 버전 일치 여부를 검사 |
| **현재 필요 버전** | `1.0.0` |
| **내용** | R1~R5 최적화 규칙 정의 (마크다운 자유 형식) |
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

## 버전 호환성

| 스킬 버전 | rules 최소 버전 | 비고 |
|-----------|---------------|------|
| 1.x       | 1.0.0         | 현재 버전 |
