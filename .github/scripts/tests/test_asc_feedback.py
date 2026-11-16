"""Unit tests for .github/scripts/asc_feedback.py with faked App Store Connect answers."""
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import asc_feedback  # noqa: E402

API = asc_feedback.API


def unb64(part):
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


def raw_to_der(raw):
    def integer(value):
        value = value.lstrip(b"\x00") or b"\x00"
        if value[0] & 0x80:
            value = b"\x00" + value
        return b"\x02" + bytes([len(value)]) + value
    body = integer(raw[:32]) + integer(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


class FakeAPI:
    """Answers by URL prefix; records every request (method, url, headers)."""

    def __init__(self, routes):
        self.routes = routes          # list of (url prefix, [responses]) - responses are used in order
        self.calls = []

    def __call__(self, method, url, headers):
        self.calls.append((method, url, headers))
        for prefix, responses in self.routes:
            if url.startswith(prefix):
                response = responses.pop(0) if len(responses) > 1 else responses[0]
                status, body = response[0], response[1]
                head = response[2] if len(response) > 2 else {}
                data = body if isinstance(body, bytes) else json.dumps(body).encode()
                return status, head, data
        raise AssertionError(f"unexpected request {url}")


def client(fake, sleeps=None):
    return asc_feedback.Client(lambda: "TOKEN", transport=fake,
                               sleep=(sleeps.append if sleeps is not None else lambda s: None))


APP = {"data": [{"type": "apps", "id": "123", "attributes": {"bundleId": "app.albumist.ios", "name": "Albumist"}}]}
BUILD = {"type": "builds", "id": "b1", "attributes": {"version": "42"}}


def submission(id_, comment="ok", screenshots=None):
    attributes = {"createdDate": "2026-11-16T08:00:00Z", "comment": comment, "deviceModel": "iPhone16,2",
                  "deviceFamily": "IPHONE", "osVersion": "26.1", "appPlatform": "IOS", "locale": "de-DE"}
    if screenshots is not None:
        attributes["screenshots"] = screenshots
    return {"type": "x", "id": id_, "attributes": attributes,
            "relationships": {"build": {"data": {"type": "builds", "id": "b1"}}}}


class TokenTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        cls.key = os.path.join(cls.dir, "key.p8")
        cls.pub = os.path.join(cls.dir, "key.pub")
        subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                        "-out", cls.key], check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", cls.key, "-pubout", "-out", cls.pub], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir)

    def test_header_and_claims_follow_apples_rules(self):
        token = asc_feedback.make_token("KEY123", "issuer-uuid", self.key, now=1_000_000)
        header, payload, signature = token.split(".")
        self.assertEqual(json.loads(unb64(header)), {"alg": "ES256", "kid": "KEY123", "typ": "JWT"})
        claims = json.loads(unb64(payload))
        self.assertEqual(claims, {"iss": "issuer-uuid", "iat": 1_000_000, "exp": 1_000_000 + 900,
                                  "aud": "appstoreconnect-v1"})
        self.assertLessEqual(claims["exp"] - claims["iat"], 20 * 60)   # Apple's maximum
        self.assertEqual(len(unb64(signature)), 64)                     # JWS form r||s, not DER

    def test_signature_verifies_with_the_public_key(self):
        token = asc_feedback.make_token("KEY123", "issuer-uuid", self.key)
        signing_input, _, signature = token.rpartition(".")
        sig_path = os.path.join(self.dir, "sig.der")
        with open(sig_path, "wb") as handle:
            handle.write(raw_to_der(unb64(signature)))
        result = subprocess.run(["openssl", "dgst", "-sha256", "-verify", self.pub, "-signature", sig_path],
                                input=signing_input.encode(), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_token_is_reused_and_renewed_before_it_expires(self):
        made, now = [], [0.0]
        c = asc_feedback.Client(lambda: made.append(1) or f"T{len(made)}", transport=None, clock=lambda: now[0])
        self.assertEqual(c.token(), "T1")
        now[0] = 9 * 60
        self.assertEqual(c.token(), "T1")
        now[0] = 11 * 60
        self.assertEqual(c.token(), "T2")


class HTTPTests(unittest.TestCase):
    def test_pagination_follows_next_and_dedupes_by_id(self):
        page1 = {"data": [submission("a"), submission("b")], "included": [BUILD],
                 "links": {"next": f"{API}/v1/apps/123/betaFeedbackCrashSubmissions?cursor=2"}}
        page2 = {"data": [submission("b"), submission("c")],
                 "links": {"next": f"{API}/v1/apps/123/betaFeedbackCrashSubmissions?cursor=3"}}
        page3 = {"data": [submission("c")], "links": {}}
        fake = FakeAPI([(f"{API}/v1/apps/123/betaFeedbackCrashSubmissions?cursor=2", [(200, page2)]),
                        (f"{API}/v1/apps/123/betaFeedbackCrashSubmissions?cursor=3", [(200, page3)]),
                        (f"{API}/v1/apps/123/betaFeedbackCrashSubmissions", [(200, page1)])])
        items, included = client(fake).pages("/v1/apps/123/betaFeedbackCrashSubmissions", {"limit": "2"}, "x", 100)
        self.assertEqual([i["id"] for i in items], ["a", "b", "c"])
        self.assertIn(("builds", "b1"), included)
        self.assertEqual(len(fake.calls), 3)
        self.assertTrue(all(h["Authorization"] == "Bearer TOKEN" for _, _, h in fake.calls))

    def test_pagination_stops_at_max_items_and_on_a_repeated_next_link(self):
        loop = {"data": [submission("a")], "links": {"next": f"{API}/v1/next"}}
        fake = FakeAPI([(f"{API}/v1/next", [(200, {"data": [submission("b")], "links": {"next": f"{API}/v1/next"}})]),
                        (f"{API}/v1/list", [(200, loop)])])
        items, _ = client(fake).pages("/v1/list", {}, "x", 100)
        self.assertEqual([i["id"] for i in items], ["a", "b"])
        self.assertEqual(len(fake.calls), 2)
        items, _ = client(FakeAPI([(f"{API}/v1/list", [(200, loop)])])).pages("/v1/list", {}, "x", 1)
        self.assertEqual(len(items), 1)

    def test_403_names_the_roles_that_may_read_feedback(self):
        body = {"errors": [{"status": "403", "code": "FORBIDDEN_ERROR", "title": "This request is forbidden for security reasons",
                            "detail": "The API key in use does not allow this request"}]}
        fake = FakeAPI([(API, [(403, body)])])
        with self.assertRaises(asc_feedback.AccessError) as caught:
            client(fake).get("/v1/apps/1/betaFeedbackScreenshotSubmissions", what="betaFeedbackScreenshotSubmissions")
        message = str(caught.exception)
        for part in ("HTTP 403", "FORBIDDEN_ERROR", "Admin, App Manager or Developer", "Team Keys",
                     "betaFeedbackScreenshotSubmissions"):
            self.assertIn(part, message)

    def test_401_points_at_the_secrets(self):
        fake = FakeAPI([(API, [(401, {"errors": [{"code": "NOT_AUTHORIZED"}]})])])
        with self.assertRaises(asc_feedback.AccessError) as caught:
            client(fake).get("/v1/apps")
        self.assertIn("ASC_KEY_ID", str(caught.exception))
        self.assertNotIn("TOKEN", str(caught.exception))

    def test_rate_limit_waits_for_retry_after_then_succeeds(self):
        sleeps = []
        fake = FakeAPI([(API, [(429, {"errors": []}, {"Retry-After": "7"}), (503, b""), (200, {"data": []})])])
        self.assertEqual(client(fake, sleeps).get("/v1/apps"), {"data": []})
        self.assertEqual(sleeps, [7.0, 10.0])

    def test_rate_limit_gives_up_after_the_retries(self):
        fake = FakeAPI([(API, [(429, {"errors": [{"code": "RATE_LIMIT_EXCEEDED"}]})])])
        with self.assertRaises(RuntimeError) as caught:
            client(fake, []).get("/v1/apps")
        self.assertIn("429", str(caught.exception))
        self.assertEqual(len(fake.calls), 5)

    def test_token_is_never_sent_to_another_host(self):
        with self.assertRaises(ValueError):
            client(FakeAPI([])).get("https://evil.example/v1/apps")
        loop = {"data": [submission("a")], "links": {"next": "https://evil.example/steal"}}
        with self.assertRaises(ValueError):
            client(FakeAPI([(API, [(200, loop)])])).pages("/v1/list", {}, "x", 10)


HOSTILE = ('<img src=x onerror=alert(1)> <script>alert(1)</script> [klick](javascript:alert(1)) '
           '![x](https://evil.example/t.png) @fuxinger | spalte |\n::error::fake\n# Überschrift\n```\n</details>')


class MarkdownTests(unittest.TestCase):
    def test_hostile_tester_text_is_inert(self):
        text = asc_feedback.md_quote(HOSTILE)
        self.assertNotIn("<", text)
        self.assertNotIn(">", "".join(line[2:] for line in text.splitlines()))   # only the quote marker
        self.assertIn("&lt;script&gt;", text)
        self.assertNotIn("](", text)            # no link or image syntax survives
        self.assertNotIn("@fuxinger", text)     # no mention
        self.assertNotIn("```", text)
        for line in text.splitlines():
            self.assertTrue(line.startswith("> "), line)   # every line stays inside the quote
            self.assertNotIn("|", line.replace("\\|", ""))

    def test_inline_text_is_one_line(self):
        self.assertNotIn("\n", asc_feedback.md_inline("a\nb\r\nc"))

    def test_code_block_fence_cannot_be_closed_from_inside(self):
        block = asc_feedback.code_block("frame\n```\n<b>x</b>\n`````")
        fence = block.splitlines()[0][:-len("text")]
        self.assertEqual(len(fence), 6)
        self.assertEqual(block.splitlines()[-1], fence)
        self.assertEqual(sum(1 for l in block.splitlines() if l.startswith(fence)), 2)

    def test_report_escapes_every_tester_field_and_omits_email(self):
        item = submission("s1", comment=HOSTILE)
        item["attributes"]["deviceModel"] = "<b>iPhone</b>"
        item["attributes"]["email"] = "tester@example.com"
        crash = submission("c1", comment="@someone <i>boom</i>")
        report = asc_feedback.render("Albumist", [{"item": item, "included": {("builds", "b1"): BUILD},
                                                   "files": ["screenshots/s1-1.png"], "problems": []}],
                                     [{"item": crash, "included": {}, "file": "crashlogs/c1.txt",
                                       "excerpt": "Thread 0 Crashed:\n0 Albumist ```", "problems": []}], [], "now")
        self.assertNotIn("<", report)
        self.assertNotIn("tester@example.com", report)
        self.assertIn("- Build: 42", report)
        self.assertIn("iPhone16,2", asc_feedback.render("A", [{"item": submission("z"), "included": {},
                                                               "files": [], "problems": []}], [], [], "now"))

    def test_counts_report_has_numbers_per_build_and_no_tester_text(self):
        item = submission("s1", comment=HOSTILE)
        other = submission("s2", comment="geheim")
        other["relationships"]["build"]["data"]["id"] = "b2"
        included = {("builds", "b1"): BUILD, ("builds", "b2"): {"type": "builds", "id": "b2", "attributes": {"version": "43"}}}
        crash = submission("c1", comment="privat")
        counts = asc_feedback.render_counts("Albumist", [{"item": item, "included": included},
                                                         {"item": other, "included": included}],
                                            [{"item": crash, "included": included}], [], "now")
        self.assertIn("| 43 | 1 | 0 | 2026\\-11\\-16 |", counts)
        self.assertIn("| 42 | 1 | 1 | 2026\\-11\\-16 |", counts)
        self.assertLess(counts.index("| 43 |"), counts.index("| 42 |"))      # newest build first
        for secret in ("img", "script", "geheim", "privat", "iPhone", "s1", "c1", "@"):
            self.assertNotIn(secret, counts)


TEXT_CRASH = """Incident Identifier: X
Exception Type:  EXC_BREAKPOINT (SIGTRAP)
Termination Reason: SIGNAL 5 Trace/BPT trap: 5
Triggered by Thread:  0

Thread 0 name:   Dispatch queue: com.apple.main-thread
Thread 0 Crashed:
0   libswiftCore.dylib            	0x1 _assertionFailure(_:_:file:line:flags:) + 244
1   Albumist                       	0x2 AppModel.apply() + 120 (AppModel.swift:42)
2   Albumist                       	0x3 closure #1 + 20
3   SwiftUI                        	0x4 x + 1
4   SwiftUI                        	0x5 y + 1

Thread 1:
0   libsystem_kernel.dylib        	0x6 __workq_kernreturn + 8
"""


class CrashLogTests(unittest.TestCase):
    def test_text_report_gives_exception_and_top_frames(self):
        excerpt = asc_feedback.top_frames(TEXT_CRASH, count=3)
        self.assertIn("Exception Type:  EXC_BREAKPOINT", excerpt)
        self.assertIn("AppModel.apply() + 120 (AppModel.swift:42)", excerpt)
        self.assertNotIn("SwiftUI", excerpt)
        self.assertNotIn("__workq_kernreturn", excerpt)

    def test_ips_report_names_images_and_symbols_of_the_faulting_thread(self):
        body = {"exception": {"type": "EXC_CRASH", "signal": "SIGABRT"}, "faultingThread": 1,
                "usedImages": [{"name": "Albumist"}, {"name": "libsystem_c.dylib"}],
                "threads": [{"frames": [{"imageIndex": 1, "symbol": "idle"}]},
                            {"frames": [{"imageIndex": 1, "symbol": "abort"},
                                        {"imageIndex": 0, "symbol": "AppModel.apply()", "sourceFile": "AppModel.swift",
                                         "sourceLine": 42}, {"imageIndex": 9, "imageOffset": 77}]}]}
        log = json.dumps({"app_name": "Albumist", "bug_type": "309"}) + "\n" + json.dumps(body, indent=1)
        excerpt = asc_feedback.top_frames(log)
        self.assertIn("EXC_CRASH SIGABRT", excerpt)
        self.assertIn("Thread 1 crashed:", excerpt)
        self.assertIn("AppModel.apply() (AppModel.swift:42)", excerpt)
        self.assertIn("+77", excerpt)
        self.assertNotIn("idle", excerpt)

    def test_unknown_format_gives_the_first_lines(self):
        self.assertEqual(asc_feedback.top_frames("\n".join(str(i) for i in range(50))).count("\n"), 19)


class FetchTests(unittest.TestCase):
    def setUp(self):
        self.out = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.out)

    def test_fetches_screenshots_and_crash_logs_into_the_folder(self):
        shots = {"data": [submission("s/1", screenshots=[{"url": "https://cdn.example/1.png"},
                                                         {"url": "http://insecure.example/2.png"}])],
                 "included": [BUILD], "links": {}}
        crashes = {"data": [submission("c1")], "included": [BUILD], "links": {}}
        fake = FakeAPI([
            (f"{API}/v1/apps?", [(200, APP)]),
            (f"{API}/v1/apps/123/betaFeedbackScreenshotSubmissions", [(200, shots)]),
            (f"{API}/v1/apps/123/betaFeedbackCrashSubmissions", [(200, crashes)]),
            (f"{API}/v1/betaFeedbackCrashSubmissions/c1/crashLog", [(200, {"data": {"attributes": {"logText": TEXT_CRASH}}})]),
        ])
        downloads = []

        def fake_download(url):
            downloads.append(url)
            return asc_feedback.download(url, transport=lambda m, u, h: (200, {"Content-Type": "image/png"}, b"PNG"))

        name, screenshots, crash_entries, errors, denied = asc_feedback.fetch(
            client(fake), "app.albumist.ios", self.out, 50, download_fn=fake_download, full=True)
        self.assertEqual(name, "Albumist (app.albumist.ios)")
        self.assertEqual(errors, [])
        self.assertFalse(denied)
        self.assertEqual(screenshots[0]["files"], ["screenshots/s_1-1.png"])     # id sanitised for the path
        self.assertIn("not https", screenshots[0]["problems"][0])
        with open(os.path.join(self.out, "screenshots/s_1-1.png"), "rb") as handle:
            self.assertEqual(handle.read(), b"PNG")
        self.assertEqual(crash_entries[0]["file"], "crashlogs/c1.txt")
        self.assertIn("AppModel.apply()", crash_entries[0]["excerpt"])
        list_call = [u for _, u, _ in fake.calls if "betaFeedbackScreenshotSubmissions" in u][0]
        self.assertIn("include=build", list_call)
        self.assertIn("sort=-createdDate", list_call)
        self.assertNotIn("email", list_call)
        self.assertNotIn("tester", list_call)

    def test_counts_mode_requests_no_tester_data_and_writes_nothing(self):
        shots = {"data": [submission("s1", screenshots=[{"url": "https://cdn.example/1.png"}])],
                 "included": [BUILD], "links": {}}
        crashes = {"data": [submission("c1")], "included": [BUILD], "links": {}}
        fake = FakeAPI([
            (f"{API}/v1/apps?", [(200, APP)]),
            (f"{API}/v1/apps/123/betaFeedbackScreenshotSubmissions", [(200, shots)]),
            (f"{API}/v1/apps/123/betaFeedbackCrashSubmissions", [(200, crashes)]),
        ])

        def no_download(url):
            raise AssertionError("counts mode must not download screenshots")

        _, screenshots, crash_entries, errors, _ = asc_feedback.fetch(
            client(fake), "app.albumist.ios", self.out, 50, download_fn=no_download)
        self.assertEqual((len(screenshots), len(crash_entries), errors), (1, 1, []))
        self.assertEqual(os.listdir(self.out), [])
        urls = [u for _, u, _ in fake.calls]
        self.assertFalse(any("crashLog" in u for u in urls))
        for url in urls[1:]:
            self.assertIn("=createdDate,build", url)
            for field in ("comment", "screenshots", "deviceModel", "email", "locale"):
                self.assertNotIn(field, url)

    def test_403_on_one_section_still_fetches_the_other(self):
        crashes = {"data": [], "links": {}}
        fake = FakeAPI([
            (f"{API}/v1/apps?", [(200, APP)]),
            (f"{API}/v1/apps/123/betaFeedbackScreenshotSubmissions", [(403, {"errors": [{"code": "FORBIDDEN_ERROR"}]})]),
            (f"{API}/v1/apps/123/betaFeedbackCrashSubmissions", [(200, crashes)]),
        ])
        _, screenshots, crash_entries, errors, denied = asc_feedback.fetch(client(fake), "app.albumist.ios", self.out, 50)
        self.assertTrue(denied)
        self.assertEqual(len(errors), 1)
        self.assertIn("Admin, App Manager or Developer", errors[0])
        self.assertEqual(crash_entries, [])

    def test_missing_app_is_reported(self):
        fake = FakeAPI([(f"{API}/v1/apps?", [(200, {"data": []})])])
        with self.assertRaises(asc_feedback.AppMissing):
            asc_feedback.fetch(client(fake), "app.albumist.ios", self.out, 50)


