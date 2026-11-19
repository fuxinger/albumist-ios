"""Cancels the UI runs (ui.yml) of the older commits of a pull request when a newer commit is
pushed (.github/workflows/ui-supersede.yml).

Why: every UI run of every branch shares the Mac queue "mac-queue" (ui.yml, "concurrency"), in
which a running run is never cancelled. On 19.11.2026 the UI run of PR #9's commit 8d0db8f ran
on for about an hour after 945446e had the fix, and the run of 945446e waited behind it. A
concurrency setting cannot cancel per branch there (one group for all branches), so this
script does it: it cancels the runs of ui.yml that belong to this pull request (same branch,
same repository, event pull_request), are still waiting or running, and test another commit.

Never cancelled: runs of other branches, a run started by hand (workflow_dispatch), and the
UI flow of a TestFlight run (it runs inside testflight.yml, not as a run of ui.yml).

A newer push must never lose its run to the job of an older push (second review, 19.11.): only
runs created before this job's own run are cancelled (a run of a newer push is always created
after it), and the job stops when its commit is no longer the head of the pull request, read
before and again after the listing (the job of the newer push does the work then). A re-run of
an older commit's run is a pull request run too and is cancelled like it: it tests an outdated
commit. Never on the default branch's own runs (HEAD_REF main is refused).

Environment: GH_TOKEN (actions: write), GITHUB_REPOSITORY, GITHUB_API_URL, GITHUB_RUN_ID, PR_NUMBER,
HEAD_SHA, HEAD_REF, GITHUB_STEP_SUMMARY (optional).
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
WORKFLOW = ".github/workflows/ui.yml"
# Every state of a run that has not ended (GitHub's run statuses).
ACTIVE = {"queued", "in_progress", "waiting", "pending", "requested"}


class ApiError(RuntimeError):
    def __init__(self, message: str, code: int | None = None):
        super().__init__(message)
        self.code = code  # the HTTP status, when GitHub answered


def api(path: str, method: str = "GET", **params):
    """JSON of a REST call on this repository."""
    repo = os.environ["GITHUB_REPOSITORY"]
    url = f"{API}/repos/{repo}/{path}" + ("?" + urllib.parse.urlencode(params) if params else "")
    request = urllib.request.Request(url, method=method, headers={
        "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}"})
    last = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read()
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as error:
            last = error
            if error.code < 500:
                break  # 4xx: asking again gives the same answer
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            last = error
        time.sleep(5 * (attempt + 1))
    raise ApiError(f"{path}: {last}", getattr(last, "code", None))


def older_runs(runs: list[dict], repo: str, branch: str, head_sha: str, before: str) -> list[int]:
    """Ids of the runs of ui.yml for this pull request that have not ended, test another commit
    than `head_sha` and were created before `before` (ISO time of this job's own run)."""
    ids = []
    for run in runs:
        source = (run.get("head_repository") or {}).get("full_name")
        created = run.get("created_at") or ""
        if (run.get("path") == WORKFLOW and run.get("event") == "pull_request"
                and run.get("head_branch") == branch and source == repo
                and run.get("status") in ACTIVE and run.get("head_sha") != head_sha
                and created and created < before):
            ids.append(run["id"])
    return ids


def main(call=api, env=os.environ) -> int:
    repo, number = env["GITHUB_REPOSITORY"], env["PR_NUMBER"]
    head_sha, branch = env["HEAD_SHA"], env["HEAD_REF"]
    lines = []

    def moved() -> str | None:
        current = call(f"pulls/{number}")["head"]["sha"]
        return None if current == head_sha else current

    if branch in ("main", env.get("DEFAULT_BRANCH", "main")):
        lines.append(f"Head branch {branch} is the default branch: nothing is cancelled there.")
    elif newer := moved():
        lines.append(f"A newer commit ({newer[:7]}) is the head of the pull request now; its own "
                     f"job cancels the older UI runs. Nothing cancelled for {head_sha[:7]}.")
    else:
        before = call(f"actions/runs/{env['GITHUB_RUN_ID']}")["created_at"]
        runs = call("actions/workflows/ui.yml/runs", branch=branch, event="pull_request",
                    per_page=100)["workflow_runs"]
        ids = older_runs(runs, repo, branch, head_sha, before)
        if ids and (newer := moved()):
            lines.append(f"A newer commit ({newer[:7]}) was pushed meanwhile; its own job cancels "
                         f"the older UI runs. Nothing cancelled for {head_sha[:7]}.")
            ids = []
        shas = {run["id"]: run["head_sha"] for run in runs}
        for run_id in ids:
            try:
                call(f"actions/runs/{run_id}/cancel", method="POST")
                lines.append(f"Cancelled UI run {run_id} (commit {shas[run_id][:7]}): "
                             f"{head_sha[:7]} is newer.")
            except ApiError as error:
                ended = error.code == 409
                lines.append(f"UI run {run_id} not cancelled ({error})"
                             + ("; it ended meanwhile." if ended else "."))
        if not ids and not lines:
            lines.append("Nothing to cancel: no UI run of an older commit is waiting or running.")
    text = "\n".join(lines)
    print(text)
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write("### Older UI runs\n\n" + "\n".join(f"- {line}" for line in lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
