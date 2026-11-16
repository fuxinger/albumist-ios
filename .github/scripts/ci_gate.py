"""Waits until the tests of one commit are finished and says whether they are green.

Used before a TestFlight upload and before a release tag. Green means:
  1. The newest CI run (ci.yml) for exactly this commit succeeded, and the job
     "iOS build and tests (macOS)" really ran and succeeded in it or in an earlier run of the
     same commit. When it was skipped everywhere (only documentation changed since the last
     tested commit), there is nothing new to ship.
  2. If a UI flow run (ui.yml) exists for this commit (it runs for pull requests), its newest
     run succeeded too. Pushes to main have no UI flow run; there CI alone decides.

Earlier stages, for starting work that may run before the whole gate is green:
  --ci     only point 1 (the CI run, with its iOS job). TestFlight builds the release archive
           on a Mac once CI is green, while the full gate still waits for the UI run; the
           upload needs both.
  --linux  only CI's Linux jobs ("Core tests (Linux)" and "App rules and strings"), for
           starting even earlier (one more Mac job at the same time as CI's).

Writes `ok=true|false` and `reason=...` to $GITHUB_OUTPUT and a line to the job summary.
Never fails itself (exit 0) unless --fail is given, so a red test run shows up as a skipped
upload with the reason, not as a second red workflow.

Environment: GH_TOKEN, GITHUB_REPOSITORY, SHA (commit to check), WAIT_MINUTES (default 180),
NO_RUN_MINUTES (give up when no CI run has appeared after this long, default 15).
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
LINUX_JOBS = ("Core tests (Linux)", "App rules and strings")
UI = "ui.yml"


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
    return api(f"actions/workflows/{workflow}/runs", head_sha=SHA, per_page=30).get("workflow_runs", [])


def newest_run(workflow):
    return max(runs(workflow), key=lambda r: r["run_number"], default=None)


def describe(run):
    return f"{run['name']} #{run['run_number']} ({run['event']}, {run['html_url']})"


def check(ui_too=True):
    """(done, ok, reason) for the current state of the runs (CI alone when not ui_too)."""
    ci = newest_run(CI)
    if ci is None:
        return False, False, f"no CI run for {SHA[:7]} yet"
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
    if not ui_too:
        return True, True, f"{describe(ci)} passed"
    ui = newest_run(UI)
    if ui is None:
        return True, True, f"{describe(ci)} passed (no UI flow run for this commit)"
    if ui["status"] != "completed":
        return False, False, f"CI passed; waiting for {describe(ui)}"
    if ui["conclusion"] != "success":
        return True, False, f"CI passed, but {describe(ui)} ended with '{ui['conclusion']}'"
    return True, True, f"{describe(ci)} and {describe(ui)} passed"


def check_linux():
    """(done, ok, reason): the Linux jobs of the newest CI run for this commit."""
    ci = newest_run(CI)
    if ci is None:
        return False, False, f"no CI run for {SHA[:7]} yet"
    jobs = {j["name"]: j for j in api(f"actions/runs/{ci['id']}/jobs", per_page=100).get("jobs", [])}
    states = []
    for name in LINUX_JOBS:
        job = jobs.get(name)
        if job is None or job.get("status") != "completed":
            if ci["status"] == "completed":
                return True, False, f"{describe(ci)} ended without '{name}'"
            return False, False, f"waiting for '{name}' in {describe(ci)}"
        if job.get("conclusion") != "success":
            return True, False, f"'{name}' ended with '{job.get('conclusion')}' in {describe(ci)}"
        states.append(name)
    return True, True, f"{' and '.join(states)} passed in {describe(ci)}"


def main():
    started = time.monotonic()
    linux, ci_only = "--linux" in sys.argv, "--ci" in sys.argv
    while True:
        try:
            done, ok, reason = check_linux() if linux else check(ui_too=not ci_only)
        except RuntimeError as error:
            done, ok, reason = False, False, str(error)
        waited = time.monotonic() - started
        print(f"GATE {int(waited // 60):>3} min: {reason}", flush=True)
        if done:
            break
        if reason.startswith("no CI run") and waited >= NO_RUN:
            reason = (f"no CI run appeared for {SHA[:7]} within {int(NO_RUN // 60)} min (CI runs for pull "
                      "requests and pushes to main; start it by hand, or use force)")
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
        part = "Linux tests" if linux else ("CI" if ci_only else "Test gate")
        out.write(f"### {part} for {SHA[:7]}: {'✅ green' if ok else '⛔ not green'}\n\n{reason}\n")
    return 1 if ("--fail" in sys.argv and not ok) else 0


if __name__ == "__main__":
    sys.exit(main())
