#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 58-maintenance-window: the maintenance window, adsb-maintenance-window.service, on both rigs
# (#33 A4; PLAN §9m, the window; §9f, the update it carries). Starting it stops the writer
# (Conflicts= and After= the writer) and pulls in the update oneshot (Wants=adsb-update.service,
# itself After= the writer), so an update runs in every window, whoever opened it: the nightly
# opener (adsb-home-update, step 70), the bootstrap, tools/pull-archive --end-session (portable
# only), or a hand. Stopping it first waits (ExecStop=) while that update is activating, then
# starts the writer again (ExecStopPost=). The unit's shape is 60-portable-pull's
# adsb-pull-window.service, which it replaces in two rounds.
#
# Shared by both rigs, so it asserts no role. It does read station.role, only to render the cap
# (RuntimeMaxSec=) and to choose the verify's sudoers check:
#   - portable: 2 h, Chris's cap on how long a window keeps the writer off, as the old unit has it;
#   - stationary: 50 min (Chris, 2026-11-22, ruling 1 of the A4 design): above adsb-update.service's
#     own TimeoutStartSec=40min (step 50), so the cap never fires mid-update. A lower cap would not
#     shorten the gap: at the cap ExecStopPost= starts the writer, which then waits on the lock
#     until the update ends (⚠️ belief, not seen), so the update's own 40 min is the real bound.
# TimeoutStopSec=45min on both: the ExecStop= wait is for the window's update, whose own bound is
# 40 min whatever the role, so the stop's bound sits above that one and not above the cap.
#
# The rename, round 1 (#33 A4 §3): on the portable the old unit stays installed, byte-identical,
# by step 60, with its sudoers rule naming both units; every reader of "is a window open" checks
# both names. Round 2, a later commit, removes the old one. This step installs no sudoers rule on
# either role: the opener and the bootstrap run as root. On the stationary the verify asserts that
# no sudoers file names either window unit, so a login there cannot end a recording session.
#
#   setup/steps/58-maintenance-window.sh            install, then verify
#   setup/steps/58-maintenance-window.sh --verify   verify only
#
# ⚠️ ExecStopPost= starts the writer with --no-block: a blocking start from inside the window's own
#    stop would wait for the writer's start job, which (Conflicts= and After=) waits for the stop
#    to finish. Reasoned from systemd's ordering rules, not seen (step 60's note, carried over).
# ⚠️ Belief, not seen: at the cap systemd signals the window's process directly and skips
#    ExecStop=, so the wait does not apply there.
# ⚠️ Unverified on the stationary: the writer's stop before the update starts; the verify reads
#    that order from the journal once a window has run this boot (window_order).
# ⛔ The verify never starts the window (PLAN §9c: a verify may never end a recording session).

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"

for t in systemctl systemd-analyze journalctl cmp grep; do
  command -v "$t" >/dev/null || die "$t is not installed"
done

ROLE=$(station_get station.role) || die "station.yml has no station.role"
[[ $ROLE == portable || $ROLE == stationary ]] || die "station.role is '$ROLE'; it must be portable or stationary"

WINDOW=adsb-maintenance-window.service
OLD_WINDOW=adsb-pull-window.service
WRITER=adsb-writer.service
UPDATE=adsb-update.service
UNIT_FILE=/etc/systemd/system/$WINDOW
SYSTEMCTL=/usr/bin/systemctl
[[ -x $SYSTEMCTL ]] || die "$SYSTEMCTL is missing; the unit names it by that path"
if [[ $ROLE == portable ]]; then CAP=2h; else CAP=50min; fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# install_if_changed <src> <dst> <mode> <owner:group>: render, diff, install (PLAN §9f), by a
# temporary file in the destination's directory and a rename (50-updater's), so a daemon-reload
# never reads a half-written file. Sets CHANGED to 0 or 1.
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
  # The temporary name ends in "~", which no unit reader takes (step 60's note).
  tmp=$(dirname "$dst")/.$(basename "$dst").adsb-new~
  rm -f -- "$tmp"
  run install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$tmp" \
    || { rm -f -- "$tmp"; die "could not write $tmp; $dst was not changed"; }
  run mv -f "$tmp" "$dst" || { rm -f -- "$tmp"; die "could not rename $tmp to $dst; $dst was not changed"; }
  CHANGED=1
  log "$dst changed; installed by rename"
}

render_unit() {
  local cap_why
  if [[ $ROLE == portable ]]; then
    cap_why="# Chris's 2 h cap: it bounds how long a window keeps the writer off, whoever opened it
# (tools/pull-archive --end-session, a hand, the opener, the bootstrap). An update still running
# at the cap is the lock's job: the writer starts, waits on the lock, then records."
  else
    cap_why="# 50 min (Chris, 2026-11-22): above the update's own 40 min TimeoutStartSec=, so the cap never
# fires mid-update; the update's 40 min, not this cap, bounds the recording gap."
  fi
  cat >"$WORK/unit" <<EOF
# Rendered by setup/steps/58-maintenance-window.sh ($ROLE). Do not edit; re-run the step. PLAN §9m.
[Unit]
Description=adsb-receiver maintenance window: the writer stopped while an update runs
# Starting the window stops the writer first: the open .part is closed and renamed.
Conflicts=$WRITER
After=$WRITER
# Starting the window also starts the update oneshot. It is After= the writer too, so it starts
# after the writer's stop; its flock -n on the recording lock is the backstop.
Wants=$UPDATE

[Service]
Type=exec
ExecStart=/bin/sleep infinity
# Closing the window waits for that update to finish, so the writer starts free to record rather
# than blocked on the lock. 45 min is above the update's own 40 min TimeoutStartSec=, on both rigs.
ExecStop=/bin/sh -c 'while $SYSTEMCTL is-active $UPDATE | grep -qx activating; do sleep 5; done'
TimeoutStopSec=45min
$cap_why
RuntimeMaxSec=$CAP
# Starts the writer again when the window stops or hits its cap. '-': a refused start (as during
# a shutdown) does not fail the window; after a reboot the writer's WantedBy= brings it back.
# --no-block: see the step's header.
ExecStopPost=-$SYSTEMCTL --no-block start $WRITER
EOF
}

