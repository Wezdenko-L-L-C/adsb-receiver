# Plan — the architecture, and why it is this way

⭐ **This document holds the reasoning.** [BUILD.md](BUILD.md) says what to buy and in what order;
[RADIOS.md](RADIOS.md) says what each radio is for. This says *why the shape is the shape*, and it
records what was rejected alongside what was chosen — because a rejected option with no reason
attached gets proposed again in six months.

ℹ️ Decisions are dated. 📋 marks what is planned but not yet done; **Proposed** marks what has not
been decided at all.

---

## 1. One base, several radio slots

**Decided 2026-08-30.**

The original framing welded the second radio to the rig's identity: portable *was* 1090 + airband,
stationary *was* 1090 + VDL2, and ⛔ "neither rig runs three dongles."

➡️ **That is now wrong.** The shape is a **base station plus expansion slots**:

```
  ┌─ BASE ──────────────────────────────┐
  │  Pi + 1090 MHz SDR + collinear/whip │   the part that differs by rig
  │  clock, position, power, antenna    │
  └─────────────┬───────────────────────┘
                │
     ┌──────────┴───────────┐  orthogonal: populate per site, not per rig type
     │  ATC audio           │
     │  ACARS (VHF POA)     │
     │  VDL2                │
     │  HFDL                │
     │  SATCOM (L-band)     │
     └──────────────────────┘
```

🔑 **The two-rig thesis survives this intact, because it was never about the radios.** Portable and
stationary want opposite things from the *base* — clock source, position, power, antenna, whether
there is a network. Those are still opposite. What was wrong was treating the radio choice as if it
followed from that split. It does not; it follows from **where the site is and what you want to
hear there**.

⛔ **Rejected: keeping the exclusive framing.** It reads tidier and it is false. A stationary site
with a scanner on it is an obviously reasonable thing to want, and the old text forbade it on a
technicality about correlation.

⚠️ **What stays true from the old framing:** airband audio earns its keep *most* on the portable
rig, because that is where it composes with timestamp correlation — the same clock joins the frame,
the track and the tower transmission. That argument is about **correlation**, not about exclusivity,
and it does not stop a stationary site from wanting a scanner for its own sake.

---

## 2. The slots

| Slot | Band | Decoder | Antenna | Status |
|---|---|---|---|---|
| **1090 ADS-B** | 1090 MHz | `readsb` | collinear 🏠 / whip 🎒 | The base. Not a slot |
| **ATC audio** | 118–137 MHz | `rtl_airband` | dipole or discone | 📋 Either rig |
| **VDL2** | 136.650–136.975 | `dumpvdl2` | discone | 📋 Stationary first |
| **ACARS (POA)** | 131.550 + others | `acarsdec` | discone | 📋 Legacy traffic, low priority |
| **HFDL** | 2–22 MHz | `dumphfdl` | ⛔ **its own HF antenna** | 📋 Conditional — see below |
| **SATCOM Aero** | ~1.5 GHz | `JAERO` | ⛔ **aimed L-band patch** | 📋 Deferred |

⚠️ **Every slot is one more dongle.** There is no software that makes two bands share one radio —
an RTL-SDR sees ~2.4 MHz at a time, and these bands are nowhere near each other.

### ⛔ Two slots need hardware the parts list does not cover

