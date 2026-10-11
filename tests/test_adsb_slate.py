# SPDX-License-Identifier: Apache-2.0
#
# bin/adsb-slate, the field display: its pure parts. Parsing chronyc's CSV,
# gpsd's TPV and SKY, readsb's aircraft.json; the big digits' width; the
# tenths' truncation; the screen diff; and the rule that the position never
# reaches stderr. No console, gpsd, chrony or readsb is needed.
# ⛔ Every position here is made up. None is a real place of the rigs.

import contextlib
import io
import json
import re
import tempfile
import time
import unittest

from _load import load, utc_ns

S = load("bin/adsb-slate", "adsb_slate")

# Made-up coordinates, one decimal each, as tests/test_adsb_writer.py does: the
# repo's pre-commit guard refuses anything that looks like a real position.
# Unusual values, so the stderr tests below cannot pass or fail by accident:
# nothing this program logs holds "71.5", and they assert on each value and
# on the pair as the slate prints it.
FAKE_LAT = "-71.5"
FAKE_LON = "171.5"

# NOW below, in epoch seconds: chrony's last update is 5 s before it.
NOW_NS = utc_ns(2026, 10, 10, 18, 0, 1, 400_000_000)
NOW_S = NOW_NS / 1e9


def csv_line(fields):
    """One line of chronyc -c output. Built from a list, one field per source
    line: the pre-commit guard reads two decimals around a comma as a position."""
    return ",".join(fields) + "\n"


def chrony(ref_time=NOW_S - 5, offset="-0.000004200", root_delay="0.000000001",
           root_disp="0.000020000", interval="16.0", leap="Normal"):
    return csv_line([
        "47505300",            # 0 ref id
        "GPS",                 # 1 ref name
        "1",                   # 2 stratum
        f"{ref_time:.9f}",     # 3 ref time
        offset,                # 4 system time (negative: fast)
        "0.000001100",         # 5 last offset
        "0.000002300",         # 6 RMS offset
        "-12.345",             # 7 frequency
        "0.001",               # 8 residual frequency
        "0.010",               # 9 skew
        root_delay,            # 10 root delay
        root_disp,             # 11 root dispersion
        interval,              # 12 update interval
        leap,                  # 13 leap status
    ])


CHRONY_SYNCED = chrony()
CHRONY_UNSYNCED = csv_line(
    ["00000000", "", "0"]                  # ref id, no ref name, stratum 0
    + ["0.000000000"] * 4                  # ref time, system time, last and RMS offset
    + ["0.000"] * 3                        # frequency, residual frequency, skew
    + ["1.000000000"] * 2                  # root delay, root dispersion
    + ["0.0", "Not synchronised"])         # update interval, leap status


def tpv(mode=3, t="2026-10-10T18:00:00.000Z", lat=FAKE_LAT, lon=FAKE_LON, alt="321.5"):
    # Written as gpsd writes it: numbers unquoted.
    parts = [f'"class":"TPV","mode":{mode}']
    if t is not None:
        parts.append(f'"time":"{t}"')
    if lat is not None:
        parts.append(f'"lat":{lat},"lon":{lon},"altMSL":{alt}')
    return ("{" + ",".join(parts) + "}").encode()


def state(text, fresh=True, now=NOW_S):
    return S.clock_state(S.parse_tracking(text), fresh, now)


