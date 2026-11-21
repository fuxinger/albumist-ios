#!/usr/bin/env python3
"""At most one filled main button shows on a page at a time.

Design rule 3 of the design package (20.11.2026, DS-04b; "Woran wir messen": "Pro Seite höchstens
ein farbiger Hauptknopf; Knöpfe auf Karten sind getönt, nicht voll farbig"). The overview showed two
full coloured buttons at once (screenshot ui-06 of 18.11.), and the second review (S11) asked for a
check that reads what a page shows, not one file: the start page shows cards from other files.

Filled: the styles in `FILLED_STYLES` (`PrimaryButtonStyle()`, the system's `.borderedProminent` and
`.glassProminent`), a toolbar item at `.confirmationAction` (iOS 26 draws it as `.glassProminent`) and
`Button(role: .confirm)`. A style set on a container fills every button in it that sets none of its
own. Every button style the app declares or uses is named in `FILLED_STYLES` or `NOT_FILLED` (the
tinted `CardActionButtonStyle` of the cards and the grey `SecondaryButtonStyle` are not filled): a
style the rule does not know is reported until it is named, so a new filled one is never missed.

A page is what one screen shows: a view's `body` with everything it shows, that is the properties
and functions of the view it uses (also from its extensions in other files), the app's views it
uses (in any file: `EmptyLibraryCard` on the start page) with theirs, the app's view modifiers
(`.showsQuickCreateBanner()`), its toolbar, bars (`safeAreaInset`), overlays and backgrounds. A
sheet, full-screen cover, popover, inspector, navigation destination, `NavigationLink` destination
and the content of a `Tab` are pages of their own. Alerts, confirmation dialogs, menus, context menus
and swipe actions are drawn by the system and count nowhere. Every view is checked as a page; a pair
is reported once, at the smallest page that shows both buttons.

At the same time: the branches of an `if`/`else`, the cases of a `switch` and the views of a
`ViewThatFits` show one at a time, and a view's `Bool` property given as `true` or `false` where the
view is used (`UnlockButton(prominent: true)`) picks its branch. Everything else adds up, and the
rows of a `ForEach` or of a `List` of data show their button more than once. Read as the App Store
build: code under `#if DEBUG` or `#if targetEnvironment(simulator)` is left out (the demo library's
card exists only in the simulator); the branches of any other `#if` add up.

What the code itself cannot say goes in `TAKE_TURNS` (buttons in places of their own that never show
together) and `SHOWN_ONCE` (a `ForEach` whose rows show a button once), each with why and the code
that makes it so: the rule reports an entry whose buttons the page no longer shows or whose code is
gone, so an entry cannot outlive its reason. A filled button the rule cannot place on a page (in a
property of a view that its body never uses, or in a closure kept for later) is reported too.

Not seen (known gaps): a style kept in a variable (reported as unknown, never passed); a view kept in
a stored property and shown later; a choice written as a ternary or in `TabView` children without
`Tab`, whose sides add up (a false alarm, never a silent pass). A menu is one button: its items are
the system's. Read without comments and string contents (navigation_rule.code_only).

Usage: filled_button_rule.py <repo root>; prints offenders and exits 1 if there are any.
"""
import bisect
import os
import pathlib
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from navigation_rule import code_only  # noqa: E402

APP = "App/Albumist"

# Button styles that fill the button with colour, and why.
FILLED_STYLES = {
    "PrimaryButtonStyle": "the app's main button: a solid accent capsule (Theme.swift)",
    ".borderedProminent": "the system's filled button",
    "BorderedProminentButtonStyle": "the system's filled button",
    ".glassProminent": "the system's tinted glass button (iOS 26)",
    "GlassProminentButtonStyle": "the system's tinted glass button (iOS 26)",
}
# Button styles that do not, and what they draw.
NOT_FILLED = {
    "SecondaryButtonStyle": "a grey capsule with the primary text colour, beside the one filled button",
    "CardActionButtonStyle": "tinted: the accent as text on a light fill of it, the actions of cards",
    "RingCardRowButtonStyle": "a row of the ring card, grey only while it is held",
    "StartMadeButtonStyle": "the made card's label as it draws itself (a tinted capsule)",
    "PressReportingButtonStyle": "plain; it says when the card is held",
    ".plain": "the label alone",
    "PlainButtonStyle": "the label alone",
    ".borderless": "the label in the accent colour",
    "BorderlessButtonStyle": "the label in the accent colour",
    ".bordered": "a tinted capsule",
    "BorderedButtonStyle": "a tinted capsule",
    ".automatic": "the system's choice for the place: a plain or tinted button",
    "DefaultButtonStyle": "the system's choice for the place: a plain or tinted button",
    ".glass": "the system's clear glass button (iOS 26)",
    "GlassButtonStyle": "the system's clear glass button (iOS 26)",
    ".link": "a link",
}

