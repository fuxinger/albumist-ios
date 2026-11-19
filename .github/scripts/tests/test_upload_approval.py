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

    def test_a_private_repository_is_refused_unless_the_owner_says_his_plan_has_environments(self):
        # GitHub Free has no environments, environment secrets or branch rules in a private
        # repository (GitHub Pro, Team or Enterprise has). The API may still list a rule there
        # that GitHub does not enforce, and the token cannot read the plan: so a private
        # repository is refused, even with the rule main, until the owner sets the repository
        # variable UPLOAD_PRIVATE_PLAN_OK to "true" (third review of fix/pipeline).
        for environment, branches in ((None, None), (CREATED_BY_A_JOB, None), (SET_UP, MAIN), (WITH_REVIEWER, MAIN)):
            with self.subTest(environment=environment):
                problems, _, _ = upload_approval.review(environment, public=False, branches=branches)
                self.assertEqual(len(problems), 1)
                for words in ("private", "GitHub Free", "UPLOAD_PRIVATE_PLAN_OK"):
                    self.assertIn(words, problems[0])
        # With the variable, the same checks as in a public repository, and a note says why.
        problems, warnings, notes = upload_approval.review(SET_UP, public=False, branches=MAIN, plan_ok=True)
        self.assertEqual((problems, warnings), ([], []))
        self.assertTrue(any("UPLOAD_PRIVATE_PLAN_OK" in n for n in notes), notes)
        for environment, branches, why in ((None, None, "does not exist"), (CREATED_BY_A_JOB, None, "other branches"),
                                           (SET_UP, MAIN + [{"name": "dev"}], "other branches")):
            with self.subTest(why=why, plan_ok=True):
                problems, _, _ = upload_approval.review(environment, public=False, branches=branches, plan_ok=True)
                self.assertEqual(len(problems), 1)
                self.assertIn(why, problems[0])
        # A public repository needs no variable.
        self.assertEqual(upload_approval.review(SET_UP, branches=MAIN, plan_ok=False)[0], [])

    def test_only_the_word_true_says_the_plan_has_environments(self):
        for value, ok in (("true", True), ("TRUE", True), (" true\n", True), ("", False), ("false", False),
                          ("1", False), ("yes", False)):
            with self.subTest(value=value):
                self.assertEqual(upload_approval.private_plan_ok({upload_approval.PLAN_VARIABLE: value}), ok)
        self.assertFalse(upload_approval.private_plan_ok({}))
        self.assertEqual(upload_approval.PLAN_VARIABLE, "UPLOAD_PRIVATE_PLAN_OK")

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

    def check(self, answer, public=True, branches=MAIN, plan_ok=False, main=(True, "a ruleset requires a pull request")):
        def fetcher():
            if isinstance(answer, Exception):
                raise answer
            return answer

        def visibility():
            if isinstance(public, Exception):
                raise public
            return public
        with contextlib.redirect_stdout(io.StringIO()) as log:
            def protection():
                if isinstance(main, Exception):
                    raise main
                return main
            code = upload_approval.check(fetcher, visibility, lambda: branches, lambda: plan_ok, protection)
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

    def test_a_private_repository_goes_on_only_with_the_owners_variable(self):
        code, log = self.check(SET_UP, public=False)
        self.assertEqual(code, 1)
        self.assertIn("GitHub Free", log)
        self.assertIn("UPLOAD_PRIVATE_PLAN_OK", log)
        self.assertEqual(self.read(self.output), "")
        code, log = self.check(SET_UP, public=False, plan_ok=True)
        self.assertEqual(code, 0, log)
        self.assertEqual(self.read(self.output), "ready=true\n")
        self.assertIn("UPLOAD_PRIVATE_PLAN_OK", self.read(self.summary))

    def test_an_unprotected_main_is_a_warning_never_a_block(self):
        # The branch rule of the environment is the only fence since 19.11.: whoever can push to
        # main can upload. When nothing requires a pull request on main, say so (third review).
        for main, words in (((False, "no ruleset requires a pull request"), upload_approval.UNPROTECTED),
                            ((None, "cannot read the branch protection"), "could not be checked"),
                            (upload_approval.ApiError("down"), "could not be checked")):
            with self.subTest(main=main):
                os.remove(self.output) if os.path.exists(self.output) else None
                code, log = self.check(SET_UP, main=main)
                self.assertEqual(code, 0, log)
                self.assertEqual(self.read(self.output), "ready=true\n")
                self.assertIn("::warning title=Upload setup::", log)
                self.assertIn(words, log)
                self.assertIn(words, self.read(self.summary))
        self.assertEqual(upload_approval.UNPROTECTED, "main ist nicht geschützt: wer auf main pushen kann, kann hochladen")
        code, log = self.check(SET_UP)
        self.assertEqual(code, 0, log)
        self.assertNotIn("::warning", log)
        self.assertIn("pull request", self.read(self.summary))

    def test_the_protection_of_main_is_read_from_rulesets_and_branch_protection(self):
        pull = {"type": "pull_request", "ruleset_source_type": "Repository", "ruleset_id": 7,
                "parameters": {"required_approving_review_count": 0}}
        forbidden = upload_approval.ApiError("GitHub API: HTTP 403")
        for answers, protected in (
                ({"rules/branches/main": [pull]}, True),
                ({"rules/branches/main": [{"type": "deletion"}], "branches/main": {"protected": False}}, False),
                ({"rules/branches/main": [], "branches/main": {"name": "main"}}, False),
                ({"rules/branches/main": [], "branches/main": {"protected": True},
                  "branches/main/protection/required_pull_request_reviews": {"required_approving_review_count": 1}}, True),
                ({"rules/branches/main": [], "branches/main": {"protected": True},
                  "branches/main/protection/required_pull_request_reviews": None}, False),
                ({"rules/branches/main": [{"type": "non_fast_forward"}], "branches/main": {"protected": True},
                  "branches/main/protection/required_pull_request_reviews": forbidden}, None)):
            with self.subTest(answers=answers):
                asked = []

                def get(path, **_):
                    asked.append(path)
                    answer = answers[path]
                    if isinstance(answer, Exception):
                        raise answer
                    return answer
                found, how = upload_approval.main_protection(get)
                self.assertIs(found, protected, how)
                self.assertTrue(how)
                self.assertEqual(asked, [p for p in answers][:len(asked)])
        # A failed read of the rulesets is the caller's to report (check: a warning, no block).
        with self.assertRaises(upload_approval.ApiError):
            upload_approval.main_protection(lambda path, **_: (_ for _ in ()).throw(upload_approval.ApiError("down")))

    def test_a_forbidden_answer_is_not_tried_again_when_it_cannot_change(self):
        import urllib.error
        import urllib.request
        calls, sleeps = [], []
        originals = urllib.request.urlopen, upload_approval.time.sleep
        self.addCleanup(lambda: (setattr(urllib.request, "urlopen", originals[0]),
                                 setattr(upload_approval.time, "sleep", originals[1])))
        from unittest import mock
        environment = mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "owner/repo", "GH_TOKEN": "token"})
        environment.start()
        self.addCleanup(environment.stop)

        def forbidden(request, timeout):
            calls.append(request.full_url)
            raise urllib.error.HTTPError(request.full_url, 403, "Forbidden", {}, None)
        urllib.request.urlopen, upload_approval.time.sleep = forbidden, sleeps.append
        with self.assertRaisesRegex(upload_approval.ApiError, "HTTP 403"):
            upload_approval._get("branches/main/protection/required_pull_request_reviews", final=(403,))
        self.assertEqual((len(calls), sleeps), (1, []))
        with self.assertRaises(upload_approval.ApiError):
            upload_approval._get("environments/testflight-upload")
        self.assertEqual(len(calls), 4)  # three tries without final

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


