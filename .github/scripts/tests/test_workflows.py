"""Checks over all workflow files (plain text; PyYAML where it is installed, as on the runners).

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


try:
    import yaml
except ImportError:  # PyYAML is on the hosted runners; without it the plain reading below is used
    yaml = None

# An input name that skips something, and a line of workflow code that skips or forces: an
# input read ("inputs.force", "inputs.skip_ui"), the word force or forced on its own (not the
# "--force" flag of git, codesign or simctl), or "untested".
SKIP_INPUT = re.compile(r"(?i)force|skip|bypass|untested|emergency|no[-_]?tests?")
SKIP_MARK = re.compile(r"(?i)inputs\.\w*(?:force|skip)|inputs\[['\"]\w*(?:force|skip)|(?:vars|env|secrets)\.\w*(?:force|skip)"
                       r"|\b(?:force|skip)_\w+|(?<![-\w])forced?\b|untested")


def strip_comment(line):
    """The line without its YAML comment: "#" at the start or after a space, outside quotes."""
    quote = None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i]
    return line


def workflow_inputs(text, plain=False):
    """Names of the workflow_dispatch and workflow_call inputs, in order. With PyYAML (and not
    plain) from the parsed file; otherwise by indentation: the keys right under "inputs:" of the
    top-level "on:"."""
    if yaml is not None and not plain:
        data = yaml.safe_load(text) or {}
        on = data.get("on", data.get(True))  # YAML 1.1 reads the key on as true
        names = []
        if isinstance(on, dict):
            for event in ("workflow_dispatch", "workflow_call"):
                spec = on.get(event)
                if isinstance(spec, dict) and isinstance(spec.get("inputs"), dict):
                    names += list(spec["inputs"])
        return names
    names, inside_on, inputs_at, child_at = [], False, None, None
    for raw in text.splitlines():
        line = strip_comment(raw).rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0:
            inside_on, inputs_at = line.startswith("on:"), None
            continue
        if not inside_on:
            continue
        if inputs_at is not None and indent <= inputs_at:
            inputs_at = None
        if line.strip() == "inputs:":
            inputs_at, child_at = indent, None
        elif inputs_at is not None:
            child_at = indent if child_at is None else child_at
            if indent == child_at:
                names.append(line.strip().split(":", 1)[0])
    return names


def job_field(text, job, field):
    """A job's "if:" or "needs:" as one line (a list joined by ", ")."""
    if yaml is not None:
        value = (yaml.safe_load(text)["jobs"][job] or {}).get(field, "")
        value = ", ".join(value) if isinstance(value, list) else str(value)
    else:
        block = re.split(r"\n  [A-Za-z0-9_-]+:\n", text.split(f"\n  {job}:\n", 1)[1], maxsplit=1)[0]
        found = re.search(rf"\n    {field}: (?:>-\n)?(.*?)\n    [a-z-]+:", "\n" + block, re.S)
        value = found.group(1) if found else ""
    return " ".join(value.split())


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

    def test_no_checkout_of_another_ref(self):
        # CodeQL actions/cache-poisoning (PR #1, PR #7): nightly.yml checked out another ref
        # (needs.pick.outputs.sha) in the default branch's context. Every workflow tests the
        # commit it runs on; a checkout with "ref:" needs a reason (and persist-credentials:
        # false) before this test is changed.
        for path in WORKFLOWS:
            for step in re.split(r"\n\s+- ", read(path)):
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

    def test_nothing_skips_the_tests_before_an_upload(self):
        # G5-02/G6-02: the owner decided on 17.11. to remove the emergency input "force", which
        # uploaded a TestFlight build without running any test. No workflow has an input or a
        # flag to skip tests or the gate, and every job before the upload runs on the results of
        # the one before it alone.
        for path in WORKFLOWS:
            text = read(path)
            code = "\n".join(strip_comment(line) for line in text.splitlines())
            with self.subTest(workflow=os.path.basename(path)):
                self.assertEqual([name for name in workflow_inputs(text) if SKIP_INPUT.search(name)], [])
                self.assertEqual([line.strip() for line in code.splitlines() if SKIP_MARK.search(line)], [])
        # Scripts: no flag that lets a run through without tests ("--forced" in earlier_attempts.py
        # and testflight_notes.py). ui_tests.py --skip names single tests that another group runs
        # (ui-groups.json); the UI gate needs every group green.
        for path in glob.glob(os.path.join(ROOT, ".github", "scripts", "*.py")):
            with self.subTest(script=os.path.basename(path)):
                flags = re.findall(r"add_argument\(\s*[\"']--([\w-]+)[\"']", read(path))
                self.assertEqual([f for f in flags if re.search(r"(?i)force|untested|skip[-_]?(?:tests?|gate)|no[-_]?tests?", f)], [])
        text = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        self.assertEqual(job_field(text, "tests", "if"), "needs.check.outputs.ready == 'true'")
        for job in ("ui", "stress"):
            self.assertIn("tests", [need.strip() for need in job_field(text, job, "needs").split(",")])
        for job, needed in (("ui-gate", ("tests", "ui", "stress")), ("release", ("tests", "ui", "stress", "ui-gate"))):
            with self.subTest(job=job):
                rule = job_field(text, job, "if")
                self.assertNotIn("||", rule)
                self.assertNotIn("inputs.", rule)
                self.assertIn("needs.check.outputs.ready == 'true'", rule)
                for need in needed:
                    self.assertIn(f"needs.{need}.result == 'success'", rule)

    def test_the_skip_check_finds_force_and_nothing_else(self):
        # Second review of 51e72f3: harmless "--force" flags of other tools are no skip, a
        # re-added input is found by both ways of reading the inputs, "#" in quotes is no comment.
        for harmless in ("git push --force-with-lease origin HEAD", "codesign --force --sign - App.app",
                         "xcrun simctl io booted recordVideo --force out.mp4"):
            self.assertIsNone(SKIP_MARK.search(harmless), harmless)
        for skip in ("if: inputs.force", "if: ${{ !inputs.skip_ui }}", "FORCED: yes", "echo untested", "      force:",
                     "if: vars.FORCE_UPLOAD == 'true'", "if: env.SKIP_TESTS != '1'", "${{ inputs['skip_ui'] }}",
                     "run: SKIP_TESTS=1 make"):
            self.assertIsNotNone(SKIP_MARK.search(skip), skip)
        sample = ("name: X\n\non:\n  workflow_dispatch:\n\n    inputs:\n      # an emergency switch\n\n      force:\n"
                  "        type: boolean\n      ui_groups:\n        type: string\n  workflow_call:\n    inputs:\n"
                  "      skip_gate: {type: boolean}\n\njobs:\n  a:\n    runs-on: x\n")
        self.assertEqual(workflow_inputs(sample), ["force", "ui_groups", "skip_gate"])
        self.assertEqual(workflow_inputs(sample, plain=True), ["force", "ui_groups", "skip_gate"])
        for path in WORKFLOWS:
            with self.subTest(workflow=os.path.basename(path)):
                self.assertEqual(workflow_inputs(read(path), plain=True), workflow_inputs(read(path)))
        self.assertEqual(strip_comment('run: echo "a # b" \'c # d\' # note'), 'run: echo "a # b" \'c # d\' ')
        self.assertEqual(strip_comment("url: https://x.example/#anchor"), "url: https://x.example/#anchor")

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
