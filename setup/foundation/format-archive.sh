#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# setup/foundation/format-archive.sh: format the portable rig's archive drive, on a first build,
# only when exactly one drive qualifies. PLAN §9m (the archive drive) and §9e, §9h (the foundation
# tier).
#
# ⛔ The one irreversible act in the build. It is foundation, not a step: no step runs mkfs (PLAN
#    §9m), because the steps run on every update, on remote rigs too. It formats only when
#    update.sh --bootstrap runs it (which sets ADSB_FOUNDATION=bootstrap in its environment) on a
#    portable's first build (no /opt/adsb-receiver/applied yet), a build a human started. Run any
#    other way it refuses, except --dry-run, which writes nothing and may be run by hand as root.
#    `--no-format` on the bootstrap stops it being called.
#
# The rule, decided by archive_candidates.py beside this file (tested without a disk in
# tests/test_archive_candidates.py; this script's --dry-run is run on stubbed tools in
# tests/test_format_archive_shell.py):
#   - a device already carrying archive.label: format nothing. If it is ext4, step 30 mounts it;
#     if it is not, this refuses and names the fix (format that device as ext4 by hand), because
#     the label says somebody chose that drive, and step 30 mounts only ext4;
#   - otherwise exactly one whole disk that is USB, removable (RM=1), not mmcblk*/nvme*, at least
#     8 GB, not read-only, not the parent of anything mounted or of active swap, and with no
#     signature on its one partition, or only a plain filesystem a read-only mount proves empty;
#   - a filesystem it could not read (a mount failure, an ext* journal that needs recovery, an
#     unreadable directory) refuses the whole run (PLAN §9e);
#   - anything else: refuse, change nothing, and report the manual command.
# Just before formatting (and in a dry run) it looks once more: lsblk and findmnt again (nothing
# on the disk is mounted or swap; the disk has the same size, serial and partition-table UUID),
# and blkid -p, a low-level probe of the device itself rather than udev's view, reads the
# signature that was decided on (its TYPE, or on a whole disk its PTTYPE; nothing else it prints,
# such as PART_ENTRY_*, counts). Any disagreement, or a tool that errs, refuses.
# Formats partition 1 as PLAN §9m says (mkfs.ext4 -L <label> -m 0, then tune2fs -c 1). Creates an
# MBR with one partition only on a disk with no partition table.
#
#   format-archive.sh [--dry-run] [--report FILE]
#     --dry-run      decide, probe with read-only mounts, run the last checks, and format nothing
#     --report FILE  write the outcome as JSON (update.sh puts it in status.json)
#   Exit: 0 formatted, skipped (an ext4 drive with the label is present) or a dry run that would
#   format; 2 refused (nothing was changed); 1 could not run, or failed after "FORMATTING" was
#   printed, including a last check that disagreed after sfdisk wrote the new partition table
#   (the report says result failed and names the part-way state).
#
# What has run on hardware: nothing. ⚠️ Unverified on the Pi: every command below this line.

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

DRY_RUN=0
REPORT=
while (($#)); do
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    --report) REPORT=${2:?--report needs a file}; shift ;;
    -h|--help) sed -n '3,44p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (usage: $0 [--dry-run] [--report FILE])" ;;
  esac
  shift
done

((EUID == 0)) || die "run as root (update.sh --bootstrap runs this on a portable's first build; by hand, only --dry-run)"
# The guard, not only a comment: a real run needs the bootstrap's marker and a rig with no build.
if ((DRY_RUN == 0)); then
  [[ ${ADSB_FOUNDATION:-} == bootstrap ]] \
    || die "only update.sh --bootstrap formats, on a portable's first build. By hand, run --dry-run, or format with the command step 30 prints"
  if [[ -e /opt/adsb-receiver/applied || -L /opt/adsb-receiver/applied ]]; then
    die "this rig has a build (/opt/adsb-receiver/applied exists): the archive drive is formatted only on a first build. Format by hand with the command step 30 prints"
  fi
