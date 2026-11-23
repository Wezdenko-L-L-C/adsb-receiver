#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 15-stationary-position: the 🏠 stationary rig's receiver position, from
# station.yml's position: block, served to readsb on 127.0.0.1:2947 in gpsd's
# protocol by bin/adsb-position, a socket-activated static responder. Chris,
# 2026-11-14 22:00, #33 A7 ("Static responder"); BUILD.md §8 step 4b.
#
# Stationary only: asserts station.role. On the 🎒 portable, gpsd owns
# 127.0.0.1:2947 (20-portable-clock).
#
#   setup/steps/15-stationary-position.sh            install, then verify
#   setup/steps/15-stationary-position.sh --verify   verify only
#
# Why a responder, and not the two simpler answers:
#   - Not --lat/--lon: readsb prints them to its journal at every start, and
#     the journal is forbidden to the position (PLAN §5, "The one position
#     source, and the surface rule"; 10-decoder's NET_OPTIONS comment).
#   - Not gpsd: PLAN rejects running gpsd on the stationary, a daemon with no
#     device. Nothing here installs it.
# So step 10 stays shared and role-blind: readsb's --net-connector
# 127.0.0.1,2947,gpsd_in, rendered on both roles, finds this socket on the
# stationary. What readsb needs from it, read in readsb's source at step 10's
# pin, is in bin/adsb-position's header.
#
# What the step installs:
#   - /usr/local/bin/adsb-position, from this checkout, root:root 0755.
#   - /etc/adsb-receiver/position.json, root:root 0600: the position alone,
#     rendered from station.yml by adsb-position's own render_credential() and
#     checked by its check_position(), the bounds readsb's handle_gpsd()
#     applies. latitude and longitude are required: with either null the step
#     fails, since a rig with no position is not ready (PLAN §9c: no pass
#     with a warning). altitude_m may be null; then readsb gets none.
#   - adsb-position.socket: ListenStream=127.0.0.1:2947, bound by systemd as
#     root, Accept=yes, so each connection starts one adsb-position@.service.
#     ⛔ No PrivateNetwork= on the socket unit: there it would bind the socket
#     inside a private namespace readsb cannot reach (systemd.exec(5)).
#   - adsb-position@.service, the sandbox. DynamicUser=yes; the position comes
#     by LoadCredential=, so its user never opens station.yml, which is
#     root-only and also holds feeder keys. PrivateNetwork=yes and
#     RestrictAddressFamilies=AF_UNIX: it can open no network socket of its
#     own, and uses only the connection systemd hands it. ⚠️ Belief, from
#     systemd.exec(5) and how file descriptors work, not seen on the Pi: an
#     inherited AF_INET connection works under both settings.
#     RuntimeMaxSec=65min ends an instance whose client stopped reading; the
#     program itself closes a connection that has not enabled a watch within
#     10 s, and any connection after an hour, so MaxConnections=8 cannot be
#     held by idle connections (bin/adsb-position's header).
# A changed program, credential or unit stops the running instances, so readsb
# redials (at most --net-connector-delay, 15 s) and gets the new position:
# readsb takes every TPV in bounds, not only the first (net_io.c, handle_gpsd(),
# lines 3887-3898 at step 10's pin).
#
# ⚠️ No uninstall, as with every role step: a rig moved from stationary to
#    portable keeps adsb-position.socket on 127.0.0.1:2947, where the
#    portable's gpsd must listen. Remove it by hand first: systemctl disable
#    --now adsb-position.socket, then delete the two units,
#    /etc/adsb-receiver/position.json and /usr/local/bin/adsb-position.
#
# ⛔ The position is never printed: not here, not by the verify, not by the
#    responder. The verify compares in-process and prints a verdict only.
#
# Nothing in this step has run on hardware; what has is recorded in PLAN, not
# here (PLAN §9c).

set -euo pipefail

# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"
require_role stationary

for t in python3 systemctl systemd-analyze ss cmp; do
  command -v "$t" >/dev/null || die "$t is not installed"
done
python3 -c 'import yaml' 2>/dev/null || die "python3-yaml is missing: apt install python3-yaml"

