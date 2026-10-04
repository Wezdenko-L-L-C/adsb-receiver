#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 20-portable-clock: gpsd on the GPS puck, chrony disciplined by it, the DS3231
# RTC checked, systemd-timesyncd out of the way, and bin/clock-preflight
# installed. BUILD.md §6 and §8 step 2; PLAN §9c.
#
# Portable only: asserts station.role, refuses a position: block, and refuses
# any clock.source but gps (PLAN §9b).
#
#   setup/steps/20-portable-clock.sh            install, then verify
#   setup/steps/20-portable-clock.sh --verify   verify only
#
# What this encodes: the values set by hand on the portable rig on
# 2026-10-03. This step ran on the portable Pi on 2026-10-04 and exited 0 (PLAN
# §9m, "Verified on hardware, 2026-10-04").
#   - gpsd 3.25 and chrony 4.6.1 from trixie. /etc/default/gpsd with the puck's
#     /dev/serial/by-id/ path, GPSD_OPTIONS="-n -b -s 4800", USBAUTO="true".
#     gpsd.service and gpsd.socket are both enabled on the Pi (seen
#     2026-10-04), and this step enables both.
#   - /etc/chrony/conf.d/gps.conf: one SHM refclock, offset 0.203. Debian's
#     chrony.conf reads conf.d (confdir) and carries rtcsync.
#   - The RTC overlay lines in config.txt on the boot partition.
#   - How the RTC reaches boot, as seen on the Pi, 2026-10-04: the kernel's
#     rtc-ds1307 driver registers rtc0 and sets the system clock from it itself
#     (the journal says "setting system clock to ..."; /sys/class/rtc/rtc0/
#     hctosys is 1). chrony's rtcsync is believed to be what writes the time
#     back to the RTC (the kernel's 11-minute mode); that was not observed.
#     There is no fake-hwclock, no udev hwclock-set, and hwclock.service is
#     masked (Debian's default). So this step adds nothing to the boot path.
#   - hwclock was NOT on the Pi: trixie ships it in util-linux-extra, which
#     was not installed. This step installs it, for the verify's `hwclock -r`
#     only; that package carries no udev rule or unit (Debian's file list).
#   - gpspipe, on trixie, is in gpsd-clients, not gpsd-tools (dpkg -S on the
#     Pi, and Debian's file lists, 2026-10-04). gpsd-tools has cgps, gpsmon
#     and gpssnmp. gpsd-clients is kept for gpspipe (Chris, 2026-10-04).
#
# ⛔ It never writes config.txt on the boot partition, which is on the PLAN
#    §9h denylist. With no /dev/rtc0 it prints the two lines to add, and
#    exits non-zero: a human gate, like formatting the archive drive.
# ⛔ The verify never judges the sky (fix quality, offset). That is
#    clock-preflight's job (PLAN §9c, two tiers).

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"
require_role portable
require_absent position

CLOCK_SOURCE=$(station_get clock.source) \
  || die "station.yml has no clock.source: add the clock: block from config/station.portable.example.yml"
[[ $CLOCK_SOURCE == gps ]] \
  || die "clock.source is '${CLOCK_SOURCE}'; the portable rig takes time from gps, and only gps: there is no network in the field (BUILD.md §6a)"

PKGS=(gpsd gpsd-clients chrony util-linux-extra)
GPSD_DEFAULTS=/etc/default/gpsd
CHRONY_GPS=/etc/chrony/conf.d/gps.conf
BY_ID=/dev/serial/by-id
RTC=/dev/rtc0
# A sanity floor only: a DS3231 that lost its coin cell is believed to restart
# at 2000-01-01. The real check compares the RTC to a disciplined system clock.
RTC_YEAR_FLOOR=2025
RTC_MAX_SKEW_S=5
# Copied, not symlinked: update.sh is to flip between two worktrees (PLAN §9f),
# and a symlink into one would follow the flip.
PREFLIGHT=/usr/local/bin/clock-preflight

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# install_if_changed <src> <dst> <mode> <owner:group>: render, diff, install
# (PLAN §9f). Installs only when the content, mode or owner differs, and logs
# which. Sets CHANGED to 0 or 1.
CHANGED=0
install_if_changed() {
  local src=$1 dst=$2 mode=$3 owner=$4
  guard_path "$dst"
  CHANGED=0
  if [[ -f $dst ]] && cmp -s "$src" "$dst" \
     && [[ $(stat -c '%U:%G %a' "$dst") == "$owner ${mode#0}" ]]; then
    log "$dst is unchanged"
    return 0
  fi
  run install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dst"
  CHANGED=1
  log "$dst changed; installed"
}

