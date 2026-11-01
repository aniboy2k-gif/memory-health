"""routine_dispose.py — disposition rules for routine_items.py `dispose` (CSR #2491 D3).
A rejected disposition raises Refuse: non-zero exit, nothing appended. stdlib only, Python 3.9."""
import datetime
import os
import re

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
    extra = {}
    if disp == "fixed":
        if kind == "part_failed":
            ok = any(r.get("part") == m.get("part") and r.get("run_id") == m.get("run_id")
                     and r.get("result") == "PASS" and r.get("ts") == ref for r in part_rows())
            if not ok:
                raise Refuse("part_failed fixed needs ref = ts of a later PASS row of the same part and run")
        else:
            check_fixed_ref(m, ref)
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
                body = normq(f.read())
        except OSError:
            body = ""
        if normq(m.get("quote")) and normq(m.get("quote")) in body:
            raise Refuse("%s still contains the quoted text" % m.get("path"))


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