class PrivacyGateTests(unittest.TestCase):
    def github(self, status, body):
        calls = []

        def transport(method, url, headers):
            calls.append((url, headers))
            return status, {}, json.dumps(body).encode() if not isinstance(body, bytes) else body
        return transport, calls

    def test_only_a_clear_private_answer_counts_as_private(self):
        transport, calls = self.github(200, {"private": True})
        self.assertTrue(asc_feedback.repo_is_private("fuxinger/sortly-ios", "gh-token", transport))
        self.assertEqual(calls[0][0], "https://api.github.com/repos/fuxinger/sortly-ios")
        self.assertEqual(calls[0][1]["Authorization"], "Bearer gh-token")
        for status, body in [(200, {"private": False}), (200, {}), (200, {"private": "true"}), (404, {}),
                             (200, b"not json")]:
            self.assertFalse(asc_feedback.repo_is_private("fuxinger/sortly-ios", "t", self.github(status, body)[0]))
        self.assertFalse(asc_feedback.repo_is_private("", "t", transport))
        self.assertFalse(asc_feedback.repo_is_private("a/b/../c?x=1", "t", transport))

        def broken(method, url, headers):
            raise OSError("network down")
        self.assertFalse(asc_feedback.repo_is_private("fuxinger/sortly-ios", "t", broken))

    def run_main(self, args, github_answer):
        out = tempfile.mkdtemp()
        summary = os.path.join(out, "summary.md")
        transport, calls = self.github(*github_answer)
        env = {"GITHUB_REPOSITORY": "fuxinger/sortly-ios", "GH_TOKEN": "t", "KEY_ID": "k", "ISSUER_ID": "i",
               "KEY_PATH": os.path.join(out, "missing.p8"), "GITHUB_OUTPUT": os.path.join(out, "output")}
        with mock.patch.dict(os.environ, env), mock.patch.object(asc_feedback, "urllib_transport", transport), \
                mock.patch.object(asc_feedback.Client, "get", side_effect=AssertionError("App Store Connect called")):
            code = asc_feedback.main(args + ["--out", os.path.join(out, "feedback"), "--summary", summary])
        written = sorted(os.listdir(out))
        shutil.rmtree(out)
        return code, calls, written

    def test_full_is_refused_on_a_public_repository_before_anything_is_fetched(self):
        code, calls, written = self.run_main(["--mode", "full"], (200, {"private": False}))
        self.assertEqual(code, 4)
        self.assertEqual(len(calls), 1)                    # only GitHub was asked
        self.assertEqual(written, [])                      # no summary, no folder, no mode=full output

    def test_full_is_refused_when_the_visibility_cannot_be_read(self):
        self.assertEqual(self.run_main(["--mode", "full"], (403, {"message": "denied"}))[0], 4)

    def test_counts_is_the_default_and_needs_no_visibility_check(self):
        with mock.patch.object(asc_feedback, "fetch", return_value=("Albumist", [], [], [], False)) as fetch:
            code, calls, written = self.run_main([], (200, {"private": False}))
        self.assertEqual(code, 0)
        self.assertEqual(calls, [])
        self.assertFalse(fetch.call_args.kwargs["full"])
        self.assertEqual(written, ["summary.md"])          # no feedback folder, no mode=full output

    def test_full_runs_on_a_private_repository_and_signals_the_upload(self):
        with mock.patch.object(asc_feedback, "fetch", return_value=("Albumist", [], [], [], False)) as fetch:
            code, calls, written = self.run_main(["--mode", "full"], (200, {"private": True}))
        self.assertEqual(code, 0)
        self.assertTrue(fetch.call_args.kwargs["full"])
        self.assertEqual(written, ["feedback", "output", "summary.md"])


class WorkflowTests(unittest.TestCase):
    def test_schedule_and_default_are_counts_and_the_artifact_follows_the_script(self):
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "workflows", "asc-feedback.yml")
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn("default: counts", text)
        self.assertIn("MODE: ${{ inputs.report || 'counts' }}", text)
        self.assertIn("if: always() && steps.fetch.outputs.mode == 'full'", text)
        self.assertIn("retention-days: 7", text)
        self.assertNotRegex(text, r"(?m)^  push:")
        self.assertNotRegex(text, r"(?m)^  pull_request")


class MainTests(unittest.TestCase):
    def test_missing_environment_fails_without_calling_the_api(self):
        saved = {k: os.environ.pop(k, None) for k in ("KEY_ID", "ISSUER_ID", "KEY_PATH")}
        try:
            out = tempfile.mkdtemp()
            self.assertEqual(asc_feedback.main(["--out", out]), 2)
            shutil.rmtree(out)
        finally:
            for k, v in saved.items():
                if v is not None:
                    os.environ[k] = v


if __name__ == "__main__":
    unittest.main()
