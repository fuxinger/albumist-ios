"""Checks over all workflow files (plain text, no YAML library needed).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import glob
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
WORKFLOWS = sorted(glob.glob(os.path.join(ROOT, ".github", "workflows", "*.yml")))


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class CacheTests(unittest.TestCase):
    """No Actions cache anywhere: the owner's rule (a Mac build cache only if it provably cannot ship
    stale code; none is used)."""

    def test_no_workflow_restores_a_cache(self):
        self.assertTrue(WORKFLOWS)
        for path in WORKFLOWS:
            text = "\n".join(line.split("#", 1)[0] for line in read(path).splitlines())
            with self.subTest(workflow=os.path.basename(path)):
                self.assertNotRegex(text, r"actions/cache(?:/restore|/save)?@")
                self.assertNotRegex(text, r"\n\s+cache(?:-dependency-path)?:\s*\S")

    def test_checkouts_of_another_ref_keep_no_token(self):
        for path in WORKFLOWS:
            steps = re.split(r"\n\s+- ", read(path))
            for step in steps:
                if "actions/checkout@" in step and re.search(r"\n\s+ref:", step):
                    with self.subTest(workflow=os.path.basename(path)):
                        self.assertIn("persist-credentials: false", step)


    def test_scheduled_workflows_check_out_only_their_own_commit(self):
        # CodeQL actions/cache-poisoning (PR #1, PR #7): nightly.yml checked out another ref
        # (needs.pick.outputs.sha) in the default branch's context. A scheduled workflow tests
        # the commit it runs on.
        for path in WORKFLOWS:
            text = read(path)
            trigger = text.split("\non:\n", 1)[1].split("\n\n", 1)[0]
            if not re.search(r"^  schedule:", trigger, re.M):
                continue
            for step in re.split(r"\n\s+- ", text):
                if "actions/checkout@" in step:
                    with self.subTest(workflow=os.path.basename(path)):
                        self.assertNotRegex(step, r"\n\s+ref:")


class TestFlightWiringTests(unittest.TestCase):
    """The upload waits for the UI gate (ui_evidence.py), which reads the group jobs' names."""

    def test_no_upload_starts_by_itself(self):
        # Fable P5-15: the old testflight.yml on main uploaded the old app state, untested, on
        # every push to main (16.11.: the website merge started one). Uploads start by hand only,
        # and no workflow that can read the App Store Connect key (named, or all secrets passed on
        # with "secrets: inherit") starts on a push or a pull request. A schedule may read it
        # (asc-feedback.yml fetches feedback and crash logs; it uploads nothing).
        for path in WORKFLOWS:
            text = read(path)
            if "secrets.ASC_" not in text and not re.search(r"secrets:\s*inherit", text):
                continue
            trigger = text.split("\non:\n", 1)[1].split("\n\n", 1)[0]
            events = re.findall(r"^  ([a-z_]+):", trigger, re.M)
            with self.subTest(workflow=os.path.basename(path)):
                if os.path.basename(path) == "testflight.yml":
                    self.assertEqual(events, ["workflow_dispatch"])
                else:
                    self.assertNotIn("push", events)
                    self.assertNotIn("pull_request", events)
                    self.assertNotIn("pull_request_target", events)

    def test_upload_needs_the_ui_gate(self):
        text = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        self.assertIn("python3 .github/scripts/ui_evidence.py gate", text)
        release = text.split("\n  release:\n", 1)[1].split("\n  tag:\n", 1)[0]
        self.assertIn("needs: [check, tests, ui, stress, ui-gate]", release)
        self.assertIn("needs.ui-gate.result == 'success'", release)

    def test_ui_flow_plans_its_groups(self):
        text = read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))
        self.assertIn("python3 .github/scripts/ui_evidence.py plan", text)
        self.assertIn("matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}", text)
        self.assertIn("- name: Plan the UI groups", text)

    def test_ui_flow_ends_in_a_verdict_and_quick_never_uploads(self):
        text = read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))
        verdict = text.split("\n  verdict:\n", 1)[1].split("\n  summary:\n", 1)[0]
        quick = "(!inputs.release && (github.event_name == 'pull_request' || inputs.quick))"
        # ci_gate.py looks for this name; the gate runs also when no group ran.
        self.assertIn(f"name: UI verdict (${{{{ {quick} && 'quick' || 'full' }}}})", verdict)
        self.assertIn("if: ${{ !cancelled() && needs.plan.result == 'success' && !inputs.release }}", verdict)
        self.assertIn("python3 .github/scripts/ui_evidence.py gate ${UI_QUICK:+--quick}", verdict)
        self.assertIn(f"UI_QUICK: ${{{{ {quick} && 'true' || '' }}}}", text)
        self.assertIn("plan --groups \"$UI_GROUPS\" ${UI_QUICK:+--quick}", text)
        self.assertIn("TEST_RUNNER_SORTLY_UI_QUICK: ${{ matrix.quick && '1' || '' }}", text)
        testflight = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        self.assertIn("python3 .github/scripts/ui_evidence.py gate\n", testflight)  # full, never --quick
        self.assertIn("      release: true\n      quick: false\n", testflight)

    def test_pull_request_runs_name_their_merge_commit(self):
        import sys
        sys.path.insert(0, os.path.join(ROOT, ".github", "scripts"))
        import ui_evidence
        text = read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))
        self.assertIn("format('[merge {0}] {1}', github.sha, github.event.pull_request.title)", text)
        run = {"event": "pull_request", "display_title": "[merge " + "a" * 40 + "] Some PR", "head_sha": "b" * 40}
        self.assertEqual(ui_evidence.tested_sha(run), "a" * 40)

    def test_the_pass_deadline_and_the_evidence_follow_the_job_limit(self):
        import sys
        sys.path.insert(0, os.path.join(ROOT, ".github", "scripts"))
        import ui_evidence
        text = read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))
        group = text.split("\n  ui:\n", 1)[1].split("\n  verdict:\n", 1)[0]
        limit = int(re.search(r"\n    timeout-minutes: (\d+)\n", group).group(1))
        self.assertEqual(limit, ui_evidence.GROUP_TIMEOUT_MINUTES)
        self.assertIn(f'--deadline "$((UI_JOB_START + ({limit} - 12) * 60))"', group)
        self.assertLess(group.index("UI_JOB_START=$(date +%s)"), group.index("- name: Run UI tests"))

    def test_ui_flow_checkouts_keep_no_token(self):
        for step in re.split(r"\n\s+- ", read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))):
            if "actions/checkout@" in step:
                with self.subTest(step=step[:80]):
                    self.assertIn("persist-credentials: false", step)

    def test_machinery_steps_exist(self):
        import sys
        sys.path.insert(0, os.path.join(ROOT, ".github", "scripts"))
        import earlier_attempts
        names = set()
        for path in WORKFLOWS:
            names |= set(re.findall(r"\n\s+(?:- )?name: (.+)", read(path)))
        for step in earlier_attempts.MACHINERY_STEPS - {"Set up job", "Initialize containers", "Stop containers",
                                                         "Complete job"}:
            with self.subTest(step=step):
                self.assertIn(step, names)


if __name__ == "__main__":
    unittest.main()
