"""Waits until the tests of one commit are finished and says whether they are green.

Used before a release tag (release.yml, without waiting). Green means:
  1. The newest CI run (ci.yml) for exactly this commit succeeded, and the job
     "iOS build and tests (macOS)" really ran and succeeded in it or in an earlier run of the
     same commit. When it was skipped everywhere (only documentation changed since the last
     tested commit), there is nothing new to ship.
  2. The newest UI flow run (ui.yml) for exactly this commit succeeded too. Always: a commit
     without a UI flow run is not green (owner decision 16.11.), so nothing is released that
     never ran the UI tests. ui.yml runs for pull requests (on the PR's head
     commit); a commit that never was a PR head, e.g. a merge commit pushed to main, needs a
     manual "UI flow" run on that commit first. Since 18.11. such a run (groups "auto") only
     runs the groups that have no green result yet for exactly this app and their own test
     code (ui_evidence.py), so for a merge commit with an already tested app it takes minutes.
     Since 19.11. the run must also have a green job "UI verdict (full)": its check
     (ui_evidence.py gate) says every group is green, in full mode, for this app and its own
     test code and none is red for that pair. A run whose verdict is "quick" (every pull
     request; the long device test skips itself) never counts: the newest full run decides,
     and a commit with quick runs only needs a full "UI flow" run by hand (only the groups
     whose quick and full test code differ run then).

TestFlight does not use this gate since 17.11.: testflight.yml runs CI, the UI flow and the
stress pass itself, in the same run, before it uploads. Those called workflows are part of the
TestFlight run, not runs of ci.yml or ui.yml, so they do not count here.

Writes `ok=true|false` and `reason=...` to $GITHUB_OUTPUT and a line to the job summary.
Never fails itself (exit 0) unless --fail is given (release.yml gives it).

Environment: GH_TOKEN, GITHUB_REPOSITORY, SHA (commit to check), WAIT_MINUTES (default 180),
NO_RUN_MINUTES (give up when no CI run has appeared after this long, or no UI flow run this
long after CI turned green; default 15).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
REPO = os.environ["GITHUB_REPOSITORY"]
SHA = os.environ["SHA"]
WAIT = float(os.environ.get("WAIT_MINUTES", "180")) * 60
NO_RUN = float(os.environ.get("NO_RUN_MINUTES", "15")) * 60
POLL = 60
CI, CI_JOB = "ci.yml", "iOS build and tests"
UI = "ui.yml"
UI_VERDICT, UI_QUICK_VERDICT = "UI verdict (full)", "UI verdict (quick)"
NO_CI, NO_UI = "no CI run", "no UI flow run"


def api(path, **params):
    url = f"{API}/repos/{REPO}/{path}" + ("?" + urllib.parse.urlencode(params) if params else "")
    request = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except (urllib.error.URLError, TimeoutError) as error:
            if isinstance(error, urllib.error.HTTPError) and error.code == 404:
                return {}
            time.sleep(10 * (attempt + 1))
    raise RuntimeError(f"GitHub API not reachable: {path}")


def runs(workflow):
    # The API filters by head_sha; checking it here too keeps the gate exact even if that
    # filter were ever ignored (a run of another commit must never count).
    found = api(f"actions/workflows/{workflow}/runs", head_sha=SHA, per_page=30).get("workflow_runs", [])
    return [run for run in found if run.get("head_sha") == SHA]


def newest_run(workflow):
    return max(runs(workflow), key=lambda r: r["run_number"], default=None)


def describe(run):
    return f"{run['name']} #{run['run_number']} ({run['event']}, {run['html_url']})"


def check():
    """(done, ok, reason) for the current state of the runs."""
    ci = newest_run(CI)
    if ci is None:
        return False, False, f"{NO_CI} for {SHA[:7]} yet"
    if ci["status"] != "completed":
        return False, False, f"waiting for {describe(ci)}"
    if ci["conclusion"] != "success":
        return True, False, f"{describe(ci)} ended with '{ci['conclusion']}'"
    # The iOS job must have passed in this run, or in an earlier run of the same commit (then
    # this run skipped it because that exact code was tested already).
    ios, state = False, []
    for run in sorted(runs(CI), key=lambda r: -r["run_number"]):
        if run["status"] != "completed":
            continue
        jobs = [j for j in api(f"actions/runs/{run['id']}/jobs", per_page=100).get("jobs", [])
                if j["name"].startswith(CI_JOB)]
        state += [f"#{run['run_number']} {j['name']}: {j.get('conclusion')}" for j in jobs]
        if jobs and all(j.get("conclusion") == "success" for j in jobs):
            ios = True
            break
    if not ios:
        state = ", ".join(state[:4]) or "job missing"
        return True, False, (f"the iOS tests did not run for this commit ({state}); only documentation "
                             "changed since the last tested commit, so there is nothing new to ship (to test this exact "
                             "commit anyway, start CI by hand on it)")
    # The newest UI flow run in full mode decides; quick runs (pull requests) are passed over.
    quick = 0
    for ui in sorted(runs(UI), key=lambda r: -r["run_number"]):
        jobs = api(f"actions/runs/{ui['id']}/jobs", per_page=100).get("jobs", [])  # its newest attempt
        if any(j.get("name", "").endswith(UI_QUICK_VERDICT) for j in jobs):
            quick += 1
            continue
        if ui["status"] != "completed":
            return False, False, f"CI passed; waiting for {describe(ui)}"
        if ui["conclusion"] != "success":
            return True, False, f"CI passed, but {describe(ui)} ended with '{ui['conclusion']}'"
        verdict = [j for j in jobs if j.get("name", "").endswith(UI_VERDICT)]
        if not verdict or any(j.get("conclusion") != "success" for j in verdict):
            return True, False, (f"CI passed, but {describe(ui)} has no green '{UI_VERDICT}' job "
                                 f"({', '.join(str(j.get('conclusion')) for j in verdict) or 'none'}); start 'UI flow' "
                                 "by hand on this commit")
        return True, True, f"{describe(ci)} and {describe(ui)} ({UI_VERDICT}) passed"
    # Not green, ever: main() waits NO_RUN_MINUTES for one to appear, then gives up.
    only_quick = f", only {quick} quick run(s) of pull requests, which never count" if quick else ""
    return False, False, f"{NO_UI} in full mode for {SHA[:7]} yet ({describe(ci)} passed{only_quick})"


def missing_run(kind):
    """The final reason when the run of `kind` (NO_CI or NO_UI) never appeared."""
    minutes = int(NO_RUN // 60)
    if kind == NO_CI:
        return (f"{NO_CI} appeared for {SHA[:7]} within {minutes} min (CI runs for pull requests and "
                "pushes to main; start it by hand)")
    return (f"{NO_UI} in full mode for {SHA[:7]} (none appeared within {minutes} min after CI passed): the "
            f"gate needs a green UI flow run on exactly this commit with a green '{UI_VERDICT}' job. Pull "
            "request runs are quick and do not count; start 'UI flow' by hand on this commit (quick off), "
            "then run this workflow again")


def main():
    started = time.monotonic()
    missing_since = {}  # NO_CI / NO_UI -> when that run was first seen missing
    while True:
        try:
            done, ok, reason = check()
        except RuntimeError as error:
            done, ok, reason = False, False, str(error)
        now = time.monotonic()
        waited = now - started
        print(f"GATE {int(waited // 60):>3} min: {reason}", flush=True)
        if done:
            break
        kind = next((k for k in (NO_CI, NO_UI) if reason.startswith(k)), None)
        if kind and now - missing_since.setdefault(kind, now) >= NO_RUN:
            reason = missing_run(kind)
            break
        if waited >= WAIT:
            reason = f"tests not finished after {int(WAIT // 60)} min ({reason})"
            break
        time.sleep(POLL)
    level = "notice" if ok else "warning"
    print(f"::{level} title=Test gate::{'Green' if ok else 'Not green'}: {reason}")
    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a", encoding="utf-8") as out:
        out.write(f"ok={'true' if ok else 'false'}\nreason={reason}\n")
    with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a", encoding="utf-8") as out:
        out.write(f"### Test gate for {SHA[:7]}: {'✅ green' if ok else '⛔ not green'}\n\n{reason}\n")
    return 1 if ("--fail" in sys.argv and not ok) else 0


if __name__ == "__main__":
    sys.exit(main())
