# 01 — Time Model & Tick Scheduler

**Status:** Proposed (awaiting overseer sign-off)
**Owner doc for:** the canonical game clock, the tick scheduler, deterministic system ordering, day/night curves, timers, scheduled events, pause/speed, and the fine/coarse advance interface used by offline catch-up.
**Governed by:** `docs/design/00-constitution.md` §4 (Time Model, LOCKED), §5 (Determinism), §7 (Economy Units), §10 (Design-Doc Contract).
**Data file:** `data/time.json`
**Code root:** `sim/time/`

Sibling-doc numbering follows **report 98 Ruling Zero: the on-disk filenames are canonical, and there is no other map.** The provisional table this doc previously carried (06=roads, 07=dispatch, 08=construction, 10=incidents, 11=weather, 12=population, 13=persistence) was one of five incompatible maps and is deleted. Every cross-reference below has been renumbered.

| Doc | System | Code root |
|---|---|---|
| 02 | Buildings, upgrades & construction projects | `sim/buildings/`, `sim/construction/` |
| 03 | Economy, taxes, land market & difficulty | `sim/economy/` |
| 04 | Electrical grid | `sim/power/` |
| 05 | Water system | `sim/water/` |
| 06 | Incidents, dispatch & emergency fleets (incl. construction crews as units) | `sim/incidents/`, `sim/dispatch/`, `sim/fleet/` |
| 07 | Weather & Disaster Director | `sim/weather/`, `sim/director/`, `sim/disasters/` |
| 08 | Persistence, offline policy & notification policy | `sim/persistence/`, `sim/offline/`, `sim/history/`, `sim/notify/` |
| 09 | Map, land, districts, population & stability, starter city | `sim/world/`, `sim/population/` |
| 10 | Roads, routing & traffic | `sim/roads/` |
| 11 | Rendering & performance | `game/` |
| 12 | UI/UX, camera input & onboarding | `ui/` |
| 13 | Android integration & export | `game/android/`, `android/plugins/` |

---

## 1. Overview & Goals

The time system is the spine of SLACUM CITY. Cascading infrastructure failure — the game's defining feature (spec §34, Core Rule 1) — is only legible to the player if the *order* in which systems observe each other is fixed and explainable. "The pump stopped because the feeder tripped in the same tick" must be true every single time, on every device, online and offline.

This system owns five responsibilities:

1. **One canonical clock.** Game-time is an integer count of SimTicks since founding. Nothing in `sim/` ever reads a wall clock (constitution §4).
2. **One scheduler.** Systems do not own timers or accumulate their own deltas. They *subscribe to a cadence* and *declare a phase*. The scheduler decides who runs, in what order, how often.
3. **Deterministic ordering.** A single, published, 18-phase order (§2.4) that guarantees producers run before consumers, and that documents every place a one-tick lag is deliberate.
4. **One time-shaped modifier layer.** Day/night curves, rush hours, night crime, commercial hours, and scheduled events (stadium, hazard warnings) all resolve into named **modifier channels** that other systems read from a frozen `TimeContext` — never by asking "what time is it?" themselves.
5. **One advance interface with two granularities.** `advance_fine` (15 game-seconds) and `advance_coarse` (1 game-hour). Offline catch-up calls the *same systems in the same phase order* through the coarse entry point. There is no parallel offline rules engine (constitution §4, spec §21/§47).

**Non-goals.** This doc does not decide what any system *does* in its tick — only when it runs, how often, with what time-derived inputs, and how it must behave when the step is coarse.

---

## 2. Mechanics

### 2.1 Units and the canonical counter

| Quantity | Value | Notes |
|---|---|---|
| Time scale (foreground) | 1 real second = 60 game-seconds (1 game-minute) | Constitution §4, LOCKED |
| SimTick | 15 game-seconds | Constitution §4, LOCKED |
| Real seconds per tick @1x | 0.25 s | 4 ticks/real-second |
| Ticks per game-minute | 4 | |
| Ticks per game-hour | 240 | |
| Ticks per game-day | 5 760 | |
| Real time per game-day @1x / 2x / 3x | 24 / 12 / 8 real minutes | |
| Game-days per game-season | 30 | |
| Game-days per game-year | 120 (4 seasons) | ≈ 48 real hours of foreground play @1x |
| Week length | 7 days | day 0 of the calendar is Monday |

**Canonical counter: `tick_index : int64`** — completed SimTicks since founding. Tick `t` advances the clock from `t × 15` to `(t + 1) × 15` game-seconds.

Constitution §4 names the canonical clock "game-minutes since founding, int64". `sim_time_minutes` remains exactly that and is **stored at save top level as required by §9**, but it is a *derived view*:

```
sim_time_minutes = tick_index / 4          # exact integer division; 4 ticks = 1 minute
tick_index       = sim_time_minutes * 4 + tick_phase   # tick_phase ∈ {0,1,2,3}
```

Because a tick is a quarter-minute, the minute counter alone cannot round-trip the state; `tick_index` is therefore the authoritative persisted field and `sim_time_minutes` is written alongside it and asserted consistent on load. This is a clarification of §4, not a deviation — see §9.

**Sub-tick residual.** Real elapsed time rarely divides evenly into ticks. The unconsumed remainder is held as `residual_game_ms : int` (0 ≤ r < 15 000) and persisted, so pausing, saving, or backgrounding never silently gains or loses a fraction of a tick.

**Founding offset.** The city is founded at day 0, **06:00** (dawn, not midnight), so the first session opens on a lit city ramping into morning rush. `FOUNDING_OFFSET_MINUTES = 360`.

### 2.2 Calendar derivation (exact)

Given `tick_index = t`:

```
game_seconds       = t * 15
abs_minutes        = game_seconds / 60 + FOUNDING_OFFSET_MINUTES
day_index          = abs_minutes / 1440
minute_of_day      = abs_minutes % 1440
hour_of_day        = minute_of_day / 60
day_of_week        = day_index % 7                     # 0 = Monday
day_type           = 1 if day_of_week >= 5 else 0      # 0 weekday, 1 weekend
season_index       = (day_index / 30) % 4              # 0 spring,1 summer,2 autumn,3 winter
season_progress    = ((day_index % 30) * 1440 + minute_of_day) / 43200.0   # 0..1
year_index         = day_index / 120
```

**Worked example.** `t = 918 442`.
`game_seconds = 13 776 630`; `abs_minutes = 229 610 + 360 = 229 970`;
`day_index = 159`; `minute_of_day = 1 010` → **16:50**; `day_of_week = 159 % 7 = 5` → **Saturday**, `day_type = 1`;
`season_index = (159/30) % 4 = 5 % 4 = 1` → **summer**; `year_index = 1`.
So tick 918 442 is *Saturday 16:50, day 159, summer of year 1* — twenty minutes into evening rush, on a weekend.

### 2.3 Cadences

Cadences are defined in **game time, not real Hz.** At 2x speed a tick arrives twice as fast in real seconds, so its real-world frequency doubles — but no system's *behaviour* changes, because a tick is always 15 game-seconds of simulated time. Constitution §4's "utilities 4 Hz, incidents 1 Hz" is exactly the @1x real-time rendering of the game-time cadences below.

| Cadence | Period | Nominal real Hz @1x | Constitution §4 mapping |
|---|---|---|---|
| `EVERY_TICK` | 1 tick = 15 game-sec | 4 Hz | utilities, vehicle logic |
| `EVERY_MINUTE` | 4 ticks = 1 game-min | 1 Hz | incident evaluation |
| `EVERY_HOUR` | 240 ticks | 1/60 Hz | economy |
| `EVERY_DAY` | 5 760 ticks | 1/1440 Hz | population / growth |
| `EVERY_N(n, offset)` | n ticks, phase-shifted | — | escape hatch, must be declared in data |

**Firing rule.** A subscription with period `P` and offset `O` fires on tick `t` iff `(t - O) mod P == 0`. Default `O = 0`, so hourly systems fire on the tick whose *start* is exactly `hh:00:00`, and **that invocation settles the hour that just ended**. Same for days.

**Worked example.** Economy is `EVERY_HOUR`, `O = 0`. It fires on `t = 240` (start time 3 600 game-sec = 01:00 relative to founding, i.e. 07:00 wall) and books taxes and upkeep for the interval 06:00–07:00 — the hour whose outage/production record is now complete.

### 2.4 The deterministic phase order (the critical section)

Every step — fine or coarse — executes exactly these phases, in this order, with no exceptions and no reordering at runtime. Phase assignment is compile-time data on each system; the scheduler sorts by `(phase, system_id, registration order)` where `system_id` is a stable string, so ties are broken deterministically and alphabetically rather than by registration accident.

> **The third term is new (Wave 15, report 98 RR-77) and it exists because the second one is not always a tie-break.** `sort_custom` is an introsort and is **not stable**, so two systems sharing a phase AND an id had no defined order at all: which of them ran last depended on the length and content of the array they happened to be sorted in. Nothing shipped registers a duplicate id — `CitySim` registers thirteen distinct ones — but a *test rig* legitimately does, to override a sim system with a wired one (`tests/test_weather_integration.gd` registers a second `&"weather"`, and both write the shared `ModifierStack`, so the last one decides what the grid draws). Adding one unrelated system elsewhere in the registry flipped that sort, and the failure surfaced as *"a heat wave stopped moving power demand"* three files from the change. Registration order is the honest tie-break — **an override registered later wins**, which is what a caller registering a duplicate already means — and it can move no *correct* behaviour, because the order it now defines was previously undefined. For a registry with unique ids, which every shipped sim has, it changes nothing: all four determinism baselines are byte-identical across the change.

