#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 00-drivers: the RTL-SDR library and tools, from apt. BUILD.md §4 and §8 step 0.
#
# Shared by both rigs, so it reads no station.yml and asserts no role.
#
#   setup/steps/00-drivers.sh            install, then verify
#   setup/steps/00-drivers.sh --verify   verify only
#
# What this encodes is what ran on the portable rig on 2026-10-03 (PLAN §9j):
# `apt install rtl-sdr` on Raspberry Pi OS trixie, and nothing else.
#
# ℹ️ No modprobe blacklist. The package installs none, and the kernel's
#    dvb_usb_rtl28xxu does claim the stick, but librtlsdr prints "Detached
#    kernel driver" and opens it anyway. It detaches the driver itself.

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"

install_drivers() {
  if dpkg-query -W -f='${Status}' rtl-sdr 2>/dev/null | grep -q 'install ok installed'; then
    log "rtl-sdr is already installed; nothing to do"
    return 0
  fi
  # Only on this path: a fresh image may have stale or empty package lists.
  run apt-get update
  run apt-get install -y rtl-sdr

  # ⚠️ A stick plugged in before the udev rules existed keeps root-only
  #    permissions (`usb_open error -3` on 2026-10-03; a replug fixed it).
  #    Reloading and re-triggering should apply the new rules without a
  #    replug. That is an inference; it has not been seen working on the Pi.
  run udevadm control --reload-rules
  run udevadm trigger --subsystem-match=usb
}

# --- verify --------------------------------------------------------------------

# rtl_test cannot open the stick while readsb holds it. If readsb is running,
# stop it for the check and always start it again on the way out.
READSB_STOPPED=0
restart_readsb() {
  if ((READSB_STOPPED)); then
    unit start readsb || warn "readsb did not restart; check: systemctl status readsb"
  fi
}

# Run as the user who called sudo, so the check exercises the udev rules and
# plugdev, which root would bypass.
as_user() {
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    runuser -u "$SUDO_USER" -- "$@"
  else
    "$@"
  fi
}

verify() {
  command -v rtl_test >/dev/null || die "rtl_test is not installed; run this step without --verify"

  if systemctl is-active --quiet readsb; then
    log "readsb is running and holds the stick; stopping it for the check"
    trap restart_readsb EXIT
    unit stop readsb
    READSB_STOPPED=1
  fi

  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    log "checking as $SUDO_USER, so the udev rules are exercised"
  else
    warn "running as root directly: udev permissions are not exercised by this check"
  fi

  # ⚠️ rtl_test's exit status is not evidence: it prints "No E4000 tuner found,
  #    aborting." on every non-E4000 tuner. Read its output instead.
  local out
  log "rtl_test -t (raw output follows)"
  out=$(as_user timeout 10 rtl_test -t 2>&1) || true
  printf '%s\n' "$out"
  echo "----"

  if grep -q 'usb_open error' <<<"$out"; then
    die "usb_open error: a permissions problem. Replug the stick, and check that ${SUDO_USER:-your user} is in plugdev (id -nG)"
  fi
  if ! grep -qE 'Found [1-9][0-9]* device' <<<"$out"; then
    die "no RTL-SDR device found. Is the stick plugged in?"
  fi

  local tuner v4=0
  tuner=$(grep -oE 'Found .+ tuner' <<<"$out" | head -n1 | sed -E 's/^Found //; s/ tuner$//') || true
  [[ -n $tuner ]] || die "the device opened but no tuner line was printed"
  grep -q 'RTL-SDR Blog V4 Detected' <<<"$out" && v4=1

  # The EEPROM strings. A genuine V4 is believed to read "RTLSDRBlog" /
  # "Blog V4" (unverified, PLAN §9j). rtl_eeprom without arguments only reads.
  local eeprom maker product
  log "rtl_eeprom (raw output follows)"
  eeprom=$(as_user timeout 10 rtl_eeprom 2>&1) || true
  printf '%s\n' "$eeprom"
  echo "----"
  maker=$(sed -nE 's/^Manufacturer:[[:space:]]*//p' <<<"$eeprom" | head -n1)
  product=$(sed -nE 's/^Product:[[:space:]]*//p' <<<"$eeprom" | head -n1)
  log "tuner: $tuner | EEPROM manufacturer: ${maker:-?} | product: ${product:-?}"

  if [[ $tuner == *R828D* ]] && ((v4)); then
    pass "genuine V4 path: R828D tuner, and the library detected an RTL-SDR Blog V4"
    return 0
  fi
  ((v4)) && die "the library reported a V4 but the tuner is $tuner; that should not happen"

  # ⛔ An R828D with no V4 line is the BUILD.md §4 silent failure: a V4 on a
  #    library without V4 support. It may half-work, so it must not pass.
  if [[ $tuner == *R828D* ]]; then
    die "R828D tuner but no 'RTL-SDR Blog V4 Detected': the librtlsdr in use lacks V4 support. See BUILD.md §4"
  fi

  # ⚠️ The counterfeit signature (PLAN §9j): sold as a V4, and not an R828D.
  if [[ "$maker $product" =~ [Bb]log|V4 ]]; then
    warn "################################################################"
    warn "The EEPROM claims RTL-SDR Blog / V4, but the tuner is $tuner, not R828D."
    warn "That is the counterfeit-V4 signature recorded in docs/PLAN.md §9j."
    warn "################################################################"
  else
    warn "If the case says V4, a non-R828D tuner is the counterfeit signature in docs/PLAN.md §9j."
  fi
  pass "non-V4 stick (tuner: $tuner)"
}

if ((VERIFY_ONLY == 0)); then
  install_drivers
fi
verify
