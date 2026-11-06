"""routine_sources.py — sources for routine_items.py (CSR #2491): channels, plugins, claude doctor,
unused extensions, rolling full-scope audit shards, audit FINDING ingest and the public-repo boundary.
stdlib only, Python 3.9. Machine-specific values (paths, channel list, project roots, board URL) live
only in the home-real channels.json — never in this file."""
import json
import os
import re
import shutil
import subprocess
import sys

import routine_items as ri

UNUSED_DAYS = 60
MK_STALE_DAYS = 14
SCOPE_DIRS = ("rules", "skills", "commands", "agents", "output-styles")
ROOT_FILES = ("CLAUDE.md", "CLAUDE.local.md", "AGENTS.md")
SKIP_DIRS = (".git", "node_modules", "tests", "fixtures", "__pycache__")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def is_worktree_copy(name):
    return "-wt-" in name or "-iso" in name


# ── log_lines / stamp_age channels ──────────────────────────────────────────
def compile_channel(ch):
    ev = []
    for e in ch.get("events") or []:
        ev.append((re.compile(e["re"]), e))
    ign = [re.compile(x) for x in ch.get("ignore") or []]
    return ev, ign


def classify(line, ev, ign):
    """-> None (ignored) | ('obs', rule, match) | ('item', rule|None, match)."""
    for r in ign:
        if r.search(line):
            return None
    for rx, rule in ev:
        m = rx.search(line)
        if m:
            return ("obs" if rule.get("observe") else "item", rule, m)
    return ("item", None, None)


def _prefix(f, end):
    start = max(0, end - 64)
    f.seek(start)
    return ri.sha1(f.read(end - start).decode("latin-1"))


def read_log(ch, cur):
    """-> dict(error|lines=[(offset, text)], inode, end, prefix, reset=None|dict)."""
    path = os.path.expanduser(ch["path"])
    try:
        st = os.stat(path)
        f = open(path, "rb")
    except OSError as exc:
        return {"error": "unreadable" if os.path.exists(path) else "absent", "detail": str(exc)}
    with f:
        size, off, reset = st.st_size, 0, None
        if cur:
            if cur.get("inode") != st.st_ino:
                reset = {"why": "inode", "old_inode": cur.get("inode"), "old_offset": cur.get("offset")}
            elif size < cur.get("offset", 0) or _prefix(f, cur.get("offset", 0)) != cur.get("prefix_sha1"):
                reset = {"why": "shrunk_or_rewritten", "old_inode": cur.get("inode"), "old_offset": cur.get("offset")}
            else:
                off = cur.get("offset", 0)
        f.seek(off)
        data = f.read(size - off)
        cut = data.rfind(b"\n") + 1
        lines, pos = [], off
        for raw in data[:cut].split(b"\n")[:-1]:
            lines.append((pos, raw.decode("utf-8", "replace").rstrip("\r")))
            pos += len(raw) + 1
        end = off + cut
        return {"lines": lines, "inode": st.st_ino, "end": end, "prefix": _prefix(f, end), "reset": reset}


def stamp_age_h(ch):
    path = os.path.expanduser(ch.get("stale_path") or ch["path"])
    try:
        with open(path) as f:
            v = f.readline().strip()
        val = float(v) if re.match(r"^[0-9]{9,12}(\.[0-9]+)?$", v) else os.stat(path).st_mtime
    except OSError as exc:
        return None, None, "absent" if not os.path.exists(path) else "unreadable: %s" % exc
    return (ri.now() - val) / 3600.0, val, None


def channel_events(ch, rows):
    """events beyond the cursor of one log_lines channel -> (read, [(kind, sev, key, text, extra)])."""
    cur = ri.latest(rows, "cursor", channel=ch["id"])
    rd = read_log(ch, cur)
    if "error" in rd:
        return rd, []
    ev, ign = compile_channel(ch)
    out = []
    if rd["reset"]:
        r = rd["reset"]
        out.append(("cursor_reset", "medium", "%s\nreset\n%s\n%s\n%s" % (ch["id"], r["old_inode"], r["old_offset"], rd["inode"]),
                     "cursor reset (%s) old inode=%s offset=%s" % (r["why"], r["old_inode"], r["old_offset"]), r))
    for off, text in rd["lines"]:
        c = classify(text, ev, ign)
        if c is None:
            continue
        kind, rule, m = c
        key = "%s\n%s\n%d\n%s" % (ch["id"], rd["inode"], off, text)
        if kind == "obs":
            ver = (m.groupdict().get("version") if m else None) or rule.get("version") or ""
            out.append(("obs", None, key, text, {"plugin": rule.get("plugin"), "version": ver}))
        else:
            out.append((rule.get("kind") if rule else "unclassified", (rule or {}).get("sev", "medium" if rule else "low"),
                        key, text, {"offset": off}))
    return rd, out