| # | Phase | Owner(s) | Cadence | Why it sits here |
|---|---|---|---|---|
| P00 | `CLOCK` | GameClock, TimeContext builder | every step | Builds the single frozen `TimeContext`. Everything downstream reads one identical time value; no system ever samples time twice in a step. |
| P01 | `COMMANDS` | CommandQueue drain (from `ui/`) | every step (fine only) | Player intent lands at exactly one point — the top of a tick, before any simulation. A dispatch issued "during" a tick can never half-apply. |
| P02 | `TIMERS` | TimerService | every step | Deadlines mature into per-owner inboxes *before* their owners run, so an owner sees its due timers in its own phase this step, not next step. |
| P03 | `EVENTS` | ScheduledEventService | every step | Opens/closes event and hazard phase windows so their modifiers are live for demand, traffic and incident rolls in the same step. |
| P04 | `WEATHER` | Weather (07) | every step | Weather is a pure upstream driver: load, failure probability, travel speed, construction rate all consume it, and it consumes none of them within a step. |
| P05 | `DEMAND` | Building demand aggregation (02) | every step | Pure function of building state × TimeContext curves × weather × event modifiers. Must precede both utility solves. |
| P06 | `POWER` | Power grid solve (04) | every step | Producers before consumers. Sets node power state, load, temperature, and rolls its own failures. |
| P07 | `WATER` | Water solve (05) | every step | **After power in the same step**, so a pump that loses its feeder in P06 loses pressure in P07 with zero lag. This is the game's signature cascade and must not be a frame behind. |
| P08 | `ROADS` | Traffic & congestion (10) | every step | Traffic signals depend on this step's power state; flooded/closed segments depend on this step's weather and water. |
| P09 | `VEHICLES` | Dispatch & movement (06) | every step | Moves units using the congestion computed at P08 this step, not last step's. |
| P10 | `WORK` | WorkService + construction projects (02) + crews as dispatchable units (06) | every step | Advances all work accumulators (construction, repair, suppression) using this step's efficiency modifiers and this step's road access. |
| P11 | `INCIDENTS` | Incident spawn / escalate / resolve (06) | every minute | Runs *after* vehicles so a unit that arrived at P09 counts as on-scene immediately; runs after P10 so suppression work already applied counts toward resolution. |
| P12 | `CASCADE` | Dependency propagation (06) | every step | One bounded pass, after every failure producer (P06, P07, P08, P11) has run. |
| P13 | `DISTRICTS` | District aggregation & stability (09) | every minute | Consumes everything the step produced. Its output is deliberately consumed by the **next** step (see lag rule below). |
| P14 | `ECONOMY` | Taxes, upkeep, treasury (03) | every hour | Settles a completed hour of production, outage and service cost. |
| P15 | `POPULATION` | Growth / decline (09) | every day | Slowest layer; consumes a full day of stability and reliability history. |
| P16 | `DIRECTOR` | Disaster Director (07) | every hour | Runs last among simulating phases because it **only ever schedules future timers and hazard events — it never mutates the world in the step it runs.** That makes every disaster traceable to a scheduling decision the player could have been warned about (spec §20.2). |
| P17 | `REPORT` | Event bus flush, notification policy (08), render snapshot | every step | Observes a fully settled world. The renderer and UI can never see a half-updated step. |

**The three deliberate lags** (each is a design choice, not an accident, and each is exactly one step):

- **L1 — Stability → crime.** District stability (P13, doc 09) feeds the *next* step's incident rolls (P11, doc 06). This breaks the crime↔stability circularity. Cost: a blackout raises crime 15 game-seconds after stability drops. Invisible to the player, essential for determinism.
- **L2 — Cascade hop rate.** A cascade pass (P12) may enqueue new failures; those are applied at P06/P07 of the **next** step, never recursively within a step. Cascades therefore propagate at **one hop per SimTick = 15 game-seconds = 0.25 real seconds @1x**. This is also a UX win: a five-hop cascade takes 1.25 real seconds to unfold on screen, which is readable rather than instantaneous. Unbounded recursion is impossible by construction.
- **L3 — Director → world.** The Director (P16) writes only timers and scheduled events; the earliest a Director decision can touch the world is the next step's P02/P03.

**Ordering rationale summary.** The order is *physical → mobile → social → fiscal → demographic → meta → reporting*. Every arrow in the spec §34 dependency example (feeder → pump → hydrant → fire effectiveness) is a forward arrow in this list, so the whole chain resolves within one tick with no lag at all.

### 2.5 Fine and coarse advance

```
ISimSystem:
    system_id()   -> StringName          # stable, sorts ties
    phase()       -> int                 # P00..P17
    cadence()     -> Cadence
    advance_fine(ctx: TimeContext)       # dt = 15 game-seconds
    advance_coarse(ctx: TimeContext)     # dt = 3600 game-seconds
```

Both entry points are mandatory. The scheduler drives *the same registry, in the same phase order*, in both modes.

**Coarse contract.** `advance_coarse` for one game-hour must:

1. Produce the same *expected* aggregate state delta as 240 `advance_fine` calls over the same hour, within **±5 %** on every scalar it mutates (verified statistically — §7, T-12).
2. Consume a **bounded, fixed** number of draws from its own named RNG stream (constitution §5) — no `while` loops over 240 iterations of Bernoulli trials. Convert per-tick probability `p` over `n = 240` trials to a single draw: expected count `λ = 240p`, sampled as `floor(λ) + (1 if rand() < frac(λ) else 0)` for `λ < 4`, or a normal approximation `round(λ + sqrt(λ·(1-p))·gauss())` clamped to `[0, 240]` for `λ ≥ 4`. This rule is published here so every doc uses the same conversion.
3. Be a no-op where the concept does not exist at hour granularity: **vehicle interpolation, render snapshots and notification toasts do nothing in coarse mode.** Vehicle *travel* does not — dispatch resolves analytically over the hour (doc 06 owns that formula).
4. Never emit render events. `ctx.mode == COARSE` gates all `P17` emission except the offline event-history ring buffer (constitution §9).

For `EVERY_HOUR` and `EVERY_DAY` systems, `advance_coarse` is *literally the same function body* as `advance_fine` — one hour of coarse time contains exactly one hourly invocation, so economy, population and Director are bit-identical between online and offline play. Only the four sub-hour layers (utilities, traffic, vehicles, incidents) need an integrated coarse variant, and their docs must specify it.

### 2.6 Day/night curves and modifier channels

Time-of-day effects are expressed as **curves**: piecewise-linear keyframe tables over hour-of-day, wrapping at 24.

**Hard rules on curve authoring:**

- **All keyframes must sit on whole game-hours.** Validated at load. This makes every curve linear across any single hour.
- **Sampling is always at the midpoint of the step.** Fine tick `t` samples at `hour_of_day(t) + (minute_of_hour + 0.125) / 60`; coarse hour `h` samples at `h + 0.5`.
- Because the curve is linear within an hour and the 240 fine midpoints are symmetric about `h + 0.5`, **the mean of the 240 fine samples equals the single coarse sample exactly.** Curve-driven deterministic quantities (demand shape, construction efficiency, commercial output) are therefore *exactly* fine/coarse-equivalent, not merely approximately. This is the single most important reason the midpoint rule exists.
- Curves are one of two kinds, declared in data:
  - `normalized` — 24-hour mean **must be 1.000 ± 0.02** (validated at load, test T-08). Other docs author their base rates as daily averages and multiply.
  - `absolute` — a 0..1 duty factor or efficiency; no normalization requirement.

**Sampling formula.** For keyframes `(h₀,v₀) … (hₙ,vₙ)` with implicit wrap `hₙ₊₁ = h₀ + 24`:

```
sample(c, x):  find i with h_i <= x < h_{i+1}
               u = (x - h_i) / (h_{i+1} - h_i)
               return v_i + u * (v_{i+1} - v_i)
```

**Worked example.** `traffic_density` keyframes include `(7, 1.71)` and `(8, 2.08)`. At 07:30, `u = 0.5`, value `= 1.71 + 0.5 × 0.37 = 1.895`. The coarse sample for hour 7 is `sample(c, 7.5) = 1.895` — identical, as guaranteed.

**Day phases** (derived from `minute_of_day`, used for lighting state, audio beds and UI labelling; they carry no arithmetic of their own):

| Phase | Window | Character |
|---|---|---|
| `NIGHT` | 22:00 – 05:00 | streetlights at full, crime peak, minimum traffic |
| `DAWN` | 05:00 – 07:00 | daylight ramp, streetlights fading |
| `MORNING_RUSH` | 07:00 – 09:30 | traffic peak, residential→commercial load shift |
| `MIDDAY` | 09:30 – 16:30 | commercial peak, construction full rate |
| `EVENING_RUSH` | 16:30 – 19:00 | traffic second peak, residential load climbing |
| `EVENING` | 19:00 – 22:00 | residential + streetlight load peak, crime rising |

**Modifier channels.** A channel is a named float that other systems read from `ctx.channels`. Each channel = its day-curve value × every active multiplier from weather, scheduled events, district state and policies, then clamped.

```
value(channel) = curve(channel) * Π_{s ∈ sources} s.multiplier      then clamp(min, max)
```

Sources are multiplied in a fixed order — sorted by `(source_kind_rank, source_id)` with ranks `weather=0, scheduled_event=1, district=2, policy=3, debug=4` — so floating-point multiplication order is deterministic.

**`data/time.json` is the only diurnal curve store in the project** (report 98 C-32, C-33). Doc 04's `demand.tod_curves` and doc 05's `residential_hourly` / `commercial_hourly` are deleted in their own docs; consumers read `ctx.channels.*` instead. **Fifteen channels:**

| Channel | Curve kind | Clamp | Primary consumer |
|---|---|---|---|
| `power_demand_residential` | normalized | 0.20 – 3.00 | 04 |
| `power_demand_commercial` | normalized | 0.20 – 3.00 | 04 |
| `power_demand_industrial` | normalized | 0.20 – 3.00 | 04 |
| `power_demand_civic` | normalized | 0.20 – 3.00 | 04 |
| `power_demand_datacenter` | normalized (flat 1.0 curve) | 0.20 – 3.00 | 04 |
| `streetlight_load` | absolute | 0.00 – 1.00 | 04 |
| `water_demand_residential` | normalized | 0.20 – 3.00 | 05 |
| `water_demand_commercial` | normalized | 0.20 – 3.00 | 05 |
| `traffic_density` | normalized | 0.05 – 4.00 | 10 |
| `crime_rate` | normalized | 0.00 – 5.00 | 06 |
| `commercial_output` | normalized | 0.00 – 2.50 | 03 |
| `construction_rate` | absolute | 0.00 – 2.00 | 02 |
| `response_speed` | absolute (base 1.0) | 0.25 – 1.50 | 06 |
| `incident_rate` | normalized (flat 1.0 curve) | 0.00 – 6.00 | 06 |
| `daylight` | absolute | 0.00 – 1.00 | `game/` lighting only |

**Derivation of the three channels added by report 98 C-32/C-33.** Each was normalized here, on the piecewise-linear keyframe curve, using the trapezoid mean `mean = (1/24)·Σ_segments w·(v_i + v_{i+1})/2` with the wrap segment `h_last → h_first + 24` included:

- **`power_demand_civic`** — shape taken from doc 04's 24-entry `CIV` `tod_curve`, which sums to `23.02` (raw mean `23.02 / 24 = 0.959`) and is therefore **not** normalized. Reduced to eight whole-hour keyframes `(0,0.80) (3,0.78) (5,0.85) (7,1.05) (8,1.10) (16,1.05) (19,0.95) (23,0.82)`, whose trapezoid area is `2.37 + 1.63 + 1.90 + 1.075 + 8.60 + 3.00 + 3.54 + 0.81 = 22.925`, mean `22.925 / 24 = 0.9552`. Scaling factor `1 / 0.9552 = 1.04689`; every keyframe multiplied and rounded to 2 dp gives the shipped curve, whose area re-checks to exactly **24.000 → mean 1.000**.
- **`power_demand_datacenter`** — flat `1.00`, single keyframe. Doc 04's `DC` curve is already flat ("data centres do not sleep"); mean **1.000** by construction. It exists as a channel rather than as a hard-coded 1.0 so weather, scheduled events and policies can push a datacenter multiplier through the same modifier stack as every other class.
- **`water_demand_commercial`** — shape taken from doc 05's `commercial_hourly`, which already sums to exactly `24.00` (raw mean 1.000). Reduced to twelve whole-hour keyframes; trapezoid area `0.675 + 0.60 + 1.45 + 2.70 + 3.55 + 3.55 + 1.675 + 3.15 + 3.675 + 1.65 + 1.00 + 0.30 = 23.975`, mean `23.975 / 24 = ` **0.999** — inside the ±0.02 normalization gate, so no rescale is applied and the shape stays doc 05's.

