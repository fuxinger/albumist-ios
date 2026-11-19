"""Rules over the test sources themselves (review P5-14, 18.11.2026): a red run of the fast tests
can be repeated (no unseeded randomness).

No script: the rules read the Swift files of the test targets (Tests/, App/SortlyTests,
App/SortlyUITests) directly. CI runs them with the other script tests ("check" in ci.yml).
"""
import os
import pathlib
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = pathlib.Path(HERE).parents[2]
TEST_DIRS = ("Tests", "App/SortlyTests", "App/SortlyUITests")

# Randomness the test cannot repeat: the system generator, directly or behind shuffled(),
# randomElement() and T.random(in:) without `using:` (review P5-14 c: a red run could not be
# repeated). A seeded generator (`using: &rng`) with the seed in the failure message is the way.
UNSEEDED = (
    re.compile(r"\.(?:shuffled|shuffle|randomElement)\(\s*\)"),
    re.compile(r"\bSystemRandomNumberGenerator\b"),
    re.compile(r"\b(?:arc4random(?:_uniform)?|drand48|srand48)\b"),
)

RANDOM_CALL = re.compile(r"\b(?:Int|Int\d+|UInt|UInt\d+|Double|Float|CGFloat|Bool)\.random\(")


def _arguments(code: str, start: int) -> str:
    """The text inside the parentheses that open at code[start - 1] (to the end of the line when
    they do not close on it)."""
    depth = 1
    for index in range(start, len(code)):
        depth += {"(": 1, ")": -1}.get(code[index], 0)
        if depth == 0:
            return code[start:index]
    return code[start:]


def _draws_without_seed(code: str) -> bool:
    if any(p.search(code) for p in UNSEEDED):
        return True
    return any(not re.search(r"\busing:", _arguments(code, m.end())) for m in RANDOM_CALL.finditer(code))


def code_lines(text: str):
    """(line number, code) of a Swift file without // comments (a line comment, or one after
    code; a "//" inside a string literal on the same line is left alone when it has no space
    before it, as in URLs)."""
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith("//"):
            continue
        yield number, re.split(r"\s//", line, maxsplit=1)[0]


def unseeded(text: str) -> list[int]:
    """Lines that draw from a generator without a seed."""
    return [n for n, code in code_lines(text) if _draws_without_seed(code)]


def swift_test_files():
    for folder in TEST_DIRS:
        yield from sorted((REPO / folder).rglob("*.swift"))


class UnseededTests(unittest.TestCase):
    def test_the_system_generator_is_found(self):
        src = ("let a = ids.shuffled()\n"
               "let b = ids.shuffled(using: &rng)\n"
               "let c = Int.random(in: 0..<10)\n"
               "let d = Int.random(in: 0..<10, using: &rng)\n"
               "let e = names.randomElement()\n"
               "var g = SystemRandomNumberGenerator()\n"
               "if Bool.random() { }\n"
               "let f = Double.random(in: 0...1, using: &rng)\n"
               "list.shuffle()\n"
               "let h = Double.random(in: 0..<(2 * .pi), using: &rng)\n"
               "let i = Double.random(in: 0..<(2 * .pi))\n")
        self.assertEqual(unseeded(src), [1, 3, 5, 6, 7, 9, 11])

    def test_comments_are_no_use(self):
        src = "// ids.shuffled() would not repeat\n/// Int.random(in: 0..<3)\nlet x = 1 // names.shuffled()\n"
        self.assertEqual(unseeded(src), [])

    def test_the_fast_tests_draw_only_from_a_seed(self):
        found = []
        for path in swift_test_files():
            for number in unseeded(path.read_text(encoding="utf-8")):
                found.append(f"{path.relative_to(REPO)}:{number}")
        self.assertEqual(found, [], "unseeded randomness: take a seeded generator (using: &rng) and name the seed")


if __name__ == "__main__":
    unittest.main()
