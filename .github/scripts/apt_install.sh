#!/usr/bin/env bash
# Installs Ubuntu packages in the swift container of the Linux jobs.
#
# On 19.11.2026 archive.ubuntu.com could not be reached from the runners (12:06-12:20 UTC):
# apt waited 6 to 13 minutes, ignored the failed index ("W: Failed to fetch"), then found no
# package, and the core tests on main never ran. Now apt gives up on a dead mirror after 20 s,
# a failed index is an error, it tries twice, then switches to the Azure copy of the Ubuntu
# archive that GitHub's own runners use, and tries twice more. Every retry prints a CI_INFRA_RETRY
# line, so it is counted, not hidden.
#
# Usage: apt_install.sh package...
# For tests: APT_GET (the apt-get command), APT_SOURCES_DIR (default /etc/apt), APT_RETRY_SLEEP.
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "apt_install.sh: no packages named" >&2
  exit 2
fi

APT_GET="${APT_GET:-apt-get}"
SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt}"
SLEEP="${APT_RETRY_SLEEP:-10}"
FALLBACK_HOST="azure.archive.ubuntu.com"
OPTS=(-o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::Retries=1)

try_install() {
  "$APT_GET" "${OPTS[@]}" -qq --error-on=any update &&
    "$APT_GET" "${OPTS[@]}" install -y -qq "$@" > /dev/null
}

use_fallback_mirror() {
  local file changed=0
  for file in "$SOURCES_DIR"/sources.list "$SOURCES_DIR"/sources.list.d/*.list "$SOURCES_DIR"/sources.list.d/*.sources; do
    [ -f "$file" ] || continue
    if grep -Eq '(archive|security)\.ubuntu\.com' "$file"; then
      sed -i -E "s#https?://(archive|security)\.ubuntu\.com#http://$FALLBACK_HOST#g" "$file"
      changed=1
    fi
  done
  [ "$changed" -eq 1 ]
}

attempt=0
for mirror in primary fallback; do
  if [ "$mirror" = fallback ]; then
    if ! use_fallback_mirror; then
      echo "CI_INFRA_RETRY apt: no Ubuntu mirror line to switch in $SOURCES_DIR" >&2
      break
    fi
    echo "CI_INFRA_RETRY apt: switched to $FALLBACK_HOST"
  fi
  for _ in 1 2; do
    attempt=$((attempt + 1))
    if try_install "$@"; then
      if [ "$attempt" -gt 1 ]; then
        echo "apt_install.sh: installed on attempt $attempt ($mirror mirror)"
        # Visible in the check's annotations and the job summary, not only in the log: an
        # environment retry is counted and fixed at its cause, never hidden (rule of 17.11.).
        echo "::warning title=Environment retry (apt)::Ubuntu packages installed on attempt $attempt ($mirror mirror) after $((attempt - 1)) failed attempt(s); the mirror is a finding to fix, not a test result"
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
          echo "- Environment retry (apt): installed on attempt $attempt ($mirror mirror)" >> "$GITHUB_STEP_SUMMARY"
        fi
      fi
      exit 0
    fi
    echo "CI_INFRA_RETRY apt: attempt $attempt failed ($mirror mirror)"
    sleep "$SLEEP"
  done
done

echo "::error::Ubuntu packages could not be installed ($*) after $attempt attempts on two mirrors."
exit 1