`water_demand` is **renamed `water_demand_residential`** (C-33). Its keyframes are unchanged: area `2.375 + 2.05 + 2.65 + 3.375 + 2.15 + 4.70 + 3.975 + 2.05 + 0.60 = 23.925`, mean `23.925 / 24 = ` **0.997**, as before.

The shipped keyframes are in §8. All computed 24-hour means, for reference: residential power 0.999, commercial power 1.001, industrial power 1.000, **civic power 1.000**, **datacenter power 1.000**, **residential water 0.997**, **commercial water 0.999**, traffic 0.999, crime 1.001, commercial output 1.001. `construction_rate` is absolute with a 24-hour mean of **0.804** — doc 02 must author project durations knowing that a 10-game-hour project started at a random hour occupies ≈ 12.4 wall game-hours.

**Weekend.** `day_type` exists in `TimeContext` and the curve lookup supports a `weekend` override table per channel. **MVP ships weekday curves only**; the override tables are empty and the mechanism is exercised by a test.

### 2.7 Timers vs. work units

Two distinct kinds of time-based progression. Conflating them is the classic bug source, so they are separate services.

**(a) Deadline timers** — an absolute `due_tick`, immune to rate modifiers. Used for: hazard warning phases, scheduled event phases, Director cooldowns, policy windows, notification pre-scheduling, incident escalation deadlines that are meant to be wall-clock ("the riot spreads in 20 minutes regardless"). Stored in a binary min-heap keyed by `(due_tick, timer_id)`; `timer_id` breaks ties deterministically. Cost per step is `O(k log n)` for `k` due timers.

**(b) Work units** — progress that accrues at a *variable* rate. Used for: construction, land development, utility repair, fire suppression, debris clearance. A work unit has no due date; it has `work_required_mu` and `work_done_mu` in milli-units, and advances by rate × dt × efficiency each step. Anything whose speed can be changed by weather, night, crew count or road access **must** be a work unit, never a timer.

**Exact integer work accumulation** (no float drift, exact save round-trip):

```
num          = rate_mu_per_hour * dt_game_seconds * eff_permille   # int64
work_done_mu += num / 3_600_000
carry_mu     += num % 3_600_000
if carry_mu >= 3_600_000:  work_done_mu += 1;  carry_mu -= 3_600_000
complete when work_done_mu >= work_required_mu
```

`eff_permille = round(construction_rate_channel * 1000)`, evaluated once per step from the frozen context.

**Worked example — an overnight high-rise stage.** A structural-frame stage is authored as `work_required_mu = 8_000_000` (8 "crew-hours" at 1 000 000 mu each). One general crew supplies `rate_mu_per_hour = 1_000_000`. Work starts at 20:00.

- 20:00–21:00: `construction_rate` samples at 20.5 → between keyframes `(19, 0.75)` and `(21, 0.60)`, `u = 0.75` → `0.6375`; `eff_permille = 638`. One hour contributes `1_000_000 × 3600 × 638 / 3_600_000 = 638_000` mu.
- 21:00–06:00 (nine hours at the flat 0.60 floor): `9 × 600_000 = 5_400_000` mu. Running total `6_038_000`.
- 06:00–07:00: sample at 6.5 → between `(6, 0.60)` and `(7, 1.00)` → `0.80` → `800_000`. Total `6_838_000`.
- 07:00 onward at full rate: needs `1_162_000` more → `1.162` hours → completes at **08:09:43** game time.

Total elapsed: 12 h 10 m of wall game-time for 8 crew-hours of work. A fine run of the same interval produces the identical figure to the milli-unit, because every hour's midpoint sample equals its fine mean exactly (§2.6).

**Coarse-mode work.** Identical code, `dt_game_seconds = 3600`, efficiency from the hour-midpoint sample. Bit-identical to the fine path when no modifier changes mid-hour; within rounding otherwise.

### 2.8 Scheduled events (stadium, hazards, anything with phases)

One framework serves stadium events, hazard warning timelines, seasonal festivals and Director-authored disasters. An event instance is a template plus an anchor tick; each phase becomes a deadline timer.

Phase offsets are in **game-minutes relative to the anchor** and may be negative (that is what makes forecasting work — spec §20.3). Each phase carries modifier deltas that are pushed onto the channel stack while the phase is open, plus an optional notification class (doc 08 owns notification policy).

**Weather templates carry no effect multipliers (report 98 C-27).** The shipped `thunderstorm_hazard` template keeps its five phases, their offsets and their notification classes, and **its `modifiers` blocks are empty**. Every storm effect multiplier — traffic, response speed, construction speed, incident rate — is published by **doc 07** as a `weather`-kind source on the same channels (`modifier_source_rank.weather = 0`), so the storm is applied exactly once. The ScheduledEvent framework remains the carrier for the *warning timeline* (watch → warning → impact → clearing → end); it is no longer a second place storm effects are authored. Non-weather templates (stadium, festivals) keep their modifiers, because nothing else publishes them.

**Worked example — `stadium_match_major`, anchored Saturday 19:00 (tick 918 442 is Saturday 16:50, so the anchor is tick 918 962).**

| Phase | Offset | Absolute | Tick | Effects while open |
|---|---|---|---|---|
| `announce` | −2880 min (2 days) | Thu 19:00 | 907 442 | notification: routine; no modifiers |
| `inbound` | −120 min | Sat 17:00 | 918 482 | `traffic_density ×1.9` within 600 m of venue; `incident_rate ×1.4` |
| `live` | 0 | Sat 19:00 | 918 962 | venue `power_demand_commercial ×2.6`; `traffic_density ×0.7`; `incident_rate ×2.2`; police demand +4 units (doc 06) |
| `outbound` | +150 min | Sat 21:30 | 919 562 | `traffic_density ×2.4`; `incident_rate ×1.8` |
| `end` | +270 min | Sat 23:30 | 920 282 | all modifiers popped |

`inbound` opens at tick 918 482 = anchor − 480 ticks (120 min × 4). At that moment a driver in a district that also has a thunderstorm active sees the stadium's `×1.9` (a `scheduled_event` source) stacked with the storm's traffic multiplier (a `weather` source published by **doc 07** — the illustrative value `×1.35` is doc 07's number, not this doc's, per C-27): `1.87 (curve at 17:00) × 1.9 × 1.35 = 4.80`, clamped to the channel maximum **4.00**. The clamp is what stops modifier stacking from producing nonsense during a disaster-plus-event pileup, and it is the reason removing the duplicate storm modifiers from the template changes the *inputs* to this example but not its shape.

**Anchoring rule.** Venues request events through `ScheduledEventService.schedule(template_id, anchor_tick, params)`. Anchor selection (which Saturday, which hour) belongs to doc 02 for venue events and doc 07 for hazards; this doc guarantees only that a scheduled anchor fires on exactly the tick requested, survives save/load, and survives coarse catch-up (a phase whose `due_tick` falls inside a coarse hour fires at the *start* of that coarse step, and is reported with its true `due_tick` in the event history).

### 2.9 Pause and speed

- `speed ∈ {1, 2, 3}`, `paused : bool`. Speed 3 is the MVP ceiling; a premium 5x is explicitly out of scope (spec §37 — do not sell simulation advantage).
- **Speed changes the rate of tick delivery and nothing else.** No system may read `ctx.speed` for arithmetic; it is present only for the renderer's interpolation. Test T-06 enforces this by running an identical 4 000-tick script at each speed and asserting identical state hashes.
- Accumulator, evaluated once per rendered frame in `game/`:

```
if not paused:
    residual_game_ms += round(frame_delta_real_ms * 60 * speed)
    n = residual_game_ms / 15000
    residual_game_ms %= 15000
    n = min(n, MAX_TICKS_PER_FRAME)          # 8
    scheduler.advance_fine_n(n)
```

  At 60 fps @3x that is `16.7 × 180 = 3006` game-ms per frame → a tick every ~5 frames. `MAX_TICKS_PER_FRAME = 8` gives 32× headroom for a hitch.
