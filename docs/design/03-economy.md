# 03 — Economy, Taxes & Budgets

**Status:** Draft for overseer review. Subordinate to `00-constitution.md` (LOCKED).
**Owner scope:** treasury, tax revenue, expenses, land market, development costs, upgrade cost curve, offline income, difficulty economics, anti-bankruptcy.
**Doc numbering:** the on-disk filenames are canonical (report 98 Ruling Zero). 01 time & tick scheduler · 02 buildings, upgrades & construction projects · **03 this doc — economy, taxes, land market & difficulty** · 04 electrical grid · 05 water · 06 incidents, dispatch & emergency fleets (incl. construction crews as units) · 07 weather & Disaster Director · 08 persistence, offline policy & notification policy · 09 map, land, districts, **population & stability**, starter city · 10 roads, routing & traffic · 11 rendering & performance · 12 UI/UX · 13 Android integration. The earlier "sibling numbering assumed" note in this doc was one of the three incompatible maps Ruling Zero abolished; every reference below now uses the canonical map.

**Amendments from report 98 applied:** Ruling Zero, C-07, C-12, C-16, C-17, C-18, C-20, C-25, C-56, C-59, C-61, R-04, R-05, R-14. **Round 2 (report 98 §14, after the docs 96/97 verification pass):** RR-2, RR-5, RR-6, RR-7. See the final section for the change list.

---

## 1. Overview & Goals

The economy is the scoreboard the whole simulation writes to. Every cascade in spec §4 Pillar 1 must be legible as **dollars**: a transformer that fails costs the player tax revenue, utility tariff, repair capital, and overtime — all four, visibly, in the same panel.

Goals:

1. **Revenue is earned by keeping systems up, not by tapping.** Tax is continuous and multiplicative against power, water, road access, stability, happiness and condition. A dark district earns a fraction of a lit one.
2. **Early game is generous, mid game forces the spec §11.3 question.** Hours 0–3 the player can afford almost every want. Around real hour 5–6, the marquee growth project and the resilience package become mutually unaffordable, by construction (§2.11 guardrail G3).
3. **Growth always buys demand as well as income** (spec §55 rule 3). Tax grows **2.15×** per building level; power/water demand grows **faster than 2.15× in every growth class** — doc 02's `k_dem` is 2.35 `steady` / 2.45 `standard` / 2.55 `vertical` (C-13). Every upgrade therefore makes the city less utility-efficient, by `1 − 2.15/k_dem` = **8.5 % / 12.2 % / 15.7 %** per level. The requirement this doc imposes is the **inequality**, not a single number (report 98 RR-7).
4. **Cheap land is a trap.** Purchase price falls with risk and distance; development cost rises with both. Total cost of ownership is the real number and the UI shows it.
5. **You can always dig out.** No treasury state is a soft-lock. Recovery is free, automatic, and never gated behind IAP (spec §37.2).
6. **Every number here lives in `data/economy.json`** (§8). No magic numbers in code (constitution §2, §12).

Units per constitution §7: whole dollars, `int64`. All internal rates are **per game-hour (gh)**. UI displays **per game-day** (24 gh). At the locked 60× scale, **1 game-hour = 1 real minute** and **1 game-day = 24 real minutes**.

---

## 2. Mechanics

### 2.1 The settlement loop

The economy system ticks once per game-hour (constitution §4 cadence "economy per game-hour"). One tick:

1. `TaxAssessor` computes potential and actual revenue per building.
2. `UtilityBilling` computes tariff revenue from delivered energy/water.
3. `ExpenseLedger` computes recurring expenses.
4. `Treasury.settle(revenue, expenses)` applies austerity/credit/floor rules.
5. `economy_hour_settled` event is emitted with the full breakdown for UI and the WHILE-YOU-WERE-AWAY history.

**Precision rule.** Treasury is whole dollars (`int64`) per constitution §7. Per-building revenue is computed in float, summed for the whole city, and rounded **once per settlement**; the sub-dollar remainder is carried forward in `revenue_carry_millidollars` (`int64`) so no money is created or destroyed by rounding.

**No tap-to-collect — auto-accrual is ruled, not proposed (report 98 C-59).** Revenue accrues continuously. At in-game 06:00 the game raises a *Daily Settlement* card summarising the previous 24 gh. The spec §41.5 onboarding beat "collect taxes" is satisfied by a scripted first Daily Settlement, not by a repeating tap loop (spec §2.2: this is not a quest-heavy casual city game). C-59 **approves** this deviation from a literal reading of spec §41.5; the onboarding step becomes *review the ledger*, owned by doc 12. There is consequently **no `economy.manual_collection` flag** in `data/economy.json` and no code path that gates accrual on a player tap — the knob is deleted, not defaulted.

### 2.2 Tax revenue formula

For each revenue-producing building `b`:

```
R_b  =  base_tax[type][level]
      × occ_b
      × f_power(b) × f_water(b) × f_road(b)
      × f_stability(b) × f_happiness × f_condition(b)
      × tax_policy_factor
      × M_rev[difficulty]
```

`R_b` is dollars per game-hour. Civic and utility buildings have `base_tax = 0`.

**base_tax curve (the level family).**

```
base_tax(type, L) = round( base_tax_L1[type] × TAX_LEVEL_GROWTH^(L-1) )
TAX_LEVEL_GROWTH = 2.15
```

Level multipliers: `1, 2.15, 4.6225, 9.9384, 21.3675`.

**Yield anchor — a derivation aid, not a generator (report 98 RR-5).** `TAX_YIELD` explains *why* the L1 rows have the shape they do: residential 0.0100 (baseline), commercial 0.0105 (better yield, most outage-sensitive), industrial 0.0095 (worse yield, big jobs + big demand), tech 0.0117 (best yield, extreme demand and fragility).

```
base_tax_L1[type]  ≈  build_cost_L1[type] × TAX_YIELD[class]     (descriptive)
```

**The published `base_tax_by_level` rows below and the `$686/gh` starter anchor are LOCKED and normative.** They are woven through C-11, doc 09's starter manifest and Milestone 1 acceptance; the yield map is not. Verification 97 §3.2 (finding F-01) showed the two disagree on four of eight revenue archetypes:

| type | class | cost | `round(cost × TAX_YIELD)` | **published (normative)** | drift |
|---|---|---|---|---|---|
| house | residential 0.0100 | 1,200 | 12 | **12** | 0.00 % |
| apartment | residential 0.0100 | 7,000 | 70 | **70** | 0.00 % |
| highrise_res | residential 0.0100 | 26,000 | 260 | **260** | 0.00 % |
| store | commercial 0.0105 | 2,600 | 27 | **26** | −4.76 % |
| office | commercial 0.0105 | 13,000 | 137 | **130** | −4.76 % |
| highrise_com | commercial 0.0105 | 40,000 | 420 | **420** | 0.00 % |
| factory | industrial 0.0095 | 22,000 | 209 | **210** | +0.48 % |
| data_center | tech 0.0117 | 180,000 | 2,106 | **2,100** | −0.28 % |

Maximum drift is **4.76 %** (store, office). Conforming to the yield map would move the starter anchor to `18×12 + 5×27 + 3×70 + 1×137 = $698/gh` and break C-11's "evaluates exactly". **The rows win; the map is documentation.** §7 test 7 is therefore a **±6 % drift guard**, not an equality assertion — it catches a genuinely mis-classed archetype (a `tech` row priced at residential yield would drift 17 %) while tolerating the four hand-tuned cells.

**MVP building table** (doc 02 owns footprint/pop/jobs/demand; this doc owns the money columns):

| type | class | build cost L1 | base_tax L1..L5 ($/gh) |
|---|---|---|---|
| house | residential | 1,200 | 12 / 26 / 55 / 119 / 256 |
| apartment | residential | 7,000 | 70 / 151 / 324 / 696 / 1,496 |
| highrise_res | residential | 26,000 | 260 / 559 / 1,202 / 2,584 / 5,555 |
| store | commercial | 2,600 | 26 / 56 / 120 / 258 / 556 |
| office | commercial | 13,000 | 130 / 280 / 601 / 1,292 / 2,778 |
| highrise_com | commercial | 40,000 | 420 / 903 / 1,941 / 4,174 / 8,974 |
| factory | industrial | 22,000 | 210 / 452 / 971 / 2,087 / 4,487 |
| data_center | tech | 180,000 | 2,100 / 4,515 / 9,707 / 20,870 / 44,871 |
| police_station | civic | 18,000 | 0 |
| fire_station | civic | 20,000 | 0 |
| power_plant_gas | utility | 60,000 | 0 |
| substation | utility | 15,000 | 0 |
| water_plant | utility | 45,000 | 0 |
| construction_yard | civic | 16,000 | 0 |

*Three L4/L5 cells are one dollar below the half-up value of `round(base_tax_L1 × 2.15^(L−1))` — `highrise_res` L5 (5,555 vs 5,556), `data_center` L4 (20,870 vs 20,871) and L5 (44,871 vs 44,872), flagged as nits by verification 97 §3.2. Under RR-5 the published rows are locked, so they are **not** changed; §7 test 8 carries a ±$1 tolerance on generated cells instead.*

**occ_b — occupancy.** From **doc 09** (population, per report 98 G-1). Residential: `occupied_population / capacity`. Commercial/industrial/tech: `jobs_filled / jobs`. Clamped `[0, 1]`. Fresh buildings ramp from 0.35 to 1.0 over `OCCUPANCY_RAMP_HOURS = 36` gh.

**f_power, f_water, f_road — utility availability.** These are the cascade transmission channel.

```
f_power(b) = floor_power[class] + (1 - floor_power[class]) × p_b
f_water(b) = floor_water[class] + (1 - floor_water[class]) × w_b
f_road(b)  = floor_road[class]  + (1 - floor_road[class])  × a_b
```

- `p_b` = fraction of the settled hour building `b` had power at nominal voltage (doc 04, `power_availability_hour`). Backup generation counts as available; its fuel is billed (§2.4).
- `w_b` = `clamp(delivered_pressure / nominal_pressure, 0, 1)` (doc 05, `water_service_factor_hour`).
- `a_b` = **`access_quality(pos) ∈ [0,1]` from doc 10** (report 98 C-61). This doc no longer defines a `road_access_factor` of its own; the term is deleted and doc 10's single definition is consumed. Flooded or blocked segments drive it down. **Do not confuse it** with doc 09's block-level `block_road_access_score`, a *development* attribute that feeds land price via `A_factor` (§2.7) and never touches `f_road`.

Floors by class (power / water / road): residential `0.35 / 0.45 / 0.85`, commercial `0.10 / 0.35 / 0.55`, industrial `0.15 / 0.20 / 0.60`, tech `0.00 / 0.10 / 0.80`. A data center with no power earns nothing; a house with no power still earns 35% of its power term because people still live there.

**f_stability.** District stability **`S ∈ [0,1]`**, owned by **doc 09** (report 98 C-56). The `[0,100]` scale this doc used is deleted — there is no `/100` in the formula and no conversion anywhere in `sim/economy/`.

```
f_stability = STAB_FLOOR + (1 - STAB_FLOOR) × S^STAB_EXP
STAB_FLOOR = 0.25,  STAB_EXP = 0.70
```

Reference values (identical numbers, restated on the ruled scale): S=1.00 → 1.0000, S=0.88 → 0.9358, S=0.82 → 0.9027, S=0.70 → 0.8343, S=0.61 → 0.7807, S=0.40 → 0.6449, S=0.10 → 0.3996.

The building's `S` is its own district's stability. `city_stability` (the population-weighted mean over districts) is also published by doc 09 and is used only by the Resilience Index and the UI — never by `f_stability`.

**f_happiness.** City happiness `H ∈ [0,100]` from **doc 09**.

```
f_happiness = clamp(1.0 + HAPPY_SLOPE × (H - 60)/100, 0.75, 1.25)
HAPPY_SLOPE = 0.50
```

H=60 → 1.00 (neutral), H=100 → 1.20, H=20 → 0.80.

**f_condition.** Building condition `C ∈ [0,1]`, owned by **doc 02** (rescaled to `[0,1]` per report 98 C-14; damage that moves it comes from docs 06 and 07).

```
f_condition = COND_FLOOR + (1 - COND_FLOOR) × C,   COND_FLOOR = 0.40
```

> **`COND_FLOOR` 0.55 → 0.40** *(doc 92 §13.3, ruled Wave 4; the doc edit doc 92 §16 held is applied here)*. The floor is not a taste setting — it sets **the payback period of a repair**. At 0.55 a repair bought its price back in ≈19 game-days of recovered revenue, which is outside the pacing horizon §2.12 is written against, and doc 92 pass-2 F-2 could not measure maintenance paying for itself at all; at 0.40 the payback is ≈14 game-days and the maintaining agent overtakes the neglecting one inside 21. **`f_condition(1.0) = 1.0` at every floor, so no founding anchor moves** — §2.12's ledger is untouched. What moves is the two worked examples below, and `tests/test_economy.gd` carries the new literals with the arithmetic in a comment.

**tax_policy_factor.** The player sets a citywide rate `r` on a slider, `[0.04, 0.16]`, default `0.09`.

```
tax_policy_factor = r / TAX_RATE_BASE,   TAX_RATE_BASE = 0.09
```

The cost is paid in doc 09, on **three** channels:

```
happiness_tax_delta       = -(r - 0.09) × TAX_RATE_HAPPINESS_COEFF (360)      # doc 09 §2.10.3, H_target
growth_rate_multiplier    = 1 - (r - 0.09) × TAX_RATE_GROWTH_COEFF  (8.0)     # doc 09 §2.10.2, relaxation RATE
attractiveness_tax_factor = 1 + TAX_RATE_ATTRACT_PULL (1.30) × min(0, happiness_tax_delta) / 100
                                                                              # doc 09 §2.10.2a, relaxation TARGET
```

At r = 0.16 revenue is ×1.778, happiness drops 25.2 points, attractiveness relaxes 56 % slower **and** toward a ceiling of 0.6724 instead of 1.00 — a short-term lever with a long-term bill. Rate changes are limited to once per `TAX_RATE_COOLDOWN_HOURS = 48` gh to stop yo-yo exploitation.

**`TAX_RATE_HAPPINESS_COEFF` is 360, not the 220 this section shipped with (Wave-7 ruling; doc 92 §20, doc 93 §E2).** Wave 6 made the power grid buyable, which handed the ×1.778 revenue somewhere to go: on doc 92's own 21-game-day matrix the pinned-slider agent ended **ahead of `balanced` on population as well as on money** (+43 % people, +104 % value created) for a happiness deficit of 1.6 points — strictly dominant, which is exactly what F-5 ruled against. Because all three channels above are denominated in the points `happiness_tax_delta` produces, **one coefficient moves the whole coupling**, and the rate is still read exactly once. The retune is *anchor-neutral by construction*: the delta is 0 at `TAX_RATE_BASE`, so no founding figure in this document changes and both state hashes are bit-identical (`tools/profile_sim.gd --baseline`). What changes is only what the player buys at the other detents.

**The third channel is new (doc 09 amendment T-1) and it is the one that bites.** Doc 92 pass-2 F-5 moved `TAX_RATE_GROWTH_COEFF` 3.5 → 8.0 to make the top detent cost "a city later", and it cost nothing: the multiplier scales `(A_target − A_city)`, and doc 09's `A_target` saturates at 1.00 for any `city_stability ≥ 0.85`, so in a healthy city it multiplied zero. `attractiveness_tax_factor` prices the slider into the **target** instead of the rate. It is deliberately built on `happiness_tax_delta` rather than on `r` a second time: the rate is converted to happiness points once, here, and doc 09 spends those points on the one attractiveness scale it has — the same no-double-count discipline report 98 C-07/C-08 apply to prices, applied to a coupling. `min(0, ·)` keeps it one-sided: below the base rate the factor is exactly 1.0, because a tax cut buys a **faster refill** (that IS `growth_rate_multiplier`, 1.40× at the bottom detent) and never an attractiveness ceiling above the stability one. Doc 09 owns the mapping and composes its three ceilings with `min`, so an overtaxed city is never billed twice for the same discontent.

**As shipped (Wave 1.5, audit doc 93 §B).** The slider has detents: **`cmd_set_tax_level(level, preview)`** walks `TAX_RATE_MIN … TAX_RATE_MAX` in `TAX_RATE_STEP` (new in §8, **0.01**) increments — 13 levels, with **level 5 landing exactly on `TAX_RATE_BASE`** — and the ladder is computed in basis points so no detent can drift off its authored rate through float arithmetic. Codes are `E_TAX_LEVEL_RANGE` then `E_TAX_COOLDOWN` (whose payload carries `hours_remaining`); re-selecting the level already in force is a free no-op that starts **no** cooldown, so the UI need not special-case it. All **four** couplings are live: the policy factor scales revenue here, and `happiness_tax_delta` / `growth_rate_multiplier` / `attractiveness_tax_factor` are passed into doc 09's happiness target, attractiveness relaxation rate and attractiveness ceiling at the hourly settlement — all exactly neutral (0 / 1.0 / 1.0) at the base rate, so the shipped starter city is unaffected and the founding ledger does not move. *(The audit's phrase "the `TAX_LEVEL_GROWTH` curve exists" conflated two constants: `TAX_LEVEL_GROWTH 2.15` is `base_tax` growth per **building** level and has nothing to do with the tax rate.)*

**M_rev[difficulty]** — §2.9. **It appears here and in the revenue-floor formula below, and NOWHERE ELSE** (doc 93 §N2): it is the *tax* multiplier, not a multiplier on §2.5's non-tax lines. §2.9's table says so and states the measured effective figure.

**City revenue floor (anti-death-spiral).** After summing all buildings:

```
R_potential_city = Σ base_tax(b) × occ_b × tax_policy_factor × M_rev
R_actual_city    = max( Σ R_b , REV_FLOOR_FRACTION × R_potential_city )
```

`REV_FLOOR_FRACTION = 0.18` (standard). This is applied at the **city aggregate only** — per-building numbers shown in the UI stay brutally honest so the cascade remains legible, but the treasury can never be driven to literally zero income by a compound failure. Without it the worst-case multiplier product is 1.4% and the city cannot fund its own rescue. See §2.10.

#### Worked example A — healthy house, level 2

`base_tax = 26`, occ 1.00, power 1.00, water 1.00, road 1.00, **S = 0.82**, H=68, C=0.95, r=0.09, standard.

```
f_stability = 0.25 + 0.75 × 0.82^0.70 = 0.25 + 0.75 × 0.8703 = 0.9027
f_happiness = 1.0 + 0.5 × (68-60)/100 = 1.040
f_condition = 0.40 + 0.60 × 0.95 = 0.9700

R = 26 × 1.0 × 1.0 × 1.0 × 1.0 × 0.9027 × 1.040 × 0.9700 = 23.68  →  $24/gh  ($568/game-day)
```

#### Worked example B — the same house during a 40-minute outage

Transformer trips at minute 20. `p = 20/60 = 0.333`. The feeder also fed a water pump, so pressure halves: `w = 0.50`. District stability falls to **S = 0.61**, happiness to 62.

```
f_power     = 0.35 + 0.65 × 0.333 = 0.5667
f_water     = 0.45 + 0.55 × 0.50  = 0.7250
f_stability = 0.25 + 0.75 × 0.61^0.70 = 0.7806
f_happiness = 1.010
f_condition = 0.9700

R = 26 × 0.5667 × 0.7250 × 1.0 × 0.7806 × 1.010 × 0.9700 = 8.17  →  $8/gh
```

**66% revenue loss in one hour from one transformer**, before counting the lost power tariff (§2.4) and the repair bill. This delta is what the *Foregone Revenue* line in the budget panel reports (§2.6).

#### Worked example C — data center, level 3, on backup power

`base_tax(L3) = 9,707`. Jobs filled 0.95, **S = 0.88**, H=70, C=1.0, r=0.09.

```
f_stability = 0.9358,  f_happiness = 1.050
R = 9707 × 0.95 × 0.9358 × 1.050 = 9,061 $/gh  ($217,464/game-day)
```

Grid fails; the site's diesel backup holds `p = 1.0`, so revenue is preserved — but doc 04 reports 2.21 MW served from diesel:

```
fuel = 2.21 MWh × $95/MWh = $210/gh   (vs $84/gh had gas grid served it)
tariff earned = 2.21 × $62 = $137/gh
```

The backup runs at a **$73/gh operating loss** while preserving $9,061/gh of tax. Correct incentive: backup is a lifeline you pay for, not a free pass.

### 2.3 Capital value and the upgrade cost curve

One curve family, so doc 02 can derive every cost column from a single `build_cost_L1`:

```
upgrade_cost(type, L → L+1) = round( build_cost_L1[type] × UPG_COEFF × UPG_GROWTH^(L-1) )
UPG_COEFF = 1.15,   UPG_GROWTH = 2.55
```

Step multipliers of `build_cost_L1`: `1.15, 2.9325, 7.4779, 19.0686`.

> **`UPG_COEFF` 1.45 → 1.15 (Wave 17, doc 93 §Y7, doc 92 §43.3).** From the
> 2026-09-01 playtest: *"upgrading buildings is way too aggressive on the
> prices."* The new value is **an identity, not a fit**:
> `UPG_COEFF = TAX_LEVEL_GROWTH − 1`. The Payback block below shows why — the
> bracket `UPG_COEFF / (TAX_LEVEL_GROWTH − 1)` is the whole of an upgrade's
> price relative to building a fresh one, and setting it to 1 makes the first
> rung pay back in exactly the time a new build does. PA-46's proposed ceiling
> `1.15 × (TAX_LEVEL_GROWTH − 1) = 1.3225` is 15 % loose and is superseded: it
> makes the first rung 15 % *worse* than a new build, which is the opposite of
> its own stated target.

```
capital_value(type, L) = round( build_cost_L1[type] × V(L) )
V(L) = 1 + (UPG_COEFF/(UPG_GROWTH-1)) × (UPG_GROWTH^(L-1) - 1)
     = 1 + 0.74194 × (2.55^(L-1) - 1)
V = [1.000, 2.150, 5.083, 12.560, 31.629, 80.254]
```

Every cell of `V` is now its own closed form at 3 dp, half-up; the L3 / L5
disagreements the 1.45 vector carried (6.147 against an exact 6.1475, 39.620
against 39.6191187) were artefacts of that coefficient and went with it.

`capital_value` drives maintenance (§2.4), repair cost (§2.5), demolition refund, and insurance-style disaster accounting.

House example: build 1,200 → upgrades 1,380 / 3,519 / 8,973 / 22,882 → L5 capital value 37,955, L5 tax 256 $/gh. *(At `UPG_COEFF` 1.45 these were 1,740 / 4,437 / 11,314 / 28,852 and 47,544 — every upgrade price is now 79.31 % of what it was, and every capital value above L1 falls with it, so maintenance, repair, refunds and disaster accounting all follow.)*

**Payback.** Gross payback of one upgrade step, ignoring multipliers:

```
payback_gh(L→L+1) = UPG_COEFF / (TAX_YIELD × (TAX_LEVEL_GROWTH - 1)) × (UPG_GROWTH/TAX_LEVEL_GROWTH)^(L-1)
                  ≈ 100 × [UPG_COEFF/(TAX_LEVEL_GROWTH-1)] × 1.186^(L-1)   game-hours
```

**The bracket is the ruling** (doc 93 §Y7). `build_cost_L1 / base_tax_L1` is
exactly **100 gh for every revenue archetype** — house 1,200/12, apartment
7,000/70, and the four above them alike — so an upgrade's payback relative to
building a fresh L1 is `UPG_COEFF / (TAX_LEVEL_GROWTH − 1)` and nothing else. At
`UPG_COEFF = TAX_LEVEL_GROWTH − 1 = 1.15` that bracket is 1 and the first rung
matches a new build exactly; every rung above it is spaced by
`UPG_GROWTH / TAX_LEVEL_GROWTH = 1.18605`, which doc 02 §8's rule requires to
stay above 1 so that each upgrade is less utility-efficient than the last.

**The ruled window is `[100, 200] gh`** — one new-build payback to two — and 1.15
is the largest coefficient whose whole six-rung ladder fits inside it. Measured
on the shipped, rounded tables (house, `upgrade_cost / Δbase_tax`):

| step | at `UPG_COEFF` 1.45 | **at 1.15** |
|---|---|---|
| L1→L2 | 124.3 gh | **98.6 gh** |
| L2→L3 | 153.0 gh | **121.3 gh** |
| L3→L4 | 176.8 gh | **140.2 gh** |
| L4→L5 | 210.6 gh | **167.0 gh** |
| L5→L6 | 249.4 gh | **197.8 gh** |

Fresh L1 construction pays back in **100 gh**, so the first rung is now *cheaper
than sprawling* — which is what level 2's "upgrade instead of building more" card
has been teaching against since it was written (PA-46). The top two rungs move
inside the window; at 1.45 they were outside it. Early growth is fast; late
vertical growth is still a genuine capital decision, because the 1.186 spacing is
untouched. This is the intended shape of the §11.3 question.

**Demolition refund** = `DEMOLITION_REFUND_FRACTION (0.25) × capital_value`. **Downgrade is not permitted** (a building is upgraded or demolished).

### 2.4 Expense model

```
E_total = E_building_maint + E_departments + E_fleet + E_fuel_vehicle
        + E_grid + E_fuel_generation + E_water + E_roads_repair
        + E_debt + E_oneoff
```

All × `M_exp[difficulty]` except **`E_roads_repair`**, `E_debt` and `E_oneoff` (which carry their own difficulty terms).

**`E_roads_repair`'s exception is new (Wave 12, doc 93 §N1) and it is a fix, not a design change.** That line's own formula below ends `× M_repair[difficulty]`, and it is an ACCRUAL against a payment — the auto-repair policy's realised job, priced by §2.5's `repair_cost = capital_value × damage_fraction × 0.85 × M_repair`. Before the ruling the settlement swept it into `M_exp` as well, so it took **`M_repair × M_exp` — 2.0000 on `crisis` against 1.2500 on every other line** — and the ledger accrued 1.25× what the same tiles cost to fix. An accrual that does not converge on its payment is the double count C-07 / C-08 / C-12 / RR-2 keep removing, one knob down. Doc 92 §29.2(b) measured it; doc 92 §32 measures the fix. **Nothing on the default preset moves**: both knobs are 1.00 on `standard`. The rule, stated once so no fourth reading is possible: **one difficulty knob per ledger line, never two** — seven recurring lines take `M_exp`, `E_roads_repair` takes `M_repair`, `E_debt` takes the APR, `E_oneoff` takes whichever price knob authored it.

**E_building_maint** — revenue-producing buildings only, **and STANDING ones only** (doc 93 §AR3, Wave 20). Civic and utility buildings are covered entirely by their department/O&M lines; billing them twice was the original balance error. **A RUIN IS NOT BILLED.** This line is the city's cost of SERVING a building (§Y1's own definition, which is what kept the line alive when the ownership ruling landed), and a ruin is served by nothing — no power, no water, nobody housed, no traffic, `state_occupancy()` 0.00 and therefore $0 of tax and $0 of `potential`. Until Wave 20 it WAS billed, and at the worst rate the formula can produce: `C_b` is 0 for a ruin, so `(1 + MAINT_CONDITION_PENALTY × (1 − C_b))` sits at its maximum **2.5×** and a destroyed building cost the city two and a half times what the same building costs in perfect repair. On the 2026-09-03 player save that was **$1,044.39/gh of $1,055.12 — 99.0 % of the line — charged against rubble** (doc 92 §58.2). `CitySim.build_settlement_inputs` skips `state == destroyed`.

```
E_building_maint = Σ capital_value(b) × BUILDING_MAINT_RATE × (1 + MAINT_CONDITION_PENALTY × (1 - C_b))
BUILDING_MAINT_RATE = 0.00040 /gh      (0.96% of capital per game-day)
MAINT_CONDITION_PENALTY = 1.5
```

At full condition and L1 this is exactly 4% of the building's gross base tax. Because capital grows on the 2.55 curve while tax grows on 2.15, maintenance climbs to 7.4% of gross by L5 — a deliberate, mild drag that makes tall buildings slightly more expensive to hold than wide ones.

**E_departments** — per **standing** station, per level: `station_upkeep(type, L) = round( station_upkeep_L1[type] × DEPT_LEVEL_GROWTH^(L-1) )`, `DEPT_LEVEL_GROWTH = 1.75`. **A RUINED STATION DRAWS NO WAGES** (doc 93 §AR3, Wave 20): this line is staffing, and a destroyed shell has no staff. It too was billed at its maximum before Wave 20 — `ASSET_CONDITION_PENALTY_COEFF` 2.0 against a ruin's condition 0 is **3.0×** a healthy station — and on the 2026-09-03 player save **100 % of the line, $306.00/gh, was four shells that no longer existed**. `CityIncidentWorld.station_rows()` carries the same guard, because it is `FleetSystem.populate_from_stations`'s only source and a ruined garage was also housing an `E_fleet` bill — **on the boot path only**: `FleetSystem.deserialize` rebuilds the roster from the save and nothing retires a unit when its station is destroyed, so `E_fleet` for a station lost mid-run is doc 91 A91-D-111's open remainder and is not closed here. Upkeep at L1 ($/gh): police_station 26, fire_station 30, utility_depot 24, **water_works 20 (staffing only)**, construction_yard 20, ems_station 28 (post-MVP), hospital 45 (post-MVP).

**Staffing-only lines (report 98 RR-16).** Where a utility formula already bills a facility's O&M, the department line for that service covers **staffing only** and must say so, or the facility is charged twice — the C-08 error in a new place. Two cases exist today: `water_works 20` is **staffing only**, because the water works' plant O&M is `E_water`'s `pump_capacity_m3h × PUMP_OM_PER_M3H_HOUR` ($14.00/gh on the starter pump); and `PLANT-1` / `SUB-A` carry **no department line at all**, because `E_grid`'s `PLANT_OM_PER_MW_HOUR` and `GRID_MAINT_PER_MW_HOUR` bill them in full (§2.12(b)). No number changes — the labelling makes the existing split legible.

A **mothballed** station pays `MOTHBALL_UPKEEP_FRACTION = 0.15` of upkeep, provides zero coverage, and costs `0.60 × station_upkeep × 24` to reactivate (§2.10).

**E_fleet** — per vehicle: `vehicle_cost(v) = vehicle_upkeep[type] × (dispatched ? active_mult[type] : 1.0)`.

The definitive roster (purchase, standby upkeep, active multiplier, one-off `dispatch_cost`, fuel class) is **§2.13(c)** and the `expenses.vehicles` block of §8 — 15 vehicle types from `patrol_car` ($9,000 / $7 gh / ×2.5 / $17 / light) to `mobile_transformer` ($48,000 / $24 gh / ×2.0 / $58 / heavy). Per report 98 C-07 this is the **only** vehicle price table in the project; doc 06's `purchase_cost` / `upkeep_per_game_hour` / `dispatch_cost` columns are deleted (look in §2.13(c) for them).

Standby upkeep is authored per role in the band **0.05 %–0.11 % of purchase per game-hour** — labour-heavy units (crews) sit at the top of the band, capital-heavy units (mobile transformer) at the bottom — so a vehicle costs roughly 1.2–2.6 % of its price per game-day just to exist, and 3–8 % when it is running.

Vehicle resale = `VEHICLE_RESALE_FRACTION (0.40) × purchase`.

**E_fuel_vehicle** = `Σ km_driven_this_hour(v) × FUEL_COST_PER_KM[fuel_class]` with light 0.6, medium 1.1, heavy 1.9 $/km. Doc 06 supplies `vehicle_km_this_hour` per vehicle. Weather multipliers (snow, flood) come through **doc 07** as `fuel_weather_mult` (blizzard 1.25, heavy rain 1.10).

**E_grid** — **this formula is the only source of recurring electrical-plant cost (report 98 C-12).** Doc 04's flat `upkeep_per_gh` column is **deleted** from `data/power.json`; doc 04 supplies only the *inventory* (`rated_mva`, `condition`, `line_km`, `plant_capacity_mw`) and this doc prices it:

```
E_grid = Σ_nodes  node_rated_MVA × GRID_MAINT_PER_MW_HOUR (4.0) × (1 + ASSET_CONDITION_PENALTY_COEFF (2.0) × (1 - condition))
       + Σ_lines  line_km × LINE_MAINT_PER_KM_HOUR (0.9) × (1 + 2.0 × (1 - condition))
       + Σ_plants plant_capacity_MW × PLANT_OM_PER_MW_HOUR (5.0)
```

`node` covers substations **and** transformers (both carry `rated_mva`); `line` covers feeder and transmission route tiles converted to km at 8 m/tile (constitution §6); `plant` covers every generating unit. Nothing in doc 04 may bill a flat per-component rate in parallel — that double-billing is exactly what C-12 removed.

*Worked value — the starter city at founding* (**inventory per doc 09 §2.9.5, the owning doc's R-16 result**; all condition 1.00):

```
plant      1 × plant_gas L1, 8.0 MW        → 8.000 × 5.0          = $40.000/gh
substation 1 × SUB-A L1, 6.0 MVA           → 6.000 × 4.0 × 1.0    = $24.000/gh
transformers 7 × L1 (0.05) + 10 × L2 (0.15) + 1 × L3 (0.40) = 2.25 MVA
                                            → 2.250 × 4.0 × 1.0   =  $9.000/gh
lines      147 feeder + 30 transmission = 177 tiles × 8 m = 1.416 km
                                            → 1.416 × 0.9 × 1.0   =  $1.274/gh
                                                          E_grid  = $74.274 → $74.3/gh
```

> **The transformer term, restated on the 18-node roster** *(doc 92 §14.1, Wave 4)*. Doc 92 F-4 thinned doc 09 §2.9.5's founding fleet from 23 nodes to **18** — the five deleted sites' streetlights, signals and customers re-home onto the nearest survivor, so the LOAD is conserved and only the rated PLATE falls, `2.40 → 2.25 MVA`. This line falls with it by `0.15 × 4.0 = $0.60/gh`; every other term is untouched. Test 37's band (`74.9 ± 0.5`, harmonised with doc 04's test 24 under RR-18) needs re-centring on **`74.3 ± 0.5`** when doc 04's owner next touches it — `tests/test_economy.gd` already asserts the new figure.

