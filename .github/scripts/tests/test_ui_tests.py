"""Unit tests for the retry rule of .github/scripts/ui_tests.py (runs on Linux, no simulator).

The log snippets are cut from real UI runs of November 2026 (job ids in the comments).
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
import ui_tests  # noqa: E402

# Job 133263283907 (contrast pass): the runner never came up.
AX_TIMEOUT = """\
2026-11-16 12:02:56.651891+0000 SortlyUITests-Runner[63130:167102] [Default] Running tests...
2026-11-16 12:04:02.313288+0000 SortlyUITests-Runner[63130:167102] [Default] Failed to initialize for UI testing: Error Domain=XCTDaemonErrorDomain Code=18 "Timed out waiting for AX loaded notification" UserInfo={NSLocalizedDescription=Timed out waiting for AX loaded notification}
Testing failed:
\tSortlyUITests-Runner (63130) encountered an error (The test runner failed to initialize for UI testing. (Underlying Error: Timed out waiting for AX loaded notification))

** TEST EXECUTE FAILED **
"""

# Job 133298844234: the simulator service dropped the connection while installing the runner.
SERVICE_INTERRUPTED = """\
2026-11-16 12:48:24.530 xcodebuild[7567:28001] [MT] IDELaunchReport: 8462062ab5750b00:8462062ab5751bc0:Launching SortlyUITests Finished with error: Error returned in reply from CoreSimulatorService: Connection interrupted
*** If you believe this error represents a bug, please attach the result bundle at /Users/runner/work/sortly-ios/sortly-ios/build/A11yResults.xcresult
Testing failed:
\tSortlyUITests-Runner encountered an error (Failed to install or launch the test runner. (Underlying Error: Error returned in reply from CoreSimulatorService: Connection interrupted. Software caused connection abort))
** TEST FAILED **
"""

# Job 133311154989: the runner ended inside test 1 (no "passed"/"failed" line for it), the
# restarted runner finished tests 2 to 4.
RESTART = """\
Test Suite 'AccessibilityUITests' started at 2026-11-16 13:19:00.000.
Test Case '-[SortlyUITests.AccessibilityUITests test1_OnboardingAtLargestTextInDarkMode]' started.
    t =   212.31s Tap "Beispiel-Mediathek anlegen" Button
    t =   214.02s     Wait for app.albumist.ios to idle
Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
Test Case '-[SortlyUITests.AccessibilityUITests test2_EnglishMainScreens]' started.
A11Y_TEST_DONE english
Test Case '-[SortlyUITests.AccessibilityUITests test2_EnglishMainScreens]' passed (558.843 seconds).
Test Case '-[SortlyUITests.AccessibilityUITests test3_LargestTextDarkModeReduceMotion]' started.
A11Y_AUDIT_ERROR xxxl plan lower attempt 1 Audit failed to complete in time
Test Case '-[SortlyUITests.AccessibilityUITests test3_LargestTextDarkModeReduceMotion]' passed (539.909 seconds).
Test Case '-[SortlyUITests.AccessibilityUITests test4_Landscape]' started.
Test Case '-[SortlyUITests.AccessibilityUITests test4_Landscape]' passed (178.609 seconds).
\t Executed 3 tests, with 0 failures (0 unexpected) in 1277.361 (1277.483) seconds
** TEST FAILED **
"""

# Job 133066518887: real findings of the accessibility tests.
A11Y_FINDING = """\
A11Y_FAIL en overview | German word 'Fotos' in English UI | label 'Also not counted: 57 Fotos von zu Hause.' | 132,228 188x38
/Users/runner/work/sortly-ios/sortly-ios/App/SortlyUITests/AccessibilityUITests.swift:355: error: -[SortlyUITests.AccessibilityUITests test2_EnglishMainScreens] : failed - en overview: 1 accessibility finding(s): German word 'Fotos'
Test Case '-[SortlyUITests.AccessibilityUITests test2_EnglishMainScreens]' failed (432.008 seconds).
\t Executed 4 tests, with 2 failures (0 unexpected) in 1400.000 (1400.100) seconds
** TEST FAILED **
"""

# Job 133152839956: the simulator service dropped AND tests failed. A failed test is never
# repeated, even when the simulator was part of the story.
SERVICE_AND_ASSERTION = """\
Error returned in reply from CoreSimulatorService: Connection interrupted
/Users/runner/work/sortly-ios/sortly-ios/App/SortlyUITests/AccessibilityUITests.swift:148: error: -[SortlyUITests.AccessibilityUITests test1_OnboardingAtLargestTextInDarkMode] : Failed to get matching snapshots: Timed out while evaluating UI query.
Test Case '-[SortlyUITests.AccessibilityUITests test1_OnboardingAtLargestTextInDarkMode]' failed (333.957 seconds).
** TEST FAILED **
"""

# Job 133066518646: a flow assertion.
FLOW_ASSERTION = """\
Test Case '-[SortlyUITests.SortlyFlowUITests test1_FullFlow]' started.
/Users/runner/work/sortly-ios/sortly-ios/App/SortlyUITests/SortlyFlowUITests.swift:60: error: -[SortlyUITests.SortlyFlowUITests test1_FullFlow] : failed - Missing: open trip for split
Test Case '-[SortlyUITests.SortlyFlowUITests test1_FullFlow]' failed (985.922 seconds).
** TEST FAILED **
"""

# Job 133221335842: the runner was stopped before it started a test.
RUNNER_TERMINATED = """\
Testing failed:
\tSortlyUITests-Runner (15570) encountered an error (Test crashed with signal term while preparing to run tests.)
** TEST FAILED **
"""

# Job 133113879733: a compile error (xcodebuild test builds first).
COMPILE_ERROR = """\
/Users/runner/work/sortly-ios/sortly-ios/App/Sortly/Platform/SamplePhotos.swift:162:66: error: cannot infer key path type from context; consider explicitly specifying a root type
Testing failed:
** TEST FAILED **
"""

APP_TRAP = """\
Test Case '-[SortlyUITests.SortlyFlowUITests test1_FullFlow]' started.
Sortly/AppModel.swift:812: Fatal error: Unexpectedly found nil while unwrapping an Optional value
Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
** TEST FAILED **
"""


class DecideTests(unittest.TestCase):
    def test_green_pass_is_a_pass(self):
        self.assertEqual(ui_tests.decide(0, RESTART), ("pass", []))

    def test_ax_loaded_timeout_is_retried(self):
        verdict, reasons = ui_tests.decide(65, AX_TIMEOUT)
        self.assertEqual(verdict, "retry")
        self.assertIn("AX loaded notification timed out", reasons)

    def test_service_interrupted_is_retried(self):
        verdict, reasons = ui_tests.decide(65, SERVICE_INTERRUPTED)
        self.assertEqual(verdict, "retry")
        self.assertIn("CoreSimulatorService connection lost", reasons)

    def test_runner_restart_alone_is_not_retried(self):
        # It is also what an app hang or a runner crash without a report looks like.
        verdict, reasons = ui_tests.decide(65, RESTART)
        self.assertEqual(verdict, "fail")
        self.assertIn("runner restart alone", reasons[0])

    def test_runner_restart_with_a_service_error_is_retried(self):
        log = RESTART.replace("Restarting after", "Error returned in reply from CoreSimulatorService: Connection interrupted\nRestarting after")
        self.assertEqual(ui_tests.decide(65, log)[0], "retry")

    def test_stale_service_banner_is_not_a_simulator_failure(self):
        log = "attempting to unload a stale CoreSimulatorService job\n** TEST FAILED **\n"
        self.assertEqual(ui_tests.decide(65, log)[0], "fail")

    def test_runner_restart_with_app_crash_report_is_not_retried(self):
        log = RESTART.replace("Restarting after", "Error returned in reply from CoreSimulatorService: Connection interrupted\nRestarting after")
        verdict, reasons = ui_tests.decide(65, log, ["/Users/runner/Library/Logs/DiagnosticReports/Sortly-2026-11-16-131900.ips"])
        self.assertEqual(verdict, "fail")
        self.assertTrue(any("Sortly-2026-11-16-131900.ips" in r for r in reasons))

    def test_crash_report_wins_over_an_infra_signature(self):
        verdict, _ = ui_tests.decide(65, SERVICE_INTERRUPTED, ["/tmp/SortlyUITests-Runner-2026-11-16.ips"])
        self.assertEqual(verdict, "fail")

    def test_accessibility_finding_is_not_retried(self):
        verdict, reasons = ui_tests.decide(65, A11Y_FINDING)
        self.assertEqual(verdict, "fail")
        self.assertIn("accessibility finding", reasons)

    def test_failed_test_is_not_retried_even_with_a_service_error(self):
        verdict, reasons = ui_tests.decide(65, SERVICE_AND_ASSERTION)
        self.assertEqual(verdict, "fail")
        self.assertIn("a test failed", reasons)

    def test_green_pass_without_any_test_fails(self):
        log = "Test Suite 'Selected tests' started.\n\t Executed 0 tests, with 0 failures (0 unexpected)\n** TEST EXECUTE SUCCEEDED **\n"
        verdict, reasons = ui_tests.decide(0, log)
        self.assertEqual(verdict, "fail")
        self.assertIn("no test ran", reasons[0])

    def test_assertion_is_not_retried(self):
        self.assertEqual(ui_tests.decide(65, FLOW_ASSERTION)[0], "fail")

    def test_fatal_error_in_the_app_is_not_retried(self):
        verdict, reasons = ui_tests.decide(65, APP_TRAP)
        self.assertEqual(verdict, "fail")
        self.assertIn("Swift runtime error (Fatal error)", reasons)

    def test_runner_stopped_before_any_test_is_retried(self):
        verdict, reasons = ui_tests.decide(65, RUNNER_TERMINATED)
        self.assertEqual(verdict, "retry")
        self.assertEqual(reasons, ["test runner stopped before the tests"])

    def test_runner_crash_inside_a_test_is_not_retried(self):
        log = RUNNER_TERMINATED.replace("Test crashed with signal term while preparing to run tests", "Test crashed with signal trap")
        self.assertEqual(ui_tests.decide(65, log)[0], "fail")

    def test_compile_error_is_not_retried(self):
        self.assertEqual(ui_tests.decide(65, COMPILE_ERROR), ("fail", ["an error was recorded"]))

    def test_unknown_failure_is_not_retried(self):
        log = "Test Case '-[SortlyUITests.SortlyFlowUITests test2_LargeTextDarkMode]' passed (54.787 seconds).\n** TEST FAILED **\n"
        self.assertEqual(ui_tests.decide(65, log)[0], "fail")

    def test_result_bundle_must_agree(self):
        # The log only shows the simulator, but the bundle has a real issue: no repeat.
        verdict, reasons = ui_tests.decide(65, SERVICE_INTERRUPTED, bundle=["result bundle: Crash: Sortly (4242)"])
        self.assertEqual(verdict, "fail")
        self.assertIn("result bundle: Crash: Sortly (4242)", reasons)

    def test_unreadable_result_bundle_blocks_the_repeat(self):
        verdict, _ = ui_tests.decide(65, AX_TIMEOUT, bundle=["result bundle not readable (no such file)"])
        self.assertEqual(verdict, "fail")

    def test_simulator_gone_after_the_pass_counts_as_infra(self):
        log = "Test Case '-[SortlyUITests.SortlyFlowUITests test2_LargeTextDarkMode]' started.\n** TEST FAILED **\n"
        probe = ("An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):\n"
                 "Process spawn via launchd failed because device is not booted.\n")
        self.assertEqual(ui_tests.decide(65, log, probe=probe)[0], "retry")


# Reviewer's adversarial cases (16.11.): each must NOT be repeated.
R = "Restarting after unexpected exit, crash, or test timeout in SortlyFlowUITests.test1_FullFlow(); summary will include totals from previous launches.\n"
ADVERSARIAL = {
    "runner segv, test-named line": "Test Case '-[SortlyUITests.SortlyFlowUITests test1_FullFlow]' started.\n" + R +
        "Testing failed:\n\tSortlyFlowUITests.test1_FullFlow(): Test crashed with signal segv.\n** TEST FAILED **\n",
    "runner abrt, Crash: line": "Test Case '-[SortlyUITests.AccessibilityUITests test3_X]' started.\n" + R +
        "Testing failed:\n\ttest3_X(): Crash: SortlyUITests-Runner (1234) at specialized Array.subscript\n** TEST FAILED **\n",
    "app crash (XCTest wording)": "Test Case '-[SortlyUITests.SortlyFlowUITests test2_X]' started.\n" + R +
        "Testing failed:\n\tAlbumist (app.albumist.ios) crashed in specialized AppModel.apply()\n** TEST FAILED **\n",
    "test timeout": "Test Case '-[SortlyUITests.SortlyFlowUITests test1_FullFlow]' started.\n" + R +
        "Testing failed:\n\ttest1_FullFlow(): Test exceeded execution time allowance of 10 minutes\n** TEST FAILED **\n",
    "new-style failed line": "Test case 'SortlyFlowUITests.test1_FullFlow()' failed on 'iPhone 17 Pro' (985.9 seconds)\n" + R + "** TEST FAILED **\n",
    "suite failed only (setUp error)": "Test Suite 'SortlyFlowUITests' failed at 2026-11-16.\nCoreSimulatorService: Connection interrupted\n** TEST FAILED **\n",
    "issue outside test (<unknown>:0)": "<unknown>:0: error: SortlyUITests : Failed to launch app\nLost connection to testmanagerd\n** TEST FAILED **\n",
    "A11Y_FAIL tab-separated": "A11Y_FAIL\ten overview | x\nCoreSimulatorService: Connection interrupted\n** TEST FAILED **\n",
    "swift testing issue": "\u2718 Test foo() recorded an issue at X.swift:3\nCoreSimulatorService\n",
    "hang: app never idles then runner killed": "Test Case '-[SortlyUITests.SortlyFlowUITests test1_FullFlow]' started.\n"
        "    t = 214.02s     Wait for app.albumist.ios to idle\n" + R + "** TEST FAILED **\n",
}


class AdversarialTests(unittest.TestCase):
    def test_none_is_repeated(self):
        for name, log in ADVERSARIAL.items():
            with self.subTest(name):
                verdict, reasons = ui_tests.decide(65, log)
                self.assertEqual(verdict, "fail", f"{name}: {reasons}")

    def test_none_is_repeated_even_when_the_simulator_is_gone_afterwards(self):
        probe = "Process spawn via launchd failed because device is not booted.\n"
        for name, log in ADVERSARIAL.items():
            if name == "hang: app never idles then runner killed":
                continue  # a dead simulator after a bare restart is the one infra case (test above)
            with self.subTest(name):
                self.assertEqual(ui_tests.decide(65, log, probe=probe)[0], "fail")


def case(name, result, *messages):
    return {"nodeType": "Test Case", "name": name, "result": result,
            "children": [{"nodeType": "Failure Message", "name": m} for m in messages]}


def bundle(*cases, top_messages=()):
    return {"testNodes": [{"nodeType": "Test Plan", "name": "SortlyUI", "result": "Failed", "children": [
        {"nodeType": "UI test bundle", "name": "SortlyUITests", "result": "Failed",
         "children": [{"nodeType": "Failure Message", "name": m} for m in top_messages] + [
             {"nodeType": "Test Suite", "name": "SortlyFlowUITests", "result": "Failed", "children": list(cases)}]}]}]}


class BundleTests(unittest.TestCase):
    def test_passed_tests_and_an_infra_message_are_clean(self):
        tree = bundle(case("test2_LargeTextDarkMode()", "Passed"),
                      case("test1_FullFlow()", "Failed",
                           "SortlyUITests-Runner encountered an error (Failed to install or launch the test runner. "
                           "(Underlying Error: Error returned in reply from CoreSimulatorService: Connection interrupted))"))
        self.assertEqual(ui_tests.bundle_findings(tree), [])

    def test_crash_message_is_a_finding(self):
        tree = bundle(case("test1_FullFlow()", "Failed", "Crash: Sortly (4242) at AppModel.apply()"))
        self.assertEqual(len(ui_tests.bundle_findings(tree)), 1)

    def test_failed_test_without_a_message_is_a_finding(self):
        self.assertEqual(len(ui_tests.bundle_findings(bundle(case("test3_TapThroughSweep()", "Failed")))), 1)

    def test_issue_outside_any_test_is_a_finding(self):
        tree = bundle(case("test2()", "Passed"), top_messages=["Failed to launch app.albumist.ios"])
        self.assertEqual(len(ui_tests.bundle_findings(tree)), 1)

    def test_skipped_and_expected_failures_are_clean(self):
        self.assertEqual(ui_tests.bundle_findings(bundle(case("a()", "Skipped"), case("b()", "Expected Failure"))), [])

    def test_infra_quoted_in_a_test_failure_message_is_a_finding(self):
        # A test's own failure that quotes the simulator service is still the test's failure.
        quoted = ("/Users/runner/work/App/SortlyUITests/SortlyFlowUITests.swift:60: error: "
                  "-[SortlyUITests.SortlyFlowUITests test1_FullFlow] : failed - "
                  "Error returned in reply from CoreSimulatorService: Connection interrupted")
        self.assertEqual(len(ui_tests.bundle_findings(bundle(case("test1_FullFlow()", "Failed", quoted)))), 1)
        crashed = "Test crashed with signal abrt (CoreSimulatorService: Connection interrupted)"
        self.assertEqual(len(ui_tests.bundle_findings(bundle(case("test1_FullFlow()", "Failed", crashed)))), 1)


class ParseBundleTests(unittest.TestCase):
    """xcresulttool output that is not an object with a list "testNodes" is not readable (no repeat)."""

    def test_valid_output_is_parsed(self):
        import json
        self.assertEqual(ui_tests.parse_bundle(json.dumps(bundle(case("a()", "Passed")))), [])
        self.assertEqual(len(ui_tests.parse_bundle(json.dumps(bundle(case("a()", "Failed", "boom"))))), 1)

    def test_other_shapes_are_not_readable(self):
        for text in ["[]", "null", "42", '"tests"', "{}", '{"testNodes": null}', '{"testNodes": {}}',
                     '{"devices": []}', "not json", ""]:
            with self.subTest(text=text):
                findings = ui_tests.parse_bundle(text)
                self.assertEqual(len(findings), 1)
                self.assertTrue(findings[0].startswith("result bundle not readable"), findings)
                self.assertEqual(ui_tests.decide(65, AX_TIMEOUT, bundle=findings)[0], "fail")

    def test_odd_nodes_inside_the_list_do_not_crash(self):
        self.assertEqual(ui_tests.parse_bundle('{"testNodes": [1, "x", {"children": 3}]}'), [])


class StrongRealTests(unittest.TestCase):
    """A test's own failure counts even on a line that also quotes a simulator service error."""

    SERVICE = "Error returned in reply from CoreSimulatorService: Connection interrupted"

    def check(self, line, reason):
        real, infra = ui_tests.scan(line + "\n")
        self.assertIn(reason, real)
        self.assertIn("CoreSimulatorService connection lost", infra)
        self.assertEqual(ui_tests.decide(65, SERVICE_INTERRUPTED + line + "\n")[0], "fail")

    def test_error_of_a_test_quoting_the_service(self):
        self.check("/Users/runner/work/App/SortlyUITests/AccessibilityUITests.swift:148: error: "
                   "-[SortlyUITests.AccessibilityUITests test1_OnboardingAtLargestTextInDarkMode] : " + self.SERVICE,
                   "an error was recorded")

    def test_failed_test_case_quoting_the_service(self):
        self.check("Test Case '-[SortlyUITests.SortlyFlowUITests test1_FullFlow]' failed (12.0 seconds). " + self.SERVICE,
                   "a test failed")

    def test_crash_signal_quoting_the_service(self):
        self.check("SortlyUITests-Runner encountered an error (Test crashed with signal abrt. " + self.SERVICE + ")",
                   "a test crashed")

    def test_sigterm_before_the_tests_stays_infrastructure(self):
        self.assertEqual(ui_tests.scan(RUNNER_TERMINATED)[0], [])
        self.assertEqual(ui_tests.decide(65, RUNNER_TERMINATED)[0], "retry")


