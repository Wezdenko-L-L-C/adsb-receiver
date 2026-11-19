# SPDX-License-Identifier: Apache-2.0
#
# setup/steps/55-security.sh's verify() fails on each way the security phase's apt configuration
# can be inert or wrong, and its install writes that configuration before the package goes in.
#
# The step itself is not run: it needs root, apt and a Pi's archives. The test takes the step's
# body, from `readonly PKG=` up to its closing `if ((VERIFY_ONLY == 0))`, as written (each cut and
# path swap is asserted, so a renamed line fails here rather than testing nothing), and runs it
# under setup/lib.sh with set -euo pipefail, ADSB_ETC and the apt.conf.d part moved into a
# temporary directory. Around it, stubs on PATH: apt-config dump and apt-cache policy print
# fixtures (the security phase's when APT_CONFIG is set, the system's when not; nothing for a
# fixture that is absent, as apt-cache does for an unknown package), unattended-upgrade prints a
# dry run's output and exits with a set code, dpkg-query reports the package installed or not, and
# apt-get and debconf-set-selections record their calls. The fixtures follow the portable's
# sources and origins as read over SSH on 2026-11-18 (deb.debian.org, deb.debian.org's
# debian-security, archive.raspberrypi.com). Needs bash.

import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
STEP = ROOT / "setup/steps/55-security.sh"
APT_PART_LINE = "readonly APT_PART=/etc/apt/apt.conf.d/52adsb-security"

FOUR = ["openssl", "libssl3t64", "openssl-provider-legacy", "wpasupplicant"]
ORIGINS = [
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security",
    "site=archive.raspberrypi.com",
]
BLACKLIST = [
    "linux-image-", "linux-headers-", "linux-kbuild-", "raspberrypi-kernel",
    "raspberrypi-bootloader", "raspi-firmware", "firmware-", "bluez-firmware", "rpi-eeprom",
    "rpi-update", "tailscale$", "tailscale-archive-keyring$",
]

PI_FILE = """\
   1 http://archive.raspberrypi.com/debian trixie/main arm64 Packages
     release o=Raspberry Pi Foundation,a=stable,n=trixie,l=Raspberry Pi Foundation,c=main,b=arm64
     origin archive.raspberrypi.com
"""
POLICY_FILES = """\
Package files:
 100 /var/lib/dpkg/status
     release a=now
 500 http://deb.debian.org/debian-security trixie-security/main arm64 Packages
     release v=13,o=Debian,a=stable-security,n=trixie-security,l=Debian-Security,c=main,b=arm64
     origin deb.debian.org
 500 http://deb.debian.org/debian trixie/main arm64 Packages
     release v=13.2,o=Debian,a=stable,n=trixie,l=Debian,c=main,b=arm64
     origin deb.debian.org
"""
PINNED = "".join(f"     {p} -> 3.5.7-1~deb13u3+rpt1 with priority 500\n" for p in FOUR)
SYS_MODS = """\
raspberrypi-sys-mods:
  Installed: 20250916
  Candidate: 20250916
  Version table:
 *** 20250916 100
        {prio} http://archive.raspberrypi.com/debian trixie/main arm64 Packages
        100 /var/lib/dpkg/status
"""
PI_VERSION = """\
{p}:
  Installed: 3.5.6
  Candidate: 3.5.7-1~deb13u3+rpt1
  Version table:
     3.5.7-1~deb13u3+rpt1 500
        500 http://archive.raspberrypi.com/debian trixie/main arm64 Packages
 *** 3.5.6 100
        100 /var/lib/dpkg/status
"""
SEC_VERSION = """\
{p}:
  Installed: 1.0-1
  Candidate: 1.0-2+deb13u1
  Version table:
     1.0-2+deb13u1 500
        500 http://deb.debian.org/debian-security trixie-security/main arm64 Packages
 *** 1.0-1 100
        100 /var/lib/dpkg/status
"""
INSTALLED_FROM_SECURITY = """\
{p}:
  Installed: 1.0-1
  Candidate: 1.1-1+rpt1
  Version table:
     1.1-1+rpt1 500
        500 http://archive.raspberrypi.com/debian trixie/main arm64 Packages
 *** 1.0-1 500
        500 http://deb.debian.org/debian-security trixie-security/main arm64 Packages
        100 /var/lib/dpkg/status
"""
MAIN_VERSION = """\
{p}:
  Installed: 1.0-1
  Candidate: 1.0-2
  Version table:
     1.0-2 500
        500 http://deb.debian.org/debian trixie/main arm64 Packages
 *** 1.0-1 100
        100 /var/lib/dpkg/status
"""
DRY_RUN = """\
Starting unattended upgrades script
Allowed origins are: origin=Debian,codename=trixie-security,label=Debian-Security, site=archive.raspberrypi.com
Initial blacklist: {blacklist}
Initial whitelist (not strict):
Option --dry-run given, *not* performing real actions
{tail}
"""

