"""Unit tests for .github/scripts/ui_groups.py (UI groups, the file map and the fingerprints).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import io
import json
import os
import re
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import ui_groups  # noqa: E402

FLOW = """import XCTest

// A comment with a brace { and a fake class Foo: XCTestCase
@MainActor
final class FlowUITests: XCTestCase {
    private let text = "a { brace in a string"
    func test1_Full() {
        UITestOnboarding.onboard(app)
    }

    func test2_Other() throws {}
    func test3_Search() {
        let q = \"\"\"
        func testNotATest() {
        \"\"\"
    }
    private func testHelperNotATest() {}
    func testWithArgument(_ x: Int) {}
}
"""
DEVICE = """import XCTest

final class DeviceUITests: XCTestCase {
    func test01_Hot() { UITestStalls.check() }
    func test02_Cold() { UITestOnboarding.onboard(app) }
}
"""
SEARCH = """import XCTest

final class SearchUITests: XCTestCase {
    func testSearch() { app.tapIfThere() }
}
"""
ONBOARDING = """import XCTest

@MainActor
enum UITestOnboarding {
    static func onboard(_ app: XCUIApplication) {}
    struct Markers {}
}
"""
STALLS = """import Foundation

enum UITestStalls {
    static func check() {}
}
"""
STALLS_SLOWER = STALLS.replace("static func check() {}", "static func check() { sleep(1) }")
TAP = """import XCTest

extension XCUIElement {
    func tapIfThere() {}
}

private extension XCUIElement {
    func onlyHere() {}
}
"""
GROUPS = {"groups": [
    {"group": "device", "title": "device conditions", "_why": "comment", "device": "pro", "only": "DeviceUITests", "skip": ""},
    {"group": "full", "title": "full flow", "device": "pro", "only": "FlowUITests/test1_Full", "skip": "", "video": True},
    {"group": "other", "title": "other flows", "device": "pro", "only": "", "skip": "FlowUITests/test1_Full DeviceUITests"},
    {"group": "small", "title": "small iPhone", "device": "se", "only": "FlowUITests/test2_Other", "skip": "",
     "reduce_motion": True},
]}


def repo(**changes):
    files = {
        "App/Albumist/App/AlbumistApp.swift": "@main struct AlbumistApp {}",
        "App/Albumist/Resources/Info.plist": "<plist/>",
        "App/StoreKit/Albumist.storekit": "{}",
        "App/project.yml": "name: Albumist",
        "Sources/AlbumistCore/Core.swift": "public struct Core {}",
        "Package.swift": "// swift-tools-version: 6.0",
        ".github/toolchain.json": '{"xcode": "27.2"}',
        ".github/workflows/ui.yml": "name: UI flow\n  run: python3 .github/scripts/toolchain.py xcode\n"
                                    "  run: python3 .github/scripts/ui_tests.py run",
        ".github/workflows/ui-stress.yml": "name: UI stress\n  run: python3 .github/scripts/ui_tests.py run",
        ".github/workflows/testflight.yml": "name: TestFlight\n  run: python3 .github/scripts/ci_gate.py",
        ".github/scripts/ui_tests.py": "# runner (ci_gate.py is no harness)\nfrom pick_simulator import pins\n\n\n"
                                       "def run():\n    \"\"\"Not other.py either.\"\"\"\n",
        ".github/scripts/pick_simulator.py": "# pick",
        ".github/scripts/toolchain.py": "# toolchain",
        ".github/scripts/ci_gate.py": "# release gate, no UI job runs it",
        ".github/scripts/other.py": "# not the harness",
        ".github/ui-groups.json": json.dumps(GROUPS),
        "App/AlbumistUITests/FlowUITests.swift": FLOW,
        "App/AlbumistUITests/DeviceUITests.swift": DEVICE,
        "App/AlbumistUITests/SearchUITests.swift": SEARCH,
        "App/AlbumistUITests/UITestOnboarding.swift": ONBOARDING,
        "App/AlbumistUITests/UITestStalls.swift": STALLS,
        "App/AlbumistUITests/XCUIElement+Tap.swift": TAP,
        "App/AlbumistTests/UnitTests.swift": "final class UnitTests {}",
        "Tests/AlbumistCoreTests/CoreTests.swift": "@Test func x() {}",
        "docs/TESTFLIGHT.md": "# TestFlight",
        "README.md": "# Albumist",
    }
    for path, text in changes.items():
        if text is None:
            files.pop(path.replace("__", "/"), None)
        else:
            files[path.replace("__", "/")] = text
    return ui_groups.DictTree(files)


class SwiftTests(unittest.TestCase):
    def test_tests_classes_and_exports(self):
        f = ui_groups.SwiftFile("x.swift", FLOW)
        self.assertEqual(f.classes, {"FlowUITests": ["XCTestCase"]})
        # Not: a private helper, a test with an argument, text in a string or a comment.
        self.assertEqual(f.methods, {"FlowUITests": ["test1_Full", "test2_Other", "test3_Search"]})
        self.assertEqual(f.exported, {"FlowUITests"})
        self.assertIn("UITestOnboarding", f.words)
        self.assertNotIn("Foo", f.words)
        self.assertNotIn("testNotATest", f.words)

    def test_extension_members_are_used_without_a_type_name(self):
        f = ui_groups.SwiftFile("t.swift", TAP)
        self.assertEqual(f.exported, {"tapIfThere"})

    def test_strings_and_comments_are_blanked(self):
        text = ui_groups.strip_swift('let a = "x { y" // z {\n/* { /* } */ */ let b = #"q"{"#\nlet c = "\\"{"')
        self.assertEqual(text.count("{"), 0)
        self.assertEqual(text.count("\n"), 2)
        self.assertIn("let b", text)

    def test_a_helper_used_only_in_an_interpolation_is_a_use(self):
        f = ui_groups.SwiftFile("x.swift", 'let a = "count \\(Helper.count(of: "x")) {"\nlet b = 1\n')
        self.assertIn("Helper", f.words)
        self.assertNotIn("count of", " ".join(sorted(f.words)))

    def test_inheritance_over_several_lines(self):
        f = ui_groups.SwiftFile("x.swift", "final class LongUITests:\n    XCTestCase\n{\n    func testA() {}\n}\n")
        self.assertEqual(f.classes, {"LongUITests": ["XCTestCase"]})
        self.assertEqual(ui_groups.all_tests({"x.swift": f}), {"LongUITests/testA": {"x.swift"}})

    def test_tests_in_an_extension_and_inherited_tests(self):
        files = {
            "A.swift": ui_groups.SwiftFile("A.swift", "class BaseUITests: XCTestCase {\n    func testBase() {}\n}\n"),
            "B.swift": ui_groups.SwiftFile("B.swift", "final class SubUITests: BaseUITests {\n    func testSub() {}\n}\n"),
            "C.swift": ui_groups.SwiftFile("C.swift", "extension SubUITests {\n    func testMore() {}\n}\n"),
        }
        tests = ui_groups.all_tests(files)
        self.assertEqual(tests["SubUITests/testBase"], {"A.swift"})
        self.assertEqual(tests["SubUITests/testMore"], {"C.swift"})
        self.assertEqual(tests["BaseUITests/testBase"], {"A.swift"})
        self.assertNotIn("BaseUITests/testMore", tests)


class SwiftCodeTests(unittest.TestCase):
    """swift_code: what a test fingerprint reads of a Swift file (Prüfer B G5-04: a comment edit is
    no change of the test, so it must not let a red result go)."""

    def same(self, a, b):
        self.assertIsNotNone(ui_groups.swift_code(a))
        self.assertEqual(ui_groups.swift_code(a), ui_groups.swift_code(b))

    def different(self, a, b):
        self.assertIsNotNone(ui_groups.swift_code(a))
        self.assertIsNotNone(ui_groups.swift_code(b))
        self.assertNotEqual(ui_groups.swift_code(a), ui_groups.swift_code(b))

    def test_comments_indentation_and_blank_lines_count_for_nothing(self):
        code = "func f() {\n    let a = 1 + 2\n    g(a)\n}\n"
        self.same(code, "// head\nfunc f() { // why\n\n\n        let a = 1 /* sum */ + 2\n\tg(a)   \n}")
        self.same(code, "/* a /* nested */ comment */func f() {\n/** doc\n */ let a = 1 + 2\ng(a)\n}\n")
        self.same(code, "func f() {\r\n    let a = 1 + 2\r\n    g(a)\r\n}\r\n")

    def test_carriage_returns_are_line_breaks_as_in_swift(self):
        # Swift ends a // comment and a line at "\r" as at "\n" (second review of G5-04): code
        # after "\r" is code.
        self.different("a // x\rb", "a // x\rc")
        self.different("let a = 1 // x\rlet b = 2\r", "let a = 1 // x\rlet b = 3\r")
        self.same("a // x\r\nb", "a\nb")
        self.same("a\r\n  b\r", "a\nb")
        self.same("a\r(b)", "a\n(b)")
        self.same("a /* x\r y */ (b)", "a\n(b)")
        self.assertIsNone(ui_groups.swift_code('let s = "open\rlet b = 1'))
        self.assertIsNone(ui_groups.swift_code("let `a\rb` = 1"))
        # The reader of uses sees the code after "\r" too.
        f = ui_groups.SwiftFile("x.swift", "let a = 1 // note\rlet b = Helper.make()\r")
        self.assertIn("Helper", f.words)
        f = ui_groups.SwiftFile("x.swift", "final class CRUITests: XCTestCase {\r    func testA() {}\r}\r")
        self.assertEqual(f.methods, {"CRUITests": ["testA"]})

    def test_line_breaks_and_space_around_operators_count(self):
        # A line break ends a statement and makes "(" no call; space decides prefix/postfix/binary.
        self.different("let a = b\n(c)\n", "let a = b(c)\n")
        self.different("let a = b - c\n", "let a = b -c\n")
        self.different("let a = b\n", "let a = c\n")
        # A comment over two lines is a line break, one on a line is a space.
        self.same("a /* x\n y */ (b)", "a\n(b)")
        self.same("a /* x */ - b", "a - b")

    def test_literals_stay_byte_for_byte(self):
        self.different('let s = "a  b"', 'let s = "a b"')
        self.different('let s = "a // b"', 'let s = "a  b"')
        self.different('let s = "x /* y */"', 'let s = "x "')
        self.same('let s = "a // b" // c', 'let s = "a // b"')
        self.different('let s = #"a "b" // c"#', 'let s = #"a "b" "#')
        self.different('let s = "q\\" // still text"', 'let s = "q\\""')
        multi = 'let s = """\n    a  // b\n      c\n    """\n'
        self.different(multi, multi.replace("      c", "    c"))
        self.different(multi, multi.replace("  // b", ""))
        self.different(multi, multi.replace('    """', '  """'))  # the closing delimiter's indentation
        self.different("let r = #/(\\d+) von /#", "let r = #/(\\d+) von/#")
        self.different("let r = #/a//b/#", "let r = #/a/#")
        self.different("let r = ##/a/#b/##", "let r = ##/a/##")
        self.different("let `a b` = 1", "let `a  b` = 1")

