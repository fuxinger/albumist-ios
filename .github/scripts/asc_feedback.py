"""Fetches TestFlight feedback (screenshots with comments) and crash reports of one app.

  python3 asc_feedback.py --bundle-id app.albumist.ios [--summary FILE]
      [--mode counts|full|encrypted] [--out feedback] [--encrypted-out feedback-encrypted]
      [--recipient .github/feedback-recipient.pem] [--days 14]

Mode counts (default): only the number of feedback and crash submissions per build. Only the
build and date of each submission are requested; no comment, device data, screenshot or crash
log is fetched or written. Mode full: comments, screenshots and crash logs into --out. Full is
refused (exit 4) unless the GitHub API reports GITHUB_REPOSITORY as private (GH_TOKEN): while the
repository is public, its job summaries and artifacts are readable by others, and screenshots
of a photo app may show the testers' own photos.

Mode encrypted (the daily schedule; allowed on a public repository): the content of full, but
only submissions of the last --days days (stateless: the local side de-duplicates by submission
id), written into a fresh folder under $RUNNER_TEMP, packed into one tar (report.md,
submissions.json, screenshots/, crashlogs/) and encrypted with openssl cms (RSA-OAEP SHA-256 key
transport, AES-256-CBC content) to the certificate --recipient. Its SHA-256 fingerprint must
equal RECIPIENT_SHA256 below, checked before anything is fetched (exit 5): a swapped certificate
in a pull request fails loudly instead of sending the feedback to someone else. The plaintext
folder and the tar are overwritten and deleted before the script ends, also on errors; only
--encrypted-out/testflight-feedback-<time>.cms remains (artifact kept 7 days). tools/feedback_inbox.py decrypts it
with the private key, which is never in the repository or on a runner.

Uses the App Store Connect API with its own team key (role Developer; never the upload's Admin
key), the secrets ASC_FEEDBACK_KEY_ID, ASC_FEEDBACK_ISSUER_ID and ASC_FEEDBACK_KEY_P8, given to
the script as KEY_ID, ISSUER_ID and KEY_PATH (the .p8 file) in the environment. The JWT is signed with the openssl
command line tool like testflight_notes.py, so no Python packages are needed.

Endpoints (App Store Connect API 4.0, checked against Apple's documentation 16.11.2026):
  GET /v1/apps?filter[bundleId]=...
  GET /v1/apps/{id}/betaFeedbackScreenshotSubmissions   (comment, device, screenshots[].url)
  GET /v1/apps/{id}/betaFeedbackCrashSubmissions        (comment, device)
  GET /v1/betaFeedbackCrashSubmissions/{id}/crashLog    (logText)
Apple allows these for keys with the role Admin, App Manager or Developer; any other role
(Marketing, Sales, Finance, Customer Support, ...) gets 403.

Full writes into --out: report.md, screenshots/<submission>-<n>.<ext>, crashlogs/<submission>.txt.
Everything testers send is untrusted text: it is only written into files (Markdown escaped, crash
logs in code fences), never printed to the log, where a line starting with "::" would be read as
a workflow command. Tester e-mail addresses and names are never requested (public repository).

The job summary only ever shows the counts table, also in modes full and encrypted (summaries
are kept about 90 days); tester content is only in report.md inside the 7-day artifact (full) or
inside the encrypted file (encrypted).
API calls never follow redirects (a 3xx is an error), so the JWT and the GitHub token cannot be
passed on to another URL; network errors, 429 and 5xx are retried.

Exit codes:
  0  everything fetched
  1  a section or a single item failed (summary and report still written with what worked)
  2  KEY_ID, ISSUER_ID or KEY_PATH missing; or the key is not accepted (401); or its role may not
     read TestFlight feedback (403: needs Admin, App Manager or Developer)
  3  no app with that bundle id
  4  mode full refused: the repository is public, or its visibility could not be read
  5  mode encrypted refused or failed: the recipient certificate is missing, not exactly one
     certificate, or not the pinned one; or the encryption failed (nothing is uploaded then)
"""
import argparse
import base64
import datetime
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from testflight_notes import b64, der_to_raw  # noqa: E402  (same JWT signing as the upload)

API = "https://api.appstoreconnect.apple.com"
ROLES = "Admin, App Manager or Developer"
ROLE_FIX = ("App Store Connect > Users and Access > Integrations > App Store Connect API > "
            "Team Keys: the key's Access column must be Admin, App Manager or Developer "
            "(a key's role cannot be changed; revoke it and generate a new one with the right "
            "role, then update the GitHub secrets ASC_FEEDBACK_KEY_ID, ASC_FEEDBACK_ISSUER_ID and "
            "ASC_FEEDBACK_KEY_P8 in the environment asc-feedback).")
SCREENSHOT_FIELDS = ("createdDate,comment,deviceModel,deviceFamily,osVersion,appPlatform,locale,"
                     "connectionType,batteryPercentage,appUptimeInMilliseconds,screenshots,build")
CRASH_FIELDS = ("createdDate,comment,deviceModel,deviceFamily,osVersion,appPlatform,locale,"
                "connectionType,batteryPercentage,appUptimeInMilliseconds,build")
