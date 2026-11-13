# SPDX-License-Identifier: Apache-2.0
#
# The clock's state and error bound, three copies held to one answer (ruled 2026-11-11 19:01,
# PLAN §9e "the clock while recording"): bin/adsb-slate's parse_tracking() and clock_state(), which
# define them; bin/adsb-writer's copy, which marks the archive; and bin/clock-preflight's, which
# decides whether the writer may start. Each program is installed alone, outside the clone, so none
# can import another: this test is what keeps the copies equal.
#
# bin/clock-preflight runs for real, as the test's own user, against a stubbed chronyc. The script
# reads /etc/adsb-receiver/clock.conf and sets a fixed PATH: the test runs a copy with the path
# pointed into a temporary directory and the stub's directory put first on that PATH (each
# replacement is asserted, so a reworded line fails here rather than reading the real file).
# Step 20's render_clock_conf, which writes clock.conf from station.yml, is taken out of the step
# and run too, and its output fed to the preflight, so the two agree on the format.
# Fake chronyc numbers carry two decimals at most: the commit guard reads longer ones around a
# comma as a position. Needs bash; the render's cases also need python3 with PyYAML.

import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import unittest

from _load import load, writer as W

S = load("bin/adsb-slate", "adsb_slate")
ROOT = pathlib.Path(__file__).resolve().parent.parent
CONF_LINE = "CONF=/etc/adsb-receiver/clock.conf"
PATH_LINE = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

try:
    import yaml  # noqa: F401  (clock-preflight's own python3 needs it)
    HAVE_YAML = True
except ImportError:
    HAVE_YAML = False


def tracking(age_s, offset="0.00", root_delay="0.01", root_disp="0.01", interval="16.0",
             leap="Normal", ref_id="C0000201", stratum="2", name=None, now=None):
    """One chronyc -n -c tracking line, the reference age_s seconds old. Stratum 2 and an NTP
    server's address by default; the GPS is ref_id 47505300, name GPS, stratum 1."""
    now = time.time() if now is None else now
    if name is None:
        name = "192.0.2.1" if ref_id != "00000000" else ""
    return ",".join([
        ref_id, name, stratum,
        f"{now - age_s:.2f}",   # 3 ref time
        offset,                 # 4 system time
        "0.00", "0.01",         # 5 last offset, 6 RMS offset
        "7.80", "0.00", "0.03", # 7 frequency, 8 residual, 9 skew
        root_delay,             # 10 root delay
        root_disp,              # 11 root dispersion
        interval,               # 12 update interval
        leap,                   # 13 leap status
    ]) + "\n"


GPS = dict(ref_id="47505300", name="GPS", stratum="1")

