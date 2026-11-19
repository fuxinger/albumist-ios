"""Whether the TestFlight upload is fenced in: it runs only in the environment testflight-upload,
and only the branch main may use it (the owner's decision of 19.11.2026, which replaced decision 5
of 18.11.: the upload runs without a click once every gate of the run is green).

  python3 .github/scripts/upload_approval.py check
      For testflight.yml (job "Upload setup", Linux, no secret) and daily_build.py. Reads the
      GitHub environment ENVIRONMENT (GET /repos/{repo}/environments/{name} and its
      deployment-branch-policies; actions: read) and exits 0 only when it exists and may be used
      from the branch main only; then it writes ready=true to $GITHUB_OUTPUT. Otherwise an error
      that points to SETUP, exit 1.

Why: the upload job of testflight.yml is the only job that names this environment, and the App
Store Connect secrets live in it (docs/launch/FREIGABE_EINRICHTEN.md). GitHub creates an
environment that a job names but that does not exist yet, without any rule: that job could then
run from any branch. So no run gets past its first job unless the environment exists with its
branch rule, and the upload job never creates one.

The branch rule is the only fence now, so it is strict: a custom rule for exactly the branch
main (GET .../deployment-branch-policies); no rule, "protected branches", a pattern, a second
branch or a tag rule stops the run (second review of bundle-p: a changed testflight.yml started
from another branch must not reach the secrets).

A private repository (GitHub's docs, "Managing environments for deployment", 19.11.2026): on GitHub
Free, environments, environment secrets and deployment branch rules exist for public
repositories only; GitHub Pro, Team and Enterprise have them in private ones too. Required
reviewers in private repositories need Enterprise, but no reviewer is needed any more. So in a
private repository a missing branch rule is refused with a message that names GitHub Free, and
a rule the API lists gives a warning that it holds only on GitHub Pro, Team or Enterprise. On
GitHub Free the environment's secrets are not given to the job either, so the upload job stops at
"App Store Connect secrets present" (fails closed).

Warning, no block: a required reviewer is still set (the upload then waits for a click, as before
19.11.).

When the API does not answer, check fails (no upload without knowing): re-run the job.

The file keeps its name (daily_build.py and the tests import it); the job and its texts say
"setup" since 19.11.

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


PRIVATE_WITHOUT_RULE = ("the repository is private and the environment {name} shows no branch rule: on GitHub Free, "
                        "environments, their secrets and their branch rules exist only in public repositories (GitHub "
                        "Pro, Team or Enterprise has them in private ones); make the repository public, or use one of "
                        "those plans and set the rule main, as in {setup}")
PRIVATE_NEEDS_PLAN = ("the repository is private: the environment's branch rule (and its secrets) hold only on GitHub "
                      "Pro, Team or Enterprise; on GitHub Free they are ignored and the upload job stops at "
                      "'App Store Connect secrets present'")


def main_only(environment: dict | None, branches: list[dict] | None) -> bool:
    """Whether the environment may be used from the branch main only (a custom rule for exactly it)."""
    policy = (environment or {}).get("deployment_branch_policy") or {}
    named = sorted((str((b or {}).get("name")), str((b or {}).get("type", "branch"))) for b in branches or [])
    return bool(policy.get("custom_branch_policies")) and not policy.get("protected_branches") and named == MAIN_ONLY


def review(environment: dict | None, public: bool = True,
           branches: list[dict] | None = None) -> tuple[list[str], list[str], list[str]]:
    """(problems that block the upload, warnings, notes) of an environment; None: it does not exist.
    public: whether the repository is public (fetch_public). branches: its custom branch rules
    (fetch_branches)."""
    fenced = environment is not None and main_only(environment, branches)
    if not public and not fenced:
        return [PRIVATE_WITHOUT_RULE.format(name=ENVIRONMENT, setup=SETUP)], [], []
    if environment is None:
        return [f"the environment {ENVIRONMENT} does not exist"], [], []
    if not fenced:
        return [f"the environment {ENVIRONMENT} may be used from other branches than main: set 'Deployment "
                "branches and tags' to 'Selected branches and tags' with the one rule main"], [], []
    warnings = [] if public else [PRIVATE_NEEDS_PLAN]
    rules = environment.get("protection_rules") or []
    if any(isinstance(r, dict) and r.get("type") == "required_reviewers" for r in rules):
        warnings.append(f"the environment {ENVIRONMENT} still has a required reviewer: the upload waits for a click "
                        f"(since 19.11.2026 it should run by itself; remove the reviewer as in {SETUP})")
    return [], warnings, [f"only the branch main may use the environment {ENVIRONMENT}"]


def check(fetcher=fetch, public=fetch_public, branch_fetcher=fetch_branches) -> int:
    try:
        environment = fetcher()
        is_public = public()
        branches = branches_of(environment, branch_fetcher)
    except ApiError as error:
        print(command("error", "Upload setup", f"the environment {ENVIRONMENT} could not be read ({error}); "
                      "re-run this job when the API answers"))
        return 1
    problems, warnings, notes = review(environment, is_public, branches)
    for text in warnings:
        print(command("warning", "Upload setup", text))
    with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a", encoding="utf-8") as out:
        if problems:
            out.write(f"### No upload: the upload environment is not set up\n\n{'; '.join(problems).capitalize()}. "
                      f"The upload runs in the environment `{ENVIRONMENT}`, which only the branch main may use; set "
                      f"it up once as in `{SETUP}` (about 5 minutes), then start a new run.\n")
        else:
            out.write(f"### Upload setup\n\nThe upload runs by itself once every gate is green; "
                      f"{'; '.join(notes)}.\n" + "".join(f"\n- Warning: {w}" for w in warnings)
                      + ("\n" if warnings else ""))
    if problems:
        print(command("error", "Upload setup", "; ".join(problems) + f". No upload: set it up as in {SETUP}, then "
                      "start a new run."))
        return 1
    print(f"UPLOAD_SETUP {ENVIRONMENT}: main only")
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
