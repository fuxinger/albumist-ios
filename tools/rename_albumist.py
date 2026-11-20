#!/usr/bin/env python3
"""Renames the internal working name "Sortly" to "Albumist" in the whole repository, in one go.

The app's visible name (Albumist) and its bundle identifiers (app.albumist.ios ...) are already
right; this changes what only developers see: SwiftPM package and modules (SortlyKit, SortlyCore
...), the folders App/Sortly, App/SortlyTests, App/SortlyUITests, the Xcode targets and schemes in
App/project.yml, type and property names (SortlyID, addedBySortly ...), test launch flags
(-SortlyUITest...), environment switches (SORTLY_UI_QUICK ...), the map resource extension
(.sortlymap), and every script, workflow and document that names them.

    python3 tools/rename_albumist.py                 # dry run (default): prints the plan
    python3 tools/rename_albumist.py --apply         # moves (git mv) and replaces in the work tree
    python3 tools/rename_albumist.py --repo-renamed  # also the repository's name in URLs (see below)

Case-aware: Sortly -> Albumist, sortly -> albumist, SORTLY -> ALBUMIST, also inside longer names
(SortlyID -> AlbumistID, TEST_RUNNER_SORTLY_UI_QUICK -> TEST_RUNNER_ALBUMIST_UI_QUICK). Any other
spelling (e.g. "SortLy") stops the run: it has no safe mapping.

Kept on purpose (EXCLUSIONS below, each with its reason): names stored on users' devices (an
update would lose their data), names of things outside the repository (an old branch, the Appetize
app, review folders), and text that names the old name as such. The database file is the one
stored name that does change: the app moves it once at launch (Sources/SortlyStore/
DatabaseFile.swift), so `DatabaseFile.legacyName` keeps the old file name.

The repository's own name (fuxinger/sortly-ios, and its Pages site fuxinger.github.io/sortly-ios)
changes only with --repo-renamed: GitHub forwards the old repository URL after a rename, but not
the old Pages URL, so the app's privacy link must change in the same step as the rename itself.

--apply refuses a dirty work tree (commit or set aside your changes first), so the result is one
reviewable diff. Run again after committing: it finds nothing left to do (idempotent). After the
moves it regenerates docs/CODEMAP.md (its order follows the file names). Standard library only.
"""
from __future__ import annotations

import argparse
import collections
import dataclasses
import os
import re
import subprocess
import sys

OLD = "sortly"
NEW = "albumist"
WORD = re.compile(OLD, re.IGNORECASE)
CASES = {"sortly": "albumist", "Sortly": "Albumist", "SORTLY": "ALBUMIST"}

SELF = "tools/rename_albumist.py"
SELF_TEST = ".github/scripts/tests/test_rename_albumist.py"


@dataclasses.dataclass(frozen=True)
class Exclusion:
    key: str
    pattern: re.Pattern
    reason: str


EXCLUSIONS = [
    Exclusion("stored-json-keys", re.compile(r'"(?:addedBySortly|createdBySortly)"'),
              "JSON keys of ManagedAlbumState (CodingKeys raw values), stored in the database and in the "
              "safety backup on users' devices; the Swift case names change, the stored keys must not, or "
              "every album record of an update fails to load."),
    Exclusion("legacy-database-name", re.compile(r'legacyName\s*==?\s*"sortly\.sqlite"'),
              "The database file name older builds wrote (DatabaseFile.legacyName, and the test that spells "
              "it out). The app moves sortly.sqlite (+ -wal, -shm) to the new name once at launch; it needs "
              "the old name to find it."),
    Exclusion("old-branch", re.compile(r"claude/sortly-app"),
              "Name of a real, retired git branch (release.yml condition, history in docs); renaming the "
              "text would point to a branch that never existed."),
    Exclusion("appetize-note", re.compile(r"sortly-ci\b"),
              "Key ci.yml uses to find the existing Appetize app (note field). A new note uploads a new "
              "Appetize app with a new public test link; change it on purpose, together with the link."),
    Exclusion("review-folders", re.compile(r"sortly-review/"),
              "Folders of earlier outside reviews that live outside this repository; their names are "
              "what they are."),
    Exclusion("former-name", re.compile(r"„Sortly“(?=\)? ist)|Arbeitsname „Sortly“"),
              "Sentences about the former working name itself (it is taken in the App Store; where it "
              "still stands): renamed, they would say nothing."),
]
REPO_EXCLUSION = Exclusion(
    "repo-name", re.compile(r"sortly-ios"),
    "The GitHub repository's name (github.com/fuxinger/sortly-ios, fuxinger.github.io/sortly-ios, the "
    "runner's checkout path /Users/runner/work/sortly-ios/...). Changes only with --repo-renamed, after the "
    "repository is renamed: GitHub forwards the old repository URL but not the old Pages URL.")