# name -> (tracking kwargs, the state word every copy must give). HOLDOVER is a fixed age by the
# reference's kind, from chrony's stratum (ruled 2026-11-12 21:17): past 96 s at stratum 1, past
# 2112 s at stratum 2 or more, past 96 s for stratum 0 or one that is not a whole number. chrony's
# update interval is no longer an input; the cases give it where it once decided the answer.
CASES = {
    "synced": (dict(age_s=5), "SYNCED"),
    "coarse": (dict(age_s=5, offset="0.01", root_delay="0.10", root_disp="0.02"), "COARSE"),
    # Until 2026-11-12 this case was stratum 2 with a 16 s interval, HOLDOVER past 2 x 16 + 64 s;
    # a 16 s poll is the GPS refclock's, so it is the GPS now.
    "holdover, GPS": (dict(age_s=200, **GPS), "HOLDOVER"),
    "NTP at 1000 s, not yet holdover": (dict(age_s=1000, interval="1044.3"), "SYNCED"),
    # 2026-11-11: no source selected for about 5 1/2 h, the reference frozen, the bound small.
    "2026-11-11": (dict(age_s=19800, offset="0.01", root_delay="0.04", root_disp="0.03",
                        interval="1037.6"), "HOLDOVER"),
    "unsynced": (dict(age_s=5, leap="Not synchronised"), "UNSYNCED"),
    # After a burst the interval reads seconds: 2 x 2 + 64 s called this HOLDOVER.
    "post-burst, NTP": (dict(age_s=204, interval="2.0"), "SYNCED"),
    # A stalled selection stretches the interval to hours: 2 x 33091 + 64 s did not call this.
    "stall, NTP": (dict(age_s=8000, interval="33091"), "HOLDOVER"),
    "GPS at 40 s": (dict(age_s=40, **GPS), "SYNCED"),
    "GPS at 100 s": (dict(age_s=100, **GPS), "HOLDOVER"),
    "stratum 0, leap Normal, at 100 s": (dict(age_s=100, stratum="0"), "HOLDOVER"),
    "stratum not a number, at 100 s": (dict(age_s=100, stratum="x"), "HOLDOVER"),
    "stratum empty, at 100 s": (dict(age_s=100, stratum=""), "HOLDOVER"),
    "stratum 0 unsynchronised": (dict(age_s=5, stratum="0", leap="Not synchronised"), "UNSYNCED"),
    "stratum 2 unsynchronised, an old reference": (dict(age_s=8000, leap="Not synchronised"),
                                                   "UNSYNCED"),
}

# The boundaries, exact: run only where the test sets "now" (the preflight reads its own clock;
# its boundary cases are PREFLIGHT_BOUNDARIES, below). NOW is a whole second, so a reference time
# NOW - age_s with two decimals is exact. Strictly older than the age is HOLDOVER.
NOW = 1_800_000_000.0
EXACT_CASES = {
    "GPS at 96 s": (dict(age_s=96, **GPS), "SYNCED"),
    "GPS at 96.01 s": (dict(age_s=96.01, **GPS), "HOLDOVER"),
    "NTP at 2112 s": (dict(age_s=2112), "SYNCED"),
    "NTP at 2112.01 s": (dict(age_s=2112.01), "HOLDOVER"),
    "stratum 3 at 2112.01 s": (dict(age_s=2112.01, stratum="3"), "HOLDOVER"),
    "stratum 3 at 2000 s": (dict(age_s=2000, stratum="3"), "SYNCED"),
}

# The same boundaries for the preflight, which reads its own clock after the test wrote the line:
# its age only grows, so "under" is 5 s under and "over" is 1 s over.
PREFLIGHT_BOUNDARIES = {
    "GPS just under 96 s": (dict(age_s=91, **GPS), "SYNCED"),
    "GPS just over 96 s": (dict(age_s=97, **GPS), "HOLDOVER"),
    "NTP just under 2112 s": (dict(age_s=2107), "SYNCED"),
    "NTP just over 2112 s": (dict(age_s=2113), "HOLDOVER"),
}

SOURCES_NONE_SELECTED = (
    "MS Name/IP address         Stratum Poll Reach LastRx Last sample\n"
    "===============================================================================\n"
    "^- 192.0.2.1                     2  10   377   500   +100us[ +100us] +/-   50ms\n"
    "^? 192.0.2.2                     2  10   377   600   +200us[ +200us] +/-   60ms\n")
SOURCES_SELECTED = SOURCES_NONE_SELECTED.replace("^- 192.0.2.1", "^* 192.0.2.1")


