#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 45-uploader: install bin/adsb-uploader, its configuration and its timer,
# which every 10 minutes copies the writer's closed files to the archive's
# off-site store, checks each there by size and MD5, and deletes the local copy
# only once it checks. Issue #1; PLAN §9i ("Update 2026-11-22: the uploader, to
# a Google Drive shared drive"); the mirror rule in §9m.
#
# Stationary only, for now: asserts station.role. Both rigs get the uploader
# (Chris, 2026-10-10, PLAN §9i); the 🎒 portable's needs the at-home and
# metered-link guards §9i records, which are not built, so its gate stays
# until they are. The portable template's own uploader: block is untouched.
#
#   setup/steps/45-uploader.sh            install, then verify
#   setup/steps/45-uploader.sh --verify   verify only
#
# station.yml's uploader: block (config/station.stationary.example.yml):
#   enabled          true or false. false: the units are installed and the
#                    timer is stopped and disabled; nothing uploads.
#   shared_drive_id  the store's shared drive ID. ⛔ Never in this repo
#                    (PLAN §9m, B): station.yml is gitignored and root-only.
#   root_folder      a folder path in that drive standing for the store's
#                    root, or "" for its top level.
# Rendered into /etc/adsb-receiver/uploader.conf, root:root 0644: neither key
# is a secret, and the unit's dynamic user must read it.
#
# The credential: /etc/adsb-receiver/uploader-sa.json, a Google Cloud service
# account's JSON key, put on the rig by hand (BUILD.md §8 step 4b), root:root
# 0600. The step checks it is a service account key and prints its
# client_email, never anything else from it; with enabled: true and no valid
# key, the step fails and says how to add one. The unit hands it to the
# uploader by LoadCredential= (systemd.exec(5)), so the uploader's user never
# opens the root-only file. ⚠️ Belief, from systemd.exec(5), not seen on the
# Pi: LoadCredential= works with DynamicUser= on the Pi's systemd 257.
#
# The unit, adsb-uploader.service, a oneshot:
#   - DynamicUser=yes with SupplementaryGroups=adsb-operator: a user that
#     exists only while it runs, in the group that owns the archive's files
#     (0660) and directories (2770), so it can read the closed files and
#     delete them, and nothing of the writer's. NoNewPrivileges=yes, so the
#     group's sudoers rule (step 05) can never be used by it, as for the writer.
#   - ProtectSystem=strict; the one path it writes is the archive's beast/
#     (ReadWritePaths=, "-" so a missing drive does not fail the namespace:
#     the uploader then finds no mount point and exits 0). StateDirectory= for
#     its state.json, CacheDirectory= for rclone's cache and its file list.
#   - After= and Wants= network-online.target, and After= the archive's mount.
#   - Nice=10 and IOSchedulingClass=idle: recording comes first.
#   - TimeoutStartSec=3h: a backlog after an outage is sent across runs
#     (MAX_FILES per run in the uploader), each bounded. The uploader's own
#     COPY_TIMEOUT_S (2 h) is kept shorter, so the check and the deletes
#     still run inside this bound after a long copy.
# The timer: 10 minutes after boot, then 10 minutes after each run started,
# monotonic, as the burst timer is (20-portable-clock's header): the writer
# closes a file every 10 minutes.
#
# ⛔ The verify never judges the network or the store (PLAN §9c): the
#    uploader's --check is readiness, and its exit 2 passes the install tier;
#    the last run's result is printed, not judged, since a dropped Wi-Fi link is
#    not a broken install.
#
# What has run on hardware is recorded in PLAN §9i, not here (PLAN §9c: no
# script carries a "tested on" header).

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"
require_role stationary

for t in python3 systemctl systemd-analyze systemd-escape cmp; do
  command -v "$t" >/dev/null || die "$t is not installed"
done

GROUP_NAME=adsb-operator
getent group "$GROUP_NAME" >/dev/null || die "no group $GROUP_NAME: run setup/steps/05-config.sh first"

