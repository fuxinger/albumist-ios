"""Mode encrypted of .github/scripts/asc_feedback.py: certificate pin, encryption round trip with a
throwaway key, plaintext wiped, mode gating, nothing of the testers in the summary or the log."""
import contextlib
import datetime
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import asc_feedback  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
API = asc_feedback.API
HOSTILE = ('<img src=x onerror=alert(1)> [klick](javascript:alert(1)) @fuxinger | spalte |\n'
           '::error::fake\n```\nUrlaubsfoto-geheim')


def make_identity(folder, name="t"):
    """A throwaway RSA key and self-signed certificate; returns (key, cert, pin)."""
    key, cert = os.path.join(folder, f"{name}-key.pem"), os.path.join(folder, f"{name}-cert.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                    "-subj", "/CN=throwaway test recipient", "-days", "2"], check=True, capture_output=True)
    der = subprocess.run(["openssl", "x509", "-in", cert, "-outform", "DER"], check=True, capture_output=True).stdout
    return key, cert, hashlib.sha256(der).hexdigest()


def decrypt(cms, key, out_tar):
    subprocess.run(["openssl", "cms", "-decrypt", "-binary", "-inform", "DER", "-in", cms, "-inkey", key,
                    "-out", out_tar], check=True, capture_output=True)


def submission(id_, comment="ok", created="2026-11-16T08:00:00Z"):
    return {"type": "x", "id": id_, "attributes": {"createdDate": created, "comment": comment,
                                                   "deviceModel": "iPhone16,2", "deviceFamily": "IPHONE",
                                                   "osVersion": "26.1", "appPlatform": "IOS", "locale": "de-DE"},
            "relationships": {"build": {"data": {"type": "builds", "id": "b1"}}}}


BUILD = {"type": "builds", "id": "b1", "attributes": {"version": "42"}}


class Identity(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        cls.key, cls.cert, cls.pin = make_identity(cls.dir)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir)


class RecipientTests(Identity):
    def test_the_pinned_certificate_is_accepted(self):
        der = asc_feedback.read_recipient(self.cert, pin=asc_feedback.colon_hex(self.pin))
        self.assertEqual(hashlib.sha256(der).hexdigest(), self.pin)

    def test_another_certificate_fails_loudly(self):
        other_key, other_cert, other_pin = make_identity(self.dir, "other")
        with self.assertRaises(asc_feedback.RecipientError) as caught:
            asc_feedback.read_recipient(other_cert, pin=self.pin)
        message = str(caught.exception)
        self.assertIn("not the pinned", message)
        self.assertIn(asc_feedback.colon_hex(other_pin), message)
        self.assertIn(asc_feedback.colon_hex(self.pin), message)
        # The default pin is the committed recipient's, not a throwaway one.
        with self.assertRaises(asc_feedback.RecipientError):
            asc_feedback.read_recipient(self.cert)

    def test_a_key_a_second_certificate_or_garbage_is_refused(self):
        with open(self.cert, encoding="ascii") as handle:
            cert = handle.read()
        with open(self.key, encoding="ascii") as handle:
            key = handle.read()
        for name, content in (("with-key.pem", cert + key), ("two.pem", cert + cert), ("key.pem", key),
                              ("empty.pem", ""), ("bin.pem", "\xff\xfe")):
            path = os.path.join(self.dir, name)
            with open(path, "w", encoding="latin-1") as handle:
                handle.write(content)
            with self.subTest(name), self.assertRaises(asc_feedback.RecipientError):
                asc_feedback.read_recipient(path, pin=self.pin)
        with self.assertRaises(asc_feedback.RecipientError):
            asc_feedback.read_recipient(os.path.join(self.dir, "missing.pem"), pin=self.pin)
        with self.assertRaises(asc_feedback.RecipientError):     # an empty or short pin never matches
            asc_feedback.read_recipient(self.cert, pin="")

    def test_the_committed_certificate_matches_the_pin_and_holds_no_key(self):
        path = os.path.join(ROOT, ".github", "feedback-recipient.pem")
        der = asc_feedback.read_recipient(path)
        self.assertEqual(asc_feedback.colon_hex(hashlib.sha256(der).hexdigest()), asc_feedback.RECIPIENT_SHA256)
        self.assertEqual(asc_feedback.RECIPIENT_SHA256,
                         "6F:83:13:57:47:66:2F:98:64:76:CE:49:36:60:1C:21:6C:08:2D:8D:85:54:42:2B:22:02:6B:5B:8A:76:32:36")
        printed = subprocess.run(["openssl", "x509", "-in", path, "-noout", "-fingerprint", "-sha256"],
                                 check=True, capture_output=True, text=True).stdout
        self.assertIn(asc_feedback.RECIPIENT_SHA256, printed)
        with open(path, encoding="ascii") as handle:
            self.assertNotIn("PRIVATE", handle.read())
        # No private key anywhere under .github or tools.
        for folder in (".github", "tools"):
            for base, _dirs, files in os.walk(os.path.join(ROOT, folder)):
                for name in files:
                    if name.endswith((".pem", ".key", ".p8", ".p12")):
                        with open(os.path.join(base, name), encoding="latin-1") as handle:
                            self.assertNotIn("PRIVATE KEY-----", handle.read(), name)


class EncryptTests(Identity):
    def setUp(self):
        self.work = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.work)

    def test_round_trip_with_oaep_sha256_and_aes_256(self):
        content = os.path.join(self.work, "content")
        os.makedirs(os.path.join(content, "screenshots"))
        files = {"report.md": b"# Bericht\n", "screenshots/s1-1.png": bytes(range(256)) * 50}
        for name, data in files.items():
            with open(os.path.join(content, name), "wb") as handle:
                handle.write(data)
        tar_path, cms = os.path.join(self.work, "bundle.tar"), os.path.join(self.work, "out.cms")
        asc_feedback.pack(content, tar_path)
        der = asc_feedback.read_recipient(self.cert, pin=self.pin)
        asc_feedback.encrypt(tar_path, der, cms, self.work)
        with open(cms, "rb") as handle:
            sealed = handle.read()
        self.assertNotIn(b"Bericht", sealed)
        self.assertNotIn(bytes(range(256)), sealed)
        printed = subprocess.run(["openssl", "cms", "-cmsout", "-print", "-inform", "DER", "-in", cms],
                                 check=True, capture_output=True, text=True).stdout
        self.assertIn("rsaesOaep", printed)
        self.assertIn("aes-256-cbc", printed)
        self.assertIn(":sha256", printed)                     # OAEP hash and MGF1 hash
        self.assertNotIn("sha1", printed.lower())
        back = os.path.join(self.work, "back.tar")
        decrypt(cms, self.key, back)
        with tarfile.open(back) as tar:
            self.assertEqual(sorted(tar.getnames()), sorted(files))
            for name, data in files.items():
                self.assertEqual(tar.extractfile(name).read(), data)
            self.assertTrue(all(m.uname == "" and m.uid == 0 for m in tar.getmembers()))

    def test_the_algorithm_check_reads_only_the_head_and_refuses_sha1_or_pkcs1(self):
        tar_path = os.path.join(self.work, "bundle.tar")
        with open(tar_path, "wb") as handle:
            handle.write(b"x" * 100_000)
        for name, options, problem in (
                ("sha1", ["-keyopt", "rsa_padding_mode:oaep"], "OAEP without SHA-256"),
                ("pkcs1", [], "no RSA-OAEP"),
                ("aes128", ["-keyopt", "rsa_padding_mode:oaep", "-keyopt", "rsa_oaep_md:sha256"], "no AES-256-CBC")):
            cms = os.path.join(self.work, f"{name}.cms")
            cipher = "-aes-128-cbc" if name == "aes128" else "-aes-256-cbc"
            subprocess.run(["openssl", "cms", "-encrypt", "-binary", cipher, "-in", tar_path, "-outform", "DER",
                            "-out", cms, "-recip", self.cert] + options, check=True, capture_output=True)
            with open(cms, "rb") as handle:
                with self.subTest(name):
                    self.assertIn(problem, asc_feedback.check_sealed(handle.read(asc_feedback.HEAD_BYTES)))
        self.assertIn("not a DER file", asc_feedback.check_sealed(b"-----BEGIN CMS-----"))
        good = os.path.join(self.work, "good.cms")
        asc_feedback.encrypt(tar_path, asc_feedback.read_recipient(self.cert, pin=self.pin), good, self.work)
        with open(good, "rb") as handle:
            self.assertEqual(asc_feedback.check_sealed(handle.read(asc_feedback.HEAD_BYTES)), [])

    def test_a_failing_openssl_leaves_no_output(self):
        tar_path, cms = os.path.join(self.work, "bundle.tar"), os.path.join(self.work, "out.cms")
        with open(tar_path, "wb") as handle:
            handle.write(b"x")
        with self.assertRaises(asc_feedback.EncryptError):
            asc_feedback.encrypt(tar_path, b"not a certificate", cms, self.work)
        self.assertFalse(os.path.exists(cms))
        with self.assertRaises(asc_feedback.EncryptError):
            asc_feedback.encrypt(tar_path, asc_feedback.read_recipient(self.cert, pin=self.pin), cms, self.work,
                                 openssl=os.path.join(self.work, "no-openssl"))

    def test_wipe_overwrites_and_removes(self):
        folder = os.path.join(self.work, "plain")
        os.makedirs(os.path.join(folder, "sub"))
        path = os.path.join(folder, "sub", "a.txt")
        with open(path, "wb") as handle:
            handle.write(b"secret" * 1000)
        written = []
        real_open = open

        def spy(file, mode="r", *args, **kwargs):
            handle = real_open(file, mode, *args, **kwargs)
            if mode == "r+b":
                original = handle.write
                handle.write = lambda data: written.append(set(data)) or original(data)
            return handle
        with mock.patch("builtins.open", spy):
            asc_feedback.wipe(folder)
        self.assertFalse(os.path.exists(folder))
        self.assertEqual(written, [{0}])