*Round 2 correction (report 98 RR-6, verification 97 finding F-02).* This doc previously priced the same plant at **$73/gh** against an assumed **14 × L1 + 9 × L2 = 2.05 MVA over 110 feeder tiles (0.88 km)**. Doc 09 §2.9.5 publishes the real fleet — **13 × L1 + 9 × L2 + 1 × L3 = 2.40 MVA** (the water works needs an L3 for its 132 kW site load, per C-35) and **177 line tiles = 1.416 km** — so the correct figure is **$74.87/gh**. The **±$1 tolerance in doc 04's test 24 fails against $73**; the expectation moves to **`74.9 ± 0.5`** (report 98 RR-18 harmonises the band on both sides — doc 04's test 24 and this doc's test 37 now carry the identical `$74.9 ± 0.5/gh`; the old $73 sits **1.874** below the centre, well outside `[74.4, 75.4]`, so the figure was wrong rather than merely rounded). This doc's §9 item 6c assumption about doc 04's transformer mix is now **closed** — doc 09 published the mix and this doc reads it.

Against the **$32/gh** this doc originally assumed for the whole electrical plant (`plant O&M 10 + grid 16 + lines 6`), that is **+$42.9/gh**. The full consequence is worked through in §2.12.

**E_fuel_generation** = `Σ generation_MWh_this_hour(plant) × FUEL_PRICE_PER_MWH[plant_type] × plant_efficiency_mult[level]`:
gas 38, diesel 95, coal 30, nuclear 9, solar 0, wind 0, hydro 0. These $/MWh figures are the **only** generation fuel prices (C-07); doc 04's `fuel_cost_per_kwh` column is deleted, and the level-efficiency shape it encoded survives as a dimensionless `plant_efficiency_mult` per level that doc 04 supplies: gas `[1.000, 0.935, 0.871, 0.806, 0.758]`. Battery discharge is free here; round-trip loss is doc 04's problem. Backup-generator diesel is billed at the same $95/MWh (doc 04 owns the fuel *model* per C-36; this doc owns the price).

**E_water** (doc 05 supplies volumes):

```
E_water = m3_treated × WATER_TREAT_COST_PER_M3 (0.06)
        + main_km × WATER_MAIN_MAINT_PER_KM_HOUR (0.7) × (1 + 2.0 × (1 - condition))
        + pump_capacity_m3h × PUMP_OM_PER_M3H_HOUR (0.35)
```

**E_roads_repair** — **new in Round 2 (report 98 RR-2).** Roads carry **no standing per-tile upkeep**; their recurring cost is the condition they lose, bought back at the C-16 price. Doc 10 supplies the physics, this doc supplies the money:

```
E_roads_repair = Σ_tiles  capital_value(tile) × decay_this_hour(tile) × REPAIR_COST_PER_CAPITAL (0.85) × M_repair
capital_value(tile) = road_build_cost_per_tile[class] × ROAD_REPAIR_CAPITAL_FRACTION (0.20)
decay_this_hour(tile) = base_decay[class] × (1 + 0.75 × c_day) × (1 + wx_wear_day) / 24     (doc 10 §2.12)
```

In implementation this is not a separate charge — it is the *accrual* the auto-repair policy realises as lumpy `E_oneoff` repair jobs. The ledger books it as a recurring line because that is what the player experiences and what the budget panel must show; `ExpenseLedger` reconciles the accrual against actual repair spend each game-day so no dollar is counted twice. **Nothing in doc 10 may bill a flat per-tile rate in parallel** — that double-billing is exactly what RR-2 removed, in the same shape as C-12 for the grid and C-08 for buildings. **And nothing may apply `M_exp` to it on top of the `M_repair` in the formula above** (doc 93 §N1): the accrual is priced with the same knob as the payment it accrues for, or it does not reconcile. Worked for the starter core in §2.12(f) at doc 10's published starter operating point `c_day = 0.35` (decay multiplier **1.2625**): **$185.87/gh**. *(Round 2 booked this line at the `c_day = 0` floor, $147.22/gh; report 98 RR-13 moved it onto the operating point doc 10 actually publishes.)*

**E_debt** — §2.10.

**E_oneoff** — capital and incident spends passed through `Treasury.spend()`, never part of the recurring rate: construction, upgrades, land, development phases, **road build/upgrade/demolish jobs and realised road repairs**, vehicle purchase, repairs, preventive maintenance, contractor surcharges.

### 2.5 Non-tax revenue, repairs, and preventive maintenance

**Utility tariffs.** Reliability pays twice: `tariff_revenue = delivered_MWh × POWER_TARIFF_PER_MWH (62) + delivered_m3 × WATER_TARIFF_PER_M3 (0.55)`.

Gas-fired grid power nets +$24/MWh; diesel backup nets **−$33/MWh**. Undelivered energy earns nothing — the outage hits tax *and* tariff.

**City services — the live line that replaces "Fines & fees"** *(report 98 RR-78).* `POLICE_FINE_PER_RESOLVED_INCIDENT = 350` is **deleted**, and so is the `fines` ledger line it fed. It and doc 06 §2.7's `reward_base[crime] = 350` were the same dollar under two names — doc 06 asked for the ruling in its own open question 6 in Wave 1 and §N1 of doc 93 wrote the re-open condition — and only doc 06's was ever live. This doc's half was metered by `CitySim.HELD_FINE_RATE = 3/350`, a §9 item 6b held constant that printed a flat **$3.00/gh on every preset at the founding hour, at 21 game-days and at 48**, while doc 06 credited the real money straight to the treasury where no ledger line and no notification ever named it.

The re-open condition — *"when doc 06 publishes real resolutions, the line becomes a measurement"* — is met. The measurement, taken on a `do_nothing` city that builds nothing and dispatches nothing: **$921 on its founding game-day, 12.5 % of that day's net income, invisible since Wave 1.**

```
city_services = Σ dispatch payouts this game-hour + Σ street collections this game-hour

dispatch payout = dispatch_payout_base[type]              # this doc, §2.13(e)
                × (1 + tier_k·(tier_peak − 1)) × speed_bonus   # doc 06 §2.7's SHAPE
                × (manual ? manual_dispatch_mult(city_level) : 1.00)   # Wave 19
                capped at MORAL_HAZARD_CAP_FRACTION (0.75) × prevented_loss

prevented_loss  = capital_value(target) − repair_cost(target, residual_damage_fraction)
                = −1 where this doc prices no capital (road edges, water segments)
```

**One line, not two, and the sub-grain lives inside it.** Dispatch and street are one concept — *the city answered a call and got paid* — and splitting a line a player reads into two half-sized ones buys nothing. The snapshot carries `city_services_by_source: {dispatch, street}` beside the total, exactly as `tax_by_class` already sits beside `tax`.

**`MANUAL_DISPATCH_MULT = 1.50` is doc 06's own `speed_bonus_max`, adopted rather than invented.** The game already prices a perfect response at 1.50×; a human working the incident drawer is worth the same. It applies only when `Incident.manual_requested` is true — only through `cmd_dispatch_unit` — so auto-dispatch pays exactly the dollars it has quietly earned since Wave 1 and the premium is the part a player has to turn up for.

**AND SINCE WAVE 19 THE PREMIUM GROWS WITH THE CITY** *(report 98 §60 RR-169, doc 92 §57.2.1, doc 91 A91-D-106)*:

```
manual_dispatch_mult(city_level) = MANUAL_DISPATCH_MULT (1.50)
                                 + MANUAL_DISPATCH_LEVEL_K (0.90) × (city_level − 1)
```

| city level | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| premium | 1.50× | 2.40× | 3.30× | 4.20× | 5.10× | **6.00×** |
| reference crime, dispatched by hand | $892.50 | $1,428 | $1,964 | $2,499 | $3,035 | **$3,570** |

**The defect it closes is that every factor in the payout above is a property of the INCIDENT and none of the PAYER.** The reference crime paid $595 on game-day one and $595 on game-day three hundred, while the city's own net per real-minute went **537.7 → 2,755.4** (`pacing_guardrails.MODEL_NET_PER_HOUR_BY_CITY_LEVEL`). The reward for answering an incident therefore lost **80.5 %** of its real value across doc 09's ladder — a decay, not a level, and the player reported it from outside the project: *"the crimes we stop are only a few hundred dollars."*

**0.90 is fitted under that series and deliberately not to it**: 6.00/1.50 = 4.00× against a city that got 5.12× richer, so the premium closes most of the decay and never outruns the city that pays it. **Two bounds keep it out of the balance matrix and out of gate 31, and both were already here.** (1) Only the MANUAL half scales, so auto-dispatch is untouched at every level and every control agent earns what it earned before — RR-78's own argument, used a second time. (2) It is asked for only where this doc can PRICE the target, i.e. where `prevented_loss ≥ 0`; there the moral-hazard clamp is a fraction of the loss prevented and therefore already grows with the asset. Where the target is unpriced, the premium stays flat at 1.50, because `MORAL_HAZARD_UNPRICED_CEILING` is derived from an avenue rebuild and an avenue does not get dearer because the city levelled up.

**The moral-hazard ceiling, and why it BINDS on shipped numbers.** The hazard is not arson (there is no arson verb); it is *waiting*. Doc 06 grows the payout at `tier_k = 0.35` per tier while doc 02 grows the residual damage at `0.10` per tier, so on a cheap building the reward outruns the value at risk from about tier 4 up. House L1, capital $1,200, tier-5 fire answered at the target response: the payout is `900 × 2.40 = $2,160`, the residual damage is 0.40 so the repair costs `1,200 × 0.40 × 0.85 = $408`, and the loss prevented is **$792** — an unclamped ratio of **2.73**. At 0.75 the city pays $594. The fraction is placed between doc 06 §2.7's own ruled worked example (0.679 of prevented loss, so a lower cap would retune a ruled payout at its reference point) and 1.00 (indifference between a fire and no fire, which plus variance is a strategy): the midpoint to the nearest 0.05. Balance gate 31 holds all three surfaces of it.

**Where the clamp cannot reach**, `prevented_loss` answers −1 rather than 0 — a road edge and a water segment have no `capital_value` in this doc, and a clamp that read a zero there would silently delete a payout the design intends to pay. Those three types are held instead by `MORAL_HAZARD_UNPRICED_CEILING = $3,900`, derived from the most expensive single asset a road-class response protects (a `COLLAPSED` AVENUE rebuilt at the full §2.13(d) build price, $5,200, × 0.75). The worst case any of them can pay today is `base × 5.40` — tier 5, best speed, manually dispatched — i.e. $1,620 / $2,160 / $2,700.

**Street opportunities** (doc 06 §2.16's tappable street life) are priced here too, for the same C-07 reason — **and since Wave 15 they are priced here ONLY** *(report 98 RR-81, doc 92 §39.1)*. Each kind is a BAND, `{base, spread}`, drawn once at spawn and frozen onto the offer:

| kind | base | spread | mean | top | *(Wave-18 band, for reference)* |
|---|---:|---:|---:|---:|---|
| `petty_crime` | 430 | 155 | **507.50** | 585 | *260 + 90* |
| `loose_animal` | 250 | 100 | **300** | 350 | *150 + 60* |
| `lost_valuables` | 700 | 300 | **850** | 1,000 | *420 + 180* |

`reward = round((base + spread·u) × (1 + STREET_REWARD_CITY_LEVEL_K·(city_level − 1)))`, `k = 0.25` *(Wave 19; it was 0.20)*.

**RE-PRICED WAVE 19, AND IT IS A TRADE RATHER THAN A RAISE** *(report 98 §60 RR-169, doc 92 §57.1)*. The bands above are ×5/3 and `data/street.json`'s `spawn.target_interval_h` is 1.50 → 2.85 **in the same commit**, so a single collection is worth 1.70× and the LAYER's income per game-hour is unmoved: measured mean bounty $320.29 → $543.11, measured mean interval 1.763 → 2.947 game-hours, measured ceiling $181.65 → $184.30/gh, founding ceiling share 35.90 % → 36.42 % against a 40 % bound.

**There was no other move available, and the arithmetic is the reason.** The ceiling on this layer is a SHARE of the city's net and it was already at 35.9 % of 40 %, i.e. 1.114× of headroom. A bigger pickup could only be bought with a rarer one. The beat moves 1.76 → 2.95 real minutes, still inside doc 06 §2.16's authored 1–3 minute band and now at its slow edge, which is where a $500 pickup belongs and where a $305 one did not.

**And `k` is fitted against a per-LEVEL series rather than a run average.** `pacing_guardrails.MODEL_NET_PER_HOUR_BY_CITY_LEVEL` is `[537.7, 658.8, 851.0, 956.4, 1017.2, 2755.4]` — flat from level 2 to 5 and then tripling — so the binding rung for the share ceiling is **level 5**, not the founding city and not the top. `184.30 × (1 + k·4) ≤ 0.40 × 1017.2` gives `k ≤ 0.302`; 0.25 leaves a seed's worth of margin and the ceiling shares by level are **34.3 / 35.0 / 32.5 / 33.7 / 36.2 / 15.0 %**. Balance gate 32 gains arm (d2) to hold exactly that.

**What this layer CANNOT be asked for.** The 2026-09-03 report asks for $15,000 a collection. At the measured delivered rate of 0.339 offers/gh that is **$5,090/gh = 1.85× the entire net income of a level-6 city**. No value of any constant in this table pays it and leaves a game underneath, so the number is ruled out of this layer and into one that fires about once a game-day (doc 93 §AQ1). `data/street.json` owns when an opportunity appears, where it stands and how long it lives; it owns no dollar, and `OpportunitySystem.FORBIDDEN_KEYS` refuses one that comes back — the same guard `IncidentCatalog` puts on `reward_base`.

**What this migration corrected, because it is the reason the migration was ranked.** Until Wave 15 this table read `petty_crime 180 / stray_animal 120 / abandoned_haul 150` and **nothing read it**: the live columns were in `data/street.json`, at the bands above, under kind names this table did not even use (`stray_animal` and `abandoned_haul` were never live kind ids). One feature, two price tables, and the balance gate was holding the dead one. The bands are MOVED, not retuned — every determinism baseline is bit-identical across the change, which is the check that says so.

**The ruled ratio holds, and its DENOMINATOR was what was wrong.** *A tapped crook is petty; a dispatched crime is the real one, and the ratio has to read as about half at a glance.* The placeholder stated that as `180 / 350 = 0.514` against `dispatch_payout_base[crime]` — but nobody is ever paid 350: doc 06 multiplies it by tier and by a speed bonus first, and the crime a player watches resolve is doc 06's own reference case, tier 3 answered on target, which pays `350 × 1.70 × 1.00 = $595`. Against that, the live mean bounty of **$305 is 0.513** — the ruled "about half" to three decimals, within 0.002 of the ratio the placeholder claimed. So nothing retuned in Wave 15; gate 32(b) compared a payout to a payout.

**RE-DERIVED AGAIN IN WAVE 19, and the denominator moved a second time** *(doc 93 §AQ1)*. Against the auto reference the re-priced crook is 507.50/595 = 0.853, which reads as "nearly the same" and would fail the bound. But the ruling's own word is *dispatched*, and a dispatched crime is one a **human** dispatched — RR-78 said as much when it invented the premium (*"the drawer is where the raise is"*). That reference pays `350 × 1.70 × 1.50 = $892.50`, and against it the crook is **0.569**. Gate 32(b) now holds two assertions because they are two claims: **(b1)** the street mean is under the AUTO reference (507.50 < 595, 15 % of margin), which is what stops the street layer being priced past the incident it is a lesser version of; and **(b2)** it is ≤ 0.60 of the MANUAL one, **at every city level**. Both sides carry a level curve now and the dispatch curve is the steeper by construction, so the ratio FALLS from 0.569 at level 1 to 0.320 at level 6 — the dispatched crime becomes more the real one as the city grows, not less.

**The income bounds, both re-derived** *(doc 92 §39.2 / §39.4)*:

- `STREET_MAX_RATE_PER_GAME_HOUR = 0.37` *(Wave 19; it was 0.70, and 0.45 before that)* is the ruled ceiling on the spawn table's un-rejected offer rate, `1 / target_interval_h`. It was once **0.45 against a table running at 0.667** — a contract violated by 48 % since the day it was written, because the table it constrained lived in a file no test could open. Gate 32(c) reads both files and holds one against the other. It is re-fitted with the rate trade above and at the same tightness the 0.70 had: 5.4 % above the shipped `1/2.85 = 0.3509`, refusing any `target_interval_h` under 2.703. **It is a tripwire, not a fit** — a wave that wants the offers back has to say out loud that it is re-pricing the bounty down as well, because the bands and the rate are one number seen twice.
- `STREET_CEILING_SHARE_MAX = 0.40` is the ruled ceiling on what the layer pays a player who collects **every** offer, as a share of the opening's own net. Measured: **$181.65/gh = 35.90 %** of $506.05/gh. Doc 92 §35.3 measured the same $181.65 at **57 %** and asked for a retune to 35–40 %; the money pass (RR-78/RR-79) delivered it from the other side by raising the founding net 337.05 → 506.05, so the share is inside the ruled band with no street dollar moving.
- `STREET_PLAYED_SHARE_BAND = [0.05, 0.20]` is the same question on a played 21-game-day arc, measured for the first time in Wave 15 by the `collector` agent (RR-82). The old band claimed 10–20 % "when played" and was never measured; the floor is loosened to 5 % because the share DECAYS across an arc by construction — street income grows 1.8× with city level while a curriculum city's net grows about three-fold.

An uncollected opportunity pays nothing and books nothing (`STREET_IDLE_SHARE = 0.0`), and gate 32(e) now measures that zero on an agent that never taps as well as asserting it from this file.

#### 2.5a State grants — the founding subsidy and the celebration *(report 98 RR-79)*

*A sub-part of §2.5 and deliberately not a `### 2.N` row of its own: a grant is non-tax revenue, which is what §2.5 is, and doc 91's completeness count is a count of `### 2.N` rows. This wave shipped no new row — it made an existing one honest.*

Two grants, one hourly and one lumpy. Both are dollars, so both are authored here.

**Founding assistance.** `FOUNDING_ASSISTANCE_PER_HOUR = 172`, tapering to zero over `FOUNDING_ASSISTANCE_DAYS = 7` on `share(day) = clamp(1 − day/7, 0, 1)`, evaluated on the settled game-day so the line steps once a day rather than drifting inside one.

172 is not a fit — it is §2.12's own founding `departments` ($96.00/gh) plus `fleet` ($76.00/gh). A founded city is handed three stations and eight vehicles by `data/starter_city.json` and starts paying full price for them in game-hour 1: **$172.00 of a $504.73/gh expense bill against $841.22 of gross, 34.1 % of everything the city spends before it has built anything.** That is the mechanical reason the opening read slow to a player, and it is why the state covers those two lines at founding and hands them back over the first game-week. Total paid over the window is `172 × 24 × (7+6+5+4+3+2+1)/7 = 172 × 24 × 4 = $16,512`, against a founding purse of $25,000 — the **discrete** daily step, not the continuous integral: the share is evaluated once per settled game-day, so the seven daily shares average `4/7 = 0.5714` and not 0.5. (A reader who integrates gets $14,448 and is $2,064 light. That gap is the difference between a line that steps at midnight and a line that drifts, and §2.5a chose the step.) Seven game-days is the curriculum's own opening: level 3 arrived on game-day 5.1–5.3 before this pass, so the taper covers levels 1–3 and is fully retired before level 4's incident wait begins.

It is a **published constant and not a fraction of the live bill**, deliberately. A subsidy that grew with the fleet would pay a player to buy vehicles, and a revenue line carrying an `M_exp` inside it would break §7 test 46's one-knob-per-line contract (doc 93 §N1).

**The taper announces itself (Wave 18).** Report 98 RR-148, 99-PA PA-32. RR-102
published `founding_assistance_days_left` into the settle snapshot and the budget
row spent it on its own label; the audit's finding was that a count on a screen
the player has to open is not a surface for the largest single mover of the
opening fortnight's net. `EconomySystem.settle_hour` now appends
**`assistance_stepped {day, per_hour, per_day, days_left, end_day, final}`** at
the first settled hour of each game-day the taper is live, plus one on the day it
retires — **eight per city** on the shipped constants, measured in doc 92 §52.1,
of which exactly one (`final`) is a doc 08 notification and the other seven are
doc 12 log rows. No dollar moves for it and no state is added: the step is
detected by asking `founding_assistance_per_hour` what *yesterday's* published
share was, so `state_hash()` cannot move.

**The celebration grant.** `LEVEL_UP_GRANT_BY_CITY_LEVEL = [0, 1000000, 2000000, 3000000, 4000000, 5000000, 6000000, 7000000]`, indexed by curriculum level, paid once per level for the life of a city, **for completing doc 09 §2.14's objectives for that rung** — not for crossing the city level.

> **The payment site moved in Wave 22** *(ruling 93 §AU6, report 98 §64 RR-191)*, and only the payment site: doc 93 §G1's `city_level = max(population_ladder, objectives_earned)` is untouched, and §2.10 layer 5's ERA still opens on that composed level. **A level is a permission and a permission may not depend on how it was reached; a grant is payment for a lesson, and the population backstop teaches none.** The distinction cost nothing at $2,500 a rung. At $1,000,000 it is the difference between a curriculum reward and a growth subsidy: paying on the composed level hands every scripted agent in doc 92's balance matrix — none of which can read a goals sheet — the curriculum's money. Doc 92 §61.12 has the table it moved. A player who ignores the goals sheet still gets the LEVEL, every unlock and every era; what they do not get is the fee for a lesson they did not take.

**RE-SCALED AGAIN in Wave 24** *(doc 92 §63.1, ruling 93 §AW1, report 98 §66 RR-197)*. The table paid **$5,890,000 across the curriculum** and now pays **$28,000,000**, and the reason is the player, 2026-09-04: *"For each level we need a much bigger boost … The first level of building up your city, you're going to at least get a million dollars or a few … **Start with one million dollars, and then at level seven we give them seven million.**"*

**Two anchors, one step, and no third number.** `grant(k) = k × $1,000,000`. A straight run of step $1,000,000 is the only shape that hits $1,000,000 at rung 1 and $7,000,000 at rung 7 with a single constant, so nothing between the player's two anchors is invented — **the table is the instruction, written as arithmetic**. The alternative through the same two points is a geometric run at `7^(1/6) = 1.3831`, and it was rejected because 1.3831 is a ratio nothing in this project publishes: Wave 22's 1.5 was `√2.25` and 2.25 is §2.11's own rung ratio, so it was *derived*, and a third invented number wearing a derivation is the failure mode doc 91 A91-D-120 already names.

**The anti-farm property survives the change of shape, and it is CHECKED rather than assumed** (ruling 93 §AW1). §AU1's guarantee was that the grant's share of the city it lands on falls every rung. On the linear ladder the rung-on-rung ratio is 2.00 / 1.50 / 1.33 / 1.25 / 1.20 / 1.17 against §2.11's city ratio of 2.25 — so from rung 2 up **the grant grows more slowly than the city**, the share falls by construction, and the fall *accelerates* (0.89 / 0.67 / 0.59 / 0.56 / 0.53 / 0.52 of the previous rung's share) where the geometric run's was flat at 0.61. **The linear ladder is the more anti-farm of the two.** `tests/test_city_services.gd` asserts the rule and the ratio bound, not seven literals.

**THE HALF-OF-THE-NEXT-CHAPTER RULE IS RETIRED.** Wave 22 anchored rung 6 at $325,000 because that was half of doc 09 §2.14.2 chapter 7's ask, and half of a purchase is a real constraint at that scale. Rung 6 is now **$6,000,000, which is 9.3× chapter 7's whole ask** of $644,370 (data centre L1 $180,000 + one upgrade step of each of the twelve `data/buildings.json` archetypes, $464,370). This doc says so in those words rather than restating a rule the numbers no longer obey. Prepaying the capstone **is** the instruction: *"plenty enough room to actually build everything and just play the game."*

**What each grant buys, at list price.** Two yardsticks: doc 09 §2.14.2's whole remaining shopping list, chapters 2–7 summed, is **$853,130**; the deepest single climb doc 02 has is a data centre L2 → L5 at **$5,306,213**.

| rung earned | pays | = the whole remaining curriculum | = the data-centre climb |
|---|---|---|---|
| 1 | **$1,000,000** | **1.17×** — *rung 1 alone pays for every lesson the curriculum will ever ask for, with $146,870 left over* | 19 % |
| 2 | **$2,000,000** | 2.34× | 38 % |
| 3 | **$3,000,000** | 3.52× | 57 % |
| 4 | **$4,000,000** | 4.69× | 75 % |
| 5 | **$5,000,000** | 5.86× | 94.2 % — *Wave 22's own rung-7 check, two rungs earlier* |
| 6 | **$6,000,000** | 7.03× | 1.13× — and 9.3× chapter 7's ask |
| 7 | **$7,000,000** | 8.21× | 1.32× — and 10.9× chapter 7's ask |

**The money is bounded by measurement, and the measurement found something else** (doc 92 §63.2–§63.3). On the unchanged agent matrix this table takes gate 18b — *a city may not outrun its own power* — from 5.99 % of building-time dark to **37.60 %** across three seeds. The cause is not copper: zero unattached buildings, zero unparented transformers, zero CRITICAL transformers, worst feeder at r = 0.25. **`supply_kw` never moves off 8,000 for the whole run**, because every founded city has one `power_facility` at doc 04 §2.2's L1 rating and nothing in `tools/playtest.gd` had ever bought or upgraded generation. The same wall is visible **at the fork**, in the last five game-days of gate 18b's own run. With the agent given the purchase it never made, the shipped reading is **4.61 / 20.88 / 0.55 %, mean 8.68 %**, against a fork mean of **12.16 %** — *the money leaves the city lighter than it found it*, and no ceiling in the gate file moves.

### 2.5a.1 Retroactive back-pay — the ledger, and what a returning city collects

**The second half of the player's instruction** *(2026-09-04; doc 92 §63.4, ruling 93 §AW3, report 98 §66 RR-199, save-section rung 10)*: *"if a player has already passed level one and was supposed to get a million dollars, you should be able to collect it for all of them AUTOMATICALLY — you should just check if you have received it, and if you haven't, then you get it. That way we can keep one city going for a while."*

**The operative word is *received*, so the record is DOLLARS and not a flag.** A city paid $2,500 for rung 1 under the original ladder has received rung 1; it is owed **$997,500**, not $1,000,000 and not nothing. `Treasury.grant_paid_by_level` is an array of dollars indexed exactly like the table above, persisted in the `treasury` block. Both payment sites write to it — `CitySim._pay_level_up_grant` (live, on `city_level_objectives_met`) and `CitySim._settle_grant_arrears` (on every load) — and both go through `Treasury.note_grant_paid`, which **only ever adds**.

Four properties, all of them consequences of that shape rather than guards:

1. **Idempotent across reloads.** The second load recomputes the same differences against a ledger that now records them, gets zero for every level, and emits nothing.
2. **Only the difference.** `max(0, table[k] − paid[k])`, per level.
3. **Never for a level the city has not EARNED.** The walk stops at `GoalSystem.earned_level`, which is monotone and sticky; the population backstop is not consulted, for the same reason §AU6 moved the live payment site off the composed level.
4. **Unfarmable for the life of the city.** A future table that pays LESS claws nothing back and re-pays nothing.

**The migration seed.** A save written before rung 11 carries no ledger (rung 10 is Wave 25's materials yard; the two waves each claimed v10 in their branches and the merge ordered them by landing), and the honest default is not zero — a city at curriculum level 5 *has* been paid, just not this much. `CitySim._v9_to_v10` therefore **marks rather than answers** (doc 08 §2.8's migrator may not open `data/`, and the restored city does not exist yet): it stamps the section version the body came from, and `_settle_grant_arrears` seeds the ledger from `grants.LEVEL_UP_GRANT_SUPERSEDED_BY_SAVE_VERSION`.

| row | table | paid on | exact for |
|---|---|---|---|
| `"0"` | `[0, 2500, 7000, 9000, 22500, 37000, 83000]` | the **composed** city level | every body at section version ≤ 8 |
| `"9"` | `[0, 45000, 65000, 95000, 145000, 215000, 325000, 5000000]` | the **curriculum** transition | a v9 body, as the element-wise **maximum** |

Row `"9"` is a maximum and is labelled as one: Wave 22 changed no *shape*, so a v9 body may have been written either side of its merge, and crediting the LARGER of the two tables that could have paid it makes double payment impossible rather than unlikely. The cost is bounded and published — a pre-Wave-22 v9 city is under-credited by at most **$487,000** on a **$15,000,000** settlement.

**The seed runs further than the arrears pay, and that is why the ledger holds dollars.** Below rung 9 the grant rode the composed level, so the seed runs to `max(city_level, earned_level)` while the arrears still pay out only to `earned_level`. A rung the population backstop already bought is therefore **recorded** (never back-paid) and **credited** (so the day the curriculum earns it, it pays the difference and not the face value).

**Back-pay opens no era.** §2.10 layer 5's relief allowance refreshes on a city level (doc 93 §AP4). Arrears settle rungs climbed in the past and the eras those rungs opened were opened then; `_settle_grant_arrears` never calls `note_era`.

**And it is visible.** One `level_up_grant_arrears_paid` event carrying the per-level breakdown, one toast — *"Back-pay collected — $14,922,000 for levels 1–5"* — and §2.21's payday chip flash. A silent credit of fourteen million dollars is indistinguishable from a bug.

**Measured on the real player city** (`slot_0/gen_000291.sav`, 2026-09-03, section version 8, game-day 166, `earned_level` 5, treasury **−$22,624**, austerity active, $569,547 of deferred liability): the seed is **$78,000**, the arrears are **$14,922,000** — $997,500 / $1,993,000 / $2,991,000 / $3,977,500 / $4,963,000, cell by cell the new table less the original ladder — and the city loads at **$14,899,376**. A second load pays **$0**. Doc 92 §63.5 has the run.

**One-shot per level per city is structural AND recorded.** `GoalSystem.earned_level` is monotone, its `done` set is sticky, and `_settle` emits exactly one `city_level_objectives_met` per rung it promotes through; since Wave 24 the ledger says so a second time, in dollars, in the save. **The one compounding surface is named rather than assumed:** `Treasury.note_era` resets §2.10 layer 5's relief allowance on the CITY-LEVEL transition (doc 93 §AP4), so a seventh rung is one more era and three more relief grants for the life of a city — +1 era, once, at the top of the ladder, behind the hardest level in the game, and monotone. Doc 92 §61.7 publishes that delta; the relief ladder itself is not re-fitted here.

**A one-off receipt is not an hourly ledger line.** §2.4 keeps one-off capital *spends* out of the recurring rate; the symmetric treatment for a one-off *receipt* is the same. The player sees it as a treasury event and a notification, and the budget panel's income statement stays an income statement.

**Street opportunities — the `street` line** *(Wave 15, doc 06 §2.16).* Doc 06's opportunity layer pays a **bounty per collection**: the player taps a crook the station missed, a loose animal or a dropped wallet, and `Treasury.credit(reward, &"street", …)` books it. It is **its own revenue line and its own lifetime counter** (`ledger_totals.lifetime_street`), and that is a ruling rather than a filing convenience: tax is a *rate on the city's value* and this is a *bounty on the player's attention*, so a ledger that folded them together would make the tax slider look like it moved when the player simply tapped more — and the budget sheet's entire job is to tell the player which lever did what. It is likewise not a `tariff`: nothing was delivered and nothing was metered.

Three properties this line has that no other revenue line has, all of them deliberate:

- **It is not a rate.** Nothing accrues per game-hour; a collection is a discrete credit at the moment of the tap. It therefore never enters `settle()`'s `revenue` argument, never scales by `M_rev`, and never moves `daily_gross_revenue` — so it cannot inflate the §2.10 credit limit, which would be a loop where tapping raises the ceiling on borrowing.
- **It is not offline income.** §2.11's offline rules do not reach it and its taper does not apply, because doc 08 §2.3 rule 9 makes the layer spawn nothing while the player is away. There is no accrual to taper.
- **Reward magnitude is THIS doc's** *(Wave 15, RR-81 — it was `data/street.json`'s until this wave, and the two files disagreed)*. The bands and the `× (1 + 0.20·(city_level − 1))` level scalar are §2.5's `city_services.street_payout` and `STREET_REWARD_CITY_LEVEL_K`; doc 06 keeps the SHAPE of an opportunity — which kinds exist, where they stand, how long they live, how police coverage bends the mix — and this doc owns every dollar in it, the same split RR-78 drew for dispatch.
- **And the lifetime counter finally counts** *(Wave 15, RR-85)*. `ledger_totals.lifetime_street` read **zero on every city since the layer shipped**: `Treasury.credit_city_service` credits under the CATEGORY `city_services` and the counter is keyed on the SOURCE, so nothing ever reached it. The cash was always right and the balance was always right; the named row answered zero to anyone who asked, which is worse than a missing row because it answers.

**The ceiling, measured and RULED** *(`tools/measure_street_yield.gd`, founding city, seeds 1337 / 4242 / 9001, 720 game-hours each = 2,160 gh, 1,225 offers; doc 92 §39.2):*

| | value |
|---|---|
| mean interval between offers | **1.763 gh** (= 1.76 real minutes at 1x) |
| mean bounty | **$320.29** |
| kind mix on the founding city | petty_crime **67.8 %** · lost_valuables **17.1 %** · loose_animal **15.1 %** |
| yield if EVERY offer is collected | **$181.65/gh**, $4,360/game-day |
| …against `STARTER_NET_PER_HOUR_EXACT` | **$506.05/gh** — so the ceiling is **35.90 %** of net |

Read that ceiling honestly: it is the yield of a player who taps **all 13.6 offers a game-day**, which costs 24 real minutes of uninterrupted attention and a lot of map-scrubbing. A realistic session collects a fraction of them.

**The Wave-14 version of this table divided by $319/gh and read 57 %**, and doc 92 §35.3 ruled that the ceiling belonged nearer 35–40 %. **It arrived there without a street dollar moving**: §2.5a's founding assistance and RR-78's retired `fines` line raised the founding net anchor from $337.05 to $506.05/gh in the same wave, and the same $181.65/gh is 35.90 % of it. The share was fixed by making the city richer rather than the street poorer — which is the better outcome, because §35.3's own two levers were `lost_valuables` and `target_interval_h`, and the second of those is the session beat the player actually asked for. `STREET_CEILING_SHARE_MAX = 0.40` publishes the top of the ruled band; balance gate 32(d) measures the ceiling on the live spawner and holds it there.

The crook share being two-thirds on the founding city is **not** a defect to tune away — it is doc 06 §2.16's coverage hook reading a starter city that has one police station, and it is the layer teaching what a second one would be for.

**And what the layer does on a PLAYED arc**, measured for the first time in Wave 15 by the `collector` agent (report 98 RR-86, doc 92 §39.5) — `curriculum` with one tap per game-minute and nothing else changed, over 21 game-days on the fine path. Street bounties land at the low end of `STREET_PLAYED_SHARE_BAND` and the share DECAYS across the run, because the layer grows 1.8× with city level while the city's own net grows about three-fold: the street stays a second income by construction, which is the property this doc wanted and could not previously check.

