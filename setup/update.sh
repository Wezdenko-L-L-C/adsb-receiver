#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# setup/update.sh: the updater. PLAN §9f (what it does), §9g (channels), §9h (the stationary gate
# and the denylist), §9m (the recording lock and the pull window).
#
# Installed by setup/steps/50-updater.sh as /usr/local/sbin/adsb-update, and run by
# adsb-update.service (a oneshot, from adsb-update.timer and from the pull window). Run by hand as
# root for the by-hand modes. Self-contained: it sources nothing, because from /usr/local/sbin
# there is no ../lib.sh. The one value it needs from the steps' contract, ADSB_RC_OTHER_ROLE, it
# reads from the tree being run's own setup/lib.sh, so it interprets the exit code that tree emits.
#
#   adsb-update                      timer mode: update to the rig's channel, if it moved
#   adsb-update --retry              timer mode, but retry a candidate that failed within 24 h
#   adsb-update --rev <sha>          by hand: apply one commit from a pushed branch (a Pi test
#                                    before it reaches main); the channel returns at the next run
#   adsb-update --check              is an update pending? Run by the home-gated opener
#                                    (bin/adsb-home-update); prints one line, writes nothing
#   update.sh --bootstrap --role portable|stationary [--set key.path=value]... [--config FILE]
#             [--no-format]          the first build, run by setup/bootstrap.sh from the worktree
#                                    of the commit it builds: that commit is the candidate
#
# In order (PLAN §9f): take the recording lock (flock -n; held means a recording session, so exit
# 0 having changed nothing) → check `applied` → heal an interrupted apt → fetch → resolve the
# candidate (both roles: stable's tip, only once its commit date is update.soak_days old: 0 on the
# 🎒 portable, 7 on the 🏠 stationary, unless station.yml sets it; 0 is no age check at all, so it
# never reads the clock) → unchanged, or a candidate that failed in the last 24 h, means exit
# having written nothing to the rig's applied state (timer mode) → a detached worktree for the
# candidate, under /opt/adsb-receiver/worktrees/<sha12> → every step with --skip-other-role, then
# every step's --verify --skip-other-role → flip the `applied` symlink, write applied-rev, then
# status.json, last, atomically. Any failure, or SIGTERM, SIGINT or SIGHUP: flip back, rewrite
# applied-rev, re-run the applied steps, record failed_step.
# Worktrees kept: during a run the applied one and the candidate (and, in a bootstrap, the tree it
# runs from); after a success only the new applied one; after a rollback the old applied one and
# the failed candidate, until the next run prunes it.
#
# ⚠️ Rollback restores what the applied tree renders; it does not remove what the candidate
#    created (a new step's unit, a new drop-in). status.json says so: rollback.complete is false,
#    and rollback.leftovers_possible names the candidate's steps the applied tree lacks.
#
# A failed candidate (status.json: result rolled_back or failed, candidate_rev, finished_at) is
# skipped by the timer for 24 h after that run, then retried once a day until the channel moves.
# --retry and --rev override that.
#
# `applied` (PLAN §9f's evening update):
#   - a dangling or unreadable `applied` is never a first build: if applied-rev names a commit the
#     clone has, its worktree is recreated and the run goes on as a normal one; otherwise the run
#     records result failed, runs no step, and exits 1;
#   - no `applied` at all is a first build only under --bootstrap, or for the timer when
#     status.json says incomplete and names the bootstrap's candidate_rev: every timer run then
#     runs the first build again at that same commit, pinned (after each boot and daily; offline
#     too, since the commit is already in the clone, so an offline rig spends one attempt per
#     boot) while the recording lock is free; on a recording portable the writer holds it from
#     every boot, so the pull window's run is the one that completes it. It follows the channel
#     only after the first build completes. The timer with no `applied` and no such status
#     refuses: there is no build on this rig.
#
# First-build mode: step 50-updater first, then the rest in order; a failing step is recorded and
# the next one runs; it never rolls back; `applied` flips only when every step passes, else
# status.json says incomplete. A signal ends it as incomplete too, with exit 128+N; an unexpected
# stop of this script itself (set -e) also records incomplete, so the timer retries it, and exits
# with the failing command's code. A failed fetch is not fatal there: it builds from what it has.
# The stationary gate (PLAN §9h) is not applied: there is no running rig to protect yet. Only
# --bootstrap on a portable's first build runs setup/foundation/ (the RTC overlay, the archive
# format); never the timer. So a drive plugged in after the bootstrap is not formatted by any
# timer run: format it by hand with the command step 30 prints, or run the bootstrap again while
# the build is still incomplete. The foundation's record (status.json foundation{}, with the
# notes its scripts printed) is carried into every later status.json.
#
# ⛔ It never reboots (PLAN §9l); steps record a needed reboot in /run/adsb-receiver/reboot-required,
#    and setup/bootstrap.sh is the one thing that may act on it, once, on a first build.
# ⛔ Its own code never stops the writer (a step may: 40 restarts it when its unit or binary
#    changed, under the lock, so it is not recording then). At its end it starts the writer only if
#    the writer is enabled and inactive and the pull window is not active, activating or
#    deactivating.
# ⛔ The update path takes no role flag: the role comes from station.yml. --role exists only with
#    --bootstrap, to write that station.yml before any step runs.
#
# station.yml: after the first build, /etc/adsb-receiver/station.yml is the copy that is edited.
# The bootstrap writes a seed, config/station.yml, into the candidate's worktree only when there is
# no /etc copy yet or it was given --config or --set in that run; step 05-config installs it, and
# drop_seeds then removes it. So no rollback, bootstrap re-run or timer run that reaches drop_seeds
# installs an old seed over the /etc copy; a signal before the steps leaves the seed on disk until
# the next run's drop_seeds. ⚠️ An edit to the /etc copy takes effect only when the steps next
# run: a timer run that finds the channel unchanged runs no step, so the edit waits for the next
# candidate, a bootstrap re-run, or the steps that read it, run by hand.
#
# Exit codes: 0 applied, unchanged, a candidate skipped in its 24 h backoff, (timer) the lock held,
# or (portable timer) no network; 1 failed, including not root, (by hand) the lock held, no build
# on this rig, and a damaged `applied`; 2 rolled back; 3 incomplete (first build); 4 not ready (the
# stationary gate held the update back); 64 bad usage; 128+N (143 SIGTERM, 130 SIGINT, 129 SIGHUP)
# when a signal arrived before anything changed (nothing recorded then), or during a first build
# (recorded as incomplete). --check has its own, below.
#
# --check (PLAN §9f's 2026-10-04 (night) update; §9e's 2026-10-05 (a)): no lock, and nothing
# written: no status.json, no log directory, nothing under /var/lib, no apt heal. It reads
# station.yml, status.json and `applied` (a dangling `applied` is read through applied-rev, as a
# run would recover it, but nothing is recreated), fetches, and runs the same resolver a timer run
# does, then the same 24 h backoff. So "pending" means a timer-mode run in a window would try a
# candidate. ⚠️ The backoff is the implementer's reading of "pending", not ruled: without it, a
# window opened inside the backoff would run nothing (rejected option C's gap "for nothing").
# One line on stdout, "pending: ..." or "not pending: ..."; everything else on stderr.
#   - An incomplete first build (status.json: result incomplete, candidate_rev) is always pending,
#     with no fetch, since the pin does not move. Its line is §9e's (a) reason line, from
#     status.json's result, candidate_rev, failed_steps and finished_at only.
#   - The 🏠 stationary's gate is not evaluated (it runs the preflights; --check answers the 🎒
#     portable opener's question).
#   - Where a timer run would itself fail before any step (no build on the rig; `applied`
#     dangling with applied-rev unusable, where the run would record failed; the pinned commit
#     missing from the clone; no clone; no origin/stable; station.yml unreadable), --check says so
#     on stdout, "not pending: a timer run here would fail too, before any step: <why>", and exits
#     13: the rig needs a hand, and a window would change nothing.
#   - A signal ends it at once, with 128+N, its fetch killed: it has written nothing, so there is
#     nothing to clean up. (Its fetch runs in the background so that `wait` can be interrupted;
#     that `timeout` passes the signal on to git is GNU timeout's documented behavior, not seen.)
# Exit codes: 0 pending; 10 not pending (the channel is unchanged, or its tip is under the soak);
# 11 not pending (the candidate failed within 24 h: the backoff); 12 not pending (the fetch
# failed); 13 not pending, a timer run would fail (above); 1 could not tell (not root, a tool
# missing), with an "xx  FAIL:" line on stderr; 64 bad usage; 128+N after a signal.
#
# status.json's trigger and opened_by (the same update), read once, when the run takes the lock:
#   - adsb-pull-window.service active, activating or deactivating: trigger window, and opened_by
#     adsb-home-update if the opener's marker (/run/adsb-home-update/window-opened-by) exists AND
#     adsb-home-update.service is activating (the opener is running), else hand (a window started
#     by hand, by tools/pull-archive, or by setup/bootstrap.sh's (b)). A marker left behind with no
#     opener running is ignored, so it cannot mislabel a later window;
#   - no window: both null. `mode` already says timer, rev or bootstrap, and a timer-mode run
#     cannot tell the timer from `adsb-update` typed by hand, so "timer" there would be a guess.
#     The implementer's choice, not ruled.
# A timer run that finds the lock held prints one line holding ADSB-UPDATE-SKIPPED (under systemd
# it starts with a <N> priority prefix, which the journal turns into the line's priority: warning
# when the pull window is open, where the writer should have stopped first, PLAN §9m). A by-hand
# run that finds the lock held prints the holder and advice for it instead, and exits 1.
#
# What has run on hardware: the portable, mobile-adsb: the first build through setup/bootstrap.sh
# on 2026-10-04 (incomplete: steps failed on a hung stick) and on 2026-10-05 (applied), and a
# --rev run of 42b5115. ⚠️ Unverified: all of it on the stationary.

set -euo pipefail