fi

SELECT=$(dirname "${BASH_SOURCE[0]}")/archive_candidates.py
WORK=$(mktemp -d)
PROBE_MNT=$WORK/mnt
RESULT=failed REASON="it stopped before deciding" DEVICE='' MANUAL=''
PARTWAY=0          # 1 once sfdisk, wipefs or mkfs may have written to the disk
# Exit codes of archive_candidates.py's empty, journal and recheck: 0 yes, 3 no, else unknown.
RC_YES=0 RC_NO=3

# write_report: the outcome as JSON, for update.sh. Paths and the command only; no config value
# but the label, which the command needs.
write_report() {
  [[ -n $REPORT ]] || return 0
  python3 - "$REPORT" "$RESULT" "$REASON" "$DEVICE" "$MANUAL" <<'PY'
import json, os, sys
path, result, reason, device, manual = sys.argv[1:6]
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump({"result": result, "reason": reason, "device": device or None,
               "manual": manual or None}, fh)
    fh.write("\n")
os.replace(tmp, path)
PY
}

# cleanup: exit 2 means refused, nothing changed, and only refuse() exits 2; any other failure
# (a command that failed under set -e with its own code, 2 included) exits 1.
cleanup() {
  local rc=$?
  if mountpoint -q "$PROBE_MNT" 2>/dev/null; then
    umount "$PROBE_MNT" || warn "could not unmount the probe mount at $PROBE_MNT"
  fi
  write_report || warn "could not write the report to $REPORT"
  rm -rf "$WORK"
  if ((rc != 0)) && [[ $RESULT != refused ]]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT

# Portable only: the stationary rig's archive question is open (PLAN §9m).
require_role portable
LABEL=$(station_get archive.label) \
  || die "station.yml has no archive.label: add the archive: block from config/station.portable.example.yml"
[[ $LABEL =~ ^[A-Za-z0-9_-]{1,16}$ ]] \
  || die "archive.label '${LABEL}' must be 1-16 letters, digits, '-' or '_' (ext4's 16-byte limit)"
MANUAL="sudo mkfs.ext4 -L $LABEL -m 0 /dev/sdX1 && sudo tune2fs -c 1 /dev/sdX1"

for t in lsblk findmnt blkid mount umount mountpoint python3 sfdisk mkfs.ext4 tune2fs wipefs udevadm dumpe2fs realpath; do
  command -v "$t" >/dev/null || die "$t is not installed"
done

# jget <file> <key>: one top-level value of a JSON object ("" for null).
jget() {
  python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else ("true" if v is True else "false" if v is False else v))' "$1" "$2"
}

# refuse <reason>: change nothing, say so loudly with the manual command, exit 2. Once the disk
# may have been written (PARTWAY), it is a failure instead: exit 1, result failed, and a reason
# that says the disk is part-way, never "nothing changed".
refuse() {
  if ((PARTWAY)); then
    RESULT=failed REASON="PART-WAY: $disk was written to (sfdisk, wipefs or mkfs ran, or may have), and then: $1"
    warn "################################################################"
    warn "THE ARCHIVE DRIVE IS PART-WAY: $REASON."
    warn "The build continues without it. Check the device twice, then format it by hand:"
    warn "    $MANUAL"
    warn "################################################################"
    exit 1
  fi
  RESULT=refused REASON=$1
  warn "################################################################"
  warn "NOT FORMATTING THE ARCHIVE DRIVE: $REASON."
  warn "The build continues without it. Each drive's verdict is above."
  warn "To format it by hand, check the device twice, then run:"
  warn "    $MANUAL"
  warn "################################################################"
  exit 2
}

