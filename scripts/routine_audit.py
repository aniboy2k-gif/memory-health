"""routine_audit.py — audit FINDING ingest (P-A, P-E), the rolling full-scope audit plan and
coverage (P-E) and the public-repo boundary check for routine_items.py (CSR #2491). stdlib only,
Python 3.9; machine-specific values live only in the home-real channels.json."""
import json
import os
import re
import subprocess
import sys

import routine_items as ri
from routine_sources import (Batch, ROOT_FILES, SCOPE_DIRS, SKIP_DIRS, is_worktree_copy,
                             unknown_item)

SHARD_CHARS = 75000
MONTH_BUDGET = 600000
RESERVED = 300000


# ── audit FINDING ingest (P-A, P-E) ──────────────────────────────────────────
def audit_state(run_dir):
    jl = os.environ.get("MH_AUDIT_JSONL") or os.path.join(ri.state_dir(), "claude-md-audit.jsonl")
    st = None
    try:
        with open(jl, encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("run_dir") == run_dir and r.get("part") == "audit" and not r.get("dry_run"):
                    st = r.get("state")
    except OSError:
        pass
    return st


def parse_findings(run_dir):
    """-> list of findings; raise ValueError on any malformed line or count mismatch."""
    with open(os.path.join(run_dir, "findings.txt"), encoding="utf-8") as f:
        lines = [x.rstrip("\n") for x in f if x.strip()]
    found, total = [], None
    for x in lines:
        if x.startswith("FINDINGS_TOTAL "):
            if total is not None or not re.match(r"^FINDINGS_TOTAL [0-9]{1,6}$", x):
                raise ValueError("bad FINDINGS_TOTAL line")
            total = int(x.split()[1])
        elif x.startswith("FINDING "):
            d = json.loads(x[len("FINDING "):])
            if not isinstance(d, dict) or any(k not in d for k in ("sev", "path", "line", "quote", "summary")):
                raise ValueError("FINDING missing a key")
            if d["sev"] not in ("high", "medium", "low") or not isinstance(d["line"], int) or len(d["quote"]) > 120:
                raise ValueError("FINDING field invalid")
            found.append(d)
        else:
            raise ValueError("unexpected line in findings.txt")
    if total is None or total != len(found):
        raise ValueError("FINDINGS_TOTAL %s != %d parsed" % (total, len(found)))
    return found


def occurrence(path, quote, line_no):
    """1-based count of the normalized quote's occurrences in the file up to the FINDING's line."""
    nq = ri.normq(quote)
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().split("\n")
    except OSError:
        return 1
    return max(1, sum(ri.normq(x).count(nq) for x in lines[:max(1, line_no)]) if nq else 1)


def cmd_ingest_audit(run_dir, part):
    if part not in ("A", "E"):
        raise ri.Refuse("--part must be A or E")
    run_dir = os.path.abspath(run_dir)
    with ri.Mutate():
        rows = ri.load_ledger()[0]
        run_id = ri.current_run(rows)
        state = audit_state(run_dir)
        err = None
        if state != "REPORTED":
            err = "audit post state %s" % state
        else:
            try:
                found = parse_findings(run_dir)
            except (OSError, ValueError) as exc:
                err = "FINDING parse: %s" % exc
        if err:
            ri.append_rows([{"ts": ri.iso(), "type": "ingest", "run_dir": run_dir, "run_id": run_id, "part": part,
                             "ok": False, "reason": err}])
            if part == "A":
                ri.record_part("A", run_id, False, err)
            sys.stderr.write("INGEST FAILED: %s\n" % err)
            return 1
        b = Batch(rows)
        for d in found:
            occ = occurrence(d["path"], d["quote"], d["line"])
            key = "%s\n%s\n%d" % (d["path"], ri.normq(d["quote"]), occ)
            b.item(ri.make_item(part, "finding", key, d["sev"], d["summary"][:200], "%s:%d %s" % (d["path"], d["line"], d["quote"]),
                                path=d["path"], quote=d["quote"], line=d["line"], occurrence=occ))
        b.commit([{"ts": ri.iso(), "type": "ingest", "run_dir": run_dir, "run_id": run_id, "part": part,
                   "ok": True, "count": len(found)}])
        if part == "A":
            ri.record_part("A", run_id, True)
    print("INGESTED findings=%d new=%d" % (len(found), len(b.items)))
    return 0


# ── P-E rolling full-scope audit ────────────────────────────────────────────
def walk_md(root):
    for d, dirs, files in os.walk(root, followlinks=True):
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS and not is_worktree_copy(x))
        for n in sorted(files):
            if n.endswith(".md"):
                yield os.path.join(d, n)