PKGS=(rclone)
SRC=$ADSB_REPO/bin/adsb-uploader
UPLOADER=/usr/local/bin/adsb-uploader
CONF=$ADSB_ETC/uploader.conf
CRED=$ADSB_ETC/uploader-sa.json
UNIT_DIR=/etc/systemd/system
SERVICE=adsb-uploader.service
TIMER=adsb-uploader.timer
MP=/var/lib/adsb-receiver/archive
MOUNT_UNIT=$(systemd-escape --path --suffix=mount "$MP")

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

pkg_installed() {
  local s
  s=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1
  [[ $s == "install ok installed" ]]
}

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

# read_block: the uploader: block, validated by the uploader's own rules (its
# read_conf and check_root). Sets ENABLED (true/false) and renders
# $WORK/uploader.conf when enabled. With enabled: false the other keys may be
# null, and no conf is rendered.
ENABLED=false
read_block() {
  local f out
  f=$(station_file) || die "no station.yml: run setup/steps/05-config.sh"
  out=$(python3 - "$f" "$SRC" "$WORK/uploader.conf" <<'PY'
import importlib.machinery, importlib.util, sys, yaml
yml, src, conf = sys.argv[1:4]
loader = importlib.machinery.SourceFileLoader("adsb_uploader", src)
spec = importlib.util.spec_from_loader("adsb_uploader", loader)
U = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
loader.exec_module(U)
with open(yml) as fh:
    doc = yaml.safe_load(fh)
b = doc.get("uploader") if isinstance(doc, dict) else None
if not isinstance(b, dict):
    sys.exit("station.yml has no uploader: block: add it from config/station.stationary.example.yml")
en = b.get("enabled")
if not isinstance(en, bool):
    sys.exit(f"uploader.enabled must be true or false, not {en!r}")
if not en:
    print("false")
    sys.exit(0)
did, root = b.get("shared_drive_id"), b.get("root_folder")
root = "" if root is None else root
if not isinstance(did, str) or not U.DRIVE_ID_RE.fullmatch(did):
    sys.exit("uploader.shared_drive_id is missing or not a shared drive's ID (the last part of its URL)")
if not isinstance(root, str):
    sys.exit("uploader.root_folder must be text, or \"\" for the drive's top level")
try:
    U.check_root(root)
except U.ConfError as e:
    sys.exit(f"uploader.root_folder: {e}")
with open(conf, "w") as fh:
    fh.write("# Rendered by setup/steps/45-uploader.sh from station.yml's uploader: block.\n"
             "# Do not edit; edit station.yml and re-run the step. Read by adsb-uploader.\n"
             f"drive_id={did}\nroot={root}\n")
print("true")
PY
  ) || die "station.yml's uploader: block is not valid (above); fix it, then run this step again"
  ENABLED=$out
}

# check_cred: the key exists, is root:root 0600, and is a service account key.
# Prints its client_email only.
check_cred() {
  local email
  if [[ ! -f $CRED || -L $CRED ]]; then
    cat >&2 <<EOF
    uploader.enabled is true, and there is no service account key at $CRED.
    Put the key there by hand (BUILD.md §8 step 4b), then run this step again:
      sudo install -m 0600 -o root -g root <the downloaded key>.json $CRED
      shred -u <the downloaded key>.json
EOF
    die "no service account key at $CRED"
  fi
  [[ $(stat -c '%U:%G %a' "$CRED") == "root:root 600" ]] \
    || die "$CRED is $(stat -c '%U:%G %a' "$CRED"), not root:root 600: sudo chown root:root $CRED; sudo chmod 0600 $CRED"
  email=$(python3 - "$SRC" "$CRED" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("adsb_uploader", sys.argv[1])
spec = importlib.util.spec_from_loader("adsb_uploader", loader)
U = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
loader.exec_module(U)
try:
    print(U.check_credential(sys.argv[2]))
except U.ConfError as e:
    sys.exit(str(e))
PY
  ) || die "$CRED is not a usable service account key (above)"
  log "$CRED: a service account key for $email (add that address to the store's shared drive as a Contributor)"
}

