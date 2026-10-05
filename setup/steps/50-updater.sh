#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 50-updater: install the updater, its oneshot and timer, and the login banner. PLAN §9f (the
# updater, its units and the banner; the banner's lock line is §9m's).
#
# Shared by both rigs, so it asserts no role. It does read station.role, only to render the
# timer: 🎒 portable ~3 min after boot and daily; 🏠 stationary ~03:30 local, randomized, Persistent.
#
#   setup/steps/50-updater.sh            install, then verify
#   setup/steps/50-updater.sh --verify   verify only
#
# What it installs:
#   - setup/update.sh -> /usr/local/sbin/adsb-update, root:root 0755, by write-then-rename: bash
#     reads a script as it runs, so the running updater keeps its old inode and finishes as the
#     old version. ➡️ A new updater takes effect at the next run.
#   - /etc/systemd/system/adsb-update.service (Type=oneshot) and adsb-update.timer.
#   - /etc/update-motd.d/50-adsb-receiver, the login banner (from setup/files/motd-banner.sh),
#     which pam_motd runs at each SSH login. Seen on mobile-adsb, 2026-10-04: /etc/pam.d/sshd
#     line 33 has `pam_motd.so motd=/run/motd.dynamic` without noupdate, and /run/motd.dynamic was
#     rewritten at an SSH login with 10-uname's output. The banner times out its own commands, so
#     a hung systemctl or lslocks cannot stall a login.
#   Every file by write-then-rename in its own directory, so a login or a daemon-reload never
#   reads a half-written one.
# ⛔ It never starts or restarts adsb-update.service: that unit may be the one running this step,
#    and restarting it would kill the update under way. It enables the timer, and starts (or, when
#    the timer file changed, restarts) it only under update.sh (ADSB_UPDATE_RUN is set): a timer
#    started after OnBootSec= has passed may elapse at once (belief, not checked), and under
#    update.sh the run it fires finds the recording lock held and exits, or merges into the
#    oneshot already running. Run by hand, no lock is held, so an immediate run would rebuild the
#    rig under the operator's hands: the step enables the timer, which then starts at the next
#    boot, and prints the command to start it now.
#
# What has run on hardware: nothing. ⚠️ Unverified on the Pi: all of it.

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"

ROLE=$(station_get station.role) || die "station.yml has no station.role"
[[ $ROLE == portable || $ROLE == stationary ]] || die "station.role is '$ROLE'; it must be portable or stationary"

for t in systemctl systemd-analyze cmp; do
  command -v "$t" >/dev/null || die "$t is not installed"
done

SRC=$ADSB_REPO/setup/update.sh
DST=/usr/local/sbin/adsb-update
UNIT_DIR=/etc/systemd/system
SERVICE=adsb-update.service
TIMER=adsb-update.timer
ADSB_WRITER_UNIT=adsb-writer.service
MOTD_SRC=$ADSB_REPO/setup/files/motd-banner.sh
MOTD=/etc/update-motd.d/50-adsb-receiver

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# install_if_changed <src> <dst> <mode> <owner:group>: render, diff, install (PLAN §9f), by a
# temporary file in the destination's directory and a rename. Sets CHANGED to 0 or 1.
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
  tmp=$(dirname "$dst")/.$(basename "$dst").adsb-new
  run install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$tmp"
  run mv -f "$tmp" "$dst"
  CHANGED=1
  log "$dst changed; installed by rename"
}

