"""Unit tests for .github/scripts/test_summary.py: the Swift Testing names (line by line, no
nested repetition in a regular expression, CodeQL py/redos on PR #1).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import test_summary  # noqa: E402

SOURCE = """import Testing

struct PlanTests {
    @Test func sameLine() {
        func helperInsideATest() -> Int { 1 }
    }

    @Test("A display name")
    @MainActor

    func afterAttributesAndABlankLine() async throws {}

    @Test(arguments: [1, 2]) func withArguments(_ n: Int) {}

    @Test
    let notAFunction = 1
    func notATest() {}

    @Testing func notTheAttribute() {}

    @Test(
        "Arguments over lines (with (nested) parentheses)",
        arguments: [(1, 2), (3, 4)]
    )
    func overSeveralLines(_ a: Int, _ b: Int) {}

    @Test("closing on the line", .tags(.slow)) @MainActor func onOneLine() {}
}
"""


class SwiftTestNameTests(unittest.TestCase):
    def test_names(self):
        self.assertEqual(test_summary.swift_test_names(SOURCE),
                         ["afterAttributesAndABlankLine", "onOneLine", "overSeveralLines", "sameLine",
                          "withArguments"])

    def test_long_attribute_runs_stay_fast(self):
        # The input that made the old pattern backtrack: many attribute-like lines, no func.
        source = "@Test\n" + "@a" * 20000 + "\n" + "   @b x\n" * 20000
        started = time.monotonic()
        self.assertEqual(test_summary.swift_test_names(source), [])
        self.assertLess(time.monotonic() - started, 2)


if __name__ == "__main__":
    unittest.main()
