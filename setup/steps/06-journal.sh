#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 06-journal: make the systemd journal persistent, with a size cap. BUILD.md: none yet (no
# section, no §8 step). The shape is PLAN §9f's "A persistent journal is a separate, small step"
# (under "Open, ruled to be decided later"); ruled to be built, right after step 5, by Chris on
# 2026-10-10.
#
# Shared by both rigs, so it reads no station.yml and asserts no role. It matters most on the 🏠
# stationary, where a watchdog reboot would otherwise erase its own cause; on the 🎒 portable it
# costs SD card writes (the reason Raspberry Pi OS ships the journal volatile).
#
#   setup/steps/06-journal.sh            install, then verify
#   setup/steps/06-journal.sh --verify   verify only
#
# What it installs:
#   - /etc/systemd/journald.conf.d/60-adsb-receiver-persistent.conf, root:root 0644:
#     Storage=persistent and SystemMaxUse=200M. It must outrank Raspberry Pi OS's
#     /usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf (Storage=volatile, seen on the
#     portable, 2026-10-10). journald.conf(5): drop-ins from /usr/lib, /usr/local/lib and /etc "are
#     sorted by their filename in lexicographic order, regardless of in which of the subdirectories
#     they reside", and for a single-value option "the entry in the file sorted last takes
#     precedence"; it recommends 60-90 for /etc. So "60-" sorts after "40-". ⚠️ A drop-in whose name
#     sorts later still wins (a name starting with a letter does); verify reads the configured last
#     word from `systemd-analyze cat-config`, so that case fails the step instead of passing on our
#     file alone.
#     SystemMaxUse=200M is the limit that binds. SystemKeepFree= stays at its default (15% of the
#     file system, capped at 4G: about 4G on the portable's 29G card); it only stops the journal
#     growing when the card is nearly full, and then it deletes nothing already there
#     (journald.conf(5)).
#   - /var/log/journal, by `systemd-tmpfiles --create --prefix /var/log/journal`, the recipe in
#     systemd-journald(8). systemd's own tmpfiles.d sets its owner, mode and ACLs (`z` and `a+`
#     lines); it does not create it, so a missing one is made first.
#
# How journald picks it up: a restart, then a flush. ⚠️ Read from the systemd v257 source and the
# v259 man pages, not seen on a Pi (systemd 257 there):
#   - journald reads its configuration only at start on 257. SIGHUP reloads it only since 258
#     (systemd-journald(8): "Added in version 258"). So `journalctl --flush` alone would ask the
#     running daemon, still Storage=volatile, to flush, and it does nothing (server_flush_to_var
#     returns at once unless Storage= is persistent or auto).
#   - After the restart, journald still writes /run until a flush: it opens /var/log/journal at
#     start only if /run/systemd/journal/flushed exists, and that flag is written only by a flush
#     that ran with Storage=persistent. `journalctl --flush` then copies /run's journal into
#     /var/log/journal/<machine-id>/, removes /run's copy, and writes the flag. At every later boot,
#     systemd-journal-flush.service does the flush (journald.conf(5)).
#   - The services' stdout and stderr streams. systemd-journald(8): a restart keeps them ("It is
#     thus safe to restart systemd-journald.service, but stopping it is not recommended"), because
#     the service manager holds copies of their descriptors. Read on the 🎒 portable, 2026-10-10
#     (systemd 257.13): systemd-journald.service has FileDescriptorStoreMax=4224,
#     FileDescriptorStorePreserve=yes and NFileDescriptorStore=16, so the store is configured; no
#     restart was seen. ⚠️ That the streams survive the restart is a belief. So the step checks it,
#     and warns loudly (never dies, even when the flush then fails) on what it finds:
#       - the mechanism, printed and not judged: journald's NFileDescriptorStore before the restart
#         and after the flush (it holds every service's streams, and transient services' streams
#         come and go inside the window, so a change in it proves nothing);
#       - each of readsb and adsb-writer that is running: its main process's fd 1 is a unix
#         socket whose other end, /run/systemd/journal/stdout in `ss -xpn`, is held by the new
#         journald's PID. This sees a dropped stream before the unit next writes; warned;
#       - the outcome: their InvocationID and NRestarts, before and after, which catch a unit
#         that has already died on a broken stream and been restarted; warned.
#     A unit not loaded, as on a first build, or loaded but not active before the restart, is
#     skipped: one that starts inside the window is not a restart. update.sh's own output goes
#     through its tee, which ignores SIGPIPE (setup/update.sh:235): its journal copy could lose
#     lines, but run.log stays complete. systemd-journal-flush.service does not Require, BindsTo or
#     PartOf journald (read on the portable, 2026-10-10), so the restart does not reach it.
#   The restart happens only under update.sh (ADSB_UPDATE_RUN is set; ruled by Chris, 2026-10-10),
#   as 50-updater and 70-portable-home-update start their timers only there: update.sh holds the
#   recording lock, so no session is recording. Run by hand, no lock is held, and a
#   restart on a recording rig could drop the writer's stdout stream, which nobody has seen
#   survive: the step installs the drop-in and runs tmpfiles, warns that journald has not loaded it
#   yet (at the next boot, or once this boot's flush has run), and prints the command to load it
#   now; verify then passes on the configuration alone, with a warning, while journald has no file
#   open under /var/log/journal/<machine-id>/, and runs its disk checks once it has one.
#   Under update.sh, the restart happens only when the drop-in changed, the running journald has no
#   file open under /var/log/journal/<machine-id>/ (its /proc/<pid>/fd links), or journald started
#   before the drop-in was last written (a run that died before its restart); a second run on a rig
#   whose journald is already on /var with the current drop-in loaded does not restart journald.
#
# ⚠️ A rollback by update.sh to a tree without this step does not run it (it runs the applied tree's
#    steps); update.sh names it in status.json's rollback.leftovers_possible (setup/update.sh,
#    rollback(), lines 1109–1112). Nothing removes the drop-in, so the journal stays persistent
#    until it is removed by hand.
#
# What has run on hardware: nothing.

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"