class SelectionTests(unittest.TestCase):
    def test_no_repeat_when_every_named_test_passed(self):
        log = "Test Case '-[SortlyUITests.SortlyFlowUITests test1_FullFlow]' passed (12.0 seconds).\n"
        self.assertIsNone(ui_tests.retry_arguments(["SortlyFlowUITests/test1_FullFlow"], [], log))
        contrast = "AccessibilityUITests/test5_IncreasedContrastAndReducedTransparency"
        self.assertIsNone(ui_tests.retry_arguments([contrast], [contrast], ""))

    def test_repeat_of_a_named_test_that_did_not_pass(self):
        self.assertEqual(ui_tests.retry_arguments(["SortlyFlowUITests/test1_FullFlow"], [], AX_TIMEOUT),
                         ["-only-testing:SortlyUITests/SortlyFlowUITests/test1_FullFlow"])

    def test_retry_skips_the_tests_that_passed(self):
        arguments = ui_tests.retry_arguments(
            ["AccessibilityUITests"], ["AccessibilityUITests/test5_IncreasedContrastAndReducedTransparency"], RESTART)
        self.assertEqual(arguments, [
            "-only-testing:SortlyUITests/AccessibilityUITests",
            "-skip-testing:SortlyUITests/AccessibilityUITests/test5_IncreasedContrastAndReducedTransparency",
            "-skip-testing:SortlyUITests/AccessibilityUITests/test2_EnglishMainScreens",
            "-skip-testing:SortlyUITests/AccessibilityUITests/test3_LargestTextDarkModeReduceMotion",
            "-skip-testing:SortlyUITests/AccessibilityUITests/test4_Landscape",
        ])

    def test_class_and_skip_only_selections_always_start_the_repeat(self):
        # The log cannot tell whether a class holds tests that never started: the repeat runs
        # with the passed tests skipped, and if none is left it runs no test and fails.
        log = "".join(f"Test Case '-[SortlyUITests.AccessibilityUITests test{i}]' passed (1.0 seconds).\n" for i in (1, 2))
        self.assertEqual(ui_tests.retry_arguments(["AccessibilityUITests"], [], log), [
            "-only-testing:SortlyUITests/AccessibilityUITests",
            "-skip-testing:SortlyUITests/AccessibilityUITests/test1",
            "-skip-testing:SortlyUITests/AccessibilityUITests/test2"])
        self.assertEqual(ui_tests.retry_arguments([], ["SortlyFlowUITests/test1_FullFlow"], log)[0],
                         "-skip-testing:SortlyUITests/SortlyFlowUITests/test1_FullFlow")
        self.assertEqual(ui_tests.decide(0, "** TEST SUCCEEDED **\n")[0], "fail")

    def test_retry_of_a_runner_that_never_started_repeats_everything(self):
        self.assertEqual(ui_tests.retry_arguments([], ["AccessibilityUITests", "SortlyFlowUITests/test1_FullFlow"], AX_TIMEOUT),
                         ["-skip-testing:SortlyUITests/AccessibilityUITests",
                          "-skip-testing:SortlyUITests/SortlyFlowUITests/test1_FullFlow"])

    def test_finished_tests(self):
        self.assertEqual(ui_tests.finished_tests(RESTART), {
            "AccessibilityUITests/test2_EnglishMainScreens": "passed",
            "AccessibilityUITests/test3_LargestTextDarkModeReduceMotion": "passed",
            "AccessibilityUITests/test4_Landscape": "passed",
        })

    def test_space_separated_matrix_values(self):
        parsed = []

        def fake_run(a):
            parsed.append((a.only, a.skip))
            return 0
        original = ui_tests.command_run
        ui_tests.command_run = fake_run
        try:
            ui_tests.main(["run", "--udid", "X", "--name", "n", "--only", "A B/c", "--skip", "", "--skip", "D"])
        finally:
            ui_tests.command_run = original
        self.assertEqual(parsed, [(["A", "B/c"], ["D"])])

    def test_restart_context_shows_the_lines_before_the_restart(self):
        context = ui_tests.restart_context(RESTART, before=2)
        self.assertEqual(len(context), 3)
        self.assertIn("Wait for app.albumist.ios to idle", context[1])
        self.assertTrue(context[2].startswith("5:Restarting after"))