# mounted_sources <file>: every mount source and every active swap device, each also resolved to
# its kernel path. A btrfs source reads /dev/sdX2[/subvol]; the bracket is cut. findmnt's output
# is captured before it is read, and a findmnt or /proc/swaps that cannot be read refuses: an
# empty list would make every disk look unmounted.
mounted_sources() {
  local out swaps src
  out=$(findmnt -rn -o SOURCE) || refuse "findmnt failed, so what is mounted is unknown"
  swaps=$(awk 'NR > 1 { print $1 }' /proc/swaps) || refuse "/proc/swaps could not be read, so active swap is unknown"
  while IFS= read -r src; do
    src=${src%%\[*}
    [[ $src == /dev/* ]] || continue
    printf '%s\n%s\n' "$src" "$(realpath -m -- "$src")"
  done <<<"$out"$'\n'"$swaps" | sort -u >"$1"
}

# 1. A labeled filesystem anywhere: nothing to do. blkid probes the devices (-c /dev/null), as
#    step 30 does, in case udev's view (which lsblk reads) is stale. blkid exits 2 for "none
#    found"; any other failure refuses rather than reads as "no label".
labeled='' rc=0
labeled=$(blkid -c /dev/null -o device -t "LABEL=$LABEL" 2>"$WORK/blkid.err") || rc=$?
if ((rc != 0 && rc != 2)); then
  refuse "blkid failed (exit $rc) looking for the label $LABEL: $(tr '\n' ' ' <"$WORK/blkid.err")"
fi
if [[ -n $labeled ]]; then
  # The label marks a chosen drive: it is never formatted here. Step 30 mounts it only if it is
  # ext4, so a labeled drive of another type is refused with the fix named.
  while IFS= read -r dev; do
    [[ -n $dev ]] || continue
    ty=$(blkid -c /dev/null -o value -s TYPE "$dev" 2>/dev/null) || ty=''
    if [[ $ty != ext4 ]]; then
      MANUAL="sudo mkfs.ext4 -L $LABEL -m 0 $dev && sudo tune2fs -c 1 $dev" DEVICE=$dev
      refuse "$dev carries the label $LABEL but is ${ty:-of no type blkid reads}, not ext4. A labeled drive is never formatted automatically, and step 30 mounts only ext4. Fix: if that drive may be erased, format it as ext4 by hand (below); otherwise unplug it, or remove its label"
    fi
  done <<<"$labeled"
  RESULT=skipped REASON="already labeled $LABEL, ext4: $(tr '\n' ' ' <<<"$labeled")" MANUAL=
  log "$REASON; nothing to format"
  exit 0
fi

# 2. The facts. PARTN needs a recent util-linux; without it the selector reads the name.
log "lsblk -o NAME,SIZE,TRAN,RM,RO,FSTYPE,LABEL,MOUNTPOINTS,MODEL (raw output follows)"
lsblk -o NAME,SIZE,TRAN,RM,RO,FSTYPE,LABEL,MOUNTPOINTS,MODEL 2>&1 || true
echo "----"
# SERIAL and PTUUID are kept so the last check can tell the same disk from a swapped one.
cols=NAME,KNAME,PATH,TYPE,TRAN,RM,RO,SIZE,FSTYPE,LABEL,PTTYPE,PTUUID,SERIAL,MOUNTPOINTS
lsblk -J -b -o "$cols,PARTN" >"$WORK/lsblk.json" 2>/dev/null \
  || lsblk -J -b -o "$cols" >"$WORK/lsblk.json" \
  || refuse "lsblk -J failed"
mounted_sources "$WORK/mounted"

select_pass() {
  python3 "$SELECT" select --lsblk "$WORK/lsblk.json" --mounted "$WORK/mounted" --label "$LABEL" "$@"
}

select_pass >"$WORK/decision.json"
decision=$(jget "$WORK/decision.json" decision)

# 3. A plain filesystem on a lone partition counts as empty only if a read-only mount shows it.
#    ext* mount with noload, so a dirty journal is not replayed: nothing is written; and an ext*
#    whose journal needs recovery is not mounted at all, because entries still in the journal do
#    not show. Each partition ends up proven empty, holding files, or unread; an unread one
#    (listed in neither) refuses the whole run in the selector's final pass (PLAN §9e).
if [[ $decision == probe ]]; then
  verdicts=()
  mkdir -p "$PROBE_MNT"
  probe_list=$(python3 -c 'import json,sys; [print(p["partition"], p["fstype"], sep="\t") for p in json.load(open(sys.argv[1]))["probe"]]' "$WORK/decision.json") \
    || refuse "the selector's probe list could not be read"
  while IFS=$'\t' read -r p fs; do
    [[ -n $p ]] || continue
    opts=ro why=''
    if [[ $fs == ext[234] ]]; then
      opts=ro,noload
      rc=0
      dumpe2fs -h "$p" >"$WORK/dumpe2fs.txt" 2>/dev/null || rc=$?
      jrc=0
      why=$(python3 "$SELECT" journal "$WORK/dumpe2fs.txt") || jrc=$?
      if ((rc != 0 || jrc != RC_YES)); then
        warn "$p ($fs) is not probed: ${why:-dumpe2fs failed} (dumpe2fs exit $rc), so it is not known to be empty"
        continue
      fi
    fi
    types=("$fs")
    [[ $fs == ntfs ]] && types=(ntfs3 ntfs)
    mounted_ok=0
    for ty in "${types[@]}"; do
      if mount -t "$ty" -o "$opts" "$p" "$PROBE_MNT" 2>"$WORK/mount.err"; then
        mounted_ok=1
        break
      fi
    done
    if ((mounted_ok == 0)); then
      warn "$p ($fs) did not mount read-only, so it is not known to be empty: $(tr '\n' ' ' <"$WORK/mount.err")"
      continue
    fi
    erc=0
    why=$(python3 "$SELECT" empty "$PROBE_MNT") || erc=$?
    case $erc in
      "$RC_YES") log "$p ($fs) is empty: $why"; verdicts+=(--proven-empty "$p") ;;
      "$RC_NO")  log "$p ($fs) holds files: $why"; verdicts+=(--not-empty "$p") ;;
      *)         warn "$p ($fs) could not be read (exit $erc): ${why:-no reason printed}" ;;
    esac
    umount "$PROBE_MNT" || refuse "could not unmount the probe mount of $p at $PROBE_MNT"
  done <<<"$probe_list"
  select_pass --final "${verdicts[@]}" >"$WORK/decision.json"
  decision=$(jget "$WORK/decision.json" decision)
fi

log "the selector's decision (raw output follows)"
cat "$WORK/decision.json"
echo "----"
MANUAL=$(jget "$WORK/decision.json" manual)
REASON=$(jget "$WORK/decision.json" reason)

case $decision in
  skip)
    RESULT=skipped MANUAL=
    log "$REASON; nothing to format"
    exit 0 ;;
  format) ;;
  *) refuse "$REASON" ;;
esac

disk=$(jget "$WORK/decision.json" disk)
part=$(jget "$WORK/decision.json" partition)
create_table=$(jget "$WORK/decision.json" create_table)
wipe=$(jget "$WORK/decision.json" wipe)
DEVICE=${part:-${disk}1}

# signature_now <device>: blkid -p's TYPE (or, on a whole disk, PTTYPE) now; "" for none. Only
# those two tags are asked for and read: on a partition, blkid -p also prints PART_ENTRY_* lines
# (the partition table's entry for it), which say nothing about a signature on it. blkid exits 2
# when it finds nothing; any other failure returns 1 (the caller refuses) rather than reads as
# "nothing". Runs in $(...), so it never calls refuse itself.
signature_now() {
  local out rc=0 found
  out=$(blkid -p -o export -s TYPE -s PTTYPE "$1" 2>"$WORK/blkid.err") || rc=$?
  if ((rc == 2)) && [[ ! -s $WORK/blkid.err ]]; then
    return 0
  fi
  if ((rc != 0)); then
    printf 'blkid -p %s failed (exit %s): %s' "$1" "$rc" "$(tr '\n' ' ' <"$WORK/blkid.err")"
    return 1
  fi
  printf 'blkid -p %s (raw): %s\n' "$1" "$(tr '\n' ' ' <<<"$out")" >&2
  found=$(sed -n 's/^TYPE=//p' <<<"$out" | head -n1)
  [[ -n $found ]] || found=$(sed -n 's/^PTTYPE=//p' <<<"$out" | head -n1)
  printf '%s' "$found"
}

# recheck [--identity-only]: the selected disk, looked at once more just before acting. Nothing on
# it is mounted or swap now; its size, serial and (unless --identity-only, after sfdisk) PTUUID
# match what was decided on; and blkid -p reads the signature decided on.
recheck() {
  local found='' rc=0 why target
  mounted_sources "$WORK/mounted.now"
  if grep -qE "^${disk}([0-9]|p[0-9]|\$)" "$WORK/mounted.now"; then
    refuse "$disk, or a partition on it, is mounted or swap now"
  fi
  lsblk -J -b -d -o PATH,SIZE,SERIAL,PTUUID "$disk" >"$WORK/lsblk.now.json" \
    || refuse "lsblk could not read $disk now"
  if [[ ${1:-} != --identity-only ]]; then
    target=$part
    [[ $create_table == true ]] && target=$disk
    found=$(signature_now "$target") || refuse "${found:-blkid -p $target failed}"
  fi
  why=$(python3 "$SELECT" recheck --decision "$WORK/decision.json" --lsblk "$WORK/lsblk.now.json" \
          --found "$found" "$@") || rc=$?
  ((rc == RC_YES)) || refuse "the last check before formatting disagrees: ${why:-recheck exit $rc}"
  log "the last check agrees: $why"
}

# 4. Just before acting, the facts once more (also in a dry run: everything here only reads).
recheck

if ((DRY_RUN)); then
  RESULT=dry_run
  log "dry run: would format $DEVICE on $disk (new partition table: $create_table; wipe a proven-empty filesystem first: $wipe). Nothing was changed."
  exit 0
fi

log "FORMATTING $DEVICE as ext4, label $LABEL (PLAN §9m). $REASON"
# From here a failure leaves the disk part-way; the report says so, whatever stops the script.
PARTWAY=1
RESULT=failed REASON="stopped part-way through formatting $DEVICE on $disk (the selector had said: $REASON); the disk may hold a new partition table or a partial filesystem. Read this run's foundation-format-archive.log, check the device, and format it by hand"
if [[ $create_table == true ]]; then
  # An MBR with one Linux partition over the whole disk.
  run sfdisk --quiet "$disk" <<<$'label: dos\ntype=83'
  run udevadm settle
  part=
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    part=$(lsblk -nr -o PATH,TYPE "$disk" | awk '$2 == "part" { print $1; exit }') || true
    [[ -n $part && -b $part ]] && break
    sleep 1
  done
  [[ -n $part && -b $part ]] || refuse "sfdisk wrote a table on $disk, but no partition device appeared"
  DEVICE=$part
  # The table is new, so its PTUUID is too; size and serial still name the same disk.
  recheck --identity-only
fi
if [[ $wipe == true ]]; then
  # The proven-empty filesystem's signature, so mkfs need not ask and blkid sees one filesystem.
  run wipefs -a "$part"
fi
# stdin from /dev/null: if mke2fs still asks to proceed, end of input is a no.
run mkfs.ext4 -L "$LABEL" -m 0 "$part" </dev/null
run tune2fs -c 1 "$part"
run udevadm settle
got=$(blkid -c /dev/null -o device -t "LABEL=$LABEL" 2>/dev/null) || true
[[ $got == "$part" ]] || refuse "formatted $part, but blkid finds the label $LABEL on '${got:-nothing}'"
RESULT=formatted REASON="formatted $part as ext4, label $LABEL" MANUAL=
pass "$REASON; step 30 mounts it"
