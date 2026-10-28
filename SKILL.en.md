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
Provides an Optimizer (trims MEMORY.md line count) and a Scanner (splits oversized memory/*.md files), plus a
**monthly routine** — a CLAUDE.md·rules audit (the bundled claude-api `prompt-audit` procedure run by a read-only
subagent, every 30 days) and a skill update check (every 30 days, check only).

> **Session learnings and hooks (facts, CSR #2450)**: `revise-claude-md-stop.sh` (Stop) and `revise-claude-md-inject.sh`
> (UserPromptSubmit) were **unwired** from `settings.json` by CSR #2451 A1-P4 (files kept for history). The plugin command
> `revise-claude-md` is **denied** in `settings.json`. Session learnings are not appended to CLAUDE.md; they are handled at
> the task's G-7 guide step (CSR #2435 D3).

## Usage

```
/memory-health          → Diagnose only (dry-run, no approval needed)
/memory-health --fix    → Run Optimizer: trim MEMORY.md line count (one approval gate)
/memory-health --scan   → Run Scanner: scan and split memory/*.md files (one approval gate)
/memory-health catalog  → Build knowledge catalog: regenerate 3-axis metadata index (read-only)
/memory-health --fix --json  → Output dry-run results as JSON (for automation/pipelines)
/memory-health --with-md     → memory health + forced monthly routine (prompt-audit by the read-only auditor + skill update check)
```

The default is dry-run — no files are changed.

Execution flow:
```
/memory-health         → show dry-run results (no gate)
                          → monthly routine (each part only when its own marker is due — see "Monthly routine")
                             audit part: audit-record.sh pre → read-only auditor agent → post
                             update part: audit-record.sh update-check (check only, never apply)
/memory-health --fix   → show dry-run results → approval gate → execute
/memory-health --scan  → show scan results    → approval gate → execute
/memory-health --with-md → Phase A(memory health dry-run) → Phase B(forced monthly routine) → Phase C(session learnings handling)
```

### --fix --json mode

Runs through step 3 (dry-run results), outputs JSON, and **exits immediately**. No files are changed.

Output schema:
```json
{
  "status": "ok | needs_action",
  "current_lines": 0,
  "target_lines": 140,
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
| subagent | `memory-health-prompt-auditor-ro` (`~/.claude/agents/`) | Monthly audit runner — tools are only `Read, Grep, Glob` (no write tool) | None (report + proposed diff only) |
| skill | `/memory-health` | Manual interactive execution + actual optimization + monthly routine | File changes |

> `revise-claude-md-stop.sh` and `revise-claude-md-inject.sh` are unwired (CSR #2451 A1-P4) — they are on no execution path, so they are not in this table.

The hook only prints warnings. Actual edits are handled by this skill.

---

## Monthly routine — CLAUDE.md·rules audit + skill update check (part of the default dry-run, CSR #2450)

> **Prerequisites**:
> - The procedure file `~/.claude/skills/claude-api/shared/prompt-audit.md` and the auditor definition
>   `~/.claude/agents/memory-health-prompt-auditor-ro.md` must exist (otherwise `pre` returns ENGINE_UNAVAILABLE / AUDITOR_MISCONFIGURED).
> - The bundled claude-api skill must not be turned off (`skillOverrides` / `disableBundledSkills`).
> - Claude Code v2.1.283+ is needed only for the user-typed `/doctor prompt-audit` form.
> - Run it in a session started without `--add-dir` / `/add-dir` / `--agents` (not visible on disk, so `pre` cannot see them — RF).

After the default `/memory-health` run (dry-run), the two parts below run. **Each part runs only when its own marker is
due** (`--with-md` forces both). If both are due: audit first, then the update check — both are attempted and recorded,
and each refreshes only its own marker.

**The audit is its own phase** — run it after memory-health's write phases (Optimizer `--fix`, Scanner `--scan`) have
finished, and change no file while it runs. Applying the audit's proposed diff happens only outside this phase, with a
separate approval.

### Timestamp-based interval check

```bash
AUDIT_LAST="$HOME/.claude/da-tools/claude-md-audit-last"          # audit part — refreshed only by audit-record.sh post on REPORTED
UPDATE_LAST="$HOME/.claude/da-tools/skill-update-check-last"      # update part — refreshed only by update-check on PASS
AUDIT_INTERVAL_DAYS="${CLAUDE_MD_AUDIT_INTERVAL:-30}"   # default 30 days, override with CLAUDE_MD_AUDIT_INTERVAL (both parts)
[[ $AUDIT_INTERVAL_DAYS =~ ^[1-9][0-9]{0,3}$ ]] || AUDIT_INTERVAL_DAYS=30   # 08/abc/0/negative → 30 (same validation as the hook memory-rules-drift-check.sh mrdc_audit_notice — change both together)

days_since() {   # missing or unreadable = 9999 (treated as due)
  local v; v="$(head -n 1 "$1" 2>/dev/null | tr -d '[:space:]')"
  [[ $v =~ ^[1-9][0-9]{0,11}$ ]] || { echo 9999; return; }
  echo $(( ($(date +%s) - v) / 86400 ))
}
AUDIT_DAYS=$(days_since "$AUDIT_LAST"); UPDATE_DAYS=$(days_since "$UPDATE_LAST")
```

### Decision

| Condition | Action |
|-----------|--------|
| `AUDIT_DAYS >= AUDIT_INTERVAL_DAYS` (incl. missing file) | audit part — the four steps below |
| `UPDATE_DAYS >= AUDIT_INTERVAL_DAYS` (incl. missing file) | update part — `audit-record.sh update-check` |
| neither due | print "✅ monthly routine up to date (audit N days ago · update check M days ago)" and skip |
| `--with-md` given | run both parts even if not due |

### Audit part — four steps (only the script decides the state)

Audit scope (fixed list, made into absolute paths by `pre`): `~/.claude/CLAUDE.md` · `~/.claude/rules/*.md` (top level only) ·
`${CLAUDE_MEMORY_DIR}/MEMORY.md` · `~/.claude/skills/memory-health/SKILL.md` and `SKILL.en.md` · the current working directory's `CLAUDE.md` (if any).

```bash
AR="$HOME/.claude/skills/memory-health/scripts/audit-record.sh"
bash "$AR" pre --cwd "$PWD"      # ① STATE=READY prints RUN_DIR=<path> · any other STATE: stop here and report it
```

② **Spawn the subagent (foreground)** — Agent tool, `subagent_type: "memory-health-prompt-auditor-ro"`, `model: "opus"`,
never in the background. Use this prompt as is, with `<MANIFEST>` replaced by the content of `$RUN_DIR/manifest.txt`, unchanged:

```
model: opus (reason: audit)
Apply the prompt-audit procedure (read ~/.claude/skills/claude-api/shared/prompt-audit.md fully first)
to exactly these files, named by absolute path. Report + proposed diff only; do not apply anything.
<MANIFEST>
End with one `COVERED: <abs path> last_line=<n>` line per path above (n = the last line number your
Read tool showed for that file), then one `FINDINGS high=<n> medium=<n> low=<n>` line.
```

③ Save the agent's **full final message** to `$RUN_DIR/report.md` (Write — no summarizing or editing).

```bash
bash "$AR" post "$RUN_DIR" "$RUN_DIR/report.md"   # ④ refreshes claude-md-audit-last only on REPORTED
```

Report: `STATE`, finding counts, and the saved copy (`~/.claude/da-tools/claude-md-audit-reports/<ts>.md`, mode 600, newest 12 kept).
If the Agent call itself errors, skip ③④ and report "audit engine unavailable (ENGINE_UNAVAILABLE)" — no marker refresh.

### Update part — skill update check

```bash
bash "$AR" update-check     # timeout -k 10 300 python3 ~/.claude/skills/skill-advisor/scripts/update.py --json
```

- Report the `SKILL: <name> channel=<channel> status=<status>` lines (updates available, fetch errors) as printed.
- **Applying is not automatic** — `update.py --apply` replaces a SKILL.md wholesale, the targets are the claude-forge
  canonical files, and `/skill-advisor --update --apply` auto-runs `--listing-audit --apply`, which is forbidden until the
  CSR #1806 decision. Applying is a separate owner-approved step in a claude-forge worktree + PR, calling
  `update.py <skill> --apply` directly. skill-advisor itself stays frozen (no change) until #1806.

### State table (`~/.claude/da-tools/claude-md-audit.jsonl`, field `part`)

| State | Step | Meaning | Marker refreshed |
|-------|------|---------|------------------|
| `READY` | pre | checks passed, run dir created | none |
| `AUDITOR_SHADOWED` | pre | more than one definition with that name, or the only one is outside the user level (`~/.claude/agents/`) — searches project `.claude/agents/` (subfolders included, from cwd up to `/`). Plugin folders and `additionalDirectories` cannot shadow the name and are not searched | none |
| `AUDITOR_MISCONFIGURED` | pre | no definition, frontmatter keys ≠ {name, description, tools, model}, `tools` ≠ `Read, Grep, Glob`, `model` ∉ {opus, sonnet, inherit} | none |
| `ENGINE_UNAVAILABLE` | pre | procedure file missing (or the Agent call errors) | none |
| `SCOPE_UNRESOLVED` | pre | `CLAUDE_MEMORY_DIR` unset or its `MEMORY.md` missing (incl. a missing scope file) | none |
| `AUDITOR_CHANGED` | post | definition sha256 differs from pre or file missing — report kept but untrusted | none |
| `SCOPE_CHANGED_DURING_AUDIT` | post | a scope file's sha256 differs from pre | none |
| `AUDIT_INCOMPLETE` | post | a `COVERED` line missing, `last_line` ≠ actual line count, or no parseable `FINDINGS` line | none |
| `REPORTED` | post | last line number of every file reported correctly + FINDINGS parsed (`read_evidence:"last_line_match"`) | `claude-md-audit-last` |
| `UPDATE_CHECK_PASS` | update | exit 0/1 + parseable JSON + `fetch_error < total` | `skill-update-check-last` + `skill-update-failed.json` |
| `UPDATE_CHECK_FAILED` | update | exit 2/124/137/other, unparseable JSON, `fetch_error == total` | none (`skill-update-failed.json` unchanged) |

What `REPORTED` means: the auditor reported the last line number of every file correctly without being given it —
evidence it opened each file; neither full reading nor review quality is proven. Finding counts are the auditor's own.
`--dry-run` (post, update-check) writes no marker, jsonl line or saved report; it only prints the record.

### What is covered (Covers — Round-8 wording)

> The auditor's tool calls are read-only provided the invoked agent actually uses the validated read-only definition
> and Claude Code enforces its tool allowlist. Pre/post hashing detects persistent definition changes but cannot
> establish that the definition remained unchanged throughout invocation. Concurrent changes, including changes
> subsequently restored and live-reload effects, are excluded from this guarantee. A matching hash does not certify
> runtime definition integrity.

### Residual risks (disclosed)

- **RA** Relies on Claude Code honoring the `tools` allowlist (documented) — `pre` catches an edited definition, not a harness regression.
- **RB** The user-typed `/doctor prompt-audit` full run executes in the main session with all tools (auto mode) — protection covers only this routine.
- **RC** The auditor cannot spawn sub-auditors — the monthly scope must fit one agent; truncation shows as AUDIT_INCOMPLETE.
- **RD** The main session writes the report, jsonl and both markers (fixed paths outside the audit scope).
- **RE** Model-orchestrated — the script cannot prove the saved text came from the auditor; finding counts are the auditor's own.
- **RF** Session-only `--add-dir` / `/add-dir` / `--agents` definitions are not visible on disk, so `pre` cannot see them — run in a session started without those flags.
- **RG** Hook side effects are outside the guarantee — the scope sha256 comparison only catches a persistent byte change between the two snapshots, not transient writes restored before `post`, same-content rewrites, or writes outside the scope.
- **RH** A definition changed and restored to identical bytes between pre and post, or changes delivered by live reload in that window, cannot be seen by a byte comparison.

### Full-scope audit (run by the user)

To audit all skills, commands and agents under `~/.claude/`, the user types `/doctor prompt-audit` (no path) themselves.
⚠ That run is **not write-protected** (RB · claude-code issue #99288: files edited with no apply request) — review the
proposed diff before approving any apply. memory-health never runs the full scope automatically (cost).

> Replaced engine: this routine used to call claude-md-improver from the claude-md-management plugin. Its code-repository
> rubric and working-directory-only discovery never saw rules, skills, MEMORY.md or cross-file contradictions, so CSR #2450 replaced it.

---

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
if [ "$LINES" -gt 140 ]; then
  echo "⚠ Verification failed: ${LINES} lines (target ≤ 140). Further optimization needed." >&2
else
  echo "✅ Verification passed: ${LINES} lines (target ≤ 140)"
  ~/.claude/skills/memory-health/scripts/memory-health-log.sh \
    "F3" "MEMORY.md optimized" "${BEFORE} lines" "${LINES} lines"
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

> Added 2026-06-13: aria/CLAUDE.md (37.5K chars WARN) and kr-ai-trader/CLAUDE.md (20.4K chars WARN) were outside memory-health's size management (user chose option (가)). The Optimizer is MEMORY.md-only, so this read-only monitor backfills it; glob patterns auto-include split files (user follow-up). Content reduction stays in `/trader-task`.

---

## CLAUDE.md Integration (`--with-md`)

> **Prerequisite**: same as the "Monthly routine" section (procedure file + auditor definition, bundled claude-api skill on).

`--with-md` can be combined with other flags: `/memory-health --with-md`, `/memory-health --fix --with-md`.

### Execution flow (3 Phases)

**Phase A — memory health (existing behavior)**
- Runs the existing dry-run / `--fix` / `--scan` / `--rules` logic unchanged
- Proceeds to Phase B after Phase A completes

**Phase B — forced monthly routine (prompt-audit + skill update check)**

Regardless of the interval, runs both parts of the "Monthly routine" section as written (its own phase — after Phase A's writes finish):
`audit-record.sh pre` → spawn the subagent `memory-health-prompt-auditor-ro` (foreground) with the manifest paths →
save its final message to a file → `audit-record.sh post` → `audit-record.sh update-check`.
- Output: the state (`STATE`), finding counts, report + proposed diff, update-check list
- **No files are modified in this phase** (report only) — applying the proposed diff needs a separate approval

**Phase C — Session learnings handling**

After Phase B, learnings from this session are handled this way (not appended to CLAUDE.md — CSR #2435 D3):
- If a task post exists (CSR, trader_log, …), handle them at that task's G-7 guide step.
- Otherwise report them and state "보고만 했습니다 — 등록되지 않았습니다" (reported only — not recorded).

For `--fix --with-md`: Phase A `--fix` completes, then Phase B → C follows.

### --with-md completion criteria
- Phase A: same as the respective mode's completion criteria
- Phase B: state of both parts reported (no file changes)
- Phase C: learnings passed to the G-7 step, or "reported only — not recorded" stated

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
| `--with-md` (Phase B) | No | prompt-audit report + proposed diff only (read-only auditor agent, no file changes) |
| `--with-md` Phase B→edit | Once | Separate approval to apply the prompt-audit proposed diff (outside the audit phase) |

---

## CHANGELOG

| Date | Change |
|------|--------|
| 2026-10-29 | **CSR #2450 — 30-day audit engine replaced + skill update check added**. Engine moved from claude-md-improver (claude-md-management plugin) to the bundled claude-api `prompt-audit` procedure — the read-only subagent `memory-health-prompt-auditor-ro` (tools `Read, Grep, Glob`) audits a fixed scope (global CLAUDE.md, rules, MEMORY.md, this skill's two SKILL files, cwd CLAUDE.md) and only `scripts/audit-record.sh` (pre/post/update-check) decides the state. Update check (skill-advisor `update.py --json`, never applied) with separate markers (`claude-md-audit-last`, `skill-update-check-last`). Hook narrative corrected (unwired by CSR #2451 A1-P4, plugin command denied), Phase C replaced by the G-7 step (CSR #2435 D3). Plugin name removed from the notice. |