KEEP_BLOCK = re.compile(r"rename:keep-begin.*?rename:keep-end", re.S)
KEEP_BLOCK_REASON = "Text between rename:keep-begin and rename:keep-end markers (the rename's own documentation)."
EXCLUDED_PATHS = {
    SELF: "This script: it has to name the old spelling.",
    SELF_TEST: "Tests of this script: they have to name the old spelling.",
}


@dataclasses.dataclass(frozen=True)
class SpecialEdit:
    """Text that the plain mapping would make wrong or meaningless; replaced first, exactly once."""
    path: str  # path before the rename
    old: str
    new: str
    repo_renamed_only: bool = False


SPECIAL_EDITS = [
    SpecialEdit("App/Sortly/App/AppInfo.swift",
                "/// Product identity in one place. The product is called Albumist (chosen 14.11.2026); the\n"
                "/// bundle identifiers keep the old working name \"sortly\" until the App Store record exists.\n",
                "/// Product identity in one place. The product is called Albumist (chosen 14.11.2026).\n"),
    SpecialEdit("App/project.yml",
                "# Short name (the target is still called Sortly): Appetize and some system lists show it.",
                "# Short name: Appetize and some system lists show it."),
    SpecialEdit("docs/KNOWN_LIMITATIONS.md",
                "- Der sichtbare Name ist Albumist; Ordner, Module und Targets heißen noch „Sortly“ (nur intern).",
                "- Der frühere Arbeitsname „Sortly“ steht nur noch in gespeicherten Namen, die bleiben müssen "
                "(Datenbank-Datei älterer Builds, Schlüssel der Album-Einträge; `tools/rename_albumist.py`)."),
    SpecialEdit("docs/review/CROSS_REVIEW_PROMPT.md",
                "**Albumist** (im Code heißen Ordner, Module und Targets noch nach dem alten Arbeitsnamen\n„Sortly“) sortiert",
                "**Albumist** sortiert"),
    SpecialEdit("website/ANLEITUNG.md",
                "Die Adresse enthält noch den alten Namen des Repositorys (`sortly-ios`).\n"
                "Das lässt sich auf zwei Wegen ändern:\n"
                "- Repository umbenennen, zum Beispiel in `albumist` (Settings › General).\n"
                "  Dann lautet die Adresse `https://fuxinger.github.io/albumist/`.\n"
                "- Eine eigene Domain kaufen",
                "Das Repository heißt `albumist-ios`, die Adressen oben gelten seit der Umbenennung. Die\n"
                "Adresse mit dem früheren Namen leitet GitHub Pages nicht weiter: In App Store Connect\n"
                "müssen Datenschutz-, Support- und Marketing-URL die Adressen oben sein.\n"
                "Eine eigene Adresse ist weiter möglich:\n"
                "- Eine eigene Domain kaufen",
                repo_renamed_only=True),
]

