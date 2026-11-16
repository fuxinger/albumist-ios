"""Runs one group of UI tests on its own simulator, and repeats only what the simulator lost.

Every UI job (ui.yml) uses this script, so all of them treat a failure the same way:

  pick  --device pro|se
      Prints the UDID of the simulator for the job: an iPhone Pro ("pro", the screenshots of
      the UI flow) or a newly created iPhone SE on the newest runtime ("se", the small iPhone
      of the accessibility tests; the narrowest iPhone there when the runtime has no SE).
  boot  --udid U [--reduce-motion] [--ready-file F]
      Boots the simulator (three attempts: CoreSimulator on the hosted Macs sometimes aborts
      the first bootstatus), grants photo access, fixes the status bar and writes the
      accessibility settings. With --ready-file it writes "ok" or "failed" there at the end,
      so the boot can run in the background while the build products are downloaded.
  run   --udid U --name N (--xctestrun F | --project P --scheme S) [--only T]... [--skip T]...
        [--reduce-motion] [--increase-contrast] [--video F] [--out DIR]
      Runs the tests (T is "Class" or "Class/testMethod" of SortlyUITests), prints the
      report lines for the log (steps, screenshots, accessibility findings, restart context,
      crash reports, SwiftUI runtime warnings) and exits with the result.
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
    line (other than the infrastructure lines above), no recorded issue, no A11Y_FAIL, no
    "Fatal error", "Crash:", "crashed", "Test crashed with signal ..." (other than the SIGTERM
    above) or "execution time allowance";
  - no crash report of the app or the test runner (~/Library/Logs/DiagnosticReports/Sortly*)
    was written during the pass;
  - the result bundle agrees: no test case failed with a message other than the
    infrastructure ones above, no issue outside a test, and it can be read at all.
Anything else is never repeated: a real failure stays red. A pass that ran no test at all
fails (a renamed test would otherwise make an empty, green selection), and a repeat whose
selection would be empty is not started. Both passes keep their own log and result bundle
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
REPORT = re.compile(r"error:|UI_STEP|UI_SWEEP|UI_TIMING|UI_FACT|A11Y_|PREVIEW_JPEG|Test Case|Executed|\*\* |"
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
    (re.compile(r"\*\* (?:TEST )?BUILD FAILED \*\*"), "build failed"),
]

# Lines that carry data, not messages (base64 screenshots and video).
DATA_LINE = re.compile(r"PREVIEW_JPEG|UI_VIDEO_B64")

CASE = re.compile(r"Test Case '-\[(?:[\w]+)\.(\w+) (\w+)\]' (passed|failed|skipped)")
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


def scan(text: str) -> tuple[list[str], list[str]]:
    """(real reasons, infrastructure reasons) found in a log, line by line."""
    real: list[str] = []
    infra: list[str] = []
    for line in text.splitlines():
        if DATA_LINE.search(line):
            continue
        found = is_infra(line)
        if found:
            infra += [r for r in found if r not in infra]
            continue
        real += [reason for pattern, reason in REAL if pattern.search(line) and reason not in real]
    return real, infra


def bundle_findings(tests: dict) -> list[str]:
    """Problems in `xcresulttool get test-results tests` output that are not the simulator's:
    any failure message that is not an infrastructure line, and any test case that did not
    pass without saying why. Tests that never started are not in the bundle."""
    findings: list[str] = []

    def messages(node: dict) -> list[str]:
        found = []
        for child in node.get("children", []) or []:
            if child.get("nodeType") == "Failure Message":
                found.append(child.get("name", ""))
            found += messages(child)
        return found

    def walk(node: dict) -> None:
        kind = node.get("nodeType")
        if kind == "Failure Message":
            text = node.get("name", "")
            if not is_infra(text):
                findings.append(f"result bundle: {text[:200]}")
        if kind == "Test Case" and node.get("result") not in PASSED and not messages(node):
            findings.append(f"result bundle: {node.get('name', '?')} {node.get('result', 'no result')} without a message")
        for child in node.get("children", []) or []:
            walk(child)

    for node in tests.get("testNodes", []) or []:
        walk(node)
    return findings


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
    real, infra = scan(log)
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
    """xcodebuild selection for the repeat: the same tests minus every test that passed.
    None when nothing is left (every test named in --only passed): no "-only X -skip X"."""
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
    _, listing = sh(["xcrun", "simctl", "list", "devices", "available", "-j"], quiet=True)
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pick_simulator.py")

    def choose(flag: str) -> str:
        done = subprocess.run([sys.executable, script, flag], input=listing, capture_output=True, text=True)
        sys.stderr.write(done.stderr)
        return done.stdout.strip()

    if device == "se":
        # An iPhone SE (375 pt) on the newest general runtime if that runtime still offers one.
        _, runtimes = sh(["xcrun", "simctl", "list", "runtimes", "available", "-j"], quiet=True)
        try:
            found = [r for r in json.loads(runtimes)["runtimes"]
                     if r.get("platform") == "iOS" and re.search(r"iOS-\d+(?:-\d+)*$", r["identifier"])]
        except (ValueError, KeyError):
            found = []
        found.sort(key=lambda r: tuple(int(p) for p in r["version"].split(".")))
        if found:
            code, udid = sh(["xcrun", "simctl", "create", "Albumist SE",
                             "com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation",
                             found[-1]["identifier"]], quiet=True)
            if code == 0 and re.fullmatch(r"[0-9A-F-]{36}", udid.strip()):
                print(f"Albumist SE on {found[-1]['identifier']}", file=sys.stderr)
                return udid.strip()
        return choose("--small")
    return choose("--pro")


def boot(udid: str) -> bool:
    for attempt in (1, 2, 3):
        sh(["xcrun", "simctl", "boot", udid], timeout=600, quiet=True)
        code, _ = sh(["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=900)
        if code == 0:
            return True
        print(f"bootstatus failed (attempt {attempt}), retrying", flush=True)
        time.sleep(15)
    return False


def prepare(udid: str, reduce_motion: bool = False, increase_contrast: bool = False, basics: bool = True) -> None:
    """Photo access, status bar and the accessibility settings of the job."""
    spawn = ["xcrun", "simctl", "spawn", udid]
    if basics:
        if sh(["xcrun", "simctl", "privacy", udid, "grant", "photos", BUNDLE_ID], timeout=600)[0] != 0:
            print("privacy grant failed")
        sh(["xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged",
            "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3"], timeout=120)
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


def read_bundle(path: str) -> list[str]:
    """`bundle_findings` of a result bundle, or why it could not be read (then no repeat)."""
    code, output = sh(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", path], timeout=300, quiet=True)
    if code != 0:
        return [f"result bundle not readable ({output.strip()[:200]})"]
    try:
        return bundle_findings(json.loads(output))
    except ValueError as error:
        return [f"result bundle not readable ({error})"]


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


def run_pass(args, label: str, chosen: list[str], build: bool) -> tuple[int, str, str, float]:
    """One xcodebuild run; returns (status, log text, result bundle path, start time)."""
    suffix = "" if label == "first" else "-retry"
    log_path = os.path.join(args.out, f"{args.name}{suffix}-log.txt")
    result = os.path.join(args.out, f"{args.name}{suffix}.xcresult")
    if args.xctestrun:
        command = ["xcodebuild", "test-without-building", "-xctestrun", args.xctestrun]
    else:
        command = ["xcodebuild", "test" if build else "test-without-building", "-project", args.project,
                   "-scheme", args.scheme, "CODE_SIGNING_ALLOWED=NO"]
    command += ["-destination", f"id={args.udid}", "-resultBundlePath", result] + chosen
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
        status = subprocess.call(command, stdout=log, stderr=subprocess.STDOUT)
    stream.terminate()
    if recorder:
        recorder.stop()
    print(f"UI_PASS_TIME {args.name} {label} {int(time.time() - started)} s (exit {status})", flush=True)
    with open(log_path, encoding="utf-8", errors="replace") as log:
        text = log.read()
    return status, text, result, started


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
    status, text, bundle_path, started = run_pass(args, "first", chosen, build=True)
    report(text, status, "first")
    crashes = crash_reports(started) if status else []
    # Whether the simulator is still there after a failed pass ("device is not booted").
    probe = sh(["xcrun", "simctl", "spawn", args.udid, "launchctl", "getenv", "HOME"], timeout=60, quiet=True)[1] if status else ""
    bundle = read_bundle(bundle_path) if status else []
    verdict, reasons = decide(status, text, crashes, probe[:4000], bundle)
    print(f"UI_VERDICT {args.name} first: {verdict}" + (f" ({'; '.join(reasons)})" if reasons else ""), flush=True)
    print_crash_reports(crashes + other_crash_reports(started) if status else [], "first")
    passes = [("first", 0 if verdict == "pass" else (status or 1), verdict, reasons, text)]
    if verdict == "retry":
        retry = retry_arguments(args.only, args.skip, text)
        if retry is None:
            print(f"UI_VERDICT {args.name}: every selected test passed, nothing to repeat; the failed pass stays red")
        else:
            print(f"::warning title=UI {args.name}::The simulator failed ({'; '.join(reasons)}); no test found a problem. "
                  "The tests that did not pass run once more on an erased simulator.")
            if reset(args.udid, args.reduce_motion, args.increase_contrast):
                status, text, bundle_path, started = run_pass(args, "retry", retry, build=False)
                report(text, status, "retry")
                crashes = crash_reports(started) if status else []
                verdict, reasons = decide(status, text, crashes, bundle=read_bundle(bundle_path) if status else [])
                final = "pass" if verdict == "pass" else "fail"
                print(f"UI_VERDICT {args.name} retry: {final}" + (f" ({'; '.join(reasons)})" if reasons else ""), flush=True)
                print_crash_reports(crashes + other_crash_reports(started) if status else [], "retry")
                passes.append(("retry", 0 if final == "pass" else (status or 1), final, reasons, text))
            else:
                print("UI_VERDICT retry impossible: the simulator did not come back after the erase")
    # The result is the last pass: the first one when nothing was repeated, else the repeat
    # (which ran every test that had not passed in the first one).
    failed = passes[-1][1] != 0
    if swiftui_warnings(os.path.join(args.out, f"{args.name}-swiftui.txt")) != 0:
        failed = True
    if args.video:
        video_to_log(args.video)
    if args.a11y_summary:
        joined = "\n".join(p[4] for p in passes)
        print(f"A11Y_SUMMARY {args.name} fails {joined.count('A11Y_FAIL ')} warnings {joined.count('A11Y_WARN ')}")
    write_summary(args.name, passes)
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
    if args.command == "classify":
        with open(args.log, encoding="utf-8", errors="replace") as log:
            text = log.read()
        bundle = []
        if args.bundle_json:
            with open(args.bundle_json, encoding="utf-8") as tests:
                bundle = bundle_findings(json.load(tests))
        verdict, reasons = decide(args.status, text, args.crash_report, bundle=bundle)
        print(f"{verdict}: {'; '.join(reasons)}")
        return 0
    return command_run(args)


if __name__ == "__main__":
    sys.exit(main())
