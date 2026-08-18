# 06 — Incidents, Dispatch & Emergency Fleets

**Status:** AMENDED per `98-consistency-report.md`, **including its §14 Round 2 rulings (RR-3, RR-4) and its §15 Round 3 ruling (RR-15)**. Complies with `00-constitution.md` (LOCKED).
**Covers:** spec §15 (Emergency & Service Response), §16.1 (stability→crime coupling), §17 (Fire System), §21.3 (Automatic Response Rules), §33 (Incident System), §34 (cascades), §46 (Incident/Vehicle data model).
**Owns:** `data/incidents.json`, `data/vehicles.json`, `data/dispatch.json`, save sections `incidents`, `fleet`, `dispatch`; code roots `sim/incidents/`, `sim/dispatch/`, `sim/fleet/`.
**Also owns, by ruling:** *all* incident generation including **storm damage** (C-53); **unit capacity per station level** (C-50); **construction crews as dispatchable units** (G-2); **fire dynamics** — severity, tier, `required_rate`, spread, burn-down, residual `damage_fraction` (C-43).
**Explicitly does not own:** any price (doc 03), per-archetype fire ignition rate or `fire_load` (doc 02), the construction *project queue* (doc 02), weather generation (doc 07), **any weather multiplier — every one is a doc 07 `get_effect()` channel (RR-4, and RR-15 for the two fire-dynamics channels `fire_escalation_mult` / `fire_spread_mult`)**, Director budgeting (doc 07), routing internals or `condition_hazard_mult` (doc 10).

> **Doc numbering follows report 98 Ruling Zero: the on-disk filenames are canonical.** 01 time · 02 buildings & construction · 03 economy · 04 power · 05 water · 06 this doc · 07 weather & Director · 08 persistence/offline/notifications · 09 map, land, districts, population & stability · 10 roads · 11 rendering · 12 UI · 13 Android. Every cross-reference below has been renumbered.

---

## 1. Overview & Goals

This system is the **crisis half** of the core loop (`Build → Operate → Crisis → Respond → Recover`). It turns the state of every other system — power load, hydrant pressure, district stability, weather, road congestion — into discrete, located, timed problems that consume a **finite** fleet, and it turns unanswered problems into worse problems.

Goals, in priority order:

1. **Finite response is the strategy.** The decision is never "should I fix this" but "which of these three, with two trucks." Every choice below protects scarcity.
2. **Legible causality** (Core Rule 12). Every incident stores the inputs that spawned it (`cause` block) so the UI can say *"Transformer T-14 failed: 118% load, condition 0.72, heat wave."*
3. **Escalation is a clock the player can read.** Severity is continuous, its rate is displayable, and partial response visibly slows it.
4. **Online and offline are the same code and the same math** (Constitution §4). The offline path is not "coarse and approximate": it is the same integrator with event-driven sub-stepping inside 1-game-hour steps, so a fire that burns a building down at minute 37 does so at minute 37 either way.
5. **Cascades are data** (Constitution §8). Escalation consequences are declarative action lists in `data/incidents.json`, not `if type == FIRE` branches.

Non-goals here: Director event budgeting (**doc 07**), weather generation (**doc 07**), pathfinding internals (doc 10), building shells / the construction project queue (**doc 02**), and every price in the project (**doc 03**).

### 1.1 Pacing target (calibration anchor for every number below)

Constitution §4: **1 real second = 1 game minute**; 1 game-hour = 60 real seconds; 1 game-day = 24 real minutes.

| | target |
|---|---|
| Incident lifetime, routine (crime, accident) | 0.5–1.0 game-hours = **30–60 real seconds** |
| Incident lifetime, infrastructure (transformer, main) | 1.5–2.5 game-hours = **1.5–2.5 real minutes** |
| Incident lifetime, escalated structure fire | 3–6 game-hours = **3–6 real minutes** |
| Incident arrival rate, early city (≈6k pop) | ≈4–6 per game-day |
| Incident arrival rate, mid-MVP city (≈25k pop) | ≈14–20 per game-day |
| **Structure fires, 300-building reference city** | **≈0.76 per game-day** — the calibration anchor for `R_fire_base` (§2.6b, R-11) |
| **Wind failures, 60-span grid, one 120-min storm** | **≈2.5 maintained / ≈12 neglected** — the calibration anchor for `R_storm_base` (§2.6f, R-13) |
| Simultaneous active incidents, mid-MVP | 2–5 typical, 8–14 during a thunderstorm |
| Fleet at mid-MVP | 4 patrol, 2 engines, 2 utility, 1 water, 2 construction |

**Response-time band — starter city *and* mature city** *(report 98 C-70; the mature-city case was previously missing and its absence risked mis-calibrated escalation timers).*

| case | distance | ETA | what the fire is doing when the engine arrives |
|---|---|---|---|
| Starter city, clear | ≤ 384 m across | **4–14 gm** | tier 1 (tier 2 begins at 21.8 gm — see §2.4) |
| Mature city, clear (doc 10 §2.6 worked example C) | 880 m | **24.2 gm** | tier 2 — 21.8 gm ≤ 24.2 gm < 39.3 gm |
| Mature city, thunderstorm + signal blackout (same run) | 880 m | **39.1 gm** | tier 2, 0.2 gm from tier 3 (39.3 gm) |

**Ruling (C-70): both bands are correct and `speed_mpgm` as a game-time constant is APPROVED.** The escalation timers in §2.4 are calibrated so that the worst mature-city response — 39.1 gm in a storm-plus-blackout — still arrives *before* tier 3 (39.3 gm) on an unattended house fire. Response degradation therefore costs the player one tier, never the building. This is a hard invariant: any retune of `esc_base[structure_fire]` must re-check it (test 23).

**This band is UNCHANGED by RR-15** *(report 98 §15).* §2.4's weather-keyed `heat_mult` / `rain_mult` constants moved to doc 07's `fire_escalation_mult` channel, but doc 07 **adopted them verbatim** (`CLEAR 1.00 · CLOUDY 1.00 · RAIN 0.80 · HEAVY_RAIN 0.80 · THUNDERSTORM 0.80 · HEAT_WAVE 1.25`, flat at every intensity — doc 07 §2.2.1), so every number above reproduces to the digit. The reference case is CLEAR, where the channel returns **1.00** and `esc_env = 1.250` exactly as before: tier 2 at **21.8 gm**, tier 3 at **39.3 gm** (`21.818 + 17.455 = 39.273`), tier 5 at **66.3 gm**. The 39.1 gm < 39.3 gm margin therefore stands at **0.2 gm**, unmoved, and `esc_base[structure_fire] = 2.20` needs no retune. Ownership moved; calibration did not.

---

## 2. Mechanics

### 2.1 Time, ticks, and the sub-step integrator

- **Incident tick cadence: 1 Hz = every 4 SimTicks = 1 game-minute** (Constitution §4).
- Every quantity below is expressed **per game-hour (`/gh`)**; the tick converts with `dt_h`.
- Online: `IncidentSystem.advance(dt_h = 1/60)`. Offline catch-up: `IncidentSystem.advance(dt_h = 1.0)`.
- **`advance()` never integrates blindly across `dt_h`.** It repeatedly computes the next *discontinuity* and advances only to it:

```
func advance(dt_h):
    remaining = dt_h
    guard = 0
    while remaining > EPS and guard < MAX_SUBSTEPS:      # MAX_SUBSTEPS = 64
        t = min(remaining, next_discontinuity_h())       # never 0; floor at MIN_SUBSTEP_H = 1/3600
        integrate_linear(t)                              # all rates constant over t by construction
        fire_discontinuities()                           # tier entries, arrivals, resolutions, spread rolls
        remaining -= t
        guard += 1
    if remaining > EPS: integrate_linear(remaining)       # guard blown: rare, logged as sim warning
```

`next_discontinuity_h()` = min over: (a) time until any en-route unit arrives, (b) time until any incident's `severity` crosses the next integer tier, (c) time until any incident's `progress` reaches 1.0, (d) time until any burning incident's `burn_timer` reaches `burn_down_hours`, (e) time to the next generation evaluation boundary, (f) time to the next day/night boundary (changes `dark` factors), (g) `SPREAD_ROLL_INTERVAL_H = 1/12` (5 game-minutes) for the next fire-spread roll batch, (h) **time to the next doc 07 weather-segment boundary** — every effect channel is a step function there (doc 07 §2.2; only `precip01` is crossfaded, and that one is the renderer's), so every weather-fed rate in this doc is constant between such boundaries: the four generation channels, §2.4's `fire_escalation_mult` and §2.8's `fire_spread_mult` alike. *(§2.6 already asserted this breakpoint; RR-15 makes two more rates depend on it, so it is now listed explicitly rather than implied.)*

Because all rates are **constant within a tier and between arrivals**, `integrate_linear` is exact. This is what makes the offline and online results identical rather than merely similar.

### 2.2 Incident object & FSM

Fields (spec §33 / §46 superset):

`id, type, subtype, position(x,z), district_id, target_ref, cluster_id, parent_id, severity(float), tier(int, derived), progress(float 0..1), status, created_min, first_assign_min, first_onscene_min, resolved_min, burn_timer_h, assigned[], required_roles[], optional_roles[], cause{}, pinned(bool), priority_cache, notification_priority, seen(bool)`

**States** (`status`):

| state | meaning | entry | exit |
|---|---|---|---|
| `NEW` | created this tick, not yet scored | generator | always → `QUEUED` at end of same tick |
| `QUEUED` | scored, awaiting units | no assigned units | → `ASSIGNED` on assignment; → `ABANDONED` if `self_resolve` timer expires |
| `ASSIGNED` | ≥1 unit assigned, none contributing on scene | assignment | → `ACTIVE` on arrival; → `QUEUED` if all units recalled/lost |
| `ACTIVE` | ≥1 capability-matching unit on scene; `progress` accumulating | arrival of a primary-role unit | → `RESOLVED` at `progress ≥ 1`; → `ASSIGNED` if primary role leaves; → `FAILED` on terminal condition |
| `RESOLVED` | success; rewards paid; units released | `progress ≥ 1.0` | terminal (removed after `KEEP_RESOLVED_MIN = 15` game-min for the UI/report) |
| `FAILED` | terminal consequence fired (burn-down, transformer destroyed, main washout) | `on_fail` condition | terminal |
| `ABANDONED` | self-resolved with no response; penalty applied | `self_resolve_h` elapsed in `QUEUED` at tier < `self_resolve_max_tier` | terminal |

**Only `ACTIVE` accumulates progress. `QUEUED` and `ASSIGNED` accumulate escalation at full rate; `ACTIVE` accumulates escalation at the suppressed rate.**

`tier = clamp(floor(severity), 1, 5)`. `severity ∈ [1.0, 5.0]`, clamped at the top.

### 2.3 Severity model

Initial severity at spawn:

```
severity_0 = clamp( 1.0 + sev_bias[type] + rng_incidents.randf() * sev_spread[type] + context_bonus , 1.0, 4.99 )
```

`context_bonus` per type (all additive, computed at spawn from the cause block):

| type | context_bonus |
|---|---|
| crime | `1.2 * max(0, 0.5 - stability) / 0.5` + `0.3` if district unpowered |
| structure_fire | `0.15 * (building_level - 1)` + `0.4` if hydrant_pressure_ratio < 0.5 |
| transformer_failure | `0.8 * max(0, load_ratio - 1.0)` + `0.5` if no feeder redundancy |
| water_main_break | `0.6 * max(0, pressure_ratio - 1.15)` |
| traffic_accident | `0.5` if intersection unpowered, `+0.4` if injury flag |
| storm_damage | `0.5 * clamp((wind_kph - 60)/40, 0, 1)` |

**Tier semantics (uniform across types, so the UI colour language is one language):**

| tier | label | notification | meaning |
|---|---|---|---|
| 1 | Minor | P3 | contained, no external effect yet |
| 2 | Moderate | P3 | first external effect begins |
| 3 | Serious | P2 | district-level effect; secondary incidents become possible |
| 4 | Severe | P1 | strong district effect; terminal countdown may begin |
| 5 | Critical | P1 | terminal consequence pending |

### 2.4 Escalation math (exact)

```
esc_rate(inc) = esc_base[type]
              * (1 + ESC_TIER_ACCEL * (tier - 1))                # ESC_TIER_ACCEL = 0.25
              * esc_env(inc)
              * difficulty.escalation_mult                       # data/difficulty.json §escalation — rows
                                                                 # authored here, file owned/loaded by doc 03 (C-17)
                                                                 # casual 0.75 / standard 1.0 / hard 1.35 / crisis 1.60

d(severity)/dt_h = esc_rate(inc) * max(0, 1 - assist_ratio(inc))
```

`esc_env` per type (**each doc-06-authored factor** clamps to [0.4, 3.0]):

```
crime            : (1 + 1.5*(1 - stability)) * (1 + 0.20*dark_frac) * (1 + 0.35*outage_frac)
structure_fire   : (1 + 0.010*max(0, wind_kph - 20)) * f_wx_esc * hydrant_penalty
                     f_wx_esc = weather.get_effect("fire_escalation_mult")   # doc 07 §2.2.1 — sole owner (RR-15)
                     hydrant_penalty = 1 + 0.6*max(0, 0.7 - hydrant_pressure_ratio)/0.7
transformer_failure : (1 + 0.30*storm_flag) * (1 + 0.5*max(0, load_ratio - 1.0))
water_main_break : (1 + 0.4*max(0, pressure_ratio - 1.0)) * (1 + 0.5*flood_saturation)
traffic_accident : (1 + 0.6*congestion_index) * (1 + 0.25*dark_frac)
storm_damage     : (1 + 0.015*max(0, wind_kph - 40))
```

**`heat_mult` / `rain_mult` are DELETED — the fire-escalation weather term is doc 07's channel** *(report 98 RR-15, extending RR-4 to the constants RR-4 did not reach).* The two floats this doc used to author inline — `heat_mult = 1.25 if heat_wave` and `rain_mult = 0.80 if rain|heavy_rain|thunderstorm` — were doc-06 numbers keyed by doc 07's weather states, the identical defect shape RR-4 removed from generation. Doc 07 §2.2.1 now publishes them as `fire_escalation_mult`, **adopted verbatim**:

| state | `get_effect("fire_escalation_mult")` | was (doc 06 inline) |
|---|---|---|
| `CLEAR` / `CLOUDY` | **1.00** (flat) | `1.0 × 1.0` = 1.00 |
| `RAIN` / `HEAVY_RAIN` / `THUNDERSTORM` | **0.80** (flat) | `1.0 × 0.80` = 0.80 |
| `HEAT_WAVE` | **1.25** (flat) | `1.25 × 1.0` = 1.25 |

