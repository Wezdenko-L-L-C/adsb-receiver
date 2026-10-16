#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The login banner, installed by setup/steps/50-updater.sh as /etc/update-motd.d/50-adsb-receiver.
# pam_motd runs /etc/update-motd.d at each SSH login, as root. Seen on mobile-adsb, 2026-10-04:
# /etc/pam.d/sshd line 33 has `pam_motd.so motd=/run/motd.dynamic` without noupdate, and
# /run/motd.dynamic was rewritten at an SSH login with 10-uname's output. As root, seen there
# 2026-10-15 (libpam-modules 1.7.0-5): pam_motd.so carries `run-parts --lsbsysinit
# /etc/update-motd.d > /run/motd.dynamic.new`, a redirect into root-owned /run, and
# /run/motd.dynamic (root:root 644) was rewritten at an SSH login. A code review of 2026-10-09
# had said it runs as the login; that was wrong. PLAN §9f, §9m.
# ⛔ It reads no station.yml, by choice: nothing from the config reaches a login's screen.
# ⛔ Being root, it opens no file by a name someone else could point elsewhere: writer.json, in the
#    writer's 2770 directory, and status.json are opened with O_NOFOLLOW and must be regular
#    files; the reboot flag is not read if it is a symlink (its directory is root's since
#    2026-10-15, lib.sh's ADSB_RUN_DIR, so none can be planted there).
# ⛔ Every value it prints passes through a filter first: each control character (C0, DEL and C1,
#    so every terminal escape sequence's introducer) becomes '?'. The files it reads are written by
#    root and the writer, but their values come from tools, drives and the radio.
#
# It reads and prints; it changes nothing, and it never fails a login: no `set -e`, every command
# guarded, and it always exits 0. A login waits for it, so every command that could hang
# (systemctl, lslocks, ps, python3) runs under a 5 s timeout of its own. What it shows:
#   - the last update run, from /var/lib/adsb-receiver/status.json (written last by update.sh),
#     including a rollback and what it could not undo (rollback.complete, leftovers_possible),
#     and, for a run inside a pull window, who opened it (opened_by: adsb-home-update or hand);
#   - on an incomplete first build (status.json says incomplete, and /opt/adsb-receiver/applied
#     does not exist), the two trap lines of PLAN §9e's 2026-10-05 (a): the pin, and the one
#     command out of it, with --role from status.json's role (only portable or stationary is
#     printed), or the generic sentence when it is neither. The ruled text reads the role from
#     station.yml, which this does not read (above); status.json's is the role update.sh read from it.
#     The ruled text
#     abbreviates the URL as "…/setup/bootstrap.sh"; the banner prints BUILD.md §8's whole URL, so
#     the line can be copied (the implementer's reading, not ruled);
#   - a needed reboot, with its reasons (/run/adsb-receiver/reboot-required);
#   - recording: who holds the recording lock, read from the holder's cgroup (not `ps -o unit=`),
#     when that process started (not when it took the lock: the writer may wait on the lock
#     first), and the writer's own state from writer.json;
#   - the preflights' verdicts as of that update run (not re-run here: a login must stay fast);
#   - the archive format refused on the first build, with the command to run by hand, until the
#     archive drive is mounted (status.json carries the first build's foundation record forward);
#   - the next scheduled update, and, where adsb-home-update.timer is loaded (🎒 portable), the
#     home-gated opener: bin/adsb-at-home's last verdict under its unit, at-home, not-at-home, off
#     (update.home_ssid not set) or cannot-tell, with when it was reached, from the world-readable
#     /run/adsb-home-update/home-update-state (it may have changed since; tmpfs, so none before the
#     first check after a boot), and the timer's next check. ⛔ Never the SSID.
# The one-run notes in status.json (such as the RTC charge-path line) are not shown here.
# ⚠️ Lines from status.json are printed as stored, but for the control-character filter above.
#    None carries a config value or a position today; nothing else here filters them.

# t <command...>: the command, stopped after 5 s (and killed 2 s later) if it hangs.
t() {
  if command -v timeout >/dev/null; then timeout -k 2 5 "$@"; else "$@"; fi
}

