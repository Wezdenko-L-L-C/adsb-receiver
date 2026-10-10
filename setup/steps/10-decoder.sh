#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 10-decoder: readsb built from source at a pinned commit, its unit and
# defaults, and tar1090 at a pinned commit, served by lighttpd. BUILD.md §7 and
# §8 step 1; PLAN §9j.
#
# Shared by both rigs, so it reads no station.yml and asserts no role.
#
#   setup/steps/10-decoder.sh            install, then verify
#   setup/steps/10-decoder.sh --verify   verify only
#
# What this encodes: the portable rig's decoder as set up by hand on
# 2026-10-03, with wiedehopf's readsb-install script. Recorded in PLAN §9j
# (2026-10-05).
#   - readsb: the pin below is the v3.16.17 tag of wiedehopf/readsb (checked
#     with `gh api`, 2026-10-04). Built with RTLSDR=yes against the packaged
#     librtlsdr 2.0.2. ⛔ Never from apt: trixie's packaged readsb has no
#     RTL-SDR support (PLAN §9j).
#   - The unit and /etc/default/readsb: readsb's debian/readsb.service and
#     debian/readsb.default at the pin: identical to upstream's apart from the
#     rendered header comment (the bodies were diffed against the Pi's files
#     and the pin's debian/ copies on 2026-10-04). `--device 0`, as ran.
#     ⚠️ Since 2026-10-10 /etc/default/readsb differs from upstream's in
#     NET_OPTIONS too: readsb's sockets bind to loopback, and its input
#     listeners are off (Chris, 2026-10-10). Why, in render_readsb.
#   - A drop-in, /etc/systemd/system/readsb.service.d/adsb-receiver.conf: ours,
#     not upstream's. systemd's exponential restart backoff: a rig with no
#     stick backs off from every 15 s toward one attempt every 2 minutes
#     (about 15 s, 23 s, 34 s, 52 s, 79 s, then 2 min). The unit above stays
#     identical to upstream's debian/readsb.service at the pin apart from the
#     rendered header comment; the drop-in overrides it.
#   - tar1090: the pin below is wiedehopf/tar1090 3.14.1823. Its own install.sh,
#     from the pinned checkout, run with that checkout as its source (the
#     script's 4th argument), so it does not fetch tar1090's master.
#     ⚠️ That installer always fetches tar1090-db, the aircraft database, from
#     that repo's master. The database is NOT pinned; only tar1090 is.
#     Accepted, Chris 2026-10-04: it is lookup data, not code.
#
# Network: a re-run with every package installed, the readsb stamp matching
# and tar1090 current touches no network. These paths do:
#   - a missing package: apt-get update and install;
#   - a stale readsb stamp (pin, recipe or binary): git fetch of the pin;
#   - a stale tar1090: git fetch of the pin, and tar1090's installer, which
#     fetches tar1090-db (and fails with no network).
#
# ⛔ The verify never stops readsb. It reads the files readsb writes.
# ⛔ No verify opens the stick; readsb is the only opener. This verify reads
#    readsb's own open of the stick from its journal: the tuner, the V4 line
#    and the EEPROM strings. The tuner/V4/counterfeit table lives here now,
#    moved from 00-drivers on 2026-10-05 (ruled by Chris, on fable-architect's
#    call). It informs and never gates: its odd combinations warn, and the
#    step passes on streaming (ruled by Chris, 2026-10-05).

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"

READSB_REPO=https://github.com/wiedehopf/readsb.git
READSB_PIN=094720939c01943de82b14df6f42f67fff1cd514     # v3.16.17
TAR1090_REPO=https://github.com/wiedehopf/tar1090.git
TAR1090_PIN=e784ee5ae82948f41efe3ef5c235ade0943ab8ff    # 3.14.1823

# The build recipe, recorded in the stamp: a change here rebuilds.
# We chose these flags. They match the CFLAGS line wiedehopf/adsb-scripts'
# readsb-install.sh uses on non-riscv machines (line 152 at f933123); which
# revision of that script built the Pi's binary is not recorded. readsb's
# Makefile at the pin already has -O2 in CFLAGS (line 25) and appends OPTIMIZE
# (line 175), so what this adds is -march=native -mtune=native. The binary is
# built on the rig it runs on, so "native" is that rig's CPU. readsb-install's
# -mno-unaligned-access is not added: aarch64 gcc rejects it (seen on the Pi,
# 2026-10-04), and that script adds it only where gcc accepts it.
READSB_MAKE_ARGS=(RTLSDR=yes "OPTIMIZE=-O2 -march=native -mtune=native")
READSB_RECIPE="${READSB_MAKE_ARGS[*]}"

READSB_SRC=/usr/local/src/readsb
TAR1090_SRC=/usr/local/src/tar1090
READSB_BIN=/usr/bin/readsb
# Runtime state lives under /var/lib/adsb-receiver/ (PLAN §9d).
STATE_DIR=/var/lib/adsb-receiver
READSB_STAMP=$STATE_DIR/readsb.stamp
TAR1090_STAMP=$STATE_DIR/tar1090.stamp
# /etc/systemd/system outranks /usr/lib/systemd/system, so this copy is the one
# systemd loads, and readsb-install's copy under /usr/lib is left untouched
# rather than edited or deleted by a step that did not put it there.
UNIT_FILE=/etc/systemd/system/readsb.service
# ⚠️ A rollback by update.sh does not remove this drop-in: rollback does not
#    undo creation inside an existing step (PLAN §9f).
DROPIN=/etc/systemd/system/readsb.service.d/adsb-receiver.conf
DEFAULTS=/etc/default/readsb
JSON_DIR=/run/readsb
TAR1090_DIR=/usr/local/share/tar1090
TAR1090_URL=http://127.0.0.1/tar1090/
READSB_USER=readsb

