# SPDX-License-Identifier: Apache-2.0
#
# setup/foundation/archive_candidates.py: the rule that decides which drive, if any, the first
# build may format. Fixtures are shaped like `lsblk -J -b -o NAME,KNAME,PATH,TYPE,TRAN,RM,RO,SIZE,
# FSTYPE,LABEL,PTTYPE,PARTN,MOUNTPOINTS`; no disk is touched.

import contextlib
import io
import json
import os
import tempfile
import unittest

from _load import load

AC = load("setup/foundation/archive_candidates.py", "archive_candidates")
LABEL = "adsb-archive"
GB = 1_000_000_000


def part(name, fstype=None, label=None, mounts=None, partn=None, children=None, size=60 * GB):
    n = {"name": name, "kname": name, "path": "/dev/" + name, "type": "part", "tran": None,
         "rm": True, "ro": False, "size": size, "fstype": fstype, "label": label, "pttype": "dos",
         "partn": partn, "mountpoints": mounts or [None]}
    if children:
        n["children"] = children
    return n


def disk(name, tran="usb", rm=True, size=64 * GB, pttype="dos", children=None, fstype=None,
         ro=False, mounts=None):
    n = {"name": name, "kname": name, "path": "/dev/" + name, "type": "disk", "tran": tran,
         "rm": rm, "ro": ro, "size": size, "fstype": fstype, "label": None, "pttype": pttype,
         "partn": None, "mountpoints": mounts or [None]}
    if children:
        n["children"] = children
    return n


def sd_boot():
    """The Pi's boot SD card: never a candidate, whatever else is plugged in."""
    return disk("mmcblk0", tran=None, rm=False, size=32 * GB, children=[
        part("mmcblk0p1", "vfat", "bootfs", ["/boot/firmware"], 1),
        part("mmcblk0p2", "ext4", "rootfs", ["/"], 2)])


def stick(name="sda", fstype="exfat", **kw):
    """The stick as bought: an MBR with one exFAT partition."""
    return disk(name, children=[part(name + "1", fstype, "USB DISK", partn=1)], **kw)


def doc(*disks):
    return {"blockdevices": list(disks)}