COUNT_FIELDS = "createdDate,build"   # counts mode: no comment, device or screenshot fields at all
MAX_DOWNLOAD = 25 * 1024 * 1024
SUMMARY_LIMIT = 900_000          # GitHub allows 1 MiB per step summary
TOKEN_LIFETIME = 15 * 60         # Apple accepts at most 20 minutes
DEFAULT_DAYS = 14                # mode encrypted: submissions of the last 14 days
# Mode encrypted only encrypts to this certificate (.github/feedback-recipient.pem): SHA-256 of
# its DER bytes, as "openssl x509 -noout -fingerprint -sha256" prints it. Deliberately not a
# command line option: changing the recipient means changing this line in a reviewed commit.
RECIPIENT_SHA256 = ("6F:83:13:57:47:66:2F:98:64:76:CE:49:36:60:1C:21:"
                    "6C:08:2D:8D:85:54:42:2B:22:02:6B:5B:8A:76:32:36")
ENCRYPTED_ARTIFACT = "testflight-feedback-encrypted"


class AccessError(Exception):
    """401 or 403: the key is not accepted, or its role does not allow the resource."""


class AppMissing(Exception):
    pass


# ---------------------------------------------------------------- JWT

def jwt_parts(key_id, issuer_id, now):
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer_id, "iat": now, "exp": now + TOKEN_LIFETIME, "aud": "appstoreconnect-v1"}
    return header, payload


def make_token(key_id, issuer_id, key_path, now=None):
    now = int(time.time()) if now is None else now
    header, payload = jwt_parts(key_id, issuer_id, now)
    signing_input = f"{b64(json.dumps(header).encode())}.{b64(json.dumps(payload).encode())}"
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                         input=signing_input.encode(), capture_output=True, check=True).stdout
    return f"{signing_input}.{b64(der_to_raw(der))}"


# ---------------------------------------------------------------- HTTP

class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follows a redirect: a 3xx comes back as an error, so a request carrying the App Store
    Connect JWT or the GitHub token can never be passed on to another URL."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


NO_REDIRECT = urllib.request.build_opener(NoRedirect)
FOLLOW_REDIRECTS = urllib.request.build_opener()


def urllib_transport(method, url, headers, opener=None):
    """Returns (status, headers, body). HTTP errors (and every 3xx) are returned, not raised.
    No redirects unless an opener that follows them is passed (screenshots only, no token)."""
    request = urllib.request.Request(url, method=method, headers=headers)
    try:
        with (opener or NO_REDIRECT).open(request, timeout=60) as response:
            return response.status, dict(response.headers), response.read(MAX_DOWNLOAD + 1)
    except urllib.error.HTTPError as error:
        try:
            body = error.read(64 * 1024)
        except (OSError, AttributeError):
            body = b""
        return error.code, dict(error.headers or {}), body


def download_transport(method, url, headers):
    """For the signed screenshot URLs: no token is sent, so following the CDN's redirects is safe."""
    return urllib_transport(method, url, headers, opener=FOLLOW_REDIRECTS)


def apple_error(body):
    """One short line from an App Store Connect error body (code: title - detail)."""
    try:
        errors = json.loads(body).get("errors") or []
    except (ValueError, AttributeError):
        return ""
    parts = []
    for item in errors[:2]:
        text = " - ".join(str(item.get(k, "")) for k in ("code", "title", "detail") if item.get(k))
        parts.append(text)
    return one_line("; ".join(parts), 300)


def no_surrogates(text):
    """The text without lone surrogates (JSON may carry "\\ud800"), which UTF-8 cannot write."""
    return str(text).encode("utf-8", "replace").decode("utf-8")


def one_line(text, limit):
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", no_surrogates(text)).strip()
    return text[:limit]


def github_mask(token):
    """Hides a derived secret (the JWT) in the Actions log; does nothing outside Actions."""
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::add-mask::{token}", flush=True)


