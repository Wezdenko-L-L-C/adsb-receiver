#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# NN-name: WHAT THIS STEP INSTALLS OR CONFIGURES. BUILD.md §X and §8 step N.
#
# ROLE: either "Shared by both rigs, so it reads no station.yml and asserts no role."
#       or    "Stationary only: asserts station.role and refuses the portable blocks (PLAN §9b)."
#
#   setup/steps/NN-name.sh            install, then verify
#   setup/steps/NN-name.sh --verify   verify only
#
# WHAT THIS ENCODES: what actually ran on hardware, with its date and the PLAN section that records
# it — or, if nothing has run yet, say so. ⛔ No "tested on" line (PLAN §9c): a verified run is
# recorded in the docs, with its output.

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"

# For a role-specific step only; delete for a shared one. There is no --role flag (PLAN §9b).
# require_role stationary
# require_absent uploader

install_step() {
  # Idempotent: detect the done state first and return, so a re-run changes nothing.
  # Write files only through paths guard_path accepts; touch units only through `unit`.
  # ⛔ Never a foundation path or unit (lib.sh, ADSB_DENY_*): CI greps this file for them.
  :
}

# --- verify --------------------------------------------------------------------

# Check what the step was FOR, not the setting that claims it (PLAN §9c table):
# an advancing aircraft.json, not `systemctl is-active readsb`.
# Print the raw evidence, then pass or die with what to do next.
# ⚠️ An exit status is evidence only once you know what the tool means by it — rtl_test exits
#    non-zero on every non-E4000 tuner (00-drivers.sh). Read the output.
verify() {
  local out
  log "COMMAND (raw output follows)"
  out=$(COMMAND 2>&1) || true
  printf '%s\n' "$out"
  echo "----"
  grep -q 'EXPECTED EVIDENCE' <<<"$out" || die "WHAT FAILED, AND WHAT TO CHECK"
  pass "WHAT WAS SEEN"
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
