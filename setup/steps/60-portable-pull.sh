#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 60-portable-pull: the pull window, adsb-pull-window.service, and the narrow sudoers rule that
# lets the pull start and stop it. PLAN §9m ("The pull window", "The privilege"), §9h.
#
# Portable only: asserts station.role and refuses a position: block (PLAN §9b).
#
#   setup/steps/60-portable-pull.sh            install, then verify
#   setup/steps/60-portable-pull.sh --verify   verify only
#
# What it installs:
#   - /etc/systemd/system/adsb-pull-window.service. Starting it stops the writer (Conflicts= and
#     After= the writer) and pulls in the update oneshot (Wants=adsb-update.service, itself After=
#     the writer), so an update runs while the archive is pulled (Chris, 2026-10-04: the pull ends
#     the recording session). Stopping it first waits (ExecStop=, up to TimeoutStopSec=45min)
#     while that update is activating (running), so in the usual case the writer does not start
#     only to block on the lock (PLAN §9m's evening update). Not covered, and the writer then
#     waits on the lock until the update ends: the 2 h cap (below); an update only queued when
#     the window stops; and an update rolling back after a SIGTERM, which is deactivating, not
#     activating, so the wait ends at once. Capped at 2 h (RuntimeMaxSec=). When it stops it
#     starts the writer again. ⚠️ Belief, not seen: at shutdown that start is refused, and the
#     writer's WantedBy= brings it back after the boot.
#   - /etc/sudoers.d/adsb-receiver: the logins in group adsb-operator, except the writer's own
#     user adsb-receiver, may run exactly two commands as root with no password, systemctl start
#     and systemctl stop of that one unit. adsb-receiver is in the group by its primary GID (step
#     05), and it is the user that parses data from the sky, so the rule excludes it by name; the
#     writer's unit also runs with NoNewPrivileges=yes (step 40), so sudo cannot work from it
#     whatever any rule says. Checked with visudo -cf before it is installed: a sudoers.d file that
#     does not parse makes sudo refuse everyone.
#   - rsync, which the pull runs on this end.
# The pull itself runs on the workstation: tools/pull-archive.
#
# ⚠️ One departure from PLAN §9m's text: ExecStopPost= starts the writer with --no-block. A
#    blocking start from inside the window's own stop would wait for the writer's start job,
#    which (Conflicts= and After=) waits for the window's stop to finish: a deadlock until the
#    stop times out. That is reasoned from systemd's ordering rules, not seen.
# ⚠️ Belief, not seen: at the 2 h cap systemd signals the window's process directly and skips
#    ExecStop=, so the wait does not apply there; a writer started then waits on the lock, as
#    before. An update still only queued (not yet running) when the window stops is not waited for.
# ⛔ The verify never starts the window (PLAN §9c: a verify may never end a recording session).
# ⚠️ Unverified on the Pi: PLAN §9m's claim that Conflicts= plus After= order the writer's stop
#    before the update starts (the verify reads that order from the journal once a window has run
#    this boot).

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"
require_role portable
require_absent position

for t in systemctl systemd-analyze visudo sudo journalctl getent cmp grep; do
  command -v "$t" >/dev/null || die "$t is not installed"
done

GROUP_NAME=adsb-operator
SERVICE_USER=adsb-receiver
WINDOW=adsb-pull-window.service
WRITER=adsb-writer.service
UPDATE=adsb-update.service
UNIT_FILE=/etc/systemd/system/$WINDOW
SUDOERS=/etc/sudoers.d/adsb-receiver
SYSTEMCTL=/usr/bin/systemctl
[[ -x $SYSTEMCTL ]] || die "$SYSTEMCTL is missing; the sudoers rule names it by that path"
getent group "$GROUP_NAME" >/dev/null || die "no group $GROUP_NAME: run setup/steps/05-config.sh first"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# install_if_changed <src> <dst> <mode> <owner:group>: render, diff, install (PLAN §9f). Sets
# CHANGED to 0 or 1.
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

pkg_installed() {
  local s
  s=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1
  [[ $s == "install ok installed" ]]
}

render_unit() {
  cat >"$WORK/unit" <<EOF
# Rendered by setup/steps/60-portable-pull.sh. Do not edit; re-run the step. PLAN §9m.
[Unit]
Description=adsb-receiver pull window: the writer off while the archive is pulled
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
# than blocked on the lock. 45 min is above the update's own 40 min TimeoutStartSec=.
ExecStop=/bin/sh -c 'while $SYSTEMCTL is-active $UPDATE | grep -qx activating; do sleep 5; done'
TimeoutStopSec=45min
# Chris's 2 h cap: it bounds how long the pull keeps the writer off. An update still running at
# the cap is the lock's job: the writer starts, waits on the lock, then records.
RuntimeMaxSec=2h
# Starts the writer again when the window stops or hits its cap. '-': a refused start (as during
# a shutdown) does not fail the window; after a reboot the writer's WantedBy= brings it back.
# --no-block: see the step's header.
ExecStopPost=-$SYSTEMCTL --no-block start $WRITER
EOF
}

