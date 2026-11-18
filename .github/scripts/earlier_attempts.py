"""Checks the earlier attempts of a TestFlight run before its upload ("Re-run failed jobs").

The owner's rule: flaky tests are counted and fixed, never hidden. So a red test is never re-run
to green: after a red test the fix goes into a new commit and a NEW run. "Re-run failed jobs" is
only for a failure of the machinery, a step in MACHINERY_STEPS or with a MACHINERY_PREFIXES name:
a runner or container that did not start, a simulator that did not boot, an artifact, a checkout
or XcodeGen (pinned download) that did not arrive, an upload to App Store Connect that broke off. Every
other step that did not pass blocks: tests, lint rules, builds, the archive and its check, the
pinned toolchain, the project generation. It goes by the step, not by the cause: a step stopped
by a cancel or a timeout, or one a lost runner left unfinished, counts like a failed one (a test
that was stopped did not pass). A job that never ran a step (no runner) counts as machinery.

  python3 .github/scripts/earlier_attempts.py --attempt 3 [--forced] jobs-1.json jobs-2.json

Each file is the answer of GET /repos/{repo}/actions/runs/{run_id}/attempts/{n}/jobs for one
earlier attempt, in order (testflight.yml fetches them with curl). Prints a warning for each
machinery failure and an error for every other one, writes a table to $GITHUB_STEP_SUMMARY and
`text=<one line>` to $GITHUB_OUTPUT (for the tag message), and exits 1 when an earlier attempt
failed outside the machinery. With --forced (a build that skips every test) it lists and never
blocks. A job that a re-run carried over unchanged appears again in every later attempt with the
same start and end time; it is counted once, and each job is one row. It fails closed: a missing,
unreadable or partial answer (more jobs than one page of 100) also exits 1.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

MACHINERY_STEPS = {
    "Set up job", "Initialize containers", "Stop containers", "Complete job",
    "Install SQLite headers", "Install XcodeGen",
    "Boot simulator (in the background)", "Wait for the simulator",
    "Unpack build products", "Keep the retry record for the run summary",
    # This check itself: it fails on what it finds in an earlier attempt (found again from
    # there) or when the API does not answer (then a re-run of the upload job is right).
    "Earlier attempts of this run",
    # The UI plan (ui.yml) and the UI gate (testflight.yml) decide from the recorded results of
    # the groups alone, every time anew (ui_evidence.py): a red group stays red for them in
    # every attempt, so a re-run of them can hide nothing.
    "Plan the UI groups", "UI groups green for this app and test code",
    # ui.yml: the build products without tests (a build or artifact problem, not a test), and
    # a group whose every pass failed on the simulator or XCTest alone (ui_tests.py exit 75):
    # there is no test result, so a re-run hides none.
    "Built tests present", "No test result (simulator or XCTest failed in every pass)",
}
MACHINERY_PREFIXES = ("Upload ", "Download ", "Post ", "Run actions/checkout@")
NOT_PASSED = ("failure", "timed_out", "cancelled")
PASSED_STEP = ("success", "skipped", "neutral")


def is_machinery(step: str) -> bool:
    return step in MACHINERY_STEPS or step.startswith(MACHINERY_PREFIXES)


def _escape(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def command(kind: str, title: str, message: str) -> str:
    """A ::warning or ::error line. The runner ends a title at ',' (as in "attempt 1, 2") and reads
    '%', CR and LF as escapes, so they are escaped the way it expects."""
    return f"::{kind} title={_escape(title).replace(':', '%3A').replace(',', '%2C')}::{_escape(message)}"


def failed_steps(job: dict) -> list[str]:
    """The steps a job did not pass: failed, cancelled (a cancel or a timeout stops the running
    step) or started and never finished (a runner lost in the middle of it). Steps that never
    ran are "skipped" or not listed, and a job that never started has no steps (CI 43763857204)."""
    return [s.get("name", "?") for s in job.get("steps") or []
            if s.get("conclusion") not in PASSED_STEP and (s.get("conclusion") or s.get("started_at"))]


def earlier_failures(attempts: list[tuple[int, dict]]) -> list[dict]:
    """One entry per job name that did not pass in an earlier attempt, in order of appearance:
    {"job", "attempts", "results", "steps", "machinery"}. Copies that a re-run carried over
    (same name, start and end) are counted once, in the attempt that ran them."""
    seen = set()
    rows: dict[str, dict] = {}
    for attempt, answer in attempts:
        for job in answer.get("jobs", []):
            if job.get("conclusion") not in NOT_PASSED:
                continue
            key = (job.get("name"), job.get("started_at"), job.get("completed_at"))
            if key in seen:
                continue
            seen.add(key)
            steps = failed_steps(job)
            row = rows.setdefault(job.get("name", "?"), {"job": job.get("name", "?"), "attempts": [],
                                                         "results": [], "steps": [], "machinery": True})
            row["attempts"].append(attempt)
            row["results"].append(job["conclusion"])
            row["steps"] += [s for s in steps if s not in row["steps"]]
            # No step that did not pass: the job ended outside its steps (no runner, or lost between two).
            row["machinery"] = row["machinery"] and all(is_machinery(s) for s in steps)
    return list(rows.values())


def one_line(rows: list[dict]) -> str:
    """For the tag message, e.g. "earlier attempts: UI flow / UI device conditions (attempt 1:
    Wait for the simulator)"."""
    if not rows:
        return "earlier attempts: no failed job"
    parts = [f"{r['job']} (attempt {', '.join(map(str, r['attempts']))}: {', '.join(r['steps']) or '/'.join(r['results'])})"
             for r in rows]
    text = " ".join(("earlier attempts: " + "; ".join(parts)).splitlines())  # one line for $GITHUB_OUTPUT
    return text if len(text) <= 900 else text[:897] + "..."


