#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 70-portable-home-update: the home-gated window opener, by which the 🎒 portable updates itself
# at home: bin/adsb-at-home, bin/adsb-home-update, adsb-home-update.service and its timer. PLAN
# §9f's 2026-10-04 (night) update (ruled by Chris, option A), §9e's 2026-10-05 (a) (the reason
# line), §9m (the pull window it opens).
#
# Portable only: asserts station.role and refuses a position: block (PLAN §9b). Its own step, the
# build's choice, not ruled: after 50-updater, which installs adsb-update with its --check mode,
# and 60-portable-pull, which installs the window. ℹ️ After a rollback to a tree without this step,
# what it installed stays (PLAN §9f: rollback does not undo creation); the opener then meets an
# adsb-update with no --check, which exits 64, and it opens nothing (its "error" line).
#
#   setup/steps/70-portable-home-update.sh            install, then verify
#   setup/steps/70-portable-home-update.sh --verify   verify only
#
# Opt-in: with update.home_ssid unset or empty in station.yml, adsb-at-home says "off", and the
# opener never runs. ⛔ Nothing here prints that value; the verify says only whether it is set, and
# whether it is a string.
#
# What it installs:
#   - /etc/tmpfiles.d/adsb-home-update.conf, making /run/adsb-home-update (lib.sh's ADSB_HOME_DIR)
#     root:root 0755, at every boot and at install (systemd-tmpfiles --create on that file alone).
#     The opener's marker and its predicate's state file live there. ⛔ Not in /run/adsb-receiver
#     (05-config's), which is adsb-receiver:adsb-operator 0755: its owner is the writer's user,
#     and a symlink planted there would turn a root write by name into a write anywhere (security
#     review, 2026-10-09). A tmpfiles.d entry rather than RuntimeDirectory=: the directory must
#     outlive each run of the oneshot, since the banner reads the state between runs. Its own
#     file, not 05-config's: the opener is portable-only. ⚠️ Belief, from systemd's
#     documentation, not seen: `d` also corrects the owner and mode of a directory already there.
#     The verify checks the result.
#   - bin/adsb-at-home and bin/adsb-home-update -> /usr/local/bin, root:root 0755, by
#     write-then-rename (as 50-updater installs the updater): the opener may be the process that
#     started the update running this step (its window's update), and bash reads a script as it
#     runs, so an in-place write could corrupt it; a rename leaves it the old file.
#   - /etc/systemd/system/adsb-home-update.service, a oneshot, as ruled: After=
#     network-online.target and the writer (so at boot the writer starts first, PLAN §9e's ruling
#     of about 20:45), ExecCondition=/usr/local/bin/adsb-at-home, TimeoutStartSec=55min, Nice=10,
#     ExecStart= the opener. The build's additions:
#       - Wants=network-online.target (as adsb-update.service has it: After= alone orders against a
#         target nothing pulled in);
#       - Environment= with three paths from lib.sh, where they are written down once:
#         ADSB_WINDOW_MARK (the opener's marker), ADSB_RECORDING_LOCK (its lock-held guard) and
#         ADSB_HOME_STATE (adsb-at-home's last verdict, which the login banner reads); and
#       - ExecStopPost= removing the marker. update.sh honors the marker only while this unit is
#         activating, so a stale one is already harmless; the removal is kept so that /run does
#         not show a marker for an opener that is gone, to anyone reading it.
#     No [Install]: the timer starts it.
#   - /etc/systemd/system/adsb-home-update.timer: OnBootSec=4min, as ruled (after adsb-update's
#     3 min boot run, which a recording writer turns into a lock-held exit), and one daily
#     OnCalendar=*-*-* 04:30:00, in the rig's local time. ⚠️ 04:30 is the implementer's pick, NOT
#     RULED. Its reasons: it is apart from adsb-update.timer's own daily run at midnight; and, a
#     belief, not measured, a rig left on at home overnight records the fewest aircraft then, so
#     the window's gap would cost least. No Persistent=: on a rig that was off at 04:30 it would
#     fire again at boot beside OnBootSec=, two triggers for one boot, and the boot trigger
#     already covers a rig switched on at home. No RandomizedDelaySec=: one rig, nothing to
#     spread.
#
# Starting, as 50-updater does for its own timer: the timer is enabled; under update.sh
# (ADSB_UPDATE_RUN) it is started, or restarted when its file changed, so a rig that receives this
# step by an ordinary update has its opener without a reboot; by hand the step prints the command
# instead, and its verify warns rather than fails. A timer started after its OnBootSec= has
# passed elapses at once: seen once on the portable Pi, 2026-10-09, on a first start (the record
# is PLAN's, not this file's). So a first install under update.sh fires the opener once, at once.
# ⚠️ That it always does, and that a restart does too, is belief: systemd may skip a monotonic
# elapse older than the timer's last trigger. That fire is harmless by the opener's guards:
# inside a window it finds the window open (decision window-active); under adsb-update.service it
# finds that unit running; and under a bootstrap's update.sh or a by-hand run, outside any unit,
# it finds the recording lock held by something other than the writer. Each opens nothing. The
# verify does not wait for that run (below).
# ⛔ It never starts or restarts adsb-home-update.service itself: that may be the unit whose window
#    runs this step, waiting on the update.
# A unit file changed on disk outside this step (NeedDaemonReload) is reloaded here, and the verify
# fails on it. The verify fails too unless /run/adsb-home-update is a real directory, not a
# symlink, root:root 0755.
#
# ⛔ The verify never starts the window or the opener, and never opens the SDR stick (PLAN §9c). It
#    runs adsb-at-home by hand, which only reads (station.yml and nmcli) and prints its verdict
#    (not its state file: that is written only under the unit). It also runs `adsb-update --check
#    --retry`, which the parser refuses before anything else runs, to show the installed updater
#    knows --check.

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"
require_role portable
require_absent position