class SelectTest(unittest.TestCase):
    def sel(self, d, mounted=(), proven=(), final=False):
        return AC.select(d, set(mounted), LABEL, proven, final)

    def test_the_stick_as_bought_is_probed_then_formatted_once_proven_empty(self):
        d = doc(sd_boot(), stick())
        first = self.sel(d)
        self.assertEqual(first["decision"], "probe")
        self.assertEqual(first["probe"], [{"partition": "/dev/sda1", "fstype": "exfat"}])
        second = self.sel(d, proven=["/dev/sda1"], final=True)
        self.assertEqual(second["decision"], "format")
        self.assertEqual(second["partition"], "/dev/sda1")
        self.assertFalse(second["create_table"])
        self.assertTrue(second["wipe"])
        # The probed type reaches the final decision, so the last check can expect it.
        self.assertEqual(second["fstype"], "exfat")

    def test_a_stick_not_proven_empty_is_refused_with_its_exact_command(self):
        r = self.sel(doc(sd_boot(), stick()), final=True)
        self.assertEqual(r["decision"], "refuse")
        self.assertIn("mkfs.ext4 -L adsb-archive -m 0 /dev/sda1", r["manual"])
        self.assertIn("tune2fs -c 1 /dev/sda1", r["manual"])

    def test_an_existing_label_formats_nothing(self):
        d = doc(sd_boot(), disk("sda", children=[part("sda1", "ext4", LABEL, partn=1)]),
                stick("sdb", fstype=None))
        r = self.sel(d)
        self.assertEqual(r["decision"], "skip")
        self.assertIsNone(r["manual"])

    def test_the_label_on_another_filesystem_type_formats_nothing_and_names_the_fix(self):
        # Never formatted (the label marks a chosen drive), and refused rather than skipped:
        # step 30 mounts only ext4, so the operator is told what to do.
        r = self.sel(doc(disk("sda", children=[part("sda1", "vfat", LABEL, partn=1)]),
                         stick("sdb", fstype=None)))
        self.assertEqual(r["decision"], "refuse")
        self.assertIn("not ext4", r["reason"])
        self.assertIn("mkfs.ext4 -L adsb-archive -m 0 /dev/sda1", r["manual"])
        self.assertIsNone(r["disk"])

    def test_a_blank_disk_gets_a_table_and_partition_1(self):
        r = self.sel(doc(sd_boot(), disk("sda", pttype=None)))
        self.assertEqual(r["decision"], "format")
        self.assertTrue(r["create_table"])
        self.assertIsNone(r["partition"])
        self.assertIn("/dev/sda1", r["manual"])

    def test_a_partition_with_no_signature_is_formatted_without_a_probe(self):
        r = self.sel(doc(sd_boot(), stick(fstype=None)))
        self.assertEqual(r["decision"], "format")
        self.assertEqual(r["partition"], "/dev/sda1")
        self.assertFalse(r["wipe"])

    def test_two_qualifying_sticks_are_refused(self):
        r = self.sel(doc(sd_boot(), stick("sda", fstype=None), stick("sdb", fstype=None)))
        self.assertEqual(r["decision"], "refuse")
        self.assertIn("2 drives", r["reason"])
        self.assertIn("/dev/sdX1", r["manual"])

    def test_a_second_stick_that_holds_files_leaves_exactly_one(self):
        d = doc(sd_boot(), stick("sda", fstype=None), stick("sdb"))
        self.assertEqual(self.sel(d)["decision"], "probe")
        r = AC.select(d, set(), LABEL, (), True, ["/dev/sdb1"])
        self.assertEqual(r["decision"], "format")
        self.assertEqual(r["partition"], "/dev/sda1")

    def test_a_stick_that_could_not_be_read_refuses_the_whole_run(self):
        # PLAN §9e: a mount failure refuses; it does not exclude that stick and format the other.
        d = doc(sd_boot(), stick("sda", fstype=None), stick("sdb"))
        r = self.sel(d, final=True)
        self.assertEqual(r["decision"], "refuse")
        self.assertIn("/dev/sdb", r["reason"])
        self.assertIn("could not be read", r["reason"])

    def test_a_usb_ssd_root_is_excluded_by_its_mounts_and_its_rm(self):
        root = disk("sda", rm=False, size=500 * GB, children=[
            part("sda1", "vfat", "bootfs", ["/boot/firmware"], 1),
            part("sda2", "ext4", "rootfs", ["/"], 2)])
        r = self.sel(doc(root, disk("sdb", pttype=None)))
        self.assertEqual(r["decision"], "format")
        self.assertEqual(r["disk"], "/dev/sdb")

    def test_a_removable_usb_root_is_excluded_by_its_mount_alone(self):
        root = disk("sda", rm=True, children=[part("sda1", "ext4", "rootfs", ["/"], 1)])
        r = self.sel(doc(root))
        self.assertEqual(r["decision"], "refuse")
        self.assertIn("mounted", r["considered"][0]["reason"])

    def test_a_mount_seen_only_by_findmnt_excludes_the_disk(self):
        r = self.sel(doc(stick(fstype=None)), mounted={"/dev/sda1"})
        self.assertEqual(r["decision"], "refuse")

    def test_active_swap_by_kernel_name_excludes_the_disk(self):
        d = doc(disk("sda", children=[part("sda1", "swap", partn=1)]))
        d["blockdevices"][0]["children"][0]["path"] = "/dev/disk/by-x/odd"
        r = self.sel(d, mounted={"/dev/sda1"})
        self.assertEqual(r["decision"], "refuse")
        self.assertIn("mounted", r["considered"][0]["reason"])

    def test_sd_and_nvme_names_are_never_candidates_even_over_usb(self):
        for name in ("mmcblk1", "nvme0n1"):
            r = self.sel(doc(disk(name, pttype=None)))
            self.assertEqual(r["decision"], "refuse", name)

    def test_not_usb_not_removable_small_or_read_only_is_refused(self):
        for d in (disk("sda", tran="sata", pttype=None), disk("sda", rm=False, pttype=None),
                  disk("sda", size=4 * GB, pttype=None), disk("sda", ro=True, pttype=None)):
            self.assertEqual(self.sel(doc(d))["decision"], "refuse", d)

    def test_eight_gb_is_the_floor(self):
        self.assertEqual(self.sel(doc(disk("sda", size=8 * GB, pttype=None)))["decision"], "format")
        self.assertEqual(self.sel(doc(disk("sda", size=8 * GB - 1, pttype=None)))["decision"],
                         "refuse")

    def test_signatures_it_will_not_overwrite(self):
        for fs in ("crypto_LUKS", "linux_raid_member", "LVM2_member", "btrfs", "iso9660", "swap"):
            r = self.sel(doc(stick(fstype=fs)), final=False)
            self.assertEqual(r["decision"], "refuse", fs)

    def test_a_whole_disk_filesystem_is_refused(self):
        r = self.sel(doc(disk("sda", pttype=None, fstype="vfat")))
        self.assertEqual(r["decision"], "refuse")

    def test_layouts_it_will_not_guess_about(self):
        two = disk("sda", children=[part("sda1", partn=1), part("sda2", partn=2)])
        empty_table = disk("sda", pttype="gpt")
        not_one = disk("sda", children=[part("sda3", partn=3)])
        holder = disk("sda", children=[part("sda1", partn=1, children=[
            {"name": "dm-0", "kname": "dm-0", "path": "/dev/mapper/x", "type": "crypt",
             "mountpoints": [None]}])])
        for d in (two, empty_table, not_one, holder):
            self.assertEqual(self.sel(doc(d))["decision"], "refuse", d["children"] if "children" in d else d)

    def test_older_lsblk_strings_and_a_singular_mountpoint(self):
        d = disk("sda", pttype=None)
        d["rm"], d["ro"] = "1", "0"
        del d["mountpoints"]
        d["mountpoint"] = None
        self.assertEqual(self.sel(doc(d))["decision"], "format")
        d["mountpoint"] = "/media/x"
        self.assertEqual(self.sel(doc(d))["decision"], "refuse")