for t in systemctl systemd-analyze systemd-tmpfiles systemd-cat journalctl busctl cmp; do
  command -v "$t" >/dev/null || die "$t is not installed"
done

DROPIN_DIR=/etc/systemd/journald.conf.d
DROPIN=$DROPIN_DIR/60-adsb-receiver-persistent.conf
STORAGE=persistent
MAX_USE=200M
JOURNAL_DIR=/var/log/journal
# journald's own flag (server_flush_to_var): written once it has flushed /run to /var. Printed by
# verify as evidence; the restart decision reads the running daemon instead (journald_on_var).
FLUSHED_FLAG=/run/systemd/journal/flushed
JOURNALD=systemd-journald.service
VERIFY_TAG=adsb-06-journal
# The units whose stdout and stderr are streams into journald, checked across its restart.
STREAM_UNITS=(readsb.service adsb-writer.service)
# Bounds, in the repo's `timeout N` idiom: the flush copies /run's journal (8M on the portable).
FLUSH_BOUND=30
SYNC_BOUND=10

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

render_dropin() {
  cat >"$WORK/dropin" <<EOF
# Rendered by setup/steps/06-journal.sh. Do not edit; re-run the step.
# Persistent journal, capped. Named 60- to sort after Raspberry Pi OS's 40-rpi-volatile-storage.conf:
# journald.conf(5), the drop-in sorted last wins.
[Journal]
Storage=$STORAGE
SystemMaxUse=$MAX_USE
EOF
}

# machine_id: the journal's directory name under /var/log/journal.
machine_id() {
  local id
  id=$(</etc/machine-id) || die "cannot read /etc/machine-id"
  [[ $id =~ ^[0-9a-f]{32}$ ]] || die "/etc/machine-id is '$id', not a machine id"
  printf '%s\n' "$id"
}

