"""Version and release notes for the release workflow.

  python3 release_notes.py version     prints MARKETING_VERSION from App/project.yml (X.Y.Z) and
                                       fails if CFBundleShortVersionString says something else
  python3 release_notes.py notes X.Y.Z prints the section "## X.Y.Z ..." of docs/CHANGELOG.md
"""
import re
import sys


def version():
    project = open("App/project.yml", encoding="utf-8").read()
    marketing = set(re.findall(r'MARKETING_VERSION:\s*"?([0-9][0-9A-Za-z.\-]*)"?', project))
    short = set(re.findall(r'CFBundleShortVersionString:\s*"?([0-9][0-9A-Za-z.\-]*)"?', project))
    if len(marketing) != 1:
        sys.exit(f"App/project.yml: expected one MARKETING_VERSION, found {sorted(marketing) or 'none'}")
    value = marketing.pop()
    if short and short != {value}:
        sys.exit(f"App/project.yml: MARKETING_VERSION {value} but CFBundleShortVersionString {sorted(short)}")
    if not re.fullmatch(r"\d+\.\d+\.\d+", value):
        sys.exit(f"App/project.yml: MARKETING_VERSION {value} is not X.Y.Z")
    print(value)


def notes(value):
    text = open("docs/CHANGELOG.md", encoding="utf-8").read()
    match = re.search(rf"^## {re.escape(value)}\b[^\n]*\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    if not match:
        sys.exit(f"docs/CHANGELOG.md has no section '## {value}'")
    body = re.sub(r"^### ", "## ", match.group(1).strip(), flags=re.M)
    print(body + "\n\nVollständige Liste: docs/CHANGELOG.md")


if __name__ == "__main__":
    if sys.argv[1:2] == ["version"]:
        version()
    elif sys.argv[1:2] == ["notes"] and len(sys.argv) == 3:
        notes(sys.argv[2])
    else:
        sys.exit(__doc__)
