# SPDX-License-Identifier: Apache-2.0
#
# tools/pull-archive, run end to end against a fake rig in a temporary directory: the live pull
# (the default) and --end-session (Chris, 2026-11-11), and the clock check both run.
#
# No rig and no network. Stubs on PATH stand in for the rig's side:
#   - ssh: skips the -o options and the host, rewrites the rig's archive path to the fake one, logs
#     the command, and runs it here with bash (stdin passed through, so `sh -s` scripts run);
#     FAKE_SSH_FAIL, a substring, makes a matching command exit 255 as a dropped link would, and
#     FAKE_SSH_BANNER is printed before every command's output, as a rig's shell startup might;
#   - rsync: drops -e, rewrites host:<archive> to the fake one, and runs the real rsync locally,
#     then prints FAKE_RSYNC_VANISH "file has vanished" lines to stderr and exits FAKE_RSYNC_RC if
#     it is set (24 is "source files vanished");
#   - systemctl and sudo: is-active reads the writer's and the window's state from files; sudo's
#     start of the window stops the writer, its stop starts it and writes a fresh .part, as the
#     window's units do on the rig; every call is logged;
#   - chronyc: `-n sources` prints a table with or without a selected ('*') line, `-n -c tracking`
#     a CSV line whose reference time is FAKE_REF_AGE seconds old; FAKE_CHRONY_FAIL fails both.
# The date directories are named from this machine's UTC clock, which is the fake rig's.
# Needs bash and rsync.

import datetime
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOL = ROOT / "tools/pull-archive"
RIG_ARCHIVE = "/var/lib/adsb-receiver/archive"
HOST = "rig.invalid"

SSH = r"""
args=("$@")
i=0
while [[ ${args[i]} == -o ]]; do i=$((i + 2)); done
i=$((i + 1))  # the host
cmd="${args[*]:i}"
cmd=${cmd//"$RIG_ARCHIVE"/"$FAKE_ARCHIVE"}
printf 'ssh %s\n' "$cmd" >>"$FAKE_LOG"
[[ -z ${FAKE_SSH_BANNER:-} ]] || echo "$FAKE_SSH_BANNER"
if [[ -n ${FAKE_SSH_FAIL:-} && $cmd == *"$FAKE_SSH_FAIL"* ]]; then exit 255; fi
exec bash -c "$cmd"
"""

RSYNC = r"""
out=()
while (($#)); do
  case $1 in
    -e) shift ;;
    "$FAKE_HOST:"*) a=${1#"$FAKE_HOST:"}; out+=("${a//"$RIG_ARCHIVE"/"$FAKE_ARCHIVE"}") ;;
    *) out+=("$1") ;;
  esac
  shift
done
printf 'rsync %s\n' "${out[*]}" >>"$FAKE_LOG"
rc=0
"$FAKE_REAL_RSYNC" "${out[@]}" || rc=$?
for ((k = 0; k < ${FAKE_RSYNC_VANISH:-0}; k++)); do
  echo "file has vanished: \"/somewhere/$k\"" >&2
done
exit "${FAKE_RSYNC_RC:-$rc}"
"""

SYSTEMCTL = r"""
printf 'systemctl %s\n' "$*" >>"$FAKE_LOG"
if [[ $1 == is-active ]]; then
  case $2 in
    adsb-writer.service) s=$(cat "$FAKE_STATE/writer") ;;
    adsb-pull-window.service) s=$(cat "$FAKE_STATE/window") ;;
    *) s=inactive ;;
  esac
  echo "$s"
  [[ $s == active ]]
  exit
fi
"""

SUDO = r"""
printf 'sudo %s\n' "$*" >>"$FAKE_LOG"
[[ $1 == -n ]] && shift
if [[ "$1 $2 $3" == "systemctl start adsb-pull-window.service" ]]; then
  echo active >"$FAKE_STATE/window"; echo inactive >"$FAKE_STATE/writer"
elif [[ "$1 $2 $3" == "systemctl stop adsb-pull-window.service" ]]; then
  echo inactive >"$FAKE_STATE/window"; echo active >"$FAKE_STATE/writer"
  d=$FAKE_ARCHIVE/beast/$(date -u +%Y-%m-%d)
  mkdir -p "$d"
  touch -d "@$(($(date +%s) + 5))" "$d/new.beast.pcap.part"
fi
"""

