#!/usr/bin/env python3
"""build-catalog.py — memory-health knowledge catalog builder (3-axis, metadata-only).

Collects metadata (NOT full content) for every Markdown file Claude references,
plus the AI bulletin-board guide/task-log posts, into a regenerable, versioned
index: catalog/knowledge-catalog.json (machine SSOT) + knowledge-catalog.md
(human/Claude navigation summary).

Axes:
  1. MD files   — roots walked with symlink follow + realpath de-dup
  2. Board DB   — bulletin.db {board}_posts (guide vs task-log), metadata only
  3. Config     — CLAUDE.md / rules / rules-canonical tagged within axis 1

Design: read-only except the two output files. No file content is collected —
only frontmatter description/name + first heading (head bytes only).
"""

import os
import re
import sys
import json
import time
import sqlite3

HOME = os.path.expanduser("~")
MEMORY_DIR = os.environ.get("CLAUDE_MEMORY_DIR", "")
BB_HOME = os.environ.get("BB_HOME", os.path.join(HOME, "workspace", "bulletin-board"))

ROOTS = [
    os.path.join(HOME, ".claude"),
    os.path.join(HOME, "workspace"),
    "/Volumes/L'Atelier de Claude/workspace",
]
PRUNE_DIRS = {
    "node_modules", ".git", ".venv", "venv", "site-packages", "models",
    "__pycache__", ".backups", ".cache", ".next", "dist", "build",
}
HEAD_BYTES = 4096          # enough for frontmatter + first heading, never full content
GUIDE_BOARD_SET = {"claude_docs"}   # boards that are guides without a "guide" substring


def categorize(realpath: str) -> str:
    name = os.path.basename(realpath)
    p = realpath
    if "/claude-forge/skills/" in p or "/.claude/skills/" in p:
        return "skill"
    if "/claude-forge/agents/" in p or "/.claude/agents/" in p:
        return "agent"
    if "/claude-forge/hooks/" in p or "/.claude/hooks/" in p:
        return "hook-doc"
    if "/rules-canonical/" in p or "/claude-forge/rules/" in p:
        return "rule-canonical"
    if "/.claude/rules/" in p:
        return "rule"
    if name == "CLAUDE.md":
        return "project-config"
    if "/.claude/projects/" in p and "/memory/" in p:
        if name.startswith("MEMORY"):
            return "memory-index"
        if name.startswith("feedback"):
            return "feedback"
        return "memory"
    if "/da-system/" in p or "/da-tools/" in p:
        return "da-tool-doc"
    return "workspace-project"


def extract_meta(path: str):
    """Return (title, description) reading only the head — never full content."""
    title = None
    desc = None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            head = fh.read(HEAD_BYTES)
    except Exception:
        return title, desc
    lines = head.split("\n")
    # YAML frontmatter (only name/description keys)
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                break
            m = re.match(r"\s*(name|description)\s*:\s*(.+)", lines[i])
            if m:
                key, val = m.group(1), m.group(2).strip().strip('"\'')
                if key == "description" and not desc:
                    desc = val
                elif key == "name" and not desc:
                    desc = val
    # first markdown heading
    for ln in lines:
        m = re.match(r"#{1,6}\s+(.+)", ln)
        if m:
            title = m.group(1).strip()
            break
    return title, desc


def scan_md(exclude_dirs=()):
    seen = {}            # realpath -> entry
    skipped_roots = []
    visited_dirs = set()
    excl = tuple(os.path.realpath(d) for d in exclude_dirs)
    for root in ROOTS:
        if not os.path.isdir(root):
            skipped_roots.append({"root": root, "reason": "not_mounted_or_missing"})
            continue
        for dirpath, dirnames, filenames in os.walk(root, followlinks=True):
            rd = os.path.realpath(dirpath)
            if rd in visited_dirs:        # symlink cycle / re-entry guard
                dirnames[:] = []
                continue
            # never scan the catalog's own output dir (self-reference → non-idempotent)
            if any(rd == e or rd.startswith(e + os.sep) for e in excl):
                dirnames[:] = []
                continue
            visited_dirs.add(rd)
            dirnames[:] = [d for d in dirnames if d not in PRUNE_DIRS]
            for fn in filenames:
                if not fn.endswith(".md"):
                    continue
                ap = os.path.join(dirpath, fn)
                try:
                    rp = os.path.realpath(ap)
                except Exception:
                    rp = ap
                if rp in seen:
                    if ap not in seen[rp]["access_paths"]:
                        seen[rp]["access_paths"].append(ap)
                    continue
                try:
                    st = os.stat(ap)
                    size, mtime = st.st_size, int(st.st_mtime)
                except Exception:
                    size, mtime = None, None
                title, desc = extract_meta(ap)
                seen[rp] = {
                    "realpath": rp,
                    "access_paths": [ap],
                    "category": categorize(rp),
                    "title": title,
                    "description": desc,
                    "size": size,
                    "mtime": mtime,
                }
    return list(seen.values()), skipped_roots