class FlakyTests(unittest.TestCase):
    """Every repeat and every test that passed only on it is recorded; nothing is repeated silently."""

    RETRY_LOG = ("Test Case '-[SortlyUITests.AccessibilityUITests test1_OnboardingAtLargestTextInDarkMode]' passed (300.0 seconds).\n"
                 "Test Case '-[SortlyUITests.AccessibilityUITests test2_EnglishMainScreens]' failed (12.0 seconds).\n")

    def test_no_repeat_no_record(self):
        record = ui_tests.flaky_record("flow-full", RESTART, [], None, None)
        self.assertEqual((record["retries"], record["flaky"]), ([], []))
        self.assertEqual(ui_tests.flaky_lines(record), [])

    def test_tests_that_passed_only_on_the_repeat(self):
        record = ui_tests.flaky_record("accessibility", RESTART, ["simulator not booted"], self.RETRY_LOG, "fail")
        self.assertEqual(record["retries"], [{"reasons": ["simulator not booted"], "result": "fail"}])
        self.assertEqual(record["flaky"], [{"test": "AccessibilityUITests/test1_OnboardingAtLargestTextInDarkMode",
                                            "first": "not started", "reason": "simulator not booted"}])
        lines = ui_tests.flaky_lines(record)
        self.assertEqual(lines[0], "FLAKY_RETRY accessibility fail (simulator not booted)")
        self.assertTrue(lines[1].startswith("FLAKY AccessibilityUITests/test1_OnboardingAtLargestTextInDarkMode simulator not booted"))

    def test_a_repeat_that_could_not_start_is_recorded(self):
        record = ui_tests.flaky_record("flow-other", AX_TIMEOUT, ["AX loaded notification timed out"], None,
                                       "not started (simulator did not come back)")
        self.assertEqual(len(record["retries"]), 1)
        self.assertEqual(record["flaky"], [])

    def test_boot_retries_are_recorded(self):
        record = ui_tests.flaky_record("flow-full", "", [], None, None, ["bootstatus failed (attempt 1 of 3)"])
        self.assertEqual(ui_tests.flaky_lines(record), ["FLAKY_BOOT flow-full bootstatus failed (attempt 1 of 3)"])

    def test_run_summary_counts_every_group(self):
        records = [ui_tests.flaky_record("accessibility", RESTART, ["simulator not booted"], self.RETRY_LOG, "fail"),
                   ui_tests.flaky_record("flow-full", RESTART, [], None, None, ["bootstatus failed (attempt 1 of 3)"]),
                   ui_tests.flaky_record("flow-other", "", [], None, None)]
        markdown, lines = ui_tests.flaky_summary(records)
        self.assertIn("1 repeat(s) after a simulator failure, 1 test(s) passed only on the repeat, 1 failed boot attempt(s), "
                      "over 3 pass record(s)", markdown)
        self.assertIn("| accessibility | flaky | AccessibilityUITests/test1_OnboardingAtLargestTextInDarkMode | not started |", markdown)
        self.assertEqual(len(lines), 3)

    def test_summary_command_reads_the_records(self):
        import json
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "flaky-accessibility.json")
            with open(path, "w") as f:
                json.dump(ui_tests.flaky_record("accessibility", RESTART, ["simulator not booted"], self.RETRY_LOG, "pass"), f)
            self.assertEqual(ui_tests.main(["flaky-summary", path, os.path.join(folder, "missing.json")]), 0)


