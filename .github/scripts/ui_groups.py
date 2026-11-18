"""The UI test groups, which test files each group depends on, and the fingerprints of the app and
of each group's test code (the owner's rule of 17.11.: a test-only change with a provably
identical app reruns only the groups it touches).

  python3 .github/scripts/ui_groups.py fingerprints [--commit C]
      {"app": ..., "groups": {group: ...}} as JSON (sha256, hex).
  python3 .github/scripts/ui_groups.py map [--commit C]
      Every file of the UI test target and the groups that depend on it.
  python3 .github/scripts/ui_groups.py affected --base B [--head H]
      The groups a change from B to H has to run again, and why: every group when the app
      changed, otherwise the groups whose test fingerprint changed.

The groups are defined in .github/ui-groups.json (only / skip as ui.yml hands them to
xcodebuild). Nothing here lists test names: the tests, the classes and which file uses which
are read from the Swift files of App/SortlyUITests at that commit, so a renamed, added or
removed test is followed automatically.

App fingerprint: sha256 over the path and git blob id of every tracked file that can go into
the app or decide how it is built. That is every file EXCEPT the UI tests (App/SortlyUITests),
the unit tests (App/SortlyTests, Tests), docs/, any *.md, .github/ (but .github/toolchain.json,
the pinned Xcode and simulator runtime, counts), scripts/, tools/ and design/. It is made as an
exclusion list on purpose: a new folder counts as app until someone says otherwise, so an
unknown file can only cause a run too many, never a run too few. Same blobs means the same
bytes, so equal fingerprints mean an identical app (Sortly/**, Sources/**, Package.swift and
Package.resolved, project.yml with its build settings, resources, the StoreKit file, the
toolchain).

Test fingerprint of a group: sha256 over the group's own definition (fields of ui-groups.json
without the "_" comments), the files that hold its tests, every file those use (transitively:
a Swift file uses another when it names a type, function or extension member that file declares
for the others; private declarations are not seen from outside), every file of App/SortlyUITests
that is not Swift (Info.plist and the like) or declares an XCTestObservation, and the harness all
groups run through (ui_tests.py, pick_simulator.py, toolchain.py). So a change to a shared helper
(UITestOnboarding.swift) changes the fingerprint of every group whose tests use it, and only of
those; ui.yml itself is not part of it (how a group is started lives in the files above).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
GROUPS_FILE = ".github/ui-groups.json"
UI_DIR = "App/SortlyUITests/"
HARNESS = (".github/scripts/ui_tests.py", ".github/scripts/pick_simulator.py", ".github/scripts/toolchain.py",
           # How the groups are built, started and named: a branch that changes them gets other
           # fingerprints, so its results never count for an unchanged ui.yml (and the reverse).
           ".github/workflows/ui.yml", ".github/workflows/testflight.yml")
NOT_APP_PREFIXES = ("App/SortlyUITests/", "App/SortlyTests/", "Tests/", "docs/", ".github/", "scripts/", "tools/",
                    "design/")
APP_EXCEPTIONS = (".github/toolchain.json",)
SHORT = 12  # hex digits in job names (48 bits)
GROUP_NAME = re.compile(r"[a-z0-9-]+")  # as ui_evidence.JOB_NAME reads it from a job name
# Environment switch of the UI tests for a quick run per change (SORTLY_UI_QUICK=1, handed to the
# tests as TEST_RUNNER_SORTLY_UI_QUICK): a group whose files read it has another test fingerprint
# in a quick run, so a quick result never stands in for a full one (the upload needs full ones).
QUICK_SWITCH = "SORTLY_UI_QUICK"


# ---------------------------------------------------------------------------------------------
# Trees: the files of one commit (git) or of a test


class GitTree:
    """The tracked files of one commit: {path: blob id} and their text."""

    def __init__(self, commit: str = "HEAD", cwd: str = ROOT):
        self.commit, self.cwd = commit, cwd
        out = subprocess.run(["git", "ls-tree", "-r", "-z", "--full-tree", commit], cwd=cwd, capture_output=True)
        if out.returncode != 0:
            raise ValueError(f"no commit {commit}: {out.stderr.decode(errors='replace').strip()}")
        self._files = {}
        for entry in out.stdout.decode("utf-8", errors="surrogateescape").split("\0"):
            if not entry:
                continue
            meta, path = entry.split("\t", 1)
            mode, kind, blob = meta.split()
            if kind == "blob":
                self._files[path] = blob
            elif kind == "commit":  # a submodule: its commit id stands for its content
                self._files[path] = blob

    def files(self) -> dict[str, str]:
        return self._files

    def read(self, path: str) -> str | None:
        blob = self._files.get(path)
        if blob is None:
            return None
        out = subprocess.run(["git", "cat-file", "blob", blob], cwd=self.cwd, capture_output=True)
        return out.stdout.decode("utf-8", errors="replace") if out.returncode == 0 else None


class DictTree:
    """{path: text} for the tests; blob ids as git makes them."""

    def __init__(self, contents: dict[str, str]):
        self.contents = contents

    def files(self) -> dict[str, str]:
        result = {}
        for path, text in self.contents.items():
            data = text.encode()
            result[path] = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
        return result

    def read(self, path: str) -> str | None:
        return self.contents.get(path)


# ---------------------------------------------------------------------------------------------
# The app


def is_app(path: str) -> bool:
    if path in APP_EXCEPTIONS:
        return True
    if path.endswith(".md") and "/" not in path:
        return False  # README.md, STATUS.md, ... at the top; a .md deeper down may be a resource
    return not path.startswith(NOT_APP_PREFIXES)


def _digest(lines) -> str:
    h = hashlib.sha256()
    for line in lines:
        h.update(line.encode("utf-8", errors="surrogateescape"))
        h.update(b"\n")
    return h.hexdigest()


def app_fingerprint(tree) -> str:
    files = tree.files()
    return _digest(f"{path}\0{files[path]}" for path in sorted(files) if is_app(path))


def app_files(tree) -> list[str]:
    return sorted(p for p in tree.files() if is_app(p))


# ---------------------------------------------------------------------------------------------
# Swift: tests, declarations and uses (good enough for well-formed test code; when in doubt it
# sees a use too many, which only makes a group run once more)

KINDS = {"class", "struct", "enum", "protocol", "actor", "extension", "func", "var", "let", "typealias"}
TYPE_KINDS = {"class", "struct", "enum", "protocol", "actor", "extension"}
MODIFIERS = {"public", "private", "fileprivate", "internal", "open", "final", "static", "override", "mutating",
             "nonmutating", "nonisolated", "required", "convenience", "lazy", "weak", "unowned", "dynamic",
             "indirect", "isolated", "consuming", "borrowing", "package", "optional", "prefix", "postfix", "infix"}
WORD = re.compile(r"@?[A-Za-z_]\w*")
TEST_FUNC = re.compile(r"\bfunc\s+(test\w*)\s*\(\s*\)")
PARENS = re.compile(r"\([^()]*\)")


def strip_swift(source: str) -> str:
    """The source with comments and the text of string literals blanked out (newlines kept), so
    braces and names in them do not count. The code inside an interpolation "\\(...)" is kept:
    a helper used only there is still a use. One pass, character by character."""
    out, i, n = [], 0, len(source)
    # Frames: ("code", paren depth or None at the top) and ("string", closing delimiter, hashes, multi-line).
    stack: list[tuple] = [("code", None)]

    def blank(text: str) -> str:
        return "".join(ch if ch == "\n" else " " for ch in text)

    while i < n:
        frame = stack[-1]
        c = source[i]
        if frame[0] == "code":
            if source.startswith("//", i):
                j = source.find("\n", i)
                j = n if j < 0 else j
                out.append(" " * (j - i))
                i = j
            elif source.startswith("/*", i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if source.startswith("/*", j):
                        depth, j = depth + 1, j + 2
                    elif source.startswith("*/", j):
                        depth, j = depth - 1, j + 2
                    else:
                        j += 1
                out.append(blank(source[i:j]))
                i = j
            elif c == '"' or (c == "#" and source[i:].lstrip("#").startswith('"')):
                hashes = 0
                while source[i + hashes] == "#":
                    hashes += 1
                multi = source.startswith('"""', i + hashes)
                opening = hashes + (3 if multi else 1)
                out.append('"' + " " * (opening - 1))
                stack.append(("string", ('"""' if multi else '"') + "#" * hashes, hashes, multi))
                i += opening
            else:
                if frame[1] is not None and c == "(":
                    stack[-1] = ("code", frame[1] + 1)
                elif frame[1] is not None and c == ")":
                    if frame[1] == 1:
                        stack.pop()  # back into the string
                    else:
                        stack[-1] = ("code", frame[1] - 1)
                out.append(c)
                i += 1
        else:
            _, close, hashes, multi = frame
            escape = "\\" + "#" * hashes
            if source.startswith(escape + "(", i):
                out.append(" " * len(escape) + "(")
                stack.append(("code", 1))
                i += len(escape) + 1
            elif source.startswith(escape, i) and i + len(escape) < n:
                out.append(blank(source[i:i + len(escape) + 1]))
                i += len(escape) + 1
            elif source.startswith(close, i):
                out.append(" " * (len(close) - 1) + '"')
                stack.pop()
                i += len(close)
            elif c == "\n" and not multi:
                stack.pop()  # an unterminated string ends at the line
                out.append(c)
                i += 1
            else:
                out.append(blank(c))
                i += 1
    return "".join(out)