class SlateAndWriterAgree(unittest.TestCase):
    def test_same_word_and_bound(self):
        now = NOW
        for name, (kw, want) in {**CASES, **EXACT_CASES}.items():
            with self.subTest(case=name):
                line = tracking(now=now, **kw)
                st, _ = S.clock_state(S.parse_tracking(line), True, now)
                wt = W.parse_tracking(line)
                self.assertEqual(st, want)
                self.assertEqual(W.clock_word(wt, now), want)
                self.assertEqual(wt["bound_s"], S.parse_tracking(line)["bound_s"])

    def test_same_thresholds(self):
        self.assertEqual((W.BOUND_OK_S, W.HOLDOVER_GPS_S, W.HOLDOVER_NTP_S),
                         (S.BOUND_OK_S, S.HOLDOVER_GPS_S, S.HOLDOVER_NTP_S))
        # As ruled 2026-11-12: 2 x 16 s + 64 s, and 2 x 1024 s + 64 s.
        self.assertEqual((S.HOLDOVER_GPS_S, S.HOLDOVER_NTP_S), (96.0, 2112.0))
        for stratum, want in (("1", 96.0), ("2", 2112.0), ("15", 2112.0), ("0", 96.0), ("", 96.0),
                              ("x", 96.0), ("2_0", 96.0), (" 2 ", 2112.0), ("-2", 96.0)):
            with self.subTest(stratum=stratum):
                self.assertEqual(S.holdover_after_s(stratum), want)
                self.assertEqual(W.holdover_after_s(stratum), want)

    def test_the_update_interval_judges_nothing(self):
        for interval in ("0.0", "2.0", "16.0", "1044.3", "33091"):
            with self.subTest(interval=interval):
                for kw, want in ((dict(age_s=90), "SYNCED"), (dict(age_s=2000), "SYNCED"),
                                 (dict(age_s=2200), "HOLDOVER"), (dict(age_s=90, **GPS), "SYNCED"),
                                 (dict(age_s=100, **GPS), "HOLDOVER")):
                    line = tracking(now=NOW, interval=interval, **kw)
                    self.assertEqual(S.clock_state(S.parse_tracking(line), True, NOW)[0], want)
                    self.assertEqual(W.clock_word(W.parse_tracking(line), NOW), want)

    def test_non_finite_is_unparsed_in_both(self):
        line = tracking(age_s=5, offset="nan")
        self.assertIsNone(S.parse_tracking(line))
        self.assertIsNone(W.parse_tracking(line))


