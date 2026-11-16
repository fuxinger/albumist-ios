"""Unit tests for the retry rule of .github/scripts/ui_tests.py (runs on Linux, no simulator).

The log snippets are cut from real UI runs of November 2026 (job ids in the comments).
Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import os
import sys
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


if __name__ == "__main__":
    unittest.main()