readonly BASE=/opt/adsb-receiver
readonly REPO=$BASE/repo
readonly WT_DIR=$BASE/worktrees
readonly APPLIED=$BASE/applied
readonly STATE=/var/lib/adsb-receiver
readonly APPLIED_REV=$STATE/applied-rev
readonly STATUS=$STATE/status.json
readonly WRITER_JSON=$STATE/writer/writer.json
readonly LOG_ROOT=/var/log/adsb-receiver
readonly KEEP_RUNS=20
readonly RUN_DIR=/run/adsb-receiver
readonly LOCK=$RUN_DIR/recording.lock
readonly REBOOT_FLAG=$RUN_DIR/reboot-required
# The opener's root-owned directory (lib.sh's ADSB_HOME_DIR), and its marker.
readonly HOME_DIR=/run/adsb-home-update
readonly WINDOW_MARK=$HOME_DIR/window-opened-by
readonly ETC_YML=/etc/adsb-receiver/station.yml
readonly WRITER_UNIT=adsb-writer.service
readonly WINDOW_UNIT=adsb-pull-window.service
readonly HOME_UNIT=adsb-home-update.service
readonly FIRST_STEP=50-updater
# The soak's role default, the one difference between the roles' channel (PLAN §9g's 2026-10-05
# update); update.soak_days in station.yml overrides it. The portable template never carries it.
readonly SOAK_DAYS_PORTABLE=0 SOAK_DAYS_STATIONARY=7
readonly FETCH_TIMEOUT=300
readonly PREFLIGHT_TIMEOUT=120
readonly BACKOFF_SECS=86400   # a failed candidate is skipped this long after its run

readonly RC_FAILED=1 RC_ROLLED_BACK=2 RC_INCOMPLETE=3 RC_NOT_READY=4 RC_USAGE=64
# --check's "not pending" codes (the header).
readonly RC_CHECK_NONE=10 RC_CHECK_BACKOFF=11 RC_CHECK_NO_FETCH=12 RC_CHECK_WOULD_FAIL=13

# --- State ---------------------------------------------------------------------

MODE=timer REV_ARG='' ROLE_ARG='' CONFIG_ARG='' NO_FORMAT=0 RETRY=0 CHECK=0
CHECKING=0 CHECK_CHILD=''   # check_pending under way; its background fetch's PID
SETS=()
SELF_WT='' SELF_SHA=''   # the worktree this script runs from, and its commit (--bootstrap only)
PIN=''             # a timer run finishing an incomplete first build: the bootstrap's commit
PREP_HOW=''        # prepare_config's outcome: keep, copied or rendered
WT_PATH=''         # ensure_worktree's result
WORK=''            # scratch, removed at exit
FIRST_BUILD=0 ROLE='' CHANNEL='' CAND='' CAND_WT='' OLD_SHA='' OLD_WT=''
RUN_ID='' RUN_LOGS='' STARTED_AT='' RESULT='' NOTE='' FAILED_STEP=''
FAILED_STEPS=()
NOTES=()           # this run's notes for status.json, e.g. the RTC overlay's charge-path line
FOUND_NOTES=()     # the foundation scripts' NOTE: lines, kept in status.json's foundation{} for good
ROLLBACK_RESULT='' ROLLBACK_FAILED_STEP=''
LEFTOVERS=()       # the candidate's steps the applied tree lacks (a rollback leaves what they made)
LAST_RESULT='' LAST_CAND='' LAST_FINISHED=0 LAST_FINISHED_TXT=''   # the previous status.json
LAST_FAILED_STEPS=''   # its failed_steps, joined with ", " (else its failed_step), for --check's line
TRIGGER='' OPENED_BY=''   # window and adsb-home-update or hand, or both empty (null): the header
GATE=''            # stationary only: passed / held
FOUND_RTC=''       # the RTC overlay's outcome, first build only
FETCH_OK=0 LOCKED=0 TERMINATED=0 TERM_SIG='' STATUS_WRITTEN=0 FLIPPED=0 FAILED_ON_PURPOSE=0
MAIN_PID=$BASHPID
STAGE=start        # start, steps, flip, rollback, finished
OTHER_RC=100
declare -A INSTALL=() VERIFY=() SECS=()

# --- Output --------------------------------------------------------------------

# --check's stdout is its one verdict line, so its progress goes to stderr.
log()  { if [[ $MODE == check ]]; then printf '==> %s\n' "$*" >&2; else printf '==> %s\n' "$*"; fi; }
warn() { printf '!!  WARNING: %s\n' "$*" >&2; }
# Inside check_pending, a failure is the one a timer run would meet too: --check's exit 13.
fail() {
  if ((CHECKING)); then
    printf 'not pending: a timer run here would fail too, before any step: %s\n' "$*"
    exit "$RC_CHECK_WOULD_FAIL"
  fi
  printf 'xx  FAIL: %s\n' "$*" >&2; FAILED_ON_PURPOSE=1; exit "$RC_FAILED"
}
usage_error() { printf 'xx  %s\n' "$*" >&2; printf 'usage: see the header of %s\n' "$0" >&2; exit "$RC_USAGE"; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# start_run_log: from here on, everything this run prints also goes to <run>/run.log. Created only
# once the run will change something, so an unchanged or lock-held run leaves no trace on disk.
start_run_log() {
  RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
  local n=1
  # Two runs in one second (a by-hand run right after another) get separate directories.
  while [[ -e $LOG_ROOT/$RUN_ID ]]; do RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$((n++)); done
  RUN_LOGS=$LOG_ROOT/$RUN_ID
  install -d -m 0750 -o root -g adm "$LOG_ROOT" 2>/dev/null || install -d -m 0750 "$LOG_ROOT"
  install -d -m 0750 -o root -g adm "$RUN_LOGS" 2>/dev/null || install -d -m 0750 "$RUN_LOGS"
  exec 3>&1 4>&2
  # The tee ignores SIGTERM, SIGINT and SIGHUP, so it outlives systemd's stop signal, a Ctrl-C and
  # a dropped SSH session, and the rollback after any of them is still logged (SIGKILL at
  # TimeoutStopSec= ends it). It ignores SIGPIPE and only warns on a write error, so a terminal
  # that went away does not stop it writing the file. SIGINT is ignored by tee's own -i: bash
  # resets SIGINT when an asynchronous subshell (this process substitution) execs, whatever
  # `trap ''` said (seen with bash 5 on a workstation; the other three stay ignored). `exec`
  # leaves no bash in that process, so none of this script's traps can run there.
  exec > >(trap '' TERM INT HUP PIPE; exec tee -i --output-error=warn -a "$RUN_LOGS/run.log" >&3) 2>&1
  log "run $RUN_ID: mode $MODE; logs in $RUN_LOGS"
}

# logtee <file>: a step's or a foundation script's own log, as a pipeline's last stage. Ignores
# the stop signals for the same reason as the run log's tee: so the step's own cleanup, after a
# signal, can still print without dying of SIGPIPE.
logtee() {
  trap '' TERM INT HUP PIPE
  exec tee -i --output-error=warn -a "$1"
}

# shellcheck disable=SC2317,SC2329  # invoked by trap (0.9 says SC2317, 0.11 SC2329)
# on_signal <TERM|INT|HUP>: systemd's SIGTERM reaches every process in the unit, and a Ctrl-C
# every process in the foreground group, so the running step usually gets the same signal and is
# killed by it rather than allowed to finish (the log tees ignore it). Bash runs this once that
# step has ended; then no further step runs and the main flow sees TERMINATED and rolls back
# (PLAN §9f). Only the main shell acts: a subshell that inherited the trap must not.
on_signal() {
  local code
  case $1 in TERM) code=143 ;; INT) code=130 ;; *) code=129 ;; esac
  [[ $BASHPID == "$MAIN_PID" ]] || exit "$code"
  TERMINATED=1 TERM_SIG=$1
  warn "SIG$1 received: no further step runs; a normal run rolls back, a first build records itself as incomplete" || true
}

# sig_exit: the exit code for a signal that arrived before anything changed.
sig_exit() {
  case $TERM_SIG in INT) echo 130 ;; HUP) echo 129 ;; *) echo 143 ;; esac
}

# --- Small helpers ------------------------------------------------------------

# yml_get <file> <dotted.key>: print the value ("" for null); exit 3 if absent. The same contract
# as lib.sh's station_get, written again here because this file sources nothing.
yml_get() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
with open(sys.argv[1]) as fh:
    node = yaml.safe_load(fh) or {}
for key in sys.argv[2].split("."):
    if not isinstance(node, dict) or key not in node:
        sys.exit(3)
    node = node[key]
print("" if node is None else ("true" if node is True else "false" if node is False else node))
PY
}

# station_file: the installed copy, else a worktree's (a first build whose 05-config has not run).
station_file() {
  local f
  if [[ -r $ETC_YML ]]; then echo "$ETC_YML"; return 0; fi
  for f in ${CAND_WT:+"$CAND_WT/config/station.yml"} "$WT_DIR"/*/config/station.yml; do
    if [[ -r $f ]]; then echo "$f"; return 0; fi
  done
  return 1
}

# lock_holder: who holds the recording lock, as "<unit or command> (PID n)". lslocks resolves
# another user's lock path only as root, which this is. The unit comes from the PID's cgroup.
lock_holder() {
  local pid unit=''
  pid=$(lslocks -r -n -o PID,PATH 2>/dev/null | awk -v p="$LOCK" '$2 == p { print $1; exit }') || true
  [[ -n $pid ]] || { echo "an unknown process"; return 0; }
  unit=$(sed -nE 's#^0::.*/([^/]+\.(service|scope))$#\1#p' "/proc/$pid/cgroup" 2>/dev/null | head -n1) || true
  echo "${unit:-$(cat "/proc/$pid/comm" 2>/dev/null || echo '?')} (PID $pid)"
}

sha12() { printf '%s' "${1:0:12}"; }

# --- Arguments -----------------------------------------------------------------

