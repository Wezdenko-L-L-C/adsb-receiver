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
