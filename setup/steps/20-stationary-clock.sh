#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 20-stationary-clock: chrony on NTP only, systemd-timesyncd out of the way,
# bin/clock-preflight installed with its keys, and, on Wi-Fi only, the burst
# timer of 20-portable-clock. PLAN §9h, A3 of #33 (2026-11-14), and B5;
# PLAN §9b rules this step by name.
#
# NTP only (A3): no gpsd, no RTC overlay, no refclock. chrony keeps Debian's
# own sources (its pool line and the DHCP-provided servers); this step adds no
# chrony configuration at all, so it restarts chrony never, and starts it only
# if it is not running. The bar is clock.max_offset_ms, 500 by A3, rendered into
# /etc/adsb-receiver/clock.conf exactly as 20-portable-clock renders it (the
# same keys, format and checks; tests/test_clock_agreement.py feeds step 20's
# render to clock-preflight, and this one's is the same code).
#
# The burst timer, on Wi-Fi only (B5 of #33: "A3's bar holds, with the burst
# timer only on Wi-Fi"; A3: no burst timer on a wired rig). The units, their
# sandbox and their verify are 20-portable-clock's, with the same names
# (adsb-chrony-burst.service and .timer); why each setting is what it is is
# in that step's header and is not repeated here. "On Wi-Fi" is read when the
# step runs: the interface of the IPv4 default route (`ip -4 route show
# default`, the first one) is wireless if /sys/class/net/<it>/wireless exists.
# ⚠️ Belief, not checked on the Pi 4: that its wlan0 has that directory (it is
#    the kernel's cfg80211 marker on Linux Wi-Fi drivers generally). With no
#    default route, the step keeps what it finds and says so, rather than
#    deciding wired or wireless on no evidence. On a wired rig the units are
#    stopped, disabled and removed. The stand-in home stationary is on Wi-Fi
#    (PLAN §9i's 2026-11-22 update).
#
# Stationary only: asserts station.role, and refuses any clock.source but ntp
# (PLAN §9b). It no longer refuses an uploader: block: the uploader landed with
# this step (PLAN §9i's 2026-11-22 update), which is the change PLAN §9b and
# the template's old closing comment named.
#
#   setup/steps/20-stationary-clock.sh            install, then verify
#   setup/steps/20-stationary-clock.sh --verify   verify only
#
# Nothing in this step has run on hardware; what has is recorded in PLAN §9h
# and §9i, not here (PLAN §9c).
# ⛔ The verify never judges the sky or the network (offset, reach): that is
#    clock-preflight's job, whose exit 2 passes the install tier (PLAN §9c).

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"
require_role stationary

CLOCK_SOURCE=$(station_get clock.source) \
  || die "station.yml has no clock.source: add the clock: block from config/station.stationary.example.yml"
[[ $CLOCK_SOURCE == ntp ]] \
  || die "clock.source is '${CLOCK_SOURCE}'; the stationary rig takes time from ntp, and only ntp (A3 of #33, PLAN §9h)"

PKGS=(chrony util-linux iproute2)
# Copied, not symlinked: update.sh flips between two worktrees (PLAN §9f).
PREFLIGHT=/usr/local/bin/clock-preflight
CLOCK_CONF=$ADSB_ETC/clock.conf
UNIT_DIR=/etc/systemd/system
BURST_SERVICE=adsb-chrony-burst.service
BURST_TIMER=adsb-chrony-burst.timer

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# install_if_changed <src> <dst> <mode> <owner:group>: render, diff, install
# (PLAN §9f). Installs only when the content, mode or owner differs, and logs
# which. Sets CHANGED to 0 or 1. For every file this step installs (clock.conf,
# the preflight and the burst units): by a temporary
# file in the destination's directory and a rename (step 60's), so a reader
# running meanwhile (the writer's ExecStartPre=, a preflight run by hand)
# sees the old file or the new one whole, never a
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
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

