"""Test summary for the GitHub job page, and the map from test-plan cases to tests.

  summary --title T [--swift-log F]... [--xcresult-json F]... [--load-log F]
      Markdown for $GITHUB_STEP_SUMMARY: test counts, failures, and which cases of the
      coverage table in docs/TEST_PLAN.md were exercised by the tests of this job.
  map-generate
      Adds every case of the coverage table that is not yet in docs/TEST_COVERAGE_MAP.txt,
      with the tests named in its "Test heute" column (hand edits in the map are kept).
  map-check
      Warns about names in the map that match no test, and cases without an entry.

The map is plain text: a case id, then test function names (Swift Testing functions without
parentheses, XCTest/UI test methods); a name ending in * matches every test starting with it.
"""
import argparse
import glob
import json
import os
import re
import sys

ROOT = os.environ.get("REPO_ROOT", ".")
PLAN = os.path.join(ROOT, "docs/TEST_PLAN.md")
MAP = os.path.join(ROOT, "docs/TEST_COVERAGE_MAP.txt")
CASE_ID = re.compile(r"^([A-G]\d+(?:[–-][A-G]?\d+)?)\b")

# ---------------------------------------------------------------------------------------------
# Test inventory from the sources


def test_inventory():
    """{function name: kind} and {display name: function name} for all tests in the repo."""
    names, display = {}, {}
    unit = glob.glob(f"{ROOT}/Tests/**/*.swift", recursive=True) + glob.glob(f"{ROOT}/App/SortlyTests/**/*.swift", recursive=True)
    ui = glob.glob(f"{ROOT}/App/SortlyUITests/**/*.swift", recursive=True)
    attribute = re.compile(r'@Test\b(\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))?[\s\S]{0,200}?\bfunc\s+(\w+)\s*\(')
    for path in unit:
        source = open(path, encoding="utf-8").read()
        kind = "load" if re.search(r"SORTLY_LOAD_TEST", source) else ("app" if "/App/" in path else "core")
        for match in attribute.finditer(source):
            name = match.group(2)
            names[name] = kind
            label = re.match(r'\(\s*"((?:[^"\\]|\\.)*)"', match.group(1) or "")
            if label:
                display[label.group(1)] = name
        for match in re.finditer(r"\bfunc\s+(test\w+)\s*\(", source):  # XCTest
            names.setdefault(match.group(1), kind)
    for path in ui:
        for match in re.finditer(r"\bfunc\s+(test\w+)\s*\(", open(path, encoding="utf-8").read()):
            names[match.group(1)] = "ui"
    return names, display


def suite_files():
    """{file stem without "Tests": [test names]} for references like "Load:" or "DecisionLifecycle"."""
    result = {}
    for path in glob.glob(f"{ROOT}/Tests/**/*Tests.swift", recursive=True) + glob.glob(f"{ROOT}/App/SortlyTests/*.swift"):
        stem = os.path.basename(path)[:-len(".swift")]
        source = open(path, encoding="utf-8").read()
        tests = re.findall(r"@Test\b[^\n]*\n?\s*(?:@\w+[^\n]*\n\s*)*func\s+(\w+)", source)
        tests += re.findall(r"@Test\b[^\n]*?func\s+(\w+)", source)
        result[stem.removesuffix("Tests")] = sorted(set(tests))
    return result

# ---------------------------------------------------------------------------------------------
# The coverage table and the map


def plan_cases():
    """[(case id, title, state, tests text)] from the coverage table of docs/TEST_PLAN.md."""
    cases = []
    in_table = False
    for line in open(PLAN, encoding="utf-8"):
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if line.startswith("| Fall |"):
            in_table = True
            continue
        if in_table and not line.startswith("|"):
            in_table = False
        if not in_table or len(cells) < 3 or set(cells[0]) <= {"-", " "}:
            continue
        match = CASE_ID.match(cells[0])
        if match:
            cases.append((match.group(1), cells[0][match.end():].strip(), cells[1], cells[2]))
    return cases


