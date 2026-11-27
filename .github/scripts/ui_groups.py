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
are read from the Swift files of App/AlbumistUITests at that commit, so a renamed, added or
removed test is followed automatically.

App fingerprint: sha256 over the path and git blob id of every tracked file that can go into
the app or decide how it is built. That is every file EXCEPT the UI tests (App/AlbumistUITests),
the unit tests (App/AlbumistTests, Tests), docs/, top-level *.md, .github/ (but .github/toolchain.json,
the pinned Xcode and simulator runtime, counts), scripts/, tools/ and design/. It is made as an
exclusion list on purpose: a new folder counts as app until someone says otherwise, so an
unknown file can only cause a run too many, never a run too few. Same blobs means the same
bytes, so equal fingerprints mean an identical app (Albumist/**, Sources/**, Package.swift and
Package.resolved, project.yml with its build settings, resources, the StoreKit file, the
toolchain).

Test fingerprint of a group: sha256 over the group's own definition (fields of ui-groups.json
without the "_" comments), the files that hold its tests, every file those use (transitively:
a Swift file uses another when it names a type, function or extension member that file declares
for the others; private declarations are not seen from outside), every file of App/AlbumistUITests
that is not Swift (Info.plist and the like) or declares an XCTestObservation, every Swift file of
the target that no group's tests reach (fails closed), and the harness: the UI workflows
(ui.yml, ui-stress.yml) and every script and .github/ file they name or import, transitively
(harness_files; every file under .github/ when unsure, ui-groups.json never: each group's own
definition counts). A Swift file of the target goes in by
its code (swift_code: comments left out, whitespace outside literals reduced to "line break or
not", literals byte for byte), so editing a comment or the indentation of a test leaves its
fingerprint, and a red result under it stays red (Prüfer B G5-04, 18.11.); a Swift file the reader
cannot read for sure, and every other file, by its git blob id. In a quick run (ALBUMIST_UI_QUICK=1) a
line "mode quick" is added for every group. So a change to a shared helper
(UITestOnboarding.swift) changes the fingerprint of every group whose tests use it, and only of
those; a change to the harness changes every group's, a change to another workflow or script
(testflight.yml, ci_gate.py) none.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import posixpath
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
GROUPS_FILE = ".github/ui-groups.json"
UI_DIR = "App/AlbumistUITests/"
# The harness: what builds, starts, names or judges the groups. It starts at the two workflows
# that run UI tests (HARNESS_ROOTS) and takes every file under .github/ they name (scripts,
# workflows, local actions, data), then every file those name or import in their code (not in a
# comment or docstring), and so on (harness_files). So the UI runner, its helpers, the matrix
# generator and the evidence reader count, and a change to a workflow or script no UI job runs
# (testflight.yml, ci.yml, ci_gate.py, ...) leaves every group's green standing (review P5-08
# (c): any script change made every green result worthless, and a fix to the pipeline cost a
# full UI run). It fails safe, toward "harness changed" (every file under .github/ counts):
#   - a root that is missing, a script that does not parse, roots that do not reach the runner;
#   - a name it cannot resolve: a .github/ path that is no file and no folder, a script or
#     module built from a variable ("${TOOL}.py", import_module(name), ["-m", name]).
#   - a script a Python script starts with the interpreter ([sys.executable, script]) when
#     `script` holds no script name the reader can see.
#   - code it cannot see (third review of C6): a shell command built at run time (shell=True,
#     os.system, os.popen, subprocess.getoutput, bash -c, python -c, a shell script from a
#     variable), exec, eval and compile, and a folder of .github/ that a script lists (glob,
#     listdir, scandir, walk, Path.glob/rglob/iterdir; also a walk of the whole repository, or
#     a folder built from __file__ the reader cannot follow). A folder outside .github/ or one
#     handed in from outside (an argument, the environment) is not the harness's.
# What it resolves (second review of C6): a .github/ path anywhere in a line (also after
# $GITHUB_WORKSPACE/ or ${{ github.workspace }}/); in a workflow or shell script a folder
# (working-directory, uses: ./.github/actions/x: every file in it); a file name with any
# extension ("other.py", "pins.csv", os.path.join parts such as "toolchain.json": every file of
# that name under .github/, but no workflow: a bare "testflight.yml" is the API's name for the workflow,
# and a workflow runs only when GitHub runs it, which needs its path); "python3 -m x", imports
# and importlib.import_module("x"). One file too many is harmless; one too few is not. A folder
# named in a Python string is data the script reads (ui_groups.py reads them all to fingerprint
# them); what a script runs goes through the ways above.
# Not harness: the scripts' own unit tests (they never run in a UI job) and ui-groups.json
# (GROUPS_FILE): each group's own definition is in its fingerprint, so an edit to another
# group, a budget or a comment runs no group again.
HARNESS_ROOTS = (".github/workflows/ui.yml", ".github/workflows/ui-stress.yml")
HARNESS_RUNNER = ".github/scripts/ui_tests.py"
HARNESS_PREFIX = ".github/"
HARNESS_EXCLUDED = (".github/scripts/tests/",)
SCRIPTS_DIR = ".github/scripts/"
WORKFLOWS_DIR = ".github/workflows/"
NAMED_PATH = re.compile(r"\.github/[A-Za-z0-9_.+/-]*")
# A .github/ path or a script name with a variable in it: cannot be resolved.
VARIABLE_NAME = re.compile(r"\.github/[A-Za-z0-9_.+/-]*[$%{]|[}$][A-Za-z0-9_-]*\.py\b")
# A file name with any extension ("pins.csv", "Info.plist"): a name that is no file under .github/
# ("os.path", "github.token") resolves to nothing and is harmless (third review of C6: data files
# with other extensions were left out).
NAMED_FILE = re.compile(r"(?<![A-Za-z0-9_.+-])([A-Za-z0-9_+-][A-Za-z0-9_.+-]*\.[A-Za-z][A-Za-z0-9]*)\b")
DASH_M = re.compile(r"\bpython3?(?:\s+-[A-Za-z]+)*\s+-m\s+([A-Za-z_][\w.]*)")
DYNAMIC_CALLS = {"import_module", "__import__", "run_module", "run_path", "spec_from_file_location"}
RUN_CALLS = {"run", "Popen", "call", "check_call", "check_output", "system", "execv", "execvp", "spawnv"}
INTERPRETER = re.compile(r"(?:.*/)?python[0-9.]*$")
# Third review of C6: what runs code the reader cannot see counts everything when it is built at
# run time: a shell string (shell=True, os.system and the like, bash -c, python -c), exec, eval
# and compile (always: their code is a string the reader does not parse), and a folder of .github/
# that is listed (glob, listdir, walk: the files are picked at run time).
SHELL_CALLS = {"system", "popen", "getoutput", "getstatusoutput"}
CODE_CALLS = {"exec", "eval", "compile"}
LIST_CALLS = {"glob", "iglob", "listdir", "scandir", "walk", "fwalk", "iterdir", "rglob"}
# Calls that go down into every folder below, also hidden ones such as .github (glob.glob skips
# hidden folders unless include_hidden; pathlib does not).
RECURSIVE_CALLS = {"walk", "fwalk", "rglob"}
LIST_MODULES = {"glob", "os", "pathlib", "posixpath"}
SHELL = re.compile(r"(?:.*/)?(?:ba|z|da|k)?sh$")
ENV = re.compile(r"(?:.*/)?env$")
# Where a path computed from __file__ lands, for listing calls: the repository as REPO, scripts
# run from its root (the workflows' working directory).
REPO = "/repository"
WILDCARD = re.compile(r"[*?\[]")


