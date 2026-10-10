---
name: new-step
description: Scaffold the next setup/steps/NN-name.sh build-step script so it meets the contract CI enforces and docs/PLAN.md §9b–§9d and §9h set out — idempotent install, a verify() of the observable effect, role refusal from station.yml, and no foundation paths or units. Use when starting any new step script (05-config, 10-decoder, 20-portable-clock, ...).
argument-hint: NN-name
---

# New build step: `setup/steps/$ARGUMENTS.sh`

## Read first

- `docs/PLAN.md` §9b (one script per step; shared vs role-specific), §9c (verify the effect), §9d
  (config), §9h (the foundation denylist), §9k (the order steps are built in), §9l (what is rejected)
- `docs/BUILD.md` §8: the step's own instructions, which the script encodes
- `setup/lib.sh`: the helpers. Use them; do not re-implement them
- `setup/steps/00-drivers.sh`: the worked example, and the idiom to match

## Then

1. Copy [template.sh](template.sh) to `setup/steps/$ARGUMENTS.sh` and `chmod +x` it.
2. Fill the header honestly: what the step does, its BUILD.md section, its role, and **what has
   actually run on hardware** (with the PLAN section that records it), or that nothing has.
3. Decide the role:
   - **Shared** (both rigs run it identically): reads no `station.yml`, asserts no role.
   - **Role-specific**: `require_role <portable|stationary>`, then `require_absent` for every
     block the other role owns. The portable step refuses `position:`; the stationary one refuses
     `uploader:` and any `clock.source` but `ntp`. *Corrected 2026-10-10: the stationary refuses
     `uploader:` only until the change that lands the uploader, which both rigs get (PLAN §9i's
     2026-10-10 update).*
4. Write `install_step` so that a second run changes nothing.
5. Write `verify()` against the observable effect, using the §9c table as the model. It prints its raw
   evidence and dies with a next action.

## The contract — CI fails the push without these

- `parse_args "$@"` and a function defined as `verify()` at the start of a line
- No denylisted path or unit (`ADSB_DENY_PATHS`, `ADSB_DENY_UNITS` in `lib.sh`) on any
  non-comment line. ⛔ Those are foundation: `setup/foundation/`, run by hand (§9h)
- `bash -n` and `shellcheck -x` clean

## Hold to these too (CI cannot see them)

- ⛔ No `--role` flag. No "tested on" header. No `yq` (not on the image; use `station_get`).
- ⛔ Not an `install-all.sh`, and nothing that chains steps. ~~The first build is by hand because
  BUILD.md §8 has human gates (§9e, §9l).~~ *Corrected 2026-10-10: the first build is one command
  (PLAN §9e's 2026-10-04 evening update): `setup/bootstrap.sh` runs `setup/update.sh --bootstrap`,
  the one orchestrator, which runs every step in order. A step still chains nothing. BUILD.md §8's
  human gates (a sky check, a power cycle with the network unplugged) stay human.*
- ⚠️ A comment that states a belief says it is a belief, as `00-drivers.sh` does for the udev
  re-trigger. Never describe the intended end state as the current one.

## Before handing back

Run `bash -n setup/steps/$ARGUMENTS.sh`, and `shellcheck -x` if it is installed. Then have the
`step-reviewer` agent read the script against PLAN §9. Report what it found and what was not checked:
nothing in this skill runs the step on a Pi.