# What this script cannot do; printed with every plan.
OUTSIDE = [
    "GitHub: rename the repository to albumist-ios (Settings > General), then run again with --repo-renamed "
    "in the same change as nothing else; the Pages site moves to https://fuxinger.github.io/albumist-ios/ "
    "and the old Pages address stops working (no forwarding).",
    "App Store Connect: privacy policy, support and marketing URLs to the new Pages address (with "
    "--repo-renamed, before the build with the new privacy link is submitted).",
    "Mac: regenerate the Xcode project (xcodegen in App/); delete the old, ignored App/Sortly.xcodeproj and "
    "DerivedData. Archive once: target, scheme and executable are now Albumist (bundle id unchanged).",
    "CI history: test names and paths change (SortlyFlowUITests -> AlbumistFlowUITests, App/SortlyUITests/ "
    "-> App/AlbumistUITests/), so UI group fingerprints, flaky history and superseded results start fresh; "
    "the first runs after the rename run every UI group. Artifact names change (Sortly-simulator-app).",
    "Appetize: the note sortly-ci is kept on purpose (same app, same test link).",
    "Not touched: secrets, variables and the environment testflight-upload (none carries the old name).",
]


class RenameError(Exception):
    pass


# ---------------------------------------------------------------- mapping

def map_word(word: str) -> str:
    try:
        return CASES[word]
    except KeyError:
        raise RenameError(f"no safe mapping for the spelling {word!r}") from None


def map_path(path: str) -> str:
    """The path after the rename (every component; paths never hold an excluded name)."""
    return WORD.sub(lambda m: map_word(m.group(0)), path)


def protected_spans(text: str, repo_renamed: bool) -> list[tuple[int, int, str]]:
    spans = [(m.start(), m.end(), "keep-block") for m in KEEP_BLOCK.finditer(text)]
    rules = EXCLUSIONS + ([] if repo_renamed else [REPO_EXCLUSION])
    for rule in rules:
        spans += [(m.start(), m.end(), rule.key) for m in rule.pattern.finditer(text)]
    return sorted(spans)


@dataclasses.dataclass
class TextResult:
    text: str
    replaced: collections.Counter  # "Old -> New" token counts
    kept: list  # (line number, exclusion key, line text)

    @property
    def count(self) -> int:
        return sum(self.replaced.values())


TOKEN = re.compile(r"[A-Za-z0-9_]*" + OLD + r"[A-Za-z0-9_]*", re.IGNORECASE)


def rename_text(text: str, repo_renamed: bool = False) -> TextResult:
    """The text with every unprotected spelling of the old name mapped."""
    spans = protected_spans(text, repo_renamed)
    out, last = [], 0
    replaced, kept = collections.Counter(), []
    lines = None
    for m in WORD.finditer(text):
        key = next((k for s, e, k in spans if s < m.end() and m.start() < e), None)
        if key:
            lines = lines or text.split("\n")
            line = text.count("\n", 0, m.start()) + 1
            kept.append((line, key, lines[line - 1].strip()))
            continue
        new = map_word(m.group(0))
        out.append(text[last:m.start()])
        out.append(new)
        last = m.end()
    out.append(text[last:])
    result = "".join(out)
    if result != text:
        # Count by whole token ("SortlyID -> AlbumistID") for a readable plan.
        for m in TOKEN.finditer(text):
            if any(s < m.end() and m.start() < e for s, e, _ in spans):
                continue
            replaced[f"{m.group(0)} -> {map_path(m.group(0))}"] += len(WORD.findall(m.group(0)))
    return TextResult(result, replaced, kept)


# ---------------------------------------------------------------- repository

def git(root: str, *args: str) -> str:
    return subprocess.run(["git", "-C", root, *args], check=True, capture_output=True, text=True).stdout


def tracked_files(root: str) -> list[str]:
    return [p for p in git(root, "ls-files", "-z").split("\0") if p]


def dirty(root: str) -> list[str]:
    return [line for line in git(root, "status", "--porcelain", "--untracked-files=normal").splitlines() if line]


def read_text(path: str) -> str | None:
    """The file's text, or None for a binary, a link or a file that is not UTF-8."""
    if os.path.islink(path) or not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        data = f.read()
    if b"\0" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