**HFDL needs an HF antenna.** A discone starts at 25 MHz, so it is deaf across the entire HFDL
range. This wants its own wire, dipole or broadband loop, and the V4's upconverter to receive it
([RADIOS.md §1](RADIOS.md#1-each-radio-is-its-own-dongle)).

⭐ **HFDL's value is a function of where the site is.** [RADIOS.md §4](RADIOS.md#4-acars--vdl2--a-second-witness-to-the-tail-number-stationary)
calls it "low yield inland" — which is right, and which **inverts at a coastal site facing an
oceanic route structure.** HFDL is how aircraft talk over water. ➡️ If the stationary site ends up
on a coast with ocean traffic offshore, HFDL moves from a curiosity to one of the better slots. If
it ends up inland, it stays a curiosity.

**SATCOM needs an aimed antenna.** An L-band patch pointed at a geostationary satellite is a mount,
an aim and a clear line of sight — a siting problem, not a dongle you plug in. ➡️ Deferred, and it
should stay deferred until every cheaper slot is boring.

---

## 3. 🔑 CPU is the binding constraint, not power

This is the thing that decides how many slots a machine can hold, and it is not the thing that
looks scariest.

**Power looks like the limit and is not.** Five dongles draw ~1.5 A against a Pi 4's ~1.2 A USB
budget — over it, and the symptom is undervoltage, which
[BUILD.md §1](BUILD.md#1-which-pi) warns looks exactly like an antenna problem. ➡️ But a powered
hub fixes it. It is a part you buy. Solved problems are not constraints.

**CPU is the limit, and no part fixes it.** A Pi 4 has four cores:

| Process | Cores |
|---|---|
| `readsb` — 1090 | ~0.5 ✅ |
| `dumpvdl2` | ~0.5 ✅ |
| `rtl_airband` | ~0.4 ✅ |
| `acarsdec` — POA | ~0.3 ⚠️ |
| `dumphfdl` | ~0.6–1.0 ⚠️ HF demodulation is the heavy one |
| tar1090, web UI, archive writer, feeder clients | ~0.7 ⚠️ |

⚠️ **Only the first three figures come from anywhere real** — they are the ones already quoted in
[RADIOS.md §5](RADIOS.md#5-what-a-second-dongle-does-to-the-pi) rule 4. The rest are estimates and
have not been measured on a Pi. ✅ marks a figure with a source; ⚠️ marks a guess.

➡️ **Even allowing for the guesses being wrong, the shape holds: about three radios fit a Pi 4
comfortably, and five do not.** Five puts you near 3.5 of 4 cores with the archive writer competing
for the remainder, on a board that already throttles under sustained load.

---

## 4. Proposed: split the stationary site across two Pis

**Proposed 2026-08-30. Not decided.**

⭐ **This follows from a rule the project already has.** [BUILD.md §8](BUILD.md#8-build-order)
step 5 says to add a second radio only once the base rig is boring, *because adding dongles is
exactly what destabilizes a working receiver.*

🔑 **Take that seriously and the conclusion is uncomfortable: the machine that owns the archive is
the last machine you should be hot-plugging a fifth SDR into.** The archive is the reason the
stationary rig exists, an archive with holes in it is not an archive, and every slot added to that
box is a chance to put a hole in it.

➡️ So:

| | Runs | Job |
|---|---|---|
| **🏠 Archive Pi** | `readsb`, archive writer, feeders, tar1090 | ⛔ Stays boring. Nothing gets added here casually |
| **📻 Radio Pi** | VDL2, airband, ACARS, HFDL, `acarshub` | Where experimenting costs nothing that matters |

They share a LAN, and the web interface (§5) spans both. This also sidesteps §3's CPU ceiling
without needing a faster board.

⛔ **Rejected: one Pi running everything.** It puts the archive — the only irreplaceable thing at
this site — on the same box as the experiments, and it runs out of cores at about three slots.

⛔ **Rejected for now: a Pi 5 or a mini-PC instead of splitting.** It solves the CPU ceiling and
not the stability one; a faster box still has the archive sharing a kernel with whatever dongle you
just plugged in. ℹ️ Reconsider if the two-Pi split turns out to cost more in operational
complexity — two machines to keep headless, updated and reachable — than it buys in isolation.

---

## 5. Proposed: the web interface is three existing services, not a new one

**Proposed 2026-08-30. Not decided.**

📋 The goal: **one page on the local network** showing aircraft, ACARS/VDL2 messages, and playable
ATC audio.

| Want | Service |
|---|---|
| Aircraft map | **`tar1090`** — already in the stack |
| Messages, searchable, with alerts | **`acarshub`** — ingests `acarsdec`, `dumpvdl2` *and* `dumphfdl` |
| ATC audio | **`rtl_airband` → Icecast**, embedded in a page |

⭐ **`acarshub` is very close to the thing being asked for**, including a message database, search,
and feeding [airframes.io](https://airframes.io). ➡️ "One page showing planes, messages and tower
audio" is then a nav bar over three services rather than an application to write.

⛔ **Rejected: writing a bespoke UI.** It is the most fun option and the least defensible one. Every
hour spent on it is an hour not spent on the archive writer and the extractor, which do not exist
and which nothing else in the world provides — whereas a decent ACARS UI already exists.

⚠️ **Local network only.** These services assume a trusted LAN and none of them should be exposed
to the internet. Remote access is Tailscale or equivalent, per
[BUILD.md §2](BUILD.md#2-two-rigs-not-one).

---

## 6. Antennas: one per band, not one split five ways

⚠️ **Three VHF decoders cannot share one discone for free.** A passive splitter costs 3–5 dB per
split, and at that point the filter and LNA work described in
[RADIOS.md §2](RADIOS.md#2-your-1090-antenna-will-not-hear-any-of-this) is being thrown away at
the splitter.

➡️ Either separate antennas per decoder, or an **active multicoupler** — an amplified splitter
designed for exactly this. ⛔ Do not passively split a signal three ways and then wonder why the
message rate dropped.

📋 A fully-populated stationary site therefore wants roughly: a 1090 collinear, a discone for the
VHF cluster (through a multicoupler), an HF wire or loop, and — eventually — an aimed L-band patch.
That is four masts' worth of thinking, which is another argument for populating slots one at a time.

---

## 7. What this changes in the existing docs

📋 Not yet reconciled. [RADIOS.md](RADIOS.md) currently contradicts §1 of this document in three
places:

| Where | Says | Should say |
|---|---|---|
| RADIOS.md intro | ⭐ "They do not both go on the same rig" | Airband earns its keep *most* on the portable rig — not exclusively |
| RADIOS.md intro | ➡️ "So neither rig runs three dongles" | A stationary site may run several; §3 here is the real limit |
| BUILD.md §3d | "The second radio" — one purchase | A slot, populated more than once |
| RADIOS.md §4 | HFDL "low yield inland" | True inland; inverts on a coast facing ocean traffic |

⚠️ Until that is done, RADIOS.md is the stale one and this document is the current thinking.

---

## 8. Sequencing

⛔ **None of this changes the build order.** [BUILD.md §8](BUILD.md#8-build-order) still applies:
the portable rig first, drivers first, second radio only once the base is boring. Slots are added
**one at a time**, and each one is allowed to be boring before the next arrives.

➡️ Rough order, with everything after the first line still 📋:

1. Both base rigs working, per BUILD.md §8.
2. VDL2 on the stationary site — the highest-yield slot, and the one that pays for the archive.
3. `acarshub` + `tar1090` behind one page. The UI is worth having as soon as there are two data
   sources to look at.
4. Airband, on whichever rig wants it. Portable for correlation, stationary for a scanner.
5. HFDL — **only if the site turns out to be coastal.** Inland, skip it.
6. ACARS POA, if VDL2 turns out to be missing traffic worth having.
7. SATCOM. A project in itself, and last for good reason.

---

## 9. The software: step scripts run from a clone on the Pi, updating themselves

**Decided 2026-10-03, Chris.** The design was a recommendation from an architecture consultation
the same day. Chris accepted it to be recorded, and that acceptance is the decision. The four
choices he made himself are marked **(Chris)** where they come up.

📋 **~~None of this software exists yet.~~** *Part of it exists; see the 2026-10-04 update below.*
~~Every path under `setup/`, `bin/` and the CI workflow named below is planned, not written.~~ The
hardware facts in [§9j](#9j--verified-on-hardware-2026-10-03) ~~are the only part of this section
that has been run~~ *are the only part of this section recorded as run.*

**Update 2026-10-04.** That status has been false since 2026-10-03. Commit `95bcba6` added
`setup/lib.sh`, `setup/steps/00-drivers.sh` and the CI workflow `.github/workflows/ci.yml`, in one
change. ➡️ [§9k](#9k-the-first-deliverable-in-order) item 1 is done.

- `lib.sh` holds the shared helpers: `--verify` parsing, reading `station.yml` with `python3` and
  `yaml`, the role checks of [§9b](#9b-one-bash-script-per-build-step), and the
  [§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away) denylist. A
  `systemctl` wrapper, `unit`, refuses denylisted units, and `00-drivers.sh` calls it. A write
  guard, `guard_path`, is defined, but no step calls it yet.
- `00-drivers.sh` installs `rtl-sdr` from apt, and its verify reads the output of `rtl_test -t` and
  `rtl_eeprom`.
- CI runs `bash -n`, `shellcheck`, the §9h denylist grep, and a check that every step has a
  `verify` and takes `--verify`. ⚠️ **The arm64 trixie dry run and the job that fast-forwards
  `stable`, both in [§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable), are not
  built.** The workflow marks both as TODO for §9k item 3.
- Still not written: `bin/`, `setup/foundation/`, `05-config`, `10-decoder`, `update.sh`, the
  timers, `status.json`, and the clock steps.

`00-drivers.sh` has been run once, on the 🎒 portable rig on 2026-10-03. Its verify failed when the
stick dropped off the USB bus during the check. ⚠️ That run is not recorded in §9j: its output was
not pasted here, and [§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect) says a record of
a run goes in the docs with the output pasted.

### 9a. The repo ships its own software, and the Pi pulls it

**(Chris)** The repo is a **build guide that ships its own software**. The README has said so since
commit `f12ab48`.

🔑 **The software runs on the Pi, from a clone of this public repo.** That direction was settled on
2026-08-29, in the founding commit `0b28b85`, which made the repo public so a Pi can pull it with no
credential on the device:

> *"Public, with no secrets in it, makes the update path `git clone` and reduces a stolen rig to a
> hardware loss."*

ℹ️ Until this section, that reasoning existed only in the commit message. ➡️ It is why Ansible, or
any config management pushed from a workstation, is rejected in [§9l](#9l-rejected): it reverses
that direction. The other options rejected there have reasons of their own.

### 9b. One bash script per build step

Plain, idempotent bash with `set -euo pipefail`. Each step in [BUILD.md §8](BUILD.md#8-build-order)
is one script in `setup/steps/NN-*.sh`, and shared helpers go in `setup/lib.sh`.

- **Shared steps are shared files.** `00-drivers` and `10-decoder` are one file each, because
  BUILD.md §8 steps 0–1 are identical for both rigs.
- **Role-specific steps are separate files.** `20-portable-clock` and `20-stationary-clock` each
  read `station.yml`, assert `station.role`, and **refuse the other role's blocks.** The portable
  step refuses a `position:` block. The stationary step refuses `clock.source` other than `ntp`,
  and refuses an `uploader:` block.
- ⭐ **That turns the templates' "do not merge" comments into exit codes.** Today the split between
  the two `config/station.*.example.yml` files is held up by comments alone. Once these steps exist,
  setting the wrong half makes a step fail.
- ⛔ **No `--role` flag anywhere.** The role comes from the config the rig already carries.

**Update 2026-10-04: how `update.sh` skips the other role's steps. (Chris), 2026-10-04.** 📋 Not
built. `update.sh` runs the candidate's steps ([§9f](#9f-what-updatesh-does)), and a role-specific
step dies in `require_role` on the other rig. Without a rule for that, every update on one rig would
fail on the other rig's steps.

- `parse_args` in `lib.sh` gains `--skip-other-role`. With it, `require_role` on a mismatch logs
  *"skipped: this step is for the X rig; station.yml says Y"* and exits a reserved code,
  `ADSB_RC_OTHER_ROLE`. That is a `lib.sh` constant, any unused value below 126, such as 100. ⛔ It
  is not 3, which `lib.sh` already uses internally for an absent key in `station_get`. Without the
  flag, `require_role` dies, as it does today.
- `require_absent` is unchanged, and dies in every mode.
- ➡️ **The flag names no role**, so the rule above holds: there is still no `--role` flag, and the
  role still comes from the config. The flag only changes what a mismatch means. Run by hand, the
  wrong step still refuses.
- **A step that calls `require_role` calls it before any other command.** The order is
  `set -euo pipefail`, `source lib.sh`, `parse_args`, `require_root`, `require_role`, then
  everything else, so a skip never half-runs. ℹ️ Because `require_root`'s sudo re-exec comes first,
  a human running the wrong step may be asked for a password and then refused. That is today's
  behavior, and it is acceptable.
- Rejected:
  - a role header that `update.sh` greps, which makes two truths;
  - a per-role manifest, which is `--role` by another door;
  - the filename as the role, because `30-archive-drive` is deliberately generic
    ([§9m](#9m--the-portable-rigs-archive-drive));
  - `update.sh` passing the role;
  - grepping the step sources for `require_role`;
  - an environment variable, which leaks to children and is invisible in `ps`;
  - a separate `--applies` mode.

### 9c. Every step ends in a check of the observable effect

Every step ends in a `verify` that checks **what the step was for, not the setting that claims it**:

| Checks this | Not this |
|---|---|
| ~~`rtl_test -t` names the R828D and prints `RTL-SDR Blog V4 Detected`~~ *`rtl_test -t` opens a device and names its tuner. An R828D must come with `RTL-SDR Blog V4 Detected`, and a V4 line on any other tuner fails. Any other tuner passes, with a warning that is louder when `rtl_eeprom` claims Blog or V4. Interim; see the 2026-10-04 update below* | `dpkg -l` shows the package |
| ~~`chronyc tracking` reports an offset inside `clock.max_offset_ms`~~ *The chain is wired and delivering: `gpsd` has the puck, and `chrony` lists the refclock. The offset check moves to the preflight. Corrected 2026-10-04; see the update on two tiers below* | `systemctl is-active chrony` |
| `aircraft.json` is advancing | `systemctl is-active readsb` |

**Update 2026-10-04: an interim ruling.** The first row did not describe the verify in
`setup/steps/00-drivers.sh`. That verify does fail an R828D with no V4 line, the
[BUILD.md §4](BUILD.md#4-drivers-first) silent failure. But it passes any other tuner, such as the
R820T on the stick in [§9j](#9j--verified-on-hardware-2026-10-03), with a warning, and exits 0.
**(Chris), 2026-10-04:** the code stands and the row changes, *"I do not have a genuine V4 yet so the
later while waiting for a genuine V4"* ("the later" being the code's behavior). A verify that
required the R828D would fail on the only stick in hand. ⚠️ **This holds only while no genuine V4 is
in hand.** Whether the verify goes back to requiring the R828D and the V4 line once one is, is not
yet ruled.

The verify prints its raw evidence and exits non-zero on failure. `--verify` runs the check on its
own.

⭐ **This is how the README's rule survives automation.** The README says ✅ marks *"the check to run,
or the fix to apply — never a claim that the part was tested here."* A script that checks the effect
and prints it is that check, run. ⛔ **So no script carries a "tested on" header.** A record of a
verified run goes in the docs, with the output pasted.

**Update 2026-10-04: what a verify may do to a running rig. (Chris), 2026-10-04:** ⛔ **a verify may
interrupt the rig for seconds and must restore it. It may never end a recording session.**
`00-drivers` stopping `readsb` briefly for its check, and starting it again on the way out, is within
the rule. The reason: `update.sh` runs every step's verify ([§9f](#9f-what-updatesh-does)), and a
verify for the pull step that started the pull window would end a session, and trigger an update
from inside an update ([§9m](#9m--the-portable-rigs-archive-drive)).

**Update 2026-10-04: two tiers, checked by two programs. (Chris), 2026-10-04.** 📋 Not built.

- **A step's `--verify` checks the install tier:** what the step put in place is in place and
  wired, observed by effects that depend on nothing outside the rig.
- **The preflights, `bin/clock-preflight` and `bin/archive-preflight`, check the readiness tier:**
  whether the world allows recording now. Their exit codes are a fixed interface
  ([§9i](#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader)). An install-tier verify
  that invokes a preflight treats `0` and `2` as a pass, and `1` as a failure.
- `update.sh`'s full verify is the install tier of every step that applies to the rig
  ([§9f](#9f-what-updatesh-does)).
- The reason: a verify that fails on the sky cannot tell "the update broke chrony" from "the rig is
  in the garage", and the 🎒 portable updates only at home, inside the pull window (§9m).
  ➡️ [BUILD.md §7](BUILD.md#7-software) rule 4 stays exactly true, as the preflight's gate on the
  writer's unit.
- **That is why the second row of the table above was corrected.** The offset inside
  `clock.max_offset_ms` is readiness, so it moves to `clock-preflight`.
- Rejected:
  - gating every update on the preflights, on both rigs;
  - gating on no readiness anywhere, which throws away the stationary rig's signal;
  - a lenient `--installed-only` flag, or an environment variable, on one verify, because
    `update.sh` would always choose lenient;
  - a verify that passes with a warning when there is no fix, which judges the sky inside the
    verify;
  - `clock.require_disciplined: false` at home, which records undisciplined time.

**The install-tier verifies, step by step. (Chris), 2026-10-04:**

- `20-portable-clock`: `gpsd` has the puck open and NMEA arrives (`gpspipe -r -n 5`; indoors a puck
  emits GGA with fix quality 0). `chronyc sources` lists the GPS refclock, whatever its reach.
  `hwclock -r` reads a plausible time from `/dev/rtc0`. `systemd-timesyncd` is inactive and masked.
  `clock-preflight` exits `0` or `2`.
- `20-stationary-clock`: `chrony` has NTP sources with nonzero reach; `systemd-timesyncd` is masked;
  `clock-preflight` exits `0` or `2`.
- The writer's step and `30-archive-drive`: see §9m. **(Chris), 2026-10-04:** the archive drive is
  install tier. A dead drive fails step 30's verify, and updates stop applying until it is replaced,
  with `failed_step` naming it. Rejected: classing the drive as readiness, because a portable with no
  drive would keep updating while refusing to record.
- ⚠️ **Unverified:** that the puck in the parts list emits NMEA with fix quality 0 indoors, and
  that `chronyc sources` lists a refclock with reach 0 before its first sample.
- ➡️ [BUILD.md §8](BUILD.md#8-build-order) step 2's "`chronyc sources` shows GPS disciplining the
  clock", and its power cycle with the network unplugged, stay human gates, under the sky.

### 9d. Config

- You edit a copy at `config/station.yml`. It is gitignored (`config/station*.yml` in `.gitignore`),
  so `git pull` never touches it.
- `setup/steps/05-config.sh` installs it to `/etc/adsb-receiver/station.yml`, owned by root, mode
  `0600`.
- Scripts read it with `python3` and its `yaml` module. Runtime state lives under
  `/var/lib/adsb-receiver/`.

### 9e. The first build is by hand; after that, updates are automatic

**The first build is by hand, one step at a time.** BUILD.md §8 has human gates in it: a sky check,
a power cycle with the network unplugged. A script cannot pass those for you. After the first build,
`setup/update.sh` orchestrates.

**(Chris) Updates are automatic, on both rigs.** *"I really do not like updating by hand."*

⚠️ **Chris overruled an earlier recommendation, on 2026-10-03, to never update automatically.**
The one risk raised against automation was that **a broken update leaves an unattended archive with
a gap in it.** ➡️ That risk is what the rest of this section exists to answer: the CI gate
([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable)), every step's own verify
([§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect)), and rollback
([§9f](#9f-what-updatesh-does)).

### 9f. What `update.sh` does

A systemd timer runs `update.sh` as a oneshot.

| | 🏠 Stationary | 🎒 Portable |
|---|---|---|
| **When** | Nightly, ~03:30 local time, with a randomized delay, `Persistent` | ~3 min after boot, and daily |
| **No network** | — | The fetch fails and it exits silently. That is normal in the field |

In order:

1. Heal an interrupted `apt`.
2. Fetch.
3. Resolve the candidate SHA for the rig's channel ([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable)).
   **If it has not changed, exit having touched nothing.**
4. Check the candidate out into a **second worktree** (blue/green, detached SHAs, ⛔ never a tracking
   branch).
5. Run the candidate's steps.
6. Run the full verify.
7. Flip an `applied` symlink, then write `applied-rev` and `status.json`, **last**.

⚠️ **On any failure:** flip back, re-run the old steps, and record `failed_step`.

- **A service restarts only if its rendered config or its binary changed.** Render, diff, then
  install.
- ⛔ **Never during a recording session.** `update.sh` takes a `flock` on a recording lock.
- ⛔ **Never reboots.** It sets `reboot_required` instead.

**Update 2026-10-04: when the 🎒 portable rig updates.** Both rigs now archive everything
([§9m](#9m--the-portable-rigs-archive-drive)), so the portable records whenever it is on. With the
recording lock above, it would never update. **(Chris), 2026-10-04: the pull ends the recording
session.** Starting the pull window, `adsb-pull-window.service`, stops the writer and pulls in the
same update oneshot the timer runs, ordered after the writer's stop. When the window ends, it starts
the writer again; after a reboot, the next boot does. The mechanism is in §9m. 📋 None of this is
built. ➡️ The ⛔ above stands: `update.sh` still never runs during a recording session. The ordering and the lock are two
mechanisms, and the lock stays as the backstop. The portable's timer also stays. While the rig is
recording, the timer fires into a held lock and exits, and it remains the update path for a rig that
is refusing to record.

- **(Chris), 2026-10-04: the writer's unit holds the recording lock** exactly as long as the writer
  runs. The lock is `/run/adsb-receiver/recording.lock`, on tmpfs (§9m).
- **(Chris), 2026-10-04: the lock is asymmetric.** `update.sh` keeps `flock -n`, and exits if the lock
  is held. The writer takes the lock blocking, with no timeout, so a writer started in the middle of
  an update waits, then records.
- ⭐ **So the full verify that `update.sh` runs can never assert that the writer is active.**
  `update.sh` holds the lock while it runs, so the writer cannot be recording. The verify for the
  writer's step checks the install instead (§9m): the unit loads, is enabled and is not failed;
  both preflights exit `0` or `2`, never `1`; and `lslocks` shows the lock held by exactly one
  process whenever the writer or `update.sh` runs. ⛔ It never checks `is-active` of the writer.
  Otherwise every update would roll back.
- **(Chris), 2026-10-04: the pull window's 2 h cap bounds only how long the pull keeps the writer
  off.** An update that overruns the window is the lock's job. At the cap the window stops and the
  writer starts, waits on the lock, and records once the update finishes. Nothing kills an update
  partway through.
- 📋 **For `update.sh`'s own design ([§9k](#9k-the-first-deliverable-in-order) item 3):** it needs
  its own `TimeoutStartSec`, and it must roll back on SIGTERM. Flipping the `applied` symlink last
  (step 7 above) is what keeps a killed update from counting as applied.

**Update 2026-10-04: which steps run, and what the full verify checks. (Chris), 2026-10-04.** 📋 Not
built.

- **Steps 5 and 6 call every step with `--skip-other-role`:** `step.sh --skip-other-role`, then
  `step.sh --verify --skip-other-role`. Exit `0` is done. `ADSB_RC_OTHER_ROLE` is recorded in
  `status.json` as "skipped (role)". Anything else is the failure that triggers rollback. The flag
  and the code are in [§9b](#9b-one-bash-script-per-build-step).
- **The full verify in step 6 is the install tier** of every step that applies to the rig
  ([§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect)). It does not judge the sky.
- **Readiness gating depends on the role, and `update.sh` reads `station.role` to choose.** On the
  🏠 stationary rig it keeps [§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away)'s
  "before committing an update" list as written, `clock-preflight` passing included, because NTP at
  a house is guaranteed and a failure there means something broke. On the 🎒 portable, no readiness
  check gates an update. The preflight verdicts go to `status.json` and the login banner.
- ⭐ **§9h's "`clock-preflight` passes" was already a role-specific gate in general clothing.** So
  `update.sh` has needed `station.role` since §9h was written.

### 9g. Channels: portable tracks `main`, stationary tracks `stable`

- 🎒 **The portable rig tracks `main`.**
- 🏠 **The stationary rig tracks a `stable` branch** that GitHub Actions fast-forwards when CI is
  green. CI runs `shellcheck`, `bash -n`, a dry run of every step in an arm64 trixie container
  against sample-filled templates (including the role-refusal paths), and a grep for the denylist in
  [§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away).
- ⭐ **The workflow's `GITHUB_TOKEN` is the only write credential, and it lives in GitHub, not on a
  device.** That keeps [§9a](#9a-the-repo-ships-its-own-software-and-the-pi-pulls-it)'s
  no-credential-on-the-Pi property intact.
- 🏠 The stationary rig also only takes commits older than `update.soak_days` (7 days).

🔑 **The gate is CI, the rig's own verify, and rollback.** ⚠️ **The portable rig is an opportunistic
canary, not a gate.** It is often powered off for weeks, so a bad commit may reach `stable` before
the portable has ever run it.

➡️ **Emergency brake:** force-push a known-good SHA to `stable`.

**Update 2026-10-04: CI and the role skip. (Chris), 2026-10-04.**

- 📋 **Now:** one cheap check. In every step that contains `require_role`, the first non-comment
  command after `parse_args` and `require_root` is the `require_role` call
  ([§9b](#9b-one-bash-script-per-build-step)). The two existing checks, the denylist grep and the
  check that every step has a `verify` and takes `--verify`, do not change. `--skip-other-role` is
  parsed in `lib.sh`.
- 📋 **The planned dry run above** ([§9k](#9k-the-first-deliverable-in-order) item 3) gains a case:
  each role-gated step, run against the other role's template, exits `ADSB_RC_OTHER_ROLE` with
  `--skip-other-role`, and non-zero without it.

### 9h. 🏠 The stationary rig runs at a remote site, hundreds of miles away

**(Chris)** The stationary rig will sit, static, at a remote site hundreds of miles from Chris. It
is built at Chris's build site first and then moved.

**(Chris) The foundation layer is the one thing updated by hand.** Tailscale, the watchdogs and the
boot disk live in `setup/foundation/`. Those scripts are run by hand, and they are outside
`update.sh`'s reach.

⛔ **`update.sh` cannot touch what keeps the rig reachable.** The install and restart helpers in
`lib.sh` carry a denylist, and CI greps `setup/steps/` for it:

| Paths | Units |
|---|---|
| `/boot/firmware`, `/etc/network*`, `/etc/NetworkManager`, `/etc/systemd/network`, `/etc/ssh`, `/etc/apt/sources.list*`, 📋 *`/etc/fstab` (decided 2026-10-04, not yet in `lib.sh`; see below)* | `tailscaled`, `ssh`, `NetworkManager` |

**Update 2026-10-04: `/etc/fstab` joins the denylist.** **(Chris), 2026-10-04.** It is a guard: no
step writes `/etc/fstab` under the archive-drive design, which mounts the drive with a systemd mount
unit instead ([§9m](#9m--the-portable-rigs-archive-drive)). ⚠️ **`ADSB_DENY_PATHS` in `setup/lib.sh`
must change with this table, and has not yet.** Its comment says the list is written as in this
table, and CI reads that array, so until it changes the CI grep does not check for `/etc/fstab`.

**Update 2026-10-04: a step installs a sudoers drop-in.** ⚠️ The 🎒 portable's pull step,
`NN-portable-pull.sh`, installs `/etc/sudoers.d/adsb-receiver`
([§9m](#9m--the-portable-rigs-archive-drive)). That is a new reachability hazard installed by a step:
a parse error in any `sudoers.d` file makes sudo refuse everyone, and on a remote rig a refusing sudo
would be a reachability failure. ➡️ The step validates the rendered file with `visudo -cf` before
installing it, and it is role-specific: it asserts the portable role
([§9b](#9b-one-bash-script-per-build-step)). The denylist table above is unchanged.

**Before committing an update**, all of these must hold: Tailscale's `BackendState` is `Running`
and the node is online; outbound https to github.com works; `readsb` answers on port 30005; and
`clock-preflight` passes.

**Update 2026-10-04: this gate is 🏠 stationary-only. (Chris), 2026-10-04.** `update.sh` reads
`station.role`, and applies the list above only on the stationary rig, as written. NTP at a house is
guaranteed, so a failure there means something broke. On the 🎒 portable no readiness check gates an
update ([§9f](#9f-what-updatesh-does)). ℹ️ "Passes" here means `clock-preflight` exits `0`
([§9i](#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader)).

**Recovery, in layers:**

1. The hardware watchdog.
2. A network watchdog: no route for 60 minutes means a reboot, at most once every 6 hours.
3. A smart plug, controlled from Chris's phone through the vendor's cloud. ⛔ **Deliberately not
   through Tailscale**, so it still works when Tailscale is the thing that broke.
4. Boot from the USB SSD, with no SD card. ⚠️ That needs a powered hub or a low-draw enclosure. It
   is a power-budget question, the same one [§3](#3--cpu-is-the-binding-constraint-not-power) says a
   part solves.

Also: `unattended-upgrades` for security updates only, with no automatic reboot. Ask the host for a
wired port.

**Health is pushed, not pulled:**

- A daily Discord heartbeat.
- An immediate post on a rollback, a stopped writer, low disk space, or a watchdog reboot.
- A healthchecks.io dead-man ping, so a **missing** heartbeat emails Chris.
- The webhook and ping URLs live in `station.yml`. They are credentials, and that file is the
  credential seam.

🎒 The portable rig gets a login banner and `status.json`, and nothing more.

**The pre-ship checklist, run at the build site before the rig moves:**

- [ ] Sky check with the real collinear.
- [ ] Three cold power cuts. After each one, the rig is reachable from a phone on cellular, over
  Tailscale, within 5 minutes.
- [ ] A smart-plug power cycle, triggered from cellular.
- [ ] WAN unplugged for 2 hours: exactly one watchdog reboot, then recovery.
- [ ] One full automatic update, including a deliberately failing commit that rolls back.
- [ ] A retention fill test.
- [ ] Tailscale key expiry disabled.
- [ ] The heartbeat and a failure alert both received.

### 9i. What is not chosen yet: the writer, the extractor, the uploader

⛔ **Their language and packaging are not chosen now.** BUILD.md §8 step 4 says to write the uploader
last, and [BUILD.md §9](BUILD.md#9--the-archive-and-feeding) says to build the extractor alongside
the writer. Choosing for them now would get ahead of both.

**Only the interfaces are fixed:**

- `readsb` BEAST output on port 30005.
- `/etc/adsb-receiver/`, and `/var/lib/adsb-receiver/{spool,archive}`.
- `bin/clock-preflight` comes first. It parses `chronyc tracking` against `clock.max_offset_ms`
  and `clock.require_disciplined`.

📋 **OPEN ITEM — what time is in a BEAST frame?** It is **believed, not verified**, that BEAST frames
from `readsb` on an RTL-SDR carry a 12 MHz MLAT counter rather than UTC. If that is true, the writer
has to supply wall time itself. ➡️ Settle it on the bench before designing the writer: capture port
30005 and compare the frame timestamps against `date`.

**Update 2026-10-04: the archive drive.** 📋 Decided, not built; see
[§9m](#9m--the-portable-rigs-archive-drive).

- `/var/lib/adsb-receiver/archive` becomes a mount point. On the 🎒 portable rig it is where the
  archive drive is mounted. How the 🏠 stationary rig's SSD backs it is not decided.
- 🎒 On the portable rig the spool moves onto the drive: `uploader.spool_dir` becomes
  `/var/lib/adsb-receiver/archive/spool`. The rest of `/var/lib/adsb-receiver/` stays on the SD card.
- The storage contract for the writer in §9m is one of the fixed interfaces: UTC file names,
  10-minute rotation, `.part` while open, fsync, `.torn`, and group `adsb-operator` permissions. The
  writer's language and packaging are still not chosen.
- **(Chris), 2026-10-04:** the recording lock, `/run/adsb-receiver/recording.lock`, is one of the
  fixed interfaces too. It lives on tmpfs, in a directory created by a `tmpfiles.d` entry
  ([§9f](#9f-what-updatesh-does), §9m).
- **(Chris), 2026-10-04: the preflights' exit codes are a fixed interface.** For both
  `bin/clock-preflight` and `bin/archive-preflight`: `0` means ready; `2` means not ready, for a
  reason outside the rig, which is printed; `1` means the check itself could not run. The writer's
  unit treats any non-zero code as "do not start", and retries (§9m). An install-tier verify that
  invokes a preflight treats `0` and `2` as a pass, and `1` as a failure
  ([§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect)).
- ➡️ **The storage design does not wait on the open item above.** File names use the disciplined Pi
  clock's wall time. Only the writer's per-frame time depends on what a BEAST frame carries.

### 9j. ✅ Verified on hardware, 2026-10-03

Chris pasted this output from the 🎒 portable rig, a Pi 4 (4 GB) with hostname `mobile-adsb`:

- Raspberry Pi OS is **Debian 13 trixie**, kernel `6.18.50+rpt-rpi-v8`.
- `apt` offers `rtl-sdr` and `librtlsdr0` at **2.0.2-2+b1**, and installed them.
- `systemd-timesyncd` is active. `chrony` is not installed.
- `python3` imports `yaml`.
- ⚠️ **`apt policy readsb` shows `readsb` 3.14.1630+git20240609.adc080d-1 in Debian trixie
  `main`.** This corrects a belief from the consultation that `readsb` is not packaged.
  - **Update 2026-10-04: packaged, but built without RTL-SDR support.** ⚠️ *Packaged* does not mean
    *usable here.* Not from the rig: the trixie package was downloaded from deb.debian.org and
    inspected. Its arm64 `Depends` are `libc6, libncurses6, libtinfo6, libzstd1, zlib1g, adduser`,
    with no `librtlsdr0`. The binary's `NEEDED` libraries are `libm`, `libzstd`, `libz`,
    `libncurses`, `libtinfo` and `libc`, with no `librtlsdr`. Its help lists the device types
    `modesbeast`, `gnshulc` and `ifile`, and has no RTL-SDR options section. The cause is in the
    source package: `debian/rules` sets `RTLSDR=yes` only when the build profile `rtlsdr` is in
    `DEB_BUILD_PROFILES`, and the archive build does not use it. ➡️ **trixie's packaged `readsb`
    cannot drive an RTL-SDR at all.**
  - ➡️ **(Chris), 2026-10-04:** *"We build from source, but add it to an sh install for the pi -
    lets make this easy on ourselves."* **`readsb` is built from source, at a pinned commit, with
    RTL-SDR support, against the packaged `librtlsdr` 2.0.2, and never installed from apt.** The
    build is scripted in the step script the Pi runs, `10-decoder`, not done by hand. `tar1090`
    stays pinned by SHA.
  - ℹ️ Debian forky and sid carry `readsb` 3.16-2, whose arm64 `Depends` do include `librtlsdr0`
    (plus `libbladerf2`, `libhackrf0`, `libsoapysdr0.8`, `libiio0` and `libad9361-0`). trixie does
    not. On an upgrade to forky the apt package would become a working RTL-SDR decoder, and the
    [BUILD.md §4](BUILD.md#4-drivers-first) concern about apt pulling in a library would apply to it
    again.
- `tar1090` is **not** packaged (*"Unable to locate package"*).
- The `rtl-sdr` package installed **no** modprobe blacklist file. A grep of `/etc/modprobe.d` and
  `/usr/lib/modprobe.d` for `rtl28xxu` found nothing.
- The kernel's `dvb_usb_rtl28xxu` module loaded and claimed the device. **The packaged library
  detached the kernel driver itself** (*"Detached kernel driver"*) and carried on.

⚠️ **The stick is labeled a V4, and the software did not see a V4.** The first `rtl_test -t` failed
with `usb_open error -3`, a permissions error, because the dongle was plugged in before the udev
rules were installed. After a replug, with the user in `plugdev`, `rtl_test -t` reported the USB
strings *"Realtek, RTL2838UHIDIR, SN: 00000001"* and *"Found Rafael Micro R820T tuner"*. There was
**no** R828D and **no** `RTL-SDR Blog V4 Detected` line. It also printed `rtlsdr_write_reg failed
with -1` and `[R82XX] PLL not locked!`. A photo of the case, sent by Chris the same day, reads
*"RTL SDR BLOG … MODEL: V4"* and *"RTL-SDR.COM"*, with the boxes *"RTL2832U · R860 · TCXO · BIAS.T ·
HF"*. R860 is the marketing name for the R828D. The packaged 2.0.2 library opened the stick and
detached the kernel driver, but identified an R820T tuner and no V4.

⚠️ **The mismatch between the label and the chip ~~is unresolved~~** *~~most likely~~ means a counterfeit;
see the 2026-10-03 update below.* *The board settled it on 2026-10-04; see that update below.* The leading suspect is a
counterfeit V4: an R820T inside a V4 case. A rewritten EEPROM is less likely, because the library
probes the tuner by chip, not by the USB string. ℹ️ A genuine V4 is believed to report the USB
strings *"RTLSDRBlog, Blog V4"*. That belief is unverified.

**Update 2026-10-03.** Chris pasted the output of `rtl_eeprom` on the stick: Vendor ID `0x0bda`,
Product ID `0x2838`, Manufacturer *"Realtek"*, Product *"RTL2838UHIDIR"*, Serial *"00000001"*,
serial number enabled *yes*, IR endpoint enabled *yes*, remote wakeup *no*, and the tuner line
*"Found Rafael Micro R820T tuner"*. The stick was bought on Amazon (Chris, 2026-10-03). The seller
is not yet identified.

➡️ **The stick is ~~most likely~~ a counterfeit V4: a generic R820T TV-tuner stick in a printed V4
case.** That is not proven from software alone. The seller's name, or the marking on the PCB, would
settle it. *The marking on the PCB did, on 2026-10-04; see the update below.* ℹ️ *"IR endpoint
enabled: yes"* is believed to be a TV-dongle default that RTL-SDR Blog units ship with disabled.
That belief is unverified.

**Update 2026-10-04: the board.** Chris opened the case and sent photos of both sides of the case
and the board, with close-ups. ✅ Read from those photos:

- The tuner chip is marked *"Rafael Micro R820T2"*, then *"D3B2220GBC"* and *"1345ZE"*. It is not
  an R828D (marketed as R860), the tuner a V4 uses.
- The silkscreen carries the date *"2018.9.13"*, and no RTL-SDR Blog name, model or version.
  ℹ️ RTL-SDR Blog reports the V4's release as 2023, which would make the board older than the V4.
  That release date is unverified here.
- Also on the board: the RTL2832U, an 8-pin chip marked *"24C02A"*, a small 4-pad metal-can
  oscillator, and a thermal pad on the underside.
- The back of the case reads *"Genuine RTL-SDR Blog? Check at: www.rtl-sdr.com/genuine"* and
  *"Designed in New Zealand. Made in China."*

➡️ **The stick is a generic R820T2 board, a V3-class design, in a counterfeit V4 case.** That
matches the software: `rtl_test` printed an R820T tuner, and the library reports the R820T2 as
*"R820T"*.

**(Chris), 2026-10-03: return the stick, and buy a genuine V4** from RTL-SDR Blog's store or a
seller listed on rtl-sdr.com. Building continues on this stick meanwhile, because it decodes 1090
on the stock 2.0.2 library.

**(Chris), 2026-10-04:** *"I will return these."* He is returning them.

⛔ **V4 support on 2.0.2 is untested on a confirmed V4.** No run has shown an R828D or
`RTL-SDR Blog V4 Detected`.

### 9k. The first deliverable, in order

1. `setup/lib.sh` + `setup/steps/00-drivers.sh` + the CI workflow, **in one change.**
2. `05-config` + `10-decoder`.
3. `update.sh` + the timers + `status.json` + the job that advances `stable`.
4. `20-portable-clock` + `clock-preflight`.

The foundation scripts come when the stationary build starts.

### 9l. Rejected

⛔ **Rejected: Ansible, or any config management pushed from a workstation.** It reverses the pull
direction the public repo was made for
([§9a](#9a-the-repo-ships-its-own-software-and-the-pi-pulls-it)). It puts a control-node toolchain
in front of every reader. And its idempotence hides the check that
[§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect) exists to show.

⛔ **Rejected: a shipped image, or pi-gen.** It bakes in the driver version, which is the
[BUILD.md §4](BUILD.md#4-drivers-first) hazard again. An image is a tested claim. And it cannot be
`git pull`ed.

⛔ **Rejected: containers.** `gpsd`, `chrony`, the RTC overlay and the USB serials are host concerns,
and the guide exists to teach them.

⛔ **Rejected: one installer with a `--role` flag.** It puts both halves in one file, which is the
same reason the templates are split.

⛔ **Rejected: two whole script trees, one per rig.** BUILD.md §8 steps 0–1 are identical, and copies
diverge.

⛔ **Rejected: an `install-all.sh` for the first build.** It would drive straight through the human
gates in BUILD.md §8.

⛔ **Rejected: letting the updater reboot.** It sets `reboot_required` instead.

⛔ **Rejected for now: release tags.** A `stable` branch advanced by CI does the job. ℹ️ Tags become
worth having when an outside builder appears.

⛔ **Rejected: making the stationary rig wait for the portable's verdict.** The portable has no push
credential, is off for weeks at a time, and never runs the stationary-only steps.

⛔ **Rejected: a second canary Pi at the build site.** ℹ️ Reconsider only if a rollback ever fails remotely.

⛔ **Rejected: an overlayfs read-only root.** Every update becomes a two-reboot dance, and booting
from the SSD with no SD card already removes the wear problem it would solve.

⛔ **Rejected: Tailscale as the only recovery path.** That is why the smart plug goes through the
vendor's cloud ([§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away)).

⛔ **Rejected: a pull-only status page as the health signal.** Silence is ambiguous: it does not
tell you whether the rig is fine or nobody looked.

⛔ **Rejected: an RTC on the stationary rig.** The clock preflight and NTP handle boot.

⛔ **Rejected: choosing the writer's language now.** See
[§9i](#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader).

⛔ **Rejected: `yq`.** It is not on the image. `python3` with its `yaml` module is
([§9j](#9j--verified-on-hardware-2026-10-03)).

ℹ️ The entries below were added 2026-10-04, with the archive drive
([§9m](#9m--the-portable-rigs-archive-drive)).

⛔ **Rejected: exFAT for the archive drive.** It has no journal. **(Chris):** *"I would prefer to
have the power cycle resistance than force a windows download on it."*

⛔ **Rejected: a step that runs `mkfs`**, for instance whenever `blkid` shows no filesystem.
[§9f](#9f-what-updatesh-does) runs the steps on every update, the remote stationary rig included. A
human formats the drive once, by hand.

⛔ **Rejected: editing `/etc/fstab` from a step.** A step would be editing the file that carries the
root filesystem's line. **(Chris)** added `/etc/fstab` to the
[§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away) denylist.

⛔ **Rejected: the portable rig pushing its archive to the workstation.** It puts a credential to the
workstation on a rig that travels and may be stolen, which undoes
[§9a](#9a-the-repo-ships-its-own-software-and-the-pi-pulls-it)'s stolen rig being a hardware loss.
The workstation pulls instead.

⛔ **Rejected: copying the archive off, then trimming the drive.** **(Chris)** chose a move.
`rsync --remove-source-files` verifies each file before it deletes the source. ⚠️ Accepted
consequence: once pulled, the workstation holds the only copy until it is uploaded onward.

⛔ **Rejected: the spool on the SD card.** It wears the card, and it would be a second place to pull
from.

⛔ **Rejected: hourly archive files.** The writer rotates on 10-minute UTC boundaries. An hour of a
running session is not pullable until it closes, and a torn tail or a bad block costs an hour
instead of ten minutes. 10-minute files are only 144 a day.

⛔ **Rejected: the pull script using Chris's existing full sudo, with its password.** Its reach as
root is unbounded. The pull window's sudoers rule allows two commands
([§9m](#9m--the-portable-rigs-archive-drive)).

⛔ **Rejected: a polkit rule for the pull window.** It is a less familiar surface. `sudo -l` is
greppable and verifiable.

⛔ **Rejected: a forced-command key in `authorized_keys`.** That is the ssh login path, which the
[§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away) denylist keeps steps away
from, and it still needs privilege underneath.

⛔ **Rejected: a dedicated pull user.** It is a second account to keep in step.

⛔ **Rejected: separate begin and end oneshots for the pull.** A wrapper that dies between them leaves
a rig that will not record at its next outing.

⛔ **Rejected: `ExecStartPost=` running `update.sh` in the pull window.** `systemctl start` would block
for a source build that takes minutes.

### 9m. 🎒 The portable rig's archive drive

**Decided 2026-10-04.** The design was a recommendation from an architecture consultation the same
day. Chris accepted it, and that acceptance is the decision, as in
[§9](#9-the-software-step-scripts-run-from-a-clone-on-the-pi-updating-themselves). The choices he
made himself are marked **(Chris)**.

📋 **None of this exists yet.** No step, preflight, mount unit, template change or writer has been
written. Every mechanism below is decided, not built.

**What it is for.** **(Chris), 2026-10-03:** both rigs archive everything, for matching to
photographs by UTC time. **(Chris), 2026-10-04:** each rig saves to its own disk, and the data is
moved off by hand (`uploader.endpoint: null`). ⚠️ [BUILD.md §2](BUILD.md#2-two-rigs-not-one),
[BUILD.md §9](BUILD.md#9--the-archive-and-feeding) and the README still frame the archive as the 🏠
stationary rig's alone; see the consequences table below.

**The drive. (Chris), 2026-10-04:** a generic 64 GB USB flash drive he already owns. *"I would prefer
to have the power cycle resistance than force a windows download on it. We can move it across the
network from the pi."* ➡️ **ext4, and the data leaves over the network, from the Pi.** ✅ Read from the
drive on 2026-10-04: 62.9 GB, exFAT on MBR, empty; a generic controller with the model string
*"USB DISK"*, a placeholder serial, and USB ID `24A9:205A`. ⚠️ Its endurance and its behavior on power
loss are unknown.

⭐ **A cheap controller may acknowledge a flush it has not done, and no filesystem fixes that.** So
the design does not trust the medium. It bounds what a power cut can lose (the storage contract
below), and it detects corruption: `errors=remount-ro`, an fsck on every mount, and the pre-field
checklist.

**The filesystem: ext4,** in its default `data=ordered` mode, mounted `noatime,errors=remount-ro`,
with barriers on and journal checksums (confirm with `tune2fs -l`). No `discard`: continuous TRIM
over USB mass storage is often unsupported, and it can stall a cheap controller. The weekly
`fstrim.timer` is the safe alternative, because it skips a device without TRIM. Rejected: exFAT, which has no journal **(Chris)**; f2fs,
whose repair tool is unfamiliar, for a workload that is sequential; btrfs, because CPU is the binding
constraint ([§3](#3--cpu-is-the-binding-constraint-not-power)) and this is a single device that may
ignore flushes; `data=journal`, which doubles the writes; a `sync` mount, for throughput and wear.

**Formatting is a human gate.** A human formats the drive once, by hand: confirm the device with
`lsblk`, run `mkfs.ext4 -L adsb-archive -m 0 /dev/sdX`, then `tune2fs -c 1`. ⛔ **No step ever runs
`mkfs`.** When the step finds no ext4 filesystem with the label, it prints the format command and
exits non-zero. The reason is that [§9f](#9f-what-updatesh-does) runs the steps on every update,
including on the remote stationary rig. Rejected: a step that formats when `blkid` shows no
filesystem.

**Found by its label,** `archive.label: adsb-archive` in `station.yml`, which is the template
default. The preflight refuses if more than one block device carries the label. It is the
dongle-serial pattern: a role label stamped by a human. A spare drive formatted the same way works
in the field with no config edit. Rejected: the filesystem UUID in `station.yml`, which makes using a
spare a config edit in the field. ℹ️ Chris may reverse this one.

**Mounted by a native systemd mount unit,** `var-lib-adsb\x2dreceiver-archive.mount`, rendered from
config (render, diff, install, as in §9f), with `WantedBy=multi-user.target`. `systemd-fsck@` is
wired explicitly, fsck runs on every mount (`tune2fs -c 1`), and a drop-in on the device unit sets a
device timeout of about 10 s. No hot-plug and no automount: the drive is a fixture. Rejected:
`/etc/fstab`, because a step would be editing the file that carries the root filesystem's line.

- ⚠️ **Unverified, recalled during the consultation and not checked:** that
  `x-systemd.device-timeout=` is ignored in a mount unit's `Options=`, and that a native mount unit
  does not pull in `systemd-fsck@` by itself. Verify on the Pi. The observable effect is a boot
  without the drive reaching the login banner in seconds, and `journalctl -u 'systemd-fsck@*'`
  showing a run.
- ⚠️ If the native unit cannot do both, the fallback is `/etc/fstab` with
  `nofail,x-systemd.device-timeout=10s`. That conflicts with the denylist ruling below, so it goes
  back to Chris.

**Mounted at the [§9i](#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader) interface
path, `/var/lib/adsb-receiver/archive`,** created on the boot medium, which on the portable is the SD
card, as `root:root 0555`. The drive holds `beast/`, `spool/` and, later, `audio/`. **(Chris),
2026-10-04:** these are `adsb-receiver:adsb-operator 2770`, so the pull can read and delete as the
login user without root. There is no sticky bit anywhere on the drive. On the portable, `uploader.spool_dir` becomes
`/var/lib/adsb-receiver/archive/spool`. The rest of `/var/lib/adsb-receiver/` (`status.json`,
`applied-rev`) stays on the SD card, so a refusal can be recorded with the drive absent.

- Rejected: the spool on the SD card, which wears it and is a second place to pull from.
- Rejected: a neutral mount point with symlinks or bind mounts. That takes two more units, or two
  symlinks that can dangle, to reach what a direct mount at the interface path gives for free. The
  guard of an unwritable mount point would have to be rebuilt at each link.
- ⚠️ The `0555` mount point only stops a writer that is not root. The real guard is the preflight
  and `RequiresMountsFor=`, so the writer runs as its own system user, `adsb-receiver`.

**A preflight, `bin/archive-preflight`,** beside `clock-preflight`, plus
`RequiresMountsFor=/var/lib/adsb-receiver/archive` on the writer's unit once the writer exists. It
prints its raw evidence, and checks:

- `findmnt` shows the path mounted from the labeled device, ext4, read-write.
- Exactly one device carries the label.
- A write, fsync, read and delete probe succeeds as `adsb-receiver`.
- It renames a torn `.part` to `.torn` (see the storage contract below).
- It reports free space, and below `archive.min_free_gb` it warns that the writer will expire old
  files. ⛔ **It does not refuse on free space;** see the backstop below.
- **(Chris), 2026-10-04: it checks and repairs modes.** A `find` over `beast/` and `spool/` looks
  for anything not in group `adsb-operator`, a file without `g+r`, a directory without `g+rwx`, or a
  sticky bit. It reports and fixes each one (`chgrp`; `chmod g+rw` on files and `chmod g+rwx` on
  directories, consistent with the modes below; `chmod -t`), then continues.
  Rejected: reporting only, which leaves files the pull cannot move, and so lets them pile up.

Its exit codes follow the preflights' contract in §9i. A refusal is recorded as
`recording: refused`, with the reason, in `status.json` and the login banner. The writer's unit
retries (see below), so a refusal at boot, such as no GPS lock yet,
becomes "retry until disciplined", and each refusal is recorded. ℹ️ That does not break [BUILD.md §7](BUILD.md#7-software) rule 2, which governs samples
inside a running recording. This refusal is a precondition of a session, like rule 4's clock
refusal, and it leaves a record that survives, so a refused window is a third fact, not silence.
⚠️ On the 🏠 stationary rig health is pushed
([§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away)), so a refusal there
also needs the push alert. That is left to the stationary build.

**The storage contract for the writer.** An interface, not a writer design: [§9l](#9l-rejected)'s
rejection of choosing the writer's language now stands.

- Files are named in UTC, by the disciplined Pi clock, and rotated on 10-minute UTC boundaries.
- A file is named `.part` while open. It is fsynced at least every 10 s and on close, and renamed to
  its final name only after the closing fsync.
- A `.part` found at boot is torn. The preflight renames it `.torn`, ⛔ never deletes it, and reports
  it. Once renamed, a `.torn` file is a closed file like any other, so the writer's space backstop
  may expire it.
- **(Chris), 2026-10-04:** everything the writer creates on the drive is in group `adsb-operator`.
  Files are group-readable, directories are group-writable and traversable, and nothing has a
  sticky bit. ⚠️ The pull depends on it.
- ➡️ The names use wall time, so the contract does not depend on §9i's open item about the time in
  a BEAST frame.

Rejected: hourly files. An hour of a running session is not pullable until it closes, and a torn
tail or a bad block costs an hour instead of ten minutes. 10-minute files are only 144 a day.

**The pull, from your workstation over your home network:** rsync over ssh with
`--remove-source-files`, excluding `*.part` and `lost+found`, and including `.torn` files. rsync
verifies each transferred file before it deletes the source.

- **(Chris), 2026-10-04: move, not copy.** ⚠️ Accepted consequence: once pulled, the workstation
  holds the only copy until it is uploaded onward.
- There is no `retention_days` on the portable. The only deletion besides the pull is the backstop
  below.
- Rejected: pushing from the Pi, which puts a credential to the workstation on a rig that travels and
  may be stolen ([§9a](#9a-the-repo-ships-its-own-software-and-the-pi-pulls-it)).
- Rejected: copying, then trimming.
- Rejected: a manifest of transferred files. With a move there is nothing for a manifest to track:
  presence on the drive is the manifest. A manifest would be a second copy of the truth, with no
  first copy for it to be true to. It agrees with **(Chris), 2026-10-03**, said of both rigs in
  the discussion of the stationary design: *"Data leaves the rigs and must not accumulate on
  them."*
- ℹ️ A check against §9l found that its rejection of config management pushed from a workstation is
  about code and config going to the Pi. Its recorded reasons do not reach a data pull.

**The pull window. (Chris), 2026-10-04: the pull ends the recording session.** Without this,
§9f's recording lock and a portable that is always recording would mean the portable never updates.
The window is a unit, `adsb-pull-window.service`, rendered by the pull step (below):

- `Conflicts=adsb-writer.service` and `After=adsb-writer.service`, so starting the window stops the
  writer first. The open `.part` is closed and renamed, and everything is pullable.
- `Wants=` the §9f update oneshot, which is itself `After=adsb-writer.service`. The same `update.sh`
  the timer runs therefore starts only after the writer has stopped, and it runs while the rsync
  does. ➡️ `update.sh`'s `flock` on the recording lock stays as the backstop: there are two
  mechanisms, the ordering and the lock.
- `Type=exec`, `ExecStart=/bin/sleep infinity`, `RuntimeMaxSec=2h` **(Chris: the 2 h cap)**.
- `ExecStopPost=-/usr/bin/systemctl start adsb-writer.service`. When the window is stopped or
  reaches its cap, this starts the writer again. The `-` means a start that is refused does not mark
  the window failed.
- ⚠️ **On a reboot, the start inside `ExecStopPost=` is expected to be refused, and the writer
  returns at the next boot through `WantedBy=multi-user.target`.** That line is load-bearing: the
  writer must stay `WantedBy=multi-user.target`.
- ℹ️ `OnSuccess=` or `OnFailure=` may replace `ExecStopPost=`, if verified.
- ⚠️ **Unverified:** that `Conflicts=` plus `After=` orders the writer's stop before both the
  window's `ExecStart` and the wanted oneshot, in one transaction. The observable check is the order
  in the journal.

**(Chris), 2026-10-04: the 2 h cap bounds only how long the pull keeps the writer off.** An update
that overruns the window is the lock's job. At the cap the window stops and the writer starts, waits
on the lock, and records once the update finishes. `Wants=` does not carry the window's stop to the
update oneshot, so nothing kills an update partway through.

- Rejected: `PartOf=` or `BindsTo=` from the update oneshot to the window, which would kill an
  update in the middle of applying it.
- Rejected: dropping the cap. The lock does nothing for a wrapper that died.

**The wrapper lives in this repo (Chris).** 📋 Its exact path is not yet chosen; `tools/pull-archive`
is an example. It runs on the workstation: `ssh <pi> sudo systemctl start adsb-pull-window.service`,
then the rsync move, then the stop, in a trap so the stop runs even when rsync fails. Afterward it
prunes the empty date directories (`find -mindepth 1 -type d -empty -delete`); the running session's
directory is never empty. It fixes the destination, and it prints the file count, the bytes moved
and what remains.

**The privilege is a narrow NOPASSWD rule (Chris).**

- `/etc/sudoers.d/adsb-receiver` grants group `adsb-operator` exactly two NOPASSWD commands:
  `systemctl start` and `systemctl stop` of `adsb-pull-window.service`. There are no wildcards.
- ⛔ The pull step validates the rendered file with `visudo -cf` before installing it. A parse error
  in any `sudoers.d` file makes sudo refuse everyone, which on a remote rig is a reachability failure
  ([§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away)).
- **(Chris)** The installing user is added to `adsb-operator`. `05-config` does that (see the steps
  below), and it says so, and says that the change needs a fresh login.
- ➡️ The login can do two things as root: start and stop one unit. §9a is intact. The Pi
  authorizes an inbound key it already trusts, and holds no credential to anything.
- Rejected: Chris's existing full sudo, with its password, used by the script. Its reach as root is
  unbounded.
- Rejected: a polkit rule. It is a less familiar surface, while `sudo -l` is greppable and
  verifiable.
- Rejected: a forced-command key in `authorized_keys`. That is the ssh login path, which the §9h
  denylist keeps steps away from, and it still needs privilege underneath.
- Rejected: a dedicated pull user. It is a second account to keep in step.
- Rejected: separate begin and end oneshots. A wrapper that dies between them leaves a rig that will
  not record at its next outing.
- Rejected: `ExecStartPost=` running `update.sh`. `systemctl start` would block for a source build
  that takes minutes.

**The writer's unit, and the recording lock.** 📋 The writer itself is not designed
([§9i](#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader)); its unit is.

- **(Chris), 2026-10-04: the writer's unit holds the recording lock exactly as long as the writer
  runs:** `ExecStart=/usr/bin/flock /run/adsb-receiver/recording.lock <writer>`. The lock file is on
  tmpfs, its directory is created by a `tmpfiles.d` entry, and it joins §9i's fixed interfaces. The
  reason: §9l keeps the writer's language unchosen, so the lock lives in a unit file, not in the
  writer's code. And on tmpfs, a crash or a reboot leaves no stale lock.
  - **(Chris), 2026-10-04: nothing writes into the lock file.** The holder is `flock`, which writes
    nothing, and having the writer write it would put lock bookkeeping into the writer's code.
    Instead, the login banner derives the holder: `lslocks` gives the PID and the path,
    `ps -o unit= -p <pid>` the unit, and `ps -o lstart= -p <pid>` the start time. `lslocks` resolves
    another user's lock path only when run as root, which the `/etc/update-motd.d/` scripts are.
    ⚠️ **Unverified:** `ps -o unit=` on trixie's `procps`.
  - Rejected: the lock in the writer's code.
  - Rejected: a lock file under `/var/lib`. It survives a power cut, so a stale lock would block
    updates.
- **(Chris), 2026-10-04: the lock is asymmetric.** `update.sh` keeps `flock -n`, and exits if the lock
  is held. The writer takes it blocking, with no timeout, so a writer started in the middle of an
  update waits, then records.
  - Rejected: `update.sh` waiting for the lock. A session lasts hours.
  - Rejected: a bounded `flock -w` for the writer. It adds a new failure, and the writer has nothing
    better to do than wait again.
- The unit's order: `RequiresMountsFor=/var/lib/adsb-receiver/archive`; then `ExecStartPre=`
  `clock-preflight`, then `archive-preflight`; then `ExecStart=`, which is the wait for the lock and
  then the writer. `Restart=on-failure`, `RestartSec=30s`, `StartLimitIntervalSec=0`. So a preflight
  that fails at boot, for instance with no GPS lock yet, is retried until the clock is disciplined,
  and each refusal is recorded in `status.json`.
- **(Chris), 2026-10-04: `UMask=0007`** on the writer's unit, and later on the uploader's. Files are
  `0660`. Directories are `2770`, and inherit the setgid bit and group `adsb-operator`.
  - Rejected: `UMask=0027`. Its `2750` directories block deletion inside them.
  - Rejected: default ACLs, which are invisible to `ls -l`.
  - Rejected: `rsync --rsync-path='sudo rsync'`. That is root with arbitrary reach, and it undoes
    the two-command boundary.
- ⭐ **The full verify that `update.sh` runs can never assert that the writer is active,** because
  `update.sh` holds the lock while it runs. See §9f, and the writer's step below.

**When the drive is nearly full. (Chris), 2026-10-04:** the writer expires the oldest closed files
and reports it loudly, in `status.json` and the login banner, rather than stopping. This is the
`archive.min_free_gb` backstop.

- On start, before it opens its first `.part`, the writer expires the oldest closed files, `.torn`
  included. It reports each one, and stops when free space is at or above `archive.min_free_gb`.
- The only refusal on space is the writer's: still below the threshold with nothing left to expire.
- The reason is the ruling above: today's session outranks an unpulled old one. [BUILD.md §9](BUILD.md#9--the-archive-and-feeding)
  item 1 puts retention in the writer, so the writer is the one component that deletes.
- Rejected: refusing at the threshold, which inverts the ruling above.
- Rejected: the preflight doing the expiry, which would put retention in two places.
- Rejected: making `.torn` files unexpirable.

**The steps. (Chris), 2026-10-04: the install is split across steps by what each one can
observe.** Each step's `--verify` checks only what that step installed, and none of them ends a
recording session ([§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect)).

- **`05-config`, widened** ([§9k](#9k-the-first-deliverable-in-order) item 2). It creates the
  `adsb-receiver` system user, with no login shell. That user owns everything written to the
  archive: the writer, the uploader, and later `rtl_airband`. It also creates the `adsb-operator`
  group, with the installing user added, and the `tmpfiles.d` entry for `/run/adsb-receiver`. It
  checks `getent` first, because `useradd` and `groupadd` fail on names that already exist. The
  reason it lives here: the 🏠 stationary rig needs the same user whatever its open question
  decides, so a step gated to the portable cannot own it.
  - `--verify`: `id adsb-receiver` shows a system user with no login shell; `getent group
    adsb-operator` lists the installing user; `/run/adsb-receiver` exists, with its mode, after
    `systemd-tmpfiles --create`.
- **`setup/steps/30-archive-drive.sh`, portable-only for now,** after the `20-*-clock` steps and
  before the writer. It reads `archive.label` and `archive.min_free_gb`. It carries a dated
  `require_role portable` gate that points at the open stationary question below, and the stationary
  template does not get `archive.label` yet.
  - **Why portable-only:** §9h's recovery layer 4 and §9l's rejection of an overlayfs root already
    have the 🏠 stationary rig booting from its USB SSD with no SD card. So whether this step
    applies there depends on how the stationary's SSD holds the archive, which is not decided. A
    role gate that can be removed is §9b's own device. If the answer is a labeled partition, the
    gate is deleted and the step is shared, with no rename.
  - **Install:** the mount point; the rendered mount unit and its drop-in; `daemon-reload`; enable
    and start the mount; `beast/` and `spool/`, chowned to `adsb-receiver:adsb-operator 2770`; and
    `bin/archive-preflight`. It creates no users or groups.
  - **`--verify`:** `findmnt` shows the path mounted from the labeled device, ext4, read-write; the
    mount unit enabled and active; `tune2fs -l` showing the label, `errors=remount-ro` and a check
    on every mount; `lsusb -t` showing the drive at 480M; `stat` showing `beast/` and `spool/` as
    `adsb-receiver:adsb-operator 2770`; the preflight, probing as `adsb-receiver`; and `df -h`, raw.
    Nothing about a writer or an update. ➡️ The drive is install tier, so a dead drive stops updates
    from applying until it is replaced ([§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect)).
  - A changed mount unit never restarts the mount. It sets `reboot_required` (§9f).
- **The writer's step** installs the writer's unit: the recording lock, the preflights, the restart
  policy, `UMask=` and `RequiresMountsFor=` above.
  - `--verify` (install tier, [§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect)): the
    unit file loads (`systemd-analyze verify`), and is enabled and not failed; both preflights exit
    `0` or `2`, never `1`; `lslocks` shows `/run/adsb-receiver/recording.lock` held by exactly one
    process whenever the writer or `update.sh` runs. Under `update.sh`, the holder is `update.sh`
    itself. ⛔ Never `is-active` of the writer (§9f).
- **`NN-portable-pull.sh`, a new role-specific step** with `require_role portable`. Its number is
  assigned after both the writer's step and `update.sh`'s step. It installs the pull window, the
  sudoers drop-in, validated with `visudo -cf` first, and the pull wrapper.
  - `--verify`: `visudo -cf` on the installed file; `sudo -l -U <operator>` listing exactly the two
    commands; the window unit loaded. If the journal holds a previous window, it shows the writer's
    stop before `update.sh`'s first line; otherwise the verify warns that no window has run yet.
    The live exercise stays in the pre-field checklist.
- **(Chris), 2026-10-04:** no step's verify reads `UMask=`. That is the setting, not the effect: the
  full pull in the pre-field checklist tests the effect.
- Rejected: step 30 installing units that belong to two later steps. Its verify could not exit 0 on
  the day it is built.
- Rejected: everything in the writer's step, behind a role branch ([§9b](#9b-one-bash-script-per-build-step)).
- Rejected: everything in `update.sh`'s step.
- Rejected: step 30 creating the user and group itself.
- Rejected: a role-specific copy of step 30. Two files with one mechanism are the copies §9l says
  diverge. What differs between the rigs, retention, belongs to the writer, not the mount.
- Rejected: keeping a "shared by both rigs" claim now, which would describe an end state as the
  current one.
- Rejected: renaming step 30 to `30-portable-archive`, because sharing it later would need a rename.
- Rejected: `archive.label: null` on the stationary meaning "on the root filesystem". One key would
  mean "refuse" on one rig and "do not mount" on the other.

**The templates. (Chris), 2026-10-04:** the 🏠 stationary template changes in one place now.
`archive.path: /mnt/ssd/beast` is replaced by a comment that names the §9i interface path and points
at the open stationary question. `enabled`, `format: beast` with its ⛔, `retention_days` and
`min_free_gb` stay. There is no `archive.label` until the stationary question is decided. The 🎒
portable template's new `archive:` block carries the same BEAST ⛔, as a comment.

- Rejected: leaving the stationary template wholly untouched. `/mnt/ssd/beast` would contradict a
  decided interface.
- Rejected: rewriting it fully now.
- Rejected: keeping `archive.path` as a configurable key.

**The port.** The drive goes in a black USB 2 port. It needs about 10 MB an hour. ⚠️ That is an
estimate derived from [BUILD.md §9](BUILD.md#9--the-archive-and-feeding)'s ~200 MB/day busy-metro
figure, not a measurement. USB 2 draws less from the Pi 4's ~1.2 A USB budget, and it avoids the
interference between USB 3 and nearby SDRs that is widely reported but ⚠️ not measured here. The
powered-hub rule ([BUILD.md §3d](BUILD.md#3d--the-second-radio--either-rig) part 14) is unchanged.

**The pre-field checklist,** the 🎒 portable's counterpart to §9h's pre-ship checklist:

- [ ] Three cold power cuts mid-recording. After each one: the mount returns; fsck is clean or says
  what it repaired; exactly one `.part` became `.torn`; every earlier closed file reads back.
- [ ] One boot with the drive pulled. The banner says refused within ~20 s, and nothing appears
  under the bare mount point.
- [ ] A full pull from the workstation. The window starts; the writer reads inactive, and no `.part`
  remains; rsync moves everything; the wrapper stops the window; the writer is active again within
  seconds, and a new `.part` appears. The drive then holds only that `.part` and `lost+found`.
- [ ] The cap. Start the window and walk away. After `RuntimeMaxSec` the writer is running again,
  with nothing having stopped the window.
- [ ] An update inside the window. With a new commit on `main`, start the window: `applied-rev`
  advances, and the journal shows the writer's stop before `update.sh` began.

➡️ If the cuts leave garbage in closed, renamed files, the answer is a different drive or an SSD on
the hub, not a different filesystem.

**(Chris), 2026-10-04: `/etc/fstab` joins the
[§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away) denylist.** A guard: no
step writes it under this design.

📋 **Not decided:** whether the 🏠 stationary rig's archive SSD is its boot device or a separate
mount. That belongs to the stationary build. ℹ️ **The consultation's lean, not a ruling:** a separate
`adsb-archive` partition on the SSD, so a full archive cannot fill the root filesystem and
`errors=remount-ro` cannot take the OS read-only. The cost is one partition at foundation time.

### 📋 Consequences for the other docs (not yet made)

| Where | Now says | Needs |
|---|---|---|
| BUILD.md §7 / §8 step 1 | — | `10-decoder` ~~may install `readsb` from apt (whether the 2024 snapshot is current enough is still to decide) and pin only~~ *builds `readsb` from source at a pinned commit, with RTL-SDR support, against the packaged `librtlsdr` 2.0.2, and does not install it from apt (2026-10-04, [§9j](#9j--verified-on-hardware-2026-10-03)). It pins* `tar1090`'s installer by SHA |
| BUILD.md §4 | ⚠️ "Installing either from `apt` can quietly pull an old one back in" | Re-examine. ~~On trixie the packaged `readsb` links the same 2.0.2 library ([§9j](#9j--verified-on-hardware-2026-10-03))~~ *Corrected 2026-10-04: on trixie the packaged `readsb` links no `librtlsdr` at all. It is built without RTL-SDR support and cannot drive the stick ([§9j](#9j--verified-on-hardware-2026-10-03)). Lines 149 and 153–154 make the same linking claim. On forky, whose `readsb` 3.16-2 depends on `librtlsdr0`, the concern applies again* |
| README "The three traps that cost the most time", trap 1, lines 39–40 | "`readsb`/`dump1090-fa` link against it, so installing either from `apt` can quietly undo the fix" | *Added 2026-10-04.* The same correction as the BUILD.md §4 row above: on trixie the packaged `readsb` links no `librtlsdr` and cannot drive an RTL-SDR ([§9j](#9j--verified-on-hardware-2026-10-03)) |
| BUILD.md §4, lines 169–171 | "If it says R820T2, or reports nothing, the old driver is still in the path" | The inference "R820T2 means the old driver" is wrong in at least one case. A stick reporting R820T on a current library may be a counterfeit, not an old driver ([§9j](#9j--verified-on-hardware-2026-10-03)) |
| README "The three traps that cost the most time" / BUILD.md §3a parts table, row 3 | — | Warn that counterfeit V4s are sold, Amazon included ([§9j](#9j--verified-on-hardware-2026-10-03)). The check is `rtl_eeprom` (its Manufacturer and Product strings) plus `rtl_test` naming the R828D. Buy from RTL-SDR Blog or a seller listed on rtl-sdr.com |
| BUILD.md §7 | "uploader (yours to write)" | It ships in this repo |
| BUILD.md §8 | Steps with no scripts | Name each step's script, and add the [§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away) pre-ship checklist |
| BUILD.md §2 | "reachable over something like Tailscale" | Tailscale key expiry, and disabling it. ⚠️ The 180-day default is an unverified claim from the consultation |
| BUILD.md §3c | Stationary parts list | Add a powered hub or a low-draw SSD enclosure, and a smart plug |
| `config/station.stationary.example.yml` | — | Add `update.soak_days`, `notify.discord_webhook` and `notify.healthcheck_url`. ⛔ The portable template must not get them |
| `config/station.stationary.example.yml` | `archive.path: /mnt/ssd/beast` | Reconcile with `/var/lib/adsb-receiver/archive` in [§9i](#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader). *Settled 2026-10-04 ([§9m](#9m--the-portable-rigs-archive-drive)), for both rigs: the path is the §9i interface path, and `archive.path` is replaced by a comment naming it. See the templates row below. What backs that path on the stationary rig is not decided* |
| README "What is here" and "Status" | Docs and two templates; "Documentation, today" | `setup/`, and the software's state |
| `.gitignore` | `config/*.local.yml`, with no comment | Document what it is for, or drop it |
| BUILD.md §2, the **Job** row | 🎒 "Log tracks at the location you are shooting from"; 🏠 "Continuous archive, feeding, ACARS harvesting" | *Added 2026-10-04.* Both rigs archive everything, for matching to photographs by UTC time (**(Chris)**, 2026-10-03, [§9m](#9m--the-portable-rigs-archive-drive)) |
| BUILD.md §3b | Portable parts 6–10, with nothing to archive onto | *Added 2026-10-04.* A USB flash drive for the archive, formatted ext4 by hand, in a black USB 2 port ([§9m](#9m--the-portable-rigs-archive-drive)) |
| BUILD.md §7, the 🎒 portable block | "uploader (yours to write) → reads aircraft.json + gpsd, spools to disk; ships on the next network, never in the field" | *Added 2026-10-04.* The same line as the earlier "BUILD.md §7" row, which says the uploader ships in this repo; make both changes together. An archive writer on the portable too, writing to the archive drive, with the spool on that drive. The data is moved off by a pull from your workstation over your home network, and `uploader.endpoint` stays null ([§9m](#9m--the-portable-rigs-archive-drive)) |
| BUILD.md §8 | No archive step | *Added 2026-10-04.* Name `30-archive-drive`, after the clock step and before the writer. Add formatting the drive as a human gate, and the 🎒 pre-field checklist ([§9m](#9m--the-portable-rigs-archive-drive)) |
| BUILD.md §9, the heading and first line | "🏠 The archive, and feeding"; "⛔ This is the stationary rig's job, and it is why that rig exists." | *Added 2026-10-04.* The archive is no longer the stationary rig's alone: both rigs archive everything (**(Chris)**, 2026-10-03, [§9m](#9m--the-portable-rigs-archive-drive)) |
| README "The idea worth stealing", the **Job** row, line 22 | 🏠 "Continuous archive, feeding aggregators, harvesting ACARS" | *Added 2026-10-04.* The same as the BUILD.md §2 row above: both rigs archive everything |
| `config/station.portable.example.yml` and `config/station.stationary.example.yml` | Portable: no `archive:` block, `spool_dir: /var/lib/adsb-receiver/spool`. Stationary: `archive.path: /mnt/ssd/beast`, `archive.format: beast` | *Added 2026-10-04 ([§9m](#9m--the-portable-rigs-archive-drive)).* The portable gets an `archive:` block with `archive.label` (default `adsb-archive`) and `archive.min_free_gb`, and the BEAST ⛔ ([BUILD.md §9](BUILD.md#9--the-archive-and-feeding) item 2) as a comment. ⛔ The stationary does not get `archive.label` yet. The archive-drive step is portable-only until the stationary rig's SSD question is decided. The stationary changes in one place: `archive.path: /mnt/ssd/beast` is replaced by a comment naming the §9i interface path and pointing at that open question. ⛔ It keeps `enabled`, `format: beast` with its ⛔, `retention_days` and `min_free_gb`. The portable gets no `retention_days`, and says why: the pull moves the data off, and the `min_free_gb` backstop is the only other deletion. The portable's `uploader.spool_dir` becomes `/var/lib/adsb-receiver/archive/spool`. ⛔ The portable still must not get `update.soak_days` or `notify.*` |
| BUILD.md §8 | No pull step | *Added 2026-10-04.* Name the 🎒 pull step, `NN-portable-pull`, after both the writer's step and `update.sh`'s step. Its number is not assigned yet ([§9m](#9m--the-portable-rigs-archive-drive)) |
| README "What is here" | No `tools/` path | *Added 2026-10-04.* The new top-level `tools/` path for the pull wrapper. Its exact name is not chosen yet ([§9m](#9m--the-portable-rigs-archive-drive)) |
| PLAN.md [§9k](#9k-the-first-deliverable-in-order), items 2 and 3 | 2: "`05-config` + `10-decoder`"; 3: "`update.sh` + the timers + `status.json` + the job that advances `stable`" | *Added 2026-10-04 ([§9m](#9m--the-portable-rigs-archive-drive)).* Item 2: `05-config` is widened. It creates the `adsb-receiver` system user, the `adsb-operator` group with the installing user, and the `tmpfiles.d` entry for `/run/adsb-receiver`. Item 3: `update.sh` needs its own `TimeoutStartSec`, and it must roll back on SIGTERM ([§9f](#9f-what-updatesh-does)) |
| `setup/lib.sh`, `parse_args` and `require_role` | `--verify` and `--help` only; `require_role` always dies on a mismatch | *Added 2026-10-04.* `parse_args` gains `--skip-other-role`, and `lib.sh` gains the constant `ADSB_RC_OTHER_ROLE`, an unused value below 126 and not 3. With the flag, `require_role` on a mismatch logs the skip and exits that code. `require_absent` is unchanged ([§9b](#9b-one-bash-script-per-build-step)) |
| `.github/workflows/ci.yml` | Two step checks: the denylist grep, and `parse_args` plus `verify()` in every step | *Added 2026-10-04.* A third check: in every step containing `require_role`, the first non-comment command after `parse_args` and `require_root` is the `require_role` call ([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable)) |
| BUILD.md §8 step 2 | "Confirm `gpsd` has a fix, `chronyc sources` shows GPS disciplining the clock, and the Pi still knows the time after a power cycle **with the network unplugged**" | *Added 2026-10-04.* When this step names `20-portable-clock`, say that the script's verify checks only the install tier, and that these checks stay human gates under the sky ([§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect)) |
| `setup/lib.sh`, `ADSB_DENY_PATHS` | No `/etc/fstab`; its comment says the list is "Written as in the PLAN §9h table" | *Added 2026-10-04.* Add `/etc/fstab` (**(Chris)**, [§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away)). CI reads this array for its grep of `setup/steps/` |