# Buttons of one page, in places of their own, that never show together: the page (a view), the
# buttons (by the view and the property or function their filled style is written in), why, and
# the code that makes it so (file, pattern in the code without comments and strings). Only what
# the code itself cannot say. The rule reports an entry whose buttons are gone or whose code is.
TAKE_TURNS = {
    "PlanReviewView": [(
        {"PlanReviewView.applyButton", "FullAccessCard.body", "UnlockCard.body", "ResultCard.photosButton"},
        "the bar with the plan's button stands only under a plan that can run (`previewed` with no "
        "`obstacle`); the cards \"Voller Zugriff nötig\" and \"Albumist freischalten\" show only what is "
        "in its way (`obstacleCard`), and \"Fotos-App öffnen\" only on the result, when `previewed` is nil",
        [("App/Albumist/Views/PlanReviewView.swift", r"if let previewed, previewed\.obstacle == nil"),
         ("App/Albumist/Views/PlanReviewView.swift", r"if let obstacle \{ obstacleCard\("),
         ("App/Albumist/Views/PlanReviewView.swift", r"guard show == nil, !model\.execution\.isRunning, "
                                                     r"model\.execution\.finished == nil")],
    )],
    "ProposalDetailView": [(
        {"ProposalDetailView.primaryButton", "FullAccessCard.body"},
        "without full access the bar keeps only \"Nicht jetzt\" (`actionBar`), and the page's filled "
        "button is the card's \"Einstellungen öffnen\"",
        [("App/Albumist/Views/ProposalViews.swift", r"if needsFullAccess \{\s*FullAccessCard\(\)"),
         ("App/Albumist/Views/ProposalViews.swift", r"if needsFullAccess \{\s*notNowButton\(card, beside: false\)"
                                                    r"\s*\} else if")],
    )],
    "TripWorkshopView": [(
        {"TripWorkshopView.splitBar", "TripWorkshopView.finished"},
        "the bar with \"Reise teilen\" stands only while nothing is done; \"Zu den Reisen\" only once a "
        "change is done",
        [("App/Albumist/Views/TripWorkshopView.swift", r"if done == nil, working == nil"),
         ("App/Albumist/Views/TripWorkshopView.swift", r"if let done \{\s*finished\(done\)")],
    )],
    "OverviewView": [
        ({"InterruptedPlanCard.body", "StarterSetCard.body"},
         "\"Dein Startpaket\" never shows beside an interrupted plan, whose \"Rest anlegen\" is the "
         "page's filled button then (StartPageTests.noStarterSetBesideAnInterruptedPlan)",
         [("Sources/AlbumistCore/Domain/StartPage.swift", r"guard input\.analysedOnce, !input\.interruptedPlan"),
          ("App/Albumist/Model/AppModel+Start.swift", r"interruptedPlan: interruptedPlan != nil")]),
        ({"EmptyLibraryCard.body", "StarterSetCard.body"},
         "the card for an empty library shows only when the analysis made no suggestion or saw no "
         "photo, \"Dein Startpaket\" only with three suggestions or more",
         [("Sources/AlbumistCore/Proposals/EmptyLibraryState.swift", r"guard input\.proposals == 0 else \{ return nil \}"),
          ("Sources/AlbumistCore/Domain/StartPage.swift", r"offered\.count >= starterSetMinimum")]),
    ],
}
# A `ForEach` whose rows show a filled button once: the view and the property or function the
# `ForEach` is written in, the button (as in `TAKE_TURNS`), why, and the code that makes it so.
SHOWN_ONCE = {
    ("StartSections.body", "StarterSetCard.body"): (
        "the rows are the sections of the start page, which has one big part at most",
        [("Sources/AlbumistCore/Domain/StartPage.swift",
          r"\} else if !starter\.isEmpty \{\s*sections\.append\(\.starterSet\(starter\)\)")],
    ),
}

PRESENTATIONS = {"sheet", "fullScreenCover", "popover", "inspector", "navigationDestination"}
SYSTEM_PRESENTATIONS = {"alert", "confirmationDialog", "contextMenu", "swipeActions"}
BUTTON_KINDS = {"Button", "ShareLink", "Link", "PasteButton", "EditButton", "RenameButton", "PhotosPicker"}
KEYWORDS = {"if", "else", "switch", "case", "default", "for", "while", "guard", "return", "let", "var",
            "func", "in", "where", "true", "false", "nil", "self", "Self", "some", "any", "try", "await"}

IDENT = re.compile(r"[A-Za-z_]\w*")
DECLARATION = re.compile(r"\b(struct|class|enum|extension|actor|protocol)\s+([A-Za-z_]\w*)")
MEMBER = re.compile(r"\b(var|func)\s+([A-Za-z_]\w*)")
VIEW_RESULT = re.compile(r"\bsome\s+View\b|\bany\s+View\b|\bAnyView\b|\bsome\s+ToolbarContent\b")
BUILDER = re.compile(r"@(?:ViewBuilder|ToolbarContentBuilder)\b")
BOOL_PROPERTY = re.compile(r"\b(?:var|let)\s+([A-Za-z_]\w*)\s*(?::\s*Bool\s*)?=\s*(true|false)\b")
STYLE = re.compile(r"\.\s*buttonStyle\s*\(")
STYLE_DECLARATION = re.compile(r"\b(?:struct|class)\s+([A-Za-z_]\w*)[^{]*?:[^{]*?\b(?:Primitive)?ButtonStyle\b")
CONFIRM_ROLE = re.compile(r"\brole\s*:\s*\.confirm\b")
CONFIRM_PLACEMENT = re.compile(r"\bplacement\s*:\s*\.confirmationAction\b")
DIRECTIVE = re.compile(r"^[ \t]*#(if|elseif|else|endif)\b([^\n]*)", re.MULTILINE)
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
# Names the code declares for itself: `let x`, `var x`, `if let x`, `case .a(let x)`, a closure's
# `x in` or `x, y in`.
LOCAL = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)|([A-Za-z_]\w*)\s*(?=,\s*[A-Za-z_]\w*\s+in\b|\s+in\b)")

TOGETHER = ("{page}: {first} and {second} can show at once. One filled main button per page (design "
            "rule 3): make one of them SecondaryButtonStyle(), or CardActionButtonStyle() on a card; if "
            "they never show together, say why in TAKE_TURNS of filled_button_rule.py")
REPEATED = ("{page}: {first} shows in every row of a list. One filled main button per page (design "
            "rule 3): a row's action is tinted (CardActionButtonStyle()) or plain; if the rows show it once, "
            "say why in SHOWN_ONCE of filled_button_rule.py")