**Event revenue (post-MVP stub, stadium/zoo):** `event_revenue = event_base_gate[type] × attendance_factor × f_stability × f_power`.

**Repairs — this doc owns repair pricing outright (report 98 C-16).** There is exactly one repair price formula in the project:

```
repair_cost = round( capital_value(asset) × damage_fraction × REPAIR_COST_PER_CAPITAL (0.85) × M_repair[difficulty] )
```

Every other system supplies **only** `damage_fraction ∈ [0,1]` and calls `economy.repair_cost(asset, damage_fraction)`. Deleted in favour of this formula (a reader looking for them should look here):

| doc | deleted construct | becomes |
|---|---|---|
| 02 | `repair_cost = build_cost(L) × 0.55 × (100 − condition)/100` | `damage_fraction = 1 − condition` per its `[0,1]` condition scale (C-14) |
| 04 | `cost_frac_of_build` per failure type (burnout 0.35, rebuild 0.20, trip 0.005 …) | the same table re-read as `damage_fraction` per failure type |
| 05 | `base_cost[type] × (0.5 + severity)` | `damage_fraction = clamp(0.5 + severity, 0, 1)` per break type |
| 06 | `cost_materials = repair_material_base[type] × tier_peak` | `damage_fraction` per incident tier; materials are a repair, not a separate price |
| 07 | quoted repair totals ($42K / $310K) and `repair_cost_mult` | `damage_fraction` per hazard; the difficulty scalar is `M_repair` (C-17) |
| 10 | `ROAD_REPAIR_COST_BASE × (1 − condition)` at $600/tile | `damage_fraction = 1 − condition` on the RR-3 `[0,1]` road-condition scale; the price is §2.13(d) (report 98 RR-2) |

**`capital_value` by asset class.** The repair formula is one formula; what differs per class is what `capital_value` *means*:

