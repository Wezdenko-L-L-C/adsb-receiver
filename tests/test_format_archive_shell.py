# SPDX-License-Identifier: Apache-2.0
#
# setup/foundation/format-archive.sh, the shell end of the archive format, run for real on stubbed
# tools: lsblk, findmnt, blkid, mount and the rest are small scripts on PATH that print what the
# real ones would. No disk is touched. sfdisk, wipefs, mkfs.ext4 and tune2fs are stubs that record
# being called and fail; every case asserts that none was called, except the part-way case, whose
# sfdisk stub only records and succeeds.
#
# The script needs root. The test runs a copy of it whose root check is replaced (the replacement
# is asserted, so a reworded check fails here rather than silently running something else), beside
# copies of setup/lib.sh (its /etc path pointed into the temporary tree) and
# archive_candidates.py, in the same layout. /proc/swaps is the real one, so the fake disk is
# named sdz.

import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
GB = 1_000_000_000
LABEL = "adsb-archive"
ROOT_CHECK = "((EUID == 0)) || die"

STUBS = {
    "lsblk": r"""
case " $* " in
  *" -d "*) cat "$FAKE/lsblk.now.json" ;;
  *" -J "*) cat "$FAKE/lsblk.json" ;;
  *" -nr "*) printf '/dev/sdz disk\n/dev/sdz1 part\n' ;;
  *) echo "NAME SIZE TRAN (stub)" ;;
esac
""",
    "findmnt": r"""printf '/dev/mmcblk0p2\n/dev/mmcblk0p1\n'""",
    # -p (the low-level probe), -t LABEL= (who carries the label), -s TYPE <dev> (its type).
    "blkid": r"""
echo "blkid $*" >>"$FAKE/blkid.log"
dev=${*: -1}
key=$(tr / _ <<<"$dev")
case " $* " in
  *" -p "*) if [[ -f $FAKE/probe$key ]]; then cat "$FAKE/probe$key"; exit 0; fi; exit 2 ;;
  *" -t LABEL="*) if [[ -s $FAKE/labeled ]]; then cat "$FAKE/labeled"; exit 0; fi; exit 2 ;;
  *" -s TYPE "*) cat "$FAKE/type$key" 2>/dev/null; exit 0 ;;
esac
exit 4
""",
    # The probe mount: records its arguments, and puts files on the "filesystem" if told to.
    "mount": r"""
echo "mount $*" >>"$FAKE/mount.log"
if [[ -f $FAKE/content ]]; then : >"${*: -1}/somebodys-file"; fi
exit 0
""",
    "umount": r"""rm -f "${*: -1}/somebodys-file"; exit 0""",
    "mountpoint": "exit 1",
    "dumpe2fs": "exit 1",
    "udevadm": "exit 0",
}
DESTRUCTIVE = ("sfdisk", "wipefs", "mkfs.ext4", "tune2fs")


def node(name, typ, fstype=None, label=None, mounts=None, partn=None, children=None,
         size=64 * GB, pttype="dos", serial=None, ptuuid=None, tran=None, rm=True):
    n = {"name": name, "kname": name, "path": "/dev/" + name, "type": typ, "tran": tran,
         "rm": rm, "ro": False, "size": size, "fstype": fstype, "label": label, "pttype": pttype,
         "ptuuid": ptuuid, "serial": serial, "partn": partn, "mountpoints": mounts or [None]}
    if children is not None:
        n["children"] = children
    return n


def boot_sd():
    return node("mmcblk0", "disk", rm=False, size=32 * GB, children=[
        node("mmcblk0p1", "part", "vfat", "bootfs", ["/boot/firmware"], 1),
        node("mmcblk0p2", "part", "ext4", "rootfs", ["/"], 2)])


def stick(fstype="exfat", label="USB DISK", children=True, pttype="dos"):
    kids = [node("sdz1", "part", fstype, label, partn=1)] if children else None
    return node("sdz", "disk", tran="usb", serial="S1", ptuuid="abcd-01" if pttype else None,
                pttype=pttype, children=kids)


class FormatArchiveShellTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = pathlib.Path(self.tmp.name)
        (t / "setup" / "foundation").mkdir(parents=True)
        (t / "config").mkdir()
        lib = (ROOT / "setup/lib.sh").read_text()
        self.assertEqual(lib.count("ADSB_ETC=/etc/adsb-receiver"), 1)
        (t / "setup/lib.sh").write_text(lib.replace("ADSB_ETC=/etc/adsb-receiver",
                                                    f"ADSB_ETC={t}/no-etc"))
        script = (ROOT / "setup/foundation/format-archive.sh").read_text()
        self.assertEqual(script.count(ROOT_CHECK), 1, "the root check moved; update this test")
        self.script = t / "setup/foundation/format-archive.sh"
        self.script.write_text(script.replace(ROOT_CHECK, "true || die"))
        shutil.copy(ROOT / "setup/foundation/archive_candidates.py", t / "setup/foundation/")
        (t / "config/station.yml").write_text(
            f"station:\n  role: portable\narchive:\n  label: {LABEL}\n  min_free_gb: 4\n")
        self.fake = t / "fake"
        self.fake.mkdir()
        self.bin = t / "bin"
        self.bin.mkdir()
        for name, body in STUBS.items():
            self.stub(name, body)
        for name in DESTRUCTIVE:
            self.stub(name, 'echo "$(basename "$0") $*" >>"$FAKE/called"; exit 99')
        self.report = self.fake / "report.json"

    def tearDown(self):
        self.tmp.cleanup()

    def stub(self, name, body):
        p = self.bin / name
        p.write_text("#!/usr/bin/env bash\n" + body.strip() + "\n")
        p.chmod(0o755)

    def disks(self, *devs, now=None):
        (self.fake / "lsblk.json").write_text(json.dumps({"blockdevices": list(devs)}))
        now = now or {"path": "/dev/sdz", "size": 64 * GB, "serial": "S1", "ptuuid": "abcd-01"}
        (self.fake / "lsblk.now.json").write_text(json.dumps({"blockdevices": [now]}))

    def probe(self, dev, text):
        (self.fake / ("probe" + dev.replace("/", "_"))).write_text(text)

    def run_script(self, *args, env=None):
        e = dict(os.environ, FAKE=str(self.fake), PATH=f"{self.bin}:{os.environ['PATH']}")
        e.pop("ADSB_FOUNDATION", None)
        e.update(env or {})
        p = subprocess.run(["bash", str(self.script), *args, "--report", str(self.report)],
                           env=e, capture_output=True, text=True, timeout=120)
        self.output = p.stdout + p.stderr
        self.assertFalse((self.fake / "called").exists(),
                         "a destructive tool was called:\n" + self.output)
        rep = json.loads(self.report.read_text()) if self.report.exists() else None
        return p.returncode, rep

    def test_the_stick_as_bought_is_probed_read_only_and_would_be_formatted(self):
        self.disks(boot_sd(), stick("exfat"))
        # blkid -p on a partition also prints the partition table's entry; only TYPE counts.
        self.probe("/dev/sdz1", "PART_ENTRY_SCHEME=dos\nTYPE=exfat\nPART_ENTRY_TYPE=0x7\n")
        rc, rep = self.run_script("--dry-run")
        self.assertEqual((rc, rep["result"], rep["device"]), (0, "dry_run", "/dev/sdz1"),
                         self.output)
        mounts = (self.fake / "mount.log").read_text()
        self.assertIn("-t exfat -o ro /dev/sdz1", mounts)

    def test_a_partition_whose_probe_prints_only_part_entry_lines_has_no_signature(self):
        self.disks(boot_sd(), stick(None, None))
        self.probe("/dev/sdz1", "PART_ENTRY_SCHEME=dos\nPART_ENTRY_TYPE=0x83\n"
                                "PART_ENTRY_NUMBER=1\nPART_ENTRY_SIZE=125000000\n")
        rc, rep = self.run_script("--dry-run")
        self.assertEqual((rc, rep["result"]), (0, "dry_run"), self.output)
        self.assertIn("-s TYPE -s PTTYPE", (self.fake / "blkid.log").read_text())

    def test_a_signature_that_appeared_since_the_decision_refuses(self):
        self.disks(boot_sd(), stick(None, None))
        self.probe("/dev/sdz1", "TYPE=vfat\nPART_ENTRY_SCHEME=dos\n")
        rc, rep = self.run_script("--dry-run")
        self.assertEqual((rc, rep["result"]), (2, "refused"), self.output)
        self.assertIn("blkid -p reads", rep["reason"])

    def test_a_swapped_stick_refuses(self):
        self.disks(boot_sd(), stick(None, None),
                   now={"path": "/dev/sdz", "size": 64 * GB, "serial": "S2", "ptuuid": "abcd-01"})
        rc, rep = self.run_script("--dry-run")
        self.assertEqual((rc, rep["result"]), (2, "refused"), self.output)
        self.assertIn("serial", rep["reason"])

    def test_a_blank_disk_would_get_a_table(self):
        self.disks(boot_sd(), stick(children=False, pttype=None),
                   now={"path": "/dev/sdz", "size": 64 * GB, "serial": "S1", "ptuuid": None})
        rc, rep = self.run_script("--dry-run")
        self.assertEqual((rc, rep["result"], rep["device"]), (0, "dry_run", "/dev/sdz1"),
                         self.output)
        self.assertIn("new partition table: true", self.output)

    def test_a_stick_holding_files_is_not_formatted(self):
        self.disks(boot_sd(), stick("exfat"))
        (self.fake / "content").write_text("")
        rc, rep = self.run_script("--dry-run")
        self.assertEqual((rc, rep["result"]), (2, "refused"), self.output)
        self.assertEqual(rep["reason"], "no drive qualifies")

    def test_a_labeled_drive_that_is_not_ext4_is_refused_with_the_fix(self):
        self.disks(boot_sd(), stick("vfat", LABEL))
        (self.fake / "labeled").write_text("/dev/sdz1\n")
        (self.fake / "type_dev_sdz1").write_text("vfat\n")
        rc, rep = self.run_script("--dry-run")
        self.assertEqual((rc, rep["result"], rep["device"]), (2, "refused", "/dev/sdz1"),
                         self.output)
        self.assertIn("not ext4", rep["reason"])
        self.assertIn("mkfs.ext4 -L adsb-archive -m 0 /dev/sdz1", rep["manual"])

    def test_a_labeled_ext4_drive_is_left_alone(self):
        self.disks(boot_sd(), stick("ext4", LABEL))
        (self.fake / "labeled").write_text("/dev/sdz1\n")
        (self.fake / "type_dev_sdz1").write_text("ext4\n")
        rc, rep = self.run_script("--dry-run")
        self.assertEqual((rc, rep["result"]), (0, "skipped"), self.output)

    @unittest.skipIf(os.path.lexists("/opt/adsb-receiver/applied"),
                     "this machine has a built rig, so a real run is refused before the part-way path")
    def test_a_failure_after_sfdisk_is_reported_part_way_never_as_nothing_changed(self):
        # A real run (the marker set) on a blank disk: sfdisk "succeeds" (a stub that only
        # records), but no partition device appears (/dev/sdz1 is not a block device here).
        # That is a failure with the disk part-way: exit 1, result failed, never refused/exit 2.
        self.stub("sfdisk", 'echo "sfdisk $*" >>"$FAKE/sfdisk.log"; cat >/dev/null; exit 0')
        self.stub("sleep", "exit 0")
        self.disks(boot_sd(), stick(children=False, pttype=None),
                   now={"path": "/dev/sdz", "size": 64 * GB, "serial": "S1", "ptuuid": None})
        rc, rep = self.run_script(env={"ADSB_FOUNDATION": "bootstrap"})
        self.assertTrue((self.fake / "sfdisk.log").exists(), self.output)
        self.assertEqual((rc, rep["result"]), (1, "failed"), self.output)
        self.assertIn("PART-WAY", rep["reason"])
        self.assertIn("PART-WAY", self.output)
        self.assertNotIn("NOT FORMATTING", self.output)

    def test_a_real_run_without_the_bootstraps_marker_refuses_before_looking(self):
        self.disks(boot_sd(), stick(None, None))
        rc, _ = self.run_script()
        self.assertEqual(rc, 1, self.output)
        self.assertIn("only update.sh --bootstrap formats", self.output)
        self.assertFalse((self.fake / "blkid.log").exists())


if __name__ == "__main__":
    unittest.main()
