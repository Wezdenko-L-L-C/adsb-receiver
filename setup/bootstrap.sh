#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# setup/bootstrap.sh: build a rig with one command, on a fresh Raspberry Pi OS. PLAN §9e and §9f.
#
#   curl -fsSL https://raw.githubusercontent.com/Wezdenko-L-L-C/adsb-receiver/main/setup/bootstrap.sh \
#     | sudo bash -s -- --role portable
#
# or, to read it before it runs (the commit you read is the commit that is built):
#
#   sudo apt install -y git
#   git clone https://github.com/Wezdenko-L-L-C/adsb-receiver.git
#   (read it; `git -C adsb-receiver checkout <commit>` if you mean another one)
#   sudo bash adsb-receiver/setup/bootstrap.sh --role portable
#
# Arguments (all but --no-reboot are passed to update.sh --bootstrap):
#   --role portable|stationary   required: which template station.yml is written from, and which
#                                channel is built (PLAN §9g: portable main, stationary stable)
#   --set key.path=value         repeatable: edit one key of it (a stationary needs position.*)
#   --config FILE                use this station.yml instead of the template
#   --no-format                  never format the archive drive, even if exactly one qualifies
#   --no-reboot                  do not reboot at the end, even if the build needs it
#
# Thin on purpose: install git if missing, clone this repo into /opt/adsb-receiver (a bare clone
# plus a detached worktree, the layout update.sh keeps), and run that worktree's
# setup/update.sh --bootstrap, which does the build. Which commit:
#   - run from a checkout (this file sits in a git checkout): that checkout's HEAD, fetched into
#     the bare clone, with a warning if it is not on the role's channel;
#   - otherwise (curl | bash): the tip of the role's channel, main or stable. A stationary first
#     build takes stable's tip without the soak: the bench is attended; the soak (PLAN §9g)
#     protects the unattended rig. The updater, the config code and the foundation scripts come
#     from that same commit, so nothing newer than what was chosen runs as root.
# ⚠️ Run again on a rig that is already built, it builds the same way, as an ordinary update
#    (with rollback, and on a stationary with the gate): on a stationary that means stable's tip
#    WITHOUT the soak, however young it is. The timer is what waits out the soak (PLAN §9g).
#
# The one thing done here besides that: a reboot, once, after a printed 5 s notice, and only when
# all of these hold (PLAN §9e's evening update):
#   - this run started with no /opt/adsb-receiver/applied (a first build);
#   - this run asked for a reboot: a step or foundation script called lib.sh's need_reboot (the
#     RTC overlay, a remounted archive drive). Each reason is also written to a file of this
#     run's own (ADSB_REBOOT_MARK), so a reason counts even when the flag (lib.sh's
#     ADSB_REBOOT_FLAG) already held it from an earlier run in the same boot;
#   - adsb-update.timer is enabled, so the build can finish after the boot;
#   - the recording lock is free, or held only by the writer that this build started at its end
#     (seconds of recording, which the shutdown's SIGTERM closes cleanly). Any other holder, such
#     as an update run the timer started meanwhile, blocks the reboot;
#   - update.sh exited 0 (applied) or 3 (incomplete). After a Ctrl-C or SIGTERM it exits 128+N,
#     even on a first build, so an interrupted build never turns into a reboot countdown.
# Otherwise it prints REBOOT REQUIRED with the reasons and exits. It never reboots once `applied`
# exists. update.sh itself never reboots. After the boot, adsb-update.timer finishes an incomplete
# build: on a portable about 3 minutes after the boot; on a stationary, which has no boot timer,
# at its nightly run (or by hand: sudo systemctl start adsb-update.service).
#
# Everything is inside functions, run by the last line (main), so a download cut short runs
# nothing, or stops at the usage check.
#
# What has run on hardware: nothing. ⚠️ Unverified on the Pi: all of it.

set -euo pipefail

# lock_verdict <lock> <seconds this run has taken>: "free", "this build's writer (PID n)" when the
# holder is adsb-writer.service and its process started during this run (update.sh starts the
# writer as it ends, so on a first build that is the only recording there can be), or a reason
# not to reboot. Read with lslocks, which does not take the lock (taking it, even for an instant,
# could make a timer-started update skip its run). The unit comes from the PID's cgroup.
lock_verdict() {
  local lock=$1 ran=$2 out pid unit age
  [[ -e $lock ]] || { echo free; return 0; }
  out=$(lslocks -r -n -o PID,PATH 2>/dev/null) || { echo "lslocks failed, so whether the recording lock is held is unknown"; return 0; }
  pid=$(awk -v p="$lock" '$2 == p { print $1; exit }' <<<"$out")
  [[ -n $pid ]] || { echo free; return 0; }
  unit=$(sed -nE 's#^0::.*/([^/]+\.(service|scope))$#\1#p' "/proc/$pid/cgroup" 2>/dev/null | head -n1) || unit=''
  age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ') || age=''
  if [[ $unit == adsb-writer.service && $age =~ ^[0-9]+$ ]] && ((age <= ran)); then
    echo "this build's writer (PID $pid, started ${age} s ago)"
  else
    echo "the recording lock is held by ${unit:-PID $pid} (process up ${age:-?} s), not by a writer this build started: a reboot would end it"
  fi
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
    portable) channel=main ;;
    stationary) channel=stable ;;
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
      echo "!!  ${sha:0:12} (the checkout's HEAD) is not on origin/$channel, the $role rig's channel; building it anyway, because you ran this from that checkout" >&2
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
  before=$(cat "$flag" 2>/dev/null) || before=''
  # This run's own list of reboot reasons (lib.sh's need_reboot appends to it).
  mark=$(mktemp)
  # shellcheck disable=SC2064  # expanded now: $mark is local to main
  trap "rm -f '$mark'" EXIT

  echo "==> running $wt/setup/update.sh --bootstrap"
  rc=0
  ADSB_REBOOT_MARK=$mark bash "$wt/setup/update.sh" --bootstrap "${args[@]}" || rc=$?

  after=$(cat "$flag" 2>/dev/null) || after=''
  [[ -n $after ]] || exit "$rc"
  # What this run asked for: its own list, plus any line the flag gained (a step whose lib.sh
  # predates the list). Only whether it is empty is used.
  gained=$(cat "$mark" 2>/dev/null) || gained=''
  if [[ -n $before ]]; then
    gained+=$'\n'$(grep -vxF -f <(printf '%s\n' "$before") <<<"$after" || true)
  else
    gained+=$'\n'$after
  fi
  gained=$(grep -v '^[[:space:]]*$' <<<"$gained" || true)

  local why=() holder
  ((no_reboot)) && why+=("--no-reboot was given")
  ((first_build)) || why+=("this rig already had a build, and a re-run never reboots it")
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
    echo "    needs one (above). Ctrl-C now to stay up, then reboot when ready."
  elif [[ $(systemctl cat adsb-update.timer 2>/dev/null) == *OnBootSec=* ]]; then
    echo "==> Rebooting in 5 seconds to finish the build; the update timer runs it again about"
    echo "    3 minutes after the boot. Ctrl-C now to stay up, then reboot when ready."
  else
    echo "==> Rebooting in 5 seconds; the update timer runs the build again at its next scheduled"
    echo "    run (sooner by hand: sudo systemctl start adsb-update.service). Ctrl-C now to stay up."
  fi
  sleep 5
  if ! systemctl reboot; then
    echo "!!  systemctl reboot failed (see above); reboot by hand: sudo systemctl reboot" >&2
  fi
  exit "$rc"
}

main "$@"
