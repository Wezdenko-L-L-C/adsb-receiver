#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 06-journal: make the systemd journal persistent, with a size cap. BUILD.md: none yet (no
# section, no §8 step). The shape is PLAN §9f's "A persistent journal is a separate, small step" (under "Open, ruled to be
# decided later"); ruled to be built, right after step 5, by Chris on 2026-10-10.
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
#     restart was seen. ⚠️ That the streams survive the restart is a belief. So the step reads
#     readsb's and adsb-writer's InvocationID and NRestarts before the restart and again after the
#     flush, and warns loudly if either changed (a unit not loaded, as on a first build, is
#     skipped). ⚠️ It sees only a break the unit has already hit: a broken stream fails on the
#     unit's next write, which may come later. update.sh's own output goes through its tee, which
#     ignores SIGPIPE (setup/update.sh:235): its journal copy could lose lines, but run.log stays
#     complete. systemd-journal-flush.service does not Require, BindsTo or PartOf journald (read
#     on the portable, 2026-10-10), so the restart does not reach it.
#   The restart happens only when the drop-in changed, or journald is not on /var yet; a second run
#   changes nothing.
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

for t in systemctl systemd-analyze systemd-tmpfiles systemd-cat journalctl cmp; do
  command -v "$t" >/dev/null || die "$t is not installed"
done

DROPIN_DIR=/etc/systemd/journald.conf.d
DROPIN=$DROPIN_DIR/60-adsb-receiver-persistent.conf
STORAGE=persistent
MAX_USE=200M
JOURNAL_DIR=/var/log/journal
# journald's own flag (systemd-journald, server_flush_to_var): written once it has flushed /run to /var.
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
# Each file's "# /path" header resets the section, since a section does not carry across files.
configured() {
  awk -v k="$1" '
    /^# \// { sec = ""; next }
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

# on_var: journald has flushed to /var and its system journal is there.
on_var() {
  [[ -e $FLUSHED_FLAG && -f $JOURNAL_DIR/$MID/system.journal ]]
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

# check_streams: compare each loaded stream unit with its mark from before the restart (BEFORE).
# A changed InvocationID or NRestarts means the unit was restarted across journald's restart: its
# stream may have broken, and for the writer that ended a recording session. Warned, never fatal:
# the reason is at the call.
declare -A BEFORE=()
check_streams() {
  local u now st i
  sleep 5   # a write that hits a broken stream, and the unit's Restart=, take a moment
  for u in "${STREAM_UNITS[@]}"; do
    [[ -n ${BEFORE[$u]:-} ]] || continue
    now=$(unit_mark "$u")
    log "$u InvocationID and NRestarts: before journald's restart ${BEFORE[$u]}; after the flush ${now:-(not loaded)}"
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

  if ((CHANGED == 0)) && on_var; then
    log "journald is already writing to $JOURNAL_DIR and the drop-in is unchanged; not restarted"
    return 0
  fi
  # See the header: on 257 only a restart loads the drop-in, and only a flush after it moves to /var.
  local u rc=0
  for u in "${STREAM_UNITS[@]}"; do
    BEFORE[$u]=$(unit_mark "$u")
    if [[ -n ${BEFORE[$u]} ]]; then log "$u InvocationID and NRestarts before journald's restart: ${BEFORE[$u]}"; fi
  done
  unit restart "$JOURNALD"
  log "timeout $FLUSH_BOUND journalctl --flush"
  timeout "$FLUSH_BOUND" journalctl --flush || rc=$?
  ((rc == 0)) \
    || die "journalctl --flush failed (exit $rc; 124 is the ${FLUSH_BOUND} s bound): journald was restarted but is still writing to /run, so this boot's journal is still volatile. Re-run this step: it restarts journald and flushes again"
  # PLAN §9c: a verify may interrupt the rig for seconds and must restore it, and may never end a
  # recording session. This is install, not verify, but the rule's reason holds, so the check
  # below warns and does not die. Dying would restore nothing: under update.sh it rolls back, and
  # the rollback re-runs the applied steps, which cannot undo a session already ended; and the
  # restart happens once per drop-in change, so a die would turn one gap into a failed update.
  check_streams
  # The machine directory is journald's own creation; systemd's rules set its mode and ACLs.
  tmpfiles
}

# --- verify --------------------------------------------------------------------

# The install tier (PLAN §9c): not the drop-in, but that journald is writing to disk. The drop-in
# matches its render; cat-config shows it as the configured last word on Storage= and SystemMaxUse=; and a
# message logged now is read back from /var/log/journal/<machine-id>/. ⛔ Never a check across boots:
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

  local mid=$MID
  log "ls -la $JOURNAL_DIR $JOURNAL_DIR/$mid; ls $FLUSHED_FLAG (raw output follows)"
  ls -la "$JOURNAL_DIR" "$JOURNAL_DIR/$mid" 2>&1 || true
  ls -l "$FLUSHED_FLAG" 2>&1 || true
  echo "----"
  [[ -f $JOURNAL_DIR/$mid/system.journal ]] \
    || die "no $JOURNAL_DIR/$mid/system.journal: journald is not writing to disk. Run this step without --verify (it restarts journald and flushes)"

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