# configured <key>: the last value of <key> in the [Journal] section, as `systemd-analyze cat-config`
# lists the main file and its drop-ins in precedence order; prints nothing if no file sets it.
# Each file's header resets the section, since a section does not carry across files. The header is
# cat-config's exact shape, "# " and one absolute path with no space ending in .conf (as printed by
# systemd 259 on the workstation, and in systemd-analyze(1)'s example: journald.conf and
# journald.conf.d/NN-name.conf), so a comment such as "# /var/log/journal" inside a file does not
# reset it.
configured() {
  awk -v k="$1" '
    /^# \/[^ ]+\.conf$/ { sec = ""; next }
    /^[[:space:]]*[#;]/ { next }
    /^[[:space:]]*\[/ { sec = $0; gsub(/[[:space:]]/, "", sec); next }
    sec == "[Journal]" && match($0, "^[[:space:]]*" k "[[:space:]]*=") {
      v = substr($0, RLENGTH + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); last = v; found = 1
    }
    END { if (found) print last }
  ' "$WORK/cat-config"
}

read_cat_config() {
  systemd-analyze cat-config systemd/journald.conf >"$WORK/cat-config" 2>&1 \
    || { cat "$WORK/cat-config"; die "systemd-analyze cat-config systemd/journald.conf failed; see above"; }
}

MID=$(machine_id)

# journald_pid: the running journald's MainPID, or nothing.
journald_pid() {
  local pid
  pid=$(systemctl show -P MainPID "$JOURNALD" 2>/dev/null) || pid=
  [[ $pid =~ ^[1-9][0-9]*$ ]] && printf '%s\n' "$pid"
  return 0
}

# journald_on_var: the running journald has a file open under /var/log/journal/<machine-id>/, read
# from its /proc/<pid>/fd links. That is the daemon's own state, not a flag file or a file left from
# an earlier boot. ⚠️ Belief, from the v257 source, not seen on a Pi: journald keeps system.journal
# open while it writes there (an offlined file stays open; only a rotation or a relinquish closes it,
# and a rotation opens the next one).
journald_on_var() {
  local pid f
  pid=$(journald_pid)
  [[ -n $pid ]] || return 1
  for f in /proc/"$pid"/fd/*; do
    [[ $(readlink "$f" 2>/dev/null) == "$JOURNAL_DIR/$MID/"* ]] && return 0
  done
  return 1
}

# journald_newer_than_dropin: the running journald's main process started after the drop-in was last
# written, so it has read it. Both in microseconds of wall-clock time: the start is
# ExecMainStartTimestamp read raw over D-Bus (systemctl show prints it to the second, and install
# writes the drop-in and restarts journald within one), the drop-in's the mtime. An empty, zero or
# unreadable value is logged and returns 1, so journald is restarted. ⚠️ Wall-clock: a clock stepped back between
# the two makes journald look older. On a rig with no RTC (the stationary may have none; not built,
# not seen), fake-hwclock can boot journald with a start time earlier than the drop-in's mtime: the
# next update.sh run then restarts journald under the lock (the stream risk this step limits); verify
# does not read this, only whether journald is on /var. Bounded: that restart gives journald
# a start time after the mtime. Seen on the 🎒 portable (RTC), 2026-10-10: ExecMainStartTimestamp
# matches the start the monotonic clock implies to within milliseconds.
JOURNALD_BUS_PATH=/org/freedesktop/systemd1/unit/systemd_2djournald_2eservice   # "-" and "." escaped
journald_newer_than_dropin() {
  local type start m
  read -r type start < <(busctl get-property org.freedesktop.systemd1 "$JOURNALD_BUS_PATH" \
    org.freedesktop.systemd1.Service ExecMainStartTimestamp 2>/dev/null) || true
  m=$(stat -c '%.6Y' "$DROPIN" 2>/dev/null) || m=
  if ! [[ ${type:-} == t && ${start:-} =~ ^[1-9][0-9]*$ ]]; then
    log "journald's ExecMainStartTimestamp read as '${type:-} ${start:-}', not 't <µs>'; treated as older than the drop-in"
    return 1
  fi
  if ! [[ $m =~ ^[0-9]+\.[0-9]{6}$ ]]; then
    log "$DROPIN's mtime read as '$m', not '<s>.<µs>'; journald treated as older than the drop-in"
    return 1
  fi
  ((start > 10#${m/./}))
}

# install_dropin: render, diff, install by rename. Sets CHANGED to 0 or 1.
CHANGED=0
install_dropin() {
  local tmp
  render_dropin
  guard_path "$DROPIN"
  if [[ ! -d $DROPIN_DIR || $(stat -c '%U:%G %a' "$DROPIN_DIR") != "root:root 755" ]]; then
    run install -d -m 0755 -o root -g root "$DROPIN_DIR"
  fi
  CHANGED=0
  if [[ -f $DROPIN ]] && cmp -s "$WORK/dropin" "$DROPIN" \
     && [[ $(stat -c '%U:%G %a' "$DROPIN") == "root:root 644" ]]; then
    log "$DROPIN is unchanged"
    return 0
  fi
  tmp=$DROPIN_DIR/.${DROPIN##*/}.adsb-new
  run install -m 0644 -o root -g root "$WORK/dropin" "$tmp"
  run mv -f "$tmp" "$DROPIN"
  CHANGED=1
  log "$DROPIN changed; installed by rename"
}

# unit_mark <unit>: "InvocationID NRestarts", or nothing if the unit is not loaded.
unit_mark() {
  local load inv nr
  load=$(systemctl show -P LoadState "$1" 2>/dev/null) || load=
  [[ $load == loaded ]] || return 0
  inv=$(systemctl show -P InvocationID "$1" 2>/dev/null) || inv=
  nr=$(systemctl show -P NRestarts "$1" 2>/dev/null) || nr=
  printf '%s %s\n' "${inv:-none}" "${nr:-?}"
}

# fd_store: journald's NFileDescriptorStore, the stream descriptors the service manager holds for it.
fd_store() {
  local n
  n=$(systemctl show -P NFileDescriptorStore "$JOURNALD" 2>/dev/null) || n=
  printf '%s\n' "${n:-?}"
}

# stream_held <unit>: the unit's main process has fd 1 on a unix stream socket whose peer is
# /run/systemd/journal/stdout and is held by the running journald. Prints what it found; returns 1
# when the stream is not held, 2 when it cannot tell (not running, or fd 1 is not a socket).
# Read from `ss -xpn`: the journald end is the line whose local address is
# /run/systemd/journal/stdout and whose peer inode is the unit's socket inode (that shape seen
# with ss on the workstation; the process column, pid=<journald>, needs root, which this step is).
stream_held() {
  local u=$1 pid link ino jpid line
  pid=$(systemctl show -P MainPID "$u" 2>/dev/null) || pid=
  [[ $pid =~ ^[1-9][0-9]*$ ]] || { echo "$u: no main process"; return 2; }
  link=$(readlink "/proc/$pid/fd/1" 2>/dev/null) || link=
  [[ $link =~ ^socket:\[([0-9]+)\]$ ]] || { echo "$u: fd 1 of PID $pid is '${link:-unreadable}', not a socket"; return 2; }
  ino=${BASH_REMATCH[1]}
  command -v ss >/dev/null || { echo "$u: ss is not installed, so its stream cannot be read"; return 2; }
  jpid=$(journald_pid)
  line=$(ss -xpn 2>/dev/null | awk -v i="$ino" '$1 == "u_str" && $5 == "/run/systemd/journal/stdout" && $8 == i') || line=
  if [[ -n $line && -n $jpid && $line == *"pid=$jpid,"* ]]; then
    echo "$u: fd 1 of PID $pid (socket $ino) is connected to journald (PID $jpid)"
    return 0
  fi
  echo "$u: fd 1 of PID $pid (socket $ino) has no journald end held by PID ${jpid:-?}; ss: ${line:-(no line)}"
  return 1
}

# check_streams <when>: compare each stream unit marked before the restart (BEFORE; only the ones
# that were active then) with its mark now, <when> ("after the flush", or after a failed one).
# A changed InvocationID or NRestarts means the unit was restarted across journald's restart: its
# stream may have broken, and for the writer that ended a recording session. Warned, never fatal:
# the reason is at the call.
declare -A BEFORE=()
FD_BEFORE='?'
check_streams() {
  local when=$1 u now st i n_after rc any=0
  for u in "${STREAM_UNITS[@]}"; do [[ -z ${BEFORE[$u]:-} ]] || any=1; done
  if ((any == 0)); then
    log "none of ${STREAM_UNITS[*]} was active before journald's restart; no stream to check"
    return 0
  fi
  sleep 5   # a write that hits a broken stream, and the unit's Restart=, take a moment
  # The mechanism, directly: the store, then each running unit's own stream. The store also holds
  # every other service's stream, and transient services' streams come and go inside the window, so
  # its count is printed, not judged; the warnings come from the units' own checks below.
  n_after=$(fd_store)
  log "$JOURNALD NFileDescriptorStore: $FD_BEFORE before the restart, $n_after $when (printed, not judged)"
  for u in "${STREAM_UNITS[@]}"; do
    [[ -n ${BEFORE[$u]:-} ]] || continue
    rc=0
    stream_held "$u" || rc=$?
    ((rc != 1)) || warn "$u's stdout stream is no longer held by journald: its output is lost until it restarts (see above). Check: journalctl -u $u -n 50; then: sudo systemctl restart $u"
  done
  for u in "${STREAM_UNITS[@]}"; do
    [[ -n ${BEFORE[$u]:-} ]] || continue
    now=$(unit_mark "$u")
    log "$u InvocationID and NRestarts: before journald's restart ${BEFORE[$u]}; $when ${now:-(not loaded)}"
    [[ $now == "${BEFORE[$u]}" ]] && continue
    # Changed: give its Restart= up to 30 s to bring it back, then say where it stands.
    st=''
    for ((i = 0; i < 30; i++)); do
      st=$(systemctl is-active "$u" 2>/dev/null) || true
      [[ $st == active ]] && break
      sleep 1
    done
    warn "$u WAS RESTARTED ACROSS JOURNALD'S RESTART (InvocationID NRestarts: ${BEFORE[$u]} -> ${now:-not loaded}). Its stream into the journal may not have survived (a belief; see the header); for adsb-writer that ended a recording session. It is now '${st:-unknown}'. Check: journalctl -u $u -n 50; if it is not active: sudo systemctl start $u"
  done
}

# tmpfiles: systemd's own rules for /var/log/journal (owner, mode, ACLs). A failure is a warning:
# journald writes there as root either way, and only who else may read it depends on this.
tmpfiles() {
  local rc=0
  run systemd-tmpfiles --create --prefix "$JOURNAL_DIR" || rc=$?
  ((rc == 0)) || warn "systemd-tmpfiles --create --prefix $JOURNAL_DIR exited $rc; the journal's owner, mode or ACLs may be off (see above)"
}

install_step() {
  install_dropin
  guard_path "$JOURNAL_DIR"
  if [[ ! -d $JOURNAL_DIR ]]; then
    run install -d -m 2755 -o root -g systemd-journal "$JOURNAL_DIR"
  fi
  tmpfiles

  # Before any restart: a restart cannot help if a later drop-in overrides ours.
  read_cat_config
  local got
  got=$(configured Storage)
  [[ $got == "$STORAGE" ]] \
    || die "the configured Storage= (cat-config's last word) is '${got:-unset}', not $STORAGE: a drop-in sorted after ${DROPIN##*/} overrides it. See: systemd-analyze cat-config systemd/journald.conf"

  # Skipped only when this run left the drop-in as it was, journald has a file open under /var, and
  # journald started after the drop-in was last written. The last catches a drop-in written by an
  # earlier run that died before the restart (as at the die above): unchanged now, but never loaded.
  if ((CHANGED == 0)) && journald_on_var && journald_newer_than_dropin; then
    log "journald (PID $(journald_pid)) has a file open under $JOURNAL_DIR/$MID/, started after the drop-in was written, and the drop-in is unchanged; not restarted"
    return 0
  fi
  # See the header: restart only under update.sh, which holds the recording lock.
  if [[ -z ${ADSB_UPDATE_RUN:-} ]]; then
    warn "$DROPIN is installed; journald has not loaded it yet, so at the next boot, or once this boot's flush has run (systemd-journal-flush.service). To load it now (on a portable that is recording, do not: the restart may drop the writer's stream into the journal): sudo systemctl restart $JOURNALD && sudo journalctl --flush"
    return 0
  fi
  # See the header: on 257 only a restart loads the drop-in, and only a flush after it moves to /var.
  local u rc=0
  for u in "${STREAM_UNITS[@]}"; do
    # A unit not running now is not marked: one that starts inside the window is not a restart.
    BEFORE[$u]=
    if systemctl is-active --quiet "$u"; then BEFORE[$u]=$(unit_mark "$u"); fi
    if [[ -n ${BEFORE[$u]} ]]; then log "$u InvocationID and NRestarts before journald's restart: ${BEFORE[$u]}"; fi
  done
  FD_BEFORE=$(fd_store)
  unit restart "$JOURNALD"
  log "timeout $FLUSH_BOUND journalctl --flush"
  timeout "$FLUSH_BOUND" journalctl --flush || rc=$?
  # PLAN §9c: a verify may interrupt the rig for seconds and must restore it, and may never end a
  # recording session. This is install, not verify, but the rule's reason holds, so the check
  # below warns and does not die. Dying would restore nothing: under update.sh it rolls back, and
  # the rollback re-runs the applied steps, which cannot undo a session already ended; and the
  # restart repeats on every update.sh run while its cause holds (a changed drop-in, journald not on
  # /var, or journald started before the drop-in was written), so a die would turn one gap into
  # failed updates. It runs before a failed flush's die too: journald has been restarted either way.
  local when='after the flush'
  ((rc == 0)) || when='after the restart (the flush failed)'
  check_streams "$when"
  ((rc == 0)) \
    || die "journalctl --flush failed (exit $rc; 124 is the ${FLUSH_BOUND} s bound): journald was restarted but is still writing to /run, so this boot's journal is still volatile. The next update restarts journald and flushes again; by hand (not on a portable that is recording): sudo systemctl restart $JOURNALD && sudo journalctl --flush"
  # The machine directory is journald's own creation; systemd's rules set its mode and ACLs.
  tmpfiles
}

# --- verify --------------------------------------------------------------------

# The install tier (PLAN §9c): not the drop-in, but that journald is writing to disk. The drop-in
# matches its render; cat-config shows it as the configured last word on Storage= and
# SystemMaxUse=; the machine directory is root:systemd-journal and setgid; and a
# message logged now is read back from /var/log/journal/<machine-id>/. Run by hand while journald has
# no file open under /var, it stops after cat-config with a warning (see the header). ⛔ Never a check across boots:
# that the journal survives a reboot is a hardware observation, not something a verify can see.
verify() {
  render_dropin
  log "$DROPIN (raw output follows)"
  cat "$DROPIN" 2>&1 || true
  echo "----"
  [[ -f $DROPIN ]] || die "$DROPIN is missing; run this step without --verify"
  cmp -s "$WORK/dropin" "$DROPIN" || die "$DROPIN differs from its render; run this step without --verify"
  [[ $(stat -c '%U:%G %a' "$DROPIN") == "root:root 644" ]] || die "$DROPIN is not root:root 0644; run this step without --verify"
  pass "$DROPIN matches its render"

  read_cat_config
  log "systemd-analyze cat-config systemd/journald.conf: each file, then its settings (raw, comments dropped)"
  awk '/^# \// || !/^[[:space:]]*([#;]|$)/' "$WORK/cat-config"
  echo "----"
  local storage maxuse
  storage=$(configured Storage)
  maxuse=$(configured SystemMaxUse)
  [[ $storage == "$STORAGE" ]] \
    || die "the configured Storage= (cat-config's last word) is '${storage:-unset}', not $STORAGE: a later-sorted drop-in overrides ${DROPIN##*/}; see above"
  [[ $maxuse == "$MAX_USE" ]] \
    || die "the configured SystemMaxUse= (cat-config's last word) is '${maxuse:-unset}', not $MAX_USE: a later-sorted drop-in overrides ${DROPIN##*/}; see above"
  pass "configured (cat-config): Storage=$STORAGE and SystemMaxUse=$MAX_USE are the last word"

  # By hand the step does not restart journald (see the header); the next boot loads the drop-in,
  # and journald is on /var once that boot's flush has run. Only "not on /var" skips the checks
  # below: once journald has a file open there, the disk read-back is the effect, whatever the
  # timestamps say (a stepped clock can make a loaded drop-in look newer than journald).
  if [[ -z ${ADSB_UPDATE_RUN:-} ]] && ! journald_on_var; then
    warn "journald has no file open under $JOURNAL_DIR/$MID/: it has not loaded $DROPIN yet, so at the next boot, or once this boot's flush has run (systemd-journal-flush.service); or now (not on a portable that is recording) with: sudo systemctl restart $JOURNALD && sudo journalctl --flush"
    pass "$DROPIN is configured; journald has not loaded it yet (at the next boot, or once the flush has run)"
    return 0
  fi

  local mid=$MID
  log "ls -la $JOURNAL_DIR $JOURNAL_DIR/$mid; ls $FLUSHED_FLAG (raw output follows)"
  ls -la "$JOURNAL_DIR" "$JOURNAL_DIR/$mid" 2>&1 || true
  ls -l "$FLUSHED_FLAG" 2>&1 || true
  echo "----"
  [[ -f $JOURNAL_DIR/$mid/system.journal ]] \
    || die "no $JOURNAL_DIR/$mid/system.journal: journald is not writing to disk. Run this step without --verify (it restarts journald and flushes)"
  # systemd's own tmpfiles rule for it is 2755 root:systemd-journal: the group reads the journal,
  # and the setgid bit passes the group to what journald creates inside. Install runs that rule.
  local perm
  perm=$(stat -c '%U:%G %a' "$JOURNAL_DIR/$mid")
  if ! [[ ${perm%% *} == root:systemd-journal ]] || ! (( 8#${perm##* } & 02000 )); then
    die "$JOURNAL_DIR/$mid is '$perm', not root:systemd-journal with the setgid bit (2755): the systemd-journal group cannot read the journal. Run this step without --verify (it runs systemd-tmpfiles --create --prefix $JOURNAL_DIR)"
  fi
  pass "$JOURNAL_DIR/$mid is $perm"

  # The effect: a line logged now is on disk under /var. --sync waits until journald has written
  # what it has received; a stream line may reach it a moment later, so the read is retried.
  local token i got='' rc
  token="persistent-journal check $(date -u +%Y%m%dT%H%M%SZ) $$ $RANDOM"
  printf '%s\n' "$token" | systemd-cat -t "$VERIFY_TAG"
  for ((i = 0; i <= 5; i++)); do
    rc=0
    timeout "$SYNC_BOUND" journalctl --sync 2>&1 || rc=$?
    ((rc != 124)) || die "journalctl --sync did not finish in ${SYNC_BOUND} s: journald is not answering. Re-run this step; if it persists, check: journalctl -u $JOURNALD -b"
    ((rc == 0)) || warn "journalctl --sync exited $rc; reading the journal anyway"
    got=$(journalctl --file="$JOURNAL_DIR/$mid/system*.journal" -t "$VERIFY_TAG" -o cat -n 20 --no-pager 2>&1) || true
    grep -qxF -- "$token" <<<"$got" && break
    if ((i < 5)); then
      log "not yet on disk; waiting 1 s ($((i + 1))/5)"
      sleep 1
    fi
  done
  log "journalctl --file=$JOURNAL_DIR/$mid/system*.journal -t $VERIFY_TAG (raw output follows)"
  printf '%s\n' "${got:-(no output)}"
  echo "----"
  grep -qxF -- "$token" <<<"$got" \
    || die "a line logged just now ('$token') is not in $JOURNAL_DIR/$mid/: journald is not writing to disk. Run this step without --verify; if it persists, check: journalctl -u $JOURNALD -b"

  log "journalctl --disk-usage (raw; the cap is $MAX_USE, reported, not judged)"
  timeout "$SYNC_BOUND" journalctl --disk-usage 2>&1 || true
  echo "----"
  pass "journald is writing to $JOURNAL_DIR/$mid/: a line logged now was read back from disk (the $MAX_USE cap is configured, not observed)"
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