@dataclasses.dataclass
class Plan:
    moves: list  # (old, new)
    edits: dict  # old path -> TextResult (after special edits)
    specials: list  # (old path, SpecialEdit)
    kept: list  # (path, line, key, text)
    skipped: list  # (path, reason)
    repo_renamed: bool

    @property
    def empty(self) -> bool:
        return not self.moves and not self.edits


def build_plan(root: str, repo_renamed: bool = False) -> Plan:
    files = tracked_files(root)
    tracked = set(files)
    moves, edits, specials, kept, skipped, problems = [], {}, [], [], [], []
    for path in files:
        if path in EXCLUDED_PATHS:
            if WORD.search(path):
                problems.append(f"{path}: an excluded file must not carry the old name in its path")
            skipped.append((path, EXCLUDED_PATHS[path]))
            continue
        try:
            new_path = map_path(path)
        except RenameError as e:
            problems.append(f"{path}: {e}")
            continue
        if new_path != path:
            if new_path in tracked:
                problems.append(f"{path} -> {new_path}: the target already exists")
            moves.append((path, new_path))
        text = read_text(os.path.join(root, path))
        if text is None:
            if _binary_mentions(os.path.join(root, path)):
                skipped.append((path, "binary file that contains the old name (not changed)"))
            continue
        original = text
        for edit in SPECIAL_EDITS:
            if edit.path == path and edit.old in text and (repo_renamed or not edit.repo_renamed_only):
                text = text.replace(edit.old, edit.new, 1)
                specials.append((path, edit))
        try:
            result = rename_text(text, repo_renamed)
        except RenameError as e:
            problems.append(f"{path}: {e}")
            continue
        for line, key, line_text in result.kept:
            if (new_path, line, key, line_text) not in kept[-3:]:
                kept.append((new_path, line, key, line_text))
        if result.text != original:
            edits[path] = result
    targets = collections.Counter(new for _, new in moves)
    problems += [f"two files would become {t}" for t, n in targets.items() if n > 1]
    if problems:
        raise RenameError("the rename cannot run:\n  " + "\n  ".join(problems))
    return Plan(moves, edits, specials, kept, skipped, repo_renamed)


def _binary_mentions(path: str) -> bool:
    try:
        with open(path, "rb") as f:
            return OLD.encode() in f.read().lower()
    except OSError:
        return False


def move_groups(moves: list) -> tuple[collections.Counter, list]:
    """Folder moves (with their file count) and files renamed by their own name."""
    folders, files = collections.Counter(), []
    for old, new in moves:
        old_parts, new_parts = old.split("/"), new.split("/")
        first = next(i for i, (a, b) in enumerate(zip(old_parts, new_parts)) if a != b)
        if first < len(old_parts) - 1:
            folders["/".join(old_parts[:first + 1]) + "/ -> " + "/".join(new_parts[:first + 1]) + "/"] += 1
            if old_parts[-1] != new_parts[-1]:
                files.append((old, new))
        else:
            files.append((old, new))
    return folders, files


# ---------------------------------------------------------------- output

