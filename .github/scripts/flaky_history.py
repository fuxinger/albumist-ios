#!/usr/bin/env python3
"""Red UI groups, simulator repeats and flaky tests over the last days, across runs.

Review P5-06 (18.11.2026): 8 of 15 red UI runs were no app bug, and the same test step failed
five times, but every run counted only its own repeats (ui_tests.py flaky-summary). This reads
the UI runs of the last DAYS days (ui.yml, testflight.yml, ui-stress.yml) through the API:

  - every group job, the stress pass and the Release smoke test (also of earlier attempts: a red
    that a re-run turned green still counts), sorted by why it did not pass, with the rules of
    the UI gate and the upload check (ui_evidence.py, earlier_attempts.py; second review of C5):
    "test red" (a step the upload check blocks on failed: the tests, the build, the toolchain,
    the project; or the job's time limit stopped its test step), "no result" (the step "No test
    result ...": the simulator or XCTest failed in every pass), "machinery" (only steps the
    upload check lets re-run: runner, download, checkout, simulator boot), "cancelled" (a
    cancel before the time limit);
  - the retry records of those runs (build/flaky-GROUP.json, artifacts ui-flaky-GROUP-attempt-N
    and flaky-stress-attempt-N): repeats after a simulator failure, tests that passed only on a
    repeat, retries inside a test, failed boot attempts.

Prints Markdown for the job summary and one ::notice line with the counts. It never fails a
run (exit 0, whatever goes wrong; the workflow step also has continue-on-error and its own
timeout, and earlier_attempts.py counts it as machinery): the groups and the gate decide. It
stops early, and says so, after MAX_CALLS API calls, after DEADLINE seconds, or when fewer than
RESERVE calls of the hour are left, so a UI run's plan and verdict (ui_evidence.py, MAX_CALLS
each) always have theirs. Lists are read page by page; when one is cut at MAX_PAGES the summary
says how many it listed of how many.

Usage: GH_TOKEN=... GITHUB_REPOSITORY=owner/repo flaky_history.py [--days 7] [--max-calls 80]
"""
from __future__ import annotations

import argparse
import collections
import datetime
import http.client
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import earlier_attempts  # noqa: E402
import ui_evidence  # noqa: E402

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
WORKFLOWS = ("ui.yml", "testflight.yml", "ui-stress.yml")
MAX_CALLS = 80
# Calls of the hour left for a UI run's plan and verdict (ui_evidence.py, MAX_CALLS each).
RESERVE = 2 * ui_evidence.MAX_CALLS
DEADLINE = 120  # seconds; the workflow step has timeout-minutes: 3
MAX_PAGES = 5  # pages of 100 per list
# The time limits (timeout-minutes) of the jobs that are no group job (ui.yml's groups:
# ui_evidence.GROUP_TIMEOUT_MINUTES); test_flaky_history.py checks them against the workflows.
TIME_LIMITS = {"stress": 170, "release-smoke": 75}
# What can break off while reading: the connection, the answer, the archive.
READ_ERRORS = (urllib.error.URLError, OSError, http.client.HTTPException, zipfile.BadZipFile, zipfile.LargeZipFile,
               ValueError, KeyError, TypeError)

GROUP_JOB = re.compile(r"\[([a-z0-9-]+) app [0-9a-f]+ tests [0-9a-f]+\]\s*$")
STRESS_JOB = re.compile(r"\bUI stress \d+ photos\s*$")
SMOKE_JOB = re.compile(r"\bRelease build smoke test \(UI\)\s*$")  # testflight.yml release-smoke
RECORD = re.compile(r"^(?:ui-)?flaky-([a-z0-9-]+)-attempt-(\d+)$")
TEST_STEPS = (ui_evidence.TEST_STEP, "Stress run")
NO_RESULT_STEP = "No test result"
OUTCOMES = ("green", "test red", "no result", "machinery", "cancelled")
INSIDE = "retried inside the test"  # ui_tests.INSIDE


class OutOfCalls(Exception):
    pass


class Api:
    """GET calls with a counter; stops at max_calls or when the hour's calls run low."""

    def __init__(self, token: str, repo: str, max_calls: int = MAX_CALLS, opener=urllib.request.urlopen):
        self.token, self.repo, self.max_calls, self.opener = token, repo, max_calls, opener
        self.count = 0
        self.stopped = ""
        self.max_pages = MAX_PAGES
        self.clock, self.deadline, self.started = time.monotonic, DEADLINE, None

    def in_time(self) -> None:
        """Raises OutOfCalls once DEADLINE seconds have passed since the first check."""
        now = self.clock()
        self.started = now if self.started is None else self.started
        if now - self.started > self.deadline:
            self.stopped = self.stopped or f"time limit ({self.deadline} s)"
            raise OutOfCalls(self.stopped)

    def _open(self, url: str, accept: str):
        if self.count >= self.max_calls:
            self.stopped = self.stopped or f"call limit ({self.max_calls})"
            raise OutOfCalls(self.stopped)
        self.count += 1
        request = urllib.request.Request(url, headers={"Accept": accept, "X-GitHub-Api-Version": "2022-11-28"})
        # Not sent on to the storage host an artifact download is redirected to.
        request.add_unredirected_header("Authorization", f"Bearer {self.token}")
        response = self.opener(request, timeout=60)
        left = response.headers.get("X-RateLimit-Remaining")
        if left is not None and left.isdigit() and int(left) < RESERVE:
            self.stopped = f"only {left} API calls of the hour left, kept for the UI plan and gate"
            self.max_calls = self.count  # this answer is used, no further call
        return response

    def get(self, path: str, **params) -> dict:
        url = f"{API}/repos/{self.repo}/{path}" + ("?" + urllib.parse.urlencode(params) if params else "")
        with self._open(url, "application/vnd.github+json") as response:
            return json.load(response)

    def download(self, url: str) -> bytes:
        with self._open(url, "application/vnd.github+json") as response:
            return response.read()


