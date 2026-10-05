#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# setup/foundation/archive_candidates.py: which drive, if any, format-archive.sh may format.
# Pure functions over `lsblk -J` output, so the rule can be tested without a disk
# (tests/test_archive_candidates.py). format-archive.sh gathers the facts and does the formatting;
# this file only decides. Python 3 standard library only.
#
# The rule (PLAN §9m, the archive drive; the bootstrap's foundation tier):
#   - If any device already carries the archive label, format nothing: skip if it is ext4 (step 30
#     mounts it), refuse with the fix named if it is not (step 30 mounts only ext4).
#   - Otherwise a candidate is a whole disk that is TRAN=usb and RM=1; is not an mmcblk* or nvme*
#     device; is at least 8 GB; is not read-only; is not, and holds nothing that is, a mounted
#     filesystem or active swap; and holds no signature on any partition, or only a plain
#     filesystem that a read-only mount proves empty.
#   - Format only if exactly one candidate remains. Anything else is a refusal, with the manual
#     command to print.
#   - A filesystem the probe could not read (a mount failure, an ext* journal that needs recovery,
#     an unreadable directory, a .Trashes, lost+found or System Volume Information that is not a
#     plain directory, or anything in System Volume Information but the files Windows writes on a
#     fresh stick) refuses the whole run, not only that disk (PLAN §9e: "a signature it cannot read, or a mount failure: it
#     refuses loudly"). Only a filesystem that mounted and plainly holds files excludes its disk
#     and lets another be formatted.
# Stricter than the rule's letter, on purpose: a filesystem on the whole disk (no partition table),
# a partition table with no partition, more than one partition, or a lone partition that is not
# partition 1, are refusals too. format-archive.sh formats partition 1 and creates a table only on
# a disk that has none.
#
#   archive_candidates.py select --lsblk FILE --mounted FILE --label LABEL
#                                [--proven-empty /dev/sdX1]... [--not-empty /dev/sdX1]... [--final]
#       prints the decision as JSON
#   archive_candidates.py empty DIR
#       exit 0 empty, 3 holds files; any other exit (2 unreadable, 1 a crash) means "could not tell"
#   archive_candidates.py journal FILE
#       FILE is `dumpe2fs -h` output: exit 0 clean, 3 needs recovery, 2 unreadable
#   archive_candidates.py recheck --decision FILE --lsblk FILE --found TYPE [--identity-only]
#       just before formatting: the same disk (size, serial, PTUUID) and the signature decided on;
#       exit 0 agrees, 3 does not (the reason printed)

import argparse
import json
import os
import re
import sys

# "8 GB" as drive makers count it: 8 * 10^9 bytes. ⚠️ A stick sold as 8 GB is often a little under
# this, so it does not qualify; 16 GB and up do.
MIN_BYTES = 8_000_000_000
# Filesystems a read-only mount can prove empty. Anything else (LUKS, RAID or LVM members, swap,
# btrfs, xfs, an ISO image, ...) is a signature this rule will not overwrite.
PROBE_FSTYPES = {"vfat", "exfat", "ntfs", "ext2", "ext3", "ext4"}
# What a freshly bought or freshly formatted stick may hold and still count as empty.
EMPTY_ALLOWED = {"System Volume Information", ".Trashes", "lost+found"}
# Inside System Volume Information, what Windows writes on a removable drive it has seen: these
# regular files, and these directories, empty. Anything else there (a restore point, a file put
# there by hand) is not known to be nothing, so the probe fails closed on it.
SVI = "System Volume Information"
SVI_FILES = {"WPSettings.dat", "IndexerVolumeGuid", "tracking.log",
             "MountPointManagerRemoteDatabase"}
SVI_DIRS = {"ClientRecoveryPasswordRotation", "AadRecoveryPasswordDelete"}
# Exit codes of the `empty`, `journal` and `recheck` subcommands. Not 1: an uncaught exception
# exits 1, and that must read as "could not tell", never as an answer.
RC_YES, RC_UNKNOWN, RC_NO = 0, 2, 3


def as_bool(v):
    """lsblk -J prints RM and RO as JSON booleans (newer util-linux) or as "1"/"0" (older)."""
    if isinstance(v, bool):
        return v
    if v is None:
        return False
    return str(v).strip() in ("1", "true", "True")


def walk(node):
    """The node and everything below it."""
    yield node
    for child in node.get("children") or []:
        yield from walk(child)


def dev_path(node):
    return node.get("path") or "/dev/" + str(node.get("name", ""))


def dev_names(node):
    """Every name the node may appear under in findmnt or /proc/swaps, resolved."""
    names = {dev_path(node), "/dev/" + str(node.get("name", ""))}
    if node.get("kname"):
        names.add("/dev/" + node["kname"])
    return names


