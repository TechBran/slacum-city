# 07 — Weather System & Disaster Director

**Status:** Amended per `98-consistency-report.md` — Round 1 (Ruling Zero, C-16, C-17, C-28, C-53, C-54, C-55, C-56, C-57, C-58, C-59) and **Round 3 (RR-15)**. Complies with `docs/design/00-constitution.md` (LOCKED). See the closing *Amendments applied* section.
**Covers:** spec §18 (Weather), §20 (Disaster Director), §43.4 (MVP disaster: Severe Thunderstorm), §19.1 partial.
**Owns data files:** `data/weather.json`, `data/director.json`. **Authors** the `pressure` section of doc 03's `data/difficulty.json` (§8.3) without owning the file.
**Owns sim code:** `sim/weather/`, `sim/director/`, `sim/disasters/severe_thunderstorm.gd`.
**Doc numbering:** on-disk filenames, per report 98 Ruling Zero. There is no other map.

---

## 1. Overview & Goals

Weather is the game's ambient pressure dial and the Disaster Director is its conductor. Together they answer one question every hour of city time: *what is about to test this city, and does the player have a fair chance to see it coming?*

**Role in the core loop.** Weather continuously modulates every other system's numbers (power load, transformer heat, road speed, fire behaviour, incident rates, water demand), so the same city performs differently at 03:00 in clear weather than at 15:00 in a heat wave. The Disaster Director sits above weather and decides *when* to escalate ambient pressure into an authored crisis — and, critically, when to shut up and let the player rebuild.

**Goals**

1. **Weather is never cosmetic** (Core Rule 8). Every state changes at least four other systems' inputs through one published multiplier interface.
2. **Forecast is a real strategic resource.** The player can see 6–24 game-hours ahead with degrading accuracy, and preparation actions taken during the warning window measurably change outcomes.
3. **Readable causality** (Core Rule 12). Every point of storm damage traces to a named component with a named reason (low condition, no arrester, no redundancy, built on a low tile). The post-storm report says so explicitly — and after report 98 it does so by *reading back* what the owning systems resolved and priced, rather than by restating their tables here.
4. **Disasters test prior planning, never punish arbitrarily** (Core Rule 9, spec §20.2). The Director's threat budget scales *up* with preparedness and *down* with distress; hard fairness rules are absolute gates, not soft weights.
5. **Deterministic and offline-safe.** Weather and Director advance identically through the fine tick path and the 1-game-hour coarse offline path (constitution §4), on the named `weather` and `director` RNG streams (constitution §5).

**Non-goals for MVP:** snow, blizzard, fog, extreme cold, high-wind-as-a-state, per-district weather, multi-cell storms, hail, hurricanes/tornadoes/earthquakes/wildfires, evacuation systems.

---

## 2. Mechanics

### 2.1 Weather state machine

Six MVP states: `CLEAR`, `CLOUDY`, `RAIN`, `HEAVY_RAIN`, `THUNDERSTORM`, `HEAT_WAVE`. Deferred: `SNOW`, `BLIZZARD`, `FOG`, `EXTREME_COLD`.

Weather is a **committed timeline**, not a per-tick roll. The system maintains a queue of segments covering at least `horizon_min = 1440` game-minutes (24 game-hours) into the future. This is the architectural keystone: the forecast can only be honest and stable if the future is already decided, and the Director can only guarantee warning lead times if it can insert a segment into a known future.

```
Segment := { id, state, start_min, end_min, intensity, source, event_id }
source ∈ { "chain", "director" }
```

**Generation.** Whenever `timeline.last().end_min - now < horizon_min`, append one segment:

1. `next = weighted_pick(transition_row[last.state] ⊙ season_mult[season], stream="weather")`
2. `duration = quantize15(uniform_int(dur_min[next], dur_max[next]))`
3. `intensity = clamp(uniform(0,1) ^ gamma[next], 0.0, 1.0)`

`quantize15` rounds to the nearest 15 game-minutes so segment boundaries always land on a SimTick boundary (constitution §4: SimTick = 15 game-seconds; 15 game-minutes = 60 ticks) and so the coarse 1-hour offline path never splits a segment inconsistently.

**Transition weight table** (base, before season modifiers; rows sum to 1.00). No self-transitions — persistence is expressed by duration, not by a self-loop.

| from ↓ / to → | CLEAR | CLOUDY | RAIN | HEAVY_RAIN | THUNDERSTORM | HEAT_WAVE |
|---|---|---|---|---|---|---|
| CLEAR        | —    | 0.72 | 0.14 | 0.03 | 0.04 | 0.07 |
| CLOUDY       | 0.45 | —    | 0.35 | 0.08 | 0.10 | 0.02 |
| RAIN         | 0.15 | 0.45 | —    | 0.28 | 0.12 | 0.00 |
| HEAVY_RAIN   | 0.00 | 0.40 | 0.35 | —    | 0.25 | 0.00 |
| THUNDERSTORM | 0.05 | 0.30 | 0.35 | 0.30 | —    | 0.00 |
| HEAT_WAVE    | 0.55 | 0.25 | 0.00 | 0.00 | 0.20 | —    |

Note the `HEAT_WAVE → THUNDERSTORM` edge at 0.20: heat waves break in storms. That is the single most dangerous sequence in the game (transformers already hot, then lightning) and it exists on purpose.

**Duration ranges and intensity bias**

| state | dur_min | dur_max | gamma | notes |
|---|---|---|---|---|
| CLEAR | 180 | 720 | 1.0 | 3–12 h |
| CLOUDY | 120 | 480 | 1.0 | 2–8 h |
| RAIN | 60 | 240 | 1.0 | 1–4 h |
| HEAVY_RAIN | 30 | 120 | 1.2 | biased mild |
| THUNDERSTORM | 45 | 150 | 1.6 | strongly biased mild — severe storms come from the Director, not the chain |
| HEAT_WAVE | 1440 | 4320 | 0.8 | 1–3 game-days, biased hot |

`gamma > 1` biases intensity low, `< 1` biases high. Chain-generated thunderstorms average intensity ≈ 0.38; Director-scheduled severe thunderstorms override intensity (§2.7.1).

**Seasons.** The calendar is **doc 01's** *(report 98 C-28)*: `days_per_season = 30`, `seasons_per_year = 4`, a **120-game-day year**. This doc derives nothing — it reads `ctx.season_index ∈ {0,1,2,3}` and `ctx.season_progress ∈ [0,1)` off `TimeContext` and indexes the table below. *(The old `season_length_days = 21`, the 84-game-day year and the `floor((sim_day % 84) / 21)` derivation are deleted — the calendar lives in `data/time.json`, owned by doc 01.)* Season multipliers are applied elementwise to the transition row, then the row is renormalised.

