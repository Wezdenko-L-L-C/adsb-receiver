#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 80-portable-slate: the field display. Installs bin/adsb-slate and its unit,
# adsb-slate.service, which draws the camera slate on tty1, the Pi's HDMI
# console: UTC to tenths in large digits, the date, local time and zone,
# chrony's sync state in words, gpsd's fix, satellites, fix age and position,
# and the aircraft count. PLAN §5, "Update 2026-10-10: the interface, ruled
# (#30)", ruling 1, and "The one position source, and the surface rule".
# Ruling 3 (the panel's power from the battery bank) is a hardware ruling this
# step does not touch. BUILD.md has no section for it yet.
#
# Portable only: asserts station.role and refuses a position: block (PLAN §9b).
# Beyond those two checks it reads no station.yml key, and it adds none.
#
#   setup/steps/80-portable-slate.sh            install, then verify
#   setup/steps/80-portable-slate.sh --verify   verify only
#
# What it installs:
#   - bin/adsb-slate -> /usr/local/bin/adsb-slate, root:root 0755. Copied, not
#     symlinked: update.sh flips between two worktrees (PLAN §9f).
#   - /etc/systemd/system/adsb-slate.service, enabled and started. Restarted
#     only when the binary or the unit changed (PLAN §9f).
#   No packages. setfont (kbd), the Terminus console fonts, chronyc and python3
#   were seen on the 🎒 portable 2026-10-10, read-only (PLAN §5, ruling 1), and
#   setfont is /usr/bin/setfont there (/bin is usrmerged). This step checks for
#   them and dies if one is missing.
#
# tty1 and getty: the unit has Conflicts=getty@tty1.service, so starting it
# stops the login prompt on tty1, and only there. getty@tty1 is enabled (seen
# on the 🎒 portable 2026-10-10, read-only). At boot both are only wanted, and
# systemd.unit(5) says that then "the unit that conflicts will be started and
# the unit that is conflicted is stopped" (read in the man page, systemd 259 on
# a workstation, 2026-10-10; the portable runs 257), so the slate wins tty1 at
# boot. ⚠️ Belief, not read: logind's autovt does not start getty on tty1
# while the slate holds it open (logind spawns autovt only on a VT that is not
# in use). If it did, getty would stop the slate, and Restart= would not bring
# it back (a stop is not a failure).
# ⚠️ Stopping the slate by hand (systemctl stop adsb-slate) does NOT bring back
# the login on tty1: nothing restarts getty@tty1 until the next boot or
# `sudo systemctl start getty@tty1`. Logins on tty2 and up remain: logind's
# autovt starts getty there when the console is switched to (belief, from
# logind's documented NAutoVTs default; not read here).
#
# The panel: seen on the 🎒 portable 2026-10-10, read-only, with no panel
# attached: both HDMI connectors read disconnected, there is no
# /sys/class/graphics/fb0, and /dev/vcs1 and /dev/vcsu1 exist (root:tty 0660).
# ⚠️ Belief, not seen: DRM's fbdev setup is deferred to the first hotplug, and
# fbcon then takes tty1 over at the panel's mode with its default font.
# With no framebuffer tty1 is an 80x25 console and its screen buffer (what
# /dev/vcs1 reads) is written: recorded by Chris on the 🎒 portable 2026-10-10
# (sudo cat /dev/vcs1, no panel): 80x25 (`stty -F /dev/tty1 size`), the
# buffer is written (it held getty's prompt); to be recorded in PLAN §5 with
# this step. ⚠️ That was getty's output. The renderer's writes under this
# unit take the same path as getty's, but are not yet seen for the slate
# itself; this step's verify, reading the same buffer, is what will show it.
# At 80x25 the slate's layout is: big digits one cell per unit, 47 columns by
# 7 rows, from column 17 (1-based), rows 2 to 8; the UTC line on row 10; the
# five status lines on rows 11 to 15; rows 16 to 25 empty (tests/test_adsb_slate.py
# checks the width at 80 columns).
# ⚠️ Belief, not seen: setfont fails with no framebuffer. Its ExecStartPre= is
# "-" (a failure ignored) either way. The renderer exits when the console's
# size changes (--exit-on-resize), and Restart= re-runs setfont, so a panel
# plugged in after boot gets the font.
#
# ⛔ The position goes to the screen only (PLAN §5, the surface rule). This
#    step's verify reads the screen as root and prints exactly two things from
#    it: the "UTC ..." line and the clock state's first word. Never the dump:
#    it holds the exact position, and step output goes into update.sh's logs.
#
# What has run on hardware is recorded in PLAN, not here (PLAN §9c: no script
# carries a "tested on" header).

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"
require_role portable
require_absent position