SRC=$ADSB_REPO/bin/adsb-position
PROG=/usr/local/bin/adsb-position
CRED=$ADSB_ETC/position.json
UNIT_DIR=/etc/systemd/system
SOCKET=adsb-position.socket
SERVICE=adsb-position@.service
ADDR=127.0.0.1:2947
RECEIVER_JSON=/run/readsb/receiver.json
# How far receiver.json may sit from station.yml. readsb writes lat and lon
# with %.6f (about 0.1 m) and alt_m_amsl with %.0f (json_out.c,
# generateReceiverJson()); 1 m covers both.
TOL_M=1
# The wait for readsb to take the position: one redial (15 s) and a margin.
WAIT_S=45

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# install_if_changed <src> <dst> <mode> <owner:group>: render, diff, install by
# a temporary file and a rename (20-portable-clock's, which says why). Sets
# CHANGED to 0 or 1.
CHANGED=0
install_if_changed() {
  local src=$1 dst=$2 mode=$3 owner=$4 tmp
  guard_path "$dst"
  CHANGED=0
  if [[ -f $dst ]] && cmp -s "$src" "$dst" \
     && [[ $(stat -c '%U:%G %a' "$dst") == "$owner ${mode#0}" ]]; then
    log "$dst is unchanged"
    return 0
  fi
  tmp=$(dirname "$dst")/.$(basename "$dst").adsb-new~
  rm -f -- "$tmp"
  run install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$tmp" \
    || { rm -f -- "$tmp"; die "could not write $tmp; $dst was not changed"; }
  run mv -f "$tmp" "$dst" || { rm -f -- "$tmp"; die "could not rename $tmp to $dst; $dst was not changed"; }
  CHANGED=1
  log "$dst changed; installed by rename"
}

# read_position: station.yml's position: block, checked by adsb-position's own
# rules and rendered to $WORK/position.json. Prints nothing of the values.
read_position() {
  local f
  f=$(station_file) || die "no station.yml: run setup/steps/05-config.sh"
  [[ -f $SRC ]] || die "$SRC is missing from this checkout"
  python3 - "$f" "$SRC" "$WORK/position.json" <<'PY' \
    || die "could not take a position from station.yml (the reason is above). If the file does not parse, fix it at that line. If the position: block is missing or unset, survey the antenna's position (BUILD.md §8 step 4b), set position.latitude and position.longitude, then run this step again. Until then this rig has no receiver position and is not ready"
import importlib.machinery, importlib.util, sys, yaml
yml, src, out = sys.argv[1:4]
loader = importlib.machinery.SourceFileLoader("adsb_position", src)
spec = importlib.util.spec_from_loader("adsb_position", loader)
P = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
loader.exec_module(P)
try:
    with open(yml) as fh:
        doc = yaml.safe_load(fh)
except yaml.YAMLError as e:
    # Line number only: YAML's own message quotes the line, which may hold a position or a key.
    mark = getattr(e, "problem_mark", None)
    sys.exit("station.yml does not parse as YAML"
             + (f" (line {mark.line + 1})" if mark is not None else ""))
b = doc.get("position") if isinstance(doc, dict) else None
if not isinstance(b, dict):
    sys.exit("station.yml has no position: block: add it from config/station.stationary.example.yml")
try:
    text = P.render_credential(b.get("latitude"), b.get("longitude"), b.get("altitude_m"))
except P.PositionError as e:
    sys.exit(f"position: {e}")
with open(out, "w") as fh:
    fh.write(text)
PY
}

render_socket() {
  cat >"$WORK/socket" <<EOF
# Rendered by setup/steps/15-stationary-position.sh. Do not edit; re-run the step.
# The stationary rig's receiver position for readsb's gpsd_in connector, on
# loopback only. One adsb-position@.service per connection. Why, in the step.
[Unit]
Description=adsb-receiver static position responder, gpsd's protocol on $ADDR

[Socket]
ListenStream=$ADDR
Accept=yes
MaxConnections=8

[Install]
WantedBy=sockets.target
EOF
}

render_service() {
  cat >"$WORK/service" <<EOF
# Rendered by setup/steps/15-stationary-position.sh. Do not edit; re-run the step.
# One connection to adsb-position.socket: the surveyed position, in gpsd's
# protocol. Why each setting, in the step's header.
[Unit]
Description=adsb-receiver static position responder (connection %i)
CollectMode=inactive-or-failed

[Service]
ExecStart=$PROG
StandardInput=socket
StandardOutput=socket
StandardError=journal
DynamicUser=yes
LoadCredential=position:$CRED
UMask=0077
NoNewPrivileges=yes
CapabilityBoundingSet=
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
PrivateNetwork=yes
PrivateIPC=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictAddressFamilies=AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
TasksMax=4
RuntimeMaxSec=65min
EOF
}

