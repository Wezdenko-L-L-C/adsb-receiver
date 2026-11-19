#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 55-security: install unattended-upgrades, switched off on its own schedule, and the apt
# configuration setup/update.sh's security phase runs it with. PLAN §9h, "Update 2026-11-17:
# software outside the repo" (07:42 Q1–Q3; 08:04 for every rig) and the note under its denylist.
#
# Shared by both rigs (all rigs alike, 08:04), so it reads no station.yml and asserts no role.
#
#   setup/steps/55-security.sh            install, then verify
#   setup/steps/55-security.sh --verify   verify only
#
# What it installs, in this order:
#   - /etc/apt/apt.conf.d/52adsb-security, written before the package: APT::Periodic::Unattended-Upgrade
#     "0", read after 20auto-upgrades, so apt-daily-upgrade.timer never runs it outside the update
#     window, whatever 20auto-upgrades says (the preseed below decides only a first install's copy;
#     a rig that already has the package with 20auto-upgrades on is turned off by this file); and
#     the Unattended-Upgrade:: settings, each list cleared first (#clear) so the package's own
#     50unattended-upgrades adds nothing: the allowed origins are Debian-Security and the Raspberry
#     Pi archive; the never-touch list (kernel, firmware, EEPROM, Tailscale; 07:42 Q1, and §9h's
#     foundation layer) is Package-Blacklist; no automatic reboot.
#   - /etc/adsb-receiver/security/apt.conf, the APT_CONFIG file update.sh runs unattended-upgrade
#     with, and the preferences file it names: the Raspberry Pi archive pinned to 1 and its openssl,
#     libssl3t64, openssl-provider-legacy and wpasupplicant pinned to 500 (07:42 Q1's four).
#     unattended-upgrades restricts origins globally, never per package, so the pins are what
#     limit the Pi archive to the four. They are that run's alone: a global pin would also hold
#     back the kernel and firmware the by-hand round takes from that archive. Its dpkg options keep
#     a changed config file (--force-confold), as 07:42 Q2 has it.
#   - the package unattended-upgrades, with debconf's unattended-upgrades/enable_auto_updates
#     preseeded false first: its postinst otherwise writes /etc/apt/apt.conf.d/20auto-upgrades
#     turned on (the template's default; checked from the package, pick-up 0l(i), 2026-11-18).
#   Every file by write-then-rename in its own directory.
#
# Names, as the portable showed them over SSH (2026-11-18 19:38): the pin's `origin` keyword and
# unattended-upgrades' `site=` both match the host a package file was fetched from, the value
# apt-cache policy prints as "origin archive.raspberrypi.com". Neither is the Release file's Origin
# field, which for that archive is "Raspberry Pi Foundation" (Origins-Pattern's `origin=`).
#
# What verify() checks, as apt resolves it rather than as the files say it (each check can fail):
#   - apt-config dump, the system's: APT::Periodic::Unattended-Upgrade "0" or absent.
#   - apt-config dump under the security phase's APT_CONFIG: its Dir::Etc::Preferences and dpkg
#     options hold (no part overrides them), and the origins and never-touch list are exactly this
#     step's, with no reboot.
#   - apt-cache policy under it: the Raspberry Pi host is among the package files, every one of its
#     files at priority 1; the four, and nothing else, pinned at 500; raspberrypi-sys-mods (a
#     package only that archive has; chosen from the pins' meaning, not read on a rig) at 1 from
#     every one of that archive's files; the four's candidates non-empty and the system's.
#   - unattended-upgrade --dry-run -v under it: exit 0, the origins and blacklist it reports are
#     this step's, and nothing it would upgrade is on the never-touch list. A dry run downloads (does
#     not install) what it would upgrade, so with anything pending it needs the network; it is
#     bounded by DRY_RUN_TIMEOUT, and a timeout fails verify.
#
# WHAT THIS ENCODES: nothing of it has run on a Pi. The portable's state that prompted it (no
# unattended-upgrades; openssl's fix a Raspberry Pi rebuild, 3.5.7-1~deb13u3+rpt1, outranking
# Debian-Security's; wpasupplicant's only in the Pi archive) was read over SSH on 2026-11-17 (PLAN
# §9h, "What prompted it").

set -euo pipefail
# shellcheck source=setup/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

parse_args "$@"
require_root "$@"

