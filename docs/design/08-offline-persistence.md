# 08 — Persistence, Offline Catch-Up & Notifications

**Status:** Draft v2 — amended per `98-consistency-report.md` (binding). Complies with `docs/design/00-constitution.md` (LOCKED); deviations flagged in §9, never silent.
**Owns:** the save file format and lifecycle, migration, corruption recovery, the offline *fidelity & fairness policy*, the event history rings, the WHILE YOU WERE AWAY report, and **notification policy (sole owner)**. Files: `data/persistence.json`, `data/notifications.json`; save sections `meta`, `notifications`, `event_log`, `pending_report`, and custody of the top-level envelope + `rng_streams`.
**Does NOT own:** the tick scheduler or the catch-up *schedule* (doc 01), the offline **economic** curve (doc 03, report C-20), dispatch policy (doc 06), the Android platform layer or push delivery mechanics (doc 13, report C-71), in-app banners (doc 12), or any other system's save section.
**Spec:** §21, §22, §23, §27, §29, §47, §50, §51 Risk 5. **Constitution:** §2, §4, §5, §9, §10.

> ### Doc numbering — settled (report 98 Ruling Zero)
> The on-disk filenames are canonical; there is no other map. 01 time · 02 buildings/construction · 03 economy · 04 power · 05 water · 06 incidents/dispatch/fleet · 07 weather/Director · **08 this doc** · 09 map/land/districts/population/stability · 10 roads · 11 rendering · 12 UI/UX · 13 Android integration & export. Every cross-reference in this doc now uses those numbers directly; the former "best guess" parenthetical convention is gone.

---

## 1. Overview & Goals

This system makes Core Design Rule 2 — *"The city continues while the player is away"* — true, safe, and fair.

1. **Persistence.** Serialize the sim deterministically, write it so no crash or app update can lose a city, and recover automatically from a damaged file.
2. **Offline catch-up policy.** Doc 01 owns *how many* coarse hours run and in what order. This doc owns *under what rules* they run: fidelity bands, hard fairness caps, the event accumulator, and the report.
3. **Notifications.** Decide what is worth interrupting a person's day for, at what rate, and let them switch each class off.

**Goals.** **G1** Never lose a city (spec §47). **G2** No parallel offline rules engine — offline differences are *rate multipliers fed into the same math*, never a second code path. **G3** Offline is never a punishment: returning must feel like *"look what happened to my city"*, never *"my city was destroyed while I slept"* (spec Risk 5). **G4** 24 game-hours of absence caught up well under 2 s on a mid-range phone. **G5** The report explains *why*, not just *what* (Core Rule 12). **G6** Notifications are hard-capped, classed, and individually toggleable (spec §22).

**Loop role.** Offline catch-up is the compressed replay of `Operate → Crisis` the player did not attend; the report hands them back into `Respond`; notifications invite them back early when the crisis is real.

---

## 2. Mechanics

### 2.1 Division of labour with doc 01 (authoritative)

Doc 01 owns and this doc **does not re-specify**: `CatchUpPlanner`, the decomposition `head_align fine → N coarse → mid_fine → 40-tick fine tail`, `OFFLINE_GRACE_SECONDS = 120` (absences under 2 real minutes credit zero), `OFFLINE_CAP_REAL_MS = 43,200,000` (**12 real hours = 720 game-hours = 30 game-days**; excess discarded, never banked — report C-19), the sliced entry point `advance_coarse_sliced(max_ms) -> bool` with `steps_done()` / `steps_total()` (report C-22), the tick→wall alarm conversion, and `ctx.is_catchup / ctx.catchup_index / ctx.catchup_total`.

The cap constant lives in `data/time.json` and is owned by doc 01. **This doc defines no cap of its own and doc 13 defines none either** (report C-19), and since report 98 §58 (RR-160) **neither does §2.12**: the credited absence is doc 01's C-19 cap and nothing narrows it. §2.12's `max_coarse_hours` — a *performance* clamp that could pull the credited window down to six real hours — is retired; what §2.12 publishes now is a wall-clock budget on the catch-up **veil**, which nothing in `sim/` reads.

This doc adds exactly one thing to each coarse step: an **offline policy band** resolved from `ctx.catchup_index`, carried on the same `TimeContext` as a set of multipliers.

```
OfflinePolicy.band_for(hour_index) -> {damage_mult, incident_mult, fidelity_mult, yield_mult, director_allowed}
```

Systems read these as ordinary rate factors — the same channel kind as weather or the day/night curve. Online they are all `1.0` and `director_allowed = true`, which is why doc 06's "identical online/offline math" invariant survives intact: nothing branches on `is_catchup`, the numbers just differ.

`band.yield_mult` is a **field this doc carries but does not author** — doc 03 populates it from its exponential income taper (report C-20). This doc authors `damage_mult`, `incident_mult`, `fidelity_mult` and `director_allowed`.

### 2.2 Fidelity bands (the cap policy)

Aligned with doc 06's `OFFLINE_FULL_FIDELITY_H = 72` and its `incident_load_damper ×0.5` beyond it. The upper boundary is doc 01's 720-game-hour cap (report C-19).

| Band | Absence hours | Incident λ × | Damage × | Fidelity × (non-economic accrual) | Economic yield × | Director |
|---|---|---|---|---|---|---|
| **FULL** | 0 – 71 | 1.00 | 1.00 | 1.00 | *(doc 03)* | at most 1 pre-warned Tier-1 event (§2.3 rule 1) |
| **DAMPED** | 72 – 719 | 0.50 | 0.50 | 0.60 | *(doc 03)* | suppressed entirely |
| **(discarded)** | ≥ 720 | — | — | — | — | — |

Band boundaries are a pure function of `catchup_index`, so constitution §5 determinism holds exactly.

**Deleted: this doc's flat economic yield column (1.00 / 0.60).** Per report C-20 there is one offline revenue curve and it is doc 03's exponential taper `yield_mult(h) = exp(−(h−4)/90)`, which doc 03 pacing-tested against its guardrail G4. Doc 03 writes it into `band.yield_mult`; this doc never multiplies revenue by a number of its own. **For the offline income curve, see doc 03 §2.11.** Doc 03 also stops keeping its own `absence_hours_elapsed` counter and reads `ctx.catchup_index`.

**Fidelity hour-equivalents `M(H)`** — the integral of `band.fidelity_mult`, applied to the *non-economic* linear accruals this doc still damps (construction work units, population growth, research) and used for the report's honesty line. It is deliberately **not** applied to revenue, so there is no double taper with doc 03's curve.

Generating formula (report C-19 / R-15; the DAMPED span is now 720 − 72 = **648** hours):

```
M(H) = 1.00 × min(H, 72) + 0.60 × clamp(H − 72, 0, 648)
```

| Absence `H` (game-hours) | Real absence | `min(H,72)` | `clamp(H−72,0,648)` | `M(H)` | `M/H` |
|---|---|---|---|---|---|
| 24 | 24 min | 24 | 0 | `24 + 0.60×0` = **24.0** | ×1.000 |
| 72 | 1 h 12 m | 72 | 0 | `72 + 0.60×0` = **72.0** | ×1.000 |
| 240 | 4 h | 72 | 168 | `72 + 0.60×168 = 72 + 100.8` = **172.8** | ×0.720 |
| 372 | 6 h 12 m | 72 | 300 | `72 + 0.60×300 = 72 + 180` = **252.0** | ×0.677 |
| 480 | 8 h | 72 | 408 | `72 + 0.60×408 = 72 + 244.8` = **316.8** | ×0.660 |
| **720 (cap)** | **12 h** | 72 | **648** | `72 + 0.60×648 = 72 + 388.8` = **460.8** | **×0.640** |

