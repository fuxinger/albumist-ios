"""Which UI groups have to run, and whether every group is green for exactly this app and its own
test code (the owner's rule of 17.11.).

  python3 .github/scripts/ui_evidence.py plan --groups auto|all|"device contrast" [--quick]
      For ui.yml: writes the job matrix of the groups that run (`matrix`, `count`) to
      $GITHUB_OUTPUT and a table to the job summary. "auto" runs every group that has no usable
      green result for this app fingerprint and its test fingerprint (ui_groups.py); "all" runs
      every group; names run those groups (also when they have a result).
  python3 .github/scripts/ui_evidence.py gate [--quick] [--groups "flow-full contrast"]
      For testflight.yml before the upload (always full) and the "UI verdict" job of ui.yml:
      exits 1 unless every group's evidence holds (below). Writes `text=<one line>` (for the tag
      message) to $GITHUB_OUTPUT. --groups checks only the named groups: the small gate of the
      daily TestFlight build (testflight.yml, gate small; the owner's decision 10 of 18.11.2026).
      The rules per group are the same; the groups left out are named in the summary and the
      text as not checked.

Quick mode (--quick; pull requests): the tests get SORTLY_UI_QUICK=1, and
DeviceConditionUITests.test11_LargeLibrary (about 25 min) skips itself (XCTSkip). Every group
has another test fingerprint in a quick run (ui_groups.py adds the mode for all, also where no
file visibly reads the switch). A quick check may take a full green instead of a quick one; a
full check (the TestFlight gate, the "UI verdict (full)" job that Release needs) never takes a
quick green. A red blocks under both keys of the current test code, in both modes.

Evidence. Every group job of ui.yml carries both fingerprints in its name, for example
"UI device conditions [device app 0123456789ab tests 0123456789ab]" (ui.yml, from the plan).
This script lists EVERY run of ui.yml and testflight.yml of the last HISTORY_DAYS days (GitHub's
run retention; none before FINGERPRINTS_SINCE, when the names came), this repository only,
never a fork, always the current run, with all their attempts, and reads each group job. Not
from commit dates: a red on a commit that was rebased, amended or whose branch was deleted
stays in sight. A time range with more runs than the API lists for one filter is split. Jobs
are read for every run whose tested commit may have this app: the commit has it, or git does
not know the commit (then its reds count, its greens cannot be checked and do not). The tested
commit of a pull request run is the merge commit named in its run-name ("[merge <sha>] ...",
ui.yml). Runs of this app with only older test code of every group are read last, while calls
are left (RESERVED_CALLS stay for logs and annotations): only the "red with older test code"
listing needs them. Each invocation may make MAX_CALLS API calls (GITHUB_TOKEN: 1000 per hour
for the repository); beyond, `plan` runs every group and `gate` fails. That lock-out needs
more than about 200 runs in 90 days whose commit has this app AND the current test code of a
group (or a commit git cannot find), plus the run listing (100 runs per call): change the app
or raise MAX_CALLS then. A cache of parsed results (an artifact) would lift it; not done. A durable record of reds outside
GitHub's run list would need a token that can write from the test runs; not done.
  - green: the job succeeded. It counts as evidence only when the fingerprints in its name are
    those of the commit it tested, recomputed here from git.
  - red: the job did not pass "Run UI tests" after that step had started, and its log shows a
    test result that failed: ui_tests.py's last line "UI_RESULT <group> fail" (a hang past the
    pass deadline is one), or without it a failed test case (echoed live as UI_LIVE, so also
    before a cancel) or a failing UI_VERDICT; or the job was cancelled after its full time
    limit. A log that cannot be read is red: GitHub deletes logs (HTTP 410) with the run or
    earlier, and such a red then stays until the app or the test changes.
  - no result: the step never started (a simulator that did not boot, a download, the
    toolchain, a run cancelled before it); a job still running; a cancel or a lost runner while
    the tests ran with nothing failed in the log (the owner's rule: never cancel a running test
    run); every pass failed on the simulator or XCTest alone (ui_tests.py exits 75, "UI_RESULT
    <group> infra", and the job fails in "No test result (...)" instead). Listed, never counted.
A group is green for this app when its newest result for (app fingerprint, group, test
fingerprint) is green AND there is no red result for that key at all. Both rules together:
  - a group whose test files, shared helpers or definition changed has a new test fingerprint
    and must have run on that code;
  - any app change gives a new app fingerprint: everything must run;
  - a red result is never made green by running the same app and the same test code again,
    in this run (earlier_attempts.py) or in another run (here): the same key stays red until
    the app or the test changes, i.e. until a fix. The red run stays listed in the summary.
In `plan` a group with such a red runs again when asked (auto runs it too), so its result is
seen, but the gate does not take that green.

Fails safe: when the API does not answer, `plan` runs every group and `gate` fails (re-run the
gate job then).

Environment: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_API_URL, GITHUB_OUTPUT,
GITHUB_STEP_SUMMARY.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import earlier_attempts  # noqa: E402
import ui_groups  # noqa: E402

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
WORKFLOWS = ("ui.yml", "testflight.yml")
HISTORY_DAYS = 90     # GitHub's default run retention: older runs (and their reds) are gone
# No group job carries fingerprints in its name before this (they came with ui_evidence.py).
FINGERPRINTS_SINCE = datetime(2026, 11, 18, tzinfo=timezone.utc)
MAX_LISTED = 1000     # the run list answers at most this many runs for one filter: split the range
# API calls per invocation (plan or gate). GITHUB_TOKEN may make 1000 requests per hour in this
# repository, shared by all jobs; a UI run makes two invocations. Beyond it: `plan` runs every
# group, `gate` fails. Each invocation prints UI_API_CALLS.
MAX_CALLS = 300
TEST_STEP = "Run UI tests"
JOB_NAME = re.compile(r"\[([a-z0-9-]+) app ([0-9a-f]{12}) tests ([0-9a-f]{12})\]$")
# ui.yml's run-name of a pull request run starts with the merge commit it tests.
MERGE = re.compile(r"^\[merge ([0-9a-f]{40})\]")
# timeout-minutes of ui.yml's group jobs (test_workflows.py checks it): a job that did not
# succeed after running this long was stopped by its time limit, which is red (a hang), log or not.
GROUP_TIMEOUT_MINUTES = 150
# Of the calls, this many are kept for the logs of reds and the annotations of reused greens:
# runs that only hold older test code of this app are read only while more are left.
RESERVED_CALLS = 60
# A job that did not pass "Run UI tests" is red only when its log shows a test result: the last
# "UI_RESULT <its group> fail" line of ui_tests.py (at the start of a log line, after GitHub's
# timestamp), or without such a line a failed test case or an error line (also echoed live,
# UI_LIVE, before a cancel: a test with continueAfterFailure that had not ended yet), a failing
# verdict of older logs, or the job's time limit (also ran_out_of_time). A
# cancel or a lost runner in the middle of the tests with nothing failed yet: no result (the
# owner's rule is anyway never to cancel a running test run). An unreadable log (also an
# expired one, HTTP 410) counts as red, so such a red stays for good.
RESULT_LINE = re.compile(r"^(?:\ufeff)?(?:\d{4}-\d\d-\d\dT[\d:.]+Z )?UI_RESULT (\S+) (pass|fail|infra)\s*$", re.M)
RED_IN_LOG = re.compile(r"Test Case '-\[[^\]]+\]' failed|UI_LIVE .*: error: -\[|UI_VERDICT \S+ (?:first|retry): fail|the failed pass stays red"
                        r"|has exceeded the maximum execution time")


class ApiError(Exception):
    pass


class CoverageError(ApiError):
    """The runs that may hold results for this app cannot all be read."""


def api(path: str, **params):
    """JSON of a REST call; text for a job log (".../logs", which redirects to the file)."""
    repo = os.environ["GITHUB_REPOSITORY"]
    url = f"{API}/repos/{repo}/{path}" + ("?" + urllib.parse.urlencode(params) if params else "")
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                                   "X-GitHub-Api-Version": "2022-11-28"})
    # Not sent on to the redirect (the log file's signed URL takes no token).
    request.add_unredirected_header("Authorization", f"Bearer {os.environ['GH_TOKEN']}")
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                if path.endswith("/logs"):
                    return response.read().decode("utf-8", errors="replace")
                return json.load(response)
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            last = error
            if isinstance(error, urllib.error.HTTPError) and error.code in (404, 410):
                break  # gone (an expired log): no use asking again
            time.sleep(5 * (attempt + 1))
    raise ApiError(f"GitHub API: {path}: {last}")


def counted(call, limit: int | None = None):
    """`call` with a counter (.count) that raises CoverageError beyond `limit` (MAX_CALLS) calls."""
    def wrapped(path, **params):
        wrapped.count += 1
        top = MAX_CALLS if limit is None else limit
        if wrapped.count > top:
            raise CoverageError(f"more than {top} API calls needed")
        return call(path, **params)
    wrapped.count = 0
    return wrapped


# ---------------------------------------------------------------------------------------------
# Results of earlier group jobs


def classify(job: dict) -> str:
    """green, red or none (see the top of this file); "red" here is confirmed from the log by
    results()."""
    if job.get("status") not in (None, "completed"):
        return "none"  # still running
    steps = {s.get("name"): s for s in job.get("steps") or []}
    test = steps.get(TEST_STEP)
    if job.get("conclusion") == "success":
        return "green" if test and test.get("conclusion") == "success" else "none"
    if test and TEST_STEP in earlier_attempts.failed_steps(job):
        return "red"  # started and not passed; results() reads the log
    return "none"


def red_in_log(log: str | None, group: str) -> bool:
    """Whether a job log shows a test result that is red. The last UI_RESULT line of ui_tests.py
    for this group decides when there is one (so a testmanagerd crash in every pass is no result,
    though a test case "failed" in it); otherwise the markers of RED_IN_LOG (a failure echoed
    while the pass ran, UI_LIVE, then a cancel; older logs). An unreadable log is red."""
    if log is None:
        return True
    verdicts = [v for g, v in RESULT_LINE.findall(log) if g == group]
    if verdicts:
        return verdicts[-1] == "fail"
    return bool(RED_IN_LOG.search(log))


def ran_out_of_time(job: dict) -> bool:
    """A job that did not succeed after running GROUP_TIMEOUT_MINUTES: GitHub's time limit
    stopped it (the log says only "The operation was canceled")."""
    try:
        start = datetime.fromisoformat(job["started_at"].replace("Z", "+00:00"))
        end = datetime.fromisoformat(job["completed_at"].replace("Z", "+00:00"))
    except (KeyError, AttributeError, TypeError, ValueError):
        return False
    return job.get("conclusion") != "success" and end - start >= timedelta(minutes=GROUP_TIMEOUT_MINUTES - 1)


def results(runs_and_jobs, logs=None) -> list[dict]:
    """One entry per group job: group, app, tests (short), result, and where it ran. `logs`
    (job id -> log text or None) confirms a red; without it a red stays red."""
    found, seen = [], set()
    for run, jobs in runs_and_jobs:
        for job in jobs:
            match = JOB_NAME.search(job.get("name", ""))
            # "Re-run failed jobs" carries a finished job over into the next attempt (same name,
            # start and end): counted once.
            key = (run.get("id"), job.get("name"), job.get("started_at"), job.get("completed_at"))
            if not match or job.get("id") in seen or (job.get("completed_at") and key in seen):
                continue
            seen.update({job.get("id"), key})
            result = classify(job)
            if (result == "red" and logs is not None and not ran_out_of_time(job)
                    and not red_in_log(logs(job.get("id")), match.group(1))):
                result = "none"  # stopped during the tests without a test result (a cancel)
            found.append({
                "group": match.group(1), "app": match.group(2), "tests": match.group(3),
                "result": result, "conclusion": job.get("conclusion"),
                "completed_at": job.get("completed_at") or "", "job_id": job.get("id"),
                "url": job.get("html_url", ""), "run_id": run.get("id"), "run_number": run.get("run_number"),
                "attempt": job.get("run_attempt", 1), "workflow": run.get("path", "").rsplit("/", 1)[-1],
                "event": run.get("event", ""), "sha": tested_sha(run) or run.get("head_sha", ""),
            })
    return found


def log_reader(call):
    """job id -> its log, None when it cannot be read (then a red stays red)."""
    def read(job_id):
        try:
            text = call(f"actions/jobs/{job_id}/logs")
        except CoverageError:
            raise
        except ApiError:
            return None
        return text if isinstance(text, str) else None
    return read


def tested_sha(run: dict) -> str | None:
    """The commit a run tested: for a pull request the merge commit from its run-name (ui.yml),
    None when the name does not carry it (an older run); else head_sha."""
    if run.get("event") == "pull_request":
        match = MERGE.search(run.get("display_title") or "")
        return match.group(1) if match else None
    return run.get("head_sha")


def _stamp(moment: datetime) -> str:
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def list_runs(call, workflow: str, start: datetime, end: datetime) -> list[dict]:
    """Every run of `workflow` created in [start, end]; a range that holds more than the API
    lists for one filter is split in two (C: never a lock-out by volume)."""
    created = f"{_stamp(start)}..{_stamp(end)}"
    answer = call(f"actions/workflows/{workflow}/runs", per_page=100, page=1, created=created)
    total = answer.get("total_count", 0)
    if total > MAX_LISTED:
        if end - start < timedelta(seconds=2):
            raise CoverageError(f"{total} runs of {workflow} created within one second")
        middle = start + (end - start) / 2
        middle = middle.replace(microsecond=0)
        return list_runs(call, workflow, start, middle) + list_runs(call, workflow, middle + timedelta(seconds=1), end)
    found = {r["id"]: r for r in answer.get("workflow_runs", [])}
    page = 1
    while len(found) < total and answer.get("workflow_runs"):
        page += 1
        answer = call(f"actions/workflows/{workflow}/runs", per_page=100, page=page, created=created)
        found.update({r["id"]: r for r in answer.get("workflow_runs", [])})
    return list(found.values())


def job_list(call, run: dict) -> list[dict]:
    """The jobs of every attempt of a run. Each run is read once per invocation (runs are kept by
    id), and only when its commit may have this app: that is what keeps the calls in budget."""
    jobs, page = [], 1
    while True:
        answer = call(f"actions/runs/{run['id']}/jobs", filter="all", per_page=100, page=page)
        jobs += answer.get("jobs", [])
        if len(jobs) >= answer.get("total_count", 0) or not answer.get("jobs"):
            break
        page += 1
    return jobs


def fetch_history(target_app: str, run_id: int | None, verifier, call=None,
                  now: datetime | None = None, keys: set[str] | None = None,
                  info: dict | None = None) -> list[tuple[dict, list[dict]]]:
    """[(run, jobs of every attempt)] of ui.yml and testflight.yml of the last HISTORY_DAYS days
    (since FINGERPRINTS_SINCE at most), this repository only, the current run always. A run whose
    tested commit git can tell is skipped when its app fingerprint differs (no call for its
    jobs); a run whose commit is unknown (rebased away, an older pull request run) is read."""
    call = call if hasattr(call, "count") else counted(call or api)
    repo = os.environ["GITHUB_REPOSITORY"]
    now = (now or datetime.now(timezone.utc)).replace(microsecond=0)
    start = max(now - timedelta(days=HISTORY_DAYS), FINGERPRINTS_SINCE)
    runs = {}
    for workflow in WORKFLOWS:
        for run in list_runs(call, workflow, start, now + timedelta(hours=1)):
            if (run.get("head_repository") or {}).get("full_name") == repo:
                runs[run["id"]] = run
    if run_id and run_id not in runs:
        runs[run_id] = call(f"actions/runs/{run_id}")
    # Must read: the current run, runs whose commit git does not know, and runs whose commit has
    # this app and the test code of one of the groups now (`keys`: their short test fingerprints,
    # full and quick). May read: runs of this app with only older test code (their reds are
    # listed, "red with older test code", and feed the "cleared by a shared change" warning),
    # newest first while calls are left.
    must, may = [], []
    for run in sorted(runs.values(), key=lambda r: r.get("created_at", ""), reverse=True):
        sha = tested_sha(run) if run["id"] != run_id else None
        app = verifier.app(sha) if sha else None
        if run["id"] == run_id or app is None:
            must.append(run)
        elif app[:ui_groups.SHORT] != target_app[:ui_groups.SHORT]:
            continue
        elif keys is None or verifier.test_keys(sha) & keys:
            must.append(run)
        else:
            may.append(run)
    history = [(run, job_list(call, run)) for run in must]
    skipped = 0
    for run in may:
        if call.count >= MAX_CALLS - RESERVED_CALLS:
            skipped += 1
            continue
        history.append((run, job_list(call, run)))
    if info is not None:
        info["older_skipped"] = skipped
    return history


class Verifier:
    """Recomputes the fingerprints of commits from git (fetching a missing one once)."""

    def __init__(self, cwd: str = ui_groups.ROOT):
        self.cwd, self.cache, self.apps = cwd, {}, {}

    def _have(self, sha: str) -> bool:
        if not (sha and re.fullmatch(r"[0-9a-f]{40}", sha)):
            return False
        if subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], cwd=self.cwd,
                          capture_output=True).returncode != 0:
            subprocess.run(["git", "fetch", "--quiet", "--no-tags", "origin", sha], cwd=self.cwd, capture_output=True)
        return True

    def app(self, sha: str) -> str | None:
        """The app fingerprint of a commit, None when git cannot read it."""
        if sha not in self.apps:
            try:
                self.apps[sha] = ui_groups.app_fingerprint(ui_groups.GitTree(sha, self.cwd)) if self._have(sha) else None
            except ValueError:
                self.apps[sha] = None
        return self.apps[sha]

    def _groups(self, sha: str):
        """(app, {group: full fingerprint}, {group: quick fingerprint}) of a commit, or None."""
        if sha not in self.cache:
            value = None
            app = self.app(sha)
            if app:
                try:
                    groups = ui_groups.Groups(ui_groups.GitTree(sha, self.cwd))
                    value = (app, groups.fingerprints(), groups.fingerprints(quick=True))
                except (ValueError, KeyError):
                    value = (app, {}, {})
            self.cache[sha] = value
        return self.cache[sha]

    def matches(self, entry: dict) -> bool:
        found = self._groups(entry["sha"])
        if not found:
            return False
        app, full, quick = found
        keys = {full.get(entry["group"], "")[:ui_groups.SHORT], quick.get(entry["group"], "")[:ui_groups.SHORT]}
        return app[:ui_groups.SHORT] == entry["app"] and entry["tests"] in keys - {""}

    def test_keys(self, sha: str) -> set[str]:
        """The short test fingerprints (full and quick) of every group of a commit."""
        found = self._groups(sha)
        if not found:
            return set()
        return {v[:ui_groups.SHORT] for fps in found[1:] for v in fps.values()}

    def changed_since(self, sha: str) -> list[str] | None:
        if not self._have(sha):
            return None
        try:
            return ui_groups.changed_files(sha, "HEAD", self.cwd)
        except ValueError:
            return None


def decide(group: str, app: str, tests: str, entries: list[dict], verifier, accept=None, block=None) -> dict:
    """The state of one group for (app, tests): {"state": green|red|missing, "evidence", "reds",
    "unverified", "older_reds"}. Greens count under the keys in `accept` (default: tests), reds
    under those and the keys in `block`."""
    short = ui_groups.SHORT
    app, tests = app[:short], tests[:short]
    accept = {k[:short] for k in (accept or [tests])}
    block = accept | {k[:short] for k in (block or [])}
    mine = [e for e in entries if e["group"] == group and e["app"] == app]
    reds = [e for e in mine if e["result"] == "red" and e["tests"] in block]
    greens = [e for e in mine if e["result"] == "green" and e["tests"] in accept]
    verified = [e for e in greens if verifier.matches(e)]
    unverified = [e for e in greens if e not in verified]
    older_reds = [e for e in mine if e["result"] == "red" and e["tests"] not in block]
    newest = max(reds + verified, key=lambda e: e["completed_at"], default=None)
    if reds:
        state = "red"
    elif newest:
        state = "green"
    else:
        state = "missing"
    return {"group": group, "state": state, "evidence": newest if state == "green" else None, "reds": reds,
            "unverified": unverified, "older_reds": older_reds, "app": app, "tests": tests}


def decide_mode(group: str, app: str, groups, entries: list[dict], verifier, quick: bool) -> dict:
    """decide() for the run's mode. A red under the group's full or quick key of this tree blocks
    in both modes (the same test code failed, whatever the mode). A full check takes full greens
    only; a quick one a quick or a full green (a full run ran more)."""
    full, fast = groups.fingerprint(group), groups.fingerprint(group, quick=True)
    if quick:
        return decide(group, app, fast, entries, verifier, accept=[fast, full], block=[full])
    return decide(group, app, full, entries, verifier, accept=[full], block=[fast])


def cleared_notes(decisions: list[dict], groups, verifier) -> list[str]:
    """Groups that were red for this app with older test code and are not red now, where none of
    their own test files changed since that red, only files they share with others (a helper, the
    harness, a workflow): worth a look that this really was the fix."""
    notes = []
    for d in decisions:
        if d["state"] == "red" or not d["older_reds"]:
            continue
        red = max(d["older_reds"], key=lambda e: e["completed_at"])
        changed = verifier.changed_since(red["sha"])
        if changed is None:
            continue
        mine = set(groups.files_of(d["group"]))
        touched = [c for c in changed if c in mine]
        if touched and not set(touched) & groups.own_files(d["group"]):
            notes.append(f"{d['group']}: red for this app in run {red['run_id']} ({red['sha'][:7]}); since then only "
                         f"shared files changed ({', '.join(touched[:6])}), none of its own test files")
    return notes


# ---------------------------------------------------------------------------------------------
# Reports


def where(entry: dict) -> str:
    return (f"[run {entry['run_id']} attempt {entry['attempt']}]({entry['url']}) "
            f"({entry['workflow']}, {entry['event']}, {entry['sha'][:7]})")


def table(decisions: list[dict], running: set[str] | None = None) -> str:
    rows = ["| Group | App | Tests | State | Evidence | Red for this key | Red with older test code |",
            "|---|---|---|---|---|---|---|"]
    for d in decisions:
        if running is not None and d["group"] in running:
            state = "runs now" + (" (red before for this key: its green will not count)" if d["state"] == "red" else "")
        else:
            state = {"green": "green", "red": "RED", "missing": "no result"}[d["state"]]
        evidence = where(d["evidence"]) if d["evidence"] else "-"
        if d["unverified"]:
            evidence += f"; {len(d['unverified'])} green job(s) whose name does not match its commit, not counted"
        rows.append(f"| {d['group']} | {d['app']} | {d['tests']} | {state} | {evidence} | "
                    f"{', '.join(where(e) for e in d['reds']) or '-'} | "
                    f"{', '.join(where(e) for e in d['older_reds']) or '-'} |")
    return "\n".join(rows) + "\n"


def append(variable: str, text: str) -> None:
    with open(os.environ.get(variable, os.devnull), "a", encoding="utf-8") as out:
        out.write(text)


def flaky_notes(decisions: list[dict], call=None) -> list[str]:
    """Flaky warnings (ui_tests.py: tests that passed only on a repeat) of reused evidence jobs,
    read from their annotations, so a reused green does not hide them."""
    call = call or api
    notes = []
    for d in decisions:
        e = d["evidence"]
        if not e:
            continue
        try:
            annotations = call(f"check-runs/{e['job_id']}/annotations", per_page=100)
        except ApiError:
            notes.append(f"{d['group']}: annotations of run {e['run_id']} not readable; see its summary")
            continue
        for a in annotations if isinstance(annotations, list) else []:
            title = a.get("title") or ""
            if "flaky" in title.lower() or "FLAKY" in (a.get("message") or ""):
                notes.append(f"{d['group']} (run {e['run_id']}): {title}: {(a.get('message') or '')[:300]}")
    return notes


# ---------------------------------------------------------------------------------------------
# Commands


def keys(groups) -> set[str]:
    """The short test fingerprints, full and quick, of every group of this tree."""
    return {fp[:ui_groups.SHORT] for quick in (False, True) for fp in groups.fingerprints(quick).values()}


def current(tree=None):
    tree = tree or ui_groups.GitTree("HEAD")
    groups = ui_groups.Groups(tree)
    return tree, groups, ui_groups.app_fingerprint(tree)


def plan(choice: str, call=None, verifier=None, tree=None, quick: bool = False, now: datetime | None = None) -> int:
    tree, groups, app = current(tree)
    names = groups.names()
    fps = groups.fingerprints(quick)
    words = choice.split()
    unknown = [w for w in words if w not in names + ["auto", "all"]]
    if unknown or (len(words) > 1 and set(words) & {"auto", "all"}):
        print(f"::error title=UI groups::unknown choice {choice!r}; use auto, all or some of: {' '.join(names)}")
        return 1
    decisions, note = None, ""
    mode = "quick" if quick else "full"
    if words in ([], ["auto"]):
        verifier = verifier or Verifier()
        call = counted(call or api)
        try:
            info = {}
            entries = results(fetch_history(app, None, verifier, call=call, now=now, keys=keys(groups), info=info),
                              logs=log_reader(call))
            if info.get("older_skipped"):
                print(f"UI_PLAN {info['older_skipped']} run(s) with only older test code of this app not read "
                      "(call budget); their reds are not listed")
            decisions = [decide_mode(n, app, groups, entries, verifier, quick) for n in names]
            run = [d["group"] for d in decisions if d["state"] != "green"]
        except (ApiError, KeyError) as error:
            run = names
            note = f"Earlier results not readable completely ({error}): every group runs."
            print(f"::warning title=UI groups::{note}")
        print(f"UI_API_CALLS {call.count} (budget {MAX_CALLS})")
    elif words == ["all"]:
        run = names
    else:
        run = [n for n in names if n in words]
    # An empty matrix is an error in GitHub even for a skipped job: a placeholder, never run (the
    # group jobs need the build, which is skipped when count is 0).
    matrix = {"include": [groups.matrix_entry(n, app, quick) for n in run]
              or [{"group": "none", "title": "none", "app": "0" * ui_groups.SHORT, "tests": "0" * ui_groups.SHORT}]}
    print(f"UI_PLAN app {app} {mode} tests " + " ".join(f"{n}={fps[n]}" for n in names))
    print(f"UI_PLAN runs: {' '.join(run) or 'nothing'} (choice: {choice or 'auto'}, {mode})")
    md = [f"### UI groups for app {app[:ui_groups.SHORT]} (choice: {choice or 'auto'}, {mode})", ""]
    if note:
        md += [note, ""]
    if decisions:
        md.append(table(decisions, set(run)))
        for d in decisions:
            if d["group"] not in run:
                print(f"UI_PLAN reuse {d['group']}: green in {where(d['evidence'])}")
        for text in cleared_notes(decisions, groups, verifier):
            print(earlier_attempts.command("warning", "UI red cleared by a shared change", text))
            md += [f"- Check: {text}"]
    else:
        md.append("Runs: " + (", ".join(run) or "nothing"))
    left = [n for n in names if n not in run]
    if left and decisions:
        md += ["", f"Not run again: {', '.join(left)} (green for this app and their own test code; the gate "
               "of a TestFlight run checks that again)."]
    elif left:
        md += ["", f"Not chosen: {', '.join(left)}."]
    append("GITHUB_STEP_SUMMARY", "\n".join(md) + "\n")
    append("GITHUB_OUTPUT", f"matrix={json.dumps(matrix, separators=(',', ':'))}\ncount={len(run)}\n")
    return 0


def gate(run_id: int | None, call=None, verifier=None, tree=None, quick: bool = False,
         now: datetime | None = None, only: str = "") -> int:
    tree, groups, app = current(tree)
    names = groups.names()
    chosen = only.split()
    unknown = [w for w in chosen if w not in names]
    if unknown:
        print(earlier_attempts.command("error", "UI gate", f"unknown group(s) {' '.join(unknown)}; "
                                       f"use some of: {' '.join(names)}"))
        return 1
    checked = [n for n in names if n in chosen] if chosen else names
    left_out = [n for n in names if n not in checked]
    verifier = verifier or Verifier()
    mode = "quick" if quick else "full"
    scope = f"{mode}, only {' '.join(checked)}" if left_out else mode
    call = counted(call or api)
    try:
        info = {}
        entries = results(fetch_history(app, run_id, verifier, call=call, now=now, keys=keys(groups), info=info),
                          logs=log_reader(call))
        if info.get("older_skipped"):
            print(earlier_attempts.command("notice", "UI gate", f"{info['older_skipped']} run(s) with only older "
                                           "test code of this app not read (call budget); the warning 'UI red cleared "
                                           "by a shared change' may miss them"))
    except (ApiError, KeyError) as error:
        print(f"UI_API_CALLS {call.count} (budget {MAX_CALLS})")
        print(earlier_attempts.command("error", "UI gate", f"earlier results not readable completely ({error}); "
                                       "re-run this job when the API answers"))
        return 1
    print(f"UI_API_CALLS {call.count} (budget {MAX_CALLS})")
    decisions = [decide_mode(n, app, groups, entries, verifier, quick) for n in checked]
    flaky = flaky_notes(decisions, call)
    cleared = cleared_notes(decisions, groups, verifier)
    parts, blocked = [], False
    for d in decisions:
        if d["state"] == "green":
            e = d["evidence"]
            here = e["run_id"] == run_id
            parts.append(f"{d['group']} {'here' if here else 'reused from run %s (%s)' % (e['run_id'], e['sha'][:7])}")
            if not here:
                print(earlier_attempts.command("notice", f"UI {d['group']} reused",
                                               f"green for this app and test code in {e['url']}"))
        else:
            blocked = True
            why = ("red for this app and this test code in " + ", ".join(e["url"] for e in d["reds"])
                   + ". A red test is never re-run to green: fix it (the test or the app changes) and start a new run."
                   if d["state"] == "red" else f"no green {mode} result for this app and this test code")
            parts.append(f"{d['group']} {d['state']}")
            print(earlier_attempts.command("error", f"UI {d['group']}", why))
    for note in flaky:
        print(earlier_attempts.command("warning", "Flaky in a reused UI group", note))
    for note in cleared:
        print(earlier_attempts.command("warning", "UI red cleared by a shared change", note))
    md = [f"### UI groups for app {app[:ui_groups.SHORT]} ({scope}): {'NOT green' if blocked else 'green'}", "",
          table(decisions)]
    if left_out:
        md += [f"Not checked by this gate: {', '.join(left_out)}.", ""]
    if flaky:
        md += ["Flaky tests in reused results (passed only on a repeat; counted, to be fixed):", ""]
        md += [f"- {n}" for n in flaky] + [""]
    if cleared:
        md += ["Red with older test code, cleared only by shared files (check that this was the fix):", ""]
        md += [f"- {n}" for n in cleared] + [""]
    if blocked:
        md.append(f"**Not green** (no upload, no release): every group needs a green {mode} result for exactly this "
                  "app and its own test code, and none may be red for that pair.")
    append("GITHUB_STEP_SUMMARY", "\n".join(md) + "\n")
    text = f"UI groups ({scope}): " + "; ".join(parts)
    if left_out:
        text += f"; not checked: {' '.join(left_out)}"
    append("GITHUB_OUTPUT", f"text={' '.join(text.splitlines())[:900]}\n")
    return 1 if blocked else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--groups", default="auto")
    p.add_argument("--quick", action="store_true", help="a quick run (SORTLY_UI_QUICK=1)")
    g = sub.add_parser("gate")
    g.add_argument("--quick", action="store_true", help="the verdict of a quick run; never for an upload")
    g.add_argument("--groups", default="", help="check only these groups (the small gate of the daily build)")
    args = parser.parse_args(argv)
    if args.command == "plan":
        return plan(args.groups.strip(), quick=args.quick)
    run_id = int(os.environ.get("GITHUB_RUN_ID", "0") or 0) or None
    return gate(run_id, quick=args.quick, only=args.groups)


if __name__ == "__main__":
    sys.exit(main())
