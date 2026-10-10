#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# setup/bootstrap.sh: build a rig with one command, on a fresh Raspberry Pi OS. PLAN §9e and §9f.
#
#   curl -fsSL https://raw.githubusercontent.com/Wezdenko-L-L-C/adsb-receiver/stable/setup/bootstrap.sh \
#     | sudo bash -s -- --role portable
#
# or, to read it before it runs (the commit you read is the commit that is built):
#
#   sudo apt install -y git
#   git clone --branch stable https://github.com/Wezdenko-L-L-C/adsb-receiver.git
#   (read it; `git -C adsb-receiver checkout <commit>` if you mean another one)
#   sudo bash adsb-receiver/setup/bootstrap.sh --role portable
#
# Arguments (all but --no-reboot are passed to update.sh --bootstrap):
#   --role portable|stationary   required: which template station.yml is written from. It does not
#                                choose a channel: both roles follow stable (PLAN §9g, 2026-10-05)
#   --set key.path=value         repeatable: edit one key of it (a stationary needs position.*)
#   --config FILE                use this station.yml instead of the template
#   --no-format                  never format the archive drive, even if exactly one qualifies
#   --no-reboot                  do not reboot at the end, even if the build needs it
#
# Thin on purpose: install git if missing, clone this repo into /opt/adsb-receiver (a bare clone
# plus a detached worktree, the layout update.sh keeps), and run that worktree's
# setup/update.sh --bootstrap, which does the build. Which commit:
#   - run from a checkout (this file sits in a git checkout): that checkout's HEAD, fetched into
#     the bare clone, with a warning if it is not on origin/stable (CI may still be running);
#   - otherwise (curl | bash): stable's tip, for both roles (PLAN §9g's 2026-10-05 update). A
#     first build, on either role, takes it without the soak: the bench is attended; the soak
#     protects the unattended rig. The updater, the config code and the foundation scripts come
#     from that same commit, so nothing newer than what was chosen runs as root. This script
#     itself is fetched from stable too (the curl line above), so it and the built commit are
#     close, not identical: raw.githubusercontent.com may serve stable a few minutes stale, and
#     stable may advance between the curl and this script's fetch. Before stable exists the curl
#     returns 404 and bash runs nothing (run from a checkout, the same case fails at the
#     rev-parse of origin/stable). A fix to this script is fetchable only once its CI is green.
#     ⚠️ The cost: stable moves only when CI is green, about three minutes after a push, so a
#     curl | bash run inside that window builds the previous green commit. The SHA it builds is
#     printed ("==> stable is <sha12>"); run from a checkout to build a chosen HEAD.
# ⚠️ Run again on a rig that is already built, it builds the same way, as an ordinary update
#    (with rollback, and on a stationary with the gate): stable's tip WITHOUT the soak, however
#    young it is. The timer is what waits out the soak (PLAN §9g).
#
# Done here before update.sh runs, on a recording rig (PLAN §9e's (b), ruled 2026-10-05, Chris):
# on a first build (no /opt/adsb-receiver/applied) whose recording lock is held by
# adsb-writer.service, this ends the recording session the one ruled way, the pull window, so the
# bootstrap stays one command. It starts adsb-pull-window.service, which stops the writer
# (Conflicts=) and starts adsb-update.service (Wants=), the pinned run the timer would make: it
# builds the EARLIER pin, the commit of the first build that is incomplete, not this bootstrap's
# commit, and it may fail again. It waits for that update to finish (polled every 5 s, a line
# every 30 s, bounded at 45 min: the window's TimeoutStopSec=, PLAN §9m, which is also what bounds
# tools/pull-archive's close, since that waits on the window's stop with no timeout of its own;
# above the update's own 40 min TimeoutStartSec=); runs update.sh --bootstrap with the lock
# free; and closes the window once update.sh returns, before any reboot notice (the stop blocks
# through the window's ExecStop= wait: half seen under the opener, ⚠️ not while the update is
# activating; and its ExecStopPost= starts the writer: seen 2026-10-10 under the opener, not under
# the bootstrap; PLAN §9e's (b) list). An EXIT trap closes it on every other path; after a signal or a timeout with the
# window's update still running, that close is --no-block, and the window ends itself once its
# update finishes (that a --no-block stop is carried through ExecStop= by systemd: ⚠️ belief, not
# seen on a Pi). If the window cannot be started, the writer is started again here (systemctl
# start --no-block), since Conflicts= may already have stopped it and a window that never ran
# reaches no ExecStopPost= (⚠️ belief, not seen on a Pi), and the bootstrap exits 1. The window's
# RuntimeMaxSec=2h cap covers the wait plus the whole build: if it ends the window first, its
# ExecStopPost= starts the writer, which waits on the lock until update.sh releases it, and the
# close here then only says so (a window ended by the cap reads failed, or perhaps inactive: ⚠️
# belief, not seen on a Pi; the code accepts either). update.sh itself still never stops the
# writer.
#   Only where adsb-pull-window.service is loaded: a rig with a writer but no window unit (one
# installed by hand before step 60 ran, the 2026-10-04 shape) gets update.sh's refusal, which says
# to stop the writer by hand; so does a rig already built, and so does a lock held by anything
# else (a hand run of adsb-update, a login's session scope), which the refusal names. Each tells
# update.sh, through ADSB_BOOTSTRAP_WINDOW, why the bootstrap did not end the session, so the
# refusal never says it would have.
#   If the window's pinned run completes the build, every step verified, steps 20 (/dev/rtc0, so
# the RTC overlay is in place) and 30 (the labeled, mounted drive, so it is formatted) included:
# the foundation's work is done. update.sh --bootstrap then applies this bootstrap's commit as an
# ordinary update, with rollback and without the foundation, and this run does not reboot.
#   ⚠️ A gap remains between the wait's end and update.sh taking the lock: a timer run (OnBootSec=
# or the daily one) that starts in it takes the lock first, and update.sh then refuses, naming that
# run as the holder. Unlikely; the bootstrap is then run again.
#
# The other thing done here: a reboot, once, after a printed 5 s notice, and only when all of these
# hold (PLAN §9e's evening update):
#   - this run started with no /opt/adsb-receiver/applied (a first build), and the pull window's
#     update, where one ran, did not create it;
#   - this run asked for a reboot: a step or foundation script called lib.sh's need_reboot (the
#     RTC overlay, a remounted archive drive, 00-drivers' DVB-module blacklist while
#     dvb_usb_rtl28xxu is loaded). Each reason is also written to a file of this
#     run's own (ADSB_REBOOT_MARK), so a reason counts even when the flag (lib.sh's
#     ADSB_REBOOT_FLAG) already held it from an earlier run in the same boot. A reason the pull
#     window's pinned run wrote counts as this bootstrap's too, since this run started that run:
#     the flag is read for comparison before the window opens;
#   - adsb-update.timer is enabled, so the build can finish after the boot;
#   - the recording lock is free, or held only by the writer that this build started at its end
#     (seconds of recording, which the shutdown's SIGTERM closes cleanly): started by update.sh's
#     writer-start rule, or by the pull window's close above. It is told by its process having
#     started during this run, whose clock starts before the window's wait, so a writer started
#     anywhere in that wait reads as this build's too. The window's writer start is --no-block,
#     so it may still be on its way when this is read; then the lock reads free. Any other
#     holder, such as an update run the timer started meanwhile, blocks the reboot;
#   - update.sh exited 0 (applied) or 3 (incomplete). After a Ctrl-C or SIGTERM it exits 128+N,
#     even on a first build, so an interrupted build never turns into a reboot countdown.
# Otherwise it prints REBOOT REQUIRED with the reasons and exits. It never reboots once `applied`
# exists. update.sh itself never reboots. After the boot, adsb-update.timer runs an incomplete
# build again at the same commit while the recording lock is free (no writer running): on a
# portable about 3 minutes after the boot; on a stationary, which has no boot timer, at its
# nightly run (or by hand: sudo systemctl start adsb-update.service). On a recording portable the
# writer holds the lock from every boot, so the build completes in the next pull window instead
# (tools/pull-archive from the workstation, or sudo systemctl start adsb-pull-window.service, then
# stop, on the rig). If a failed step cannot pass at that commit, run this bootstrap again (BUILD.md
# §8), which pins to stable's tip; on a recording portable it ends the session itself, above.
#
# Everything is inside functions, run by the last line (main), so a download cut short runs
# nothing, or stops at the usage check.
#
# What has run on hardware: the portable, mobile-adsb, on 2026-10-04 (incomplete: steps failed
# on a hung stick) and on 2026-10-05 (applied, and the reboot taken). ⚠️ Unverified: all of it on
# the stationary. ⚠️ Not run on hardware: the pull-window path above (written 2026-10-05, after
# both runs). It runs only on a second bootstrap of an incomplete, recording first build, which has
# not yet occurred, and no SD is staged to prove it (PLAN §9e, the 2026-10-10 ruling under (b)'s
# beliefs list). The window unit it starts and stops is shared with the opener, and has run end to
# end under it (PLAN §9f's record on hardware, 2026-10-10 at 08:45). So its beliefs about systemd
# are each marked, here and in PLAN §9e's (b) list, as seen under the opener and not under the
# bootstrap, half seen, or "⚠️ belief, not seen on a Pi". That the window's update is
# activating, or has a queued start job, by the time `systemctl start` of the window returns: seen
# in effect 2026-10-10 under the opener, not under the bootstrap; the wait checks both, so it does
# not rest on it.

