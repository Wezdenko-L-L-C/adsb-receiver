#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 05-config: station.yml into /etc, the adsb-receiver user, the adsb-operator
# group, and the tmpfiles.d entry for the recording lock. PLAN §9d, and §9m
# "05-config, widened".
#
# Shared by both rigs, so it asserts no role. It does read station.yml, to
# refuse installing one that does not parse or names no valid station.role.
#
#   setup/steps/05-config.sh            install, then verify
#   setup/steps/05-config.sh --verify   verify only
#
# As of 2026-10-04, nothing in this step has run on hardware.
#
# What it installs:
#   - config/station.yml -> /etc/adsb-receiver/station.yml, root:root 0600.
#   - Group adsb-operator (system). Its members are meant to read and delete
#     on the archive drive without root, once step 30's 2770 directories and
#     the writer's UMask=0007 exist (PLAN §9m).
#   - User adsb-receiver (system, no home, no login shell). It owns what is
#     written to the archive. An existing user with the wrong primary group or
#     shell is repaired; one with a UID outside the system range is refused,
#     never renumbered. ℹ️ Its PRIMARY group is adsb-operator: that is a
#     choice made here, not in PLAN §9m, so that anything it creates outside a
#     setgid directory is still group adsb-operator.
#   - The installing user (SUDO_USER) joins adsb-operator (Chris, 2026-10-04).
#   - /etc/tmpfiles.d/adsb-receiver.conf: /run/adsb-receiver and the recording
#     lock file, /run/adsb-receiver/recording.lock (PLAN §9f, §9i).

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"

SRC_YML=$ADSB_REPO/config/station.yml
DST_YML=$ADSB_ETC/station.yml
TMPFILES=/etc/tmpfiles.d/adsb-receiver.conf
RUN_DIR=/run/adsb-receiver
LOCK=$RUN_DIR/recording.lock
USER_NAME=adsb-receiver
GROUP_NAME=adsb-operator

# A missing yaml module would otherwise surface as a traceback blamed on the config.
command -v python3 >/dev/null || die "python3 is missing: apt install python3"
python3 -c 'import yaml' 2>/dev/null || die "python3-yaml is missing: apt install python3-yaml"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# in_group_db <user>: the user is in GROUP_NAME in the group database. No
# `grep -q` at the end of a pipe: under pipefail its early exit can fail the pipe.
in_group_db() {
  local g
  g=$(id -nG "$1" 2>/dev/null) || return 1
  [[ " $g " == *" $GROUP_NAME "* ]]
}

# sys_uid_max: Debian's login.defs leaves SYS_UID_MAX commented out, and 999 is
# its documented default.
sys_uid_max() {
  local m
  m=$(awk '$1 == "SYS_UID_MAX" { print $2 }' /etc/login.defs 2>/dev/null | tail -n1) || true
  echo "${m:-999}"
}

# validate_station <file>: parses as YAML, and station.role is portable or
# stationary. Prints the role.
validate_station() {
  python3 - "$1" <<'PY'
import sys, yaml
try:
    with open(sys.argv[1]) as fh:
        doc = yaml.safe_load(fh)
except Exception as e:
    print(f"{sys.argv[1]} does not parse as YAML: {e}", file=sys.stderr)
    sys.exit(1)
station = doc.get("station") if isinstance(doc, dict) else None
role = station.get("role") if isinstance(station, dict) else None
if role not in ("portable", "stationary"):
    print(f"{sys.argv[1]}: station.role is {role!r}; it must be portable or stationary", file=sys.stderr)
    sys.exit(1)
print(role)
PY
}

# install_if_changed <src> <dst> <mode> <owner:group>: render, diff, install
# (PLAN §9f). Installs only when the content, mode or owner differs, and logs
# which.
install_if_changed() {
  local src=$1 dst=$2 mode=$3 owner=$4
  guard_path "$dst"
  if [[ -f $dst ]] && cmp -s "$src" "$dst" \
     && [[ $(stat -c '%U:%G %a' "$dst") == "$owner ${mode#0}" ]]; then
    log "$dst is unchanged"
    return 0
  fi
  run install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dst"
  log "$dst changed; installed"
}

install_station_yml() {
  if [[ ! -f $SRC_YML ]]; then
    # Under update.sh the step runs from a fresh worktree, where the gitignored
    # config/station.yml does not exist (PLAN §9f, §9d; update.sh is not
    # written yet). The installed copy
    # is then the config.
    if [[ -f $DST_YML ]]; then
      log "no $SRC_YML in this checkout; keeping the installed $DST_YML"
      return 0
    fi
    die "no config/station.yml and no $DST_YML. Run: cp config/station.<role>.example.yml config/station.yml, edit it, then run this step again"
  fi
  local role
  role=$(validate_station "$SRC_YML") || die "refusing to install $SRC_YML; fix it and run this step again"
  log "$SRC_YML parses; station.role: $role"
  guard_path "$ADSB_ETC"
  if [[ ! -d $ADSB_ETC ]]; then
    run install -d -m 0755 -o root -g root "$ADSB_ETC"
  fi
  install_if_changed "$SRC_YML" "$DST_YML" 0600 root:root
}

