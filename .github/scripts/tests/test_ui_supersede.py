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


JOB_CREATED = "2026-11-19T10:00:00Z"  # this job's own run


def run(run_id, sha=OLD, status="in_progress", branch=BRANCH, event="pull_request",
        path=".github/workflows/ui.yml", repo=REPO, created="2026-11-19T09:00:00Z"):
    return {"id": run_id, "head_sha": sha, "status": status, "head_branch": branch, "event": event,
            "path": path, "head_repository": {"full_name": repo}, "created_at": created}


class OlderRunsTests(unittest.TestCase):
    def ids(self, runs):
        return ui_supersede.older_runs(runs, REPO, BRANCH, NEW, JOB_CREATED)

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

    def test_a_run_created_after_this_job_is_never_cancelled(self):
        # Second review, 19.11.: the job of push A reads the head (A), push B lands, B's UI run
        # is created, and A's job lists it: another commit than A, but newer. Only runs created
        # before this job's own run are older.
        runs = [run(1, sha="c" * 40, created="2026-11-19T10:00:05Z"),
                run(2, created=JOB_CREATED), run(3, created="2026-11-19T09:59:59Z")]
        self.assertEqual(self.ids(runs), [3])

    def test_a_run_without_its_repository_or_time_is_not_cancelled(self):
        no_time = run(2)
        del no_time["created_at"]
        self.assertEqual(self.ids([no_time]), [])

    def test_a_run_without_its_repository_is_not_cancelled(self):
        broken = run(1)
        broken["head_repository"] = None
        self.assertEqual(self.ids([broken]), [])


class ReadyForReviewTests(unittest.TestCase):
    """Stage 1 (26.11.2026): when a draft is marked ready for review, the head stays the same and
    the draft's smoke run of that commit gives way to the full run of the ready event."""

    def ids(self, runs, ready=True):
        return ui_supersede.older_runs(runs, REPO, BRANCH, NEW, JOB_CREATED, same_commit=ready)

    def test_the_smoke_run_of_the_same_commit_is_cancelled_when_ready(self):
        self.assertEqual(self.ids([run(1, sha=NEW, created="2026-11-19T09:40:00Z")]), [1])

    def test_without_the_ready_event_the_same_commit_stays(self):
        self.assertEqual(self.ids([run(1, sha=NEW, created="2026-11-19T09:40:00Z")], ready=False), [])

    def test_the_full_run_of_the_ready_event_itself_is_never_cancelled(self):
        # Created in the same second as this job's run, or one second before it.
        runs = [run(1, sha=NEW, created=JOB_CREATED), run(2, sha=NEW, created="2026-11-19T09:59:59Z"),
                run(3, sha=NEW, created="2026-11-19T09:59:01Z")]
        self.assertEqual(self.ids(runs), [])

    def test_the_gap_is_sixty_seconds(self):
        self.assertEqual(self.ids([run(1, sha=NEW, created="2026-11-19T09:59:00Z")]), [1])
        self.assertEqual(self.ids([run(1, sha=NEW, created="2026-11-19T09:59:01Z")]), [])

    def test_older_commits_are_cancelled_as_before(self):
        self.assertEqual(self.ids([run(1, created="2026-11-19T09:59:59Z")]), [1])

    def test_main_reads_the_action(self):
        env = {"GITHUB_REPOSITORY": REPO, "PR_NUMBER": "9", "HEAD_SHA": NEW, "HEAD_REF": BRANCH,
               "GITHUB_RUN_ID": "77", "ACTION": "ready_for_review"}
        api = FakeApi(runs=[run(5, sha=NEW, created="2026-11-19T09:30:00Z"), run(6, sha=NEW, created=JOB_CREATED)])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(ui_supersede.main(api, env), 0)
        self.assertEqual(api.cancelled, [5])
        self.assertIn("ready for review", out.getvalue())


