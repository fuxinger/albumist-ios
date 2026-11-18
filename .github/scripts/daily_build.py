"""Starts the daily TestFlight build for the owner (small gate) when there is something new to build
(the owner's decision 10 of 18.11.2026: a daily build with the small gate; the big gate stays for
testers and the App Store). For daily-build.yml: Linux, no secret.

  python3 .github/scripts/daily_build.py decide
      Writes start=true|false to $GITHUB_OUTPUT and why to the log and the job summary. true only
      when all of these hold:
        1. The upload asks the owner first (upload_approval.py: the environment exists and has a
           required reviewer). The daily build never uploads on its own: its upload job waits for
           the owner's click like every other.
        2. No TestFlight run is running or waiting. A run that waits for the owner's approval still
           holds the group "testflight" (testflight.yml); a run started now would wait behind it
           and would replace a run that already waits there (GitHub keeps one waiting run).
        3. This app is not in TestFlight yet: no build-<number> tag (testflight.yml tags every
           uploaded build, and only those) is on a commit with this commit's app fingerprint
           (ui_groups.py: what goes into the app; docs, tests and the pipeline do not count). No
           new build, and no new question to the owner, while the app is unchanged.
        4. No TestFlight run of exactly this commit got past its first job ("Upload approval"),
           whatever its result: a red test is fixed in a new commit, never re-run to green, and a
           build the owner rejected is not offered again the next day. A run that stopped in its
           first job (approval not set up yet, API down) tested nothing and does not count.
      Started by hand, testflight.yml can still build any commit with either gate.

The workflow then starts testflight.yml on main with the input gate=small (gh workflow run, the
run's own token with actions: write; GitHub lets that token start workflow_dispatch runs).

Environment: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_API_URL, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ui_evidence  # noqa: E402
import ui_groups  # noqa: E402
import upload_approval  # noqa: E402

WORKFLOW = "testflight.yml"
# The name of testflight.yml's first job (test_workflows.py checks it).
CHECK_JOB = "Upload approval"
TAG = re.compile(r"^build-(\d+)$")


def build_tags(cwd: str = ui_groups.ROOT) -> dict[str, str]:
    """{tag: commit} of the build-<number> tags (one per uploaded build, testflight.yml)."""
    out = subprocess.run(["git", "for-each-ref", "--format=%(refname:short) %(objectname) %(*objectname)", "refs/tags/build-*"],
                         cwd=cwd, capture_output=True, text=True)
    tags = {}
    for line in out.stdout.splitlines():
        name, obj, *peeled = line.split()
        if TAG.match(name):
            tags[name] = peeled[0] if peeled else obj  # an annotated tag points at a tag object
    return tags


def runs_of(call) -> list[dict]:
    """The newest 100 runs of testflight.yml (newest first); a TestFlight run takes hours, so they
    reach back weeks."""
    return call(f"actions/workflows/{WORKFLOW}/runs", per_page=100).get("workflow_runs", [])


def got_past_the_check(call, run: dict) -> bool:
    """Whether a run's first job ("Upload approval") passed, so that the run went on to test."""
    jobs = call(f"actions/runs/{run['id']}/jobs", filter="all", per_page=100).get("jobs", [])
    return any(j.get("name") == CHECK_JOB and j.get("conclusion") == "success" for j in jobs)


def decide(head: str, app: str, runs: list[dict], tags: dict[str, str], approval: tuple[list, list, list],
           app_of, passed_check) -> tuple[bool, str]:
    """(start, why). app_of(sha) -> app fingerprint or None; passed_check(run) -> bool."""
    problems = approval[0]
    if problems:
        return False, (f"{'; '.join(problems)}: the daily build starts once the upload asks the owner first "
                       f"({upload_approval.SETUP})")
    active = [r for r in runs if r.get("status") != "completed"]
    if active:
        r = active[0]
        what = "waits for the owner's approval or a runner" if r.get("status") == "waiting" else r.get("status")
        return False, (f"TestFlight run {r.get('run_number')} ({r.get('head_sha', '')[:7]}) {what}: no second run is "
                       f"started behind it ({r.get('html_url', '')})")
    for tag, sha in sorted(tags.items(), key=lambda t: -int(TAG.match(t[0]).group(1))):
        if app_of(sha) == app:
            return False, f"this app is in TestFlight already: {tag} ({sha[:7]}) has the same app fingerprint"
    for r in runs:
        if r.get("head_sha") == head and passed_check(r):
            return False, (f"TestFlight run {r.get('run_number')} tested exactly this commit already "
                           f"({r.get('conclusion')}): a red test is fixed in a new commit, and a build the owner "
                           f"rejected is not offered again; start TestFlight by hand to build it anyway "
                           f"({r.get('html_url', '')})")
    return True, f"new app {app[:ui_groups.SHORT]} on {head[:7]}: starting TestFlight with the small gate"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("command", choices=["decide"])
    parser.parse_args(argv)
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ui_groups.ROOT, capture_output=True,
                          text=True, check=True).stdout.strip()
    app = ui_groups.app_fingerprint(ui_groups.GitTree(head))
    try:
        environment = upload_approval.fetch()
        call = ui_evidence.api
        runs = runs_of(call)
    except (upload_approval.ApiError, ui_evidence.ApiError) as error:
        start, why = False, f"GitHub API did not answer ({error}); no daily build today, or start it by hand"
    else:
        verifier = ui_evidence.Verifier()
        try:
            start, why = decide(head, app, runs, build_tags(), upload_approval.review(environment), verifier.app,
                                lambda run: got_past_the_check(call, run))
        except ui_evidence.ApiError as error:
            start, why = False, f"GitHub API did not answer ({error}); no daily build today, or start it by hand"
    print(f"DAILY_BUILD {'start' if start else 'no build'}: {why}")
    with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a", encoding="utf-8") as out:
        out.write(f"### Daily build: {'started (small gate)' if start else 'not started'}\n\n{why}\n")
    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a", encoding="utf-8") as out:
        out.write(f"start={'true' if start else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
