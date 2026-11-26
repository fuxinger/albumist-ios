"""The photo viewer gets every photo of the list it was opened from (iPhone, Build 41, 26.11.2026:
"Nicht sortiert" showed 3.348 photos, the viewer "1 von 3.000" and stopped there). The library
grid builds its thumbnails 3,000 at a time (LibraryView.page) and handed the viewer only those;
search did the same with its pages. The viewer builds its own pages in a window (PageWindow), so
it never needs a cut list. This rule finds a viewer opened with a list cut to the pages shown."""
import os
import re
import unittest

VIEWS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "App", "Albumist", "Views")


def offenders(folder: str = VIEWS) -> list[str]:
    found = []
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".swift"):
            continue
        with open(os.path.join(folder, name), encoding="utf-8") as f:
            code = re.sub(r"//[^\n]*", "", f.read())
        for match in re.finditer(r"PhotoViewer\.Start\(", code):
            # The call's line and the two blocks around it, which build its list.
            opened = code.rfind("{", 0, code.rfind("{", 0, match.start()))
            before = code[max(opened, 0):code.find("\n", match.end())]
            if re.search(r"\.prefix\(\s*shown\s*\)", before):
                found.append(f"{name}:{code.count(chr(10), 0, match.start()) + 1}")
    return found


class ViewerListRuleTests(unittest.TestCase):
    def test_no_viewer_gets_only_the_pages_shown(self):
        self.assertEqual(offenders(), [])

    def test_the_rule_finds_the_cut_list_of_build_41(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "LibraryView.swift"), "w", encoding="utf-8") as f:
                f.write("Button {\n    guard selecting else {\n"
                        "        viewing = PhotoViewer.Start(id: id, ids: members.prefix(shown).map(\\.id))\n"
                        "        return\n    }\n}\n")
            with open(os.path.join(tmp, "SearchView.swift"), "w", encoding="utf-8") as f:
                f.write("return Button {\n    var ids = Array(result.ids.prefix(shown))\n"
                        "    viewing = PhotoViewer.Start(id: id, ids: ids)\n}\n")
            self.assertEqual(offenders(tmp), ["LibraryView.swift:3", "SearchView.swift:3"])


if __name__ == "__main__":
    unittest.main()
