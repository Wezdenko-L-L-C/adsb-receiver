#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 58-maintenance-window: the maintenance window, adsb-maintenance-window.service, on both rigs
# (#33 A4; PLAN §9m, the 🎒 portable's window; §9f, "A4 of #33", the window on both rigs and the
# update it carries). Starting it stops the writer
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
# either role: the opener and the bootstrap run as root.
#
# On the stationary the verify asks sudo itself (no_sudo_grant_opens_window), for every account
# but root, whether it may run `systemctl start` or `stop` of either window unit, and fails on any
# grant that reaches those commands without reaching everything: a rule naming the unit, a
# wildcard, an argument-less systemctl, with or without a password, from any file sudo reads. An
# account holding a general grant (ALL, the admin login's usual one) is root by hand: named, not
# failed. What the verify shows is that no account has been given the window by sudo. It does not
# show that only the timer opens it. Other ways in that it does not check: root by hand, and an
# admin login's general sudo, with or without a password; the bootstrap, which runs as root and
# opens the window itself; and any other root process.
#
# ⚠️ A window ended by its cap (RuntimeMaxSec=) is left `failed`, by PLAN's belief, not seen (its
#    list of the old unit's untested claims: "a unit ended by RuntimeMaxSec= reads failed"). Nothing
#    in this repo treats that as an alarm: this verify never reads the window's ActiveState, the
#    opener and the bootstrap read failed as closed, and the login banner does not show the window.
#    systemd's own `systemctl --failed` and `is-system-running` (degraded) would list it until the
#    next start or a reset-failed (systemd's documented behavior, not seen here).
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