# adsb-at-home's own needs too: nmcli, python3 and its yaml module.
for t in systemctl systemd-analyze systemd-tmpfiles cmp timeout nmcli python3; do
  command -v "$t" >/dev/null || die "$t is not installed"
done
python3 -c 'import yaml' 2>/dev/null || die "python3's yaml module is missing (python3-yaml); adsb-at-home reads station.yml with it"

AT_HOME_SRC=$ADSB_REPO/bin/adsb-at-home
OPENER_SRC=$ADSB_REPO/bin/adsb-home-update
AT_HOME=/usr/local/bin/adsb-at-home
OPENER=/usr/local/bin/adsb-home-update
UPDATER=/usr/local/sbin/adsb-update
UNIT_DIR=/etc/systemd/system
TMPFILES=/etc/tmpfiles.d/adsb-home-update.conf
# The timer's daily OnCalendar= (the header): rendered into the timer and checked by the verify.
DAILY_AT='*-*-* 04:30:00'
SERVICE=adsb-home-update.service
TIMER=adsb-home-update.timer
WINDOW=adsb-pull-window.service
WRITER=adsb-writer.service

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# install_if_changed <src> <dst> <mode> <owner:group>: render, diff, install (PLAN §9f), by a
# temporary file in the destination's directory and a rename (50-updater's). Sets CHANGED.
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

render_tmpfiles() {
  cat >"$WORK/tmpfiles" <<EOF
# Rendered by setup/steps/70-portable-home-update.sh. Do not edit; re-run the step. PLAN §9f.
# The home-gated opener's own runtime directory: root's alone to write. Not /run/adsb-receiver,
# which the writer's user owns (the step's header).
d $ADSB_HOME_DIR 0755 root root -
EOF
}

# install_dir: the tmpfiles.d file, then the directory now, not only at the next boot.
install_dir() {
  render_tmpfiles
  install_if_changed "$WORK/tmpfiles" "$TMPFILES" 0644 root:root
  run systemd-tmpfiles --create "$TMPFILES"
}

render_service() {
  cat >"$WORK/service" <<EOF
# Rendered by setup/steps/70-portable-home-update.sh. Do not edit; re-run the step. PLAN §9f.
[Unit]
Description=adsb-receiver home-gated window opener (portable): opens the pull window at home when an update is pending
# At boot the writer starts first (PLAN §9e); the window this opens is what ends its session.
Wants=network-online.target
After=network-online.target $WRITER

[Service]
Type=oneshot
# At home or not, read-only, from the active Wi-Fi SSID and update.home_ssid (unset: off).
# An exit of 1 to 254 skips the run without failing the unit: 1 not at home or off, 2 cannot tell.
ExecCondition=$AT_HOME
Environment=ADSB_WINDOW_MARK=$ADSB_WINDOW_MARK
Environment=ADSB_RECORDING_LOCK=$ADSB_RECORDING_LOCK
Environment=ADSB_HOME_STATE=$ADSB_HOME_STATE
ExecStart=$OPENER
# The opener removes its marker on every exit it sees; this covers a SIGKILL at the timeout.
ExecStopPost=-/bin/rm -f $ADSB_WINDOW_MARK
# Ruled. The opener bounds its own waits inside it.
TimeoutStartSec=55min
Nice=10
EOF
}

