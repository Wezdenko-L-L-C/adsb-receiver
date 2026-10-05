#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# setup/foundation/rtc_config.py: whether the boot partition's config.txt already has the two RTC
# lines in effect for every board. Run by setup/foundation/rtc-overlay.sh with config.txt's path;
# tested on small files in tests/test_rtc_config.py. Python 3 standard library only.
#
#   rtc_config.py CONFIG_TXT
#     prints two lines: "dtparam on|missing" and "overlay on|missing|conflict <section>: <line>"
#
# It reads the file as the firmware does, as far as this rule needs, last setting wins:
#   - A line counts as "on" only where it applies to every board: before any [section] header,
#     or under [all]. [none] applies to no board, and its lines are ignored.
#   - dtparam=i2c_arm=on (or its alias i2c) turns the parameter on. Any later setting of it to
#     anything else, in any section but [none], counts as undoing it: such a section may apply to
#     this board. Only the literal value "on" counts as on: 1, true or a bare `dtparam=i2c_arm`
#     read as not proven on, so the caller appends the canonical line, a harmless duplicate.
#   - dtoverlay=i2c-rtc,ds3231 loads the overlay. An i2c-rtc overlay for any other chip, in any
#     section but [none], is a conflict, which the caller refuses: a human decides which RTC is
#     fitted, and a section for another board is not told apart from one for this board.
#   - A bare `dtoverlay=` ends the current overlay's parameter scope; it loads and unloads
#     nothing, so it changes neither answer.
# ⚠️ Belief, not checked: no overlay in a stock config.txt has a parameter named i2c_arm, so a
#    dtparam=i2c_arm line after some other dtoverlay= line still reaches the base device tree. The
#    overlay scope is therefore not tracked. Only config.txt itself is read: an `include`d file is
#    not followed.

import re
import sys


def rtc_lines(text):
    """(param, overlay, conflict) for config.txt's text: param is "on" or "missing", overlay is
    "on" or "missing", conflict is "" or "<section>: <line>"."""
    section = "all"
    param, overlay, conflict = "missing", "missing", ""
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip().lower()
            continue
        if section == "none":
            continue
        uncond = section == "all"
        m = re.fullmatch(r"dtparam=(.*)", line)
        if m:
            for kv in m.group(1).split(","):
                k, eq, v = kv.strip().partition("=")
                if k.strip() not in ("i2c_arm", "i2c"):
                    continue
                if eq and v.strip() == "on":
                    if uncond:
                        param = "on"
                else:
                    param = "missing"
            continue
        if line == "dtoverlay=":
            continue
        m = re.fullmatch(r"dtoverlay=i2c-rtc(?:,(.*))?", line)
        if m:
            chips = [kv.strip().partition("=")[0] for kv in (m.group(1) or "").split(",")
                     if kv.strip()]
            if "ds3231" in chips:
                if uncond:
                    overlay = "on"
            else:
                conflict = f"[{section}]: {line}"
    return param, overlay, conflict


def main(argv):
    if len(argv) != 1:
        print("usage: rtc_config.py CONFIG_TXT", file=sys.stderr)
        return 64
    with open(argv[0], errors="replace") as fh:
        param, overlay, conflict = rtc_lines(fh.read())
    print("dtparam", param)
    print("overlay", "conflict " + conflict if conflict else overlay)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