def scope_files(cfg):
    cl = os.path.join(ri.home(), ".claude")
    cands = [os.path.join(cl, n) for n in ROOT_FILES]
    for s in SCOPE_DIRS:
        cands.extend(walk_md(os.path.join(cl, s)))
    for r in cfg.get("project_roots") or []:
        r = os.path.expanduser(r)
        cands.extend(os.path.join(r, n) for n in ROOT_FILES)
        for s in SCOPE_DIRS:
            cands.extend(walk_md(os.path.join(r, ".claude", s)))
    out, seen = [], set()
    for p in cands:
        if os.path.isfile(p):
            rp = os.path.realpath(p)
            if rp not in seen:
                seen.add(rp)
                out.append(rp)
    return out


def discover(cfg):
    """roots with CLAUDE.md or .claude/ (depth <= 2) that are neither listed nor worktree copies."""
    listed = {os.path.realpath(os.path.expanduser(r)) for r in cfg.get("project_roots") or []}
    found, missing = [], [r for r in cfg.get("project_roots") or [] if not os.path.isdir(os.path.expanduser(r))]
    for top in cfg.get("discover_dirs") or []:
        top = os.path.expanduser(top)
        lvl1 = [os.path.join(top, n) for n in sorted(os.listdir(top))] if os.path.isdir(top) else []
        lvl2 = []
        for d in lvl1:
            if os.path.isdir(d) and not os.path.basename(d).startswith("."):
                lvl2.extend(os.path.join(d, n) for n in sorted(os.listdir(d)) if not n.startswith("."))
        for d in lvl1 + lvl2:
            n = os.path.basename(d)
            if not os.path.isdir(d) or n.startswith(".") or is_worktree_copy(n) or n in SKIP_DIRS:
                continue
            if (os.path.isfile(os.path.join(d, "CLAUDE.md")) or os.path.isdir(os.path.join(d, ".claude"))) \
                    and os.path.realpath(d) not in listed:
                found.append(d)
    return found, missing


def chunks_of(path):
    """consecutive line-range chunks of <= SHARD_CHARS chars -> (sha, [(start, end, chars)], total)."""
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    out, start, acc = [], 1, 0
    for i, x in enumerate(lines, 1):
        n = len(x) + 1
        if acc and acc + n > SHARD_CHARS:
            out.append((start, i - 1, acc))
            start, acc = i, 0
        acc += n
    if acc or not out:
        out.append((start, max(start, len(lines)), acc))
    return ri.sha256_file(path), out, len(text)


def load_cov():
    try:
        return ri.load_json(ri.lp("audit-coverage.json"))
    except (OSError, ValueError):
        return {}


def cmd_plan_shards(split):
    with ri.Mutate():
        rows = ri.load_ledger()[0]
        run_id = ri.current_run(rows)
        if split is not None:
            return split_shard(int(split), run_id)
        cfg = ri.load_config() or {}
        b = Batch(rows)
        found, missing = discover(cfg)
        now_ids = set()
        for what, roots, msg in (("root", found, "unregistered project root"), ("rootmissing", missing, "listed project root missing")):
            for d in roots:
                it = unknown_item("E", "%s\n%s" % (what, d), "%s %s" % (msg, d), root=d)
                now_ids.add(it["id"])
                b.item(it)
        for iid, e in b.f.items():
            if e["meta"].get("part") == "E" and e["meta"].get("kind") == "unknown" and e["meta"].get("root") and iid not in now_ids:
                b.fix(iid, run_id)
        b.commit([])
        cov = load_cov()
        never, old, changed = [], [], []
        for p in scope_files(cfg):
            sha, ch, _n = chunks_of(p)
            c = cov.get(p) or {}
            ranges = c.get("ranges", []) if c.get("sha256") == sha else []
            todo = [(p, sha, s, e, n) for s, e, n in ch if not covered(ranges, s, e)]
            if c.get("sha256") == sha and c.get("complete"):
                old.append((c.get("audited_at") or "", [(p, sha, s, e, n) for s, e, n in ch
                                                        if not covered(c.get("redo", []), s, e)]))
            elif c.get("audited_at"):
                changed.extend(todo)  # audited before, content changed since (progress kept per sha256)
            else:
                never.extend(todo)
        old.sort(key=lambda x: x[0])
        g1 = never + [u for _a, us in old for u in us]
        take1, left1 = fill(g1, RESERVED)
        take2, left2 = fill(changed, MONTH_BUDGET - RESERVED + left1)
        if left2:
            more, _l = fill([u for u in g1 if u not in take1], left2)
            take1 += more
        shards = pack(take1 + take2)
        plan = write_plan(run_id, shards)
        ages = [(ri.now() - (ri.parse_iso(c.get("audited_at")) or ri.now())) / 86400 for c in cov.values() if c.get("audited_at")]
        print("PLAN run=%s shards=%d chars=%d never_audited=%d max_audit_age_days=%d" % (
            run_id, len(shards), sum(u[4] for u in take1 + take2), len({u[0] for u in never}), int(max(ages or [0]))))
        for s in plan["shards"]:
            print("SHARD %d %s" % (s["n"], s["manifest"]))
    return 0