    def test_code_in_an_interpolation_is_code(self):
        self.same('print("n \\(count(of: "x" /* why */))!")', 'print("n \\(count(of:  "x"  ))!")')
        self.different('print("n \\(a - b)")', 'print("n \\(a -b)")')
        self.different('print("n \\(f("a  b"))")', 'print("n \\(f("a b"))")')

    def test_what_it_cannot_read_for_sure_falls_back_to_the_bytes(self):
        for source in ("let a = b/c", "let r = /a b/", "let r = /a//", "x /=y", 'let s = "open\nlet b = 1',
                       "/* open comment", 'let s = """\nopen', "let r = #/open", "let `a = 1", "let s = \"\ufffd\""):
            with self.subTest(source=source):
                self.assertIsNone(ui_groups.swift_code(source))
                self.assertEqual(ui_groups.swift_code_id(source, "0" * 40), "blob " + "0" * 40)
        for source in ("let a = b / c", "a /= 2\n"):
            with self.subTest(source=source):
                self.assertIsNotNone(ui_groups.swift_code(source))
        self.assertEqual(ui_groups.swift_code_id(None, "1" * 40), "blob " + "1" * 40)
        self.assertTrue(ui_groups.swift_code_id("let a = 1", "1" * 40).startswith("code "))


class GroupTests(unittest.TestCase):
    def test_file_map(self):
        groups = ui_groups.Groups(repo())
        self.assertEqual(groups.selected_tests("other"), ["FlowUITests/test2_Other", "FlowUITests/test3_Search",
                                                          "SearchUITests/testSearch"])
        self.assertEqual(groups.file_map(), {
            ".github/scripts/pick_simulator.py": ["device", "full", "other", "small"],
            ".github/scripts/toolchain.py": ["device", "full", "other", "small"],
            ".github/scripts/ui_tests.py": ["device", "full", "other", "small"],
            ".github/workflows/ui-stress.yml": ["device", "full", "other", "small"],
            ".github/workflows/ui.yml": ["device", "full", "other", "small"],
            "App/AlbumistUITests/DeviceUITests.swift": ["device"],
            "App/AlbumistUITests/FlowUITests.swift": ["full", "other", "small"],
            "App/AlbumistUITests/SearchUITests.swift": ["other"],
            "App/AlbumistUITests/UITestOnboarding.swift": ["device", "full", "other", "small"],
            "App/AlbumistUITests/UITestStalls.swift": ["device"],
            "App/AlbumistUITests/XCUIElement+Tap.swift": ["other"],
        })

