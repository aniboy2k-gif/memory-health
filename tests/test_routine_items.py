#!/usr/bin/env python3
"""Tests for routine_items.py / routine_sources.py / the peek hook segment / peek-watchdog.sh
(CSR #2491 design V2, V3 and V3 additions (a)-(q)). Synthetic fixtures only.
Run: /usr/bin/python3 -m unittest tests/test_routine_items.py   (hook runtime: 3.9, /bin/bash 3.2)"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts")
PY = os.environ.get("MH_TEST_PYTHON", "/usr/bin/python3")
NOW = 1793500000  # fixed clock
DAY = 86400


class Base(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp(prefix="mh-routine-")
        self.home = os.path.join(self.t, "home")
        self.local = os.path.join(self.t, "local")
        self.state = os.path.join(self.t, "state")
        self.board = os.path.join(self.t, "board")
        for d in (self.home, self.local, self.state, self.board, os.path.join(self.t, "logs")):
            os.makedirs(d)
        self.log = os.path.join(self.t, "logs", "a.log")
        self.write(self.log, "")
        self.now = NOW
        # default: auto-update on (observed by construction); TestPlugins turns it off
        self.plugins({"demo@mk": "1.0.0"}, {"mk": {"autoUpdate": True, "lastUpdated": "2026-10-31T00:00:00.000Z"}})
        self.config()
        self.fresh_stamps()

    def tearDown(self):
        shutil.rmtree(self.t, ignore_errors=True)

    # ── fixtures ──
    def env(self, sid="S1", **extra):
        e = {k: v for k, v in os.environ.items() if not k.startswith(("MH_", "DISABLE_", "CLAUDE_CODE_DISABLE"))}
        e.update({"MH_HOME": self.home, "MH_LOCAL_DIR": self.local, "MH_STATE_DIR": self.state,
                  "MH_AUDIT_JSONL": os.path.join(self.state, "audit.jsonl"), "MH_NOW_EPOCH": str(self.now),
                  "MH_TODAY": time.strftime("%Y-%m-%d", time.gmtime(self.now)), "CLAUDE_CODE_SESSION_ID": sid,
                  "MH_BOARD_POST_URL": "file://" + self.board + "/{n}.json"})
        e.update({k: str(v) for k, v in extra.items()})
        return e

    def run_ri(self, *args, sid="S1", **extra):
        return subprocess.run([PY, os.path.join(SCRIPTS, "routine_items.py")] + list(args), env=self.env(sid, **extra),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)

    def ok(self, *args, **kw):
        p = self.run_ri(*args, **kw)
        self.assertEqual(p.returncode, 0, "%s -> %s\n%s%s" % (args, p.returncode, p.stdout, p.stderr))
        return p

    def config(self, **over):
        # chan1 lists demo@mk: only a listing channel's observation counts (design L85)
        cfg = {"channels": [{"id": "chan1", "type": "log_lines", "path": self.log, "plugins": ["demo@mk"],
                             "events": [{"re": "HOLD", "kind": "hold", "sev": "high"},
                                        {"re": r"demo up to date \((?P<version>[^)]+)\)", "observe": True, "plugin": "demo@mk"}],
                             "ignore": ["^ok "]}],
               "required_ids": [], "project_roots": [], "discover_dirs": []}
        cfg.update(over)
        self.write(os.path.join(self.local, "channels.json"), json.dumps(cfg))
        return cfg

    def plugins(self, versions, markets, settings=None, helpers=(), claudeai=None):
        """markets get a catalog (installLocation) listing their plugins; names in `helpers` declare headersHelper."""
        d = os.path.join(self.home, ".claude", "plugins")
        os.makedirs(d, exist_ok=True)
        self.write(os.path.join(d, "installed_plugins.json"),
                   json.dumps({"version": 2, "plugins": {k: [{"version": v}] for k, v in versions.items()}}))
        for name, ents in (("known_marketplaces.json", markets), ("known_marketplaces_claudeai.json", claudeai)):
            if ents is None and os.path.exists(os.path.join(d, name)):
                os.remove(os.path.join(d, name))
            elif ents is not None:
                self.write(os.path.join(d, name), json.dumps(
                    {mk: dict(e, installLocation=e.get("installLocation") or self.catalog(mk, versions, helpers))
                     for mk, e in ents.items()}))
        self.write(os.path.join(self.home, ".claude", "settings.json"), json.dumps(settings or {}))

    def catalog(self, mk, versions, helpers):
        root = os.path.join(self.home, ".claude", "plugins", "marketplaces", mk)
        ents = []
        for full in versions:
            name, _s, m = full.partition("@")
            if m == mk:
                ents.append(dict({"name": name, "source": "./" + name}, **({"headersHelper": "h"} if full in helpers else {})))
        self.write(os.path.join(root, ".claude-plugin", "marketplace.json"), json.dumps({"name": mk, "plugins": ents}))
        return root

    def fresh_stamps(self, age_days=0):
        v = "%d\n" % (self.now - age_days * DAY)
        for n in ("claude-md-audit-last", "skill-update-check-last"):
            self.write(os.path.join(self.state, n), v)
        for p in "CDEFG":
            self.write(os.path.join(self.local, "part-%s-last" % p), v)

    def write(self, path, text, mode="w"):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, mode) as f:
            f.write(text)

    def logline(self, *lines):
        self.write(self.log, "".join(x + "\n" for x in lines), "a")

    def rows(self, type_=None):
        try:
            with open(os.path.join(self.local, "items.jsonl")) as f:
                rs = [json.loads(x) for x in f if x.strip()]
        except OSError:
            return []
        return [r for r in rs if type_ is None or r.get("type") == type_]

    def ledger_bytes(self):
        try:
            with open(os.path.join(self.local, "items.jsonl"), "rb") as f:
                return f.read()
        except OSError:
            return b""

    def start(self, *a, sid="S1"):
        p = self.ok("start", *a, sid=sid)
        return [x.split("=", 1)[1] for x in p.stdout.split("\n") if x.startswith("RUN_ID=")][0].split(" ")[0]

    def items(self, kind=None):
        return [r for r in self.rows("item") if kind is None or r["kind"] == kind]

    def status(self, *a):
        p = self.run_ri("status", "--json", *a)
        return p.returncode, json.loads(p.stdout)

    def csr(self, n, text="", status="pending", comments=()):
        self.write(os.path.join(self.board, "%d.json" % n), json.dumps(
            {"data": {"content": text, "status": status, "comments": [{"id": c[0], "content": c[1]} for c in comments]}}))

    def open_ids(self):
        return {o["id"] for o in self.status()[1]["open"]}

    def audit_run(self, findings, state="REPORTED", name="r1"):
        d = os.path.join(self.t, "runs", name)
        os.makedirs(d, exist_ok=True)
        self.write(os.path.join(d, "findings.txt"), "".join(x + "\n" for x in findings))
        self.write(os.path.join(self.state, "audit.jsonl"),
                   json.dumps({"part": "audit", "state": state, "run_dir": d, "dry_run": False}) + "\n", "a")
        return d

    def part_row(self, part, run, result, ts):
        self.write(os.path.join(self.local, "parts.jsonl"),
                   json.dumps({"part": part, "run_id": run, "result": result, "ts": ts}) + "\n", "a")

    def all_pass(self, run, tag, skip=()):
        for p in self.rows("run")[-1]["due_parts"]:
            if p not in skip:
                self.part_row(p, run, "PASS", "%s-%s" % (tag, p))

    def finding(self, path, line, quote, sev="medium", summary="s"):
        return "FINDING " + json.dumps({"sev": sev, "path": path, "line": line, "quote": quote, "summary": summary},
                                       ensure_ascii=False)


# ── V3 base ──────────────────────────────────────────────────────────────────
class TestChannels(Base):
    def test_hold_line_then_ingest_then_zero(self):
        self.logline("ok routine", "2026-11-01 HOLD structural change")
        p = self.ok("peek")
        self.assertIn("pending 1", p.stdout)
        self.start()
        self.ok("scan-channels")
        self.assertEqual(len(self.items("hold")), 1)
        p = self.ok("peek")
        self.assertNotIn("pending", p.stdout)

    def test_unmatched_line_is_one_unclassified(self):
        self.logline("something new")
        self.start()
        self.ok("scan-channels")
        self.assertEqual(len(self.items("unclassified")), 1)

    def test_rename_and_recreate_resets_with_old_inode(self):  # (g) + inode change
        self.logline("ok a")
        self.start()
        self.ok("scan-channels")
        old = os.stat(self.log).st_ino
        os.rename(self.log, self.log + ".1")
        self.logline("ok b")
        self.ok("scan-channels")
        r = self.items("cursor_reset")
        self.assertEqual(len(r), 1)
        self.assertEqual(r[0]["old_inode"], old)

    def test_truncate_in_place_then_hold(self):
        self.logline("ok first line padding padding", "ok second")
        self.start()
        self.ok("scan-channels")
        with open(self.log, "w") as f:
            f.write("HOLD x\n")
        p = self.ok("pending")
        self.assertEqual(len([x for x in p.stdout.split("\n") if x.strip()]), 2)
        self.ok("scan-channels")
        self.assertEqual((len(self.items("hold")), len(self.items("cursor_reset"))), (1, 1))

    def test_identical_line_two_channels_two_ids(self):  # (b) part 1
        other = os.path.join(self.t, "logs", "b.log")
        self.write(other, "ERROR: update failed\n")
        self.logline("ERROR: update failed")
        cfg = self.config()
        cfg["channels"].append(dict(cfg["channels"][0], id="chan2", path=other))
        self.write(os.path.join(self.local, "channels.json"), json.dumps(cfg))
        self.start()
        self.ok("scan-channels")
        self.assertEqual(len({r["id"] for r in self.items("unclassified")}), 2)

    def test_dismissed_unclassified_plus_new_and_cursor_after_items(self):  # (b) part 2
        self.logline("odd one")
        self.start()
        self.ok("scan-channels")
        iid = self.items("unclassified")[0]["id"]
        self.ok("dispose", iid, "--disp", "dismissed", "--reason", "harmless banner line from the tool")
        self.logline("odd two")
        self.ok("scan-channels")
        self.assertEqual(self.open_ids(), {self.items("unclassified")[-1]["id"]})
        rs = self.rows()
        last_item = max(i for i, r in enumerate(rs) if r.get("type") == "item")
        last_cur = max(i for i, r in enumerate(rs) if r.get("type") == "cursor" and r.get("channel") == "chan1")
        self.assertLess(last_item, last_cur)

    def test_identical_lines_different_offsets_and_replay(self):  # (i) part 1 + 3
        self.logline("same", "same")
        self.start()
        self.ok("scan-channels")
        self.assertEqual(len(self.items("unclassified")), 2)
        n = len(self.items())
        self.ok("scan-channels")
        self.assertEqual(len(self.items()), n)

    def test_fault_after_k_then_exactly_once(self):
        self.logline("e1", "e2", "e3")
        self.start()
        p = self.run_ri("scan-channels", MH_FAULT_AFTER=1)
        self.assertNotEqual(p.returncode, 0)
        self.ok("scan-channels")
        srcs = [r["source"].split(": ", 1)[1] for r in self.items("unclassified")]
        self.assertEqual(sorted(srcs), ["e1", "e2", "e3"])

    def test_long_line_truncated(self):
        self.logline("x" * 2000)
        self.start()
        self.ok("scan-channels")
        it = self.items("unclassified")[0]
        self.assertTrue(it.get("truncated"))
        self.assertLessEqual(len(it["source"]), 500)

    def test_registry_absent_is_unknown_and_plugins_still_scanned(self):
        os.remove(os.path.join(self.local, "channels.json"))
        self.start()
        self.ok("scan-channels")
        self.assertEqual(len(self.items("unknown")), 1)
        self.assertTrue(any(r.get("channel") == "plugins" for r in self.rows("cursor")))

    def test_required_id_missing_is_unknown(self):
        self.config(required_ids=["chan1", "nope"])
        self.logline("ok")
        self.start()
        self.ok("scan-channels")
        self.assertEqual([r["summary"] for r in self.items("unknown")], ["required channel nope missing or unread"])

    def test_rewritten_prefix_resets_cursor(self):  # X10 M16
        self.logline("ok aaaa")
        self.start()
        self.ok("scan-channels")
        self.write(self.log, "ok bbbb\nHOLD x\n")  # same first length, different bytes, grown
        self.ok("scan-channels")
        self.assertEqual((len(self.items("cursor_reset")), len(self.items("hold"))), (1, 1))

    def test_stale_runner_stamp_and_registry_backup(self):  # X10 M13 + M14
        stamp = os.path.join(self.t, "runner.stamp")
        self.write(stamp, "%d\n" % (self.now - 48 * 3600))
        cfg = self.config(channels=[{"id": "runner", "type": "stamp", "path": stamp, "max_age_h": 24}])
        self.start()
        self.ok("scan-channels")
        self.assertEqual(len(self.items("runner-stale")), 1)
        bk = os.path.join(self.home, ".claude", "backups", "memory-health-local")
        with open(os.path.join(bk, os.listdir(bk)[0])) as f:
            self.assertEqual(json.load(f), cfg)

    def test_boundary_deny_regenerated(self):
        self.config(project_roots=[os.path.join(self.t, "proj-x")])
        self.start()
        self.ok("scan-channels")
        with open(os.path.join(self.local, "boundary-deny.txt")) as f:
            deny = f.read().split("\n")
        self.assertIn("/" + "Volumes/", deny)
        self.assertIn(os.path.join(self.t, "proj-x"), deny)
        self.assertIn("/proj-x/", deny)


class TestPlugins(Base):
    def setUp(self):
        Base.setUp(self)
        self.plugins({"demo@mk": "1.0.0"}, {"mk": {"source": {"source": "directory"}, "lastUpdated": "2026-10-31T00:00:00.000Z"}})

    def test_version_unlike_cursor_is_one_event(self):
        self.start()
        self.ok("scan-channels")
        self.plugins({"demo@mk": "1.1.0"}, {"mk": {}})
        p = self.ok("pending")
        self.assertEqual([x for x in p.stdout.split("\n") if x], ["medium plugins: demo@mk 1.0.0 -> 1.1.0"])

    def test_unobserved_created_then_fixed_by_observation(self):  # (d) (n) (l)
        self.config(channels=[dict(self.config()["channels"][0], plugins=["demo@mk"])])
        self.start()
        self.ok("scan-channels")
        self.assertEqual(len(self.items("unobserved_plugin")), 1)
        self.assertEqual(self.items("unobserved_plugin")[0]["id"] in self.open_ids(), True)
        self.logline("demo up to date (1.0.0)")
        self.ok("scan-channels")
        self.assertNotIn(self.items("unobserved_plugin")[0]["id"], self.open_ids())
        fixed = [r for r in self.rows("disp") if r["disp"] == "fixed"]
        self.assertTrue(fixed[-1]["ref"].startswith("recheck:"))

    def test_observation_older_than_45_days_reopens(self):  # (o)
        self.logline("demo up to date (1.0.0)")
        self.start()
        self.ok("scan-channels")
        self.assertEqual(self.items("unobserved_plugin"), [])
        self.now += 46 * DAY
        self.fresh_stamps()
        self.start("--force")
        self.ok("scan-channels")
        self.assertEqual(len(self.items("unobserved_plugin")), 1)
        self.now += DAY
        self.logline("demo up to date (1.0.1)")
        self.ok("scan-channels")
        self.assertEqual(self.open_ids(), set())

    def test_crash_before_fixed_then_restart_fixes(self):  # (p)
        self.start()
        self.ok("scan-channels")
        uid = self.items("unobserved_plugin")[0]["id"]
        self.logline("demo up to date (1.0.0)")
        p = self.run_ri("scan-channels", MH_FAULT_AFTER=1)  # obs row written, crash before fixed/cursor
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(len(self.rows("obs")), 1)
        self.assertIn(uid, self.open_ids())
        self.now += DAY  # restart, no new event
        self.ok("scan-channels")
        self.assertNotIn(uid, self.open_ids())

    def test_auto_update_enabled_fixes(self):  # (q)
        self.start()
        self.ok("scan-channels")
        uid = self.items("unobserved_plugin")[0]["id"]
        self.plugins({"demo@mk": "1.0.0"}, {"mk": {"autoUpdate": True, "lastUpdated": "2026-10-31T00:00:00.000Z"}})
        self.ok("scan-channels")
        self.assertNotIn(uid, self.open_ids())

    def unobserved(self):
        self.start()
        self.ok("scan-channels")
        return sorted(r["plugin"] for r in self.items("unobserved_plugin") if r["id"] in self.open_ids())

    def test_marketplace_refresh_is_one_event(self):  # X5 R5
        self.start()
        self.ok("scan-channels")
        self.plugins({"demo@mk": "1.0.0"}, {"mk": {"lastUpdated": "2026-11-01T00:00:00.000Z"}})
        p = self.ok("pending")
        self.assertEqual([x for x in p.stdout.split("\n") if x],
                         ["low plugins: marketplace mk lastUpdated 2026-10-31T00:00:00.000Z -> 2026-11-01T00:00:00.000Z"])

    def test_old_cursor_is_silent_baseline_then_stores_map(self):  # X5 R5b
        self.write(os.path.join(self.local, "items.jsonl"), json.dumps(
            {"ts": "t", "type": "cursor", "channel": "plugins", "versions": {"demo@mk": "1.0.0"}}) + "\n")
        self.assertEqual(self.ok("pending").stdout, "")
        self.start()
        self.ok("scan-channels")
        cur = [r for r in self.rows("cursor") if r["channel"] == "plugins"][-1]
        self.assertEqual(cur.get("lastUpdated"), {"mk": "2026-10-31T00:00:00.000Z"})

    def test_observation_counts_only_from_listing_channel(self):  # X8
        other = os.path.join(self.t, "logs", "b.log")
        self.write(other, "demo up to date (1.0.0)\n")
        cfg = self.config()
        chan2 = dict(cfg["channels"][0], id="chan2", path=other)
        del chan2["plugins"]
        self.config(channels=cfg["channels"] + [chan2])
        self.assertEqual(self.unobserved(), ["demo@mk"])

    def test_default_on_official_and_claudeai(self):  # X9
        self.plugins({"a@claude-code-plugins": "1", "b@knowledge-work-plugins": "1", "c@claudeai-team": "1",
                      "d@claudeai-x": "1"}, {"claude-code-plugins": {}, "knowledge-work-plugins": {}, "claudeai-x": {}},
                     claudeai={"claudeai-team": {}})
        self.assertEqual(self.unobserved(), ["b@knowledge-work-plugins", "d@claudeai-x"])

    def test_malformed_claudeai_file_is_unknown(self):  # X9
        self.write(os.path.join(self.home, ".claude", "plugins", "known_marketplaces_claudeai.json"), "{bad")
        self.unobserved()
        self.assertEqual([r["summary"].startswith("plugins json unreadable") for r in self.items("unknown")], [True])

    def test_headers_helper_plugin_needs_observation(self):  # A1
        mk = "claude-plugins-official"
        self.plugins({"p1@" + mk: "1", "p2@" + mk: "1"}, {mk: {}}, helpers=("p2@" + mk,))
        self.assertEqual(self.unobserved(), ["p2@" + mk])
        self.plugins({"p1@" + mk: "1"}, {mk: {"installLocation": os.path.join(self.t, "no-catalog")}})
        self.ok("scan-channels")
        self.assertIn("p1@" + mk, [r["plugin"] for r in self.items("unobserved_plugin") if r["id"] in self.open_ids()])

    def test_env_disables_auto_update(self):  # X10 M18
        self.plugins({"demo@mk": "1.0.0"}, {"mk": {"autoUpdate": True}})
        self.start()
        self.ok("scan-channels", DISABLE_AUTOUPDATER="1")
        self.assertEqual(len(self.items("unobserved_plugin")), 1)

    def test_stale_marketplace_with_auto_update_on(self):  # X10 M19
        self.plugins({"demo@mk": "1.0.0"}, {"mk": {"autoUpdate": True, "lastUpdated": "2026-09-01T00:00:00.000Z"}})
        self.unobserved()
        self.assertEqual(len(self.items("marketplace-stale")), 1)

    def test_unobserved_task_gives_exit_4(self):  # (m) (j part 3)
        self.start()
        self.ok("scan-channels")
        uid = self.items("unobserved_plugin")[0]["id"]
        self.csr(900, "items: " + uid)
        self.ok("dispose", uid, "--disp", "task", "--ref", "CSR #900")
        self.assertEqual(self.status("--check-refs")[0], 4)


# ── dispose rules ────────────────────────────────────────────────────────────
class TestDispose(Base):
    def seed(self, kind="hold", sev="high", line=None):
        self.logline(line or "%s HOLD" % kind)
        self.start()
        self.ok("scan-channels")
        return [r for r in self.items() if r["kind"] in (kind, "unclassified")][0]["id"]

    def test_high_rejects_deferred_and_dismissed(self):
        iid = self.seed()
        for args in (["--disp", "dismissed", "--reason", "x" * 25],
                     ["--disp", "deferred", "--goal", "g", "--deadline", "2026-11-20", "--method", "m", "--revert", "r"]):
            p = self.run_ri("dispose", iid, *args)
            self.assertEqual(p.returncode, 1, args)
        self.assertEqual(self.rows("disp"), [])

    def test_malformed_dispositions_rejected(self):
        self.logline("odd")
        self.start()
        self.ok("scan-channels")
        iid = self.items("unclassified")[0]["id"]
        bad = [["--disp", "bogus"], ["--disp", "dismissed", "--reason", "short"],
               ["--disp", "deferred", "--goal", "g", "--deadline", "2026-11-20"],
               ["--disp", "deferred", "--goal", "g", "--deadline", "2027-06-01", "--method", "m", "--revert", "r"],
               ["--disp", "verified", "--reason", "tiny"], ["--disp", "fixed", "--ref", "not-a-ref"],
               ["--disp", "task", "--ref", "CSR #1"]]
        for b in bad:
            self.assertEqual(self.run_ri("dispose", iid, *b).returncode, 1, b)
        self.assertEqual(self.run_ri("dispose", "C:nope:0000000000", "--disp", "verified", "--reason", "x" * 30).returncode, 1)
        self.assertEqual(self.rows("disp"), [])

    def test_second_deferral_rejected(self):
        self.logline("odd")
        self.start()
        self.ok("scan-channels")
        iid = self.items("unclassified")[0]["id"]
        d = ["--goal", "g", "--deadline", "2026-11-20", "--method", "m", "--revert", "r"]
        self.ok("dispose", iid, "--disp", "deferred", *d)
        self.assertEqual(self.run_ri("dispose", iid, "--disp", "deferred", *d).returncode, 1)

    def test_fetch_error_rejects_dismissed(self):
        out = os.path.join(self.t, "upd.txt")
        self.write(out, "SKILL: s1 channel=github_raw status=fetch-error upstream=-\nSTATE=UPDATE_CHECK_PASS\n")
        self.start()
        self.ok("ingest-update", "--file", out)
        iid = self.items("fetch-error")[0]["id"]
        self.assertEqual(self.run_ri("dispose", iid, "--disp", "dismissed", "--reason", "x" * 30).returncode, 1)

    def test_dismissed_default_deny_by_kind(self):
        self.start()
        self.ok("part-fail", "--part", "D", "--reason", "doctor timed out")
        pf = self.items("part_failed")[0]["id"]
        os.remove(os.path.join(self.local, "channels.json"))
        self.ok("scan-channels")
        unk = self.items("unknown")[0]["id"]
        for iid in (pf, unk):
            self.assertEqual(self.run_ri("dispose", iid, "--disp", "dismissed", "--reason", "x" * 30).returncode, 1)
        self.config()
        self.write(self.log, "ok\n")
        self.ok("scan-channels")
        self.write(self.log, "")
        self.ok("scan-channels")
        cr = self.items("cursor_reset")[0]["id"]
        self.assertEqual(self.run_ri("dispose", cr, "--disp", "dismissed", "--reason", "x" * 30).returncode, 1)

    def test_coverage_kinds_reject_session_closure(self):  # (j)
        self.plugins({"demo@mk": "1.0.0"}, {"mk": {"source": {"source": "directory"}}})
        self.start()
        self.ok("scan-channels")
        uid = self.items("unobserved_plugin")[0]["id"]
        for args in (["--disp", "verified", "--reason", "x" * 30], ["--disp", "fixed", "--ref", "abcdef1"],
                     ["--disp", "dismissed", "--reason", "x" * 30]):
            self.assertEqual(self.run_ri("dispose", uid, *args).returncode, 1)
        self.assertEqual(self.rows("disp"), [])

    def test_multi_id_all_or_nothing(self):
        self.logline("a1", "a2", "a3")
        self.start()
        self.ok("scan-channels")
        ids = [r["id"] for r in self.items("unclassified")]
        self.assertEqual(self.run_ri("dispose", *(ids + ["C:x:0"]), "--disp", "dismissed", "--reason", "x" * 30).returncode, 1)
        self.assertEqual(self.rows("disp"), [])
        self.ok("dispose", *ids, "--disp", "dismissed", "--reason", "x" * 30)
        self.assertEqual(len(self.rows("disp")), 3)

    def test_task_needs_id_in_csr_and_unlinked_after_removal(self):
        iid = self.seed()
        self.csr(901, "nothing here")
        self.assertEqual(self.run_ri("dispose", iid, "--disp", "task", "--ref", "CSR #901").returncode, 1)
        self.csr(901, "follow-up", comments=[(5, "ids: " + iid)])
        self.ok("dispose", iid, "--disp", "task", "--ref", "CSR #901")
        self.assertEqual(self.status("--check-refs")[0], 0)
        self.csr(901, "follow-up")
        code, st = self.status("--check-refs")
        self.assertEqual((code, st["open"][0]["kind"]), (1, "unlinked_task"))

    def test_check_refs_done_is_orphaned_and_unreachable_is_2(self):
        iid = self.seed()
        self.csr(902, iid)
        self.ok("dispose", iid, "--disp", "task", "--ref", "CSR #902")
        self.csr(902, iid, status="done")
        code, st = self.status("--check-refs")
        self.assertEqual((code, st["open"][0]["kind"]), (1, "orphaned_task"))
        os.remove(os.path.join(self.board, "902.json"))
        self.assertEqual(self.status("--check-refs")[0], 2)

    def test_fixed_then_reobserved_reopens_dismissed_does_not(self):
        self.logline("odd")
        self.start()
        self.ok("scan-channels")
        iid = self.items("unclassified")[0]["id"]
        self.csr(903, "x", comments=[(77, "done")])
        self.ok("dispose", iid, "--disp", "fixed", "--ref", "CSR #903 c#77")
        self.assertEqual(self.run_ri("dispose", iid, "--disp", "fixed", "--ref", "CSR #903 c#78").returncode, 1)
        # same id re-observed: append an item row as the scanner would (re-observation)
        it = dict(self.items()[0])
        self.write(os.path.join(self.local, "items.jsonl"), json.dumps(it) + "\n", "a")
        self.assertIn(iid, self.open_ids())
        n = len(self.items())
        self.ok("scan-channels")
        self.assertEqual(len(self.items()), n)  # re-scan of an open id appends nothing


# ── status / runs / parts / lease ───────────────────────────────────────────
class TestStatusRuns(Base):
    def test_run_exit_2_until_pass_and_non_latest_rejected(self):
        run = self.start("--force")
        self.assertEqual(self.status("--check-refs", "--run", run)[0], 2)
        self.assertEqual(self.status("--check-refs", "--run", "bogus")[0], 2)
        self.ok("scan-channels")
        self.ok("part-fail", "--part", "D", "--reason", "doctor anchor missing")
        self.assertNotEqual(self.status("--check-refs", "--run", run)[0], 0)

    def test_audit_incomplete_part_failed_task_is_4(self):  # (a)
        run = self.start()
        d = self.audit_run(["FINDINGS_TOTAL 0"], state="AUDIT_INCOMPLETE")
        self.assertEqual(self.run_ri("ingest-audit", "--run-dir", d, "--part", "A").returncode, 1)
        pf = self.items("part_failed")[0]["id"]
        self.csr(904, "ids " + pf)
        self.ok("dispose", pf, "--disp", "task", "--ref", "CSR #904")
        self.write(os.path.join(self.state, "claude-md-audit-last"), "1\n")
        run = self.start("--force")
        self.assertEqual(self.status("--check-refs", "--run", run)[0], 2)  # new run: A due again without PASS

    def test_part_failed_task_exit_4_in_same_run(self):
        self.fresh_stamps(age_days=40)
        run = self.start()
        for p in ("B", "C", "D", "E", "F", "G"):
            self.write(os.path.join(self.local, "parts.jsonl"),
                       json.dumps({"part": p, "run_id": run, "result": "PASS", "ts": "t"}) + "\n", "a")
        d = self.audit_run(["FINDINGS_TOTAL 0"], state="AUDIT_INCOMPLETE")
        self.run_ri("ingest-audit", "--run-dir", d, "--part", "A")
        pf = self.items("part_failed")[0]["id"]
        self.csr(905, pf)
        self.ok("dispose", pf, "--disp", "task", "--ref", "CSR #905")
        self.assertEqual(self.status("--check-refs", "--run", run)[0], 4)

    def test_pending_event_makes_c_due(self):  # (c)
        self.logline("HOLD")
        self.start()
        self.assertIn("C", self.rows("run")[-1]["due_parts"])

    def test_lease(self):
        self.start(sid="S1")
        before = self.ledger_bytes()
        p = self.run_ri("scan-channels", sid="S2")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(self.ledger_bytes(), before)
        self.assertEqual(self.run_ri("start", sid="S2").returncode, 1)
        self.ok("scan-channels", sid="S1")
        self.ok("pending", sid="S1")
        self.ok("scan-channels", sid="S1")
        self.now += 31 * 60
        self.ok("start", sid="S2")
        self.assertEqual(self.rows("lease_takeover")[0]["old_session"], "S1")

    def test_torn_tail(self):
        self.start()
        self.write(os.path.join(self.local, "items.jsonl"), '{"type":"item","id":"x', "a")
        self.assertNotEqual(self.status()[0], 2)
        self.logline("odd")
        self.ok("scan-channels")
        self.assertNotEqual(self.status()[0], 2)
        self.assertTrue(os.path.exists(os.path.join(self.local, "items.torn.jsonl")))

    def test_unparseable_mid_line_is_unknown(self):
        self.write(os.path.join(self.local, "items.jsonl"), "garbage\n{}\n")
        self.assertEqual(self.status()[0], 2)
        self.assertIn("ledger unreadable", self.ok("peek").stdout)

    def test_status_without_both_flags_is_open_unchecked(self):  # X11
        p = self.ok("status")
        self.assertIn("STATUS OPEN_UNCHECKED exit=0", p.stdout)
        got = [self.status(*a) for a in ((), ("--check-refs",))]
        self.assertEqual([(c, s["status"]) for c, s in got], [(0, "OPEN_UNCHECKED")] * 2)

    def test_interval_clamped(self):  # X10 M1
        self.logline("HOLD")
        self.assertIn("interval 45d", self.ok("peek", CLAUDE_MD_AUDIT_INTERVAL=100).stdout)


# ── P-B / P-D / P-F ─────────────────────────────────────────────────────────
class TestParts(Base):
    def test_doctor_without_anchor_fails(self):
        f = os.path.join(self.t, "doc.txt")
        self.write(f, "Auto-updates: enabled\nAuto-update channel: latest\n")
        self.start()
        self.assertEqual(self.run_ri("ingest-doctor", "--file", f).returncode, 1)
        self.assertEqual(len(self.items("part_failed")), 1)

    def test_doctor_permission_items(self):
        f = os.path.join(self.t, "doc.txt")
        self.write(f, "Auto-updates: enabled\nAuto-update channel: latest\nLast update attempt: success -> 2 (d)\n\n"
                      "Permission rules that may not work as written\n- rule one never matches\n"
                      "- rule two lets options run arbitrary commands\n\nNo installation issues found.\n")
        self.start()
        self.ok("ingest-doctor", "--file", f)
        sev = sorted(r["sev"] for r in self.items("doctor-permission"))
        self.assertEqual(sev, ["high", "medium"])

    def test_unused_missing_key_fails_and_inventory(self):
        cj = os.path.join(self.t, "claude.json")
        self.write(cj, json.dumps({"pluginUsage": {}, "secretToken": "never-read"}))
        self.start()
        p = self.run_ri("scan-unused", "--file", cj)
        self.assertEqual(p.returncode, 1)
        self.assertNotIn("never-read", p.stdout + p.stderr)
        sk = os.path.join(self.home, ".claude", "skills", "idle-skill")
        self.write(os.path.join(sk, "SKILL.md"), "x")
        self.write(cj, json.dumps({"skillUsage": {}, "pluginUsage": {"demo@mk": {"lastUsedAt": self.now * 1000}}}))
        self.ok("scan-unused", "--file", cj)
        self.assertEqual([r["summary"].split(" ")[1] for r in self.items("unused-extension")], ["idle-skill"])

    def test_doctor_non_zero_exit_fails(self):  # X10 M4
        b = os.path.join(self.t, "bin")
        self.write(os.path.join(b, "claude"), "#!/bin/sh\nprintf 'Auto-updates: on\\nAuto-update channel: latest\\n"
                                              "Last update attempt: success\\n'\nexit 1\n")
        os.chmod(os.path.join(b, "claude"), 0o755)
        self.start()
        self.assertEqual(self.run_ri("ingest-doctor", PATH=b + ":" + os.environ["PATH"]).returncode, 1)
        self.assertEqual(len(self.items("part_failed")), 1)

    def test_doctor_failed_update_attempt_is_item(self):  # X10 M26
        f = os.path.join(self.t, "doc.txt")
        self.write(f, "Auto-updates: on\nAuto-update channel: latest\nLast update attempt: failed (network)\n")
        self.start()
        self.ok("ingest-doctor", "--file", f)
        self.assertEqual(len(self.items("cli-update-failed")), 1)

    def test_unused_after_60_days(self):  # X10 M5
        cj = os.path.join(self.t, "claude.json")
        old = (self.now - 61 * DAY) * 1000
        self.write(cj, json.dumps({"skillUsage": {}, "pluginUsage": {"demo@mk": {"lastUsedAt": old}}}))
        self.start()
        self.ok("scan-unused", "--file", cj)
        self.assertEqual(len(self.items("unused-extension")), 1)

    def test_update_items_keyed_by_upstream(self):
        out = os.path.join(self.t, "upd.txt")
        self.write(out, "SKILL: s1 channel=npm status=update-available upstream=2.0\nSTATE=UPDATE_CHECK_PASS\n")
        self.start()
        self.ok("ingest-update", "--file", out)
        self.write(out, "SKILL: s1 channel=npm status=update-available upstream=2.1\nSTATE=UPDATE_CHECK_PASS\n")
        self.ok("ingest-update", "--file", out)
        self.assertEqual(len(self.items("update-available")), 2)


# ── P-G: embedded npm dependency freshness ──────────────────────────────────
FAKE_NPM = """#!/bin/sh
# fake npm for TestDeps: behaviour chosen per test through FAKE_NPM_* env vars
echo "$1 $(pwd) | $*" >> "$FAKE_NPM_LOG"
case "$1" in
  config) printf '%s' "$FAKE_NPM_CONFIG_OUT"; exit "${FAKE_NPM_CONFIG_RC:-0}" ;;
  outdated)
    [ -n "$FAKE_NPM_OUTDATED_SLEEP" ] && exec sleep "$FAKE_NPM_OUTDATED_SLEEP"
    printf '%s' "$FAKE_NPM_OUTDATED_OUT"; exit "${FAKE_NPM_OUTDATED_RC:-0}" ;;
  audit) printf '%s' "$FAKE_NPM_AUDIT_OUT"; exit "${FAKE_NPM_AUDIT_RC:-0}" ;;
  view) printf '%s\\n' "$FAKE_NPM_VIEW_OUT"; exit "${FAKE_NPM_VIEW_RC:-0}" ;;