def merge(ranges):
    out = []
    for s, e in sorted(tuple(x) for x in ranges):
        if out and s <= out[-1][1] + 1:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return out


def covered(ranges, s, e):
    return any(a <= s and e <= b for a, b in merge(ranges))


def fill(units, budget):
    took = []
    for u in units:
        if u[4] <= budget:
            took.append(u)
            budget -= u[4]
    return took, budget


def pack(units):
    shards, cur, acc = [], [], 0
    for u in units:
        if cur and acc + u[4] > SHARD_CHARS:
            shards.append(cur)
            cur, acc = [], 0
        cur.append(u)
        acc += u[4]
    if cur:
        shards.append(cur)
    return shards


def entry_line(p, s, e, whole):
    return p if whole else "%s#L%d-%d" % (p, s, e)


def write_plan(run_id, shards, split=()):
    d = ri.lp(os.path.join("shards", run_id))
    os.makedirs(d, exist_ok=True)
    plan = {"run_id": run_id, "shards": []}
    for n, units in enumerate(shards, 1):
        ents = []
        for p, sha, s, e, c in units:
            ch = chunks_of(p)[1]
            ents.append({"path": p, "sha256": sha, "start": s, "end": e, "chars": c,
                         "whole": (s, e) == (ch[0][0], ch[-1][1])})
        man = os.path.join(d, "shard-%d.txt" % n)
        ri.atomic_write(man, "".join(entry_line(x["path"], x["start"], x["end"], x["whole"]) + "\n" for x in ents))
        plan["shards"].append({"n": n, "manifest": man, "entries": ents, "covered": False, "split": n in split})
    ri.atomic_write(ri.lp("shard-plan.json"), json.dumps(plan, indent=1))
    return plan