set -euo pipefail

readonly WINDOW=adsb-pull-window.service WRITER=adsb-writer.service UPDATE=adsb-update.service
WINDOW_OPENED=0   # 1 once this run has asked for the pull window: only then does it close it

# lock_holder <lock>: "<PID> <unit>" of the process holding the recording lock, the unit read
# from the PID's cgroup (empty when none is named there), nothing when the lock is free, or exit 1
# when lslocks failed. Read with lslocks, which does not take the lock (taking it, even for an
# instant, could make a timer-started update skip its run).
lock_holder() {
  local lock=$1 out pid unit
  [[ -e $lock ]] || return 0
  out=$(lslocks -r -n -o PID,PATH 2>/dev/null) || return 1
  pid=$(awk -v p="$lock" '$2 == p { print $1; exit }' <<<"$out")
  [[ -n $pid ]] || return 0
  unit=$(sed -nE 's#^0::.*/([^/]+\.(service|scope))$#\1#p' "/proc/$pid/cgroup" 2>/dev/null | head -n1) || unit=''
  echo "$pid $unit"
}

# lock_verdict <lock> <seconds this run has taken>: "free", "this build's writer (PID n)" when the
# holder is adsb-writer.service and its process started during this run (update.sh starts the
# writer as it ends, or the pull window's close does, so on a first build that is the only
# recording there can be), or a reason not to reboot.
lock_verdict() {
  local lock=$1 ran=$2 h pid unit age
  h=$(lock_holder "$lock") || { echo "lslocks failed, so whether the recording lock is held is unknown"; return 0; }
  [[ -n $h ]] || { echo free; return 0; }
  read -r pid unit <<<"$h"
  age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ') || age=''
  if [[ $unit == adsb-writer.service && $age =~ ^[0-9]+$ ]] && ((age <= ran)); then
    echo "this build's writer (PID $pid, started ${age} s ago)"
  else
    echo "the recording lock is held by ${unit:-PID $pid} (process up ${age:-?} s), not by a writer this build started: a reboot would end it"
  fi
}

