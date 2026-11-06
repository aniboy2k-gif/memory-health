#!/usr/bin/env python3
"""Tests for routine_items.py status rules on task-disposed part_failed and coverage items (CSR #2492 X2, X3;
split out of test_routine_items.py, which holds Base). Synthetic fixtures only.
Run: /usr/bin/python3 -m unittest tests/test_routine_status.py   (hook runtime: 3.9)"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_routine_items import Base  # noqa: E402


# ── X2: task-disposed part_failed, ordered by parts.jsonl append position ──
class TestPartFailedOrder(Base):
    def fail_d(self, n=910, pre_pass=None):
        self.now += 60  # a new run id per start
        run = self.start("--force")
        if pre_pass:
            self.part_row("D", run, "PASS", pre_pass)
        self.ok("part-fail", "--part", "D", "--reason", "doctor anchor missing")
        pf = self.items("part_failed")[-1]["id"]
        self.csr(n, "ids " + pf)
        self.ok("dispose", pf, "--disp", "task", "--ref", "CSR #%d" % n)
        return run, pf

    def run_without_d(self):
        self.fresh_stamps(age_days=40)
        self.write(os.path.join(self.local, "part-D-last"), "%d\n" % self.now)
        self.now += 31 * 60  # lease stale -> start appends a new run row with due_parts from the stamps
        run = self.start()
        self.assertNotIn("D", self.rows("run")[-1]["due_parts"])
        self.all_pass(run, run)
        return run

    def code(self, run):
        return self.status("--check-refs", "--run", run)[0]

    def test_r1_later_pass_unblocks(self):
        self.fail_d()
        self.now += 60
        run2 = self.start("--force")
        self.all_pass(run2, "r2")
        code, st = self.status("--check-refs", "--run", run2)
        self.assertEqual((code, st["status"]), (0, "COMPLETE"))

    def test_r1b_run_without_the_part_keeps_blocking(self):  # regression guard
        self.fail_d()
        self.assertEqual(self.code(self.run_without_d()), 4)

    def test_r1c_pass_then_run_without_the_part(self):
        self.fail_d()
        self.now += 60
        run2 = self.start("--force")
        self.all_pass(run2, "r2")
        self.assertEqual(self.code(self.run_without_d()), 0)

    def test_r1d_pass_before_fail_same_run_blocks(self):  # regression guard
        run, _pf = self.fail_d(pre_pass="early")
        self.all_pass(run, "r1", skip="D")
        self.assertEqual(self.code(run), 4)

    def test_r1e_fixed_by_later_pass_after_csr_done(self):
        _r1, pf = self.fail_d()
        self.now += 60
        run2 = self.start("--force")
        self.all_pass(run2, "r2")
        self.csr(910, "ids " + pf, status="done")
        self.ok("dispose", pf, "--disp", "fixed", "--ref", "r2-D")
        self.assertEqual(self.code(run2), 0)

    def test_r1f_fixed_refuses_pass_before_the_failure(self):
        _run, pf = self.fail_d(pre_pass="early")
        self.assertEqual(self.run_ri("dispose", pf, "--disp", "fixed", "--ref", "early").returncode, 1)

    def test_r1g_missing_failed_row_blocks(self):  # regression guard (fail closed)
        self.fail_d()
        os.remove(os.path.join(self.local, "parts.jsonl"))
        self.now += 60
        run2 = self.start("--force")
        self.all_pass(run2, "r2")
        self.assertEqual(self.code(run2), 4)


# ── X3: the scanner recheck closes task / deferred coverage items ───────────
class TestCoverageRecheck(Base):
    def unknown_registry(self):
        os.remove(os.path.join(self.local, "channels.json"))
        run = self.start()
        self.ok("scan-channels")
        return run, self.items("unknown")[0]["id"]

    def test_r2_task_closed_by_recheck(self):
        run, uid = self.unknown_registry()
        self.csr(920, uid)
        self.ok("dispose", uid, "--disp", "task", "--ref", "CSR #920")
        self.config()
        self.ok("scan-channels")
        last = [r for r in self.rows("disp") if r["id"] == uid][-1]
        self.assertEqual((last["disp"], last["ref"]), ("fixed", "recheck:" + run))
        self.assertEqual(self.status("--check-refs")[0], 0)

    def test_r2b_deferred_closed_by_recheck(self):
        run, uid = self.unknown_registry()
        # coverage items are sev=high, so `dispose` refuses deferred; the row is written as an older ledger would hold it
        self.write(os.path.join(self.local, "items.jsonl"), json.dumps(
            {"ts": "t", "type": "disp", "id": uid, "disp": "deferred", "ref": "", "reason": "",
             "defer": {"goal": "g", "deadline": "2099-01-01", "method": "m", "revert": "r"}}) + "\n", "a")
        self.config()
        self.ok("scan-channels")
        last = [r for r in self.rows("disp") if r["id"] == uid][-1]
        self.assertEqual((last["disp"], last["ref"]), ("fixed", "recheck:" + run))


if __name__ == "__main__":
    unittest.main()


# ── CSR #2509 follow-up P1/P6: task-disposed items are visible before --check-refs; refusal says when it ends ──
class TestUncheckedTasks(Base):
    fail_d = TestPartFailedOrder.fail_d  # same setup: one part_failed item disposed as task

    def test_status_notes_unchecked_task_count(self):
        self.fail_d()
        code, st = self.status()
        self.assertTrue(any("1 task-disposed" in n for n in st["notes"]), st["notes"])

    def test_status_without_tasks_has_no_such_note(self):
        self.start()
        _code, st = self.status()
        self.assertFalse(any("task-disposed" in n for n in st["notes"]), st["notes"])

    def test_peek_shows_unchecked_tasks_even_when_nothing_else_is_open(self):
        self.fail_d()
        self.assertIn("task-unchecked 1", self.ok("peek").stdout)

    def test_start_refusal_says_remaining_time(self):
        self.start(sid="S1")
        p = self.run_ri("start", sid="S2")
        self.assertEqual(p.returncode, 1)
        self.assertRegex(p.stdout + p.stderr, r"lease ends in \d+ ?min")
