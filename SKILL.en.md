# /memory-health

> 🌐 **[Multilingual / 다국어]**
> For Korean → [`SKILL.md`](SKILL.md)
> 한국어로 사용하려면 → [`SKILL.md`](SKILL.md)
>
> **Language auto-detection**: Default output is English. If the conversation is in Korean, output switches to Korean automatically.
> When the language is unclear or mixed, Korean (default) is used.

> ⚠️ **[SINGLE-SESSION ONLY]** Running multiple Claude tabs simultaneously can corrupt your files.
> Always use this skill in a single session. No locking mechanism is provided.

<!-- Sync checklist: whenever SKILL.en.md is modified, verify the following:
  - [ ] Apply the same changes to SKILL.md
  - [ ] Any new bash commands or error messages should be in English
  - [ ] Update both files when version numbers or thresholds change
-->

A skill for diagnosing and optimizing the health of your memory files.
Provides an Optimizer (trims MEMORY.md line count) and a Scanner (splits oversized memory/*.md files).

## Usage

```
/memory-health          → Diagnose only (dry-run, no approval needed)
/memory-health --fix    → Run Optimizer: trim MEMORY.md line count (one approval gate)
/memory-health --scan   → Run Scanner: scan and split memory/*.md files (one approval gate)
/memory-health --fix --json  → Output dry-run results as JSON (for automation/pipelines)
```

The default is dry-run — no files are changed.

Execution flow:
```
/memory-health         → show dry-run results (no gate)
/memory-health --fix   → show dry-run results → approval gate → execute
/memory-health --scan  → show scan results    → approval gate → execute
```

### --fix --json mode

Runs through step 3 (dry-run results), outputs JSON, and **exits immediately**. No files are changed.

Output schema:
```json
{
  "status": "ok | needs_action",
  "current_lines": 0,
  "target_lines": 180,
  "candidates": [
    { "section": "<header>", "current_lines": 0, "savings": 0 }
  ]
}
```

## Setup (first-time only)

The `CLAUDE_MEMORY_DIR` environment variable must be set. See `install.sh` for setup instructions.

Before using this skill for the first time, run the following to create the required files:
```bash
MEMORY_DIR="${CLAUDE_MEMORY_DIR:?'CLAUDE_MEMORY_DIR is not set'}"
touch "$MEMORY_DIR/violation-archive.md" && echo "✅ violation-archive.md"
touch "$MEMORY_DIR/skill-audit.log"      && echo "✅ skill-audit.log"
```

---

## Role boundary (hook vs skill)

| Type | File | Role | Side effects |
|------|------|------|--------------|
| hook | `memory-line-check.sh` | Automatic monitoring + warnings only | None |
| skill | `/memory-health` | Manual interactive execution + actual optimization | File changes |

The hook only prints warnings. Actual edits are handled by this skill.

---

## Optimizer: Trim MEMORY.md line count (`--fix`)

### Prerequisites
- Recommended when the hook (memory-line-check.sh) has triggered a ≥ 180-line warning
- MEMORY.md is excluded from the Scanner (`--scan`) — only the Optimizer applies to it

### Steps (7 steps)

**Step 1 — Diagnose**
```bash
MEMORY_DIR="${CLAUDE_MEMORY_DIR:?'CLAUDE_MEMORY_DIR is not set'}"
wc -l "${MEMORY_DIR}/MEMORY.md"
wc -c "${MEMORY_DIR}/MEMORY.md"
```
Prints the current line count and byte size.

**Step 2 — Analyze**
```bash
RULES_VERSION_REQUIRED="1.0.0"
RULES_FILE="${MEMORY_DIR}/memory-health-rules.md"
# verify rules file exists and version matches
[ -r "$RULES_FILE" ] || { echo "❌ Rules file not found: $RULES_FILE" >&2; exit 1; }
grep -q "^# version: $RULES_VERSION_REQUIRED" "$RULES_FILE" \
  || { echo "❌ Rules version mismatch (required: $RULES_VERSION_REQUIRED)" >&2; exit 1; }
```
Loads rules R1–R5 and identifies optimization candidates.
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

**Step 7 — Verify (mandatory)**
```bash
LINES=$(wc -l < "${MEMORY_DIR}/MEMORY.md")
if [ "$LINES" -gt 180 ]; then
  echo "⚠ Verification failed: ${LINES} lines (target ≤ 180). Further optimization needed." >&2
else
  echo "✅ Verification passed: ${LINES} lines (target ≤ 180)"
  ~/.claude/skills/memory-health/scripts/memory-health-log.sh \
    "F3" "MEMORY.md optimized" "${BEFORE} lines" "${LINES} lines"
fi
```

### Completion criteria
- MEMORY.md line count ≤ 180 (verified with `wc -l`)
- Execution history recorded in skill-audit.log

---

## Scanner: Scan and split MD files (`--scan`)

### Prerequisites
- Scan target: `memory/*.md` (excluding MEMORY.md)
- Measurement: character count via Python `len()` (not bytes)
- Threshold: files exceeding 5,000 characters

### Steps (6 steps)

**Step 1 — Scan**
```python
import os, glob
MEMORY_DIR = os.environ.get("CLAUDE_MEMORY_DIR")
if not MEMORY_DIR:
    raise EnvironmentError("CLAUDE_MEMORY_DIR is not set")
results = []
for f in glob.glob(f"{MEMORY_DIR}/*.md"):
    if os.path.basename(f) == "MEMORY.md":
        continue  # Optimizer-only file — excluded
    content = open(f, encoding="utf-8").read()
    char_count = len(content)
    if char_count > 5000:
        results.append((f, char_count))
results.sort(key=lambda x: x[1], reverse=True)
for f, c in results:
    print(f"{c:,} chars  {os.path.basename(f)}")
```

**Step 2 — Measure + Report**
Print the list of oversized files, how much they exceed the threshold, and their section headers.

**Step 3 — Propose**
Suggest natural split points for each file.
Naming convention for split files: `{original-name}-part2.md`

**Step 4 — Select + Approve**
The user selects which files to split and where.
Step 5 proceeds only after explicit confirmation.

**Step 5 — Backup + Execute (2-phase commit)**

*Single file split:*
```
1. Create {original-name}-part2.md
2. Update MEMORY.md pointer (same git commit)
   Pointer format: "details: {original-name}-part2.md [one-line condition trigger]"
3. Verify: len(part1) + len(part2) = len(original) ± 3 characters
4. On failure: git checkout -- {changed files}
```

*Multiple file split:*
```
Phase 1 (Prepare):
  - Create all split files as {original-name}-part2.md.tmp
  - Prepare pointer updates as {original-name}.patch
Phase 2 (Commit):
  - Validate total len() across all .tmp files
  - Bulk rename (remove .tmp suffix)
  - Update all pointers at once
  - Delete .patch files
On failure:
  - Delete all .tmp files
  - Ensure MEMORY.md is unchanged
  - Delete .patch files
```

**Phase 2 rollback decision tree**
```
(a) rename fails:
    Delete all .tmp files, leave MEMORY.md pointers unchanged → recovery complete
    Verify: ls "${CLAUDE_MEMORY_DIR}"/*.tmp 2>/dev/null \
            && echo "⚠ tmp files remain" || echo "✅ cleaned up"

(b) rename succeeds + pointer update fails:
    Reverse mv (restore part2 → original) + git checkout -- MEMORY.md
    Verify: git diff --name-only

(c) len() check fails (both previous steps succeeded):
    git checkout -- {all changed files}
    Verify: git status
```
Each branch prints an error to stderr before exiting with code 1.

**Step 6 — Verify + Log**
Re-measure len() of each processed file. Log only on successful commit:
```bash
~/.claude/skills/memory-health/scripts/memory-health-log.sh \
  "F4" "${FILE} split" "${BEFORE} chars" "${AFTER1} chars + ${AFTER2} chars"
```

### Completion criteria
- All processed files are 5,000 characters or fewer
- MEMORY.md pointers updated and index consistency verified
- Execution history recorded in skill-audit.log

---

## Failure mode table

| Step | Failure condition | Authoritative state | Recovery command |
|------|-----------------|---------------------|-----------------|
| Step 5 backup fails (Optimizer) | `memory-backup.sh` exit ≠ 0 | Original MEMORY.md preserved | `git log --oneline -5` |
| Step 6 write error (Optimizer) | MEMORY.md write fails | Backup copy is authoritative | `git checkout -- MEMORY.md` |
| Phase 1 .tmp creation fails (Scanner) | write error | Original preserved | `rm -f "${CLAUDE_MEMORY_DIR}"/*.tmp` |
| Phase 2 rename fails (Scanner) | `mv` exit ≠ 0 | .tmp files remain | `rm -f "${CLAUDE_MEMORY_DIR}"/*.tmp` |
| Phase 2 pointer update fails (Scanner) | MEMORY.md write error | part2 created, MEMORY.md outdated | `git checkout -- MEMORY.md && rm {part2-file}` |
| len() check fails (Scanner) | \|sum − original\| > 3 | Files changed | `git checkout -- {changed files}` |
| Audit log rotate fails | `cp` exit ≠ 0 | Logging stopped | `ls -lh "${CLAUDE_MEMORY_DIR}/skill-audit.log"` |

---

## Audit log spec

```
Location: ${CLAUDE_MEMORY_DIR}/skill-audit.log
Format: {ISO8601} | {function} | {summary} | {before} → {after}
Examples:
  2026-04-21T20:00:00+0900 | F3 | MEMORY.md optimized | 195 lines → 142 lines
  2026-04-21T20:10:00+0900 | F4 | project-fss.md split | 25,190 chars → 4,800 chars + 4,200 chars
Retention: rotated to skill-audit.log.old when exceeding 50KB (handled automatically by the skill)
Retention policy: maximum 2 generations (one .old file)
```

Audit log scope:
- Allowed: standard shell commands, Python built-ins, environment variables (CLAUDE_MEMORY_DIR, etc.), scripts bundled with this skill
- Not allowed: external systems, personal boards, third-party trackers, or any dependency outside this repository

---

## Optimization rules reference

Candidate identification rules are loaded from `memory/memory-health-rules.md` via the Read tool.
No ad-hoc judgment — never select candidates using criteria not in the rules file.

---

## Approval policy summary

| Mode | Approval required | Reason |
|------|------------------|--------|
| dry-run (default) | No | Auto-approved scope (no file changes) |
| `--fix` | Once | MEMORY.md content changes |
| `--scan` | Once | memory/*.md content changes |
| `--fix --json` | No | Same as dry-run, exits after JSON output |
