#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 30-archive-drive: mount the archive drive at /var/lib/adsb-receiver/archive,
# make beast/ and spool/ on it, and install bin/archive-preflight. PLAN §9m.
#
# Portable only, for now: asserts station.role and refuses a position: block
# (PLAN §9b). The gate is dated below; the step itself is generic.
#
#   setup/steps/30-archive-drive.sh            install, then verify
#   setup/steps/30-archive-drive.sh --verify   verify only
#
# As of 2026-10-04, nothing in this step has run on hardware.
#
# ⛔ It never formats anything. Formatting is a human gate (PLAN §9m): with no
#    ext4 filesystem carrying archive.label, it prints the commands and exits
#    non-zero. It runs no mkfs, and tune2fs only to read (-l).
# ⛔ It creates no users or groups. 05-config does (PLAN §9m rejects this step
#    doing it).
#
# The mount is a native systemd mount unit, not a line in the fstab, which
# carries the root filesystem's line and is on the PLAN §9h denylist.
#
# ⚠️ Two systemd behaviors this design rests on are UNVERIFIED. They were
#    recalled during the PLAN §9m consultation and not checked:
#    1. that x-systemd.device-timeout= is ignored in a mount unit's Options=.
#       That is why the device timeout is a drop-in on the device unit.
#    2. that a native mount unit does not pull in systemd-fsck@ by itself.
#       That is why Requires= and After= name it explicitly.
#    The observable check, on the Pi: a boot without the drive reaches the
#    login banner in seconds, and `journalctl -u 'systemd-fsck@*'` shows a run.
#    If the native unit cannot do both, the fallback is the fstab with
#    nofail,x-systemd.device-timeout=10s, which conflicts with the denylist and
#    goes back to Chris (PLAN §9m).

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"

# 2026-10-04: portable-only until the stationary rig's SSD question in PLAN §9m
# is decided (boot device, or a separate labeled partition). If the answer is a
# labeled partition, deleting this gate shares the step, with no rename.
require_role portable
require_absent position

for t in blkid lsblk findmnt mountpoint systemd-escape tune2fs python3; do
  command -v "$t" >/dev/null || die "$t is not installed"
done

LABEL=$(station_get archive.label) \
  || die "station.yml has no archive.label: add the archive: block from config/station.portable.example.yml"
MIN_FREE_GB=$(station_get archive.min_free_gb) \
  || die "station.yml has no archive.min_free_gb: add the archive: block from config/station.portable.example.yml"
# ext4 caps a label at 16 bytes. This set also keeps /dev/disk/by-label/<label>
# free of udev's \x escapes.
[[ $LABEL =~ ^[A-Za-z0-9_-]{1,16}$ ]] \
  || die "archive.label '${LABEL}' must be 1-16 letters, digits, '-' or '_' (ext4's 16-byte limit)"
