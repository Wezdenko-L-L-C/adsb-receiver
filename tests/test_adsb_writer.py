# SPDX-License-Identifier: Apache-2.0
#
# bin/adsb-writer, on synthesized BEAST streams. ⛔ No real capture is
# committed: every byte here is built by the tests.

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
