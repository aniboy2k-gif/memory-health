#!/usr/bin/env python3
"""Tests for the T5 rule of check_fixed_ref (CSR #2492 D4): an audit finding whose quote is still in the file
is `fixed` by a commit only when that commit deleted the audited line. Synthetic git fixtures only.
Run: /usr/bin/python3 -m unittest tests/test_routine_fixed_ref.py   (hook runtime: 3.9)"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_routine_items import NOW, SCRIPTS, Base  # noqa: E402

sys.path.insert(0, SCRIPTS)
import routine_dispose as rd  # noqa: E402
from routine_items import Refuse  # noqa: E402

Q = ".claude/settings.json"
L = "- gitignore \".claude/settings.json\" (it's local) 1"
MARKER = "<!-- local patch: shared .claude/settings.json no longer gitignored -->"
BASE = ["# title", "intro", "see `.claude/settings.json` for hooks", "a", "b", L, "end"]
FIXED = ["# title", MARKER, "intro", "see `.claude/settings.json` for hooks", "a", "b", "end"]
AUDIT = "2026-01-02T12:00:00Z"
GENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def day(n):
    return "2026-01-%02dT00:00:00Z" % n


class Repo:
    def __init__(self, d):
        self.d = d
        os.makedirs(d)
        self.git("-c", "init.defaultBranch=main", "init", "-q")

    def git(self, *a, date=None):
        env = dict(GENV)
        if date:
            env.update({"GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date})
        return subprocess.run(["git", "-C", self.d, "-c", "user.email=t@t", "-c", "user.name=t", "-c",
                               "commit.gpgsign=false"] + list(a), env=env, check=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, universal_newlines=True).stdout.strip()

    def put(self, lines, name="doc.md"):
        with open(os.path.join(self.d, name), "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

    def commit(self, lines, n, name="doc.md", msg="c"):
        if lines is not None:
            self.put(lines, name)
        self.git("add", "-A")
        self.git("commit", "-qm", msg, date=day(n))
        return self.git("rev-parse", "HEAD")


class FixedRefT5(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp(prefix="mh-t5-")
        self.n = 0

    def tearDown(self):
        shutil.rmtree(self.t, ignore_errors=True)

    def repo(self):
        self.n += 1
        return Repo(os.path.join(self.t, "r%d" % self.n))

    def item(self, r, line=6, occ=2, ts=AUDIT, quote=Q, name="doc.md", drop=()):
        m = {"id": "E:finding:x", "kind": "finding", "path": os.path.join(r.d, name), "quote": quote,
             "line": line, "occurrence": occ, "ts": ts}
        return {k: v for k, v in m.items() if k not in drop}

    def accept(self, m, ref):
        return rd.check_fixed_ref(m, ref)

    def refuse(self, m, ref):
        with mock.patch.dict(os.environ, {"MH_BOARD_POST_URL": "file://" + self.t + "/none/{n}.json"}):
            self.assertRaises(Refuse, rd.check_fixed_ref, m, ref)

    def shape641(self):
        """#641 shape: merge commit; the quote-bearing marker is its own hunk at line 2; L deleted; another
        quote line remains; ts between A and R."""
        r = self.repo()
        c0 = r.commit(BASE, 1)
        r.git("checkout", "-qb", "fix")
        r.commit(FIXED, 3, msg="fix")
        r.git("checkout", "-q", "main")
        r.commit(["other"], 3, name="other.txt")
        r.git("merge", "-q", "--no-ff", "fix", "-m", "merge fix", date=day(4))
        return r, c0, r.git("rev-parse", "HEAD")

    # ── accepted ──
    def test_641_shape_accepts_and_returns_full_sha(self):
        r, _c0, m_sha = self.shape641()
        self.assertEqual(self.accept(self.item(r), m_sha), {"ref_sha": m_sha})
        self.assertEqual(self.accept(self.item(r), m_sha[:8]), {"ref_sha": m_sha})

    def test_fix_whose_parent_is_the_audit_commit_accepts(self):
        r = self.repo()
        r.commit(BASE, 1)
        f = r.commit([x for x in BASE if x != L], 3)
        self.assertEqual(self.accept(self.item(r), f), {"ref_sha": f})

    # ── defeats (1)-(9) ──
    def test_d1_later_reword_of_another_quote_line_refused(self):
        r, _c0, m_sha = self.shape641()
        x = r.commit([y.replace("for hooks", "for project hooks") for y in FIXED], 5)
        self.refuse(self.item(r), x)
        y = r.commit([y.replace("for hooks", "for project hooks") for y in FIXED if y != "a"], 6)
        self.refuse(self.item(r), y)  # deletes a line that is not L and adds no quote
        self.accept(self.item(r), m_sha)

    def test_d2_ref_before_the_audit_refused(self):
        r = self.repo()
        r.commit(BASE, 1)
        p2 = r.commit([x for x in BASE if x != L], 1, msg="p2")
        r.commit(BASE, 1, msg="p3 re-adds L")
        f = r.commit([x for x in BASE if x != L], 3)
        self.refuse(self.item(r), p2)
        self.accept(self.item(r), f)

    def test_d3_two_identical_lines_close_only_when_both_are_gone(self):
        r = self.repo()
        two = BASE + ["x", L]
        r.commit(two, 1)
        f1 = r.commit(BASE[:5] + BASE[6:] + ["x", L], 3)
        a, b = self.item(r, 6, 2), self.item(r, 9, 3)
        self.refuse(a, f1)
        self.refuse(b, f1)
        f2 = r.commit(BASE[:5] + BASE[6:] + ["x"], 4)
        self.accept(a, f2)
        self.accept(b, f2)

    def test_d4_in_place_reword_keeping_the_quote_refused(self):
        for new in (L + " <!-- keep -->", L.replace('"', "“", 1).replace('"', "”", 1)):
            with self.subTest(new=new):
                r = self.repo()
                r.commit(BASE, 1)
                f = r.commit([new if x == L else x for x in BASE], 3)
                self.refuse(self.item(r), f)

    def test_d5_rename_away_and_back_refused(self):
        r = self.repo()
        r.commit(BASE, 1)
        r.git("mv", "doc.md", "doc2.md")
        mv = r.commit([x for x in BASE if x != L], 3, name="doc2.md")
        r.git("mv", "doc2.md", "doc.md")
        back = r.commit(None, 4)
        self.refuse(self.item(r), mv)
        self.refuse(self.item(r), back)

    def test_d6_later_re_add_or_new_occurrence_refused(self):
        see = "see `.claude/settings.json` for hooks"
        variants = {"re-add": FIXED + [L], "new occurrence": FIXED + ["more " + Q],
                    "swap": [L if x == see else x for x in FIXED],
                    "curly double": [L.replace('"', "“", 1).replace('"', "”", 1) if x == see else x
                                     for x in FIXED],
                    "curly single": [L.replace("'", "’") if x == see else x for x in FIXED],
                    "nfkc": [L.replace(" 1", " １") if x == see else x for x in FIXED],
                    "spaces": [L.replace(" (", "   (") if x == see else x for x in FIXED]}
        for name, lines in variants.items():
            with self.subTest(variant=name):
                r, _c0, m_sha = self.shape641()
                r.commit(lines, 5)
                self.refuse(self.item(r), m_sha)
        r, _c0, m_sha = self.shape641()
        r.commit([x.replace("for hooks", "for all hooks") for x in FIXED], 5)
        self.accept(self.item(r), m_sha)

    def test_d7_ref_off_head_history_refused(self):
        r = self.repo()
        c0 = r.commit(BASE, 1)
        r.git("checkout", "-qb", "side")
        s = r.commit([x for x in BASE if x != L], 3, msg="side")
        r.git("checkout", "-q", "main")
        f = r.commit([x for x in BASE if x != L], 3, msg="main fix")
        self.assertEqual(r.git("rev-parse", s + "^"), c0)
        self.refuse(self.item(r), s)
        self.accept(self.item(r), f)

    def test_d8_pr_url_or_comment_ref_with_quote_present_refused(self):
        r, _c0, _m = self.shape641()
        self.refuse(self.item(r), "https://github.com/o/r/pull/641")
        self.refuse(self.item(r), "CSR #1 c#2")

    def test_d9_quote_spanning_lines_refused(self):
        r, _c0, m_sha = self.shape641()
        self.refuse(self.item(r, line=2, occ=1, quote="intro see"), m_sha)

    # ── (g) audit anchor ──
    def test_g_anchor_fields_and_match(self):
        r, _c0, m_sha = self.shape641()
        bad = [self.item(r, drop=("line",)), self.item(r, line="6"), self.item(r, line=True),
               self.item(r, drop=("occurrence",)), self.item(r, occ=2.0), self.item(r, drop=("ts",)),
               self.item(r, ts=""), self.item(r, ts="2025-01-01T00:00:00Z"), self.item(r, line=3),
               self.item(r, occ=1), self.item(r, occ=3), self.item(r, line=7)]
        for m in bad:
            with self.subTest(m=m):
                self.refuse(m, m_sha)
        self.accept(self.item(r), m_sha)

    def test_g_line_and_occurrence_must_be_int_not_bool_or_float(self):
        r = self.repo()
        r.commit([L, "a", "see " + Q, "end"], 1)
        f = r.commit(["a", "see " + Q, "end"], 3)
        for line, occ in ((True, 1), (1.0, 1), (1, True), (1, 1.0)):
            with self.subTest(line=line, occ=occ):
                self.refuse(self.item(r, line=line, occ=occ), f)
        self.accept(self.item(r, line=1, occ=1), f)

    def test_g_occurrence_counts_matches_not_lines(self):
        r = self.repo()
        r.commit(["# t", "a %s b %s" % (Q, Q), "x", "y", L, "end"], 1)
        f = r.commit(["# t", "a %s b %s" % (Q, Q), "x", "y", "end"], 3)
        self.refuse(self.item(r, line=5, occ=2), f)
        self.accept(self.item(r, line=5, occ=3), f)

    def test_g_anchor_is_first_parent_at_ts(self):
        r = self.repo()
        r.commit(BASE, 1)
        r.git("checkout", "-qb", "late")
        r.commit(["# moved"] + BASE, 2, msg="side, before ts")
        r.git("checkout", "-q", "main")
        r.git("merge", "-q", "--no-ff", "late", "-m", "merge after ts", date=day(3))
        f = r.commit(["# moved"] + [x for x in BASE if x != L], 4)
        self.accept(self.item(r, line=6), f)
        self.refuse(self.item(r, line=7), f)

    # ── (b)(i) and errors ──
    def test_b_untracked_at_head_refused(self):
        r, _c0, m_sha = self.shape641()
        r.git("rm", "-q", "--cached", "doc.md")
        r.git("commit", "-qm", "untrack", date=day(5))
        self.assertTrue(os.path.exists(os.path.join(r.d, "doc.md")))
        self.refuse(self.item(r), m_sha)

    def test_root_or_non_commit_ref_refused_without_traceback(self):
        r = self.repo()
        c0 = r.commit(BASE, 1)
        tree = r.git("rev-parse", "HEAD^{tree}")
        self.refuse(self.item(r), c0)
        self.refuse(self.item(r), tree)
        self.refuse(self.item(r), "0" * 40)

    def test_fix_reverted_later_has_ref_after_audit_but_wl_tree_refuses(self):
        r = self.repo()
        r.commit(BASE, 1)
        f = r.commit([x for x in BASE if x != L], 3)
        r.commit(BASE, 4, msg="revert")
        self.refuse(self.item(r), f)

    def test_normt_definition(self):
        self.assertEqual(rd.normt(" ‘a’ ‚‛′ “b”„‟ １\n\tz "),
                         "'a' ''' \"b\"\"\" 1 z")


class FixedRefCli(Base):
    def test_dispose_stores_full_sha(self):
        r = Repo(os.path.join(self.t, "repo"))
        iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))  # noqa: E731
        r.put(BASE)
        r.git("add", "-A")
        r.git("commit", "-qm", "c0", date=iso(NOW - 2 * 86400))
        f = os.path.join(r.d, "doc.md")
        self.start()
        d = self.audit_run([self.finding(f, 6, Q), "FINDINGS_TOTAL 1"])
        self.ok("ingest-audit", "--run-dir", d, "--part", "E")
        iid = self.items("finding")[0]["id"]
        r.put([x for x in BASE if x != L])
        r.git("add", "-A")
        r.git("commit", "-qm", "fix", date=iso(NOW + 86400))
        sha = r.git("rev-parse", "HEAD")
        self.ok("dispose", iid, "--disp", "fixed", "--ref", sha[:10])
        with open(os.path.join(self.local, "items.jsonl"), encoding="utf-8") as fh:
            rows = [json.loads(x) for x in fh if x.strip()]
        disp = [x for x in rows if x.get("type") == "disp" and x.get("id") == iid]
        self.assertEqual((disp[-1]["ref"], disp[-1]["ref_sha"]), (sha[:10], sha))


if __name__ == "__main__":
    unittest.main()
