# Roadmap: the order of the remaining work

⭐ **This file holds the order, and nothing else.** The reason for each item is in
[PLAN.md](PLAN.md), at the section the item links to; the to-dos are GitHub issues. ⛔ No reasoning
goes here.

ℹ️ The order changes only by Chris's rulings, and each change is dated. Started 2026-10-10, from
his rulings that day ([PLAN.md §8](PLAN.md#8-sequencing)'s 2026-10-10 update). Issue numbers are
added once Chris has approved the list of issues; until then each item reads "(issue to be filed)".

## 🎒 The portable, completed first

*Ruled 2026-10-10 ([PLAN.md §8](PLAN.md#8-sequencing)).*

1. **Sweep fixes: stale comments in the code and the config templates,** including the code-side
   corrections the 2026-10-10 rulings bring
   ([§9j](PLAN.md#9j--verified-on-hardware-2026-10-03),
   [§9i](PLAN.md#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader),
   [§9m](PLAN.md#9m--the-portable-rigs-archive-drive)).
   **Hands:** implementer. Before it is pushed, rig code goes through `step-reviewer` (for any
   `setup/steps/*.sh` or `setup/lib.sh`), then `/code-review` (medium), then `/security-review`
   ([§9b](PLAN.md#9b-one-bash-script-per-build-step)).
   **Done when:** every comment PLAN.md names as still owed in code is corrected, among them
   `setup/steps/10-decoder.sh:98–101` and `tools/pull-archive:45`. (issue to be filed)
2. **The unexplained unclean reset of 2026-10-10, about 11:50.**
   **Hands:** Claude reads the rig; Chris's hands on the hardware.
   **Done when:** the cause is seen, or a second occurrence's evidence is recorded.
   [§9f](PLAN.md#9f-what-updatesh-does), "✅ A third boot". (issue to be filed)
3. **Where the collected data lives** ("step 6b" in the 2026-10-10 rulings; not BUILD.md §6b). The
   interim pull into the synced folder is the procedure; its trial passed on 2026-10-10. Still open:
   the database question, and the store's layout.
   **Hands:** rejection-checker, then fable-architect, then Chris by question, then documenter.
   **Done when:** both open questions are ruled and recorded.
   [§9m](PLAN.md#9m--the-portable-rigs-archive-drive), "Update 2026-10-10: the pull into a synced
   folder". (issue to be filed)
4. **The interface:** the field display, with the rig's position and the time for the camera shot;
   a viewer; ATC playback. `readsb`'s GPS receiver position is designed with it: one position
   source, and one ruling on where the position may appear.
   **Hands:** not yet named. **Done when:** not yet stated.
   [§8](PLAN.md#8-sequencing); the proposal in [PLAN.md](PLAN.md) §5. (issue to be filed)
5. **The 🎒 pre-field checklist.**
   **Hands:** not yet named. **Done when:** every box in it is checked.
   [§9m](PLAN.md#9m--the-portable-rigs-archive-drive), "The pre-field checklist". (issue to be filed)
6. **A field session.** ℹ️ Chris states three days of battery sessions already; Claude has not seen
   them. What remains is whatever the checklist's field items need.
   **Hands:** not yet named. **Done when:** the checklist's field items are seen in a field session.
   [§8](PLAN.md#8-sequencing). (issue to be filed)

➡️ **The portable is completed.**

## Between the two: not placed by a ruling

- **PLAN.md consolidation,** with fable-architect first, on whether §9 splits out of PLAN.md. ⚠️ Its
  place here is not ruled; Chris places it.
  **Hands:** fable-architect first. **Done when:** not yet stated. (issue to be filed)

## 🏠 The stationary, after the portable

7. **The uploader, first.** The rig-side client, in this repo, proven on the 🎒 portable at home;
   the receiving end, in a private service outside this repo, whose hosting gates the remote
   deploy.
   **Hands:** not yet named. **Done when:** the uploader is proven on the 🎒 portable at home.
   [§9i](PLAN.md#9i-what-is-not-chosen-yet-the-writer-the-extractor-the-uploader), "Update
   2026-10-10: both rigs get an automatic uploader". (issue to be filed)
8. **The stationary design,** in one fable-architect session. Its carry list is the open notes
   PLAN.md leaves for the stationary design
   ([§4](PLAN.md#4-proposed-split-the-stationary-site-across-two-pis),
   [§9f](PLAN.md#9f-what-updatesh-does), [§9l](PLAN.md#9l-rejected),
   [§9m](PLAN.md#9m--the-portable-rigs-archive-drive)).
   **Hands:** fable-architect. **Done when:** its rulings are recorded in PLAN.md.
   (issue to be filed)
9. **The install manifest, before any 🏠 stationary deploy; then the stationary build, and its
   pre-ship checklist.**
   **Hands:** not yet named. **Done when:** every box in the pre-ship checklist is checked.
   [§9f](PLAN.md#9f-what-updatesh-does), "Deferred, decided and not built";
   [§9h](PLAN.md#9h--the-stationary-rig-runs-at-a-remote-site-hundreds-of-miles-away), "The
   pre-ship checklist". (issue to be filed)

## 📻 After the stationary

- **The second radio, on both rigs,** per [BUILD.md §8](BUILD.md#8-build-order) step 5: "Add a
  second radio only after all of the above is boring."
  **Hands:** not yet named. **Done when:** not yet stated. [§8](PLAN.md#8-sequencing).
  (issue to be filed)

## Parked

- **The `lslocks` fragility.** Re-opened only if the smoke suite fails again. (issue to be filed)
