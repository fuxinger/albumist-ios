"""Fetches TestFlight feedback (screenshots with comments) and crash reports of one app.

  python3 asc_feedback.py --bundle-id app.albumist.ios --out feedback [--summary FILE] [--summary-mode full|counts]

Uses the App Store Connect API with the same team key as the TestFlight upload: KEY_ID,
ISSUER_ID and KEY_PATH (the .p8 file) in the environment. The JWT is signed with the openssl
command line tool like testflight_notes.py, so no Python packages are needed.

Endpoints (App Store Connect API 4.0, checked against Apple's documentation 16.11.2026):
  GET /v1/apps?filter[bundleId]=...
  GET /v1/apps/{id}/betaFeedbackScreenshotSubmissions   (comment, device, screenshots[].url)
  GET /v1/apps/{id}/betaFeedbackCrashSubmissions        (comment, device)
  GET /v1/betaFeedbackCrashSubmissions/{id}/crashLog    (logText)
Apple allows these for keys with the role Admin, App Manager or Developer; any other role
(Marketing, Sales, Finance, Customer Support, ...) gets 403.

Writes into --out: report.md, screenshots/<submission>-<n>.<ext>, crashlogs/<submission>.txt.
Everything testers send is untrusted text: it is only written into files (Markdown escaped, crash
logs in code fences), never printed to the log, where a line starting with "::" would be read as
a workflow command. Tester e-mail addresses and names are never requested (public repository).

Exit codes: 0 all fetched, 1 a section failed (report written with what worked), 2 the key is
not accepted or lacks the role, 3 no app with that bundle id.
"""
import argparse
import html
import json
import os
import re
import subprocess
import sys
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
            "role, then update the GitHub secrets ASC_KEY_ID and ASC_KEY_P8).")
SCREENSHOT_FIELDS = ("createdDate,comment,deviceModel,deviceFamily,osVersion,appPlatform,locale,"
                     "connectionType,batteryPercentage,appUptimeInMilliseconds,screenshots,build")
CRASH_FIELDS = ("createdDate,comment,deviceModel,deviceFamily,osVersion,appPlatform,locale,"
                "connectionType,batteryPercentage,appUptimeInMilliseconds,build")
MAX_DOWNLOAD = 25 * 1024 * 1024
SUMMARY_LIMIT = 900_000          # GitHub allows 1 MiB per step summary
TOKEN_LIFETIME = 15 * 60         # Apple accepts at most 20 minutes


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

def urllib_transport(method, url, headers):
    """Returns (status, headers, body). HTTP errors are returned, not raised."""
    request = urllib.request.Request(url, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, dict(response.headers), response.read(MAX_DOWNLOAD + 1)
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers or {}), error.read(64 * 1024)


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


def one_line(text, limit):
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text)).strip()
    return text[:limit]


