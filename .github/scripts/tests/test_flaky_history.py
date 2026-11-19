"""Tests for .github/scripts/flaky_history.py (runs on Linux, no network).

Job and step names as in the runs of November 2026 (TestFlight run 44461253154, UI run
44480215847). Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import contextlib
import datetime
import io
import json
import os
import sys
import unittest
import unittest.mock
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import flaky_history  # noqa: E402
import ui_tests  # noqa: E402

NOW = datetime.datetime(2026, 11, 19, 12, 0, tzinfo=datetime.timezone.utc)


def job(name, conclusion="success", failed=None, attempt=1, status="completed", minutes=30, step="failure"):
    steps = [{"name": "Set up job", "conclusion": "success"}]
    if failed:
        steps.append({"name": failed, "conclusion": step, "started_at": "2026-11-19T04:00:00Z"})
    end = datetime.datetime(2026, 11, 19, 4, 0, tzinfo=datetime.timezone.utc) + datetime.timedelta(minutes=minutes)
    return {"name": name, "status": status, "conclusion": conclusion, "steps": steps, "run_attempt": attempt,
            "started_at": "2026-11-19T04:00:00Z", "completed_at": end.strftime("%Y-%m-%dT%H:%M:%SZ")}


def artifact_zip(record):
    blob = io.BytesIO()
    with zipfile.ZipFile(blob, "w") as archive:
        archive.writestr(f"flaky-{record['group']}.json", json.dumps(record))
    return blob.getvalue()


class FakeApi(flaky_history.Api):
    def __init__(self, answers, blobs=None, max_calls=80):
        super().__init__("t", "o/r", max_calls)
        self.answers, self.blobs, self.paths = answers, blobs or {}, []

    def get(self, path, **params):
        self._count()
        self.paths.append(path)
        return self.answers.get(path, {})

    def download(self, url):
        self._count()
        return self.blobs[url]

    def _count(self):
        if self.count >= self.max_calls:
            self.stopped = f"call limit ({self.max_calls})"
            raise flaky_history.OutOfCalls(self.stopped)
        self.count += 1


DEVICE = "UI flow / UI device conditions [device app 822dc5d98d30 tests 820feadd77cb]"
A11Y = "UI flow / UI accessibility (small iPhone) [accessibility app 822dc5d98d30 tests 75bad0a777b4]"
OTHER = "UI other flows, purchase and search [flow-other app 822dc5d98d30 tests 7fd9f637e853]"
STRESS = "Stress pass / UI stress 10000 photos"
SMOKE = "Release build smoke test (UI)"

ANSWERS = {
    "actions/workflows/ui.yml/runs": {"workflow_runs": [{"id": 2, "created_at": "2026-11-19T08:00:00Z"}]},
    "actions/workflows/testflight.yml/runs": {"workflow_runs": [{"id": 1, "created_at": "2026-11-19T04:52:18Z"}]},
    "actions/workflows/ui-stress.yml/runs": {"workflow_runs": []},
    "actions/runs/1/jobs": {"jobs": [job(DEVICE, "failure", "Run UI tests"), job(A11Y, "failure", "Run UI tests"),
                                     job(STRESS, "failure", "Stress run"), job("Tests / Core tests (Linux)"),
                                     job("UI gate (every group green for this app and its test code)", "skipped")]},
    "actions/runs/1/artifacts": {"artifacts": [
        {"name": "ui-flaky-device-attempt-1", "archive_download_url": "u1"},
        {"name": "flaky-stress-attempt-1", "archive_download_url": "u2"},
        {"name": "ui-results-device", "archive_download_url": "nope"}]},
    "actions/runs/2/jobs": {"jobs": [job(OTHER, "failure", "No test result (simulator or XCTest failed in every pass)"),
                                     job(OTHER, attempt=2), job(DEVICE, "cancelled"),
                                     job(DEVICE, "failure", "Download build products", attempt=2),
                                     job(DEVICE, None, status="in_progress", attempt=3)]},
    "actions/runs/2/artifacts": {"artifacts": [{"name": "ui-flaky-flow-other-attempt-2", "archive_download_url": "u3"}]},
}
BLOBS = {
    "u1": artifact_zip({"group": "device", "boot": ["bootstatus failed"], "retries": [], "flaky": [
        {"test": "DeviceConditionUITests.test07", "first": ui_tests.INSIDE, "reason": "slow plan"}]}),
    "u2": artifact_zip({"group": "stress", "boot": [], "retries": [], "flaky": []}),
    "u3": artifact_zip({"group": "flow-other", "boot": [], "retries": [{"reasons": ["AX"], "result": "pass"}], "flaky": [
        {"test": "SortlyFlowUITests.test4", "first": "failed", "reason": "AX"}]}),
}


class OutcomeTests(unittest.TestCase):
    def test_why_a_job_did_not_pass(self):
        self.assertEqual(flaky_history.outcome(job(DEVICE)), "green")
        self.assertEqual(flaky_history.outcome(job(DEVICE, "failure", "Run UI tests")), "test red")
        self.assertEqual(flaky_history.outcome(job(STRESS, "failure", "Stress run")), "test red")
        self.assertEqual(flaky_history.outcome(
            job(DEVICE, "failure", "No test result (simulator or XCTest failed in every pass)")), "no result")
        self.assertEqual(flaky_history.outcome(job(DEVICE, "failure", "Wait for the simulator")), "machinery")
        self.assertEqual(flaky_history.outcome(job(DEVICE, "failure")), "machinery")
        self.assertEqual(flaky_history.outcome(job(DEVICE, "cancelled")), "cancelled")
        self.assertIsNone(flaky_history.outcome(job(DEVICE, "skipped")))
        self.assertIsNone(flaky_history.outcome(job(DEVICE, None, status="in_progress")))

    def test_the_same_causes_as_the_gate_and_the_upload_check(self):
        # Second review of C5: the causes come from ui_evidence.py and earlier_attempts.py. A job
        # its time limit stopped in the test step is red (ui_evidence.ran_out_of_time), a cancel
        # before that is a cancel; a failed build, toolchain or project step blocks the upload
        # (earlier_attempts.py), so it is red too, never "machinery".
        self.assertEqual(flaky_history.outcome(job(DEVICE, "cancelled", "Run UI tests", minutes=150, step="cancelled")),
                         "test red")
        self.assertEqual(flaky_history.outcome(job(DEVICE, "cancelled", "Run UI tests", minutes=40, step="cancelled")),
                         "cancelled")
        self.assertEqual(flaky_history.outcome(job(STRESS, "cancelled", "Stress run", minutes=170, step="cancelled")),
                         "test red")
        self.assertEqual(flaky_history.outcome(job(SMOKE, "cancelled", "Run UI tests", minutes=75, step="cancelled")),
                         "test red")
        self.assertEqual(flaky_history.outcome(job(SMOKE, "failure", "Build for testing (Release)")), "test red")
        self.assertEqual(flaky_history.outcome(job(DEVICE, "failure", "Select pinned Xcode")), "test red")
        self.assertEqual(flaky_history.outcome(job(DEVICE, "failure", "Download build products")), "machinery")
        self.assertEqual(flaky_history.outcome(job(DEVICE, "failure", "Built tests present")), "machinery")
        # The time limits are the workflows' own.
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "workflows")
        for workflow, group in (("ui-stress.yml", "stress"), ("testflight.yml", "release-smoke")):
            with open(os.path.join(root, workflow), encoding="utf-8") as f:
                text = f.read()
            limit = flaky_history.TIME_LIMITS[group]
            with self.subTest(group=group):
                self.assertIn(f"    timeout-minutes: {limit}\n", text)

    def test_group_jobs_by_their_name(self):
        self.assertEqual(flaky_history.group_of(DEVICE), "device")
        self.assertEqual(flaky_history.group_of(OTHER), "flow-other")
        self.assertEqual(flaky_history.group_of(STRESS), "stress")
        self.assertEqual(flaky_history.group_of("UI stress 50000 photos"), "stress")
        self.assertEqual(flaky_history.group_of("Release build smoke test (UI)"), "release-smoke")
        self.assertIsNone(flaky_history.group_of("UI build"))
        self.assertIsNone(flaky_history.group_of("UI verdict (full)"))

    def test_the_names_match_the_workflows(self):
        # The step and artifact names this reads are the ones the workflows write.
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "workflows")
        with open(os.path.join(root, "ui.yml"), encoding="utf-8") as f:
            ui = f.read()
        with open(os.path.join(root, "ui-stress.yml"), encoding="utf-8") as f:
            stress = f.read()
        self.assertIn("- name: Run UI tests\n", ui)
        self.assertIn("- name: No test result (", ui)
        self.assertIn("name: ui-flaky-${{ matrix.group }}-attempt-${{ github.run_attempt }}", ui)
        self.assertIn("- name: Stress run\n", stress)
        self.assertIn("name: flaky-stress-attempt-${{ github.run_attempt }}", stress)
        with open(os.path.join(root, "testflight.yml"), encoding="utf-8") as f:
            testflight = f.read()
        self.assertIn("    name: Release build smoke test (UI)\n", testflight)
        self.assertTrue(flaky_history.RECORD.match("ui-flaky-release-smoke-attempt-1"))
        self.assertTrue(flaky_history.RECORD.match("ui-flaky-flow-other-attempt-2"))
        self.assertTrue(flaky_history.RECORD.match("flaky-stress-attempt-1"))
        self.assertFalse(flaky_history.RECORD.match("ui-results-device"))
        self.assertEqual(flaky_history.INSIDE, ui_tests.INSIDE)


class CollectTests(unittest.TestCase):
    def run_main(self, api):
        with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(flaky_history.main(["--days", "3"], api=api, now=NOW), 0)
        return out.getvalue(), err.getvalue()

    def test_every_attempt_counts_and_records_are_read(self):
        api = FakeApi(ANSWERS, BLOBS)
        stats = flaky_history.collect(api, NOW - datetime.timedelta(days=3))
        self.assertEqual(stats["runs"], [2, 1])  # newest first
        self.assertEqual(dict(stats["groups"]["device"]), {"test red": 1, "cancelled": 1, "machinery": 1})
        self.assertEqual(dict(stats["groups"]["flow-other"]), {"no result": 1, "green": 1})
        self.assertEqual(dict(stats["groups"]["stress"]), {"test red": 1})
        self.assertNotIn("nope", [p for p in api.paths])
        c = flaky_history.counts(stats)
        self.assertEqual((c["repeats"], c["passed on repeat"], c["inside"], c["boots"]), (1, 1, 1, 1))
        self.assertEqual(stats["stopped"], "")

    def test_the_summary_and_the_notice(self):
        out, err = self.run_main(FakeApi(ANSWERS, BLOBS))
        self.assertIn("### UI history: the last 3 days, every UI run", out)
        self.assertIn("2 of 2 runs read", out)
        self.assertIn("| device | 0 | 1 | 0 | 1 | 1 |", out)
        self.assertIn("| flow-other | 1 | 0 | 1 | 0 | 0 |", out)
        self.assertIn("| SortlyFlowUITests.test4 | 1 | passed only on the repeat |", out)
        self.assertIn("| DeviceConditionUITests.test07 | 1 | retried inside the test |", out)
        self.assertIn("::notice title=UI history (3 days)::6 group job(s) not green (3 test red, 1 no result, "
                      "1 machinery, 1 cancelled); 2 flaky test(s), 1 simulator repeat(s), over 2 of 2 runs", err)

    def test_the_call_limit_stops_it_and_says_so(self):
        out, _ = self.run_main(FakeApi(ANSWERS, BLOBS, max_calls=5))
        self.assertIn("1 of 2 runs read", out)
        self.assertIn("stopped early: call limit (5)", out)

    def test_it_never_fails(self):
        class Broken(FakeApi):
            def get(self, path, **params):
                raise flaky_history.urllib.error.URLError("down")
        out, err = self.run_main(Broken({}))
        self.assertIn("stopped early: the API did not answer", out)
        self.assertIn("0 group job(s) not green", err)
        with contextlib.redirect_stdout(io.StringIO()) as plain, \
                unittest.mock.patch.dict(os.environ, {"GH_TOKEN": "", "GITHUB_REPOSITORY": ""}):
            self.assertEqual(flaky_history.main([]), 0)
        self.assertIn("nothing read", plain.getvalue())

    def test_few_calls_left_in_the_hour_stop_it(self):
        class Response(io.BytesIO):
            def __init__(self, left):
                super().__init__(b'{"workflow_runs": []}')
                self.headers = {"X-RateLimit-Remaining": str(left)}

        api = flaky_history.Api("t", "o/r", 80, opener=lambda request, timeout: Response(120))
        self.assertEqual(api.get("actions/workflows/ui.yml/runs"), {"workflow_runs": []})
        with self.assertRaises(flaky_history.OutOfCalls):
            api.get("actions/workflows/testflight.yml/runs")
        self.assertIn("only 120 API calls of the hour left", api.stopped)
        seen = []
        api = flaky_history.Api("secret", "o/r", 80, opener=lambda request, timeout: seen.append(request) or Response(900))
        api.get("x")
        # The token goes to the API only, never on to the host a download is redirected to.
        self.assertEqual(seen[0].unredirected_hdrs.get("Authorization"), "Bearer secret")
        self.assertNotIn("Authorization", seen[0].headers)

    def test_a_broken_answer_still_writes_the_summary(self):
        # Second review of C5: a connection that breaks off is no reason to fail the step.
        import http.client
        for error in (http.client.RemoteDisconnected("closed"), http.client.IncompleteRead(b"x"),
                      ConnectionResetError("reset"), zipfile.LargeZipFile("big")):
            class Broken(FakeApi):
                def download(self, url, error=error):
                    raise error
            with self.subTest(error=type(error).__name__):
                out, err = self.run_main(Broken(ANSWERS, BLOBS))
                self.assertIn("stopped early: the API did not answer", out)
                self.assertIn("::notice title=UI history", err)

        class Exploding(FakeApi):
            def get(self, path, **params):
                raise RuntimeError("anything else")
        out, err = self.run_main(Exploding({}))
        self.assertIn("### UI history", out)
        self.assertIn("stopped early", out)

    def test_it_stops_at_its_deadline(self):
        clock = iter(range(0, 10_000, 50))
        api = FakeApi(ANSWERS, BLOBS)
        api.clock, api.deadline = lambda: next(clock), 120
        stats = flaky_history.collect(api, NOW - datetime.timedelta(days=3))
        self.assertIn("time limit", stats["stopped"])

    def test_the_run_list_is_paged_and_a_cap_is_said(self):
        runs = [{"id": i, "created_at": f"2026-11-19T{i % 24:02d}:00:00Z"} for i in range(1, 151)]

        class Paged(FakeApi):
            def get(self, path, **params):
                self._count()
                if path == "actions/workflows/ui.yml/runs":
                    page = params.get("page", 1)
                    return {"total_count": 150, "workflow_runs": runs[(page - 1) * 100:page * 100]}
                return {}
        api = Paged({}, max_calls=1000)
        stats = flaky_history.collect(api, NOW - datetime.timedelta(days=3))
        self.assertEqual(stats["listed"], 150)
        self.assertEqual(stats["capped"], "")
        api = Paged({}, max_calls=1000)
        api.max_pages = 1
        stats = flaky_history.collect(api, NOW - datetime.timedelta(days=3))
        self.assertEqual(stats["listed"], 100)
        self.assertIn("ui.yml: 100 of 150 runs listed", stats["capped"])
        out = flaky_history.markdown(stats, 3)
        self.assertIn("ui.yml: 100 of 150 runs listed", out)

    def test_it_leaves_the_plan_and_verdict_of_a_ui_run_their_calls(self):
        import ui_evidence
        self.assertGreaterEqual(flaky_history.RESERVE, 2 * ui_evidence.MAX_CALLS)

    def test_the_step_never_turns_a_run_red(self):
        import earlier_attempts
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "workflows")
        self.assertIn("UI history of the last 7 days", earlier_attempts.MACHINERY_STEPS)
        for workflow in ("ui.yml", "testflight.yml"):
            with open(os.path.join(root, workflow), encoding="utf-8") as f:
                text = f.read()
            step = text.split("- name: UI history of the last 7 days\n", 1)[1].split("\n      - ", 1)[0].split("\n\n")[0]
            with self.subTest(workflow=workflow):
                self.assertIn("continue-on-error: true", step)
                self.assertIn("        timeout-minutes: 3\n", step)

    def test_a_broken_artifact_is_no_record(self):
        self.assertEqual(flaky_history.records_of(b"not a zip"), [])


if __name__ == "__main__":
    unittest.main()