class Client:
    def __init__(self, token_factory, transport=None, sleep=time.sleep, clock=time.monotonic,
                 retries=4, mask=None):
        self.token_factory = token_factory
        self.mask = mask or github_mask
        self.transport = transport or urllib_transport
        self.sleep = sleep
        self.clock = clock
        self.retries = retries
        self._token = None
        self._token_at = 0.0
        self.rate_limit = ""
        self.last_total = None

    def token(self):
        if self._token is None or self.clock() - self._token_at > TOKEN_LIFETIME - 5 * 60:
            self._token = self.token_factory()
            self._token_at = self.clock()
            self.mask(self._token)
        return self._token

    def get(self, path_or_url, params=None, what="App Store Connect"):
        url = path_or_url if path_or_url.startswith("https://") else f"{API}{path_or_url}"
        if not url.startswith(API + "/"):
            raise ValueError("refusing to send the API token to another host")
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params, safe="[],")
        for attempt in range(self.retries + 1):
            try:
                status, headers, body = self.transport("GET", url, {"Authorization": f"Bearer {self.token()}",
                                                                   "Accept": "application/json"})
            except (urllib.error.URLError, OSError) as error:     # timeouts, resets, DNS: like a 5xx
                if attempt >= self.retries:
                    raise RuntimeError(f"{what}: no connection ({one_line(error, 200)})") from None
                wait = retry_after({}, attempt)
                print(f"ASC {what}: no connection, retrying in {wait:.0f} s", flush=True)
                self.sleep(wait)
                continue
            self.rate_limit = {k.lower(): v for k, v in headers.items()}.get("x-rate-limit", self.rate_limit)
            if status == 200:
                return json.loads(body)
            if status == 401:
                raise AccessError(
                    f"{what}: HTTP 401, App Store Connect does not accept the key ({apple_error(body)}). "
                    "Check that ASC_FEEDBACK_KEY_ID, ASC_FEEDBACK_ISSUER_ID and ASC_FEEDBACK_KEY_P8 belong to the same team key and that "
                    "the key is not revoked (App Store Connect > Users and Access > Integrations).")
            if status == 403:
                raise AccessError(
                    f"{what}: HTTP 403, the key's role may not read this ({apple_error(body)}). "
                    f"TestFlight feedback and crash logs need a team key with the role {ROLES}. {ROLE_FIX}")
            if status == 404:
                raise LookupError(f"{what}: HTTP 404 ({apple_error(body)})")
            if 300 <= status < 400:
                raise RuntimeError(f"{what}: HTTP {status}, redirects are not followed with the API token")
            if (status == 429 or status >= 500) and attempt < self.retries:
                wait = retry_after(headers, attempt)
                print(f"ASC {what}: HTTP {status}, retrying in {wait:.0f} s", flush=True)
                self.sleep(wait)
                continue
            raise RuntimeError(f"{what}: HTTP {status} ({apple_error(body)})")
        raise RuntimeError(f"{what}: no answer")  # pragma: no cover

    def pages(self, path, params, what, max_items, stop=None):
        """All items of a paged list (follows links.next), with the included resources by (type, id).
        With stop (a list sorted newest first): the first item for which stop(item) is true ends
        the list, and no further page is requested."""
        items, included, seen = [], {}, set()
        url, query, visited = path, dict(params), set()
        self.last_total = None
        stopped = False
        while url and len(items) < max_items and not stopped:
            page = self.get(url, query, what)
            if self.last_total is None:
                total = ((page.get("meta") or {}).get("paging") or {}).get("total")
                self.last_total = total if isinstance(total, int) and total >= 0 else None
            for resource in page.get("included", []) or []:
                included[(resource.get("type"), resource.get("id"))] = resource
            for item in page.get("data", []) or []:
                if item.get("id") in seen:
                    continue
                if stop is not None and stop(item):
                    stopped = True
                    break
                seen.add(item.get("id"))
                items.append(item)
                if len(items) >= max_items:
                    break
            nxt = (page.get("links") or {}).get("next")
            if stopped or not nxt or nxt in visited:
                break
            visited.add(nxt)
            url, query = nxt, None
        return items, included


def retry_after(headers, attempt):
    value = {k.lower(): v for k, v in headers.items()}.get("retry-after")
    try:
        return min(max(float(value), 1.0), 120.0)
    except (TypeError, ValueError):
        return min(5.0 * (2 ** attempt), 120.0)


def download(url, transport=download_transport):
    """A screenshot from its signed URL (no API token: it is another host)."""
    if not url.startswith("https://"):
        raise ValueError("screenshot URL is not https")
    status, headers, body = transport("GET", url, {})
    if status != 200:
        raise RuntimeError(f"screenshot download: HTTP {status}")
    if len(body) > MAX_DOWNLOAD:
        raise RuntimeError("screenshot larger than 25 MB, skipped")
    kind = {k.lower(): v for k, v in headers.items()}.get("content-type", "").split(";")[0].strip().lower()
    return body, {"image/png": "png", "image/jpeg": "jpg", "image/heic": "heic"}.get(kind, "img")


# ---------------------------------------------------------------- Crash logs

def top_frames(log_text, count=8):
    """The interesting part of a crash log: exception lines and the top frames of the crashed thread.
    Understands Apple's text crash report and the JSON .ips format; otherwise the first lines."""
    text = log_text or ""
    ips = parse_ips(text)
    if ips is not None:
        return ips_frames(ips, count)
    lines = text.splitlines()
    head = [l for l in lines if re.match(r"^(Exception Type|Exception Codes|Exception Reason|Termination Reason|"
                                         r"Crashed Thread|Triggered by Thread):", l)]
    for index, line in enumerate(lines):
        if re.match(r"^Thread \d+(?: name:.*)? Crashed", line):
            frames = []
            for frame in lines[index + 1:]:
                if not frame.strip():
                    break
                frames.append(frame.rstrip())
                if len(frames) >= count:
                    break
            return "\n".join(head + [line] + frames)
    return "\n".join(head + lines[: max(0, 20 - len(head))])


def parse_ips(text):
    """The body of a JSON crash report (.ips: one header line, then the report), or None."""
    stripped = text.strip()
    if not stripped.startswith("{"):
        return None
    for candidate in (stripped.partition("\n")[2], stripped):
        try:
            data = json.loads(candidate)
        except ValueError:
            continue
        if isinstance(data, dict) and "threads" in data:
            return data
    return None


def ips_frames(data, count):
    lines = []
    exception = data.get("exception") or {}
    if exception:
        lines.append("Exception: " + " ".join(str(exception.get(k)) for k in ("type", "signal", "subtype")
                                              if exception.get(k)))
    termination = data.get("termination") or {}
    if termination.get("indicator") or termination.get("reasons"):
        lines.append("Termination: " + one_line(termination.get("indicator") or termination.get("reasons"), 300))
    images = data.get("usedImages") or []
    threads = data.get("threads") or []
    index = data.get("faultingThread")
    if not isinstance(index, int) or not 0 <= index < len(threads):
        index = next((i for i, t in enumerate(threads) if t.get("triggered")), 0)
    if threads:
        lines.append(f"Thread {index} crashed:")
        for number, frame in enumerate((threads[index].get("frames") or [])[:count]):
            image = images[frame["imageIndex"]].get("name", "?") if isinstance(frame.get("imageIndex"), int) \
                and 0 <= frame["imageIndex"] < len(images) else "?"
            symbol = frame.get("symbol") or f"+{frame.get('imageOffset', '?')}"
            where = f" ({frame['sourceFile']}:{frame.get('sourceLine', '?')})" if frame.get("sourceFile") else ""
            lines.append(f"{number:<3} {image:<30} {symbol}{where}")
    return "\n".join(lines)