UNKNOWN_STYLE = ("Button style {style} is in neither FILLED_STYLES nor NOT_FILLED of filled_button_rule.py: "
                 "name it there, with whether it fills the button with colour")
UNPLACED = ("Filled button {button} is on no page the rule can see: write it in a view's body or in a "
            "property or function of the view that the body uses")
GONE = ("{entry} of filled_button_rule.py names {button}, which {page} does not show (any more): "
        "update or remove the entry")
NO_WITNESS = ("{entry} of filled_button_rule.py rests on `{pattern}` in {path}, which is not there any more: "
              "check that the buttons still never show together, then update the entry")


# MARK: - Reading the code

def release_value(condition: str):
    """Whether the App Store build compiles `#if condition`: False for DEBUG and the simulator,
    True for their negation, None for anything else."""
    condition = condition.strip()
    while condition.startswith("(") and condition.endswith(")"):
        condition = condition[1:-1].strip()
    if "||" in condition:
        values = [release_value(part) for part in condition.split("||")]
        return True if True in values else False if all(v is False for v in values) else None
    if "&&" in condition:
        values = [release_value(part) for part in condition.split("&&")]
        return False if False in values else True if all(v is True for v in values) else None
    if condition.startswith("!"):
        value = release_value(condition[1:])
        return None if value is None else not value
    if re.fullmatch(r"DEBUG|targetEnvironment\(\s*simulator\s*\)", condition):
        return False
    return None


def release_code(code: str) -> str:
    """`code` as the App Store build compiles it: what stands under `#if DEBUG` or
    `#if targetEnvironment(simulator)` blanked (newlines kept), the directives themselves too."""
    out = list(code)
    frames: list[list] = []  # [live, taken] for each open #if

    def blank(start, end):
        for index in range(start, end):
            if out[index] != "\n":
                out[index] = " "

    last = 0
    for directive in DIRECTIVE.finditer(code):
        if any(not live for live, _ in frames):
            blank(last, directive.start())
        kind, condition = directive.group(1), directive.group(2)
        if kind == "if":
            value = release_value(condition)
            frames.append([value is not False, value is True])
        elif frames and kind == "elseif":
            frame = frames[-1]
            value = None if frame[1] else release_value(condition)
            frame[0] = not frame[1] and value is not False
            frame[1] = frame[1] or value is True
        elif frames and kind == "else":
            frames[-1][0] = not frames[-1][1]
        elif frames and kind == "endif":
            frames.pop()
        blank(directive.start(), directive.end())
        last = directive.end()
    if any(not live for live, _ in frames):
        blank(last, len(code))
    return "".join(out)


def brackets(code: str) -> dict:
    """The index of the matching bracket of every bracket in `code`, both ways."""
    match, stack = {}, []
    for index, char in enumerate(code):
        if char in "([{":
            stack.append(index)
        elif char in ")]}" and stack:
            opening = stack.pop()
            match[opening], match[index] = index, opening
    return match


def skip_space(code: str, index: int, end: int | None = None) -> int:
    end = len(code) if end is None else end
    while index < end and code[index].isspace():
        index += 1
    return index


def skip_space_back(code: str, index: int) -> int:
    while index >= 0 and code[index].isspace():
        index -= 1
    return index


def word_back(code: str, index: int):
    """(start, word) of the identifier that ends at `index`, or None."""
    start = index
    while start >= 0 and (code[start].isalnum() or code[start] == "_"):
        start -= 1
    return (start + 1, code[start + 1:index + 1]) if start < index else None


class Source:
    """One Swift file: its text, its code as the App Store build reads it, and its brackets."""

    def __init__(self, path: str, text: str):
        self.path = path
        self.text = text
        self.code = release_code(code_only(text))
        self.match = brackets(self.code)
        self.newlines = [index for index, char in enumerate(self.code) if char == "\n"]
        self.depth = []
        depth = 0
        for char in self.code:
            self.depth.append(depth)
            depth += 1 if char == "{" else -1 if char == "}" else 0
        # The filled styles' receivers, every style's first use per receiver, unknown styles.
        self.styles: dict[int, tuple] = {}      # receiver start -> (style name, "." of the style, after it)
        self.loose_styles: dict[int, tuple] = {}  # "." of a style whose receiver is not found -> (name, after)
        self.unknown_styles: list[tuple] = []   # (offset, style)
        self.filled_styles: list[int] = []      # "." of each filled style

    def line(self, offset: int) -> int:
        return bisect.bisect_left(self.newlines, offset) + 1

    def call(self, index: int, end: int):
        """The arguments `( … )` and the trailing closures `{ … } label: { … }` that follow a name
        ending at `index`: (arguments or None, [closures], index after them)."""
        code, match = self.code, self.match
        at = skip_space(code, index, end)
        if at < end and code[at] == "<":  # generic arguments
            depth = 0
            while at < end:
                depth += {"<": 1, ">": -1}.get(code[at], 0)
                at += 1
                if depth == 0:
                    break
            at = skip_space(code, at, end)
        arguments = None
        if at < end and code[at] == "(" and at in self.match:
            arguments = (at + 1, match[at])
            at = skip_space(code, match[at] + 1, end)
        closures = []
        while at < end and code[at] == "{" and at in match:
            closures.append((at + 1, match[at]))
            after = skip_space(code, match[at] + 1, end)
            label = IDENT.match(code, after)
            if label and label.group() not in KEYWORDS:
                colon = skip_space(code, label.end(), end)
                if colon < end and code[colon] == ":":
                    brace = skip_space(code, colon + 1, end)
                    if brace < end and code[brace] == "{":
                        at = brace
                        continue
            at = match[at] + 1
        if arguments is None and not closures:
            return None, [], index
        return arguments, closures, at

    def body_brace(self, start: int, end: int):
        """The `{` that opens the body of an `if` or `switch` whose condition starts at `start`."""
        index = start
        while index < end:
            char = self.code[index]
            if char in "([" and index in self.match:
                index = self.match[index] + 1
                continue
            if char == "{":
                return index if index in self.match else None
            index += 1
        return None

    def receiver(self, dot: int):
        """Start of the expression a modifier at `dot` (the "." of `.buttonStyle`) is applied to:
        the name it begins with (`Button`, `VStack`, a property of the view), or None."""
        code, index = self.code, dot - 1
        while True:
            index = skip_space_back(code, index)
            if index < 0:
                return None
            char = code[index]
            if char in ")]}":
                if index not in self.match:
                    return None
                index = self.match[index] - 1
                continue
            if char == ":":  # the label of a trailing closure: `} label: {`
                found = word_back(code, skip_space_back(code, index - 1))
                if not found:
                    return None
                index = found[0] - 1
                continue
            found = word_back(code, index)
            if not found:
                return None
            start, word = found
            before = skip_space_back(code, start - 1)
            if before >= 0 and code[before] == ".":
                owner = word_back(code, skip_space_back(code, before - 1))
                if owner and owner[1] == "self":
                    return start
                index = before - 1
                continue
            return start if word not in KEYWORDS else None

    def title(self, start: int, end: int):
        """The first string literal of the code between `start` and `end`: the button's words, or
        None when it shows words from a variable."""
        for literal in LITERAL.finditer(self.text, start, end):
            if self.code[literal.start()] == '"' and self.code[literal.end() - 1] == '"':
                words = literal.group(1)
                return words if len(words) <= 48 else words[:47] + "…"
        return None


