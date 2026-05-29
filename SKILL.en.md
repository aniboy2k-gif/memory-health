---
name: memory-health
description: "Memory file health diagnosis + optimization (MEMORY.md Optimizer R1~R6 + memory/*.md Scanner + Rules Checker + periodic CLAUDE.md audit)"
argument-hint: '[check] | fix [--R1...] [--json] | scan | rules [--strict] | --with-md | --fix | --scan | --rules [--strict] | --fix --json | --fix --with-md | --scan --with-md'
---

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
/memory-health catalog  → Build knowledge catalog: regenerate 3-axis metadata index (read-only)
/memory-health --fix --json  → Output dry-run results as JSON (for automation/pipelines)
/memory-health --with-md     → memory health + CLAUDE.md quality audit (requires claude-md-management plugin)
```

The default is dry-run — no files are changed.

Execution flow:
```
/memory-health         → show dry-run results (no gate)
/memory-health --fix   → show dry-run results → approval gate → execute
/memory-health --scan  → show scan results    → approval gate → execute
/memory-health --with-md → Phase A(memory health dry-run) → Phase B(CLAUDE.md quality audit) → Phase C(session learnings prompt)
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

The `CLAUDE_MEMORY_DIR` environment variable must be set. Three ways (one or more recommended):
1. `env` field in `~/.claude/settings.json` → `"CLAUDE_MEMORY_DIR": "<abs-path>"` (injected regardless of how Claude Code is launched, dynamic reload — most robust)
2. `~/.zshrc` → `export CLAUDE_MEMORY_DIR="<abs-path>"` (terminal/script compatible)
3. run `install.sh` (auto-detects and persists it to `~/.zshrc`)

If unset, the helper scripts (`memory-backup.sh`, `memory-health-log.sh`) no longer abort cryptically: they print the three setup options above and exit 1 gracefully (Layer 3 — no path guessing, safety first).

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

Loads rules R1–R8 and identifies optimization candidates.
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

## CLAUDE.md Integration (`--with-md`)

> **Prerequisite**: `claude-md-management` plugin must be installed.
> Install: `claude plugin install claude-md-management`
> Verify: `claude plugin list`

`--with-md` can be combined with other flags: `/memory-health --with-md`, `/memory-health --fix --with-md`.

### Execution flow (3 Phases)

**Phase A — memory health (existing behavior)**
- Runs the existing dry-run / `--fix` / `--scan` / `--rules` logic unchanged
- Proceeds to Phase B after Phase A completes

**Phase B — CLAUDE.md quality audit (invokes `claude-md-improver` skill)**

Audits CLAUDE.md files in the current working directory:

```bash
find . -name "CLAUDE.md" -o -name ".claude.local.md" 2>/dev/null | head -10
```

If files exist, runs `claude-md-improver` Phases 1–3 (Discovery → Quality Assessment → Quality Report).
- Outputs quality scores (A–F grade)
- Lists issues and recommended additions
- **No files are modified in this phase** (report only)

If no files found:
```
ℹ️  No CLAUDE.md found — no CLAUDE.md in the current directory.
   Run from the project root or create a CLAUDE.md first.
```

**Phase C — Session learnings prompt**

After Phase B, outputs:
```
💡 Capture session learnings
   To incorporate discoveries from this session into CLAUDE.md:
   /revise-claude-md
   (available with claude-md-management plugin installed)
```

For `--fix --with-md`: Phase A `--fix` completes, then Phase B → C follows.

### --with-md completion criteria
- Phase A: same as the respective mode's completion criteria
- Phase B: CLAUDE.md quality report output complete (no file changes)
- Phase C: session learnings prompt output complete

---

## Catalog: knowledge index catalog (`catalog`)

Collects **metadata** (not full content) for every MD file Claude references, plus the
AI bulletin board (guides + task logs) and the config hierarchy, into a regenerable
index — a map of "what lives where". Read a specific file's body on demand.

### Three axes

| Axis | Source | Metadata |
|------|--------|----------|
| ① MD files | `~/.claude` (symlink follow) · `~/workspace` · L'Atelier workspace | realpath · access_paths (symlink multi-path) · category · title (first `#`) · frontmatter description · size · mtime |
| ② AI board | **live DB** `{board}_posts` (path resolution ★ below) | board · type (guide/tasklog) · post id·title·status·tags·dates (**no content**) |

> ★ **Board live DB path (must reference this)**: the builder opens the DB with the **same resolution order** as the board server (`bulletin-board/src/db/database.js`) — `$DB_PATH` env → `~/Library/Application Support/bulletin-board/bulletin.db` (live default) → `$BB_HOME/data/bulletin.db` → `$BB_HOME/database.db` (in-repo copies, **may be stale**). The `$BB_HOME/data/bulletin.db` is a **stale secondary copy** (measured 2026-05-29: live csr 860 vs stale 368, live 31 boards vs stale 19, trader_log's 357 posts absent from stale). Always use the live path for direct sqlite queries too. Details: `feedback_bulletin-board-live-db-path.md`
| ③ Config | CLAUDE.md · rules · rules-canonical | tagged in ① then re-aggregated as `config_hierarchy` |

### Behavior
```bash
bash ~/.claude/skills/memory-health/scripts/catalog.sh
```
- Builder: `scripts/build-catalog.py` (python3). realpath de-dup (symlink = one entry),
  no content read (head 4KB per file only), mount-graceful (skip unmounted roots + record coverage gap).
- Output (read-only — writes only these two, under `catalog/` to stay clear of memory-health's own scan):
  - `${CLAUDE_MEMORY_DIR}/catalog/knowledge-catalog.json` — full machine SSOT
  - `${CLAUDE_MEMORY_DIR}/catalog/knowledge-catalog.md` — category/board summary + jq query guide (≤10K cap)
- Idempotent: output dir excluded from scan → same input = same output.

### Query (no search subcommand — query the JSON directly)
```bash
CAT="$CLAUDE_MEMORY_DIR/catalog/knowledge-catalog.json"
jq -r '.md.entries[]|select(.category=="skill")|.realpath' "$CAT"
jq -r '.board.entries[]|select(.board=="csr")|"\(.id)\t\(.status)\t\(.title)"' "$CAT"
```

### Completion criteria
- Valid `knowledge-catalog.json` + all three axes present + 0 duplicate realpaths
- `knowledge-catalog.md` ≤ 10,000 chars
- F6 entry recorded in skill-audit.log

---

## Approval policy summary

| Mode | Approval required | Reason |
|------|------------------|--------|
| dry-run (default) | No | Auto-approved scope (no file changes) |
| `--fix` | Once | MEMORY.md content changes |
| `--scan` | Once | memory/*.md content changes |
| `catalog` | No | read-only (creates only the two catalog/ index files, originals untouched) |
| `--fix --json` | No | Same as dry-run, exits after JSON output |
| `--with-md` (Phase B) | No | claude-md-improver report only (no file changes) |
| `--with-md` Phase B→edit | Once | Separate approval if claude-md-improver applies edits |