render_service() {
  cat >"$WORK/service" <<EOF
# Rendered by setup/steps/45-uploader.sh. Do not edit; re-run the step.
# Copies the writer's closed files to the store, checks each by size and MD5,
# and deletes the local copy only once it checks. Why each setting, in the
# step's header. PLAN §9i.
[Unit]
Description=adsb-receiver uploader: closed archive files to the store, checked, then removed
Wants=network-online.target
After=network-online.target $MOUNT_UNIT

[Service]
Type=oneshot
ExecStart=$UPLOADER
DynamicUser=yes
SupplementaryGroups=$GROUP_NAME
LoadCredential=sa.json:$CRED
StateDirectory=adsb-uploader
CacheDirectory=adsb-uploader
UMask=0007
NoNewPrivileges=yes
CapabilityBoundingSet=
ProtectSystem=strict
ReadWritePaths=-$MP/beast
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=3h
EOF
}

render_timer() {
  cat >"$WORK/timer" <<'EOF'
# Rendered by setup/steps/45-uploader.sh. Do not edit; re-run the step.
# 10 min after boot, then 10 min after each run started: monotonic time, so a
# step in the wall clock does not move it. The writer closes a file every 10
# minutes.
[Unit]
Description=adsb-receiver uploader timer, every 10 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF
}

need_reload() {
  local u
  for u in "$SERVICE" "$TIMER"; do
    [[ $(systemctl show -p NeedDaemonReload --value "$u" 2>/dev/null) == yes ]] && return 0
  done
  return 1
}

install_step() {
  [[ -f $SRC ]] || die "$SRC is missing from this checkout"
  read_block
  apt_ensure "${PKGS[@]}"
  install_if_changed "$SRC" "$UPLOADER" 0755 root:root
  if [[ $ENABLED == true ]]; then
    check_cred
    install_if_changed "$WORK/uploader.conf" "$CONF" 0644 root:root
  fi
  local svc_changed timer_changed
  render_service
  render_timer
  install_if_changed "$WORK/service" "$UNIT_DIR/$SERVICE" 0644 root:root
  svc_changed=$CHANGED
  install_if_changed "$WORK/timer" "$UNIT_DIR/$TIMER" 0644 root:root
  timer_changed=$CHANGED
  if ((svc_changed || timer_changed)) || need_reload; then
    run systemctl daemon-reload
  fi
  if [[ $ENABLED == true ]]; then
    systemctl is-enabled --quiet "$TIMER" || unit enable "$TIMER"
    if ! systemctl is-active --quiet "$TIMER"; then
      unit start "$TIMER"
    elif ((timer_changed)); then
      unit restart "$TIMER"
    fi
  else
    log "uploader.enabled is false: the timer is stopped and disabled; nothing uploads"
    if systemctl is-active --quiet "$TIMER"; then unit stop "$TIMER"; fi
    if systemctl is-enabled --quiet "$TIMER" 2>/dev/null; then unit disable "$TIMER"; fi
  fi
}

# --- verify --------------------------------------------------------------------