class SweepSkipTests(unittest.TestCase):
    """Rows the tap-through sweep (UI test 3) leaves out appear in the run's UI summary (review 16.11.)."""

    LOG = ("Test Case '-[SortlyUITests.SortlyFlowUITests test3_TapThroughEveryScreen]' started.\n"
           "UI_SWEEP_OK Vorschläge › Reisen 2024 → Reisen 2024\n"
           "UI_SWEEP_SKIP Vorschläge › Länder und Orte (section header or footer text)\n"
           "UI_SWEEP_SKIP Vorschläge row 7 (no label, no text)\n"
           "UI_SWEEP_SKIP Mediathek › Alles rückgängig machen (changes the library)\n"
           "UI_SWEEP_SKIP Vorschläge › Länder und Orte (section header or footer text)\n"
           "UI_SWEEP_SKIP Suchen › Strand › photo (not hittable)\n"
           "/x/SortlyFlowUITests.swift:9: error: -[SortlyUITests.SortlyFlowUITests test3] : UI_SWEEP_SKIP quoted (x)\n")

    def test_skip_lines_are_collected_once_each(self):
        self.assertEqual(ui_tests.sweep_skips(self.LOG), [
            {"where": "Vorschläge › Länder und Orte", "why": "section header or footer text"},
            {"where": "Vorschläge row 7", "why": "no label, no text"},
            {"where": "Mediathek › Alles rückgängig machen", "why": "changes the library"},
            {"where": "Suchen › Strand › photo", "why": "not hittable"},
        ])

    def test_a_label_with_brackets_keeps_its_reason(self):
        skips = ui_tests.sweep_skips("UI_SWEEP_SKIP Alben › Urlaub (Italien) 2024 (section header or footer text)\n")
        self.assertEqual(skips, [{"where": "Alben › Urlaub (Italien) 2024", "why": "section header or footer text"}])

    def test_run_summary_lists_the_skipped_rows(self):
        record = ui_tests.flaky_record("flow-other", self.LOG, [], None, None)
        record["sweep_skips"] = ui_tests.sweep_skips(self.LOG) + [{"where": "Alben › A | B", "why": "section header or footer text"}]
        markdown, lines = ui_tests.flaky_summary([record, ui_tests.flaky_record("flow-full", "", [], None, None)])
        self.assertEqual(lines, [])
        self.assertIn("### UI test 3: rows the tap-through sweep did not tap", markdown)
        self.assertIn("5 row(s) left out", markdown)
        self.assertIn("| flow-other | Vorschläge › Länder und Orte | section header or footer text |", markdown)
        self.assertIn("| flow-other | Alben › A \\| B |", markdown)

    def test_no_section_without_skips(self):
        markdown, _ = ui_tests.flaky_summary([ui_tests.flaky_record("flow-full", "", [], None, None)])
        self.assertNotIn("tap-through sweep", markdown)

    def test_the_group_job_summary_shows_skips_even_without_repeats(self):
        import json
        import tempfile
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as folder:
            summary = os.path.join(folder, "summary.md")
            record = ui_tests.flaky_record("flow-other", self.LOG, [], None, None)
            record["sweep_skips"] = ui_tests.sweep_skips(self.LOG)
            saved = os.environ.get("GITHUB_STEP_SUMMARY")
            os.environ["GITHUB_STEP_SUMMARY"] = summary
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    ui_tests.write_flaky(SimpleNamespace(out=folder, name="flow-other"), record)
            finally:
                if saved is None:
                    os.environ.pop("GITHUB_STEP_SUMMARY")
                else:
                    os.environ["GITHUB_STEP_SUMMARY"] = saved
            with open(summary, encoding="utf-8") as f:
                self.assertIn("Vorschläge › Länder und Orte", f.read())
            with open(os.path.join(folder, "flaky-flow-other.json"), encoding="utf-8") as f:
                self.assertEqual(len(json.load(f)["sweep_skips"]), 4)

    def test_summary_command_prints_the_skips_of_every_group(self):
        import json
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "flaky-flow-other.json")
            record = ui_tests.flaky_record("flow-other", self.LOG, [], None, None)
            record["sweep_skips"] = ui_tests.sweep_skips(self.LOG)
            with open(path, "w", encoding="utf-8") as f:
                json.dump(record, f)
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(ui_tests.main(["flaky-summary", path]), 0)
            self.assertIn("| flow-other | Vorschläge row 7 | no label, no text |", out.getvalue())
            self.assertIn("::notice title=UI sweep::4 row(s)", err.getvalue())