# open_window <lock>: PLAN §9e's (b). Starts the pull window, which stops the writer (Conflicts=)
# and starts adsb-update.service (Wants=), then waits for that update to finish, so update.sh
# --bootstrap finds the lock free. close_window ends the window: main calls it once update.sh
# returns, and main's EXIT trap calls it on every other path.
open_window() {
  local lock=$1 st job h pid unit poll=5 t=$SECONDS next=$SECONDS
  # 45 min: the bound tools/pull-archive's close puts on its wait for a running update (it waits
  # on the window's stop, whose TimeoutStopSec= is 45 min, PLAN §9m), above the update's own 40 min
  # TimeoutStartSec=.
  local deadline=$((SECONDS + 45 * 60))
  echo "==> the writer holds the recording lock; ending the session through the pull window, as ruled (PLAN §9e)"
  # Set before the start, so a start interrupted by a signal is still closed by main's EXIT trap.
  WINDOW_OPENED=1
  if ! systemctl start "$WINDOW"; then
    # A failed start is not closed: the window may never have run, so its ExecStopPost= would not
    # start the writer (⚠️ belief, not seen on a Pi), which Conflicts= may already have stopped. It
    # is started here instead.
    WINDOW_OPENED=0
    echo "xx  could not start $WINDOW (see above); starting $WRITER again (systemctl start --no-block)" >&2
    systemctl start --no-block "$WRITER" \
      || echo "!!  that failed too (exit $?): the writer may be off; start it by hand (sudo systemctl start $WRITER)" >&2
    exit 1
  fi
  echo "==> the window is open; waiting for the $UPDATE it started to finish (it may fail: it is the pinned run)"
  while :; do
    st=$(systemctl show -p ActiveState --value "$UPDATE" 2>/dev/null) || st=''
    # A start job still queued reads inactive; it is waited for too. That `list-jobs <unit>` lists
    # a queued start job: ⚠️ belief, not seen on a Pi.
    job=$(systemctl list-jobs --no-legend "$UPDATE" 2>/dev/null | grep -F "$UPDATE") || job=''
    [[ ($st == inactive || $st == failed) && -z $job ]] && break
    if ((SECONDS >= deadline)); then
      h=$(lock_holder "$lock") || h='? (lslocks failed)'
      read -r pid unit <<<"${h:-}"
      echo "xx  $UPDATE is still ${st:-unknown}${job:+ (a start job queued)} after 45 min; the recording lock is held by ${unit:-${pid:+PID }${pid:-nobody}}." >&2
      echo "    Once that update has finished, run this bootstrap again." >&2
      exit 1
    fi
    if ((SECONDS >= next)); then
      echo "    $UPDATE is ${st:-unknown}${job:+ (a start job queued)}; waited $((SECONDS - t)) s"
      next=$((SECONDS + 30))
    fi
    sleep "$poll"
  done
  echo "==> $UPDATE has finished ($st) after $((SECONDS - t)) s; the lock should now be free"
}