readonly PKG=unattended-upgrades
readonly APT_PART=/etc/apt/apt.conf.d/52adsb-security
readonly SEC_DIR=$ADSB_ETC/security
readonly SEC_APT_CONF=$SEC_DIR/apt.conf
readonly SEC_PREFS=$SEC_DIR/preferences
readonly PI_HOST=archive.raspberrypi.com
readonly PI_FOUR="openssl libssl3t64 openssl-provider-legacy wpasupplicant"
# A package only the Raspberry Pi archive carries, so every file it is listed in is that archive's:
# under the phase's pins it must sit at 1 like everything there outside the four.
readonly PI_OTHER=raspberrypi-sys-mods
readonly DRY_RUN_TIMEOUT=600
# The allowed origins, as unattended-upgrades reads them (it substitutes ${distro_codename}).
# shellcheck disable=SC2016  # ${distro_codename} is unattended-upgrades' own, not the shell's
readonly -a ORIGINS=(
  'origin=Debian,codename=${distro_codename}-security,label=Debian-Security'
  "site=$PI_HOST"
)
# The never-touch list: regexes, matched at the start of the binary package name, so a bare name
# also covers its siblings (rpi-eeprom-images, raspi-firmware-nonfree); $ only where an exact name is
# meant (tailscale must not match a package that merely starts with it).
readonly -a BLACKLIST=(
  'linux-image-'
  'linux-headers-'
  'linux-kbuild-'
  'raspberrypi-kernel'
  'raspberrypi-bootloader'
  'raspi-firmware'
  'firmware-'
  'bluez-firmware'
  'rpi-eeprom'
  'rpi-update'
  'tailscale$'
  'tailscale-archive-keyring$'
)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