**Worked example — season lookup** (doc 01 §2.2's own example, recomputed here on the 30-day calendar): `day_index = 159` → `season_index = (159 / 30) % 4 = 5 % 4 = 1` → **SUMMER** (`year_index = 1`). At 09:20 that day (`minute_of_day = 560`): `season_progress = ((159 % 30) × 1440 + 560) / 43200 = (9 × 1440 + 560) / 43200 = 13,520 / 43,200 = **0.3130**`. On the old 84-day year the same tick read as `(159 % 84) / 21 = 75 / 21 → season 3 (WINTER)` — the four-row table below is unchanged, but every boundary moved, so no season-dependent expectation from before C-28 survives.

| season | CLEAR | CLOUDY | RAIN | HEAVY_RAIN | THUNDERSTORM | HEAT_WAVE | temp_base_c |
|---|---|---|---|---|---|---|---|
| SPRING | 1.0 | 1.0 | 1.20 | 1.00 | 1.00 | 0.20 | 16 |
| SUMMER | 1.0 | 1.0 | 0.90 | 1.10 | 1.40 | 1.60 | 26 |
| AUTUMN | 1.0 | 1.0 | 1.30 | 1.20 | 0.80 | 0.30 | 14 |
| WINTER | 1.0 | 1.3 | 1.10 | 1.00 | 0.30 | 0.00 | 4 |

Winter with snow deferred is simply cold rain and cloud. Flagged in §9.

**Worked example — one transition.** Current `CLOUDY`, season `SUMMER`.
Base row × summer mult = `clear 0.45×1.0=0.450`, `rain 0.35×0.9=0.315`, `heavy 0.08×1.1=0.088`, `thunder 0.10×1.4=0.140`, `heat 0.02×1.6=0.032`. Sum `= 1.025`.
Normalised: `clear 0.4390, rain 0.3073, heavy 0.0859, thunder 0.1366, heat 0.0312`.
Cumulative: `0.4390, 0.7463, 0.8322, 0.9688, 1.0000`. RNG `u = 0.62` → **RAIN**.
`duration = quantize15(uniform_int(60,240)) → 165 min`. `intensity = 0.71^1.0 = 0.71`.

### 2.2 Effect multiplier table

One published interface: `WeatherSystem.get_effect(channel) -> float`. Each state defines a `[min, max]` pair per channel; the live value is `lerp(min, max, intensity)`.

**This table is authoritative for all five weather multiplier families** *(report 98 C-57)*. Doc 02's inline `weather_load_mult` / `weather_water_mult` / `weather_decay_mult` / `weather_fire_mult` / `weather_build_mult` constants are deleted, not overridden — no placeholder survives anywhere. `get_effect()` accepts doc 02's short aliases so its call sites resolve without a rename:

| alias (doc 02 call site) | canonical channel |
|---|---|
| `load_mult` | `power_load_mult` |
| `water_mult` | `water_demand_mult` |
| `decay_mult` | `condition_decay_mult` |
| `fire_mult` | `fire_ignition_mult` |
| `build_mult` | `construction_speed_mult` |

The one genuine disagreement is ruled in this doc's favour: **thunderstorm `construction_speed_mult` is `0.45 → 0.25`**, not doc 02's flat 0.55. A thunderstorm should stop a crane.

| channel | CLEAR | CLOUDY | RAIN | HEAVY_RAIN | THUNDERSTORM | HEAT_WAVE |
|---|---|---|---|---|---|---|
| `power_load_mult` | 1.00→1.03 | 0.98→0.98 | 1.02→1.05 | 1.05→1.10 | 1.06→1.14 | 1.25→1.55 |
| `water_demand_mult` | 1.00→1.05 | 0.98→0.98 | 0.94→0.90 | 0.90→0.85 | 0.90→0.85 | 1.30→1.60 |
| `road_speed_mult` | 1.00→1.00 | 1.00→1.00 | 0.90→0.84 | 0.78→0.62 | 0.72→0.55 | 0.99→0.97 |
| `fire_spread_mult` | 1.00→1.10 | 0.95→0.95 | 0.70→0.55 | 0.50→0.35 | 0.60→0.45 | 1.35→1.70 |
| **`fire_escalation_mult`** *(RR-15)* | **1.00→1.00** | **1.00→1.00** | **0.80→0.80** | **0.80→0.80** | **0.80→0.80** | **1.25→1.25** |
| `fire_ignition_mult` | 1.00→1.00 | 0.95→0.95 | 0.88→0.80 | 0.78→0.70 | 1.80→3.00 | 1.30→1.60 |
| `incident_crime_mult` | 1.00→1.00 | 1.00→1.00 | 0.88→0.82 | 0.78→0.70 | 0.82→0.75 | 1.15→1.35 |
| `incident_traffic_mult` | 1.00→1.00 | 1.02→1.02 | 1.25→1.45 | 1.60→2.00 | 1.80→2.30 | 1.00→1.05 |
| `incident_utility_mult` | 1.00→1.00 | 1.00→1.00 | 1.05→1.10 | 1.25→1.60 | 2.00→3.50 | 1.40→1.90 |
| `line_failure_rate_mult` | 1.00→1.00 | 1.00→1.00 | 1.10→1.25 | 1.40→1.90 | 2.50→6.00 | 1.05→1.10 |
| `outage_health_risk_mult` | 1.00→1.00 | 1.00→1.00 | 1.00→1.00 | 1.05→1.10 | 1.05→1.10 | 2.00→3.50 |
| `solar_output_mult` | 1.00→1.00 | 0.55→0.55 | 0.32→0.24 | 0.18→0.12 | 0.14→0.08 | 1.05→1.05 |
| `construction_speed_mult` | 1.00→1.00 | 1.00→1.00 | 0.92→0.86 | 0.72→0.55 | 0.45→0.25 | 0.88→0.78 |
| `condition_decay_mult` | 1.00→1.00 | 1.00→1.00 | 1.10→1.20 | 1.25→1.40 | 1.40→1.80 | 1.20→1.40 |
| `wind_kph` | 5→15 | 8→20 | 10→25 | 15→40 | 30→85 | 3→12 |
| `precip_mm_h` | 0→0 | 0→0 | 2→6 | 8→20 | 12→35 | 0→0 |
| `temp_offset_c` | +1→+3 | −1→−2 | −2→−4 | −3→−6 | −3→−7 | +7→+14 |

**Transformer heat is derived, not tabled.** A second hand-authored table would drift from the temperature model, so there is exactly one source of truth:

```
ambient_temp_c = season_temp_base + diurnal_amp * cos(2π * (t_min_of_day - 900) / 1440)
                 + lerp(temp_offset_min, temp_offset_max, intensity)
diurnal_amp = 6.0        # peak 15:00, trough 03:00
transformer_heat_rate_mult = clamp(1.0 + (ambient_temp_c - 20.0) / 25.0, 0.70, 2.40)
```

**Worked example — thunderstorm effects at intensity 0.77, summer, 18:00 (t_min_of_day = 1080).**
`power_load_mult = lerp(1.06, 1.14, 0.77) = 1.1216`
`road_speed_mult = 0.72 − 0.17×0.77 = 0.5891`
`wind_kph = lerp(30, 85, 0.77) = 72.4`
`precip_mm_h = lerp(12, 35, 0.77) = 29.7`
`temp_offset = −3 + (−4 × 0.77) = −6.08`
`ambient = 26 + 6×cos(2π×0.125) + (−6.08) = 26 + 4.243 − 6.08 = 24.16 °C`
`transformer_heat_rate_mult = 1 + 4.16/25 = 1.166`

**Worked example — heat wave at intensity 0.80, summer, 15:00.**
`ambient = 26 + 6.0 + (7 + 7×0.80) = 26 + 6 + 12.6 = 44.6 °C`
`transformer_heat_rate_mult = clamp(1 + 24.6/25) = 1.984`
`power_load_mult = lerp(1.25, 1.55, 0.80) = 1.49`
A city running 88% grid utilisation in clear weather is at 131% here. That is the heat-wave crisis, delivered entirely through multipliers with no bespoke code.

**`precip01` — the continuous renderer channel** *(report 98 C-58)*. `precip_mm_h` is a per-state band; the renderer (doc 11) needs a normalized ramp for `amount_ratio` and its wetness integrator. This doc additionally publishes:

```
precip01 = clamp(precip_mm_h / PRECIP01_SCALE_MM_H, 0.0, 1.0)      PRECIP01_SCALE_MM_H = 35.0
```

35 mm/h is the table maximum (`THUNDERSTORM` at intensity 1.0), so `precip01` spans the full `[0,1]` with no headroom wasted. **`precip01` is the one channel that is continuous across segment boundaries:** during the final `SEGMENT_CROSSFADE_GS = 60` game-seconds (4 SimTicks) of a segment it is cross-faded into the next segment's value,

```
u        = (SEGMENT_CROSSFADE_GS - remaining_gs) / SEGMENT_CROSSFADE_GS      # 0 → 1
precip01 = lerp(precip01(this_segment), precip01(next_segment), u)
```

which is free and exact because the timeline is committed — the next segment already exists. Every *other* channel remains a step function at the boundary: sim math needs step semantics for coarse/fine parity (test 3), and only the renderer needs the ramp.

**Worked — thunderstorm at intensity 0.77:** `precip_mm_h = 29.7` → `precip01 = 29.7 / 35 = **0.8486**`. Crossing into the following `HEAVY_RAIN` segment at intensity 0.40 (`precip = lerp(8, 20, 0.40) = 12.8` → `precip01 = 0.3657`), 30 game-seconds before the boundary `u = 0.5` and the published value is `lerp(0.8486, 0.3657, 0.5) = **0.6072**`.

**Who rolls line failures** *(report 98 C-53)*. **Doc 06 owns all incident generation, including storm damage.** This doc does not roll line failures and neither does doc 04 — the old `storm_owns_line_failures` suppression flag is deleted because there is nothing left to suppress. The split is:

| doc | contributes |
|---|---|
| **07** (this doc) | `wind_kph`, `precip_mm_h` / `precip01`, the storm-cell mask (`in_storm_cell(pos)`), and the storm's phase/duration |
| **04** | per-component `weather_exposure`, `tree_adjacent`, `underground`, `condition`, and the failure-type resolution once a failure is generated |
| **06** | the `storm_damage` generator (§2.6(f)) — the only line-failure generator in the game |

`line_failure_rate_mult` survives as a published channel, but it now scales only doc 04's **non-wind background** hazard curve (thermal, condition, age). Doc 06's storm generator reads `wind_kph` directly, so wind is never counted twice.

#### 2.2.1 The three fire channels *(report 98 RR-15)*

Fire weather is **three different questions**, and this doc publishes one channel per question. They multiply into doc 06's math at three different places; none of them restates another, and none of them may be substituted for another:

| channel | the question it answers | consumed by | ruling |
|---|---|---|---|
| `fire_ignition_mult` | how *often* does a fire start here? | doc 06 §2.6 fire generation (via doc 02's `fire_mult` alias) | RR-4 |
| **`fire_escalation_mult`** | how fast does *this already-burning* fire's severity climb? | doc 06 §2.4 `esc_env[structure_fire]` | **RR-15** |
| `fire_spread_mult` | how readily does it *jump* to the next building? | doc 06 §2.8 `rate(target)` | **RR-15** |

**`fire_escalation_mult` — ownership moved here, calibration preserved *exactly***. Under RR-15 the weather-keyed constants that used to live in doc 06 §2.4's `esc_env[structure_fire]` become a published channel of this table. Doc 06 deletes them and calls `get_effect("fire_escalation_mult")`; **the numbers are adopted verbatim, not re-derived**, so doc 06's §1.1 response band and its test 23 invariant stand untouched. The source expression, as doc 06 shipped it:

```
esc_env[structure_fire] = (1 + 0.010*max(0, wind_kph - 20)) * heat_mult * rain_mult * hydrant_penalty
    heat_mult = 1.25 if heat_wave else 1.0
    rain_mult = 0.80 if rain|heavy_rain|thunderstorm else 1.0
```

Only `heat_mult × rain_mult` is weather-keyed and only that product moves. The wind term stays in doc 06 (it reads this doc's `wind_kph` directly, per C-53) and `hydrant_penalty` is doc 05/06 physics. Because weather state is a single global enum (§2.3 / C-59), the two flags are mutually exclusive — no state can be both a heat wave and raining — so the product is always exactly one of `1.25`, `0.80` or `1.00`:

| state | doc 06 source branch | `heat_mult × rain_mult` | adopted band |
|---|---|---|---|
| `CLEAR` | neither flag → `1.0 × 1.0` | 1.00 | **1.00→1.00** |
| `CLOUDY` | neither flag → `1.0 × 1.0` | 1.00 | **1.00→1.00** |
| `RAIN` | `rain_mult` fires | `1.0 × 0.80` = 0.80 | **0.80→0.80** |
| `HEAVY_RAIN` | `rain_mult` fires | `1.0 × 0.80` = 0.80 | **0.80→0.80** |
| `THUNDERSTORM` | `rain_mult` fires | `1.0 × 0.80` = 0.80 | **0.80→0.80** |
| `HEAT_WAVE` | `heat_mult` fires | `1.25 × 1.0` = 1.25 | **1.25→1.25** |

All six MVP states are covered by doc 06's expression — `CLEAR` and `CLOUDY` are not *named* by it but fall through both `else` branches to `1.0`, so their 1.00 is **adopted, not invented**. The four deferred states (`SNOW`, `BLIZZARD`, `FOG`, `EXTREME_COLD`) have no doc-06 value and are not published; when they land they enter this row at **1.00** as a neutral default and must be balanced deliberately, not inherited (§9 item 14).

**This channel is flat by ruling — the band endpoints are equal, so it is intensity-invariant.** Doc 06's constants were step functions of the weather *state* with no intensity term, and RR-15 says calibration is preserved; giving the channel a slope would have been a re-tune wearing an ownership move's clothes. the §2.2 rule `lerp(min, max, intensity)` with `min == max` returns the constant at every intensity, so the general interface needs no special case. Widening these bands later is a deliberate balance change that must re-derive doc 06 §1.1 and test 23.

**Worked check — nothing moved.** Doc 06's §2.4 worked example (wood house L2, wind 45 kph, **clear**, hydrant ratio 1.0) computed `esc_env = 1 + 0.010×25 = 1.25`. Recomputed through the channel: wind term `1 + 0.010 × max(0, 45 − 20) = 1 + 0.250 = 1.250`; `get_effect("fire_escalation_mult") = 1.00` (CLEAR, any intensity); `hydrant_penalty = 1 + 0.6 × max(0, 0.7 − 1.0)/0.7 = 1.000`. Product `1.250 × 1.00 × 1.000 = **1.250**` — identical, so the tier ladder (2.750 / 3.438 / 4.125 / 4.813 per gh) and the 66.3-game-minute tier-5 arrival are unchanged, and doc 06's test 23 hard invariant (worst mature-city response 39.1 gm < tier 3 at 39.3 gm) is untouched. Likewise this doc's own §2.7.8 City B fires: the reference storm is `THUNDERSTORM`, whose adopted value is `0.80` — the same 0.80 that priced the two apartment fires at `damage_fraction 0.29`, so the **$44,036** bill and the 42.8× spread stand as written.

**Why this is a new channel and not `fire_spread_mult`.** Report 98's audit note asked whether the existing spread channel could absorb the escalation constants. It cannot, and the arithmetic is the reason. In a thunderstorm `fire_spread_mult` runs `0.60→0.45`, so substituting it for the adopted `0.80` would scale escalation by `0.60/0.80 = 0.750` at intensity 0 and `0.45/0.80 = 0.5625` at intensity 1.0 — a **25.0% to 43.8% cut** in escalation rate, landing straight on the tier-arrival times and on test 23's margin of `39.3 − 39.1 = 0.2` game-minutes. That is a balance change, and RR-15 rules it out: ownership moves, numbers do not. The two channels stay separate because they are separate quantities — a downpour wets a *neighbouring* roof far more than it slows a fire already inside a structure.

**`fire_spread_mult` — confirmed published, per-state, and about to be read.** It has been in this table since the first draft (`CLEAR 1.00→1.10`, `CLOUDY 0.95→0.95`, `RAIN 0.70→0.55`, `HEAVY_RAIN 0.50→0.35`, `THUNDERSTORM 0.60→0.45`, `HEAT_WAVE 1.35→1.70`) and in `data/weather.json` §8.1 for all six MVP states; it is intensity-lerped like every other non-flat channel, and until RR-15 it had no consumer. Doc 06 §2.8 now multiplies it into `rate(target)`. Two contract notes for that consumer:

1. **No wind double-count.** These values are a *fuel-moisture and ambient-heat* term — a wet roof does not catch, a sun-baked one does. Wind enters spread only through doc 06's own `g_wind = 1 + 1.2 × (wind_kph/60) × max(0, cos θ)`, which reads this doc's published `wind_kph`. The two are orthogonal by construction, the same way `line_failure_rate_mult` was narrowed to non-wind hazard under C-53.
2. **Reference value for doc 06's re-derivation.** At the §2.7 reference storm (`THUNDERSTORM`, intensity 0.77) the published value is `lerp(0.60, 0.45, 0.77) = 0.60 − 0.15 × 0.77 = 0.60 − 0.1155 = **0.4845**`. At `CLEAR` intensity 0 it is `1.00` and at `CLEAR` intensity 1 it is `1.10`, so doc 06's clear-weather worked example moves by at most +10%.

### 2.3 Storm cell (spatial weather)

**Ruled scope of spatial weather** *(report 98 C-59)* — stated explicitly because two sibling docs asked:

> **Weather state is city-wide global.** There is exactly one `(state, intensity)` for the whole city at any tick. Every effect channel of §2.2 is global, roads samples the global state, and the renderer renders the global state. **The `THUNDERSTORM` storm cell is the only spatial weather object, and it affects exactly two things: lightning target eligibility (§2.7.3) and flood accumulation (§2.4).** It never modulates a global effect channel and never produces a second weather region, so no boundary popping exists in MVP. Doc 10's open question X-4 and doc 11's §9.12 are closed by this paragraph.

Within that scope, `THUNDERSTORM` spawns a **cell** with a position, so lightning strikes and heavy rain sweep across the map rather than blanket it (spec §18: "weather should move visibly across the city").

```
radius_tiles = max(48, 0.60 * city_bounding_radius_tiles)
heading_deg  = uniform(0, 360)                        # rolled at spawn
speed_tpm    = uniform(1.6, 3.2)                      # tiles per game-minute
spawn        = city_center - heading_unit * (city_bounding_radius_tiles + radius_tiles)
```

Advection speed is **deliberately decoupled from `wind_kph`**: physically a 72 kph storm crosses a 240-tile (1.9 km) city in ~2.7 minutes, which would make the cell useless as a gameplay object. 1.6–3.2 tiles/min gives a 75–150 minute traverse that matches storm duration. Surface `wind_kph` still drives all damage. Gameplay over realism, stated openly (§9).

A component is eligible for a lightning strike only if `distance(component, cell_center) <= radius_tiles`. As the cell tracks across the map, the at-risk set moves with it.

### 2.4 Localized flooding (stub)

Only road tiles whose land block reports `elevation_class == LOW` accumulate water. Each such tile carries `depth_mm`, updated on the utilities cadence (4 Hz, evaluated in 15-game-second steps, integrated per game-minute):

```
inflow_mm_h  = precip_mm_h * runoff_concentration          # LOW = 6.0, MID = 1.0, HIGH = 0.4
net_mm_h     = inflow_mm_h - drain_rate_mm_h * sandbag_or_drain_bonus
depth_mm     = clamp(depth_mm + net_mm_h * dt_hours, 0, 900)
drain_rate_mm_h = 40.0
```

| depth_mm | state | `road_speed_mult` on that tile | side effects |
|---|---|---|---|
| 0–39 | dry/wet | 1.00 | — |
| 40–99 | nuisance | 0.75 | — |
| 100–199 | standing water | 0.45 | 4%/10 min chance of a stalled-vehicle traffic incident |
| 200–349 | flooded | 0.15 | closed to civilian routing; 30%/10 min forced trip of a substation/pump on this tile |
| 350+ | impassable | edge removed from road graph | emergency routing must detour; substation/pump on tile forced offline, condition −0.15 |

**Worked example.** LOW tile, storm precip 25 mm/h sustained 60 minutes.
`inflow = 25 × 6.0 = 150 mm/h`; `net = 150 − 40 = 110 mm/h`; after 60 min `depth = 110 mm` → **standing water**, `road_speed_mult = 0.45`.
Rain then stops: `net = −40 mm/h`, so the tile drains to 0 in 2.75 game-hours. Roads stay degraded well after the storm exits — the aftermath tail is free.

Flood depth multiplies with the weather-wide `road_speed_mult`: a flooded tile during a thunderstorm is `0.5891 × 0.15 = 0.088` — effectively a wall.

For consumers that want a scalar rather than a band: `flood_saturation(tile) = clamp(depth_mm / 350.0, 0, 1)` (0 = dry, 1 = impassable). `flood_saturation_city` is the area-weighted mean over LOW tiles. Roads (doc 10) uses this for its ground-condition term.

> **THE SIM HALF SHIPPED AND THE PLAYER NEVER SAW IT — ✅ CLOSED 2026-08-20 (doc 91 A91-D-26, report 98 RR-53).** `sim/weather/flood_field.gd` was live, not a stub — a two-real-hour soak logged **460 `flood_level_changed`** and 92 `road_closed_flood`, and doc 10's closures fired off it correctly. But `flood_level_changed` was consumed by **nothing**: `game/render/weather_fx.gd` matched exactly three types (`weather_changed`, `lightning_strike`, `lightning_flash_cosmetic`), `game/main.gd`'s `_on_sim_batch` translator had no arm for it, and it appeared in neither `data/ui.json.event_log.events` nor `data/notifications.json.bindings`. **Standing water was integrated continuously and was never drawn, never announced and never logged.** The only way a player learned a tile had flooded was indirectly, through `road_closed_flood` — which *is* wired to both routers, and which only fires at the 350 mm band. The three bands below it were invisible.
>
> **What ships now.** The band table above is unchanged in every number; nothing in `sim/` moved and the state hashes are identical (RR-53). What changed is that all five bands now reach the player, and each reaches them by the route that suits it:
>
> | band | depth | how the player learns |
> |---|---|---|
> | dry/wet | 0–39 mm | — |
> | nuisance | 40–99 mm | **drawn**: puddles in `game/render/flood_view.gd`. Not narrated, on purpose |
> | standing water | 100–199 mm | drawn, **event log** (weather), **push** `flood_started` (P2) |
> | flooded | 200–349 mm | drawn, **event log**, **push** `flood_deepening` (P1) |
> | impassable | 350 mm+ | drawn (the sheet stands above the kerb), **push** `road_flooded` — already wired — and `road_reopened` on the way down, which nothing consumed before |
>
> The rule behind that column, adopted as doc 93's event ruling: **narrate the bands that change what the player can DO; draw the ones that only change how the street looks.** A film of water in the gutter is something to see, not something to be told, and its consumer is the renderer.
>
> **The renderer is `game/render/flood_view.gd`, not a `WeatherFX` arm.** The cheap fix this note used to propose — raise `sc_wetness` on the affected tiles — cannot be done there and would be wrong if it could: `sc_wetness` is a **project shader global**, one float for the whole world, and `WeatherFX` owns it as §2.9's city-wide rain integrator. A flood is the opposite shape of data — per land block, outliving the rain that caused it by hours, routinely at different bands a hundred metres apart. Folding it into the global would flood the whole city or none of it. So the flood is geometry: one MultiMesh of 8 m quads over the flooded cell's **road tiles** (this section's own rule — a 128 m sheet over the block would put standing water through every building on it), one draw call while water stands and none when the city is dry.
>
> **The renderer's query on load is this section's persisted field, and there is no render-side save state.** `WeatherSystem.serialize()` already writes `"flood": flood.serialize()` → `{"tiles": {cell: depth_mm}}`, so a city resumed at the peak of a flood has the answer in hand before the first frame; the view takes that dictionary through `prime()` and snaps to it. Waiting for the next band crossing would have been wrong twice over — on a draining field the next crossing can be a game-hour away, and a render-side copy of a sim fact can only ever disagree with it.

### 2.5 Forecast system

The forecast reads the committed timeline and degrades it as a function of lead time. Because the timeline is committed, forecasts *converge* toward truth rather than jittering.

```
lead = segment.start_min - now
p_correct(lead) = clamp(base_accuracy - accuracy_decay * (lead / 1440) + station_bonus, 0.50, 0.99)
base_accuracy = 0.97,  accuracy_decay = 0.42,  station_bonus = 0.0 in MVP
```

| lead | p_correct |
|---|---|
| 0 h | 0.97 |
| 3 h | 0.918 |
| 6 h | 0.865 |
| 12 h | 0.760 |
| 24 h | 0.550 |

On failure the displayed state is drawn from a **confusion table** — neighbours only, so the forecast is wrong, not insane: `CLEAR→{CLOUDY 1.00}`; `CLOUDY→{CLEAR .50, RAIN .50}`; `RAIN→{CLOUDY .45, HEAVY_RAIN .35, THUNDERSTORM .20}`; `HEAVY_RAIN→{RAIN .55, THUNDERSTORM .45}`; `THUNDERSTORM→{HEAVY_RAIN .60, RAIN .40}`; `HEAT_WAVE→{CLEAR .70, CLOUDY .30}`.

Also perturbed: `displayed_intensity = clamp(true_intensity + gauss(0, 0.06 + 0.10*lead/1440), 0, 1)` and `displayed_start = true_start ± uniform_int(0, 10 + 40*lead/1440)` minutes.

**Stability.** All forecast noise is derived from `hash(segment.id, forecast_refresh_index)`, where `forecast_refresh_index = floor(now / 60)`. The forecast therefore updates once per game-hour and is byte-identical between refreshes — no shimmer, no save-scumming by reopening the panel.

**Two inviolable honesty rules:**
1. **No hidden severe.** Once `lead <= min_warning_min` for a Director-scheduled event, the forecast shows the truth with `p_correct = 1.0`. Fairness rule F7 outranks forecast noise.
2. **No near-term false alarms.** The confusion table may never *invent* `THUNDERSTORM` or `HEAT_WAVE` at `lead <= 180` minutes. False alarms are allowed only beyond 3 hours, where they read as normal forecast uncertainty rather than a lie.

**UI presentation bands** (contract for the HUD doc):

| lead | presentation |
|---|---|
| 0–6 h | exact icon + exact start time + intensity bar |
| 6–12 h | icon + "≈HH:MM ±30m" window |
| 12–24 h | probability phrase only, e.g. "Storms likely (65%)" where % = `round(p_correct × 100)` for the true state |

---

### 2.6 Disaster Director v1

#### 2.6.1 Inputs and derived scores

Evaluated once per game-hour on the `director` RNG stream.

| input | source | type |
|---|---|---|
| `city_age_days` | doc 01 `GameClock` | int |
| `population`, `pop_peak_7d` | doc 09 | int |
| `treasury`, `daily_opex` | doc 03 | int64 |
| `grid_redundancy`, `water_redundancy`, `road_redundancy` | docs 04 / 05 / 10 | float 0–1 each |
| unit counts per department | doc 06 | int |
| `city_stability` | **doc 09** — population-weighted mean of district stability (C-56) | float 0–1 |
| `active_incidents` | doc 06 | int |
| `customers_out_pct`, `roads_impassable_pct` | docs 04 / 10 | float 0–1 |
| `difficulty` preset name | doc 08 `meta`; knob values via `Difficulty.get("pressure", ·)` on doc 03's `data/difficulty.json` (C-17) | enum |
| recent disaster history | own save section | ring buffer 32 |

**Redundancy score**
```
R = 0.50*grid_redundancy + 0.30*water_redundancy + 0.20*road_redundancy
```

**Fleet strength**
```
needed[fire]         = ceil(pop / 12000)
needed[police]       = ceil(pop /  9000)
needed[utility]      = ceil(pop / 15000)
needed[water]        = ceil(pop / 25000)
needed[construction] = ceil(pop / 20000)
F = mean_d( clamp(owned[d] / max(1, needed[d]), 0, 1.25) ) / 1.25
```

**Preparedness**
```
runway_days = treasury / max(1, daily_opex)
P = 0.35*R + 0.25*F + 0.20*city_stability + 0.20*clamp(runway_days/10, 0, 1)
```

**Stability is read here, never written here** *(report 98 C-56)*. `stability ∈ [0,1]` is owned by doc 09 per district; `city_stability` is doc 09's population-weighted aggregate over districts. This doc **writes no city scalar**. Every stability consequence it produces — the storm-outcome hit, the Storm Ready bonus — goes through `districts.apply_stability(district_id, delta)` on the districts affected, and the city aggregate re-derives from that. There is no `city_stability` field in this doc's save section and no write path to one.

#### 2.6.2 Threat budget

The Director accrues **threat points (TP)** and spends them to schedule events.

```
city_tier(pop): <2000 → 0 | <10000 → 1 | <40000 → 2 | <120000 → 3 | else → 4
tp_base_per_day = [0, 6, 12, 20, 30][city_tier]
age_ramp  = clamp(city_age_days / 10.0, 0.30, 1.00)
pressure  = 0.55 + 0.90 * P                       # range 0.55 … 1.45
tp_rate_per_day = tp_base_per_day * age_ramp * pressure * Difficulty.get("pressure","tp_rate_mult")
                  * (0.50 if suppressed else 1.0) * (0.35 if offline else 1.0)

tp_pool = min(tp_pool + tp_rate_per_day * hours/24, tp_pool_cap)
tp_pool_cap = 180  (40 while suppressed, 60 while offline)
```

`pressure` is the anti-frustration spine: a city with `P = 0.20` accrues threat at `0.73×`, a city with `P = 0.90` at `1.36×`. Challenge follows capability.

**Event catalog (v1).** `min_city_tier` gates by city size (the §2.6.2 `city_tier(pop)` ladder); `min_P` gates by preparedness. **`hazard_tier` is a different axis entirely** — it is the *consequence* class doc 08's offline rule 1 gates on (F8, C-55), and it was added here because "tier" previously meant only city size and the ruling is unstateable without it:

- **Tier 1** — bounded, single-site, self-limiting: every `class == "minor"` event.
- **Tier 2** — multi-site or multi-hour, but not city-shaping.
- **Tier 3** — a city-wide authored crisis with its own beat sheet.

| id | tp_cost | class | **hazard_tier** | forecastable | warn_min | min_city_tier | min_P | base_weight |
|---|---|---|---|---|---|---|---|---|
| `traffic_pileup` | 6 | minor | **1** | no | — | 1 | 0.00 | 1.1 |
| `water_main_break` | 8 | minor | **1** | no | — | 1 | 0.00 | 1.0 |
| `storm_minor` | 8 | minor | **1** | yes | 60 | 1 | 0.00 | 1.4 |
| `transformer_explosion` | 10 | minor | **1** | no | — | 1 | 0.10 | 1.2 |
| `crime_surge` | 12 | minor | **1** | no | — | 2 | 0.15 | 0.9 |
| `major_structure_fire` | 14 | major | **2** | no | — | 2 | 0.20 | 0.8 |
| `heat_wave` | 24 | major | **2** | yes | 360 | 1 | 0.15 | 0.7 |
| `severe_thunderstorm` | 36 | major | **3** | yes | 90 | 1 | 0.20 | 1.0 |

Deferred to post-MVP (costs pre-reserved so the budget curve doesn't need re-tuning): `flash_flood` 30, `river_flood` 40, `blizzard` 46, `wildfire` 50, `tornado` 60, `major_blackout` 64, `riot` 44, `hurricane` 90, `earthquake` 100.

**Severity**
```
severity_mult = clamp(0.60 + 0.80 * P, 0.60, 1.40) * Difficulty.get("pressure","severity_mult")
                * (0.75 if scheduled_offline else 1.0)
```
Optionally the Director may **buy severity**: spend up to `1.60 × tp_cost` to add up to `+0.30` to `severity_mult`, linearly (`+0.50×tp_cost` buys `+0.125`). It does so only when `tp_pool > 1.6 × tp_cost` and no other candidate is affordable.

#### 2.6.3 Scheduling algorithm (hourly)

```
1. refresh inputs; update suppression & recovery-mode state (§2.6.4)
2. accrue TP (rates above)
3. if recovery_mode.active or suppression.active: return
4. candidates = catalog.filter(min_city_tier ok, P >= min_P, cost <= tp_pool,
                               per-type cooldown clear, class cooldown clear,
                               class == "minor" if soft_suppression)
5. if candidates empty: return
6. p_attempt = clamp(tp_pool / 40.0, 0, 1) * 0.25
   if rng.randf() >= p_attempt: return
7. weight(e) = e.base_weight
              * (1.5 if last_seen(e) > 10 game-days else 1.0)         # novelty
              * (1.0 + 0.6 * e.tp_cost / tp_pool)                     # budget-pressure bias
              * season_affinity(e)                                    # heat_wave: 0 in winter
   pick = weighted_pick(candidates, weight)
8. choose target(s) per §2.6.5; if no legal target, drop pick and return
   if ctx.is_catchup: candidates = candidates.filter(F8, §2.6.4)   # Tier 1, pre-warned, FULL band, ≤1
9. impact_min = now + (pick.warn_min * Difficulty.get("pressure","warning_lead_mult")) if forecastable
              = now + uniform_int(10, 120)                                             otherwise
10. tp_pool -= cost;  push to scheduled[];  if forecastable, inject the weather
    segment now so the forecast can show it (subject to §2.5 honesty rules)
11. emit director_event_scheduled
```

**Worked example.** Pop 45 000 (tier 3), Standard, age 40 days, `R = 0.62`, fleet owns fire 4/4, police 4/5, utility 3/3, water 1/2, construction 2/3 → `F = mean(1.0, 0.8, 1.0, 0.5, 0.667)/1.25 = 0.7934/1.25 = 0.635`. `stability = 0.68`, treasury $620 000, opex $85 000/day → `runway = 7.29 d` → `0.729`.
`P = 0.35(0.62) + 0.25(0.635) + 0.20(0.68) + 0.20(0.729) = 0.217 + 0.159 + 0.136 + 0.146 = 0.658`
`pressure = 0.55 + 0.90(0.658) = 1.142` → `tp_rate = 20 × 1.0 × 1.142 × 1.0 = 22.8 TP/day = 0.952 TP/game-hour`
`severity_mult = clamp(0.60 + 0.80×0.658) = 1.126`
With `tp_pool = 41`: `p_attempt = 0.25`. Weights (novelty: severe storm last seen 14 d ago, transformer 3 d ago, crime 4 d ago, pileup 5 d ago):

| candidate | base | novelty | budget bias | weight |
|---|---|---|---|---|
| `severe_thunderstorm` | 1.0 | 1.5 | 1+0.6(36/41)=1.527 | 2.291 |
| `water_main_break` | 1.0 | 1.5 | 1.117 | 1.676 |
| `storm_minor` | 1.4 | 1.0 | 1.117 | 1.564 |
| `major_structure_fire` | 0.8 | 1.5 | 1.205 | 1.446 |
| `heat_wave` | 0.7 | 1.5 | 1.351 | 1.419 |
| `transformer_explosion` | 1.2 | 1.0 | 1.146 | 1.375 |
| `traffic_pileup` | 1.1 | 1.0 | 1.088 | 1.197 |
| `crime_surge` | 0.9 | 1.0 | 1.176 | 1.058 |

Sum `12.026`. `P(severe_thunderstorm | attempt) = 19.05%`; per hour `0.25 × 0.1905 = 4.76%`. Mean weighted cost `16.33 TP`; at `0.952 TP/h` accrual the system is accrual-limited to `0.058 events/hour ≈ 1.4 events/game-day`, of which majors are further throttled by F2 to at most one per two game-days. Target cadence achieved: **one major crisis every ~2–2.5 game-days (≈50–60 real minutes of active play), a handful of minor incidents between them.**

#### 2.6.4 Hard fairness rules

These are **gates**, evaluated before any weighting. Numbers are Standard difficulty; `Difficulty.get("pressure","cooldown_mult")` scales all cooldowns.

**F1 — Grace period.** No Director event until `city_age_days >= 3` AND `population >= 400`. Ambient weather and ambient incidents still run. *Amended (Wave 3, 2026-08-19, doc 92 F-1 ruling): the population half is waived for FLOOR events — `data/director.json`'s `floor` block guarantees a size-independent trickle of minor / hazard-tier-1 / cheap (`tp_cost ≤ 10`) events after the age gate, so a small city still feels weather and pressure. Majors keep the full F1 gate.*

**F2 — Class cooldown.** After a `major` event's *resolution* (all its spawned incidents cleared or expired): no new major for **2880 game-minutes** (2 game-days). After any `minor`: no new event of any class for **360 game-minutes** (6 game-hours).

**F3 — Per-type cooldown.** The same event id cannot recur within **5760 game-minutes** (4 game-days).

**F4 — No repeat-targeting.**
- Any component or district that was a primary target of a Director event gains `target_immunity` until `now + 4320` min (3 game-days). Immune targets get their selection weight multiplied by **0.15**.
- A specific component targeted within the last **1440** min has weight **0.00** — hard exclusion.
- A district cannot be the primary target of two consecutive major events, regardless of timing.
- Within a single storm, a component that has already been struck has weight **0.00** for the rest of that storm.

**F5 — No kick while down.** Director is **fully suppressed** while any of:
- `city_stability < 0.35`
- an unresolved incident spawned by a prior major event still exists
- `customers_out_pct > 0.25`
- `treasury < 0`
- `roads_impassable_pct > 0.40`

Suppression clears only after all conditions are false *plus* `recovery_grace = 720` game-minutes (12 game-hours).
**Soft suppression:** while `0.35 <= city_stability < 0.50`, only `class == "minor"` events (`tp_cost <= 12`) may be scheduled. Crisis difficulty disables soft suppression only; the hard list applies at every difficulty.

**F6 — No revenge spike.** While suppressed, TP accrues at `0.50×` and `tp_pool` is clamped to `40`. A long, painful recovery cannot be converted into a stockpiled punishment.

**F7 — Warning guarantee.** Every forecastable event emits `weather_warning` (notification class CRITICAL / Priority 1, exempt from all rate limiting) at least `warn_min × Difficulty.get("pressure","warning_lead_mult")` before impact: `severe_thunderstorm` 90, `heat_wave` 360, `storm_minor` 60. If the warning cannot be delivered (e.g. the event would be scheduled inside its own warning window), the event is **not scheduled** and the TP is refunded.

**F8 — Offline fairness.** *Tightened to doc 08 §2.3 rule 1 verbatim (report 98 C-55). Doc 08's invariants are the outer clamp; this doc adds nothing that loosens them.* During coarse catch-up the Director may schedule:

- **at most one hazard per catch-up session** — not per 12 real hours, not per band. One, total, however long the absence.
- that hazard must be **`hazard_tier == 1`**. **Tier-2 and Tier-3 events never spawn offline** — no `heat_wave`, no `major_structure_fire`, and never a `severe_thunderstorm`.
- it may only fire while the catch-up is in doc 08's **FULL band** (`catchup_index ≤ 71`). In the DAMPED band the Director is suppressed entirely.
- it may fire **only if a forecast warning for it was already active before the player backgrounded the app** — they saw it and chose to leave. An offline hazard is never new information.
- **on `casual`, zero.** No offline hazard at any tier, ever.

Consequences worth stating, because they are surprising: of the eight catalog events only the five `class == "minor"` rows are Tier 1, and of those only **`storm_minor` is forecastable**, so in practice the sole event that can ever begin during catch-up is a `storm_minor` the player was already warned about. The old "1 major per 12 real hours" allowance is deleted, and with it the old "no *unwarned* major within the final 60 game-minutes" clause — an unwarned offline hazard is now impossible at any point in the window, which strictly subsumes it.

Still applied on top, because they only tighten further: `severity_mult × 0.75`; TP accrual `× 0.35`; `tp_pool_cap = 60`; offline auto-response policies (spec §21.3) apply to every spawned incident; doc 08's `OfflineGuard` clamps every mutation regardless of what this doc emits.

**F9 — Unrecoverable guard.** If `population < 0.60 × pop_peak_7d` OR `treasury < 0` for more than 1440 game-minutes, the Director enters **RECOVERY MODE**: zero events, TP frozen at its current value, for a minimum of **4320** game-minutes and until `city_stability >= 0.55`. Exempt only in an explicit Challenge/Crisis scenario mode (post-MVP).

**F10 — Nothing irreplaceable is destroyed.** Director-driven damage may never destroy, and may never reduce below `condition = 0.10`, any of: the city's last power plant, its last water treatment plant, its last storage reservoir, or the sole station of any department. Damage is clamped and the component remains repairable. Lightning still *strikes* these — the drama is preserved, the loss is not permanent. Since C-54 moved damage resolution out of this doc, F10 travels to the resolver as the `condition_floor = 0.10` field on the `LightningStrike` payload (§2.7.3), and doc 04/02/05 clamp on it; the gate itself is still evaluated here, where the "last of its kind" test can be made.

#### 2.6.5 Target selection

Generic weighted selection over legal targets:
```
w = base_type_weight * condition_factor * exposure_factor * protection_factor
    * immunity_factor * spatial_factor
condition_factor = 1.0 + 1.5 * (1.0 - condition)
immunity_factor  = 0.00 (hit <24 h) | 0.15 (hit <3 d) | 1.00
```
Per-event overrides are in §2.7.3 for lightning. F4 and F10 are applied as filters *before* weighting, never as weights.

#### 2.6.6 Difficulty

**These four rows are authored by this doc but they live in `data/difficulty.json`, owned by doc 03** *(report 98 C-17)*. There is one difficulty file in the project and one read path, `Difficulty.value("pressure", key)`; this doc opens no difficulty file of its own and `data/director.json` carries no `difficulty` block. The rows below are the `pressure` section of that file.

> **SHIPPED 2026-08-20 (doc 91 A91-D-19, report 98 RR-48).** The file exists and these five columns are in it, moved and not edited. `data/director.json`'s `_difficulty_fallback` — the read-only mirror this section's rows lived in while doc 03's file did not exist — is **deleted**, and `DirectorTables.load_from()` now REFUSES a director file that carries one. `CitySim._push_difficulty_to_systems()` calls `set_difficulty()` then `set_pressure_knobs(Difficulty.row("pressure"))` at boot, at founding and after every load, so `DisasterDirector.knob()` reads the live row and never a fallback. With nothing set at all it reads NOMINAL — every scale 1.0, soft suppression on — which is `standard` by construction rather than "whatever preset string the object happens to hold". *(The read path is `Difficulty.value(…)` and not `Difficulty.get(…)`: `get` is `Object.get` and GDScript refuses the redeclaration. Doc 03 §2.9 rule 3 carries the note.)*

| | `tp_rate_mult` | `cooldown_mult` | `severity_mult` | `warning_lead_mult` | `soft_suppression` |
|---|---|---|---|---|---|
| Casual | 0.60 | 2.00 | 0.80 | 1.50 | true |
| **Standard** | **1.00** | **1.00** | **1.00** | **1.00** | **true** |
| Hard | 1.45 | 0.75 | 1.20 | 0.70 | true |
| Crisis | 2.00 | 0.50 | 1.45 | 0.50 | **false** |

Two changes from the pre-C-17 table. **`repair_cost_mult` is deleted** — it duplicated doc 03's `M_repair`, and repair difficulty is `Difficulty.get("economic","M_repair")` (0.70 / 1.00 / 1.35 / 1.60) and nothing else; a reader looking for the old column should look in doc 03 §2.5. **`warning_mult` is renamed `warning_lead_mult`** to match the key doc 03 declared for this section; the values are unchanged.

Doc 03 §3.4 rule 4 requires a declared monotonic direction for every `_mult` knob, so this section ships `_direction = {tp_rate_mult: "up", cooldown_mult: "down", severity_mult: "up", warning_lead_mult: "down"}` — each is monotone casual → crisis as authored.

Per spec §35, difficulty changes *pressure and preparation time*, not raw HP numbers: Casual gives 1.5× the warning window and half the event rate; Crisis halves the warning and doubles the budget. The hard fairness list (F1, F4–F10) is identical at every difficulty — including F8, which is zero-hazard on casual and one-pre-warned-Tier-1-hazard everywhere else.

---

### 2.7 MVP Disaster — SEVERE THUNDERSTORM, beat by beat

`T = 0` is the moment the storm cell centre reaches the city centre. **Reference case** used for every number below: pop 45 000, tier 3, Standard difficulty, `P = 0.50` → `severity_mult = 1.00`, storm `intensity = 0.77`, duration 120 min, 8 total response units.

#### 2.7.1 Scheduling and weather injection

The Director sets intensity explicitly rather than letting the chain roll it:
```
intensity = clamp(0.62 + 0.30 * (severity_mult - 0.60) / 0.80, 0.60, 1.00)
```
Reference case `severity_mult = 1.00` → `0.62 + 0.30 × (0.40/0.80) = **0.77**`. The better-prepared city of §2.6.3 (`severity_mult = 1.126`) would instead get `0.817` — a materially nastier storm, which is the intended reward-shaped-as-challenge.

The timeline is edited: the current segment is truncated to end at `T−30`, a `THUNDERSTORM` segment `[T−30, T+120)` with `source = "director"` is inserted, followed by `HEAVY_RAIN` (45 min), `RAIN` (90 min), then the chain resumes normally.

#### 2.7.2 Warning phase timeline

| time | beat |
|---|---|
| **T−360** | Forecast panel shows a 12–24 h probability band: "Storms possible (58%)". Sky already hazy in-engine. |
| **T−180** | Band firms into the 6–12 h window: "Thunderstorm ≈19:40 ±25m". Distant lightning on the horizon at night. |
| **T−90** | **SEVERE THUNDERSTORM WARNING** — P1 notification (F7, unsuppressable). Storm Prep panel opens: countdown, plus a live readiness readout — grid headroom %, transformer peak temp, idle crews per department, reservoir fill %, count of assets on LOW tiles, count of tree-adjacent line segments. |
| **T−90 → T−20** | **Preparation window** (§2.7.7). |
| **T−30** | Weather state flips to `THUNDERSTORM`. Wind ramps 15 → 45 kph over 20 min. Light rain. `road_speed_mult` starts falling. |
| **T−20** | Storm cell enters the map at the upwind edge. Renderer sweeps the front. Low-tile accumulation begins. |
| **T−10** | First lightning: **cosmetic only**, zero asset strikes. Flashes and thunder land before any damage, so the player always gets a sensory beat before the first failure. |
| **T = 0** | **Peak arrival.** Cell centred, wind 72 kph, precip 30 mm/h. |

#### 2.7.3 Lightning strike generation and target selection

**Ownership split** *(report 98 C-54)*. This doc owns **strike generation and target selection** — it is the only system that can see the storm cell, the building roster and F4 target immunity simultaneously — and it emits:

```
LightningStrike { target_ref, energy, event_uid, condition_floor }
  target_ref      : typed handle (grid component id | building id | water node id) — never a bare tile
  energy          : float, lerp(0.60, 1.60, u), u = uniform(0,1) on the `weather` stream (mean 1.10)
  event_uid       : the Director event this strike belongs to, for report attribution
  condition_floor : 0.10 if the target is F10-protected, else 0.00
```

**Damage resolution belongs to the doc that owns the asset.** This doc's old per-target damage-band table is deleted; it restated numbers it did not own and would have drifted from them. A reader looking for strike outcomes should look here:

| struck asset | resolves in | using |
|---|---|---|
| substation, transformer, feeder span, transmission span, plant | **doc 04** | its `ds` damage-state bands and §2.8 failure-type table (`SUB_FAULT`, `XFMR_LIGHTNING`, `FEEDER_TRIP` / `FEEDER_FAULT` / `FEEDER_DOWN`, `PLANT_FAULT`), its `p_damage = 0.55 × (1 − 0.22 × arrester_level) × clamp(energy, 0.6, 1.6)`, its repair jobs and crew capabilities |
| building (high-rise, industrial, data center, generic) | **docs 02 / 06** | doc 02's `condition` delta and `fire_load`; doc 06's ignition, severity tier and spread |
| water pump / treatment / tank node | **doc 05** | its node failure model and `coverage_frac` fallback |

`energy` is the one number this doc hands the resolver, and doc 04's `energy_scale_min/max = 0.6/1.6` are exactly its clamp bounds, so the two ranges agree by construction. `condition_floor` is how F10 reaches a resolver that cannot see the Director: an irreplaceable asset is still *struck* — the drama survives — but the resolver clamps its condition at 0.10 and converts any "replacement" outcome into a "repairable" one.

*Note on a shared constant:* this doc's `p_asset_hit = 0.55` (does the bolt hit an asset or the ground?) and doc 04's `base_damage_prob = 0.55` (does the hit damage the component?) are unrelated numbers that happen to share a value. They multiply; they do not duplicate.

**Strike generation** (owned here):

```
strike_attempts_per_hour = base_strike_rate * intensity * severity_mult * phase_mult
base_strike_rate = 6.0
phase_mult: lead-in (T−20…T=0) 0.00 (cosmetic) | peak (T=0…T+60) 1.00 | trailing (T+60…end) 0.35
```
Reference case peak hour: `6.0 × 0.77 × 1.00 × 1.0 = 4.62 attempts`. Trailing 50 min: `4.62 × 0.35 × (50/60) = 1.35`. **Total ≈ 6.0 attempts per storm.**

Each attempt: with `p_asset_hit = 0.55` it selects a target from the weighted asset list; otherwise it is a ground strike (renderer + audio only, 6% chance of a small park/pole fire). Expected **≈ 3.3 asset *strikes* per storm** — how many of those become *failures* is the resolver's roll, not this doc's, and is worked below.

**Asset weight**
```
w = base_type_weight * height_factor * condition_factor * exposure_factor
    * protection_factor * immunity_factor * cell_factor

height_factor     = 1.0 + height_m / 40.0
condition_factor  = 1.0 + 1.5 * (1.0 - condition)
exposure_factor   = outdoor 1.00 | rooftop-shielded 0.30 | underground 0.05
protection_factor = product of: arrester 0.35, surge_protection 0.50, station_ground_grid 0.40  (floor 0.20)
immunity_factor   = 0.00 same storm or <24 h | 0.15 <3 game-days | 1.00 otherwise
cell_factor       = 1.0 inside cell radius, 0.0 outside
```

| asset type | `base_type_weight` | typical `height_m` |
|---|---|---|
| transmission line span | 3.0 | 30 |
| substation | 2.5 | 20 |
| distribution transformer | 1.8 | 10 |
| distribution line span | 1.2 | 12 |
| high-rise L4–L5 | 2.2 | 48–70 |
| stadium | 1.5 | 40 |
| factory / industrial | 1.6 | 22 |
| data center | 1.4 | 18 |
| water pump station | 0.8 | 12 |
| generic building L1–L3 | 0.3 | 8–20 |

**Worked comparison — one substation, two cities.**
Prepared: `2.5 × (1+20/40=1.50) × (1+1.5×0.10=1.15) × 1.00 × 0.35(arrester) × 1.00 × 1.00 = **1.510**`
Unprepared: `2.5 × 1.50 × (1+1.5×0.55=1.825) × 1.00 × 1.00 × 1.00 × 1.00 = **6.844**`
The neglected substation is **4.5× more likely** to be the struck asset. The player's maintenance and arrester spending is directly legible in the outcome distribution.

**Strikes → failures: the conversion, recomputed under C-54.** Because damage probability now belongs to the resolver, an asset strike is no longer the same thing as an asset failure, and every downstream count in §2.7.5 and §2.7.8 moves with it. Generating formula, reference storm (intensity 0.77, `severity_mult` 1.00, 120 min):

```
asset_strikes        = attempts × p_asset_hit                       = 5.967 × 0.55 = 3.28
strikes_by_family    = asset_strikes × weight_share(family)
grid_failures        = grid_strikes × 0.55 × (1 − 0.22·arrester_L) × E[energy]     (doc 04)
E[energy]            = 1.10
```

Reference weight mix inside the cell for the reference city: **grid 0.70, buildings 0.25, water 0.05**.

| | per storm | peak hour (77.4% of attempts) |
|---|---|---|
| strike attempts | 5.967 | 4.62 |
| asset strikes (`×0.55`) | **3.28** | 2.54 |
| grid strikes (`×0.70`) | 2.30 | 1.78 |
| → grid **failures**, no arrester (`×0.55×1.10 = 0.605`) | **1.39** | **1.08** |
| → `SurgeAbsorbed`, condition −0.05, no incident | 0.91 | 0.70 |
| → grid failures with arrester L1 (`×0.55×0.78×1.10 = 0.472`) | 1.09 | 0.84 |
| building strikes (`×0.25`) | 0.82 | 0.63 |
| water-node strikes (`×0.05`) | 0.16 | 0.13 |

So the headline moves from "≈3.3 asset hits, ≈3.3 failures" to **≈3.3 asset strikes producing ≈1.4 grid failures, ≈0.8 building strikes and ≈0.2 water strikes** — and an arrester on every substation buys back 22% of the grid failures before any repair bill is written. F10's clamp rides along on every strike as `condition_floor`.

#### 2.7.4 Wind damage — what this doc supplies, and the outcome targets it holds doc 06 to

**This doc rolls no wind damage** *(report 98 C-53)*. The `p_fail_5min` per-span roll that used to live here is deleted, as is doc 04's per-hour `h_wind` curve; **doc 06's `storm_damage` generator (§2.6(f)) is the single line-failure generator in the game.** A reader looking for the wind rate should look there, and for per-component exposure attributes in doc 04.

What this doc supplies, per tick, for the whole storm:

| published | consumed by |
|---|---|
| `wind_kph` (§2.2, intensity-lerped) | doc 06's `wind_factor`, doc 04's wind-cutout for generation |
| `in_storm_cell(pos) -> bool` — the storm-cell mask | doc 06, to restrict candidate assets to the cell |
| `storm_phase` and `t0_min` / `duration_min` | doc 06, for the phase envelope |
| the "crane not recalled" flag per construction site (from the §2.7.7 prep action) | doc 06, as an exposure input on crane sites |

**Outcome targets — normative, and doc 06 calibrates `R_storm_base` against them** (report 98 R-13). These two reference cases are the storm's stated design intent and survive the ownership move intact:

| reference case | inputs | **expected line failures per 120-min storm** |
|---|---|---|
| maintained grid | 60 exposed spans, `wind_kph = 70`, `condition = 0.60`, no tree adjacency, vegetation contract irrelevant | **≈ 2.5** |
| neglected grid | 60 exposed spans, `wind_kph = 85`, `condition = 0.35`, tree-adjacent | **≈ 12** |

The 4.8× spread between them is the whole point: two neglected maintenance decisions multiply the crew workload fivefold. Against doc 06's formula as currently written (`λ = R_storm_base · dt_h · wind_factor · exposure_class · (2 − condition)`) the maintained case computes to `0.020 × 1.0 × 1.0 × 1.40 × 2 h × 60 = 3.36` and the neglected case to `0.020 × 2.25 × 1.4 × 1.65 × 2 h × 60 = 12.47` — the neglected target is already met, the maintained one is ~34% hot, which is exactly the recalibration R-13 assigns to doc 06.

**Other wind effects at peak** are likewise doc 06's to generate; this doc supplies only the trigger conditions. Crane sites that were not recalled, L4–L5 rooftop equipment above `wind_kph ≥ 70`, and commercial signage all map onto doc 06's `storm_damage` exposure classes (`rooftop_mech`, `pole`, `overhead_span`) and its `storm_damage/blocked_road` and `storm_damage/roof_damage` rows.

#### 2.7.5 Incident volume choreography

Target counts for the reference city (pop 45 000, 8 total response units). Ambient baseline is ~2 incidents/hour.

**Recomputed under C-53 and C-54.** The peak row changes because an asset strike is no longer an asset failure (§2.7.3: 1.78 grid strikes in the peak hour convert to **1.08** grid failures at doc 04's `p_damage`, the balance landing as `SurgeAbsorbed` condition dings) and because the wind failures are now doc 06's, running at the §2.7.4 target of ≈2.5 per 120-min storm ⇒ **≈1.3** in the peak hour.

| window | source | expected new incidents |
|---|---|---|
| T−90 → T−20 | ambient ×1.0 | 0–1 |
| T−20 → T=0 | `incident_traffic_mult` ≈2.2, no strikes | ~1 |
| **T=0 → T+60 (peak)** | 4.62 attempts → 2.54 asset strikes → **≈1.1 grid failures + ≈0.6 building strikes (≈0.3 becoming fires) + ≈0.1 water ⇒ ≈1.5**; wind line failures **≈1.3**; traffic ×2.2 → ~3; downed-line hazard ~1; fire 0–1 | **7–10** |
| T+60 → T+110 (trailing) | strikes ×0.35, traffic ×1.6 | 2–3 |
| T+110 → T+300 | heavy rain → rain, floods receding | back to ~2/h |

`1.5 + 1.3 + 3 + 1 + 0.5 = 7.3`, banded 7–10 for the spread of the underlying Poisson draws. Against an ambient baseline of ~2 incidents/hour the peak hour delivers **≈3.5–5× baseline against a fleet of 8** — deliberately more than can be answered simultaneously, forcing triage. That overload *is* the disaster. *(Pre-amendment this row read 8–11 and "4–5×"; the drop is entirely the doc-04 damage probability that this doc used to skip by resolving strikes itself.)* The concurrency cap of 12 still binds before the fleet does, so the choreography guarantee is unaffected.

**Choreography caps** (anti-unwinnable, enforced by the storm module):
```
max_concurrent_storm_incidents = round(3 + 1.1 * total_response_units)     # 8 units → 12
max_new_incidents_per_10min    = max(2, ceil(total_response_units * 0.5))  # 8 units → 4
```
Rolls exceeding a cap are **downgraded, not deleted**: a would-be new incident instead becomes a condition ding on the target component (−0.03) and a log line in the storm report. The player still pays for it, but never faces an infinite queue.

**Emergent cascade beats.** These are *not* authored here — they fall out of the dependency graph (constitution §8: cascades are data-driven edges) and are listed only as the expected story the systems should produce:
```
substation trip → district outage
  → traffic signals dark      → district traffic ×1.5, accident rate ×1.8
  → street lights dark (night)→ district crime ×1.6
  → water pump loses power    → pressure zone falls to reserve-only
     → hydrant pressure 0.40  → fire suppression effectiveness ×0.55
        → a lightning rooftop fire escalates sev 2 → sev 3 and spreads
```

#### 2.7.6 Aftermath and recovery arc

| time | beat |
|---|---|
| T+120 | Cell exits. `HEAVY_RAIN` (45 min) → `RAIN` (90 min). `road_speed_mult` 0.70 → 0.88. Notification: "Storm has cleared." |
| T+120 → T+240 | **Triage window.** Flood tiles draining at 40 mm/h. Crews work the queue. Escalation timers on unhandled incidents are the real threat now. |
| **T+180** | **STORM REPORT** screen generated (see below). |
| T+240 → T+600 | **Repair arc.** Construction crews clear debris and road damage. Struck components keep their reduced `condition` until a maintenance action — cheaper than replacement, and a visible bill the player chose to defer. |
| T+120 → T+~900 | **Stability recovery.** *Not this doc's mechanism (C-56).* Stability is doc 09's per-district aggregate and recovers as its own inputs (power reliability, water, crime, coverage) recover; this doc applies only the storm-outcome delta and the Storm Ready bonus, through `districts.apply_stability(district_id, delta)`. On doc 09's published recovery slope a −0.30 hit heals in roughly 15 game-hours once power and water are back citywide. |

**Storm Report contents** (this is the teaching moment, Core Rule 12):
- Strikes taken / assets hit / wind failures
- Peak customers out; **outage customer-minutes** (the headline resilience metric)
- Incidents: spawned / handled within timer / escalated / downgraded by cap
- Total repair cost, split by department — **summed from doc 03's charges, not priced here** *(report 98 C-16)*. Every damaged asset's resolver hands doc 03 a `damage_fraction ∈ [0,1]` and doc 03 charges `economy.repair_cost(asset, damage_fraction)`; the report totals the charges tagged with this storm's `event_uid`. This doc quotes no repair figure it did not read back from the ledger, and owns no repair price table and no `repair_cost_mult` (C-17 — repair difficulty is `M_repair`).
- **Root-cause list**: the three worst failures, each annotated with *why* — `condition 0.45`, `no lightning arrester`, `no alternate feed`, `elevation LOW (flooded)`, `tree-adjacent span`. Each row links directly to the fix (maintenance order, arrester upgrade, tie switch, vegetation contract).

**Director consequences on resolution:** F2 major cooldown (2 game-days) starts; F4 immunity on every struck component (3 game-days); F5 suppression if stability fell below 0.35; plus a **post-event bleed** — `tp_pool ×= 0.5` for the 12 game-hours after a major event resolves, so a well-handled storm does not immediately fund the next one.

**Preparedness reward.** If the player took ≥3 prep actions AND `outage_customer_minutes < 250 × population/1000`, award **Storm Ready**: `+0.05` stability applied through `districts.apply_stability()` on every district the storm touched (C-56 — no city scalar is written), and state aid reimbursing **15%** of the ledger repair total. This makes preparation profitable, not merely less painful.

#### 2.7.7 Preparation actions (the warning window)

Available T−90 → T−20 only. All optional; a city that does nothing is still playable, just worse.

| action | cost | effect |
|---|---|---|
| **Pre-stage crews** | $3 000/crew | Crews relocate to depots near the highest-weight assets. Travel time to storm incidents −35% for 6 game-hours. |
| **Voluntary load shed** | −5% commercial tax for the storm's duration | `power_load_mult × 0.92` — often the difference between 98% and 106% grid utilisation |
| **Top off water storage** | $ per m³ (doc 05) | Reservoirs to 100%, protecting hydrant pressure through a pump outage |
| **Emergency crew callout** | $18 000 | +1 temporary utility crew for 12 game-hours |
| **Recall construction crews** | free; forfeits ~90 min of project progress | Clears the site's crane-exposure flag, removing it from doc 06's `storm_damage` candidate set (§2.7.4) |
| **Sandbag a land block** *(stub)* | $6 000/block | `drain_rate_mm_h × 1.6` on that block for 24 game-hours |

Prep actions are also the Director's fairness receipt: the count is recorded in the storm report and feeds the Storm Ready check.

#### 2.7.8 Prepared vs unprepared — same storm, same seed

Both cities: pop 45 000, `severity_mult = 1.00`, `intensity = 0.77`, 6.0 strike attempts, 60 exposed line spans. (In practice City A's higher `P` would earn it a *harder* storm; held equal here to isolate the effect of preparation.)

**Repair bills are computed, not quoted** *(report 98 C-16)*. The old totals ($42 000 / $310 000) were this doc's own invention against doc 04's pre-C-07 price ladder and are deleted. Doc 03 is the sole repair-pricing authority, and this doc consumes it:

```
repair_cost = round( capital_value(asset) × damage_fraction × REPAIR_COST_PER_CAPITAL (0.85) × M_repair )
M_repair = 1.00 at standard difficulty
```

`capital_value` comes from doc 03 §2.13(b) (grid components, post-C-07 rescale) and §2.3's `capital_value()` curve (buildings). `damage_fraction` comes from the resolving doc — doc 04's `cost_frac_of_build` table re-read per failure type, doc 06's `0.10(tier_peak − 1) + 0.30·burn_timer` for fires. The inventory the two scenarios are priced against, stated so the arithmetic is reproducible:

| asset | source | capital_value |
|---|---|---|
| overhead distribution span = 20 route tiles, feeder class 2 | doc 03 §2.13(b): $210/tile | **$4,200** |
| distribution transformer L3 | doc 03 §2.13(b) | **$2,800** |
| substation L3 (30 MW) | doc 03 §2.13(b) | **$65,000** |
| apartment L3 (fire target) | doc 03 §2.3 `capital_value()` | **$43,029** |

| failure type (doc 04 §2.8) | repair job | `damage_fraction` (doc 04 §8, re-read per C-16) |
|---|---|---|
| `FEEDER_TRIP` | reclose | 0.005 |
| `FEEDER_FAULT` | splice | 0.05 |
| `FEEDER_DOWN` | rebuild | 0.20 |
| `SUB_FAULT` | substation repair | 0.30 |
| `XFMR_LIGHTNING` / `XFMR_BURNOUT` | swap | 0.35 |

**CITY A — prepared.** Two substations with a tie switch (`grid_redundancy 0.80`), all conditions ≥0.85, arresters on both substations, no assets on LOW tiles, 3 utility crews + 1 called out, vegetation contract active, storage topped, load shed on.

- Substation strike weight 1.51 each; weight mass sits on lines and high-rises instead.
- **Outcome:** 1 line flashover (45-second blink); 1 distribution transformer failure (400 customers, 28 min); 1 wind fault on a redundant feeder → tie switch closes automatically → **0 customers out** from it.
- Peak customers out: **400 (0.9%)**. Outage customer-minutes: **≈ 11 200** — just inside the Storm Ready threshold of `250 × 45 000/1000 = 11 250`.
- Incidents: 7 spawned, 7 handled inside escalation timers, 0 fires, 0 downgrades.
- **Repair bill, computed:**

| item | `damage_fraction` | capital | `× df × 0.85 × 1.00` | cost |
|---|---|---|---|---|
| 1 × `FEEDER_TRIP` (flashover) | 0.005 | 4,200 | 4,200 × 0.005 × 0.85 = 17.85 | **$18** |
| 1 × `XFMR_LIGHTNING` swap | 0.35 | 2,800 | 2,800 × 0.35 × 0.85 = 833.00 | **$833** |
| 1 × `FEEDER_FAULT` splice (wind) | 0.05 | 4,200 | 4,200 × 0.05 × 0.85 = 178.50 | **$179** |
| | | | **total** | **$1,030** |

  Storm Ready reimburses `round(0.15 × 1,030)` = **$155**, plus `+0.05` stability on the touched districts.
- Stability: −0.02, recovered in 4 game-hours.
- **Player experience:** genuinely spectacular — sky lit up, sirens, the blink, the tie switch closing on the overlay — and the city held. The reward for three hours of prior infrastructure work is *watching it work*.

**CITY B — unprepared.** One substation (`grid_redundancy 0.15`), mean condition 0.45, no arresters, substation sited on a LOW tile in the floodplain, 1 utility crew, deferred maintenance, tree-adjacent spans, no prep actions.

- Substation strike weight 6.84 — it absorbs ~32% of all asset-strike probability.
- **T+12:** substation struck; doc 04 resolves the strike (`p_damage = 0.55 × 1.00 × energy 1.29 = 0.71` → damaged) to `SUB_FAULT` — breaker damage, offline. **All 45 000 customers out.**
- **T+18:** substation tile at 160 mm → crew access delayed +20 min, and a forced-trip roll keeps re-tripping the site.
- **T+12:** the only water pump loses power; storage was at 45% and drains in 70 min. **T+82:** hydrant pressure 0.40 in two zones.
- **T+35:** lightning rooftop fire in a low-pressure zone → suppression ×0.55 → escalates sev 2 → sev 3, spreads to one adjacent building.
- Wind: 12 line failures — doc 06's `storm_damage` generator at the §2.7.4 neglected-grid target — queue behind everything. Doc 04 resolves this seed as 9 × `FEEDER_FAULT` + 3 × `FEEDER_DOWN`.
- One crew must serialise: substation 55 min → 3 transformers ×30 min → 2 line faults. **Last customer restored T+310.**
- **T+140:** night falls on a dark city. Crime ×1.6 (dark) ×1.4 (outage) → 4 crime incidents; police already committed → 2 escalate.
- Outage customer-minutes: **≈ 4 700 000** (420× City A) — `4 700 000 / 45 000 = 104.4` minutes of outage per customer, i.e. **1.74 game-hours of city-wide load lost**. 5 incidents downgraded by the concurrency cap.
- **Repair bill, computed:**

| item | `damage_fraction` | capital | `× df × 0.85 × 1.00` | cost |
|---|---|---|---|---|
| 1 × `SUB_FAULT`, substation L3 | 0.30 | 65,000 | 65,000 × 0.30 × 0.85 = 16,575.00 | **$16,575** |
| 9 × `FEEDER_FAULT` splice | 0.05 | 4,200 ea | 9 × 178.50 | **$1,607** |
| 3 × `FEEDER_DOWN` rebuild | 0.20 | 4,200 ea | 3 × 714.00 | **$2,142** |
| 3 × `XFMR_BURNOUT` swap, L3 | 0.35 | 2,800 ea | 3 × 833.00 | **$2,499** |
| 2 × structure fire, apartment L3 — doc 06 `df = 0.10(3−1) + 0.30×0.30 = 0.29` | 0.29 | 43,029 ea | 2 × 10,606.65 | **$21,213** |
| | | | **total** | **$44,036** |

  **42.8× City A's bill** from the same storm and the same seed. Against a $180 000 treasury that is **24.5%** — painful and survivable, which is the correct shape; the deeper cost is the revenue hole, 1.74 game-hours of city-wide load booked by doc 03 against its `REV_FLOOR_FRACTION`, not by this doc. *(The pre-amendment figures — $42 000 and $310 000, a 7.4× spread — were priced off doc 04's deleted 8×-inflated ladder and this doc's own deleted damage bands. The composition also shifted: **48.2% of the new bill is the two structure fires doc 06 resolves** (21,213 / 44,036) against **37.6% for the substation** (16,575 / 44,036) and 14.2% for all fifteen line and transformer failures combined — a truer picture than the old grid-only total, because lightning breaks equipment but fire destroys value.)*
- Stability 0.62 → **0.31** (applied per district via `districts.apply_stability()`) → **F5 fires. The Director goes completely silent** until the doc-09 city aggregate is ≥0.35 plus 12 game-hours.
- Storm report headline: *"Substation Alpha — condition 0.45, no arrester, elevation LOW, sole feed for 100% of customers."* One line, four fixes, all purchasable.

The design contract: the unprepared city gets **hurt badly, taught precisely, and then left alone to recover.** That combination is what separates "hard but fair" from "random and cruel."

---

## 3. Data schema

### 3.1 `data/weather.json` and `data/director.json`

Full, literal contents are in §8 (Tunables) — that block *is* the schema, with every key populated at its shipping default. Types: all probabilities and multipliers `float`, all durations `int` game-minutes, all costs `int` dollars, all `*_mult` keys unitless multipliers, effect entries are `[min, max]` pairs lerped by `intensity`. Both files carry `schema_version: 1`; a loader mismatch is a hard error, not a silent default.

**A third file this doc writes into but does not own:** `data/difficulty.json` (doc 03, report 98 C-17). Its `pressure` section holds this doc's four difficulty knobs and is read only through `Difficulty.get("pressure", key)`. Neither `data/weather.json` nor `data/director.json` carries a `difficulty` block, and this doc defines no difficulty scalar of its own.

### 3.2 Save sections
```
"weather": {
  "section_version": 1,
  "rng": { "seed": int, "state": int },
  "forecast_refresh_index": int,
  "timeline": [ { "id": int, "state": str, "start_min": int, "end_min": int,
                  "intensity": float, "source": str, "event_id": int|null } ],
  "storm_cell": { "active": bool, "x_t": float, "z_t": float, "radius_t": float,
                  "heading_deg": float, "speed_tpm": float } | null,
  "flood": { "tiles": { "<tx>,<tz>": int_mm }, "closed_edges": [int] }
},
"director": {
  "section_version": 1,
  "rng": { "seed": int, "state": int },
  "difficulty": str,
  "tp_pool": float,
  "last_event_end_min": { "<event_id>": int },
  "last_major_end_min": int,
  "last_major_district": int,
  "history": [ { "type": str, "start_min": int, "end_min": int,
                 "severity_mult": float, "targets": [int], "outcome": str } ],  // ring 32
  "target_immunity": { "<component_id>": int },
  "suppression": { "active": bool, "reasons": [str], "since_min": int, "clear_at_min": int },
  "recovery_mode": { "active": bool, "until_min": int },
  "scheduled": [ { "event_uid": int, "type": str, "impact_min": int, "warned": bool,
                   "severity_mult": float, "params": {} } ],
  "pop_peak_7d": int,
  "offline_hazard_used": bool,        // F8: one per catch-up session, reset at catchup_begin (C-55)
  "active_storm": { "phase": str, "t0_min": int, "duration_min": int,
                    "struck_ids": [int], "prep_actions": [str],
                    "new_incidents_window": [ [int, int] ],
                    "metrics": { "strikes": int, "asset_hits": int, "wind_fails": int,
                                 "outage_customer_minutes": int, "repair_cost": int,
                                 "downgraded": int } } | null
}
```

---

## 4. Sim API sketch

All classes are `RefCounted`, no Node/scene access (constitution §3).

```
sim/weather/weather_system.gd   WeatherSystem
  tick(dt_min) [utilities cadence] · advance_coarse(hours, ctx) [offline, same rules]
  get_state() · get_intensity() · get_effect(channel) · get_ambient_temp_c()
       # get_effect() is authoritative for all five weather multiplier families (C-57)
       # and accepts doc 02's short aliases: load_mult / water_mult / decay_mult / fire_mult / build_mult
       # 17 channels; the three fire channels are distinct and multiply (§2.2.1, RR-15):
       #   fire_ignition_mult (how often) · fire_escalation_mult (how fast this one grows)
       #   fire_spread_mult (how readily it jumps). fire_escalation_mult is flat per state.
  state_at(gmin) -> {state, intensity}      # free: the timeline is committed
  get_transformer_heat_mult() · wx_slowdown() = 1 - get_effect("road_speed_mult")
  get_wind_kph() · get_precip_mm_h() · get_precip01()      # precip01: C-58, crossfaded across segments
  get_forecast(horizon_min) -> Array[ForecastEntry]
  get_storm_cell() · in_storm_cell(pos) -> bool · flood_depth_mm(tx,tz) · flood_saturation(tx,tz)
  get_edge_speed_mult(edge_id)
  inject_segment(state, start_min, duration_min, intensity, event_id) -> int
  serialize() / deserialize(dict)
  helpers: WeatherTimeline · Forecast · StormCell · FloodField

sim/director/disaster_director.gd   DisasterDirector
  tick_hour(inputs: DirectorInputs, ctx) · on_incident_resolved(incident_id, event_uid)
  on_event_resolved(event_uid) · get_debug_state() · serialize() / deserialize(dict)
  forecast_queue() -> Array[{event_id, kind, severity, onset_gmin, warning_lead_gmin,
                             confidence}]        # committed + persisted; for UI & offline alarms
  helpers: ThreatBudget (accrual/caps) · FairnessGate (F1–F10, pure predicates)
           EventCatalog · TargetSelector

sim/disasters/severe_thunderstorm.gd   SevereThunderstorm
  begin(severity_mult, intensity, duration_min) · tick(dt_min) · build_report()
  emit_strike() -> LightningStrike{target_ref, energy, event_uid, condition_floor}   # C-54
```

**What this doc reads from other systems rather than defining** *(report 98)*: `ctx.season_index` / `ctx.season_progress` (doc 01, C-28) · `Difficulty.get("pressure", key)` (doc 03, C-17) · `economy.repair_cost(asset, damage_fraction)` (doc 03, C-16) · `districts.apply_stability(district_id, delta)` and `city_stability` (doc 09, C-56). It calls no repair price table, no calendar derivation, no difficulty file and no city stability scalar of its own.

**Commands handled:** `set_difficulty`, `storm_prep_action(action_id, target)`, `debug_force_weather(state, intensity, duration)`, `debug_force_director_event(id)`, `debug_set_tp(v)`.

**Events emitted:** `weather_changed`, `weather_forecast_updated`, `weather_warning` (the P1/CRITICAL severe warning; name adopted from doc 12), `storm_phase_changed`, `lightning_strike`, `lightning_flash_cosmetic`, `wind_damage`, `flood_level_changed`, `road_closed_flood`, `road_reopened`, `director_event_scheduled`, `director_event_started`, `director_event_ended`, `director_suppressed`, `director_recovery_mode`, `storm_report_ready`, `storm_ready_bonus`.

`lightning_strike` carries the `LightningStrike` payload above and is the *only* strike event; `wind_damage` is now emitted **by doc 06**, not here (C-53), and remains in this list only as an event this doc *subscribes* to for its storm report metrics.

---

## 5. Cross-system interfaces

**Doc numbering is Ruling Zero's: the on-disk filenames in `docs/design/` are canonical and there is no other map** *(report 98 §0)*. Every row below is checked against that table. All thirteen docs have landed; the "pending" qualifiers on docs 04 and 09 are removed, and doc 09's title is now *Map, Land, Districts, Population & Stability*.

| doc | this doc **reads** | this doc **provides** |
|---|---|---|
| **01** Time model & tick scheduler | injected `GameClock` (int64 game-minutes), cadence registration, `weather` + `director` RNG streams, `ctx.is_catchup` / `catchup_index` / `catchup_total`, **`ctx.season_index` + `ctx.season_progress`** (C-28 — this doc derives no calendar) | registration on the utilities cadence + an hourly Director cadence; `advance_coarse(hours, ctx)`. Doc 01's `thunderstorm_hazard` template keeps its phase structure and timing; its `modifiers` blocks are empty (C-27 — every storm effect multiplier is §2.2's) |
| **02** Buildings, upgrades & construction | per-building `height_m`, `level`, `condition`, `has_surge_protection`, footprint tiles, crane-equipped construction sites, `fire_load` | `get_effect()` for all five families under doc 02's aliases `load_mult` / `water_mult` / `decay_mult` / `fire_mult` / `build_mult` — **authoritative; doc 02 authors no weather constant** (C-57). Building strikes are resolved by doc 02/06, not here (C-54) |
| **03** Economy, taxes, land market & difficulty | `population`, `treasury`, `daily_opex`, 7-day population series (`pop_peak_7d`); **`economy.repair_cost(asset, damage_fraction)`** (C-16); **`Difficulty.get("pressure", key)`** (C-17) | `power_load_mult`; prep-action cost triggers; a `damage_fraction ∈ [0,1]` for any hazard this doc resolves itself; the Storm Ready reimbursement rate (15%). **This doc quotes no repair total and owns no `repair_cost_mult`** |
| **04** Electrical grid | component list with `position`, `condition`, `weather_exposure`, `has_arrester`, `has_ground_grid`, `tree_adjacent`, `underground`, `elevation_class`; `grid_redundancy` ∈ [0,1]; `customers_out_pct`; **its `ds` damage-state bands and §2.8 failure types** (C-54) | `power_load_mult`, `transformer_heat_rate_mult`, `ambient_temp_c`, `line_failure_rate_mult` (**background/thermal hazard only — wind is doc 06's**, C-53), `solar_output_mult`, `wind_kph`, and `LightningStrike{target_ref, energy, event_uid, condition_floor}`. The `storm_owns_line_failures` flag is **deleted** — nothing remains to suppress |
| **05** Water system | pump + reservoir positions, `elevation_class`, storage level, `water_redundancy`, its node failure model for struck water nodes | `water_demand_mult`, `LightningStrike` on water nodes, flood depth at node tiles, the top-off prep action |
| **06** Incidents, dispatch & emergency fleets | `active_incidents`, owned units per department, unit availability, escalation timers, **its `storm_damage` generator's output** (C-53) | `incident_crime_mult` / `incident_traffic_mult` / `incident_utility_mult` / `fire_ignition_mult` (RR-4), **`fire_escalation_mult` for its §2.4 `esc_env[structure_fire]` and `fire_spread_mult` for its §2.8 `rate(target)`** (RR-15, §2.2.1 — adopted values, no re-tune), `wind_kph`, `in_storm_cell(pos)`, storm phase/duration, crane-exposure flags, the choreography caps of §2.7.5, crew pre-staging, and the §2.7.4 outcome targets (≈2.5 / ≈12 failures) it calibrates `R_storm_base` against |
| **08** Persistence, offline & notification policy | `offline_real_hours` handed in once at resume, auto-response policy set, `ctx.is_catchup`, `band_for(hour_index)`, **§2.3 rule 1 — the outer clamp on F8** (C-55) | own save sections; `forecast_queue()` for scheduling honest offline hazard alarms; WHILE-YOU-WERE-AWAY storm entries |
| **09** Map, land, districts, population & stability | per-block/per-tile `elevation_class ∈ {LOW, MID, HIGH}`, city bounding radius, district membership, per-district `stability ∈ [0,1]` and the population-weighted **`city_stability` aggregate** (C-56) | flood accumulation per tile, `outage_health_risk_mult`, and stability deltas **written only through `districts.apply_stability(district_id, delta)` — never to a city scalar** |
| **10** Roads, routing & traffic | road graph edges, per-edge `condition`, `road_redundancy`, `roads_impassable_pct`, the per-edge `accident_hazard(e)` rate | **`wx_slowdown() = 1 − road_speed_mult`** (doc 10 §2.11 consumes exactly this), per-edge flood speed multiplier, `flood_saturation(tile)` for its ground term, edge removal at ≥350 mm, debris road closures. Weather is **global**; roads samples one city-wide state (C-59) |
| **11** Rendering & performance | — | weather state + intensity, `wind_kph`, `precip_mm_h` **and `precip01 ∈ [0,1]`, continuous across segment boundaries** (C-58), storm cell position/radius/heading, cosmetic and real lightning flash events, per-tile flood depth, `ambient_temp_c` for heat shimmer. One global state to render — no second region, no boundary popping (C-59) |
| **12** UI/UX, camera input & onboarding | — | `get_forecast()` entries tagged with their UI band, `Director.forecast_queue()` (committed and persisted, exactly the shape doc 12 asks for), `weather_warning` with `notify_class = CRITICAL`, warning countdown + readiness readout, storm prep panel, Storm Report payload |
| **13** Android integration & export | — | notification payloads for `weather_warning` and `storm_report_ready` (deep link `weather:<event_uid>`) |

**Interfaces this doc requires from others** — all four now have a named owner:
- `elevation_class ∈ {LOW, MID, HIGH}` per tile (or at minimum per land block) — **doc 09**. Without it, localized flooding cannot exist and §2.7 loses one of its four damage channels.
- `weather_exposure`, `has_arrester`, `has_ground_grid`, `tree_adjacent`, `underground` on grid components — **doc 04**. Without these, lightning has no player-facing counterplay and §2.7.3 degrades to a dice roll.
- `grid_redundancy`, `water_redundancy`, `road_redundancy` as `[0,1]` scalars, each defined by its own doc (04 / 05 / 10). The Director only combines them (§2.6.1).
- `districts.apply_stability(id, delta)` and the `city_stability` aggregate — **doc 09** (C-56).

*(The fourth entry used to be the `storm_owns_line_failures` suppression flag. C-53 deleted it: doc 06 is the only line-failure generator, so there is nothing to suppress.)*

---

## 6. MVP cut

**In (vertical slice):** 6 weather states with intensity; the full 17-channel effect table — including the three distinct fire channels `fire_ignition_mult` / `fire_escalation_mult` / `fire_spread_mult` (§2.2.1, RR-15) and `precip01` with its segment crossfade; derived temperature and transformer heat; the doc-01 calendar consumed through `ctx.season_index` / `ctx.season_progress`; committed timeline + forecast with lead-based accuracy, confusion table, hourly refresh stability, and both honesty rules; storm cell with position/radius/advection plus the `in_storm_cell()` mask; flood stub on LOW tiles with 5 depth bands; Disaster Director with TP budget, preparedness score, hourly scheduling, all of F1–F10 (F8 at doc 08's clamp), 4 difficulty presets read from `data/difficulty.json`, and 8 catalog events carrying `hazard_tier`; severe thunderstorm fully implemented per §2.7 including lightning **generation and target selection** and the `LightningStrike` payload, choreography caps, Storm Report, and 6 prep actions; offline parity.

**Out, because another doc owns it** (not deferred — *moved*): wind damage rolls and all storm incident generation (doc 06 §2.6(f)); lightning damage resolution (doc 04 for grid, 02/06 for buildings, 05 for water); repair pricing (doc 03 §2.5); difficulty knob storage (doc 03 `data/difficulty.json`); the calendar (doc 01); stability state (doc 09).

**Deferred:** snow / blizzard / fog / extreme cold / high-wind states; seasons beyond the 4-row multiplier table; multi-cell and per-district weather; weather-station building and forecast upgrades; sandbags beyond the drain-rate stub; storm drains as buildable infrastructure; the 9 pre-costed post-MVP disasters; evacuation; insurance economy beyond the flat 15% reimbursement; hail; lightning-caused wildfire; Challenge/Crisis scenario mode exemptions to F9.

---

## 7. Test plan (headless)

| # | test | assertion |
|---|---|---|
| 1 | Transition table integrity | For all 6 states × 4 seasons, weighted+renormalised rows sum to 1.0 ± 1e-6; no self-transition has non-zero weight |
| 2 | Determinism | Same seed, 10 000 game-hours → identical segment list (state, start, end, intensity) across two runs |
| 3 | Coarse/fine parity | Fine ticking 48 game-hours vs `advance_coarse(48)` from the same save → identical timeline and identical Director `scheduled[]` |
| 4 | Duration bounds | 10 000 sampled durations ∈ `[dur_min, dur_max]` and ≡ 0 mod 15 |
| 5 | Effect bounds | For all 6 states × intensity ∈ {0, 0.5, 1}, all **17** channels resolve and every value ∈ `[min, max]`; `transformer_heat_rate_mult` ∈ [0.70, 2.40]; `get_effect()` returns identical values for each doc-02 alias and its canonical channel name (C-57); an unknown channel name raises rather than returning 1.0 |
| 5d | `fire_escalation_mult` adoption golden (RR-15) | Per-state values are exactly `{CLEAR 1.00, CLOUDY 1.00, RAIN 0.80, HEAVY_RAIN 0.80, THUNDERSTORM 0.80, HEAT_WAVE 1.25}` at intensity ∈ {0, 0.25, 0.5, 0.77, 1} — **intensity-invariant to 1e-9**, since the band endpoints are equal. Cross-check against doc 06: replaying its §2.4 example (wood house L2, wind 45 kph, CLEAR, hydrant ratio 1.0) through `esc_env = wind_term × get_effect("fire_escalation_mult") × hydrant_penalty` yields `1.250 ± 1e-6` and tier 5 at `66.3 ± 0.1` game-minutes — the pre-RR-15 values. Anti-aliasing guard: the two fire channels are separate table entries, and for RAIN / HEAVY_RAIN / THUNDERSTORM / HEAT_WAVE at every intensity `fire_escalation_mult != fire_spread_mult` (0.80 vs 0.70→0.55, 0.50→0.35, 0.60→0.45; 1.25 vs 1.35→1.70), so neither can be silently substituted for the other |
| 5e | `fire_spread_mult` is published and read (RR-15) | All 6 MVP states publish a `fire_spread_mult` band in `data/weather.json`; at THUNDERSTORM intensity 0.77 the value is `0.4845 ± 1e-4`; at CLEAR it spans `[1.00, 1.10]`. Mirrored in doc 06's spread suite, which asserts the channel is actually multiplied into `rate(target)` — this doc asserts only that the value is correct and position-independent |
| 5b | `precip01` continuity (C-58) | `precip01 == clamp(precip_mm_h/35,0,1)` at every sample; across a THUNDERSTORM→HEAVY_RAIN boundary the published series has no step > 0.02 per SimTick over the final 60 game-seconds; at 30 gs before the reference boundary the value is `0.6072 ± 1e-3`; no other channel is interpolated |
| 5c | Calendar consumption (C-28) | `season_index` is never computed inside `sim/weather/`; feeding `ctx` day 159 selects SUMMER and `season_progress` at 09:20 == `0.3130 ± 1e-4`; a 120-game-day sweep visits each season for exactly 30 days |
| 6 | Forecast at lead 0 | 1 000 samples: displayed state == true state, 100% |
| 7 | Forecast accuracy calibration | 5 000 samples at lead 360 min: measured correct rate ∈ 0.865 ± 0.03 |
| 8 | Forecast stability | Two `get_forecast()` calls inside one refresh window → byte-identical output; across a refresh → may differ but converges (mean |lead error| non-increasing over 12 refreshes) |
| 9 | No invented severe | 20 000 samples at lead ≤ 180: zero cases of displayed THUNDERSTORM/HEAT_WAVE when true state is neither |
| 10 | Warning guarantee (F7) | 200 Director-scheduled severe thunderstorms → `weather_warning` emitted ≥ 90 min before `storm_phase_changed(lead_in)` in 200/200 |
| 11 | Flood accumulation | LOW tile, 25 mm/h for 60 min → `depth == 110 mm ± 1`; `road_speed_mult == 0.45` |
| 12 | Flood recede | precip 0 for 3 h → depth 0; previously-removed edge restored exactly once |
| 13 | Wind interface, not wind rolls (C-53) | `sim/weather/` and `sim/disasters/` contain no failure roll: assert zero calls into any damage API from the storm module's wind path. Instead assert the *inputs* — at intensity 0.77 the published `wind_kph == 72.4 ± 0.1` for every tick of the storm, and `in_storm_cell()` is true for exactly the components within `radius_tiles` of the cell centre. The 2.5 / 12 outcome targets are asserted in doc 06's suite, against its `R_storm_base` |
| 14 | Lightning weight golden | Fixed 5-asset city → computed **target-selection** weights match hand table (substation prepared 1.510, unprepared 6.844) to 1e-3. Selection only — no damage band is evaluated in this doc (C-54) |
| 14b | Strike payload & no damage bands (C-54) | 1 000 strikes: every emitted `LightningStrike` carries `target_ref`, `energy ∈ [0.60, 1.60]`, `event_uid`, and `condition_floor == 0.10` iff the target is F10-protected; `sim/weather/` + `sim/director/` + `sim/disasters/` contain no `ds` band table |
| 14c | Strike→failure conversion (C-54) | 10 000 reference storms at the §2.7.3 weight mix → mean asset strikes `3.28 ± 2%`, mean grid failures `1.39 ± 3%` with no arrester and `1.09 ± 3%` at arrester L1 |
| 15 | No double strike | 100 simulated storms → no component id appears twice in one storm's `struck_ids` |
| 16 | Immunity weighting (F4) | Components hit <3 game-days ago selected at ≤ 0.20× their un-immune share over 5 000 storms |
| 17 | Irreplaceable guard (F10) | City with 1 power plant, 1 000 forced strike resolutions → condition never < 0.10, never destroyed |
| 18 | Class cooldown (F2) | 500 simulated game-days → no two `major` events start within 2880 min of the prior's resolution |
| 19 | Per-type cooldown (F3) | Same run → no event id recurs within 5760 min |
| 20 | Kick-while-down (F5) | Force stability 0.30 for 30 game-days → 0 events scheduled; restore to 0.60 → first event only after `recovery_grace` 720 min |
| 21 | Soft suppression | stability 0.42 for 10 game-days → every scheduled event has `tp_cost ≤ 12` |
| 22 | No revenge spike (F6) | During suppression, `tp_pool ≤ 40` at every hourly sample |
| 23 | Recovery mode (F9) | Force pop to 55% of 7-day peak → 0 events for ≥ 4320 min and until stability ≥ 0.55 |
| 24 | Offline cap (F8, tightened by C-55) | 10 000 seeded catch-ups of 1–12 real hours: Director hazards **≤ 1 per catch-up session**, always `hazard_tier == 1`, always pre-warned before backgrounding, never in the DAMPED band; on `casual`, always **0**. Mirrors doc 08's `test_no_unwarned_offline_hazard` and must agree with it row for row |
| 25 | Incident caps | Force 40 strike hits in 10 min → new incidents ≤ `max_new_incidents_per_10min`; remainder logged as `downgraded` |
| 26 | Difficulty scaling | 100 game-days Casual vs Crisis → major-event count ratio ∈ [2.6, 4.0]; every knob read goes through `Difficulty.get("pressure", ·)` and `data/director.json` contains no `difficulty` key and no `repair_cost_mult` (C-17) |
| 27 | Preparedness monotonicity | P swept 0.1 → 0.9 in 0.1 steps → `tp_rate` strictly increasing, `severity_mult` strictly increasing, both within clamps |
| 28 | Save round-trip | serialize → deserialize → next 24 game-hours identical to the uninterrupted run |
| 29 | Prep action effect | Same seed storm with and without load shed → peak `power_load` differs by exactly 8%; Storm Ready awarded only when both conditions hold |
| 30 | Report completeness | 50 storms → every report has ≥1 root-cause row per damaged component, each with a non-empty reason code |
| 31 | Repair pricing is consumed, not owned (C-16) | Replay the §2.7.8 City A and City B seeds → the report's repair total equals the sum of `economy.repair_cost()` charges tagged with the `event_uid`, and equals **$1,030** (City A) and **$44,036** (City B) at standard difficulty; `sim/weather/` + `sim/director/` + `sim/disasters/` contain no price constant |
| 32 | Stability writes go through districts (C-56) | 200 storms → every stability mutation is a `districts.apply_stability(id, d)` call; zero writes to any city-level scalar; the Storm Ready `+0.05` lands on each touched district exactly once |
| 33 | Global-with-cell invariant (C-59) | For 5 000 sampled positions in an active thunderstorm, `get_effect(ch)` is position-independent for all **17** channels — the count grew by one under RR-15's `fire_escalation_mult`, and a fire inside the cell escalates at the same weather multiplier as one outside it; only `in_storm_cell()` and `flood_depth_mm()` vary spatially |

---

## 8. Tunables

Every balance constant introduced by this doc, complete and drop-in ready. §8.1 is the literal contents of `data/weather.json`; §8.2 is the literal contents of `data/director.json`; §8.3 is this doc's authored `pressure` rows **inside doc 03's `data/difficulty.json`**. No number in §1–§7 exists outside these three blocks.

**Constants that used to live here and no longer do** (report 98) — a reader looking for them should look in the owning doc:

| deleted key | ruling | now lives in |
|---|---|---|
| `seasons.length_days` (21) and the 84-day year | C-28 | doc 01 `data/time.json` (`days_per_season 30`, `seasons_per_year 4`) |
| `storm.wind.*` — `k_wind`, `threshold_kph`, `condition_base`, `span_factor_tree_adjacent`, `roll_period_min`, `fault_vs_down_split`, `crane_incident_p`, `rooftop_equip_p`, `rooftop_equip_wind_kph`, `signage_debris_p`, `vegetation_management_days` | C-53 | doc 06 §2.6(f) `storm_damage` (`R_storm_base`, `wind_factor`, `exposure_class`); doc 04 for per-component exposure |
| `storm_owns_line_failures` | C-53 | nothing — deleted outright, there is no second generator to suppress |
| `storm.lightning.damage_bands.*` (line / substation / transformer / building / water_pump) | C-54 | doc 04 §2.8 + §2.7.3 (grid), docs 02/06 (buildings), doc 05 (water nodes) |
| `difficulty.*` including `repair_cost_mult` | C-17 | doc 03 `data/difficulty.json` — `pressure` section (§8.3) and `economic.M_repair` |
| `storm.recovery.stability_regen_per_hour` | C-56 | doc 09 — stability dynamics are its aggregate, not this doc's |
| `fairness.offline.max_majors_per_real_hours`, `no_unwarned_major_final_min` | C-55 | doc 08 §2.3 rule 1, mirrored read-only in §8.2 |

**Constants that arrived here from another doc** — the one row that moves *inward*:

| adopted key | ruling | came from | value change |
|---|---|---|---|
| `states.*.effects.fire_escalation_mult` | **RR-15** | doc 06 §2.4 `esc_env[structure_fire]` — `heat_mult` (1.25 in heat wave) and `rain_mult` (0.80 in rain/heavy rain/thunderstorm) — inline constants in doc 06's escalation formula, never keys in `data/incidents.json`, which is why they went unnoticed until the closing audit | **none.** The six published bands are the product `heat_mult × rain_mult` evaluated per state (§2.2.1). Ownership moved; calibration is byte-identical. |

### 8.1 `data/weather.json`
```json
{
  "schema_version": 1,
  "horizon_min": 1440,
  "quantize_min": 15,
  "diurnal_amp_c": 6.0,
  "diurnal_peak_min_of_day": 900,
  "precip01_scale_mm_h": 35.0,
  "segment_crossfade_gs": 60,
  "seasons": {
    "_calendar_note": "days_per_season and seasons_per_year live in data/time.json (doc 01, report 98 C-28). This doc indexes ctx.season_index and derives nothing.",
    "order": ["SPRING", "SUMMER", "AUTUMN", "WINTER"],
    "table": {"SPRING": {"temp_base_c": 16.0, "transition_mult": {"CLEAR": 1.0, "CLOUDY": 1.0, "RAIN": 1.2, "HEAVY_RAIN": 1.0, "THUNDERSTORM": 1.0, "HEAT_WAVE": 0.2}}, "SUMMER": {"temp_base_c": 26.0, "transition_mult": {"CLEAR": 1.0, "CLOUDY": 1.0, "RAIN": 0.9, "HEAVY_RAIN": 1.1, "THUNDERSTORM": 1.4, "HEAT_WAVE": 1.6}}, "AUTUMN": {"temp_base_c": 14.0, "transition_mult": {"CLEAR": 1.0, "CLOUDY": 1.0, "RAIN": 1.3, "HEAVY_RAIN": 1.2, "THUNDERSTORM": 0.8, "HEAT_WAVE": 0.3}}, "WINTER": {"temp_base_c": 4.0, "transition_mult": {"CLEAR": 1.0, "CLOUDY": 1.3, "RAIN": 1.1, "HEAVY_RAIN": 1.0, "THUNDERSTORM": 0.3, "HEAT_WAVE": 0.0}}}
  },
  "transitions": {
    "CLEAR": {"CLOUDY": 0.72, "RAIN": 0.14, "HEAVY_RAIN": 0.03, "THUNDERSTORM": 0.04, "HEAT_WAVE": 0.07},
    "CLOUDY": {"CLEAR": 0.45, "RAIN": 0.35, "HEAVY_RAIN": 0.08, "THUNDERSTORM": 0.1, "HEAT_WAVE": 0.02},
    "RAIN": {"CLEAR": 0.15, "CLOUDY": 0.45, "HEAVY_RAIN": 0.28, "THUNDERSTORM": 0.12},
    "HEAVY_RAIN": {"CLOUDY": 0.4, "RAIN": 0.35, "THUNDERSTORM": 0.25},
    "THUNDERSTORM": {"CLEAR": 0.05, "CLOUDY": 0.3, "RAIN": 0.35, "HEAVY_RAIN": 0.3},
    "HEAT_WAVE": {"CLEAR": 0.55, "CLOUDY": 0.25, "THUNDERSTORM": 0.2}
  },
  "transformer_heat": {"ref_temp_c": 20.0, "per_degree": 0.04, "clamp": [0.7, 2.4]},
  "states": {
    "CLEAR": {"dur_min": 180, "dur_max": 720, "intensity_gamma": 1.0, "effects": {"power_load_mult": [1.0, 1.03], "water_demand_mult": [1.0, 1.05], "road_speed_mult": [1.0, 1.0], "fire_spread_mult": [1.0, 1.1], "fire_escalation_mult": [1.0, 1.0], "fire_ignition_mult": [1.0, 1.0], "incident_crime_mult": [1.0, 1.0], "incident_traffic_mult": [1.0, 1.0], "incident_utility_mult": [1.0, 1.0], "line_failure_rate_mult": [1.0, 1.0], "outage_health_risk_mult": [1.0, 1.0], "solar_output_mult": [1.0, 1.0], "construction_speed_mult": [1.0, 1.0], "condition_decay_mult": [1.0, 1.0], "wind_kph": [5, 15], "precip_mm_h": [0, 0], "temp_offset_c": [1, 3]}},
    "CLOUDY": {"dur_min": 120, "dur_max": 480, "intensity_gamma": 1.0, "effects": {"power_load_mult": [0.98, 0.98], "water_demand_mult": [0.98, 0.98], "road_speed_mult": [1.0, 1.0], "fire_spread_mult": [0.95, 0.95], "fire_escalation_mult": [1.0, 1.0], "fire_ignition_mult": [0.95, 0.95], "incident_crime_mult": [1.0, 1.0], "incident_traffic_mult": [1.02, 1.02], "incident_utility_mult": [1.0, 1.0], "line_failure_rate_mult": [1.0, 1.0], "outage_health_risk_mult": [1.0, 1.0], "solar_output_mult": [0.55, 0.55], "construction_speed_mult": [1.0, 1.0], "condition_decay_mult": [1.0, 1.0], "wind_kph": [8, 20], "precip_mm_h": [0, 0], "temp_offset_c": [-1, -2]}},
    "RAIN": {"dur_min": 60, "dur_max": 240, "intensity_gamma": 1.0, "effects": {"power_load_mult": [1.02, 1.05], "water_demand_mult": [0.94, 0.9], "road_speed_mult": [0.9, 0.84], "fire_spread_mult": [0.7, 0.55], "fire_escalation_mult": [0.8, 0.8], "fire_ignition_mult": [0.88, 0.8], "incident_crime_mult": [0.88, 0.82], "incident_traffic_mult": [1.25, 1.45], "incident_utility_mult": [1.05, 1.1], "line_failure_rate_mult": [1.1, 1.25], "outage_health_risk_mult": [1.0, 1.0], "solar_output_mult": [0.32, 0.24], "construction_speed_mult": [0.92, 0.86], "condition_decay_mult": [1.1, 1.2], "wind_kph": [10, 25], "precip_mm_h": [2, 6], "temp_offset_c": [-2, -4]}},
    "HEAVY_RAIN": {"dur_min": 30, "dur_max": 120, "intensity_gamma": 1.2, "effects": {"power_load_mult": [1.05, 1.1], "water_demand_mult": [0.9, 0.85], "road_speed_mult": [0.78, 0.62], "fire_spread_mult": [0.5, 0.35], "fire_escalation_mult": [0.8, 0.8], "fire_ignition_mult": [0.78, 0.7], "incident_crime_mult": [0.78, 0.7], "incident_traffic_mult": [1.6, 2.0], "incident_utility_mult": [1.25, 1.6], "line_failure_rate_mult": [1.4, 1.9], "outage_health_risk_mult": [1.05, 1.1], "solar_output_mult": [0.18, 0.12], "construction_speed_mult": [0.72, 0.55], "condition_decay_mult": [1.25, 1.4], "wind_kph": [15, 40], "precip_mm_h": [8, 20], "temp_offset_c": [-3, -6]}},
    "THUNDERSTORM": {"dur_min": 45, "dur_max": 150, "intensity_gamma": 1.6, "effects": {"power_load_mult": [1.06, 1.14], "water_demand_mult": [0.9, 0.85], "road_speed_mult": [0.72, 0.55], "fire_spread_mult": [0.6, 0.45], "fire_escalation_mult": [0.8, 0.8], "fire_ignition_mult": [1.8, 3.0], "incident_crime_mult": [0.82, 0.75], "incident_traffic_mult": [1.8, 2.3], "incident_utility_mult": [2.0, 3.5], "line_failure_rate_mult": [2.5, 6.0], "outage_health_risk_mult": [1.05, 1.1], "solar_output_mult": [0.14, 0.08], "construction_speed_mult": [0.45, 0.25], "condition_decay_mult": [1.4, 1.8], "wind_kph": [30, 85], "precip_mm_h": [12, 35], "temp_offset_c": [-3, -7]}},
    "HEAT_WAVE": {"dur_min": 1440, "dur_max": 4320, "intensity_gamma": 0.8, "effects": {"power_load_mult": [1.25, 1.55], "water_demand_mult": [1.3, 1.6], "road_speed_mult": [0.99, 0.97], "fire_spread_mult": [1.35, 1.7], "fire_escalation_mult": [1.25, 1.25], "fire_ignition_mult": [1.3, 1.6], "incident_crime_mult": [1.15, 1.35], "incident_traffic_mult": [1.0, 1.05], "incident_utility_mult": [1.4, 1.9], "line_failure_rate_mult": [1.05, 1.1], "outage_health_risk_mult": [2.0, 3.5], "solar_output_mult": [1.05, 1.05], "construction_speed_mult": [0.88, 0.78], "condition_decay_mult": [1.2, 1.4], "wind_kph": [3, 12], "precip_mm_h": [0, 0], "temp_offset_c": [7, 14]}}
  },
  "storm_cell": {"radius_min_tiles": 48, "radius_frac_of_city": 0.6, "speed_tiles_per_min": [1.6, 3.2]},
  "flood": {
    "drain_rate_mm_h": 40.0,
    "runoff_concentration": {"LOW": 6.0, "MID": 1.0, "HIGH": 0.4},
    "max_depth_mm": 900,
    "thresholds": [{"depth_mm": 0, "road_speed_mult": 1.0, "label": "dry"}, {"depth_mm": 40, "road_speed_mult": 0.75, "label": "nuisance"}, {"depth_mm": 100, "road_speed_mult": 0.45, "label": "standing_water", "stall_incident_p_10min": 0.04}, {"depth_mm": 200, "road_speed_mult": 0.15, "label": "flooded", "civilian_closed": true, "asset_trip_p_10min": 0.3}, {"depth_mm": 350, "road_speed_mult": 0.0, "label": "impassable", "remove_edge": true, "asset_forced_offline": true, "asset_condition_delta": -0.15}]
  },
  "forecast": {
    "base_accuracy": 0.97,
    "accuracy_decay": 0.42,
    "clamp": [0.5, 0.99],
    "refresh_min": 60,
    "station_bonus": 0.0,
    "intensity_noise_base": 0.06,
    "intensity_noise_lead": 0.1,
    "time_jitter_base_min": 10,
    "time_jitter_lead_min": 40,
    "no_invent_severe_below_lead_min": 180,
    "confusion": {"CLEAR": {"CLOUDY": 1.0}, "CLOUDY": {"CLEAR": 0.5, "RAIN": 0.5}, "RAIN": {"CLOUDY": 0.45, "HEAVY_RAIN": 0.35, "THUNDERSTORM": 0.2}, "HEAVY_RAIN": {"RAIN": 0.55, "THUNDERSTORM": 0.45}, "THUNDERSTORM": {"HEAVY_RAIN": 0.6, "RAIN": 0.4}, "HEAT_WAVE": {"CLEAR": 0.7, "CLOUDY": 0.3}},
    "ui_bands": [{"max_lead_min": 360, "mode": "exact"}, {"max_lead_min": 720, "mode": "window"}, {"max_lead_min": 1440, "mode": "probability"}]
  }
}
```

### 8.2 `data/director.json`
```json
{
  "schema_version": 1,
  "tp": {
    "tier_pop_thresholds": [2000, 10000, 40000, 120000],
    "base_per_day_by_tier": [0, 6, 12, 20, 30],
    "age_ramp_days": 10,
    "age_ramp_floor": 0.3,
    "pressure_base": 0.55,
    "pressure_slope": 0.9,
    "pool_cap": 180.0,
    "pool_cap_suppressed": 40.0,
    "pool_cap_offline": 60.0,
    "offline_rate_mult": 0.35,
    "suppressed_rate_mult": 0.5,
    "post_event_bleed_mult": 0.5,
    "post_event_bleed_min": 720
  },
  "preparedness": {
    "w_redundancy": 0.35,
    "w_fleet": 0.25,
    "w_stability": 0.2,
    "w_runway": 0.2,
    "runway_cap_days": 10.0,
    "redundancy_weights": {"grid": 0.5, "water": 0.3, "road": 0.2},
    "fleet_pop_per_unit": {"fire": 12000, "police": 9000, "utility": 15000, "water": 25000, "construction": 20000},
    "fleet_clamp": 1.25
  },
  "severity": {"base": 0.6, "slope": 0.8, "clamp": [0.6, 1.4], "offline_mult": 0.75, "buy_max_cost_mult": 1.6, "buy_max_severity": 0.3},
  "scheduling": {"eval_period_min": 60, "attempt_pool_target": 40.0, "attempt_base_p": 0.25, "novelty_days": 10, "novelty_mult": 1.5, "budget_bias_slope": 0.6, "sudden_delay_min": [10, 120]},
  "fairness": {
    "grace_days": 3,
    "grace_population": 400,
    "major_cooldown_min": 2880,
    "minor_cooldown_min": 360,
    "per_type_cooldown_min": 5760,
    "target_immunity_min": 4320,
    "target_hard_exclude_min": 1440,
    "immunity_weight_mult": 0.15,
    "suppress": {"stability": 0.35, "customers_out_pct": 0.25, "roads_impassable_pct": 0.4, "recovery_grace_min": 720},
    "soft_suppress_stability": 0.5,
    "soft_suppress_max_cost": 12,
    "recovery_mode": {"pop_frac_of_peak": 0.6, "debt_duration_min": 1440, "min_duration_min": 4320, "exit_stability": 0.55},
    "offline": {
      "_source": "08-offline-persistence.md §2.3 rule 1 — mirrored read-only, owned there (report 98 C-55)",
      "max_hazards_per_catchup": 1,
      "max_hazard_tier": 1,
      "requires_prewarning": true,
      "allowed_bands": ["FULL"],
      "hazards_on_casual": 0
    },
    "irreplaceable_condition_floor": 0.1
  },
  "_difficulty_note": "MOVED — the four pressure knobs live in data/difficulty.json (doc 03, report 98 C-17), read via Difficulty.get(\"pressure\", key). repair_cost_mult is DELETED; repair difficulty is economic.M_repair.",
  "events": [
    {"id": "traffic_pileup", "tp_cost": 6, "class": "minor", "hazard_tier": 1, "forecastable": false, "warn_min": 0, "min_city_tier": 1, "min_preparedness": 0.0, "base_weight": 1.1},
    {"id": "water_main_break", "tp_cost": 8, "class": "minor", "hazard_tier": 1, "forecastable": false, "warn_min": 0, "min_city_tier": 1, "min_preparedness": 0.0, "base_weight": 1.0},
    {"id": "storm_minor", "tp_cost": 8, "class": "minor", "hazard_tier": 1, "forecastable": true, "warn_min": 60, "min_city_tier": 1, "min_preparedness": 0.0, "base_weight": 1.4},
    {"id": "transformer_explosion", "tp_cost": 10, "class": "minor", "hazard_tier": 1, "forecastable": false, "warn_min": 0, "min_city_tier": 1, "min_preparedness": 0.1, "base_weight": 1.2},
    {"id": "crime_surge", "tp_cost": 12, "class": "minor", "hazard_tier": 1, "forecastable": false, "warn_min": 0, "min_city_tier": 2, "min_preparedness": 0.15, "base_weight": 0.9},
    {"id": "major_structure_fire", "tp_cost": 14, "class": "major", "hazard_tier": 2, "forecastable": false, "warn_min": 0, "min_city_tier": 2, "min_preparedness": 0.2, "base_weight": 0.8},
    {"id": "heat_wave", "tp_cost": 24, "class": "major", "hazard_tier": 2, "forecastable": true, "warn_min": 360, "min_city_tier": 1, "min_preparedness": 0.15, "base_weight": 0.7, "season_affinity": {"SPRING": 0.3, "SUMMER": 1.6, "AUTUMN": 0.3, "WINTER": 0.0}},
    {"id": "severe_thunderstorm", "tp_cost": 36, "class": "major", "hazard_tier": 3, "forecastable": true, "warn_min": 90, "min_city_tier": 1, "min_preparedness": 0.2, "base_weight": 1.0, "season_affinity": {"SPRING": 1.0, "SUMMER": 1.4, "AUTUMN": 0.8, "WINTER": 0.3}}
  ],
  "storm": {
    "phases": {"lead_in_min": 30, "cell_entry_min": -20, "cosmetic_flash_min": -10, "peak_min": 60, "trailing_frac": 0.35},
    "duration_min": [90, 180],
    "intensity_from_severity": {"base": 0.62, "slope": 0.3, "clamp": [0.6, 1.0]},
    "lightning": {"base_strike_rate_per_hour": 6.0, "p_asset_hit": 0.55, "ground_fire_p": 0.06, "energy_range": [0.6, 1.6], "base_type_weight": {"transmission_line": 3.0, "substation": 2.5, "distribution_transformer": 1.8, "distribution_line": 1.2, "high_rise_l4_l5": 2.2, "stadium": 1.5, "factory": 1.6, "data_center": 1.4, "water_pump": 0.8, "building_generic": 0.3}, "height_divisor_m": 40.0, "condition_slope": 1.5, "exposure_factor": {"outdoor": 1.0, "rooftop_shielded": 0.3, "underground": 0.05}, "protection_factor": {"arrester": 0.35, "surge_protection": 0.5, "ground_grid": 0.4, "floor": 0.2}, "_damage_bands_note": "DELETED (report 98 C-54) — this doc generates strikes and selects targets only. Damage resolution: doc 04 §2.8/§2.7.3 for grid components, docs 02/06 for buildings, doc 05 for water nodes. energy_range matches doc 04's energy_scale_min/max by construction."},
    "wind": {"_note": "DELETED (report 98 C-53) — doc 06 §2.6(f) is the only line-failure generator. This doc publishes wind_kph (§2.2) and in_storm_cell(); doc 04 publishes per-component exposure. Outcome targets doc 06 calibrates R_storm_base against, for a 120-min storm over 60 exposed spans:", "outcome_target_maintained": {"wind_kph": 70, "condition": 0.6, "tree_adjacent": false, "expected_failures": 2.5}, "outcome_target_neglected": {"wind_kph": 85, "condition": 0.35, "tree_adjacent": true, "expected_failures": 12.0}},
    "choreography": {"concurrent_base": 3.0, "concurrent_per_unit": 1.1, "new_per_10min_min": 2, "new_per_10min_per_unit": 0.5, "downgrade_condition_delta": -0.03},
    "prep_actions": {"pre_stage_crews": {"cost_per_crew": 3000, "travel_time_mult": 0.65, "duration_min": 360}, "load_shed": {"commercial_tax_mult": 0.95, "power_load_mult": 0.92}, "top_off_water": {"fill_to": 1.0}, "callout_crew": {"cost": 18000, "duration_min": 720, "crews": 1}, "recall_construction": {"cost": 0, "progress_loss_min": 90}, "sandbag_block": {"cost": 6000, "drain_rate_mult": 1.6, "duration_min": 1440}},
    "reward": {"min_prep_actions": 3, "outage_cm_per_1k_pop": 250, "stability_bonus": 0.05, "reimburse_frac": 0.15},
    "recovery": {"report_at_min": 180, "_stability_regen_note": "MOVED — stability dynamics belong to doc 09 (report 98 C-56). This doc applies deltas via districts.apply_stability() and regenerates nothing."}
  }
}
```

### 8.3 `data/difficulty.json` → `pressure` section (authored here, owned by doc 03)

Dropped into doc 03's file per report 98 C-17 §3.4. Four knobs, four presets, one declared direction each; validated by doc 03's loader and its test 32 monotonicity check.

```json
"pressure": {
  "_owner": "07-weather-disaster-director.md",
  "_direction": { "tp_rate_mult": "up", "cooldown_mult": "down", "severity_mult": "up", "warning_lead_mult": "down" },
  "casual":   { "tp_rate_mult": 0.60, "cooldown_mult": 2.00, "severity_mult": 0.80, "warning_lead_mult": 1.50, "soft_suppression": true },
  "standard": { "tp_rate_mult": 1.00, "cooldown_mult": 1.00, "severity_mult": 1.00, "warning_lead_mult": 1.00, "soft_suppression": true },
  "hard":     { "tp_rate_mult": 1.45, "cooldown_mult": 0.75, "severity_mult": 1.20, "warning_lead_mult": 0.70, "soft_suppression": true },
  "crisis":   { "tp_rate_mult": 2.00, "cooldown_mult": 0.50, "severity_mult": 1.45, "warning_lead_mult": 0.50, "soft_suppression": false }
}
```

`repair_cost_mult` is **absent by ruling**, not by oversight. `soft_suppression` is a fifth key beyond the four doc 03 listed in its `_keys` placeholder: it is a scalar bool, it is a pressure knob by every reading of C-17, and leaving it in `data/director.json` would have been a difficulty scalar outside the single difficulty file — which C-17 rule 2 forbids. Doc 03's `_keys` list should grow by one; nothing else about its schema changes.

---

## 9. Conflicts & open questions

### Conflicts with the constitution
**None material.** Two items to confirm:

1. **Seasons — ruled and resolved (report 98 C-28).** Seasons are approved as a concept, and the calendar is doc 01's: **30-day seasons, a 120-game-day year**. This doc no longer introduces, defines or derives a calendar; it reads `ctx.season_index` / `ctx.season_progress` and indexes its four-row table (§2.1). The old 84-day year is deleted. The season-less degradation path still exists (set every `transition_mult` to 1.0 and pin `temp_base_c = 20`) but is no longer needed.
2. **`data/weather.json` and `data/director.json`** are new files under constitution §2's "ALL tunable numbers live in `data/`" rule. No conflict, just registering ownership.

### Deliberate design calls the overseer should ratify
3. **Committed weather timeline instead of per-tick rolling.** This is the load-bearing architectural decision. It is what makes an honest forecast, a guaranteed 90-minute warning, and offline/online parity all possible with one mechanism. Cost: the timeline (up to ~12 segments) is persisted, and `inject_segment` rewrites the future, which any consumer caching weather must tolerate.
4. **Storm cell advection speed is decoupled from `wind_kph`.** Physically wrong (a 72 kph storm would cross a 2 km city in minutes). Set directly to 1.6–3.2 tiles/game-minute so cell traverse time matches storm duration. Gameplay over realism, stated openly.
5. **Preparedness *increases* threat budget** (`pressure = 0.55 + 0.90·P`). Well-run cities get up to 1.45× the challenge; struggling ones get 0.55×. This is rubber-banding and some players will detect it. I believe it is correct for a game about resilience — the reward for building well is a worthier test, not idleness — but it is a taste call worth an explicit yes.

### Open questions
6. **Are `min_warning_min` values right for a mobile session?** 90 game-minutes of thunderstorm warning = **90 real seconds** at the locked 60× scale. That is enough time to tap 3–4 prep buttons but not enough to *build* anything. Options: (a) accept it as a pure triage window, (b) raise to 180 game-min, (c) auto-slow time to 1× during a warning countdown. I recommend (a) plus an optional "pause on warning" accessibility setting, but this needs a UI-doc decision.
7. **~~Who owns `city_stability`?~~ CLOSED by C-56.** `stability ∈ [0,1]` is owned by **doc 09** per district; `city_stability` is doc 09's population-weighted mean over districts, computed and published there. This doc reads it and writes nothing to it: every delta goes through `districts.apply_stability(district_id, delta)` (§2.6.1, §2.7.6). The guessed aggregation was right; it is now someone's job.
8. **Does `elevation_class` exist per tile or only per land block?** *(Still open.)* The flood stub is written per road *tile*; doc 09 carries `elevation_band` per block. If it stays block-granular a whole 128 m block floods at once — coarser than I'd like, still shippable. Needs an answer before implementation.
9. **~~Repair cost sourcing.~~ CLOSED by C-16.** **Doc 03 owns repair pricing, end to end.** This doc's quoted totals are deleted and §2.7.8 is recomputed from `economy.repair_cost(asset, damage_fraction) = capital_value × damage_fraction × 0.85 × M_repair` against doc 03's post-C-07 ladder: **City A $1,030, City B $44,036**. No fallback table was needed and none exists here.
10. **~~Offline major-event cap unit.~~ CLOSED by C-55.** F8 no longer counts per *real* hour of anything — doc 08's rule 1 is per **catch-up session**, which the sim already knows from `ctx.catchup_index` / `catchup_begin`. The constitution §4 wall-clock question evaporates: this doc needs no `offline_real_hours` input at all, only `ctx`.
11. **~~Doc numbering.~~ CLOSED by Ruling Zero (report 98 §0).** The on-disk filenames in `docs/design/` are canonical and there is no other map. §5 is written against that table; the numbering variants in docs 08 and 12 are stale, and their own worklists carry the fix. No code may reference a doc number until each doc's renumber lands.
12. **~~Doc 02's placeholder weather constants.~~ CLOSED by C-57.** **This doc's `get_effect()` is authoritative for all five families.** Doc 02's five inline `weather_*_mult` constants are deleted rather than overridden, so no placeholder survives for someone to implement by accident; §2.2 publishes an alias table so doc 02's short channel names (`load_mult`, `water_mult`, `decay_mult`, `fire_mult`, `build_mult`) resolve unchanged. The one genuine disagreement is ruled in this doc's favour: **thunderstorm `construction_speed_mult` 0.45 → 0.25** stands against doc 02's flat 0.55.
13. **Weather scope — recorded, closed by C-59.** Weather state is city-wide global; the `THUNDERSTORM` cell is the only spatial object and affects only lightning targeting and flood accumulation. Doc 10's X-4 and doc 11's §9.12 are closed on that basis (§2.3).
14. **~~Doc 06's residual weather-keyed fire constants.~~ CLOSED by RR-15.** The `heat_mult` / `rain_mult` pair inside doc 06 §2.4's `esc_env[structure_fire]` is now **this doc's `fire_escalation_mult` channel**, adopted at its shipped values (§2.2.1); doc 06 deletes the constants and consumes the channel, and its previously-unread `fire_spread_mult` gains its first consumer in §2.8. The audit's worry — that folding escalation into `fire_spread_mult` would cut escalation 25–44% and break test 23 — is answered by *not* folding them: three questions, three channels. **One residual, deliberately left open:** the four deferred weather states (`SNOW`, `BLIZZARD`, `FOG`, `EXTREME_COLD`) have no adopted escalation or spread value. They enter at a neutral 1.00 when they are implemented, and that 1.00 is a placeholder to be balanced, not a ruling — a blizzard plainly should not escalate fires like a clear day. Flagged here so the next author does not inherit it silently.
15. **Doc length.** This doc runs long against the 350–700 target. The overrun is concentrated in §8 (tunables, required to be complete and drop-in) and §2.7 (the full beat-by-beat storm, which was the explicit assignment); the report-98 Round 1 amendments net out roughly flat, since the deleted damage bands and wind rolls paid for the added ownership tables and recomputations. Round 3's RR-15 adds §2.2.1 net-new — one channel's worth of table against a page of provenance — which I judged worth it: an adopted number with no visible derivation is exactly the kind of orphan this campaign existed to kill. I judged completeness the higher duty; say the word and I will move §8 into `data/` files.

---

## Amendments applied (report 98)

Each row is a binding ruling from `98-consistency-report.md` and what changed here. Deleted material is *removed*, never commented out; every deletion carries a pointer to the owning doc.

### Round 1 (report 98 §12)

| ruling | change applied in this doc |
|---|---|
| **Ruling Zero** | §5 rewritten against the canonical on-disk filenames — doc 04 and doc 09 no longer "pending", doc 09 retitled *Map, Land, Districts, Population & Stability*, doc 06 named as incidents/dispatch/fleets, doc 08 as persistence/offline/notification policy; header records the numbering; §9 item 11 closed. |
| **C-16** | The quoted repair totals ($42K / $310K) are deleted. §2.7.8 now consumes `economy.repair_cost(asset, damage_fraction)` and recomputes both scenarios line by line against doc 03's ladder: **City A $1,030**, **City B $44,036** (42.8×). Storm Report totals are summed from the ledger by `event_uid`; §9 item 9 closed. |
| **C-17** | `repair_cost_mult` deleted from §2.6.6 and `data/director.json` — repair difficulty is doc 03's `M_repair`. The four pressure knobs move to the `pressure` section of `data/difficulty.json` (new §8.3), read only through `Difficulty.get("pressure", key)`; `warning_mult` renamed `warning_lead_mult` to doc 03's declared key; `_direction` authored for the monotonicity test. |
| **C-28** | `season_length_days = 21`, the 84-game-day year and the `floor((sim_day % 84)/21)` derivation are deleted. §2.1 consumes `ctx.season_index` / `ctx.season_progress` on doc 01's 30-day / 120-day calendar, with a recomputed worked example (day 159 → SUMMER, `season_progress 0.3130`). The four-row season table is unchanged; `season_index` is dropped from the save section; §9 item 1 closed. |
| **C-53** | §2.7.4's `p_fail_5min` wind rolls and both their worked examples are deleted, as is the `storm_owns_line_failures` flag (§2.2, §5, §8.2 `storm.wind`). §2.7.4 is now the interface this doc supplies — `wind_kph`, `in_storm_cell()`, storm phase, crane-exposure flags — plus the two normative outcome targets (≈2.5 and ≈12 failures per 120-min storm) that doc 06 calibrates `R_storm_base` against. `line_failure_rate_mult` narrowed to doc 04's non-wind background hazard so wind is never double-counted. |
| **C-54** | This doc keeps strike generation and target selection and now emits `LightningStrike{target_ref, energy, event_uid, condition_floor}`; the whole per-target damage-band table is deleted in favour of doc 04's `ds` bands and §2.8 failure types (grid), docs 02/06 (buildings), doc 05 (water nodes). F10 travels as `condition_floor` on the payload. Strike→failure conversion recomputed: **3.28 asset strikes → 1.39 grid failures** (1.09 with arresters). |
| **C-55** | F8 tightened to doc 08 §2.3 rule 1 verbatim: **at most one hazard per catch-up session, `hazard_tier == 1` only, pre-warned before backgrounding, FULL band only, zero on casual.** The old "1 major per 12 real hours" and the "no unwarned major in the final 60 minutes" clause are deleted (subsumed). A `hazard_tier` column was added to the event catalog and `min_tier` renamed `min_city_tier` so the two axes stop colliding; save field `offline_major_window` → `offline_hazard_used`; test 24 rewritten; §9 item 10 closed. |
| **C-56** | Stability deltas are written only through `districts.apply_stability(district_id, delta)` — the storm-outcome hit and the Storm Ready `+0.05`. `city_stability` is read as doc 09's population-weighted aggregate; no city scalar is written, no stability field is saved, and `stability_regen_per_hour` is deleted (doc 09 owns the dynamics). §9 item 7 closed. |
| **C-57** | §2.2 declared authoritative for all five weather multiplier families, with an alias table mapping doc 02's `load_mult` / `water_mult` / `decay_mult` / `fire_mult` / `build_mult` onto the canonical channels. Thunderstorm `construction_speed_mult` **0.45 → 0.25** stands. §9 item 12 closed. |
| **C-58** | `precip01 = clamp(precip_mm_h / 35.0, 0, 1)` published for doc 11, continuous across segment boundaries by lerping the last 60 game-seconds of a segment into the next; all other channels remain step functions for coarse/fine parity. Worked example (0.8486 at intensity 0.77; 0.6072 mid-crossfade), tunables `precip01_scale_mm_h` / `segment_crossfade_gs`, API `get_precip01()`, test 5b. |
| **C-59** | §2.3 opens with the explicit ruling: weather state is city-wide global, the `THUNDERSTORM` cell is the only spatial object, and it affects lightning targeting and flood accumulation only. Doc 10 X-4 and doc 11 §9.12 recorded as closed; test 33 asserts channel values are position-independent. |
| *(housekeeping)* | `section_version: 1` added to both save sections per doc 08's mandate — this doc was not listed under C-25 because it had no colliding key, and this closes the gap in the same direction. |

*(Round 2, report 98 §14: no ruling was addressed to this doc. RR-4 named this doc's `get_effect()` as the sole owner of weather multipliers but assigned the edit to doc 06, which deleted its `weather_mults` table; nothing here changed.)*

### Round 3 (report 98 §15)

| ruling | change applied in this doc |
|---|---|
| **RR-15** *(part 1 — publish)* | **New published channel `fire_escalation_mult`** in the §2.2 effect table and in `data/weather.json` §8.1, for all six MVP states: `CLEAR 1.00→1.00`, `CLOUDY 1.00→1.00`, `RAIN 0.80→0.80`, `HEAVY_RAIN 0.80→0.80`, `THUNDERSTORM 0.80→0.80`, `HEAT_WAVE 1.25→1.25`. The values are **adopted verbatim** from doc 06 §2.4's `esc_env[structure_fire]` (`heat_mult = 1.25 if heat_wave`, `rain_mult = 0.80 if rain\|heavy_rain\|thunderstorm`, both `1.0` otherwise) — the per-state product `heat_mult × rain_mult`, which is unambiguous because weather state is one global enum (C-59). **Ownership moved under RR-15; calibration is preserved exactly**, so doc 06's §1.1 response band and its test 23 invariant (39.1 gm response < tier 3 at 39.3 gm) require no re-derivation. New §2.2.1 carries the derivation, the per-state adoption table, the worked check reproducing doc 06's `esc_env = 1.250` and its 66.3-gm tier-5 arrival unchanged, and the arithmetic ruling out the alternative of reusing `fire_spread_mult` (`0.60/0.80 = 0.750` … `0.45/0.80 = 0.5625` → a 25.0–43.8% escalation cut, i.e. a re-tune, which RR-15 forbids). The band is **flat/intensity-invariant by ruling**, matching the step-function form of the constants it adopts. Channel count 16 → **17**. |
| **RR-15** *(part 2 — confirm)* | **`fire_spread_mult` is confirmed published with per-state values** and was already complete for all six MVP states in §2.2 and `data/weather.json` (`1.00→1.10 / 0.95→0.95 / 0.70→0.55 / 0.50→0.35 / 0.60→0.45 / 1.35→1.70`) — no value changed; it simply gains its first consumer in doc 06 §2.8. §2.2.1 adds the two contract notes that consumer needs: it is a fuel-moisture/heat term only (**wind enters spread solely through doc 06's `g_wind` off this doc's `wind_kph`, never twice**), and the reference-storm value `lerp(0.60, 0.45, 0.77) = 0.4845` for doc 06's re-derivation. |
| **RR-15** *(supporting edits)* | §4 API comment records 17 channels and the three-fire-channel split; §5's doc-06 row lists both fire channels as provided; §6 MVP cut restated as a 17-channel table; §8 gains an inward-moving-constants table (the first key this doc has ever *adopted* rather than shed); tests **5** (17 channels), **5d** (adoption golden, intensity-invariance, doc-06 cross-check, anti-aliasing guard) and **5e** (spread channel published and valued) added, test **33** raised from 16 to 17 channels; §9 item 14 records the closure and the one deliberate residual (deferred states enter at a placeholder 1.00). |
