---
name: memory-health
description: "Diagnoses and optimizes the health of Claude Code auto-memory files (MEMORY.md, memory/*.md) and auto-loaded rule files — MEMORY.md Optimizer R1~R10, memory/*.md Scanner, Rules Checker, and periodic CLAUDE.md audit (monthly routine). Use when MEMORY.md approaches its line or character cap, when memory/*.md files grow too large, when auditing CLAUDE.md or other auto-loaded rule files, when a session-start notice suggests running '/memory-health routine', or when the user asks to check or clean up these memory files or runs /memory-health. Not for recalling conversation content or remembered facts."
argument-hint: '[check] | fix [--R1...] [--json] | scan | rules [--strict] | --with-md | --fix | --scan | --rules [--strict] | --fix --json | --fix --with-md | --scan --with-md'
---

# /memory-health

> 🌐 **[Multilingual / 다국어]**
> For Korean → [`SKILL.md`](SKILL.md)
> 한국어로 사용하려면 → [`SKILL.md`](SKILL.md)
>
> **Language auto-detection**: Default output is Korean (same rule as `SKILL.md`). If the conversation is in English, output switches to English automatically.
> When the language is unclear or mixed, Korean (default) is used.

> ⚠️ **[SINGLE-SESSION ONLY]** Running multiple Claude tabs simultaneously can corrupt your files.
> Always use this skill in a single session. No locking mechanism is provided.

