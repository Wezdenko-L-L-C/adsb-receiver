#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# setup/foundation/rtc-overlay.sh: wire the portable rig's DS3231 RTC into boot, by adding two
# lines to config.txt on the boot partition. BUILD.md §6b; PLAN §9h (the foundation tier).
#
# ⛔ Foundation, not a step: the boot partition is on the PLAN §9h denylist, so no step and no
#    timer-driven update writes it. update.sh --bootstrap runs it on a portable's first build,
#    which a human started by hand.
#
# What it does, and nothing else (Chris, 2026-10-04):
#   - refuses any role but portable (the stationary rig has no RTC, PLAN §9l);
#   - if /dev/rtc0 already exists, writes nothing. On a Pi 4 (the portable rig), which has no RTC
#     of its own, rtc0 can only be an added one. ⚠️ On a Pi 5 the SoC's own RTC is rtc0 and a
#     DS3231 would be rtc1, so this check (and step 20's) would need revisiting there;
#   - if config.txt already has both lines in effect for every board, writes nothing. "In effect"
#     reads the file as the firmware does, last setting wins: the line is under [all] or before any
#     section, and no later line in any section but [none] turns i2c_arm off or loads i2c-rtc for
#     another chip. A conflicting i2c-rtc overlay, in any such section, refuses (a human decides
#     which RTC is fitted). The reading is rtc_config.py beside this file, tested in
#     tests/test_rtc_config.py;
#   - otherwise backs config.txt up beside itself (config.txt.adsb-<UTC time>), appends an [all]
#     section with the missing lines, re-reads both lines from the file, records that a reboot is
#     needed (lib.sh need_reboot), and prints the charge-path line marked NOTE:, which update.sh
#     copies into that run's status.json notes;
#   - with both lines in effect but no /dev/rtc0, records that a reboot is needed too (the lines
#     were added by hand, or by a run whose flag a reboot has not cleared). A reboot should bring
#     rtc0; if it is still absent after one, the DS3231 is missing or mis-wired, which no reboot
#     fixes.
#   The bootstrap may then reboot once; step 20 then looks for /dev/rtc0. ⚠️ Belief, not seen
#   through this path: the reboot makes rtc0 appear (PLAN §9e).
# ⚠️ Only config.txt itself is read: an `include`d file is not followed.
# ⚠️ Belief, not seen: with no DS3231 fitted, the lines are harmless (the driver's probe fails and
#    no /dev/rtc0 appears; step 20 then says so).
#
# What has run on hardware: nothing. On the portable Pi the two lines were added by hand on
# 2026-10-03, so there this changes nothing.

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

case ${1:-} in
  '') ;;
  -h|--help) sed -n '3,37p' "$0"; exit 0 ;;
  *) die "unknown argument: $1 (this script takes none)" ;;
esac
((EUID == 0)) || die "run as root (update.sh --bootstrap runs this on a portable's first build)"
require_role portable

if [[ -e /dev/rtc0 ]]; then
  pass "/dev/rtc0 exists: the RTC is already wired into boot; config.txt is not touched"
  exit 0
fi

CONFIG=/boot/firmware/config.txt
[[ -f $CONFIG ]] || die "$CONFIG does not exist: this is not the Raspberry Pi OS layout this guide builds on"

# rtc_lines: the two lines' state in config.txt, read as the firmware reads it (last setting
# wins), by rtc_config.py (its header has the rules). Prints "dtparam on|missing" and
# "overlay on|missing|conflict [<section>]: <line>".
rtc_lines() {
  python3 "$(dirname "${BASH_SOURCE[0]}")/rtc_config.py" "$CONFIG"
}

# missing_lines: the lines to append, one per line; dies on a conflict.
missing_lines() {
  local state
  state=$(rtc_lines) || die "could not read $CONFIG"
  if grep -q '^overlay conflict' <<<"$state"; then
    die "$CONFIG loads i2c-rtc for another chip ($(sed -n 's/^overlay conflict //p' <<<"$state")); a human decides which RTC is fitted, even when that line is in a section for another board. BUILD.md §6b"
  fi
  grep -qx 'dtparam on' <<<"$state" || echo 'dtparam=i2c_arm=on'
  grep -qx 'overlay on' <<<"$state" || echo 'dtoverlay=i2c-rtc,ds3231'
  return 0
}

missing=()
mapfile -t missing < <(missing_lines)
# missing_lines runs in a process substitution, so its die cannot stop this script: check again.
missing_lines >/dev/null

log "$CONFIG, the RTC lines (raw, before)"
grep -nE 'i2c|rtc|^\[' "$CONFIG" || echo "(no i2c, rtc or section lines)"
echo "----"

if ((${#missing[@]} == 0)); then
  need_reboot "the RTC overlay is in config.txt but /dev/rtc0 is absent: a reboot should bring it; if it is still absent after one, check the DS3231's wiring (BUILD.md §6b) (setup/foundation/rtc-overlay.sh)"
  pass "$CONFIG already has both lines in effect for every board; nothing to change, but /dev/rtc0 needs a reboot"
  exit 0
fi

backup=$CONFIG.adsb-$(date -u +%Y%m%dT%H%M%SZ)
run cp -p "$CONFIG" "$backup"
tmp=$CONFIG.adsb-new
cp -p "$CONFIG" "$tmp"
# A file that does not end in a newline would join its last line to ours.
lead=$'\n'
[[ -z $(tail -c1 "$CONFIG") ]] || lead=$'\n\n'
{
  printf '%s' "$lead"
  echo "# Added by adsb-receiver setup/foundation/rtc-overlay.sh: the DS3231 RTC (BUILD.md §6b)."
  echo "[all]"
  printf '%s\n' "${missing[@]}"
} >>"$tmp"
sync "$tmp"
# A rename, so a power cut leaves the old file or the new one. ⚠️ On FAT that is the usual
# outcome, not a guarantee; the backup above is the remedy.
run mv -f "$tmp" "$CONFIG"
sync "$CONFIG"

log "$CONFIG, the RTC lines (raw, after); the backup is $backup"
grep -nE 'i2c|rtc|^\[' "$CONFIG" || true
echo "----"
# The file's text, both lines; the effect (/dev/rtc0) can only be seen after a reboot.
still=$(missing_lines) || die "could not re-read $CONFIG; restore $backup and look"
[[ -z $still ]] || die "after the write, $CONFIG still lacks, in effect: $(paste -sd ' ' <<<"$still"). Restore $backup and look"
need_reboot "the RTC overlay was added to config.txt (setup/foundation/rtc-overlay.sh)"
# The one check nothing here can make (Chris, 2026-10-04). update.sh records NOTE: lines in this
# run's status.json notes and in its foundation.notes, which every later status.json carries forward.
echo "NOTE: If this is a ZS-042 board with a CR2032, the charge path must already be removed (BUILD.md §6b); nothing here can check it."
pass "added to $CONFIG: ${missing[*]}"