class Tracking(unittest.TestCase):
    def test_synced(self):
        t = S.parse_tracking(CHRONY_SYNCED)
        self.assertTrue(t["synced"])
        self.assertEqual(t["ref"], "GPS")
        self.assertAlmostEqual(t["offset_s"], -4.2e-6)
        # chronyc(1): |offset| + root dispersion + root delay / 2.
        self.assertAlmostEqual(t["bound_s"], 4.2e-6 + 2e-5 + 0.5e-9)
        self.assertEqual(state(CHRONY_SYNCED),
                         ("SYNCED", "SYNCED GPS   error <= 0.024 ms   system clock 0.004 ms fast"))

    def test_offset_sign_is_a_word(self):
        # Negative CSV system time is a FAST clock (seen on the portable, 2026-10-10).
        self.assertEqual(S.offset_words(-0.001049242), "1.049 ms fast")
        self.assertEqual(S.offset_words(0.0021), "2.100 ms slow")
        self.assertNotIn("-", state(CHRONY_SYNCED)[1].split("system clock")[1])

    def test_unsynchronised(self):
        t = S.parse_tracking(CHRONY_UNSYNCED)
        self.assertFalse(t["synced"])
        self.assertEqual(S.clock_state(t, True, NOW_S), ("UNSYNCED", "UNSYNCED"))

    def test_a_large_error_bound_is_coarse_not_synced(self):
        # An NTP server over Wi-Fi: 40 ms of root delay, 10 ms of dispersion.
        st, text = state(chrony(root_delay="0.040000000", root_disp="0.010000000",
                                interval="1044.3"))
        self.assertEqual(st, "COARSE")
        self.assertIn("error <= 30.004 ms", text)
        # Just inside the 20 ms bound is still synced.
        self.assertEqual(state(chrony(root_disp="0.019000000"))[0], "SYNCED")

    def test_a_stale_update_is_holdover(self):
        # 16 s interval: past 2 x 16 + 64 = 96 s since the last update.
        self.assertEqual(state(chrony(ref_time=NOW_S - 95))[0], "SYNCED")
        st, text = state(chrony(ref_time=NOW_S - 300))
        self.assertEqual(st, "HOLDOVER")
        self.assertIn("last update 300 s ago", text)
        # A long interval (NTP over Wi-Fi, 1044.3 s seen) is not holdover at 1000 s.
        self.assertNotEqual(state(chrony(ref_time=NOW_S - 1000, interval="1044.3"))[0], "HOLDOVER")

    def test_unparsed_or_stale_is_a_word(self):
        self.assertIsNone(S.parse_tracking(""))
        self.assertIsNone(S.parse_tracking("506 Cannot talk to daemon\n"))
        self.assertIsNone(S.parse_tracking(chrony(offset="nan?")))
        self.assertEqual(S.clock_state(None, True, NOW_S), ("CHRONY?", "CHRONY?"))
        # A synced reading that is no longer fresh is not shown as current.
        self.assertEqual(state(CHRONY_SYNCED, fresh=False)[0], "CHRONY?")

    def test_non_finite_values_are_unparsed_not_synced(self):
        # float() takes these; a NaN bound would pass every threshold test.
        for bad in ({"root_disp": "nan"}, {"root_delay": "inf"}, {"offset": "-inf"},
                    {"interval": "NaN"}, {"ref_time": float("nan")}):
            kw = dict(bad)
            if "ref_time" in kw:
                text = chrony().replace(f"{NOW_S - 5:.9f}", "nan", 1)
            else:
                text = chrony(**kw)
            self.assertIsNone(S.parse_tracking(text), bad)
            self.assertEqual(state(text)[0], "CHRONY?", bad)

    def test_ref_name_cannot_carry_an_escape(self):
        self.assertNotIn("\x1b", state(CHRONY_SYNCED.replace(",GPS,", ",\x1b[2J,", 1))[1])


