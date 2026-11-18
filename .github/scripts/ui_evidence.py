"""Which UI groups have to run, and whether every group is green for exactly this app and its own
test code (the owner's rule of 17.11.).

  python3 .github/scripts/ui_evidence.py plan --groups auto|all|"device contrast"
      For ui.yml: writes the job matrix of the groups that run (`matrix`, `count`) to
      $GITHUB_OUTPUT and a table to the job summary. "auto" runs every group that has no usable
      green result for this app fingerprint and its test fingerprint (ui_groups.py); "all" runs
      every group; names run those groups (also when they have a result).
  python3 .github/scripts/ui_evidence.py gate
      For testflight.yml before the upload: exits 1 unless every group's evidence holds (below).
      Writes `text=<one line>` (for the tag message) to $GITHUB_OUTPUT.

Evidence. Every group job of ui.yml carries both fingerprints in its name, for example
"UI device conditions [device app 0123456789ab tests 0123456789ab]" (ui.yml, from the plan).
This script lists the runs of ui.yml and testflight.yml of the last DAYS days (this repository
only, never a fork; at most MAX_RUNS per workflow; always the current run) with all their
attempts, and reads the result of each group job:
  - green: the job succeeded. It counts as evidence only when the fingerprints in its name are
    those of its commit, recomputed here from git (a job of a pull request, which tests GitHub's
    merge commit, counts when the PR head has the same fingerprints).
  - red: the job failed in "Run UI tests" (a test failed, the step timed out, or the runner was
    lost while it ran). The same rule as earlier_attempts.py: it goes by the step.
  - no result: anything else (a cancelled job, a simulator that did not boot, a download or the
    toolchain that failed before the tests ran). Listed, never counted.
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
DAYS = 14
MAX_RUNS = 40
TEST_STEP = "Run UI tests"
JOB_NAME = re.compile(r"\[([a-z0-9-]+) app ([0-9a-f]{12}) tests ([0-9a-f]{12})\]$")


class ApiError(Exception):
    pass


def api(path: str, **params):
    repo = os.environ["GITHUB_REPOSITORY"]
    url = f"{API}/repos/{repo}/{path}" + ("?" + urllib.parse.urlencode(params) if params else "")
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                                   "X-GitHub-Api-Version": "2022-11-28"})
    request.add_unredirected_header("Authorization", f"Bearer {os.environ['GH_TOKEN']}")
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            last = error
            time.sleep(5 * (attempt + 1))
    raise ApiError(f"GitHub API: {path}: {last}")


# ---------------------------------------------------------------------------------------------
# Results of earlier group jobs


def classify(job: dict) -> str:
    """green, red or none (see the top of this file)."""
    steps = {s.get("name"): s for s in job.get("steps") or []}
    test = steps.get(TEST_STEP)
    if job.get("conclusion") == "success":
        return "green" if test and test.get("conclusion") == "success" else "none"
    if job.get("conclusion") == "failure" and test and TEST_STEP in earlier_attempts.failed_steps(job):
        return "red"
    return "none"


def results(runs_and_jobs) -> list[dict]:
    """One entry per group job: group, app, tests (short), result, and where it ran."""
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
            found.append({
                "group": match.group(1), "app": match.group(2), "tests": match.group(3),
                "result": classify(job), "conclusion": job.get("conclusion"),
                "completed_at": job.get("completed_at") or "", "job_id": job.get("id"),
                "url": job.get("html_url", ""), "run_id": run.get("id"), "run_number": run.get("run_number"),
                "attempt": job.get("run_attempt", 1), "workflow": run.get("path", "").rsplit("/", 1)[-1],
                "event": run.get("event", ""), "sha": run.get("head_sha", ""),
            })
    return found


def fetch_history(target_app: str, run_id: int | None, verifier, days: int = DAYS, max_runs: int = MAX_RUNS,
                  call=None, now: datetime | None = None) -> list[tuple[dict, list[dict]]]:
    """[(run, jobs of every attempt)] of ui.yml and testflight.yml. A run of a commit whose app
    fingerprint git can tell is skipped when it differs (no API call for its jobs); pull request
    runs (merge commits) and the current run are always read."""
    call = call or api
    repo = os.environ["GITHUB_REPOSITORY"]
    since = ((now or datetime.now(timezone.utc)) - timedelta(days=days)).strftime("%Y-%m-%d")
    runs = {}
    for workflow in WORKFLOWS:
        answer = call(f"actions/workflows/{workflow}/runs", per_page=100, created=f">={since}")
        listed = [r for r in answer.get("workflow_runs", [])
                  if (r.get("head_repository") or {}).get("full_name") == repo]
        for run in sorted(listed, key=lambda r: r.get("created_at", ""), reverse=True)[:max_runs]:
            runs[run["id"]] = run
    if run_id and run_id not in runs:
        runs[run_id] = call(f"actions/runs/{run_id}")
    history = []
    for run in runs.values():
        if run["id"] != run_id and run.get("event") != "pull_request":
            app = verifier.app(run.get("head_sha", ""))
            if app is not None and app[:ui_groups.SHORT] != target_app[:ui_groups.SHORT]:
                continue
        jobs, page = [], 1
        while True:
            answer = call(f"actions/runs/{run['id']}/jobs", filter="all", per_page=100, page=page)
            jobs += answer.get("jobs", [])
            if len(jobs) >= answer.get("total_count", 0) or not answer.get("jobs"):
                break
            page += 1
        history.append((run, jobs))
    return history


class Verifier:
    """Recomputes the fingerprints of a commit from git (fetching it once when missing)."""

    def __init__(self, cwd: str = ui_groups.ROOT):
        self.cwd, self.cache = cwd, {}

    def _groups(self, sha: str):
        if sha not in self.cache:
            value = None
            if sha and re.fullmatch(r"[0-9a-f]{40}", sha):
                if subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], cwd=self.cwd,
                                  capture_output=True).returncode != 0:
                    subprocess.run(["git", "fetch", "--quiet", "origin", sha], cwd=self.cwd, capture_output=True)
                try:
                    tree = ui_groups.GitTree(sha, self.cwd)
                    app = ui_groups.app_fingerprint(tree)
                    try:
                        groups = ui_groups.Groups(tree).fingerprints()
                    except (ValueError, KeyError):
                        groups = {}
                    value = (app, groups)
                except ValueError:
                    value = None
            self.cache[sha] = value
        return self.cache[sha]

    def app(self, sha: str) -> str | None:
        found = self._groups(sha)
        return found[0] if found else None

    def matches(self, entry: dict) -> bool:
        found = self._groups(entry["sha"])
        if not found:
            return False
        app, groups = found
        return (app[:ui_groups.SHORT] == entry["app"]
                and groups.get(entry["group"], "")[:ui_groups.SHORT] == entry["tests"])


def decide(group: str, app: str, tests: str, entries: list[dict], verifier) -> dict:
    """The state of one group for (app, tests): {"state": green|red|missing, "evidence", "reds",
    "unverified", "older_reds"}."""
    app, tests = app[:ui_groups.SHORT], tests[:ui_groups.SHORT]
    mine = [e for e in entries if e["group"] == group and e["app"] == app and e["tests"] == tests]
    reds = [e for e in mine if e["result"] == "red"]
    greens = [e for e in mine if e["result"] == "green"]
    verified = [e for e in greens if verifier.matches(e)]
    unverified = [e for e in greens if e not in verified]
    older_reds = [e for e in entries if e["group"] == group and e["app"] == app and e["tests"] != tests
                  and e["result"] == "red"]
    newest = max(reds + verified, key=lambda e: e["completed_at"], default=None)
    if reds:
        state = "red"
    elif newest:
        state = "green"
    else:
        state = "missing"
    return {"group": group, "state": state, "evidence": newest if state == "green" else None, "reds": reds,
            "unverified": unverified, "older_reds": older_reds, "app": app, "tests": tests}


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


def current(tree=None):
    tree = tree or ui_groups.GitTree("HEAD")
    groups = ui_groups.Groups(tree)
    return tree, groups, ui_groups.app_fingerprint(tree), groups.fingerprints()


def plan(choice: str, call=None, verifier=None, tree=None) -> int:
    tree, groups, app, fps = current(tree)
    names = groups.names()
    words = choice.split()
    unknown = [w for w in words if w not in names + ["auto", "all"]]
    if unknown or (len(words) > 1 and set(words) & {"auto", "all"}):
        print(f"::error title=UI groups::unknown choice {choice!r}; use auto, all or some of: {' '.join(names)}")
        return 1
    decisions, note = None, ""
    if words in ([], ["auto"]):
        verifier = verifier or Verifier()
        try:
            entries = results(fetch_history(app, None, verifier, call=call))
            decisions = [decide(n, app, fps[n], entries, verifier) for n in names]
            run = [d["group"] for d in decisions if d["state"] != "green"]
        except (ApiError, KeyError) as error:
            run = names
            note = f"Earlier results not readable ({error}): every group runs."
            print(f"::warning title=UI groups::{note}")
    elif words == ["all"]:
        run = names
    else:
        run = [n for n in names if n in words]
    # An empty matrix is an error in GitHub even for a skipped job: a placeholder, never run (the
    # group jobs need the build, which is skipped when count is 0).
    matrix = {"include": [groups.matrix_entry(n, app) for n in run]
              or [{"group": "none", "title": "none", "app": "0" * ui_groups.SHORT, "tests": "0" * ui_groups.SHORT}]}
    print(f"UI_PLAN app {app} tests " + " ".join(f"{n}={fps[n]}" for n in names))
    print(f"UI_PLAN runs: {' '.join(run) or 'nothing'} (choice: {choice or 'auto'})")
    md = [f"### UI groups for app {app[:ui_groups.SHORT]} (choice: {choice or 'auto'})", ""]
    if note:
        md += [note, ""]
    if decisions:
        md.append(table(decisions, set(run)))
        for d in decisions:
            if d["group"] not in run:
                print(f"UI_PLAN reuse {d['group']}: green in {where(d['evidence'])}")
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


def gate(run_id: int | None, call=None, verifier=None, tree=None) -> int:
    tree, groups, app, fps = current(tree)
    verifier = verifier or Verifier()
    try:
        entries = results(fetch_history(app, run_id, verifier, call=call))
    except (ApiError, KeyError) as error:
        print(earlier_attempts.command("error", "UI gate", f"earlier results not readable ({error}); re-run this job"))
        return 1
    decisions = [decide(n, app, fps[n], entries, verifier) for n in groups.names()]
    flaky = flaky_notes(decisions, call)
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
                   if d["state"] == "red" else "no green result for this app and this test code")
            parts.append(f"{d['group']} {d['state']}")
            print(earlier_attempts.command("error", f"UI {d['group']}", why))
    for note in flaky:
        print(earlier_attempts.command("warning", "Flaky in a reused UI group", note))
    md = [f"### UI groups for app {app[:ui_groups.SHORT]}: {'NOT green' if blocked else 'green'}", "", table(decisions)]
    if flaky:
        md += ["Flaky tests in reused results (passed only on a repeat; counted, to be fixed):", ""]
        md += [f"- {n}" for n in flaky] + [""]
    if blocked:
        md.append("**Not uploaded**: every group needs a green result for exactly this app and its own test code, "
                  "and none may be red for that pair.")
    append("GITHUB_STEP_SUMMARY", "\n".join(md) + "\n")
    text = "UI groups: " + "; ".join(parts)
    append("GITHUB_OUTPUT", f"text={' '.join(text.splitlines())[:900]}\n")
    return 1 if blocked else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--groups", default="auto")
    sub.add_parser("gate")
    args = parser.parse_args(argv)
    if args.command == "plan":
        return plan(args.groups.strip())
    run_id = int(os.environ.get("GITHUB_RUN_ID", "0") or 0) or None
    return gate(run_id)


if __name__ == "__main__":
    sys.exit(main())