def outcome(job: dict) -> str | None:
    """Why a finished job did not pass, or "green"; None while it runs or when it was skipped.
    The steps that did not pass are earlier_attempts.failed_steps, judged by its is_machinery;
    the time limit by ui_evidence.ran_out_of_time."""
    if job.get("status") != "completed" or job.get("conclusion") in ("skipped", None):
        return None
    if job["conclusion"] == "success":
        return "green"
    failed = earlier_attempts.failed_steps(job)
    if any(name.startswith(NO_RESULT_STEP) for name in failed):
        return "no result"
    if job["conclusion"] == "cancelled":
        group = group_of(job.get("name", ""))
        limit = TIME_LIMITS.get(group or "", ui_evidence.GROUP_TIMEOUT_MINUTES)
        stopped_in_test = any(name in TEST_STEPS for name in failed)
        return "test red" if stopped_in_test and ui_evidence.ran_out_of_time(job, limit) else "cancelled"
    if not failed or all(earlier_attempts.is_machinery(name) for name in failed):
        return "machinery"  # no runner, a job that never ran a step, or only steps a re-run may repeat
    return "test red"


def group_of(job_name: str) -> str | None:
    name = job_name.split(" / ")[-1]
    found = GROUP_JOB.search(name)
    if found:
        return found.group(1)
    if STRESS_JOB.search(name):
        return "stress"
    return "release-smoke" if SMOKE_JOB.search(name) else None


def records_of(blob: bytes) -> list[dict]:
    """The flaky-*.json records in an artifact's zip (unreadable ones left out)."""
    found = []
    try:
        with zipfile.ZipFile(io.BytesIO(blob)) as archive:
            for name in archive.namelist():
                if re.fullmatch(r"(?:.*/)?flaky-[a-z0-9-]+\.json", name):
                    try:
                        record = json.loads(archive.read(name).decode("utf-8"))
                    except (ValueError, UnicodeDecodeError):
                        continue
                    if isinstance(record, dict):
                        found.append(record)
    except zipfile.BadZipFile:
        pass
    return found


def listing(api: Api, path: str, key: str, capped: list[str], label: str, **params) -> list[dict]:
    """Every item of a paged list, at most api.max_pages pages of 100; a cut list is noted in
    `capped` ("<label>: N of M <key> listed")."""
    items, total = [], None
    for page in range(1, api.max_pages + 1):
        api.in_time()
        answer = api.get(path, per_page=100, page=page, **params)
        found = answer.get(key, [])
        items += found
        total = answer.get("total_count", total)
        if len(found) < 100 or (total is not None and len(items) >= total):
            return items
    if total is None or len(items) < total:
        capped.append(f"{label}: {len(items)} of {total if total is not None else 'more'} {key.replace('workflow_', '')} listed")
    return items


def collect(api: Api, since: datetime.datetime) -> dict:
    """{"runs": [run ids read], "listed": number of runs in the window, "groups": {group:
    Counter of outcomes}, "reds": [(group, outcome, run id, attempt)], "records": [records],
    "stopped": why it stopped early ("" when it read everything), "capped": the lists cut at
    MAX_PAGES ("" when none)}. Never raises."""
    stats = {"runs": [], "listed": 0, "groups": collections.defaultdict(collections.Counter), "reds": [],
             "records": [], "stopped": "", "capped": ""}
    capped: list[str] = []
    try:
        runs = []
        for workflow in WORKFLOWS:
            try:
                runs += listing(api, f"actions/workflows/{workflow}/runs", "workflow_runs", capped, workflow,
                                created=f">={since:%Y-%m-%dT%H:%M:%SZ}")
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    continue
                raise
        runs.sort(key=lambda r: r.get("created_at", ""), reverse=True)
        stats["listed"] = len(runs)
        for run in runs:
            jobs = listing(api, f"actions/runs/{run['id']}/jobs", "jobs", capped, f"run {run['id']}", filter="all")
            artifacts = listing(api, f"actions/runs/{run['id']}/artifacts", "artifacts", capped, f"run {run['id']}")
            stats["runs"].append(run["id"])
            for job in jobs:
                group, result = group_of(job.get("name", "")), outcome(job)
                if group and result:
                    stats["groups"][group][result] += 1
                    if result != "green":
                        stats["reds"].append((group, result, run["id"], job.get("run_attempt", 1)))
            for artifact in artifacts:
                if RECORD.match(artifact.get("name", "")) and not artifact.get("expired"):
                    api.in_time()
                    stats["records"] += records_of(api.download(artifact["archive_download_url"]))
    except OutOfCalls:
        pass
    except READ_ERRORS as error:
        stats["stopped"] = f"the API did not answer ({type(error).__name__}: {str(error)[:200]})"
    except Exception as error:  # a report never fails the run
        stats["stopped"] = f"it failed ({type(error).__name__}: {str(error)[:200]})"
    stats["stopped"] = stats["stopped"] or api.stopped
    stats["capped"] = "; ".join(capped)
    return stats