STUBS = {
    "apt-config": r"""
[ "$1" = dump ] || exit 2
if [ -n "${APT_CONFIG:-}" ]; then f=$FIX/dump.sec; else f=$FIX/dump.sys; fi
[ -f "$f" ] && cat "$f"
exit 0
""",
    "apt-cache": r"""
[ "$1" = policy ] || exit 2
shift
if [ -n "${APT_CONFIG:-}" ]; then w=sec; else w=sys; fi
f=$FIX/policy.$w.${1:-all}
[ -f "$f" ] && cat "$f"
exit 0
""",
    "unattended-upgrade": r"""
cat "$FIX/uu.out"
exit "$(cat "$FIX/uu.rc")"
""",
    "dpkg-query": r"""
[ -f "$FIX/installed" ] || { echo "dpkg-query: no packages found matching" >&2; exit 1; }
printf 'ii '
""",
    "apt-get": r"""
echo "apt-get $* part=$([ -f "$PART" ] && echo yes || echo no)" >>"$FIX/calls"
[ "$1" = install ] && : >"$FIX/installed"
exit 0
""",
    "debconf-set-selections": r"""
echo "debconf $(cat) part=$([ -f "$PART" ] && echo yes || echo no)" >>"$FIX/calls"
""",
}


def dump_lines(key, values):
    return f'{key} "";\n' + "".join(f'{key}:: "{v}";\n' for v in values)