    def test_group_names_must_fit_a_job_name(self):
        for bad in ("Device", "a b", "x]"):
            groups = {"groups": [dict(GROUPS["groups"][0], group=bad)]}
            with self.subTest(name=bad), self.assertRaisesRegex(ValueError, "lower-case"):
                ui_groups.Groups(repo(**{".github__ui-groups.json": json.dumps(groups)}))

    def test_quick_mode_changes_every_group(self):
        device = DEVICE.replace("func test02_Cold() {", 'func test02_Cold() {\n        if env["ALBUMIST_UI_QUICK"] == "1" { return }')
        groups = ui_groups.Groups(repo(**{"App__AlbumistUITests__DeviceUITests.swift": device}))
        self.assertTrue(groups.reads_quick("device"))
        self.assertFalse(groups.reads_quick("full"))
        # Fails safe: in a quick run every group has another fingerprint, also one whose files
        # do not visibly read the switch.
        for name in ("device", "full"):
            self.assertNotEqual(groups.fingerprint(name, quick=True), groups.fingerprint(name))
            entry = groups.matrix_entry(name, "a" * 64, quick=True)
            self.assertTrue(entry["quick"])
            self.assertTrue(entry["title"].endswith(" (quick)"))
        self.assertFalse(groups.matrix_entry("full", "a" * 64)["quick"])

    def test_matrix_entry(self):
        tree = repo()
        groups = ui_groups.Groups(tree)
        entry = groups.matrix_entry("small", "a" * 64)
        self.assertEqual(entry, {"group": "small", "title": "small iPhone", "device": "se", "only": "FlowUITests/test2_Other",
                                 "skip": "", "video": False, "reduce_motion": True, "increase_contrast": False, "quick": False,
                                 "budget_min": 0, "app": "a" * 12, "tests": groups.fingerprint("small")[:12]})

    def test_a_time_budget_reports_and_runs_nothing_again(self):
        # budget_min only reports (ui_tests.py budget_check): a new budget is in the matrix but
        # changes no test fingerprint, so no group runs again for it.
        budgeted = {"groups": [dict(g, budget_min=25) for g in GROUPS["groups"]]}
        before = ui_groups.Groups(repo())
        after = ui_groups.Groups(repo(**{".github__ui-groups.json": json.dumps(budgeted)}))
        for name in before.names():
            with self.subTest(name):
                self.assertEqual(after.fingerprint(name), before.fingerprint(name))
                self.assertEqual(after.matrix_entry(name, "a" * 64)["budget_min"], 25)
        self.assertEqual(ui_groups.REPORT_ONLY, ("budget_min",))

