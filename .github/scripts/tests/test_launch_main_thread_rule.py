"""Launch work that the hang watch found on the main thread stays off it (UI run 45589509156,
25.11.2026, flow-other): the keychain read of the free-album count held the main thread for
2.3 s, and the database folder's file calls (setResourceValues in AppModel.databaseURL) for
220 ms. Both now run off it; these checks keep them there. The behaviour itself is tested in
App/AlbumistTests/PurchasesKeychainTests.swift and LaunchOffMainTests.swift."""
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")


def read(*parts: str) -> str:
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def code_only(swift: str) -> str:
    """Swift without // comments, so a comment naming a call is no call."""
    return re.sub(r"//[^\n]*", "", swift)


class LaunchMainThreadRuleTests(unittest.TestCase):
    def test_the_keychain_is_only_reached_through_its_queue(self):
        purchases = code_only(read("App", "Albumist", "Platform", "Purchases.swift"))
        self.assertNotRegex(purchases, r"LedgerKeychain\.(load|save|loadNow|saveNow)\(")
        self.assertIn("keychain.beginLoad()", purchases)
        keychain = code_only(read("App", "Albumist", "Platform", "LedgerKeychain.swift"))
        # Only the copy's queue calls the keychain itself.
        for call in re.finditer(r"\b(loadNow|saveNow)\(\)?", keychain):
            line = keychain[keychain.rfind("\n", 0, call.start()) + 1:keychain.find("\n", call.end())]
            if "static func" in line:
                continue
            self.assertIn("Copy(asksForTime: true, read: { LedgerKeychain.loadNow() }", line, line)

    def test_a_plan_waits_for_the_keychain_before_it_checks_the_free_albums(self):
        model = code_only(read("App", "Albumist", "Model", "AppModel.swift"))
        run = model[model.index("private func run(_ plan: ChangePlan"):]
        wait = run.index("await Purchases.shared.keychainRead()")
        check = run.index("Purchases.shared.allows(albums:")
        self.assertLess(wait, check)

    def test_the_database_folder_is_made_off_the_main_thread(self):
        model = code_only(read("App", "Albumist", "Model", "AppModel.swift"))
        self.assertIn("nonisolated static func databaseURL()", model)
        load = model[model.index("private func load() async"):]
        load = load[:load.index("\n    }\n")]
        calls = [m.start() for m in re.finditer(r"Self\.databaseURL\(\)", load)]
        self.assertEqual(len(calls), 1, "load() calls databaseURL() once")
        before = load[max(0, calls[0] - 80):calls[0]]
        self.assertIn("Task.detached", before)


if __name__ == "__main__":
    unittest.main()