class PreflightBase(unittest.TestCase):
    """A copy of bin/clock-preflight to run, its clock.conf, and a stubbed chronyc."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        src = (ROOT / "bin/clock-preflight").read_text()
        self.assertEqual(src.count(CONF_LINE), 1, "the clock.conf line to remap was not found once")
        self.assertEqual(src.count(PATH_LINE), 1, "the fixed PATH line was not found once")
        self.assertNotIn("EUID", src, "the preflight must run as any user")
        self.conf = self.tmp / "clock.conf"
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.script = self.tmp / "clock-preflight"
        self.script.write_text(src.replace(CONF_LINE, f"CONF={self.conf}")
                               .replace(PATH_LINE, f"PATH={self.bin}:{PATH_LINE[5:]}"))
        stub = self.bin / "chronyc"
        stub.write_text(
            "#!/usr/bin/env bash\n"
            'case "$*" in\n'
            '  "-n tracking") echo "Reference ID    : (stub text form; not judged)" ;;\n'
            '  "-n -c tracking") cat "$FAKE_DIR/csv" ;;\n'
            '  "-n sources") cat "$FAKE_DIR/sources" ;;\n'
            "  *) exit 1 ;;\n"
            "esac\n")
        stub.chmod(0o755)
        self.config(500)

    def config(self, max_ms, require="true"):
        self.conf.write_text("# a comment\n"
                             f"max_offset_ms={max_ms}\nrequire_disciplined={require}\nsource=gps\n")

    def run_it(self, csv, sources=SOURCES_NONE_SELECTED):
        (self.tmp / "csv").write_text(csv)
        (self.tmp / "sources").write_text(sources)
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", FAKE_DIR=str(self.tmp))
        p = subprocess.run(["bash", str(self.script)], capture_output=True, text=True,
                           env=env, timeout=60)
        return p.returncode, p.stdout, p.stderr

    def state_line(self, out):
        lines = [x for x in out.splitlines() if x.startswith("==> clock state ")]
        self.assertEqual(len(lines), 1, out)
        return lines[0]


@unittest.skipUnless(shutil.which("bash"), "needs bash")
class Preflight(PreflightBase):
    def test_agrees_with_the_slate(self):
        for name, (kw, want) in {**CASES, **PREFLIGHT_BOUNDARIES}.items():
            if want == "UNSYNCED":
                continue  # refused before the state line; test_cold_boot_is_not_ready below
            with self.subTest(case=name):
                line = tracking(**kw)
                rc, out, err = self.run_it(line)
                self.assertEqual(rc, 0, out + err)
                bound = S.parse_tracking(line)["bound_s"] * 1000
                ref = kw.get("ref_id", "C0000201")
                self.assertIn(f"==> clock state {want}: reference {ref}, error bound {bound:.3f} ms",
                              self.state_line(out))
                # The slate gives the same word on the same line at the preflight's own reading.
                self.assertEqual(S.clock_state(S.parse_tracking(line), True, time.time())[0], want)

    def test_the_state_line_names_the_stratum_and_its_age(self):
        rc, out, err = self.run_it(tracking(age_s=204, interval="2.0"))
        self.assertEqual(rc, 0, out + err)
        self.assertIn("(stratum 2, HOLDOVER past 2112 s; update interval 2 s)", self.state_line(out))
        rc, out, err = self.run_it(tracking(age_s=40, **GPS))
        self.assertEqual(rc, 0, out + err)
        self.assertIn("(stratum 1, HOLDOVER past 96 s; update interval 16 s)", self.state_line(out))
        # A stratum that is not a whole number is not printed.
        rc, out, err = self.run_it(tracking(age_s=40, stratum="a\tb"))
        self.assertEqual(rc, 0, out + err)
        self.assertIn("(stratum ?, HOLDOVER past 96 s; update interval 16 s)", self.state_line(out))

    def test_2026_11_11_is_ready_in_holdover_with_no_source_selected(self):
        kw, _ = CASES["2026-11-11"]
        rc, out, err = self.run_it(tracking(**kw), SOURCES_NONE_SELECTED)
        self.assertEqual(rc, 0, out + err)
        self.assertIn("0 source(s) selected ('*')", out)
        last = out.strip().splitlines()[-1]
        self.assertTrue(last.startswith("==> READY: HOLDOVER, error bound 60.000 ms within 500 ms;"
                                        " chrony's reference was last updated "), last)

    def test_a_selected_source_is_not_required_and_not_refused(self):
        rc, out, _ = self.run_it(tracking(age_s=5), SOURCES_SELECTED)
        self.assertEqual(rc, 0)
        self.assertEqual(out.strip().splitlines()[-1],
                         "==> READY: disciplined (SYNCED), error bound 15.000 ms within 500 ms")

    def test_cold_boot_is_not_ready(self):
        cold = tracking(age_s=time.time(), offset="0.00", root_delay="1.00", root_disp="1.00",
                        interval="0.0", leap="Not synchronised", ref_id="00000000", stratum="0")
        rc, _, err = self.run_it(cold, "")
        self.assertEqual(rc, 2, err)
        self.assertIn("NOT READY: the clock is not disciplined: chrony has no reference"
                      " (Reference ID 00000000); Leap status is 'Not synchronised'", err)

    def test_local_clock_reference_is_not_ready(self):
        rc, _, err = self.run_it(tracking(age_s=5, ref_id="7F7F0101"))
        self.assertEqual(rc, 2)
        self.assertIn("its own local clock (7F7F0101)", err)

    def test_bound_over_the_bar_is_not_ready(self):
        rc, _, err = self.run_it(tracking(age_s=19800, offset="0.40", root_disp="0.20",
                                          interval="1037.6"))
        self.assertEqual(rc, 2)
        self.assertIn("NOT READY: chrony's error bound is 605.000 ms (HOLDOVER), over"
                      " clock.max_offset_ms (500 ms)", err)
        self.config(100)  # the stationary's bar
        rc, _, err = self.run_it(tracking(age_s=5, offset="0.10", root_disp="0.01"))
        self.assertEqual(rc, 2, err)
        self.assertIn("over clock.max_offset_ms (100 ms)", err)

    def test_clock_conf_missing_or_invalid_could_not_run(self):
        good = tracking(age_s=5)
        for text, want in (
                (None, "cannot read"),
                ("max_offset_ms=500\nrequire_disciplined=true\n", "no source"),
                ("max_offset_ms=0\nrequire_disciplined=true\nsource=gps\n", "positive, plain decimal"),
                ("max_offset_ms=nan\nrequire_disciplined=true\nsource=gps\n", "positive, plain decimal"),
                ("max_offset_ms=true\nrequire_disciplined=true\nsource=gps\n", "positive, plain decimal"),
                # float() takes each of these; awk's -v would read another number, so all are refused.
                ("max_offset_ms=1_0\nrequire_disciplined=true\nsource=gps\n", "positive, plain decimal"),
                ("max_offset_ms= 5\nrequire_disciplined=true\nsource=gps\n", "positive, plain decimal"),
                ("max_offset_ms=1e3\nrequire_disciplined=true\nsource=gps\n", "positive, plain decimal"),
                ("max_offset_ms=+5\nrequire_disciplined=true\nsource=gps\n", "positive, plain decimal"),
                ("max_offset_ms=5.\nrequire_disciplined=true\nsource=gps\n", "positive, plain decimal"),
                ("max_offset_ms=500\nrequire_disciplined=yes\nsource=gps\n", "true or false"),
                ("max_offset_ms=500\nmax_offset_ms=100\nrequire_disciplined=true\nsource=gps\n",
                 "once, as key=value"),
                ("max_offset_ms=500\nrequire_disciplined=true\nsource=gps\nextra=1\n", "once, as key=value")):
            with self.subTest(text=text):
                if text is None:
                    self.conf.unlink(missing_ok=True)
                else:
                    self.conf.write_text(text)
                rc, _, err = self.run_it(good)
                self.assertEqual(rc, 1, err)
                self.assertIn(want, err)

    def test_an_empty_source_is_valid(self):
        self.conf.write_text("max_offset_ms=500\nrequire_disciplined=true\nsource=\n")
        rc, out, err = self.run_it(tracking(age_s=5))
        self.assertEqual(rc, 0, out + err)
        self.assertIn("clock.require_disciplined true, clock.source (unset)", out)

    def test_lines_split_on_newline_only(self):
        # A U+2028 or U+0085 inside a value is not a line break (step 20's render refuses both).
        self.conf.write_text("max_offset_ms=500\nrequire_disciplined=true\nsource=a\u2028b\u0085c\n",
                             encoding="utf-8")
        rc, out, err = self.run_it(tracking(age_s=5))
        self.assertEqual(rc, 0, out + err)
        self.conf.write_text("max_offset_ms=500\u2028require_disciplined=true\nsource=gps\n", encoding="utf-8")
        rc, _, err = self.run_it(tracking(age_s=5))
        self.assertEqual(rc, 1)
        self.assertIn("no require_disciplined", err)

    def test_unparsed_tracking_could_not_run(self):
        rc, _, err = self.run_it("506 Cannot talk to daemon\n")
        self.assertEqual(rc, 1)
        self.assertIn("CHECK FAILED TO RUN: could not parse chronyc -n -c tracking", err)
        # A line with the reference's name but too few fields: the name is never in the message.
        rc, _, err = self.run_it("C0000201,192.0.2.1,2\n")
        self.assertEqual(rc, 1)
        last = err.strip().splitlines()[-1]
        self.assertIn("3 field(s) in its first line, 14 needed", last)
        self.assertNotIn("192.0.2.1", last)


if __name__ == "__main__":
    unittest.main()


@unittest.skipUnless(HAVE_YAML and shutil.which("bash"), "needs bash and PyYAML")
class Step20Render(PreflightBase):
    """setup/steps/20-portable-clock.sh's render_clock_conf, with lib.sh's station_file and die
    stood in for, feeding the preflight above."""

    def render(self, yml):
        st = self.tmp / "station.yml"
        st.write_text(yml)
        step = (ROOT / "setup/steps/20-portable-clock.sh").read_text()
        self.assertEqual(step.count("\nrender_clock_conf() {\n"), 1,
                         "step 20's render_clock_conf() was not found once: the extraction would test nothing")
        start = step.index("\nrender_clock_conf() {\n") + 1
        end = step.find("\n}\n", start)
        self.assertGreater(end, start, "render_clock_conf() has no closing brace at the start of a line")
        fn = step[start:end + 3]
        self.assertIn("python3 - \"$f\" >\"$WORK/clock.conf\"", fn, "the extracted function is not the render")
        work = self.tmp / "work"
        work.mkdir(exist_ok=True)
        harness = (f"set -euo pipefail\nWORK={work}\nstation_file() {{ echo {st}; }}\n"
                   "die() { echo \"xx  FAIL: $*\" >&2; exit 1; }\n" + fn + "render_clock_conf\n")
        p = subprocess.run(["bash", "-c", harness], capture_output=True, text=True, timeout=60)
        return p.returncode, (work / "clock.conf").read_text() if p.returncode == 0 else "", p.stderr

    def test_render_feeds_the_preflight(self):
        rc, conf, err = self.render("clock:\n  source: gps\n  max_offset_ms: 500\n  require_disciplined: true\n")
        self.assertEqual(rc, 0, err)
        self.assertIn("max_offset_ms=500\nrequire_disciplined=true\nsource=gps\n", conf)
        self.conf.write_text(conf)
        kw, _ = CASES["2026-11-11"]
        rc, out, err = self.run_it(tracking(**kw))
        self.assertEqual(rc, 0, out + err)
        self.assertIn("clock.max_offset_ms 500, clock.require_disciplined true, clock.source gps", out)

    def test_render_writes_a_plain_decimal_the_preflight_accepts(self):
        for yml_value, want in (("500", "500"), ("100.5", "100.5"), ("1.0e-5", "0.00001"),
                                ("1.0e+16", "10000000000000000"), ("250.0", "250.0")):
            with self.subTest(value=yml_value):
                rc, conf, err = self.render(f"clock:\n  max_offset_ms: {yml_value}\n  require_disciplined: true\n")
                self.assertEqual(rc, 0, err)
                self.assertIn(f"\nmax_offset_ms={want}\n", conf)
                self.conf.write_text(conf)
                rc, out, err = self.run_it(tracking(age_s=5))
                self.assertIn(rc, (0, 2), out + err)
                self.assertIn(f"clock.max_offset_ms {want},", out)

    def test_render_refuses_what_the_preflight_would(self):
        for yml, want in (("clock:\n  max_offset_ms: true\n  require_disciplined: true\n", "positive, finite"),
                          ("clock:\n  max_offset_ms: .nan\n  require_disciplined: true\n", "positive, finite"),
                          ("clock:\n  max_offset_ms: 500\n  require_disciplined: 1\n", "true or false"),
                          ("station:\n  role: portable\n", "no clock: block"),
                          ("clock:\n  max_offset_ms: 500\n  require_disciplined: true\n  source: \"a\\u2028b\"\n",
                           "line-separator"),
                          ("clock:\n  max_offset_ms: 500\n  require_disciplined: true\n  source: \"a\\x85b\"\n",
                           "line-separator")):
            with self.subTest(yml=yml):
                rc, _, err = self.render(yml)
                self.assertEqual(rc, 1)
                self.assertIn(want, err)
                self.assertIn("is not valid for clock-preflight", err)