    def test_every_real_group_has_a_time_budget(self):
        with open(os.path.join(ui_groups.ROOT, ".github", "ui-groups.json"), encoding="utf-8") as f:
            groups = json.load(f)["groups"]
        for g in groups:
            with self.subTest(g["group"]):
                self.assertIsInstance(g.get("budget_min"), int)
                self.assertGreater(g["budget_min"], 0)
        with open(os.path.join(ui_groups.ROOT, ".github", "workflows", "ui.yml"), encoding="utf-8") as f:
            ui = f.read()
        self.assertIn("BUDGET_MIN: ${{ matrix.budget_min }}", ui)
        self.assertIn('--budget-min "${BUDGET_MIN:-0}"', ui)


class FingerprintTests(unittest.TestCase):
    BASE = repo()

    def changed(self, **changes):
        """(app changed, {group: test fingerprint changed})."""
        before, after = ui_groups.fingerprints(self.BASE), ui_groups.fingerprints(repo(**changes))
        return (before["app"] != after["app"],
                sorted(g for g in before["groups"] if before["groups"][g] != after["groups"].get(g)))

    def test_app_changes_are_app_changes(self):
        for path in ("App/Albumist/App/AlbumistApp.swift", "App/Albumist/Resources/Info.plist", "App/project.yml",
                     "App/StoreKit/Albumist.storekit", "Sources/AlbumistCore/Core.swift", "Package.swift",
                     "Package.resolved", ".github/toolchain.json", "Sources/AlbumistWorldMap/Resources/world.albumistmap",
                     "NewFolder/unknown.txt", ".gitattributes", "App/Albumist/Resources/Licenses.md"):
            with self.subTest(path=path):
                self.assertTrue(self.changed(**{path.replace("/", "__"): "changed"})[0])
        self.assertTrue(self.changed(**{"Sources__AlbumistCore__Core.swift": None})[0], "a deleted app file")

    def test_test_docs_and_workflow_changes_leave_the_app_alone(self):
        for path in ("App/AlbumistUITests/FlowUITests.swift", "App/AlbumistTests/UnitTests.swift",
                     "Tests/AlbumistCoreTests/CoreTests.swift", "docs/TESTFLIGHT.md", "README.md", "docs/launch/x.md",
                     ".github/workflows/ui.yml", ".github/scripts/other.py", ".github/ui-groups.json",
                     "scripts/gen_codemap.py", "tools/x.sh", "design/icon/icon.svg"):
            with self.subTest(path=path):
                after = repo(**{path.replace("/", "__"): "changed"})
                self.assertEqual(ui_groups.app_fingerprint(after), ui_groups.app_fingerprint(self.BASE))

    def test_a_test_file_changes_only_its_groups(self):
        # A group left without tests is an error, not an empty fingerprint.
        with self.assertRaisesRegex(ValueError, "device .* select no UI test"):
            ui_groups.Groups(repo(**{"App__AlbumistUITests__DeviceUITests.swift": None}))
        changed = DEVICE.replace("test02_Cold", "test02_Colder")
        self.assertEqual(self.changed(**{"App__AlbumistUITests__DeviceUITests.swift": changed}), (False, ["device"]))
        longer = FLOW.replace("func test2_Other() throws {}", "func test2_Other() throws { sleep(20) }")
        self.assertEqual(self.changed(**{"App__AlbumistUITests__FlowUITests.swift": longer}), (False, ["full", "other", "small"]))
        tapped = SEARCH.replace("app.tapIfThere()", "app.tapIfThere(); app.swipeUp()")
        self.assertEqual(self.changed(**{"App__AlbumistUITests__SearchUITests.swift": tapped}), (False, ["other"]))

    def test_comments_and_indentation_leave_every_fingerprint(self):
        # Prüfer B G5-04: the rule is "red until the test or the app changes"; a comment is no change.
        flow = FLOW.replace("    func test2_Other", "    // waits 20 s\n  func test2_Other").replace("XCTestCase {\n", "XCTestCase { // open\n")
        self.assertEqual(self.changed(**{"App__AlbumistUITests__FlowUITests.swift": flow}), (False, []))
        self.assertEqual(self.changed(**{"App__AlbumistUITests__UITestOnboarding.swift": "/* the onboarding */\n" + ONBOARDING}),
                         (False, []))
        # Text in a string literal is test code (what the test types or looks for).
        in_string = FLOW.replace("func testNotATest() {\n", "func testNotATest() { // open\n")
        self.assertEqual(self.changed(**{"App__AlbumistUITests__FlowUITests.swift": in_string}),
                         (False, ["full", "other", "small"]))
        self.assertEqual(self.changed(**{"App__AlbumistUITests__FlowUITests.swift": FLOW.replace("a { brace", "a {  brace")}),
                         (False, ["full", "other", "small"]))
        # A file the reader cannot read for sure counts by its bytes, comments too.
        unsure = DEVICE.replace("func test01_Hot() {", "func test01_Hot() { let half = 1/2")
        base = ui_groups.fingerprints(repo(**{"App__AlbumistUITests__DeviceUITests.swift": unsure}))
        after = ui_groups.fingerprints(repo(**{"App__AlbumistUITests__DeviceUITests.swift": unsure + "// note\n"}))
        self.assertNotEqual(base["groups"]["device"], after["groups"]["device"])