def style_name(argument: str):
    """`PrimaryButtonStyle()` → "PrimaryButtonStyle", `.borderedProminent` → ".borderedProminent";
    None for anything else (a variable, a ternary)."""
    argument = " ".join(argument.split())
    found = re.fullmatch(r"(\.?[A-Za-z_]\w*)\s*(?:\(.*\))?", argument)
    if not found:
        return None
    name = found.group(1)
    return name if name.startswith(".") or name[0].isupper() else None


# MARK: - What a page shows

class Leaf:
    """One filled button: where its filled style (or prominent item) is written, and its words."""

    def __init__(self, name: str, path: str, line: int, title):
        self.name, self.path, self.line, self.title = name, path, line, title

    def __str__(self):
        shown = f"„{self.title}“" if self.title else self.name
        return f"{shown} ({self.path}:{self.line})"


class Node:
    """What a part of a page can show: `leaves`, the filled buttons it can show, and `pairs`, the
    two of them (or one twice) it can show at the same time."""
    leaves: frozenset = frozenset()
    pairs: frozenset = frozenset()


def pair(a: int, b: int) -> tuple:
    return (a, b) if a <= b else (b, a)


class One(Node):
    def __init__(self, leaf: int):
        self.leaves = frozenset([leaf])


class Seq(Node):
    """Shown together."""

    def __init__(self, children):
        leaves, pairs = set(), set()
        for child in children:
            pairs |= child.pairs
            pairs |= {pair(a, b) for a in child.leaves for b in leaves}
            leaves |= child.leaves
        self.leaves, self.pairs = frozenset(leaves), frozenset(pairs)


class Alt(Node):
    """One of them at a time."""

    def __init__(self, children):
        self.leaves = frozenset().union(*(child.leaves for child in children))
        self.pairs = frozenset().union(*(child.pairs for child in children))


class Many(Node):
    """The rows of a list: every row can show what one row shows, except the buttons in `once`."""

    def __init__(self, child: Node, once: set):
        self.leaves = child.leaves
        self.pairs = child.pairs | {pair(a, b) for a in child.leaves for b in child.leaves
                                    if a != b or a not in once}


class Apart(Node):
    """`child`, whose buttons in one group of `groups` never show together."""

    def __init__(self, child: Node, groups):
        self.leaves = child.leaves
        self.pairs = frozenset(p for p in child.pairs
                               if p[0] == p[1] or not any(p[0] in group and p[1] in group for group in groups))


EMPTY = Seq([])


class TypeInfo:
    def __init__(self, name: str):
        self.name = name
        self.is_view = False
        self.members: dict[str, list] = {}   # view member name -> [(source, start, end)]
        self.functions: set = set()          # the view members that are functions
        self.bools: dict[str, bool] = {}     # Bool properties with their value when not given
        self.declarations: list = []         # (source, offset)


class Page:
    def __init__(self, label: str, path: str, line: int, is_view: bool):
        self.label, self.path, self.line, self.is_view = label, path, line, is_view
        self.node = EMPTY