Worked, away 6 h 12 m real (doc 01's example, `H = 372`): `M = 252.0` hour-equivalents out of 372 elapsed ⇒ fidelity rate **×0.68**, i.e. 252 crew-hours of construction credited. *(The dollar figure that used to sit here was computed from this doc's deleted flat yield column; the offline ledger total is now doc 03's, from its own curve.)*

Worked, away 24 min real (`H = 24`): `M = 24.0` — short absences are lossless, which is what a check-in-during-lunch player must experience.

Worked, at the cap (`H = 720`, 12 real hours): `M = 460.8` of 720 ⇒ **×0.64**. Attended play is always strictly better per elapsed hour; offline is generous enough to reward returning. Anything beyond 720 is discarded by doc 01 and reported, never banked.

**Damage & wear** in any coarse step:

```
condition_loss = base_hourly_loss(asset, load, weather)
               × band.damage_mult
               × difficulty.offline.difficulty_offline_mult   # casual 0.50 | standard 1.00 | hard 1.30 | crisis 1.60
               × (0.35 if safe_mode else 1.00)                # safe_mode = post-recovery, §2.9
```

The difficulty row above is authored by this doc but **lives in `data/difficulty.json`, owned by doc 03** (report C-17) — one file, one loader, one schema, per-owner rows.

### 2.3 Anti-frustration rules (spec Risk 5 — normative invariants, asserted by tests)

1. **No surprise disasters offline.** The Disaster Director may schedule **at most one** hazard per catch-up session; this doc tightens it: it must be **Tier 1**, may only fire in the FULL band, and only if **a forecast warning for it was already active before the player backgrounded the app** — they saw it and chose to leave. Tier-2 and Tier-3 events never spawn offline. On `casual`, zero. Per report C-55 these invariants are the **outer clamp**: doc 07's fairness rule F8 is tightened to match verbatim and doc 01's recommendation defers to this rule.
2. **Damage ceiling.** Aggregate condition lost across one catch-up ≤ `offline_damage_cap_frac = 0.35` of the city's total condition pool (Σ condition over buildings + utility nodes, sampled at catch-up start). Once hit, further offline damage is zero for the rest of the session.
3. **Per-asset floor.** No asset drops below `offline_asset_condition_floor = 0.15` offline. It can be crippled; it cannot be finished off while the player sleeps.
4. **Nothing is destroyed or removed offline.** Buildings may reach `damaged`; never `destroyed`. No entity is deleted from the world by the offline path, ever. (Overrides doc 06's burn-down outcome while `is_catchup` — the fire instead parks at 0.15 condition and stays an open incident, which is *better* drama: the player arrives to a building still burning.) **Report C-47 upholds this clamp and adds one thing on doc 06's side:** its `destroy_building` cascade op gains an explicit `world.destroy_allowed()` guard, so offline the verb is **refused visibly** — it emits `policy_blocked`-style refusal and leaves the incident open — rather than being silently swallowed by `OfflineGuard`. The clamp here remains the backstop; the guard makes the refusal legible.
5. **No offline deaths.** Population may migrate away by at most `offline_population_loss_cap_frac = 0.08` of city population per catch-up. Casualty outcomes convert to injuries. Consistent with spec §31 — deaths need credible severe conditions, which need an attending player.
6. **Treasury floor.** Offline expenses are paid to zero, then accrue as `deferred_bills`, capped at `deferred_bills_cap_days = 3` game-days of operating expense; while deferred, service efficiency ×0.80. Treasury never goes negative offline.
7. **Return grace.** For `return_grace_minutes = 120` game-minutes after resume, the Director may schedule nothing, and every incident that began offline has its escalation timer frozen. The player always gets time to read the report and act.
8. **Stability floor.** Purely-offline accrual may not push city stability below `offline_stability_floor = 0.20`. Riots and civil emergency are attended content.
9. **The play-NOW layer does not accrue** *(Wave 15, doc 06 §2.16).* Doc 06 §2.16's tappable street opportunities — the crook the police missed, the loose dog, the glint on the kerb — **do not spawn offline, and none is waiting when the player returns**. A catch-up expires whatever it finds past its lifetime and says NOTHING about it: a bounty nobody could have taken is not news, and a "while you were away" line listing $2,400 of money the player was never offered is worse than silence. Nor is it deferred, banked or paid at a taper — the layer pays for *attention*, and attention is the one thing an absent player did not spend. This rule is the only one of the nine that is **structural rather than clamped**: the spawner is a fine-path system whose `advance_coarse` expires and returns, so there is no output for `OfflineGuard` to clamp and no branch in the rules to get wrong. Its `street` RNG stream does not move a single position across a catch-up of any length (`tests/test_street_opportunities.gd`), which is also why the coarse-step balance matrix is bit-identical to the build before the layer existed.

These are enforced by `OfflineGuard`, a wrapper the coarse path installs around the mutation calls (`apply_condition_delta`, `apply_population_delta`, `destroy_entity`, treasury debit). It is a clamp on outputs, not a branch in the rules — G2 holds.

### 2.4 Auto-response during catch-up

**Owned by doc 06.** `DispatchPolicy.allows()` runs from the identical assignment loop online and offline; the `dispatch` save section holds the policy (`auto_dispatch_*`, `utility_priority_order`, `*_reserve_units`, `reserve_break_tier`, `auto_spend_contractor`, `auto_repair_cost_cap`, `offline_notify_min_priority`). Travel time comes from doc 10's `route_minutes(a, b, profile)`, which that doc guarantees is mode-invariant.

This doc adds only two things:

- **`reserve_treasury` (default $50,000)** — an auto-spend floor the offline path may not cross, layered on top of `auto_repair_cost_cap` (which is per-repair). Without it, a long absence can drain a treasury to zero through many individually-cheap repairs.
- **`policy_blocked` surfacing.** Every auto-dispatch or auto-repair refused by the player's own policy emits a `policy_blocked` event that **always surfaces individually** in the report. The player must be able to learn that their own setting cost them a district — otherwise the policy UI is a trap.

### 2.5 Save file layout on disk

> ### Shipped 2026-08-19 — the unification
>
> Until this date the project had **two save formats and one game**. `SaveManager` implemented everything below — generation files, the manifest commit, digests, retention, quarantine, the §2.9 gate, the §2.8 ladders — and was reachable from nowhere: `game/save_service.gd` wrote its own flat `{"format":1,"meta":{…},"ui":{…},"state":{…}}` file per slot. Doc 91 §8 marked six rows PARTIAL for that one reason. `SaveService`'s five-method API is unchanged; its storage half is now `SaveManager`.
>
> **The layout as shipped.** A player-facing slot IS a slot directory, so the ladder applies per slot rather than only to a notional slot 0:
>
> ```
> user://saves/slot_0/manifest.json      # autosave slot
> user://saves/slot_0/gen_000042.sav
> user://saves/slot_0/quarantine/…
> user://saves/slot_3/…                  # a player's manual save, same shape
> user://saves/slot_3.json               # format 1, read-only, still loads
> ```
>
> **The header moved into `manifest.json`, and that is a strengthening.** `SaveService` put `meta` in its file's first bytes so a load screen could list slots without deserializing a city. Inside a doc-08 envelope it cannot: §2.6's body is `sort_keys = true` by law, which is what makes the digest meaningful, and sorted keys put the city section ahead of `meta`. The manifest is the natural home — this section already calls it "tiny; its rename is the commit point" — so `manifest.active` carries a `meta` field holding the shell's header (`slot`, `saved_at_unix`, `day_index`, `population`, `treasury`, plus `format` / `save_reason` / `sim_time_minutes` / `app_version`). It is a few hundred uncompressed bytes per slot, it is committed by the same rename as the generation, and unlike the old brace-scan it survives a body that is corrupt **and** unparseable. The old scan is kept for one case only: a manifest with no header, where the service decompresses the active generation and brace-matches `meta` out of it rather than hiding the slot.
>
> **Envelope `schema_version` is 1, not §8's 7.** Seven was an illustration written when this doc imagined a shipped history to have laddered through. No generation file has ever existed on a device, so there is nothing to migrate and v1 is the honest number. `data/persistence.json.save.current_schema_version` repeats it for documentation and `tests/test_save_manager.gd` asserts the two agree — a tripwire, never a source, because the ladder that has to agree with the number is code.
>
> **`debug_plain_mirror` ships `false`.** §2.5 asks debug builds to emit a plain `.json` beside each generation. The mirror is not written yet; the tunable exists and is off. What it would buy — a save you can read in an editor — is already available through the format-1 fixture and `JSON.stringify` in a test, and a second copy of every save on a phone is a cost with no reader. Flagged as owed, not silently dropped.

```
user://saves/slot0/
  manifest.json        # tiny; its rename is the commit point
  gen_000123.sav       # full save, generation 123 (active) — immutable once renamed into place
  gen_000122.sav …     # retained checkpoints
  pinned_premigration.sav
  pinned_precatchup.sav
  quarantine/bad_gen_000121.sav
  crash_report.json    # only when every candidate failed
user://settings.cfg    # device-scoped (audio, graphics, a11y, notification prefs). NOT in any save slot.
```

**`user://settings.cfg` (report C-03, constitution §2 amendment #3).** Device-scoped, outside every save slot, **never touched by the save migration ladder**, never rolled back by checkpoint recovery, and it survives city deletion. This doc adopts doc 11's `settings.cfg` naming — the former `settings.json` name is withdrawn. Docs 08 (notification prefs), 11 (graphics preset), 12 (accessibility) and 13 (permission-flow bookkeeping) all write into this one file; the `notifications` **save** section keeps only what must roll back with the city (buckets, last-sent stamps, scheduled alarm ids), while the player's *preferences* (master switch, per-class toggles, quiet hours, re-engagement switch) live in `settings.cfg` and are mirrored into the section on save purely so a report can explain what was suppressed.

> **As built (Wave 18, PA-15 · A91-D-70).** Until this wave the file was a path
> with no caller: `ui/settings_model.gd:settings_file_path()` returned the name
> and nothing opened it, so every preference above lived only inside the city's
> save and reset at the title door, on New City and on every other slot — the
> case §2.13.4 forbids by name. `game/device_settings.gd` is now the whole of the
> I/O and it is a **section registry** rather than one owner's format: `settings`
> (doc 12's rows, the `device_scoped_keys` subset) and `permission` (doc 13
> §2.7's `asked_count` / `last_asked_unix` / `reprompt_count`). Every write
> re-reads the file and replaces one section, so a permission write cannot lose a
> settings change made a frame earlier, and every write is tmp+rename — the same
> commit discipline §2.6 uses for a generation, and for the same reason: a
> settings write lands on the tap the player makes on their way out of the app.
>
> **One deviation from PA-15's own fix column, on this section's authority.** The
> audit's fix text puts "the budget's last-sent stamps" in `settings.cfg` too;
> this section says the opposite and wins — the `notifications` **save** section
> keeps what must roll back with the city (buckets, last-sent stamps, scheduled
> alarm ids) and only the *preferences* are device-scoped. `NotificationBudget`
> is unchanged; its per-class switches already reach the device file as doc 12
> rows.

Generation files are **versioned JSON** (constitution §2) written via `FileAccess.open_compressed(..., COMPRESSION_ZSTD)`. The format is JSON; compression is transport. Debug builds also emit a plain `.json` mirror. Report C-05 records this as compliant.

**This directory is the only persistence implementation in the project (report C-24).** No other doc writes city state: doc 13's `city.tmp → city.json` path, its 3-deep `city.bak.N` rotation, its fallback logic and its `saves_recovered_from_backup` counter are **deleted**; the generation ladder, `manifest.json` commit point, quarantine and repair notes below replace all of them. Doc 13's pause sequence step 3 is `SaveManager.request_save("pause")`. Doc 13 keeps exactly two things on this axis: the ≤ 250 ms pause budget and the Android lifecycle ordering — both of which this doc's §2.6 budget already fits inside.

**Envelope** — so the digest can cover exactly what is embedded:

```
{"schema_version":7,"body_sha256":"<64 hex>","body":<body-json>}
```

`body-json` = `JSON.stringify(body, "", true, true)` (`sort_keys = true`, `full_precision = true`). Sorted keys + full float precision make serialization byte-stable, which makes the digest meaningful and save-diffing possible in tests.

### 2.6 Atomic write protocol

Sim state is RefCounted and not thread-safe, so: **snapshot on the sim thread, encode and write on a worker.**

1. **Barrier.** Only between ticks, never mid-tick.
2. **Snapshot** (sim thread, ≤ 25 ms): each system's `serialize()` in a fixed order → a pure Dictionary/Array/int/float/String tree with no object references. Sim resumes immediately.
3. **Encode** (worker): stringify → SHA-256 of the body text → assemble the envelope **by string concatenation**, so the hashed bytes are literally the embedded bytes → zstd.
4. **Write** `gen_NNNNNN.sav.tmp`, `flush()`, release.
5. **Rename** tmp → `gen_NNNNNN.sav` (atomic within a directory on ext4).
6. **Commit:** build the new `manifest.json`, write `.tmp`, flush, rename. **This rename is the commit.** Until it lands the previous generation is still active.
7. **Sweep** generation files referenced by neither `active`, `history`, nor `pinned`. Sweep failure is non-fatal.

A crash anywhere before step 6 leaves the previous save active plus one orphan, cleaned next sweep. There is no window in which the active save is partially written.

```json
// manifest.json
{"manifest_version":1, "slot":0,
 "active":{"file":"gen_000123.sav","schema_version":7,"sim_time_minutes":918240,
           "sha256":"…","real_unix":1755500000,"reason":"pause","bytes":118432},
 "history":[{"file":"gen_000122.sav","…":"same fields"}],
 "pinned":{"pre_migration":"pinned_premigration.sav","pre_catchup":"pinned_precatchup.sav"},
 "high_water_sim_minutes":918240, "max_seen_unix":1755500000,
 "app_version":"0.4.1", "next_generation":124}
```

**Cost budget:** snapshot ≤ 25 ms (at most one dropped frame), encode+compress+write ≤ 120 ms (worker). A trigger arriving while a save is in flight is coalesced, except `pause`/`quit`, which block up to 400 ms for completion — inside which doc 13's ≤ 250 ms pause budget is met by the snapshot alone (≤ 25 ms), since the encode/write worker outlives the pause callback and commits after it.

*(The encode worker in step 3 is **not** affected by report C-22's threading ruling: it touches only the detached pure-data snapshot from step 2, never live sim state. C-22 governs the catch-up path, which is main-thread sliced — see §2.12.)*

### 2.7 Checkpoint cadence & rotation

| Trigger | `reason` | Note |
|---|---|---|
| Every 5 real minutes of foreground play | `autosave` | Real-time timer driven by the shell. |
| App pause / focus loss | `pause` | The highest-value trigger on Android — how most sessions actually end. **Doc 13's lifecycle step 3 calls `SaveManager.request_save("pause")`** (report C-24); it does not write files itself. |
| Explicit quit / back-out | `quit` | |
| Before a schema migration | `pre_migration` (**pinned**) | Kept until 3 successful launches on the new app version. |
| Before catch-up results commit | `pre_catchup` (**pinned**) | Kept until the next successful autosave. |
| After catch-up commits | `post_catchup` | Makes the report survivable. |
| Player taps Save | `manual` | |

**Retention** — at most **6 unpinned + 2 pinned** (~8 × 120 KB ≈ 1 MB). Slots filled greedily newest-first, one generation per slot: **A** active · **B** newest other · **C** newest ≥ 30 real min older than A · **D** ≥ 6 real h · **E** ≥ 24 real h · **F** ≥ 7 real days. Dense recent protection plus a week-deep escape hatch against a bug that corrupts state slowly.

> ### Shipped 2026-08-19 — the ladder subsumes doc 13's autosave shadow
>
> **Ruling: the two-slot autosave rotation is retired, and this ladder replaces it.** Doc 13 §2.11 had `SaveService` alternate its autosave between slot 0 and a shadow at slot 7, because "one slot cannot survive a save that is structurally perfect and semantically wrong, written moments before the process died." That reasoning is exactly right and this section answers it strictly better:
>
> | | two-slot shadow | ladder (A–F) |
> |---|---|---|
> | fallbacks | 1 | up to 5 |
> | age spread of the fallback | one autosave interval | 0 / 30 min / 6 h / 24 h / 7 days |
> | fallback verified before it is offered | no — a full parse only | yes — SHA-256 of the body (§2.9 check 3) |
> | commit point | file rename | manifest rename, after the generation is durable |
> | bad candidate | overwritten next rotation | quarantined, never deleted |
> | cost | slot 7 unusable by the player | none |
>
> A shadow is a ladder two deep with no checksum, so it is subsumed on every axis. `AUTOSAVE_SHADOW_SLOT` is deleted, the autosave always lands on slot 0, and slot 7 is a player slot again.
>
> **One thing outlives it: the files.** A phone upgrading from a build that alternated has a format-1 save in slot 7, and it is the *newer* half half the time. `LEGACY_AUTOSAVE_SHADOW_SLOT` is kept for exactly that read — never written, consulted only when the ladder is empty — so an upgrading player's first unclean launch does not cost them the autosave interval the rotation existed to save. It stops mattering the moment the first post-upgrade autosave commits generation 1.
>
> **The crash-sentinel contract is unchanged and still answered.** `CrashSentinel.recovery_slot()` asks `SaveService.last_good_autosave_slot()` and gets a slot index; it now means "the autosave slot, when anything in its ladder passes the §2.9 gate", and −1 otherwise, at which point the sentinel falls back to `latest_slot()` exactly as before. The probe behind it is **side-effect free by contract**: it does not quarantine, does not deserialize, and emits no `failed` signal, because a damaged checkpoint found by a health check is an expected finding and not an error to put in front of a player. `SaveManager.peek_newest()` is that probe.
>
> **Reason strings ride the manifest.** Every entry carries §2.7's `reason`, so `pre_migration` and `pre_catchup` pin from the shell as specified; `SaveService.save_slot(sim, slot, reason)` takes it as an optional third argument (default `manual`), and `autosave()` passes `autosave`. Doc 13's pause step becomes `save_slot(sim, 0, "pause")` when the lifecycle node is rewired — see the doc 13 integration note.

### 2.8 Versioning & migration

**Two levels, both required** (the sibling docs already assume per-section versions):

- **Envelope `schema_version` (int)** — owned here. Covers the envelope and the section *registry*: which sections exist, top-level key names, section renames/splits. Bumped only when the shape *between* sections changes.
- **`section_version` (int) inside every section** — owned by that section's system, with its own independent ladder. Adding a field to `power` bumps `power.section_version`, not the envelope.

> **Settled by report C-25.** `section_version` inside every section; `schema_version` only on the envelope. Docs 01, 02, 04, 09, 10 and 12 apply the one-word rename in their own §3.2; docs 05, 08 and 13 already comply. This doc's sections (§3.2) use `section_version` throughout and always have.

> ### RULED 2026-08-21 — a SECTION rung is sufficient; `city` is a section like any other (report 98 RR-75, doc 93 §P2)
>
> **The question, which has now been asked three times.** When `water.section_version` went 2 → 3 and `roads.section_version` 2 → 3 (RR-60 / RR-60b) the bytes on disk changed and `city.section_version` did not. Twice a wave has stopped to ask whether the city body owed a rung beside them as an *epoch marker*, and twice the answer has been written in a note under one shipment, where the next wave does not find it. It is written here instead, because this is the section that owns the counters.
>
> **The ruling.** **No.** A section rung is sufficient when the body's shape holds. Three counters, three triggers, and no counter may be forced by a change it does not own:
>
> | counter | MOVES when | does NOT move when |
> |---|---|---|
> | envelope `schema_version` | the section **registry** changes — a section appears, disappears, splits, is renamed, or a top-level key moves *between* sections | any section changes its own contents |
> | `<section>.section_version` | that section's own **shape** changes, or the **rules under which that section's own state is advanced** change | a sibling section takes a rung |
> | `city.section_version` | the same two triggers for the `city` section — **plus** a rules change no single section owns (scheduler, phase order, or a cross-section association) | `water`, `roads` or any other section takes a rung of its own |
>
> **This is the second bullet above, applied.** *"Adding a field to `power` bumps `power.section_version`, not the envelope"* — and, for exactly the same reason, not `city`'s either. A per-section ladder that a sibling can force is not independent, and independence is the whole reason §2.8 gave every section one.
>
> **The v1 → v2 argument does not say otherwise; it says this.** That note is the strongest statement in the project that a version records *rules* and not only *shape*: "a save is a promise about what the binary that wrote it would do next", and "`section_version` is the only field a future migrator can key on to know which set of rules a body was last advanced under". The field it names is the **changed section's**. When water's rules move, `water.section_version` is that key, and a `city` rung beside it would be a second record of one fact — the scattering C-17 exists to stop.
>
> **The test, so this is checkable and not a preference.** *Does an old body still mean what it meant?* A v6 city body written by the pre-RR-60 binary restores under the post-RR-60 binary to **exactly** the city it restored to before: the two new keys are simply absent and both loaders fall back to the behaviour they always had. Where that holds and the only thing that moved is inside a section that took its own rung, `city.section_version` stays put. `tests/test_save_migration.gd` and `tests/test_save_determinism_days.gd` are the gates.
>
> **What this forbids: the pure epoch marker.** A `_v6_to_v7` identity migrator with nothing in the body it is about is a rung that describes rules the city section did not have — the same fault the Wave-9 correction below calls out ("a ladder that describes rules the binary did not have is worse than no ladder"), at the same price: every future migrator walks a rung that answers nothing. A rung is taken because a body needs it, never to date-stamp a wave.
>
> **Where the marker belongs instead.** In this section, as one of the dated shipment notes below — which is what the RR-60 rungs already have. The record of *when* is prose; the counter is a contract.

**Ladder.** Pure `Dictionary -> Dictionary` functions registered by source version. They never import sim classes, so a migration written today still works after those classes are rewritten:

```gdscript
const CURRENT_SCHEMA_VERSION := 7
const LADDER := {1: _v1_to_v2, 2: _v2_to_v3, 3: _v3_to_v4, 4: _v4_to_v5, 5: _v5_to_v6, 6: _v6_to_v7}

static func migrate(body: Dictionary, from_version: int) -> Dictionary:
    var v := from_version
    while v < CURRENT_SCHEMA_VERSION:
        assert(LADDER.has(v), "no migration path from v%d" % v)
        body = LADDER[v].call(body); v += 1
    body["schema_version"] = v
    return body
```

Rules for every step: **total** (may not fail; missing input ⇒ documented default; unknown keys preserved); **additive-first** (removed fields are ignored for one version before being dropped); **never reads `data/`** (constants it needs are inlined, because the tables will have moved on); ships with a fixture test.

**Worked example — envelope v3 → v4.** Three real changes: transformers gain `oil_temp_c` (doc 04 §2.6); water pumps' boolean `powered` becomes a tri-state; district `stability` splits into components (doc 09 owns districts and stability per report G-1).

```gdscript
static func _v3_to_v4(b: Dictionary) -> Dictionary:
    var amb: float = float(b.get("weather", {}).get("ambient_c", 18.0))
    for tx in b.get("power", {}).get("transformers", []):
        var load_frac: float = float(tx.get("load_kw", 0.0)) / maxf(1.0, float(tx.get("capacity_kw", 1.0)))
        tx["oil_temp_c"] = amb + 35.0 * load_frac      # doc 04: steady-state rise at rated load = 35 C
        tx.erase("hot")                                 # v3 boolean, superseded

    for p in b.get("water", {}).get("pumps", []):       # bool -> {0 unpowered, 1 grid, 2 backup}
        var was: bool = bool(p.get("powered", true))
        p["power_state"] = 1 if was else (2 if bool(p.get("has_backup", false)) else 0)
        p.erase("powered")

    for d in b.get("districts", []):                    # preserve the aggregate exactly
        var s: float = float(d.get("stability", 0.75))  # agg = 0.30*power+0.20*water+0.30*safety+0.20*services
        d["stability_components"] = {"power": s, "water": s, "safety": s, "services": s}
        d.erase("stability")
    return b
```

**Retired content ids** are remapped after migration via `data/id_remap.json`. An id with no mapping does **not** delete the entity: it is flagged `"orphan": true`, skipped by every tick, drawn as rubble, and listed in a **Save Repair** panel offering a one-tap 100%-of-build-cost refund. Non-destructive by construction.

**Downgrade.** `schema_version > CURRENT` (sideloaded older APK) ⇒ the loader **refuses and does not touch the file**, then offers the newest retained generation at or below CURRENT: *"This city was saved by a newer version. Update the app to continue."*

> ### Shipped 2026-08-19 — format 1 → format 2, the one migration that has real users
>
> The ladder above is for envelope versions that have all existed inside this format. There is one migration that crosses formats, and it is the only one with saves on a device behind it: `game/save_service.gd`'s flat `{"format":1,"meta":{…},"ui":{…},"state":{…}}` file, written into `user://saves/slot_N.json` by every build up to this one.
>
> **It is read, never rewritten.** `SaveService.load_slot()` picks a reader per slot: a generation ladder if `slot_N/manifest.json` exists, the format-1 file otherwise. The gate a format-1 file gets is the one it can pass — it has no digest and no generation — so: the envelope parses, `format ≤ 2` (a file from a newer build is refused under the downgrade rule above rather than half-read into a city), and `state` is a dictionary. The file is then left **exactly as found**. That is deliberate: an untouched pre-upgrade file is its own `pre_migration` checkpoint (§2.7) at zero cost and zero risk, and rewriting a player's save during a load is a write nobody asked for at the least convenient moment. The next save to that slot writes generation 1 beside it, the ladder wins from then on, and `delete_slot` removes both so "delete this city" cannot leave the pre-upgrade city behind for the next launch to resume.
>
> **The fixture is a real file, and it is never regenerated.** `tests/fixtures/legacy_slot_format1.json` is a byte-for-byte capture of a format-1 write produced by the shipped code *before* this change — a seed-4242 city, five hours in, one player-placed house, `ui.onboarding.finished = true`. `tests/test_save_migration.gd` installs it into a slot and asserts the loaded city is identical to what a longhand format-1 reader produces from the same bytes, and stays identical after both advance three hours. The comparison is against a reference reader rather than a recorded hash on purpose: a hard-coded hash fails whenever the sim legitimately changes shape and is then "fixed" by re-recording it, which is how a migration test quietly stops testing.
>
> **Section ladders reach the sim body through a hook, not a fork.** The registry in §3.1 has twenty owners; Milestone 1 has one `capture_state()`. `sim/persistence/dict_section.gd` is the `SaveSection` contract backed by a payload its owner holds, and the shell registers three of them — `meta`, `city`, `ui`. `city.section_version` comes from `sim.save_section_version()` when the sim exposes one and is 1 otherwise, and its ladder is `sim.migrate_save_section(data, from)`, both duck-typed so `sim/city_sim.gd` can grow them on its own schedule. As systems split out of `city` they register their own sections and this adapter loses a key, with no change to the manager above it or the shell beside it.

> ### Shipped 2026-08-20 — `city.section_version` 1 → 2, the routing / sub-step rules epoch
>
> The first bump of a section version in this project, and it is the awkward kind: **the city section's SHAPE did not change.** Not one key was added, removed or renamed, and `CitySim._v1_to_v2` is the identity function. What changed is the rules a body is advanced *under*:
>
> 1. **The fire-spread breakpoint became conditional** on a live `structure_fire` (doc 91 D-15). A quiet game-hour is integrated in fewer, larger sub-steps, and the generators therefore draw a different — statistically identical — Poisson sequence.
>
> **Corrected 2026-08-20 (Wave 9).** This note originally listed a second item — *"dispatch ETAs became street-true"* — and it should not have. Wave 8 wired the router, measured an unbounded incident backlog and took the wiring back out, so **the Chebyshev stand-in is what v2 actually shipped**. Street-true ETAs are **v4**'s, below. The correction is made here rather than left standing because a ladder that describes rules the binary did not have is worse than no ladder: `section_version` is the key a future migrator reads to know which rules a body was last advanced under, and it has to be true.
>
> **Why that is a version bump at all.** §2.8's ladder is usually read as being about shape, and on shape alone this change would be free. It is not free, because a save is a promise about what the binary that wrote it would do *next*. Advance a v1 body under v2 rules and you get a city v1 would never have produced: a different truck answers, at a different minute, and the fire spreads or does not on a different draw. A player who saves under one build and loads under the other sees that, and `section_version` is the only field a future migrator can key on to know which set of rules a body was last advanced under. A version that does not move when the rules move cannot be that key.
>
> **It costs the player nothing.** The identity migrator means every v1 save opens with every building, every dollar and every RNG stream exactly where it was left; save → load → advance is bit-identical *within* the new rules, on both the starter and the benchmark city (`tools/profile_sim.gd --baseline`). `tests/test_save_migration.gd` holds four properties: the rung is stamped into the bytes on disk and not merely into the class; a restamped-v1 generation loads to the same `state_hash` with zero structural repairs; the body goes **through** `migrate_section` rather than around it (asserted on a probe, because an identity migrator that is silently never called looks exactly like one that ran); and the migrator itself is total on an empty body, a current-rung body and a body from a version that does not exist.
>
> **One thing the epoch does repair, and it is not in the migrator.** Doc 04's component record carries a `tile`, and doc 06 uses it as the incident position for every `PowerComponentFailed`. `CitySim._boot_power` added plants, substations, feeders and transmission links with **no tile at all** — `data/starter_city.json` spells a substation's location `terminal`, not `tile` — so all four defaulted to the map origin and that value went into every save ever written. Chebyshev dispatch hid it; doc 10's router does not, because no street lies within snapping distance of (0, 0), so the incident is flagged `unreachable` and escalates to destruction unanswered. The boot path now reads both spellings, `PowerGrid._initial_tile` falls back to a line's own route head, and **`CitySim.restore_state` re-stamps authored power tiles from the boot file on every load** — boot geometry is not player state, so it is re-derived rather than trusted from the body, exactly as `_transformer_cover` already is. That is why the repair lives at the load seam and not on the ladder: §2.8's rules forbid a migrator from reading `data/`, and the authored terminal is in `data/`.

> ### Shipped 2026-08-20 — `city.section_version` 2 → 3, doc 09 §2.14's goal curriculum
>
> The body gains **one key**, `goals`, and gains it additively: every other key is
> byte-for-byte what v2 wrote. It carries the curriculum's counters — which
> objectives are complete, how far the counted ones have got, and the highest
> level the objective route has earned — and it is a save section rather than a UI
> preference for one reason: those counters are sim state, and save → load →
> advance has to stay bit-identical with a curriculum in flight
> (`tests/test_goals_system.gd`).
>
> **What a v2 body cannot carry is the ANSWER.** A city played for thirty
> game-days has no record of which objectives it met, because nothing was
> counting, and reconstructing that depends on the whole restored city *and* on
> `data/goals.json`. §2.8's rules forbid a migrator from reading `data/`, and the
> migrator never sees the standing city either. So the ladder does the only honest
> thing available to it: **`_v2_to_v3` marks the body** (`goals.bootstrap = true`)
> and answers nothing, and `CitySim.restore_state` runs `GoalSystem.bootstrap`
> **last**, once the city is up — every level at or below the city's own level
> complete, the active level seeded from the observable residue of the event kinds
> (houses standing, transformers placed, blocks owned), and everything with no
> residue at zero. The event queue is then emptied, because a restore is not an
> achievement: bootstrapping a level-4 city completes four levels' worth of
> objectives and publishing those would greet a returning player with four
> level-up toasts for work they did last week.
>
> This is the same shape as the Wave-8 power-tile repair above and for the same
> reason: **the load seam is where an answer that needs `data/` and the whole city
> belongs**; the ladder is where an answer that needs only the body belongs.

> ### Shipped 2026-08-20 — `city.section_version` 3 → 4, **the routing / cadence epoch**
>
> Mostly a rules rung, like v2: `CitySim._v3_to_v4` is the identity function and
> every key a v3 body carries means exactly what it meant. It is not *purely* one
> — item 4 below adds two **additive** keys, `power.service_pending_gs` and
> `water.service_pending_h`, each holding the un-banked remainder of the current
> game-minute; a v3 body has neither and restores both at zero, which is precisely
> what a v3 body meant. Four changes land together, and every one of them alters
> what a v3 body would have produced *next* — which is the only thing §2.8's
> ladder is for.
>
> 1. **Dispatch ETAs are street-true.** `CitySim._boot_incidents` constructs
>    `IncidentSystem` with `roads.travel_time_provider()`, so doc 06 §2.10's
>    `eta_minutes` is doc 10's `route_minutes` and not the Chebyshev stand-in.
>    Every arrival minute, every assignment ranking and every `unreachable`
>    verdict is a different number. *(This is the item the v2 note above claimed
>    and did not have; see the correction there.)*
> 2. **Doc 06 §2.10 has a terminal rule** (report 98 RR-26). An incident with
>    nothing committed to it for 24 game-hours becomes ABANDONED, and
>    `max_acceptable_cost_min` is re-fitted 90 → 115. Incidents that used to
>    stand at tier 5 for the rest of the city's life now end.
> 3. **The minute's roads work is spread across the four ticks of the minute**
>    (doc 91 D-15 proposal 2), which reorders draws inside the `traffic` RNG
>    stream.
> 4. **The power and water service ledgers bank per game-minute** (D-15 proposal
>    3). The accumulators are dt-exact, so the settled hour is the same in value
>    and not in float association, and `PowerGrid`'s LIT/DARK hysteresis now
>    samples on a game-minute grid instead of a 15-game-second one. The un-banked
>    remainder is persisted (the two additive keys above) rather than dropped,
>    because a save taken two ticks into a game-minute holds half a minute of
>    service the ledger has not been told about, and a restore that lost it would
>    bank a different slice of that minute from the live city — save → load →
>    advance would stop being bit-identical, which is not a trade this project
>    makes for a cadence win.
>
> **What the migrator deliberately does NOT invent.** Doc 06's new clock measures
> *game-hours since anything was last committed to this incident*, and a v3 body
> records no such thing. Every restored incident therefore starts at zero and gets
> a full game-day before the rule can touch it. The alternative —
> back-dating the clock from `created_h` — would abandon a returning player's
> incidents on the strength of a guess, on the first tick after the update, which
> is the opposite of what a migrator is for.
>
> **It still costs the player nothing structurally.** A v3 save opens with every
> building, dollar and RNG stream where it was left, and save → load → advance is
> bit-identical *within* the new rules on both cities and both paths
> (`tools/profile_sim.gd --baseline`). What it does not get is the city v3 would
> have produced next, and that is exactly what the rung records.

> ### Shipped 2026-09-03 — `city.section_version` 8 → 9, **the commissions board**
>
> A SHAPE rung, and the second one of exactly this shape: doc 03 §2.5b's
> commissions board (report 98 §60 RR-170) adds one top-level key, `contracts`,
> and one entry inside an existing one, `rng.contracts` — which is precisely what
> rung 7 added for doc 06 §2.16's opportunity layer. `CitySim._v8_to_v9` is the
> identity function for the same reason `_v6_to_v7` was, and the reason is the
> §2.8 rule rather than a convenience: **missing input means a DOCUMENTED
> default**, and both defaults are documented. `ContractBoard.deserialize({})` is
> an empty board, which is what a city that has never seen the board should
> restore to; `RngStreams.deserialize` leaves the new stream on the seed
> `hash(master_seed + ":contracts")` gave it at boot rather than inventing a
> state. Stamping an empty `contracts` block in would be WORSE than leaving it
> out — it would record a board the writing binary never had.
>
> **What it costs a returning player: nothing, and one thing it deliberately does
> not give them.** Every building, dollar and RNG stream opens where it was left.
> What a v8 save does not come back with is a commission in hand, because it
> never had one; the board posts a fresh offer on its next posting attempt, which
> is the same answer rung 7 gave a returning player and an empty kerb.
>
> **It is also the rung that moves the four determinism baselines,** and the
> cause is one line: `rng.serialize()`'s key set is inside `state_hash()`, so a
> named stream is a hash change on every city including one that never opens the
> board. Report 98 §60 publishes the before/after for all four.

> ### Shipped 2026-09-04 — `city.section_version` 9 → 10, **the excavation yield**
>
> A SHAPE rung, and the THIRD of this shape — but the first that is *purely*
> shape. Doc 03 §2.8b's `land_works` line (report 98 §69 RR-209) adds:
>
> * `works_stockpile`, one top-level integer — the city's materials yard;
> * `works_yield_total` on every `world_blocks` row — what that block has handed
>   back for life, which is the CLAMP: the per-block ceiling is enforced against
>   a cumulative total, and a counter that reset on load would let a save and a
>   reload pay the ceiling twice;
> * `rng.land_works`, the tenth named stream, plus
>   `treasury.ledger_totals.lifetime_excavation` and
>   `treasury.hour_city_services.excavation`.
>
> `CitySim._v9_to_v10` is the identity function for the §2.8 reason its two
> predecessors were: **missing input means a DOCUMENTED default**, and all three
> defaults are documented. An absent `works_stockpile` is an empty yard, which is
> what a city that has never dug means; an absent `works_yield_total` is 0,
> because those blocks were dug out before anyone was counting and the honest
> answer is a fresh ceiling rather than a retro-charge for money the player was
> never paid; `RngStreams.deserialize` leaves the new stream on the seed
> `hash(master_seed + ":land_works")` gave it at boot.
>
> **Unlike rungs 8 and 9 it is not ALSO a rules rung**, and that is worth
> recording because two in a row were. A v9 city that is never developed again
> advances identically under v10: the yield is credited on a development phase
> COMPLETING and on nothing else, and a city with no pipeline in flight completes
> none. What a returning player loses is nothing; what they gain is that the next
> block they open pays them for what comes out of it.
>
> **It moves the four determinism baselines on shape alone, and report 98 §69.3
> proves exactly that**: `tools/ab_land_works.gd` digests the canonical body with
> these four key groups stripped and the result is byte-identical to the fork's
> published digest on both cities and both paths.
> ### 2026-09-04, Wave 25 — **no rung, and the reasoning is the point**
>
> Doc 04 §2.15.2's `cmd_repair_grid_component` (report 98 §68 RR-206) puts a new
> kind of thing in an existing section: a `ConstructionQueue` job whose payload
> carries `grid_component`, `kind`, `cost`, `damage_fraction` and
> `repair_target`. `city.section_version` stays at **9**, and §2.8's own rule is
> why rather than an appeal to convenience.
>
> **Nothing about the SHAPE moved.** `ConstructionQueue.serialize()` writes each
> job's `payload` as an opaque `Dictionary` and `deserialize()` reads it back
> whole; the queue has never enumerated a payload's keys and no migrator ever
> could. The keys are plain `String`, `int` and `float`, so unlike doc 10's road
> payload (A91-D-47, whose live `Vector2i` degrades to the text `"(3, 4)"`
> through `JSON.stringify`) this one round-trips exactly.
>
> **Nothing about the RULES moved for a body that has one.** A v9 save written
> before this wave carries no such job — the command did not exist — so there is
> nothing to default and nothing to reinterpret. §2.8's *"missing input means a
> DOCUMENTED default"* is satisfied trivially: the absent thing is a job, and a
> city with no crew on a transformer is a city with no crew on a transformer.
>
> **And a rung taken anyway would have been the fault §2.8 forbids.** *"A rung is
> taken because a body needs it, never to date-stamp a wave"* — a `_v9_to_v10`
> identity migrator here would describe a rule the city section did not gain, and
> every future migrator would walk it for nothing.
>
> **What a returning player gets.** A save taken with a crew EN ROUTE restores
> with the job in the queue, the money already spent, and the transformer still
> FAILED — and the crew finishes on the other side exactly as it would have
> before, which `tests/test_ui_transformer.gd`'s
> `test_the_crew_survives_a_save_and_finishes_on_the_other_side` pins by
> restoring one capture twice and advancing both.
>
> **One counter is appended, at 0**, which is doc 09 §2.12's own migration policy
> for `StatsRecorder` (*"counters migrate by appending at 0 and never renaming"*):
> `grid_components_repaired`, beside `grid_components_upgraded` and
> `grid_components_demolished`. **The four determinism baselines do not move**
> (doc 92 §65.5).


> ### Shipped 2026-08-20 — `city.section_version` 4 → 5, **the upgrade-timing epoch**
>
> The smallest rung this ladder has and the clearest illustration of why it is a
> ladder about *rules* rather than about *shape*: **one read moved by one row**,
> and no key on either side of the migration means anything different.
>
> `CitySim.cmd_upgrade_building` read `upgrade_time_hours` from the row of the
> level being upgraded **to**. Doc 02 §2.2 stores the price of the step `L → L+1`
> on the row upgraded **from** (`upgrade_time_hours(L) = 0.65 ×
> build_time(L + 1)`), which is why `BuildingCatalog` requires the column on
> every row below the top and forbids it on the top row. Every upgrade in the
> game except the last step of a ladder therefore ran **one rung's duration too
> slow** — a `house` L4→L5 was billed 7.0 crew-hours for a step doc 02 prices at
> 5.0, a `high_rise` L4→L5 was billed 148 for 87. Reported as RR-29(h), ruled and
> fixed as report 98 **RR-38**.
>
> `CitySim._v4_to_v5` is **the identity function**. There is no field to add, no
> default to invent, and — deliberately — **no re-pricing of the construction
> jobs already in the body**. `ConstructionQueue` serialises
> `required_crew_hours` and `required_work_units` per job, so an upgrade in
> flight when the player updates finishes on the bill it was quoted, and the
> correction reaches them on the next upgrade they buy. Re-pricing a paid-for job
> downward mid-flight would be a gift and upward would be a theft; leaving it
> alone is the only one of the three that is a *record*.
>
> **What the rung actually records**, and why it is not free even though the
> migrator is: a v4 body advanced under v5 rules produces a city v4 would never
> have produced. Every upgrade the player starts after the update completes
> sooner, so construction completion minutes shift, and everything downstream of
> a completion minute — population, demand, revenue, the RNG draws taken on the
> tick a building lands — shifts with it. Measured: the `curriculum` agent's
> 45-game-day end-state hash moves on **all three** of doc 92's seeds.
>
> **`tools/profile_sim.gd` is byte-identical on both cities and both paths, and
> that is a fact about the instrument rather than about the rung.** Its identity
> pass boots a city and advances it; nobody in it ever issues
> `cmd_upgrade_building`, so a digest taken with no player in the loop cannot see
> a change to what a player's command costs. Save → load → advance stays
> bit-identical *within* the v5 rules, which is what `--baseline` proves and what
> §2.7's contract asks for. Doc 92 §27.3 carries the full hash ledger, including
> the two matrix agents that never upgrade and reproduce every column to the
> printed digit — the control that says this epoch reaches the sim through
> exactly one command.

> ### Shipped 2026-08-20 — `city.section_version` 5 → 6, **the difficulty epoch**
>
> Doc 03 §2.9's preset stops being a thing only the Disaster Director knows and
> becomes the **city's** (doc 91 A91-D-19, ruled in doc 93 §K1). Under v5 exactly
> one of the sixteen difficulty knobs was reachable — doc 07's `pressure` row,
> through `data/director.json`'s read-only mirror — and the other fifteen were
> `Treasury.DIFFICULTY_STANDARD` on every boot forever. Under v6 the preset
> prices every build, upgrade, land purchase, development phase and repair
> (`M_build` / `M_land` / `M_dev` / `M_repair`), scales revenue and recurring
> expense (`M_rev` / `M_exp`), sets the revenue floor, the credit APR, the
> relief-grant allowance and the offline taper, and drives doc 06's escalation and
> generation multipliers as well as doc 07's four pressure knobs.
>
> **The body's SHAPE does not move, and that is the interesting part.**
> `DisasterDirector.serialize()` has written `"difficulty"` since doc 07 shipped,
> and `deserialize` has keyed `_difficulty_locked` on it — so **the preset is
> already in every v5 body**. `CitySim._restore_difficulty` reads it back out of
> that section and re-pins the treasury's twelve economic knobs, the Director's
> four pressure knobs and doc 06's escalation pair. Doc 93 §K2 rules why there is
> no second copy at city level: two records of one fact is the scattering report
> 98 C-17 exists to stop, and a new key in `canonical_capture()` would move
> `state_hash()` on the DEFAULT preset, which this change may not do.
>
> `CitySim._v5_to_v6` is therefore **the identity function on every save the game
> has ever written**, and it adds **no top-level key, ever**. It writes exactly
> one thing, into one body: a `director` section that exists but does not name its
> preset gets `"standard"`. That is not a guess about what such a body meant —
> under v5 only `standard` was reachable, so `standard` is what it was played on.
> A body with no `director` section at all is a fragment rather than a city and is
> left alone; `restore_state` defaults it to the same preset anyway. Doc 08 §2.8's
> three rules hold: TOTAL, additive-first, and it reads no `data/` (the preset
> NAMES a row, it does not carry one).
>
> **What the rung records**, since the migrator does nothing: a v5 body advanced
> under v6 rules is a city v5 could not have produced *if it names a non-default
> preset*, and is bit-for-bit the same city if it names `standard`. That is the
> only rung on this ladder whose cost depends on a value in the body rather than
> on the binary, and it is stated that way rather than rounded to "identity":
> `tools/profile_sim.gd --hash-only` is byte-identical on both cities and both
> paths (the identity pass founds on the default), doc 92 §29.1's seven-strategy
> matrix is byte-identical to §27.6's post-fix column, and doc 92 §29.3 measures
> what the other three presets do instead.
>
> **Save → load → advance is bit-identical on all four presets**
> (`tests/test_difficulty.gd`): a city saved on `hard`, loaded into a process that
> booted on `standard`, and advanced 12 game-hours has the same `state_hash()` as
> the one that never stopped. That is the property that makes the preset a save
> section rather than a launch flag.

> ### Shipped 2026-08-20 — two SECTION rungs, and no envelope rung
>
> **`water.section_version` 2 → 3** (`demand.zone_sums` and `pending`) and
> **`roads.section_version` 2 → 3** (`last_hour_sampled`), from doc 91 A91-D-30
> and report 98 §26 RR-60. All three keys are the same KIND of thing and it is
> worth naming: **they are history, not state.** A running incremental float sum,
> a rebuild the city owes but has not done, and the cursor of a once-per-game-hour
> sampler are none of them re-derivable from the body, and every one of them was
> being re-derived. Additive, documented in their own doc's §3.2, and
> `city.section_version` stays at **6**.
>
> **That last part is now a RULE and not a decision taken once** — see §2.8's
> ruled block above (2026-08-21, report 98 RR-75, doc 93 §P2). What follows is
> the reasoning it was generalised from; the rule is the thing to quote.
>
> That last part is the decision worth writing down. §2.8's rule is that a rung
> records a change of shape *or of rules*, and here neither moved at CITY level:
> the body gains no top-level key, no existing key changes meaning, and a v6 body
> written by the old binary restores under the new one to **exactly** the city it
> restored to before — the two new keys are simply absent and both loaders fall
> back to the behaviour they have always had. What did change is what those two
> SECTIONS record about themselves, which is what a per-section ladder is for and
> the whole reason §2.8 gave every section one.
>
> **The property the two rungs buy** is the one this document has claimed since it
> was written and could not prove: *the same save plus the same elapsed time
> produces the same city.* It did not, past the first game-day, and the reason was
> a quantity neither section was writing down. `tests/test_save_determinism_days.gd`
> is the gate — 2 h, 26 h, 50 h and seven game-days, on the founding city and the
> benchmark city — and the reason it is stated in game-DAYS is that every gate
> before it saved inside the first one.

> ### Shipped 2026-08-21 — `city.section_version` 6 → 7, the opportunity layer
>
> **A SHAPE rung, and the first one since v3.** Doc 06 §2.16 adds the tappable
> street layer, and with it two additions to the city body: one top-level key,
> `street` (`{next_id, live: […]}` — the roster of bounties standing on the
> city's kerbs, so a save taken mid-crook restores the crook), and one entry
> inside an existing key, `rng.street` (constitution §5's eighth named stream,
> report 98 RR-77).
>
> **`CitySim._v6_to_v7` is the identity function, and here that is not a
> formality — it is the complete answer.** Both additions restore correctly from
> a v6 body that has neither:
>
> - `OpportunitySystem.deserialize({})` yields an empty roster at `next_id = 1`,
>   which is exactly what a v6 city had. Under v6 nothing could spawn, so "no
>   live opportunities" is not a default invented for the save — it is the fact.
> - `RngStreams.deserialize` walks the streams it HAS and takes each one's entry
>   only if the body carries it, so a v6 body re-seats its seven known streams
>   and leaves `street` on the seed `hash(master_seed + ":street")` gave it at
>   boot. That is the same position a fresh city of that seed starts from, which
>   is the only sensible place for a stream nobody has drawn from.
>
> So the migrator writes **no key at all**, and that is the deliberate choice
> §2.8's additive-first rule asks for: a migrator that materialises defaults has
> to be re-read every time the default changes, and `restore_state` already
> answers this one. The v5 → v6 rung took the same line for the same reason.
>
> **A row of the v7 roster widened in Wave 15 and did NOT take a rung** (report
> 98 RR-93). `born_gm` — the spawn game-minute, which doc 11 §2.17 anchors a
> body's wander beat to so a cold load restores the street mid-stride instead of
> restarting it — is a new field on an existing row, and `deserialize` derives
> it from `spawned_h × 60` when a body does not carry one. That derivation is
> *exact*: it reproduces the number the spawner would have written, so a v7 body
> from before the field is not a body with a guessed beat. **A field a reader
> can derive from what the body already carries is additive, and additive
> changes do not take rungs** — that is §2.8's rule, and taking one here would
> have been the pure epoch marker this section forbids two hundred lines above.
> The field DOES move the fine determinism baselines, because the persisted row
> is hashed; doc 92 §40.1 publishes the delta and the multi-day
> save → load → advance identity gate is green.
>
> **What the rung costs the player: nothing**, and they gain the layer on the
> next game-minute they spend looking at the city. **What it costs the
> baselines:** `state_hash()` moves for every city, founding and played alike,
> because the `rng` block has an eighth entry and the body a twenty-ninth key.
> Nothing else in the body changes value — the spawner reads the city and writes
> only its own section, perturbs no other stream, and creates no money without a
> tap. Report 98 RR-77 turns that last sentence into the test it needs to be.
>
> **And it is a §2.3 rule-9 system**, which is why this rung does NOT change what
> a catch-up produces: the spawner's coarse path expires and returns, drawing
> nothing, so an offline advance of any length lands on the same city v6 would
> have produced apart from the two added keys.

### 2.9 Load & corruption recovery

Candidate order: `manifest.active` → `manifest.history[…]` → `pinned.pre_catchup` → `pinned.pre_migration` → directory scan sorted by embedded `sim_time_minutes` descending.

Per-candidate gate — fail any ⇒ quarantine and advance:

| # | Check | Failure means |
|---|---|---|
| 1 | Opens and decompresses | Truncated / flash error |
| 2 | Envelope parses with all three keys | Interrupted write |
| 3 | Recomputed SHA-256 of body text matches | Bit rot / tampering |
| 4 | `1 ≤ schema_version ≤ CURRENT` | Downgrade (handled above) |
| 5 | Envelope + all section ladders complete | Missing migration step |
| 6 | `validate_structural()` passes | Logic corruption |
| 7 | `sim_time_minutes ≤ manifest.high_water_sim_minutes + 1` | Time moved impossibly forward |

`validate_structural()` asserts: every registry section present (missing ⇒ that system's `default_section()`, logged as a repair note); `sim_time_minutes ≥ 0` and `== time.tick_index / 4` (doc 01's invariant, constitution §4 as amended by report C-01); all **eight** RNG streams present with int seed+state (`street` joined in Wave 15 per report 98 RR-77 — and note that a MISSING stream is not a rejection: `RngStreams.deserialize` walks the streams it has and leaves an absent one on its boot seed, which is the only reading that lets a save from an older build open at all); entity counts in `[0, 200000]`; no dangling entity references. Dangling references below `repair_threshold_frac = 0.02` of entities are **repaired** and noted; above it the candidate is rejected.

**Quarantine, never delete** (cap 3 files, oldest evicted) so a support path exists.

**Recovery UX.** When the loaded candidate is not `manifest.active`:
- *"Recovered your city from a checkpoint. You lost about **N minutes** of progress."* — `N = (high_water_sim_minutes − loaded.sim_time_minutes) / 60` real minutes.
- The absence is measured from the **loaded** generation's `real_unix`, so the lost wall-clock is replayed rather than skipped.
- **Recovery grace:** catch-up runs with `safe_mode = true` (damage ×0.35, zero Director hazards) and the Director stays suppressed for `recovery_grace_minutes = 240` game-minutes after resume. A save bug must never cost a city.

**Total failure:** nothing deleted, `crash_report.json` written (manifest, per-candidate failure codes, sizes, app version), player offered *"Start a new city"* or *"Keep these files and contact support"*.

**Clock tamper.** `meta.max_seen_unix` is monotonic. If `now_unix < max_seen_unix` the device clock moved backwards: elapsed credits zero, `clock_rollback_count += 1`, play continues. We clamp; we never punish.

### 2.10 Event history rings

Two persisted rings so a flood of routine events can never evict the story (constitution §9):

| Ring | Capacity | Admits |
|---|---|---|
| `critical` | 64 | `sev ≥ 3`, anything permanently changing the map, anything needing a decision |
| `routine` | 448 | everything else |

Entry (~110 bytes; ~56 KB total):

```json
{"t":918240,"c":"power","k":"transformer_failed","sev":3,"ref":"pwr_tx_0142",
 "d":{"district":"d3","minutes_out":47,"pop":4120},"n":1}
```

`t` sim_time_minutes · `c` category · `k` event key (indexes `data/notifications.json.events`) · `sev` 0–4 · `ref` entity id · `d` payload · `n` aggregate count.

**Aggregation.** During catch-up, events go to a `CatchupAccumulator`, not straight into a ring. Per `(category, key)` it keeps a count plus `exemplars_per_key = 3` exemplars, ranked by severity then recency; only exemplars enter the rings, counts become report chips. Keys marked `"aggregate": false` bypass this and always get their own entry. This is what lets a full **720 game-hours** (the report C-19 cap) of history fit in 512 slots.

`event_log.report_marker_time` records when the player last acknowledged a report; the next report covers exactly `(report_marker_time, now]`.

### 2.11 WHILE YOU WERE AWAY report

Built by sim as a plain Dictionary, rendered by doc 12, **persisted in `pending_report`** so killing the app before reading it loses nothing. Fixed priority order; **empty sections are omitted**.

| # | Section | Content | Cap |
|---|---|---|---|
| 0 | **Header** | *"Away 6h 12m — 15 city days passed."* Fidelity note when capped (*"Your city ran for 30 days — the maximum"*, per doc 01's wording; 720 game-hours = 30 game-days at the report C-19 cap). Recovery banner if §2.9 fired. | — |
| 1 | **NEEDS YOU NOW** | Unresolved state *right now*: active hazards, districts dark > 60 game-min, burning buildings, deferred bills, blocked construction, units still committed. Each row deep-links. | 5 rows |
| 2 | **CRISIS TIMELINE** | Chronological cause→effect beats from the `critical` ring, built by walking doc 06's `incident.cause` links: *"02:14 — Lightning struck Feeder F-3 → Harbor District dark 47 min → hydrant pressure fell → 2 burglaries."* | 6 beats |
| 3 | **CITY LEDGER** | Taxes, expenses, net, deferred bills, treasury before → after (all from doc 03), and the rate stated honestly — *"offline rate ×0.68"* for the economic figure doc 03 realized, *"fidelity ×0.68"* for `M(H)/H` (§2.2) when the two differ. | — |
| 4 | **PROGRESS** | Construction completed, upgrades, land developed, population Δ, unlocks. | 5 + "N more" |
| 5 | **RESPONSE SUMMARY** | Incidents by class (spawned / auto-resolved / open), units dispatched, avg response minutes, auto-repair spend, `policy_blocked` count. | — |
| 6 | **AGGREGATE COUNTS** | Chips: *"23 minor incidents · 4 crimes · 1 water main break"*. | — |
| 7 | **Footer** | Grace timer; Save Repair entry; forecast reconciliation lines (§2.13). | — |

**Surface vs aggregate (normative).** Always individual: `sev ≥ 3`; anything that permanently changed the map; anything needing a decision; every `policy_blocked`; and the single worst event of each category even at `sev ≤ 2`. Always aggregated: `sev ≤ 2` routine events, incidents auto-resolved without consequence, per-hour economy.

**Suppression.** No report when doc 01 credited zero elapsed, or when `elapsed_game_minutes < report_min_absence_minutes (10)` **and** nothing `sev ≥ 2` occurred. A 30-second app-switch must never produce a modal.

**NEEDS YOU NOW ordering:**

```
urgency = 100 × severity_weight[sev]            # [0,1,3,7,15]
        + 0.5 × minutes_unresolved
        + population_affected / 500
        + 30 if escalation_eta_minutes <= 60 else 0
        + 50 if class in {hazard, fire, hospital_threat, water_outage} else 0
```

Worked: a 47-min structure fire, sev 3, 900 people, escalating in 20 min ⇒ `700 + 23.5 + 1.8 + 30 + 50 = 805.3`, ranked above a 6-hour sev-2 outage affecting 4,000 ⇒ `300 + 180 + 8 + 0 + 50 = 538`. Fire first. Correct.

### 2.12 Performance budget

**Reference device:** Snapdragon 7-series-class mid-range Android, typed GDScript, Godot 4.7.2 Mobile.
**Reference city:** 800 buildings, 500 power nodes, 350 water nodes, 24 districts, 60 vehicles, 30 concurrent incidents, 20 construction projects.

The assignment target is **24 game-hours < 2 s**. Independently derived per-entity cost for one FULL-band coarse hour, assuming ~5 M simple typed-GDScript ops/s on one core:

| Sub-step | ops | ms |
|---|---|---|
| Power one-pass solve (500 nodes × ~90) | 45,000 | 9.0 |
| Water (350 × ~70) | 24,500 | 4.9 |
| Buildings + economy (800 × ~60, struct-of-arrays) | 48,000 | 9.6 |
| Incidents: 30 active × 120 + 24 districts × 60 | 5,040 | 1.0 |
| Dispatch, districts, construction, weather, Director, event accumulate | 13,700 | 2.8 |
| **Subtotal / with ~2× allocation & dictionary overhead** | **136,240** | **27.3 / ~55** |

**⇒ 24 coarse hours ≈ 0.66 s at 27.3 ms/hour, ≈ 1.32 s at the 55 ms allocation-loaded figure. G4's 2 s target is met either way.**

**Report C-21 settles the 45× disagreement with doc 01's 0.6 ms budget by measurement.** Doc 01's 0.6 ms line is retired; **this doc's decision rule is adopted verbatim and is normative, not conditional**, and this doc owns the tunable.

> #### ~~Decision rule for `max_coarse_hours`~~ — **RETIRED 2026-09-03 (report 98 §58, RR-161)**
>
> The rule was: `max_coarse_hours = clamp(floor(ceil(2000 / measured_coarse_ms) / 24) × 24, 72, 720)`, measured by P0-27, written into `data/persistence.json`, and applied by `CatchUpPlanner.plan` as a clamp on the **credited absence**. It shipped in Wave 17 at **360 game-hours = 6 real hours** (RR-133) and it is deleted — from this doc, from the data file, from `SavePolicy` and from the planner's signature.
>
> **It was on the wrong axis.** A performance budget bounds how long the catch-up VEIL takes; it may never bound what the player is paid for being away. Doc 92 §55 measures what the confusion cost: an eight-hour night on a settled L3 city paid **$281,319** where the uncapped absence pays **$354,830**, and a twelve-hour absence was paid **57.5%** of what those hours were worth. The 2,000 ms numerator was G4's *"24 game-hours caught up well under 2 s"* applied to the **720**-hour catch-up, and the result bounded neither veil: at the shipped 360 the founding city spent ~3 s on a full absence and the benchmark city spent **64,552 ms**.
>
> **The credited absence is doc 01's C-19 cap and nothing else** (RR-160). `CatchUpPlanner.plan` takes three arguments and reads no data file, so no workstation measurement has a path to a player's wallet.

> #### The veil budget (NORMATIVE — report 98 §58, RR-161)
>
> The performance budget stays, on the axis it is a budget for, and it is **two measured wall-clock numbers with no arithmetic between them**. `data/persistence.json.catchup`:
>
> ```
> veil_ms_at_cap : 6432   # MEASURED: one whole 12-real-hour catch-up plan on the
>                         # settled reference city, tools/measure_offline_night.gd
> veil_budget_ms : 9000   # what that is allowed to be
> ```
>
> **The gate is `veil_ms_at_cap ≤ veil_budget_ms`**, asserted by `tests/test_catchup_veil_budget.gd`. When it fails the answer is **a cheaper coarse hour, never a smaller credit**.
>
> Both fields are a **gate and not a tunable**: nothing in `sim/`, `ui/` or `game/` reads either, and the same test asserts that too. A performance number that can reach a player's wallet is how RR-133 happened, and the structural half of the fix is that this pair cannot.
>
> `measured_coarse_ms` (founding city, 5.488 ms) and `bench_coarse_ms` (1,500 buildings, 165.493 ms) stay in the file as **recorded** measurements. `CatchUpPlanner.veil_ms_at_cap(m) = m × 720` estimates a veil from either of them; it is an estimator for a gate and never an input to a plan.

Measured 2026-09-03 (doc 92 §55.6), the whole 12-real-hour plan, dev workstation:

| city | coarse hours | veil ms | ms / coarse hour | frames at 60 fps | vs 9,000 ms |
|---|---|---|---|---|---|
| founding + 60 gh settle (L2) | 719 | 4,845 | 6.74 | 291 | ✅ |
| founding + 110 gh settle (L3) | 719 | **5,504** | 7.65 | 331 | ✅ |
| founding + 180 gh settle (L4) | 719 | **6,432** | 8.95 | 386 | ✅ (shipped figure) |
| `bench_city`, 1,500 buildings | 719 | **116,882** | 162.6 | 7,013 | ❌ **AC-19-1** |

**The reference figure is this section's own accepted worst case, and that is the argument for it.** The paragraph below already ruled 3,960 ms of work ⇒ ~5.5 s of veil preferable to handing back less than three game-days. 6,432 ms is the same order and it hands back **thirty** game-days. The benchmark city is 13× over and is filed against the coarse step (doc 92 §55.7 AC-19-1) — it is not new, and the deleted clamp never bounded it either.

Two design constraints this doc imposes for the budget's sake:

- **Struct-of-arrays iteration in the coarse path.** Buildings and utility nodes must be walked as `PackedFloat32Array`/`PackedInt32Array` columns, not arrays of RefCounted objects (~2.5× cheaper in GDScript). Doc 04 already specifies SoA component arrays; doc 02 must expose `coarse_columns()`.
- **Main-thread sliced catch-up — no threading (report C-22).** The `WorkerThreadPool` branch and `async_threshold_hours` are **deleted**. Sim state is single-owner `RefCounted` (constitution §3), and threading it to save a load screen is an unforced determinism and lifecycle risk on a platform that can kill the process mid-task. Catch-up of any length runs on the main thread through doc 01's `advance_coarse_sliced(max_ms) -> bool`, called once per frame with `slice_budget_ms = 12`, behind doc 13's animated veil; `steps_done()` / `steps_total()` drive a determinate progress bar and this doc keeps emitting `catchup_progress` every `progress_emit_every_hours = 8`. Worst case at the 72-hour floor and 55 ms/hour: 3,960 ms of work ⇒ ~330 frames ⇒ ~5.5 s of veil at 60 fps, animated and progress-bared rather than frozen. **As built (Wave 14): the entry point is `CitySim.begin_catchup(plan)` → `CatchUpCursor`, not `advance_coarse_sliced(max_ms)`** — a plan carries doc 01's fine head-align and fine tail as well as the coarse body, and `max_ms` cannot be evaluated inside `sim/`, which may not read a clock. C-22's ruling is unchanged and so is the 12 ms budget; the budget now lives in the shell's loop, which is where `RestoreCursor` already put it. `steps_done()` / `steps_total()` are on the cursor, along with `done_ticks()` / `total_ticks()`. Doc 01 §2.10, doc 13 §2.9, report 98 §29 RR-73.

Save-side budgets: snapshot ≤ 25 ms · encode+write ≤ 120 ms · file ≤ 250 KB · full load incl. verification ≤ 400 ms.

> ### Measured 2026-08-19 — the save-side budgets, as shipped
>
> Desktop (the dev box), single-threaded through `SaveService.save_slot` → `SaveManager.request_save`: snapshot, stringify, SHA-256, zstd, generation rename and manifest commit all on one thread, since §2.6's encode worker is not built yet. The figure to compare against is therefore the **combined** 25 + 120 = 145 ms, not either half.
>
> | City | body as plain JSON | generation on disk | save | load (incl. §2.9 gate) | `list_slots()` | `last_good_autosave_slot()` |
> |---|---|---|---|---|---|---|
> | starter + 5 h, 34 buildings | 166,774 B | **28,998 B** (17.4 %) | 16.1 ms | 50.5 ms | 0.26 ms | 0.07 ms |
> | `bench_city`, 1,500 buildings | 1,278,827 B | **130,432 B** (10.2 %) | 126.4 ms | 257.4 ms | 0.57 ms | 0.22 ms |
>
> Every budget holds at the benchmark city: 130 KB against the 250 KB file cap, 126 ms against the 145 ms combined write budget, 257 ms against the 400 ms load budget. Re-measure on the Fold 6 before treating the two right-hand columns as headroom.
>
> **Compression paid for the ladder outright.** The old format wrote 1.28 MB per slot for `bench_city`; six retained generations of the new one are 780 KB. Deeper history, less disk. The `list_slots()` column is the manifest header (§2.5) doing its job — a load screen showing three slots costs under 2 ms and never decompresses a city.

### 2.13 Notification policy (spec §22) — sole owner (report C-71)

**Ownership, settled.** `data/notifications.json` is **this doc's file and nobody else's**: classes, priorities, event→class mapping, budgets, quiet hours and coalescing. The four-class model below is canonical and **P4 ships disabled**. Doc 13 owns the *platform* — Android channels, `AlarmManager`, the permission flow, scheduling mechanics — in `data/android.json`, and **consumes** the plan this doc produces; its parallel rate limiter (`max_per_wake`, `min_gap_s`, `max_per_day`) is deleted and its three channels map onto P1/P2/P3. Doc 12 owns **only** the in-app banner/toast gate, whose constants live in `data/ui.json` under `in_app_alerts` and can never be confused with a push budget (report C-72). Copy lives in `data/notifications_text.json`, owned by doc 13, keyed by this doc's convention (§3.3).

**The platform reality that shapes everything:** Android offers no reliable background execution, and running the sim in a foreground service would be a battery scandal in a game about power. **The sim does not run while the app is closed.** Offline notifications are therefore *scheduled at background time* — from fire times already in the save wherever possible — then reconciled against the actual catch-up on resume.

#### 2.13.0 Look-ahead horizon, by predictability class (report C-23)

The old single `horizon_hours = 48` figure is **deleted**. It conflated two incompatible things: 48 *game*-hours is only 48 real minutes at the locked 60× scale, and buying real-world hours by projection is unaffordable (1,440 coarse steps ≈ 39 s of work against an 80 ms pause budget). The horizon is therefore split by how the fire time is known:

| Class | How the fire time is known | Horizon | Projection cost |
|---|---|---|---|
| **(a) Deterministic timers** — construction, upgrade, land development, research, stadium events | Already in the `time` save section, flagged `notify_offline` | **Full offline cap: 720 game-hours = 12 real hours** | **none** |
| **(b) Pre-rolled Director / forecast events** | Already in the `director` / `weather` save sections with `eta_ticks` + `confidence` | **Full offline cap: 720 game-hours = 12 real hours**, scheduled when `confidence ≥ 0.80` | **none** |
| **(c) Emergent risk projection** — "T-12 is projected to overload" | Not known; requires running the sim forward | `projection_steps = clamp(floor(projection_budget_ms / measured_coarse_ms), 12, 60)` coarse steps | budget-bounded, ≤ `projection_budget_ms = 80` |

Classes (a) and (b) need **no projection at all** and consequently reach the *entire* 12-real-hour absence — which is the horizon that actually matters, and it costs zero milliseconds. Class (c) is bounded by budget, never by wishful hours: 12–60 coarse steps is 12–60 game-hours of simulated look-ahead ≙ **12–60 real minutes** of wall clock. Worked at the §2.12 accounting figure `measured_coarse_ms = 27.3`: `floor(80 / 27.3) = 2` → clamped up to the floor **12 steps** (≈ 12 real minutes) and the pause cost is capped by the clamp, not by the budget; at `measured_coarse_ms = 1.0`: `floor(80/1.0) = 80` → clamped down to **60 steps** (≈ 1 real hour).

**In MVP class (c) ships disabled** (`emergent_projection_enabled = false`). Classes (a) and (b) carry every notification the vertical slice needs.

**Scheduling pass** (`NotificationPlanner.plan()`), run on every `pause`/`quit` save. Doc 01 owns the tick→wall conversion (`alarm_wall_ms = background_wall_ms + (due_tick − current_tick) × 250`) and guarantees the sim fires the same timer at the same `due_tick` the alarm predicted. This doc decides *what gets scheduled*:

1. **Deterministic completions** (class (a), confidence 1.0) — any doc 01 timer flagged `notify_offline`.
2. **Forecast hazards** (class (b)) — from doc 07's forecast list, scheduled when `confidence ≥ 0.80`, phrased as forecasts: *"Severe thunderstorm expected in ~2 hours."*
3. **Projected risk milestones** (class (c), **MVP: disabled**) — only when projected probability within the projected window `≥ 0.80`, phrased conditionally: *"Transformer T-12 is projected to overload."* Never asserted as fact.
4. Everything is run through the §2.13.2 budget *at scheduling time* (fire times are known, so buckets can be simulated forward) before being handed to doc 13's `INotificationSink`.

**On resume** all pending alarms are cancelled and re-planned. A notification that *fired* but whose predicted event did not occur is reconciled honestly in the report footer: *"Forecast update — the storm tracked north; no damage."* Crying wolf without acknowledgement is how a game loses notification permission forever.

#### 2.13.1 Priority classes (data — `data/notifications.json`, canonical per report C-71)

Four classes. The `Android channel` column is the **binding target** doc 13 must implement — doc 13 owns how a channel is created and delivered, this doc owns which class an event belongs to and what its budget is. The limits below are the **push** budgets and are the most conservative numbers in the project by intent (report C-72); doc 12's higher in-app banner rates are a different quantity under a different key.

| Class | Android channel | Examples (spec §22) | Limit | Min gap | Default |
|---|---|---|---|---|---|
| `P1_critical` | `slacum_critical`, IMPORTANCE_HIGH, sound+vibrate | Major disaster, citywide blackout, hospital threat, civil emergency | 2 / 60 min | 10 min | ON |
| `P2_important` | `slacum_important`, DEFAULT, sound | Major fire, crime surge, water-system failure, large construction complete | 3 / 6 h | 20 min | ON |
| `P3_routine` | `slacum_routine`, LOW, silent | Upgrade complete, new land ready, milestone | 4 / 24 h | 60 min | ON |
| `P4_ambient` | *(no channel in MVP)* | Re-engagement, treasury threshold, daily summary | 1 / 48 h | 12 h | **OFF — ships disabled (report C-71)** |

Class rank maps to doc 06's `offline_notify_min_priority` so a single threshold controls both the digest and the alarms. P4 exists in the schema so it cannot be bolted on later without a migration, but it is disabled by default, has no default-created Android channel, and emits nothing in MVP.

#### 2.13.2 Rate limiting

Token buckets, refilled continuously, persisted in the `notifications` section so limits survive restarts.

```
refill(b, elapsed_min): b.tokens = min(b.capacity, b.tokens + elapsed_min * b.capacity / b.window_minutes)

allow(event, class, now) =
      user_enabled[class]
  and class_bucket.tokens >= 1  and  global_bucket.tokens >= 1     # global: 8 per 1440 min
  and now - last_any_sent            >= global_min_gap_minutes (5)
  and now - last_sent_class[class]   >= class.min_gap_minutes
  and now - last_sent_key[event.key] >= event.cooldown_minutes
  and not blocked_by_quiet_hours(class, event.severity, now)
```

On allow: decrement both buckets, stamp all three timestamps. On deny: emit `notification_suppressed(key, reason)` — the event **still enters the ring and still appears in the report**. Nothing is lost, only un-buzzed.

**Coalescing.** If `≥ 3` notifications of one class would fire within `coalesce_window_minutes = 15`, they collapse into one summary carrying the highest severity — *"3 problems in your city — tap to review."* One token, not three.

#### 2.13.3 Quiet hours

Default **ON**, `22:00–08:00` device-local (the only device-local wall-clock read in the game; it lives in the platform layer, never in `sim/`). Policy `defer_to_end`: suppressed notifications collapse into a **single** P3 summary at the end of the window. Bypass only for `P1_critical` with `severity ≥ 4`, and only if the player explicitly enabled *"Allow critical alerts during quiet hours"* (default **OFF**). Player-editable; a zero-length window disables the feature.

#### 2.13.4 Player controls & the doc-13 boundary

Master switch, one switch per class, quiet-hours start/end, critical-bypass switch, re-engagement kill switch — all persisted in `user://settings.cfg` (§2.5), because a player who turned notifications off must stay off across city deletion and checkpoint rollback. Each class maps 1:1 to a stable Android channel id so system settings work too (spec §49).

**Everything below this line is doc 13's implementation, stated here only as the requirement this doc places on it** (report C-71): `POST_NOTIFICATIONS` (API 33+) requested **contextually after the player's first resolved incident**, with an in-game explainer — never at first launch. `SCHEDULE_EXACT_ALARM` is restricted on Android 13+/14+: default to inexact `setWindow` alarms with a ±5-minute window; exact alarms only for P1 forecast arrivals *if already granted*; never nag, degrade silently. Doc 13 applies **no rate limiting of its own** — the plan it receives has already passed §2.13.2. Re-engagement (`P4`): max 1 per 48 h, only when the last session ended > 24 h ago, and only carrying true content — *"Your city has been running 3 days — $1.2M in taxes waiting."* No false urgency. Spec §37.2's ethics apply to attention as well as money.

**Worked example.** 03:10 real. A `transformer_failed` (P2) event fires. `P2.tokens = 1.5`, `global.tokens = 6.0`, last P2 sent 02:55 (15 min ago; min gap 20). Quiet hours active.
→ min-gap fails **and** quiet hours blocks P2 ⇒ **suppressed**, `notification_suppressed(transformer_failed, "quiet_hours")`, event still enters the critical ring. At 08:00 one P3 summary fires (*"2 problems occurred overnight"*). On resume the transformer appears in **NEEDS YOU NOW** and the **CRISIS TIMELINE**. Informed, not woken.

---


### 2.14 The write is threaded; the LOAD is costed and refused (report 98 RR-44, 2026-08-20)

§2.12's budget is about the *offline catch-up*. This section is about the two
operations either side of it, which nobody had measured until RR-37 and which are
both on the main thread.

#### 2.14.1 The split, and where the cost actually is

`SaveManager` divides into two halves with different obligations:

* **`capture_save`** — walks the registered sections and calls `serialize()` on
  each, which for the city section is `CitySim.canonical_capture()`. This is a
  read of LIVE simulation state and it is the whole reason a save is
  deterministic. Run it beside a tick and the capture is of a city that never
  existed. **It must not leave the main thread, ever.**
* **`commit_save`** — `JSON.stringify`, SHA-256, the envelope concatenation, the
  atomic zstd write, the manifest commit, retention and sweep. It touches no
  section, no sim and no shared mutable state but the slot directory. **It may.**

`tools/profile_save.gd` reports both halves of both operations. Workstation,
headless, best of 7:

| city | operation | total | half A | half B |
|---|---|---|---|---|
| founding (34 bldg, +6 h) | save | 16.54 ms | capture **11.73** | write **4.81** |
| founding | load | 52.13 ms | read **3.35** | restore **48.40** |
| benchmark (1,500 bldg) | save | 148.72 ms | capture **96.28** | write **52.44** |
| benchmark | load | 483.86 ms | read **35.22** | restore **442.56** |

**Two things in that table are not what the framing predicted, and both are
rulings rather than notes.**

#### 2.14.2 The write is threaded — and it is a third of the save, not most of it

`SaveService.async_writes` hands `commit_save` to a `WorkerThreadPool` task.
Measured caller cost: **148.72 → 97.54 ms** on the benchmark city and
**16.54 → 11.99** on the founding one. That is real and worth taking — a
benchmark-city autosave stops being six frames of hitch and becomes four — but
the capture is **65 %** of the save and the write is 35 %. `canonical_capture()`
walking the roster and floating every number into `"~f~%08x%08x"` costs nearly
twice what stringifying, digesting, compressing and writing the result does.
**The next lever on the save path is the capture, not the file**, and it is a
sim-side one: a section registry that captured incrementally, or a float codec
cheaper than a two-word hex string, would move the larger half.

The API keeps its shape. `save_slot` still returns the meta dictionary at once —
the header is built from the capture, not from the file — and `saved` still fires
exactly once per successful write, later and on the main thread. Every reader of
a slot (`load_slot`, `list_slots`, `delete_slot`, `has_slot`, `latest_slot`,
`slot_path`, `last_good_autosave_slot`, `manager_for`) flushes the queue on the
way in, so nothing can observe a half-written ladder, and
`NOTIFICATION_PREDELETE` / `EXIT_TREE` flush too, so a process that ends with a
write queued still lands it. **One write in flight per service**, because
`commit_save` reads the generation number out of the manifest and two commits
would race for it; a second request settles the first.

**`SYNC_REASONS` is normative and short:** `pause`, `quit`, `pre_migration`,
`pre_catchup`. Doc 13 §2.2 gives the process no promise that it survives the
pause callback, so a dispatched write is not a committed one there; and a pinned
checkpoint taken immediately before something destructive is not a pin until it
has landed. `AndroidLifecycle` already tags its lifecycle save `pause`, so that
path is synchronous whether or not the shell ever enables threading.

#### 2.14.3 Streaming the load — the design, and why it is not built

The obvious symmetry is to thread the load the same way: read, decompress, parse,
digest and gate on a worker while a progress bar draws, then restore on the main
thread. **It buys 7 %.**

A load is `read` + `restore`, and on the benchmark city that is **35.2 ms +
442.6 ms** (the ~6 ms the two halves leave short of the 483.9 total is the
wrapper around them — the ladder probe, the section registration and the
signal). The read half is genuinely pure — `FileAccess.open_compressed`,
`get_as_text`, `JSON.parse`, `HashingContext`, the seven-check gate and
`DictSection.deserialize` all touch nothing but the bytes — so it *could* be
threaded, and threading all of it would take a 484 ms load to 449 ms. The restore
half is `CitySim.restore_state`, which rebuilds the live city: rosters, grids,
graphs, RNG streams. It can no more leave the main thread than the capture can.

**Ruling: not built.** The cost is a background thread, a progress model the UI
has to render against, a re-entrancy contract on the load gate (which today
quarantines and writes `repair_notes` as it walks), and a second code path
through the most safety-critical function in the game — for 7 % of one operation
that happens at most a few times a session. The instrument is in the tree
(`SaveService.last_load_read_ms` / `last_load_restore_ms`, and
`tools/profile_save.gd`'s split columns) so the number can be re-checked on a
device rather than re-argued.

**Re-open only if `restore_state` itself becomes chunked.** That is the load's
real lever: a restore that could yield between sections would let a loading
screen animate, which is what a player actually notices, and it would make the
read half's 35 ms worth threading as well because the two would then overlap.
That is a doc 08 / doc 01 change and it wants its own wave.

**And doc 13 §2.9's ANR arithmetic still does not budget this.** A benchmark-city
resume pays 484 ms of load before a single coarse step of catch-up runs, and
threading the write does not touch that number. RR-37 filed it; it remains filed.

### 2.15 Both halves get their lever (report 98 §24, Wave 12, 2026-08-20)

§2.14 closes on two open items — "the next lever on the save path is the capture"
and "re-open only if `restore_state` itself becomes chunked". Both are taken here,
and doc 13 §2.9's arithmetic is re-written with the load term it never had
(§2.9.1). **Every byte on disk is unchanged**: `tools/profile_sim.gd --hash-only`
reports the same four digests on both cities before and after.

#### 2.15.1 The capture splits again — and this time the second half may leave

§2.14.1's two halves were `capture_save` (live state, main thread) and
`commit_save` (bytes, any thread), and `CitySim.canonical_capture()` sat entirely
in the first. It is two things: a READ of live state, and a canonicalisation of
the snapshot that read produced. Only the first has a thread requirement.

`SaveSection` therefore gains **`finalize(data) -> Dictionary`** — the bytes-only
tail of `serialize()`, run by `commit_save`, with two normative rules:

1. **It may not touch the sim.** Not a read, not a counter. The thread it runs on
   has no ordering relationship with the tick loop.
2. **It must be idempotent.** The manager cannot know whether a caller finalized
   before handing the payload over, and a capture committed twice (a retried
   write) must not encode twice.

`DictSection` carries it as an optional Callable; `SaveService` installs
`CitySim.encode_captured` there and asks the sim for `capture_detached()` instead
of `canonical_capture()`. A sim that publishes neither still answers
`canonical_capture()` and pays for both halves on the calling thread, which is
what every test double does.

**`capture_detached()` is `capture_state()` plus a native `duplicate(true)`, and
the copy is load-bearing.** §2.14.1 claimed the capture aliases nothing in the
sim; that was true only because the old float codec REBUILT the whole tree on its
way past. `RoadNetwork.save_section()` puts three live containers into its body by
reference. The explicit deep copy costs **8.1 ms of C++** on the benchmark city
and turns an accident into the contract, and
`tests/test_save_chunked_restore.gd` asserts it from both ends — that the detached
body does not move when the sim advances, and that `capture_state()` itself hands
out no live container.

#### 2.15.2 The load is chunked, so §2.14.3 re-opens on its own terms

`CitySim.begin_restore(body)` returns a **`RestoreCursor`**: eleven labelled,
resumable steps. `restore_state()` is that cursor drained on the spot — one
implementation, not two. The sim is INCONSISTENT at every seam, so nothing may
tick, render or query it between steps; the veil is what guarantees that, and it
is the shell's obligation.

The veil's budget is **the longest step, not the total** (doc 13 §2.9.1 has the
table), which is why `roads` is three steps: `RoadNetwork.load_section_steps()`
names its own seams and `CitySim` splices them in rather than cutting a
subsystem's loader from outside.

§2.14.3's refusal of a threaded READ **stands, and for the same 7 %**: 28 ms of
read against 202 ms of restore is still a background thread and a second path
through the load gate for a fourteenth of one operation. What changed is that the
restore no longer freezes the veil, which was the thing a player actually noticed.

Measured, `tools/profile_save.gd --repeats=7`, workstation, best ms:

| city | operation | before | after |
|---|---|---|---|
| founding | save (caller, `--async`) | 10.04 | **5.17** |
| founding | save (caller, synchronous) | 13.85 | **11.22** |
| founding | load / restore half | 48.39 / 45.35 | **45.32 / 42.17** |
| benchmark | save (caller, `--async`) | 85.39 | **39.19** |
| benchmark | save (caller, synchronous) | 125.29 | **106.43** |
| benchmark | load / restore half | 432.82 / 396.84 | **236.43 / 202.14** |
| benchmark | longest restore step | — | **76.5** |

#### 2.15.3 §3.1's section registry — what the measurement says about building it

The incremental-capture idea §2.14.2 gestures at ("a section registry that
captured incrementally") was measured before it was built, and **refused**: on the
benchmark city, fourteen of twenty-eight sections are unchanged after a game-hour
and they are worth **0.25 ms of a 36 ms encode**, while `buildings`, `grid`,
`roads` and `water` are 91 % of the body and every one of them changes within
fifteen game-MINUTES. Report 98 §24 RR-51 has the table and the ruling. The
finding is not "sections are a bad idea" — it is that **the split §3.1 needs is
not by owner, it is by rate**: a static half per subsystem (topology, which moves
when the player builds) and a dynamic half (condition, congestion, flow, load,
which moves every tick). That is a format change and wants a wave that is allowed
to move the bytes.

## 3. Data Schema

### 3.1 Save body — top level and section registry

Per constitution §9, sections sit at top level beside `schema_version` / `sim_time_minutes` / `rng_streams`.

```json
{
  "schema_version": 7,
  "sim_time_minutes": 918240,
  "rng_streams": {
    "weather":{"seed":8891234512,"state":4471223}, "incidents":{"seed":8891234513,"state":990122},
    "crime":{"seed":8891234514,"state":12},        "failures":{"seed":8891234515,"state":55019},
    "director":{"seed":8891234516,"state":7},      "traffic":{"seed":8891234517,"state":33412},
    "misc":{"seed":8891234518,"state":901}
  },
  "meta":{}, "time":{}, "world":{}, "districts":{}, "population":{}, "progression":{}, "stats":{},
  "buildings":{}, "construction":{}, "economy":{}, "power":{}, "water":{}, "roads":{},
  "incidents":{}, "fleet":{}, "dispatch":{}, "weather":{}, "director":{},
  "notifications":{}, "event_log":{}, "pending_report":{}, "ui":{}, "render_prefs":{}, "android":{}
}
```

**Canonical registry — report 98 §11, reproduced verbatim.** This supersedes the earlier registry in this section, which omitted `roads`, `render_prefs`, `ui` and `android`, assigned `construction` to a non-existent "Economy & Construction" doc, and pointed `districts` at a "Districts, Population & Stability" doc that never existed (report C-26).

| Section | Owner | Notes |
|---|---|---|
| `meta` | 08 | save identity, difficulty, catch-up bookkeeping, `reserve_treasury` |
| `rng_streams` | 08 (custody) | **eight** streams per constitution §5 (`street` added Wave 15, report 98 RR-77) |
| `time` | 01 | `tick_index`, residual, timers, work units, scheduled events |
| `world` | 09 | blocks, ownership, development, tile overrides |
| `districts` | 09 | membership, reliability EMAs, stability components |
| `population` | 09 | per-building occupancy/job fill, happiness, city level |
| `progression` | 09 | unlocks, milestones |
| `stats` | 09 | lifetime counters |
| `buildings` | 02 | per-building records |
| `construction` | 02 | project queue, progress, crew bindings |
| `economy` | 03 | treasury, carry, tax rate, land owned, ledger, hourly ring |
| `power` | 04 | components (SoA), ties, backup gens, system, building service |
| `water` | 05 | nodes, tanks, edges, zones, jobs, policy |
| `roads` | 10 | RLE tile blocks, closures, speed overrides, auto-repair |
| `incidents` / `fleet` / `dispatch` | 06 | active incidents, units, policy + stats |
| `weather` / `director` | 07 | timeline, storm cell, flood; TP, cooldowns, scheduled |
| `notifications` / `event_log` / `pending_report` | 08 | buckets, rings, unacknowledged report |
| `ui` | 12 | camera, overlay, settings, onboarding |
| `render_prefs` | 11 | camera continuity only |
| `android` | 13 | last pause stamp, permission state, device profile |

Three consequences for the loader. **(1)** `validate_structural()` expects **24 section keys** — the table's 20 rows, of which `rng_streams` is the top-level custody row (constitution §9) and three rows cover two or three keys each: `19 − 3 + (3 + 2 + 3) = 24` — and repairs a missing one from that owner's `default_section()`. **(2)** `population`, `progression`, `stats`, `roads`, `ui`, `render_prefs` and `android` are new registry members; because the envelope version covers the section *registry* (§2.8), any post-launch registry change of this shape is an envelope bump with a ladder step. Pre-MVP no city exists, so this correction folds into the current envelope version instead — the rule is unchanged, it simply has nothing to migrate yet. **(3)** Device-scoped preferences are *not* here: they are in `user://settings.cfg` (§2.5), which the ladder never touches.

**Section contract** every owning system implements:

```gdscript
func section_key() -> String
func section_version() -> int
func serialize() -> Dictionary            # pure data, sorted-key safe, includes "section_version"
func deserialize(d: Dictionary) -> void   # input already migrated to the current section_version
func migrate_section(d: Dictionary, from: int) -> Dictionary
func default_section() -> Dictionary      # used by validate_structural() repair
```

### 3.2 Sections owned by this doc

```json
{
  "meta": {
    "section_version": 1,
    "save_id": "c7f2a1e0-…", "city_name": "Slacum",
    "app_version": "0.4.1", "content_version": 12, "difficulty": "standard",
    "created_unix": 1752000000, "last_saved_unix": 1755500000, "max_seen_unix": 1755500000,
    "play_seconds": 41290, "save_reason": "pause", "generation": 123, "clock_rollback_count": 0,
    "reserve_treasury": 50000,
    "last_catchup": { "at_unix": 1755499000, "credited_real_ms": 22320000, "coarse_hours": 371,
                      "capped": false, "safe_mode": false, "fidelity_hour_equivalents": 252.0,
                      "fidelity_rate": 0.677, "damage_cap_hit": false, "director_hazards": 1,
                      "is_resync_emitted": true },
    "repair_notes": []
  },

  "notifications": {
    "section_version": 1,
    "master_enabled": true,
    "class_enabled": {"P1_critical": true, "P2_important": true, "P3_routine": true, "P4_ambient": false},
    "quiet_hours": {"enabled": true, "start_min": 1320, "end_min": 480, "allow_critical": false},
    "reengagement_enabled": true,
    "buckets": {
      "global":       {"tokens": 6.0, "capacity": 8, "window_minutes": 1440},
      "P1_critical":  {"tokens": 2.0, "capacity": 2, "window_minutes": 60},
      "P2_important": {"tokens": 1.5, "capacity": 3, "window_minutes": 360},
      "P3_routine":   {"tokens": 4.0, "capacity": 4, "window_minutes": 1440},
      "P4_ambient":   {"tokens": 1.0, "capacity": 1, "window_minutes": 2880}
    },
    "last_any_sent_unix": 1755498800,
    "last_sent_class_unix": {"P1_critical": 0, "P2_important": 1755498800, "P3_routine": 1755490000, "P4_ambient": 0},
    "last_sent_key_unix": {"construction_complete": 1755490000},
    "scheduled": [ {"alarm_id":4411,"key":"construction_complete","class":"P3_routine","fire_unix":1755503600,"exact":false,"ref":"proj_0091","due_tick":919700,"confidence":1.0} ],
    "permission_state": {"post_notifications": "granted", "exact_alarm": "denied"}
  },

  "event_log": {
    "section_version": 1,
    "critical": {"cap": 64,  "head": 19,  "entries": [ /* §2.10 entries */ ]},
    "routine":  {"cap": 448, "head": 301, "entries": [ /* … */ ]},
    "report_marker_time": 884400, "dropped_routine_count": 118
  },

  "pending_report": {
    "section_version": 1, "built_at_sim_minutes": 918240, "acknowledged": false,
    "header": {"away_real_seconds":22320,"away_game_minutes":1339200,"game_days":15.5,"coarse_hours":371,
               "capped":false,"cap_game_hours":720,"fidelity_hour_equivalents":252.0,"fidelity_rate":0.677,
               "recovered_from_checkpoint":false},
    "needs_you_now": [ {"kind":"fire","ref":"inc_0442","label":"Structure fire — Harbor High-Rise","urgency":805.3,"deeplink":"incident/inc_0442"} ],
    "timeline": [ {"t":891600,"text_key":"tl_lightning_feeder","args":{"feeder":"F-3","district":"Harbor","minutes":47,"crimes":2}} ],
    "ledger": {"taxes":3120400,"expenses":751600,"net":2368800,"deferred_bills":0,"treasury_before":8420000,"treasury_after":10788800,"offline_rate":0.677},
    // ↑ every figure in `ledger` is supplied by doc 03, including `offline_rate` (the ratio its own
    //   exponential taper realized). This doc supplies `header.fidelity_rate` (= M(H)/H) and nothing else
    //   economic. Illustrative values shown; they are doc 03's to recompute (report C-20).
    "progress": {"construction_complete":["proj_0091","proj_0093"],"upgrades":1,"land_developed":1,"population_delta":3140,"unlocks":[]},
    "response": {"by_class":{"fire":{"spawned":3,"auto_resolved":2,"open":1},"crime":{"spawned":11,"auto_resolved":11,"open":0}},
                 "units_dispatched":26,"avg_response_minutes":7.4,"auto_repair_spend":61200,"policy_blocked":1},
    "aggregates": [ {"key":"crime_petty","count":9}, {"key":"water_main_minor","count":1} ],
    "forecast_reconciliation": [ {"key":"storm_forecast","occurred":false} ]
  }
}
```

### 3.3 `data/notifications.json` — owned solely by this doc (report C-71)

> **Shipped 2026-08-19.** The file exists and this section is description, not plan. Three things landed with it, and each is recorded here because it is a shape the schema below does not show:
>
> * **`bindings` — an ordered array beside `events`.** `events` (below, verbatim) says what a notification *is*; `bindings` says which sim event *becomes* one, and it is an ARRAY because first-match-wins ordering is load-bearing (the two `BlockDarkChanged` rules; the P1-vs-general incident rules) while `events` is an object keyed by notify_id and order-independent. A binding may override `class`, which is how one sim event carrying its own urgency (`incident_created.notification_priority`) reaches two budgets without needing two sets of copy. `ui/alerts_model.gd` reads `bindings` + `events`; `game/notifications/notification_router.gd` reads `classes` + `events` + `runtime`. One table, two readers, and they cannot disagree.
> * **`data/ui.json.alerts.events` was deleted, not merged** — the stand-in's own comment promised exactly that. `ui.json` keeps presentation and doc 12's `in_app_alerts` gate. Deleting it fixed two live defects the stand-in had been hiding: it read `city_level_changed.level` and `block_ready.block_id` while `sim/` emits `to` and `block`, so both notifications rendered an **empty title** in the shipped game while passing tests that fed them the field the table wanted. The replacement is checked against the emit sites, and it took the bound notify_ids from **11 to 27** — the 16 new ones are doc 05's whole water set, doc 06's incidents, doc 10's roads, doc 07's warning and `load_shed_ended` / `tax_changed`, every one of which already had `n_*` copy in `data/strings.en.json` and no rule to reach it.
> * **`runtime` lives in this file, not `data/persistence.json`.** §8's `notifications_runtime` block is filed under `data/persistence.json` in this doc; that file does not exist in the repo yet, and splitting one policy across a file that is not there would mean the budget lived nowhere. It sits under `runtime` here, verbatim, beside the classes it limits, and moves when `persistence.json` lands.
>
> **The platform half is still doc 13 phase 2, by design.** What ships is the *decision*: every push is classified, coalesced and run through §2.13.2's budget, and then handed to a `NotificationSink` that is a documented no-op. `AndroidNative.supports_notifications()` is a `has_method` probe on the `SlacumNative` singleton and is false on every build, so `game/notifications/native_notification_sink.gd` is finished, wired and inert. Phase 2 is a Kotlin change plus a channel review, not a refactor — and doc 13 still applies **no rate limiting of its own** (C-71), because everything `deliver()` receives has already passed the budget.


Localization keys are conventional, not authored: `title_key = "n_" + <event key> + "_title"`, `body_key = "n_" + <event key> + "_body"`. Adding an event therefore touches this file and the string table only. The strings themselves live in doc 13's `data/notifications_text.json` and doc 12's `data/strings.en.json` (report G-8); doc 12's own `data/notifications.json` block is deleted and doc 13's parallel rate limiter is deleted. `mvp_enabled: false` on `P4_ambient` is the switch that keeps the class present in schema but silent in the slice.

```json
{
  "schema_version": 1,
  "classes": {
    "P1_critical":  {"rank":1,"channel_id":"slacum_critical","android_importance":"high","sound":true,"vibrate":true,"capacity":2,"window_minutes":60,"min_gap_minutes":10,"default_enabled":true,"mvp_enabled":true,"quiet_bypass_min_severity":4},
    "P2_important": {"rank":2,"channel_id":"slacum_important","android_importance":"default","sound":true,"vibrate":false,"capacity":3,"window_minutes":360,"min_gap_minutes":20,"default_enabled":true,"mvp_enabled":true,"quiet_bypass_min_severity":99},
    "P3_routine":   {"rank":3,"channel_id":"slacum_routine","android_importance":"low","sound":false,"vibrate":false,"capacity":4,"window_minutes":1440,"min_gap_minutes":60,"default_enabled":true,"mvp_enabled":true,"quiet_bypass_min_severity":99},
    "P4_ambient":   {"rank":4,"channel_id":"slacum_ambient","android_importance":"min","sound":false,"vibrate":false,"capacity":1,"window_minutes":2880,"min_gap_minutes":720,"default_enabled":false,"mvp_enabled":false,"quiet_bypass_min_severity":99}
  },
  "events": {
    "hazard_started":        {"class":"P1_critical","severity":4,"aggregate":false,"cooldown_minutes":60,"deeplink":"incident/{ref}"},
    "district_blackout":     {"class":"P1_critical","severity":4,"aggregate":false,"cooldown_minutes":120,"deeplink":"district/{ref}"},
    "hospital_service_lost": {"class":"P1_critical","severity":4,"aggregate":false,"cooldown_minutes":180,"deeplink":"building/{ref}"},
    "storm_forecast":        {"class":"P1_critical","severity":3,"aggregate":false,"cooldown_minutes":240,"deeplink":"weather"},
    "major_fire":            {"class":"P2_important","severity":3,"aggregate":false,"cooldown_minutes":90,"deeplink":"incident/{ref}"},
    "water_system_failure":  {"class":"P2_important","severity":3,"aggregate":false,"cooldown_minutes":120,"deeplink":"overlay/water"},
    "transformer_failed":    {"class":"P2_important","severity":3,"aggregate":true,"cooldown_minutes":120,"deeplink":"overlay/power"},
    "crime_surge":           {"class":"P2_important","severity":2,"aggregate":true,"cooldown_minutes":240,"deeplink":"overlay/police"},
    "coalesced_summary":     {"class":"P2_important","severity":2,"aggregate":false,"cooldown_minutes":15,"deeplink":"report"},
    "construction_complete": {"class":"P3_routine","severity":1,"aggregate":true,"cooldown_minutes":180,"deeplink":"building/{ref}"},
    "land_ready":            {"class":"P3_routine","severity":1,"aggregate":true,"cooldown_minutes":180,"deeplink":"land/{ref}"},
    "milestone_reached":     {"class":"P3_routine","severity":1,"aggregate":false,"cooldown_minutes":720,"deeplink":"dashboard"},
    "treasury_threshold":    {"class":"P4_ambient","severity":0,"aggregate":true,"cooldown_minutes":1440,"deeplink":"dashboard"},
    "reengagement":          {"class":"P4_ambient","severity":0,"aggregate":false,"cooldown_minutes":2880,"deeplink":"dashboard"}
  }
}
```

---

## 4. Sim API Sketch

All `RefCounted`, under `sim/`, with no Node/OS/Input imports (constitution §3).

```
sim/persistence/
  SaveManager        build_snapshot() · request_save(reason) · load_slot(slot) -> LoadResult
  SaveEncoder        encode(body) -> PackedByteArray     (stringify → sha256 → envelope → zstd)
  SaveMigrator       migrate(body, from) · CURRENT_SCHEMA_VERSION · LADDER · run_section_ladders()
  SaveValidator      validate_structural(body) -> {repairs[], fatal}
  CheckpointPolicy   plan_retention(manifest, new_gen) -> {keep[], delete[]}
  SaveSection        (interface) §3.1

sim/offline/
  OfflinePolicy      band_for(hour_index) -> band · fidelity_hour_equivalents(H) [= M(H)] · from_data()
  OfflineGuard       clamp_condition() · clamp_population() · block_destroy() · clamp_treasury()
  CatchupAccumulator add(event) · counts · exemplars · caps_hit
  CatchupReportBuilder build(acc, world, plan) -> Dictionary

sim/history/  EventRing push/window/to_dict/from_dict · EventLog (critical + routine + marker)
sim/notify/   NotificationPlanner.plan() · NotificationBudget.allow()/consume()/refill()

Injected interfaces — declared in sim/, implemented in game/ (constitution §3's four layers stand;
report C-04 withdrew this doc's `platform/` proposal, see §9):
  IClockSource now_unix() · IFileSink write/rename/list/delete · INotificationSink schedule/cancel/channels
```

> ### Shipped 2026-08-19 — what is actually under `sim/persistence/`
>
> ```
> sim/persistence/save_manager.gd    envelope · atomic write · manifest commit · retention ·
>                                    quarantine · candidate walk · peek_newest() (side-effect-free probe)
> sim/persistence/save_section.gd    the §3.1 contract, unchanged
> sim/persistence/dict_section.gd    the contract backed by a payload its owner holds (§2.8's note)
> sim/persistence/save_policy.gd     `data/persistence.json`.save, parsed once, injected into both writers
> ```
>
> `SaveEncoder`, `SaveMigrator`, `SaveValidator` and `CheckpointPolicy` are **methods on `SaveManager`, not classes**. Four collaborators for one 350-line file whose only caller is the shell would be four indirections nobody reads; they split out when a second caller or a second policy exists. The behaviour each names is present and tested. `IFileSink` is likewise still `FileAccess` directly — the C-04 injection point arrives with doc 13's phase 2, and is the one seam in this list that is genuinely owed rather than deliberately collapsed.

**Commands handled:** `save_now`, `acknowledge_report`, `restore_checkpoint(generation)`, `set_reserve_treasury(v)`, `set_notification_class_enabled(class, bool)`, `set_quiet_hours(start, end, enabled, allow_critical)`, `set_reengagement_enabled(bool)`.

**Events emitted:** `save_started`, `save_written`, `save_failed`, `save_recovered`, `save_repaired`, `migration_applied`, `catchup_progress`, `catchup_capped`, `report_ready`, `report_acknowledged`, `notification_scheduled`, `notification_suppressed`, `policy_blocked`.

**Snapshot contract — `is_resync` (report C-68, binding).** The **first state snapshot published after a catch-up commits** carries `is_resync: true`; every subsequent snapshot carries `is_resync: false`.

```gdscript
# every snapshot handed to game/ and ui/
{ "sim_time_minutes": int, "is_resync": bool, ... }
```

`is_resync: true` means *"this state is the result of compressed time, not of events you just watched"*. Doc 11 consumes it to **snap** emissive/overlay state instead of animating — without it the renderer would replay up to 30 game-days of accumulated relights, playing a 3.15 s sweep per district that changed while the app was closed. Doc 12 uses the same flag to suppress transition toasts for state the report already explains. Setting the flag is this doc's responsibility because this doc owns the catch-up commit point; `meta.last_catchup.is_resync_emitted` records that it was set, so a killed process between commit and first frame does not lose the flag.

---

## 5. Cross-System Interfaces

**Provided by this doc:** the `SaveSection` contract; `OfflinePolicy` band multipliers on `TimeContext`; `OfflineGuard` clamps; `EventRing.push(entry)` as the single sink for anything that may appear in a report or notification; the **`is_resync`** snapshot flag (§4); `SaveManager.request_save(reason)` as the **only** way anything in the project writes city state; and `data/notifications.json` as the only push-notification policy in the project.

| Doc | Required interface |
|---|---|
| **01 Time & ticks** | Authoritative: `CatchUpPlanner`, `advance_real_elapsed`, `OFFLINE_CAP_REAL_MS = 43,200,000` (12 real h / 720 game-h, report C-19), `OFFLINE_GRACE_SECONDS`, phase order, `ctx.is_catchup/catchup_index/catchup_total`, timer `notify_offline` flags, the tick→wall alarm formula, and **`advance_coarse_sliced(max_ms) -> bool` + `steps_done()` / `steps_total()`** (report C-22). Required *from* it: attach `OfflinePolicy.band_for(ctx.catchup_index)` to every coarse `TimeContext`; expose `sim_time_minutes == tick_index / 4` for the load-time assertion. |
| **02 Buildings & construction** | `coarse_columns() -> {ids, condition, power_kw, water_units, pop, jobs}` (SoA, §2.12); `apply_condition_delta()` routed through `OfflineGuard`; owns `buildings` + `construction` sections; construction work units linear in `dt`. Rename its inner `schema_version` → `section_version` (report C-25). |
| **03 Economy** | **Owns the offline economic curve** (report C-20): populates `band.yield_mult` from `exp(−(h−4)/90)`, reads `ctx.catchup_index` instead of its own absence counter, and supplies every `ledger` figure in the report including its realized `offline_rate`. Also owns `data/difficulty.json`, in which this doc authors the `offline` rows (report C-17). Consumes: `deferred_bills` with the 3-day cap and ×0.80 efficiency penalty; `reserve_treasury`. |
| **04 Electrical grid** | `advance(dt_gh = 1.0)` coarse path; SoA component arrays for the coarse walk; failure rolls from the `failures` stream only. Rename its inner `schema_version` → `section_version` (report C-25). |
| **05 Water system** | `advance(1.0)`; zone re-keying on load already specified; inner key ✔ (already `section_version`). |
| **06 Incidents, dispatch & fleet** | Authoritative: `DispatchPolicy.allows()`, the `dispatch` policy table, `OFFLINE_FULL_FIDELITY_H = 72`, `incident.cause` for timeline causality. Required: honour `band.incident_mult` as a generation-rate factor; add **`world.destroy_allowed()`** to the `destroy_building` cascade op so offline destruction is refused *visibly* (report C-47) on top of `OfflineGuard.block_destroy()`; map every incident type to a `data/notifications.json` event key; keep `offline_notify_min_priority` as a digest threshold only; respect `reserve_treasury`. |
| **07 Weather & Director** | `set_offline_constraints(max_tier = 1, max_count = 1, require_prewarned = true)` and full suppression in the DAMPED band — these are the outer clamp and F8 is tightened to match (report C-55); `forecast(horizon) -> [{kind, eta_ticks, confidence, tier}]` **pre-rolled into the save** so notification class (b) needs no projection (report C-23); `suppress_until(sim_minutes)` for return and recovery grace. |
| **09 Map, land, districts, population & stability** | Owns `world`, `districts`, `population`, `progression`, `stats` (report §11 + G-1/G-4/G-5); `stability_components` shape; `apply_population_delta()` routed through `OfflineGuard`; generates `tests/fixtures/bench_city.json`, which **this doc validates against the current save schema in CI** (report G-7). Rename inner key → `section_version`. |
| **10 Roads** | Owns the `roads` section (report C-26 — it was missing from the old registry); deterministic serialization, stable ids; `route_minutes(a, b, profile)` (used by dispatch, not directly here). Rename inner key → `section_version`. |
| **11 Rendering & performance** | Owns `render_prefs` (camera continuity only) and the graphics preset in `user://settings.cfg`. Consumes **`is_resync`** on the first post-catch-up snapshot and snaps emissive state instead of animating (report C-68). |
| **12 UI/UX** | Owns the `ui` section and `data/strings.en.json`. Renders `pending_report`; issues §4 commands; owns **only** the in-app banner gate under `data/ui.json.in_app_alerts` — it does not own `data/notifications.json` (report C-71/C-72). Rename inner key → `section_version`. |
| **13 Android integration & export** | Owns the `android` section, `game/android/*` (GDScript) and `android/plugins/slacum_native/` (Kotlin AAR) — **not** a source layer (report C-04). Implements `IClockSource` / `IFileSink` / `INotificationSink` for `game/`. **Persistence:** calls `SaveManager.request_save("pause")` on lifecycle step 3 and implements no save path of its own — no `city.json`, no `.bak` rotation, no `saves_recovered_from_backup` (report C-24); keeps its ≤ 250 ms pause budget and lifecycle ordering. **Notifications:** consumes this doc's plan, owns channels/`AlarmManager`/permissions and `data/notifications_text.json`, and applies no rate limiting of its own (report C-71). Also owns the catch-up veil the sliced path runs behind. |

---

## 6. MVP Cut

**In the vertical slice** (spec §43.1: "Persistent save", "Offline catch-up", "Basic notifications"):

Single slot; atomic write with manifest commit; generation files; retention slots A–C (3 generations). SHA-256 verification, candidate walk, quarantine, recovery dialog, safe mode. `user://settings.cfg` for device-scoped prefs. Envelope + per-section ladder machinery with at least one real migration exercised by a fixture test (proving the mechanism, not the intent). Both fidelity bands and **all eight fairness rules from day one** — they are the difference between the offline city being a feature and being a bug. `reserve_treasury` and `policy_blocked` surfacing. Main-thread sliced catch-up with `catchup_progress` and the `is_resync` flag. The §2.12 veil budget gated against a measured full-cap catch-up (`veil_ms_at_cap ≤ veil_budget_ms`; RR-161 — the former `max_coarse_hours` clamp on the credited absence is retired). Event rings, accumulator, report sections 0–5. Notifications: P1–P3, per-class toggles, global + per-class buckets, quiet hours with `defer_to_end`, inexact alarms, deterministic completions (class a) + storm forecast (class b) only — both of which reach the full 12-real-hour cap with zero projection.

**Deferred:** retention slots D–F · multiple city slots · cloud / Play Games saved games · **emergent risk projection, notification class (c)** (ships present, `emergent_projection_enabled = false` — report C-23) · P4 ambient class and re-engagement (ships present but disabled and empty, `mvp_enabled = false` — report C-71) · report sharing (spec §54) · save export/import for support · `id_remap` + Save Repair panel (needed once content ids start churning, ~Phase 3).

---

## 7. Test Plan

Headless: `godot --headless --path "…" -s res://tests/run_tests.gd`.

**Persistence**
1. `test_roundtrip_identity` — 500-entity city → serialize → deserialize → re-serialize; the two sorted-key strings are byte-identical.
2. `test_atomic_write_crash` — fault injector aborts after tmp-write / after rename / before manifest rename / after manifest rename. All four load a *valid* save; the first three load the *previous* generation.
3. `test_digest_detects_corruption` — flip one body byte; loader rejects, quarantines, loads generation B, reports the correct lost-minutes figure.
4. `test_truncated_file` — truncate to 50%; same recovery path.
5. `test_all_candidates_bad` — corrupt every generation; nothing deleted, `crash_report.json` written, `FATAL_NO_CANDIDATE` returned.
6. `test_retention_policy` — 200 synthetic saves over 10 real days; exactly ≤ 6 unpinned + ≤ 2 pinned remain, slots A–F match their age rules.
7. `test_downgrade_refused` — `schema_version = CURRENT + 1`; refused, file untouched, older compatible generation loaded.
8. `test_clock_rollback` — `now_unix < max_seen_unix`; elapsed 0, counter incremented, no state change.

**Migration**
9. `test_migration_ladder_all_versions` — every fixture `save_v1..v(N-1).json` migrates to CURRENT and passes `validate_structural()` with zero fatal repairs.
10. `test_migration_v3_to_v4_values` — §2.8's example: `oil_temp_c == ambient + 35×load_frac` to 1e-6; every `power_state ∈ {0,1,2}`; district aggregate stability unchanged to 1e-6.
11. `test_migration_is_total` — strip a random 10% of keys from a v1 fixture, 100 seeded trials; the ladder never throws and always yields a loadable body.
12. `test_section_ladders_independent` — bumping `power.section_version` alone migrates only `power` and leaves the envelope version untouched.
13. `test_unknown_id_orphaned` — a retired building type survives load as `orphan`, is skipped by every tick, appears in `repair_notes`.

**Offline policy & fairness**
14. `test_band_plan_pure_function` — `band_for(h)` depends only on `h`; boundaries asserted at **71/72 and 719/720** (report C-19).
15. `test_fidelity_multiplier` — `M(24) == 24.0`, `M(72) == 72.0`, `M(240) == 172.8`, `M(372) == 252.0`, `M(480) == 316.8` and **`M(720) == 460.8`** to 1e-9; `M(720)/720 == 0.64` to 1e-9; `M(H) == M(720)` for every `H > 720` (report R-15). Asserts the DAMPED span is 648, not 408.
15b. `test_yield_mult_not_authored_here` — `data/persistence.json.offline.bands` contains **no** `yield_mult` key; `band.yield_mult` is null until doc 03 populates it, and a coarse step with an unpopulated `yield_mult` accrues no revenue rather than silently accruing full revenue (report C-20).
16. `test_determinism_same_input_same_output` — same save + same elapsed run twice ⇒ byte-identical post-catchup saves, for elapsed ∈ {5 game-min, 24 game-h, 372 game-h, 720 game-h}.
17. `test_absence_cap` — 30 real days produces the identical post-state to **12 real hours** (720 game-hours); `catchup_capped` emitted with the discarded remainder (report C-19).
18. `test_no_offline_destruction` — 10,000 seeded catch-ups at the 720-hour cap on `hard`: zero buildings destroyed, zero entities removed, zero deaths, no asset below 0.15, total condition loss ≤ 0.35 of pool, population loss ≤ 8%. Also asserts every `destroy_building` attempt was **refused visibly** by doc 06's `destroy_allowed()` guard rather than silently swallowed (report C-47).
19. `test_no_unwarned_offline_hazard` — 10,000 seeded runs: Director hazards ≤ 1, always Tier 1, always pre-warned, never in the DAMPED band; on `casual`, always 0.
20. `test_treasury_never_negative_offline` — start at $500 with heavy expenses; treasury ≥ 0, `deferred_bills` ≤ 3 game-days, ×0.80 efficiency applied.
21. `test_reserve_treasury_respected` — many cheap auto-repairs cannot drive treasury below `reserve_treasury`; each refusal emits `policy_blocked`.
22. `test_return_grace` — no hazard scheduled within 120 game-minutes of resume; offline incidents' escalation timers frozen for that window.
23. `test_band_multiplier_is_neutral_online` — with all multipliers 1.0 the coarse path reproduces doc 06's online/offline equivalence test exactly, proving the bands are a rate channel and not a branch.
23b. `test_catchup_is_main_thread_only` — a catch-up at the 720-hour cap runs entirely on the calling thread: `WorkerThreadPool.get_thread_count()` usage is zero across the catch-up, `advance_coarse_sliced(12)` is called once per frame, `steps_done()` increases monotonically to `steps_total()`, and `catchup_progress` fires every 8 hours (report C-22).
23c. `test_is_resync_flag` — the first snapshot published after a catch-up commit has `is_resync == true`, the second `false`; killing the process between commit and first frame still yields `is_resync == true` on the next launch's first snapshot, via `meta.last_catchup.is_resync_emitted` (report C-68).

**Event log & report**
24. `test_ring_eviction_protects_critical` — 5,000 routine + 10 critical pushes; all 10 critical survive.
25. `test_report_aggregation` — 400 petty crimes ⇒ ≤ 3 ring entries and one chip with count 400.
26. `test_report_suppressed_for_short_absence` — 5 game-minutes with nothing above sev 1 ⇒ `pending_report` null; a credited-zero absence likewise.
27. `test_report_survives_kill` — build a report, kill before acknowledge, reload; the identical report is presented.
28. `test_urgency_ordering` — §2.11's worked example ranks the fire above the outage.

**Notifications**
29. `test_rate_limit_buckets` — 50 P2 events in one game-hour ⇒ ≤ 3 per 6 h window, never < 20 min apart; the rest emit `notification_suppressed` yet still reach the ring.
30. `test_quiet_hours_defer` — events in 22:00–08:00 produce exactly one summary at 08:00; a sev-4 P1 defers with `allow_critical = false` and fires with `true`.
31. `test_class_toggle_off` — disabling P3 suppresses every P3 notification while ring entries and report content are unchanged.
32. `test_schedule_reconcile_on_resume` — pending alarms cancelled and re-planned; a fired-but-unrealized forecast yields a `forecast_reconciliation` entry.
32b. `test_notification_horizon_by_class` — deterministic timers and pre-rolled forecast events **720 game-hours** out are scheduled with zero coarse steps executed during the pause pass; class (c) is off in MVP, and when force-enabled `projection_steps == clamp(floor(80 / measured_coarse_ms), 12, 60)` and the pause pass stays inside doc 13's 250 ms budget (report C-23).
32c. `test_notification_policy_is_single_source` — no other `data/*.json` in the repo defines a notification class, capacity, window or min-gap; doc 12's constants exist only under `ui.json.in_app_alerts`; `P4_ambient.mvp_enabled == false` and nothing P4 is ever emitted (report C-71/C-72).

**Performance** (`tests/perf/`, 2× tolerance for CI noise)
33. `test_coarse_step_cost` — **P0-27; RE-AIMED 2026-09-03 (RR-161).** As built it is `tests/test_milestone1.gd::test_coarse_step_cost_budget`: it measures one FULL-band coarse hour on the founding city and now prints what that costs at the full 12-real-hour cap (`CatchUpPlanner.veil_ms_at_cap`) instead of deriving a clamp on the player's credit. It still does not fail on a slow measurement — a wall-clock assert beside sibling suites is a flake, not a gate.
33b. `test_catchup_veil_budget` — **the arbiter for §2.12's rule, and it is a whole file.** Asserts (a) the credited absence is doc 01's C-19 cap at every length from 6 to 12 real hours and there is no argument to `plan()` that can narrow it; (b) `veil_ms_at_cap ≤ veil_budget_ms` from `data/persistence.json`; (c) **nothing in `sim/`, `ui/` or `game/` reads either field**, and the planner names `SavePolicy` nowhere; (d) the capped copy, in both directions.
34. `test_catchup_perf_24h` — 24 game-hours < **2,000 ms** (design expectation 0.66–1.32 s per §2.12). This is G4 and it is the only place the 2,000 ms number still belongs.
35. ~~`test_catchup_perf_cap`~~ — **RETIRED with the clamp (RR-161).** Its subject was `max_coarse_hours × measured_coarse_ms`, which no longer exists. The full-cap cost is measured directly by `tools/measure_offline_night.gd` and recorded as `veil_ms_at_cap`; test 33b gates it.
36. `test_snapshot_perf` < 25 ms (also proves doc 13's 250 ms pause budget is met by the snapshot alone) · `test_encode_write_perf` < 120 ms and < 250 KB · `test_load_perf` < 400 ms.
37. `test_bench_city_fixture_valid` — **amended 2026-08-19; see the ruling below.** Doc 09's generated `tests/fixtures/bench_city.json` is validated as a **BOOT file**: it parses, its `schema_version` tracks `data/starter_city.json`'s (the loader's data-file version, *not* the save envelope's), and it boots a `CitySim` clean at 1,500 buildings. The save-schema half of report G-7 is then covered by putting the booted city **through** the save path — `save_slot` → `load_slot` → identical `state_hash()`, with zero structural repairs — so doc 11's on-device gates cannot silently stop running against a stale fixture, and a save-schema drift is caught on 1,500 buildings rather than on the starter city's 35. Lives in `tests/test_save_migration.gd`; the boot-file legs are also asserted by `tests/test_bench_city.gd` (doc 11 test 26).

> ### Ruling — `bench_city.json` is a boot file, not a save body (flagged Wave 6, settled here)
>
> The original wording asked the fixture to "load under the current registry and pass `validate_structural()`". It cannot, and it must not be made to. The file is in `data/starter_city.json`'s shape — `world`, `blocks`, `buildings` with `origin`/`size`/`level`, roads — and it is consumed by `StarterCityLoader`. A save body is §3.1's twenty-four-key section registry with `rng_streams`, `sim_time_minutes` and a per-section `section_version`. They are two different schemas with two different owners and two different version counters; feeding one to the other's loader would assert only that they disagree, and would fail the moment either one moved for reasons of its own. Doc 09 §2.13 described the fixture as a save file; **that is the error, and this ruling corrects it** — doc 09 §2.13 now reads "boot file" throughout, **applied 2026-08-19**, with the correction stated in the section and in that doc's G-7 changelog row.
>
> The requirement behind G-7 is not a schema check, it is a **tripwire against silence**: doc 11's performance gates are measured against this fixture, and a stale one makes every one of those numbers stop meaning anything without going red. That requirement is met by validating what the file actually is, and then by exercising the save path with the city it produces — which is a stronger test than the original, because a 1,500-building round-trip through `save_slot`/`load_slot` catches save-schema drift that a structural check on a static file never would.

---

## 8. Tunables

> ### Shipped 2026-08-19 — `data/persistence.json` exists, `save` block only
>
> The file landed with the unification and carries the `save` block below, with three corrections the code forced and one thing deliberately left out.
>
> * **`current_schema_version` is 1, not 7** (§2.5's shipped note explains why), and a test asserts it equals `SaveManager.CURRENT_SCHEMA_VERSION`.
> * **`slot_path` is a template** — `user://saves/slot_%d` — because a player-facing slot is now its own ladder rather than there being one notional `slot0`. `legacy_slot_file` (`user://saves/slot_%d.json`) is new and names the format-1 files still on devices.
> * **`retention_slot_age_real_seconds` keeps its six entries, and the first is slot A's own age**, which is 0 by definition. `SavePolicy` publishes entries B..F as the history ladder and truncates it to `max_unpinned_generations − 1`, so shortening one tunable can never leave the other lying. `debug_plain_mirror` ships `false`.
> * **The `offline`, `fairness` and `event_log` blocks are NOT in the file yet.** Their readers are doc 01's `CatchUpPlanner` (which reads `data/time.json`) and code that does not exist (`OfflinePolicy`, `OfflineGuard`, the event rings). Writing tunables that nothing reads is how a data file starts lying, so they arrive with their consumers. `sim/persistence/save_policy.gd` is the only reader of what is there, and both writers take a `SavePolicy` rather than reading the file themselves — which is what lets a test shorten the ladder without touching a disk.
> * **`notifications.json.runtime` stays where it is.** §3.3 promised to move it here once this file existed. It reads better beside the classes it limits, and moving it is a change to a shipped, tested notification path for no behavioural gain; recorded as a deliberate non-move rather than an oversight.

```json
// ===== data/persistence.json =====
{
  "schema_version": 1,

  "save": {
    "current_schema_version": 7,
    "slot_path": "user://saves/slot0/",
    "device_settings_path": "user://settings.cfg",   // device-scoped, never migrated (report C-03)
    "compression": "zstd",
    "debug_plain_mirror": true,
    "autosave_interval_real_seconds": 300,
    "snapshot_budget_ms": 25,
    "encode_write_budget_ms": 120,
    "load_budget_ms": 400,
    "blocking_save_wait_ms": 400,
    "max_unpinned_generations": 6,
    "max_pinned_generations": 2,
    "retention_slot_age_real_seconds": [0, 0, 1800, 21600, 86400, 604800],
    "premigration_keep_launches": 3,
    "quarantine_max_files": 3,
    "repair_threshold_frac": 0.02,
    "max_entities_sane": 200000
  },

  "offline": {
    "full_fidelity_hours": 72,

    // The absence cap itself is data/time.json's (doc 01, report C-19): 12 real h = 720 game-h,
    // and since report 98 §58 (RR-160) it is the ONLY thing that bounds the credit.
    // max_coarse_hours / _cap / _floor / catchup_time_budget_ms / coarse_hours_rounding_multiple
    // are DELETED (RR-161): they were a performance clamp on the player's wallet.
    // What this doc publishes instead is a wall-clock gate on the VEIL, and it lives in
    // data/persistence.json's `catchup` block because SavePolicy is that file's only reader:
    "veil_ms_at_cap": 6432,                  // MEASURED, tools/measure_offline_night.gd (doc 92 §55.6)
    "veil_budget_ms": 9000,                  // what that is allowed to be; the gate is <=
    "measured_coarse_ms": 5.488,             // RECORDED, founding city (P0-30)
    "bench_coarse_ms": 165.493,              // RECORDED, 1,500 buildings — over budget, AC-19-1

    // main-thread sliced catch-up only (report C-22); the WorkerThreadPool branch is deleted
    "slice_budget_ms": 12,
    "progress_emit_every_hours": 8,

    "bands": {
      // yield_mult is deliberately absent: doc 03 owns the offline economic curve (report C-20)
      // and populates band.yield_mult from exp(-(h-4)/90) at load. See doc 03 §2.11.
      "FULL":   {"incident_mult": 1.00, "damage_mult": 1.00, "fidelity_mult": 1.00, "director_allowed": true},
      "DAMPED": {"incident_mult": 0.50, "damage_mult": 0.50, "fidelity_mult": 0.60, "director_allowed": false}
    }
  },

  "fairness": {
    "offline_damage_cap_frac": 0.35,
    "offline_asset_condition_floor": 0.15,
    "offline_population_loss_cap_frac": 0.08,
    "offline_stability_floor": 0.20,
    "offline_allow_destruction": false,
    "offline_allow_deaths": false,
    "offline_max_director_hazards": 1,
    "offline_max_hazard_tier": 1,
    "offline_hazard_requires_prewarning": true,
    "return_grace_minutes": 120,
    "recovery_grace_minutes": 240,
    "recovery_safe_mode_damage_mult": 0.35,
    "deferred_bills_cap_days": 3,
    "deferred_bills_efficiency_mult": 0.80,
    "reserve_treasury_default": 50000,
    "casual_offline_hazards_allowed": false
    // difficulty_offline_mult {casual 0.50, standard 1.00, hard 1.30, crisis 1.60} MOVED:
    // it is authored by this doc but lives in data/difficulty.json under "offline",
    // owned by doc 03 (report C-17). One difficulty file, one schema, one loader.
  },

  "event_log": {
    "critical_ring_capacity": 64,
    "routine_ring_capacity": 448,
    "critical_severity_threshold": 3,
    "exemplars_per_key": 3
  },

  "report": {
    "min_absence_minutes": 10,
    "needs_you_now_max_rows": 5,
    "timeline_max_beats": 6,
    "progress_max_rows": 5,
    "dark_district_alert_minutes": 60,
    "urgency": {
      "severity_weight": [0, 1, 3, 7, 15],
      "severity_scale": 100.0,
      "minutes_unresolved_weight": 0.5,
      "population_divisor": 500.0,
      "imminent_escalation_bonus": 30.0,
      "imminent_escalation_window_minutes": 60,
      "critical_class_bonus": 50.0,
      "critical_classes": ["hazard", "fire", "hospital_threat", "water_outage"]
    }
  },

  "notifications_runtime": {
    "global_capacity": 8,
    "global_window_minutes": 1440,
    "global_min_gap_minutes": 5,
    "coalesce_min_count": 3,
    "coalesce_window_minutes": 15,

    // horizon_hours: 48 is DELETED (report C-23) — it meant 48 real minutes at the locked 60x scale.
    // Horizon is now split by predictability class; see §2.13.0.
    "deterministic_horizon_game_hours": 720,   // class (a): timers already in the save; zero projection
    "forecast_horizon_game_hours": 720,        // class (b): pre-rolled Director events; zero projection
    "emergent_projection_enabled": false,      // class (c): MVP ships disabled
    "projection_budget_ms": 80,
    "projection_steps_min": 12,
    "projection_steps_max": 60,

    "risk_notification_threshold": 0.80,
    "forecast_confidence_threshold": 0.80,
    "inexact_alarm_window_minutes": 5,
    "reengagement_min_absence_hours": 24,
    "reengagement_min_gap_hours": 48,
    "quiet_hours_default": {"enabled": true, "start_min": 1320, "end_min": 480, "allow_critical": false}
  }
}
```

`data/notifications.json` (class table + event table, §3.3) is the second half of this tunables set; its numbers are not duplicated here.

---

## 9. Conflicts & Open Questions

### Conflicts with the constitution — all resolved

- **C-1 — Compression on top of JSON.** *Resolved, report C-05.* Compliant: the format is JSON, compression is transport, debug builds write a plain mirror. Constitution §2 carries a one-line note for the record.
- **C-5 — A fifth source directory (`platform/`).** **WITHDRAWN, report C-04.** Doc 13 wins: the Android shell is `game/android/*` (GDScript) plus a Kotlin AAR under `android/plugins/slacum_native/`, which is build-system territory, not a source layer. Constitution §3's four layers stand unchanged. `sim/` reaches the platform only through the injected `IClockSource` / `IFileSink` / `INotificationSink` interfaces declared in §4 and implemented in `game/`. No constitution amendment is requested by this doc on this point.
- **C-6 — Device-scoped settings outside the save slot.** *Resolved, report C-03.* The file exists and is in constitution §2 as amendment #3, under doc 11's naming: **`user://settings.cfg`**, not `settings.json`. See §2.5.

*(No conflict is claimed against constitution §4's "1 game-hour steps" — this revision defers the schedule entirely to doc 01, which steps in whole coarse hours. Fidelity is expressed as multipliers within those hours, not as a different step size. Likewise no determinism exception is claimed against §5: band boundaries are a pure function of `catchup_index`, and there is no wall-clock watchdog anywhere in the offline path.)*

### Conflicts with sibling docs — all resolved

- **C-2 — Coarse-step cost, 45× apart.** *Resolved, report C-21.* Doc 01's 0.6 ms line is retired; this doc's decision rule is adopted **verbatim and normatively**, this doc owns `max_coarse_hours`, and P0-27 measures it. See §2.12 — the rule and its generated table are no longer conditional on anybody's estimate being right.
- **C-3 — Offline destruction.** *Resolved, report C-47.* The clamp stands (condition 0.15, incident left open) **and** doc 06 adds the `world.destroy_allowed()` guard so the refusal is visible rather than silently swallowed. See §2.3 rule 4.
- **C-4 — Section version key naming.** *Resolved, report C-25.* `section_version` inside every section, `schema_version` only on the envelope; docs 01, 02, 04, 09, 10 and 12 apply the one-word rename. This doc already complied.
- **C-7 — Notification ownership.** *Resolved, report C-71.* This doc owns **policy** (`data/notifications.json`: four classes, event mapping, budgets, quiet hours, coalescing; P4 disabled). Doc 13 owns the **platform** and deletes its parallel rate limiter. Doc 12 owns **only** in-app banners under `data/ui.json.in_app_alerts`. Doc 06 keeps `offline_notify_min_priority` as a digest threshold. Doc 01 keeps only the tick→wall conversion.
- **C-8 — Offline cap value.** *Resolved, report C-19 — this doc's recommendation carried.* **12 real hours = 720 game-hours = 30 game-days.** Doc 01 owns the constant in `data/time.json`; doc 13's `offline_max_hours = 72` is deleted; this doc defines no cap of its own. `M(H)` is recomputed at the new cap in §2.2 (`M(720) = 460.8`, ×0.64).
- **C-9 — SoA requirement on doc 02.** *Still live as a dependency, not a conflict.* §2.12's budget assumes `coarse_columns()` from doc 02 (doc 04 already has SoA arrays). If doc 02 ships object-per-entity the FULL-band hour rises ~2.5× and, by §2.12's rule, `max_coarse_hours` shrinks correspondingly — e.g. 27.3 ms → 68 ms would still clamp to the 72-hour floor, at ~4.9 s of veil. Doc 02 owes this interface.
- **C-10 — Horizon units (new, resolved).** *Report C-23.* The old `horizon_hours = 48` was 48 *game*-hours = 48 real minutes and was being described as real-world look-ahead. Deleted and replaced by §2.13.0's per-class split; doc 13's `plan_horizon_hours = 24` is corrected the same way.

### Open questions for the overseer

- **O-1 — Doc numbering.** *CLOSED by report 98 Ruling Zero.* The on-disk filenames are canonical; this doc's cross-references are renumbered accordingly and the old "best guess" warning box is deleted.
- **O-2 — Cloud save.** Currently deferred entirely, so losing a device loses a city — which sits badly against spec §47's spirit. Is Play Games Saved Games in scope for Phase 4, or post-launch?
- **O-3 — Is `restore_checkpoint` player-facing?** A visible "restore an earlier save" list is a strong safety net and an equally strong exploit (undo a disaster). Recommend: reachable only after an automatic recovery event, never as a free-standing menu item.
- **O-4 — Rewarded-ad catch-up boost.** Spec §38 permits rewarded ads for modest acceleration; the obvious hook is "watch an ad to recover the DAMPED-band penalty". Note post-C-20 that this would touch doc 03's curve for the money half and this doc's `fidelity_mult` for the rest, so it is now a *two-owner* change. It fits §37.2's letter but sits close to manufactured frustration. Recommend **no** for MVP — flagging it so it stays a decision rather than becoming a drift.
- **O-5 — Should the offline curves be visible to the player?** The report states "offline rate ×0.68" (doc 03's economic realization) and, when they diverge, "fidelity ×0.68" (`M(H)/H`). Honest, and it teaches that attending is better; it also makes the damping feel like a tax, and two numbers may be one too many for the header. Worth a UX call with doc 12 before the report ships.
- **O-6 — Does anything still need `fidelity_mult` once doc 03 owns revenue?** (New, post-C-20.) `M(H)` now damps only construction work units, population growth and research. If doc 09 and doc 02 would rather taper those on their own curves, the two-band fidelity column collapses into pure bookkeeping and `M(H)` becomes a reporting figure only. Recommend keeping it as specified until doc 03's curve has been pacing-tested against real catch-ups — a single owned damper is better than three unowned ones.

---

## Amendments applied (report 98)

Every row below is a binding ruling from `98-consistency-report.md` §12 (doc 08 worklist) applied to this document. Deleted numbers are **removed**, not commented out; each deletion carries a pointer to the doc a reader should now consult.

| Ruling | Where | What changed |
|---|---|---|
| **Ruling Zero** | header, §2 throughout, §5 | On-disk filenames are the canonical numbering. The "numbering warning" box is deleted; every "the Time doc / the Incidents doc / (guessed no.)" reference is replaced with a real doc number, and §5's cross-system table is rebuilt around docs 01–13 as filed. |
| **C-03** | §2.5, §2.13.4, §8 | Device-scoped settings adopt doc 11's name: **`user://settings.cfg`**, never inside a save, never migrated. The old `user://settings.json` is withdrawn; notification *preferences* move there while the `notifications` save section keeps only roll-back-able runtime state. |
| **C-04** | §4, §5, §9 | The proposed fifth source layer `platform/` is **withdrawn**. Constitution §3's four layers stand; the Android shell is `game/android/` + `android/plugins/slacum_native/` (doc 13), and `sim/` reaches it only via injected `IClockSource` / `IFileSink` / `INotificationSink`. |
| **C-19** | §2.1, §2.2, §2.10, §2.11, §7, §8 | Offline cap is **12 real hours = 720 game-hours = 30 game-days**, owned by doc 01 in `data/time.json`. This doc defines no cap of its own. DAMPED band becomes 72–719; discard at ≥ 720. |
| **C-20** | §2.1, §2.2, §3.2, §7, §8 | This doc's **flat 1.00 / 0.60 economic yield rows are deleted**. `band.yield_mult` is carried but authored by doc 03 from its exponential taper `exp(−(h−4)/90)` (see doc 03 §2.11). `incident_mult`, `damage_mult` and `director_allowed` stay; the 0.60 fidelity weight survives only as `fidelity_mult`, which never touches revenue. |
| **C-21** | §2.12, §7 (33), §8 | The measurement decision rule is now **normative, not conditional**: `max_coarse_hours = clamp(floor(ceil(2000 / measured_coarse_ms) / 24) × 24, 72, 720)`, measured by P0-27. Doc 01's 0.6 ms budget is retired. This doc owns the tunable; a generated seven-row table shows the rule's output. |
| **C-22** | §2.6, §2.12, §7 (23b), §8 | The **`WorkerThreadPool` branch and `async_threshold_hours` are deleted**. Catch-up of any length is main-thread sliced via doc 01's `advance_coarse_sliced(max_ms)` with `steps_done()`/`steps_total()`, `slice_budget_ms = 12`, behind doc 13's veil; `catchup_progress` retained. (The save *encode* worker is unaffected — it touches only a detached snapshot.) |
| **C-23** | §2.13.0, §7 (32b), §8 | `horizon_hours = 48` is deleted (it was 48 real *minutes*). Horizon splits by predictability class: deterministic timers and pre-rolled Director events are scheduled to the **full 720-game-hour cap with zero projection**; emergent projection is budget-bounded at `clamp(floor(80 / measured_coarse_ms), 12, 60)` steps and **ships disabled in MVP**. |
| **C-24** | §2.5, §2.6, §2.7, §5 | Ownership of persistence asserted over doc 13: its pause step is `SaveManager.request_save("pause")`; its `city.json`, 3-deep `.bak` rotation, fallback logic and `saves_recovered_from_backup` counter are deleted in favour of the generation ladder + manifest commit + quarantine. Doc 13 keeps its ≤ 250 ms pause budget and lifecycle ordering. |
| **C-26** | §3.1 | The save-section registry is **replaced with report §11 verbatim** — adds `roads` (10), `render_prefs` (11), `ui` (12), `android` (13), `population`/`progression`/`stats` (09); `construction` → 02; `districts` → 09. 24 section keys; the "Districts, Population & Stability" and "Economy & Construction" phantom owners are gone. |
| **C-47** | §2.3 rule 4, §5, §7 (18) | The offline destruction clamp stands (condition 0.15, incident left open) and now records doc 06's added `world.destroy_allowed()` guard, so the destroy verb is refused **visibly** instead of being silently swallowed by `OfflineGuard`. |
| **C-68** | §4, §3.2, §5, §7 (23c) | The first post-catch-up snapshot carries **`is_resync: true`** as a contract field, so doc 11 snaps emissive state instead of replaying up to 30 game-days of relight sweeps. `meta.last_catchup.is_resync_emitted` makes it survive a kill between commit and first frame. |
| **C-71** | §2.13, §2.13.1, §2.13.4, §3.3, §5 | This doc is **sole owner of notification policy** in `data/notifications.json`: four classes, event mapping, budgets, quiet hours, coalescing; **P4 ships disabled** (`mvp_enabled: false`, no channel). Doc 13 owns the platform and deletes its parallel rate limiter; doc 12 owns only in-app banners under `data/ui.json.in_app_alerts`. |
| **R-15** | §2.2, §7 (15) | `M(H)` regenerated at the new cap: `M(H) = 1.00 × min(H,72) + 0.60 × clamp(H−72, 0, **648**)`; **`M(720) = 72 + 388.8 = 460.8`, `460.8 / 720 = ×0.64`**. Full table for H ∈ {24, 72, 240, 372, 480, 720}; test 15 expectations recomputed. |

### Shipped after report 98 — the persistence unification (2026-08-19)

| Where | What changed |
|---|---|
| §2.5 | The two save formats become one. `game/save_service.gd` keeps its five-method API and loses its storage half to `SaveManager`; a player slot is a generation directory (`user://saves/slot_N/`); the slot header moves from the file's first bytes into `manifest.active.meta`; envelope `schema_version` recorded as **1**, not §8's illustrative 7; `debug_plain_mirror` ships `false` and is flagged as owed. |
| §2.7 | **Ruling: doc 13's two-slot autosave shadow is retired and this ladder subsumes it** — same guarantee, five fallbacks instead of one, each digest-verified, and slot 7 returned to the player. `SaveService.last_good_autosave_slot()` still answers, now via `SaveManager.peek_newest()`, a probe that is side-effect-free by contract. `save_slot(sim, slot, reason)` carries §2.7's reason, so `pre_migration` / `pre_catchup` pin from the shell. |
| §2.8 | The **format-1 → format-2 reader** lands with a byte-for-byte fixture (`tests/fixtures/legacy_slot_format1.json`) captured from the shipped writer and never regenerated. Format-1 files are read, never rewritten, and stand as their own `pre_migration` checkpoint; they are also the ladder's last candidate. Section ladders reach the sim body through `sim.save_section_version()` / `sim.migrate_save_section()`, duck-typed, via `sim/persistence/dict_section.gd`. |
| §2.9 | The seven-check gate, quarantine and repair notes are now on the path the app runs. `SaveService` surfaces two new failure reasons — `corrupt` and `downgrade` — plus `last_load_recovered` / `last_load_lost_minutes` / `repair_notes` for the recovery UX this section specifies. |
| §2.12 | Save-side budgets **measured** on both cities; all four hold at the benchmark city. Compression cut a slot from 1.28 MB to 130 KB, so six retained generations cost less disk than one file of the old format. |
| §4 | `sim/persistence/` as shipped: `save_manager.gd`, `save_section.gd`, `dict_section.gd`, `save_policy.gd`. `SaveEncoder` / `SaveMigrator` / `SaveValidator` / `CheckpointPolicy` are methods, not classes, deliberately. |
| §7 (37) | **Ruling: `bench_city.json` is a BOOT file, not a save body** (Wave 6's flag, settled). The test validates it as one and then round-trips the city it produces through the save path — a stronger reading of report G-7 than the original. Doc 09 §2.13 says "boot file" throughout as of 2026-08-19. |
| §8 | `data/persistence.json` exists, `save` block only. `offline` / `fairness` / `event_log` arrive with their consumers rather than sitting unread. `notifications.json.runtime` deliberately stays put. |

**Also applied, from rulings that name doc 08 outside the §12 worklist row:** **C-17** (`difficulty_offline_mult` moved out of `data/persistence.json` into doc 03's `data/difficulty.json`, authored here), **C-55** (this doc's offline Director invariants recorded as the outer clamp doc 07's F8 is tightened to), **C-72** (push budgets stated as distinct from doc 12's in-app rates), **C-25** (recorded as settled; this doc already used `section_version` and needed no rename), and **G-7** (new test 37: this doc validates doc 09's `bench_city.json` fixture against the current registry in CI).

---

## WAVE 17 — Core Rule 2 on a cold launch, and §2.12 implemented (2026-09-01)

*Appended rather than woven in: three sibling branches are editing this document
in the same wave. Where this section and an older one disagree, this one is what
the code does, and each subsection names the section it amends.*

### Core Rule 2, §2.1 — the restore owes the absence, on every path

**§2.1 as it stood assumed the process survived the absence.** It did not say so,
which is how nobody noticed: the only implementation of the offline credit was
reached from `NOTIFICATION_APPLICATION_RESUMED`, and a killed process never gets
one. Measured at the fork: the sole `CatchUpPlanner` call in the shell was
`game/main.gd:1630`, inside `_on_app_resumed`; `game/android_lifecycle.gd:171-182`
measured an absence only when `_paused_wall >= 0.0`; and `_paused_wall` was an
in-memory member, `-1.0` at every boot, **never seeded from disk**. So after a
process death, a swipe-away, a low-memory kill, or the title door's CONTINUE —
which is the *default* launch — the city resumed frozen at the pause.

**Amended rule.** *After any successful restore, the city is owed the real time
since the generation it was restored from was committed.* The paths are the title
door's CONTINUE, `--resume`'s `load_latest`, and crash recovery; the credit runs
through the same planner, the same `CatchUpCursor` and the same veil an
in-process resume uses. A founding city owes nothing, because there is no
generation behind it.

**What the save carries.** Doc 13 §3.2's `save.android.last_pause`, built by
`game/android/lifecycle_stamp.gd` and stamped by `AndroidLifecycle.capture_stamp`
on **every** save — a periodic autosave the process was killed after is as much
"the last time this city was awake" as a pause is, and `clean` distinguishes
them. `manifest.active.real_unix` is the fallback for every generation written
before this wave; it is a wall reading with no monotonic bracket, credited on
exactly the terms desktop has always been credited on.

**§2.8 / RR-75 note.** `android` is a new section at `section_version = 1` and
owes no epoch marker. It is registered on the WRITE side only: registering it on
the read side would make `_validate_structural` file a `repair_notes` entry for
every generation that predates it — i.e. all of them — and put "(1 repairs)" in
front of a player whose save is healthy. The read side takes it from the loaded
body directly. The deviation is deliberate, is recorded in report 98 §48, and
reverses the day a v2 needs a migrator.

### §2.9's clock-backwards clamp, as built

`meta.max_seen_unix` was written and read by nothing. It is now doc 08 §2.9's
tamper floor on the cold path, in `LifecycleStamp.elapsed_since`, and it is the
FIRST of three checks and the only absolute one:

```
floor_unix = max(max_seen_unix, stamp.unix_s)
if now_unix + 120 s < floor_unix:      # doc 13 §2.3's tolerance, not a new number
    elapsed = 0 ; anomaly = clock_backwards ; log it ; play continues
```

The 120 s tolerance is what separates a tamper from a routine NTP correction; §2.9
says *clamp, never punish*, and a 60-second correction that zeroed an eight-hour
absence would be a punishment. The other two checks (the `elapsedRealtime`
ceiling within one boot, the reboot floor across boots) are doc 13 §3.2's and are
written out there.

### §2.12 — `max_coarse_hours`, implemented, with the numbers

> **SUPERSEDED 2026-09-03 — report 98 §58, RR-160/RR-161.** Everything in this
> subsection happened and is kept as the record of it. What it shipped was a
> clamp on the **credited absence**, and six real hours of credit is what a
> player got for a night's sleep; doc 92 §55 measures the bill at **$73,511 for
> an eight-hour night on a settled L3 city**. `max_coarse_hours` is deleted and
> §2.12's budget now gates the **veil**. Read the section above, not this one,
> for what ships.

The decision rule in §2.12 has been NORMATIVE since report C-21 and was
implemented nowhere: `grep -rn max_coarse_hours sim/ game/ data/` returned zero
hits at the fork. It is now `CatchUpPlanner.derive_max_coarse_hours`, stated once,
and the shipped value lives in `data/persistence.json`'s new `catchup` block —
this document's file, as §2.12 requires — read by `SavePolicy`, which is still
the file's only reader.

**Measured 2026-09-01, this workstation, debug headless**
(`godot --headless -s res://tools/profile_sim.gd -- --coarse-hours=48
--fine-hours=1 --repeats=3 --no-profile --quiet`):

| City | `measured_coarse_ms` | `ceil(2000/m)` | ↓ to ×24 | `max_coarse_hours` | Real-time cover |
|---|---|---|---|---|---|
| `data/starter_city.json` — the reference city | **5.488** | 365 | 360 | **360** | 6 h |
| `tests/fixtures/bench_city.json` (1,500 buildings) | **165.493** | 13 | 0 | **72** (floor) | 1 h 12 m |

Doc 13 §2.13's Fold multiplier is 3–5× on top of both. **360 ships**; report 98
§48 RR-133 rules which city the rule reads and argues it. The bench figure is
recorded beside it in the same block so the 30× disagreement stays visible.

> **The measurement is load-sensitive, and doc 01 §2.10 already said so.** The
> figure above is a dedicated run: 48 coarse hours, best of 3 repeats, on an
> otherwise-quiet box. `tests/test_milestone1.gd`'s P0-30 line takes 24 steps in
> a single pass in the middle of the suite, and on this branch, with three
> sibling suites running, it read **6.59 ms → 288**. Doc 01 §2.10's own note
> puts the 312/288 boundary at exactly `measured_ms = 6.410` and calls the
> spread what it is. **That is why the shipped clamp is a NUMBER IN A FILE and
> not a live measurement**, and why `tests/test_catchup_clamp.gd` re-derives it
> from `measured_coarse_ms` rather than from a fresh timing: a clamp that moved
> with the load on the build machine would not be deterministic, and one that
> moved with the load on the *player's phone* would be a fairness bug.

**Applied** in `CatchUpPlanner.plan` as `credited = min(elapsed,
OFFLINE_CAP_REAL_MS, max_coarse_hours × 60 000 ms)` — one game-hour of absence
costs 60 000 real ms, so 720 game-hours is exactly `OFFLINE_CAP_REAL_MS` and the
clamp can only ever tighten doc 01's C-19 cap, never raise it. The plan now
returns `cap_real_ms`, `cap_game_hours` and `discarded_real_ms` beside `capped`,
which is what lets §2.11's report say what it discarded rather than only that it
discarded something.

**Reported**, as §2.12 requires (*"the report says so (`catchup_capped`)"*), and
this is where a second defect fell out: `ui/away_model.gd` has carried
`capped_text` since S12 and the shell's report dictionary **had no `capped` key at
all**, so the line was unreachable; and `ui_veil_catchup_capped` had "12 hours"
written into the string. Both now carry the cap that was actually applied.

**What a player notices.** An absence longer than 6 real hours credits 360
game-hours (15 game-days) instead of 720 (30). `tests/test_catchup_planner.gd` is
re-pinned with both forms — doc 01's C-19 ladder arithmetic with the cap passed
explicitly, and the shipped default beside it.

### §2.11 — the away report's 'before' survives a kill

A pause taken while the catch-up veil is up used to commit a mid-absence city
*and* overwrite the report's 'before' snapshot with it, so the report diffed the
city against a half-advanced version of itself. Three changes (report 98 §48
RR-134, doc 93 §AG3):

* the pause mid-catch-up does not touch the snapshot;
* it is written with reason **`pause_mid_catchup`** — a new `SYNC_REASONS` entry,
  sync for the same reason `pause` is — so a cold launch can tell a settled
  generation from a mid-absence one;
* the unspent tail of the plan **and** the pre-absence snapshot ride
  `last_pause.unfinished`, so the relaunch finishes the interrupted plan and
  still reports against the city the player actually left.

§2.13's notification pass is skipped for the same pause, for the reason doc 93
§AG3 gives: the alarms would be scheduled against a future still being computed.

### Tunables added to `data/persistence.json`

```jsonc
"catchup": {
  "measured_coarse_ms": 5.488,    // one FULL-band coarse hour, reference city
  "bench_coarse_ms": 165.493,     // recorded, not shipped — RR-133
  "max_coarse_hours": 360         // clamp(floor(ceil(2000/5.488)/24)*24, 72, 720)
}
```

`tests/test_catchup_clamp.gd` re-derives `max_coarse_hours` from
`measured_coarse_ms` and fails if the two disagree, so the shipped number cannot
drift from the measurement printed beside it.

---

## WAVE 19 — the clamp was on the wrong axis, and a night is paid in full again (2026-09-03)

**Report 98 §58 (RR-160..RR-163) is binding; doc 92 §55 carries the numbers.**
The player's sentence, from their own Fold 6 city: *"I went to bed hoping I'd
wake up to a bunch of money. The money stops after a certain amount of hours of
the game being closed."*

They were describing the subsection immediately above. Wave 17 implemented this
doc's `max_coarse_hours` and fed it into `CatchUpPlanner.plan` as a second clamp
on the credited absence; at the founding city's 5.488 ms coarse hour it shipped
at **360 game-hours = 6 real hours**, and hours 7, 8 and 9 of a night credited
nothing at all.

### What changed in this document

| §  | was | is |
|---|---|---|
| §2.1 | "`max_coarse_hours` is a performance clamp that may only ever be ≤ the doc-01 cap" | this doc narrows the credited absence by nothing; §2.12's budget bounds the veil |
| §2.12 | a NORMATIVE derivation, `clamp(floor(ceil(2000/m)/24)×24, 72, 720)`, applied to the credit | a measured wall-clock gate, `veil_ms_at_cap ≤ veil_budget_ms`, applied to the veil and read by no shipped code |
| §7 (33) | P0-27 sets the clamp | P0-27 prints the veil estimate; new test **33b** `test_catchup_veil_budget` is the arbiter |
| §7 (35) | `test_catchup_perf_cap` | retired with its subject |
| §8 | five clamp tunables under `offline` | `veil_ms_at_cap` / `veil_budget_ms`, with the two coarse-hour measurements recorded beside them |

### What did NOT change, and why that is the finding

**§2.3's eight fairness rules are untouched.** Offline still draws no street
opportunities (rule 9), catch-up is still a session kind and not a step size, and
the Director is still held to one pre-warned Tier-1 event per absence. The
obvious suspects for *"the money stops"* were those rules and doc 03 §2.11's
exponential taper, and both were **measured** rather than assumed: with the
credited window restored, an absence pays **97.4–101.1%** of what the same hours
are worth online-and-idle, at every length from one real hour to twelve (doc 92
§55.4). The taper's 94-effective-hour ceiling is real and is very nearly
cancelled at a growing city, because the work the player already paid for is
`TAPER_EXEMPT`. No taper change is shipped and no difficulty scalar moved.

### The one thing left to the shell

`game/main.gd` passes `elapsed_wall_s` as the away report's
`elapsed_game_minutes`, so a **capped** absence over-reports city time (RR-162).
The snippet is the lead's and is anchored in report 98 §58.2. An uncapped absence
— which is now every absence up to 12 real hours — already reports correctly,
because credited *is* elapsed.
