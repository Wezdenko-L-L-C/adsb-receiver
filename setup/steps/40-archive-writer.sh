#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 40-archive-writer: install bin/adsb-writer and its unit, adsb-writer.service,
# which records readsb's BEAST stream onto the archive drive. PLAN §9m ("The
# archive writer", the writer's unit, the recording lock, the steps).
#
# Portable only, for now: asserts station.role and refuses a position: block
# (PLAN §9b). The gate follows step 30's: the drive is portable-only until the
# stationary rig's SSD question in PLAN §9m is decided.
#
#   setup/steps/40-archive-writer.sh            install, then verify
#   setup/steps/40-archive-writer.sh --verify   verify only
#
# What it installs:
#   - bin/adsb-writer -> /usr/local/bin/adsb-writer, root:root 0755. Copied, not
#     symlinked: update.sh flips between two worktrees (PLAN §9f).
#   - /var/lib/adsb-receiver/writer, adsb-receiver:adsb-operator 2770, on the SD
#     card: the writer's status file, writer.json, goes there.
#   - /etc/systemd/system/adsb-writer.service, rendered from station.yml
#     (archive.min_free_gb), enabled, with NoNewPrivileges=yes: the writer parses
#     data from the sky, and its user is in adsb-operator (step 05), whose sudoers
#     rule it must never use (step 60 excludes it by name too). ⚠️ Belief, not seen
#     on the Pi: the two ExecStartPre=+ preflights still pass under it (they run
#     as root and only drop privileges, which NoNewPrivileges allows).
#
# Starting and restarting (§9f: a service restarts only if its rendered config
# or its binary changed):
#   - running or starting, and the unit or the binary changed: restarted. The
#     writer closes its file cleanly on SIGTERM, so a session gets a new file,
#     not a torn one. A unit file that was missing counts as changed, so a
#     writer found running without one is restarted under the new one.
#   - stopping (deactivating): waited for, up to 15 s, before deciding. Still
#     stopping after that, or in maintenance: neither started nor restarted,
#     with a warning.
#   - not running: started, unless the pull window is active (starting the
#     writer would stop the window, PLAN §9m) or the recording lock is held.
#     If the lock is held, this step leaves the writer stopped, warns, and
#     names the command that starts it: sudo systemctl start adsb-writer.
#     update.sh holds the lock while it runs, and at its end starts the writer
#     if it is enabled and inactive and the pull window is not active,
#     activating or deactivating (setup/update.sh, PLAN §9f). The pull window
#     starts it when the window ends (setup/steps/60-portable-pull.sh, PLAN
#     §9m).
#   Both with --no-block: whether the preflights pass is readiness, not install.
#
# ⛔ Port 30005, readsb and a sky are readiness, never checked here: this step
#    does not depend on 10-decoder. It does need step 20's clock-preflight and
#    step 30's archive-preflight, which the unit runs before each start.
#
# What has run on hardware is recorded in PLAN §9m, not here (PLAN §9c: no
# script carries a "tested on" header).

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"

# 2026-10-04: portable-only, with step 30 (PLAN §9m).
require_role portable
require_absent position

for t in python3 systemctl systemd-analyze systemd-escape journalctl lslocks cmp; do
  command -v "$t" >/dev/null || die "$t is not installed"
done
FLOCK=/usr/bin/flock
[[ -x $FLOCK ]] || die "$FLOCK is missing (util-linux)"

MIN_FREE_GB=$(station_get archive.min_free_gb) \
  || die "station.yml has no archive.min_free_gb: add the archive: block from config/station.portable.example.yml"
