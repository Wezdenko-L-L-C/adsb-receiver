#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tests/smoke_update.sh: a sandbox smoke test of setup/update.sh and setup/bootstrap.sh, run end to
# end without root. The real scripts are copied into a temporary directory with sed, which remaps
# their fixed paths (/opt, /var/lib, /var/log, /run and /etc's adsb-receiver directories, and the
# clone URL) into that directory and neuters the root checks, the root ownership of what they
# install, dpkg and the 5-second reboot countdown. Every remap is asserted before anything runs:
# the sandbox form must be in the copy and the original must not, so a reformatted line in either
# script stops the suite by name instead of reaching the real paths. A throwaway git
# repository stands in for the project, with fake steps and foundation scripts that print what
# they were run with and fail, sleep or hold the recording lock on cue. systemctl is a stub on
# PATH, so nothing is enabled and nothing reboots. Each case prints PASS or FAIL, and the exit
# status is the verdict: 0 only if every case passed and exactly EXPECTED_CHECKS cases ran.
# It refuses to run as root: it is for the workstation and CI, never a rig.
#
# Run: bash tests/smoke_update.sh    (SMOKE_KEEP=1 keeps the sandbox and prints where it is)
# Needs: bash, git, python3 with PyYAML, flock and setsid (util-linux), coreutils.
# Wall-clock heavy for its size: the signal cases wait for a step to start sleeping and the lock
# cases sleep, so a run mostly idles (about 30 s on the author's machine).
set -uo pipefail
# The number of check cases a full run makes. Bump it when cases are added or removed: a run that
# makes fewer (a section skipped by an early return, a wait loop that timed out) fails.
readonly EXPECTED_CHECKS=121
((EUID != 0)) || { echo "refusing to run as root: the sandbox remaps real system paths by sed"; exit 1; }
REAL=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SB=$(mktemp -d) || { echo "mktemp failed"; exit 1; }
[[ -n $SB && -d $SB ]] || { echo "mktemp gave no sandbox directory: '$SB'"; exit 1; }
cleanup() { if [[ ${SMOKE_KEEP:-} == 1 ]]; then echo "sandbox kept: $SB"; else rm -rf "${SB:?}"; fi; }
trap cleanup EXIT
mkdir -p "$SB"/{opt,var,log,run,etc,src,bin}
NPASS=0 NFAIL=0
ok()   { echo "PASS: $*"; NPASS=$((NPASS+1)); }
bad()  { echo "FAIL: $*"; NFAIL=$((NFAIL+1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

remap_update() {
  sed -e "s#/opt/adsb-receiver#$SB/opt#; s#^readonly STATE=/var/lib/adsb-receiver#readonly STATE=$SB/var#; s#/var/log/adsb-receiver#$SB/log#; s#^readonly RUN_DIR=/run/adsb-receiver#readonly RUN_DIR=$SB/run#; s#/etc/adsb-receiver/station.yml#$SB/etc/station.yml#" \
      -e 's#((EUID == 0)) || {#true || {#' -e 's#^  DEBIAN_FRONTEND=noninteractive dpkg --configure -a \\#  true \\#' \
      -e 's#install -m 0600 -o root -g root #install -m 0600 #' "${UPD_SRC:-$REAL/setup/update.sh}"
}
remap_bootstrap() {
  sed -e "s#local base=/opt/adsb-receiver#local base=$SB/opt#" \
      -e "s#local url=https://github.com/[^ ]*#local url=$SB/src/origin.git#" \
      -e 's#if ((EUID != 0)); then#if false; then#' -e 's#^  sleep 5$#  sleep 0#' \
      -e 's#install -d -m 0755 -o root -g root #install -d -m 0755 #' \
      -e 's#\[\[ \$s == "install ok installed" \]\] || missing+=#true || missing+=#' "$REAL/setup/bootstrap.sh"
}
U=$SB/update.sh; remap_update >"$U"
B=$SB/bootstrap.sh; remap_bootstrap >"$B"
# <file> then triples of <remap> <sandbox form, must be present> <original, must be absent>,
# all fixed strings. One failing remap names itself and stops the suite.
assert_remaps() {
  local f=$1; shift
  while (($# >= 3)); do
    if ! grep -qF -- "$2" "$f" || grep -qF -- "$3" "$f"; then
      echo "remap failed in ${f##*/}: $1 (want '$2' present and '$3' absent)"; exit 1
    fi
    shift 3
  done
}
assert_remaps "$U" \
  "BASE"          "readonly BASE=$SB/opt"              "readonly BASE=/opt/adsb-receiver" \
  "STATE"         "readonly STATE=$SB/var"             "readonly STATE=/var/lib/adsb-receiver" \
  "LOG_ROOT"      "readonly LOG_ROOT=$SB/log"          "/var/log/adsb-receiver" \
  "RUN_DIR"       "readonly RUN_DIR=$SB/run"           "readonly RUN_DIR=/run/adsb-receiver" \
  "ETC_YML"       "readonly ETC_YML=$SB/etc/station.yml" "/etc/adsb-receiver/station.yml" \
  "root check"    "true || {"                          "((EUID == 0))" \
  "dpkg"          "  true \\"                          "DEBIAN_FRONTEND=noninteractive dpkg --configure -a" \
  "root install"  "install -m 0600 \""                 "install -m 0600 -o root -g root"
# shellcheck disable=SC2016  # $s is bootstrap.sh's text, matched literally
assert_remaps "$B" \
  "base"          "local base=$SB/opt"                 "local base=/opt/adsb-receiver" \
  "clone url"     "local url=$SB/src/origin.git"       "local url=https://github.com/" \
  "root check"    "if false; then"                     "EUID != 0" \
  "reboot sleep"  "  sleep 0"                          "sleep 5" \
  "root install"  "install -d -m 0755 \""              "install -d -m 0755 -o root -g root" \
  "dpkg-query"    "true || missing+="                  '[[ $s == "install ok installed" ]]'

cat >"$SB/bin/systemctl" <<EOF
#!/usr/bin/env bash
case "\$1 \${2:-}" in
  "is-enabled adsb-update.timer") cat "$SB/timer-state" 2>/dev/null || echo disabled ;;
  "is-enabled "*) echo disabled; exit 1 ;;
  "is-active "*) echo inactive; exit 3 ;;
  "reboot "*) echo "FAKE REBOOT"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SB/bin/systemctl"
export PATH=$SB/bin:$PATH

R=$SB/src/proj; mkdir -p "$R/setup/steps" "$R/setup/foundation" "$R/config"
cp "$REAL"/config/station.*.example.yml "$R/config/"
{
cat <<EOF
ADSB_RC_OTHER_ROLE=100
ADSB_RUN_DIR=$SB/run
ADSB_REBOOT_FLAG=$SB/run/reboot-required
ADSB_RECORDING_LOCK=$SB/run/recording.lock
warn() { printf '!!  WARNING: %s\n' "\$*" >&2; }
die() { printf 'xx  FAIL: %s\n' "\$*" >&2; exit 1; }
EOF
sed -n '/^need_reboot() {/,/^}/p' "$REAL/setup/lib.sh"
} >"$R/setup/lib.sh"
grep -q ADSB_REBOOT_MARK "$R/setup/lib.sh" || { echo "need_reboot not copied"; exit 1; }
remap_update >"$R/setup/update.sh"
remap_bootstrap >"$R/setup/bootstrap.sh"
mk() { cat >"$R/setup/steps/$1.sh" <<EOF
#!/usr/bin/env bash
n=$1
echo "\$0 \$* ADSB_UPDATE_RUN=\${ADSB_UPDATE_RUN:-unset}"
[[ \${1:-} == --skip-other-role && \$n == 20-other ]] && exit 100
[[ \${1:-} == --skip-other-role && -e setup/IFAIL-\$n ]] && { echo "deliberate install failure"; exit 1; }
[[ \${1:-} == --skip-other-role && -e setup/SLEEP-\$n ]] && { echo SLEEPING; sleep 30; echo "slept through"; }
[[ \${1:-} == --skip-other-role && -e setup/HOLD-\$n ]] && { 9<&- setsid flock -w 60 "$SB/run/recording.lock" sleep 8 </dev/null >/dev/null 2>&1 & }
[[ \${1:-} == --verify && -e setup/FAIL-\$n ]] && { echo "deliberate verify failure"; exit 1; }
if [[ \${1:-} == --skip-other-role && "\$(cat $SB/reboot-step 2>/dev/null)" == \$n ]]; then
  source setup/lib.sh
  if [[ -e $SB/fixed-reason ]]; then need_reboot "reboot reason from \$n"; else need_reboot "reboot reason from \$n \$RANDOM"; fi
fi
exit 0
EOF
}
for s in 00-a 20-other 40-c 50-updater; do mk "$s"; done
# 05-config as the real one treats station.yml: the worktree's config/station.yml, if there is
# one, replaces the installed copy (here the sandbox's etc); with none, the installed copy stays.
cat >"$R/setup/steps/05-config.sh" <<EOF
#!/usr/bin/env bash
echo "\$0 \$* ADSB_UPDATE_RUN=\${ADSB_UPDATE_RUN:-unset}"
if [[ \${1:-} == --skip-other-role ]]; then
  if [[ -f config/station.yml ]]; then
    if cmp -s config/station.yml "$SB/etc/station.yml"; then echo "05: unchanged"
    else cp config/station.yml "$SB/etc/station.yml"; echo "05: installed config/station.yml"; fi
  else echo "05: no config/station.yml; keeping the installed copy"; fi
fi
[[ -f "$SB/etc/station.yml" ]] || { echo "05: no installed station.yml"; exit 1; }
exit 0
EOF
cat >"$R/setup/foundation/rtc-overlay.sh" <<'EOF'
echo "rtc foundation marker=${ADSB_FOUNDATION:-unset}"
echo "NOTE: a test note"
[[ -e setup/SLEEP-rtc || -e "$(dirname "$0")/../SLEEP-rtc" ]] && { echo SLEEPING; sleep 30; echo "slept through"; }
exit 0
EOF
cat >"$R/setup/foundation/format-archive.sh" <<'EOF'
echo "format foundation marker=${ADSB_FOUNDATION:-unset}"
printf '{"result": "skipped", "reason": "test", "device": null, "manual": null}\n' >"$2"
EOF
gc() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
git -C "$R" init -q -b main && git -C "$R" add -A && gc commit -qm one
git clone -q --bare "$R" "$SB/src/origin.git"
push() { git -C "$R" push -q -f "$SB/src/origin.git" "${1:-main}"; }
commit() { git -C "$R" add -A; gc commit -qm "$1"; push "${2:-main}"; }

S() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$SB/var/status.json" "$1"; }
run() { RC=0; "$@" >"$SB/out.txt" 2>&1 || RC=$?; }
mt() { stat -c %Y "$SB/var/status.json" 2>/dev/null || echo none; }
sha() { git -C "$R" rev-parse "${1:-HEAD}"; }
rmwt() { local t; t=$(readlink -f "$SB/opt/applied"); [[ $t == "$SB"/opt/worktrees/* ]] && rm -rf "${t:?}"; }
lacks() { ! grep -q -- "$1" "$2"; }                      # <pattern> <file>: no line matches
lacks_has() { lacks "$1" "$3" && grep -q -- "$2" "$3"; } # <absent> <present> <file>
rc_has() { [ "$RC" = "$1" ] && grep -q -- "$2" "$3"; }   # <exit status> <pattern> <file>
globbed() { compgen -G "$1" >/dev/null; }               # <glob>: something matches it
seeds() { find "$SB/opt/worktrees" -path '*/config/station.yml' | wc -l; }  # seed copies left

echo "== A. timer, no applied, no status: refuses (exit 1)"
printf 'station:\n  role: portable\n' >"$SB/etc/station.yml"
run bash "$U"
rm -f "$SB/etc/station.yml"
check "A exit 1" [ "$RC" = 1 ]
check "A says no build" grep -q "no build on this rig" "$SB/out.txt"

echo "== B. bootstrap, portable, first build, step 40 install fails: incomplete (3), no reboot (timer disabled)"
touch "$R/setup/IFAIL-40-c"; commit "two: 40 fails"
B1=$(sha)
echo disabled >"$SB/timer-state"; echo 00-a >"$SB/reboot-step"
run bash "$B" --role portable
check "B exit 3" [ "$RC" = 3 ]
check "B incomplete, candidate is main" [ "$(S 's["result"]+" "+s["candidate_rev"]')" = "incomplete $B1" ]
check "B foundation saw the bootstrap marker" grep -q "format foundation marker=bootstrap" "$SB/out.txt"
check "B step saw ADSB_UPDATE_RUN" grep -q "ADSB_UPDATE_RUN=2" "$SB/out.txt"
check "B no reboot: timer not enabled" grep -q "adsb-update.timer is not enabled" "$SB/out.txt"
check "B did not reboot" lacks "FAKE REBOOT" "$SB/out.txt"
check "B no applied" [ ! -e "$SB/opt/applied" ]

echo "== C. timer while incomplete: pinned to the bootstrap's commit, not main's new tip"
rm -f "$R/setup/IFAIL-40-c"; echo "# three" >>"$R/setup/steps/00-a.sh"; commit "three: fixed"
rm -f "$SB/reboot-step"
run bash "$U"
check "C exit 3 (pinned B1 still fails)" [ "$RC" = 3 ]
check "C candidate is still B1" [ "$(S 's["candidate_rev"]')" = "$B1" ]
check "C log says pinned" grep -q "finishing the first build at the bootstrap's commit" "$SB/out.txt"

echo "== C2. bootstrap again at main's tip: applied (0), reboots (first build, flag gained, timer enabled, lock free)"
echo enabled >"$SB/timer-state"; echo 40-c >"$SB/reboot-step"; rm -f "$SB/run/reboot-required"
run bash "$B" --role portable
check "C2 exit 0" [ "$RC" = 0 ]
check "C2 applied main" [ "$(S 's["result"]+" "+s["applied_rev"]')" = "applied $(sha)" ]
check "C2 rebooted" grep -q "FAKE REBOOT" "$SB/out.txt"
A1=$(sha)
check "C2 05-config installed the seed, and it is gone from the worktrees" \
  [ "$(seeds)/$([ -f "$SB/etc/station.yml" ] && echo installed)" = 0/installed ]

echo "== D. bootstrap re-run on the built rig, flag gains a line: never reboots"
run bash "$B" --role portable
check "D exit 0" [ "$RC" = 0 ]
check "D did not reboot" lacks "FAKE REBOOT" "$SB/out.txt"
check "D says re-run never reboots" grep -q "already had a build" "$SB/out.txt"
rm -f "$SB/reboot-step"

echo "== E. timer unchanged: exit 0, status untouched"
m=$(mt); sleep 1; run bash "$U"
check "E exit 0 and untouched" [ "$RC/$(mt)" = "0/$m" ]

echo "== F. new commit with a new step 45-new and a 40-c verify failure: rolled back (2)"
mk 45-new; touch "$R/setup/FAIL-40-c"; commit "four: bad"
F1=$(sha)
run bash "$U"
check "F exit 2" [ "$RC" = 2 ]
check "F rolled back, rollback ok" [ "$(S 's["result"]+" "+s["rollback"]["result"]')" = "rolled_back ok" ]
check "F rollback.complete false, leftovers 45-new" [ "$(S 'str(s["rollback"]["complete"])+" "+",".join(s["rollback"]["leftovers_possible"])')" = "False 45-new" ]
check "F applied and applied-rev are the old commit" [ "$(git -C "$SB/opt/applied" rev-parse HEAD) $(cat "$SB/var/applied-rev")" = "$A1 $A1" ]
check "F rollback steps ran" ls "$SB/log"/*/rollback-40-c.log

echo "== G. timer right after: the failed candidate is skipped (24 h backoff), exit 0, nothing written"
m=$(mt); sleep 1; run bash "$U"
check "G exit 0, untouched" [ "$RC/$(mt)" = "0/$m" ]
check "G says skipped" grep -q "skipped: ${F1:0:12} was rolled_back" "$SB/out.txt"

echo "== H. --retry overrides: runs and rolls back again (2)"
run bash "$U" --retry
check "H exit 2" [ "$RC" = 2 ]

echo "== I. 25 h later the timer retries on its own"
python3 - "$SB/var/status.json" <<'EOF'
import json, sys, time
p = sys.argv[1]; s = json.load(open(p))
s["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 25 * 3600))
json.dump(s, open(p, "w"))
EOF
run bash "$U"
check "I exit 2 (retried)" [ "$RC" = 2 ]

echo "== J. applied dangling, applied-rev good: worktree recreated, normal run"
rm -f "$R/setup/FAIL-40-c"; commit "five: good"
rmwt
run bash "$U"
check "J exit 0" [ "$RC" = 0 ]
check "J recovered and applied five" [ "$(S 's["result"]+" "+s["applied_rev"]')" = "applied $(sha)" ]
check "J said recreated" grep -q "recreating its worktree" "$SB/out.txt"

echo "== K. applied dangling, applied-rev garbage: failed (1), no step runs"
rmwt; echo nonsense >"$SB/var/applied-rev"
run bash "$U"
check "K exit 1" [ "$RC" = 1 ]
check "K failed_step" [ "$(S 's["result"]+"|"+s["failed_step"]')" = "failed|applied is dangling and applied-rev is unusable" ]
check "K no step ran" lacks "steps/00-a.sh" "$SB/out.txt"
rm -f "$SB/opt/applied"; run bash "$B" --role portable --no-reboot
check "K repaired by removing applied and bootstrapping" [ "$RC" = 0 ]

echo "== L. SIGTERM, SIGINT, SIGHUP to the process group mid-step: rolled back (2)"
for sig in TERM INT HUP; do
  touch "$R/setup/SLEEP-40-c"; echo "# $sig" >>"$R/setup/steps/00-a.sh"; commit "sleep $sig"
  python3 - "$U" "$sig" "$SB/out.txt" <<'EOF'
import os, signal, subprocess, sys, time
u, sig, out = sys.argv[1:4]
with open(out, "w") as fh:
    p = subprocess.Popen(["bash", u, "--retry"], stdout=fh, stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(300):
        time.sleep(0.1)
        if "SLEEPING" in open(out).read():
            break
    os.killpg(p.pid, getattr(signal, "SIG" + sig))
    p.wait(timeout=60)
EOF
  grep -q "result: rolled_back; exit 2" "$SB/out.txt" || tail -25 "$SB/out.txt"
  check "L $sig exit 2" grep -q "result: rolled_back; exit 2" "$SB/out.txt"
  check "L $sig rollback ok" [ "$(S 's["rollback"]["result"]')" = ok ]
  check "L $sig step did not finish" lacks "slept through" "$SB/out.txt"
  rm -f "$R/setup/SLEEP-40-c"; commit "unsleep $sig"
  run bash "$U" --retry
done

echo "== M. lock held by another process: exit 0, marker line, nothing written"
echo "# m" >>"$R/setup/steps/00-a.sh"; commit "m"
m=$(mt); flock "$SB/run/recording.lock" sleep 4 & sleep 0.5
run bash "$U"
check "M exit 0, untouched" [ "$RC/$(mt)" = "0/$m" ]
check "M marker" grep -q "^ADSB-UPDATE-SKIPPED lock-held" "$SB/out.txt"
wait

echo "== N. offline portable: exit 0, nothing written"
mv "$SB/src/origin.git" "$SB/src/gone.git"; m=$(mt); run bash "$U"; mv "$SB/src/gone.git" "$SB/src/origin.git"
check "N exit 0, untouched" [ "$RC/$(mt)" = "0/$m" ] || tail -5 "$SB/out.txt"

echo "== O. usage"
run bash "$U" --bootstrap --role portable --rev abc; check "O1 --bootstrap --rev: 64" [ "$RC" = 64 ]
run bash "$U" --role portable; check "O2 --role without --bootstrap: 64" [ "$RC" = 64 ]
run bash "$B"; check "O3 bootstrap without --role: 64" [ "$RC" = 64 ]

echo "== P. bootstrap from a checkout at a commit not on main: builds that commit, warns"
git -C "$R" checkout -q -b side; echo "# side" >>"$R/setup/steps/00-a.sh"; gc commit -qam side
run bash "$R/setup/bootstrap.sh" --role portable --no-reboot
check "P exit 0" [ "$RC" = 0 ]
check "P built the checkout's HEAD" [ "$(S 's["applied_rev"]')" = "$(sha)" ]
check "P warned not on main" grep -q "is not on origin/main" "$SB/out.txt"
git -C "$R" checkout -q main

echo "== Q. --set typing: 00000001 stays a string where the template holds a string"
WT=$(readlink -f "$SB/opt/applied")
run bash "$WT/setup/update.sh" --bootstrap --role portable --set dongles.adsb=00000001 --config "$R/config/station.portable.example.yml"
python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(repr(d["dongles"]["adsb"]))' "$SB/etc/station.yml" >"$SB/q.txt" 2>&1
check "Q 00000001 is a string" grep -qx "'00000001'" "$SB/q.txt"

echo "== R. stationary soak: stable's tip applies only once it is soak_days old"
rm -rf "${SB:?}/opt" "${SB:?}/var" "${SB:?}/log" "${SB:?}/run" "${SB:?}/etc/station.yml"; mkdir -p "$SB/opt" "$SB/var" "$SB/log" "$SB/run"
old=$(date -u -d '-10 days' +%Y-%m-%dT%H:%M:%SZ)
echo "# old" >>"$R/setup/steps/00-a.sh"; git -C "$R" add -A
GIT_COMMITTER_DATE=$old GIT_AUTHOR_DATE=$old gc commit -qm old; push main
git -C "$R" push -q -f "$SB/src/origin.git" main:stable
R1=$(sha)
run bash "$B" --role stationary --no-reboot --set position.latitude=1.5 --set position.longitude=2.5 --set position.altitude_m=3
check "R first build at stable's tip, no gate" [ "$RC/$(S 's["applied_rev"]')" = "0/$R1" ]
echo "# young" >>"$R/setup/steps/00-a.sh"; commit young
git -C "$R" push -q -f "$SB/src/origin.git" main:stable
run bash "$U"
check "R young tip: unchanged, exit 0" [ "$RC" = 0 ]
check "R says under soak" grep -q "under update.soak_days" "$SB/out.txt"
check "R old non-tip commit not applied" [ "$(cat "$SB/var/applied-rev")" = "$R1" ]
old2=$(date -u -d '-8 days' +%Y-%m-%dT%H:%M:%SZ)
GIT_COMMITTER_DATE=$old2 gc commit -q --amend --no-edit; push main; git -C "$R" push -q -f "$SB/src/origin.git" main:stable
run bash "$U"
check "R aged tip is the candidate; the gate holds (no clock-preflight): exit 4" [ "$RC" = 4 ]
check "R candidate named" grep -q "candidate: $(sha | cut -c1-12)" "$SB/out.txt"

sig_run() { # <signal> <cmd...>: run it in its own session, send the signal to the group at SLEEPING
  local sig=$1; shift
  python3 - "$sig" "$SB/out.txt" "$@" <<'PYX'
import os, signal, subprocess, sys, time
sig, out, *cmd = sys.argv[1:]
with open(out, "w") as fh:
    p = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(300):
        time.sleep(0.1)
        if "SLEEPING" in open(out).read():
            break
    else:
        print("never saw SLEEPING", file=sys.stderr)
    os.killpg(p.pid, getattr(signal, "SIG" + sig))
    sys.exit(p.wait(timeout=90))
PYX
}
fresh_rig() {
  rm -rf "${SB:?}/opt" "${SB:?}/var" "${SB:?}/log" "${SB:?}/run" "${SB:?}/etc/station.yml"
  mkdir -p "$SB/opt" "$SB/var" "$SB/log" "$SB/run"
  rm -f "$SB/reboot-step" "$SB/fixed-reason"
  rm -f "$R"/setup/IFAIL-* "$R"/setup/FAIL-* "$R"/setup/SLEEP-* "$R"/setup/HOLD-*
}

echo "== S1. SIGINT and SIGTERM during the foundation (rtc-overlay): the formatter never runs"
for sig in INT TERM; do
  fresh_rig; touch "$R/setup/SLEEP-rtc"; echo "# s1 $sig" >>"$R/setup/steps/00-a.sh"; commit "s1 $sig"
  echo enabled >"$SB/timer-state"; echo 00-a >"$SB/reboot-step"
  RC=0; sig_run "$sig" bash "$B" --role portable || RC=$?
  # SIGTERM to the group ends bootstrap.sh at once (bash's default); update.sh finishes on its own.
  for _ in $(seq 1 60); do pgrep -f "$SB/opt/worktrees/.*/setup/update.sh" >/dev/null || break; sleep 0.5; done
  want=130; [[ $sig == TERM ]] && want=143
  check "S1 $sig: the formatter did not run" lacks "format foundation marker" "$SB/out.txt"
  check "S1 $sig: format.json says not_run" [ "$(S 's["foundation"]["format_archive"]["result"]')" = not_run ]
  check "S1 $sig: recorded incomplete" [ "$(S 's["result"]')" = incomplete ]
  check "S1 $sig: update.sh exited 128+N ($want)" grep -q "result: incomplete; exit $want" "$SB/out.txt"
  check "S1 $sig: no reboot countdown" lacks "Rebooting in\|FAKE REBOOT" "$SB/out.txt"
  check "S1 $sig: no step ran after the signal" lacks "40-c.sh --skip-other-role" "$SB/out.txt"
done
rm -f "$R/setup/SLEEP-rtc"; commit "s1 done"

echo "== S2. a pinned first build that fails unexpectedly (set -e) stays retryable"
fresh_rig; touch "$R/setup/IFAIL-40-c"; commit "s2: 40 fails"; S2=$(sha)
echo disabled >"$SB/timer-state"
run bash "$B" --role portable
check "S2 bootstrap: incomplete (3)" [ "$RC/$(S 's["result"]')" = 3/incomplete ]
# The run-log directory cannot be made (a file is in its way): install -d fails under set -e.
mv "$SB/log" "$SB/log.d"; : >"$SB/log"
run bash "$U"
rm -f "$SB/log"; mv "$SB/log.d" "$SB/log"
echo "   (S2 timer run: exit $RC)"; tail -5 "$SB/out.txt" | sed 's/^/   | /'
check "S2 the timer run died unexpectedly (exit 1)" [ "$RC" = 1 ]
check "S2 status is still incomplete, not failed" [ "$(S 's["result"]+" "+s["candidate_rev"]')" = "incomplete $S2" ]
check "S2 failed_step names update.sh itself" grep -q "update.sh itself" "$SB/var/status.json"
check "S2 foundation record carried forward, with its note" [ "$(S 's["foundation"]["rtc_overlay"]+"|"+",".join(s["foundation"]["notes"])')" = "ok|a test note" ]
run bash "$U"
check "S2 the next timer run retries, pinned (exit 3)" [ "$RC" = 3 ]
check "S2 said it is finishing the first build" grep -q "finishing the first build at the bootstrap's commit ${S2:0:12}" "$SB/out.txt"
check "S2 foundation still carried" [ "$(S 's["foundation"]["format_archive"]["result"]')" = skipped ]
rm -f "$R/setup/IFAIL-40-c"; commit "s2 done"

echo "== S3. a bootstrap re-run in the same boot: the reason it set again counts (reboots)"
fresh_rig; touch "$R/setup/IFAIL-40-c" "$SB/fixed-reason"; commit "s3"
echo enabled >"$SB/timer-state"; echo 00-a >"$SB/reboot-step"
run bash "$B" --role portable --no-reboot
check "S3 run 1: incomplete, not rebooted (--no-reboot)" [ "$RC" = 3 ] && check "S3 run 1 no reboot" lacks "FAKE REBOOT" "$SB/out.txt"
lines1=$(wc -l <"$SB/run/reboot-required")
run bash "$B" --role portable
check "S3 run 2: the flag gained no line" [ "$(wc -l <"$SB/run/reboot-required")" = "$lines1" ]
check "S3 run 2: rebooted, since this run asked for it" grep -q "FAKE REBOOT" "$SB/out.txt"
echo 40-c >"$SB/reboot-step"; rm -f "$SB/run/reboot-required"; touch "$SB/run/reboot-required"
echo "stale reason from an earlier run" >"$SB/run/reboot-required"; rm -f "$SB/reboot-step"
run bash "$B" --role portable
check "S3 run 3: a stale reason alone does not reboot" lacks_has "FAKE REBOOT" "this run asked for no reboot" "$SB/out.txt"
rm -f "$R/setup/IFAIL-40-c" "$SB/fixed-reason"; commit "s3 done"

echo "== S4. Ctrl-C during the build: no reboot countdown"
fresh_rig; touch "$R/setup/SLEEP-40-c"; commit "s4"
echo enabled >"$SB/timer-state"; echo 00-a >"$SB/reboot-step"
RC=0; sig_run INT bash "$B" --role portable || RC=$?
check "S4 bootstrap exit 130" [ "$RC" = 130 ]
check "S4 no countdown, no reboot" lacks "Rebooting in\|FAKE REBOOT" "$SB/out.txt"
check "S4 says the build stopped (exit 130)" grep -q "the build stopped (exit 130)" "$SB/out.txt"
check "S4 recorded incomplete" [ "$(S 's["result"]')" = incomplete ]
rm -f "$R/setup/SLEEP-40-c"; commit "s4 done"

echo "== S5. the lock held at the end by something this build did not start as its writer: no reboot"
fresh_rig; touch "$R/setup/HOLD-40-c"; commit "s5"
echo enabled >"$SB/timer-state"; echo 00-a >"$SB/reboot-step"
run bash "$B" --role portable
check "S5 applied (0)" [ "$RC" = 0 ]
check "S5 no reboot: the lock holder is named" lacks_has "FAKE REBOOT" "not by a writer this build started" "$SB/out.txt"
sleep 8; rm -f "$R/setup/HOLD-40-c"; commit "s5 done"

echo "== S6. an incomplete status with a null candidate is not misread (one field per line)"
fresh_rig; mkdir -p "$SB/var"
printf '{"result": "incomplete", "candidate_rev": null, "finished_at": "2026-10-04T00:00:00Z"}\n' >"$SB/var/status.json"
printf 'station:\n  role: portable\n' >"$SB/etc/station.yml"
run bash "$U"
check "S6 refuses: no build on this rig (not a cat-file error on a timestamp)" grep -q "no build on this rig" "$SB/out.txt"

echo "== T. the /etc copy is the one edited: no pinned timer run, rollback or bootstrap re-run reinstalls the seed"
etc_get() { python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(d["station"]["id"], d["archive"]["min_free_gb"])' "$SB/etc/station.yml" 2>&1; }
edit_etc() { sed -i "s/^  id: .*/  id: $1/" "$SB/etc/station.yml"; }

echo "-- T1. a first build left incomplete, the /etc copy edited, the timer finishes it pinned"
fresh_rig; touch "$R/setup/IFAIL-40-c"; commit "t1: 40 fails"
echo disabled >"$SB/timer-state"
run bash "$B" --role portable --no-reboot
check "T1 bootstrap: incomplete (3)" [ "$RC" = 3 ]
check "T1 05-config installed the seed" grep -q "05: installed config/station.yml" "$SB/out.txt"
check "T1 no seed left in any worktree" [ "$(seeds)" = 0 ]
edit_etc edited-t1
run bash "$U"
check "T1 the timer ran the pinned first build (exit 3)" rc_has 3 "finishing the first build" "$SB/out.txt"
check "T1 /etc kept the edit" [ "$(etc_get)" = "edited-t1 4" ]

echo "-- T2. a built rig, the /etc copy edited, a candidate rolls back to the bootstrap's tree"
fresh_rig; echo "# t2" >>"$R/setup/steps/00-a.sh"; commit "t2: good"; T2=$(sha)
run bash "$B" --role portable --no-reboot
check "T2 bootstrap applied (0)" [ "$RC" = 0 ]
check "T2 no seed left in any worktree" [ "$(seeds)" = 0 ]
edit_etc edited-t2
touch "$R/setup/FAIL-40-c"; commit "t2: bad"
run bash "$U"
check "T2 rolled back (2), rollback ok" [ "$RC/$(S 's["rollback"]["result"]')" = "2/ok" ]
check "T2 the rollback re-ran 05-config from the applied tree" globbed "$SB/log/*/rollback-05-config.log"
check "T2 /etc kept the edit through the rollback" [ "$(etc_get)" = "edited-t2 4" ]
rm -f "$R/setup/FAIL-40-c"; commit "t2: fixed"

echo "-- T3. a bootstrap re-run at the applied commit, no --set and no --config"
edit_etc edited-t3
AW=$(readlink -f "$SB/opt/applied")
run bash "$AW/setup/bootstrap.sh" --role portable --no-reboot
check "T3 re-run applied (0) at the same commit, in the same worktree" \
  [ "$RC $(S 's["applied_rev"]') $(readlink -f "$SB/opt/applied")" = "0 $T2 $AW" ]
check "T3 05-config kept the installed copy" grep -q "05: no config/station.yml; keeping the installed copy" "$SB/out.txt"
check "T3 /etc kept the edit" [ "$(etc_get)" = "edited-t3 4" ]

echo "-- T4. the control: a bootstrap re-run WITH --set does write /etc, from the edited copy"
run bash "$AW/setup/bootstrap.sh" --role portable --no-reboot --set archive.min_free_gb=9
check "T4 applied (0)" [ "$RC" = 0 ]
check "T4 --set reached /etc, and the earlier edit is kept" [ "$(etc_get)" = "edited-t3 9" ]
check "T4 no seed left in any worktree" [ "$(seeds)" = 0 ]

echo "-- T5. the timer applies a new candidate: /etc is untouched"
run bash "$U"
check "T5 timer applied main's tip (0)" [ "$RC $(S 's["applied_rev"]')" = "0 $(sha)" ]
check "T5 /etc kept the edits" [ "$(etc_get)" = "edited-t3 9" ]

echo "-- X1. bootstrap re-run at the applied commit with --set, 00-a fails before 05: warned, /etc untouched"
AW=$(readlink -f "$SB/opt/applied"); touch "$AW/setup/IFAIL-00-a"
run bash "$AW/setup/bootstrap.sh" --role portable --no-reboot --set archive.min_free_gb=11
check "X1 rolled back (2)" [ "$RC" = 2 ]
check "X1 warned the input was discarded" grep -q "input was discarded" "$SB/out.txt"
check "X1 /etc untouched" [ "$(etc_get)" = "edited-t3 9" ]
check "X1 no seed left" [ "$(seeds)" = 0 ]
rm -f "$AW/setup/IFAIL-00-a"
echo "-- X2. set -e failure at stage steps before any step, re-run with --set: on_exit drops the seed before rollback"
# shellcheck disable=SC2016  # $CAND_WT is update.sh's text, matched and written literally
sed 's#^    run_steps "\$CAND_WT" "" || ok=0$#    [[ ! -e $CAND_WT/setup/BOOM ]]\n&#' "$REAL/setup/update.sh" >"$SB/patched.sh"
grep -q 'setup/BOOM' "$SB/patched.sh" || bad "X2 the patch point in update.sh was not found"
UPD_SRC=$SB/patched.sh remap_update >"$R/setup/update.sh"; commit "x2: boom-able"
run bash "$U"; check "X2 timer applied the boom-able commit" [ "$RC" = 0 ]
AW=$(readlink -f "$SB/opt/applied"); touch "$AW/setup/BOOM"
run bash "$AW/setup/bootstrap.sh" --role portable --no-reboot --set archive.min_free_gb=12
check "X2 stopped unexpectedly at stage steps" grep -q "stopped unexpectedly .* at stage steps" "$SB/out.txt"
check "X2 warned the input was discarded" grep -q "input was discarded" "$SB/out.txt"
check "X2 the rollback ran" grep -q "ROLLING BACK" "$SB/out.txt"
check "X2 /etc untouched by the rollback's 05" [ "$(etc_get)" = "edited-t3 9" ]
check "X2 no seed left" [ "$(seeds)" = 0 ]
echo
echo "smoke: $NPASS passed, $NFAIL failed"
if ((NPASS + NFAIL != EXPECTED_CHECKS)); then
  echo "smoke: $((NPASS + NFAIL)) checks ran, EXPECTED_CHECKS is $EXPECTED_CHECKS"; exit 1
fi
((NFAIL == 0))