# install_chrony: running and enabled. No configuration of this step's: NTP is
# Debian's chrony.conf as shipped (A3).
install_chrony() {
  if [[ $(systemctl is-enabled chrony 2>/dev/null) != enabled ]]; then
    unit enable chrony
  fi
  if systemctl is-active --quiet chrony; then
    log "chrony is running; not restarted (this step configures none of it)"
  else
    unit start chrony
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
# DEL, C1, U+2028, U+2029); this step accepts only ntp for it anyway (above).
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
print("# Rendered by setup/steps/20-stationary-clock.sh from station.yml's clock: block.")
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
# Rendered by setup/steps/20-stationary-clock.sh. Do not edit; re-run the step.
# Asks chrony for a burst of samples from each NTP source; the timer starts it
# every 15 minutes. Why, why each sandbox setting, and why "-" on ExecStart=
# (chronyc failing does not fail the run), in 20-portable-clock's header.
[Unit]
Description=adsb-receiver chrony burst: several NTP samples in a row (stationary, Wi-Fi)
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
# Rendered by setup/steps/20-stationary-clock.sh. Do not edit; re-run the step.
# 5 min after boot, then 15 min after each run started: monotonic time, so a
# step in the wall clock does not move it (20-portable-clock's header).
[Unit]
Description=adsb-receiver chrony burst timer, every 15 minutes (stationary, Wi-Fi)

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

# on_wifi: prints wifi, wired or unknown, from the IPv4 default route's
# interface (the header). Prints its evidence to stderr.
on_wifi() {
  local route dev
  route=$(ip -4 route show default 2>/dev/null | head -n1) || route=''
  dev=$(sed -nE 's/.* dev ([^ ]+).*/\1/p' <<<"$route")
  if [[ -z $dev ]]; then
    printf '==> no IPv4 default route (ip -4 route show default: %s)\n' "${route:-(none)}" >&2
    echo unknown
    return 0
  fi
  if [[ -e /sys/class/net/$dev/wireless ]]; then
    printf '==> the default route is on %s, which is wireless (/sys/class/net/%s/wireless)\n' "$dev" "$dev" >&2
    echo wifi
  else
    printf '==> the default route is on %s, which is not wireless (no /sys/class/net/%s/wireless)\n' "$dev" "$dev" >&2
    echo wired
  fi
}

# burst_present: either burst unit file is installed.
burst_present() {
  [[ -e $UNIT_DIR/$BURST_SERVICE || -e $UNIT_DIR/$BURST_TIMER ]]
}

# remove_burst: a wired rig carries no burst timer (A3). Stopped, disabled,
# and its files removed; a run of the service under way is let finish.
remove_burst() {
  if ! burst_present; then
    log "no burst units installed, as a wired rig should have"
    return 0
  fi
  if systemctl is-active --quiet "$BURST_TIMER"; then
    unit stop "$BURST_TIMER"
  fi
  if systemctl is-enabled --quiet "$BURST_TIMER" 2>/dev/null; then
    unit disable "$BURST_TIMER"
  fi
  guard_path "$UNIT_DIR/$BURST_TIMER"
  guard_path "$UNIT_DIR/$BURST_SERVICE"
  run rm -f -- "$UNIT_DIR/$BURST_TIMER" "$UNIT_DIR/$BURST_SERVICE"
  run systemctl daemon-reload
}

LINK=''
install_step() {
  apt_ensure "${PKGS[@]}"
  install_chrony
  install_timesyncd
  install_clock_conf
  install_preflight
  LINK=$(on_wifi)
  case $LINK in
    wifi)  install_burst ;;
    wired) remove_burst ;;
    *)     warn "no default route, so whether this rig is on Wi-Fi is not known; the burst units are left as they are ($(burst_present && echo installed || echo absent))" ;;
  esac
}

# --- verify --------------------------------------------------------------------

# The install tier (PLAN §9c): chrony runs, timesyncd is out of the way, the
# preflight and its keys are installed, and the burst units match the link.
# Nothing here judges an offset, a source's reach or the network.
verify() {
  local t
  for t in chronyc python3 systemd-analyze ip; do
    command -v "$t" >/dev/null || die "$t is not installed; run this step without --verify"
  done

  # 1. chrony is enabled and running. Its sources are printed, not judged.
  local en ac out
  en=$(systemctl is-enabled chrony 2>&1) || true
  ac=$(systemctl is-active chrony 2>&1) || true
  log "chrony: is-enabled $en, is-active $ac"
  [[ $en == enabled ]] || die "chrony is '$en', not enabled; run this step without --verify"
  [[ $ac == active ]] || die "chrony is '$ac', not active; run this step without --verify"
  log "chronyc -n sources (raw output follows; judged only for a GPS refclock)"
  local rc=0
  out=$(chronyc -n sources 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "----"
  # An absent GPS line proves nothing if chronyc could not answer: fail rather
  # than pass "no GPS refclock" on an error.
  ((rc == 0)) || die "chronyc -n sources exited $rc (above), so whether a GPS refclock is configured could not be read. Check: systemctl status chrony; ls -ld /run/chrony"
  if grep -qE '^#.[[:space:]]+GPS[[:space:]]' <<<"$out"; then
    die "chronyc sources lists a GPS refclock, which a stationary rig does not have (A3 of #33). Look for a stray conf in /etc/chrony/conf.d"
  fi
  # A configured refclock is listed whether or not the network is up, so no
  # source lines still means no GPS refclock; but it also means no NTP source.
  if ! grep -qE '^[#^=][*+?x~-][[:space:]]' <<<"$out"; then
    warn "chronyc sources lists no source at all (above): no GPS refclock, but no NTP source either. The clock is not being disciplined; check the network and the pool lines in /etc/chrony/chrony.conf"
  fi
  pass "chrony is enabled and running; chronyc sources answered and lists no GPS refclock"

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
  # Readable with no privilege at all: bin/adsb-writer, as its own unprivileged user, reads
  # clock.max_offset_ms from it, and a login runs the preflight with no sudo. Only the read is
  # proven here, as nobody: not the preflight, whose chronyc may fail for reasons of its own, and
  # a failed verify holds every later update.
  [[ -x $PREFLIGHT ]] || die "$PREFLIGHT is not installed; run this step without --verify"
  command -v setpriv >/dev/null || die "setpriv (util-linux) is not installed, so whether a plain user can read $CLOCK_CONF cannot be checked"
  setpriv --reuid=nobody --regid=nogroup --clear-groups cat -- "$CLOCK_CONF" >/dev/null \
    || die "nobody cannot read $CLOCK_CONF, so neither the writer's user nor a login without sudo could read the clock's bar. Check: ls -ld $ADSB_ETC $CLOCK_CONF"
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

  # 7. The burst timer, by the link (the header).
  local link
  link=$(on_wifi)
  if [[ $link == wired ]]; then
    burst_present \
      && die "the default route is wired, and a burst unit is still installed ($UNIT_DIR/$BURST_TIMER or $UNIT_DIR/$BURST_SERVICE); run this step without --verify"
    pass "wired, and no burst units installed (A3)"
    return 0
  fi
  if [[ $link == unknown ]] && ! burst_present; then
    pass "no default route and no burst units: nothing to judge until the link is known"
    return 0
  fi
  local t_ac svc s_active s_result s_status s_started
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