class NotUploadedTests(unittest.TestCase):
    """"Re-run all jobs" on a run that uploaded must not upload again (third review of
    fix/pipeline): the run's build number is its run number, and the tag job gives every uploaded
    build the tag build-<run number>. Both the first job and the start of the upload job stop
    when that tag exists."""

    def setUp(self):
        from unittest import mock
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.summary = os.path.join(folder.name, "summary")
        environment = mock.patch.dict(os.environ, {"GITHUB_RUN_NUMBER": "41", "GITHUB_STEP_SUMMARY": self.summary})
        environment.start()
        self.addCleanup(environment.stop)

    def run_it(self, answer):
        asked = []

        def get(path, **_):
            asked.append(path)
            if isinstance(answer, Exception):
                raise answer
            return answer
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = upload_approval.not_uploaded(get)
        return code, log.getvalue(), asked

    def test_no_tag_goes_on(self):
        code, log, asked = self.run_it(None)
        self.assertEqual(code, 0, log)
        self.assertEqual(asked, ["git/ref/tags/build-41"])
        self.assertIn("build-41", log)

    def test_the_tag_of_this_run_stops_it(self):
        tag = {"ref": "refs/tags/build-41", "object": {"type": "tag", "sha": "f" * 40}}
        code, log, _ = self.run_it(tag)
        self.assertEqual(code, 1)
        self.assertIn("::error title=Already uploaded::", log)
        for words in ("TestFlight build 41", "build-41", "Run workflow"):
            self.assertIn(words, log)
        with open(self.summary, encoding="utf-8") as out:
            self.assertIn("already uploaded", out.read())

    def test_only_this_exact_tag_counts(self):
        # GET git/ref is exact; an answer for another ref (a list, as git/refs gives) is not it.
        code, log, _ = self.run_it([{"ref": "refs/tags/build-410", "object": {"type": "tag", "sha": "f" * 40}}])
        self.assertEqual(code, 0, log)

    def test_no_answer_is_no_upload(self):
        code, log, _ = self.run_it(upload_approval.ApiError("down"))
        self.assertEqual(code, 1)
        self.assertIn("re-run this job", log)

    def test_the_command_is_there(self):
        originals = upload_approval.not_uploaded
        self.addCleanup(setattr, upload_approval, "not_uploaded", originals)
        upload_approval.not_uploaded = lambda: 7
        self.assertEqual(upload_approval.main(["not-uploaded"]), 7)


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
                         upload_approval.review(dict(SET_UP, deployment_branch_policy=None), public=False),
                         upload_approval.review(SET_UP, public=False, branches=MAIN)):
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