class SwiftFile:
    """What one Swift file declares and uses."""

    def __init__(self, path: str, source: str):
        self.path = path
        self.classes: dict[str, list[str]] = {}   # top-level class -> inherited names
        self.methods: dict[str, list[str]] = {}   # class or extended type -> test methods declared here
        self.exported: set[str] = set()            # names other files can use
        text = strip_swift(source)
        self.words = set(WORD.findall(text))
        # Reads the quick switch (a string, so in the raw source): its group's result depends on the mode.
        self.quick_switch = QUICK_SWITCH in source
        self.observer = "XCTestObservation" in self.words
        self._parse(text)

    @staticmethod
    def _declaration(line: str):
        """(kind, name, private, inherits) of a declaration that starts this line, or None."""
        words = WORD.findall(PARENS.sub(" ", line))
        for i, word in enumerate(words):
            if word.startswith("@"):
                continue
            nxt = words[i + 1] if i + 1 < len(words) else ""
            if word == "class" and nxt in {"func", "var", "let"} | MODIFIERS:
                continue  # "class func": a modifier here
            if word in KINDS:
                if not nxt or nxt.startswith("@"):
                    return None
                private = any(w in ("private", "fileprivate") for w in words[:i])
                return word, nxt, private, SwiftFile._inherits(line) if word in TYPE_KINDS else []
            if word not in MODIFIERS:
                return None
        return None

    @staticmethod
    def _inherits(header: str) -> list[str]:
        """The names after ":" of a type declaration up to its "{" or "where"."""
        if ":" not in header:
            return []
        return WORD.findall(header.split(":", 1)[1].split("{", 1)[0].split(" where ")[0])

    def _parse(self, text: str) -> None:
        stack: list[tuple | None] = []  # one entry per open brace: the top-level declaration it opens, or None
        pending = None                  # a top-level declaration whose "{" has not come yet
        header = None                   # (class name, text) of a class declaration spread over lines
        for line in text.split("\n"):
            if header and not stack:
                header = (header[0], header[1] + " " + line)
                if "{" in line:
                    self.classes[header[0]] = self._inherits(header[1])
                    header = None
            found = self._declaration(line)
            if found and not stack:
                kind, name, private, inherits = found
                if kind == "class":
                    self.classes[name] = inherits
                    if "{" not in line:
                        header = (name, line)
                if kind != "extension" and not private:
                    self.exported.add(name)
                pending = (kind, name, private)
            elif found and len(stack) == 1 and stack[0]:
                kind, name, private, _ = found
                container_kind, container, container_private = stack[0]
                if container_kind == "extension" and not container_private and not private:
                    self.exported.add(name)  # an extension member, used without naming its file's types
                if container_kind in ("class", "extension") and kind == "func" and not private:
                    test = TEST_FUNC.search(line)
                    if test:
                        self.methods.setdefault(container, []).append(test.group(1))
            for ch in line:
                if ch == "{":
                    stack.append(pending if not stack else None)
                    pending = None
                elif ch == "}" and stack:
                    stack.pop()