- **Buildings** — §2.3's `capital_value(type, L) = build_cost_L1 × V(L)`.
- **Grid components** — their **§2.13(b) build cost at the current level** (grid components have no upgrade ladder in this doc's `V(L)` sense — they are replaced, not upgraded).

  **This bullet finally has a spender (Wave 25, report 98 §68 RR-206).** It has been published since C-16 and implemented as `CostCurves.capital_value_grid` since Wave 17, and until this wave **no command in the project charged it**: doc 04's components could burn out, and the only thing that put one back was doc 06 resolving the incident the failure filed. `CitySim.cmd_repair_grid_component` is the door, `CostCurves.repair_cost_grid(component, level, damage_fraction, m_repair)` is the accessor, and **not one number moves**: the price is this formula, the `damage_fraction` is doc 04 §2.6's own `FAILURE_DAMAGE` plus the wear, and the charge books under the existing `&"repair"` category — so the §2.5 `Repairs` ledger line carries it with no new row, no new key in `data/economy.json` and no new §2.13 entry. Worked, on the founding city: an L1 transformer burned out at condition 0.9979 is `500 × 0.3521 × 0.85 = ` **$150**; an L2 **$329**; an L3 **$838** (doc 92 §65.2).

  **A FEEDER cannot be priced through this bullet and the repair verb refuses one rather than pretending** (doc 91 A91-D-131). A line's §2.13(b) price is **per tile of its run**, not a `build_cost` array, so `capital_value_grid("feeder", 1)` answers **0** and any repair read off it would be free. Closing it is this doc's decision to make — does a feeder repair re-buy the whole run or the faulted span? — and is filed rather than guessed at in `sim/`.
- **Road tiles (new, report 98 RR-2)** — `build_price_per_tile × ROAD_REPAIR_CAPITAL_FRACTION (0.20)`, i.e. **STREET $360, AVENUE $1,040** against the §2.13(d) build prices of $1,800 / $5,200.

  A road is the only asset in the project that is repaired **in place, in layers**. Resurfacing re-buys the wearing course and the top of the base; it does not re-buy the excavation, the sub-base, the utility corridor or the right-of-way, which together dominate the build price. A flat 1.00 basis would price a full-depth reconstruction every time a tile lost condition, and §2.12 shows exactly how wrong that is (it books **$929/gh** of routine maintenance at doc 10's `c_day = 0.35` operating point — **$736/gh** even at the `c_day = 0` floor — against a starter city earning $839/gh gross). `ROAD_REPAIR_CAPITAL_FRACTION` is this doc's constant, sits in `data/economy.json`, and is the one lever available once RR-2 fixed the per-tile prices and doc 10 owns the decay rate.

  Consequences: a fully failed STREET tile repairs for `360 × 1.00 × 0.85 = $306`, a fully failed AVENUE for `1,040 × 1.00 × 0.85 = $884` (doc 10's deleted flat $600 sat between the two). A **`COLLAPSED`** tile is *not* a repair — doc 10 §2.12 requires a full rebuild, which is charged at the full §2.13(d) build price. Doc 10's worked example F (12 STREET tiles at condition 0.40) reprices from $4,320 to `12 × 360 × 0.60 × 0.85 = $2,203`.

Repairing 100% damage costs 85% of capital — cheaper than rebuilding, expensive enough that prevention wins. Doc 04's "replacement cost ×4" language for a destroyed transformer is therefore expressed as `damage_fraction = 1.0` plus a fresh purchase, never as a fourth price model.

**THE RESTORE — the capital end of the same family (new Wave 18; doc 02 §2.12, doc 92 §54, doc 93 §AN2).** A building the city has *lost* is not a repair that ran off the end of the scale; it is its own row, and this doc owns it outright:

```
restore_cost = round( capital_value(type, level_at_destruction) × RESTORE_COST_FRACTION (0.20) × M_repair[difficulty] )
```

| | |
|---|---|
| **key** | `data/economy.json.expenses.RESTORE_COST_FRACTION` |
| **accessor** | `CostCurves.restore_cost_building(type, level, m_repair)` — the only place a restore is priced (C-07) |
| **charged by** | `CitySim.cmd_restore_building`, under its **own ledger source `&"restore"`** |
| **level** | `level_at_destruction`, always. **No grace window, no demotion** — see doc 02 §2.12 |

**Why 0.20 and not doc 02's authored 0.60.** The old pair — `0.60 × build cost` inside 72 game-hours, full price and a demotion to L1 after — was never charged by anything, because until Wave 18 the transition had no caller at all (doc 91 A91-D-99). It met its first measurement on 2026-09-02 and failed it. The re-derivation (doc 92 §54) pins the fraction between two prices this section already publishes:

- **floor `0.17 × capital`** — the repair a *maintaining* player buys. Doc 92 §43.1's `balanced` agent repairs at condition 0.80, i.e. `0.20 damage × REPAIR_COST_PER_CAPITAL`. **A restore below this would make letting a building fall down cheaper than keeping it up**, at every level of every archetype, so `CostCurves` refuses such a table at boot and `tests/test_economy.gd` asserts the inequality per archetype per rung rather than asserting a constant.
- **ceiling `0.5525 × capital`** — the repair at doc 02 §2.6's auto-damage line (`0.65 × 0.85`), the deepest repair anyone sanely buys.

Measured consequence: the three ruins a neglected 45-day arc actually leaves standing — the starter city's power plant, substation and water plant — come back for **$24,000 against a $17,058 day's net (1.41×)**, where the authored 0.60 charged **$72,000 (4.22×)**.

**`M_repair`, not `M_build`**, because the price is read off `capital_value` like every other line of the repair family. **Not `&"construction"`**, because §2.10 layer 2's austerity blocks that category and a city that cannot restore its own power plant during an austerity cannot recover from one; **not `&"repair"`**, because folding a capital event into the routine line would make doc 92's repair burden appear to move when the player simply rebuilt. No `lifetime_restores` row ships — `Treasury.lifetime` is inside `state_hash()` and Wave 18 is a player-verb lane that moves no baseline (doc 91 A91-D-100).

**THE SALVAGE — the same family, running the other way (new Wave 19; doc 02 §2.12, doc 92 §57.2.2, doc 93 §AQ2, report 98 §60 RR-171).** The row under the restore in doc 02 §2.12's transition table, `destroyed → (removed)`, had a cost fraction and a crew-hours factor and no caller for seventeen waves. It ships as a CREDIT:

```
salvage_value = round( capital_value(type, level_at_destruction) × SALVAGE_FRACTION (0.15) )
```

| | |
|---|---|
| **key** | `data/economy.json.expenses.SALVAGE_FRACTION` |
| **accessor** | `CostCurves.salvage_value_building(type, level)` — the only place a ruin is valued (C-07) |
| **credited by** | `CitySim.cmd_salvage_building`, to `&"construction"` (doc 91 A91-D-108) |
| **level** | `level_at_destruction`, the same level the restore is priced at, so the panel's two numbers are about the same building |
| **no `M_repair`** | the difficulty presets scale what the city BUYS, never what it is paid |

**0.15 is a closed form, not a fit:** `DEMOLITION_REFUND_FRACTION (0.25) − doc 02 §2.12's own authored rubble-clearance fraction (0.10)`. A ruin is worth its scrap less the mess, and both halves of that sentence are numbers this project already published. Three bounds, all held as inequalities in `tests/test_salvage_building.gd` rather than as literals:

- **< 0.25**, or a wreck beats an intact demolition and letting stock fall is a strategy;
- **< `RESTORE_COST_FRACTION` 0.20**, or salvaging a ruin pays for restoring it and the two verbs are a loop instead of a decision — and the ratio `0.15/0.20 = 0.75` means **four ruins salvaged pay for three restored**, at every level and every archetype, because both fractions read the same `capital_value`;
- **> 0.05**, the net of the restore-then-demolish arbitrage that has existed since Wave 18 and that nobody had looked for (doc 91 A91-D-107). Salvage pays it immediately with no crew and no construction time, so the exploit is strictly dominated by the honest button beside it.

Worth, on shipped stock: house L1 **$180**, L3 **$915**, L5 **$5,693**; the starter city's power plant (capital $60,000 at L1) **$9,000**.

**Why the game pays for this at all.** The 2026-09-03 report is a city with every building destroyed and a negative balance, and every priced verb in the project asks that player for money they do not have. This is the one verb that runs the other way, and it is the only reason there is a pressable button on that panel.

### 2.5b Commissions — the third way the city gets paid (new Wave 19)

*(Doc 92 §57.3, doc 93 §AQ3, report 98 §60 RR-170. Data:
`data/contracts.json` for the work, `city_services.contract_payout` for the
money, `sim/economy/contract_board.gd` for the loop.)*

**The ask this section exists for**, 2026-09-03: *"any other fun ideas to collect
money in the game, something to actually DO to collect, other than tax
revenue"* — and, in the same breath, *"add a zero to that. 15,000 for one."*

**Why the $15,000 is here and not on the street layer.** §2.5's opportunity layer
delivers **0.339 offers per game-hour** (measured). A $15,000 pickup at that rate
is **$5,090/gh**, which is **1.85× the entire net income of a level-6 city**. No
value of any street constant pays the player's number and leaves a game
underneath it; a figure that size has to belong to something that fires about
once a game-day. This is that something.

**The loop, and where the money is in it.** A client posts a commission. The
player ACCEPTS one — the city holds exactly one at a time — which starts a
deadline in game-hours. They do the work with verbs the game already has. When
the target is met the commission goes `ready`, and the player CLAIMS it, **which
is the only step that moves a dollar**. Nothing on the board is money until it is
tapped, which is §2.5's own rule for a street bounty applied to a bigger one.

```
reward = round( (base + spread·u) × (1 + CONTRACT_REWARD_CITY_LEVEL_K·(city_level − 1)) )
```

`u ~ U[0,1)` is drawn once on the `contracts` stream at OFFER time and frozen
onto the row **with the city level**, so the card, the accept, the claim and a
save → load all quote the same dollars.

| tier | base | spread | mean | at level 6 (×3.00) |
|---|---:|---:|---:|---|
| `minor` | 900 | 300 | 1,050 | 2,700 – 3,600 |
| `standard` | 2,200 | 700 | 2,550 | 6,600 – 8,700 |
| `major` | 5,000 | 1,600 | 5,800 | **15,000 – 19,800** |

`CONTRACT_REWARD_CITY_LEVEL_K = 0.40` — the same shape §2.5 gives a street
bounty and a steeper slope, because a commission is gated by city level in a way
a kerb pickup is not. It is fitted to land the `major` band's **floor** exactly
on the player's own $15,000 at the top rung.

**The income bound, and it is ONE authored number in another file.**
`CONTRACT_CEILING_SHARE_MAX = 0.25` is the ruled share of the city's net this
layer may pay somebody who completes every commission offered. What ENFORCES it
is `data/contracts.json board.cooldown_h_after_claim = 30.0`: the city holds one
commission at a time, so income cannot exceed one payout per cooldown whatever
the player does. Measured against `MODEL_NET_PER_HOUR_BY_CITY_LEVEL`, the best
tier available at each rung lands at **6.5 / 18.1 / 18.0 / 19.6 / 21.7 / 21.0 %**
of net. Balance gate 32 arm (h) reads both files and holds one against the other,
exactly as arm (c) does for the street rate.

**Why 0.25 and not 0.40 like the street's.** *The two are added.* A player who
takes every street offer AND completes every commission is at `0.40 + 0.25 =
0.65` of net from active play, which leaves the passive city 61 % of the total.
That is the line: **above one half from any single active layer, or above two
thirds from all of them together, and the city stops being the thing being
played.**

**The ledger.** Credited through §2.5's settled `city_services` channel with
SOURCE `contracts`, beside `dispatch` and `street` — its own sub-row, because the
budget panel has to be able to say which of the three a player's money came from.
Deliberately NOT tax: tax is a rate on the city's value and this is a fee for a
job delivered, and a ledger that mixed them would make the tax slider look like
it moved when the player simply worked.

**What it does not do.** It does not run while the player is away (doc 08 §2.3
rule 9 — no offer appears, no deadline runs, no draw is taken), it charges
nothing to accept, and **a lapsed commission costs nothing**: no fee, no
stability, no reputation. A penalty for not finishing converts an opportunity
into a chore and taxes precisely the player who put the phone down. Ruled in
`data/contracts.json._no_penalty`, on the same terms as the street layer's
`expire_stability_delta: 0.0`, and re-opens on the same one condition.

**Emergency contractor.** Paying to bypass the construction/crew queue costs `CONTRACTOR_SURCHARGE = 1.80 ×` the job cost and completes in `CONTRACTOR_TIME_FRACTION = 0.35` of the normal duration. Available at any treasury ≥ 0. This is the *money-for-time* valve and it is deliberately bad value.

**Preventive maintenance.** Player action on any asset with condition ∈ [0.50, 0.99], costing `pm_cost = round( capital_value(asset) × PM_COST_FRACTION (0.06) )`.

Restores condition to 1.00, occupies one crew for `PM_CREW_HOURS = 2` gh. Below 0.50 it is a repair, not a PM. This is the cheapest possible resilience purchase and the first one the tutorial should teach.

**The repair BUDGET (Wave 18).** Report 98 RR-150, 99-PA PA-33.
`data/economy.json.building_repair` holds doc 02 §2.6's auto-repair policy dials,
and it is here rather than in `building_rules.json` for the reason C-07 gives:
**the cap is dollars.** It is a player *budget*, not a price — the pass it bounds
authors nothing and asks `cmd_repair_building(sim_id, true)` for every quote, the
identical preview the building panel's REPAIR button takes, so this section stays
the only place a repair is priced. `AUTO_REPAIR_DEFAULT_DAILY_CAP = 10000` is
derived from the measured civic bill and not chosen: **$226,852 over 45 game-days
= $5,041/game-day averaged, peaking at $7,893/game-day** in the heaviest bucket
(doc 92 §52.3), so the cap pays an ordinary day in full and spreads a catch-up
spike over two or three days. The block's *threshold* half authors no number at
all — it names doc 02 §2.6's own band keys, which `CitySim` resolves off the
building's stamped rules. Inert at the shipped default (`off`), so it enters no
balance gate.

### 2.6 Net-income presentation

HUD (doc 12) shows one number: **Net Income, per game-day**, computed as `net_display = EMA(net_hour × 24, alpha = 0.25)` each settlement to stop jitter.

Green if ≥ 0, amber if negative but treasury > 3 game-days of expense, red otherwise.

Tapping opens the **Budget** panel:

```
REVENUE                             EXPENSES
  Residential tax    +$18,400/d       Building maintenance  -$3,100/d
  Commercial tax     +$26,100/d       Police operations     -$1,870/d
  Industrial tax     +$11,200/d       Fire operations       -$2,160/d
  Technology tax     +$50,400/d       Utility crews         -$1,730/d
  Power tariff        +$4,010/d       Water services        -$1,100/d
  Water tariff          +$390/d       Public works          -$1,440/d
  City services       +$1,840/d       Grid O&M              -$2,980/d
  State assistance        +$0/d
                                      Generation fuel       -$2,020/d
                                      Vehicle fuel            -$620/d
                                      Road repair           -$4,760/d
  Gross             +$110,780/d       Debt service              -$0/d
                                      Total                -$21,780/d
  FOREGONE (outages, instability, damage)            -$14,930/d
  NET                                                +$74,070/d
  Resilience Index 47/100  ·  Cash buffer 4.6 game-days
```

**Foregone revenue** is the headline teaching device:
`foregone = R_potential_city - R_actual_city`, split by cause (power / water / road / stability / condition) using each factor's log-share of the total shortfall. Tapping a cause jumps the camera to the worst-contributing district.

**Resilience Index** — the number the §11.3 tradeoff is scored against:

```
RI = round( 100 × ( 0.30×grid_margin_score      // doc 04
                  + 0.20×grid_redundancy_score  // doc 04
                  + 0.15×water_margin_score     // doc 05
                  + 0.15×response_capacity_score// doc 06
                  + 0.10×condition_score        // mean condition, capital-weighted
                  + 0.10×cash_buffer_score ) )

cash_buffer_score = clamp( treasury / (5 × daily_gross_expense), 0, 1 )
```

### 2.7 Land purchase price (spec §7.2)

One land block = 16×16 tiles (constitution §6).

```
price = round_to_100(
          LAND_BASE
        × D_factor × T_factor × R_factor × W_factor
        × A_factor × P_factor × E_factor
        × escalation
        × M_land[difficulty] )

LAND_BASE = 9,000
```

| term | formula | notes |
|---|---|---|
| `D_factor` distance | `0.55 + 0.45 × exp(-(d-1)/DIST_DECAY)`, `DIST_DECAY = 4`, `d` = Chebyshev block distance from the city-centre block, min 1 | far land is *cheaper*; the cost lands in development instead |
| `T_factor` terrain | lookup: flat 1.00, gentle 1.08, hilly 1.30, steep 1.65, rocky 1.45, forest 1.05, marsh 0.80, island 1.90 | |
| `R_factor` risk | `1 - RISK_DISCOUNT × risk_index`, `RISK_DISCOUNT = 0.45`, `risk_index ∈ [0,1]` = doc 09's `env_risk_index` (ERI) | max-risk land is 55% price |
| `W_factor` waterfront | `1 + WATERFRONT_PREMIUM × (waterfront_edges / 4)`, `WATERFRONT_PREMIUM = 0.55` | |
| `A_factor` road access | `1 + ROAD_ADJ_PREMIUM × n`, `ROAD_ADJ_PREMIUM = 0.09`, `n` = existing arterial connections 0..4 (doc 09 block attribute) | block-level; **not** doc 10's `access_quality`, which is tile-level and feeds `f_road` only (C-61) |
| `P_factor` proximity | `1 + PROX_COEFF × prestige`, `PROX_COEFF = 0.35`, `prestige` = mean land-value index of adjacent owned blocks ∈[0,1] | |
| `E_factor` elevation | `1 + ELEV_COEFF × elevation_norm`, `ELEV_COEFF = 0.20` | high ground costs more, floods less |
| `escalation` | `min(1 + LAND_ESCALATION × max(0, blocks_owned - STARTER_BLOCKS_FREE), ESCALATION_CAP)`, `LAND_ESCALATION = 0.06`, `STARTER_BLOCKS_FREE = 9`, `ESCALATION_CAP = 4.0` | the growth brake |

`risk_index` is **hidden until surveyed**. Before the Survey phase the UI shows a *risk band* (Low / Moderate / High / Unknown) with ±0.20 uncertainty. Buying unsurveyed land is a real gamble, which is exactly spec §4 Pillar 2 ("cheap land may carry hidden environmental risk").

**Input bundle.** Doc 09's `LandPriceInputs` supplies `(d, dev_terrain, risk_index, waterfront_edges, n, prestige, elevation_norm)` per block, with `elevation_norm = elevation_class / 4` and column-A river-bank blocks reported at `elevation_norm = 0.00` (they sit at the water line regardless of their inland elevation class). This doc computes the price; doc 09 never restates it.

**Adjacency rule** (spec §7.1): a block must border owned land. Non-adjacent purchase is a post-MVP unlock (islands/satellite districts) at `NONADJACENT_PREMIUM = 1.6×`.

#### Worked example D — riverfront block, first purchase

d=2, flat, risk 0.15, 1 waterfront edge, 2 road connections, prestige 0.50, elevation 0.20, blocks_owned 9, standard.

```
D = 0.55 + 0.45 × e^(-0.25)            = 0.9004
T = 1.00
R = 1 - 0.45 × 0.15                    = 0.9325
W = 1 + 0.55 × 0.25                    = 1.1375
A = 1 + 0.09 × 2                       = 1.1800
P = 1 + 0.35 × 0.50                    = 1.1750
E = 1 + 0.20 × 0.20                    = 1.0400
escalation = 1 + 0.06 × max(0, 9-9)    = 1.0000

price = 9000 × 0.9004 × 1 × 0.9325 × 1.1375 × 1.18 × 1.175 × 1.04 = 12,389  →  $12,400
```

#### Worked example E — tidal-marsh block `B_0_6` (A7), the cheapest land on the board

*Rewritten against a block that actually exists (report 98 C-18). The previous version used `d = 5`; doc 09's world is 7×7 with a 3×3 core, so the maximum Chebyshev block distance is **3** and the cheapest block on the board is **$6,700**, not $3,900. The 7×7 world stands (doc 11's chunk budgets are sized for it); this example moves to fit it.*

Attributes from doc 09 §2.8.2: `B_0_6` (grid A7), ring 2, `dev_terrain = marsh`, **d = 3** (Chebyshev from the centre block `B_3_3`), **ERI 0.443**, waterfront_edges 3, arterial connections n = 0, prestige 0.00, `elevation_norm` 0.00 (river bank), flood risk 0.90 — the worst on the board. `blocks_owned = 9` (nothing bought yet beyond the starter core), standard difficulty.

```
D = 0.55 + 0.45 × e^(-(3-1)/4) = 0.55 + 0.45 × 0.606531 = 0.822939
T = 0.80                                    (marsh)
R = 1 - 0.45 × 0.443                        = 0.800650
W = 1 + 0.55 × (3/4)                        = 1.412500
A = 1 + 0.09 × 0                            = 1.000000
P = 1 + 0.35 × 0.00                         = 1.000000
E = 1 + 0.20 × 0.00                         = 1.000000
escalation = 1 + 0.06 × max(0, 9-9)         = 1.000000
M_land[standard]                            = 1.000000

9000 × 0.822939                             = 7,406.45
      × 0.80                                = 5,925.16
      × 0.800650                            = 4,743.98
      × 1.412500                            = 6,700.87   →  round_to_100  →  $6,700
```

**$6,700 vs $12,400** — the marsh block is 54% of the riverfront block's purchase price. Now look at what it costs to make it usable.

### 2.8 Land development phase costs (spec §7.3)

Six phases, sequential, each a construction project consuming crew time. Per report 98 G-2 the split is: **doc 02** owns the project record, the queue and progress; **doc 06** owns crews as dispatchable units; **doc 09** owns the phase → crew-type mapping. This doc owns only the money. Durations below are the pacing assumption doc 09/02 must hit, not an ownership claim.

```
phase_cost = round(
    PHASE_BASE[phase]
  × terrain_mult[phase][terrain]
  × (1 + DIST_DEV_COEFF[phase] × d)
  × access_mult[phase]
  × M_dev[difficulty] )
```

| # | phase | PHASE_BASE | DIST_DEV_COEFF | duration (gh) | effect |
|---|---|---|---|---|---|
| 1 | survey | 1,200 | 0.02 | 4 | reveals true `risk_index`, terrain, elevation |
| 2 | clearing | 3,000 | 0.03 | 8 | removes vegetation/debris |
| 3 | grading | 4,500 | 0.03 | 12 | levels buildable tiles |
| 4 | road_install | 7,500 | 0.16 | 14 | connects block to road graph |
| 5 | utility_corridor | 9,000 | 0.22 | 16 | power + water trunk to block edge |
| 6 | final_development | 5,000 | 0.05 | 6 | block becomes buildable |

`access_mult` applies to `road_install` only: `1 - 0.15 × n` (existing arterial connections). All other phases 1.0.

**terrain_mult** is an 8×6 lookup in `development.terrain_phase_mult` (§8). Its shape is the design point: terrain hits *grading* hardest (steep 3.40, rocky 2.80, marsh 2.60), water hits *roads* hardest (island 4.50), and forest hits *clearing* hardest (1.90). Flat land is 1.00 across the board.

#### Worked example F — total cost of ownership, D vs E

*Regenerated for the C-18 rewrite of example E: the marsh column moves from `d = 5` to `B_0_6`'s `d = 3`, so every `(1 + DIST_DEV_COEFF × d)` term changes. Generating formula, applied to every row:*

```
phase_cost = round( PHASE_BASE[phase] × terrain_mult[phase][terrain] × (1 + DIST_DEV_COEFF[phase] × d) × access_mult × M_dev )
access_mult = 1 - 0.15 × n   on road_install only, 1.00 elsewhere;   M_dev[standard] = 1.00
round() is half-up throughout this doc (final phase: 7,187.5 → 7,188)
terrain_mult[marsh] = [1.10, 1.60, 2.60, 1.90, 1.40, 1.25];   terrain_mult[flat] = [1.00 × 6]
```

| phase | riverfront `B_?` (d=2, flat, n=2) | cost | marsh `B_0_6` (d=3, marsh, n=0) | cost |
|---|---|---|---|---|
| survey | 1200 × 1.00 × 1.04 × 1.00 | 1,248 | 1200 × 1.10 × 1.06 × 1.00 | 1,399 |
| clearing | 3000 × 1.00 × 1.06 × 1.00 | 3,180 | 3000 × 1.60 × 1.09 × 1.00 | 5,232 |
| grading | 4500 × 1.00 × 1.06 × 1.00 | 4,770 | 4500 × 2.60 × 1.09 × 1.00 | 12,753 |
| road_install | 7500 × 1.00 × 1.32 × 0.70 | 6,930 | 7500 × 1.90 × 1.48 × 1.00 | 21,090 |
| utility_corridor | 9000 × 1.00 × 1.44 × 1.00 | 12,960 | 9000 × 1.40 × 1.66 × 1.00 | 20,916 |
| final | 5000 × 1.00 × 1.10 × 1.00 | 5,500 | 5000 × 1.25 × 1.15 × 1.00 | 7,188 |
| **development** | | **34,588** | | **68,578** |
| **+ purchase** | | **12,400** | | **6,700** |
| **all-in** | | **$46,988** | | **$75,278** |

Ratios: purchase **0.54×**, development **1.98×**, all-in **1.602×**. The block that cost **54% as much to buy** costs **60% more to own** — and it carries flood risk 0.90, the highest in the world. The inversion survives the move from `d = 5` to `d = 3` because it was always driven by `terrain_mult`, not by distance: marsh hits *grading* at 2.60 and *road_install* at 1.90 whatever the distance is.

The land purchase dialog must therefore display **Purchase / Est. development / Est. all-in** with the estimate banded ±15% before survey. This single UI requirement carries most of spec §7.2's design intent.

*(Test 11's threshold moves with the example: the invariant is now `all_in(E) ≥ 1.50 × all_in(D)`, model value 1.602 — see §7.)*

### 2.8b `land_works` — what the crews find (SOURCE `excavation`, Wave 25)

*Added 2026-09-04 from the player's own words: "when we open up a new plot of land … we will find materials from digging it out for the infrastructure. So potentially opening up a piece of land will give you resources and money back." Ruling 93 §AZ; measured in doc 92 §66; report 98 §69 RR-210.*

**The line.** `land_works` is a REVENUE line credited at the COMPLETION of three of §2.8's six phases. It is a direct credit through `Treasury.credit_city_service(amount, "excavation", …)` — the same door doc 06's dispatch payout and doc 06 §2.16's street collection use — so it lands in the balance the instant it is earned and is tallied on §2.5's settled `city_services` line at its own sub-grain until the hour settles.

| | |
|---|---|
| **line** | `land_works` |
| **SOURCE** | `excavation` — `Treasury.hour_city_services["excavation"]`, `ledger_totals.lifetime_excavation` |
| **paid at** | the completion of `clearing`, `grading`, `utility_corridor` |
| **accessor** | `EconomySystem.works_yield_value(phase, terrain, d, n, M_dev, roll, bonus)` — the only place a find is priced (C-07) |
| **credited by** | `CitySim._credit_land_works`, the coordinator, because `DevelopmentController` may not touch money (its own header) |
| **stream** | `land_works`, the tenth named stream (constitution §5) — two draws per credited phase, band then bonus, in that fixed order |
| **receipt** | `land_works_find` on the bus → a toast (`ui/land_works_model.gd`), an event-log row (`data/ui.json.event_log.events`), a `cash` cue (`data/audio.json`), and the land panel's `Recovered so far` |

**The prices.** Each band is a FRACTION OF THAT PHASE'S OWN COST, drawn uniformly on the `land_works` stream:

| phase | material | low | high | keeps material? |
|---|---|---|---|---|
| clearing | `timber` | 0.08 | 0.18 | no — timber is not road base |
| grading | `aggregate` | 0.06 | 0.14 | yes |
| utility_corridor | `spoil` | 0.05 | 0.11 | yes |

with a **12 % chance** on `utility_corridor` alone of turning up `copper` instead — an abandoned main — at **×2.00**. A trench is the only one of the three digs that goes deep enough for that to be true.

**There is no terrain table and that is the design.** §2.8's `terrain_phase_mult` already says clearing a forest costs 1.90× and grading rock 2.80×, so a forest block yields 1.90× the timber and a rocky one 2.80× the aggregate *out of a table this doc already publishes* — with nothing new to keep in step. `M_dev` is inside the phase cost for the same reason: a harder difficulty charges more AND hands proportionally more back, and the ratio is difficulty-invariant.

**The ceiling — `WORKS_YIELD_CEILING = 0.10`.** A block's CUMULATIVE yield, cash and kept material together, is clamped to `0.10 × its own six-phase development bill`. `LandBlock.works_yield_total` is persisted (doc 08 §2.8 rung 10) precisely so a save-and-reload cannot pay the ceiling twice. Three bounds, all held as inequalities in `tests/test_land_works.gd` rather than as literals, and all measured in doc 92 §66.3:

- **< the smallest `road_install` share of a development bill on any terrain at any distance (0.2375, rocky at d = 0)** — the find may never pay for the road it was dug for, or the infrastructure builds itself;
- **< `SALVAGE_FRACTION` 0.15** — the ground you dig may never be worth more than a whole building taken apart;
- **it binds only on the bonus tail.** The maximum draw with no bonus is 8.45 % of the bill (rocky, d = 0); with the `copper` bonus on top of a maximum roll it reaches 12.23 %. So the clamp can only ever bite where a clamp should: on the best possible roll of the rarest event.

Measured over three cities × three blocks (doc 92 §66.4): every block recovered **5.49 %–7.27 %** of its own bill, and `land_works` paid **$207.49 a game-day** — **2.7 %** of the founding city's $319/gh net. That is "money back", which is what was asked for, and not profit.

**The materials yard** (ruling 93 §AZ3) is ONE persisted integer for the whole city, `CitySim.works_stockpile`. The rows flagged as keeping material bank `STOCKPILE_SHARE` of a find instead of selling it; the player is paid the rest in cash, and when the yard is full the part that will not fit is paid as cash instead, so nothing is ever lost.

| knob | value | derivation |
|---|---|---|
| `STOCKPILE_SHARE` | **0.34** | `LandBlock.road_tiles_est()` puts 0.34 of a block's usable ground under road; 0.34 of what comes out of the ground is what goes back into it |
| `STOCKPILE_MAX_OFFSET_FRACTION` | **0.25** | §2.5's own published `DEMOLITION_REFUND_FRACTION`, reused as "what a thing taken apart is worth against the next one" |
| `STOCKPILE_CAP` | **$4,125** | `0.25 × (road_install + utility_corridor at flat, d = 0) = 0.25 × 16,500`. The yard is a WORKING STOCK, not a bank: it holds at most what one phase may ever take off |

The yard pays towards `road_install` and `utility_corridor` and nothing else — the two phases the dug-out material is *for* — up to a quarter of that phase's invoice. Because the offset is capped at a quarter, the net can never reach zero: **the yard shortens a bill and never replaces one.** Every draw is announced on `land_works_stockpile_spent` and carries its own event-log row, because an invoice that silently got smaller is the one thing a ledger may never do.

### 2.9 Difficulty — one file, one schema, one loader (spec §35, report 98 C-17)

**This doc owns `data/difficulty.json` and every difficulty knob in the project lives in it.** Before C-17 the knobs were scattered: this doc held the economic multipliers, doc 07 held pressure knobs *plus* a `repair_cost_mult` that duplicated `M_repair`, doc 06 held `difficulty.escalation_mult`, doc 08 held `difficulty_offline_mult`. That is now one file with four authored sections:

| section | authored by | contents |
|---|---|---|
| `economic` | **03 (this doc)** | `M_rev`, `M_exp`, `M_land`, `M_dev`, `M_build`, `M_repair`, `starting_treasury`, `OFF_TAU_HOURS`, `offline_damage_cap_fraction`, `REV_FLOOR_FRACTION`, `CREDIT_APR_PER_GAME_DAY`, `relief_grants_per_era` |
| `pressure` | 07 | `tp_rate_mult`, `cooldown_mult`, `severity_mult`, `warning_lead_mult` |
| `escalation` | 06 | `escalation_mult`, `OFFLINE_RESPONSE_TIME_MULT` |
| `offline` | 08 | `difficulty_offline_mult` and any band-gating knobs |

**Rules of the file (this doc enforces them, the owners fill the rows):**

1. Exactly four preset keys — `casual`, `standard`, `hard`, `crisis` — and every section must define a row for all four. A missing row is a load error, not a default.
2. **No difficulty scalar may exist outside this file.** Doc 07's `repair_cost_mult` is deleted; repair difficulty is `M_repair` and nothing else.
3. One loader, `sim/economy/difficulty.gd`, exposes `Difficulty.value(section, key) -> Variant`. Systems read through it; nobody parses the file twice. *(This rule said `Difficulty.get(…)` until 2026-08-20. It cannot ship under that name: `get` is `Object.get(StringName) -> Variant` and GDScript refuses a method that redeclares a native one with a different signature. The rule is about there being exactly ONE read path — there is; only the spelling moved.)*
4. Schema in §3.4, contents in §8.

Difficulty changes *pressure*, not health bars.

| knob | casual | standard | hard | crisis |
|---|---|---|---|---|
| `M_rev` **tax** revenue | 1.15 | 1.00 | 0.92 | 0.85 |
| `M_exp` recurring expense **(seven lines — see §2.4)** | 0.85 | 1.00 | 1.12 | 1.25 |
| `M_land` land price | 0.85 | 1.00 | 1.15 | 1.30 |
| `M_dev` development cost | 0.85 | 1.00 | 1.15 | 1.30 |
| `M_build` build/upgrade cost | 0.90 | 1.00 | 1.10 | 1.20 |
| `M_repair` repair cost **(and `E_roads_repair`'s accrual — §2.4)** | 0.70 | 1.00 | 1.35 | 1.60 |
| `starting_treasury` | 35,000 | 25,000 | 18,000 | 12,000 |
| `OFF_TAU` offline taper | 120 | 90 | 75 | 60 |
| `offline_damage_cap_fraction` | 0.10 | 0.20 | 0.30 | 0.45 |
| `REV_FLOOR_FRACTION` | 0.25 | 0.18 | 0.14 | 0.10 |
| `CREDIT_APR_PER_GAME_DAY` | 0.004 | 0.008 | 0.014 | 0.022 |
| `relief_grants_per_era` | 4 | 3 | 2 | 0 |

(The rows above are the `economic` section of `data/difficulty.json`; the other three sections are listed in §8.)

**Two rows carry a scope, and the scope is part of the number** *(Wave 12 — doc 93 §N1/§N2, measured in doc 92 §32)*:

- **`M_rev` multiplies the TAX line only** — §2.2's per-building formula and §2.2's revenue floor. §2.5's power tariff, water tariff, city services and state assistance are outside it, deliberately: `delivered_mwh` 1.5 is still §9 item 6b's *held* metering constant and a difficulty knob on a placeholder is a difficulty knob on nothing, and the other three are §2.5 lines that §2.2's two `M_rev` formulas do not reach. *(The `fines 3/350` half of the held pair was retired in Wave 15 — report 98 RR-78 — and its replacement stays outside `M_rev` on the §2.5 argument rather than on the placeholder one.)* Non-tax revenue is **11.82 % of founding gross**, so the row's advertised effect and its measured effect differ by that share:

  | preset | advertised | **measured on GROSS revenue** |
  |---|---|---|
  | `casual` | +15 % | **+13.23 %** |
  | `hard` | −8 % | **−7.05 %** |
  | `crisis` | −15 % | **−13.23 %** |

  The advertised column is what the knob does to the line it multiplies; the measured column is what the player's ledger shows. Both are printed because a preset table that quotes only the first is the reason doc 92 §29.2(a) had to solve for the split algebraically.

- **`M_exp` multiplies SEVEN of the eight recurring lines.** `E_roads_repair` is the eighth and takes `M_repair` instead — one knob per line, never two (§2.4).

**The preset is chosen when a city is FOUNDED, and a city keeps it for life (doc 93 §K1).** This paragraph used to say the opposite — *"Difficulty may be raised at any time. Lowering it is permitted at any time but sets `save.assisted = true` permanently (excludes the city from any future leaderboard, spec §35)"* — and it is replaced rather than annotated, because the two rules cannot both be true of one save. The ruling and its three reasons are in doc 93 §K1; the short version is that `save.assisted` was a leaderboard flag for a leaderboard this game does not have, and a mid-city multiplier change is a re-pricing of a city the player has already paid for. There is no `cmd_set_difficulty`, no settings control and no `assisted` field.

> **IMPLEMENTATION STATUS — this section SHIPS (2026-08-20; doc 91 A91-D-19 closed).**
>
> | rule | what ships |
> |---|---|
> | one file | `data/difficulty.json` — four sections × four presets, the tables above and in §8.2 verbatim |
> | one loader | `sim/economy/difficulty.gd` (`class_name Difficulty`), the only reader of that file |
> | one read path | `Difficulty.value(section, key)` — **not** `get`, see §3.4 rule 5 |
> | no scalar outside it | `data/director.json`'s `_difficulty_fallback` mirror and `data/incidents.json`'s `difficulty_escalation` block are **deleted**, and `DirectorTables` / `IncidentCatalog` now REFUSE a file that grows one back. `OFF_TAU_HOURS` left `data/economy.json.offline` on the same day |
> | resolved at boot | `CitySim.boot(…, difficulty_preset)` loads and pins it before the treasury is constructed, because the founding balance is one of its twelve knobs |
> | chosen at founding | `CitySim.found_with_difficulty(preset)`, valid only at `tick_index == 0`; the front door's chip (doc 12, `ui/title_screen.gd`) is the surface, and S9 shows it read-only |
> | part of the city | doc 08 §2.8 city section **v6**; the body names the preset in the `director` section it has always named it in, and `_v5_to_v6` defaults a body that does not |
>
> **The default preset reproduces the pre-difficulty binary bit-for-bit.** `tools/profile_sim.gd --hash-only` reports `18e70625e633c254…` / `4c3c52cdb4c5a3cc…` on the founding city and `d6b2509c179987d3…` / `bf8dc7282758843b…` on `bench_city` before and after, and doc 92 §29.1's control matrix is byte-identical to §27.6's post-fix table. Non-default presets move the hashes, which is their job.
>
> **Two rows of §2.9's own table are still SEAMS**, and they are named rather than quietly dropped: `escalation.OFFLINE_RESPONSE_TIME_MULT` (doc 06's offline auto-response path does not exist yet) and `offline.difficulty_offline_mult` (doc 08 §2.3's band gating does not read it yet). Both are authored, validated and reachable through the loader; nothing reads them. `economic.offline_damage_cap_fraction` is in the same position — `EconomySystem.offline_oneoff_cap()` takes it as an argument and no live caller passes it yet.

### 2.10 Anti-bankruptcy floor (spec §37)

**There is no game over and no paid rescue.** Recovery is a five-layer ladder, all free.

**Layer 1 — Revenue floor.** §2.2: city revenue never drops below `REV_FLOOR_FRACTION` of potential. A totally dark, rioting city still funds a slow rebuild.

**Layer 2 — Austerity Mode.** Auto-enters when `treasury < 0`, auto-exits at `treasury ≥ 0.5 × daily_gross_expense`. All recurring expenses × `AUSTERITY_EXPENSE_MULT = 0.55`; condition decay × `AUSTERITY_DECAY_MULT = 2.5` (doc 02/07); vehicle breakdown chance × 2.0 (doc 06); new construction starts, land purchase and vehicle purchase blocked, but **in-flight projects continue** — never strand a half-built tower. Persistent HUD banner: *"AUSTERITY — deferred maintenance, services degraded."*

**Layer 3 — Emergency Credit Line.** Automatic overdraft, no application: `credit_limit = max( CREDIT_LIMIT_FLOOR (20,000), CREDIT_LIMIT_DAYS (6) × daily_gross_revenue )`, `interest_per_hour = round( |min(0, treasury)| × CREDIT_APR_PER_GAME_DAY / 24 )`.

Interest is booked as `E_debt`. Rising debt service is visible in the budget panel, so the spiral is legible before it bites.

**Layer 4 — Deferred liability hard floor.** Treasury cannot go below `-credit_limit`. Any expense that would breach it is moved into `deferred_liability` instead. Deferred liabilities accrue **no interest**; every $1,000 deferred applies `DEFERRED_CONDITION_PENALTY = 0.004` condition loss to a randomly chosen asset (RNG stream `misc`, capital-weighted); they are repaid automatically at `DEFERRED_REPAY_FRACTION = 0.35` of positive net income per hour, before the treasury sees it.

So the punishment for insolvency is a **decaying city**, never a locked one.

**Layer 5 — State Emergency Assistance.** A free, automatic grant (spec §15.2 already names state/national assistance as a fiction hook). Triggers when **all** of `treasury ≤ -0.5 × credit_limit`, 24-gh trailing average net income ≤ 0, `game_hours_since_last_grant ≥ RELIEF_COOLDOWN_HOURS (120)`, and `grants_used < relief_grants_per_era[difficulty]` hold. Amount (**amended Wave 19**, doc 93 §AP4, measured in doc 92 §56.5):

```
grant = clamp( round( max( RELIEF_DAYS_OF_REVENUE × daily_gross_revenue,
                           max( 0, RELIEF_DAMAGE_FRACTION × outstanding_restore_cost
                                   - relief_era_paid ) ) ),
               RELIEF_MIN (8,000), RELIEF_MAX (250,000) )

relief_era_paid += grant          # reset by note_era, with the allowance
```

The revenue term alone was measured on the city **after** the loss, so the worse the catastrophe the smaller the relief: a standard city of 251 ruins carrying a **$238,280** restore bill was offered **$8,000** — `RELIEF_MIN` — on every preset. `outstanding_restore_cost` is `CostCurves.restore_cost_building` summed over the city's actual ruins at its own `M_repair`, i.e. the identical call `cmd_restore_building` charges, so C-07 keeps one price and the grant can never disagree with the invoice. `RELIEF_DAMAGE_FRACTION = 0.35` is `DEFERRED_REPAY_FRACTION` adopted, not invented. **It is not farmable, and the argument is an inequality: 0.35 < 1**, so the grant never covers the bill it is measured against and wrecking your own stock always loses money; the bill also shrinks as it is spent, so relief decays back to the revenue term as the city recovers.

> **THE INEQUALITY WAS TRUE PER GRANT AND FALSE PER ERA, and Wave 21 fixed it**
> (doc 93 §AS4, measured in doc 92 §60.4). `relief_grants_per_era` is 3 on
> standard, and **3 × 0.35 = 1.05**. The shipped build paid the 2026-09-03
> player **$306,233 against a $296,438 restore bill — 1.033×** — and a unit
> control driving three grants against a fixed bill returns **$311,259**, which
> is 1.050× to the dollar. `Treasury.relief_era_paid` — dollars, persisted,
> reset by `note_era` with the allowance it belongs to — subtracts what the era
> has already handed over from the DAMAGE term, so an era's damage-side relief
> sums to at most `RELIEF_DAMAGE_FRACTION × (the largest bill any grant in it
> was measured against)`. **No new constant is authored**: the cap is the
> fraction that was already here, applied to the era instead of to the grant.
> The **revenue term stays outside it** — it is measured on what the city EARNS
> rather than on what it lost, and netting it would punish a city for having
> spent its last grant well — and so does `RELIEF_MIN`, which is the floor this
> layer guarantees every grant. A save written before the cap carries no counter
> and loads at 0, which is what a city that has taken no grant means.


**An era is a CITY LEVEL** (Wave 19, doc 91 A91-D-103). `relief_grants_per_era` carried that word from this table's first draft and nothing in the project ever defined it, so `relief_grants_used` — incremented and persisted but reset by nothing — made the allowance a *lifetime* three. `Treasury.note_era(city_level)` resets it on the same transition that pays `LEVEL_UP_GRANT_BY_CITY_LEVEL`: already tracked, already persisted, monotone, and therefore unfarmable.

Presented as a news beat, not a shop prompt. **Crisis difficulty has zero grants** — that is what "survival mode" means, and it is the only place the safety net is absent.

**Player-driven rescue tools** (always available, no difficulty gate): demolish a building for `0.25 × capital_value`; sell a vehicle for `0.40 × purchase`; mothball a station (upkeep → 15%, reactivation `0.60 × upkeep × 24`); sell undeveloped land for `LAND_RESALE_FRACTION = 0.55 × current price`; raise the tax rate for up to ×1.778 revenue at the doc-09 happiness/growth cost.

**Monetization boundary (spec §37.2).** No layer above is purchasable, accelerable by IAP, or ad-gated. The single permitted ad interaction is reducing `RELIEF_COOLDOWN_HOURS` by 24 gh, once per cooldown, via an optional rewarded ad. Everything else in the ladder is unconditional.

### 2.11 Offline income rules (spec §21, constitution §4, report 98 C-19/C-20)

Offline uses the **same** `EconomySystem.tick_hour()` as online play (constitution §4 forbids a parallel implementation). The only difference is a per-hour multiplier that equals 1.0 while online.

**One channel, one curve, split by concern (C-20).** Doc 08 owns the *mechanism*: `OfflinePolicy.band_for(hour_index)` on `TimeContext` is the only path by which any system learns it is offline, and it carries `incident_mult`, `damage_mult`, `director_allowed` and `yield_mult`. This doc owns the *economic curve* and **populates `band.yield_mult`** — doc 08's flat 1.00 / 0.60 two-band yield rows are deleted, because only this doc pacing-tested the taper (guardrail G4).

```
yield_mult(h) = 1.0                               if h ≤ OFF_FULL
              = exp( -(h - OFF_FULL) / OFF_TAU )   if h > OFF_FULL
OFF_FULL = 4 game-hours,  OFF_TAU = 90 (standard)
h = ctx.catchup_index      # 0-based coarse-hour index within the current catch-up run
```

**This doc keeps no absence counter.** The former `absence_hours_elapsed` field is **deleted** from the `economy` save section and `OfflineYield` reads `ctx.catchup_index` instead. Absence detection, the minimum-absence threshold and the session-start reset are doc 08's mechanism, not this doc's state — a reader looking for `SESSION_START_SECONDS` or `OFFLINE_MIN_MINUTES` should look in doc 08's `data/offline.json`.

The multiplier scales **revenue and recurring expenses identically**, so net income stays coherent and a loss-making city is not punished harder for being closed.

Integrating gives effective earning hours per absence: `E(H) = H` for `H ≤ 4`, else `E(H) = OFF_FULL + OFF_TAU × (1 - e^(-(H-4)/OFF_TAU))`.

The absence itself is capped at **12 real hours = 720 game-hours** by doc 01's `data/time.json` (report 98 C-19); surplus is discarded and reported, never banked. The table is therefore stated to the cap, not beyond it:

| real time away | 5 min | 20 min | 1 h | 4 h | 8 h | **12 h (cap)** |
|---|---|---|---|---|---|---|
| game-hours H | 5 | 20 | 60 | 240 | 480 | **720** |
| **effective earning hours E(H)** | 4.99 | 18.66 | 45.69 | 87.46 | 93.55 | **93.97** |

```
E(5)   = 4 + 90 × (1 - e^(-1/90))    = 4 + 90 × 0.011050 =  4.99
E(20)  = 4 + 90 × (1 - e^(-16/90))   = 4 + 90 × 0.162874 = 18.66
E(60)  = 4 + 90 × (1 - e^(-56/90))   = 4 + 90 × 0.463270 = 45.69
E(240) = 4 + 90 × (1 - e^(-236/90))  = 4 + 90 × 0.927374 = 87.46
E(480) = 4 + 90 × (1 - e^(-476/90))  = 4 + 90 × 0.994946 = 93.55
E(720) = 4 + 90 × (1 - e^(-716/90))  = 4 + 90 × 0.999650 = 93.97
```

*(The previously tabled 19.0 at H=20 and 51.6 at H=60 did not satisfy the stated integral; they are corrected above. E(240), E(480) and the ceiling were always right.)*

**Hard ceiling ≈ 94 game-hours (~3.9 game-days) of income per absence**, reached after roughly 6 real hours away — well inside the 12-hour cap, so the cap and the taper never fight. Returning daily is rewarded; leaving the game closed is not a strategy.

**Not tapered:** construction progress, repair progress, crew work, development phases, condition decay, population change, and weather/incident generation. Work the player already paid for completes at full rate. Only *money flow* tapers.

**Offline response penalty.** Doc 06 resolves offline incidents under the player's auto-response policies (spec §21.3) with `OFFLINE_RESPONSE_TIME_MULT` = casual 1.2 / standard 1.6 / hard 1.9 / crisis 2.2. Longer resolution ⇒ more foregone revenue ⇒ the fragile city visibly earns less while you sleep. This is the intended hook for checking in.

**Offline damage cap.** Total one-off offline costs (repairs + auto-dispatched contractor spend) in a single absence are capped at `offline_oneoff_cap = round( offline_damage_cap_fraction × (treasury_at_close + offline_net_revenue) )`.

Damage beyond the cap is **not billed** — the assets simply remain broken and appear in the WHILE YOU WERE AWAY report as *"Unrepaired: 3 transformers, 1 water main."* The player pays consciously, on return, with full information.

**Rule: offline never bankrupts you. It leaves you a mess.**

**Minimum absence.** Owned by doc 08 (C-20) along with the rest of the absence mechanism; this doc's `OFFLINE_MIN_MINUTES` constant is deleted.

### 2.12 Treasury pacing — the first 10 real hours

Modelled at standard difficulty, competent-but-not-optimal play, across a 7-calendar-day arc containing 600 real minutes (= 600 game-hours = 25 game-days) of active play. **1 real minute = 1 game-hour.**

**Starting conditions.** Treasury $25,000. Doc 09's starter city must produce **gross base tax of $686/gh** (this model assumes 18 houses L1, 5 stores L1, 3 apartments L1, 1 office L1, plus police, fire, gas plant, substation, water plant, construction yard — the mix report 98 C-11 restored, which evaluates exactly: `18×12 + 5×26 + 3×70 + 1×130 = 216 + 130 + 210 + 130 = 686`).

**Restated starter ledger — ROUND 2 (report 98 RR-2 / RR-6), re-priced in ROUND 3 (RR-13 / RR-16 / RR-18).** Round 3 moves exactly one line — (f) routine road repair, onto doc 10's `c_day = 0.35` operating point — labels (b)'s `water_works` as staffing-only, and shows the net from unrounded components; lines (a) and (c)–(e) are unchanged. Round 1 (C-12 / R-04) moved one line — the electrical plant — and said in terms "every other line is unchanged". The verification pass (96 F-6/F-7, 97 F-02/F-03/F-04/F-06) showed that four more lines were stale and one was missing entirely. **All of them move here, at once, each derived from the owning doc's published inventory rather than assumed.**

**(a) Gross tax — $617 → $740/gh.** Round 1 applied an assumed aggregate multiplier of **0.90** to the $686 base. Doc 09 now owns stability and happiness (G-1) and publishes its own t0 values: `f_stability = 0.25 + 0.75 × 0.9475^0.70 = ` **0.9722** (on `city_stability` 0.9475) and `f_happiness = 1.0 + 0.50 × (82 − 60)/100 = ` **1.110** (on `H` = 82.15). At founding every other multiplier is nominal — `occ` 1.000 (doc 09: every authored building is past its 36 gh ramp), `f_power` 1.000, `f_water` 1.000, `f_road` 1.000 (every core block is AVENUE-fronted), `f_condition` 1.000 (`C` = 1.00), `tax_policy_factor` 1.000 (`r` = 0.09), `M_rev` 1.000.

```
aggregate = 0.9722 × 1.110 = 1.07914          (replaces the assumed 0.90)
tax       = 686 × 1.07914 = 740.29   ->   $740/gh
```

*A note on the 0.9722, because §2.2 is strict that `f_stability` reads the **building's own district**, not the city aggregate.* RR-6 mandates doc 09's published 0.972, which is `f_stability(city_stability 0.9475)`. Evaluated properly — per district, weighted by that district's share of the $686 — the answer is `(296×0.96596 + 390×0.98630)/686 = ` **0.97752** (Northgate `S` 0.9358 carries $296/gh of tax, the three `S` 0.9740 districts carry $390/gh), giving `aggregate 1.08505` and `tax $744.34`. The two differ by **0.55 %**, well inside the ±5 % anchor gate, because `S^0.70` is nearly linear over `[0.93, 0.98]`. **This doc uses the ruled 0.972** and records the refinement here rather than quietly banking $4/gh; if doc 09 later publishes a tax-weighted aggregate the line moves to $744 and the pacing `K` to **1.36378** (report 98 RR-18 — the 1.36285 printed here in Round 2 was arithmetically wrong).

*The re-derivation, shown (RR-18).* `K` is `(gross revenue − non-road expense) / net_r1`, evaluated on the per-district tax instead of the ruled one:

```
f_stability (tax-weighted) = (296 x 0.96596 + 390 x 0.98630) / 686
                           = (285.924 + 384.657) / 686 = 670.581 / 686 = 0.977524
aggregate                  = 0.977524 x 1.110               = 1.085051
tax                        = 686 x 1.085051                 = 744.345
gross                      = 744.345 + 93 + 3.058 + 3       = 843.403
K_per_district             = (843.403 - 334.706) / 373      = 508.697 / 373 = 1.363799
```

**Published value: `1.36378`, as ruled.** Carrying every term unrounded lands on `1.363799`; the ruled figure is `1.36378`, a gap of `1.5e-5` — **$0.006/gh** at founding — that comes from which intermediate the divisor is rounded at. This doc publishes the ruled constant and records the difference rather than silently substituting its own. The Round-2 figure **1.36285** was in a different league: it reproduces from no consistent input set, sits **0.07 %** low (≈ `$0.35/gh` of net at founding), and is the same class of slip as the rounded-gross gap recorded under the regeneration rule below. **This constant is not used by the shipped model** (the ruled 0.972 path is), so nothing downstream moves; it is corrected so the sensitivity note can be trusted if doc 09 ever exercises it.

**(b) Departments — $116 → $96/gh.** §9 item 6b held this line at 116 pending doc 09's R-16 manifest. **That manifest has landed**, so the line is now derivable rather than held: the starter city's stations are `POL-1`, `FIRE-1`, `WTR-1` and `YARD-1`. `PLANT-1` and `SUB-A` are **not** stations — their recurring cost is `E_grid`'s `PLANT_OM_PER_MW_HOUR` and `GRID_MAINT_PER_MW_HOUR`, and billing them here as well is precisely the double-charge C-08 removed.

```
police_station 26 + fire_station 30 + water_works 20 + construction_yard 20 = $96/gh
                                      ^^^^^^^^^^^^^^ staffing only (RR-16)
```

**`water_works 20` is a staffing-only line (report 98 RR-16).** The water works' plant O&M is billed by `E_water` — `pump_capacity 40.0 m³/h × PUMP_OM_PER_M3H_HOUR 0.35 = $14.00/gh` in (d) below — so this $20 buys operators, not pumps. It is the same exclusion `PLANT-1` and `SUB-A` get, stated rather than implied: wherever `E_grid` or `E_water` prices a facility's O&M, the department line for that service is staffing only. **No number changes** — 20 was already authored as a staffing figure; it is now labelled so nobody "completes" it with an O&M component that `E_water` is already charging.

**(c) `E_grid` — $73 → $74.87/gh** on doc 09's real inventory (2.40 MVA of transformers, 1.416 km of line). Worked in full in §2.4. Doc 04's flat `upkeep_per_gh` column — which priced the same set at ~$834/gh and would have made the starter city insolvent on day one — remains deleted (C-12).

**(d) `E_water` — $10 → $15.39/gh.** The C-34 rescale landed in doc 05 but never reached this table (96 F-6, 97 F-03). All three terms re-derive from doc 09 §2.9.4/§2.9.6 and doc 05 §8:

```
treatment   m3_treated 5.56 m3/h x 0.06                        =  $0.334/gh   (was 1)
mains       126 trunk + 63 lateral = 189 tiles x 8 m = 1.512 km
            1.512 x 0.7 x 1.0                                  =  $1.058/gh   (was 4)
pump O&M    pump_capacity 40.0 m3/h x 0.35                     = $14.000/gh   (was 5)
                                                     E_water   = $15.392/gh
```

**(e) Water tariff — $7 → $3/gh.** Same rescale, other side of the ledger: `delivered_m3_hour 5.56 × WATER_TARIFF_PER_M3 0.55 = $3.06/gh`.

**(f) Routine road repair — $0 → $147.22 → $185.87/gh, at doc 10's operating point (report 98 RR-2, re-priced by RR-13).** Roads carry **no standing per-tile upkeep** — doc 10's `upkeep_per_game_day` is deleted, mirroring C-08's no-double-billing principle — so the recurring cost of a road is decay bought back through C-16 repair pricing. Derived, not assumed:

```
inventory     9 core blocks x 87 tiles = 783 (doc 09 template, C-60 class map)
              = 540 AVENUE (block boundaries) + 243 STREET (index-7 collectors)
capital_value build price x ROAD_REPAIR_CAPITAL_FRACTION (0.20)   -- see 2.5
              AVENUE 5,200 x 0.20 = $1,040/tile . STREET 1,800 x 0.20 = $360/tile
decay         doc 10 section 2.3 / 2.12, on the RR-3 [0,1] scale:
              AVENUE 0.0060 /game-day . STREET 0.0090 /game-day
              decay(tile) = base x (1 + 0.75*c_day) x (1 + wx_wear_day)
operating pt  doc 10 OWNS congestion physics and publishes the starter city's derived
              operating point: c_day = 0.35 (quiet), clear => wx_wear_day = 0, so
              multiplier = 1 + 0.75 x 0.35 = 1.2625     (doc 10 sec 2.3, test 42)
pricing       repair_cost = capital_value x damage_fraction x 0.85 x M_repair(1.00)  (C-16)

Steady state: every repair restores condition to 1.00, so over any cycle the player buys
back exactly the condition the network loses. The expected rate is therefore
decay x capital x 0.85, and it is INDEPENDENT of auto_repair_threshold -- the threshold
sets how lumpy the spend is, not how large.

AVENUE  540 x 1,040 = $561,600 capital
        x 0.0060/gd = $3,369.60/gd  x 1.2625 = $4,254.12/gd
                                    x 0.85   = $3,616.00/gd  = $150.66675/gh
STREET  243 x   360 =  $87,480 capital
        x 0.0090/gd =   $787.32/gd  x 1.2625 =   $993.99/gd
                                    x 0.85   =   $844.89/gd  =  $35.20387/gh
                                        E_roads_repair       = $185.87057/gh
                                        per developed block  =  $20.65229/gh
```

Equivalently, the whole line is the Round-2 floor scaled by the operating-point multiplier: `147.22425 × 1.2625 = 185.87057`, and the per-block term `185.87057 / 9 = 20.65229`. **`PACING_ROAD_PER_DEVELOPED_BLOCK` moves 16.35825 → 20.65229 $/gh per developed block.**

**Why the floor was the wrong number to book (RR-13).** Round 2 evaluated this line at `c_day ≈ 0`, reasoning that a quiet starter city carries no congestion. Doc 10 owns congestion physics, and what it actually publishes for this city is `c_day = 0.35` — its §2.3 accrual (`core_damage_fraction_accrual_per_gh = 0.28548` tile-fractions/gh) and its test 42 are both stated at that point, and its own decay worked example calls `c_day = 0.35` "quiet". Booking the ledger at 0 while the physics doc runs its arithmetic at 0.35 made this doc's line a **floor the sim would never actually observe**, understating routine road cost by **26.25 %** (`1.2625 − 1`). Cross-check against doc 10's published throughput, which is the same statement in the other unit: `0.28548 tile-fractions/gh` over a core whose mean tile capital is `(540×1,040 + 243×360) / 783 = $828.96`, priced at 0.85 ⇒ `0.28548 × 828.96 × 0.85 = $201.1/gh` if every tile-fraction were of average value. The exact figure is lower ($185.87) because the fractions are not uniformly distributed across classes — AVENUE tiles carry 2.9× the capital of STREET tiles (`1,040 / 360`) but decay 1.5× slower (`0.0060 / 0.0090`), so the cheap class supplies 40 % of the fractions against 13 % of the capital — which is why this doc computes per class rather than multiplying the aggregate.

**Two independent checks on the capital basis.** (i) Doc 10's own — now deleted — standing upkeep priced the same 9-block core at **$157.28/gh** (`9 × (60×6.00 + 27×2.20) / 24`). That figure was congestion-independent, so the like-for-like comparison is against this line's `c_day = 0` floor: **$147.22 vs $157.28, 6.4 % apart** — two independently authored routes agreeing, which remains the strongest available evidence that a 0.20 capital basis is right. At the `c_day = 0.35` operating point the derived line runs **18.2 % above** doc 10's old flat rate, which is the correct direction: a flat per-tile upkeep could not price traffic, and traffic is exactly what wears a road. (ii) As a rate on capital, roads cost `0.0060 × 1.2625 × 0.85 = 0.644 %` (AVENUE) and `0.0090 × 1.2625 × 0.85 = 0.966 %` (STREET) of their repair basis per game-day, against `BUILDING_MAINT_RATE`'s **0.96 %** of capital per game-day. The STREET rate now lands within 0.6 % of the building rate — two long-lived civil assets, independently authored, costing the same fraction of capital to keep.

**What a 1.00 basis would have cost, recorded so nobody re-litigates it.** At `ROAD_REPAIR_CAPITAL_FRACTION = 1.00` the same arithmetic gives `(540×5,200×0.0060 + 243×1,800×0.0090) × 1.2625 × 0.85 / 24 = 753.33 + 176.02 = ` **$929.35/gh** ($736.12 even at the `c_day = 0` floor) — **125.5 % of the starter city's gross tax** ($740.29) and **110.7 % of its gross revenue** ($839.35), for a road network the player never bought and cannot decline. The starter city would be insolvent at founding and no "slight retune" reaches that far. RR-2 fixes the per-tile prices and doc 10 owns the decay rate *and* the operating point, so the capital basis is the only honest lever, and this is why it exists.

**The founding ledger, restated in full:**

```
REVENUE
  tax        686 x occ 1.000 x f_power 1.000 x f_water 1.000 x f_road 1.000
                 x f_stability 0.9722 x f_happiness 1.110 x f_condition 1.000
                 x policy 1.000 x M_rev 1.000                        =  740.291
  power tariff                                       (held - see below)  93.00
  water tariff  5.56 m3/h x 0.55                                     =    3.058
  city services  no incident resolved in the founding HOUR (RR-78)   =    0.000
  state assistance  departments 96 + fleet 76, share(day 0) = 1.00   =  172.000
                                                    GROSS REVENUE    = 1008.349 $/gh

EXPENSES
  building maintenance   68,600 capital x 0.00040 x 1.0              =   27.440
  departments            26 + 30 + 20 (staffing only) + 20          =   96.000
  fleet                  2x7 + 12 + 9 + 9 + 14                      =   58.000
  E_grid                 40.000 + 24.000 + 9.000 + 1.274            =   74.274
  generation fuel                                    (held - see below)  57.000
  vehicle fuel                                       (held - see below)   6.000
  E_water                0.334 + 1.058 + 14.000                     =   15.392
  routine road repair    150.667 + 35.204   (c_day 0.35, x 1.2625)  =  185.871
  debt service                                                      =    0.000
                                                    TOTAL EXPENSE    =  519.977 $/gh

NET  = 1008.349 - 519.977  =  +488.37 $/gh  ->  +$488/gh  =  +$11,721/game-day
```

> **WAVE 17 — this ledger does not move, and that is the finding** *(doc 93 §Y1,
> doc 92 §43.8)*. The ownership ruling was drafted to retire `E_building_maint`
> here, on the reading that it bills exactly the four `REVENUE_CLASSES` — exactly
> the buildings the city does not own. **Measured, the retirement broke the
> game**: with the line gone and private stock kept up by its owners,
> `tools/measure_insolvency.gd` put `do_nothing` on `standard` at game-day
> **176** against gate 29's ruled 69, and `casual` **never went insolvent inside
> 200 game-days at all**. So the line stays, and §2.4 now says what it is: the
> city's cost of *serving* a building, which is what C-08's civic exclusion
> already implied — civic shells are excluded because their own O&M lines bill
> them, not because the city only pays for what it owns. What moves to the owner
> is the lumpy, TAPPED repair (§2.6a's `E_OWNER_MAINTAINED`), which is what the
> 2026-09-01 playtest actually asked for.
>
> **Measured on the live sim, 24 settled game-hours, `standard`, seed 1337**
> (`tools/measure_founding_ledger.gd --hours=24`): gross **1047.184374 on both
> sides, bit-identical**; expense `532.296003 → 533.212457`; net `514.888371 →
> 513.971917`. The only line that moves at all is `departments`, by
> **+$0.92/gh**, because doc 93 §Y5 finally applies
> `ASSET_CONDITION_PENALTY_COEFF` to a worn station — **0.18 % of the game-day
> net, inside every anchor's own ±1 % tolerance, so not one pacing guardrail is
> re-fitted and gates 1, 2 and 2b hold unchanged.**

> **WAVE 15 — the revenue side moves by exactly +$169.00/gh and not one expense
> line moves at all** *(report 98 RR-78 / RR-79, doc 92 §36.2).* Two published
> constants, in opposite directions: `+172.00` of §2.5a founding assistance and
> `-3.00` of the retired `fines` line. Gross `839.349412 -> 1008.349412`, net
> `319.372846 -> 488.372846`, game-day `+$7,665 -> +$11,721`.
>
> **The `city services` line reads 0.000 in this table and that is the founding
> HOUR, not the founding day.** Settle the same city for 24 game-hours and the
> line is **$38.38/gh — $921 across the founding day, 12.5 % of what this ledger
> used to call its whole net income** — on a `do_nothing` city that builds
> nothing and dispatches nothing. That money was always being paid; before RR-78
> it went straight to the treasury with no ledger line and no notification
> naming it, which is the whole of the player's report that automatic dispatch
> "should pay us money". The as-integrated anchors move with it:
> `STARTER_FIRST_GAME_DAY_NET_EXACT 7380.320908 -> 12357.320908`, of which
> `169 x 24 = 4056.00` is the design and **$921.00 is the arrears.**

> **`E_grid` $74.874 → $74.274/gh, and the net with it** *(doc 92 §14.1, ruled Wave 4; the doc edit doc 92 §16 held is applied here)*. Doc 92 F-4 thinned `data/starter_city.json`'s founding transformer roster **23 → 18 nodes**. That is **0.15 MVA** of rated plate off the inventory (`2.40 → 7×0.05 + 10×0.15 + 1×0.40 = 2.25`), and this section bills $4.00/MVA-gh on the inventory, so the transformer term falls by exactly `0.15 × 4.0 = $0.60/gh` — `9.600 → 9.000`. The plant, the substation and the 1.416 km of line are untouched, and so is every revenue line. **Net: `839.349412 − 519.976566 = 319.372846 $/gh`**, displayed as **+$319/gh** and **+$7,664.95/game-day**; the rounded headline figure does not move. `data/economy.json`'s `pacing_guardrails` and `tests/test_economy.gd` carry the re-stamped pair, and doc 93 §E2 carries the shift table.

**The net line, from unrounded components on both sides (report 98 RR-18).** Round 2 subtracted an unrounded expense total from a *rounded* $839 gross, which is the one arithmetic sin this pass will not repeat. Revenue: `740.291412 + 93 + 3.058 + 3 = 839.349412` (tax = `686 × 0.9722 × 1.110 = 686 × 1.079142`). Expense: `27.44 + 96 + 58 + 74.274 + 57 + 6 + 15.392 + 185.870566 = 519.976566`. Net: `839.349412 − 519.976566 = ` **319.372846 $/gh**, displayed as **+$319/gh** and **+$7,664.95/game-day**. Nothing here is rounded until the last step. *(The `E_grid` term is the Wave-4 18-node roster — see the note under the ledger.)*

**Progression of this line across the four passes:** expense `306 → 347 → 482 → 521`; net `+414 → +373 → +357 → +319`. *(Wave 15's revenue re-anchor moved the net to +488; Wave 17 moved neither figure — see the box above.)* Round 2's four moves nearly cancelled; Round 3 moves exactly one line:

```
ROUND 1 -> ROUND 2
revenue   tax        +123.29   (740.29 - 617)
          water tariff -3.94   (3.06 - 7)                       revenue  720 -> 839  (+119)
expense   roads      +147.22   (new line, at the c_day 0 floor)
          E_grid       +1.87   (74.87 - 73)
          E_water      +5.39   (15.39 - 10)
          departments -20.00   (96 - 116)                       expense  347 -> 482  (+135)
                                                                NET     +373 -> +357 (-16)

ROUND 2 -> ROUND 3   (the road line moves onto doc 10's operating point, RR-13)
expense   roads       +38.65   (185.87 - 147.22, i.e. x 1.2625) expense  482 -> 521  (+39)
                                                                NET     +357 -> +319 (-38)

ROUND 3 -> WAVE 4    (doc 92 F-4 thins the transformer roster 23 -> 18)
expense   E_grid       -0.60   (74.274 - 74.874, i.e. -0.15 MVA) expense  521 -> 520  (-1)
                                                                NET     +318.77 -> +319.37
```

**Two revenue lines and one expense line are still held, and this doc will not invent them.** `power tariff 93` and `generation fuel 57` both imply a starter delivered/generated load of ~1.5 MWh/gh. Doc 09 now publishes the **402.0 kW building nameplate** and the **783.3 kW night peak**, but the 24-hour **delivered** MWh depends on the 24-hour mean of doc 01's `streetlight_load` channel (on 19:00–07:00, so nowhere near 1.000) and on doc 04's loss model — and doc 04 owes exactly that restatement under **RR-10**. The two figures sit on opposite sides of the ledger and move together, so holding them shifts net by less than the pair's own uncertainty. `vehicle fuel 6` waits on doc 06's `vehicle_km_this_hour`. See §9 item 6b. *(The third held line, `fines 3/350`, was retired in Wave 15: doc 06 had been taking that measurement all along — report 98 RR-78.)*

**Regenerating the pacing table.** Round 1's model stands: revenue and the city-scaling expense lines (`E_grid`, `E_water`, departments, maintenance, fleet, fuel) all grow with installed capacity, because the grid is sized to the load and the load is sized to the buildings that pay the tax. **Roads are the exception** — the road network grows only when a *block* is developed (one stamped template = 87 tiles), not when a vacant lot is filled or a building upgraded, and the starter core is 62 % vacant lots. So the Round 2 rule splits into a proportional term and a per-block term:

```
net_r3(phase) = round( K x net_r1(phase)  -  ROAD_PER_BLOCK x blocks_developed(phase) )
K              = (839 - 334.706) / 373 = 504.294 / 373      = 1.35200   (unchanged)
ROAD_PER_BLOCK = 185.87057 / 9                              = 20.65229  $/gh per block
                 (was 147.224 / 9 = 16.35825 at the c_day 0 floor -- RR-13)
flow           = net_r3 x (gh for a play row | effective earning hours for an away row)
treasury_end   = treasury_start + flow + grants - one_off_spend
```

`334.706` is the total **non-road** expense at founding; `K` is what one dollar of Round-1 net becomes once the tax uplift and the utility corrections are applied at constant city shape. **`K` is untouched by RR-13** — it is the *non-road* proportional term, and the road line was deliberately factored out of it precisely so a re-priced road line moves one constant and not twenty-three rows' worth of revenue. Sanity check at founding: `1.35200 × 373 − 20.65229 × 9 = 504.296 − 185.871 = ` **318.43**, against the ledger's directly computed **319.37** — a **$0.95/gh (0.30 %)** gap of which $0.35 is inherited from `K` having been derived against the rounded `$839` gross rather than `$839.349`, and $0.60 is Wave 4's `E_grid` restatement (`334.706` is likewise still the pre-restatement non-road total). Re-deriving `K` at `(839.349 − 334.106)/373 = 1.35454` would close both and move every row by ~+0.5 %; **RR-13 did not ask for that and no pass since has done it**, because the model's own tolerance (test 27, ±20 %) is 66× the error and churning 23 rows for 0.3 % is how a pacing table stops being auditable. The gap is recorded here and in §8 rather than silently absorbed.

`blocks_developed` counts blocks whose `road_install` phase has completed: **9** at founding, **10** from S3 (block 2 finishes development), **11** from S6 (the marsh bill lands), **12** from S11 (waterfront), **13** at S12 (4th block). **One-off spends are unchanged** — the block template stamp is billed once, by the `road_install` development phase (§2.8), and never a second time by the per-tile ladder.

| # | phase | real min | gh | blk | R1 net | **net $/gh** | flow | one-off spend | treasury end | beat |
|---|---|---|---|---|---|---|---|---|---|---|
| S1 | play | 45 | 45 | 9 | 374 | **320** | +14,400 +10,000 grant | 17,940 | **$31,460** | Tutorial; build house+store; scripted transformer failure; first upgrade; buy block 2 ($12,400) |
| — | away 11 h | | 94 eff | 9 | 401 | **356** | +33,464 | 2,000 | $62,924 | First WHILE YOU WERE AWAY |
| S2 | play | 10 | 10 | 9 | 405 | **362** | +3,620 | 9,198 | $57,346 | Start survey/clear/grade |
| — | away 10 h | | 94 eff | 9 | 419 | **381** | +35,814 | 3,000 | $90,160 | |
| S3 | play | 60 | 60 | 10 | 469 | **428** | +25,680 | 66,790 | **$49,050** | Finish development (**10th block joins the road graph**); 4 houses + apartment + store; **substation upgrade forced** ($18,000) |
| — | away 10 h | | 94 eff | 10 | 532 | **513** | +48,222 | 3,500 | $93,772 | |
| S4 | play | 10 | 10 | 10 | 541 | **525** | +5,250 | 3,480 | $95,542 | Queue 2 upgrades |
| — | away 4 h | | 88 eff | 10 | 550 | **537** | +47,256 | 2,500 | $140,298 | |
| S5 | play | 15 | 15 | 10 | 559 | **549** | +8,235 | **17,300** | $131,233 | **Buy marsh block `B_0_6` ($6,700 — C-18)** + start survey |
| — | away 6 h | | 92 eff | 10 | 568 | **561** | +51,612 | 8,000 | $174,845 | **First thunderstorm, offline** |
| S6 | play | 70 | 70 | 11 | 631 | **626** | +43,820 | **73,428** | **$145,237** | Storm repairs; **marsh development bill lands ($68,578 — example F)**; factory built |
| — | away 11 h | | 94 eff | 11 | 712 | **735** | +69,090 | 5,000 | $209,327 | |
| S7 | play | 15 | 15 | 11 | 721 | **748** | +11,220 | **14,400** | $206,147 | 2nd fire engine after a near-miss (§2.13(c) price) |
| — | away 11 h | | 94 eff | 11 | 730 | **760** | +71,440 | 6,000 | $271,587 | |
| S8 | play | 80 | 80 | 11 | 811 | **869** | +69,520 | **261,000** | **$80,107** | **THE CRUNCH** — see below |
| — | away 10 h | | 94 eff | 11 | 1,712 | **2,087** | +196,178 | 40,000 | $236,285 | Heat wave + 4% grid margin ⇒ cascading outage |
| S9 | play | 20 | 20 | 11 | 1,982 | **2,452** | +49,040 | 48,000 | $237,325 | Mobile transformer bought under fire ($48,000) |
| — | away 11 h | | 94 eff | 11 | 2,207 | **2,757** | +259,158 | 12,000 | $484,483 | |
| S10 | play | 90 | 90 | 11 | 2,388 | **3,001** | +270,090 | 288,000 | $466,573 | Resilience package finally bought; RI 34→68 |
| — | away 22 h | | 94 eff | 11 | 2,613 | **3,306** | +310,764 | 9,000 | $768,337 | Quiet night — the payoff |
| S11 | play | 85 | 85 | 12 | 2,703 | **3,407** | +289,595 | 280,000 | $777,932 | Waterfront block + two high-rises |
| — | away 20 h | | 94 eff | 12 | 2,973 | **3,772** | +354,568 | 14,000 | $1,118,500 | |
| S12 | play | 100 | 100 | 13 | 3,153 | **3,994** | +399,400 | 620,000 | **$897,900** | Grid expansion, 4th block, 8 upgrades |

**End state at 10 real hours:** treasury ≈ **$898K** (Round 2: $973K; Round 1: $470K), net income ≈ **+$95,856/game-day** (Round 2: $97,200), city ~4× founding size, Resilience Index ~70.

**What RR-13 did to the arc.** The road line is the only per-block term in the model, so re-pricing it at `c_day = 0.35` takes **$4.29/gh per developed block** off every row — $38.65/gh at founding, $55.82/gh by S12 — and compounds through the treasury. The **early rows take it hardest in relative terms** (S1 net 358 → 320, −10.6 %; S1 treasury $33,170 → $31,460, −5.2 %) and the late rows hardest in absolute terms (S12 treasury $972,787 → $897,900, −$74,887, −7.7 %). That is the right shape: the starter core is 62 % vacant, so its road network is the largest single asset the player owns relative to income, and pricing its wear honestly should bite most when income is smallest. **The crunch got sharper** (§2.12's G3 ratios below), which moves the model *toward* the §11.3 intent rather than away from it.

**Read that honestly.** The arc did not get easier by design; it got easier because doc 09's *measured* t0 factors are better than this doc's guess. Round 1 assumed a 0.90 aggregate on tax; doc 09's starter city is well-enough run to earn **1.079** — a 19.9 % uplift on the largest revenue line — and that uplift compounds through every session, while the road line grows only 44 % across the whole arc (9 → 13 developed blocks). **The tight sessions got tighter and the loose ones got looser:** S1's net falls 374 → 358 → **320** across the three passes and its treasury end falls $33,890 → $33,170 → **$31,460**, while S12's rises $469,521 → $972,787 → **$897,900**. RR-13 pulls the loose end back by 7.7 % without touching the tight end's shape, but it does not undo Round 2's uplift — the ceiling question in §9 item 9b stands.

Whether that *ceiling* is right is a balance question, not an arithmetic one, and §9 item 9 now carries it. The sensitivity is stated rather than fudged: holding `f_happiness` at its neutral 1.000 — i.e. treating doc 09's `H = 82` as a founding grace period that decays as the city takes damage — gives `aggregate = 0.9722`, `tax = 667`, gross `766.0`, `net = 765.99 − 520.58 = +245/gh`, `K = 1.15630` (unchanged — `K` is the non-road term) and, with RR-13's road line, an end state near **$625K** (it was +284/gh and ~$700K at the `c_day = 0` floor). This doc does **not** apply that discount, because doc 09 owns `H`, publishes 82.15 with a worked derivation, and explicitly names "a fudge in the revenue chain" as the wrong lever (doc 09 §9 item 7). If the ceiling needs lowering, the honest place is doc 09's `happiness.norms` centres.

**The S8 crunch, explicitly.** At the decision point the player holds **$341,107** (271,587 carried in + 69,520 earned during S8) and is offered:

| package | contents, itemised on the §2.13 ladder | cost |
|---|---|---|
| **Growth** | data_center L1 180,000 + gas peaker (`plant_gas` L1) 60,000 + 3 × apartment L1 (3 × 7,000) 21,000 | **$261,000** |
| **Resilience** | 2nd substation L1 15,000 + 34-tile class-2 transmission tie (34 × 1,200) 40,800 + tie switch 3,500 + battery bank L3 87,500 + 6 × transformer L4 replacement (6 × 6,900) 41,400 + 2nd fire station 20,000 + fire engine 14,400 | **$222,600** |

Both = **$483,600 = 1.418× treasury** (`483,600 / 341,107`); the cheaper package alone is **0.653× treasury** (`222,600 / 341,107`). Guardrail G3 requires `sum ≥ 1.15×` and `min ≥ 0.45×` — **both hold**, and both moved *away* from their limits under RR-13 (Round 2: 1.264 / 0.582; Round 1: 1.388 / 0.639). The crunch is still a crunch, and a slightly harder one: taking Growth now leaves **$80,107** on hand, ≈ **1.1 game-days** of buffer (was $121,637 ≈ 1.7), and pushes grid margin to 4 %, and the next heat wave then costs ~$218,000 in foregone revenue and repairs; taking Resilience keeps income flat for ~3 real hours and the player watches the plateau. **This is spec §11.3 made arithmetic.** The *sum* ratio was the guardrail to watch after Round 2; with $41,530 less banked at the decision point it now carries 23 % headroom instead of 10 %, and the S8 packages need **no** re-sizing. If doc 09's happiness model later firms up above `H = 82`, re-size the packages upward rather than re-fudging the treasury downward.

**Balance guardrails (asserted by tests, §7):**

- **G1 — not too loose:** at no session end may `treasury > 14 × daily_net_income` for two consecutive sessions.
- **G2 — not too tight:** at every session end, `treasury ≥ 1.5 × daily_net_income`.
- **G3 — the §11.3 crunch exists:** at each city tier there must be a defined growth package and resilience package with `growth + resilience ≥ 1.15 × treasury_at_tier` and `min(growth, resilience) ≥ 0.45 × treasury_at_tier`.
- **G4 — offline never dominates:** cumulative offline income over the 10-hour model must be between 1.2× and 2.0× cumulative online income. Recomputed against the Round-3 table: offline `33,464 + 35,814 + 48,222 + 47,256 + 51,612 + 69,090 + 71,440 + 196,178 + 259,158 + 310,764 + 354,568 = 1,477,566`; online `14,400 + 3,620 + 25,680 + 5,250 + 8,235 + 43,820 + 11,220 + 69,520 + 49,040 + 270,090 + 289,595 + 399,400 = 1,189,870`; ratio **1.242×** (Round 2: 1.250×; Round 1: 1.279×). The road line is charged in both modes, so re-pricing it barely tilts the ratio; the small move is the per-block term landing on the 12 play rows and only 11 away rows.
- **G5 — first-hour generosity:** the player must be able to afford the first land block, its full 6-phase development, and 4 buildings within the first 120 game-hours. **Check:** by gh 120 the player has taken in `25,000 start + 10,000 grant + 45 × 320 + E(75) 53.2 × 356 = 25,000 + 10,000 + 14,400 + 18,939 = $68,339` against a required `12,400 block + 34,588 development + ~13,000 for four buildings = $59,988`. **✓** (margin $8,351, against Round 2's $12,136 and Round 1's $13,175 — narrowing but comfortably clear; the requirement is unchanged because RR-13 touches no price.)

**Guardrail check on the Round-3 table** (`daily_net = net × 24`):

| session end | treasury | daily net | treasury / daily net | G1 ≤ 14 | G2 ≥ 1.5 |
|---|---|---|---|---|---|
| S1 | 31,460 | 7,680 | 4.10 | ✓ | ✓ |
| S2 | 57,346 | 8,688 | 6.60 | ✓ | ✓ |
| S3 | 49,050 | 10,272 | 4.78 | ✓ | ✓ |
| S4 | 95,542 | 12,600 | 7.58 | ✓ | ✓ |
| S5 | 131,233 | 13,176 | 9.96 | ✓ | ✓ |
| S6 | 145,237 | 15,024 | 9.67 | ✓ | ✓ |
| S7 | 206,147 | 17,952 | **11.48** | ✓ | ✓ |
| S8 | 80,107 | 20,856 | **3.84** | ✓ | ✓ |
| S9 | 237,325 | 58,848 | 4.03 | ✓ | ✓ |
| S10 | 466,573 | 72,024 | 6.48 | ✓ | ✓ |
| S11 | 777,932 | 81,768 | 9.51 | ✓ | ✓ |
| S12 | 897,900 | 95,856 | 9.37 | ✓ | ✓ |

Peak ratio is **11.48 at S7** against the G1 ceiling of 14 (Round 2: 12.55, Round 1: 12.77) — still the row to watch, and materially safer. The **G2 floor moves from S1 to S8** (3.84 against the 1.5 minimum; S1 is now 4.10), which is the honest consequence of the crunch row losing more cash than the tutorial row: the binding "too tight" moment is now the moment the design *intends* to be tightest. **All five guardrails hold on the Round-3 table, so no expense constant was retuned** — RR-13 licensed a retune only if a guardrail broke, and none did. `ROAD_REPAIR_CAPITAL_FRACTION` stays at **0.20**, `K` stays at **1.35200**, every price in §2.13 is untouched, and the only constant that moved is the one RR-13 named: `PACING_ROAD_PER_DEVELOPED_BLOCK` 16.35825 → **20.65229**, which is not a tuning choice but the arithmetic consequence of doc 10's operating point.

---

### 2.13 The complete currency ladder — this doc is the sole authority (report 98 C-07)

Four tables were in conflict across the project: doc 02's build costs (~35% below this doc's), doc 04's grid ladder (8–13× above), doc 06's fleet (5–14× above), and — surviving Round 1 untouched because C-07's amend list never named roads — doc 10's per-tile road prices (report 98 RR-2). **Doc 03 is the sole currency authority** — it owns treasury magnitude, starting funds and the only calibrated pacing model (§2.12). The complete ladder is published here, in one place, and nothing costed may be implemented against any other table.

Every price below is at **`M_build` / `M_land` / `M_dev` = 1.00 (standard)**. Difficulty scaling is applied at spend time, never baked into the table.

#### (a) Buildings — `build_cost_l1` (unchanged; doc 02's cost column is deleted)

The §2.2 table stands verbatim. For reference, the twelve costed archetypes plus civic/utility:
house 1,200 · store 2,600 · apartment 7,000 · office 13,000 · construction_yard 16,000 · substation 15,000 · police_station 18,000 · fire_station 20,000 · factory 22,000 · highrise_res 26,000 · highrise_com 40,000 · water_plant 45,000 · power_plant_gas 60,000 · data_center 180,000.

Level costs derive from `build_cost_l1` through §2.3's `upgrade_cost()` / `capital_value()` — doc 02 supplies `build_cost_l1` and `class` and defines no curve of its own.

#### (b) Grid components — rescaled from doc 04 onto this ladder

Doc 04 owns capacity, topology, thermal, protection and repair *times*; it owns **no prices**. Its `build_cost`, `upkeep_per_gh` and `fuel_cost_per_kwh` columns are deleted from `data/power.json` (upkeep is §2.4's `E_grid`, fuel is §2.4's `E_fuel_generation`, prices are here).

**Rescale rule.** Two anchors were fixed by C-07 — `substation L1 → $15,000` (from doc 04's $120,000, factor **1/8**) and `plant_gas L1 → $60,000` (from doc 04's $180,000, factor **1/3**). Everything else follows:

```
grid components  (substation, transformer, feeder, transmission, battery, backup gen, tie switch, flood wall):
        cost_03 = round_currency( cost_04 × GRID_COST_SCALE ),      GRID_COST_SCALE = 0.125   (1/8)
generating plants (gas, solar, wind):
        cost_03 = round_currency( cost_04 × PLANT_COST_SCALE ),     PLANT_COST_SCALE = 0.333… (1/3)
round_currency(x) = nearest $10   for x <   1,000
                    nearest $100  for x <  100,000
                    nearest $1,000 for x ≥ 100,000
```

Plants keep a shallower factor because a plant is a *strategic* purchase — at 1/8 a gas peaker would cost less than a fire station, and the S8 crunch would evaporate. The two anchors were both given by the ruling; this rule just makes them reproducible.

| component | doc 04 `build_cost` (deleted) | × scale | **this doc's `build_cost` (canonical)** |
|---|---|---|---|
| `plant_gas` L1–L5 | 180k / 380k / 760k / 1.5M / 2.9M | 1/3 | **60,000 / 127,000 / 253,000 / 500,000 / 967,000** |
| `plant_solar` L1–L5 | 220k / 500k / 950k / 1.8M / 3.1M | 1/3 | **73,300 / 167,000 / 317,000 / 600,000 / 1,033,000** |
| `plant_wind` L1–L5 | 260k / 560k / 1.05M / 1.9M / 3.3M | 1/3 | **86,700 / 187,000 / 350,000 / 633,000 / 1,100,000** |
| `substation` L1–L5 | 120k / 260k / 520k / 1.05M / 2.1M | 1/8 | **15,000 / 32,500 / 65,000 / 131,000 / 263,000** |
| `transformer` L1–L5 | 4,000 / 9,000 / 22,000 / 55,000 / 130,000 | 1/8 | **500 / 1,100 / 2,800 / 6,900 / 16,300** |
| `transformer` **L6** *(Wave 28)* | — (doc 04's table predates the rung) | — | **41,500** — see below |
| `feeder` class 1–3, **per tile**, overhead | 900 / 1,700 / 3,200 | 1/8 | **110 / 210 / 400** |
| `transmission` class 1–3, **per tile** | 5,800 / 9,400 / 16,000 | 1/8 | **730 / 1,200 / 2,000** |
| `battery` L1–L5 *(post-MVP)* | 140k / 320k / 700k / 1.5M / 3.2M | 1/8 | **17,500 / 40,000 / 87,500 / 188,000 / 400,000** |
| `backup_gen` S / M / L | 18,000 / 62,000 / 210,000 | 1/8 | **2,300 / 7,800 / 26,300** |
| `tie_switch` | 28,000 | 1/8 | **3,500** |
| `flood_wall`, per level (0–2) | 45,000 | 1/8 | **5,600** |
| `surge_arrester`, per level (0–3) | `0.09 × build_cost` | — | **`0.09 × build_cost`** (a fraction, unaffected by rescale) |

Underground feeder still costs `× UNDERGROUND_COST_MULT (2.6)` per tile — that multiplier is doc 04's topology decision, not a price.

> **The transformer's sixth rung — $41,500** (Wave 28; doc 04 §2.2's 6,750 kW
> rung, doc 93 §BC-2, doc 92 §68.2, report 98 §72 RR-221). **It has no
> `× GRID_COST_SCALE` row above because doc 04's deleted table never had a sixth
> rung to rescale**, so it is derived from the five cells this doc already owns
> rather than back-fitted through a scale that no longer has an input.
>
> **The ladder's own $/kW curve, continued.** The five shipped rungs price copper
> at
>
> | rung | kW | build_cost | $/kW |
> |---|---|---|---|
> | 1 | 50 | 500 | 10.00 |
> | 2 | 150 | 1,100 | 7.33 |
> | 3 | 400 | 2,800 | 7.00 |
> | 4 | 1,000 | 6,900 | 6.90 |
> | 5 | 2,500 | 16,300 | 6.52 |
> | **6** | **6,750** | **41,500** | **6.15** |
>
> — a monotone decline whose last step is `6.52 / 6.90 = ×0.945`. One more step
> gives `6.52 × 0.945 = 6.15 $/kW`, and `6.15 × 6,750 = $41,512.50`, half-up on
> this column's own $100 grid = **$41,500**. Nothing here is a new magnitude: it
> is the same economy-of-scale curve the first five rungs already publish, read
> one step further, which is report 98 RR-19's principle applied forward.
>
> **Where it sits in the roster.** It is the most expensive single grid purchase
> short of a substation ($15,000 at L1, $32,500 at L2), and that ordering is the
> right one rather than an accident: doc 04 §2.2's sixth rung needs a class-3
> feeder and a substation at L2 or better underneath it, so $41,500 is the
> *smaller* half of what a top-rung transformer actually commits a city to. Every
> reader is already wired — `CostCurves.grid_build_cost` reads the array,
> `grid_upgrade_cost` prices an L5 → L6 re-rating at the target rung's full build
> cost per §2.13(f), `capital_value_grid` prices its repair and
> `grid_demolition_refund` its 25 % — so this cell needs no new accessor and
> `test_gate_34_…` asserts every rung of the ladder is both placeable and priced
> above $0.

**What a placed transformer actually costs (Wave 1.5).** Doc 04's `cmd_place_grid_component` charges the `transformer` row at the chosen level **plus the feeder lateral it takes to reach the grid**, at this table's per-tile feeder price for the tapped feeder's conductor class (and its underground multiplier where it applies). An L1 transformer two tiles off a class-1 overhead feeder is therefore `500 + 2 × 110 = $720`, and one eight tiles out is `500 + 8 × 110 = $1,380` — the copper is the interesting half of the decision, which is the point. Those lateral tiles join the feeder's `route`, so §2.4's `E_grid` bills their `line_km` from the next game-hour: **extending the grid raises the standing bill**, with no separate per-component upkeep (C-08 still holds). The `road_install` / `utility_corridor` no-double-billing rule below applies unchanged — a development phase's trunk is charged once, by §2.8, and never again per tile.

**Worked check against §2.12's S8 resilience package:** `substation L1 15,000 + 34 × transmission cls-2 1,200 = 40,800 + tie_switch 3,500 = 59,300` — the package line this doc has always priced at "≈60,000". The rescale reproduces the pacing model's own assumptions, which is the strongest available evidence that 1/8 and 1/3 are the right factors.

#### (c) Vehicles — the definitive roster (recomputation R-14)

Doc 06's `purchase_cost` / `upkeep_per_game_hour` / `dispatch_cost` columns are deleted. C-07 preserves doc 06's **ratios**, not its magnitudes, and fixes the anchor at **fire engine = 1.60 × patrol car**. Doc 06's own spread is 4.222× (patrol 45,000 → engine 190,000), so the roster is rank-preservingly compressed onto this doc's scale:

```
purchase_03[v] = round_to_100( purchase_03[patrol_car] × ( purchase_06[v] / purchase_06[patrol_car] ) ^ GAMMA )
purchase_03[patrol_car] = 9,000        (this doc's existing anchor, unchanged)
GAMMA = ln(1.60) / ln(4.2222) = 0.47000 / 1.44036 = 0.32631
```

`GAMMA` is chosen so the engine lands **exactly** on the ruled 1.60×; every other doc-06 vehicle inherits the same compression, so the ordering patrol < water < utility < construction < engine survives intact.

| doc 06 type | doc 06 purchase (deleted) | ratio vs patrol | ^GAMMA | **purchase (canonical)** | **ratio vs patrol** |
|---|---|---|---|---|---|
| `police_patrol` → `patrol_car` | 45,000 | 1.0000 | 1.0000 | **9,000** | 1.000 |
| `water_repair_truck` | 85,000 | 1.8889 | 1.2306 | **11,100** | 1.233 |
| `utility_service_truck` | 95,000 | 2.1111 | 1.2761 | **11,500** | 1.278 |
| `construction_crew_vehicle` → `construction_crew` | 120,000 | 2.6667 | 1.3772 | **12,400** | 1.378 |
| `fire_engine` | 190,000 | 4.2222 | 1.6000 | **14,400** | **1.600** |

The remaining ten vehicle types have no doc-06 counterpart and keep this doc's authored prices (they were already on this ladder). Standby upkeep and `active_mult` are **authored per role**, not derived from purchase — a construction crew is wages, a mobile transformer is metal — and land in the band **0.05 %–0.115 %** of purchase per game-hour. *(The upper bound was quoted as 0.11 % and `construction_crew` is 0.113 % — verification 97 §2.2's nit. The band moves, not the price: crews are wages and belong at the top of it, and §7 test 35's range moves with it.)* `dispatch_cost` is the one-off turnout/consumables charge doc 06 books per responding unit:

```
dispatch_cost = round( DISPATCH_COST_UPKEEP_MULT (2.4) × upkeep_per_gh )
```

2.4 sits inside doc 06's own dispatch:upkeep spread (1.50–2.57, mean 2.31), so its incident net-value arithmetic keeps its shape.

| vehicle | purchase | upkeep $/gh | upkeep as % of purchase | `active_mult` | `dispatch_cost` | fuel class |
|---|---|---|---|---|---|---|
| `patrol_car` | 9,000 | 7 | 0.078% | 2.5 | 17 | light |
| `water_repair_truck` | 11,100 | 9 | 0.081% | 2.5 | 22 | medium |
| `utility_service_truck` | 11,500 | 9 | 0.078% | 2.5 | 22 | medium |
| `construction_crew` | 12,400 | 14 | 0.113% | 2.0 | 34 | medium |
| `supervisor` | 14,000 | 10 | 0.071% | 2.5 | 24 | light |
| `fire_engine` | 14,400 | 12 | 0.083% | 3.0 | 29 | heavy |
| `pump_truck` | 18,000 | 13 | 0.072% | 2.5 | 31 | medium |
| `bucket_truck` | 20,000 | 14 | 0.070% | 2.5 | 34 | medium |
| `road_crew` | 20,000 | 16 | 0.080% | 2.0 | 38 | heavy |
| `rescue` | 22,000 | 15 | 0.068% | 3.0 | 36 | medium |
| `ladder_truck` | 26,000 | 18 | 0.069% | 3.0 | 43 | heavy |
| `heavy_equipment_crew` | 30,000 | 22 | 0.073% | 2.0 | 53 | heavy |
| `heavy_repair_truck` | 34,000 | 20 | 0.059% | 2.5 | 48 | heavy |
| `crane_crew` | 42,000 | 28 | 0.067% | 2.0 | 67 | heavy |
| `mobile_transformer` | 48,000 | 24 | 0.050% | 2.0 | 58 | heavy |

**Starter fleet check.** Doc 09's starter roster is 2 × `patrol_car`, 1 × `fire_engine`, 1 × `utility_service_truck`, 1 × `water_repair_truck`, 1 × `construction_crew`: `2×7 + 12 + 9 + 9 + 14 = $58/gh`, exactly the `fleet 58` line in §2.12. The R-14 rescale moves purchase prices only; the recurring fleet line is untouched.

Resale is `VEHICLE_RESALE_FRACTION (0.40) × purchase` for every type.

#### (d) Roads — per tile (report 98 RR-2)

**C-07's currency monopoly covers roads too, and until Round 2 it did not.** Doc 10 carried `build_cost`, `upgrade_cost`, `upkeep_per_game_day` and `repair_cost_base` in `data/roads.json`, which made this doc's own §7 test 33 fail against the shipped data (verification 96 F-4, 97 F-06). RR-2 rules: **doc 10 owns road build/repair *work and physics* — crew-hours, condition, decay, damage fractions — and owns no prices.** The four columns are deleted from `data/roads.json` and land here.

| item | price | notes |
|---|---|---|
| `STREET` build, **per tile** | **$1,800** | doc 10's magnitude, adopted; already on this doc's `round_currency` ladder (nearest $100) |
| `AVENUE` build, **per tile** | **$5,200** | boundary arterials in doc 09's template map to AVENUE (C-60) |
| `STREET → AVENUE` upgrade, **per tile** | **$4,000** | |
| demolish refund, per tile | `DEMOLITION_REFUND_FRACTION (0.25) × build price` | STREET $450 · AVENUE $1,300 |
| repair `capital_value`, per tile | `build price × ROAD_REPAIR_CAPITAL_FRACTION (0.20)` | STREET $360 · AVENUE $1,040 — §2.5 |
| `COLLAPSED` rebuild, per tile | full build price | doc 10 §2.12: a collapse is a rebuild, not a repair |
| **standing upkeep** | **none — deleted** | mirroring C-08; the recurring cost of a road is decay bought back through repair (§2.12 f) |

**Upgrade coherence check.** `1,800 + 4,000 = $5,800` to reach an AVENUE by upgrading, against `$5,200` to build one outright — a **$600 (11.5 %) premium for deferring the decision**, the same shape as §2.3's `UPG_COEFF`-driven building ladder, where upgrading is always dearer than having built big first. That the two independently authored numbers land on the right side of that inequality is the reason they can be adopted unchanged rather than re-derived.

**No double-billing with development phases.** The 87-tile block template stamped during land development is charged **once**, by §2.8's `road_install` phase (`PHASE_BASE 7,500 × terrain × distance × access`, $6,930–$21,090 in worked example F). The per-tile prices above are the charge for **player-placed** tiles, the **upgrade** command, the `COLLAPSED` rebuild and the demolish refund. Doc 10's test 42 asserts the same invariant from the other side: a stamped block produces **zero** `Treasury.spend()` calls from `sim/roads/`.

#### (e) City services — what the city is PAID (report 98 RR-78)

The one table in this ladder that runs the other way. Doc 06's `reward_base` column is deleted from `data/incidents.json` and lands here unchanged; doc 12's street opportunities are priced here from the day they ship.

| kind | id | base | ceiling that holds it |
|---|---|---|---|
| dispatch | `structure_fire` | **900** | `0.75 × prevented_loss`, per incident |
| dispatch | `transformer_failure` | **600** | `0.75 × prevented_loss`, per incident |
| dispatch | `water_main_break` | **500** | `MORAL_HAZARD_UNPRICED_CEILING $3,900` |
| dispatch | `storm_damage` (any subtype) | **400** | `MORAL_HAZARD_UNPRICED_CEILING $3,900` |
| dispatch | `crime` | **350** | `0.75 × prevented_loss`, per incident |
| dispatch | `traffic_accident` | **300** | `MORAL_HAZARD_UNPRICED_CEILING $3,900` |
| street | `lost_valuables` | **420 + 180·u** (mean 510) | `STREET_CEILING_SHARE_MAX 0.40` of the opening's net |
| street | `petty_crime` | **260 + 90·u** (mean 305) | ruled `< dispatch crime at its reference payout, $595` |
| street | `loose_animal` | **150 + 60·u** (mean 180) | `STREET_CEILING_SHARE_MAX 0.40` of the opening's net |

Multipliers, in the order they apply: doc 06's shape `(1 + tier_k·(tier_peak − 1)) × speed_bonus` (0.65× to 3.60× across the tier and speed bands), then `MANUAL_DISPATCH_MULT 1.50` if and only if a human made the call, then the ceiling. **A street collection takes no dispatch multiplier at all** — an opportunity is what it is, and a tap is a tap. Its one scalar is `STREET_REWARD_CITY_LEVEL_K 0.20`, applied at spawn against the city level and frozen onto the offer, so a level-5 city pays 1.8× a founding one for the same crook.

*Recorded, because it will be re-litigated:* doc 10's per-tile replacement value for one stamped block is `60 × 5,200 + 27 × 1,800 = $360,600`, which is **17–52×** the `road_install` phase price. That gap is real and this doc has chosen to live with it rather than move either number, on the reasoning that the two prices answer different questions — the phase price is what it costs to *connect a block to the network* through a development contract, the per-tile price is what it costs to *lay one tile on demand*, and bulk civil works are genuinely an order of magnitude cheaper per unit than piecework. The gap is what makes player-drawn roads a considered purchase instead of free paint. It is flagged as §9 item 14 for the overseer.

#### (f) The rush — buying the remaining duration outright (report 98 RR-107, Wave 17)

The player asked for it in the only terms a player has: *"we should have the ability to speed it up with cash."* `CitySim.cmd_rush_construction(job_id)` finishes an in-flight project **now**, and this is what it costs.

**It is not a new number.** §2.5 already publishes this doc's price of time — the *emergency contractor* buys `1 − CONTRACTOR_TIME_FRACTION = 0.65` of a project's duration for a surcharge of `CONTRACTOR_SURCHARGE − 1 = 0.80` of its cash price. Divide the one by the other and the rate falls out:

```
RUSH_SURCHARGE_PER_DURATION = (CONTRACTOR_SURCHARGE − 1) / (1 − CONTRACTOR_TIME_FRACTION)
                            = 0.80 / 0.65 = 1.230769… → published as 1.23077

rush_rate($/crew-hour)  = job_cash_price × 1.23077 / required_crew_hours
rush_cost               = ceil( remaining_crew_hours × rush_rate )
                        = ceil( 1.23077 × (1 − progress) × job_cash_price )
```

`remaining_crew_hours / required_crew_hours` **is** `1 − progress`, off doc 02 §2.13's exact integer accumulator, so the quote and the work can never disagree. `CostCurves` re-checks the published cell against the contractor pair at load (`RUSH_DERIVATION_TOLERANCE 1e-5`) and refuses a boot where the two have drifted apart — the constant is published because C-07 says a price lives in this file, and re-checked because a published derivation that nothing re-derives is a comment.

**What it buys, and why the two valves do not fight.** A rush at zero progress costs **1.23 × the project's cash price**, on top of what was already paid: an instantly-finished `house` is `1,200 + 1,477 = $2,677`, **2.23×** its sticker; a `data_center` is `180,000 + 221,539 = $401,539`. Per unit of duration saved the rush and the contractor are the **same price by construction**, so neither dominates — the contractor is the cheaper ticket for a project you have not started, the rush is the only one that works on a project half-built, and §2.5's *"deliberately bad value"* verdict is inherited rather than re-argued.

**The rate is per-project, not per-crew-hour-of-the-city.** The roster's dollars-per-crew-hour spans **15×** — `house 1,200 / 2.0 h = $600/ch` at the bottom, `data_center 180,000 / 20 h = $9,000/ch` at the top, with `store 867`, `apartment 1,167`, `construction_yard 1,600`, `office 1,625`, `police_station 1,800`, `substation 1,875` and `fire_station 2,000` in between — so a flat $/ch rate would make rushing a tower nearly free and rushing a shack ruinous. Doc 92 §45 has the sweep.

**Rounding is a CEILING here and nowhere else in this ladder.** §2.1's half-up rule governs prices computed from static table cells; this is the only price computed against a live, continuously-moving quantity, and half-up would let a project at 99.9 % quote **$0** — the money-for-time valve handing over the last of the time for none of the money. The ceiling also makes the floor $1 without a second rule.

**Where the dollars land.** The charge goes through `Treasury.spend()` in the **`construction`** category with the ledger reason `rush <kind> <target_ref>`, so it is part of §2.4's `E_oneoff` column, which already names *"contractor surcharges"*. It is therefore **blocked by §2.10 layer 2's austerity gate** — a rush is a new commitment, and layer 2 blocks new commitments — and it is refused outright below the layer-4 credit floor rather than deferred: a half-paid rush would buy a whole building. Both refusals answer `E_FUNDS` with the quote, because from the player's side they are the same fact.

**No difficulty multiplier is applied on top.** `M_build` / `M_dev` are already inside the job's cash price — they were applied when this doc charged it — so a `crisis` city pays a `crisis` rush through the number the rush is a fraction of. Multiplying again would charge `M²`.

**Development phases are re-quoted, not remembered.** Four of the five live job kinds carry their cash price on the job record; doc 09's six phases are billed downstream by `_charge_development_phases`, so a phase's rush price is re-derived from §2.8's own `development_phase_cost()`. If the block's inputs moved since the phase started — a road built next door raises `arterial_connections` — the re-quote differs from what was charged, and that is correct: a rush is a **new purchase, quoted today**, exactly as `cmd_start_development`'s preview quotes the next phase today. A91-D-48 files the underlying asymmetry.

---

## 3. Data Schema

### 3.1 `data/economy.json`

Full contents in §8. Top-level keys: `meta`, `tax`, `expenses`, `tariffs`, `land`, `development`, `upgrades`, **`roads`** (new, report 98 RR-2), `offline`, `recovery`, `presentation`, `pacing_guardrails`. The `difficulty` block has **moved out** into its own file (§3.4, report 98 C-17).

**Files owned by this doc:** `data/economy.json` and `data/difficulty.json`.

### 3.2 `data/buildings.json` — economy columns owned by this doc

Doc 02 owns the file; these keys are this doc's contract:

```json
{ "house": { "class": "residential", "build_cost_l1": 1200, "base_tax_l1": 12,
             "base_tax_by_level": [12, 26, 55, 119, 256],
             "upgrade_cost_by_step": [1380, 3519, 8973, 22882],
             "capital_value_by_level": [1200, 2940, 7376, 18691, 47544] } }
```

Doc 02's own `build_cost` and `upkeep_cents_per_hour` columns are deleted (C-07, C-08); `build_cost_l1` above is the only build price and §2.4 is the only recurring charge.

`base_tax_by_level`, `upgrade_cost_by_step` and `capital_value_by_level` are **generated** from `build_cost_l1` + `class` by a build-time script (`tools/gen_building_economy.gd`) using the curves in §2.2/§2.3, and committed. Hand-editing them is a schema violation; a test asserts they match the generator.

### 3.3 Save section `"economy"` (constitution §9)

```json
{
  "economy": {
    "section_version": 1, "treasury": 972787, "revenue_carry_millidollars": 412,
    "tax_rate": 0.09, "tax_rate_last_changed_hour": 51200,
    "difficulty": "standard", "assisted": false,
    "deferred_liability": 0, "credit_limit_cached": 604800,
    "austerity_active": false, "austerity_entered_hour": null,
    "relief_grants_used": 0, "relief_last_grant_hour": null,
    "ema_net_per_day": 97200,
    "hourly_history": [ { "h": 51199, "rev": 4620, "exp": 1120, "foregone": 622 } ],
    "land_owned": [ { "block_id": "B_0_6", "purchase_price": 6700, "purchased_hour": 33,
                      "dev_phase": 6, "dev_spent": 68578, "risk_index_revealed": 0.443 } ],
    "ledger_totals": { "lifetime_tax": 41822190, "lifetime_tariff": 1902410,
                       "lifetime_expense": 9840112, "lifetime_repairs": 1201884,
                       "lifetime_foregone": 3418220, "lifetime_street": 214600 }
  }
}
```

Three changes from the pre-amendment shape:

- **`schema_version` → `section_version`** (report 98 C-25: `schema_version` appears on the save *envelope* only; every section uses `section_version`). Doc 03 was omitted from C-25's amend list, but the ruling's text is general and this section carried exactly the colliding key.
- **`absence_hours_elapsed` is deleted** (C-20). This doc keeps no absence counter; `OfflineYield` reads `ctx.catchup_index` and publishes `band.yield_mult` to doc 08's `OfflinePolicy`.
- **`ledger_totals.lifetime_street` is added** *(Wave 15, §2.5's `street` line).* Lifetime counters migrate the way doc 09 §2.12's do — **appended at 0, never renamed** — and `Treasury.deserialize` walks the keys it HAS rather than the keys the body carries, so an older `ledger_totals` restores every row it wrote and starts this one at zero. That is not a default invented for the save: a city that could not earn street money genuinely earned none. The city section takes doc 08 §2.8 rung **v7** for the wider shape change this belongs to.

`hourly_history` is a ring buffer of `ECONOMY_HISTORY_HOURS = 168` entries (one game-week) feeding the budget graphs and the WHILE YOU WERE AWAY report.

### 3.4 `data/difficulty.json` — the single difficulty file (report 98 C-17)

Owned by this doc, authored section-by-section by the systems that own the knobs. One schema, one loader, no difficulty scalar anywhere else in the project.

```json
{
  "meta": { "schema_version": 1, "owner_doc": "03-economy.md",
            "presets": ["casual", "standard", "hard", "crisis"],
            "default_preset": "standard",
            "sections": { "economic": "03", "pressure": "07", "escalation": "06", "offline": "08" } },
  "economic":   { "casual": { }, "standard": { }, "hard": { }, "crisis": { } },
  "pressure":   { "casual": { }, "standard": { }, "hard": { }, "crisis": { } },
  "escalation": { "casual": { }, "standard": { }, "hard": { }, "crisis": { } },
  "offline":    { "casual": { }, "standard": { }, "hard": { }, "crisis": { } }
}
```

**Schema rules, validated on load by `sim/economy/difficulty.gd`** — every one of them refuses a real file in `tests/test_difficulty.gd`, because a validation rule with no test is a comment:

1. `meta.presets` is exactly the four names, in that order. Every section must carry a row for all four; a missing preset is a load error, never a silent default.
2. Section keys are fixed: `economic`, `pressure`, `escalation`, `offline`. A key not in `meta.sections` is a load error (this is what stops a fifth doc quietly adding a fifth scalar).
3. Values are scalars (`float`/`int`/`bool`) only — no nested tables, no per-archetype maps. A knob that needs a table belongs in the owning system's own data file, gated by a scalar here.
4. Monotonicity: for any knob whose name begins `M_`, or that ends `_mult` / `_fraction`, the casual→crisis sequence must be **strictly** monotone in the direction the owner declares via a `"_direction": {knob: "up" | "down"}` sibling map at section level. A knob matching that pattern with no declared direction is a load error. Strict and not weak — two presets that agree on a multiplier are the same game in that dimension, and the file should say so by not carrying the knob.
5. `Difficulty.value(section, key)` is the only read path (see §2.9 rule 3 for why not `get`). Systems never open the file.
6. **Key parity**: the four rows of a section carry the same knob names. A knob present on three presets and absent on the fourth would read as its caller's `.get(key, default)` fallback on exactly one difficulty — which is the shape of A91-D-19 itself, one level down.
7. `meta.default_preset` names the preset a city is founded on when nothing chooses, and it is the preset every figure in doc 92 before §29 is measured on. *(Added 2026-08-20; §3.4 shipped without it and the loader needs one name rather than an index into `meta.presets`.)*

Full contents in §8.

---

## 4. Sim API Sketch

All in `sim/economy/`, `RefCounted` only, no `Node`, no engine singletons (constitution §3).

| class | responsibility |
|---|---|
| `EconomySystem` | orchestrator; owns `tick_hour(ctx)`; registered on the per-game-hour cadence |
| `TaxAssessor` | per-building potential and actual revenue; foregone attribution by cause |
| `UtilityBilling` | tariff revenue from doc 04/05 delivery figures |
| `ExpenseLedger` | the ten expense lines of §2.4 (including `E_roads_repair`, RR-2); the daily accrual-vs-actual road reconciliation; austerity multiplier application |
| `Treasury` | int64 balance, credit line, deferred liability, austerity state machine, relief grants |
| `LandMarket` | `price_for_block()`, `development_phase_cost()`, purchase/resale validation |
| `CostCurves` | `upgrade_cost()`, `capital_value()`, `base_tax()`, `repair_cost()`, `pm_cost()` — pure functions |
| `BudgetSnapshot` | immutable per-hour struct handed to `ui/` |
| `OfflineYield` | `yield_mult(ctx.catchup_index)` published into doc 08's `OfflinePolicy` band; the one-off damage cap |
| `Difficulty` | loader and validator for `data/difficulty.json`; `Difficulty.get(section, key)` — the only difficulty read path in the project (C-17) |

**Tick entry point:** `EconomySystem.tick_hour(ctx: SimContext) -> void`. `ctx` carries `clock`, `rng.misc`, `catchup_index`, the doc-08 offline band, and read-only handles to the building/grid/water/dispatch/population registries.

**Commands handled** (from `ui/` via the command API):
`set_tax_rate`, `buy_land`, `sell_land`, `start_development_phase`, `demolish_building`, `sell_vehicle`, `mothball_station`, `reactivate_station`, `order_preventive_maintenance`, `hire_emergency_contractor`, `set_difficulty`, `acknowledge_relief_grant`.

**Events emitted:**
`economy_hour_settled`, `daily_settlement`, `treasury_threshold_crossed`, `austerity_entered`, `austerity_exited`, `credit_line_engaged`, `credit_limit_reached`, `deferred_liability_accrued`, `deferred_liability_cleared`, `relief_grant_awarded`, `land_purchased`, `land_sold`, `development_phase_started`, `development_phase_completed`, `tax_rate_changed`, `foregone_revenue_spike`.

---

## 5. Cross-System Interfaces

*Renumbered onto the canonical on-disk map (report 98 Ruling Zero). The pre-amendment version of this table used the "10 = construction / 11 = population / 07 = incidents / 08 = weather / 13 = persistence" map, which does not exist.*

**Reads (this doc is the consumer). Each is a per-game-hour value unless noted.**

| from | value | type / range |
|---|---|---|
| **01 Time** | per-game-hour cadence `EVERY_HOUR`; `ctx.channels.*`; the offline cap constant in `data/time.json` (12 real h = 720 gh) | |
| **02 Buildings** | `build_cost_l1`, `class`, `level`, `condition` | int, enum, 1–5, **0..1** (C-14) |
| **02 Buildings** | `k_dem` per growth class — **the requirement is `k_dem > TAX_LEVEL_GROWTH (2.15)` for every class**, strictly, not equality (report 98 RR-7) | doc 02 is the authority on the values (2.35 `steady` / 2.45 `standard` / 2.55 `vertical`, C-13); this doc ships only the floor `REQUIRED_MIN_DEMAND_LEVEL_GROWTH = 2.15`, **exclusive**. An equality constant of 2.35 rejected 9 of 12 archetypes (verification 96 F-8 / 97 F-11) |
| **02 Buildings / Construction** | project queue state, crew bindings, phase-completion callbacks (G-2: doc 02 owns the project record) | |
| **04 Power** | `power_availability_hour(building_id)` | 0..1, backup counts as available |
| **04 Power** | `delivered_mwh_hour`, `generation_mwh_by_plant_type`, `plant_efficiency_mult[level]` | float |
| **04 Power** | node inventory for `E_grid`: `rated_mva`, `condition`, `line_km`, `plant_capacity_mw` | **the only grid cost input** — doc 04 publishes no prices (C-07, C-12) |
| **04 Power** | `grid_margin_score`, `grid_redundancy_score` | 0..1, for Resilience Index |
| **04 Power** | `damage_fraction` per failure type (its old `cost_frac_of_build` table, re-read) | 0..1 (C-16) |
| **05 Water** | `water_service_factor_hour(building_id)` | 0..1 |
| **05 Water** | `delivered_m3_hour`, `m3_treated_hour`, `main_km`, `pump_capacity_m3h`, `water_margin_score`, `damage_fraction` per break type | |
| **06 Incidents / Dispatch / Fleet** | `vehicle_roster` (type, dispatched flag), `vehicle_km_this_hour`, `response_capacity_score`, `damage_fraction` per incident; **the payout SHAPE** — `(1 + tier_k·(tier_peak − 1)) × speed_bonus` — plus `target_ref`, the residual damage fraction and `manual_requested`, all of which this doc needs to price a resolve and to ceiling it (RR-78). *(`police_incidents_resolved_hour` deleted with the `fines` line — RR-78.)* | |
| **07 Weather / Director** | `damage_fraction` per hazard event, `fuel_weather_mult` | 0..1, ≥1.0 |
| **08 Persistence / Offline** | `ctx.catchup_index`; `OfflinePolicy.band_for(hour_index)` — the only signal that the sim is offline (C-20) | int, band |
| **09 Map / Land / Districts / Population** | block `distance_blocks (d)`, `dev_terrain`, `waterfront_edges`, `arterial_connections (n)`, `elevation_norm`, `prestige`, `env_risk_index (ERI)`, adjacency | the `LandPriceInputs` bundle |
| **09 …Population & Stability** | `occupancy(building_id)`, district `stability`, `city_stability`, city `happiness`, `city_level` | 0..1, **0..1** (C-56), 0..1, 0..100, int |
| **09 Map / Land** | starter city must yield **gross base tax $686/gh ±5%** at founding | the §2.12 pacing model is anchored to it |
| **10 Roads** | `access_quality(pos)` — the single tile-level road-access definition (C-61) | 0..1, feeds `a_b` |
| **10 Roads** | road **inventory and physics** for the §2.12(f) repair line: tile counts by class, `condition ∈ [0,1]` (RR-3), `base_decay` per class, the `(1 + 0.75·c_day)(1 + wx_wear_day)` decay modifiers, **the starter city's derived operating point `c_day = 0.35` ⇒ multiplier 1.2625 (RR-13)**, and `damage_fraction` per damage source | doc 10 publishes **no price** (RR-2); `upkeep_per_game_day() -> int` is **deleted** from its interface — there is no standing road upkeep to bill |

**Provides (this doc is the producer):**

| to | value |
|---|---|
| **02 Buildings** | `CostCurves.upgrade_cost()`, `capital_value()`, `base_tax()`; the `build_cost_l1` ladder (§2.13a) — doc 02 defines no cost, tax or upkeep column |
| **02 Construction** | affordability check + `Treasury.spend()` on project start; contractor surcharge pricing |
| **04 Power** | the grid component price ladder (§2.13b); `E_grid` billing; `FUEL_PRICE_PER_MWH`; `repair_cost(asset, damage_fraction)` |
| **05 Water** | `E_water` billing; `repair_cost(asset, damage_fraction)` |
| **06 Incidents / Fleet** | vehicle purchase / upkeep / `active_mult` / `dispatch_cost` / resale (§2.13c); austerity breakdown multiplier; `repair_cost()` in place of `cost_materials`; **`dispatch_payout(type, shape, manual, target_ref, residual)` and `prevented_loss_value()` (§2.13e / §2.5, RR-78)** — doc 06 holds no `reward_base` column |
| **07 Weather / Director** | `repair_cost(asset, damage_fraction)` — doc 07 quotes no repair totals and owns no `repair_cost_mult` (C-16, C-17) |
| **08 Persistence / Offline** | the `"economy"` save section and its hourly ring buffer; **`band.yield_mult`** populated from §2.11's exponential taper (C-20) |
| **09 Map / Land / Population** | `LandMarket.price_for_block()`, `development_phase_cost()`; `happiness_tax_delta = -(r - 0.09) × 360`; `growth_rate_multiplier = 1 - (r - 0.09) × 8.0`; **`attractiveness_tax_factor(r) = 1 + 1.30 × min(0, happiness_tax_delta)/100`** (doc 09 §2.10.2a, T-1); austerity flag |
| **10 Roads** | the **§2.13(d) per-tile road price ladder** (STREET/AVENUE build, upgrade, demolish refund, repair `capital_value` basis) — doc 10 holds no price column (RR-2); job pricing through `Treasury.spend()`; `repair_cost(tile, damage_fraction)`; **no standing upkeep is billed or billable** |
| **12 UI** | `BudgetSnapshot`, `net_display`, foregone-by-cause breakdown, Resilience Index, land TCO estimate |
| **All** | **`data/difficulty.json`** and `Difficulty.get(section, key)` (C-17) — including `M_rev / M_exp / M_land / M_dev / M_build / M_repair`. No other doc defines, loads or duplicates a difficulty scalar. |

**Non-negotiable contract:** every other system that spends or earns money does so through `Treasury.spend(amount, category, reason)` / `Treasury.earn(...)`. No system mutates the balance directly.

---

## 6. MVP Cut (spec §43)

**In the vertical slice:**

- Tax formula in full: all six multipliers + occupancy + tax-rate slider + difficulty.
- All ten expense lines of §2.4, including `E_roads_repair` (RR-2) and `E_debt` (credit line and interest ship, though debt is rare early).
- Power and water tariffs; police fines.
- Land purchase formula (all seven terms) and all six development phases with costs.
- Upgrade cost curve and capital value; demolition refund; preventive maintenance.
- Net income HUD + Budget panel + **Foregone Revenue line** (this is the teaching device; it is not optional).
- Offline taper published into doc 08's band, offline damage cap, WHILE YOU WERE AWAY financial summary.
- Four difficulty presets in `data/difficulty.json`, with the loader and its four validation rules (§3.4).
- The complete currency ladder of §2.13 — buildings, grid components, vehicles **and roads** — as the single source of every price in the project, with **no standing road upkeep** (RR-2).
- Austerity Mode, credit line, deferred liability, State Emergency Assistance, asset sales, mothballing.

**Deferred:**

- Stadium/event gate revenue, tourism, regional export contracts (spec §11.1) — formula stubs only.
- Bond issuance / player-chosen debt instruments (credit line is automatic-only in MVP).
- Per-district tax rates (citywide slider only in MVP).
- Insurance policies against disaster loss.
- Non-adjacent land purchase premium.
- Any IAP, premium currency, or rewarded-ad hook (constitution §7: no premium currency in MVP). The relief-cooldown ad in §2.10 is post-alpha and ships **disabled**.
- Economy analytics export beyond the local ring buffer.

---

## 7. Test Plan

Headless, `tests/sim/economy/`, run via `godot --headless --path . -s res://tests/run_tests.gd`.

**Formula correctness**
1. `test_tax_worked_example_a` — house L2, healthy inputs from §2.2 example A ⇒ 24 ±1.
2. `test_tax_worked_example_b` — outage inputs ⇒ 8 ±1; assert loss ≥ 60% of example A.
3. `test_tax_worked_example_c` — data center L3 ⇒ 9,061 ±10.
4. `test_tax_multiplier_bounds` — fuzz 10,000 random input vectors; assert `0 ≤ R_b ≤ base_tax × 1.25 × 1.778` always.
5. `test_class_floors_applied` — with `p=0`, tech ⇒ 0 revenue, residential ⇒ exactly 35% of the power term.
6. `test_city_revenue_floor` — drive every multiplier to minimum; assert city revenue ≥ 0.18 × potential.
7. `test_base_tax_yield_drift` *(was `test_base_tax_yield_invariant`; report 98 RR-5)* — for every entry in `buildings.json`, assert `abs(base_tax_l1 / (build_cost_l1 × TAX_YIELD[class]) − 1) ≤ 0.06`. **The published rows are normative and the yield map is a derivation aid**, so this is a drift guard, not an equality. Model values: house/apartment/highrise_res/highrise_com 0.00 %, factory 0.48 %, data_center 0.28 %, **store and office 4.76 % (the two largest, both inside the gate)**. Also assert the gate would *catch* a real defect: re-classing `data_center` to `residential` drifts **16.7 %** and fails — `2,100 / (180,000 × 0.0100) − 1 = 2,100/1,800 − 1 = +0.16667` (report 98 RR-18; the 14.5 % printed in Round 2 was `1 − 1,800/2,100`, the drift measured from the wrong side of the ratio — the test's own expression divides the published row by the yield estimate, so 16.7 % is the figure it actually produces).
8. `test_generated_columns_match_curves` — regenerate `base_tax_by_level`, `upgrade_cost_by_step`, `capital_value_by_level` and diff against committed data, **tolerance ±$1 per cell** (verification 97 §3.2: `highrise_res` L5, `data_center` L4/L5 are one dollar below half-up and are locked by RR-5).

**Land & development**
9. `test_land_price_example_d` ⇒ $12,400 exactly (after round-to-100).
10. `test_land_price_example_e` — block `B_0_6` (marsh, d=3, ERI 0.443, wf 3, n 0, prestige 0, elevation_norm 0, blocks_owned 9, standard) ⇒ **$6,700 exactly** (raw 6,700.87 before round-to-100). *Was $3,900 against an impossible d=5 block; recomputed per C-18 / R-05.*
11. `test_development_tco_inversion` — example E all-in ≥ **1.50 ×** example D all-in; assert the model values `dev(E) = 68,578`, `all_in(E) = 75,278`, `all_in(D) = 46,988`, ratio **1.602**. *Threshold lowered from 1.7 because the block moved from d=5 to d=3; the inversion is terrain-driven, not distance-driven, so it survives.*
12. `test_escalation_cap` — 200 blocks owned ⇒ escalation exactly 4.0.
13. `test_risk_hidden_before_survey` — `risk_index` query pre-survey returns a band, not a value.

**Treasury & recovery**
14. `test_no_money_lost_to_rounding` — 10,000 hours of settlement; assert `treasury + carry` equals exact rational sum within $1.
15. `test_austerity_enter_exit` — force negative treasury; assert expense mult 0.55, construction blocked, in-flight project still completes, exit at threshold.
16. `test_credit_limit_hard_floor` — attempt a spend exceeding the limit; assert treasury clamps and `deferred_liability` grows by the exact remainder.
17. `test_deferred_repayment` — with positive net income, deferred clears at 35%/hour and emits `deferred_liability_cleared`.
18. `test_relief_grant_gates` — grant fires only when all four conditions hold; never fires twice inside cooldown; never fires on crisis difficulty.
19. `test_bankruptcy_recovery_no_iap` — start a wrecked city (treasury −credit_limit, all buildings condition 0.2, grid 50% down); simulate 2,000 gh with only free tools; assert treasury > 0 and RI > 30. **This is the spec §37 acceptance test.**

**Offline**
20. `test_offline_yield_curve` — E(5)=4.99±0.05, E(20)=18.66±0.05, **E(60)=45.69±0.20**, E(240)=87.46±0.20, E(480)=93.55±0.20, **E(720)=93.97±0.10**. *Corrected per §2.11: the previously tabled 19.0 and 51.6 did not satisfy the stated integral, and the 10,080 gh row is unreachable under the 12-real-hour cap (C-19).*
21. `test_offline_uses_same_code_path` — 100 gh online vs 100 gh offline with `yield_mult` forced to 1.0 produce byte-identical treasury and event streams.
22. `test_offline_damage_cap` — inject damage worth 5× the cap; assert billed ≤ cap and the remainder appears as `unrepaired_assets` in the report.
23. `test_yield_reads_catchup_index` *(replaces `test_absence_reset`)* — assert the `economy` save section contains **no** `absence_hours_elapsed` key, that `OfflineYield.yield_mult()` takes its hour index from `ctx.catchup_index`, and that the value it returns is what appears in `OfflinePolicy.band_for(h).yield_mult` (C-20). Absence-reset semantics are doc 08's test, not this doc's.

**Determinism & persistence**
24. `test_economy_determinism` — same save + same elapsed offline time ⇒ identical treasury, twice (constitution §5).
25. `test_save_roundtrip` — serialize/deserialize the `"economy"` section; deep-equal.
26. `test_migration_v0_to_v1` — schema ladder runs without loss.

**Pacing (the balance regression suite)**
27. `test_pacing_model_10_hours` — a scripted player agent replays the §2.12 session/spend table; assert every session-end treasury within ±20% of the tabled value. Anchors after RR-13: S1 **$31,460**, S8 **$80,107**, S12 **$897,900**. *(Was S1 $33,170 / S8 $121,637 / S12 $972,787 at the `c_day = 0` road floor.)*
28. `test_guardrail_g1_g2` — treasury/daily-net ratio stays in `[1.5, 14]` per G1/G2; assert the peak is S7 at **11.48** and the floor is **S8 at 3.84** (the floor row moved off S1 under RR-13; S1 is 4.10).
29. `test_guardrail_g3_crunch` — at each defined tier, `growth + resilience ≥ 1.15 × treasury` and `min ≥ 0.45 × treasury`. At S8: treasury **341,107**, growth 261,000, resilience 222,600 ⇒ sum ratio **1.418**, min ratio **0.653**.
30. `test_guardrail_g4_offline_share` — offline/online cumulative income ratio ∈ [1.2, 2.0]; model value **1.242** (1,477,566 / 1,189,870).
31. `test_guardrail_g5_first_hour` — 120 gh from founding suffices for block + full development + 4 buildings; model value **$68,339 available against $59,988 required**.
32. `test_difficulty_monotonicity` — for identical play, final treasury strictly decreases across casual > standard > hard > crisis; also validates `data/difficulty.json` rule 4 (declared monotonic direction per knob).

**Currency ladder (C-07 / R-14)**
33. `test_single_price_table` *(respecified as key-based — report 98 RR-17)* — **parse** every `data/*.json`, walk the object tree, and collect the set of **JSON keys**. Assert that the price keys `build_cost`, `purchase_cost`, `upkeep_per_gh`, `upkeep_cents_per_hour`, `upkeep_per_game_day`, `dispatch_cost`, `repair_cost_base` and `cost_frac_of_build` occur as a key in **no** file except `data/economy.json` — at any nesting depth, and including keys that merely *end with* one of those names (`street_build_cost`, `avenue_upkeep_per_gh`) so the guard cannot be dodged by prefixing. This is the mechanical guard on "one currency authority".

    **String values are explicitly out of scope.** The assertion is on keys, never on file text: **`_note` / `_*_note` strings may name any of these tokens freely**, and several must — doc 10's `data/roads.json` carries `_pricing_owner_note` and `data/power.json` carries `_price_note`, both of which *list the deleted keys by name* so a reader finds the owner. A text grep fails those files for saying the right thing, which is the defect RR-17 corrects; the ownership pointers are the feature, not the violation. *(Extended for roads under RR-2 — the test previously failed on day one against `data/roads.json`, which shipped all four road price keys as real keys.)*
34. `test_grid_cost_rescale` — regenerate §2.13(b) from doc 04's capacity ladder with `GRID_COST_SCALE = 0.125` / `PLANT_COST_SCALE = 1/3` and the stated rounding rule; diff against committed data. Assert the two ruled anchors exactly: `substation L1 == 15000`, `plant_gas L1 == 60000`.
35. `test_vehicle_ratio_preservation` — assert `fire_engine.purchase == round(1.60 × patrol_car.purchase)` exactly, and that the five doc-06 MVP types are strictly ordered patrol < water < utility < construction < engine (the ratios C-07 preserved). Assert every `upkeep_per_gh` lies in `[0.00050, 0.00115] × purchase` (upper bound widened from 0.0011 so `construction_crew`'s 0.113 % passes — verification 97 §2.2).
36. `test_starter_fleet_line` — the doc-09 starter roster prices to **$58/gh** standby, matching §2.12's fleet line.
37. `test_e_grid_starter_inventory` — feed **doc 09 §2.9.5's** starter inventory (8.0 MW plant, 6.0 MVA substation, **2.25 MVA** of transformers = 7×L1 + 10×L2 + 1×L3, **1.416 km** of line = 177 tiles × 8 m, all condition 1.0) to `ExpenseLedger`; assert **`E_grid == 74.3 ± 0.5 $/gh`** and that no flat per-component upkeep is read from `data/power.json` (C-12). *Recomputed under RR-6 from the stale 2.05 MVA / 0.88 km / $73 set, then **re-centred by Wave 4's F-4 roster thinning** (23 → 18 nodes, 2.40 → 2.25 MVA); the tolerance stays **±0.5 on both sides** under RR-18 and doc 04 test 24 should move with it, since the two tests assert the identical band on the identical inventory. The derivation `40.000 + 24.000 + 9.000 + 1.274 = 74.274` sits 0.026 inside the new centre — the same 0.026 the old pair had, because only the transformer term moved.*
38. `test_repair_price_single_source` — for one asset of each kind (building, transformer, feeder, water main, **road tile**, vehicle), assert the charged repair equals `capital_value × damage_fraction × 0.85 × M_repair` and that the supplying doc contributed only `damage_fraction` (C-16). For the road tile, assert `capital_value == build_price × 0.20` (STREET 360, AVENUE 1,040).
39. `test_difficulty_file_schema` — `data/difficulty.json` loads; all four sections × four presets present; an injected fifth section and an injected nested value each raise a load error (§3.4 rules 1–3).

**Roads (report 98 RR-2)**

40. `test_road_prices_are_here` — `data/economy.json.roads` supplies STREET build 1,800, AVENUE build 5,200, upgrade 4,000; `data/roads.json` contains **no** `build_cost`, `upgrade_cost`, `upkeep_per_game_day` or `repair_cost_base` key (the roads half of test 33, asserted from this side).
41. `test_no_standing_road_upkeep` — run 240 settlements with a 783-tile core and assert `ExpenseLedger` books **zero** dollars under any `roads.upkeep` category, and that `sim/roads/` exposes no `upkeep_per_game_day()`. The only road money in a settlement is `E_roads_repair` and one-off job spend.
42. `test_road_repair_price` — a 12-tile STREET run at condition 0.40 charges `12 × 360 × 0.60 × 0.85 = $2,203`; a single fully failed AVENUE tile charges `1,040 × 1.00 × 0.85 = $884`; a `COLLAPSED` tile charges the **full** build price (5,200 / 1,800), not a repair.
43. `test_starter_road_repair_expectation` *(re-based on doc 10's operating point — report 98 RR-13)* — with the doc-09 core (540 AVENUE + 243 STREET), decay at doc 10's base rates, **`c_day = 0.35`** (decay multiplier **1.2625**), clear weather (`wx_wear_day = 0`) and `M_repair = 1.0`, assert the steady-state road-repair rate is **$185.9 ± 0.5 /gh**; assert it is **invariant to `auto_repair_threshold`** across {0.25, 0.40, 0.55} over 2,000 gh (the threshold changes lumpiness, not rate); and assert the underlying damage-fraction throughput equals doc 10 test 42's published **0.28548 tile-fractions/gh**, so both docs are asserting the same starter city rather than two different ones. Also assert the `c_day = 0` floor still evaluates to **$147.2 ± 0.5 /gh**, which pins the `(1 + 0.75·c_day)` coupling itself rather than just its value at one point. *(Was `c_day = 0` / $147.2 — a point doc 10's own arithmetic never uses.)*
44. `test_road_upgrade_costs_more_than_building_big` — `street.build + street_to_avenue.upgrade > avenue.build` (5,800 > 5,200), the same inequality §2.3 imposes on buildings.
45. `test_block_template_billed_once` — stamping a 87-tile block template during `road_install` produces exactly one `Treasury.spend()` of the §2.8 phase price and **zero** per-tile charges (the mirror of doc 10's test 42).
46. `test_one_difficulty_knob_per_ledger_line` *(new — doc 93 §N1/§N2)* — settle the §2.12 founding ledger on all four **live** `data/difficulty.json` `economic` rows and assert, per preset and against the `standard` settlement: the seven swept expense lines are exactly `× M_exp`; `roads_repair` is exactly `× M_repair` **and explicitly not `× M_repair × M_exp`**; `debt` takes neither; `tax` is exactly `× M_rev`; and `power_tariff` / `water_tariff` / `city_services` / `assistance` are exactly `× 1.000`. Reads the live file rather than transcribed constants, so a retune moves the expectation with the file and only a change of SCOPE fails. *(`fines` retired — RR-78. The two lines that replaced it join the same list for the same §2.5 reason: `M_rev` is the TAX multiplier.)*
47. `test_city_services_is_one_dollar_and_one_line` *(new — report 98 RR-78)* — resolve an incident on a live `CitySim` and assert three things at once: the treasury moved by the payout **immediately**, the next settlement's `revenue.city_services` names exactly that amount, and `Treasury.settle` was handed `revenue − city_services` so the same dollar was not banked twice. Also asserts `data/incidents.json` carries no `reward_base` key at any depth and `IncidentCatalog` refuses a file that carries it back — the RR-78 half of test 33.
48. `test_the_receipt_book_survives_a_save` *(new — RR-78)* — resolve an incident, save between the resolve and the hour's settlement, load, settle, and assert the `city_services` line is the same as an unsaved control's. A save taken mid-hour must not lose a line the income statement is about to print, and an older save (no `hour_city_services` key) must restore to 0 rather than to garbage.
49. `test_the_grants_are_paid_once_and_only_forward` *(new — report 98 RR-79)* — a city that crosses two city-level rungs in one move is paid BOTH grants; a city that crosses the same rung twice is paid once (`city_level` is monotone by `data/progression.json`); a city at level 0 is paid nothing. And the founding-assistance taper: `founding_assistance_per_hour(0) = 172.00`, `(3) = 98.29`, `(7) = 0.00`, `(99) = 0.00`.

---

## 8. Tunables

Two files, both owned by this doc: `data/economy.json` (everything except difficulty) and `data/difficulty.json` (§3.4).

### 8.1 `data/economy.json`

```json
{
  "meta": { "schema_version": 1, "doc": "03-economy.md", "units": "dollars per game-hour",
            "currency_authority": true,
            "note": "Sole price table for the project (report 98 C-07). No build_cost, purchase_cost, upkeep or repair-price column may exist in any other data file." },

  "tax": {
    "TAX_LEVEL_GROWTH": 2.15, "TAX_RATE_BASE": 0.09, "TAX_RATE_MIN": 0.04, "TAX_RATE_MAX": 0.16,
    "TAX_RATE_COOLDOWN_HOURS": 48, "TAX_RATE_HAPPINESS_COEFF": 360.0, "TAX_RATE_GROWTH_COEFF": 8.0,
    "TAX_RATE_ATTRACT_PULL": 1.30,
    "_attract_pull_note": "doc 09 amendment T-1. attractiveness_tax_factor(r) = 1 + 1.30 * min(0, happiness_tax_delta(r)) / 100 — the attractiveness CEILING the rate buys, where TAX_RATE_GROWTH_COEFF buys only the RATE at which doc 09 walks toward it. 1.0 at and below TAX_RATE_BASE; 0.6724 at TAX_RATE_MAX (coeff 360). Priced off happiness_tax_delta so the rate is read once in the coupling.",
    "_tax_level_note": "The player knob of §2.2 is the RATE r, bounded by TAX_RATE_MIN/MAX. cmd_set_tax_level exposes it as the discrete ladder MIN, MIN+STEP, ... , MAX so the UI has detents; 13 levels, and level 5 lands exactly on TAX_RATE_BASE. The ladder is computed in basis points so no float drift can move a detent off its authored rate. This is the tax RATE ladder and is unrelated to TAX_LEVEL_GROWTH, which is base_tax growth per BUILDING level.",
    "TAX_RATE_STEP": 0.01,
    "OCCUPANCY_RAMP_HOURS": 36,
    "_stability_note": "S is [0,1] from doc 09 (C-56). f_stability = STAB_FLOOR + (1-STAB_FLOOR) * S^STAB_EXP. No /100.",
    "STAB_FLOOR": 0.25, "STAB_EXP": 0.70,
    "HAPPY_SLOPE": 0.50, "HAPPY_FACTOR_MIN": 0.75, "HAPPY_FACTOR_MAX": 1.25, "COND_FLOOR": 0.40,
    "_tax_yield_note": "DESCRIPTIVE ONLY (RR-5). The published base_tax_by_level rows in data/buildings.json and the $686/gh starter anchor are normative; this map documents why the L1 rows have the shape they do and is checked by test 7 as a +/-6% drift guard, never as an equality. Max drift today is 4.76% (store, office).",
    "TAX_YIELD": { "residential": 0.0100, "commercial": 0.0105, "industrial": 0.0095, "tech": 0.0117 },
    "TAX_YIELD_DRIFT_TOLERANCE": 0.06,
    "_road_note": "f_road consumes doc 10's access_quality(pos) in [0,1] (C-61). This doc defines no road_access_factor.",
    "utility_floors": {
      "residential": { "power": 0.35, "water": 0.45, "road": 0.85 },
      "commercial":  { "power": 0.10, "water": 0.35, "road": 0.55 },
      "industrial":  { "power": 0.15, "water": 0.20, "road": 0.60 },
      "tech":        { "power": 0.00, "water": 0.10, "road": 0.80 }
    }
  },

  "upgrades": {
    "UPG_COEFF": 1.15, "UPG_GROWTH": 2.55, "DEMOLITION_REFUND_FRACTION": 0.25,
    "_demand_growth_note": "RR-7: the requirement is an EXCLUSIVE FLOOR, not an equality. Every doc-02 growth class must satisfy k_dem > REQUIRED_MIN_DEMAND_LEVEL_GROWTH. Doc 02 is the authority on the values (2.35 steady / 2.45 standard / 2.55 vertical, C-13). The old REQUIRED_DEMAND_LEVEL_GROWTH: 2.35 equality constant is DELETED - it rejected 9 of 12 archetypes.",
    "REQUIRED_MIN_DEMAND_LEVEL_GROWTH": 2.15,
    "REQUIRED_MIN_DEMAND_LEVEL_GROWTH_EXCLUSIVE": true,
    "CAPITAL_VALUE_V": [1.000, 2.150, 5.083, 12.560, 31.629, 80.254]
  },

  "roads": {
    "_note": "Sole road price table (report 98 RR-2, extending C-07). data/roads.json carries build_cost, upgrade_cost, upkeep_per_game_day and repair_cost_base in NO form. Doc 10 owns road work and physics - crew-hours, condition on [0,1] (RR-3), decay rates, damage fractions - and no prices.",
    "_no_upkeep_note": "ROADS CARRY NO STANDING PER-TILE UPKEEP IN MVP, mirroring C-08. The recurring cost of a road is decay bought back through the C-16 repair formula; see 2.12(f) for the derived starter expectation of $185.87/gh over the 783-tile core, evaluated at doc 10's published starter operating point c_day = 0.35 (RR-13). The $147.22/gh figure Round 2 booked is the c_day = 0 FLOOR, which the sim never observes.",
    "build_cost_per_tile":   { "STREET": 1800, "AVENUE": 5200 },
    "upgrade_cost_per_tile": { "STREET_TO_AVENUE": 4000 },
    "ROAD_REPAIR_CAPITAL_FRACTION": 0.20,
    "_repair_basis_note": "capital_value(road tile) = build_cost_per_tile * ROAD_REPAIR_CAPITAL_FRACTION -> STREET 360, AVENUE 1040. Repair re-buys the wearing course and the top of the base, not the excavation, sub-base, utility corridor or right-of-way. A 1.00 basis prices the starter core's routine maintenance at $929.35/gh at c_day 0.35 = 110.7% of gross revenue ($736.12 even at the c_day 0 floor); see 2.5 and 2.12(f).",
    "collapsed_rebuild_uses_full_build_cost": true,
    "demolish_refund_fraction": 0.25,
    "_demolish_note": "Same DEMOLITION_REFUND_FRACTION as buildings: STREET $450, AVENUE $1300 per tile."
  },

  "expenses": {
    "BUILDING_MAINT_RATE": 0.00040, "MAINT_CONDITION_PENALTY": 1.5, "DEPT_LEVEL_GROWTH": 1.75,
    "MOTHBALL_UPKEEP_FRACTION": 0.15, "MOTHBALL_REACTIVATE_HOURS_OF_UPKEEP": 14.4,
    "VEHICLE_RESALE_FRACTION": 0.40, "ASSET_CONDITION_PENALTY_COEFF": 2.0,
    "GRID_MAINT_PER_MW_HOUR": 4.0, "LINE_MAINT_PER_KM_HOUR": 0.9, "PLANT_OM_PER_MW_HOUR": 5.0,
    "WATER_TREAT_COST_PER_M3": 0.06, "WATER_MAIN_MAINT_PER_KM_HOUR": 0.7, "PUMP_OM_PER_M3H_HOUR": 0.35,
    "REPAIR_COST_PER_CAPITAL": 0.85, "PM_COST_FRACTION": 0.06, "PM_MIN_CONDITION": 0.50, "PM_CREW_HOURS": 2,
    "_repair_note": "repair_cost = capital_value * damage_fraction * REPAIR_COST_PER_CAPITAL * M_repair (C-16). Docs 02/04/05/06/07 supply damage_fraction only and hold no price table.",
    "RESTORE_COST_FRACTION": 0.20,
    "SALVAGE_FRACTION": 0.15,                          // Wave 19 - what a RUIN is worth
    "_salvage_note": "salvage_value = capital_value(level_at_destruction) * SALVAGE_FRACTION (Wave 19, doc 92 sec 57.2.2, doc 93 sec AQ2). Closed form: DEMOLITION_REFUND_FRACTION 0.25 - doc 02 sec 2.12's authored 0.10 clearance. Credited, not charged.",
    "_restore_note": "restore_cost = capital_value(level_at_destruction) * RESTORE_COST_FRACTION * M_repair (Wave 18, doc 92 sec 54, doc 93 sec AN). Replaces doc 02's authored 0.60/72h pair, which no caller ever read. Floor: 0.17 = the repair a maintaining player buys.",
    "CONTRACTOR_SURCHARGE": 1.80, "CONTRACTOR_TIME_FRACTION": 0.35,
    "RUSH_SURCHARGE_PER_DURATION": 1.23077,
    "_rush_derivation": "§2.13(f): (CONTRACTOR_SURCHARGE − 1) / (1 − CONTRACTOR_TIME_FRACTION). Re-checked at load.",
    "FUEL_COST_PER_KM": { "light": 0.6, "medium": 1.1, "heavy": 1.9 },
    "FUEL_PRICE_PER_MWH": { "gas": 38, "diesel": 95, "coal": 30, "nuclear": 9, "solar": 0, "wind": 0, "hydro": 0 },
    "plant_efficiency_mult": { "gas": [1.000, 0.935, 0.871, 0.806, 0.758] },
    "_station_staffing_note": "RR-16: where E_grid or E_water already bills a facility's O&M, that service's department line is STAFFING ONLY and says so here. water_works 20 is staffing only - the water works' plant O&M is E_water's pump_capacity_m3h * PUMP_OM_PER_M3H_HOUR ($14.00/gh on the starter pump). Power plants and substations carry NO station_upkeep row at all: E_grid's PLANT_OM_PER_MW_HOUR and GRID_MAINT_PER_MW_HOUR bill them in full (C-08 no-double-billing). No value changed under RR-16.",
    "station_upkeep_l1": { "police_station": 26, "fire_station": 30, "utility_depot": 24,
      "water_works": 20, "construction_yard": 20, "ems_station": 28, "hospital": 45 },
    "station_upkeep_is_staffing_only": ["water_works"],

    "_vehicle_note": "Sole vehicle price table (C-07 / R-14). purchase for the five doc-06 MVP types = round_to_100(9000 * (purchase_06/45000)^0.32631), anchored so fire_engine = 1.60 x patrol_car. dispatch_cost = round(2.4 * upkeep). upkeep and active_mult are authored per role.",
    "VEHICLE_PURCHASE_COMPRESSION_GAMMA": 0.32631,
    "DISPATCH_COST_UPKEEP_MULT": 2.4,
    "VEHICLE_UPKEEP_FRACTION_BAND": [0.00050, 0.00115],
    "vehicles": {
      "patrol_car":            { "purchase": 9000,  "upkeep": 7,  "active_mult": 2.5, "dispatch_cost": 17, "fuel_class": "light" },
      "water_repair_truck":    { "purchase": 11100, "upkeep": 9,  "active_mult": 2.5, "dispatch_cost": 22, "fuel_class": "medium" },
      "utility_service_truck": { "purchase": 11500, "upkeep": 9,  "active_mult": 2.5, "dispatch_cost": 22, "fuel_class": "medium" },
      "construction_crew":     { "purchase": 12400, "upkeep": 14, "active_mult": 2.0, "dispatch_cost": 34, "fuel_class": "medium" },
      "supervisor":            { "purchase": 14000, "upkeep": 10, "active_mult": 2.5, "dispatch_cost": 24, "fuel_class": "light" },
      "fire_engine":           { "purchase": 14400, "upkeep": 12, "active_mult": 3.0, "dispatch_cost": 29, "fuel_class": "heavy" },
      "pump_truck":            { "purchase": 18000, "upkeep": 13, "active_mult": 2.5, "dispatch_cost": 31, "fuel_class": "medium" },
      "bucket_truck":          { "purchase": 20000, "upkeep": 14, "active_mult": 2.5, "dispatch_cost": 34, "fuel_class": "medium" },
      "road_crew":             { "purchase": 20000, "upkeep": 16, "active_mult": 2.0, "dispatch_cost": 38, "fuel_class": "heavy" },
      "rescue":                { "purchase": 22000, "upkeep": 15, "active_mult": 3.0, "dispatch_cost": 36, "fuel_class": "medium" },
      "ladder_truck":          { "purchase": 26000, "upkeep": 18, "active_mult": 3.0, "dispatch_cost": 43, "fuel_class": "heavy" },
      "heavy_equipment_crew":  { "purchase": 30000, "upkeep": 22, "active_mult": 2.0, "dispatch_cost": 53, "fuel_class": "heavy" },
      "heavy_repair_truck":    { "purchase": 34000, "upkeep": 20, "active_mult": 2.5, "dispatch_cost": 48, "fuel_class": "heavy" },
      "crane_crew":            { "purchase": 42000, "upkeep": 28, "active_mult": 2.0, "dispatch_cost": 67, "fuel_class": "heavy" },
      "mobile_transformer":    { "purchase": 48000, "upkeep": 24, "active_mult": 2.0, "dispatch_cost": 58, "fuel_class": "heavy" }
    },

    "_grid_cost_note": "Rescaled from doc 04 onto this ladder (C-07). Doc 04's build_cost, upkeep_per_gh and fuel_cost_per_kwh columns are deleted; recurring grid cost is E_grid above, generation fuel is FUEL_PRICE_PER_MWH.",
    "GRID_COST_SCALE": 0.125,
    "PLANT_COST_SCALE": 0.33333,
    "grid_components": {
      "plant_gas":     { "build_cost": [60000, 127000, 253000, 500000, 967000] },
      "plant_solar":   { "build_cost": [73300, 167000, 317000, 600000, 1033000] },
      "plant_wind":    { "build_cost": [86700, 187000, 350000, 633000, 1100000] },
      "substation":    { "build_cost": [15000, 32500, 65000, 131000, 263000] },
      "transformer":   { "build_cost": [500, 1100, 2800, 6900, 16300, 41500] },
      "feeder":        { "cost_per_tile_overhead": [110, 210, 400], "underground_cost_mult": 2.6 },
      "transmission":  { "cost_per_tile": [730, 1200, 2000] },
      "battery":       { "build_cost": [17500, 40000, 87500, 188000, 400000], "_status": "post_mvp" },
      "backup_gen":    { "build_cost": { "S": 2300, "M": 7800, "L": 26300 } },
      "tie_switch":    { "build_cost": 3500 },
      "flood_wall":    { "build_cost_per_level": 5600 },
      "surge_arrester":{ "build_cost_fraction_of_host": 0.09 }
    }
  },

  "tariffs": { "POWER_TARIFF_PER_MWH": 62, "WATER_TARIFF_PER_M3": 0.55 },

  "city_services": {                                   // §2.5, report 98 RR-78
    "dispatch_payout_base": { "crime": 350, "structure_fire": 900,
      "transformer_failure": 600, "water_main_break": 500,
      "traffic_accident": 300, "storm_damage": 400 },  // doc 06 §2.7's column, MOVED not retuned
    "MANUAL_DISPATCH_MULT": 1.50,                      // = doc 06's own speed_bonus_max
    "MANUAL_DISPATCH_LEVEL_K": 0.90,                   // Wave 19 - the premium stops shrinking
    "MORAL_HAZARD_CAP_FRACTION": 0.75,
    "MORAL_HAZARD_UNPRICED_CEILING": 3900,             // 0.75 × a COLLAPSED AVENUE rebuild
    "street_payout": {                                 // §2.5, report 98 RR-81 — MOVED from
      "petty_crime":    { "base": 260, "spread":  90 },//   data/street.json at the same values
      "loose_animal":   { "base": 150, "spread":  60 },
      "lost_valuables": { "base": 420, "spread": 180 } },
    "STREET_REWARD_CITY_LEVEL_K": 0.25,                // MOVED with them (a term in a $ formula);
                                                       // 0.20 -> 0.25 in Wave 19, fitted against
                                                       // MODEL_NET_PER_HOUR_BY_CITY_LEVEL
    "STREET_MAX_RATE_PER_GAME_HOUR": 0.70,             // ceiling on 1/target_interval_h
    "STREET_CEILING_SHARE_MAX": 0.40,                  // every offer taken, vs the opening's net
    "STREET_PLAYED_SHARE_BAND": [0.05, 0.20],          // measured on a 21-day arc (RR-82)
    "STREET_IDLE_SHARE": 0.0                           // a written-down zero
  },

  "grants": {                                          // §2.5a, report 98 RR-79 / RR-187 / RR-197
    "FOUNDING_ASSISTANCE_PER_HOUR": 172,               // = §2.12 departments 96 + fleet 76
    "FOUNDING_ASSISTANCE_DAYS": 7,
                                                       // Wave 24: rung k pays k million (§2.5a)
    "LEVEL_UP_GRANT_BY_CITY_LEVEL":
        [0, 1000000, 2000000, 3000000, 4000000, 5000000, 6000000, 7000000],
                                                       // Wave 24: the back-pay seed (§2.5a.1),
                                                       // keyed on doc 08 §2.8's section version
    "LEVEL_UP_GRANT_SUPERSEDED_BY_SAVE_VERSION": {
      "0": [0, 2500, 7000, 9000, 22500, 37000, 83000],
      "9": [0, 45000, 65000, 95000, 145000, 215000, 325000, 5000000]
    }
  },

  "land": {
    "LAND_BASE": 9000, "DIST_DECAY": 4.0, "DIST_FLOOR": 0.55, "RISK_DISCOUNT": 0.45,
    "WATERFRONT_PREMIUM": 0.55, "ROAD_ADJ_PREMIUM": 0.09, "PROX_COEFF": 0.35, "ELEV_COEFF": 0.20,
    "LAND_ESCALATION": 0.06, "STARTER_BLOCKS_FREE": 9, "ESCALATION_CAP": 4.0,
    "NONADJACENT_PREMIUM": 1.60, "LAND_RESALE_FRACTION": 0.55, "PRICE_ROUNDING": 100,
    "PRE_SURVEY_RISK_UNCERTAINTY": 0.20,
    "terrain_mult": { "flat": 1.00, "gentle": 1.08, "hilly": 1.30, "steep": 1.65,
      "rocky": 1.45, "forest": 1.05, "marsh": 0.80, "island": 1.90 }
  },

  "development": {
    "ROAD_ACCESS_DISCOUNT_PER_CONNECTION": 0.15,
    "phases": [
      { "id": "survey",            "base": 1200, "dist_coeff": 0.02, "hours": 4 },
      { "id": "clearing",          "base": 3000, "dist_coeff": 0.03, "hours": 8 },
      { "id": "grading",           "base": 4500, "dist_coeff": 0.03, "hours": 12 },
      { "id": "road_install",      "base": 7500, "dist_coeff": 0.16, "hours": 14 },
      { "id": "utility_corridor",  "base": 9000, "dist_coeff": 0.22, "hours": 16 },
      { "id": "final_development", "base": 5000, "dist_coeff": 0.05, "hours": 6 }
    ],
    "terrain_phase_mult": {
      "flat":   [1.00, 1.00, 1.00, 1.00, 1.00, 1.00],
      "gentle": [1.00, 1.05, 1.25, 1.10, 1.05, 1.00],
      "hilly":  [1.05, 1.20, 2.20, 1.50, 1.20, 1.05],
      "steep":  [1.15, 1.40, 3.40, 2.10, 1.45, 1.10],
      "rocky":  [1.10, 1.80, 2.80, 1.60, 1.55, 1.05],
      "forest": [1.00, 1.90, 1.30, 1.15, 1.10, 1.00],
      "marsh":  [1.10, 1.60, 2.60, 1.90, 1.40, 1.25],
      "island": [1.30, 1.30, 1.50, 4.50, 3.20, 1.20]
    }
  },

  "offline": {
    "_note": "This doc owns the economic curve only. Absence detection, the minimum-absence threshold, the session-start reset and the offline cap are doc 08 / doc 01 mechanism (C-19, C-20). OFFLINE_MIN_MINUTES and SESSION_START_SECONDS are deleted from this file.",
    "OFF_FULL_HOURS": 4, "OFF_TAU_HOURS": 90,
    "HOUR_INDEX_SOURCE": "ctx.catchup_index",
    "PUBLISHES_TO": "OfflinePolicy.band_for(h).yield_mult",
    "TAPER_APPLIES_TO": ["revenue", "recurring_expenses"],
    "TAPER_EXEMPT": ["construction", "repairs", "crew_work", "condition_decay", "population", "weather", "incidents"]
  },

  "_difficulty_note": "MOVED — every difficulty knob now lives in data/difficulty.json (C-17, §3.4). This file defines none.",

  "recovery": {
    "AUSTERITY_EXPENSE_MULT": 0.55, "AUSTERITY_DECAY_MULT": 2.5, "AUSTERITY_VEHICLE_BREAKDOWN_MULT": 2.0,
    "AUSTERITY_EXIT_DAYS_OF_EXPENSE": 0.5, "CREDIT_LIMIT_FLOOR": 20000, "CREDIT_LIMIT_DAYS_OF_REVENUE": 6,
    "DEFERRED_CONDITION_PENALTY_PER_1000": 0.004, "DEFERRED_REPAY_FRACTION": 0.35,
    "RELIEF_COOLDOWN_HOURS": 120, "RELIEF_TRIGGER_CREDIT_FRACTION": 0.5, "RELIEF_DAYS_OF_REVENUE": 1.5,
    "RELIEF_MIN": 8000, "RELIEF_MAX": 250000,
    "RELIEF_AD_COOLDOWN_REDUCTION_HOURS": 24, "RELIEF_AD_ENABLED": false
  },

  "presentation": {
    "NET_DISPLAY_EMA_ALPHA": 0.25, "ECONOMY_HISTORY_HOURS": 168,
    "DAILY_SETTLEMENT_GAME_HOUR": 6, "CASH_BUFFER_TARGET_DAYS": 5,
    "resilience_index_weights": { "grid_margin": 0.30, "grid_redundancy": 0.20, "water_margin": 0.15,
      "response_capacity": 0.15, "condition": 0.10, "cash_buffer": 0.10 }
  },

  "pacing_guardrails": {
    "_round2_note": "Restated under report 98 RR-6. Every starter line below is derived from the owning doc's published inventory: tax from doc 09's t0 f_stability 0.9722 x f_happiness 1.110 = 1.07914 (NOT the old assumed 0.90 aggregate); E_grid from doc 09 2.9.5 (2.40 MVA, 1.416 km); E_water from the C-34 rescale (40 m3/h pump); roads from RR-2. STARTER_POWER_TARIFF and STARTER_GAS_FUEL are still HELD pending doc 04's RR-10 delivered-MWh restatement.",
    "_round3_note": "RR-13: the road-repair line is re-priced at doc 10's published starter operating point c_day = 0.35 (decay multiplier 1 + 0.75*0.35 = 1.2625), not the c_day = 0 floor. Road line 147.22 -> 185.87, per-block term 16.35825 -> 20.65229, expense 482 -> 521, net 357 -> 319, and the S1-S12 rows and G1-G5 all re-ran. ALL FIVE GUARDRAILS HOLD, so no expense constant was retuned: ROAD_REPAIR_CAPITAL_FRACTION stays 0.20 and PACING_ROUND2_K stays 1.35200.",
    "STARTER_GROSS_TAX_PER_HOUR": 686, "STARTER_GROSS_TAX_TOLERANCE": 0.05,
    "STARTER_T0_AGGREGATE_MULT": 1.07914,
    "STARTER_TAX_REVENUE_PER_HOUR": 740,
    "STARTER_GROSS_REVENUE_PER_HOUR": 839,
    "STARTER_GROSS_REVENUE_PER_HOUR_EXACT": 839.349412,
    "STARTER_EXPENSE_PER_HOUR": 521, "STARTER_NET_PER_HOUR": 319,
    "_exact_pair_note": "The _EXACT pair is the AS-INTEGRATED ledger doc 93 sec E2 owns (live doc-05/doc-06/doc-10 inventories, and the fleet-billing ruling), NOT this doc's sec 2.12 arithmetic. The unsuffixed 521/319 are this doc's own published round figures and do not move; tests/test_balance_gates.gd gates 1-2 hold the sim to the _EXACT pair and tests/test_economy.gd holds this doc to its own.",
    "STARTER_EXPENSE_PER_HOUR_EXACT": 504.176677, "STARTER_NET_PER_HOUR_EXACT": 337.047860,
    "STARTER_FIRST_GAME_DAY_NET_EXACT": 8004.047,
    "STARTER_E_GRID_PER_HOUR": 74.27,
    "STARTER_E_GRID_TEST_TOLERANCE": 0.5,
    "STARTER_E_WATER_PER_HOUR": 15.39,
    "STARTER_DEPARTMENTS_PER_HOUR": 96,
    "STARTER_ROAD_REPAIR_PER_HOUR": 185.87,
    "STARTER_ROAD_C_DAY": 0.35,
    "STARTER_ROAD_DECAY_MULT": 1.2625,
    "_road_operating_point_note": "RR-13: c_day and the multiplier are DOC 10's (10 sec 2.3 / 2.12, test 42); this file records them so the ledger line is reproducible, and owns neither. multiplier = 1 + 0.75*c_day at wx_wear_day 0. The c_day 0 floor is 147.22/gh; test 43 asserts both points so the coupling is pinned, not just its value.",
    "STARTER_ROAD_REPAIR_PER_HOUR_AT_C_DAY_0": 147.22,
    "STARTER_ROAD_TILES": { "AVENUE": 540, "STREET": 243, "total": 783 },
    "PACING_ROUND2_K": 1.35200,
    "_k_rounding_note": "PACING_ROUND2_K was derived against the ROUNDED $839 gross AND against the pre-Wave-4 non-road expense (334.706, before F-4 took $0.60 off E_grid), so the founding sanity check (1.35200*373 - 20.65229*9 = 318.43) sits $0.95/gh below the ledger's directly computed 319.37. Re-deriving at (839.349412 - 334.106)/373 = 1.35454 would close both and move all 23 rows by ~0.5%; RR-13 did not ask for that, no pass since has done it, and the model tolerance (test 27) is +/-20%. Recorded, not absorbed.",
    "PACING_K_PER_DISTRICT_VARIANT": 1.36378,
    "_k_per_district_note": "RR-18: the sensitivity constant for doc 09's tax-weighted f_stability 0.977524 (tax 744.34). Corrects Round 2's 1.36285, which reproduced from no consistent input set. NOT used by the shipped model, which uses the ruled 0.9722 path; unrounded arithmetic lands on 1.363799 and the ruled 1.36378 is published.",
    "PACING_ROAD_PER_DEVELOPED_BLOCK": 20.65229,
    "PACING_BLOCKS_DEVELOPED_BY_SESSION": [9, 9, 10, 10, 10, 11, 11, 11, 11, 11, 12, 13],
    "_deleted": "PACING_GRID_CORRECTION_MULT 0.90097 - superseded by PACING_ROUND2_K plus the per-block road term (RR-6). PACING_ROAD_PER_DEVELOPED_BLOCK 16.35825 - the c_day 0 value, superseded by 20.65229 (RR-13).",
    "G1_MAX_DAYS_OF_NET_BANKED": 14, "G2_MIN_DAYS_OF_NET_BANKED": 1.5,
    "G3_MIN_PACKAGE_SUM_VS_TREASURY": 1.15, "G3_MIN_SINGLE_PACKAGE_VS_TREASURY": 0.45,
    "G4_OFFLINE_ONLINE_RATIO_RANGE": [1.2, 2.0], "G5_FIRST_BLOCK_AFFORDABLE_BY_HOUR": 120,
    "MODEL_SESSION_END_TREASURY": [31460, 57346, 49050, 95542, 131233, 145237, 206147, 80107, 237325, 466573, 777932, 897900],
    "MODEL_TCO_RATIO_E_OVER_D": 1.602, "MODEL_G4_RATIO": 1.242,
    "MODEL_G1_PEAK_RATIO": 11.48, "MODEL_G1_PEAK_SESSION": "S7",
    "MODEL_G2_FLOOR_RATIO": 3.84, "MODEL_G2_FLOOR_SESSION": "S8",
    "MODEL_G5_AVAILABLE_BY_HOUR_120": 68339, "MODEL_G5_REQUIRED": 59988,
    "MODEL_G3_S8": { "treasury": 341107, "growth": 261000, "resilience": 222600, "sum_ratio": 1.418, "min_ratio": 0.653 }
  }
}
```

### 8.2 `data/difficulty.json`

```json
{
  "meta": { "schema_version": 1, "owner_doc": "03-economy.md",
            "presets": ["casual", "standard", "hard", "crisis"],
            "sections": { "economic": "03", "pressure": "07", "escalation": "06", "offline": "08" } },

  "economic": {
    "_direction": { "M_rev": "down", "M_exp": "up", "M_land": "up", "M_dev": "up", "M_build": "up",
                    "M_repair": "up", "starting_treasury": "down", "OFF_TAU_HOURS": "down",
                    "offline_damage_cap_fraction": "up", "REV_FLOOR_FRACTION": "down",
                    "CREDIT_APR_PER_GAME_DAY": "up", "relief_grants_per_era": "down" },
    "casual":   { "M_rev": 1.15, "M_exp": 0.85, "M_land": 0.85, "M_dev": 0.85, "M_build": 0.90, "M_repair": 0.70, "starting_treasury": 35000, "OFF_TAU_HOURS": 120, "offline_damage_cap_fraction": 0.10, "REV_FLOOR_FRACTION": 0.25, "CREDIT_APR_PER_GAME_DAY": 0.004, "relief_grants_per_era": 4 },
    "standard": { "M_rev": 1.00, "M_exp": 1.00, "M_land": 1.00, "M_dev": 1.00, "M_build": 1.00, "M_repair": 1.00, "starting_treasury": 25000, "OFF_TAU_HOURS": 90,  "offline_damage_cap_fraction": 0.20, "REV_FLOOR_FRACTION": 0.18, "CREDIT_APR_PER_GAME_DAY": 0.008, "relief_grants_per_era": 3 },
    "hard":     { "M_rev": 0.92, "M_exp": 1.12, "M_land": 1.15, "M_dev": 1.15, "M_build": 1.10, "M_repair": 1.35, "starting_treasury": 18000, "OFF_TAU_HOURS": 75,  "offline_damage_cap_fraction": 0.30, "REV_FLOOR_FRACTION": 0.14, "CREDIT_APR_PER_GAME_DAY": 0.014, "relief_grants_per_era": 2 },
    "crisis":   { "M_rev": 0.85, "M_exp": 1.25, "M_land": 1.30, "M_dev": 1.30, "M_build": 1.20, "M_repair": 1.60, "starting_treasury": 12000, "OFF_TAU_HOURS": 60,  "offline_damage_cap_fraction": 0.45, "REV_FLOOR_FRACTION": 0.10, "CREDIT_APR_PER_GAME_DAY": 0.022, "relief_grants_per_era": 0 }
  },

  "pressure": {
    "_owner": "07-weather-disaster-director.md",
    "_keys": ["tp_rate_mult", "cooldown_mult", "severity_mult", "warning_lead_mult"],
    "_note": "Doc 07 authors these four rows. repair_cost_mult is DELETED — repair difficulty is economic.M_repair (C-17).",
    "casual": {}, "standard": {}, "hard": {}, "crisis": {}
  },

  "escalation": {
    "_owner": "06-incidents-dispatch.md",
    "_keys": ["escalation_mult", "OFFLINE_RESPONSE_TIME_MULT"],
    "_seed_from_doc_03": { "OFFLINE_RESPONSE_TIME_MULT": { "casual": 1.2, "standard": 1.6, "hard": 1.9, "crisis": 2.2 } },
    "casual": {}, "standard": {}, "hard": {}, "crisis": {}
  },

  "offline": {
    "_owner": "08-offline-persistence.md",
    "_keys": ["difficulty_offline_mult"],
    "casual": {}, "standard": {}, "hard": {}, "crisis": {}
  }
}
```

Empty preset objects above are placeholders for rows the owning doc authors; the loader (§3.4 rule 1) rejects the file until every section has all four presets populated. `OFFLINE_RESPONSE_TIME_MULT` was authored here originally and is handed to doc 06 as a seed, because it is a dispatch knob and C-17 puts each row with its owner.

---

## 9. Conflicts & Open Questions

### Conflicts with the constitution

1. **Sub-dollar precision vs constitution §7 ("whole dollars, int64").** A $12/gh house cannot be represented per-building in whole dollars without material rounding drift. Resolution used here: the **treasury** is strictly whole-dollar `int64` (constitution honoured); per-building revenue is computed in float, summed, rounded once per settlement, and the remainder carried in an `int64` millidollar accumulator. No money is created or destroyed. Flagging because it is an interpretation, not a deviation — confirm it is acceptable.

2. **Spec §41.5 says "collect taxes"; this doc makes revenue continuous. — RULED, APPROVED (report 98 C-59).** No longer an open deviation. Continuous accrual plus a Daily Settlement card stands; the onboarding beat becomes *review the ledger* (doc 12); `economy.manual_collection` is deleted rather than defaulted false.

3. **Difficulty as pure multipliers vs spec §35 ("Difficulty should change pressure, not just multiply values"). — RESOLVED STRUCTURALLY (C-17).** §2.9 is multiplicative because that is what an economy doc can own; the pressure-shaping half is now *guaranteed* to exist because `data/difficulty.json` reserves named sections for doc 07 (pressure), doc 06 (escalation) and doc 08 (offline), and the loader refuses to start with them empty. The knobs can no longer fall between docs — a missing row is a load error.

### Cross-doc dependencies that will break if ignored

4. **Doc 02's `k_dem` must exceed this doc's `TAX_LEVEL_GROWTH = 2.15` in every growth class — strictly.** *(Restated under report 98 RR-7.)* If any class picks a demand growth ≤ 2.15, upgrades become efficiency-positive for that class and spec §55 rule 3 / Pillar 5 collapses. This is the single most important cross-doc constant in the game's balance. **The requirement is the inequality, and the shipped constant is `REQUIRED_MIN_DEMAND_LEVEL_GROWTH = 2.15` (exclusive).** This doc previously demanded equality with 2.35, which C-13's three per-class values (2.35 `steady` / 2.45 `standard` / 2.55 `vertical`) fail for 9 of 12 archetypes — a loader honouring it literally would have rejected `apartment`, `office`, `high_rise`, `data_center`, both stations, both utility shells and `construction_yard` (verification 96 F-8 / 97 F-11). Doc 02 owns the values; this doc owns only the floor.

5. **Doc 02 must not define its own upgrade cost curve.** `CostCurves.upgrade_cost()` is authoritative; doc 02 supplies only `build_cost_l1` and `class`.

6. **Doc 09's starter city must hit $686/gh gross base tax (±5%).** The entire §2.12 pacing table is anchored to it. C-11 confirms the original 18/5/3/1 mix evaluates to exactly $686/gh against this doc's rows, so no re-run is owed on that account.

6b. **One starter line was owed and has now been paid; one pair is still held.** *(Updated under RR-6.)*
   - **`departments 116 → 96 $/gh` — RESOLVED.** This line was held pending doc 09's post-C-11 manifest. That manifest has landed, and the answer is the "96" reading: `police_station 26 + fire_station 30 + water_works 20 + construction_yard 20`. `PLANT-1` and `SUB-A` are not stations — they are billed by `E_grid`'s plant O&M and node maintenance, and adding a department line for them is the C-08 double-charge. `utility_depot` does not exist in the starter city.
   - **`fines 3/350` — RESOLVED, and it was never a placeholder for a missing measurement.** *(Wave 15, report 98 RR-78.)* It was a placeholder for a measurement doc 06 was already taking and crediting straight to the treasury, where no ledger line named it. `CitySim.HELD_FINE_RATE` and `POLICE_FINE_PER_RESOLVED_INCIDENT` are deleted; the live `city_services` line replaces them, and the founding day's real figure is **$38.38/gh** against the held $3.00. The lesson for the pair still held below: a held line whose sibling doc has an implementation is worth checking, not just waiting on.
   - **`power tariff 93` / `gas fuel 57` — STILL HELD.** Both imply a ~1.5 MWh/gh starter load. Doc 09's R-16 result now publishes the **402.0 kW building nameplate** and the **783.3 kW night peak**, but neither is the 24-hour **delivered** figure this pair needs: that requires the 24-hour mean of doc 01's `streetlight_load` channel (on 19:00–07:00 only, so materially below 1.000 over the day) and doc 04's loss model, and doc 04 owes exactly that restatement under **RR-10**. The two figures sit on opposite sides of the ledger and move together, so net movement is small and holding them is safer than guessing. **Re-derive the pair when doc 04 lands RR-10.** A first-order estimate (mean building load 402.0 kW + signals 48.6 kW + streetlights at a ~0.5 duty ≈ 137 kW ⇒ ~0.59 MWh/gh delivered) would move tariff 93 → ~37 and gas fuel 57 → ~24, i.e. net −$24/gh; it is recorded as a *magnitude*, not applied.

6c. **Doc 04's starter transformer mix — CLOSED.** This doc previously *assumed* 14 × L1 + 9 × L2 = 2.05 MVA to reproduce C-12's "~2.1 MVA" gloss. Doc 09 §2.9.5 now **publishes** the real fleet — 13 × L1 + 9 × L2 + 1 × L3 = **2.40 MVA** over 23 units, with the L3 forced by `WTR-1`'s 132 kW site load under C-35 — plus **177 line tiles = 1.416 km**. §2.4 reads those figures; nothing is assumed. Doc 04's test 24 expectation moves from `73 ± 1` to **`74.9 ± 0.5`**, and this doc's test 37 carries the identical band (report 98 RR-18 — the two tolerances were `± 0.5` and `± 1` on the same assertion, which is one tolerance too many for one number).

7. **Doc 04 must report `power_availability_hour` as a time-weighted fraction of the settled hour**, not an instantaneous boolean. Sub-hour outages are the core cascade signal; a boolean would erase two-thirds of the drama in worked example B.

8. **Doc 06 must expose `vehicle_km_this_hour`.** Without it, fuel is a flat fee and dispatch distance stops mattering economically.

8b. **Nothing outside `data/economy.json` may carry a price.** After C-07 this is mechanically testable (test 33). The columns deleted from other docs, and where a reader should now look: doc 02 `build_cost` / `upkeep_cents_per_hour` / `Tax $/gh` → §2.13(a) and §2.2; doc 04 `build_cost` / `upkeep_per_gh` / `fuel_cost_per_kwh` → §2.13(b), §2.4 `E_grid`, §2.4 `FUEL_PRICE_PER_MWH`; doc 06 `purchase_cost` / `upkeep_per_game_hour` / `dispatch_cost` / `repair_material_base` / **`reward_base` (RR-78)** → §2.13(c), §2.13(e) and §2.5; docs 02/04/05/07 repair prices → §2.5.

### Open questions for the overseer

9. **Is ~55% of income arriving offline acceptable for the intended identity?** The taper caps any single absence at ~94 game-hours, but offline still out-earns active play **1.242:1** across the Round-3 model (1,477,566 offline against 1,189,870 online = 55.4 % of total). Lowering `OFF_TAU` to 60 would flip it to roughly parity at the cost of punishing players who cannot check in twice daily. I have set 90 as the compromise; this is a product call, not a math call. Note the C-19 cap (12 real hours) does not bind here — the taper ceiling of ~94 gh is reached at ~6 real hours, well inside it.

9b. **The 10-hour end state doubled, and that is a real balance question. (New, RR-6.)** Round 1 modelled the arc on an *assumed* 0.90 aggregate tax multiplier; doc 09's owned t0 factors give **1.079**, a 19.9 % uplift that compounds through every session, while the new road-repair line grows only 44 % across the arc. The result was an end state of **$973K** against Round 1's $470K; **RR-13's road re-pricing has since pulled it back to $898K**, still roughly double Round 1. Every guardrail still passes (G1 peak **11.48** / 14, G2 floor **3.84** / 1.5, G3 sum **1.418** / 1.15), and I have not fudged the revenue chain to hide it — but the §11.3 crunch is measurably softer, and if the overseer wants Round 1's shape back the honest levers are, in order of preference: **(a)** doc 09 raises its `happiness.norms` `city_stability` centre 0.85 → 0.95, which lands `H` near 76 and the aggregate near 1.04; **(b)** re-size the S8 packages upward against the larger treasury — **note RR-13 has already recovered part of this**: the S8 decision-point treasury falls $382,637 → $341,107 and the package sum ratio rises 1.264 → 1.418, so lever (b) is now the least urgent of the three; **(c)** accept it — a 62 %-vacant starter core is *supposed* to be a generous first ten hours (goal 2 in §1), and G1 is the guard against "too loose", not the target. **Not** a lever: discounting `f_happiness` here, which would put a second, contradictory happiness model in this doc.

10. **Should the tax-rate slider be citywide only in MVP, or per-district?** Per-district rates create genuinely interesting gentrification/flight play, but they multiply the doc-09 happiness surface and the UI cost. Deferred here; happy to promote.

11. **Should there be a hard treasury ceiling or a "surplus pressure" mechanic?** Guardrail G1 detects a too-loose economy but does nothing about it in a real playthrough where a player hoards. Options: escalating land prices (already present), a civic-pressure mechanic where large idle surpluses reduce happiness ("why aren't you fixing anything?"), or nothing. Recommend nothing for MVP, revisit after playtest.

12. **`REPAIR_COST_PER_CAPITAL = 0.85` may be too punishing for high-level assets.** Repairing a fully damaged L5 high-rise costs $625K. That could be correct drama or could feel like a bricked asset. Suggest a level-scaled variant (`0.85 - 0.05×(L-1)`) if playtest says it stings too hard.

13. **Does the State Emergency Assistance grant undermine tension?** It is capped, cooldowned, limited to 3 uses, and absent on crisis. I believe it is the right answer to spec §37.2 ("making recovery effectively impossible without payment" is the failure mode to avoid), but it is the mechanic most likely to be seen as a hand-hold. Alternative: replace the grant with a longer-term repayable **relief loan** at 0% interest. Happy to switch.

14. **Is a 17–52× gap between the `road_install` phase price and the per-tile road ladder acceptable? (New, RR-2.)** Stamping a block's 87-tile template costs $6,930–$21,090 through §2.8's `road_install` phase; the same 87 tiles priced per tile are **$360,600**. RR-2 ruled the per-tile magnitudes in (street 1,800 / avenue 5,200) and this doc has adopted them unchanged, on the reading that the two prices answer different questions — a development contract that lays a whole block at once versus piecework on demand — and that the gap is what makes player-drawn roads a considered purchase instead of free paint. It is nonetheless the largest unexplained ratio left anywhere in the ladder, and one of three things should eventually happen: raise `PHASE_BASE[road_install]`, lower the per-tile prices, or record the gap as intentional. My recommendation is the third, with `ROAD_ADJ_PREMIUM` and the AVENUE gate (C-62) already doing the work of making avenues feel expensive.

15. **Is `ROAD_REPAIR_CAPITAL_FRACTION = 0.20` the right basis? (New in RR-2; band re-swept under RR-13.)** It is argued in §2.5 from how road maintenance actually works (resurfacing re-buys the wearing course, not the earthworks) and corroborated twice in §2.12(f) — against doc 10's independently authored standing upkeep (`c_day = 0` floor $147.22 vs $157.28/gh, **6.4 % apart**) and against `BUILDING_MAINT_RATE` as a rate on capital (0.644–0.966 % vs 0.96 % per game-day at the operating point, which is *closer* than Round 2's 0.51–0.77 %). But it is a constant this doc introduced, it now moves **$743/gh** at founding (`929.35 − 185.87`), and it deserves an explicit sign-off rather than inheritance.

    **The sweep, re-stated at `c_day = 0.35`.** The road line is linear in the fraction *and* in the decay multiplier — it is `736.12 × fraction × (1 + 0.75·c_day)` — so the pacing model depends on the two only through their product, and Round 2's sweep translates exactly by dividing each break point by **1.2625**:

    | fraction (Round 2 sweep, `c_day = 0`) | equivalent fraction at `c_day = 0.35` | G2 floor |
    |---|---|---|
    | 0.20 | **0.1584** | 3.86 |
    | 0.2525 | **0.20 ← shipped** | **3.84** |
    | 0.26 | 0.2059 | 3.58 |
    | 0.30 | 0.2376 | 2.15 |
    | **0.32** | **0.2535** | **1.38 — G2 breaks at S8** |

    So the usable band narrows from roughly `[0.10, 0.31]` to roughly **`[0.08, 0.245]`**, and the shipped 0.20 now sits at **79 % of the break point** rather than 63 %. It is still not a value tuned to the edge, and the G2 floor it produces (3.84) is 2.6× the guardrail minimum — but the honest reading is that RR-13 consumed most of this constant's headroom, and a future ruling that raises `c_day` again (a busier city, a snow season averaged in) will reach the break. If the overseer wants that headroom back, lowering the fraction is the lever, and it is exactly linear.

---

## Amendments applied (report 98)

| ruling | change made in this doc |
|---|---|
| **Ruling Zero** | Header numbering note replaced with the canonical on-disk map; §5's whole cross-reference table renumbered (10 = roads not construction, 09 = population/land not construction, 06 = incidents/dispatch/fleet, 07 = weather/director, 08 = persistence/offline); every in-text reference to "doc 11 population", "doc 08 risk_index", "doc 10 construction" and "doc 07 damage" retargeted in §2.2, §2.4, §2.5, §2.7, §2.8, §2.10, §2.11 and §9. |
| **C-07** | New **§2.13 — the complete currency ladder**, published as sole authority: (a) building `build_cost_l1` (unchanged, doc 02's column deleted); (b) grid components rescaled from doc 04 with `GRID_COST_SCALE 1/8` and `PLANT_COST_SCALE 1/3` (substation L1 $15,000, plant_gas L1 $60,000, transformer 500/1,100/2,800/6,900/16,300, feeder 110/210/400 per tile, transmission 730/1,200/2,000 per tile, plus battery, backup gen, tie switch, flood wall); (c) the definitive 15-row vehicle roster with purchase, upkeep, `active_mult`, new `dispatch_cost` and fuel class. |
| **C-12** | §2.4 `E_grid` stated as the only recurring electrical cost, with doc 04's flat `upkeep_per_gh` deleted and the starter inventory worked to **$73/gh**. §2.12 starter expenses restated **306 → 347 $/gh**, net **+414 → +373 $/gh**, and the entire S1–S12 pacing table regenerated by `net_new = round(0.90097 × net_old)` with every flow and treasury column recomputed (end state $707K → **$469,521**). |
| **C-16** | §2.5 rewritten: `repair_cost = capital_value × damage_fraction × 0.85 × M_repair` is the single repair price in the project, with a table mapping each deleted model (doc 02's condition formula, doc 04's `cost_frac_of_build`, doc 05's `base_cost × (0.5+severity)`, doc 06's `repair_material_base`, doc 07's quoted totals) onto the `damage_fraction` those docs now supply. |
| **C-17** | §2.9 rewritten around **`data/difficulty.json`**, owned here: four sections (`economic` 03, `pressure` 07, `escalation` 06, `offline` 08), four presets, five schema rules, one loader `Difficulty.get()`. Schema in new §3.4, contents in new §8.2; the `difficulty` block removed from `data/economy.json`; doc 07's `repair_cost_mult` recorded as deleted. |
| **C-18 / R-05** | Worked example E rewritten against a real block — `B_0_6` (A7), marsh, d=3, ERI 0.443, wf 3, n 0 ⇒ **$6,700** (raw 6,700.87) instead of the geometrically impossible d=5 / $3,900. Example F regenerated at d=3 (development $80,350 → **$68,578**, all-in **$75,278**, inversion ratio 1.602). Pacing row S5 one-off 14,500 → **17,300**, row S6 85,200 → **73,428**. Tests 10 and 11 recomputed. |
| **C-20** | §2.11 rewritten: this doc owns the economic curve and publishes it into doc 08's `OfflinePolicy` band `yield_mult`; `absence_hours_elapsed` deleted from the save section; `h = ctx.catchup_index`; `OFFLINE_MIN_MINUTES` and `SESSION_START_SECONDS` deleted with a pointer to doc 08. Offline table restated to the C-19 12-hour cap and its two wrong rows (E(20), E(60)) corrected. Test 23 replaced. |
| **C-25** | Save-section key `schema_version` → **`section_version`**. Doc 03 was omitted from C-25's amend list but carried exactly the colliding key the ruling forbids; applied and flagged in §3.3. |
| **C-56** | `f_stability = 0.25 + 0.75 × S^0.70` with **`S ∈ [0,1]`** owned by doc 09; the `/100` deleted from the formula, the reference table restated on the ruled scale (numerically identical), and worked examples A/B/C updated to S = 0.82 / 0.61 / 0.88. |
| **C-59** | Auto-accrual recorded as **approved**, not proposed: §2.1 states the ruling, §9 item 2 changed from "needs sign-off" to "RULED", and `economy.manual_collection` is confirmed absent from `data/economy.json`. |
| **C-61** | `f_road`'s `a_b` is now doc 10's **`access_quality(pos)`**; this doc's `road_access_factor` is deleted. §2.7's `A_factor` explicitly distinguished from it as a block-level development attribute. |
| **R-04** | Starter expense line and net restated with full arithmetic; the whole S1–S12 table, all four guardrail checks (G1/G2 per-session table, G3 at S8, G4 at 1.279) and the S8 crunch itemisation regenerated. |
| **R-14** | Vehicle costs onto this ladder with a stated, reproducible rule: `purchase = round_to_100(9,000 × (purchase_06 / 45,000)^0.32631)`, γ chosen so `fire_engine = 1.60 × patrol_car` exactly, doc 06's rank order preserved (patrol 9,000 < water 11,100 < utility 11,500 < construction 12,400 < engine 14,400). `dispatch_cost = round(2.4 × upkeep)` added. Starter fleet line verified unchanged at $58/gh. |
| **new tests** | §7 grew from 32 to 39 cases: 33 single-price-table grep guard, 34 grid rescale regeneration, 35 vehicle ratio preservation, 36 starter fleet line, 37 `E_grid` starter inventory, 38 repair single-source, 39 difficulty file schema. |

### Round 2 — post-verification rulings (report 98 §14)

Applied after the adversarial verification pass (docs 96 structural / 97 numeric). Four rulings are this doc's: **RR-2, RR-5, RR-6, RR-7.**

| ruling | change made in this doc |
|---|---|
| **RR-2** | **Roads join the currency monopoly.** New **§2.13(d)** publishes the per-tile road ladder — `STREET` build **$1,800**, `AVENUE` build **$5,200**, `STREET→AVENUE` upgrade **$4,000**, demolish refund `0.25 ×` build, `COLLAPSED` rebuild at full build price — adopting doc 10's magnitudes onto this ladder; `data/roads.json` loses `build_cost`, `upgrade_cost`, `upkeep_per_game_day` and `repair_cost_base`, and §7 test 33 is extended to grep for the last two so it passes as written. **Roads carry NO standing per-tile upkeep** (mirroring C-08); the §5 "provides" row deletes `upkeep_per_game_day()` from doc 10's interface and new test 41 asserts zero dollars are ever booked under a road-upkeep category. §2.5 defines `capital_value(road tile) = build price × **`ROAD_REPAIR_CAPITAL_FRACTION` 0.20**` (STREET $360, AVENUE $1,040) as a per-asset-class capital definition inside C-16, not a second repair formula. New §2.12(f) **derives** the routine road-repair expectation over doc 09's 783-tile core from doc 10's decay rates (AVENUE 0.0060, STREET 0.0090 per game-day on the RR-3 `[0,1]` scale) and C-16 pricing: `540×1,040×0.0060×0.85/24 + 243×360×0.0090×0.85/24 = 119.34 + 27.88 = ` **$147.22/gh**, cross-checked against doc 10's own deleted upkeep ($157.28/gh, 6.4 % apart) and against `BUILDING_MAINT_RATE` as a rate on capital. The 1.00-basis figure (**$736.12/gh = 99.4 % of gross revenue**) is recorded so the basis is not silently re-litigated. New `roads` block in `data/economy.json`; new tests 40–45; new §9 items 14 and 15. |
| **RR-5** | **`TAX_YIELD` demoted to a documented derivation aid; the published rows and the $686 anchor are LOCKED normative.** §2.2's yield-anchor paragraph is rewritten with the full eight-row drift table (max drift **4.76 %**, store and office) and states outright that conforming to the map would move the anchor to $698 and break C-11. §7 **test 7 becomes `test_base_tax_yield_drift`, a ±6 % guard** with an added negative case (a mis-classed `data_center` drifts ~~14.5 %~~ **16.7 %** and fails — *figure corrected in place by RR-18; see test 7*). `TAX_YIELD_DRIFT_TOLERANCE: 0.06` and a `_tax_yield_note` ship in §8. The three L4/L5 half-up nits (`highrise_res` L5, `data_center` L4/L5) are **not** changed — the rows are locked — and test 8 carries a ±$1 tolerance instead. |
| **RR-6** | **Starter ledger restated with every post-amendment input at once, and S1–S12 re-run.** §2.4's `E_grid` moves onto doc 09 §2.9.5's real inventory (**2.40 MVA** transformers, **1.416 km** line) → **$74.87/gh** (was $73; doc 04 test 24's ±1 fails and moves to ~~`74.9 ± 1`~~ **`74.9 ± 0.5`** — *tolerance harmonised in place by RR-18; both docs now assert the same band*). §2.12 restates: gross tax **617 → 740** on doc 09's t0 `f_stability 0.9722 × f_happiness 1.110 = 1.07914` replacing the assumed 0.90; departments **116 → 96** (the §9 6b hold released now doc 09's manifest landed — plant and substation are `E_grid`, not departments); `E_water` **10 → 15.39** (treat 0.334 + mains 1.058 + pump O&M 14.000, the C-34 rescale finally reaching this table); water tariff **7 → 3**; new road line **+147.22**. Founding: revenue **720 → 839**, expense **347 → 482**, net **+373 → +357**. New regeneration rule `net_r2 = round(K 1.35200 × net_r1 − 16.35825 × blocks_developed)` — proportional for city-scaling lines, **per-block for roads**, because the road network grows only when a block is developed. All 23 rows, the G1/G2 table, G3, G4 and G5 recomputed: **S1 $33,890 → $33,170**, **S8 $87,436 → $121,637**, **S12 $469,521 → $972,787**; G1 peak 12.77 → **12.55**, G2 floor **3.86**, G3 at S8 sum 1.388 → **1.264** / min 0.639 → **0.582**, G4 1.279 → **1.250**, G5 **$72,124 available vs $59,988 required**. **All five guardrails hold, so no expense constant was retuned to make them hold.** §9 6c closed; 6b's tariff/fuel pair explicitly held pending doc 04's RR-10; new §9 item 9b records that the end state doubled and names the three honest levers. |
| **RR-7** | `DEMAND_LEVEL_GROWTH` becomes an **exclusive floor**. §5's "must equal 2.35" row and §9 item 4 restated as **`k_dem > TAX_LEVEL_GROWTH (2.15)` for every growth class**, with doc 02 named as the authority on the three values. `data/economy.json` ships **`REQUIRED_MIN_DEMAND_LEVEL_GROWTH: 2.15`** plus `REQUIRED_MIN_DEMAND_LEVEL_GROWTH_EXCLUSIVE: true`; `REQUIRED_DEMAND_LEVEL_GROWTH: 2.35` is **deleted** (it rejected 9 of 12 archetypes). §1 goal 3 restated with the three per-class efficiency losses (8.5 % / 12.2 % / 15.7 %) instead of a single "9 %". |

**Deletions in the Round 2 pass, with ownership pointers.** `data/roads.json`'s `build_cost` / `upgrade_cost` / `repair_cost_base` → **§2.13(d)**; `data/roads.json`'s `upkeep_per_game_day` and doc 10's `upkeep_per_game_day()` API → **deleted outright, not moved** (roads have no standing upkeep — the recurring charge is §2.12(f)'s repair expectation); doc 10's `ROAD_REPAIR_COST_BASE 600` → **§2.5**'s `capital_value × damage_fraction × 0.85`; this doc's `REQUIRED_DEMAND_LEVEL_GROWTH 2.35` → **`REQUIRED_MIN_DEMAND_LEVEL_GROWTH 2.15`, exclusive**; this doc's `PACING_GRID_CORRECTION_MULT 0.90097` → **`PACING_ROUND2_K 1.35200` plus `PACING_ROAD_PER_DEVELOPED_BLOCK 16.35825`** *(the per-block term is 20.65229 after RR-13)*.

### Round 3 — closing-audit rulings (report 98 §15)

The closing audit's four economy rulings: **RR-13, RR-16, RR-17, RR-18.** One moves numbers (RR-13); the other three make existing decisions legible and correct three stale figures.

| ruling | change made in this doc |
|---|---|
| **RR-13** | **The road-repair ledger line is re-priced at doc 10's operating point, and the pacing model re-run.** Doc 10 owns congestion physics and publishes the starter city's derived point as **`c_day = 0.35`** ⇒ decay multiplier `1 + 0.75 × 0.35 = ` **1.2625**; Round 2 booked the line at the `c_day = 0` *floor*, a point doc 10's own §2.3 accrual and test 42 never use. §2.4 and **§2.12(f)** re-derive per class: AVENUE `540 × 1,040 × 0.0060 × 1.2625 × 0.85 / 24 = 150.66675`, STREET `243 × 360 × 0.0090 × 1.2625 × 0.85 / 24 = 35.20387` ⇒ **`E_roads_repair` $147.22 → $185.87/gh** (equivalently `147.22425 × 1.2625`), and **`PACING_ROAD_PER_DEVELOPED_BLOCK` 16.35825 → 20.65229** (`185.87057 / 9`). Founding ledger: expense **482 → 521**, net **+357 → +319** (`839.349412 − 520.576566 = 318.772846`). All 23 pacing rows regenerated on `net_r3 = round(1.35200 × net_r1 − 20.65229 × blocks_developed)`: **S1 $33,170 → $31,460**, **S8 $121,637 → $80,107**, **S12 $972,787 → $897,900** (end state $973K → **$898K**). Guardrails re-run: **G1 peak 12.55 → 11.48** (S7), **G2 floor 3.86 (S1) → 3.84 (S8)** — the binding row moves to the crunch, where the design intends it — **G3 at S8 treasury $382,637 → $341,107, sum 1.264 → 1.418, min 0.582 → 0.653**, **G4 1.250 → 1.242** (offline 1,477,566 / online 1,189,870), **G5 $68,339 available vs $59,988 required**. **All five hold, so nothing was retuned**: `ROAD_REPAIR_CAPITAL_FRACTION` stays 0.20 and `PACING_ROUND2_K` stays 1.35200. §7 test 43 re-based on `c_day = 0.35` ⇒ **$185.9 ± 0.5/gh**, with the doc 10 test 42 accrual (0.28548 tile-fractions/gh) and the `c_day = 0` floor both asserted so the two docs pin the same starter city; tests 27–31 re-anchored. §9 item 15's basis sweep re-stated at the operating point (break point 0.32 → **0.2535**, usable band `[0.10, 0.31]` → **`[0.08, 0.245]`**, shipped 0.20 now at 79 % of break). §8 ships `STARTER_ROAD_C_DAY 0.35`, `STARTER_ROAD_DECAY_MULT 1.2625` and the floor value alongside the operating value. |
| **RR-16** | **`water_works 20` labelled staffing-only.** §2.4's `E_departments` gains a *Staffing-only lines* paragraph and §2.12(b) states it at the point of use: the water works' plant O&M is already billed by `E_water`'s `pump_capacity_m3h × PUMP_OM_PER_M3H_HOUR` ($14.00/gh on the starter pump), so the department line buys operators only — the same exclusion `PLANT-1` and `SUB-A` get from `E_grid`, now stated rather than implied. `data/economy.json` gains `_station_staffing_note` and `station_upkeep_is_staffing_only: ["water_works"]`. **No number changes**; the ledger's `$96/gh` and the `20` itself are untouched. |
| **RR-17** | **Test 33 respecified as key-based.** `test_single_price_table` now **parses** each `data/*.json` and asserts the eight price names appear as **JSON keys** in no file but `data/economy.json` — at any nesting depth, including keys that end with one of the names, so prefixing cannot dodge it. **`_note` strings may name the tokens freely**, and must: doc 10's `_pricing_owner_note` and doc 04's `_price_note` list the deleted keys precisely so a reader finds the owner, and a text grep would fail both files for saying the right thing. **No data changes** — the guard's intent is unchanged, its implementation is now the one that can actually pass. |
| **RR-18** | **Three stale figures corrected, one tolerance harmonised.** (i) §7 **test 7**'s negative case is **16.7 %**, not 14.5 % — `2,100 / (180,000 × 0.0100) − 1 = +0.16667`; the old figure measured the drift from the wrong side of the ratio (`1 − 1,800/2,100`), while the test's own expression divides the published row by the yield estimate. (ii) The **founding net line is shown from unrounded components on both sides**: `839.349412 − 520.576566 = 318.772846`, replacing Round 2's rounded-`$839`-minus-unrounded-expense subtraction; the ledger block now prints revenue to three decimals. (iii) The **per-district `K` sensitivity constant is re-derived to 1.36378** (Round 2's 1.36285 reproduces from no consistent input set and is 0.07 % low), with the full chain shown from the tax-weighted `f_stability 0.977524`; unrounded arithmetic lands on 1.363799 and the **ruled 1.36378 is what this doc publishes**. The constant is not used by the shipped model. (iv) The **`E_grid` test tolerance is ±0.5 on both sides** — §7 test 37, §2.4's Round-2 correction note and §9 item 6c all now read `$74.9 ± 0.5/gh`, identical to doc 04 test 24. Related: the RR-5 and RR-6 changelog rows above are annotated in place rather than rewritten, matching how doc 04 handled its own stale C-12 row. |

### Wave 15 — the money pass (report 98 RR-78 / RR-79 / RR-80)

| ruling | change |
|---|---|
| **RR-78** | **The last dollar column joins the currency monopoly, and the double-booking doc 06 asked about in Wave 1 is closed.** `reward_base` is deleted from `data/incidents.json` and lands here as **§2.13(e)** / `city_services.dispatch_payout_base`, at the same six values — doc 06 keeps the SHAPE of a payout (`tier_k`, the speed bonus) and this doc owns every dollar in it, the same split C-16 uses for repairs. `IncidentCatalog.FORBIDDEN_KEYS` gains `reward_base` so the boot refuses a file that carries it back, and §7 test 33's key list gains it too. **`POLICE_FINE_PER_RESOLVED_INCIDENT` and `CitySim.HELD_FINE_RATE` are RETIRED with the `fines` ledger line**: they were the same dollar as `reward_base[crime]` and only doc 06's was live, so doc 03's half printed a flat $3.00/gh forever (doc 93 §N1 point 3's measurement) while the real money reached the treasury unnamed. Doc 93 §N1 point 4's re-open condition is met. New **`city_services`** revenue line — ONE line for dispatch and street both, with `city_services_by_source: {dispatch, street}` inside it exactly as `tax_by_class` sits inside `tax` — plus `MANUAL_DISPATCH_MULT 1.50` (doc 06's own `speed_bonus_max`, paid only through `cmd_dispatch_unit`), the **moral-hazard ceiling** `MORAL_HAZARD_CAP_FRACTION 0.75` against `capital_value(target) − repair_cost(target, residual)`, and `MORAL_HAZARD_UNPRICED_CEILING 3900` for the three types whose targets this doc prices no capital for. **The ceiling BINDS on shipped numbers**: a tier-5 fire in a house L1 paid 2.73× the loss it prevented. Street opportunity prices (`petty_crime 180 < dispatch crime 350`, by ruling) and the `STREET_MAX_RATE_PER_GAME_HOUR 0.45` income-share contract are authored here for the same C-07 reason. New §7 tests 47 and 48; new balance gates 31 and 32. |
| **RR-79** | **The early-income retune: two state grants, both published constants, neither farmable.** New **§2.5a**. `FOUNDING_ASSISTANCE_PER_HOUR 172` — §2.12's own `departments` 96 + `fleet` 76, the two operating lines the player is billed for and never chose, 34.1 % of a founding city's expense bill — tapering to zero over `FOUNDING_ASSISTANCE_DAYS 7` on `clamp(1 − day/7, 0, 1)`, booked as the `assistance` revenue line. `LEVEL_UP_GRANT_BY_CITY_LEVEL [0, 2500, 7000, 9000, 22500, 37000, 83000]`, derived as *half of what the next chapter asks you to buy* against doc 09 §2.14's curriculum, paid once per level on whichever route earned it, as a one-off receipt and not an hourly line. **Founding ledger: gross `839.349412 → 1008.349412`, net `319.372846 → 488.372846`, game-day `+$7,665 → +$11,721`; not one expense line moves.** As-integrated anchors: `STARTER_NET_PER_HOUR_EXACT 337.047860 → 506.047860` (exactly +169.00) and `STARTER_FIRST_GAME_DAY_NET_EXACT 7380.320908 → 12357.320908` (+4,977.00, of which $921.00 is RR-78's arrears). `STARTER_EXPENSE_PER_HOUR_EXACT` is deliberately NOT re-stamped. New §7 test 49. |
| **RR-80** | **Gate 4's money column moves from the stock to the flow.** The retune raised the opening's income and both agents spent it, differently — so `treasury_end` inverted (`balanced` $81,950 → $58,612 against neglect's $55,624 → $80,532) at the same time as `value created` un-inverted. Neither flip is the maintenance knob: a stock measures how much an agent chose not to spend. `net_mean_per_hour` is what condition drives through `f_condition`, it separates the pair by **12–20 % on all three seeds in both arms**, and it is the column gate 5 already uses one comparison up. No constant moved. |

**Numbers that moved in Round 3.** `E_roads_repair 147.22 → 185.87 $/gh` · `road line per developed block 16.35825 → 20.65229` · `starter expense 482 → 521 $/gh` · `starter net +357 → +319 $/gh` · `daily net +8,568 → +7,650` · `S1 treasury 33,170 → 31,460` · `S8 treasury 121,637 → 80,107` · `S12 treasury 972,787 → 897,900` · `G1 peak 12.55 → 11.48` · `G2 floor 3.86 (S1) → 3.84 (S8)` · `G3 S8 treasury 382,637 → 341,107, sum 1.264 → 1.418, min 0.582 → 0.653` · `G4 1.250 → 1.242` · `G5 available 72,124 → 68,339` · `1.00-basis road line 736.12 → 929.35 $/gh` · `test 7 negative case 14.5 % → 16.7 %` · `per-district K 1.36285 → 1.36378` · `E_grid test tolerance ±1 → ±0.5` · `test 43 c_day 0 / $147.2 → c_day 0.35 / $185.9`.

**Numbers that did NOT move in Round 3, and why.** Every price in §2.13 (RR-13 changes what a road *wears*, not what it costs to build); `ROAD_REPAIR_CAPITAL_FRACTION 0.20` and `PACING_ROUND2_K 1.35200` (no guardrail broke, so nothing was retuned); the `$686` starter anchor and every `base_tax_by_level` row (LOCKED by RR-5); `E_grid $74.87`, `E_water $15.39` and departments `$96` (RR-16 relabels, it does not reprice); the one-off spend column and the S8 package contents (RR-13 changes what the player *has*, not what they are offered); and the R1-net column of the pacing table, which is the Round-1 baseline the regeneration rule reads.