render_timer() {
  cat >"$WORK/timer" <<EOF
# Rendered by setup/steps/70-portable-home-update.sh. Do not edit; re-run the step. PLAN §9f.
# 4 min after boot, after adsb-update.timer's 3 min run, and daily. The daily time, 04:30 local,
# is the implementer's pick, not ruled (the step's header). No Persistent=: it would add a second
# trigger at boot beside OnBootSec=.
[Unit]
Description=adsb-receiver home-gated window opener timer (portable)

[Timer]
OnBootSec=4min
OnCalendar=$DAILY_AT

[Install]
WantedBy=timers.target
EOF
}

install_bins() {
  [[ -f $AT_HOME_SRC ]] || die "$AT_HOME_SRC is missing from this checkout"
  [[ -f $OPENER_SRC ]] || die "$OPENER_SRC is missing from this checkout"
  install_if_changed "$AT_HOME_SRC" "$AT_HOME" 0755 root:root
  install_if_changed "$OPENER_SRC" "$OPENER" 0755 root:root
}

# need_reload: a unit file of this step's changed on disk since systemd read it.
need_reload() {
  local u
  for u in "$SERVICE" "$TIMER"; do
    [[ $(systemctl show -p NeedDaemonReload --value "$u" 2>/dev/null) == yes ]] && return 0
  done
  return 1
}

install_units() {
  local svc_changed timer_changed
  render_service
  render_timer
  install_if_changed "$WORK/service" "$UNIT_DIR/$SERVICE" 0644 root:root
  svc_changed=$CHANGED
  install_if_changed "$WORK/timer" "$UNIT_DIR/$TIMER" 0644 root:root
  timer_changed=$CHANGED
  if ((svc_changed || timer_changed)) || need_reload; then
    run systemctl daemon-reload
  fi
  if ! systemctl is-enabled --quiet "$TIMER"; then
    unit enable "$TIMER"
  fi
  # As 50-updater: start or restart only under update.sh (the header).
  if [[ -n ${ADSB_UPDATE_RUN:-} ]]; then
    if ! systemctl is-active --quiet "$TIMER"; then
      unit start "$TIMER"
    elif ((timer_changed)); then
      unit restart "$TIMER"
    fi
  elif ! systemctl is-active --quiet "$TIMER"; then
    warn "$TIMER is enabled but not started: it starts at the next boot. To start it now (it may open the pull window at once, if at home and an update is pending): sudo systemctl start $TIMER"
  elif ((timer_changed)); then
    warn "$TIMER changed; daemon-reload has run. To restart it now (it may open the pull window at once, if at home and an update is pending): sudo systemctl restart $TIMER"
  fi
}

install_step() {
  install_dir
  install_bins
  install_units
}

# --- verify --------------------------------------------------------------------

# calendar_check [systemd-analyze command]: the daily expression has a next elapse by systemd's
# own reckoning: `systemd-analyze calendar` exits 0 and prints a "Next elapse:" line that is
# neither empty nor "never". It reads no unit state, so it holds whether or not the timer is
# active. A missing systemd-analyze is warned about, and the check counted as unverified, not
# failed: this is tooling, not the rig's state. ℹ️ In the step itself it is never missing, since
# the tool check at the top requires it for `systemd-analyze verify`; that branch is reached only
# from the smoke test. Run with LC_ALL=C: the "Next elapse:" label it parses is English.
calendar_check() {
  local an=${1:-systemd-analyze} out rc=0 next
  if ! command -v "$an" >/dev/null 2>&1; then
    warn "$an is not installed, so whether OnCalendar=$DAILY_AT gives a next elapse is UNVERIFIED"
    return 0
  fi
  log "$an calendar '$DAILY_AT' (raw output follows)"
  out=$(LC_ALL=C "$an" calendar "$DAILY_AT" 2>&1) || rc=$?
  printf '%s\n' "${out:-(no output)}"
  echo "----"
  next=$(sed -n 's/^[[:space:]]*Next elapse:[[:space:]]*//p' <<<"$out" | head -n1)
  if ((rc != 0)) || [[ -z $next || $next == never ]]; then
    die "the daily expression OnCalendar=$DAILY_AT gives systemd no next elapse (exit $rc, above)"
  fi
  pass "OnCalendar=$DAILY_AT gives systemd a next elapse: $next"
}

