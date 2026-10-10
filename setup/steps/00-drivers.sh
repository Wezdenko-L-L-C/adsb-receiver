#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 00-drivers: the RTL-SDR library and tools, from apt, and a modprobe blacklist
# for the kernel's DVB-T driver. BUILD.md §4 and §8 step 0.
#
# Shared by both rigs, so it reads no station.yml and asserts no role.
#
#   setup/steps/00-drivers.sh            install, then verify
#   setup/steps/00-drivers.sh --verify   verify only
#
# The package half encodes what ran on the portable rig on 2026-10-03 (PLAN
# §9j): `apt install rtl-sdr` on Raspberry Pi OS trixie. The blacklist was
# added on 2026-10-05 (below).
#
# ⚠️ Known limitation, not fixed: with two sticks plugged in, readsb
#    (--device 0) opens device 0 only (believed; not seen with two sticks),
#    and this step judges the first stick sysfs lists. One stick is verified.
#
# ℹ️ Until 2026-10-05: no modprobe blacklist. The package installs none, and the kernel's
#    dvb_usb_rtl28xxu does claim the stick, but librtlsdr prints "Detached
#    kernel driver" and opens it anyway. It detaches the driver itself.
#    Corrected 2026-10-05: it also re-attaches the driver on every close. On 2026-10-04 rtl_test
#    hung a counterfeit stick, the DVB driver re-probed it, a USB reset storm followed and the Pi
#    4's whole hub (usb 1-1) dropped. So this step now blacklists the module (install_blacklist).
#
# ⚠️ A rollback by update.sh does not remove the blacklist file: rollback does not undo creation
#    inside an existing step (PLAN §9f; the install manifest is the ruled next change). A
#    blacklist left behind is harmless: nothing on the rig uses the DVB driver.
#    Corrected 2026-10-10: the install manifest was not the next change, and it is still not
#    built. Its ruled place is unchanged: before any 🏠 stationary deploy (PLAN §9f).

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
  # trigger returns before udev has applied the rules; verify stats the node next.
  run udevadm settle --timeout=10
}

# --- the DVB driver blacklist ----------------------------------------------------

BLACKLIST=/etc/modprobe.d/adsb-receiver-rtlsdr.conf
DVB_MODULE=dvb_usb_rtl28xxu

dvb_module_loaded() { [[ -d /sys/module/$DVB_MODULE ]]; }

render_blacklist() {
  cat <<EOF
# Rendered by setup/steps/00-drivers.sh. Do not edit; re-run the step.
# The DVB-T driver claims the RTL-SDR at boot and re-binds it whenever librtlsdr lets go; nothing here uses it.
blacklist $DVB_MODULE
EOF
}

# Render, diff, install. The blacklist only stops the module loading; while it
# is loaded, the kernel re-binds the stick every time librtlsdr closes it, and
# every re-bind is a probe. So whenever the module is loaded, on every run, a
# reboot is recorded (need_reboot writes a reason once; calling it each run
# also tells a bootstrap re-run in the same boot). It is never unloaded here.
# On the portable rig (checked 2026-10-05) the initramfs does not carry the
# module and it loads from the root filesystem, so the next boot applies the
# blacklist with no initramfs rebuild.
install_blacklist() {
  local tmp
  guard_path "$BLACKLIST"
  tmp=$(mktemp)
  render_blacklist >"$tmp"
  if [[ -f $BLACKLIST ]] && cmp -s "$tmp" "$BLACKLIST" \
     && [[ $(stat -c '%U:%G %a' "$BLACKLIST") == "root:root 644" ]]; then
    log "$BLACKLIST is unchanged"
  else
    run install -m 0644 -o root -g root "$tmp" "$BLACKLIST"
    log "$BLACKLIST written"
  fi
  rm -f "$tmp"

  if dvb_module_loaded; then
    need_reboot "$DVB_MODULE is loaded; the blacklist takes effect at the next boot"
  fi
}

# --- verify --------------------------------------------------------------------

# ⛔ No verify opens the stick; readsb is the only opener. While the DVB module
#    is loaded, every close by librtlsdr is a kernel re-probe of the stick (the
#    2026-10-04 hub drop followed one); readsb opens it once and holds it. So
#    this verify reads sysfs and /dev only, and 10-decoder's verify reads
#    readsb's own open (tuner, V4, the counterfeit table) from its journal.