def ui_files(tree) -> dict[str, SwiftFile]:
    files = {}
    for path in sorted(tree.files()):
        if path.startswith(UI_DIR) and path.endswith(".swift"):
            files[path] = SwiftFile(path, tree.read(path) or "")
    return files


def test_classes(files: dict[str, SwiftFile]) -> set[str]:
    """Classes that derive from XCTestCase, also through another class of the target."""
    bases = {}
    for f in files.values():
        bases.update(f.classes)
    found = set()
    changed = True
    while changed:
        changed = False
        for name, inherits in bases.items():
            if name not in found and ("XCTestCase" in inherits or found & set(inherits)):
                found.add(name)
                changed = True
    return found


def all_tests(files: dict[str, SwiftFile]) -> dict[str, set[str]]:
    """{"Class/testMethod": {files that declare it (inherited tests: the base class's file too)}}."""
    classes = test_classes(files)
    bases = {}
    for f in files.values():
        bases.update(f.classes)
    own: dict[str, dict[str, set[str]]] = {}
    for f in files.values():
        for cls, methods in f.methods.items():
            for m in methods:
                own.setdefault(cls, {}).setdefault(m, set()).add(f.path)
    tests: dict[str, set[str]] = {}
    for cls in classes:
        lineage, seen = [cls], set()
        while lineage:
            current = lineage.pop()
            if current in seen:
                continue
            seen.add(current)
            for m, paths in own.get(current, {}).items():
                tests.setdefault(f"{cls}/{m}", set()).update(paths)
            lineage += [b for b in bases.get(current, []) if b in classes]
    return tests