CHRONYC = r"""
[[ -z ${FAKE_CHRONY_FAIL:-} ]] || { echo "506 Cannot talk to daemon" >&2; exit 1; }
if [[ "$*" == "-n sources" ]]; then
  echo "MS Name/IP address         Stratum Poll Reach LastRx Last sample"
  echo "==============================================================================="
  echo "#? GPS                           0   4     0     -     +0ns[   +0ns] +/-    0ns"
  echo "^${FAKE_MARK:-+} 192.0.2.1                     2  10   377   500   +100us[ +100us] +/-   50ms"
  echo "^- 192.0.2.2                     2  10   377   600   +200us[ +200us] +/-   60ms"
elif [[ "$*" == "-n -c tracking" ]]; then
  r=$(($(date +%s) - ${FAKE_REF_AGE:-100}))
  echo "C0000201,192.0.2.1,3,$r.25,0.01,-0.01,0.01,7.8,-0.0,0.03,0.1,0.02,1037.6,Normal"
else
  exit 1
fi
"""


def utc_day(offset_days, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    return (now + datetime.timedelta(days=offset_days)).strftime("%Y-%m-%d")


@unittest.skipUnless(shutil.which("rsync") and shutil.which("bash"), "needs rsync and bash")
class PullArchive(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = pathlib.Path(self.tmp.name)
        self.archive = t / "rig"
        self.beast = self.archive / "beast"
        self.spool = self.archive / "spool"
        self.beast.mkdir(parents=True)
        self.spool.mkdir()
        self.dest = t / "dest"
        self.state = t / "state"
        self.state.mkdir()
        (self.state / "writer").write_text("active\n")
        (self.state / "window").write_text("inactive\n")
        self.log = t / "log"
        self.log.touch()
        bindir = t / "bin"
        bindir.mkdir()
        for name, body in (("ssh", SSH), ("rsync", RSYNC), ("systemctl", SYSTEMCTL),
                           ("sudo", SUDO), ("chronyc", CHRONYC)):
            p = bindir / name
            p.write_text("#!/usr/bin/env bash\nset -uo pipefail\n" + body.lstrip())
            p.chmod(0o755)
        self.env = dict(os.environ,
                        PATH=f"{bindir}:{os.environ['PATH']}",
                        RIG_ARCHIVE=RIG_ARCHIVE, FAKE_ARCHIVE=str(self.archive),
                        FAKE_HOST=HOST, FAKE_LOG=str(self.log), FAKE_STATE=str(self.state),
                        FAKE_REAL_RSYNC=shutil.which("rsync"), FAKE_MARK="*")
        self.old = time.time() - 3600

    def tearDown(self):
        self.tmp.cleanup()

    def file(self, rel):
        p = self.beast / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"not a pcap")
        return p

    def dir(self, name, fresh=False, parent=None):
        d = (parent or self.beast) / name
        d.mkdir(parents=True, exist_ok=True)
        if not fresh:
            os.utime(d, (self.old, self.old))
        return d

    def run_tool(self, *args, **env):
        return self.run_raw(*args, HOST, str(self.dest), **env)

    def run_raw(self, *argv, **env):
        e = dict(self.env, **{k: str(v) for k, v in env.items()})
        r = subprocess.run(["bash", str(TOOL), *argv], env=e,
                           capture_output=True, text=True, timeout=120)
        r.log = self.log.read_text()
        return r

    # The live pull

    def test_live_does_not_touch_the_window_and_moves_closed_files_only(self):
        today = utc_day(0)
        self.file(f"{today}/20260101T000000Z.beast.pcap")
        part = self.file(f"{today}/20260101T001000Z.beast.pcap.part")
        (self.spool / "batch-1").write_text("x")
        r = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("sudo", r.log)
        self.assertNotIn("adsb-pull-window", r.log)
        self.assertNotIn("systemctl start", r.log)
        self.assertNotIn("systemctl stop", r.log)
        self.assertTrue((self.dest / "beast" / today / "20260101T000000Z.beast.pcap").exists())
        self.assertTrue(part.exists(), "the open .part must stay on the rig")
        self.assertFalse((self.dest / "spool").exists(), "a live pull must not move spool/")
        self.assertTrue((self.spool / "batch-1").exists())
        self.assertIn("!!  spool/ was left on the rig with 1 file(s) in it", r.stderr)
        self.assertIn("--end-session moves spool/ too", r.stderr)
        self.assertIn("this pull does not end the session or run the update (use --end-session", r.stdout)
        self.assertLess(r.stdout.index("live pull from"), r.stdout.index("==> moving"))
        self.assertEqual(r.log.count("systemctl is-active"), 1, "the writer's state rides the prune's ssh")
        self.assertIn("files left in beast/ on the drive: 1, of which 1 .part (the open file, or a preflight probe);"
                      " what stays is the tail closed after rsync's listing (up to one 10-minute file)"
                      " and the open .part, until the next pull", r.stdout)
        self.assertIn("the writer is active (this pull did not stop it)", r.stdout)

    def test_live_exit_24_is_a_warning(self):
        self.file(f"{utc_day(0)}/20260101T000000Z.beast.pcap")
        r = self.run_tool(FAKE_RSYNC_RC=24, FAKE_RSYNC_VANISH=2)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("rsync exit 24: 2 source file(s) vanished", r.stderr)
        self.assertIn("One possible cause is the writer's free-space backstop", r.stderr)
        self.assertIn('file has vanished: "/somewhere/1"', r.stderr, "rsync's own stderr is still shown")

    def test_live_exit_24_without_vanished_lines_says_it_could_not_count(self):
        r = self.run_tool(FAKE_RSYNC_RC=24)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("how many could not be counted", r.stderr)

    def test_live_other_rsync_failure_is_the_exit_status(self):
        self.file(f"{utc_day(0)}/20260101T000000Z.beast.pcap")
        r = self.run_tool(FAKE_RSYNC_RC=23)
        self.assertEqual(r.returncode, 23)

    def test_live_prune_refuses_recent_names_fresh_mtimes_and_full_or_odd_directories(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        recent = [utc_day(o, now) for o in (-1, 0, 1)]
        for name in recent:
            self.dir(name)  # empty and an hour old, but named for yesterday, today or tomorrow
        self.dir("2020-01-01")  # empty, old, an old date: the one to prune
        self.dir("2020-01-02", fresh=True)  # empty, an old date, but its mtime is now
        part = self.file("2020-01-03/20200103T000000Z.beast.pcap.part")
        self.dir("2020-01-03")  # holds a .part, which is not moved
        self.file("2020-01-04/20200104T000000Z.beast.pcap")
        # Emptied by this pull's move, which sets its mtime to now: in this short pull that is
        # under 15 minutes before the prune, so a later pull prunes it.
        self.dir("2020-01-04")
        self.dir("not-a-date")
        r = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        for name in recent:
            self.assertTrue((self.beast / name).is_dir(), f"{name} was pruned")
        self.assertFalse((self.beast / "2020-01-01").exists(), "an old empty date directory stayed")
        self.assertTrue((self.beast / "2020-01-02").is_dir())
        self.assertTrue(part.exists())
        self.assertTrue((self.beast / "2020-01-04").is_dir())
        self.assertTrue((self.beast / "not-a-date").is_dir())
        self.assertIn("pruned 1 empty date directories", r.stdout)

    def test_live_writer_not_active_is_reported(self):
        (self.state / "writer").write_text("failed\n")
        r = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("the writer is 'failed', not active", r.stderr)

    # --end-session keeps the old path

    def test_end_session_opens_and_closes_the_window_and_moves_spool(self):
        today = utc_day(0)
        self.file(f"{today}/20260101T000000Z.beast.pcap")
        (self.spool / "batch-1").write_text("x")
        self.dir("2020-01-01")
        r = self.run_tool("--end-session")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("sudo -n systemctl start adsb-pull-window.service", r.log)
        self.assertIn("sudo -n systemctl stop adsb-pull-window.service", r.log)
        self.assertTrue((self.dest / "spool/batch-1").exists())
        self.assertFalse((self.beast / "2020-01-01").exists())
        self.assertIn("the writer is recording again", r.stdout)

    def test_end_session_exit_24_stays_a_failure(self):
        self.file(f"{utc_day(0)}/20260101T000000Z.beast.pcap")
        r = self.run_tool("--end-session", FAKE_RSYNC_RC=24)
        self.assertEqual(r.returncode, 24)
        self.assertIn("sudo -n systemctl stop adsb-pull-window.service", r.log)

    # The clock check, in both modes; it never changes the exit status

    def test_clock_selected_and_fresh_raises_no_banner(self):
        r = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("the rig's clock: chrony has a selected source ('*')", r.stdout)
        self.assertNotIn("CLOCK", r.stderr)
        self.assertNotIn("192.0.2", r.stdout + r.stderr, "chronyc's table must not be printed")

    def test_clock_no_selected_source_raises_the_banner(self):
        for mode in ((), ("--end-session",)):
            with self.subTest(mode=mode):
                r = self.run_tool(*mode, FAKE_MARK="+")
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("THE RIG'S CLOCK MAY NOT BE DISCIPLINED", r.stderr)
                self.assertIn("NO source selected ('*')", r.stderr)
                self.assertNotIn("192.0.2", r.stdout + r.stderr)

    def test_clock_stale_reference_raises_the_banner(self):
        r = self.run_tool(FAKE_REF_AGE=20000)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("THE RIG'S CLOCK MAY NOT BE DISCIPLINED", r.stderr)
        self.assertIn("reference time was last updated 2000", r.stderr)
        self.assertNotIn("NO source selected", r.stderr)

    def test_clock_reference_ahead_of_the_rig_raises_the_banner(self):
        r = self.run_tool(FAKE_REF_AGE=-600)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("THE RIG'S CLOCK MAY NOT BE DISCIPLINED", r.stderr)
        self.assertRegex(r.stderr, r"reference time is ahead of the rig's clock by (599|600|601) s")

    def test_clock_reference_slightly_ahead_is_jitter(self):
        r = self.run_tool(FAKE_REF_AGE=-30)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("CLOCK", r.stderr)
        self.assertIn("the rig's clock: chrony has a selected source ('*')", r.stdout)

    def test_clock_chronyc_failing_says_it_could_not_tell(self):
        r = self.run_tool(FAKE_CHRONY_FAIL=1)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("COULD NOT TELL WHETHER THE RIG'S CLOCK IS DISCIPLINED", r.stderr)
        self.assertIn("chronyc -n sources failed", r.stderr)
        self.assertNotIn("MAY NOT BE DISCIPLINED", r.stderr)

    def test_clock_line_is_found_after_a_shell_banner(self):
        r = self.run_tool(FAKE_SSH_BANNER="Welcome to the rig")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("COULD NOT TELL", r.stderr)
        self.assertIn("the rig's clock: chrony has a selected source ('*')", r.stdout)
        self.assertIn("the writer is active (this pull did not stop it)", r.stdout)

    def test_clock_ssh_failure_says_it_could_not_tell(self):
        # "sh -s" is the clock check's ssh (and the live prune's, which then warns and goes on).
        r = self.run_tool(FAKE_SSH_FAIL="sh -s")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("COULD NOT TELL WHETHER THE RIG'S CLOCK IS DISCIPLINED", r.stderr)
        self.assertIn("exit 255", r.stderr)


    # The arguments

    def test_end_session_after_the_positionals(self):
        r = self.run_raw(HOST, str(self.dest), "--end-session")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("sudo -n systemctl start adsb-pull-window.service", r.log)

    def test_end_session_between_the_positionals(self):
        r = self.run_raw(HOST, "--end-session", str(self.dest))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("sudo -n systemctl start adsb-pull-window.service", r.log)

    def test_unknown_option_is_refused(self):
        r = self.run_raw("--end-sesion", HOST, str(self.dest))
        self.assertEqual(r.returncode, 64)
        self.assertIn("unknown option: --end-sesion", r.stderr)
        self.assertEqual(r.log, "", "nothing may reach the rig")

    def test_double_dash_ends_the_options(self):
        r = self.run_raw("--", HOST, str(self.dest))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("sudo", r.log)
        r = self.run_raw("--", "--end-session", str(self.dest))
        self.assertEqual(r.returncode, 64, "after --, a target starting with - is refused")
        r = self.run_raw(HOST, "--", "-dest")
        self.assertEqual(r.returncode, 64, "after --, a destination starting with - is refused")
        self.assertIn("the destination may not start with '-'", r.stderr)


if __name__ == "__main__":
    unittest.main()