def _is_text(node) -> bool:
    return isinstance(node, ast.Constant) and isinstance(node.value, str)


def _path_of(node, values: dict, script: str, depth: int = 0) -> str | None:
    """The path an expression stands for, as far as the reader can follow it (constants,
    __file__, names given once, os.path.join/dirname/abspath, pathlib's Path, / and .parent,
    f-strings and +); None when it cannot."""
    if depth > 12 or node is None:
        return None
    again = lambda n: _path_of(n, values, script, depth + 1)  # noqa: E731
    if _is_text(node):
        return node.value
    if isinstance(node, ast.Name):
        if node.id == "__file__":
            return f"{REPO}/{script}"
        return again(values.get(node.id))
    if isinstance(node, ast.JoinedStr):
        parts = [again(v.value) if isinstance(v, ast.FormattedValue) else again(v) for v in node.values]
        return None if None in parts else "".join(parts)
    if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Add, ast.Div)):
        left, right = again(node.left), again(node.right)
        if left is None or right is None:
            return None
        return left + right if isinstance(node.op, ast.Add) else posixpath.join(left, right)
    if isinstance(node, ast.Attribute) and node.attr == "parent":
        inner = again(node.value)
        return None if inner is None else posixpath.dirname(posixpath.normpath(inner))
    if isinstance(node, ast.Call):
        func = node.func
        called = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", "")
        args = [again(a) for a in node.args]
        if None in args:
            return None
        if called in ("join", "Path", "PurePath", "PosixPath") and args:
            return posixpath.join(*args)
        if called == "dirname" and len(args) == 1:
            return posixpath.dirname(posixpath.normpath(args[0]))
        if called in ("abspath", "realpath", "normpath") and len(args) == 1:
            return posixpath.normpath(args[0])
        if called in ("resolve", "absolute") and not args and isinstance(func, ast.Attribute):
            return again(func.value)
    return None