parse_args() {
  while (($#)); do
    case $1 in
      --bootstrap) MODE=bootstrap ;;
      --rev) [[ -n ${2:-} ]] || usage_error "--rev needs a commit"; REV_ARG=$2; shift ;;
      --role) [[ -n ${2:-} ]] || usage_error "--role needs portable or stationary"; ROLE_ARG=$2; shift ;;
      --set) [[ ${2:-} == *=* ]] || usage_error "--set needs key.path=value"; SETS+=("$2"); shift ;;
      --config) [[ -n ${2:-} ]] || usage_error "--config needs a file"; CONFIG_ARG=$2; shift ;;
      --no-format) NO_FORMAT=1 ;;
      --retry) RETRY=1 ;;
      --check) CHECK=1 ;;
      -h|--help) sed -n '3,/^$/p' "$0"; exit 0 ;;   # the header: line 3 to the first blank line
      *) usage_error "unknown argument: $1" ;;
    esac
    shift
  done
  if [[ $MODE != bootstrap ]]; then
    [[ -z $ROLE_ARG && -z $CONFIG_ARG && ${#SETS[@]} -eq 0 && $NO_FORMAT -eq 0 ]] \
      || usage_error "--role, --set, --config and --no-format belong to --bootstrap only; the update path takes the role from station.yml"
    [[ -n $REV_ARG ]] && MODE=rev
    if ((CHECK)); then
      [[ -z $REV_ARG && $RETRY -eq 0 ]] || usage_error "--check takes no other argument: it asks what a timer run would do"
      MODE=check
    fi
  else
    ((CHECK == 0)) || usage_error "--check does not go with --bootstrap"
    [[ $ROLE_ARG == portable || $ROLE_ARG == stationary ]] \
      || usage_error "--bootstrap needs --role portable or --role stationary"
    # Refused rather than honored: the bootstrap builds the commit it runs from (setup/bootstrap.sh
    # chose it), so a second commit would mean running one tree's updater over another's steps.
    # Test a commit with --rev once the rig is built.
    [[ -z $REV_ARG ]] || usage_error "--rev does not go with --bootstrap: the bootstrap builds the commit it runs from; use --rev once the rig is built"
    ((RETRY == 0)) || usage_error "--retry does not go with --bootstrap"
  fi
  return 0
}

# --- The first build's config (--bootstrap) -------------------------------------

# prepare_config: decide station.yml before anything else happens, so a stationary with no
# position is refused at the start. Writes $WORK/station.yml, or nothing when an installed config
# is kept as it is.
#   base: --config FILE; else the installed /etc copy; else the role's template from this checkout.
#   --set key.path=value edits the base. The key must already exist. The value is a string unless
#   the key's current value is not a string and the value is plainly null, true or false, a
#   decimal number with no leading zero, or a [list] or {map}; quote it ("...") to force a string.
#   So 00000001 and 1090 stay strings where the template holds a string, and on, no and 1e3 are
#   never booleans or floats.
# Sets PREP_HOW: keep (the installed config, untouched), copied, or rendered.
prepare_config() {
  local base kind
  if [[ -n $CONFIG_ARG ]]; then
    [[ -r $CONFIG_ARG ]] || fail "--config $CONFIG_ARG: not a readable file"
    base=$CONFIG_ARG kind=file
  elif [[ -r $ETC_YML ]]; then
    base=$ETC_YML kind=installed
  else
    base=$SELF_WT/config/station.$ROLE_ARG.example.yml kind=template
    [[ -r $base ]] || fail "no template $base in this checkout"
  fi
  PREP_HOW=$(python3 - "$base" "$kind" "$ROLE_ARG" "$WORK/station.yml" "${SETS[@]}" <<'PY'
import numbers, re, shutil, sys, yaml
base, kind, role, out, *sets = sys.argv[1:]

def die(msg):
    print(f"xx  FAIL: {msg}", file=sys.stderr)
    sys.exit(1)

def typed(key, raw, old):
    """The --set value: a string unless plainly something else (see the shell comment above)."""
    if raw in ("", "null", "~"):
        return None
    if raw[0] in "\"'":
        v = yaml.safe_load(raw)
        if not isinstance(v, str):
            die(f"--set {key}: {raw} does not read as a quoted string")
        return v
    if isinstance(old, str):
        return raw
    if raw in ("true", "false"):
        return raw == "true"
    if re.fullmatch(r"-?(0|[1-9][0-9]*)", raw):
        return int(raw)
    if re.fullmatch(r"-?(0|[1-9][0-9]*)\.[0-9]+", raw):
        return float(raw)
    if raw[0] in "[{":
        try:
            return yaml.safe_load(raw)
        except yaml.YAMLError as e:
            die(f"--set {key}: {raw} does not parse as a YAML list or map: {e}")
    return raw

try:
    with open(base) as fh:
        doc = yaml.safe_load(fh)
except Exception as e:
    die(f"{base} does not parse as YAML: {e}")
if not isinstance(doc, dict):
    die(f"{base} is not a YAML mapping")
got = (doc.get("station") or {}).get("role") if isinstance(doc.get("station"), dict) else None
if got != role:
    die(f"--role {role}, but {base} says station.role: {got!r}. The bootstrap does not change a rig's role")
for item in sets:
    key, _, raw = item.partition("=")
    path = key.split(".")
    node = doc
    for part in path[:-1]:
        if not isinstance(node, dict) or not isinstance(node.get(part), dict):
            die(f"--set {key}: {part!r} is not a block in {base}")
        node = node[part]
    if path[-1] not in node:
        die(f"--set {key}: no such key in {base}; use --config FILE for a config with other keys")
    if key == "station.role":
        die("--set station.role: the role is --role")
    node[path[-1]] = typed(key, raw, node[path[-1]])
if role == "stationary":
    pos = doc.get("position")
    bad = [k for k in ("latitude", "longitude", "altitude_m")
           if not isinstance(pos, dict) or isinstance(pos.get(k), bool)
           or not isinstance(pos.get(k), numbers.Real)]
    if bad:
        die("the stationary rig needs its surveyed position before anything is built: "
            + ", ".join("position." + k for k in bad) + " missing. Add --set position.latitude=... "
            "--set position.longitude=... --set position.altitude_m=..., or --config FILE")
elif "position" in doc:
    die("a portable rig takes its position from GPS; remove the position: block (PLAN §9b)")
if kind == "installed" and not sets:
    print("keep")
    sys.exit(0)
if not sets:
    shutil.copyfile(base, out)
    print("copied")
    sys.exit(0)
with open(out, "w") as fh:
    fh.write("# Written by setup/update.sh --bootstrap from " + base.rsplit("/", 1)[-1]
             + " with --set " + ", ".join(s.partition("=")[0] for s in sets) + ".\n"
             "# The comments explaining each key are in config/station.*.example.yml.\n")
    yaml.safe_dump(doc, fh, sort_keys=False, default_flow_style=False, allow_unicode=True)
print("rendered")
PY
  ) || fail "station.yml was not written; fix the above and run the same command again"
}

# --- The recording lock ----------------------------------------------------------

take_lock() {
  if [[ ! -e $LOCK ]]; then
    # Before 05-config's tmpfiles.d entry exists (a first build). That entry then sets the owner
    # and mode; flock(1) locks a file opened read-only, so root owning it now is harmless.
    install -d -m 0755 "$RUN_DIR"
    : >>"$LOCK"
  fi
  exec 9<"$LOCK"
  if ! flock -n 9; then
    exec 9<&-
    if [[ $MODE == timer ]]; then
      lock_held_timer
      exit 0
    fi
    lock_held_by_hand
    exit "$RC_FAILED"
  fi
  LOCKED=1
}

# lock_held_by_hand: the refusal of a run by hand, or by setup/bootstrap.sh, that finds the lock
# held, with advice for the holder it names: the writer (a recording session), a pull window's
# update, or anything else. ADSB_BOOTSTRAP_WINDOW is setup/bootstrap.sh's hint, read only under
# --bootstrap: why the bootstrap did or did not end the session itself (opened, no-unit, built,
# not-writer). It is passed because nothing else tells this script that its caller is the bootstrap
# (update.sh --bootstrap is also run by hand, and by a bootstrap.sh older than the hint), and the
# refusal must not tell the bootstrap's own user that the bootstrap ends the session when it just
# did not. With no hint, the text claims nothing about what a bootstrap did.
lock_held_by_hand() {
  local holder win why='' again='run this again'
  holder=$(lock_holder)
  win=$(systemctl is-active "$WINDOW_UNIT" 2>/dev/null) || true
  [[ $MODE == bootstrap ]] && again='run the bootstrap again'
  printf 'xx  the recording lock is held by %s.\n' "$holder" >&2
  if [[ $holder == "$WRITER_UNIT "* ]]; then
    if [[ $MODE == bootstrap ]]; then
      case ${ADSB_BOOTSTRAP_WINDOW:-} in
        no-unit) why="$WINDOW_UNIT is not loaded on this rig" ;;
        built) why="this rig already has a build, and the bootstrap ends a session only on a first build" ;;
        opened) why="it ended one through the pull window, and the writer holds the lock again" ;;
        not-writer) why="the writer did not hold the lock when the bootstrap looked" ;;
      esac
    fi
    if [[ -n $why ]]; then
      printf '    A recording session is on, and the bootstrap did not end it: %s.\n' "$why" >&2
    else
      printf '    A recording session is on: run the bootstrap (setup/bootstrap.sh), which ends it itself on\n' >&2
      printf '    a first build; or end it by hand.\n' >&2
    fi
    printf '    By hand: start the pull window (sudo systemctl start %s), %s once the\n' "$WINDOW_UNIT" "$again" >&2
    printf '    adsb-update.service it starts has finished, then stop the window (sudo systemctl stop %s);\n' "$WINDOW_UNIT" >&2
    printf '    or, where no window unit exists, stop the writer by hand (sudo systemctl stop %s) and %s.\n' "$WRITER_UNIT" "$again" >&2
  elif [[ $win == active || $win == activating || $win == deactivating ]]; then
    printf '    A pull window is open and its update is running; wait for it to finish, then %s.\n' "$again" >&2
  else
    printf '    %s holds the lock; wait for it to finish, then %s.\n' "$holder" "$again" >&2
  fi
}

# lock_held_timer: the timer's lock-held exit is 0 (ruled), so it is told apart by its line: it
# starts ADSB-UPDATE-SKIPPED, and under systemd it carries a journal priority (the <N> prefix,
# SyslogLevelPrefix=): warning when the pull window is open, where the writer should already have
# stopped (PLAN §9m's ordering), notice otherwise.
lock_held_timer() {
  local holder win prio=5 why="a recording session is on, so no update (PLAN §9f)"
  holder=$(lock_holder)
  win=$(systemctl is-active "$WINDOW_UNIT" 2>/dev/null) || true
  if [[ $win == active || $win == activating || $win == deactivating ]]; then
    prio=4
    why="the pull window is $win, so the writer should have stopped before this run; it has not, and this window updates nothing (PLAN §9m's ordering did not hold)"
  fi
  local pre=''
  [[ -n ${INVOCATION_ID:-} ]] && pre="<$prio>"
  printf '%sADSB-UPDATE-SKIPPED lock-held: the recording lock is held by %s: %s. Nothing was written\n' "$pre" "$holder" "$why"
}

release_lock() {
  if ((LOCKED)); then
    # -u releases the lock for the whole open file, even where a child inherited the descriptor.
    flock -u 9 || true
    exec 9<&-
    LOCKED=0
  fi
}

