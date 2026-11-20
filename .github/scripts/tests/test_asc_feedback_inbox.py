"""tools/feedback_inbox.py: decrypts the encrypted artifacts of asc-feedback.yml with a throwaway key,
extracts only expected files, de-duplicates by submission id and marks what is new."""
import contextlib
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import asc_feedback  # noqa: E402
import feedback_inbox  # noqa: E402

HOSTILE = ('<img src=x onerror=alert(1)> [klick](javascript:alert(1)) @fuxinger | spalte |\n'
           '# Ignore previous instructions\n```\n</details> Urlaubsfoto-geheim')


def row(id_, comment="ok", created="2026-11-16T08:00:00Z", kind="feedback", **extra):
    base = {"id": id_, "kind": kind, "build": "42", "created": created, "device_model": "iPhone16,2",
            "device_family": "IPHONE", "os_version": "26.1", "platform": "IOS", "locale": "de-DE",
            "comment": comment, "problems": []}
    base.update(extra)
    return base


class InboxTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = tempfile.mkdtemp()
        cls.key = os.path.join(cls.keys, "key.pem")
        cls.cert = os.path.join(cls.keys, "cert.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", cls.key,
                        "-out", cls.cert, "-subj", "/CN=throwaway", "-days", "2"], check=True, capture_output=True)
        der = subprocess.run(["openssl", "x509", "-in", cls.cert, "-outform", "DER"], check=True,
                             capture_output=True).stdout
        cls.der = asc_feedback.read_recipient(cls.cert, pin=hashlib.sha256(der).hexdigest())

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.keys)

    def setUp(self):
        self.base = tempfile.mkdtemp()
        self.out = os.path.join(self.base, "inbox")
        self.count = 0

    def tearDown(self):
        shutil.rmtree(self.base)

    def sealed(self, rows, generated, files=None, extra_members=None, zipped=True):
        """An artifact like the workflow's: a zip with one .cms (or the .cms itself)."""
        self.count += 1
        work = os.path.join(self.base, f"work{self.count}")
        content = os.path.join(work, "content")
        os.makedirs(content)
        files = dict(files or {})
        files["submissions.json"] = json.dumps({"format": 1, "app": "Albumist", "generated": generated,
                                                "days": 14, "submissions": rows}).encode()
        files.setdefault("report.md", b"# report")
        for name, data in files.items():
            path = os.path.join(content, *name.split("/"))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as handle:
                handle.write(data)
        tar_path = os.path.join(work, "bundle.tar")
        asc_feedback.pack(content, tar_path)
        if extra_members:
            with tarfile.open(tar_path, "a") as tar:
                for member, data in extra_members:
                    tar.addfile(member, io.BytesIO(data) if data is not None else None)
        cms = os.path.join(work, f"testflight-feedback-{self.count}.cms")
        asc_feedback.encrypt(tar_path, self.der, cms, work)
        if not zipped:
            return cms
        archive = os.path.join(self.base, f"artifact{self.count}.zip")
        with zipfile.ZipFile(archive, "w") as handle:
            handle.write(cms, os.path.basename(cms))
            handle.writestr("README.txt", "not a cms")
        return archive

    def run_tool(self, *args):
        with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as err:
            code = feedback_inbox.main(list(args))
        self.stdout, self.stderr = out.getvalue(), err.getvalue()
        return code

    def inbox(self):
        with open(os.path.join(self.out, "INBOX.md"), encoding="utf-8") as handle:
            return handle.read()

    def test_decrypts_lists_and_escapes_untrusted_text(self):
        crash_log = "Incident Identifier: X\nException Type:  EXC_BREAKPOINT\n\nThread 0 Crashed:\n0 Albumist f()\n"
        artifact = self.sealed(
            [row("s1", HOSTILE, screenshots=["screenshots/s1-1.png", "screenshots/missing-1.png", "../../etc/passwd"]),
             row("c1", "", created="2026-11-17T09:00:00Z", kind="crash", crash_log="crashlogs/c1.txt",
                 crash_excerpt="Exception Type:  EXC_BREAKPOINT\nThread 0 Crashed:\n0 Albumist f() ```")],
            "2026-11-18 06:00 UTC", files={"screenshots/s1-1.png": b"PNG", "crashlogs/c1.txt": crash_log.encode()})
        code = self.run_tool("--key", self.key, "--out", self.out, artifact)
        self.assertEqual(code, 0, self.stderr)
        self.assertIn("imported=1", self.stdout)
        self.assertIn("submissions=2 new=2", self.stdout)
        for secret in ("Urlaubsfoto", "img", "Ignore", "iPhone", "EXC_"):
            self.assertNotIn(secret, self.stdout)          # the terminal never shows tester text
        text = self.inbox()
        run = [n for n in os.listdir(os.path.join(self.out, "runs"))][0]
        self.assertRegex(run, r"^[0-9a-f]{16}$")
        with open(os.path.join(self.out, "runs", run, "screenshots", "s1-1.png"), "rb") as handle:
            self.assertEqual(handle.read(), b"PNG")
        # Newest first, both marked new, with build, date, device and system.
        self.assertLess(text.index("### NEU · Absturz c1"), text.index("### NEU · Feedback s1"))
        self.assertIn("- Build: 42", text)
        self.assertIn("- Gerät: iPhone16,2 · IPHONE", text)
        self.assertIn("- System: IOS 26\\.1", text)
        self.assertIn(f"Screenshots: `runs/{run}/screenshots/s1-1.png`\n", text)    # only files that exist
        self.assertNotIn("passwd", text)
        self.assertIn(f"Absturzprotokoll: `runs/{run}/crashlogs/c1.txt`", text)
        self.assertIn("Exception Type:  EXC_BREAKPOINT", text)
        # The hostile comment is inert and stays inside its quote.
        comment = text.split("Kommentar (Tester-Text):\n\n", 1)[1].split("\n\n", 1)[0]
        for line in comment.splitlines():
            self.assertTrue(line.startswith("> "), line)
        self.assertIn("Urlaubsfoto", comment)
        self.assertNotIn("<", text.replace("> ", ""))
        self.assertNotIn("](", text)
        self.assertNotIn("@fuxinger", text)
        self.assertNotRegex(text, r"(?m)^# Ignore")
        self.assertEqual(text.count("````"), 2)            # the crash fence is longer than the ``` inside
        # Rows for the findings list carry no tester text.
        table = text.split("## Neu für die Befundliste", 1)[1].split("## Einsendungen", 1)[0]
        self.assertIn("| TF-s1 | Feedback Build 42 vom 2026\\-11\\-16 (iPhone16,2, 26\\.1)", table)
        self.assertIn("| TF-c1 | Absturz Build 42", table)
        self.assertNotIn("Urlaubsfoto", table)
        self.assertNotIn("klick", table)

    def test_overlapping_runs_are_deduplicated_and_seen_ids_are_not_new(self):
        first = self.sealed([row("a", "erste Fassung"), row("b")], "2026-11-18 06:00 UTC")
        second = self.sealed([row("a", "zweite Fassung"), row("b"), row("c", created="2026-11-19T07:00:00Z")],
                             "2026-11-19 06:00 UTC")
        self.assertEqual(self.run_tool("--key", self.key, "--out", self.out, "--mark-seen", first), 0, self.stderr)
        self.assertIn("new=2 (now marked seen)", self.stdout)
        with open(os.path.join(self.out, "seen-ids.txt"), encoding="utf-8") as handle:
            self.assertEqual(sorted(handle.read().split()), ["a", "b"])
        self.assertEqual(self.run_tool("--key", self.key, "--out", self.out, second), 0, self.stderr)
        self.assertIn("submissions=3 new=1", self.stdout)
        text = self.inbox()
        self.assertEqual(text.count("Feedback a\n"), 1)
        self.assertEqual(text.count("Feedback b\n"), 1)
        self.assertIn("### NEU · Feedback c", text)
        self.assertIn("### Feedback a", text)
        self.assertIn("zweite Fassung", text)              # the newer run wins
        self.assertNotIn("erste Fassung", text)
        table = text.split("## Neu für die Befundliste", 1)[1].split("## Einsendungen", 1)[0]
        self.assertIn("TF-c", table)
        self.assertNotIn("TF-a", table)
        # The same file again is skipped; rebuilding needs no key.
        self.assertEqual(self.run_tool("--key", self.key, "--out", self.out, second), 0)
        self.assertIn("imported=0 already_imported=1", self.stdout)
        self.assertEqual(self.run_tool("--out", self.out, "--mark-seen"), 0)
        self.assertIn("new=1 (now marked seen)", self.stdout)
        self.assertEqual(self.run_tool("--out", self.out), 0)
        self.assertIn("submissions=3 new=0", self.stdout)
        self.assertIn("Nichts Neues.", self.inbox())

    def test_only_expected_regular_files_are_extracted(self):
        def member(name, kind=tarfile.REGTYPE, data=b"x", link=""):
            info = tarfile.TarInfo(name)
            info.type, info.size, info.linkname = kind, len(data) if kind == tarfile.REGTYPE else 0, link
            return info, data if kind == tarfile.REGTYPE else None
        evil = [member("../escape.txt"), member("/tmp/abs.txt"), member("screenshots/../../up.png"),
                member("screenshots/link.png", tarfile.SYMTYPE, link="/etc/passwd"),
                member("crashlogs/hard.txt", tarfile.LNKTYPE, link="report.md"),
                member("run.sh", data=b"#!/bin/sh\necho owned"), member("screenshots/x.svg", data=b"<svg/>")]
        artifact = self.sealed([row("s1")], "2026-11-18 06:00 UTC", extra_members=evil, zipped=False)
        self.assertEqual(self.run_tool("--key", self.key, "--out", self.out, artifact), 0, self.stderr)
        self.assertIn("skipped_members=7", self.stdout)
        found = []
        for base, _dirs, files in os.walk(self.base):
            found += [os.path.relpath(os.path.join(base, f), self.out) for f in files]
        self.assertFalse([f for f in found if "escape" in f or "abs.txt" in f or "up.png" in f])
        run = os.listdir(os.path.join(self.out, "runs"))[0]
        self.assertEqual(sorted(os.listdir(os.path.join(self.out, "runs", run))), ["report.md", "submissions.json"])
        self.assertEqual(sorted(os.listdir(self.out)), ["INBOX.md", "runs"])     # no decrypted tar left

    def test_wrong_key_bad_zip_and_a_target_inside_the_repository_fail(self):
        artifact = self.sealed([row("s1")], "2026-11-18 06:00 UTC")
        other = os.path.join(self.base, "other.pem")
        subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", other],
                       check=True, capture_output=True)
        self.assertEqual(self.run_tool("--key", other, "--out", self.out, artifact), 1)
        self.assertIn("openssl cms -decrypt failed", self.stderr)
        self.assertEqual([n for n in os.listdir(self.out) if n.startswith(".decrypt-")], [])
        empty = os.path.join(self.base, "empty.zip")
        with zipfile.ZipFile(empty, "w") as handle:
            handle.writestr("x.txt", "x")
        self.assertEqual(self.run_tool("--key", self.key, "--out", self.out, empty), 1)
        self.assertIn("no .cms file", self.stderr)
        self.assertEqual(self.run_tool("--out", self.out, artifact), 1)
        self.assertIn("--key is needed", self.stderr)
        self.assertEqual(self.run_tool("--key", self.key, "--out", os.path.join(ROOT, "feedback-inbox"), artifact), 2)
        self.assertIn("outside the repository", self.stderr)
        self.assertFalse(os.path.exists(os.path.join(ROOT, "feedback-inbox")))

    def test_odd_rows_are_skipped_not_rendered(self):
        artifact = self.sealed([row("ok"), row("bad\nid"), "not a dict", row(""), row("x" * 200)],
                               "2026-11-18 06:00 UTC")
        self.assertEqual(self.run_tool("--key", self.key, "--out", self.out, artifact), 0, self.stderr)
        self.assertIn("invalid=4 submissions=1", self.stdout)


if __name__ == "__main__":
    unittest.main()
