"""English wording rules for Localizable.xcstrings (German is the source language).

Review P3-10 / G3-10 (18.11.): the English read like a translation. This keeps the fixed
terms from coming back:
- "Sicher" (the confidence of a suggestion) is "Certain", never "Safe"; no English text says
  "safe" as an adjective (the confidence badge, "Accept all safe ones").
- American spelling: "analyzing", "analyzed", never "analysing", "analysed", "analyse".
- "trial run" stays out (the trial year is "Albumist works with", P3-09; the old word
  "Probelauf" was "test run").
- "Alles rückgängig machen" is "Undo Everything", never "Take Everything Back".
- Every visible button title is in title case, as Apple writes buttons in English
  ("Create Album", "Not Now", "Restore Purchase"). Button titles are read from the Swift code:
  Button("…"), Button(a ? "…" : "…"), Button { } label: { Text("…") } or Label("…", …),
  CardTextButton("…"), TapTarget("…"), and the titles in EXTRA_BUTTONS that the code passes
  through a variable.

Usage: english_rule.py <repo root>; prints offenders and exits 1 if there are any.
"""
import glob
import json
import re
import sys

CATALOG = "App/Sortly/Resources/Localizable.xcstrings"

# Button titles the code hands over in a variable (ProposalViews.swift `primaryTitle`, the card
# actions of ProposalCardLabels.swift `ProposalCardAction.title`) or shows behind a condition
# ("Namen vorschlagen" gives way to a spinner while it works).
EXTRA_BUTTONS = {
    "Album so lassen", "%lld %@ Fotos ergänzen", "Album ergänzen", "Album anlegen",
    "Namen eingeben", "Album auswählen", "Auswählen", "Namen vorschlagen",
    "Anlegen", "Ergänzen …", "Benennen …", "Ansehen …",
}

# Words that stay lowercase inside a title (Apple Style Guide: articles, coordinating
# conjunctions, prepositions of four letters or fewer). They may be capitalized too.
MINOR = {"a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet", "as", "at", "by",
         "in", "into", "of", "off", "on", "onto", "out", "over", "to", "up", "with", "from", "per", "via"}

TERMS = [
    (re.compile(r"\banalys(e|es|ed|ing)\b", re.I), "British spelling, write analyze/analyzing/analyzed"),
    (re.compile(r"\btrial run\b", re.I), "the trial year is \"Albumist works with\""),
    (re.compile(r"\btake everything back\b", re.I), "write \"Undo Everything\""),
    (re.compile(r"\bsafe\b", re.I), "\"Sicher\" is \"Certain\", not \"Safe\""),
]

LIT = r'"((?:[^"\\]|\\.)*)"'
INTERP = re.compile(r'\\\((?:[^()]|\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))*\)')


def norm(key):
    """A catalog key or a Swift literal with every placeholder written as #."""
    key = INTERP.sub("#", key).replace('\\"', '"').replace("%%", "%")
    return re.sub(r"%(\d\$)?(lld|ld|d|@|f|\.\d+f)", "#", key)


def load_catalog(root):
    with open(f"{root}/{CATALOG}", encoding="utf-8") as file:
        return json.load(file)["strings"]


def english_values(entry):
    """Every English text of a catalog entry: the plain one and each plural or device form."""
    out = []

    def walk(node):
        if isinstance(node, dict):
            unit = node.get("stringUnit")
            if isinstance(unit, dict) and "value" in unit:
                out.append(unit["value"])
            for name, child in node.items():
                if name != "stringUnit":
                    walk(child)
    walk(entry.get("localizations", {}).get("en", {}))
    return out


def _closing(src, start):
    """Index of the brace or parenthesis that closes the one at `start`, strings skipped."""
    opening = src[start]
    closing = {"{": "}", "(": ")"}[opening]
    depth, i = 0, start
    while i < len(src):
        c = src[i]
        if c == '"':
            i += 1
            while i < len(src) and src[i] != '"':
                if src[i] == "\\" and i + 1 < len(src) and src[i + 1] == "(":
                    i = _closing(src, i + 1)
                elif src[i] == "\\":
                    i += 1
                i += 1
        elif c == opening:
            depth += 1
        elif c == closing:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(src)