def selected(test: str, only: list[str], skip: list[str]) -> bool:
    """Whether xcodebuild runs `test` with -only-testing `only` and -skip-testing `skip`."""
    def hits(entries):
        return any(test == e or test.startswith(e + "/") for e in entries)
    return (not only or hits(only)) and not hits(skip)


def uses(files: dict[str, SwiftFile]) -> dict[str, set[str]]:
    """{file: files it uses directly}."""
    result = {}
    for path, f in files.items():
        result[path] = {other for other, g in files.items() if other != path and g.exported & f.words}
    return result


def closure(start: set[str], graph: dict[str, set[str]]) -> set[str]:
    seen, todo = set(), list(start)
    while todo:
        path = todo.pop()
        if path in seen:
            continue
        seen.add(path)
        todo += graph.get(path, ())
    return seen


# ---------------------------------------------------------------------------------------------
# Groups


def load_groups(tree) -> list[dict] | None:
    text = tree.read(GROUPS_FILE)
    if text is None:
        return None
    try:
        groups = json.loads(text)["groups"]
    except (ValueError, KeyError, TypeError) as error:
        raise ValueError(f"{GROUPS_FILE} is not readable: {error}") from error
    if not isinstance(groups, list) or not all(isinstance(g, dict) and g.get("group") for g in groups):
        raise ValueError(f"{GROUPS_FILE}: every group needs a name")
    for g in groups:
        if not GROUP_NAME.fullmatch(str(g["group"])):
            raise ValueError(f"{GROUPS_FILE}: group name {g['group']!r} must be lower-case letters, digits and '-'")
    if len({g["group"] for g in groups}) != len(groups):
        raise ValueError(f"{GROUPS_FILE}: a group name appears twice")
    return groups


def definition(group: dict) -> dict:
    return {k: v for k, v in group.items() if not k.startswith("_")}


class Groups:
    """The groups of one tree, their tests, files and fingerprints."""

    def __init__(self, tree):
        self.tree = tree
        self.groups = load_groups(tree)
        if self.groups is None:
            raise ValueError(f"{GROUPS_FILE} is missing")
        self.files = ui_files(tree)
        self.tests = all_tests(self.files)
        self.graph = uses(self.files)
        blobs = tree.files()
        shared = ({p for p in blobs if p.startswith(UI_DIR) and not p.endswith(".swift")}
                  | {p for p, f in self.files.items() if f.observer}
                  | {p for p in HARNESS if p in blobs})
        # Fails closed: a Swift file of the target that no group's tests reach (a helper whose use
        # this reader missed, a test class it could not see) counts for every group.
        reached = set()
        for g in self.groups:
            reached |= closure(self.own_files(g["group"]), self.graph)
        self.uncovered = sorted(p for p in self.files if p not in reached and p not in shared)
        self.shared = sorted(closure(shared | set(self.uncovered), self.graph) | shared)
        empty = [g["group"] for g in self.groups if not self.selected_tests(g["group"])]
        if empty:
            raise ValueError(f"group(s) {', '.join(empty)} of {GROUPS_FILE} select no UI test "
                             "(renamed or moved tests? see ui_groups.py map)")

    def names(self) -> list[str]:
        return [g["group"] for g in self.groups]

    def group(self, name: str) -> dict:
        return next(g for g in self.groups if g["group"] == name)

    def selected_tests(self, name: str) -> list[str]:
        g = self.group(name)
        only, skip = g.get("only", "").split(), g.get("skip", "").split()
        return sorted(t for t in self.tests if selected(t, only, skip))

    def own_files(self, name: str) -> set[str]:
        return {p for t in self.selected_tests(name) for p in self.tests[t]}

    def files_of(self, name: str) -> list[str]:
        """Every file the group's result depends on, besides the app."""
        return sorted(closure(self.own_files(name), self.graph) | set(self.shared))

    def reads_quick(self, name: str) -> bool:
        """Whether a file of the group reads the quick switch (SORTLY_UI_QUICK)."""
        return any(self.files[p].quick_switch for p in self.files_of(name) if p in self.files)

    def fingerprint(self, name: str, quick: bool = False) -> str:
        """The group's test fingerprint; in a quick run another one when its tests read the switch."""
        blobs = self.tree.files()
        lines = [json.dumps(definition(self.group(name)), sort_keys=True)]
        lines += [f"{p}\0{blobs[p]}" for p in self.files_of(name)]
        if quick and self.reads_quick(name):
            lines.append(f"mode quick ({QUICK_SWITCH}=1)")
        return _digest(lines)

    def fingerprints(self, quick: bool = False) -> dict[str, str]:
        return {name: self.fingerprint(name, quick) for name in self.names()}

    def file_map(self) -> dict[str, list[str]]:
        """{file of the UI test target or harness: [groups that depend on it]}."""
        result: dict[str, list[str]] = {}
        for name in self.names():
            for path in self.files_of(name):
                result.setdefault(path, []).append(name)
        for path in self.tree.files():
            if path.startswith(UI_DIR):
                result.setdefault(path, [])
        return dict(sorted(result.items()))

    def matrix_entry(self, name: str, app: str, quick: bool = False) -> dict:
        """One entry of ui.yml's job matrix: the group's fields and both short fingerprints (they
        go into the job name, where ui_evidence.py finds them again)."""
        g = definition(self.group(name))
        entry = {k: g.get(k, "") for k in ("group", "title", "device", "only", "skip")}
        for flag in ("video", "reduce_motion", "increase_contrast"):
            entry[flag] = bool(g.get(flag, False))
        quick = quick and self.reads_quick(name)
        if quick:
            entry["title"] += " (quick)"
        entry["quick"] = quick
        entry["app"] = app[:SHORT]
        entry["tests"] = self.fingerprint(name, quick)[:SHORT]
        return entry