# install_updater: never in place. A temporary file in the same directory, then a rename.
install_updater() {
  [[ -f $SRC ]] || die "$SRC is missing from this checkout"
  guard_path "$DST"
  if [[ -f $DST ]] && cmp -s "$SRC" "$DST" && [[ $(stat -c '%U:%G %a' "$DST") == "root:root 755" ]]; then
    log "$DST is unchanged"
    return 0
  fi
  local tmp=${DST%/*}/.adsb-update.new
  run install -D -m 0755 -o root -g root "$SRC" "$tmp"
  run mv -f "$tmp" "$DST"
  log "$DST changed; installed by rename. It takes effect at the next run"
}

render_service() {
  cat >"$WORK/service" <<EOF
# Rendered by setup/steps/50-updater.sh. Do not edit; re-run the step. PLAN §9f.
[Unit]
Description=adsb-receiver update (setup/update.sh, PLAN §9f)
# After the writer: when the pull window starts, the writer's stop comes first (PLAN §9m). The
# recording lock is the backstop: a run that finds it held exits having written nothing.
Wants=network-online.target
After=network-online.target $ADSB_WRITER_UNIT

[Service]
Type=oneshot
ExecStart=$DST
# A readsb source build takes minutes on a Pi 4; the rollback after a SIGTERM may rebuild too.
TimeoutStartSec=40min
TimeoutStopSec=30min
Nice=10
EOF
}

render_timer() {
  if [[ $ROLE == portable ]]; then
    cat >"$WORK/timer" <<'EOF'
# Rendered by setup/steps/50-updater.sh for the portable rig. Do not edit; re-run the step.
# PLAN §9f: ~3 min after boot, and daily. While the rig records, a run finds the recording lock
# held and exits; the pull window is the update path then (PLAN §9m).
[Unit]
Description=adsb-receiver update timer (portable)

[Timer]
OnBootSec=3min
OnCalendar=daily

[Install]
WantedBy=timers.target
EOF
  else
    cat >"$WORK/timer" <<'EOF'
# Rendered by setup/steps/50-updater.sh for the stationary rig. Do not edit; re-run the step.
# PLAN §9f: nightly, ~03:30 local time, randomized, and caught up after downtime.
[Unit]
Description=adsb-receiver update timer (stationary)

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  fi
}

install_units() {
  local svc_changed timer_changed
  render_service
  render_timer
  install_if_changed "$WORK/service" "$UNIT_DIR/$SERVICE" 0644 root:root
  svc_changed=$CHANGED
  install_if_changed "$WORK/timer" "$UNIT_DIR/$TIMER" 0644 root:root
  timer_changed=$CHANGED
  if ((svc_changed || timer_changed)); then
    run systemctl daemon-reload
  fi
  if ! systemctl is-enabled --quiet "$TIMER"; then
    # Enabled, not --now: when it starts is decided just below.
    unit enable "$TIMER"
  fi
  # See the header: start or restart only under update.sh, which holds the recording lock.
  if [[ -n ${ADSB_UPDATE_RUN:-} ]]; then
    if ! systemctl is-active --quiet "$TIMER"; then
      unit start "$TIMER"
    elif ((timer_changed)); then
      unit restart "$TIMER"
    fi
  elif ! systemctl is-active --quiet "$TIMER"; then
    warn "$TIMER is enabled but not started: it starts at the next boot. To start it now (it may start an update at once): sudo systemctl start $TIMER"
  elif ((timer_changed)); then
    warn "$TIMER changed; daemon-reload has run. To restart it now (it may start an update at once): sudo systemctl restart $TIMER"
  fi
}

install_motd() {
  [[ -f $MOTD_SRC ]] || die "$MOTD_SRC is missing from this checkout"
  install_if_changed "$MOTD_SRC" "$MOTD" 0755 root:root
}

install_step() {
  install_updater
  install_units
  install_motd
}

# --- verify --------------------------------------------------------------------

# The install tier (PLAN §9c): the updater is this checkout's and parses, both units match their
# render and load, the timer is enabled and waiting, and the banner runs. ⛔ Never is-active of
# adsb-update.service: under update.sh it is the unit running this.
verify() {
  log "stat $DST (raw output follows)"
  stat -c '%U:%G %a %n' "$DST" 2>&1 || true
  echo "----"
  [[ -f $DST ]] || die "$DST is not installed; run this step without --verify"
  [[ $(stat -c '%U:%G %a' "$DST") == "root:root 755" ]] || die "$DST is not root:root 0755; run this step without --verify"
  cmp -s "$SRC" "$DST" || die "$DST differs from $SRC; run this step without --verify"
  bash -n "$DST" || die "$DST does not parse (bash -n); see above"
  pass "$DST is this checkout's update.sh, and parses"

  render_service
  render_timer
  cmp -s "$WORK/service" "$UNIT_DIR/$SERVICE" || die "$UNIT_DIR/$SERVICE is missing or differs from the rendered unit; run this step without --verify"
  cmp -s "$WORK/timer" "$UNIT_DIR/$TIMER" || die "$UNIT_DIR/$TIMER is missing or differs from the rendered unit ($ROLE); run this step without --verify"
  local out rc=0
  # --recursive-errors=no (systemd 250 and later; the Pi runs 257): the exit status covers these
  # two units only. A fault in a unit they name (adsb-writer.service) is printed above, but does
  # not fail this step, nor roll back an update over another step's unit.
  log "systemd-analyze verify --recursive-errors=no $SERVICE $TIMER (raw output follows)"
  out=$(systemd-analyze verify --recursive-errors=no "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$TIMER" 2>&1) || rc=$?
  printf '%s\n' "${out:-(no output)}"
  echo "----"
  ((rc == 0)) || die "systemd-analyze verify rejected the units (exit $rc); see above"
  pass "$SERVICE and $TIMER match their render ($ROLE) and load"

  local en ac
  en=$(systemctl is-enabled "$TIMER" 2>&1) || true
  ac=$(systemctl is-active "$TIMER" 2>&1) || true
  log "systemctl list-timers $TIMER (raw output follows)"
  systemctl list-timers --all --no-pager "$TIMER" 2>&1 || true
  echo "----"
  [[ $en == enabled ]] || die "$TIMER is '$en', not enabled; run this step without --verify"
  if [[ $ac == active ]]; then
    pass "$TIMER is enabled and active"
  elif [[ -z ${ADSB_UPDATE_RUN:-} ]]; then
    # By hand the step does not start it (see the header); the next boot does.
    warn "$TIMER is enabled but '$ac': it starts at the next boot, or now with: sudo systemctl start $TIMER"
    pass "$TIMER is enabled"
  else
    die "$TIMER is '$ac', not active (waiting), under update.sh; run this step without --verify"
  fi

  [[ -x $MOTD ]] || die "$MOTD is not installed or not executable; run this step without --verify"
  cmp -s "$MOTD_SRC" "$MOTD" || die "$MOTD differs from $MOTD_SRC; run this step without --verify"
  # The banner always exits 0, so its exit status alone proves nothing: its output must hold its
  # header line. A timeout (a hung lslocks or systemctl) is a warning: the banner is cosmetic, and
  # an update must never roll back over it.
  log "$MOTD (raw output follows)"
  rc=0
  out=$(timeout 20 "$MOTD" 2>&1) || rc=$?
  printf '%s\n' "${out:-(no output)}"
  echo "----"
  if ((rc == 124)); then
    warn "the login banner did not finish in 20 s, although each of its commands has a 5 s timeout of its own; a login would wait on it. See above"
    pass "the login banner is installed (it timed out here)"
    return 0
  fi
  ((rc == 0)) || die "the login banner exited $rc; a banner must never fail a login. See above"
  grep -q '^adsb-receiver on ' <<<"$out" || die "the login banner ran but printed no 'adsb-receiver on <host>' line; see above"
  pass "the login banner is installed, runs, and prints its header"
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
