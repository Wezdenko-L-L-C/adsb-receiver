# SPDX-License-Identifier: Apache-2.0
#
# Load bin/adsb-writer and tools/adsb-extract as modules. They have no .py
# extension, so a plain import cannot find them. Bytecode is not written: a
# __pycache__ beside the installed copy would be clutter.

import importlib.machinery
import importlib.util
import pathlib
import sys

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parent.parent


def load(rel, name):
    if name in sys.modules:
        return sys.modules[name]
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / rel))
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    loader.exec_module(mod)
    return mod


writer = load("bin/adsb-writer", "adsb_writer")
extract = load("tools/adsb-extract", "adsb_extract")


def beast(typ, counter, signal, data):
    """A BEAST frame, escaped as on the wire: every 0x1a after the first doubled."""
    body = counter.to_bytes(6, "big") + bytes([signal]) + bytes(data)
    return bytes([0x1A, typ]) + body.replace(b"\x1a", b"\x1a\x1a")


class FakeClock:
    """A settable time.time_ns()."""

    def __init__(self, ns):
        self.ns = ns

    def __call__(self):
        return self.ns


def utc_ns(y, mo, d, h, mi, s, frac_ns=0):
    import calendar
    return calendar.timegm((y, mo, d, h, mi, s)) * 1_000_000_000 + frac_ns