render_sudoers() {
  cat >"$WORK/sudoers" <<EOF
# Rendered by setup/steps/60-portable-pull.sh. Do not edit; re-run the step. PLAN §9m.
# Exactly two commands, no wildcards: start and stop the pull window. Not for $SERVICE_USER, a
# member by its primary group, which runs the writer.
%$GROUP_NAME,!$SERVICE_USER ALL=(root) NOPASSWD: $SYSTEMCTL start $WINDOW, $SYSTEMCTL stop $WINDOW
EOF
}

install_window() {
  render_unit
  install_if_changed "$WORK/unit" "$UNIT_FILE" 0644 root:root
  if ((CHANGED)); then
    run systemctl daemon-reload
  fi
  # No [Install] section: the window is started by hand (through sudo) and never at boot.
}

install_sudoers() {
  render_sudoers
  log "visudo -cf on the rendered rule (raw output follows)"
  visudo -cf "$WORK/sudoers" || die "the rendered sudoers rule does not parse; nothing was installed"
  echo "----"
  install_if_changed "$WORK/sudoers" "$SUDOERS" 0440 root:root
  if ((CHANGED)); then
    log "visudo -c on the whole configuration (raw output follows)"
    visudo -c || die "sudo's whole configuration does not parse after installing $SUDOERS, which parsed on its own (visudo -cf above). Read visudo's message above for the file it names; if that is $SUDOERS, remove it at once (rm $SUDOERS). Until it is fixed, sudo may refuse everyone"
    echo "----"
  fi
}

install_rsync() {
  if pkg_installed rsync; then
    log "rsync is installed"
    return 0
  fi
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y rsync
}

install_step() {
  install_rsync
  install_window
  install_sudoers
}

# --- verify --------------------------------------------------------------------

