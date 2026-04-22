# memory-health

> [한국어](README.ko.md) | English
> **Canonical source: README.md (English). README.ko.md is a translation and may lag behind.**

> 🌐 **Skill files**: [`SKILL.md`](SKILL.md) (Korean, default) · [`SKILL.en.md`](SKILL.en.md) (English)
> Claude Code detects your conversation language and uses the matching skill file automatically.
> You can also reference the English skill file directly by pointing Claude to `SKILL.en.md`.

> **Memory grows. Context limits. memory-health keeps Claude sharp.**

A Claude Code skill that diagnoses and optimizes memory files in custom auto-memory setups — before silent truncation degrades your AI assistant's context.

---

## Who This Is For

Some Claude Code users build a **custom auto-memory system** — a setup where Claude reads a set of Markdown files at the start of every session to remember past context. If you've built something like this, here's how it typically works:

- `MEMORY.md` is loaded at session start as an index of what Claude should remember
- `memory/*.md` files hold the actual memory entries, referenced from the index
- The loading mechanism has a **hard limit of 200 lines** on `MEMORY.md`

**The problem**: Once `MEMORY.md` exceeds 200 lines, everything past line 200 is silently dropped. You won't get an error — Claude just won't remember things it used to know. By the time you notice, the context is already gone.

**How to tell if this applies to you**: If `~/.claude/hooks/memory-line-check.sh` exists in your setup and MEMORY.md is triggering ≥180-line warnings, this skill is for you.

If you're using Claude Code's built-in memory features rather than a custom file-based system, this skill doesn't apply.

---

## The Problem

