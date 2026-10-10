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

*Update 2026-10-04: ✅ a first measurement of one process in the last row. The archive writer,
`bin/adsb-writer`, used 1.1% of a core, averaged over its first 30 s on the 🎒 portable Pi, start-up
included (`ps`). Seen by Claude on 2026-10-04; see the end of
[§9m](#9m--the-portable-rigs-archive-drive). The row's ~0.7 is still an estimate.*

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
*📋 Open note, 2026-10-04 (not a ruling): the stationary hardware is not yet ruled; one Pi 5 is
expected to serve as a stationary rig, and the proposal for the remote rig is a Pi 5. If so, this
rejection is overtaken. For the stationary design; see also the open note under
[§9l](#9l-rejected)'s rejection of an RTC on the stationary rig.*

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
that has been run~~ ~~*are the only part of this section recorded as run.*~~ *Corrected 2026-10-04:
no longer the only part recorded as run. [§9m](#9m--the-portable-rigs-archive-drive) records runs
on the 🎒 portable Pi in its two "✅ Verified on hardware, 2026-10-04" blocks, at the end of that
section.*

**Update 2026-10-04.** That status has been false since 2026-10-03. Commit `95bcba6` added
`setup/lib.sh`, `setup/steps/00-drivers.sh` and the CI workflow `.github/workflows/ci.yml`, in one
change. ➡️ [§9k](#9k-the-first-deliverable-in-order) item 1 is done.

- `lib.sh` holds the shared helpers: `--verify` parsing, reading `station.yml` with `python3` and
  `yaml`, the role checks of [§9b](#9b-one-bash-script-per-build-step), and the
  [§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away) denylist. A
  `systemctl` wrapper, `unit`, refuses denylisted units, and `00-drivers.sh` calls it. A write
  guard, `guard_path`, is defined~~, but no step calls it yet~~. *Corrected 2026-10-04: since commit
  `47ed4ed`, `05-config` and `30-archive-drive` call it on the paths they install.*
- `00-drivers.sh` installs `rtl-sdr` from apt~~, and its verify reads the output of `rtl_test -t` and
  `rtl_eeprom`~~. *Corrected 2026-10-05: it also writes a modprobe blacklist for the kernel's
  `dvb_usb_rtl28xxu`, and no verify opens the stick any more
  ([§9j](#9j--verified-on-hardware-2026-10-03)'s 2026-10-05 ruling). The proof is split. `00-drivers`
  proves the udev rule's effect, the stick's node in group `plugdev` mode `660`, and the blacklist's
  state, from sysfs and `/dev`. `10-decoder` proves the tuner and the V4 line, from `readsb`'s own open
  of the stick in its current invocation's journal.*
- CI runs `bash -n`, `shellcheck`, the §9h denylist grep, and a check that every step has a
  `verify` and takes `--verify`. *Update 2026-10-04: it now also runs the check that a role-gated
  step calls `require_role` first (commit `47ed4ed`, [§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable))
  and a check that every Markdown anchor names a heading, and `bash -n` and `shellcheck` now cover
  `bin/` as well as `setup/`.* ⚠️ **The arm64 trixie dry run and ~~the job that fast-forwards
  `stable`, both~~ in [§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable), ~~are~~ not
  built.** The workflow marks ~~both~~ *it* as TODO for §9k item 3. *Corrected 2026-10-04 (evening):
  the job that fast-forwards `stable`, `advance-stable`, is written, ~~and has not run yet~~
  ([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable)). The arm64 dry run is still
  not built, and is the workflow's one remaining TODO.* *Corrected 2026-10-05: ✅ `advance-stable`
  has run, with `GITHUB_TOKEN` alone, on every push to `main` on 2026-10-04 and 2026-10-05; see
  §9g's third bullet.*
- Still not written: ~~`bin/`,~~ `setup/foundation/`, ~~`05-config`,~~ `10-decoder`, `update.sh`, the
  timers, `status.json`, and ~~the clock steps~~ *`20-stationary-clock`*. *Corrected 2026-10-04: commit `47ed4ed` wrote
  `05-config`, `30-archive-drive` and `bin/archive-preflight`
  ([§9m](#9m--the-portable-rigs-archive-drive)).* ~~*`bin/clock-preflight` is still not written.*~~
  *Corrected 2026-10-04, later: `20-portable-clock` and `bin/clock-preflight` are written, and
  step 20 ran on the 🎒 portable Pi. So are `40-archive-writer`, `bin/adsb-writer` and
  `tools/adsb-extract`, and step 40 ran there too. Both runs are at the end of
  [§9m](#9m--the-portable-rigs-archive-drive).* *Corrected 2026-10-04 (evening): `setup/foundation/`
  (two scripts, for the 🎒 portable's first build), `update.sh`, the timers (rendered by
  `50-updater`) and `status.json` are written, ⚠️ not yet run on hardware
  ([§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic) and
  [§9f](#9f-what-updatesh-does), "As built"). ~~`10-decoder` is written but not committed; it waits for
  its run on the Pi (§9m, R5).~~ `20-stationary-clock` is still not written.* *Corrected 2026-10-05:
  `10-decoder` is committed, as `42b5115` on `main`. It ran on the 🎒 portable Pi on 2026-10-05 by
  `adsb-update --rev`, then merged, with CI green ([§9j](#9j--verified-on-hardware-2026-10-03)'s
  "`10-decoder`, as built").*

`00-drivers.sh` has been run ~~once~~, on the 🎒 portable rig on 2026-10-03. Its verify failed when the
stick dropped off the USB bus during the check. ⚠️ That run is not recorded in §9j: its output was
not pasted here, and [§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect) says a record of
a run goes in the docs with the output pasted. *Corrected 2026-10-05: no longer once. It ran again
on 2026-10-05, in the bootstrap and in the `--rev` run, and passed both
([§9j](#9j--verified-on-hardware-2026-10-03)'s 2026-10-05 ruling).*

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
  BUILD.md §8 steps 0–1 are identical for both rigs. *Added 2026-10-10: so is `06-journal`, the
  persistent journal on both rigs, ruled by Chris that day to come right after step 5 (the record
  is "A persistent journal, step `06-journal`", at the end of [§9f](#9f-what-updatesh-does)). It
  reads no `station.yml` and asserts no role. `update.sh` runs the steps in filename order, so it
  runs after `05-config` and before `10-decoder`; on a first build `50-updater` still runs first.
  BUILD.md §8 has no step for it yet.*
- **Role-specific steps are separate files.** `20-portable-clock` and `20-stationary-clock` each
  read `station.yml`, assert `station.role`, and **refuse the other role's blocks.** The portable
  step refuses a `position:` block. The stationary step refuses `clock.source` other than `ntp`,
  and refuses an `uploader:` block.
- ⭐ **That turns the templates' "do not merge" comments into exit codes.** Today the split between
  the two `config/station.*.example.yml` files is held up by comments alone. Once these steps exist,
  setting the wrong half makes a step fail.
- ⛔ **No `--role` flag ~~anywhere~~.** The role comes from the config the rig already carries.
  *Superseded 2026-10-04 (Chris), in one place only: the one-command build's bootstrap takes
  `--role`, and writes the rig's only `station.yml` from that role's template before any step runs.
  The steps and `update.sh`'s update path still take no role flag. Why that does not bring back two
  truths is in [§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)'s evening
  update. ~~📋 Ruled, not built.~~* *Corrected 2026-10-04, later that evening: built, not yet run on
  hardware ("As built" in §9e's evening update).*

**Update 2026-10-04: how `update.sh` skips the other role's steps. (Chris), 2026-10-04.** ~~📋 Not
built.~~ *Half built, corrected 2026-10-04: the `lib.sh` half, `--skip-other-role` and
`ADSB_RC_OTHER_ROLE`, and CI's check that `require_role` comes first, are in commit `47ed4ed`.
~~`update.sh`, which is to use them, is not built.~~* *Corrected 2026-10-04, later that evening:
`update.sh` is built and uses them, reading `ADSB_RC_OTHER_ROLE` from the tree it runs; not yet run
on hardware ([§9f](#9f-what-updatesh-does)'s evening update, "As built").* `update.sh` runs the candidate's steps ([§9f](#9f-what-updatesh-does)), and a role-specific
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

**(Chris), 2026-10-09, about 18:35: `/security-review` is standing for every change to the rigs'
code** (`setup/`, `bin/`, `config/` and `tools/`), before it is pushed. It runs after
`step-reviewer` and `/code-review`, and replaces neither. The reason recorded with the ruling: the
rigs run root timers that parse radio and Wi-Fi input anyone nearby can send, and this repo is
public.

### 9c. Every step ends in a check of the observable effect

Every step ends in a `verify` that checks **what the step was for, not the setting that claims it**:

| Checks this | Not this |
|---|---|
| ~~`rtl_test -t` names the R828D and prints `RTL-SDR Blog V4 Detected`~~ ~~*`rtl_test -t` opens a device and names its tuner. An R828D must come with `RTL-SDR Blog V4 Detected`, and a V4 line on any other tuner fails. Any other tuner passes, with a warning that is louder when `rtl_eeprom` claims Blog or V4. Interim; see the 2026-10-04 update below*~~ *Corrected 2026-10-05: no verify opens the stick. `00-drivers`: the stick's node is group `plugdev`, mode `660`, and the blacklist names `dvb_usb_rtl28xxu`. `10-decoder`: the tuner and the V4 line from `readsb`'s own open, in its current invocation's journal; the odd combinations warn and never fail. See the 2026-10-05 supersession below, and [§9j](#9j--verified-on-hardware-2026-10-03)* | `dpkg -l` shows the package |
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

*Superseded 2026-10-05, in two rulings by Chris (both in full in
[§9j](#9j--verified-on-hardware-2026-10-03)):*

- *No verify opens the stick, and `readsb` is the rig's only opener. So the tuner table moved out
  of `00-drivers` and into `10-decoder`'s verify, which reads the tuner, the V4 line and the EEPROM
  strings from `readsb`'s own open of the stick.*
- ***The tuner table informs and never gates.** Chris: "I will not be using the counterfeit radios
  anymore." Three odd combinations now warn, and the step passes on streaming: a V4 line with a
  tuner other than the R828D; an R828D with no V4 line, the
  [BUILD.md §4](BUILD.md#4-drivers-first) silent failure, which is now a warning; and Blog or V4 in
  the EEPROM strings on a tuner other than the R828D, the counterfeit signature, kept for the
  record. Until 2026-10-05 the first two failed the verify, in `00-drivers`. The reason, recorded by
  the `10-decoder` review: under `update.sh`, a hardware or library verdict used as an update gate
  would roll back a candidate that cannot fix it, on every timer pass.*
- *The question left open above, whether a genuine V4 brings back the R828D requirement, is still
  not ruled. ➡️ Since 2026-10-05 the table gates no stick, so the question has no effect unless
  Chris reopens it.*

The verify prints its raw evidence and exits non-zero on failure. `--verify` runs the check on its
own.

⭐ **This is how the README's rule survives automation.** The README says ✅ marks *"the check to run,
or the fix to apply — never a claim that the part was tested here."* A script that checks the effect
and prints it is that check, run. ⛔ **So no script carries a "tested on" header.** A record of a
verified run goes in the docs, with the output pasted.

**Update 2026-10-04: what a verify may do to a running rig. (Chris), 2026-10-04:** ⛔ **a verify may
interrupt the rig for seconds and must restore it. It may never end a recording session.**
`00-drivers` stopping `readsb` briefly for its check, and starting it again on the way out, is within
the rule. *Update 2026-10-05: the rule and the permission stand, but `00-drivers` no longer uses it.
Since the 2026-10-05 ruling that no verify opens the stick, its verify reads only sysfs and `/dev`,
and stops nothing ([§9j](#9j--verified-on-hardware-2026-10-03)).* The reason: `update.sh` runs every step's verify ([§9f](#9f-what-updatesh-does)), and a
verify for the pull step that started the pull window would end a session, and trigger an update
from inside an update ([§9m](#9m--the-portable-rigs-archive-drive)).

**Update 2026-10-04: two tiers, checked by two programs. (Chris), 2026-10-04.** ~~📋 Not built.~~
*Partly built, corrected 2026-10-04: `bin/archive-preflight` is in commit `47ed4ed`, and
`30-archive-drive`'s verify invokes it, treating `0` and `2` as a pass and `1` as a failure.
`bin/clock-preflight` is not in `47ed4ed`.*

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

**Update 2026-10-04 (evening): where the config is edited on a rig built by the bootstrap.** The
first bullet above describes a clone you run steps from by hand. On a rig built by the one-command
bootstrap ([§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)'s evening
update), **the config is `/etc/adsb-receiver/station.yml`, and after the first build you edit it
there, with `sudo`** (it is `root:root 0600`).

- On the bootstrap, `--role`, `--set` and `--config` write the worktree's `config/station.yml`
  before any step runs, and `05-config` installs it to `/etc`. That copy only seeds the installed
  one.
- Every update after that checks out a fresh worktree, which has no `config/station.yml`, because
  it is gitignored. `05-config` then keeps the installed copy (`setup/steps/05-config.sh`,
  `install_station_yml`), and `lib.sh`'s `station_file` reads the installed copy first. Built, not
  yet run on hardware.
- ~~📋~~ The bootstrap's seed must never overwrite an edited `/etc` copy ~~(fix in progress,
  2026-10-04)~~. *Corrected 2026-10-04: built, not yet run on hardware.* A worktree already at the
  commit is reused, and `git reset --hard` leaves its untracked `config/station.yml`
  (`setup/update.sh`, `ensure_worktree`, lines 516–537); `05-config` installs any
  `config/station.yml` it finds over `/etc` (`setup/steps/05-config.sh`, `install_station_yml`,
  lines 112–131).
  - **How.** `drop_seeds` (`setup/update.sh` lines 539–570): once
    `/etc/adsb-receiver/station.yml` exists, it removes `config/station.yml` from every worktree
    under `/opt/adsb-receiver/worktrees`, so no later run installs it over the `/etc` copy: not a
    rollback to that tree, not a bootstrap re-run at the same commit, not the timer finishing a
    first build there. It runs before this run writes its own seed (line 1213), again after the
    candidate's steps (line 1243), and from `on_exit` before its rollback (lines 1019–1021). While
    there is no `/etc` copy, a first build whose `05-config` has not run, the seed is the only
    config and stays (line 552), so the timer's pinned retry still finds it. A failed `rm` is a
    warning, never an exit (lines 560–562).
  - A bootstrap writes a seed only when it was given `--set` or `--config`, or there is no `/etc`
    copy yet; otherwise `prepare_config` keeps the installed copy and writes none (lines 288–294,
    1121–1123, 1211–1217). That half was already in place, and is unchanged.
  - ⚠️ After the steps, this run's seed is removed whether or not `05-config` installed it. If the
    run was given `--set` or `--config` and `05-config` did not finish ok (an earlier step failed,
    or the run was stopped), it warns that the input was discarded and is to be passed again on
    the next bootstrap run (lines 545–547, 565–567). So a signal that stops a bootstrap given
    `--set` during its steps, after the `/etc` copy exists but before `05-config` runs, loses the
    `--set`; the warning says so, and running the bootstrap again with it fixes it.
  - ⚠️ What follows from the code, as built:
    - A bootstrap re-run with `--set` on a built rig whose candidate then rolls back keeps the
      `--set` values in `/etc`, if `05-config` installed them before the failure. The rollback
      re-runs the applied tree's steps (lines 956–986), whose `05-config` finds no seed and keeps
      the installed copy (`05-config.sh` lines 118–121). Nothing restores the previous `/etc` copy.
    - A signal after this run writes its seed but before the steps start leaves the seed on disk
      (line 1218 exits with no `drop_seeds`, and `on_exit` then drops nothing), until the next run's
      `drop_seeds` removes it.
    - `05-config` run by hand from a checkout that has a `config/station.yml` still installs it
      over `/etc`. That is its documented manual path, and its header says so (`05-config.sh`
      lines 23–24).
  - Rejected: "the 05-config marker", in which `05-config` records that it installed a seed and
    does not install one it has already installed. The implementer chose `drop_seeds` because it
    "changes only update.sh and leaves 05-config's by-hand behavior alone". The build's own
    choice; Chris approved the fix landing, not this comparison.
  - Run on the workstation, not on a Pi: the sandbox smoke test `tests/smoke_update.sh`, which
    CI's `smoke` job runs, passes 122 checks in about 35 s. As reported by the implementers, not
    seen by Claude: 9 checks in the suite's T cases fail without `drop_seeds`, and 3 checks
    in case X2 fail without the `on_exit` call.

### 9e. The first build is by hand; after that, updates are automatic

*Note 2026-10-04: the first half of this heading is superseded, as the paragraph below says. The
heading is kept as written because nine links in this document point at its anchor.*

~~**The first build is by hand, one step at a time.**~~ *Superseded 2026-10-04 (Chris): the first
build is one command, and the updater it installs finishes the build; see the evening update at the
end of this section.* BUILD.md §8 has human gates in it: a sky check,
a power cycle with the network unplugged. A script cannot pass those for you. After the first build,
`setup/update.sh` orchestrates.

**(Chris) Updates are automatic, on both rigs.** *"I really do not like updating by hand."*

⚠️ **Chris overruled an earlier recommendation, on 2026-10-03, to never update automatically.**
The one risk raised against automation was that **a broken update leaves an unattended archive with
a gap in it.** ➡️ That risk is what the rest of this section exists to answer: the CI gate
([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable)), every step's own verify
([§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect)), and rollback
([§9f](#9f-what-updatesh-does)).

**Update 2026-10-04 (evening): the first build is one command. (Chris), 2026-10-04.** ~~📋 **Ruled, not
built.** No file, unit or mode below exists yet. This records the decision, not code.~~ *Corrected
2026-10-04, later that evening: built, and ⚠️ not yet run on hardware. Where the code differs from
the text below, or adds to it, the text is corrected in place and the details are in "As built" at
the end of this update.* Chris's input that started it:

> *"build up a station with one command in pi after the os is installed and the units should be able
> to get updates without me needed to go to every single station"*
>
> *"the act of me starting the install should be considered my agreement to do it. Adding manual
> steps just makes the process longer"*
>
> *"If I am installing a new image - rebooting is common and not an issue."*

His words were input, not rulings. An architecture consultation weighed them on their merits. Then
Chris ruled each choice below through multiple-choice questions, taking the consultation's
recommendation every time, and that choice is the decision.

- **The command,** run on the Pi once the OS is installed:
  `curl -fsSL …/setup/bootstrap.sh | sudo bash -s -- --role portable|stationary [--set key.path=value] [--config FILE]`.
  A two-command form, a `git clone` and then `setup/bootstrap.sh` run from it with `sudo`, is
  documented beside it, for a reader who wants to read before running.
- **`setup/bootstrap.sh` is a thin fetcher.** It makes the bare clone under `/opt/adsb-receiver/`
  ([§9f](#9f-what-updatesh-does)'s evening update), checks out a worktree, and ~~`exec`s~~ *runs
  (corrected 2026-10-04: as a child process, not by `exec`, because it reads the exit code to
  decide the reboot)* that worktree's
  `setup/update.sh --bootstrap`. Everything worth reviewing runs from the clone, under CI. ➡️ There
  is one orchestrator: the first build runs the code the timer runs every day. *Which commit it
  checks out, as built: see "As built" below.*
- **`--role` writes the only config.** The bootstrap copies that role's template, applies each
  `--set`, validates the result as `05-config` does, and writes it to the worktree's gitignored
  `config/station.yml` before any step runs, so `05-config` installs it as it does today.
  `--config FILE` supplies a whole file instead, for the 🏠 stationary's many values.
  `--role stationary` with no position refuses at the start, before anything irreversible.
  - **Why this does not bring back two truths.** [§9b](#9b-one-bash-script-per-build-step)'s ⛔
    exists so the role comes from the config the rig carries, never from a flag beside that config. A
    flag that *creates* the config, before any step runs, leaves one truth: from then on every step
    and every update reads the role from `station.yml`, as before. The steps and `update.sh`'s update
    path still take no role flag, and CI is to grep that they never read one. *Built 2026-10-04: CI
    greps `setup/steps/*.sh` and `setup/lib.sh` for a `--role` or `ADSB_ROLE`. `update.sh` is not
    grepped, because its `--role` belongs to `--bootstrap`; its own argument parser refuses `--role`,
    `--set`, `--config` and `--no-format` without `--bootstrap`.*
- **First-build mode.** With no `applied` symlink yet there is nothing to roll back to. So
  `update.sh --bootstrap` installs `50-updater` first (the updater, its timer and the login banner),
  then runs every other step in order, and **continues past a step that fails**, recording each
  step's result. `status.json` says `result: incomplete` and names the failing step. `applied` flips
  only when every step passes. In first-build mode a failed fetch is not fatal: it builds from the
  worktree it has.
  - ➡️ **The timer already ruled in [§9f](#9f-what-updatesh-does) finishes the build:** about 3
    minutes after the next boot, then daily, with no second command. A puck plugged in later, or the
    `/dev/rtc0` that appears only after the reboot, completes the build by itself, and the writer
    starts. Missing hardware never stops the install.
    - *Corrected 2026-10-04, as built: "about 3 minutes after the next boot" is the 🎒 portable's
      timer; the 🏠 stationary's has no boot trigger, so it finishes at its nightly run. The timer
      finishes the build pinned to the bootstrap's commit, not the channel's tip (see "As built").
      And the archive drive is the exception to "completes the build by itself": only the bootstrap
      formats, so a drive plugged in later is formatted by hand, with the command step 30 prints, or
      by running the bootstrap again while the build is still incomplete.*
    - *Corrected 2026-10-05: on a recording 🎒 portable the timer never finishes the build.* The
      writer starts at boot, before the 3-minute timer, and holds the recording lock from then on, so
      every timer run finds the lock held and exits (`ADSB-UPDATE-SKIPPED lock-held`, seen on the 🎒
      portable after its first bootstrap's reboot, 2026-10-04 at 20:08). ➡️ There the path that
      completes the build is the pull window, as ruled on 2026-10-04 and recorded at the end of this
      section. The timer still finishes a build that installed no writer, because then nothing holds
      the lock.
    - ℹ️ ~~`update.sh`'s and `bootstrap.sh`'s own closing messages make the same false claim, and so
      does `update.sh`'s refusal of `--rev` during an incomplete first build ("the timer finishes it
      at the bootstrap's commit"); their text is owed separately, through `implementer`, and is not
      corrected here.~~ *Corrected 2026-10-05: fixed in `1d5f631`: `update.sh`'s incomplete-build
      warning and its `--rev` refusal, and `bootstrap.sh`'s header and reboot notice, no longer
      say the timer finishes the build.*
- **The reboot, once.** `bootstrap.sh` reboots, not `update.sh`. ~~When `update.sh --bootstrap` has
  exited and the reboot flag is set (`need_reboot`, in §9f's evening update), `bootstrap.sh` prints a
  5 s notice and reboots.~~ *Corrected 2026-10-04, (Chris), after the code reviews: a set flag is not
  enough. `bootstrap.sh` prints a 5 s notice and reboots only when five conditions all hold, and
  only on a first build; the conditions and why are in "As built" below.* `--no-reboot` suppresses
  it. The notice is a delay, not a prompt.
  ➡️ `update.sh` still never reboots (§9f). [§9l](#9l-rejected)'s rejection of letting the updater
  reboot is scoped, not dropped.
- **The foundation tier, invoked by the bootstrap.** The two irreversible acts of a first build move
  into [§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away)'s
  `setup/foundation/`, for the 🎒 portable role only. They are invoked only by `update.sh --bootstrap`,
  which a human starts by hand, and never by a step or by the timer.
  - **`setup/foundation/rtc-overlay.sh`** backs up `config.txt` to a dated copy, appends
    `dtparam=i2c_arm=on` and `dtoverlay=i2c-rtc,ds3231` only if they are absent, so a second run does
    nothing, and sets the reboot flag. `20-portable-clock` does not change: it still never writes
    `config.txt`, and it still reports a missing `/dev/rtc0`. ℹ️ This replaces an earlier ruling that
    the RTC overlay is a human gate, like `mkfs`. This document never recorded that ruling;
    ~~`setup/steps/20-portable-clock.sh`'s header still calls the overlay a human gate.~~
    *Corrected 2026-10-04: step 20's header and its gate message now say that the bootstrap's
    `rtc-overlay.sh` writes the overlay and that the charge-path fix is a hardware-assembly step.*
    ⚠️ Belief, from
    the consultation, not seen: writing the two lines with no RTC board fitted is harmless, because the
    driver's probe fails and no `/dev/rtc0` appears. ~~⚠️ **Open:** step 20's gate message also tells
    the builder to check the RTC module's charging circuit first
    ([BUILD.md §6b](BUILD.md#6b-gps-alone-does-not-close-it), the ZS-042 board's charging circuit). The ruling does not say where that check goes once the
    overlay is written for them.~~
    - **Closed 2026-10-04, (Chris): the ZS-042 charge-path check is a hardware-assembly step,** in
      [BUILD.md §6b](BUILD.md#6b-gps-alone-does-not-close-it), done before the board is wired to the
      Pi. 🔑 The ZS-042 trickle-charges its cell from the moment its VCC pin is powered, overlay or
      not: the overlay only makes the kernel talk to the chip. So the overlay write was never the
      moment of the hazard, a gate on it guards the wrong event, and no script can see a diode.
      - `rtc-overlay.sh` writes nothing when `/dev/rtc0` already exists. That is an effect check,
        not a Pi-model table.
      - When it does write, it prints one line marked `NOTE:`, saying that on a ZS-042 board with a
        CR2032 the charge path must already be removed, and that nothing here can check it.
        `update.sh` records that line in that run's `status.json` `notes`, and in the `foundation`
        record that later runs carry forward. The login banner does not show it.
      - There is no banner line, no flag and no Pi-model condition.
      - Chris's input that the hazard applies only to Pis before the Pi 5 was weighed: the hazard
        follows the board, not the Pi, and the 🏠 stationary has no RTC by ruling
        ([§9l](#9l-rejected)).
      - Rejected: **a bootstrap flag** such as `--rtc-charge-path-fixed`, a prompt by another name
        that attests to nothing a script can verify; **a permanent banner line**, which can never
        clear and trains the reader to skip the banner; **a Pi-model condition on the overlay**,
        which guards the wrong hazard and needs a model table; and **refusing to write the overlay**
        (keeping the human gate), which guards nothing, because the board charges anyway.
  - **`setup/foundation/format-archive.sh`**, under a strict rule:
    - If any device already carries the label `adsb-archive`, it formats nothing, and step 30 mounts
      that device.
    - Otherwise the candidates are every whole disk with `TRAN=usb` and `RM=1` that is not the parent
      of any mounted filesystem or active swap, is not an `mmcblk*` or `nvme*` device, is at least
      8 GB, and either holds no filesystem, RAID or LUKS signature on any partition, or has only one
      filesystem, which mounts read-only and holds nothing but `System Volume Information`, `.Trashes`
      and `lost+found`.
    - It formats **only if exactly one** candidate remains. Two candidates, none, a signature it
      cannot read, or a mount failure: it refuses loudly, the build continues without the archive,
      and the exact command to run is put in `status.json` and the login banner.
    - `--no-format` turns it off. It formats partition 1, as
      [§9m](#9m--the-portable-rigs-archive-drive) rules, and creates an MBR with one partition only if
      the disk has no partition table.
    - ➡️ It refuses the boot medium, anything mounted, anything with a signature it did not prove
      empty, a second stick, a disk under 8 GB, and the 🏠 stationary role.
    - *As built, 2026-10-04, the rule is stricter than the bullets above, and a labeled drive that
      is not ext4 is refused rather than left to step 30. The details are in
      [§9m](#9m--the-portable-rigs-archive-drive), in the update after its foundation exception.*
    - ⭐ The hazard is not consent, which starting the install gives. It is the wrong device: nobody
      can consent to formatting the wrong one, and a human typing `/dev/sdX1` at a terminal carries
      that hazard too. The rule can be stricter than a tired human.
- **Why three earlier rulings are answered, not dropped.** [§9l](#9l-rejected)'s rejection of an
  `install-all.sh`, §9m's *"No step ever runs `mkfs`"* and §9h's denylist share one reason: the
  update path runs unattended, on every update, the remote 🏠 stationary rig included. A first build
  started by a human hand at the bench is outside that reason, and the foundation tier is outside
  both the steps and the update path, where §9h already puts the boot disk. Each of the three is
  corrected in place, dated. The sky check and the power cycle with the network unplugged stay human
  gates, after the build: they are readiness, which
  [§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect) moved to the preflights, so the build
  does not wait for them.
- Rejected:
  - **A fat `bootstrap.sh` that builds without `update.sh`.** Two orchestrators diverge. The thin
    fetcher keeps one code path, the one the timer exercises daily.
  - **Resuming from a checkpoint file.** It is a second truth, which can disagree with the rig after
    a change by hand. Resuming comes from the steps' idempotence and the timer.
  - **A self-removing resume unit**, such as an `adsb-bootstrap-resume.service` that re-runs the
    bootstrap and disables itself. It duplicates the timer, it is a second updater path, and a unit
    that re-runs `curl | bash` at boot is a shape nobody should ship. The ruled 3-minute timer already
    is the resume, and it has nothing to remove.
    - *Narrowed 2026-10-05, by the two rulings of 2026-10-04 (night), at the end of this section and
      of [§9f](#9f-what-updatesh-does).* On a recording 🎒 portable the 3-minute timer is not the
      resume, because it always finds the lock held; the pull window is. The rejection stands, and
      was applied again to a boot-time first-build unit with a condition (option C at the end of
      this section). The home-gated opener of the second ruling is not a second updater either: it
      opens the window, and the window runs the one update oneshot.
  - **Deriving the role from hardware**, such as a puck present meaning portable. A stationary with a
    puck on the bench, or a portable bootstrapped with the puck still in the bag, gets the wrong
    role, and the role decides which irreversible acts run.
  - **Stopping at the first failing step, to be re-run once it is fixed** (the consultation's first
    design). Missing hardware would stop the install, and the installed timer already finishes it.
  - **Only the two-command form.** Chris asked for one command. The `curl` form trusts what
    `update.sh` trusts every day, TLS to the repo's host and whatever is on `main`, so it adds no new
    trust. It only takes away reading before running, and the thin fetcher keeps what runs unread
    small.

**As built, 2026-10-04 (evening).** `setup/bootstrap.sh`, the bootstrap half of `setup/update.sh`,
`setup/foundation/rtc-overlay.sh` with `rtc_config.py`, and `setup/foundation/format-archive.sh`
with `archive_candidates.py` are written. ⚠️ **Nothing here has run on a Pi.** Every mechanism was
checked off the Pi only: the unit tests under `tests/` (105 pass), `bash -n` and `shellcheck`, and,
as reported by the implementer and not seen by Claude, a sandbox run of `update.sh` and
`bootstrap.sh` with fake steps (92 cases). What only the Pi can prove is listed at the end of
[§9f](#9f-what-updatesh-does)'s "As built". Two choices below were ruled by **(Chris), 2026-10-04,**
after the code reviews, through the same route as the rest of this update, and marked so; the
others are the build's own.

- **Which commit is built. (Chris), 2026-10-04.** `bootstrap.sh` takes the channel from `--role`:
  🎒 `main`, 🏠 `stable` ([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable)). Run
  through `curl | bash`, it builds the channel's tip; a 🏠 stationary first build takes `stable`'s
  tip without the soak, because the bench is attended, and the soak protects the unattended rig.
  Run from a checkout, it builds that checkout's `HEAD`: it fetches the commit into the bare clone,
  warns if it is not on the role's channel, and warns that uncommitted edits are not what is built.
  `update.sh --bootstrap` builds the commit it runs from, and refuses `--rev`.
  - Why: the soak is about what code runs as root on the remote rig, and the config code, the
    foundation scripts and the updater are more privileged than the steps, not less. Reading before
    running is a promise about the bytes that execute; running a later `main` would break it exactly
    where a reader relied on it.
  - Rejected: the channel from the role only, with no checkout case; and keeping `main` for both
    roles, with the unsoaked first build only documented.
  - ⚠️ **A bootstrap run again on a built 🏠 stationary builds `stable`'s tip without the soak,
    however young it is.** It is an ordinary update then, with rollback and the
    [§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away) gate. The timer is
    what waits out the soak. `bootstrap.sh`'s header says so.
  - *Superseded in part 2026-10-05, (Chris): `--role` no longer chooses a channel. Both roles build
    `stable`'s tip, the first build without the soak on either
    ([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable), its 2026-10-05 update). The
    checkout case stands; its "not on origin/$channel" warning is to add that CI may still be
    running. ~~📋 Ruled, not built: `bootstrap.sh` still sets `channel=main` for `--role portable`.~~*
    *Corrected 2026-10-05: built in `94e4f94`, ⚠️ not yet run on a Pi. `bootstrap.sh` sets
    `channel=stable` for both roles, and the checkout case's warning reads "not on origin/stable,
    the rigs' channel (CI may still be running)" (smoke case P).*
- **The config, as built.** The base is `--config FILE`, else the installed
  `/etc/adsb-receiver/station.yml`, else the role's template. `--role` must match the base's
  `station.role`, and `--set station.role` is refused. A `--set` key must already exist. Its value
  stays a string where the key holds a string; otherwise it is read as null, true or false, a
  decimal number, or a list or map only when it plainly is one, and quoting forces a string. With no
  `--set`, the file is copied as it is, so the template's comments survive; with `--set` they are
  lost, and a header line says so. On a built rig the installed config is kept untouched unless
  `--set` or `--config` is given. Where it is edited afterward: [§9d](#9d-config).
- **The reboot. (Chris), 2026-10-04.** `bootstrap.sh` reboots only when all of these hold:
  - this run began with no `applied` (a first build);
  - this run asked for a reboot. `bootstrap.sh` names a file of its own in `ADSB_REBOOT_MARK`, and
    `lib.sh`'s `need_reboot` appends every reason to it, even one the flag already holds. The
    reason: `need_reboot` writes a reason into the flag only once, so a second bootstrap in the same
    boot adds no line to the flag, and a before-and-after comparison of the flag would miss it. That
    comparison is kept only as a fallback, for a commit whose `lib.sh` predates the mark;
  - `adsb-update.timer` is enabled, so something finishes the build after the boot;
  - the recording lock is free, or is held by `adsb-writer.service` whose process started during
    this run, the seconds-old recording the build itself started at its end (that exception, and
    the per-run mark above, are the build's own, after review). It is read with `lslocks`, which
    does not take the lock. Any other holder, such as an update the timer started meanwhile, blocks
    the reboot;
  - `update.sh` exited `0` (applied) or `3` (incomplete).
  - Otherwise it prints `REBOOT REQUIRED` with every reason it is not rebooting, and exits with the
    build's code. Once `applied` exists it never reboots. A failed `systemctl reboot` keeps the
    build's exit code.
  - Why: Chris's *"rebooting is common and not an issue"* is about installing a new image. On a
    built rig a reboot can end a recording, and a built rig has the banner and the timer to carry
    the flag.
  - Rejected: a reboot on any first build; a reboot on any build when this run set the flag; and no
    reboot at all, even on a first build. ➡️ What would change it: Chris asking for reboots on
    re-runs, and then as an explicit `--reboot`, never a default.
- **A stop signal.** After SIGTERM, SIGINT or SIGHUP, `update.sh` exits `128+N` (143, 130, 129),
  even in a first build, where `status.json` still says `incomplete`. So a Ctrl-C during a build
  never turns into a reboot countdown. The foundation scripts are not started after a signal, so
  nothing is formatted after a Ctrl-C (the build's own choice, after review).
- **An unexpected stop in a first build.** If `update.sh` itself stops on an error (`set -e`)
  during a first build, it records `incomplete`, not `failed`, so the timer's pin still finds the
  build and retries it, and it exits with the failing command's code, not `3`, so `bootstrap.sh`
  does not take it for an ordinary incomplete build and reboot. The build's own choice, after
  review. Rejected: letting the timer also pin on a `failed` status, which would pin on a failure
  written for other reasons.
- **The foundation record is carried forward.** `status.json`'s `foundation` object (the overlay's
  result, the format's report, the `NOTE:` lines, and when it ran) is copied unchanged into every
  later `status.json`, so the pinned run that finishes an incomplete build does not erase it. The
  banner's "ARCHIVE DRIVE NOT FORMATTED" line, which reads that record, is hidden once the archive
  mount point is mounted. The build's own choice, after review.
- **`rtc-overlay.sh` and `rtc_config.py`.** The overlay script reads `config.txt` through
  `setup/foundation/rtc_config.py`, tested in `tests/test_rtc_config.py`, which reads the file as
  the firmware does, as far as this rule needs, with the last setting winning. A line turns a
  setting on only before any section or under `[all]`, and a later line that undoes it, in any
  section but `[none]`, counts as undoing it; `[none]` is ignored. Only the literal `dtparam=i2c_arm=on`
  (or `i2c=on`) counts as on, so `=1`, `=true` or a bare `dtparam=i2c_arm` gets the canonical line
  appended, a harmless duplicate. An `i2c-rtc` overlay for another chip, in any section but
  `[none]`, refuses, because a human decides which RTC is fitted. The script appends missing lines
  under a new `[all]`, writes by temporary file and rename after a dated backup, re-reads the file,
  and calls `need_reboot`. With both lines already in effect and no `/dev/rtc0`, it writes nothing
  and calls `need_reboot`. ⚠️ An `include`d file is not followed. ⚠️ On FAT, a power cut leaving
  either the old file or the new one is the usual outcome of a rename, not a guarantee; the backup
  is the remedy.

**Update 2026-10-04 (night), written 2026-10-05: the pull window completes an incomplete 🎒 portable
build; the writer never waits for an update at boot. (Chris), 2026-10-04, about 20:45.** Ruled by
multiple-choice question, after a check against the rulings already written and then an
architecture consultation. It answers the correction above: on a recording portable the timer never
finishes the build.

- **Chris's input, checked first:** *"writer waits → network available? → update → start writer"*.
  As worded, it re-derives the refusal in [§9f](#9f-what-updatesh-does)'s evening update of "an
  update at boot before the writer starts, with a bounded network wait". The consultation refused
  the network predicate again, for two reasons:
  - a phone hotspot at the airport is a network, so the rig would run a `readsb` rebuild before
    recording at a shoot;
  - the pinned first build needs no network, so the predicate gates the wrong thing.
- ⭐ **The "incomplete" rig was already recording.** The writer's unit decides by its preflights,
  never by `applied`: `40-archive-writer` renders the two `ExecStartPre=+` preflights, then the
  `flock` in `ExecStart=`, and no condition on the build. An incomplete build withholds only the
  update path.
- **The window already completes it, with no code change.** The window wants `adsb-update.service`,
  whose `ExecStart=` runs `adsb-update` with no arguments, which is timer mode. With no `applied` and
  `status.json` at `incomplete`, `examine_applied` pins the run to the bootstrap's commit, and a
  failed fetch does not end a first build, so it runs offline too. On the Pi, without the
  workstation: `sudo systemctl start adsb-pull-window.service`, then `stop`, the two commands the
  step-60 sudoers rule allows. The 3-minute timer still completes a build that installed no writer,
  because then the lock is free.
- ✅ **Seen on hardware, 2026-10-05,** on the 🎒 portable: the window stopped the writer, whose file
  closed with 6989 frames, before the update started, at 20:21:37 Arizona time. The update ran with
  the lock free, in timer mode, at the bootstrap's pinned commit `d2c8f91`, and six of its seven
  steps passed. The seventh is the hazard below.
- Rejected:
  - **(C) A state-gated, bounded, boot-time first-build unit,** with `ConditionPathExists=!applied`
    and `Before=` the writer. It is the "self-removing resume unit" rejected above, with a condition.
    And it makes every failing step run ahead of recording at every field boot until the build
    completes: the shape of the first bootstrap on 2026-10-04, where a failing step (`00-drivers`'
    `rtl_test` hanging the stick) took down the Pi's whole USB hub.
  - **(B) The writer conditioned on `applied`.** A rig able to record stays silent until it goes
    home: the shape that [§9m](#9m--the-portable-rigs-archive-drive)'s option A1 removed.
- ➡️ **What would reopen it:**
  - the window does not take the pinned path, or its ordering fails (neither happened on
    2026-10-05, above);
  - Chris rules that a rig built away from home must reach `applied` by its next boot with no hand,
    which is C's one real gain;
  - a step whose *install* needs hardware that arrives after the bootstrap;
  - Chris rules the weeks-long `incomplete` banner unacceptable in itself.
- ℹ️ **The timer's skip line names one kind of holder.** `lock_held_timer` in `update.sh` gives the
  same reason whoever holds the lock: *"a recording session is on, so no update (PLAN §9f)"*, or,
  with the pull window open, that the window's ordering did not hold. A recording session is the
  only lock holder its wording names. The holder itself, from `lslocks`, is printed beside it.
- ⚠️ **Found 2026-10-05~~, and open~~; ruled the same night (the block below): a pinned first build whose own step cannot pass is a trap the
  design did not name.** Every way out but a second bootstrap is closed:
  - `update.sh` refuses `--rev` while a first build is incomplete (`examine_applied`);
  - on a recording portable the timer always finds the lock held;
  - the window re-runs the same pinned commit, so a fix pushed to `main` never reaches the rig.

  On 2026-10-05, step `60-portable-pull` failed at the pin on a broken-pipe bug in its own check,
  fixed on `main` in `e019b29`. The only way out was a second one-command bootstrap by hand: stop
  the writer, then run the `curl` line, which built `main`'s tip ("As built" above) and completed
  the build. Chris chose that route by multiple-choice question. ➡️ ~~Nothing is ruled about
  preventing the trap.~~ *Ruled 2026-10-05, (Chris): the trap is kept, with an exit; see the update
  right below. ~~📋 Not built.~~* *Corrected 2026-10-05: (b), the one-command exit, is built in
  `94e4f94`, ~~⚠️ not yet run on a Pi~~; ~~(a) is still 📋 not built.~~* *Corrected 2026-10-09: (a) is
  built, in `f411815`; see "The opener, as built" at the end of §9f.* *Corrected 2026-10-10: (b)
  runs only on a second bootstrap of an incomplete, recording first build; not yet occurred. No SD
  is staged to prove it: the ruling after (b)'s beliefs list below.*

**Update 2026-10-05: the pinned first build keeps its daily retry, and gets a one-command exit.
(Chris), 2026-10-05.** 📋 **Ruled, not built.** Nothing below exists in the tree: no `--check`, no
reason line, no banner line, ~~and no change to `bootstrap.sh`~~. *Corrected 2026-10-05: (b) is
✅ built, in `94e4f94`, ~~⚠️ not yet run on a Pi~~; how, in "(b), as built" below. ~~(a) is still not
built: no `--check`, no reason line, no banner line.~~* *Corrected 2026-10-09: (a) is built, in
`f411815`: `--check` prints the reason line below for an incomplete first build, and the banner
prints the two lines below while `status.json` says `incomplete` and `applied` does not exist.
⚠️ Neither has run on a Pi: they show only on an incomplete first build, and the 🎒 portable's
build is complete. See "The opener, as built" at the end of §9f.* *Corrected 2026-10-10: (b) runs
only on a second bootstrap of an incomplete, recording first build; not yet occurred.* Ruled by multiple-choice question,
after a check against the rulings already written and then an architecture consultation, whose
mechanism this is. Chris: *"I have no problem with (a) and (b)."* It answers the ⚠️ trap just above.

- **What stays.** The pin, and the `--check` contract ruled at the end of
  [§9f](#9f-what-updatesh-does), exactly as written. The pinned path is unchanged, and no backoff
  applies to `incomplete`. ⭐ The daily retry at a failing pin is not the defect; the defect is the
  exit.
- 🔑 **Why the retry stays: the rig cannot tell a bug at the pin from a step waiting for hardware.**
  Both fail the same step at the same candidate on every attempt (a puck plugged in later completes
  the build by itself, above). So any rule that stops retrying on "the same step failed again" stops
  exactly the build the retry exists to finish. Every other observable, a new boot, `main` moved,
  time passed, is irrelevant to a pinned run or is already the opener's trigger.
  - The daily retry is already ruled for a case with the same cost: §9f retries a `rolled_back` or
    `failed` candidate once a day until the channel moves, because *"a day bounds the cost and still
    heals a transient with no hands"*.
  - On a recording 🎒 portable it runs only through a home window: one bounded gap per day at home,
    not field loss ([§9m](#9m--the-portable-rigs-archive-drive)'s field-loss rule is about one day's
    shooting). The opener accepts the same gap for every real update. Rejected option C's gap, in
    §9f, was "for nothing"; a pinned retry is the designed completion path for a build the rig cannot
    prove is stuck.
- **What is broken is the exit.** The pin's reason is "a human started it on a known commit"; the
  remedy for a failed candidate is "push a fix"; a push does not reach a pin. So the only exit is a
  hand, and on 2026-10-05 it took two commands, stop the writer and then the `curl` line: the
  "multiple commands" Chris refused. The first build is the attended phase by the design's own
  reasoning, so a hand as the exit is consistent; a two-command hand is not.
- **(a) `--check` and the banner name the trap, and the one command out of it.**
  - `--check` exits `0` for every incomplete first build and prints one reason line, carried by the
    opener's single `ADSB-HOME-UPDATE` journal line: *"pending: the first build is incomplete at
    <sha12 of candidate_rev>; the last run failed <failed_steps> at <finished_at>; the window retries
    this same commit, and a fix on main does not reach it"*. It takes no lock and writes nothing.
  - When `status.json` says `incomplete`, the banner adds two lines after its existing "last
    update: incomplete" and "failed steps" lines:
    - *"first build: incomplete at <sha12>; every home window retries this same commit (the pin). A
      step waiting for hardware completes once it is plugged in; a fix pushed to main does not reach
      a pinned build."*
    - *"if <failed_steps> cannot pass at this commit, run the bootstrap again, one command (BUILD.md
      §8): curl -fsSL …/setup/bootstrap.sh | sudo bash -s -- --role <station.role>"*, the role read
      from `/etc/adsb-receiver/station.yml` under the banner's 5 s timeout, or the generic sentence if
      it cannot be read: *"run the bootstrap again, one command: BUILD.md §8 has the line for your
      rig's role"*.
    - The lines clear when `applied` exists.
  - **State:** read from `status.json` only: `result`, `candidate_rev`, `failed_steps` and
    `finished_at`, all of which exist. Nothing is written by `--check`, nothing under `/var/lib`; no
    counter, no boot id.
- **(b) A bootstrap run again on a recording rig ends the session itself.** On a first build (no
  `applied`) whose recording lock is held by `adsb-writer.service`, `bootstrap.sh` ends the session
  the one ruled way:
  1. it starts `adsb-pull-window.service`;
  2. it waits for the `adsb-update.service` the window starts through `Wants=` (the pinned run,
     which will fail again) to finish;
  3. it runs `update.sh --bootstrap` with the lock free;
  4. it stops the window at its end, whose `ExecStopPost=` starts the writer, or the ruled reboot
     ends everything.

  `update.sh` still never stops the writer. §9f's paragraph on the 🎒 portable's first bootstrap is
  narrowed to match: its "once" becomes "on any first build".

  *The implementer's condition, not a new ruling:* if the rig has a writer but no
  `adsb-pull-window.service` unit (a writer installed by hand before step 60 ever ran, the
  2026-10-04 shape), the bootstrap keeps today's behavior and refuses with the
  stop-the-writer-by-hand instruction; the window path applies only where the window unit is
  loaded.

  *Added 2026-10-05:* ✅ **(b), as built, 2026-10-05, in `94e4f94`**
  on `main`, pushed about 21:55 Arizona time; ~~CI pending when this was written~~ *corrected
  2026-10-05: ✅ CI green (scripts, smoke and `advance-stable` all succeeded; `stable` is
  `94e4f94`), seen on GitHub by the coordinating session at about 22:00 Arizona time*. ~~⚠️ **Not yet run
  on a Pi.**~~ *Corrected 2026-10-10: runs only on a second bootstrap of an incomplete, recording
  first build; not yet occurred.* Smoke cases W1 to W7 in `tests/smoke_update.sh` exercise the shapes below on stubs (a
  stub `systemctl`, a `flock` process holding the lock). From `setup/bootstrap.sh`:
  - **When.** A first build (no `applied`) whose recording lock is held by `adsb-writer.service`,
    read with `lslocks` and the holder's cgroup, and only where `adsb-pull-window.service` is
    loaded.
  - **The wait.** It starts the window, then waits for the window's `adsb-update.service` to leave
    `activating` with no start job queued for it: polled every 5 s, a line every 30 s, bounded at
    45 min, the window's `TimeoutStopSec=`. Past the bound it names the lock's holder and exits 1.
  - **The build and the close.** It runs `update.sh --bootstrap` with the lock free, and closes the
    window once that returns, before the reboot decision.
  - **Every other path.** The `EXIT` trap closes the window once; while the window's update is
    still `activating`, with `--no-block`, so the window ends itself once that update finishes.
  - **A failed window start** is not closed: the bootstrap starts the writer again itself
    (`systemctl start --no-block`), and exits 1.
  - **If the window's pinned run completed the build,** the run logs both commits, the pin's and
    its own, and applies its own as an ordinary update; it never reboots then.
  - **Where the window unit is absent, or the holder is not the writer,** `update.sh`'s refusal
    names the holder and what frees the lock. The refusal is now holder-aware, and is told by
    `ADSB_BOOTSTRAP_WINDOW` what the bootstrap tried (`opened`, `no-unit`, `built`, `not-writer`).
  - ⚠️ **Beliefs about systemd it rests on, ~~none seen on a Pi~~:** *Corrected 2026-10-10: some
    are now seen under the opener on the 🎒 portable (§9f's record on hardware, 2026-10-10 at
    08:45), not under the bootstrap. Both start and stop the same `adsb-pull-window.service`. Each
    belief is marked below.*
    - the window's update is `activating`, or has a queued start job, when `systemctl start` of the
      window returns; *update 2026-10-10: seen in effect 2026-10-10 under the opener, not under the
      bootstrap: `adsb-update.service` started alongside the window, as in §9m's 2026-10-05
      journal, where its "Starting" line comes before the window's "Started". Which poll of the
      opener's dispatch wait broke is not logged. The bootstrap's wait reads both the state and the
      job (~~`setup/bootstrap.sh:183–188`~~ `setup/bootstrap.sh:190–195`), so it does not rest on this;*
    - `systemctl list-jobs <unit>` shows a start job still queued; *update 2026-10-10: ⚠️ not seen.
      The opener lists the jobs at every poll (~~`bin/adsb-home-update:297`~~ `bin/adsb-home-update:308`) and logs nothing about
      them;*
    - `systemctl stop` blocks through `ExecStop=`, and `stop --no-block` carries through it;
      *update 2026-10-10: the blocking stop is half seen, under the opener, not under the bootstrap.
      The opener's `timeout 120 systemctl stop` (~~`bin/adsb-home-update:156`~~ `bin/adsb-home-update:167`) returned 0 with the
      update already inactive, so the `ExecStop=` wait had nothing to wait on. Seen: a stop that
      goes through `ExecStop=` and returns. ⚠️ Not seen: the stop waiting while the update is
      `activating`, which ~~`setup/bootstrap.sh:237`~~ `setup/bootstrap.sh:246` relies on. ⚠️ `stop --no-block` is not seen:
      only the trap path takes it;*
    - `ExecStopPost=` starts the writer, and a failed start runs none; *update 2026-10-10: the
      writer start is seen 2026-10-10 under the opener, not under the bootstrap: after the close,
      `adsb-writer` was active and the window inactive. ⚠️ A failed start running none is not seen;*
    - a unit ended by `RuntimeMaxSec=` reads `failed`; *update 2026-10-10: ⚠️ not seen; §9m's
      checklist owes the cap test;*
    - the shutdown cancels a queued start. *Update 2026-10-10: ⚠️ not seen; only the bootstrap's
      reboot path relies on it (~~`setup/bootstrap.sh:397–403`~~ `setup/bootstrap.sh:406–412`).*
  - **No SD is staged to prove (b) on hardware. (Chris), 2026-10-10, about 08:55.** Ruled by
    multiple-choice question, on an architecture consultation's recommendation. (b) runs only on a
    second bootstrap of an incomplete, recording first build; that has not yet occurred.
    - **Why:**
      - **A fresh-SD bootstrap does not reach (b) at all.** ~~`setup/bootstrap.sh:372–380`~~ *`setup/bootstrap.sh:381–389`* opens the
        window only on a first build (no `applied`) whose recording lock is held by
        `adsb-writer.service`, and only where `adsb-pull-window.service` is loaded. A fresh image's
        first bootstrap has no writer holding the lock, so it runs `update.sh --bootstrap` directly
        (`hint=not-writer`).
      - **The shared window unit has now run end to end on hardware,** under the opener (§9f's
        record on hardware, 2026-10-10 at 08:45): the same `adsb-pull-window.service`
        (`setup/steps/60-portable-pull.sh:99–121`), started by a different caller.
      - **The remaining bootstrap-only beliefs either fail closed or are bounded by the 2 h cap.**
        The bootstrap refuses to reboot over a lock holder it cannot attribute to this build's
        writer, and prints the hand command (`lock_verdict`, ~~`setup/bootstrap.sh:146–157`~~ *`setup/bootstrap.sh:153–164`*, read at
        ~~:432–437~~ *:441–446*); it never reboots once `applied` exists (~~:421–427~~ *:430–436*).
      - **(b) is attended by definition:** it runs only when a human has just typed the bootstrap
        line. The 🏠 stationary has no window unit, so it takes the refusal path (`hint=no-unit`,
        ~~`setup/bootstrap.sh:387–390`~~ *`setup/bootstrap.sh:396–399`*), the refusal it had before `94e4f94`.
    - **Proof is opportunistic.** (b) is proven the next time a first build on the 🎒 portable comes
      up incomplete for real (the 2026-10-04 shape) and Chris runs the bootstrap again; its evidence
      is read from the journal of `adsb-pull-window`, `adsb-writer` and `adsb-update`. Its
      precondition is the persistent journal (§9f, "Open, ruled to be decided later"), ~~now on the
      plan as the next rig step~~ *corrected 2026-10-10: built that day as step `06-journal` (§9f, "A
      persistent journal, step `06-journal`"); ~~⚠️ not yet run on a Pi~~ corrected again 2026-10-10:
      install and verify ran on the 🎒 portable under `update.sh`; ⚠️ that the journal survives a
      reboot is not yet seen*: a second bootstrap that reboots would otherwise leave only its own
      output, which carries the script's claims, not systemd's observation.
    - Rejected:
      - **A fresh SD with a plain bootstrap.** It does not reach (b) (above); it re-proves the
        2026-10-05 first-build path and nothing of the bootstrap's open or close of the window.
      - **A fresh SD with a contrived incomplete first build, smoke case W7's shape on hardware.** It
        reaches (b), but it is a hand procedure of several steps invented for a test, on the rig
        whose build is currently healthy; with the journal volatile, a second bootstrap that reboots
        leaves only its own output; and what it proves is a path that fails closed.
      - **Removing `applied` on the 🎒 portable.** It fakes the state, and a wrong turn leaves the
        rig with no `applied` and the writer off.
      - **A narrower proof by hand of the bootstrap-only beliefs** (start the window, interrupt a
        bootstrap, a `stop --no-block`, wait out the 2 h cap). Each tests a bounded or fail-closed
        branch by hand. The two worth hardware time, the cap and a full pull, are already owed on
        §9m's checklist, need no `applied` removed, and are done when the pull is next done.
      - **Dropping the ⚠️ markers on the strength of the smoke stubs.** The stub `systemctl`
        (`tests/smoke_update.sh:108–172`) encodes the same beliefs the script holds: a `list-jobs`
        that lists a job, a `stop` that only removes a flag. The markers stay until (b) runs for
        real.
    - ➡️ **What would change it:**
      - a real incomplete first build on the 🎒 portable: then (b) runs on its own, attended; its
        journal and the bootstrap's output are read, and the markers that hold are cleared;
      - a fresh-SD build scheduled anyway (a re-image of the 🎒 portable, or a bench build of a rig
        with a window unit): then one deliberate incomplete-then-second-bootstrap pass is added from
        a checkout, since the hands are already committed;
      - the opener's close reporting what the belief forbids: its `124` message (the window's stop
        not finished in 120 s, ~~`bin/adsb-home-update:159`~~ *`bin/adsb-home-update:170`*) with the update already inactive, or the
        writer not active after a close. Then the shared mechanism is wrong, (b) inherits it, and
        its hardware proof becomes urgent; the fallback is the written two-command exit in BUILD.md
        §8 (the last "What would change it" bullet of this update);
      - the stationary design giving the 🏠 stationary a maintenance window (§9f, "Open, ruled to be
        decided later"): then (b) could apply to a rig that must heal with no hands, "attended by
        definition" no longer holds there, and a hardware proof is required before the remote
        deploy.
    - ℹ️ *From the consultation, not the ruling's text:* the opener's guard 1
      (~~`bin/adsb-home-update:231–235`~~ *`bin/adsb-home-update:242–246`*) opens nothing while `adsb-pull-window.service` is active,
      activating or deactivating, so its `OnBootSec=4min` fire landing in a bootstrap's open window
      logs `window-active` and is a no-op. `94e4f94` predates the opener (`f411815`), so this
      interaction is newer than (b).
- **Order:** ~~both (a) and (b) are 📋 ruled, not built.~~ (b) is built and reviewed before the opener.
  *Corrected 2026-10-05: (b) is built (`94e4f94`), ~~⚠️ not yet run on a Pi~~; ~~(a) is still 📋 ruled,
  not built.~~* *Corrected 2026-10-09: (a) is built, in `f411815`, ⚠️ not run on a Pi (above).*
  *Corrected 2026-10-10: (b) runs only on a second bootstrap of an incomplete, recording first
  build; not yet occurred.*
- Rejected:
  - **P1: `--check` not pending when the pin already failed the same steps.** That is the
    hardware-waiting build's exact signature, and it narrows a ruled contract on a heuristic the
    resolver does not hold.
  - **P2: a once-per-pin marker under `/var/lib`.** The same wrong stop, plus the "second truth"
    rejected above (resuming from a checkpoint file), when `status.json` already holds
    `candidate_rev` and `result`.
  - **P3 and P6: the pin follows the channel after N failures, or when `main` moved.** They reverse
    §9f's known-commit reason, which carries Chris's name, precisely when the rig is misbehaving; the
    first unreviewed tip that also fails leaves the rig at a different unknown commit, with still no
    exit. ℹ️ Noted, not ruled: for the 🏠 stationary the un-pinned timer path would still apply the
    soak, so the hazard there is thinner; that is the stationary design's question.
  - **P4: `--rev` during an incomplete build.** It runs by hand under the lock, so on a recording
    portable the window must be open first: not fewer commands, and nothing for the opener. And
    `--rev` is "a Pi test" that relies on rollback, which first-build mode lacks.
  - **P5 as stated: accept, with a two-command exit.** The right outcome, the wrong exit.
  - **The 24 h backoff extended to `incomplete`.** Keyed on `finished_at`, it suppresses the retry 4
    minutes after the bootstrap's own reboot, the one retry the design most relies on, because
    `/dev/rtc0` appears only then; keyed on a boot id, it changes nothing.
  - **"Pending only when `main` moved".** A signal a pinned run cannot act on, and it misses a puck
    plugged in while `main` is quiet.
  - **A hardware-versus-bug exit-code contract for steps.** It is the only principled detector, but
    it is a new contract across every step; a misclassification traps the rig the other way; and it
    still gives no exit. ➡️ Recorded as the next design if the daily retry is ever shown to harm.
- ➡️ **What would change it:**
  - the retry itself does harm at home, such as a step at the pin that hangs the hub on every window
    (the 2026-10-04 shape): then step-level first, the exit-code contract second, never a cadence
    rule;
  - Chris rules that an incomplete rig must heal from a push with no hand (the weeks-long
    `incomplete` reopener above): then he reverses the pin ruling (P6, with the soak for the 🏠
    stationary and CI green for the 🎒 portable);
  - an incomplete 🏠 stationary at the remote site with no hand: the pin means a truck roll. That
    case alone could justify an incomplete stationary following soaked `stable`; open for the
    stationary design session;
  - the one-command exit cannot be built inside the window ruling (the bootstrap cannot safely wait
    out the window's pinned run, or the ordering is not what §9m reasons): then the exit is a written
    two-command procedure in BUILD.md §8, and the banner prints both commands.
- ⚠️ **Not verified:**
  - ~~nothing of the opener or `--check` exists;~~ *corrected 2026-10-09: both are built, in
    `f411815`, and applied on the 🎒 portable; see "The opener, as built" at the end of §9f;*
  - the banner has not run on the Pi;
  - the length of a pinned retry at home is not measured (expected minutes, `readsb` already built
    at its pin);
  - that `bootstrap.sh` can start the window, wait for the window-started pinned update to finish,
    then take the lock without a race, is reasoned from `flock -n` and §9m's `Wants=` and `After=`,
    not seen;
  - ~~the window's `ExecStopPost=` writer start is reasoned, not seen;~~ *corrected 2026-10-10: seen
    under the opener, not under the bootstrap (§9f's record on hardware, 2026-10-10 at 08:45);*
  - whether §9f's *"It is the one time a human stops the writer for an update"* is Chris's ruling or
    the consultation's expectation is unmarked in this file.

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
   *Update 2026-10-05, (Chris): the channel is `stable` on both rigs; the soak, a role default, is
   the only role difference (§9g's 2026-10-05 update). ~~📋 Ruled, not built.~~* *Corrected
   2026-10-05: built in `94e4f94`, ~~⚠️ not yet run on a Pi~~.* *Corrected 2026-10-10: run on the 🎒
   portable: its `status.json` read `channel: stable` on 2026-10-09 and 2026-10-10, and it applied
   `5428470` and `398ad28` from `stable` on 2026-10-10 (the step-06 records at the end of this
   section). ⚠️ The 🏠 stationary's soak of 7 has not run: no stationary is built.*
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
session.** *Narrowed 2026-10-05, by the ruling of 2026-10-04 (night) at the end of this section: a
window ends the recording session; the pull and the home check open one. ~~📋 The home check is not
built.~~* *Corrected 2026-10-09: the home check is built, in `f411815`, and applied on the 🎒
portable; see "The opener, as built" at the end of this section.* Starting the pull window, `adsb-pull-window.service`, stops the writer and pulls in the
same update oneshot the timer runs, ordered after the writer's stop. When the window ends, it starts
the writer again; after a reboot, the next boot does. The mechanism is in §9m. ~~📋 None of this is
built.~~ *Corrected 2026-10-04: built, not yet run on hardware. `setup/steps/60-portable-pull.sh`
installs `adsb-pull-window.service`, whose `ExecStop=` waits while that update is running, and the
sudoers rule that lets the logins in `adsb-operator`, but not the writer's own user, start and stop
it; the workstation side is the wrapper, `tools/pull-archive`. ~~⚠️ That `Conflicts=` plus `After=`
order the writer's stop before the update starts is not yet seen on the Pi.~~* *Corrected
2026-10-05:* ✅ *the writer's stop was seen before the update's start, once, on one pull, on
2026-10-05; not a guarantee across boots. The journal lines are in
[§9m](#9m--the-portable-rigs-archive-drive)'s pull window, under its ⚠️ on `Conflicts=` and
`After=`.* ➡️ The ⛔ above stands: `update.sh` still never runs during a recording session. The ordering and the lock are two
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
  - *Update 2026-10-04 (evening), (Chris): the values are ruled, ~~still 📋 not built~~:
    `TimeoutStartSec=40min` and `TimeoutStopSec=30min`; see the evening update at the end of this
    section.* *Corrected 2026-10-04, later that evening: built in the unit `50-updater` renders, and
    `update.sh` rolls back on SIGTERM, SIGINT and SIGHUP; not yet run on hardware.*

**Update 2026-10-04: which steps run, and what the full verify checks. (Chris), 2026-10-04.** ~~📋 Not
built.~~ *Corrected 2026-10-04, later that evening: built in `update.sh`, not yet run on hardware.
As built, every step's install runs first, then every step's verify, and in a first build a step
whose install failed gets no verify.*

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

**Update 2026-10-04 (evening): the update automation, "step 2". (Chris), 2026-10-04.** ~~📋 **Ruled,
not built.** An implementer is writing it as this is recorded. No file, unit, path or field below
exists yet, so none of it could be checked against code.~~ *Corrected 2026-10-04, later that
evening: built, and ⚠️ not yet run on hardware. The text below was checked against the code; where
the code differs or adds, it is corrected in place, and the details are in "As built" at the end of
this update.* It was ruled with
[§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)'s one-command build, by the
same route: an architecture consultation, then Chris's choice, the consultation's recommendation
every time. A check of the proposal against the rulings already written found no collision except
the option rejected below as "`update.sh` stopping the writer".

- **The clone, at `/opt/adsb-receiver/`, all `root:root`:** a bare `repo/` with the anonymous HTTPS
  origin of [§9a](#9a-the-repo-ships-its-own-software-and-the-pi-pulls-it); `worktrees/<sha12>/`, at
  most two, the applied one and the candidate, on detached SHAs; and the `applied` symlink, flipped
  last (step 7 above). `applied-rev` and `status.json` stay in `/var/lib/adsb-receiver/`.
  - Why there, from the consultation: `update.sh` runs as root, and git refuses to work in a
    repository owned by another user unless `safe.directory` is set (⚠️ not checked here). No step
    embeds a clone path: each derives its paths from `ADSB_REPO` in `setup/lib.sh` and copies what
    units run to `/usr/local/bin`, so the location is free on filesystem-layout grounds alone.
    `/opt` is where self-contained add-on software goes, and `/var/lib/adsb-receiver/` is
    [§9d](#9d-config)'s runtime state. A bare repository with `git worktree add --detach` is step 4's
    shape exactly: there is no checked-out branch to drift onto.
  - Rejected: **`~/adsb-receiver`.** Root's git trips the ownership refusal on a login's clone, or a
    root-owned tree sits in a login's home; and a login running `git pull` there would be a second
    updater, beside `update.sh`, that can disagree about what is on the Pi.
  - Rejected: **`/var/lib/adsb-receiver/src`.** It mixes about 100 MB of code and two checkouts into
    §9d's state directory, beside the archive's mount point.
- **Two new steps.** `setup/steps/50-updater.sh` is shared, and reads `station.role` only to render
  the timer. It installs `setup/update.sh` as `/usr/local/sbin/adsb-update`; `adsb-update.service`,
  the oneshot that §9m calls "the §9f update oneshot"; `adsb-update.timer`, rendered by role (🎒
  `OnBootSec=3min` and `OnCalendar=daily`; 🏠 `OnCalendar=*-*-* 03:30`, `RandomizedDelaySec=30min`,
  `Persistent=true`); and the login banner, `/etc/update-motd.d/50-adsb-receiver`. The pull step is
  `setup/steps/60-portable-pull.sh`, §9m's `NN-portable-pull`.
- **The running updater and the candidate's copy:**
  - The copy is installed by **rename**, never in place. Bash reads a running script by offset, so
    truncating it corrupts the run; a rename leaves the old file to the running process.
  - `50-updater` **never** starts or restarts `adsb-update.service`. That would kill the update that
    is running it, and roll back a round that was succeeding. It reloads systemd and enables the
    timer only.
  - **A new updater takes effect at the next run.** The round that installs it finishes under the
    old one. ➡️ A change to the contract between steps and updater (exit `0`, `ADSB_RC_OTHER_ROLE`,
    anything else) takes two commits.
  - `update.sh` is self-contained: it sources no `lib.sh`, because from `/usr/local/sbin` there is no
    `..`. It reads `ADSB_RC_OTHER_ROLE` by sourcing the *candidate's* `lib.sh` in a subshell, so the
    code it interprets is the one the candidate's steps emit.
- **The unit:** `Type=oneshot`; `TimeoutStartSec=40min`, for a source build of `readsb` plus its
  verify; `TimeoutStopSec=30min`, so the rollback on SIGTERM, which may itself rebuild, has room
  before SIGKILL; `Nice=10`, so a build does not starve `readsb`;
  `After=network-online.target adsb-writer.service`. It exits `0` for applied, unchanged, the lock
  held, and no network on the portable, and non-zero for rolled back or failed, so the oneshot shows
  `failed` and the banner can say so. *As built, 2026-10-04: the unit also has
  `Wants=network-online.target`, without which `After=` on that target orders nothing. The full
  list of exit codes is in "As built" below.*
- **The writer-start rule.** At its end, after releasing the lock, `update.sh` runs
  `systemctl start --no-block adsb-writer.service` **only if** that unit is enabled and inactive and
  `adsb-pull-window.service` is neither active nor activating *(as built, 2026-10-04: nor
  deactivating, because a closing window now waits for the update to end before it starts the
  writer itself; see [§9m](#9m--the-portable-rigs-archive-drive)'s pull window)*. Inside the window it must not: the
  start would stop the window through `Conflicts=` in the middle of the rsync, and the window's
  `ExecStopPost=` starts the writer anyway. In the timer's path a writer whose preflights refuse reads
  `activating` (`auto-restart`), not inactive, so nothing is done. ➡️ Starting is not stopping:
  `update.sh` still never stops the writer.
- **A reboot flag.** `lib.sh` gains `need_reboot <reason>`, which appends to
  `/run/adsb-receiver/reboot-required`. That is tmpfs, so a reboot clears it, which is the meaning
  wanted. Step 30 calls it where it now only prints `REBOOT REQUIRED`, and the foundation tier sets
  it. `update.sh` reads it into `status.json`'s `reboot_required` and `reboot_reasons`, the banner
  shows it, and `bootstrap.sh` acts on it once (§9e). *As built, 2026-10-04: `need_reboot` also
  appends every reason to the file a bootstrap names in `ADSB_REBOOT_MARK` (§9e's "As built"), and
  `lib.sh` is the one place the flag's path is written down (see "As built" below).*
- **Logs.** `update.sh` copies each step's output to `/var/log/adsb-receiver/<run>/<step>.log`, and
  the run's to ~~`<run>.log`~~ *`<run>/run.log` (corrected 2026-10-04, as built; a rollback's step
  logs are `rollback-<step>.log` and the foundation's `foundation-<script>.log`, in the same
  directory, which is `root:adm 0750`)*. It keeps the last 20 or so runs, and `status.json` points at them.
  ➡️ An update's record does not depend on the journal. *As built: a run that finds the lock held,
  finds the channel unchanged, skips a candidate in its backoff, or has no network on the portable
  leaves no log directory.*
- **`status.json`:** `/var/lib/adsb-receiver/status.json`, `root:root 0644`, written by `update.sh`
  only, atomically (a temporary file, then a rename), and last (step 7 above).
  - Its shape, versioned from the start as `"schema": 1`: host, role and channel; start and finish
    times; `result`, one of `applied`, ~~`unchanged`,~~ `rolled_back`, `failed`, `incomplete`,
    ~~`no_network`~~ *`not_ready`*; `applied_rev`, `candidate_rev` and `failed_step`; per step, the install and verify
    results, the seconds taken and the log's path, or `skipped (role)`; `readiness`, each preflight's
    exit code and line; `reboot_required` and `reboot_reasons`; the run's log; and `writer_json`, the
    path of the writer's state file.
    - *Corrected 2026-10-04, as built: an unchanged run and a portable timer run with no network
      write nothing, like a lock-held run, so `status.json` keeps recording the last run that
      changed or tried to change the rig. `not_ready` is the 🏠 stationary gate holding an update
      back, or the stationary's fetch failing. The built file also carries `mode`, `exit`,
      `applied_at`, `failed_steps` (a first build's list), `rollback` (its result, the step it failed
      at, `complete` and `leftovers_possible`), `gate`, `foundation` and `notes`; see "As built"
      below.*
  - ⛔ It echoes no config value: no position and no URL. Step names, exit codes, SHAs, times and
    paths only.
  - **A run that finds the lock held writes nothing.** `status.json` records the last run that took
    the lock. A "skipped" record would overwrite that, two writers of one truth. The banner shows a
    held lock live.
  - **It points at `writer.json`, and never copies it.** The writer rewrites `writer.json` at every
    rotation and event, so a copy taken at update time is stale by definition, and a reader would
    trust it. The login is in `adsb-operator`, so it can read `writer.json` itself (§9m, ruling (f)).
    This supersedes §9m's permission to copy it.
- **The banner,** about eight lines: role and host; the applied SHA's prefix, the result, when it
  finished, and the failed step, if any; `REBOOT REQUIRED` with its reasons; the recording lock's
  holder and since when, from `lslocks` and the holder's cgroup (`/proc/<pid>/cgroup`); `writer.json`'s
  state, current file and frames in it; the two preflights' verdicts; and the next update, from
  `systemctl list-timers`. ➡️ Reading the cgroup replaces `ps -o unit=`, so §9m's ⚠️ on
  `ps -o unit=` will be removed once this is built. *As built, 2026-10-04: the banner is
  `setup/files/motd-banner.sh`, installed by `50-updater`; see "As built" below. The lock holder's
  start time is the process's, from `ps -o lstart=`.*
- **`update.sh --rev <sha>`:** run by hand, as root, with a SHA on a pushed branch. It replaces
  copying files to the Pi and running steps by hand, and it is how a step gets its run on the Pi
  before it reaches `main` (§9m, R5). `10-decoder`'s first run on the Pi is to go this way.
- **CI.** The denylist grep, which today reads only `setup/steps/*.sh`, is to cover `setup/update.sh`
  and `setup/bootstrap.sh` too. The job that fast-forwards `stable`
  ([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable), the workflow's TODO for
  [§9k](#9k-the-first-deliverable-in-order) item 3) is part of step 2. *Built 2026-10-04; what CI
  now checks is in "As built" below.*
- **The 🎒 portable's first bootstrap.** Its writer is recording, so `update.sh --bootstrap` would
  exit at its `flock -n`, and the pull window does not yet exist to stop the writer. Chris stops the
  writer once by hand (`sudo systemctl stop adsb-writer.service`), runs the one command, and
  `update.sh` starts the writer at its end, by the writer-start rule above. It is the one time a human
  stops the writer for an update. ⚠️ The consultation expects no restarts on that run, because what is
  installed is byte-identical to what the steps render; not seen.
  - *Narrowed 2026-10-05, (Chris), ~~📋 ruled, not built~~ built 2026-10-05 in `94e4f94`, ⚠️ not
    yet run on a Pi:* "once" becomes "on any first build". On a
    first build (no `applied`) whose recording lock is held by `adsb-writer.service`, `bootstrap.sh`
    itself ends the session through the pull window, runs `update.sh --bootstrap` with the lock free,
    and stops the window at its end; `update.sh` still never stops the writer. The mechanism is at
    the end of [§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic), as (b). ~~Until
    it is built, `update.sh --bootstrap` with the lock held still exits at its `flock -n`, so a
    bootstrap run again on a recording portable needs the writer stopped by hand first, as on
    2026-10-05.~~ *Corrected 2026-10-05: built; how, in §9e's "(b), as built". A bootstrap run again
    on a recording portable's first build ends the session itself where `adsb-pull-window.service`
    is loaded. Where it is not, where the lock's holder is not the writer, or on a rig already
    built, `update.sh --bootstrap` still exits at its `flock -n`, and its refusal names the holder
    and what frees the lock; with no window unit, that is still the writer stopped by hand.*
- Rejected:
  - **`update.sh` stopping the writer.** It collides with rulings already written: ⛔ never during a
    recording session (above); the lock is asymmetric and `update.sh` never waits, because a session
    lasts hours (§9m); and the pull ends the recording session, the one ruled way to end one (above).
    *(2026-10-05: a window ends it; the pull and the home check open one, as narrowed above.)*
  - **An update at boot before the writer starts, with a bounded network wait.** In the field the
    portable boots with no network, so the wait always runs out, and costs its whole bound at the
    start of every shoot. Ordered `Before=` the writer, a round that rebuilds `readsb` would delay
    recording by minutes at boot, the reason §9m rejects `ExecStartPost=` running `update.sh`. And it
    is not needed: the writer's blocking `flock` already gives update-then-record whenever the update
    holds the lock first, and the 3-minute timer lands updates on a rig whose preflights refuse,
    which is when a rig needs fixing.
    - *Extended 2026-10-05, by the two rulings of 2026-10-04 (night): the first at the end of
      [§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic), the second at the end
      of this section.* The refusal stands, and was applied again: Chris's *"writer waits → network
      available? → update → start writer"* re-derived it, and the network predicate was refused
      again, for the reasons in §9e. ⚠️ **The third reason, that the timer lands updates, is false on
      hardware for a recording 🎒 portable.** The writer holds the lock from boot, so every timer run
      skips (seen 2026-10-04 at 20:08, §9e). It holds as worded for a rig whose preflights refuse,
      because the writer takes the lock only in `ExecStart=`, after them. ➡️ The gap it left, no
      automatic update at all on a recording portable, is closed by the home-gated window opener at
      the end of this section, not by an update at boot.
  - The other clone locations, and copying `writer.json`: above.
- **Open, ruled to be decided later. (Chris), 2026-10-04:**
  - ⚠️ **The 🏠 stationary cannot update as designed.** Both rigs archive everything (§9m), so a
    stationary writer holds the recording lock continuously, and its nightly `adsb-update.service`
    will exit at `flock -n` every night. The pull window is portable-only. ➡️ This is to be ruled in
    the stationary design, before any remote deploy. The consultation's starting shape, not a ruling:
    fetch and resolve nightly without the lock, read-only; only when the candidate has changed, start
    an `adsb-maintenance-window.service` shaped like the pull window (`Conflicts=` and `After=` on the
    writer, `Wants=` the update, `ExecStopPost=` starting the writer again, a short cap). The archive
    gap would be minutes, only on nights with a new commit, and recorded as `stop` and `start`
    events: a known gap, not silence ([BUILD.md §7](BUILD.md#7-software) rule 2).
  - **A persistent journal is a separate, small step, ~~later~~; not step 2.** Step 2 writes its own logs
    (above), so it does not depend on one. The consultation's shape: `Storage=persistent` and
    `SystemMaxUse=200M` in a `journald.conf.d` drop-in, as a shared step. It matters most on the
    remote 🏠 stationary, where a watchdog reboot would otherwise erase its own cause, and it costs SD
    card wear on the portable. *Corrected 2026-10-10: no longer later, and no longer open. (Chris),
    2026-10-10, about 08:50: built right after step 5, as the shared step `06-journal`, in the shape
    above. ~~⚠️ Not yet run on hardware.~~ The rulings, the build and its beliefs are in "A persistent
    journal, step `06-journal`", at the end of this section.* *Corrected again 2026-10-10: install
    and verify ran on the 🎒 portable under `update.sh`; ~~⚠️ that the journal survives a reboot is not
    yet seen~~ and the journal survived a reboot there at about 11:14 (corrected 2026-10-10; "✅ A
    second reboot", in that block).*
- 📋 **The step-2 success test.** Not run; it needs step 2 built and bootstrapped on the 🎒
  portable, with `status.json` at `result: applied` and the writer recording again.
  1. **A push to `main` lands by itself.** *Note 2026-10-05: under the channel ruling of
     2026-10-05 ([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable)), the push lands
     once `advance-stable` has run, not on "CI green" alone. ~~📋 Until that ruling is built, the 🎒
     portable still pulls `main`.~~* *Corrected 2026-10-10: the ruling is built, in `94e4f94`, and
     the 🎒 portable pulls `stable` (§9g).* Commit a harmless change that is *rendered*, such as a
     comment in the writer unit's rendered header, so that landing shows beyond a SHA. With CI green,
     start the pull window. Over SSH, with no sudo: `status.json` reads `result: applied` at the new
     SHA, every step `ok` or `skipped (role)`, `readiness` filled in; `readlink
     /opt/adsb-receiver/applied` names it; `systemctl cat adsb-writer` shows the new header; and the
     closed file ends with `stop reason=SIGTERM` ~~(`tools/adsb-extract --check`)~~ *(corrected
     2026-10-05: `tools/adsb-extract --check` prints the `stop` event only as a count among the
     events, with the file's last wall time; the reason is in the window mode's CSV, or the writer's
     journal, `stopped: SIGTERM`)*. Stop the window: the
     writer is active within seconds, with a new `.part`.
     - *Update 2026-10-05, (Chris): the review of a pull is now two-level, the container
       (`--check`) and the content (the frames decode as Mode S); see
       [§9m](#9m--the-portable-rigs-archive-drive), after "The pull".*
  2. **The lock's backstop.** With the writer recording, start `adsb-update.service` by hand. It
     exits within a second, `status.json` is unchanged, and the journal says the lock is held by
     `adsb-writer.service`.
  3. **A deliberately failing commit rolls back, observably.** One commit to `40-archive-writer.sh`
     changes the rendered unit's `Description=` and adds a `die` naming the rollback test to
     `verify()`. With CI green, which does not run the verify, start the window. Expect: the
     candidate's step installs the new unit, its verify dies, nothing flips, and the applied steps run
     again and put the old unit back. `status.json` reads `result: rolled_back`,
     `failed_step: 40-archive-writer`, the bad SHA as `candidate_rev`, `applied_rev` unchanged;
     `systemctl show -p Description adsb-writer` gives the old text; `adsb-update.service` shows
     `failed`, and the banner says so. Then an honest revert commit, which the next window applies. No
     force-push and no rewritten history.
  4. **The window's ordering.** `journalctl -b -o short-precise -u adsb-writer -u adsb-pull-window
     -u adsb-update` shows the writer stopped before `adsb-update` starts and before the window is
     started, and the closed file's `stop` event precedes `status.json`'s `started_at`. That is the
     observable check for §9m's ⚠️ on `Conflicts=` and `After=`.
     - *Update 2026-10-05:* ✅ *the journal half was seen once, on one pull, 2026-10-05: the writer
       stopped at 20:21:37.601549, before `adsb-pull-window.service` and `adsb-update.service` were
       started (`-o short-iso`, Arizona time); not a guarantee across boots. The lines are in §9m.
       The comparison with `status.json`'s `started_at` is not recorded here.*
  - Rejected: testing rollback with a new step that always fails, which fails every rig that pulls it
    and tests nothing about restoring; and a failing commit on a side branch run with `--rev`, because
    the point is the real channel's path.

**As built, 2026-10-04 (evening).** `setup/update.sh`, `setup/steps/50-updater.sh` (the updater,
its unit and timer, and the banner), `setup/files/motd-banner.sh`, `setup/steps/60-portable-pull.sh`,
`tools/pull-archive`, the `lib.sh` changes and the CI changes are written. ⚠️ **Nothing here has run
on a Pi**; the off-Pi checks are those in
[§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)'s "As built". ✅ Read on the
🎒 portable Pi by Claude on 2026-10-04, over read-only SSH: systemd 257, util-linux 2.41.5, and
cgroup v2, which are what these mechanisms assume. Four choices below were ruled by **(Chris),
2026-10-04,** after the code reviews; the others are the build's own, marked as such.

- **Exit codes:** `0` applied, unchanged, a candidate skipped in its backoff, the lock held (timer),
  or no network (🎒 portable timer); `1` failed, including not root, the lock held when run by hand,
  no build on the rig, and a damaged `applied`; `2` rolled back; `3` incomplete (a first build); `4`
  not ready (the 🏠 stationary gate held the update, or its fetch failed); `64` bad usage; `128+N`
  after a signal (143 SIGTERM, 130 SIGINT, 129 SIGHUP), recorded as `incomplete` in a first build,
  and recorded not at all when it arrived before anything changed.
- **The skip marker.** A timer run that finds the recording lock held prints one line beginning
  `ADSB-UPDATE-SKIPPED`, exits `0` and writes nothing. Under systemd the line carries a journal
  priority: warning when the pull window is open, where the writer should already have stopped
  (§9m's ordering), notice otherwise. A run by hand that finds the lock held prints the holder
  instead, says how to free it, and exits `1`. The build's own choice, after review.
- **The soak is tip-aged. (Chris), 2026-10-04.** The 🏠 stationary takes `stable`'s tip, and only
  once the tip's commit date is at least `update.soak_days` old (7 when the key is absent);
  otherwise the run counts as unchanged. The superseded wording, and why, is in
  [§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable).
- **A 24 h backoff for a failed candidate. (Chris), 2026-10-04.** The timer skips a candidate that
  `status.json` records as `rolled_back` or `failed` (its `result`, `candidate_rev` and
  `finished_at`) for 24 h after that run, then tries it once a day until the channel moves.
  `adsb-update --retry` (timer mode only) and `--rev` override it. A skipped run exits `0` and
  writes nothing.
  - Why: a permanent skip turns a transient failure, such as a network blip during a `readsb`
    build, into no update until the next commit, which on the remote rig may be a week; retrying
    every run does a long build on every run, on the CPU-bound rig. A day bounds the cost and still
    heals a transient with no hands. The record already exists in `status.json`, so reading it back
    is one truth, not a new file.
  - Rejected: skipping until the channel moves; retrying every run (as first built); an exponential
    backoff. ➡️ What would change it: a measured case where the daily retry itself does harm.
- **A damaged `applied`, and entering first-build mode. (Chris), 2026-10-04.**
  - A dangling or unreadable `applied` is **never a first build.** If `applied-rev` names a commit
    the clone has, its worktree is recreated, `applied` points at it again, and the run goes on as a
    normal one, with a note. Otherwise the run records `failed`, with `failed_step` "applied is
    dangling and applied-rev is unusable", runs no step, and exits `1`.
  - First-build mode is entered only by `--bootstrap`, or by the timer when `status.json` says
    `incomplete` and names the bootstrap's `candidate_rev`. The timer then stays **pinned** to that
    commit, after each boot and daily, offline too, and follows the channel only once the build
    completes. With no `applied` and no such status, the timer refuses: there is no build on this
    rig. `--rev` is refused until a build exists.
  - Why: first-build mode has no gate and no rollback. It is safe only because a human started it
    on a known commit. Letting a broken symlink, or a new push, enter it would turn the remote rig's
    safest path into its most dangerous one.
  - Rejected: a dangling `applied` failing with no recovery; and a dangling `applied` read as a
    first build (as first built).
- **Rollback does not undo creation. (Chris), 2026-10-04.** Render, diff, install restores every
  file the applied tree renders, exactly. It does not remove what the candidate *created*: a new
  step's unit, or a new drop-in inside an existing step. So `status.json`'s `rollback` says
  `complete: false`, and `leftovers_possible` lists the candidate's steps that the applied tree
  lacks, as a warning, not as the mechanism. The banner and the run's log say the same. The
  rollback checks that the applied worktree is there before it flips back, rewrites `applied-rev`
  with the flip, and runs the applied steps each in a session of its own (`setsid --wait`), so a
  second Ctrl-C does not reach them.
  - ➡️ **The install manifest is the next change, before any 🏠 stationary deploy;** see the
    deferred items below. Until then the 🎒 portable rolls back at home, where Chris can look.
    *Weakened 2026-10-05, by the home-gated opener ruled 2026-10-04 (night) at the end of this
    section: a portable that updates itself at home can roll back there with no one looking. That
    is reported as a reason to pull the install manifest forward on the 🎒 portable too; it is not
    ruled.* *Corrected 2026-10-10: it was not the next change. The opener (`f411815`) and step
    `06-journal` were built before it, and it is still not built: no helper in `setup/lib.sh` records
    what it installs, and `install_if_changed` is still defined in each step that uses it. Its ruled place is
    unchanged: before any 🏠 stationary deploy.*
  - Rejected: a per-step `--uninstall`, a second description of each step, run only at the worst
    moment; a step-list diff with `--uninstall`, which misses the common case, a new file inside an
    existing step; accepting the gap for good, which on the stationary would leave a rejected
    commit's unit running while the alert says "rolled back"; and holding step 2 until the manifest
    is built.
- **`50-updater` and the timer.** The step enables `adsb-update.timer` without `--now`. It starts
  it, or restarts it when the timer file changed, only under `update.sh`, which marks its steps with
  `ADSB_UPDATE_RUN` and holds the recording lock, so a run the timer fires at once only finds the
  lock held. Run by hand, the step leaves the timer to start at the next boot and prints the
  command to start it now, and its verify warns rather than fails. ⚠️ Belief, not checked: a timer
  started after its `OnBootSec=` has passed may elapse at once. *Update 2026-10-09:* ✅ *seen once,
  for `adsb-home-update.timer`, the opener's timer, which step 70 starts the same way: its start
  under `update.sh` fired it at once, on the 🎒 portable at 19:16 Arizona time (the record is at the
  end of this section). For `adsb-update.timer` itself it is still not seen.* The verify runs
  `systemd-analyze verify --recursive-errors=no` (systemd 250 and later). The build's own choices,
  after review.
- **The login banner.** It reads and prints, and changes nothing. It never fails a login: no
  `set -e`, every command guarded, exit `0` always, and every command that could hang runs under a
  5 s timeout of its own. It shows the last update's result, any rollback and what it could not
  undo, a needed reboot, the recording lock's holder from its cgroup and when that process started,
  `writer.json`'s state, the preflights' verdicts as of that update, the refused archive format
  with its manual command until the archive is mounted, and the next update. It does not show the
  one-run notes, such as the RTC charge-path line. ✅ Seen on the 🎒 portable Pi by Claude on
  2026-10-04, over read-only SSH: `/etc/pam.d/sshd` runs `pam_motd` without `noupdate`, and
  `/run/motd.dynamic` was rewritten at an SSH login, so `/etc/update-motd.d/` runs at each login.
  ⚠️ The banner itself has not run there.
- **`lib.sh` is the one place the run directory's paths are written down:** `ADSB_RUN_DIR`,
  `ADSB_REBOOT_FLAG` and `ADSB_RECORDING_LOCK`. Steps `05-config` and `40-archive-writer` and
  `bootstrap.sh` read them from there (the bootstrap from the built commit's `lib.sh`). `update.sh`
  and the banner source nothing, so they carry copies, and CI compares both copies with `lib.sh`'s
  values and fails any other rig script that writes `/run/adsb-receiver` on a non-comment line.
- **CI, as built.** The denylist grep covers `setup/steps/`, `update.sh`, `bootstrap.sh`,
  `setup/foundation/`, `setup/files/`, `bin/` and `tools/`; only `setup/foundation/rtc-overlay.sh`
  may name `/boot/firmware`. A disk-formatting command (`mkfs*`, `wipefs`, `sfdisk`, `dd` onto a
  device and the like) outside `setup/foundation/` fails, through
  `.github/scripts/check-disk-commands.py`, which has tests of its own. The role-flag grep and the
  path comparison are above. The `advance-stable` job is built; whether its token can push a commit
  that touches `.github/workflows/` is ~~unknown until its first run~~ *answered 2026-10-05: ✅ it
  can; the job fast-forwarded `stable` on every push to `main` on 2026-10-04 and 2026-10-05,
  including `9fd4a4e`, which touched `ci.yml`*
  ([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable)). The arm64 dry run is still a
  TODO.
- **Open, for the stationary design:**
  - ⚠️ **The 🏠 stationary gate cannot pass yet.** `clock-preflight` is installed only by
    `20-portable-clock`, and the gate counts a preflight that is not installed as a hold, so a built
    stationary holds every update (`not_ready`, exit `4`) until a stationary clock step exists. It
    never applies on a first build, so a stationary can still be built. This belongs to the
    stationary design, with the recording lock versus the nightly update already recorded above.
  - 📋 **Open note, the Pi 5's own RTC:** see [§9l](#9l-rejected)'s rejection of an RTC on the
    stationary rig.
- 📋 **Deferred, decided and not built:**
  - **The install manifest.** `lib.sh`'s install helpers record every path, unit, sudoers and
    tmpfiles file they touch, per step and run; a rollback re-runs the applied steps and then acts
    on what the candidate touched and the applied tree did not, conservatively: units disabled,
    sudoers and tmpfiles entries removed, plain files deleted only under the repo's own install
    roots, everything else reported as leftovers. A CI grep stops steps installing outside the
    helpers. Before any 🏠 stationary deploy, and the pre-ship checklist's failing commit should then
    create something.
  - **`install_if_changed` moves into `lib.sh`.** It is defined again in steps 05, 10, 20, 30, 40,
    50 and 60, and it is where the manifest's recording goes. *Update 2026-10-10: and in step 70
    (`setup/steps/70-portable-home-update.sh`); step 06 installs its drop-in without it.*
  - **The repo's `new-step` skill is stale.** `.claude/skills/new-step/SKILL.md` still says *"Not
    an `install-all.sh`… The first build is by hand"*, which the one-command build supersedes. Not
    edited here.
  - **`10-decoder`'s `git_at_pin` fetches before it looks for the commit locally,** so a rollback
    with no network would fail there. It should check with `git cat-file -e` first.
- **What only the Pi can prove,** from the build's own lists of what it could not check:
  - every script as root on trixie, end to end: `curl | sudo bash`, the 5 s reboot, and the timer
    finishing a build after the boot;
  - the 🎒 portable Pi's first bootstrap changing nothing it installed by hand;
  - the real SIGTERM path under systemd, `flock -u` with inherited descriptors, and the journal
    priority prefix on the skip marker;
  - git's ownership check waived with `-c safe.directory` when root fetches from a login's
    checkout, and `git worktree prune` on the root-owned bare clone;
  - the banner under `pam_motd`, its timeouts, and the lock holder read from `/proc/<pid>/cgroup`;
  - `bootstrap.sh`'s lock verdict when the holder is the writer it started;
  - the format's tools on the Pi: `blkid -p` on a partition with no signature, the exFAT and NTFS
    probe mounts, `dumpe2fs` on a stick pulled without unmounting, `sfdisk` on a blank disk,
    `lsblk`'s `PARTN`, `SERIAL` and `PTUUID` on a USB stick, and the identity check after `sfdisk`;
  - the `config.txt` rename on FAT, and the firmware's reading of `[none]` and a bare `dtoverlay=`;
  - the pull window: `ExecStop=` on a normal stop, skipped at the cap; a running oneshot reading
    `activating`; the `--no-block` deadlock reasoning; and §9m's `Conflicts=` and `After=` ordering;
  - `sudo -l -U`'s output and exit codes, and the `!adsb-receiver` exclusion taking effect;
  - both `ExecStartPre=+` preflights passing under `NoNewPrivileges=yes`;
  - `tools/pull-archive` over a real link: `find -newermt` through the remote shell, a `.part`
    within 60 s, and ssh keepalives on a dropped link;
  - that rsync is missing from Raspberry Pi OS Lite, and Tailscale's JSON fields;
  - the step-2 success test above.

**Update 2026-10-04 (night), written 2026-10-05: the 🎒 portable updates itself at home, through a
home-gated window opener, at boot and daily. (Chris), 2026-10-04, about 20:55, option A.** ~~📋
**Ruled, not built.** Nothing of the opener exists in the tree: no unit, script, mode, key or field
below.~~ *Corrected 2026-10-09: built in `f411815`, with step 70's timer verify as ruled on
2026-10-09 in `eeaeffe`, `9a6c6d9` and `b7d2527`; `main` and `stable` are `b7d2527`, applied on the
🎒 portable on 2026-10-09 at about 20:13 Arizona time. What the build adds to the text below, and
the rulings of 2026-10-09, are in the blocks after it: "The opener, as built", the security ruling,
the timer verify's ruling, and the record on hardware.* Ruled by multiple-choice question, after a
check against the rulings already written and then an architecture consultation, whose design this
is.

- ⭐ **Chris's standing statement that drove it:** *"I want automated updates and I am ok with setup
  installs run by me (but not multiple commands - we have been using linux scripts for years to
  setup machines) and I understand if a major update requires me."* He named the gap that the review
  against his goals had missed: as ruled until then, the 🎒 portable had **no** automatic update
  path. The writer holds the lock whenever the rig is on, every timer run skips, and only a window
  started by hand updates.
- **The design.** An automatic update on a recording portable can only be an automatic *opening* of
  the window. So:
  - `adsb-home-update.timer`, 🎒 portable only: `OnBootSec=4min`, after the 3-minute timer's
    lock-held exit, plus one daily `OnCalendar=`.
  - It starts `adsb-home-update.service`, a oneshot: `After=network-online.target
    adsb-writer.service`, `ExecCondition=/usr/local/bin/adsb-at-home`, `TimeoutStartSec=55min`,
    `Nice=10`.
  - `bin/adsb-at-home` reads the active Wi-Fi SSID through `nmcli`, read-only
    ([§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away) bars writes, not
    reads), and compares it with an owner-set `update.home_ssid` in `station.yml`. **Unset means
    always off: the opener is opt-in.** It prints only "at home" or "not at home", ⛔ never the SSID
    (the ⛔ on echoing a config value, under `status.json` above).
  - Then `adsb-update --check`, a new mode: no lock, the fetch and the real resolver, and no
    `status.json` written. Exit `0` means an update is pending: ~~`main`~~ *`stable` (corrected
    2026-10-05, (Chris): both rigs follow `stable`, §9g's 2026-10-05 update)* is past `applied`, or the
    build is incomplete. *Extended 2026-10-05, (Chris), ~~📋 ruled, not built~~ built 2026-10-09 in
    `f411815`: the contract stands as
    written; for an incomplete first build `--check` also prints one reason line, which the
    opener's `ADSB-HOME-UPDATE` line carries; the line and why are at the end of
    [§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic).*
  - If one is pending, it drops a tmpfs marker, ~~`/run/adsb-receiver/window-opened-by`~~
    *`/run/adsb-home-update/window-opened-by` (corrected 2026-10-09, (Chris), by the security
    ruling after "The opener, as built" below)*; starts
    `adsb-pull-window.service`; waits for `adsb-update.service` to be dispatched and to finish; stops
    the window, whose `ExecStop=` wait applies as for any closer; and removes the marker.
  - ⚠️ **A required guard: a window already active means there is nothing to open.**
- **What does not change.** The writer still starts first at every boot (the ruling of about 20:45,
  at the end of [§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)). The window
  stops it afterward, which is the ruled way to end a session. `update.sh` still never stops the
  writer. The sudoers rule and the ⛔ on the monitoring login
  ([§9m](#9m--the-portable-rigs-archive-drive)) are untouched: a root timer is not Claude's login.
- **What it records.** `status.json`, written by `update.sh` only, gains `trigger: window` and
  `opened_by: adsb-home-update` or `hand`. The banner shows the opener's next fire and `opened_by`.
  One `ADSB-HOME-UPDATE` journal line per decision, with no SSID.
- **Field cost.** A true negative costs nothing: no Wi-Fi, a hotspot with another name, or Ethernet
  makes the condition false in milliseconds. A false positive, a hotspot named like home, costs one
  bounded loss, once, fixed by renaming the hotspot.
- **"A major update requires me" is ruled as exactly three things:**
  1. a reboot: `update.sh` never reboots, and the banner asks;
  2. anything only the bootstrap may do: the image, the format, the RTC overlay, and the §9h
     denylist (network, SSH, `/boot/firmware`, fstab);
  3. a hand after a rollback or a failed candidate: read the banner and push a fix; the rig retries
     daily after the 24 h backoff.

  A `readsb` rebuild at home is **not** major.
- Rejected:
  - **(B) The writer waits at boot, at home only:** Chris's sketch, made safe. It reverses the ruling
    of about 20:45; it puts recording behind a unit at every boot, the shape of the 2026-10-04 hub
    hang; it is worst on a false positive; and it runs at boot only.
  - **(C) Opening the window daily at home, with no `--check`.** A daily recording gap for nothing.
    It is the consultation's fallback if `--check` cannot reuse the resolver without the lock.
  - **(D) The workstation's cron running `tools/pull-archive`.** It ties updates to this PC being
    on; it is an unattended use of Chris's SSH key; data moves as a side effect; and it does nothing
    for the 🏠 stationary.
- **The 🏠 stationary.** The same opener shape is the starting point for its maintenance window,
  with no predicate: the trigger is the candidate changing after the soak, with the §9h gate open.
  It gets its **own** window unit, with no sudoers grant and a cap of minutes. It is to be designed
  in its own session, not pre-built.
- ➡️ **What would change it:**
  - `nmcli` cannot give the SSID on this image (→ the gateway's MAC address, still local).
    *Answered 2026-10-05: it can; see below;*
  - a false positive twice for one cause (→ the SSID and the gateway's MAC both, or drop the boot
    trigger);
  - `--check` cannot reuse the resolver without the lock (→ option C);
  - Chris rules an unattended rollback at home unacceptable (→ the install manifest first, and open
    the window only when the last result was not `rolled_back` or `failed`).
- ⚠️ **Unverifiable off the Pi:**
  - that NetworkManager is the stack, and what `nmcli` prints, on Pi OS Lite trixie. *Update
    2026-10-05:* ✅ read on the 🎒 portable Pi: `nmcli -t -f active,ssid dev wifi` prints the
    active SSID in its terse output, as one line beginning `yes:`, plus `no:` lines duplicated per
    band. ➡️ The predicate must take the `yes:` line; *Update 2026-10-09:* ✅ *the command the
    predicate runs, `nmcli -t -f active,ssid dev wifi list --rescan no`, gave exactly one `yes:`
    line on the 🎒 portable Pi (the record on hardware below);*
  - `ExecCondition=` on systemd 257. *Update 2026-10-05: the Pi runs systemd 257.13;
    ~~`ExecCondition=` on it is still unverified;~~* *Update 2026-10-09:* ✅ *seen on systemd
    257.13: `ExecCondition=` ran `adsb-at-home`, which said "at home", and the opener ran after it,
    on 2026-10-09 at 19:16 and on 2026-10-10 at 08:02 (the record on hardware below). The "not at
    home" and "off" exits skipping the run are not seen;*
  - whether `systemctl start` of the window returns before the update's job is dispatched;
  - the window's `Conflicts=` and `After=` ordering. *Update 2026-10-05: the writer's stop was seen
    before the update's start, at the end of §9e.*

**The opener, as built, 2026-10-09.** Built in `f411815`: step `70-portable-home-update`
(`setup/steps/70-portable-home-update.sh`), `bin/adsb-at-home`, `bin/adsb-home-update`,
`adsb-update --check`, `status.json`'s `trigger` and `opened_by`, and the banner's lines, including
§9e's (a). Step 70's timer verify was then rebuilt to the ruling below, in `eeaeffe`, `9a6c6d9` and
`b7d2527`. `main` and `stable` are both `b7d2527`. It was applied on the 🎒 portable on 2026-10-09
at about 20:13 Arizona time (the record on hardware below). What the build adds to the ruled text
above, from the code:

- **Its own step, portable only,** after `50-updater`, which installs `adsb-update` with `--check`,
  and `60-portable-pull`, which installs the window. The build's choice, not ruled.
- **The timer:** `OnBootSec=4min`, as ruled, and `OnCalendar=*-*-* 04:30:00`, in the rig's local
  time. ⚠️ **04:30 is the implementer's pick, not ruled.** No `Persistent=` and no
  `RandomizedDelaySec=`.
- **`adsb-update --check`** takes no lock and writes nothing: no `status.json`, no log directory,
  nothing under `/var/lib`, no apt heal. It fetches and runs the same resolver a timer run does,
  then prints one line on stdout, `pending: …` or `not pending: …`. Its exit codes:
  - `0`: pending;
  - `10`: not pending (the channel is unchanged, or its tip is under the soak);
  - `11`: not pending (the candidate failed within 24 h: the backoff);
  - `12`: not pending (the fetch failed);
  - `13`: not pending, because a timer run here would fail too, before any step: the rig needs a
    hand, and a window would change nothing;
  - `1`: could not tell (not root, a tool missing);
  - `64`: bad usage;
  - `128+N`: after a signal.

  An incomplete first build is always pending, with no fetch, and its line is §9e's (a) reason line.
  ⚠️ **The 24 h backoff inside `--check` is the implementer's reading of "pending", not ruled.**
  The reason given in `update.sh`'s header: without it, a window opened inside the backoff would
  run nothing, rejected option C's gap "for nothing".
- **`status.json`'s `trigger` and `opened_by`** are read once, when the run takes the lock. If
  `adsb-pull-window.service` is active, activating or deactivating, `trigger` is `window`, and
  `opened_by` is `adsb-home-update` when the opener's marker exists **and**
  `adsb-home-update.service` is activating, else `hand`. A marker left behind with no opener
  running is ignored. With no window, both are null: `mode` already says `timer`, `rev` or
  `bootstrap`, and a timer-mode run cannot tell the timer from `adsb-update` typed by hand. The
  implementer's choice, not ruled.
- **The banner's §9e (a) lines differ from the ruled text in two places,** both noted in
  `setup/files/motd-banner.sh`: the bootstrap line takes `--role` from `status.json`'s `role`, not
  from `station.yml`, because the banner runs as the login, which cannot read `station.yml` (a code
  review's finding, ⚠️ not seen on the Pi); and it prints BUILD.md §8's whole URL rather than
  "…/setup/bootstrap.sh", so the line can be copied (the implementer's reading, not ruled).

**The opener's runtime directory: a security finding and its ruling. (Chris), 2026-10-09, about
18:50.** `/security-review` of the opener, before it was pushed, found its root writes landing in
`/run/adsb-receiver`, which is owned by the writer's user, `adsb-receiver:adsb-operator 0755`
(✅ read on the Pi, below). A link planted there would let a compromised writer clobber any file as
root.

- **The ruling:** the opener's files move to a root-owned `/run/adsb-home-update`, made by its own
  tmpfiles.d file, `/etc/tmpfiles.d/adsb-home-update.conf`, `root:root 0755`. Both writers,
  `adsb-at-home` (its state file, for the banner) and `adsb-home-update` (its marker), refuse a
  directory that is not a real directory owned by root and writable by root alone, and never write
  through a link. Smoke cases SEC1 to SEC4 in `tests/smoke_update.sh` exercise it.
- *The build's choice, not ruled:* a tmpfiles.d entry rather than `RuntimeDirectory=`, because the
  directory must outlive each run of the oneshot: the banner reads the state between runs.
- 📋 **Reported by the same review, not fixed; open:**
  - `need_reboot` in `setup/lib.sh` appends to `/run/adsb-receiver/reboot-required` as root: a
    root write into the same writer-owned directory, the same link class. It predates the opener;
  - the login banner prints `reboot-required` and `status.json`'s lines raw, so a terminal escape
    in either reaches the login's terminal;
  - `update.sh`'s `prepare_config` echoes a malformed `--set` value in its error, and passes the
    `--set` values to `python3` in its arguments, where any process on the Pi can read them.

**Step 70's timer verify. (Chris), 2026-10-09, about 20:00.** Ruled by multiple-choice question, on
an architecture consultation's recommendation, after the third self-correction on this verify. It
answers the 19:16 rollback in the record below: the verify of `f411815` read the timer while the
timer's own install-time fire was running, and found no next elapse. ⚠️ That systemd shows no
realtime next elapse while a timer is `running` is a belief, not seen in `systemctl show`.

- **Starting the timer under `update.sh` stays**, as for `50-updater`'s timer.
- **One `systemctl show` snapshot of the timer, decided on `SubState`:**
  - `running` passes: the timer fired its service, and that run has not ended. One rule covers the
    install-time fire, a by-hand verify during a 04:30 run, and the home update that the opener
    itself is running;
  - `waiting` passes only with a realtime next elapse that `date -d` parses (not empty, `n/a`,
    `infinity` or `0`). Without one, the snapshot is read again, up to 5 reads, with `SubState`
    decided afresh at every read;
  - anything else fails.
- **Plus `systemd-analyze calendar`** on `DAILY_AT`, the one variable `render_timer` also uses,
  which must give a next elapse. Both checks run under `LC_ALL=C`.
- **No wait, and no marker carve-out.**
- *From the consultation, not the ruling's text:* the `running` pass is not
  [§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect)'s rejected "verify that passes
  with a warning when there is no fix". It passes on evidence of the fire, and names the one fact it
  did not read.
- Rejected:
  - **The 90 s wait and the marker carve-out of `0142623`.** It passes on a guess about whose run
    it is, and its wait kills a by-hand verify that lands in a `--check` phase.
  - **Gating on the service's state.** Weaker evidence than the timer's own.
  - **Starting the timer only at the next boot.** Days with no opener.
  - **Changing the unit's timing.** It moves the race.
- ➡️ **What would change it,** from the consultation's report:
  - a timer seen in `running` without having fired, such as a by-hand service start seen to put it
    there on systemd 257.13: then `running` is not proof of a fire, and that branch must also
    require `LastTriggerUSec` set and within this boot;
  - a home update after which the timer does not re-arm: then the re-arm is a real failure mode,
    and its observer moves to where it is observable, the banner's line and the opener's next run,
    or a check after `update.sh` releases the lock, not the step's verify;
  - `systemd-analyze calendar` absent or differently formatted on the Pi: then the `Next elapse:`
    line is accepted leniently, or the check is dropped and recorded as a belief; the verify does
    not die on tooling;
  - the install-time fire under a bootstrap's `update.sh` seen to do more than find the lock held
    (a `--check` fetch colliding with the bootstrap's, or a window opened): then the timer is
    started under `update.sh` only while the pull window is active, activating or deactivating,
    and only enabled otherwise;
  - a correctly armed timer seen `waiting` with no realtime next elapse for longer than the 5
    reads: then the bound is wrong, and the check becomes "realtime or monotonic set".
- ⚠️ **Beliefs it rests on, not seen on a Pi:**
  - a timer enters `running` only on its own elapse; a by-hand start of the service is believed to
    leave it `waiting`;
  - `NextElapseUSecRealtime` is empty while the timer is `running`.

✅ **Verified on hardware, 2026-10-09 and 2026-10-10: the opener on the 🎒 portable, `mobile-adsb`.**
Read on the Pi over SSH by Claude, or pasted by Chris; Arizona time, which is the Pi's.

- **2026-10-09, 19:16: `f411815` rolled back at step 70's verify.** Starting the timer under
  `update.sh` fired it at once: its `OnBootSec=` had long passed. The opener ran for about 1 s.
  `ExecCondition=` on systemd 257.13 ran `adsb-at-home`, which said "at home"; then the opener
  logged `ADSB-HOME-UPDATE window-active … nothing to open`, because the update's own window was
  open. The old verify's `list-timers` read, 273 ms later, showed NEXT `-`, mid-run. A minute later
  `systemctl show` gave `SubState=waiting`, next elapse 04:30. The rollback was ok. *Added
  2026-10-10:* the order, a fire at the timer's start and then a read 273 ms later, is consistent
  with the code: `update.sh`'s install pass runs each step without `--verify` (`run_one` adds it
  only in the verify phase), and step 70 run without `--verify` installs and then runs its own
  verify, so the timer's start and the verify's read of the timer both ran inside the install
  pass's one run of step 70. ⚠️ The order is from the reading at the time (commit `0142623`'s
  message), not re-verified: the 19:16 journal cannot be read again, because the Pi rebooted on
  2026-10-10 at 07:58 and its journal is volatile (below).
- **2026-10-09, about 20:13: the fourth pull applied `b7d2527`** (`result: applied`,
  `channel: stable`, exit `0`). Step 70's install was ok and its verify ok, every check `PASS`:
  the root-owned directory; the binaries; `--check` known to the installed updater; the units equal
  to their render; `systemd-analyze calendar` giving a next elapse at 04:30 MST; the timer
  `waiting` with a next elapse of Sat 04:30 MST; the predicate "at home". The writer was recording
  again.
- **Readings, 2026-10-09:**
  - `nmcli -t -f active,ssid dev wifi list --rescan no` gives exactly one `yes:` line;
  - the Pi's timezone is `America/Phoenix`;
  - `/run/adsb-receiver` is `adsb-receiver:adsb-operator 0755`;
  - `systemctl show` of a waiting timer gives `NextElapseUSecMonotonic=0` when there is no monotonic
    elapse;
  - `channel: stable` first appeared in `status.json` at the first applied run, because an
    unchanged run writes no `status.json`, by design (§9f's `status.json` bullet, its 2026-10-04
    "as built" correction).
- **2026-10-10, read over SSH by Claude:** the Pi booted at 07:58:16. `adsb-home-update.timer` fired
  at 08:02:17, boot plus 4 min 01 s, so `OnBootSec=4min` is seen. `adsb-at-home` printed "at home";
  the opener logged
  `ADSB-HOME-UPDATE not-pending: not pending: stable is still b7d252760b31, which is applied`; the
  service deactivated successfully. Next elapse: Sun 2026-10-11 04:30 MST.
- **2026-10-10, about 08:45: the opener's first automatic open, read over SSH by Claude.** CI
  advanced `stable` to `11cebb9` at 08:25; Chris then rebooted the 🎒 portable at home, and it
  booted at 08:41:05. `adsb-home-update.timer` fired at 08:45:01, and `adsb-at-home` printed "at
  home". `adsb-pull-window.service` started at 08:45:03, with `adsb-update.service` starting
  alongside it. At 08:45:43 the opener logged one line,
  `ADSB-HOME-UPDATE opened-applied: pending: stable's tip 11cebb9b3ae6 is the candidate; applied is b7d252760b31; adsb-update.service ran (40 s), exit 0, status.json: applied; the window is closed, and its end starts the writer`,
  and the service deactivated successfully. Afterwards `status.json` read `result: applied`,
  `channel: stable`, `trigger: window`, `opened_by: adsb-home-update` and `applied_rev`
  `11cebb9b3ae6…`; `applied` pointed at `worktrees/11cebb9b3ae6`; `readsb` and `adsb-writer` were
  active and `adsb-pull-window` inactive. Next elapse: Sun 2026-10-11 04:30 MST. The 08:02 run of
  the same day (above) was not pending; this is the first open.
- ⚠️ **The Pi's journal is volatile:** `journalctl --list-boots` shows only the current boot. So
  whether the 04:30 run of 2026-10-10 happened is **not verifiable**, and any later "did the opener
  run" check reads only the current boot. ~~A persistent journal is not built: it is the separate,
  later step under "Open, ruled to be decided later" above.~~ *Corrected 2026-10-10: a persistent
  journal is built, as step `06-journal`, ~~⚠️ not yet run on hardware, so the journal on the Pi is
  still volatile~~ ("A persistent journal, step `06-journal`", below).* *Corrected again
  2026-10-10: step 06's install and verify ran on the 🎒 portable under `update.sh` at about 10:12,
  and its verify read a token back from `/var/log/journal/<machine-id>/`. ~~⚠️ That the journal
  survives a reboot is not yet seen.~~ Corrected 2026-10-10: after Chris rebooted it at about 11:14,
  `journalctl --list-boots` shows two boots, and the earlier boot reads back ("✅ A second reboot",
  below).*
- ⚠️ ~~**No automatic open has happened yet:** nothing has been pending. The open path, the window's
  start, a new `InvocationID` on `adsb-update.service`, then the outcome, is still a belief, as is
  `ExecMainStatus` holding the oneshot's exit code.~~ *Corrected 2026-10-10: the first automatic
  open happened at 08:45 (the 08:45 bullet above). Seen: the open path itself, the window's start, a new
  `InvocationID` on `adsb-update.service`, then the outcome; `ExecMainStatus` holding the oneshot's
  exit code, read as `0` beside `status.json`'s `applied` (a non-zero exit has not been read
  through it); and the window's close starting the writer. ⚠️ Still not seen: whether the
  opener's dispatch wait broke on its first poll, which is not logged; the opener's "not at home"
  and "off" exits; its close's `124` path (~~`bin/adsb-home-update:159`~~ `bin/adsb-home-update:170`, the window's stop not
  finished in 120 s); and a timer entering `running` on a by-hand start of its service.*

**A persistent journal, step `06-journal`. (Chris), 2026-10-10, in ~~two~~ *three* rulings.** It closes the
"Open, ruled to be decided later" item above that put the persistent journal later. Built in
`787fd06`, `cc26f27`, `5f4a077` and `77e7282` (`setup/steps/06-journal.sh`). ~~⚠️ **Not yet run on
hardware.**~~ *Corrected 2026-10-10: install and verify ran on the 🎒 portable under `update.sh`, in
the pull window at about 10:12 (the "✅ Run on hardware" block below). ~~⚠️ That the journal survives
a reboot is not yet seen.~~ Corrected 2026-10-10: it survived a reboot at about 11:14 ("✅ A second
reboot", below).*

- **About 08:50: a persistent journal on both rigs, built right after step 5, as a shared step
  06.** The reason given: the "logs reset every day" observation was in fact every reboot.
  Raspberry Pi OS ships `/usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf`
  (`Storage=volatile`; ✅ read on the 🎒 portable, below). On the remote 🏠 stationary a watchdog
  reboot would erase its own cause; on the 🎒 portable, whether a timer run happened before the last boot cannot be read. The 04:30 run
  of 2026-10-10 is unverifiable for this reason (the record on hardware above).
- **About 10:00, by multiple-choice question: journald is restarted only under `update.sh`** (with
  `ADSB_UPDATE_RUN` set), which holds the recording lock, following the precedent of `50-updater`
  and `70-portable-home-update`, which start their timers only there. Run by hand, the step installs
  and warns, and its verify passes on the configuration, with a warning, while journald is not yet
  writing to `/var`. The reason, as the question stated it for this option: a restart by hand on a
  recording 🎒 portable could drop the writer's stdout stream, which nobody has seen survive; and
  `50-updater` and `70-portable-home-update` already do it this way. Chris gave no reason beyond
  choosing it.
  - Not taken, the question's two other options:
    - **"Refuse while recording":** run by hand, restart journald only if no recording session
      holds the lock; otherwise warn that the drop-in loads at the next boot.
    - **"Leave as built":** always restart; run by hand, the restart is Chris's own choice, and the
      warning reports it.
- **~~About 11:00~~ *about 10:35*, by multiple-choice question, on an architecture consultation's recommendation:
  the stream check is dropped** (option B). *Corrected 2026-10-10: the time. The consultation's
  report closed at about 10:31, the ruling came after it, and the commits that carry it, `b91e874`
  and `398ad28`, were made at 10:44, so 11:00 is impossible.* The step keeps journald's `NFileDescriptorStore` before
  and after the restart, printed and not judged, and `readsb`'s and `adsb-writer`'s `InvocationID`
  and `NRestarts` before and after, warned. How it came to a question: the check that paired each
  unit's fd 1 with journald through `ss -xpn` warned falsely on its first run on hardware, because
  the Pi's kernel has no unix_diag (the "✅ Run on hardware" block below). It was then replaced, on
  the same branch, never shipped, by a check of journald's per-stream state files
  (`UNIT=<unit>` in `/run/systemd/journal/streams/`, tied to journald's open sockets, against a
  baseline taken before the restart). That took three rewrites in a row, and Chris asked for the
  consultation.
  - The reasoning, the consultation's; ✅ marks what Claude checked:
    - The restart runs only under `update.sh`, which refuses to run while the writer holds the
      recording lock (✅ read in `setup/update.sh`: `take_lock`, :459–468, takes it with `flock -n`;
      a timer run that finds it held exits 0, a run by hand exits `RC_FAILED`, with
      `lock_held_by_hand`'s message at :485–503), so the writer is never recording across it. Its
      unit has `IgnoreSIGPIPE=yes` (✅ seen on the 🎒 portable), so if its stream did break, the
      Python writer would get `EPIPE` on its next write to stderr, exit, and be restarted, which the
      `InvocationID` and `NRestarts` check reports. ⚠️ Belief, not seen, and not certain on every
      path: the writer's `log()` in `bin/adsb-writer` is `print(..., file=sys.stderr, flush=True)`,
      but some of its calls sit in `try` blocks with `except OSError`, and there are catch-alls
      (`except Exception`, in `start_probes` and at the end of `main`), so an `EPIPE` could be caught
      instead of ending the process.
    - ⚠️ **The residual, not detected by the step:** `readsb` (C) would lose its journal lines
      silently until its next restart. By the code's order (`update.sh`'s `step_list` takes the
      steps in file-name order; §9b: `06-journal` runs before `10-decoder`), it arises only on a rig
      whose `readsb` was running when the drop-in first landed, the 🎒 portable's case, already
      observed (the "✅ Run on hardware" block below), or at a later restart with `readsb` running:
      a change to the drop-in, a journald that looks older than it, or journald with no file open
      under `/var` (a later boot whose flush failed; from the step's restart decision,
      `journald_on_var`, not seen).
    - The restart happens about once per rig (the drop-in changed, journald not on `/var`, or
      journald older than the drop-in), so a check for it cannot be validated on a rig before its
      one real run. The stream files are systemd's private format ("This is private data. Do not
      parse"), read here only through the strings of a systemd 259 binary, while the rigs run 257.
    - [§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect): a verification that happens
      once per rig is a hardware observation recorded in the docs, not a script. What is owed is
      the standing item "📋 Owed, standing" below.
  - Rejected:
    - **A: finish the stream-file check.** It still rests on the private format, and a format
      mismatch would be a permanent false warning, the pattern the `ss` form already produced.
    - **C1: a probe of liveness after the restart.** There is no write the step can cause in
      `readsb`; it would need a change to `readsb`. ⚠️ A belief.
    - **C2: the whole set of socket inodes, compared and printed.** Nothing pairs it to a unit
      without unix_diag.
    - **C3: restart `readsb` after journald's restart.** It replaces an observation with an
      intervention on a mechanism seen to work once, and costs `readsb` its stick for seconds.
      ➡️ **Kept as the fallback, a ruling in waiting:** it is the answer if a dropped stream is
      ever seen.
    - **Keeping the check, log-only.** Maintenance with no warning.
  - ➡️ **What would change it:**
    - a dropped `readsb` stream seen on either rig: then C3;
    - a lock design in which the writer records across `update.sh`: then journald must not be
      restarted while the writer holds the lock;
    - a Pi kernel with `CONFIG_UNIX_DIAG`: then the pairing through `ss` could return cheaply.
- **As built,** from `setup/steps/06-journal.sh`:
  - **The drop-in,** `/etc/systemd/journald.conf.d/60-adsb-receiver-persistent.conf`,
    `root:root 0644`: `Storage=persistent` and `SystemMaxUse=200M`. `60-` sorts after the vendor's
    `40-`, and journald.conf(5) gives the drop-in sorted last the last word. `SystemKeepFree=` is
    left at its default.
  - **`systemd-tmpfiles --create --prefix /var/log/journal`,** systemd's own rules for the
    directory's owner, mode and ACLs. A failure warns.
  - **Before any restart,** the last word on `Storage=` in `systemd-analyze cat-config` must be
    `persistent`; a later-sorted drop-in that overrides ours fails the step.
  - **The restart decision, under `update.sh` only.** journald is restarted when this run changed
    the drop-in, or the running journald has no file open under `/var/log/journal/<machine-id>/`
    (read from its `/proc/<pid>/fd`), or journald's `ExecMainStartTimestamp` (read with `busctl`, in
    µs) is older than the drop-in's mtime. Then `journalctl --flush`, bounded at 30 s. A run on a rig
    whose journald is already on `/var` with the current drop-in loaded restarts nothing.
  - **~~Three~~ *Two* stream checks around the restart,** for `readsb` and `adsb-writer`, each only where the
    unit was active before it: journald's `NFileDescriptorStore` before and after, printed and not
    judged; ~~each unit's fd 1 held by the new journald, read from `ss -xpn`;~~ and each unit's
    `InvocationID` and `NRestarts`, before and after. ~~All three warn and never die.~~
    *Corrected 2026-10-10: the store's count is printed, not judged; a changed `InvocationID` or
    `NRestarts` is warned; neither dies. The `ss -xpn` check is removed by the ~~11:00~~ 10:35 ruling
    above (time corrected 2026-10-10). It
    warned falsely on its first run, because `ss` sees no unix peers on the Pi's kernel (the "✅ Run
    on hardware" block below), and the stream-file check that replaced it, on the same branch, was
    never shipped. In the step, `fd_store` reads the store and `unit_mark` the two values, compared in
    `check_streams`.* The reasons, in
    the code: [§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect)'s rule that a check may
    never end a recording session; a die under `update.sh` rolls back, and the rollback cannot undo a
    session already ended; and the restart repeats on every run while its cause holds, so a die would
    turn one gap into failed updates. They run before a failed flush's die, since journald has been
    restarted either way.
  - **The verify:** the drop-in matches its render; `cat-config`'s last word on `Storage=` and
    `SystemMaxUse=` is ours; the machine directory is `root:systemd-journal` with the setgid bit;
    and a token logged now is read back from `/var/log/journal/<machine-id>/`. ⛔ No check across
    boots: that the journal survives a reboot is a hardware observation.
  - **A rollback** by `update.sh` to a tree without step 06 leaves the drop-in in place, and names
    the step in `status.json`'s `rollback.leftovers_possible`. The journal stays persistent until
    the drop-in is removed by hand.
- ✅ **Read on the 🎒 portable, `mobile-adsb`, over SSH by Claude, 2026-10-10:**
  - `/usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf` holds `[Journal]` and
    `Storage=volatile` (read at about 10:03);
  - journald's descriptor store is configured: `FileDescriptorStoreMax=4224`,
    `FileDescriptorStorePreserve=yes`, `NFileDescriptorStore=16` (*added 2026-10-10:* read earlier
    that day, before step 06 ran; the run read 17 before its restart and 17 after, so the count
    varies and is not a constant);
  - `systemd-journal-flush.service` requires only `-.mount` and `system.slice`;
  - the tmpfiles rule for `/var/log/journal/%m` is `2755 root systemd-journal`, plus `adm` ACLs;
  - `ss` is `/usr/bin/ss`, and `busctl` is `/usr/bin/busctl`; `busctl` gives
    `ExecMainStartTimestamp` as `t <µs>`, which matched the start the monotonic clock implies to
    within milliseconds (the portable has an RTC, so no clock step before journald); coreutils is
    9.7, and `stat -c %.6Y` gives microseconds;
  - the journal holds no raw GPS position: the NMEA lines carry `<lat>` and `<lon>` placeholders
    (counted, never printed).
- ✅ **Run on hardware: the 🎒 portable, `mobile-adsb`, 2026-10-10, about 10:12 to 10:13, seen by
  Claude over SSH.**
  - `tools/pull-archive` opened the pull window, and the window's update applied `5428470`
    (`stable`): `trigger: window`, `opened_by: hand`, `result: applied`, exit 0. Every step's
    install and verify were ok; `06-journal` took 7 s. The window stopped the writer, and it
    recorded again from 10:13:28. The version that ran had the `ss -xpn` stream check.
  - Step 06's log: the drop-in changed, and was installed by rename; tmpfiles ran; `readsb`'s
    `InvocationID` and `NRestarts` were recorded; `systemctl restart systemd-journald`; `timeout 30
    journalctl --flush` returned. `NFileDescriptorStore` was 17 before the restart and 17 after the
    flush. `readsb`'s `InvocationID` and `NRestarts` were unchanged afterwards.
  - The verify: the drop-in matches its render; `cat-config`'s last word is `Storage=persistent`
    and `SystemMaxUse=200M`; `/var/log/journal/<machine-id>` is `root:systemd-journal 2755`; the
    token was read back from disk; `journalctl --disk-usage` gave 16M.
  - ⚠️ **The `ss` stream check warned for `readsb`** ("no journald end … ss: (no line)"). The cause,
    seen: the kernel, `6.18.50+rpt-rpi-v8`, has `# CONFIG_UNIX_DIAG is not set`, so `ss` reads
    `/proc/net/unix`, which carries no peers: every one of the 106 unix sockets showed peer 0. The
    warning was the check's, not a dropped stream.
  - The streams, seen, not as root *(added 2026-10-10: read by Claude over SSH at about 10:30,
    after the run, not within the 10:12 to 10:13 of this block's heading)*: after the restart, the inodes of the sockets bound to
    `/run/systemd/journal/stdout` (journald's ends) equal, 16 of 16, the inode parts of the file
    names in `/run/systemd/journal/streams/` (`9:<ino>`). Sockets created at boot (08:41; 345, 10330
    and 10343, for example) are still among them after the restart at about 10:12. Two stream files
    have an mtime of 08:41:17, which is `readsb`'s `ExecMainStartTimestamp`. ⚠️ **Not seen:** the
    files' contents, which are root-only, so which unit owns them is inferred from the mtime alone;
    and `readsb`'s output after the restart, since it has logged nothing since 08:41:58.
  - Also seen: `readsb` and `adsb-writer` both have `StandardOutput=journal`,
    `StandardError=inherit` and `IgnoreSIGPIPE=yes`; `readsb` has `Restart=always`, the writer
    `Restart=on-failure`; the writer has two `ExecStartPre=+` preflights.
  - ⚠️ ~~**Not yet seen: a second reboot,** for `journalctl --list-boots` to show two boots or more.
    That is the remaining hardware observation for persistence itself (in
    [§9m](#9m--the-portable-rigs-archive-drive)'s pre-field checklist).~~ *Corrected 2026-10-10:
    seen, at about 11:14; see "✅ A second reboot" right below.*
- ✅ **A second reboot: the 🎒 portable, `mobile-adsb`, 2026-10-10, rebooted by Chris at home at
  about 11:14, read by Claude over SSH, read-only, as a login in group `adm`.** *Added 2026-10-10.*
  - `uptime -s`: 11:14:20.
  - `journalctl --list-boots` shows two boots: `-1`, `3ab92481…`, from 08:41:05 to 11:14:10, its
    last entry the shutdown's (`systemd-shutdown`, "Journal stopped"); and `0`, `193ee80b…`, from
    11:14:26. `journalctl -b -1` reads back, 5,366 lines. Its first entry is that boot's start,
    08:41:05, so what journald held in `/run` before step 06's flush at about 10:12 to 10:13 was
    carried to disk by that flush.
  - Step 06's own verify tokens (tag `adsb-06-journal`) from the run before the reboot, logged at
    10:12:40 and 10:13:03, were still on disk after it, beside this run's of 11:18:27 and 11:18:43:
    direct evidence that the journal survives a reboot.
  - The opener opened the window by itself: `adsb-home-update.timer` fired at 11:18:20.
    `status.json` then read `trigger: window`, `opened_by: adsb-home-update`, started 11:18:25,
    finished 11:19:03, `result: applied`, exit 0, `applied_rev` `398ad28`, `failed_steps: []`,
    `rollback: null`; all ten steps' install and verify ok; `06-journal` took 3 s.
  - Step 06's log (run directory `20261010T181826Z`): the drop-in "is unchanged"; tmpfiles ran;
    "journald (PID 293) has a file open under /var/log/journal/<machine-id>/, started after the
    drop-in was written, and the drop-in is unchanged; not restarted". Every verify check passed:
    the drop-in matches its render; `cat-config`'s last word is `Storage=persistent` and
    `SystemMaxUse=200M`; the machine directory is `root:systemd-journal 2755`; the token was read
    back from disk. `journalctl --disk-usage` gave 20.7M.
  - Afterwards `readsb` and `adsb-writer` were active; `readsb` had `NRestarts=0` and
    `ActiveEnterTimestamp` 11:14:38.
  - So journald was not restarted on this run, and no stream observation was owed by it (the
    "📋 Owed, standing" item below). The belief that a restart keeps the streams is not touched by
    this run.
- 📋 **Owed, standing: the stream observation, by hand, whenever step 06's restart runs on a rig
  where `readsb` is already running.** *Added 2026-10-10,* by the ~~11:00~~ *10:35 (time corrected
  2026-10-10)* ruling above.
  - On a first build, `06-journal` restarts journald before `10-decoder` and `40-archive-writer`
    install (`update.sh`'s `step_list` takes the steps in file-name order; §9b). So no stream unit
    is running and nothing can be dropped: `readsb` is started by `10-decoder` afterwards, and the
    writer once the run ends, both on streams to the new journald. ➡️ The 🏠 stationary owes no
    stream observation at its first build.
  - After the 🎒 portable's first application (done, 2026-10-10, above), such a restart comes only
    from a later change to the drop-in, a journald that looks older than it, or journald with no
    file open under `/var` (a later boot whose flush failed; from the step's restart decision,
    `journald_on_var`, not seen).
  - The observation: before and after journald's restart, record
    `systemctl show -p NFileDescriptorStore systemd-journald`; `readsb`'s and the writer's
    `InvocationID` and `NRestarts`; the set of `/run/systemd/journal/stdout` socket inodes from
    `ss -xn`, and the file names in `/run/systemd/journal/streams/`; and, as root, the `UNIT=` lines
    of the stream files. Paste the output into the rig's build record.
- ⚠️ **Beliefs it rests on, not seen:**
  - that a journald restart keeps the services' stdout streams. systemd-journald(8) says so, and
    the store is configured, ~~but no restart has been seen~~ *corrected 2026-10-10: and one restart
    has been seen, on the 🎒 portable at about 10:12 (the "✅ Run on hardware" block above).
    journald's ends of the stdout sockets match the stream files 16 of 16 after it, sockets from
    boot among them, and two files carry `readsb`'s start time as their mtime. ⚠️ Still a belief for
    `readsb` itself: the files' contents were not read, and it has logged nothing since, so its
    output after the restart is not seen*;
  - that on systemd 257 journald re-reads its configuration only on a restart (a reload by SIGHUP
    arrives in 258), and that after the restart a `journalctl --flush` is needed to move to `/var`:
    the implementer's reading of the v257 source and the man pages;
  - that the flush finishes within its bound on the Pi, ~~and that `ss -xpn` run as root shows
    journald's PID in the columns the check reads~~ *corrected 2026-10-10: the flush returned
    within its 30 s bound on the 🎒 portable (the whole step took 7 s). The `ss -xpn` belief is
    moot: `ss` sees no unix peers on the Pi's kernel, and the check that rested on it is removed (the
    ~~11:00~~ 10:35 ruling above; time corrected 2026-10-10)*;
  - the 🏠 stationary's clock. It is not built, and may have no RTC: then fake-hwclock can make
    journald look older than the drop-in, which costs one extra restart under the lock and corrects
    itself;
  - ~~all of step 06: it has not run on hardware.~~ *Corrected 2026-10-10: install and verify ran
    on the 🎒 portable under `update.sh` (above). Still not seen: ~~the journal surviving a reboot,
    and~~ any run on the 🏠 stationary. Corrected 2026-10-10: the journal surviving a reboot is seen,
    on the 🎒 portable at about 11:14 ("✅ A second reboot", above).*

### 9g. Channels: portable tracks `main`, stationary tracks `stable`

*Corrected 2026-10-05, (Chris): the heading's "portable tracks `main`" is superseded. Both rigs
follow `stable`, and the soak is the only role difference; see the 2026-10-05 update below the
emergency brake. ~~📋 Ruled, not built.~~ The heading is kept as written because other sections link to
its anchor.* *Corrected 2026-10-05: built in `94e4f94`, ~~⚠️ not yet run on a Pi~~.* *Corrected
2026-10-10: the 🎒 portable is seen following `stable`; see "As built" at the end of the 2026-10-05
update below.*

- 🎒 ~~**The portable rig tracks `main`.**~~ *Superseded 2026-10-05, (Chris): the 🎒 portable
  follows `stable` too, with no soak (the 2026-10-05 update below). This bullet carried no reason,
  and none was found.*
- 🏠 **The stationary rig tracks a `stable` branch** that GitHub Actions fast-forwards when CI is
  green. CI runs `shellcheck`, `bash -n`, a dry run of every step in an arm64 trixie container
  against sample-filled templates (including the role-refusal paths), and a grep for the denylist in
  [§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away).
  - *Update 2026-10-05, (Chris): both rigs follow this `stable` branch now (the 2026-10-05 update
    below). ⚠️ The arm64 dry run named here is still not built (`ci.yml`'s TODO,
    [§9k](#9k-the-first-deliverable-in-order) item 3), so it is what both rigs' channel lacks, not
    the stationary's alone, which makes it more load-bearing.*
- ⭐ **The workflow's `GITHUB_TOKEN` is the only write credential, and it lives in GitHub, not on a
  device.** That keeps [§9a](#9a-the-repo-ships-its-own-software-and-the-pi-pulls-it)'s
  no-credential-on-the-Pi property intact.
  - *Update 2026-10-04 (evening), (Chris): the `advance-stable` job is built, fast-forward only,
    with `GITHUB_TOKEN`. ⚠️ Unknown until its first run: whether GitHub refuses a `GITHUB_TOKEN` push
    of commits that touch `.github/workflows/`. The documentation does not say for a fast-forward to
    existing commits, and the workflow's `permissions:` cannot grant it. If it is refused, the
    fallback is a fine-grained personal access token (Contents: write, Workflows: write) stored as a
    repository secret, which keeps the only write credential in GitHub. Not added now.*
  - *Update 2026-10-05: ✅ no longer unknown; GitHub did not refuse. Checked by the coordinating
    session on GitHub on 2026-10-05 (`gh run watch`, `git ls-remote`): `advance-stable` ran with
    `GITHUB_TOKEN` alone on every push to `main` on 2026-10-04 (`d2c8f91` and the commits before
    it, one of which, `9fd4a4e`, touched `ci.yml`) and on 2026-10-05 (`c35a29c`, `e019b29`,
    `42b5115`, `1d5f631`, `d36fee6`), each time fast-forwarding `stable` within about three minutes.
    The personal-access-token fallback is not needed.*
- 🏠 The stationary rig also only takes commits older than `update.soak_days` (7 days).
  - ~~"Commits older than"~~ *Superseded 2026-10-04 (evening), (Chris): the stationary takes
    **`stable`'s tip, and only once the tip is at least `update.soak_days` old**; otherwise it waits.
    Never "the newest commit older than `update.soak_days`", which the first build of `update.sh`
    did: under that rule a bad commit becomes the candidate on the day it turns old, whatever younger
    revert followed it. Under the tip rule, any push to `main` resets the stationary's clock, and a
    bad commit is never applied alone. The cost, stated plainly: the stationary updates only after
    `update.soak_days` quiet days on `stable`, so a busy week means no stationary update that week.
    That is what a soak means, and it gives the brake below for free. Built, not yet run on
    hardware.*

🔑 **The gate is CI, the rig's own verify, and rollback.** ⚠️ **The portable rig is an opportunistic
canary, not a gate.** It is often powered off for weeks, so a bad commit may reach `stable` before
the portable has ever run it.
*Restated 2026-10-05, (Chris): the 🎒 portable is an opportunistic canary for `stable`, running
`stable`'s tip up to `update.soak_days` ahead of the 🏠 stationary. It is still not a gate.*

➡️ **Emergency brake:** ~~force-push a known-good SHA to `stable`.~~ *Superseded 2026-10-04
(evening), (Chris): **a revert commit on `main`.** It is forward-only and CI-tested, reaches `stable`
through the same job as any commit, and the rig applies it as a candidate, the mechanism it already
has. Under the tip-aged soak above, the young revert holds the stationary until the revert and the
bad commit have aged together. A force-push of `stable` to an older commit stays only as a
documented last resort, and **it holds only until the next green push to `main`**, which the job
fast-forwards: nothing on `main` says "held", so the job is right to follow the chain again.*
- *Rejected: a `stable-hold` branch or ref that the job honors, which is a second truth; a chain
  rule, `stable` must equal the push's `before`, which turns every red CI run on `main` into a silent,
  permanent hold; and leaving the force-push as the brake with its limit documented. ➡️ What would
  change it: a need to hold `stable` without touching `main` for longer than `update.soak_days`;
  then a `stable-hold` ref, accepted as a second truth.*
- *Restated 2026-10-05, (Chris), now that both rigs follow `stable` (the update below). ~~📋 Ruled, not
  built.~~ Corrected 2026-10-05: both rigs follow `stable` as built in `94e4f94`, ~~⚠️ not yet run on
  a Pi~~. Corrected 2026-10-10: the 🎒 portable is seen following it (the "As built" below).* A revert on `main` reaches `stable` through the job. The 🎒 portable takes it on its next
  pull; the 🏠 stationary once the revert and the bad commit have aged together. ⚠️ **The force-push
  last resort now holds both rigs** until the next green push to `main`; during a hold the portable
  runs a fix by `--rev`. A hand fast-forward of `stable`, `git push origin main:stable`, is not a
  brake, and is permitted: it is what the job does, for an Actions outage or an unparseable
  `ci.yml`.

**Update 2026-10-05: both rigs follow `stable`, and the soak is the only role difference. (Chris),
2026-10-05, about 21:50.** ~~📋 **Ruled, not built.** Nothing below is in the tree yet: `update.sh`'s
`channel_of` and `bootstrap.sh`'s `--role` case still give the 🎒 portable `main` (read 2026-10-05).~~
*Corrected 2026-10-05: built in `94e4f94`, ~~⚠️ not yet run on a Pi~~; see "As built" at the end of this
update.* *Corrected 2026-10-10: the `update.sh` half is seen on the 🎒 portable; the bootstrap's half
has not run since; both in "As built".*
Ruled by multiple-choice question, after a check against the rulings already written and then an
architecture consultation, whose mechanism this is. Chris's question that opened it: *"should we be
using stable build points instead of main to determine where to pull the latest code from?"*

- **The ruling.** Both rigs follow `stable`. The soak is the only role difference, as a role default
  inside `update.sh`: 🎒 portable 0 days, 🏠 stationary 7. `update.soak_days` overrides it where a
  `station.yml` carries the key; the portable template still never carries it (the ⛔ in the
  consequences table at the end of this file).
- **A soak of 0 means no age check at all,** not "aged at least zero seconds". The guard exists
  because an age of at least zero would depend on the Pi's clock being past the commit date. Today's
  `resolve_candidate` tests `age >= days * 86400`, with `age` the Pi's `date +%s` less the tip's
  commit date (read 2026-10-05).
- **Why.**
  - CI tests what hardware cannot change: `bash -n`, `shellcheck`, the Python unit tests, the
    denylist and disk-command greps, path consistency, the `--verify` and `require_role` shape,
    anchors, and the sandbox smoke of `update.sh` and `bootstrap.sh`. So a red commit on the Pi
    yields no information the red check did not.
  - Today a red commit on the 🎒 portable costs a `readsb` rebuild on a CPU-bound Pi, a rollback that
    does not undo creation ([§9f](#9f-what-updatesh-does)), a 24 h backoff, and a banner asking for
    a hand. Under the home-gated opener ([§9f](#9f-what-updatesh-does), its end) it would also cost a
    recording gap at home: `--check` opens the window for a tip that then rolls back. Comparing
    against `stable` makes that gap impossible.
  - The pinned first build gets the same protection: a `curl | bash` run while CI is still running
    builds the last green commit, not an unverified tip. On 2026-10-05 that held only because Chris
    waited.
  - **R5 ([§9m](#9m--the-portable-rigs-archive-drive)) does not bind the portable to `main`.** It
    binds a commit to its Pi run, which `--rev` (any pushed branch) or a checkout bootstrap before
    the push satisfies. The channel pull is the second run of the same commit, delayed by CI's
    minutes.
  - **This, variant B, over variant A (below):** the role becomes one number instead of two code
    paths. Today `channel_of`, the portable branch and the stationary soak make the role matter in
    three places in one function, `resolve_candidate`.
- Rejected:
  - **Staying on `main`.** The canary's extra runs are of commits that never reach `stable`, each
    costing a rebuild and a partial rollback, and under the opener a recording gap. The §9g bullet
    above carried no reason, and none is found.
  - **Variant A: `stable`, with a separate no-soak branch for the portable.** A second resolver path
    to drift; and [§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)'s rejection
    of "the channel from the role only" already refused a role special case.
  - **`update.soak_days: 0` in the portable template.** It breaks the consequences table's ⛔.
  - **A per-role channel flag in the bootstrap or `station.yml`.** A second truth; this section's
    brake ruling refused a `stable-hold` for less.
  - **Gating `stable` on the portable's run.** The portable is off for weeks; it would freeze the
    stationary.
- 📋 **What changes, named, ~~not implemented~~:** *Corrected 2026-10-05: implemented in `94e4f94`;
  see "As built" at the end of this update.*
  - `setup/update.sh`: `channel_of` returns `stable` for both roles, or goes; the portable branch in
    `resolve_candidate` is deleted; `DEFAULT_SOAK_DAYS` becomes a role default (portable 0,
    stationary 7); a soak of 0 short-circuits the age check; the header's and `NOTE`'s
    wording; the "clone has no origin/stable" failure now applies to both roles; the two messages
    that say "on a stationary it builds stable's tip without the soak" drop "on a stationary".
  - `setup/bootstrap.sh`: `channel=stable` for both roles; the header says both roles build
    `stable`'s tip, the first build without the soak on either; the checkout path's "not on
    origin/$channel" warning adds that CI may still be running.
  - `tests/smoke_update.sh`: case P expects "not on origin/stable"; a new case: a portable with a
    soak of 0 takes `stable`'s tip when the clock is behind the commit date.
  - `.github/workflows/ci.yml`, comments only: "both rigs"; the TODO's arm64 dry run is now what
    both rigs' channel lacks; and the `GITHUB_TOKEN` push of commits touching `.github/workflows/`
    is no longer unknown: it worked on 2026-10-04 and 2026-10-05. *Answered 2026-10-05, in
    `94e4f94`: `ci.yml`'s comments now say all three.*
  - `status.json`'s `channel` field, seen as `main` on the 🎒 portable on 2026-10-05, reads `stable`
    on both roles; the banner and `--check` read it.
- **The costs, stated plainly:**
  - a `curl | bash` within about three minutes of a push builds the previous green commit. The
    bootstrap prints the SHA it builds; the checkout path builds a chosen `HEAD`;
  - an Actions outage, or an unparseable `ci.yml`, freezes both rigs' channel. The escape is the
    hand fast-forward above, or `--rev`;
  - a red push is seen on GitHub only.
- ➡️ **What would change it:**
  - a second commit CI rejects but the Pi needs (a check wrong about hardware). Twice is evidence the
    gate is in the wrong place, and the portable goes back to `main` until it is fixed;
  - a need to hold `stable` while the portable keeps moving: then the `stable-hold` ref this section
    already names;
  - the previous-green trap biting more than once at the bench: then a `--channel main` escape on
    the bootstrap, named as the unverified-tip case;
  - Actions outages freezing both rigs more than once: then a wrapper for the hand fast-forward, in
    `tools/`.
- ⚠️ **Not verified (the consultation's):** whether the Pi's clock can in practice be behind a commit
  date; the full list of smoke cases.
- **As built, 2026-10-05, in `94e4f94`** on `main`, pushed about 21:55 Arizona time; ~~CI pending when
  this was written~~ *corrected 2026-10-05: ✅ CI green (scripts, smoke and `advance-stable` all
  succeeded; `stable` is `94e4f94`), seen on GitHub by the coordinating session at about 22:00
  Arizona time*. ⚠️ ~~**Not yet run on a Pi.**~~ *Corrected 2026-10-10: the `update.sh` half has
  run on the 🎒 portable. Its `status.json` read `channel: stable` on 2026-10-09 and 2026-10-10
  (§9f's records on hardware), and it applied `5428470` and `398ad28` from `stable` on 2026-10-10.
  It applied `398ad28` at 11:18, about half an hour after the commit at 10:44, which a soak of a day
  or more would have held back: the portable's soak of 0 is seen in effect. Not run: the 🏠
  stationary's soak of 7 (no stationary is built), and the bootstrap's half, the `curl` URL and
  `bootstrap.sh`'s `channel=stable` (no bootstrap is recorded since this commit; `bootstrap.sh`'s
  header lists runs on 2026-10-04 and 2026-10-05, the second at `e019b29`, before it).* From `setup/update.sh` and `setup/bootstrap.sh`:
  - `channel_of` returns `stable` for both roles.
  - The role default is `SOAK_DAYS_PORTABLE=0` and `SOAK_DAYS_STATIONARY=7`; `update.soak_days`
    in `station.yml` overrides it.
  - A rejected value falls back to the role default, and the log says the file's value was
    rejected.
  - The value is read in base 10. ⚠️ `08` and `09` were bad octal to bash arithmetic: the
    comparison failed silently, and the rig never updated.
  - A soak of 0 short-circuits before any date is read.
  - The bootstrap builds `stable`'s tip for both roles.
  - Smoke cases Z (a portable, soak 0, takes a tip dated two days ahead of the clock) and Y1 to Y4
    (the override, both ways; a rejected value; `08`) exercise it on stubs.
  - ⚠️ **A consequence the ruling did not name, made in the same commit.** The one command's `curl`
    URL and the documented clone form now take `stable` (`bootstrap.sh` lines 6 and 12;
    [BUILD.md §8](BUILD.md#8-build-order)).
    - So the script and the commit it builds are close, not identical: `raw.githubusercontent.com`
      may serve `stable` minutes stale, and `stable` may advance between the `curl` and the fetch.
    - Before `stable` exists, the `curl` returns 404 and bash runs nothing. The same case already
      failed at the `rev-parse` of `origin/stable`.
    - A fix to `bootstrap.sh` is fetchable only once its CI is green.
    - Made by the implementer on the review's finding, reported to Chris, not separately ruled.

**Update 2026-10-04: CI and the role skip. (Chris), 2026-10-04.**

- ~~📋~~ **Now:** one cheap check. *Built 2026-10-04, in commit `47ed4ed`: the `ci.yml` step "a
  role-gated step calls require_role first".* In every step that contains `require_role`, the first non-comment
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
`update.sh`'s reach. *Update 2026-10-04 (evening), (Chris): a foundation script may also be
invoked by the bootstrap, `update.sh --bootstrap`, which a human starts by hand on a first build. Two
foundation scripts, `rtc-overlay.sh` and `format-archive.sh`, are ruled for that, 🎒 portable role
only ([§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)'s evening update). No
step and no timer-started update invokes one, so they stay outside the update path's reach. ~~📋 Ruled,
not built.~~* *Corrected 2026-10-04, later that evening: built, not yet run on hardware. As built,
`format-archive.sh` also refuses a real run without `update.sh --bootstrap`'s marker in its
environment, or on a rig that already has a build.*

⛔ **`update.sh` cannot touch what keeps the rig reachable.** The install and restart helpers in
`lib.sh` carry a denylist, and CI greps `setup/steps/` for it:

| Paths | Units |
|---|---|
| `/boot/firmware`, `/etc/network*`, `/etc/NetworkManager`, `/etc/systemd/network`, `/etc/ssh`, `/etc/apt/sources.list*`, ~~📋~~ *`/etc/fstab` (decided 2026-10-04, ~~not yet in `lib.sh`~~ in `lib.sh` since commit `47ed4ed`; see below)* | `tailscaled`, `ssh`, `NetworkManager`, *`sshd` (added 2026-10-04: `lib.sh`'s `ADSB_DENY_UNITS` already lists it, because on Debian `ssh.service` is also reachable as `sshd.service`)* |

*Update 2026-10-04 (evening), (Chris): the ⛔ above stands for the update path. Its reason is a
remote rig under automatic updates, and a first build started by hand is outside that reason; see
[§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)'s evening update. ~~📋 CI's grep
is to cover `setup/update.sh` and `setup/bootstrap.sh` too ([§9f](#9f-what-updatesh-does)'s evening
update).~~* *Corrected 2026-10-04, later that evening: built. CI's grep now covers those two and
`setup/foundation/`, `setup/files/`, `bin/` and `tools/`, with only `setup/foundation/rtc-overlay.sh`
allowed to name `/boot/firmware` ([§9f](#9f-what-updatesh-does)'s "As built").*

**Update 2026-10-04: `/etc/fstab` joins the denylist.** **(Chris), 2026-10-04.** It is a guard: no
step writes `/etc/fstab` under the archive-drive design, which mounts the drive with a systemd mount
unit instead ([§9m](#9m--the-portable-rigs-archive-drive)). ⚠️ **`ADSB_DENY_PATHS` in `setup/lib.sh`
must change with this table~~, and has not yet~~.** Its comment says the list is written as in this
table, and CI reads that array~~, so until it changes the CI grep does not check for `/etc/fstab`~~.
*Corrected 2026-10-04: `ADSB_DENY_PATHS` gained `/etc/fstab` in commit `47ed4ed`, so the CI grep of
`setup/steps/` now checks for it.*

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

⛔ ~~**Their language and packaging are not chosen now.**~~ BUILD.md §8 step 4 says to write the uploader
last, and [BUILD.md §9](BUILD.md#9--the-archive-and-feeding) says to build the extractor alongside
the writer. Choosing for them now would get ahead of both.

**Corrected 2026-10-04: the writer's and the extractor's language and packaging are chosen. (Chris),
2026-10-04:** Python 3, standard library only. The ruling and its reasons are in
[§9m](#9m--the-portable-rigs-archive-drive), under "The archive writer". The timing this section
waited for has come: the writer is being built now, and its extractor is built alongside it, as
BUILD.md §9 says. 📋 Decided, ~~not built~~ *built: corrected 2026-10-04, `bin/adsb-writer` and
`tools/adsb-extract` are written, and the writer records on the 🎒 portable Pi (the end of §9m)*. The uploader's language is still not chosen; BUILD.md §8
step 4 still puts it last.

**Only the interfaces are fixed:**

- `readsb` BEAST output on port 30005.
- `/etc/adsb-receiver/`, and `/var/lib/adsb-receiver/{spool,archive}`.
- `bin/clock-preflight` comes first. It parses `chronyc tracking` against `clock.max_offset_ms`
  and `clock.require_disciplined`.

~~📋 **OPEN ITEM — what time is in a BEAST frame?**~~ It is **believed, not verified**, that BEAST frames
from `readsb` on an RTL-SDR carry a 12 MHz MLAT counter rather than UTC. If that is true, the writer
has to supply wall time itself. ➡️ Settle it on the bench before designing the writer: capture port
30005 and compare the frame timestamps against `date`.

**✅ Settled 2026-10-04: a BEAST frame carries a 12 MHz counter, not UTC.** Checked with a 60 s
read-only capture of port 30005 on the 🎒 portable Pi, run over SSH: 5,381 frames, with the Pi clock
disciplined by NTP to 0.65 ms, and the counter fitted against the wall clock by least squares.

- **A 12 MHz counter:** 11,999,700 ticks per second, about −25 ppm against the disciplined clock.
  ~~It follows the radio's crystal, not the Pi's clock.~~
  - *Corrected 2026-10-04: "follows the radio's crystal" is struck as unsupported. −25 ppm is what
    this 60 s capture gave. ✅ A 525.5 s fit of the writer's first closed file, on the 🎒 portable
    Pi later the same day, gives the counter at +0.1 ppm against 12 MHz (`tools/adsb-extract
    --check`, seen by Claude on 2026-10-04; see the end of [§9m](#9m--the-portable-rigs-archive-drive)).
    The two disagree, and the cause of the difference is not known. ⚠️ Belief, not checked: the
    clock was NTP-disciplined to 0.65 ms for this capture, but whether chrony's frequency estimate
    had settled is unknown. The writer is unaffected: it stamps wall time itself (R1 in §9m).*
- **It counts from `readsb`'s start, and resets on every `readsb` restart.** `readsb` started at
  monotonic 17.2 s; at uptime ≈ 665.7 s the counter read 647.6 s.
- **It is monotonic:** zero backward steps in the capture.
- **It is not UTC in any encoding.** Read as Radarcape seconds-of-day, it gave 7 s against a real
  76,990 s.
- **~~Mode A/C frames, type `0x31`,~~ Type-`0x31` frames carry timestamp 0.** *Corrected 2026-10-04: this
  overstated the case. The only `0x31` frames seen were all-zero keepalives, and no Mode A/C reply
  has been observed; see the correction below. ✅ Mode A/C decoding is not switched on: checked by
  Claude on 2026-10-04 over read-only SSH, the running `readsb`'s command line has no `--modeac`, and
  `/etc/default/readsb` does not mention it. ⚠️ Still a belief, not verified: that `readsb`'s default
  with no `--modeac` is off.*
- ➡️ **The writer supplies wall time.** How it does that is the ruling in
  [§9m](#9m--the-portable-rigs-archive-drive), "The archive writer".
- ~~⚠️ **Belief, not verified:**~~ that the timestamp-0 `0x31` frames are `readsb`'s idle BEAST heartbeat,
  sent every `--net-heartbeat` ~~(believed to default to 60 s)~~. If so, they are evidence of "connected,
  empty sky". Check it in a capture.
- **✅ Corrected 2026-10-04: checked. They are `readsb`'s keepalive, and the 60 s interval was
  wrong.** Checked by Claude with a read-only 30 s capture of port 30005 on the 🎒 portable Pi: 5
  type-`0x31` frames in 30 s, about one every 6 s, and every one entirely zero (counter
  `000000000000`, signal 0, data `0000`). ➡️ They are `readsb`'s keepalive, an all-zero Mode A/C
  frame, not Mode A/C replies. The belief about what they are holds; the belief about how often they
  come was wrong. Whether the ~6 s interval is set by `--net-heartbeat` is not checked.
  - The writer keeps them like any other frame (R1 in [§9m](#9m--the-portable-rigs-archive-drive)).
    📋 The extractor's per-file fit is being changed, in `tools/adsb-extract`, to drop a `0x31` frame
    only when it is all-zero.

**Update 2026-10-04: the archive drive.** 📋 Decided, ~~not built~~ *partly built*; see
[§9m](#9m--the-portable-rigs-archive-drive). *Corrected 2026-10-04: commit `47ed4ed` built the mount
at `/var/lib/adsb-receiver/archive` (`30-archive-drive`), the portable template's `spool_dir` on the
drive, the `tmpfiles.d` entry for `/run/adsb-receiver` and the recording lock file (`05-config`),
and `bin/archive-preflight` with the exit codes below.* ~~*The writer, and with it the storage contract,
is not built, and*~~ *`bin/clock-preflight` is not in `47ed4ed`. Corrected 2026-10-04, later: the
writer is written and records on the 🎒 portable Pi, and `bin/clock-preflight` is written and
installed there by `20-portable-clock`; see the end of [§9m](#9m--the-portable-rigs-archive-drive).*

- `/var/lib/adsb-receiver/archive` becomes a mount point. On the 🎒 portable rig it is where the
  archive drive is mounted. How the 🏠 stationary rig's SSD backs it is not decided.
- 🎒 On the portable rig the spool moves onto the drive: `uploader.spool_dir` becomes
  `/var/lib/adsb-receiver/archive/spool`. The rest of `/var/lib/adsb-receiver/` stays on the SD card.
- The storage contract for the writer in §9m is one of the fixed interfaces: UTC file names,
  10-minute rotation, `.part` while open, fsync, `.torn`, and group `adsb-operator` permissions. ~~The
  writer's language and packaging are still not chosen.~~ *Corrected 2026-10-04: chosen, and the
  contract's open items are closed; see the correction at the top of this section and §9m, "The
  archive writer".*
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
  `/usr/lib/modprobe.d` for `rtl28xxu` found nothing. *Update 2026-10-05: that is the 2026-10-03
  fact about the package, and is now history for the rig. Since 2026-10-05 `00-drivers` writes its
  own blacklist, `/etc/modprobe.d/adsb-receiver-rtlsdr.conf`; see the 2026-10-05 ruling below.*
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

**Update 2026-10-05: no verify in `setup/steps/` opens the stick; `readsb` is the rig's only
opener. (Chris), 2026-10-05,** by multiple-choice question, on fable-architect's call after the
rejection check.

🔑 **The 2026-10-04 hazard was the close, not the open.** While the kernel's `dvb_usb_rtl28xxu` is
loaded, every `rtlsdr_close` is a kernel re-probe of a stick that may have just hung: `librtlsdr`
prints `Reattached kernel driver` on every close (fact 3 below). The module is loaded on every first
build, and stays loaded until a reboot, which `update.sh` never performs. A verify opens and then
closes, by definition, so any opener in a verify performs the second half of the hazard. `readsb`
differs in kind: it opens the stick once and holds it.

What each verify proves now, read from the code:

- **`00-drivers`:** `rtl_test` and `rtl_eeprom` resolve on `PATH`. The stick is present in sysfs, as
  `0bda:2838` or `0bda:2832`: none fails the step; more than one warns, and the first is judged. Its
  EEPROM strings are read from sysfs, printed, and not judged. The udev rule's observable effect: the
  node `/dev/bus/usb/BBB/DDD` is group `plugdev`, mode `660`, retried for up to 5 s. Root-only was
  the exact 2026-10-03 failure (`usb_open error -3`, above). The blacklist file contains
  `blacklist dvb_usb_rtl28xxu`. With the module loaded it warns, records a reboot (`need_reboot`) and
  passes. ⛔ It never fails on that, so an update never rolls back for a pending reboot.
- **`10-decoder`:** after its streaming checks, it reads the tuner line, an
  `RTL-SDR Blog V4 Detected` line and the EEPROM strings from `readsb`'s journal, filtered to
  `readsb`'s current `InvocationID`. It reports whether `Detached kernel driver` appears there: if it
  does, a kernel driver was bound when `readsb` opened the stick, which is the state before the
  blacklist's first reboot. The tuner table that follows informs and never gates (the next update).

⛔ **Rejected,** by fable-architect, with these reasons:

- **A single `rtl_eeprom` open.** It is still a close with the module loaded, on every first build.
  "`rtl_eeprom` does not hang" is a belief. And the strings are in sysfs for free (fact 4 below).
- **Opening the stick only when the module is not loaded.** Dead code: `readsb` holds the stick on
  every later boot. It would also prove the wrong user's access.
- **A reboot in the middle of the build.** That is the resume unit rejected in
  [§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic). The bootstrap's one reboot
  is at its end.
- **`modprobe -r` in the install.** Removing a USB driver runs its disconnect against the stick, the
  same class of act. To be reconsidered only if a first build ever drops the hub.
- **Keeping the sudo user's `rtl_test` as the proof of the udev rule.** It proves the operator's
  access, not `readsb`'s. The node's group and mode prove the rule's effect, and `readsb`'s own open
  proves the access of the user that matters.
- **Failing on "module loaded", or on "no tuner line".** Every update would roll back until a reboot
  by hand.
- **A settle wait after stopping `readsb`.** Proposed earlier the same day in the first
  implementation pass, and withdrawn after review: it could not observe the re-bind.

⚠️ **Accepted exposure.** On a first build `readsb` starts with the module still loaded, and runs so
until the bootstrap's end-of-run reboot. That was the state of every rig, on every boot, until
2026-10-05.

➡️ **What would change it:**

- a counterfeit or a genuine V4 that gives no tuner line, or a different one, through `readsb`'s
  stderr;
- journald rotation on the 🏠 stationary losing the current invocation's open line. Then
  `10-decoder` would persist the first tuner line it sees, not open the stick;
- a hub drop from `readsb`'s own open, with the module loaded, on a first build;
- Chris ruling that a verify must prove that the human's `rtl_test` works.

ℹ️ Chris's 2026-10-04 ruling that a verify may stop `readsb` for seconds
([§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect)) still stands. `00-drivers` stops
using the permission.

✅ **Verified on hardware, 2026-10-05,** on the 🎒 portable, `mobile-adsb`: the new `00-drivers`
verify passed, with the node `plugdev 660` and the strings `Realtek` / `RTL2838UHIDIR` /
`00000001`. After the reboot the module was not loaded, and `readsb`'s journal had no
`Detached kernel driver` line. `10-decoder`'s verify read `Found Rafael Micro R820T tuner` from the
current invocation.

**Update 2026-10-05: the tuner table informs and never gates. (Chris), 2026-10-05:** *"I will not be
using the counterfeit radios anymore."* In `10-decoder`'s verify the three odd combinations warn, and
the step passes on streaming:

- a V4 line with a tuner other than the R828D;
- an R828D with no V4 line: the [BUILD.md §4](BUILD.md#4-drivers-first) silent failure, now a
  warning;
- Blog or V4 in the EEPROM strings on a tuner other than the R828D: the counterfeit signature, kept
  for the record.

Until 2026-10-05 the first two failed the verify, in `00-drivers`. The reason, recorded by the
`10-decoder` review: under `update.sh`, a hardware or library verdict used as an update gate would
roll back a candidate that cannot fix it, on every timer pass. This supersedes the 2026-10-04 interim
ruling in [§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect).

**The facts behind both rulings, recorded 2026-10-05:**

1. **The 2026-10-04 hub drop.** `00-drivers`' `rtl_test` hung the counterfeit stick; the DVB driver
   re-probed it; a USB reset storm followed; then a firmware mailbox timeout (an
   `rpi_firmware_property_list` WARNING, tag `0x00038002`); then the Pi 4's whole USB 2.0 hub,
   `usb 1-1`, disconnected, taking the stick, the GPS puck and the archive drive together. The
   archive drive's ext4 journal aborted, with no file open. `get_throttled` read `0x0`, so it was not
   power. Only a reboot recovered it. ⚠️ On a Pi 4 every USB 2.0 device is on that one hub, whatever
   the port: the kernel shows all three as `1-1.x`.
2. **The blacklist needs no initramfs rebuild, on the 🎒 portable.** The module loads from the root
   filesystem about 5.5 s after boot (`dmesg`), and the initramfs is `MODULES=dep` and does not
   contain it (`lsinitramfs`). So `/etc/modprobe.d` applies at the next boot, with no initramfs
   rebuild and nothing under `/boot/firmware`. ⚠️ Checked on the portable only. The 🏠 stationary's
   image is unchecked.
3. **`librtlsdr` prints `Reattached kernel driver` on every close.** Seen in the output of
   `rtl_eeprom` and `rtl_test`, 2026-10-05.
4. **The USB descriptor strings in sysfs are the strings `rtl_eeprom` prints.** Both read on
   2026-10-05: `Realtek` / `RTL2838UHIDIR` / `00000001`.
5. **The genuine RTL-SDR Blog V3.** Its EEPROM reads `Realtek` / `RTL2838UHIDIR` / `00000001`, with a
   Rafael Micro R820T tuner (`rtl_eeprom` and `rtl_test`, run by Chris, 2026-10-05). ➡️ The
   counterfeit match, `[Bb]log|V4`, never fires on a V3.
6. **Since 2026-10-05 `00-drivers` writes `/etc/modprobe.d/adsb-receiver-rtlsdr.conf`.** The
   2026-10-03 fact above, that the package installs no blacklist file, is now history.
7. **A rollback does not remove that file:** a rollback does not undo creation
   ([§9f](#9f-what-updatesh-does)). Harmless: nothing on the rig uses the DVB driver.
8. **A first build now records a reboot,** because the module is loaded at boot, before the blacklist
   exists, and the bootstrap reboots at its end
   ([§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)'s reboot rule). Seen
   2026-10-05.

**Update 2026-10-05: `10-decoder`, as built.** Until 2026-10-05 the step's header said its record in
PLAN was pending; this is that record.

- **`readsb`** is built from source at the `v3.16.17` tag of `wiedehopf/readsb`
  (`094720939c01943de82b14df6f42f67fff1cd514`), with `RTLSDR=yes` and
  `OPTIMIZE=-O2 -march=native -mtune=native`, against the packaged `librtlsdr` 2.0.2. ⛔ Never from
  apt: trixie's packaged `readsb` has no RTL-SDR support (above). The step refuses to run while the
  apt package is installed.
- **The unit and `/etc/default/readsb`** are rendered from upstream's `debian/` files at the pin,
  identical to them apart from the rendered header comment (the bodies were diffed on 2026-10-04).
- **`tar1090`** is at `3.14.1823` (`e784ee5ae82948f41efe3ef5c235ade0943ab8ff`), installed by its own
  `install.sh` from the pinned checkout, and served by `lighttpd`. ⚠️ **`tar1090-db`, the aircraft
  database, is not pinned.** Accepted, (Chris) 2026-10-04: it is lookup data, not code.
- **A drop-in, `/etc/systemd/system/readsb.service.d/adsb-receiver.conf`,** sets
  `StartLimitIntervalSec=0`, `RestartSteps=5` and `RestartMaxDelaySec=2min`: systemd's exponential
  backoff. A rig with no stick backs off from one attempt every 15 s toward one every 2 minutes, about
  15, 23, 34, 52 and 79 s, then 2 min. Upstream's unit alone restarted it every 15 s: 28 restarts in
  about 7 minutes were seen on 2026-10-04. Two minutes, not ten, bounds the loss after a transient
  fault on the remote rig. ⚠️ That rests on a belief, not verified: that systemd does not reset the
  restart counter after a long healthy run.
- **The verify asserts** `RestartSteps=5`, `RestartMaxDelayUSec=2min`, `StartLimitIntervalUSec=0`,
  and the drop-in in `DropInPaths`.
- **When it reloads and restarts.** A changed unit file or drop-in always daemon-reloads. A run that
  finds `readsb` `activating`, in its backoff, restarts it rather than waiting the backoff out.
  Otherwise a running `readsb` is restarted only when its binary, unit, drop-in or defaults changed
  (the render, diff, install rule of [§9f](#9f-what-updatesh-does)), when it lacks the `plugdev`
  group, or when systemd had it loaded from another unit file.
- ⚠️ **Known limitation:** with two sticks, `00-drivers` verifies the first device sysfs lists, and
  `10-decoder` verifies `readsb`'s device 0.

✅ **Verified on hardware, 2026-10-05: the first run.** On the 🎒 portable, `mobile-adsb`, by
`adsb-update --rev 42b5115`, run by Chris after stopping the writer by hand. The install and the
verify passed: `readsb --version` printed 3.16.17; `DropInPaths` and the three values were as
asserted; `samples_processed` climbed; `tar1090` answered HTTP 200 at the pinned version. The commit
then merged to `main` (`42b5115`, CI green), and `stable` advanced.

- **Reception on the V3, at 20:38 (Arizona time, UTC−7, as is 14:20 below):** 5,523 messages a
  minute, 17 aircraft, signal −13.7 dBFS and noise −30.0 dBFS. The counterfeit's baseline,
  2026-10-04 at 14:20: 5,538 messages a minute, 14
  aircraft, −14.2 / −38.6 dBFS. ⚠️ The noise figure is an autogain artifact, two minutes after a
  restart, not a comparison of the sticks. Range is not comparable, because `readsb` has no receiver
  location configured.

### 9k. The first deliverable, in order

1. `setup/lib.sh` + `setup/steps/00-drivers.sh` + the CI workflow, **in one change.**
2. `05-config` + `10-decoder`. *Half done, 2026-10-04: `05-config` is built, widened as in
   [§9m](#9m--the-portable-rigs-archive-drive), in commit `47ed4ed`. ~~`10-decoder` is not.~~*
   *Corrected 2026-10-05: `10-decoder` is built too, committed as `42b5115`, and ran on the 🎒
   portable Pi ([§9j](#9j--verified-on-hardware-2026-10-03)).*
3. `update.sh` + the timers + `status.json` + the job that advances `stable`. *Built 2026-10-04
   (evening), with `setup/bootstrap.sh` ([§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)),
   `50-updater` (the timers and the login banner) and `60-portable-pull`
   ([§9f](#9f-what-updatesh-does)'s evening update). ~~⚠️ Not yet run on hardware.~~ The arm64 dry run
   in CI is still not built.* *Corrected 2026-10-10: run on the 🎒 portable many times since: the
   bootstrap's first build on 2026-10-04 and its completion on 2026-10-05
   ([§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)); the timer's lock-held
   skip (§9e); pull windows by hand, and the opener's automatic opens, each writing `status.json`
   ([§9f](#9f-what-updatesh-does)'s record on hardware of 2026-10-09 and 2026-10-10, and its step-06
   records). The job that advances `stable` has run on GitHub since 2026-10-04
   ([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable)). ⚠️ Nothing of it has run on
   the 🏠 stationary, which is not built.*
4. `20-portable-clock` + `clock-preflight`. *Done 2026-10-04: both are written, and step 20 ran on
   the 🎒 portable Pi; see the end of [§9m](#9m--the-portable-rigs-archive-drive).*

The foundation scripts come when the stationary build starts. *Update 2026-10-04 (evening): two
foundation scripts came first, for the 🎒 portable's first build, `rtc-overlay.sh` and
`format-archive.sh` (§9e); the 🏠 stationary's still come with its build.*

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
*Update 2026-10-04 (evening): the one-command build's `--role`, ruled by Chris, is a different
thing; see [§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)'s evening update.
It names the template the bootstrap writes into `station.yml`, and the role-specific steps stay
separate files.*

⛔ **Rejected: two whole script trees, one per rig.** BUILD.md §8 steps 0–1 are identical, and copies
diverge.

~~⛔ **Rejected: an `install-all.sh` for the first build.** It would drive straight through the human
gates in BUILD.md §8.~~ *Superseded 2026-10-04 (Chris): the first build is one command,
`setup/bootstrap.sh` handing off to `update.sh --bootstrap`
([§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)'s evening update). The
reason is answered, not dropped. Of BUILD.md §8's human gates, the sky check and the power cycle
with the network unplugged are readiness, judged by the preflights, and stay human gates after the
build. The config becomes `--role`. The RTC overlay and the archive format move to the foundation
tier, which only the hand-started bootstrap invokes, the format under a strict rule that refuses
anything it cannot prove is the one right drive. Missing hardware no longer stops the build: the
installed timer finishes it. Chris: "the act of me starting the install should be considered my
agreement to do it." ~~📋 Ruled, not built.~~* *Corrected 2026-10-04, later that evening: built,
not yet run on hardware.*

⛔ **Rejected: letting the updater reboot.** It sets `reboot_required` instead.
*Update 2026-10-04 (evening), (Chris): this stands for `update.sh`, which still never reboots. Its
scope is now the updater: `bootstrap.sh`, the one-command build's fetcher, may reboot once, on a
first build, when the foundation tier set the reboot flag
([§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)'s evening update). ~~📋 Ruled,
not built.~~* *Corrected 2026-10-04, later that evening: built, not yet run on hardware; and the
bootstrap reboots only when five conditions all hold, not on the flag alone (§9e's "As built").*

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
*📋 Open note, 2026-10-04 (not a ruling): this rejection was about adding an RTC board. The
stationary hardware is not yet ruled; one Pi 5 is expected to serve as a stationary rig, and the
proposal for the remote rig is a Pi 5; if so, its built-in RTC changes this rejection's premise
(and [§4](#4-proposed-split-the-stationary-site-across-two-pis)'s "Rejected for now: a Pi 5" is
overtaken too). For the stationary design. From
Raspberry Pi's documentation (the RTC section, read by a documentation lookup on 2026-10-04, not
checked on hardware): the Pi 5's RTC is usable with no battery; a battery goes on connector J5,
"BAT", a two-pin JST-SH; the official battery is a rechargeable ML2020 lithium-manganese cell, and
a primary (non-rechargeable) cell is not recommended; trickle charging is off by default, and
`dtparam=rtc_bbat_vchg=3000000` in `config.txt` turns it on. ⚠️ The documentation does not say
whether the RTC appears as `/dev/rtc0`, whether the kernel sets the clock from it at boot, or that
no overlay is needed; check those on a Pi 5. ℹ️ `setup/foundation/rtc-overlay.sh`'s header already
notes that on a Pi 5 its `/dev/rtc0` check, and step 20's, would need revisiting. What the
stationary rigs do with the RTC is for the stationary design.*

⛔ **Rejected: choosing the writer's language now.** See
[§9i](#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader).
*Update 2026-10-04: the timing this rejection waited for has come. The writer is being built now,
and its extractor is built alongside it, as [BUILD.md §9](BUILD.md#9--the-archive-and-feeding) item 3
says. **(Chris), 2026-10-04:** Python 3, standard library only; the ruling, and the languages
rejected with it, are in [§9m](#9m--the-portable-rigs-archive-drive), "The archive writer".*

⛔ **Rejected: `yq`.** It is not on the image. `python3` with its `yaml` module is
([§9j](#9j--verified-on-hardware-2026-10-03)).

ℹ️ The entries below were added 2026-10-04, with the archive drive
([§9m](#9m--the-portable-rigs-archive-drive)).

⛔ **Rejected: exFAT for the archive drive.** It has no journal. **(Chris):** *"I would prefer to
have the power cycle resistance than force a windows download on it."*

⛔ **Rejected: a step that runs `mkfs`**, for instance whenever `blkid` shows no filesystem.
[§9f](#9f-what-updatesh-does) runs the steps on every update, the remote stationary rig included. ~~A
human formats the drive once, by hand.~~ *Superseded 2026-10-04 (Chris), for the 🎒 portable: the
rejection of a step that runs `mkfs` stands, for the reason above. The format moves to a foundation
script, `setup/foundation/format-archive.sh`, which only the hand-started bootstrap invokes, under a
strict rule; a human formats by hand only when that rule refuses, or with `--no-format`. See
[§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)'s evening update. 📋 Ruled,
not built.*

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

📋 **~~None of this exists yet.~~** ~~No step, preflight, mount unit, template change or writer has been
written. Every mechanism below is decided, not built.~~ *Part of it is built; see the 2026-10-04
update below.*

**Update 2026-10-04: what is built.** Commit `47ed4ed`, the afternoon of the day this section was
decided, built:

- `setup/steps/05-config.sh`, widened as in the steps below.
- `setup/steps/30-archive-drive.sh`, which renders and installs the mount unit and its drop-in.
- `bin/archive-preflight`.
- The `setup/lib.sh` changes: `--skip-other-role` and `ADSB_RC_OTHER_ROLE`
  ([§9b](#9b-one-bash-script-per-build-step)), and `/etc/fstab` in `ADSB_DENY_PATHS`.
- The template changes, portable and stationary, as in the templates paragraph below.
- CI's check that a role-gated step calls `require_role` first
  ([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable)).

📋 **Still not built:** ~~the writer and its unit,~~ the pull window, the sudoers drop-in, the pull
wrapper, `NN-portable-pull`, `update.sh`, `status.json`, and the login banner. *Corrected
2026-10-04, later: the writer, its unit and its step, `40-archive-writer`, are written, and step 40
ran on the 🎒 portable Pi; see the end of this section.* *Corrected 2026-10-04, in the evening: the
pull window, the sudoers drop-in, the pull wrapper (`tools/pull-archive`), the pull step
(`60-portable-pull`), `update.sh`, `status.json` and the login banner are written too
([§9f](#9f-what-updatesh-does)'s evening update). ⚠️ None of them has run on the Pi.* The choices the build
made where this section left them open, and the first run on hardware, are at the end of this
section.

⭐ **(Chris), 2026-10-04: the field-loss rule.** *"we may need to pivot if these decisions cause
issues recording in the field (losing the data from one days shooting is ok as long as it is fixed,
losing it continuously is not acceptable)."* ➡️ This is the test for revisiting today's choices: one
lost day that gets fixed is acceptable; a failure that keeps losing data is not.

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
with barriers on and journal checksums (~~confirm with `tune2fs -l`~~ *confirmed from the live mount,
`findmnt` and `/proc/fs/ext4/<dev>/options`, not `tune2fs -l`; corrected 2026-10-04, see the build
choices at the end of this section*). No `discard`: continuous TRIM
over USB mass storage is often unsupported, and it can stall a cheap controller. The weekly
`fstrim.timer` is the safe alternative, because it skips a device without TRIM. Rejected: exFAT, which has no journal **(Chris)**; f2fs,
whose repair tool is unfamiliar, for a workload that is sequential; btrfs, because CPU is the binding
constraint ([§3](#3--cpu-is-the-binding-constraint-not-power)) and this is a single device that may
ignore flushes; `data=journal`, which doubles the writes; a `sync` mount, for throughput and wear.

~~**Formatting is a human gate.** A human formats the drive once, by hand:~~ *Superseded 2026-10-04
(Chris), for the 🎒 portable: the one-command build's bootstrap formats the drive, under a strict
rule, through the foundation tier; see the dated block after this paragraph. By hand, when that
rule refuses or with `--no-format`:* confirm the device with
`lsblk`, run ~~`mkfs.ext4 -L adsb-archive -m 0 /dev/sdX`, then `tune2fs -c 1`~~
*`mkfs.ext4 -L adsb-archive -m 0 /dev/sdX1`, then `tune2fs -c 1 /dev/sdX1` (corrected 2026-10-04;
see below)*. ⛔ **No step ever runs
`mkfs`.** When the step finds no ext4 filesystem with the label, it prints the format command and
exits non-zero. The reason is that [§9f](#9f-what-updatesh-does) runs the steps on every update,
including on the remote stationary rig. Rejected: a step that formats when `blkid` shows no
filesystem.

**Update 2026-10-04 (evening): the foundation exception. (Chris), 2026-10-04.** ~~📋 Ruled, not built.~~
*Corrected 2026-10-04, later that evening: built, not yet run on hardware; as built, below.*
*"No step ever runs `mkfs`"* keeps its sentence: step 30 still formats nothing, and still prints the
commands and exits non-zero when it finds no labeled drive. The exception is not a step.
`setup/foundation/format-archive.sh`, 🎒 portable role only, is invoked only by `update.sh
--bootstrap`, which a human starts by hand on a first build, and never by a step or the timer. It
formats under the strict rule written in
[§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)'s evening update: nothing if a
drive already carries the label, otherwise exactly one unmounted, non-boot, removable USB disk of at
least 8 GB with no signature (or one proven empty), and otherwise a loud refusal that leaves the
command in `status.json` and the banner. ➡️ The reason above, the steps running on every update on
the remote rig, does not reach a first build started by hand. ℹ️ `setup/steps/30-archive-drive.sh`'s
format help (*"No script runs mkfs"*) and the portable template's comment (*"No script formats
it"*) say "no script", which is wider than this ruling, and are stale once this is built.
*Update 2026-10-04: both were reworded in the build; they now name the bootstrap's
`format-archive.sh` as the one thing that may format the drive.*

**Update 2026-10-04 (evening): the format, as built.** `setup/foundation/format-archive.sh` gathers
the facts and does the formatting; `setup/foundation/archive_candidates.py` decides, as pure
functions over `lsblk -J`, tested without a disk in `tests/test_archive_candidates.py`. The shell's
`--dry-run` is tested on stubbed tools in `tests/test_format_archive_shell.py`. ⚠️ Not yet run on
hardware: no command of it has run on the Pi. Where it goes beyond the rule in
[§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic), these are the build's own
choices, made stricter on review:

- **A guard, not only a comment.** A real run needs `ADSB_FOUNDATION=bootstrap`, which only
  `update.sh --bootstrap` sets, and no `/opt/adsb-receiver/applied`. Run any other way, it refuses.
  `--dry-run` decides, probes with read-only mounts, runs the last checks, formats nothing, and may
  be run by hand as root.
- **A labeled drive is never formatted.** If the device carrying `archive.label` is ext4, it formats
  nothing and step 30 mounts it. If it is not ext4, it refuses and names the fix: format that device
  as ext4 by hand if it may be erased, or unplug it, or remove its label. The label says somebody
  chose that drive, and step 30 mounts only ext4.
- **Stricter than the rule's letter.** It also refuses a filesystem on the whole disk with no
  partition table, a partition table with no partition, more than one partition, a lone partition
  that is not partition 1, a read-only disk, and a partition used by RAID, LVM or encryption.
  "8 GB" is 8×10⁹ bytes, so a stick sold as 8 GB usually does not qualify.
- **"Proven empty", as built.** A read-only mount (`noload` for ext2, 3 and 4, so a dirty journal is
  not replayed) that holds nothing but `System Volume Information`, `.Trashes` and `lost+found`, each
  a plain directory. `.Trashes` and `lost+found` must hold no files. **`System Volume Information`**
  may hold only what Windows writes on a removable drive: the regular files `WPSettings.dat`,
  `IndexerVolumeGuid`, `tracking.log` and `MountPointManagerRemoteDatabase`, and the directories
  `ClientRecoveryPasswordRotation` and `AadRecoveryPasswordDelete` only if empty. Anything else
  there makes the probe answer "unknown". ⚠️ That list of files is from memory, not checked against
  Windows.
- **Fail closed on anything unread.** A probe mount that fails, an ext journal that needs recovery,
  an unreadable directory, or an unknown answer refuses the whole run, not only that disk. Only a
  filesystem that mounted and plainly holds files excludes its disk and lets another be formatted.
- **The last check, just before formatting.** `lsblk` and `findmnt` again (nothing on the disk is
  mounted or swap; the disk has the same size, serial and partition-table UUID), and `blkid -p`, a
  probe of the device itself, must read the signature decided on, its `TYPE` (or a whole disk's
  `PTTYPE`) and nothing else. Any disagreement, or a tool that errs, refuses. A proven-empty
  filesystem is wiped with `wipefs` first, and `mkfs.ext4` reads its input from `/dev/null`, so a
  prompt can never hang it.
- **PART-WAY.** Once it prints `FORMATTING`, any later refusal becomes a failure: exit `1`,
  `result: failed`, and a reason beginning "PART-WAY", which says the disk may hold a new partition
  table or a partial filesystem. Never "nothing was changed". That includes a last check that
  disagrees after `sfdisk` wrote a new table.
- **Exit codes:** `0` formatted, skipped (an ext4 drive with the label is present) or a dry run that
  would format; `2` refused, nothing changed, and only a refusal exits `2`; `1` could not run, or
  failed part-way. Its report (result, reason, device and the manual command) goes into
  `status.json`'s `foundation` record.

**Update 2026-10-04: the partition, not the whole device. (Chris), 2026-10-04.** The format
commands name partition 1, `/dev/sdX1`, not `/dev/sdX`. The drive came with an MBR partition table
holding one partition, and formatting partition 1 keeps that table. Rejected: formatting the whole
device. Whether formatting it over an existing table leaves a stale table was not verified, and was
not tested. Step 30's format help prints the partition commands.

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
  - **Update 2026-10-04, after the first run on the 🎒 portable (at the end of this section).**
    ✅ The explicit wiring works: on a remount,
    `systemd-fsck@dev-disk-by\x2dlabel-adsb\x2darchive.service` ran, and e2fsck forced a check.
    ⚠️ Still unverified: that a native mount unit does not pull in `systemd-fsck@` by itself. The
    unit wires it explicitly, so this run cannot tell. ⚠️ Still unverified: the device timeout, a
    drop-in on the device unit setting `JobRunningTimeoutSec=10s`, believed to match what fstab's
    `x-systemd.device-timeout=` generates; and that a boot without the drive reaches the login
    banner in seconds. Both wait on the pre-field checklist's boot with the drive pulled.
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
  ~~and `RequiresMountsFor=`~~, so the writer runs as its own system user, `adsb-receiver`.
  *Corrected 2026-10-04: the guard against writing to the SD card is now `archive-preflight` plus
  the `0555` mount point, and no unit dependency. **(Chris), 2026-10-04:** the writer's unit has
  `Wants=` and `After=` on the archive's mount unit instead of `RequiresMountsFor=`; see the
  correction in "The writer's unit, and the recording lock" below.*

**A preflight, `bin/archive-preflight`,** beside `clock-preflight`~~, plus
`RequiresMountsFor=/var/lib/adsb-receiver/archive` on the writer's unit once the writer exists~~.
*Corrected 2026-10-04: not `RequiresMountsFor=`; the writer's unit has `Wants=` and `After=` on the
archive's mount unit (see the writer's unit below).* It prints its raw evidence, and checks:

- `findmnt` shows the path mounted from the labeled device, ext4, read-write.
- Exactly one device carries the label.
- A write, fsync, read and delete probe succeeds as `adsb-receiver`.
- It renames a torn `.part` to `.torn` (see the storage contract below).
- It reports free space, and below `archive.min_free_gb` it warns that the writer will expire old
  files. ⛔ **It does not refuse on free space;** see the backstop below.
  - **Update 2026-10-04: a full drive counts as ready.** Found in review: the write probe failed
    with ENOSPC on a 100%-full drive, and the preflight exited `2`. That refused on space, and it
    would have kept the writer, the one component that expires files, from ever starting, against
    the ⛔ above and the backstop ruling below. Now, with under 1 MiB available or no free inodes,
    the preflight warns loudly, skips the probe, and exits `0`. A probe that fails with ENOSPC is
    excused the same way. Chris approved this on 2026-10-04. ⚠️ The ENOSPC path was simulated, not
    seen on hardware.
- **(Chris), 2026-10-04: it creates a missing `beast/` or `spool/`,** as
  `adsb-receiver:adsb-operator 2770`, and reports it. A freshly formatted spare drive has neither, and
  nothing else could create them: the root of the new ext4 filesystem is root-owned `0755`. So "a
  spare drive formatted the same way works in the field with no config edit", above, was false as
  designed. This makes it true.
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

*Update 2026-10-04: nothing was named to produce that record; the preflights write nothing. **(Chris),
2026-10-04:** a refusal is read from systemd, and the writer's own state goes to a file it owns. See
"The archive writer" below, ruling (f).*

**The storage contract for the writer.** An interface, not a writer design~~: [§9l](#9l-rejected)'s
rejection of choosing the writer's language now stands~~. *Corrected 2026-10-04: the writer is now
designed, and its language chosen ([§9l](#9l-rejected)'s update); see "The archive writer" below. The
contract stands as written, with its OPEN item closed there.*

- Files are named in UTC, by the disciplined Pi clock, and rotated on 10-minute UTC boundaries.
- A file is named `.part` while open. It is fsynced at least every 10 s and on close, and renamed to
  its final name only after the closing fsync.
- A `.part` found at boot is torn. The preflight renames it `.torn`, ⛔ never deletes it, and reports
  it. Once renamed, a `.torn` file is a closed file like any other, so the writer's space backstop
  may expire it.
- **(Chris), 2026-10-04:** everything the writer creates on the drive is in group `adsb-operator`.
  Files are group-readable, directories are group-writable and traversable, and nothing has a
  sticky bit. ⚠️ The pull depends on it.
- ⚠️ **OPEN, for the writer's design (added 2026-10-04).** The preflight's guards against renaming a
  live `.part` (see the build choices at the end of this section) assume that the writer either
  holds its `.part` open or runs as `adsb-writer.service`. The contract does not say so yet. It also
  does not say whether the writer reuses a 10-minute file name after a crash.
  - *Closed 2026-10-04 by **(Chris), 2026-10-04**, ruling (d) in "The archive writer" below: the
    writer holds exactly one `.part` open for its whole life, as `adsb-writer.service`; files are
    named by the UTC second they were opened; and the writer never reuses a name.*
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

**Update 2026-10-05: the pulled archive is reviewed for decodability, not only for presence.
(Chris), 2026-10-05:** *"If we do not already have this in the plan, we need to add it: review the
recorded files and make sure we can decode them."* Every pulled file is reviewed at two levels, and
both are required:

- **(1) The container.** Every pulled file reads back complete under `tools/adsb-extract --check`,
  with its record counts, its first and last wall time, its events, and a counter fit.
- **(2) The content.** The frames decode as Mode S: the DF17 and DF18 frames pass the Mode S CRC,
  and resolve to ICAO addresses whose count is consistent with what `readsb` tracked at the time.
- ➡️ (1) does not show (2). `--check` reads the pcap records and fits the BEAST counter; it does not
  parse the Mode S message inside a frame (`check()` in `tools/adsb-extract`, read 2026-10-05).
- **(2) is not yet a tool.** On 2026-10-05 it was done by hand on the workstation: a 60 s window
  extracted with `tools/adsb-extract DIR TIME --window 30 --beast`, then a Python parse of about 40
  lines over that BEAST stream, which is not in the tree: the frame framing with its `0x1a` escapes,
  a histogram of downlink formats, the Mode S CRC with polynomial `0xFFF409`, and the ICAO address
  from bytes 1 to 3 of each DF17 or DF18 frame.
- 📋 **The tool half is owed:** a `--decode` mode in `tools/adsb-extract`, or a check in
  `tools/pull-archive` after the move, that reports the CRC-valid DF17 and DF18 frames and the
  distinct ICAO addresses per file, so that every pull ends with a decode verdict. Not yet designed
  in detail; which of the two homes is not ruled.

✅ **Seen 2026-10-05, by the coordinating session on the workstation,** on the six files pulled from
`mobile-adsb` at 20:21 Arizona time, recorded with the RTL-SDR Blog V3 stick: 2026-10-06 UTC, 02:36Z
to 03:21Z. This is the pull whose journal lines are under the pull window below.

- **(1)** All six read back `complete` under `--check`: 15,454, 55,242, 42,985, 25,694, 34,381 and
  6,992 records, each with its `clock` and `position` events. The first file shows a `readsb` restart
  as a second counter segment. The counter fits lie between −2.5 and +4.2 ppm, except one 23.6 s
  segment at −34.1 ppm right after a restart; the residual std is about 8 ms, and its max under
  60 ms. The last file ends with the `stop` event at 03:21:37.56Z, from the pull window's SIGTERM.
- **(2)** A 60 s window around 03:15:00Z held 3,522 BEAST frames, 2,297 short and 1,225 long. By
  downlink format: DF0 1,820; DF4 36; DF5 1; DF11 440; DF16 22; DF17 1,203. All 1,203 DF17 frames
  passed the CRC, and none failed. They resolved to 12 distinct ICAO addresses, the busiest with 249
  frames in the minute; `readsb` was tracking 13 to 17 aircraft in that period.

**The pull window. (Chris), 2026-10-04: the pull ends the recording session.** *Narrowed
2026-10-05, by the ruling of 2026-10-04 (night) at the end of [§9f](#9f-what-updatesh-does): a
window ends the recording session; the pull and the home check open one. ~~📋 The home check is not
built.~~* *Corrected 2026-10-09: the home check is built, in `f411815`, and applied on the 🎒
portable; see "The opener, as built" at the end of §9f.* Without this,
§9f's recording lock and a portable that is always recording would mean the portable never updates.
The window is a unit, `adsb-pull-window.service`, rendered by the pull step (below):

- `Conflicts=adsb-writer.service` and `After=adsb-writer.service`, so starting the window stops the
  writer first. The open `.part` is closed and renamed, and everything is pullable.
- `Wants=` the §9f update oneshot, which is itself `After=adsb-writer.service`. The same `update.sh`
  the timer runs therefore starts only after the writer has stopped, and it runs while the rsync
  does. ➡️ `update.sh`'s `flock` on the recording lock stays as the backstop: there are two
  mechanisms, the ordering and the lock.
- `Type=exec`, `ExecStart=/bin/sleep infinity`, `RuntimeMaxSec=2h` **(Chris: the 2 h cap)**.
- ~~`ExecStopPost=-/usr/bin/systemctl start adsb-writer.service`.~~
  *`ExecStopPost=-/usr/bin/systemctl --no-block start adsb-writer.service` (superseded 2026-10-04,
  as built: a blocking start from inside the window's own stop would wait for the writer's start
  job, which, through `Conflicts=` and `After=`, waits for the window's stop to finish, a deadlock
  until the stop times out. ⚠️ That is reasoned from systemd's ordering rules, not seen.)* When the
  window is stopped or
  reaches its cap, this starts the writer again. The `-` means a start that is refused does not mark
  the window failed.
- *Added 2026-10-04 (evening), (Chris): **closing the window waits for the update.**
  `ExecStop=` polls while `adsb-update.service` is `activating`, that is, running, and
  `TimeoutStopSec=45min` is above the update's own 40 min `TimeoutStartSec=`. So in the usual case
  the writer starts free to record, not blocked on the lock.*
  - *Why: any closer, the wrapper, Chris by hand or anything else, gets the same behavior, so there
    is one mechanism. Without it the writer would be active and blocked on the lock, writing
    nothing, which makes this section's "no file means the writer was not running" false, silently,
    at the one moment a human is there.*
  - *Not covered, and the writer then waits on the lock until the update ends, as before: the 2 h
    cap (⚠️ belief, not seen: at `RuntimeMaxSec=` systemd signals the window's process directly and
    skips `ExecStop=`); an update only queued, not yet running, when the window stops; and an update
    rolling back after a SIGTERM, which is `deactivating`, not `activating`, so the wait ends at
    once.*
  - *Rejected: a wait in the wrapper only, bounded by the cap, which a closer other than the wrapper
    would not get; and closing anyway, with the state reported in `status.json` and the banner.
    ➡️ What would change it: updates at home routinely over 20 min with Chris waiting at the
    terminal; then the wrapper gets a detach option, still with the unit's wait.*
- ⚠️ **On a reboot, the start inside `ExecStopPost=` is expected to be refused, and the writer
  returns at the next boot through `WantedBy=multi-user.target`.** That line is load-bearing: the
  writer must stay `WantedBy=multi-user.target`.
- ℹ️ `OnSuccess=` or `OnFailure=` may replace `ExecStopPost=`, if verified.
- ⚠️ **Unverified:** that `Conflicts=` plus `After=` orders the writer's stop before both the
  window's `ExecStart` and the wanted oneshot, in one transaction. The observable check is the order
  in the journal.
  - *Update 2026-10-04 (evening): still unverified. 📋 The step-2 success test in
    [§9f](#9f-what-updatesh-does)'s evening update, item 4, is to check it, from the journal and from
    the closed file's `stop` event.*
  - *Update 2026-10-05:* ✅ **the order was seen once, on one pull, 2026-10-05, on the 🎒 portable;
    not a guarantee across boots.** Read over SSH by the coordinating session from
    `journalctl -b -o short-iso -u adsb-pull-window -u adsb-writer -u adsb-update` (Arizona time,
    UTC−7):

    ```
    2026-10-05T20:21:37.601549-07:00 systemd[1]: Stopped adsb-writer.service
    2026-10-05T20:21:37.605153-07:00 systemd[1]: Starting adsb-pull-window.service
    2026-10-05T20:21:37.609042-07:00 systemd[1]: Starting adsb-update.service
    2026-10-05T20:21:37.631636-07:00 systemd[1]: Started adsb-pull-window.service
    ```

    Before those, at 20:21:37, the writer logged
    `closed 2026-10-06/20261006T032000Z.beast.pcap: 6989 frames, 242549 bytes`, then
    `stopped: SIGTERM`. Step 60's own `window_order` check read the same lines on the 2026-10-05
    bootstrap run and passed: *"the last window stopped the writer before the update started"*.
    ⚠️ The journal shows the order; it does not show whether the three jobs were one transaction.

**(Chris), 2026-10-04: the 2 h cap bounds only how long the pull keeps the writer off.** An update
that overruns the window is the lock's job. At the cap the window stops and the writer starts, waits
on the lock, and records once the update finishes. `Wants=` does not carry the window's stop to the
update oneshot, so nothing kills an update partway through.

*Update 2026-10-04 (evening), (Chris): a scoped correction, not a reversal. A window closed before
its cap now waits for a running update (the `ExecStop=` above), so the writer's absence may extend
by the update's remainder. No recording is lost either way, because the writer would have been
blocked on the lock, and the state is now honest: the writer inactive, with a reason, rather than
active and silent. At the cap the paragraph above holds as written, ⚠️ if, as believed and not seen,
the cap skips `ExecStop=`.*

- Rejected: `PartOf=` or `BindsTo=` from the update oneshot to the window, which would kill an
  update in the middle of applying it.
- Rejected: dropping the cap. The lock does nothing for a wrapper that died.

**The wrapper lives in this repo (Chris).** ~~📋 Its exact path is not yet chosen; `tools/pull-archive`
is an example.~~ *Corrected 2026-10-04 (evening), as built: it is `tools/pull-archive <ssh-target>
<destination-dir>`.* It runs on the workstation: `ssh <pi> sudo systemctl start adsb-pull-window.service`,
then the rsync move, then the stop, in a trap so the stop runs even when rsync fails. Afterward it
prunes the empty date directories (`find -mindepth 1 -type d -empty -delete`); the running session's
directory is never empty. ~~It fixes the destination,~~ *The destination is an argument, because a
workstation path cannot go in this public repo (corrected 2026-10-04, as built),* and it prints the
file count, the bytes moved and what remains.

*As built, 2026-10-04 (evening), the build's own choices after review; ⚠️ not yet run against the Pi:*

- *Before the window opens, it checks that rsync is on the workstation's `PATH` and that the
  destination is writable, so a pull that cannot move anything never ends a recording session.*
- *ssh sends keepalives (`ServerAliveInterval=15`, `ServerAliveCountMax=4`), so a link that died
  silently ends the ssh in about a minute instead of hanging. rsync has `--timeout=60`.*
- *It adds `--fsync` when the workstation's rsync has it (3.2.4 and later), so each file is on disk
  here before its source is deleted, and warns when it does not. Owner, group and mode are not
  copied.*
- *It prunes only while the writer is stopped, because a prune between the writer's `mkdir` and its
  open would kill the writer.*
- *Closing: the stop is the exact command the sudoers rule allows, and it waits on the rig while the
  update runs (the unit's `ExecStop=` above), printing the update's state every 10 s. Then it waits
  up to 60 s for the writer to be active **and** a `.part` written since the close began, the
  preflight's probe files not counting, and warns loudly if not: the pull is the one moment a human
  is there to see a writer that did not come back.*
- *The cap: if the window had already ended before the close, at its 2 h cap, the writer may have
  been recording since then, and a quiet sky need not touch its `.part`, so any `.part` counts.*

**The privilege is a narrow NOPASSWD rule (Chris).**

- `/etc/sudoers.d/adsb-receiver` grants group `adsb-operator` exactly two NOPASSWD commands:
  `systemctl start` and `systemctl stop` of `adsb-pull-window.service`. There are no wildcards.
  - *Update 2026-10-04 (evening), (Chris): **the rule is written `%adsb-operator,!adsb-receiver`.**
    The build's primary-group choice (at the end of this section) made `adsb-receiver`, the writer's
    user, a member of `adsb-operator`, so a group-wide rule let the writer start the pull window
    with no password: end its own session, or start an update. The writer parses data from the sky,
    so the path is a parser bug, not a design, but a service account holds no grant it never uses.
    sudoers' negation of a user in a user list excludes that user from the group match; the
    manual's warning about `!` concerns subtracting commands from `ALL`. Built, not yet run on
    hardware: `visudo -cf` accepts the rendered rule.*
  - *The second guard is `NoNewPrivileges=yes` on the writer's unit, so `sudo` cannot work from the
    writer's processes whatever any sudoers file says; see the writer's unit below. Two guards for
    one hazard: the unit cages the process, and the rule scopes the grant.*
  - *Rejected: a separate humans-only group, a second group to keep in step, for the reason a
    dedicated pull user is rejected below, and it still cannot separate the owner from the
    monitoring login, which is the same login; another primary group for `adsb-receiver`, which
    re-opens the 2026-10-04 choice and the setgid file-group design the pull depends on; and leaving
    it, the cheapest, but a sky-fed parser with a root grant it never uses is what a reviewer will
    keep finding.*
- ⛔ The pull step validates the rendered file with `visudo -cf` before installing it. A parse error
  in any `sudoers.d` file makes sudo refuse everyone, which on a remote rig is a reachability failure
  ([§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away)).
- **(Chris)** The installing user is added to `adsb-operator`. `05-config` does that (see the steps
  below), and it says so, and says that the change needs a fresh login.
- ➡️ The login can do two things as root: start and stop one unit. §9a is intact. The Pi
  authorizes an inbound key it already trusts, and holds no credential to anything.
- *Update 2026-10-04 (evening). (Chris), 2026-10-04.* ⚠️ **Once the pull step is installed, any login
  in group `adsb-operator` can start the pull window without a password, and starting it ends a
  recording session.** ⛔ The read-only monitoring login starts the pull window only on the owner's
  explicit go, given in that session. ~~📋 Ruled; the pull step is not built.~~ *Corrected
  2026-10-04, later that evening: the pull step is built, not yet run on hardware. No group, user or
  sudoers shape separates the monitoring login from the owner, because it is the owner's login; the
  ⛔ is policy.*
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

**The archive writer. Decided 2026-10-04, in the afternoon.** Chris ruled it through
multiple-choice questions. Each time he took the architecture consultation's recommendation, and
that choice is the decision, as at the top of this section. It follows the BEAST timestamp being
settled the same day ([§9i](#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader)).
📋 **Decided, ~~not built~~** *built*. ~~The writer, its unit, its step, the extractor and the CI test below are
not written. Every mechanism here is planned.~~ *Corrected 2026-10-04, later: `bin/adsb-writer`,
`setup/steps/40-archive-writer.sh` and the unit it renders, `tools/adsb-extract`, and CI's
`unittest` run over `tests/` are written. Step 40 ran on the 🎒 portable Pi, and the writer
records; see the end of this section, which also lists what has not yet been seen on the Pi.*

**R1, wall time and the container. (Chris), 2026-10-04.**

- **The writer stamps every frame when it receives it, from `CLOCK_REALTIME`**, the disciplined Pi
  clock. A BEAST frame carries no wall time (§9i).
- **The container is classic pcap,** with the nanosecond magic `0xa1b23c4d` and the linktype
  `DLT_USER0` (147). There is one record per BEAST frame. The record's payload is the frame exactly
  as received from port 30005, with its `0x1a` escaping and its 12 MHz counter intact.
  ➡️ Concatenating the payloads that begin with `0x1a` reproduces a valid BEAST stream.
- **Event records are payloads that do not begin with `0x1a`:** one UTF-8 line each.
  - `start`
  - `stop reason=…`
  - `connected <addr>`
  - `disconnected reason=…`
  - `clock <chronyc tracking offset and leap status>`, at start and at each rotation
  - `expired <path> <bytes>`
  - `resync`, on an unknown type byte
  - `position`, under R-pos below
- **A file is written for every interval the writer is up, even with zero frames.** No file means
  the writer was not running. A file of events alone means connected with an empty sky, or
  disconnected, and the events say which. Frames mean traffic. ➡️
  [BUILD.md §7](BUILD.md#7-software) rule 2, a gap and an empty sky being different facts, is met in
  the data itself.
- **Why:**
  - A time on every record needs no anchor, no reset detection, and no special case for the
    timestamp-0 frames.
  - Keeping the raw frame keeps the counter, for the spacing of frames inside one flush.
  - pcap records delimit themselves, so a `.torn` file reads cleanly up to its last complete record.
- ⭐ **Why this is not the "bespoke format" that [BUILD.md §9](BUILD.md#9--the-archive-and-feeding)
  item 2 refuses.** The data is BEAST and the container is pcap: both are existing formats, with
  their own tools (`capinfos`, `tcpdump -r`, Wireshark). What item 2 refused was a bespoke JSON
  archive, *"a format only you can read"*.
- **The cost** is about 16 bytes a record, ~12 MB an hour at today's ~92 frames/s. ⚠️ That is an
  estimate, not a measurement.
  - *Update 2026-10-04: ✅ measured on the writer's first closed file on the 🎒 portable Pi:
    1,317,614 bytes, 37,988 records, over 8 min 46 s, about 9 MB an hour. Seen by Claude on
    2026-10-04; see the end of this section.*
- Rejected:
  - **An anchor per file or per session, with counter offsets.** It needs reset detection,
    re-anchoring, a rule for the timestamp-0 frames and a rule for drift: logic that can fail in the
    field, to save about 8 bytes a frame.
  - **Rewriting the timestamp into the Radarcape GPS encoding.** It destroys the counter, drops the
    date, needs a status frame to switch readers into that mode, and puts byte-rewriting on the data
    path.
  - **A sidecar index file.** Two files per interval breaks every per-file mechanism already
    decided: `.part` to `.torn`, the rsync move, and expiry.
  - **In-band sync frames in BEAST grammar.** An invented type is a hidden bespoke extension, and a
    forged `0x34` can switch `readsb` into Radarcape mode.
  - **No custom writer: `nc` or `socat` into a file.** It cannot rotate on a frame boundary, fsync,
    rename, expire, or record a lost connection.
- ➡️ **What would change it:** a consumer that needs pure BEAST files on disk, with no strip step.

**R2, latency. (Chris), 2026-10-04: not measured absolutely, and no constant applied.** The kit
cannot measure the latency from the antenna to the writer: the GNSS puck is NMEA over USB, with no
PPS known, and NMEA-disciplined chrony is good to about 0.1 s. A documented error budget stands in
its place. ⚠️ **Every figure in it is a belief, not a measurement:**

- the Pi clock, disciplined by NMEA: ≲ 0.1 s;
- `readsb`'s USB buffering and demodulation: ~50–150 ms;
- `readsb`'s output flush interval: tens to hundreds of ms;
- the camera clock: ~0.1 s.

➡️ The sum is well under the ±1 s that matching to photographs needs. **The part that can be
measured is checked per file:** a linear fit of the counter against the wall stamp, giving the
slope in ppm and the residual's maximum and standard deviation. A growing residual, or a step, shows
the writer falling behind.

- Rejected:
  - **Subtracting an estimated constant.** It would present an assumption as a result.
  - **Buying PPS and a reference receiver.** Out of proportion to ±1 s.
  - **The ADS-B T bit.** The T bit marks position epochs synchronized to UTC, and transponders
    rarely set it, so a measurement built on it would rest on a flag most aircraft do not send.
    ⚠️ That is the architecture consultation's assessment, not verified here.
- ➡️ **What would change it:** a requirement tighter than about 0.3 s, which means PPS first; or an
  MLAT network's sync statistics, on the 🏠 stationary rig.

**R3, language and packaging. (Chris), 2026-10-04.** This answers
[§9i](#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader) and [§9l](#9l-rejected).

- **The writer is Python 3, standard library only, in one file, `bin/adsb-writer`.** The writer's
  step copies it to `/usr/local/bin/adsb-writer`, for the preflights' reason: `update.sh` will flip
  between two worktrees ([§9f](#9f-what-updatesh-does)), and a symlink into one would follow the
  flip.
- **The extractor is Python 3, standard library only, under `tools/`.** It runs on the workstation,
  on pulled data.
- **CI gains a standard-library `unittest`,** run on a small committed BEAST sample.
- **Why:** at ~92 frames/s the work is shaped by I/O. The cost per frame is estimated at well under
  1% of a core here; ⚠️ that is arithmetic, not a measurement. And no build step keeps the
  `git pull` model.
  - *Update 2026-10-04: ✅ a first measurement: 1.1% of a core, averaged over the writer's first
    30 s on the 🎒 portable Pi, start-up included (`ps`). Seen by Claude on 2026-10-04; see the end
    of this section.*
- Rejected:
  - **C, built on the Pi.** Every update compiles, a build failure becomes a rollback, CI cannot
    check it, and it buys nothing at this rate.
  - **A Go or Rust binary in the repo.** It sits where §9l's rejected image sits: it bakes in a
    version, cannot be reviewed as a diff, and is a binary blob in a public repo.
- ➡️ **What would change it:** a Python writer measured above ~25% of a core, or dropping frames, at
  the 🏠 stationary rig's real rate. Then the hot loop moves to C, with the same file format and the
  same unit.

**R-pos, the receiver's position. (Chris), 2026-10-04:** the archive records it. On the 🎒 portable,
a `position` event from `gpsd` is written at start and at each rotation. **Why:** the extractor's
"what was overhead" needs it, and the portable moves every shoot. ⚠️ The archive files never enter
this repo.

**R-ext, the extractor. (Chris), 2026-10-04: stage 1 is built with the writer.** Given a UTC window,
it gives per-frame times, as CSV, and a slice of plain BEAST. The default window is t ± 30 s, so the
CPR even and odd pairs survive. Stage 2, frames to positions, is deferred, and does not block
recording.

**The writer's rulings (a) to (g). (Chris), 2026-10-04,** accepted as a set:

- **(a) Its values are command-line arguments in `ExecStart=`,** such as `--min-free-gb`,
  `--source 127.0.0.1:30005` and `--archive <beast dir>`. The writer's step renders the unit from
  `station.yml` (render, diff, install, as for the mount unit). `station.yml` stays `root:root 0600`
  ([§9d](#9d-config)).
  - Rejected: widening `station.yml`'s mode. It carries keys and tokens.
  - ℹ️ An environment file is a workable alternative, not taken.
- **(b) A lost connection to port 30005 does not stop the writer.** It keeps its `.part` open,
  writes a `disconnected` event, retries every 1–2 s, writes `connected` when the port returns, and
  keeps rotating. ⛔ It never exits on a disconnect.
  - Rejected: exiting and relying on `Restart=`. That leaves a 30 s hole with no record, and restart
    flapping.
  - Rejected: logging to the journal only. The journal does not travel with the pull.
- **(c) On SIGTERM or SIGINT** (the pull window's `Conflicts=` is one), the writer finishes the
  current frame, writes `stop`, fsyncs, renames the `.part`, and exits `0`. The unit keeps the
  default `KillMode=control-group`, so the writer gets the signal directly. ⚠️ **Belief, not
  verified:** that `flock(1)` does not forward signals, and that the child inherits the lock's file
  descriptor.
- **(d) This closes the storage contract's OPEN item above.**
  - The writer holds exactly one `.part` open for its whole life, as `adsb-writer.service`.
  - Files are named by the UTC second they were **opened**, not by the interval's start:
    `beast/YYYY-MM-DD/YYYYMMDDTHHMMSSZ.beast.pcap`, with `.part` appended while open.
  - Rotation is on the 10-minute UTC boundary, on a frame boundary.
  - The writer never reuses a name. The final rename does not clobber: on a collision it falls back
    to `.1`, `.2` and so on, as the preflight does.
  - ⭐ **Why names by opening time:** a crash is not the only collision. A pull window stopped and
    restarted inside one interval would, with names by interval start, rename onto an existing
    closed file and overwrite real data.
  - ➡️ The extractor finds files by their name range, and always opens the file before the window
    too.
- **(e) Expiry runs at start, as already ruled, and at every rotation,** after the closed file is
  renamed. It is the same routine: the oldest closed files, `.torn` included, until free space is at
  or above `min_free_gb`, each one an `expired` event. **Why:** a 🏠 stationary writer never
  restarts. ➡️ "The writer is the only deleter" stands.
  - *Update 2026-10-04: **(Chris), 2026-10-04:** the routine checks first and deletes nothing when
    the threshold cannot be reached, and at rotation it spares the file just closed. See "When the
    drive is nearly full", below.*
- **(f) The writer owns a state file, ~~`/var/lib/adsb-receiver/writer.json`~~
  `/var/lib/adsb-receiver/writer/writer.json`,** on the SD card, written by tmp and rename, at start,
  at each rotation and at each event. It holds the state, the current file, the frames in this file,
  the last `clock` event and the last expiry list. ~~`update.sh`, not built, may copy it into
  `status.json`.~~ *Superseded 2026-10-04 (Chris): `status.json` points at this file, and never
  copies it. The writer rewrites it at every rotation and event, so a copy is stale by definition,
  and a reader would trust it. See [§9f](#9f-what-updatesh-does)'s evening update. ~~📋 Ruled; neither
  `update.sh` nor `status.json` is built.~~* *Corrected 2026-10-04, later that evening: both are
  built, and `status.json` carries the path in `writer_json`; not yet run on hardware.*
  - *Path adjusted by Claude 2026-10-04, pending Chris's approval of the diff:* the file lives in a
    directory, `/var/lib/adsb-receiver/writer/`, that the writer's step creates as
    `adsb-receiver:adsb-operator 2770`. The reason: on the 🎒 portable Pi, a read-only `stat` on
    2026-10-04 showed `/var/lib/adsb-receiver` as `root:root 0755`, and `id` showed `adsb-receiver`
    with primary group `adsb-operator`. So the writer could not create the temporary file there to
    rename. Widening that directory is not wanted.
  - **Refusals are read from systemd,** because the preflights write nothing:
    `systemctl show -p ActiveState,Result,ExecMainStatus adsb-writer`, and
    `journalctl -u adsb-writer -p err`.
  - ⭐ **This names the owner of the `recording: refused` record this section assumed earlier,
    which nothing produced.**
- **(g) The unit's commands:**
  - `ExecStartPre=+/usr/local/bin/clock-preflight`
  - `ExecStartPre=+/usr/local/bin/archive-preflight`
  - `ExecStart=/usr/bin/flock /run/adsb-receiver/recording.lock /usr/local/bin/adsb-writer …`
  - ⚠️ The `+` corrects a defect in this section's unit order as first written; see the correction
    there, below. That `+` runs a command as root under a unit's `User=` is a systemd fact ~~still to
    be verified on the Pi~~. *Corrected 2026-10-04: ✅ verified for systemd 259 on the workstation;
    see the correction there.* *Update 2026-10-04, later: ✅ and seen on the Pi's systemd 257, on
    step 40's first run; see the end of this section.*

**R5, build order. (Chris), 2026-10-04.**

- **The writer depends on port 30005 answering, not on how `readsb` got there.** The writer's step
  treats 30005 as a readiness fact, and the writer waits and records the gap, under (b). ⛔ It is
  never an install check on `10-decoder`.
- **`20-portable-clock`, `bin/clock-preflight`, and the writer with its step run on the Pi now,**
  because they do not touch the radio. Each is committed once it passes there. `10-decoder` waits for
  its Pi run on a new radio.
- ➡️ The rule holds that nothing reaches `main` before its run on the Pi passes. ~~The 🎒 portable
  tracks `main`~~ ([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable)).
  *Corrected 2026-10-05, (Chris): the 🎒 portable follows `stable` (§9g's 2026-10-05 update). This
  rule binds a commit to its Pi run, not the portable to `main`: the portable's proving run is by
  `--rev` or a checkout bootstrap before the push; its channel pull is the second run, of the same
  commit once green. ~~📋 Ruled, not built.~~* *Corrected 2026-10-10: built in `94e4f94`; the 🎒
  portable's channel pull is seen on `stable` ([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable)).*

**The writer's unit, and the recording lock.** 📋 ~~The writer itself is not designed
([§9i](#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader)); its unit is.~~ *Corrected
2026-10-04: the writer is now designed, ~~not built~~; see "The archive writer" above.* *Corrected
2026-10-04, later: built, and recording on the 🎒 portable Pi; see the end of this section.*

- **(Chris), 2026-10-04: the writer's unit holds the recording lock exactly as long as the writer
  runs:** `ExecStart=/usr/bin/flock /run/adsb-receiver/recording.lock <writer>`. The lock file is on
  tmpfs, its directory is created by a `tmpfiles.d` entry, and it joins §9i's fixed interfaces. The
  reason: §9l keeps the writer's language unchosen, so the lock lives in a unit file, not in the
  writer's code. And on tmpfs, a crash or a reboot leaves no stale lock.
  - *Update 2026-10-04: the first of those reasons has lapsed, because the writer's language is now
    chosen ("The archive writer" above, R3). The lock stays in the unit file: **(Chris), 2026-10-04**,
    ruling (g) keeps `flock` in `ExecStart=`.*
  - **(Chris), 2026-10-04: nothing writes into the lock file.** The holder is `flock`, which writes
    nothing, and having the writer write it would put lock bookkeeping into the writer's code.
    Instead, the login banner derives the holder: `lslocks` gives the PID and the path,
    ~~`ps -o unit= -p <pid>` the unit,~~ and `ps -o lstart= -p <pid>` the start time. `lslocks` resolves
    another user's lock path only when run as root, which the `/etc/update-motd.d/` scripts are.
    *Superseded 2026-10-04 (Chris): the banner reads the holder's unit from its cgroup,
    `/proc/<pid>/cgroup`, not from `ps -o unit=`. See [§9f](#9f-what-updatesh-does)'s evening update.
    ~~📋 Ruled; the banner is not built.~~* *Corrected 2026-10-04, later that evening: built, not yet
    run on hardware.*
    ~~⚠️ **Unverified:** `ps -o unit=` on trixie's `procps`.~~
    *Update 2026-10-04 (evening): moot once the banner reads the cgroup. This ⚠️ will be removed when
    that is built, not before.* *Struck 2026-10-04, later that evening: the banner is built and reads
    the cgroup, so nothing uses `ps -o unit=`. ⚠️ The cgroup read itself has not run on the Pi.*
  - Rejected: the lock in the writer's code.
  - Rejected: a lock file under `/var/lib`. It survives a power cut, so a stale lock would block
    updates.
- **(Chris), 2026-10-04: the lock is asymmetric.** `update.sh` keeps `flock -n`, and exits if the lock
  is held. The writer takes it blocking, with no timeout, so a writer started in the middle of an
  update waits, then records.
  - Rejected: `update.sh` waiting for the lock. A session lasts hours.
  - Rejected: a bounded `flock -w` for the writer. It adds a new failure, and the writer has nothing
    better to do than wait again.
- The unit's order: ~~`RequiresMountsFor=/var/lib/adsb-receiver/archive`~~ *`Wants=` and `After=` on
  the archive's mount unit (corrected 2026-10-04; see below)*; then `ExecStartPre=`
  `clock-preflight`, then `archive-preflight`; then `ExecStart=`, which is the wait for the lock and
  then the writer. `Restart=on-failure`, `RestartSec=30s`, `StartLimitIntervalSec=0`. So a preflight
  that fails at boot, for instance with no GPS lock yet, is retried until the clock is disciplined,
  and each refusal is recorded in `status.json`.
  - **Corrected 2026-10-04.** ⚠️ **As written above, the unit could never start.** `ExecStartPre=`
    runs as the unit's `User=` unless its command is prefixed `+`, and the writer runs as
    `adsb-receiver`. Both preflights refuse to run as anyone but root, and exit `1`, "run as root"
    (`bin/archive-preflight` line 53, `bin/clock-preflight` line 59). **(Chris), 2026-10-04,** ruling
    (g) in "The archive writer" above: the order is unchanged, and both preflights carry the `+`:
    `ExecStartPre=+/usr/local/bin/clock-preflight`, then
    `ExecStartPre=+/usr/local/bin/archive-preflight`, then
    `ExecStart=/usr/bin/flock /run/adsb-receiver/recording.lock /usr/local/bin/adsb-writer …`.
    ~~⚠️ The `+` behavior is a systemd fact still to be verified on the Pi.~~ *Corrected
    2026-10-04:* ✅ **The `+` behavior is verified for systemd 259,** from the `systemd.service(5)`
    man page on the workstation: *"If the executable path is prefixed with "+" then the process is
    executed with full privileges. In this mode privilege restrictions configured with User=,
    Group= … are not applied to the invoked command line (but still affect any other ExecStart=,
    ExecStop=, … lines)."* ✅ The writer's unit as rendered passes `systemd-analyze verify` on
    systemd 259. ~~⚠️ **Still unverified:** that the Pi's systemd 257 behaves the same. Step 40's
    first run on the Pi shows it.~~ *Corrected 2026-10-04, later: ✅ it does, for the `+` prefix.
    On step 40's first run on the 🎒 portable Pi, `systemd-analyze verify` printed nothing on
    systemd 257, and both `ExecStartPre=+` preflights ran as root and printed READY. Seen by Claude
    on 2026-10-04; see the end of this section.* Who records a refusal is ruling (f) there.
  - **Corrected 2026-10-04: the archive's mount is wanted, not required. (Chris), 2026-10-04,
    option A1.** ⚠️ **As first written, a missing drive stopped the writer silently, with no
    retry.** `RequiresMountsFor=` adds `Requires=` and `After=` on the mount unit. When the mount
    fails, as with the drive absent at boot, the writer's start job fails with result `dependency`
    before any process runs. The writer is left inactive (dead), with `Result=success` and
    `NRestarts=0`. `Restart=on-failure` never fires, because it governs processes that ran.
    ➡️ Booting without the drive and plugging it in later recorded nothing until a reboot or a
    manual start, and nothing showed it. Also: under `Requires=`, stopping the required unit stops
    the dependent, with no restart. ✅ Both seen by Claude on 2026-10-04 with stand-in user units on
    systemd 259; the Pi runs systemd 257. ➡️ "Retried until the clock is disciplined", above, held
    only for a preflight's refusal, until this ruling.
    - **The ruling:** the writer's unit carries `Wants=` and `After=` on
      `var-lib-adsb\x2dreceiver-archive.mount`, the archive's mount unit (the name read on the Pi),
      instead of `RequiresMountsFor=`. ✅ Each step of the mechanism was seen on systemd 259 with
      stand-in units, 2026-10-04:
      - a failed wanted unit does not fail the writer's start, so `ExecStartPre=+archive-preflight`
        runs and exits `2`, not ready;
      - `Restart=on-failure`, with `RestartSec=30s`, retries;
      - each retry enqueues a fresh start job for the wanted mount: four mount attempts for four
        writer attempts;
      - between retries the writer reads `activating` (`auto-restart`), not `failed`.
    - ➡️ **A drive plugged in late is mounted and recorded within about one cycle,** the device
      timeout (10 s, if the drop-in above works) plus 30 s, with no hands. The refusal is the
      preflight's on every attempt. The retry now covers a failed mount, as well as a preflight's
      refusal. The guard against writing to the SD card is `archive-preflight` plus the `0555`
      mount point (corrected above).
    - ℹ️ With the drive absent, the refusal that `archive-preflight` prints is *"no device is
      labeled adsb-archive"*, as seen on the Pi below, which it checks before the mount. *"Nothing is
      mounted"* is its refusal when the drive is there but its mount failed.
    - 📋 **Decided; ~~not yet run on the Pi~~** *built, and run on the Pi*. ~~The change is being made in~~
      *The change is in* `setup/steps/40-archive-writer.sh`. ~~Nothing above has been seen on the Pi's systemd 257.~~
      *Corrected 2026-10-04, later: step 40 ran on the 🎒 portable Pi, and the writer's unit, with
      `Wants=` and `After=` on the mount, came up and records on systemd 257; see the end of this
      section. ⚠️ The mechanism above is still not seen on the Pi: no failed mount, no late plug and
      no retry has happened there. The late-plug test in the pre-field checklist below shows it.*
    - Rejected:
      - **(A2) Also triggering the mount on hot-plug,** with the mount unit `WantedBy=` the
        by-label device unit. It shortens the gap to seconds and mounts inside the pull window. But
        it reverses this section's "No hot-plug and no automount", needs step 30 to re-enable a
        changed unit, and its trigger is provable only by a real plug. The field-loss rule does not
        need it.
      - **(B) Keeping `RequiresMountsFor=` and starting the writer when the device appears.** Any
        other mount failure, such as an fsck error or a corrupt drive, still leaves the writer
        silently dead, with no refusal recorded.
      - **(C) Surfacing it only.** It still needs a manual start in the field, which Chris's ruling
        on automation rules out.
      - **`/etc/fstab` with `nofail`.** `/etc/fstab` is on the denylist, and `nofail` does not
        change the writer's dependency type.
      - **An `.automount`.** This section ruled out an automount; autofs shows at the mount point,
        and a touch there with no drive blocks.
      - **A timer or a `.path` unit re-poking the mount.** Redundant with the restart loop.
    - ⚠️ **OPEN, a belief corrected.** The architecture consultation believed that the mount unit
      is `BindsTo=` its device, so that pulling the drive mid-session would stop the mount. Read on
      the Pi on 2026-10-04 with `systemctl show`: the mount unit has `Requires=dev-sda1.device` and
      an empty `BindsTo=`. ➡️ So a pull mid-session is unverified. The mount may stay on a vanished
      device. The writer would then exit on its write or fsync error, logging `fatal:` (⚠️ a belief:
      that the kernel returns an error rather than hanging), and keep retrying, refused, until a
      reboot. That is one lost session, fixed by a reboot, which the field-loss rule accepts. The
      pre-field checklist below tests it.
- **(Chris), 2026-10-04: `UMask=0007`** on the writer's unit, and later on the uploader's. Files are
  `0660`. Directories are `2770`, and inherit the setgid bit and group `adsb-operator`.
  - Rejected: `UMask=0027`. Its `2750` directories block deletion inside them.
  - Rejected: default ACLs, which are invisible to `ls -l`.
  - Rejected: `rsync --rsync-path='sudo rsync'`. That is root with arbitrary reach, and it undoes
    the two-command boundary.
- *Added 2026-10-04 (evening), (Chris): **`NoNewPrivileges=yes`** on the writer's unit. The kernel
  then refuses any privilege gain in the writer's process tree, so `sudo` cannot work from it,
  whatever any sudoers file says, including rules written later. It is the effect-level guard beside
  the sudoers exclusion in "The privilege" above. Step 40's verify reads `NoNewPrivs` from the
  running writer's `/proc/<pid>/status`, or, with no writer running, the loaded unit's
  `NoNewPrivileges`. Built, not yet run on hardware. ⚠️ Belief, to see on the Pi: both
  `ExecStartPre=+` preflights still print READY under it. They run as root and only drop to
  `adsb-receiver` for the write probe, which `NoNewPrivileges` allows. If one fails under it, that is
  the finding, and the sudoers exclusion alone stands.*
- ⭐ **The full verify that `update.sh` runs can never assert that the writer is active,** because
  `update.sh` holds the lock while it runs. See §9f, and the writer's step below.

**When the drive is nearly full. (Chris), 2026-10-04:** the writer expires the oldest closed files
and reports it loudly, in `status.json` and the login banner, rather than stopping. This is the
`archive.min_free_gb` backstop.

- On start, before it opens its first `.part`, the writer expires the oldest closed files, `.torn`
  included. It reports each one, and stops when free space is at or above `archive.min_free_gb`.
  - *Update 2026-10-04. **(Chris), 2026-10-04:** expiry also runs at every rotation, after the
    closed file is renamed, by the same routine, and each expired file is an `expired` event. A 🏠
    stationary writer never restarts. See ruling (e) in "The archive writer" above.*
  - *Update 2026-10-04: at start and at rotation, the routine now checks first and deletes nothing
    when the threshold cannot be reached, and at rotation it spares the file just closed; see the
    correction below.*
- ~~The only refusal on space is the writer's: still below the threshold with nothing left to expire.~~
  - **Corrected 2026-10-04. (Chris), 2026-10-04: check first, delete nothing.** ⚠️ **As ruled above,
    an unreachable threshold wiped the drive.** If `archive.min_free_gb` cannot be reached even by
    expiring every closed file (the threshold set wrong, the drive too small, or the drive filled by
    something other than the archive), the rule deleted every closed file on the drive, oldest
    first, and then refused. That lost un-pulled data for nothing, because the writer could not
    record anyway. Worse, after a refusal at rotation, the unit's `Restart=` brings the writer back
    30 s later, and the start-time expiry deleted even the file the rotation had kept. ➡️ That is
    loss that repeats, which the field-loss rule above does not accept. Found on 2026-10-04 by code
    review and the implementer, by reasoning; not seen on the Pi.
    - **The ruling:** before deleting anything, at start and at every rotation, the writer computes
      whether expiry can succeed: free space plus the total size of every file it may expire is at
      or above `archive.min_free_gb`. The files it may expire are the closed files, `.torn`
      included; at rotation, not the file just closed; never a `.part`.
      - If not, it deletes nothing and refuses loudly: state `refused` in its status, and the
        journal.
      - If so, it expires oldest-first as before, stopping at the threshold, and at rotation it
        spares the file just closed. ℹ️ That spare at rotation is new with this change.
    - ➡️ **A misconfigured threshold or a small drive costs recording, never data.**
    - 📋 **Decided; ~~not yet run on the Pi~~** *built, and the writer runs on the Pi*. ~~The change is being made in~~ *The change is in* `bin/adsb-writer`.
      *Corrected 2026-10-04, later: the writer ran on the 🎒 portable Pi; see the end of this
      section. ⚠️ No expiry and no refusal on space has happened there, so this rule is not seen on
      the Pi.*
    - Rejected:
      - **Always sparing the newest closed file at start too.** It stops the restart from deleting
        that file, but still deletes every older file before refusing.
      - **Keeping the rule as ruled.** An unreachable threshold wipes the drive's un-pulled data.
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
    adsb-operator` ~~lists the installing user~~ *lists at least one member besides `adsb-receiver`
    (corrected 2026-10-04; see the build choices at the end of this section)*; `/run/adsb-receiver` exists, with its mode, after
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
    mount unit enabled and active; `tune2fs -l` showing the label~~, `errors=remount-ro`~~ and a check
    on every mount; *the live mount's options showing `errors=remount-ro` (corrected 2026-10-04; see
    the build choices at the end of this section)*; ~~`lsusb -t` showing the drive at 480M~~ *the
    drive's USB link at 480 Mb/s, judged from the sysfs `speed` file of the USB device above the
    block device, with `lsusb -t` printed raw beside it (corrected 2026-10-04)*; `stat` showing `beast/` and `spool/` as
    `adsb-receiver:adsb-operator 2770`; the preflight, probing as `adsb-receiver`; and `df -h`, raw.
    Nothing about a writer or an update. ➡️ The drive is install tier, so a dead drive stops updates
    from applying until it is replaced ([§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect)).
  - A changed mount unit never restarts the mount. It sets `reboot_required` (§9f).
- **The writer's step** installs the writer's unit: the recording lock, the preflights, the restart
  policy, `UMask=` and ~~`RequiresMountsFor=`~~ *`Wants=` and `After=` on the archive's mount unit
  (corrected 2026-10-04)* above.
  - `--verify` (install tier, [§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect)): the
    unit file loads (`systemd-analyze verify`), and is enabled and not failed; both preflights exit
    `0` or `2`, never `1`; `lslocks` shows `/run/adsb-receiver/recording.lock` held by exactly one
    process whenever the writer or `update.sh` runs. Under `update.sh`, the holder is `update.sh`
    itself. ⛔ Never `is-active` of the writer (§9f).
  - *Update 2026-10-04.* ~~*📋 Its planned name is*~~ *It is `setup/steps/40-archive-writer.sh`,* portable-only
    for now, because its ~~`RequiresMountsFor=` target~~ *wanted mount unit (corrected 2026-10-04)*
    is built only by step 30, which is
    portable-only. *Under "The archive writer" above it also copies `bin/adsb-writer` to
    `/usr/local/bin/adsb-writer` (R3), renders the unit from `station.yml` (a), and creates
    `/var/lib/adsb-receiver/writer/` (f). Port 30005 is a readiness fact for it, never an install
    check (R5).* *Corrected 2026-10-04, later: the step is written, and its first run on the 🎒
    portable Pi exited `0`; see the end of this section.*
- **`NN-portable-pull.sh`, a new role-specific step** with `require_role portable`. Its number is
  assigned after both the writer's step and `update.sh`'s step. It installs the pull window, the
  sudoers drop-in, validated with `visudo -cf` first, and ~~the pull wrapper~~ *rsync (corrected
  2026-10-04, as built: the wrapper runs on the workstation, so no step on the Pi installs it; the
  step installs rsync, which the pull runs on the Pi's end)*.
  - *Update 2026-10-04 (evening), (Chris): the number is assigned. It is
    `setup/steps/60-portable-pull.sh`, after `50-updater`, `update.sh`'s step. See
    [§9f](#9f-what-updatesh-does)'s evening update. ~~📋 Neither is built.~~* *Corrected 2026-10-04,
    later that evening: both are built, not yet run on hardware.*
  - `--verify`: `visudo -cf` on the installed file; ~~`sudo -l -U <operator>` listing exactly the two
    commands~~ *see the correction below*; the window unit loaded. If the journal holds a previous window, it shows the writer's
    stop before `update.sh`'s first line; otherwise the verify warns that no window has run yet.
    The live exercise stays in the pre-field checklist.
    - *Corrected 2026-10-04 (evening), as built. The installed file must be `root:root 0440` and
      byte-identical to the rendered rule, and name the window with no wildcard. Then sudo itself is
      asked, with `sudo -l -U <user> <command>` for each command, which starts nothing: every login
      in `adsb-operator` must be allowed, the members `getent group` lists and every user whose
      primary group it is, which `getent group` does not list; and `adsb-receiver` must be refused,
      by name **(Chris, 2026-10-04)**. "Exactly the two commands" could not be checked as written:
      the owner's login also holds `(ALL) ALL`. ⚠️ **Limit: a yes from `sudo -l -U` does not tell
      NOPASSWD from a password grant,** so a login with `(ALL) ALL` passes on that alone. That the
      window's rule is NOPASSWD is proven by the rendered-file comparison, not by `sudo -l`. ⚠️ The
      exact refusal text and exit code are from sudo's documentation, not seen on the Pi. The
      journal-order check warns and never fails.*
    - *Update 2026-10-05: the journal-order check, `window_order`, failed inside the first window it
      ever checked: `tail` took EPIPE under `pipefail` when the journal after the window's start
      exceeded the pipe buffer. Fixed in `e019b29`, with one `sed` range and no pipeline. That is the
      failure behind the trap at the end of
      [§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic). ⚠️ The same
      `| head -n1` shape remains, reported and not fixed, in ~~`setup/bootstrap.sh:73`~~ `setup/bootstrap.sh:145` (guarded by
      `|| unit=''`), and ~~`setup/update.sh:237`~~ `setup/update.sh:299`, `setup/steps/20-portable-clock.sh:366` and
      `bin/clock-preflight:120` and `:125` (each guarded by `|| true`).*
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
figure, not a measurement. *Update 2026-10-04: ✅ measured at about 9 MB an hour, on the writer's
first closed file on the 🎒 portable Pi; see the end of this section.* USB 2 draws less from the Pi 4's ~1.2 A USB budget, and it avoids the
interference between USB 3 and nearby SDRs that is widely reported but ⚠️ not measured here. The
powered-hub rule ([BUILD.md §3d](BUILD.md#3d--the-second-radio--either-rig) part 14) is unchanged.

**The pre-field checklist,** the 🎒 portable's counterpart to §9h's pre-ship checklist:

- [ ] Three cold power cuts mid-recording. After each one: the mount returns; fsck is clean or says
  what it repaired; exactly one `.part` became `.torn`; every earlier closed file reads back.
- [ ] One boot with the drive pulled. The banner says refused within ~20 s, and nothing appears
  under the bare mount point.
- [ ] *Added 2026-10-04.* Pull the drive while recording. Expect a `fatal:` in the writer's
  journal, then the retry loop, refused; then see what a replug does. See the OPEN item in the
  writer's unit above.
- [ ] *Added 2026-10-04.* Boot with the drive absent, then plug it in. Expect the writer to record
  within about 40 s with no hands: the preflight's *"no device is labeled"* refusal, then a mount on
  a later retry, then a growing `.part`. This is the main claim of the A1 ruling in the writer's
  unit above. It is decided, and not yet seen on the Pi.
- [ ] A full pull from the workstation. The window starts; the writer reads inactive, and no `.part`
  remains; rsync moves everything; the wrapper stops the window; the writer is active again within
  seconds, and a new `.part` appears. The drive then holds only that `.part` and `lost+found`.
  *Added 2026-10-05, (Chris): the pull ends with the two-level review of the pulled files, the
  container and the content; see the 2026-10-05 update after "The pull" above.*
- [ ] The cap. Start the window and walk away. After `RuntimeMaxSec` the writer is running again,
  with nothing having stopped the window.
- [ ] An update inside the window. With a new commit on `main`, start the window: `applied-rev`
  advances, and the journal shows the writer's stop before `update.sh` began.
  *Note 2026-10-05: once the channel ruling of 2026-10-05
  ([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable)) is built, read "a new commit
  on `stable`". ~~📋 Ruled, not built.~~* *Corrected 2026-10-10: built in `94e4f94`, so it reads "a
  new commit on `stable`"; the 🎒 portable is seen following `stable` (§9g).*
- [x] *Added 2026-10-10.* The persistent journal across a reboot. Step 06 has run here
  ([§9f](#9f-what-updatesh-does), "A persistent journal, step `06-journal`"); reboot the rig a
  second time, and `journalctl --list-boots` shows two boots or more.
  *Done 2026-10-10: Chris rebooted the 🎒 portable at about 11:14, and `journalctl --list-boots`
  showed two boots, the earlier one readable; see §9f, "✅ A second reboot".*

➡️ If the cuts leave garbage in closed, renamed files, the answer is a different drive or an SSD on
the hub, not a different filesystem.

**(Chris), 2026-10-04: `/etc/fstab` joins the
[§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away) denylist.** A guard: no
step writes it under this design.

📋 **Not decided:** whether the 🏠 stationary rig's archive SSD is its boot device or a separate
mount. That belongs to the stationary build. ℹ️ **The consultation's lean, not a ruling:** a separate
`adsb-archive` partition on the SSD, so a full archive cannot fill the root filesystem and
`errors=remount-ro` cannot take the OS read-only. The cost is one partition at foundation time.

**Update 2026-10-04: the choices this section left open, made in the build.** Made in commit
`47ed4ed`, and approved by Chris on 2026-10-04: he said he had no problem with them.

- **`adsb-receiver`'s primary group is `adsb-operator`,** so anything it creates outside a setgid
  directory is still in group `adsb-operator`.
- **The `tmpfiles.d` entry also pre-creates the lock file,** `/run/adsb-receiver/recording.lock`,
  `0644`, `adsb-receiver:adsb-operator`, beside the `0755` directory. So `update.sh` and the writer
  never race to create it. ⚠️ That `flock(1)` can lock a file it opened read-only, which is what
  makes `0644` enough for both, is a belief, not checked.
- **The preflight is copied to `/usr/local/bin/archive-preflight`,** not run from the clone, because
  `update.sh` will flip between two worktrees ([§9f](#9f-what-updatesh-does)), and a symlink into one
  would follow the flip.
- **`errors=remount-ro` and journal checksums are judged from the live mount,** `findmnt`'s options
  and `/proc/fs/ext4/<dev>/options`, not from `tune2fs -l` as this section first worded it. The
  format commands set neither in the superblock: `tune2fs -l` showed `Errors behavior: Continue`.
  And on the Pi, `tune2fs`'s journal features read "none" while the kernel listed
  `journal_checksum`. The two places above that said `tune2fs -l` for these are struck through.
  ➡️ The same principle as [§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect): check the
  effect, not the setting. `tune2fs -l` is still read for the volume name and the maximum mount
  count. A missing `journal_checksum` warns, and does not fail the verify.
- **`min_free_gb: 4` on the 🎒 portable template,** read as GiB, the G that `df -h` prints. A
  backstop, not a budget. *✅ Confirmed in the code, 2026-10-04: `bin/adsb-writer` converts
  `--min-free-gb` with 2³⁰ bytes per unit, and `bin/archive-preflight` compares with 1073741824 bytes
  per unit, so the writer and the preflight count the same GiB.*
- **The preflight never renames a `.part` that any process holds open,** found by a scan of
  `/proc/*/fd`, **nor any `.part` while `adsb-writer.service` is active.** Only "active": the writer's
  own `ExecStartPre=` run of the preflight sees "activating", and that boot-time run is the one that
  should rename. On a name collision it uses `X.1.torn`, `X.2.torn`, and so on. ⚠️ These guards rest
  on the OPEN item in the storage contract above.
- **`05-config` repairs a wrong primary group or shell on an existing `adsb-receiver`, but never
  renumbers it,** because files on the drive carry the UID. A UID outside the system range stops the
  step, with a manual remedy.
- **(Chris), 2026-10-04: the installing user is `$SUDO_USER`,** added only when it is set and is not
  root. Under `update.sh` nobody is added, and the verify requires at least one member of
  `adsb-operator` besides `adsb-receiver`. ⚠️ **The consequence: if the group empties, every update
  fails `05-config`'s verify until someone runs the step by hand, with sudo.**

**✅ Verified on hardware, 2026-10-04: the first run.** On the 🎒 portable rig, under Raspberry Pi
OS Lite (trixie), from the pasted output:

- **The format, by hand.** `mke2fs 1.47.2` reported *"/dev/sda1 contains a exfat file system
  labelled 'USB DISK'"*, and wrote 15359992 4k blocks. `tune2fs` printed *"Setting maximal mount
  count to 1"*.
- **`05-config`.** The config was installed `root:root 600`. `getent` showed
  `adsb-receiver:x:999:985::/nonexistent:/usr/sbin/nologin`, and `adsb-operator:x:985:` with the
  installing user as its member. `/run/adsb-receiver` was `755` and the lock `644`, both
  `adsb-receiver:adsb-operator`. Every check printed PASS.
- **`30-archive-drive`.** `findmnt` showed
  `/var/lib/adsb-receiver/archive /dev/sda1 ext4 rw,noatime,errors=remount-ro`. The mount unit was
  enabled and active. `tune2fs` showed the volume name `adsb-archive` and a maximum mount count of 1.
  The link was 480 Mb/s. `beast/` and `spool/` were `adsb-receiver:adsb-operator 2770`. The
  preflight printed READY and exited `0`, with the probe ok. `df -h`: 58G, 2.1M used. Every check
  printed PASS.
- **The drive unmounted and pulled.** The preflight printed `NOT READY: no device is labeled
  adsb-archive. Is the archive drive plugged in?` and exited `2`.
- **The remount.** `systemd-fsck@dev-disk-by\x2dlabel-adsb\x2darchive.service` ran, and e2fsck
  printed *"adsb-archive has been mounted 1 times without being checked, check forced"*, then passes
  1–5. ✅ So the fsck on every mount works, and the explicit `Requires=` and `After=` on
  `systemd-fsck@` run it.
- **The group alone.** A fresh login, with no sudo, could list `beast/` (`drwxrws---`).
- **The kernel's mount options.** `/proc/fs/ext4/<dev>/options` listed `journal_checksum`, `barrier`,
  `data=ordered` and `nodiscard`.
- **No auto-mount.** Pi OS Lite boots to `multi-user.target`, and udisks2 is installed, but nothing
  auto-mounted the drive. Step 30's `findmnt --source` listed only the archive path.

**✅ Verified on hardware, 2026-10-04: steps 20 and 40, and the first recording.** On the 🎒
portable rig. Seen by Claude on 2026-10-04, over read-only SSH on the Pi or in output Chris pasted:

- **`20-portable-clock`, at about 22:00 UTC.** It exited `0` (Chris ran `echo $?`). The files on
  the Pi matched the repo by sha256; `setup/steps/20-portable-clock.sh` was
  `deb0a39e22442cea4eef14f6df985a22b7b97d46a01710554c360b90299bcdf8`. It installed
  `util-linux-extra`, rendered `/etc/default/gpsd` and `/etc/chrony/conf.d/gps.conf`, and installed
  `/usr/local/bin/clock-preflight`. Every install-tier check passed: `gpsd` has the puck by its
  `/dev/serial/by-id/` path, and NMEA arrives; `chrony` lists the GPS refclock; the RTC reads
  (`rtc-ds1307`, `hctosys` 1); `systemd-timesyncd` is not installed.
  - `clock-preflight` said NOT READY and exited `2`, because the step had just restarted `chrony`.
    Exit `2` passes the install tier ([§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect)).
    A minute later `chrony` was disciplined (leap status Normal), and the GPS refclock had reach 1.
- **`40-archive-writer`, at 22:41 UTC.** It exited `0`. The hashes matched the repo:
  `setup/steps/40-archive-writer.sh` `105fabb4792224dd…` and `bin/adsb-writer`
  `9a2bf5024e9d3082…` (prefixes).
  - ⚠️ After the runs, the header comments of `setup/steps/20-portable-clock.sh` and
    `setup/steps/40-archive-writer.sh` were updated to record them, so those two files' committed
    hashes differ from the ones above. ✅ Verified by Claude on 2026-10-04 by diffing the copies on
    the Pi against the tree: the only lines that differ are comments. `bin/adsb-writer`,
    `bin/clock-preflight` and `setup/lib.sh` are byte-identical to what ran.
  - It created `/var/lib/adsb-receiver/writer` as `adsb-receiver:adsb-operator 2770`, installed
    `/usr/local/bin/adsb-writer`, and rendered and enabled `adsb-writer.service`.
  - `systemd-analyze verify` printed nothing on the Pi's systemd 257. Both `ExecStartPre=+`
    preflights ran as root and printed READY: the clock offset 0.040 ms, with GPS reach 377; the
    archive mounted read-write, and the probe write as `adsb-receiver` ok. ➡️ That closes the ⚠️ on
    the Pi's systemd 257 in the writer's unit above, for the `+` prefix.
  - The unit came up active (running), with `NRestarts=0`, and one holder of the recording lock,
    `flock`.
- **The first recording.** `20261004T224114Z.beast.pcap` was opened at the writer's start, and named
  by the time it was opened (ruling (d)), mode `0660`, `adsb-receiver:adsb-operator`. It rotated
  exactly at 22:50:00 UTC into `20261004T225000Z.beast.pcap.part`, with no restart.
  - The closed file: 37,988 records (37,984 frames, and 4 events: `start`, `connected`, `clock` and
    `position`), 1,317,614 bytes over 8 min 46 s. ➡️ About 9 MB an hour, measured, beside the ~10
    and ~12 MB an hour estimated in this section.
  - `tools/adsb-extract --check` on it: complete; 5 all-zero keepalives, not fitted; one segment of
    37,979 frames over 525.5 s; the counter at +0.1 ppm against 12 MHz; residual max 59.81 ms, std
    8.06 ms. ➡️ That is R2's per-file check, and it is well inside ±1 s. ⚠️ The +0.1 ppm disagrees
    with the −25 ppm in [§9i](#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader);
    see the correction there.
  - The writer's CPU: 1.1% of a core, averaged over its first 30 s, start-up included (`ps`). A
    first measurement, beside R3's and [§3](#3--cpu-is-the-binding-constraint-not-power)'s estimates.
- 📋 **Not yet seen on the Pi:** the late-plug test, the drive-pull test, any expiry, any refusal on
  space, ~~a `readsb` restart in the middle of a file~~ ~~, and a pull window~~. *Corrected 2026-10-05: a
  pull window ran on the Pi on 2026-10-05 at 20:21 Arizona time; the journal lines are in this
  section's pull window, under the ⚠️ on `Conflicts=` and `After=`, in its 2026-10-05 update.*
  *Corrected 2026-10-05: a `readsb` restart in the middle of a file was seen, as the second counter
  segment in the 02:36Z file of 2026-10-06 UTC; see the decodability review after "The pull".*
  ~~`10-decoder` has not run on
  the Pi; it waits for a new radio (R5).~~ *Corrected 2026-10-05: the new radio, an RTL-SDR Blog V3,
  arrived on 2026-10-05, and `10-decoder` ran on the Pi that day
  ([§9j](#9j--verified-on-hardware-2026-10-03)).*

### 📋 Consequences for the other docs (not yet made)

| Where | Now says | Needs |
|---|---|---|
| BUILD.md §7 / §8 step 1 | — | `10-decoder` ~~may install `readsb` from apt (whether the 2024 snapshot is current enough is still to decide) and pin only~~ *builds `readsb` from source at a pinned commit, with RTL-SDR support, against the packaged `librtlsdr` 2.0.2, and does not install it from apt (2026-10-04, [§9j](#9j--verified-on-hardware-2026-10-03)). It pins* `tar1090`'s installer by SHA |
| BUILD.md §4 | ⚠️ "Installing either from `apt` can quietly pull an old one back in" | Re-examine. ~~On trixie the packaged `readsb` links the same 2.0.2 library ([§9j](#9j--verified-on-hardware-2026-10-03))~~ *Corrected 2026-10-04: on trixie the packaged `readsb` links no `librtlsdr` at all. It is built without RTL-SDR support and cannot drive the stick ([§9j](#9j--verified-on-hardware-2026-10-03)). Lines 149 and 153–154 make the same linking claim. On forky, whose `readsb` 3.16-2 depends on `librtlsdr0`, the concern applies again* |
| README "The three traps that cost the most time", trap 1, lines 39–40 | "`readsb`/`dump1090-fa` link against it, so installing either from `apt` can quietly undo the fix" | *Added 2026-10-04.* The same correction as the BUILD.md §4 row above: on trixie the packaged `readsb` links no `librtlsdr` and cannot drive an RTL-SDR ([§9j](#9j--verified-on-hardware-2026-10-03)) |
| BUILD.md §4, lines ~~169–171~~ *183–185 (corrected 2026-10-10)* | "If it says R820T2, or reports nothing, the old driver is still in the path" | The inference "R820T2 means the old driver" is wrong in at least one case. A stick reporting R820T on a current library may be a counterfeit, not an old driver ([§9j](#9j--verified-on-hardware-2026-10-03)) |
| BUILD.md §4, the code block (lines 152–164) and the paragraph after it (lines 175–178) | "`sudo apt purge '^librtlsdr'`" … "then build current librtlsdr from osmocom/rtl-sdr"; "Build from `osmocom/rtl-sdr`, not `rtlsdrblog/rtl-sdr-blog`" | *Added 2026-10-10.* The steps do the opposite: `00-drivers` installs the packaged `rtl-sdr` from apt, and `10-decoder` installs `librtlsdr0` and `librtlsdr-dev` from apt and builds `readsb` against the packaged 2.0.2 ([§9j](#9j--verified-on-hardware-2026-10-03)). No step purges `librtlsdr` or builds it from source. `setup/steps/10-decoder.sh:98–101` sends the reader to this table for it, which had no row until this one. *Done 2026-10-10: BUILD.md §4 carries a dated correction after the block (lines 166–173) saying what the steps do; the recipe is kept as written beside it.* Still owed, in code: `10-decoder.sh:98–101` then calls BUILD.md §4 "queued for a rewrite", and gives "no V4 is coming" as a reason, which no ruling in this file says: (Chris), 2026-10-03, ruled to buy a genuine V4 ([§9j](#9j--verified-on-hardware-2026-10-03)) |
| README "The three traps that cost the most time" / BUILD.md §3a parts table, row 3 | — | Warn that counterfeit V4s are sold, Amazon included ([§9j](#9j--verified-on-hardware-2026-10-03)). The check is `rtl_eeprom` (its Manufacturer and Product strings) plus `rtl_test` naming the R828D. Buy from RTL-SDR Blog or a seller listed on rtl-sdr.com. *Corrected 2026-10-05: the EEPROM strings do not tell a counterfeit from a V3, because both read `Realtek` / `RTL2838UHIDIR` ([§9j](#9j--verified-on-hardware-2026-10-03)), so the tuner name is the only tell. And since 2026-10-05 no verify opens the stick, so that check is the hand check in BUILD.md §8, not a step's* |
| BUILD.md §7 | "uploader (yours to write)" | It ships in this repo |
| BUILD.md §8 | Steps with no scripts | Name each step's script, and add the [§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away) pre-ship checklist |
| BUILD.md §2 | "reachable over something like Tailscale" | Tailscale key expiry, and disabling it. ⚠️ The 180-day default is an unverified claim from the consultation |
| BUILD.md §3c | Stationary parts list | Add a powered hub or a low-draw SSD enclosure, and a smart plug |
| `config/station.stationary.example.yml` | — | Add `update.soak_days`, `notify.discord_webhook` and `notify.healthcheck_url`. ⛔ The portable template must not get them |
| `config/station.stationary.example.yml` | `archive.path: /mnt/ssd/beast` | Reconcile with `/var/lib/adsb-receiver/archive` in [§9i](#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader). *Settled 2026-10-04 ([§9m](#9m--the-portable-rigs-archive-drive)), for both rigs: the path is the §9i interface path, and `archive.path` is replaced by a comment naming it. See the templates row below. What backs that path on the stationary rig is not decided. Done 2026-10-04, in commit `47ed4ed`* |
| README "What is here" and "Status" | Docs and two templates; "Documentation, today" | `setup/`, and the software's state |
| `.gitignore` | `config/*.local.yml`, with no comment | Document what it is for, or drop it |
| BUILD.md §2, the **Job** row | 🎒 "Log tracks at the location you are shooting from"; 🏠 "Continuous archive, feeding, ACARS harvesting" | *Added 2026-10-04.* Both rigs archive everything, for matching to photographs by UTC time (**(Chris)**, 2026-10-03, [§9m](#9m--the-portable-rigs-archive-drive)) |
| BUILD.md §3b | Portable parts 6–10, with nothing to archive onto | *Added 2026-10-04.* A USB flash drive for the archive, formatted ext4 by hand, in a black USB 2 port ([§9m](#9m--the-portable-rigs-archive-drive)) |
| BUILD.md §7, the 🎒 portable block | "uploader (yours to write) → reads aircraft.json + gpsd, spools to disk; ships on the next network, never in the field" | *Added 2026-10-04.* The same line as the earlier "BUILD.md §7" row, which says the uploader ships in this repo; make both changes together. An archive writer on the portable too, writing to the archive drive, with the spool on that drive. The data is moved off by a pull from your workstation over your home network, and `uploader.endpoint` stays null ([§9m](#9m--the-portable-rigs-archive-drive)) |
| BUILD.md §8 | No archive step | *Added 2026-10-04.* Name `30-archive-drive`, after the clock step and before the writer. ~~Add formatting the drive as a human gate,~~ *Corrected 2026-10-04 (evening): on the 🎒 portable, formatting is no longer a human gate; the bootstrap's foundation tier formats under a strict rule, and a human formats only when it refuses ([§9e](#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)). BUILD.md §8 now says what the one command does without asking, the format among it. Still owed:* and the 🎒 pre-field checklist ([§9m](#9m--the-portable-rigs-archive-drive)) |
| BUILD.md §9, the heading and first line | "🏠 The archive, and feeding"; "⛔ This is the stationary rig's job, and it is why that rig exists." | *Added 2026-10-04.* The archive is no longer the stationary rig's alone: both rigs archive everything (**(Chris)**, 2026-10-03, [§9m](#9m--the-portable-rigs-archive-drive)) |
| README "The idea worth stealing", the **Job** row, line 22 | 🏠 "Continuous archive, feeding aggregators, harvesting ACARS" | *Added 2026-10-04.* The same as the BUILD.md §2 row above: both rigs archive everything |
| `config/station.portable.example.yml` and `config/station.stationary.example.yml` | Portable: no `archive:` block, `spool_dir: /var/lib/adsb-receiver/spool`. Stationary: `archive.path: /mnt/ssd/beast`, `archive.format: beast` | *Added 2026-10-04 ([§9m](#9m--the-portable-rigs-archive-drive)).* The portable gets an `archive:` block with `archive.label` (default `adsb-archive`) and `archive.min_free_gb`, and the BEAST ⛔ ([BUILD.md §9](BUILD.md#9--the-archive-and-feeding) item 2) as a comment. ⛔ The stationary does not get `archive.label` yet. The archive-drive step is portable-only until the stationary rig's SSD question is decided. The stationary changes in one place: `archive.path: /mnt/ssd/beast` is replaced by a comment naming the §9i interface path and pointing at that open question. ⛔ It keeps `enabled`, `format: beast` with its ⛔, `retention_days` and `min_free_gb`. The portable gets no `retention_days`, and says why: the pull moves the data off, and the `min_free_gb` backstop is the only other deletion. The portable's `uploader.spool_dir` becomes `/var/lib/adsb-receiver/archive/spool`. ⛔ The portable still must not get `update.soak_days` or `notify.*`. *Done 2026-10-04, in commit `47ed4ed`, for both templates* |
| BUILD.md §8 | No pull step | *Added 2026-10-04.* Name the 🎒 pull step, `NN-portable-pull`, after both the writer's step and `update.sh`'s step. ~~Its number is not assigned yet~~ *Its number is assigned: `60-portable-pull` (2026-10-04, evening)* ([§9m](#9m--the-portable-rigs-archive-drive)) |
| README "What is here" | No `tools/` path | *Added 2026-10-04.* The new top-level `tools/` path for the pull wrapper. ~~Its exact name is not chosen yet~~ *It is `tools/pull-archive` (2026-10-04, evening)* ([§9m](#9m--the-portable-rigs-archive-drive)) |
| PLAN.md [§9k](#9k-the-first-deliverable-in-order), items 2 and 3 | 2: "`05-config` + `10-decoder`"; 3: "`update.sh` + the timers + `status.json` + the job that advances `stable`" | *Added 2026-10-04 ([§9m](#9m--the-portable-rigs-archive-drive)).* Item 2: `05-config` is widened. It creates the `adsb-receiver` system user, the `adsb-operator` group with the installing user, and the `tmpfiles.d` entry for `/run/adsb-receiver`. Item 3: `update.sh` needs its own `TimeoutStartSec`, and it must roll back on SIGTERM ([§9f](#9f-what-updatesh-does)). *Update 2026-10-04: item 2's `05-config` half is done, in commit `47ed4ed`; `10-decoder` is not. Item 3 is not done* *Update 2026-10-04 (evening): item 3 is built, with its own `TimeoutStartSec=` and a rollback on SIGTERM, not yet run on hardware. §9k item 3 now names `bootstrap.sh`, `50-updater` and `60-portable-pull` too* *Update 2026-10-10: item 3 has run on the 🎒 portable; §9k item 3 says where it is recorded. No rollback on SIGTERM is recorded on hardware* |
| `setup/lib.sh`, `parse_args` and `require_role` | `--verify` and `--help` only; `require_role` always dies on a mismatch | *Added 2026-10-04.* `parse_args` gains `--skip-other-role`, and `lib.sh` gains the constant `ADSB_RC_OTHER_ROLE`, an unused value below 126 and not 3. With the flag, `require_role` on a mismatch logs the skip and exits that code. `require_absent` is unchanged ([§9b](#9b-one-bash-script-per-build-step)). *Done 2026-10-04, in commit `47ed4ed`. `ADSB_RC_OTHER_ROLE` is 100* |
| `.github/workflows/ci.yml` | Two step checks: the denylist grep, and `parse_args` plus `verify()` in every step | *Added 2026-10-04.* A third check: in every step containing `require_role`, the first non-comment command after `parse_args` and `require_root` is the `require_role` call ([§9g](#9g-channels-portable-tracks-main-stationary-tracks-stable)). *Done 2026-10-04, in commit `47ed4ed`* |
| BUILD.md §8 step 2 | "Confirm `gpsd` has a fix, `chronyc sources` shows GPS disciplining the clock, and the Pi still knows the time after a power cycle **with the network unplugged**" | *Added 2026-10-04.* When this step names `20-portable-clock`, say that the script's verify checks only the install tier, and that these checks stay human gates under the sky ([§9c](#9c-every-step-ends-in-a-check-of-the-observable-effect)) |
| `setup/lib.sh`, `ADSB_DENY_PATHS` | No `/etc/fstab`; its comment says the list is "Written as in the PLAN §9h table" | *Added 2026-10-04.* Add `/etc/fstab` (**(Chris)**, [§9h](#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away)). CI reads this array for its grep of `setup/steps/`. *Done 2026-10-04, in commit `47ed4ed`* |
| BUILD.md §8 | No `06-journal` | *Added 2026-10-10.* Name the shared step `06-journal` ([§9f](#9f-what-updatesh-does), "A persistent journal, step `06-journal`"): the journal made persistent, capped at `SystemMaxUse=200M`; journald restarted only under `update.sh`; run by hand, the step installs and warns, and the drop-in loads at the next boot. *Done 2026-10-10: BUILD.md §8 names it, after the list of what the one command does without asking.* Still owed, in code: the header of `setup/steps/06-journal.sh`, line 4, says "BUILD.md: none yet (no section, no §8 step)" |