def _from_location(node, values: dict, depth: int = 0) -> bool:
    """Whether an expression is built from __file__ or a .github/ string, also through the names
    it uses: a folder the reader could not follow that may well be one of .github/."""
    if depth > 12 or node is None:
        return False
    for part in ast.walk(node):
        if isinstance(part, ast.Name):
            if part.id == "__file__" or _from_location(values.get(part.id), values, depth + 1):
                return True
        elif _is_text(part) and ".github" in part.value:
            return True
    return False


def _lists_harness(node: ast.Call, called: str, values: dict, script: str) -> str:
    """Why a listing call (glob, listdir, walk, Path.iterdir ...) may pick files of .github/ at run
    time, "" when it does not (a folder outside .github/, or one handed in from outside)."""
    func = node.func
    module_call = isinstance(func, ast.Name) or (isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name)
                                                 and func.value.id in LIST_MODULES)
    if module_call:
        target = node.args[0] if node.args else ast.Constant(".")
        pattern_of_path = called in ("glob", "iglob")
    else:  # Path(...).glob(pattern), .rglob(pattern), .iterdir()
        target = func.value
        if node.args:
            target = ast.BinOp(left=func.value, op=ast.Div(), right=node.args[0])
        pattern_of_path = True
    path = _path_of(target, values, script)
    if path is None:
        return f"{called}() of a folder built from the script's place" if _from_location(target, values) else ""
    path = posixpath.normpath(posixpath.join(REPO, path))
    literal = WILDCARD.split(path, 1)[0] if pattern_of_path else path
    literal = literal.rstrip("/") or "/"
    if "/.github" in path[len(REPO):] or (literal + "/").startswith(f"{REPO}/.github/"):
        return f"{called}() of a folder of .github/"
    hidden = not module_call or any(k.arg == "include_hidden" for k in node.keywords)
    recursive = called in RECURSIVE_CALLS or (pattern_of_path and "**" in path and hidden)
    if recursive and (REPO + "/").startswith(literal.rstrip("/") + "/"):
        return f"{called}() of the whole repository, .github/ included"
    return ""


def _runs_hidden_code(node: ast.Call, called: str, values: dict, script: str) -> str:
    """Why a call runs code the reader cannot see, "" when it does not (third review of C6)."""
    func = node.func
    if (isinstance(func, ast.Name) and func.id in CODE_CALLS) or (
            isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name) and func.value.id == "builtins"
            and func.attr in CODE_CALLS):
        return f"{called}() of code the reader does not parse"
    first = node.args[0] if node.args else None
    shell = next((k.value for k in node.keywords if k.arg == "shell"), None)
    if called in RUN_CALLS and shell is not None and not (isinstance(shell, ast.Constant) and not shell.value):
        if not _is_text(first):
            return "a shell command built at run time (shell=True)"
    if called in SHELL_CALLS and first is not None and not _is_text(first):
        return f"{called}() of a shell command built at run time"
    if called in RUN_CALLS and isinstance(first, (ast.List, ast.Tuple)):
        argv = list(first.elts)
        while argv and _is_text(argv[0]) and ENV.match(argv[0].value):
            argv = argv[1:]
        program = argv[0] if argv else None
        python = (isinstance(program, ast.Attribute) and program.attr == "executable") or (
            _is_text(program) and INTERPRETER.match(program.value))
        shell_program = _is_text(program) and SHELL.match(program.value)
        rest = argv[1:]
        for i, item in enumerate(rest):
            if _is_text(item) and item.value == "-c" and (python or shell_program):
                code = rest[i + 1] if i + 1 < len(rest) else None
                return "" if _is_text(code) else "code for -c built at run time"
        if shell_program:
            script_arg = next((a for a in rest if not (_is_text(a) and a.value.startswith("-"))), None)
            if script_arg is not None and not _is_text(script_arg):
                return "a shell script started from a name built at run time"
    if called in LIST_CALLS:
        return _lists_harness(node, called, values, script)
    return ""