render_part() {
  local o b
  cat <<EOF
// Rendered by setup/steps/55-security.sh. Do not edit; re-run the step. PLAN §9h (07:42 Q1–Q3).
// Never on apt's own schedule: setup/update.sh's security phase runs unattended-upgrade in the
// update window, under the recording lock. This file sorts after 20auto-upgrades, so it wins.
APT::Periodic::Unattended-Upgrade "0";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::OnlyOnACPower "false";
Unattended-Upgrade::Skip-Updates-On-Metered-Connections "false";
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
// The second admits the whole Raspberry Pi archive here. The security phase's run alone reads
// $SEC_PREFS, whose pins leave only openssl, libssl3t64, openssl-provider-legacy and wpasupplicant
// installable from it; 55-security's verify checks those pins as apt resolves them.
Unattended-Upgrade::Origins-Pattern {
EOF
  for o in "${ORIGINS[@]}"; do printf '  "%s";\n' "$o"; done
  cat <<EOF
};
// Regexes, matched at the start of the binary package name; \$ where an exact name is meant.
#clear Unattended-Upgrade::Package-Blacklist;
Unattended-Upgrade::Package-Blacklist {
EOF
  for b in "${BLACKLIST[@]}"; do printf '  "%s";\n' "$b"; done
  echo '};'
}

render_conf() {
  cat <<EOF
// Rendered by setup/steps/55-security.sh. Do not edit; re-run the step. PLAN §9h (07:42 Q1, Q2).
// The APT_CONFIG of setup/update.sh's unattended-upgrade run, and of nothing else.
Dir::Etc::Preferences "$SEC_PREFS";
DPkg::Options { "--force-confdef"; "--force-confold"; };
EOF
}

render_prefs() {
  cat <<EOF
Explanation: Rendered by setup/steps/55-security.sh; read only by setup/update.sh's security phase.
Explanation: PLAN §9h, 07:42 Q1: from the Raspberry Pi archive, these four and nothing else.
Explanation: "origin" here is apt's host keyword (the host a package file is fetched from).
Package: $PI_FOUR
Pin: origin $PI_HOST
Pin-Priority: 500

Package: *
Pin: origin $PI_HOST
Pin-Priority: 1
EOF
}

# put <rendered file> <destination> <mode>: write-then-rename, only when it differs.
put() {
  local src=$1 dst=$2 mode=$3
  guard_path "$dst"
  if cmp -s "$src" "$dst"; then log "$dst: unchanged"; return 0; fi
  install -d -m 0755 "$(dirname "$dst")"
  install -m "$mode" "$src" "$dst.new~"
  mv -f "$dst.new~" "$dst"
  log "$dst: written"
}

install_step() {
  # The configuration first: the part is in place before the package's postinst or any apt timer
  # can read the package's own files, and on a rig where the package is already installed with
  # 20auto-upgrades on, it is this part (sorting after it) that turns the schedule off.
  render_part >"$WORK/part"; put "$WORK/part" "$APT_PART" 0644
  render_prefs >"$WORK/prefs"; put "$WORK/prefs" "$SEC_PREFS" 0644
  render_conf >"$WORK/conf"; put "$WORK/conf" "$SEC_APT_CONF" 0644
  # Before the package: its postinst reads this to decide whether to write 20auto-upgrades on.
  # It decides a first install only; the part above is what holds on every rig.
  echo "$PKG $PKG/enable_auto_updates boolean false" | run debconf-set-selections
  if [[ $(dpkg-query -W -f '${db:Status-Abbrev}' "$PKG" 2>/dev/null) != "ii "* ]]; then
    if ! DEBIAN_FRONTEND=noninteractive run apt-get install -y -q --no-install-recommends "$PKG"; then
      DEBIAN_FRONTEND=noninteractive run apt-get update -q
      DEBIAN_FRONTEND=noninteractive run apt-get install -y -q --no-install-recommends "$PKG"
    fi
  else
    log "$PKG is installed"
  fi
}

# --- verify --------------------------------------------------------------------
# Every apt command runs under LC_ALL=C: the lines read here ("Candidate:", "Pinned packages:",
# "Allowed origins are:") are translated in other locales.

# policy <APT_CONFIG, or '' for the system's> [package...]: apt-cache policy's output. Dies,
# showing apt-cache's errors, when it fails or prints nothing (empty lists, an unknown package), so
# no check below ever compares two empty strings.
policy() {
  local conf=$1 out rc=0
  shift
  out=$(APT_CONFIG=$conf LC_ALL=C apt-cache policy "$@" 2>"$WORK/policy.err") || rc=$?
  if ((rc != 0)) || [[ -z $out ]]; then
    cat "$WORK/policy.err" >&2
    die "apt-cache policy ${*:-(all package files)}${conf:+ under APT_CONFIG=$conf} failed (exit $rc) or printed nothing; its errors are above. Empty apt lists print nothing: run apt-get update"
  fi
  printf '%s\n' "$out"
}

# candidate <package> <APT_CONFIG, or ''>: apt's candidate version; dies when there is none.
candidate() {
  local out c
  out=$(policy "$2" "$1")
  c=$(awk '$1 == "Candidate:" { print $2 }' <<<"$out")
  [[ -n $c && $c != "(none)" ]] \
    || die "$1 has no candidate${2:+ under APT_CONFIG=$2} ('${c:-empty}'); apt-cache policy printed: $out"
  printf '%s\n' "$c"
}

# pkg_origin <package>: the sources, "<url> <suite>" per line, that list the package's candidate
# version under the phase's APT_CONFIG (apt-cache policy's version table; /var/lib/dpkg/status is
# not a source). Empty when the package or its candidate is unknown.
pkg_origin() {
  APT_CONFIG=$SEC_APT_CONF LC_ALL=C apt-cache policy "$1" 2>/dev/null | awk '
    $1 == "Candidate:" { c = $2; next }
    $1 == "Version" && $2 == "table:" { tbl = 1; next }
    # the installed row, "*** <version> <priority>": a version row too (blanking $1 would leave NF 3)
    tbl && $1 == "***" && NF == 3 { cur = ($2 == c); next }
    # a version row: "<version> <priority>", priority being the last field
    tbl && NF == 2 && $2 ~ /^[0-9]+$/ && $1 !~ /^[a-z+]+:\/\// { cur = ($1 == c); next }
    tbl && cur && $2 ~ /^[a-z+]+:\/\// { print $2, $3 }'
}

# pkg_origin_ok <package>: true when the candidate is listed from Debian-Security (a trixie-security
# suite under debian-security), or the package is one of the four and the candidate is listed from
# the Pi archive.
pkg_origin_ok() {
  local o p
  o=$(pkg_origin "$1")
  grep -qE '^[a-z+]+://[^/ ]*/debian-security [a-z]+-security/' <<<"$o" && return 0
  for p in $PI_FOUR; do
    [[ $1 == "$p" ]] && grep -qE "^[a-z+]+://$PI_HOST/" <<<"$o" && return 0
  done
  return 1
}

# dump <APT_CONFIG, or ''> <file>: apt-config dump into the file; dies when it fails or is empty.
dump() {
  local rc=0
  APT_CONFIG=$1 LC_ALL=C apt-config dump >"$2" 2>"$WORK/dump.err" || rc=$?
  if ((rc != 0)) || [[ ! -s $2 ]]; then
    cat "$WORK/dump.err" >&2
    die "apt-config dump${1:+ under APT_CONFIG=$1} failed (exit $rc) or printed nothing; its errors are above"
  fi
}

# conf_value <dump file> <key>: a scalar as apt-config dump prints it, empty when absent. Keys
# compare without case, as apt's do.
conf_value() {
  awk -v k="${2,,}" 'tolower($1) == k { v = substr($0, length($1) + 2); sub(/^"/, "", v); sub(/";$/, "", v); print v }' "$1" | tail -n 1
}

# conf_list <dump file> <key>: a list's values, one per line, in apt's order.
conf_list() {
  awk -v k="${2,,}::" 'tolower($1) == k { v = substr($0, length($1) + 2); sub(/^"/, "", v); sub(/";$/, "", v); print v }' "$1"
}

# same_list <what> <got, one per line> <want...>: die unless equal, in order.
same_list() {
  local what=$1 got=$2
  shift 2
  [[ $got == "$(printf '%s\n' "$@")" ]] \
    || die "$what resolves to [$(paste -sd' ' <<<"$got")], not [$*]; a part sorting after $APT_PART changes it (ls /etc/apt/apt.conf.d)"
}

verify() {
  log "dpkg-query -W $PKG (raw output follows)"
  dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version}\n' "$PKG" 2>&1 || true
  echo "----"
  [[ $(dpkg-query -W -f '${db:Status-Abbrev}' "$PKG" 2>/dev/null) == "ii "* ]] \
    || die "$PKG is not installed; run this step without --verify"
  for f in "$APT_PART" "$SEC_APT_CONF" "$SEC_PREFS"; do
    [[ -f $f ]] || die "$f is missing; run this step without --verify"
  done
  cmp -s <(render_part) "$APT_PART" || die "$APT_PART differs from its render; run this step without --verify"
  cmp -s <(render_conf) "$SEC_APT_CONF" || die "$SEC_APT_CONF differs from its render; run this step without --verify"
  cmp -s <(render_prefs) "$SEC_PREFS" || die "$SEC_PREFS differs from its render; run this step without --verify"
  pass "the three files match their render"

  # The schedule: what apt-daily-upgrade.service's apt.systemd.daily reads, after every part
  # (20auto-upgrades included) is applied. Not the preseed: the value apt resolves.
  local sys=$WORK/dump.sys sec=$WORK/dump.sec uu
  dump '' "$sys"
  uu=$(conf_value "$sys" APT::Periodic::Unattended-Upgrade)
  log "apt-config dump: APT::Periodic::Unattended-Upgrade '${uu:-absent}'"
  [[ -z $uu || $uu == 0 ]] \
    || die "APT::Periodic::Unattended-Upgrade resolves to '$uu': apt's own timer would run unattended-upgrades outside the window. Look for a part sorting after $APT_PART (ls /etc/apt/apt.conf.d)"
  pass "nothing enables unattended-upgrade on apt's own schedule (APT::Periodic::Unattended-Upgrade resolves to '${uu:-absent}')"

  # The security phase's run: everything it reads, as apt resolves it under its APT_CONFIG.
  dump "$SEC_APT_CONF" "$sec"
  log "APT_CONFIG=$SEC_APT_CONF apt-config dump: what the security phase's run resolves (raw output follows)"
  grep -iE '^(Dir::Etc::Preferences|DPkg::Options|Unattended-Upgrade::(Origins-Pattern|Allowed-Origins|Package-Blacklist|Automatic-Reboot|InstallOnShutdown))' "$sec" || true
  echo "----"
  local v opts
  v=$(conf_value "$sec" Dir::Etc::Preferences)
  [[ $v == "$SEC_PREFS" ]] \
    || die "under the phase's APT_CONFIG, Dir::Etc::Preferences resolves to '$v', not $SEC_PREFS: a part overrides it, so the pins would not apply"
  opts=$(conf_list "$sec" DPkg::Options)
  if ! grep -qxF -- --force-confold <<<"$opts" || ! grep -qxF -- --force-confdef <<<"$opts" \
     || grep -qxE -- '--force-conf(new|miss)' <<<"$opts"; then
    die "under the phase's APT_CONFIG, DPkg::Options resolves to [$(paste -sd' ' <<<"$opts")], not --force-confdef and --force-confold (07:42 Q2)"
  fi
  pass "the phase's run reads its own preferences ($SEC_PREFS) and keeps changed config files"
  same_list "Unattended-Upgrade::Origins-Pattern" "$(conf_list "$sec" Unattended-Upgrade::Origins-Pattern)" "${ORIGINS[@]}"
  [[ -z $(conf_list "$sec" Unattended-Upgrade::Allowed-Origins) ]] \
    || die "Unattended-Upgrade::Allowed-Origins is not empty under the phase's APT_CONFIG; a part sorting after $APT_PART adds to it"
  pass "the allowed origins are Debian-Security and $PI_HOST only"
  same_list "Unattended-Upgrade::Package-Blacklist" "$(conf_list "$sec" Unattended-Upgrade::Package-Blacklist)" "${BLACKLIST[@]}"
  pass "the never-touch list is the kernel, firmware, EEPROM and Tailscale (${#BLACKLIST[@]} entries)"
  v=$(conf_value "$sec" Unattended-Upgrade::Automatic-Reboot)
  [[ ${v,,} == false ]] || die "Unattended-Upgrade::Automatic-Reboot resolves to '${v:-absent}', not false"
  v=$(conf_value "$sec" Unattended-Upgrade::InstallOnShutdown)
  [[ ${v,,} == false ]] || die "Unattended-Upgrade::InstallOnShutdown resolves to '${v:-absent}', not false"
  pass "unattended-upgrades never reboots and never installs at shutdown"

  # The pins, as apt resolves them under the phase's APT_CONFIG.
  local all files pinned p n
  all=$(policy "$SEC_APT_CONF")
  log "APT_CONFIG=$SEC_APT_CONF apt-cache policy (raw output follows)"
  printf '%s\n' "$all"
  echo "----"
  # "<priority> <host>" for every package file that names a host.
  files=$(awk '$2 ~ /^[a-z+]+:\/\// && $1 ~ /^-?[0-9]+$/ { prio = $1; next }
               $1 == "origin" && prio != "" { print prio, $2; prio = "" }' <<<"$all")
  n=$(awk -v h="$PI_HOST" '$2 == h' <<<"$files" | wc -l)
  ((n > 0)) || die "no package file from $PI_HOST in apt-cache policy: apt's sources do not name it, or its lists are missing (apt-get update)"
  v=$(awk -v h="$PI_HOST" '$2 == h && $1 != 1 { print $1 }' <<<"$files" | sort -u | paste -sd' ')
  [[ -z $v ]] || die "$PI_HOST's package files are at priority $v under the phase's pins, not 1: the Package: * stanza in $SEC_PREFS is not applied"
  pass "every one of $PI_HOST's $n package files is at priority 1 under the phase's pins"
  # "<package> <priority>" for every specifically pinned version.
  pinned=$(awk '/^Pinned packages:/ { on = 1; next }
                on && $2 == "->" && $4 == "with" && $5 == "priority" { sub(/:.*/, "", $1); print $1, $6 }' <<<"$all")
  for p in $PI_FOUR; do
    awk -v p="$p" '$1 == p && $2 == 500 { f = 1 } END { exit !f }' <<<"$pinned" \
      || die "$p has no version from $PI_HOST pinned at 500 under the phase's pins: it could not be updated from there (Pinned packages: [$(paste -sd' ' <<<"$pinned")])"
  done
  v=$(awk -v four=" $PI_FOUR " 'index(four, " " $1 " ") == 0 || $2 != 500' <<<"$pinned" | paste -sd' ')
  [[ -z $v ]] || die "pinned under the phase's pins beyond the four at 500: $v"
  pass "from $PI_HOST, the four ($PI_FOUR) and nothing else are pinned at 500"
  # A package outside the four, from that archive alone: every file listing it at 1.
  v=$(policy "$SEC_APT_CONF" "$PI_OTHER")
  printf '%s\n' "$v"
  n=$(grep -cE "^ +-?[0-9]+ [a-z+]+://$PI_HOST/" <<<"$v" || true)
  ((n > 0)) || die "$PI_OTHER is not listed from $PI_HOST; this check needs a package only that archive carries"
  [[ -z $(grep -E "^ +-?[0-9]+ [a-z+]+://$PI_HOST/" <<<"$v" | awk '$1 != 1') ]] \
    || die "$PI_OTHER is above priority 1 from $PI_HOST under the phase's pins: the run could update it"
  pass "$PI_OTHER, outside the four, is at priority 1 from $PI_HOST under the phase's pins"
  # The four's candidates under the pins are the system's: the pins never hold one back or
  # downgrade it (the Pi rebuild of openssl outranks Debian-Security's, PLAN §9h).
  local c_sys c_sec
  for p in $PI_FOUR; do
    c_sys=$(candidate "$p" '')
    c_sec=$(candidate "$p" "$SEC_APT_CONF")
    [[ $c_sys == "$c_sec" ]] \
      || die "$p: the security phase's candidate is '$c_sec', the system's '$c_sys'; its pins would hold back or downgrade it"
  done
  pass "the four's candidates under the phase's pins are the system's"

  # The run itself, simulated: what unattended-upgrade reports it would do.
  local rc=0 got pat o pkgs re
  log "APT_CONFIG=$SEC_APT_CONF unattended-upgrade --dry-run -v, at most ${DRY_RUN_TIMEOUT}s (raw output follows)"
  APT_CONFIG=$SEC_APT_CONF LC_ALL=C DEBIAN_FRONTEND=noninteractive \
    timeout -k 30 "$DRY_RUN_TIMEOUT" unattended-upgrade --dry-run -v >"$WORK/dry" 2>&1 || rc=$?
  cat "$WORK/dry"
  echo "----"
  ((rc == 0)) || die "unattended-upgrade --dry-run exited $rc (124 or 137: not finished in ${DRY_RUN_TIMEOUT}s). A dry run downloads what it would upgrade, so it needs the network when anything is pending"
  got=$(sed -n 's/.*Allowed origins are: //p' "$WORK/dry" | tail -n 1)
  pat=''
  for o in "${ORIGINS[@]}"; do
    # shellcheck disable=SC2016  # the literal ${distro_codename}, unattended-upgrades' own
    o=${o//'${distro_codename}'/[a-z]*}
    pat+=${pat:+, }$o
  done
  # shellcheck disable=SC2053  # $pat is a glob on purpose: the codename is the rig's
  [[ -n $got && $got == $pat ]] || die "unattended-upgrade reports its allowed origins as '$got', not '$pat'"
  got=$(sed -n 's/.*Initial blacklist: //p' "$WORK/dry" | tail -n 1)
  [[ $got == "${BLACKLIST[*]}" ]] || die "unattended-upgrade reports its blacklist as '$got', not '${BLACKLIST[*]}'"
  if grep -q 'Packages that will be upgraded: ' "$WORK/dry"; then
    pkgs=$(sed -n 's/.*Packages that will be upgraded: //p' "$WORK/dry" | tail -n 1)
  elif grep -q 'No packages found that can be upgraded unattended' "$WORK/dry"; then
    pkgs=''
  else
    die "unattended-upgrade's dry run says neither what it would upgrade nor that there is nothing; see above"
  fi
  for p in $pkgs; do
    pkg_origin_ok "${p%%:*}" || die "unattended-upgrade would upgrade $p, which is neither from Debian-Security nor one of the four from $PI_HOST ($PI_FOUR): its candidate's sources are [$(pkg_origin "${p%%:*}" | paste -sd';')]"
    for re in "${BLACKLIST[@]}"; do
      if [[ ${p%%:*} =~ ^$re ]]; then
        die "unattended-upgrade would upgrade $p, on the never-touch list ($re)"
      fi
    done
  done
  pass "unattended-upgrade's dry run reads this step's origins and blacklist, and would upgrade ${pkgs:-nothing}, none of it never-touch"
}

if ((VERIFY_ONLY == 0)); then
  install_step
fi
verify