verify() {
  local en ac rc out svc s_active s_result s_status s_started
  read_block

  # 1. The program is this checkout's.
  cmp -s "$SRC" "$UPLOADER" || die "$UPLOADER is missing or differs from $SRC; run this step without --verify"
  [[ $(stat -c '%U:%G %a' "$UPLOADER") == "root:root 755" ]] \
    || die "$UPLOADER is not root:root 0755; run this step without --verify"
  command -v rclone >/dev/null || die "rclone is not installed; run this step without --verify"
  log "rclone version (raw, first line): $(rclone version 2>&1 | head -n1)"
  pass "$UPLOADER matches this checkout, and rclone is installed"

  # 2. The units match their render, load, and pass systemd-analyze.
  render_service
  render_timer
  cmp -s "$WORK/service" "$UNIT_DIR/$SERVICE" \
    || die "$UNIT_DIR/$SERVICE is missing or differs from its render; run this step without --verify"
  cmp -s "$WORK/timer" "$UNIT_DIR/$TIMER" \
    || die "$UNIT_DIR/$TIMER is missing or differs from its render; run this step without --verify"
  verify_units "the uploader's units" "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$TIMER"
  ! need_reload || die "systemd has not read the current $SERVICE or $TIMER; run this step without --verify"
  pass "$SERVICE and $TIMER match their render, load, and pass systemd-analyze"

  # 3. The timer, by uploader.enabled.
  en=$(systemctl is-enabled "$TIMER" 2>&1) || true
  ac=$(systemctl is-active "$TIMER" 2>&1) || true
  log "$TIMER: is-enabled $en, is-active $ac; uploader.enabled: $ENABLED"
  if [[ $ENABLED != true ]]; then
    [[ $ac != active ]] || die "uploader.enabled is false, and $TIMER is active; run this step without --verify"
    [[ $en != enabled ]] || die "uploader.enabled is false, and $TIMER is enabled; run this step without --verify"
    pass "uploader.enabled is false, and the timer is stopped and disabled"
    return 0
  fi
  [[ $en == enabled ]] || die "$TIMER is '$en', not enabled; run this step without --verify"
  [[ $ac == active ]] || die "$TIMER is '$ac', not active; run this step without --verify"
  pass "$TIMER is enabled and active"

  # 4. The conf matches station.yml, and the key is a service account's.
  cmp -s "$WORK/uploader.conf" "$CONF" \
    || die "$CONF differs from what station.yml's uploader: block renders now; run this step without --verify"
  [[ $(stat -c '%U:%G %a' "$CONF") == "root:root 644" ]] \
    || die "$CONF is not root:root 0644; run this step without --verify"
  check_cred
  pass "$CONF matches station.yml, and $CRED is a root-only service account key"

  # 5. Readiness (PLAN §9c, §9i): 0 and 2 pass the install tier, 1 fails it.
  rc=0
  log "$UPLOADER --check --credential $CRED (raw output follows)"
  timeout 120 "$UPLOADER" --check --credential "$CRED" || rc=$?
  echo "----"
  case $rc in
    0) pass "adsb-uploader --check: ready" ;;
    2|124) warn "adsb-uploader --check: not ready (exit $rc): the store was not reached or refused; see above"
       pass "adsb-uploader --check ran (exit $rc passes the install tier, PLAN §9c)" ;;
    *) die "adsb-uploader --check could not run its check (exit $rc); see above" ;;
  esac

  # 6. The last run, as systemd recorded it: printed, never judged (the header).
  svc=$(LC_ALL=C systemctl show -p ActiveState -p Result -p ExecMainStatus \
          -p ExecMainStartTimestampMonotonic -p ExecMainExitTimestamp "$SERVICE" 2>&1) \
    || die "systemctl show $SERVICE failed: $svc"
  s_active=$(sed -n 's/^ActiveState=//p' <<<"$svc")
  s_result=$(sed -n 's/^Result=//p' <<<"$svc")
  s_status=$(sed -n 's/^ExecMainStatus=//p' <<<"$svc")
  s_started=$(sed -n 's/^ExecMainStartTimestampMonotonic=//p' <<<"$svc")
  if [[ $s_active == activating ]]; then
    log "$SERVICE is running now"
  elif [[ -z $s_started || $s_started == 0 ]]; then
    log "$SERVICE has not run since boot"
  else
    log "$SERVICE's last run: Result=${s_result:-?}, exit ${s_status:-?} (0 all checked; 2 the store not reached or some files kept; 1 could not run). Its log: journalctl -u $SERVICE -n 50"
  fi
  pass "the uploader is installed and enabled; the last run's result is printed above, not judged"
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