class WatchdogTests(unittest.TestCase):
    """The watchdog stops a pass only before its first test, and only for a simulator that left "Booted"."""

    STARTED_LOG = "Test Case '-[SortlyUITests.AccessibilityUITests test1_OnboardingAtLargestTextInDarkMode]' started.\n"
    STOPPED = ("2026-11-16 15:24:03.524929+0000 SortlyUITests-Runner[6264:25895] [Default] Running tests...\n"
               "UI_WATCHDOG simulator 900A5BAA-B5B5-4706-B7C3-D0C89A4F6B80 left Booted (state Shutdown) before the first test; "
               "pass stopped\n")

    def test_stops_only_after_two_checks_without_booted(self):
        self.assertFalse(ui_tests.watchdog_should_stop("", ["Booted", "Booted"]))
        self.assertFalse(ui_tests.watchdog_should_stop("", ["Shutdown"]))
        self.assertFalse(ui_tests.watchdog_should_stop("", ["Booted", "Shutdown"]))
        self.assertTrue(ui_tests.watchdog_should_stop("", ["Booted", "Shutdown", "Shutdown"]))
        self.assertTrue(ui_tests.watchdog_should_stop("", ["Shutting Down", "Shutdown"]))

    def test_unknown_state_never_stops(self):
        self.assertFalse(ui_tests.watchdog_should_stop("", ["", ""]))
        self.assertFalse(ui_tests.watchdog_should_stop("", ["Shutdown", ""]))

    def test_never_stops_once_a_test_started(self):
        self.assertFalse(ui_tests.watchdog_should_stop(self.STARTED_LOG, ["Shutdown", "Shutdown"]))

    def test_a_stopped_pass_is_repeated(self):
        self.assertEqual(ui_tests.decide(-15, self.STOPPED),
                         ("retry", ["simulator shut down before the tests (watchdog)"]))

    def test_a_quoted_watchdog_line_is_not_infrastructure(self):
        line = "SortlyFlowUITests.swift:60: error: -[SortlyUITests.SortlyFlowUITests test1_FullFlow] : UI_WATCHDOG simulator X left Booted"
        self.assertEqual(ui_tests.is_infra(line), [])

    def test_a_stopped_pass_with_a_real_line_is_not_repeated(self):
        self.assertEqual(ui_tests.decide(-15, self.STOPPED + "A11Y_FAIL en overview | x\n")[0], "fail")

    def test_bundle_of_a_stopped_pass(self):
        self.assertEqual(ui_tests.watchdog_bundle(["result bundle not readable (no such file)"]), [])
        self.assertEqual(ui_tests.watchdog_bundle(["result bundle: Crash: Sortly (4242)"]), ["result bundle: Crash: Sortly (4242)"])
        verdict, _ = ui_tests.decide(-15, self.STOPPED, bundle=ui_tests.watchdog_bundle(["result bundle not readable (x)"]))
        self.assertEqual(verdict, "retry")

    def run_watchdog(self, log_text, states, start_test_at_check=None):
        """start_test_at_check: number of the device_state call (from 1) during which a test starts,
        i.e. its "started" line reaches the log while simctl is being asked."""
        import subprocess
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as log:
            log.write(log_text)
        process = subprocess.Popen(["sleep", "30"])
        answers = iter(states)
        calls = [0]
        original = ui_tests.device_state

        def fake_state(udid):
            calls[0] += 1
            if calls[0] == start_test_at_check:
                with open(log.name, "a") as started:
                    started.write(self.STARTED_LOG)
            return next(answers, states[-1])
        ui_tests.device_state = fake_state
        try:
            dog = ui_tests.Watchdog("U", log.name, process, interval=0.05)
            dog.start()
            dog.join(timeout=5)
            if dog.is_alive():
                dog.stop()
                dog.join(timeout=5)
            stopped = process.poll() is not None
        finally:
            ui_tests.device_state = original
            if process.poll() is None:
                process.kill()
            process.wait()
            os.remove(log.name)
        return dog.fired, stopped

    def test_watchdog_thread_stops_the_process(self):
        self.assertEqual(self.run_watchdog("", ["Booted", "Shutdown", "Shutdown"]), ("Shutdown", True))

    def test_watchdog_thread_leaves_a_started_pass_alone(self):
        self.assertEqual(self.run_watchdog(self.STARTED_LOG, ["Shutdown", "Shutdown"]), ("", False))

    def test_a_test_started_during_the_state_check_is_not_stopped(self):
        # Review 16.11. (probe.py): the log was read before device_state (up to 30 s), so a test
        # that started during the second check was still stopped. The log is read again first.
        self.assertEqual(self.run_watchdog("", ["Shutdown", "Shutdown"], start_test_at_check=2), ("", False))
        self.assertEqual(self.run_watchdog("", ["Booted", "Shutdown", "Shutdown"], start_test_at_check=3),
                         ("", False))


