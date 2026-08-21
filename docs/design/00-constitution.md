# SLACUM CITY — Design & Engineering Constitution

**Status:** LOCKED — deviations require explicit overseer approval and must be flagged, never made silently.
**This document overrides all other design docs where they conflict.**
**Cross-doc rulings in `98-consistency-report.md` are binding on docs 01–13; a doc that contradicts a ruling is stale, not authoritative.**
**Parent spec:** `docs/BLACKOUT-spec.md` (BLACKOUT was the working title; the game is now **SLACUM CITY**).

---

## 1. Product Identity

- **Title:** SLACUM CITY
- **Tagline:** *You built it. Now keep it alive.*
- **Genre:** Persistent urban survival / crisis-management city builder (see spec §1–§6).
- **Platform:** Android-first, native app. Landscape orientation.
- **The 15 Core Design Rules in spec §55 are constitutional.** Every system design must be checked against them.

## 2. Technology (LOCKED)

| Decision | Value | Rationale |
|---|---|---|
| Engine | **Godot 4.7.2 stable** | Spec §28 sanctioned Godot if tooling shifts; agentic CLI development requires headless-scriptable engine; free; exports native ARM64 Android with Vulkan. |
| Renderer | **Mobile** (Vulkan) on Android; Forward+ acceptable in editor/dev | Best mobile graphics path in Godot; supports glow/emissive night city. |
| Language | **Typed GDScript** everywhere initially | One language, fast iteration, headless-testable. Hot paths may move to C++/GDExtension ONLY after profiling proves need. |
| Android target | targetSdk = 37 (latest installed), **minSdk = 29** (Android 10) | "Latest Android" mandate; Vulkan baseline; covers modern devices. |
| Package id | `com.slacumcity.game` | |
| Persistence | Versioned JSON per save slot (`user://saves/slot0/`), atomic write (tmp + rename), rotating checkpoints. The on-disk file may be zstd-compressed (the *format* is still JSON; debug builds write a plain mirror). Binary/SQLite is a post-alpha optimization, not an MVP concern. | |
| Device settings | Graphics preset, notification prefs, accessibility live in `user://settings.cfg` — device-scoped, outside any save slot, never touched by the save migration ladder. | Survive city deletion and checkpoint rollback. |
| Tests | Custom minimal headless runner: `godot --headless --path . -s res://tests/run_tests.gd`, or `tools/run_suite.sh`. Every sim system ships with tests in the same commit. **Two rules the runner enforces itself (2026-08-20), because both were learned the hard way:** it moves `user://` to a per-process directory before the first test loads, so two worktrees can run the suite at the same time; and **a test method that finishes without making a single assertion FAILS the run** — a GDScript runtime error unwinds one function and returns quietly, so "aborted" and "passed" are otherwise the same thing from the runner's seat. | Report 98 RR-57 |
| VCS | git, branch `main`. | |

## 3. Architecture (LOCKED) — spec §27, Core Rule 11

Four layers, strict dependency direction (lower layers never import from higher):

```
sim/     Simulation core. Pure logic. RefCounted classes ONLY.
         NEVER imports Node, scenes, rendering, UI, or engine singletons
         (no Input, no OS time, no Engine). Time and RNG are injected.
game/    Rendering & scene layer. Reads sim state via snapshots/events. 3D city, vehicles, weather VFX, lighting, camera.
ui/      HUD, overlays, panels, dialogs. Talks to sim through a command API, reads via the same snapshots/events.
data/    JSON balance tables. ALL tunable numbers live here. No magic numbers in code.
```

- `sim/` communicates outward via an **event bus** (plain event objects appended per tick) and a queryable state. `game/` and `ui/` communicate inward via **commands** (place_building, dispatch_unit, buy_land, …) validated by the sim.
- The sim must run headless, with no scene tree, for tests and offline catch-up.

## 4. Time Model (LOCKED defaults; values live in `data/time.json`)

- Canonical clock: **`tick_index` — whole SimTicks since city founding**, int64. `sim_time_minutes = tick_index / 4` is a derived field, written at save top level and asserted equal to `tick_index / 4` on load. No floats for the master clock. *(Amended per report 98 C-01.)*
- **Scale: 1 real second = 1 game minute** (60×) while app is open ⇒ one full day/night cycle = 24 real minutes. Offline elapsed real time is credited at the same 60× scale up to a cap owned by `data/time.json` (default: 12 real hours; surplus is discarded and reported, never banked). *(Per report 98 C-19.)*
- **SimTick = 0.25 real seconds = 15 game-seconds.** The sim advances in whole ticks; rendering interpolates.
- Tick-rate layers (spec §29.5): vehicles every tick @ render-visible cadence (logic 4 Hz + interpolation), utilities 4 Hz, incident evaluation 1 Hz, economy per game-hour, population/growth per game-day. **Cadences are game-time — `EVERY_TICK` / `EVERY_MINUTE` / `EVERY_HOUR` / `EVERY_DAY` — equal to 4 Hz / 1 Hz only at 1× speed. Real-world Hz never appears in sim math, so speed controls cannot alter balance.** *(Per report 98 C-02.)* Systems subscribe to cadences; the scheduler is one place, not per-system timers.
- **Offline catch-up** uses the SAME system code via a coarse advance path (1 game-hour steps), never a separate parallel implementation of the rules (spec §21, §47).
- No system reads wall clock. `GameClock` is injected; real elapsed offline time is measured once at resume by the app shell and handed to the sim.

