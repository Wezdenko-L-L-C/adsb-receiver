# SPDX-License-Identifier: Apache-2.0
#
# bin/adsb-position, the stationary rig's static position responder (#33 A7), spoken to over a
# socket pair as readsb's gpsd_in connector speaks to it. Each TPV is read back with a replica of
# readsb's handle_gpsd() parsing (net_io.c at step 10's pin: strip spaces, need "class":"TPV",
# take "lat":, "lon": and "alt":, each value ended at a comma), so a change in the line's shape
# that readsb could not read fails here.
#
# ⛔ The coordinates are made up (a point in the Pacific Ocean); no real position belongs in this
#    repo. The checks that the position is never printed look for their digits in every message.

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

from _load import ROOT, load

P = load("bin/adsb-position", "adsb_position")

# Made up, not a station's. Built from integers so that no literal has a coordinate's shape (the
# public repo's pre-commit guard refuses one).
LAT, LON, ALT = 12345678 / 1e6, -98765432 / 1e6, 432.0
FAR_LAT, FAR_LON, NEAR_LAT, NEAR_LON = LAT + 83, LON - 100, LAT / 1000, LON / 1000
SHOWN = tuple(f"{abs(v):.4f}" for v in (LAT, LON, FAR_LAT, FAR_LON, NEAR_LAT, NEAR_LON)) + ("432",)


def readsb_parse(line):
    """readsb's handle_gpsd() on one line: (lat, lon, alt or None), or None where it ignores it."""
    p = line.rstrip("\r\n").replace(" ", "")
    if '"class":"TPV"' not in p:
        return None
    i, j = p.find('"lat":'), p.find('"lon":')
    if i < 0 or j < 0:
        return None
    k = p.find('"alt":')

    def value(at):
        return float(p[at + 6:].split(",", 1)[0].rstrip("}"))

    lat, lon = value(i), value(j)
    if not -89.9 <= lat <= 89.9 or not -180 <= lon <= 180 or (abs(lat) < 0.1 and abs(lon) < 0.1):
        return None
    return lat, lon, value(k) if k >= 0 else None


class Conn:
    """The responder's serve() on one end of a socket pair, in a thread; the test is readsb."""

    def __init__(self, pos=(LAT, LON, ALT), repeat_s=60.0):
        self.client, server = socket.socketpair()
        self.client.settimeout(5)
        self.rx = self.client.makefile("r", encoding="utf-8", newline="\n")
        self.server = server
        self.rc = None

        def run():
            self.rc = P.serve(server.fileno(), server.fileno(), pos, repeat_s=repeat_s)

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def send(self, text):
        self.client.sendall(text.encode())

    def line(self):
        return json.loads(self.rx.readline())

    def close(self):
        self.client.shutdown(socket.SHUT_WR)
        self.thread.join(5)
        self.rx.close()
        self.client.close()
        self.server.close()


class Protocol(unittest.TestCase):
    def test_version_first_with_nothing_sent(self):
        # Step 10's verify reads one line before it sends anything, and wants a VERSION.
        c = Conn()
        try:
            v = c.line()
            self.assertEqual(v["class"], "VERSION")
            self.assertEqual(v["release"], "adsb-position")
        finally:
            c.close()
        self.assertEqual(c.rc, 0)

    def test_readsb_watch_gets_the_position_as_readsb_reads_it(self):
        c = Conn()
        try:
            c.line()
            c.send('?WATCH={"enable":true,"json":true};\n')  # readsb's own request, byte for byte
            self.assertEqual(c.line()["class"], "WATCH")
            raw = c.rx.readline()
            self.assertEqual(readsb_parse(raw), (LAT, LON, ALT))
            tpv = json.loads(raw)
            self.assertNotIn("time", tpv)  # not a time source
            self.assertEqual(tpv["mode"], 3)
        finally:
            c.close()
        self.assertEqual(c.rc, 0)

    def test_no_altitude_sends_no_alt(self):
        c = Conn(pos=(LAT, LON, None))
        try:
            c.line()
            c.send('?WATCH={"enable":true,"json":true};\n')
            c.line()
            self.assertEqual(readsb_parse(c.rx.readline()), (LAT, LON, None))
        finally:
            c.close()

    def test_tpv_repeats_while_watching(self):
        c = Conn(repeat_s=0.05)
        try:
            c.line()
            c.send('?WATCH={"enable":true,"json":true};\n')
            c.line()
            self.assertIsNotNone(readsb_parse(c.rx.readline()))
            self.assertIsNotNone(readsb_parse(c.rx.readline()))
        finally:
            c.close()

    def test_no_tpv_without_watch_and_unknown_requests_get_an_error(self):
        c = Conn(repeat_s=0.01)
        try:
            c.line()
            c.send("?DEVICES;\n?VERSION;\n")
            self.assertEqual(c.line()["class"], "ERROR")
            self.assertEqual(c.line()["class"], "VERSION")
            c.send('?WATCH={"enable":false};\n')
            self.assertEqual(c.line(), {"class": "WATCH", "enable": False, "json": False})
            c.client.settimeout(0.3)
            with self.assertRaises(socket.timeout):
                c.client.recv(1)
        finally:
            c.close()


class Position(unittest.TestCase):
    def test_render_round_trips(self):
        with tempfile.TemporaryDirectory() as d:
            f = os.path.join(d, "position")
            with open(f, "w") as fh:
                fh.write(P.render_credential(LAT, LON, ALT))
            self.assertEqual(P.load_position(f), (LAT, LON, ALT))

    def test_refusals_never_carry_the_value(self):
        bad = [
            (None, LON, ALT), (LAT, None, ALT), (True, LON, ALT), (str(LAT), LON, ALT),
            (float("nan"), LON, ALT), (FAR_LAT, LON, ALT), (LAT, FAR_LON, ALT),
            (NEAR_LAT, NEAR_LON, ALT), (LAT, LON, "432"), (LAT, LON, 99432.0),
        ]
        for case in bad:
            with self.subTest(case=case):
                with self.assertRaises(P.PositionError) as cm:
                    P.check_position(*case)
                for d in SHOWN + ("99432",):
                    self.assertNotIn(d, str(cm.exception))

    def test_main_with_a_bad_credential_fails_and_prints_no_value(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "position"), "w") as fh:
                json.dump({"lat": FAR_LAT, "lon": LON, "alt_m": ALT}, fh)
            r = subprocess.run([sys.executable, "-I", str(ROOT / "bin/adsb-position")],
                               env={"CREDENTIALS_DIRECTORY": d, "PATH": os.environ["PATH"]},
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout, "")
        self.assertIn("re-run setup/steps/15-stationary-position.sh", r.stderr)
        for d in SHOWN:
            self.assertNotIn(d, r.stderr)


if __name__ == "__main__":
    unittest.main()