def is_harness(path: str) -> bool:
    """The broad rule, when unsure: every file under .github/ except the scripts' tests and the
    group file."""
    return path.startswith(HARNESS_PREFIX) and not path.startswith(HARNESS_EXCLUDED) and path != GROUPS_FILE


class Names:
    """What a file names: .github/ paths, file names, modules; `unresolved` when a name is built
    from a variable."""

    def __init__(self, folders_run: bool):
        # In a workflow or shell script a named folder is where something runs (all its files
        # count); in a Python string it is data.
        self.folders_run = folders_run
        self.paths: set[str] = set()
        self.files: set[str] = set()
        self.modules: set[str] = set()
        self.unresolved = ""

    def read_text(self, text: str) -> None:
        """Paths, file names and "python -m" modules in a piece of code or a string."""
        variable = VARIABLE_NAME.search(text)
        if variable:
            self.unresolved = self.unresolved or f"a name built from a variable: {variable.group(0)}"
        self.paths |= {m.rstrip("./") for m in NAMED_PATH.findall(text)}
        self.files |= set(NAMED_FILE.findall(text))
        self.modules |= {m.split(".")[0] for m in DASH_M.findall(text)}


def workflow_names(text: str) -> Names:
    """What a workflow or shell script names outside its whole-line comments (a trailing comment
    stays in: one name too many is harmless) and outside "sparse-checkout:" (checking a folder out
    runs nothing in it)."""
    names = Names(folders_run=True)
    code = [line for line in text.splitlines()
            if not line.lstrip().startswith("#") and not line.lstrip().startswith("sparse-checkout:")]
    names.read_text("\n".join(code))
    return names


def script_names(text: str, path: str = SCRIPTS_DIR + "script.py") -> Names | None:
    """What a Python script imports or names in a string that is not a docstring (a path it runs
    or loads, "x.py", "toolchain.json", a module for import_module or "-m"); None when it cannot
    be parsed (the caller then counts everything). Comments and docstrings name scripts for the
    reader only. Code it runs in a way the reader cannot follow (_runs_hidden_code) makes the
    names unresolved. path: where the script is (for __file__)."""
    try:
        tree = ast.parse(text)
    except (SyntaxError, ValueError):
        return None
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) and node.body:
            first = node.body[0]
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant):
                docstrings.add(id(first.value))
    names = Names(folders_run=False)
    # The script names each variable is ever given (script = os.path.join(HERE, "x.py")), and
    # the expression a name was last given (for the paths of listing calls).
    assigned: dict[str, set[str]] = {}
    values: dict[str, ast.AST] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    values[target.id] = node.value
            given = {c.value for c in ast.walk(node.value) if isinstance(c, ast.Constant) and isinstance(c.value, str)}
            for target in node.targets:
                if isinstance(target, ast.Name):
                    assigned.setdefault(target.id, set()).update(
                        f for text in given for f in NAMED_FILE.findall(text) if f.endswith(".py"))
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.modules |= {alias.name.split(".")[0] for alias in node.names}
        elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
            names.modules.add(node.module.split(".")[0])
        elif isinstance(node, ast.Call):
            func = node.func
            called = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", "")
            hidden = _runs_hidden_code(node, called, values, path)
            if hidden:
                names.unresolved = names.unresolved or hidden
            if called in DYNAMIC_CALLS:
                first = node.args[0] if node.args else None
                if isinstance(first, ast.Constant) and isinstance(first.value, str):
                    names.modules.add(first.value.split(".")[0])
                    names.read_text(first.value)
                else:
                    names.unresolved = names.unresolved or f"{called}() of a name built at run time"
            elif called in RUN_CALLS and node.args and isinstance(node.args[0], (ast.List, ast.Tuple)):
                argv = node.args[0].elts
                program = argv[0] if argv else None
                runs_python = (isinstance(program, ast.Attribute) and program.attr == "executable") or (
                    isinstance(program, ast.Constant) and isinstance(program.value, str) and INTERPRETER.match(program.value))
                script = argv[1] if len(argv) > 1 else None
                if runs_python and script is not None and not (isinstance(script, ast.Constant) and isinstance(script.value, str)):
                    seen = assigned.get(script.id, set()) if isinstance(script, ast.Name) else {
                        f for c in ast.walk(script) if isinstance(c, ast.Constant) and isinstance(c.value, str)
                        for f in NAMED_FILE.findall(c.value) if f.endswith(".py")}
                    if not seen:
                        names.unresolved = names.unresolved or "a script started from a name built at run time"
        elif isinstance(node, (ast.List, ast.Tuple)):
            items = node.elts
            for i, item in enumerate(items[:-1]):
                if isinstance(item, ast.Constant) and item.value == "-m":
                    after = items[i + 1]
                    if isinstance(after, ast.Constant) and isinstance(after.value, str):
                        names.modules.add(after.value.split(".")[0])
                    else:
                        names.unresolved = names.unresolved or "python -m with a module built at run time"
        elif isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in docstrings:
            names.read_text(node.value)
    return names