class GroupTests(unittest.TestCase):
    """The UI groups of ui.yml: every test runs in exactly one group (no test twice, none lost)."""

    ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")

    def workflow(self):
        return open(os.path.join(self.ROOT, ".github", "workflows", "ui.yml"), encoding="utf-8").read()

    def groups(self):
        """{group: {field: value}} of .github/ui-groups.json (ui.yml's matrix comes from it, see
        ui_groups.py), in order; booleans as GitHub hands them to the job ("true")."""
        with open(os.path.join(self.ROOT, ".github", "ui-groups.json"), encoding="utf-8") as f:
            listed = json.load(f)["groups"]
        return {g["group"]: {k: ("true" if v is True else v) for k, v in g.items() if v is not False and k != "group"}
                for g in listed}

    def ui_tests(self):
        """Every test method of the SortlyUITests target, as "Class/test"."""
        import glob
        import re
        tests = []
        for path in sorted(glob.glob(os.path.join(self.ROOT, "App", "SortlyUITests", "*.swift"))):
            current = None
            for line in open(path, encoding="utf-8"):
                cls = re.match(r"\s*(?:@\w+\s+)*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase", line)
                if cls:
                    current = cls.group(1)
                test = re.match(r"\s*(?:@\w+\s+)*func\s+(test\w*)\s*\(\s*\)", line)
                if test and current:
                    tests.append(f"{current}/{test.group(1)}")
        return tests

    @staticmethod
    def selected(test, only, skip):
        """Whether xcodebuild runs `test` with -only-testing `only` and -skip-testing `skip`."""
        def hits(entries):
            return any(test == e or test.startswith(e + "/") for e in entries)
        return (not only or hits(only)) and not hits(skip)

    def test_five_groups_and_the_contrast_job(self):
        groups = self.groups()
        self.assertEqual(set(groups), {"device", "flow-full", "flow-other", "accessibility", "contrast"})
        test5 = "AccessibilityUITests/test5_IncreasedContrastAndReducedTransparency"
        self.assertEqual(groups["contrast"]["only"], test5)
        self.assertEqual(groups["contrast"]["increase_contrast"], "true")
        self.assertEqual(groups["contrast"]["reduce_motion"], "true")
        self.assertEqual(groups["contrast"]["device"], "se")
        self.assertEqual(groups["accessibility"]["skip"], test5)
        self.assertNotIn("increase_contrast", groups["accessibility"])
        self.assertEqual(groups["device"]["device"], "pro")
        self.assertNotIn("reduce_motion", groups["device"])

    def test_at_most_four_groups_at_a_time(self):
        # With CI's one macOS job, five macOS jobs at the peak; contrast (the shortest) waits.
        import re
        self.assertRegex(self.workflow(), r"\n      max-parallel: 4\n")
        self.assertEqual(list(self.groups())[-1], "contrast")

    def test_other_flows_skip_exactly_what_the_others_run(self):
        groups = self.groups()
        others = set()
        for name in ("device", "flow-full", "accessibility", "contrast"):
            others |= set(groups[name]["only"].split())
        covered = {t for t in others if not any(t != o and t.startswith(o + "/") for o in others)}
        self.assertEqual(set(groups["flow-other"]["skip"].split()), covered)
        self.assertEqual(groups["flow-other"]["only"], "")

    def test_every_ui_test_runs_in_exactly_one_group(self):
        groups = self.groups()
        tests = self.ui_tests()
        self.assertGreater(len(tests), 20)
        self.assertTrue(any(t.startswith("DeviceConditionUITests/") for t in tests))
        classes = {t.split("/")[0] for t in tests}
        for name, fields in groups.items():
            for entry in fields["only"].split() + fields["skip"].split():
                with self.subTest(group=name, entry=entry):
                    # A renamed test would otherwise select nothing (or skip nothing) silently.
                    self.assertIn(entry, tests if "/" in entry else classes)
        for test in tests:
            with self.subTest(test=test):
                runs = [name for name, f in groups.items() if self.selected(test, f["only"].split(), f["skip"].split())]
                self.assertEqual(len(runs), 1, f"{test} runs in {runs or 'no group'}")

    def test_the_stress_run_is_not_part_of_the_ui_run(self):
        # DeviceConditionUITests/test12 skips itself without SORTLY_STRESS_PHOTOS; only
        # ui-stress.yml (by hand, weekly and in every TestFlight run) sets it.
        self.assertNotIn("SORTLY_STRESS_PHOTOS", self.workflow())
        stress = open(os.path.join(self.ROOT, ".github", "workflows", "ui-stress.yml"), encoding="utf-8").read()
        self.assertIn("TEST_RUNNER_SORTLY_STRESS_PHOTOS", stress)
        self.assertNotIn("pull_request", stress)
        self.assertNotIn("push:", stress)
        self.assertIn("toolchain.py xcode --runtime", stress)
        self.assertIn("pick_simulator.py --role pro", stress)


