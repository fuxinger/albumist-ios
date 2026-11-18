"""Which UI groups have to run, and whether every group is green for exactly this app and its own
test code (the owner's rule of 17.11.).

  python3 .github/scripts/ui_evidence.py plan --groups auto|all|"device contrast" [--quick]
      For ui.yml: writes the job matrix of the groups that run (`matrix`, `count`) to
      $GITHUB_OUTPUT and a table to the job summary. "auto" runs every group that has no usable
      green result for this app fingerprint and its test fingerprint (ui_groups.py); "all" runs
      every group; names run those groups (also when they have a result).
  python3 .github/scripts/ui_evidence.py gate [--quick]
      For testflight.yml before the upload (always full) and the "UI verdict" job of ui.yml:
      exits 1 unless every group's evidence holds (below). Writes `text=<one line>` (for the tag
      message) to $GITHUB_OUTPUT.

Quick mode (--quick, SORTLY_UI_QUICK=1 for the tests; pull requests): a group whose files read
the switch (today device conditions: test11, the large library, skips itself) has another test
fingerprint in a quick run (ui_groups.py). A quick run may take a full green instead of a quick
one; a full check (the TestFlight gate, Release) never takes a quick green.

Evidence. Every group job of ui.yml carries both fingerprints in its name, for example
"UI device conditions [device app 0123456789ab tests 0123456789ab]" (ui.yml, from the plan).
This script lists EVERY run of ui.yml and testflight.yml since this app fingerprint first
existed (this repository only, never a fork; always the current run) with all their attempts,
and reads the result of each group job. "First existed": the oldest commit of any fetched branch
with this app fingerprint, or, for a merge commit with it, the later of the first appearances of
its parents' apps (a pull request's runs test GitHub's merge commit before it is on a branch);
one hour earlier for clock skew. When that window cannot be read completely (more than 1000 runs
of one workflow in it, or older than the run retention of RETENTION_DAYS days), `plan` runs every
group and `gate` fails: an old red must not drop out of sight. A durable record of reds outside
GitHub's run list would need a token that can write from the test runs; not done.
  - green: the job succeeded. It counts as evidence only when the fingerprints in its name are
    those of its commit, recomputed here from git (a job of a pull request, which tests GitHub's
    merge commit, counts when the PR head has the same fingerprints).
  - red: the job ended without passing "Run UI tests" after that step had started (a test
    failed, the step or job timed out, the run was cancelled or the runner lost while it ran).
    The same rule as earlier_attempts.py: it goes by the step, not by the cause.
  - no result: the step never started (a simulator that did not boot, a download, the
    toolchain, a run cancelled before it), a job still running, or a pass in which the
    simulator was lost before any test started (ui_tests.py exits 75 and the job fails in
    "Simulator lost before the first test" instead). Listed, never counted.
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
RETENTION_DAYS = 85   # GitHub keeps runs 90 days by default; older reds may be gone
MAX_LISTED = 1000     # the run list answers at most this many runs for one filter
MAX_JOB_CALLS = 300   # plan only: beyond this, every group runs instead of reading more
TEST_STEP = "Run UI tests"
JOB_NAME = re.compile(r"\[([a-z0-9-]+) app ([0-9a-f]{12}) tests ([0-9a-f]{12})\]$")


class ApiError(Exception):
    pass


class CoverageError(ApiError):
    """The runs since this app first existed cannot all be read."""


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
    if job.get("status") not in (None, "completed"):
        return "none"  # still running
    steps = {s.get("name"): s for s in job.get("steps") or []}
    test = steps.get(TEST_STEP)
    if job.get("conclusion") == "success":
        return "green" if test and test.get("conclusion") == "success" else "none"
    if test and TEST_STEP in earlier_attempts.failed_steps(job):
        return "red"  # started and not passed: failure, timed out, cancelled or lost runner
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


def fetch_history(target_app: str, run_id: int | None, verifier, call=None, now: datetime | None = None,
                  max_job_calls: int | None = None) -> list[tuple[dict, list[dict]]]:
    """[(run, jobs of every attempt)] of ui.yml and testflight.yml since `target_app` first existed
    (verifier.window_start). A run of a commit whose app fingerprint git can tell is skipped when
    it differs (no API call for its jobs); pull request runs (merge commits) and the current run
    are always read. Raises CoverageError when the window cannot be read completely."""
    call = call or api
    repo = os.environ["GITHUB_REPOSITORY"]
    now = now or datetime.now(timezone.utc)
    start = verifier.window_start(target_app)
    if start is None:
        raise CoverageError("no commit with this app fingerprint found in git")
    since = datetime.fromtimestamp(start, timezone.utc) - timedelta(hours=1)
    if since < now - timedelta(days=RETENTION_DAYS):
        raise CoverageError(f"this app exists since {since:%Y-%m-%d}, longer than the run retention "
                            f"({RETENTION_DAYS} days): older red results may be gone")
    runs = {}
    for workflow in WORKFLOWS:
        page, listed = 1, []
        while True:
            answer = call(f"actions/workflows/{workflow}/runs", per_page=100, page=page,
                          created=f">={since:%Y-%m-%dT%H:%M:%SZ}")
            total = answer.get("total_count", 0)
            if total > MAX_LISTED:
                raise CoverageError(f"{total} runs of {workflow} since {since:%Y-%m-%d %H:%M} UTC, "
                                    f"the API lists at most {MAX_LISTED}")
            batch = answer.get("workflow_runs", [])
            listed += batch
            if not batch or len(listed) >= total:
                break
            page += 1
        for run in listed:
            if (run.get("head_repository") or {}).get("full_name") == repo:
                runs[run["id"]] = run
    if run_id and run_id not in runs:
        runs[run_id] = call(f"actions/runs/{run_id}")
    history, job_calls = [], 0
    for run in sorted(runs.values(), key=lambda r: r.get("created_at", ""), reverse=True):
        if run["id"] != run_id and run.get("event") != "pull_request":
            app = verifier.app(run.get("head_sha", ""))
            if app is not None and app[:ui_groups.SHORT] != target_app[:ui_groups.SHORT]:
                continue
        jobs, page = [], 1
        while True:
            job_calls += 1
            if max_job_calls is not None and job_calls > max_job_calls:
                raise CoverageError(f"more than {max_job_calls} job lists to read")
            answer = call(f"actions/runs/{run['id']}/jobs", filter="all", per_page=100, page=page)
            jobs += answer.get("jobs", [])
            if len(jobs) >= answer.get("total_count", 0) or not answer.get("jobs"):
                break
            page += 1
        history.append((run, jobs))
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
            subprocess.run(["git", "fetch", "--quiet", "origin", sha], cwd=self.cwd, capture_output=True)
        return True

    def app(self, sha: str) -> str | None:
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

    def window_start(self, app: str) -> int | None:
        """Unix time from which results for `app` can exist (top of this file)."""
        out = subprocess.run(["git", "log", "--all", "HEAD", "--format=%H %ct %P"], cwd=self.cwd,
                             capture_output=True, text=True)
        if out.returncode != 0:
            return None
        commits = [line.split() for line in out.stdout.splitlines() if line.strip()]
        first: dict[str, int] = {}
        for sha, ct, *_ in commits:
            fp = self.app(sha)
            if fp:
                first[fp] = min(first.get(fp, int(ct)), int(ct))
        starts = []
        for sha, ct, *parents in commits:
            if self.app(sha) != app:
                continue
            starts.append(int(ct))
            if len(parents) > 1 and all(self.app(p) in first for p in parents):
                # A merge (GitHub's merge commit of a pull request, tested before it lands)
                # holds the app of both sides: it cannot exist before the later of them.
                starts.append(max(first[self.app(p)] for p in parents))
        return min(starts, default=None)

    def changed_since(self, sha: str) -> list[str] | None:
        if not self._have(sha):
            return None
        try:
            return ui_groups.changed_files(sha, "HEAD", self.cwd)
        except ValueError:
            return None


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


def decide_mode(group: str, app: str, groups, entries: list[dict], verifier, quick: bool) -> dict:
    """decide() for the run's mode: a full check takes full results only; a quick one its quick
    result or, when that is not green, a full green (it ran more)."""
    full = groups.fingerprint(group)
    if not quick:
        return decide(group, app, full, entries, verifier)
    fast = groups.fingerprint(group, quick=True)
    found = decide(group, app, fast, entries, verifier)
    if fast == full or found["state"] == "green":
        return found
    instead = decide(group, app, full, entries, verifier)
    return instead if instead["state"] == "green" else found


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


def current(tree=None):
    tree = tree or ui_groups.GitTree("HEAD")
    groups = ui_groups.Groups(tree)
    return tree, groups, ui_groups.app_fingerprint(tree)


def plan(choice: str, call=None, verifier=None, tree=None, quick: bool = False) -> int:
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
        try:
            entries = results(fetch_history(app, None, verifier, call=call, max_job_calls=MAX_JOB_CALLS))
            decisions = [decide_mode(n, app, groups, entries, verifier, quick) for n in names]
            run = [d["group"] for d in decisions if d["state"] != "green"]
        except (ApiError, KeyError) as error:
            run = names
            note = f"Earlier results not readable completely ({error}): every group runs."
            print(f"::warning title=UI groups::{note}")
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


def gate(run_id: int | None, call=None, verifier=None, tree=None, quick: bool = False) -> int:
    tree, groups, app = current(tree)
    verifier = verifier or Verifier()
    mode = "quick" if quick else "full"
    try:
        entries = results(fetch_history(app, run_id, verifier, call=call))
    except (ApiError, KeyError) as error:
        print(earlier_attempts.command("error", "UI gate", f"earlier results not readable completely ({error}); "
                                       "re-run this job when the API answers"))
        return 1
    decisions = [decide_mode(n, app, groups, entries, verifier, quick) for n in groups.names()]
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
    md = [f"### UI groups for app {app[:ui_groups.SHORT]} ({mode}): {'NOT green' if blocked else 'green'}", "",
          table(decisions)]
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
    text = f"UI groups ({mode}): " + "; ".join(parts)
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
    args = parser.parse_args(argv)
    if args.command == "plan":
        return plan(args.groups.strip(), quick=args.quick)
    run_id = int(os.environ.get("GITHUB_RUN_ID", "0") or 0) or None
    return gate(run_id, quick=args.quick)


if __name__ == "__main__":
    sys.exit(main())