# ── builtin plugins channel ─────────────────────────────────────────────────
# Default-on marketplaces (G3 step 3). Sources, retrieved 2026-11-01:
#   https://code.claude.com/docs/en/discover-plugins — "On by default: `claude-plugins-official` and the other
#   official marketplace names except `knowledge-work-plugins` and `first-party-plugins`, plus marketplaces
#   added from claude.ai"
#   https://code.claude.com/docs/en/plugins/security.md — "These marketplace names make up the official tier:"
#   claude-plugins-official, claude-code-marketplace, claude-code-plugins, anthropic-marketplace, anthropic-plugins,
#   agent-skills, anthropic-agent-skills, life-sciences, knowledge-work-plugins, claude-for-legal,
#   claude-for-financial-services, financial-services-plugins, first-party-plugins, claude-tag-plugins
# No machine-readable copy exists. A name added later falls to "off" (fails safe: the item opens) and an explicit
# autoUpdate key (precedence 1-2) always overrides this list. claude.ai marketplaces are recognised only by their
# record in known_marketplaces_claudeai.json, never by a `claudeai-` name alone.
DEFAULT_ON = ("claude-plugins-official", "claude-code-marketplace", "claude-code-plugins", "anthropic-marketplace",
              "anthropic-plugins", "agent-skills", "anthropic-agent-skills", "life-sciences", "claude-for-legal",
              "claude-for-financial-services", "financial-services-plugins", "claude-tag-plugins")


def plugin_state():
    """-> (versions, known_marketplaces, settings, claude.ai marketplaces); a present but unreadable
    claude.ai record raises like the other two files (-> unknown), an absent one means none."""
    base = os.path.join(ri.home(), ".claude", "plugins")
    ip = ri.load_json(os.path.join(base, "installed_plugins.json"))
    km = ri.load_json(os.path.join(base, "known_marketplaces.json"))
    try:
        kc = ri.load_json(os.path.join(base, "known_marketplaces_claudeai.json"))
    except FileNotFoundError:
        kc = {}
    if not isinstance(kc, dict):
        raise ValueError("known_marketplaces_claudeai.json is not an object")
    try:
        st = ri.load_json(os.path.join(ri.home(), ".claude", "settings.json"))
    except (OSError, ValueError):
        st = {}
    versions = {}
    for name, ents in (ip.get("plugins") or {}).items():
        if isinstance(ents, list) and ents:
            versions[name] = str(ents[0].get("version") or "")
    return versions, km, st, kc