def read_map():
    entries = {}
    if not os.path.exists(MAP):
        return entries
    for line in open(MAP, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if line:
            case, *tests = line.split()
            entries[case] = tests
    return entries


def resolve(text, names, suites):
    """Test names for the free text of a "Test heute" cell."""
    found = []
    text = text.replace("`", "")
    for first, last in re.findall(r"\btest(\d)\s*[–-]\s*(\d)\b", text):  # "test1–6"
        found += [n for n in names if names[n] == "ui" and first <= n[4:5] <= last]
    for digit in re.findall(r"\b(?:UI\s+)?test(\d)\b(?!\s*[–-])", text):    # "UI test6"
        found += [n for n in names if names[n] == "ui" and n.startswith(f"test{digit}_")]
    # "Suite: name…, other…" looks only inside that suite; "Load: 20.000" means the whole suite.
    for segment in re.findall(r"\b\w+:[^:]*?(?=,?\s+\w+:|$)", text):
        label, rest = segment.split(":", 1)
        if label not in suites:
            continue
        tokens = [t.lower() for t in re.findall(r"[A-Za-z]\w{3,}", rest)]
        hits = [n for n in suites[label] if any(t in n.lower() for t in tokens)]
        found += hits or suites[label]
        text = text.replace(segment, " ")
    for token, partial in re.findall(r"([A-Za-z][A-Za-z0-9_]{3,})(…|\.\.\.)?", text):
        if token in names:
            found.append(token)                                              # exact function
        elif partial:
            found += [n for n in names if n.startswith(token)][:6]           # "pauseAndResume…"
        elif token in suites:
            found += suites[token]                                           # "DecisionLifecycle"
    unique = []
    for name in found:
        if name not in unique:
            unique.append(name)
    return unique


def map_generate():
    names, _ = test_inventory()
    suites = suite_files()
    existing = read_map()
    added = []
    for case, title, state, text in plan_cases():
        if case not in existing:
            existing[case] = resolve(text, names, suites)
            added.append(case)
    header = (
        "# Test-plan case -> tests that exercise it (docs/TEST_PLAN.md, table \"Abdeckung aller Fälle\").\n"
        "# One line per case: the case id, then test function names (Swift Testing functions without\n"
        "# parentheses, XCTest and UI test methods). A name ending in * matches every test starting\n"
        "# with it. New cases: `python3 .github/scripts/test_summary.py map-generate` adds them from the\n"
        "# \"Test heute\" column; then check the names by hand. CI warns about names that match no test\n"
        "# (map-check) and shows per run which cases ran (job summary).\n"
    )
    order = [c for c, *_ in plan_cases()] + [c for c in existing if c not in {c for c, *_ in plan_cases()}]
    with open(MAP, "w", encoding="utf-8") as out:
        out.write(header)
        for case in order:
            out.write(f"{case:<6} {' '.join(existing[case])}".rstrip() + "\n")
    print(f"MAP {len(existing)} cases, {len(added)} added: {' '.join(added)}")


def matches(pattern, name):
    return name.startswith(pattern[:-1]) if pattern.endswith("*") else name == pattern


def map_check():
    names, _ = test_inventory()
    entries = read_map()
    problems = 0
    for case, tests in entries.items():
        for pattern in tests:
            if not any(matches(pattern, n) for n in names):
                print(f"::warning file=docs/TEST_COVERAGE_MAP.txt::{case}: no test named {pattern}")
                problems += 1
    for case, *_ in plan_cases():
        if case not in entries:
            print(f"::warning file=docs/TEST_COVERAGE_MAP.txt::{case} from docs/TEST_PLAN.md has no line in the map "
                  "(python3 .github/scripts/test_summary.py map-generate)")
            problems += 1
    print(f"MAP_CHECK {len(entries)} cases, {problems} warnings")

# ---------------------------------------------------------------------------------------------
# Test results


SWIFT_TESTING = re.compile(r"^\S*\s*Test (\"(?:[^\"\\]|\\.)*\"|[\w`]+\([^)]*\))(?: with \d+ test cases?)? (passed|failed|skipped)")
SWIFT_TOTAL = re.compile(r"Test run with (\d+) tests?(?: in \d+ suites?)? (passed|failed)(?:.*?with (\d+) issues?)?")
XCTEST = re.compile(r"Test Case '-?\[?[\w.]*[ .](\w+)\]?' (passed|failed|skipped)")


def function_name(raw, display):
    if raw.startswith('"'):
        return display.get(raw[1:-1].replace('\\"', '"'), raw[1:-1])
    return raw.split("(", 1)[0].strip("`")


def parse_swift_log(path, display, results, totals):
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip()
        total = SWIFT_TOTAL.search(line)
        if total:
            totals["issues"] += int(total.group(3) or 0)
            continue
        match = SWIFT_TESTING.match(line) or XCTEST.search(line)
        if match:
            name = function_name(match.group(1), display)
            status = match.group(2)
            if results.get(name) != "failed":
                results[name] = status


def parse_xcresult(path, display, results, totals):
    try:
        data = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError):
        return

    def walk(node):
        if node.get("nodeType") == "Test Case":
            name = function_name(node.get("name", ""), display)
            name = display.get(node.get("name", ""), name)
            status = {"Passed": "passed", "Failed": "failed", "Skipped": "skipped",
                      "Expected Failure": "passed"}.get(node.get("result"), "failed")
            if results.get(name) != "failed":
                results[name] = status
            if status == "failed":
                totals["issues"] += 1
        for child in node.get("children", []):
            walk(child)

    for node in data.get("testNodes", []):
        walk(node)