for t in python3 systemctl systemd-analyze cmp; do
  command -v "$t" >/dev/null || die "$t is not installed"
done
# A fixed path, never `command -v`: the rendered unit must not vary with the
# caller's PATH.
SETFONT=/usr/bin/setfont
[[ -x $SETFONT ]] || die "$SETFONT is missing (package kbd). It was seen on the portable on 2026-10-10; install kbd with apt, then re-run this step"
command -v chronyc >/dev/null \
  || die "chronyc is not installed: run setup/steps/20-portable-clock.sh first (the slate shows chrony's state)"

SRC=$ADSB_REPO/bin/adsb-slate
SLATE=/usr/local/bin/adsb-slate
UNIT=adsb-slate.service
UNIT_FILE=/etc/systemd/system/$UNIT
TTY=/dev/tty1
VT_NAME=tty1
GETTY=getty@tty1.service

# Terminus 32x16: 120 columns by 33 rows on the 1920x1080 panel. The slate
# prints ASCII only and draws its digits as reverse-video spaces, so any
# character set of the face will do. The order is fixed, and the first that
# exists is used. All three were seen in /usr/share/consolefonts on the 🎒
# portable 2026-10-10, read-only, so there the choice is Uni2's.
FONT_DIR=/usr/share/consolefonts
FONT_PREFERRED=(Uni2-Terminus32x16.psf.gz Lat15-Terminus32x16.psf.gz Uni3-Terminus32x16.psf.gz)
FONT=''
for f in "${FONT_PREFERRED[@]}"; do
  if [[ -f $FONT_DIR/$f ]]; then FONT=$FONT_DIR/$f; break; fi
done
[[ -n $FONT ]] || die "none of ${FONT_PREFERRED[*]} is in $FONT_DIR. They come with console-setup-linux; install it with apt, then re-run this step"

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

