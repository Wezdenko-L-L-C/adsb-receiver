# SPDX-License-Identifier: Apache-2.0
#
# setup/steps/58-maintenance-window.sh's two journal- and sudo-reading checks: the stationary's
# no_sudo_grant_opens_window, which asks sudo itself whether any account but root may start or stop
# either window unit, and window_order, which reads the last window's writer stop and update start
# from the journal.
#
# The step itself is not run: it needs root and systemd. The test takes the step's text from its
# "# window_order:" comment up to `verify() {`, as written (a missing cut fails here rather than
# testing nothing), and runs one function under setup/lib.sh with set -euo pipefail. Around it,
# stubs on PATH: getent prints a passwd fixture; sudo answers `-n -l -U <user> <command>` from a
# grants fixture as sudo's manual describes (exit 0 and the command when allowed, exit 1 and "is
# not allowed to run sudo" when not, a "sudo:" error line for a broken sudoers); journalctl prints a
# journal fixture. The refusal and error texts are sudo's documented forms, not read from a rig.
# Needs bash.

import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
STEP = ROOT / "setup/steps/58-maintenance-window.sh"
W = "adsb-maintenance-window.service"
OLD = "adsb-pull-window.service"
WR = "adsb-writer.service"
UP = "adsb-update.service"

STUBS = {
    "getent": 'cat "$FIX/passwd"\n',
    "journalctl": 'cat "$FIX/journal"\n',
    "sudo": r'''
[[ $1 == -n && $2 == -l && $3 == -U ]] || { echo "sudo stub: unexpected $*" >&2; exit 2; }
u=$4; shift 4; cmd="$*"
if [[ -f $FIX/error.$u ]]; then echo "sudo: parse error in /etc/sudoers.d/broken near line 1"; exit 1; fi
if grep -qxF "$u ALL" "$FIX/grants" || grep -qxF "$u $cmd" "$FIX/grants"; then echo "$1"; exit 0; fi
echo "User $u is not allowed to run sudo on stub."
exit 1
''',
}

PASSWD = """\
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
chris:x:1000:1000:,,,:/home/chris:/bin/bash
adsb-receiver:x:999:999::/nonexistent:/usr/sbin/nologin
"""


def jline(sec, text):
    return f"2026-11-22T04:30:{sec:02d}.000000-0700 stub systemd[1]: {text}\n"


class Step58(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = pathlib.Path(self.tmp.name)
        src = STEP.read_text()
        start = src.find("# window_order: if a window ran")
        end = src.find("verify() {\n")
        self.assertTrue(0 <= start < end, f"the checks were not found in {STEP}; update this test")
        self.body = src[start:end]
        for fn in ("window_order() {", "sudo_refuses() {", "no_sudo_grant_opens_window() {"):
            self.assertIn(fn, self.body, f"{fn} not found; update this test")
        self.fix = t / "fix"
        self.fix.mkdir()
        stubs = t / "bin"
        stubs.mkdir()
        for name, text in STUBS.items():
            (stubs / name).write_text("#!/usr/bin/env bash\n" + text.lstrip())
            (stubs / name).chmod(0o755)
        self.t = t
        self.env = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}", FIX=str(self.fix))
        (self.fix / "passwd").write_text(PASSWD)
        (self.fix / "grants").write_text("root ALL\n")
        (self.fix / "journal").write_text("")

    def tearDown(self):
        self.tmp.cleanup()

    def run_fn(self, fn):
        script = self.t / "run.sh"
        script.write_text(
            "set -euo pipefail\n"
            f'source "{ROOT}/setup/lib.sh"\n'
            f"WINDOW={W} OLD_WINDOW={OLD} WRITER={WR} UPDATE={UP} SYSTEMCTL=/usr/bin/systemctl\n"
            + self.body + f"{fn}\n"
        )
        return subprocess.run(["bash", str(script)], env=self.env, capture_output=True, text=True, timeout=60)

    def grant(self, *lines):
        (self.fix / "grants").write_text("root ALL\n" + "".join(l + "\n" for l in lines))

    def journal(self, *lines):
        (self.fix / "journal").write_text("".join(jline(i, l) for i, l in enumerate(lines)))

    # --- sudo -----------------------------------------------------------------------------

    def test_no_grant_passes(self):
        r = self.run_fn("no_sudo_grant_opens_window")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("to each of the 3 accounts but root, except those holding a general grant (none)", r.stdout)

    def test_a_general_grant_is_named_not_failed(self):
        self.grant("chris ALL")
        r = self.run_fn("no_sudo_grant_opens_window")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("holding a general grant (chris)", r.stdout)

    def test_a_grant_naming_the_new_window_fails(self):
        self.grant(f"chris /usr/bin/systemctl stop {W}")
        r = self.run_fn("no_sudo_grant_opens_window")
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn(f"chris: /usr/bin/systemctl stop {W}", r.stderr)

    def test_a_grant_to_a_service_account_for_the_old_window_fails(self):
        self.grant(f"adsb-receiver /usr/bin/systemctl start {OLD}")
        r = self.run_fn("no_sudo_grant_opens_window")
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn(f"adsb-receiver: /usr/bin/systemctl start {OLD}", r.stderr)

    def test_a_sudo_error_is_not_a_refusal(self):
        (self.fix / "error.daemon").write_text("")
        r = self.run_fn("no_sudo_grant_opens_window")
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("is not a plain refusal", r.stderr)

    # --- window_order --------------------------------------------------------------------

    def test_no_window_warns(self):
        self.journal(f"Started {WR} - writer.")
        r = self.run_fn("window_order")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("no maintenance window has run this boot", r.stderr)

    def test_writer_stopped_then_update_passes(self):
        self.journal(f"Started {WR} - w.", f"Stopping {WR} - w...", f"Stopped {WR} - w.",
                     f"Starting {W} - m...", f"Started {W} - m.", f"Starting {UP} - u...")
        r = self.run_fn("window_order")
        self.assertIn("stopped the writer before the update started", r.stdout, r.stderr)

    def test_update_logged_before_the_window_but_after_the_stop_passes(self):
        self.journal(f"Started {WR} - w.", f"Stopping {WR} - w...", f"Stopped {WR} - w.",
                     f"Starting {UP} - u...", f"Starting {OLD} - p...")
        r = self.run_fn("window_order")
        self.assertIn("stopped the writer before the update started", r.stdout, r.stderr)

    def test_an_earlier_boot_run_is_not_this_windows_update(self):
        self.journal(f"Started {WR} - w.", f"Starting {UP} - u...", f"Stopping {WR} - w...",
                     f"Stopped {WR} - w.", f"Starting {W} - m...", f"Starting {UP} - u...")
        r = self.run_fn("window_order")
        self.assertIn("stopped the writer before the update started", r.stdout, r.stderr)

    def test_update_during_the_writer_stop_warns(self):
        self.journal(f"Started {WR} - w.", f"Stopping {WR} - w...", f"Starting {UP} - u...",
                     f"Stopped {WR} - w.", f"Starting {W} - m...")
        r = self.run_fn("window_order")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("THE UPDATE STARTED BEFORE THE WRITER STOPPED", r.stderr)

    def test_writer_not_running_at_the_second_window_warns(self):
        self.journal(f"Stopping {WR} - w...", f"Stopped {WR} - w.", f"Starting {W} - m...",
                     f"Starting {UP} - u...", f"Stopped {W} - m.", f"Starting {W} - m...",
                     f"Starting {UP} - u...")
        r = self.run_fn("window_order")
        self.assertIn("shows no writer stop", r.stderr)


if __name__ == "__main__":
    unittest.main()
