"""Unit tests for .github/scripts/upload_approval.py and daily_build.py (the upload runs only in the
environment testflight-upload, which only the branch main may use; since the owner's decision of
19.11.2026 without a click; the daily build starts only when there is something new). No API call: the
answers are written here the way GitHub's REST API gives them.

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import daily_build  # noqa: E402
import upload_approval  # noqa: E402

OWNER = {"type": "User", "reviewer": {"login": "owner", "id": 1}}
# GET /repos/{repo}/environments/testflight-upload as set up in docs/launch/FREIGABE_EINRICHTEN.md
# since 19.11.2026: no required reviewer, only the branch rule.
SET_UP = {"name": "testflight-upload",
          "protection_rules": [{"id": 2, "type": "branch_policy"}],
          "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True}}
# The set-up of 18.11. (decision 5): the owner as required reviewer as well.
WITH_REVIEWER = dict(SET_UP, protection_rules=[{"id": 1, "type": "required_reviewers", "prevent_self_review": False,
                                                "reviewers": [OWNER]}, {"id": 2, "type": "branch_policy"}])
# What GitHub creates when a job names an environment that does not exist: no rule at all.
# GET .../environments/testflight-upload/deployment-branch-policies as set up there (step 3).
MAIN = [{"id": 3, "name": "main", "type": "branch"}]
CREATED_BY_A_JOB = {"name": "testflight-upload", "protection_rules": [], "deployment_branch_policy": None}


class ReviewTests(unittest.TestCase):
    def test_no_reviewer_is_needed(self):
        # The owner's decision of 19.11.2026: the upload runs without a click once every gate is
        # green; the environment's branch rule (main only) is the fence.
        self.assertEqual(upload_approval.review(SET_UP, branches=MAIN)[0], [])

    def test_a_missing_or_unfenced_environment_is_refused(self):
        # GitHub creates an environment a job names without any rule; the check stops the run
        # before the upload job could do that.
        for environment, why in ((None, "does not exist"), (CREATED_BY_A_JOB, "other branches than main")):
            with self.subTest(why=why):
                problems, _, _ = upload_approval.review(environment, branches=None)
                self.assertEqual(len(problems), 1)
                self.assertIn(why, problems[0])

    def test_a_private_repository_needs_a_working_branch_rule(self):
        # GitHub Free has no environments, environment secrets or branch rules in a private
        # repository (GitHub Pro, Team or Enterprise has). Without a rule the API shows, refused,
        # and the message says why; with one, a warning names the plan it needs.
        for environment, branches in ((None, None), (CREATED_BY_A_JOB, None), (dict(SET_UP, deployment_branch_policy=None), MAIN)):
            with self.subTest(environment=environment):
                problems, _, _ = upload_approval.review(environment, public=False, branches=branches)
                self.assertEqual(len(problems), 1)
                self.assertIn("private", problems[0])
                self.assertIn("GitHub Free", problems[0])
        problems, warnings, _ = upload_approval.review(SET_UP, public=False, branches=MAIN)
        self.assertEqual(problems, [])
        self.assertTrue(any("GitHub Pro, Team or Enterprise" in w for w in warnings), warnings)

    def test_a_reviewer_left_in_place_is_a_warning(self):
        problems, warnings, _ = upload_approval.review(WITH_REVIEWER, branches=MAIN)
        self.assertEqual(problems, [])
        self.assertIn("required reviewer", warnings[0])

    def test_only_the_branch_main_may_use_the_environment(self):
        # Second review of bundle-p: a changed testflight.yml from another branch must not reach
        # the owner's approval under a misleading name, so anything but "main only" stops the run.
        protected = {"protected_branches": True, "custom_branch_policies": False}
        for environment, branches, why in (
                (dict(SET_UP, deployment_branch_policy=None), None, "no rule"),
                (dict(SET_UP, deployment_branch_policy=protected), None, "protected branches"),
                (SET_UP, [], "custom without a rule"),
                (SET_UP, [{"name": "*", "type": "branch"}], "every branch by pattern"),
                (SET_UP, MAIN + [{"name": "dev", "type": "branch"}], "main and another"),
                (SET_UP, [{"name": "main", "type": "tag"}], "a tag named main"),
                (dict(SET_UP, deployment_branch_policy=protected), MAIN, "protected branches, rules listed"),
                (dict(SET_UP, deployment_branch_policy=None), MAIN, "no rule, rules listed")):
            with self.subTest(why=why):
                problems, _, _ = upload_approval.review(environment, branches=branches)
                self.assertEqual(len(problems), 1)
                self.assertIn("other branches than main", problems[0])

    def test_a_rule_without_a_type_is_a_branch_rule(self):
        # Answers from before GitHub added tag rules name no type; such a rule is a branch rule.
        self.assertEqual(upload_approval.review(SET_UP, branches=[{"id": 3, "name": "main"}])[0], [])

    def test_the_rules_are_read_from_branch_policies(self):
        originals = upload_approval._get
        self.addCleanup(setattr, upload_approval, "_get", originals)
        paths = []
        upload_approval._get = lambda path: paths.append(path) or {"total_count": 1, "branch_policies": MAIN}
        self.assertEqual(upload_approval.fetch_branches(), MAIN)
        self.assertEqual(paths, ["environments/testflight-upload/deployment-branch-policies"])
        upload_approval._get = lambda path: None
        self.assertIsNone(upload_approval.fetch_branches())
        self.assertIsNone(upload_approval.branches_of(CREATED_BY_A_JOB, lambda: MAIN))
        self.assertEqual(upload_approval.branches_of(SET_UP, lambda: MAIN), MAIN)


class CheckTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.output, self.summary = os.path.join(folder.name, "out"), os.path.join(folder.name, "summary")
        saved = {k: os.environ.get(k) for k in ("GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY")}
        os.environ.update(GITHUB_OUTPUT=self.output, GITHUB_STEP_SUMMARY=self.summary)
        self.addCleanup(lambda: [os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
                                 for k, v in saved.items()])

    def read(self, path):
        if not os.path.exists(path):
            return ""
        with open(path, encoding="utf-8") as f:
            return f.read()

    def check(self, answer, public=True, branches=MAIN):
        def fetcher():
            if isinstance(answer, Exception):
                raise answer
            return answer

        def visibility():
            if isinstance(public, Exception):
                raise public
            return public
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = upload_approval.check(fetcher, visibility, lambda: branches)
        return code, log.getvalue()

    def test_set_up(self):
        code, log = self.check(SET_UP)
        self.assertEqual(code, 0, log)
        self.assertEqual(self.read(self.output), "ready=true\n")
        self.assertIn("runs by itself once every gate is green", self.read(self.summary))
        self.assertNotIn("approv", self.read(self.summary).lower())

    def test_not_set_up_stops_the_run_and_says_where_the_steps_are(self):
        for answer in (None, CREATED_BY_A_JOB):
            with self.subTest(answer=answer):
                code, log = self.check(answer)
                self.assertEqual(code, 1)
                self.assertIn("::error title=Upload setup::", log)
                self.assertIn(upload_approval.SETUP, log)
                self.assertIn("No upload: the upload environment is not set up", self.read(self.summary))
                self.assertEqual(self.read(self.output), "")

    def test_no_answer_is_no_upload(self):
        for answer, public in ((upload_approval.ApiError("down"), True), (SET_UP, upload_approval.ApiError("down"))):
            with self.subTest(answer=answer, public=public):
                code, log = self.check(answer, public)
                self.assertEqual(code, 1)
                self.assertIn("re-run this job", log)
                self.assertEqual(self.read(self.output), "")

    def test_a_private_repository_goes_on_only_with_the_branch_rule(self):
        code, log = self.check(SET_UP, public=False)
        self.assertEqual(code, 0, log)
        self.assertIn("GitHub Pro, Team or Enterprise", log)
        code, log = self.check(dict(SET_UP, deployment_branch_policy=None), public=False, branches=None)
        self.assertEqual(code, 1)
        self.assertIn("GitHub Free", log)
        self.assertEqual(self.read(self.output), "ready=true\n")  # from the first check only

    def test_visibility_is_read_from_the_repository(self):
        originals = upload_approval._get
        self.addCleanup(setattr, upload_approval, "_get", originals)
        for answer, public in (({"private": False, "visibility": "public"}, True),
                               ({"private": True, "visibility": "private"}, False),
                               ({"private": True, "visibility": "internal"}, False),
                               ({"private": False}, True), ({}, False)):
            with self.subTest(answer=answer):
                upload_approval._get = lambda path, answer=answer: answer
                self.assertEqual(upload_approval.fetch_public(), public)
        upload_approval._get = lambda path: None
        with self.assertRaises(upload_approval.ApiError):
            upload_approval.fetch_public()


APPROVED = upload_approval.review(SET_UP, branches=MAIN)
HEAD, OLD = "a" * 40, "b" * 40
APPS = {HEAD: "1" * 64, OLD: "2" * 64, "c" * 40: "1" * 64}


def run(number, sha, status="completed", conclusion="success"):
    return {"id": 1000 + number, "run_number": number, "head_sha": sha, "status": status, "conclusion": conclusion,
            "html_url": f"https://example/run/{number}"}


class DailyBuildTests(unittest.TestCase):
    def decide(self, runs=(), tags=None, approval=APPROVED, passed=lambda r: True, docs_only=lambda sha: False):
        return daily_build.decide(HEAD, APPS[HEAD], list(runs), tags or {}, approval, APPS.get, passed, docs_only)

    def test_a_new_app_starts_the_small_gate(self):
        start, why = self.decide([run(40, OLD)], {"build-40": OLD})
        self.assertTrue(start, why)
        self.assertIn("small gate", why)

    def test_never_before_the_approval_is_set_up(self):
        for approval in (upload_approval.review(None), upload_approval.review(CREATED_BY_A_JOB),
                         upload_approval.review(dict(SET_UP, deployment_branch_policy=None), public=False)):
            with self.subTest(approval=approval):
                start, why = self.decide(approval=approval)
                self.assertFalse(start)
                self.assertIn(upload_approval.SETUP, why)

    def test_never_while_another_run_runs_or_waits(self):
        # Since 19.11.2026 a daily build uploads by itself; never a second run beside or behind one.
        for status in ("queued", "in_progress", "waiting", "pending", "requested"):
            with self.subTest(status=status):
                start, why = self.decide([run(41, OLD, status=status, conclusion=None)])
                self.assertFalse(start)
                self.assertIn("TestFlight run 41", why)

    def test_an_unchanged_app_gives_no_new_build(self):
        # build-38 is on commit c, whose app is the same as now (only docs or tests changed since).
        start, why = self.decide([run(40, OLD)], {"build-38": "c" * 40, "build-40": OLD})
        self.assertFalse(start)
        self.assertIn("build-38", why)

    def test_the_same_commit_is_not_tried_again(self):
        for conclusion in ("failure", "cancelled"):
            with self.subTest(conclusion=conclusion):
                start, why = self.decide([run(42, HEAD, conclusion=conclusion)])
                self.assertFalse(start)
                self.assertIn("tested exactly this commit already", why)
        # A run that stopped in its first job (approval not set up then) tested nothing.
        start, why = self.decide([run(42, HEAD, conclusion="failure")], passed=lambda r: False)
        self.assertTrue(start, why)

    def test_the_same_app_is_not_tried_again_after_a_docs_only_commit(self):
        # Run 42 on commit c (same app as HEAD) was red or rejected; since then only docs changed.
        # The next morning must not run the unchanged app and tests again until one goes green.
        same_app = "c" * 40
        for conclusion in ("failure", "cancelled"):
            with self.subTest(conclusion=conclusion):
                start, why = self.decide([run(42, same_app, conclusion=conclusion)], docs_only=lambda sha: True)
                self.assertFalse(start)
                self.assertIn("only documentation changed since", why)
        # Tests or the pipeline changed since (a fix of a flaky test): a new run is right.
        start, why = self.decide([run(42, same_app, conclusion="failure")], docs_only=lambda sha: False)
        self.assertTrue(start, why)
        # Another app on that commit: only docs between them cannot be, but the app decides.
        start, why = self.decide([run(42, OLD, conclusion="failure")], docs_only=lambda sha: True)
        self.assertTrue(start, why)

    def test_docs_only_since_reads_the_diff(self):
        import subprocess
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        git = lambda *a: subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *a], cwd=folder.name,
                                        check=True, capture_output=True, text=True).stdout.strip()
        git("init", "-q")
        os.makedirs(os.path.join(folder.name, "docs"))
        for name in ("docs/a.md", "README.md", "app.swift"):
            with open(os.path.join(folder.name, name), "w") as f:
                f.write("1")
        git("add", "-A"); git("commit", "-qm", "1")
        first = git("rev-parse", "HEAD")
        for name in ("docs/a.md", "README.md"):
            with open(os.path.join(folder.name, name), "w") as f:
                f.write("2")
        git("commit", "-qam", "2")
        docs = git("rev-parse", "HEAD")
        with open(os.path.join(folder.name, "app.swift"), "w") as f:
            f.write("2")
        git("commit", "-qam", "3")
        code = git("rev-parse", "HEAD")
        self.assertTrue(daily_build.docs_only_since(first, docs, folder.name))
        self.assertFalse(daily_build.docs_only_since(first, code, folder.name))
        self.assertFalse(daily_build.docs_only_since("f" * 40, docs, folder.name))  # not in the checkout

    def test_build_tags_point_at_their_commits(self):
        import subprocess
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        git = ["git", "-C", folder.name, "-c", "user.name=t", "-c", "user.email=t@example.invalid"]
        subprocess.run(git + ["init", "-q"], check=True)
        subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "one"], check=True)
        first = subprocess.run(git + ["rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        subprocess.run(git + ["tag", "build-7"], check=True)  # lightweight
        subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "two"], check=True)
        second = subprocess.run(git + ["rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        subprocess.run(git + ["tag", "-a", "build-8", "-m", "TestFlight build 8"], check=True)  # as testflight.yml
        subprocess.run(git + ["tag", "build-x"], check=True)
        self.assertEqual(daily_build.build_tags(folder.name), {"build-7": first, "build-8": second})

    def test_the_command_writes_its_answer_and_never_fails_the_job(self):
        # The whole command on this checkout, with the API faked: an unanswered API means no
        # build today (and a green job that says why), never an upload without the checks.
        import ui_evidence
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        output, summary = os.path.join(folder.name, "out"), os.path.join(folder.name, "summary")
        saved = {k: os.environ.get(k) for k in ("GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY")}
        os.environ.update(GITHUB_OUTPUT=output, GITHUB_STEP_SUMMARY=summary)
        self.addCleanup(lambda: [os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
                                 for k, v in saved.items()])
        originals = (upload_approval.fetch, ui_evidence.api, upload_approval.fetch_public, upload_approval.fetch_branches)
        self.addCleanup(lambda: (setattr(upload_approval, "fetch", originals[0]), setattr(ui_evidence, "api", originals[1]),
                                 setattr(upload_approval, "fetch_public", originals[2]),
                                 setattr(upload_approval, "fetch_branches", originals[3])))
        upload_approval.fetch_public = lambda: True
        upload_approval.fetch_branches = lambda: MAIN

        def runs(path, **params):
            if path.endswith("/runs"):
                return {"workflow_runs": [run(50, OLD, status="waiting", conclusion=None)]}
            raise AssertionError(path)
        upload_approval.fetch, ui_evidence.api = (lambda: SET_UP), runs
        with contextlib.redirect_stdout(io.StringIO()) as log:
            self.assertEqual(daily_build.main(["decide"]), 0)
        self.assertIn("DAILY_BUILD no build: TestFlight run 50", log.getvalue())
        with open(output, encoding="utf-8") as f:
            self.assertEqual(f.read(), "start=false\n")

        # An environment that other branches may use: no daily build either.
        upload_approval.fetch_branches = lambda: [{"name": "*", "type": "branch"}]
        os.remove(output)
        with contextlib.redirect_stdout(io.StringIO()) as log:
            self.assertEqual(daily_build.main(["decide"]), 0)
        self.assertIn("other branches than main", log.getvalue())
        with open(output, encoding="utf-8") as f:
            self.assertEqual(f.read(), "start=false\n")
        upload_approval.fetch_branches = lambda: MAIN

        def down():
            raise upload_approval.ApiError("down")
        upload_approval.fetch = down
        os.remove(output)
        with contextlib.redirect_stdout(io.StringIO()) as log:
            self.assertEqual(daily_build.main(["decide"]), 0)
        self.assertIn("GitHub API did not answer", log.getvalue())
        with open(output, encoding="utf-8") as f:
            self.assertEqual(f.read(), "start=false\n")

    def test_the_check_job_name_is_read_from_the_jobs_of_the_run(self):
        jobs = {"jobs": [{"name": daily_build.CHECK_JOB, "conclusion": "success"}, {"name": "Tests", "conclusion": "failure"}]}
        self.assertTrue(daily_build.got_past_the_check(lambda path, **params: jobs, run(42, HEAD)))
        jobs["jobs"][0]["conclusion"] = "failure"
        self.assertFalse(daily_build.got_past_the_check(lambda path, **params: jobs, run(42, HEAD)))
        # Runs of before 19.11. named it "Upload approval".
        old = {"jobs": [{"name": "Upload approval", "conclusion": "success"}]}
        self.assertTrue(daily_build.got_past_the_check(lambda path, **params: old, run(43, HEAD)))


if __name__ == "__main__":
    unittest.main()
