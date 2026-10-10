# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash
#
# setup/lib.sh: shared helpers for setup/steps/*.sh. Source it; do not run it.
# Each step sets `set -euo pipefail` itself, before sourcing this file.
#
# See docs/PLAN.md §9 for the design these helpers serve.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "setup/lib.sh is sourced by the step scripts; it does nothing on its own." >&2
  exit 1
fi

ADSB_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ADSB_ETC=/etc/adsb-receiver

# The exit code of a step run with --skip-other-role on the other role's rig
# (PLAN §9b). Any unused value below 126 would do. ⛔ Not 3: station_get exits 3
# for an absent key. setup/update.sh records it as "skipped (role)" (PLAN §9f),
# reading this value from the candidate's own lib.sh.
ADSB_RC_OTHER_ROLE=100

# The run directory's paths, written down here once. Steps and bootstrap.sh
# read them from here; update.sh and the login banner, which source nothing,
# carry copies, and CI compares those copies with these values.
# The reboot flag (PLAN §9f: update.sh never reboots; it records that a reboot is
# needed). On tmpfs, so a reboot clears it, which is exactly its meaning.
ADSB_RUN_DIR=/run/adsb-receiver
ADSB_REBOOT_FLAG=$ADSB_RUN_DIR/reboot-required
# The recording lock (PLAN §9f, §9m): held by the writer while it runs, and by
# update.sh while it runs.
# shellcheck disable=SC2034  # read by the steps and bootstrap.sh
ADSB_RECORDING_LOCK=$ADSB_RUN_DIR/recording.lock
# The home-gated opener's own runtime directory (PLAN §9f's 2026-10-04 (night)
# update), root:root 0755, made by step 70's own tmpfiles.d file. ⛔ Not
# ADSB_RUN_DIR: that is owned by adsb-receiver, the writer's user, so a
# compromised writer could plant a symlink there, and a root write by name
# would follow it (found by a security review, 2026-10-09). Only root writes
# here. It outlives each run of the oneshot: the banner reads the state between.
# shellcheck disable=SC2034  # read by step 70
ADSB_HOME_DIR=/run/adsb-home-update
# The opener's marker: the opener writes it before it starts the pull window and
# removes it after; while it exists and the opener's unit is running, update.sh
# records opened_by: adsb-home-update. Step 70 passes it to the opener through
# its unit's Environment=; update.sh carries a copy.
# shellcheck disable=SC2034  # read by step 70
ADSB_WINDOW_MARK=$ADSB_HOME_DIR/window-opened-by
# The opener's predicate's last verdict, "<at-home|not-at-home|off|cannot-tell>
# <UTC time>", world-readable, for the login banner, which runs as the login and
# so cannot read station.yml. Written by bin/adsb-at-home under its unit (step
# 70 passes the path in Environment=); the banner carries a copy.
# shellcheck disable=SC2034  # read by step 70
ADSB_HOME_STATE=$ADSB_HOME_DIR/home-update-state

# --- Logging -----------------------------------------------------------------

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!!  WARNING: %s\n' "$*" >&2; }
die()  { printf 'xx  FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok  PASS: %s\n' "$*"; }

# Print a command, then run it, so the output reads as the guide being followed.
run() { printf '+ %s\n' "$*"; "$@"; }