# close_window normal|trap: stops the pull window if this run opened it, once; the window's
# ExecStopPost= then starts the writer (--no-block) (seen 2026-10-10 under the opener, not under
# the bootstrap; PLAN §9e's (b) list).
#   - normal (main, once update.sh returns): a blocking stop, through the window's
#     ExecStop=, which waits while adsb-update.service is running (up to 45 min) (that the stop
#     blocks through ExecStop=: half seen under the opener, returning with the update already
#     inactive; ⚠️ the stop waiting while the update is activating is not seen; PLAN §9e).
#   - trap (main's EXIT trap: a signal, the wait's timeout, any other exit while open):
#     the same, unless the window's update is still running; then --no-block, so a Ctrl-C is not
#     held for up to 45 min, and systemd carries the stop through: the window ends once that
#     update finishes (up to its own 45 min wait), and the writer then starts (that a --no-block
#     stop is carried through ExecStop=: ⚠️ belief, not seen on a Pi).
# A window already ended (its 2 h cap, which skips ExecStop=: ⚠️ belief, not seen on a Pi) is not
# stopped again. Such a window reads failed, or perhaps inactive (⚠️ belief, not seen on a Pi);
# the code accepts either.
close_window() {
  local how=$1 win st
  ((WINDOW_OPENED)) || return 0
  WINDOW_OPENED=0
  win=$(systemctl is-active "$WINDOW" 2>/dev/null) || true
  if [[ $win == inactive || $win == failed ]]; then
    echo "==> the window had already ended (its 2 h cap); the writer was started by its ExecStopPost"
    return 0
  fi
  if [[ $how == trap ]]; then
    st=$(systemctl show -p ActiveState --value "$UPDATE" 2>/dev/null) || st=''
    if [[ $st == activating ]]; then
      echo "==> closing the pull window without waiting: it closes itself when $UPDATE finishes (up to the window's own 45 min wait), and the writer then starts by its ExecStopPost="
      systemctl stop --no-block "$WINDOW" \
        || echo "!!  could not stop $WINDOW (exit $?): run 'sudo systemctl stop $WINDOW'; until then the writer is off" >&2
      return 0
    fi
  fi
  echo "==> closing the pull window; it waits while $UPDATE is running, and its end starts the writer"
  systemctl stop "$WINDOW" \
    || echo "!!  could not stop $WINDOW (exit $?): run 'sudo systemctl stop $WINDOW'; until then the writer is off" >&2
}