def fresh(name="sda", size=64 * GB, serial="S1", ptuuid="abcd-01"):
    return {"blockdevices": [{"name": name, "path": "/dev/" + name, "size": size,
                              "serial": serial, "ptuuid": ptuuid}]}


class RecheckTest(unittest.TestCase):
    """The last look before formatting: the same disk, and the signature decided on."""

    def decision(self, d, **kw):
        r = AC.select(doc(d), set(), LABEL, **kw)
        self.assertEqual(r["decision"], "format")
        return r

    def stick_ids(self, fstype="exfat", **kw):
        s = stick(fstype=fstype, **kw)
        s["serial"], s["ptuuid"] = "S1", "abcd-01"
        return s

    def test_the_stick_as_bought_passes_with_its_probed_type(self):
        dec = self.decision(self.stick_ids(), proven=["/dev/sda1"], final=True)
        self.assertIsNone(AC.recheck(dec, fresh(), "exfat"))

    def test_the_wipe_path_refuses_any_other_type_or_none(self):
        dec = self.decision(self.stick_ids(), proven=["/dev/sda1"], final=True)
        self.assertIsNotNone(AC.recheck(dec, fresh(), "vfat"))
        self.assertIsNotNone(AC.recheck(dec, fresh(), ""))

    def test_a_wipe_decision_with_no_type_never_passes(self):
        dec = self.decision(self.stick_ids(), proven=["/dev/sda1"], final=True)
        dec["fstype"] = None
        self.assertIn("names no filesystem", AC.recheck(dec, fresh(), ""))

    def test_a_partition_with_no_signature_must_still_have_none(self):
        dec = self.decision(self.stick_ids(fstype=None))
        self.assertIsNone(AC.recheck(dec, fresh(), ""))
        self.assertIsNotNone(AC.recheck(dec, fresh(), "ext4"))

    def test_a_blank_disk_must_still_be_blank(self):
        d = disk("sda", pttype=None)
        d["serial"] = "S1"
        dec = self.decision(d)
        self.assertIsNone(AC.recheck(dec, fresh(ptuuid=None), ""))
        self.assertIsNotNone(AC.recheck(dec, fresh(ptuuid=None), "dos"))

    def test_a_swapped_stick_under_the_same_name_is_refused(self):
        dec = self.decision(self.stick_ids(fstype=None))
        for f in (fresh(serial="S2"), fresh(size=32 * GB), fresh(ptuuid="ffff-01"),
                  {"blockdevices": []}):
            self.assertIsNotNone(AC.recheck(dec, f, ""), f)

    def test_after_the_new_table_only_size_and_serial_are_compared(self):
        d = disk("sda", pttype=None)
        d["serial"] = "S1"
        dec = self.decision(d)
        self.assertIsNone(AC.recheck(dec, fresh(ptuuid="new-uuid"), "", identity_only=True))
        self.assertIsNotNone(AC.recheck(dec, fresh(serial="S2"), "", identity_only=True))


