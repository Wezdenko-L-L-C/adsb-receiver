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

    # --decode

    def test_crc24_known_answer(self):
        # A published DF17 (The 1090 Megahertz Riddle; AA 4840D6). Its parity
        # field is also the CRC of the first 88 bits, a second check of the same.
        msg = bytes.fromhex("8D4840D6202CC371C32CE0576098")
        self.assertEqual(extract.crc24(msg), 0)
        self.assertEqual(extract.crc24(msg[:11]), 0x576098)
        flipped = bytearray(msg)
        flipped[6] ^= 0x04
        self.assertNotEqual(extract.crc24(bytes(flipped)), 0)

    def decode_file(self, frames, torn=False):
        """One closed file holding these BEAST frames; returns (status, text)."""
        w = self.writer()
        w.begin("start test")
        for i, f in enumerate(frames):
            w.frame(self.clock.ns + i, f)
        w.finish("SIGTERM")
        path = self.paths()[0]
        if torn:
            with open(path, "rb") as fh:
                data = fh.read()
            os.remove(path)
            path = path.replace(".beast.pcap", ".beast.pcap.torn")
            with open(path, "wb") as fh:
                fh.write(data[:-3])
        out = io.StringIO()
        return extract.decode_files([path], out), out.getvalue()

    def test_decode_clean_file(self):
        frames = [beast(0x33, 1000 + i, 40, df17(aa)) for i, aa in enumerate([0x4840D6, 0xA1B2C3, 0x4840D6])]
        frames.append(beast(0x31, 0, 0, b"\x00\x00"))                       # a keepalive
        frames.append(beast(0x32, 2000, 30, SHORT))                          # a short frame
        frames.append(beast(0x33, 2001, 30, bytes([20 << 3]) + bytes(13)))  # DF20: long, not DF17/18
        status, text = self.decode_file(frames)
        self.assertEqual(status, 0, text)
        self.assertIn(": 8 records, 6 BEAST frames, 4 long, DF17/18 3/3 CRC-valid, 2 addresses; complete", text)
        self.assertNotIn("FAILS", text)
        self.assertNotIn("4840d6", text.lower())  # counts only, never an address
        self.assertIn("total: 1 file(s), 0 failing, 0 with no frames; DF17/18 3/3 CRC-valid; 2 distinct addresses", text)

    def test_decode_distinct_across_files(self):
        out = io.StringIO()
        paths = []
        for n, aas in enumerate([(0x4840D6, 0xA1B2C3), (0x4840D6, 0x3C6544)]):
            w = self.writer()
            w.begin("start test")
            for i, aa in enumerate(aas):
                w.frame(self.clock.ns + i, beast(0x33, 1000 + i, 40, df17(aa)))
            w.finish("SIGTERM")
            paths = self.paths()
            self.clock.ns += 600 * 10**9
        self.assertEqual(len(paths), 2)
        self.assertEqual(extract.decode_files(paths, out), 0)
        self.assertIn("DF17/18 4/4 CRC-valid; 3 distinct addresses across the set", out.getvalue())

    def test_decode_one_corrupted_frame_fails(self):
        bad = bytearray(df17(0xA1B2C3))
        bad[7] ^= 0x01
        frames = [beast(0x33, 1000, 40, df17(0x4840D6)), beast(0x33, 1001, 40, bytes(bad))]
        status, text = self.decode_file(frames)
        self.assertEqual(status, 1)
        self.assertIn("DF17/18 1/2 CRC-valid, 1 addresses", text)
        self.assertIn("!! FAILS: 1 CRC-invalid DF17/18 frame(s)", text)

    def test_decode_torn_file_fails(self):
        frames = [beast(0x33, 1000 + i, 40, df17(0x4840D6)) for i in range(5)]
        status, text = self.decode_file(frames, torn=True)
        self.assertEqual(status, 1)
        self.assertIn("!! FAILS: torn: ", text)

    def test_decode_events_only_or_keepalives_only_warns(self):
        # (Chris), 2026-10-10: a warning with the events, exit 0, not a failure.
        status, text = self.decode_file([])
        self.assertEqual(status, 0, text)
        self.assertIn("!! no frames: events: start 1, stop 1\n", text)
        self.assertNotIn("FAILS", text)
        self.assertIn("total: 1 file(s), 0 failing, 1 with no frames;", text)
        for p in self.paths():
            os.remove(p)
        status, text = self.decode_file([beast(0x31, 0, 0, b"\x00\x00")] * 3)
        self.assertEqual(status, 0, text)
        self.assertIn("3 BEAST frames, 0 long", text)
        self.assertIn("!! no frames: events: start 1, stop 1; keepalives (all-zero 0x31) 3", text)
        self.assertNotIn("FAILS", text)

    def test_decode_zero_records_fails(self):
        self.decode_file([])
        path = self.paths()[0]
        with open(path, "rb") as fh:
            header = fh.read(24)
        with open(path, "wb") as fh:
            fh.write(header)  # a pcap header and nothing after it: complete, but empty
        out = io.StringIO()
        self.assertEqual(extract.decode_files([path], out), 1)
        self.assertIn(": 0 records,", out.getvalue())
        self.assertIn("!! FAILS: no records", out.getvalue())
        self.assertNotIn("!! no frames", out.getvalue())

    def test_decode_frames_but_no_valid_df1718_fails(self):
        status, text = self.decode_file([beast(0x32, 1000 + i, 30, SHORT) for i in range(4)])
        self.assertEqual(status, 1)
        self.assertIn("4 BEAST frames, 0 long, DF17/18 0/0 CRC-valid", text)
        self.assertIn("!! FAILS: no CRC-valid DF17/18 frames", text)
        self.assertNotIn("!! no frames", text)

    def test_decode_malformed_frame_fails_without_a_crash(self):
        # 9 bytes as stored, but 0x1a 0x1a pairs leave 5 after the type once
        # unescaped: under the counter and signal byte.
        short = b"\x1a\x33" + b"\x1a\x1a" * 2 + b"\x00\x00\x00"
        self.assertGreaterEqual(len(short), 9)
        status, text = self.decode_file([beast(0x33, 1000, 40, df17(0x4840D6)), short, b"\x1a"])
        self.assertEqual(status, 1)
        self.assertIn("3 BEAST frames, 1 long, DF17/18 1/1 CRC-valid", text)
        self.assertIn("!! FAILS: 2 malformed frame(s)", text)

    def test_decode_unreadable_file_fails_and_the_rest_go_on(self):
        status, _ = self.decode_file([beast(0x33, 1000, 40, df17(0x4840D6))])
        self.assertEqual(status, 0)
        good = self.paths()[0]
        gone = os.path.join(self.archive, "20261004T130000Z.beast.pcap")
        out = io.StringIO()
        self.assertEqual(extract.decode_files([gone, good], out), 1)
        text = out.getvalue()
        self.assertIn(f"{gone}: unreadable\n  !! FAILS: unreadable: ", text)
        self.assertIn(f"{good}: 3 records, 1 BEAST frames", text)
        self.assertIn("total: 2 file(s), 1 failing, 0 with no frames; DF17/18 1/1 CRC-valid; 1 distinct", text)

    def test_decode_unescapes_before_the_crc(self):
        msg = df17(0x1A2B1A)
        self.assertIn(0x1A, msg)
        raw = beast(0x33, 1000, 40, msg)
        self.assertIn(b"\x1a\x1a", raw[2:])  # escaped as on the wire
        status, text = self.decode_file([raw])
        self.assertEqual(status, 0, text)
        self.assertIn("DF17/18 1/1 CRC-valid, 1 addresses", text)

    def test_decode_and_check_exclude_each_other_and_dir_time(self):
        import contextlib
        for argv in (["--decode", "a", "--check", "b"], ["d", "2026-10-04T12:00:00Z", "--decode", "a"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
                extract.main(argv)
            self.assertEqual(cm.exception.code, 2, argv)


def df17(aa, me=bytes.fromhex("202CC371C32CE0")):
    """A DF17 (CA 5) from this address, its parity computed: 14 bytes."""
    head = bytes([0x8D]) + aa.to_bytes(3, "big") + me
    return head + extract.crc24(head).to_bytes(3, "big")


if __name__ == "__main__":
    unittest.main()