<!-- Sync checklist: whenever SKILL.en.md is modified, verify the following:
  - [ ] Apply the same changes to SKILL.md
  - [ ] If a reference/*.en.md file changed, apply the same change to its reference/*.md pair (ko/en file structure 1:1)
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

### v2 command structure (CSR #656)

> **Status (P7 disposition, CSR #962, 2026-05-29)**: v2 commands run **by interpreting this SKILL procedure** — no separate dispatcher script is needed and none is planned.
> - `catalog` and `rules` run dedicated scripts (`scripts/catalog.sh`, `scripts/check-rules.sh`)
> - `check`, `fix` and `scan` are carried out from this SKILL procedure (Claude's interpretation)
> - v1 commands keep working as deprecated aliases (until 2026-12-31)

```
/memory-health check         → diagnosis (hook-safe — memory files never changed · writes state records, runs git fetch) [Read first: reference/optimizer.en.md steps 1-3]
                              exit 0=ok, 1=warn, 2=critical
/memory-health fix [--R1...] → mutating Optimizer (R1~R10, explicit R numbers — per memory-health-rules.md) [Read first: reference/optimizer.en.md]
/memory-health scan          → Scanner (split memory/*.md, one approval) [Read first: reference/scanner.en.md]
/memory-health rules         → Rules Checker (auto-loaded files, read-only) [Read first: reference/rules-checker.en.md]
/memory-health rules --strict → exit 2 on WARN or worse [Read first: reference/rules-checker.en.md]
/memory-health catalog       → knowledge catalog builder (regenerates the 3-axis metadata index) [Read first: reference/with-md-catalog.en.md]
/memory-health fix --json    → dry-run JSON output [Read first: reference/optimizer.en.md steps 1-3]
/memory-health --with-md     → CLAUDE.md quality audit (combinable with every command) [Read first: reference/with-md-catalog.en.md · Phase A uses reference/optimizer.en.md]
```

**Command boundary (DA C-7)**:
- **check** = a diagnosis that never changes memory files (MEMORY.md, memory/*.md), hook-safe — safe to automate. It does run the remote check's `git fetch` and cooldown marker (②) and write the monthly routine's markers and report files (③) (RD)
- **fix / scan / rules** = explicitly mutating or read-only — separate surfaces
- default command = `check` (safe-side default)

### v1 commands (deprecated aliases — until 2026-12-31)

```
/memory-health               → diagnosis (= v2 check) [Read first: reference/optimizer.en.md steps 1-3]
/memory-health --fix         → Optimizer (= v2 fix, deprecated warning) [Read first: reference/optimizer.en.md]
/memory-health --scan        → Scanner (= v2 scan, deprecated warning) [Read first: reference/scanner.en.md]
/memory-health --rules       → Rules Checker (= v2 rules, deprecated warning) [Read first: reference/rules-checker.en.md]
/memory-health --rules --strict → (= v2 rules --strict) [Read first: reference/rules-checker.en.md]
/memory-health --fix --json  → (= v2 fix --json) [Read first: reference/optimizer.en.md steps 1-3]
/memory-health --with-md     → CLAUDE.md audit (same in v2) [Read first: reference/with-md-catalog.en.md · Phase A uses reference/optimizer.en.md]
```

The default is dry-run, so memory files (MEMORY.md, memory/*.md) are not changed. The remote check (②) runs `git fetch` and writes its cooldown marker (`.remote-check-last`); the monthly routine (③) writes its markers, jsonl and report files.

Execution flow:
```
/memory-health         → ① show dry-run results (no gate) [Read first: reference/optimizer.en.md — ① = its steps 1-3]
                          ② skill remote update check (CSR #962 — internet fetch, 4h cooldown, non-blocking)
                          ③ monthly routine (each part only when its own marker is due — see "Monthly routine")
                             audit part: audit-record.sh pre → read-only auditor agent → post
                             update part: audit-record.sh update-check (check only, never apply)
                          ℹ️  Rules Checker not included — use /memory-health --rules or MEMORY_HEALTH_DEFAULT_RULES=true (if set, Read first: reference/rules-checker.en.md)
/memory-health --fix   → show dry-run results → approval gate → execute [Read first: reference/optimizer.en.md]
/memory-health --scan  → show scan results    → approval gate → execute [Read first: reference/scanner.en.md]
/memory-health --rules → run Rules Checker (no file changes, no gate) [Read first: reference/rules-checker.en.md]
/memory-health --with-md → Phase A(memory health dry-run) → Phase B(forced monthly routine, even if not due) → Phase C(session learnings handling) [Read first: reference/with-md-catalog.en.md · Phase A uses reference/optimizer.en.md]
```

### Procedure files (reference/) — Read the whole file before running

`[Read first: reference/X.en.md]` on a command line above = before running that command, Read that file in full (the procedure text lives there).

| File | Content | Entry points that read it |
|---|---|---|
| `reference/optimizer.en.md` | every Optimizer step, completion criteria | default `/memory-health` (= `check`, ① = steps 1-3) · `fix`/`--fix` · `fix --json`/`--fix --json` (steps 1-3) · `--with-md` Phase A |
| `reference/scanner.en.md` | Scanner steps 1-6, completion criteria | `scan`/`--scan` |
| `reference/rules-checker.en.md` | Rules Checker + project CLAUDE.md size monitoring | `rules`/`--rules` (`--strict`) · the default run when `MEMORY_HEALTH_DEFAULT_RULES=true` |
| `reference/with-md-catalog.en.md` | `--with-md` Phases A-C · Catalog | `--with-md` · `catalog` |

### --fix --json mode

Before this step, Read `reference/optimizer.en.md` in full (steps 1-3).
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

## Skill remote update check (default run ②, CSR #962)

On the default `/memory-health` run (dry-run), checks over the internet whether the installed skill is **behind its remote (github)**. It mirrors the proven pattern of `forge-update-check.sh`.

```bash
bash ~/.claude/skills/memory-health/scripts/check-skill-update.sh
```

- **Behavior**: `git fetch origin` (4s timeout) → compare local HEAD with the origin default branch → if behind, one advisory line ("skill update: N commits … git pull")
- **4h cooldown**: avoids fetching on every run (`MEMORY_HEALTH_STATE_DIR/.remote-check-last`). `--force` ignores it (for tests)
- **Non-blocking**: offline, timeout and non-git all exit 0 with no output (graceful). Safe without a network
- **Handling the result**: report the advisory to the user as printed. Whether to apply the update is the user's decision (no automatic pull)

> Separate from forge-update-check.sh (the whole framework, SessionStart) — this one covers only the memory-health **skill repo** and is part of the default `/memory-health` run.

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
Do not report these again (dismissed earlier, path | quote): <DO_NOT_REPORT>
Emit one `FINDING <json>` line per finding (one-line JSON object with keys sev, path, line, quote, summary;
quote = the offending file text verbatim, at most 120 characters, JSON-escaped), then one `FINDINGS_TOTAL <n>` line.
End with one `COVERED: <abs path> last_line=<n>` line per path above (n = the last line number your
Read tool showed for that file), then one `FINDINGS high=<n> medium=<n> low=<n>` line.
```

Replace `<DO_NOT_REPORT>` with the output of `python3 "$AR_DIR/routine_items.py" do-not-report` (`none` when empty). `AR_DIR` = the folder holding `$AR`.

③ Save the agent's **full final message** to `$RUN_DIR/report.md` (Write — no summarizing or editing).

```bash
bash "$AR" post "$RUN_DIR" "$RUN_DIR/report.md"   # ④ refreshes claude-md-audit-last only on REPORTED
```

Report: `STATE`, finding counts, and the saved copy (`~/.claude/da-tools/claude-md-audit-reports/<ts>.md`, mode 600, newest 12 kept).
`post` prepends a header to the copy (state, read_evidence, residuals RE/RF/RH; on `AUDITOR_CHANGED` also "신뢰 불가 — AUDITOR_CHANGED" = untrusted); the agent's text follows unchanged.
If the Agent call itself errors, skip ③④, run the command below, then report "audit engine unavailable (ENGINE_UNAVAILABLE)" — no marker refresh:

```bash
bash "$AR" fail "$RUN_DIR" "<agent error text>"   # records ENGINE_UNAVAILABLE in the jsonl · never touches claude-md-audit-last
```

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
| `ENGINE_UNAVAILABLE` | pre · fail | procedure file missing (pre), or the Agent call errors (`fail`) | none |
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

### Observe → ingest → dispose (`/memory-health routine`, CSR #2491)

So that a run never ends at "audit done, finished": everything the routine finds becomes a **ledger item**, and a run ends only when
every item has a **disposition**. Tool = `scripts/routine_items.py` (stdlib, `/usr/bin/python3` 3.9). Local state folder `$MH_LOCAL_DIR`
(default: `memory-health-local/` in the Claude config folder, a real folder, not a symlink) — ledger `items.jsonl` (append-only single record) ·
this machine's channel list `channels.json` (never committed to a public repo) · part records `parts.jsonl`·`part-<C~F>-last` · audit scope progress `audit-coverage.json`.

**Who and when**: ① detect = the existing SessionStart hook `memory-rules-drift-check.sh` calls `routine_items.py peek` first, every session
(local reads only, 1 s budget, at most 600 chars — open item count, due parts, new channel events). A non-zero peek exit prints one line
`routine peek FAILED rc=<n>`. If the hook itself does not run, a second SessionStart command `peek-watchdog.sh` (installed by **copy** into the
state folder) prints one line `routine detector stale`. ② ingest + dispose = the interactive session that receives the notice runs the following
before other work (not in `claude -p` — its hooks see `CLAUDE_CODE_ENTRYPOINT=sdk-cli` (interactive = `cli`, measured), so peek prints only the count line there).

```bash
RI="python3 $HOME/.claude/skills/memory-health/scripts/routine_items.py"   # adjust to the install location
$RI start [--force]          # take the routine lease + run row (due_parts); refused while another session used it in the last 30 min
# only the due parts (--force = all seven):
#  P-A fixed-scope audit  — the 4 steps above → $RI ingest-audit --run-dir "$RUN_DIR" --part A
#  P-B skill updates      — bash "$AR" update-check > "$T/upd.txt"; $RI ingest-update --file "$T/upd.txt"
#  P-C update channels    — $RI scan-channels        (builtin plugins channel + log_lines/stamp_age channels from channels.json)
#  P-D install diagnosis  — $RI ingest-doctor        (claude doctor, read-only, 60 s cap)
#  P-E rolling full audit — $RI plan-shards → per shard: pre --shard <manifest> → auditor → post → ingest-audit --part E → cover --run-dir … --shard N
#                           (an AUDIT_INCOMPLETE shard: plan-shards --split N halves it, retried once)
#  P-F unused extensions  — $RI scan-unused          (reads only the skillUsage/pluginUsage keys of ~/.claude.json — it also holds credentials)
#  P-G embedded npm deps  — $RI scan-deps          (dep_roots/npx_specs from channels.json — both live only in the local channels.json; skills/plugins themselves belong to P-B/P-C)
#  a part that could not run at all: $RI part-fail --part X --reason "<why>"
$RI status --check-refs --run <RUN_ID>   # repeat until disposition is complete
```

- P-E scope = the official `/doctor prompt-audit` default scope (CLAUDE.md, rules, skills, commands, agents, output-styles in the config folder) plus,
  for each root in `channels.json` `project_roots`, its CLAUDE.md, CLAUDE.local.md, AGENTS.md and `.claude/{rules,skills,commands,agents,output-styles}`.
  600,000 chars a month (8 shards of 75,000); at least 300,000 go to never-audited then oldest-audited files, the rest to changed files. Files larger than
  75,000 chars are split into line-range chunks covered over several months. `plan-shards` prints the never-audited count and the maximum audit age every
  run; a project root found under `discover_dirs` (depth 2) but not listed, or a listed root that is missing, becomes an `unknown` item.
- A chunk (`path#L<start>-<end>`) must report its given end line in `COVERED`, so its "opened it" evidence is weaker than a whole file's (the range is told).

**Dispose** — `$RI dispose <id>... --disp <kind> …` (several ids at once; if any violates a rule nothing is written):

| disposition | needs | not accepted when |
|---|---|---|
| `fixed` | `--ref` = commit sha · PR URL · `CSR #N c#M` (checked against that post's comments) | an audit finding whose file still holds the quote · `part_failed` only with the `ts` of a later PASS row of the same run |
| `task` | `--ref "CSR #N"` — that post's body or a comment must contain the item id verbatim | board unreachable |
| `dismissed` | `--reason` ≥ 20 chars | allowed kinds only: audit finding (not high), update-available, unused-extension, plugin-version-changed, unclassified. An audit-finding dismissal is bound to the file's sha256 and reopens when the file changes |
| `deferred` | all of `--goal --deadline (YYYY-MM-DD, within 90 days) --method --revert` | once per item · not for sev=high |
| `verified` | `--reason` with evidence (command + output line) ≥ 20 chars | `unknown` and `unobserved_plugin` cannot be closed by a session — the next scan must re-read the source; then the tool writes `fixed recheck:<run>` |

| item kind | what the session does |
|---|---|
| audit finding high | `fixed` or `task` in the same session |
| audit finding medium/low | `fixed` in this batch, `dismissed` with a reason, or `deferred` |
| fix in claude-forge / memory-health / skill-advisor | one worktree and one PR per repo; merge approval asked once at the end of the run |
| fix in personal local files | direct edit after a backup |
| owner-only (money, permission, credentials, irreversible, taste) · doctor permission-rule warning | `task` into this month's follow-up CSR, tagged `waiting` |
| skill update available | read the upstream diff; `update.py <skill> --apply` in a claude-forge worktree + PR, or `dismissed` (local divergence on purpose) |
| plugin version changed | check `claude plugin list --json` shows it enabled without errors → `verified` |
| auto-update marketplace not refreshed for > 14 days | `claude plugin marketplace update <name>`, re-check, record |
| `unobserved_plugin` (auto-update off + no upstream observation in 45 days) | add an observation rule to an upstream-checking channel or turn auto-update on — the next scan closes it |
| `runner-stale` | diagnose with `launchctl list`, the log and rc; fix if no sudo is needed, else owner `task` |
| `part_failed` | re-run the part in the same run → PASS → `fixed` (that row's ts). Otherwise `task` — the run ends with exit 4 (not complete) and the part is due again next session |
| `cursor_reset` | read the log from the start (and the replaced file if any), ingest missed events, `verified` |
| `unclassified` | extend the channel's event/ignore regexes and `verified` (evidence = the regex), or `dismissed` |
| `orphaned_task`, `unlinked_task` | dispose again — a new `task`, or add an id comment to that CSR |

- **At most one follow-up CSR per month** ("월간 루틴 YYYY-MM 후속", created only by the lease holder after searching for the same title) — never one CSR per item.
- **Completion**: done **only when** `status --check-refs --run <latest run_id>` exits **0** — 1 open items · 2 ledger unknown / overdue deferral / refs unchecked / a due part without PASS · 4 blocked, handed to a follow-up (not complete). The report ends with that STATUS line.
- **Later versions**: no per-version observation items — the channel checks are permanent (peek every session + monthly ingest).
- **Public-repo boundary**: before a push/PR to memory-health or skill-advisor run `$RI boundary-check --repo <repo> [--body <PR body file>]` — gitleaks + the deny list (`boundary-deny.txt`, regenerated by every `scan-channels`) + whole-word project root names. Blocks when the list is absent or empty, gitleaks errors, or no base commit can be found.
- `channels.json` keys: `channels[]` (`id`, `type`=`log_lines`|`stamp_age`, `path`, `events[{re,kind,sev,observe,plugin}]`, `ignore[]`, `stale_path`, `max_age_h`) · `required_ids[]` · `project_roots[]` · `discover_dirs[]` · `board_post_url` (`{n}` = post number) · `gitleaks_cmd` (optional).

### What is covered (Covers — Round-8 wording)

> The auditor's tool calls are read-only provided the invoked agent actually uses the validated read-only definition
> and Claude Code enforces its tool allowlist. Pre/post hashing detects persistent definition changes but cannot
> establish that the definition remained unchanged throughout invocation. Concurrent changes, including changes
> subsequently restored and live-reload effects, are excluded from this guarantee. A matching hash does not certify
> runtime definition integrity.

### Residual risks (disclosed)

- **RA** Relies on Claude Code honoring the `tools` allowlist (documented) — `pre` catches an edited definition, not a harness regression.
- **RB** The user-typed `/doctor prompt-audit` full run executes in the main session with all tools (auto mode) — protection covers only this routine.
- **RC** The auditor cannot spawn sub-auditors — the monthly scope must fit one agent; truncation shows as AUDIT_INCOMPLETE; growing D1-scope requires re-running V8 (one real auditor run over the whole scope confirming REPORTED) — the `rules/*.md` glob is re-expanded at every `pre`, so the scope grows without anyone widening it on purpose.
- **RD** The main session writes the report, jsonl and both markers (fixed paths outside the audit scope).
- **RE** Model-orchestrated — the script cannot prove the saved text came from the auditor; finding counts are the auditor's own.
- **RF** Session-only `--add-dir` / `/add-dir` / `--agents` definitions are not visible on disk, so `pre` cannot see them — run in a session started without those flags.
- **RG** Hook side effects are outside the guarantee — the scope sha256 comparison only catches a persistent byte change between the two snapshots, not transient writes restored before `post`, same-content rewrites, or writes outside the scope.
- **RH** A definition changed and restored to identical bytes between pre and post, or changes delivered by live reload in that window, cannot be seen by a byte comparison.

### Full-scope audit (run by the user)

To audit all skills, commands and agents under `~/.claude/`, the user types `/doctor prompt-audit` (no path) themselves.
⚠ That run is **not write-protected** (RB · claude-code issue #99288: files edited with no apply request) — review the
proposed diff before approving any apply. memory-health never runs the full scope automatically (cost).

> Engine replacement history (claude-md-improver → prompt-audit, CSR #2450): [`CHANGELOG.md`](CHANGELOG.md)

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
| **WAL init fails (Atomicity)** | `memory-wal.sh init` exit ≠ 0 | before any change, original preserved | `memory-wal.sh list` |
| **Uncommitted WAL found (Atomicity)** | process stopped after a change → WAL remains | mid-change — file integrity in doubt | `memory-wal.sh recover` → `rollback` → restore from `memory-backup.sh` |
| **Journal chain break (Atomicity)** | `memory-journal.sh verify` exit ≠ 0 | log tampered or damaged — reliability in doubt | check `memory-journal.sh tail 20`, then compare with an external backup |
| **Sidecar fingerprint mismatch (R6)** | sha256 comparison fails | the user edited directly, then re-ran the tool | normal — proceed with the change + refresh the sidecar |

> **Atomicity flow (Phase C — CSR #658, 2026-05-19)**:
> 1. `wal_id=$(memory-wal.sh init "$files" "$rules")` — prepare phase
> 2. `memory-backup.sh` — guarantees a backup right before the change (existing behavior)
> 3. apply the approved R rules — the actual file change
> 4. `memory-journal.sh log <action> "$files" "$rules" "$wal_id" '{...}'` — append-only audit
> 5. `memory-wal.sh commit "$wal_id"` — atomic completion signal (WAL deleted)
>
> On interruption: the WAL remains → on the next run `memory-wal.sh recover` detects it → after user confirmation, `rollback` + `git checkout` or a backup restore.

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
| dry-run (default) | No | Auto-approved scope (no memory-file changes — writes only state records and report files, RD) |
| `--fix` | Once | MEMORY.md content changes |
| `--scan` | Once | memory/*.md content changes |
| `--rules` | No | read-only, no file changes |
| `catalog` | No | read-only (creates only the two catalog/ index files, originals untouched) |
| `--fix --json` | No | Same as dry-run, exits after JSON output |
| `--with-md` (Phase B) | No | prompt-audit report + proposed diff only (read-only auditor agent, no file changes) |
| `--with-md` Phase B→edit | Once | Separate approval to apply the prompt-audit proposed diff (outside the audit phase) |

---

Change history and background: [`CHANGELOG.md`](CHANGELOG.md)