class WindowTests(unittest.TestCase):
    def test_only_the_last_days_are_fetched_and_paging_stops_there(self):
        since = datetime.datetime(2026, 11, 6, tzinfo=datetime.timezone.utc)
        page1 = {"data": [submission("new1", created="2026-11-19T10:00:00.000Z"),
                          submission("new2", created="2026-11-06T00:00:01+00:00")],
                 "included": [BUILD], "links": {"next": f"{API}/v1/apps/123/betaFeedbackCrashSubmissions?cursor=2"}}
        page2 = {"data": [submission("old", created="2026-11-05T23:59:59Z"), submission("older")],
                 "links": {"next": f"{API}/v1/apps/123/betaFeedbackCrashSubmissions?cursor=3"}}
        calls = []

        def transport(method, url, headers):
            calls.append(url)
            if "/crashLog" in url:
                return 200, {}, json.dumps({"data": {"attributes": {"logText": "Thread 0 Crashed:"}}}).encode()
            if url.startswith(f"{API}/v1/apps?"):
                return 200, {}, json.dumps({"data": [{"id": "123", "attributes": {"bundleId": "b"}}]}).encode()
            if "cursor=2" in url:
                return 200, {}, json.dumps(page2).encode()
            if "cursor=3" in url:
                raise AssertionError("paging went past the window")
            if "Screenshot" in url:
                return 200, {}, json.dumps({"data": [], "links": {}}).encode()
            return 200, {}, json.dumps(page1).encode()
        client = asc_feedback.Client(lambda: "T", transport=transport, mask=lambda t: None, sleep=lambda s: None)
        out = tempfile.mkdtemp()
        try:
            _, shots, crashes, errors, _, _ = asc_feedback.fetch(client, "b", out, 200, full=True, since=since)
        finally:
            shutil.rmtree(out)
        self.assertEqual(errors, [])
        self.assertEqual([e["item"]["id"] for e in crashes], ["new1", "new2"])
        self.assertEqual(sorted(u.split("/")[-2] for u in calls if "/crashLog" in u), ["new1", "new2"])

    def test_an_unreadable_date_never_stops_the_list(self):
        stop = asc_feedback.older_than(datetime.datetime(2026, 11, 6, tzinfo=datetime.timezone.utc))
        self.assertFalse(stop(submission("x", created="gestern")))
        self.assertFalse(stop(submission("x", created=None)))
        self.assertTrue(stop(submission("x", created="2026-11-01T00:00:00Z")))
        self.assertFalse(asc_feedback.older_than(None)(submission("x", created="2000-01-01T00:00:00Z")))


