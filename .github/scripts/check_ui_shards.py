"""Every UI test runs in exactly one shard of .github/workflows/ui.yml.

The UI run is split over parallel runners; each shard lists its tests as `Class` or
`Class/test` in a `tests:` line of the matrix. A test missing there would never run, a test
listed twice would run twice, and a name that no longer exists would run nothing.
Usage: python3 .github/scripts/check_ui_shards.py
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parents[2]
tests: dict[str, list[str]] = {}
for path in sorted((root / "App" / "SortlyUITests").glob("*.swift")):
    current = None
    for line in path.read_text(encoding="utf-8").splitlines():
        cls = re.match(r"\s*(?:@\w+\s+)*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase", line)
        if cls:
            current = cls.group(1)
            tests.setdefault(current, [])
        test = re.match(r"\s*func\s+(test\w*)\s*\(\s*\)", line)
        if test and current:
            tests[current].append(test.group(1))

workflow = (root / ".github" / "workflows" / "ui.yml").read_text(encoding="utf-8")
listed = [entry for line in re.findall(r"^\s*tests:\s*(.+)$", workflow, re.M) for entry in line.split()]

problems = []
runs: dict[str, int] = {}
for entry in listed:
    cls, _, name = entry.partition("/")
    if cls not in tests:
        problems.append(f"{entry}: no UI test class {cls}")
        continue
    names = [name] if name else tests[cls]
    for n in names:
        if n not in tests[cls]:
            problems.append(f"{entry}: no test {n} in {cls}")
        runs[f"{cls}/{n}"] = runs.get(f"{cls}/{n}", 0) + 1
for cls, names in tests.items():
    for n in names:
        count = runs.get(f"{cls}/{n}", 0)
        if count != 1:
            problems.append(f"{cls}/{n} is listed {count} times in the shards of ui.yml")

total = sum(len(n) for n in tests.values())
if problems:
    print("\n".join(problems))
    sys.exit(1)
print(f"UI shards cover all {total} UI tests exactly once")