    def test_a_shared_helper_changes_every_group_that_uses_it(self):
        self.assertEqual(self.changed(**{"App__AlbumistUITests__UITestOnboarding.swift": ONBOARDING.replace(
            "XCUIApplication) {}", "XCUIApplication) { app.launch() }")}), (False, ["device", "full", "other", "small"]))
        self.assertEqual(self.changed(**{"App__AlbumistUITests__UITestStalls.swift": STALLS_SLOWER}), (False, ["device"]))
        self.assertEqual(self.changed(**{"App__AlbumistUITests__XCUIElement+Tap.swift": TAP.replace(
            "func tapIfThere() {}", "func tapIfThere() { tap() }")}), (False, ["other"]))

    def test_harness_resources_and_observers_count_for_every_group(self):
        everyone = (False, ["device", "full", "other", "small"])
        self.assertEqual(self.changed(**{".github__scripts__ui_tests.py": "# changed"}), everyone)
        self.assertEqual(self.changed(**{"App__AlbumistUITests__Info.plist": "<plist/>"}), everyone)
        observer = "final class Observer: NSObject, XCTestObservation {}\n"
        self.assertEqual(self.changed(**{"App__AlbumistUITests__Observer.swift": observer}), everyone)
        self.assertEqual(self.changed(**{".github__workflows__ui.yml": "name: UI flow changed\n"
                                         "  run: python3 .github/scripts/ui_tests.py run"}), everyone)
        self.assertEqual(self.changed(**{".github__workflows__ui-stress.yml": "name: UI stress\n"
                                         "  run: python3 .github/scripts/ui_tests.py run --only x"}), everyone)
        # The harness reaches what the UI workflows name, and what those scripts import.
        self.assertEqual(self.changed(**{".github__scripts__pick_simulator.py": "# changed"}), everyone)
        self.assertEqual(self.changed(**{".github__scripts__toolchain.py": "# changed"}), everyone)
        self.assertEqual(self.changed(**{".github__scripts__tests__test_x.py": "# new"}), (False, []))
        # Fails closed: a file no group's tests reach (here a helper nobody uses yet) counts for all.
        self.assertEqual(self.changed(**{"App__AlbumistUITests__Unused.swift": "enum Unused {}\n"}), everyone)

    def test_a_script_or_workflow_no_ui_job_runs_leaves_every_green(self):
        # Review P5-08 (c): every script and workflow counted for every group, so a fix to the
        # release gate or the TestFlight workflow made every green UI result worthless and cost a
        # full UI run (the rule before this test said: testflight.yml and ci.yml change everyone).
        nothing = (False, [])
        for path in (".github/workflows/testflight.yml", ".github/workflows/ci.yml", ".github/scripts/ci_gate.py",
                     ".github/scripts/other.py", ".github/scripts/new_tool.py"):
            with self.subTest(path=path):
                self.assertEqual(self.changed(**{path.replace("/", "__"): "# new"}), nothing)
        # Once a UI workflow names it, it is harness.
        everyone = (False, ["device", "full", "other", "small"])
        named = repo(**{".github__workflows__ui.yml": "name: UI flow\n  run: python3 .github/scripts/ui_tests.py run\n"
                                                    "  run: python3 .github/scripts/toolchain.py xcode\n"
                                                    "  run: python3 .github/scripts/other.py"})
        before = ui_groups.fingerprints(named)["groups"]
        after = ui_groups.fingerprints(ui_groups.DictTree(dict(named.contents, **{".github/scripts/other.py": "# x"})))["groups"]
        self.assertEqual(sorted(g for g in before if before[g] != after[g]), everyone[1])

    def test_names_in_comments_and_docstrings_are_no_use(self):
        names = ui_groups.script_names('"""Uses x_doc.py."""\nimport a_mod\nfrom b_mod import c\n# d_comment.py\n'
                                       'def f():\n    """e_doc.py"""\n    return os.path.join(HERE, "f_run.py"), ".github/g.json"\n')
        self.assertEqual((names.modules, names.files, names.paths, names.unresolved),
                         ({"a_mod", "b_mod"}, {"f_run.py", "g.json"}, {".github/g.json"}, ""))
        self.assertIsNone(ui_groups.script_names("def broken(:\n"))
        names = ui_groups.workflow_names("# .github/scripts/ci_gate.py\n  run: python3 .github/scripts/x.py # y\n"
                                         "  with:\n    sparse-checkout: .github\n")
        self.assertEqual((names.paths, names.files), ({".github/scripts/x.py"}, {"x.py"}))
        # The runner starts a script it named in a variable: resolved; one from an unknown name: not.
        self.assertEqual(ui_groups.script_names('s = os.path.join(HERE, "pick.py")\nsubprocess.run([sys.executable, s])\n')
                         .unresolved, "")
        self.assertNotEqual(ui_groups.script_names("subprocess.run([sys.executable, NAME, '--x'])\n").unresolved, "")

    def test_every_way_of_naming_a_helper_counts_it_or_everything(self):
        # Second review of C6: a helper named in a way the reader did not know was left out of
        # every fingerprint. Each way below either counts the helper or, when the name cannot be
        # resolved, counts everything (fails safe).
        everyone = ["device", "full", "other", "small"]
        runner = "  run: python3 .github/scripts/ui_tests.py run\n"

        def changed_groups(changes, edit):
            base = repo(**changes)
            after = repo(**dict(changes, **edit))
            before_fp, after_fp = ui_groups.fingerprints(base)["groups"], ui_groups.fingerprints(after)["groups"]
            return sorted(g for g in before_fp if before_fp[g] != after_fp[g])