# pkg_installed <pkg>: no `grep -q` at the end of a pipe, which pipefail can trip.
pkg_installed() {
  local s
  s=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1
  [[ $s == "install ok installed" ]]
}

# apt_ensure <pkg>...: install whichever are missing; apt-get update only then.
apt_ensure() {
  local p missing=()
  for p in "$@"; do
    pkg_installed "$p" || missing+=("$p")
  done
  if ((${#missing[@]} == 0)); then
    log "already installed: $*"
    return 0
  fi
  run apt-get update
  # ℹ️ trixie's gpsd asks no debconf questions (its .deb has no templates or
  #    config script); /etc/default/gpsd is a plain conffile, rendered below.
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

# rtc_gate: the human gate. The step never edits the boot partition.
rtc_gate() {
  if [[ -e $RTC ]]; then
    log "$RTC exists"
    return 0
  fi
  warn "no $RTC: the DS3231 is not wired into boot"
  cat >&2 <<'EOF'
    Wiring the RTC into boot is done by hand, once. No script edits the boot
    partition (PLAN §9h). Add these two lines to config.txt on the boot
    partition (on Raspberry Pi OS, the FAT partition mounted at boot; see
    BUILD.md §6b):
        dtparam=i2c_arm=on
        dtoverlay=i2c-rtc,ds3231
    Check the module's charging circuit first (BUILD.md §6b, the ZS-042).
    Then reboot, and run this step again.
EOF
  die "no $RTC; add the two lines above and reboot"
}

# find_puck: exactly one device under /dev/serial/by-id. Sets PUCK. The by-id
# name is the adapter's own, so it survives a ttyUSB renumbering; it names this
# puck's serial number, which is why it is found here, not written in the repo.
PUCK=
find_puck() {
  local devs=()
  if [[ -d $BY_ID ]]; then
    shopt -s nullglob
    devs=("$BY_ID"/*)
    shopt -u nullglob
  fi
  log "ls $BY_ID (raw): ${devs[*]:-(none)}"
  ((${#devs[@]} > 0)) || die "nothing under $BY_ID: plug in the GPS puck"
  if ((${#devs[@]} > 1)); then
    printf '%s\n' "${devs[@]}" >&2
    die "${#devs[@]} serial devices under $BY_ID (listed above); unplug all but the GPS puck, then run this step again"
  fi
  PUCK=${devs[0]}
  log "the GPS puck: $PUCK -> $(readlink -f "$PUCK")"
}

render_gpsd() {
  cat >"$WORK/gpsd" <<EOF
# Rendered by setup/steps/20-portable-clock.sh. Do not edit; re-run the step.
# Read by gpsd.service as EnvironmentFile=. The values were set by hand on the
# portable rig on 2026-10-03.

# Devices gpsd should collect to at boot time.
# They need to be read/writeable, either by user gpsd or the group dialout.
# The puck by its /dev/serial/by-id/ name, found when the step ran.
DEVICES="$PUCK"

# Other options you want to pass to gpsd
#   -n        poll the puck with no client connected, so chrony's SHM refclock
#             has samples from boot
#   -b        read-only: gpsd never writes configuration to the puck
#   -s 4800   a fixed speed, instead of gpsd's auto-baud: the auto-baud trap,
#             queued for BUILD.md §6 and not yet written there. 4800 is what
#             the hand setup of 2026-10-03 ran, and gpsd reported 4800 bps.
GPSD_OPTIONS="-n -b -s 4800"

# Automatically hot add/remove USB GPS devices via gpsdctl
USBAUTO="true"
EOF
}

render_chrony() {
  cat >"$WORK/gps.conf" <<'EOF'
# Rendered by setup/steps/20-portable-clock.sh. Do not edit; re-run the step.
# gpsd's shared-memory segment 0, as a refclock named GPS. Set by hand on the
# portable rig on 2026-10-03.
#
# offset 0.203: the puck's NMEA lateness, in seconds, measured on THIS rig's
#   puck on 2026-10-03. ⚠️ Another puck needs its own value: measure it against
#   a good NTP source before trusting the number.
# delay 0.2: half of it counts in chrony's error bound, so a USB NMEA puck is
#   treated as good to about +/-0.1 s rather than as a precise clock.
refclock SHM 0 refid GPS offset 0.203 delay 0.2
EOF
}

install_gpsd() {
  render_gpsd
  install_if_changed "$WORK/gpsd" "$GPSD_DEFAULTS" 0644 root:root
  local changed=$CHANGED u
  # Both enabled, as on the Pi: the service runs gpsd from boot (-n needs no
  # client), and the socket is the package's own activation path.
  for u in gpsd.service gpsd.socket; do
    if [[ $(systemctl is-enabled "$u" 2>/dev/null) != enabled ]]; then
      unit enable "$u"
    fi
  done
  if ((changed)); then
    unit restart gpsd
  elif ! systemctl is-active --quiet gpsd; then
    unit start gpsd
  else
    log "gpsd is running and $GPSD_DEFAULTS did not change; not restarted"
  fi
}

install_chrony() {
  render_chrony
  install_if_changed "$WORK/gps.conf" "$CHRONY_GPS" 0644 root:root
  if ((CHANGED)); then
    unit restart chrony
  elif ! systemctl is-active --quiet chrony; then
    unit start chrony
  else
    log "chrony is running and $CHRONY_GPS did not change; not restarted"
  fi
}

timesyncd_state() {
  systemctl show -p LoadState --value systemd-timesyncd.service 2>/dev/null || true
}

# Inactive and masked. not-found satisfies that too: installing chrony removes
# the systemd-timesyncd package (it did on the Pi, 2026-10-03), and a unit that
# does not exist cannot start.
install_timesyncd() {
  local st
  st=$(timesyncd_state)
  case $st in
    not-found) log "systemd-timesyncd is not installed (LoadState not-found); nothing to mask" ;;
    masked)    log "systemd-timesyncd is masked" ;;
    *)
      unit stop systemd-timesyncd
      unit mask systemd-timesyncd ;;
  esac
}

install_preflight() {
  local src=$ADSB_REPO/bin/clock-preflight
  [[ -f $src ]] || die "$src is missing from this checkout"
  install_if_changed "$src" "$PREFLIGHT" 0755 root:root
}

install_step() {
  rtc_gate
  find_puck
  apt_ensure "${PKGS[@]}"
  install_gpsd
  install_chrony
  install_timesyncd
  install_preflight
}

# --- verify --------------------------------------------------------------------

# Hide the position in NMEA before printing it: the raw output gets pasted, and
# a position at home is a home address. The check reads the unredacted text.
redact_nmea() {
  sed -E 's/[0-9]{4}\.[0-9]+,[NS],[0-9]{5}\.[0-9]+,[EW]/<lat>,<N|S>,<lon>,<E|W>/g'
}

# gpsd_paths: the device paths in gpsd's DEVICES reports, one per line.
gpsd_paths() {
  python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    if msg.get("class") == "DEVICES":
        for d in msg.get("devices", []):
            if d.get("path"):
                print(d["path"])
' 2>/dev/null || true
}

# clock_disciplined: chrony has a real reference (not none, not local) and is
# synchronized. Used only to decide whether to compare the RTC to it.
clock_disciplined() {
  local t
  t=$(chronyc -n tracking 2>/dev/null) || return 1
  grep -qE '^Reference ID[[:space:]]*: (00000000|7F7F0101)' <<<"$t" && return 1
  ! grep -qE '^Leap status[[:space:]]*: Not synchronised' <<<"$t"
}

# The install tier (PLAN §9c): the chain is wired and delivering. Nothing here
# judges the fix or the offset, and nothing stops a service.
verify() {
  rtc_gate

  local t
  for t in gpspipe chronyc hwclock python3; do
    command -v "$t" >/dev/null || die "$t is not installed; run this step without --verify"
  done

  # 1. gpsd has the configured puck open, and NMEA arrives. Indoors a puck is
  #    believed to emit GGA with fix quality 0, which passes (unverified, PLAN
  #    §9c).
  local want want_real out paths p match=''
  want=$(sed -nE 's/^DEVICES="?([^"]*)"?[[:space:]]*$/\1/p' "$GPSD_DEFAULTS" 2>/dev/null | tail -n1) || true
  log "$GPSD_DEFAULTS: DEVICES=\"$want\""
  [[ -n $want ]] || die "$GPSD_DEFAULTS sets no DEVICES; run this step without --verify"
  [[ -e $want ]] || die "$want does not exist: plug in the GPS puck (or, a different puck: run this step without --verify)"
  want_real=$(realpath -- "$want")
  log "timeout 15 gpspipe -r -n 5 (raw output follows, positions redacted)"
  out=$(timeout 15 gpspipe -r -n 5 2>&1) || true
  redact_nmea <<<"$out"
  echo "----"
  # The configured path, or a hotplugged alias of it (a /dev/ttyUSB* that
  # USBAUTO added): compared after realpath. Any other device does not count.
  paths=$(gpsd_paths <<<"$out")
  log "gpsd reports these devices (raw): ${paths:-(none)}; the configured one resolves to $want_real"
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    if [[ $(realpath -- "$p" 2>/dev/null) == "$want_real" ]]; then
      match=$p
      break
    fi
  done <<<"$paths"
  [[ -n $match ]] \
    || die "gpsd does not have $want ($want_real) open. Check: systemctl status gpsd, and DEVICES in $GPSD_DEFAULTS"
  grep -qE '^\$[A-Z]{5},' <<<"$out" \
    || die "gpsd has $match open, but no NMEA arrived in 15 s. Check that $want is the puck"
  pass "gpsd has $want open (reported as $match), and NMEA arrives"

  # 2. chrony lists the GPS refclock, whatever its reach (believed: a refclock
  #    with reach 0 is still listed before its first sample; unverified).
  log "chronyc -n sources (raw output follows)"
  out=$(chronyc -n sources 2>&1) || true
  printf '%s\n' "$out"
  echo "----"
  grep -qE '^#.[[:space:]]+GPS[[:space:]]' <<<"$out" \
    || die "chronyc sources lists no GPS refclock. Check $CHRONY_GPS, and that chrony.conf has 'confdir /etc/chrony/conf.d'"
  pass "chrony lists the GPS refclock"

  # 3. The RTC holds the time. How it reaches the system clock at boot is
  #    printed, not judged (this file's header).
  log "/sys/class/rtc/rtc0: name $(cat /sys/class/rtc/rtc0/name 2>/dev/null || echo '?'), hctosys $(cat /sys/class/rtc/rtc0/hctosys 2>/dev/null || echo '?') (raw, not judged)"
  log "chrony.conf rtcsync line (raw, not judged): $(grep -E '^[[:space:]]*rtcsync' /etc/chrony/chrony.conf 2>/dev/null || echo '(none)')"
  log "hwclock -r -f $RTC; date (raw output follows)"
  out=$(hwclock -r -f "$RTC" 2>&1) || true
  printf '%s\n' "$out"
  date --iso-8601=seconds
  echo "----"
  local year rtc_s sys_s skew
  year=$(grep -oE '^[0-9]{4}' <<<"$out" | head -n1) || true
  [[ -n $year ]] || die "hwclock could not read $RTC; check the wiring and the coin cell (BUILD.md §6b)"
  ((10#$year >= RTC_YEAR_FLOOR)) \
    || die "the RTC reads year $year: a dead or missing coin cell, or never set. Once the system clock is right, chrony's rtcsync is believed to write it back"
  if clock_disciplined; then
    rtc_s=$(date -d "$(head -n1 <<<"$out")" +%s 2>/dev/null) || rtc_s=
    sys_s=$(date +%s)
    if [[ -z $rtc_s ]]; then
      warn "could not parse hwclock's time, so it is not compared to the system clock"
    else
      skew=$((rtc_s - sys_s))
      ((skew < 0)) && skew=$((-skew))
      log "RTC against the disciplined system clock: ${skew} s apart"
      if ((skew > RTC_MAX_SKEW_S)); then
        warn "the RTC is ${skew} s from the disciplined system clock (more than ${RTC_MAX_SKEW_S} s). After a boot it should agree within seconds; chrony's rtcsync is believed to correct it within 11 minutes"
      fi
    fi
  else
    log "the system clock is not disciplined, so the RTC is not compared to it"
  fi
  pass "the RTC reads a time (year $year)"

  # 4. systemd-timesyncd: masked, or not installed at all.
  local st ac
  st=$(timesyncd_state)
  ac=$(systemctl show -p ActiveState --value systemd-timesyncd.service 2>/dev/null) || true
  log "systemd-timesyncd: LoadState=${st:-?} ActiveState=${ac:-?}"
  case $st in
    masked|not-found) ;;
    *) die "systemd-timesyncd is '$st', not masked; run this step without --verify" ;;
  esac
  [[ $ac == inactive ]] || die "systemd-timesyncd is $ac; it must be inactive"
  pass "systemd-timesyncd is $st and inactive"

  # 5. The readiness tier: 0 and 2 pass the install tier, 1 fails it (PLAN §9c, §9i).
  local rc=0
  [[ -x $PREFLIGHT ]] || die "$PREFLIGHT is not installed; run this step without --verify"
  log "$PREFLIGHT (raw output follows)"
  "$PREFLIGHT" || rc=$?
  echo "----"
  case $rc in
    0) pass "clock-preflight: exit 0; see its output above" ;;
    2) warn "clock-preflight: not ready (exit 2); see its output above"
       pass "clock-preflight ran (exit 2 passes the install tier, PLAN §9c)" ;;
    *) die "clock-preflight could not run its check (exit $rc); see its output above" ;;
  esac
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
