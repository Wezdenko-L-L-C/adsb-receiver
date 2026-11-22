# SPDX-License-Identifier: Apache-2.0
#
# bin/adsb-uploader against a fake rclone: a local directory stands for the
# store, and the fake answers `copy` and `lsjson` as rclone's drive backend is
# believed to (lsjson's Hashes carry an md5). ⛔ No network, no real store: the
# check-then-delete rule is what is tested, not rclone or Drive.

import datetime
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest

from _load import load

U = load("bin/adsb-uploader", "adsb_uploader")

NOW = 1_795_000_000.0          # 2026-11-17, UTC
TODAY = datetime.datetime.fromtimestamp(NOW, datetime.timezone.utc).date()


class FakeRclone:
    """rclone copy / lsjson over a local directory standing for the store.
    dest remotes look like ':drive:<root>/<host>[/beast/<day>]'."""

    def __init__(self, store):
        self.store = store
        self.calls = []
        self.copy_rc = 0
        self.corrupt = set()      # names whose store copy is altered after the copy
        self.no_md5 = set()       # names listed with no md5
        self.duplicate = set()    # names listed twice
        self.lsjson_rc = 0
        self.copy_skip = set()    # names the copy does not send

    def path(self, remote):
        assert remote.startswith(":drive:"), remote
        return os.path.join(self.store, remote[len(":drive:"):])

    def __call__(self, argv, env=None, capture_output=True, text=True, timeout=None):
        self.calls.append((argv, env))
        cmd = argv[1]
        if cmd == "copy":
            lst = argv[argv.index("--files-from") + 1]
            src, dst = argv[-2], argv[-1]
            with open(lst) as fh:
                rels = [l.strip() for l in fh if l.strip()]
            for rel in rels:
                if os.path.basename(rel) in self.copy_skip:
                    continue
                d = os.path.join(self.path(dst), rel)
                os.makedirs(os.path.dirname(d), exist_ok=True)
                shutil.copyfile(os.path.join(src, rel), d)
                if os.path.basename(rel) in self.corrupt:
                    with open(d, "ab") as fh:
                        fh.write(b"x")
            return subprocess.CompletedProcess(argv, self.copy_rc, "", "copy stderr\n")
        if cmd == "lsjson":
            if self.lsjson_rc:
                return subprocess.CompletedProcess(argv, self.lsjson_rc, "", "Failed to lsjson: boom\n")
            d = self.path(argv[-1])
            if not os.path.isdir(d):
                return subprocess.CompletedProcess(argv, 3, "", "directory not found\n")
            items = []
            for name in sorted(os.listdir(d)):
                p = os.path.join(d, name)
                if os.path.isdir(p):
                    if "--dirs-only" in argv:
                        items.append({"Name": name, "IsDir": True, "Size": -1})
                    continue
                if "--dirs-only" in argv:
                    continue
                with open(p, "rb") as fh:
                    md5 = hashlib.md5(fh.read()).hexdigest()
                it = {"Name": name, "Size": os.path.getsize(p), "IsDir": False,
                      "Hashes": {} if name in self.no_md5 else {"md5": md5}}
                items.append(it)
                if name in self.duplicate:
                    items.append(dict(it))
            return subprocess.CompletedProcess(argv, 0, json.dumps(items), "")
        raise AssertionError(f"unexpected rclone command {argv}")


class UploadTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.archive = os.path.join(self.tmp, "archive")
        self.store = os.path.join(self.tmp, "store")
        self.state = os.path.join(self.tmp, "state")
        self.cache = os.path.join(self.tmp, "cache")
        for d in (self.archive, self.store, self.cache):
            os.makedirs(d)
        self.rc = FakeRclone(self.store)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def put(self, rel, data=b"BEAST", age_s=600):
        p = os.path.join(self.archive, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as fh:
            fh.write(data)
        os.utime(p, (NOW - age_s, NOW - age_s))
        return p

    def upload(self, root="", host="home-adsb"):
        return U.do_upload(self.archive, "0ABCDEFGHIJK", root, host, "/cred.json", self.cache,
                           self.state, now=lambda: NOW, run=self.rc, utc_today=TODAY,
                           ismount=lambda p: True)

    def state_doc(self):
        with open(os.path.join(self.state, "state.json")) as fh:
            return json.load(fh)

    def in_store(self, rel, host="home-adsb", root=""):
        return os.path.exists(os.path.join(self.store, root, host, rel))

    def test_closed_files_are_copied_in_the_mirror_layout_checked_and_deleted(self):
        a = self.put("beast/2026-11-10/20261110T100000Z.beast.pcap", b"one")
        b = self.put("beast/2026-11-10/20261110T101000Z.beast.pcap.torn", b"two")
        c = self.put("beast/2026-11-17/20261117T100000Z.beast.pcap", b"three")
        self.assertEqual(self.upload(), U.EXIT_OK)
        for rel in ("beast/2026-11-10/20261110T100000Z.beast.pcap",
                    "beast/2026-11-10/20261110T101000Z.beast.pcap.torn",
                    "beast/2026-11-17/20261117T100000Z.beast.pcap"):
            self.assertTrue(self.in_store(rel), rel)
        for p in (a, b, c):
            self.assertFalse(os.path.exists(p), p)
        # An old empty date directory goes; today's stays for the writer.
        self.assertFalse(os.path.exists(os.path.join(self.archive, "beast/2026-11-10")))
        self.assertTrue(os.path.isdir(os.path.join(self.archive, "beast/2026-11-17")))
        s = self.state_doc()
        self.assertEqual((s["result"], s["files_in_batch"], s["checked"], s["deleted"],
                          s["not_checked"], s["days_pruned"]), ("ok", 3, 3, 3, 0, 1))

    def test_root_folder_prefixes_the_host_folder(self):
        self.put("beast/2026-11-10/20261110T100000Z.beast.pcap")
        self.assertEqual(self.upload(root="Archive/ADS-B"), U.EXIT_OK)
        self.assertTrue(self.in_store("beast/2026-11-10/20261110T100000Z.beast.pcap",
                                      root="Archive/ADS-B"))

    def test_only_closed_files_old_enough_are_taken(self):
        keep = [
            self.put("beast/2026-11-17/20261117T120000Z.beast.pcap.part"),
            self.put("beast/2026-11-17/.archive-preflight-probe.1"),
            self.put("beast/2026-11-17/notes.txt"),
            self.put("beast/not-a-date/20261117T100000Z.beast.pcap"),
            self.put("spool/20261117T100000Z.beast.pcap"),
            self.put("beast/2026-11-17/20261117T121000Z.beast.pcap", age_s=5),
        ]
        os.symlink("/etc/passwd", os.path.join(self.archive, "beast/2026-11-17/20261117T122000Z.beast.pcap"))
        self.assertEqual(self.upload(), U.EXIT_OK)
        self.assertEqual(self.state_doc()["result"], "nothing to upload")
        for p in keep:
            self.assertTrue(os.path.exists(p), p)
        self.assertEqual(self.rc.calls, [])

    def test_a_file_that_does_not_check_is_kept(self):
        good = self.put("beast/2026-11-10/20261110T100000Z.beast.pcap", b"good")
        bad = self.put("beast/2026-11-10/20261110T101000Z.beast.pcap", b"bad")
        nomd5 = self.put("beast/2026-11-10/20261110T102000Z.beast.pcap", b"nomd5")
        dup = self.put("beast/2026-11-10/20261110T103000Z.beast.pcap", b"dup")
        missing = self.put("beast/2026-11-10/20261110T104000Z.beast.pcap", b"missing")
        self.rc.corrupt.add(os.path.basename(bad))
        self.rc.no_md5.add(os.path.basename(nomd5))
        self.rc.duplicate.add(os.path.basename(dup))
        self.rc.copy_skip.add(os.path.basename(missing))
        self.rc.copy_rc = 1
        self.assertEqual(self.upload(), U.EXIT_NOT_READY)
        self.assertFalse(os.path.exists(good))
        for p in (bad, nomd5, dup, missing):
            self.assertTrue(os.path.exists(p), p)
        # The date directory is not empty, so it stays.
        self.assertTrue(os.path.isdir(os.path.dirname(good)))
        s = self.state_doc()
        self.assertEqual((s["result"], s["copy_exit"], s["deleted"], s["not_checked"]),
                         ("some files did not check", 1, 1, 4))

    def test_store_not_reached_deletes_nothing(self):
        p = self.put("beast/2026-11-10/20261110T100000Z.beast.pcap")
        self.rc.lsjson_rc = 1
        self.assertEqual(self.upload(), U.EXIT_NOT_READY)
        self.assertTrue(os.path.exists(p))
        self.assertEqual(self.state_doc()["result"], "the store was not reached")

    def test_not_mounted_is_nothing_to_do(self):
        self.put("beast/2026-11-10/20261110T100000Z.beast.pcap")
        rc = U.do_upload(self.archive, "0ABCDEFGHIJK", "", "h", "/c", self.cache, self.state,
                         now=lambda: NOW, run=self.rc, utc_today=TODAY, ismount=lambda p: False)
        self.assertEqual(rc, U.EXIT_OK)
        self.assertEqual(self.rc.calls, [])
        self.assertEqual(self.state_doc()["result"], "no archive mounted")

    def test_rclone_gets_no_config_file_and_the_drive_options_by_environment(self):
        self.put("beast/2026-11-10/20261110T100000Z.beast.pcap")
        os.environ["RCLONE_DRIVE_ROOT_FOLDER_ID"] = "leaked"
        try:
            self.upload()
        finally:
            del os.environ["RCLONE_DRIVE_ROOT_FOLDER_ID"]
        argv, env = self.rc.calls[0]
        self.assertEqual(argv[1], "copy")
        self.assertIn("--no-traverse", argv)
        self.assertIn("--checksum", argv)
        self.assertEqual(argv[-1], ":drive:home-adsb")
        self.assertEqual(env["RCLONE_CONFIG"], "/dev/null")
        self.assertEqual(env["RCLONE_DRIVE_TEAM_DRIVE"], "0ABCDEFGHIJK")
        self.assertEqual(env["RCLONE_DRIVE_SERVICE_ACCOUNT_FILE"], "/cred.json")
        self.assertNotIn("RCLONE_DRIVE_ROOT_FOLDER_ID", env)

    def test_state_holds_no_store_id(self):
        self.put("beast/2026-11-10/20261110T100000Z.beast.pcap")
        self.upload()
        with open(os.path.join(self.state, "state.json")) as fh:
            self.assertNotIn("0ABCDEFGHIJK", fh.read())

    def test_batch_is_capped_oldest_first(self):
        for i in range(5):
            self.put(f"beast/2026-11-10/20261110T10{i}000Z.beast.pcap")
        got = U.closed_files(self.archive, NOW, limit=3)
        self.assertEqual([r for r, _, _ in got], [f"beast/2026-11-10/20261110T10{i}000Z.beast.pcap"
                                                  for i in range(3)])


class ConfTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def conf(self, text):
        p = os.path.join(self.tmp, "uploader.conf")
        with open(p, "w") as fh:
            fh.write(text)
        return p

    def test_valid(self):
        self.assertEqual(U.read_conf(self.conf("# c\ndrive_id=0ABCdef_-123\nroot=\n")),
                         ("0ABCdef_-123", ""))
        self.assertEqual(U.read_conf(self.conf("drive_id=0ABCdef_-123\nroot=A b/C(1)\n"))[1], "A b/C(1)")

    def test_refused(self):
        for text in ("root=\n", "drive_id=x\n", "drive_id=0ABCdef_-123\ndrive_id=0ABCdef_-123\n",
                     "drive_id=0ABCdef_-123\nroot=../x\n", "drive_id=0ABCdef_-123\nroot=/x\n",
                     "drive_id=0ABCdef_-123\nroot=a//b\n", "drive_id=0ABCdef_-123\nroot=a:b\n",
                     "drive_id=0ABCdef_-123\nother=1\n", "drive_id=0ABCdef_-123\nnot a pair\n"):
            with self.assertRaises(U.ConfError, msg=text):
                U.read_conf(self.conf(text))

    def test_host(self):
        self.assertEqual(U.host_name("home-adsb.lan"), "home-adsb")
        for bad in ("", "-x", "a_b", "x" * 64):
            with self.assertRaises(U.ConfError, msg=bad):
                U.host_name(bad)

    def test_credential(self):
        p = os.path.join(self.tmp, "sa.json")
        with open(p, "w") as fh:
            json.dump({"type": "service_account", "client_email": "u@p.iam.gserviceaccount.com",
                       "private_key": "-----BEGIN PRIVATE KEY-----\nsecret\n"}, fh)
        self.assertEqual(U.check_credential(p), "u@p.iam.gserviceaccount.com")
        with open(p, "w") as fh:
            json.dump({"type": "authorized_user", "client_email": "x"}, fh)
        with self.assertRaises(U.ConfError) as cm:
            U.check_credential(p)
        self.assertNotIn("secret", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