def print_plan(plan: Plan, out=None) -> None:
    w = lambda s="": print(s, file=out or sys.stdout)  # noqa: E731
    if plan.empty:
        w("Nothing to rename: no file or text carries the old name outside the exclusions below.")
    folders, files = move_groups(plan.moves)
    w(f"== Moves: {len(plan.moves)} files ==")
    for group, n in sorted(folders.items()):
        w(f"  {group}  ({n} files)")
    if files:
        w("  renamed by their own name:")
        for old, new in files:
            w(f"    {old} -> {new}")
    total = sum(r.count for r in plan.edits.values())
    w()
    w(f"== Text replacements: {total} in {len(plan.edits)} files ==")
    rewritten = collections.Counter(path for path, _ in plan.specials)
    for path in sorted(plan.edits):
        extra = f" (+{rewritten[path]} rewritten sentence)" if rewritten[path] else ""
        w(f"  {plan.edits[path].count:5}  {path}{extra}")
    tokens = collections.Counter()
    for r in plan.edits.values():
        tokens.update(r.replaced)
    if tokens:
        w("  most frequent:")
        for token, n in tokens.most_common(30):
            w(f"    {n:5}  {token}")
    if plan.specials:
        w()
        w(f"== Rewritten sentences (the plain mapping would make them wrong): {len(plan.specials)} ==")
        for path, edit in plan.specials:
            w(f"  {path}: {edit.new.splitlines()[0][:100]}")
    w()
    w("== Not renamed on purpose ==")
    by_key = collections.defaultdict(list)
    for path, line, key, text in plan.kept:
        by_key[key].append(f"{path}:{line}: {text[:140]}")
    rules = {r.key: r.reason for r in EXCLUSIONS + [REPO_EXCLUSION]}
    rules["keep-block"] = KEEP_BLOCK_REASON
    for key, reason in rules.items():
        if key == "repo-name" and plan.repo_renamed:
            continue
        w(f"  [{key}] {reason}")
        if key == "keep-block":
            lines = collections.defaultdict(list)
            for path, line, k, _ in plan.kept:
                if k == key:
                    lines[path].append(line)
            for path, found in lines.items():
                w(f"      {path}:{min(found)}-{max(found)} ({len(found)} mentions)")
            continue
        for hit in by_key.get(key, []):
            w(f"      {hit}")
    for path, reason in plan.skipped:
        w(f"  [file] {path}: {reason}")
    w()
    w("== Outside this script (owner) ==")
    for item in OUTSIDE:
        w(f"  - {item}")


# ---------------------------------------------------------------- apply

def apply(root: str, plan: Plan, out=None) -> None:
    out = out or sys.stdout
    for path, result in plan.edits.items():
        with open(os.path.join(root, path), "w", encoding="utf-8", newline="") as f:
            f.write(result.text)
    for old, new in sorted(plan.moves):
        os.makedirs(os.path.dirname(os.path.join(root, new)) or root, exist_ok=True)
        git(root, "mv", old, new)
    # Folders the moves emptied (git does not track folders).
    for old, _ in plan.moves:
        folder = os.path.dirname(os.path.join(root, old))
        while folder != root and os.path.isdir(folder) and not os.listdir(folder):
            os.rmdir(folder)
            folder = os.path.dirname(folder)
    codemap = os.path.join(root, "scripts", "gen_codemap.py")
    if os.path.exists(codemap):
        subprocess.run([sys.executable, codemap], check=True, cwd=root, capture_output=True)
    folders, _ = move_groups(plan.moves)
    left = sorted(old for old in (group.split(" -> ")[0] for group in folders)
                  if os.path.isdir(os.path.join(root, old)))
    print(f"Applied: {len(plan.moves)} moves, {sum(r.count for r in plan.edits.values())} replacements "
          f"in {len(plan.edits)} files; docs/CODEMAP.md regenerated.", file=out)
    if left:
        print("Old folders still there (only ignored files left in them, e.g. build output): "
              + ", ".join(left), file=out)
    print("Next: review `git status` / `git diff --stat -M`, build, test, commit.", file=out)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="print the plan only (default)")
    mode.add_argument("--apply", action="store_true", help="move and replace in the work tree")
    p.add_argument("--repo-renamed", action="store_true",
                   help="the GitHub repository is renamed to albumist-ios: change its URLs too")
    p.add_argument("--root", default=None, help="repository root (default: the one this script is in)")
    args = p.parse_args(argv)
    root = os.path.abspath(args.root or os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    root = git(root, "rev-parse", "--show-toplevel").strip()
    if args.apply:
        changes = dirty(root)
        if changes:
            print("Refused: the work tree has changes. Commit them or set them aside first, so the rename "
                  "is one clean diff:\n  " + "\n  ".join(changes[:20]), file=sys.stderr)
            return 2
    try:
        plan = build_plan(root, args.repo_renamed)
    except RenameError as e:
        print(f"Refused: {e}", file=sys.stderr)
        return 1
    print_plan(plan)
    if args.apply and not plan.empty:
        print()
        apply(root, plan)
    elif not args.apply and not plan.empty:
        print("\nDry run: nothing changed. Run with --apply to do it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