# clean <text>: the text with each control character replaced by '?': C0 and DEL byte by byte,
# and C1 (U+0080 to U+009F) as UTF-8 encodes it. Bytes, whatever the login's locale.
clean() {
  local LC_ALL=C s=$1
  s=${s//[[:cntrl:]]/?}
  s=${s//$'\xc2'[$'\x80'-$'\x9f']/?}
  printf '%s' "$s"
}

STATUS=/var/lib/adsb-receiver/status.json
WRITER_JSON=/var/lib/adsb-receiver/writer/writer.json
LOCK=/run/adsb-receiver/recording.lock
FLAG=/run/adsb-receiver/reboot-required
HOME_STATE=/run/adsb-home-update/home-update-state
APPLIED=/opt/adsb-receiver/applied

echo
echo "adsb-receiver on $(hostname 2>/dev/null)"

if [[ ! -e $STATUS ]]; then
  echo "  no update has run yet (no $STATUS)"
elif ! command -v python3 >/dev/null; then
  echo "  $STATUS exists, but python3 is missing, so it cannot be read"
else
  # Every line is built first and printed at the end, so a failure part-way prints none of them.
  archive_mounted=0
  t mountpoint -q /var/lib/adsb-receiver/archive 2>/dev/null && archive_mounted=1
  applied_exists=0
  [[ -e $APPLIED || -L $APPLIED ]] && applied_exists=1
  ARCHIVE_MOUNTED=$archive_mounted APPLIED_EXISTS=$applied_exists \
    t python3 - "$STATUS" <<'PY' 2>/dev/null || echo "  status.json: unreadable"
import json, os, re, stat, sys
# O_NOFOLLOW, and a regular file only (O_NONBLOCK, so a FIFO cannot hold the login).
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
if not stat.S_ISREG(os.fstat(fd).st_mode):
    sys.exit(1)
s = json.load(os.fdopen(fd))
out = []
rev = (s.get("applied_rev") or "")[:12] or "none"
out.append(f"  role {s.get('role')}, channel {s.get('channel')}; applied {rev}")
how = s.get("mode")
if s.get("trigger") == "window":
    how = f"{how}, in a pull window opened by {s.get('opened_by')}"
out.append(f"  last update: {s.get('result')} at {s.get('finished_at')} ({how})")
failed = s.get("failed_steps") or ([s["failed_step"]] if s.get("failed_step") else [])
if s.get("failed_steps"):
    out.append(f"  failed steps: {', '.join(s['failed_steps'])}")
elif s.get("failed_step"):
    out.append(f"  failed step: {s['failed_step']}")
# PLAN §9e's 2026-10-05 (a): the pin, and the one command out of it, until `applied` exists.
if s.get("result") == "incomplete" and os.environ.get("APPLIED_EXISTS") != "1":
    sha = (s.get("candidate_rev") or "")[:12] or "?"
    steps = ", ".join(failed) or "the failed steps"
    out.append(f"  first build: incomplete at {sha}; every home window retries this same commit (the pin)."
               " A step waiting for hardware completes once it is plugged in; a fix pushed to main does"
               " not reach a pinned build.")
    role = s.get("role")
    if role in ("portable", "stationary"):
        out.append(f"  if {steps} cannot pass at this commit, run the bootstrap again, one command (BUILD.md §8):"
                   " curl -fsSL https://raw.githubusercontent.com/Wezdenko-L-L-C/adsb-receiver/stable/setup/bootstrap.sh"
                   f" | sudo bash -s -- --role {role}")
    else:
        out.append(f"  if {steps} cannot pass at this commit, run the bootstrap again, one command:"
                   " BUILD.md §8 has the line for your rig's role")
rb = s.get("rollback")
if rb:
    out.append(f"  rollback: {rb.get('result')}" + (f" at {rb['failed_step']}" if rb.get("failed_step") else ""))
    if rb.get("complete") is False:
        # Information, not an alarm: a rollback re-runs the applied steps and never removes
        # what the candidate added; this says where to look if something new is left behind.
        left = rb.get("leftovers_possible") or []
        out.append("    note: a rollback does not remove what the candidate added"
                   + (f"; steps only in the candidate: {', '.join(left)}" if left else ""))
for name, r in (s.get("readiness") or {}).items():
    st = r.get("status") or r.get("exit")
    out.append(f"  {name}: {st}" + (f"  {r['line']}" if r.get("line") else ""))
found = s.get("foundation") or {}
fa = found.get("format_archive") or {}
if fa.get("result") in ("refused", "failed") and os.environ.get("ARCHIVE_MOUNTED") != "1":
    out.append(f"  ARCHIVE DRIVE NOT FORMATTED by the first build ({found.get('ran_at')}): {fa.get('reason')}")
    if fa.get("manual"):
        out.append(f"    by hand, after checking the device: {fa['manual']}")
if s.get("log"):
    out.append(f"  log: {s['log']}")
# The header's filter: C0, DEL and C1 become '?'.
print("\n".join(re.sub(r"[\x00-\x1f\x7f-\x9f]", "?", line) for line in out))
PY
fi

if [[ -s $FLAG && ! -L $FLAG ]]; then
  echo "  REBOOT REQUIRED:"
  while IFS= read -r reason || [[ -n $reason ]]; do
    printf '    %s\n' "$(clean "$reason")"
  done <"$FLAG" 2>/dev/null
elif [[ -e /run/reboot-required ]]; then
  echo "  REBOOT REQUIRED (by the system's packages)"
fi

pid=$(t lslocks -r -n -o PID,PATH 2>/dev/null | awk -v p="$LOCK" '$2 == p { print $1; exit }')
if [[ -n $pid ]]; then
  holder=$(sed -nE 's#^0::.*/([^/]+\.(service|scope))$#\1#p' "/proc/$pid/cgroup" 2>/dev/null | head -n1)
  started=$(t ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//')
  echo "  recording lock: held by $(clean "${holder:-PID $pid}") (process started $(clean "${started:-?}"))"
else
  echo "  recording lock: free (not recording)"
fi
if [[ -r $WRITER_JSON ]] && command -v python3 >/dev/null; then
  t python3 - "$WRITER_JSON" <<'PY' 2>/dev/null
import json, os, re, stat, sys
# Written by the writer in a directory its group may write: never followed (the header).
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
if not stat.S_ISREG(os.fstat(fd).st_mode):
    sys.exit(1)
w = json.load(os.fdopen(fd))
line = (f"  writer: {w.get('state')}, file {w.get('current_file')}, {w.get('frames_in_file')} frames"
        f" (as of {w.get('updated_at')})")
print(re.sub(r"[\x00-\x1f\x7f-\x9f]", "?", line))
PY
fi

next=$(t systemctl list-timers --no-pager --no-legend adsb-update.timer 2>/dev/null | awk 'NR == 1 { print $1, $2, $3, $4 }')
[[ -n $next ]] && echo "  next update: $next"
# The home-gated opener (🎒 portable, setup/steps/70): shown only where its timer is loaded.
if [[ $(t systemctl show -p LoadState --value adsb-home-update.timer 2>/dev/null) == loaded ]]; then
  hs=''
  [[ -r $HOME_STATE ]] && read -r hs hs_at <"$HOME_STATE" 2>/dev/null
  hs_at=$(clean "${hs_at:-}")
  case $hs in
    off) echo "  home update: off, update.home_ssid is not set (as of $hs_at; may have changed since)" ;;
    at-home|not-at-home) echo "  home update: on; last check: ${hs//-/ } (as of $hs_at; may have changed since)" ;;
    cannot-tell) echo "  home update: the last check could not tell (station.yml or nmcli unreadable; as of $hs_at)" ;;
    *) echo "  home update: not checked since this boot" ;;
  esac
  next=$(t systemctl list-timers --no-pager --no-legend adsb-home-update.timer 2>/dev/null | awk 'NR == 1 { print $1, $2, $3, $4 }')
  echo "  next home update check: ${next:-none scheduled (the timer is not started)}"
fi
echo
exit 0