def counts(stats: dict) -> dict:
    records = stats["records"]
    flaky = [f for r in records for f in r.get("flaky", [])]
    return {
        "repeats": sum(len(r.get("retries", [])) for r in records),
        "passed on repeat": sum(1 for f in flaky if f.get("first") != INSIDE),
        "inside": sum(1 for f in flaky if f.get("first") == INSIDE),
        "boots": sum(len(r.get("boot", [])) for r in records),
        "reds": collections.Counter(result for _, result, _, _ in stats["reds"]),
        "tests": collections.Counter((f.get("test", "?"), "inside" if f.get("first") == INSIDE else "repeat") for f in flaky),
    }


def markdown(stats: dict, days: int) -> str:
    c = counts(stats)
    read, listed = len(stats["runs"]), stats["listed"]
    md = [f"### UI history: the last {days} days, every UI run", "",
          f"{read} of {listed} runs read (UI flow, TestFlight, stress; newest first)"
          + (f"; stopped early: {stats['stopped']}" if stats["stopped"] else "")
          + (f"; lists cut at {MAX_PAGES * 100}: {stats['capped']}" if stats.get("capped") else "") + ".", "",
          "Group jobs by result, by the rules of the UI gate and the upload check. *Test red*: a test, the app, its "
          "build or toolchain, or the time limit in the tests (fix it, never re-run to green). *No result*: the "
          "simulator or XCTest failed in every pass. *Machinery*: runner, download, checkout, simulator boot. "
          "*Cancelled*: before the time limit.", "",
          "| Group | " + " | ".join(o.capitalize() for o in OUTCOMES) + " |", "|---|" + "---|" * len(OUTCOMES)]
    for group in sorted(stats["groups"]):
        md.append(f"| {group} | " + " | ".join(str(stats["groups"][group][o]) for o in OUTCOMES) + " |")
    if not stats["groups"]:
        md.append("| (none) |" + " |" * len(OUTCOMES))
    md += ["", f"Repeats after a simulator failure: {c['repeats']}. Tests that passed only on a repeat: "
           f"{c['passed on repeat']}. Retries inside a test: {c['inside']}. Failed boot attempts: {c['boots']}."]
    if c["tests"]:
        md += ["", "| Flaky test | Times | Kind |", "|---|---|---|"]
        md += [f"| {test} | {n} | {'retried inside the test' if kind == 'inside' else 'passed only on the repeat'} |"
               for (test, kind), n in c["tests"].most_common(15)]
    if stats["reds"]:
        md += ["", "Not green: " + ", ".join(f"{g} {r} (run {run}, attempt {a})" for g, r, run, a in stats["reds"][:30])]
    return "\n".join(md) + "\n"


def notice(stats: dict, days: int) -> str:
    c = counts(stats)
    reds = c["reds"]
    return (f"::notice title=UI history ({days} days)::{sum(reds.values())} group job(s) not green "
            f"({reds['test red']} test red, {reds['no result']} no result, {reds['machinery']} machinery, "
            f"{reds['cancelled']} cancelled); {c['passed on repeat'] + c['inside']} flaky test(s), "
            f"{c['repeats']} simulator repeat(s), over {len(stats['runs'])} of {stats['listed']} runs")


def main(argv: list[str] | None = None, api: Api | None = None, now: datetime.datetime | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--max-calls", type=int, default=MAX_CALLS)
    args = parser.parse_args(argv)
    if api is None:
        token, repo = os.environ.get("GH_TOKEN", ""), os.environ.get("GITHUB_REPOSITORY", "")
        if not token or not repo:
            print("UI history: no GH_TOKEN or GITHUB_REPOSITORY, nothing read")
            return 0
        api = Api(token, repo, args.max_calls)
    now = now or datetime.datetime.now(datetime.timezone.utc)
    stats = collect(api, now - datetime.timedelta(days=args.days))
    try:
        sys.stdout.write(markdown(stats, args.days))
        print(notice(stats, args.days), file=sys.stderr)
    except Exception as error:  # a report never fails the run
        print(f"UI history: no summary ({type(error).__name__}: {str(error)[:200]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
