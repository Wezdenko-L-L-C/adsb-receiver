# SPDX-License-Identifier: Apache-2.0
#
# setup/steps/15-stationary-position.sh's reading of `systemctl list-units --plain --no-legend`:
# position_instances names each adsb-position@ instance whether or not systemd prints a leading
# "●" (a failed or not-found unit may carry one even with --plain, depending on the version), and
# need_reload and stop_instances act on those names, never on the marker.
#
# The step itself is not run: it needs root and systemd. The test takes position_instances,
# need_reload and stop_instances, as written, out of the step (each extraction is asserted, so a
# renamed function fails here rather than testing nothing) and runs them under setup/lib.sh, with
# set -euo pipefail as the step has it, on a stub systemctl that prints a fixture for list-units,
# answers NeedDaemonReload from a fixture, and records every call. Needs bash.

import os
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
STEP = ROOT / "setup/steps/15-stationary-position.sh"
FUNCS = ("position_instances", "need_reload", "stop_instances")

RUNNING = "adsb-position@0-127.0.0.1:2947-127.0.0.1:53008.service loaded active running Position responder\n"
FAILED = "● adsb-position@1-127.0.0.1:2947-127.0.0.1:53010.service loaded failed failed Position responder\n"
FAILED_BARE = "adsb-position@1-127.0.0.1:2947-127.0.0.1:53010.service loaded failed failed Position responder\n"
NAME0 = "adsb-position@0-127.0.0.1:2947-127.0.0.1:53008.service"
NAME1 = "adsb-position@1-127.0.0.1:2947-127.0.0.1:53010.service"

# list-units prints $FAKE_UNITS; show -p NeedDaemonReload prints yes for the unit named in
# $FAKE_RELOAD, no otherwise.
SYSTEMCTL = r"""
echo "$*" >>"$FAKE_LOG"
case $1 in
  list-units) printf '%s' "${FAKE_UNITS:-}" ;;
  show) for a in "$@"; do last=$a; done
        if [[ $last == "${FAKE_RELOAD:-}" ]]; then echo yes; else echo no; fi ;;
esac
"""


def function_text(src, name):
    m = re.search(rf"^{name}\(\) \{{\n.*?^\}}\n", src, re.M | re.S)
    return m.group(0) if m else None


class Step15Instances(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = pathlib.Path(self.tmp.name)
        src = STEP.read_text()
        funcs = []
        for name in FUNCS:
            text = function_text(src, name)
            self.assertIsNotNone(text, f"{name} not found in {STEP}; update this test")
            funcs.append(text)
        self.bin = t / "bin"
        self.bin.mkdir()
        stub = self.bin / "systemctl"
        stub.write_text("#!/bin/bash\n" + SYSTEMCTL.lstrip())
        stub.chmod(0o755)
        self.log = t / "systemctl.log"
        self.harness = t / "harness.sh"
        self.harness.write_text(
            "set -euo pipefail\n"
            f"source {ROOT / 'setup/lib.sh'}\n"
            + "".join(funcs)
            + "SOCKET=adsb-position.socket\n"
            '"$@"\n')

    def tearDown(self):
        self.tmp.cleanup()

    def run_harness(self, *args, units="", reload=""):
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", FAKE_LOG=str(self.log),
                   FAKE_UNITS=units, FAKE_RELOAD=reload)
        return subprocess.run(["bash", str(self.harness), *args], env=env,
                              capture_output=True, text=True)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_names_with_and_without_the_marker(self):
        for failed in (FAILED, FAILED_BARE):
            with self.subTest(marker=failed.startswith("●")):
                r = self.run_harness("position_instances", "--all", units=RUNNING + failed)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout.splitlines(), [NAME0, NAME1])

    def test_no_instances_prints_nothing(self):
        r = self.run_harness("position_instances", units="")
        self.assertEqual((r.returncode, r.stdout), (0, ""), r.stderr)

    def test_need_reload_reads_the_marked_instance_by_name(self):
        r = self.run_harness("need_reload", units=RUNNING + FAILED, reload=NAME1)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"show -p NeedDaemonReload --value {NAME1}", self.calls())
        self.assertFalse(any("●" in c for c in self.calls() if c.startswith("show")))

    def test_need_reload_says_no_when_nothing_needs_it(self):
        r = self.run_harness("need_reload", units=RUNNING + FAILED)
        self.assertEqual(r.returncode, 1, r.stderr)

    def test_stop_instances_stops_each_by_name(self):
        r = self.run_harness("stop_instances", units=RUNNING + FAILED)
        self.assertEqual(r.returncode, 0, r.stderr)
        stops = [c for c in self.calls() if c.startswith("stop ")]
        self.assertEqual(stops, [f"stop {NAME0}", f"stop {NAME1}"])


if __name__ == "__main__":
    unittest.main()
