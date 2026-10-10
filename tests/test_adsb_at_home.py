# SPDX-License-Identifier: Apache-2.0
#
# bin/adsb-at-home, the home-gated opener's ExecCondition= (PLAN §9f's 2026-10-04 (night) update),
# run for real against a stubbed nmcli. The stub prints a fixture in nmcli's terse format and
# records its arguments, so a case can show the SSID never reached a child's command line. By
# hand it prints "at home", "not at home" or "cannot tell" (exit 0, 1, 2); under its unit
# (ADSB_HOME_STATE set) every verdict but "at home" is a tagged ADSB-HOME-UPDATE line, and the
# verdict goes to the state file the login banner reads.
#
# The script reads /etc/adsb-receiver/station.yml. The test runs a copy whose path is pointed into
# a temporary directory (the replacement is asserted, so a reworded line fails here rather than
# reading the real file). PATH holds only a directory of the tools the script needs (python3, mv,
# timeout) plus the stub, so "no nmcli" is a real absence, whatever the machine has installed.
# Needs bash, and python3 with PyYAML.

import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
STATION_LINE = "readonly STATION=/etc/adsb-receiver/station.yml"
OWNER_LINE = "readonly OWNER_UID=0   # who must own the state's directory: root"
SECRET = "Sec:ret\\Net"   # a colon and a backslash, both escaped in nmcli's terse output


def terse(ssid):
    """nmcli's terse escaping of one value: '\\' -> '\\\\', ':' -> '\\:'."""
    return ssid.replace("\\", "\\\\").replace(":", "\\:")