class JournalTest(unittest.TestCase):
    def test_states(self):
        clean = "Filesystem volume name:   x\nFilesystem features:      has_journal ext_attr extent\n"
        dirty = "Filesystem features:      has_journal needs_recovery extent\n"
        self.assertEqual(AC.journal_state(clean)[0], "clean")
        self.assertEqual(AC.journal_state(dirty)[0], "needs_recovery")
        self.assertEqual(AC.journal_state("dumpe2fs: Bad magic number\n")[0], "unknown")


class MainExitTest(unittest.TestCase):
    """The shell reads these exit codes; 1 (a crash) must never mean an answer. select and recheck
    are run through argparse with the arguments format-archive.sh passes, --found "" included."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, obj):
        path = os.path.join(self.dir, name)
        with open(path, "w") as fh:
            if isinstance(obj, str):
                fh.write(obj)
            else:
                json.dump(obj, fh)
        return path

    def main(self, argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = AC.main(argv)
        return rc, out.getvalue()

    def test_select_then_final_select_as_the_shell_calls_them(self):
        s = stick("sda")
        s["serial"], s["ptuuid"] = "S1", "abcd-01"
        lsblk = self.write("lsblk.json", doc(sd_boot(), s, stick("sdb")))
        mounted = self.write("mounted", "/dev/mmcblk0p1\n/dev/mmcblk0p2\n\n")
        base = ["select", "--lsblk", lsblk, "--mounted", mounted, "--label", LABEL]
        rc, out = self.main(base)
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out)["decision"], "probe")
        rc, out = self.main(base + ["--final", "--proven-empty", "/dev/sda1",
                                    "--not-empty", "/dev/sdb1"])
        dec = json.loads(out)
        self.assertEqual((rc, dec["decision"], dec["partition"]), (0, "format", "/dev/sda1"))
        # Repeated --proven-empty, as the shell passes one per partition.
        rc, out = self.main(base + ["--final", "--proven-empty", "/dev/sda1",
                                    "--proven-empty", "/dev/sdb1"])
        self.assertEqual(json.loads(out)["decision"], "refuse")

    def test_recheck_exit_codes_with_an_empty_found(self):
        s = stick("sda", fstype=None)
        s["serial"], s["ptuuid"] = "S1", "abcd-01"
        dec = AC.select(doc(s), set(), LABEL)
        self.assertEqual(dec["decision"], "format")
        decision = self.write("decision.json", dec)
        now = self.write("now.json", fresh())
        base = ["recheck", "--decision", decision, "--lsblk", now]
        self.assertEqual(self.main(base + ["--found", ""])[0], 0)
        rc, out = self.main(base + ["--found", "vfat"])
        self.assertEqual(rc, 3)
        self.assertIn("vfat", out)
        swapped = self.write("swapped.json", fresh(serial="S2"))
        rc, _ = self.main(["recheck", "--decision", decision, "--lsblk", swapped, "--found", "",
                           "--identity-only"])
        self.assertEqual(rc, 3)
        new_table = self.write("newtable.json", fresh(ptuuid="new-01"))
        rc, _ = self.main(["recheck", "--decision", decision, "--lsblk", new_table, "--found", "",
                           "--identity-only"])
        self.assertEqual(rc, 0)

    def test_empty_and_journal_exit_codes(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(AC.main(["empty", root]), 0)
            with open(os.path.join(root, "x"), "w"):
                pass
            self.assertEqual(AC.main(["empty", root]), 3)
            self.assertEqual(AC.main(["empty", os.path.join(root, "missing")]), 2)
            f = os.path.join(root, "dump")
            with open(f, "w") as fh:
                fh.write("Filesystem features:      has_journal needs_recovery\n")
            self.assertEqual(AC.main(["journal", f]), 3)


class EmptyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_what_a_fresh_stick_holds_counts_as_empty(self):
        svi = os.path.join(self.root, "System Volume Information")
        os.makedirs(os.path.join(svi, "ClientRecoveryPasswordRotation"))
        for f in ("WPSettings.dat", "IndexerVolumeGuid"):
            with open(os.path.join(svi, f), "w"):
                pass
        os.makedirs(os.path.join(self.root, "lost+found"))
        os.makedirs(os.path.join(self.root, ".Trashes", "501"))
        self.assertEqual(AC.empty_state(self.root)[0], "empty")

    def test_system_volume_information_must_be_a_plain_directory_of_known_files(self):
        svi = os.path.join(self.root, "System Volume Information")
        # A symlink, or a regular file, by that name: not known to be nothing.
        os.symlink("/etc", svi)
        self.assertEqual(AC.empty_state(self.root)[0], "unknown")
        os.remove(svi)
        with open(svi, "w"):
            pass
        self.assertEqual(AC.empty_state(self.root)[0], "unknown")
        os.remove(svi)
        # A directory holding anything Windows does not write there fails closed, unnamed.
        os.makedirs(svi)
        with open(os.path.join(svi, "holiday.jpg"), "w"):
            pass
        state, why = AC.empty_state(self.root)
        self.assertEqual(state, "unknown")
        self.assertNotIn("holiday", why)
        os.remove(os.path.join(svi, "holiday.jpg"))
        # A known name that is not what Windows writes (a directory for a file, a full directory).
        os.makedirs(os.path.join(svi, "WPSettings.dat"))
        self.assertEqual(AC.empty_state(self.root)[0], "unknown")
        os.rmdir(os.path.join(svi, "WPSettings.dat"))
        os.makedirs(os.path.join(svi, "AadRecoveryPasswordDelete"))
        with open(os.path.join(svi, "AadRecoveryPasswordDelete", "x"), "w"):
            pass
        self.assertEqual(AC.empty_state(self.root)[0], "unknown")

    def test_any_other_entry_is_not_empty_and_is_not_named(self):
        with open(os.path.join(self.root, "holiday.jpg"), "w"):
            pass
        state, why = AC.empty_state(self.root)
        self.assertEqual(state, "not_empty")
        self.assertNotIn("holiday", why)

    def test_a_file_in_the_trash_is_not_empty(self):
        os.makedirs(os.path.join(self.root, ".Trashes", "501"))
        with open(os.path.join(self.root, ".Trashes", "501", "x"), "w"):
            pass
        self.assertEqual(AC.empty_state(self.root)[0], "not_empty")

    def test_a_symlink_inside_the_trash_counts_as_content(self):
        os.makedirs(os.path.join(self.root, ".Trashes", "501"))
        os.symlink("/", os.path.join(self.root, ".Trashes", "501", "link"))
        self.assertEqual(AC.empty_state(self.root)[0], "not_empty")

    def test_a_symlinked_or_regular_file_trash_or_lost_found_fails_closed(self):
        os.symlink("/etc", os.path.join(self.root, ".Trashes"))
        self.assertEqual(AC.empty_state(self.root)[0], "unknown")
        os.remove(os.path.join(self.root, ".Trashes"))
        with open(os.path.join(self.root, "lost+found"), "w"):
            pass
        self.assertEqual(AC.empty_state(self.root)[0], "unknown")

    @unittest.skipIf(os.geteuid() == 0, "root reads a mode-000 directory anyway")
    def test_an_unreadable_directory_in_lost_found_fails_closed(self):
        sub = os.path.join(self.root, "lost+found", "#12")
        os.makedirs(sub)
        os.chmod(sub, 0)
        try:
            self.assertEqual(AC.empty_state(self.root)[0], "unknown")
        finally:
            os.chmod(sub, 0o755)


if __name__ == "__main__":
    unittest.main()