def mountpoints(node):
    mps = node.get("mountpoints")
    if mps is None:
        mps = [node.get("mountpoint")]
    return [m for m in mps if m]


def classify(disk, mounted, proven):
    """One whole disk: {"verdict": candidate|probe|rejected, "reason", "disk", "partition",
    "create_table", "wipe", "probe"}."""
    path = dev_path(disk)
    name = str(disk.get("name", ""))
    out = {"disk": path, "verdict": "rejected", "reason": "", "partition": None,
           "create_table": False, "wipe": False, "fstype": None, "probe": [], "near": False,
           "identity": identity(disk)}

    def reject(reason):
        out["reason"] = reason
        return out

    if name.startswith(("mmcblk", "nvme")):
        return reject("an SD card or NVMe device, never a candidate")
    tran = disk.get("tran") or ""
    if tran != "usb":
        return reject(f"not on USB (transport: {tran or 'none'})")
    if not as_bool(disk.get("rm")):
        return reject("not removable (RM=0)")
    for node in walk(disk):
        if mountpoints(node) or (dev_names(node) & mounted):
            return reject(f"{dev_path(node)} is mounted or is active swap")
    # USB, removable and unmounted: the drive the manual command most likely means.
    out["near"] = True
    if as_bool(disk.get("ro")):
        return reject("read-only")
    try:
        size = int(disk.get("size") or 0)
    except (TypeError, ValueError):
        return reject(f"size unreadable: {disk.get('size')!r}")
    if size < MIN_BYTES:
        return reject(f"{size} bytes, under {MIN_BYTES} (8 GB)")
    if disk.get("fstype"):
        return reject(f"a {disk['fstype']} signature on the whole disk, with no partition table")
    children = disk.get("children") or []
    for child in children:
        if child.get("type") != "part":
            return reject(f"{dev_path(child)} is a {child.get('type')}, not a partition")
        if child.get("children"):
            return reject(f"{dev_path(child)} is in use by another device (RAID, LVM or encryption)")
    if not children:
        if disk.get("pttype"):
            return reject(f"a {disk['pttype']} partition table with no partition")
        out.update(verdict="candidate", create_table=True,
                   reason="blank: no partition table and no signature")
        return out
    if len(children) != 1:
        return reject(f"{len(children)} partitions; only a disk with exactly one is formatted")
    part = children[0]
    ppath = dev_path(part)
    partn = part.get("partn")
    if partn is not None:
        try:
            is_one = int(partn) == 1
        except (TypeError, ValueError):
            is_one = False
    else:
        is_one = re.search(r"\D1$", ppath) is not None
    if not is_one:
        return reject(f"its only partition, {ppath}, is not partition 1")
    out["partition"] = ppath
    fstype = part.get("fstype")
    if not fstype:
        out.update(verdict="candidate", reason=f"{ppath} holds no signature")
        return out
    if fstype not in PROBE_FSTYPES:
        return reject(f"{ppath} holds {fstype}, which this rule never overwrites")
    if ppath in proven:
        # fstype goes into the decision: the last check before formatting compares it with what
        # blkid -p reads then.
        out.update(verdict="candidate", wipe=True, fstype=fstype,
                   reason=f"{ppath} holds {fstype}, proven empty by a read-only mount")
        return out
    out.update(verdict="probe", probe=[{"partition": ppath, "fstype": fstype}],
               reason=f"{ppath} holds {fstype}; empty only if a read-only mount shows it")
    return out


def identity(disk):
    """What must still be true of the disk when it is formatted: the same size, serial and
    partition-table UUID. A stick swapped for another under the same name fails this."""
    return {"size": str(disk.get("size")), "serial": disk.get("serial") or None,
            "ptuuid": disk.get("ptuuid") or None}


def manual_command(label, device):
    dev = device or "/dev/sdX1"
    return (f"sudo mkfs.ext4 -L {label} -m 0 {dev} && sudo tune2fs -c 1 {dev}"
            + ("" if device else "   (find the drive with: lsblk -o NAME,SIZE,TRAN,RM,FSTYPE,MODEL)"))