# sdr_devices: the sysfs directory of every RTL2832U on USB (Realtek 0bda,
# product 2838 or 2832), one per line.
sdr_devices() {
  local d v p
  for d in /sys/bus/usb/devices/*; do
    [[ -f $d/idVendor && -f $d/idProduct ]] || continue
    # A device that vanishes mid-scan is skipped: it is no longer on the bus.
    v=$(<"$d/idVendor") || continue
    p=$(<"$d/idProduct") || continue
    if [[ $v == 0bda && ( $p == 2838 || $p == 2832 ) ]]; then
      printf '%s\n' "$d"
    fi
  done
}

# sysfs_str <dir> <attr>: the attribute's text, or "(none)".
sysfs_str() {
  local s
  s=$(cat "$1/$2" 2>/dev/null) || s=
  printf '%s\n' "${s:-(none)}"
}

verify() {
  # 1. The package's effect: its tools are on PATH.
  local t
  for t in rtl_test rtl_eeprom; do
    command -v "$t" >/dev/null || die "$t is not on PATH; run this step without --verify"
  done
  pass "rtl_test and rtl_eeprom are on PATH"

  # 2. The stick, from sysfs. Install tier, like the archive drive: no stick fails.
  local devs dev
  devs=$(sdr_devices)
  [[ -n $devs ]] || die "no RTL-SDR (0bda:2838 or 0bda:2832) on USB; is the stick plugged in?"
  log "RTL2832U devices on USB, from sysfs (raw): $(tr '\n' ' ' <<<"$devs")"
  dev=$(head -n1 <<<"$devs")
  if (($(grep -c . <<<"$devs") > 1)); then
    warn "more than one RTL2832U on USB; judging the first, $dev (one stick is verified; see the header)"
  fi

  # 3. The EEPROM strings, read from sysfs without opening the stick. Printed,
  #    not judged: the counterfeit table is in 10-decoder's verify.
  log "EEPROM strings from sysfs, read without opening the stick (raw): manufacturer: $(sysfs_str "$dev" manufacturer) | product: $(sysfs_str "$dev" product) | serial: $(sysfs_str "$dev" serial)"

  # 4. The udev rule's effect on the node: root-only was the 2026-10-03 failure
  #    (usb_open error -3). The packaged rule gives root:plugdev 0660 (seen on
  #    the portable rig, 2026-10-05). Retried up to 5 times, 1 s apart, so a
  #    verify right after a replug or a trigger does not beat udev to the node.
  local node perm bus devnum i
  bus=$(<"$dev/busnum") || die "$dev/busnum vanished while reading it; is the stick dropping off the bus?"
  devnum=$(<"$dev/devnum") || die "$dev/devnum vanished while reading it; is the stick dropping off the bus?"
  node=$(printf '/dev/bus/usb/%03d/%03d' "$((10#$bus))" "$((10#$devnum))")
  for ((i = 0; i <= 5; i++)); do
    perm=$(stat -c '%G %a' "$node" 2>&1) || true
    log "stat -c '%G %a' $node: $perm"
    [[ $perm == "plugdev 660" ]] && break
    if ((i < 5)); then
      log "not yet plugdev 660; waiting 1 s for udev ($((i + 1))/5)"
      sleep 1
    fi
  done
  [[ $perm == "plugdev 660" ]] \
    || die "$node is '$perm', not 'plugdev 660': the udev rule has not applied. Replug the stick, or run: udevadm trigger --subsystem-match=usb"
  pass "$node is group plugdev, mode 660"

  # 5. The blacklist. The module's state is reported, never judged.
  log "$BLACKLIST (raw output follows)"
  cat "$BLACKLIST" 2>&1 || true
  echo "----"
  grep -qx "blacklist $DVB_MODULE" "$BLACKLIST" 2>/dev/null \
    || die "$BLACKLIST does not blacklist $DVB_MODULE; run this step without --verify"
  if dvb_module_loaded; then
    warn "$DVB_MODULE is loaded; the kernel may re-bind the stick on any close until the next boot, when the blacklist takes effect"
    # In --verify mode too, so a verify-only run records the reason.
    need_reboot "$DVB_MODULE is loaded; the blacklist takes effect at the next boot"
    pass "$BLACKLIST blacklists $DVB_MODULE (the module is loaded)"
  else
    pass "$BLACKLIST blacklists $DVB_MODULE, and the module is not loaded"
  fi
}

if ((VERIFY_ONLY == 0)); then
  install_drivers
  install_blacklist
fi
verify