class AtHome(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.station = self.tmp / "station.yml"
        src = (ROOT / "bin/adsb-at-home").read_text()
        self.assertEqual(src.count(STATION_LINE), 1, "the station.yml line to remap was not found once")
        self.assertEqual(src.count(OWNER_LINE), 1, "the owner line to remap was not found once")
        self.script = self.tmp / "adsb-at-home"
        # The state's directory must be root's on the rig; here, the test's own user's.
        self.script.write_text(src.replace(STATION_LINE, f"readonly STATION={self.station}")
                               .replace(OWNER_LINE, f"readonly OWNER_UID={os.getuid()}"))
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.home.chmod(0o755)
        self.state = self.home / "home-update-state"
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for tool in ("python3", "timeout", "mv", "stat", "mktemp", "chmod", "rm"):
            path = shutil.which(tool)
            self.assertIsNotNone(path, f"{tool} is needed")
            (self.bin / tool).symlink_to(path)
        self.argv_log = self.tmp / "nmcli.argv"
        self.fixture = self.tmp / "nmcli.out"

    def nmcli(self, lines, rc=0):
        self.fixture.write_text("".join(line + "\n" for line in lines))
        stub = self.bin / "nmcli"
        # Absolute paths: PATH holds only self.bin.
        stub.write_text(f"#!{shutil.which('bash')}\nprintf '%s\\n' \"$*\" >>{self.argv_log}\n"
                        f"{shutil.which('cat')} {self.fixture}\nexit {rc}\n")
        stub.chmod(0o755)

    def config(self, text):
        self.station.write_text("station:\n  role: portable\n" + text)

    def run_it(self, unit=False):
        bash = shutil.which("bash")
        env = {"PATH": str(self.bin)}
        if unit:
            env["ADSB_HOME_STATE"] = str(self.state)
        p = subprocess.run([bash, str(self.script)], capture_output=True, text=True,
                           env=env, timeout=60)
        return p.returncode, p.stdout, p.stderr

    def assert_verdict(self, rc, out, err, home):
        self.assertEqual((rc, out, err), (0, "at home\n", "") if home else (1, "not at home\n", ""))

    def assert_cannot_tell(self, rc, out, err):
        self.assertEqual((rc, out, err), (2, "cannot tell\n", ""))

    def nmcli_calls(self):
        return self.argv_log.read_text().splitlines() if self.argv_log.exists() else []

    # --- the key ---

    def test_unset_is_not_at_home_and_asks_nothing(self):
        self.config("")
        self.nmcli([f"yes:{terse(SECRET)}"])
        self.assert_verdict(*self.run_it(), home=False)
        self.assertEqual(self.nmcli_calls(), [])

    def test_empty_and_null_are_not_at_home(self):
        for value in ('""', "null", "~"):
            with self.subTest(value=value):
                self.config(f"update:\n  home_ssid: {value}\n")
                self.nmcli(["yes:"])
                self.assert_verdict(*self.run_it(), home=False)
        self.assertEqual(self.nmcli_calls(), [])

    def test_non_strings_read_as_unset(self):
        # An unquoted yes is YAML's true; a number and a list are not SSIDs either.
        for value, fixture in (("yes", ["yes:yes", "yes:True"]), ("1234", ["yes:1234"]),
                               ("[a, b]", ["yes:a"])):
            with self.subTest(value=value):
                self.config(f"update:\n  home_ssid: {value}\n")
                self.nmcli(fixture)
                self.assert_verdict(*self.run_it(), home=False)
        self.assertEqual(self.nmcli_calls(), [])

    def test_unreadable_station_yml_is_cannot_tell(self):
        self.nmcli(["yes:anything"])
        self.assert_cannot_tell(*self.run_it())
        self.station.write_text("update: [unclosed\n")
        self.assert_cannot_tell(*self.run_it())

    # --- the yes: line ---

    def test_the_yes_line_among_duplicated_no_lines(self):
        # The shape seen on the 🎒 portable Pi on 2026-10-05: one yes: line, no: lines per band.
        self.config(f'update:\n  home_ssid: "{SECRET.replace(chr(92), chr(92) * 2)}"\n')
        self.nmcli(["no:Neighbor", "no:Neighbor", f"yes:{terse(SECRET)}", "no:Other", "no:Other"])
        rc, out, err = self.run_it()
        self.assert_verdict(rc, out, err, home=True)
        self.assertNotIn(SECRET, out + err)

    def test_the_ssid_on_a_no_line_only_is_not_at_home(self):
        self.config('update:\n  home_ssid: "HomeNet"\n')
        self.nmcli(["no:HomeNet", "no:HomeNet", "yes:Hotspot"])
        self.assert_verdict(*self.run_it(), home=False)

    def test_escaping_is_undone_not_compared_raw(self):
        # The configured value spelled the way nmcli escapes it is a different SSID.
        self.config("update:\n  home_ssid: 'Sec\\:ret'\n")
        self.nmcli(["yes:Sec\\:ret"])
        self.assert_verdict(*self.run_it(), home=False)

    def test_a_second_yes_line_can_match(self):
        self.config('update:\n  home_ssid: "HomeNet"\n')
        self.nmcli(["yes:Other", "yes:HomeNet"])
        self.assert_verdict(*self.run_it(), home=True)

    # --- no Wi-Fi ---

    def test_ethernet_only_no_nmcli_and_a_failing_nmcli(self):
        self.config('update:\n  home_ssid: "HomeNet"\n')
        with self.subTest("Ethernet only: no yes: line"):
            self.nmcli(["no:HomeNet"])
            self.assert_verdict(*self.run_it(), home=False)
        with self.subTest("nmcli fails (NetworkManager not running): cannot tell"):
            self.nmcli(["yes:HomeNet"], rc=8)
            self.assert_cannot_tell(*self.run_it())
        with self.subTest("no nmcli at all: no Wi-Fi, not at home (ruled)"):
            (self.bin / "nmcli").unlink()
            self.assert_verdict(*self.run_it(), home=False)

    # --- under the unit ---

    def test_under_the_unit_one_tagged_line_and_the_state_file(self):
        state = self.state
        cases = (
            ("", ["yes:HomeNet"], 1, "ADSB-HOME-UPDATE off: ", "off"),
            ('update:\n  home_ssid: "HomeNet"\n', ["yes:Other"], 1, "ADSB-HOME-UPDATE not-at-home: ", "not-at-home"),
            ('update:\n  home_ssid: "HomeNet"\n', ["yes:HomeNet"], 0, "at home", "at-home"),
        )
        for text, fixture, rc_want, line, word in cases:
            with self.subTest(word=word):
                self.config(text)
                self.nmcli(fixture)
                rc, out, err = self.run_it(unit=True)
                self.assertEqual((rc, err, len(out.splitlines())), (rc_want, "", 1))
                self.assertTrue(out.startswith(line), out)
                self.assertNotIn("HomeNet", out)
                got = state.read_text().split()
                self.assertEqual((len(got), got[0]), (2, word))
                self.assertEqual(oct(state.stat().st_mode & 0o777), "0o644")
        with self.subTest(word="cannot-tell"):
            self.nmcli(["yes:HomeNet"], rc=8)
            rc, out, err = self.run_it(unit=True)
            self.assertEqual(rc, 2)
            self.assertTrue(out.startswith("ADSB-HOME-UPDATE cannot-tell: "), out)
            self.assertEqual(state.read_text().split()[0], "cannot-tell")
        self.assertNotIn("HomeNet", state.read_text())

    # --- ⛔ no write outside a directory only root (here, the test's user) may write ---

    def test_an_unsafe_state_directory_is_cannot_tell_and_nothing_is_written(self):
        self.config('update:\n  home_ssid: "HomeNet"\n')
        self.nmcli(["yes:HomeNet"])
        with self.subTest("group- and other-writable"):
            self.home.chmod(0o777)
            rc, out, err = self.run_it(unit=True)
            self.assertEqual((rc, err), (2, ""))
            self.assertTrue(out.startswith("ADSB-HOME-UPDATE cannot-tell: "), out)
            self.assertEqual(list(self.home.iterdir()), [])
            self.home.chmod(0o755)
        with self.subTest("the directory is a symlink"):
            real = self.tmp / "elsewhere"
            real.mkdir()
            link = self.tmp / "linked"
            link.symlink_to(real)
            self.state = link / "home-update-state"
            rc, out, err = self.run_it(unit=True)
            self.assertEqual(rc, 2)
            self.assertTrue(out.startswith("ADSB-HOME-UPDATE cannot-tell: "), out)
            self.assertEqual(list(real.iterdir()), [])

    def test_a_symlink_at_the_state_path_is_replaced_not_followed(self):
        victim = self.tmp / "victim"
        victim.write_text("untouched\n")
        self.state.symlink_to(victim)
        self.config('update:\n  home_ssid: "HomeNet"\n')
        self.nmcli(["yes:HomeNet"])
        rc, out, _ = self.run_it(unit=True)
        self.assertEqual((rc, out), (0, "at home\n"))
        self.assertEqual(victim.read_text(), "untouched\n")
        self.assertFalse(self.state.is_symlink())
        self.assertEqual(self.state.read_text().split()[0], "at-home")
        self.assertEqual([f.name for f in self.home.iterdir()], ["home-update-state"])

    # --- ⛔ the SSID goes nowhere ---

    def test_the_ssid_is_never_an_argument_of_nmcli(self):
        self.config('update:\n  home_ssid: "HomeNet"\n')
        self.nmcli(["yes:HomeNet"])
        self.run_it()
        self.nmcli(["yes:Elsewhere"])
        self.run_it()
        self.assertEqual(self.nmcli_calls(), ["-t -f active,ssid dev wifi list --rescan no"] * 2)


if __name__ == "__main__":
    unittest.main()