# ---------------------------------------------------------------- Markdown

BIDI_AND_CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f\u202a-\u202e\u2066-\u2069]")
MD_SPECIAL = re.compile(r"([\\`*_{}\[\]()#+\-.!|~>:])")


def md_text(value, limit=4000):
    """Untrusted text as inert Markdown: no HTML, no links, images, mentions or table breaks."""
    text = no_surrogates(value or "")
    text = re.sub(BIDI_AND_CONTROL, "", text)
    if len(text) > limit:
        text = text[:limit] + "…"
    text = html.escape(text, quote=False)       # < > & -> entities, so no raw HTML
    text = MD_SPECIAL.sub(r"\\\1", text)
    text = text.replace("@", "&#64;")             # no @mentions
    return text


def md_inline(value, limit=200):
    return md_text(one_line(value, limit), limit + 1)


def md_quote(value):
    lines = md_text(value).splitlines() or [""]
    return "  \n".join("> " + line for line in lines)     # two spaces: keep the tester's line breaks


def code_block(text):
    text = BIDI_AND_CONTROL.sub("", no_surrogates(text or ""))
    longest = max([len(run) for run in re.findall(r"`+|~+", text)] + [2])
    fence = "`" * (longest + 1)
    return f"{fence}text\n{text}\n{fence}"


# ---------------------------------------------------------------- Report

def safe_id(value):
    return re.sub(r"[^A-Za-z0-9_-]", "_", str(value))[:80] or "unknown"


def build_version(item, included):
    ref = ((item.get("relationships") or {}).get("build") or {}).get("data") or {}
    build = included.get(("builds", ref.get("id")))
    return ((build or {}).get("attributes") or {}).get("version") or "?"


def describe(item, included):
    a = item.get("attributes") or {}
    device = " · ".join(x for x in [md_inline(a.get("deviceModel")), md_inline(a.get("deviceFamily"))] if x)
    os_name = " ".join(x for x in [md_inline(a.get("appPlatform")), md_inline(a.get("osVersion"))] if x)
    rows = [
        ("Datum", md_inline(a.get("createdDate"))),
        ("Build", md_inline(build_version(item, included))),
        ("Gerät", device or "?"),
        ("System", os_name or "?"),
        ("Sprache", md_inline(a.get("locale")) or "?"),
    ]
    if a.get("batteryPercentage") is not None:
        rows.append(("Akku", md_inline(f"{a.get('batteryPercentage')} %")))
    try:
        rows.append(("App lief", md_inline(f"{int(a['appUptimeInMilliseconds']) // 1000} s")))
    except (KeyError, TypeError, ValueError):
        pass
    return "\n".join(f"- {key}: {value}" for key, value in rows)


def shown_count(fetched, total, max_items):
    """The number to show: Apple's total when it sent one, else what was fetched, "200+" at the cap."""
    if isinstance(total, int) and total >= fetched:
        return str(total)
    if max_items and fetched >= max_items:
        return f"{fetched}+"
    return str(fetched)


def render_counts(app, screenshots, crashes, errors, generated, totals=None, max_items=None, details=None,
                  days=None):
    """Counts per build only: no tester text, no device details, no crash frames. This is all a job
    summary ever shows (summaries are kept ~90 days); with details ("full" or "encrypted") it
    points to the artifact."""
    totals = totals or {}
    per_build = {}
    for kind, entries in (("feedback", screenshots), ("crashes", crashes)):
        for entry in entries:
            build = build_version(entry["item"], entry["included"])
            row = per_build.setdefault(build, {"feedback": 0, "crashes": 0, "newest": ""})
            row[kind] += 1
            created = str((entry["item"].get("attributes") or {}).get("createdDate") or "")
            row["newest"] = max(row["newest"], created)
    feedback_count = shown_count(len(screenshots), totals.get("screenshots"), max_items)
    crash_count = shown_count(len(crashes), totals.get("crashes"), max_items)
    out = [f"# TestFlight-Feedback {md_inline(app)}", "",
           f"Abgeholt: {md_inline(generated)} · {feedback_count} Feedback mit Screenshot · "
           f"{crash_count} Absturzberichte", ""]
    if days:
        out += [f"Nur Einsendungen der letzten {int(days)} Tage.", ""]
    for message in errors:
        out += [f"**Fehler:** {md_inline(message, 600)}", ""]
    if max_items and (len(screenshots) >= max_items or len(crashes) >= max_items):
        out += [f"Tabelle: nur die neuesten {max_items} je Art.", ""]
    if per_build:
        out += ["| Build | Feedback | Abstürze | Neuestes |", "|---|---|---|---|"]
        def order(key):
            return (0, -int(key)) if str(key).isdigit() else (1, 0)
        for build in sorted(per_build, key=order):
            row = per_build[build]
            out.append(f"| {md_inline(build, 20)} | {row['feedback']} | {row['crashes']} | "
                       f"{md_inline(row['newest'][:10], 20)} |")
        out.append("")
    if details == "encrypted":
        out += [f"Details verschlüsselt im Artefakt **{ENCRYPTED_ARTIFACT}** (`report.md`, Screenshots, "
                "Absturzprotokolle; 7 Tage). Lesbar nur mit dem privaten Schlüssel: "
                "`tools/feedback_inbox.py`.", ""]
    elif details:
        out += ["Details im Artefakt **testflight-feedback** (`report.md`, Screenshots, Absturzprotokolle; "
                "7 Tage).", ""]
    else:
        out += ["Nur Anzahlen: solange das Repository öffentlich ist, stehen Kommentare, Screenshots und "
                "Absturzprotokolle nur in App Store Connect (TestFlight > Feedback, Abstürze).", ""]
    return "\n".join(out)