        other = {".github__scripts__other.py": "# changed"}
        cases = {
            "workspace variable": {".github__workflows__ui.yml": "name: UI\n" + runner
                                   + '  run: python3 "$GITHUB_WORKSPACE/.github/scripts/other.py"\n'},
            "workspace expression": {".github__workflows__ui.yml": "name: UI\n" + runner
                                     + "  run: python3 ${{ github.workspace }}/.github/scripts/other.py\n"},
            "working directory": {".github__workflows__ui.yml": "name: UI\n" + runner
                                  + "  working-directory: .github/scripts\n  run: python3 other.py\n"},
            "python -m": {".github__workflows__ui.yml": "name: UI\n" + runner
                          + "  run: cd .github/scripts && python3 -m other\n"},
            "import_module": {".github__scripts__ui_tests.py": "import importlib\nimportlib.import_module('other')\n"},
        }
        for name, changes in cases.items():
            with self.subTest(name):
                self.assertEqual(changed_groups(changes, other), everyone)
        # A local action: its action.yml and what it runs.
        action = {".github__workflows__ui.yml": "name: UI\n" + runner + "  - uses: ./.github/actions/sim\n",
                  ".github__actions__sim__action.yml": "runs:\n  steps:\n    - run: python3 .github/scripts/other.py\n"}
        self.assertEqual(changed_groups(action, other), everyone)
        self.assertEqual(changed_groups(action, {".github__actions__sim__action.yml": "runs: {}\n"}), everyone)
        # A data file named through os.path.join parts.
        data = {".github__scripts__ui_tests.py": "import os\nPINS = os.path.join(HERE, '..', 'data', 'pins.json')\n",
                ".github__data__pins.json": "{}"}
        self.assertEqual(changed_groups(data, {".github__data__pins.json": '{"x": 1}'}), everyone)
        # Names it cannot resolve: everything counts, here the release gate no UI job runs.
        gate = {".github__scripts__ci_gate.py": "# changed"}
        for name, changes in {
            "variable script": {".github__workflows__ui.yml": "name: UI\n" + runner
                                + "  run: python3 .github/scripts/${TOOL}.py\n"},
            "variable module": {".github__scripts__ui_tests.py": "import importlib\nimportlib.import_module(NAME)\n"},
            "variable -m": {".github__scripts__ui_tests.py": "import subprocess\nsubprocess.run(['python3', '-m', NAME])\n"},
            "missing path": {".github__workflows__ui.yml": "name: UI\n" + runner
                             + "  run: python3 .github/scripts/not_there.py\n"},
        }.items():
            with self.subTest(name):
                self.assertEqual(changed_groups(changes, gate), everyone)

    def test_code_run_or_listed_in_ways_the_reader_cannot_follow_counts_everything(self):
        # Third review of C6: a shell string built at run time, exec/eval/compile, a folder of
        # .github/ listed (glob, listdir, walk) and a data file with another extension were left
        # out of the harness. Each now counts everything, or the file it names.
        everyone = ["device", "full", "other", "small"]
        runner = "  run: python3 .github/scripts/ui_tests.py run\n"
        ui = {".github__workflows__ui.yml": "name: UI\n" + runner}

        def changed_groups(script, edit, extra=None):
            changes = dict(ui, **{".github__scripts__ui_tests.py": script}, **(extra or {}))
            before_fp = ui_groups.fingerprints(repo(**changes))["groups"]
            after_fp = ui_groups.fingerprints(repo(**dict(changes, **edit)))["groups"]
            return sorted(g for g in before_fp if before_fp[g] != after_fp[g])

