# SPDX-License-Identifier: Apache-2.0
#
# setup/steps/10-decoder.sh's failure path for tar1090's installer: a run whose installer fails
# still removes the 95-tar1090-otherport.conf link (:8504, PLAN §5 ruling 7) before the step dies,
# and the installer's failure stays the step's, whatever the removal does.
#
# The step itself is not run: it needs root, apt, a readsb build and a real lighttpd. The test
# takes its install_tar1090 and close_tar1090_otherport, as written, out of the step (each
# extraction is asserted, so a renamed function fails here rather than testing nothing) and runs
# them under setup/lib.sh, with set -euo pipefail as the step has it. Around them: a fake
# installer that links the config into a temporary conf-enabled and exits 3, a stub systemctl that
# records its arguments, a stub ss that prints a fixture of listeners, and stubs for the two
# helpers the failure path never reaches past (tar1090_is_current, git_at_pin). A case may call
# close_tar1090_otherport alone, as a run whose installer succeeded or was skipped does. Needs
# bash.

import os
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
STEP = ROOT / "setup/steps/10-decoder.sh"
FUNCS = ("install_tar1090", "close_tar1090_otherport")
INSTALLER_FAIL = "xx  FAIL: tar1090's install.sh failed (exit 3); its output is above"

# The fake install.sh: links the otherport config, as tar1090's does on every run (its line 358
# at the pin), unless told not to, then fails.
INSTALLER = r"""
if [[ -z ${FAKE_NO_LINK:-} ]]; then
  ln -s ../conf-available/95-tar1090-otherport.conf "$FAKE_LINK"
fi
echo "fake install.sh: failing"
exit 3
"""


def function_text(src, name):
    m = re.search(rf"^{name}\(\) \{{\n.*?^\}}\n", src, re.M | re.S)
    return m.group(0) if m else None


