# SPDX-License-Identifier: Apache-2.0
#
# bin/adsb-writer, on synthesized BEAST streams. ⛔ No real capture is
# committed: every byte here is built by the tests.

import io
import json
import os
import socket
import tempfile
import threading
import types
import unittest

from _load import FakeClock, beast, extract, utc_ns, writer as W

LONG = bytes(range(0x10, 0x1E))          # 14 bytes, one of them 0x1a
SHORT = bytes([0x5D, 0x1A, 0x1A, 1, 2, 3, 4])


class ParserTest(unittest.TestCase):
    def test_escaped_bytes_are_kept_as_received(self):
        f1 = beast(0x33, 0x1A1A00001A1A, 0x1A, LONG)
        f2 = beast(0x32, 5, 0x40, SHORT)
        f3 = beast(0x31, 0, 0, b"\x00\x00")
        items = W.BeastParser().feed(f1 + f2 + f3)
        self.assertEqual(items, [("frame", f1), ("frame", f2), ("frame", f3)])
        typ, counter, sig, data = extract.decode_frame(f1)
        self.assertEqual((typ, counter, sig, data), (0x33, 0x1A1A00001A1A, 0x1A, LONG))

    def test_a_frame_split_across_recv_boundaries(self):
        f1 = beast(0x33, 0x1A, 0x1A, LONG)
        f2 = beast(0x32, 7, 1, SHORT)
        stream = f1 + f2
        # Every split point, including between the two bytes of a doubled 0x1a.
        for cut in range(1, len(stream)):
            p = W.BeastParser()
            items = p.feed(stream[:cut]) + p.feed(stream[cut:])
            self.assertEqual(items, [("frame", f1), ("frame", f2)], f"cut at {cut}")
        p = W.BeastParser()
        items = []
        for b in stream:
            items += p.feed(bytes([b]))
        self.assertEqual(items, [("frame", f1), ("frame", f2)])

    def test_resync_on_an_unknown_type(self):
        good = beast(0x32, 9, 2, SHORT)
        junk = b"\x1a\xe3" + b"\x01\x02\x03\x04\x05"
        items = W.BeastParser().feed(good + junk + good)
        self.assertEqual(items, [("frame", good), ("resync", len(junk), "type=0xe3"), ("frame", good)])

    def test_a_frame_cut_by_a_new_one_is_resynced(self):
        good = beast(0x32, 9, 2, SHORT)
        cut = beast(0x33, 1, 1, LONG)[:6]
        items = W.BeastParser().feed(good + cut + good)
        self.assertEqual(items, [("frame", good), ("resync", 6, "truncated"), ("frame", good)])


class WriterTestBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.archive = os.path.join(self.tmp.name, "beast")
        os.mkdir(self.archive)
        self.status = os.path.join(self.tmp.name, "writer.json")
        self.clock = FakeClock(utc_ns(2026, 10, 4, 12, 3, 17, 250_000_000))
        self.free = 10 << 30
        self.logs = []
        self.real_log = W.log
        W.log = self.logs.append

    def tearDown(self):
        W.log = self.real_log
        self.tmp.cleanup()

    def statvfs(self, _path):
        return types.SimpleNamespace(f_bavail=self.free // 4096, f_frsize=4096)

    def make(self, min_free=1 << 30, probe=None):
        return W.Writer(self.archive, min_free, status_path=self.status, clock_ns=self.clock,
                        statvfs=self.statvfs, probe=probe, source="test")

    def files(self):
        out = []
        for d, _, names in os.walk(self.archive):
            out += [os.path.relpath(os.path.join(d, n), self.archive) for n in names]
        return sorted(out)


class WriterTest(WriterTestBase):
    def test_named_by_the_second_it_was_opened(self):
        w = self.make()
        w.begin("start test")
        self.assertEqual(self.files(), ["2026-10-04/20261004T120317Z.beast.pcap.part"])
        w.finish("SIGTERM")
        self.assertEqual(self.files(), ["2026-10-04/20261004T120317Z.beast.pcap"])

    def test_rotation_at_a_ten_minute_boundary(self):
        w = self.make()
        w.begin("start test")
        f = beast(0x33, 1000, 50, LONG)
        self.clock.ns = utc_ns(2026, 10, 4, 12, 9, 59, 900_000_000)
        self.assertFalse(w.due(self.clock.ns))
        w.frame(self.clock.ns, f)
        self.clock.ns = utc_ns(2026, 10, 4, 12, 10, 0, 100_000_000)
        self.assertTrue(w.due(self.clock.ns))
        w.rotate()
        w.frame(self.clock.ns, f)
        w.finish("SIGTERM")
        self.assertEqual(self.files(), ["2026-10-04/20261004T120317Z.beast.pcap",
                                        "2026-10-04/20261004T121000Z.beast.pcap"])
        first, _ = extract.read_pcap(os.path.join(self.archive, self.files()[0]))
        second, _ = extract.read_pcap(os.path.join(self.archive, self.files()[1]))
        self.assertEqual([p for _, p in first], [b"start test", f])
        self.assertEqual([p for _, p in second], [f, b"stop reason=SIGTERM"])

    def test_an_interval_with_no_frames_still_gets_a_file(self):
        w = self.make()
        w.begin("start test")
        for minute in (10, 20, 30):
            self.clock.ns = utc_ns(2026, 10, 4, 12, minute, 0, 5)
            w.rotate()
        w.finish("SIGINT")
        self.assertEqual(len(self.files()), 4)

    def test_pcap_header(self):
        w = self.make()
        w.begin("start test")
        w.finish("SIGTERM")
        with open(os.path.join(self.archive, self.files()[0]), "rb") as fh:
            head = fh.read(24)
        self.assertEqual(head[:4], b"\x4d\x3c\xb2\xa1")
        self.assertEqual(head[4:8], b"\x02\x00\x04\x00")
        self.assertEqual(int.from_bytes(head[16:20], "little"), 65535)
        self.assertEqual(int.from_bytes(head[20:24], "little"), 147)

    def test_rename_never_clobbers(self):
        day = os.path.join(self.archive, "2026-10-04")
        os.mkdir(day)
        taken = os.path.join(day, "20261004T120317Z.beast.pcap")
        with open(taken, "wb") as fh:
            fh.write(b"older")
        w = self.make()
        w.begin("start test")
        w.finish("SIGTERM")
        self.assertEqual(self.files(), ["2026-10-04/20261004T120317Z.1.beast.pcap",
                                        "2026-10-04/20261004T120317Z.beast.pcap"])
        with open(taken, "rb") as fh:
            self.assertEqual(fh.read(), b"older")

    def test_sigterm_close_path(self):
        w = self.make()
        w.begin("start test")
        w.event("connected 127.0.0.1:30005")
        w.frame(self.clock.ns, beast(0x32, 3, 3, SHORT))
        w.finish("SIGTERM")
        self.assertEqual([n for n in self.files() if n.endswith(".part")], [])
        records, note = extract.read_pcap(os.path.join(self.archive, self.files()[0]))
        self.assertIsNone(note)
        self.assertEqual(records[-1][1], b"stop reason=SIGTERM")
        with open(self.status) as fh:
            st = json.load(fh)
        self.assertEqual(st["state"], "stopped")
        self.assertIsNone(st["current_file"])

    def test_a_link_at_the_status_tmp_name_is_not_followed(self):
        # The status directory is the group's to write: a symlink or a hard link planted at the
        # .tmp name must not be opened, so what it points to is left as it was.
        victim = os.path.join(self.tmp.name, "victim")
        for kind in ("symlink", "hardlink"):
            with self.subTest(kind=kind):
                with open(victim, "w") as fh:
                    fh.write("untouched\n")
                tmp = self.status + ".tmp"
                (os.symlink if kind == "symlink" else os.link)(victim, tmp)
                w = self.make()
                w.write_status(force=True)
                with open(victim) as fh:
                    self.assertEqual(fh.read(), "untouched\n")
                self.assertFalse(os.path.lexists(tmp))
                with open(self.status) as fh:
                    self.assertIn("updated_at", json.load(fh))
                os.unlink(self.status)

    def test_position_never_reaches_the_status_file(self):
        line = "position 10.5 20.5 100.0 3 2026-10-04T12:03:17.000Z"
        w = self.make(probe=lambda: ["clock ref=TEST", line])
        w.begin("start test")
        for t in threading.enumerate():
            if t.name == "probe":
                t.join(5)
        w.drain_probes()
        w.write_status(force=True)
        w.finish("SIGTERM")
        with open(self.status) as fh:
            self.assertNotIn("10.5", fh.read())
        self.assertFalse([m for m in self.logs if "10.5" in m], self.logs)
        records, _ = extract.read_pcap(os.path.join(self.archive, self.files()[0]))
        self.assertIn(line.encode(), [p for _, p in records])


class ExpiryTest(WriterTestBase):
    """Free space is self.base minus the blocks the archive holds, counted per
    inode as st_blocks * 512: what a filesystem's free count actually sees."""

    def put(self, rel, size):
        path = os.path.join(self.archive, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(b"x" * size)
        return path

    def used(self):
        seen = {}
        for d, _, ns in os.walk(self.archive):
            for n in ns:
                st = os.lstat(os.path.join(d, n))
                seen[(st.st_dev, st.st_ino)] = st.st_blocks * 512
        return sum(seen.values())

    def blocks(self, rel):
        return os.lstat(os.path.join(self.archive, rel)).st_blocks * 512

    def statvfs(self, _path):
        return types.SimpleNamespace(f_bavail=self.base - self.used(), f_frsize=1)

    def run_main(self, during=None):
        """main() with the fake clock and drive; during(w) stands in for run()."""
        clock, statvfs = self.clock, self.statvfs
        real_writer, real_run, real_signal = W.Writer, W.run, W.signal.signal

        def writer(*a, **kw):
            kw.update(clock_ns=clock, statvfs=statvfs, probe=None)
            return real_writer(*a, **kw)

        def run(w, _host, _port, _stop):
            if during:
                during(w)

        W.Writer, W.run, W.signal.signal = writer, run, lambda *_a: None
        try:
            return W.main(["--archive", self.archive, "--status", self.status,
                           "--min-free-gb", "1", "--no-position"])
        finally:
            W.Writer, W.run, W.signal.signal = real_writer, real_run, real_signal

    def test_oldest_first_by_name_never_a_part(self):
        self.put("2026-10-01/20261001T235000Z.beast.pcap.torn", 100)
        self.put("2026-10-02/20261002T000000Z.beast.pcap", 100)
        self.put("2026-10-02/20261002T001000Z.1.beast.pcap", 100)
        self.put("2026-10-02/20261002T002000Z.beast.pcap.part", 100)
        self.put("2026-10-03/20261003T000000Z.beast.pcap", 100)
        # Make the oldest by name the newest by mtime: name order must win.
        os.utime(os.path.join(self.archive, "2026-10-01/20261001T235000Z.beast.pcap.torn"))
        b = self.blocks("2026-10-03/20261003T000000Z.beast.pcap")
        self.base = self.used() + b
        # free b; need 3.5b -> three files go (free 4b).
        w = self.make(min_free=b * 7 // 2)
        expired = w.expire()
        self.assertEqual([e["path"] for e in expired], [
            "2026-10-01/20261001T235000Z.beast.pcap.torn",
            "2026-10-02/20261002T000000Z.beast.pcap",
            "2026-10-02/20261002T001000Z.1.beast.pcap",
        ])
        self.assertEqual(self.files(), ["2026-10-02/20261002T002000Z.beast.pcap.part",
                                        "2026-10-03/20261003T000000Z.beast.pcap"])
        self.assertFalse(os.path.exists(os.path.join(self.archive, "2026-10-01")))
        self.assertEqual([p.decode().split()[0] for _, p in w.pending], ["expired"] * 3)

    def test_refuses_when_nothing_is_left(self):
        self.put("2026-10-02/20261002T002000Z.beast.pcap.part", 100)
        self.base = 150
        w = self.make(min_free=300)
        with self.assertRaises(W.OutOfSpace):
            w.expire()
        self.assertEqual(self.files(), ["2026-10-02/20261002T002000Z.beast.pcap.part"])

    def test_unreachable_at_start_deletes_nothing(self):
        old = ["2026-10-01/20261001T000000Z.beast.pcap",
               "2026-10-02/20261002T000000Z.beast.pcap.torn"]
        for rel in old:
            self.put(rel, 100)
        self.base = self.used() + 1000
        expirable = sum(self.blocks(rel) for rel in old)
        w = self.make(min_free=1000 + expirable + 1)  # one byte out of reach
        with self.assertRaises(W.OutOfSpace) as cm:
            w.begin("start test")
        self.assertEqual(self.files(), old)  # and no .part opened
        self.assertEqual([p for _, p in w.pending], [b"start test"])  # no expired event
        msg = str(cm.exception)
        self.assertIn("1000 bytes free", msg)
        self.assertIn(f"{expirable} bytes expirable", msg)
        self.assertIn(f"({1000 + expirable + 1} bytes)", msg)
        self.assertIn("Nothing was deleted", msg)

    def test_unreachable_at_rotation_deletes_nothing_and_keeps_the_file_it_just_closed(self):
        old = "2026-10-04/20261004T110000Z.beast.pcap"
        self.put(old, 100)
        self.base = 1 << 30
        w = self.make(min_free=1 << 20)
        w.begin("start test")
        f = beast(0x32, 3, 3, SHORT)
        w.frame(self.clock.ns, f)
        self.clock.ns = utc_ns(2026, 10, 4, 12, 10, 0, 5)
        # The threshold is reachable only by deleting the file this rotation
        # closes: free + the older file falls short, free + both would not.
        w.fh.flush()
        self.base = self.used() + 1000
        closed = "2026-10-04/20261004T120317Z.beast.pcap"
        w.min_free = 1000 + self.blocks(old) + 1
        self.assertGreaterEqual(1000 + self.blocks(old) + self.blocks(closed + ".part"), w.min_free)
        with self.assertRaises(W.OutOfSpace) as cm:
            w.rotate()
        self.assertIn(f"sparing the file just closed ({closed})", str(cm.exception))
        # Nothing deleted, the older file included; no new .part opened.
        self.assertEqual(self.files(), [old, closed])
        records, note = extract.read_pcap(os.path.join(self.archive, closed))
        self.assertIsNone(note)
        self.assertEqual(records[-1][1], f)

    def test_reachable_at_rotation_oldest_first_stops_at_threshold_and_spares_the_file_just_closed(self):
        old = ["2026-10-04/20261004T090000Z.beast.pcap",
               "2026-10-04/20261004T100000Z.beast.pcap",
               "2026-10-04/20261004T110000Z.beast.pcap"]
        for rel in old:
            self.put(rel, 100)
        b = self.blocks(old[0])
        self.base = 1 << 30
        w = self.make(min_free=1 << 20)
        w.begin("start test")
        self.clock.ns = utc_ns(2026, 10, 4, 12, 10, 0, 5)
        w.fh.flush()
        self.base = self.used() + b // 2
        w.min_free = 2 * b  # free b/2: the two oldest go (free 2.5b), the third stays
        w.rotate()
        self.assertEqual([e["path"] for e in w.status["last_expired"]], old[:2])
        self.assertEqual(self.files(), [old[2], "2026-10-04/20261004T120317Z.beast.pcap",
                                        "2026-10-04/20261004T121000Z.beast.pcap.part"])
        w.finish("SIGTERM")
        records, _ = extract.read_pcap(os.path.join(self.archive, "2026-10-04/20261004T121000Z.beast.pcap"))
        self.assertEqual([p.split()[0] for _, p in records][:2], [b"expired", b"expired"])

    def test_a_sparse_file_counts_its_blocks_not_its_size(self):
        rel = "2026-10-01/20261001T000000Z.beast.pcap"
        path = self.put(rel, 0)
        with open(path, "r+b") as fh:
            fh.truncate(1 << 20)  # 1 MiB long, next to nothing allocated
        self.base = self.used() + 1000
        w = self.make(min_free=1000 + (1 << 19))  # its size would reach this; its blocks cannot
        with self.assertRaises(W.OutOfSpace):
            w.expire()
        self.assertEqual(self.files(), [rel])

    def test_a_name_hard_linked_to_a_part_counts_nothing(self):
        # A power cut between link and unlink in link_noclobber: both names.
        rel = "2026-10-01/20261001T000000Z.beast.pcap"
        path = self.put(rel, 100)
        os.link(path, path + ".part")
        self.base = self.used() + 1000
        w = self.make(min_free=1001)  # deleting the closed name returns nothing
        with self.assertRaises(W.OutOfSpace) as cm:
            w.expire()
        self.assertIn("0 bytes expirable", str(cm.exception))
        self.assertEqual(self.files(), [rel, rel + ".part"])

    def test_restart_after_a_refusal_at_rotation_still_deletes_nothing(self):
        old = "2026-10-04/20261004T110000Z.beast.pcap"
        closed = "2026-10-04/20261004T120317Z.beast.pcap"
        self.put(old, 100)
        self.base = 2 << 30

        def during(w):
            w.frame(self.clock.ns, beast(0x32, 3, 3, SHORT))
            self.clock.ns = utc_ns(2026, 10, 4, 12, 10, 0, 5)
            w.fh.flush()
            # 1 GiB threshold, 1000 bytes free: out of reach with every file counted.
            self.base = self.used() + 1000
            w.rotate()

        self.assertEqual(self.run_main(during), 1)
        self.assertEqual(self.files(), [old, closed])
        with open(self.status) as fh:
            st = json.load(fh)
        self.assertEqual(st["state"], "refused")
        self.assertIn(f"sparing the file just closed ({closed})", st["refused_reason"])

        # systemd's restart: a fresh writer, the same threshold, nothing spared.
        self.logs.clear()
        self.clock.ns = utc_ns(2026, 10, 4, 12, 10, 30)
        self.assertEqual(self.run_main(), 1)
        self.assertEqual(self.files(), [old, closed])
        with open(self.status) as fh:
            st = json.load(fh)
        self.assertEqual(st["state"], "refused")
        refusing = [m for m in self.logs if m.startswith("REFUSING TO RECORD")]
        self.assertEqual(len(refusing), 1, self.logs)
        expirable = self.blocks(old) + self.blocks(closed)
        self.assertIn("1000 bytes free", refusing[0])
        self.assertIn(f"{expirable} bytes expirable", refusing[0])
        self.assertIn(f"({1 << 30} bytes)", refusing[0])

    def test_expiry_at_start_lands_in_the_first_file(self):
        self.put("2026-10-01/20261001T000000Z.beast.pcap", 100)
        self.base = 150
        w = self.make(min_free=100)
        w.begin("start test")
        w.finish("SIGTERM")
        records, _ = extract.read_pcap(os.path.join(self.archive, self.files()[0]))
        self.assertEqual([p for _, p in records][:2],
                         [b"start test", b"expired 2026-10-01/20261001T000000Z.beast.pcap 100"])

    def test_a_file_moved_away_is_not_replaced_by_the_next_oldest(self):
        a = self.put("2026-10-01/20261001T000000Z.beast.pcap", 100)
        b = self.put("2026-10-02/20261002T000000Z.beast.pcap", 100)
        self.base = self.used() + 10
        w = self.make(min_free=10 + self.blocks("2026-10-01/20261001T000000Z.beast.pcap"))
        real = W.os.path.getsize
        moved = os.path.join(self.tmp.name, "moved")

        def getsize(p):
            if p == a and os.path.exists(a):
                os.rename(a, moved)  # rsync moved it after expiry listed it: that space is free now
            return real(p)
        W.os.path.getsize = getsize
        try:
            expired = w.expire()
        finally:
            W.os.path.getsize = real
        self.assertEqual(expired, [])
        self.assertTrue(os.path.exists(b), "the next oldest was expired although the move freed enough")


def join_threads(name):
    for t in threading.enumerate():
        if t.name == name:
            t.join(5)


def tracking_csv(age_s, now_s, leap="Normal"):
    # Two decimals at most: the commit guard reads longer ones around a comma as a position.
    return ",".join(["C0000201", "192.0.2.1", "2", f"{now_s - age_s:.2f}", "0.01", "0.00", "0.01",
                     "7.80", "0.00", "0.03", "0.04", "0.03", "1037.6", leap]) + "\n"


class ClockTest(WriterTestBase):
    """The clock while recording (ruled 2026-11-11 19:01): marked, never a reason to stop."""

    def fake_run(self, tracking, sources, rc=0):
        def run(argv, **_kw):
            out = tracking if argv[-1] == "tracking" else sources
            return types.SimpleNamespace(returncode=rc, stdout=out)
        return run

    def test_probe_clock_carries_state_age_bound_and_source_counts(self):
        now = 1_800_000_000.0
        src = "^,-,192.0.2.1,2,10,377,500,0.00,0.00,0.05\n^,?,192.0.2.2,2,10,0,600,0.00,0.00,0.06\n"
        line = W.probe_clock(now_s=lambda: now, run=self.fake_run(tracking_csv(19800, now), src))
        self.assertEqual(line, "clock ref=C0000201 name=192.0.2.1 stratum=2 system_time_s=0.01 leap=Normal"
                               " state=HOLDOVER ref_age_s=19800 bound_ms=60.000"
                               " sources=2 selected=0 combined=0 reachable=1")
        line = W.probe_clock(now_s=lambda: now, run=self.fake_run(tracking_csv(5, now), ""))
        self.assertIn("state=COARSE ref_age_s=5 ", line)
        self.assertTrue(line.endswith("sources=? selected=? combined=? reachable=?"), line)
        self.assertEqual(W.probe_clock(run=self.fake_run("", "", rc=1)),
                         "clock unavailable reason=chronyc-exit-1")

    def test_a_loss_mid_session_keeps_recording_and_writes_one_event_on_the_change(self):
        synced = ("clock ref=C0000201 name=192.0.2.1 stratum=2 system_time_s=0.00 leap=Normal state=SYNCED"
                  " ref_age_s=5 bound_ms=15.000 sources=2 selected=1 combined=0 reachable=2")
        holdover = synced.replace("state=SYNCED ref_age_s=5", "state=HOLDOVER ref_age_s=2400") \
                         .replace("selected=1", "selected=0")
        readings = iter([synced, synced, holdover, holdover])
        mono = [0.0]
        w = W.Writer(self.archive, 1 << 30, status_path=self.status, clock_ns=self.clock,
                     statvfs=self.statvfs, probe=lambda: [synced], source="test",
                     clock_probe=lambda: next(readings), monotonic=lambda: mono[0])
        w.begin("start test")
        join_threads("probe")
        w.tick()
        f = beast(0x32, 3, 3, SHORT)
        for _ in range(4):
            mono[0] += W.CLOCK_CHECK_S
            w.tick()                    # starts a check
            join_threads("clock-check")
            w.tick()                    # takes its result
            w.frame(self.clock.ns, f)   # and recording goes on
        self.assertIsNotNone(w.fh, "the writer must still be recording")
        w.write_status(force=True)
        with open(self.status) as fh:
            st = json.load(fh)
        self.assertEqual(st["clock"]["state"], "HOLDOVER")
        self.assertEqual(st["last_clock"], holdover)
        w.finish("SIGTERM")
        records, _ = extract.read_pcap(os.path.join(self.archive, self.files()[0]))
        clocks = [p.decode() for _, p in records if p.startswith(b"clock")]
        self.assertEqual(clocks, [synced, holdover], "one at the start, one on the change, none repeated")
        self.assertEqual(sum(1 for _, p in records if p[:1] == b"\x1a"), 4)
        self.assertIn(holdover, self.logs)

    def test_the_bound_crossing_the_bar_inside_holdover_is_a_change(self):
        # The state word, the reference and "none selected" stay the same; only the bound grows.
        def line(bound):
            return ("clock ref=C0000201 name=192.0.2.1 stratum=2 system_time_s=0.01 leap=Normal state=HOLDOVER"
                    f" ref_age_s=19800 bound_ms={bound} sources=2 selected=0 combined=0 reachable=2")
        readings = iter([line("480.000"), line("520.000"), line("530.000")])
        mono = [0.0]
        w = W.Writer(self.archive, 1 << 30, status_path=self.status, clock_ns=self.clock,
                     statvfs=self.statvfs, probe=lambda: [line("460.000")], source="test",
                     clock_probe=lambda: next(readings), monotonic=lambda: mono[0], max_offset_ms=500.0)
        w.begin("start test")
        join_threads("probe")
        w.tick()
        for _ in range(3):
            mono[0] += W.CLOCK_CHECK_S
            w.tick()
            join_threads("clock-check")
            w.tick()
        w.finish("SIGTERM")
        records, _ = extract.read_pcap(os.path.join(self.archive, self.files()[0]))
        bounds = [p.decode().split("bound_ms=")[1].split()[0] for _, p in records if p.startswith(b"clock")]
        self.assertEqual(bounds, ["460.000", "520.000"], "an event on crossing 500 ms, none for 480 or 530")
        # Without the bar (clock.conf absent), the same readings write no event after the start's.
        self.assertEqual(W.clock_key(line("480.000")), W.clock_key(line("520.000")))

    def test_a_flapping_chronyc_is_not_a_change_until_two_unavailable_in_a_row(self):
        synced = ("clock ref=C0000201 name=192.0.2.1 stratum=2 system_time_s=0.00 leap=Normal state=SYNCED"
                  " ref_age_s=5 bound_ms=15.000 sources=2 selected=1 combined=0 reachable=2")
        t_out, x_out = "clock unavailable reason=timeout", "clock unavailable reason=chronyc-exit-1"
        readings = iter([synced, t_out, synced, t_out, synced, t_out, x_out, t_out, synced])
        mono = [0.0]
        w = W.Writer(self.archive, 1 << 30, status_path=self.status, clock_ns=self.clock,
                     statvfs=self.statvfs, probe=lambda: [synced], source="test",
                     clock_probe=lambda: next(readings), monotonic=lambda: mono[0])
        w.begin("start test")
        join_threads("probe")
        w.tick()
        for _ in range(9):
            mono[0] += W.CLOCK_CHECK_S
            w.tick()
            join_threads("clock-check")
            w.tick()
            self.assertIsNotNone(w.fh, "never a reason to stop")
        w.finish("SIGTERM")
        records, _ = extract.read_pcap(os.path.join(self.archive, self.files()[0]))
        clocks = [p.decode() for _, p in records if p.startswith(b"clock")]
        # Single timeouts write nothing; the second unavailable in a row does, whatever its reason,
        # and the third adds nothing; the recovery is a change.
        self.assertEqual(clocks, [synced, x_out, synced])

    def test_read_max_offset_ms_from_clock_conf(self):
        conf = os.path.join(self.tmp.name, "clock.conf")
        self.assertIsNone(W.read_max_offset_ms(conf), "absent")
        for text, want in (("# c\nmax_offset_ms=500\nrequire_disciplined=true\nsource=gps\n", 500.0),
                           ("max_offset_ms=100.5\n", 100.5),
                           ("max_offset_ms=0\n", None), ("max_offset_ms=nan\n", None),
                           ("max_offset_ms=true\n", None), ("source=gps\n", None),
                           ("max_offset_ms=1_0\n", None), ("max_offset_ms= 5\n", None),
                           ("max_offset_ms=1e3\n", None), ("max_offset_ms=+5\n", None),
                           (b"max_offset_ms=\xff\n", None)):
            with self.subTest(text=text):
                with open(conf, "wb") as fh:
                    fh.write(text if isinstance(text, bytes) else text.encode())
                self.assertEqual(W.read_max_offset_ms(conf), want)

    def test_extract_counts_a_clock_event_by_its_first_word(self):
        w = self.make()
        w.begin("start test")
        w.event("clock ref=C0000201 state=HOLDOVER ref_age_s=2400 bound_ms=60.000 sources=2 selected=0")
        w.finish("SIGTERM")
        out = io.StringIO()
        extract.check(os.path.join(self.archive, self.files()[0]), out=out)
        self.assertIn("  events: clock 1, start 1, stop 1", out.getvalue())


class RaceTest(WriterTestBase):
    """A live pull moves files and removes empty date directories while the writer runs (PLAN
    §9m's four races): each is tolerated."""

    def patch(self, obj, name, fn):
        real = getattr(obj, name)
        setattr(obj, name, fn)
        self.addCleanup(setattr, obj, name, real)
        return real

    def test_close_file_survives_the_file_moved_after_its_rename(self):
        real = W.link_noclobber
        moved = os.path.join(self.tmp.name, "moved")

        def link_then_move(*a):
            final = real(*a)
            os.rename(final, moved)  # rsync took it at once
            return final
        self.patch(W, "link_noclobber", link_then_move)
        w = self.make()
        w.begin("start test")
        w.finish("SIGTERM")
        self.assertTrue(os.path.exists(moved))
        self.assertTrue([m for m in self.logs if m.startswith("closed ") and m.endswith(" bytes")], self.logs)

    def test_closed_files_skips_a_date_directory_removed_after_its_test(self):
        gone = os.path.join(self.archive, "2026-10-01")
        os.mkdir(gone)
        os.makedirs(os.path.join(self.archive, "2026-10-02"))
        open(os.path.join(self.archive, "2026-10-02/20261002T000000Z.beast.pcap"), "wb").close()
        real = self.patch(W.os, "listdir", None)

        def listdir(p):
            if p == gone and os.path.isdir(gone):
                os.rmdir(gone)  # the prune, between isdir() and listdir()
            return real(p)
        W.os.listdir = listdir
        found = self.make().closed_files()
        self.assertEqual([c[1] for c in found], ["20261002T000000Z.beast.pcap"])

    def test_open_file_makes_its_directory_again_if_removed_before_the_open(self):
        real = self.patch(W.os, "open", None)
        removed = []

        def open_(path, *a, **kw):
            if path.endswith(".part") and not removed:
                os.rmdir(os.path.dirname(path))  # the prune, between makedirs() and open()
                removed.append(path)
            return real(path, *a, **kw)
        W.os.open = open_
        w = self.make()
        w.begin("start test")
        self.assertEqual(len(removed), 1)
        self.assertEqual(self.files(), ["2026-10-04/20261004T120317Z.beast.pcap.part"])
        w.finish("SIGTERM")


class StepBackTest(WriterTestBase):
    def test_a_clock_stepped_back_mid_file_rotates_into_an_earlier_name_and_clobbers_nothing(self):
        w = self.make()
        w.begin("start test")
        f = beast(0x32, 3, 3, SHORT)
        w.frame(self.clock.ns, f)
        self.clock.ns = utc_ns(2026, 10, 4, 12, 10, 0, 100_000_000)
        w.rotate()
        w.frame(self.clock.ns, f)
        # chrony steps the clock back into the first file's interval, to its very second.
        self.clock.ns = utc_ns(2026, 10, 4, 12, 3, 17, 500_000_000)
        self.assertTrue(w.due(self.clock.ns), "an earlier interval is a different interval")
        w.rotate()
        w.frame(self.clock.ns, f)
        w.finish("SIGTERM")
        self.assertEqual(self.files(), ["2026-10-04/20261004T120317Z.1.beast.pcap",
                                        "2026-10-04/20261004T120317Z.beast.pcap",
                                        "2026-10-04/20261004T121000Z.beast.pcap"])
        first, _ = extract.read_pcap(os.path.join(self.archive, "2026-10-04/20261004T120317Z.beast.pcap"))
        self.assertEqual([p for _, p in first], [b"start test", f])
        third, _ = extract.read_pcap(os.path.join(self.archive, "2026-10-04/20261004T120317Z.1.beast.pcap"))
        self.assertEqual([p for _, p in third], [f, b"stop reason=SIGTERM"])


class ProbeTest(unittest.TestCase):
    def fake_gpsd(self, lines):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)

        def serve():
            c, _ = srv.accept()
            c.sendall(b'{"class":"VERSION"}\n')
            c.recv(100)
            for line in lines:
                c.sendall(line + b"\n")
            c.close()
            srv.close()
        threading.Thread(target=serve, daemon=True).start()
        return srv.getsockname()

    def test_first_tpv_with_a_fix(self):
        addr = self.fake_gpsd([b'{"class":"TPV","mode":1}',
                               b'{"class":"TPV","mode":3,"lat":10.5,"lon":20.5,"altMSL":100.0,'
                               b'"time":"2026-10-04T12:00:00.000Z"}'])
        self.assertEqual(W.probe_position(addr, 3),
                         "position 10.5 20.5 100.0 3 2026-10-04T12:00:00.000Z")

    def test_no_fix(self):
        addr = self.fake_gpsd([b'{"class":"TPV","mode":1}'])
        self.assertEqual(W.probe_position(addr, 3), "position unavailable reason=eof")

    def test_refused(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        addr = s.getsockname()
        s.close()
        self.assertEqual(W.probe_position(addr, 1), "position unavailable reason=refused")


if __name__ == "__main__":
    unittest.main()