class MainEncryptedTests(Identity):
    """main() in mode encrypted with a faked fetch that writes what the real one would."""

    def setUp(self):
        self.base = tempfile.mkdtemp()
        self.runner_temp = os.path.join(self.base, "runner-temp")
        os.makedirs(self.runner_temp)
        self.sealed_dir = os.path.join(self.runner_temp, "feedback-encrypted")
        self.summary = os.path.join(self.base, "summary.md")
        self.output = os.path.join(self.base, "output")

    def tearDown(self):
        shutil.rmtree(self.base)

    def fake_fetch(self, client, bundle_id, out_dir, max_items, full=False, since=None, **_):
        self.fetch_args = {"out_dir": out_dir, "full": full, "since": since}
        if not full:
            return "Albumist (app.albumist.ios)", [], [], [], False, {}
        os.makedirs(os.path.join(out_dir, "screenshots"), exist_ok=True)
        os.makedirs(os.path.join(out_dir, "crashlogs"), exist_ok=True)
        with open(os.path.join(out_dir, "screenshots", "s1-1.png"), "wb") as handle:
            handle.write(b"PNG-of-a-private-holiday")
        with open(os.path.join(out_dir, "crashlogs", "c1.txt"), "w", encoding="utf-8") as handle:
            handle.write("Thread 0 Crashed:\n0 Albumist Secret.frame()\n")
        shot = {"item": submission("s1", comment=HOSTILE), "included": {("builds", "b1"): BUILD},
                "files": ["screenshots/s1-1.png"], "problems": []}
        crash = {"item": submission("c1", comment="Absturz beim Teilen"), "included": {("builds", "b1"): BUILD},
                 "file": "crashlogs/c1.txt", "excerpt": "Thread 0 Crashed:\n0 Albumist Secret.frame()",
                 "problems": []}
        return "Albumist (app.albumist.ios)", [shot], [crash], [], False, {"screenshots": 99, "crashes": 99}

    def run_main(self, args, pin=None, github=(200, {"private": False}), fetch=None):
        github_calls = []

        def transport(method, url, headers):
            github_calls.append(url)
            return github[0], {}, json.dumps(github[1]).encode()
        env = {"GITHUB_REPOSITORY": "fuxinger/sortly-ios", "GH_TOKEN": "t", "KEY_ID": "k", "ISSUER_ID": "i",
               "KEY_PATH": os.path.join(self.base, "missing.p8"), "GITHUB_OUTPUT": self.output,
               "RUNNER_TEMP": self.runner_temp}
        fetch_mock = mock.Mock(side_effect=fetch or self.fake_fetch)
        with mock.patch.dict(os.environ, env), \
                mock.patch.object(asc_feedback, "RECIPIENT_SHA256", pin or asc_feedback.colon_hex(self.pin)), \
                mock.patch.object(asc_feedback, "urllib_transport", transport), \
                mock.patch.object(asc_feedback, "fetch", fetch_mock), \
                contextlib.redirect_stdout(io.StringIO()) as log:
            code = asc_feedback.main(args + ["--recipient", self.cert, "--encrypted-out", self.sealed_dir,
                                             "--out", os.path.join(self.runner_temp, "feedback"),
                                             "--summary", self.summary])
        self.log, self.github_calls, self.fetch_mock = log.getvalue(), github_calls, fetch_mock
        return code

    def read(self, path):
        if not os.path.exists(path):
            return ""
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    def test_encrypted_runs_on_a_public_repository_and_only_the_cms_remains(self):
        code = self.run_main(["--mode", "encrypted", "--days", "14"])
        self.assertEqual(code, 0, self.log)
        self.assertEqual(self.github_calls, [])                      # no visibility question needed
        self.assertTrue(self.fetch_args["full"])
        self.assertTrue(self.fetch_args["out_dir"].startswith(os.path.join(self.runner_temp, "feedback-plain-")))
        age = datetime.datetime.now(datetime.timezone.utc) - self.fetch_args["since"]
        self.assertAlmostEqual(age.total_seconds(), 14 * 86400, delta=120)
        self.assertIn("mode=encrypted", self.read(self.output).splitlines())
        # Plaintext gone; under RUNNER_TEMP only the folder with the one .cms file.
        self.assertEqual(os.listdir(self.runner_temp), ["feedback-encrypted"])
        sealed = os.listdir(self.sealed_dir)
        self.assertEqual(len(sealed), 1)
        self.assertRegex(sealed[0], r"^testflight-feedback-\d{8}-\d{6}\.cms$")
        with open(os.path.join(self.sealed_dir, sealed[0]), "rb") as handle:
            blob = handle.read()
        for secret in (b"Urlaubsfoto", b"PNG-of-a-private-holiday", b"Secret.frame", b"Teilen"):
            self.assertNotIn(secret, blob)
        # Summary and log: counts only.
        summary = self.read(self.summary)
        self.assertIn("| 42 | 1 | 1 |", summary)
        self.assertIn("1 Feedback mit Screenshot · 1 Absturzberichte", summary)   # not Apple's all-time 99
        self.assertIn("letzten 14 Tage", summary)
        self.assertIn("testflight-feedback-encrypted", summary)
        for text in (summary, self.log):
            for secret in ("Urlaubsfoto", "img", "javascript", "@fuxinger", "::error::fake", "Teilen",
                           "Secret.frame", "s1-1.png", "iPhone", "s1", "c1"):
                self.assertNotIn(secret, text.replace("mode=encrypted", ""))
        self.assertNotIn("::error", self.log)
        # Decrypted with the throwaway key: everything is there.
        back = os.path.join(self.base, "back.tar")
        decrypt(os.path.join(self.sealed_dir, sealed[0]), self.key, back)
        with tarfile.open(back) as tar:
            names = sorted(tar.getnames())
            self.assertEqual(names, ["crashlogs/c1.txt", "report.md", "screenshots/s1-1.png", "submissions.json"])
            self.assertEqual(tar.extractfile("screenshots/s1-1.png").read(), b"PNG-of-a-private-holiday")
            report = tar.extractfile("report.md").read().decode()
            index = json.loads(tar.extractfile("submissions.json").read())
        self.assertIn("Urlaubsfoto", report)
        self.assertNotIn("<img", report)
        self.assertEqual(index["format"], 1)
        self.assertEqual(index["days"], 14)
        rows = {row["id"]: row for row in index["submissions"]}
        self.assertEqual(rows["s1"]["comment"], HOSTILE)             # raw: the inbox escapes it
        self.assertEqual(rows["s1"]["screenshots"], ["screenshots/s1-1.png"])
        self.assertEqual(rows["c1"]["crash_log"], "crashlogs/c1.txt")
        self.assertEqual((rows["s1"]["build"], rows["s1"]["device_model"], rows["s1"]["os_version"]),
                         ("42", "iPhone16,2", "26.1"))

    def test_lone_surrogates_and_bidi_marks_from_testers_do_not_break_the_run(self):
        def odd_fetch(client, bundle_id, out_dir, max_items, full=False, since=None, **_):
            result = self.fake_fetch(client, bundle_id, out_dir, max_items, full=full, since=since)
            result[1][0]["item"]["attributes"]["comment"] = "kaputt \ud800 \u202eabc"
            result[1][0]["item"]["attributes"]["deviceModel"] = "iPhone\udfff"
            result[2][0]["excerpt"] = "Thread 0 \ud83d Crashed \u2066x"
            return result
        self.assertEqual(self.run_main(["--mode", "encrypted"], fetch=odd_fetch), 0, self.log)
        sealed = os.path.join(self.sealed_dir, os.listdir(self.sealed_dir)[0])
        back = os.path.join(self.base, "back.tar")
        decrypt(sealed, self.key, back)
        with tarfile.open(back) as tar:
            report = tar.extractfile("report.md").read().decode("utf-8")      # strict UTF-8
            index = json.loads(tar.extractfile("submissions.json").read().decode("ascii"))
        rows = {row["id"]: row for row in index["submissions"]}
        self.assertEqual(rows["s1"]["comment"], "kaputt ? \u202eabc")
        self.assertEqual(rows["s1"]["device_model"], "iPhone?")
        self.assertIn("kaputt ? abc", report)                                  # bidi marks gone
        self.assertNotIn("\u2066", report)
        self.assertNotIn("\u202e", report)
        self.assertNotIn("\u2066", asc_feedback.code_block("a\u2066b\u202ec"))

    def test_a_swapped_certificate_stops_before_anything_is_fetched(self):
        code = self.run_main(["--mode", "encrypted"], pin="00" * 32)
        self.assertEqual(code, 5)
        self.assertIn("not the pinned", self.log)
        self.fetch_mock.assert_not_called()
        self.assertEqual(os.listdir(self.runner_temp), [])
        self.assertEqual(self.read(self.output), "")
        self.assertEqual(self.read(self.summary), "")

    def test_a_failed_encryption_uploads_nothing_and_still_wipes_the_plaintext(self):
        with mock.patch.object(asc_feedback, "encrypt", side_effect=asc_feedback.EncryptError("openssl broke")):
            code = self.run_main(["--mode", "encrypted"])
        self.assertEqual(code, 5)
        self.assertNotIn("mode=", self.read(self.output))
        self.assertFalse([n for n in os.listdir(self.runner_temp) if n.startswith("feedback-plain-")])
        self.assertEqual(os.listdir(self.sealed_dir), [])
        summary = self.read(self.summary)
        self.assertIn("Verschlüsselung\\: openssl broke", summary)
        self.assertNotIn("Details verschlüsselt", summary)
        self.assertNotIn("Urlaubsfoto", summary)

    def test_a_crash_inside_the_run_still_wipes_the_plaintext(self):
        def explode(*args, **kwargs):
            self.fake_fetch(*args, **kwargs)
            raise ZeroDivisionError("unexpected")      # not one of the errors run() reports
        with self.assertRaises(ZeroDivisionError):
            self.run_main(["--mode", "encrypted"], fetch=explode)
        self.assertEqual(os.listdir(self.runner_temp), [])

    def test_the_window_is_bounded(self):
        for days in ("0", "91"):
            self.assertEqual(self.run_main(["--mode", "encrypted", "--days", days]), 5)
        self.fetch_mock.assert_not_called()

    def test_full_is_still_refused_on_a_public_repository(self):
        code = self.run_main(["--mode", "full"])
        self.assertEqual(code, 4)
        self.assertEqual(len(self.github_calls), 1)
        self.fetch_mock.assert_not_called()
        self.assertEqual(os.listdir(self.runner_temp), [])

    def test_counts_writes_nothing_but_the_summary(self):
        code = self.run_main(["--mode", "counts"])
        self.assertEqual(code, 0)
        self.assertFalse(self.fetch_mock.call_args.kwargs["full"])
        self.assertIsNone(self.fetch_mock.call_args.kwargs["since"])
        self.assertEqual(os.listdir(self.runner_temp), [])
        self.assertEqual(self.read(self.output), "")