install_group_and_user() {
  # getent first: groupadd and useradd fail on names that already exist (PLAN §9m).
  if getent group "$GROUP_NAME" >/dev/null; then
    log "group $GROUP_NAME exists"
  else
    run groupadd --system "$GROUP_NAME"
  fi
  local pw uid gid shell ggid max
  if pw=$(getent passwd "$USER_NAME"); then
    log "user $USER_NAME exists: $pw"
    IFS=: read -r _ _ uid gid _ _ shell <<<"$pw"
    max=$(sys_uid_max)
    # ⛔ Never renumbered: files on the drive carry the UID.
    if ! ((uid > 0 && uid <= max)); then
      die "$USER_NAME exists with UID $uid, outside the system range 1-$max, so this step did not make it. Check what it owns (find / -xdev -uid $uid), then remove it by hand (userdel $USER_NAME) and run this step again"
    fi
    ggid=$(getent group "$GROUP_NAME" | cut -d: -f3)
    if [[ $gid != "$ggid" ]]; then
      run usermod -g "$GROUP_NAME" "$USER_NAME"
      log "$USER_NAME's primary group was GID $gid; it is now $GROUP_NAME"
    fi
    if [[ $shell != /usr/sbin/nologin ]]; then
      run usermod -s /usr/sbin/nologin "$USER_NAME"
      log "$USER_NAME's shell was $shell; it is now /usr/sbin/nologin"
    fi
  else
    run useradd --system --no-create-home --home-dir /nonexistent \
      --shell /usr/sbin/nologin --gid "$GROUP_NAME" "$USER_NAME"
  fi

  # The installing user joins the group (Chris, 2026-10-04). Under update.sh
  # from a timer, or from a root shell, there is no SUDO_USER, and nobody is
  # added.
  if [[ -z ${SUDO_USER:-} || $SUDO_USER == root ]]; then
    log "no SUDO_USER (a timer or a root shell): adding nobody to $GROUP_NAME"
    return 0
  fi
  if in_group_db "$SUDO_USER"; then
    log "$SUDO_USER is already in $GROUP_NAME"
  else
    run usermod -aG "$GROUP_NAME" "$SUDO_USER"
    log "$SUDO_USER joined $GROUP_NAME. It takes effect at $SUDO_USER's next login."
  fi
}

install_tmpfiles() {
  # The lock file is created here, not by its users, so neither root's
  # update.sh nor the writer races to create it. It is believed, not checked
  # here, that flock(1) can lock a file it opened read-only, so that 0644 is
  # enough for both. On tmpfs: a crash or a
  # reboot leaves no stale lock (PLAN §9m).
  cat >"$WORK/tmpfiles.conf" <<EOF
# Rendered by setup/steps/05-config.sh. Do not edit; re-run the step.
# The recording lock (PLAN §9f, §9i, §9m).
d $RUN_DIR 0755 $USER_NAME $GROUP_NAME -
f $LOCK 0644 $USER_NAME $GROUP_NAME -
EOF
  install_if_changed "$WORK/tmpfiles.conf" "$TMPFILES" 0644 root:root
  # Changes nothing when the directory and file are already right.
  run systemd-tmpfiles --create "$TMPFILES"
}

install_step() {
  install_station_yml
  install_group_and_user
  # After the user and group exist: tmpfiles.d names them.
  install_tmpfiles
}

# --- verify --------------------------------------------------------------------