class Client:
    def __init__(self, token_factory, transport=urllib_transport, sleep=time.sleep, clock=time.monotonic,
                 retries=4):
        self.token_factory = token_factory
        self.transport = transport
        self.sleep = sleep
        self.clock = clock
        self.retries = retries
        self._token = None
        self._token_at = 0.0
        self.rate_limit = ""

    def token(self):
        if self._token is None or self.clock() - self._token_at > TOKEN_LIFETIME - 5 * 60:
            self._token = self.token_factory()
            self._token_at = self.clock()
            if os.environ.get("GITHUB_ACTIONS") == "true":
                print(f"::add-mask::{self._token}", flush=True)
        return self._token

    def get(self, path_or_url, params=None, what="App Store Connect"):
        url = path_or_url if path_or_url.startswith("https://") else f"{API}{path_or_url}"
        if not url.startswith(API + "/"):
            raise ValueError("refusing to send the API token to another host")
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params, safe="[],")
        for attempt in range(self.retries + 1):
            status, headers, body = self.transport("GET", url, {"Authorization": f"Bearer {self.token()}",
                                                               "Accept": "application/json"})
            self.rate_limit = {k.lower(): v for k, v in headers.items()}.get("x-rate-limit", self.rate_limit)
            if status == 200:
                return json.loads(body)
            if status == 401:
                raise AccessError(
                    f"{what}: HTTP 401, App Store Connect does not accept the key ({apple_error(body)}). "
                    "Check that ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 belong to the same team key and that "
                    "the key is not revoked (App Store Connect > Users and Access > Integrations).")
            if status == 403:
                raise AccessError(
                    f"{what}: HTTP 403, the key's role may not read this ({apple_error(body)}). "
                    f"TestFlight feedback and crash logs need a team key with the role {ROLES}. {ROLE_FIX}")
            if status == 404:
                raise LookupError(f"{what}: HTTP 404 ({apple_error(body)})")
            if (status == 429 or status >= 500) and attempt < self.retries:
                wait = retry_after(headers, attempt)
                print(f"ASC {what}: HTTP {status}, retrying in {wait:.0f} s", flush=True)
                self.sleep(wait)
                continue
            raise RuntimeError(f"{what}: HTTP {status} ({apple_error(body)})")
        raise RuntimeError(f"{what}: no answer")  # pragma: no cover

    def pages(self, path, params, what, max_items):
        """All items of a paged list (follows links.next), with the included resources by (type, id)."""
        items, included, seen = [], {}, set()
        url, query, visited = path, dict(params), set()
        while url and len(items) < max_items:
            page = self.get(url, query, what)
            for resource in page.get("included", []) or []:
                included[(resource.get("type"), resource.get("id"))] = resource
            for item in page.get("data", []) or []:
                if item.get("id") in seen:
                    continue
                seen.add(item.get("id"))
                items.append(item)
                if len(items) >= max_items:
                    break
            nxt = (page.get("links") or {}).get("next")
            if not nxt or nxt in visited:
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


def download(url, transport=urllib_transport):
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

MD_SPECIAL = re.compile(r"([\\`*_{}\[\]()#+\-.!|~>:])")


def md_text(value, limit=4000):
    """Untrusted text as inert Markdown: no HTML, no links, images, mentions or table breaks."""
    text = str(value or "")
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f‪-‮⁦-⁩]", "", text)
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
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text or "")
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
    if a.get("appUptimeInMilliseconds") is not None:
        rows.append(("App lief", md_inline(f"{int(a['appUptimeInMilliseconds']) // 1000} s")))
    return "\n".join(f"- {key}: {value}" for key, value in rows)


def render(app, screenshots, crashes, errors, generated, counts_only=False):
    out = [f"# TestFlight-Feedback {md_inline(app)}", "",
           f"Abgeholt: {md_inline(generated)} · {len(screenshots)} Feedback mit Screenshot · "
           f"{len(crashes)} Absturzberichte", ""]
    for message in errors:
        out += [f"**Fehler:** {md_inline(message, 600)}", ""]
    if counts_only:
        out += ["Inhalte (Kommentare, Screenshots, Absturzprotokolle) stehen nur im Bericht des Laufs, "
                "nicht in dieser Zusammenfassung.", ""]
        return "\n".join(out)
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