        gate = {".github__scripts__ci_gate.py": "# changed"}
        here = "import os, glob, pathlib, subprocess, sys\nHERE = os.path.dirname(os.path.abspath(__file__))\n" \
               "ROOT = os.path.join(HERE, '..', '..')\n"
        for name, script in {
            "shell=True, built": "import subprocess\nsubprocess.run(f'python3 {SCRIPT}', shell=True)\n",
            "shell=True, a name": "import subprocess\nsubprocess.check_call(COMMAND, shell=True)\n",
            "os.system": "import os\nos.system(COMMAND)\n",
            "os.popen": "import os\nos.popen('python3 ' + NAME)\n",
            "getoutput": "import subprocess\nsubprocess.getoutput(COMMAND)\n",
            "bash -c": "import subprocess\nsubprocess.run(['bash', '-c', COMMAND])\n",
            "/bin/sh -c": "import subprocess\nsubprocess.run(['/bin/sh', '-c', 'python3 ' + NAME])\n",
            "env bash script": "import subprocess\nsubprocess.run(['/usr/bin/env', 'bash', SCRIPT])\n",
            "python -c": "import subprocess, sys\nsubprocess.run([sys.executable, '-c', CODE])\n",
            "exec": "exec(open(PATH).read())\n",
            "exec, constant": "exec('import other')\n",
            "eval": "eval(SOURCE)\n",
            "compile": "code = compile(SOURCE, 'x', 'exec')\n",
            "builtins.exec": "import builtins\nbuiltins.exec(SOURCE)\n",
            "glob next to the script": here + "for s in glob.glob(os.path.join(HERE, '*.py')): pass\n",
            "glob of .github": "import glob\nglob.glob('.github/scripts/*.py')\n",
            "listdir of .github": "import os\nos.listdir('.github/scripts')\n",
            "scandir of the folder": "import os\nos.scandir(os.path.dirname(__file__))\n",
            "walk of the repository": here + "for top, dirs, files in os.walk(ROOT): pass\n",
            "Path.glob": "import pathlib\npathlib.Path(__file__).parent.glob('*.py')\n",
            "Path.iterdir": "from pathlib import Path\nfor p in (Path(__file__).parent / '..' / 'actions').iterdir(): pass\n",
            "listdir of a folder from __file__ it cannot follow": "import os\nos.listdir(helper(__file__))\n",
        }.items():
            with self.subTest(name):
                self.assertEqual(changed_groups(script, gate), everyone)
        # What it can follow names the script, and nothing more: a shell string that is constant,
        # folders outside .github/ (the tests' Swift files, a folder handed in), re.compile.
        other = {".github__scripts__other.py": "# changed"}
        for name, script in {
            "shell=True, constant": "import subprocess\nsubprocess.run('python3 .github/scripts/other.py', shell=True)\n",
            "os.system, constant": "import os\nos.system('python3 .github/scripts/other.py')\n",
            "bash -c, constant": "import subprocess\nsubprocess.run(['bash', '-c', 'python3 .github/scripts/other.py'])\n",
        }.items():
            with self.subTest(name):
                self.assertEqual(changed_groups(script, other), everyone)
                self.assertEqual(changed_groups(script, gate), [])
        for name, script in {
            "glob of the Swift tests": here + "glob.glob(f'{ROOT}/App/AlbumistUITests/**/*.swift', recursive=True)\n",
            "glob of a folder handed in": "import glob, os\ndef f(folder):\n    return glob.glob(os.path.join(folder, '**', 'x'))\n",
            "glob of /Applications": "import glob\nglob.glob('/Applications/Xcode*.app')\n",
            "re.compile": "import re\nPATTERN = re.compile(r'x')\n",
        }.items():
            with self.subTest(name):
                self.assertEqual(changed_groups(script, gate), [])
        # A data file with any extension, named through os.path.join parts.
        for extension in ("csv", "plist", "xml", "ini", "conf", "jsonl"):
            with self.subTest(extension=extension):
                data = {f".github__data__pins.{extension}": "a"}
                script = f"import os\nPINS = os.path.join(HERE, '..', 'data', 'pins.{extension}')\n"
                self.assertEqual(changed_groups(script, {f".github__data__pins.{extension}": "b"}, data), everyone)
                self.assertEqual(changed_groups(script, gate, data), [])

    def test_the_group_file_is_no_harness(self):
        # Second review of C6: ui-groups.json was harness (the real ui_groups.py names it), so a
        # budget_min or _comment edit ran all groups again. Each group's own definition counts.
        with open(os.path.join(ui_groups.ROOT, ".github", "scripts", "ui_groups.py"), encoding="utf-8") as f:
            real = f.read()
        changes = {".github__workflows__ui.yml": "name: UI\n  run: python3 .github/scripts/ui_groups.py plan\n"
                                                 "  run: python3 .github/scripts/ui_tests.py run\n",
                   ".github__scripts__ui_groups.py": real}
        base = repo(**changes)
        self.assertNotIn(".github/ui-groups.json", ui_groups.harness_files(base))
        groups = json.loads(json.dumps(GROUPS))
        groups["_comment"] = ["a new comment"]
        groups["groups"][0]["budget_min"] = 99
        after = repo(**dict(changes, **{".github__ui-groups.json": json.dumps(groups)}))
        self.assertEqual(ui_groups.fingerprints(base)["groups"], ui_groups.fingerprints(after)["groups"])
        self.assertNotIn(".github/ui-groups.json", ui_groups.harness_files(ui_groups.GitTree("HEAD")))

    def test_unsure_counts_every_script_and_workflow(self):
        # Fails toward "harness changed": without a UI workflow, or one that reaches no runner,
        # every script and workflow is harness again.
        everyone = (False, ["device", "full", "other", "small"])
        for changes in ({".github__workflows__ui-stress.yml": None},
                        {".github__scripts__ui_tests.py": "def broken(:\n"},
                        {".github__workflows__ui.yml": "name: UI flow\n  run: ./run-the-tests.sh",
                         ".github__workflows__ui-stress.yml": "name: UI stress"}):
            with self.subTest(changes=sorted(changes)):
                base = repo(**changes)
                after = repo(**dict(changes, **{".github__scripts__ci_gate.py": "# changed"}))
                before_fp, after_fp = ui_groups.fingerprints(base)["groups"], ui_groups.fingerprints(after)["groups"]
                self.assertEqual(sorted(g for g in before_fp if before_fp[g] != after_fp[g]), everyone[1])