class App:
    """The app's Swift files, read once: its types, their view members, and every page."""

    def __init__(self, sources: dict):
        self.sources = [Source(path, text) for path, text in sorted(sources.items())]
        self.types: dict[str, TypeInfo] = {}
        self.leaves: list[Leaf] = []
        self.leaf_index: dict[tuple, int] = {}
        self.memo: dict[tuple, Node] = {}
        self.building: set = set()
        self.pages: dict[tuple, Page] = {}
        self.pending: list[tuple] = []
        self.placed: set = set()  # (path, ".") of each filled style seen on a page
        self.button_styles: list[tuple] = []  # (path, line, name) of each ButtonStyle the app declares
        for source in self.sources:
            self.index(source)
        self.read_pages()

    # The index of types, members and styles.

    def type_key(self, name: str, source: Source, private: bool = False) -> str:
        return f"{source.path}#{name}" if private else name

    def resolve(self, name: str, source: Source):
        """The type `name` means in `source`: a private one of the file first."""
        local = f"{source.path}#{name}"
        if local in self.types:
            return local
        return name if name in self.types else None

    def index(self, source: Source):
        code = source.code
        for found in STYLE_DECLARATION.finditer(code):
            self.button_styles.append((source.path, source.line(found.start()), found.group(1)))
        for declaration in DECLARATION.finditer(code):
            kind, name = declaration.group(1), declaration.group(2)
            if kind == "protocol" or name in KEYWORDS:
                continue
            opening = code.find("{", declaration.end())
            if opening < 0 or opening not in source.match:
                continue
            header = code[declaration.end():opening]
            if "\n\n" in header.strip():
                continue  # not a declaration with a body
            line_start = code.rfind("\n", 0, declaration.start()) + 1
            private = kind != "extension" and re.search(r"\b(?:private|fileprivate)\b",
                                                        code[line_start:declaration.start()]) is not None
            key = self.resolve(name, source) if kind == "extension" else self.type_key(name, source, private)
            key = key or name
            info = self.types.setdefault(key, TypeInfo(name))
            info.declarations.append((source, declaration.start()))
            if kind != "extension" and re.search(r"\bView\b", header):
                info.is_view = True
            if kind == "extension" and re.search(r":[^{]*\bView\b", header):
                info.is_view = True
            self.members_of(source, info, opening)
        for style in STYLE.finditer(code):
            self.read_style(source, style)

    def members_of(self, source: Source, info: TypeInfo, opening: int):
        code, closing = source.code, source.match[opening]
        level = source.depth[opening] + 1
        for bool_property in BOOL_PROPERTY.finditer(code, opening, closing):
            if source.depth[bool_property.start()] == level:
                info.bools.setdefault(bool_property.group(1), bool_property.group(2) == "true")
        for member in MEMBER.finditer(code, opening, closing):
            if source.depth[member.start()] != level:
                continue
            kind, name = member.group(1), member.group(2)
            body = self.member_body(source, kind, member.end(), closing)
            if body is None:
                continue
            signature = code[member.end():body]
            line_start = code.rfind("\n", 0, code.rfind("\n", 0, member.start())) + 1
            attributes = code[line_start:member.start()]
            if name == "body" or VIEW_RESULT.search(signature) or BUILDER.search(attributes):
                info.members.setdefault(name, []).append((source, body + 1, source.match[body]))
                if kind == "func":
                    info.functions.add(name)

    def member_body(self, source: Source, kind: str, index: int, end: int):
        """The `{` of a computed property's or a function's body, or None for a stored property."""
        code, match = source.code, source.match
        while index < end:
            char = code[index]
            if char in "([" and index in match:
                index = match[index] + 1
                continue
            if char == "{":
                return index if index in match else None
            if kind == "var" and char in "=\n":
                return None
            index += 1
        return None

    def read_style(self, source: Source, style):
        code = source.code
        opening = style.end() - 1
        if opening not in source.match:
            return
        after = source.match[opening] + 1
        name = style_name(code[opening + 1:after - 1])
        if name not in FILLED_STYLES and name not in NOT_FILLED:
            source.unknown_styles.append((style.start(), name or " ".join(code[opening + 1:after - 1].split())))
        filled = name in FILLED_STYLES
        if filled:
            source.filled_styles.append(style.start())
        start = source.receiver(style.start())
        if start is None:
            if filled:
                source.loose_styles[style.start()] = (name, after)
            return
        first = source.styles.get(start)
        if first is None or style.start() < first[1]:  # the style nearest the button wins
            source.styles[start] = (name, style.start(), after)

    # Building what a page shows.

    def leaf(self, name: str, source: Source, at: int, title, line: int | None = None) -> One:
        """The filled button that starts at `at`, named where its style is written (at `line`)."""
        key = (source.path, at)
        if key not in self.leaf_index:
            self.leaf_index[key] = len(self.leaves)
            self.leaves.append(Leaf(name, source.path, line or source.line(at), title))
        return One(self.leaf_index[key])

    def view_member(self, key: str, name: str):
        info = self.types.get(key)
        return info.members.get(name) if info else None

    def uses_member(self, key: str, name: str, source: Source, at: int, following: int, end: int, local: set) -> bool:
        """Whether `name` at `at` shows the view member of that name: a function where it is called
        (`planContent(…)`), a property where no local of that name stands (`let finished = …`, a
        closure's `section in`)."""
        info = self.types.get(key)
        if not info or name not in info.members:
            return False
        if name in info.functions:
            return following < end and source.code[following] == "("
        return name not in local

    def build_type(self, key: str, flags: frozenset, styled):
        memo = ("type", key, flags, styled)
        if memo in self.memo:
            return self.memo[memo]
        node = self.build_member(key, "body", flags, styled)
        groups = TAKE_TURNS.get(self.types[key].name)
        if groups:
            node = Apart(node, [frozenset(number for number in node.leaves if self.leaves[number].name in names)
                                for names, _, _ in groups])
        self.memo[memo] = node
        return node

    def build_member(self, key: str, name: str, flags: frozenset, styled):
        memo = (key, name, flags, styled)
        if memo in self.memo:
            return self.memo[memo]
        if memo in self.building:
            return EMPTY  # a view that shows itself
        bodies = self.view_member(key, name)
        if not bodies:
            return EMPTY
        self.building.add(memo)
        context = (key, self.types[key].name, name, flags, styled)
        node = Alt([self.build_range(context, source, start, end) for source, start, end in bodies])
        self.building.discard(memo)
        self.memo[memo] = node
        return node

    def flags_for(self, key: str, source: Source, arguments):
        """The `Bool` properties of the view `key` as one use gives them (`prominent: true`), or
        their value when it gives none."""
        values = dict(self.types[key].bools)
        if arguments:
            text = source.code[arguments[0]:arguments[1]]
            for given in re.finditer(r"\b([A-Za-z_]\w*)\s*:\s*(true|false)\b", text):
                values[given.group(1)] = given.group(2) == "true"
        return frozenset(values.items())

    def choice(self, flags: frozenset, condition: str):
        """True or False when `condition` is one `Bool` property the use of the view gave."""
        found = re.fullmatch(r"(!)?\s*(?:self\s*\.\s*)?([A-Za-z_]\w*)", condition.strip())
        values = dict(flags)
        if not found or found.group(2) not in values:
            return None
        return values[found.group(2)] != bool(found.group(1))

    def add_page(self, label: str, context, source: Source, at: int, ranges):
        key = (source.path, at)
        if key not in self.pages:
            self.pages[key] = Page(label, source.path, source.line(at), False)
            self.pending.append((key, (context[0], context[1], context[2], context[3], None), source, ranges))

    def build_range(self, context, source: Source, start: int, end: int) -> Node:
        """What the code between `start` and `end` shows, in the view `context` is in."""
        key, type_name, member, flags, styled = context
        code = source.code
        items: list[Node] = []
        local = {found.group(1) or found.group(2) for found in LOCAL.finditer(code, start, end)}
        index = start
        while True:
            found = IDENT.search(code, index, end)
            if not found:
                break
            word, at, index = found.group(), found.start(), found.end()
            before = skip_space_back(code, at - 1)
            previous = code[before] if before >= 0 else ""
            if previous in "#$@":
                continue
            following = skip_space(code, index, end)
            labelled = following < end and code[following] == ":" and previous != "?"
            if previous == ".":
                owner = word_back(code, skip_space_back(code, before - 1))
                if owner and owner[1] == "self":
                    if at in source.styles:
                        node, index = self.styled(context, source, word, at, index, end)
                        items.append(node)
                    elif self.uses_member(key, word, source, at, following, end, set()):
                        items.append(self.build_member(key, word, flags, styled))
                    continue
                # A static view member: `Self.chevron`, `RingCard.chevron(…)`.
                owner_key = key if owner and owner[1] == "Self" else (
                    self.resolve(owner[1], source) if owner and owner[1][:1].isupper() else None)
                if owner_key and self.uses_member(owner_key, word, source, at, following, end, set()):
                    values = flags if owner_key == key else frozenset(self.types[owner_key].bools.items())
                    items.append(self.build_member(owner_key, word, values, styled))
                    continue
                if word in PRESENTATIONS or word in SYSTEM_PRESENTATIONS:
                    arguments, closures, after = source.call(index, end)
                    if word in PRESENTATIONS:
                        self.add_page(f"{type_name}: .{word}", context, source, before,
                                      ([arguments] if arguments else []) + closures)
                    index = max(index, after)
                elif word == "buttonStyle":
                    if before in source.loose_styles:
                        name, after = source.loose_styles[before]
                        self.placed.add((source.path, before))
                        items.append(self.leaf(f"{type_name}.{member}", source, before,
                                               source.title(code.rfind("\n", 0, before) + 1, before)))
                    opening = skip_space(code, index, end)
                    if opening < end and code[opening] == "(" and opening in source.match:
                        index = source.match[opening] + 1
                elif following < end and code[following] == "(" and self.view_member("View", word):
                    items.append(self.build_member("View", word, frozenset(), styled))
                continue
            if labelled or word in ("self", "Self"):
                continue
            if word == "if":
                node, index = self.if_chain(context, source, at, end)
                items.append(node)
                continue
            if word == "switch":
                node, index = self.switch(context, source, at, end)
                items.append(node)
                continue
            if at in source.styles:
                node, index = self.styled(context, source, word, at, index, end)
                items.append(node)
                continue
            if word in ("ForEach", "List", "ViewThatFits", "Menu", "NavigationLink", "Tab",
                        "ToolbarItem", "ToolbarItemGroup"):
                node, index = self.container(context, source, word, at, index, end)
                if node is not None:
                    items.append(node)
                continue
            if word in BUTTON_KINDS:
                arguments, _, after = source.call(index, end)
                confirm = word == "Button" and arguments and CONFIRM_ROLE.search(code, *arguments)
                if styled and at not in source.styles:
                    items.append(self.leaf(styled[0], source, at, source.title(at, after), styled[2]))
                elif confirm and at not in source.styles:
                    items.append(self.leaf(f"{type_name}.{member}", source, at, source.title(at, after)))
                continue
            target = self.resolve(word, source)
            if target and target != key and following < end and code[following] in "({<":
                arguments, _, _ = source.call(index, end)
                items.append(self.build_type(target, self.flags_for(target, source, arguments), styled))
                continue
            if word not in KEYWORDS and self.uses_member(key, word, source, at, following, end, local):
                items.append(self.build_member(key, word, flags, styled))
        return Seq(items)

    def styled(self, context, source: Source, word: str, at: int, index: int, end: int):
        """An expression whose own style is filled (or not): its buttons, and where it ends."""
        key, type_name, member, flags, styled = context
        name, dot, after = source.styles[at]
        if name not in FILLED_STYLES:
            # Its own style is not filled: nothing in it is filled by a style set above it.
            inner = (key, type_name, member, flags, None)
            if word in BUTTON_KINDS or word == "Menu":
                return EMPTY, after
            return self.expression(inner, source, word, at, index, dot, None), after
        self.placed.add((source.path, dot))
        style = (f"{type_name}.{member}", source.path, source.line(dot))
        if word in BUTTON_KINDS:
            return self.leaf(style[0], source, at, source.title(at, dot), style[2]), after
        if word == "Menu":
            return self.leaf(style[0], source, at, self.menu_title(source, index, dot), style[2]), after
        return self.expression((key, type_name, member, flags, style), source, word, at, index, dot, style), after

    def expression(self, context, source: Source, word: str, at: int, index: int, dot: int, style):
        """What the expression from `at` to the modifier at `dot` shows, with `style` set on it."""
        key, type_name, member, flags, _ = context
        target = self.resolve(word, source)
        if target and target != key:
            arguments, _, _ = source.call(index, dot)
            own = self.build_type(target, self.flags_for(target, source, arguments), style)
            return Seq([own, self.build_range(context, source, index, dot)])
        if self.view_member(key, word):
            return Seq([self.build_member(key, word, flags, style), self.build_range(context, source, index, dot)])
        return self.build_range(context, source, index, dot)

    def if_chain(self, context, source: Source, at: int, end: int):
        """`if … { } else if … { } else { }`: one branch at a time (or the one a `Bool` picks)."""
        code = source.code
        brace = source.body_brace(at + 2, end)
        if brace is None:
            return EMPTY, at + 2
        condition = code[at + 2:brace]
        closing = source.match[brace]
        then = self.build_range(context, source, brace + 1, closing)
        index = closing + 1
        other = EMPTY
        word = IDENT.match(code, skip_space(code, index, end))
        if word and word.group() == "else":
            following = skip_space(code, word.end(), end)
            nested = IDENT.match(code, following)
            if nested and nested.group() == "if":
                other, index = self.if_chain(context, source, following, end)
            elif following < end and code[following] == "{" and following in source.match:
                other = self.build_range(context, source, following + 1, source.match[following])
                index = source.match[following] + 1
        picked = self.choice(context[3], condition)
        if picked is not None:
            return (then if picked else other), index
        return Alt([then, other]), index

    def switch(self, context, source: Source, at: int, end: int):
        """`switch … { case …: … }`: one case at a time."""
        code = source.code
        brace = source.body_brace(at + 6, end)
        if brace is None:
            return EMPTY, at + 6
        closing = source.match[brace]
        level = source.depth[brace] + 1
        labels = []
        for label in re.finditer(r"\b(?:case|default)\b", code[:closing]):
            if label.start() <= brace or source.depth[label.start()] != level:
                continue
            previous = word_back(code, skip_space_back(code, label.start() - 1))
            if previous and previous[1] in ("if", "guard", "while", "for", "let", "var"):
                continue
            if code[skip_space_back(code, label.start() - 1)] in ",(":
                continue
            index = label.end()
            while index < closing and code[index] != ":":
                if code[index] in "([" and index in source.match:
                    index = source.match[index]
                index += 1
            labels.append((label.start(), index + 1))
        cases = [self.build_range(context, source, labels[number][1],
                                  labels[number + 1][0] if number + 1 < len(labels) else closing)
                 for number in range(len(labels))]
        return Alt(cases or [EMPTY]), closing + 1

    def container(self, context, source: Source, word: str, at: int, index: int, end: int):
        """The SwiftUI views that decide what shows: lists, `ViewThatFits`, menus, links, tabs and
        the toolbar's confirmation."""
        key, type_name, member, flags, styled = context
        code = source.code
        arguments, closures, after = source.call(index, end)
        if arguments is None and not closures:
            return None, index
        if word == "ForEach" or (word == "List" and arguments and closures
                                 and not re.match(r"\s*[A-Za-z_]\w*\s*:", code[arguments[0]:arguments[1]])):
            content = closures[0] if closures else arguments
            once = {button for (owner, button) in SHOWN_ONCE if owner == f"{type_name}.{member}"}
            row = self.build_range(context, source, *content)
            return Many(row, {number for number in row.leaves if self.leaves[number].name in once}), after
        if word == "ViewThatFits" and closures:
            return Alt([self.build_range(context, source, start, stop)
                        for start, stop in self.statements(source, *closures[0])] or [EMPTY]), after
        if word == "Menu":
            # One button (filled by a style set around it); its items are the system's.
            if styled:
                return self.leaf(styled[0], source, at, self.menu_title(source, index, end), styled[2]), after
            return EMPTY, after
        if word == "NavigationLink":
            parts = []
            if arguments and re.search(r"\bdestination\s*:", code[arguments[0]:arguments[1]]):
                self.add_page(f"{type_name}: NavigationLink", context, source, at, [arguments])
                parts = closures
            elif closures:
                self.add_page(f"{type_name}: NavigationLink", context, source, at, closures[:1])
                parts = closures[1:]
            return Seq([self.build_range(context, source, start, stop) for start, stop in parts]), after
        if word == "Tab":
            if closures:
                self.add_page(f"{type_name}: Tab", context, source, at, closures[:1])
            return EMPTY, after
        if word in ("ToolbarItem", "ToolbarItemGroup"):
            if arguments and CONFIRM_PLACEMENT.search(code, *arguments):
                style = (f"{type_name}.{member}", source.path, source.line(at))
                inner = (key, type_name, member, flags, style)
                return Seq([self.build_range(inner, source, start, stop) for start, stop in closures]), after
            return None, index  # read on: its content is part of the page
        return None, index

    def menu_title(self, source: Source, index: int, end: int):
        """A menu's words: in its arguments (`Menu("Mehr")`) or its `label:`, not in its items."""
        arguments, closures, _ = source.call(index, end)
        part = arguments or (closures[-1] if len(closures) > 1 else None)
        return source.title(*part) if part else None

    def statements(self, source: Source, start: int, end: int):
        """The views written one below the other between `start` and `end` (`ViewThatFits`)."""
        code, parts, begin, index = source.code, [], start, start
        while index < end:
            char = code[index]
            if char in "([{" and index in source.match:
                index = source.match[index] + 1
                continue
            if char == "\n":
                following = skip_space(code, index, end)
                previous = skip_space_back(code, index - 1)
                if following < end and code[following] != "." and code[previous] not in ",(+-*/=&|?:" \
                        and code[begin:index].strip():
                    parts.append((begin, index))
                    begin = index
            index += 1
        if code[begin:end].strip():
            parts.append((begin, end))
        return parts

    # Every page.

    def read_pages(self):
        """Every view is a page; so is every view a non-view shows (`AppScreen.destination`, the
        screens pushed by value, as they are given), and every sheet or destination found on the way."""
        for key, info in sorted(self.types.items()):
            flags = frozenset(info.bools.items())
            if info.is_view and "body" in info.members:
                source, offset = next(((source, offset) for source, offset in info.declarations
                                       if source.path == info.members["body"][0][0].path), info.declarations[0])
                page = Page(info.name, source.path, source.line(offset), True)
                self.pages[("type", key)] = page
                page.node = self.build_type(key, flags, None)
                continue
            for name, bodies in sorted(info.members.items()):
                source, start, _ = bodies[0]
                page = Page(f"{info.name}.{name}", source.path, source.line(start), False)
                self.pages[("member", key, name)] = page
                page.node = self.build_member(key, name, flags, None)
        while self.pending:
            key, context, source, ranges = self.pending.pop(0)
            self.pages[key].node = Seq([self.build_range(context, source, start, stop) for start, stop in ranges])

    def together(self):
        """(page, first, second) for each two filled buttons (or one in every row) that can show at
        once, at the smallest page that shows them both."""
        smallest = {}
        for page in self.pages.values():
            for found in page.node.pairs:
                writes = any(self.leaves[number].name.split(".")[0] == page.label for number in found)
                rank = (len(page.node.leaves), not writes, not page.is_view, page.path, page.line)
                if found not in smallest or rank < smallest[found][0]:
                    smallest[found] = (rank, page)
        return sorted(((page, self.leaves[a], self.leaves[b]) for (a, b), (_, page) in smallest.items()),
                      key=lambda item: (item[0].path, item[0].line, item[1].path, item[1].line,
                                        item[2].path, item[2].line))


