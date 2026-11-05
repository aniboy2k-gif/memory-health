# /memory-health — Rules Checker procedure (reference)

## Contents
- Rules Checker: size check of auto-loaded files (`--rules`)
- Project CLAUDE.md (+ split files) size monitoring (READ-ONLY)

## Rules Checker: size check of auto-loaded files (`--rules`)

### Prerequisites
- The `CLAUDE_RULES_DIR` environment variable must be set to an absolute path (exit 1 if unset)
- Setting `CLAUDE_RULES_DIR`: ① recommended — add `export CLAUDE_RULES_DIR=...` directly to a shell profile such as `~/.zshrc` · ② if you choose to save at the interactive prompt during `install.sh` (default N), `env.sh` is created under `~/.claude/da-tools/`; source it. If you skip saving, `env.sh` is not created, so use ①
- Scan target: only `.md` files that are direct children of `CLAUDE_RULES_DIR` (subdirectories ignored)
- No file changes (read-only) → no approval gate

### Scope notice
This feature **checks the size of MD files in the given directory**.
It does not guarantee whether Claude Code actually loads those files.

### Thresholds
| Level | Threshold | Meaning |
|-------|-----------|---------|
| OK | < 20,000 chars | normal |
| WARN | 20,000 ~ 40,000 chars | early warning (at 50% of CRITICAL) |
| CRITICAL | > 40,000 chars | self-chosen threshold (separate from Claude Code's official warning — the official threshold scales with the model context window, CHANGELOG 2.1.169) |

Threshold overrides: `CLAUDE_RULES_SIZE_WARN`, `CLAUDE_RULES_SIZE_CRITICAL` environment variables

### Symlink policy
- follow a symlink target once (max depth 20)
- realpath() hash set for de-duplication + cycle detection (deterministic, order-independent)
- on a cycle: print WARN + skip that entry (exit 0)
- on exceeding the depth: print WARN + skip (exit 0)

### Steps (4 steps)

**Step 1 — Check the environment**
```bash
check CLAUDE_RULES_DIR is set → exit 1 if unset (configuration error)
check the CLAUDE_RULES_DIR directory exists → exit 1 if missing (configuration error)
```

**Step 2 — Scan (5-second wall-clock budget)**
Run `scripts/check-rules.sh`:
```bash
bash ~/.claude/skills/memory-health/scripts/check-rules.sh [--strict]
```
On timeout: print the files finished so far + the unprocessed files (at most 10) + exit 0

**Step 3 — Output**
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
(The script prints Korean; when reporting to an English-speaking user, translate it.)

**Step 4 — audit log (F5)**
```bash
memory-health-log.sh "F5" "rules-scan (read-only)" "CRITICAL=N" "WARN=M"
```

### Graceful failure policy

| Failure type | Output level | exit code |
|--------------|--------------|-----------|
| CLAUDE_RULES_DIR unset | WARN + skip | **1** |
| directory missing | WARN + skip | **1** |
| a file fails to parse | ℹ️ skip + continue | 0 |
| symlink cycle detected | ⚠ WARN + skip | 0 |
| symlink depth exceeded | ⚠ WARN + skip | 0 |
| timeout (default) | partial result ⚠ + unprocessed list | 0 |
| timeout (--strict) | partial result ⚠ + unprocessed list | **2** |
| WARN or worse (--strict) | that output | **2** |
| a CRITICAL file exists | CRITICAL output | 0 (read-only) |

### `--strict` mode
For CI/CD pipelines. exit 2 on any WARN-or-worse condition.
```bash
bash check-rules.sh --strict
```

### Completion criteria
- scan results printed
- F5 entry recorded in skill-audit.log

---

## Project CLAUDE.md (+ split files) size monitoring (READ-ONLY)

Separate from the user MEMORY.md (the Optimizer's target), this monitors the size of **external project CLAUDE.md files and their split children** (e.g. aria, kr-ai-trader). **Read-only — it never modifies files.** Actual content optimization goes through the domain workflow (ARIA/KRIS = `/trader-task`), since MEMORY.md's caps are for personal memory and don't fit project docs (plus domain / foreign-repo boundaries).

```bash
bash ~/.claude/skills/memory-health/scripts/check-project-claudemd.sh [--strict]
```

- **Target list** (priority): `--list=<path>` > `$CLAUDE_PROJECT_CLAUDEMD_LIST` > `~/.claude/da-tools/project-claudemd-paths.txt` (one absolute path **or glob pattern** per line; `#`/blank lines ignored)
- **Split files auto-included**: if the list uses a glob (e.g. `.../aria/CLAUDE*.md`), then when CLAUDE.md is later split (`CLAUDE-part2.md`, etc.) the **split files are automatically picked up** (realpath dedup). No manual re-registration needed when `/trader-task` produces splits.
- **Thresholds (chars, aligned with Rules Checker)**: OK<20,000 / WARN 20,000–40,000 / CRITICAL>40,000 (env `CLAUDE_PROJECT_MD_WARN`/`CLAUDE_PROJECT_MD_CRITICAL`)
- **Graceful**: missing list / unmounted volume / zero matches = skip + exit 0 (non-blocking). `--strict` → exit 2 on WARN+ (for CI).
- **Integration**: recommended in `/memory-health check` (default) and `--rules`. On CRITICAL, report to the user but **never auto-edit** — only point to the domain workflow.
