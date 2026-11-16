#!/usr/bin/env python3
"""Does this commit hold app changes that are not on TestFlight yet?

TestFlight should never start for a commit that only changes the website or documents
(16.11.: merging the website into main started a build of an old app state). The reference is
the newest `build-<number>` tag that is an ancestor of HEAD (the tag job sets one after every
upload). If no file outside the ignored areas changed since that tag, there is nothing new to
ship. Without any ancestor tag, everything counts as new. Code pushed before a docs-only
commit is still new relative to the last uploaded build, so this check lets it through; whether
it is uploaded then depends on the test gate (ci_gate.py), which fails closed when that commit
has no green iOS and UI run.

Usage: app_changed.py            prints `changed=true|false` (for $GITHUB_OUTPUT) and why
Needs the full history and tags (actions/checkout with fetch-depth: 0).
"""
import fnmatch
import subprocess
import sys

IGNORED = ["website/*", "docs/*", "LICENSE", ".github/ISSUE_TEMPLATE/*", ".github/pull_request_template.md"]
# Never ignored, whatever the file type: a Markdown or text file there may be an app resource.
APP_AREAS = ("App/", "Sources/", "Tests/", "Package.", "project.yml")


def ignored(path: str) -> bool:
    if path.startswith(APP_AREAS):
        return False
    if "/" not in path and path.endswith(".md"):  # README.md, SECURITY.md, STATUS.md at the top
        return True
    # fnmatch's * also matches "/", so "docs/*" covers everything below docs/.
    return any(fnmatch.fnmatch(path, pattern) for pattern in IGNORED)


def app_files(paths):
    return [p for p in paths if p and not ignored(p)]


def git(*args) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def last_build_tag():
    try:
        return git("describe", "--tags", "--abbrev=0", "--match", "build-*", "HEAD").strip() or None
    except subprocess.CalledProcessError:
        return None


def decide(tag, changed_paths):
    """(changed, reason) from the newest ancestor build tag and the files changed since it."""
    if tag is None:
        return True, "no earlier TestFlight build in this history"
    app = app_files(changed_paths)
    if not app:
        return False, f"only website or documents changed since {tag}"
    return True, f"{len(app)} app file(s) changed since {tag}, e.g. {app[0]}"


def main() -> int:
    tag = last_build_tag()
    # --no-renames: a file moved out of the app (e.g. into docs/) must list its old path too.
    paths = git("diff", "--name-only", "--no-renames", f"{tag}..HEAD").splitlines() if tag else []
    changed, reason = decide(tag, paths)
    print(f"changed={'true' if changed else 'false'}")
    print(f"# {reason}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
