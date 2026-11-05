# /memory-health — `--with-md` and Catalog procedures (reference)

## CLAUDE.md Integration (`--with-md`)

> **Prerequisite**: same as the "Monthly routine" section (procedure file + auditor definition, bundled claude-api skill on).

`--with-md` can be combined with other flags: `/memory-health --with-md`, `/memory-health --fix --with-md`, `/memory-health --scan --with-md`.

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
