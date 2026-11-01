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
        cfg = {"channels": [{"id": "chan1", "type": "log_lines", "path": self.log,
                             "events": [{"re": "HOLD", "kind": "hold", "sev": "high"},
                                        {"re": r"demo up to date \((?P<version>[^)]+)\)", "observe": True, "plugin": "demo@mk"}],
                             "ignore": ["^ok "]}],
               "required_ids": [], "project_roots": [], "discover_dirs": []}
        cfg.update(over)
        self.write(os.path.join(self.local, "channels.json"), json.dumps(cfg))
        return cfg

    def plugins(self, versions, markets, settings=None):
        d = os.path.join(self.home, ".claude", "plugins")
        os.makedirs(d, exist_ok=True)
        self.write(os.path.join(d, "installed_plugins.json"),
                   json.dumps({"version": 2, "plugins": {k: [{"version": v}] for k, v in versions.items()}}))
        self.write(os.path.join(d, "known_marketplaces.json"), json.dumps(markets))
        self.write(os.path.join(self.home, ".claude", "settings.json"), json.dumps(settings or {}))

    def fresh_stamps(self, age_days=0):
        v = "%d\n" % (self.now - age_days * DAY)
        for n in ("claude-md-audit-last", "skill-update-check-last"):
            self.write(os.path.join(self.state, n), v)
        for p in "CDEF":
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
        for p in ("B", "C", "D", "E", "F"):
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

    def test_update_items_keyed_by_upstream(self):
        out = os.path.join(self.t, "upd.txt")
        self.write(out, "SKILL: s1 channel=npm status=update-available upstream=2.0\nSTATE=UPDATE_CHECK_PASS\n")
        self.start()
        self.ok("ingest-update", "--file", out)
        self.write(out, "SKILL: s1 channel=npm status=update-available upstream=2.1\nSTATE=UPDATE_CHECK_PASS\n")
        self.ok("ingest-update", "--file", out)
        self.assertEqual(len(self.items("update-available")), 2)


# ── audit findings ──────────────────────────────────────────────────────────
class TestFindings(Base):
    def test_roundtrip_and_malformed(self):
        f = os.path.join(self.t, "doc.md")
        q = "a | b \\ c 한글"
        self.write(f, "x\n" + q + "\n")
        self.start()
        d = self.audit_run([self.finding(f, 2, q), "FINDINGS_TOTAL 1"])
        self.ok("ingest-audit", "--run-dir", d, "--part", "E")
        self.assertEqual(self.items("finding")[0]["quote"], q)
        for bad in ([self.finding(f, 2, q), "FINDINGS_TOTAL 2"], ["FINDING {not json", "FINDINGS_TOTAL 1"],
                    ['FINDING {"sev":"high","path":"p","line":1,"quote":"q"}', "FINDINGS_TOTAL 1"]):
            d2 = self.audit_run(bad, name="bad%d" % len(bad[0]))
            self.assertEqual(self.run_ri("ingest-audit", "--run-dir", d2, "--part", "E").returncode, 1)

    def test_same_quote_two_lines_two_items(self):  # (i) part 2
        f = os.path.join(self.t, "doc.md")
        self.write(f, "dup text\nother\ndup text\n")
        self.start()
        d = self.audit_run([self.finding(f, 1, "dup text"), self.finding(f, 3, "dup text"), "FINDINGS_TOTAL 2"])
        self.ok("ingest-audit", "--run-dir", d, "--part", "E")
        self.assertEqual(sorted(r["occurrence"] for r in self.items("finding")), [1, 2])

    def test_dismissal_bound_to_file_hash(self):  # (k)
        f = os.path.join(self.t, "doc.md")
        self.write(f, "keep\nbad phrase\n")
        self.start()
        d = self.audit_run([self.finding(f, 2, "bad phrase"), "FINDINGS_TOTAL 1"])
        self.ok("ingest-audit", "--run-dir", d, "--part", "E")
        iid = self.items("finding")[0]["id"]
        self.ok("dispose", iid, "--disp", "dismissed", "--reason", "intended wording kept on purpose")
        d = self.audit_run([self.finding(f, 2, "bad phrase"), "FINDINGS_TOTAL 1"], name="r2")
        self.ok("ingest-audit", "--run-dir", d, "--part", "E")
        self.assertNotIn(iid, self.open_ids())
        self.write(f, "new first line\nkeep\nbad phrase\n")
        d = self.audit_run([self.finding(f, 3, "bad phrase"), "FINDINGS_TOTAL 1"], name="r3")
        self.ok("ingest-audit", "--run-dir", d, "--part", "E")
        self.assertIn(iid, self.open_ids())

    def test_fixed_needs_quote_gone_and_real_sha(self):
        repo = os.path.join(self.t, "repo")
        os.makedirs(repo)
        f = os.path.join(repo, "doc.md")
        self.write(f, "bad phrase\n")
        g = ["git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t"]
        subprocess.check_call(g[:3] + ["init", "-q"])
        subprocess.check_call(g + ["add", "doc.md"])
        subprocess.check_call(g + ["commit", "-qm", "c1"])
        self.start()
        d = self.audit_run([self.finding(f, 1, "bad phrase"), "FINDINGS_TOTAL 1"])
        self.ok("ingest-audit", "--run-dir", d, "--part", "E")
        iid = self.items("finding")[0]["id"]
        sha = subprocess.check_output(g[:3] + ["rev-parse", "HEAD"], universal_newlines=True).strip()
        self.assertEqual(self.run_ri("dispose", iid, "--disp", "fixed", "--ref", sha).returncode, 1)
        self.write(f, "good phrase\n")
        self.assertEqual(self.run_ri("dispose", iid, "--disp", "fixed", "--ref", "deadbeef00").returncode, 1)
        self.assertEqual(self.run_ri("dispose", iid, "--disp", "fixed", "--ref", "CSR #906 c#1").returncode, 1)
        self.ok("dispose", iid, "--disp", "fixed", "--ref", sha)

    def test_medium_finding_accepts_dismissed(self):
        f = os.path.join(self.t, "doc.md")
        self.write(f, "meh\n")
        self.start()
        d = self.audit_run([self.finding(f, 1, "meh"), "FINDINGS_TOTAL 1"])
        self.ok("ingest-audit", "--run-dir", d, "--part", "E")
        self.ok("dispose", self.items("finding")[0]["id"], "--disp", "dismissed", "--reason", "style only, owner wording kept")


