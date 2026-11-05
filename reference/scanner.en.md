# /memory-health — Scanner procedure (reference)

## Scanner: Scan and split MD files (`--scan`)

### Prerequisites
- Scan target: `memory/*.md` (excluding MEMORY.md)
- Measurement: character count via Python `len()` (not bytes)
- Threshold: files exceeding 10,000 characters (aligned with the Phase F per-file cap of 10,000 tokens, trader_log #199 2026-05-21)

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
    if char_count > 10000:
        results.append((f, char_count))
results.sort(key=lambda x: x[1], reverse=True)
for f, c in results:
    print(f"{c:,} chars  {os.path.basename(f)}")
```

**Step 2 — Measure + Report**
Print the list of oversized files, how much they exceed the threshold, and their section headers.

**Step 3 — Propose**
Suggest natural split points for each file.
The split file name is decided first by memory-health-rules.md R10 (externalization destination routing) — only when there is no hub, `{original-name}-part2.md`

**Step 4 — Select + Approve**
The user selects which files to split and where.
Step 5 proceeds only after explicit confirmation.

**Step 5 — Backup + Execute (2-phase commit)**

Below, `{original-name}-part2.md` stands for the split file name chosen in step 3 (the R10 hub when one exists).

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
- All processed files are 10,000 characters or fewer (Phase F per-file cap)
- MEMORY.md pointers updated and index consistency verified
- Execution history recorded in skill-audit.log