# The unit. What each line is for:
#   - StandardOutput=tty on TTYPath=: the console is the renderer's stdout.
#     StandardInput=null: systemd.exec(5), read 2026-10-10: "If the TTY is used
#     for output only, the executed process will not become the controlling
#     process of the terminal, and will not fail or wait for other processes
#     to release the terminal." So a keyboard's Ctrl-C reaches nothing, and the
#     renderer turns echo off itself.
#   - ⚠️ Belief, not read in systemd.exec(5): systemd opens TTYPath= in the
#     forked child before it drops to the dynamic user, which is how an
#     unprivileged process gets /dev/tty1, which is crw------- root:tty (seen
#     on the 🎒 portable 2026-10-10, read-only). The verify checks the effect:
#     the renderer runs unprivileged, and its line is on tty1's screen.
#   - TTYVTDisallocate=yes: systemd.exec(5) says it deallocates or clears the
#     terminal "before and after execution". ⚠️ Belief, not seen: "after"
#     includes a renderer killed by SIGKILL, so a frozen clock is not left on
#     the panel. The renderer clears the screen itself on a clean exit.
#   - LimitCORE=0: the process holds the exact position, and a core file would
#     carry it to disk. (Seen on the 🎒 portable 2026-10-10, read-only: no
#     systemd-coredump package, and core_pattern is `core`, a file in the
#     working directory.)
#   - "-+" on setfont: "+" runs it as root, outside the sandbox (systemd.service(5));
#     "-" ignores its failure, which is believed, not seen, to be what happens
#     with no framebuffer.
#   - DynamicUser=yes implies NoNewPrivileges=, RestrictSUIDSGID=,
#     ProtectSystem=strict and ProtectHome=read-only (systemd.exec(5)); they
#     are written out anyway, ProtectHome= tightened to yes.
#   - Not set, deliberately: PrivateDevices=, DevicePolicy= and ProtectClock=
#     (which implies DeviceAllow=, systemd.exec(5)). Each could stop systemd
#     opening /dev/tty1 for the renderer; untested, so left out.
#   - IPAddressDeny=any with IPAddressAllow=localhost: gpsd is on loopback
#     (PLAN §5, the one position source), and the renderer has no reason to
#     reach anything else. ⚠️ Belief, not read: chronyc reaches chronyd over
#     its Unix socket or UDP to 127.0.0.1:323 (Debian's default command port),
#     both allowed here. The running kernel has CONFIG_CGROUP_BPF=y and
#     CONFIG_BPF_SYSCALL=y (seen on the 🎒 portable 2026-10-10, read-only),
#     which this filter needs.
#   - SystemCallFilter=@system-service: the renderer's TIOCGWINSZ and termios
#     calls are ioctl, which `systemd-analyze syscall-filter @system-service`
#     lists (seen on the 🎒 portable 2026-10-10, read-only).
#   - StartLimitIntervalSec=0: an exit on a resize, or a crash, always restarts.
render_unit() {
  cat >"$WORK/unit" <<EOF
# Rendered by setup/steps/80-portable-slate.sh. Do not edit; re-run the step.
# The field display (PLAN §5, "the interface, ruled (#30)", ruling 1).
[Unit]
Description=adsb-receiver field slate on $VT_NAME (UTC, clock, GPS, aircraft)
# Takes $VT_NAME from the login prompt; other consoles keep theirs.
Conflicts=$GETTY
After=$GETTY
# Ordering only; nothing here pulls these in. Each missing source is a word on
# the screen.
After=chrony.service gpsd.socket readsb.service
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=-+$SETFONT -C $TTY $FONT
ExecStart=$SLATE --exit-on-resize
Restart=always
RestartSec=2s
StandardInput=null
StandardOutput=tty
StandardError=journal
TTYPath=$TTY
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
DynamicUser=yes
NoNewPrivileges=yes
RestrictSUIDSGID=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
UMask=0077
LimitCORE=0
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
IPAddressDeny=any
IPAddressAllow=localhost
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
EOF
}

install_step() {
  [[ -f $SRC ]] || die "$SRC is missing from this checkout"
  [[ -c $TTY ]] || die "$TTY is not a character device: this kernel has no virtual consoles, so there is nowhere to draw the slate. Check: ls -l /dev/tty1"
  log "console font: $FONT"

  local bin_changed unit_changed state
  install_if_changed "$SRC" "$SLATE" 0755 root:root
  bin_changed=$CHANGED
  render_unit
  install_if_changed "$WORK/unit" "$UNIT_FILE" 0644 root:root
  unit_changed=$CHANGED
  if ((unit_changed)); then
    run systemctl daemon-reload
  fi
  if ! systemctl is-enabled --quiet "$UNIT"; then
    unit enable "$UNIT"
  fi

  state=$(systemctl show -p ActiveState --value "$UNIT" 2>/dev/null) || state=''
  case $state in
    active|activating|reloading|refreshing)
      if ((bin_changed || unit_changed)); then
        log "$UNIT is $state and its binary or unit changed: restarting it"
        guard_unit "$UNIT"
        run systemctl --no-block restart "$UNIT"
      else
        log "$UNIT is $state and unchanged; left as it is"
      fi
      ;;
    *)
      log "$UNIT is ${state:-unknown}: starting it. That stops $GETTY (Conflicts=); getty on tty2 and up is untouched"
      guard_unit "$UNIT"
      run systemctl --no-block start "$UNIT"
      ;;
  esac
}