def render(app, screenshots, crashes, errors, generated):
    """The full report (mode full, private repository only)."""
    out = [f"# TestFlight-Feedback {md_inline(app)}", "",
           f"Abgeholt: {md_inline(generated)} · {len(screenshots)} Feedback mit Screenshot · "
           f"{len(crashes)} Absturzberichte", ""]
    for message in errors:
        out += [f"**Fehler:** {md_inline(message, 600)}", ""]
    out += ["## Feedback mit Screenshots", ""]
    if not screenshots:
        out += ["Keins.", ""]
    for entry in screenshots:
        item = entry["item"]
        out += [f"### {md_inline(item.get('id'))}", "", describe(item, entry["included"]), ""]
        out += ["Kommentar:", "", md_quote((item.get("attributes") or {}).get("comment") or "(kein Text)"), ""]
        if entry["files"]:
            out += ["Screenshots: " + ", ".join(f"`{name}`" for name in entry["files"]), ""]
        for problem in entry["problems"]:
            out += [f"- {md_inline(problem, 300)}"]
        out.append("")
    out += ["## Abstürze", ""]
    if not crashes:
        out += ["Keine.", ""]
    for entry in crashes:
        item = entry["item"]
        out += [f"### {md_inline(item.get('id'))}", "", describe(item, entry["included"]), ""]
        comment = (item.get("attributes") or {}).get("comment")
        if comment:
            out += ["Kommentar:", "", md_quote(comment), ""]
        if entry["file"]:
            out += [f"Protokoll: `{entry['file']}`", "", code_block(entry["excerpt"]), ""]
        for problem in entry["problems"]:
            out += [f"- {md_inline(problem, 300)}"]
        out.append("")
    return "\n".join(out)


# ---------------------------------------------------------------- Encryption (mode encrypted)

class RecipientError(Exception):
    """The recipient certificate is missing, malformed, or not the pinned one."""


class EncryptError(Exception):
    pass


def fingerprint_hex(text):
    return re.sub(r"[^0-9a-f]", "", str(text).lower())


def colon_hex(digest):
    return ":".join(digest[i:i + 2] for i in range(0, len(digest), 2)).upper()


def read_recipient(path, pin=None):
    """The DER bytes of the one certificate in path, if its SHA-256 equals the pin (default
    RECIPIENT_SHA256). Anything else in the file (a second certificate, a key) is refused."""
    pin = fingerprint_hex(RECIPIENT_SHA256 if pin is None else pin)
    try:
        with open(path, "rb") as handle:
            data = handle.read(64 * 1024 + 1)
    except OSError as error:
        raise RecipientError(f"recipient certificate {path} cannot be read ({error.strerror})") from None
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        raise RecipientError(f"recipient certificate {path} is not a PEM file") from None
    blocks = re.findall(r"-----BEGIN ([A-Z0-9 ]+)-----\r?\n(.*?)-----END \1-----", text, re.S)
    if len(data) > 64 * 1024 or text.count("-----BEGIN ") != 1 or [b[0] for b in blocks] != ["CERTIFICATE"]:
        raise RecipientError(f"{path} must hold exactly one PEM certificate and nothing else")
    try:
        der = base64.b64decode("".join(blocks[0][1].split()), validate=True)
    except ValueError:
        raise RecipientError(f"recipient certificate {path} is not valid base64") from None
    actual = hashlib.sha256(der).hexdigest()
    if len(pin) != 64 or actual != pin:
        raise RecipientError(f"recipient certificate {path} has the SHA-256 fingerprint {colon_hex(actual)}, "
                             f"not the pinned {colon_hex(pin)} (asc_feedback.py RECIPIENT_SHA256). "
                             "Nothing was fetched or encrypted.")
    return der


def certificate_pem(der):
    body = base64.b64encode(der).decode("ascii")
    lines = [body[i:i + 64] for i in range(0, len(body), 64)]
    return "-----BEGIN CERTIFICATE-----\n" + "\n".join(lines) + "\n-----END CERTIFICATE-----\n"


def wipe(path):
    """Overwrites every regular file under path with zeros, then deletes path. Best effort on
    journaling or copy-on-write disks; the runner's disk is discarded after the job anyway."""
    if not os.path.lexists(path):
        return
    if os.path.isdir(path) and not os.path.islink(path):
        for root, _dirs, files in os.walk(path):
            for name in files:
                wipe(os.path.join(root, name))
        shutil.rmtree(path, ignore_errors=True)
        return
    try:
        if os.path.isfile(path) and not os.path.islink(path):
            size = os.path.getsize(path)
            with open(path, "r+b") as handle:
                while size > 0:
                    chunk = min(size, 1024 * 1024)
                    handle.write(b"\0" * chunk)
                    size -= chunk
                handle.flush()
                os.fsync(handle.fileno())
    except OSError:
        pass
    try:
        os.remove(path)
    except OSError:
        pass