[[ $MIN_FREE_GB =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || die "archive.min_free_gb '${MIN_FREE_GB}' must be a number of gigabytes"

USER_NAME=adsb-receiver
GROUP_NAME=adsb-operator
getent passwd "$USER_NAME" >/dev/null || die "no user $USER_NAME: run setup/steps/05-config.sh first"
getent group "$GROUP_NAME" >/dev/null || die "no group $GROUP_NAME: run setup/steps/05-config.sh first"

MP=/var/lib/adsb-receiver/archive
BY_LABEL=/dev/disk/by-label/$LABEL
UNIT_DIR=/etc/systemd/system
MOUNT_UNIT=$(systemd-escape -p --suffix=mount "$MP")
FSCK_UNIT="systemd-fsck@$(systemd-escape -p "$BY_LABEL").service"
DEVICE_UNIT=$(systemd-escape -p --suffix=device "$BY_LABEL")
DROPIN=$UNIT_DIR/$DEVICE_UNIT.d/timeout.conf
# Copied, not symlinked: update.sh is to flip between two worktrees (PLAN §9f),
# and a symlink into one would follow the flip.
PREFLIGHT=/usr/local/bin/archive-preflight

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

# format_help <reason>: the human gate. Print the drives and the commands, and fail.
format_help() {
  log "lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL (raw output follows)"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL 2>&1 || true
  echo "----"
  warn "$1"
  cat >&2 <<EOF
    Formatting the archive drive is done by hand, once (PLAN §9m). No script runs mkfs.
    Format partition 1, not the whole device: the stick ships with an MBR
    partition table, and formatting partition 1 keeps that table.
    1. Find the drive in the listing above by its SIZE and MODEL. Check it twice:
       mkfs erases whatever device you name, the wrong one included.
    2. sudo mkfs.ext4 -L $LABEL -m 0 /dev/sdX1
    3. sudo tune2fs -c 1 /dev/sdX1       (an fsck on every mount)
    Then run this step again.
EOF
  die "no ext4 filesystem labeled $LABEL"
}

# find_device: exactly one block device carries the label, and it is ext4.
# Sets DEV. -c /dev/null makes blkid probe the devices rather than trust its cache.
DEV=
find_device() {
  local devs n fstype
  devs=$(blkid -c /dev/null -o device -t "LABEL=$LABEL" 2>/dev/null) || true
  n=$(grep -c . <<<"$devs") || true
  if ((n > 1)); then
    log "blkid: devices labeled $LABEL (raw output follows)"
    printf '%s\n' "$devs"
    echo "----"
    die "more than one device carries the label $LABEL; unplug or relabel all but one"
  fi
  ((n == 1)) || format_help "no filesystem is labeled $LABEL"
  DEV=$devs
  fstype=$(blkid -c /dev/null -o value -s TYPE "$DEV" 2>/dev/null) || true
  [[ $fstype == ext4 ]] || format_help "$DEV is labeled $LABEL but is ${fstype:-not formatted}, not ext4"
  log "the archive drive: $DEV, ext4, label $LABEL"
}

# live_opts_missing: print which of the unit's options the live mount at $MP
# lacks (noatime, errors=remount-ro); print nothing when it has them all. Reads
# findmnt and, for errors=, /proc/fs/ext4/<dev>/options (see verify).
live_opts_missing() {
  local opts kname procopts o
  opts=$(findmnt -nr -o OPTIONS --mountpoint "$MP" | tail -n1) || true
  kname=$(basename "$(realpath -- "$DEV")")
  procopts=$(cat "/proc/fs/ext4/$kname/options" 2>/dev/null) || true
  for o in noatime errors=remount-ro; do
    if [[ ,$opts, != *,"$o",* ]] && ! grep -qx -- "$o" <<<"$procopts"; then
      printf '%s ' "$o"
    fi
  done
}

install_mount_point() {
  # While mounted, the path is the drive's root directory: leave its mode alone.
  if mountpoint -q "$MP"; then
    log "$MP is mounted; the mount point underneath is left as it is"
    return 0
  fi
  guard_path "$MP"
  [[ -d $MP ]] || run mkdir -p "$MP"
  # ⚠️ 0555 stops only a writer that is not root (PLAN §9m). The real guards are
  #    the preflight and the writer's RequiresMountsFor=.
  if [[ $(stat -c '%U:%G %a' "$MP") == "root:root 555" ]]; then
    log "$MP is root:root 0555"
  else
    run chown root:root "$MP"
    run chmod 0555 "$MP"
  fi
  if [[ -n $(find "$MP" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    warn "the bare mount point $MP is not empty, on the SD card. The mount will hide what is there; look before you trust it"
  fi
}

render_units() {
  cat >"$WORK/mount" <<EOF
# Rendered by setup/steps/30-archive-drive.sh from station.yml (archive.label).
# Do not edit; re-run the step. PLAN §9m.
[Unit]
Description=adsb-receiver archive drive (label $LABEL)
# An fsck on every mount (the drive is formatted with tune2fs -c 1), wired
# explicitly: a native mount unit is believed not to pull it in (unverified).
Requires=$FSCK_UNIT
After=$FSCK_UNIT

[Mount]
What=$BY_LABEL
Where=$MP
Type=ext4
# No discard: continuous TRIM over USB mass storage is often unsupported, and
# it can stall a cheap controller. The weekly fstrim.timer skips a device
# without TRIM (PLAN §9m).
Options=noatime,errors=remount-ro

[Install]
WantedBy=multi-user.target
EOF

  # Believed to be what the fstab option x-systemd.device-timeout=10s generates
  # (a belief, not checked). Without it, a boot with no drive waits out the
  # default device timeout before the mount fails.
  cat >"$WORK/timeout.conf" <<EOF
# Rendered by setup/steps/30-archive-drive.sh. Do not edit; re-run the step.
# A missing archive drive fails its mount in about 10 s (PLAN §9m).
[Unit]
JobRunningTimeoutSec=10s
EOF
}

install_units() {
  local first=0 mount_changed=0 dropin_changed=0
  render_units
  [[ -f $UNIT_DIR/$MOUNT_UNIT ]] || first=1
  install_if_changed "$WORK/mount" "$UNIT_DIR/$MOUNT_UNIT" 0644 root:root
  mount_changed=$CHANGED
  install_if_changed "$WORK/timeout.conf" "$DROPIN" 0644 root:root
  dropin_changed=$CHANGED
  if ((mount_changed || dropin_changed)); then
    run systemctl daemon-reload
  fi

  if ! systemctl is-enabled --quiet "$MOUNT_UNIT"; then
    unit enable "$MOUNT_UNIT"
  fi
  # Starting a mount that is not active interrupts nothing, first install or not.
  local missing
  if ! systemctl is-active --quiet "$MOUNT_UNIT"; then
    unit start "$MOUNT_UNIT" \
      || die "the mount did not start; check: systemctl status '$MOUNT_UNIT' and journalctl -b -u '$FSCK_UNIT'"
  elif ((mount_changed && !first)); then
    # ⛔ A changed mount unit never restarts the mount (PLAN §9m): unmounting
    #    under a recording would end it. 📋 PLAN §9f has update.sh set
    #    reboot_required in status.json; neither exists yet, so this warning is
    #    the only record.
    warn "################################################################"
    warn "$MOUNT_UNIT changed while mounted. It was NOT restarted."
    warn "REBOOT REQUIRED for the new mount unit to take effect."
    warn "################################################################"
  fi
  if ((dropin_changed && !first)); then
    log "the device timeout changed; it applies from the next boot"
  fi
  # A path already mounted before the unit existed (by hand, say) keeps the
  # options it was mounted with, whatever the unit now says.
  missing=$(live_opts_missing)
  if [[ -n $missing ]]; then
    warn "################################################################"
    warn "$MP is mounted without: $missing"
    warn "The unit file is right; the live mount is older than it. Unmount and"
    warn "start the unit (systemctl stop/start '$MOUNT_UNIT'), or reboot."
    warn "################################################################"
  fi
}

install_drive_dirs() {
  mountpoint -q "$MP" || die "$MP is not mounted; check: systemctl status '$MOUNT_UNIT'"
  local d path
  for d in beast spool; do
    path=$MP/$d
    guard_path "$path"
    [[ -d $path ]] || run mkdir "$path"
    if [[ $(stat -c '%U:%G' "$path") != "$USER_NAME:$GROUP_NAME" ]]; then
      run chown "$USER_NAME:$GROUP_NAME" "$path"
    fi
    # 2770: the group can read and delete without root; setgid passes the group
    # on; no sticky bit, which would stop the group deleting (PLAN §9m).
    if [[ $(stat -c '%a' "$path") != 2770 ]]; then
      run chmod 2770 "$path"
      [[ $(stat -c '%a' "$path") == 2770 ]] || run chmod u-s,-t "$path"
    fi
    log "$path: $(stat -c '%U:%G %a' "$path")"
  done
}

install_preflight() {
  local src=$ADSB_REPO/bin/archive-preflight
  [[ -f $src ]] || die "$src is missing from this checkout"
  install_if_changed "$src" "$PREFLIGHT" 0755 root:root
}

install_step() {
  find_device
  install_mount_point
  install_units
  install_drive_dirs
  install_preflight
}

# --- verify --------------------------------------------------------------------

# The install tier (PLAN §9c): the drive is mounted, wired and writable. Nothing
# about a writer or an update, and nothing here stops or starts a service, so it
# can never end a recording session.
verify() {
  find_device

  local fm src fstype opts kname procopts
  log "findmnt --mountpoint $MP (raw output follows)"
  findmnt --mountpoint "$MP" 2>&1 || true
  echo "----"
  fm=$(findmnt -nr -o SOURCE,FSTYPE,OPTIONS --mountpoint "$MP" | tail -n1) || true
  [[ -n $fm ]] || die "nothing is mounted at $MP; check: systemctl status '$MOUNT_UNIT'"
  read -r src fstype opts <<<"$fm"
  [[ $(realpath -- "$src") == "$(realpath -- "$DEV")" ]] \
    || die "$MP is mounted from $src, not from $DEV (label $LABEL)"
  [[ $fstype == ext4 ]] || die "$MP is $fstype, not ext4"
  [[ ,$opts, == *,rw,* ]] \
    || die "$MP is mounted read-only. errors=remount-ro trips on a filesystem error: check dmesg, then fsck the drive"
  [[ ,$opts, == *,noatime,* ]] \
    || die "$MP is mounted without noatime. If $UNIT_DIR/$MOUNT_UNIT has it, the live mount is stale: unmount and start the unit, or reboot"
  [[ ,$opts, != *,nobarrier,* ]] \
    || die "$MP is mounted nobarrier; the design needs barriers on (PLAN §9m). Remove it from the mount options"

  # The labeled filesystem mounted anywhere else too, for instance a desktop
  # auto-mount under /media. ⚠️ Unverified whether the Pi's image auto-mounts.
  local targets others
  targets=$(findmnt -nr -o TARGET --source "$DEV") || true
  log "findmnt --source $DEV: every mount of the drive (raw output follows)"
  printf '%s\n' "${targets:-(none)}"
  echo "----"
  others=$(grep -vxF -- "$MP" <<<"$targets") || true
  [[ -z $others ]] \
    || die "$DEV is also mounted at: $others. Unmount it there, and stop whatever mounted it (a desktop auto-mounter?)"

  # errors=remount-ro is checked as the kernel's mount option, the effect. ℹ️ It
  # is believed that ext4 lists errors= in findmnt only when it differs from the
  # superblock's default, and that /proc/fs/ext4/<dev>/options lists every
  # option in force, one per line. Either one counts.
  kname=$(basename "$(realpath -- "$DEV")")
  procopts=$(cat "/proc/fs/ext4/$kname/options" 2>/dev/null) || true
  if [[ -n $procopts ]]; then
    log "/proc/fs/ext4/$kname/options (raw output follows)"
    printf '%s\n' "$procopts"
    echo "----"
  fi
  if [[ ,$opts, == *,errors=remount-ro,* ]] || grep -qx 'errors=remount-ro' <<<"$procopts"; then
    pass "$MP is mounted from $DEV, ext4, rw, errors=remount-ro"
  else
    die "$MP is not mounted errors=remount-ro. Check Options= in $UNIT_DIR/$MOUNT_UNIT; if it is there, the live mount is stale: unmount and start the unit, or reboot"
  fi

  local en ac
  en=$(systemctl is-enabled "$MOUNT_UNIT" 2>&1) || true
  ac=$(systemctl is-active "$MOUNT_UNIT" 2>&1) || true
  log "systemctl is-enabled / is-active $MOUNT_UNIT (raw output follows)"
  printf '%s\n%s\n' "$en" "$ac"
  echo "----"
  [[ $en == enabled ]] || die "$MOUNT_UNIT is not enabled; run this step without --verify"
  [[ $ac == active ]] || die "$MOUNT_UNIT is not active; check: systemctl status '$MOUNT_UNIT'"
  pass "$MOUNT_UNIT is enabled and active"

  # ⚠️ PLAN §9m lists "tune2fs -l showing errors=remount-ro". The format
  #    commands do not set the superblock's error behavior, so that line is
  #    printed here and not judged; the mount option above is the effect.
  local t2 vol maxc
  t2=$(tune2fs -l "$DEV" 2>&1) || die "tune2fs -l $DEV failed: $t2"
  log "tune2fs -l $DEV (selected lines, raw)"
  grep -E '^(Filesystem volume name|Filesystem features|Maximum mount count|Errors behavior|Journal features|Journal checksum[^:]*):' <<<"$t2" || true
  echo "----"
  # PLAN §9m wants journal checksums. Judged as the kernel's mount option in
  # /proc/fs/ext4/<dev>/options (printed above), the effect, as errors= is.
  # tune2fs's "Journal features:" line, printed above, is not judged: on the
  # Pi, 2026-10-04, it read "none" while the kernel listed journal_checksum on a
  # metadata_csum filesystem. A warning, not a failure: it is a format choice.
  if [[ -z $procopts ]]; then
    warn "/proc/fs/ext4/$kname/options is unreadable, so journal checksums cannot be judged"
  elif ! grep -qx 'journal_checksum' <<<"$procopts"; then
    warn "the mount has no journal_checksum in /proc/fs/ext4/$kname/options; PLAN §9m wants journal checksums"
  fi
  vol=$(sed -nE 's/^Filesystem volume name:[[:space:]]*//p' <<<"$t2")
  maxc=$(sed -nE 's/^Maximum mount count:[[:space:]]*//p' <<<"$t2")
  [[ $vol == "$LABEL" ]] || die "the volume name is '$vol', not '$LABEL'"
  [[ $maxc == 1 ]] || die "Maximum mount count is $maxc, not 1. Run by hand: sudo tune2fs -c 1 $DEV (an fsck on every mount)"
  pass "tune2fs: volume name $LABEL, an fsck on every mount"

  # USB 2, by the drive's own link speed: walk up sysfs from the block device to
  # the USB device, the first ancestor with both speed and busnum.
  local sys speed
  sys=$(realpath -- "/sys/class/block/$kname")
  while [[ $sys == /sys/* && ! ( -f $sys/speed && -f $sys/busnum ) ]]; do
    sys=$(dirname "$sys")
  done
  [[ -f $sys/speed ]] || die "$DEV is not on USB (no USB device above /sys/class/block/$kname)"
  speed=$(<"$sys/speed")
  log "the drive's USB device: $sys, speed $speed (Mb/s)"
  if command -v lsusb >/dev/null; then
    log "lsusb -t (raw output follows)"
    lsusb -t 2>&1 || true
    echo "----"
  else
    warn "lsusb is not installed (usbutils); the sysfs speed above is the evidence"
  fi
  [[ $speed == 480 ]] || die "the drive's USB link is $speed Mb/s, not 480: move it to a black USB 2 port (PLAN §9m)"
  pass "the drive is on a 480 Mb/s (USB 2) link"

  local d out
  log "stat beast/ spool/ (raw output follows)"
  stat -c '%U:%G %a %n' "$MP/beast" "$MP/spool" 2>&1 || true
  echo "----"
  for d in beast spool; do
    out=$(stat -c '%U:%G %a' "$MP/$d" 2>/dev/null) || true
    [[ $out == "$USER_NAME:$GROUP_NAME 2770" ]] \
      || die "$MP/$d is '${out:-missing}', not $USER_NAME:$GROUP_NAME 2770; run this step without --verify"
  done
  pass "beast/ and spool/ are $USER_NAME:$GROUP_NAME 2770"

  # The readiness tier: 0 and 2 pass the install tier, 1 fails it (PLAN §9c, §9i).
  local rc=0
  [[ -x $PREFLIGHT ]] || die "$PREFLIGHT is not installed; run this step without --verify"
  log "$PREFLIGHT (raw output follows)"
  "$PREFLIGHT" || rc=$?
  echo "----"
  case $rc in
    0) pass "archive-preflight: ready (exit 0)" ;;
    2) warn "archive-preflight: not ready, for a reason outside the rig (exit 2); see its output above"
       pass "archive-preflight ran (exit 2 passes the install tier, PLAN §9c)" ;;
    *) die "archive-preflight could not run its check (exit $rc); see its output above" ;;
  esac

  log "journalctl -b -u 'systemd-fsck@*' --no-pager (raw output follows)"
  journalctl -b -u 'systemd-fsck@*' --no-pager 2>&1 || true
  echo "----"
  local fsck_log
  fsck_log=$(journalctl -b -q -u "$FSCK_UNIT" --no-pager 2>/dev/null) || true
  if [[ -n $fsck_log ]]; then
    pass "$FSCK_UNIT ran this boot"
  else
    warn "no run of $FSCK_UNIT in this boot's journal. That is the unverified fsck wiring in this file's header; check after a reboot"
  fi

  log "df -h $MP (raw output follows); archive.min_free_gb is $MIN_FREE_GB"
  df -h "$MP" 2>&1 || true
  echo "----"
  pass "the archive drive is installed"
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
