"""Sets the German "Was testen" (What to Test) text of one TestFlight build.

  python3 testflight_notes.py text  --notes docs/TESTFLIGHT_NOTES.md --build 28 --sha abc1234
      Prints the text: the part of the notes file between the markers
      <!-- testflight:start --> and <!-- testflight:end -->, as plain text, plus a line with the
      build number and commit. At most 4000 characters (App Store Connect's limit). Every
      build has passed its tests (testflight.yml has no way to upload without them), so the
      text carries no warning of its own.
  python3 testflight_notes.py upload --notes ... --build 28 --sha ... --bundle-id app.albumist.ios
      Waits (bounded) until App Store Connect knows the build, then writes the text into the
      build's German beta localization (creates it if missing). Same API key as the upload:
      KEY_ID, ISSUER_ID and KEY_PATH (the .p8 file) in the environment. Exit 0 also on failure,
      with a warning: the build itself is uploaded already and stays usable.

The JWT is signed with the openssl command line tool, so no Python packages are needed.
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ASC = "https://api.appstoreconnect.apple.com/v1"
LIMIT = 4000


def render(notes_path, build, sha):
    with open(notes_path, encoding="utf-8") as f:
        source = f.read()
    match = re.search(r"<!--\s*testflight:start\s*-->(.*?)<!--\s*testflight:end\s*-->", source, re.S)
    body = match.group(1) if match else source
    lines = []
    for line in body.strip().splitlines():
        line = re.sub(r"^#+\s*", "", line)                       # headings
        line = re.sub(r"^(\s*)[-*]\s+", r"\1• ", line)            # bullets
        line = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1 (\2)", line)  # links
        line = re.sub(r"(\*\*|__|`)", "", line)                  # bold, code
        line = re.sub(r"(?<!\w)[*_](\S[^*_]*?)[*_](?!\w)", r"\1", line)  # italics
        lines.append(line.rstrip())
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()
    footer = f"\n\nBuild {build} · {sha[:7]}"
    if len(text) + len(footer) > LIMIT:
        text = text[: LIMIT - len(footer) - 1].rstrip() + "…"
    return text + footer


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der):
    """ECDSA signature from openssl (DER sequence of r and s) to the 64-byte JWS form."""
    if der[0] != 0x30:
        raise ValueError("unexpected signature format")
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        if der[index] != 0x02:
            raise ValueError("unexpected signature format")
        length = der[index + 1]
        value = der[index + 2: index + 2 + length].lstrip(b"\x00")
        parts.append(value.rjust(32, b"\x00"))
        index += 2 + length
    return b"".join(parts)


def token():
    header = {"alg": "ES256", "kid": os.environ["KEY_ID"], "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": os.environ["ISSUER_ID"], "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64(json.dumps(header).encode())}.{b64(json.dumps(payload).encode())}"
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.environ["KEY_PATH"]],
                         input=signing_input.encode(), capture_output=True, check=True).stdout
    return f"{signing_input}.{b64(der_to_raw(der))}"


def call(method, path, body=None, **params):
    url = f"{ASC}/{path}" + ("?" + urllib.parse.urlencode(params) if params else "")
    request = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None, headers={
        "Authorization": f"Bearer {token()}",
        "Content-Type": "application/json",
    })
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
        return json.loads(data) if data else {}


def upload(args):
    text = render(args.notes, args.build, args.sha)
    print("WHAT_TO_TEST\n" + text + "\n")
    deadline = time.monotonic() + args.wait_minutes * 60
    last_error = ""
    while True:
        try:
            apps = call("GET", "apps", **{"filter[bundleId]": args.bundle_id, "fields[apps]": "bundleId"})["data"]
            if not apps:
                raise LookupError(f"no app with bundle id {args.bundle_id}")
            builds = call("GET", "builds", **{"filter[app]": apps[0]["id"], "filter[version]": str(args.build),
                                              "fields[builds]": "version,processingState", "limit": "5"})["data"]
            if not builds:
                raise LookupError(f"build {args.build} not in App Store Connect yet")
            build = builds[0]
            state = build["attributes"].get("processingState")
            localizations = call("GET", f"builds/{build['id']}/betaBuildLocalizations",
                                 **{"fields[betaBuildLocalizations]": "locale,whatsNew"})["data"]
            german = [l for l in localizations if l["attributes"]["locale"].lower().startswith("de")]
            for loc in german:
                call("PATCH", f"betaBuildLocalizations/{loc['id']}", {"data": {
                    "type": "betaBuildLocalizations", "id": loc["id"], "attributes": {"whatsNew": text}}})
            if not german:
                call("POST", "betaBuildLocalizations", {"data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {"locale": "de-DE", "whatsNew": text},
                    "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}}}})
            done = [l["attributes"]["locale"] for l in german] or ["de-DE (new)"]
            print(f"TESTFLIGHT_NOTES set for build {args.build} ({state}): {', '.join(done)}")
            with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a", encoding="utf-8") as out:
                out.write(f"### Was testen (Build {args.build})\n\n```\n{text}\n```\n")
            return 0
        except urllib.error.HTTPError as error:
            last_error = f"HTTP {error.code}: {error.read().decode(errors='replace')[:300]}"
        except (urllib.error.URLError, TimeoutError, LookupError, KeyError, ValueError,
                subprocess.CalledProcessError) as error:
            last_error = str(error)
        print(f"NOTES waiting: {last_error}", flush=True)
        if time.monotonic() > deadline:
            print(f"::warning title=What to Test not set::Build {args.build} is uploaded, but its "
                  f"'Was testen' text could not be set within {args.wait_minutes} min: {last_error}")
            return 0
        time.sleep(30)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["text", "upload"])
    parser.add_argument("--notes", default="docs/TESTFLIGHT_NOTES.md")
    parser.add_argument("--build", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--bundle-id", default="app.albumist.ios")
    parser.add_argument("--wait-minutes", type=float, default=40)
    args = parser.parse_args()
    if args.command == "text":
        print(render(args.notes, args.build, args.sha))
        return 0
    return upload(args)


if __name__ == "__main__":
    sys.exit(main())
