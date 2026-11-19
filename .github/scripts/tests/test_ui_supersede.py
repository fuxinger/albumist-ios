"""Unit tests for .github/scripts/ui_supersede.py (a new push cancels the UI runs of the older
commits of the same pull request); the GitHub API is faked.

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import contextlib
import io
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import ui_supersede  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
REPO = "owner/repo"
BRANCH = "claude/work"
NEW = "b" * 40
OLD = "a" * 40


def run(run_id, sha=OLD, status="in_progress", branch=BRANCH, event="pull_request",
        path=".github/workflows/ui.yml", repo=REPO):
    return {"id": run_id, "head_sha": sha, "status": status, "head_branch": branch, "event": event,
            "path": path, "head_repository": {"full_name": repo}}


class OlderRunsTests(unittest.TestCase):
    def ids(self, runs):
        return ui_supersede.older_runs(runs, REPO, BRANCH, NEW)

    def test_the_run_of_an_older_commit_is_cancelled_waiting_or_running(self):
        # PR #9, 19.11.2026: the UI run of 8d0db8f ran on for an hour after 945446e had the fix,
        # and the run of 945446e waited for it in the Mac queue.
        runs = [run(1, status="in_progress"), run(2, status="queued"), run(3, status="waiting"),
                run(4, status="pending"), run(5, status="requested")]
        self.assertEqual(self.ids(runs), [1, 2, 3, 4, 5])

    def test_the_run_of_the_new_commit_stays(self):
        self.assertEqual(self.ids([run(1, sha=NEW), run(2, sha=NEW, status="queued")]), [])

    def test_a_finished_run_is_left_alone(self):
        self.assertEqual(self.ids([run(1, status="completed")]), [])

    def test_another_branch_is_never_touched(self):
        self.assertEqual(self.ids([run(1, branch="main"), run(2, branch="claude/other")]), [])

    def test_only_pull_request_runs_of_this_repository(self):
        # A run by hand (workflow_dispatch) was started on purpose; a fork with the same branch
        # name is another pull request; a TestFlight run is not a run of ui.yml at all.
        runs = [run(1, event="workflow_dispatch"), run(2, repo="someone/fork"),
                run(3, path=".github/workflows/testflight.yml"), run(4, event="push")]
        self.assertEqual(self.ids(runs), [])

    def test_a_run_without_its_repository_is_not_cancelled(self):
        broken = run(1)
        broken["head_repository"] = None
        self.assertEqual(self.ids([broken]), [])


class FakeApi:
    def __init__(self, head=NEW, runs=(), refuse=()):
        self.head, self.runs, self.refuse = head, list(runs), set(refuse)
        self.calls, self.cancelled = [], []

    def __call__(self, path, method="GET", **params):
        self.calls.append((method, path, params))
        if path == "pulls/9":
            return {"head": {"sha": self.head, "ref": BRANCH}}
        if path == "actions/workflows/ui.yml/runs":
            return {"workflow_runs": self.runs}
        if path.startswith("actions/runs/") and path.endswith("/cancel") and method == "POST":
            run_id = int(path.split("/")[2])
            if run_id in self.refuse:
                raise ui_supersede.ApiError(f"{path}: HTTP 409")
            self.cancelled.append(run_id)
            return {}
        raise AssertionError(f"unexpected call {method} {path}")


class MainTests(unittest.TestCase):
    def setUp(self):
        self.env = {"GITHUB_REPOSITORY": REPO, "PR_NUMBER": "9", "HEAD_SHA": NEW, "HEAD_REF": BRANCH}

    def main(self, api):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = ui_supersede.main(api, self.env)
        return code, out.getvalue()

    def test_cancels_the_older_runs_and_says_which(self):
        api = FakeApi(runs=[run(11), run(12, sha=NEW, status="queued"), run(13, status="completed")])
        code, out = self.main(api)
        self.assertEqual((code, api.cancelled), (0, [11]))
        self.assertIn("11", out)
        self.assertIn(("GET", "actions/workflows/ui.yml/runs",
                       {"branch": BRANCH, "event": "pull_request", "per_page": 100}), api.calls)

    def test_a_late_job_of_an_older_push_cancels_nothing(self):
        # Two pushes in a row: if the job of the first push runs after the second push, its
        # commit is no longer the head of the pull request, and it must not cancel the UI run
        # of the newer commit.
        api = FakeApi(head="c" * 40, runs=[run(11, sha=NEW), run(12)])
        code, out = self.main(api)
        self.assertEqual((code, api.cancelled), (0, []))
        self.assertIn("newer", out)

    def test_a_run_that_ended_meanwhile_is_no_failure(self):
        # GitHub answers 409 when the run finished between the listing and the cancel.
        api = FakeApi(runs=[run(11), run(12)], refuse={11})
        code, out = self.main(api)
        self.assertEqual((code, api.cancelled), (0, [12]))
        self.assertIn("409", out)

    def test_nothing_to_cancel(self):
        code, out = self.main(FakeApi(runs=[run(11, sha=NEW)]))
        self.assertEqual(code, 0)
        self.assertIn("nothing", out.lower())


class WorkflowTests(unittest.TestCase):
    """The workflow that calls the script (.github/workflows/ui-supersede.yml)."""

    def setUp(self):
        with open(os.path.join(ROOT, ".github", "workflows", "ui-supersede.yml"), encoding="utf-8") as f:
            self.text = f.read()
        self.code = "\n".join(line.split("#", 1)[0] for line in self.text.splitlines())

    def test_runs_on_the_pushes_that_start_a_ui_run(self):
        with open(os.path.join(ROOT, ".github", "workflows", "ui.yml"), encoding="utf-8") as f:
            ui = f.read()
        self.assertIn("pull_request:\n    paths-ignore: ['**.md']", ui)
        self.assertIn("pull_request:\n    paths-ignore: ['**.md']", self.code)

    def test_outside_the_mac_queue_and_one_per_pull_request(self):
        # In "mac-queue" it would wait behind the very run it has to cancel.
        self.assertNotIn("mac-queue", self.code)
        self.assertIn("group: ui-supersede-${{ github.event.pull_request.number }}", self.code)
        self.assertIn("cancel-in-progress: true", self.code)

    def test_least_rights_and_no_forks(self):
        self.assertIn("permissions: {}", self.code)
        self.assertIn("actions: write", self.code)
        self.assertNotIn("contents: write", self.code)
        self.assertIn("!github.event.pull_request.head.repo.fork", self.code)
        self.assertIn("persist-credentials: false", self.code)

    def test_the_mac_queue_comment_points_here(self):
        with open(os.path.join(ROOT, ".github", "workflows", "ui.yml"), encoding="utf-8") as f:
            ui = f.read()
        self.assertIn("ui-supersede.yml", ui)
        self.assertNotIn("Not done: cancelling the older run of the same branch", ui)


if __name__ == "__main__":
    unittest.main()
