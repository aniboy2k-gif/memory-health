#!/usr/bin/env python3
"""routine_items.py — memory-health monthly routine: observe -> ingest -> dispose.

stdlib only; must run on the hook runtime /usr/bin/python3 (3.9). Single SSOT = the append-only
ledger $MH_LOCAL_DIR/items.jsonl (default: memory-health-local under the user's Claude config dir).
Current state = fold by id. Only `status --check-refs --run <latest run_id>` exit 0 means a routine
run is complete (2 > 1 > 4 > 0; 4 = failure handed to a task, not complete).

Subcommands
  peek                      read-only SessionStart notice (<=600 chars, 1 s budget, exit 3 on overrun)
  pending                   read-only full list of channel events beyond the cursors
  start [--force]           acquire the routine lease, append the run row (due_parts)
  scan-channels             P-C: registry channels + builtin plugins channel
  ingest-update --file F    P-B: stdout of `audit-record.sh update-check`
  ingest-doctor [--file F]  P-D: `claude doctor` (read-only)
  scan-unused [--file F]    P-F: only the skillUsage/pluginUsage keys of ~/.claude.json
  scan-deps                 P-G: npm packages vendored inside skills/tools (dep_roots, npx_specs in channels.json)
  ingest-audit --run-dir D --part A|E   FINDING lines saved by `audit-record.sh post`
  plan-shards [--split N]   P-E: rolling full-scope audit plan
  cover --run-dir D --shard N           P-E: coverage after post + ingest-audit passed
  part-fail --part X --reason T         record a part that could not run (part_failed item)
  dispose ID... --disp K [--ref R] [--reason T] [--goal --deadline --method --revert]
  status [--check-refs] [--run RUN_ID] [--json]
  do-not-report             dismissed audit findings (path + quote) for the auditor prompt
  boundary-check --repo DIR [--body FILE]   public push/PR boundary (fail-closed)
Mutating subcommands need the lease held by $CLAUDE_CODE_SESSION_ID and serialize on mutate.lock.
Exit codes: 0 ok · 1 refused/invalid/open · 2 unknown/unchecked · 3 peek overrun · 4 blocked with follow-up.
"""
import datetime
import fcntl
import hashlib
import json
import os
import re
import signal
import sys
import time
import urllib.request

LEASE_STALE_S = 1800
DEFER_MAX_DAYS = 90
OBS_WINDOW_DAYS = 45
PEEK_CAP = 600
PARTS = "ABCDEFG"
COVERAGE_KINDS = ("unknown", "unobserved_plugin")
DISMISSABLE = ("finding", "update-available", "unused-extension", "plugin-version-changed", "unclassified", "dep-outdated", "dep-vulnerable")
SEV_RANK = {"high": 3, "medium": 2, "low": 1}
SOURCE_MAX = 500


class Refuse(Exception):
    """Refusal: non-zero exit, nothing written."""


# ── paths / time ─────────────────────────────────────────────────────────────
def home():
    return os.environ.get("MH_HOME") or os.path.expanduser("~")


def local_dir():
    return os.environ.get("MH_LOCAL_DIR") or os.path.join(home(), ".claude", "memory-health-local")


def lp(name):
    return os.path.join(local_dir(), name)


def state_dir():
    return os.environ.get("MH_STATE_DIR") or os.path.join(home(), ".claude", "da-tools")


def now():
    v = os.environ.get("MH_NOW_EPOCH", "")
    return float(v) if re.match(r"^[1-9][0-9]{0,11}$", v) else time.time()


def iso(t=None):
    t = now() if t is None else t
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def today():
    v = os.environ.get("MH_TODAY", "")
    return v if re.match(r"^\d{4}-\d{2}-\d{2}$", v) else datetime.date.today().isoformat()


def sha1(s):
    return hashlib.sha1(s.encode("utf-8", "surrogateescape")).hexdigest()


