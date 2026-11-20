#!/usr/bin/env python3
"""Runs `swift test` with a deadline and, when it hangs, names the tests that were still running.

On 20.11.2026 the Linux core tests hung for 30 minutes (CI and UI runs, FullRunDisplayTests
around rebuildAfterCompleteRun) until the job's timeout-minutes killed them; the log ended with
the last test that finished, not the one that hung. This watchdog keeps the output as before
(echoed and written to --log), counts every test that Swift Testing (or XCTest) reported as
started and not yet finished, and at the deadline:
  - prints `TEST_HANG <test> running for <s> s` for each of them, oldest first, an ::error
    annotation and a line in the job summary;
  - sends SIGQUIT to the test processes (the Swift runtime's backtracer then prints where every
    thread stands), waits up to --grace seconds, then kills them;
  - exits 124 (as `timeout` does), so the step is red like any test failure: a hang is a test
    finding, never machinery, and it is not retried.
Without a hang it exits with the command's own status.

  python3 .github/scripts/swift_test_watch.py --minutes 10 --log core-linux.log -- swift test --parallel

The deadline is about twice the 95th percentile of the step's measured time (docs/TESTFLIGHT.md,
"Tempo-Plan"), below the step's timeout-minutes, so the report comes before GitHub kills the job.
"""
from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
import threading
import time
from collections import Counter

# Swift Testing: "◇ Test rebuildAfterCompleteRun() started." / "✔ Test x() passed after 0.1
# seconds." / "✘ Test x() failed after ..." / "➜ Test x() skipped."; XCTest: "Test Case
# '-[Suite test]' started." / "... passed (0.1 seconds)." / "... failed (...)." / "... skipped".
STARTED = re.compile(r"\bTest (?P<name>.+?) started\.?\s*$")
# "recorded an issue" is not an end: such a test may still be running (and hang).
FINISHED = re.compile(r"\bTest (?P<name>.+?) (?:passed|failed|skipped)\b")


class Tracker:
    """Tests started and not finished, with the time each was first seen starting."""

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.open: Counter[str] = Counter()
        self.since: dict[str, float] = {}
        self.lock = threading.Lock()

    def feed(self, line: str) -> None:
        line = line.rstrip("\n")
        with self.lock:
            started = STARTED.search(line)
            if started:
                name = started.group("name")
                self.open[name] += 1
                self.since.setdefault(name, self.clock())
                return
            finished = FINISHED.search(line)
            if finished and self.open[finished.group("name")] > 0:
                name = finished.group("name")
                self.open[name] -= 1
                if self.open[name] == 0:
                    del self.open[name]
                    self.since.pop(name, None)

    def running(self) -> list[tuple[str, float]]:
        """[(test, seconds running)], the longest first."""
        now = self.clock()
        with self.lock:
            return sorted(((n, now - self.since[n]) for n in self.open), key=lambda item: -item[1])


def append_summary(text: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text + "\n")


def report(tracker: Tracker, limit_s: float, out=None) -> list[str]:
    out = out or sys.stdout
    running = tracker.running()
    names = [name for name, _ in running]
    for name, seconds in running:
        print(f"TEST_HANG {name} running for {int(seconds)} s", file=out)
    listed = ", ".join(names[:10]) or "none reported as started (the hang is outside a test, e.g. the build)"
    print(f"::error title=Tests hung::swift test ran longer than {int(limit_s // 60)} min; still running: {listed}",
          file=out)
    append_summary(f"**Tests hung** after {int(limit_s // 60)} min; still running: {listed}")
    return names


def session_pids(sid: int) -> list[int]:
    """Every process of the session `sid` (the test command was started as its leader): from
    /proc on Linux, `pgrep -s` elsewhere (macOS). The test runner and its helpers (xctest,
    swiftpm-testing-helper) may sit in process groups of their own, but not in another session."""
    pids = []
    if os.path.isdir("/proc"):
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            try:
                with open(f"/proc/{entry}/stat", encoding="utf-8", errors="replace") as f:
                    fields = f.read().rsplit(")", 1)[1].split()
                if int(fields[3]) == sid:  # after "pid (comm)": state ppid pgrp session
                    pids.append(int(entry))
            except (OSError, IndexError, ValueError):
                continue
    else:
        found = subprocess.run(["pgrep", "-s", str(sid)], capture_output=True, text=True)
        pids = [int(p) for p in found.stdout.split() if p.isdigit()]
    return pids


def signal_session(sid: int, sig: int) -> int:
    """Sends `sig` to the session's process group and to every process of the session."""
    sent = 0
    try:
        os.killpg(sid, sig)
        sent += 1
    except (ProcessLookupError, PermissionError):
        pass
    for pid in session_pids(sid):
        try:
            os.kill(pid, sig)
            sent += 1
        except (ProcessLookupError, PermissionError):
            pass
    return sent


def run(command: list[str], limit_s: float, log_path: str | None, quiet: bool, grace_s: float) -> int:
    tracker = Tracker()
    log = open(log_path, "w", encoding="utf-8") if log_path else None
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                               errors="replace", bufsize=1, start_new_session=True)

    def pump():
        for line in process.stdout:
            tracker.feed(line)
            if not quiet:
                sys.stdout.write(line)
                sys.stdout.flush()
            if log:
                log.write(line)
                log.flush()

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    try:
        status = process.wait(timeout=limit_s)
    except subprocess.TimeoutExpired:
        report(tracker, limit_s)
        signal_session(process.pid, signal.SIGQUIT)
        deadline = time.monotonic() + grace_s
        while time.monotonic() < deadline and (process.poll() is None or session_pids(process.pid)):
            time.sleep(0.5)
        # Nothing of the session is left running.
        signal_session(process.pid, signal.SIGKILL)
        process.wait()
        reader.join(timeout=5)
        if log:
            log.close()
        return 124
    reader.join(timeout=30)
    if log:
        log.close()
    return status


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--minutes", type=float, help="deadline in minutes")
    parser.add_argument("--seconds", type=float, help="deadline in seconds (tests)")
    parser.add_argument("--log", help="also write the output here")
    parser.add_argument("--quiet", action="store_true", help="write the output only to --log")
    parser.add_argument("--grace", type=float, default=60, help="seconds between SIGQUIT and SIGKILL")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or (args.minutes is None) == (args.seconds is None):
        parser.error("give the command after -- and exactly one of --minutes or --seconds")
    limit = args.seconds if args.seconds is not None else args.minutes * 60
    return run(command, limit, args.log, args.quiet, args.grace)


if __name__ == "__main__":
    sys.exit(main())