- **Backlog spill.** If `residual_game_ms` ever exceeds `BACKLOG_SPILL_TICKS × 15000` (240 ticks = one game-hour — reachable only via a device stall or an OS freeze that did not trigger a lifecycle callback), the surplus is converted to whole coarse hours and run through the offline path, then the remainder resumes fine. This unifies "device hiccup" with "player was away" instead of adding a third code path. Every spill is logged to the event ring as `time.spill`.
- **Pause semantics.** Paused: the clock is frozen, no phases run, commands queue and drain at P01 of the first resumed tick, rendering and camera stay live. Pause is **foreground-only**: backgrounding stamps `last_advance_wall_ms` regardless of pause state, and the return credits elapsed time normally. Core Rule 2 ("the city continues while the player is away") outranks the pause button. The pause UI states this once, on first use.
- **Grace window.** `OFFLINE_GRACE_SECONDS = 120`. Real elapsed under 120 s while backgrounded is credited as **zero**, so checking a notification or taking a call does not cost the player two game-hours. Above the grace window, the full elapsed time is credited (not elapsed-minus-grace).
- **Auto-speed.** Setting `auto_speed_reset_on_critical` (default **on**): a P1 notification (class owned by doc 08) forces `speed = 1` and raises a toast. It never force-pauses — pausing the player mid-crisis is worse than the crisis.
  > **As built (Wave 18, PA-84): not *a P1 notification* — three of them.** This
  > clause said "a P1" and had no caller for seventeen waves, because *every* P1
  > is far too many: measured on the curriculum path, the matching stream is
  > 78–271 events over 21 game-days, which is up to **32.3 forced resets per real
  > hour**. The shipped trigger set is `data/ui.json.speed.auto_speed_reset_triggers`
  > — `incident_failed`, `credit_limit_reached`, and `flood_level_changed` at band
  > `flooded` — plus a **thirty**-real-minute re-arm (PA-84 suggested ten; ten
  > misses PA-84's own ≤ 1-per-real-hour bar on one of eleven seeds), which brings
  > the worst of eleven to **0.714 per real hour**. Doc 12 §2.11 carries the sweep;
  > `tools/measure_speed_resets.gd` re-runs it. The toast is not raised separately:
  > the same event is already on its way to the alert surface.

### 2.10 Offline catch-up: the schedule planner

At resume, the app shell measures real elapsed milliseconds once and hands it to the sim (constitution §4). `CatchUpPlanner` converts it into a **deterministic advance schedule** — the same input always yields the same schedule, which is what makes constitution §5 ("same save + same elapsed time ⇒ same offline outcome") literally true even though fine and coarse steps are not identical.

```
elapsed_real_ms  -> credited_real_ms = 0                                if elapsed_real_ms < 120_000
                    min(elapsed_real_ms, OFFLINE_CAP_REAL_MS)           otherwise
game_ms          = credited_real_ms * 60 + residual_game_ms
total_ticks      = game_ms / 15000        ; residual_game_ms = game_ms % 15000
```

`OFFLINE_CAP_REAL_MS = 43 200 000` (**12 real hours = 720 game-hours = 30 game-days**), ruled by report 98 C-19. Derivation: `12 × 3 600 × 1 000 = 43 200 000 ms`; at the locked 60× scale `12 × 60 = 720` game-hours; `720 / 24 = 30` game-days; `720 × 240 = 172 800` ticks.

**This doc owns the constant, in `data/time.json`.** Docs 08 and 13 read it and define none of their own — doc 13's former `offline_max_hours = 72` is deleted there, and doc 08's `M(H)` band arithmetic re-derives against 720 (`M(720) = 1.00 × 72 + 0.60 × 648 = 460.8`, i.e. `460.8 / 720 = ×0.64`, doc 08's recomputation R-15).

Why 12 and not 8: 8 real hours does not cover a full night plus a commute, which is the stated failure mode of a check-in game. Why not 72: three days would hand back six months of city per absence and break doc 03's offline/online income guardrail G4, doc 07's fairness budget and doc 08's damage-cap arithmetic simultaneously.

Time beyond the cap is discarded, not banked; the WHILE YOU WERE AWAY report states plainly: *"You were away 26 h. Your city ran for 30 days (12 h of catch-up, the maximum)."* No debt, no compounding.

**Decomposition** (deterministic, in this order):

1. If `total_ticks ≤ FINE_CATCHUP_MAX_TICKS` (20 ticks = 5 game-minutes): run all of them fine. Done.
2. Otherwise reserve the tail: `tail = min(FINE_TAIL_TICKS, total_ticks)` where `FINE_TAIL_TICKS = 40` (10 game-minutes). The last 10 game-minutes before the player sees the city are **always fine**, so vehicles are mid-route, incidents are mid-escalation and the world is micro-coherent on arrival rather than snapping out of an hour-averaged blur.
3. `head_align`: fine-advance `(240 − (tick_index mod 240)) mod 240` ticks to reach the next game-hour boundary.
4. `coarse_hours = (total_ticks − tail − head_align) / 240`, run through `advance_coarse`.
5. `mid_fine = remaining ticks after the coarse hours`, run fine.
6. `tail` ticks fine.

**Worked example A — player away 6 h 12 m, returning at tick 918 442.**
`credited = 22 320 000 ms` (under the 12 h cap of 43 200 000 ms) → `game_ms = 1 339 200 000` → `total_ticks = 89 280` (= 372 game-hours = 15.5 game-days).
`tail = 40`. `tick_index mod 240 = 918 442 mod 240 = 202` → `head_align = 240 − 202 = 38`.
`89 280 − 40 − 38 = 89 202`; `coarse_hours = 89 202 / 240 = 371`; consumed `371 × 240 = 89 040`; `mid_fine = 89 202 − 89 040 = 162`.
Schedule: **38 fine → 371 coarse → 162 fine → 40 fine**. Total 38 + 89 040 + 162 + 40 = 89 280 ✓.

**Worked example B — the capped case, recomputed at the C-19 cap.** Player away 26 h, returning at tick 918 442 with `residual_game_ms = 0`.
`credited = min(93 600 000, 43 200 000) = 43 200 000 ms`, `capped = true` → `game_ms = 2 592 000 000` → `total_ticks = 172 800` (= 720 game-hours = 30 game-days; under the retired 8 h cap this was 115 200 ticks = 20 game-days).
`tail = 40`; `head_align = 38` as above.
`172 800 − 40 − 38 = 172 722`; `coarse_hours = 172 722 / 240 = 719` (integer division); consumed `719 × 240 = 172 560`; `mid_fine = 172 722 − 172 560 = 162`.
Schedule: **38 fine → 719 coarse → 162 fine → 40 fine**. Total 38 + 172 560 + 162 + 40 = 172 800 ✓.
So the worst case this doc must plan for is **719 coarse steps**, not 371 and not the 479 of the retired cap.

**Cost budget — settled by measurement, not by argument (report 98 C-21).** This doc previously budgeted **0.6 ms per coarse step**; doc 08's independent per-entity accounting gave **≈ 27 ms** on the 800-building reference city — a 45× disagreement that no amount of reasoning resolves. **That 0.6 ms line is retired.** In its place, doc 08's decision rule is normative and doc 08 owns the resulting tunable:

1. Phase 0 task **P0-27** builds `tests/perf/test_coarse_step_cost.gd`.
2. It measures one FULL-band coarse hour on the reference city, on the reference device, and reports `measured_ms`.
3. `max_coarse_hours = clamp( floor_to_multiple_of_24( ceil(2000 / measured_ms) ), 72, 720 )` — the 2 000 ms numerator is doc 08's catch-up work budget, the floor of 72 keeps three game-days of absence always creditable, and the ceiling of **720** is the C-19 cap above.
4. **`max_coarse_hours` lives in doc 08's tunables, not in `data/time.json`.** This doc supplies `OFFLINE_CAP_REAL_MS` (the 720-hour outer bound) and the coarse entry point; doc 08 supplies the measured cap and reports discarded hours exactly as it already reports over-cap hours.

Worked out across the plausible measurement range, so the shape of the rule is visible before P0-27 runs:

| `measured_ms` | `ceil(2000 / m)` | floor to ×24 | clamp [72, 720] → `max_coarse_hours` |
|---|---|---|---|
| 0.6 (this doc's retired claim) | 3 334 | 3 312 | **720** (full cap) |
| 2.0 | 1 000 | 984 | **720** (full cap) |
| 2.77 | 723 | 720 | **720** (the break-even point) |
| 4.0 (doc 08's pass threshold) | 500 | 480 | **480** |
| 12.0 | 167 | 144 | **144** |
| 27.0 (doc 08's accounting) | 75 | 72 | **72** (floor) |
| 50.0 | 40 | 24 | **72** (floor binds) |

The full 720-hour cap is therefore reachable only at `measured_ms ≤ 2.77`; anything at or above doc 08's 4 ms threshold caps catch-up below the C-19 bound and the surplus is discarded and reported.

> **Measured 2026-08-20 (Wave 9) — the cap does not move, and the stress fixture does.** Doc 06 §2.10's dispatch now prices every ETA through doc 10's router (report 98 RR-26), which more than doubles the incident phase of a coarse step and takes **66 % more integrator sub-steps**, because street-true arrival times are all distinct where the Chebyshev stand-in's collided on a grid. Interleaved A/B, same session, `git stash` for the before arm:
>
> | | **reference city** (starter, 34 buildings) | benchmark city (1,500) |
> |---|---|---|
> | coarse step | 6.353 → **6.690 ms** (+5.3 %, inside session noise) | 126.41 → **189.96 ms** |
> | 12 h catch-up | 0.076 → **0.080 s** | 1.517 → **2.280 s** |
> | sub-steps / coarse hour | 1.25 → **1.25** | 8.75 → **14.54** |
>
> **`max_coarse_hours` sits on a knife-edge, and this wave measured both sides of it in one session.** `tests/test_milestone1.gd` derives the cap from its own reading of the starter city's coarse step, and this branch was measured twice: **6.42 ms → 288** on a loaded run and **6.07 ms → 312** on the full-suite run twenty minutes later. Wave 8 measured 6.21 → 312. **The boundary is at exactly `measured_ms = 6.410`** (`floor(2000 / m / 24) × 24` steps there), so a 5.5 % spread in the measurement straddles it — and a workstation carrying three other agents' test suites has more than that in it. The honest statement is *the cap sits on the 312/288 boundary and the rule reports whichever side the device lands on*, not *the cap moved*. Nothing breaks either way: the test asserts only the C-21 floor of 72, doc 08 owns the constant, and 288 game-hours is still twelve game-days of creditable absence.
>
> What *is* unambiguously out of budget is the **benchmark** figure: 2.28 s against the 2 s target on a 1,500-building stress fixture, 14 % over, filed in audit 91's narrowed D-15 with the cheapest lever named (quantising arrival times onto the SimTick grid — they are already whole game-seconds, and 15 would collapse most of the extra breakpoints). It is doc 06's fidelity call, not doc 01's budget to relax.

The fine ticks in worked example B (38 + 162 + 40 = **240** ticks) cost `240 × 1.2 ms = 288 ms` at the §2.12 fine-tick average — a real and non-trivial share of the catch-up budget, and larger than the whole coarse body was assumed to be under the retired 0.6 ms line.

**Catch-up runs on the main thread, sliced (report 98 C-22).** There is no `WorkerThreadPool` branch: sim state is single-owner `RefCounted` (constitution §3), and threading it to save a load screen is an unforced determinism and lifecycle risk on a platform that can kill the process mid-task. The scheduler therefore exposes `advance_coarse_sliced(max_ms) -> bool` (§4), which the app shell pumps behind an animated veil until it returns `true`, emitting `time.catchup_progress` from `steps_done()` / `steps_total()`. Doc 13 owns the per-frame slice budget (12 ms) and the veil; doc 08 owns the progress-event contract.

> **As built (Wave 14) — same ruling, one layer out: `CitySim.begin_catchup(plan) -> CatchUpCursor` (`sim/time/catchup_cursor.gd`).** C-22's decision is unchanged and so is the 12 ms budget; two details of the signature above could not survive the planner this section itself specifies. **`advance_coarse_sliced(max_ms)` cannot advance a real resume**, because a plan is not coarse hours alone — worked example B above is `38 fine → 719 coarse → 162 fine → 40 fine`, and three of its four segments are fine. And **`max_ms` cannot be a sim-side argument at all**: `sim/` may not read a clock (constitution §5), so nothing in here can tell whether `max_ms` has elapsed. The cursor therefore spends **one whole unit** — one coarse hour or one fine tick — and the SHELL loops on `Time.get_ticks_usec()` until its 12 ms is gone. `steps_done()` / `steps_total()` are on the cursor, as is `done_ticks()` / `total_ticks()`, which is what doc 12 §2.20's bar actually reads because it is proportional to game time.
>
> **The slicing changes nothing about the city and the seam that guarantees it is this section's own `ctx.catchup_index`.** It indexes the SEGMENT, not the slice, so the cursor issues `advance_coarse_n(1, true, hours_done_in_segment, segment_hours)` where a monolithic call issued `advance_coarse_n(n, true, 0, n)` once — byte-identical `TimeContext`s. `tests/test_catchup_cursor.gd` proves it on both cities at four slice sizes, on `state_hash()` and on the drained event bus. Report 98 §29 RR-73.

**Catch-up context.** Coarse steps carry `ctx.is_catchup = true`, `ctx.catchup_index`, `ctx.catchup_total`. Doc 06 is expected to run auto-response policies (spec §21.3) rather than leaving units idle.

**Offline Director allowance — deferred to doc 08 (report 98 C-55).** This doc previously *recommended* a hard limit of 1 Director-scheduled major hazard per catch-up session. That recommendation is withdrawn and replaced by a reference: **doc 08 §2.3 rule 1 is the outer clamp**, and it is strictly tighter — at most one hazard per catch-up session, which must be **Tier 1**, must have had a **forecast warning already active before the player backgrounded the app**, may fire **only in the FULL band**, and is **zero on `casual`**. Tier-2 and Tier-3 events never spawn offline. Doc 07's F8 is tightened to match verbatim. This doc defines no cap of its own and ships no tunable for one; it supplies only `ctx.is_catchup`, `ctx.catchup_index` and `ctx.catchup_total`, which doc 08's `OfflineGuard` and doc 07's Director read.

### 2.11 Notification pre-scheduling

Because the sim does not run in the background, notifications about *future* deterministic moments must be registered with Android before the app leaves the foreground. Any deadline timer flagged `notify_offline` converts cleanly, since offline scale is a constant 250 real-ms per tick:

```
real_ms_per_tick     = 15 (game-sec) / 60 (scale) * 1000 = 250
alarm_wall_ms        = background_wall_ms + (due_tick - current_tick) * 250
```

Capped at `background_wall_ms + OFFLINE_CAP_REAL_MS` — now **43 200 000 ms** (12 real hours) per C-19, so a deterministic timer up to 720 game-hours out can be pre-registered. On resume, all pre-registered alarms are cancelled and re-derived. Doc 08 owns notification classes, priority and rate limiting; doc 13 owns the Android channel and `AlarmManager` mechanics and the copy. This doc owns only the tick→wall conversion and the guarantee that the sim, when it actually runs the catch-up, fires the same timer at the same `due_tick` the alarm predicted.

**Worked example.** Construction completing at tick 919 700, backgrounded at tick 918 442, wall time 1 755 600 000 000. `(919 700 − 918 442) × 250 = 314 500 ms` → alarm at wall 1 755 600 314 500, i.e. 5 min 14 s later in the real world. That is what "5 real minutes" means for a 5-game-hour job at 60×.

### 2.12 Performance budget

| Step kind | Target avg | Target p99 | Notes |
|---|---|---|---|
| Fine tick (typical) | 1.2 ms | 3.0 ms | 12 ticks/real-sec at 3x → ≤ 3.6 % CPU |
| Fine tick on an hour boundary | 3.0 ms | 8.0 ms | adds P14 economy |
| Fine tick on a day boundary | 6.0 ms | 14.0 ms | adds P15 population; once per 24 real min @1x |

**There is deliberately no coarse-step row.** The former `0.6 ms avg / 1.5 ms p99` coarse budget is **retired** by report 98 C-21 — it was an estimate 45× below doc 08's per-entity accounting, and a budget nobody can adjudicate is worse than no budget. The coarse step is governed by *measurement* instead: `tests/perf/test_coarse_step_cost.gd` (Phase 0, P0-27) reports `measured_ms`, and **doc 08** derives and owns `max_coarse_hours` from it by the rule in §2.10. The retired `budget.coarse_step_avg_ms` and `budget.catchup_total_warn_ms` constants are removed from `data/time.json`; the catch-up work budget (2 000 ms target, 2 500 ms test gate) lives in doc 08.

If a day-boundary tick is measured above **8 ms** on the reference device, `EVERY_DAY` systems may declare `sliceable = true` and receive `ctx.slice_index / ctx.slice_count`, spreading their per-building work across the 240 ticks of the day's first hour (`slice_count = 1` in coarse mode). The mechanism is specified now and **off in MVP** — it is a measured-need escape hatch, not a default.

---

## 3. Data Schema

### 3.1 `data/time.json`

Full contents in §8. Top-level keys: `clock`, `speeds`, `catchup`, `phases`, `day_phases`, `curves`, `channels`, `event_templates`, `timer_kinds`, `budget`.

Validated at load (test T-08): every `normalized` curve has 24-hour mean within 1.000 ± 0.02; every keyframe hour is an integer in [0, 23]; keyframes strictly ascending; every channel names an existing curve; every clamp has `min ≤ max`.

### 3.2 Save section — `"time"`

```json
{
  "time": {
    "section_version": 1,
    "tick_index": 918442,
    "residual_game_ms": 4200,
    "founding_wall_ms": 1755500000000,
    "last_advance_wall_ms": 1755600000000,
    "speed": 2,
    "paused": false,
    "next_timer_id": 1043,
    "next_event_id": 78,
    "next_work_id": 5120,
    "timers": [
      {
        "id": 1042, "kind": "scheduled_event_phase", "owner": "events",
        "due_tick": 918962, "period_ticks": 0, "repeats_left": 0,
        "notify_offline": true, "payload": { "event_id": 77, "phase": "live" }
      }
    ],
    "work_units": [
      {
        "id": 5119, "kind": "construction", "owner": "construction",
        "work_required_mu": 8000000, "work_done_mu": 6038000, "carry_mu": 0,
        "rate_mu_per_hour": 1000000, "rate_channel": "construction_rate",
        "blocked": false, "payload": { "project_id": 311, "stage": 3 }
      }
    ],
    "scheduled_events": [
      {
        "id": 77, "template_id": "stadium_match_major",
        "anchor_tick": 918962, "venue_building_id": 4412,
        "open_phases": ["inbound"], "fired_phases": ["announce", "inbound"],
        "params": { "attendance": 41000 }
      }
    ],
    "curve_set_overrides": {},
    "catchup_last": { "credited_real_ms": 22320000, "coarse_hours": 371, "capped": false }
  }
}
```

Top level, per constitution §9: `sim_time_minutes` is written as `tick_index / 4` and asserted equal on load.

**Section version key.** The per-section key is **`section_version`** (report 98 C-25), never `schema_version`. `schema_version` appears **only** on the save envelope, at top level, owned by doc 08. The `schema_version` field in `data/time.json` (§8) is a *data-file* version and is unaffected by this ruling — it is not a save section.

**Migration policy.** `time.section_version` is independent of the save envelope's global `schema_version`. Adding a curve or channel is not a migration (curves are data, absent overrides default to 1.0). Changing tick length or scale *would* be a migration and requires overseer approval — the ladder function would rescale `tick_index`, all `due_tick`s and `rate_mu_per_hour`.

---

## 4. Sim API Sketch

```
sim/time/game_clock.gd          class GameClock          — tick_index, residual, calendar derivation
sim/time/time_context.gd        class TimeContext        — frozen per-step view (see below)
sim/time/day_curve_set.gd       class DayCurveSet        — load, validate, sample, hour-mean
sim/time/modifier_stack.gd      class ModifierStack      — push/pop sources, deterministic product, clamp
sim/time/tick_scheduler.gd      class TickScheduler      — registry, phase sort, cadence firing, advance_fine/_coarse
sim/time/timer_service.gd       class TimerService       — min-heap of deadline timers, per-owner inboxes
sim/time/work_service.gd        class WorkService        — integer work accumulators
sim/time/scheduled_events.gd    class ScheduledEventService
sim/time/catchup_planner.gd     class CatchUpPlanner     — elapsed -> deterministic schedule
sim/time/sim_system.gd          interface ISimSystem
```

**`TimeContext` fields** (read-only for the step): `tick_index`, `game_seconds`, `dt_game_seconds` (15 or 3600), `mode` (FINE/COARSE), `is_catchup`, `catchup_index`, `catchup_total`, `minute_of_day`, `hour_of_day`, `hour_midpoint` (float, the sample position), `day_index`, `day_of_week`, `day_type`, `day_phase`, `season_index`, `season_progress`, `channels` (Dictionary), `speed` (renderer only — never read by sim math), `slice_index`, `slice_count`.

**Scheduler entry points:** `advance_fine_n(n)`, `advance_coarse_n(hours)`, `advance_real_elapsed(elapsed_real_ms)` (plans then runs), `register(system)`, `set_speed(s)`, `set_paused(b)`.

**Sliced catch-up entry points (report 98 C-22).** Catch-up is main-thread and sliced; there is no threaded branch.

> **As built (Wave 14):** `CitySim.begin_catchup(plan) -> CatchUpCursor`, with `step()` spending ONE whole unit (a coarse hour or a fine tick), `is_done()`, `run()`, `steps_done()` / `steps_total()` and `done_ticks()` / `total_ticks()`. The block below is kept for its contract — whole steps, never split, same schedule, same determinism — but its *signature* is superseded twice over: a plan is not coarse hours alone (worked example B is three fine segments and one coarse one), and `max_ms` cannot be evaluated inside `sim/`, which may not read a clock (constitution §5). The budget is the shell's loop; see §2.10's as-built note and report 98 §29 RR-73.

```
advance_coarse_sliced(max_ms: int) -> bool
    # Runs whole coarse steps from the plan until the elapsed budget for this
    # call would exceed max_ms, then returns.
    #   returns false -> more steps remain; call again next frame
    #   returns true  -> the plan is exhausted (coarse body, mid-fine and fine
    #                    tail all consumed); the sim is caught up
    # A step is never split: the budget is checked between steps, so phase order
    # and determinism are untouched. The same schedule from CatchUpPlanner runs
    # in the same order whether it is delivered in 1 slice or 400 — the result is
    # bit-identical to advance_coarse_n() over the same plan (test T-21).

steps_done()  -> int   # coarse-equivalent steps completed in the current plan
steps_total() -> int   # total steps in the current plan; 0 when no plan is active
```

The caller supplies `max_ms`; **this doc ships no slice-budget constant** — doc 13 owns it (12 ms per frame behind the animated veil) and doc 08 owns the `time.catchup_progress` event contract that `steps_done() / steps_total()` feeds.

**Commands handled:** `set_speed`, `set_paused`, `debug_advance_ticks`, `debug_advance_hours`, `debug_set_time_of_day` (last three compiled out of release).

**Events emitted:** `time.tick`, `time.minute`, `time.hour`, `time.day`, `time.day_phase_changed`, `time.season_changed`, `time.speed_changed`, `time.paused`, `time.spill`, `time.catchup_begin`, `time.catchup_progress`, `time.catchup_end`, `timer.due`, `work.completed`, `event.scheduled`, `event.phase_begin`, `event.phase_end`.

---

## 5. Cross-System Interfaces

**Everything this doc provides:**

Doc numbers below are the canonical on-disk numbers (report 98 Ruling Zero).

| Consumer | Provided |
|---|---|
| All sim systems | `ISimSystem` implementation contract, `TimeContext`, phase slot, cadence subscription |
| 02 Buildings & construction | `channels.power_demand_*`, `water_demand_residential`, `water_demand_commercial`, `commercial_output`; `day_type`, `season_index` for demand shaping; `WorkService`, the `construction_rate` channel and `work.completed` events for the project queue |
| 03 Economy | `EVERY_HOUR` slot at P14 settling the completed hour; `channels.commercial_output` |
| 04 Power | `EVERY_TICK` at P06; `power_demand_residential/commercial/industrial/civic/datacenter`, `streetlight_load` — the **only** diurnal store; doc 04's `demand.tod_curves` is deleted (C-32) |
| 05 Water | `EVERY_TICK` at P07, guaranteed after P06 in the same step; `water_demand_residential`, `water_demand_commercial` — doc 05's `residential_hourly` / `commercial_hourly` arrays are deleted (C-33) |
| 06 Incidents, dispatch & fleets | `EVERY_TICK` at P09 (vehicles) and `EVERY_MINUTE` at P11 (incidents); `response_speed`, `crime_rate`, `incident_rate`; deadline timers for escalation; the L1 one-step stability lag; `is_catchup` for auto-response policies; crews as dispatchable units at P10 |
| 07 Weather & Director | `EVERY_TICK` at P04 (weather) and `EVERY_HOUR` at P16 (Director); ScheduledEventService for hazard timelines; `season_index`, `season_progress`; the 30-day season / 120-day year calendar (§2.1–2.2) |
| 08 Persistence, offline & notification policy | `OFFLINE_CAP_REAL_MS` (43 200 000 ms = 720 game-hours) as the outer offline bound; `tick → wall_ms` conversion (250 ms/tick); `notify_offline` timer flag; `advance_coarse_sliced` + `steps_done()`/`steps_total()` for `time.catchup_progress`; catch-up summary payload; event ring buffer timestamps |
| 09 Map, districts & population | `EVERY_MINUTE` at P13 (districts/stability), `EVERY_DAY` at P15 (population) |
| 10 Roads | `EVERY_TICK` at P08; `traffic_density`; `WorkService` for road jobs submitted to doc 02's queue |
| 11 Rendering | `daylight` channel, `day_phase`, interpolation alpha `residual_game_ms / 15000`, `speed` |
| 13 Android | elapsed-ms handoff contract at resume; the tick→wall alarm conversion doc 13's `AlarmManager` layer schedules against |

**What this doc requires from others (exact expectations):**

1. **Every sim system** implements `advance_fine` *and* `advance_coarse` and declares a stable `system_id`, `phase`, `cadence`. A system that cannot supply a coarse variant must justify it here; none is expected to need to.
2. **Docs 04, 05, 06, 10** publish their coarse integration formula and the number of RNG draws their coarse step consumes.
3. **Doc 07 (Director)** honours the "schedules only, never mutates" rule at P16. It does **not** read an offline hazard cap from this doc: per report 98 C-55 the cap is doc 08 §2.3 rule 1 (≤ 1 hazard, Tier 1 only, pre-warned before backgrounding, FULL band only, zero on `casual`), and doc 07's F8 is tightened to it verbatim. This doc supplies only `ctx.is_catchup` / `catchup_index` / `catchup_total`.
4. **Doc 07 (Weather)** exposes weather as multipliers on the named channels in §2.6 — it must not invent private time-of-day logic — and, per C-27, is the **sole** author of storm effect multipliers, including those the `thunderstorm_hazard` template used to carry.
5. **Doc 02** authors construction durations against the `construction_rate` 24-hour mean of **0.804**, not against a nominal 1.0.
6. **Doc 03** authors all rates per game-hour (constitution §7) and treats the hourly invocation as settling the *previous* hour.
7. **Doc 13** owns wall-clock measurement in the app shell and passes elapsed ms to the sim exactly once per resume, and owns the per-frame `max_ms` slice budget passed to `advance_coarse_sliced`.
8. **Doc 08** owns `max_coarse_hours`, derived from `test_coarse_step_cost` per §2.10, and owns the catch-up work budget. This doc defines neither.

---

## 6. MVP Cut

**In the vertical slice:**

- `GameClock`, `tick_index`, calendar derivation, `TimeContext`.
- `TickScheduler` with the full 18-phase order and all four cadences (phases with no registered system are simply empty).
- Day curves for all **15** channels, weekday only; `ModifierStack` with clamps.
- Deadline timers + work units, both persisted.
- Pause and 1x/2x/3x, backlog spill, foreground-pause semantics, grace window.
- `advance_coarse` interface plus `CatchUpPlanner` with the 12-real-hour cap, head-align, coarse body, mid-fine and fine tail.
- `advance_coarse_sliced(max_ms)` + `steps_done()` / `steps_total()` — the sliced main-thread catch-up path (C-22). Required in MVP: it is the only catch-up path there is.
- The full save section and its round-trip test.
- ScheduledEventService with the phase/timer machinery and **one** shipped template — the thunderstorm hazard timeline for the MVP disaster (spec §43.4). This is required in MVP because the storm needs a warning phase. Its `modifiers` blocks ship **empty** (C-27); doc 07 supplies the storm's effects.

**Deferred:**

- Weekend curve override tables (mechanism ships, data does not).
- Stadium event templates and venue anchoring (spec §10, Phase 5) — the framework carries them with no new code.
- Sliceable day-cadence systems (off until measured).
- Android notification pre-registration (§2.11 conversion ships and is tested; the JNI alarm call is doc 13, Phase 2).
- Seasonal variation of the daylight curve — MVP daylight is fixed sunrise 06:00 / sunset 19:00 year-round; `season_index` is exposed for doc 07 regardless.
- Per-system RNG-draw accounting tooling (a debug build feature).

---

## 7. Test Plan

Headless, via `godot --headless --path . -s res://tests/run_tests.gd`.

| ID | Test | Assertion |
|---|---|---|
| T-01 | Calendar derivation table | 12 hand-computed `tick_index → (day, dow, hh:mm, season)` pairs, including the §2.2 worked example and the wrap ticks 5759/5760, match exactly. |
| T-02 | Cadence firing counts | Over 5 760 ticks from tick 0: `EVERY_TICK` fires 5 760, `EVERY_MINUTE` 1 440, `EVERY_HOUR` 24, `EVERY_DAY` 1. Repeat starting at tick 918 442 (non-aligned) and assert the same counts ±1. |
| T-03 | Phase order stability | Register 18 probe systems in shuffled order across 20 seeded permutations; the recorded execution sequence is byte-identical every time and matches the P00…P17 table. |
| T-04 | One-step lag contract | A probe writing at P13 and a probe reading at P11 observe exactly one step of delay, never zero, never two. |
| T-05 | Cascade hop rate | A synthetic 5-hop dependency chain fully propagates in exactly 5 ticks, and a deliberately cyclic 3-node graph terminates (one hop per tick, no recursion, no hang). |
| T-06 | Speed independence | The same 4 000-tick script at speed 1, 2, 3 and with 40 pause/resume pairs interleaved yields identical end-state hashes. |
| T-07 | Curve sampling | `sample()` matches hand-computed values at 6 points including the 07:30 traffic example and a wrap-around sample at 23:30. |
| T-08 | Curve validation | Every `normalized` curve in `data/time.json` has 24-hour trapezoid mean within 1.000 ± 0.02; every keyframe hour is an integer; a deliberately malformed fixture is rejected with a clear error. Explicit expected means, recomputed post-C-32/C-33: `power_demand_civic` **1.000** (area 24.000), `power_demand_datacenter` **1.000**, `water_demand_residential` **0.997** (area 23.925), `water_demand_commercial` **0.999** (area 23.975). |
| T-09 | Fine/coarse curve equivalence | For all **15** channels: mean of 240 fine midpoint samples across an hour equals the single coarse midpoint sample to within 1e-9, for all 24 hours. |
| T-10 | Work accumulation exactness | The §2.7 overnight high-rise example completes at 08:09:43 to the tick, and running the same interval as 12 coarse hours produces the same `work_done_mu` ± 1. |
| T-11 | Catch-up planner determinism | §2.10 worked example A produces exactly `[38 fine, 371 coarse, 162 fine, 40 fine]`; §2.10 worked example B (the 12-h cap) produces exactly `[38 fine, 719 coarse, 162 fine, 40 fine]` summing to 172 800 ticks; total ticks equal `game_ms / 15000`; residual carries correctly; 200 random elapsed values all conserve total ticks. |
| T-12 | Coarse statistical equivalence | Harness for stochastic systems: 1 000 independent coarse-hours vs 1 000 fine-hours on a probe system with `p = 0.004/tick`; mean event counts within 5 %, and the coarse path consumes a fixed draw count per step. |
| T-13 | Cap and grace | Elapsed 90 s credits 0 ticks; 130 s credits 520 ticks (`130 × 60 = 7 800` game-sec `/ 15`); 26 h credits exactly `OFFLINE_CAP_REAL_MS = 43 200 000 ms` worth — **172 800 ticks = 720 game-hours = 30 game-days** (was 115 200 / 20 days under the retired 8 h cap) — and sets `capped = true`. Also asserts `data/time.json` carries no `max_coarse_hours` and no offline-hazard constant: both belong to doc 08. |
| T-14 | Save round-trip | Serialize at a non-aligned tick with 3 timers, 2 work units (one mid-carry), 1 open event phase and residual 4 200 ms; deserialize; advance 1 000 ticks on both; state hashes match. `sim_time_minutes == tick_index / 4`. The section carries `section_version` and **no** `schema_version` key (C-25). |
| T-15 | Timer heap ordering | 10 000 timers with duplicate `due_tick`s fire in `(due_tick, id)` order across 5 shuffled insertion orders. |
| T-16 | Scheduled event timeline | The §2.8 stadium example opens/closes all five phases on the exact ticks listed, both fine and through a coarse catch-up spanning the whole event. |
| T-17 | Modifier clamp & order | Curve `1.87 × 1.9 (scheduled_event) × 1.35 (weather, injected as doc 07 would) = 4.7966` clamps to **4.00**; multiplying the same source set in 10 shuffled registration orders gives a bit-identical float. |
| T-21 | Sliced catch-up equivalence (C-22) | Worked example B's 719-coarse-step plan run through `advance_coarse_sliced(max_ms)` at `max_ms ∈ {1, 4, 12, 50, 10⁹}` yields a state hash and RNG stream states identical to `advance_coarse_n` over the same plan; `steps_done()` is non-decreasing, never exceeds `steps_total() = 719`, and the call returns `true` exactly once, on the step that exhausts the plan. No `WorkerThreadPool` symbol appears anywhere in `sim/time/`. **SHIPPED as `tests/test_catchup_cursor.gd` (Wave 14)** — the budget is units per frame rather than `max_ms`, at `{1, 3, 12, ∞}`, on **both cities**, and against a verbatim copy of the shell loop the cursor replaced rather than against `advance_coarse_n` alone (a plan carries fine segments too). It compares `state_hash()` **and** the drained event bus, because an away report is built from the second one. |
| T-22 | Channel registry completeness (C-32/C-33) | `data/time.json` declares exactly the 15 channels in §2.6, including `power_demand_civic`, `power_demand_datacenter` and `water_demand_commercial`; the key `water_demand` no longer resolves (a consumer asking for it fails loudly rather than silently reading 1.0). |
| T-23 | Weather template carries no effects (C-27) | Every phase of the `thunderstorm_hazard` template has an empty `modifiers` block, while its five phase names, offsets (−240, −60, 0, +90, +180 min) and notify classes are intact; a storm run with doc 07 stubbed out moves no channel. |
| T-18 | Backlog spill | Injecting a 400-tick backlog produces exactly 1 coarse hour + 160 fine ticks and one `time.spill` event; total simulated time is conserved. |
| T-19 | No wall-clock in sim | Static scan of `sim/` for `Time.`, `OS.`, `Engine.`, `Input.`, `get_ticks_` — zero hits. |
| T-20 | Determinism end-to-end | Same save + same elapsed ms run through `advance_real_elapsed` twice ⇒ identical state hash and identical RNG stream states (constitution §5). |

---

## 8. Tunables — `data/time.json`

```json
{
  "schema_version": 1,
  "clock": {
    "real_seconds_per_game_minute": 1.0,
    "game_seconds_per_sim_tick": 15,
    "ticks_per_game_minute": 4,
    "ticks_per_game_hour": 240,
    "ticks_per_game_day": 5760,
    "minutes_per_game_day": 1440,
    "days_per_week": 7,
    "days_per_season": 30,
    "seasons_per_year": 4,
    "founding_offset_minutes": 360,
    "founding_day_of_week": 0,
    "weekend_first_day_of_week": 5
  },
  "speeds": {
    "allowed": [1, 2, 3],
    "default": 1,
    "max_ticks_per_frame": 8,
    "backlog_spill_ticks": 240,
    "auto_speed_reset_on_critical": true,
    "pause_is_foreground_only": true
  },
  "catchup": {
    "offline_cap_real_ms": 43200000,
    "offline_cap_game_hours": 720,
    "offline_grace_seconds": 120,
    "fine_catchup_max_ticks": 20,
    "fine_tail_ticks": 40,
    "coarse_step_game_seconds": 3600,
    "real_ms_per_tick_offline": 250,
    "coarse_lambda_normal_threshold": 4.0
  },
  "phases": [
    "CLOCK", "COMMANDS", "TIMERS", "EVENTS", "WEATHER", "DEMAND",
    "POWER", "WATER", "ROADS", "VEHICLES", "WORK", "INCIDENTS",
    "CASCADE", "DISTRICTS", "ECONOMY", "POPULATION", "DIRECTOR", "REPORT"
  ],
  "day_phases": [
    { "id": "NIGHT",         "start_minute": 1320, "end_minute": 300 },
    { "id": "DAWN",          "start_minute": 300,  "end_minute": 420 },
    { "id": "MORNING_RUSH",  "start_minute": 420,  "end_minute": 570 },
    { "id": "MIDDAY",        "start_minute": 570,  "end_minute": 990 },
    { "id": "EVENING_RUSH",  "start_minute": 990,  "end_minute": 1140 },
    { "id": "EVENING",       "start_minute": 1140, "end_minute": 1320 }
  ],
  "curves": {
    "power_demand_residential": {
      "kind": "normalized", "mean": 0.999,
      "keys": [[0,0.76],[5,0.67],[7,1.14],[9,0.92],[12,0.87],[17,1.19],[20,1.46],[22,1.25]]
    },
    "power_demand_commercial": {
      "kind": "normalized", "mean": 1.001,
      "keys": [[0,0.36],[6,0.42],[8,1.14],[10,1.51],[18,1.51],[20,1.14],[22,0.62]]
    },
    "power_demand_industrial": {
      "kind": "normalized", "mean": 1.000,
      "keys": [[0,0.84],[6,0.89],[8,1.08],[16,1.13],[22,0.94]]
    },
    "power_demand_civic": {
      "kind": "normalized", "mean": 1.000,
      "_source": "doc 04 CIV tod_curve shape, normalized here (raw mean 0.959, x1.04689) — report 98 C-32",
      "keys": [[0,0.84],[3,0.82],[5,0.89],[7,1.10],[8,1.15],[16,1.10],[19,0.99],[23,0.86]]
    },
    "power_demand_datacenter": {
      "kind": "normalized", "mean": 1.000,
      "_source": "flat — data centres do not sleep; report 98 C-32",
      "keys": [[0,1.00]]
    },
    "streetlight_load": {
      "kind": "absolute", "mean": 0.500,
      "keys": [[0,1.00],[6,1.00],[7,0.00],[18,0.00],[19,1.00],[23,1.00]]
    },
    "water_demand_residential": {
      "kind": "normalized", "mean": 0.997,
      "_note": "renamed from water_demand — report 98 C-33; keyframes unchanged",
      "keys": [[0,0.45],[5,0.50],[7,1.55],[9,1.10],[12,1.15],[14,1.00],[18,1.35],[21,1.30],[23,0.75]]
    },
    "water_demand_commercial": {
      "kind": "normalized", "mean": 0.999,
      "_source": "doc 05 commercial_hourly (sums to 24.0); keyframe-reduced here, no rescale needed — report 98 C-33",
      "keys": [[0,0.25],[3,0.20],[5,0.40],[7,1.05],[9,1.65],[11,1.90],[13,1.65],[14,1.70],
               [16,1.45],[19,1.00],[21,0.65],[23,0.35]]
    },
    "traffic_density": {
      "kind": "normalized", "mean": 0.999,
      "keys": [[0,0.19],[5,0.23],[6,0.59],[7,1.71],[8,2.08],[9,1.44],[11,1.12],[13,1.28],
               [15,1.23],[16,1.66],[17,2.08],[18,1.87],[19,1.17],[21,0.80],[23,0.37]]
    },
    "crime_rate": {
      "kind": "normalized", "mean": 1.001,
      "keys": [[0,1.66],[3,1.44],[6,0.59],[9,0.48],[12,0.59],[15,0.75],[18,1.02],[21,1.44],[23,1.66]]
    },
    "commercial_output": {
      "kind": "normalized", "mean": 1.001,
      "keys": [[0,0.22],[7,0.33],[9,1.46],[12,1.74],[14,1.57],[18,1.68],[20,1.30],[22,0.60]]
    },
    "construction_rate": {
      "kind": "absolute", "mean": 0.804,
      "keys": [[0,0.60],[6,0.60],[7,1.00],[17,1.00],[19,0.75],[21,0.60]]
    },
    "response_speed": {
      "kind": "absolute", "mean": 1.000,
      "keys": [[0,1.00]]
    },
    "incident_rate": {
      "kind": "normalized", "mean": 1.000,
      "keys": [[0,1.00]]
    },
    "daylight": {
      "kind": "absolute", "mean": 0.492,
      "keys": [[0,0.00],[5,0.00],[6,0.15],[7,0.75],[8,1.00],[17,1.00],[18,0.75],[19,0.15],[20,0.00]]
    }
  },
  "weekend_curve_overrides": {},
  "channels": {
    "power_demand_residential": { "curve": "power_demand_residential", "min": 0.20, "max": 3.00 },
    "power_demand_commercial":  { "curve": "power_demand_commercial",  "min": 0.20, "max": 3.00 },
    "power_demand_industrial":  { "curve": "power_demand_industrial",  "min": 0.20, "max": 3.00 },
    "power_demand_civic":       { "curve": "power_demand_civic",       "min": 0.20, "max": 3.00 },
    "power_demand_datacenter":  { "curve": "power_demand_datacenter",  "min": 0.20, "max": 3.00 },
    "streetlight_load":         { "curve": "streetlight_load",         "min": 0.00, "max": 1.00 },
    "water_demand_residential": { "curve": "water_demand_residential", "min": 0.20, "max": 3.00 },
    "water_demand_commercial":  { "curve": "water_demand_commercial",  "min": 0.20, "max": 3.00 },
    "traffic_density":          { "curve": "traffic_density",          "min": 0.05, "max": 4.00 },
    "crime_rate":               { "curve": "crime_rate",               "min": 0.00, "max": 5.00 },
    "commercial_output":        { "curve": "commercial_output",        "min": 0.00, "max": 2.50 },
    "construction_rate":        { "curve": "construction_rate",        "min": 0.00, "max": 2.00 },
    "response_speed":           { "curve": "response_speed",           "min": 0.25, "max": 1.50 },
    "incident_rate":            { "curve": "incident_rate",            "min": 0.00, "max": 6.00 },
    "daylight":                 { "curve": "daylight",                 "min": 0.00, "max": 1.00 }
  },
  "modifier_source_rank": {
    "weather": 0, "scheduled_event": 1, "district": 2, "policy": 3, "debug": 4
  },
  "timer_kinds": [
    "scheduled_event_phase", "hazard_phase", "incident_escalation",
    "director_cooldown", "policy_window", "notification"
  ],
  "work_kinds": [
    "construction", "land_development", "utility_repair",
    "fire_suppression", "debris_clearance"
  ],
  "work": {
    "milli_units_per_unit": 1000000,
    "accumulator_denominator": 3600000
  },
  "event_templates": {
    "thunderstorm_hazard": {
      "_note": "report 98 C-27: doc 07 owns every storm effect multiplier. This template carries the warning timeline only — phases, offsets and notification classes. All modifiers blocks are intentionally empty; see data/weather.json (doc 07) for road_speed_mult, construction_speed_mult, incident_*_mult and response effects.",
      "phases": [
        { "name": "watch",    "offset_minutes": -240, "notify": "important", "modifiers": {} },
        { "name": "warning",  "offset_minutes": -60,  "notify": "critical",  "modifiers": {} },
        { "name": "impact",   "offset_minutes": 0,    "notify": "critical",  "modifiers": {} },
        { "name": "clearing", "offset_minutes": 90,   "notify": "routine",   "modifiers": {} },
        { "name": "end",      "offset_minutes": 180,  "notify": "none",      "modifiers": {} }
      ]
    },
    "stadium_match_major": {
      "phases": [
        { "name": "announce", "offset_minutes": -2880, "notify": "routine", "modifiers": {} },
        { "name": "inbound",  "offset_minutes": -120,  "notify": "routine",
          "modifiers": { "traffic_density": 1.90, "incident_rate": 1.40 } },
        { "name": "live",     "offset_minutes": 0,     "notify": "routine",
          "modifiers": { "traffic_density": 0.70, "incident_rate": 2.20,
                         "power_demand_commercial": 2.60 } },
        { "name": "outbound", "offset_minutes": 150,   "notify": "routine",
          "modifiers": { "traffic_density": 2.40, "incident_rate": 1.80 } },
        { "name": "end",      "offset_minutes": 270,   "notify": "none", "modifiers": {} }
      ]
    }
  },
  "budget": {
    "_note": "report 98 C-21: coarse_step_avg_ms (0.6) and catchup_total_warn_ms (500) are REMOVED. The coarse step is settled by measurement — tests/perf/test_coarse_step_cost.gd (P0-27) — and doc 08 owns max_coarse_hours and the catch-up work budget. See §2.10 / §2.12.",
    "fine_tick_avg_ms": 1.2,
    "fine_tick_p99_ms": 3.0,
    "hour_tick_avg_ms": 3.0,
    "day_tick_avg_ms": 6.0,
    "day_tick_slice_threshold_ms": 8.0
  },
  "debug": {
    "advance_log_ring_size": 4096,
    "enable_debug_time_commands": false
  }
}
```

---

## 9. Conflicts & Open Questions

### Conflicts with the constitution

1. **Canonical clock storage (constitution §4).** §4 states the canonical clock is "game-minutes since founding, int64". A 15-game-second tick has quarter-minute resolution, so a minute counter cannot round-trip state. **Resolution taken:** `tick_index : int64` is the authoritative persisted counter; `sim_time_minutes = tick_index / 4` is written at save top level exactly as §9 requires and asserted consistent on load. No numeric value in §4 changes. Flagged as a clarification, not a deviation, but it does edit the literal wording of §4 and needs a nod.

2. **"4 Hz / 1 Hz" wording (constitution §4).** Real-world Hz doubles at 2x speed. This doc reads those figures as *game-time cadences* — every tick and every game-minute respectively — which equal 4 Hz and 1 Hz at 1x and are speed-invariant. This is the only reading under which speed controls do not change balance.

3. **Offline time scale (constitution §4) — RULED, CLOSED.** §4 locks the 60× scale "while app is open" and was silent on offline. This doc applies the **same** 60× scale offline, with a **12-real-hour credit cap** (= 720 game-hours = 30 game-days) and time beyond the cap discarded rather than banked. Report 98 C-19 ruled the number and constitution §4 has been amended to name it ("default: 12 real hours; surplus is discarded and reported, never banked"). This doc owns the constant in `data/time.json`; docs 08 and 13 read it and define none of their own. Docs 03, 07 and 08 balance against 30 game-days, not 20.

4. **Offline determinism scope (constitution §5).** §5 guarantees "same save + same elapsed time ⇒ same offline outcome". That holds exactly, because `CatchUpPlanner` maps elapsed ms to a deterministic advance schedule. It does **not** imply that a coarse catch-up equals a fine catch-up of the same duration — those legitimately differ, and the coarse contract binds them only to ±5 % in expectation. Stated here so no other doc assumes fine/coarse identity for stochastic systems.

### Likely conflicts with sibling docs

5. **Doc 02 (construction projects).** `construction_rate` has a 24-hour mean of **0.804**, not 1.0. If doc 02 authors durations against a nominal full-rate day, every project will run ~24 % long. Either doc 02 divides by 0.804, or the night floor is raised to 1.0 (which costs the "construction sleeps at night" texture). Report 98 C-29 ruled it: every work unit multiplies `ctx.channels.construction_rate`, and docs 02, 09 and 10 must call it — doc 09's tutorial block re-derives to `97.6 / 0.804 ≈ 121 gh`.

6. **Doc 07 (Director).** The P16 "schedules only, never mutates" rule constrains the Director's implementation shape. A Director that wants to damage the city in the instant it decides to will conflict; the intended pattern is to schedule an event whose `impact` phase is one or more ticks later.

7. **Doc 06 (Incidents) — the L1 lag.** Incidents read the *previous* step's district stability (published by doc 09 at P13). If doc 06 assumes same-step stability, the code will silently work but the cascade will be one tick tighter than documented and the ordering test T-04 will fail.

8. **Doc 06 (Dispatch) coarse mode.** Vehicles must resolve travel analytically over a coarse hour. If doc 06 cannot express dispatch without per-tick movement, we need either a per-hour analytic model there or a special case here — and a special case here is the worse outcome.

9. **Doc numbering — RULED, CLOSED.** Report 98 Ruling Zero: **the on-disk filenames are canonical and there is no other map.** This doc's provisional table was one of five incompatible maps; it is deleted and every cross-reference in §2, §5, §6 and §9 has been renumbered against the canonical list at the top of this doc. No code may reference a doc number except through that list.

10. **Doc 07 (Weather) — storm effects, RULED.** Report 98 C-27: the `thunderstorm_hazard` template's `modifiers` blocks are empty and doc 07 is the sole author of storm effect multipliers. If doc 07 fails to publish a traffic/response/construction/incident multiplier for `THUNDERSTORM`, the storm will be *silent* rather than double-counted — a loud failure mode is preferred, and T-23 asserts it.

11. **Doc 08 (Offline) — coarse-step cost, RULED.** Report 98 C-21 retired this doc's 0.6 ms coarse budget in favour of `test_coarse_step_cost` and doc 08's `max_coarse_hours` rule. The residual risk is that P0-27 measures near doc 08's 27 ms figure, in which case `max_coarse_hours = 72` and a 12-hour absence credits only 3 game-days of the 30 the cap allows — the C-19 cap and the measured cap would then disagree in practice, and the report must say so plainly. That is a *reporting* requirement on doc 08, not a redesign here.

### Open questions for the overseer

- **Weekends: worth authoring in MVP?** The mechanism is free; two extra curve sets (traffic, commercial) would add real texture to rush-hour play for a few hours of authoring. Currently deferred.
- **Seasonal daylight.** Fixed 06:00/19:00 year-round is a visible simplification once seasons exist in doc 07. Add a per-season daylight curve set at that point, or accept a static sun?
- **Speed 3 as the ceiling.** A 3x cap means a full game-day is 8 real minutes. Is there appetite for a 5x "quiet period" speed once the city is large and stable, given the explicit decision not to sell speed?
- **Foreground-only pause.** Confirm the ruling that pausing then closing the app does not stop the city. It is the honest reading of Core Rule 2, and it will generate support mail.

*Closed by report 98:* "is the 8-hour cap right?" (C-19 → 12 h) and "discard or bank over-cap time?" (discard, confirmed in constitution §4 and C-19).

---

## Amendments applied (report 98)

Every row of this doc's worklist in report 98 §12, applied in place. Deleted constants are **removed**, not commented out; each carries a one-line pointer to the doc that now owns it.

| Ruling | Change |
|---|---|
| **Ruling Zero** | The provisional sibling-numbering table (06=roads, 07=dispatch, 08=construction, 10=incidents, 11=weather, 12=population, 13=persistence) is deleted and replaced with the canonical on-disk map; every cross-reference in §2.4 (phase owners), §2.5, §2.6 (channel consumers), §2.8, §2.9, §2.10, §2.11, §5 (both tables), §6 and §9 is renumbered. §9 item 9 closed. |
| **C-19** | `OFFLINE_CAP_REAL_MS` 28 800 000 → **43 200 000 ms** (12 real hours = 720 game-hours = 30 game-days = 172 800 ticks). This doc owns the constant in `data/time.json`; docs 08 and 13 read it. §2.10 rewritten with the derivation and the "why not 8, why not 72" rationale; a new capped worked example B added; the report string re-worded; §2.11's alarm cap re-stated; T-13's expectation recomputed 115 200 → 172 800 ticks; §9 conflict 3 marked ruled. |
| **C-21** | The **0.6 ms / 1.5 ms coarse-step budget line is retired** — removed from the §2.12 table and from `budget` in §8, along with `catchup_total_warn_ms`. Replaced by doc 08's measurement rule stated normatively in §2.10 (`test_coarse_step_cost.gd`, P0-27, `max_coarse_hours = clamp(floor_to_×24(ceil(2000 / measured_ms)), 72, 720)`), with a worked table across the plausible measurement range. `max_coarse_hours` is **owned by doc 08**, not by `data/time.json`. |
| **C-22** | §4 gains `advance_coarse_sliced(max_ms) -> bool` plus `steps_done()` / `steps_total()`, with the never-split-a-step guarantee. §2.10 states main-thread slicing only and that no `WorkerThreadPool` branch exists. The per-frame `max_ms` value belongs to doc 13 (12 ms); no slice constant ships here. Added to §6 MVP; new test T-21. |
| **C-25** | Save section `"time"` key `schema_version` → **`section_version`**; §3.2 migration prose updated; T-14 asserts the section carries no `schema_version`. The `schema_version` in `data/time.json` is a data-file version, untouched. |
| **C-27** | All five `modifiers` blocks in the `thunderstorm_hazard` template are **emptied**; phases, offsets (−240/−60/0/+90/+180 min) and notify classes retained. §2.8 states doc 07 is the sole author of storm effect multipliers; the §2.8 clamp example and T-17 now attribute the ×1.35 to doc 07's weather source. New test T-23. `stadium_match_major` keeps its modifiers — nothing else publishes them. |
| **C-32** | Two channels added: **`power_demand_civic`** (doc 04's CIV shape, normalized here: raw mean 0.959, keyframe-curve mean 0.9552, ×1.04689 → mean **1.000**) and **`power_demand_datacenter`** (flat 1.00, mean 1.000). `data/time.json` is stated as the only diurnal curve store; doc 04's `demand.tod_curves` is deleted there. |
| **C-33** | `water_demand` **renamed `water_demand_residential`** (keyframes unchanged, mean 0.997) and **`water_demand_commercial`** added from doc 05's `commercial_hourly` (raw sum exactly 24.0; keyframe-reduced curve mean **0.999**, inside the ±0.02 gate, so no rescale). Doc 05 deletes both hourly arrays. Channel count 12 → **15** throughout (§2.6, §6, T-09); new test T-22. |
| **C-55** | The "recommended ≤ 1 Director-scheduled major hazard per catch-up session" recommendation is **withdrawn** and the tunable `recommended_max_director_hazards_per_catchup` **removed** from `data/time.json`. §2.10 and §5 requirement 3 now reference **doc 08 §2.3 rule 1** as the outer clamp (≤ 1 hazard, Tier 1 only, pre-warned before backgrounding, FULL band only, zero on `casual`). This doc supplies only `ctx.is_catchup` / `catchup_index` / `catchup_total`. |

**Numbers that moved.** `OFFLINE_CAP_REAL_MS` 28 800 000 → 43 200 000 ms · offline cap 480 → **720** game-hours (20 → 30 game-days) · capped tick count 115 200 → **172 800** · worst-case coarse plan 479 → **719** steps · channel count 12 → **15** · coarse-step budget 0.6 ms → **measured** (`max_coarse_hours` = 720 at ≤2.77 ms, 480 at 4 ms, 72 at 27 ms) · catch-up fine-tick cost restated from an erroneous "≈ 0.7 ms" to `240 × 1.2 = ` **288 ms**.

**Numbers that did not move,** and were re-derived to confirm it: the §2.2 calendar example (tick 918 442 → Saturday 16:50, day 159, summer, year 1) · the §2.3 hourly-firing example · the §2.6 07:30 traffic sample 1.895 · the §2.7 overnight high-rise completion 08:09:43 for 8 crew-hours · `water_demand_residential` mean 0.997 · worked example A's schedule `[38, 371, 162, 40]` (6 h 12 m is under both the old and new cap) · the §2.11 alarm example (314 500 ms) · `construction_rate` mean 0.804.