class FakeApi:
    def __init__(self, head=NEW, runs=(), refuse=(), heads=None):
        self.head, self.runs, self.refuse = head, list(runs), dict.fromkeys(refuse, 409)
        self.heads = list(heads) if heads else None  # the head at each read, in order
        self.calls, self.cancelled = [], []

    def __call__(self, path, method="GET", **params):
        self.calls.append((method, path, params))
        if path == "pulls/9":
            head = self.heads.pop(0) if self.heads else self.head
            return {"head": {"sha": head, "ref": BRANCH}}
        if path == "actions/runs/77":
            return {"id": 77, "created_at": JOB_CREATED}
        if path == "actions/workflows/ui.yml/runs":
            return {"workflow_runs": self.runs}
        if path.startswith("actions/runs/") and path.endswith("/cancel") and method == "POST":
            run_id = int(path.split("/")[2])
            if run_id in self.refuse:
                raise ui_supersede.ApiError(f"{path}: HTTP Error {self.refuse[run_id]}", self.refuse[run_id])
            self.cancelled.append(run_id)
            return {}
        raise AssertionError(f"unexpected call {method} {path}")


class MainTests(unittest.TestCase):
    def setUp(self):
        self.env = {"GITHUB_REPOSITORY": REPO, "PR_NUMBER": "9", "HEAD_SHA": NEW, "HEAD_REF": BRANCH,
                    "GITHUB_RUN_ID": "77"}

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

    def test_a_push_during_the_listing_cancels_nothing(self):
        # The head was this job's commit at the first read and moved before the cancel.
        api = FakeApi(heads=[NEW, "c" * 40], runs=[run(11), run(12)])
        code, out = self.main(api)
        self.assertEqual((code, api.cancelled), (0, []))
        self.assertIn("meanwhile", out)

    def test_a_refused_cancel_names_its_reason(self):
        # 403: no permission (e.g. a Dependabot pull request gets a read-only token).
        api = FakeApi(runs=[run(11)])
        api.refuse = {11: 403}
        code, out = self.main(api)
        self.assertEqual((code, api.cancelled), (0, []))
        self.assertIn("403", out)
        self.assertNotIn("ended", out)

    def test_never_on_the_default_branch(self):
        for default in ("main", "trunk"):
            with self.subTest(default=default):
                self.env.update(HEAD_REF=default, DEFAULT_BRANCH=default)
                api = FakeApi(runs=[run(11, branch=default)])
                code, out = self.main(api)
                self.assertEqual((code, api.cancelled, api.calls), (0, [], []))

    def test_a_403_on_a_run_whose_id_contains_409_is_no_ended_run(self):
        api = FakeApi(runs=[run(14090)])
        api.refuse = {14090: 403}
        code, out = self.main(api)
        self.assertNotIn("ended", out)

    def test_a_run_that_ended_meanwhile_is_no_failure(self):
        # GitHub answers 409 when the run finished between the listing and the cancel.
        api = FakeApi(runs=[run(11), run(12)], refuse={11})
        code, out = self.main(api)
        self.assertEqual((code, api.cancelled), (0, [12]))
        self.assertIn("409", out)
        self.assertIn("ended meanwhile", out)

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
        # The same events as ui.yml's pull request runs, ready_for_review too (stage 1, 26.11.).
        def code(text):
            return "\n".join(line for line in text.splitlines() if not line.strip().startswith("#"))
        types = "pull_request:\n    types: [opened, synchronize, reopened, ready_for_review]\n    paths-ignore: ['**.md']"
        self.assertIn(types, code(ui))
        self.assertIn(types, code(self.text))
        self.assertIn("ACTION: ${{ github.event.action }}", self.code)

    def test_outside_the_mac_queue_and_one_per_pull_request(self):
        # In "mac-queue" it would wait behind the very run it has to cancel.
        self.assertNotIn("mac-queue", self.code)
        self.assertIn("group: ui-supersede-${{ github.event.pull_request.number }}", self.code)
        self.assertIn("cancel-in-progress: true", self.code)

    def test_least_rights_and_no_forks(self):
        self.assertIn("permissions: {}", self.code)
        self.assertIn("actions: write", self.code)
        self.assertNotIn("contents: write", self.code)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", self.code)
        self.assertIn("GITHUB_RUN_ID", open(os.path.join(ROOT, ".github", "scripts", "ui_supersede.py"),
                                            encoding="utf-8").read())
        self.assertIn("persist-credentials: false", self.code)

    def test_the_mac_queue_comment_points_here(self):
        with open(os.path.join(ROOT, ".github", "workflows", "ui.yml"), encoding="utf-8") as f:
            ui = f.read()
        self.assertIn("ui-supersede.yml", ui)
        self.assertNotIn("Not done: cancelling the older run of the same branch", ui)


if __name__ == "__main__":
    unittest.main()
