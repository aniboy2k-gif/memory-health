"""routine_dispose.py — disposition rules for routine_items.py `dispose` (CSR #2491 D3).
A rejected disposition raises Refuse: non-zero exit, nothing appended. stdlib only, Python 3.9."""
import datetime
import os
import re
import subprocess
import unicodedata

from routine_items import (COVERAGE_KINDS, DEFER_MAX_DAYS, DISMISSABLE, BoardError, Mutate, Refuse, append_rows,
                           board_post, fold, iso, load_ledger, normq, part_rows, sha256_file, today)


def validate_disp(e, disp, a, rows):
    """-> extra fields for the row; raise Refuse when the disposition is not allowed for this item."""
    m = e["meta"]
    kind, sev = m.get("kind"), m.get("sev")
    ref, reason = a.get("ref") or "", a.get("reason") or ""
    if disp not in ("fixed", "task", "dismissed", "deferred", "verified"):
        raise Refuse("unknown disposition %s" % disp)
    if kind in COVERAGE_KINDS and disp in ("fixed", "verified", "dismissed"):
        raise Refuse("%s closes only by a scanner recheck (task allowed)" % kind)
    if sev == "high" and disp not in ("fixed", "task"):
        raise Refuse("sev=high accepts only fixed or task")
    if kind == "part_failed" and disp not in ("fixed", "task"):
        raise Refuse("part_failed accepts only fixed or task")
    if disp == "dismissed" and kind not in DISMISSABLE:
        raise Refuse("dismissed is not allowed for kind=%s" % kind)
    # a denylist, not an allowlist: observation kinds are open-ended (channel kinds come from channels.json),
    # so a hand list would refuse `verified` for unlisted observation kinds; coverage and part_failed refuse above
    if kind == "finding" and disp == "verified":
        raise Refuse("verified is not allowed for kind=finding (use fixed, dismissed, deferred or task)")
    extra = {}
    if disp == "fixed":
        if kind == "part_failed":
            ok = any(r.get("ts") == ref for r in passes_after_fail(part_rows(), m.get("part"), m.get("run_id")) or [])
            if not ok:
                raise Refuse("part_failed fixed needs ref = ts of a PASS row of the same part after its last FAILED row")
        else:
            extra.update(check_fixed_ref(m, ref))
    elif disp == "task":
        check_task_ref(m, ref)
    elif disp == "dismissed":
        if len(reason) < 20:
            raise Refuse("dismissed needs reason >= 20 chars")
        if kind == "finding":
            extra["file_sha256"] = sha256_file(m.get("path") or "")
    elif disp == "verified":
        if len(reason) < 20:
            raise Refuse("verified needs evidence (--reason) >= 20 chars")
    elif disp == "deferred":
        extra["defer"] = check_deferral(e, a)
    return extra


def passes_after_fail(prow, part, run_id):
    """PASS rows of `part` (any run) after the last FAILED row of (part, run_id), by parts.jsonl append
    position (not ts, not run order); None when that FAILED row is missing (callers fail closed)."""
    fails = [k for k, r in enumerate(prow)
             if r.get("part") == part and r.get("run_id") == run_id and r.get("result") == "FAILED"]
    if not fails:
        return None
    return [r for r in prow[fails[-1] + 1:] if r.get("part") == part and r.get("result") == "PASS"]


def part_failed_blocking(m, prow, run_row):
    """a task-disposed part_failed blocks until a PASS of its part follows its last FAILED row; with --run
    it also blocks while that run's last row for a due part is not PASS (design L99, order-aware)."""
    if not passes_after_fail(prow, m.get("part"), m.get("run_id")):
        return True
    if run_row is not None and m.get("part") in (run_row.get("due_parts") or []):
        mine = [r for r in prow if r.get("part") == m.get("part") and r.get("run_id") == run_row.get("run_id")]
        return not mine or mine[-1].get("result") != "PASS"
    return False


def check_task_ref(m, ref):
    mm = re.match(r"^CSR #(\d+)$", ref)
    if not mm:
        raise Refuse("task ref must be `CSR #N`")
    try:
        _st, texts, _ids = board_post(mm.group(1))
    except BoardError as exc:
        raise Refuse("board unreachable: %s" % exc)
    if not any(m["id"] in t for t in texts):
        raise Refuse("CSR #%s body/comments do not contain %s" % (mm.group(1), m["id"]))


def check_deferral(e, a):
    """-> the four deferral fields; raise Refuse unless all are set and the deadline is in range."""
    if any(d.get("disp") == "deferred" for _i, d in e["disps"]):
        raise Refuse("at most one deferral per item")
    dfr = {k: a.get(k) or "" for k in ("goal", "deadline", "method", "revert")}
    if not all(dfr.values()):
        raise Refuse("deferred needs all four: --goal --deadline --method --revert")
    try:
        dl = datetime.date.fromisoformat(dfr["deadline"])
    except ValueError:
        raise Refuse("deadline must be YYYY-MM-DD")
    t = datetime.date.fromisoformat(today())
    if not (t <= dl <= t + datetime.timedelta(days=DEFER_MAX_DAYS)):
        raise Refuse("deadline must be within %d days from today" % DEFER_MAX_DAYS)
    return dfr


