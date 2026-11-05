# /memory-health — Optimizer procedure (reference)

## Contents
- Optimizer: Trim MEMORY.md line count (`--fix`)

## Optimizer: Trim MEMORY.md line count (`--fix`)

### Prerequisites
- Recommended when the hook (memory-line-check.sh) has triggered a warning (≥ 160 lines or ≥ 20,000 characters)
- ★ CSR #1825: the platform cap is **200 lines OR 25,000 characters (UTF-16 code units)** — **not bytes**.
  Behavioral probe: 24,899 chars load / 25,099 chars truncate; 10,734 chars at 31,534 **bytes** load fully.
  Korean inflates bytes only — it does **not** bring the file closer to the cap. Never judge with `wc -c`.
- MEMORY.md is excluded from the Scanner (`--scan`) — only the Optimizer applies to it

### Steps (7 steps)

**Step 1 — Diagnose**
```bash
MEMORY_DIR="${CLAUDE_MEMORY_DIR:?'CLAUDE_MEMORY_DIR is not set'}"
wc -l "${MEMORY_DIR}/MEMORY.md"
# character count (UTF-16 code units) — not bytes (wc -c) (CSR #1825)
MH_T="${MEMORY_DIR}/MEMORY.md" python3 -c 'import os
t=open(os.environ["MH_T"],encoding="utf-8",errors="replace").read()
print(sum(2 if ord(c)>0xFFFF else 1 for c in t))'
```
Prints the current line count and character count.

**Step 2 — Analyze** (CSR #962: version-string grep replaced by drift-check validation)
```bash
RULES_FILE="${MEMORY_DIR}/memory-health-rules.md"
DRIFT="$HOME/.claude/skills/memory-health/scripts/memory-rules-drift-check.sh"
# verify rules file exists
[ -r "$RULES_FILE" ] || { echo "❌ Rules file not found: $RULES_FILE" >&2; exit 1; }
# Integrity via content drift, NOT a version string (which a stale fork can fake).
# Expected version is derived from the bundle template, never hardcoded here (H-3).
bash "$DRIFT" --check || echo "⚠ rules drift detected — review guidance above before proceeding (no silent pass)"
```
- **Fix B**: the `# version:` line is a human-readable secondary marker only. Integrity authority is the drift-check (axis0 canonical↔bundle / axis1 active↔base / axis2 bundle version). A version-only-bumped stale fork is caught by axis0/axis2.
- **H-3**: the expected version is NOT hardcoded in SKILL files (removed the old `RULES_VERSION_REQUIRED`). The bundle template `# version:` is the single source.

Loads rules R1–R10 (every R section of memory-health-rules.md) and identifies optimization candidates.
No ad-hoc judgment — always apply the criteria from the rules file.

**Step 3 — Propose (dry-run)**
- Print expected changes per candidate
- Print expected line count after applying changes
- If `--fix --json` mode: output in the JSON schema above and **exit immediately** (skip steps 4–7)
- Wait for user confirmation

**Step 4 — Approval**
The user must explicitly confirm before step 5 proceeds.
Implicit agreement is not accepted ("looks good", "ok" alone will prompt a re-confirmation).

**Step 5 — Backup (hard stop)**
```bash
~/.claude/hooks/memory-backup.sh
BACKUP_EXIT=$?
if [ $BACKUP_EXIT -ne 0 ]; then
  echo "❌ Backup failed (exit $BACKUP_EXIT). Aborting." >&2
  echo "For recovery: git log --oneline -5" >&2
  exit 1
fi
```
If the backup fails, step 6 cannot proceed.

**Step 6 — Execute**
Apply the approved changes to MEMORY.md.
No shared state (global variables, file locks) with the Scanner handler.

**Step 7 — Verify (mandatory)** — line count + character count together

```bash
LINES=$(wc -l < "${MEMORY_DIR}/MEMORY.md")
# ★ The axis is characters (UTF-16 code units), not bytes (CSR #1825 behavioral probe).
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
  # cap×0.7 target line against the 200-line·25,000-char cap (our choice — not a platform authority)
  ~/.claude/skills/memory-health/scripts/memory-health-log.sh \
    "F3" "MEMORY.md optimized" "${BEFORE} lines" "${LINES} lines/${CHARS} chars"
fi
```

**Step 8 — Sync board #32 (mandatory, prevents recurrence of claude_fail #81)**

MEMORY.md was modified, so the board sync page (claude-docs #32, "MEMORY.md — Claude Code 동기화 페이지") must be updated too. **No hand-syncing** — a deterministic generator regenerates #32 from MEMORY.md:

```bash
~/.claude/scripts/sync-memory-to-board.sh
SYNC_EXIT=$?
if [ "$SYNC_EXIT" -ne 0 ]; then
  echo "⚠ #32 sync failed (exit $SYNC_EXIT) — verify board access and re-run manually: ~/.claude/scripts/sync-memory-to-board.sh" >&2
fi
```

> **Defense-in-depth**: the PostToolUse hook `memory-sync-detect.sh` also reminds on MEMORY.md edits, but this skill is the mutation author so it syncs explicitly. Use `--check` for read-only drift detection. Pattern + honest scope: `feedback_source-derived-sync-forcing-function`.

### Completion criteria
- MEMORY.md line count ≤ 140 and character count ≤ 17,500 (UTF-16 code units — **not** `wc -c` bytes)
- **Board #32 synced** (`sync-memory-to-board.sh` exit 0, or reported to user on failure) — claude_fail #81
- Execution history recorded in skill-audit.log
