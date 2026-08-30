# The second radio — ATC audio and ACARS

Two more receivers doing jobs the 1090 MHz chain cannot. **ATC audio** gives you what was said;
**ACARS/VDL2** gives you a second, independent witness to what an airframe *is*.

⭐ **They do not both go on the same rig:**

| Radio | Rig | Why there |
|---|---|---|
| **Airband / ATC audio** | 🎒 **Portable** | The audio only earns its keep next to whatever else you are recording. Tower audio captured at home matches nothing you shot |
| **ACARS / VDL2** | 🏠 **Stationary** | Value comes from **continuous** harvesting — months of registrations accumulating into a cross-reference. A few hours in the field is a rounding error |

➡️ **So neither rig runs three dongles.** Portable is 1090 + airband; stationary is 1090 + VDL2.
[§5](#5-what-a-second-dongle-does-to-the-pi) applies to both at two dongles, and bites hardest if
you ever stack a third.

---

## 1. Each radio is its own dongle

**One RTL-SDR sees ~2.4 MHz at a time.** ADS-B is at 1090 MHz, airband at 118–137 MHz, VDL2 at
136.9 MHz. These are not one radio's problem, and no amount of software makes them so.

| Rig | Dongle | Tuned to | Decoder |
|---|---|---|---|
| 🎒 Portable | 1 | 1090 MHz | `readsb` |
| 🎒 Portable | 2 | 118–137 MHz airband | `rtl_airband` |
| 🏠 Stationary | 1 | 1090 MHz | `readsb` |
| 🏠 Stationary | 2 | 136.650–136.975 VDL2 | `dumpvdl2` |

⚠️ **A general-purpose dongle is a good VHF radio and a middling 1090 one.** The **V4** improves on
the V3 here — its triple-tuned R828D front end notches broadcast FM and DAB, which is most of what
swamps a receiver near a city — but it still carries no 1090 SAW filter, so a **1090 bandpass**
inline is still the upgrade that matters for ADS-B.

➡️ **If you own one filtered stick and one V4, put the filtered stick on ADS-B** and let the V4 do
the VHF work.

ℹ️ **HF works differently on the V4, and better.** The V3 reached HF by **direct sampling**, with no
filtering and Nyquist folding around 14.4 MHz throwing up spurious signals. The V4 has a
**built-in upconverter** (SA612 mixer, +28.8 MHz) instead: no folding, real gain control on HF, and
front-end filtering. ⛔ **Direct-sampling mode does not exist on the V4** — any guide telling you to
enable it was written for a V3. Both have a software bias tee (`rtl_biast`) for an antenna-end LNA.

---

## 2. Your 1090 antenna will not hear any of this

A FlightAware 26" is a narrowband collinear cut for 1090 MHz. At 118 MHz it is deaf. Options,
cheapest first:

| Antenna | Covers | Notes |
|---|---|---|
| **RTL-SDR Blog dipole kit** | Airband, with each leg at ~60 cm | ⭐ Half-wave at 120 MHz. Genuinely fine for a nearby tower, and you may already own one |
| **Discone** (e.g. Diamond D130J) | 25 MHz – 1.3 GHz | ⭐ One antenna feeds airband **and** VDL2. Mediocre at 1090 — keep the collinear for that |
| Dedicated airband antenna | 118–137 only | Better airband gain, no VDL2 headroom |

⚠️ **The filter that matters here is not the AM one.** Near an airport the front-end killer is
**FM broadcast at 88–108 MHz**, immediately adjacent to airband. An **FM band-stop/notch filter**
(~$12) is the fix. A broadcast-AM reject high-pass cuts below ~2 MHz and is irrelevant to both
airband and 1090 — and on a V4 it is redundant with the upconverter's own front-end filtering.

---

## 3. ATC audio — `rtl_airband` (portable)

Purpose-built for this, runs well on a Pi, monitors **several channels at once** within one
dongle's slice, squelch-gated, and writes timestamped files or streams to Icecast. Run tower,
ground and approach simultaneously.

⭐ **This composes with timestamp correlation rather than sitting beside it.** `rtl_airband`
timestamps its recordings and the Pi's clock is GPS-disciplined ([BUILD.md §6](BUILD.md#6-the-clock-gps-and-an-rtc)),
so if you are already joining camera frames to ADS-B samples by time, the same join yields the
frame, the track, *and the tower transmission covering that aircraft* — on one clock. That is a far
stronger record than any of the three alone, and it falls out of the architecture rather than
needing new machinery.

### ⚠️ Legality is not uniform

| | ADS-B | Airband |
|---|---|---|
| **US** | Legal | ✅ Legal to monitor **and publish** — ECPA exempts aviation communications; it is what LiveATC does |
| **UK** | Legal | ⛔ **An offence** under the Wireless Telegraphy Act 2006. Rarely prosecuted, still the law |

➡️ **Leave the airband dongle at home when travelling to the UK.** The 1090 chain travels fine.
⚠️ This table is not exhaustive — check the jurisdiction you are actually going to.

---

## 4. ACARS / VDL2 — a second witness to the tail number (stationary)

"ARINC messages" in practice means **ACARS**, carried over four bearers with very different yields:

| Bearer | Frequency | Decoder | Worth it? |
|---|---|---|---|
| **VDL Mode 2** | 136.650–136.975 | **`dumpvdl2`** | ⭐ **Start here.** Most US airline traffic has migrated to it, and all four channels fit inside one dongle at once |
| VHF ACARS (POA) | 131.550 + others | `acarsdec` | Legacy traffic. 5.4 MHz away from VDL2, so it needs its own dongle. Add later, if ever |
| HFDL | 2–22 MHz | `dumphfdl` | Oceanic. The V4's upconverter does this properly; low yield inland |
| SATCOM Aero | ~1.5 GHz L-band | `JAERO` | Needs a patch antenna aimed at a satellite. A project in itself |

⭐ **Why this is more than a novelty.** ACARS and VDL2 carry the **registration explicitly**, plus
flight number and often the type. ADS-B gives you a hex and a callsign that you then *resolve* to a
registration through a lookup — a chain with a failure mode.

➡️ **ACARS hands you the tail number from the aircraft itself.** That is a second independent
witness on the same airframe: a natural cross-check, and a way to catch a bad hex→registration
lookup that would otherwise go unnoticed.

ℹ️ **Consider feeding [airframes.io](https://airframes.io)**, for the same reason you would feed an
ADS-B aggregator — it is the rent for a public good this kind of project leans on.

---

## 5. What a second dongle does to the Pi

Adding radios is what destabilises a working receiver. All four of these have bitten people:

1. ⛔ **You need a powered USB hub at two dongles plus GPS.** Each dongle draws ~300 mA and a Pi
   4's entire USB budget is ~1.2 A. The 🎒 portable rig — two dongles *and* a GPS puck — runs
   closest to the edge, and the symptom is undervoltage, which
   [BUILD.md §1](BUILD.md#1-which-pi) already warns *looks exactly like an antenna problem*. The
   🏠 stationary rig has mains behind it and more slack.
2. ⛔ **Set unique serials** — `rtl_eeprom -d 0 -s 1090`, and so on. Otherwise USB enumeration
   order shuffles at boot and your decoder grabs the airband dongle. This is *the* classic
   multi-dongle bug, and it presents as **"ADS-B stopped working for no reason"**.
3. ⚠️ **Space them on short USB extension leads.** Stacked directly, dongles heat each other and
   drift — and the extension also moves them away from the Pi's own USB noise.
4. ⚠️ **CPU becomes a real load**: `readsb` ~0.5 core, `rtl_airband` ~0.4, `dumpvdl2` ~0.5. A Pi 4
   fits it with room, but the fan case stops being optional.

⚠️ **Recompute the power budget before an all-day session** —
[BUILD.md §5](BUILD.md#5-power-portable-only) carries the figures for a portable rig with a second
radio and a hub.
