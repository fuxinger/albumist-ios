"""Decides whether the expensive (macOS) jobs have to run for this commit.

Writes `code=true|false`, `swift=true|false` and `base=<sha>` to $GITHUB_OUTPUT.

`code` is false only when every file that changed since the last *tested* commit is
documentation (`*.md` anywhere, or anything under `docs/`). The last tested commit is the
newest ancestor of HEAD on which a job of WORKFLOW whose name starts with JOB_PREFIX
succeeded (ran, not skipped); for a pull request HEAD is GitHub's merge commit, the one CI
tests. Comparing with that commit instead of the push's `before`
matters: when a code push's run is cancelled by a following docs-only push, the code has
never been tested, and the second run must test it.

Everything runs (`code=true`) when no tested ancestor is found, when the API or git fail,
and for every event other than push and pull_request (manual and scheduled runs).

Environment: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_EVENT_NAME, GITHUB_EVENT_PATH, GITHUB_SHA,
GITHUB_RUN_ID, GITHUB_OUTPUT, WORKFLOW (file name, e.g. ci.yml), JOB_PREFIX.
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
REPO = os.environ["GITHUB_REPOSITORY"]
WORKFLOW = os.environ.get("WORKFLOW", "ci.yml")
JOB_PREFIX = os.environ.get("JOB_PREFIX", "iOS build and tests")
RUN_ID = int(os.environ.get("GITHUB_RUN_ID", "0") or 0)
MAX_RUNS_WITH_JOB_LOOKUP = 15
SWIFT_FILES = ("Package.swift", "Package.resolved", "App/project.yml")


def api(path, **params):
    url = f"{API}/repos/{REPO}/{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True)


def is_docs(path):
    return path.endswith(".md") or path.startswith("docs/")


def is_swift(path):
    return path.endswith(".swift") or path in SWIFT_FILES


FETCHES = [0]


def has_commit(sha):
    if git("cat-file", "-e", f"{sha}^{{commit}}").returncode == 0:
        return True
    # A commit only reachable from a pull request ref or a deleted branch; a few at most.
    if FETCHES[0] >= 5:
        return False
    FETCHES[0] += 1
    git("fetch", "--quiet", "--filter=blob:none", "origin", sha)
    return git("cat-file", "-e", f"{sha}^{{commit}}").returncode == 0


def tested_job(run):
    jobs = api(f"actions/runs/{run['id']}/jobs", per_page=100).get("jobs", [])
    return any(j["name"].startswith(JOB_PREFIX) and j.get("conclusion") == "success" for j in jobs)


def find_base(head, branch):
    """Newest commit that is an ancestor of (or equal to) head and was tested."""
    seen = set()
    lookups = 0
    queries = [{"branch": branch}] if branch else []
    queries.append({})  # any branch, e.g. main's last tested commit for a new branch
    for query in queries:
        runs = api(f"actions/workflows/{WORKFLOW}/runs", status="completed", per_page=50, **query)
        for run in runs.get("workflow_runs", []):
            sha = run["head_sha"]
            if run["id"] == RUN_ID or run["id"] in seen:
                continue
            seen.add(run["id"])
            if not has_commit(sha):
                continue
            if sha != head and git("merge-base", "--is-ancestor", sha, head).returncode != 0:
                continue
            if lookups >= MAX_RUNS_WITH_JOB_LOOKUP:
                return None
            lookups += 1
            if tested_job(run):
                return sha
    return None


def main():
    event_name = os.environ.get("GITHUB_EVENT_NAME", "")
    event = {}
    if os.environ.get("GITHUB_EVENT_PATH"):
        with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as f:
            event = json.load(f)
    # What CI tests: the pushed commit, or for a pull request the merge commit GitHub made
    # (GITHUB_SHA). Diffing up to the merge commit also counts code that arrived on the base
    # branch; when the base is already part of the PR branch its tree equals the PR head's.
    head = os.environ["GITHUB_SHA"]
    branch = (event.get("pull_request") or {}).get("head", {}).get("ref") or os.environ.get("GITHUB_REF_NAME", "")

    result = {"code": "true", "swift": "true", "base": ""}
    if event_name not in ("push", "pull_request"):
        reason = f"{event_name} run: everything runs"
    else:
        try:
            base = find_base(head, branch)
        except (urllib.error.URLError, TimeoutError, KeyError, ValueError) as error:
            base, reason = None, f"could not look up earlier runs ({error}): everything runs"
        else:
            reason = f"no tested ancestor found for {head[:7]}: everything runs"
        if base:
            diff = git("diff", "--name-only", "--no-renames", base, head)
            if diff.returncode != 0:
                reason = f"git diff {base[:7]}..{head[:7]} failed: everything runs"
            else:
                files = [f for f in diff.stdout.splitlines() if f]
                code = [f for f in files if not is_docs(f)]
                result = {
                    "code": "true" if code else "false",
                    "swift": "true" if any(is_swift(f) for f in files) else "false",
                    "base": base,
                }
                reason = (f"{len(files)} files changed since {base[:7]}, the last commit where "
                          f"'{JOB_PREFIX}' passed; {len(code)} of them are not documentation")
                for f in files[:40]:
                    print(f"  {'docs ' if is_docs(f) else 'code '} {f}")
    print(f"CHANGES code={result['code']} swift={result['swift']}: {reason}")
    if result["code"] == "false":
        print(f"::notice title=Docs only::Only documentation changed since {result['base'][:7]}; "
              "macOS jobs are skipped.")
    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a", encoding="utf-8") as out:
        for key, value in result.items():
            out.write(f"{key}={value}\n")


if __name__ == "__main__":
    sys.exit(main())