def resolve(names: Names, blobs) -> set[str] | None:
    """The files of the tree that `names` stands for; None when one cannot be resolved."""
    if names.unresolved:
        return None
    found = set()
    for path in names.paths:
        if not path.startswith(HARNESS_PREFIX):
            continue  # ".github" alone: nothing in particular
        if path in blobs:
            found.add(path)
            continue
        inside = {p for p in blobs if p.startswith(path + "/")}
        if not inside:
            return None  # a .github/ path that is neither a file nor a folder
        if names.folders_run:
            found |= inside
    for name in names.files:
        found |= {p for p in blobs if p.startswith(HARNESS_PREFIX) and not p.startswith(WORKFLOWS_DIR)
                  and p.rsplit("/", 1)[-1] == name}
    for module in names.modules:
        script, package = f"{SCRIPTS_DIR}{module}.py", f"{SCRIPTS_DIR}{module}/"
        found |= {p for p in blobs if p == script or p.startswith(package)}
    return {p for p in found if not p.startswith(HARNESS_EXCLUDED) and p != GROUPS_FILE}


def harness_files(tree) -> set[str]:
    """The harness of a tree (see HARNESS_ROOTS): the UI workflows and, transitively, every file
    under .github/ they and the files they reach name or import (workflow_names, script_names,
    resolve). Fails safe, toward "changed": without both roots, with a script that cannot be
    parsed, with a name that cannot be resolved, or when the UI workflows do not reach the
    runner, every file under .github/ counts (is_harness)."""
    blobs = tree.files()
    everything = {p for p in blobs if is_harness(p)}
    if any(root not in blobs for root in HARNESS_ROOTS):
        return everything
    found, todo = set(), list(HARNESS_ROOTS)
    while todo:
        path = todo.pop()
        if path in found:
            continue
        found.add(path)
        text = tree.read(path) or ""
        if path.endswith(".py"):
            named = script_names(text, path)
            if named is None:
                return everything
        elif path.endswith((".yml", ".yaml", ".sh")):
            named = workflow_names(text)
        else:
            continue  # data (JSON and the like) names nothing that runs
        reached = resolve(named, blobs)
        if reached is None:
            return everything
        todo += [p for p in reached if p not in found]
    if HARNESS_RUNNER not in found:
        return everything
    return found


NOT_APP_PREFIXES = ("App/AlbumistUITests/", "App/AlbumistTests/", "Tests/", "docs/", ".github/", "scripts/", "tools/",
                    "design/")
APP_EXCEPTIONS = (".github/toolchain.json",)
SHORT = 12  # hex digits in job names (48 bits)
GROUP_NAME = re.compile(r"[a-z0-9-]+")  # as ui_evidence.JOB_NAME reads it from a job name
# Environment switch of the UI tests for a quick run per change (ALBUMIST_UI_QUICK=1, handed to the
# tests as TEST_RUNNER_ALBUMIST_UI_QUICK; DeviceConditionUITests.test11_LargeLibrary skips itself):
# every group has another test fingerprint in a quick run, so a quick result never stands in for
# a full one (the upload needs full ones).
QUICK_SWITCH = "ALBUMIST_UI_QUICK"


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