for t in systemctl systemd-analyze journalctl cmp grep awk getent; do
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
# Rendered by setup/steps/58-maintenance-window.sh ($ROLE). Do not edit; re-run the step. PLAN §9m;
# §9f, "A4 of #33".
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
# writer's stop before the update oneshot started (PLAN §9m; on both rigs, §9f's "A4 of #33"). Printed and warned on, never a
# failure: a wrong order is a design defect that the lock still backstops, not a broken install.
# Moved here from step 60, so the stationary gets it too.
#
# How the last window's lines are found. journalctl -u over several units interleaves them in time
# order. The anchor is the last "Starting <window>" line. The writer's stop is logged BEFORE it
# (the window is After= the writer), and the update's start may fall either side of it (it is
# After= the writer, not the window), so the check does not read forward from the anchor alone.
# It walks back from the anchor to the writer's "Stopped" line, giving up at a writer start or an
# earlier window's "Starting" (then the writer was not running when this window opened), then back
# to that stop's "Stopping" line. The update's start is the first "Starting <update>" after the
# "Stopping" line: before the "Stopped" line, the order is broken; after it, it holds. Counted in
# lines, not by a fixed lookback, so an earlier update run (the timer's at boot) is not taken for
# this window's.
# Only systemd's own unit-lifecycle lines are markers: the identifier field is systemd[<pid>]:, the
# next word is Starting, Started, Stopping or Stopped, and the word after it is the unit itself
# (systemd writes "Started <unit> - <description>.", or "Started <unit>." for a unit with no
# description, so trailing dots are dropped). A process's own line that names a unit in its text
# (the writer's, update.sh's, a window's ExecStopPost=) is never one, so it cannot stand for a
# writer start and cut the walk back short with a false "no writer stop", as free-text matching did
# when two windows ran in one boot.
window_order() {
  local j pos a s k u
  j=$(journalctl -b -q --no-pager -o short-iso-precise -u "$WINDOW" -u "$OLD_WINDOW" -u "$WRITER" -u "$UPDATE" 2>/dev/null) || j=''
  # One awk, one line out: the anchor, the writer's Stopped and Stopping lines, the update's start
  # (line numbers in $j, 0 for none).
  pos=$(awk -v W="Starting $WINDOW" -v O="Starting $OLD_WINDOW" -v R="$WRITER" -v U="Starting $UPDATE" '
    { t[NR] = ""; v = $4; n = $5; sub(/\.+$/, "", n); ev = v " " n }
    $3 !~ /^systemd\[[0-9]+\]:$/ { next }
    ev == W || ev == O           { t[NR] = "win" }
    ev == "Stopping " R          { t[NR] = "stopping" }
    ev == "Stopped " R           { t[NR] = "stopped" }
    ev == "Starting " R || ev == "Started " R { t[NR] = "wstart" }
    ev == U                      { t[NR] = "upd" }
    END {
      a = 0; s = 0; k = 0; u = 0
      for (i = NR; i >= 1; i--) if (t[i] == "win") { a = i; break }
      if (a) for (i = a - 1; i >= 1; i--) {
        if (t[i] == "stopped") { s = i; break }
        if (t[i] == "wstart" || t[i] == "win") break
      }
      if (s) for (i = s - 1; i >= 1; i--) {
        if (t[i] == "stopping") { k = i; break }
        if (t[i] == "wstart" || t[i] == "win" || t[i] == "stopped") break
      }
      from = k ? k : (s ? s : a)
      if (a) for (i = from + 1; i <= NR; i++) if (t[i] == "upd") { u = i; break }
      print a, s, k, u
    }' <<<"$j") || pos='0 0 0 0'
  read -r a s k u <<<"$pos"
  if ((a == 0)); then
    warn "no maintenance window has run this boot, so the writer-stop-before-update order is not shown yet (PLAN §9m)"
    return 0
  fi
  local from=$((k > 0 ? k : (s > 0 ? s : a)))
  log "journal from the last maintenance window this boot (raw output follows)"
  # One process, no pipeline: under pipefail, head closing early gave tail EPIPE (step 60's note).
  sed -n "${from},$((from + 59))p" <<<"$j" | grep -E "(Stopp(ing|ed)|Start(ing|ed)) ($WINDOW|$OLD_WINDOW|$WRITER|$UPDATE)" || true
  echo "----"
  if ((s == 0)); then
    warn "the last window shows no writer stop: the writer was not running when it started, so the order is not shown"
  elif ((u == 0)); then
    warn "the last window shows no update start after the writer's stop began"
  elif ((u > s)); then
    pass "the last window stopped the writer before the update started"
  else
    warn "THE UPDATE STARTED BEFORE THE WRITER STOPPED in the last window. PLAN §9m's ordering claim does not hold here; the recording lock is the only guard. Read the lines above"
  fi
}

# sudo_refuses <user> <command words...>: asks sudo itself whether <user> may run the command
# (`sudo -n -l -U`, which starts nothing). Returns 0 on a plain refusal, 1 on a grant (exit 0, its
# output printed). Anything else is not an answer and fails the verify: sudo's manual says `-l
# <command>` exits 1 when the command is not allowed, printing nothing or "... is not allowed to
# run sudo ...", and an error (an unknown user, a sudoers parse error) carries a "sudo:" prefix
# (step 60's reading). Seen (Claude, 2026-11-22, in a Debian trixie container, sudo 1.9.16p2):
# `sudo -n -l -U nobody /usr/bin/systemctl start adsb-maintenance-window.service` printed nothing
# and exited 1, while a `%sudo ALL` member got the command echoed and exit 0. So on that sudo a
# refusal is the empty-output branch; the "is not allowed to run" match is a fallback for a sudo
# that words it, from sudo's documentation, not seen. ⚠️ Not yet seen on the stationary itself.
sudo_refuses() {
  local u=$1 out rc=0
  shift
  out=$(sudo -n -l -U "$u" "$@" 2>&1) || rc=$?
  if ((rc == 0)); then
    log "sudo -n -l -U $u $*: allowed (raw output follows)"
    printf '%s\n----\n' "${out:-(no output)}"
    return 1
  fi
  if ((rc != 1)) || grep -q '^sudo:' <<<"$out" \
     || ! { [[ -z ${out//[[:space:]]/} ]] || grep -qi 'is not allowed to run' <<<"$out"; }; then
    printf '%s\n----\n' "${out:-(no output)}"
    die "sudo's answer for $u and '$*' (exit $rc, above) is not a plain refusal, so whether $u may open or end the window is not shown"
  fi
  return 0
}

# no_sudo_grant_opens_window: the stationary's property (a), by its effect (the header). Every
# account but root, from getent passwd, not only those with a login shell: a grant to a service
# account (the writer's user runs code that parses radio input) is the worse case, and sudo -l
# answers for an account whatever its shell. Each is first asked of a probe command no rule would
# name, `/usr/bin/true <an argument>`: an account allowed that holds a general grant and is root
# by hand (named, not failed). Every other account must be refused all four window commands.
# Only refused or granted lines are judged; a grant's listing is printed, a refusal's is not.
SUDO_PROBE=(/usr/bin/true adsb-receiver-sudo-probe)
no_sudo_grant_opens_window() {
  local pw u uid cmd n=0 admins=() granted=()
  if ! command -v sudo >/dev/null 2>&1; then
    pass "sudo is not installed, so no account can open or end the window through it (root can; not checked)"
    return 0
  fi
  [[ -x ${SUDO_PROBE[0]} ]] || die "${SUDO_PROBE[0]}, the sudo check's probe command, is missing"
  pw=$(getent passwd) || die "getent passwd failed, so which accounts sudo might let open the window is not shown"
  while IFS=: read -r u _ uid _; do
    [[ -n $u && $uid != 0 ]] || continue
    n=$((n + 1))
    if ! sudo_refuses "$u" "${SUDO_PROBE[@]}"; then
      admins+=("$u")
      continue
    fi
    for cmd in "$SYSTEMCTL start $WINDOW" "$SYSTEMCTL stop $WINDOW" "$SYSTEMCTL start $OLD_WINDOW" "$SYSTEMCTL stop $OLD_WINDOW"; do
      # shellcheck disable=SC2086  # the command's words, on purpose
      sudo_refuses "$u" $cmd || granted+=("$u: $cmd")
    done
  done <<<"$pw"
  ((n > 0)) || die "getent passwd listed no account but root, so the sudo check asked nobody"
  if ((${#granted[@]})); then
    die "on the stationary, sudo lets an account other than root open or end the window, by a grant that is not a general one (listings above): $(printf '%s; ' "${granted[@]}")no account may be given the window here (#33 A4); remove the rule"
  fi
  pass "sudo refuses systemctl start and stop of $WINDOW and $OLD_WINDOW to each of the $n accounts but root, except those holding a general grant (${admins[*]:-none}), which is root by hand. Not checked: root, the bootstrap (as root), and those general grants, with or without a password"
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
    no_sudo_grant_opens_window
  fi
  window_order
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
