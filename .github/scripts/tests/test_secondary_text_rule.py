"""Unit tests for .github/scripts/secondary_text_rule.py, the rule over the app's views, and the
contrast of `Theme.noteText` and `Theme.secondaryText` on the app's backgrounds (review P3-14: small text in the
system grey is 3.4:1 on a white card, WCAG 1.4.3 asks 4.5:1)."""
import os
import pathlib
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import secondary_text_rule  # noqa: E402

REPO = pathlib.Path(HERE).parents[2]
THEME = REPO / "App" / "Sortly" / "DesignSystem" / "Theme.swift"


class SecondaryTextRuleTests(unittest.TestCase):
    def lines(self, text):
        return [line for line, _ in secondary_text_rule.offenders_in(text)]

    def test_small_grey_text_on_one_line_is_found(self):
        self.assertEqual(self.lines('Text("12 Fotos").font(.footnote).foregroundStyle(.secondary)\n'), [1])

    def test_the_font_on_the_line_above_counts(self):
        src = 'Text("a")\n    .font(.subheadline)\n    .foregroundStyle(.secondary)\n'
        self.assertEqual(self.lines(src), [3])

    def test_the_font_on_the_line_below_counts(self):
        src = 'Label("a", systemImage: "lock")\n    .foregroundStyle(.secondary)\n    .font(.caption2)\n'
        self.assertEqual(self.lines(src), [2])

    def test_a_font_after_a_closing_brace_counts(self):
        src = 'Group {\n    Text("a")\n}\n.font(.footnote).foregroundStyle(.secondary)\n'
        self.assertEqual(self.lines(src), [4])

    def test_every_spelling_of_the_system_grey_is_found(self):
        for grey in (".secondary", "Color.secondary", "Color(uiColor: .secondaryLabel)",
                     "selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary)"):
            with self.subTest(grey=grey):
                self.assertEqual(self.lines(f'Text("a").font(.caption).foregroundStyle({grey})\n'), [1])
        self.assertEqual(self.lines('Text("a").font(.caption).foregroundColor(.secondary)\n'), [1])

    def test_a_font_chosen_by_condition_counts(self):
        src = 'Text("a")\n    .font(selected ? .subheadline.weight(.semibold) : .subheadline)\n    .foregroundStyle(.secondary)\n'
        self.assertEqual(self.lines(src), [3])

    def test_the_theme_greys_pass(self):
        self.assertEqual(self.lines('Text("a").font(.footnote).foregroundStyle(.noteText)\n'), [])
        self.assertEqual(self.lines('Text("a").font(.footnote).foregroundStyle(Theme.noteText)\n'), [])
        self.assertEqual(self.lines('Text("a").font(.footnote).foregroundStyle(Theme.secondaryText)\n'), [])

    def test_grey_text_in_a_large_font_is_not_this_rules(self):
        self.assertEqual(self.lines('Text("a").font(.headline).foregroundStyle(.secondary)\n'), [])
        self.assertEqual(self.lines('Text("a").foregroundStyle(.secondary)\n'), [])

    def test_the_next_view_is_not_the_chain(self):
        src = 'Text("a").font(.footnote)\nText("b")\n    .foregroundStyle(.secondary)\n'
        self.assertEqual(self.lines(src), [])

    def test_a_system_fill_is_not_the_grey(self):
        self.assertEqual(self.lines('Text("a").font(.footnote).background(Color(uiColor: .secondarySystemFill))\n'), [])

    def test_a_commented_line_is_skipped(self):
        self.assertEqual(self.lines('// Text("a").font(.footnote).foregroundStyle(.secondary)\n'), [])

    def test_the_system_grey_on_purpose_is_allowed_with_a_reason(self):
        src = ('Image(systemName: "eye.slash")\n    .font(.footnote)\n'
               '    .foregroundStyle(.secondary) // secondary-text: system (a symbol, not text)\n')
        self.assertEqual(self.lines(src), [])

    def test_the_app_has_no_small_text_in_the_system_grey(self):
        found = secondary_text_rule.offenders(REPO)
        self.assertEqual(found, [], f"{len(found)} small texts in the system grey:\n"
                         + "\n".join(f"{path}:{line} {code}" for path, line, code in found))

    def test_the_shared_style_uses_the_theme_grey(self):
        text = THEME.read_text(encoding="utf-8")
        shared = re.search(r"extension ShapeStyle where Self == Color \{[^}]*"
                           r"static var noteText: Color \{ Theme\.noteText \}", text)
        self.assertIsNotNone(shared, "Theme.swift has no `.noteText` style that returns Theme.noteText")