def auto_update(mk, km, st, kc=None):
    """effective plugin auto-update (precedence: settings -> marketplace record -> default; env)."""
    env = dict(st.get("env") or {})
    env.update(os.environ)
    if str(env.get("FORCE_AUTOUPDATE_PLUGINS", "")) not in ("1", "true"):
        for k in ("DISABLE_UPDATES", "DISABLE_AUTOUPDATER", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"):
            if str(env.get(k, "")) not in ("", "0", "false"):
                return False
    ekm = (st.get("extraKnownMarketplaces") or {}).get(mk) or {}
    if "autoUpdate" in ekm:
        return bool(ekm["autoUpdate"])
    kc = kc or {}
    k = km.get(mk) or kc.get(mk) or {}  # a claude.ai marketplace is recorded in the claudeai file instead
    if "autoUpdate" in k:
        return bool(k["autoUpdate"])
    return mk in DEFAULT_ON or mk in kc


def helper_blocked(name, mk, km, kc):
    """Claude Code's auto-update skips a plugin whose marketplace entry declares headersHelper
    (docs plugins/loading); an entry that cannot be read counts as skipped, so the item stays open."""
    ent = km.get(mk) or kc.get(mk)
    loc = str(ent.get("installLocation") or "") if isinstance(ent, dict) else ""
    path = loc if loc.endswith(".json") else os.path.join(loc, ".claude-plugin", "marketplace.json")
    try:
        cat = ri.load_json(path) if loc else {}
    except (OSError, ValueError):
        return True
    ents = [p for p in (cat.get("plugins") if isinstance(cat, dict) else None) or []
            if isinstance(p, dict) and p.get("name") == name.split("@", 1)[0]]
    return len(ents) != 1 or "headersHelper" in ents[0]


def marketplace_dates(km):
    return {mk: e["lastUpdated"] for mk, e in sorted(km.items())
            if isinstance(e, dict) and isinstance(e.get("lastUpdated"), str)}


def plugin_events(rows):
    """version and marketplace lastUpdated changes vs the plugins cursor (no cursor, or no recorded date for a
    marketplace, = silent baseline: a cursor written before dates were stored emits nothing)."""
    versions, km, _st, _kc = plugin_state()
    cur = ri.latest(rows, "cursor", channel="plugins")
    out = []
    if cur:
        for name, v in sorted(versions.items()):
            if (cur.get("versions") or {}).get(name) != v:
                out.append(("plugin-version-changed", "medium", "plugins\n%s\n%s" % (name, v),
                            "plugins: %s %s -> %s" % (name, (cur.get("versions") or {}).get(name), v), {"plugin": name}))
        old = cur.get("lastUpdated") if isinstance(cur.get("lastUpdated"), dict) else {}
        for mk, lu in marketplace_dates(km).items():
            if mk in old and old[mk] != lu:
                out.append(("marketplace-refreshed", "low", "plugins\nmk\n%s\n%s" % (mk, lu),
                            "plugins: marketplace %s lastUpdated %s -> %s" % (mk, old[mk], lu), {"marketplace": mk}))
    return versions, out


# ── pending (read-only, used by peek / pending / start) ─────────────────────
def pending(rows, cfg):
    res = []
    for ch in (cfg or {}).get("channels") or []:
        if ch.get("type") != "log_lines":
            continue
        try:
            rd, evs = channel_events(ch, rows)
        except (re.error, KeyError):
            res.append(("high", "%s: channel config invalid" % ch.get("id")))
            continue
        if "error" in rd:
            res.append(("high", "%s: log %s" % (ch["id"], rd["error"])))
        for kind, sev, _k, text, _x in evs:
            if kind != "obs":
                res.append((sev, "%s: %s" % (ch["id"], text)))
    try:
        _v, pe = plugin_events(rows)
        res.extend((sev, text) for _kd, sev, _k, text, _x in pe)
    except (OSError, ValueError):
        res.append(("high", "plugins: installed_plugins/known_marketplaces unreadable"))
    return res


# ── scan-channels (P-C) ─────────────────────────────────────────────────────
class Batch(object):
    """collects rows; items go first (fsync), cursors last; MH_FAULT_AFTER=k aborts after k items."""

    def __init__(self, rows):
        self.rows, self.f = rows, ri.fold(rows)
        self.items, self.other, self.seen = [], [], set()

    def item(self, row):
        if row["id"] in self.seen or not ri.should_append(self.f.get(row["id"])):
            return
        self.seen.add(row["id"])
        self.items.append(row)

    def fix(self, iid, run_id):
        """called only after a successful source read; a coverage item closes by this recheck alone (design L97),
        so one disposed task/deferred (the only dispositions coverage kinds accept) is closed here too."""
        e = self.f.get(iid)
        last = e["disps"][-1][1].get("disp") if e and e["disps"] else None
        pending = e and e["meta"].get("kind") in ri.COVERAGE_KINDS and last in ("task", "deferred")
        if e and (ri.item_state(e) in ("open", "overdue") or pending) and iid not in self.seen:
            self.other.append({"ts": ri.iso(), "type": "disp", "id": iid, "disp": "fixed", "ref": "recheck:%s" % run_id,
                               "reason": "scanner re-read the source successfully"})

    def commit(self, cursors):
        """items + observations first (fsync), then scanner fixes, the cursor rows last."""
        first = self.items + [r for r in self.other if r.get("type") == "obs"]
        fault = os.environ.get("MH_FAULT_AFTER")
        if fault is not None:  # test hook: abort after exactly k rows of the first stream
            for k, row in enumerate(first):
                if k >= int(fault):
                    raise SystemExit(99)
                ri.append_rows([row])
            if len(first) <= int(fault):
                raise SystemExit(99)
        else:
            ri.append_rows(first)
        ri.append_rows([r for r in self.other if r.get("type") != "obs"])
        ri.append_rows(cursors)


def unknown_item(part, what, summary, **extra):
    return ri.make_item(part, "unknown", "unknown\n%s" % what, "high", summary, **extra)


def deny_file(cfg):
    """boundary-deny.txt regenerated each run from channels.json paths and project_roots."""
    hm = ri.home()
    ent = set()
    for ch in cfg.get("channels") or []:
        for k in ("path", "stale_path"):
            if ch.get(k):
                ent.add(ch[k])
                ent.add(os.path.expanduser(ch[k]))
    for r in cfg.get("project_roots") or []:
        ent.add(r)
        ent.add("/%s/" % os.path.basename(r.rstrip("/")))
    # generic machine prefixes, spelled in pieces so this public file never contains them
    ent.update(["/" + "Volumes/", "/private" + "/var/folders", "/" + "Users/", "~" + "/.claude/", hm])
    ri.atomic_write(ri.lp("boundary-deny.txt"), "".join(sorted(e + "\n" for e in ent if e)))


def cmd_scan_channels():
    with ri.Mutate():
        rows, _u, _t = ri.load_ledger()
        run_id = ri.current_run(rows)
        b = Batch(rows)
        cursors = []
        try:
            cfg = ri.load_config()
            cfg_err = None if cfg is not None else "absent"
        except (ValueError, OSError) as exc:
            cfg, cfg_err = None, "unreadable: %s" % exc
        if cfg_err:
            b.item(unknown_item("C", "registry", "channel registry %s" % cfg_err))
        else:
            b.fix(ri.item_id("C", "unknown", "unknown\nregistry"), run_id)
            deny_file(cfg)
            backup_registry()
        ok_ids = set()
        for ch in (cfg or {}).get("channels") or []:
            cid = ch.get("id")
            if ch.get("type") == "log_lines" and not _scan_log_channel(b, ch, cid, rows, run_id, cursors):
                continue
            ok = True
            if ch.get("max_age_h") is not None:
                ok = _scan_stamp_channel(b, ch, cid, run_id)
            if ok:
                ok_ids.add(cid)
        for rid in (cfg or {}).get("required_ids") or []:
            if rid in ok_ids:
                b.fix(ri.item_id("C", "unknown", "unknown\nrequired\n%s" % rid), run_id)
            else:
                b.item(unknown_item("C", "required\n%s" % rid, "required channel %s missing or unread" % rid))
        plugin_scan(b, rows, run_id, cursors, cfg)
        b.commit(cursors)
        ri.record_part("C", run_id, True)
    print("SCANNED items=%d" % len(b.items))
    return 0


def _scan_log_channel(b, ch, cid, rows, run_id, cursors):
    """log_lines channel -> items/obs rows + a new cursor; False when the log is unreadable (channel skipped)."""
    rd, evs = channel_events(ch, rows)
    if "error" in rd:
        b.item(unknown_item("C", "%s\nlog" % cid, "%s: log %s" % (cid, rd["error"]), channel=cid))
        return False
    for kind, sev, key, text, x in evs:
        if kind == "obs":
            b.other.append({"ts": ri.iso(), "type": "obs", "channel": cid, "plugin": x.get("plugin"),
                            "version": x.get("version"), "line": ri.clip(text)[0]})
            continue
        src = "%s @%s: %s" % (cid, x.get("offset", 0), text) if kind != "cursor_reset" else text
        b.item(ri.make_item("C", kind, key, sev, "%s: %s" % (cid, text[:160]), src, channel=cid,
                            **({"old_inode": x.get("old_inode"), "old_offset": x.get("old_offset")}
                               if kind == "cursor_reset" else {})))
    cursors.append({"ts": ri.iso(), "type": "cursor", "channel": cid, "inode": rd["inode"],
                    "offset": rd["end"], "prefix_sha1": rd["prefix"]})
    b.fix(ri.item_id("C", "unknown", "unknown\n%s\nlog" % cid), run_id)
    return True


def _scan_stamp_channel(b, ch, cid, run_id):
    """max_age_h check; False when the stamp is unreadable."""
    age, val, err = stamp_age_h(ch)
    if err:
        b.item(unknown_item("C", "%s\nstamp" % cid, "%s: stamp %s" % (cid, err), channel=cid))
        return False
    b.fix(ri.item_id("C", "unknown", "unknown\n%s\nstamp" % cid), run_id)
    if age > float(ch["max_age_h"]):
        b.item(ri.make_item("C", "runner-stale", "%s\nstale\n%d" % (cid, int(val)), "medium",
                            "%s: runner stale %.0fh (max %sh)" % (cid, age, ch["max_age_h"]), channel=cid))
    return True


def plugin_scan(b, rows, run_id, cursors, cfg=None):
    try:
        versions, pe = plugin_events(rows)
        _v, km, st, kc = plugin_state()
    except (OSError, ValueError) as exc:
        b.item(unknown_item("C", "plugins", "plugins json unreadable: %s" % exc))
        return
    b.fix(ri.item_id("C", "unknown", "unknown\nplugins"), run_id)
    for kind, sev, key, text, x in pe:
        b.item(ri.make_item("C", kind, key, sev, text, text, **x))
    t = ri.now()
    obs = observed(rows + b.other, cfg)
    for name in sorted(versions):
        mk = name.split("@", 1)[1] if "@" in name else ""
        on = auto_update(mk, km, st, kc)
        helper = helper_blocked(name, mk, km, kc) if on else False
        iid = ri.item_id("C", "unobserved_plugin", "plugins\nunobserved\n%s" % name)
        if (on and not helper) or t - obs.get(name, 0) <= ri.OBS_WINDOW_DAYS * 86400:
            b.fix(iid, run_id)
        else:
            b.item(ri.make_item("C", "unobserved_plugin", "plugins\nunobserved\n%s" % name, "high",
                                "plugin %s: auto-update off and no upstream observation in %d days" % (name, ri.OBS_WINDOW_DAYS),
                                plugin=name))
        lu = ri.parse_iso(((km.get(mk) or {}).get("lastUpdated") or "")[:19] + "Z")
        if on and lu and t - lu > MK_STALE_DAYS * 86400:
            b.item(ri.make_item("C", "marketplace-stale", "plugins\nmkstale\n%s\n%s" % (mk, (km.get(mk) or {}).get("lastUpdated")),
                                "medium", "marketplace %s lastUpdated %s while auto-update is on" % (mk, (km.get(mk) or {}).get("lastUpdated"))))
    cursors.append({"ts": ri.iso(), "type": "cursor", "channel": "plugins", "versions": versions,
                    "lastUpdated": marketplace_dates(km)})


def observed(rows, cfg):
    """plugin -> latest observation epoch, counting only observations from a channel whose `plugins`
    list names that plugin (design L85: from its listing channel)."""
    listing = {ch.get("id"): set(ch.get("plugins") or []) for ch in (cfg or {}).get("channels") or []}
    obs = {}
    for r in rows:
        if r.get("type") == "obs" and r.get("plugin") and r.get("version") \
                and r["plugin"] in listing.get(r.get("channel"), ()):
            obs[r["plugin"]] = max(obs.get(r["plugin"], 0), ri.parse_iso(r.get("ts")) or 0)
    return obs


def backup_registry():
    src = ri.lp("channels.json")
    h = ri.sha256_file(src)
    if not h:
        return
    d = os.path.join(ri.home(), ".claude", "backups", "memory-health-local")
    dst = os.path.join(d, "channels.%s.json" % h[:10])
    if not os.path.exists(dst):
        with open(src, encoding="utf-8") as f:
            ri.atomic_write(dst, f.read())


# ── P-B / P-D / P-F ─────────────────────────────────────────────────────────
def cmd_ingest_update(path):
    with ri.Mutate():
        rows = ri.load_ledger()[0]
        run_id = ri.current_run(rows)
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read()
        except OSError as exc:
            ri.record_part("B", run_id, False, "update-check output unreadable: %s" % exc)
            return 1
        b = Batch(rows)
        for m in re.finditer(r"^SKILL: (\S+) channel=(\S+) status=(\S+)(?: upstream=(\S+))?$", text, re.M):
            name, chan, status, up = m.group(1), m.group(2), m.group(3), m.group(4) or "-"
            kind = "update-available" if status.startswith("update-available") else "fetch-error"
            b.item(ri.make_item("B", kind, "skill\n%s\n%s" % (name, up), "medium", "skill %s: %s (%s)" % (name, status, chan),
                                m.group(0)))
        b.commit([])
        ok = "STATE=UPDATE_CHECK_PASS" in text.split("\n")
        ri.record_part("B", run_id, ok, "" if ok else "update-check did not PASS")
    print("INGESTED items=%d part_B=%s" % (len(b.items), "PASS" if ok else "FAILED"))
    return 0 if ok else 1


def parse_doctor(text):
    """-> (anchors_ok, [(kind, sev, line)])."""
    text = ANSI.sub("", text)
    lines = [x.rstrip() for x in text.split("\n")]
    anchors = all(any(x.startswith(a) for x in lines) for a in ("Auto-updates", "Auto-update channel", "Last update attempt"))
    out, sec = [], None
    for x in lines:
        if x.startswith("Last update attempt") and "success" not in x.split(":", 1)[-1]:
            out.append(("cli-update-failed", "medium", x))
        if x.startswith("Permission rules that may not work as written"):
            sec = "perm"
            continue
        if re.match(r"(?i)^.*installation issue", x) and not x.startswith("No installation issues found"):
            sec = "install"
            if x.startswith("- "):
                out.append(("doctor-install", "medium", x))
            continue
        if not x.strip():
            sec = None
            continue
        if sec == "perm" and x.startswith("- "):
            out.append(("doctor-permission", "high" if "arbitrary" in x else "medium", x))
        elif sec == "install":
            out.append(("doctor-install", "medium", x))
    return anchors, out


def cmd_ingest_doctor(path):
    with ri.Mutate():
        rows = ri.load_ledger()[0]
        run_id = ri.current_run(rows)
        if path:
            try:
                with open(path, encoding="utf-8") as f:
                    text, rc = f.read(), 0
            except OSError as exc:
                text, rc = "", "unreadable: %s" % exc
        else:
            try:
                p = subprocess.run(["claude", "doctor"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
                text, rc = p.stdout.decode("utf-8", "replace"), p.returncode
            except (OSError, subprocess.TimeoutExpired) as exc:
                text, rc = "", "error: %s" % exc
        anchors, found = parse_doctor(text)
        if rc != 0 or not anchors:
            ri.record_part("D", run_id, False, "claude doctor rc=%s anchors=%s" % (rc, anchors))
            print("PART D FAILED")
            return 1
        b = Batch(rows)
        for kind, sev, line in found:
            b.item(ri.make_item("D", kind, "doctor\n%s" % line, sev, line[:200], line))
        b.commit([])
        ri.record_part("D", run_id, True)
    print("INGESTED items=%d part_D=PASS" % len(b.items))
    return 0


def read_usage(path):
    """only skillUsage and pluginUsage are read from ~/.claude.json (it also holds credentials)."""
    for attempt in (0, 1):
        try:
            with open(path, encoding="utf-8") as f:
                d = json.load(f)
            return {"skillUsage": d["skillUsage"], "pluginUsage": d["pluginUsage"]}
        except (OSError, ValueError, KeyError, TypeError) as exc:
            err = exc
            if isinstance(exc, KeyError) or attempt:
                break
    raise ValueError("usage keys unreadable: %s" % type(err).__name__)


def cmd_scan_unused(path):
    path = path or os.path.join(ri.home(), ".claude.json")
    with ri.Mutate():
        rows = ri.load_ledger()[0]
        run_id = ri.current_run(rows)
        try:
            u = read_usage(path)
        except ValueError as exc:
            ri.record_part("F", run_id, False, str(exc))
            print("PART F FAILED")
            return 1
        cut = (ri.now() - UNUSED_DAYS * 86400) * 1000
        inv = []
        sk = os.path.join(ri.home(), ".claude", "skills")
        for n in sorted(os.listdir(sk)) if os.path.isdir(sk) else []:
            if os.path.isfile(os.path.join(sk, n, "SKILL.md")):
                inv.append(("skill", n, u["skillUsage"].get(n)))
        try:
            plugins = plugin_state()[0]
        except (OSError, ValueError):
            plugins = {}
        for n in sorted(plugins):
            inv.append(("plugin", n, u["pluginUsage"].get(n)))
        b = Batch(rows)
        for typ, n, rec in inv:
            last = (rec or {}).get("lastUsedAt") or 0
            if last < cut:
                b.item(ri.make_item("F", "unused-extension", "unused\n%s\n%s" % (typ, n), "low",
                                    "%s %s unused for >= %d days (or never)" % (typ, n, UNUSED_DAYS)))
        b.commit([])
        ri.record_part("F", run_id, True)
    print("INGESTED items=%d part_F=PASS" % len(b.items))
    return 0


# ── P-G: npm packages vendored inside skills/tools ──────────────────────────
NPM_REGISTRY = "https://registry.npmjs.org/"
SCOPED_REG = re.compile(r"^@[^:]+:registry$")


def dep_timeout():
    try:
        return float(os.environ.get("MH_DEP_TIMEOUT_S") or 60)
    except ValueError:
        return 60.0


def run_npm(args, cwd=None):
    """-> (rc, stdout) or (None, 'timeout'|'error'); npm resolved at call time (tests stub it via PATH)."""
    npm = shutil.which("npm")
    if not npm:
        return None, "npm-not-found"
    try:
        p = subprocess.run([npm] + args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=dep_timeout())
    except subprocess.TimeoutExpired:
        return None, "timeout"
    except OSError:
        return None, "error"
    return p.returncode, p.stdout


def outdated_verdict(rc, out):
    """-> (packages dict, None) on success, else (None, reason)."""
    if rc is None:
        return None, out if out == "timeout" else "exit-error"
    if rc not in (0, 1):
        return None, "exit-%d" % rc
    try:
        d = json.loads(out)
    except ValueError:
        return None, "non-json"
    if not isinstance(d, dict):
        return None, "malformed"
    if "error" in d:
        code = d["error"].get("code") if isinstance(d["error"], dict) else None
        return None, "error-envelope:%s" % (code or "unknown")
    for v in d.values():
        if not (isinstance(v, dict) and isinstance(v.get("current"), str) and isinstance(v.get("latest"), str)
                and isinstance(v.get("wanted", ""), str)):
            return None, "malformed"
    return d, None


AUDIT_SEV = {"critical": "high", "high": "medium", "moderate": "low"}  # item sev; low/info advisories are not raised


def audit_verdict(rc, out):
    """-> ([(package, audit severity, sorted advisory ids, first title)], None) on success, else (None, reason).
    `npm audit` exits 1 when it found vulnerabilities, so rc 0 and 1 are both a valid report."""
    if rc is None:
        return None, "audit-timeout" if out == "timeout" else "audit-exit-error"
    if rc not in (0, 1):
        return None, "audit-exit-%d" % rc
    try:
        d = json.loads(out)
    except ValueError:
        return None, "audit-non-json"
    if not isinstance(d, dict):
        return None, "audit-malformed"
    if "error" in d:
        code = d["error"].get("code") if isinstance(d["error"], dict) else None
        return None, "audit-error-envelope:%s" % (code or "unknown")
    vulns = d.get("vulnerabilities")
    if not isinstance(vulns, dict) or not all(isinstance(v, dict) for v in vulns.values()):
        return None, "audit-malformed"
    res = []
    for name, v in sorted(vulns.items()):
        sev = v.get("severity")
        if sev not in AUDIT_SEV:
            continue
        via = [x for x in v.get("via") or [] if isinstance(x, dict)]
        ids = sorted({str(x.get("source") or x.get("url") or "") for x in via if x.get("source") or x.get("url")})
        res.append((name, sev, ids, (via[0].get("title") if via else None) or "transitive"))
    return res, None


def npx_cached(name):
    """-> version of the newest-mtime cached package.json under ~/.npm/_npx, or None."""
    best = None
    base = os.path.join(ri.home(), ".npm", "_npx")
    for h in os.listdir(base) if os.path.isdir(base) else []:
        pj = os.path.join(base, h, "node_modules", name, "package.json")
        try:
            m = os.stat(pj).st_mtime
        except OSError:
            continue
        if best is None or m > best[0]:
            best = (m, pj)
    try:
        v = ri.load_json(best[1]).get("version") if best else None
    except (OSError, ValueError, AttributeError):
        v = None
    return v if isinstance(v, str) and v else None


def _scan_root(b, root, fail):
    if not os.path.isdir(root):
        return fail(root, "root-missing")
    nm = os.path.join(root, "node_modules")
    if not (os.path.isdir(nm) or os.path.islink(nm)):
        print("SKIP %s (no node_modules)" % os.path.basename(root.rstrip("/")))
        return
    rc, out = run_npm(["config", "list", "--json"], cwd=root)
    try:
        conf = json.loads(out) if rc == 0 else None
    except ValueError:
        conf = None
    if not isinstance(conf, dict):
        return fail(root, "npm-config-failed")
    if any(SCOPED_REG.match(k) and v != NPM_REGISTRY for k, v in conf.items()):
        return fail(root, "scoped-registry-override")
    pkgs, why = outdated_verdict(*run_npm(["outdated", "--json", "--registry", NPM_REGISTRY], cwd=root))
    if why:
        return fail(root, why)
    for name in sorted(pkgs):
        v = pkgs[name]
        b.item(ri.make_item("G", "dep-outdated", "%s\n%s\n%s" % (root, name, v["latest"]), "low",
                            "%s %s (wanted %s, latest %s) in %s" % (name, v["current"], v.get("wanted", "-"), v["latest"],
                                                                   os.path.basename(root.rstrip("/"))),
                            package=name, current=v["current"], wanted=v.get("wanted"), latest=v["latest"], root=root))
    # CSR #2509: `outdated` alone rated everything low while `npm audit` showed high advisories (da-tools, 2026-11-06)
    found, why = audit_verdict(*run_npm(["audit", "--json", "--registry", NPM_REGISTRY], cwd=root))
    if why:
        return fail(root, why)
    for name, sev, ids, title in found:
        b.item(ri.make_item("G", "dep-vulnerable", "%s\n%s\n%s\n%s" % (root, name, sev, ",".join(ids)), AUDIT_SEV[sev],
                            "%s has a %s advisory (%s) in %s" % (name, sev, title, os.path.basename(root.rstrip("/"))),
                            package=name, audit_severity=sev, advisories=ids, root=root))


def _scan_npx(b, name, fail):
    cached = npx_cached(name)
    rc, out = run_npm(["view", name, "version"])
    lines = [x.strip() for x in (out or "").split("\n") if x.strip()] if rc == 0 else []
    if not lines:
        return fail("npx:%s" % name, "npm-view-failed")
    latest = lines[-1]
    if cached != latest:
        b.item(ri.make_item("G", "dep-outdated", "npx\n%s\n%s" % (name, latest), "low",
                            "npx %s %s (%s), latest %s" % (name, cached or "unknown", "last-cached" if cached else "unknown",
                                                         latest),
                            package=name, current=cached or "unknown", latest=latest, root="npx",
                            cache_label="last-cached" if cached else "unknown"))


def cmd_scan_deps():
    with ri.Mutate():
        rows = ri.load_ledger()[0]
        run_id = ri.current_run(rows)
        b = Batch(rows)
        failures = []

        def fail(where, reason):
            failures.append("%s: %s" % (os.path.basename(where.rstrip("/")) or where, reason))
            b.item(ri.make_item("G", "dep-scan-failed", "%s\n%s" % (where, reason), "medium",
                                "dependency scan failed (%s) for %s" % (reason, os.path.basename(where.rstrip("/")) or where),
                                reason=reason, root=where))

        if not shutil.which("npm"):
            fail("npm", "npm-not-found")
        else:
            try:
                cfg = ri.load_config() or {}
            except (ValueError, OSError):
                cfg = {}
            roots = cfg.get("dep_roots") or []
            if not roots:
                failures.append("dep_roots unset")
                b.item(ri.make_item("G", "dep-roots-unset", "dep_roots", "medium",
                                    "dep_roots missing or empty in the local channels.json — part G scanned nothing"))
            else:
                for root in roots:
                    _scan_root(b, os.path.expanduser(str(root)), fail)
                for name in cfg.get("npx_specs") or []:
                    _scan_npx(b, str(name), fail)
        b.commit([])
        ok = not failures
        ri.record_part("G", run_id, ok, "" if ok else "; ".join(failures)[:300])
    print("INGESTED items=%d part_G=%s" % (len(b.items), "PASS" if ok else "FAILED"))
    return 0 if ok else 1


def dispatch(cmd, rest):
    import routine_audit as ra  # imported here: routine_audit imports this module
    o = ri.opts
    if cmd == "scan-channels":
        return cmd_scan_channels()
    if cmd == "ingest-update":
        return cmd_ingest_update(o(rest, {"file": True})[0].get("file") or "")
    if cmd == "ingest-doctor":
        return cmd_ingest_doctor(o(rest, {"file": True})[0].get("file"))
    if cmd == "scan-unused":
        return cmd_scan_unused(o(rest, {"file": True})[0].get("file"))
    if cmd == "scan-deps":
        o(rest, {})
        return cmd_scan_deps()
    if cmd == "ingest-audit":
        a = o(rest, {"run-dir": True, "part": True})[0]
        return ra.cmd_ingest_audit(a.get("run-dir", ""), a.get("part", ""))
    if cmd == "plan-shards":
        return ra.cmd_plan_shards(o(rest, {"split": True})[0].get("split"))
    if cmd == "cover":
        a = o(rest, {"run-dir": True, "shard": True})[0]
        return ra.cmd_cover(a.get("run-dir", ""), a.get("shard", "0"))
    if cmd == "boundary-check":
        a = o(rest, {"repo": True, "body": True})[0]
        return ra.cmd_boundary_check(os.path.abspath(a.get("repo", ".")), a.get("body"))
    sys.stderr.write("unknown subcommand %s\n" % cmd)
    return 64
