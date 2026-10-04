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

# --- Logging -----------------------------------------------------------------

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!!  WARNING: %s\n' "$*" >&2; }
die()  { printf 'xx  FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok  PASS: %s\n' "$*"; }

# Print a command, then run it, so the output reads as the guide being followed.
run() { printf '+ %s\n' "$*"; "$@"; }

# --- Arguments -----------------------------------------------------------------

# Every step takes the same arguments. `--verify` runs only the step's check.
# Sets VERIFY_ONLY to 0 or 1.
VERIFY_ONLY=0
# shellcheck disable=SC2034  # VERIFY_ONLY is read by the steps
parse_args() {
  while (($#)); do
    case $1 in
      --verify) VERIFY_ONLY=1 ;;
      -h|--help)
        echo "usage: $0 [--verify]"
        echo "  --verify  run only this step's check of the observable effect"
        exit 0 ;;
      *) die "unknown argument: $1 (usage: $0 [--verify])" ;;
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
# carries. There is no --role flag anywhere (PLAN §9b).
require_role() {
  local want=$1 got
  got=$(station_get station.role) || die "station.yml has no station.role"
  [[ $got == "$want" ]] || die "this step is for the $want rig; station.yml says station.role: ${got:-null}"
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
#    setup/foundation/ and are run by hand. CI reads these arrays to grep
#    setup/steps/, so this is the one place the list is written down.

# Written as in the PLAN §9h table; a trailing * is a glob.
ADSB_DENY_PATHS=(
  /boot/firmware
  '/etc/network*'
  /etc/NetworkManager
  /etc/systemd/network
  /etc/ssh
  '/etc/apt/sources.list*'
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
