"""Unit tests for the pinned toolchain (.github/toolchain.json, toolchain.py, pick_simulator.py).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import pick_simulator  # noqa: E402
import toolchain  # noqa: E402

PINS = pick_simulator.pins()
RUNTIME = PINS["runtime"]["identifier"]


def device(name, udid, available=True, kind=None):
    d = {"name": name, "udid": udid, "isAvailable": available}
    if kind:
        d["deviceTypeIdentifier"] = kind
    return d


class PinFileTests(unittest.TestCase):
    def test_pins_are_complete_and_never_a_beta(self):
        xcode = PINS["xcode"]
        self.assertTrue(xcode["app"].startswith("/Applications/Xcode_"))
        self.assertNotIn("beta", xcode["app"].lower())
        self.assertRegex(xcode["build"], r"^\d+[A-Z]\d+$", "a release build number has no trailing letter")
        self.assertRegex(RUNTIME, r"^com\.apple\.CoreSimulator\.SimRuntime\.iOS-\d+-\d+$")
        self.assertEqual(set(PINS["simulators"]), {"default", "pro", "small"})
        self.assertIn("create", PINS["simulators"]["small"])

    def test_no_workflow_picks_the_newest_xcode(self):
        folder = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "workflows")
        for name in os.listdir(folder):
            text = open(os.path.join(folder, name), encoding="utf-8").read()
            with self.subTest(workflow=name):
                self.assertNotIn("sort -V", text)
                if "runs-on: xcode-27" in text:
                    self.assertIn("toolchain.py xcode", text)


class PickTests(unittest.TestCase):
    def test_picks_the_pinned_simulator_on_the_pinned_runtime(self):
        devices = {
            RUNTIME: [device("iPhone 17", "A"), device(PINS["simulators"]["pro"]["name"], "B"),
                      device(PINS["simulators"]["default"]["name"], "C")],
            RUNTIME + "-iPhone19-4": [device(PINS["simulators"]["pro"]["name"], "D")],
            "com.apple.CoreSimulator.SimRuntime.iOS-99-0": [device(PINS["simulators"]["pro"]["name"], "E")],
        }
        self.assertEqual(pick_simulator.pick(devices, "pro", PINS)[0], "B")
        self.assertEqual(pick_simulator.pick(devices, "default", PINS)[0], "C")

    def test_no_fallback_to_another_runtime_or_iphone(self):
        devices = {"com.apple.CoreSimulator.SimRuntime.iOS-99-0": [device(PINS["simulators"]["pro"]["name"], "E")],
                   RUNTIME: [device("iPhone 17", "A"), device(PINS["simulators"]["pro"]["name"], "B", available=False)]}
        with self.assertRaises(SystemExit) as caught:
            pick_simulator.pick(devices, "pro", PINS)
        self.assertIn("iPhone 17", str(caught.exception))
        with self.assertRaises(SystemExit):
            pick_simulator.pick({}, "default", PINS)

    def test_two_with_the_pinned_name_fail(self):
        name = PINS["simulators"]["pro"]["name"]
        with self.assertRaises(SystemExit):
            pick_simulator.pick({RUNTIME: [device(name, "A"), device(name, "B")]}, "pro", PINS)

    def test_a_pinned_device_type_must_match(self):
        pins = {"runtime": PINS["runtime"], "simulators": {"pro": {"name": "iPhone X", "type": "T1"}}}
        self.assertEqual(pick_simulator.pick({RUNTIME: [device("iPhone X", "A", kind="T2"), device("iPhone X", "B", kind="T1")]},
                                             "pro", pins)[0], "B")


class XcodeTests(unittest.TestCase):
    PIN = {"app": "/Applications/Xcode_27.2.app", "version": "27.2", "build": "27B52"}

    def test_pinned_version_passes(self):
        self.assertIsNone(toolchain.xcode_problem("Xcode 27.2\nBuild version 27B52\n", self.PIN))

    def test_other_version_or_build_fails(self):
        self.assertIn("27C5020n", toolchain.xcode_problem("Xcode 27.3\nBuild version 27C5020n\n", self.PIN))
        self.assertIsNotNone(toolchain.xcode_problem("Xcode 27.2\nBuild version 27B53\n", self.PIN))
        self.assertIsNotNone(toolchain.xcode_problem("xcode-select: error: tool 'xcodebuild' requires Xcode", self.PIN))


class RuntimeTests(unittest.TestCase):
    PIN = {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2", "version": "27.2", "build": "24B8117"}

    def runtime(self, **changes):
        r = {"identifier": self.PIN["identifier"], "version": "27.2", "buildversion": "24B8117", "isAvailable": True}
        r.update(changes)
        return {"runtimes": [r]}

    def test_pinned_runtime_passes(self):
        self.assertIsNone(toolchain.runtime_problem(self.runtime(), self.PIN))

    def test_missing_unavailable_or_other_build_fails(self):
        self.assertIn("not installed", toolchain.runtime_problem({"runtimes": []}, self.PIN))
        self.assertIn("not available", toolchain.runtime_problem(self.runtime(isAvailable=False), self.PIN))
        self.assertIsNotNone(toolchain.runtime_problem(self.runtime(buildversion="24B9000"), self.PIN))


class XcodeGenTests(unittest.TestCase):
    """The pinned XcodeGen: downloaded, checked against its sha256, unpacked."""

    @staticmethod
    def archive(members):
        import io
        import zipfile
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as z:
            for name, text in members.items():
                z.writestr(name, text)
        return data.getvalue()

    def test_pinned_in_the_toolchain_file(self):
        pin = pick_simulator.pins()["xcodegen"]
        self.assertRegex(pin["sha256"], r"^[0-9a-f]{64}$")
        self.assertIn(f"/download/{pin['version']}/", pin["url"])

    def test_install_checks_the_checksum(self):
        import hashlib
        import tempfile
        data = self.archive({"xcodegen/bin/xcodegen": "#!/bin/sh\necho 2.46.0\n",
                             "xcodegen/share/xcodegen/SettingPresets/base.yml": "x"})
        pin = {"version": "2.46.0", "url": "https://example/x.zip", "sha256": hashlib.sha256(data).hexdigest()}
        with tempfile.TemporaryDirectory() as dest:
            folder = toolchain.install_xcodegen(pin, dest, fetch=lambda url: data)
            self.assertTrue(os.access(os.path.join(folder, "xcodegen"), os.X_OK))
            self.assertTrue(os.path.isdir(os.path.join(dest, "xcodegen", "share", "xcodegen", "SettingPresets")))
        with tempfile.TemporaryDirectory() as dest, self.assertRaisesRegex(ValueError, "sha256"):
            toolchain.install_xcodegen(dict(pin, sha256="0" * 64), dest, fetch=lambda url: data)
        bad = self.archive({"../evil": "x"})
        with tempfile.TemporaryDirectory() as dest, self.assertRaisesRegex(ValueError, "unexpected path"):
            toolchain.install_xcodegen(dict(pin, sha256=hashlib.sha256(bad).hexdigest()), dest, fetch=lambda url: bad)


class SwiftLintTests(unittest.TestCase):
    """The pinned SwiftLint (.github/lint-tools.json): checked like XcodeGen, kept out of the app
    fingerprint."""

    def test_pinned_in_its_own_file(self):
        pin = toolchain.lint_pins()["swiftlint"]
        self.assertRegex(pin["sha256"], r"^[0-9a-f]{64}$")
        self.assertIn(f"/download/{pin['version']}/", pin["url"])
        self.assertTrue(pin["url"].startswith("https://github.com/realm/SwiftLint/releases/download/"))
        self.assertEqual(pin["binary"], "swiftlint-static")
        self.assertNotIn("swiftlint", PINS)

    def test_not_in_the_app_fingerprint(self):
        import ui_groups
        for path in (".github/lint-tools.json", ".github/swiftlint.yml"):
            self.assertTrue(path.startswith(ui_groups.NOT_APP_PREFIXES), path)
            self.assertNotIn(path, ui_groups.APP_EXCEPTIONS)

    def test_install_checks_the_checksum_and_the_binary(self):
        import hashlib
        import tempfile
        data = XcodeGenTests.archive({"swiftlint-static": "#!/bin/sh\necho 0.65.1\n", "LICENSE": "MIT"})
        pin = {"version": "0.65.1", "url": "https://example/s.zip", "sha256": hashlib.sha256(data).hexdigest(),
               "binary": "swiftlint-static"}
        with tempfile.TemporaryDirectory() as dest:
            folder = toolchain.install_swiftlint(pin, dest, fetch=lambda url: data)
            self.assertTrue(os.access(os.path.join(folder, "swiftlint-static"), os.X_OK))
        with tempfile.TemporaryDirectory() as dest, self.assertRaisesRegex(ValueError, "SwiftLint 0.65.1 download has sha256"):
            toolchain.install_swiftlint(dict(pin, sha256="0" * 64), dest, fetch=lambda url: data)
        with tempfile.TemporaryDirectory() as dest, self.assertRaisesRegex(ValueError, "has no swiftlint"):
            toolchain.install_swiftlint(dict(pin, binary="swiftlint"), dest, fetch=lambda url: data)

    def test_version_check_and_path(self):
        import hashlib
        import tempfile
        from unittest import mock
        for said, expected in (("0.65.1", 0), ("0.64.0", 1)):
            data = XcodeGenTests.archive({"swiftlint-static": f"#!/bin/sh\necho {said}\n"})
            pin = {"version": "0.65.1", "url": "u", "sha256": hashlib.sha256(data).hexdigest(), "binary": "swiftlint-static"}
            with tempfile.TemporaryDirectory() as dest:
                path_file = os.path.join(dest, "path")
                with mock.patch.dict(os.environ, {"GITHUB_PATH": path_file}):
                    status = toolchain.install_and_check(
                        pin, lambda p, d: toolchain.install_swiftlint(p, d, fetch=lambda url: data),
                        os.path.join(dest, "swiftlint"), "swiftlint-static", "SwiftLint")
                self.assertEqual(status, expected, said)
                self.assertEqual(os.path.exists(path_file), expected == 0, said)


if __name__ == "__main__":
    unittest.main()