class Gpsd(unittest.TestCase):
    def test_tpv_keeps_trailing_zeros(self):
        # A float would print this as -71.5: kept as text, nothing is rounded.
        kept = "-71.50000"
        _, info = S.parse_gpsd_line(tpv(lat=kept, lon=kept))
        self.assertEqual(info["lat"], kept)

    def test_tpv_keeps_the_text_gpsd_sent(self):
        kind, info = S.parse_gpsd_line(tpv())
        self.assertEqual(kind, "TPV")
        self.assertEqual(info["mode"], 3)
        # Exact: the digits as sent, not a float's rounding of them.
        self.assertEqual((info["lat"], info["lon"], info["alt"]), (FAKE_LAT, FAKE_LON, "321.5"))
        self.assertEqual(info["time"], utc_ns(2026, 10, 10, 18, 0, 0) / 1e9)

    def test_tpv_no_fix(self):
        kind, info = S.parse_gpsd_line(tpv(mode=1, lat=None))
        self.assertEqual((kind, info["mode"], info["lat"]), ("TPV", 1, None))
        self.assertEqual(S.fix_word(1), "NO FIX")
        self.assertEqual(S.fix_word(0), "NO FIX")
        self.assertEqual(S.fix_word(2), "2D FIX")
        self.assertEqual(S.fix_word(3), "3D FIX")

    def test_sky_usat_or_count_of_used(self):
        self.assertEqual(S.parse_gpsd_line(b'{"class":"SKY","uSat":7,"nSat":12}'),
                         ("SKY", {"used": 7, "seen": 12}))
        sats = [{"PRN": i, "used": i % 3 == 0} for i in range(1, 10)]
        line = json.dumps({"class": "SKY", "satellites": sats}).encode()
        self.assertEqual(S.parse_gpsd_line(line), ("SKY", {"used": 3, "seen": 9}))
        # A SKY with neither count does not replace the last one.
        self.assertIsNone(S.parse_gpsd_line(b'{"class":"SKY","hdop":1.2}'))

    def test_numbers_are_matched_whole(self):
        self.assertEqual(S.num_text("12.5"), "12.5")
        for bad in ("1\n", "12.5\n", " 1", "1 ", "nan", "Infinity", float("nan"), float("inf"), True):
            self.assertIsNone(S.num_text(bad), repr(bad))
        self.assertIsNone(S.parse_iso_utc("2026-10-10T18:00:00Z\n"))
        self.assertIsNotNone(S.parse_iso_utc("2026-10-10T18:00:00Z"))

    def test_nan_position_is_no_position(self):
        # json reads the NaN literal as a float, whatever parse_float says.
        _, info = S.parse_gpsd_line(b'{"class":"TPV","mode":3,"lat":NaN,"lon":Infinity}')
        self.assertEqual((info["lat"], info["lon"]), (None, None))

    def test_other_lines_are_ignored(self):
        for line in (b'{"class":"VERSION","release":"3.25"}', b"not json", b"[1,2]", b""):
            self.assertIsNone(S.parse_gpsd_line(line))


