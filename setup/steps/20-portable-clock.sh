#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 20-portable-clock: gpsd on the GPS puck, chrony disciplined by it, the DS3231
# RTC checked, systemd-timesyncd out of the way, bin/clock-preflight
# installed with its keys, and a timer that asks chrony for a burst of NTP
# samples every 15 minutes. BUILD.md §6 and §8 step 2; PLAN §9c.
#
# The burst timer (Chris, 2026-11-12 21:08): adsb-chrony-burst.timer starts
# adsb-chrony-burst.service every 15 minutes, a oneshot running
# `/usr/bin/chronyc burst 2/8` as _chrony. By chronyc(1)'s burst good/max, read
# in chrony 4.8's man page on a workstation, not the rig's 4.6.1: up to 8
# measurements of each NTP source, stopping once 2 are good. The reason: at
# home the rig's NTP sources are the DHCP-provided servers, reached over the
# home Wi-Fi, where a reply after the link has been idle can be held up by as
# much as about 100 ms. The record of 2026-11-12 21:08 names the test those
# samples fail as chrony's delay-dev-ratio test (read from `chronyc ntpdata`'s
# test bits by the order chrony 4.6's docs list them), so with one sample per
# poll the reference stopped updating for hours. A burst gives chrony several
# draws in a row, while the link is awake.
#   - Fixed arguments; it parses no output. As _chrony because chronyd accepts
#     burst only on its Unix command socket, /run/chrony/chronyd.sock, in a
#     directory that is _chrony's, 0700; chronyc run as any other user falls
#     back to UDP on localhost, where burst is refused.
#   - Every 15 minutes by OnBootSec=5min and OnUnitActiveSec=15min, monotonic
#     time, not OnCalendar=: the wall clock is what chrony is correcting, and a
#     step in it would move a calendar timer. No RandomizedDelaySec=: one rig,
#     nothing to spread.
#   - The sandbox, each setting kept because chronyc is believed to still work
#     under it: NoNewPrivileges=yes; CapabilityBoundingSet= empty (_chrony
#     needs no capability to talk to its own socket); ProtectSystem=strict with
#     ReadWritePaths=-/run/chrony, because chronyc binds its own reply socket,
#     chronyc.<pid>, beside chronyd.sock ("%s/chronyc.%d" is in the strings of
#     a chronyc 4.8 binary on a workstation; the rig's 4.6.1 was not read), so
#     a read-only /run would break it. Its "-" is systemd's "ignore if
#     missing" (systemd.exec(5)): with chrony stopped or restarting,
#     /run/chrony may be absent, and without the "-" systemd is believed to
#     fail to build the namespace before chronyc runs; with it, chronyc runs
#     and finds no socket. ProtectHome=yes, PrivateTmp=yes and
#     PrivateDevices=yes, none of which it reads; and
#     RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6, the socket and its
#     localhost fallback. TimeoutStartSec=30s bounds a chronyc that hangs.
#     ⚠️ Not run under this sandbox on a Pi when written.
#   - ExecStart= carries systemd's "-" prefix (Chris, 2026-11-13 21:24, the
#     option "A refused burst isn't a failure"), so chronyc failing does not
#     fail the run. ⚠️ Belief, not seen on a Pi: in the field the NTP sources
#     stay in chrony's table, offline (PLAN §5's note on the 12-minute GPS
#     takeover: "sources marked offline keep their samples", a docs agent's
#     reading of chrony 4.6.1's source), and a burst asks them anyway, to no
#     answer (chronyc(1): after a burst an offline source reverts to
#     offline); with no NTP source known to chrony at all, burst is believed
#     to be answered "503 No such source", with chronyc exiting non-zero.
#     Either way the run succeeds, so a burst refused in the field no longer
#     fails the next update's verify.
#     What still fails the run: a timeout (TimeoutStartSec=). What no longer
#     does, seen on a workstation's systemd 259 with "-", not on the rig's: a
#     non-zero exit, a kill by a signal (SIGSEGV), and an executable that
#     cannot be run (exit 203, a failure while systemd sets up the process).
#     Not seen: a sandbox that cannot be set up (a 226/NAMESPACE exit, say);
#     it is believed to end as the exit 203 did, since both are the process
#     failing before chronyc runs, but that was not probed (a user manager
#     builds no such namespace). If it does, a broken sandbox no longer fails
#     the unit either: the accepted cost. The proof that bursts
#     work is the overnight read step 0d already requires: the reference's age
#     at every clock event, and the timer's journal showing chrony accepting
#     bursts at home.
#   - The verify checks the units (they match their render, load and pass
#     systemd-analyze), that the timer is enabled and active, and that the
#     service's last run this boot ended Result=success. It never starts a
#     burst itself, and judges no sample, offset or source (PLAN §9c: never
#     the sky). With "-", Result=success holds whatever chronyc exited with;
#     chronyc's own status, ExecMainStatus, is printed and not judged, so the
#     verify does not read whether chrony accepted a burst. systemd keeps a
#     unit's last run for the current boot only, so "last run" is this boot's;
#     the active timer keeps the service loaded, so its last run stays
#     readable (seen on the same workstation: an inactive oneshot that nothing
#     referenced was unloaded and its run forgotten; one an active timer
#     referenced kept its run).
#   - No run to judge passes, and says so: a fresh install whose timer has not
#     fired yet, the first 5 minutes after a boot, or a run still going when
#     the verify reads it. Failing those would hold an update for something
#     the timer does within minutes, and the verify may not start a run to
#     find out. The next verify judges the run that follows.
#
# The preflight's keys (Chris, 2026-11-12 01:02): clock.max_offset_ms,
# clock.require_disciplined and clock.source are rendered from station.yml,
# which is root-only, into /etc/adsb-receiver/clock.conf, root:root 0644, so
# clock-preflight runs as any user: tools/pull-archive --end-session runs it
# over ssh with no sudo, and bin/adsb-writer reads clock.max_offset_ms from it.
# Rendered before the preflight is installed, so a new preflight never finds
# the file missing. An edit to those keys in station.yml takes effect at this
# step's next run: on a recording rig, that is the next update window (the home
# opener's, a pull with --end-session, or one opened by hand), since the timer
# finds the recording lock held. The verify fails while the file and
# station.yml disagree, and checks that a user with no privilege at all
# (nobody, through setpriv) can read it.
# The format: comment lines, then key=value lines separated by "\n" only, each
# key once. max_offset_ms is a plain decimal (digits, at most one point and
# more digits: no sign, exponent, underscore or space), which the readers
# require.
#
# Portable only: asserts station.role, refuses a position: block, and refuses
# any clock.source but gps (PLAN §9b).
#
#   setup/steps/20-portable-clock.sh            install, then verify
#   setup/steps/20-portable-clock.sh --verify   verify only
#
# What this encodes: the values set by hand on the portable rig on
# 2026-10-03. What has run on hardware is recorded in PLAN §9m, not here (PLAN
# §9c: no script carries a "tested on" header).
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
#    §9h denylist. With no /dev/rtc0 it fails. The overlay is written by the
#    bootstrap's foundation tier (setup/foundation/rtc-overlay.sh, run only by
#    update.sh --bootstrap on a portable's first build, never by the timer).
#    The bootstrap then reboots once, and the update timer runs this step again
#    after the boot. ⚠️ Belief, not seen through this path (PLAN §9e): that
#    reboot makes rtc0 appear. The ZS-042's charge-path fix (BUILD.md §6b) is a
#    hardware-assembly step, not software: nothing here checks it.
#    Corrected 2026-10-10: on a recording 🎒 portable the update timer does not
#    run this step again after the boot. The writer starts at boot and holds the
#    recording lock, so each timer run finds it held and exits; a pull window
#    finishes the build (PLAN §9e, "First-build mode", its 2026-10-05
#    correction). The timer still does on a build that installed no writer,
#    because then nothing holds the lock. The belief above is still untested: the bootstraps on the
#    portable found /dev/rtc0 already present, so this path was not exercised.
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
# Copied, not symlinked: update.sh flips between two worktrees (PLAN §9f), and
# a symlink into one would follow the flip.
PREFLIGHT=/usr/local/bin/clock-preflight
CLOCK_CONF=$ADSB_ETC/clock.conf
UNIT_DIR=/etc/systemd/system
BURST_SERVICE=adsb-chrony-burst.service
BURST_TIMER=adsb-chrony-burst.timer

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# install_if_changed <src> <dst> <mode> <owner:group>: render, diff, install
# (PLAN §9f). Installs only when the content, mode or owner differs, and logs
# which. Sets CHANGED to 0 or 1. For every file this step installs (gpsd's
# defaults, chrony's gps.conf, clock.conf, the preflight and the burst units): by a temporary
# file in the destination's directory and a rename (step 60's), so a reader
# running meanwhile (the writer's ExecStartPre=, a pull's preflight over ssh,
# chrony or gpsd starting) sees the old file or the new one whole, never a
# half-written one; on a first install the file is absent until the rename. The rename is atomic for readers only: nothing
# here fsyncs, so what a power cut right after the install leaves on disk is
# the filesystem's to decide. The temporary name ends in "~", which run-parts, sudo's
# includedir and chrony's conf.d (*.conf) all skip; one left by a killed run is
# removed first.
CHANGED=0
install_if_changed() {
  local src=$1 dst=$2 mode=$3 owner=$4 tmp
  guard_path "$dst"
  CHANGED=0
  if [[ -f $dst ]] && cmp -s "$src" "$dst" \
     && [[ $(stat -c '%U:%G %a' "$dst") == "$owner ${mode#0}" ]]; then
    log "$dst is unchanged"
    return 0
  fi
  tmp=$(dirname "$dst")/.$(basename "$dst").adsb-new~
  rm -f -- "$tmp"
  run install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$tmp" \
    || { rm -f -- "$tmp"; die "could not write $tmp; $dst was not changed"; }
  run mv -f "$tmp" "$dst" || { rm -f -- "$tmp"; die "could not rename $tmp to $dst; $dst was not changed"; }
  CHANGED=1
  log "$dst changed; installed by rename"
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

# rtc_gate: no /dev/rtc0 fails the step. The step never edits the boot partition.
rtc_gate() {
  if [[ -e $RTC ]]; then
    log "$RTC exists"
    return 0
  fi
  warn "no $RTC: the DS3231 is not wired into boot"
  cat >&2 <<'EOF'
    No step edits the boot partition (PLAN §9h). On a first build, the
    bootstrap's setup/foundation/rtc-overlay.sh writes the RTC overlay into
    config.txt and the bootstrap reboots once; /dev/rtc0 is expected after
    that boot, and the update timer then runs this step again, unless the
    archive writer is recording: then every timer run finds the recording
    lock held and skips, and a pull window runs this step again.
    A rig built before the bootstrap existed never runs that script: add
    dtparam=i2c_arm=on and dtoverlay=i2c-rtc,ds3231 to config.txt on the boot
    partition, under [all], by hand (BUILD.md §6b), then reboot.
    If the overlay is in config.txt, the rig has rebooted since, and there is
    still no rtc0, check the board's wiring (BUILD.md §6b). The charge-path
    fix in BUILD.md §6b is a hardware-assembly step, not software.
EOF
  die "no $RTC: the RTC is not wired into boot yet (see above)"
}

# find_puck: the GPS puck's path. Sets PUCK. The DEVICES path that
# $GPSD_DEFAULTS already configures wins while it exists: a built rig keeps its
# puck when a second USB-serial adapter is plugged in, where "exactly one"
# would hold every update at this step although gpsd has its puck (a review,
# 2026-10-15). Only with nothing configured, or the configured device gone, is
# the puck found as exactly one device under /dev/serial/by-id. The by-id name
# is the adapter's own, so it survives a ttyUSB renumbering; it names this
# puck's serial number, which is why it is found here, not written in the repo.
PUCK=
find_puck() {
  local devs=() conf
  # The same read as the verify's.
  conf=$(sed -nE 's/^DEVICES="?([^"]*)"?[[:space:]]*$/\1/p' "$GPSD_DEFAULTS" 2>/dev/null | tail -n1) || true
  if [[ -n $conf && -e $conf ]]; then
    PUCK=$conf
    log "the GPS puck, as $GPSD_DEFAULTS configures it: $PUCK -> $(readlink -f "$PUCK")"
    return 0
  fi
  if [[ -n $conf ]]; then
    log "$GPSD_DEFAULTS configures DEVICES=\"$conf\", which does not exist now; looking under $BY_ID"
  fi
  if [[ -d $BY_ID ]]; then
    shopt -s nullglob
    devs=("$BY_ID"/*)
    shopt -u nullglob
  fi
  log "ls $BY_ID (raw): ${devs[*]:-(none)}"
  ((${#devs[@]} > 0)) || die "nothing under $BY_ID: plug in the GPS puck${conf:+ (the configured one is $conf)}"
  if ((${#devs[@]} > 1)); then
    printf '%s\n' "${devs[@]}" >&2
    if [[ -n $conf ]]; then
      die "${#devs[@]} serial devices under $BY_ID (listed above), and the configured $conf is not among them. Plug that puck back in (this step accepts $conf whatever else is plugged in), or unplug all but the GPS puck you mean, then run this step again"
    fi
    die "${#devs[@]} serial devices under $BY_ID (listed above), and $GPSD_DEFAULTS configures none; unplug all but the GPS puck, then run this step again"
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
# offset 0.203: chrony's refclock offset, in seconds, meant to compensate the
#   NMEA's lateness. Set by hand on this rig on 2026-10-03; how it was derived
#   is not recorded. As of 2026-10-11 the puck on this rig is a GlobalSat
#   BU-353N. A spot check on 2026-10-11, not a measurement of the offset:
#   with it applied, `chronyc sources` showed the GPS refclock's last sample
#   at -2.3 ms (about 13:27Z, the NTP server online and selected; the only
#   reading against a clock NTP was steering), then -6.8 ms (about 13:29Z)
#   and -3.9 ms (about 13:38Z), both with the NTP sources offline and the
#   clock coasting on the server's last correction, before chrony selected
#   the GPS. ⚠️ Another puck may need its own value: measure it against a
#   good NTP source before trusting it.
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

# render_clock_conf: the three keys, from station.yml, into $WORK/clock.conf;
# dies if they are missing or invalid. max_offset_ms must be a positive, finite
# number (not a boolean) and require_disciplined true or false: the checks
# clock-preflight applied to station.yml before 2026-11-12, and applies to
# clock.conf now. Added here, not in the old preflight: source, text or empty,
# with no character a line reader could split on or a terminal act on (C0,
# DEL, C1, U+2028, U+2029); this step accepts only gps for it anyway (above).
# max_offset_ms is written as a plain decimal, which is all the readers accept.
render_clock_conf() {
  local f
  f=$(station_file) || die "no station.yml: run setup/steps/05-config.sh"
  python3 - "$f" >"$WORK/clock.conf" <<'PY' \
    || die "station.yml's clock: block is not valid for clock-preflight (above); fix it, then run this step again"
import decimal, math, re, sys, yaml
with open(sys.argv[1]) as fh:
    doc = yaml.safe_load(fh)
clock = doc.get("clock") if isinstance(doc, dict) else None
if not isinstance(clock, dict):
    sys.exit("station.yml has no clock: block")
m, r, s = clock.get("max_offset_ms"), clock.get("require_disciplined"), clock.get("source")
# bool is an int in Python; a YAML true is not a number of milliseconds. YAML
# also parses .inf and .nan as floats.
if isinstance(m, bool) or not isinstance(m, (int, float)) or not math.isfinite(m) or m <= 0:
    sys.exit(f"clock.max_offset_ms must be a positive, finite number, not {m!r}")
if not isinstance(r, bool):
    sys.exit(f"clock.require_disciplined must be true or false, not {r!r}")
s = s if isinstance(s, str) else ""
if re.search("[\x00-\x1f\x7f-\x9f\u2028\u2029]", s):
    sys.exit("clock.source holds a control or line-separator character")
print("# Rendered by setup/steps/20-portable-clock.sh from station.yml's clock: block.")
print("# Do not edit; edit station.yml and re-run the step. Read by clock-preflight and adsb-writer.")
# A plain decimal, never repr()'s exponent form (1e-05, 1e+16): the readers accept nothing else.
plain = str(m) if isinstance(m, int) else format(decimal.Decimal(repr(m)), "f")
if not re.fullmatch(r"[0-9]+(\.[0-9]+)?", plain):
    sys.exit(f"clock.max_offset_ms {m!r} does not render as a plain decimal")
print(f"max_offset_ms={plain}")
print(f"require_disciplined={'true' if r else 'false'}")
print(f"source={s}")
PY
}

install_clock_conf() {
  render_clock_conf
  install_if_changed "$WORK/clock.conf" "$CLOCK_CONF" 0644 root:root
}

install_preflight() {
  local src=$ADSB_REPO/bin/clock-preflight
  [[ -f $src ]] || die "$src is missing from this checkout"
  install_if_changed "$src" "$PREFLIGHT" 0755 root:root
}

render_burst_service() {
  cat >"$WORK/burst.service" <<'EOF'
# Rendered by setup/steps/20-portable-clock.sh. Do not edit; re-run the step.
# Asks chrony for a burst of samples from each NTP source; the timer starts it
# every 15 minutes. Why, why each sandbox setting, and why "-" on ExecStart=
# (chronyc failing does not fail the run), in the step's header.
[Unit]
Description=adsb-receiver chrony burst: several NTP samples in a row (portable)
After=chrony.service

[Service]
Type=oneshot
User=_chrony
ExecStart=-/usr/bin/chronyc burst 2/8
TimeoutStartSec=30s
NoNewPrivileges=yes
CapabilityBoundingSet=
ProtectSystem=strict
ReadWritePaths=-/run/chrony
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
EOF
}

render_burst_timer() {
  cat >"$WORK/burst.timer" <<'EOF'
# Rendered by setup/steps/20-portable-clock.sh. Do not edit; re-run the step.
# 5 min after boot, then 15 min after each run started: monotonic time, so a
# step in the wall clock does not move it (the step's header).
[Unit]
Description=adsb-receiver chrony burst timer, every 15 minutes (portable)

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF
}

# burst_need_reload: a burst unit changed on disk since systemd read it.
burst_need_reload() {
  local u
  for u in "$BURST_SERVICE" "$BURST_TIMER"; do
    [[ $(systemctl show -p NeedDaemonReload --value "$u" 2>/dev/null) == yes ]] && return 0
  done
  return 1
}

# The timer is enabled and started, by hand and under update.sh alike: what it
# starts is a burst, harmless at any moment, unlike the timers of steps 50 and
# 70. A timer started after its OnBootSec= has passed is believed to elapse at
# once (step 70's header), which is one burst.
install_burst() {
  local svc_changed timer_changed
  render_burst_service
  render_burst_timer
  install_if_changed "$WORK/burst.service" "$UNIT_DIR/$BURST_SERVICE" 0644 root:root
  svc_changed=$CHANGED
  install_if_changed "$WORK/burst.timer" "$UNIT_DIR/$BURST_TIMER" 0644 root:root
  timer_changed=$CHANGED
  if ((svc_changed || timer_changed)) || burst_need_reload; then
    run systemctl daemon-reload
  fi
  if ! systemctl is-enabled --quiet "$BURST_TIMER"; then
    unit enable "$BURST_TIMER"
  fi
  if ! systemctl is-active --quiet "$BURST_TIMER"; then
    unit start "$BURST_TIMER"
  elif ((timer_changed)); then
    unit restart "$BURST_TIMER"
  fi
}

install_step() {
  rtc_gate
  find_puck
  apt_ensure "${PKGS[@]}"
  install_gpsd
  install_chrony
  install_timesyncd
  install_clock_conf
  install_preflight
  install_burst
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
  for t in gpspipe chronyc hwclock python3 systemd-analyze; do
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

  # 5. The preflight's keys: the installed file is what station.yml renders now.
  local rc
  render_clock_conf
  [[ -f $CLOCK_CONF ]] || die "$CLOCK_CONF is missing; run this step without --verify"
  cmp -s "$WORK/clock.conf" "$CLOCK_CONF" \
    || die "$CLOCK_CONF differs from what station.yml's clock: block renders now; run this step without --verify"
  [[ $(stat -c '%U:%G %a' "$CLOCK_CONF") == "root:root 644" ]] \
    || die "$CLOCK_CONF is not root:root 0644; run this step without --verify"
  pass "$CLOCK_CONF matches station.yml's clock: block, root:root 0644"
  # Readable with no privilege at all, the ruled purpose (pull-archive --end-session runs the
  # preflight as a login, with no sudo). Only the read is proven here, as nobody: not the
  # preflight, whose chronyc may fail for reasons of its own (chrony may have just restarted above), and a
  # failed verify holds every later update.
  [[ -x $PREFLIGHT ]] || die "$PREFLIGHT is not installed; run this step without --verify"
  command -v setpriv >/dev/null || die "setpriv (util-linux) is not installed, so whether a plain user can read $CLOCK_CONF cannot be checked"
  setpriv --reuid=nobody --regid=nogroup --clear-groups cat -- "$CLOCK_CONF" >/dev/null \
    || die "nobody cannot read $CLOCK_CONF, so a login without sudo (tools/pull-archive --end-session) could not run the preflight either. Check: ls -ld $ADSB_ETC $CLOCK_CONF"
  pass "$CLOCK_CONF is readable by nobody (setpriv)"

  # 6. The readiness tier: 0 and 2 pass the install tier, 1 fails it (PLAN §9c, §9i).
  rc=0
  log "$PREFLIGHT (raw output follows)"
  "$PREFLIGHT" || rc=$?
  echo "----"
  case $rc in
    0) pass "clock-preflight: exit 0; see its output above" ;;
    2) warn "clock-preflight: not ready (exit 2); see its output above"
       pass "clock-preflight ran (exit 2 passes the install tier, PLAN §9c)" ;;
    *) die "clock-preflight could not run its check (exit $rc); see its output above" ;;
  esac

  # 7. The burst timer: both units are this checkout's and load, the timer is
  #    enabled and active, and the service's last run this boot ended
  #    Result=success (the header). Nothing here starts a burst, or judges a
  #    sample, an offset or a source's reach.
  local en t_ac svc s_active s_result s_status s_started
  render_burst_service
  render_burst_timer
  cmp -s "$WORK/burst.service" "$UNIT_DIR/$BURST_SERVICE" \
    || die "$UNIT_DIR/$BURST_SERVICE is missing or differs from its render; run this step without --verify"
  cmp -s "$WORK/burst.timer" "$UNIT_DIR/$BURST_TIMER" \
    || die "$UNIT_DIR/$BURST_TIMER is missing or differs from its render; run this step without --verify"
  rc=0
  log "systemd-analyze verify $BURST_SERVICE $BURST_TIMER (raw output follows)"
  out=$(systemd-analyze verify "$UNIT_DIR/$BURST_SERVICE" "$UNIT_DIR/$BURST_TIMER" 2>&1) || rc=$?
  printf '%s\n' "${out:-(no output)}"
  echo "----"
  ((rc == 0)) || die "systemd-analyze verify rejected the burst units (exit $rc); see above"
  [[ $(systemctl show -p LoadState --value "$BURST_SERVICE" 2>/dev/null) == loaded ]] \
    || die "$BURST_SERVICE is not loaded; run this step without --verify"
  ! burst_need_reload \
    || die "systemd has not read the current $BURST_SERVICE or $BURST_TIMER (NeedDaemonReload=yes); run this step without --verify"
  en=$(systemctl is-enabled "$BURST_TIMER" 2>&1) || true
  t_ac=$(systemctl is-active "$BURST_TIMER" 2>&1) || true
  log "$BURST_TIMER: is-enabled $en, is-active $t_ac"
  [[ $en == enabled ]] || die "$BURST_TIMER is '$en', not enabled; run this step without --verify"
  [[ $t_ac == active ]] || die "$BURST_TIMER is '$t_ac', not active; run this step without --verify"
  pass "$BURST_SERVICE and $BURST_TIMER match their render and load; the timer is enabled and active"
  # The last run, as systemd recorded it; read, never started here.
  # ExecMainStartTimestampMonotonic is 0 when the service has not run this boot.
  # With "-" on ExecStart=, Result=success whatever chronyc exited with, and a
  # timeout is Result=timeout; ExecMainStatus is chronyc's own status, printed
  # and not judged (the header).
  svc=$(LC_ALL=C systemctl show -p ActiveState -p Result -p ExecMainStatus \
          -p ExecMainStartTimestampMonotonic -p ExecMainExitTimestamp "$BURST_SERVICE" 2>&1) \
    || die "systemctl show $BURST_SERVICE failed (a systemctl failure, not a failed burst): $svc"
  log "systemctl show $BURST_SERVICE (raw output follows)"
  printf '%s\n' "$svc"
  echo "----"
  s_active=$(sed -n 's/^ActiveState=//p' <<<"$svc")
  s_result=$(sed -n 's/^Result=//p' <<<"$svc")
  s_status=$(sed -n 's/^ExecMainStatus=//p' <<<"$svc")
  s_started=$(sed -n 's/^ExecMainStartTimestampMonotonic=//p' <<<"$svc")
  if [[ $s_active == activating ]]; then
    pass "$BURST_SERVICE is running now; that run is not judged here, and the next verify judges its result"
  elif [[ -z $s_started || $s_started == 0 ]]; then
    pass "$BURST_SERVICE has not run since boot (a fresh install, or under 5 min since boot): no run to judge yet; the next verify judges its first"
  elif [[ $s_result == success ]]; then
    pass "$BURST_SERVICE's last run ended Result=success. Not read: whether chrony accepted that burst (chronyc's own status, ExecMainStatus=${s_status:-?}, is not judged: \"-\" on ExecStart=, the header)"
  else
    die "$BURST_SERVICE's last run did not succeed (Result=${s_result:-?}; above): with \"-\" on ExecStart=, chronyc's own exit does not fail it, so this is a timeout or systemd's own failure. Check: journalctl -u $BURST_SERVICE -n 20; systemctl status chrony; ls -ld /run/chrony"
  fi
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