WORKFLOW = os.path.join(ROOT, ".github", "workflows", "asc-feedback.yml")


def steps(text):
    return {block.split("\n", 1)[0].strip(): block for block in re.split(r"\n      - name: ", text)[1:]}


class WorkflowEncryptedTests(unittest.TestCase):
    def setUp(self):
        with open(WORKFLOW, encoding="utf-8") as handle:
            self.text = handle.read()
        self.steps = steps(self.text)

    def test_the_schedule_and_the_default_are_encrypted(self):
        self.assertIn("options: [encrypted, counts, full]", self.text)
        self.assertIn("default: encrypted", self.text)
        fetch = self.steps["Fetch feedback and crash logs"]
        self.assertIn("MODE: ${{ inputs.report || 'encrypted' }}", fetch)
        for part in ('--out "$RUNNER_TEMP/feedback"', '--encrypted-out "$RUNNER_TEMP/feedback-encrypted"',
                     "--recipient .github/feedback-recipient.pem", "--days 14", '--mode "$MODE"'):
            self.assertIn(part, fetch)

    def test_only_the_encrypted_file_is_uploaded_and_only_on_the_scripts_word(self):
        sealed = self.steps["Keep the encrypted report"]
        self.assertIn("if: always() && steps.fetch.outputs.mode == 'encrypted'", sealed)
        self.assertIn("path: ${{ runner.temp }}/feedback-encrypted/*.cms\n", sealed)
        self.assertIn("retention-days: 7\n", sealed)
        self.assertIn("name: testflight-feedback-encrypted", sealed)
        plain = self.steps["Keep report, screenshots and crash logs"]
        self.assertIn("if: always() && steps.fetch.outputs.mode == 'full'", plain)
        self.assertIn("path: ${{ runner.temp }}/feedback\n", plain)
        # Exactly these two uploads; the plaintext folder of encrypted is never a path.
        uploads = [b for b in self.steps.values() if "actions/upload-artifact@" in b]
        self.assertEqual(len(uploads), 2)
        self.assertNotIn("feedback-plain", "".join(uploads))

    def test_the_plaintext_is_removed_even_if_the_step_was_killed(self):
        cleanup = self.steps["Remove key and plaintext"]
        self.assertIn("if: always()", cleanup)
        self.assertIn('rm -rf "$RUNNER_TEMP/asc" "$RUNNER_TEMP"/feedback-plain-*', cleanup)
        names = list(self.steps)
        self.assertLess(names.index("Fetch feedback and crash logs"), names.index("Remove key and plaintext"))
        self.assertLess(names.index("Remove key and plaintext"), names.index("Keep the encrypted report"))

    def test_the_checkout_brings_the_certificate(self):
        checkout = self.text.split("actions/checkout@", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("sparse-checkout: .github/scripts\n", checkout)   # cone mode: also .github/*.pem
        self.assertNotIn("sparse-checkout-cone-mode: false", checkout)
        self.assertTrue(os.path.isfile(os.path.join(ROOT, ".github", "feedback-recipient.pem")))

    def test_no_expression_carries_anything_from_the_testers(self):
        expressions = set(re.findall(r"\$\{\{.*?\}\}", "\n".join(
            line for line in self.text.splitlines() if not line.lstrip().startswith("#"))))
        self.assertEqual(expressions, {
            "${{ secrets.ASC_FEEDBACK_KEY_ID }}", "${{ secrets.ASC_FEEDBACK_ISSUER_ID }}",
            "${{ secrets.ASC_FEEDBACK_KEY_P8 }}", "${{ runner.temp }}", "${{ github.token }}",
            "${{ inputs.report || 'encrypted' }}"})
        self.assertNotRegex(self.text, r"secrets\.ASC_(?:KEY_ID|ISSUER_ID|KEY_P8)\b")   # never the upload key


if __name__ == "__main__":
    unittest.main()