class StatusLines(unittest.TestCase):
    NOW = NOW_NS
    LOCAL = time.struct_time((2026, 10, 10, 11, 0, 1, 5, 283, 0))

    def snap(self, **kw):
        s = {"gpsd_connected": True, "tpv": S.parse_gpsd_line(tpv())[1], "tpv_fresh": True,
             "sky": {"used": 9, "seen": 14}, "sky_fresh": True,
             "tracking": S.parse_tracking(CHRONY_SYNCED), "tracking_fresh": True,
             "aircraft": (4, self.NOW / 1e9 - 0.5)}
        s.update(kw)
        return s

    def test_all_sources_present(self):
        lines = S.status_lines(self.NOW, self.snap(), self.LOCAL)
        self.assertEqual(lines[1], "CLOCK SYNCED GPS   error <= 0.024 ms   system clock 0.004 ms fast")
        self.assertEqual(lines[2], "GPS 3D FIX   SATS 9 used of 14   FIX AGE 1.4 s")
        self.assertEqual(lines[3], f"POS {FAKE_LAT} {FAKE_LON}   ALT 321.5 m")
        self.assertEqual(lines[4], "AIRCRAFT 4 heard in the last 60 s")

    def test_missing_and_stale_sources_are_words(self):
        lines = S.status_lines(self.NOW, self.snap(gpsd_connected=False, aircraft="missing",
                                                   tracking=None), self.LOCAL)
        self.assertEqual(lines[1:], ["CLOCK CHRONY?", "GPS NO GPSD", "POS NO GPSD",
                                     "AIRCRAFT NO READSB"])
        lines = S.status_lines(self.NOW, self.snap(tpv_fresh=False, tracking_fresh=False,
                                                   aircraft=(4, self.NOW / 1e9 - 30)), self.LOCAL)
        self.assertEqual(lines[1], "CLOCK CHRONY?")
        self.assertTrue(lines[2].startswith("GPS STALE"))
        self.assertNotIn(FAKE_LAT, " ".join(lines))
        self.assertEqual(lines[4], "AIRCRAFT READSB STALE")

    def test_fix_age_is_a_word_when_a_number_would_mislead(self):
        unsynced = S.parse_tracking(CHRONY_UNSYNCED)
        lines = S.status_lines(self.NOW, self.snap(tracking=unsynced), self.LOCAL)
        self.assertTrue(lines[2].endswith("FIX AGE ? (clock unsynced)"), lines[2])
        lines = S.status_lines(self.NOW, self.snap(tracking_fresh=False), self.LOCAL)
        self.assertTrue(lines[2].endswith("FIX AGE ? (clock unknown)"), lines[2])
        ahead = S.parse_gpsd_line(tpv(t="2026-10-10T18:00:05.000Z"))[1]
        lines = S.status_lines(self.NOW, self.snap(tpv=ahead), self.LOCAL)
        self.assertTrue(lines[2].endswith("FIX AGE ? (fix after clock)"), lines[2])
        old = S.parse_gpsd_line(tpv(t="2026-10-10T17:50:00.000Z"))[1]
        lines = S.status_lines(self.NOW, self.snap(tpv=old), self.LOCAL)
        self.assertTrue(lines[2].endswith("FIX AGE ? (implausible)"), lines[2])
        # Holdover and coarse still bound the clock: the age is a number.
        hold = S.parse_tracking(chrony(ref_time=NOW_S - 300))
        lines = S.status_lines(self.NOW, self.snap(tracking=hold), self.LOCAL)
        self.assertTrue(lines[2].endswith("FIX AGE 1.4 s"), lines[2])

    def test_readsb_words(self):
        lines = S.status_lines(self.NOW, self.snap(aircraft="unreadable"), self.LOCAL)
        self.assertTrue(lines[4].startswith("AIRCRAFT READSB UNREADABLE"), lines[4])
        # A `now` ahead of the system clock is not current either.
        lines = S.status_lines(self.NOW, self.snap(aircraft=(4, self.NOW / 1e9 + 10)), self.LOCAL)
        self.assertTrue(lines[4].startswith("AIRCRAFT READSB ?"), lines[4])
        lines = S.status_lines(self.NOW, self.snap(aircraft=(4, self.NOW / 1e9 + 1)), self.LOCAL)
        self.assertEqual(lines[4], "AIRCRAFT 4 heard in the last 60 s")

    def test_no_fix_shows_no_position(self):
        snap = self.snap(tpv=S.parse_gpsd_line(tpv(mode=1, lat=None))[1], sky_fresh=False)
        lines = S.status_lines(self.NOW, snap, self.LOCAL)
        self.assertEqual(lines[2], "GPS NO FIX   SATS ?   FIX AGE -")
        self.assertEqual(lines[3], "POS NO FIX")


class Aircraft(unittest.TestCase):
    def test_counts_only_the_last_60_s(self):
        obj = {"now": 1760140000.5, "messages": 10, "aircraft": [
            {"hex": "abc001", "seen": 0.4},
            {"hex": "abc002", "seen": 59.9},
            {"hex": "abc003", "seen": 60.1},     # stale: not counted
            {"hex": "abc004", "seen": 250},      # stale
            {"hex": "abc005"},                   # no seen: not counted
        ]}
        self.assertEqual(S.count_aircraft(obj), (2, 1760140000.5))

    def test_non_finite_numbers(self):
        self.assertIsNone(S.count_aircraft({"now": float("nan"), "aircraft": []}))
        self.assertIsNone(S.count_aircraft({"now": float("inf"), "aircraft": []}))
        obj = {"now": 1.0, "aircraft": [{"seen": float("nan")}, {"seen": float("-inf")}, {"seen": 1}]}
        self.assertEqual(S.count_aircraft(obj), (1, 1.0))

    def test_unreadable_is_its_own_word_and_logs_the_type_once(self):
        with tempfile.TemporaryDirectory() as d:   # a directory cannot be read as a file
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                self.assertEqual(S.read_aircraft(d), "unreadable")
                self.assertEqual(S.read_aircraft(d), "unreadable")
            self.assertEqual(err.getvalue().count("IsADirectoryError"), 1)

    def test_not_aircraft_json(self):
        self.assertIsNone(S.count_aircraft([]))
        self.assertIsNone(S.count_aircraft({"aircraft": []}))
        self.assertEqual(S.read_aircraft("/nonexistent/aircraft.json"), "missing")