# window_order: if a window ran this boot, the journal shows the writer's stop before the update
# oneshot started (PLAN §9m). Printed and warned on, never a failure: a wrong order is a design
# defect that the lock still backstops, not a broken install.
window_order() {
  local j
  j=$(journalctl -b -q --no-pager -o short-iso-precise -u "$WINDOW" -u "$WRITER" -u "$UPDATE" 2>/dev/null) || j=''
  local last
  last=$(grep -nE "Start(ing|ed) $WINDOW" <<<"$j" | tail -n1 | cut -d: -f1) || last=''
  if [[ -z $last ]]; then
    warn "no pull window has run this boot, so the writer-stop-before-update order is not shown yet. It is in the pre-field checklist (PLAN §9m)"
    return 0
  fi
  local tail_j stop upd from
  from=$((last > 5 ? last - 5 : 1))
  # One process, no pipeline: under pipefail, head closing early gave tail EPIPE and ended the step (seen on the Pi 2026-10-05).
  tail_j=$(sed -n "${from},$((from + 59))p" <<<"$j")
  log "journal around the last pull window this boot (raw output follows)"
  grep -E "(Stopp(ing|ed)|Start(ing|ed)) ($WINDOW|$WRITER|$UPDATE)" <<<"$tail_j" || true
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

verify() {
  render_unit
  cmp -s "$WORK/unit" "$UNIT_FILE" || die "$UNIT_FILE is missing or differs from the rendered unit; run this step without --verify"
  local out rc=0 load
  log "systemd-analyze verify $UNIT_FILE (raw output follows)"
  out=$(systemd-analyze verify "$UNIT_FILE" 2>&1) || rc=$?
  # 📋 open: as in step 50, --recursive-errors=no would keep a fault in the writer or update unit
  #    from failing this step; not changed here.
  printf '%s\n' "${out:-(no output)}"
  echo "----"
  ((rc == 0)) || die "systemd-analyze verify rejected $UNIT_FILE (exit $rc); see above"
  load=$(systemctl show -p LoadState --value "$WINDOW" 2>/dev/null) || load=''
  [[ $load == loaded ]] || die "$WINDOW is '$load', not loaded; run this step without --verify"
  pass "$WINDOW matches its render, passes systemd-analyze verify, and is loaded (not started: a verify never starts it)"

  log "stat $SUDOERS; visudo -cf $SUDOERS (raw output follows)"
  stat -c '%U:%G %a %n' "$SUDOERS" 2>&1 || true
  rc=0
  visudo -cf "$SUDOERS" || rc=$?
  echo "----"
  ((rc == 0)) || die "$SUDOERS does not parse; remove it at once (rm $SUDOERS), then run this step"
  [[ $(stat -c '%U:%G %a' "$SUDOERS") == "root:root 440" ]] || die "$SUDOERS is not root:root 0440; run this step without --verify"
  render_sudoers
  cmp -s "$WORK/sudoers" "$SUDOERS" || die "$SUDOERS differs from the rendered rule; run this step without --verify"
  pass "$SUDOERS parses, is root:root 0440, and is the rendered rule"

  # Who the rule reaches, asked of sudo itself: `sudo -l -U <user> <command>` prints the command
  # and exits 0 only if that user may run it (it starts nothing). The group's logins are its
  # listed members and every user whose primary group it is (getent group lists only the
  # former). ⚠️ A yes here does not tell NOPASSWD from a password grant: a login with (ALL) ALL
  # passes on that alone. That the window's rule is NOPASSWD is the rendered file's, checked above.
  local gid members=() m others=() cmd listing
  gid=$(getent group "$GROUP_NAME" | cut -d: -f3)
  IFS=, read -r -a members <<<"$(getent group "$GROUP_NAME" | cut -d: -f4)"
  while IFS=: read -r m _ _ pg _; do
    [[ $pg == "$gid" ]] && members+=("$m")
  done < <(getent passwd)
  for m in "${members[@]}"; do
    [[ -n $m && $m != "$SERVICE_USER" && " ${others[*]} " != *" $m "* ]] && others+=("$m")
  done
  ((${#others[@]})) || die "$GROUP_NAME has no members besides $SERVICE_USER, so nobody can pull. See setup/steps/05-config.sh"
  for cmd in "$SYSTEMCTL start $WINDOW" "$SYSTEMCTL stop $WINDOW"; do
    for m in "${others[@]}"; do
      log "sudo -l -U $m $cmd (raw output follows)"
      # shellcheck disable=SC2086  # the command's words, on purpose
      listing=$(sudo -l -U "$m" $cmd 2>&1) || die "sudo does not let $m run '$cmd'; see setup/steps/05-config.sh and $SUDOERS"
      printf '%s\n----\n' "$listing"
    done
    # The writer's user: no grant, whatever its group (PLAN §9m's evening update). Only an actual
    # refusal passes: sudo's manual says `sudo -l <command>` exits 1 when the command is not
    # allowed, and here it prints nothing then, or "... is not allowed to run sudo ...".
    # Anything else (exit 0, or an error such as an unknown user or a sudoers parse error, which
    # sudo prints with a "sudo:" prefix) is not a refusal. ⚠️ The exact refusal text is from
    # sudo's documentation and its usual output, not seen on the Pi. Corrected 2026-10-10: this
    # check passed on the 🎒 portable in every update PLAN §9f records, the last at 11:18 that day
    # (PLAN §9m), so sudo's answer there was one of the two refusal forms above; which one is not
    # recorded.
    log "sudo -l -U $SERVICE_USER $cmd: must be refused (raw output follows)"
    rc=0
    # shellcheck disable=SC2086
    listing=$(sudo -l -U "$SERVICE_USER" $cmd 2>&1) || rc=$?
    printf '%s\n----\n' "${listing:-(no output)}"
    if ((rc == 0)); then
      die "sudo lets $SERVICE_USER, the writer's user, run '$cmd'; the rule must exclude it (%$GROUP_NAME,!$SERVICE_USER)"
    fi
    if ((rc != 1)) || grep -q '^sudo:' <<<"$listing" \
       || ! { [[ -z ${listing//[[:space:]]/} ]] || grep -qi 'is not allowed to run' <<<"$listing"; }; then
      die "sudo's answer for $SERVICE_USER and '$cmd' (exit $rc, above) is not a plain refusal, so whether the rule excludes it is not shown"
    fi
  done
  if grep -vE '^[[:space:]]*#' "$SUDOERS" | grep -F "$WINDOW" | grep -qE '\*'; then
    die "$SUDOERS names $WINDOW with a wildcard; PLAN §9m allows none"
  fi
  pass "${others[*]} may start and stop $WINDOW; $SERVICE_USER may not"

  command -v rsync >/dev/null || die "rsync is not on PATH; run this step without --verify"
  pass "rsync is installed ($(command -v rsync))"

  window_order
  pass "the pull window's unit, its sudoers rule and rsync are installed"
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
