# /memory-health — Rules Checker 절차 (reference)

## Contents
- Rules Checker: 자동 로드 파일 크기 검사 (`--rules`)
- 프로젝트 CLAUDE.md(+분리 파일) 크기 모니터링 (READ-ONLY)

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