# timer_snapshot: ONE `systemctl show` of the timer, parsed by key into T_SUB, T_ACTIVE, T_LAST,
# T_NEXT and T_MONO, the raw output in T_RAW. Returns 1 when systemctl show itself failed. A
# NextElapseUSecMonotonic of "none" reads 0, not empty. LC_ALL=C: the keys are not
# locale-sensitive, but the realtime next elapse is a timestamp string that next_set gives to
# date(1) to parse, so it is read in the C locale (⚠️ belief: systemd's timestamp words, such as
# the weekday, follow the locale).
timer_snapshot() {
  local line
  T_SUB='' T_ACTIVE='' T_LAST='' T_NEXT='' T_MONO=''
  T_RAW=$(LC_ALL=C systemctl show -p SubState -p ActiveState -p LastTriggerUSec -p NextElapseUSecRealtime \
            -p NextElapseUSecMonotonic "$TIMER" 2>&1) || return 1
  while IFS= read -r line; do
    case $line in
      SubState=*) T_SUB=${line#*=} ;;
      ActiveState=*) T_ACTIVE=${line#*=} ;;
      LastTriggerUSec=*) T_LAST=${line#*=} ;;
      NextElapseUSecRealtime=*) T_NEXT=${line#*=} ;;
      NextElapseUSecMonotonic=*) T_MONO=${line#*=} ;;
    esac
  done <<<"$T_RAW"
}

# next_set: T_NEXT names a time: not empty, n/a, infinity or 0, and date(1) parses it, so a
# non-time string (never, say) is "not set". systemd ends the timestamp with the local zone's
# abbreviation, which date knows only for some zones (MST is one), so if the whole string does not
# parse, it is tried again without that last word (⚠️ belief: the abbreviation is the only part
# date may not know).
next_set() {
  [[ -n $T_NEXT && $T_NEXT != n/a && $T_NEXT != infinity && $T_NEXT != 0 ]] || return 1
  LC_ALL=C date -d "$T_NEXT" +%s >/dev/null 2>&1 && return 0
  [[ $T_NEXT == *' '* ]] && LC_ALL=C date -d "${T_NEXT% *}" +%s >/dev/null 2>&1
}

# timer_check <reads> <pause command>: the active timer's state, decided on SubState at every
# read, with no wait on anything the timer started. The step calls it with 5 and "sleep 1"; the
# smoke test passes its own, so the retry is counted in reads, not in seconds.
#   - running: the timer has fired adsb-home-update.service and that run has not ended. A timer
#     enters running only on its own elapse (⚠️ belief, from systemd's source and behavior; not
#     seen for a by-hand `systemctl start adsb-home-update.service`, which is believed to leave
#     the timer waiting), so running is itself evidence the timer works. Its next elapse is not
#     readable while that run goes on (⚠️ belief: `show --value` of NextElapseUSecRealtime is
#     empty then), and systemd re-arms it when the run ends. That run may be the opener that
#     opened the very window this update runs in, waiting for this verify to end, so it is not
#     waited for.
#   - waiting with a realtime next elapse (next_set): the timer is armed.
#   - waiting without one: read again, <pause> between, up to <reads> reads in all, and decide
#     each read afresh, so a timer that fires between reads (running) passes, and one that turns
#     elapsed, dead or failed fails as that, not as a missing next elapse. ⚠️ Belief, not seen: a
#     waiting timer with no next elapse can be met at all, briefly, between its start and its
#     catch-up fire. Still waiting with none at the last read: fail.
#   - anything else (elapsed, dead, failed, ...): fail, with the snapshot.
# A failing `systemctl show` is reported as such, never as a missing next elapse.
timer_check() {
  local reads=$1 pause=$2 n=0 last
  while :; do
    n=$((n + 1))
    if ((n > 1)); then
      # shellcheck disable=SC2086  # the pause command's words, on purpose
      $pause
    fi
    timer_snapshot || die "systemctl show $TIMER failed (a systemctl failure, not a missing next elapse): $T_RAW"
    log "systemctl show $TIMER, read $n of at most $reads (raw output follows)"
    printf '%s\n' "$T_RAW"
    echo "----"
    last=$T_LAST
    [[ -n $last && $last != n/a && $last != 0 ]] || last=''
    case $T_SUB in
      running)
        pass "$TIMER has fired $SERVICE (LastTriggerUSec=${last:-none}) and that run has not ended; its next elapse is not readable while it runs, and systemd re-arms it when the run ends (not measured here; the login banner shows the next fire). A timer enters running only on its own elapse: belief, not seen for a by-hand service start"
        return 0 ;;
      waiting)
        if next_set; then
          pass "$TIMER is waiting: next elapse $T_NEXT (monotonic: ${T_MONO:-?}, 0 for none); last trigger ${last:-none since start}"
          return 0
        fi
        ((n < reads)) || die "$TIMER is active but has no realtime next elapse after $n reads (the last snapshot above): $(paste -sd ' ' <<<"$T_RAW")" ;;
      *)
        die "$TIMER is ${T_ACTIVE:-?}, SubState '${T_SUB:-?}', neither waiting nor running (the snapshot above): $(paste -sd ' ' <<<"$T_RAW")" ;;
    esac
  done
}