need_reload() {
  local u
  for u in "$SOCKET" "$SERVICE"; do
    [[ $(systemctl show -p NeedDaemonReload --value "$u" 2>/dev/null) == yes ]] && return 0
  done
  return 1
}

# stop_instances: end every running connection, so readsb redials and is
# served by the current program and credential.
stop_instances() {
  local u
  while read -r u _; do
    [[ -n $u ]] && unit stop "$u"
  done < <(systemctl list-units --plain --no-legend 'adsb-position@*.service' 2>/dev/null || true)
}

install_step() {
  local changed=0 sock_changed
  read_position
  install_if_changed "$SRC" "$PROG" 0755 root:root
  ((CHANGED)) && changed=1
  install_if_changed "$WORK/position.json" "$CRED" 0600 root:root
  ((CHANGED)) && changed=1
  render_socket
  render_service
  install_if_changed "$WORK/service" "$UNIT_DIR/$SERVICE" 0644 root:root
  ((CHANGED)) && changed=1
  install_if_changed "$WORK/socket" "$UNIT_DIR/$SOCKET" 0644 root:root
  sock_changed=$CHANGED
  if ((changed || sock_changed)) || need_reload; then
    run systemctl daemon-reload
  fi
  systemctl is-enabled --quiet "$SOCKET" || unit enable "$SOCKET"
  if ! systemctl is-active --quiet "$SOCKET"; then
    unit start "$SOCKET"
  elif ((sock_changed)); then
    unit restart "$SOCKET"
  fi
  if ((changed || sock_changed)); then
    stop_instances
  fi
}

# --- verify --------------------------------------------------------------------

# position_verdict: compare receiver.json with $WORK/position.json in-process.
# Prints one word, never a value: ok, absent, far, alt-absent, alt-far or
# unreadable.
position_verdict() {
  python3 - "$RECEIVER_JSON" "$WORK/position.json" "$TOL_M" <<'PY'
import json, math, sys
rj, want_p, tol = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    with open(rj) as fh:
        got = json.load(fh)
    with open(want_p) as fh:
        want = json.load(fh)
except (OSError, ValueError):
    print("unreadable"); sys.exit(0)
def num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)
def verdict():
    if not isinstance(got, dict) or not isinstance(want, dict):
        return "unreadable"
    lat, lon = got.get("lat"), got.get("lon")
    if not (num(lat) and num(lon)):
        return "absent"
    p1, p2 = math.radians(lat), math.radians(want["lat"])
    dp, dl = p2 - p1, math.radians(want["lon"] - lon)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    if 2 * 6371008.8 * math.asin(min(1.0, math.sqrt(a))) > tol:
        return "far"
    if want.get("alt_m") is not None:
        alt = got.get("alt_m_amsl")
        if not num(alt):
            return "alt-absent"
        if abs(alt - want["alt_m"]) > tol:
            return "alt-far"
    return "ok"
# Any surprise in either file is a verdict, never a traceback (which could quote a value).
try:
    print(verdict())
except Exception:
    print("unreadable")
PY
}

