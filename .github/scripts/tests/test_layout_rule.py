"""Unit tests for .github/scripts/layout_rule.py, and the rule over the app's views
(review P3-12 / G3-07: a symbol with a fixed width drawn over the text at the largest size)."""
import os
import pathlib
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import layout_rule  # noqa: E402

REPO = pathlib.Path(HERE).parents[2]


class LayoutRuleTests(unittest.TestCase):
    def lines(self, text):
        return [line for line, _ in layout_rule.offenders_in(text)]

    def test_a_fixed_width_in_the_chain_is_found(self):
        src = ("HStack {\n"
               "    Image(systemName: Self.symbol(kind))\n"
               "        .foregroundStyle(.secondary)\n"
               "        .frame(width: 24)\n"
               "    Text(label)\n"
               "}\n")
        self.assertEqual(self.lines(src), [4])

    def test_a_fixed_width_and_height_on_the_same_line_is_found(self):
        self.assertEqual(self.lines('Image(systemName: "x").font(.title3).frame(width: 32, height: 32)\n'), [1])

    def test_a_scaled_width_passes(self):
        src = 'Image(systemName: "scissors")\n    .frame(width: symbolWidth)\n'
        self.assertEqual(self.lines(src), [])

    def test_a_minimum_width_passes(self):
        src = 'Image(systemName: "xmark")\n    .frame(minWidth: 44, minHeight: 44)\n'
        self.assertEqual(self.lines(src), [])

    def test_a_frame_after_the_chain_ends_is_not_the_symbols(self):
        src = 'Image(systemName: "x")\n    .font(.title3)\nText("a")\n    .frame(width: 24)\n'
        self.assertEqual(self.lines(src), [])

    def test_a_fixed_size_on_purpose_is_allowed_with_a_reason(self):
        src = 'Image(systemName: "x")\n    .frame(width: 24) // layout-rule: fixed (inside a 24 pt badge)\n'
        self.assertEqual(self.lines(src), [])

    def test_the_app_has_no_fixed_symbol_width(self):
        found = layout_rule.offenders(REPO)
        self.assertEqual(found, [], "\n".join(f"{path}:{line} {code}" for path, line, code in found))


if __name__ == "__main__":
    unittest.main()