# MARK: - The rule

def app_sources(root) -> dict:
    base = pathlib.Path(root)
    return {path.relative_to(base).as_posix(): path.read_text(encoding="utf-8")
            for path in sorted((base / APP).rglob("*.swift"))}


def entry_offenders(app: App, root):
    """(file, line, advice) for each entry of `TAKE_TURNS` and `SHOWN_ONCE` whose buttons the app no
    longer shows where the entry says, or whose code is gone."""
    this = ".github/scripts/filled_button_rule.py"
    found = []
    shown = {}
    for page in app.pages.values():
        shown.setdefault(page.label, set()).update(app.leaves[number].name for number in page.node.leaves)
    entries = [(f"TAKE_TURNS[{page!r}]", page, names, witnesses)
               for page, groups in TAKE_TURNS.items() for names, _, witnesses in groups]
    for (owner, button), (_, witnesses) in SHOWN_ONCE.items():
        view, _, member = owner.partition(".")
        key = app.resolve(view, app.sources[0]) if app.sources else None
        names = set()
        if key:
            names = {app.leaves[number].name for number in app.build_member(key, member, frozenset(), None).leaves}
        shown[owner] = names
        entries.append((f"SHOWN_ONCE[{owner!r}]", owner, {button}, witnesses))
    codes = {}
    for entry, page, names, witnesses in entries:
        for button in sorted(names - shown.get(page, set())):
            found.append((this, 1, GONE.format(entry=entry, button=button, page=page)))
        for path, pattern in witnesses:
            if path not in codes:
                file = pathlib.Path(root) / path
                codes[path] = release_code(code_only(file.read_text(encoding="utf-8"))) if file.exists() else ""
            if not re.search(pattern, codes[path]):
                found.append((this, 1, NO_WITNESS.format(entry=entry, pattern=pattern, path=path)))
    return found