class Timing(unittest.TestCase):
    def test_tenths_truncate_never_round(self):
        base = utc_ns(2026, 10, 10, 23, 59, 59)
        self.assertEqual(S.format_utc(base), "2026-10-10 23:59:59.0")
        self.assertEqual(S.format_utc(base + 99_999_999), "2026-10-10 23:59:59.0")
        self.assertEqual(S.format_utc(base + 100_000_000), "2026-10-10 23:59:59.1")
        # 0.9999999 s must not show the next second, nor .10.
        self.assertEqual(S.format_utc(base + 999_999_999), "2026-10-10 23:59:59.9")
        self.assertEqual(S.format_utc(base + 1_000_000_000), "2026-10-11 00:00:00.0")
        self.assertEqual(S.big_clock_text(base + 950_000_000), "23:59:59.9")

    def test_next_tick_is_the_next_100ms_boundary(self):
        base = utc_ns(2026, 10, 10, 0, 0, 0)
        self.assertAlmostEqual(S.next_tick_delay(base + 30_000_000), 0.07)
        self.assertAlmostEqual(S.next_tick_delay(base + 99_999_999), 1e-9)
        self.assertAlmostEqual(S.next_tick_delay(base), 0.1)
        for off in range(0, 300_000_000, 7_000_001):
            d = S.next_tick_delay(base + off)
            self.assertTrue(0 < d <= 0.1)
            self.assertEqual((base + off + round(d * 1e9)) % S.TICK_NS, 0)


class BigDigits(unittest.TestCase):
    def test_width_per_column_count(self):
        self.assertEqual(S.CLOCK_UNITS, 47)
        for cols, rows, sx in ((120, 33, 2), (80, 25, 1), (64, 24, 1), (240, 67, 5), (48, 25, 0)):
            p = S.plan(cols, rows)
            self.assertEqual(p["sx"], sx, f"{cols}x{rows}")
            rendered = S.time_rows(utc_ns(2026, 10, 10, 12, 34, 56, 700_000_000), p)
            for r, text in rendered.items():
                self.assertEqual(len(text), cols, f"{cols}x{rows} row {r}")
                self.assertLess(r, rows - 1, "the last row stays empty")
            if sx:
                big = S.render_big("12:34:56.7", p["sx"], p["sy"])
                self.assertEqual({len(x) for x in big}, {47 * sx})
                self.assertEqual(len(big), 7 * p["sy"])
                self.assertLessEqual(47 * sx, cols - 2)
                # Every big row is in the frame, at the computed place.
                self.assertIn(" " * p["big_left"] + big[0], rendered[p["big_top"]])

    def test_status_fits_below_the_digits(self):
        for cols, rows in ((120, 33), (80, 25), (240, 67)):
            p = S.plan(cols, rows)
            self.assertLessEqual(p["status_top"] + 5, rows - 1)

    def test_utc_line_is_the_one_verify_reads(self):
        p = S.plan(120, 33)
        rows = S.time_rows(utc_ns(2026, 10, 10, 12, 34, 56, 700_000_000), p)
        self.assertEqual(rows[p["utc_row"]].strip(), "UTC 2026-10-10 12:34:56.7")