# WCAG 2 contrast (sRGB, alpha composited).
def _linear(channel):
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4


def _luminance(rgb):
    r, g, b = (_linear(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def _over(rgb, alpha, background):
    return tuple(alpha * c + (1 - alpha) * b for c, b in zip(rgb, background))


def contrast(a, b):
    hi, lo = sorted((_luminance(a), _luminance(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def _hex(code):
    return tuple(int(code[i:i + 2], 16) / 255 for i in (0, 2, 4))


# Apple's system colours (UIKit, iOS 26), sRGB. The fill is `tertiarySystemFill`
# (118, 118, 128) at 12 % light / 24 % dark (the chips of the analysis card); with
# Increase Contrast it is taken stronger (20 % / 30 %) than the system's, to stay on the safe side.
_FILL = (118 / 255, 118 / 255, 128 / 255)
BACKGROUNDS = {
    "light": {
        "card (secondarySystemGroupedBackground)": _hex("FFFFFF"),
        "grouped background (systemGroupedBackground)": _hex("F2F2F7"),
        "chip on a card (tertiarySystemFill)": _over(_FILL, 0.12, _hex("FFFFFF")),
        "chip on the grouped background": _over(_FILL, 0.12, _hex("F2F2F7")),
    },
    "light, Increase Contrast": {
        "card": _hex("FFFFFF"),
        "grouped background": _hex("EBEBF0"),
        "chip on a card": _over(_FILL, 0.20, _hex("FFFFFF")),
        "chip on the grouped background": _over(_FILL, 0.20, _hex("EBEBF0")),
    },
    "dark": {
        "card": _hex("1C1C1E"),
        "grouped background": _hex("000000"),
        "card in a sheet (elevated)": _hex("2C2C2E"),
        "chip on a card": _over(_FILL, 0.24, _hex("1C1C1E")),
        "chip on a card in a sheet": _over(_FILL, 0.24, _hex("2C2C2E")),
    },
    "dark, Increase Contrast": {
        "card": _hex("242426"),
        "grouped background": _hex("000000"),
        "card in a sheet (elevated)": _hex("363638"),
        "chip on a card": _over(_FILL, 0.30, _hex("242426")),
        "chip on a card in a sheet": _over(_FILL, 0.30, _hex("363638")),
    },
}


def theme_secondary_text():
    """The four variants of `Theme.secondaryText`, read from Theme.swift: the dark branch comes
    first in the source, then the light one."""
    text = THEME.read_text(encoding="utf-8")
    block = text[text.index("static let secondaryText"):]
    block = block[:block.index("})")]
    found = re.findall(r"red: high \? ([\d.]+) : ([\d.]+), green: high \? ([\d.]+) : ([\d.]+), "
                       r"blue: high \? ([\d.]+) : ([\d.]+)", block)
    if len(found) != 2 or "userInterfaceStyle == .dark" not in block:
        raise AssertionError("Theme.secondaryText no longer reads as dark branch, then light branch")
    (dark, light) = [[float(v) for v in values] for values in found]

    def pick(values, high):
        return (values[0], values[2], values[4]) if high else (values[1], values[3], values[5])
    return {
        "light": pick(light, False), "light, Increase Contrast": pick(light, True),
        "dark": pick(dark, False), "dark, Increase Contrast": pick(dark, True),
    }


def theme_note_text():
    """The four variants of `Theme.noteText`, read from Theme.swift."""
    text = THEME.read_text(encoding="utf-8")
    found = re.search(r"static let noteText = adaptive\(\s*light: \(([^)]*)\),\s*dark: \(([^)]*)\),\s*"
                      r"lightHigh: \(([^)]*)\),\s*darkHigh: \(([^)]*)\)\)", text)
    if not found:
        raise AssertionError("Theme.noteText no longer reads as adaptive(light:dark:lightHigh:darkHigh:)")
    light, dark, light_high, dark_high = (tuple(float(v) for v in group.split(",")) for group in found.groups())
    return {"light": light, "light, Increase Contrast": light_high,
            "dark": dark, "dark, Increase Contrast": dark_high}


class ContrastTests(unittest.TestCase):
    def test_the_note_grey_holds_4_5_to_1_on_every_background(self):
        """Fails when someone lightens `Theme.noteText` below 4.5:1 on any background it is used on."""
        colours = theme_note_text()
        for mode, backgrounds in BACKGROUNDS.items():
            for name, background in backgrounds.items():
                with self.subTest(mode=mode, background=name):
                    self.assertGreaterEqual(contrast(colours[mode], background), 4.5)

    def test_the_note_grey_stays_lighter_than_the_wash_grey(self):
        """The hierarchy: the note grey sits between the system grey and `secondaryText`."""
        note, wash = theme_note_text(), theme_secondary_text()
        for mode, backgrounds in BACKGROUNDS.items():
            for name, background in backgrounds.items():
                with self.subTest(mode=mode, background=name):
                    self.assertLess(contrast(note[mode], background), contrast(wash[mode], background))

    def test_increase_contrast_makes_the_note_grey_clearly_stronger(self):
        note = theme_note_text()
        for mode, background in (("light", _hex("FFFFFF")), ("dark", _hex("1C1C1E"))):
            with self.subTest(mode=mode):
                self.assertGreater(contrast(note[f"{mode}, Increase Contrast"], background),
                                   contrast(note[mode], background) + 1)

    def test_the_note_grey_is_read_from_the_source(self):
        note = theme_note_text()
        self.assertEqual(note["light"], (0.39, 0.39, 0.42))
        self.assertEqual(note["dark"], (0.67, 0.67, 0.70))
        self.assertAlmostEqual(contrast(note["light"], _hex("FFFFFF")), 5.92, delta=0.01)
        self.assertAlmostEqual(contrast(note["dark"], _hex("1C1C1E")), 7.45, delta=0.01)

    def test_the_wash_grey_holds_4_5_to_1_on_every_background(self):
        colours = theme_secondary_text()
        self.assertEqual(len(colours), 4)
        for mode, backgrounds in BACKGROUNDS.items():
            for name, background in backgrounds.items():
                with self.subTest(mode=mode, background=name):
                    self.assertGreaterEqual(contrast(colours[mode], background), 4.5)

    def test_the_wash_grey_is_read_from_the_source(self):
        colours = theme_secondary_text()
        self.assertEqual(colours["light"], (0.27, 0.27, 0.30))
        self.assertEqual(colours["dark"], (0.78, 0.78, 0.81))
        self.assertAlmostEqual(contrast(colours["light"], _hex("FFFFFF")), 9.5, delta=0.05)
        self.assertAlmostEqual(contrast(colours["dark"], _hex("1C1C1E")), 10.1, delta=0.05)

    def test_the_system_grey_falls_short_in_light_mode(self):
        """Why the rule exists: `secondaryLabel` is (60, 60, 67) at 60 % in light mode."""
        grey = (60 / 255, 60 / 255, 67 / 255)
        for name, background in (("card", _hex("FFFFFF")), ("grouped background", _hex("F2F2F7"))):
            with self.subTest(background=name):
                self.assertLess(contrast(_over(grey, 0.6, background), background), 4.5)


if __name__ == "__main__":
    unittest.main()
