# adsb-receiver

Build notes for a pair of Raspberry Pi ADS-B receivers: one that travels, one that stays put.

This is a **build guide**, not a distribution. It exists because most ADS-B instructions stop at
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
| **Runs for** | Hours, on battery | 24/7, on mains |
| **Position** | ⚠️ Changes every session | ✅ A constant — survey once, put it in config |
| **Network** | ⛔ None | ✅ Yes |
| **Clock from** | **GPS** — there is no network to ask | **NTP** — better than the GPS puck, and free |
| **Antenna** | Magnetic whip on a car roof | Collinear up a mast, as high as you can get it |

➡️ **The stationary rig needs neither a GPS puck nor an RTC.** This is the single most common
over-buy, and it comes from copying a portable parts list out of symmetry. At a house there *is* a
network: NTP gives ~1–10 ms, which beats a USB GPS puck's ~100 ms, and the position is a number you
measure once and never again.

## ⛔ The three traps that cost the most time

Each of these presents as something else, which is what makes them expensive.

**1. An RTL-SDR Blog V4 on old drivers reports nothing, or the wrong frequency — with no error.**
The V4's R828D tuner is unsupported by older `librtlsdr`, and `readsb`/`dump1090-fa` link against
it, so installing either from `apt` can quietly undo the fix. At a fence line this is
indistinguishable from a bad antenna, a bad cable, or an empty sky.
✅ `rtl_test -t` must name the tuner **R828D**. → [BUILD.md §4](docs/BUILD.md#4-drivers-first)

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
| [`docs/BUILD.md`](docs/BUILD.md) | The rig end to end — Pi choice, parts, power, drivers, GPS/RTC, software, build order |
| [`docs/RADIOS.md`](docs/RADIOS.md) | The second radio — airband/ATC audio and ACARS/VDL2, antennas, legality, multi-dongle pitfalls |
| [`config/station.example.yml`](config/station.example.yml) | Template for the per-station settings that must **not** be committed |

⛔ **Your station position is not public data.** A stationary receiver's coordinates are a home
address — yours, or a friend's if the antenna is on their roof. `config/station.yml` is
gitignored; keep it that way, and agree the siting with whoever owns the roof *before* it goes up.

## Status

📋 **Documentation, today.** The archive writer, the extractor, and the uploader are designed but
not written; where that is true the docs say so rather than pretending otherwise.

⚠️ **Nothing here has been confirmed against a built rig yet.** These are researched notes: the
power figures in [BUILD.md §5](docs/BUILD.md#5-power-portable-only) come off a pack's spec sheet
rather than a bench run, and that section names the two things to test before trusting them. ✅ in
these docs marks **the check to run, or the fix to apply** — never a claim that the part was
tested here.

## Licence

Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