# readsb's own list for this commit is `required_packages` in its source, plus
# git and ca-certificates to fetch it.
# ⚠️ BUILD.md §4 says to purge the packaged librtlsdr and build osmocom's. This
#    step does the opposite, and installs librtlsdr0 and librtlsdr-dev from
#    apt: no V4 is coming, and 00-drivers uses the packaged 2.0.2. BUILD.md §4
#    is queued for a rewrite (PLAN §9's consequences table).
#    Corrected 2026-10-10: BUILD.md §4 is not rewritten; it carries a dated
#    correction after its code block saying what the steps do, with the recipe
#    kept beside it. "No V4 is coming" was not a ruling when written; it is now:
#    no genuine V4 is available, and the portable runs on a genuine V3 (Chris,
#    2026-10-10, PLAN §9j).
BUILD_PKGS=(git ca-certificates gcc make libc6-dev pkg-config libusb-1.0-0-dev
  librtlsdr-dev librtlsdr0 libncurses-dev zlib1g zlib1g-dev libzstd1 libzstd-dev)
# lighttpd serves tar1090. tar1090's install.sh at the pin apt-installs only
# git, jq and curl, when their commands are missing (its command_package, line
# 41); with these and git above present, it never runs apt itself. Its wget and
# unzip appear only in a fallback for a failed git clone (line 112), which it
# does not install.
WEB_PKGS=(lighttpd curl jq python3)
# iproute2: the verify reads readsb's listeners with its `ss` (2026-10-10).
VERIFY_PKGS=(iproute2)

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

# pkg_installed <pkg>: dpkg says it is installed. No `grep -q` at the end of a
# pipe: under pipefail its early exit can fail the pipe.
pkg_installed() {
  local s
  s=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1
  [[ $s == "install ok installed" ]]
}