def line_end(source: str, i: int) -> int:
    """Where the line that holds `i` ends: the first "\n" or "\r" from `i` on (Swift's lexer
    ends a line, and a // comment, at either), or the end of the source."""
    ends = [j for j in (source.find("\n", i), source.find("\r", i)) if j >= 0]
    return min(ends) if ends else len(source)


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
                j = line_end(source, i)
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
            elif c in "\r\n" and not multi:
                stack.pop()  # an unterminated string ends at the line
                out.append(c)
                i += 1
            else:
                out.append(blank(c))
                i += 1
    return "".join(out)


SWIFT_SPACE = " \t\r\n\x0b\x0c\x00"  # what Swift's lexer skips as whitespace


def swift_code(source: str) -> str | None:
    """The source as the compiler reads it, without what never changes how it runs: comments are
    dropped, and every run of whitespace and comments outside a literal becomes one "\\n" when it
    holds a line break (Swift reads a line break: a new statement, "(" not a call) and one " "
    otherwise (Swift reads whether an operator has space around it, never how much). String
    literals (also raw and multi-line ones, with their indentation and the closing delimiter's),
    extended regex literals #/.../# and `quoted names` stay byte for byte; the code inside an
    interpolation "\\(...)" is read as code. One pass, character by character.

    None (the caller then takes the bytes) where this reader is not sure: a "/" that is not a
    comment and not an operator with whitespace on both sides (a bare regex literal /.../ may hold
    a space or "//"), a literal or comment left open at the end, an unclosed `name`, or "\\ufffd"
    (bytes that were not UTF-8 and were replaced, so two different files could read the same).
    So two sources with the same result compile to the same program; only the source
    locations #line and #column report can differ (indentation moves #column too; XCTFail and
    print messages carry them, nothing in the tests decides by them).
    Line breaks are "\n", "\r" and "\r\n", as in Swift's lexer: each ends a // comment and a
    single-line string, and each makes a run of whitespace a line break."""
    if "\ufffd" in source:
        return None
    out: list[str] = []
    gap = ""  # the separator owed before the next code ("", " " or "\n")
    i, n = 0, len(source)
    # Frames as in strip_swift: ("code", paren depth or None at the top) and
    # ("string", closing delimiter, hashes, multi-line).
    stack: list[tuple] = [("code", None)]

    def emit(text: str) -> None:
        nonlocal gap
        if gap and out:
            out.append(gap)
        gap = ""
        out.append(text)

    while i < n:
        frame = stack[-1]
        c = source[i]
        if frame[0] == "code":
            if c in SWIFT_SPACE or source.startswith("//", i) or source.startswith("/*", i):
                start = i
                while i < n:
                    if source[i] in SWIFT_SPACE:
                        i += 1
                    elif source.startswith("//", i):
                        i = line_end(source, i)
                    elif source.startswith("/*", i):
                        depth, j = 1, i + 2
                        while j < n and depth:
                            if source.startswith("/*", j):
                                depth, j = depth + 1, j + 2
                            elif source.startswith("*/", j):
                                depth, j = depth - 1, j + 2
                            else:
                                j += 1
                        if depth:
                            return None  # a comment left open
                        i = j
                    else:
                        break
                if out:  # leading whitespace and comments of the file count for nothing
                    gap = "\n" if ("\n" in source[start:i] or "\r" in source[start:i]) else " "
                continue
            if c == "/":
                # An operator "/" or "/=" with whitespace on both sides; anything else may be a
                # bare regex literal, whose text this reader cannot tell from code.
                end = i + 2 if source.startswith("/=", i) else i + 1
                before = source[i - 1] if i else " "
                after = source[end] if end < n else " "
                if before not in SWIFT_SPACE or after not in SWIFT_SPACE:
                    return None
                emit(source[i:end])
                i = end
                continue
            if c == "#" and source[i:].lstrip("#").startswith("/"):
                hashes = len(source[i:]) - len(source[i:].lstrip("#"))
                close = "/" + "#" * hashes
                j = i + hashes + 1
                while j < n and not source.startswith(close, j):
                    j += 2 if source[j] == "\\" else 1
                if j >= n:
                    return None
                emit(source[i:j + len(close)])
                i = j + len(close)
                continue
            if c == "`":
                j = source.find("`", i + 1)
                if j < 0 or "\n" in source[i:j] or "\r" in source[i:j]:
                    return None
                emit(source[i:j + 1])
                i = j + 1
                continue
            if c == '"' or (c == "#" and source[i:].lstrip("#").startswith('"')):
                hashes = 0
                while source[i + hashes] == "#":
                    hashes += 1
                multi = source.startswith('"""', i + hashes)
                opening = hashes + (3 if multi else 1)
                emit(source[i:i + opening])
                stack.append(("string", ('"""' if multi else '"') + "#" * hashes, hashes, multi))
                i += opening
                continue
            if frame[1] is not None and c == "(":
                stack[-1] = ("code", frame[1] + 1)
            elif frame[1] is not None and c == ")":
                if frame[1] == 1:
                    stack.pop()  # back into the string
                else:
                    stack[-1] = ("code", frame[1] - 1)
            emit(c)
            i += 1
        else:
            _, close, hashes, multi = frame
            escape = "\\" + "#" * hashes
            if source.startswith(escape + "(", i):
                out.append(escape + "(")
                stack.append(("code", 1))
                i += len(escape) + 1
            elif source.startswith(escape, i) and i + len(escape) < n:
                out.append(source[i:i + len(escape) + 1])
                i += len(escape) + 1
            elif source.startswith(close, i):
                out.append(close)
                stack.pop()
                i += len(close)
            elif c in "\r\n" and not multi:
                return None  # a string left open at the end of its line
            else:
                out.append(c)
                i += 1
    if len(stack) != 1:
        return None
    return "".join(out)