# --- verify --------------------------------------------------------------------

# settle <seconds>: waits until no job is queued for the unit and it is active
# and running, polling once a second. The job check covers the moment after
# install's `restart --no-block`, before the old process has gone: MainPID read
# then could be the old renderer's. Sets U_ACTIVE, U_SUB and U_JOB; returns 1
# if it has not settled by then.
U_ACTIVE='' U_SUB='' U_JOB=''
settle() {
  local secs=$1 s i=0
  while :; do
    s=$(systemctl show -p ActiveState,SubState "$UNIT" 2>/dev/null) || true
    U_ACTIVE=$(sed -n 's/^ActiveState=//p' <<<"$s")
    U_SUB=$(sed -n 's/^SubState=//p' <<<"$s")
    U_JOB=$(systemctl list-jobs --no-legend "$UNIT" 2>/dev/null | awk '{ printf "%s%s/%s", sep, $3, $4; sep = " " }') || true
    [[ -z $U_JOB && $U_ACTIVE == active && $U_SUB == running ]] && return 0
    ((i++ < secs)) || return 1
    sleep 1
  done
}

# read_screen: reads tty1's screen as root, twice, about 1.2 s apart, and
# prints ONLY the "UTC ..." line, the system clock at each read and the clock
# state's first word. ⛔ Never the dump: it holds the exact position. Any error
# is printed as its type name only. Exit 0 if the line is within 2 s of the
# system clock both times and advances; otherwise 1, with the reason.
read_screen() {
  python3 - <<'PY'
import calendar, re, sys, time

UTC = re.compile(r"UTC (\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d)")
WORD = re.compile(r"CLOCK (SYNCED|COARSE|HOLDOVER|UNSYNCED|CHRONY\?)")
ENC = "utf-32-le" if sys.byteorder == "little" else "utf-32-be"
# vcsu1 is tty1's screen as one 32-bit code point per cell; vcs1, the older
# interface, one byte per cell. Neither has line breaks.
DEVICES = (("/dev/vcsu1", ENC), ("/dev/vcs1", "latin-1"))


def read():
    err = "none"
    for path, enc in DEVICES:
        try:
            with open(path, "rb") as fh:
                return path, fh.read().decode(enc, "replace")
        except OSError as e:
            err = type(e).__name__
    print(f"could not read /dev/vcsu1 or /dev/vcs1 ({err})")
    sys.exit(1)


def sample():
    # Up to 5 s for a renderer that has just started to draw its first frame.
    deadline = time.monotonic() + 5
    while True:
        t0 = time.time()
        path, text = read()
        t1 = time.time()
        found = UTC.findall(text)
        if len(found) == 1 or time.monotonic() > deadline:
            break
        time.sleep(0.5)
    if len(found) != 1:
        print(f"{path}: {len(found)} 'UTC YYYY-MM-DD HH:MM:SS.t' lines on the screen, not 1")
        sys.exit(1)
    y, mo, d, h, mi, s, t = (int(x) for x in found[0])
    shown = calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0)) + t / 10
    mid = (t0 + t1) / 2
    w = WORD.findall(text)
    line = f"UTC {y:04d}-{mo:02d}-{d:02d} {h:02d}:{mi:02d}:{s:02d}.{t}"
    sysclk = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(mid)) + f".{int(mid * 1000) % 1000:03d}"
    print(f"{path}: screen '{line}'; system clock at the read {sysclk} UTC; screen minus system {shown - mid:+.2f} s")
    return shown, mid, (w[0] if len(w) == 1 else "?")


a, ma, word = sample()
time.sleep(1.2)
b, mb, word = sample()
print(f"clock state on the screen: {word}")
bad = [x for x in ((a, ma), (b, mb)) if abs(x[0] - x[1]) > 2]
if bad:
    print("the screen's UTC line is more than 2 s from the system clock")
    sys.exit(1)
