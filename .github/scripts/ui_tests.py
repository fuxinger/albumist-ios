"""Runs one group of UI tests on its own simulator, and repeats only what the simulator lost.

Every UI job (ui.yml) uses this script, so all of them treat a failure the same way:

  pick  --device pro|se
      Prints the UDID of the simulator for the job, both pinned in .github/toolchain.json: the
      image's iPhone Pro ("pro", the screenshots of the UI flow) or a newly created iPhone SE
      ("se", the small iPhone of the accessibility tests), on the pinned runtime. No fallback.
  boot  --udid U [--reduce-motion] [--ready-file F]
      Boots the simulator (three attempts: CoreSimulator on the hosted Macs sometimes aborts
      the first bootstatus), grants photo access, fixes the status bar and writes the
      accessibility settings. With --ready-file it writes "ok" or "failed" there at the end,
      so the boot can run in the background while the build products are downloaded.
  run   --udid U --name N (--xctestrun F | --project P --scheme S) [--only T]... [--skip T]...
        [--reduce-motion] [--increase-contrast] [--video F] [--out DIR] [--deadline EPOCH]
      Runs the tests (T is "Class" or "Class/testMethod" of SortlyUITests), prints the
      report lines for the log (steps, screenshots, accessibility findings, restart context,
      crash reports, SwiftUI runtime warnings), a last line "UI_RESULT NAME pass|fail|infra"
      (ui_evidence.py reads it) and exits with the result: 0, 1, or 75 when every pass failed
      on the simulator or XCTest alone (no test result; it writes DIR/no-test-result, and
      ui.yml fails the job in "No test result (simulator or XCTest failed in every pass)",
      which ui_evidence.py counts as no result rather than red). A test that reset
      the photo access (the CI simulator then answers "denied" without asking) prints
      UI_HOST_GRANT_PHOTOS; the access is given back from the Mac (`simctl privacy grant`)
      while the pass runs (class HostGrants).
  classify LOG [--status N] [--crash-report F]... [--bundle-json F]
      Prints what `run` would decide for a finished pass (for trying the rules on a log;
      without --bundle-json the result bundle counts as clean).

The retry rule (`decide`): a pass that failed is repeated ONCE, on a simulator that is shut
down, ERASED (app, photos, the runner's marker files) and booted and prepared again like a
new one, and only for the tests that did not pass (-only-testing as before, plus
-skip-testing for every test that passed), when all of these hold:
  - the log (or a simctl call right after the pass) shows an explicit failure of the
    simulator service or of the test runner before it ran a test: "Error returned in reply
    from CoreSimulatorService", "CoreSimulatorService: Connection interrupted", "Timed out
    waiting for AX loaded notification", "failed to initialize for UI testing", "Failed to
    install or launch the test runner", "Failed to establish communication with the test
    runner", "device is not booted", a runner stopped with SIGTERM before its first test.
    "Restarting after unexpected exit, crash, or test timeout" alone is NOT enough: it is
    also what an app hang or crash looks like;
  - no log line points at the app or the tests: no failed test case or suite, no ": error:"
    line (other than the infrastructure lines above; but a test's own ": error: -[...]", a
    "Test Case ... failed" or a crash other than SIGTERM counts even when it quotes one), no
    recorded issue, no A11Y_FAIL, no "Fatal error", "Crash:", "crashed", "Test crashed with signal ..." (other than the SIGTERM
    above) or "execution time allowance";
  - no crash report of the app or the test runner (~/Library/Logs/DiagnosticReports/Sortly*)
    was written during the pass;
  - the result bundle agrees: no test case failed with a message other than the
    infrastructure ones above, no issue outside a test, and it can be read at all (a JSON
    object with a list "testNodes").
A crash of XCTest's daemon testmanagerd during a test ("Critical process testmanagerd crashed",
the app lost with it; `daemon_crash`) also counts as such a failure: the failure lines it caused
are taken out, anything else still counts, and the tests that did not pass are repeated. That
goes beyond "a simulator failure before the first test": a test that had already started is
run again (decision of 18.11.2026, for the owner to confirm; docs/TESTFLIGHT.md). It is counted
(FLAKY_RETRY with the reason, also "app lost + daemon crash in <test>" when the app was lost in
that test without a crash report), and if the daemon crashes again in the same test in the
repeat, the group is red (likely app-caused, e.g. a huge accessibility tree).
A pass still running at --deadline (the job's time limit minus a margin, ui.yml) is stopped:
with a test still running a hang, red, never repeated (UI_HANG); with none running (between
tests, before the first) a deadline line that counts as infrastructure (UI_DEADLINE). A repeat
is not started with less than 30 min left (10 min after the erase): then no result. While a pass runs, failed test cases and ": error: -["
lines are echoed into the job log at once (UI_LIVE), so a cancel after a failure stays red.
Before every pass (first and repeat) `settle` waits up to 5 min for the Mac's load after the
simulator's boot (SIM_SETTLE, SIM_TOP), never into the 10 min a repeat keeps; then the pass
starts anyway. No test is repeated for it.
A watchdog (class Watchdog) stops a pass early when the simulator leaves "Booted" before
the first test started (two checks 20 s apart); the UI_WATCHDOG line it leaves in the log is
one of the infrastructure failures above, and the stop counts as FLAKY_BOOT. It never stops a
pass in which a test has started (the log is read again right before the stop, so a test that
started while simctl was being asked counts too).
Anything else is never repeated: a real failure stays red. That includes XCTest losing the
app at a launch ("Application ... does not have a process ID", device test 04 of UI run
44066730498): it is never repeated, but the verdict says which side it points at
(`lost_app_at_launch`), from the crash reports and the app's own launch record (the device
tests print "UI_FACT app process P started T UTC" from the file the app writes at launch):
a crash report means the app crashed; a process that started 30 s or more after the test's
"UI_FACT clock T launch" means the simulator began the launch late (simulator/XCTest side);
a process that started at once means the app itself did not come up in time (app side);
without a record of a new process the cause stays open. A pass that ran no test at all
fails (a renamed test would otherwise make an empty, green selection), and a repeat whose
selection would be empty is not started (only possible when every --only entry is a single
test; a class or skip-only selection always starts the repeat, see `retry_arguments`). Both passes keep their own log and result bundle
(NAME.xcresult, NAME-retry.xcresult); the screenshots of the tests that passed in the first
pass are printed from its log.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time

TARGET = "SortlyUITests"
BUNDLE_ID = "app.albumist.ios"

# Lines of the xcodebuild log that go into the job log. PREVIEW_JPEG lines carry the
# screenshots (the gallery is built from them), A11Y_ lines the accessibility findings.
REPORT = re.compile(r"error:|UI_STEP|UI_SWEEP|UI_TIMING|UI_FACT|UI_HOST|UI_STRESS|UI_FLAKY|A11Y_|PREVIEW_JPEG|Test Case|Executed|\*\* |"
                    r"Testing failed|Fatal error|crashed|Restarting after|unexpected exit|encountered an error")
REPORT_LIMIT = 15000

# Explicit failures of the simulator service or of the test runner before its first test
# (seen on the hosted Macs, Nov 2026). Matched per line.
INFRA = [
    (re.compile(r"Error returned in reply from CoreSimulatorService|CoreSimulatorService: Connection (?:interrupted|invalid)"),
     "CoreSimulatorService connection lost"),
    (re.compile(r"Timed out waiting for AX loaded notification"), "AX loaded notification timed out"),
    (re.compile(r"failed to initialize for UI testing", re.I), "test runner failed to initialize"),
    (re.compile(r"Failed to install or launch the test runner"), "test runner not installed or launched"),
    (re.compile(r"Failed to establish communication with the test runner"), "no connection to the test runner"),
    (re.compile(r"Test runner exited before starting test execution"), "test runner exited before the tests"),
    (re.compile(r"test runner hung before establishing connection", re.I), "test runner hung before connecting"),
    (re.compile(r"\bdevice is not booted\b"), "simulator not booted"),
    # SIGTERM to a runner that had not started a test yet (the simulator was going away).
    (re.compile(r"Test crashed with signal term (?:before establishing connection|while preparing to run tests)"),
     "test runner stopped before the tests"),
    # Written by this script's watchdog (run_pass): the simulator left "Booted" before the first
    # test started, so the pass was stopped instead of waiting for xcodebuild to notice.
    (re.compile(r"^UI_WATCHDOG simulator \S+ left Booted"), "simulator shut down before the tests (watchdog)"),
    # Written by run_pass: the deadline came while no test was running (between tests, before
    # the first one, xcodebuild winding up): the time ran out, not a test.
    (re.compile(r"^UI_DEADLINE\b"), "pass stopped at the job's deadline with no test running"),
]

# Anything here is about the app or the tests: never repeated. Matched per line, on lines
# that are not one of the infrastructure lines above.
REAL = [
    (re.compile(r"Test [Cc]ase '.*' failed"), "a test failed"),
    (re.compile(r"Test Suite '.*' failed"), "a test suite failed"),
    (re.compile(r": error:"), "an error was recorded"),
    (re.compile(r"recorded an issue"), "an issue was recorded"),
    (re.compile(r"with [1-9]\d* failures?\b"), "failures counted"),
    (re.compile(r"\bA11Y_FAIL\b"), "accessibility finding"),
    (re.compile(r"Fatal error"), "Swift runtime error (Fatal error)"),
    (re.compile(r"Test crashed with signal"), "a test crashed"),
    (re.compile(r"\bCrash:"), "a crash"),
    (re.compile(r"\bcrashed\b", re.I), "something crashed"),
    (re.compile(r"execution time allowance"), "a test ran out of time"),
    # Written by run_pass when a test was still running at the job's deadline (--deadline): a
    # hang is a finding (the app or a test never got done), never repeated.
    (re.compile(r"^UI_HANG\b"), "hang: the pass did not end before the job's deadline"),
    (re.compile(r"\*\* (?:TEST )?BUILD FAILED \*\*"), "build failed"),
]

# A test's own failure, even on a line that also quotes one of the infrastructure messages
# (an assertion whose text contains a CoreSimulatorService error is still an assertion).
STRONG_REAL = [
    (re.compile(r": error: -\["), "an error was recorded"),
    (re.compile(r"Test [Cc]ase .* failed"), "a test failed"),
    (re.compile(r"Test crashed with signal (?!term)"), "a test crashed"),
]

# XCTest's daemon testmanagerd crashed (UI run 44202318875 attempt 2, job 134494213854: SIGSEGV
# in com.apple.testmanagerd, responsible process SimulatorTrampoline). The test that was running
# then fails with "Lost connection to the application" and "Critical process testmanagerd
# crashed", and the runner restarts. That is the simulator's XCTest side, not the app: those
# lines, that test's "failed" line and the failure counts are taken out before the log is
# judged (daemon_crash); anything else that failed still counts, and so does a crash report of
# the app. The tests that did not pass run once more like after a simulator failure.
DAEMON_CRASH = re.compile(r"Critical process testmanagerd crashed")
# A testmanagerd crash in a test whose app was lost too, with no app crash report: still repeated,
# but named in the reasons (and so in the flaky record) as "app lost + daemon crash".
APP_LOST = re.compile(r"Lost connection to the application|does not have a process ID|is not running")
DAEMON_LOST = re.compile(r"Critical process testmanagerd crashed|Lost connection to the application"
                         r"|Couldn.t communicate with a helper application")
ERROR_OF = re.compile(r": error: -\[\w+\.(\w+) (\w+)\] : ")
FAILED_CASE = re.compile(r"Test [Cc]ase '-\[\w+\.(\w+) (\w+)\]' failed")
AGGREGATE = re.compile(r"Test Suite '.*' failed|with [1-9]\d* failures?\b")

# Echoed into the job log while a pass runs (HostGrants.check).
LIVE = re.compile(r"Test [Cc]ase '.*' failed|: error: -\[")

# Lines that carry data, not messages (base64 screenshots and video).
DATA_LINE = re.compile(r"PREVIEW_JPEG|UI_VIDEO_B64")

CASE = re.compile(r"Test Case '-\[(?:[\w]+)\.(\w+) (\w+)\]' (passed|failed|skipped)")
STARTED = re.compile(r"Test Case '-\[\w+\.\w+ \w+\]' started")
# Written by `run` when every pass failed on the simulator or XCTest alone, so the group has no
# test result (exit NO_TEST_EXIT): the workflow fails the job in a step of its own, and
# ui_evidence.py counts it neither green nor red.
NO_TEST_RESULT = "no-test-result"
# A repeat needs an erase and boot (up to ~25 min seen) and its tests: not started with less than
# this left before --deadline, nor after an erase that left less than RETRY_AFTER_RESET. The
# group then has no result (exit NO_TEST_EXIT) instead of a repeat cut off as a hang.
RETRY_BEFORE_RESET = 30 * 60
RETRY_AFTER_RESET = 10 * 60
NO_TEST_EXIT = 75
PASSED = ("Passed", "Skipped", "Expected Failure")


# ---------------------------------------------------------------------------------------------
# The decision (pure functions; unit tests in tests/test_ui_tests.py)


def finished_tests(log: str) -> dict[str, str]:
    """{"Class/test": "passed" | "failed" | "skipped"} from the XCTest lines of a log."""
    result: dict[str, str] = {}
    for cls, test, state in CASE.findall(log):
        name = f"{cls}/{test}"
        if result.get(name) != "failed":
            result[name] = state
    return result


def is_infra(line: str) -> list[str]:
    return [reason for pattern, reason in INFRA if pattern.search(line)]


def strong_real(line: str) -> list[str]:
    """Reasons from STRONG_REAL: these count even on a line that is also an infrastructure line."""
    return [reason for pattern, reason in STRONG_REAL if pattern.search(line)]


def scan(text: str) -> tuple[list[str], list[str]]:
    """(real reasons, infrastructure reasons) found in a log, line by line."""
    real: list[str] = []
    infra: list[str] = []
    for line in text.splitlines():
        if DATA_LINE.search(line):
            continue
        real += [reason for reason in strong_real(line) if reason not in real]
        found = is_infra(line)
        if found:
            infra += [r for r in found if r not in infra]
            continue
        real += [reason for pattern, reason in REAL if pattern.search(line) and reason not in real]
    return real, infra


def bundle_findings(tests: dict) -> list[str]:
    """Problems in `xcresulttool get test-results tests` output that are not the simulator's:
    any failure message that is not an infrastructure line (or that is one but also names a
    test's own failure, STRONG_REAL), and any test case that did not pass without saying why.
    Tests that never started are not in the bundle."""
    findings: list[str] = []

    def children(node: dict) -> list[dict]:
        found = node.get("children") or []
        return [child for child in found if isinstance(child, dict)] if isinstance(found, list) else []

    def messages(node: dict) -> list[str]:
        found = []
        for child in children(node):
            if child.get("nodeType") == "Failure Message":
                found.append(child.get("name", ""))
            found += messages(child)
        return found

    def walk(node: dict) -> None:
        kind = node.get("nodeType")
        if kind == "Failure Message":
            text = node.get("name", "")
            if strong_real(text) or not is_infra(text):
                findings.append(f"result bundle: {text[:200]}")
        if kind == "Test Case" and node.get("result") not in PASSED and not messages(node):
            findings.append(f"result bundle: {node.get('name', '?')} {node.get('result', 'no result')} without a message")
        for child in children(node):
            walk(child)

    for node in children({"children": tests.get("testNodes")}):
        walk(node)
    return findings


LOST_APP = re.compile(r"does not have a process ID")
LAUNCH_CLOCK = re.compile(r"UI_FACT clock (\d\d):(\d\d):(\d\d(?:\.\d)?) launch\b")
APP_PROCESS = re.compile(r"UI_FACT app process (\d+) started (\d\d):(\d\d):(\d\d(?:\.\d)?) UTC")
LATE_START = 30.0


def lost_app_at_launch(log: str, crash_reports: list[str] | None = None) -> list[str]:
    """Which side a lost app at a launch points at (see the module text); [] when none was lost.

    Always a reason for "fail" (it is added to the real reasons, never repeated)."""
    def seconds(match: re.Match, first: int) -> float:
        return int(match.group(first)) * 3600 + int(match.group(first + 1)) * 60 + float(match.group(first + 2))

    lines = [line for line in log.splitlines() if not DATA_LINE.search(line)]
    reasons: list[str] = []
    for index, line in enumerate(lines):
        if not (LOST_APP.search(line) and strong_real(line)):
            continue
        launch = None
        for earlier in reversed(lines[:index]):
            if STARTED.search(earlier):
                break
            launch = launch or LAUNCH_CLOCK.search(earlier)
        process = None
        for later in lines[index + 1:]:
            if STARTED.search(later):
                break
            process = process or APP_PROCESS.search(later)
        if crash_reports:
            reason = "XCTest lost the app at a launch, and a crash report was written (app side)"
        elif launch and process:
            late = (seconds(process, 2) - seconds(launch, 1)) % 86_400
            if late >= LATE_START:
                reason = (f"XCTest lost the app at a launch: no crash report, the simulator started the app "
                          f"process {late:.0f} s after the launch request (simulator/XCTest side)")
            else:
                reason = (f"XCTest lost the app at a launch: the app process started after {late:.0f} s "
                          f"but did not come up (app side)")
        else:
            reason = "XCTest lost the app at a launch: no crash report, no launch record of a new app process (cause open)"
        if reason not in reasons:
            reasons.append(reason)
    return reasons


def daemon_crash_tests(log: str) -> set[tuple[str, str]]:
    """(class, test) of each test in which testmanagerd crashed."""
    hit = set()
    for line in log.splitlines():
        match = ERROR_OF.search(line)
        if match and DAEMON_CRASH.search(line):
            hit.add(match.groups())
    return hit


def daemon_crash(log: str, bundle: list[str]) -> tuple[str, list[str], list[str]]:
    """(log, bundle findings, reasons) with the failure that a crash of testmanagerd caused taken
    out (see DAEMON_CRASH); unchanged and [] when it did not crash."""
    lines = log.splitlines()
    if not any(DAEMON_CRASH.search(line) for line in lines):
        return log, bundle, []
    hit = daemon_crash_tests(log)
    lost = sorted({e.groups() for line in lines if (e := ERROR_OF.search(line)) and e.groups() in hit
                   and APP_LOST.search(line)})
    reasons = ["XCTest daemon testmanagerd crashed"]
    if lost:
        reasons.append("app lost + daemon crash in " + ", ".join(f"{c}/{t}" for c, t in lost)
                       + " (no app crash report)")
    kept = []
    for line in lines:
        error, failed = ERROR_OF.search(line), FAILED_CASE.search(line)
        if DAEMON_CRASH.search(line) or AGGREGATE.search(line):
            continue  # the counts sum up the "failed" lines; another failure has its own line
        if error and error.groups() in hit and DAEMON_LOST.search(line):
            continue
        if failed and failed.groups() in hit:
            continue
        kept.append(line)
    return "\n".join(kept), [b for b in bundle if not DAEMON_LOST.search(b)], reasons


def decide(status: int, log: str, crash_reports: list[str] | None = None, probe: str = "",
           bundle: list[str] | None = None) -> tuple[str, list[str]]:
    """("pass" | "retry" | "fail", reasons) for one finished pass.

    status: exit code of xcodebuild; log: its whole output; crash_reports: paths of Sortly*
    reports written during the pass; probe: output of a simctl call made right after the pass
    (says whether the simulator is still there); bundle: `bundle_findings` of the pass's
    result bundle (or the reason it could not be read). Both the log and the bundle must
    show nothing about the app before a pass is repeated.
    """
    ran = finished_tests(log)
    if status == 0:
        if not ran:
            return "fail", ["no test ran (a renamed test, or a selection that matches nothing)"]
        return "pass", []
    log, bundle, daemon = daemon_crash(log, list(bundle or []))
    real, infra = scan(log)
    infra[:0] = daemon
    real += [reason for reason in lost_app_at_launch(log, crash_reports) if reason not in real]
    if crash_reports:
        real.append("crash report " + ", ".join(os.path.basename(p) for p in crash_reports))
    real += list(bundle or [])
    if real:
        return "fail", real
    for line in probe.splitlines():
        infra += [r for r in is_infra(line) if r not in infra]
    if infra:
        return "retry", infra
    return "fail", ["no explicit simulator failure (unknown cause; a runner restart alone is not repeated)"]


def retry_arguments(only: list[str], skip: list[str], log: str) -> list[str] | None:
    """xcodebuild selection for the repeat: the same tests minus every test that passed or
    was skipped in the first pass.

    None (no repeat) only when every --only entry is a single test ("Class/test") that passed,
    was skipped or is in --skip: then there is nothing left to name. In every other case a
    selection is returned, also when nothing may be left to run: with a class in --only
    ("AccessibilityUITests") or with no --only at all (the flow-other group selects by
    --skip only) the script cannot tell from the log whether the class or target holds tests
    that never started, so the repeat starts with the passed tests skipped. If none is left,
    that repeat runs no test and `decide` fails it ("no test ran"): the group stays red."""
    done = [name for name, state in finished_tests(log).items() if state in ("passed", "skipped")]
    if only and all("/" in t and (t in done or t in skip) for t in only):
        return None
    return selection(only, skip + [name for name in done if name not in skip])


def selection(only: list[str], skip: list[str]) -> list[str]:
    return [f"-only-testing:{TARGET}/{t}" for t in only] + [f"-skip-testing:{TARGET}/{t}" for t in skip]


def restart_context(log: str, before: int = 60, limit: int = 400) -> list[str]:
    """What XCTest logged before each "Restarting after" (a runner that ended inside a test
    leaves no "passed"/"failed" line; this says where and why)."""
    lines = log.splitlines()
    picked: list[int] = []
    for index, line in enumerate(lines):
        if "Restarting after" in line:
            picked += [i for i in range(max(0, index - before), index + 1) if i not in picked]
    out = [f"{i + 1}:{lines[i][:300]}" for i in sorted(picked) if "PREVIEW_JPEG" not in lines[i]]
    return out[:limit]


# ---------------------------------------------------------------------------------------------
# Simulator


def watchdog_should_stop(log: str, states: list[str]) -> bool:
    """True when a pass is to be stopped: no test has started yet and the last two checks of the
    simulator (20 s apart) both found it known and not "Booted". A pass in which any test
    started is never stopped: whatever happens then is for the tests and `decide` to judge."""
    if STARTED.search(log):
        return False
    last = states[-2:]
    return len(last) == 2 and all(state and state != "Booted" for state in last)


def watchdog_bundle(findings: list[str]) -> list[str]:
    """Result bundle findings of a pass the watchdog stopped before any test, or that was stopped
    at the job's deadline (UI_HANG stays a finding from the log): a bundle that
    xcodebuild could not finish is expected then and is no finding; anything it does say still
    counts (and blocks the repeat)."""
    return [f for f in findings if not f.startswith("result bundle not readable")]


def flaky_record(name: str, first_log: str, retry_reasons: list[str], retry_log: str | None,
                 retry_result: str | None, boot_retries: list[str] | None = None) -> dict:
    """What a group's run says about flakiness, for build/flaky-NAME.json and the FLAKY lines.

    retries: every repeat after a simulator failure (also one that failed, and one that could
    not start); flaky: every test that passed only in that repeat, with the reason and what
    the first pass made of it ("failed" or "not started"), and every test that retried a step
    inside itself (its UI_FLAKY_RETRY line, first: INSIDE); boot: failed boot attempts."""
    record = {"group": name, "boot": list(boot_retries or []), "retries": [], "flaky": []}
    for test, why in dict.fromkeys(INSIDE_RETRY.findall(first_log + "\n" + (retry_log or ""))):
        record["flaky"].append({"test": test, "first": INSIDE, "reason": why})
    if retry_result is None and not retry_reasons:
        return record
    record["retries"].append({"reasons": retry_reasons, "result": retry_result or "not started"})
    first = finished_tests(first_log)
    for test, state in finished_tests(retry_log or "").items():
        if state == "passed":
            record["flaky"].append({"test": test, "first": first.get(test, "not started"),
                                    "reason": "; ".join(retry_reasons)})
    return record


# A UI test that retries a step inside itself prints "UI_FLAKY_RETRY <Class.test> <reason>"
# (DeviceConditionUITests test07). Counted and shown like a test that passed only on a repeat
# (flaky-*.json, FLAKY line, job and run summary, the flaky warning the TestFlight gate repeats
# for reused results); it does not block, like the other flaky tests: the rule is to count and
# fix them, and a test that still fails after its own retry is red anyway.
INSIDE_RETRY = re.compile(r"\bUI_FLAKY_RETRY (\S+) (.+?)\s*$", re.M)
INSIDE = "retried inside the test"


def flaky_lines(record: dict) -> list[str]:
    lines = [f"FLAKY_BOOT {record['group']} {reason}" for reason in record.get("boot", [])]
    lines += [f"FLAKY_RETRY {record['group']} {r['result']} ({'; '.join(r['reasons'])})" for r in record.get("retries", [])]
    lines += [f"FLAKY {f['test']} {f['reason']} " + (f"({INSIDE})" if f["first"] == INSIDE else
                                                     f"(first pass: {f['first']}; passed on the repeat)")
              for f in record.get("flaky", [])]
    return lines


SWEEP_SKIP = re.compile(r"\bUI_SWEEP_SKIP (.+?)\s*$")


def sweep_skips(log: str) -> list[dict]:
    """The rows the tap-through sweep (UI test 3) left out, from its UI_SWEEP_SKIP lines, in
    order and each once: {"where": "Vorschläge › Länder und Orte", "why": "section header or
    footer text"}. The sweep skips a cell without its own label that has fewer than two texts
    and no image as a section header or footer; listed in the run summary so that a real row
    skipped that way is seen."""
    found: list[dict] = []
    for line in log.splitlines():
        match = SWEEP_SKIP.search(line)
        if not match or ": error:" in line:
            continue
        text = match.group(1)
        why = re.match(r"^(.*?) \(([^()]*)\)$", text)
        entry = {"where": why.group(1), "why": why.group(2)} if why else {"where": text, "why": ""}
        if entry not in found:
            found.append(entry)
    return found


def sweep_summary(records: list[dict]) -> str:
    """Markdown: every row the sweep left out, per group ("" when no group has any)."""
    rows = [(r["group"], s) for r in records for s in r.get("sweep_skips", [])]
    if not rows:
        return ""
    cell = lambda text: text.replace("|", "\\|")  # noqa: E731
    md = ["### UI test 3: rows the tap-through sweep did not tap", "",
          f"{len(rows)} row(s) left out. \"section header or footer text\" is a cell without its own label "
          "with fewer than two texts and no image; if a real row is listed so, the sweep missed it.", "",
          "| Group | Where | Why |", "|---|---|---|"]
    md += [f"| {group} | {cell(s['where'])} | {cell(s['why'])} |" for group, s in rows]
    return "\n".join(md) + "\n"


def flaky_summary(records: list[dict]) -> tuple[str, list[str]]:
    """(Markdown for the run summary, FLAKY lines) over every group's record."""
    boots = sum(len(r.get("boot", [])) for r in records)
    retries = sum(len(r.get("retries", [])) for r in records)
    flaky = [f for r in records for f in r.get("flaky", []) if f.get("first") != INSIDE]
    inside = [f for r in records for f in r.get("flaky", []) if f.get("first") == INSIDE]
    lines = [line for r in records for line in flaky_lines(r)]
    md = ["### UI tests: simulator retries and flaky tests", "",
          f"{retries} repeat(s) after a simulator failure, {len(flaky)} test(s) passed only on the repeat, "
          f"{len(inside)} retry(ies) inside a test, "
          f"{boots} failed boot attempt(s), over {len(records)} pass record(s). A real test failure is never repeated.", ""]
    if lines:
        md += ["| Group | Kind | Test | First pass | Reason / result |", "|---|---|---|---|---|"]
        for r in records:
            md += [f"| {r['group']} | boot | | | {b} |" for b in r.get("boot", [])]
            md += [f"| {r['group']} | repeat | | | {x['result']}: {'; '.join(x['reasons'])} |" for x in r.get("retries", [])]
            md += [f"| {r['group']} | flaky | {f['test']} | {f['first']} | {f['reason']} |" for f in r.get("flaky", [])]
    sweep = sweep_summary(records)
    return "\n".join(md) + "\n" + ("\n" + sweep if sweep else ""), lines


def sh(command: list[str], timeout: float = 300, quiet: bool = False) -> tuple[int, str]:
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        output = (done.stdout or "") + (done.stderr or "")
        code = done.returncode
    except subprocess.TimeoutExpired:
        output, code = f"timed out after {int(timeout)} s: {' '.join(command)}", 124
    except OSError as error:
        output, code = str(error), 127
    if not quiet and output.strip():
        print(output.rstrip(), flush=True)
    return code, output


def pick(device: str) -> str:
    """UDID of the pinned simulator (.github/toolchain.json): "pro" is the image's iPhone Pro
    on the pinned runtime, "se" a new iPhone SE (375 pt) created from the pinned device type on
    that runtime. No fallback: a missing simulator fails the job (exit 2 in main)."""
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pick_simulator.py")
    if device == "se":
        sys.path.insert(0, os.path.dirname(script))
        from pick_simulator import pins
        toolchain = pins()
        small, runtime = toolchain["simulators"]["small"], toolchain["runtime"]["identifier"]
        code, udid = sh(["xcrun", "simctl", "create", small["name"], small["create"], runtime], quiet=True)
        if code == 0 and re.fullmatch(r"[0-9A-F-]{36}", udid.strip()):
            print(f"{small['name']} ({small['create']}) on {runtime}", file=sys.stderr)
            return udid.strip()
        print(f"::error title=Pinned toolchain::could not create {small['name']} ({small['create']}) on {runtime}: "
              f"{udid.strip()[:300]}. Update .github/toolchain.json on purpose.", flush=True)
        return ""
    _, listing = sh(["xcrun", "simctl", "list", "devices", "available", "-j"], quiet=True)
    done = subprocess.run([sys.executable, script, "--role", "pro"], input=listing, capture_output=True, text=True)
    sys.stderr.write(done.stderr)
    if done.returncode != 0:
        print(f"::error title=Pinned toolchain::{done.stderr.strip()[:300]}", flush=True)
    return done.stdout.strip()


BOOT_RETRIES: list[str] = []


def timing(what: str, started: float) -> None:
    """UI_BOOT_TIMING lines: where the 2-5 min before the first test go (simulator boot, photo
    access, settings), measured per job; docs/TESTFLIGHT.md, "Messung"."""
    print(f"UI_BOOT_TIMING {what} {time.monotonic() - started:.1f} s", flush=True)


SETTLE_LOAD = 3.5
SETTLE_LIMIT = 300
SETTLE_STEP = 10


def settle_limit(deadline: float, now: float) -> float:
    """How long `settle` may wait: SETTLE_LIMIT, but never into the RETRY_AFTER_RESET minutes
    that the retry guard in command_run promised to the tests (checked before the erase, while
    the wait comes after it)."""
    if not deadline:
        return SETTLE_LIMIT
    return max(0.0, min(SETTLE_LIMIT, deadline - now - RETRY_AFTER_RESET))


def settle(load=lambda: os.getloadavg()[0], sleep=time.sleep, top=None,
           limit: float = SETTLE_LIMIT, step: float = SETTLE_STEP, clock=time.monotonic) -> bool:
    """Waits until the Mac's 1-minute load is below SETTLE_LOAD (at most `limit` s), before a
    pass starts its first test. Every value is a SIM_SETTLE line, what keeps the Mac busy a
    SIM_TOP line once a minute. True when it settled.

    Why: right after the simulator's boot the hosted Mac (3 cores) is starved for minutes
    (ci.yml has the same wait since CI 44376522818). The first launch of a UI group then took
    30 s (device test06, UI run 44397301774) or XCTest lost the app although it had started
    and drawn its first screen (flow-other test05, UI run 44437759848: process after 4 s, its
    code after 9 s, a 2.3 s stall in dyld/os_log, "does not have a process ID" after 150 s).
    The pass still runs when the load stays high: the wait only gives the Mac its time."""
    # Measured on the clock: on a starved Mac `ps` (busiest) alone can take its 30 s timeout.
    start, next_top = clock(), 0.0
    while True:
        value = load()
        waited = clock() - start
        print(f"SIM_SETTLE load(1m)={value:.2f} after {waited:.0f} s", flush=True)
        if value < SETTLE_LOAD:
            return True
        if waited >= next_top:
            next_top += 60
            for line in (top or busiest)():
                print(f"SIM_TOP {line}", flush=True)
        if waited >= limit:
            print(f"SIM_SETTLE still {value:.2f} after {waited:.0f} s; the pass starts anyway", flush=True)
            return False
        sleep(min(step, limit - waited))


def busiest() -> list[str]:
    """The busiest processes on the Mac (for SIM_TOP)."""
    code, out = sh(["ps", "-Ao", "pcpu=,state=,comm=", "-r"], timeout=30, quiet=True)
    return [line[:160] for line in out.splitlines()[:8]] if code == 0 else []


def boot(udid: str) -> bool:
    for attempt in (1, 2, 3):
        started = time.monotonic()
        sh(["xcrun", "simctl", "boot", udid], timeout=600, quiet=True)
        timing(f"simctl boot (attempt {attempt})", started)
        code, _ = sh(["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=900)
        timing(f"booted (attempt {attempt}, bootstatus {code})", started)
        if code == 0:
            return True
        BOOT_RETRIES.append(f"bootstatus failed (attempt {attempt} of 3)")
        print(f"FLAKY_BOOT {udid} bootstatus failed (attempt {attempt} of 3), retrying", flush=True)
        time.sleep(15)
    return False


def prepare(udid: str, reduce_motion: bool = False, increase_contrast: bool = False, basics: bool = True) -> None:
    """Photo access, status bar and the accessibility settings of the job."""
    spawn = ["xcrun", "simctl", "spawn", udid]
    started = time.monotonic()
    if basics:
        if sh(["xcrun", "simctl", "privacy", udid, "grant", "photos", BUNDLE_ID], timeout=600)[0] != 0:
            print("privacy grant failed")
        timing("photo access granted", started)
        sh(["xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged",
            "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3"], timeout=120)
        timing("status bar set", started)
    if reduce_motion:
        # Settings › Accessibility › Motion. The app reads it at launch.
        sh(spawn + ["defaults", "write", "com.apple.Accessibility", "ReduceMotionEnabled", "-bool", "true"])
        _, value = sh(spawn + ["defaults", "read", "com.apple.Accessibility", "ReduceMotionEnabled"], quiet=True)
        print(f"A11Y_SETTING ReduceMotionEnabled={value.strip()}", flush=True)
    if increase_contrast:
        if sh(["xcrun", "simctl", "ui", udid, "increase_contrast", "enabled"])[0] != 0:
            sh(spawn + ["defaults", "write", "com.apple.Accessibility", "DarkenSystemColors", "-bool", "true"])
        sh(spawn + ["defaults", "write", "com.apple.Accessibility", "EnhancedBackgroundContrastEnabled", "-bool", "true"])
        _, darken = sh(spawn + ["defaults", "read", "com.apple.Accessibility", "DarkenSystemColors"], quiet=True)
        _, enhanced = sh(spawn + ["defaults", "read", "com.apple.Accessibility", "EnhancedBackgroundContrastEnabled"], quiet=True)
        print(f"A11Y_SETTING DarkenSystemColors={darken.strip()} EnhancedBackgroundContrastEnabled={enhanced.strip()}", flush=True)
    timing("prepared", started)


def reset(udid: str, reduce_motion: bool, increase_contrast: bool) -> bool:
    """Shut down, erase, boot and prepare again: the repeat starts like a new group (the app,
    its data, the photo library and the runner's marker files are gone, so a repeated test 1
    meets the welcome screen and checks every step again)."""
    sh(["xcrun", "simctl", "shutdown", udid], timeout=180)
    if sh(["xcrun", "simctl", "erase", udid], timeout=300)[0] != 0:
        print("UI_SIM_ERASE_FAILED", flush=True)
        return False
    print("UI_SIM_ERASED", flush=True)
    if not boot(udid):
        return False
    prepare(udid, reduce_motion, increase_contrast)
    return True


def parse_bundle(text: str) -> list[str]:
    """`bundle_findings` of `xcresulttool get test-results tests` output, or why it is not
    readable (then no repeat): it must be a JSON object with a list "testNodes"."""
    try:
        tests = json.loads(text)
    except ValueError as error:
        return [f"result bundle not readable ({error})"]
    if not isinstance(tests, dict) or not isinstance(tests.get("testNodes"), list):
        return [f"result bundle not readable (no testNodes list in {text.strip()[:120]!r})"]
    return bundle_findings(tests)


def read_bundle(path: str) -> list[str]:
    """`bundle_findings` of a result bundle, or why it could not be read (then no repeat)."""
    code, output = sh(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", path], timeout=300, quiet=True)
    if code != 0:
        return [f"result bundle not readable ({output.strip()[:200]})"]
    return parse_bundle(output)


def crash_reports(since: float) -> list[str]:
    """Crash reports of the app or the test runner written since `since`."""
    folder = os.path.expanduser("~/Library/Logs/DiagnosticReports")
    found = []
    for path in glob.glob(os.path.join(folder, "**", "Sortly*"), recursive=True):
        try:
            if os.path.getmtime(path) >= since - 5:
                found.append(path)
        except OSError:
            pass
    return sorted(found)


def other_crash_reports(since: float) -> list[str]:
    folder = os.path.expanduser("~/Library/Logs/DiagnosticReports")
    found = []
    for path in glob.glob(os.path.join(folder, "**", "*.ips"), recursive=True):
        name = os.path.basename(path)
        try:
            recent = os.path.getmtime(path) >= since - 5
        except OSError:
            recent = False
        if recent and not name.startswith("Sortly") and re.search(r"testmanagerd|XCTest|Runner|CoreSimulator|SpringBoard", name):
            found.append(path)
    return sorted(found)[:10]


# ---------------------------------------------------------------------------------------------
# One pass


class Recorder(threading.Thread):
    """Video of the sorting show in the full flow: starts when the test opens the plan
    ("UI_STEP_OK open plan") and stops a few seconds after the plan is done ("UI_TIMING apply")."""

    def __init__(self, udid: str, log_path: str, video: str):
        super().__init__(daemon=True)
        self.udid, self.log_path, self.video = udid, log_path, video
        self.stop_flag = threading.Event()
        self.offset = 0
        self.tail = ""
        self.lines: list[str] = []

    def seen(self, pattern: str) -> bool:
        """Reads only what was added to the log since the last call (it grows to tens of MB)."""
        try:
            with open(self.log_path, encoding="utf-8", errors="replace") as log:
                log.seek(self.offset)
                chunk = log.read()
                self.offset = log.tell()
        except OSError:
            chunk = ""
        text = self.tail + chunk
        complete, _, self.tail = text.rpartition("\n")
        self.lines += [l.rstrip() for l in complete.split("\n") if "UI_STEP_OK" in l or "UI_TIMING" in l]
        return any(re.search(pattern, line) for line in self.lines)

    def run(self) -> None:
        while not self.stop_flag.is_set() and not self.seen(r"UI_STEP_OK open plan"):
            time.sleep(1)
        if self.stop_flag.is_set():
            return
        recording = subprocess.Popen(["xcrun", "simctl", "io", self.udid, "recordVideo", "--codec=h264", "--force", self.video],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(240):
            if self.stop_flag.is_set() or self.seen(r"UI_TIMING apply"):
                break
            time.sleep(1)
        time.sleep(3)
        recording.send_signal(signal.SIGINT)
        try:
            recording.wait(timeout=30)
        except subprocess.TimeoutExpired:
            recording.kill()

    def stop(self) -> None:
        self.stop_flag.set()
        self.join(timeout=60)


HOST_GRANT = re.compile(r"(?:^|\s)UI_HOST_GRANT_PHOTOS\s*$")


def host_grant_requests(text: str) -> int:
    """How many complete lines of `text` ask the Mac to give the photo access back."""
    return sum(1 for line in text.split("\n") if HOST_GRANT.search(line))


GRANT_TRIES = 2
GRANT_TIMEOUT = 90


def grant_photos(udid: str, run=sh, tries: int = GRANT_TRIES, timeout: float = GRANT_TIMEOUT) -> bool:
    """`simctl privacy grant photos`, tried again once with a fresh call when it fails.

    UI run 44108052342 (device test 09): the call hung until its 120 s timeout, and the app's
    launches in that time waited for it (one began 55 s late, 4 s after the call was killed),
    so the access stayed taken away and test 09 and, through it, test 10 failed. A normal grant
    takes about a second. Every try is in the log ("UI_HOST ... attempt N of M"); the tests'
    own checks decide as before (a grant that never came stays a red test)."""
    for attempt in range(1, tries + 1):
        started = time.monotonic()
        code, output = run(["xcrun", "simctl", "privacy", udid, "grant", "photos", BUNDLE_ID], timeout=timeout, quiet=True)
        took = time.monotonic() - started
        if code == 0:
            print(f"UI_HOST photo access granted ({took:.0f} s, attempt {attempt} of {tries})", flush=True)
            return True
        detail = " ".join(output.split())[:200]
        print(f"UI_HOST photo access grant failed (exit {code}, {took:.0f} s, attempt {attempt} of {tries})"
              + (f": {detail}" if detail else ""), flush=True)
    print(f"UI_HOST photo access NOT granted after {tries} attempts; the test that asked will fail on it", flush=True)
    return False


class HostGrants(threading.Thread):
    """Gives the photo access back from the Mac each time a test asks (UI_HOST_GRANT_PHOTOS,
    DeviceConditionUITests.grantFromHost): the CI simulator shows no iOS question after an
    access reset, and Settings opens on its first page, not on Albumist's."""

    def __init__(self, udid: str, log_path: str, interval: float = 2, grant=None):
        super().__init__(daemon=True)
        self.udid, self.log_path, self.interval = udid, log_path, interval
        self.grant = grant or self.grant_photos
        self.stopped = threading.Event()
        self.offset = 0
        self.tail = ""

    def grant_photos(self) -> None:
        grant_photos(self.udid)

    def check(self) -> None:
        """Reads what was added to the log since the last call; one grant per complete request line."""
        try:
            with open(self.log_path, encoding="utf-8", errors="replace") as log:
                log.seek(self.offset)
                chunk = log.read()
                self.offset = log.tell()
        except OSError:
            chunk = ""
        complete, _, self.tail = (self.tail + chunk).rpartition("\n")
        for _ in range(host_grant_requests(complete)):
            self.grant()
        # A failure shows in the job log at once, not only when the pass ends: a run cancelled
        # (or a runner lost) after it is still red for ui_evidence.py.
        for line in complete.splitlines():
            if LIVE.search(line) and not DATA_LINE.search(line):
                print(f"UI_LIVE {line[:400]}", flush=True)

    def run(self) -> None:
        while not self.stopped.wait(self.interval):
            self.check()

    def stop(self) -> None:
        self.stopped.set()
        self.join(timeout=30)


def device_state(udid: str) -> str:
    """"Booted", "Shutdown", ... of a simulator, or "" when simctl does not say (then unknown)."""
    code, listing = sh(["xcrun", "simctl", "list", "devices", "-j"], timeout=30, quiet=True)
    if code != 0:
        return ""
    try:
        for entries in json.loads(listing).get("devices", {}).values():
            for d in entries:
                if d.get("udid") == udid:
                    return str(d.get("state", ""))
    except (ValueError, AttributeError):
        pass
    return ""


class Watchdog(threading.Thread):
    """Stops xcodebuild when the simulator leaves "Booted" before the first test started.

    Hosted Macs sometimes lose the simulator 1-5 min into a pass ("Test crashed with signal term
    while preparing to run tests", then "device is not booted"; UI run 43893790053 lost 4-5 min
    per group waiting for xcodebuild to give up). The stop is written to the log as a
    UI_WATCHDOG line (an infrastructure line for `decide`) and counted as FLAKY_BOOT; the pass is
    then repeated once on an erased simulator like any other simulator failure."""

    def __init__(self, udid: str, log_path: str, process: subprocess.Popen, interval: float = 20):
        super().__init__(daemon=True)
        self.udid, self.log_path, self.process, self.interval = udid, log_path, process, interval
        self.stopped = threading.Event()
        self.fired = ""

    def read_log(self) -> str:
        try:
            with open(self.log_path, encoding="utf-8", errors="replace") as log:
                return log.read()
        except OSError:
            return ""

    def run(self) -> None:
        states: list[str] = []
        while not self.stopped.wait(self.interval):
            text = self.read_log()
            if STARTED.search(text):
                return
            states.append(device_state(self.udid))
            if watchdog_should_stop(text, states):
                # device_state can take up to 30 s; a test that started meanwhile must not be
                # stopped, so the log is read again right before the stop.
                if STARTED.search(self.read_log()):
                    return
                self.fired = states[-1]
                print(f"UI_WATCHDOG simulator {self.udid} is {self.fired} before the first test; stopping the pass", flush=True)
                self.process.terminate()
                try:
                    self.process.wait(timeout=60)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                return

    def stop(self) -> None:
        self.stopped.set()


def run_pass(args, label: str, chosen: list[str], build: bool) -> tuple[int, str, str, float, bool]:
    """One xcodebuild run; returns (status, log text, result bundle path, start time, whether
    the watchdog stopped it)."""
    suffix = "" if label == "first" else "-retry"
    log_path = os.path.join(args.out, f"{args.name}{suffix}-log.txt")
    result = os.path.join(args.out, f"{args.name}{suffix}.xcresult")
    if args.xctestrun:
        command = ["xcodebuild", "test-without-building", "-xctestrun", args.xctestrun]
    else:
        command = ["xcodebuild", "test" if build else "test-without-building", "-project", args.project,
                   "-scheme", args.scheme, "CODE_SIGNING_ALLOWED=NO"]
    command += ["-destination", f"id={args.udid}", "-resultBundlePath", result] + chosen
    settled = time.monotonic()
    settle(limit=settle_limit(getattr(args, "deadline", 0) or 0, time.time()))
    timing(f"load settled before the {label} pass", settled)
    print(f"UI_PASS {args.name} {label}: {' '.join(chosen) or 'all tests'}", flush=True)
    # SwiftUI reports broken navigation (link without destination) and similar runtime problems
    # only in the system log, so it is recorded during the whole pass.
    with open(os.path.join(args.out, f"{args.name}-swiftui.txt"), "a") as swiftui:
        stream = subprocess.Popen(
            ["xcrun", "simctl", "spawn", args.udid, "log", "stream", "--style", "compact", "--level", "debug",
             "--predicate", 'process == "Sortly" AND (subsystem == "com.apple.SwiftUI" OR messageType == fault '
                            'OR eventMessage CONTAINS[c] "navigationDestination")'],
            stdout=swiftui, stderr=subprocess.STDOUT)
    recorder = None
    if args.video and not os.path.exists(args.video):
        recorder = Recorder(args.udid, log_path, args.video)
        recorder.start()
    started = time.time()
    with open(log_path, "w") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        watchdog = Watchdog(args.udid, log_path, process)
        watchdog.start()
        grants = HostGrants(args.udid, log_path)
        grants.start()
        status, hung = wait_until(process, getattr(args, "deadline", 0) or 0)
        grants.stop()
        watchdog.stop()
        watchdog.join(timeout=90)
    if hung:
        with open(log_path, encoding="utf-8", errors="replace") as log:
            test = running_test(log.read())
        with open(log_path, "a") as log:
            if test:
                log.write(f"\nUI_HANG pass {label}: {test} still running at the job's deadline; xcodebuild stopped\n")
            else:
                log.write(f"\nUI_DEADLINE pass {label} stopped at the job's deadline with no test running\n")
        print(f"::error title=UI {args.name}::The {label} pass did not end before the job's deadline"
              + (f" ({test} hangs); stopped." if test else "; no test was running, stopped."), flush=True)
        status = status or 1
    if watchdog.fired:
        with open(log_path, "a") as log:
            log.write(f"\nUI_WATCHDOG simulator {args.udid} left Booted (state {watchdog.fired}) before the first test; "
                      "pass stopped\n")
        BOOT_RETRIES.append(f"simulator left Booted (state {watchdog.fired}) before the first test of the {label} pass; "
                            "stopped by the watchdog")
        status = status or 1
    stream.terminate()
    if recorder:
        recorder.stop()
    print(f"UI_PASS_TIME {args.name} {label} {int(time.time() - started)} s (exit {status})", flush=True)
    with open(log_path, encoding="utf-8", errors="replace") as log:
        text = log.read()
    # A pass stopped by the watchdog or at the deadline may leave a result bundle xcodebuild
    # could not finish; command_run then drops only the "not readable" finding (watchdog_bundle).
    return status, text, result, started, bool(watchdog.fired) or hung


RUNNING = re.compile(r"Test Case '-\[\w+\.(\w+) (\w+)\]' (started|passed|failed|skipped)")


def running_test(log: str) -> str | None:
    """"Class/test" of a test case that started and has no passed/failed/skipped line yet."""
    open_tests: list[str] = []
    for match in RUNNING.finditer(log):
        name = f"{match.group(1)}/{match.group(2)}"
        if match.group(3) == "started":
            open_tests.append(name)
        elif name in open_tests:
            open_tests.remove(name)
    return open_tests[-1] if open_tests else None


def wait_until(process, deadline: float, grace: float = 30) -> tuple[int, bool]:
    """(exit status, whether it hung): waits for `process` until the epoch second `deadline`
    (0: no deadline), then stops it: SIGINT first, which lets xcodebuild end the test and write
    its result bundle like Ctrl-C does; after `grace` seconds SIGTERM, after `grace` more SIGKILL."""
    if not deadline:
        return process.wait(), False
    try:
        return process.wait(timeout=max(1.0, deadline - time.time())), False
    except subprocess.TimeoutExpired:
        pass
    for stop in (lambda: process.send_signal(signal.SIGINT), process.terminate):
        stop()
        try:
            return process.wait(timeout=grace) or 1, True
        except subprocess.TimeoutExpired:
            continue
    process.kill()
    return process.wait() or 1, True


def report(text: str, status: int, label: str) -> None:
    printed = 0
    for line in text.splitlines():
        if REPORT.search(line) and "/SourcePackages/" not in line:
            print(line)
            printed += 1
            if printed >= REPORT_LIMIT:
                print(f"UI_REPORT_CUT {label}: more than {REPORT_LIMIT} lines")
                break
    # A pass that fails before any test runs leaves nothing for the filter above.
    if status != 0 and "Test Case" not in text:
        for line in [l for l in text.splitlines() if "PREVIEW_JPEG" not in l][-40:]:
            print(f"UI_LOG_TAIL {label} {line[:400]}")
    for line in restart_context(text):
        print(f"UI_RESTART_CONTEXT {label} {line}")


def print_crash_reports(paths: list[str], label: str) -> None:
    for path in paths:
        print(f"UI_CRASH_REPORT {label} {path}")
        try:
            with open(path, encoding="utf-8", errors="replace") as report_file:
                head = report_file.read(6000)
        except OSError as error:
            head = str(error)
        for line in head.splitlines()[:150]:
            print(f"UI_CRASH {line}")


def command_run(args) -> int:
    os.makedirs(args.out, exist_ok=True)
    chosen = selection(args.only, args.skip)
    if args.increase_contrast:
        prepare(args.udid, increase_contrast=True, basics=False)
    status, text, bundle_path, started, stopped = run_pass(args, "first", chosen, build=True)
    report(text, status, "first")
    crashes = crash_reports(started) if status else []
    # Whether the simulator is still there after a failed pass ("device is not booted").
    probe = sh(["xcrun", "simctl", "spawn", args.udid, "launchctl", "getenv", "HOME"], timeout=60, quiet=True)[1] if status else ""
    bundle = read_bundle(bundle_path) if status else []
    if stopped:
        bundle = watchdog_bundle(bundle)
    verdict, reasons = decide(status, text, crashes, probe[:4000], bundle)
    print(f"UI_VERDICT {args.name} first: {verdict}" + (f" ({'; '.join(reasons)})" if reasons else ""), flush=True)
    print_crash_reports(crashes + other_crash_reports(started) if status else [], "first")
    passes = [("first", 0 if verdict == "pass" else (status or 1), verdict, reasons, text)]
    first_log, retry_reasons, retry_log, retry_result = text, [], None, None
    stays_red = False
    if verdict == "retry":
        retry_reasons = reasons
        retry = retry_arguments(args.only, args.skip, text)
        if retry is None:
            stays_red = True
            print(f"UI_VERDICT {args.name}: every selected test passed, nothing to repeat; the failed pass stays red")
        else:
            print(f"::warning title=UI {args.name}::The simulator failed ({'; '.join(reasons)}); no test found a problem. "
                  "The tests that did not pass run once more on an erased simulator.")
            deadline = getattr(args, "deadline", 0) or 0
            if deadline and deadline - time.time() < RETRY_BEFORE_RESET:
                print(f"UI_VERDICT retry skipped: {max(0, deadline - time.time()) / 60:.0f} min left before the job's "
                      "deadline, too little for an erase and a repeat")
                retry_result = "not started (too little time before the deadline)"
            elif not reset(args.udid, args.reduce_motion, args.increase_contrast):
                print("UI_VERDICT retry impossible: the simulator did not come back after the erase")
                retry_result = "not started (simulator did not come back)"
            elif deadline and deadline - time.time() < RETRY_AFTER_RESET:
                print(f"UI_VERDICT retry skipped: the erase took until {max(0, deadline - time.time()) / 60:.0f} min "
                      "before the job's deadline")
                retry_result = "not started (too little time before the deadline)"
            else:
                status, text, bundle_path, started, stopped = run_pass(args, "retry", retry, build=False)
                report(text, status, "retry")
                crashes = crash_reports(started) if status else []
                bundle = read_bundle(bundle_path) if status else []
                verdict, reasons = decide(status, text, crashes, bundle=watchdog_bundle(bundle) if stopped else bundle)
                # "infra": the repeat failed on the simulator or XCTest alone again.
                final = {"pass": "pass", "retry": "infra"}.get(verdict, "fail")
                again = daemon_crash_tests(first_log) & daemon_crash_tests(text)
                if final == "infra" and again:
                    # The daemon crashed again in the same test: likely caused by what the test
                    # does in the app (a huge accessibility tree, ...), so red, not "no result".
                    final = "fail"
                    reasons = ["testmanagerd crashed again in the same test: "
                               + ", ".join(f"{c}/{t}" for c, t in sorted(again)) + " (likely app-caused)"] + reasons
                print(f"UI_VERDICT {args.name} retry: {final}" + (f" ({'; '.join(reasons)})" if reasons else ""), flush=True)
                print_crash_reports(crashes + other_crash_reports(started) if status else [], "retry")
                passes.append(("retry", 0 if final == "pass" else (status or 1), final, reasons, text))
                retry_log, retry_result = text, final
        if retry is None:
            retry_reasons = []
    record = flaky_record(args.name, first_log, retry_reasons, retry_log, retry_result, boot_retries(args.out))
    record["sweep_skips"] = sweep_skips(first_log + "\n" + (retry_log or ""))
    write_flaky(args, record)
    # The result is the last pass: the first one when nothing was repeated, else the repeat
    # (which ran every test that had not passed in the first one).
    failed = passes[-1][1] != 0
    infra_only = failed and passes[-1][2] in ("retry", "infra") and not stays_red
    if swiftui_warnings(os.path.join(args.out, f"{args.name}-swiftui.txt")) != 0:
        failed, infra_only = True, False
    if args.video:
        video_to_log(args.video)
    if args.a11y_summary:
        joined = "\n".join(p[4] for p in passes)
        print(f"A11Y_SUMMARY {args.name} fails {joined.count('A11Y_FAIL ')} warnings {joined.count('A11Y_WARN ')}")
    write_summary(args.name, passes)
    # The line ui_evidence.py reads in the job log: only "fail" is a red for the group's key.
    result = "infra" if infra_only else ("fail" if failed else "pass")
    print(f"UI_RESULT {args.name} {result}", flush=True)
    if infra_only:
        # Every pass failed on the simulator or XCTest alone (the repeat too, or it could not
        # start): no test result for the group. The workflow fails the job in its own step "No
        # test result (simulator or XCTest failed in every pass)" instead of "Run UI tests".
        reasons = "; ".join(passes[-1][3]) or "no reason found"
        with open(os.path.join(args.out, NO_TEST_RESULT), "w", encoding="utf-8") as marker:
            marker.write(reasons + "\n")
        print(f"::warning title=UI {args.name}::No test result: the simulator or XCTest failed in every pass "
              f"({reasons}). Neither green nor red for this group; start it again.")
        return NO_TEST_EXIT
    return 1 if failed else 0


def swiftui_warnings(path: str) -> int:
    """Prints the app's unique runtime warnings; 1 when a navigation link leads nowhere."""
    try:
        with open(path, encoding="utf-8", errors="replace") as log:
            lines = log.read().splitlines()
    except OSError:
        return 0
    counts: dict[str, int] = {}
    for line in lines:
        if re.search(r"^Filtering|^Timestamp|SwiftUI:Scenes|_UIHostingView|renderbox", line):
            continue
        key = line[24:]
        counts[key] = counts.get(key, 0) + 1
    for key, count in sorted(counts.items(), key=lambda kv: -kv[1])[:40]:
        print(f"UI_RUNTIME_WARNING {count:>7} {key}")
    text = "\n".join(lines)
    if re.search(r"Publishing changes from within view updates|Modifying state during view update", text, re.I):
        print("::warning::SwiftUI state was changed during a view update (see UI_RUNTIME_WARNING)")
    if re.search(r"no matching navigationDestination|NavigationLink is presenting|cannot be activated", text, re.I):
        print("::error::SwiftUI navigation warning in the UI run (a link leads nowhere)")
        return 1
    return 0


def video_to_log(video: str) -> None:
    """Artifact downloads are not reachable from every reviewer's machine, so a smaller copy
    of the video is also printed into the log (base64 chunks, like the screenshots)."""
    if not os.path.exists(video):
        print("UI_VIDEO missing (the plan was not applied in this run)")
        return
    print(f"UI_VIDEO {os.path.basename(video)}")
    small = video[:-4] + "-small.mp4"
    if sh(["avconvert", "--source", video, "--output", small, "--preset", "Preset1920x1080", "--replace"],
          timeout=300, quiet=True)[0] != 0:
        with open(video, "rb") as source, open(small, "wb") as target:
            target.write(source.read())
    size = os.path.getsize(small)
    print(f"UI_VIDEO_SIZE {size}")
    if size < 25_000_000:
        import base64
        data = base64.b64encode(open(small, "rb").read()).decode()
        for index in range(0, len(data), 60000):
            print(f"UI_VIDEO_B64 {index // 60000 + 1} {data[index:index + 60000]}")


def boot_retries(out: str) -> list[str]:
    """Failed boot attempts of this job: the background boot (boot --out) and any reset here."""
    found = []
    path = os.path.join(out, "boot-retries.json")
    try:
        with open(path, encoding="utf-8") as f:
            found = json.load(f)
        os.remove(path)  # counted once, by the first run of the job
    except (OSError, ValueError):
        pass
    return [str(x) for x in found if isinstance(x, str)] + BOOT_RETRIES


def write_flaky(args, record: dict) -> None:
    """build/flaky-NAME.json (collected by the UI summary job), FLAKY lines in the log and,
    when anything was repeated or the sweep left rows out, rows in the job summary. Nothing is
    repeated silently."""
    with open(os.path.join(args.out, f"flaky-{args.name}.json"), "w", encoding="utf-8") as f:
        json.dump(record, f, indent=1)
    lines = flaky_lines(record)
    for line in lines:
        print(line, flush=True)
    repeated = [f["test"] for f in record["flaky"] if f["first"] != INSIDE]
    inside = [f["test"] for f in record["flaky"] if f["first"] == INSIDE]
    if record["flaky"]:
        parts = ([f"{len(repeated)} test(s) passed only on the repeat: {', '.join(repeated)}"] if repeated else []) \
            + ([f"{len(inside)} retry(ies) inside a test: {', '.join(inside)}"] if inside else [])
        print(f"::warning title=UI {args.name} flaky::{'; '.join(parts)}", flush=True)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path and (lines or record.get("sweep_skips")):
        with open(path, "a", encoding="utf-8") as out:
            out.write("\n" + flaky_summary([record])[0])


def write_summary(name: str, passes) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    rows = []
    for label, status, verdict, reasons, text in passes:
        tests = finished_tests(text)
        counts = {s: sum(1 for v in tests.values() if v == s) for s in ("passed", "failed", "skipped")}
        rows.append(f"| {name} | {label} | {'✅' if status == 0 else '❌'} {verdict} | {counts['passed']} | "
                    f"{counts['failed']} | {counts['skipped']} | {'; '.join(reasons)} |")
    with open(path, "a", encoding="utf-8") as out:
        out.write("\n| Group | Pass | Result | Passed | Failed | Skipped | Why |\n|---|---|---|---|---|---|---|\n")
        out.write("\n".join(rows) + "\n")


# ---------------------------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("pick")
    p.add_argument("--device", choices=["pro", "se"], default="pro")
    b = sub.add_parser("boot")
    b.add_argument("--udid", required=True)
    b.add_argument("--reduce-motion", action="store_true")
    b.add_argument("--ready-file")
    b.add_argument("--out", default="build")
    f = sub.add_parser("flaky-summary")
    f.add_argument("records", nargs="*")
    r = sub.add_parser("run")
    r.add_argument("--udid", required=True)
    r.add_argument("--name", required=True)
    r.add_argument("--xctestrun")
    r.add_argument("--project", default="App/Sortly.xcodeproj")
    r.add_argument("--scheme", default="SortlyUI")
    r.add_argument("--only", action="append", default=[])
    r.add_argument("--skip", action="append", default=[])
    r.add_argument("--reduce-motion", action="store_true")
    r.add_argument("--increase-contrast", action="store_true")
    r.add_argument("--video")
    r.add_argument("--a11y-summary", action="store_true")
    r.add_argument("--out", default="build")
    r.add_argument("--deadline", type=float, default=0,
                   help="epoch second by which a pass must end (the job's limit minus a margin); 0: none")
    c = sub.add_parser("classify")
    c.add_argument("log")
    c.add_argument("--status", type=int, default=65)
    c.add_argument("--crash-report", action="append", default=[])
    c.add_argument("--bundle-json", help="output of `xcrun xcresulttool get test-results tests` for the pass")
    args = parser.parse_args(argv)
    # Space-separated lists are allowed too (matrix values in ui.yml).
    for key in ("only", "skip"):
        if hasattr(args, key):
            setattr(args, key, [t for value in getattr(args, key) for t in value.split()])

    if args.command == "pick":
        udid = pick(args.device)
        if not udid:
            print("no simulator found", file=sys.stderr)
            return 1
        print(udid)
        return 0
    if args.command == "boot":
        ok = boot(args.udid)
        if BOOT_RETRIES:
            os.makedirs(args.out, exist_ok=True)
            with open(os.path.join(args.out, "boot-retries.json"), "w", encoding="utf-8") as f:
                json.dump(BOOT_RETRIES, f)
        if ok:
            prepare(args.udid, reduce_motion=args.reduce_motion)
        else:
            print("simulator did not boot")
        if args.ready_file:
            with open(args.ready_file, "w") as ready:
                ready.write("ok\n" if ok else "failed\n")
        return 0 if ok else 1
    if args.command == "run" and args.xctestrun is not None and not os.path.isfile(args.xctestrun):
        print(f"::error::--xctestrun '{args.xctestrun}' is not a file (no .xctestrun in the build products?)")
        return 2
    if args.command == "flaky-summary":
        records = []
        for path in args.records:
            try:
                with open(path, encoding="utf-8") as f:
                    records.append(json.load(f))
            except (OSError, ValueError) as error:
                print(f"::warning title=UI summary::{path} not readable ({error})")
        markdown, lines = flaky_summary(records)
        for line in lines:
            print(line, file=sys.stderr)
        flaky = sum(len(r.get("flaky", [])) for r in records)
        retries = sum(len(r.get("retries", [])) for r in records)
        if flaky or retries:
            print(f"::notice title=UI flaky tests::{retries} repeat(s) after a simulator failure, "
                  f"{flaky} test(s) passed only on the repeat", file=sys.stderr)
        skipped = sum(len(r.get("sweep_skips", [])) for r in records)
        if skipped:
            print(f"::notice title=UI sweep::{skipped} row(s) not tapped by the tap-through sweep "
                  "(listed in the run summary)", file=sys.stderr)
        print(markdown)
        return 0
    if args.command == "classify":
        with open(args.log, encoding="utf-8", errors="replace") as log:
            text = log.read()
        bundle = []
        if args.bundle_json:
            with open(args.bundle_json, encoding="utf-8") as tests:
                bundle = parse_bundle(tests.read())
        verdict, reasons = decide(args.status, text, args.crash_report, bundle=bundle)
        print(f"{verdict}: {'; '.join(reasons)}")
        return 0
    return command_run(args)


if __name__ == "__main__":
    sys.exit(main())
