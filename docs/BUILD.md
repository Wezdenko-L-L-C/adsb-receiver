# Building the rig

Both rigs run Raspberry Pi OS Lite (64-bit) and the same decoder. What differs is where the clock
and the position come from, and what else is along for the ride.

➡️ **Read [§2](#2-two-rigs-not-one) before buying anything.** The parts lists diverge, and one rig
does not need the GPS at all.

---

## 1. Which Pi

**A Pi 4 is comfortable; a Pi 3 or Zero 2 W will do.** ADS-B decoding is not demanding — an RTL-SDR
at 2.4 MSPS costs roughly half of one core on a Pi 4.

If you are building both rigs, the natural split is **more RAM → stationary**: it runs `tar1090`,
an SSD-backed archive, a feeder client and an ACARS decoder together. The portable rig runs a
decoder, an uploader and (optionally) `rtl_airband`, which is comfortable in 1 GB.

⚠️ **Power is the real constraint, not RAM.** A Pi 4 pulls ~3–5 W idle and more with an SDR
attached, and it is fussy about undervoltage — a weak supply causes decode dropouts **that look
exactly like antenna problems**. Budget a source that genuinely holds **5 V / 3 A**. If the rig
becomes something you carry regularly, a Pi Zero 2 W does the same job on a fraction of the power.

---

## 2. Two rigs, not one

These are two machines that happen to share a decoder.

| | 🎒 **Portable** | 🏠 **Stationary** |
|---|---|---|
| **Job** | Log tracks at the location you are shooting from | Continuous archive, feeding, ACARS harvesting |
| **Runs for** | Hours, on battery | 24/7, on wall power |
| **Position** | ⚠️ Changes every session | ✅ Constant — survey once, put it in config |
| **Network** | ⛔ None | ✅ Yes |
| **Antenna** | Magnetic-mount whip on a car roof | Collinear (e.g. FlightAware 26") up a mast |

### ⭐ The two rigs want opposite things from GPS

[§6](#6-the-clock-gps-and-an-rtc) argues that GPS is *not optional*. That argument is **entirely a
portable argument**, and it is worth understanding why it collapses indoors:

> *"It gets time from NTP over the network, and in the field there is no network."*

At a house there **is** a network. NTP over it gives ~1–10 ms — **better than a USB GPS puck's
~100 ms** — and the station's position is a number you measure once.

➡️ **The stationary rig needs neither the GPS nor the RTC.** Skip both; save the money and the USB
port. ⛔ Do not copy the portable parts list onto the roof rig out of symmetry.

### ➡️ Build the portable one first

It is the rig that produces something you cannot get back. An archive started later loses nothing
but history, whereas a session you went out and shot without a logger running is gone for good.

⚠️ **A friend's roof is a second site, not a spare shelf.** It has to run unattended — headless,
auto-restarting, reachable over something like Tailscale — on somebody else's power and internet.
⛔ **And the station position is their home address.** It lands in your data and, through an
archive, potentially in anything you publish from it. Agree it with them before the antenna goes
up, not after.

---

## 3. Parts

Buy the shared core once per rig, then only the additions for the rig you are building.
⛔ **[§3d](#3d--the-second-radio--either-rig) is a later order, not part of the first one** — see
[§8](#8-build-order).

### 3a. Shared core — both rigs

| # | Part | Notes |
|---|---|---|
| 1 | **Raspberry Pi 4** (3 or Zero 2 W also fine) | See [§1](#1-which-pi) |
| 2 | **microSD, 32 GB, A2 / high-endurance** | Cheap cards are the usual cause of "it stopped working" |
| 3 | **1090 MHz SDR** — FlightAware Pro Stick Plus, or RTL-SDR Blog **V4** | ⭐ Best is a stick with a **built-in 1090 filter + LNA**. The V4's triple-tuned front end notches broadcast FM and DAB, which is most of what swamps a generic dongle near a city — but it carries **no 1090 SAW filter**, so a **1090 bandpass** inline is still the ADS-B upgrade. ⛔ A broadcast-AM reject high-pass is *not* that filter: it cuts below ~2 MHz and does nothing at 1090. ⛔ **A V4 needs current drivers — [§4](#4-drivers-first)** |
| 4 | **Coax + the right adapter** | ⚠️ Check connectors before ordering — FlightAware antennas are **N-female**, the sticks are **SMA-female**. You want an N-male → SMA-male cable, not a stack of adapters |
| 5 | **Heatsink case, with a fan** | A Pi 4 throttles under sustained load, and [RADIOS.md](RADIOS.md) gives it real work |

### 3b. 🎒 Portable additions

| # | Part | Notes |
|---|---|---|
| 6 | **Magnetic-mount 1090 whip** | For a car roof. ⛔ A 26" collinear is the wrong antenna to carry and the wrong one to mount in a hurry. ⚠️ These are usually **MCX** — check the bundled MCX→SMA adapter presents **SMA male**, since the dongle's connector is SMA female |
| 7 | **USB-C power bank, genuine 5 V 3 A** | See [§5](#5-power-portable-only). ⚠️ Undervoltage looks like bad reception |
| 8 | **USB GNSS receiver** — ⭐ **GlobalSat BU-353N5** | ⛔ Portable only. ⭐ Magnetic mount on a ~1.5 m lead, so the antenna goes where the sky is — which a HAT cannot do. [§6c](#6c-which-gnss-puck) for why the N5 over the older S4 |
| 9 | **DS3231 RTC module** (I²C breakout, ~$5) | ⛔ Portable only. ⭐ [§6b](#6b-gps-alone-does-not-close-it) — the half of the clock problem GPS does *not* solve. ⚠️ DS3231, **not** DS1307. ⚠️ [§6b](#6b-gps-alone-does-not-close-it): fix the charge path before fitting |
| 10 | **A bag that fits it all, and short USB extension leads** | Dongles need spacing ([RADIOS.md §5](RADIOS.md#5-what-a-second-dongle-does-to-the-pi)), and a rig you dread packing is a rig you leave at home |

### 3c. 🏠 Stationary additions

| # | Part | Notes |
|---|---|---|
| 6 | **FlightAware 26" antenna + mast/mount** | ⭐ **Height beats everything else you can buy.** Outdoors and high is worth more than any filter or LNA |
| 7 | **Outdoor-rated coax, as short as the run allows** | ⚠️ Loss at 1090 MHz is brutal — LMR-400 over RG-58 for anything past a few meters, and put the LNA at the *antenna* end (the dongle's bias tee can power it) |
| 8 | **USB SSD** | For the archive. ⛔ Do not run a continuous archive onto the SD card |
| 9 | **Wall power supply — the official 5 V 3 A one** | Not a phone charger. Undervoltage is the same failure as in the field, just permanent |
| 10 | ⛔ **Not** a GPS, and **not** an RTC | [§2](#2-two-rigs-not-one) — it has a network and a position that never moves |

### 3d. 📻 The second radio — either rig

⛔ **Do not buy this with the first order.** [§8](#8-build-order) step 5 is deliberate: a second
radio goes on only once the base rig is boring, because adding dongles is exactly what
destabilizes a working receiver. Ordering it early does not make that step arrive sooner — it just
puts a dongle in a drawer.

➡️ *Which* radio goes on *which* rig, and why, is [RADIOS.md](RADIOS.md). This is only the list.
🎒 Portable is 1090 + airband; 🏠 stationary is 1090 + VDL2. ⛔ Neither rig runs three dongles.

| # | Part | Notes |
|---|---|---|
| 11 | **A second RTL-SDR** | 🎒 airband, 🏠 VDL2. ⭐ If you own a filtered stick **and** a V4, the filtered stick stays on 1090 and the V4 does the VHF work — a general-purpose dongle is a good VHF radio and a middling 1090 one ([RADIOS.md §1](RADIOS.md#1-each-radio-is-its-own-dongle)) |
| 12 | **A VHF antenna** — 🎒 RTL-SDR Blog dipole kit, 🏠 discone (e.g. Diamond D130J) | ⛔ Your 1090 collinear is **deaf** at 118 MHz; it is cut for 1090 and nothing else. The dipole kit is half-wave at 120 MHz with each leg at ~60 cm, and you may already own one. A discone feeds airband **and** VDL2 off one antenna ([RADIOS.md §2](RADIOS.md#2-your-1090-antenna-will-not-hear-any-of-this)) |
| 13 | **FM band-stop / notch filter** (~$12) | ⚠️ **Not** the broadcast-AM high-pass, which cuts below ~2 MHz and is irrelevant here. The front-end killer near an airport is **FM broadcast at 88–108 MHz**, immediately adjacent to airband |
| 14 | **Powered USB hub** | ⛔ **Required on the 🎒 portable rig.** Each dongle draws ~300 mA and a Pi 4's entire USB budget is ~1.2 A — two dongles *plus* the GPS puck is over it. The symptom is undervoltage, which [§1](#1-which-pi) warns looks exactly like an antenna problem. ℹ️ The 🏠 stationary rig has wall power behind it and no puck, so it has slack — but this is still the first thing to try if a second dongle destabilizes it |

⚠️ **Short USB extension leads, on both rigs.** Stacked directly, dongles heat each other and
drift, and the lead also moves them off the Pi's own USB noise
([RADIOS.md §5](RADIOS.md#5-what-a-second-dongle-does-to-the-pi) rule 3). 🎒 The portable list
already carries them as part 10; 🏠 the stationary one does not, so add them here.

⚠️ **🎒 Recompute the power budget before ordering.** A second dongle and a hub take the worked
example in [§5](#5-power-portable-only) from ~12 hours to ~9.5 — still longer than any session,
but no longer the comfortable margin a single-dongle rig enjoys.

### Optional

- **GPS HAT with a PPS pin** — sub-microsecond time instead of ~100 ms. Overkill for correlating
  photographs, and it does not buy MLAT either: `mlat-client` derives timing from the dongle's own
  sample clock, not from your GPS. ℹ️ If you want one anyway, a **Uputronics GPS/RTC HAT** bundles
  the RTC and so replaces parts 8 *and* 9 — at the cost of putting the antenna on top of the Pi
  rather than on a lead.
- **1090 bandpass filter** if you are near broadcast towers, or running an unfiltered generic
  dongle at 1090 at all.

---

## 4. Drivers first

### ⛔ The V4 fails silently on old drivers

**Do this before anything else, and do not skip it because the dongle enumerates.**

Old `librtlsdr` builds have no support for the V4's **R828D** tuner. The result is not an error:
you get **no signals, or signals at the wrong frequency** — indistinguishable from a bad antenna, a
bad cable, or an empty sky.

⚠️ **It bites ADS-B specifically**, because `readsb` and `dump1090-fa` link against `librtlsdr`.
Installing either from `apt` can quietly pull an old one back in and undo the fix.

```bash
# ⚠️ This takes readsb / dump1090-fa with it — they link against librtlsdr.
#    That is the point (they get rebuilt against the new one), but do it knowingly.
sudo apt purge '^librtlsdr'        # quote it: ^ is a regex for apt, not for the shell
# then remove any stale librtlsdr* left behind in /usr/lib and /usr/local/lib
echo 'blacklist dvb_usb_rtl28xxu' | sudo tee /etc/modprobe.d/blacklist-rtl.conf
# Corrected 2026-10-05: setup/steps/00-drivers.sh now writes this blacklist itself, as
#   /etc/modprobe.d/adsb-receiver-rtlsdr.conf. Skip the line above if you build with the one
#   command (§8); a hand-written file beside the step's own is harmless.
# then build current librtlsdr from osmocom/rtl-sdr, and re-check with rtl_test -t
```

⚠️ **Build from `osmocom/rtl-sdr`, not `rtlsdrblog/rtl-sdr-blog`.** Osmocom is the **upstream**
project; the rtlsdrblog repo is the downstream **fork**, and it has carried a broken commit that
fails to compile with an `rtlsdr_check_dongle_model` implicit-declaration error. ⛔ Get the two the
wrong way round and you are back to a silent failure, which is the entire subject of this section.

⚠️ **Not verified here:** *which* repo carries R828D support at the revision you actually clone —
that moves, and a README is not evidence. ✅ The check that settles it is `rtl_test -t` below.

✅ **Verify before trusting it:** `rtl_test -t` should name the tuner as **R828D**. If it says
R820T2, or reports nothing, the old driver is still in the path and every reading after this point
is worthless.

ℹ️ None of this applies to a FlightAware Pro Stick — it is an R820T2 device and works with the
packaged driver.

---

## 5. Power (portable only)

ℹ️ The stationary rig runs on wall power; none of this applies to it.

Worked example, computed from the spec of an **Anker Prime 27,650 mAh / 250 W**:

| | |
|---|---|
| Pack | 27,650 mAh at 3.6 V nominal = **99.5 Wh** (~84.6 Wh usable after conversion loss) |
| Pi 4 + SDR only | ~5.5 W → ~15 hours |
| Pi 4 + SDR + GPS + wifi ([local link only](#7-software)) | ~7 W → **~12 hours** |
| ⚠️ **+ second dongle + powered hub** ([§3d](#3d--the-second-radio--either-rig)) | ~9 W → **~9.5 hours** |

✅ *Measured 2026-10-05, on that bank:* one minute after boot, with the stick, the GPS puck, the
archive drive, the fan and the RTC live and `readsb` decoding, the port read **5.1 V, 1.1 A, 5.6 W**,
and the bank estimated **14 h 36 m** at 100 %. ➡️ The ~7 W row above is conservative. ⚠️ One
minute is not a session: a one-hour reading, with the low-current cutoff (below) proven not to bite,
is still owed.

⚠️ **A second radio is where the headroom goes** — 12 hours down to about 9.5. Still longer than
any session, but no longer the "far more than needed" a single-dongle rig enjoys.

ℹ️ At 99.5 Wh a pack like this is also under the **100 Wh airline carry-on limit**, which is worth
checking on the spec sheet if the rig travels.

⚠️ **Two things to test on the bench, not in the field:**

1. **Low-current cutoff.** Many banks switch off when draw drops below a threshold, and a headless
   Pi 4 idling near 3 W can fall under it — the rig dies twenty minutes in for no visible reason.
   Look for the bank's low-current / trickle mode (often a double-press of the button).
   ⭐ Leave it running on the bench for an hour before trusting it.
2. ⛔ **Pi 4 Rev 1.0 boards (early 2019) will not power from an e-marked USB-C cable at all.** A
   known design fault, fixed in Rev 1.2 later that year. If yours is an original launch unit and
   refuses to boot from a bank, try a plain (non-e-marked) cable before suspecting the bank. The
   revision is printed near the USB-C port.

---

## 6. The clock: GPS, and an RTC

⛔ **This section is about the portable rig only** — [§2](#2-two-rigs-not-one) explains why the
argument does not survive the move indoors.

### 6a. What the GPS is carrying

Two separate things, and only one of them is obvious:

**Position.** The receiver's own location. It sets each sample's position, and the decoder needs it
to resolve surface positions properly.

⭐ **Time — the reason it is not optional.** ⛔ **A Raspberry Pi has no real-time clock.** It gets
time from NTP over the network, and in the field there is no network. A Pi that boots somewhere
remote comes up with a clock that may be wildly wrong **and has no way to notice**.

⚠️ This matters enormously if you are joining anything else to these samples **by timestamp** — a
camera's frames, recorded audio. A logger with a wrong clock does not fail loudly. It produces a
complete, plausible track that correlates every frame to the **wrong aircraft**.

➡️ **Run `gpsd` + `chrony`** with the GPS as a time source, so the logger's clock is disciplined
from the same satellites as everything else.

### 6b. GPS alone does not close it

A GPS puck fixes the clock **only once it has locked** — a cold start is 30–60 s under clear sky,
longer against a building or inside a car. If your logger refuses to record until the clock is
disciplined (it should — see [§7](#7-software)), that wait is time stood around unable to start.

⭐ **A DS3231 costs ~$5 and removes the wait.** It holds wall-clock across boots on a coin cell, so
the Pi comes up already approximately right and GPS then refines it.

| | Gives you | Available |
|---|---|---|
| **DS3231 RTC** | Time across a boot, with no network and no sky | **Instantly**, every boot |
| **GPS** | Position, and time disciplined to ±~100 ms | After lock |

⚠️ **DS3231, not DS1307.** The 3231 is temperature-compensated at ±2 ppm; the 1307 drifts enough to
matter over a weekend. Four pins (3V3, GND, SDA, SCL) and ~~`dtoverlay=i2c-rtc,ds3231` in
`config.txt`~~ *two lines in `config.txt`, `dtparam=i2c_arm=on` and `dtoverlay=i2c-rtc,ds3231`
(corrected 2026-10-04: this named only the second; the one-command build in [§8](#8-build-order)
adds both)*, and it leaves the rest of the header free — which a HAT does not.

#### ⛔ The ZS-042 board will try to charge a non-rechargeable cell

The common **DS3231 + AT24C32 board (ZS-042)** carries a 200 Ω resistor (R5) and a 1N4148 diode
wired to trickle-charge a **LIR2032 rechargeable**. Fit an ordinary **CR2032** and the board
force-charges a cell that was never designed to be charged — a leak and fire risk, and a
well-documented one.

➡️ **Pick one ~~before it goes in a bag~~ before the board is wired to the Pi:**
*Corrected 2026-10-04: the charging circuit is live from the moment the board is powered, not from
the moment the overlay is enabled, so this is a hardware-assembly step, done with the board in
hand. No script can check it, and the one-command build in [§8](#8-build-order) does not: it only
prints a reminder when it adds the overlay.*
- fit a **LIR2032** (rechargeable, what the board expects), **or**
- **remove R5** (or the 1N4148), after which a CR2032 is safe.

ℹ️ Wire it to the Pi's **3.3 V** pin, not 5 V — the Pi's I²C is 3.3 V logic anyway, and it makes
the charging circuit less aggressive if you have not removed it. ℹ️ The AT24C32 EEPROM on the same
board appears at a second I²C address and is harmless.

ℹ️ **±100 ms is not a ceiling — it is far better than most uses need.** Samples land ~1 s apart at
best. This is why the PPS HAT stays optional: it improves a number that is already sufficient.

### 6c. Which GNSS puck

⭐ **The BU-353N5, not the older S4.** They are different receivers, and the N5 is not simply a
refresh:

| | BU-353S4 | ⭐ **BU-353N5** |
|---|---|---|
| Chipset | SiRFstar IV | **MediaTek AG3335MN**, 75 channels |
| Constellations | GPS only | **GPS + GLONASS + Galileo + BeiDou + QZSS + SBAS** |
| Tracking sensitivity | ~-163 dBm | -165 dBm |
| Cold start | ~35–45 s | **<33 s** (hot start <1 s) |
| Weather | Not rated | **IPX6** |
| Output | NMEA 0183 | NMEA 0183 v3.01/v4.10 — `gpsd` reads it directly |

ℹ️ The S4 is often described as a u-blox. It is not — it is SiRFstar IV.

⭐ **Multi-constellation is not a spec-sheet nicety here.** Anywhere you are likely to set up is
partial sky: buildings, perimeter fencing, and your own vehicle block a chunk of it. Four
constellations instead of one is exactly what recovers a lock in that situation, and lock time is
time you cannot start recording. IPX6 matters more than it sounds for something living on a car
roof in a hot, dry climate.

⚠️ **Bench check before trusting it:** the USB bridge is a **Prolific PL2303GC**. Linux support for
newer PL2303 variants arrived around kernel 5.13 — current Raspberry Pi OS is well clear, but an
older image will not enumerate it. Confirm `/dev/ttyUSB0` appears and `cgps` shows satellites.

✅ **It does not replace the DS3231.** "Hot start <1 s" is the *GPS* re-acquiring from its own
ephemeris backup. It gives the **Pi** no wall clock at boot. [§6b](#6b-gps-alone-does-not-close-it)
stands unchanged.

---

## 7. Software

**🎒 Portable — everything serves the session:**

```
  readsb  (or dump1090-fa)   → decodes 1090 MHz, writes aircraft.json ~1 Hz
  gpsd + chrony              → position, and disciplined time (§6)
  i2c-rtc (ds3231)           → wall-clock across a boot, before GPS locks (§6b)
  rtl_airband                → ATC audio on a second dongle (RADIOS.md)
  uploader (yours to write)  → reads aircraft.json + gpsd, spools to disk;
                               ships on the next network, never in the field
```

⛔ **The portable uploader does not upload in the field.** [§2](#2-two-rigs-not-one) means it
literally: there is no network out there. It writes numbered batches to `spool_dir` for the whole
session and ships them the next time the rig sees a network. ➡️ Which is why rule 3 below is not
optional on this rig, and why `uploader.endpoint` may be null — a rig that only ever logs locally
is a valid rig.

ℹ️ **The wifi in the [§5](#5-power-portable-only) power budget is a local link, not a route out.**
A phone hotspot or the Pi's own AP, so you can check a headless rig is alive without carrying a
screen. ⛔ Nothing in the software should assume it reaches the internet.

**🏠 Stationary — everything serves the archive:**

```
  readsb  (or dump1090-fa)   → decodes 1090 MHz
  chrony (plain NTP)         → ⛔ no gpsd, no RTC. Position is a constant in config
  tar1090                    → local web map; it also earns its keep aiming the mast
  dumpvdl2                   → ACARS/VDL2 on a second dongle (RADIOS.md)
  feeder client              → whatever aggregators you feed (§9)
  archive writer (to write)  → BEAST to the SSD, retention enforced in the writer (§9)
  extractor (to write)       → pulls a time window back out of the archive (§9)
```

📋 **The uploader, the archive writer and the extractor do not exist here yet.** Four rules worth
following when you write the first two — the first three apply to any logger, the fourth is
specific to a rig with no network:

1. ⛔ Store **every candidate**, never a pick. Narrowing at write time throws away the evidence
   you need to check the pick later.
2. ⛔ Record a **failed read as a sample carrying an error**. A gap and an empty sky are different
   facts, and a schema that cannot tell them apart will silently conflate them.
3. ⛔ Buffer to disk **before** uploading, and number batches so a retry is idempotent.
4. ⚠️ **Refuse to record until the clock is disciplined** — by GPS on the portable rig, by NTP on
   the stationary one. An un-disciplined Pi clock silently corrupts every correlation made from
   that session, and it is cheap to check (`chronyc tracking`) before you start.

---

## 8. Build order

➡️ **Build the 🎒 portable rig first.** The stationary rig reuses everything you learn, and steps
0–1 are identical for both.

**The software is one command.** *Added 2026-10-04.* ~~⚠️ Built, and not yet run on a Pi.~~
*Corrected 2026-10-05: it ran on the portable Pi, `mobile-adsb`, on 2026-10-04 and again on
2026-10-05, which completed the build at `e019b29` with a reboot
([PLAN.md §9e](PLAN.md#9e-the-first-build-is-by-hand-after-that-updates-are-automatic)).* Once
Raspberry Pi OS is installed, run this on the Pi. Missing hardware does not stop it: the update
timer it installs finishes the build once the hardware is there.

```
curl -fsSL https://raw.githubusercontent.com/Wezdenko-L-L-C/adsb-receiver/main/setup/bootstrap.sh \
  | sudo bash -s -- --role portable
```

To read what runs before it runs, clone the repo and run the bootstrap from your checkout. It then
builds the commit you read, not a newer one:

```
sudo apt install -y git
git clone https://github.com/Wezdenko-L-L-C/adsb-receiver.git
sudo bash adsb-receiver/setup/bootstrap.sh --role portable
```

`--role stationary` needs the rig's surveyed position, as `--set position.latitude=…` and the
like, or a whole file with `--config FILE`. `--no-format` and `--no-reboot` turn off the two acts
below. Why it is shaped this way is in [PLAN.md §9e](PLAN.md#9e-the-first-build-is-by-hand-after-that-updates-are-automatic).

⚠️ **Starting it is your agreement. It does these without asking:**

- **It formats the archive drive,** on the portable only, and only under a strict rule: if a drive
  is already labeled for the archive, nothing is formatted; otherwise exactly one unmounted,
  removable USB disk of at least 8 GB, with no filesystem on it, or one that a read-only mount
  proves empty. Anything else, it refuses, carries on without the drive, and shows the command to
  run by hand in the login banner. Only this first run formats: a drive plugged in later is
  formatted by hand.
- **It writes the RTC overlay** into `config.txt`, on the portable only, unless the RTC is already
  wired into boot.
- **It reboots once,** after a 5 s notice, on a first build, when those changes need it. After the
  boot the update timer finishes anything still incomplete, such as a step waiting for hardware
  that was plugged in late.

ℹ️ ~~`10-decoder`, the step that installs `readsb` and `tar1090`, is not in the repo yet
([PLAN.md §9m](PLAN.md#9m--the-portable-rigs-archive-drive), R5), so until it is, the command does
not give you step 1's map.~~ *Corrected 2026-10-05: `10-decoder`, the step that installs `readsb`
and `tar1090`, is in the repo (`42b5115`) and ran on the portable Pi on 2026-10-05
([PLAN.md §9j](PLAN.md#9j--verified-on-hardware-2026-10-03)).*

✅ **After the build, these stay yours to check, under the sky.** The build does not wait for them,
and no script can pass them for you:

- [ ] `tar1090` shows aircraft (step 1).
- [ ] `gpsd` has a fix, and `chronyc sources` shows GPS disciplining the clock (step 2).
- [ ] The Pi still knows the time after a power cycle **with the network unplugged** (step 2).

0. ⛔ **Install the drivers first** ([§4](#4-drivers-first)) and confirm `rtl_test -t` ~~names an
   **R828D**~~ *opens the stick and names its tuner*. Every step below would otherwise be debugging the wrong thing.
   *Corrected 2026-10-04: an R828D is only what a V4 reports. ~~The step script `00-drivers` fails an
   R828D without its V4 line, and passes any other tuner with a warning
   ([PLAN.md §9c](PLAN.md#9c-every-step-ends-in-a-check-of-the-observable-effect)'s 2026-10-04
   update).~~ The stick first used here was a counterfeit V4 with an R820T2
   ([PLAN.md §9j](PLAN.md#9j--verified-on-hardware-2026-10-03)), and the replacement radio is an
   RTL-SDR Blog V3 (R820T2), not yet in hand on 2026-10-04.*
   *Corrected 2026-10-05: `00-drivers` no longer checks the tuner, and no step's verify opens the
   stick. The tuner check is `10-decoder`'s, read from `readsb`'s own open of the stick, and it only
   warns: an R828D without its V4 line, a V4 line on another tuner, and Blog or V4 in the EEPROM on
   another tuner each print a warning, and the step passes once the stick is streaming
   ([PLAN.md §9j](PLAN.md#9j--verified-on-hardware-2026-10-03)'s 2026-10-05 rulings).*
   ℹ️ *Added 2026-10-05: with the one command above, step 0 is `setup/steps/00-drivers.sh`, which
   installs the packaged driver from apt and blacklists the kernel's DVB driver. It does not do
   [§4](#4-drivers-first)'s from-source build. This step's order is not yet rewritten for the one
   command.*
   ⚠️ *Added 2026-10-05: on a first build, before its reboot, the kernel's DVB driver is still
   loaded, and every close of the stick hands it back to that driver, which re-probes it. That is
   the hazard behind the 2026-10-04 hub drop
   ([PLAN.md §9j](PLAN.md#9j--verified-on-hardware-2026-10-03)). The `rtl_test -t` check above
   stands as a hand check, because the ruling that no step opens the stick covers verifies, not
   you. After the reboot, `journalctl -u readsb -b` shows the same tuner line without opening the
   stick.*
1. Build it **on the bench**, on wall power and wifi. Confirm `tar1090` shows aircraft.
2. Add GPS and the RTC. Confirm `gpsd` has a fix, `chronyc sources` shows GPS disciplining the
   clock, and the Pi still knows the time after a power cycle **with the network unplugged**.
   ⛔ *Added 2026-10-04:* **fix the RTC board's charge path before you wire it to the Pi**
   ([§6b](#6b-gps-alone-does-not-close-it)). It is an assembly check: the board charges its cell
   from the moment it is powered, and no script can see it.
3. Only then take it out on battery — that is where undervoltage and antenna placement problems
   appear, and you want everything else already known-good.
4. Write the uploader last, against a receiver you already trust.
5. ⭐ **Add a second radio only after all of the above is boring.** Adding dongles is exactly what
   destabilizes a working rig — see [RADIOS.md](RADIOS.md). ➡️ Order its parts at this point, not
   with the first order: [§3d](#3d--the-second-radio--either-rig).
6. 🏠 **Then build the stationary rig**, reusing steps 1 and 5 — but ⛔ **not** step 2. Its own
   extra step is the mast, because height is the only thing that materially changes reception.

⚠️ **Receiving ADS-B is legal in the US**; this is a receive-only device and transmits nothing.
⛔ **That blanket statement stops being true once an airband dongle is attached**, and receive-only
is not the whole test abroad. See the jurisdiction table in
[RADIOS.md §3](RADIOS.md#3-atc-audio--rtl_airband-portable) before travelling.

---

## 9. 🏠 The archive, and feeding

⛔ **This is the stationary rig's job, and it is why that rig exists.** Feeder tiers want high
monthly uptime and an archive wants no holes — neither of which a receiver that leaves the house
can deliver.

**Feeding costs nothing extra.** The decoder is already running. Aggregators generally reward
feeders with better API allowances than registered non-feeders, and the specific benefit worth
having is usually *your own receiver's* state vectors, uncharged and unthrottled.

⚠️ **An API allowance is not a recording budget.** A day holds 86,400 seconds; even a generous
feeder tier answers occasional questions rather than streaming. And feeding generally does **not**
unlock deep historical backfill, which tends to stay restricted to research and government use.

⭐ **So the archive, not the API, is what gives you history** — and it is better than any API tier,
because it is yours: no credits, no rate limit, no egress block, nobody else deciding what you may
keep. Budget roughly **~200 MB/day compressed** for a busy US metro at 1 Hz, or ~73 GB/year.

**Three things to settle before writing it:**

1. ⛔ **Retention policy, enforced in the writer.** An unbounded archive fills the disk and then
   *silently stops recording*. Put the limit in the writer, not in a cron job somebody forgets.
2. ⚠️ **Use an existing format.** `readsb` already emits BEAST and the archiving problem is solved
   upstream. A bespoke JSON archive is a format only you can read, for no gain.
3. ⭐ **An archive is worth only what the extractor gets out of it.** The value is not in keeping
   the bytes; it is in pulling a time window back out. Build the extractor alongside the writer, or
   the archive is just a disk filling up hopefully.

ℹ️ **Feed anyway.** It earns allowance for occasional lookups, and it is the rent for a public good
this kind of project leans on.