def index_board():
    # Resolve the SAME DB the live board server uses (src/db/database.js):
    #   DB_PATH env  ||  ~/Library/Application Support/bulletin-board/bulletin.db
    # then fall back to the in-repo copies (which may be stale).
    candidates = []
    if os.environ.get("DB_PATH"):
        candidates.append(os.environ["DB_PATH"])
    candidates.append(os.path.join(HOME, "Library", "Application Support",
                                   "bulletin-board", "bulletin.db"))
    candidates.append(os.path.join(BB_HOME, "data", "bulletin.db"))
    candidates.append(os.path.join(BB_HOME, "database.db"))
    db = next((c for c in candidates if os.path.isfile(c)), None)
    if not db:
        return {"available": False, "reason": "db_not_found"}, []
    boards, entries = [], []
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        cur = con.cursor()
        tables = [r[0] for r in cur.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name LIKE '%\\_posts' ESCAPE '\\' ORDER BY name")]
        for t in tables:
            board = t[:-6]
            btype = "guide" if ("guide" in board or board in GUIDE_BOARD_SET) else "tasklog"
            cols = [r[1] for r in cur.execute(f"PRAGMA table_info({t})")]
            sel = [c for c in ("id", "title", "status", "tags", "updated_at", "created_at")
                   if c in cols]
            if not sel:
                continue
            rows = list(cur.execute(f"SELECT {','.join(sel)} FROM {t} ORDER BY id"))
            boards.append({"board": board, "type": btype, "count": len(rows)})
            for row in rows:
                d = dict(zip(sel, row))
                d["board"] = board
                d["board_type"] = btype
                entries.append(d)
        con.close()
    except Exception as e:
        return {"available": False, "reason": f"query_error:{e}"}, []
    return {"available": True, "db": db, "boards": boards}, entries


def counts_by(items, key):
    out = {}
    for it in items:
        out[it.get(key)] = out.get(it.get(key), 0) + 1
    return dict(sorted(out.items(), key=lambda kv: -kv[1]))


def build():
    if not MEMORY_DIR:
        sys.stderr.write(
            "❌ CLAUDE_MEMORY_DIR is not set — cannot write catalog.\n"
            "   Set it via ~/.claude/settings.json env / ~/.zshrc / install.sh\n")
        return 1
    out_dir = os.path.join(MEMORY_DIR, "catalog")
    os.makedirs(out_dir, exist_ok=True)

    md_entries, skipped_roots = scan_md(exclude_dirs=[out_dir])
    board_meta, board_entries = index_board()
    md_by_cat = counts_by(md_entries, "category")

    config_cats = ("project-config", "rule", "rule-canonical")
    config_entries = [e for e in md_entries if e["category"] in config_cats]

    catalog = {
        "schema_version": "1",
        "generated_ts": int(time.time()),
        "generated_iso": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "roots": ROOTS,
        "md": {
            "count": len(md_entries),
            "by_category": md_by_cat,
            "skipped_roots": skipped_roots,
            "entries": sorted(md_entries, key=lambda e: (e["category"], e["realpath"])),
        },
        "board": {
            **board_meta,
            "post_count": len(board_entries),
            "entries": board_entries,
        },
        "config_hierarchy": {
            "count": len(config_entries),
            "entries": sorted(config_entries, key=lambda e: e["realpath"]),
        },
    }

    json_path = os.path.join(out_dir, "knowledge-catalog.json")
    tmp = json_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(catalog, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, json_path)

    md_path = os.path.join(out_dir, "knowledge-catalog.md")
    write_md_index(md_path, catalog)

    print(f"✅ catalog built: {json_path}")
    print(f"   MD files: {len(md_entries)} (categories: {len(md_by_cat)})")
    if board_meta.get("available"):
        print(f"   Board: {len(board_meta['boards'])} boards, {len(board_entries)} posts")
    else:
        print(f"   Board: unavailable ({board_meta.get('reason')})")
    if skipped_roots:
        print(f"   ⚠ skipped roots: {[r['root'] for r in skipped_roots]}")
    print(f"   Navigation: {md_path}")
    return 0


def write_md_index(path, catalog):
    """Human/Claude navigation summary — kept compact (full detail lives in JSON)."""
    L = []
    L.append("# Knowledge Catalog (navigation)")
    L.append("")
    L.append(f"> 자동 생성 — `/memory-health catalog`. {catalog['generated_iso']}. "
             "전체 항목은 `knowledge-catalog.json` (jq/grep 조회). 본 파일은 요약·진입점.")
    L.append("")
    md = catalog["md"]
    L.append(f"## MD 파일 — {md['count']}개 (심링크 중복제거 후)")
    L.append("")
    L.append("| 카테고리 | 개수 |")
    L.append("|----------|-----:|")
    for cat, n in md["by_category"].items():
        L.append(f"| {cat} | {n} |")
    if md["skipped_roots"]:
        L.append("")
        L.append("⚠ **미수집(coverage gap)**: " +
                 ", ".join(f"`{r['root']}` ({r['reason']})" for r in md["skipped_roots"]))
    L.append("")
    board = catalog["board"]
    if board.get("available"):
        guides = [b for b in board["boards"] if b["type"] == "guide"]
        tasks = [b for b in board["boards"] if b["type"] == "tasklog"]
        L.append(f"## AI 게시판 — {board['post_count']}개 게시물 / {len(board['boards'])}개 보드")
        L.append("")
        L.append("### 가이드 보드")
        L.append("")
        L.append("| 보드 | 게시물 |")
        L.append("|------|-------:|")
        for b in sorted(guides, key=lambda x: -x["count"]):
            L.append(f"| {b['board']} | {b['count']} |")
        L.append("")
        L.append("### Task Log 보드")
        L.append("")
        L.append("| 보드 | 게시물 |")
        L.append("|------|-------:|")
        for b in sorted(tasks, key=lambda x: -x["count"]):
            L.append(f"| {b['board']} | {b['count']} |")
    else:
        L.append("## AI 게시판 — 조회 불가")
        L.append("")
        L.append(f"⚠ {board.get('reason')}")
    L.append("")
    L.append(f"## 설정 계층 — {catalog['config_hierarchy']['count']}개")
    L.append("")
    L.append("CLAUDE.md · rules · rules-canonical (authority tier). 전체 목록은 JSON "
             "`config_hierarchy.entries`.")
    L.append("")
    L.append("## 조회 방법 (full detail = JSON)")
    L.append("")
    L.append("```bash")
    L.append("CAT=\"$CLAUDE_MEMORY_DIR/catalog/knowledge-catalog.json\"")
    L.append("# 카테고리별 MD 경로+설명")
    L.append("jq -r '.md.entries[]|select(.category==\"skill\")|.realpath' \"$CAT\"")
    L.append("# 키워드로 제목/설명 검색")
    L.append("jq -r '.md.entries[]|select((.title//\"\")+(.description//\"\")|test(\"메모리\";\"i\"))|.realpath' \"$CAT\"")
    L.append("# 특정 게시판 task log 목록")
    L.append("jq -r '.board.entries[]|select(.board==\"csr\")|\"\\(.id)\\t\\(.status)\\t\\(.title)\"' \"$CAT\"")
    L.append("```")
    L.append("")
    body = "\n".join(L) + "\n"
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.replace(tmp, path)


if __name__ == "__main__":
    sys.exit(build())
