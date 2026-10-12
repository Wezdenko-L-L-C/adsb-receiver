# Roadmap: the order of the remaining work

⭐ **This file holds the order, and nothing else.** The reason for each item is in
[PLAN.md](PLAN.md), at the section the item links to; the to-dos are GitHub issues. ⛔ No reasoning
goes here.

ℹ️ The order changes only by Chris's rulings, and each change is dated. Started 2026-10-10, from
his rulings that day ([PLAN.md §8](PLAN.md#8-sequencing)'s 2026-10-10 update). Issue numbers were
added 2026-10-10, once Chris had approved the list of issues.

## 🎒 The portable, completed first

*Ruled 2026-10-10 ([PLAN.md §8](PLAN.md#8-sequencing)).*

1. ~~**Sweep fixes: stale comments in the code and the config templates,** including the code-side
   corrections the 2026-10-10 rulings bring
   ([§9j](PLAN.md#9j--verified-on-hardware-2026-10-03),
   [§9i](PLAN.md#9i-what-is-not-chosen-yet-the-uploader),
   [§9m](PLAN.md#9m--the-portable-rigs-archive-drive)).
   **Hands:** implementer. Before it is pushed, rig code goes through `step-reviewer` (for any
   `setup/steps/*.sh` or `setup/lib.sh`), then `/code-review` (medium), then `/security-review`
   ([§9b](PLAN.md#9b-one-bash-script-per-build-step)).
   **Done when:** every comment PLAN.md names as still owed in code is corrected, among them
   the BUILD.md §4 pointer in `setup/steps/10-decoder.sh` and the comment on the only copy in
   `tools/pull-archive`.~~ (#27)
   *Done 2026-10-11: the code comments and config templates in `cd913dd`, recorded in PLAN and
   BUILD in `0728e07`; the rest, the comments PLAN §5 lists as lagging, in `7e5dd45`; and the
   slate's comments on the `setfont` re-run, marked as beliefs, in `543b75f`.*
2. ~~**The unexplained unclean reset of 2026-10-10, about 11:50.**~~
   *Moved 2026-10-10 to [Watched](#watched-acted-on-only-when-it-recurs) by Chris's ruling: it
   waits for an event, so it is not a step in the order. The number is kept so the issues' item
   numbers still hold.* (#28)
3. **Where the collected data lives** ("step 6b" in the 2026-10-10 rulings; not BUILD.md §6b). The
   interim pull into the synced folder is the procedure; its trial passed on 2026-10-10. The two
   questions it left open were the database question and the store's layout.
   ~~**Hands:** rejection-checker, then fable-architect, then Chris by question, then documenter.
   **Done when:** both open questions are ruled and recorded.~~
   [§9m](PLAN.md#9m--the-portable-rigs-archive-drive), "Update 2026-10-10: the pull into a synced
   folder". (#29)
   *Done 2026-10-10: both ruled and recorded, in §9m's "Update 2026-10-10 (afternoon): where the
   collected data lives, ruled". The database they rule is built in two steps, placed below (4a,
   6a); their code and issues live in a private repository.*
4. ~~**The interface:** the field display, with the rig's position and the time for the camera shot;
   a viewer; ATC playback. `readsb`'s GPS receiver position is designed with it: one position
   source, and one ruling on where the position may appear.
   **Hands:** not yet named. **Done when:** not yet stated.~~
   *Ruled and split 2026-10-10 by Chris
   ([§5](PLAN.md#5-proposed-the-web-interface-is-three-existing-services-not-a-new-one), "Update
   2026-10-10: the interface, ruled (#30)"). ATC playback (#36) moved to "📻 After the stationary";
   it does not gate the portable's completion.* Item 4 is now, in order:
   1. ~~**readsb's listeners on loopback,** in their own commit, first (ruling 2).
      **Hands:** implementer, then `step-reviewer`, `/code-review` (medium), `/security-review`;
      Chris runs step 10. **Done when:** `ss -ltn` on the 🎒 portable shows readsb on loopback only.~~
      *Done 2026-10-10: committed as `425e89b`. The portable's own update applied it, not a run of
      step 10 by Chris, and `ss -ltn` then showed listeners on loopback only (PLAN §5, ruling 2's
      "✅ Seen" bullet).*
   2. **The field display and the position ruling** (rulings 1, 3, 4, 6, 9, 10).
      **Hands:** implementer and the same review chain; Chris opened a pull window
      (`tools/pull-archive`), whose update applied the step, and attached the panel.
      ~~**Done when:** the slate photographed beside time.gov within 0.3 s; the one-hour power reading
      with the panel on; the slate's CPU from `ps`.~~
      *Changed 2026-10-10 by Chris's ruling (PLAN §5, "The work within #30, in order", item 2's
      19:27 rulings):* **Done when:** the slate photographed beside time.gov within 0.3 s, at home,
      by filming both; the same check in the field state (Wi-Fi off, the rig on the GPS, a phone
      reference on cellular); the one-hour power reading with the panel on; the slate's CPU from
      `ps`. (#30)
      *Built 2026-10-10 as `ed40944`. With the panel, 2026-10-11: the two time checks are seen, at
      home and in the field state; the power reading and the CPU with the panel on are still owed
      (PLAN §5, "The work within #30, in order", item 2, "#30's panel run, 2026-10-11").*
   3. **The viewer:** the live map with the receiver marker at the gated accuracy, :8504 closed,
      and the archive timeline from 4a (rulings 6, 7, 9, 10). **Hands:** implementer and the same
      review chain. **Done when:** stated in its issue. (#35)

   4a. **Database step A, beside the interface:** the catalog, the events and the frame index,
   in local Docker on the workstation; the interface's archive timeline reads it. *Placed
   2026-10-10 by Chris's ruling.*
   **Hands:** not yet named. **Done when:** stated in its issue (in a private repository).
   [§9m](PLAN.md#9m--the-portable-rigs-archive-drive), "Update 2026-10-10 (afternoon): where the
   collected data lives, ruled", A.3.
5. **The 🎒 pre-field checklist.**
   **Hands:** not yet named. **Done when:** every box in it is checked.
   [§9m](PLAN.md#9m--the-portable-rigs-archive-drive), "The pre-field checklist". (#31)
6. **A field session.** ℹ️ Chris states three days of battery sessions already; Claude has not seen
   them. What remains is whatever the checklist's field items need.
   **Hands:** not yet named. **Done when:** the checklist's field items are seen in a field session.
   [§8](PLAN.md#8-sequencing). (no issue of its own: #11 is closed on Chris's word; the checklist's field items are in #31)

➡️ **The portable is completed.**

   6a. **Database step B: positions,** after the field session and before the 🏠 stationary
   design (item 8). Frames to positions is written once, for this and for the extractor.
   *Placed 2026-10-10 by Chris's ruling.*
   **Hands:** not yet named. **Done when:** stated in its issue (in a private repository).
   [§9m](PLAN.md#9m--the-portable-rigs-archive-drive), "Update 2026-10-10 (afternoon): where the
   collected data lives, ruled", A.3.

## Between the two: not placed by a ruling

- **PLAN.md consolidation,** with fable-architect first, on whether §9 splits out of PLAN.md. ⚠️ Its
  place here is not ruled; Chris places it.
  **Hands:** fable-architect first. **Done when:** not yet stated. (#32)

## 🏠 The two stationaries, after the portable: home first, then remote

*Changed 2026-10-11 by Chris's rulings A and B
([§9h](PLAN.md#9h--the-stationary-rigs-home-and-remote), "Update
2026-10-11: two 🏠 stationary rigs, the home one first"): two stationary rigs, the 🏠 home
stationary first, then the 🏠 remote stationary.*

7. **The uploader, before the 🏠 remote stationary.** The rig-side client, in this repo, proven on
   the 🎒 portable at home; the receiving end, in a private service outside this repo, whose hosting
   gates the remote deploy. *Placed 2026-10-11 by ruling B: before the 🏠 remote stationary (9.2)
   only; the 🏠 home stationary (9.1) may be built before it.*
   **Hands:** not yet named. **Done when:** the uploader is proven on the 🎒 portable at home.
   [§9i](PLAN.md#9i-what-is-not-chosen-yet-the-uploader), "Update
   2026-10-10: both rigs get an automatic uploader". (#1)
8. **The stationary design,** in one fable-architect session, before any 🏠 stationary build, the
   home one included (ruling A). Its carry list is the open notes PLAN.md leaves for the stationary
   design, compiled 2026-10-11 from fable-architect's reading; each entry is an open note at the
   section named, and none of them is a ruling (ruling B only leaves the data exit to this session):
   - which parts of §9h bind the role and which bind the remote site
     ([§9h](PLAN.md#9h--the-stationary-rigs-home-and-remote));
   - the maintenance window for a writer that holds the recording lock around the clock, and the
     stationary clock step ([§9f](PLAN.md#9f-what-updatesh-does));
   - the stationary's archive storage ([§9m](PLAN.md#9m--the-portable-rigs-archive-drive));
   - the 🏠 home stationary's data exit until the uploader lands (§9h, ruling B);
   - the hardware and the RTC ([§4](PLAN.md#4-proposed-split-the-stationary-site-across-two-pis),
     [§9l](PLAN.md#9l-rejected));
   - whether §4's two-Pi split becomes a split across the two sites (§4);
   - the rejected second canary Pi, and the 🏠 home stationary's soak (§9l);
   - station identity: the hostname and `station.id`
     ([§9m](PLAN.md#9m--the-portable-rigs-archive-drive));
   - per-station gain (§9h).

   **Hands:** fable-architect. **Done when:** its rulings are recorded in PLAN.md.
   (#33)
9. **The two stationary builds.** *Split 2026-10-11 by ruling A.* Item 9 is now, in order:
   1. **The 🏠 home stationary build.**
      **Hands:** not yet named. **Done when:** not yet ruled. Proposed by fable-architect,
      2026-10-11: "it archives 24/7 and has taken one automatic update through its maintenance
      window, seen." (#38)
      **Owed before its first bootstrap:** the decision on hiding unfinished work on `main`
      ([§9g](PLAN.md#9g-channels-portable-tracks-main-stationary-tracks-stable), "Update
      2026-10-11: hiding unfinished work on `main` is not done now").
   2. **The install manifest, before the 🏠 remote stationary's deploy; then the 🏠 remote
      stationary build, and its pre-ship checklist.** Proposed by fable-architect, 2026-10-11, not
      ruled: the 🏠 home stationary runs the checklist's items that do not depend on the move
      first, as a rehearsal.
      **Hands:** not yet named. **Done when:** every box in the pre-ship checklist is checked, on
      the 🏠 remote stationary.
      [§9f](PLAN.md#9f-what-updatesh-does), "Deferred, decided and not built";
      [§9h](PLAN.md#9h--the-stationary-rigs-home-and-remote), "The
      pre-ship checklist". (#34)

## 📻 After the stationary

⚠️ *Flagged 2026-10-11, not ruled: with two 🏠 stationaries, whether "after the stationary" means
after both, and which rig the second radio goes on first, are open; a question for the stationary
design (item 8).*

- **The second radio, on both rigs,** per [BUILD.md §8](BUILD.md#8-build-order) step 5: "Add a
  second radio only after all of the above is boring."
  **Hands:** not yet named. **Done when:** not yet stated. [§8](PLAN.md#8-sequencing).
  (#12, #21)
- **ATC playback,** `rtl_airband` to Icecast, once the second radio exists. *Moved here 2026-10-10
  from item 4 by Chris's ruling; it does not gate the 🎒 portable's completion.*
  **Done when:** stated in its issue. (#36)

## Watched: acted on only when it recurs

*Ruled 2026-10-10 (Chris, by question).*

- **The unexplained unclean reset of 2026-10-10, about 11:50.** The evidence keeps itself: the
  🎒 portable's journal is persistent, and a torn `.part` is kept as `.torn`. ⚠️ Nothing alerts:
  a recurrence is seen at a pull (a `.torn` file, which a field session's power-off also leaves)
  or in `journalctl --list-boots`.
  **Hands:** Claude reads the rig; Chris's hands on the hardware.
  **Done when:** the cause is seen, or a second occurrence's evidence is recorded.
  [§9f](PLAN.md#9f-what-updatesh-does), "✅ A third boot". (#28)

## Parked

- **The `lslocks` fragility.** Re-opened only if the smoke suite fails again. (no issue: parked)