def select(doc, mounted, label, proven=(), final=False, not_empty=()):
    """The decision over a whole `lsblk -J` document:
    {"decision": skip|probe|format|refuse, "reason", "disk", "partition", "create_table", "wipe",
     "fstype", "identity", "probe", "considered", "manual"}.
    With final, every probed partition must be in proven or in not_empty: one in neither could
    not be read, and that refuses the whole run."""
    mounted = set(mounted)
    proven = set(proven)
    not_empty = set(not_empty)
    devices = doc.get("blockdevices") or []
    result = {"decision": "refuse", "reason": "", "disk": None, "partition": None,
              "create_table": False, "wipe": False, "fstype": None, "identity": None,
              "probe": [], "considered": [], "manual": manual_command(label, None)}
    for dev in devices:
        for node in walk(dev):
            if node.get("label") == label:
                path = dev_path(node)
                if node.get("fstype") != "ext4":
                    # The label marks a chosen drive: never formatted here. Step 30 mounts only
                    # ext4, so say what to do.
                    result.update(partition=path, manual=manual_command(label, path),
                                  reason=f"{path} carries the label {label} but is "
                                         f"{node.get('fstype') or 'of no known type'}, not ext4; "
                                         "a labeled drive is never formatted automatically. If "
                                         "it may be erased, format it as ext4 by hand; otherwise "
                                         "unplug it or remove its label")
                    return result
                result.update(decision="skip", disk=None, partition=path,
                              reason=f"{path} already carries the label {label}",
                              manual=None)
                return result
    verdicts = [classify(d, mounted, proven) for d in devices if d.get("type") == "disk"]
    unread = []
    if final:
        for v in verdicts:
            if v["verdict"] != "probe":
                continue
            v["verdict"] = "rejected"
            if all(p["partition"] in not_empty for p in v["probe"]):
                v["reason"] += "; it holds files"
            else:
                v["reason"] += "; it could not be read, so it is not known to be empty"
                unread.append(v["disk"])
    result["considered"] = [{k: v[k] for k in ("disk", "verdict", "reason")} for v in verdicts]
    near = [v for v in verdicts if v["near"]]
    if len(near) == 1:
        guess = near[0]["partition"] or (near[0]["disk"] + "1" if near[0]["create_table"] else None)
        result["manual"] = manual_command(label, guess)
    if unread:
        result["reason"] = (f"{', '.join(unread)} could not be read (a mount failure, a journal "
                            "that needs recovery, or an unreadable directory); PLAN §9e refuses the "
                            "whole run rather than format another drive")
        return result
    probes = [v for v in verdicts if v["verdict"] == "probe"]
    if probes:
        result.update(decision="probe", probe=[p for v in probes for p in v["probe"]],
                      reason="a filesystem must be proven empty before deciding")
        return result
    cands = [v for v in verdicts if v["verdict"] == "candidate"]
    if len(cands) == 1:
        c = cands[0]
        result.update(decision="format", disk=c["disk"], partition=c["partition"],
                      create_table=c["create_table"], wipe=c["wipe"], fstype=c["fstype"],
                      identity=c["identity"], reason=c["reason"],
                      manual=manual_command(label, c["partition"] or c["disk"] + "1"))
    elif not cands:
        result["reason"] = "no drive qualifies"
    else:
        result["reason"] = f"{len(cands)} drives qualify; formatting needs exactly one"
    return result


def empty_state(root):
    """("empty"|"not_empty"|"unknown", reason) for the filesystem mounted at root: empty only if
    it holds nothing but what a fresh stick may hold. Anything it cannot read, or a .Trashes or
    lost+found that is not a plain directory, or a System Volume Information that is not a plain
    directory holding only what Windows writes there, is "unknown": fail closed. Names of files
    found are never printed: they may be somebody's."""
    others = 0
    try:
        with os.scandir(root) as it:
            entries = list(it)
    except OSError as e:
        return "unknown", f"its root could not be listed ({e.strerror})"
    for entry in entries:
        if entry.name not in EMPTY_ALLOWED:
            others += 1
            continue
        try:
            plain_dir = entry.is_dir(follow_symlinks=False)
        except OSError as e:
            return "unknown", f"{entry.name} could not be read ({e.strerror})"
        if not plain_dir:
            return "unknown", f"{entry.name} is not a plain directory"
        if entry.name == SVI:
            why = svi_unknown(entry.path)
            if why:
                return "unknown", why
            continue
        errors = []
        for dp, dn, files in os.walk(entry.path, onerror=errors.append):
            if files or any(os.path.islink(os.path.join(dp, d)) for d in dn):
                return "not_empty", f"{entry.name} holds files"
        if errors:
            return "unknown", f"part of {entry.name} could not be read ({errors[0].strerror})"
    if others:
        return "not_empty", (f"holds {others} entr{'y' if others == 1 else 'ies'} besides "
                             f"{sorted(EMPTY_ALLOWED)}")
    return "empty", "holds nothing but what a fresh stick may hold"