class Step10OtherportOnInstallerFailure(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = pathlib.Path(self.tmp.name)
        src = STEP.read_text()
        funcs = []
        for name in FUNCS:
            text = function_text(src, name)
            self.assertIsNotNone(text, f"{name} not found in {STEP}; update this test")
            funcs.append(text)
        (t / "conf-enabled").mkdir()
        (t / "conf-available").mkdir()
        (t / "conf-available/95-tar1090-otherport.conf").write_text('$SERVER["socket"] == ":8504" {}\n')
        self.link = t / "conf-enabled/95-tar1090-otherport.conf"
        (t / "src").mkdir()
        (t / "src/install.sh").write_text(INSTALLER.lstrip())
        self.bin = t / "bin"
        self.bin.mkdir()
        self.log = t / "systemctl.log"
        self.stub("systemctl", 'echo "$*" >>"$FAKE_LOG"; exit "${FAKE_SYSTEMCTL_RC:-0}"')
        # ss -ltnH's columns: State Recv-Q Send-Q Local Peer. Prints $FAKE_SS's lines, if any.
        self.stub("ss", 'printf "%s" "${FAKE_SS:-}"')
        self.harness = t / "harness.sh"
        self.harness.write_text(
            "set -euo pipefail\n"
            f"source {ROOT / 'setup/lib.sh'}\n"
            + "".join(funcs)
            + "tar1090_is_current() { return 1; }\n"
            "git_at_pin() { :; }\n"
            "ensure_state_dir() { echo 'past the installer' >&2; }\n"
            f"OTHERPORT_LINK=${{FAKE_OTHERPORT:-{self.link}}}\n"
            f"TAR1090_SRC={t / 'src'}\n"
            f"JSON_DIR={t / 'json'}\n"
            "TAR1090_REPO=unused TAR1090_PIN=unused\n"
            '"${1:-install_tar1090}"\n'
            "echo 'past install_tar1090' >&2\n")

    def tearDown(self):
        self.tmp.cleanup()

    def stub(self, name, body):
        p = self.bin / name
        p.write_text("#!/usr/bin/env bash\n" + body + "\n")
        p.chmod(0o755)

    def run_harness(self, *args, **env):
        e = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", FAKE_LINK=str(self.link),
                 FAKE_LOG=str(self.log), **env)
        return subprocess.run(["bash", str(self.harness), *args], env=e, capture_output=True,
                              text=True, timeout=30)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def assert_installer_failure_is_the_steps(self, r):
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertEqual(r.stderr.rstrip("\n").splitlines()[-1], INSTALLER_FAIL, r.stderr)
        self.assertNotIn("past the installer", r.stderr)
        self.assertNotIn("past install_tar1090", r.stderr)

    def test_link_the_installer_made_is_removed_and_lighttpd_restarted(self):
        r = self.run_harness()
        self.assert_installer_failure_is_the_steps(r)
        self.assertFalse(os.path.lexists(self.link), "the :8504 link survived a failed installer")
        self.assertEqual(self.calls(), ["restart lighttpd"])
        self.assertNotIn("WARNING", r.stderr)

    def test_no_link_means_no_restart(self):
        r = self.run_harness(FAKE_NO_LINK="1")
        self.assert_installer_failure_is_the_steps(r)
        self.assertFalse(os.path.lexists(self.link))
        self.assertEqual(self.calls(), [])
        self.assertIn("is absent and nothing listens on port 8504", r.stdout)

    def test_failed_restart_warns_and_the_installer_failure_stays_the_steps(self):
        r = self.run_harness(FAKE_SYSTEMCTL_RC="5")
        self.assert_installer_failure_is_the_steps(r)
        self.assertFalse(os.path.lexists(self.link))
        self.assertEqual(self.calls(), ["restart lighttpd"])
        self.assertIn("!!  WARNING: closing port 8504", r.stderr)
        self.assertIn("(exit 5;", r.stderr)

    def test_failed_rm_stops_the_close_there(self):
        # errexit is on inside the close: a failed rm restarts nothing.
        self.stub("rm", "exit 4")
        r = self.run_harness()
        self.assert_installer_failure_is_the_steps(r)
        self.assertTrue(os.path.lexists(self.link))
        self.assertEqual(self.calls(), [])
        self.assertIn("(exit 4;", r.stderr)

    def test_die_inside_the_close_warns_and_the_installer_failure_stays_last(self):
        # guard_path refuses a denylisted path: a FAIL line of its own, then the warning, then
        # the installer's FAIL. The path is a missing one under /etc/ssh, so nothing is touched.
        r = self.run_harness(FAKE_OTHERPORT="/etc/ssh/adsb-test-missing/95-tar1090-otherport.conf")
        self.assert_installer_failure_is_the_steps(r)
        self.assertEqual(self.calls(), [])
        lines = r.stderr.splitlines()
        refusal = [i for i, l in enumerate(lines) if l.startswith("xx  FAIL: refusing to write")]
        warning = [i for i, l in enumerate(lines) if l.startswith("!!  WARNING: closing port 8504")]
        self.assertEqual(len(refusal), 1, r.stderr)
        self.assertEqual(len(warning), 1, r.stderr)
        self.assertLess(refusal[0], warning[0])
        self.assertIn("(exit 1;", lines[warning[0]])

    def test_absent_link_but_8504_listening_restarts_lighttpd(self):
        # A run whose rm succeeded and whose restart failed left this: no link, 8504 still open.
        r = self.run_harness("close_tar1090_otherport",
                             FAKE_SS="LISTEN 0 1024 0.0.0.0:80 0.0.0.0:*\n"
                                     "LISTEN 0 1024 0.0.0.0:8504 0.0.0.0:*\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls(), ["restart lighttpd"])
        self.assertIn("is absent, but port 8504 listens (0.0.0.0:8504)", r.stdout)

    def test_absent_link_and_nothing_on_8504_touches_nothing(self):
        r = self.run_harness("close_tar1090_otherport",
                             FAKE_SS="LISTEN 0 1024 0.0.0.0:80 0.0.0.0:*\n"
                                     "LISTEN 0 1024 [::]:18504 [::]:*\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls(), [])
        self.assertIn("is absent and nothing listens on port 8504", r.stdout)


if __name__ == "__main__":
    unittest.main()