def fetch(client, bundle_id, out_dir, max_items, download_fn=download):
    """Fetches both sections; returns (app name, screenshots, crashes, errors, access_denied)."""
    apps = client.get("/v1/apps", {"filter[bundleId]": bundle_id, "fields[apps]": "bundleId,name"}, "apps")["data"]
    apps = [a for a in apps if (a.get("attributes") or {}).get("bundleId") == bundle_id] or apps
    if not apps:
        raise AppMissing(f"no app with bundle id {bundle_id} visible to this key")
    app = apps[0]
    name = f"{(app.get('attributes') or {}).get('name') or bundle_id} ({bundle_id})"
    errors, denied = [], False
    screenshots, crashes = [], []
    os.makedirs(os.path.join(out_dir, "screenshots"), exist_ok=True)
    os.makedirs(os.path.join(out_dir, "crashlogs"), exist_ok=True)

    common = {"include": "build", "fields[builds]": "version", "sort": "-createdDate",
              "limit": str(min(max_items, 200))}
    try:
        items, included = client.pages(f"/v1/apps/{app['id']}/betaFeedbackScreenshotSubmissions",
                                       dict(common, **{"fields[betaFeedbackScreenshotSubmissions]": SCREENSHOT_FIELDS}),
                                       "betaFeedbackScreenshotSubmissions", max_items)
        for item in items:
            entry = {"item": item, "included": included, "files": [], "problems": []}
            images = (item.get("attributes") or {}).get("screenshots") or []
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
    except (LookupError, RuntimeError, ValueError, OSError) as error:
        errors.append(f"betaFeedbackScreenshotSubmissions: {error}")

    try:
        items, included = client.pages(f"/v1/apps/{app['id']}/betaFeedbackCrashSubmissions",
                                       dict(common, **{"fields[betaFeedbackCrashSubmissions]": CRASH_FIELDS}),
                                       "betaFeedbackCrashSubmissions", max_items)
        for item in items:
            entry = {"item": item, "included": included, "file": "", "excerpt": "", "problems": []}
            try:
                log = client.get(f"/v1/betaFeedbackCrashSubmissions/{urllib.parse.quote(str(item.get('id')), safe='')}"
                                 "/crashLog", {"fields[betaCrashLogs]": "logText"}, "crashLog")
                text = ((log.get("data") or {}).get("attributes") or {}).get("logText") or ""
                entry["file"] = f"crashlogs/{safe_id(item.get('id'))}.txt"
                with open(os.path.join(out_dir, entry["file"]), "w", encoding="utf-8") as handle:
                    handle.write(text)
                entry["excerpt"] = top_frames(text)
            except AccessError:
                raise
            except (LookupError, RuntimeError, ValueError, OSError) as error:
                entry["problems"].append(f"Absturzprotokoll: {error}")
            crashes.append(entry)
    except AccessError as error:
        errors.append(str(error))
        denied = True
    except (LookupError, RuntimeError, ValueError, OSError) as error:
        errors.append(f"betaFeedbackCrashSubmissions: {error}")
    return name, screenshots, crashes, errors, denied


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", default="app.albumist.ios")
    parser.add_argument("--out", default="feedback")
    parser.add_argument("--max-items", type=int, default=100, help="per section, newest first")
    parser.add_argument("--summary", help="also write the report here (GITHUB_STEP_SUMMARY)")
    parser.add_argument("--summary-mode", choices=["full", "counts"], default="full")
    args = parser.parse_args(argv)
    for name in ("KEY_ID", "ISSUER_ID", "KEY_PATH"):
        if not os.environ.get(name):
            print(f"::error::{name} is not set")
            return 2
    os.makedirs(args.out, exist_ok=True)
    client = Client(lambda: make_token(os.environ["KEY_ID"], os.environ["ISSUER_ID"], os.environ["KEY_PATH"]))
    generated = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
    try:
        app, screenshots, crashes, errors, denied = fetch(client, args.bundle_id, args.out, args.max_items)
    except AccessError as error:
        app, screenshots, crashes, errors, denied = args.bundle_id, [], [], [str(error)], True
    except AppMissing as error:
        print(f"::error title=App not found::{error}")
        return 3
    except (LookupError, RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as error:
        app, screenshots, crashes, errors, denied = args.bundle_id, [], [], [one_line(error, 400)], False
    report = render(app, screenshots, crashes, errors, generated)
    with open(os.path.join(args.out, "report.md"), "w", encoding="utf-8") as handle:
        handle.write(report)
    if args.summary:
        summary = render(app, screenshots, crashes, errors, generated, counts_only=args.summary_mode == "counts")
        if len(summary.encode()) > SUMMARY_LIMIT:
            summary = summary.encode()[:SUMMARY_LIMIT].decode(errors="ignore") + \
                "\n\n(gekürzt, vollständig in report.md im Artefakt)\n"
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write(summary + "\n")
    # Only counts and our own messages go to the log, never tester text.
    print(f"ASC_FEEDBACK screenshots={len(screenshots)} "
          f"screenshot_files={sum(len(e['files']) for e in screenshots)} crashes={len(crashes)} "
          f"crash_logs={sum(1 for e in crashes if e['file'])} errors={len(errors)}")
    if client.rate_limit:
        print(f"ASC rate limit: {one_line(client.rate_limit, 120)}")
    for message in errors:
        print(f"::error title=App Store Connect::{one_line(message, 900)}")
    if denied:
        return 2
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
