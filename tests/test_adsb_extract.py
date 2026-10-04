# SPDX-License-Identifier: Apache-2.0
#
# tools/adsb-extract, on files written by bin/adsb-writer from synthesized frames.

import io
import os
import tempfile
import types
import unittest

from _load import FakeClock, beast, extract, utc_ns, writer as W

SHORT = bytes([0x5D, 1, 2, 3, 4, 5, 6])


class ExtractTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.archive = self.tmp.name
        self.clock = FakeClock(utc_ns(2026, 10, 4, 12, 3, 17))
        self.real_log = W.log
        W.log = lambda _msg: None

    def tearDown(self):
        W.log = self.real_log
        self.tmp.cleanup()

    def writer(self):
        return W.Writer(self.archive, 0, clock_ns=self.clock,
                        statvfs=lambda _p: types.SimpleNamespace(f_bavail=1, f_frsize=1))

    def paths(self):
        out = []
        for d, _, names in os.walk(self.archive):
            out += [os.path.join(d, n) for n in names]
        return sorted(out)

    def record_minute(self, w, start_ns, ppm=-25.0, counter0=12_000_000):
        """One frame every 0.1 s for 60 s; the counter runs ppm off 12 MHz."""
        for i in range(600):
            t = start_ns + i * 100_000_000
            counter = counter0 + round(i * 0.1 * 12_000_000 * (1 + ppm * 1e-6))
            if w.due(t):
                self.clock.ns = t
                w.rotate()
            w.frame(t, beast(0x32, counter, 30, SHORT))

    def test_torn_tail_stops_at_the_last_complete_record(self):
        w = self.writer()
        w.begin("start test")
        for i in range(10):
            w.frame(self.clock.ns + i, beast(0x32, 100 + i, 1, SHORT))
        w.close_file()
        path = self.paths()[0]
        whole, note = extract.read_pcap(path)
        self.assertIsNone(note)
        torn = path.replace(".beast.pcap", ".beast.pcap.torn")
        with open(path, "rb") as fh:
            data = fh.read()
        for cut in (len(data) - 3, len(data) - 20):
            with open(torn, "wb") as fh:
                fh.write(data[:cut])
            recs, note = extract.read_pcap(torn)
            self.assertTrue(note.startswith("torn"), note)
            self.assertEqual(recs, whole[:len(recs)])
            self.assertEqual(len(recs), len(whole) - 1)
        with open(torn, "wb") as fh:
            fh.write(data + b"\x00" * 64)  # a zeroed tail
        recs, note = extract.read_pcap(torn)
        self.assertEqual(recs, whole)
        self.assertTrue(note.startswith("torn"))

    def test_window_across_a_rotation(self):
        w = self.writer()
        w.begin("start test")
        self.record_minute(w, utc_ns(2026, 10, 4, 12, 9, 30))
        w.finish("SIGTERM")
        self.assertEqual(len(self.paths()), 2)
        out = io.StringIO()
        beast_out = io.BytesIO()
        frames, events = extract.extract(self.archive, utc_ns(2026, 10, 4, 12, 10, 0), 5, out, beast_out)
        self.assertEqual(frames, 101)  # 11:55.0 .. 12:05.0 inclusive, at 10 per second
        rows = out.getvalue().splitlines()
        self.assertEqual(rows[0].split(",")[:3], ["wall_time_utc", "kind", "beast_type"])
        self.assertTrue(rows[1].startswith("2026-10-04T12:09:55.000000000Z,frame,0x32,"))
        items = W.BeastParser().feed(beast_out.getvalue())
        self.assertEqual(len(items), 101)

    def test_check_fits_the_counter(self):
        w = self.writer()
        w.begin("start test")
        self.record_minute(w, utc_ns(2026, 10, 4, 12, 3, 20))
        self.record_minute(w, utc_ns(2026, 10, 4, 12, 4, 30), ppm=-25.0, counter0=5)  # readsb restarted
        w.finish("SIGTERM")
        out = io.StringIO()
        extract.check(self.paths()[0], out)
        text = out.getvalue()
        self.assertIn("segment 1: 600 frames", text)
        self.assertIn("segment 2: 600 frames", text)
        self.assertIn("-25.0 ppm", text)

    def test_check_drops_only_all_zero_keepalives(self):
        w = self.writer()
        w.begin("start test")
        t = utc_ns(2026, 10, 4, 12, 3, 20)
        for i in range(5):  # as seen on the Pi: all-zero 0x31 frames
            w.frame(t + i * 6_000_000_000, beast(0x31, 0, 0, b"\x00\x00"))
        w.frame(t, beast(0x31, 0, 0, b"\x12\x34"))   # counter 0 but data: not a keepalive
        w.frame(t, beast(0x32, 0, 30, SHORT))        # counter 0 on a Mode S frame
        self.record_minute(w, t)
        w.finish("SIGTERM")
        out = io.StringIO()
        extract.check(self.paths()[0], out)
        text = out.getvalue()
        self.assertIn("keepalives (all-zero 0x31), not fitted: 5", text)
        self.assertIn("counter 0, not a keepalive, not fitted: 2", text)
        self.assertIn("segment 1: 600 frames", text)
        self.assertNotIn("segment 2", text)

    def test_check_with_keepalives_only(self):
        w = self.writer()
        w.begin("start test")
        w.frame(self.clock.ns, beast(0x31, 0, 0, b"\x00\x00"))
        w.finish("SIGTERM")
        out = io.StringIO()
        extract.check(self.paths()[0], out)
        text = out.getvalue()
        self.assertIn("keepalives (all-zero 0x31), not fitted: 1", text)
        self.assertNotIn("not a keepalive", text)
        self.assertIn("nothing to fit", text)

    def test_candidates_include_the_file_before_the_window(self):
        files = [(utc_ns(2026, 10, 4, 12, 0, 0), "a"), (utc_ns(2026, 10, 4, 12, 0, 0), "a.torn"),
                 (utc_ns(2026, 10, 4, 12, 10, 0), "b"), (utc_ns(2026, 10, 4, 12, 20, 0), "c")]
        lo = utc_ns(2026, 10, 4, 12, 5, 0)
        self.assertEqual(extract.candidates(files, lo, lo + 60 * 10**9), ["a", "a.torn"])
        self.assertEqual(extract.candidates(files, lo, utc_ns(2026, 10, 4, 12, 10, 30)), ["a", "a.torn", "b"])

    def test_parse_utc(self):
        self.assertEqual(extract.parse_utc("2026-10-04T12:03:17.5Z"), utc_ns(2026, 10, 4, 12, 3, 17, 500_000_000))
        self.assertEqual(extract.parse_utc("2026-10-04T05:03:17-07:00"), utc_ns(2026, 10, 4, 12, 3, 17))


if __name__ == "__main__":
    unittest.main()