if not b > a:
    print("the screen's UTC line did not advance in 1.2 s")
    sys.exit(1)
PY
}

# Checked here (PLAN §9c, the observable effect): the renderer is the unit's
# main process, unprivileged, and its UTC line is on tty1's screen, near the
# system clock and advancing. With no panel, tty1's buffer is still written:
# recorded by Chris on the 🎒 portable 2026-10-10 (sudo cat /dev/vcs1, no
# panel): 80x25, the buffer is written; to be recorded in PLAN §5 with this
# step. That was getty's output; the renderer's takes the same path, not yet
# seen for the slate itself. ⛔ Never judged: chrony's state or a GPS fix
# (readiness, PLAN §9c), and whether a panel is attached: none of them can be
# fixed by an update, and a failed verify under update.sh rolls the whole
# update back (setup/update.sh, rollback).
verify() {
  local out ver rc
  log "stat $SLATE; $SLATE --version (raw output follows)"
  stat -c '%U:%G %a %n' "$SLATE" 2>&1 || true
  ver=$("$SLATE" --version 2>&1) || true
  printf '%s\n' "$ver"
  echo "----"
  [[ -f $SLATE ]] || die "$SLATE is not installed; run this step without --verify"
  [[ $(stat -c '%U:%G %a' "$SLATE") == "root:root 755" ]] || die "$SLATE is not root:root 0755; run this step without --verify"
  cmp -s "$SRC" "$SLATE" || die "$SLATE differs from $SRC; run this step without --verify"
  [[ $ver == "adsb-slate "* ]] || die "$SLATE --version did not run; is python3 intact? (see above)"
  pass "$SLATE is this checkout's, and runs: $ver"

  render_unit
  cmp -s "$WORK/unit" "$UNIT_FILE" || die "$UNIT_FILE is missing or differs from the rendered unit; run this step without --verify"
  log "systemd-analyze verify $UNIT_FILE (raw output follows)"
  rc=0
  out=$(systemd-analyze verify "$UNIT_FILE" 2>&1) || rc=$?
  printf '%s\n' "${out:-(no output)}"
  echo "----"
  ((rc == 0)) || die "systemd-analyze verify rejected $UNIT_FILE (exit $rc); see above"
  pass "$UNIT_FILE matches the rendered unit and loads"

  local en
  en=$(systemctl is-enabled "$UNIT" 2>&1) || true
  [[ $en == enabled ]] || die "$UNIT is '$en', not enabled; run this step without --verify"

  # A renderer whose PID changes during the checks below is retried once,
  # after settling again: an exit on a console resize (a panel plugged in
  # during an update) does exactly that, and a failed verify rolls the whole
  # update back. Only a second change fails: a renderer that keeps dying.
  local attempt rc2
  for attempt in 1 2; do
    rc2=0
    check_renderer || rc2=$?
    ((rc2 == 0)) && return 0
    if ((attempt == 1)); then
      warn "$UNIT's renderer restarted during the checks (a resize exit does this once, e.g. a panel plugged in); settling and checking once more"
    fi
  done
  die "$UNIT's renderer restarted during the checks twice running: it keeps dying. Check: journalctl -u $UNIT -n 50 (it logs error types only, never the position); then re-run: setup/steps/80-portable-slate.sh --verify"
}