def swift_code_id(source: str | None, blob: str) -> str:
    """What stands for a Swift file of the UI tests in a test fingerprint: the digest of its code
    (swift_code), so a change to comments or indentation leaves the fingerprint, and with it
    a red result, as it is; its git blob id where the code cannot be read for sure."""
    code = swift_code(source) if source is not None else None
    if code is None:
        return f"blob {blob}"
    return "code " + hashlib.sha256(code.encode("utf-8", errors="surrogateescape")).hexdigest()


class SwiftFile:
    """What one Swift file declares and uses."""

    def __init__(self, path: str, source: str | None):
        self.path = path
        self.source = source  # None when git could not read it (its fingerprint then takes its bytes)
        # Swift's line breaks ("\r\n", "\r", "\n") as "\n" for the line-based reader below.
        source = (source or "").replace("\r\n", "\n").replace("\r", "\n")
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
            files[path] = SwiftFile(path, tree.read(path))
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


# Keys of a group that only report or schedule and never change what runs: left out of the test
# fingerprint, so a new budget does not run a group again. "after_core" (27.11.) only says when
# ui.yml starts the group (after CI's macOS job, job ui-late), not what it tests.
REPORT_ONLY = ("budget_min", "after_core")


def definition(group: dict) -> dict:
    """What a group runs: its keys without the comments ("_...") and the report-only keys."""
    return {k: v for k, v in group.items() if not k.startswith("_") and k not in REPORT_ONLY}


# The smoke test of a draft pull request (rebuild stage 1, the owner's decision of 26.11.2026,
# "alles wie empfohlen"): while a pull request is a draft, ui.yml runs only these two tests,
# quick, on one Mac (the full flow from onboarding to plan, and undo from the history; each
# onboards by itself), instead of all groups. The full UI run comes once, when the pull
# request is marked ready for review. Not a group: its result is no evidence for any group
# (its job name carries the test key SMOKE_TESTS_KEY, which no group's fingerprint can be), so
# the verdict of a ready pull request, the TestFlight gate and every plan run the groups
# themselves. Its job name carries its own test fingerprint (Groups.smoke_fingerprint): a red
# smoke test blocks every later verdict for this app and smoke test code (ui_evidence.py), so a
# red is never re-run to green by marking the draft ready (second review 26.11.).
SMOKE_GROUP = "smoke"
SMOKE_TESTS = ("AlbumistFlowUITests/test1_FullFlow", "AlbumistFlowUITests/test1c_UndoFromHistory")
SMOKE_BUDGET_MIN = 25


def smoke_entry(app: str, tests: str) -> dict:
    """ui.yml's job matrix entry for the smoke test of a draft pull request (`tests`: its
    fingerprint, Groups.smoke_fingerprint)."""
    return {"group": SMOKE_GROUP, "title": "smoke test, full flow and undo (quick)", "device": "pro",
            "only": " ".join(SMOKE_TESTS), "skip": "", "contrast_only": "", "video": False, "reduce_motion": False,
            "increase_contrast": False, "budget_min": SMOKE_BUDGET_MIN, "quick": True,
            "app": app[:SHORT], "tests": tests[:SHORT]}