def sha256_file(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None


def item_id(part, kind, key):
    return "%s:%s:%s" % (part, kind, sha1(key)[:10])


def clip(text):
    """source lines > 500 chars are cut and flagged."""
    return (text[:SOURCE_MAX], True) if len(text) > SOURCE_MAX else (text, False)


def interval_days():
    try:
        v = int(os.environ.get("CLAUDE_MD_AUDIT_INTERVAL", "30"))
    except ValueError:
        v = 30
    return min(45, max(1, v))


def atomic_write(path, text):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def load_config():
    """home-real channels.json; None when absent (folds to kind=unknown in scan-channels)."""
    try:
        cfg = load_json(lp("channels.json"))
    except FileNotFoundError:
        return None
    if not isinstance(cfg, dict):
        raise ValueError("channels.json is not an object")
    return cfg


# ── ledger ───────────────────────────────────────────────────────────────────
def load_ledger():
    """-> (rows, unknown, torn). Torn last line is ignored; any other bad line = unknown (fail-loud)."""
    try:
        with open(lp("items.jsonl"), "rb") as f:
            data = f.read()
    except FileNotFoundError:
        return [], False, False
    rows, unknown, torn = [], False, False
    cut = data.rfind(b"\n") + 1
    body = [x for x in data[:cut].split(b"\n") if x.strip()]
    try:  # fast path: every complete line at once (peek's 1 s budget); any doubt -> per-line path below
        fast = json.loads(b"[" + b",".join(body) + b"]") if body else []
        if all(isinstance(r, dict) for r in fast) and not data[cut:].strip():
            return fast, False, False
    except ValueError:
        pass
    lines = data.split(b"\n")
    for i, raw in enumerate(lines):
        if not raw.strip():
            continue
        try:
            r = json.loads(raw.decode("utf-8"))
            if not isinstance(r, dict):
                raise ValueError
            rows.append(r)
        except ValueError:
            if i == len(lines) - 1:
                torn = True
            else:
                unknown = True
    return rows, unknown, torn


def append_rows(rows):
    """Append under the mutate lock; a torn final line is moved to items.torn.jsonl first."""
    if not rows:
        return
    os.makedirs(local_dir(), exist_ok=True)
    path = lp("items.jsonl")
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        size = os.lseek(fd, 0, os.SEEK_END)
        if size:
            os.lseek(fd, 0, os.SEEK_SET)
            data = b""
            while True:
                chunk = os.read(fd, 1 << 20)
                if not chunk:
                    break
                data += chunk
            if not data.endswith(b"\n"):
                cut = data.rfind(b"\n") + 1
                tail = data[cut:]
                try:
                    json.loads(tail.decode("utf-8"))
                    os.lseek(fd, 0, os.SEEK_END)
                    os.write(fd, b"\n")
                except ValueError:
                    with open(lp("items.torn.jsonl"), "ab") as t:
                        t.write(tail + b"\n")
                    os.ftruncate(fd, cut)
                    sys.stderr.write("warning: torn ledger tail moved to items.torn.jsonl\n")
        os.lseek(fd, 0, os.SEEK_END)
        os.write(fd, "".join(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n" for r in rows).encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)


def fold(rows):
    """id -> {meta, items:[row idx], disps:[(idx,row)]}."""
    out = {}
    for idx, r in enumerate(rows):
        t = r.get("type")
        if t == "item" and r.get("id"):
            e = out.setdefault(r["id"], {"meta": r, "items": [], "disps": [], "first_ts": r.get("ts")})
            e["meta"] = r
            e["items"].append(idx)
        elif t == "disp" and r.get("id") in out:
            out[r["id"]]["disps"].append((idx, r))
    return out


def _dismiss_lapsed(e, d):
    """an audit-finding dismissal applies only while the file's sha256 equals the recorded one."""
    rec = d.get("file_sha256")
    if not rec:
        return False
    return sha256_file(e["meta"].get("path") or "") != rec


def item_state(e, today_s=None):
    """-> 'open' | 'overdue' | 'disposed'."""
    today_s = today_s or today()
    if not e["disps"]:
        return "open"
    di, d = e["disps"][-1]
    k = d.get("disp")
    if k == "deferred":
        return "overdue" if (d.get("defer") or {}).get("deadline", "") < today_s else "disposed"
    if k in ("fixed", "verified"):
        return "open" if e["items"][-1] > di else "disposed"
    if k == "dismissed" and e["items"][-1] > di and _dismiss_lapsed(e, d):
        return "open"
    return "disposed"


def should_append(e):
    """idempotent ingest: new id, or re-observation after fixed/verified, or after a lapsed dismissal."""
    if e is None:
        return True
    if not e["disps"]:
        return False
    di, d = e["disps"][-1]
    if d.get("disp") in ("fixed", "verified"):
        return e["items"][-1] < di
    if d.get("disp") == "dismissed":
        return e["items"][-1] < di and _dismiss_lapsed(e, d)
    return False


def make_item(part, kind, key, sev, summary, source=None, **extra):
    row = {"ts": iso(), "type": "item", "id": item_id(part, kind, key), "part": part, "kind": kind,
           "sev": sev, "summary": summary}
    if source is not None:
        text, cut = clip(source)
        row["source"] = text
        if cut:
            row["truncated"] = True
    row.update(extra)
    return row


def latest(rows, type_, **match):
    for r in reversed(rows):
        if r.get("type") == type_ and all(r.get(k) == v for k, v in match.items()):
            return r
    return None


# ── lease / mutate lock ──────────────────────────────────────────────────────
def session_id():
    return os.environ.get("CLAUDE_CODE_SESSION_ID", "")


def read_lease():
    try:
        return load_json(lp("routine.lease"))
    except (OSError, ValueError):
        return None


def lease_fresh(lease):
    try:
        return isinstance(lease, dict) and now() - float(lease.get("heartbeat_ts") or 0) < LEASE_STALE_S
    except (TypeError, ValueError):  # a malformed lease counts as stale (may be taken over)
        return False


class Mutate(object):
    """exclusive flock on mutate.lock from first read to last write; checks + refreshes the lease."""

    def __init__(self, need_lease=True):
        self.need_lease = need_lease
        self.fd = None

    def __enter__(self):
        os.makedirs(local_dir(), exist_ok=True)
        self.fd = os.open(lp("mutate.lock"), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        if self.need_lease:
            lease, sid = read_lease(), session_id()
            if not lease:
                raise Refuse("no routine lease — run `routine_items.py start` first")
            if not sid or lease.get("session_id") != sid:
                raise Refuse("routine lease held by session %s" % str(lease.get("session_id"))[:8])
            write_lease(sid)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)
        return False


def write_lease(sid, exclusive=False):
    body = json.dumps({"session_id": sid, "heartbeat_ts": now()})
    if exclusive:
        fd = os.open(lp("routine.lease"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(body)
    else:
        atomic_write(lp("routine.lease"), body)


# ── parts / stamps ───────────────────────────────────────────────────────────
def stamp_path(part):
    if part == "A":
        return os.path.join(state_dir(), "claude-md-audit-last")
    if part == "B":
        return os.path.join(state_dir(), "skill-update-check-last")
    return lp("part-%s-last" % part)


def stamp_epoch(part):
    try:
        with open(stamp_path(part)) as f:
            v = f.readline().strip()
        return float(v) if re.match(r"^[1-9][0-9]{0,11}(\.[0-9]+)?$", v) else None
    except OSError:
        return None


def due_parts(force=False, pending=0):
    if force:
        return list(PARTS)
    iv, t, out = interval_days(), now(), []
    for p in PARTS:
        e = stamp_epoch(p)
        if e is None or (t - e) / 86400 >= iv or (p == "C" and pending > 0):
            out.append(p)
    return out


def part_failed_id(part, run_id):
    return "%s:part_failed:%s" % (part, sha1(part + run_id)[:10])


def record_part(part, run_id, ok, reason=""):
    """part row in parts.jsonl; FAILED also appends an open part_failed item; PASS refreshes C-G stamps."""
    row = {"ts": iso(), "part": part, "run_id": run_id, "result": "PASS" if ok else "FAILED"}
    if reason:
        row["reason"] = reason
    with open(lp("parts.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
        f.flush()
        os.fsync(f.fileno())
    if ok:
        if part in "CDEFG":
            atomic_write(stamp_path(part), "%d\n" % int(now()))
    else:
        it = make_item(part, "part_failed", part + run_id, "high", "part %s FAILED in run %s: %s" % (part, run_id, reason))
        it["id"] = part_failed_id(part, run_id)
        it["run_id"] = run_id
        if should_append(fold(load_ledger()[0]).get(it["id"])):
            append_rows([it])
    return row


def part_rows():
    rows = []
    try:
        with open(lp("parts.jsonl"), encoding="utf-8") as f:
            for line in f:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return rows


def current_run(rows):
    r = latest(rows, "run")
    if not r:
        raise Refuse("no run row — run `routine_items.py start` first")
    return r["run_id"]


# ── board ────────────────────────────────────────────────────────────────────
class BoardError(Exception):
    pass


def board_post(n):
    """-> (status, [texts], [comment ids]). URL template from env MH_BOARD_POST_URL or channels.json."""
    tpl = os.environ.get("MH_BOARD_POST_URL")
    if not tpl:
        try:
            tpl = (load_config() or {}).get("board_post_url")
        except ValueError:
            tpl = None
    if not tpl:
        raise BoardError("no board_post_url configured")
    try:
        with urllib.request.urlopen(tpl.replace("{n}", str(n)), timeout=5) as r:
            d = json.loads(r.read().decode("utf-8"))
    except Exception as exc:  # unreachable, 404, bad JSON: all mean "refs unchecked"
        raise BoardError(str(exc))
    p = d.get("data", d) if isinstance(d, dict) else None
    comments = p.get("comments") if isinstance(p, dict) else None
    if not isinstance(p, dict) or not isinstance(comments or [], list) or \
            not all(isinstance(c, dict) for c in comments or []):
        raise BoardError("unexpected board response shape")
    texts = [str(p.get("content") or "")] + [str(c.get("content") or "") for c in comments or []]
    return str(p.get("status") or ""), texts, [str(c.get("id")) for c in comments or []]


# ── dispose ──────────────────────────────────────────────────────────────────
def normq(s):
    return " ".join((s or "").split())


# ── status ───────────────────────────────────────────────────────────────────
def compute_status(check_refs=False, run=None):
    rows, unknown, _torn = load_ledger()
    f = fold(rows)
    code2, notes, opened, blocked = [], [], [], []
    if unknown:
        code2.append("ledger unreadable (UNKNOWN)")
    refs, prow = {}, part_rows()
    import routine_dispose as rd  # imported here: routine_dispose imports this module
    lr = latest(rows, "run") if run is not None else None
    for i, e in sorted(f.items()):
        st = item_state(e)
        kind = e["meta"].get("kind")
        if st == "overdue":
            code2.append("overdue deferral %s" % i)
            opened.append((i, kind))
            continue
        if st == "open":
            opened.append((i, kind))
            continue
        di, d = e["disps"][-1]
        if d.get("disp") != "task":
            continue
        if kind in COVERAGE_KINDS or (kind == "part_failed" and rd.part_failed_blocking(
                e["meta"], prow, lr if lr and lr.get("run_id") == run else None)):
            blocked.append(i)
        if check_refs:
            _status_task_ref(i, d, refs, code2, opened)
    if run is not None:
        _status_run_parts(rows, f, run, code2, blocked, prow)
    open_ids = {o[0] for o in opened}
    blocked = sorted({b for b in blocked if b not in open_ids})
    code = 2 if code2 else 1 if opened else 4 if blocked else 0
    if not check_refs:
        nt = len(task_disposed_ids(f))
        if nt:  # CSR #2509: these reopen as orphaned_task/unlinked_task once their CSR closes; `open=` above does not count them
            notes.append("%d task-disposed item(s) not ref-checked — they may reopen as orphaned_task/unlinked_task" % nt)
        notes.append("task refs not checked — completion needs `status --check-refs --run <latest run_id>`")
    return code, code2, opened, blocked, notes, f


def task_disposed_ids(f):
    """ids whose latest disposition is `task` (their CSR is only read by --check-refs)."""
    return [i for i, e in f.items() if item_state(e) == "disposed" and e["disps"] and e["disps"][-1][1].get("disp") == "task"]


def _status_task_ref(i, d, refs, code2, opened):
    """--check-refs for one task disposition; appends to code2/opened, caches board reads in refs."""
    n = re.match(r"^CSR #(\d+)$", d.get("ref") or "")
    n = n.group(1) if n else None
    if n not in refs:
        try:
            refs[n] = board_post(n) if n else None
        except BoardError as exc:
            refs[n] = exc
    got = refs[n]
    if got is None or isinstance(got, BoardError):
        code2.append("refs unchecked (%s)" % i)
    elif got[0].lower() in ("done", "closed"):
        opened.append((i, "orphaned_task"))
    elif not any(i in t for t in got[1]):
        opened.append((i, "unlinked_task"))


def _status_run_parts(rows, f, run, code2, blocked, prow):
    """--run: every due part of that run needs its last row in that run to be PASS, or a task-disposed part_failed item."""
    lr = latest(rows, "run")
    if not lr or lr.get("run_id") != run:
        code2.append("--run %s is not the latest run" % run)
        return
    last = {r.get("part"): r.get("result") for r in prow if r.get("run_id") == run}  # append order: last row wins
    passed = {p for p, res in last.items() if res == "PASS"}
    for p in lr.get("due_parts") or []:
        if p in passed:
            continue
        pf = f.get(part_failed_id(p, run))
        if pf and pf["disps"] and pf["disps"][-1][1].get("disp") == "task" and item_state(pf) == "disposed":
            blocked.append(part_failed_id(p, run))
        else:
            code2.append("part %s due in %s without PASS" % (p, run))


def cmd_status(check_refs, run, as_json):
    code, code2, opened, blocked, notes, f = compute_status(check_refs, run)
    names = {0: "COMPLETE", 1: "OPEN", 2: "UNKNOWN", 4: "BLOCKED_WITH_FOLLOWUP"}
    # exit code unchanged; only the word: completion needs both flags (design D5)
    label = "OPEN_UNCHECKED" if code == 0 and not (check_refs and run) else names[code]
    if as_json:
        print(json.dumps({"exit": code, "status": label, "reasons": code2,
                          "open": [{"id": i, "kind": k, "sev": f[i]["meta"].get("sev") if i in f else None,
                                    "summary": f[i]["meta"].get("summary") if i in f else None} for i, k in opened],
                          "blocked": blocked, "notes": notes}, ensure_ascii=False))
    else:
        for i, k in opened:
            m = f[i]["meta"]
            print("OPEN %s kind=%s sev=%s %s" % (i, k, m.get("sev"), m.get("summary")))
        for b in blocked:
            print("BLOCKED %s (task — not complete until restored)" % b)
        for r in code2 + notes:
            print("NOTE %s" % r)
        print("STATUS %s exit=%d open=%d" % (label, code, len(opened)))
    return code


# ── peek / pending ───────────────────────────────────────────────────────────
def pending_events(rows, cfg):
    """[(sev, text)] for channel events beyond the cursors (read-only)."""
    import routine_sources as rs
    return rs.pending(rows, cfg)


def cmd_peek():
    budget = float(os.environ.get("MH_PEEK_BUDGET") or 1.0)

    def overrun(_s, _f):
        os._exit(3)

    signal.signal(signal.SIGALRM, overrun)
    signal.setitimer(signal.ITIMER_REAL, budget)
    if os.environ.get("MH_PEEK_TEST_SLEEP"):
        time.sleep(float(os.environ["MH_PEEK_TEST_SLEEP"]))
    rows, unknown, _torn = load_ledger()
    try:
        cfg = load_config()
    except ValueError:
        cfg, unknown = None, True
    f = fold(rows)
    t = now()
    open_ids = [i for i, e in f.items() if item_state(e) in ("open", "overdue")]
    events = pending_events(rows, cfg)
    events.sort(key=lambda x: -SEV_RANK.get(x[0], 1))
    due = due_parts(pending=len(events))
    iv = interval_days()
    od, od_items = _peek_overdue(f, open_ids, t, iv)
    ntask = len(task_disposed_ids(f))
    signal.setitimer(signal.ITIMER_REAL, 0)
    if not (open_ids or due or events or unknown or ntask):
        touch_peek_last()
        return 0
    bits = _peek_bits(unknown, open_ids, due, events, iv, ntask)
    instr = _peek_instr()
    # measured (CSR #2491 landing): `claude -p` hooks see CLAUDE_CODE_ENTRYPOINT=sdk-cli, interactive = cli
    headless = os.environ.get("CLAUDE_CODE_ENTRYPOINT", "").startswith("sdk")
    pre = ""
    if od or od_items:
        pre = "ROUTINE OVERDUE %dd — " % max(od + od_items)
    if headless:  # non-interactive: count line only, no run instruction, no event lines
        print("[memory-health routine] %s%s" % (pre, " · ".join(bits)))
        touch_peek_last()
        return 0
    lines = _peek_lines("[memory-health routine] %s%s — %s" % (pre, " · ".join(bits), instr), events)
    print("\n".join(lines))
    touch_peek_last()
    return 0


def _peek_overdue(f, open_ids, t, iv):
    """-> (parts overdue > 7d past the interval, open items older than 30d), both in days."""
    ages = []
    for p in PARTS:
        e = stamp_epoch(p)
        if e is not None:
            ages.append((t - e) / 86400 - iv)
    od = [int(a) + iv for a in ages if a > 7]
    # one parse of the earliest first_ts (ISO-8601 'Z' strings sort chronologically) — peek's 1 s budget
    first = min((f[i]["first_ts"] for i in open_ids if isinstance(f[i]["first_ts"], str)), default=None)
    age = t - (parse_iso(first) or t) if first else 0
    od_items = [int(age / 86400)] if age > 30 * 86400 else []
    return od, od_items


def _peek_bits(unknown, open_ids, due, events, iv, ntask=0):
    bits = []
    if unknown:
        bits.append("ledger unreadable")
    if open_ids:
        bits.append("open %d" % len(open_ids))
    if ntask:  # their CSRs are only read by `status --check-refs`; `open` above does not include a closed one
        bits.append("task-unchecked %d" % ntask)
    if due:
        bits.append("due %s" % ",".join(due))
    if events:
        bits.append("pending %d" % len(events))
    if iv != 30:
        bits.append("interval %dd" % iv)
    return bits


def _peek_instr():
    lease = read_lease()
    if lease_fresh(lease):
        return "routine running (session %s)" % str(lease.get("session_id"))[:8]
    return "run /memory-health routine"


def _peek_lines(head, events):
    """head line + event lines, cut to PEEK_CAP with a `+N more pending` tail."""
    lines = [head]
    used = len(lines[0])
    for k, (sev, text) in enumerate(events):
        line = "  · %s" % text[:140]
        rest = len(events) - k - 1
        tail = len("\n+%d more pending — routine_items.py pending lists all" % (len(events) - k))
        if used + 1 + len(line) + (tail if rest else 0) > PEEK_CAP:
            lines.append("+%d more pending — routine_items.py pending lists all" % (len(events) - k))
            break
        lines.append(line)
        used += 1 + len(line)
    return lines


def touch_peek_last():
    """the only write peek performs: mtime of the home-real stamp (no ledger row)."""
    try:
        os.makedirs(local_dir(), exist_ok=True)
        with open(lp("peek-last"), "a"):
            pass
        os.utime(lp("peek-last"), None)
    except OSError:
        pass


def cmd_pending():
    rows = load_ledger()[0]
    for sev, text in pending_events(rows, load_config()):
        print("%s %s" % (sev, text))
    return 0


# ── start / part-fail / do-not-report ───────────────────────────────────────
def cmd_start(force):
    sid = session_id()
    if not sid:
        raise Refuse("CLAUDE_CODE_SESSION_ID is empty")
    with Mutate(need_lease=False):
        lease = read_lease()
        rows = load_ledger()[0]
        out = []
        if lease and lease.get("session_id") != sid:
            if lease_fresh(lease):
                left = max(1, int((LEASE_STALE_S - (now() - float(lease.get("heartbeat_ts") or 0)) + 59) // 60))
                raise Refuse("routine running in session %s (lease ends in %d min unless that session keeps working)"
                             % (str(lease.get("session_id"))[:8], left))
            out.append({"ts": iso(), "type": "lease_takeover", "old_session": lease.get("session_id"),
                        "old_heartbeat": lease.get("heartbeat_ts"), "session": sid})
            write_lease(sid)
        elif lease and lease_fresh(lease) and not force and latest(rows, "run"):
            write_lease(sid)
            print("RUN_ID=%s (lease refreshed)" % latest(rows, "run")["run_id"])
            return 0
        elif lease:
            write_lease(sid)
        else:
            write_lease(sid, exclusive=True)
        events = pending_events(rows, load_config())
        run_id = "%s-%s" % (datetime.datetime.fromtimestamp(now(), datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"), sid[:8])
        due = due_parts(force, len(events))
        out.append({"ts": iso(), "type": "run", "run_id": run_id, "due_parts": due, "session": sid})
        append_rows(out)
    print("RUN_ID=%s" % run_id)
    print("DUE_PARTS=%s" % ",".join(due))
    return 0


def cmd_part_fail(part, reason):
    if part not in PARTS or len(reason) < 10:
        raise Refuse("part-fail needs --part A-G and --reason (>= 10 chars)")
    with Mutate():
        record_part(part, current_run(load_ledger()[0]), False, reason)
    print("PART %s FAILED" % part)
    return 0


def cmd_do_not_report():
    f = fold(load_ledger()[0])
    for i, e in sorted(f.items()):
        m = e["meta"]
        d = e["disps"][-1][1] if e["disps"] else {}
        # a dismissal suppresses re-reporting only while the file's sha256 still matches (design L93)
        if m.get("kind") == "finding" and item_state(e) == "disposed" and d.get("disp") == "dismissed" \
                and not _dismiss_lapsed(e, d):
            print("%s | %s" % (m.get("path"), m.get("quote")))
    return 0


# ── CLI ──────────────────────────────────────────────────────────────────────
def opts(argv, names):
    a, pos, k = {}, [], 0
    while k < len(argv):
        x = argv[k]
        if x.startswith("--") and x[2:] in names:
            if names[x[2:]]:
                if k + 1 >= len(argv):
                    raise Refuse("%s needs a value" % x)
                a[x[2:]] = argv[k + 1]
                k += 2
                continue
            a[x[2:]] = True
        elif x.startswith("--"):
            raise Refuse("unknown option %s" % x)
        else:
            pos.append(x)
        k += 1
    return a, pos


def main(argv):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import routine_sources as rs
    if not argv:
        print(__doc__)
        return 64
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "peek":
            return cmd_peek()
        if cmd == "pending":
            return cmd_pending()
        if cmd == "start":
            return cmd_start(opts(rest, {"force": False})[0].get("force", False))
        if cmd == "status":
            a = opts(rest, {"check-refs": False, "run": True, "json": False})[0]
            return cmd_status(a.get("check-refs", False), a.get("run"), a.get("json", False))
        if cmd == "dispose":
            a, ids = opts(rest, {k: True for k in ("disp", "ref", "reason", "goal", "deadline", "method", "revert")})
            if not ids or "disp" not in a:
                raise Refuse("dispose ID... --disp K")
            import routine_dispose as rd
            return rd.cmd_dispose(ids, a)
        if cmd == "part-fail":
            a = opts(rest, {"part": True, "reason": True})[0]
            return cmd_part_fail(a.get("part", ""), a.get("reason", ""))
        if cmd == "do-not-report":
            return cmd_do_not_report()
        return rs.dispatch(cmd, rest)
    except Refuse as exc:
        sys.stderr.write("REFUSED: %s\n" % exc)
        return 1


if __name__ == "__main__":
    # run through the importable module so routine_sources shares one copy (one Refuse class)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import routine_items as _self
    sys.exit(_self.main(sys.argv[1:]))