main() {
  local url=https://github.com/Wezdenko-L-L-C/adsb-receiver.git
  local base=/opt/adsb-receiver
  local repo=$base/repo
  local no_reboot=0 args=() a prev='' role='' channel sha wt rc checkout='' fetch_ok=1
  local usage="usage: bootstrap.sh --role portable|stationary [--set key.path=value]... [--config FILE] [--no-format] [--no-reboot]"

  # No credential prompt, ever: the Pi carries none (PLAN §9a). A renamed or private repo fails.
  export GIT_TERMINAL_PROMPT=0

  for a in "$@"; do
    [[ $prev == --role ]] && role=$a
    prev=$a
    case $a in
      --no-reboot) no_reboot=1 ;;
      --rev)
        echo "xx  --rev is not a bootstrap option: to build a particular commit, check it out and run this script from that checkout" >&2
        exit 64 ;;
      -h|--help) echo "$usage"; exit 0 ;;
      *) args+=("$a") ;;
    esac
  done
  # Before apt and the clone: a bad command line changes nothing.
  case $role in
    # Both roles follow stable; the role does not choose a channel (PLAN §9g's 2026-10-05 update).
    portable|stationary) channel=stable ;;
    *) echo "xx  --role portable or --role stationary is required" >&2; echo "$usage" >&2; exit 64 ;;
  esac

  if ((EUID != 0)); then
    echo "xx  run as root: curl -fsSL <url>/setup/bootstrap.sh | sudo bash -s -- --role $role" >&2
    exit 1
  fi
  # Under `curl | sudo bash`, stdin is this script. Nothing below may read it.
  exec </dev/null

  # Run from a checkout? Under curl | bash there is no file, so this stays empty.
  local self=${BASH_SOURCE[0]:-} top
  if [[ -n $self && -f $self ]]; then
    top=$(cd "$(dirname "$self")/.." && pwd)
    [[ -e $top/.git ]] && checkout=$top
  fi

  local missing=() p s
  for p in git ca-certificates; do
    s=$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null) || s=''
    [[ $s == "install ok installed" ]] || missing+=("$p")
  done
  if ((${#missing[@]})); then
    echo "==> installing ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
  fi

  install -d -m 0755 -o root -g root "$base" "$base/worktrees"
  if [[ ! -d $repo ]]; then
    echo "==> cloning $url into $repo"
    rm -rf "$repo.tmp"
    git init --bare --quiet "$repo.tmp"
    git -C "$repo.tmp" remote add origin "$url"
    git -C "$repo.tmp" fetch --quiet origin
    mv "$repo.tmp" "$repo"
  else
    echo "==> fetching into $repo"
    if ! git -C "$repo" fetch --prune --quiet origin; then
      fetch_ok=0
      echo "!!  the fetch failed; carrying on with what $repo already has" >&2
    fi
  fi

  if [[ -n $checkout ]]; then
    # The checkout belongs to the login that cloned it, not root: git's ownership check is
    # waived for that one path, on these commands only.
    local gc=(git -c "safe.directory=$checkout" -c "safe.directory=$checkout/.git")
    sha=$("${gc[@]}" -C "$checkout" rev-parse --verify "HEAD^{commit}")
    if [[ -n $("${gc[@]}" -C "$checkout" status --porcelain --untracked-files=no 2>/dev/null) ]]; then
      echo "!!  $checkout has uncommitted changes; what is built is its last commit, ${sha:0:12}, not the edited files" >&2
    fi
    "${gc[@]}" -C "$repo" fetch --quiet "$checkout" HEAD
    git -C "$repo" cat-file -e "$sha^{commit}"
    if ! git -C "$repo" merge-base --is-ancestor "$sha" "origin/$channel" 2>/dev/null; then
      echo "!!  ${sha:0:12} (the checkout's HEAD) is not on origin/$channel, the rigs' channel (CI may still be running); building it anyway, because you ran this from that checkout" >&2
    fi
    echo "==> the checkout's HEAD is ${sha:0:12}"
  else
    sha=$(git -C "$repo" rev-parse --verify "origin/$channel^{commit}")
    if ((fetch_ok)); then
      echo "==> $channel is ${sha:0:12}"
    else
      echo "==> $channel was ${sha:0:12} at the last fetch that worked (this one failed)"
    fi
  fi

  wt=$base/worktrees/${sha:0:12}
  if [[ $(git -C "$wt" rev-parse HEAD 2>/dev/null) != "$sha" ]]; then
    local live=''
    live=$(readlink -f "$base/applied" 2>/dev/null) || live=''
    if [[ -e $wt && $wt == "$live" ]]; then
      echo "xx  $wt is the live applied worktree, but it does not read as ${sha:0:12}; not removing it. Look at it by hand" >&2
      exit 1
    fi
    git -C "$repo" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    git -C "$repo" worktree prune
    git -C "$repo" worktree add --detach --quiet "$wt" "$sha"
  fi

  # The reboot flag's and the recording lock's paths, from the lib.sh of the commit being built,
  # where they are written down once.
  local flag lock
  # shellcheck disable=SC2016  # $1 and the variables expand in the child, on purpose
  flag=$(bash -c 'source "$1/setup/lib.sh" && printf "%s" "$ADSB_REBOOT_FLAG"' _ "$wt") || flag=''
  [[ $flag == /* ]] || { echo "xx  could not read ADSB_REBOOT_FLAG from $wt/setup/lib.sh" >&2; exit 1; }
  # shellcheck disable=SC2016
  lock=$(bash -c 'source "$1/setup/lib.sh" && printf "%s" "${ADSB_RECORDING_LOCK:-}"' _ "$wt") || lock=''
  [[ $lock == /* ]] || lock=${flag%/*}/recording.lock   # a commit whose lib.sh predates the variable

  local first_build=1 before='' after='' gained='' mark t0=$SECONDS
  [[ -e $base/applied || -L $base/applied ]] && first_build=0
  # Read before the pull window opens (below), so a reason its pinned run writes counts as this
  # bootstrap's: this run started that run.
  before=$(cat "$flag" 2>/dev/null) || before=''
  # This run's own list of reboot reasons (lib.sh's need_reboot appends to it).
  mark=$(mktemp)
  # shellcheck disable=SC2064  # expanded now: $mark is local to main
  trap "rm -f '$mark'; close_window trap" EXIT

  # A first build on a recording rig: the session ends through the pull window (header; PLAN §9e's
  # (b)), only where the window unit is loaded. Otherwise update.sh refuses below, naming the holder.
  # hint tells update.sh why the bootstrap did or did not end the session (ADSB_BOOTSTRAP_WINDOW),
  # so its refusal never tells the bootstrap's own user that the bootstrap would have ended it.
  local h hpid hunit load hint=built old window_built=''
  if ((first_build)); then
    hint=not-writer
    h=$(lock_holder "$lock") || h=''
    read -r hpid hunit <<<"${h:-}" || true
    if [[ $hunit == "$WRITER" ]]; then
      load=$(systemctl show -p LoadState --value "$WINDOW" 2>/dev/null) || load=''
      if [[ $load == loaded ]]; then
        hint=opened
        open_window "$lock"
        if [[ -e $base/applied || -L $base/applied ]]; then
          first_build=0
          old=$(git -C "$base/applied" rev-parse --verify --quiet HEAD 2>/dev/null) || old='?'
          window_built=${old:0:12}
          echo "==> the window's pinned run completed the build at ${old:0:12}; this bootstrap now applies ${sha:0:12} as an ordinary update (with rollback; the foundation did not run and is not needed: steps 20 and 30 verified)"
        fi
      else
        hint=no-unit
        echo "!!  the writer (PID $hpid) holds the recording lock, and $WINDOW is '${load:-unknown}', not loaded, so the session is not ended here (PLAN §9e); update.sh refuses below" >&2
      fi
    fi
  fi

  echo "==> running $wt/setup/update.sh --bootstrap"
  rc=0
  ADSB_REBOOT_MARK=$mark ADSB_BOOTSTRAP_WINDOW=$hint bash "$wt/setup/update.sh" --bootstrap "${args[@]}" || rc=$?
  # The window closes here, before the reboot decision and its notice. Its writer start
  # (ExecStopPost=) is --no-block, so that start job may still be in flight when the decision
  # below reads the lock, and during the countdown: the race exists, and it is harmless, because
  # the shutdown cancels a start job still queued (⚠️ belief, systemd's job semantics, not seen)
  # and stops a writer already started, which starts at boot anyway. A writer that has started
  # holds the lock as a process younger than this run, which lock_verdict reads as this build's
  # writer. A no-op where no window was opened.
  close_window normal

  after=$(cat "$flag" 2>/dev/null) || after=''
  [[ -n $after ]] || exit "$rc"
  # What this run asked for: its own list, plus any line the flag gained (a step whose lib.sh
  # predates the list, or the pull window's pinned run, which this run started). Only whether it is
  # empty is used.
  gained=$(cat "$mark" 2>/dev/null) || gained=''
  if [[ -n $before ]]; then
    gained+=$'\n'$(grep -vxF -f <(printf '%s\n' "$before") <<<"$after" || true)
  else
    gained+=$'\n'$after
  fi
  gained=$(grep -v '^[[:space:]]*$' <<<"$gained" || true)

  local why=() holder
  ((no_reboot)) && why+=("--no-reboot was given")
  # A build the window's pinned run made seconds ago is named as such: "already had a build" would
  # be false for it. Either way the rule holds: never a reboot once `applied` exists.
  if [[ -n $window_built ]]; then
    why+=("the pull window's pinned run completed the build at $window_built during this bootstrap, and a bootstrap never reboots once applied exists")
  elif ((first_build == 0)); then
    why+=("this rig already had a build, and a re-run never reboots it")
  fi
  [[ -n $gained ]] || why+=("this run asked for no reboot (the reasons in $flag are from an earlier run this boot)")
  ((rc == 0 || rc == 3)) || why+=("the build stopped (exit $rc)")
  [[ $(systemctl is-enabled adsb-update.timer 2>/dev/null) == enabled ]] \
    || why+=("adsb-update.timer is not enabled, so nothing would finish the build after a boot")
  holder=$(lock_verdict "$lock" "$((SECONDS - t0))")
  [[ $holder == free || $holder == "this build's writer"* ]] || why+=("$holder")

  echo "==> REBOOT REQUIRED: $(paste -sd ';' <<<"$after")"
  if ((${#why[@]})); then
    echo "==> Not rebooting: $(IFS=';'; echo "${why[*]}"). Reboot by hand when ready (sudo systemctl reboot)."
    exit "$rc"
  fi
  [[ $holder == free ]] || echo "==> The recording lock is held by $holder; the reboot stops it cleanly."
  if ((rc == 0)); then
    echo "==> Rebooting in 5 seconds: the build is applied, and the reboot puts into effect what"
    echo "    needs one (above)."
  else
    if [[ $(systemctl cat adsb-update.timer 2>/dev/null) == *OnBootSec=* ]]; then
      echo "==> Rebooting in 5 seconds; the update timer runs the build again at this commit"
      echo "    about 3 minutes after the boot, if the recording lock is free. On a recording"
      echo "    portable the writer holds it from the boot, so the build completes in the next pull"
      echo "    window instead (tools/pull-archive from the workstation, or sudo systemctl start"
      echo "    adsb-pull-window.service, then stop, on the rig)."
    else
      echo "==> Rebooting in 5 seconds; the update timer runs the build again at its next scheduled"
      echo "    run (sooner by hand: sudo systemctl start adsb-update.service)."
    fi
    echo "    If a failed step cannot pass at this commit, run this bootstrap again (BUILD.md §8),"
    echo "    which pins to stable's tip; on a recording portable it ends the recording session itself,"
    echo "    through the pull window, so that is the one command."
  fi
  echo "    Ctrl-C now to stay up, then reboot when ready."
  sleep 5
  if ! systemctl reboot; then
    echo "!!  systemctl reboot failed (see above); reboot by hand: sudo systemctl reboot" >&2
  fi
  exit "$rc"
}

main "$@"