[[ $MIN_FREE_GB =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || die "archive.min_free_gb '${MIN_FREE_GB}' must be a number of GiB (2^30 bytes, as the writer counts it)"

USER_NAME=adsb-receiver
GROUP_NAME=adsb-operator
getent passwd "$USER_NAME" >/dev/null || die "no user $USER_NAME: run setup/steps/05-config.sh first"
getent group "$GROUP_NAME" >/dev/null || die "no group $GROUP_NAME: run setup/steps/05-config.sh first"

SRC=$ADSB_REPO/bin/adsb-writer
WRITER=/usr/local/bin/adsb-writer
UNIT=adsb-writer.service
UNIT_FILE=/etc/systemd/system/$UNIT
WINDOW_UNIT=adsb-pull-window.service
STATE_DIR=/var/lib/adsb-receiver/writer
MP=/var/lib/adsb-receiver/archive
# Step 30's mount unit, named as step 30 names it. On the Pi it reads
# var-lib-adsb\x2dreceiver-archive.mount (2026-10-04): the backslash is part of
# the name and must reach the rendered unit as it is.
MOUNT_UNIT=$(systemd-escape --path --suffix=mount "$MP")
BEAST_DIR=$MP/beast
LOCK=$ADSB_RECORDING_LOCK   # from lib.sh
CLOCK_PREFLIGHT=/usr/local/bin/clock-preflight
ARCHIVE_PREFLIGHT=/usr/local/bin/archive-preflight

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

# need_preflights: the unit runs both before every start; without them it
# could only fail and retry.
need_preflights() {
  [[ -x $CLOCK_PREFLIGHT ]] || die "$CLOCK_PREFLIGHT is not installed: run setup/steps/20-portable-clock.sh first"
  [[ -x $ARCHIVE_PREFLIGHT ]] || die "$ARCHIVE_PREFLIGHT is not installed: run setup/steps/30-archive-drive.sh first"
}

# The archive mount is Wants= + After=, not RequiresMountsFor= (Chris, 2026-10-04,
# option A1; PLAN §9m). RequiresMountsFor= adds Requires=, and with Requires= a
# failed mount fails the writer's start JOB before any process runs: the writer
# is left inactive/dead, Result=success, NRestarts=0, Restart= never fires, and
# nothing records until a reboot. Stopping a required unit also stops the writer
# with no restart. (Both seen with stand-in user units, systemd 259, 2026-10-04.)
# With Wants= + After=, every attempt runs the preflights: archive-preflight
# refuses with exit 2 ("no device is labeled ..." with the drive absent, "nothing
# is mounted" if it is present but the mount failed), Restart=on-failure retries every
# 30 s, and each retry queues a fresh start job for the wanted mount (four mount
# attempts for four writer attempts, same stand-ins). So a drive plugged in late
# is picked up within about one cycle: the device timeout plus 30 s.
# ➡️ The guard against writing to the SD card is archive-preflight's refusal and
#    the mount point's 0555 (step 30), no longer a unit dependency.
# ⚠️ Belief, to be tested on the Pi before the field: the Pi's mount unit has
#    Requires=dev-sda1.device and no BindsTo= (systemctl show, 2026-10-04), so a
#    drive pulled mid-session may leave the mount on a vanished device. The writer
#    then exits on its write or fsync error and keeps retrying, refused by
#    archive-preflight, until a reboot.
render_unit() {
  cat >"$WORK/unit" <<EOF
# Rendered by setup/steps/40-archive-writer.sh from station.yml
# (archive.min_free_gb). Do not edit; re-run the step. PLAN §9m.
[Unit]
Description=adsb-receiver archive writer (BEAST onto the archive drive)
# The archive drive's mount: wanted, not required, so a failed mount still lets
# the start run, archive-preflight refuse it, and Restart= retry, pulling the
# mount in again each time. After= makes each attempt wait for the mount's start
# job to finish or fail. Not RequiresMountsFor=: see the step's comment (PLAN §9m).
Wants=$MOUNT_UNIT
After=$MOUNT_UNIT
# Ordering only; nothing here pulls these in. readsb is not a dependency: the
# writer waits for port 30005 itself.
After=network.target readsb.service chrony.service gpsd.socket
# A refused start retries forever (PLAN §9m). In [Unit]: systemd 259's
# systemd-analyze ignores it in [Service] ("Unknown key", seen on a
# workstation, 2026-10-04); the Pi's 257 is believed to read it the same way.
StartLimitIntervalSec=0

[Service]
User=$USER_NAME
Group=$GROUP_NAME
# The kernel refuses this process tree any privilege gain (setuid, so sudo), whatever a sudoers
# file says (PLAN §9m's evening update).
NoNewPrivileges=yes
# Files 0660, directories 2770 by inheritance (PLAN §9m).
UMask=0007
# '+' runs the preflights as root: both read the root-only station.yml, and
# archive-preflight exits 1 as any other user. Any non-zero exit fails the
# start, and Restart= retries it (PLAN §9i).
ExecStartPre=+$CLOCK_PREFLIGHT
ExecStartPre=+$ARCHIVE_PREFLIGHT
# The recording lock, held exactly as long as the writer runs. Blocking, with no
# timeout: a writer started during an update waits, then records (PLAN §9f).
ExecStart=$FLOCK $LOCK $WRITER --min-free-gb $MIN_FREE_GB --source 127.0.0.1:30005 --archive $BEAST_DIR
Restart=on-failure
RestartSec=30s

[Install]
# Load-bearing: after a reboot in the pull window, this is what brings the
# writer back (PLAN §9m).
WantedBy=multi-user.target
EOF
}

install_state_dir() {
  guard_path "$STATE_DIR"
  [[ -d $STATE_DIR ]] || run mkdir -p "$STATE_DIR"
  if [[ $(stat -c '%U:%G' "$STATE_DIR") != "$USER_NAME:$GROUP_NAME" ]]; then
    run chown "$USER_NAME:$GROUP_NAME" "$STATE_DIR"
  fi
  if [[ $(stat -c '%a' "$STATE_DIR") != 2770 ]]; then
    # The leading 0 is load-bearing: GNU chmod keeps a directory's setuid bit
    # under a plain 2770 (7770 became 6770, tried 2026-10-04); 02770 clears it.
    run chmod 02770 "$STATE_DIR"
    [[ $(stat -c '%a' "$STATE_DIR") == 2770 ]] \
      || die "$STATE_DIR is $(stat -c '%a' "$STATE_DIR") after chmod 02770, not 2770; check what it is and what it is mounted on (ls -ld $STATE_DIR; findmnt -T $STATE_DIR), fix it by hand, then re-run this step"
  fi
  log "$STATE_DIR: $(stat -c '%U:%G %a' "$STATE_DIR")"
}

# lock_holders: the PIDs holding the recording lock, one per line. Read with
# lslocks, which does not take the lock: taking it even for an instant could
# make update.sh's flock -n see it held and skip a run.
lock_holders() {
  lslocks -r -n -o PID,PATH 2>/dev/null | awk -v p="$LOCK" '$2 == p { print $1 }' || true
}

# settle <seconds> <deactivating|any>: polls the writer's unit once a second, for
# at most <seconds>, while it is deactivating; with "any", also while a job for
# it is queued or running, or its ExecStartPre= preflights are running
# (activating/start-pre). The job check covers the moment after a --no-block
# restart before the unit has left active. Sets U_ACTIVE, U_SUB and U_JOB to the
# last state seen; returns 1 if it had not settled by then.
U_ACTIVE='' U_SUB='' U_JOB=''
settle() {
  local secs=$1 mode=$2 s i=0
  while :; do
    s=$(systemctl show -p ActiveState,SubState "$UNIT" 2>/dev/null) || true
    U_ACTIVE=$(sed -n 's/^ActiveState=//p' <<<"$s")
    U_SUB=$(sed -n 's/^SubState=//p' <<<"$s")
    U_JOB=''
    if [[ $mode == any ]]; then
      U_JOB=$(systemctl list-jobs --no-legend "$UNIT" 2>/dev/null | awk '{ printf "%s%s/%s", sep, $3, $4; sep = " " }') || true
    fi
    if [[ $U_ACTIVE != deactivating && -z $U_JOB ]] \
       && ! [[ $mode == any && $U_ACTIVE == activating && $U_SUB == start-pre ]]; then
      return 0
    fi
    ((i++ < secs)) || return 1
    if ((i == 1)); then
      log "$UNIT is $U_ACTIVE ($U_SUB${U_JOB:+, job $U_JOB}): waiting up to ${secs} s for it to settle"
    fi
    sleep 1
  done
}

install_step() {
  [[ -f $SRC ]] || die "$SRC is missing from this checkout"
  need_preflights
  install_state_dir

  local bin_changed unit_changed state window holders
  install_if_changed "$SRC" "$WRITER" 0755 root:root
  bin_changed=$CHANGED
  render_unit
  # A missing unit file installs as changed, so a writer found running without
  # one (deleted under it, or loaded from elsewhere) is restarted below: what
  # runs then is this unit, not whatever was loaded before.
  install_if_changed "$WORK/unit" "$UNIT_FILE" 0644 root:root
  unit_changed=$CHANGED
  if ((unit_changed)); then
    run systemctl daemon-reload
  fi
  if ! systemctl is-enabled --quiet "$UNIT"; then
    unit enable "$UNIT"
  fi

  # A writer still stopping is waited for: deciding on "deactivating" would
  # either restart it mid-stop or start it while its old process holds the lock.
  settle 15 deactivating || true
  state=$U_ACTIVE
  case $state in
    active|activating|reloading|refreshing)
      if ((bin_changed || unit_changed)); then
        log "$UNIT is $state ($U_SUB) and its binary or unit changed: restarting it (the writer closes its file on SIGTERM)"
        guard_unit "$UNIT"
        run systemctl --no-block restart "$UNIT"
      else
        log "$UNIT is $state ($U_SUB) and unchanged; left as it is"
      fi
      ;;
    deactivating)
      warn "$UNIT is still deactivating ($U_SUB) after 15 s: this step neither starts nor restarts it. Check: journalctl -u $UNIT -n 50; then re-run this step"
      ;;
    maintenance)
      # systemd reports a service as maintenance while 'systemctl clean' removes
      # its state, cache, logs or runtime directories (from systemd's state
      # table; not seen on a rig).
      warn "$UNIT is in maintenance, which for a service means 'systemctl clean' is running on it: this step neither starts nor restarts it. Re-run this step once 'systemctl show -p ActiveState $UNIT' no longer says maintenance"
      ;;
    *)
      window=$(systemctl show -p ActiveState --value "$WINDOW_UNIT" 2>/dev/null) || true
      holders=$(lock_holders)
      if [[ $window == active ]]; then
        log "$WINDOW_UNIT is active: not starting $UNIT, which would end the pull window. The window's unit starts it when it ends (PLAN §9m)"
      elif [[ -n $holders ]]; then
        warn "$LOCK is held (PID $(tr '\n' ' ' <<<"$holders")): $UNIT is ${state:-unknown} and this step LEAVES IT STOPPED. If the holder is update.sh, it starts the writer itself when it finishes (unless the pull window is active, whose end starts it). Otherwise, once the holder has finished (ps -p <PID>), start it with: sudo systemctl start $UNIT"
      else
        log "$UNIT is ${state:-unknown}: starting it. The preflights decide whether it records; see journalctl -u $UNIT"
        guard_unit "$UNIT"
        run systemctl --no-block start "$UNIT"
      fi
      ;;
  esac
}