def submissions_index(app, screenshots, crashes, generated, days):
    """submissions.json: what tools/feedback_inbox.py reads (tester text raw: it is untrusted there too)."""
    def text(value):
        return "" if value is None else no_surrogates(value)

    def common(entry, kind):
        item = entry["item"]
        a = item.get("attributes") or {}
        return {"id": text(item.get("id")), "kind": kind, "build": build_version(item, entry["included"]),
                "created": text(a.get("createdDate")), "device_model": text(a.get("deviceModel")),
                "device_family": text(a.get("deviceFamily")), "os_version": text(a.get("osVersion")),
                "platform": text(a.get("appPlatform")), "locale": text(a.get("locale")),
                "comment": text(a.get("comment")), "problems": [text(p) for p in entry["problems"]]}
    rows = [dict(common(e, "feedback"), screenshots=list(e["files"])) for e in screenshots]
    rows += [dict(common(e, "crash"), crash_log=e["file"], crash_excerpt=e["excerpt"]) for e in crashes]
    return {"format": 1, "app": app, "generated": generated, "days": days, "submissions": rows}


def pack(content_dir, tar_path):
    """Every file under content_dir into an uncompressed tar, paths relative to it, no owner names."""
    def anonymous(info):
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        return info
    with tarfile.open(tar_path, "w", format=tarfile.PAX_FORMAT) as tar:
        for root, dirs, files in os.walk(content_dir):
            dirs.sort()
            for name in sorted(files):
                full_path = os.path.join(root, name)
                tar.add(full_path, arcname=os.path.relpath(full_path, content_dir), recursive=False,
                        filter=anonymous)


# DER encodings (tag 06, length, value) of the object identifiers the encrypted file must name in
# its first bytes (recipient info, then the content algorithm), and the one it must not.
OID_RSAES_OAEP = bytes.fromhex("06092a864886f70d010107")      # 1.2.840.113549.1.1.7
OID_SHA256 = bytes.fromhex("0609608648016503040201")          # 2.16.840.1.101.3.4.2.1
OID_AES_256_CBC = bytes.fromhex("060960864801650304012a")     # 2.16.840.1.101.3.4.1.42
OID_SHA1 = bytes.fromhex("06052b0e03021a")                    # 1.3.14.3.2.26
HEAD_BYTES = 4096


def check_sealed(head):
    """Whether the start of a DER CMS file says RSA-OAEP with SHA-256 (no SHA-1) and AES-256-CBC.
    Only the first HEAD_BYTES are read: the algorithms come before the encrypted content."""
    problems = []
    if not head.startswith(b"\x30"):
        problems.append("not a DER file")
    if OID_RSAES_OAEP not in head:
        problems.append("no RSA-OAEP")
    if OID_SHA256 not in head or OID_SHA1 in head:
        problems.append("OAEP without SHA-256")
    if OID_AES_256_CBC not in head:
        problems.append("no AES-256-CBC")
    return problems


def encrypt(tar_path, cert_der, out_path, work_dir, openssl="openssl"):
    """openssl cms: RSA-OAEP (SHA-256, MGF1 SHA-256) for the key, AES-256-CBC for the content,
    DER output. Checks the result really names those algorithms; removes a partial output on failure."""
    cert_path = os.path.join(work_dir, "recipient.pem")
    with open(cert_path, "w", encoding="ascii") as handle:
        handle.write(certificate_pem(cert_der))
    command = [openssl, "cms", "-encrypt", "-binary", "-aes-256-cbc", "-in", tar_path, "-outform", "DER",
               "-out", out_path, "-recip", cert_path, "-keyopt", "rsa_padding_mode:oaep",
               "-keyopt", "rsa_oaep_md:sha256", "-keyopt", "rsa_mgf1_md:sha256"]
    try:
        result = subprocess.run(command, capture_output=True, timeout=300)
        if result.returncode != 0:
            raise EncryptError(f"openssl cms -encrypt: exit {result.returncode} "
                               f"({one_line(result.stderr.decode('utf-8', 'replace'), 300)})")
        with open(out_path, "rb") as handle:
            problems = check_sealed(handle.read(HEAD_BYTES))
        if problems:
            raise EncryptError("the encrypted file is not what was asked for: " + ", ".join(problems))
    except (EncryptError, OSError, subprocess.SubprocessError) as error:
        try:
            os.remove(out_path)
        except OSError:
            pass
        if isinstance(error, EncryptError):
            raise
        raise EncryptError(f"openssl cms -encrypt: {one_line(error, 300)}") from None


def repo_is_private(repo, token, transport=None):
    """Asks GitHub itself whether the repository is private. Anything but a clear yes counts as public."""
    if not repo or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        return False
    headers = {"Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        status, _, body = (transport or urllib_transport)("GET", f"https://api.github.com/repos/{repo}", headers)
        return status == 200 and json.loads(body).get("private") is True
    except (OSError, ValueError, AttributeError, urllib.error.URLError):
        return False


def created_at(item):
    """The submission's createdDate as an aware datetime, or None when it cannot be read."""
    value = str((item.get("attributes") or {}).get("createdDate") or "")
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=datetime.timezone.utc)


def older_than(since):
    """A stop rule for Client.pages: true for the first submission created before since (the
    lists are sorted newest first). A date that cannot be read never stops the list."""
    def stop(item):
        created = created_at(item)
        return since is not None and created is not None and created < since
    return stop


