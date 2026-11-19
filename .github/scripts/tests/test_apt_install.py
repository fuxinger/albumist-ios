"""apt_install.sh: a dead Ubuntu mirror costs seconds and a switch, not the core tests.

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import os
import stat
import subprocess
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
SCRIPT = os.path.join(ROOT, ".github", "scripts", "apt_install.sh")

UBUNTU_SOURCES = """Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main universe restricted multiverse
"""

# A fake apt-get: logs each call; "update" fails while the sources name a host listed in
# $FAIL_HOSTS (a dead mirror), "install" fails when $FAIL_INSTALL is set.
FAKE_APT = """#!/usr/bin/env bash
echo "$*" >> "$LOG"
if [[ " $* " == *" update"* ]]; then
  for h in $FAIL_HOSTS; do
    if grep -q "//$h" "$SOURCES/sources.list.d/ubuntu.sources"; then
      echo "W: Failed to fetch http://$h/ubuntu/dists/noble/InRelease  Connection failed" >&2
      exit 100
    fi
  done
  exit 0
fi
[ -n "${FAIL_INSTALL:-}" ] && exit 100
exit 0
"""


class AptInstallTests(unittest.TestCase):
    def run_script(self, fail_hosts="", fail_install="", sources=UBUNTU_SOURCES, packages=("libsqlite3-dev", "python3")):
        tmp = tempfile.mkdtemp()
        os.makedirs(os.path.join(tmp, "apt", "sources.list.d"))
        if sources is not None:
            with open(os.path.join(tmp, "apt", "sources.list.d", "ubuntu.sources"), "w") as f:
                f.write(sources)
        fake = os.path.join(tmp, "apt-get")
        with open(fake, "w") as f:
            f.write(FAKE_APT)
        os.chmod(fake, os.stat(fake).st_mode | stat.S_IEXEC)
        log = os.path.join(tmp, "calls.log")
        open(log, "w").close()
        env = dict(os.environ, APT_GET=fake, APT_SOURCES_DIR=os.path.join(tmp, "apt"), APT_RETRY_SLEEP="0",
                   LOG=log, SOURCES=os.path.join(tmp, "apt"), FAIL_HOSTS=fail_hosts, FAIL_INSTALL=fail_install)
        result = subprocess.run(["bash", SCRIPT, *packages], env=env, capture_output=True, text=True, timeout=60)
        with open(log) as f:
            calls = f.read().splitlines()
        path = os.path.join(tmp, "apt", "sources.list.d", "ubuntu.sources")
        final = None
        if os.path.exists(path):
            with open(path) as f:
                final = f.read()
        return result, calls, final

    def test_a_working_mirror_installs_at_once(self):
        result, calls, final = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertIn("install -y -qq libsqlite3-dev python3", calls[1])
        self.assertNotIn("CI_INFRA_RETRY", result.stdout)
        self.assertEqual(final, UBUNTU_SOURCES)

    def test_a_failed_index_is_an_error_and_apt_gives_up_quickly(self):
        # 19.11.: apt ignored the failed index and waited minutes per mirror.
        _, calls, _ = self.run_script()
        self.assertIn("--error-on=any", calls[0])
        self.assertIn("Acquire::http::Timeout=20", calls[0])

    def test_a_dead_mirror_switches_to_the_azure_copy(self):
        # The case of 19.11.: archive.ubuntu.com and security.ubuntu.com unreachable.
        result, calls, final = self.run_script(fail_hosts="archive.ubuntu.com security.ubuntu.com")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CI_INFRA_RETRY apt: switched to azure.archive.ubuntu.com", result.stdout)
        self.assertEqual(result.stdout.count("CI_INFRA_RETRY apt: attempt"), 2)
        self.assertNotIn("archive.ubuntu.com/ubuntu", final.replace("azure.archive.ubuntu.com", ""))
        self.assertNotIn("security.ubuntu.com", final)
        self.assertIn("URIs: http://azure.archive.ubuntu.com/ubuntu/", final)
        self.assertIn("install -y -qq libsqlite3-dev python3", calls[-1])

    def test_it_fails_clearly_when_both_mirrors_are_dead(self):
        result, calls, _ = self.run_script(fail_hosts="archive.ubuntu.com security.ubuntu.com azure.archive.ubuntu.com")
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error::Ubuntu packages could not be installed", result.stdout)
        self.assertEqual(len(calls), 4)  # two updates per mirror, nothing installed

    def test_a_failing_install_is_retried_and_then_fails(self):
        result, calls, _ = self.run_script(fail_install="1")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(sum("install" in c for c in calls), 4)

    def test_no_sources_to_switch_stops_after_the_first_mirror(self):
        result, calls, _ = self.run_script(fail_install="1", sources=None)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no Ubuntu mirror line to switch", result.stderr)
        self.assertEqual(sum("install" in c for c in calls), 2)

    def test_no_package_named_is_an_error(self):
        result, calls, _ = self.run_script(packages=())
        self.assertEqual(result.returncode, 2)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
