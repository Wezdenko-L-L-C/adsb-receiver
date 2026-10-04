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

### 9c. Every step ends in a check of the observable effect

Every step ends in a `verify` that checks **what the step was for, not the setting that claims it**:

| Checks this | Not this |
|---|---|
| `rtl_test -t` names the R828D and prints `RTL-SDR Blog V4 Detected` | `dpkg -l` shows the package |
| `chronyc tracking` reports an offset inside `clock.max_offset_ms` | `systemctl is-active chrony` |
| `aircraft.json` is advancing | `systemctl is-active readsb` |

The verify prints its raw evidence and exits non-zero on failure. `--verify` runs the check on its
own.

⭐ **This is how the README's rule survives automation.** The README says ✅ marks *"the check to run,
or the fix to apply — never a claim that the part was tested here."* A script that checks the effect
and prints it is that check, run. ⛔ **So no script carries a "tested on" header.** A record of a
verified run goes in the docs, with the output pasted.

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
| `/boot/firmware`, `/etc/network*`, `/etc/NetworkManager`, `/etc/systemd/network`, `/etc/ssh`, `/etc/apt/sources.list*` | `tailscaled`, `ssh`, `NetworkManager` |

**Before committing an update**, all of these must hold: Tailscale's `BackendState` is `Running`
and the node is online; outbound https to github.com works; `readsb` answers on port 30005; and
`clock-preflight` passes.

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

### 9j. ✅ Verified on hardware, 2026-10-03

Chris pasted this output from the 🎒 portable rig, a Pi 4 (4 GB) with hostname `mobile-adsb`:

- Raspberry Pi OS is **Debian 13 trixie**, kernel `6.18.50+rpt-rpi-v8`.
- `apt` offers `rtl-sdr` and `librtlsdr0` at **2.0.2-2+b1**, and installed them.
- `systemd-timesyncd` is active. `chrony` is not installed.
- `python3` imports `yaml`.
- ⚠️ **`apt policy readsb` shows `readsb` 3.14.1630+git20240609.adc080d-1 in Debian trixie
  `main`.** This corrects a belief from the consultation that `readsb` is not packaged.
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

⚠️ **The mismatch between the label and the chip ~~is unresolved~~** *most likely means a counterfeit;
see the 2026-10-03 update below.* The leading suspect is a
counterfeit V4: an R820T inside a V4 case. A rewritten EEPROM is less likely, because the library
probes the tuner by chip, not by the USB string. ℹ️ A genuine V4 is believed to report the USB
strings *"RTLSDRBlog, Blog V4"*. That belief is unverified.

**Update 2026-10-03.** Chris pasted the output of `rtl_eeprom` on the stick: Vendor ID `0x0bda`,
Product ID `0x2838`, Manufacturer *"Realtek"*, Product *"RTL2838UHIDIR"*, Serial *"00000001"*,
serial number enabled *yes*, IR endpoint enabled *yes*, remote wakeup *no*, and the tuner line
*"Found Rafael Micro R820T tuner"*. The stick was bought on Amazon (Chris, 2026-10-03). The seller
is not yet identified.

➡️ **The stick is most likely a counterfeit V4: a generic R820T TV-tuner stick in a printed V4
case.** That is not proven from software alone. The seller's name, or the marking on the PCB, would
settle it. ℹ️ *"IR endpoint enabled: yes"* is believed to be a TV-dongle default that RTL-SDR Blog
units ship with disabled. That belief is unverified.

**(Chris), 2026-10-03: return the stick, and buy a genuine V4** from RTL-SDR Blog's store or a
seller listed on rtl-sdr.com. Building continues on this stick meanwhile, because it decodes 1090
on the stock 2.0.2 library.

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

### 📋 Consequences for the other docs (not yet made)

| Where | Now says | Needs |
|---|---|---|
| BUILD.md §7 / §8 step 1 | — | `10-decoder` may install `readsb` from apt (whether the 2024 snapshot is current enough is still to decide) and pin only `tar1090`'s installer by SHA |
| BUILD.md §4 | ⚠️ "Installing either from `apt` can quietly pull an old one back in" | Re-examine. On trixie the packaged `readsb` links the same 2.0.2 library ([§9j](#9j--verified-on-hardware-2026-10-03)) |
| BUILD.md §4, lines 169–171 | "If it says R820T2, or reports nothing, the old driver is still in the path" | The inference "R820T2 means the old driver" is wrong in at least one case. A stick reporting R820T on a current library may be a counterfeit, not an old driver ([§9j](#9j--verified-on-hardware-2026-10-03)) |
| README "The three traps that cost the most time" / BUILD.md §3a parts table, row 3 | — | Warn that counterfeit V4s are sold, Amazon included ([§9j](#9j--verified-on-hardware-2026-10-03)). The check is `rtl_eeprom` (its Manufacturer and Product strings) plus `rtl_test` naming the R828D. Buy from RTL-SDR Blog or a seller listed on rtl-sdr.com |
| BUILD.md §7 | "uploader (yours to write)" | It ships in this repo |
| BUILD.md §8 | Steps with no scripts | Name each step's script, and add the [§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away) pre-ship checklist |
| BUILD.md §2 | "reachable over something like Tailscale" | Tailscale key expiry, and disabling it. ⚠️ The 180-day default is an unverified claim from the consultation |
| BUILD.md §3c | Stationary parts list | Add a powered hub or a low-draw SSD enclosure, and a smart plug |
| `config/station.stationary.example.yml` | — | Add `update.soak_days`, `notify.discord_webhook` and `notify.healthcheck_url`. ⛔ The portable template must not get them |
| `config/station.stationary.example.yml` | `archive.path: /mnt/ssd/beast` | Reconcile with `/var/lib/adsb-receiver/archive` in [§9i](#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader) |
| README "What is here" and "Status" | Docs and two templates; "Documentation, today" | `setup/`, and the software's state |
| `.gitignore` | `config/*.local.yml`, with no comment | Document what it is for, or drop it |
