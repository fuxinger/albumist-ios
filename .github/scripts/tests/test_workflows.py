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
    stale code; none is used) and the reason the nightly checkout of another ref is safe
    (nightly.yml, "Cache poisoning")."""

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


class TestFlightWiringTests(unittest.TestCase):
    """The upload waits for the UI gate (ui_evidence.py), which reads the group jobs' names."""

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


if __name__ == "__main__":
    unittest.main()