def svi_unknown(path):
    """None if System Volume Information holds only what Windows writes there; else why not."""
    try:
        with os.scandir(path) as it:
            inside = list(it)
    except OSError as e:
        return f"{SVI} could not be listed ({e.strerror})"
    for e in inside:
        try:
            if e.name in SVI_FILES and e.is_file(follow_symlinks=False):
                continue
            if e.name in SVI_DIRS and e.is_dir(follow_symlinks=False):
                with os.scandir(e.path) as sub:
                    if next(sub, None) is None:
                        continue
        except OSError as err:
            return f"part of {SVI} could not be read ({err.strerror})"
        return f"{SVI} holds something besides what Windows writes there, so it is not known to be empty"
    return None


def journal_state(text):
    """("clean"|"needs_recovery"|"unknown", reason) from `dumpe2fs -h` output. A journal that
    needs recovery may hold directory entries a noload mount does not show, so such a filesystem
    can look empty when it is not."""
    feats = None
    for line in text.splitlines():
        if line.startswith("Filesystem features:"):
            feats = line.split(":", 1)[1].split()
    if feats is None:
        return "unknown", "dumpe2fs printed no feature list"
    if "needs_recovery" in feats:
        return "needs_recovery", "its journal needs recovery (it was not unmounted cleanly)"
    return "clean", "its journal needs no recovery"


def recheck(decision, fresh, found, identity_only=False):
    """None if, just before formatting, the disk is still the one decided on and blkid -p reads
    what was decided on; else why not. fresh is `lsblk -J -b -d -o PATH,SIZE,SERIAL,PTUUID` of the
    disk now; found is blkid -p's TYPE (or PTTYPE) now, "" for no signature."""
    disk = decision.get("disk")
    if decision.get("decision") != "format" or not disk:
        return "the decision is not to format"
    want_id = decision.get("identity") or {}
    devs = [d for d in (fresh.get("blockdevices") or []) if dev_path(d) == disk]
    if len(devs) != 1:
        return f"{disk} is no longer there"
    now_id = identity(devs[0])
    # identity_only: after sfdisk wrote a new table, the PTUUID has changed by design.
    keys = ("size", "serial") if identity_only else ("size", "serial", "ptuuid")
    for k in keys:
        if now_id.get(k) != want_id.get(k):
            return f"{disk}'s {k} is now {now_id.get(k)!r}, not {want_id.get(k)!r}: not the same disk"
    if identity_only:
        return None
    if decision.get("create_table"):
        target, want = disk, ""
    elif decision.get("wipe"):
        target, want = decision.get("partition"), decision.get("fstype") or ""
        if not want:
            return "the decision says wipe, but names no filesystem type to expect"
    else:
        target, want = decision.get("partition"), ""
    if found != want:
        return (f"blkid -p reads {found or 'no signature'!r} on {target}, not "
                f"{want or 'no signature'!r} as decided")
    return None


def main(argv):
    ap = argparse.ArgumentParser(prog="archive_candidates.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("select")
    s.add_argument("--lsblk", required=True, help="lsblk -J -b output")
    s.add_argument("--mounted", required=True,
                   help="resolved device paths of mount sources and active swap, one per line")
    s.add_argument("--label", required=True)
    s.add_argument("--proven-empty", action="append", default=[])
    s.add_argument("--not-empty", action="append", default=[])
    s.add_argument("--final", action="store_true")
    e = sub.add_parser("empty")
    e.add_argument("dir")
    j = sub.add_parser("journal")
    j.add_argument("file")
    r = sub.add_parser("recheck")
    r.add_argument("--decision", required=True)
    r.add_argument("--lsblk", required=True)
    r.add_argument("--found", required=True)
    r.add_argument("--identity-only", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "select":
        with open(a.lsblk) as fh:
            doc = json.load(fh)
        with open(a.mounted) as fh:
            mounted = {line.strip() for line in fh if line.strip()}
        print(json.dumps(select(doc, mounted, a.label, a.proven_empty, a.final, a.not_empty),
                         indent=1))
        return 0
    if a.cmd == "empty":
        state, why = empty_state(a.dir)
        print(why)
        return {"empty": RC_YES, "not_empty": RC_NO}.get(state, RC_UNKNOWN)
    if a.cmd == "journal":
        with open(a.file, errors="replace") as fh:
            state, why = journal_state(fh.read())
        print(why)
        return {"clean": RC_YES, "needs_recovery": RC_NO}.get(state, RC_UNKNOWN)
    with open(a.decision) as fh:
        decision = json.load(fh)
    with open(a.lsblk) as fh:
        fresh = json.load(fh)
    why = recheck(decision, fresh, a.found, a.identity_only)
    print(why or "agrees")
    return RC_NO if why else RC_YES


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