install_step() {
  render_unit
  install_if_changed "$WORK/unit" "$UNIT_FILE" 0644 root:root
  if ((CHANGED)) || [[ $(systemctl show -p NeedDaemonReload --value "$WINDOW" 2>/dev/null) == yes ]]; then
    run systemctl daemon-reload
  fi
  # No [Install] section: the window is started by an opener and never at boot.
}

# --- verify --------------------------------------------------------------------

# window_order: if a window ran this boot (under either name, in round 1), the journal shows the
# writer's stop before the update oneshot started (PLAN §9m). Printed and warned on, never a
# failure: a wrong order is a design defect that the lock still backstops, not a broken install.
# Moved here from step 60, so the stationary gets it too.
window_order() {
  local j last
  j=$(journalctl -b -q --no-pager -o short-iso-precise -u "$WINDOW" -u "$OLD_WINDOW" -u "$WRITER" -u "$UPDATE" 2>/dev/null) || j=''
  last=$(grep -nE "Start(ing|ed) ($WINDOW|$OLD_WINDOW)" <<<"$j" | tail -n1 | cut -d: -f1) || last=''
  if [[ -z $last ]]; then
    warn "no maintenance window has run this boot, so the writer-stop-before-update order is not shown yet (PLAN §9m)"
    return 0
  fi
  local tail_j stop upd from
  from=$((last > 5 ? last - 5 : 1))
  # One process, no pipeline: under pipefail, head closing early gave tail EPIPE (step 60's note).
  tail_j=$(sed -n "${from},$((from + 59))p" <<<"$j")
  log "journal around the last maintenance window this boot (raw output follows)"
  grep -E "(Stopp(ing|ed)|Start(ing|ed)) ($WINDOW|$OLD_WINDOW|$WRITER|$UPDATE)" <<<"$tail_j" || true
  echo "----"
  stop=$(grep -m1 -nE "Stopped $WRITER" <<<"$tail_j" | cut -d: -f1) || stop=''
  upd=$(grep -m1 -nE "Starting $UPDATE" <<<"$tail_j" | cut -d: -f1) || upd=''
  if [[ -n $stop && -n $upd ]] && ((stop < upd)); then
    pass "the last window stopped the writer before the update started"
  elif [[ -z $stop ]]; then
    warn "the last window shows no writer stop: the writer was not running when it started, so the order is not shown"
  elif [[ -z $upd ]]; then
    warn "the last window shows no update start in the lines read"
  else
    warn "THE UPDATE STARTED BEFORE THE WRITER STOPPED in the last window. PLAN §9m's ordering claim does not hold here; the recording lock is the only guard. Read the lines above"
  fi
}

# no_sudoers_names_window: the stationary's property (a), checked rather than assumed: nothing
# under /etc/sudoers or /etc/sudoers.d names either window unit, so no login can open one.
no_sudoers_names_window() {
  local hits
  hits=$(grep -rlE -- "adsb-(maintenance|pull)-window" /etc/sudoers /etc/sudoers.d 2>/dev/null) || hits=''
  [[ -z $hits ]] || die "on the stationary, these sudoers files name a window unit: $(paste -sd ' ' <<<"$hits"). No login may open the window here (#33 A4); remove the rule"
  pass "no sudoers file names a window unit (the stationary's window opens only from its own timer, as root)"
}

verify() {
  local load
  render_unit
  cmp -s "$WORK/unit" "$UNIT_FILE" || die "$UNIT_FILE is missing or differs from the rendered unit ($ROLE); run this step without --verify"
  # verify_units passes --recursive-errors=no, so this judges $UNIT_FILE only; the steps that
  # install the writer (40) and the update (50) judge theirs.
  verify_units "$UNIT_FILE" "$UNIT_FILE"
  load=$(systemctl show -p LoadState --value "$WINDOW" 2>/dev/null) || load=''
  [[ $load == loaded ]] || die "$WINDOW is '$load', not loaded; run this step without --verify"
  [[ $(systemctl show -p NeedDaemonReload --value "$WINDOW" 2>/dev/null) != yes ]] \
    || die "systemd has not read the current $UNIT_FILE (NeedDaemonReload=yes); run this step without --verify"
  pass "$WINDOW matches its render ($ROLE, RuntimeMaxSec=$CAP), passes systemd-analyze verify, and is loaded (not started: a verify never starts it)"
  if [[ $ROLE == stationary ]]; then
    no_sudoers_names_window
  fi
  window_order
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