# writer_start_rule: at the end of a run, after the lock is released (PLAN §9f, §9m). Inside the
# pull window a start would stop the window mid-pull; the window's own end starts the writer, and
# a window that is deactivating is waiting for this run to end before it does. A refusing writer
# is activating (auto-restart), not inactive, so it is left alone.
writer_start_rule() {
  local en act win
  en=$(systemctl is-enabled "$WRITER_UNIT" 2>/dev/null) || true
  act=$(systemctl is-active "$WRITER_UNIT" 2>/dev/null) || true
  win=$(systemctl is-active "$WINDOW_UNIT" 2>/dev/null) || true
  if [[ $en == enabled && $act == inactive && $win != active && $win != activating && $win != deactivating ]]; then
    log "the writer is enabled and inactive, and no pull window is open: starting it"
    systemctl start --no-block "$WRITER_UNIT" || warn "systemctl start $WRITER_UNIT failed"
  fi
}

# window_context: status.json's trigger and opened_by (the header). Called once the lock is taken,
# so it describes the window this run is inside; the opener removes its marker only after the
# window's update has finished. The marker's content is not read: its presence, with the opener's
# unit running, is the record.
window_context() {
  local win
  win=$(systemctl is-active "$WINDOW_UNIT" 2>/dev/null) || true
  if [[ $win == active || $win == activating || $win == deactivating ]]; then
    TRIGGER=window OPENED_BY=hand
    if [[ -e $WINDOW_MARK ]] \
       && [[ $(systemctl is-active "$HOME_UNIT" 2>/dev/null) == activating ]]; then
      OPENED_BY=adsb-home-update
    fi
  fi
  return 0
}

# --- Git -----------------------------------------------------------------------

fetch() {
  [[ -d $REPO ]] || fail "no clone at $REPO; build the rig with setup/bootstrap.sh first"
  # No credential prompt, ever: the Pi carries none (PLAN §9a), and a 401 must fail, not ask.
  if GIT_TERMINAL_PROMPT=0 timeout "$FETCH_TIMEOUT" git -C "$REPO" fetch --prune --quiet origin; then
    FETCH_OK=1
  else
    FETCH_OK=0
  fi
}

# channel_of <role>: the branch a role tracks: stable, for both (PLAN §9g's 2026-10-05 update; the
# soak is the only role difference). The role argument stays so the callers need not change.
channel_of() { echo stable; }