def offenders_in(sources: dict, app: App | None = None):
    """(file, line, advice) for each page of the Swift `sources` (path → text) that can show two
    filled buttons at once, each button style the rule does not know, and each filled button it
    cannot place on a page."""
    app = app or App(sources)
    found = []
    for page, first, second in app.together():
        if first is second:
            found.append((page.path, page.line, REPEATED.format(page=page.label, first=first)))
        else:
            found.append((page.path, page.line, TOGETHER.format(page=page.label, first=first, second=second)))
    for source in app.sources:
        for offset, style in source.unknown_styles:
            found.append((source.path, source.line(offset), UNKNOWN_STYLE.format(style=style)))
        for offset in source.filled_styles:
            if (source.path, offset) not in app.placed:
                button = f"{source.path}:{source.line(offset)}"
                found.append((source.path, source.line(offset), UNPLACED.format(button=button)))
    for path, line, name in app.button_styles:
        if name not in FILLED_STYLES and name not in NOT_FILLED:
            found.append((path, line, UNKNOWN_STYLE.format(style=name)))
    return sorted(set(found))


def offenders(root):
    """(file, line, advice) for every finding in App/Albumist and every entry that no longer holds."""
    sources = app_sources(root)
    app = App(sources)
    return sorted(set(offenders_in(sources, app) + entry_offenders(app, root)))


def main(argv) -> int:
    root = argv[1] if len(argv) > 1 else "."
    found = offenders(root)
    for file, line, advice in found:
        print(f"::error file={file},line={line}::{advice}")
    print(f"FILLED_BUTTON_RULE {len(found)} offenders")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