# check_renderer: settles the unit, then checks its main process and tty1's
# screen. Returns 0 if all pass, 10 if the main process changed or vanished
# while it checked (the caller retries once); dies on anything else.
check_renderer() {
  local settled=1 show
  settle 20 || settled=0
  # MainPID is read only now, after the unit has settled with no job queued.
  # NRestarts is printed, not judged: the renderer exits on every console
  # resize (a panel plugged in) and Restart= brings it back, so restarts are
  # expected. A renderer that keeps dying is caught instead by its PID
  # changing while this checks it, twice (verify).
  log "systemctl show $UNIT (raw output follows)"
  show=$(systemctl show -p ActiveState,SubState,Result,NRestarts,MainPID,ExecMainStatus "$UNIT" 2>&1) || true
  printf '%s\n' "$show"
  echo "----"
  if ((settled == 0)); then
    die "$UNIT has not settled to active and running with no job queued after 20 s (ActiveState=$U_ACTIVE SubState=$U_SUB${U_JOB:+ job $U_JOB}). Check: journalctl -u $UNIT -n 50 (it logs error types only, never the position); then re-run this step"
  fi
  pass "$UNIT is active and running"

  # The main process is the renderer, unprivileged, with NoNewPrivs.
  local mpid cmd uid nnp
  mpid=$(sed -n 's/^MainPID=//p' <<<"$show")
  [[ $mpid =~ ^[1-9][0-9]*$ && -r /proc/$mpid/cmdline ]] \
    || die "$UNIT has no main process to read (MainPID=${mpid:-?}); check: journalctl -u $UNIT -n 50, then re-run this step"
  cmd=$(tr '\0' ' ' <"/proc/$mpid/cmdline" 2>/dev/null) || cmd=''
  uid=$(awk '$1 == "Uid:" { print $2 }' "/proc/$mpid/status" 2>/dev/null) || uid=''
  nnp=$(awk '$1 == "NoNewPrivs:" { print $2 }' "/proc/$mpid/status" 2>/dev/null) || nnp=''
  if [[ ! -d /proc/$mpid ]]; then
    log "PID $mpid exited while it was read"
    return 10
  fi
  log "PID $mpid: $cmd; uid $uid; NoNewPrivs $nnp"
  [[ " $cmd " == *" $SLATE "* ]] || die "$UNIT's main process (PID $mpid) is not $SLATE; check: systemctl cat $UNIT, then re-run this step without --verify"
  [[ $uid =~ ^[0-9]+$ && $uid != 0 ]] || die "$UNIT's renderer (PID $mpid) runs as uid ${uid:-?}, not an unprivileged one; check DynamicUser= in $UNIT_FILE, then re-run this step without --verify"
  [[ $nnp == 1 ]] || die "$UNIT's renderer (PID $mpid) has NoNewPrivs ${nnp:-?}, not 1; restart it (sudo systemctl restart $UNIT), then re-run this step"
  pass "the renderer is $UNIT's main process (PID $mpid), as uid $uid, with NoNewPrivs 1"

  # Which console is in front: printed, not judged. The screen read below is
  # tty1's whichever is in front.
  local active getty
  active=$(cat /sys/class/tty/tty0/active 2>/dev/null) || active='?'
  getty=$(systemctl show -p ActiveState --value "$GETTY" 2>/dev/null) || getty='?'
  log "the console in front: $active; $GETTY: $getty"
  if [[ $active != "$VT_NAME" ]]; then
    warn "the console in front is $active, not $VT_NAME: a panel shows that console, not the slate. Switch back with: sudo chvt 1"
  fi

  log "tty1's screen, read as root: the UTC line and the clock state only (the rest is never printed: it holds the position)"
  local rc=0 mpid2
  read_screen || rc=$?
  echo "----"
  # The PID first: a restart mid-read can also be why the read failed.
  mpid2=$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null) || mpid2='?'
  if [[ $mpid2 != "$mpid" ]]; then
    log "$UNIT's main process changed while the screen was read (PID $mpid, now ${mpid2:-?})"
    return 10
  fi
  ((rc == 0)) || die "the slate's UTC line on tty1 is missing, off or frozen (see above). Check: journalctl -u $UNIT -n 50; systemctl status $UNIT. Then re-run: setup/steps/80-portable-slate.sh --verify"
  pass "tty1 shows the slate's UTC line, within 2 s of the system clock and advancing, and the renderer (PID $mpid) ran throughout"
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