# need_reboot <reason>: record that a change takes effect only after a reboot.
# Appends the reason to ADSB_REBOOT_FLAG once, as one line (newlines become
# spaces, so it matches itself next time); update.sh copies the reasons into
# status.json, the login banner shows them, and setup/bootstrap.sh reads this
# path from here. Nothing here reboots.
# ADSB_REBOOT_MARK, when setup/bootstrap.sh sets it, names a file of its own:
# every reason is also appended there, even one the flag already holds, so the
# bootstrap knows what THIS run asked for (a re-run in the same boot adds no
# line to the flag).
need_reboot() {
  local reason="$*"
  reason=${reason//$'\r'/ }
  reason=${reason//$'\n'/ }
  [[ -n ${reason// /} ]] || die "need_reboot needs a reason"
  if [[ ! -d ${ADSB_REBOOT_FLAG%/*} ]]; then
    # Before 05-config's tmpfiles.d entry exists (a first build); that entry
    # sets the directory's owner and mode when it runs.
    install -d -m 0755 "${ADSB_REBOOT_FLAG%/*}"
  fi
  if ! grep -qxF -- "$reason" "$ADSB_REBOOT_FLAG" 2>/dev/null; then
    printf '%s\n' "$reason" >>"$ADSB_REBOOT_FLAG"
  fi
  if [[ -n ${ADSB_REBOOT_MARK:-} ]]; then
    printf '%s\n' "$reason" >>"$ADSB_REBOOT_MARK" \
      || warn "could not record the reason in $ADSB_REBOOT_MARK (the bootstrap's per-run list)"
  fi
  warn "REBOOT REQUIRED: $reason (recorded in $ADSB_REBOOT_FLAG)"
}

# --- Arguments -----------------------------------------------------------------

# Every step takes the same arguments. `--verify` runs only the step's check.
# `--skip-other-role` changes only what a role mismatch means (see require_role);
# it names no role, so the role still comes from station.yml (PLAN §9b).
# Sets VERIFY_ONLY and SKIP_OTHER_ROLE to 0 or 1.
VERIFY_ONLY=0
SKIP_OTHER_ROLE=0
# shellcheck disable=SC2034  # VERIFY_ONLY is read by the steps
parse_args() {
  while (($#)); do
    case $1 in
      --verify) VERIFY_ONLY=1 ;;
      --skip-other-role) SKIP_OTHER_ROLE=1 ;;
      -h|--help)
        echo "usage: $0 [--verify] [--skip-other-role]"
        echo "  --verify           run only this step's check of the observable effect"
        echo "  --skip-other-role  if this step is for the other rig, say so and exit $ADSB_RC_OTHER_ROLE"
        echo "                     instead of failing (how update.sh runs every step, PLAN §9b)"
        exit 0 ;;
      *) die "unknown argument: $1 (usage: $0 [--verify] [--skip-other-role])" ;;
    esac
    shift
  done
}

# Re-run the calling step under sudo if it is not already root.
# Call it as: require_root "$@"
require_root() {
  if ((EUID != 0)); then
    log "re-running under sudo"
    exec sudo -- bash "$0" "$@"
  fi
}

# --- station.yml ------------------------------------------------------------

# The installed copy (written by 05-config, root-only) wins. Before 05-config
# has run, fall back to the copy you are editing in the clone.
station_file() {
  local f
  for f in "$ADSB_ETC/station.yml" "$ADSB_REPO/config/station.yml"; do
    if [[ -r $f ]]; then echo "$f"; return 0; fi
  done
  return 1
}

# station_get <dotted.key>: print the value ("" for null). Exits 3 if the key
# is absent, so a missing key and a null one can be told apart.
station_get() {
  local f
  f=$(station_file) || die "no station.yml: copy a config/station.*.example.yml to config/station.yml"
  python3 - "$f" "$1" <<'PY'
import sys, yaml
with open(sys.argv[1]) as fh:
    node = yaml.safe_load(fh) or {}
for key in sys.argv[2].split("."):
    if not isinstance(node, dict) or key not in node:
        sys.exit(3)
    node = node[key]
if node is None:
    print("")
elif isinstance(node, bool):
    print("true" if node else "false")
else:
    print(node)
PY
}

# station_has <dotted.key>: true if the key is present, even when null.
station_has() {
  local rc=0
  station_get "$1" >/dev/null || rc=$?
  case $rc in
    0) return 0 ;;
    3) return 1 ;;
    *) die "could not read $1 from station.yml" ;;
  esac
}

# require_role <portable|stationary>: the role comes from the config the rig
# carries. There is no --role flag anywhere (PLAN §9b). On a mismatch it dies,
# unless --skip-other-role was given: then it says so and exits
# ADSB_RC_OTHER_ROLE. A step calls it before any other command after
# parse_args and require_root, so a skip never half-runs; CI checks that order.
require_role() {
  local want=$1 got
  got=$(station_get station.role) || die "station.yml has no station.role"
  [[ $got == "$want" ]] && return 0
  if ((SKIP_OTHER_ROLE)); then
    log "skipped: this step is for the $want rig; station.yml says ${got:-null}"
    exit "$ADSB_RC_OTHER_ROLE"
  fi
  die "this step is for the $want rig; station.yml says station.role: ${got:-null}"
}

# require_absent <dotted.key>: refuse the other role's blocks (PLAN §9b).
require_absent() {
  if station_has "$1"; then
    die "station.yml sets '$1', which this rig's role must not have; see the template for your role"
  fi
}

# --- The foundation denylist (PLAN §9h) --------------------------------------
#
# ⛔ Steps never touch what keeps the rig reachable. Those live in
#    setup/foundation/, run by hand, or by update.sh --bootstrap on a first
#    build (never by the timer). CI reads these arrays to grep setup/steps/,
#    setup/update.sh, setup/bootstrap.sh, setup/foundation/, setup/files/,
#    bin/ and tools/ (only setup/foundation/rtc-overlay.sh may name
#    /boot/firmware), so this is the one place the list is written down.

# Written as in the PLAN §9h table; a trailing * is a glob.
ADSB_DENY_PATHS=(
  /boot/firmware
  '/etc/network*'
  /etc/NetworkManager
  /etc/systemd/network
  /etc/ssh
  '/etc/apt/sources.list*'
  /etc/fstab
)
# ssh.service is also reachable as sshd.service on Debian, so both names are listed.
ADSB_DENY_UNITS=(tailscaled ssh sshd NetworkManager)

# guard_path <path>: die if the path is a denylisted one, or under one.
guard_path() {
  local p deny
  p=$(realpath -m -- "$1")
  for deny in "${ADSB_DENY_PATHS[@]}"; do
    # shellcheck disable=SC2053  # $deny is a glob on purpose
    if [[ $p == $deny || $p == $deny/* ]]; then
      die "refusing to write $p: it is foundation (setup/foundation/), not a step's"
    fi
  done
  return 0
}

# guard_unit <unit>: die if the unit is denylisted.
guard_unit() {
  local u=${1%.service} deny
  for deny in "${ADSB_DENY_UNITS[@]}"; do
    [[ $u == "$deny" ]] && die "refusing to touch $1: it is foundation (setup/foundation/), not a step's"
  done
  return 0
}

# unit <verb> <unit>: systemctl, behind the denylist.
unit() {
  guard_unit "$2"
  run systemctl "$1" "$2"
}