def split_shard(n, run_id):
    """an AUDIT_INCOMPLETE shard is halved and retried once (first-run calibration)."""
    plan = ri.load_json(ri.lp("shard-plan.json"))
    if plan.get("run_id") != run_id:
        raise ri.Refuse("shard plan belongs to another run")
    sh = [s for s in plan["shards"] if s["n"] == n]
    if not sh or sh[0].get("split") or sh[0]["covered"]:
        raise ri.Refuse("shard %d cannot be split (missing, covered or already split once)" % n)
    ents = sh[0]["entries"]
    if len(ents) > 1:
        halves = [ents[:len(ents) // 2], ents[len(ents) // 2:]]
    else:
        x = ents[0]
        mid = (x["start"] + x["end"]) // 2
        if mid <= x["start"] - 1 or x["start"] == x["end"]:
            raise ri.Refuse("shard %d is a single line and cannot be halved" % n)
        halves = [[dict(x, end=mid)], [dict(x, start=mid + 1)]]
    keep = [s for s in plan["shards"] if s["n"] != n]
    units = [[(e["path"], e["sha256"], e["start"], e["end"], e["chars"]) for e in s["entries"]] for s in keep]
    units += [[(e["path"], e["sha256"], e["start"], e["end"], e["chars"]) for e in h] for h in halves]
    new = write_plan(run_id, units, split=(len(units) - 1, len(units)))
    done = {tuple(sorted((e["path"], e["start"], e["end"]) for e in s["entries"])) for s in keep if s["covered"]}
    for s in new["shards"]:
        s["covered"] = tuple(sorted((e["path"], e["start"], e["end"]) for e in s["entries"])) in done
    ri.atomic_write(ri.lp("shard-plan.json"), json.dumps(new, indent=1))
    for s in new["shards"]:
        print("SHARD %d %s" % (s["n"], s["manifest"]))
    return 0


def cmd_cover(run_dir, n):
    run_dir = os.path.abspath(run_dir)
    with ri.Mutate():
        rows = ri.load_ledger()[0]
        run_id = ri.current_run(rows)
        if audit_state(run_dir) != "REPORTED":
            raise ri.Refuse("post did not pass for %s" % run_dir)
        ing = [r for r in rows if r.get("type") == "ingest" and r.get("run_dir") == run_dir]
        if not ing or not ing[-1].get("ok"):
            raise ri.Refuse("ingest-audit did not exit 0 for %s" % run_dir)
        plan = ri.load_json(ri.lp("shard-plan.json"))
        sh = [s for s in plan["shards"] if s["n"] == int(n)]
        if plan.get("run_id") != run_id or not sh:
            raise ri.Refuse("shard %s not in the current plan" % n)
        with open(sh[0]["manifest"], encoding="utf-8") as f1, open(os.path.join(run_dir, "manifest.txt"), encoding="utf-8") as f2:
            if f1.read().strip() != f2.read().strip():
                raise ri.Refuse("run dir manifest differs from shard %s" % n)
        cov = load_cov()
        for e in sh[0]["entries"]:
            sha, ch, _n = chunks_of(e["path"])
            if sha != e["sha256"]:
                continue  # changed since planning: stays uncovered and is re-planned
            c = cov.get(e["path"]) or {}
            if c.get("sha256") != sha:  # a sha256 change discards chunk progress
                c = {"sha256": sha, "ranges": [], "complete": False, "audited_at": c.get("audited_at")}
            key = "redo" if c.get("complete") else "ranges"  # re-audit of a complete file rotates audited_at
            c[key] = merge(c.get(key, []) + [[e["start"], e["end"]]])
            if covered(c[key], ch[0][0], ch[-1][1]):
                c["complete"], c["audited_at"], c["ranges"], c["redo"] = True, ri.iso(), c[key], []
            cov[e["path"]] = c
        ri.atomic_write(ri.lp("audit-coverage.json"), json.dumps(cov, indent=1, sort_keys=True))
        sh[0]["covered"] = True
        ri.atomic_write(ri.lp("shard-plan.json"), json.dumps(plan, indent=1))
        if all(s["covered"] for s in plan["shards"]):
            ri.record_part("E", run_id, True)
    print("COVERED shard %s" % n)
    return 0


# ── public-repo boundary ────────────────────────────────────────────────────
def git(repo, *a):
    p = subprocess.run(["git", "-C", repo] + list(a), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def cmd_boundary_check(repo, body):
    """fail-closed: deny file absent/empty, no base ref or gitleaks error blocks the push/PR."""
    try:
        with open(ri.lp("boundary-deny.txt"), encoding="utf-8") as f:
            deny = [x.rstrip("\n") for x in f if x.strip()]
    except OSError:
        deny = []
    if not deny:
        print("BLOCKED boundary-deny.txt absent or empty")
        return 1
    rc, base = git(repo, "rev-parse", "--verify", "-q", "@{u}")
    if rc != 0:
        rc, base = git(repo, "merge-base", "HEAD", "origin/HEAD")
        if rc != 0:
            print("BLOCKED no base ref (@{u} undefined and merge-base HEAD origin/HEAD failed)")
            return 1
    base = base.strip()
    _r, diff = git(repo, "diff", "%s..HEAD" % base)
    added = "\n".join(x[1:] for x in diff.split("\n") if x.startswith("+") and not x.startswith("+++"))
    _r, msgs = git(repo, "log", "--format=%B", "%s..HEAD" % base)
    texts = [("diff", added), ("log", msgs)]
    if body:
        with open(body, encoding="utf-8") as f:
            texts.append(("body", f.read()))
    hits = ["%s: %s" % (w, d) for w, t in texts for d in deny if d in t]
    try:
        cfg = ri.load_config() or {}
    except ValueError:
        cfg = {}
    for r in cfg.get("project_roots") or []:
        bn = os.path.basename(r.rstrip("/"))
        if not bn or git(repo, "grep", "-qwF", bn, base)[0] == 0:
            continue  # already public in the base tree
        rx = re.compile(r"(?<![\w-])%s(?![\w-])" % re.escape(bn))
        hits.extend("%s: basename %s" % (w, bn) for w, t in texts if rx.search(t))
    gl = cfg.get("gitleaks_cmd") or ["gitleaks", "detect", "--source", "{repo}", "--log-opts", "{base}..HEAD", "--no-banner", "--redact"]
    try:
        g = subprocess.run([x.replace("{repo}", repo).replace("{base}", base) for x in gl],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if g.returncode != 0:
            hits.append("gitleaks exit %d" % g.returncode)
    except OSError as exc:
        hits.append("gitleaks error: %s" % exc)
    if hits:
        print("BLOCKED %d hit(s)" % len(hits))
        for h in hits:
            print("  " + h)
        return 1
    print("BOUNDARY OK base=%s" % base[:12])
    return 0