verify() {
  local out role
  log "stat $DST_YML (raw output follows)"
  out=$(stat -c '%U:%G %a %n' "$DST_YML" 2>&1) || true
  printf '%s\n' "$out"
  echo "----"
  [[ -f $DST_YML ]] || die "$DST_YML does not exist; run this step without --verify"
  [[ $out == "root:root 600 "* ]] || die "$DST_YML must be root:root 0600; run this step without --verify"
  role=$(validate_station "$DST_YML") || die "the installed $DST_YML is not valid; fix config/station.yml and run this step"
  pass "$DST_YML is root:root 0600, parses, and says station.role: $role"

  # The user: a system UID and no login shell.
  local pw uid gid shell sys_max
  log "getent passwd $USER_NAME; id $USER_NAME (raw output follows)"
  pw=$(getent passwd "$USER_NAME") || true
  printf '%s\n' "${pw:-(no entry)}"
  id "$USER_NAME" 2>&1 || true
  echo "----"
  [[ -n $pw ]] || die "no user $USER_NAME; run this step without --verify"
  IFS=: read -r _ _ uid gid _ _ shell <<<"$pw"
  sys_max=$(sys_uid_max)
  ((uid > 0 && uid <= sys_max)) || die "$USER_NAME has UID $uid, outside the system range 1-$sys_max"
  [[ $shell == */nologin ]] || die "$USER_NAME has login shell $shell; it must have none (nologin)"

  # The group, and who is in it besides adsb-receiver.
  local gr ggid members m others=()
  log "getent group $GROUP_NAME (raw output follows)"
  gr=$(getent group "$GROUP_NAME") || true
  printf '%s\n' "${gr:-(no entry)}"
  echo "----"
  [[ -n $gr ]] || die "no group $GROUP_NAME; run this step without --verify"
  IFS=: read -r _ _ ggid members <<<"$gr"
  [[ $gid == "$ggid" ]] || die "$USER_NAME's primary group is GID $gid, not $GROUP_NAME ($ggid)"
  pass "$USER_NAME is a system user (UID $uid of max $sys_max), shell $shell, primary group $GROUP_NAME"
  IFS=, read -r -a members <<<"$members"
  for m in "${members[@]}"; do
    [[ -n $m && $m != "$USER_NAME" ]] && others+=("$m")
  done
  ((${#others[@]})) || die "$GROUP_NAME has no members besides $USER_NAME. On a first build, run this step with sudo from the login you pull with. Under update.sh there is no SUDO_USER, so nobody can be added: run it by hand, with sudo, from that login"
  pass "$GROUP_NAME members: ${others[*]}"
  check_login_has_group "$ggid"

  # The tmpfiles.d result, on tmpfs.
  log "stat $RUN_DIR $LOCK (raw output follows)"
  stat -c '%U:%G %a %F %n' "$RUN_DIR" "$LOCK" 2>&1 || true
  echo "----"
  [[ -d $RUN_DIR && $(stat -c '%U:%G %a' "$RUN_DIR") == "$USER_NAME:$GROUP_NAME 755" ]] \
    || die "$RUN_DIR is missing or not $USER_NAME:$GROUP_NAME 0755; run: systemd-tmpfiles --create $TMPFILES"
  [[ -f $LOCK && $(stat -c '%U:%G %a' "$LOCK") == "$USER_NAME:$GROUP_NAME 644" ]] \
    || die "$LOCK is missing or not $USER_NAME:$GROUP_NAME 0644; run: systemd-tmpfiles --create $TMPFILES"
  pass "$RUN_DIR and $LOCK exist, $USER_NAME:$GROUP_NAME, 0755 and 0644"
}

# check_login_has_group <gid>: a new group membership reaches a login only at
# its next login. Under sudo this process has root's groups, not the login's,
# so `id -nG` here would prove nothing. Instead, read the groups of the nearest
# ancestor process whose real AND effective UIDs are both SUDO_UID, which is
# the login's shell. The sudo process itself has real UID SUDO_UID but
# effective UID 0 and root's groups (seen on the Pi, 2026-10-04), so a match on
# the real UID alone stops there; requiring both skips it and setuid helpers.
check_login_has_group() {
  local want=$1 pid ruid euid groups
  [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] || return 0
  if ! in_group_db "$SUDO_USER"; then
    warn "$SUDO_USER, who ran this, is not in $GROUP_NAME. To add this login, run this step without --verify, with sudo, from it"
    return 0
  fi
  pid=$PPID
  while ((pid > 1)); do
    # Uid: real, effective, saved, filesystem.
    read -r ruid euid < <(awk '/^Uid:/ { print $2, $3 }' "/proc/$pid/status" 2>/dev/null) || break
    if [[ -n ${SUDO_UID:-} && $ruid == "$SUDO_UID" && $euid == "$SUDO_UID" ]]; then
      groups=$(awk '/^Groups:/ { $1 = ""; print }' "/proc/$pid/status")
      log "groups of $SUDO_USER's process $pid (raw, numeric): $groups"
      if [[ " $groups " == *" $want "* ]]; then
        pass "$SUDO_USER's current login already carries $GROUP_NAME"
      else
        warn "$SUDO_USER is in $GROUP_NAME in the group database, but this login is not. Log out and in again"
      fi
      return 0
    fi
    pid=$(awk '/^PPid:/ { print $2 }' "/proc/$pid/status" 2>/dev/null) || break
  done
  warn "could not find a process of $SUDO_USER's login, so cannot tell whether it needs a fresh login"
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