| Constraint | Type | Value | Source |
|-----------|------|-------|--------|
| MEMORY.md line cutoff | **Hard limit** | 200 lines | Context injection mechanism design |
| MEMORY.md safety target | Safety margin | 180 lines | 200 − 20-line buffer (aligns with hook warning threshold) |
| memory/*.md size threshold | **Empirical** | 5,000 chars | Observed context crowding in practice |

Content beyond line 200 of `MEMORY.md` is **silently not loaded** by the context injector. By the time you notice the problem, valuable memory is already gone.

## The Solution

`/memory-health` runs before memory goes missing — diagnosing file sizes, warning about threshold breaches, and offering safe, approval-gated optimization.

---

## Requirements

**Platform**: macOS (requires `pgrep` and `lsof` for auto-detection). Linux is not officially supported — `install.sh` will fall back to manual path entry if these tools are absent.

**Before running `bash install.sh`**, verify:

- [ ] **Claude Code is currently running** — `install.sh` auto-detects the memory directory from the active Claude process. If Claude is not running, auto-detection is skipped and you'll be prompted to enter the path manually.
- [ ] **Git is installed** — required for rollback in `--scan` mode
- [ ] **You know your memory directory path** — typically `~/.claude/projects/<encoded-path>/memory/`

After running `bash install.sh`, ensure the following are in place before using the skill:

- **Claude Code** with skill execution enabled
- **Git** — required for rollback in `--scan` mode; target files must be tracked and the working tree must be clean before running (`git status --porcelain` and `git ls-files` of target files should be verified)
- **`memory-health-rules.md`** — present in your memory directory; defines R1–R5 rules governing which MEMORY.md entries are candidates for removal or compression (`install.sh` copies this automatically)
- **`memory-backup.sh`** hook — copied to `~/.claude/hooks/` and registered in `settings.json` (`install.sh` copies the file; `settings.json` registration requires one manual step — see installer output)

### Initial Setup (run once)

Run `install.sh` to auto-detect the correct memory directory and set `CLAUDE_MEMORY_DIR`:

```bash
bash install.sh
```

Or set manually, then create required files:

```bash
export CLAUDE_MEMORY_DIR="<your-memory-dir>"   # see install.sh for detection method
touch "$CLAUDE_MEMORY_DIR/violation-archive.md" && echo "created: violation-archive.md"
touch "$CLAUDE_MEMORY_DIR/skill-audit.log"      && echo "created: skill-audit.log"
```

> **Why `install.sh` instead of `$(whoami)`?** Claude Code generates project paths from the working directory's absolute path, not just the username. A simple username substitution will break on non-standard setups. `install.sh` detects the actual path at runtime.

> `violation-archive.md` stores rule-violation records written by the audit system. Explicit initialization prevents accidental creation in the wrong directory.

---

## Features

| Feature | Flag | File changes? | What it does |
|---------|------|:-------------:|--------------|
| Diagnose | *(default)* | No | Dry-run: reports current line/char counts |
| Optimizer | `--fix` | **Yes** | Trims MEMORY.md to ≤ 180 lines (approval gate required) |
| Scanner | `--scan` | **Yes** | Finds `memory/*.md` > 5,000 chars; splits into `*-part2.md` (approval gate required) |
| JSON output | `--fix --json` | No | Dry-run results as JSON (pipeline/automation); exits after stage 3, no file changes |

---

## Usage

```
/memory-health          → Diagnose only (dry-run, no approval needed)
/memory-health --fix    → Optimizer: trim MEMORY.md (1 approval gate)
/memory-health --scan   → Scanner: split oversized memory files (1 approval gate)
/memory-health --fix --json  → JSON dry-run output (exits after Propose stage)
```

> **`--fix` and `--scan` both modify files.** A backup runs automatically before any changes are made. If something goes wrong, you can recover with `git checkout -- <file>`.
> Neither flag does anything until you explicitly confirm — the default (`/memory-health` with no flags) is always a safe, read-only diagnosis.

---

## How It Works

### Optimizer (`--fix`): MEMORY.md Line Trimmer

7-stage pipeline with hard stops (points where a failure blocks the next stage):

1. **Diagnose** — measure current line and byte count
2. **Analyze** — load R1–R5 rules from `memory-health-rules.md`; no ad-hoc judgment
3. **Propose** — show candidate changes and projected line count (dry-run, read-only preview) — *`--json` flag exits here, outputting results as JSON with no further stages executed*
4. **Approve** — you'll need to confirm explicitly before anything changes
5. **Backup** — `memory-backup.sh` runs automatically; if the backup fails, the whole operation stops here
6. **Execute** — apply approved changes to MEMORY.md
7. **Verify** — assert `wc -l ≤ 180`; log to `skill-audit.log`

**Done when**: `wc -l MEMORY.md ≤ 180` + audit log entry recorded (stages 1–7 completed successfully).

### Scanner (`--scan`): memory/*.md Size Manager

6-stage pipeline with 2-phase commit (a write strategy that either applies all changes at once or rolls all of them back):

1. **Scan** — find all `memory/*.md` (excluding MEMORY.md) exceeding 5,000 chars
2. **Measure & Report** — list files with char counts and section headers
3. **Propose** — suggest split points (Markdown section headers / logical boundaries); output: `{original}-part2.md`
4. **Select & Approve** — you choose the split point and confirm before anything changes
5. **Backup + Execute (2-phase commit)**:
   - Phase 1 (Prepare): write temporary files and prepare pointer updates — nothing is committed yet
   - Phase 2 (Commit): verify the split is lossless (±3 chars tolerance for line-ending differences), then apply everything at once
   - If anything goes wrong, all changes are rolled back automatically via `git checkout`
6. **Verify & Log** — re-measure output files; **audit log recorded only on commit success**; rollback exits with error log

**Done when**: all processed files ≤ 5,000 chars + MEMORY.md pointers updated + commit succeeded + audit log entry recorded.

> **Design note**: The Optimizer uses `memory-backup.sh` for recovery (single-file change). The Scanner uses Git for rollback integrity across multiple files. This difference is intentional.

---

## Role Boundary

| Component | File | Role | Side effects |
|-----------|------|------|--------------|
| Hook | `memory-line-check.sh` | Auto-watch + warn only | None |
| Skill | `/memory-health` | Interactive manual execution + optimization | **File changes** |

The hook tells you when something's off. This skill is what actually fixes it.

---

## Audit Log

```
Location: ${CLAUDE_MEMORY_DIR}/skill-audit.log
Format:   {ISO8601} | {Feature} | {Summary} | {Before} → {After}

Example:
  2026-04-21T20:00:00+0900 | F3 | MEMORY.md optimization | 195 lines → 142 lines
  2026-04-21T20:10:00+0900 | F4 | project-fss.md split | 25,190 chars → 4,800 + 4,200 chars
```

Rotation: auto-rotates to `.old` when file exceeds 50KB. Maximum 2 generations retained.

The log path is controlled by the `$CLAUDE_MEMORY_DIR` environment variable in `memory-health-log.sh`.

---

## Limitations

| Limitation | Details |
|-----------|---------|
| **Single-session only** | No lock mechanism — concurrent Claude tabs may corrupt files |
| **Local filesystem only** | Remote sync and cloud storage are not supported |
| **AI instruction file** | `SKILL.md` is an LLM instruction file interpreted by Claude at runtime, not a standalone executable |
| **Custom auto-memory only** | Works only with a specific file-based auto-memory pattern, not official Claude Code features |

---

## File Structure

```
~/.claude/skills/memory-health/
├── SKILL.md                          # Skill definition and pipeline spec
├── INTERFACES.md                     # Component contract specifications
├── memory-health-rules.md            # R1-R5 optimization rules template
├── install.sh                        # Setup: auto-detects memory dir, sets CLAUDE_MEMORY_DIR
└── scripts/
    ├── memory-health-log.sh          # Audit log writer + auto-rotate
    └── memory-backup.sh              # Backup sample (copy to ~/.claude/hooks/)

# External dependencies (not in this repo):
~/.claude/hooks/
├── memory-line-check.sh              # Watch hook: warns when MEMORY.md >= 180 lines
└── memory-backup.sh                  # Backup hook: hard stop gate for --fix

${CLAUDE_MEMORY_DIR}/
├── MEMORY.md                         # Session index (managed by Optimizer)
├── memory-health-rules.md            # R1-R5 optimization rules (required)
├── skill-audit.log                   # Execution history
└── violation-archive.md              # Rule-violation archive (created in setup)
```

---

## Approval Policy

When `--fix` or `--scan` is used, you'll need to confirm before any files change. Saying something like "looks good" or "sure" will prompt a follow-up — the response needs to clearly indicate you want to proceed.

| Mode | Approval required | Example of valid approval |
|------|:-----------------:|---------------------------|
| dry-run (default) | No | — |
| `--fix` | **Yes** | "proceed", "yes, apply", "확정해주세요" |
| `--scan` | **Yes** | "proceed", "yes, apply", "확정해주세요" |

---

## Related

- `memory-line-check.sh` — hook that monitors MEMORY.md line count
- `memory-health-rules.md` — R1–R5 ruleset governing Optimizer decisions
- `skill-audit.log` — full execution history

---

*Part of the [Claude Code Skills](https://github.com/aniboy2k-gif/memory-health) collection.*