class Repaint(unittest.TestCase):
    def frame(self, p, ns):
        f = S.blank_rows(p)
        f.update(S.time_rows(ns, p))
        return f

    def test_the_repaint_covers_every_row(self):
        p = S.plan(80, 25)
        out = S.repaint(self.frame(p, NOW_NS), p)
        # Rows 1 to 24 (1-based) are each written from column 1, blank or not ...
        written = sorted(int(r) for r in re.findall(r"\x1b\[(\d+);1H", out))
        self.assertEqual(written, list(range(1, 26)))
        # ... and row 25, the last, is only erased in place: nothing follows the erase.
        self.assertTrue(out.endswith("\x1b[25;1H\x1b[2K"))
        self.assertEqual(out.count("\x1b[25;1H"), 1)

    def test_a_tick_does_not_touch_the_blank_rows(self):
        p = S.plan(80, 25)
        a = self.frame(p, NOW_NS)
        b = self.frame(p, NOW_NS + S.TICK_NS)
        rows = {int(r) - 1 for r in re.findall(r"\x1b\[(\d+);\d+H", S.diff(a, b))}
        self.assertTrue(rows)
        self.assertTrue(all(a[r].strip() for r in rows), rows)


class Diff(unittest.TestCase):
    def test_only_the_changed_span_is_written(self):
        old = {0: "abcdef", 1: "xxxxxx"}
        new = {0: "abcXef", 1: "xxxxxx"}
        self.assertEqual(S.diff(old, new), "\x1b[1;4HX")
        self.assertEqual(S.diff(new, new), "")

    def test_cells_are_reverse_video_spaces(self):
        out = S.diff({}, {2: "a" + S.PIX * 3 + "b"})
        self.assertEqual(out, "\x1b[3;1Ha\x1b[7m   \x1b[27mb")
        self.assertNotIn(S.PIX, out)


class PositionNeverOnStderr(unittest.TestCase):
    """⛔ The position goes to the screen only. Each error path below has the
    position within reach, and its stderr must not hold it."""

    def assert_clean(self, err):
        for needle in (FAKE_LAT, FAKE_LON, f"{FAKE_LAT} {FAKE_LON}", FAKE_LAT.lstrip("-")):
            self.assertNotIn(needle, err)

    def test_status_error_logs_the_type_only(self):
        snap = StatusLines.snap(StatusLines(), tpv={"mode": 3, "time": None, "lat": FAKE_LAT,
                                                     "lon": FAKE_LON, "alt": None})
        real = S.status_lines

        def boom(*_a, **_k):
            raise ValueError(f"bad position {FAKE_LAT} {FAKE_LON}")
        S.status_lines = boom
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                rows = S.status_rows(StatusLines.NOW, snap, S.plan(120, 33))
        finally:
            S.status_lines = real
        self.assertIn("ValueError", err.getvalue())
        self.assert_clean(err.getvalue())
        self.assertIn("STATUS ERROR", " ".join(rows.values()))

    def test_hooks_print_no_message(self):
        err = io.StringIO()
        exc = RuntimeError(f"lat {FAKE_LAT} lon {FAKE_LON}")
        with contextlib.redirect_stderr(err):
            S.excepthook(RuntimeError, exc, None)
            S.log_error("x", exc)

            class Args:
                exc_type = RuntimeError
                exc_value = exc
                thread = type("T", (), {"name": "gpsd"})()
            S.thread_excepthook(Args)
        self.assertIn("RuntimeError", err.getvalue())
        self.assert_clean(err.getvalue())

    def test_gpsd_lines_log_nothing(self):
        src = S.Sources()
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            src.take_gpsd_line(tpv())
            src.take_gpsd_line(b'{"class":"TPV","mode":3,"lat":' + FAKE_LAT.encode() + b',"lon":}')
        self.assertEqual(err.getvalue(), "")
        self.assertEqual(src.tpv[1]["lat"], FAKE_LAT)


if __name__ == "__main__":
    unittest.main()
