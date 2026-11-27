"""Unit tests for .github/scripts/earlier_attempts.py (job lists as the GitHub API gives them).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import earlier_attempts  # noqa: E402


def job(name, conclusion, failed=(), cancelled=(), skipped=(), start="2026-11-17T10:00:00Z", end="2026-11-17T11:00:00Z"):
    steps = [{"name": "Set up job", "conclusion": "success"}]
    steps += [{"name": s, "conclusion": "failure"} for s in failed]
    steps += [{"name": s, "conclusion": "cancelled"} for s in cancelled]
    steps += [{"name": s, "conclusion": "skipped"} for s in skipped]
    return {"name": name, "conclusion": conclusion, "started_at": start, "completed_at": end, "steps": steps}


GREEN = job("Tests / App rules and strings", "success")


class FailureTests(unittest.TestCase):
    def test_a_simulator_that_did_not_boot_may_be_re_run(self):
        rows = earlier_attempts.earlier_failures(
            [(1, {"jobs": [GREEN, job("UI flow / UI device conditions", "failure", ["Wait for the simulator"])]})])
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]["machinery"])
        lines, markdown, blocked = earlier_attempts.report(rows, 2)
        self.assertFalse(blocked)
        self.assertTrue(lines[0].startswith("::warning title=Re-run after attempt 1::UI flow / UI device conditions"))
        self.assertIn("machinery: re-run allowed", markdown)

    def test_a_red_test_or_build_blocks(self):
        for step in ("Run UI tests", "Stress run", "Build and test app", "Core tests (macOS)", "Build and test",
                     "Load test (20,000 and 100,000 photos, time and memory limits)", "Navigation rule",
                     "Build for testing", "Archive (unsigned; signed for the App Store during export)"):
            with self.subTest(step=step):
                rows = earlier_attempts.earlier_failures([(1, {"jobs": [job("Some job", "failure", [step])]})])
                lines, markdown, blocked = earlier_attempts.report(rows, 2)
                self.assertTrue(blocked)
                self.assertTrue(lines[0].startswith("::error title=Red in attempt 1::Some job: failure in " + step))
                self.assertIn("**Not uploaded**", markdown)

    def test_machinery_steps(self):
        for step in ("Set up job", "Initialize containers", "Boot simulator (in the background)",
                     "Wait for the simulator", "Fresh simulator (erased and booted)", "Download build products", "Unpack build products",
                     "Install XcodeGen", "Upload to TestFlight", "Upload results", "Post Run actions/checkout@abc",
                     "Run actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "Earlier attempts of this run",
                     "Plan the UI groups", "UI groups green for this app and test code",
                     "Key of this pass and whether it runs", "Stress pass green for this app and test code",
                     "Keep the retry record for the run summary", "Wait before the second try of the retry record",
                     "Keep the retry record for the run summary (second try)"):
            with self.subTest(step=step):
                self.assertTrue(earlier_attempts.is_machinery(step))
        for step in ("Run UI tests", "Select pinned Xcode", "Generate Xcode project", "Job summary"):
            with self.subTest(step=step):
                self.assertFalse(earlier_attempts.is_machinery(step))

    def test_a_cancelled_or_unfinished_step_counts_like_a_failed_one(self):
        flow = "UI flow / UI full flow and video"
        cases = {
            # A timeout (the job fails) or a cancel stops the running test: it did not pass.
            "timeout in a test": (job(flow, "failure", cancelled=["Run UI tests"]), ["Run UI tests"], False),
            "cancel in a test": (job(flow, "cancelled", cancelled=["Run UI tests"]), ["Run UI tests"], False),
            # A cancel while the simulator boots; the steps after it never ran ("skipped").
            "cancel in the boot": (job(flow, "cancelled", cancelled=["Wait for the simulator"], skipped=["Run UI tests"]),
                                   ["Wait for the simulator"], True),
            # A runner lost in the middle of a test leaves the step started and unfinished; a
            # step that never started is not counted.
            "runner lost in a test": ({"name": flow, "conclusion": "failure", "steps": [
                {"name": "Set up job", "conclusion": "success", "started_at": "2026-11-17T10:00:00Z"},
                {"name": "Run UI tests", "conclusion": None, "started_at": "2026-11-17T10:05:00Z"},
                {"name": "Upload results", "conclusion": None, "started_at": None}]}, ["Run UI tests"], False),
        }
        for case, (answer, steps, machinery) in cases.items():
            with self.subTest(case=case):
                rows = earlier_attempts.earlier_failures([(1, {"jobs": [answer]})])
                self.assertEqual(rows[0]["steps"], steps)
                self.assertEqual(rows[0]["machinery"], machinery)

    def test_a_cancelled_ci_run_as_the_api_gives_it(self):
        # CI 43763857204 (cancelled by a newer push): a Linux job stopped in "Initialize
        # containers" (the rest "skipped"), one stopped in its check, a Mac job that never
        # started (no steps at all).
        rows = earlier_attempts.earlier_failures([(1, {"jobs": [
            job("Core tests (Linux)", "cancelled", cancelled=["Initialize containers"],
                skipped=["Run actions/checkout@v5", "Install SQLite headers", "Build and test"]),
            job("App name check", "cancelled",
                cancelled=["Run python3 .github/scripts/name_check.py docs/launch/name-candidates.txt"]),
            {"name": "iOS build and tests (macOS)", "conclusion": "cancelled", "started_at": "2026-11-15T21:28:18Z",
             "completed_at": "2026-11-15T21:28:28Z"},
        ]})])
        self.assertEqual([(r["job"], r["steps"], r["machinery"]) for r in rows], [
            ("Core tests (Linux)", ["Initialize containers"], True),
            ("App name check", ["Run python3 .github/scripts/name_check.py docs/launch/name-candidates.txt"], False),
            ("iOS build and tests (macOS)", [], True),
        ])

    def test_a_job_without_a_failed_step_is_the_runner(self):
        rows = earlier_attempts.earlier_failures([(1, {"jobs": [job("Stress pass / UI stress 10000 photos", "failure")]})])
        self.assertTrue(rows[0]["machinery"])
        self.assertIn("(no failed step)", earlier_attempts.report(rows, 2)[0][0])

    def test_a_carried_over_failure_is_counted_once_and_each_job_is_one_row(self):
        device = job("UI flow / UI device conditions", "failure", ["Wait for the simulator"])
        stress_1 = job("Stress pass / UI stress 10000 photos", "failure", ["Boot simulator (in the background)"])
        stress_2 = job("Stress pass / UI stress 10000 photos", "failure", ["Wait for the simulator"],
                       start="2026-11-17T12:00:00Z", end="2026-11-17T12:10:00Z")
        # Attempt 2 re-ran only the stress pass; the device group's failure was carried over unchanged.
        rows = earlier_attempts.earlier_failures([(1, {"jobs": [device, stress_1]}),
                                                  (2, {"jobs": [dict(device), stress_2]})])
        self.assertEqual([r["job"] for r in rows], ["UI flow / UI device conditions", "Stress pass / UI stress 10000 photos"])
        self.assertEqual(rows[0]["attempts"], [1])
        self.assertEqual(rows[1]["attempts"], [1, 2])
        self.assertEqual(rows[1]["steps"], ["Boot simulator (in the background)", "Wait for the simulator"])
        self.assertEqual(earlier_attempts.one_line(rows),
                         "earlier attempts: UI flow / UI device conditions (attempt 1: Wait for the simulator); "
                         "Stress pass / UI stress 10000 photos (attempt 1, 2: Boot simulator (in the background), "
                         "Wait for the simulator)")
        # The runner would end the title at the comma of "1, 2".
        self.assertTrue(earlier_attempts.report(rows, 3)[0][1].startswith(
            "::warning title=Re-run after attempt 1%2C 2::Stress pass / UI stress 10000 photos: failure/failure in "
            "Boot simulator (in the background), Wait for the simulator; machinery"))

    def test_workflow_commands_are_escaped(self):
        self.assertEqual(earlier_attempts.command("error", "a, b: c", "50% done\nnext"),
                         "::error title=a%2C b%3A c::50%25 done%0Anext")

    def test_a_red_archive_always_blocks(self):
        # The emergency "force" listed this and uploaded anyway; it is gone (the owner's decision
        # 17.11., G5-02/G6-02): no mode of this check lets a failure outside the machinery through.
        rows = earlier_attempts.earlier_failures(
            [(1, {"jobs": [job("Archive and upload to TestFlight", "failure", ["Archive of the tested commit"])]})])
        lines, markdown, blocked = earlier_attempts.report(rows, 2)
        self.assertTrue(blocked)
        self.assertTrue(lines[0].startswith("::error title=Red in attempt 1::"))
        self.assertIn("**Not uploaded**", markdown)
        self.assertNotIn("FORCED", markdown + "".join(lines))

    def test_nothing_failed_before(self):
        rows = earlier_attempts.earlier_failures([(1, {"jobs": [GREEN]})])
        self.assertEqual(rows, [])
        self.assertEqual(earlier_attempts.one_line(rows), "earlier attempts: no failed job")
        self.assertIn("No job failed in attempts 1 to 1.", earlier_attempts.report(rows, 2)[1])


class MainTests(unittest.TestCase):
    def run_main(self, answers, attempt, *extra):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        paths = []
        for number, answer in enumerate(answers, start=1):
            path = os.path.join(folder.name, f"jobs-{number}.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write(answer if isinstance(answer, str) else json.dumps(answer))
            paths.append(path)
        summary, output = os.path.join(folder.name, "summary.md"), os.path.join(folder.name, "output.txt")
        saved = {k: os.environ.get(k) for k in ("GITHUB_STEP_SUMMARY", "GITHUB_OUTPUT")}
        os.environ.update(GITHUB_STEP_SUMMARY=summary, GITHUB_OUTPUT=output)
        try:
            with contextlib.redirect_stdout(io.StringIO()) as log:
                code = earlier_attempts.main(["--attempt", str(attempt), *extra, *paths])
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        return code, log.getvalue(), self.read(summary), self.read(output)

    @staticmethod
    def read(path):
        if not os.path.exists(path):
            return ""
        with open(path, encoding="utf-8") as f:
            return f.read()

    def test_blocks_on_a_red_test_and_writes_the_tag_line(self):
        code, log, summary, output = self.run_main(
            [{"jobs": [job("Tests / iOS build and tests (macOS)", "failure", ["Build and test app"])]}], 2)
        self.assertEqual(code, 1)
        self.assertIn("::error title=Red in attempt 1::", log)
        self.assertIn("| Tests / iOS build and tests (macOS) | 1 | failure | Build and test app |", summary)
        self.assertEqual(output, "text=earlier attempts: Tests / iOS build and tests (macOS) (attempt 1: Build and test app)\n")

    def test_passes_after_machinery_only(self):
        code, log, summary, output = self.run_main(
            [{"jobs": [job("Archive and upload to TestFlight", "failure", ["Upload to TestFlight"])]}], 2)
        self.assertEqual(code, 0)
        self.assertIn("::warning title=Re-run after attempt 1::", log)

    def test_job_filter_reads_only_the_named_job(self):
        # ui.yml's verdict (27.11.): a red app test in core-macos blocks, a red UI group of an
        # earlier attempt does not (ui_evidence.py keeps that record by fingerprint).
        name = "Core and app tests hard (macOS)"
        red_core = [{"jobs": [job(name, "failure", ["Build and test app"]),
                              job("UI device", "failure", ["Run UI tests"])]}]
        self.assertEqual(self.run_main(red_core, 2, "--job", name)[0], 1)
        red_group = [{"jobs": [job(name, "success"), job("UI device", "failure", ["Run UI tests"])]}]
        code, log, _, _ = self.run_main(red_group, 2, "--job", name)
        self.assertEqual(code, 0)
        self.assertNotIn("UI device", log)
        machinery = [{"jobs": [job(name, "failure", ["Fresh simulator (erased and booted)"])]}]
        self.assertEqual(self.run_main(machinery, 2, "--job", name)[0], 0)
        # A partial answer still fails closed, before the filter.
        partial = [{"total_count": 120, "jobs": [job(name, "success")]}]
        self.assertEqual(self.run_main(partial, 2, "--job", name)[0], 1)

    def test_there_is_no_forced_mode(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as stop:
            self.run_main([{"jobs": [job("Tests / iOS build and tests (macOS)", "failure", ["Build and test app"])]}],
                          2, "--forced")
        self.assertEqual(stop.exception.code, 2)

    def test_fails_closed_when_an_attempt_is_missing_or_unreadable(self):
        self.assertEqual(self.run_main([{"jobs": []}], 3)[0], 1)
        for answer in ("not json", {"message": "Not Found"}, [], {"total_count": 120, "jobs": [GREEN]}):
            with self.subTest(answer=answer):
                code, log, _, output = self.run_main([answer], 2)
                self.assertEqual(code, 1)
                self.assertIn("the jobs of attempt 1 are not readable", log)
                self.assertEqual(output, "")
        self.assertEqual(self.run_main([{"total_count": 1, "jobs": [GREEN]}], 2)[0], 0)


if __name__ == "__main__":
    unittest.main()