    @staticmethod
    def code_of(path, text):
        """The text without comments, and for a script without its docstrings (they name other
        scripts for the reader only)."""
        if not path.endswith(".py"):
            return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        import ast
        import tokenize
        docs = set()
        for node in ast.walk(ast.parse(text)):
            if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) and node.body:
                first = node.body[0]
                if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant):
                    docs.add(first.lineno)
        kept = [tok.string for tok in tokenize.generate_tokens(io.StringIO(text).readline)
                if tok.type != tokenize.COMMENT and not (tok.type == tokenize.STRING and tok.start[0] in docs)]
        return " ".join(kept)

    def test_the_real_harness_is_what_the_ui_workflows_and_runner_name(self):
        # Read from the files themselves, no list kept by hand: every script ui.yml, ui-stress.yml
        # and ui_tests.py call or import is harness; the release-only scripts are not.
        tree = ui_groups.GitTree("HEAD")
        harness = ui_groups.harness_files(tree)
        root = ui_groups.ROOT
        named = set()
        for path in (".github/workflows/ui.yml", ".github/workflows/ui-stress.yml", ".github/scripts/ui_tests.py"):
            with open(os.path.join(root, path), encoding="utf-8") as f:
                text = f.read()
            named |= {".github/scripts/" + m for m in re.findall(r"\.github/scripts/([A-Za-z0-9_]+\.py)", text)}
            named |= {f".github/scripts/{m}.py" for m in re.findall(r"^\s*(?:from|import)\s+(\w+)", text, re.M)
                      if os.path.exists(os.path.join(root, ".github", "scripts", f"{m}.py"))}
        self.assertIn(".github/scripts/ui_tests.py", named)
        self.assertIn(".github/scripts/pick_simulator.py", named)  # imported by ui_tests.py
        self.assertEqual(sorted(named - harness), [])
        # Every .github/scripts name, path or -m module in the code (comments left out) of the
        # roots and of every harness script resolves to a file in the set.
        scripts = {p for p in tree.files() if p.startswith(".github/scripts/") and p.endswith(".py")
                   and not p.startswith(".github/scripts/tests/")}
        for path in sorted(p for p in harness if p.endswith((".yml", ".py"))):
            code = self.code_of(path, tree.read(path))
            names = set(re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\.py\b", code)) | set(re.findall(r"-m\s+([A-Za-z_]\w*)", code))
            for name in names:
                script = f".github/scripts/{name}.py"
                if script in scripts:
                    with self.subTest(file=path, name=name):
                        self.assertIn(script, harness)
        for path in (".github/workflows/testflight.yml", ".github/workflows/ci.yml", ".github/scripts/ci_gate.py",
                     ".github/scripts/archive_check.py"):
            self.assertNotIn(path, harness)

    def test_group_definitions(self):
        groups = json.loads(json.dumps(GROUPS))
        groups["groups"][0]["_why"] = "a new comment"
        self.assertEqual(self.changed(**{".github__ui-groups.json": json.dumps(groups)}), (False, []))
        groups["groups"][3]["reduce_motion"] = False
        self.assertEqual(self.changed(**{".github__ui-groups.json": json.dumps(groups)}), (False, ["small"]))

    def test_affected_says_why(self):
        run, why = ui_groups.affected(self.BASE, repo(**{"App__AlbumistUITests__UITestStalls.swift": STALLS_SLOWER}),
                                      ["App/AlbumistUITests/UITestStalls.swift"])
        self.assertEqual((run, why), (["device"], {"device": ["App/AlbumistUITests/UITestStalls.swift"]}))
        # Only comments and indentation changed: nothing to run again.
        run, why = ui_groups.affected(self.BASE, repo(**{"App__AlbumistUITests__UITestStalls.swift":
                                                          "// Stalls\n" + STALLS.replace("    static", "  static")}),
                                      ["App/AlbumistUITests/UITestStalls.swift"])
        self.assertEqual((run, why), ([], {}))
        run, why = ui_groups.affected(self.BASE, repo(**{"Sources__AlbumistCore__Core.swift": "changed"}),
                                      ["Sources/AlbumistCore/Core.swift", "docs/TESTFLIGHT.md"])
        self.assertEqual(run, ["device", "full", "other", "small"])
        self.assertEqual(why["full"], ["app changed: Sources/AlbumistCore/Core.swift"])
        self.assertEqual(ui_groups.affected(self.BASE, repo(**{"docs__TESTFLIGHT.md": "x"}), ["docs/TESTFLIGHT.md"]),
                         ([], {}))


class RepositoryTests(unittest.TestCase):
    """The real UI test target at HEAD (needs git; read, never changed)."""

    ROOT = ui_groups.ROOT

    def setUp(self):
        if subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.ROOT, capture_output=True).returncode != 0:
            self.skipTest("no git checkout")
        try:
            self.groups = ui_groups.Groups(ui_groups.GitTree("HEAD"))
        except ValueError as error:
            self.skipTest(str(error))

    def test_every_group_runs_tests_and_every_test_file_has_a_group(self):
        for name in self.groups.names():
            with self.subTest(group=name):
                self.assertTrue(self.groups.selected_tests(name), f"{name} selects no test")
        for path, names in self.groups.file_map().items():
            if path.endswith("UITests.swift"):
                with self.subTest(path=path):
                    self.assertTrue(names, f"{path} is in no group")

    def test_every_swift_file_of_the_target_is_read_as_code(self):
        # Otherwise a comment edit in it would change its groups' fingerprints again and let a red
        # result go (Prüfer B G5-04). Write a division as "a / b" (a bare regex /.../ can not be read).
        for path, f in self.groups.files.items():
            with self.subTest(path=path):
                self.assertTrue(self.groups.code_ids[path].startswith("code "),
                                f"{path}: ui_groups.swift_code cannot read it for sure (a \"/\" without spaces?)")

    def test_the_shared_onboarding_belongs_to_every_group_that_onboards(self):
        users = self.groups.file_map().get("App/AlbumistUITests/UITestOnboarding.swift", [])
        test_files = [p for p, f in self.groups.files.items() if "UITestOnboarding" in f.words and p.endswith("UITests.swift")]
        expected = sorted({n for n in self.groups.names() for p in test_files if p in self.groups.own_files(n)})
        self.assertEqual(sorted(users), expected)


if __name__ == "__main__":
    unittest.main()