## 5. Determinism & RNG (LOCKED) — spec §47

- Every stochastic system gets its own **named RNG stream** (`RandomNumberGenerator` with persisted seed + state). Streams: `weather`, `incidents`, `crime`, `failures`, `director`, `traffic`, `street`, `misc`. *(`street` added per report 98 RR-77 for doc 06 §2.16's opportunity layer. The roster is a ROSTER, not a cap: the rule above is that a new stochastic system takes a new stream, so a new system extends this list by definition. Extending it costs the existing streams nothing — each stream's seed is `hash(master_seed + ":" + name)`, so a name that did not exist perturbs no sequence that did — and the whole cost lands in one place, the `rng` block of the save body, which is why the addition takes a section rung.)*
- Same save + same elapsed time ⇒ same offline outcome. Cross-device bit-determinism is NOT required (single-player, local saves).
- Never call a shared/global RNG from sim code.

## 6. World Units (LOCKED)

- **1 tile = 8 m.** Grid-aligned world, XZ plane, Y up.
- **Land block = 16×16 tiles** (128 m square). Land purchase, development, and render/sim chunking all use the land block as the unit. Chunk == land block.
- Building footprints in whole tiles (1×1 house up to 4×4 stadium/arcology-class).
- Roads occupy tiles; the road graph nodes are intersections/endpoints, edges are road segments (spec §8.1).
- Starter city ≈ 3×3 land blocks developed + surrounding purchasable ring (exact layout in doc 09).

## 7. Economy Units (LOCKED)

- Currency: whole dollars, int64. UI formats as $1.2K / $3.4M.
- All rates expressed **per game-hour** internally; UI may display per-day.
- No premium currency in MVP. Monetization hooks come post-alpha (spec §37 principles are constitutional).

## 8. Simulation State Truths (LOCKED)

- Population is **aggregate per building** (spec §29.1). No individual citizens.
- Emergency/service vehicles are **real entities with real routing**; civilian traffic is density/cosmetic (spec §29.2).
- Incidents are first-class sim objects with the spec §33 fields.
- Utilities (power, water) are **graphs with capacity/load/condition**, not coverage percentages (spec §3).
- Cascades are **data-driven dependency edges** (spec §34), not hand-scripted chains.
- District = aggregation region (one or more land blocks) carrying stability/crime/reliability aggregates (spec §46).

## 9. Save Schema Ground Rules

- Top-level: `schema_version` (int), `sim_time_minutes`, `rng_streams`, then per-system sections. Each system owns serialize/deserialize of its section.
- Migrations: ladder of `migrate_vN_to_vN+1` functions; never break an existing city (spec §47: "The player must not lose a long-running city due to an update").
- Event history ring buffer persisted for the WHILE YOU WERE AWAY report.

## 10. Design-Doc Contract (for all subsystem design docs 01–13)

Every design doc MUST contain, in order:
1. **Overview & goals** — what this system does and its role in the core loop.
2. **Mechanics** — exact rules and **formulas with real numbers**, worked examples included. Vague prose ("should feel dangerous") is not acceptable where a formula can exist.
3. **Data schema** — the JSON structures for `data/` tables and for this system's save-file section.
4. **Sim API sketch** — main classes, tick entry points, commands handled, events emitted (names only, brief).
5. **Cross-system interfaces** — exactly what it reads from / provides to other systems (reference other docs by number).
6. **MVP cut** — what ships in the vertical slice vs deferred, per spec §43.
7. **Test plan** — the concrete headless test cases that prove it works.
8. **Tunables** — one consolidated JSON block of every balance constant introduced, ready to drop into `data/`.
9. **Conflicts & open questions** — any tension with this constitution or another doc, flagged explicitly.

## 11. Art Direction Anchors (from spec §24–§25)

Dark atmospheric neo-noir. Night is the signature: emissive windows, streetlights, district-scale blackout darkening and relight moments. Placeholder art phase: stylized gray-box buildings with emissive window textures — readable by archetype and level from silhouette alone. No photorealism chase.

## 12. Development Doctrine

- **Vertical slice first** (spec §44): the loop *buy land → develop → build → tax → upgrade → overload → improve → survive incident → repair → grow* must be fun before content expands.
- Test along the way: sim systems are TDD-leaning; nothing merges without its headless tests passing.
- Every balance number is data, every data file has a schema, every system has a test.
- When a design doc and code disagree, the doc is updated in the same change — docs stay truthful.