def _first_argument(src, open_paren):
    """The text of the first argument of the call whose `(` is at `open_paren`."""
    end = _closing(src, open_paren)
    depth, i = 0, open_paren + 1
    while i < end:
        c = src[i]
        if c == '"':
            i += 1
            while i < end and src[i] != '"':
                if src[i] == "\\" and src[i + 1] == "(":
                    i = _closing(src, i + 1)
                elif src[i] == "\\":
                    i += 1
                i += 1
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            return src[open_paren + 1:i]
        i += 1
    return src[open_paren + 1:end]


def button_titles_in(src):
    """The string literals a Swift file shows as button titles, as (line, literal)."""
    found = []

    def add(pos, literal):
        found.append((src.count("\n", 0, pos) + 1, literal))

    for m in re.finditer(r"\b(Button|CardTextButton|TapTarget)\(", src):
        arg = _first_argument(src, m.end() - 1)
        # Button(role: …) / Button(action: …) carry no title; a title is a literal or a choice
        # of literals (`selecting ? "Fertig" : "Auswählen"`, `String(localized: "…")`).
        if re.match(r"\s*\w+:", arg) and not arg.lstrip().startswith("String(localized:"):
            continue
        for lit in re.finditer(LIT, arg):
            add(m.start(), lit.group(1))
    for m in re.finditer(r"\bButton(\([^{}]*?\))?\s*\{", src):
        action_end = _closing(src, m.end() - 1)
        label = re.match(r"\s*label:\s*\{", src[action_end + 1:])
        if not label:
            continue
        open_brace = action_end + label.end()
        body = src[open_brace + 1:_closing(src, open_brace)].strip()
        title = re.match(r"(?:Text|Label)\((?:String\(localized: )?" + LIT, body)
        if title and not re.search(r"\b(VStack|HStack|ZStack|if|ForEach)\b", body):
            add(m.start(), title.group(1))
    return found


def button_keys(root):
    """Catalog keys shown as button titles, each with the first place it is used."""
    catalog = load_catalog(root)
    keys = {}
    for key in catalog:
        keys.setdefault(norm(key), key)
    used = {}
    for path in sorted(glob.glob(f"{root}/App/Sortly/**/*.swift", recursive=True)):
        with open(path, encoding="utf-8") as file:
            src = file.read()
        for line, literal in button_titles_in(src):
            key = keys.get(norm(literal))
            if key is not None:
                used.setdefault(key, f"{path.split('/')[-1]}:{line}")
    for key in EXTRA_BUTTONS:
        if key in catalog:
            used.setdefault(key, "EXTRA_BUTTONS")
    return used


def title_case_problem(text):
    """The first word that breaks title case, or None."""
    words = re.findall(r"[^\s]+", text)
    for index, word in enumerate(words):
        core = word.strip("“”\"'‘’()[],.:;!?…")
        if not core or not core[0].isalpha():
            continue  # a number or a placeholder like %lld or %@
        if core[0].isupper():
            continue
        if re.match(r"i[A-Z]", core):
            continue  # iCloud, iPhone
        if index not in (0, len(words) - 1) and core.lower() in MINOR:
            continue
        return core
    return None


def offenders(root):
    """(key, English text, problem) for every rule an English text breaks."""
    catalog = load_catalog(root)
    found = []
    for key, entry in catalog.items():
        for value in english_values(entry):
            for pattern, problem in TERMS:
                if pattern.search(value):
                    found.append((key, value, problem))
    for key, where in sorted(button_keys(root).items()):
        for value in english_values(catalog[key]):
            word = title_case_problem(value)
            if word:
                found.append((key, value, f"button ({where}) not in title case: \"{word}\""))
    return found


def main(argv):
    root = argv[1] if len(argv) > 1 else "."
    found = offenders(root)
    for key, value, problem in found:
        print(f"ENGLISH_STYLE | {key} | {value} | {problem}")
    print(f"ENGLISH_STYLE_CHECKED {len(button_keys(root))} button titles, {len(found)} problems")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