verify() {
  local rc out en ac ss_out line laddr proc listen='' ours=0 others=0 verdict i
  read_position

  # 1. The program is this checkout's; the credential is station.yml's position.
  cmp -s "$SRC" "$PROG" || die "$PROG is missing or differs from $SRC; run this step without --verify"
  [[ $(stat -c '%U:%G %a' "$PROG") == "root:root 755" ]] \
    || die "$PROG is not root:root 0755; run this step without --verify"
  if [[ ! -f $CRED || -L $CRED ]] || ! cmp -s "$WORK/position.json" "$CRED"; then
    die "$CRED is missing or does not match station.yml's position: block; run this step without --verify"
  fi
  [[ $(stat -c '%U:%G %a' "$CRED") == "root:root 600" ]] \
    || die "$CRED is $(stat -c '%U:%G %a' "$CRED"), not root:root 600; run this step without --verify"
  pass "$PROG matches this checkout, and $CRED matches station.yml's position (values not printed)"

  # 2. The units match their render, load, and pass systemd-analyze.
  render_socket
  render_service
  cmp -s "$WORK/socket" "$UNIT_DIR/$SOCKET" \
    || die "$UNIT_DIR/$SOCKET is missing or differs from its render; run this step without --verify"
  cmp -s "$WORK/service" "$UNIT_DIR/$SERVICE" \
    || die "$UNIT_DIR/$SERVICE is missing or differs from its render; run this step without --verify"
  rc=0
  log "systemd-analyze verify $SOCKET $SERVICE (raw output follows)"
  out=$(systemd-analyze verify "$UNIT_DIR/$SOCKET" "$UNIT_DIR/$SERVICE" 2>&1) || rc=$?
  printf '%s\n' "${out:-(no output)}"
  echo "----"
  ((rc == 0)) || die "systemd-analyze verify rejected the responder's units (exit $rc); see above"
  # A warning can come with exit 0, and PLAN §9c allows no pass with a warning:
  # any output at all fails.
  [[ -z $out ]] || die "systemd-analyze verify printed the lines above (exit 0): a warning is not a pass; fix the units in this step"
  ! need_reload || die "systemd has not read the current $SOCKET or $SERVICE; run this step without --verify"
  pass "$SOCKET and $SERVICE match their render, load, and pass systemd-analyze"

  # 3. The socket is enabled and listening, on loopback only, held by systemd.
  en=$(systemctl is-enabled "$SOCKET" 2>&1) || true
  ac=$(systemctl is-active "$SOCKET" 2>&1) || true
  log "$SOCKET: is-enabled $en, is-active $ac"
  [[ $en == enabled ]] || die "$SOCKET is '$en', not enabled; run this step without --verify"
  [[ $ac == active ]] || die "$SOCKET is '$ac', not active; check: systemctl status $SOCKET"
  ss_out=$(ss -ltnpH 2>&1) || die "ss -ltnpH failed: $ss_out"
  while IFS= read -r line; do
    read -r _ _ _ laddr _ proc <<<"$line"
    [[ $laddr == *:"${ADDR##*:}" ]] || continue
    listen+="$line"$'\n'
    if [[ $laddr == "$ADDR" && $proc == *'"systemd",pid=1,'* ]]; then
      ours=$((ours + 1))
    else
      others=$((others + 1))
    fi
  done <<<"$ss_out"
  log "ss -ltnpH, listeners on port ${ADDR##*:} (raw):"
  printf '%s' "${listen:-(none)$'\n'}"
  ((others == 0)) \
    || die "something other than systemd's $ADDR listens on port ${ADDR##*:} (above); the responder must be the only listener, on loopback only (a gpsd installed by hand?)"
  ((ours == 1)) || die "systemd does not hold $ADDR for $SOCKET (above); check: systemctl status $SOCKET"
  pass "port ${ADDR##*:} listens on $ADDR only, held by systemd for $SOCKET"

  # 4. The observable effect: readsb has the position, and it is station.yml's.
  systemctl is-active --quiet readsb \
    || die "readsb is not running, so it cannot have taken the position; run setup/steps/10-decoder.sh, then this step"
  verdict=unreadable
  for ((i = 0; i <= WAIT_S; i++)); do
    verdict=$(position_verdict)
    [[ $verdict == ok ]] && break
    if ((i < WAIT_S)); then sleep 1; fi
  done
  log "$RECEIVER_JSON against station.yml's position, after up to ${WAIT_S} s: $verdict"
  case $verdict in
    ok) ;;
    absent) die "readsb's $RECEIVER_JSON carries no lat and lon after ${WAIT_S} s: readsb has not taken the position. Check: journalctl -u readsb for its gpsd connector, and journalctl -u 'adsb-position@*' for the responder" ;;
    far) die "readsb's $RECEIVER_JSON position is more than ${TOL_M} m from station.yml's after ${WAIT_S} s. The responder serves station.yml's position (checked above), and readsb takes every TPV it is sent, so either an instance still serves an older credential or something else feeds readsb a position. Check: journalctl -u 'adsb-position@*' and ss -tnp 'dport = :${ADDR##*:}'; systemctl stop 'adsb-position@*.service' ends every connection, and readsb redials within 15 s" ;;
    alt-absent) die "readsb's $RECEIVER_JSON has lat and lon but no alt_m_amsl, though station.yml sets altitude_m; run this step without --verify" ;;
    alt-far) die "readsb's $RECEIVER_JSON alt_m_amsl is more than ${TOL_M} m from station.yml's altitude_m; run this step without --verify" ;;
    *) die "could not read $RECEIVER_JSON as JSON (readsb not writing it?); check: systemctl status readsb" ;;
  esac
  pass "readsb's $RECEIVER_JSON carries the receiver position, and it matches station.yml's within ${TOL_M} m (values not printed)"
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