# --- verify --------------------------------------------------------------------

# The install tier (PLAN §9c, §9m): the writer and its unit are installed,
# loadable, enabled and not failed, and both preflights can run. ⛔ Never
# is-active of the writer (PLAN §9f): update.sh holds the recording lock while
# it runs this, so the writer cannot be recording then. Its state is printed
# and warned on, never asserted.
verify() {
  need_preflights
  pass "both preflights are installed"

  local out ver
  log "stat $WRITER; $WRITER --version (raw output follows)"
  stat -c '%U:%G %a %n' "$WRITER" 2>&1 || true
  ver=$("$WRITER" --version 2>&1) || true
  printf '%s\n' "$ver"
  echo "----"
  [[ -f $WRITER ]] || die "$WRITER is not installed; run this step without --verify"
  [[ $(stat -c '%U:%G %a' "$WRITER") == "root:root 755" ]] || die "$WRITER is not root:root 0755; run this step without --verify"
  cmp -s "$SRC" "$WRITER" || die "$WRITER differs from $SRC; run this step without --verify"
  [[ $ver == "adsb-writer "* ]] || die "$WRITER --version did not run; is python3 intact? (see above)"
  pass "$WRITER is this checkout's, and runs: $ver"

  render_unit
  cmp -s "$WORK/unit" "$UNIT_FILE" || die "$UNIT_FILE is missing or differs from the rendered unit; run this step without --verify"
  log "systemd-analyze verify $UNIT_FILE (raw output follows)"
  local rc=0
  out=$(systemd-analyze verify "$UNIT_FILE" 2>&1) || rc=$?
  printf '%s\n' "${out:-(no output)}"
  echo "----"
  ((rc == 0)) || die "systemd-analyze verify rejected $UNIT_FILE (exit $rc); see above"
  pass "$UNIT_FILE matches the rendered unit and loads"

  # Settle first. Right after this step's restart --no-block the old writer may
  # still be stopping with its .part open, and archive-preflight renames any
  # .part it finds while the writer is not active; during the unit's own
  # ExecStartPre= the two runs of the preflights would race each other.
  local settled=1
  settle 15 any || settled=0

  # NoNewPrivileges: the observable effect where a writer process runs (its NoNewPrivs in
  # /proc/<MainPID>/status, the flag the kernel enforces, inherited by the writer from flock);
  # otherwise the loaded unit's setting, which is what the next start gets. Read after settling:
  # right after a --no-block restart the old process, started under the old unit, may still run.
  local mpid nnp
  mpid=$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null) || mpid=''
  if [[ $mpid =~ ^[0-9]+$ ]] && ((mpid > 0)) && [[ -r /proc/$mpid/status ]]; then
    nnp=$(awk '$1 == "NoNewPrivs:" { print $2 }' "/proc/$mpid/status" 2>/dev/null) || nnp=''
    log "/proc/$mpid/status ($UNIT's main process): NoNewPrivs ${nnp:-?}"
    if [[ $nnp == 1 ]]; then
      pass "$UNIT's running process (PID $mpid) has NoNewPrivs 1"
    elif ((settled)); then
      die "$UNIT's running process (PID $mpid) has NoNewPrivs ${nnp:-unreadable}, not 1: it was started before the unit had NoNewPrivileges=yes. Restart it (sudo systemctl restart $UNIT), then re-run this step"
    else
      warn "$UNIT's running process (PID $mpid) has NoNewPrivs ${nnp:-unreadable}, not 1, and the unit had not settled: it may be the old writer still stopping. Re-run: setup/steps/40-archive-writer.sh --verify"
    fi
  else
    nnp=$(systemctl show -p NoNewPrivileges --value "$UNIT" 2>&1) || true
    log "no $UNIT process runs; systemctl show -p NoNewPrivileges $UNIT: $nnp"
    [[ $nnp == yes ]] || die "$UNIT has NoNewPrivileges=${nnp:-?}, not yes (daemon-reload not run?); run this step without --verify"
    pass "$UNIT will run with NoNewPrivileges=yes (the loaded unit's setting; no process runs now)"
  fi

  local show load active sub result nrestarts status en
  log "systemctl show $UNIT (raw output follows)"
  show=$(systemctl show -p LoadState,ActiveState,SubState,Result,UnitFileState,NRestarts,ExecMainStatus "$UNIT" 2>&1) || true
  printf '%s\n' "$show"
  echo "----"
  load=$(sed -n 's/^LoadState=//p' <<<"$show")
  active=$(sed -n 's/^ActiveState=//p' <<<"$show")
  sub=$(sed -n 's/^SubState=//p' <<<"$show")
  result=$(sed -n 's/^Result=//p' <<<"$show")
  nrestarts=$(sed -n 's/^NRestarts=//p' <<<"$show")
  status=$(sed -n 's/^ExecMainStatus=//p' <<<"$show")
  en=$(systemctl is-enabled "$UNIT" 2>&1) || true
  [[ $load == loaded ]] || die "$UNIT is $load, not loaded; run this step without --verify"
  [[ $en == enabled ]] || die "$UNIT is '$en', not enabled; run this step without --verify"
  [[ $active != failed ]] || die "$UNIT has failed; check: journalctl -u $UNIT -n 50"
  pass "$UNIT is loaded and enabled, and its ActiveState is not failed (ActiveState=$active SubState=$sub Result=$result NRestarts=$nrestarts ExecMainStatus=$status)"

  # ⚠️ Not failed is not recording, and two states that are not failed hide a
  # writer that will never record:
  #  - StartLimitIntervalSec=0: a refused start never reaches failed. It loops
  #    through activating (auto-restart) every RestartSec=. NRestarts climbs
  #    but reads 0 on the first refusal, and ExecMainStatus stays 0 when it is
  #    a preflight that refuses (stand-in user units, systemd 259, 2026-10-04).
  #  - A required dependency that failed leaves the writer inactive/dead with
  #    Result=success and NRestarts=0 (stand-in user units, systemd 259,
  #    2026-10-04). Only the journal's "Dependency failed" line says so. The
  #    archive mount is Wants=, not required, so a missing drive shows as the
  #    auto-restart loop above instead; this line is now unexpected, and would
  #    mean some other required dependency failed.
  if [[ $sub == auto-restart ]]; then
    warn "$UNIT IS LOOPING: SubState=auto-restart, Result=$result, NRestarts=$nrestarts. Each start is refused and retried every 30 s, and it will not record until the cause clears. ExecMainStatus=$status is the writer's own exit, and stays 0 when a preflight refuses. journalctl -u $UNIT -n 50 says which check refuses"
  elif [[ $nrestarts =~ ^[0-9]+$ ]] && ((nrestarts > 0)); then
    warn "$UNIT has been restarted automatically (NRestarts=$nrestarts). journalctl -u $UNIT -n 50 says why"
  fi
  if [[ $active == inactive ]]; then
    local dep
    dep=$(journalctl -u "$UNIT" -b -q --no-pager -o short-iso 2>/dev/null | grep -F 'Dependency failed' | tail -n1) || true
    if [[ -n $dep ]]; then
      warn "$UNIT IS INACTIVE AFTER A FAILED DEPENDENCY this boot (Result=$result does not show it). Last journal line: $dep. This is unexpected: the archive mount ($MOUNT_UNIT) is only Wants=, so a missing drive should show as an auto-restart loop, not this. Some other required dependency failed; check: systemctl list-dependencies $UNIT; journalctl -b -u $UNIT"
    else
      log "$UNIT is inactive; this boot's journal for it has no 'Dependency failed' line"
    fi
  fi

  # The readiness tier: 0 and 2 pass the install tier, 1 fails it (PLAN §9c, §9i).
  local p
  if ((settled)); then
    for p in "$CLOCK_PREFLIGHT" "$ARCHIVE_PREFLIGHT"; do
      rc=0
      log "$p (raw output follows)"
      "$p" || rc=$?
      echo "----"
      case $rc in
        0) pass "$(basename "$p"): ready (exit 0)" ;;
        2) warn "$(basename "$p"): not ready, for a reason outside the rig (exit 2); see its output above"
           pass "$(basename "$p") ran (exit 2 passes the install tier, PLAN §9c)" ;;
        *) die "$(basename "$p") could not run its check (exit $rc); see its output above" ;;
      esac
    done
  else
    warn "$UNIT had not settled after 15 s (ActiveState=$U_ACTIVE SubState=$U_SUB${U_JOB:+ job $U_JOB}): the preflights were NOT run, so this verify does not show that they can. Run now, archive-preflight could rename the .part of a writer still stopping. Re-run: setup/steps/40-archive-writer.sh --verify"
  fi

  log "stat $STATE_DIR (raw output follows)"
  out=$(stat -c '%U:%G %a' "$STATE_DIR" 2>&1) || true
  printf '%s\n' "$out"
  echo "----"
  [[ $out == "$USER_NAME:$GROUP_NAME 2770" ]] \
    || die "$STATE_DIR is '${out}', not $USER_NAME:$GROUP_NAME 2770; run this step without --verify"
  pass "$STATE_DIR is $USER_NAME:$GROUP_NAME 2770"

  # PLAN §9m: the lock is held by exactly one process whenever the writer or
  # update.sh runs. Neither need be running now, so none is no failure.
  local holders n
  holders=$(lock_holders)
  n=$(grep -c . <<<"$holders") || true
  log "lslocks: holders of $LOCK (raw output follows)"
  lslocks -o COMMAND,PID,TYPE,MODE,PATH 2>&1 | awk -v p="$LOCK" 'NR == 1 || $NF == p' || true
  echo "----"
  if ((n > 1)); then
    warn "$n lslocks lines for $LOCK; one holder is expected (PLAN §9m). Read the lines above"
  else
    log "$LOCK: $n holder(s)"
  fi

  # Printed, not judged: whether it is recording is readiness.
  local newest
  newest=$(find "$BEAST_DIR" -type f -name '*.beast.pcap*' -printf '%T@ %s %P\n' 2>/dev/null | sort -n | tail -n1) || true
  log "newest file under $BEAST_DIR (mtime size path): ${newest:-(none)}"
  if [[ -r $STATE_DIR/writer.json ]]; then
    log "$STATE_DIR/writer.json (selected fields, raw)"
    python3 - "$STATE_DIR/writer.json" <<'PY' || true
import json, sys
with open(sys.argv[1]) as fh:
    s = json.load(fh)
for k in ("state", "connected", "current_file", "frames_in_file", "updated_at", "last_clock"):
    print(f"  {k}: {s.get(k)}")
PY
  else
    log "$STATE_DIR/writer.json: not written yet"
  fi
  if ((settled)); then
    pass "the archive writer is installed"
  else
    pass "the archive writer is installed; its preflights were not run (see the warning above)"
  fi
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
