# SPDX-License-Identifier: Apache-2.0
#
# setup/foundation/rtc_config.py: the reading of config.txt that decides whether
# setup/foundation/rtc-overlay.sh writes the boot partition. On text, no boot partition.

import contextlib
import io
import os
import tempfile
import unittest

from _load import load

RC = load("setup/foundation/rtc_config.py", "rtc_config")

PARAM = "dtparam=i2c_arm=on"
OVERLAY = "dtoverlay=i2c-rtc,ds3231"


def lines(*ls):
    return RC.rtc_lines("\n".join(ls) + "\n")


class RtcConfigTest(unittest.TestCase):
    def test_both_lines_before_any_section_or_under_all_are_on(self):
        self.assertEqual(lines(PARAM, OVERLAY), ("on", "on", ""))
        self.assertEqual(lines("[pi4]", "dtoverlay=vc4-kms-v3d", "[all]", PARAM, OVERLAY),
                         ("on", "on", ""))

    def test_a_stock_file_has_neither(self):
        stock = ("#dtparam=i2c_arm=on", "dtparam=audio=on", "camera_auto_detect=1",
                 "dtoverlay=vc4-kms-v3d", "[cm4]", "otg_mode=1", "[all]")
        self.assertEqual(lines(*stock), ("missing", "missing", ""))

    def test_the_last_setting_wins(self):
        self.assertEqual(lines(PARAM, "dtparam=i2c_arm=off")[0], "missing")
        self.assertEqual(lines("dtparam=i2c_arm=off", PARAM)[0], "on")
        self.assertEqual(lines(PARAM, "dtparam=audio=on,i2c=off")[0], "missing")

    def test_a_line_under_a_board_section_does_not_count_as_on_for_every_board(self):
        self.assertEqual(lines("[pi4]", PARAM, OVERLAY), ("missing", "missing", ""))

    def test_a_later_off_in_any_board_section_undoes_it(self):
        self.assertEqual(lines(PARAM, "[pi4]", "dtparam=i2c_arm=off")[0], "missing")

    def test_none_applies_to_no_board(self):
        self.assertEqual(lines(PARAM, OVERLAY, "[none]", "dtparam=i2c_arm=off",
                               "dtoverlay=i2c-rtc,pcf8523"), ("on", "on", ""))
        self.assertEqual(lines("[none]", PARAM, OVERLAY), ("missing", "missing", ""))

    def test_only_the_literal_on_counts_as_on(self):
        # Not proven on: the caller appends the canonical line, a harmless duplicate.
        for v in ("dtparam=i2c_arm=1", "dtparam=i2c_arm=true", "dtparam=i2c_arm", "dtparam=i2c_arm=ON"):
            self.assertEqual(lines(v)[0], "missing", v)
            self.assertEqual(lines(PARAM, v)[0], "missing", v)

    def test_a_bare_dtoverlay_resets_scope_and_changes_neither_answer(self):
        self.assertEqual(lines(OVERLAY, "dtoverlay=", PARAM), ("on", "on", ""))
        self.assertEqual(lines(PARAM, OVERLAY, "dtoverlay="), ("on", "on", ""))
        self.assertEqual(lines("dtoverlay="), ("missing", "missing", ""))

    def test_an_rtc_overlay_for_another_chip_is_a_conflict(self):
        p, o, c = lines(PARAM, "dtoverlay=i2c-rtc,pcf8523")
        self.assertEqual(c, "[all]: dtoverlay=i2c-rtc,pcf8523")
        # Even after ds3231, last wins.
        self.assertTrue(lines(PARAM, OVERLAY, "dtoverlay=i2c-rtc,ds1307")[2])

    def test_a_conflict_in_another_boards_section_still_refuses(self):
        # Fail closed: which sections apply to this board is not decided here.
        _, _, c = lines(PARAM, OVERLAY, "[pi5]", "dtoverlay=i2c-rtc,rv3028")
        self.assertEqual(c, "[pi5]: dtoverlay=i2c-rtc,rv3028")

    def test_comments_and_trailing_comments_are_ignored(self):
        self.assertEqual(lines("# " + PARAM, OVERLAY + "  # the RTC"), ("missing", "on", ""))

    def test_main_prints_the_two_lines(self):
        with tempfile.TemporaryDirectory() as d:
            f = os.path.join(d, "config.txt")
            with open(f, "w") as fh:
                fh.write(PARAM + "\n[pi5]\ndtoverlay=i2c-rtc,rv3028\n")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(RC.main([f]), 0)
            self.assertEqual(out.getvalue(),
                             "dtparam on\noverlay conflict [pi5]: dtoverlay=i2c-rtc,rv3028\n")


if __name__ == "__main__":
    unittest.main()