def summary(args):
    names, display = test_inventory()
    results, totals = {}, {"issues": 0}
    for path in args.swift_log or []:
        if os.path.exists(path):
            parse_swift_log(path, display, results, totals)
    for path in args.xcresult_json or []:
        if os.path.exists(path):
            parse_xcresult(path, display, results, totals)
    failed = sorted(n for n, s in results.items() if s == "failed")
    passed = sum(1 for s in results.values() if s == "passed")
    skipped = sum(1 for s in results.values() if s == "skipped")
    out = [f"## {args.title}", ""]
    if not results:
        out.append("No test results found (the build or the test run failed before any test finished; see the log).")
    else:
        icon = "❌" if failed or totals["issues"] else "✅"
        out.append(f"{icon} **{len(results)} tests**: {passed} passed, {len(failed)} failed, "
                   f"{skipped} skipped" + (f", {totals['issues']} issues recorded." if totals["issues"] else "."))
    if failed:
        out += ["", "**Failed:** " + ", ".join(f"`{n}`" for n in failed[:40])]
    if args.load_log and os.path.exists(args.load_log):
        load = [l.strip() for l in open(args.load_log, encoding="utf-8", errors="replace")
                if l.startswith(("LOAD_", "[measure]"))]
        if load:
            out += ["", "<details><summary>Load test</summary>", "", "```", *load[:30], "```", "</details>"]
    entries = read_map()
    plan = {c: (title, state) for c, title, state, _ in plan_cases()} if os.path.exists(PLAN) else {}
    if entries and results:
        rows, exercised = [], 0
        for case, patterns in entries.items():
            title, state = plan.get(case, ("", ""))
            hits = sorted({n for n in results if results[n] != "skipped" and any(matches(p, n) for p in patterns)})
            ui_only = bool(patterns) and all(names.get(n) == "ui" for p in patterns for n in names if matches(p, n))
            if any(results[n] == "failed" for n in hits):
                mark = "❌ failed"
            elif hits:
                mark = "✅ ran"
                exercised += 1
            elif not patterns:
                mark = "— no test"
            elif ui_only:
                mark = "↪ UI flow"
            else:
                mark = "· not in this job"
            rows.append(f"| {case} {title} | {state} | {mark} | {', '.join(hits[:4])}{' …' if len(hits) > 4 else ''} |")
        out += ["", f"<details><summary>Test-plan cases exercised here: {exercised} of {len(entries)}</summary>", "",
                "| Case | Plan | This job | Tests that ran |", "|---|---|---|---|", *rows, "", "</details>"]
    print("\n".join(out))
    if args.fail_on_missing and not results:
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("summary")
    s.add_argument("--title", required=True)
    s.add_argument("--swift-log", action="append")
    s.add_argument("--xcresult-json", action="append")
    s.add_argument("--load-log")
    s.add_argument("--fail-on-missing", action="store_true")
    sub.add_parser("map-generate")
    sub.add_parser("map-check")
    args = parser.parse_args()
    if args.command == "summary":
        return summary(args)
    if args.command == "map-generate":
        return map_generate()
    return map_check()


if __name__ == "__main__":
    sys.exit(main())