# resolve_candidate: CAND for the mode and the rig's channel. Returns 1 when the channel has no
# eligible commit (stable's tip is younger than the soak), which a built rig treats as unchanged.
resolve_candidate() {
  local tip days def src f tip_ct now age
  CHANNEL=$(channel_of "$ROLE")
  if [[ $MODE == bootstrap ]]; then
    # The commit setup/bootstrap.sh chose and runs this from. On a first build, either role, that
    # is stable's tip without the soak: the bench is attended; the soak protects the unattended rig.
    CAND=$SELF_SHA
    if ((FETCH_OK)) && ! git -C "$REPO" merge-base --is-ancestor "$CAND" "origin/$CHANNEL" 2>/dev/null; then
      NOTE="built from $(sha12 "$CAND"), which is not on origin/$CHANNEL"
      warn "$NOTE"
    fi
    return 0
  fi
  if [[ -n $PIN ]]; then
    CAND=$PIN
    NOTE="finishing the first build at the bootstrap's commit $(sha12 "$PIN"); the channel is followed once it completes"
    return 0
  fi
  if [[ $MODE == rev ]]; then
    CHANNEL=rev
    CAND=$(git -C "$REPO" rev-parse --verify --quiet "$REV_ARG^{commit}") \
      || fail "--rev $REV_ARG: no such commit in the clone (pushed, and fetched?)"
    [[ -n $(git -C "$REPO" branch -r --contains "$CAND" 2>/dev/null) ]] \
      || fail "--rev $REV_ARG is on no pushed branch; push it first (the Pi runs only what is on GitHub)"
    return 0
  fi
  tip=$(git -C "$REPO" rev-parse --verify --quiet "origin/stable^{commit}") \
    || fail "the clone has no origin/stable. CI creates it on the first green push to main (PLAN §9g)"
  local deflabel="the stationary's default"
  def=$SOAK_DAYS_STATIONARY
  [[ $ROLE == portable ]] && def=$SOAK_DAYS_PORTABLE deflabel="the portable's default"
  days=$def src=$deflabel
  if f=$(station_file) && days=$(yml_get "$f" update.soak_days 2>/dev/null); then
    src="update.soak_days in $f"
  else
    days=$def
  fi
  if ! [[ $days =~ ^[0-9]+$ ]]; then
    warn "update.soak_days '$days' in ${f:-station.yml} is not a whole number of days; rejected, using $def, $deflabel"
    days=$def src="$deflabel; update.soak_days in ${f:-station.yml} was rejected"
  fi
  # Base 10 from here on: the regex accepts a leading zero (YAML hands "08" through as a string),
  # which bash arithmetic would read as octal, and 08 or 09 as an error, failing the comparison
  # below silently so the rig never updated.
  days=$((10#$days))
  # A soak of 0 is no age check at all, not "aged at least zero seconds": that would depend on the
  # Pi's clock being past the commit date (PLAN §9g's 2026-10-05 update). Nothing below runs.
  if ((days == 0)); then
    log "soak 0: the channel's tip is the candidate ($src)"
    CAND=$tip
    return 0
  fi
  # Soak (PLAN §9g's evening update): stable's TIP, and only once the tip's commit date is soak_days
  # old. Never "the newest commit older than soak_days": that would apply a bad commit the day it
  # turned old, whatever younger revert followed it. With the tip, a revert on main (the brake)
  # resets the clock, and the bad commit is never applied alone.
  tip_ct=$(git -C "$REPO" log -1 --format=%ct "$tip") || fail "could not read the commit date of stable's tip"
  now=$(date +%s)
  age=$((now - tip_ct))
  if ((age >= days * 86400)); then
    CAND=$tip
    return 0
  fi
  NOTE="stable's tip $(sha12 "$tip") is $((age / 86400)) days old, under update.soak_days ($days, $src; the role default is 0 on the portable, 7 on the stationary, unless station.yml sets it); it applies once it has been quiet that long"
  return 1
}

# ensure_worktree <sha>: a detached worktree at the SHA, reused if it is already there (`reset
# --hard` leaves its untracked config/station.yml; drop_seeds decides that file's fate). Sets
# WT_PATH; never run in $(...), so its fail ends this script, not a subshell.
ensure_worktree() {
  local sha=$1 wt head
  wt=$WT_DIR/$(sha12 "$sha")
  if [[ -d $wt ]]; then
    head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || head=''
    if [[ $head == "$sha" ]]; then
      git -C "$wt" reset --hard --quiet "$sha" || fail "could not reset the worktree $wt"
      WT_PATH=$wt
      return 0
    fi
    git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || rm -rf -- "$wt"
  fi
  # A worktree whose directory is gone is still registered, and `worktree add` refuses its path
  # until the registration is pruned (the dangling-applied recovery meets exactly this).
  git -C "$REPO" worktree prune
  install -d -m 0755 "$WT_DIR"
  git -C "$REPO" worktree add --detach --quiet "$wt" "$sha" || fail "git worktree add $wt failed"
  WT_PATH=$wt
}

# drop_seeds: a worktree's config/station.yml is only the seed of $ETC_YML, written by a bootstrap
# for its own run. Once $ETC_YML exists, that file is removed from every worktree, so no later run
# can install it over the installed copy: not a rollback to that tree, not a bootstrap re-run at
# the same commit, not the timer finishing a first build there. Run before this run writes its own
# seed, again after the candidate's steps, and by on_exit before its rollback. While there is no
# $ETC_YML (a first build whose 05-config has not run) the seed is the only config, and stays.
# ⚠️ After the steps, this run's seed is removed whether or not 05-config installed it: if this
# run was given --set or --config and 05-config did not finish ok (INSTALL[05-config]: an earlier
# step failed, or the run was stopped), it warns that that input was discarded. A failed rm is a
# warning, never an exit: under set -e it would otherwise end the run (and roll back a candidate
# whose steps had all passed).
drop_seeds() {
  local f mine=''
  [[ -f $ETC_YML ]] || return 0
  # This run's seed: written only once STAGE has left start, and only by a bootstrap.
  if [[ $STAGE != start && $MODE == bootstrap && -n $CAND_WT && -f $WORK/station.yml ]] \
     && { ((${#SETS[@]})) || [[ -n $CONFIG_ARG ]]; }; then
    mine=$CAND_WT/config/station.yml
  fi
  for f in "$WT_DIR"/*/config/station.yml; do
    [[ -f $f ]] || continue
    if ! rm -f -- "$f"; then
      warn "could not remove $f; a later run at that commit may install it over $ETC_YML"
      continue
    fi
    log "removed $f: $ETC_YML exists, and it is the copy that is edited"
    if [[ $f == "$mine" && ${INSTALL[05-config]:-} != ok ]]; then
      warn "this run's --set/--config input was discarded: 05-config did not install it (${INSTALL[05-config]:-not run}). Pass the same --set/--config again on the next bootstrap run"
    fi
  done
  return 0
}

# prune_worktrees <path>...: remove every worktree but these (PLAN §9f).
prune_worktrees() {
  local d k keep
  for d in "$WT_DIR"/*/; do
    [[ -d $d ]] || continue
    d=${d%/}
    keep=0
    for k in "$@"; do [[ -n $k && $d == "$k" ]] && keep=1; done
    ((keep)) && continue
    log "removing the old worktree $d"
    git -C "$REPO" worktree remove --force "$d" 2>/dev/null || rm -rf -- "$d"
  done
  git -C "$REPO" worktree prune || true
}

# read_last_status: the previous run's result, candidate and finish time, from status.json (the
# 24 h backoff's memory, and the incomplete first build's pin). Unreadable reads as nothing.
read_last_status() {
  local out
  [[ -r $STATUS ]] || return 0
  out=$(python3 - "$STATUS" 2>/dev/null <<'PY'
import calendar, json, sys, time
s = json.load(open(sys.argv[1]))
fin = s.get("finished_at") or ""
try:
    t = calendar.timegm(time.strptime(fin, "%Y-%m-%dT%H:%M:%SZ"))
except ValueError:
    t = 0
# The failed steps (a first build's list, else the one failed step) for --check's reason line;
# newlines inside a name would shift the fields, so they become spaces.
fs = s.get("failed_steps") or ([s["failed_step"]] if s.get("failed_step") else [])
fs = ", ".join(str(x).replace("\n", " ") for x in fs if x)
# One field per line: a tab-separated read would collapse an empty field (tab is IFS
# whitespace) and shift the rest.
print(s.get("result") or "", s.get("candidate_rev") or "", t, fin or "-", fs, sep="\n")
PY
  ) || return 0
  local -a f
  mapfile -t f <<<"$out"
  LAST_RESULT=${f[0]:-} LAST_CAND=${f[1]:-} LAST_FINISHED=${f[2]:-0} LAST_FINISHED_TXT=${f[3]:--}
  LAST_FAILED_STEPS=${f[4]:-}
  [[ $LAST_FINISHED =~ ^[0-9]+$ ]] || LAST_FINISHED=0
}

# --- Steps -----------------------------------------------------------------------

# read_other_rc <worktree>: set OTHER_RC to ADSB_RC_OTHER_ROLE as that tree's lib.sh defines it.
# Returns 1 if it cannot be read; the caller records that as a failure explicitly.
read_other_rc() {
  local v
  # shellcheck disable=SC2016  # $1 and the variable expand in the child, on purpose
  v=$(bash -c 'source "$1/setup/lib.sh" && printf "%s" "$ADSB_RC_OTHER_ROLE"' _ "$1" 2>/dev/null) || v=''
  [[ $v =~ ^[0-9]+$ ]] || return 1
  OTHER_RC=$v
}

# step_list <worktree>: the steps, in order; on a first build 50-updater comes first, so the
# timer that finishes the build exists even if a later step fails. Prints nothing (not one empty
# line) for a tree with no steps.
step_list() {
  local s first=() rest=() all
  for s in "$1"/setup/steps/[0-9][0-9]-*.sh; do
    [[ -f $s ]] || continue
    if ((FIRST_BUILD)) && [[ $(basename "$s" .sh) == "$FIRST_STEP" ]]; then first+=("$s"); else rest+=("$s"); fi
  done
  all=("${first[@]}" "${rest[@]}")
  if ((${#all[@]})); then printf '%s\n' "${all[@]}"; fi
  return 0
}

# run_one <worktree> <step> <install|verify> <log> [rollback]: the step's exit code. stdin is
# /dev/null; a step never reads it, and under the bootstrap stdin was the piped script.
#   - The step starts with the default dispositions of SIGTERM, SIGINT and SIGHUP, never this
#     script's (a rollback ignores them, and an ignored signal is inherited across exec: a
#     `timeout` inside the step could then not stop what it runs).
#   - ADSB_UPDATE_RUN tells a step it runs under update.sh, which holds the recording lock (step
#     50 starts the timer only then).
#   - In a rollback the step runs in a session of its own (setsid), so a second Ctrl-C or a
#     dropped terminal does not reach it; systemd's stop signal has already been sent by then.
run_one() {
  local wt=$1 step=$2 phase=$3 logf=$4 args=(--skip-other-role) rc pre=()
  [[ $phase == verify ]] && args=(--verify --skip-other-role)
  [[ ${5:-} == rollback ]] && pre=(setsid --wait)
  log "----- $(basename "$step" .sh): ${phase} (${args[*]}) -----"
  set +e
  (trap - TERM INT HUP; cd "$wt" && ADSB_UPDATE_RUN=${RUN_ID:-none} exec "${pre[@]}" bash "$step" "${args[@]}") \
    </dev/null 2>&1 | logtee "$logf"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

# run_steps <worktree> <label>: the install pass, then the verify pass (PLAN §9f steps 5 and 6).
# Normal mode stops at the first failure and returns 1 with FAILED_STEP set. First-build mode runs
# on, collecting FAILED_STEPS, and returns 1 if any failed. <label> prefixes the log names
# (rollback- for a rollback), and a rollback's results go to ROLLBACK_FAILED_STEP only.
run_steps() {
  local wt=$1 label=$2 s name rc t0 any=0 phase logf
  local -a steps
  mapfile -t steps < <(step_list "$wt")
  if ((${#steps[@]} == 0)) || ! read_other_rc "$wt"; then
    local why="no steps in $wt"
    ((${#steps[@]} == 0)) || why="could not read ADSB_RC_OTHER_ROLE from $wt/setup/lib.sh"
    warn "$why"
    if [[ $label == rollback- ]]; then
      ROLLBACK_FAILED_STEP=$why
    else
      FAILED_STEP=$why
      ((FIRST_BUILD)) && FAILED_STEPS+=("$why")
    fi
    return 1
  fi
  for phase in install verify; do
    for s in "${steps[@]}"; do
      name=$(basename "$s" .sh)
      if ((TERMINATED)) && [[ $label != rollback- ]]; then
        [[ -n $FAILED_STEP ]] || FAILED_STEP="$name (terminated before it ran)"
        return 1
      fi
      if [[ $phase == verify && $label != rollback- && ${INSTALL[$name]:-} != ok ]]; then
        continue
      fi
      logf=$RUN_LOGS/$label$name.log
      t0=$SECONDS
      rc=0
      run_one "$wt" "$s" "$phase" "$logf" "${label%-}" || rc=$?
      if [[ $label == rollback- ]]; then
        if ((rc != 0 && rc != OTHER_RC)); then
          ROLLBACK_FAILED_STEP="$name ($phase, exit $rc)"
          return 1
        fi
        continue
      fi
      SECS[$name]=$(( ${SECS[$name]:-0} + SECONDS - t0 ))
      local verdict
      if ((rc == 0)); then verdict=ok
      elif ((rc == OTHER_RC)); then verdict="skipped (role)"
      else verdict="failed (exit $rc)"
      fi
      if ((TERMINATED)) && ((rc != 0)); then verdict="terminated (exit $rc)"; fi
      if [[ $phase == install ]]; then INSTALL[$name]=$verdict; else VERIFY[$name]=$verdict; fi
      if [[ $verdict == ok || $verdict == "skipped (role)" ]]; then continue; fi
      any=1
      if ((FIRST_BUILD)); then
        FAILED_STEPS+=("$name")
        [[ -n $FAILED_STEP ]] || FAILED_STEP=$name
        ((TERMINATED)) && return 1
      else
        FAILED_STEP=$name
        return 1
      fi
    done
  done
  return "$any"
}

# --- Foundation (first build, --bootstrap, portable) -----------------------------

# run_foundation: the RTC overlay, then the archive format. A stop signal (TERMINATED) is checked
# before each script, so nothing is started, and above all nothing formatted, after a Ctrl-C or a
# SIGTERM; a script already running gets the signal itself.
run_foundation() {
  local rc=0
  if ((TERMINATED)); then
    log "----- foundation: not run (SIG$TERM_SIG received) -----"
    FOUND_RTC="not run (SIG$TERM_SIG)"
    printf '{"result": "not_run", "reason": "SIG%s received before it started", "device": null, "manual": null}\n' "$TERM_SIG" >"$WORK/format.json"
    return 0
  fi
  log "----- foundation: rtc-overlay -----"
  # ADSB_FOUNDATION=bootstrap: the marker format-archive.sh requires before it formats.
  (trap - TERM INT HUP; ADSB_FOUNDATION=bootstrap exec bash "$CAND_WT/setup/foundation/rtc-overlay.sh") </dev/null 2>&1 \
    | logtee "$RUN_LOGS/foundation-rtc-overlay.log" || rc=${PIPESTATUS[0]}
  if ((rc == 0)); then FOUND_RTC=ok; else FOUND_RTC="failed (exit $rc)"; fi
  # A line the script marks "NOTE: " goes into this run's notes, and into foundation{}, which later
  # runs carry forward; the banner does not show it.
  local n
  while IFS= read -r n; do
    if [[ -n $n ]]; then NOTES+=("$n"); FOUND_NOTES+=("$n"); fi
  done < <(sed -n 's/^NOTE: //p' "$RUN_LOGS/foundation-rtc-overlay.log")
  if ((TERMINATED)); then
    log "----- foundation: format-archive: not run (SIG$TERM_SIG received) -----"
    printf '{"result": "not_run", "reason": "SIG%s received before it started", "device": null, "manual": null}\n' "$TERM_SIG" >"$WORK/format.json"
    return 0
  fi
  if ((NO_FORMAT)); then
    log "----- foundation: format-archive: not run (--no-format) -----"
    printf '{"result": "disabled", "reason": "--no-format", "device": null, "manual": null}\n' >"$WORK/format.json"
    return 0
  fi
  log "----- foundation: format-archive -----"
  rc=0
  (trap - TERM INT HUP; ADSB_FOUNDATION=bootstrap exec bash "$CAND_WT/setup/foundation/format-archive.sh" --report "$WORK/format.json") \
    </dev/null 2>&1 | logtee "$RUN_LOGS/foundation-format-archive.log" || rc=${PIPESTATUS[0]}
  [[ -s $WORK/format.json ]] \
    || printf '{"result": "failed", "reason": "exit %s, no report", "device": null, "manual": null}\n' "$rc" >"$WORK/format.json"
}

# --- Readiness ---------------------------------------------------------------------

# readiness: the preflights' verdicts, plus, on the stationary, the rest of PLAN §9h's list. Each
# line of $WORK/readiness.tsv is <name> TAB <exit code, or empty> TAB <status> TAB <last line of
# output>; status is ok for a pass. The preflights run with default signal dispositions, so their
# timeout works even inside a rollback.
readiness() {
  local p out rc line st
  : >"$WORK/readiness.tsv"
  for p in clock-preflight archive-preflight; do
    if [[ $ROLE == stationary && $p == archive-preflight ]]; then continue; fi
    if [[ ! -x /usr/local/bin/$p ]]; then
      printf '%s\t\tnot installed\t\n' "$p" >>"$WORK/readiness.tsv"
      continue
    fi
    rc=0
    out=$(trap - TERM INT HUP; timeout "$PREFLIGHT_TIMEOUT" "/usr/local/bin/$p" 2>&1 </dev/null) || rc=$?
    line=$(grep -v '^[[:space:]]*$' <<<"$out" | tail -n1 | tr '\t' ' ') || line=''
    case $rc in
      0) st=ok ;; 1) st="could not run" ;; 2) st="not ready" ;; 124) st="timed out" ;; *) st="exit $rc" ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$p" "$rc" "$st" "$line" >>"$WORK/readiness.tsv"
  done
  [[ $ROLE == stationary ]] || return 0
  local ts=''
  if command -v tailscale >/dev/null; then
    ts=$(trap - TERM INT HUP; timeout 30 tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except ValueError:
    print("unreadable"); sys.exit()
st, online = s.get("BackendState"), (s.get("Self") or {}).get("Online")
print("ok" if st == "Running" and online else f"BackendState {st}, online {online}")' 2>/dev/null) || ts=unreadable
  else
    ts="not installed"
  fi
  printf 'tailscale\t\t%s\t\n' "$ts" >>"$WORK/readiness.tsv"
  if ((FETCH_OK)); then printf 'github\t\tok\t\n' >>"$WORK/readiness.tsv"; else printf 'github\t\tfetch failed\t\n' >>"$WORK/readiness.tsv"; fi
  if (trap - TERM INT HUP; timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/30005') 2>/dev/null; then
    printf 'readsb-30005\t\tok\t\n' >>"$WORK/readiness.tsv"
  else
    printf 'readsb-30005\t\tno answer\t\n' >>"$WORK/readiness.tsv"
  fi
}

# gate_holds: PLAN §9h's "before committing an update", stationary only: every check's status is
# ok (clock-preflight's means exit 0; not installed is a hold).
gate_holds() {
  awk -F'\t' '$3 != "ok" { bad = 1 } END { exit bad }' "$WORK/readiness.tsv"
}

# --- Recording the run ---------------------------------------------------------------

flip_applied() {
  local rel
  rel=worktrees/$(basename "$1")
  ln -sfn "$rel" "$APPLIED.new"
  mv -Tf "$APPLIED.new" "$APPLIED"
}

write_applied_rev() {
  install -d -m 0755 "$STATE"
  printf '%s\n' "$1" >"$APPLIED_REV.new"
  chmod 0644 "$APPLIED_REV.new"
  mv -f "$APPLIED_REV.new" "$APPLIED_REV"
}

# write_status <exit code>: status.json, schema 1, root 0644, atomically, last (PLAN §9f). Step
# names, verdicts, SHAs, times and paths, plus some lines copied verbatim: each preflight's last
# line, the steps' NOTE: lines, the reboot reasons and the archive format's report. No field copies
# a config value on purpose, but the verbatim lines are only as clean as the scripts that print
# them (archive-preflight's names archive.label). It points at writer.json and never copies it.
write_status() {
  local code=$1 name tsv=$WORK/steps.tsv applied_now='' notes=$WORK/notes.txt failed_steps=''
  install -d -m 0755 "$STATE"
  : >"$tsv"
  for name in "${!INSTALL[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "${INSTALL[$name]}" "${VERIFY[$name]:-not run}" \
      "${SECS[$name]:-0}" "$RUN_LOGS/$name.log" >>"$tsv"
  done
  : >"$notes"
  if [[ -n $NOTE ]]; then printf '%s\n' "$NOTE" >>"$notes"; fi
  if ((${#NOTES[@]})); then printf '%s\n' "${NOTES[@]}" >>"$notes"; fi
  if ((${#FAILED_STEPS[@]})); then failed_steps=$(printf '%s\n' "${FAILED_STEPS[@]}"); fi
  local leftovers='' fnotes=''
  if ((${#LEFTOVERS[@]})); then leftovers=$(printf '%s\n' "${LEFTOVERS[@]}"); fi
  if ((${#FOUND_NOTES[@]})); then fnotes=$(printf '%s\n' "${FOUND_NOTES[@]}"); fi
  if [[ -L $APPLIED ]]; then applied_now=$(git -C "$APPLIED" rev-parse HEAD 2>/dev/null || true); fi
  [[ -f $WORK/readiness.tsv ]] || : >"$WORK/readiness.tsv"
  S_STATUS=$STATUS S_TSV=$tsv S_READY=$WORK/readiness.tsv S_FMT=$WORK/format.json \
  S_FLAG=$REBOOT_FLAG S_NOTES=$notes S_APPLIED=$applied_now S_FLIPPED=$FLIPPED S_NOW=$(utc_now) \
  S_ROLE=$ROLE S_CHANNEL=$CHANNEL S_MODE=$MODE S_STARTED=$STARTED_AT S_RESULT=$RESULT S_EXIT=$code \
  S_CAND=$CAND S_FAILED=$FAILED_STEP S_FAILED_STEPS=$failed_steps S_RB=$ROLLBACK_RESULT \
  S_RB_STEP=$ROLLBACK_FAILED_STEP S_LEFT=$leftovers S_GATE=$GATE S_RTC=$FOUND_RTC S_FNOTES=$fnotes \
  S_LOG=${RUN_LOGS:+$RUN_LOGS/run.log} S_WRITER=$WRITER_JSON S_TRIGGER=$TRIGGER S_OPENED_BY=$OPENED_BY \
  python3 - <<'PY' || { warn "could not write $STATUS"; return 0; }
import json, os, socket
E = os.environ
def nz(v): return v or None
steps = {}
for line in open(E["S_TSV"]):
    n, ins, ver, secs, logf = line.rstrip("\n").split("\t")
    steps[n] = {"install": ins, "verify": ver, "seconds": int(secs), "log": logf}
readiness = {}
for line in open(E["S_READY"]):
    n, rc, st, last = (line.rstrip("\n").split("\t") + ["", "", ""])[:4]
    readiness[n] = {"exit": int(rc) if rc.lstrip("-").isdigit() else None, "status": st,
                    "line": nz(last)}
fa = None
if os.path.exists(E["S_FMT"]):
    try:
        fa = json.load(open(E["S_FMT"]))
    except ValueError:
        fa = {"result": "unreadable"}
reasons = []
if os.path.exists(E["S_FLAG"]):
    reasons = [l.strip() for l in open(E["S_FLAG"]) if l.strip()]
notes = [l.strip() for l in open(E["S_NOTES"]) if l.strip()]
applied_rev = nz(E["S_APPLIED"])
try:
    prev = json.load(open(E["S_STATUS"]))
    if not isinstance(prev, dict):
        prev = {}
except (OSError, ValueError):
    prev = {}
applied_at = None
if E["S_FLIPPED"] == "1":
    applied_at = E["S_NOW"]
elif prev.get("applied_rev") == applied_rev:
    applied_at = prev.get("applied_at")
# The foundation runs once, on the bootstrap's first build; its record (and its notes, such as the
# RTC charge-path line) is carried into every later status.json, unchanged, with when it ran.
if E["S_RTC"] or fa:
    foundation = {"rtc_overlay": nz(E["S_RTC"]), "format_archive": fa,
                  "notes": [l for l in E["S_FNOTES"].split("\n") if l], "ran_at": E["S_NOW"]}
else:
    foundation = prev.get("foundation") if isinstance(prev.get("foundation"), dict) else None
doc = {
    "schema": 1,
    "host": socket.gethostname(),
    "role": nz(E["S_ROLE"]),
    "channel": nz(E["S_CHANNEL"]),
    "mode": E["S_MODE"],
    # window, with adsb-home-update or hand; null for a run outside any window (the header).
    "trigger": nz(E["S_TRIGGER"]),
    "opened_by": nz(E["S_OPENED_BY"]),
    "started_at": nz(E["S_STARTED"]),
    "finished_at": E["S_NOW"],
    "result": E["S_RESULT"],
    "exit": int(E["S_EXIT"]),
    "applied_rev": applied_rev,
    "applied_at": applied_at,
    "candidate_rev": nz(E["S_CAND"]),
    "failed_step": nz(E["S_FAILED"]),
    "failed_steps": [s for s in E["S_FAILED_STEPS"].split("\n") if s],
    "steps": dict(sorted(steps.items())),
    # complete is false until rollback can remove what a candidate created (the next change).
    # Corrected 2026-10-10: that change, the install manifest, was not the next one and is not
    # built. Its ruled place is unchanged: before any stationary deploy (PLAN §9f).
    "rollback": ({"result": E["S_RB"], "failed_step": nz(E["S_RB_STEP"]), "complete": False,
                  "leftovers_possible": [s for s in E["S_LEFT"].split("\n") if s]}
                 if E["S_RB"] else None),
    "readiness": readiness,
    "gate": nz(E["S_GATE"]),
    "foundation": foundation,
    "notes": notes,
    "reboot_required": bool(reasons),
    "reboot_reasons": reasons,
    "log": nz(E["S_LOG"]),
    "writer_json": E["S_WRITER"],
}
tmp = E["S_STATUS"] + ".new"
with open(tmp, "w") as fh:
    json.dump(doc, fh, indent=1)
    fh.write("\n")
    fh.flush()
    os.fsync(fh.fileno())
os.chmod(tmp, 0o644)
os.replace(tmp, E["S_STATUS"])
PY
  STATUS_WRITTEN=1
}

prune_logs() {
  local -a runs
  mapfile -t runs < <(find "$LOG_ROOT" -mindepth 1 -maxdepth 1 -type d -name '2*' -printf '%f\n' 2>/dev/null | sort)
  local n=$(( ${#runs[@]} - KEEP_RUNS )) i
  for ((i = 0; i < n; i++)); do rm -rf -- "${LOG_ROOT:?}/${runs[i]}"; done
}

# --- Rollback ------------------------------------------------------------------------

# rollback: the applied tree back in place and its steps re-run. It checks the applied worktree
# first and flips back only if it is there; it rewrites applied-rev with the flip. It ignores the
# stop signals while it works; its children get the defaults back (run_one, readiness).
rollback() {
  trap '' TERM INT HUP
  STAGE=rollback
  RESULT=rolled_back
  # What this rollback cannot undo: anything a step new in the candidate created (PLAN §9f).
  local s
  LEFTOVERS=()
  for s in "$CAND_WT"/setup/steps/[0-9][0-9]-*.sh; do
    [[ -f $s ]] || continue
    [[ -n $OLD_WT && -f $OLD_WT/setup/steps/${s##*/} ]] || LEFTOVERS+=("$(basename "$s" .sh)")
  done
  if [[ -z $OLD_WT || ! -d $OLD_WT ]] || ! git -C "$OLD_WT" rev-parse --verify --quiet HEAD >/dev/null; then
    ROLLBACK_RESULT=failed ROLLBACK_FAILED_STEP="the applied worktree ${OLD_WT:-?} is missing, so nothing was flipped back"
    warn "cannot roll back: $ROLLBACK_FAILED_STEP"
    return 0
  fi
  if ((FLIPPED)); then
    flip_applied "$OLD_WT"
    FLIPPED=0
    write_applied_rev "$OLD_SHA"
  fi
  log "ROLLING BACK to $(sha12 "$OLD_SHA"): re-running the applied steps (failed: ${FAILED_STEP:-?})"
  ((${#LEFTOVERS[@]} == 0)) || warn "the candidate's steps ${LEFTOVERS[*]} are not in the applied tree: what they created stays installed (rollback.leftovers_possible in status.json)"
  if run_steps "$OLD_WT" rollback-; then
    ROLLBACK_RESULT=ok
    log "rollback complete: the applied steps ran and verified (what the candidate created is not removed)"
  else
    ROLLBACK_RESULT=failed
    warn "the rollback itself failed at $ROLLBACK_FAILED_STEP; the rig needs a look"
  fi
}

# --- Exit ------------------------------------------------------------------------

finish() {
  local code=$1
  STAGE=finished
  if [[ -n $RESULT ]] && ((STATUS_WRITTEN == 0)); then
    write_status "$code"
  fi
  release_lock
  writer_start_rule
  [[ -n $RUN_LOGS ]] && prune_logs
  log "result: ${RESULT:-none}; exit $code"
  exit "$code"
}

# shellcheck disable=SC2317,SC2329  # invoked by trap (0.9 says SC2317, 0.11 SC2329)
# on_exit: an unexpected failure in this script itself (set -e). A normal run that had begun
# changing the rig rolls back; any run that took the lock records itself and applies the
# writer-start rule. A first build records itself as incomplete, not failed, so the timer's pin
# (examine_applied) still finds it and retries it; the exit code stays the failing command's, so
# setup/bootstrap.sh does not take it for an ordinary incomplete build (exit 3) and reboot.
on_exit() {
  local rc=$?
  trap - EXIT
  # A subshell that inherited this trap must not release the lock, roll back or write status.
  [[ $BASHPID == "$MAIN_PID" ]] || return 0
  [[ $STAGE == finished ]] && { [[ -n $WORK ]] && rm -rf -- "$WORK"; return 0; }
  if ((LOCKED)); then
    ((FAILED_ON_PURPOSE)) || warn "update.sh stopped unexpectedly (exit $rc) at stage $STAGE"
    if [[ $STAGE == steps || $STAGE == flip ]] && ((FIRST_BUILD == 0)); then
      [[ -n $FAILED_STEP ]] || FAILED_STEP="update.sh itself (exit $rc at stage $STAGE)"
      # main's drop_seeds after the steps may not have run: this run's seed must not reach the
      # rollback's 05-config.
      drop_seeds || true
      rollback || true
    fi
    if [[ -n $RESULT || $STAGE != start ]]; then
      if [[ -z $RESULT || $RESULT == running ]]; then
        if ((FIRST_BUILD)) && [[ -n $CAND ]]; then
          RESULT=incomplete
          [[ -n $FAILED_STEP ]] || FAILED_STEP="update.sh itself (exit $rc at stage $STAGE)"
          FAILED_STEPS+=("$FAILED_STEP")
        else
          RESULT=failed
        fi
      fi
      write_status "$rc" || true
    fi
    release_lock
    writer_start_rule || true
  fi
  [[ -n $WORK ]] && rm -rf -- "$WORK"
  exit "$rc"
}

# --- Applied state ------------------------------------------------------------------

# examine_applied: what `applied` says, before anything else (PLAN §9f's evening update). Sets OLD_WT and
# OLD_SHA for a built rig; FIRST_BUILD (and PIN, for the timer) for a first build; or ends the
# run.
examine_applied() {
  if [[ -e $APPLIED || -L $APPLIED ]]; then
    OLD_WT=$(readlink -f "$APPLIED") || OLD_WT=''
    OLD_SHA=''
    if [[ -n $OLD_WT && -d $OLD_WT && $(git -C "$OLD_WT" rev-parse --show-toplevel 2>/dev/null) == "$OLD_WT" ]]; then
      OLD_SHA=$(git -C "$OLD_WT" rev-parse --verify --quiet HEAD) || OLD_SHA=''
    fi
    [[ -n $OLD_SHA ]] || recover_applied
    return 0
  fi
  if [[ $MODE == bootstrap ]]; then
    FIRST_BUILD=1
    return 0
  fi
  if [[ $LAST_RESULT == incomplete && -n $LAST_CAND ]]; then
    [[ $MODE == timer ]] \
      || fail "the first build is incomplete (status.json) and stays pinned at the bootstrap's commit $(sha12 "$LAST_CAND") until it completes (the timer with the lock free, or a pull window on a recording portable); --rev waits until then. If the pinned commit itself cannot pass, run the one-command bootstrap again (BUILD.md §8)"
    git -C "$REPO" cat-file -e "$LAST_CAND^{commit}" 2>/dev/null \
      || fail "the incomplete first build's commit $(sha12 "$LAST_CAND") is not in the clone; run the bootstrap again (it builds stable's tip without the soak, PLAN §9g)"
    FIRST_BUILD=1 PIN=$LAST_CAND
    return 0
  fi
  fail "no build on this rig (no $APPLIED, and status.json records no incomplete first build); run the bootstrap (setup/bootstrap.sh)"
}

# recover_applied: `applied` dangles or names no readable worktree. Never a first build: rebuild
# the worktree from applied-rev if the clone has that commit (it was written with the flip, so it
# is the same truth), else record the failure and run no step.
recover_applied() {
  local rev=''
  rev=$(head -n1 "$APPLIED_REV" 2>/dev/null) || rev=''
  if [[ $rev =~ ^[0-9a-f]{40}$ ]] && git -C "$REPO" cat-file -e "$rev^{commit}" 2>/dev/null; then
    warn "$APPLIED is dangling or unreadable; applied-rev names $(sha12 "$rev"), which the clone has: recreating its worktree and carrying on as a normal run"
    ensure_worktree "$rev"
    flip_applied "$WT_PATH"
    OLD_WT=$WT_PATH OLD_SHA=$rev
    NOTES+=("applied was dangling or unreadable; its worktree was recreated from applied-rev ($(sha12 "$rev"))")
    return 0
  fi
  RESULT=failed FAILED_STEP="applied is dangling and applied-rev is unusable"
  warn "$FAILED_STEP: no step runs. Look at $APPLIED and $APPLIED_REV. To rebuild from nothing, remove $APPLIED and run the bootstrap (a first build: no gate, no rollback, and stable's tip without the soak, PLAN §9g)"
  write_status "$RC_FAILED"
  finish "$RC_FAILED"
}

# in_backoff: true when CAND is the candidate status.json records as rolled_back or failed, less
# than 24 h ago (PLAN §9f's evening update). Sets BACKOFF_MSG. The timer's run and --check both
# ask it, so --check's "not pending" is the run's "skipped".
BACKOFF_MSG=''
in_backoff() {
  [[ $CAND == "$LAST_CAND" ]] && [[ $LAST_RESULT == rolled_back || $LAST_RESULT == failed ]] || return 1
  local age=$(( $(date +%s) - LAST_FINISHED ))
  ((LAST_FINISHED > 0 && age >= 0 && age < BACKOFF_SECS)) || return 1
  BACKOFF_MSG="$(sha12 "$CAND") was $LAST_RESULT at $LAST_FINISHED_TXT; the timer tries it again $(( (BACKOFF_SECS - age + 3599) / 3600 )) h from now"
}

# --- --check -------------------------------------------------------------------------

# shellcheck disable=SC2317,SC2329  # invoked by trap (0.9 says SC2317, 0.11 SC2329)
# check_signal <128+N>: --check's signal handler: kill its fetch, if one runs, and exit.
check_signal() {
  [[ -n $CHECK_CHILD ]] && kill "$CHECK_CHILD" 2>/dev/null
  exit "$1"
}

# check_pending: --check (the header). The timer run's path up to the point where it would start
# changing the rig, reading only: no lock, no apt heal, no worktree, no status.json, no log
# directory. Prints its one verdict line on stdout and exits. Its fail() is exit 13 (above).
check_pending() {
  local f rev=''
  CHECKING=1
  f=$(station_file) || fail "no station.yml (neither $ETC_YML nor a worktree's); build the rig with setup/bootstrap.sh"
  ROLE=$(yml_get "$f" station.role) || fail "$f has no station.role"
  [[ $ROLE == portable || $ROLE == stationary ]] || fail "$f: station.role is '$ROLE'"
  CHANNEL=$(channel_of "$ROLE")
  read_last_status
  # examine_applied's reading, without its repair: a dangling `applied` is read through
  # applied-rev, from which a run would recreate the worktree (recover_applied).
  if [[ -e $APPLIED || -L $APPLIED ]]; then
    OLD_WT=$(readlink -f "$APPLIED") || OLD_WT=''
    if [[ -n $OLD_WT && -d $OLD_WT && $(git -C "$OLD_WT" rev-parse --show-toplevel 2>/dev/null) == "$OLD_WT" ]]; then
      OLD_SHA=$(git -C "$OLD_WT" rev-parse --verify --quiet HEAD) || OLD_SHA=''
    fi
    if [[ -z $OLD_SHA ]]; then
      rev=$(head -n1 "$APPLIED_REV" 2>/dev/null) || rev=''
      if ! [[ $rev =~ ^[0-9a-f]{40}$ ]] || ! git -C "$REPO" cat-file -e "$rev^{commit}" 2>/dev/null; then
        fail "applied is dangling and applied-rev is unusable: a run would record failed and run no step, so a window would change nothing. Look at $APPLIED and $APPLIED_REV"
      fi
      OLD_SHA=$rev
      log "$APPLIED is dangling or unreadable; applied-rev names $(sha12 "$rev"), whose worktree a run would recreate"
    fi
  elif [[ $LAST_RESULT == incomplete && -n $LAST_CAND ]]; then
    # The pin (examine_applied): every incomplete first build is pending (PLAN §9e's (a)). No fetch:
    # the pinned run builds that commit whatever the channel says, offline too.
    git -C "$REPO" cat-file -e "$LAST_CAND^{commit}" 2>/dev/null \
      || fail "the incomplete first build's commit $(sha12 "$LAST_CAND") is not in the clone; run the bootstrap again (BUILD.md §8)"
    FIRST_BUILD=1 PIN=$LAST_CAND
    resolve_candidate
    # The reason line, worded as ruled (PLAN §9e's 2026-10-05 (a)).
    printf 'pending: the first build is incomplete at %s; the last run failed %s at %s; the window retries this same commit, and a fix on main does not reach it\n' \
      "$(sha12 "$CAND")" "${LAST_FAILED_STEPS:-(no step recorded)}" "$LAST_FINISHED_TXT"
    exit 0
  else
    fail "no build on this rig (no $APPLIED, and status.json records no incomplete first build); run the bootstrap (setup/bootstrap.sh)"
  fi
  # fetch(), in the background, so that a signal ends the wait at once (check_signal).
  [[ -d $REPO ]] || fail "no clone at $REPO; build the rig with setup/bootstrap.sh first"
  GIT_TERMINAL_PROMPT=0 timeout "$FETCH_TIMEOUT" git -C "$REPO" fetch --prune --quiet origin &
  CHECK_CHILD=$!
  if wait "$CHECK_CHILD"; then FETCH_OK=1; else FETCH_OK=0; fi
  CHECK_CHILD=''
  if ((FETCH_OK == 0)); then
    printf 'not pending: the fetch failed (no network?), so whether %s moved is unknown\n' "$CHANNEL"
    exit "$RC_CHECK_NO_FETCH"
  fi
  if ! resolve_candidate; then
    printf 'not pending: %s\n' "$NOTE"
    exit "$RC_CHECK_NONE"
  fi
  if [[ $CAND == "$OLD_SHA" ]]; then
    printf 'not pending: %s is still %s, which is applied\n' "$CHANNEL" "$(sha12 "$CAND")"
    exit "$RC_CHECK_NONE"
  fi
  if in_backoff; then
    printf 'not pending: %s\n' "$BACKOFF_MSG"
    exit "$RC_CHECK_BACKOFF"
  fi
  printf "pending: %s's tip %s is the candidate; applied is %s\n" "$CHANNEL" "$(sha12 "$CAND")" "$(sha12 "$OLD_SHA")"
  exit 0
}

# --- Main --------------------------------------------------------------------------

main() {
  parse_args "$@"
  ((EUID == 0)) || { printf 'xx  run as root\n' >&2; exit "$RC_FAILED"; }
  # Under `curl | sudo bash`, stdin was the script. Nothing below reads it.
  exec </dev/null
  for t in git python3 flock lslocks systemctl timeout setsid; do
    command -v "$t" >/dev/null || fail "$t is not installed"
  done
  if [[ $MODE == check ]]; then
    # Before the scratch directory, the EXIT trap and the lock: --check writes nothing, so a
    # signal ends it at once (the header).
    trap 'check_signal 143' TERM
    trap 'check_signal 130' INT
    trap 'check_signal 129' HUP
    check_pending
  fi
  WORK=$(mktemp -d)
  trap on_exit EXIT
  trap 'on_signal TERM' TERM
  trap 'on_signal INT' INT
  trap 'on_signal HUP' HUP
  STARTED_AT=$(utc_now)

  if [[ $MODE == bootstrap ]]; then
    SELF_WT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    SELF_SHA=$(git -C "$SELF_WT" rev-parse --verify --quiet HEAD) \
      || fail "$SELF_WT is not a git worktree; run this through setup/bootstrap.sh"
    if ! python3 -c 'import yaml' 2>/dev/null; then
      log "python3-yaml is missing; installing it"
      if ! { DEBIAN_FRONTEND=noninteractive apt-get update -q \
             && DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-yaml; }; then
        fail "could not install python3-yaml"
      fi
    fi
    prepare_config
    case $PREP_HOW in
      keep) log "keeping the installed $ETC_YML (station.role: $ROLE_ARG)" ;;
      copied|rendered) log "station.yml for the $ROLE_ARG rig: $PREP_HOW from ${CONFIG_ARG:-the template}; validated" ;;
      *) fail "station.yml: unexpected outcome '$PREP_HOW'" ;;
    esac
    [[ -n $CONFIG_ARG ]] && log "ℹ️ If $CONFIG_ARG holds credentials, delete it once the build is done; the installed copy is $ETC_YML (root, 0600)"
  fi

  take_lock
  window_context

  if [[ $MODE == bootstrap ]]; then
    ROLE=$ROLE_ARG
  else
    local f
    f=$(station_file) || fail "no station.yml (neither $ETC_YML nor a worktree's); build the rig with setup/bootstrap.sh"
    ROLE=$(yml_get "$f" station.role) || fail "$f has no station.role"
    [[ $ROLE == portable || $ROLE == stationary ]] || fail "$f: station.role is '$ROLE'"
  fi
  CHANNEL=$(channel_of "$ROLE")

  read_last_status
  examine_applied

  # PLAN §9f step 1.
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a \
    || warn "dpkg --configure -a failed (is another apt running?); a step that needs apt may fail"

  # Step 2. A signal during the fetch ends the run here, before any offline branch reads FETCH_OK.
  fetch
  ((TERMINATED)) && { STAGE=finished; release_lock; exit "$(sig_exit)"; }
  if ((FETCH_OK == 0)); then
    if ((FIRST_BUILD)) || [[ $MODE == bootstrap ]]; then
      warn "the fetch failed; this run carries on with what the clone already has"
    elif [[ $MODE == timer && $ROLE == portable ]]; then
      log "the fetch failed: no network, which is normal in the field (PLAN §9f). Nothing was written to the rig's applied state"
      STAGE=finished; release_lock; writer_start_rule; exit 0
    elif [[ $MODE == timer ]]; then
      RESULT=not_ready GATE=held NOTE="the fetch from GitHub failed"
      readiness
      finish "$RC_NOT_READY"
    else
      fail "the fetch failed; --$MODE needs the network"
    fi
  fi

  # Step 3.
  if ! resolve_candidate; then
    log "unchanged: $NOTE. Nothing was written to the rig's applied state"
    STAGE=finished; release_lock; writer_start_rule; exit 0
  fi
  if [[ $MODE == timer && $FIRST_BUILD -eq 0 && $CAND == "$OLD_SHA" ]]; then
    log "unchanged: $CHANNEL is still $(sha12 "$CAND"), which is applied. Nothing was written to the rig's applied state"
    STAGE=finished; release_lock; writer_start_rule; exit 0
  fi
  # The 24 h backoff (PLAN §9f's evening update): a candidate that failed or rolled back is not tried again by
  # the timer until a day after that run; then once a day, until the channel moves.
  if [[ $MODE == timer ]] && ((RETRY == 0 && FIRST_BUILD == 0)) && in_backoff; then
    log "skipped: $BACKOFF_MSG, or run: sudo adsb-update --retry. Nothing was written to the rig's applied state"
    STAGE=finished; release_lock; writer_start_rule; exit 0
  fi

  RESULT=running
  start_run_log
  local applied_txt="none (a first build)"
  [[ -n $OLD_SHA ]] && applied_txt=$(sha12 "$OLD_SHA")
  log "role $ROLE, channel $CHANNEL; applied: $applied_txt; candidate: $(sha12 "$CAND")"
  [[ -z $NOTE ]] || log "$NOTE"

  # The stationary gate (PLAN §9h), before anything changes. Never in first-build mode: there is
  # no running rig to protect yet, and a gate there would mean no stationary could ever be built.
  if [[ $ROLE == stationary && $FIRST_BUILD -eq 0 ]]; then
    readiness
    if gate_holds; then GATE=passed; else
      GATE=held RESULT=not_ready NOTE="PLAN §9h's checks did not all hold; nothing was changed"
      warn "$NOTE"; cat "$WORK/readiness.tsv"
      finish "$RC_NOT_READY"
    fi
  fi

  # Step 4.
  prune_worktrees "$OLD_WT" "$WT_DIR/$(sha12 "$CAND")" "$SELF_WT"
  ensure_worktree "$CAND"
  CAND_WT=$WT_PATH
  # Before any step runs, and before this run's own seed: a seed left by an earlier bootstrap
  # (in the applied tree a rollback would re-run, or in this reused worktree) must not reach /etc.
  # A bootstrap writes a seed only when it was given --config or --set, or there is no $ETC_YML
  # yet; otherwise it writes none (prepare_config: keep).
  drop_seeds
  if [[ $MODE == bootstrap && -f $WORK/station.yml ]]; then
    install -m 0600 -o root -g root "$WORK/station.yml" "$CAND_WT/config/station.yml"
    log "wrote $CAND_WT/config/station.yml; step 05-config installs it to $ETC_YML"
  fi
  ((TERMINATED)) && { RESULT=''; STAGE=finished; release_lock; exit "$(sig_exit)"; }

  # Steps 5 and 6.
  STAGE=steps
  local ok=1
  if ((FIRST_BUILD)); then
    local -a list
    mapfile -t list < <(step_list "$CAND_WT")
    if [[ $MODE == bootstrap && $ROLE == portable ]] && ((TERMINATED == 0)); then
      # 50-updater first, then the foundation tier, then the rest (run_steps runs 50 again; it
      # is idempotent and takes seconds). run_foundation checks TERMINATED again before each
      # script: 50-updater may be the step a Ctrl-C lands in.
      if ((${#list[@]})) && [[ $(basename "${list[0]}" .sh) == "$FIRST_STEP" ]]; then
        local rc50=0
        run_one "$CAND_WT" "${list[0]}" install "$RUN_LOGS/$FIRST_STEP.log" || rc50=$?
        ((rc50 == 0)) || warn "$FIRST_STEP failed (exit $rc50); the timer that would finish this build may be missing"
      fi
      run_foundation
    fi
    run_steps "$CAND_WT" "" || ok=0
  else
    run_steps "$CAND_WT" "" || ok=0
  fi
  ((TERMINATED)) && ok=0
  # This run's seed, installed, if 05-config ran, goes too (and before a rollback re-runs steps).
  drop_seeds

  # Step 7, or the failure path. The old worktree is pruned only after status.json is written,
  # so a failure before then still has a tree to roll back to.
  if ((ok)); then
    STAGE=flip
    flip_applied "$CAND_WT"
    FLIPPED=1
    write_applied_rev "$CAND"
    RESULT=applied
    readiness
    write_status 0
    STAGE=finished
    prune_worktrees "$CAND_WT"
    finish 0
  fi
  if ((FIRST_BUILD)); then
    RESULT=incomplete
    [[ ${#FAILED_STEPS[@]} -gt 0 ]] || FAILED_STEPS=("${FAILED_STEP:-unknown}")
    # After a signal the exit is 128+N, not 3, so whatever ran this (setup/bootstrap.sh) does not
    # carry on as after an ordinary incomplete build; status.json still says incomplete.
    local code=$RC_INCOMPLETE
    ((TERMINATED)) && code=$(sig_exit)
    warn "the build is INCOMPLETE: ${FAILED_STEPS[*]}. Each step's log is in $RUN_LOGS. Every update timer run (after each boot, and daily) runs the build again at this same commit while the recording lock is free (a rig with no writer running), so a step waiting for hardware completes once it is plugged in. On a recording portable the writer holds the lock from every boot, so the build completes in the next pull window instead (tools/pull-archive from the workstation, or sudo systemctl start adsb-pull-window.service, then stop, on the rig). If a failed step cannot pass at this commit, run the one-command bootstrap again (BUILD.md §8), which pins to stable's tip. The archive drive is the exception: only the bootstrap formats it, so a drive plugged in later is formatted by hand (step 30 prints the command), or by running the bootstrap again"
    readiness
    write_status "$code"
    STAGE=finished
    [[ -n $SELF_WT && $SELF_WT != "$CAND_WT" ]] && prune_worktrees "$CAND_WT"
    finish "$code"
  fi
  rollback
  readiness
  write_status "$RC_ROLLED_BACK"
  finish "$RC_ROLLED_BACK"
}

main "$@"