def report(rows: list[dict], attempt: int, forced: bool) -> tuple[list[str], str, bool]:
    """(workflow commands, summary markdown, blocked)."""
    lines, blocked = [], False
    for r in rows:
        what = f"{r['job']}: {'/'.join(r['results'])}" + (f" in {', '.join(r['steps'])}" if r["steps"] else " (no failed step)")
        when = ", ".join(map(str, r["attempts"]))
        if r["machinery"]:
            lines.append(command("warning", f"Re-run after attempt {when}", f"{what}; machinery, a re-run is allowed"))
        elif forced:
            lines.append(command("warning", "FORCED – untested", f"{what} in attempt {when}"))
        else:
            blocked = True
            lines.append(command("error", f"Red in attempt {when}", f"{what}. A red test is never re-run to green: "
                                 "fix it and start a new run."))
    cell = lambda text: text.replace("|", "\\|")  # noqa: E731
    md = [f"### Attempt {attempt} of this run: the earlier attempts", ""]
    if rows:
        md += ["| Job | Attempt | Result | Failed steps | Counts as |", "|---|---|---|---|---|"]
        md += [f"| {cell(r['job'])} | {', '.join(map(str, r['attempts']))} | {'/'.join(r['results'])} | "
               f"{cell(', '.join(r['steps']) or 'none')} | "
               f"{'machinery: re-run allowed' if r['machinery'] else 'not machinery: fix it and start a new run'} |"
               for r in rows]
    else:
        md.append(f"No job failed in attempts 1 to {attempt - 1}.")
    if blocked:
        md += ["", "**Not uploaded**: an earlier attempt failed outside the machinery (a test, a rule, a build "
                   "or the archive). A red test is never re-run to green: fix it and start a new run."]
    elif forced and any(not r["machinery"] for r in rows):
        md += ["", "**FORCED – untested**: listed only; a forced build skips every test."]
    return lines, "\n".join(md) + "\n", blocked


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--attempt", type=int, required=True, help="this attempt (github.run_attempt)")
    parser.add_argument("--forced", action="store_true", help="the run uploads without tests (force)")
    parser.add_argument("answers", nargs="*", help="jobs of attempts 1 to N-1, in order")
    args = parser.parse_args(argv)
    if len(args.answers) != args.attempt - 1:
        print(f"::error title=Earlier attempts::expected the jobs of {args.attempt - 1} earlier attempt(s), "
              f"got {len(args.answers)}")
        return 1
    attempts = []
    for number, path in enumerate(args.answers, start=1):
        try:
            with open(path, encoding="utf-8") as f:
                answer = json.load(f)
            # Fails closed: an answer without its job list, or with only part of it, is no answer.
            if not isinstance(answer, dict) or not isinstance(answer.get("jobs"), list):
                raise ValueError("no job list")
            if answer.get("total_count", 0) > len(answer["jobs"]):
                raise ValueError(f"{len(answer['jobs'])} of {answer['total_count']} jobs")
            attempts.append((number, answer))
        except (OSError, ValueError, TypeError) as error:
            print(command("error", "Earlier attempts", f"the jobs of attempt {number} are not readable ({error}); "
                          "re-run this job once the API answers, or start a new run"))
            return 1
    rows = earlier_failures(attempts)
    lines, markdown, blocked = report(rows, args.attempt, args.forced)
    for line in lines:
        print(line, flush=True)
    with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a", encoding="utf-8") as out:
        out.write(markdown)
    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a", encoding="utf-8") as out:
        out.write(f"text={one_line(rows)}\n")
    return 1 if blocked else 0


if __name__ == "__main__":
    sys.exit(main())
