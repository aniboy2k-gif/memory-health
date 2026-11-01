#!/usr/bin/env python3
"""Tests for routine_items.py audit side — findings, shards, boundary check, audit-record.sh integration
(CSR #2491; split out of test_routine_items.py, which holds Base). Synthetic fixtures only.
Run: /usr/bin/python3 -m unittest tests/test_routine_audit.py   (hook runtime: 3.9, /bin/bash 3.2)"""
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_routine_items import DAY, SCRIPTS, Base  # noqa: E402


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
        bads = ([self.finding(f, 2, q), "FINDINGS_TOTAL 2"], ["FINDING {not json", "FINDINGS_TOTAL 1"],
                ['FINDING {"sev":"high","path":"p","line":1,"quote":"q"}', "FINDINGS_TOTAL 1"],
                ['FINDING {"sev":"low","path":"p","line":1,"quote":["x"],"summary":"s"}', "FINDINGS_TOTAL 1"],
                ['FINDING {"sev":"low","path":"p","line":true,"quote":"x","summary":"s"}', "FINDINGS_TOTAL 1"])
        for k, bad in enumerate(bads):
            d2 = self.audit_run(bad, name="bad%d" % k)
            p = self.run_ri("ingest-audit", "--run-dir", d2, "--part", "E")
            self.assertEqual(p.returncode, 1, bad)
            self.assertNotIn("Traceback", p.stderr)
        # an over-long quote is cut to its first 120 chars (still verbatim file text), not rejected
        long_q = "z" * 130
        self.write(f, long_q + "\n", "a")
        d3 = self.audit_run([self.finding(f, 3, long_q), "FINDINGS_TOTAL 1"], name="long")
        self.ok("ingest-audit", "--run-dir", d3, "--part", "E")
        self.assertEqual(len(self.items("finding")[-1]["quote"]), 120)

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

    def test_shards_packed_first_fit_decreasing(self):
        # path order a50, b50, c25, d25: sequential packing needs 3 shards, first-fit decreasing 2
        for name, n in (("a.md", 50000), ("b.md", 50000), ("c.md", 25000), ("d.md", 25000)):
            self.scope(name, n)
        self.start()
        _o, plan = self.plan()
        self.assertEqual(len(plan["shards"]), 2)
        self.assertTrue(all(sum(e["chars"] for e in s["entries"]) <= 75000 for s in plan["shards"]))

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
        self.write(os.path.join(ws, "repo-wt-csr9", "sub", "CLAUDE.md"), "x")  # child of a worktree copy
        os.makedirs(os.path.join(ws, "work-iso", "repo", ".claude"))
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
        subprocess.check_call(["git", "-C", r, "config", "color.ui", "always"])  # user config must not hide lines
        self.assertEqual(self.check(r, path).returncode, 1)
        subprocess.check_call(["git", "-C", r, "config", "--unset", "color.ui"])
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
        # the Read tool may show an empty line after the final newline: N+1 is accepted, N+2 is not
        whole = os.path.join(self.t, "shard2.txt")
        self.write(whole, doc + "\n")
        for shown, want in ((5, "STATE=REPORTED"), (6, "STATE=AUDIT_INCOMPLETE")):
            p = subprocess.run(["/bin/bash", ar, "pre", "--shard", whole, "--cwd", self.t], env=env,
                               stdout=subprocess.PIPE, universal_newlines=True)
            r2 = [x.split("=", 1)[1] for x in p.stdout.split("\n") if x.startswith("RUN_DIR=")][0]
            self.write(os.path.join(r2, "report.md"), "COVERED: %s last_line=%d\nFINDINGS_TOTAL 0\nFINDINGS high=0 medium=0 low=0\n"
                       % (doc, shown))
            p = subprocess.run(["/bin/bash", ar, "post", r2, os.path.join(r2, "report.md")], env=env,
                               stdout=subprocess.PIPE, universal_newlines=True)
            self.assertIn(want, p.stdout, (shown, p.stdout))
            time.sleep(1.1)  # run dirs are named by second
        self.start()
        self.ok("ingest-audit", "--run-dir", run, "--part", "E")
        self.assertEqual(len(self.items("finding")), 1)


if __name__ == "__main__":
    unittest.main()