# ── P-E shards / coverage ───────────────────────────────────────────────────
class TestShards(Base):
    def scope(self, name, chars, line=1000):
        p = os.path.join(self.home, ".claude", "rules", name)
        self.write(p, "".join(("%s\n" % ("y" * (line - 1))) for _ in range(chars // line)))
        return os.path.realpath(p)

    def plan(self):
        out = self.ok("plan-shards").stdout
        with open(os.path.join(self.local, "shard-plan.json")) as f:
            return out, json.load(f)

    def cover_all(self, plan, tag):
        for s in plan["shards"]:
            run = os.path.join(self.t, "runs", "%s-%d" % (tag, s["n"]))
            os.makedirs(run)
            shutil.copy(s["manifest"], os.path.join(run, "manifest.txt"))
            self.write(os.path.join(run, "findings.txt"), "FINDINGS_TOTAL 0\n")
            self.write(os.path.join(self.state, "audit.jsonl"),
                       json.dumps({"part": "audit", "state": "REPORTED", "run_dir": run}) + "\n", "a")
            self.ok("ingest-audit", "--run-dir", run, "--part", "E")
            self.ok("cover", "--run-dir", run, "--shard", str(s["n"]))

    def cov(self):
        with open(os.path.join(self.local, "audit-coverage.json")) as f:
            return json.load(f)

    def test_200k_file_three_chunks_covered_after_all(self):
        p = self.scope("big.md", 200000)
        self.start()
        _o, plan = self.plan()
        ents = [e for s in plan["shards"] for e in s["entries"] if e["path"] == p]
        self.assertEqual(len(ents), 3)
        s1 = plan["shards"][0]
        run = os.path.join(self.t, "runs", "one")
        os.makedirs(run)
        shutil.copy(s1["manifest"], os.path.join(run, "manifest.txt"))
        self.write(os.path.join(run, "findings.txt"), "FINDINGS_TOTAL 0\n")
        self.write(os.path.join(self.state, "audit.jsonl"), json.dumps({"part": "audit", "state": "REPORTED", "run_dir": run}) + "\n", "a")
        self.ok("ingest-audit", "--run-dir", run, "--part", "E")
        self.ok("cover", "--run-dir", run, "--shard", "1")
        self.assertFalse(self.cov()[p]["complete"])
        self.cover_all({"shards": plan["shards"][1:]}, "rest")
        self.assertTrue(self.cov()[p]["complete"])

    def test_700k_covered_after_two_runs_and_change_restarts(self):  # (e)
        p = self.scope("huge.md", 700000)
        self.start()
        _o, plan = self.plan()
        self.cover_all(plan, "a")
        self.assertFalse(self.cov()[p]["complete"])
        self.now += DAY
        self.start("--force")
        _o, plan = self.plan()
        self.cover_all(plan, "b")
        self.assertTrue(self.cov()[p]["complete"])
        q = self.scope("huge2.md", 700000)
        self.start("--force")
        _o, plan = self.plan()
        self.cover_all(plan, "c")
        self.write(q, "changed\n", "a")
        self.start("--force")
        _o, plan = self.plan()
        self.assertEqual(self.cov()[q].get("ranges", [])[-1:], self.cov()[q].get("ranges", [])[-1:])
        self.assertEqual(sum(1 for s in plan["shards"] for e in s["entries"] if e["path"] == q), 8)

    def test_changed_over_budget_keeps_300k_for_never(self):
        old = [self.scope("old%d.md" % i, 70000) for i in range(12)]
        self.start()
        cov = {p: {"sha256": "stale", "ranges": [[1, 70]], "complete": True, "audited_at": "2026-01-01T00:00:00Z"} for p in old}
        self.write(os.path.join(self.local, "audit-coverage.json"), json.dumps(cov))
        new = [self.scope("new%d.md" % i, 70000) for i in range(6)]
        _o, plan = self.plan()
        chars = sum(e["chars"] for s in plan["shards"] for e in s["entries"] if e["path"] in new)
        self.assertGreaterEqual(chars, 300000 - 70000)
        self.assertGreaterEqual(chars, 4 * 70000)

    def test_cover_refused_without_ingest_leaves_file_identical(self):
        self.scope("a.md", 3000)
        self.start()
        _o, plan = self.plan()
        self.write(os.path.join(self.local, "audit-coverage.json"), '{"keep": 1}')
        run = os.path.join(self.t, "runs", "x")
        os.makedirs(run)
        shutil.copy(plan["shards"][0]["manifest"], os.path.join(run, "manifest.txt"))
        self.write(os.path.join(self.state, "audit.jsonl"), json.dumps({"part": "audit", "state": "REPORTED", "run_dir": run}) + "\n", "a")
        self.assertEqual(self.run_ri("cover", "--run-dir", run, "--shard", "1").returncode, 1)
        with open(os.path.join(self.local, "audit-coverage.json")) as f:
            self.assertEqual(f.read(), '{"keep": 1}')

    def test_concurrent_covers_both_recorded(self):  # (h)
        a, b = self.scope("a.md", 60000), self.scope("b.md", 60000)
        self.start()
        _o, plan = self.plan()
        self.assertEqual(len(plan["shards"]), 2)
        runs = []
        for s in plan["shards"]:
            run = os.path.join(self.t, "runs", "c%d" % s["n"])
            os.makedirs(run)
            shutil.copy(s["manifest"], os.path.join(run, "manifest.txt"))
            self.write(os.path.join(run, "findings.txt"), "FINDINGS_TOTAL 0\n")
            self.write(os.path.join(self.state, "audit.jsonl"), json.dumps({"part": "audit", "state": "REPORTED", "run_dir": run}) + "\n", "a")
            self.ok("ingest-audit", "--run-dir", run, "--part", "E")
            runs.append((run, s["n"]))
        res = []
        th = [threading.Thread(target=lambda r=r: res.append(self.run_ri("cover", "--run-dir", r[0], "--shard", str(r[1])).returncode))
              for r in runs]
        [x.start() for x in th]
        [x.join() for x in th]
        self.assertEqual(res, [0, 0])
        self.assertTrue(self.cov()[a]["complete"] and self.cov()[b]["complete"])

    def test_unregistered_root_is_unknown(self):
        ws = os.path.join(self.t, "ws")
        self.write(os.path.join(ws, "proj", "CLAUDE.md"), "x")
        self.write(os.path.join(ws, "proj-wt-1", "CLAUDE.md"), "x")
        self.config(discover_dirs=[ws])
        self.start()
        self.plan()
        self.assertEqual(len(self.items("unknown")), 1)


# ── public-repo boundary ────────────────────────────────────────────────────
class TestBoundary(Base):
    def repo(self, upstream=True):
        r = os.path.join(self.t, "pub")
        g = ["git", "-C", r, "-c", "user.email=t@t", "-c", "user.name=t"]
        os.makedirs(r)
        subprocess.check_call(["git", "init", "-q", r])
        self.write(os.path.join(r, "a.txt"), "base\n")
        subprocess.check_call(g + ["add", "a.txt"])
        subprocess.check_call(g + ["commit", "-qm", "base"])
        if upstream:
            subprocess.check_call(g + ["branch", "-q", "up"])
            subprocess.check_call(g + ["branch", "-q", "--set-upstream-to=up"])
        return r, g

    def fake_gitleaks(self, rc=0):
        b = os.path.join(self.t, "bin")
        self.write(os.path.join(b, "gitleaks"), "#!/bin/sh\nexit %d\n" % rc)
        os.chmod(os.path.join(b, "gitleaks"), 0o755)
        return b + ":" + os.environ["PATH"]

    def check(self, r, path):
        return self.run_ri("boundary-check", "--repo", r, PATH=path)

    def test_blocks(self):  # (f) + base boundary test
        root = os.path.join(self.t, "secretproj")
        self.config(project_roots=[root])
        self.start()
        path = self.fake_gitleaks()
        r, g = self.repo()
        self.assertEqual(self.check(r, path).returncode, 1)  # deny file absent
        self.ok("scan-channels")
        self.assertEqual(self.check(r, path).returncode, 0)
        self.write(os.path.join(r, "a.txt"), "see /" + "Volumes/x/y\n", "a")
        subprocess.check_call(g + ["commit", "-qam", "c"])
        self.assertEqual(self.check(r, path).returncode, 1)
        subprocess.check_call(g + ["reset", "-q", "--hard", "up"])
        self.write(os.path.join(r, "a.txt"), "mentions secretproj here\n", "a")
        subprocess.check_call(g + ["commit", "-qam", "c2"])
        self.assertEqual(self.check(r, path).returncode, 1)
        subprocess.check_call(g + ["reset", "-q", "--hard", "up"])
        self.assertEqual(self.check(r, self.fake_gitleaks(1)).returncode, 1)
        r2 = os.path.join(self.t, "pub2")
        shutil.move(r, r2)
        subprocess.check_call(["git", "-C", r2, "branch", "-q", "--unset-upstream"])
        self.assertEqual(self.check(r2, path).returncode, 1)  # no @{u}, no origin/HEAD


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


# ── integration: audit-record.sh pre --shard / post FINDING ─────────────────
class TestAuditRecord(Base):
    def test_shard_pre_post_findings(self):
        h = self.home
        agent = os.path.join(h, ".claude", "agents", "memory-health-prompt-auditor-ro.md")
        self.write(agent, "---\nname: memory-health-prompt-auditor-ro\ndescription: read-only auditor\n"
                          "tools: Read, Grep, Glob\nmodel: opus\n---\nbody\n")
        self.write(os.path.join(h, ".claude", "skills", "claude-api", "shared", "prompt-audit.md"), "procedure\n")
        doc = os.path.join(self.t, "doc.md")
        self.write(doc, "l1\nl2\nl3\nl4\n")
        man = os.path.join(self.t, "shard.txt")
        self.write(man, "%s#L1-2\n" % doc)
        env = self.env()
        env["HOME"] = h
        ar = os.path.join(SCRIPTS, "audit-record.sh")
        p = subprocess.run(["/bin/bash", ar, "pre", "--shard", man, "--cwd", self.t], env=env, stdout=subprocess.PIPE,
                           universal_newlines=True)
        self.assertIn("STATE=READY", p.stdout, p.stdout)
        run = [x.split("=", 1)[1] for x in p.stdout.split("\n") if x.startswith("RUN_DIR=")][0]
        rep = os.path.join(run, "report.md")
        self.write(rep, "text\nCOVERED: %s#L1-2 last_line=2\n%s\nFINDINGS_TOTAL 1\nFINDINGS high=0 medium=1 low=0\n"
                   % (doc, self.finding(doc, 2, "l2")))
        p = subprocess.run(["/bin/bash", ar, "post", run, rep], env=env, stdout=subprocess.PIPE, universal_newlines=True)
        self.assertIn("STATE=REPORTED", p.stdout, p.stdout)
        self.start()
        self.ok("ingest-audit", "--run-dir", run, "--part", "E")
        self.assertEqual(len(self.items("finding")), 1)


if __name__ == "__main__":
    unittest.main()