def check_fixed_ref(m, ref):
    mm = re.match(r"^CSR #(\d+) c#(\d+)$", ref)
    if mm:
        try:
            _st, _t, ids = board_post(mm.group(1))
        except BoardError as exc:
            raise Refuse("board unreachable: %s" % exc)
        if mm.group(2) not in ids:
            raise Refuse("c#%s not found under CSR #%s" % (mm.group(2), mm.group(1)))
    elif re.match(r"^https://\S+/pull/\d+$", ref):
        pass
    elif re.match(r"^[0-9a-f]{7,40}$", ref):
        if m.get("kind") == "finding":
            path = os.path.realpath(m.get("path") or "")
            import subprocess
            rc = subprocess.call(["git", "-C", os.path.dirname(path), "cat-file", "-e", ref + "^{commit}"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if rc != 0:
                raise Refuse("commit %s not found in the repo of %s" % (ref, path))
    else:
        raise Refuse("fixed ref must be a commit sha, a PR URL or `CSR #N c#M`")
    if m.get("kind") == "finding":
        try:
            with open(m.get("path") or "", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            text = ""
        if normq(m.get("quote")) and normq(m.get("quote")) in normq(text):
            if not re.match(r"^[0-9a-f]{7,40}$", ref):
                raise Refuse("%s still contains the quoted text" % m.get("path"))
            why = quote_kept_fix(m, ref, text)
            if isinstance(why, str):
                raise Refuse("%s still contains the quoted text and %s" % (m.get("path"), why))
            return why
    return {}


# ── T5 (CSR #2492 D4): the quote is still in the file, the commit deleted the audited line ──
_QMAP = dict([(ord(c), "'") for c in "‘’‚‛′"] +
             [(ord(c), '"') for c in "“”„‟″"])


def normt(s):
    """(e) NFKC, then curly/prime quotes to ASCII, then whitespace collapse."""
    return " ".join(unicodedata.normalize("NFKC", s or "").translate(_QMAP).split())


def _git(repo, *args):
    """-> stdout text, or None on a non-zero exit."""
    p = subprocess.run(["git", "-C", repo] + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.stdout.decode("utf-8", "replace") if p.returncode == 0 else None


def _rev(repo, spec):
    out = _git(repo, "rev-parse", "--verify", "--quiet", spec)
    return out.strip() if out else None


def _is_ancestor(repo, a, b):
    return subprocess.call(["git", "-C", repo, "merge-base", "--is-ancestor", a, b],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0


def audited_line(text, nq, line, occ):
    """(g) normt of line `line` when the occ-th match of nq (counted line by line in file order) lies on it."""
    seen = 0
    for k, x in enumerate(text.split("\n"), 1):
        n = normt(x).count(nq)
        if k == line:
            return normt(x) if seen < occ <= seen + n else None
        seen += n
    return None


def hunks(diff):
    """-U0 diff -> [(deleted lines, added lines)] per hunk; header lines before the first @@ are skipped."""
    out = []
    for x in diff.split("\n"):
        if x.startswith("@@"):
            out.append(([], []))
        elif out and x[:1] in ("-", "+"):
            out[-1][0 if x[0] == "-" else 1].append(x[1:])
    return out


def quote_kept_fix(m, ref, tree):
    """-> {"ref_sha": full sha} when every T5 condition holds, else a short reason (str)."""
    path = os.path.realpath(m.get("path") or "")
    top = (_git(os.path.dirname(path), "rev-parse", "--show-toplevel") or "").strip()
    if not top:
        return "the file is not in a git repo"
    rel = os.path.relpath(path, os.path.realpath(top))
    if _git(top, "cat-file", "-e", "HEAD:" + rel) is None:
        return "%s is not in HEAD" % rel
    r = _rev(top, ref + "^{commit}")
    if not r or not _is_ancestor(top, r, "HEAD"):
        return "%s is not a commit in HEAD's history" % ref
    line, occ, ts = m.get("line"), m.get("occurrence"), m.get("ts")
    if type(line) is not int or type(occ) is not int or not ts:
        return "the item lacks integer line/occurrence or ts"
    a = (_git(top, "log", "--first-parent", "-1", "--until=" + ts, "--format=%H", "HEAD") or "").strip()
    nq = normt(m.get("quote"))
    lt = audited_line(_git(top, "show", "%s:%s" % (a, rel)) or "", nq, line, occ) if a and nq else None
    if lt is None:
        return "the audited line is not found at the audit commit"
    p1 = _rev(top, r + "^1")
    if not p1 or not _is_ancestor(top, a, p1):
        return "the commit does not follow the audit"
    old, new = _git(top, "show", "%s:%s" % (p1, rel)), _git(top, "show", "%s:%s" % (r, rel))
    if old is None or new is None:
        return "%s is missing before or at the commit" % rel
    diff = _git(top, "-c", "diff.algorithm=myers", "diff", "--no-color", "--no-ext-diff", "--no-textconv",
                "--no-renames", "-U0", p1, r, "--", rel) or ""
    if not any(any(normt(d) == lt for d in dl) and not any(nq in normt(x) for x in ad) for dl, ad in hunks(diff)):
        return "the commit does not delete the audited line"
    if any(normt(x) == lt for x in tree.split("\n")) or normt(tree).count(nq) > normt(new).count(nq):
        return "the audited line or a new occurrence is back"
    return {"ref_sha": r}


def cmd_dispose(ids, a):
    with Mutate():
        rows = load_ledger()[0]
        f = fold(rows)
        out = []
        for i in ids:
            e = f.get(i)
            if not e:
                raise Refuse("no such item %s" % i)
            extra = validate_disp(e, a["disp"], a, rows)
            row = {"ts": iso(), "type": "disp", "id": i, "disp": a["disp"], "ref": a.get("ref") or "",
                   "reason": a.get("reason") or ""}
            row.update(extra)
            out.append(row)
        append_rows(out)
    print("DISPOSED %d" % len(out))
    return 0