The band endpoints are equal, so the channel is **intensity-invariant** — matching the step-function form of the constants it replaced. Nothing here is a retune: **`esc_base[structure_fire]` stays 2.20, §1.1's band is unchanged, and test 23's hard invariant is untouched.** The wind term stays in doc 06 (it reads doc 07's `wind_kph` directly, per C-53) and `hydrant_penalty` is doc 05/06 physics — only the weather-keyed product moved.

**The channel is passed through unclamped.** The `[0.4, 3.0]` clamp applies to the factors *this doc* authors; re-clamping a doc 07 value would be doc 06 quietly retuning doc 07 (C-57's exact failure mode). At every published value (0.80 / 1.00 / 1.25) the clamp is a no-op anyway, so this costs nothing today and prevents a silent truncation if doc 07 ever widens the row.

`dark_frac` is the **exact fraction of the sub-step that falls in night hours** (night = game-hours 19:00–06:00), computed analytically — this is why coarse and fine steps agree.

**`assist_ratio` — the single unifying quantity:**

```
effective_rate(inc)  = Σ over on-scene, capability-matching units of contribution(unit, inc)
                       capped at RATE_CAP_MULT (= 3.0) × required_rate(inc)
assist_ratio(inc)    = effective_rate(inc) / required_rate(inc)
```

`required_rate` for non-fire types:
```
required_rate = hold_base[type] * (1 + HOLD_TIER_SLOPE * (tier - 1))     # HOLD_TIER_SLOPE = 0.40
```
`required_rate` for `structure_fire` (see §2.8) — **derived from doc 02's `fire_load`, which is already per-level, so there is no separate level slope** *(report 98 C-43 / R-12; `S_req_base[archetype]` and `S_LEVEL_SLOPE` are deleted — the per-archetype-per-level consequence index lives in doc 02 §2.3 `FireLoad`)*:
```
S_req(b)      = S_REQ_ANCHOR (0.50) * ( fire_load(archetype, level) / FIRE_LOAD_ANCHOR (20) ) ^ S_REQ_EXP (0.45)
required_rate = S_req(b) * stage_mult[tier]
```

`contribution(unit, inc)`:
```
base           = unit.resolve_rate[role_for(type)]              # 0 if no capability match
access_factor  = 1.0
                 * (1.15 if a police unit is on scene providing traffic/crowd control else 1.0)
                 * (0.75 if road access to the incident is degraded — doc 10 `access_quality` < 0.6)
water_factor   = hydrant_factor  if type == structure_fire else 1.0
contribution   = base * access_factor * water_factor
```

**Worked escalation example — house fire, no response** *(re-derived through the channel, RR-15; every figure reproduces).*
Wood house L2, wind 45 kph, **CLEAR** (`fire_escalation_mult = 1.00` at every intensity), hydrant ratio 1.0. `esc_base[structure_fire] = 2.2`, difficulty 1.0.

```
wind term       = 1 + 0.010 × max(0, 45 − 20) = 1 + 0.250        = 1.250
f_wx_esc        = get_effect("fire_escalation_mult")  [CLEAR]    = 1.000
hydrant_penalty = 1 + 0.6 × max(0, 0.7 − 1.0)/0.7 = 1 + 0        = 1.000
esc_env         = 1.250 × 1.000 × 1.000                          = 1.250    ← was 1.25, unchanged
```

| tier | rate `/gh` | time in tier (game-min) |
|---|---|---|
| 1 | 2.2·1.00·1.25 = 2.750 | 21.8 (`60/2.750 = 21.818`) |
| 2 | 2.2·1.25·1.25 = 3.438 | 17.5 (`60/3.4375 = 17.455`) |
| 3 | 2.2·1.50·1.25 = 4.125 | 14.5 (`60/4.125 = 14.545`) |
| 4 | 2.2·1.75·1.25 = 4.813 | 12.5 (`60/4.8125 = 12.468`) |

Reaches tier 5 at **66.3 game-minutes** (66 real seconds) after ignition (`21.818 + 17.455 + 14.545 + 12.468 = 66.286`), and tier 3 at **39.3 gm** (`21.818 + 17.455 = 39.273`) — the §1.1 / test 23 invariant, unmoved. An engine arriving at minute 8 with `assist_ratio ≥ 1` freezes severity at 1.36.

*Cross-check — the same fire in a storm, where the moved constant actually bites.* **THUNDERSTORM at intensity 0.77** (doc 07's reference storm): `wind_kph = lerp(30, 85, 0.77) = 72.4`, so the wind term is `1 + 0.010 × 52.4 = 1.524`; `f_wx_esc = 0.80` (flat); hydrant ratio 1.0 → `1.000`.
`esc_env = 1.524 × 0.80 × 1.000 = **1.2192**` → tier-1 rate `2.2 × 1.00 × 1.2192 = 2.68224 /gh` → tier 2 at `60/2.68224 = **22.37 gm**`.
Under the deleted inline constants this was `1.524 × rain_mult 0.80 = 1.2192` — **the identical number**. The storm damping is preserved exactly; only its owner changed.

**Worked partial-suppression example** *(recomputed on the C-43 derivation — the old `0.5·(1+0.35·1)·1.30 = 0.878` used the deleted hand-authored constants).*
Same wood house **L2** fire at tier 3. Doc 02 gives `fire_load(house, L2) = 40`, so
`S_req = 0.50 × (40/20)^0.45 = 0.50 × 2^0.45 = 0.50 × 1.36604 = 0.683020`
`required_rate = 0.683020 × stage_mult[T3] 1.30 = **0.887926**`.
One engine on scene with hydrant ratio 0.4 → `hydrant_factor = 0.25 + 0.75·0.4 = 0.55`, contribution `1.00·1.00·0.55 = 0.55`.
`assist_ratio = 0.55 / 0.887926 = **0.619420**`. Escalation continues at `4.125 × (1 − 0.619420) = 4.125 × 0.380580 = **1.5699 /gh**` — the fire still grows, at **38%** speed. **This is the water-pressure cascade made visible** (Pillar 1).

### 2.5 Resolution math

```
work_required(inc) = W_base[type] * (1 + W_slope[type] * (tier - 1))          # game-hours of nominal work
d(progress)/dt_h   = effective_rate(inc) / work_required(inc)
resolved when progress ≥ 1.0
```

`work_required` is a function of **tier (integer)**, not continuous severity — this keeps `d(progress)/dt` constant between discontinuities and makes §2.1 exact. When an incident crosses a tier boundary, `progress` is **not** reset but `work_required` grows, so effective completion slips backwards proportionally: `progress *= work_required_old / work_required_new`.

**Worked resolution example — transformer failure.** `W_base = 0.90`, `W_slope = 0.30`, tier 2 → `work_required = 0.90·1.30 = 1.17 gh`. One utility truck (`resolve_rate.utility = 1.0`), `required_rate = 1.0·(1+0.4·1) = 1.4` → `assist_ratio = 0.714` (escalation continues at 29% speed — one truck is not enough for a tier-2 transformer). `d(progress)/dt = 1.0/1.17 = 0.855/gh` → 1.17 gh = **70 real seconds** of work, plus travel. Two trucks: `effective_rate = 2.0`, `assist_ratio = 1.43` → escalation halted, work done in 0.585 gh = 35 s.

### 2.6 Generation

Each generator runs on the incident tick and produces an expected count over the sub-step, then draws a Poisson count from its **named** RNG stream:

```
λ_total = Σ over candidates c of λ_c(dt_h)
n = poisson(λ_total, stream_for(type))             # inverse-transform, Knuth for λ < 30
for i in n: pick candidate c with probability λ_c / λ_total   # deterministic weighted pick
```

**RNG stream assignment** (constitution §5; *report 98 C-45 — `crime` was previously unconsumed and crime was illegally drawn from `incidents`*):

| generator | count draw | candidate / target pick |
|---|---|---|
| `crime` | **`crime`** | **`crime`** — district pick *and* the within-district building pick (§2.6a) |
| `structure_fire` | `incidents` | `incidents` |
| `transformer_failure` | `incidents` | `incidents` |
| `water_main_break` | `incidents` | `incidents` |
| `traffic_accident` | `incidents` | `incidents` |
| `storm_damage` | `incidents` | `incidents` |

`failures` remains doc 02/04/05's stream for their own component rolls; `weather` and `director` are doc 07's; `traffic` is **reserved, not deleted** — cosmetic traffic uses a render-local RNG in `game/`, which is legal because constitution §5 governs `sim/` only *(C-45)*. Stream order within a sub-step is fixed by the type order in the table so consumption is deterministic across online and offline paths.

Poisson is additive over time, so `λ` accumulated over 60 one-minute steps equals `λ` over one 60-minute step **whenever the rate factors are constant**; the sub-step integrator guarantees this by breaking at day/night and weather boundaries. Draw *counts* differ between modes only in RNG consumption order, which is acceptable under Constitution §5 (same save + same elapsed time ⇒ same outcome; the mode is itself a function of elapsed time).

Global safety valve: `λ_total *= incident_load_damper` where
`incident_load_damper = clamp(1.0 - 0.06 * max(0, active_incident_count - fleet_size), 0.25, 1.0)`.
This is the anti-death-spiral rule (spec §51 Risk 5) and it is applied identically online and offline.

**Weather enters generation through doc 07's channels only — doc 06 authors no weather constant** *(report 98 RR-4, extending C-57).* The `weather_mults` table (`crime` / `fire` / `transformer` / `traffic`, with its dead `snow` / `blizzard` / `fog` columns) is **deleted from this doc and from `data/incidents.json`**. It was a second statement of a quantity doc 07 already publishes, keyed by discrete state, so it could not express doc 07's intensity lerp and it drifted the moment doc 07 retuned a row. Each generator now names exactly one channel:

| generator | channel consumed | doc 07 §2.2 range (CLEAR → THUNDERSTORM at intensity 1.0) |
|---|---|---|
| `crime` | `weather.get_effect("incident_crime_mult")` | 1.00 → 0.75 |
| `structure_fire` | `weather.get_effect("fire_ignition_mult")` | 1.00 → 3.00 |
| `transformer_failure` | `weather.get_effect("incident_utility_mult")` | 1.00 → 3.50 |
| `traffic_accident` | `weather.get_effect("incident_traffic_mult")` | 1.00 → 2.30 |
| `water_main_break` | — (weather reaches it through doc 05's `freeze_stress` and doc 07's `flood_saturation`) | — |
| `storm_damage` | — (weather reaches it through `wind_kph` and the storm cell) | — |

**Two further channels are consumed outside generation** *(RR-15)*: `fire_escalation_mult` in §2.4's `esc_env[structure_fire]`, and `fire_spread_mult` in §2.8's `rate(target)`. Doc 07 §2.2.1 keeps the three fire channels deliberately distinct — *how often* a fire starts (`fire_ignition_mult`, above), *how fast* one already burning grows (`fire_escalation_mult`), *how readily* it jumps to a neighbour (`fire_spread_mult`) — and **none may be substituted for another**; the six channels doc 06 reads are listed in §5.

**Look for every number in doc 07 §2.2.** The values below are quoted only inside worked examples, always with the state *and the intensity* named, because `get_effect()` returns `lerp(min, max, intensity)` and a bare state is no longer enough to reproduce a figure. **Weather is city-wide global** (C-59), so a weather channel multiplies **every** candidate in the city, never a subset — the worked examples below are computed that way.

#### Generator formulas — the complete MVP catalog

**(a) `crime`** — candidate = district for the **rate**, building for the **position**. Basis: per 1,000 residents. **Both draws use the `crime` RNG stream** *(C-45)*.
```
λ = R_crime_base * (pop_district/1000) * dt_h * f_stab * f_dark * f_police * f_weather
R_crime_base = 0.012
f_stab    = 1 + 3.0 * (1 - stability)^2                      # stability 0..1 (doc 09)
f_dark    = 1 + 0.35 * dark_frac * (1 + 1.5 * outage_frac)
f_police  = clamp(1.4 - 0.6 * police_coverage, 0.5, 1.4)     # coverage_police(pos), doc 02 (C-51)
f_weather = weather.get_effect("incident_crime_mult")        # doc 07 §2.2 — sole owner (RR-4)
```
*Worked:* pop 6,000, stability 0.55, full night, 40% of district unpowered, coverage 0.5, **CLEAR** (`incident_crime_mult = 1.00` at every intensity) →
`f_stab = 1+3·0.45² = 1.6075`, `f_dark = 1+0.35·1.6 = 1.560`, `f_police = 1.10`, `f_weather = 1.00` →
`λ = 0.012·6·1.6075·1.560·1.10 = 0.1986 /gh` = **4.8 crimes/game-day** in that district.

**Target selection inside the district — doc 02's `crime_weight`** *(report 98 C-44).* Doc 06 owns generation; doc 02 owns *attractiveness*. Its per-archetype-per-level `crime_weight` column is adopted verbatim as the within-district weighted pick that places the incident on a specific building:

```
target_weight(b) = crime_weight(archetype, level)      ← doc 02 §2.3 `Crime` column, normative
                 * STATE_ELIGIBLE[b.state]             ← doc 02 §2.12 (on_fire / under_construction ⇒ 0)
pick b with probability target_weight(b) / Σ target_weight   # drawn from the `crime` stream
incident.position = b.centre ; incident.target_ref = {kind:"building", id:b.id}
```

**Doc 06 authors no attractiveness term of its own.** The three situational coefficients doc 02 used to carry (`no_police 1.2`, `night 0.8`, `outage 1.5`) are deleted there because they duplicated `f_police` / `f_dark` / `f_stab` above — the situational signal is applied **once**, here, at district granularity; the archetype signal is applied **once**, there, at building granularity.

*Worked target pick:* a district of 40 L1 houses (weight 1.00 each), 6 L2 stores (4.80), 2 L1 substations (1.50). `Σ = 40·1.00 + 6·4.80 + 2·1.50 = 40 + 28.8 + 3 = 71.8`. P(a store) = `28.8/71.8 = 40.1%` from 12.5% of the buildings; P(a substation) = `3/71.8 = 4.2%` from 4.3% of the buildings. Doc 02's copper-theft intent reaches the dispatch map without doc 06 restating a single constant.

**(b) `structure_fire`** — candidate = building. **Doc 02 owns the base rate; doc 06 applies situational multipliers only** *(report 98 C-42).*

`base_fire_risk_by_archetype` and `level_risk_slope` are **deleted from this doc and from `data/incidents.json`** — they inverted doc 02's ordering (they rated `high_rise` 0.80, *below* `house` at 1.00) and double-weighted ignition. The per-archetype-per-level base rate is doc 02 §2.3's `Fire p/gh` column (`fire_ignition_per_hour`), multiplied by doc 02's own `fire_condition_mult` and `state_fire_mult`. Look for those numbers in **doc 02 §2.3 / §2.7**.

```
λ(b) = R_fire_base * p_ignite_base(b) * dt_h * f_power * f_weather * f_arson

p_ignite_base(b) = fire_ignition_per_hour(archetype, level)   ← doc 02 §2.3, NORMATIVE
                 * fire_condition_mult(b)                     ← doc 02 §2.6 = 1 + 1.5·(1 − condition)^1.5
                 * state_fire_mult(b)                         ← doc 02 §2.12

R_fire_base = 0.40            # recalibrated, R-11 — a dimensionless global scalar, NOT a per-archetype rate
f_power   = 1 + 0.8 * (1 if building unpowered else 0)
f_weather = weather.get_effect("fire_ignition_mult")          # doc 07 §2.2 — sole owner (RR-4)
f_arson   = 1 + 2.0 * max(0, 0.35 - stability)/0.35
```

**Recalibration of `R_fire_base` (R-11).** Target from §1.1: **≈0.76 structure fires per game-day at 300 buildings**, all powered, **CLEAR** weather, stability ≥ 0.35. Doc 07 §2.2 gives `fire_ignition_mult = 1.00 → 1.00` for CLEAR — flat at every intensity — so `f_weather = 1.000` exactly and the calibration below is unaffected by the RR-4 switch to `get_effect()`.

Reference 300-building composition (a 9× scale-up of doc 09's post-C-11 starter mix plus the civic/utility set), with each archetype at its reference level and doc 02's `Fire p/gh`:

| archetype | ref level | count | `fire_ignition_per_hour` | count × rate |
|---|---|---|---|---|
| house | L2 | 170 | 0.00019 | 0.03230 |
| store | L2 | 45 | 0.00038 | 0.01710 |
| apartment | L2 | 30 | 0.00028 | 0.00840 |
| office | L2 | 15 | 0.00026 | 0.00390 |
| high_rise | L1 | 6 | 0.00026 | 0.00156 |
| data_center | L1 | 2 | 0.00060 | 0.00120 |
| police_station | L1 | 6 | 0.00010 | 0.00060 |
| fire_station | L1 | 5 | 0.00006 | 0.00030 |
| substation | L1 | 8 | 0.00070 | 0.00560 |
| power_facility | L1 | 2 | 0.00090 | 0.00180 |
| water_facility | L1 | 6 | 0.00012 | 0.00072 |
| construction_yard | L1 | 5 | 0.00040 | 0.00200 |
| **total** | | **300** | mean **0.00025160** | **Σ = 0.07548 /gh** |

City mean condition 0.90 → `fire_condition_mult = 1 + 1.5·(1 − 0.90)^1.5 = 1 + 1.5·0.0316228 = 1.047434`; all states normal → `state_fire_mult = 1.0`.

```
Σ p_ignite_base = 0.07548 × 1.047434            = 0.0790604 /gh
target          = 0.76 fires/game-day ÷ 24      = 0.0316667 /gh
R_fire_base     = 0.0316667 / 0.0790604         = 0.400540   →  0.40
```

**`R_fire_base = 0.40`** (was 0.00010 against a deleted risk index — the three-order-of-magnitude move is entirely a change of units: the multiplicand is now a real per-hour probability, not a 1.0-centred index).

*Verification:* `λ = 0.40 × 0.0790604 = 0.0316242 /gh` → `× 24 = **0.7590 fires/game-day**` ✓ (target 0.76, −0.1%).

*Worked — thunderstorm with a district blackout (recomputed on doc 07's channel, RR-4).* 60 of the 300 buildings go dark during a **THUNDERSTORM at intensity 0.77** (doc 07 §2.2's own worked intensity). Mean `p_ignite_base` per building = `0.0790604 / 300 = 0.00026353467 /gh`.

`f_weather = get_effect("fire_ignition_mult") = lerp(1.80, 3.00, 0.77) = 1.80 + 1.20×0.77 = **2.724**` — where the deleted table read a flat **1.60** for every thunderstorm regardless of intensity. **The storm is global, so all 300 buildings carry it**; only `f_power` distinguishes the 60 dark ones.

- 240 lit: `0.40 × 240 × 0.00026353467 = 0.02529933 /gh`; `× f_weather 2.724 = **0.06891537 /gh**`
- 60 dark: `0.40 × 60 × 0.00026353467 = 0.00632483 /gh`; `× f_power 1.8 = 0.01138470`; `× f_weather 2.724 = **0.03101192 /gh**`
- city total: `0.06891537 + 0.03101192 = 0.09992729 /gh` = **2.398 fires/game-day**, a **3.16×** lift over the 0.759/day clear baseline.

*(Was 1.044/day at ×1.38. Two corrections compound: the flat 1.60 becomes doc 07's intensity-lerped 2.724, and the storm multiplier now reaches the 240 lit buildings it always should have — weather is city-wide global per C-59, and the old arithmetic applied it only to the blacked-out 20%.)*

The ordering the old table inverted is now correct by construction: an L5 `power_facility` (0.00242/gh) is **16×** more ignition-prone than an L1 house (0.00015/gh), and an L5 high-rise (0.00070) is **4.7×**, exactly as doc 02 authored it.

**(c) `transformer_failure`** — candidate = transformer node (doc 04).
```
λ = R_xf_base * dt_h * f_load * f_cond * f_temp * f_weather
R_xf_base = 0.0012
f_load    = (clamp(load_ratio, 0.20, 1.60) / 0.70)^3
f_cond    = (2 - condition)^2
f_temp    = 1 + 0.9 * max(0, (temp_c - 65) / 35)              # transformer temperature, doc 04
f_weather = weather.get_effect("incident_utility_mult")       # doc 07 §2.2 — sole owner (RR-4)
```
*Worked:* 12 transformers, load_ratio 0.85, condition 0.85, temp 72 °C, **CLEAR** (`incident_utility_mult = 1.00` at every intensity) →
`f_load = (1.2143)³ = 1.790`, `f_cond = 1.15² = 1.3225`, `f_temp = 1.18`, `f_weather = 1.00` →
per node `0.0012·1.790·1.3225·1.18 = 0.003352 /gh`; ×12 = `0.0402 /gh` = **0.97 failures/game-day**.
Push load_ratio to 1.10: `f_load = 3.881` → **2.10/game-day**. Overbuilding demand without capacity is directly, legibly punished.

**(d) `water_main_break`** — candidate = main segment (doc 05 `water.mains()`).

**Doc 06 owns the roll; doc 05's hazard drivers are multiplied in, not replaced** *(report 98 C-46).* Over-pressure alone cannot produce breaks in a well-run system — that was the defect. Doc 05's `cond_mult` and `load_mult` **supersede** doc 06's old `f_cond` (which is deleted; look for the condition curve in doc 05 §2.9), and doc 05's freeze-stress hazard is consumed as an **additive channel** rather than doc 06's old flat `f_freeze = 2.2` step (also deleted).

```
λ_seg = dt_h * [  R_wm_base * length_km * f_press * cond_mult * load_mult * f_ground     # mechanical
                + FREEZE_BREAK_BASE * freeze_stress * (1.2 - condition) ]                # freeze (doc 05)

R_wm_base = 0.0022                                              # doc 06, unchanged
f_press   = 1 + 1.5 * max(0, pressure_ratio - 1.05)             # doc 06 — over-pressure, unchanged
cond_mult = 1.0 + 6.0 * (1 - condition)^2                       # doc 05 §2.9, consumed verbatim
load_mult = 1.0 + 1.5 * max(0, utilization - 0.85) / 0.15       # doc 05 §2.9, consumed verbatim
f_ground  = 1 + 0.5 * flood_saturation                          # doc 06, from doc 07
FREEZE_BREAK_BASE = 0.0020, freeze_stress                       # doc 05 §2.9, consumed verbatim
```

`freeze_stress` and `utilization` join `length_km`, `condition` and `pressure_ratio` on doc 05's `water.mains()` record. The freeze channel is gated by doc 05's `feature_flags.freeze_enabled` (**false** in MVP — the MVP disaster is a thunderstorm); when a break is drawn, `P(frozen) = freeze_term / λ_seg` and a `frozen: true` break inherits doc 05's ×1.6 repair time and 0.80 post-repair condition.

*Worked — healthy system.* 6.0 km of mains at condition 0.80, utilization 0.70, nominal pressure, no freeze, no flood:
`cond_mult = 1 + 6·(0.20)² = 1 + 6·0.04 = 1.24`; `load_mult = 1.00` (0.70 < 0.85 knee); `f_press = 1.00`
`λ = 0.0022 × 6.0 × 1.00 × 1.24 × 1.00 × 1.00 = 0.016368 /gh` = **0.393 breaks/game-day**
*(was 0.46/day under the deleted `f_cond = (2−c)² = 1.44`; doc 05's curve is deliberately flatter near perfect condition.)*

*Worked — neglected and overloaded.* Same 6.0 km at condition 0.50, utilization 0.95, `pressure_ratio` 1.15:
`f_press = 1 + 1.5·(1.15 − 1.05) = 1.15`; `cond_mult = 1 + 6·(0.50)² = 2.50`; `load_mult = 1 + 1.5·(0.10/0.15) = 2.00`
`λ = 0.0022 × 6.0 × 1.15 × 2.50 × 2.00 = 0.0759 /gh` = **1.822 breaks/game-day**
The old formula gave `0.0132 × 1.15 × 2.25 = 0.03416 /gh` = 0.820/day. **The neglected, over-utilised system is now 2.22× worse while the healthy one is 15% better** — which is the correct shape, and it is what makes doc 05's utilization number matter to the player.

**(e) `traffic_accident`** — candidate = intersection node (doc 10).
```
λ = R_acc_base * dt_h * f_flow * f_signal * f_weather * f_dark * f_road_cond
R_acc_base = 0.0020
f_flow      = clamp(congestion_index, 0.05, 2.0)^1.5           # doc 10, 0 = empty, 1 = at capacity
f_signal    = 1.00 powered signal | 3.00 unpowered signal | 1.60 unsignalized
f_weather   = weather.get_effect("incident_traffic_mult")      # doc 07 §2.2 — sole owner (RR-4)
f_dark      = 1 + 0.25 * dark_frac
f_road_cond = max over edges e incident to the node of  roads.condition_hazard_mult(e)
```

**`f_road_cond` is doc 10's `condition_hazard_mult` folded in, per report 98 C-48** — previously absent, which left road maintenance as a pure travel-time tax and stripped half the weight out of the maintenance decision. Doc 10 §2.11 owns the formula and **doc 06 does not rescale it**.

**Road `condition` is on `[0,1]`, like every other condition in the project** *(report 98 RR-3 — C-14's "condition ∈ [0,1] everywhere" applies to roads too; there is no carve-out).* Doc 10 restates the formula on the new scale, and doc 06 quotes the restated form:

```
condition_hazard_mult(e) = 1 + K_ROAD_HAZ (0.4) * max(0, ROAD_HAZ_KNEE (0.75) - condition_e)     # condition_e ∈ [0,1]
```

The knee moves `75 → 0.75` and the coefficient `0.004 → 0.4` (a ×100 compensation), so **every returned multiplier is numerically unchanged** — only the units of the input move. A pristine road at **1.00** returns **1.00**, a road at **0.55** returns **1.08**, a failing road at **0.10** returns **1.26**. The **max** over the node's incident edges is used, not the mean: the collision happens on the worst approach.

*Worked — new roads.* 20 intersections, congestion 0.8, powered signals, CLEAR, day, road condition **1.00**:
`f_flow = 0.8^1.5 = 0.715542`, `f_weather = 1.00`, `f_dark = 1.00`, `f_road_cond = 1.00` → per node `0.0020 × 0.715542 = 0.00143108`, ×20 = `0.0286217 /gh` = **0.687/game-day**.

*Worked — the same city after neglect.* Approaches decayed to condition **0.55** → `f_road_cond = 1 + 0.4·(0.75 − 0.55) = 1 + 0.4·0.20 = 1.08`:
per node `0.00143108 × 1.08 = 0.00154557`, ×20 = `0.0309114 /gh` = **0.742/game-day**. At condition **0.10** (`1 + 0.4·0.65 = 1.26`) it is `0.0360632 /gh` = **0.866/game-day** — deferred resurfacing now buys **+26% accidents** on its own.

*Worked — the outage cascade, on condition-0.55 roads (recomputed on doc 07's channel, RR-4).* Blackout 8 of those 20 signals at night in **RAIN at intensity 0.75**:
`f_weather = get_effect("incident_traffic_mult") = lerp(1.25, 1.45, 0.75) = **1.40**` — the same figure the deleted table carried for `rain`, which it now reproduces only at this one intensity; at intensity 1.0 the storm-free rain case is 1.45. `f_dark = 1 + 0.25·1.0 = 1.25`. **Rain and night are city-wide, so all 20 nodes carry both**; only `f_signal` distinguishes the 8 dark ones.
- the 8 dark nodes: `0.0020 × 0.715542 × f_signal 3.00 × 1.40 × 1.25 × 1.08 = 0.00811424` each → `0.0649139 /gh`
- the 12 lit nodes: `0.0020 × 0.715542 × f_signal 1.00 × 1.40 × 1.25 × 1.08 = 0.00270475` each → `0.0324570 /gh`
- total `0.0973709 /gh` = **2.337/game-day** against the 0.742 day/clear baseline — the district's accident rate **×3.15**, which is the outage→traffic cascade from spec §4 Pillar 1, now compounded by road condition instead of ignoring it.

*(Was 2.003/day at ×2.70. The dark-node arithmetic is unchanged; the correction is on the 12 lit nodes, which the old worked example priced at the day/clear rate `0.00154557` even though the rain and the night fall on the whole city — C-59, weather is global.)*

**(f) `storm_damage`** — candidate = exposed asset. **Doc 06 owns *all* storm damage generation** *(report 98 C-53).*

Three systems used to roll line failures. Doc 04's `h_wind` and doc 07 §2.7.4's per-span wind rolls are **both deleted as generators**, and the proposed `storm_owns_line_failures` flag is unnecessary and deleted with them. The split is now:

| supplier | what it provides | doc 06 uses it as |
|---|---|---|
| **07 Weather** | `weather.current().wind_kph`, `weather.get_storm_cell() → {active, x_t, z_t, radius_t}` | `wind_factor`, and the **cell mask** — only assets inside the cell are candidates |
| **04 Power** | per-component `weather_exposure`, `tree_adjacent`, `condition`, `underground` via `power.exposed_components()` | `exposure_class`, `(2 − condition)`; `underground ⇒ excluded` |
| **05 Water / 02 Buildings** | exposed rooftop mechanical on L4–L5 buildings, above-grade water assets | `exposure_class` rows `rooftop_mech`, `pole` |

```
candidates = { assets a : not a.underground and in_storm_cell(a.tile) }
λ(a) = R_storm_base * dt_h * wind_factor * exposure_class[a] * (2 - a.condition)

R_storm_base = 0.0149                                          # recalibrated, R-13
wind_factor  = max(0, (wind_kph - 40) / 30)^2                  # zero below 40 kph; wind_kph from doc 07
exposure_class = { overhead_span 1.0, pole 0.8, rooftop_mech 0.5, tree_adjacent 1.8 }
subtype drawn: downed_power_line 0.45 | blocked_road 0.35 | roof_damage 0.20
in_storm_cell(t) = active and |t - (x_t, z_t)| <= radius_t     # doc 07 owns the cell; doc 06 only samples it
```

**Recalibration against doc 07's stated outcome targets (R-13).** Doc 07 §2.7.4 publishes two reference outcomes for a **60-span grid over one 120-game-minute (2.0 gh) storm**: a *maintained* grid loses **≈2.5** spans, a *neglected* one **≈12**. Those are now doc 06's targets, and two constants move to hit both simultaneously.

`exposure_class.tree_adjacent` is raised **1.4 → 1.8** to adopt doc 07's `span_factor_tree_adjacent = 1.8` — doc 07 owns storm physics under C-53, and with 1.4 the two target cases cannot be satisfied by any single `R_storm_base` (they demand 0.0149 and 0.0192 respectively). At 1.8 they agree to within 0.6%.

| doc 07 case | `wind_kph` | `wind_factor` | `exposure_class` | `2 − condition` | λ per span `/gh` | × 2.0 gh × 60 spans | doc 07 target |
|---|---|---|---|---|---|---|---|
| maintained, no trees | 70 | `((70−40)/30)² = 1.00` | 1.0 | `2 − 0.60 = 1.40` | `0.0149 × 1.00 × 1.0 × 1.40 = 0.020860` | **2.503** | ≈2.5 ✓ |
| neglected, tree-adjacent | 85 | `((85−40)/30)² = 2.25` | 1.8 | `2 − 0.35 = 1.65` | `0.0149 × 2.25 × 1.8 × 1.65 = 0.099569` | **11.948** | ≈12 ✓ |

```
solve maintained:  2.5 / (60 × 2.0 × 1.40)          = 2.5 / 168.0   = 0.0148810
solve neglected:  12.0 / (60 × 2.0 × 2.25×1.8×1.65) = 12.0 / 801.9  = 0.0149645
R_storm_base = 0.0149        (both, to within 0.6%)
```

**`R_storm_base = 0.0149`** (was 0.020, an uncalibrated guess). Two neglected maintenance decisions still cost **4.8× the crew workload**, exactly as doc 07 designed.

*Worked — small city.* 25 exposed spans at condition 0.85, wind 70 kph, all inside the cell → `wind_factor = 1.0`, `2 − 0.85 = 1.15` →
`λ = 0.0149 × 1.0 × 1.0 × 1.15 × 25 = 0.428375 /gh` → a 3-hour storm yields **≈1.29** damage events.
At 100 kph, `wind_factor = ((100−40)/30)² = 4.0` → `λ = 1.713500 /gh` → **≈5.1 events** across the storm. That is the MVP disaster's teeth (spec §43.4).

### 2.7 Catalog — response, resolution, consequences, rewards

| type | primary role (must be on scene for progress) | support roles | `W_base` / `W_slope` | typical solo resolve | `esc_base` | `hold_base` | self-resolve |
|---|---|---|---|---|---|---|---|
| `crime` | `police` ×1 (×2 at tier ≥3, ×3 at tier ≥4) | — | 0.30 / 0.40 | 18 s @T1 | 0.80 | 1.00 | 2.0 gh, max tier 2 |
| `structure_fire` | `fire` (count implied by `required_rate`) | `police` (access), `construction` (post-fire debris) | 0.30 / 0.45 | 20 s @T1 house | 2.20 | see §2.8 | never |
| `transformer_failure` | `utility` ×1 (×2 at tier ≥3) | `construction` (pole/pad work, +20% rate) | 0.90 / 0.30 | 54 s @T1 | 0.50 | 1.00 | never |
| `water_main_break` | `water` ×1 (×2 at tier ≥3) | `construction` (road cut, +25% rate) | 1.20 / 0.30 | 72 s @T1 | 0.60 | 1.00 | never |
| `traffic_accident` | `police` ×1 | `fire` (extrication, required if `injury`), `construction` (debris, tier ≥3) | 0.35 / 0.35 | 21 s @T1 | 0.70 | 1.00 | 1.0 gh, max tier 2 |
| `storm_damage/downed_power_line` | `utility` ×1 | `construction` | 0.70 / 0.30 | 42 s @T1 | 0.40 | 1.00 | never |
| `storm_damage/blocked_road` | `construction` ×1 | — | 0.50 / 0.25 | 30 s @T1 | 0.30 | 1.00 | 6.0 gh, max tier 2 |
| `storm_damage/roof_damage` | `construction` ×1 | — | 0.80 / 0.25 | 48 s @T1 | 0.35 | 1.00 | never |

**Escalation consequences** — declarative `on_tier_enter` action lists (fired once per tier, recorded in the incident so a save/load cannot re-fire them):

| type | T2 | T3 | T4 | T5 | `on_fail` (terminal) |
|---|---|---|---|---|---|
| `crime` | district `stability −0.010` | `stability −0.025`; `confidence −0.01`; notify P2 | `stability −0.045`; spawn 1 extra `crime` in district | `stability −0.070`; spawn 2 extra `crime`; set district `unrest_flag` for 4 gh | held at T5 for 1.0 gh → `ABANDONED`: `stability −0.10`, spawn `structure_fire` (arson) on a random district building with `severity_0 = 2.0` |
| `structure_fire` | `condition −0.10`; occupants evacuate (tax output → 0); spread rolls begin at `g_stage 0.35` (§2.8) | spread rate ×2.9 (`g_stage` → 1.00); `stability −0.02`; notify P2 | `condition −0.25`; adjacent-building spread rate ×1.8; notify P1 | structural involvement; `burn_timer` starts | `burn_timer ≥ 0.5 gh` → `FAILED`: building **destroyed** via `destroy_building` (guarded — see below; the verb calls **doc 02** `buildings.destroy(id, cause)`, **doc 03** prices the rebuild), population loss = building occupants ×`FIRE_FATALITY_FRACTION 0.02` + displacement, `stability −0.12`, `confidence −0.05`, spawn `storm_damage/blocked_road`-class **debris** incident on site |
| `transformer_failure` | feeder load shed 25% (doc 04) | feeder **offline** → district outage begins; all downstream street lighting off | outage widens to sibling feeder if no redundancy; `stability −0.03` | transformer thermal runaway; `burn_timer` starts | `burn_timer ≥ 0.4 gh` → `FAILED`: transformer **destroyed** (doc 06 supplies `damage_fraction = 1.0`; doc 04 owns the component, **doc 03** prices the replacement per C-16), 30% chance to spawn `structure_fire` on nearest building, feeder out until replaced |
| `water_main_break` | segment isolated: `pressure_ratio −0.15` in zone | zone pressure `−0.35`; **hydrant_factor in zone drops** → active fires suppress slower | road surface damaged → doc 10 `edge_speed_mult 0.5` on that segment | zone pressure `−0.60`; `stability −0.04` | held at T5 for 1.0 gh → `FAILED`: washout — road segment **closed** (doc 10), spawn `storm_damage/blocked_road`, zone pressure `−0.8` until repaired, `stability −0.06` |
| `traffic_accident` | doc 10 `edge_speed_mult 0.6` on segment | segment `edge_speed_mult 0.3`; congestion propagates | segment **closed** (doc 10); `stability −0.01` | secondary collision: spawn 1 more `traffic_accident` on an adjacent edge | `ABANDONED` after `self_resolve_h`: segment closed for 1.0 gh, `confidence −0.01` |
| `storm_damage/downed_power_line` | feeder capacity `−30%` | feeder **offline** | 25% chance to spawn `structure_fire` at nearest building | live-line hazard: adjacent edges closed | `FAILED` at T5 held 1.0 gh: feeder destroyed, treated as `transformer_failure` fail |
| `storm_damage/blocked_road` | `edge_speed_mult 0.5` | segment closed | reroute pressure raises district congestion `+0.2` | — | `ABANDONED`: segment stays closed until a construction crew is dispatched manually |
| `storm_damage/roof_damage` | building `condition −0.05` | `condition −0.12`; water ingress; tax output ×0.7 | `condition −0.25` | — | `FAILED` at T5 held 2.0 gh: building condition floored at 0.2, requires a full **doc 02** repair project priced by **doc 03** |

**Zone pressure on a main break (report 98 C-46).** Doc 06's **tiered** `zone_pressure_delta` in the `water_main_break` row above (`−0.15 / −0.35 / −0.60 / −0.80` at T2/T3/T4/T5) **stands and is authoritative** — a break that has been open for an hour must hurt more than one that just started, which a flat penalty cannot express. Doc 05's `break_pressure_penalty = 0.12 × severity` is retained there only as the fallback for breaks doc 06 does not own; in MVP there are none, so it never fires.

**The `destroy_building` guard (report 98 C-47).** Doc 08 fairness rule 4 forbids any destruction while the player is offline and clamps the outcome to condition 0.15 with the incident left open. That clamp stands — a player arriving to a building *still burning* is the better drama. But the refusal must be **visible**, not silently swallowed by `OfflineGuard`, so the cascade op checks first:

```
op destroy_building(target):
    if not world.destroy_allowed():                       # false whenever ctx.is_offline (doc 08 rule 4)
        buildings.apply_condition_delta(target, to: OFFLINE_DESTROY_CLAMP_CONDITION (0.15))
        inc.burn_timer_h = FIRE_BURN_DOWN_H               # frozen at the threshold; does not re-arm
        inc.status stays ACTIVE/ASSIGNED at tier 5        # incident is NOT resolved and NOT failed
        emit destroy_refused_offline{incident_id, target, reason:"offline"}
        return REFUSED
    buildings.destroy(target, cause: inc.id)              # doc 02 removes it; doc 03 books the loss
    return DONE
```

The same guard covers `feeder_destroy` and any future terminal verb. Online, `destroy_allowed()` is unconditionally `true`. Test 20b asserts the offline branch fires exactly once and leaves the incident open.

**Rewards & penalties.**

```
reward = reward_base[type] * (1 + 0.35 * (tier_peak - 1)) * speed_bonus
speed_bonus = clamp(1.5 - 0.5 * (response_minutes / target_response_min[type]), 0.60, 1.50)
response_minutes = first_onscene_min - created_min

cost_dispatch  = Σ over responding units of  economy.vehicle_dispatch_cost(type)   # doc 03 §2.13(c)
cost_materials = economy.repair_cost(inc.target_ref, damage_fraction(inc))         # doc 03 §2.5
net = reward - cost_dispatch - cost_materials      # may be negative; crises cost money by design
```

**All three money terms above are doc 03's** *(report 98 C-07 / C-16 / R-14).* Doc 06's `repair_material_base` column is **deleted** — it was a second repair price table. Doc 06 supplies only `damage_fraction ∈ [0,1]` (§2.8), and doc 03 computes `capital_value × damage_fraction × REPAIR_COST_PER_CAPITAL (0.85) × M_repair`. Look for the numbers in **doc 03 §2.5** and `data/economy.json`.

| type | `reward_base` | `target_response_min` | stability on resolve |
|---|---|---|---|
| crime | 350 | 8 | +0.010 |
| structure_fire | 900 | 6 | +0.020 |
| transformer_failure | 600 | 12 | +0.015 |
| water_main_break | 500 | 15 | +0.015 |
| traffic_accident | 300 | 7 | +0.008 |
| storm_damage (any) | 400 | 15 | +0.010 |

*Worked (recomputed on doc 03's ladder, R-14):* tier-3 structure fire in a **house L2**, one engine, on scene at minute 5, resolved with `burn_timer = 0`.
- `speed_bonus = clamp(1.5 − 0.5·(5/6), 0.60, 1.50) = 1.083333`
- `reward = 900 × (1 + 0.35·2) × 1.083333 = 900 × 1.70 × 1.083333 = **$1,657**`
- `cost_dispatch = 1 × fire_engine.dispatch_cost` — doc 03 `$29` (was doc 06's deleted `$220`) → **$29**
- `damage_fraction = 0.10·(3 − 1) + 0.30·0.0 = 0.20`; doc 03 `capital_value(house, L2) = $2,940` →
  `cost_materials = round(2,940 × 0.20 × 0.85 × M_repair 1.00) = **$500**` (was `250 × 3 = $750`)
- **net = 1,657 − 29 − 500 = +$1,128**, plus `stability +0.020` and a saved building.

Let it burn down instead and the player loses the whole `capital_value` and pays doc 03 for a rebuild — a **$2,940** capital write-off against a **$500** repair. The ratio, not the magnitude, is the design: *responding is always cheaper than replacing.*

### 2.8 Fire spread & suppression (spec §17)

**Growth stages** map 1:1 onto tiers so there is one severity language:

| tier | stage | spread multiplier `g_stage` | `stage_mult` (suppression demand) |
|---|---|---|---|
| 1 | Incipient | 0.00 | 0.60 |
| 2 | Growing | 0.35 | 0.90 |
| 3 | Fully involved | 1.00 | 1.30 |
| 4 | Structural | 1.80 | 1.80 |
| 5 | Conflagration | 3.00 | 2.40 |

**Spread.** Every `SPREAD_ROLL_INTERVAL_H = 1/12 gh` (5 game-minutes), for each burning incident at tier ≥ 2 (`g_stage` is 0 at tier 1, so tier-1 fires never spread), each non-burning building whose centre is within `SPREAD_RADIUS_M = 40` is evaluated as a **hazard rate**, then converted to a probability for the interval:

```
rate(target) = P_spread_base * g_stage[tier] * g_dist * g_wind * g_density * g_mat * g_weather
             * (1 - clamp(assist_ratio, 0, 1))
P_spread_base = 0.30 /gh
g_dist    = clamp( exp( -(d_m - MIN_GAP_M) / D0 ), 0, 1 )      # MIN_GAP_M = 6, D0 = 12
g_wind    = 1 + 1.2 * (wind_kph / 60) * max(0, cos θ)          # θ = angle(wind_dir, bearing to target)
g_density = 1 + 0.5 * (neighbours_within_24m / 6)
g_mat     = spread_material_mult[target.archetype]
g_weather = weather.get_effect("fire_spread_mult")             # doc 07 §2.2 — sole owner (RR-15)

p_interval = 1 - exp( -rate * SPREAD_ROLL_INTERVAL_H )
```

**`g_weather` is new — doc 07's `fire_spread_mult` finally has its consumer** *(report 98 RR-15).* Doc 07 has published this channel for all six MVP states since its first draft (`CLEAR 1.00→1.10`, `CLOUDY 0.95→0.95`, `RAIN 0.70→0.55`, `HEAVY_RAIN 0.50→0.35`, `THUNDERSTORM 0.60→0.45`, `HEAT_WAVE 1.35→1.70`) and **nothing read it** — a published channel with no consumer is a spec that cannot be wrong, which is why the closing audit caught it. Doc 06 now multiplies it in. Two contract notes carried over from doc 07 §2.2.1, both load-bearing:

1. **No wind double-count.** `fire_spread_mult` is a *fuel-moisture and ambient-heat* term — a wet roof does not catch, a sun-baked one does. **Wind reaches spread exactly once**, through doc 06's own `g_wind`, which reads doc 07's `wind_kph`. `g_weather` and `g_wind` are orthogonal by construction, and a test asserts it (test 42).
2. **Unlike escalation, this channel is intensity-lerped.** A bare state name no longer reproduces a spread figure; every worked value below names the **state and the intensity**, and takes `wind_kph` from that state's own band so the example is a situation the weather system can actually produce. As with `f_wx_esc`, doc 06 passes the value through **unclamped** — it is doc 07's number.

Using a **hazard rate** (not a flat per-tick probability) is what makes fine and coarse stepping agree: `P(no ignition over 1 gh) = exp(-rate)` whether evaluated once or twelve times. `g_weather` is constant within a sub-step (weather state and intensity are step functions at segment boundaries — doc 07 §2.2), so it does not disturb that exactness; §2.1's discontinuity list already breaks at weather boundaries.

*Worked — re-derived under RR-15.* Fully-involved (T3) apartment fire, unsuppressed, wind blowing straight at a wooden house **14 m** away (`cos θ = 1`), 4 neighbours within 24 m. The geometry terms are weather-independent:
`g_stage = 1.00`; `g_dist = exp(-(14-6)/12) = exp(-0.666667) = 0.513417`; `g_density = 1 + 0.5·(4/6) = 1.333333`; `g_mat[house] = 1.40`.

The **50 kph** of the pre-RR-15 example is only reachable in a `THUNDERSTORM` (doc 07's `wind_kph` bands: CLEAR 5→15, CLOUDY 8→20, RAIN 10→25, HEAVY_RAIN 15→40, THUNDERSTORM 30→85), at intensity `(50 − 30)/55 = 0.363636`. So the direct successor of the old figure is a storm, and the storm now damps it:

```
g_wind    = 1 + 1.2 × (50/60) × 1                              = 2.000000
g_weather = lerp(0.60, 0.45, 0.363636) = 0.60 − 0.15×0.363636  = 0.545455
rate(pre-RR-15) = 0.30 × 1.000 × 0.513417 × 2.000000 × 1.333333 × 1.40            = 0.575027 /gh
rate(post)      = 0.575027 × 0.545455                                             = 0.313651 /gh
p_5min = 1 − exp(−0.313651/12) = 1 − exp(−0.0261376) = 1 − 0.974201 = **2.58%**   (was 4.68%)
p_1gh  = 1 − exp(−0.313651)    = 1 − 0.730772          = **26.9%**                (was 43.7%)
```

*(The pre-RR-15 line printed **0.5746**; the exact product is **0.575027** — the 0.4‰ gap is the old example's 3-decimal rounding of `g_dist` to 0.513, not a calibration change. Its 4.68% / 43.7% are reproduced by the unrounded value to 0.01 pp.)*

Put one engine on it (`assist_ratio 1.0`) and the rate goes to **zero**, in any weather.

**The same fire in four weathers** — each state at a stated intensity, with `wind_kph` taken from that state's own band, so both `g_wind` and `g_weather` move. This is the table that shows what RR-15 bought: **rain damps spread and heat drives it**, and neither used to be true.

| state · intensity | `wind_kph` | `g_wind` | `g_weather` | `rate /gh` | `p` per 5-min roll | `p` over 1 gh |
|---|---|---|---|---|---|---|
| `CLEAR` 0.50 | 10.0 | 1.200000 | `lerp(1.00,1.10,0.5)` = **1.050000** | 0.362267 | 2.97% | **30.4%** |
| `HEAT_WAVE` 0.80 | 10.2 | 1.204000 | `lerp(1.35,1.70,0.8)` = **1.630000** | 0.564251 | 4.59% | **43.1%** |
| `THUNDERSTORM` 0.3636 | 50.0 | 2.000000 | `lerp(0.60,0.45,0.3636)` = **0.545455** | 0.313651 | 2.58% | **26.9%** |
| `THUNDERSTORM` 0.77 *(doc 07 reference storm)* | 72.4 | 2.448000 | `lerp(0.60,0.45,0.77)` = **0.484500** | 0.341007 | 2.80% | **28.9%** |

Arithmetic for the last row, which is the one doc 07 asked for by name: `wind_kph = lerp(30, 85, 0.77) = 72.4` → `g_wind = 1 + 1.2×(72.4/60) = 1 + 1.448 = 2.448`; `0.30 × 0.513417 × 2.448 × 1.333333 × 1.40 = 0.703833 /gh` before weather; `× 0.4845 = 0.341007 /gh`. **Doc 07's reference storm therefore cuts spread to 48.45% of its dry-air value** — `p_1gh` 50.5% → **28.9%** on this geometry — while the *same* storm raises ignition 2.724× (§2.6(b)) and leaves escalation at 0.80 (§2.4). Three questions, three answers, three channels: a thunderstorm starts many more fires, grows each one slightly slower, and stops them jumping. That reads correctly, and no single channel could have said it.

Note the heat wave beats the raw-wind thunderstorm (0.564 vs 0.314 /gh) despite carrying **one seventh** the wind: dry fuel outweighs a gale, which is the fuel-moisture semantics doc 07 §2.2.1 note 1 asks for.

**Ratios inside §2.7's cascade rows are unaffected.** `g_weather` is a common factor across all targets of a given fire, so the tier-2→tier-3 step (`g_stage 0.35 → 1.00`, i.e. spread rate **×2.9**) and the tier-4 adjacency bonus (**×1.8**) are unchanged in every weather.

A spread ignition creates a **new** `structure_fire` incident with `severity_0 = 1.0 + 0.25·(parent_tier - 2)`, `parent_id` = source, and the same `cluster_id` (the parent's, allocated on first spread).

**Suppression — `S_req` is derived from doc 02's `fire_load`** *(report 98 C-43 / R-12).*

`S_req_base_by_archetype` (twelve hand-authored constants) and `S_LEVEL_SLOPE = 0.35` are **deleted from this doc and from `data/incidents.json`**. They were a second, independent statement of how consequential a building is, and they did not carry doc 02's deliberate 56× spread between an L1 house and an L5 high-rise into the dispatch math. The consequence index now enters through exactly one number — doc 02 §2.3's `FireLoad` column:

```
S_req(b) = S_REQ_ANCHOR (0.50) * ( fire_load(archetype, level) / FIRE_LOAD_ANCHOR (20) ) ^ S_REQ_EXP (0.45)
required_rate(fire) = S_req(b) * stage_mult[tier]
contribution(engine) = engine.suppression * hydrant_factor * access_factor
hydrant_factor = clamp( 0.25 + 0.75 * hydrant_pressure_ratio, 0.25, 1.15 )
```

`hydrant_pressure_ratio` comes from **doc 05** as `water.hydrant_pressure_ratio(position) -> float ∈ [0, 1.2]`. Pressure 0 (dead water system) still leaves `0.25` — tank water on the engine — so fire response degrades rather than becoming impossible.

**Calibration anchors and the exponent (R-12).** Doc 02's `k_fire_load = 2.00` doubles `fire_load` every level, so each level multiplies `S_req` by `2^0.45 = 1.366040`.
- `house` L1: `fire_load 20` → `0.50 × (20/20)^0.45 = **0.500**` — the anchor, exact.
- `high_rise` L5: `fire_load 1120` → `0.50 × 56^0.45 = 0.50 × 6.118958 = **3.060**`.

> **Ruled: the exponent stays at 0.45 and `high_rise` L5 lands at 3.06, not 3.60.** Report 98 C-43 publishes the formula `0.50 × (fire_load/20)^0.45` *and* describes it as yielding "≈3.6"; those two statements are arithmetically incompatible (hitting 3.60 requires `ln(7.2)/ln(56) = 0.4904`, and doc 02's suggested 0.474 yields 3.37). Doc 02 §2.7 explicitly hands the final calibration constant to doc 06 under R-12. Doc 06 keeps the **published formula** over the **derived-figure gloss**, because (a) the formula is stated identically in the report and in the amended doc 02, (b) the exact anchor `house L1 = 0.50` is satisfied to the digit, and (c) doc 02 test 24 already asserts `S_req_base(1120) == 3.06 ± 0.01`. The 3.60 figure is the *old* hand-authored model's L5 value (`1.50 × 2.40`); the new derivation lands 15% below it, softening the largest fire in the game by exactly one engine. If the overseer wants the old value preserved to the digit, the single-constant change is `S_REQ_EXP: 0.45 → 0.4904`.

**`S_req` — all 60 rows, generated** from `S_req = 0.50 × (fire_load/20)^0.45` against doc 02 §2.3's `FireLoad` column:

| archetype | L1 | L2 | L3 | L4 | L5 |
|---|---|---|---|---|---|
| `house` | 0.500 | 0.683 | 0.933 | 1.275 | 1.741 |
| `apartment` | 0.720 | 0.984 | 1.344 | 1.836 | 2.508 |
| `store` | 0.553 | 0.755 | 1.032 | 1.409 | 1.925 |
| `office` | 0.683 | 0.933 | 1.275 | 1.741 | 2.378 |
| `high_rise` | 0.879 | 1.200 | 1.640 | 2.240 | 3.060 |
| `data_center` | 0.933 | 1.275 | 1.741 | 2.378 | 3.249 |
| `police_station` | 0.600 | 0.820 | 1.120 | 1.530 | 2.090 |
| `fire_station` | 0.553 | 0.755 | 1.032 | 1.409 | 1.925 |
| `power_facility` | 0.984 | 1.344 | 1.836 | 2.508 | 3.426 |
| `substation` | 0.788 | 1.077 | 1.471 | 2.009 | 2.745 |
| `water_facility` | 0.553 | 0.755 | 1.032 | 1.409 | 1.925 |
| `construction_yard` | 0.755 | 1.032 | 1.409 | 1.925 | 2.630 |

*Spot check, `power_facility` L5:* `fire_load 1440` → `0.50 × (1440/20)^0.45 = 0.50 × 72^0.45 = 0.50 × 6.852290 = **3.426**` ✓. *Column check:* because `k_fire_load = 2.00`, each column is exactly `2^0.45 = 1.366040 ×` the one to its left (rows are computed directly from `fire_load` and rounded once, so the printed digits may differ by 1 ulp from a chained multiply).

*Suppression sizing (engines needed for `assist_ratio ≥ 1` at `hydrant_factor 1.0`, `engine.suppression 1.00`). The level term is inside `S_req` now, so the only multiplier left is `stage_mult`: T2 0.90, T3 1.30, T4 1.80.*

| building | L1 T2 (×0.90) | L3 T3 (×1.30) | L5 T4 (×1.80) |
|---|---|---|---|
| `house` | 0.500·0.90 = 0.450 → **1** | 0.933·1.30 = 1.213 → **2** | 1.741·1.80 = 3.134 → **4** |
| `store` | 0.553·0.90 = 0.498 → **1** | 1.032·1.30 = 1.341 → **2** | 1.925·1.80 = 3.465 → **4** |
| `apartment` | 0.720·0.90 = 0.648 → **1** | 1.344·1.30 = 1.747 → **2** | 2.508·1.80 = 4.514 → **5** |
| `office` | 0.683·0.90 = 0.615 → **1** | 1.275·1.30 = 1.657 → **2** | 2.378·1.80 = 4.281 → **5** |
| `high_rise` | 0.879·0.90 = 0.791 → **1** | 1.640·1.30 = 2.131 → **3** | 3.060·1.80 = 5.507 → **6** |
| `data_center` | 0.933·0.90 = 0.840 → **1** | 1.741·1.30 = 2.263 → **3** | 3.249·1.80 = 5.848 → **6** |

A level-5 high-rise at tier 4 needs **six** engines (the deleted model said seven) — still far beyond the MVP fleet, and unreachable if hydrant pressure is degraded. **That is the intent** (spec §17: "A Level 5 high-rise fire must be significantly more consequential than a Level 1 house fire"): vertical growth must be paid for with fire capacity, not just power and water. The designed answer is (a) never let a high-rise fire reach tier 4 — a 1-engine response at tier 1–2 now holds it, where the old table demanded 2 — and (b) post-MVP ladder trucks, which contribute `2.0` for `level ≥ 3` buildings: `2 ladders (4.0) + 2 engines (2.0) = 6.0 ≥ 5.507` still brings the same fire down to **four units**.

**Burn-down.** While `tier == 5` and `assist_ratio < 0.5`, `burn_timer += dt_h`. At `burn_timer ≥ FIRE_BURN_DOWN_H (0.50 gh = 30 s)` the incident goes `FAILED` and the guarded `destroy_building` op (§2.7) runs — **doc 02** removes the building, **doc 03** books the capital loss, and offline the op is refused and clamped instead (C-47). If the fire is resolved before that, residual damage:
```
damage_fraction = clamp( 0.10*(tier_peak - 1) + 0.30*burn_timer_h , 0, 0.95 )
buildings.apply_condition_delta(id, -damage_fraction)     # doc 02 applies it
economy.repair_cost(target, damage_fraction)              # doc 03 prices it (C-16); doc 06 prices nothing
```

### 2.9 Dispatch — priority scoring

Recomputed for every non-terminal incident each incident tick (cached in `priority_cache`).

```
priority(inc) = W_TYPE * type_priority[type]
              + W_SEV  * (severity - 1.0)
              + W_WAIT * min(wait_hours, WAIT_CAP)
              + W_EXP  * exposure(inc)
              + W_LIFE * life_safety(inc)
              - W_COV  * coverage(inc)
              + (PIN_BONUS if inc.pinned else 0)
              + CLUSTER_BONUS * max(0, cluster_size - 1)

W_TYPE 60, W_SEV 45, W_WAIT 30, WAIT_CAP 3.0, W_EXP 70, W_LIFE 120, W_COV 90,
PIN_BONUS 500, CLUSTER_BONUS 25
type_priority: structure_fire 5, transformer_failure 4, water_main_break 3,
               traffic_accident 3, storm_damage 3, crime 2
coverage(inc) = clamp(assigned_effective_rate / required_rate, 0, 1)
life_safety(inc) = 1 if (structure_fire with occupants and tier ≥ 2) or (traffic_accident with injury) else 0
```

`exposure(inc) ∈ [0,1]`:
```
structure_fire      : clamp( (occupants + 0.4*Σ occupants of buildings within 24 m) / 400, 0, 1 )
transformer_failure : clamp( customers_downstream / 800, 0, 1 ) + 0.35 if a critical facility
                      (hospital / water pump / fire station) is downstream        [clamped to 1]
water_main_break    : clamp( customers_downstream / 800, 0, 1 ) + 0.30 if the zone has an active fire
traffic_accident    : clamp( congestion_index_of_edge / 1.5, 0, 1 )
crime               : 0.6 * clamp(district_pop/6000, 0, 1) + 0.4 * (1 - stability)
storm_damage        : exposure of the underlying asset, per the rows above
```

**Worked ordering** (the moment that defines the game):
- High-rise fire, T3, 320 occupants, waiting 0.2 gh, unstaffed → `60·5 + 45·2 + 30·0.2 + 70·0.85 + 120 = 575.5`
- Transformer failure T2 feeding a hospital, waiting 0.5 gh → `60·4 + 45·1 + 30·0.5 + 70·1.0 = 370.0`
- Crime T4, district pop 5,000, stability 0.30, waiting 1.5 gh → `60·2 + 45·3 + 30·1.5 + 70·0.78 = 354.6`
- Traffic accident T1, injury, waiting 0.1 gh → `60·3 + 45·0 + 3 + 70·0.5 + 120 = 338.0`

Fire first, hospital's transformer second, riot-adjacent crime third. That reads correctly to a human, which is the test.

### 2.10 Dispatch — assignment algorithm

Runs each incident tick, after scoring. Deterministic: all iteration is over id-sorted arrays; all ties break on ascending `unit_id`.

```
1. queue = incidents with status in {QUEUED, ASSIGNED, ACTIVE} and coverage < 1.0,
           sorted by priority DESC, then created_min ASC, then id ASC
2. assignments_made = 0
3. for inc in queue:
     if assignments_made >= MAX_ASSIGNMENTS_PER_TICK (16): break
     if not policy_allows_auto_dispatch(inc): continue          # §2.12 — skipped for manual commands
     for need in unmet_needs(inc):                              # primary role first, then supports
        best = null; best_cost = INF
        for unit in fleet where unit.has_capability(need.role)
                            and unit.status in {IDLE, RETURNING, RESPONDING}
                            and not unit.manual_lock:
            if unit.status == RESPONDING:
                if priority(inc) - priority(unit.incident) < REASSIGN_THRESHOLD (120): continue
            if unit.status == ON_SCENE:  continue                # never strip an on-scene unit automatically
            c = eta_minutes(unit, inc)
                + REASSIGN_PENALTY (12)   if unit.status == RESPONDING
                + RESERVE_PENALTY (45)    if taking it breaks a station reserve (§2.12)
                + ROLE_FIT_PENALTY (30) * (1 - unit.role_fit[need.role])
            if c < best_cost: best = unit; best_cost = c
        if best != null and best_cost <= MAX_ACCEPTABLE_COST (90):
            assign(best, inc); assignments_made += 1
```

`unmet_needs(inc)` returns the primary role until `assigned_effective_rate ≥ required_rate(inc)`, then support roles listed in the catalog, then stops. This is what produces multi-unit responses without a separate "alarm level" concept: **a bigger fire simply keeps asking for engines until the requirement is met.**

**Travel time is authoritative from doc 10, and is the same number online and offline:**

```
eta_minutes(unit, inc) = turnout_min[vehicle_type]
                       + roads.route_minutes(unit.position_node, nearest_node(inc.position), profile)
profile = { speed_mpgm, siren: true, ignores_closures: false }
```

**`RouteProfile` carries no `weather_mult` and no `flood_mult`** *(report 98 C-49 — both fields are deleted).* Doc 10 already applies weather through `wx_resist` per route class (fed by doc 07's `road_speed_mult` channel) and flooding through its closure table; carrying them again in the profile double-counted both, and the double-count grew with storm intensity — exactly when the response time matters most. A genuine per-vehicle exception (a future high-clearance flood truck) becomes a **named capability** on the profile, e.g. `capabilities: ["high_clearance"]`, which doc 10 interprets against its own closure rules — never a raw multiplier handed across the boundary.

**Required interface from doc 10:** `route_minutes(a, b, profile) -> float` MUST be a pure function of (road-graph version, congestion snapshot, profile) and MUST return the identical value in the online and offline paths. Doc 10 is expected to implement this as a cached node→node cost with congestion quantised to 0.05 steps. **The sim's arrival time is this number; the renderer animates the vehicle along the real polyline stretched to hit it** (Constitution §3: renderer follows sim, never the reverse). If a route does not exist, `route_minutes` returns `INF`, the unit is skipped, and the incident is flagged `unreachable` for the UI.

**Player manual override** (commands in §4):
- `cmd_dispatch_unit(unit_id, incident_id)` — bypasses all scoring and all policy; sets `unit.manual_lock = true`. The auto-dispatcher will never reassign or recall a manually-locked unit. Lock clears when the unit returns to `IDLE`.
- `cmd_recall_unit(unit_id)` — unit → `RETURNING`, releases its contribution immediately.
- `cmd_pin_incident(incident_id, bool)` — adds `PIN_BONUS 500` to priority; survives save/load.
- `cmd_set_policy(key, value)` — §2.12.
Manual commands are applied **before** the auto-dispatcher runs in the same tick, so the player always wins the tie.

### 2.11 Vehicle model & FSM

**Speed is expressed in metres per game-minute (`speed_mpgm`).** Because the constitution fixes 1 game-minute = 1 real second, this single number is simultaneously the sim's travel-time input and the renderer's on-screen speed in m/s — sim and render cannot drift. It is a **gameplay-time constant, not a physical speed**; see §9.

```
effective_speed = speed_mpgm                            # doc 06 owns this, and only this
                * (siren_mult if status == RESPONDING else 1.0)
                ... then doc 10 applies road class, congestion, weather and closures
                    inside route_minutes(); doc 06 never multiplies them itself
```

**Doc 06 authors no `weather_speed_mult` and no `flood_mult` table** *(report 98 C-49; the tables are deleted from §8).* Weather reaches travel time exactly once, through doc 07's `get_effect("road_speed_mult")` channel consumed by doc 10; flooding reaches it exactly once, through doc 10's closure table. `road_class_mult` is likewise **doc 10's** (its R-1 ruling: "doc 10 publishes no absolute vehicle speed — only `road_class_mult`"), so doc 06 stops restating `arterial 1.25 / local 1.00 / alley 0.80`.

**MVP vehicle roster.** **Prices are absent by ruling** *(report 98 C-07 / R-14).* Doc 06's `purchase_cost`, `upkeep_per_game_hour` and `dispatch_cost` columns are **deleted** — doc 03 is the sole currency authority. Look for them in **doc 03 §2.13(c)** and `data/economy.json` → `expenses.vehicles`. Doc 03 preserved doc 06's *ratios* (patrol < water < utility < construction < engine, with `fire_engine = 1.60 × patrol_car`) while compressing the magnitudes onto its own ladder; the `economy_id` column below is the join key.

| type | `economy_id` (doc 03) | dept | `speed_mpgm` | `siren_mult` | `turnout_min` | `refit_min` | capabilities | resolve rates | `suppression` |
|---|---|---|---|---|---|---|---|---|---|
| `police_patrol` | `patrol_car` | police | 32 | 1.25 | 1.0 | 0 | `police`, `traffic_control`, `crowd_control` | police 1.00, traffic 0.90 | — |
| `fire_engine` | `fire_engine` | fire | 26 | 1.25 | 1.5 | 6 | `fire_suppression`, `rescue_basic`, `traffic_control(0.5)` | fire 1.00, traffic 0.50, rescue 1.00 | 1.00 |
| `utility_service_truck` | `utility_service_truck` | utility | 24 | 1.15 | 2.0 | 0 | `electrical_repair`, `line_work` | utility 1.00, construction 0.30 | — |
| `water_repair_truck` | `water_repair_truck` | water | 24 | 1.15 | 2.0 | 5 | `water_repair`, `hydrant_service` | water 1.00, construction 0.30 | — |
| `construction_crew_vehicle` | `construction_crew` | construction | 18 | 1.00 | 2.5 | 0 | `debris_clearance`, `road_repair`, `structure_repair`, `land_development` | construction 1.00, utility 0.25, water 0.25 | — |

Notes:
- `role_fit` = the resolve rate itself normalised to the primary (so a construction crew answering a downed line scores `ROLE_FIT_PENALTY · 0.75 = 22.5` extra cost, and contributes only 0.25 — usable in desperation, never preferred).
- Crossing 300 m in a starter city: patrol `1.0 + 300/32 = 10.4` game-minutes; engine `1.5 + 300/26 = 13.0`. In a **peak thunderstorm** (doc 07 `road_speed_mult = 0.55`, applied by doc 10) the engine takes `1.5 + 300/(26×0.55) = 1.5 + 300/14.3 = **22.5**`. Weather visibly costs buildings. *(The previous "blizzard ×0.55" example is retired: doc 07's MVP state set is CLEAR / CLOUDY / RAIN / HEAVY_RAIN / THUNDERSTORM / HEAT_WAVE — there is no blizzard to route through.)*

**Station unit capacity — doc 06 owns it** *(report 98 C-50).* Units are doc 06's entities, and fleet size is what calibrates the incident load damper (§2.6) and the Director's fleet-strength score (§5). Doc 02's `unit_slots` and `crew_slots` columns are deleted there. **Doc 06's ladders stand unchanged:**

| department | `capacity_per_station_level` | housed at |
|---|---|---|
| police (`police_patrol`) | **[2, 3, 4, 5, 6]** | `police_station` |
| fire (`fire_engine`) | **[1, 2, 3, 4, 5]** | `fire_station` |
| utility (`utility_service_truck`) | **[1, 2, 3, 4, 5]** | `power_facility` / `substation` |
| water (`water_repair_truck`) | **[1, 2, 3, 4, 5]** | `water_facility` |
| construction (`construction_crew_vehicle`) | **[1, 2, 3, 4, 5]** | `construction_yard` |

Doc 02 supplies the station *shell* — footprint, level, condition, state, `coverage_radius_tiles` and the `coverage_police(pos)` / `coverage_fire(pos)` scalars (C-51) — and doc 06 supplies how many units live in it.

**Construction crews are doc 06's dispatchable units** *(report 98 G-2).* The three-way split is:

| owner | owns |
|---|---|
| **06 (this doc)** | the crew **roster** — crews are `fleet` units with the FSM below, station capacity `[1,2,3,4,5]`, dispatch scoring, `manual_lock`, **preemption at `CONSTRUCTION_PREEMPT_PRIORITY = 400`**, and `auto_dispatch_construction: false` by default (crews belong to the build queue; pulling one onto an incident is a player decision) |
| **02 Buildings** | the **project record and progress** — `sim/construction/`, work units through doc 01's `WorkService`, and the published API `ConstructionQueue.submit(job) / reorder / cancel` plus `job_started / completed / cancelled` |
| **09 Map/Land** | the land-development **phase → crew-type mapping** |

A crew bound to a doc 02 job is `ON_SCENE` on that job from doc 06's point of view; preemption emits `construction_job_preempted{job_id, unit_id}` so doc 02 can pause and re-queue rather than lose progress. Doc 10 submits road jobs to doc 02's queue, not to doc 06.

**Vehicle FSM:** `IDLE` → `RESPONDING` → `ON_SCENE` → (`RETURNING` → `IDLE`) with side states `REFIT` (out of service `refit_min` after fire/water work) and `OFFLINE` (unaffordable upkeep ⇒ unit parked and flagged — **doc 03**'s austerity layer, §2.12 there). `ON_SCENE` begins contributing on the tick it arrives. Units auto-release from `ON_SCENE` when the incident leaves `ACTIVE`.

**Unpowered stations have no effect on their units — this is a RULED MVP decision, not an open question** *(report 98 C-52).* Spec §4 Pillar 1 argues a blacked-out fire station should be degraded; doc 06's MVP call is **upheld by the report**. A `fire_station` blackout that grounds the fleet during the thunderstorm that caused the blackout is a legitimate death spiral, and the anti-death-spiral rule (spec §51 Risk 5) outranks the pillar here. **Post-MVP the penalty is `turnout_min × 2` while the station is dark — never a hard stop**, and it is tracked in doc 99's risk register rather than as a defect in this doc.

### 2.12 Auto-dispatch policy system (spec §21.3)

Policies live in the `dispatch` save section and are evaluated by **one function**, `DispatchPolicy.allows(unit, incident, world) -> bool`, called from the identical assignment loop in §2.10 in both the online and offline paths. There is no offline-only branch anywhere in dispatch. This is a hard invariant and §7 tests it directly.

| policy key | type | default | effect |
|---|---|---|---|
| `auto_dispatch_fire` | bool | `true` | allow auto-assignment of `fire` units |
| `auto_dispatch_police` | bool | `true` | allow auto-assignment of `police` units |
| `auto_dispatch_police_min_priority` | int | 150 | police auto-dispatch only if `priority(inc) ≥` this |
| `auto_dispatch_utility` | bool | `true` | |
| `auto_dispatch_water` | bool | `true` | |
| `auto_dispatch_construction` | bool | `false` | **ruled default (G-2)** — crews belong to doc 02's build queue; committing one to an incident is a player decision |
| `utility_priority_order` | array | `["critical_facility","water_pump","substation","commercial","residential"]` | when two incidents tie within `TIE_BAND (25)` priority, the one whose downstream class appears earlier wins |
| `fire_reserve_units` | int | 1 | keep N engines `IDLE` at station; overridden when `tier ≥ reserve_break_tier` |
| `police_reserve_units` | int | 0 | as above |
| `reserve_break_tier` | int | 4 | tier at which reserves may be committed |
| `auto_spend_contractor` | bool | `false` | may hire an emergency contractor unit (post-MVP) |
| `auto_repair_cost_cap` | int | 5000 | skip auto-dispatch if `cost_materials` estimate exceeds this (treasury protection) |
| `offline_notify_min_priority` | int | 2 | notification threshold used for the WHILE YOU WERE AWAY digest |

```
DispatchPolicy.allows(unit, inc, world):
    if inc.manual_requested: return true                       # player command bypasses everything
    if not policy["auto_dispatch_" + unit.department]: return false
    if unit.department == "police" and priority(inc) < policy.auto_dispatch_police_min_priority: return false
    if economy.repair_cost(inc.target_ref, expected_damage_fraction(inc)) > policy.auto_repair_cost_cap
       and inc.tier < 4: return false                          # doc 03 prices it; the cap is a dollar limit,
                                                               # not a price table (C-07/C-16)
    if breaks_reserve(unit) and inc.tier < policy.reserve_break_tier: return false
    return true

breaks_reserve(unit):
    n_idle_same_dept_same_station = count(IDLE units of unit.department at unit.home_station)
    return n_idle_same_dept_same_station <= policy[unit.department + "_reserve_units"]
```

`RESERVE_PENALTY (45)` in the cost function handles the *soft* case (a reserve-breaking unit is still considered but heavily disfavoured when `tier ≥ reserve_break_tier`); `breaks_reserve` in `allows()` handles the *hard* case below that tier.

### 2.13 Offline catch-up integration

`IncidentSystem` exposes exactly one entry point; the offline driver (**doc 08**, through doc 01's `advance_coarse_sliced`) calls it repeatedly with `dt_h = 1.0`:

```
for hour in range(elapsed_game_hours):
    weather.advance(1.0); power.advance(1.0); water.advance(1.0); roads.advance(1.0)
    incidents.advance(1.0)          # internally sub-steps per §2.1
    events → history ring buffer
```

Bounded cost: `MAX_SUBSTEPS = 64` per hour, and each sub-step is O(active_incidents + queued_assignments). With ≤ 40 active incidents and ≤ 20 units, worst case is ~2,500 cheap operations per simulated hour. At doc 01's post-C-19 cap — **12 real hours = 720 game-hours** — that is ~1.8 M cheap operations for a maximal absence, comfortably inside doc 08's sliced 12 ms-per-frame budget (C-22: main-thread slicing, no worker thread) and well under the "feels immediate" target (spec §50).

**Offline clamp (Risk 5 mitigation, spec §51):** if `elapsed_game_hours > OFFLINE_FULL_FIDELITY_H (72 game-hours)`, hours beyond the first 72 use `incident_load_damper *= 0.5` and the Disaster Director (**doc 07**) is suppressed. The player's city degrades but is never destroyed by a long absence. This is a **generation-rate** change only — the escalation and resolution math are untouched, so the invariant in §2.12 still holds.

**Offline destruction is refused, not silently dropped** *(C-47).* `world.destroy_allowed()` is `false` for every offline hour, so the `destroy_building` / `feeder_destroy` verbs take the clamped branch in §2.7: condition floors at 0.15, the incident stays open at tier 5, and `destroy_refused_offline` is written to the history ring so the WHILE YOU WERE AWAY report can say *"your L2 house was still burning when you got back."*

---

## 3. Data Schema

### 3.1 `data/incidents.json`

```jsonc
{
  "schema_version": 1,
  "globals": { /* see §8 tunables block, key "globals" */ },
  "types": {
    "<type_id>": {
      "display_name": "String",
      "type_priority": 1-5,
      "sev_bias": 0.0,            // added to severity_0
      "sev_spread": 1.0,          // × randf()
      "esc_base": 0.0,            // severity points per game-hour at tier 1
      "hold_base": 1.0,           // required_rate at tier 1 (ignored if suppression_model=="fire")
      "hold_tier_slope": 0.40,
      "w_base": 0.30,             // work_required at tier 1, game-hours
      "w_slope": 0.40,
      "suppression_model": "generic" | "fire",
      "self_resolve_h": 0.0,      // 0 = never
      "self_resolve_max_tier": 0,
      "primary_role": "police",
      "primary_counts_by_tier": [1,1,2,3,3],
      "support_roles": [ { "role": "construction", "rate_bonus": 0.20, "min_tier": 1 } ],
      "generator": {
        "candidate_source": "district"|"building"|"transformer"|"water_segment"|"intersection"|"exposed_asset",
        "base_rate": 0.012,
        "factors": ["stability","dark","police_coverage","weather"]   // named factor fns, §2.6
      },
      "reward_base": 350, "target_response_min": 8,
      // repair_material_base DELETED (C-07/C-16) -> doc 03 economy.repair_cost(target, damage_fraction)
      "stability_on_resolve": 0.010,
      "notification_priority_by_tier": [3,3,2,1,1],
      "on_tier_enter": {
        "2": [ { "op": "district_stability", "value": -0.010 } ],
        "3": [ { "op": "district_stability", "value": -0.025 },
               { "op": "city_confidence",   "value": -0.010 } ],
        "4": [ { "op": "spawn_incident", "type": "crime", "count": 1, "scope": "district" } ],
        "5": [ { "op": "set_district_flag", "flag": "unrest", "duration_h": 4.0 } ]
      },
      "on_fail": {
        "condition": { "hold_tier": 5, "hold_h": 1.0 },
        "actions": [ { "op": "district_stability", "value": -0.10 },
                     { "op": "spawn_incident", "type": "structure_fire",
                       "scope": "district_random_building", "severity_0": 2.0 } ]
      },
      "subtypes": { /* optional; same shape, overrides parent keys */ }
    }
  },
  "generator_base_rates": { /* six keys, §8 */ },
  "factors": { /* per-type factor constants, §8 */ },
  // weather_mults DELETED (RR-4) -> doc 07 §2.2 get_effect(): incident_crime_mult,
  //   fire_ignition_mult, incident_utility_mult, incident_traffic_mult. No weather number lives here.
  // RR-15: the §2.4 inline pair heat_mult (1.25) / rain_mult (0.80) is DELETED too -> doc 07
  //   get_effect("fire_escalation_mult"); §2.8 spread multiplies get_effect("fire_spread_mult").
  //   Channel NAMES only, in fire_weather_channels below -- still no weather number in this file.
  // fire: S_req is DERIVED from doc 02's fire_load (C-43). s_req_base_by_archetype and
  // s_level_slope are DELETED -- look for the consequence ladder in doc 02 §2.3 `FireLoad`.
  "fire": { "s_req_anchor": 0.50, "fire_load_anchor": 20, "s_req_exp": 0.45,
            "stage_mult": [], "g_stage": [], "spread_material_mult": {}, "residual_damage": {} },
  // base_fire_risk_by_archetype DELETED (C-42) -> doc 02 §2.3 `Fire p/gh` (fire_ignition_per_hour)
  "reward": { /* §8 */ }
}
```

`op` vocabulary (the data-driven cascade verbs, Constitution §8): `district_stability`, `city_confidence`, `spawn_incident`, `set_district_flag`, `building_condition`, `destroy_building`, `feeder_load_shed`, `feeder_offline`, `feeder_destroy`, `zone_pressure_delta`, `edge_speed_mult`, `edge_close`, `population_delta`, `notify`. Each verb is one small handler; adding a cascade never requires new incident code.

**Guarded verbs** *(report 98 C-47).* `destroy_building` and `feeder_destroy` are the only *irreversible* verbs, and both open with an explicit `world.destroy_allowed()` check before doing anything:

```
CASCADE_OPS = {
  ...
  "destroy_building": func(inc, args):
        if not world.destroy_allowed():                    # doc 08 fairness rule 4: never offline
            buildings.set_condition(args.target, OFFLINE_DESTROY_CLAMP_CONDITION)   # 0.15
            inc.burn_timer_h = catalog.globals.fire_burn_down_h                     # frozen, not re-armed
            emit("destroy_refused_offline", {incident_id = inc.id, target = args.target})
            return OpResult.REFUSED
        buildings.destroy(args.target, inc.id)             # doc 02 owns the building record
        return OpResult.DONE,
  "feeder_destroy": func(inc, args):
        if not world.destroy_allowed(): ... same shape, condition clamp 0.15 on the component ...
}
```

The point of the explicit guard is that the refusal is **visible** — a `REFUSED` result, an event and a history entry — rather than being swallowed by doc 08's `OfflineGuard` at a lower layer where neither the player nor a test can see it.

### 3.2 `data/vehicles.json`

```jsonc
{
  "schema_version": 1,
  "types": {
    "<vehicle_type_id>": {
      "display_name": "String",
      "economy_id": "patrol_car",  // join key into doc 03 data/economy.json expenses.vehicles (C-07)
      "department": "police"|"fire"|"utility"|"water"|"construction",
      "speed_mpgm": 32.0,        // metres per game-minute — see §2.11 and §9(1)
      "siren_mult": 1.25,        // applied only while status == RESPONDING
      "turnout_min": 1.0,        // game-minutes added to every ETA
      "refit_min": 0,            // out of service after a job
      "capabilities": ["police","traffic_control"],
      "resolve_rate": { "police": 1.00, "traffic": 0.90 },   // role → work rate; absent role ⇒ 0
      "suppression": 0.0,                                    // fire units only
      // purchase_cost / upkeep_per_game_hour / dispatch_cost DELETED (C-07, R-14)
      //   -> doc 03 §2.13(c), data/economy.json expenses.vehicles, keyed by economy_id
      "home_department_station": "police_station",
      "unlock": { "city_level": 1 },                         // city_level owned by doc 09 (G-1)
      "capacity_per_station_level": [2,3,4,5,6]              // units housed per station level (C-50, doc 06 owns)
    }
  }
  // weather_speed_mult DELETED (C-49) -> doc 07 get_effect("road_speed_mult"), applied by doc 10
  // road_class_mult    DELETED (C-49) -> doc 10 §2.11, the sole publisher of road class speed
}
```

### 3.3 Save sections

```jsonc
"incidents": {
  "section_version": 1,          // per-section key is `section_version`; `schema_version` is envelope-only (C-25)
  "next_id": 412,
  "active": [ {
    "id": 407, "type": "structure_fire", "subtype": null,
    "pos": [312.0, 148.0], "district_id": 3, "target_ref": { "kind": "building", "id": 1182 },
    "cluster_id": 12, "parent_id": null,
    "severity": 3.41, "progress": 0.22, "status": "ACTIVE", "burn_timer_h": 0.0,
    "created_min": 184320, "first_assign_min": 184323, "first_onscene_min": 184331,
    "tiers_fired": [2,3], "pinned": false, "seen": true,
    "assigned": [ { "unit_id": 7, "role": "fire", "state": "ON_SCENE", "eta_min": 0.0, "manual": false } ],
    "cause": { "source": "transformer_failure", "source_id": 388, "load_ratio": 1.12, "weather": "thunderstorm" }
  } ],
  "recent": [ /* RESOLVED/FAILED/ABANDONED kept KEEP_RESOLVED_MIN then moved to the history ring */ ],
  "gen_accumulators": { "crime": 0.0041, "structure_fire": 0.0002 }   // fractional λ carry (unused; Poisson is memoryless — reserved)
},
"fleet": {
  "section_version": 1,
  "next_id": 22,
  "units": [ {
    "id": 7, "type": "fire_engine", "home_station_id": 44,
    "pos_node": 903, "pos": [318.5, 151.2],
    "speed": 32.5,                 // metres per game-minute, current — REQUIRED by doc 11 (C-67)
    "heading": 1.9199,             // radians, XZ plane, 0 = +X — REQUIRED by doc 11 (C-67)
    "status": "ON_SCENE", "incident_id": 407,
    "route": [903, 871, 866], "route_progress": 1.0,
    "arrive_at_min": 184331, "manual_lock": false, "refit_until_min": 0,
    "construction_job_id": null    // non-null while a crew is bound to a doc 02 project (G-2)
  } ]
},
"dispatch": {
  "section_version": 1,
  "policy": { "auto_dispatch_fire": true, "auto_dispatch_police": true,
    "auto_dispatch_police_min_priority": 150, "auto_dispatch_utility": true,
    "auto_dispatch_water": true, "auto_dispatch_construction": false,
    "utility_priority_order": ["critical_facility","water_pump","substation","commercial","residential"],
    "fire_reserve_units": 1, "police_reserve_units": 0, "reserve_break_tier": 4,
    "auto_spend_contractor": false, "auto_repair_cost_cap": 5000,
    "offline_notify_min_priority": 2 },
  "stats": { "resolved_total": 318, "failed_total": 11, "abandoned_total": 27,
             "avg_response_min": 9.4, "rolling_response_score": 0.81 }
}
```

`rolling_response_score` = EWMA (α = 0.05) of `clamp(1.5 - response_minutes/target_response_min, 0, 1)` — read by the Disaster Director (**doc 07**) as a preparedness input.

**`speed` and `heading` are first-class persisted fields on `vehicle_state`, not derived** *(report 98 C-67).* Doc 11's Hermite interpolation needs both to place a vehicle between two 4 Hz sim positions; reconstructing them from consecutive positions doubles visible latency and makes a vehicle turn a frame after it has already moved. `speed` is `effective_speed` in metres per game-minute at the last sim update, `heading` is the direction of travel along the current route polyline in radians on the XZ plane. Both are written by `FleetSystem.advance()`, snapshot each tick, and round-trip through save/load so a resumed city does not stutter on the first frame.

---

## 4. Sim API Sketch

```
sim/incidents/incident.gd                 # RefCounted data object + tier()/is_terminal()
sim/incidents/incident_system.gd          # advance(dt_h), generation, escalation, resolution, cascade verbs
sim/incidents/incident_catalog.gd         # parsed data/incidents.json, factor-function registry
sim/incidents/fire_spread.gd              # spread rolls, suppression sizing, burn-down
sim/incidents/cascade_ops.gd              # the `op` verb handlers
sim/dispatch/dispatch_system.gd           # scoring, assignment loop, reassignment, manual overrides
sim/dispatch/dispatch_policy.gd           # DispatchPolicy.allows(), breaks_reserve()
sim/fleet/vehicle.gd                      # unit data object + FSM transitions
sim/fleet/fleet_system.gd                 # roster, stations, upkeep hook, arrival/return advance
```

**Tick entry points** (registered on the scheduler, Constitution §4):
`IncidentSystem.advance(dt_h)` @1 Hz — internally calls `DispatchSystem.tick()` and `FleetSystem.advance(dt_h)` at each sub-step boundary. `FleetSystem.charge_upkeep()` @per-game-hour.

**RNG streams consumed** (constitution §5): `crime` — crime generation *and* crime target selection (C-45); `incidents` — every other generator, subtype picks and spread rolls. Doc 06 touches no other stream.

**Commands handled:** `dispatch_unit`, `recall_unit`, `pin_incident`, `set_dispatch_policy`, `buy_vehicle`, `sell_vehicle`, `set_unit_home_station`, `acknowledge_incident`.

**Events emitted:** `incident_created`, `incident_tier_changed`, `incident_assigned`, `unit_dispatched`, `unit_arrived`, `unit_returned`, `incident_resolved`, `incident_failed`, `incident_abandoned`, `fire_spread`, `building_destroyed_by_fire`, **`destroy_refused_offline`** (C-47), **`construction_job_preempted`** (G-2), `dispatch_blocked_no_units`, `dispatch_blocked_unreachable`, `policy_changed`.

**`vehicle_state` snapshot record** (per unit, per tick, consumed by doc 11): `{ id, type, pos, speed, heading, status, incident_id, route_progress }` — `speed` and `heading` are explicit per C-67.

---

## 5. Cross-System Interfaces

**Renumbered per report 98 Ruling Zero.** The table below previously used a private numbering map (02 = economy, 03 = buildings, 08 = Director, 11 = persistence, 12 = UI/notifications). Every row is now on the on-disk numbering, and every doc reference in §1–§4 and §6–§9 has been corrected to match.

**Reads (required interfaces — named here so sibling docs can honour them):**

| doc | function this system calls | note |
|---|---|---|
| **01** Time | `ctx.channels`, `ctx.catchup_index`, `OfflinePolicy.band_for()` via `ctx`; `world.destroy_allowed()` | the only path by which doc 06 learns it is offline |
| **02** Buildings | `buildings.query_radius(pos, r)`, `buildings.get(id)` (archetype, level, condition, occupants, powered, state), `buildings.apply_condition_delta(id, d)`, `buildings.destroy(id, cause)`, **`fire_ignition_per_hour(type, L)`**, **`fire_condition_mult(b)`**, **`state_fire_mult(b)`**, **`fire_load(type, L)`**, **`crime_weight(type, L)`**, `coverage_police(pos)`, `coverage_fire(pos)`; `ConstructionQueue.submit/reorder/cancel` | C-42, C-43, C-44, C-51, G-2 |
| **03** Economy | `economy.credit(amount, reason)`, `economy.debit(amount, reason) -> bool`, `economy.can_afford(amount)`, **`economy.repair_cost(asset, damage_fraction)`**, **`economy.vehicle_dispatch_cost(type)`**, `Difficulty.get("escalation", key)` | sole currency authority (C-07, C-16, C-17) |
| **04** Power | `power.transformers()` (load_ratio, condition, temp_c, redundancy), `power.is_powered(pos)`, `power.power_availability_hour(id)`, `power.customers_downstream(node)`, `power.feeder_offline(id)`, `power.feeder_load_shed(id, frac)`, **`power.exposed_components()`** (weather_exposure, tree_adjacent, condition, underground) | last one is C-53's storm input |
| **05** Water | **`water.hydrant_pressure_ratio(pos) -> float ∈ [0,1.2]`** (the fire cascade), **`water.mains()`** (length_km, condition, pressure_ratio, **utilization**, **freeze_stress**, ground_saturation), `water.set_segment_broken(id, severity)`, `water.zone_pressure_delta(zone, d)` | `utilization` / `freeze_stress` added by C-46 |
| **07** Weather & Director | `weather.current()` (kind, wind_kph, wind_dir, temp_c, flood_saturation), `weather.get_storm_cell()`, **`weather.get_effect(channel)` for exactly six channels — `incident_crime_mult`, `fire_ignition_mult`, `incident_utility_mult`, `incident_traffic_mult` (generation, §2.6), `fire_escalation_mult` (§2.4 `esc_env`), `fire_spread_mult` (§2.8 `rate(target)`)**, `weather.get_forecast(h)`; `director.request_scripted_incident(spec)` | C-53 storm inputs; C-57 / **RR-4** / **RR-15** effect channels — doc 06 authors no weather constant anywhere, in generation or in fire dynamics |
| **09** Map, districts & population | `districts.get(id)` (pop, stability ∈ [0,1], police_coverage, outage_frac), `districts.apply_stability(id, d)`, `city.apply_confidence(d)`, `progression.city_level()` | stability owned here (C-56); population/city level absorbed here (G-1) |
| **10** Roads | **`roads.route_minutes(a, b, profile) -> float`** (authoritative, mode-invariant), `roads.congestion_index(edge)`, **`roads.condition_hazard_mult(edge)`** (C-48), `roads.access_quality(pos)`, `roads.set_edge_speed_mult(edge, m)`, `roads.close_edge(edge, until_min)`, `roads.nearest_node(pos)`, `roads.signalised_intersections()` | `condition_hazard_mult` is new |

**Provides:**

| consumer | what this system exposes |
|---|---|
| **02** Buildings | `incidents.active_on_building(id)` (blocks upgrades while burning); `FireStarted` / `FireSuppressed` / `BurnDown` (the only way `on_fire` is entered or left); residual `damage_fraction`; crew binding and `construction_job_preempted` (G-2) |
| **03** Economy | `vehicle_roster` (type, dispatched flag), `vehicle_km_this_hour`, `police_incidents_resolved_hour`, `response_capacity_score`, and `damage_fraction` per incident — doc 06 supplies fractions, never prices (C-16) |
| **04/05** Power & Water | `power.feeder_offline/load_shed` effects on cascade; `water.set_segment_broken`; repair-job completion callbacks |
| **07** Director | `dispatch.stats.rolling_response_score`, `incidents.active_count()`, `fleet.free_units_by_dept()` — the Director must not schedule a disaster when `free_units_by_dept` is exhausted (spec §20.2) |
| **08** Persistence & notifications | `serialize()/deserialize()` for the three save sections; `incident_events` for the WHILE YOU WERE AWAY digest; `notification_priority` per incident — **doc 08 owns notification policy, budgets and quiet hours** (C-71), doc 06 only classifies |
| **11** Rendering | `vehicle_state` snapshot including **`speed` and `heading`** (C-67); `fire_spread`, `incident_tier_changed` for VFX |
| **12** UI | `incidents.snapshot()` for the incident drawer (spec §40.2): id, type, tier, wait, assigned, `escalation_eta_min` (= time to next tier at current rate — the readable clock) |

---

## 6. MVP Cut

**In the vertical slice:**
- All six incident types with the full generator, escalation, resolution and cascade tables above (spec §43.3), including **storm damage, which doc 06 now generates for the whole project** (C-53).
- The complete FSM, sub-step integrator, and the online/offline equivalence guarantee.
- Priority scoring + greedy nearest-available assignment + manual override + pinning.
- The five MVP vehicle types, **station capacity ladders (C-50)**, purchase/upkeep/dispatch charges *priced by doc 03*, refit.
- **Construction crews as dispatchable units**, preemption at priority 400, `auto_dispatch_construction: false` (G-2).
- Fire spread **including doc 07's `fire_spread_mult` as `g_weather`** (RR-15), `S_req` derived from doc 02's `fire_load` (C-43), hydrant-pressure suppression coupling, burn-down.
- **All six doc 07 effect channels wired** — four in generation (RR-4) plus `fire_escalation_mult` in §2.4 and `fire_spread_mult` in §2.8 (RR-15). Doc 06 ships no weather constant.
- The full `dispatch.policy` block (all keys above), used identically online and offline.
- The `op` verb set listed in §3.1, **including the `world.destroy_allowed()` guard** (C-47).

**Ruled MVP decisions (recorded, not open):**
- **Unpowered stations have no effect on their units** *(C-52).* Upheld by report 98 as a deliberate anti-death-spiral call. Post-MVP: `turnout_min × 2` while dark, never a hard stop. Tracked in doc 99's risk register.
- **`speed_mpgm` is a game-time constant, not a physical speed** *(C-70).* Approved; the mature-city response case is in §1.1.
- **Doc 06 owns unit capacity per station level** *(C-50).* Doc 02's `unit_slots` / `crew_slots` are deleted there.

**Deferred (post-MVP):**
- Ladder / rescue / hazmat / SWAT / EMS / mobile-transformer / bucket-truck / pump-truck units and their alarm-level interactions (spec §15.2, §15.4).
- Crew skill/experience, unit damage, fuel as a distinct resource.
- Building-specific incidents (stadium crowd, data-centre cooling, prison riot, zoo escape) — spec §10.
- Contractor hiring (`auto_spend_contractor` exists as a stored flag but has no unit to hire).
- Multi-district "alarm" declarations and mutual aid.
- Incident chaining across saves (`cluster_id` is stored but MVP clusters are only fire spread).
- Traffic-accident injury EMS branch (the `injury` flag exists and raises priority; there is no EMS unit yet, so `fire_engine` handles extrication).

---

## 7. Test Plan

Headless tests (`tests/sim/incidents/`, `tests/sim/dispatch/`), all with injected clock and seeded streams.

**Determinism & offline equivalence (the load-bearing tests):**
1. `test_online_offline_equivalence` — build a fixed city, run 24 game-hours via 1,440 `advance(1/60)` calls; from the same save, run 24 `advance(1.0)` calls. Assert **identical** final severity, progress, status, burn_timer, building conditions, treasury, and district stability for every incident that existed in both runs (generation RNG is seeded identically and consumed at the same boundaries).
2. `test_substep_boundary_exactness` — a fire crossing tiers 1→5 with no response: assert tier-entry timestamps match a closed-form analytic solution to within 1 game-second at both step sizes.
3. `test_policy_identical_both_paths` — instrument `DispatchPolicy.allows()`; assert the call sequence and results are identical between the two runs of test 1.
4. `test_save_load_midflight` — serialise mid-incident (unit en route, tier 3, 2 tiers fired), deserialise, continue; assert no tier re-fires and arrival lands on the same game-minute.

**Math:**
5. `test_escalation_table` *(re-derived through the channel, **RR-15**; expectations unchanged)* — reproduce the §2.4 worked example with a stubbed `WeatherSystem` in **CLEAR** (`fire_escalation_mult == 1.00`): `esc_env == 1.250 ± 1e-6` and tier times 21.8 / 17.5 / 14.5 / 12.5 game-minutes ±0.1.
6. `test_partial_suppression` *(recomputed, R-12)* — one engine at hydrant ratio 0.4 on a tier-3 **house L2** fire: `required_rate == 0.887926 ± 0.0005`, `assist_ratio == 0.619420 ± 0.001`, escalation rate `== 1.5699 ± 0.01`.
7. `test_generator_rates` — 10,000 game-hours of a fixed city, assert observed counts per type within ±5% of the analytic λ for each of the six worked examples in §2.6, at the **post-amendment** constants (`R_fire_base 0.40`, `R_storm_base 0.0149`).
8. `test_work_requeue_on_tier_change` — progress rescales by `W_old/W_new` on tier entry; never exceeds 1.0, never goes negative.
9. `test_hazard_rate_composition` — fire spread: `P(no ignition)` over 1 gh equals `exp(-rate)` at both 5-minute and 1-hour granularity within ±1e-9. **Run it a second time with the weather held at `HEAVY_RAIN` intensity 1.0 (`g_weather = 0.35`)** to assert `g_weather` enters the hazard rate and not the per-roll probability — the two are only equivalent if the multiplication happens before the exponential (RR-15).

**Dispatch:**
10. `test_priority_ordering` — the four §2.9 worked incidents sort 575.5 / 370.0 / 354.6 / 338.0.
11. `test_nearest_unit_assignment` — three stations, one incident; assert the minimum-`eta` unit is chosen; add congestion on the near route and assert the choice flips.
12. `test_no_units_queues` — 5 incidents, 1 unit: exactly one is `ASSIGNED`, four stay `QUEUED`, all four escalate, `dispatch_blocked_no_units` emitted.
13. `test_reassignment_threshold` — a unit en route to a 300-priority incident is pulled by a 430-priority one (Δ=130 ≥ 120) but not by a 400-priority one (Δ=100).
14. `test_manual_lock` — manually dispatched unit is never reassigned even by a tier-5 fire; `cmd_recall_unit` releases it.
15. `test_fire_reserve` — with `fire_reserve_units=1` and 2 engines, a tier-2 fire takes one engine only; a tier-4 fire takes both.
16. `test_construction_preempt` — a crew on a build job is preempted only above priority 400.
17. `test_unreachable` — close every route to an incident: `route_minutes == INF`, no assignment, `dispatch_blocked_unreachable` emitted, incident still escalates.

**Cascades:**
18. `test_transformer_to_fire_chain` — force a transformer failure, block dispatch, assert feeder offline at tier 3, district `outage_frac > 0`, crime λ rises by the computed factor, and a `structure_fire` becomes possible.
19. `test_water_pressure_weakens_fire` — identical fire with `hydrant_pressure_ratio` 1.0 vs 0.3; assert resolution time ratio equals `1.0 / (0.25+0.75·0.3) = 2.11 ± 0.02`.
20. `test_burn_down` — tier 5 held 0.5 gh with no response destroys the building, applies the population/stability deltas exactly once, and spawns the debris incident.
21. `test_spread_cluster` — dense wooden block, no response: assert ≥2 spread ignitions in 2 gh at seed X, all sharing one `cluster_id`, and that cluster priority adds `25 × (n−1)`.
22. `test_load_damper` — force 40 active incidents against a 6-unit fleet; assert `incident_load_damper == 0.25` floor and generation drops accordingly.

**Rulings from report 98 (each amendment gets a test):**
23. `test_response_band_vs_escalation` *(C-70; **invariants unchanged under RR-15**)* — an unattended house fire in **CLEAR** reaches tier 2 at 21.8 gm and tier 3 at 39.3 gm; assert the mature-city worst case 39.1 gm (doc 10 §2.6 example C) arrives strictly before tier 3, and the clear case 24.2 gm arrives in tier 2. Fails loudly if `esc_base[structure_fire]` is retuned without re-checking — **and now also if doc 07 widens the `fire_escalation_mult` CLEAR band away from 1.00**, since the test drives `esc_env` through the live channel rather than a doc 06 constant. The 0.2 gm margin (39.3 − 39.1) is asserted explicitly so a future retune cannot erode it silently.
24. `test_fire_rate_calibration` *(C-42 / R-11)* — build the §2.6(b) 300-building reference city at condition 0.90; assert `Σ p_ignite_base == 0.0790604 ± 1e-6` and `λ_city × 24 == 0.759 ± 0.005` fires/game-day. Assert `data/incidents.json` contains **no** `base_fire_risk_by_archetype` and **no** `level_risk_slope` key.
25. `test_s_req_from_fire_load` *(C-43 / R-12)* — for all 60 (archetype, level) pairs assert `S_req == 0.50 × (doc02.fire_load/20)^0.45` to 1e-6; spot-assert `house L1 == 0.500`, `high_rise L5 == 3.060 ± 0.001`, `power_facility L5 == 3.426 ± 0.001`. Assert `data/incidents.json` contains no `s_req_base_by_archetype` and no `s_level_slope`.
26. `test_crime_target_weighting` *(C-44)* — the §2.6(a) district (40 house L1 / 6 store L2 / 2 substation L1): over 100,000 picks assert P(store) `== 0.401 ± 0.005` and P(substation) `== 0.042 ± 0.003`; assert a building in state `on_fire` is never picked.
27. `test_crime_uses_crime_stream` *(C-45)* — instrument all seven streams; assert crime generation **and** crime target selection consume only `crime`, that `incidents` is untouched by the crime generator, and that `traffic` is consumed by nothing in `sim/`.
28. `test_main_break_uses_doc05_terms` *(C-46)* — reproduce both §2.6(d) worked rows: healthy `λ == 0.016368 ± 1e-6` (0.393/day), neglected+overloaded `λ == 0.0759 ± 1e-6` (1.822/day). Assert `load_mult` is read from `water.mains()` and that no `f_cond` or flat `f_freeze` constant survives in `data/incidents.json`.
29. `test_destroy_refused_offline` *(C-47)* — run a tier-5 fire to burn-down with `world.destroy_allowed() == false`; assert the building survives at condition 0.15, the incident stays `ACTIVE` at tier 5, `burn_timer` does not re-arm, `destroy_refused_offline` is emitted exactly once, and `buildings.destroy` is never called. Then flip the guard true and assert destruction proceeds.
30. `test_accident_road_condition` *(C-48 / **RR-3** / **RR-4**)* — the §2.6(e) rows on the **`[0,1]` road-condition scale**: condition **1.00** → 0.687/day, **0.55** → 0.742/day, **0.10** → 0.866/day, and the 8-dark-signal night-rain case (RAIN at intensity 0.75, `incident_traffic_mult == 1.40`) → **2.337/day (×3.15)**. Assert doc 06 calls `roads.condition_hazard_mult` and applies **max** over incident edges; assert `roads.condition(e) ∈ [0,1]` for every edge and that no `/100` or `×100` rescale appears anywhere in `sim/incidents/`.
31. `test_route_profile_fields` *(C-49)* — assert `RouteProfile` has exactly `{speed_mpgm, siren, ignores_closures, capabilities}` and that neither `weather_mult` nor `flood_mult` appears anywhere in `sim/dispatch/` or `data/vehicles.json`.
32. `test_storm_calibration` *(C-53 / R-13)* — reproduce doc 07's two reference outcomes with a 60-span grid over a 2.0 gh storm: maintained (wind 70, cond 0.60, no trees) `== 2.503 ± 0.05` expected failures; neglected (wind 85, cond 0.35, tree-adjacent) `== 11.948 ± 0.10`. Assert underground components are never candidates and that assets outside `weather.get_storm_cell()` are excluded.
33. `test_no_price_in_doc06_data` *(C-07 / R-14)* — grep guard: `purchase_cost`, `upkeep_per_game_hour`, `dispatch_cost`, `repair_material_base`, `weather_speed_mult` and `road_class_mult` appear in **no** file under `data/incidents.json` / `data/vehicles.json` / `data/dispatch.json`. Assert every vehicle type carries an `economy_id` that resolves in `data/economy.json`.
34. `test_vehicle_state_has_velocity` *(C-67)* — assert `speed` and `heading` are present on every snapshot record and survive save/load; assert `heading` matches the route polyline bearing to 1e-4 rad.
35. `test_crew_preemption_and_default` *(G-2)* — assert `auto_dispatch_construction` defaults `false`, that a crew on a doc 02 job is preempted only above priority 400, and that preemption emits `construction_job_preempted` and leaves doc 02's job progress intact.
36. `test_station_capacity_ladders` *(C-50)* — assert police `[2,3,4,5,6]` and the other four `[1,2,3,4,5]`, and that `data/buildings.json` contains no `unit_slots` or `crew_slots` key.
37. `test_section_version_keys` *(C-25 convention)* — the three save sections each carry `section_version`, and none carries `schema_version`.

**Round 2 rulings:**
38. `test_no_weather_table_in_doc06` *(**RR-4**, extended by **RR-15**)* — grep guard: the key `weather_mults` and the state keys `snow` / `blizzard` / `fog` appear in **no** file under `data/incidents.json` / `data/vehicles.json` / `data/dispatch.json`, and no float literal **anywhere** in `sim/incidents/` is keyed by a weather state — which under RR-15 is now literally true, so the guard is widened from the generation module to the whole tree and includes `sim/incidents/fire_spread.gd`. Assert the four *generators* call `weather.get_effect()` with exactly `incident_crime_mult`, `fire_ignition_mult`, `incident_utility_mult` and `incident_traffic_mult`, that `water_main_break` and `storm_damage` call it with nothing, and that the identifiers `heat_mult` and `rain_mult` no longer exist in `sim/`.
39. `test_weather_channel_values_come_from_doc07` *(**RR-4**)* — with a stubbed `WeatherSystem` in THUNDERSTORM at intensity 0.77, assert `get_effect("fire_ignition_mult") == 2.724 ± 1e-6` (doc 07 §2.2 `lerp(1.80, 3.00, 0.77)`) and that the §2.6(b) 300-building reference city with 60 dark buildings yields `λ == 0.09992729 ± 1e-7 /gh` = **2.398 fires/game-day**. Retune doc 07's row and this test must move — that is the point of it.
40. `test_weather_is_global_in_generation` *(**RR-4** / C-59)* — for every generator that consumes a weather channel, assert the multiplier applied to each candidate is identical across all candidates in the city (one `get_effect()` read per sub-step, not per candidate), so no worked example can ever again apply a global channel to a subset.

**Round 3 rulings:**
41. `test_esc_env_consumes_fire_escalation_mult` *(**RR-15**)* — with a stubbed `WeatherSystem`, assert `esc_env[structure_fire] == wind_term × get_effect("fire_escalation_mult") × hydrant_penalty` and nothing else. Golden values, wood house L2, hydrant ratio 1.0: **CLEAR** any intensity → `esc_env == 1.250 ± 1e-6`, tier ladder `2.750 / 3.4375 / 4.125 / 4.8125 /gh`, tier 3 at `39.273 ± 0.01` gm, tier 5 at `66.286 ± 0.01` gm; **THUNDERSTORM intensity 0.77** (`wind_kph 72.4`) → `esc_env == 1.2192 ± 1e-6` and tier 2 at `22.37 ± 0.01` gm. Assert the channel is **intensity-invariant** (identical at intensity 0 / 0.25 / 0.5 / 0.77 / 1.0 for all six states, to 1e-9) and that doc 06 applies **no clamp** to it. Grep guard: no `1.25`/`0.80` weather-keyed literal survives in the escalation path.
42. `test_spread_consumes_fire_spread_mult` *(**RR-15**)* — reproduce the §2.8 table on the fixed geometry (T3 apartment source, wooden house target 14 m downwind, 4 neighbours within 24 m), **with `wind_kph` supplied as a stub input at the table's rounded values (72.4 at intensity 0.77 etc.), exactly as test 41 does** — the exact lerp gives 72.35 and would miss the 1e-6 tolerance: `CLEAR` 0.50 → `rate == 0.362267 ± 1e-6` (p₁gh 30.4%), `HEAT_WAVE` 0.80 → `0.564251 ± 1e-6` (43.1%), `THUNDERSTORM` 0.3636 → `0.313651 ± 1e-6` (26.9%), `THUNDERSTORM` 0.77 → `0.341007 ± 1e-6` (28.9%). Assert `g_weather` is read from `get_effect("fire_spread_mult")` (not from `fire_escalation_mult` or a doc 06 constant), that it is applied **once per target evaluation and identically to every target of the same fire** (C-59), and that removing it from the product reproduces the pre-RR-15 `0.703833 /gh` at the reference storm — the regression this test exists to catch.
43. `test_three_fire_channels_are_not_aliased` *(**RR-15**)* — instrument `get_effect()` and run one game-hour containing generation, escalation and a spread roll in `THUNDERSTORM` at intensity 0.77. Assert exactly three distinct fire channel names are requested, that each is read at its own site (`fire_ignition_mult` → `sim/incidents/` generation, `fire_escalation_mult` → escalation, `fire_spread_mult` → `fire_spread.gd`), and that their live values differ (`2.724 / 0.80 / 0.4845`) so no substitution can pass unnoticed. Also assert **wind is not double-counted**: `wind_kph` enters spread only through `g_wind`, and stubbing `fire_spread_mult` to 1.0 leaves `g_wind` unchanged.

---

## 8. Tunables

One document, three top-level keys — split into `data/incidents.json`, `data/vehicles.json`, `data/dispatch.json` verbatim.

**Deleted by report 98, with where to look instead** — these keys are *removed*, not defaulted, not commented out:

| deleted key | ruling | now lives in |
|---|---|---|
| `incidents.base_fire_risk_by_archetype` | C-42 | doc 02 §2.3 `Fire p/gh` (`fire_ignition_per_hour`) |
| `incidents.factors.fire.level_risk_slope` | C-42 | doc 02 — the rate is already per level |
| `incidents.fire.s_req_base_by_archetype` | C-43 | derived from doc 02 §2.3 `FireLoad` |
| `incidents.globals.s_level_slope` | C-43 | derived — `fire_load` is already per level |
| `incidents.types.*.repair_material_base` | C-07 / C-16 | doc 03 §2.5 `economy.repair_cost()` |
| `vehicles.types.*.purchase_cost` / `.upkeep_per_game_hour` / `.dispatch_cost` | C-07 / R-14 | doc 03 §2.13(c), `data/economy.json` → `expenses.vehicles` |
| `vehicles.weather_speed_mult` | C-49 | doc 07 `get_effect("road_speed_mult")`, applied by doc 10 |
| `vehicles.road_class_mult` | C-49 | doc 10 §2.11 |
| `incidents.factors.water_main.press_*` retained; `f_cond` / `freeze_mult` step | C-46 | doc 05 §2.9 `cond_mult` / `load_mult` / freeze stress |
| `incidents.weather_mults` (all four tables: `.crime` / `.fire` / `.transformer` / `.traffic`, and every `snow` / `blizzard` / `fog` column in them) | **RR-4** | doc 07 §2.2 `get_effect()` — `incident_crime_mult`, `fire_ignition_mult`, `incident_utility_mult`, `incident_traffic_mult` |
| §2.4 `esc_env[structure_fire].heat_mult` (1.25) and `.rain_mult` (0.80) — **inline formula constants, never JSON keys**, which is why the earlier grep guards never saw them | **RR-15** | doc 07 §2.2.1 `get_effect("fire_escalation_mult")` — **values adopted verbatim**, so no calibration moved |
| *(nothing deleted — an omission corrected)* §2.8 `rate(target)` never read doc 07's published `fire_spread_mult` | **RR-15** | doc 07 §2.2 `get_effect("fire_spread_mult")`, multiplied in as `g_weather` |

```json
{
  "incidents": {
    "schema_version": 1,
    "globals": {
      "esc_tier_accel": 0.25,
      "hold_tier_slope": 0.40,
      "rate_cap_mult": 3.0,
      "keep_resolved_min": 15,
      "max_substeps_per_hour": 64,
      "min_substep_h": 0.000278,
      "spread_roll_interval_h": 0.08333,
      "spread_radius_m": 40.0,
      "spread_min_gap_m": 6.0,
      "spread_dist_decay_m": 12.0,
      "p_spread_base": 0.30,
      "fire_burn_down_h": 0.50,
      "fire_fatality_fraction": 0.02,
      "transformer_burn_down_h": 0.40,
      "offline_destroy_clamp_condition": 0.15,
      "hydrant_floor": 0.25,
      "hydrant_span": 0.75,
      "hydrant_cap": 1.15,
      "access_degraded_mult": 0.75,
      "access_police_bonus": 1.15,
      "load_damper_per_excess": 0.06,
      "load_damper_floor": 0.25,
      "offline_full_fidelity_h": 72,
      "offline_beyond_damper": 0.50,
      "night_start_hour": 19,
      "night_end_hour": 6
    },
    "_rng_note": "C-45: crime generation AND crime target selection draw from the `crime` stream; every other generator draws from `incidents`. `traffic` is reserved and consumed by nothing in sim/.",
    "rng_streams": {
      "crime": "crime",
      "structure_fire": "incidents",
      "transformer_failure": "incidents",
      "water_main_break": "incidents",
      "traffic_accident": "incidents",
      "storm_damage": "incidents"
    },
    "generator_base_rates": {
      "_note": "R_fire_base and R_storm_base recalibrated by report 98 R-11 and R-13; see §2.6(b) and §2.6(f) for the arithmetic.",
      "crime_per_1000_pop": 0.012,
      "structure_fire_global_scalar": 0.40,
      "transformer_per_node": 0.0012,
      "water_main_per_km": 0.0022,
      "traffic_per_intersection": 0.0020,
      "storm_per_exposed_asset": 0.0149
    },
    "factors": {
      "crime": { "k_stability": 3.0, "k_dark": 0.35, "k_outage_in_dark": 1.5,
                 "police_base": 1.4, "police_slope": 0.6, "police_min": 0.5, "police_max": 1.4,
                 "target_weight_source": "doc02.crime_weight" },
      "fire":  { "unpowered_mult": 0.8, "arson_stability_knee": 0.35, "arson_k": 2.0,
                 "base_rate_source": "doc02.fire_ignition_per_hour * doc02.fire_condition_mult * doc02.state_fire_mult",
                 "esc_wind_knee_kph": 20.0, "esc_wind_k": 0.010,
                 "esc_hydrant_knee": 0.7, "esc_hydrant_k": 0.6,
                 "esc_weather_source": "doc07.fire_escalation_mult" },
      "transformer": { "load_ref": 0.70, "load_exp": 3.0, "load_clamp": [0.20, 1.60],
                       "temp_knee_c": 65.0, "temp_span_c": 35.0, "temp_k": 0.9 },
      "water_main": { "press_knee": 1.05, "press_k": 1.5, "ground_k": 0.5,
                      "cond_mult_source": "doc05.cond_mult", "load_mult_source": "doc05.load_mult",
                      "freeze_break_base": 0.0020, "freeze_cond_offset": 1.2,
                      "freeze_gated_by": "doc05.feature_flags.freeze_enabled" },
      "traffic": { "flow_exp": 1.5, "flow_clamp": [0.05, 2.0],
                   "signal_powered": 1.0, "signal_unpowered": 3.0, "unsignalised": 1.6, "dark_k": 0.25,
                   "road_condition_source": "doc10.condition_hazard_mult", "road_condition_agg": "max",
                   "road_condition_scale": "[0,1]" },
      "storm": { "wind_knee_kph": 40.0, "wind_span_kph": 30.0, "wind_exp": 2.0,
                 "exposure_class": { "overhead_span": 1.0, "pole": 0.8, "rooftop_mech": 0.5, "tree_adjacent": 1.8 },
                 "subtype_weights": { "downed_power_line": 0.45, "blocked_road": 0.35, "roof_damage": 0.20 },
                 "wind_source": "doc07.weather.current().wind_kph",
                 "cell_mask_source": "doc07.weather.get_storm_cell()",
                 "exposure_source": "doc04.power.exposed_components()",
                 "exclude_if": "underground" }
    },
    "_weather_note": "RR-4: the weather_mults table is DELETED, not defaulted. Doc 07 §2.2 get_effect() is the sole statement of weather. The `weather_channels` map below binds each GENERATOR to one doc 07 channel name (null = this generator reads no weather channel); `fire_weather_channels` binds the two FIRE-DYNAMICS sites added by RR-15. Both maps carry channel NAMES only. This file carries no weather number and no weather state key.",
    "weather_channels": {
      "crime":               "incident_crime_mult",
      "structure_fire":      "fire_ignition_mult",
      "transformer_failure": "incident_utility_mult",
      "traffic_accident":    "incident_traffic_mult",
      "water_main_break":    null,
      "storm_damage":        null
    },
    "_fire_weather_note": "RR-15. Three fire questions, three doc 07 channels, three call sites, never interchangeable (doc 07 §2.2.1): fire_ignition_mult = how often a fire starts (generation, bound in weather_channels above); fire_escalation_mult = how fast a burning one grows (§2.4 esc_env[structure_fire], replacing the deleted inline heat_mult 1.25 / rain_mult 0.80 at values doc 07 adopted verbatim -- calibration preserved, §1.1 band and test 23 unchanged); fire_spread_mult = how readily it jumps (§2.8 g_weather, doc 07's first consumer for this channel). Both are passed through UNCLAMPED -- doc 06's [0.4,3.0] esc_env clamp applies only to factors doc 06 authors. Wind is NOT in either channel: it enters escalation via the §2.4 wind term and spread via g_wind, both off doc 07's wind_kph, exactly once each.",
    "fire_weather_channels": {
      "escalation": "fire_escalation_mult",
      "spread":     "fire_spread_mult"
    },
    "types": {
      "crime":               { "type_priority":2, "sev_bias":0.0,  "sev_spread":1.0, "esc_base":0.80, "hold_base":1.00, "w_base":0.30, "w_slope":0.40, "suppression_model":"generic", "self_resolve_h":2.0, "self_resolve_max_tier":2, "primary_role":"police",       "primary_counts_by_tier":[1,1,2,3,3], "support_roles":[], "reward_base":350, "target_response_min":8,  "stability_on_resolve":0.010, "notification_priority_by_tier":[3,3,2,1,1] },
      "structure_fire":      { "type_priority":5, "sev_bias":0.0,  "sev_spread":0.6, "sev_level_k":0.15, "esc_base":2.20, "hold_base":0.00, "w_base":0.30, "w_slope":0.45, "suppression_model":"fire",    "self_resolve_h":0.0, "self_resolve_max_tier":0, "primary_role":"fire",         "primary_counts_by_tier":[1,1,2,3,4], "support_roles":[{"role":"police","rate_bonus":0.15,"min_tier":2},{"role":"construction","rate_bonus":0.00,"min_tier":4}], "reward_base":900, "target_response_min":6,  "stability_on_resolve":0.020, "notification_priority_by_tier":[3,3,2,1,1] },
      "transformer_failure": { "type_priority":4, "sev_bias":0.2,  "sev_spread":0.8, "esc_base":0.50, "hold_base":1.00, "w_base":0.90, "w_slope":0.30, "suppression_model":"generic", "self_resolve_h":0.0, "self_resolve_max_tier":0, "primary_role":"utility",      "primary_counts_by_tier":[1,1,2,2,2], "support_roles":[{"role":"construction","rate_bonus":0.20,"min_tier":3}], "reward_base":600, "target_response_min":12, "stability_on_resolve":0.015, "notification_priority_by_tier":[3,2,2,1,1] },
      "water_main_break":    { "type_priority":3, "sev_bias":0.1,  "sev_spread":0.9, "esc_base":0.60, "hold_base":1.00, "w_base":1.20, "w_slope":0.30, "suppression_model":"generic", "self_resolve_h":0.0, "self_resolve_max_tier":0, "primary_role":"water",        "primary_counts_by_tier":[1,1,2,2,2], "support_roles":[{"role":"construction","rate_bonus":0.25,"min_tier":2}], "reward_base":500, "target_response_min":15, "stability_on_resolve":0.015, "notification_priority_by_tier":[3,3,2,1,1], "zone_pressure_delta_by_tier":[0.0,0.0,-0.15,-0.35,-0.60,-0.80] },
      "traffic_accident":    { "type_priority":3, "sev_bias":0.0,  "sev_spread":0.8, "esc_base":0.70, "hold_base":1.00, "w_base":0.35, "w_slope":0.35, "suppression_model":"generic", "self_resolve_h":1.0, "self_resolve_max_tier":2, "primary_role":"police",       "primary_counts_by_tier":[1,1,1,2,2], "support_roles":[{"role":"fire","rate_bonus":0.30,"min_tier":1},{"role":"construction","rate_bonus":0.20,"min_tier":3}], "reward_base":300, "target_response_min":7,  "stability_on_resolve":0.008, "notification_priority_by_tier":[3,3,2,1,1] },
      "storm_damage":        { "type_priority":3, "sev_bias":0.1,  "sev_spread":0.9, "esc_base":0.40, "hold_base":1.00, "w_base":0.70, "w_slope":0.30, "suppression_model":"generic", "self_resolve_h":0.0, "self_resolve_max_tier":0, "primary_role":"utility",      "primary_counts_by_tier":[1,1,2,2,2], "support_roles":[{"role":"construction","rate_bonus":0.20,"min_tier":1}], "reward_base":400, "target_response_min":15, "stability_on_resolve":0.010, "notification_priority_by_tier":[3,3,2,1,1],
        "subtypes": {
          "downed_power_line": { "primary_role":"utility",      "esc_base":0.40, "w_base":0.70, "w_slope":0.30 },
          "blocked_road":      { "primary_role":"construction", "esc_base":0.30, "w_base":0.50, "w_slope":0.25, "self_resolve_h":6.0, "self_resolve_max_tier":2, "type_priority":2 },
          "roof_damage":       { "primary_role":"construction", "esc_base":0.35, "w_base":0.80, "w_slope":0.25, "type_priority":2 }
        } }
    },
    "fire": {
      "_s_req_note": "C-43 / R-12. S_req(b) = s_req_anchor * (doc02.fire_load(archetype, level) / fire_load_anchor) ^ s_req_exp. No per-archetype constant and no level slope live here any more. Anchors: house L1 fire_load 20 -> 0.500 exactly; high_rise L5 fire_load 1120 -> 3.060. Set s_req_exp to 0.4904 if the overseer wants the pre-amendment 3.60 preserved.",
      "s_req_anchor": 0.50,
      "fire_load_anchor": 20,
      "s_req_exp": 0.45,
      "stage_mult": [0.0,0.60,0.90,1.30,1.80,2.40],
      "g_stage":    [0.0,0.00,0.35,1.00,1.80,3.00],
      "g_wind_k": 1.2, "g_wind_ref_kph": 60.0, "g_density_k": 0.5, "g_density_ref": 6,
      "g_weather_source": "doc07.fire_spread_mult",
      "spread_material_mult": { "house":1.40,"apartment":1.00,"store":1.10,"office":0.70,"high_rise":0.70,"data_center":0.60,"industrial":1.30,"default":1.00 },
      "residual_damage": { "tier_k": 0.10, "burn_timer_k": 0.30, "cap": 0.95 }
    },
    "reward": { "tier_k": 0.35, "speed_bonus_base": 1.5, "speed_bonus_k": 0.5, "speed_bonus_min": 0.60, "speed_bonus_max": 1.50 }
  },

  "vehicles": {
    "schema_version": 1,
    "_price_note": "C-07 / R-14: doc 03 is the sole currency authority. purchase, upkeep, active_mult and dispatch_cost live in data/economy.json expenses.vehicles, keyed by economy_id. Nothing in this file carries a price.",
    "types": {
      "police_patrol":            { "economy_id":"patrol_car",             "department":"police",       "speed_mpgm":32.0, "siren_mult":1.25, "turnout_min":1.0, "refit_min":0, "capabilities":["police","traffic_control","crowd_control"], "resolve_rate":{"police":1.00,"traffic":0.90}, "suppression":0.0, "home_department_station":"police_station",     "capacity_per_station_level":[2,3,4,5,6] },
      "fire_engine":              { "economy_id":"fire_engine",            "department":"fire",         "speed_mpgm":26.0, "siren_mult":1.25, "turnout_min":1.5, "refit_min":6, "capabilities":["fire_suppression","rescue_basic","traffic_control"], "resolve_rate":{"fire":1.00,"rescue":1.00,"traffic":0.50}, "suppression":1.00, "home_department_station":"fire_station",       "capacity_per_station_level":[1,2,3,4,5] },
      "utility_service_truck":    { "economy_id":"utility_service_truck",  "department":"utility",      "speed_mpgm":24.0, "siren_mult":1.15, "turnout_min":2.0, "refit_min":0, "capabilities":["electrical_repair","line_work"], "resolve_rate":{"utility":1.00,"construction":0.30}, "suppression":0.0, "home_department_station":"substation",         "capacity_per_station_level":[1,2,3,4,5] },
      "water_repair_truck":       { "economy_id":"water_repair_truck",     "department":"water",        "speed_mpgm":24.0, "siren_mult":1.15, "turnout_min":2.0, "refit_min":5, "capabilities":["water_repair","hydrant_service"], "resolve_rate":{"water":1.00,"construction":0.30}, "suppression":0.0, "home_department_station":"water_facility",     "capacity_per_station_level":[1,2,3,4,5] },
      "construction_crew_vehicle":{ "economy_id":"construction_crew",      "department":"construction", "speed_mpgm":18.0, "siren_mult":1.00, "turnout_min":2.5, "refit_min":0, "capabilities":["debris_clearance","road_repair","structure_repair","land_development"], "resolve_rate":{"construction":1.00,"utility":0.25,"water":0.25}, "suppression":0.0, "home_department_station":"construction_yard", "capacity_per_station_level":[1,2,3,4,5] }
    }
  },

  "dispatch": {
    "schema_version": 1,
    "scoring": { "w_type":60, "w_sev":45, "w_wait":30, "wait_cap_h":3.0, "w_exposure":70,
                 "w_life":120, "w_coverage":90, "pin_bonus":500, "cluster_bonus":25, "tie_band":25 },
    "exposure": { "fire_pop_ref":400, "fire_neighbour_k":0.4, "customers_ref":800,
                  "critical_facility_bonus":0.35, "fire_in_zone_bonus":0.30,
                  "congestion_ref":1.5, "crime_pop_ref":6000, "crime_pop_w":0.6, "crime_stability_w":0.4 },
    "route_profile_fields": ["speed_mpgm", "siren", "ignores_closures", "capabilities"],
    "assignment": { "max_assignments_per_tick":16, "reassign_threshold":120, "reassign_penalty_min":12,
                    "reserve_penalty_min":45, "role_fit_penalty_min":30, "max_acceptable_cost_min":90,
                    "construction_preempt_priority":400 },
    "policy_defaults": { "auto_dispatch_fire":true, "auto_dispatch_police":true,
      "auto_dispatch_police_min_priority":150, "auto_dispatch_utility":true, "auto_dispatch_water":true,
      "auto_dispatch_construction":false,
      "utility_priority_order":["critical_facility","water_pump","substation","commercial","residential"],
      "fire_reserve_units":1, "police_reserve_units":0, "reserve_break_tier":4,
      "auto_spend_contractor":false, "auto_repair_cost_cap":5000, "offline_notify_min_priority":2 },
    "response_score_ewma_alpha": 0.05
  }
}
```

**Difficulty rows authored here, filed in doc 03's `data/difficulty.json`** *(report 98 C-17 — one difficulty file, one loader, owners still author their own rows; doc 06 defines no difficulty scalar of its own):*

```json
"escalation": {
  "_owner": "06",
  "casual":   { "escalation_mult": 0.75, "generation_mult": 0.80 },
  "standard": { "escalation_mult": 1.00, "generation_mult": 1.00 },
  "hard":     { "escalation_mult": 1.35, "generation_mult": 1.20 },
  "crisis":   { "escalation_mult": 1.60, "generation_mult": 1.40 }
}
```

---

## 9. Conflicts & Open Questions

*(Rewritten after report 98, and again after its Round 2 and Round 3 rulings. Items 1, 2, 4, 5, five of the six original open questions and Round 2's follow-up question 10 are now **ruled** and recorded as decisions; what remains — questions 6–9 — is genuinely open, and none of it is a weather question any more.)*

**Ruled — recorded, no longer requesting approval:**

1. **Vehicle speed is a game-time constant, not a physical speed — APPROVED** *(report 98 C-70).* `speed_mpgm` (metres per game-minute) makes sim ETA and rendered motion the same number under the locked 60× time scale, and produces readable response times. Its literal physical interpretation (≈1.9 km/h for a patrol car) is nonsense and must never be surfaced in UI or fiction. The report additionally confirmed the mature-city case: 24.2 gm clear / 39.1 gm storm-plus-blackout over 880 m, both of which arrive before tier 3 on an unattended house fire (§1.1, test 23).

2. **The sim owns arrival time; the renderer follows — HONOURED BY DOC 10.** `roads.route_minutes()` is authoritative for both scoring and actual arrival, and doc 10 §9 R-1 accepted mode-invariance and deleted its own vehicle-speed table. Doc 06's `RouteProfile` no longer carries `weather_mult` or `flood_mult` (C-49), so there is exactly one place each where weather and flooding touch travel time.

3. **Constitution §4's "coarse advance path (1 game-hour steps)".** This doc calls `advance(1.0)` as required and sub-steps internally to preserve exactness. Read as compliant (the *scheduler* steps by an hour); flagged only because it is a stronger fidelity claim than the constitution demands. Unchanged by the report.

4. **Money — RESOLVED, doc 03 owns all of it** *(C-07 / C-16 / R-14).* Doc 06's purchase, upkeep, dispatch and `repair_material_base` tables are deleted. C-07 preserved doc 06's *ratios* — the roster is still ordered patrol < water < utility < construction < engine, with `fire_engine = 1.60 × patrol_car` — while compressing magnitudes onto doc 03's ladder. Doc 06 now supplies `damage_fraction` and consumes `economy.repair_cost()`.

5. **Construction crews — RESOLVED as a three-way split** *(G-2).* Doc 06 owns crews as dispatchable units (roster, station capacity `[1,2,3,4,5]`, preemption at priority 400, `auto_dispatch_construction: false`); **doc 02 owns the project record, progress and the queue API**; doc 09 owns the phase→crew-type mapping. The contention model is unchanged; only the ownership is now written down.

**Ruled — questions closed by the report:**

- **Doc numbering — CLOSED by Ruling Zero.** The on-disk filenames are canonical; §5 and every in-text reference in this doc have been renumbered. The old private map (02 = economy, 03 = buildings, 08 = Director, 11 = persistence, 12 = UI) is gone.
- **`stability` range — CLOSED: `[0,1]`, owned by doc 09** *(C-56).* Also confirmed: `police_coverage ∈ [0,1]` (implemented in doc 02 per C-51), `congestion_index ∈ [0,2]`, `hydrant_pressure_ratio ∈ [0,1.2]`, building `condition ∈ [0,1]` (C-14), and **road `condition ∈ [0,1]`** *(RR-3 — C-14 applies to roads too; there is no carve-out, and doc 06 quotes `condition_hazard_mult` on the rescaled knee 0.75 / coefficient 0.4)*.
- **`weather_mults` vs doc 07's `get_effect()` channels — CLOSED by RR-4: doc 07's channels win.** Doc 06's four incident-rate weather tables are **deleted**, not overridden, so no placeholder survives for someone to implement by accident; the generators name `incident_crime_mult`, `fire_ignition_mult`, `incident_utility_mult` and `incident_traffic_mult` directly (§2.6). The dead `snow` / `blizzard` / `fog` columns died with the table — if Phase 2 adds winter states, doc 07 adds the rows and doc 06 changes nothing. Two worked examples moved as a result (§2.6(b), §2.6(e)); see the Round 2 amendment table.
- **Unpowered stations — CLOSED: no effect in MVP** *(C-52).* Deliberate, upheld, recorded in §6 and doc 99's risk register. Post-MVP `turnout_min ×2`, never a hard stop.
- **Storm damage ownership — CLOSED: doc 06 owns all of it** *(C-53).* Doc 04's `h_wind` and doc 07 §2.7.4's rolls are deleted; the `storm_owns_line_failures` flag is deleted with them.
- **Residual weather-keyed fire constants (old open question 10) — CLOSED by RR-15, and the fix cost no calibration.** The question asked whether §2.4's inline `heat_mult` / `rain_mult` should move behind a doc 07 channel, and flagged that folding them into the *existing* `fire_spread_mult` would cut escalation 25–44% in a thunderstorm and break test 23's 0.2 gm margin. **The ruling answers it by not folding:** doc 07 published a **new** channel, `fire_escalation_mult`, whose per-state values are doc 06's own constants adopted verbatim (`1.00 / 1.00 / 0.80 / 0.80 / 0.80 / 1.25`, flat), so ownership moved and every number stayed — §1.1's band, the 66.3 gm tier-5 arrival and test 23's invariant all reproduce to the digit (§2.4). Separately, §2.8 now multiplies `fire_spread_mult` into `rate(target)` as `g_weather`, giving that long-published channel its first consumer; **that one *is* a behaviour change and is worked out in §2.8** — at doc 07's reference storm, spread falls to 48.45% of its dry-air value (`p₁gh` 50.5% → 28.9% on the reference geometry), while a heat wave raises it to ×1.63. The general lesson is written into doc 07 §2.2.1: fire weather is three questions, so it takes three channels, and **one channel may never stand in for another** — tests 41–43 enforce it. *No weather constant of any kind now survives in this doc.*

**Still open for the overseer:**

6. **`reward_base` may be doc 03's money too.** `reward_base[crime] = 350` is numerically identical to doc 03's `POLICE_FINE_PER_RESOLVED_INCIDENT = 350`, which suggests doc 03 already books that revenue. Report 98 did not name `reward_base` in C-07 and doc 03's single-price-table grep guard (its test 33) does not cover it, so it is retained here — but if it is the same dollar it must move. **Requesting a ruling.**

7. **Fatalities.** `FIRE_FATALITY_FRACTION = 0.02` on burn-down is the only death source this doc introduces; spec §31 says deaths should follow only from credible severe conditions. Confirm this is acceptable for a mobile store rating, or set it to 0 and model the loss purely as displacement.

8. **Should `traffic_accident` require an EMS unit in MVP?** Currently `fire_engine` covers extrication and the `injury` flag only raises priority. If doc 07's thunderstorm choreography wants ambulance drama, EMS needs to move from §6 deferred into MVP.

9. **Incident cap.** Should there be a hard ceiling on simultaneous active incidents (e.g. 60) in addition to `incident_load_damper`, to bound offline cost on very large cities? None added; the damper alone is asymptotically self-limiting but not bounded. Note the offline budget is now 720 game-hours (C-19), not 480, which makes the question slightly sharper.

---

## Amendments applied (report 98)

### Round 1 (report 98 §1–§13 — the first amendment wave)

| ruling | change |
|---|---|
| **Ruling Zero** | Adopted the on-disk doc numbering everywhere: §5's cross-system table rebuilt on 01–13, and every in-text reference corrected (Director 08→**07**, buildings 03→**02**, economy 02→**03**, offline driver 11→**08**, notifications 12→**08**). A numbering banner was added at the head of the doc. |
| **C-07 / R-14** | Deleted the `purchase`, `upkeep_/gh` and `dispatch_cost` columns from the §2.11 roster and the `purchase_cost` / `upkeep_per_game_hour` / `dispatch_cost` keys from `data/vehicles.json`; added `economy_id` as the join key into doc 03 §2.13(c). Also deleted `repair_material_base` (doc 03 §2.5 `repair_cost()`). §2.7's reward worked example recomputed on doc 03's prices: net **+$687 → +$1,128**. |
| **C-42 / R-11** | Deleted `base_fire_risk_by_archetype` and `level_risk_slope`. The base rate is now doc 02's `fire_ignition_per_hour × fire_condition_mult × state_fire_mult`; doc 06 keeps only `f_power`, `f_weather`, `f_arson`. **`R_fire_base` recalibrated 0.00010 → 0.40** against a stated 300-building reference city, hitting **0.759 fires/game-day** vs the 0.76 target. |
| **C-43 / R-12** | Deleted `S_req_base[archetype]` (12 constants) and `S_LEVEL_SLOPE = 0.35`. `S_req = 0.50 × (doc02.fire_load/20)^0.45`, regenerated for all **60** archetype×level rows; suppression sizing table rebuilt (high_rise L5 T4: **7 engines → 6**). Ruled that the published exponent 0.45 wins over the report's "≈3.6" gloss; **high_rise L5 = 3.060**. |
| **C-44** | Adopted doc 02's `crime_weight` as the within-district weighted target pick, with `STATE_ELIGIBLE` gating; doc 06 authors no attractiveness term. Worked pick added (store 40.1% of incidents from 12.5% of buildings). |
| **C-45** | Crime generation **and** crime target selection moved to the **`crime`** RNG stream; a per-generator stream table added to §2.6 and §4. `traffic` recorded as reserved. |
| **C-46** | Deleted `f_cond = (2−c)²` and the flat `f_freeze = 2.2`; doc 05's `cond_mult` and `load_mult` are multiplied in and its freeze-stress hazard consumed as an additive channel. Both worked examples recomputed: healthy **0.46 → 0.393** breaks/day, neglected+overloaded **0.820 → 1.822**. Tiered `zone_pressure_delta` restated as authoritative. |
| **C-47** | Added an explicit `world.destroy_allowed()` guard to `destroy_building` (and `feeder_destroy`) in §2.7 and the §3.1 op vocabulary: offline the verb returns `REFUSED`, clamps condition to 0.15, freezes `burn_timer` and emits `destroy_refused_offline`. New test 29. |
| **C-48** | Multiplied doc 10's `condition_hazard_mult` into the `traffic_accident` rate as `f_road_cond` (max over incident edges). Worked examples recomputed: 0.687/day at condition 100, **0.742** at 55, **0.866** at 10; the outage cascade is ×2.70. |
| **C-49** | Dropped `weather_mult` and `flood_mult` from `RouteProfile`; also deleted the duplicate `weather_speed_mult` and `road_class_mult` tables from §2.11 and `data/vehicles.json`. The blizzard travel example was recomputed as a peak thunderstorm (same 22.5 gm). |
| **C-50** | Stated explicitly that doc 06 owns unit capacity per station level; published the five ladders (police `[2,3,4,5,6]`, rest `[1,2,3,4,5]`) as a table in §2.11. Numbers unchanged. |
| **C-52** | Moved "unpowered stations have no effect" out of §9's open questions and into §2.11/§6 as a **ruled MVP decision**, with the post-MVP `turnout_min ×2` penalty recorded. |
| **C-53 / R-13** | Doc 06 declared sole owner of storm-damage generation; added the supplier table (doc 07 `wind_kph` + storm-cell mask, doc 04 `exposed_components()`), cell masking and underground exclusion. **`R_storm_base` recalibrated 0.020 → 0.0149** and `exposure_class.tree_adjacent` **1.4 → 1.8**, hitting doc 07's targets at **2.503** (maintained) and **11.948** (neglected) failures per 60-span storm. |
| **C-67** | Added `speed: float` and `heading: float` to `vehicle_state` — persisted in the `fleet` save section and present on the per-tick snapshot for doc 11's Hermite interpolation. |
| **C-70** | Added the mature-city response case to §1.1 as a three-row table (starter 4–14 gm / mature clear 24.2 gm / mature storm+blackout 39.1 gm) with the tier-arrival check, and recorded `speed_mpgm` as approved. New invariant test 23. |
| **G-2** | Wrote the crews split into §2.11: doc 06 owns crews as dispatchable units with capacity `[1,2,3,4,5]`, preemption at **400** and `auto_dispatch_construction: false`; **doc 02 owns the project queue** (`ConstructionQueue.submit/reorder/cancel`); doc 09 owns the phase→crew mapping. Added `construction_job_id` to the unit record and a `construction_job_preempted` event. |
| **C-17** (from §12's amend list) | `difficulty.escalation_mult` re-pointed from "doc 08" to `data/difficulty.json`, owned and loaded by doc 03; doc 06's rows published as an `escalation` block in §8. |
| **C-25 convention** | Added `section_version` to all three save sections (`incidents`, `fleet`, `dispatch`), which previously carried no version key at all. `schema_version` remains envelope-only. |
| **§7** | Test plan grew from 22 to 37 cases: 6 recomputed, 15 new (23–37), one per ruling. |

### Round 2 (report 98 §14 — post-verification rulings)

| ruling | change |
|---|---|
| **RR-4** | **Deleted the `weather_mults` table entirely** — all four sub-tables (`.crime` / `.fire` / `.transformer` / `.traffic`, 36 constants including the dead `snow` / `blizzard` / `fog` columns) removed from §8 and from `data/incidents.json`, replaced by a `weather_channels` binding map that carries **no number**. The four affected generators now name a doc 07 channel in the formula itself: `crime → get_effect("incident_crime_mult")`, `structure_fire → get_effect("fire_ignition_mult")`, `transformer_failure → get_effect("incident_utility_mult")`, `traffic_accident → get_effect("incident_traffic_mult")`. `water_main_break` and `storm_damage` bind to nothing — weather reaches them through `freeze_stress` / `flood_saturation` and through `wind_kph` / the storm cell respectively. **Doc 07 §2.2 is now the sole statement of weather in the project.** Two worked examples moved because the deleted table's flat per-state values are not what `get_effect()` returns: §2.6(b)'s thunderstorm-blackout case **1.044 → 2.398 fires/game-day** (flat 1.60 → `lerp(1.80, 3.00, 0.77) = 2.724`, and the global storm now reaches all 300 buildings, not only the 60 dark ones — C-59), and §2.6(e)'s outage cascade **2.003 → 2.337 accidents/game-day** (`incident_traffic_mult` at RAIN intensity 0.75 still reads 1.40, but rain and night now fall on the 12 lit nodes too). §2.6's preamble, §3.1's schema comment, §5's doc 07 interface row, §8's deleted-key table and §9's open question 6 all restated; new tests 38/39/40. |
| **RR-3** | Road `condition` joins the project-wide `[0,1]` scale (C-14 has no carve-out). §2.6(e) restates doc 10's `condition_hazard_mult` on the rescaled constants — knee `75 → 0.75`, coefficient `0.004 → 0.4` — which leaves **every returned multiplier unchanged** (1.00 / 1.08 / 1.26) while moving the input units. The three worked road-condition values become **100 → 1.00**, **55 → 0.55**, **10 → 0.10**, and test 30's consumed values move with them; §8's `factors.traffic` gains `"road_condition_scale": "[0,1]"`, and §9's range list records road condition alongside building condition. Accident rates at each condition are unchanged (0.687 / 0.742 / 0.866 per game-day); only the outage-cascade row moved, and that is RR-4's doing, not RR-3's. |
| **§7** | Test plan grew from 37 to **40** cases: test 30 recomputed under RR-3 + RR-4, three new (38–40) guarding that no weather number and no `[0,100]` road condition can re-enter this doc. |
| **§9** | Open question 6 (`weather_mults` vs `get_effect()`) **closed by RR-4** and moved into the ruled list; the remaining questions renumbered 6–9. New open question 10 records the *residual* weather constants RR-4 does not reach — §2.4's `heat_mult` / `rain_mult` in `esc_env[structure_fire]`, and §2.8's failure to consume doc 07's `fire_spread_mult` — which are the same defect shape but cannot be fixed without re-deriving the §1.1 response band and test 23's hard invariant. Flagged, not changed. |

### Round 3 (report 98 §15 — closing-audit rulings)

| ruling | change |
|---|---|
| **RR-15** *(part 1 — escalation ownership moves, calibration preserved)* | **Deleted the inline weather-keyed constants from §2.4's `esc_env[structure_fire]`** — `heat_mult = 1.25 if heat_wave` and `rain_mult = 0.80 if rain\|heavy_rain\|thunderstorm`, the last doc-06-authored floats keyed by a doc 07 weather state. They were never keys in `data/incidents.json`, only formula literals, which is why RR-4's grep guards missed them. The term is now `f_wx_esc = weather.get_effect("fire_escalation_mult")` (doc 07 §2.2.1), whose per-state band doc 07 **adopted verbatim** from this doc: `CLEAR 1.00 · CLOUDY 1.00 · RAIN 0.80 · HEAVY_RAIN 0.80 · THUNDERSTORM 0.80 · HEAT_WAVE 1.25`, flat at every intensity. **No calibration moved and no constant was retuned:** the §2.4 worked example re-derives as `1.250 × 1.000 × 1.000 = 1.250`, the tier ladder stays `2.750 / 3.4375 / 4.125 / 4.8125 /gh`, tier 3 lands at `21.818 + 17.455 = 39.273 gm` and tier 5 at `66.286 gm`, so **§1.1's response band is unchanged and test 23's hard invariant keeps its full 0.2 gm margin** (39.1 gm mature-city worst case < 39.3 gm). A storm cross-check was added showing the moved constant reproducing exactly: THUNDERSTORM at intensity 0.77 → `1.524 × 0.80 = 1.2192`, identical to the deleted `rain_mult` path. `esc_base[structure_fire] = 2.20` untouched. The channel is passed through **unclamped** — §2.4's `[0.4, 3.0]` clamp binds only doc-06-authored factors, because re-clamping a doc 07 value would be doc 06 retuning doc 07 by the back door. |
| **RR-15** *(part 2 — spread gains its weather term; **this one moves numbers**)* | **§2.8 `rate(target)` now multiplies in `g_weather = weather.get_effect("fire_spread_mult")`**, a channel doc 07 has published for all six MVP states since its first draft and which **nothing read**. Doc 06 is its first consumer. Worked values re-derived on the fixed geometry (T3 apartment source, wooden house 14 m downwind, 4 neighbours): the pre-RR-15 example's 50 kph wind is only reachable in a `THUNDERSTORM` (doc 07's `wind_kph` bands), at intensity 0.3636, where `g_weather = 0.545455` and the rate falls **0.575027 → 0.313651 /gh** — per-roll `p` **4.68% → 2.58%**, hourly `p` **43.7% → 26.9%**. A four-weather table was added, each row at a stated intensity with `wind_kph` drawn from that state's own band so both `g_wind` and `g_weather` move: `CLEAR 0.50` 0.362267 /gh (30.4%), `HEAT_WAVE 0.80` 0.564251 /gh (43.1%), `THUNDERSTORM 0.3636` 0.313651 /gh (26.9%), `THUNDERSTORM 0.77` 0.341007 /gh (28.9%). At doc 07's reference storm spread is cut to **48.45%** of dry-air (`0.703833 → 0.341007 /gh`, hourly `p` 50.5% → 28.9%) while the *same* storm raises ignition ×2.724 and leaves escalation at 0.80 — three channels, three answers. Contract notes recorded: **no wind double-count** (wind reaches spread only via `g_wind`), the channel is intensity-lerped so every quoted figure names state *and* intensity, and it is passed through unclamped. §2.7's cascade ratios (`g_stage` ×2.9 at T3, ×1.8 adjacency at T4) are unaffected — `g_weather` is a common factor. *(Housekeeping: the pre-RR-15 line printed `0.5746`; the exact product is `0.575027`, the difference being the old example's 3-dp rounding of `g_dist` to 0.513. Its published 4.68% / 43.7% reproduce from the unrounded value to 0.01 pp, so this is precision, not calibration.)* |
| **§5 / §2.6 / §3.1 / §8** | The doc 07 interface row moved from **four channels to six** (`fire_escalation_mult` and `fire_spread_mult` join the four RR-4 generation channels), with the call site named for each. §2.6 gained a pointer that two channels are consumed *outside* generation. §3.1's schema comment records the deletion. §8 gained a `fire_weather_channels` map (`escalation` / `spread` → channel **names** only, no numbers), a `_fire_weather_note` stating the three-questions/three-channels rule and the no-wind-double-count and no-clamp contracts, `factors.fire` gained the escalation wind/hydrant constants that doc 06 legitimately owns (`esc_wind_knee_kph 20.0`, `esc_wind_k 0.010`, `esc_hydrant_knee 0.7`, `esc_hydrant_k 0.6`) plus `esc_weather_source`, and `fire` gained `g_weather_source`. The deleted-key table records both halves of the ruling. **`data/incidents.json` still carries no weather number and no weather state key.** |
| **§2.1 / §6** (housekeeping under RR-15) | `next_discontinuity_h()` gained an explicit **(h) weather-segment boundary** breakpoint. §2.6 had always asserted the integrator "breaks at day/night and weather boundaries", but §2.1's enumerated list did not contain it; RR-15 makes two further rates (`fire_escalation_mult` in escalation, `fire_spread_mult` in spread) depend on that breakpoint for online/offline exactness, so the implied item is now written down. No behaviour change — tests 1/2/9 already required it. §6's MVP-cut list records the six wired channels and `g_weather`. |
| **§7** | Test plan grew from 40 to **43** cases. Tests 5, 9, 23 and 38 restated: 5 and 23 now drive `esc_env` through the live channel while asserting the *same* expectations (the point of RR-15), 9 re-runs under `HEAVY_RAIN` to prove `g_weather` enters the hazard rate rather than the per-roll probability, and 38's grep guard widens from generation to the whole `sim/incidents/` tree and adds the `heat_mult` / `rain_mult` identifiers. New: **41** (`esc_env` consumes the channel; golden `1.250` CLEAR and `1.2192` storm; intensity-invariance; no clamp), **42** (spread consumes `fire_spread_mult`; the four re-derived rates; removing it reproduces the pre-RR-15 `0.703833 /gh`), **43** (the three fire channels are read at three distinct sites with three distinct values and none may be substituted; wind is not double-counted). |
| **§9** | Open question 10 **closed by RR-15** and moved into the ruled list, recording both halves — the escalation move that changed no number, and the spread consumption that did — plus the reason the audit's feared 25–44% escalation cut never happened (doc 07 published a *new* channel instead of overloading `fire_spread_mult`). Questions 6–9 remain open and none of them is a weather question. **Doc 06 now authors no weather constant anywhere: not in generation (RR-4), not in escalation, not in spread (RR-15).** |
