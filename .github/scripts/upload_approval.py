"""Whether a TestFlight upload waits for the owner's approval (the owner's decision 5 of 18.11.2026).

  python3 .github/scripts/upload_approval.py check
      For testflight.yml (job "Upload approval", Linux, no secret) and daily_build.py. Reads the
      GitHub environment ENVIRONMENT (GET /repos/{repo}/environments/{name}; actions: read) and
      exits 0 only when it exists and asks a required reviewer before a job may use it; then it
      writes ready=true to $GITHUB_OUTPUT. Otherwise an error that points to SETUP, exit 1.

Why: the upload job of testflight.yml is the only job that names this environment, and the App
Store Connect secrets live in it (docs/launch/FREIGABE_EINRICHTEN.md). GitHub creates an
environment that a job names but that does not exist yet, without any protection rule: that job
would start without asking anyone, and it could still read the four secrets if they were left
in the repository. So no run gets past its first job unless the environment asks the owner.
That the secrets left the repository cannot be read from here (a job outside the environment
would have to read them for that); the setup steps say to delete them.

It also stops when the repository is not public: on GitHub Free, Pro and Team a required
reviewer of an environment is enforced in public repositories only, and whether the API still
lists such a rule after a switch to private is not known. Going private needs another approval
path first (docs/launch/FREIGABE_EINRICHTEN.md); until then nothing is uploaded.

It also stops unless the environment may be used from the branch main only (a custom rule for
exactly the branch main, GET .../deployment-branch-policies): with no rule, or "protected
branches", or another pattern, a changed testflight.yml started from another branch could ask
for the owner's approval under a misleading name (second review of bundle-p).

Warning, no block: "Prevent self-review" is on (the owner could not approve a run he started himself;
the daily build is started by GitHub Actions, so it does not matter there).

When the API does not answer, check fails (no upload without knowing): re-run the job.

Environment: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_API_URL, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from earlier_attempts import command  # noqa: E402

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
# The environment of the upload job in testflight.yml (test_workflows.py checks that they match).
ENVIRONMENT = "testflight-upload"
SETUP = "docs/launch/FREIGABE_EINRICHTEN.md"


class ApiError(Exception):
    pass


def fetch(name: str = ENVIRONMENT) -> dict | None:
    """The environment as the REST API describes it, None when it does not exist (HTTP 404)."""
    return _get(f"environments/{urllib.parse.quote(name, safe='')}")


def fetch_branches(name: str = ENVIRONMENT) -> list[dict] | None:
    """The environment's custom branch rules, None when there are none (HTTP 404)."""
    answer = _get(f"environments/{urllib.parse.quote(name, safe='')}/deployment-branch-policies")
    return None if answer is None else list(answer.get("branch_policies") or [])


MAIN_ONLY = [("main", "branch")]


def branches_of(environment: dict | None, fetcher=None) -> list[dict] | None:
    """The custom branch rules of an environment that has them (fetch_branches), else None."""
    custom = bool(((environment or {}).get("deployment_branch_policy") or {}).get("custom_branch_policies"))
    return (fetcher or fetch_branches)() if custom else None


def fetch_public() -> bool:
    """Whether the repository is public (GET /repos/{repo}; any token that can read it)."""
    repository = _get("")
    if repository is None:
        raise ApiError("GitHub API: the repository could not be read")
    return repository.get("private") is False and repository.get("visibility", "public") == "public"


def _get(path: str) -> dict | None:
    repo = os.environ["GITHUB_REPOSITORY"]
    url = f"{API}/repos/{repo}" + (f"/{path}" if path else "")
    name = path or repo
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                                   "X-GitHub-Api-Version": "2022-11-28",
                                                   "Authorization": f"Bearer {os.environ['GH_TOKEN']}"})
    last = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            last = error
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            last = error
        time.sleep(5 * (attempt + 1))
    raise ApiError(f"GitHub API: {name}: {last}")


NOT_PUBLIC = ("the repository is not public, and GitHub enforces a required reviewer of an environment in a "
              "private repository only with GitHub Enterprise")


def review(environment: dict | None, public: bool = True,
           branches: list[dict] | None = None) -> tuple[list[str], list[str], list[str]]:
    """(problems that block the upload, warnings, reviewers) of an environment; None: it does not exist.
    public: whether the repository is public (fetch_public). branches: its custom branch rules
    (fetch_branches)."""
    if not public:
        return [NOT_PUBLIC], [], []
    if environment is None:
        return [f"the environment {ENVIRONMENT} does not exist"], [], []
    rules = environment.get("protection_rules") or []
    reviewing = [r for r in rules if isinstance(r, dict) and r.get("type") == "required_reviewers"]
    reviewers = []
    for rule in reviewing:
        for entry in rule.get("reviewers") or []:
            who = (entry or {}).get("reviewer") or {}
            reviewers.append(who.get("login") or who.get("slug") or who.get("name") or "?")
    # A rule always has a reviewer in GitHub's settings; an answer that lists none counts as none.
    if not reviewing or all(isinstance(r.get("reviewers"), list) and not r["reviewers"] for r in reviewing):
        return [f"the environment {ENVIRONMENT} has no required reviewer"], [], []
    policy = environment.get("deployment_branch_policy") or {}
    rules_named = sorted(((b or {}).get("name"), (b or {}).get("type", "branch")) for b in branches or [])
    if policy.get("protected_branches") or not policy.get("custom_branch_policies") or rules_named != MAIN_ONLY:
        return [f"the environment {ENVIRONMENT} may be used from other branches than main: set 'Deployment "
                "branches and tags' to 'Selected branches and tags' with the one rule main"], [], []
    warnings = []
    if any(r.get("prevent_self_review") for r in reviewing):
        warnings.append("'Prevent self-review' is on: a reviewer cannot approve a run he started himself")
    return [], warnings, reviewers


def check(fetcher=fetch, public=fetch_public, branch_fetcher=fetch_branches) -> int:
    try:
        environment = fetcher()
        is_public = public()
        branches = branches_of(environment, branch_fetcher)
    except ApiError as error:
        print(command("error", "Upload approval", f"the environment {ENVIRONMENT} could not be read ({error}); "
                      "re-run this job when the API answers"))
        return 1
    problems, warnings, reviewers = review(environment, is_public, branches)
    for text in warnings:
        print(command("warning", "Upload approval", text))
    with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a", encoding="utf-8") as out:
        if problems:
            out.write(f"### No upload: the approval is not set up\n\n{'; '.join(problems).capitalize()}. The upload "
                      f"waits for the owner's approval in the environment `{ENVIRONMENT}`; set it up once as in "
                      f"`{SETUP}` (about 10 minutes), then start a new run.\n")
        else:
            out.write(f"### Upload approval\n\nThe upload job waits until {', '.join(reviewers) or 'a reviewer'} "
                      f"approves it (environment `{ENVIRONMENT}`).\n" + "".join(f"\n- Warning: {w}" for w in warnings)
                      + ("\n" if warnings else ""))
    if problems:
        print(command("error", "Upload approval", "; ".join(problems) + f". No upload without the owner's approval: "
                      f"set it up as in {SETUP}, then start a new run."))
        return 1
    print(f"UPLOAD_APPROVAL {ENVIRONMENT}: required reviewer(s) {', '.join(reviewers) or '(listed by GitHub)'}")
    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a", encoding="utf-8") as out:
        out.write("ready=true\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("command", choices=["check"])
    parser.parse_args(argv)
    return check()


if __name__ == "__main__":
    sys.exit(main())
