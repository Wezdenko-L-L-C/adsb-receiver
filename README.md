# adsb-receiver

How to build a pair of Raspberry Pi ADS-B receivers, one that travels and one that stays put, and
the software that runs them.

This is a **build guide that ships its own software**. ~~⚠️ The software is not written yet; see
[Status](#status).~~ *Corrected 2026-10-10: the software is written. One command,
[`setup/bootstrap.sh`](setup/bootstrap.sh), builds a rig by running the step scripts
`setup/steps/00`–`70` through [`setup/update.sh`](setup/update.sh), which then keeps it current;
[`bin/`](bin/) holds what runs on the rig, and [`tools/pull-archive`](tools/pull-archive) and
[`tools/adsb-extract`](tools/adsb-extract) run on a workstation. The 🎒 portable rig is built from
it (first bootstrapped 2026-10-04) and running, updating itself from the `stable` branch. The 🏠
stationary rig is not built yet.* The guide exists because most ADS-B instructions stop at
"it decodes aircraft" — and the failures that cost real time happen after that point, silently, in
ways that look like a bad antenna.

---

## ⭐ The idea worth stealing: two rigs, not one

Most guides describe *a* receiver. If you both carry a receiver into the field **and** want a
continuous archive at home, those are two machines with opposite requirements, and building one
box to do both gets both jobs wrong — the archive grows a hole every time you leave, and the field
rig carries weight it never needed.

| | 🎒 **Portable** — goes out | 🏠 **Stationary** — stays home |
|---|---|---|
| **Job** | Log tracks where you actually are | Continuous archive, feeding aggregators, harvesting ACARS |
| **Runs for** | Hours, on battery | 24/7, on wall power |
| **Position** | ⚠️ Changes every session | ✅ A constant — survey once, put it in config |
| **Network** | ⛔ None | ✅ Yes |
| **Clock from** | **GPS** — there is no network to ask | **NTP** — better than the GPS puck, and free |
| **Antenna** | Magnetic whip on a car roof | Collinear up a mast, as high as you can get it |

*Added 2026-10-10: the **Job** row is no longer the whole split. Both rigs archive everything, for
matching to photographs by UTC time (**(Chris)**, 2026-10-03,
[PLAN.md §9m](docs/PLAN.md#9m--the-portable-rigs-archive-drive)). The 🎒 portable records onto its
own archive drive, and the data is moved off by a pull from a workstation,
[`tools/pull-archive`](tools/pull-archive).*

➡️ **The stationary rig needs neither a GPS puck nor an RTC.** This is the single most common
over-buy, and it comes from copying a portable parts list out of symmetry. At a house there *is* a
network: NTP gives ~1–10 ms, which beats a USB GPS puck's ~100 ms, and the position is a number you
measure once and never again.

## ⛔ The three traps that cost the most time

Each of these presents as something else, which is what makes them expensive.

**1. An RTL-SDR Blog V4 on old drivers reports nothing, or the wrong frequency — with no error.**
The V4's R828D tuner is unsupported by older `librtlsdr`, ~~and `readsb`/`dump1090-fa` link against
it, so installing either from `apt` can quietly undo the fix.~~ At a fence line this is
indistinguishable from a bad antenna, a bad cable, or an empty sky.
✅ `rtl_test -t` must name the tuner **R828D**. → [BUILD.md §4](docs/BUILD.md#4-drivers-first)
*Corrected 2026-10-10: on Raspberry Pi OS trixie the packaged `readsb` links no `librtlsdr` at all.
It is built without RTL-SDR support and cannot drive the stick. The one-command build
([BUILD.md §8](docs/BUILD.md#8-build-order)) compiles `readsb` from source against the packaged
`librtlsdr` 2.0.2 instead. On Debian forky, whose packaged `readsb` depends on `librtlsdr0`, the
concern applies again ([PLAN.md §9j](docs/PLAN.md#9j--verified-on-hardware-2026-10-03)). Whether
`dump1090-fa` links it is not checked here. ⚠️ The packaged 2.0.2 has not been run with a confirmed
V4. ⚠️ Counterfeit V4s are sold, Amazon included: the stick first used here was an R820T2 board in a
printed V4 case. Its EEPROM strings read the same as a genuine V3's, so the tuner name is the only
tell, and reading it is the hand check in BUILD.md §8 step 0. Buy from RTL-SDR Blog or a seller
listed on rtl-sdr.com (PLAN.md §9j).*

**2. The common DS3231 RTC board (ZS-042) will try to charge a non-rechargeable coin cell.**
It ships with a trickle-charge circuit intended for a LIR2032. Fit an ordinary CR2032 and the board
force-charges a cell never designed for it — a leak and fire risk.
✅ Fit a LIR2032, **or** remove R5. → [BUILD.md §6](docs/BUILD.md#6-the-clock-gps-and-an-rtc)

**3. Two dongles with the same serial shuffle at boot**, and your decoder grabs the wrong radio.
Presents as "ADS-B stopped working for no reason."
✅ `rtl_eeprom -d 0 -s 1090`. → [RADIOS.md §5](docs/RADIOS.md#5-what-a-second-dongle-does-to-the-pi)

## What is here

| | |
|---|---|
| [`docs/PLAN.md`](docs/PLAN.md) | ⭐ **The why** — the architecture as one base plus radio slots, what the real constraints are, and what was rejected |
| [`docs/BUILD.md`](docs/BUILD.md) | The rig end to end — Pi choice, parts, power, drivers, GPS/RTC, software, build order |
| [`docs/RADIOS.md`](docs/RADIOS.md) | The second radio — airband/ATC audio and ACARS/VDL2, antennas, legality, multi-dongle pitfalls. ~~⚠️ Currently behind [`PLAN.md §1`](docs/PLAN.md#1-one-base-several-radio-slots)~~ *Corrected 2026-10-10: brought into line with PLAN.md §1's slots* |
| [`config/station.portable.example.yml`](config/station.portable.example.yml) | 🎒 Template for the per-station settings that must **not** be committed |
| [`config/station.stationary.example.yml`](config/station.stationary.example.yml) | 🏠 The same, for the rig that stays put |
| [`setup/`](setup/) | *Added 2026-10-10.* The build: [`bootstrap.sh`](setup/bootstrap.sh), the one command, and [`update.sh`](setup/update.sh), which runs the step scripts in `setup/steps/` and keeps the rig current. [BUILD.md §8](docs/BUILD.md#8-build-order) |
| [`bin/`](bin/) | *Added 2026-10-10.* What runs on the rig: the archive writer `adsb-writer`, the clock and archive preflights, and the 🎒 portable's home-update opener |
| [`tools/`](tools/) | *Added 2026-10-10.* What runs on your workstation: `pull-archive`, which moves the 🎒 portable's archive off it, and `adsb-extract`, which reads a time window back out of the pulled files |

⭐ **Two templates, one per rig, and they are not two copies of one file.** Each holds only what
its role actually uses — so the 🎒 portable one has **no `position:` block at all**, because a
hardcoded position on a rig that moves is the failure mode
[BUILD.md §6a](docs/BUILD.md#6a-what-the-gps-is-carrying) describes: a complete, plausible,
confidently wrong track rather than an obvious gap. ⛔ Do not merge them back together.

⛔ **Your station position is not public data.** A stationary receiver's coordinates are a home
address — yours, or a friend's if the antenna is on their roof. `config/station.yml` is
gitignored; keep it that way, and agree the siting with whoever owns the roof *before* it goes up.

## Status

~~📋 **Documentation, today.** The archive writer, the extractor, and the uploader are designed but
not written; where that is true the docs say so rather than pretending otherwise.~~
*Corrected 2026-10-10: the archive writer, [`bin/adsb-writer`](bin/adsb-writer), and the extractor,
[`tools/adsb-extract`](tools/adsb-extract), are written, and the writer records on the 🎒 portable.
📋 The uploader is not written, and its language is not chosen
([PLAN.md §9i](docs/PLAN.md#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader)).*

~~⚠️ **Nothing here has been confirmed against a built rig yet.**~~ *Corrected 2026-10-10: the 🎒
portable is built from this repo and running; what has been verified on it is recorded in
[PLAN.md §9j](docs/PLAN.md#9j--verified-on-hardware-2026-10-03) and
[§9m](docs/PLAN.md#9m--the-portable-rigs-archive-drive). The 🏠 stationary is not built.* These are
researched notes: the power figures in [BUILD.md §5](docs/BUILD.md#5-power-portable-only) come off a
pack's spec sheet rather than a bench run, and that section names the two things to test before
trusting them. *Added 2026-10-10: that section now also carries one measured reading, a minute
long, from 2026-10-05.* ✅ in these docs marks **the check to run, or the fix to apply** ~~— never a
claim that the part was tested here~~. *Corrected 2026-10-10: a ✅ with a date beside it, as on
BUILD.md §5's 2026-10-05 reading, records a check made on the built 🎒 portable.*

## License

Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