def fingerprints(tree) -> dict:
    return {"app": app_fingerprint(tree), "groups": Groups(tree).fingerprints()}


def changed_files(base: str, head: str, cwd: str = ROOT) -> list[str]:
    out = subprocess.run(["git", "diff", "--name-only", "--no-renames", base, head], cwd=cwd,
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise ValueError(f"git diff {base} {head} failed: {out.stderr.strip()}")
    return [f for f in out.stdout.splitlines() if f]


def affected(base_tree, head_tree, changed: list[str]) -> tuple[list[str], dict[str, list[str]]]:
    """(groups to run again, {group: why}) for a change from base_tree to head_tree."""
    head = Groups(head_tree)
    app_changes = [p for p in changed if is_app(p)]
    if app_fingerprint(base_tree) != app_fingerprint(head_tree):
        why = "app changed: " + ", ".join(app_changes[:8]) + (" ..." if len(app_changes) > 8 else "")
        return head.names(), {name: [why] for name in head.names()}
    try:
        base = Groups(base_tree)
    except ValueError:
        base = None
    run, reasons = [], {}
    for name in head.names():
        if base is None or name not in base.names():
            run.append(name)
            reasons[name] = ["new group (or no group file at the base)"]
            continue
        if base.fingerprint(name) == head.fingerprint(name):
            continue
        files = set(head.files_of(name)) | set(base.files_of(name))
        why = [p for p in changed if p in files]
        if definition(base.group(name)) != definition(head.group(name)):
            why.append(f"its definition in {GROUPS_FILE}")
        run.append(name)
        reasons[name] = why or ["its set of files changed"]
    return run, reasons


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    f = sub.add_parser("fingerprints")
    f.add_argument("--commit", default="HEAD")
    m = sub.add_parser("map")
    m.add_argument("--commit", default="HEAD")
    a = sub.add_parser("affected")
    a.add_argument("--base", required=True)
    a.add_argument("--head", default="HEAD")
    args = parser.parse_args(argv)
    if args.command == "fingerprints":
        print(json.dumps(fingerprints(GitTree(args.commit)), indent=1))
    elif args.command == "map":
        groups = Groups(GitTree(args.commit))
        for path, names in groups.file_map().items():
            print(f"{path}: {' '.join(names) or '(no group)'}")
        for name in groups.names():
            print(f"group {name}: {len(groups.selected_tests(name))} tests, files {' '.join(groups.files_of(name))}")
    else:
        run, reasons = affected(GitTree(args.base), GitTree(args.head), changed_files(args.base, args.head))
        if not run:
            print("no UI group needs to run again (same app, same test code)")
        for name in run:
            print(f"{name}: {'; '.join(reasons[name])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