# apt_ensure <pkg>...: install whichever are missing. apt-get update only then,
# so a re-run with everything present touches no network.
apt_ensure() {
  local p missing=()
  for p in "$@"; do
    pkg_installed "$p" || missing+=("$p")
  done
  if ((${#missing[@]} == 0)); then
    log "already installed: $*"
    return 0
  fi
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

ensure_state_dir() {
  guard_path "$STATE_DIR"
  [[ -d $STATE_DIR ]] || run install -d -m 0755 -o root -g root "$STATE_DIR"
}

# git_at_pin <repo-url> <sha> <dir>: a checkout of exactly <sha>, detached, with
# no stray files. Fetches the one commit, never a branch.
git_at_pin() {
  local url=$1 sha=$2 dir=$3 head
  guard_path "$dir"
  if [[ ! -d $dir/.git ]]; then
    run mkdir -p "$dir"
    run git -C "$dir" init -q
    run git -C "$dir" remote add origin "$url"
  fi
  run git -C "$dir" remote set-url origin "$url"
  run git -C "$dir" fetch -q --depth 1 origin "$sha"
  run git -C "$dir" checkout -q --detach "$sha"
  run git -C "$dir" clean -q -fdx
  head=$(git -C "$dir" rev-parse HEAD)
  [[ $head == "$sha" ]] || die "$dir is at $head after the checkout, not the pin $sha"
  log "$dir is at the pin $sha"
}

# stamp_field <file> <key>: the rest of the "key value..." line; empty if absent.
stamp_field() {
  awk -v k="$2" '$1 == k { sub(/^[^ ]+ /, ""); print; exit }' "$1" 2>/dev/null || true
}

sha256_of() {
  sha256sum "$1" 2>/dev/null | awk '{ print $1 }'
}

# --- readsb --------------------------------------------------------------------

refuse_apt_readsb() {
  if pkg_installed readsb; then
    die "the apt package readsb is installed. trixie's packaged readsb cannot drive an RTL-SDR (PLAN §9j). Remove it (apt-get remove readsb), then run this step again"
  fi
}

# The build is skipped when the stamp names the pin and the recipe, AND the
# installed binary is the one the stamp recorded. Anything else rebuilds.
readsb_is_current() {
  [[ -f $READSB_STAMP && -x $READSB_BIN ]] || return 1
  [[ $(stamp_field "$READSB_STAMP" sha) == "$READSB_PIN" ]] || return 1
  [[ $(stamp_field "$READSB_STAMP" recipe) == "$READSB_RECIPE" ]] || return 1
  [[ $(stamp_field "$READSB_STAMP" sha256) == "$(sha256_of "$READSB_BIN")" ]]
}

build_readsb() {
  if readsb_is_current; then
    log "readsb at the pin, with this recipe, is installed (the stamp and the binary's hash agree); no build"
    return 0
  fi
  log "building readsb at $READSB_PIN with: $READSB_RECIPE (minutes on a Pi 4)"
  git_at_pin "$READSB_REPO" "$READSB_PIN" "$READSB_SRC"
  local jobs
  jobs=$(($(nproc) - 1))
  ((jobs > 0)) || jobs=1
  run make -C "$READSB_SRC" -j"$jobs" "${READSB_MAKE_ARGS[@]}" readsb
  [[ -x $READSB_SRC/readsb ]] || die "the build produced no $READSB_SRC/readsb"

  local built new
  built=$(sha256_of "$READSB_SRC/readsb")
  if [[ -x $READSB_BIN && $(sha256_of "$READSB_BIN") == "$built" ]]; then
    log "$READSB_BIN is already this build"
  else
    # A rename, so the running readsb keeps its old inode and nothing writes
    # into a busy executable.
    new=$(dirname "$READSB_BIN")/.readsb.new
    guard_path "$new"
    guard_path "$READSB_BIN"
    run install -m 0755 -o root -g root "$READSB_SRC/readsb" "$new"
    run mv -f "$new" "$READSB_BIN"
  fi
  # The stamp may be written before readsb restarts: whether to restart is
  # read from the running process (readsb_restart_reason), not remembered.
  ensure_state_dir
  guard_path "$READSB_STAMP"
  printf 'sha %s\nrecipe %s\nsha256 %s\nbuilt %s\n' "$READSB_PIN" "$READSB_RECIPE" "$built" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$WORK/stamp"
  run install -m 0644 -o root -g root "$WORK/stamp" "$READSB_STAMP"
}

ensure_readsb_user() {
  # getent first: useradd fails on a name that exists.
  # Primary group nogroup, as `adduser --system` made it on the Pi (gid
  # nogroup, groups dialout and plugdev, seen 2026-10-04). An existing user is
  # left as it is, apart from plugdev below.
  if getent passwd "$READSB_USER" >/dev/null; then
    log "user $READSB_USER exists"
  else
    run useradd --system --no-create-home --home-dir /nonexistent \
      --shell /usr/sbin/nologin --gid nogroup "$READSB_USER"
  fi
  # plugdev: the rtl-sdr udev rules grant the stick to that group (MODE 0660,
  # GROUP plugdev for 0bda:2838, seen on the Pi 2026-10-04), as
  # readsb-install does with `adduser readsb plugdev`. ℹ️ readsb-install also
  # adds dialout, for serial receivers; an RTL-SDR does not need it, and this
  # step neither adds nor removes it.
  local g
  g=$(id -nG "$READSB_USER")
  if [[ " $g " != *" plugdev "* ]]; then
    run usermod -aG plugdev "$READSB_USER"
  fi
}

render_readsb() {
  cat >"$WORK/readsb.service" <<'EOF'
# Rendered by setup/steps/10-decoder.sh. Do not edit; re-run the step.
# readsb's own debian/readsb.service at the pinned commit. This copy, in
# /etc/systemd/system, overrides any under /usr/lib/systemd/system.

[Unit]
Description=readsb ADS-B receiver
Documentation=https://github.com/wiedehopf/readsb
Wants=network.target
After=network.target

[Service]
EnvironmentFile=/etc/default/readsb
User=readsb
RuntimeDirectory=readsb
RuntimeDirectoryMode=0755
ExecStart=/usr/bin/readsb --write-json /run/readsb --quiet $RECEIVER_OPTIONS $DECODER_OPTIONS $NET_OPTIONS $JSON_OPTIONS
Type=simple
Restart=always
RestartSec=15
StartLimitInterval=1
StartLimitBurst=100
Nice=-5

[Install]
WantedBy=default.target
EOF

  # Ours, not upstream's, so the unit above stays identical to upstream's
  # debian/readsb.service at the pin apart from the rendered header comment (the
  # body was diffed on 2026-10-04). With no
  # stick, upstream's unit restarts readsb every 15 s forever (28 times in about
  # 7 minutes, seen on the portable rig): its StartLimitBurst never limits.
  cat >"$WORK/readsb.dropin" <<'EOF'
# Rendered by setup/steps/10-decoder.sh. Do not edit; re-run the step.
# systemd's exponential restart backoff (RestartSteps= and RestartMaxDelaySec=
# need systemd 254 or later; Pi OS trixie has 257). From readsb's own
# RestartSec=15, over 5 steps, to one attempt every 2 minutes: about 15 s,
# 23 s, 34 s, 52 s, 79 s, then 2 min. A rig with no stick plugged in no longer
# retries every 15 s. StartLimitIntervalSec=0: systemd never gives up.
# RestartSec= is not set here: upstream's unit sets it, and a copy here would
# silently pin an old value at a new pin.
# Why 2 minutes, not longer: systemd is believed (unverified) not to reset the
# restart counter after a long healthy run, so after a stick-less stretch the
# next transient fault could wait the full maximum. On the remote rig 2
# minutes bounds that loss.
# The archive writer's own 30 s preflight loop is a separate thing, untouched.

[Unit]
StartLimitIntervalSec=0

[Service]
RestartSteps=5
RestartMaxDelaySec=2min
EOF

  # ⚠️ Rendered, so a hand edit to /etc/default/readsb is reverted on the next
  #    run, and readsb restarts with the repo's values. Config lives in the
  #    repo (PLAN §9f): change it here.
  # 📋 Not yet from station.yml: `--device 0` is what ran. Selecting the stick
  #    by its EEPROM serial (dongles.adsb, RADIOS.md §5 rule 2) and, on the
  #    stationary rig, --lat/--lon from position: are follow-ups.
  # ⛔ NET_OPTIONS: loopback only, and no input listeners (Chris, 2026-10-10).
  #    Until then this was upstream's line: raw input on 30001 and BEAST input
  #    on 30004 and 30104, with every listener on all addresses, IPv4 and IPv6
  #    (seen with `ss -ltn` on the portable, 2026-10-10). Anyone on the same
  #    network could send readsb frames, and readsb's source at the pin
  #    forwards network-input frames to the BEAST output like the stick's own
  #    (net_io.c, outputMessage(): no check of a message's remote flag before
  #    beast_out). Read in the source, not seen on a rig. The archive writer
  #    records that BEAST output, so such frames would land in the archive.
  #    Nothing off the rig needs these sockets: the writer and update.sh's
  #    readiness probe connect to 127.0.0.1:30005, and tar1090 reads
  #    /run/readsb from disk. ℹ️ A future feeder or mlat client on the rig
  #    pushes into readsb's input ports on loopback, so a feeder step would
  #    reopen one input port, bound to 127.0.0.1; nothing is reopened now.
  #    - --net-bind-address 127.0.0.1: every listener binds to it. readsb
  #      resolves it with getaddrinfo(AF_UNSPEC) (anet.c, anetTcpServer()),
  #      which gives an IPv4 address only, so no [::] listener is expected;
  #      read in the source, not seen. The verify reads `ss` either way.
  #    - --net-ri-port and --net-bi-port are removed, not set to 0: their
  #      default at the pin is "0" (readsb.c), and "0" opens nothing
  #      (net_io.c, serviceListen()); read in readsb's source at the pin, not
  #      seen. The verify checks that those ports are closed.
  #    - 30002 (raw out) and 30003 (SBS out) stay, on loopback. Nothing in
  #      this repo reads them (2026-10-10); removing them is not ruled.
  #    ⚠️ Reasoned from this step's code, not yet seen on a rig: a rig with the
  #    old file gets this one on its next run. install_if_changed's `cmp`
  #    finds the rendered file different and installs it, and
  #    readsb_restart_reason's mtime check finds the file newer than the
  #    running readsb and restarts it. ✅ once the portable re-runs the step.
  cat >"$WORK/readsb.default" <<'EOF'
# Rendered by setup/steps/10-decoder.sh. Do not edit; a hand edit is reverted
# on the next run. Change the step instead.
# Read by readsb.service as EnvironmentFile=. The values are the ones the
# portable rig ran on 2026-10-03, apart from NET_OPTIONS: since 2026-10-10
# readsb listens on loopback only, with no input ports. Why, in the step.

RECEIVER_OPTIONS="--device 0 --device-type rtlsdr --gain auto --ppm 0"
DECODER_OPTIONS="--max-range 450 --write-json-every 1"
NET_OPTIONS="--net --net-bind-address 127.0.0.1 --net-ro-port 30002 --net-sbs-port 30003 --net-bo-port 30005"
JSON_OPTIONS="--json-location-accuracy 2 --range-outline-hours 24"
EOF
}

# enable_links: the enablement symlinks for readsb.service, one per line.
enable_links() {
  local l
  for l in /etc/systemd/system/*.wants/readsb.service; do
    [[ -L $l ]] && printf '%s -> %s\n' "$l" "$(readlink "$l")"
  done
  return 0
}

# enabled_at_etc: readsb is enabled, and every enablement symlink points at
# UNIT_FILE (readsb-install's points at its /usr/lib copy).
enabled_at_etc() {
  local links
  links=$(enable_links)
  [[ -n $links ]] || return 1
  ! grep -qv -- "-> $UNIT_FILE\$" <<<"$links"
}

# readsb_restart_reason: print why the running readsb is stale, or nothing.
# Read from observable state, so a run that died between installing and
# restarting is caught by the next run (PLAN §9f: restart only on a change).
readsb_restart_reason() {
  local pid exe etimes start f gid
  pid=$(systemctl show -p MainPID --value readsb 2>/dev/null) || pid=0
  [[ $pid =~ ^[1-9][0-9]*$ ]] || return 0   # not running: the caller starts it
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || exe=
  if [[ $exe != "$READSB_BIN" ]]; then
    echo "the running readsb (PID $pid) is '${exe:-unreadable}', not the installed $READSB_BIN"
    return 0
  fi
  etimes=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ') || etimes=
  if [[ $etimes =~ ^[0-9]+$ ]]; then
    start=$(($(date +%s) - etimes))
    for f in "$UNIT_FILE" "$DROPIN" "$DEFAULTS"; do
      [[ -e $f ]] || continue
      if (($(stat -c %Y "$f") > start)); then
        echo "$f changed after readsb (PID $pid) started"
        return 0
      fi
    done
  else
    echo "cannot read how long PID $pid has run"
    return 0
  fi
  gid=$(getent group plugdev | cut -d: -f3)
  if [[ " $(awk '/^Groups:/ { $1 = ""; print }' "/proc/$pid/status") " != *" $gid "* ]]; then
    echo "the running readsb (PID $pid) lacks the plugdev group"
    return 0
  fi
}

install_readsb_service() {
  local frag reload state reason='' units_changed=0
  render_readsb
  install_if_changed "$WORK/readsb.service" "$UNIT_FILE" 0644 root:root
  units_changed=$CHANGED
  # The drop-in directory explicitly 0755: install -D would create it under
  # the caller's umask, and a restrictive one would leave it 0700. An existing
  # one left so by an earlier run is corrected too.
  guard_path "${DROPIN%/*}"
  if [[ ! -d ${DROPIN%/*} || $(stat -c '%U:%G %a' "${DROPIN%/*}") != "root:root 755" ]]; then
    run install -d -m 0755 -o root -g root "${DROPIN%/*}"
  fi
  install_if_changed "$WORK/readsb.dropin" "$DROPIN" 0644 root:root
  if ((CHANGED)); then units_changed=1; fi
  install_if_changed "$WORK/readsb.default" "$DEFAULTS" 0644 root:root

  # A daemon-reload whenever this run changed the unit or the drop-in, and
  # whenever systemd says it needs one. NeedDaemonReload covers drop-ins too: a
  # loaded unit reports yes when one is added or changed (seen on systemd 259,
  # 2026-10-05; unverified on 257). A changed drop-in restarts readsb through
  # readsb_restart_reason.
  frag=$(systemctl show -p FragmentPath --value readsb 2>/dev/null) || frag=
  reload=$(systemctl show -p NeedDaemonReload --value readsb 2>/dev/null) || reload=
  if ((units_changed)) || [[ $frag != "$UNIT_FILE" || $reload == yes ]]; then
    run systemctl daemon-reload
    if [[ $frag != "$UNIT_FILE" ]]; then
      reason="systemd had readsb loaded from '${frag:-nothing}', not $UNIT_FILE"
    fi
  fi
  if ! enabled_at_etc; then
    log "enablement symlinks before (raw): $(enable_links | tr '\n' ' ')"
    # reenable: disable, then enable, so the symlink points at UNIT_FILE. It
    # starts and stops nothing.
    unit reenable readsb
  fi

  # activating is the backoff's wait between restarts. A step run is when a
  # hand or the updater wants readsb tried now, and the verify's 20 s wait for
  # aircraft.json is shorter than the backoff's later steps, so it is
  # restarted. The backoff is for the unattended loop. A restart also covers
  # whatever readsb_restart_reason would have found.
  state=$(systemctl show -p ActiveState --value readsb 2>/dev/null) || state=
  case $state in
    inactive|failed|'')
      unit start readsb
      return 0 ;;
    activating)
      log "readsb is in its restart backoff; starting it now rather than waiting out the backoff"
      unit restart readsb
      return 0 ;;
  esac
  [[ -n $reason ]] || reason=$(readsb_restart_reason)
  if [[ -n $reason ]]; then
    log "restarting readsb: $reason"
    unit restart readsb
  else
    log "readsb is running the installed binary, with the current unit, drop-in, defaults and groups; not restarted"
  fi
}

# --- tar1090 -------------------------------------------------------------------

# tar1090's install.sh at the pin writes TAR_VERSION into html/version.json
# (line 303); with a local source it sets TAR_VERSION to the checkout's
# `version` file plus "_dirty" (line 147).
tar1090_expected_version() {
  local v
  v=$(cat "$TAR1090_SRC/version" 2>/dev/null) || return 1
  printf '%s_dirty\n' "$v"
}

tar1090_installed_version() {
  python3 - "$TAR1090_DIR/html/version.json" <<'PY' 2>/dev/null
import json, sys
with open(sys.argv[1]) as fh:
    print(json.load(fh).get("tar1090Version", ""))
PY
}

tar1090_is_current() {
  local want got head
  [[ $(stamp_field "$TAR1090_STAMP" sha) == "$TAR1090_PIN" ]] || return 1
  head=$(git -C "$TAR1090_SRC" rev-parse HEAD 2>/dev/null) || return 1
  [[ $head == "$TAR1090_PIN" ]] || return 1
  want=$(tar1090_expected_version) || return 1
  got=$(tar1090_installed_version) || return 1
  [[ $got == "$want" ]]
}

install_tar1090() {
  if tar1090_is_current; then
    log "tar1090 at the pin is installed ($(tar1090_installed_version)); not reinstalled"
    return 0
  fi
  git_at_pin "$TAR1090_REPO" "$TAR1090_PIN" "$TAR1090_SRC"
  # install.sh <data dir> <web path> <install path> <local source>, at the pin:
  #   - $4 is taken as the source when its install.sh mentions tar1090 (line
  #     23), and then copied instead of fetching master (lines 138-147);
  #   - an empty $3 keeps the default install path, /usr/local/share/tar1090
  #     (lines 20-21); an empty $2 with $1 set makes the one instance
  #     "$1 tar1090", served at /tar1090 (lines 193-196);
  #   - TAR1090_UPDATE_DIR, if set, would move its git copies (line 29), so it
  #     is cleared.
  # It writes /usr/local/share/tar1090, /etc/default/tar1090 (only if absent),
  # the tar1090 unit and user, and /etc/lighttpd, and restarts tar1090 and
  # lighttpd. ⚠️ It fetches tar1090-db from master (accepted, Chris 2026-10-04).
  log "running tar1090's installer from the pinned checkout"
  (cd "$TAR1090_SRC" && run env -u TAR1090_UPDATE_DIR bash ./install.sh "$JSON_DIR" "" "" "$TAR1090_SRC") \
    || die "tar1090's install.sh failed; its output is above"
  ensure_state_dir
  guard_path "$TAR1090_STAMP"
  printf 'sha %s\ninstalled %s\n' "$TAR1090_PIN" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$WORK/tstamp"
  run install -m 0644 -o root -g root "$WORK/tstamp" "$TAR1090_STAMP"
}

install_step() {
  refuse_apt_readsb
  apt_ensure "${BUILD_PKGS[@]}" "${WEB_PKGS[@]}" "${VERIFY_PKGS[@]}"
  ensure_readsb_user
  build_readsb
  install_readsb_service
  install_tar1090
}

# --- verify --------------------------------------------------------------------

# json_field <file> <key>[.<key>...]: print the value, or nothing.
json_field() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as fh:
        node = json.load(fh)
    for k in sys.argv[2].split("."):
        node = node[k]
    print(node)
except Exception:
    pass
PY
}

# wait_for_field <file> <key> <seconds>: poll until the file has the key.
# After a restart readsb recreates /run/readsb; aircraft.json comes within
# seconds, stats.json only at its first 10 s update. Prints the value.
wait_for_field() {
  local f=$1 k=$2 max=$3 i v
  for ((i = 0; i <= max; i++)); do
    v=$(json_field "$f" "$k")
    if [[ -n $v ]]; then
      printf '%s\n' "$v"
      return 0
    fi
    ((i < max)) && sleep 1
  done
  return 1
}

# An RTL2832U on USB: Realtek 0bda, product 2838 or 2832. Read from sysfs, so no
# lsusb is needed. Prints the matches.
sdr_on_usb() {
  local d v p
  for d in /sys/bus/usb/devices/*; do
    [[ -f $d/idVendor && -f $d/idProduct ]] || continue
    v=$(<"$d/idVendor"); p=$(<"$d/idProduct")
    if [[ $v == 0bda && ( $p == 2838 || $p == 2832 ) ]]; then
      printf '%s %s:%s\n' "$(basename "$d")" "$v" "$p"
    fi
  done
}

# Why is readsb not writing? Say whether the stick is there, then fail.
die_not_streaming() {
  local why=$1 sdr
  log "journalctl -u readsb -n 20 --no-pager (raw output follows)"
  journalctl -u readsb -n 20 --no-pager 2>&1 || true
  echo "----"
  sdr=$(sdr_on_usb)
  log "RTL2832U devices on USB, from sysfs (raw): ${sdr:-(none)}"
  if [[ -z $sdr ]]; then
    die "$why. No RTL-SDR (0bda:2838 or 0bda:2832) is on USB: plug in the stick"
  fi
  die "$why. The stick is on USB; check: systemctl status readsb, and the journal above"
}

# check_tuner: what librtlsdr printed when readsb opened the stick, read from
# the journal of readsb's current start (its InvocationID), so nothing here
# opens the stick. On the portable rig (2026-10-05) each start logs:
#   rtlsdr: using device #0: Generic RTL2832U OEM (Realtek, RTL2838UHIDIR, SN 00000001)
#   Detached kernel driver
#   Found Rafael Micro R820T tuner
# and a genuine V4 is believed to add "RTL-SDR Blog V4 Detected" after the
# tuner line, as rtl_test prints it. Then the tuner table, moved from
# 00-drivers on 2026-10-05: it warns and never fails (see below).
# check_tuner <invocation-id>: the ID captured before the streaming checks. If
# readsb restarted since, it says so and reads the current start instead.
check_tuner() {
  local inv0=$1 inv jrn rc=0 libl tail_from_tuner devline tuner v4=0 maker product
  inv=$(systemctl show -p InvocationID --value readsb 2>/dev/null) || inv=
  [[ -n $inv ]] || die "readsb has no InvocationID, so it is not running; check: systemctl status readsb"
  if [[ $inv != "$inv0" ]]; then
    warn "readsb restarted during the verify (InvocationID ${inv0:-none}, now $inv); reading the current start's journal"
  fi
  jrn=$(journalctl -u readsb "_SYSTEMD_INVOCATION_ID=$inv" -o cat --no-pager 2>/dev/null) || rc=$?
  if ((rc != 0)); then
    warn "could not read readsb's journal (journalctl exit $rc): tuner identity not checked"
    return 0
  fi
  libl=$(grep -E 'rtlsdr: using device|Detached kernel driver|Found .+ tuner|RTL-SDR Blog V4 Detected' <<<"$jrn") || true
  log "journalctl -u readsb _SYSTEMD_INVOCATION_ID=$inv -o cat: the librtlsdr lines follow"
  printf '%s\n' "${libl:-(none)}"
  echo "----"
  if [[ -z $libl ]]; then
    warn "tuner identity not checked this invocation: no librtlsdr open line in the journal (rotated?)"
    return 0
  fi

  # Reported, not judged. Before the blacklist's first reboot this is expected.
  if grep -q 'Detached kernel driver' <<<"$libl"; then
    log "'Detached kernel driver' is in this start's journal: a kernel driver was bound to the stick when readsb opened it"
  else
    log "no 'Detached kernel driver' in this start's journal: no kernel driver was bound to the stick when readsb opened it"
  fi

  # Everything from the last tuner line on: the V4 line, if any, follows it.
  tail_from_tuner=$(awk '/Found .+ tuner/ { buf = "" ; f = 1 } f { buf = buf $0 "\n" } END { printf "%s", buf }' <<<"$jrn")
  tuner=$(grep -m1 -oE 'Found .+ tuner' <<<"$tail_from_tuner" | sed -E 's/^Found //; s/ tuner$//') || true
  if [[ -z $tuner ]]; then
    warn "tuner identity not checked this invocation: no librtlsdr open line in the journal (rotated?)"
    return 0
  fi
  grep -q 'RTL-SDR Blog V4 Detected' <<<"$tail_from_tuner" && v4=1
  devline=$(grep -E 'rtlsdr: using device #0: ' <<<"$jrn" | tail -n1) || true
  maker=$(sed -nE 's/.*\(([^,]*), ([^,]*), SN [^)]*\)[[:space:]]*$/\1/p' <<<"$devline")
  product=$(sed -nE 's/.*\(([^,]*), ([^,]*), SN [^)]*\)[[:space:]]*$/\2/p' <<<"$devline")
  log "tuner: $tuner | EEPROM manufacturer: ${maker:-?} | product: ${product:-?}"

  # ℹ️ This table informs; it never gates. No branch fails: a hardware verdict
  #    is not an update gate, and the stick is already streaming. Until
  #    2026-10-05 the odd combinations below failed the verify (in 00-drivers,
  #    then here). Ruled by Chris, 2026-10-05: "I will not be using the
  #    counterfeit radios anymore."
  local v4word=no
  ((v4)) && v4word=yes
  if [[ $tuner == *R828D* ]] && ((v4)); then
    log "reads as a genuine V4: an R828D tuner, and the library detected an RTL-SDR Blog V4"
  elif ((v4)); then
    # (a) The library's V4 line on another tuner.
    warn "################################################################"
    warn "The library reported an RTL-SDR Blog V4, but the tuner is $tuner, not R828D."
    warn "That should not happen; report it."
    warn "################################################################"
  elif [[ $tuner == *R828D* ]]; then
    # (b) An R828D with no V4 line: the BUILD.md §4 silent failure, a V4 on a
    #     library without V4 support. It may half-work.
    warn "################################################################"
    warn "R828D tuner but no 'RTL-SDR Blog V4 Detected': the librtlsdr in use may lack V4 support (BUILD.md §4)."
    warn "The stick is streaming, so this is a warning, not a failure (ruled 2026-10-05)."
    warn "################################################################"
  elif [[ "$maker $product" =~ [Bb]log|V4 ]]; then
    # (c) The counterfeit signature (PLAN §9j): sold as a V4, and not an R828D.
    #     Kept as a warning for the record.
    warn "################################################################"
    warn "The EEPROM claims RTL-SDR Blog / V4, but the tuner is $tuner, not R828D."
    warn "That is the counterfeit-V4 signature recorded in docs/PLAN.md §9j."
    warn "################################################################"
  else
    log "reads as a non-V4 stick: no Blog or V4 in the EEPROM strings"
    warn "If the case says V4, a non-R828D tuner is the counterfeit signature in docs/PLAN.md §9j."
  fi
  pass "readsb opened the stick: tuner $tuner; library V4 line: $v4word; EEPROM strings: '${maker:-?}' / '${product:-?}'"
}

verify() {
  # The binary: ours, not a package's, and linked to librtlsdr.
  local out
  [[ -x $READSB_BIN ]] || die "$READSB_BIN is missing; run this step without --verify"
  log "dpkg -S $READSB_BIN (raw output follows; it must find no package)"
  if out=$(dpkg -S "$READSB_BIN" 2>&1); then
    printf '%s\n' "$out"
    echo "----"
    if [[ ${out%%:*} == readsb ]]; then
      die "$READSB_BIN belongs to the readsb package; trixie's packaged readsb cannot drive an RTL-SDR (PLAN §9j). Remove it and run this step"
    fi
    die "$READSB_BIN belongs to the package ${out%%:*}, not to this step's build. Remove it and run this step"
  fi
  printf '%s\n' "$out"
  echo "----"
  log "ldd $READSB_BIN (raw output follows)"
  out=$(ldd "$READSB_BIN" 2>&1) || true
  printf '%s\n' "$out"
  echo "----"
  grep -q 'librtlsdr' <<<"$out" || die "$READSB_BIN does not link librtlsdr: it was built without RTLSDR=yes"
  log "readsb --version (raw output follows)"
  "$READSB_BIN" --version 2>&1 || true
  echo "----"
  log "$READSB_STAMP (raw output follows)"
  cat "$READSB_STAMP" 2>&1 || true
  echo "----"
  [[ $(stamp_field "$READSB_STAMP" sha) == "$READSB_PIN" ]] \
    || die "the stamp does not name the pin $READSB_PIN; run this step without --verify"
  [[ $(stamp_field "$READSB_STAMP" recipe) == "$READSB_RECIPE" ]] \
    || die "the stamp does not name the recipe '$READSB_RECIPE'; run this step without --verify"
  [[ $(stamp_field "$READSB_STAMP" sha256) == "$(sha256_of "$READSB_BIN")" ]] \
    || die "$READSB_BIN is not the binary the stamp recorded; something replaced it. Run this step without --verify"
  pass "$READSB_BIN is a source build at $READSB_PIN ($READSB_RECIPE), owned by no package, linked to librtlsdr"

  # The unit in force, its enablement, and the process running what is installed.
  # readsb's InvocationID now, before the streaming checks, for check_tuner.
  local frag links reason inv0
  inv0=$(systemctl show -p InvocationID --value readsb 2>/dev/null) || inv0=
  frag=$(systemctl show -p FragmentPath --value readsb 2>&1) || true
  links=$(enable_links)
  log "readsb.service: FragmentPath=$frag; enablement symlinks (raw): ${links:-(none)}"
  [[ $frag == "$UNIT_FILE" ]] || die "systemd loads readsb from '$frag', not $UNIT_FILE; run this step without --verify"
  enabled_at_etc || die "readsb is not enabled through $UNIT_FILE; run this step without --verify"

  # The restart backoff is the one systemd has loaded: the drop-in is in
  # DropInPaths, and the values in force are the drop-in's, which also catches
  # a later drop-in overriding ours. The printed forms (5, 2min, 0) are what
  # systemd 259 prints for these settings (seen 2026-10-05). On the Pi's 257,
  # before this drop-in, `systemctl show readsb` printed StartLimitIntervalUSec=1s,
  # RestartMaxDelayUSec=infinity and RestartSteps=0 (read 2026-10-05): the same
  # human timespan family. `2min` itself is unobserved on 257 until this step runs.
  local dropins props p want got
  [[ -f $DROPIN ]] || die "$DROPIN is missing; run this step without --verify"
  dropins=$(systemctl show -p DropInPaths --value readsb 2>&1) || true
  props=$(systemctl show -p RestartUSec -p RestartSteps -p RestartMaxDelayUSec -p StartLimitIntervalUSec readsb 2>&1 | tr '\n' ' ') || true
  log "readsb.service: DropInPaths=${dropins:-(none)}; $props(raw)"
  [[ " $dropins " == *" $DROPIN "* ]] \
    || die "$DROPIN exists but systemd has not loaded it (DropInPaths='$dropins'; no daemon-reload since it changed?); run this step without --verify"
  for p in RestartSteps=5 RestartMaxDelayUSec=2min StartLimitIntervalUSec=0; do
    want=${p#*=}
    got=$(systemctl show -p "${p%%=*}" --value readsb 2>&1) || true
    [[ $got == "$want" ]] \
      || die "readsb's ${p%%=*} is '$got', not '$want' from $DROPIN (a later drop-in overriding it, or no daemon-reload); check: systemctl cat readsb"
  done
  pass "systemd has loaded the restart backoff drop-in $DROPIN: RestartSteps=5, RestartMaxDelayUSec=2min, StartLimitIntervalUSec=0"

  if systemctl is-active --quiet readsb; then
    reason=$(readsb_restart_reason)
    [[ -z $reason ]] || die "$reason; run this step without --verify, which restarts it"
    pass "readsb runs the installed binary, with the current unit, drop-in and defaults, in plugdev"
  fi

  # The radio streams: aircraft.json's clock moves, and the sample counter
  # climbs. Neither needs an aircraft in the sky.
  local ac=$JSON_DIR/aircraft.json st=$JSON_DIR/stats.json now1 now2
  now1=$(wait_for_field "$ac" now 20) || die_not_streaming "$ac has no readable 'now' after 20 s"
  sleep 3
  now2=$(json_field "$ac" now)
  log "aircraft.json now: $now1, then 3 s later: ${now2:-?}"
  if ! awk -v a="$now1" -v b="${now2:-0}" 'BEGIN { exit !(b > a) }'; then
    die_not_streaming "aircraft.json's now did not advance in 3 s"
  fi
  pass "aircraft.json is advancing"

  # total.local.samples_processed: the name in readsb's stats.c at the pin. The
  # "local" block exists only when readsb has an SDR. stats.json is rewritten
  # every 10 s at this pin (statsUpdate), not every second: it can take up to
  # 30 s to appear after a restart, and up to 25 s more to change.
  local s1 s2 i
  s1=$(wait_for_field "$st" total.local.samples_processed 30) \
    || die_not_streaming "$st has no total.local.samples_processed after 30 s, so readsb reports no SDR"
  s2=$s1
  for ((i = 0; i < 25; i++)); do
    sleep 1
    s2=$(json_field "$st" total.local.samples_processed)
    [[ -n $s2 ]] && awk -v a="$s1" -v b="$s2" 'BEGIN { exit !(b > a) }' && break
  done
  log "stats.json total.local.samples_processed: $s1, then ${s2:-?} (after up to 25 s)"
  awk -v a="$s1" -v b="${s2:-0}" 'BEGIN { exit !(b > a) }' \
    || die_not_streaming "the sample counter did not climb in 25 s: the stick is not streaming"
  pass "the SDR is streaming: samples_processed climbed"

  # Which stick readsb opened, from its own open (check_tuner).
  check_tuner "$inv0"

  # Printed, not judged: an empty sky is not a broken install.
  log "aircraft.json messages: $(json_field "$ac" messages), aircraft: $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("aircraft", [])))' "$ac" 2>/dev/null || echo '?') (raw, not judged)"

  # readsb's sockets (render_readsb, ruled 2026-10-10): every listener on its
  # ports binds to loopback, the input ports are closed, and 127.0.0.1:30005,
  # the BEAST output the archive writer and update.sh's probe connect to, is
  # listening and sends data. Read from `ss`, after the streaming checks, so
  # readsb has been up for some seconds. Judged on the port set, not the owner:
  # whatever holds one of these ports beyond loopback is the exposure, whether
  # or not it is readsb.
  local ss_out laddr addr port seen='' offlo='' inputs='' bo_v4=0 bo_else='' bo_rc bo_fd
  ss_out=$(ss -ltnH 2>&1) || die "ss -ltnH failed: $ss_out"
  while read -r _ _ _ laddr _; do
    [[ -n $laddr ]] || continue
    port=${laddr##*:}
    case $port in 30001|30002|30003|30004|30005|30104) ;; *) continue ;; esac
    seen+="$laddr "
    # 127.0.0.1:30005, [::1]:30005, 0.0.0.0:30005, [::]:30005, *:30005; an
    # address may carry a %interface suffix, outside the brackets
    # ([::1]%lo:30005) or inside them. The suffix goes first, then the
    # brackets. Fail-closed: any form that does not reduce to exactly
    # 127.0.0.1 or ::1 counts as beyond loopback.
    addr=${laddr%:*}
    addr=${addr%%\%*}
    addr=${addr#\[}
    addr=${addr%\]}
    if [[ $addr != 127.0.0.1 && $addr != ::1 ]]; then
      offlo+="$laddr "
    fi
    if [[ $port == 30005 ]]; then
      if [[ $addr == 127.0.0.1 ]]; then bo_v4=1; else bo_else+="$laddr "; fi
    fi
    case $port in
      30001|30004|30104) inputs+="$laddr " ;;
    esac
  done <<<"$ss_out"
  log "ss -ltnH, listeners on readsb's ports 30001-30005 and 30104 (raw): ${seen:-(none)}"
  [[ -z $offlo ]] \
    || die "listening beyond loopback on readsb's ports: ${offlo% }. /etc/default/readsb binds readsb to 127.0.0.1; run this step without --verify, which rewrites it and restarts readsb. If it is already current, another program holds the port: check: ss -ltnp"
  [[ -z $inputs ]] \
    || die "readsb's input ports are open: ${inputs% }. /etc/default/readsb opens none; run this step without --verify, which rewrites it and restarts readsb. If it is already current, check: ss -ltnp"
  if ((bo_v4 == 0)); then
    if [[ -n $bo_else ]]; then
      die "port 30005, readsb's BEAST output, listens only on ${bo_else% }, not on 127.0.0.1, which the archive writer and update.sh connect to; check: /etc/default/readsb's NET_OPTIONS, and systemctl status readsb"
    fi
    die "nothing listens on port 30005 at all, readsb's BEAST output, which the archive writer and update.sh connect to on 127.0.0.1; check: systemctl status readsb, and /etc/default/readsb's NET_OPTIONS"
  fi
  # The effect, as update.sh's readiness probe sees it (a connect to
  # 127.0.0.1:30005), plus one byte read: readsb sends a BEAST keepalive about
  # every 6 s with an empty sky (bin/adsb-writer), so 10 s is enough. Exit 2:
  # the connect failed; 3: the connection closed before a byte; 124: no byte
  # within 10 s. The connect is this shell's own, closed right after the read;
  # the read is `head`, timeout's direct child, so a timeout kills the process
  # reading the socket and leaves no client connected to readsb.
  bo_rc=0
  if { exec {bo_fd}<>/dev/tcp/127.0.0.1/30005; } 2>/dev/null; then
    timeout 10 head -c 1 <&"$bo_fd" >"$WORK/bo.byte" 2>/dev/null || bo_rc=$?
    exec {bo_fd}>&-
    if ((bo_rc == 0)) && [[ ! -s $WORK/bo.byte ]]; then bo_rc=3; fi
  else
    bo_rc=2
  fi
  log "connect to 127.0.0.1:30005 and read one byte: exit $bo_rc (0 a byte came; 2 no connect; 3 closed with nothing; 124 nothing in 10 s)"
  ((bo_rc == 0)) \
    || die "127.0.0.1:30005, readsb's BEAST output, did not send a byte within 10 s of a connect (exit $bo_rc); check: systemctl status readsb"
  pass "on readsb's ports, nothing listens beyond loopback and no input port is open; 127.0.0.1:30005 accepted a connect and sent a byte within 10 s"

  # tar1090: the pinned version is installed, its page is served, and its data
  # path serves readsb's current aircraft.json.
  local want got head code served local_now
  head=$(git -C "$TAR1090_SRC" rev-parse HEAD 2>/dev/null) || true
  want=$(tar1090_expected_version) || true
  got=$(tar1090_installed_version) || true
  log "tar1090: stamp sha $(stamp_field "$TAR1090_STAMP" sha), $TAR1090_SRC at ${head:-?}, html/version.json tar1090Version ${got:-?} (want ${want:-?})"
  [[ $(stamp_field "$TAR1090_STAMP" sha) == "$TAR1090_PIN" && $head == "$TAR1090_PIN" ]] \
    || die "tar1090 is not installed from the pin $TAR1090_PIN; run this step without --verify"
  [[ -n $want && $got == "$want" ]] \
    || die "the installed tar1090 is '${got:-none}', not '$want'; run this step without --verify"
  pass "tar1090 is the pinned version, $got"

  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "$TAR1090_URL" 2>&1) || true
  log "curl $TAR1090_URL: HTTP $code"
  [[ $code == 200 ]] || die "$TAR1090_URL did not return 200; check: systemctl status lighttpd, and ls /etc/lighttpd/conf-enabled"
  out=$(curl -fsS --max-time 10 "${TAR1090_URL}data/aircraft.json" 2>&1) \
    || die "${TAR1090_URL}data/aircraft.json is not served: $out"
  printf '%s\n' "$out" >"$WORK/served.json"
  served=$(json_field "$WORK/served.json" now)
  local_now=$(json_field "$ac" now)
  log "aircraft.json now: served ${served:-?}, readsb's own ${local_now:-?}"
  [[ -n $served ]] \
    || die "${TAR1090_URL}data/aircraft.json is not readsb's aircraft.json (no 'now'); check the data alias in /etc/lighttpd/conf-enabled/88-tar1090.conf"
  # readsb writes it every second (--write-json-every 1): 5 s apart is stale.
  awk -v a="$served" -v b="${local_now:-0}" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 5) }' \
    || die "the served aircraft.json is not readsb's current one (now $served against $local_now); check the data alias in /etc/lighttpd/conf-enabled/88-tar1090.conf"
  pass "tar1090 is served at $TAR1090_URL, and its data path serves readsb's current aircraft.json"
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