class HostGrantTests(unittest.TestCase):
    """A test that reset the photo access asks the Mac to give it back (UI_HOST_GRANT_PHOTOS)."""

    def test_requests_are_counted_per_line(self):
        log = "x\nUI_HOST_GRANT_PHOTOS\nTest Case '-[SortlyUITests.DeviceConditionUITests test09]' started.\nUI_HOST_GRANT_PHOTOS\n"
        self.assertEqual(ui_tests.host_grant_requests(log), 2)

    def test_the_answer_is_not_a_request(self):
        self.assertEqual(ui_tests.host_grant_requests("UI_HOST photo access granted\nUI_HOST_GRANT_PHOTOS_X\n"), 0)

    def test_the_watcher_grants_once_per_request(self):
        granted = []
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "log.txt")
            with open(path, "w") as log:
                log.write("UI_HOST_GRANT_PHOTOS\nhalf a li")
            grants = ui_tests.HostGrants("U", path, interval=0.01, grant=lambda: granted.append(1))
            grants.check()
            with open(path, "a") as log:
                log.write("ne\nUI_HOST_GRANT_PHOTOS\n")
            grants.check()
            grants.check()
        self.assertEqual(len(granted), 2)


# Device test 04 of UI run 44066730498: XCTest lost the app at a relaunch (no crash report).
LOST_APP_LOG = """Test Case '-[SortlyUITests.DeviceConditionUITests test04_UnreadableICloudOfflineComplete]' started.
UI_FACT app process 30001 started 11:03:22.5 UTC, its code ran from 11:03:23.4 UTC
UI_FACT atlas offline Dein Reise-Atlas, 12 Länder · 0 Städte · 12 Reisen
UI_FACT clock 11:06:36.3 launch
<unknown>:0: error: -[SortlyUITests.DeviceConditionUITests test04_UnreadableICloudOfflineComplete] : Application 'app.albumist.ios' does not have a process ID
{record}UI_FACT main stall 2.6 s from 11:07:36.6 UTC
Test Case '-[SortlyUITests.DeviceConditionUITests test04_UnreadableICloudOfflineComplete]' failed (372.873 seconds).
Test Case '-[SortlyUITests.DeviceConditionUITests test06_DiskFullDuringAnalysisAndPlan]' started.
UI_FACT app process 30003 started 11:09:36.0 UTC, its code ran from 11:09:37.0 UTC
Test Case '-[SortlyUITests.DeviceConditionUITests test06_DiskFullDuringAnalysisAndPlan]' passed (60.000 seconds).
** TEST EXECUTE FAILED **
"""