esac
exit 64
"""
OUTDATED = json.dumps({"left-pad": {"current": "1.0.0", "wanted": "1.0.1", "latest": "1.3.0"},
                       "chalk": {"current": "4.1.0", "latest": "5.3.0"}})


class TestDeps(Base):
    def setUp(self):
        Base.setUp(self)
        self.bin = os.path.join(self.t, "bin")
        self.write(os.path.join(self.bin, "npm"), FAKE_NPM)
        os.chmod(os.path.join(self.bin, "npm"), 0o755)
        self.npm_log = os.path.join(self.t, "npm.log")
        self.root = os.path.join(self.t, "tool-a")
        os.makedirs(os.path.join(self.root, "node_modules"))
        self.config(dep_roots=[self.root])

    def deps(self, path=None, **fake):
        env = {"FAKE_NPM_LOG": self.npm_log, "MH_DEP_TIMEOUT_S": 1, "FAKE_NPM_CONFIG_OUT": "{}", "FAKE_NPM_OUTDATED_OUT": "{}",
               "FAKE_NPM_AUDIT_OUT": '{"vulnerabilities": {}}'}
        env.update({"FAKE_NPM_" + k.upper(): v for k, v in fake.items()})
        env["PATH"] = path if path is not None else self.bin + os.pathsep + os.environ.get("PATH", "")
        return self.run_ri("scan-deps", **env)

    def dep_items(self):
        return [r for r in self.items() if r["kind"].startswith("dep-")]

    def assert_one_failure(self, p, kind, reason):
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        its = self.dep_items()
        self.assertEqual([(r["kind"], r.get("reason")) for r in its], [(kind, reason)])
        self.assertIn("part_G=FAILED", p.stdout)
        self.assertEqual(len(self.items("part_failed")), 1)

    def npm_calls(self):
        try:
            with open(self.npm_log) as f:
                return [x.split(" ", 1)[0] for x in f.read().split("\n") if x]
        except OSError:
            return []

    def test_a_outdated_exit_1_valid_json(self):
        self.start()
        p = self.deps(outdated_out=OUTDATED, outdated_rc=1)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("INGESTED items=2 part_G=PASS", p.stdout)
        its = self.dep_items()
        self.assertEqual(sorted((r["kind"], r["package"], r["latest"]) for r in its),
                         [("dep-outdated", "chalk", "5.3.0"), ("dep-outdated", "left-pad", "1.3.0")])
        lp = [r for r in its if r["package"] == "left-pad"][0]
        self.assertEqual((lp["current"], lp["wanted"], lp["root"], lp["sev"]), ("1.0.0", "1.0.1", self.root, "low"))
        self.assertIn("tool-a", lp["summary"])
        self.assertEqual(len({r["id"] for r in its}), 2)
        self.assertEqual(self.items("part_failed"), [])
        self.assertIn("G", [r["part"] for r in [json.loads(x) for x in open(os.path.join(self.local, "parts.jsonl"))]
                            if r["result"] == "PASS"])

    def test_b_exit_0_empty_object(self):
        self.start()
        p = self.deps(outdated_out="{}", outdated_rc=0)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.dep_items(), [])
        self.assertIn("part_G=PASS", p.stdout)

    def test_c_exit_2(self):
        self.start()
        self.assert_one_failure(self.deps(outdated_out=OUTDATED, outdated_rc=2), "dep-scan-failed", "exit-2")

    def test_d_non_json(self):
        self.start()
        self.assert_one_failure(self.deps(outdated_out="npm WARN something\n", outdated_rc=1), "dep-scan-failed", "non-json")

    def test_e_timeout(self):
        self.start()
        self.assert_one_failure(self.deps(outdated_sleep=3), "dep-scan-failed", "timeout")

    def test_f_npm_absent(self):
        self.start()
        self.assert_one_failure(self.deps(path=os.path.join(self.t, "empty-bin") + os.pathsep + "/usr/bin:/bin"),
                                "dep-scan-failed", "npm-not-found")
        self.assertEqual(self.npm_calls(), [])

    def test_g_dep_roots_absent(self):
        self.config()
        self.start()
        self.assert_one_failure(self.deps(outdated_out=OUTDATED, outdated_rc=1), "dep-roots-unset", None)
        self.assertEqual(self.npm_calls(), [])

    def test_h_scoped_registry_override(self):
        self.start()
        cfg = json.dumps({"@acme:registry": "https://npm.example.invalid/", "registry": "https://registry.npmjs.org/"})
        self.assert_one_failure(self.deps(config_out=cfg, outdated_out=OUTDATED, outdated_rc=1),
                                "dep-scan-failed", "scoped-registry-override")
        self.assertEqual(self.npm_calls(), ["config"])

    def test_i_error_envelope(self):
        self.start()
        env = json.dumps({"error": {"code": "ENOTCACHED", "summary": "request to registry failed: cache mode"}})
        self.assert_one_failure(self.deps(outdated_out=env, outdated_rc=1), "dep-scan-failed", "error-envelope:ENOTCACHED")
        self.assertEqual(self.items("dep-outdated"), [])

    def malformed(self, bad):
        self.start()
        self.assert_one_failure(self.deps(outdated_out=json.dumps(bad), outdated_rc=1), "dep-scan-failed", "malformed")
        self.assertEqual(self.items("dep-outdated"), [])

    def test_j_malformed_string_value(self):
        self.malformed({"left-pad": "1.0.0", "chalk": {"current": "4.1.0", "latest": "5.3.0"}})

    def test_j_malformed_missing_latest(self):
        self.malformed({"left-pad": {"current": "1.0.0", "wanted": "1.0.1"}})

    def test_k_npx_cached_older_than_registry(self):
        self.config(dep_roots=[self.root], npx_specs=["demo-cli"])
        for h, ver, age in (("aaa", "1.0.0", 2 * DAY), ("bbb", "1.1.0", DAY)):
            pj = os.path.join(self.home, ".npm", "_npx", h, "node_modules", "demo-cli", "package.json")
            self.write(pj, json.dumps({"name": "demo-cli", "version": ver}))
            t = time.time() - age
            os.utime(pj, (t, t))
        self.start()
        p = self.deps(outdated_out="{}", view_out="2.0.0")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        its = self.dep_items()
        self.assertEqual([(r["kind"], r["current"], r["latest"], r["cache_label"]) for r in its],
                         [("dep-outdated", "1.1.0", "2.0.0", "last-cached")])

    def test_l_rerun_no_duplicates(self):
        self.start()
        self.deps(outdated_out=OUTDATED, outdated_rc=1)
        p = self.deps(outdated_out=OUTDATED, outdated_rc=1)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("INGESTED items=0 part_G=PASS", p.stdout)
        its = self.items("dep-outdated")
        self.assertEqual(len(its), 2)
        self.assertEqual(len({r["id"] for r in its}), 2)

    # regression guards found missing by the CSR #2497 design-conformance check (mutations M2-M10)
    def test_m_registry_pinned_and_cwd_is_root(self):
        self.start()
        self.assertEqual(self.deps(outdated_out=OUTDATED, outdated_rc=1).returncode, 0)
        with open(self.npm_log) as f:
            calls = [x.split(" | ", 1) for x in f.read().split("\n") if x]
        root = os.path.realpath(self.root)
        self.assertEqual([(h.split(" ", 1)[1], args) for h, args in calls],
                         [(root, "config list --json"),
                          (root, "outdated --json --registry https://registry.npmjs.org/"),
                          (root, "audit --json --registry https://registry.npmjs.org/")])

    def test_n_root_without_node_modules_skipped(self):
        bare, linked = os.path.join(self.t, "tool-b"), os.path.join(self.t, "tool-c")
        os.makedirs(bare)
        os.makedirs(linked)
        os.makedirs(os.path.join(self.t, "real-nm"))
        os.symlink(os.path.join(self.t, "real-nm"), os.path.join(linked, "node_modules"))
        self.config(dep_roots=[bare, linked])
        self.start()
        p = self.deps()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("SKIP tool-b (no node_modules)", p.stdout)
        self.assertEqual(self.npm_calls(), ["config", "outdated", "audit"])  # only the symlinked root is scanned

    def test_o_dep_outdated_dismissable(self):
        self.start()
        self.deps(outdated_out=OUTDATED, outdated_rc=1)
        iid = self.items("dep-outdated")[0]["id"]
        p = self.run_ri("dispose", iid, "--disp", "dismissed", "--reason", "owner keeps this pin on purpose for now")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_p_part_g_due_forced_and_stamped(self):
        p = self.run_ri("start", "--force")
        self.assertIn("DUE_PARTS=A,B,C,D,E,F,G", p.stdout)
        stamp = os.path.join(self.local, "part-G-last")
        os.remove(stamp)  # setUp's fresh_stamps() already wrote it
        self.assertEqual(self.deps().returncode, 0)
        self.assertTrue(os.path.exists(stamp))

    def test_q_default_timeout_60s(self):
        sys.path.insert(0, SCRIPTS)
        try:
            import routine_sources as rs
        finally:
            sys.path.remove(SCRIPTS)
        old = os.environ.pop("MH_DEP_TIMEOUT_S", None)
        try:
            self.assertEqual(rs.dep_timeout(), 60)
        finally:
            if old is not None:
                os.environ["MH_DEP_TIMEOUT_S"] = old


# ── V2: hook + watchdog ─────────────────────────────────────────────────────
class TestHook(Base):
    def hook(self, **extra):
        env = self.env(**extra)
        env.update({"MH_ACTIVE_RULES": os.path.join(self.t, "absent-rules.md"), "MH_PYTHON": PY})
        p = subprocess.run(["/bin/bash", os.path.join(SCRIPTS, "memory-rules-drift-check.sh")], env=env, input="{}",
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        return p.stdout

    def test_empty_and_nothing_due_prints_nothing(self):
        os.remove(os.path.join(self.local, "channels.json"))
        self.assertEqual(self.hook(), "")

    def test_open_count_and_cap(self):
        self.logline(*("HOLD event number %d with some padding text" % i for i in range(30)))
        out = self.hook()
        self.assertLessEqual(len(out.rstrip("\n")), 600)
        last = out.rstrip("\n").split("\n")[-1]
        shown = len([x for x in out.split("\n") if x.startswith("  · ")])
        self.assertEqual(last, "+%d more pending — routine_items.py pending lists all" % (30 - shown))
        self.start()
        self.ok("scan-channels")
        self.assertIn("open 30", self.hook())

    def test_peek_failure_is_one_line(self):
        bad = os.path.join(self.t, "not-a-dir")
        self.write(bad, "x")
        self.assertRegex(self.hook(MH_LOCAL_DIR=bad), r"^routine peek FAILED rc=[1-9][0-9]*\n$")

    def test_non_interactive_gets_count_line_only(self):
        self.logline("HOLD a", "HOLD b")
        out = self.hook(CLAUDE_CODE_ENTRYPOINT="sdk-cli")
        self.assertEqual(len(out.rstrip("\n").split("\n")), 1, out)
        self.assertIn("pending 2", out)
        self.assertNotIn("run /memory-health routine", out)
        self.assertIn("run /memory-health routine", self.hook(CLAUDE_CODE_ENTRYPOINT="cli"))

    def test_overrun_exit_3(self):
        p = self.run_ri("peek", MH_PEEK_TEST_SLEEP=2, MH_PEEK_BUDGET=1)
        self.assertEqual(p.returncode, 3)

    def test_overdue_prefix(self):
        self.write(os.path.join(self.local, "part-D-last"), "%d\n" % (self.now - 40 * DAY))
        self.assertIn("ROUTINE OVERDUE 40d —", self.hook())

    def test_peek_runs_when_other_segment_exits_early(self):
        self.write(os.path.join(self.local, "part-D-last"), "1\n")
        out = self.hook(MH_ACTIVE_RULES=os.path.join(self.t, "nope"))  # ACTIVE_ABSENT early path
        self.assertIn("[memory-health routine]", out)

    def test_100k_ledger_within_budget(self):
        row = json.dumps({"ts": "2026-11-01T00:00:00Z", "type": "item", "id": "C:x:%d", "part": "C", "kind": "unclassified",
                          "sev": "low", "summary": "s"})
        self.write(os.path.join(self.local, "items.jsonl"), "".join(row.replace("%d", str(i)) + "\n" for i in range(100000)))
        p = self.run_ri("peek", MH_PEEK_BUDGET=1)
        self.assertEqual(p.returncode, 0)
        self.assertIn("open 100000", p.stdout)

    def test_watchdog(self):
        wd = os.path.join(SCRIPTS, "peek-watchdog.sh")
        env = self.env()
        run = lambda: subprocess.run(["/bin/bash", wd], env=env, stdout=subprocess.PIPE, universal_newlines=True).stdout
        self.assertEqual(run(), "")  # first run: no previous watchdog stamp
        pl, wl = os.path.join(self.local, "peek-last"), os.path.join(self.local, "watchdog-last")
        self.write(pl, "")
        t = time.time() - 4 * DAY
        os.utime(pl, (t - DAY, t - DAY))
        os.utime(wl, (t, t))
        self.assertRegex(run(), r"^routine detector stale \(peek-last [^)]+\)\n$")
        os.utime(pl, (t + 10, t + 10))
        os.utime(wl, (t, t))
        self.assertEqual(run(), "")  # both > 72 h old, peek newer -> nothing
        os.remove(pl)
        self.assertEqual(run(), "routine detector stale (peek-last absent)\n")


if __name__ == "__main__":
    unittest.main()


# ── CSR #2509 follow-up P4: scan-deps also reads `npm audit` (outdated alone hid 3 high advisories) ──
def audit_out(**vulns):
    return json.dumps({"vulnerabilities": {n: {"name": n, "severity": sev, "isDirect": False,
                                               "via": [{"source": src, "title": "t-" + n, "severity": sev}]}
                                           for n, (sev, src) in vulns.items()}})


class TestDepsAudit(TestDeps):
    def vulns(self):
        return self.items("dep-vulnerable")

    def test_audit_severity_maps_and_names_the_advisory(self):
        self.start()
        p = self.deps(audit_out=audit_out(undici=("high", 111), lodash=("critical", 222), minimatch=("moderate", 333)),
                      audit_rc=1)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        got = {r["package"]: r["sev"] for r in self.vulns()}
        self.assertEqual(got, {"undici": "medium", "lodash": "high", "minimatch": "low"})
        self.assertIn("high", [r for r in self.vulns() if r["package"] == "undici"][0]["summary"])

    def test_same_advisory_does_not_duplicate_new_advisory_reopens(self):
        self.start()
        self.deps(audit_out=audit_out(undici=("high", 111)), audit_rc=1)
        self.deps(audit_out=audit_out(undici=("high", 111)), audit_rc=1)
        self.assertEqual(len(self.vulns()), 1)
        self.deps(audit_out=audit_out(undici=("high", 999)), audit_rc=1)
        self.assertEqual(len(self.vulns()), 2)

    def test_audit_garbage_fails_part_g(self):
        self.start()
        self.assert_one_failure(self.deps(audit_out="npm WARN x\n", audit_rc=1), "dep-scan-failed", "audit-non-json")

    def test_audit_error_envelope_fails_part_g(self):
        self.start()
        env = json.dumps({"error": {"code": "ENOAUDIT", "summary": "x"}})
        self.assert_one_failure(self.deps(audit_out=env, audit_rc=1), "dep-scan-failed", "audit-error-envelope:ENOAUDIT")

    def test_dep_vulnerable_dismissable_unless_critical(self):
        self.start()
        self.deps(audit_out=audit_out(undici=("high", 111), lodash=("critical", 222)), audit_rc=1)
        by = {r["package"]: r["id"] for r in self.vulns()}
        why = "dev-tool only, no network input reaches it"
        self.assertEqual(self.run_ri("dispose", by["undici"], "--disp", "dismissed", "--reason", why).returncode, 0)
        self.assertEqual(self.run_ri("dispose", by["lodash"], "--disp", "dismissed", "--reason", why).returncode, 1)