# The install tier (PLAN §9c): both programs are this checkout's and parse; the updater they call
# knows --check; both units match their render, load and need no reload; the timer is enabled,
# active under update.sh, and, when active, waiting with a next elapse or running a run it fired;
# its daily expression has a next elapse; update.home_ssid, if set, is a string; and the
# predicate runs and gives a verdict. ⛔ Never starts the window or the opener.
verify() {
  local f src st
  render_tmpfiles
  cmp -s "$WORK/tmpfiles" "$TMPFILES" || die "$TMPFILES is missing or differs from its render; run this step without --verify"
  log "stat $ADSB_HOME_DIR (raw output follows)"
  stat -c '%U:%G %a %F %n' "$ADSB_HOME_DIR" 2>&1 || true
  echo "----"
  [[ -d $ADSB_HOME_DIR && ! -L $ADSB_HOME_DIR ]] || die "$ADSB_HOME_DIR is not a directory (or is a symlink); run this step without --verify"
  st=$(stat -c '%U:%G %a' "$ADSB_HOME_DIR")
  [[ $st == "root:root 755" ]] || die "$ADSB_HOME_DIR is $st, not root:root 0755: the opener refuses to write there; run this step without --verify"
  pass "$ADSB_HOME_DIR is a directory, root:root 0755, from $TMPFILES"

  for f in "$AT_HOME" "$OPENER"; do
    src=$AT_HOME_SRC
    [[ $f == "$OPENER" ]] && src=$OPENER_SRC
    log "stat $f (raw output follows)"
    stat -c '%U:%G %a %n' "$f" 2>&1 || true
    echo "----"
    [[ -f $f ]] || die "$f is not installed; run this step without --verify"
    [[ $(stat -c '%U:%G %a' "$f") == "root:root 755" ]] || die "$f is not root:root 0755; run this step without --verify"
    cmp -s "$src" "$f" || die "$f differs from $src; run this step without --verify"
    bash -n "$f" || die "$f does not parse (bash -n); see above"
  done
  pass "$AT_HOME and $OPENER are this checkout's, and parse"

  # The parser's own answer: an updater that knows --check refuses it with --retry by name; one
  # that does not calls --check an unknown argument. Both exit 64 before anything runs.
  [[ -x $UPDATER ]] || die "$UPDATER is not installed; run setup/steps/50-updater.sh"
  local out rc=0
  log "$UPDATER --check --retry: must be refused by the parser, naming --check (raw output follows)"
  out=$(timeout 10 "$UPDATER" --check --retry 2>&1) || rc=$?
  printf '%s\n' "${out:-(no output)}"
  echo "----"
  if [[ $rc != 64 ]] || ! grep -q -- '--check takes no other argument' <<<"$out"; then
    die "$UPDATER does not know --check (exit $rc, above), which the opener runs; run setup/steps/50-updater.sh from this checkout"
  fi
  pass "$UPDATER knows the --check mode the opener runs"

  render_service
  render_timer
  cmp -s "$WORK/service" "$UNIT_DIR/$SERVICE" || die "$UNIT_DIR/$SERVICE is missing or differs from the rendered unit; run this step without --verify"
  cmp -s "$WORK/timer" "$UNIT_DIR/$TIMER" || die "$UNIT_DIR/$TIMER is missing or differs from the rendered unit; run this step without --verify"
  rc=0
  # --recursive-errors=no, as in 50-updater: a fault in a unit these name (the writer) is printed,
  # but does not fail this step.
  log "systemd-analyze verify --recursive-errors=no $SERVICE $TIMER (raw output follows)"
  out=$(systemd-analyze verify --recursive-errors=no "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$TIMER" 2>&1) || rc=$?
  printf '%s\n' "${out:-(no output)}"
  echo "----"
  ((rc == 0)) || die "systemd-analyze verify rejected the units (exit $rc); see above"
  local load
  load=$(systemctl show -p LoadState --value "$SERVICE" 2>/dev/null) || load=''
  [[ $load == loaded ]] || die "$SERVICE is '$load', not loaded; run this step without --verify"
  ! need_reload || die "systemd has not read the current $SERVICE or $TIMER (NeedDaemonReload=yes); run this step without --verify"
  load=$(systemctl show -p LoadState --value "$WINDOW" 2>/dev/null) || load=''
  [[ $load == loaded ]] || die "$WINDOW, which the opener starts, is '$load', not loaded; run setup/steps/60-portable-pull.sh"
  pass "$SERVICE and $TIMER match their render, load, and need no reload; $WINDOW is loaded (not started: a verify never starts it)"

  local en ac
  en=$(systemctl is-enabled "$TIMER" 2>&1) || true
  ac=$(systemctl is-active "$TIMER" 2>&1) || true
  [[ $en == enabled ]] || die "$TIMER is '$en', not enabled; run this step without --verify"
  if [[ $ac == active ]]; then
    pass "$TIMER is enabled and active"
  elif [[ -z ${ADSB_UPDATE_RUN:-} ]]; then
    # By hand the step does not start it (the header); the next boot does.
    warn "$TIMER is enabled but '$ac': it starts at the next boot, or now with: sudo systemctl start $TIMER"
    pass "$TIMER is enabled"
  else
    die "$TIMER is '$ac', not active (waiting), under update.sh; run this step without --verify"
  fi
  calendar_check
  # Only an active timer's state is decided: an inactive one, warned about by hand above, is
  # believed to read SubState dead (⚠️ belief, not seen), which timer_check would fail.
  if [[ $ac == active ]]; then
    timer_check 5 "sleep 1"
  fi

  # update.home_ssid: what kind of value, never the value. unset, string, string-ws (leading or
  # trailing whitespace) or other.
  local kind stf
  stf=$(station_file) || die "no station.yml"
  kind=$(python3 - "$stf" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
v = (d.get("update") or {}).get("home_ssid") if isinstance(d, dict) else None
if v is None or v == "":
    print("unset")
elif not isinstance(v, str):
    print("other")
elif v != v.strip():
    print("string-ws")
else:
    print("string")
PY
  ) || die "could not read update.home_ssid's kind from $stf"
  case $kind in
    other) die "update.home_ssid in $stf is set, but not to a string (an unquoted yes or no, a number, a list); the opener treats it as unset. Quote it: home_ssid: \"...\" (its value is not printed here)" ;;
    string-ws) warn "update.home_ssid in $stf begins or ends with whitespace; the SSID must match exactly, so check it (its value is not printed here)" ;;
  esac

  # The predicate, by hand: one line, "at home", "not at home" or "cannot tell".
  local verdict
  log "$AT_HOME (raw output follows)"
  rc=0
  verdict=$(timeout 30 "$AT_HOME" 2>&1) || rc=$?
  printf '%s\n' "${verdict:-(no output)}"
  echo "----"
  case "$rc:$verdict" in
    "0:at home"|"1:not at home"|"2:cannot tell") ;;
    *) die "$AT_HOME exited $rc and printed something other than 'at home', 'not at home' or 'cannot tell' (above)" ;;
  esac
  if [[ $kind == unset ]]; then
    pass "the predicate runs ($verdict); update.home_ssid is not set, so the opener is off (opt-in, PLAN §9f)"
  elif ((rc == 2)); then
    die "update.home_ssid is set, but $AT_HOME cannot tell whether the rig is at home (station.yml or nmcli could not be read); the opener would never run"
  else
    ((rc == 0)) || warn "not at home now: the opener runs only on the home Wi-Fi (expected in the field)"
    pass "the predicate runs ($verdict); update.home_ssid is set, to a string (its value is never printed)"
  fi
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