class Step55Verify(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = pathlib.Path(self.tmp.name)
        src = STEP.read_text()
        start = src.find("readonly PKG=unattended-upgrades\n")
        end = src.find("if ((VERIFY_ONLY == 0)); then\n")
        self.assertTrue(0 <= start < end, f"the step's body was not found in {STEP}; update this test")
        body = src[start:end]
        self.assertEqual(body.count(APT_PART_LINE), 1, f"{APT_PART_LINE!r} not found; update this test")
        self.part = t / "apt.conf.d/52adsb-security"
        body = body.replace(APT_PART_LINE, f"readonly APT_PART={self.part}")
        self.etc = t / "etc"
        self.prefs = self.etc / "security/preferences"
        self.fix = t / "fix"
        self.fix.mkdir()
        stubs = t / "bin"
        stubs.mkdir()
        for name, text in STUBS.items():
            (stubs / name).write_text("#!/usr/bin/env bash\n" + text.lstrip())
            (stubs / name).chmod(0o755)
        self.script = t / "run.sh"
        self.script.write_text(
            "set -euo pipefail\n"
            f'source "{ROOT}/setup/lib.sh"\n'
            f"ADSB_ETC={self.etc}\n"
            + body
            + "install_step\nverify\n"
        )
        self.env = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}", FIX=str(self.fix), PART=str(self.part))
        # A correctly configured rig, already installed.
        (self.fix / "installed").write_text("")
        self.write_dumps()
        self.write_policy()
        self.write_dry_run()

    def tearDown(self):
        self.tmp.cleanup()

    def write_dumps(self, periodic="0", prefs=None, origins=ORIGINS, blacklist=BLACKLIST):
        sysd = 'APT::Periodic::Update-Package-Lists "1";\n'
        if periodic is not None:
            sysd += f'APT::Periodic::Unattended-Upgrade "{periodic}";\n'
        (self.fix / "dump.sys").write_text(sysd)
        sec = sysd + f'Dir::Etc::preferences "{prefs or self.prefs}";\n'
        sec += dump_lines("DPkg::Options", ["--force-confdef", "--force-confold"])
        sec += 'Unattended-Upgrade::InstallOnShutdown "false";\nUnattended-Upgrade::Automatic-Reboot "false";\n'
        sec += dump_lines("Unattended-Upgrade::Origins-Pattern", origins)
        sec += dump_lines("Unattended-Upgrade::Package-Blacklist", blacklist)
        (self.fix / "dump.sec").write_text(sec)

    def write_policy(self, pi_file=PI_FILE, pinned=PINNED, sys_mods_prio=1, four=FOUR):
        (self.fix / "policy.sec.all").write_text(POLICY_FILES + pi_file + "Pinned packages:\n" + pinned)
        (self.fix / "policy.sec.raspberrypi-sys-mods").write_text(SYS_MODS.format(prio=sys_mods_prio))
        for w in ("sys", "sec"):
            for p in four:
                (self.fix / f"policy.{w}.{p}").write_text(
                    PI_VERSION.format(p=p))

    def write_dry_run(self, tail="Packages that will be upgraded: openssl libssl3t64", rc=0, blacklist=BLACKLIST):
        (self.fix / "uu.out").write_text(DRY_RUN.format(blacklist=" ".join(blacklist), tail=tail))
        (self.fix / "uu.rc").write_text(str(rc))

    def run_step(self):
        # The step without --verify: install_step writes the files (the package reads as installed
        # unless a case says otherwise, so apt-get is not called), then verify.
        return subprocess.run(["bash", str(self.script)], env=self.env, capture_output=True, text=True, timeout=60)

    def assertPasses(self, r):
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("ok  PASS: unattended-upgrade's dry run reads", r.stdout)

    def assertFails(self, r, text):
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("xx  FAIL:", r.stderr)
        self.assertIn(text, r.stderr)

    def test_a_correct_rig_passes(self):
        self.assertPasses(self.run_step())

    def test_install_writes_the_configuration_before_the_package(self):
        (self.fix / "installed").unlink()
        self.assertPasses(self.run_step())
        calls = (self.fix / "calls").read_text().splitlines()
        self.assertTrue(calls[0].startswith("debconf unattended-upgrades"), calls)
        self.assertTrue(all(c.endswith("part=yes") for c in calls), calls)
        self.assertTrue(any(c.startswith("apt-get install") for c in calls), calls)

    def test_schedule_on_after_every_part_fails(self):
        self.write_dumps(periodic="1")
        self.assertFails(self.run_step(), "APT::Periodic::Unattended-Upgrade resolves to '1'")

    def test_schedule_absent_passes(self):
        self.write_dumps(periodic=None)
        self.assertPasses(self.run_step())

    def test_preferences_overridden_by_a_part_fails(self):
        self.write_dumps(prefs="/etc/apt/preferences")
        self.assertFails(self.run_step(), "Dir::Etc::Preferences resolves to '/etc/apt/preferences'")

    def test_an_added_origin_fails(self):
        self.write_dumps(origins=ORIGINS + ["origin=Debian,codename=${distro_codename}-updates"])
        self.assertFails(self.run_step(), "Unattended-Upgrade::Origins-Pattern resolves to")

    def test_a_shortened_blacklist_fails(self):
        self.write_dumps(blacklist=BLACKLIST[:-1])
        self.assertFails(self.run_step(), "Unattended-Upgrade::Package-Blacklist resolves to")

    def test_inert_pins_fail(self):
        # Preferences not applied: the Pi archive at its default 500, nothing pinned.
        self.write_policy(pi_file=PI_FILE.replace("   1 http", " 500 http"), pinned="")
        self.assertFails(self.run_step(), "archive.raspberrypi.com's package files are at priority 500")

    def test_pi_host_absent_fails(self):
        self.write_policy(pi_file="")
        self.assertFails(self.run_step(), "no package file from archive.raspberrypi.com")

    def test_one_of_the_four_unpinned_fails(self):
        self.write_policy(pinned="".join(l + "\n" for l in PINNED.splitlines() if "wpasupplicant" not in l))
        self.assertFails(self.run_step(), "wpasupplicant has no version from archive.raspberrypi.com pinned at 500")

    def test_a_fifth_pinned_package_fails(self):
        self.write_policy(pinned=PINNED + "     raspi-firmware -> 1:1.2025 with priority 500\n")
        self.assertFails(self.run_step(), "beyond the four at 500: raspi-firmware 500")

    def test_a_pi_package_outside_the_four_above_1_fails(self):
        self.write_policy(sys_mods_prio=500)
        self.assertFails(self.run_step(), "raspberrypi-sys-mods is above priority 1")

    def test_empty_apt_lists_fail(self):
        for f in self.fix.glob("policy.*"):
            f.unlink()
        self.assertFails(self.run_step(), "printed nothing")

    def test_empty_candidates_fail(self):
        # The check this replaced passed here: '' under the pins equalled '' without them.
        for p in FOUR:
            for w in ("sys", "sec"):
                (self.fix / f"policy.{w}.{p}").unlink()
        self.assertFails(self.run_step(), "apt-cache policy openssl")

    def test_a_dry_run_upgrading_the_kernel_fails(self):
        self.write_dry_run(tail="Packages that will be upgraded: openssl linux-image-6.12.47+rpt-rpi-v8")
        self.assertFails(self.run_step(), "would upgrade linux-image-6.12.47+rpt-rpi-v8")

    def write_origin(self, pkg, text):
        (self.fix / f"policy.sec.{pkg}").write_text(text.format(p=pkg))

    def test_a_security_package_from_debian_security_passes(self):
        self.write_origin("curl", SEC_VERSION)
        self.write_dry_run(tail="Packages that will be upgraded: openssl curl")
        self.assertPasses(self.run_step())

    def test_a_package_outside_the_four_from_the_pi_archive_fails(self):
        self.write_origin("pi-other", PI_VERSION)
        self.write_dry_run(tail="Packages that will be upgraded: openssl pi-other")
        self.assertFails(self.run_step(), "pi-other, which is neither from Debian-Security")

    def test_the_installed_versions_sources_are_not_the_candidates(self):
        # apt-cache marks the installed row "***"; its sources must not be read as the candidate's.
        self.write_origin("pi-other", INSTALLED_FROM_SECURITY)
        self.write_dry_run(tail="Packages that will be upgraded: pi-other")
        self.assertFails(self.run_step(), "pi-other, which is neither from Debian-Security")

    def test_a_package_from_plain_debian_fails(self):
        self.write_origin("curl", MAIN_VERSION)
        self.write_dry_run(tail="Packages that will be upgraded: curl")
        self.assertFails(self.run_step(), "curl, which is neither from Debian-Security")

    def test_a_package_with_no_known_source_fails(self):
        self.write_dry_run(tail="Packages that will be upgraded: mystery")
        self.assertFails(self.run_step(), "mystery, which is neither from Debian-Security")

    def test_the_blacklist_covers_eeprom_siblings(self):
        self.write_origin("rpi-eeprom-images", SEC_VERSION)
        self.write_dry_run(tail="Packages that will be upgraded: rpi-eeprom-images")
        self.assertFails(self.run_step(), "never-touch list (rpi-eeprom)")

    def test_a_failed_dry_run_fails(self):
        self.write_dry_run(rc=1)
        self.assertFails(self.run_step(), "unattended-upgrade --dry-run exited 1")

    def test_a_dry_run_with_another_blacklist_fails(self):
        self.write_dry_run(blacklist=BLACKLIST[:3])
        self.assertFails(self.run_step(), "unattended-upgrade reports its blacklist as")

    def test_a_dry_run_with_nothing_to_do_passes(self):
        self.write_dry_run(tail="No packages found that can be upgraded unattended and no pending auto-removals")
        self.assertPasses(self.run_step())


if __name__ == "__main__":
    unittest.main()