class LostAppTests(unittest.TestCase):
    def log(self, record=""):
        return LOST_APP_LOG.replace("{record}", record)

    def test_a_late_process_start_points_at_the_simulator_and_stays_red(self):
        log = self.log("UI_FACT app process 30002 started 11:07:35.1 UTC, its code ran from 11:07:36.0 UTC\n")
        verdict, reasons = ui_tests.decide(65, log)
        self.assertEqual(verdict, "fail")
        self.assertIn("XCTest lost the app at a launch: no crash report, the simulator started the app process 59 s "
                      "after the launch request (simulator/XCTest side)", reasons)

    def test_a_prompt_process_start_points_at_the_app(self):
        log = self.log("UI_FACT app process 30002 started 11:06:38.0 UTC, its code ran from 11:07:36.0 UTC\n")
        self.assertEqual(ui_tests.lost_app_at_launch(log),
                         ["XCTest lost the app at a launch: the app process started after 2 s but did not come up (app side)"])

    def test_a_crash_report_points_at_the_app(self):
        log = self.log("UI_FACT app process 30002 started 11:07:35.1 UTC, its code ran from 11:07:36.0 UTC\n")
        self.assertEqual(ui_tests.lost_app_at_launch(log, ["/x/Sortly-2026-11-17-110700.ips"]),
                         ["XCTest lost the app at a launch, and a crash report was written (app side)"])

    def test_without_a_record_the_cause_stays_open(self):
        # The record of the earlier process (before the launch) and of the next test do not count.
        self.assertEqual(ui_tests.lost_app_at_launch(self.log()),
                         ["XCTest lost the app at a launch: no crash report, no launch record of a new app process (cause open)"])

    def test_nothing_lost_says_nothing(self):
        self.assertEqual(ui_tests.lost_app_at_launch("Test Case '-[A.B test01]' passed (1.0 seconds).\n"), [])


class GrantPhotosTests(unittest.TestCase):
    def run_grant(self, codes):
        calls = []

        def fake(command, timeout, quiet):
            calls.append((command, timeout))
            code = codes[len(calls) - 1]
            return code, "" if code == 0 else "timed out after 90 s: xcrun simctl privacy"

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            granted = ui_tests.grant_photos("U", run=fake)
        return granted, calls, out.getvalue()

    def test_a_working_grant_is_one_call(self):
        granted, calls, out = self.run_grant([0])
        self.assertTrue(granted)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], ["xcrun", "simctl", "privacy", "U", "grant", "photos", ui_tests.BUNDLE_ID])
        self.assertIn("UI_HOST photo access granted", out)

    def test_a_hung_grant_is_tried_once_more_and_said(self):
        granted, calls, out = self.run_grant([124, 0])
        self.assertTrue(granted)
        self.assertEqual(len(calls), 2)
        self.assertIn("UI_HOST photo access grant failed (exit 124", out)
        self.assertIn("attempt 2 of 2", out)

    def test_two_failures_are_said_and_not_hidden(self):
        granted, calls, out = self.run_grant([124, 1])
        self.assertFalse(granted)
        self.assertEqual(len(calls), 2)
        self.assertIn("UI_HOST photo access NOT granted after 2 attempts", out)


if __name__ == "__main__":
    unittest.main()