def fetch(client, bundle_id, out_dir, max_items, download_fn=download, full=False, since=None):
    """Fetches both sections; returns (app name, screenshots, crashes, errors, access_denied, totals),
    totals being Apple's meta.paging.total per section when it sent one.
    Without full only the build and date of each submission are requested; nothing is downloaded
    and nothing is written. With since (an aware datetime) only submissions created since then."""
    apps = client.get("/v1/apps", {"filter[bundleId]": bundle_id, "fields[apps]": "bundleId,name"}, "apps")["data"]
    apps = [a for a in apps if (a.get("attributes") or {}).get("bundleId") == bundle_id] or apps
    if not apps:
        raise AppMissing(f"no app with bundle id {bundle_id} visible to this key")
    app = apps[0]
    name = f"{(app.get('attributes') or {}).get('name') or bundle_id} ({bundle_id})"
    errors, denied, totals = [], False, {}
    screenshots, crashes = [], []
    # A failing token renewal (openssl) ends one section, not the run.
    failures = (LookupError, RuntimeError, ValueError, OSError, subprocess.CalledProcessError)
    if full:
        os.makedirs(os.path.join(out_dir, "screenshots"), exist_ok=True)
        os.makedirs(os.path.join(out_dir, "crashlogs"), exist_ok=True)

    common = {"include": "build", "fields[builds]": "version", "sort": "-createdDate",
              "limit": str(min(max_items, 200))}
    try:
        items, included = client.pages(f"/v1/apps/{app['id']}/betaFeedbackScreenshotSubmissions",
                                       dict(common, **{"fields[betaFeedbackScreenshotSubmissions]":
                                                       SCREENSHOT_FIELDS if full else COUNT_FIELDS}),
                                       "betaFeedbackScreenshotSubmissions", max_items, stop=older_than(since))
        totals["screenshots"] = client.last_total
        for item in items:
            entry = {"item": item, "included": included, "files": [], "problems": []}
            images = ((item.get("attributes") or {}).get("screenshots") or []) if full else []
            for number, image in enumerate(images, 1):
                try:
                    body, ext = download_fn(str((image or {}).get("url") or ""))
                    name_ = f"screenshots/{safe_id(item.get('id'))}-{number}.{ext}"
                    with open(os.path.join(out_dir, name_), "wb") as handle:
                        handle.write(body)
                    entry["files"].append(name_)
                except (OSError, ValueError, RuntimeError, urllib.error.URLError) as error:
                    entry["problems"].append(f"Screenshot {number}: {error}")
            screenshots.append(entry)
    except AccessError as error:
        errors.append(str(error))
        denied = True
    except failures as error:
        errors.append(f"betaFeedbackScreenshotSubmissions: {one_line(error, 400)}")

    try:
        items, included = client.pages(f"/v1/apps/{app['id']}/betaFeedbackCrashSubmissions",
                                       dict(common, **{"fields[betaFeedbackCrashSubmissions]":
                                                       CRASH_FIELDS if full else COUNT_FIELDS}),
                                       "betaFeedbackCrashSubmissions", max_items, stop=older_than(since))
        totals["crashes"] = client.last_total
        for item in items:
            entry = {"item": item, "included": included, "file": "", "excerpt": "", "problems": []}
            if full:
                try:
                    log = client.get(f"/v1/betaFeedbackCrashSubmissions/{urllib.parse.quote(str(item.get('id')), safe='')}"
                                     "/crashLog", {"fields[betaCrashLogs]": "logText"}, "crashLog")
                    text = ((log.get("data") or {}).get("attributes") or {}).get("logText") or ""
                    entry["file"] = f"crashlogs/{safe_id(item.get('id'))}.txt"
                    with open(os.path.join(out_dir, entry["file"]), "w", encoding="utf-8",
                              errors="replace") as handle:
                        handle.write(text)
                    entry["excerpt"] = top_frames(text)
                except AccessError:
                    raise
                except failures as error:
                    entry["problems"].append(f"Absturzprotokoll: {one_line(error, 300)}")
            crashes.append(entry)
    except AccessError as error:
        errors.append(str(error))
        denied = True
    except failures as error:
        errors.append(f"betaFeedbackCrashSubmissions: {one_line(error, 400)}")
    return name, screenshots, crashes, errors, denied, totals


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", default="app.albumist.ios")
    parser.add_argument("--out", default="feedback", help="folder for report.md, screenshots and crash logs (full)")
    parser.add_argument("--encrypted-out", default="feedback-encrypted",
                        help="folder for the one encrypted file (encrypted); nothing else is written there")
    parser.add_argument("--recipient", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                                                            "feedback-recipient.pem"),
                        help="certificate to encrypt to (encrypted); must match RECIPIENT_SHA256")
    parser.add_argument("--days", type=int, default=DEFAULT_DAYS,
                        help="encrypted: only submissions of the last DAYS days")
    parser.add_argument("--max-items", type=int, default=200, help="per section, newest first")
    parser.add_argument("--summary", help="also write the report here (GITHUB_STEP_SUMMARY)")
    parser.add_argument("--mode", choices=["counts", "full", "encrypted"], default="counts",
                        help="counts: numbers per build only; full: comments, screenshots, crash logs "
                             "(refused unless GitHub reports the repository GITHUB_REPOSITORY as private); "
                             "encrypted: the same content of the last --days days, encrypted to --recipient")
    args = parser.parse_args(argv)
    full = args.mode == "full"
    encrypted = args.mode == "encrypted"
    if full and not repo_is_private(os.environ.get("GITHUB_REPOSITORY", ""),
                                    os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")):
        print("::error title=full refused::Mode full is refused: the repository is public (or its visibility "
              "could not be read), and tester screenshots and comments must never land in a public job summary "
              "or a downloadable artifact. Use mode counts; read the feedback itself in App Store Connect > "
              "TestFlight > Feedback.")
        return 4
    cert_der = None
    if encrypted:
        if not 1 <= args.days <= 90:
            print("::error::--days must be between 1 and 90")
            return 5
        try:
            cert_der = read_recipient(args.recipient)
        except RecipientError as error:
            print(f"::error title=encrypted refused::{one_line(error, 600)}")
            return 5
    for name in ("KEY_ID", "ISSUER_ID", "KEY_PATH"):
        if not os.environ.get(name):
            print(f"::error::{name} is not set")
            return 2
    work = None
    if encrypted:
        # Plaintext only in a fresh folder under $RUNNER_TEMP, wiped in the finally below.
        work = tempfile.mkdtemp(prefix="feedback-plain-", dir=os.environ.get("RUNNER_TEMP") or None)
        out_dir = os.path.join(work, "content")
        os.makedirs(out_dir)
    else:
        out_dir = args.out
        if full:
            os.makedirs(out_dir, exist_ok=True)
    try:
        return run(args, out_dir, work, cert_der)
    finally:
        if work:
            wipe(work)


def run(args, out_dir, work, cert_der):
    full = args.mode in ("full", "encrypted")
    encrypted = args.mode == "encrypted"
    client = Client(lambda: make_token(os.environ["KEY_ID"], os.environ["ISSUER_ID"], os.environ["KEY_PATH"]))
    now = time.time()
    generated = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(now))
    since = (datetime.datetime.fromtimestamp(now, datetime.timezone.utc) - datetime.timedelta(days=args.days)
             if encrypted else None)
    totals = {}
    try:
        app, screenshots, crashes, errors, denied, totals = fetch(client, args.bundle_id, out_dir, args.max_items,
                                                                  full=full, since=since)
    except AccessError as error:
        app, screenshots, crashes, errors, denied = args.bundle_id, [], [], [str(error)], True
    except AppMissing as error:
        print(f"::error title=App not found::{error}")
        return 3
    except (LookupError, RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as error:
        app, screenshots, crashes, errors, denied = args.bundle_id, [], [], [one_line(error, 400)], False
    if full:
        try:
            report = render(app, screenshots, crashes, errors, generated)
        except (KeyError, TypeError, ValueError, AttributeError) as error:
            report = (render_counts(app, screenshots, crashes, errors, generated, totals, args.max_items)
                      + f"\n\n**Fehler:** Bericht nicht erstellt ({md_inline(error, 300)}).\n")
            errors.append(f"report.md: {one_line(error, 300)}")
        with open(os.path.join(out_dir, "report.md"), "w", encoding="utf-8", errors="replace") as handle:
            handle.write(report)
    sealed = ""
    if encrypted:
        with open(os.path.join(out_dir, "submissions.json"), "w", encoding="utf-8") as handle:
            json.dump(submissions_index(app, screenshots, crashes, generated, args.days), handle,
                      ensure_ascii=True, indent=1)
        name = f"testflight-feedback-{time.strftime('%Y%m%d-%H%M%S', time.gmtime(now))}.cms"
        try:
            os.makedirs(args.encrypted_out, exist_ok=True)
            tar_path = os.path.join(work, "bundle.tar")
            pack(out_dir, tar_path)
            encrypt(tar_path, cert_der, os.path.join(args.encrypted_out, name), work)
            sealed = name
        except (EncryptError, OSError, tarfile.TarError) as error:
            errors.append(f"Verschlüsselung: {one_line(error, 400)}")
    # The job summary only ever gets the counts table (summaries are kept ~90 days); tester content
    # goes only into report.md inside the 7-day artifact (full, private repository) or into the
    # encrypted file (encrypted).
    if encrypted:
        summary = render_counts(app, screenshots, crashes, errors, generated, {}, args.max_items,
                                details="encrypted" if sealed else None, days=args.days)
    else:
        summary = render_counts(app, screenshots, crashes, errors, generated, totals, args.max_items,
                                details="full" if full else None)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8", errors="replace") as handle:
            handle.write(summary[:SUMMARY_LIMIT] + "\n")
    # The only signal that lets the workflow upload an artifact: full (private repository), or
    # encrypted once the file is written and checked.
    signal = "full" if args.mode == "full" else ("encrypted" if sealed else "")
    if signal and os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"mode={signal}\n")
    # Only counts and our own messages go to the log, never tester text.
    print(f"ASC_FEEDBACK mode={args.mode} screenshots={len(screenshots)} "
          f"screenshot_files={sum(len(e['files']) for e in screenshots)} crashes={len(crashes)} "
          f"crash_logs={sum(1 for e in crashes if e['file'])} errors={len(errors)}"
          + (f" encrypted={sealed}" if encrypted else ""))
    if client.rate_limit:
        print(f"ASC rate limit: {one_line(client.rate_limit, 120)}")
    for message in errors:
        print(f"::error title=App Store Connect::{one_line(message, 900)}")
    if encrypted and not sealed:
        return 5
    if denied:
        return 2
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
