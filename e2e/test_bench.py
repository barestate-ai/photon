"""scripts/bench.py: the pure parts, the footprint tool wrapper, and one real cold start."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

import bs

sys.path.insert(0, os.path.join(bs.ROOT, "scripts"))
import bench  # noqa: E402


class Summary(unittest.TestCase):
    def test_median_of_even_and_odd_counts(self):
        self.assertEqual(bench.summarize([300.0, 100.0, 200.0])["p50"], 200.0)
        self.assertEqual(bench.summarize([400.0, 100.0, 200.0, 300.0])["p50"], 250.0)

    def test_reports_every_value_and_the_max(self):
        summary = bench.summarize([5.0, 9.0, 7.0])
        self.assertEqual(summary["values"], [5.0, 9.0, 7.0])
        self.assertEqual(summary["max"], 9.0)

    def test_p95_is_the_nearest_rank_not_the_rank_below(self):
        thirty = list(range(1, 31))
        self.assertEqual(bs.nearest_rank(thirty, 0.95), 29)
        self.assertEqual(bs.nearest_rank(reversed(thirty), 0.95), 29)
        self.assertEqual(bs.nearest_rank([5.0], 0.95), 5.0)
        self.assertEqual(bs.nearest_rank(range(1, 11), 0.95), 10)
        self.assertEqual(bs.nearest_rank(range(1, 21), 0.95), 19)
        self.assertEqual(bench.summarize(thirty)["p95"], 29)

    def test_paint_time_comes_from_the_beacon_after_the_baseline(self):
        log = ["GET /fp.html 200", "GET /__beacon?fp=1000.5 204", "GET /__beacon?fp=2000.5 204"]
        self.assertEqual(bench.paint_epoch_ms(log, since=2), 2000.5)
        self.assertIsNone(bench.paint_epoch_ms(log, since=3))


class Footprint(unittest.TestCase):
    def test_sums_the_footprint_of_every_listed_process(self):
        document = {"processes": [
            {"name": "a", "pid": 1, "footprint": 1_000_000},
            {"name": "b", "pid": 2, "footprint": 2_500_000}], "errors": []}
        self.assertEqual(bench.processes_of(document), [("a", 1, 1_000_000), ("b", 2, 2_500_000)])

    def test_an_unreadable_process_is_an_error_not_a_zero(self):
        document = {"processes": [{"name": "a", "pid": 1, "footprint": 1}], "errors": ["pid 2: denied"]}
        with self.assertRaises(RuntimeError):
            bench.processes_of(document)

    def test_measures_this_python_process(self):
        with tempfile.TemporaryDirectory() as out:
            processes = bench.measure_footprint([os.getpid()], os.path.join(out, "fp.json"))
            self.assertEqual([pid for _, pid, _ in processes], [os.getpid()])
            self.assertGreater(processes[0][2], 1_000_000)
            self.assertTrue(os.path.exists(os.path.join(out, "fp.json")))


class ColdStart(unittest.TestCase):
    def test_launch_to_first_paint_is_measured_on_the_real_app(self):
        with tempfile.TemporaryDirectory() as out:
            report = os.path.join(out, "report.json")
            logs = bs.test_log_dir or os.path.join(out, "logs")
            done = subprocess.run(
                [sys.executable, os.path.join(bs.ROOT, "scripts", "bench.py"), "cold-start",
                 "--runs", "2", "--first-launch-runs", "0", "--out", report],
                stdin=subprocess.DEVNULL, timeout=120, env={**os.environ, "BS_TEST_LOG_DIR": logs})
            # The apps' own logs die with the bench's temp data dirs unless they were copied out.
            self.assertEqual(sorted(os.listdir(logs)), [
                "cef.log", "cef.warm-0.log", "cef.warm-1.log",
                "photon.log", "photon.warm-0.log", "photon.warm-1.log"])
            with open(report) as written:
                cold = json.load(written)["cold_start"]
            self.assertEqual(len(cold["warm"]["values"]), 2)
            self.assertTrue(all(0 < value < 10_000 for value in cold["warm"]["values"]), cold)
            # Two launches are a smoke run: fast, but never an accepted measurement.
            self.assertFalse(cold["pass"])
            self.assertEqual(done.returncode, 1)


class ColdStartVerdict(unittest.TestCase):
    def test_too_few_runs_is_not_a_pass_or_a_fail(self):
        verdict = bench.cold_start_verdict({"warm": {"n": 2}, "budget_ms": 1500, "pass": False})
        self.assertEqual(verdict, "not enough runs for a budget verdict (n<10)")

    def test_enough_runs_report_pass_or_fail(self):
        warm = {"n": 10}
        self.assertIn("PASS", bench.cold_start_verdict({"warm": warm, "budget_ms": 1500, "pass": True}))
        self.assertIn("FAIL", bench.cold_start_verdict({"warm": warm, "budget_ms": 1500, "pass": False}))


class CodeSignClones(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="bs-clones-")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def make(self, bundle, entry, content="payload"):
        directory = os.path.join(self.root, f"{bundle}.code_sign_clone", entry)
        os.makedirs(directory)
        with open(os.path.join(directory, "file"), "w") as out:
            out.write(content)
        return directory

    def test_removes_only_the_entries_created_during_the_run(self):
        old = self.make("org.cef.cefclient", "old")
        other = self.make("com.google.Chrome", "chrome-new-during-run")
        with bench.reaping_code_sign_clones((bench.CEFCLIENT_ID,), self.root):
            new_cef = self.make("org.cef.cefclient", "new")
            new_bs = self.make("dev.barestate.browser", "new")
        self.assertTrue(os.path.isdir(old))
        self.assertTrue(os.path.isdir(other))
        self.assertTrue(os.path.isdir(new_bs))
        self.assertFalse(os.path.exists(new_cef))
        self.assertTrue(os.path.isdir(os.path.dirname(old)))

    def test_cleans_up_when_the_run_raises(self):
        with self.assertRaises(RuntimeError):
            with bench.reaping_code_sign_clones((bench.CEFCLIENT_ID,), self.root):
                leaked = self.make("org.cef.cefclient", "new")
                raise RuntimeError("bench failed")
        self.assertFalse(os.path.exists(leaked))

    def test_only_cefclient_is_ever_reaped(self):
        # Barestate exits cleanly and leaves no clone; its id could name the user's own running copy.
        self.assertEqual(bench.bundles_to_reap("cefclient-baseline"), (bench.CEFCLIENT_ID,))
        for what in ("cold-start", "footprint", "launcher", "all"):
            self.assertEqual(bench.bundles_to_reap(what), ())

    def test_a_symlinked_clone_directory_is_left_alone(self):
        target = tempfile.mkdtemp(prefix="bs-clones-target-")
        self.addCleanup(shutil.rmtree, target, ignore_errors=True)
        os.symlink(target, os.path.join(self.root, "org.cef.cefclient.code_sign_clone"))
        with bench.reaping_code_sign_clones((bench.CEFCLIENT_ID,), self.root):
            os.mkdir(os.path.join(target, "precious"))
        self.assertTrue(os.path.isdir(os.path.join(target, "precious")))

    def test_a_symlink_entry_is_unlinked_not_followed(self):
        target = tempfile.mkdtemp(prefix="bs-clones-target-")
        self.addCleanup(shutil.rmtree, target, ignore_errors=True)
        with bench.reaping_code_sign_clones((bench.CEFCLIENT_ID,), self.root):
            clones = os.path.join(self.root, "org.cef.cefclient.code_sign_clone")
            os.makedirs(clones)
            os.symlink(target, os.path.join(clones, "link"))
        self.assertTrue(os.path.isdir(target))
        self.assertFalse(os.path.lexists(os.path.join(clones, "link")))


@unittest.skipUnless(os.environ.get("BARESTATE_BENCH_CEFCLIENT") == "1",
                     "launches a re-signed cefclient; set BARESTATE_BENCH_CEFCLIENT=1 to run")
class CefclientBaseline(unittest.TestCase):
    def test_a_resigned_clone_of_cefclient_reaches_first_paint_and_leaves_vendor_alone(self):
        before = os.stat(os.path.realpath(bench.CEFCLIENT)).st_mtime_ns
        clones = bench.code_sign_clone_entries(bench.CLONE_ROOT, (bench.CEFCLIENT_ID,))
        with tempfile.TemporaryDirectory() as out:
            report = os.path.join(out, "report.json")
            done = subprocess.run(
                [sys.executable, os.path.join(bs.ROOT, "scripts", "bench.py"), "cefclient-baseline",
                 "--runs", "1", "--first-launch-runs", "1", "--out", report],
                stdin=subprocess.DEVNULL, timeout=180)
            with open(report) as written:
                baseline = json.load(written)["cefclient_baseline"]
            self.assertEqual(done.returncode, 0)
            self.assertEqual(len(baseline["first_launch"]["values"]), 1)
            self.assertEqual(len(baseline["warm"]["values"]), 1)
            self.assertTrue(all(0 < v < 30_000 for s in ("first_launch", "warm")
                                for v in baseline[s]["values"]), baseline)
        self.assertEqual(os.stat(os.path.realpath(bench.CEFCLIENT)).st_mtime_ns, before)
        self.assertEqual(bench.code_sign_clone_entries(bench.CLONE_ROOT, (bench.CEFCLIENT_ID,)) - clones, set())


if __name__ == "__main__":
    unittest.main()