class Groups:
    """The groups of one tree, their tests, files and fingerprints."""

    def __init__(self, tree):
        self.tree = tree
        self.groups = load_groups(tree)
        if self.groups is None:
            raise ValueError(f"{GROUPS_FILE} is missing")
        self.files = ui_files(tree)
        # A Swift file of the target counts by its code (comments and indentation left out), so a
        # red result stays red until the test code really changes (owner's rule of 17.11.); every
        # other file by its bytes.
        blob_ids = tree.files()
        self.code_ids = {p: swift_code_id(f.source, blob_ids[p]) for p, f in self.files.items()}
        self.tests = all_tests(self.files)
        self.graph = uses(self.files)
        blobs = tree.files()
        shared = ({p for p in blobs if p.startswith(UI_DIR) and not p.endswith(".swift")}
                  | {p for p, f in self.files.items() if f.observer}
                  | harness_files(tree))
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

    def on_pull_requests(self, name: str) -> bool:
        """Whether a pull request's UI run and its verdict include the group ("pull_requests":
        false leaves it to TestFlight runs, the nightly run on main and runs by hand; 27.11.,
        large-library)."""
        return self.group(name).get("pull_requests", True) is not False

    def after_core(self, name: str) -> bool:
        """Whether ui.yml starts the group after CI's macOS job, on the Mac that job frees (job
        ui-late), in a run where that job runs ("after_core": true; 27.11., contrast)."""
        return self.group(name).get("after_core") is True

    def group(self, name: str) -> dict:
        return next(g for g in self.groups if g["group"] == name)

    def selected_tests(self, name: str) -> list[str]:
        """The group's tests: its selection (only, skip) and the tests of its second phase on an
        erased simulator with Increase Contrast on ("contrast_only", ui_tests.py --contrast-only)."""
        g = self.group(name)
        only, skip = g.get("only", "").split(), g.get("skip", "").split()
        contrast = g.get("contrast_only", "").split()
        return sorted(t for t in self.tests if selected(t, only, skip) or (contrast and selected(t, contrast, [])))

    def own_files(self, name: str) -> set[str]:
        return {p for t in self.selected_tests(name) for p in self.tests[t]}

    def files_of(self, name: str) -> list[str]:
        """Every file the group's result depends on, besides the app."""
        return sorted(closure(self.own_files(name), self.graph) | set(self.shared))

    def reads_quick(self, name: str) -> bool:
        """Whether a file of the group reads the quick switch (ALBUMIST_UI_QUICK)."""
        return any(self.files[p].quick_switch for p in self.files_of(name) if p in self.files)

    def fingerprint(self, name: str, quick: bool = False) -> str:
        """The group's test fingerprint; in a quick run always another one."""
        blobs = self.tree.files()
        lines = [json.dumps(definition(self.group(name)), sort_keys=True)]
        lines += [f"{p}\0{self.code_ids.get(p) or blobs[p]}" for p in self.files_of(name)]
        if quick:
            # Every group, not only those whose files read the switch (reads_quick): a switch
            # read where this reader cannot see it must not make a quick result look full.
            lines.append(f"mode quick ({QUICK_SWITCH}=1)")
        return _digest(lines)

    def smoke_fingerprint(self) -> str:
        """The smoke test's test fingerprint, built like a quick group's: its two tests' files,
        the helpers they use, the shared files and the harness. Never equal to a group's (its
        own first line)."""
        blobs = self.tree.files()
        own = {p for t in SMOKE_TESTS for p in self.tests.get(t, ())}
        lines = [json.dumps({"smoke": list(SMOKE_TESTS)}, sort_keys=True)]
        lines += [f"{p}\0{self.code_ids.get(p) or blobs[p]}"
                  for p in sorted(closure(own, self.graph) | set(self.shared))]
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
        entry = {k: g.get(k, "") for k in ("group", "title", "device", "only", "skip", "contrast_only")}
        for flag in ("video", "reduce_motion", "increase_contrast"):
            entry[flag] = bool(g.get(flag, False))
        # The group's time budget in minutes (0: none), checked by ui_tests.py --budget-min.
        entry["budget_min"] = int(self.group(name).get("budget_min", 0) or 0)
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
