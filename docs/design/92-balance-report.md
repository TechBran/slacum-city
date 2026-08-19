# 92 — Balance report: first harness pass

**Status:** DATA + RECOMMENDATIONS. Nothing in `data/` was changed by this pass.
Every recommendation below is a proposal for the lead engineer to rule on; the
harness owns measurement, not tuning.
**Scope:** doc 93 §E — "headless playtest harness (scripted strategies over N
game-days → curves) so tuning decisions come from data, not vibes".
**Instrument:** `tools/playtest.gd`, tested by `tests/test_playtest_harness.gd`.
**Run:** 4 strategies × 3 seeds × 14 game-days (336 game-hours), sampled every
game-hour, on **both** the fine (online) and coarse (offline catch-up) paths —
24 runs, 8,088 samples.

---

## 0. Reproduce

```bash
# 12 runs on the path the player actually plays (~13 min), JSON under build/playtest/
~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
    -s res://tools/playtest.gd -- --days=14 --mode=fine

# the same 12 on doc 01's coarse offline path (~20 s) — needed for §5 F-4
~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
    -s res://tools/playtest.gd -- --days=14 --mode=coarse

# regenerate every table in this document from those files
python3 tools/playtest_report.py build/playtest --mode fine   --section all
python3 tools/playtest_report.py build/playtest --mode fine   --section compare
```

Seeds `1337, 4242, 9001`. Run files are `build/playtest/<strategy>_seed<N>_d<D>_<mode>.json`
(schema_version 1) and are **not committed** — they are regenerated per merge.
`tests/test_playtest_harness.gd` pins the schema and the determinism guarantee:
same strategy + seed + mode ⇒ byte-identical sample stream and `state_hash`.

**Everything below was measured on the FINE path unless a row says otherwise.**
The two paths are not the same city; F-4 is about exactly that, and it is the
reason every number in this report is path-tagged.

---

## 1. The strategies

Four scripted agents, all driving the real command layer
(`cmd_place_building`, `cmd_upgrade_building` — the only two verbs that exist
today; the harness probes for the other six of doc 93 §B and degrades around
them). None of them makes a stochastic choice: site selection scans sorted block
ids then row-major tiles, archetype preference lists sort with an id tie-break.

| id | policy |
|---|---|
| `do_nothing` | issues no commands. The control curve — what the founding city does when left alone. |
| `greedy_growth` | maximises heads (population + jobs) bought per dollar, zero reserve, saves up to 24 gh for a denser row. Upgrades are scored on their *delta*, so the agent picks the genuinely better buy. |
| `infrastructure_first` | civic/utility archetypes before revenue floorspace, $8k operating reserve, revenue only out of surplus above $40k. |
| `balanced` | doc 03 §2.12's "competent but not optimal": one game-day of gross expense held in reserve (floor $12k), upgrade what stands before adding more, then 2:1 residential:commercial, plus one civic building per city level. |

---

## 2. Headline — 14 game-days, fine path

| strategy (mean of 3 seeds) | treasury d14 | value created¹ | net $/gh | pop | happiness | stability | dark %² | placed | upgraded |
|---|---|---|---|---|---|---|---|---|---|
| **do_nothing** | **$125,493** | $125,493 | 299 | 144 | 81.0 | 0.9343 | 3.01 | 0 | 0 |
| **greedy_growth** | $2,981 | **$436,781** | 1,226 | 1,179 | 54.5 | 0.7150 | 30.20 | 86 | 0 |
| **infrastructure_first** | $21,752 | $112,952 | 262 | 187 | 77.4 | 0.9579 | 3.04 | 15 | 0 |
| **balanced** | $20,061 | $431,805 | 1,211 | 763 | 57.8 | 0.7521 | 31.49 | 172 | 90 |

¹ `treasury_end + construction_spend` — cash plus everything the agent turned
into buildings. Spend-everything agents pin the treasury near zero, so cash
alone ranks them wrongly.
² `blackout_minutes_total ÷ (60 × Σ metered buildings × hours)` — the share of
all building-time spent without power. Substations draw no service load
(doc 04 §2.3) and are excluded.

Per seed:

| strategy | seed | treasury d14 | net $/gh | pop | happiness | stability | level | dark % | placed | upgraded |
|---|---|---|---|---|---|---|---|---|---|---|
| do_nothing | 1337 | $128,220 | 307 | 144 | 79.9 | 0.9222 | 0 | 2.71 | 0 | 0 |
| do_nothing | 4242 | $132,305 | 319 | 144 | 82.2 | 0.9475 | 0 | 0.00 | 0 | 0 |
| do_nothing | 9001 | $115,953 | 271 | 144 | 80.8 | 0.9333 | 0 | 6.34 | 0 | 0 |
| greedy_growth | 1337 | $3,669 | 1,248 | 1,232 | 55.2 | 0.7262 | 2 | 28.00 | 87 | 0 |
| greedy_growth | 4242 | $2,388 | 1,453 | 1,446 | 56.4 | 0.7415 | 2 | 23.74 | 97 | 0 |
| greedy_growth | 9001 | $2,886 | 975 | 860 | 52.0 | 0.6774 | 2 | 38.86 | 74 | 0 |
| infrastructure_first | 1337 | $10,470 | 275 | 200 | 74.9 | 0.9518 | 0 | 2.39 | 19 | 0 |
| infrastructure_first | 4242 | $14,147 | 289 | 204 | 77.4 | 0.9740 | 0 | 0.00 | 20 | 0 |
| infrastructure_first | 9001 | $40,639 | 222 | 156 | 79.8 | 0.9478 | 0 | 6.73 | 7 | 0 |
| balanced | 1337 | $23,372 | 1,346 | 827 | 59.6 | 0.7791 | 1 | 25.15 | 161 | 129 |
| balanced | 4242 | $21,180 | 1,543 | 841 | 61.7 | 0.7862 | 1 | 19.90 | 154 | 142 |
| balanced | 9001 | $15,632 | 744 | 621 | 52.1 | 0.6909 | 1 | 49.43 | 202 | 0 |

Seed spread is large and it is not noise: it is **whether and when a transformer
burned out** (see F-3). `do_nothing` 4242 never lost one and ends 14 % richer
than `do_nothing` 9001, which lost four.

---

## 3. Regression anchors — doc 03 §2.12's founding ledger

Measured at the first settled game-hour of a `do_nothing` run:

| doc 03 §2.12 founding line | published | measured | drift |
|---|---|---|---|
| gross revenue $/gh | 839.349 | **843.405** | +0.48 % |
| expense $/gh | 520.577 | **520.649** | +0.01 % |
| **net $/gh** | **318.773** | **322.756** | **+1.25 %** |
| first game-day net | +$7,650.55 | **+$7,748** | +1.27 % |
| starter gross base tax (doc 03 §8, ±5 %) | 686 | **686.0** | **0.00 %** |

The base-tax anchor is exact. Backing the §2.5 non-tax lines out of the measured
gross — `power_tariff 1.5 MWh × 62 = 93`, `water_tariff 5.56 m³ × 0.55 = 3.058`,
`fines 3` — leaves `843.405 − 99.058 = 744.347`, and `744.347 / 686 = 1.085054`,
which is doc 03 RR-18's per-district aggregate `1.085051` to six figures. So the
starter city hits its LOCKED $686/gh base exactly and the whole +0.48 % gross gap
lives in one multiplier. That is F-10.

---

## 4. The curves

### 4.1 Treasury by game-day, mean of seeds ($)

| day | do_nothing | greedy_growth | infrastructure_first | balanced |
|---|---|---|---|---|
| 1 | $32,748 | $2,895 | $16,474 | $13,412 |
| 2 | $40,473 | $4,775 | $23,982 | $14,219 |
| 3 | $48,112 | $4,593 | $11,094 | $14,521 |
| 4 | $55,715 | $4,469 | $17,776 | $14,460 |
| 5 | $63,300 | $3,644 | $24,450 | $15,161 |
| 6 | $70,872 | $5,433 | $12,652 | $15,489 |
| 7 | $78,429 | $5,095 | $18,681 | $16,055 |
| 8 | $85,601 | $4,551 | $24,327 | $17,226 |
| 9 | $92,409 | $4,121 | $29,606 | $21,325 |
| 10 | $99,078 | $2,362 | $34,746 | $23,639 |
| 11 | $105,702 | $6,701 | $39,048 | $28,284 |
| 12 | $112,312 | $5,476 | $40,232 | $34,093 |
| 13 | $118,910 | $3,974 | $35,364 | $32,253 |
| 14 | $125,493 | $2,981 | $21,752 | $20,061 |

`do_nothing` is very nearly a straight line: **+$7,748 on game-day 1, +$6,583 on
game-day 14**, mean +$7,178/game-day. The slight droop is F-3, not a growth curve
running out — nothing else about that city ever changes.

### 4.2 Net income $/gh, mean of seeds

| day | do_nothing | greedy_growth | infrastructure_first | balanced |
|---|---|---|---|---|
| 1 | 323 | 529 | 311 | 442 |
| 2 | 322 | 662 | 313 | 584 |
| 3 | 318 | 770 | 296 | 696 |
| 4 | 317 | 870 | 278 | 864 |
| 5 | 316 | 1,035 | 278 | 1,079 |
| 6 | 315 | 1,241 | 258 | 1,291 |
| 7 | 315 | 1,444 | 251 | 1,438 |
| 8 | 299 | 1,727 | 235 | 1,529 |
| 9 | 284 | **2,024** | 220 | 1,501 |
| 10 | 278 | 1,968 | 214 | **1,718**³ |
| 11 | 276 | 1,347 | 213 | 1,718 |
| 12 | 275 | 1,213 | 233 | 1,585 |
| 13 | 275 | 1,201 | 269 | 1,324 |
| 14 | 274 | 1,125 | 294 | 1,278 |

³ balanced peaks day 11 at 1,718.
**Every curve turns over.** `greedy_growth` loses **44 %** of its peak income
between day 9 and day 14 *while still building*; `balanced` loses 26 % from day
11; `do_nothing` loses 15 % without ever taking an action. The cause is the same
in all three: permanent grid failures (F-3).

### 4.3 Blackout minutes per game-day, mean of seeds

| day | do_nothing | greedy_growth | infrastructure_first | balanced |
|---|---|---|---|---|
| 2 | 239 | 1,304 | 239 | 918 |
| 4 | 480 | 6,903 | 480 | 1,920 |
| 6 | 480 | 11,031 | 480 | 8,120 |
| 8 | 1,282 | 17,765 | 1,282 | 54,251 |
| 10 | 2,694 | 44,982 | 2,826 | 94,467 |
| 12 | 2,880 | 93,125 | 3,360 | 142,201 |
| 14 | 2,880 | 111,794 | 3,360 | 192,532 |

Monotone in every column. A blackout in this build is a ratchet.

### 4.4 Population and stability, mean of seeds

| day | pop: do_nothing / greedy / infra / balanced | stability: do_nothing / greedy / infra / balanced |
|---|---|---|
| 1 | 144 / 256 / 144 / 184 | 0.9475 / 0.9435 / 0.9677 / 0.9424 |
| 5 | 144 / 492 / 144 / 429 | 0.9391 / 0.8960 / 0.9604 / 0.9272 |
| 9 | 144 / 988 / 144 / 672 | 0.9348 / 0.8592 / 0.9569 / 0.8417 |
| 14 | 144 / 1,179 / 187 / 763 | 0.9343 / 0.7150 / 0.9579 / 0.7521 |

`do_nothing`'s population is **144 for all 336 game-hours** — the founding city
never grows by itself and never reaches city level 1 (threshold 250, doc 09
§2.11). `greedy_growth`'s population flattens from day 10 while it keeps
building, because `PopulationSystem.attractiveness_target = clamp((S − 0.35)/0.50)`
falls with stability (F-11).

---

## 5. Findings

Each finding is **evidence → doc anchor → recommendation**. Recommendations are
proposals for the lead engineer; **no `data/*.json` was touched by this pass.**

### F-1 — Standing still is the second-most-profitable strategy in the game

**Evidence.** `do_nothing` ends the fortnight with **$125,493** — 42× the greedy
agent's cash, 6× balanced's, and more *total value* than `infrastructure_first`
creates ($125,493 vs $112,952). It never touches the credit line, never enters
austerity, never loses a building, and never levels up. Its treasury curve is a
straight line.

**Anchor.** Doc 03 §2.12 models "competent-but-not-optimal play" and never models
the null strategy, because the systems that were supposed to make standing still
lethal — doc 06 incidents, doc 07 weather/disaster director, doc 05 water — have
not landed. Constitution §1: *"You built it. Now keep it alive."*

**Recommendation.** **No economy retune is justified by this finding.** The gap
is content, not numbers: doc 93 §A says as much, and retuning doc 03 against a
city with no pressure would have to be undone when Wave 1 merges. Record this
curve as the baseline the pressure systems must bend, and re-run this report the
day incidents and weather merge. If `do_nothing` still out-earns `balanced` on
cash at that point, *that* is the moment to move doc 03's constants — and doc 03
§9 item 9b (the founding `f_happiness` ceiling) already names the honest lever.

### F-2 — Growth is rewarded right through the collapse it causes

**Evidence.** `greedy_growth` takes the city from 144 to 1,179 residents and from
$323/gh to a peak of $2,024/gh, and in doing so drives stability 0.9475 → 0.7150,
happiness 82.2 → 54.5, and **30.2 % of all building-time into darkness** with 41
permanent component failures and 111 block-dark transitions across three seeds.
Its income then falls 44 % from the peak. And yet: it ends the fortnight with
**3.5× the total value** of the control, never goes negative, and never has a run
that fails. The collapse is expensive; it is never dangerous.

**Anchor.** Doc 03 §2.2 `utility_floors.residential.power = 0.35` — a dark house
still bills 35 % of its power term (commercial 0.10, industrial 0.15, tech 0.00).
Doc 04 §2.6 `XFMR_BURNOUT_R 3.0`.

**Recommendation (two candidates, ruling needed).**
1. The utility floor is calibrated for a *transient* outage; nothing in §2.2
   distinguishes "dark for an hour" from "dark for nine days". Rather than
   lowering the flat 0.35 — which would over-punish exactly the storm case doc 07
   owns — propose §2.2 gain a **duration term**: the floor decays toward 0 as a
   building's consecutive dark hours accumulate (e.g. `floor × 2^(−dark_hours/τ)`,
   τ on the order of a game-day). One new constant, no existing row moves.
2. Do nothing to the floor until F-3 is fixed. A revenue penalty for darkness is
   only fair when the player has a verb that ends the darkness.

This report recommends **(2) first, then (1)** — see F-3.

### F-3 — A failed grid component is failed forever, and the cost is enormous

**Evidence.** `PowerGrid.repair_component()` exists and **has no caller anywhere
in `sim/`, `game/` or `ui/`.** The consequence, measured on the control strategy
that does nothing wrong:

| `do_nothing` seed 1337 | day 1 | 2 | 3 | 4 | … | 14 |
|---|---|---|---|---|---|---|
| blackout minutes/day | 0 | 717 | 1,440 | 1,440 | … | **1,440** |
| stability | 0.9475 | 0.9286 | 0.9226 | 0.9222 | … | 0.9222 |
| net $/gh | 322.9 | 320.5 | 310.8 | 307.5 | … | **301.4** |

One transformer (`T-15`, serving the water works) burns out at game-hour 35 and
the city runs dark on that node for the remaining **twelve game-days** — exactly
1,440 building-minutes a day, a perfect flat line, forever.

Seed 9001 is worse: four failures from day 8, and

| `do_nothing` seed 9001 | d7 | d8 | d9 | d10 | d11 | d14 |
|---|---|---|---|---|---|---|
| blackout minutes/day | 0 | 2,405 | 4,320 | 6,643 | 7,200 | **7,200** |
| net $/gh | 319.7 | 272.7 | 228.3 | 212.0 | 207.7 | **205.9** |

**a −36 % permanent income loss for a player who never touched the game.**
Across all 12 fine runs there were **80 component failures**; in **10 of 12 runs
not a single building was ever relit** (the 626 LIT transitions that do occur are
rolling-shed rotation in two greedy/balanced runs, not recovery).

**Anchor.** Doc 93 §B — `cmd_repair_building`, `cmd_place_grid_component`
("THE game"). Doc 06 dispatch, not landed. Doc 04 §2.9's auto-reclose exists
(and works, for *trips*); a `_fail()` is terminal.

**Recommendation.** **This is the single highest-value item in doc 93 §B and the
data confirms it.** Until a repair path exists, no blackout-, stability- or
happiness-related constant should be retuned — the harness is currently measuring
a city with no immune system, and any number fitted to it will be wrong twice.
Two concrete asks, in order:
1. `cmd_repair_building` / a grid-repair verb, priced off doc 03 §2.5
   (`capital_value × damage_fraction × REPAIR_COST_PER_CAPITAL 0.85`), which
   `CostCurves.repair_cost()` already implements and nobody calls.
2. `cmd_place_grid_component` so a burnt transformer can at least be replaced.
   The harness already drives it the moment it exists
   (`InfrastructureFirst._extend_grid`, guarded by `has_method` + arity probe).

### F-4 — The coarse path does not implement doc 04 §2.12's fidelity rule, and offline players are measurably luckier

**Evidence.** Same seeds, same scripts, both paths:

| strategy | seed | value online | value offline | offline edge | dark % on/off |
|---|---|---|---|---|---|
| do_nothing | 1337 | $128,220 | $132,305 | +3.2 % | 2.71 / 0.00 |
| do_nothing | 4242 | $132,305 | $132,305 | +0.0 % | 0.00 / 0.00 |
| do_nothing | 9001 | $115,953 | $131,063 | **+13.0 %** | 6.34 / 0.73 |
| greedy_growth | 9001 | $352,686 | $516,284 | **+46.4 %** | 38.86 / 26.10 |
| balanced | 9001 | $274,832 | $524,708 | **+90.9 %** | 49.43 / 23.43 |
| *(all 12 pairs)* | | | | **mean +17.3 %, median +7.5 %, positive in 10 of 12** | |

Component *failures* are comparable across paths (greedy: 41 fine, 46 coarse), but
building **DARK transitions are 2.6× higher online** (726 vs 275) and measured
dark-time is far higher — because rolling shed rotation
(`ROLLING_SHED_PERIOD_GM` = 30 game-minutes) and the LIT/DARK hysteresis
(20 / 10 game-seconds) cannot resolve inside a single 3,600-game-second step.

**Anchor.** Doc 04 §2.12 states the rule in terms:

> **Fidelity rule:** if any component ended the previous step with `r > 1.0`, or
> a storm is active, the hour is sub-stepped at `dt = 300 game-seconds`
> (12 sub-steps) so cascades and inverse-time trips resolve correctly; otherwise
> the hour runs in one step.

`CitySim.PowerPhaseSystem.advance_coarse()` calls `advance_fine(ctx)`
unconditionally. Its own comment quotes the precondition — *"coarse hour in one
step when nothing was overloaded"* — and never checks it. Constitution §4:
offline catch-up must use the same system code, and it does; it does not use the
same *fidelity*.

**Recommendation.** Implement the fidelity rule in `PowerPhaseSystem.advance_coarse`:
track whether any component ended the previous step with `r > 1.0` and, if so,
run `grid.tick(300, …)` twelve times instead of `grid.tick(3600, …)` once. The
budget is there — the coarse step measures **0.82 ms** on the starter city
(`tests/test_milestone1.gd`'s P0-30 probe, 720-hour cap at the 2 s budget), so
a 12× sub-step on overloaded hours only stays far inside it. Until then every
balance number must be path-tagged, and doc 08's WHILE YOU WERE AWAY sheet is
describing a city luckier than the one the player would have got online.

### F-5 — The upgrade ladder is economically dominated by sprawl, at every level

**Evidence.** Two rankings, both measured off the shipped tables:

*Heads (population + jobs) bought per dollar:*

| archetype | build L1 | L1→2 | L2→3 | L3→4 | L4→5 |
|---|---|---|---|---|---|
| apartment | **0.00371** | 0.00217 | 0.00158 | 0.00115 | 0.00083 |
| house | **0.00333** | 0.00115 | 0.00090 | 0.00044 | 0.00028 |
| high_rise | **0.00288** | 0.00220 | 0.00180 | 0.00148 | 0.00122 |
| office | **0.00231** | 0.00138 | 0.00098 | 0.00071 | 0.00052 |
| store | **0.00231** | 0.00080 | 0.00052 | 0.00033 | 0.00021 |

*Base tax $/gh bought per dollar of capital:* every revenue archetype's L1 sits on
a flat **0.0100** (that is the RR-5 yield anchor doing its job); every upgrade
step returns **≈0.0080** — a uniform **−20 %**. The single exception is
`data_center` L1 at **0.01167** (+16.7 %, the drift RR-5 documents and locks).

The consequence in play: `greedy_growth`, which scores builds and upgrades on the
same axis and takes whichever is better, performed **zero upgrades in 336
game-hours across all three seeds**. `balanced` upgraded 90 times only because
its policy puts upgrades ahead of floorspace by rule, not by value.

**Anchor.** Doc 02 Core Design Rule 5 (five levels per archetype); doc 03 §2.2
`base_tax_by_level` (LOCKED by RR-5); doc 03 §8
`REQUIRED_MIN_DEMAND_LEVEL_GROWTH 2.15`. Also: the starter core offers **510
placeable, transformer-served 1×1 sites** at founding, and `E_NO_SITE` was never
returned on any fine run — land inside an owned block is free and effectively
unlimited.

**Recommendation.** **Do not reprice `base_tax_by_level`** — RR-5 locked it and
the flat 0.0100 line is deliberate. The ladder is dominated because the *costs
it avoids* are not modelled yet. In priority order:
1. **Make footprint scarce.** The starter core is 62 % vacant (doc 03 §2.12) and
   a lot inside an owned block costs nothing. The block-development bill exists
   (doc 03 §2.8) but only for new blocks. A per-footprint charge — or simply the
   arrival of `cmd_buy_block` so expansion has a price — turns "upgrade vs
   sprawl" into a real decision.
2. **Make grid headroom the binding constraint.** It nearly already is (F-2):
   sprawl is what kills the grid. Once `cmd_place_grid_component` prices the
   transformer that a 40th house needs, upgrading a served building beats
   building an unserved one *without touching a single tax row*.
3. Only if 1 and 2 leave the ladder dominated: revisit `growth_classes.k_out`
   in `building_rules.json`, which is the number that actually sets upgrade
   yield per level.

### F-6 — Civic buildings are pure cost, and two archetypes are outright traps

**Evidence.** `infrastructure_first` spent **$90,000** on 5 civic buildings
(2 construction_yard, 2 fire_station, 1 police_station on seed 1337) plus $16,800
on 14 houses, and finished the fortnight with **less total value than doing nothing**
($112,952 vs $125,493) and a **lower mean net income** (262 vs 299 $/gh). Its
stability is the best in the study (0.9579) and buys it nothing.

Why: every service/utility archetype carries `base_tax = 0` (doc 03 §2.2) and
adds a permanent department line — `police_station 26`, `fire_station 30`,
`construction_yard 20` $/gh at L1 (`data/economy.json` `station_upkeep_l1`). The
offsetting benefit does not exist: `req_fire_coverage` / `req_police_coverage`
are loaded and validated by `BuildingCatalog` and **read by nothing**, and
`cmd_upgrade_building`'s own comment says coverage checks "join when docs 05 /
02-coverage land".

Two archetypes are worse than useless. Measured directly — buy both on a booted
starter city, run a game-day, and read `PowerGrid.grid_inventory()`:

```
before:      plants=1  nodes=24   system_supply_kw   0.0
place power_facility -> ok=true  cost=60000
place substation     -> ok=true  cost=15000
after 24 gh: plants=1  nodes=24   system_supply_kw 8000.0     (unchanged)
```

- **`power_facility` — $60,000, 3×3, adds no generation.** `CitySim._boot_power()`
  builds the electrical graph exclusively from `starter_city.json`'s
  `power.nodes`; a player-placed `power_facility` becomes an ordinary `Building`
  with `power_demand_kw = 0.0` and never becomes a `PowerGrid` component.
- **`substation` — $15,000, and `_boot_power()` explicitly skips it** ("no service
  draw, doc 04 §2.3"). It is an inert box. `balanced` bought one on two of three
  seeds because it is the cheapest "utility" card on the sheet.

**Anchor.** Doc 03 §2.4 `E_departments` (RR-16); doc 02 §2.4 coverage columns;
doc 04 §2.1 (grid components are placed by `cmd_place_grid_component`, not by the
building command).

**Recommendation.**
1. **Remove `power_facility` and `substation` from the build sheet**, or route
   those cards to `cmd_place_grid_component` when it lands. Today they are a
   $60,000 and a $15,000 trap that the UI presents as a normal purchase. This is
   the cheapest fix in this report and it is a player-facing bug, not a balance
   knob.
2. Coverage must gate *something* before "infrastructure first" can be a strategy
   rather than a self-inflicted wound. Until then, treat this strategy's curve as
   a measurement of the missing system, not as evidence that civic prices are
   wrong.

### F-7 — `cmd_place_building` does not enforce `min_city_level`

**Evidence.** Verified directly: a city at level 0 with sufficient funds places a
`high_rise` (`min_city_level` 3) and a `data_center` (`min_city_level` 4), both
`ok = true`. The gate exists only in `BuildController.card()`'s `locked` flag —
i.e. in the UI. `cmd_upgrade_building` *does* check it and returns `E_CITY_LEVEL`.

**Stake.** `data_center` L1 is the single highest-ROI purchase in the game
(0.01167 $/gh per dollar of capital against the flat 0.0100 — F-5), and it is
what the unenforced gate is guarding.

**Anchor.** Doc 02 §2.3 `min_city_level` column; doc 02 §2.12 place path; doc 12
§2.7 lock glyph; constitution §3 (the sim validates commands, the UI does not).

**Recommendation.** Add the `E_CITY_LEVEL` check to `cmd_place_building` in the
documented gate order — after `E_NOT_DEVELOPED`, before `E_FOOTPRINT` — reusing
the reason code `cmd_upgrade_building` already publishes. One comparison; closes
a command-layer bypass that a scripted client, a replayed save, or the harness
itself walks straight through.

### F-8 — Building condition never changes

**Evidence.** `Building.apply_decay()` and `Building.roll_structural_failure()`
are called **only from `tests/test_building.gd`**. Measured: after 336 game-hours
of a booted starter city, the **minimum** condition over all 34 buildings is
**1.000**. Nothing ages.

Consequences, all currently inert: `f_condition` (doc 03 §2.2, `COND_FLOOR 0.55`)
is pinned at 1.0; `MAINT_CONDITION_PENALTY 1.5` on `E_building_maint` never
fires; the `E_CONDITION` upgrade blocker
(`Building.MIN_CONDITION_TO_UPGRADE`) can never trigger; and the "repair your
city" half of the core loop has no input. Note the interaction with F-3: the
income decay this report measures comes **entirely from grid failures**, not from
building wear — the wear channel is switched off.

**Anchor.** Doc 02 §2.6 (condition & decay); doc 03 §2.4; doc 93 §B
(`cmd_repair_building` — *"`Building.repair()` exists unsurfaced; condition decay
already punishes neglect"* — it does not, yet).

**Recommendation.** Wire `apply_decay(dt_h, overload_excess, powered_fraction)`
into the hourly phase before `cmd_repair_building` ships, or the repair verb
arrives with nothing to repair. `powered_fraction` is exactly the availability
`PowerGrid.settle_hour()` already returns and `HourlyPhaseSystem` already holds.

### F-9 — Doc 03 §2.10's recovery ladder is not wired, and the build commands ignore `Treasury.spend()`

**Evidence.** `Treasury.update_credit_limit()`, `update_austerity()` and
`maybe_grant_relief()` have no caller in `sim/` outside tests. So:
`credit_limit` sits at `CREDIT_LIMIT_FLOOR` **$20,000** for the whole game
regardless of revenue (§2.10 layer 3 sizes it at 6 days of gross revenue —
≈$121,000 at founding); austerity never engages (layer 2); the three relief
grants per era are unreachable (layer 5). Only `debt_interest_per_hour()` is
live, and only because `EconomySystem.settle_hour()` reaches for it as a default
argument.

No run in this pass went negative, so the ladder's absence cost nothing
*measurable* — but it hides a latent bug. Both construction commands do:

```gdscript
if treasury.balance < cost:
    return CommandQueue.fail(&"E_FUNDS", …)
treasury.spend(cost, &"construction")   # result discarded
```

`Treasury.AUSTERITY_BLOCKED_CATEGORIES` contains `&"construction"`, and a blocked
`spend()` charges **nothing** and returns `ok = false`. The day austerity is
wired, every build placed under austerity will be **free**.

**Anchor.** Doc 03 §2.10 layers 2/3/4/5; doc 03 §5 ("nothing outside `Treasury`
mutates the balance… every earn/spend goes through `credit()`/`spend()`").

**Recommendation.** Call the three ladder functions from `HourlyPhaseSystem`
(they need only trailing gross revenue and gross expense, both already in the
`BudgetSnapshot` `EconomySystem.settle_hour()` returns), and make both `cmd_*`
verbs read the `spend()` result and fail with the returned `reason_code`. Fix the
second half **before** the first, or turning the ladder on ships a free-building
exploit.

### F-10 — The founding ledger measures +$322.76/gh, doc 03 §2.12 publishes +$318.77/gh

**Evidence.** Measured gross **843.405**, expense **520.649**, net **322.756**
against §2.12's 839.349 / 520.577 / 318.773.

**This is the doc being behind the code, not the code being wrong.**
`EconomySystem.revenue_for_building()` reads `f_stability` from the building's own
district, exactly as doc 03 §2.2 requires. §2.12's headline ledger instead uses
doc 09's ruled *city aggregate* 0.9722 (RR-6). Doc 03 RR-18 already worked the
per-district answer:

```
f_stability (tax-weighted) = (296 × 0.96596 + 390 × 0.98630) / 686 = 0.977524
aggregate                  = 0.977524 × 1.110                     = 1.085051
tax                        = 686 × 1.085051                       = 744.345
gross                      = 744.345 + 93 + 3.058 + 3             = 843.403
```

The harness measures **843.405** — RR-18's own figure, to three decimals. §2.12
explicitly reserved the outcome: *"if doc 09 later publishes a tax-weighted
aggregate the line moves to $744 and the pacing `K` to 1.36378."*

**Recommendation (ruling needed — this one changes a published table).**
Adopt the per-district basis, which §2.2 already mandates and the code already
implements:

- §2.12 founding ledger → gross **$843.40**, expense **$520.58**, net
  **+$322.76/gh**, **+$7,746/game-day**;
- `PACING_ROUND2_K` → the already-published **1.36378**; regenerate the S1–S12
  table on `net = round(1.36378 × net_r1 − 20.65229 × blocks_developed)` and re-run
  guardrails G1–G5 (the shift is +0.9 % on the proportional term, well inside
  test 27's ±20 %, so no guardrail is expected to move);
- `data/economy.json`'s `STARTER_EXPENSE_PER_HOUR_EXACT 520.576566` and
  `STARTER_NET_PER_HOUR_EXACT 318.772846` → the per-district pair
  (**520.649 / 322.756**).

The alternative — amending §2.2 to read the city aggregate — is worse: §2.2 is
the normative rule and per-district is the physically correct reading.

**Test debt either way.** `tests/test_city_sim.gd::test_economy_settles_in_the_loop`
asserts the first settled hour in `[315, 322]` and the live value is **322**, and
the first game-day in `[7,500, 7,800]` against a live **7,748**. Both are passing
on their boundary and will break on any move. Re-centre them on whichever figure
is ruled, with an explicit ±1 % band and the doc reference in the message.

### F-11 — Population is capped by stability, not by land (working as designed)

**Evidence.** `greedy_growth`'s population flattens at ~1,100 from day 10 while it
keeps placing buildings, because `attractiveness_target = clamp((S − 0.35)/0.50)`
falls to 0.73 as stability collapses to 0.715. Land never binds: 510 servable
1×1 sites at founding and `E_NO_SITE` was never returned on the fine path.

**Anchor.** Doc 09 §2.10 (`PopulationSystem`), doc 09 §2.10.3.

**No recommendation.** Recorded because it is the mechanism F-2's fix should lean
on: the negative feedback loop from blackouts → stability → attractiveness →
population → tax **already exists and works**. It is not painful enough to change
behaviour (greedy still ends 3.5× ahead), but it is the right lever to sharpen,
and it needs no new system.

---

## 6. What this pass could not see

The harness measures what is wired. These are stubbed or absent today, and every
number above should be re-read when they land:

| system | state in this run |
|---|---|
| water (doc 05) | `water: 1.0` constant in `build_settlement_inputs`; `HELD_WATER` metering constants |
| roads (doc 10) | `road: 1.0` constant; `E_roads_repair` billed off a fixed 540 AVENUE / 243 STREET inventory at `c_day 0.35` |
| incidents & dispatch (doc 06) | absent; `HELD_FINE_RATE`, a fixed 6-vehicle `STARTER_VEHICLES` roster |
| weather & disasters (doc 07) | clear-sky stub, `t_ambient 22 °C`, `heat_wave: false` — **no storm ever fires**, so doc 04 §2.12's storm sub-step condition is untested too |
| taxes (doc 03 §2.2) | rate pinned at `0.09`; `cmd_set_tax_level` absent |
| land market (doc 09 §2.5) | `cmd_buy_block` absent; the city is 9 blocks for all 14 days |
| demolish / repair / priority | absent (doc 93 §B) |

`tools/playtest.gd` probes all six missing verbs by name and arity every run and
prints which are present, so the first re-run after any of them merges will
exercise them without a code change here.

---

## 7. Proposed regression gates for the next run

Not implemented as tests by this pass — they are proposals, because several of
them should *fail* today on purpose.

| gate | today | proposed threshold |
|---|---|---|
| founding first settled hour, net $/gh | 322.756 | ruled figure ±1 % (F-10) |
| `do_nothing` 14-day treasury | $125,493 | **upper** bound once Wave 1 lands; today record-only |
| `balanced` beats `do_nothing` on cash at d14 | ✗ ($20,061 vs $125,493) | must hold once pressure systems land |
| relit buildings after a component failure | 0 in 10 of 12 runs | > 0 once a repair verb exists (F-3) |
| `greedy_growth` dark % at d14 | 30.2 % | ≤ 10 % once grid verbs exist (F-3) |
| offline/online value edge | +17.3 % mean | \|Δ\| ≤ 5 % once doc 04 §2.12's fidelity rule is implemented (F-4) |
| `cmd_place_building` on a locked archetype | succeeds | must return `E_CITY_LEVEL` (F-7) |
| building condition after 14 game-days | 1.000 | < 1.000 once decay is wired (F-8) |

---

## 8. Changelog

| pass | date | what changed |
|---|---|---|
| **1** | 2026-08-18 | First harness pass. `tools/playtest.gd` + `tools/playtest_report.py` + `tests/test_playtest_harness.gd` land; 24 runs (4 strategies × 3 seeds × 2 paths × 14 game-days). Findings F-1 … F-11 opened. No `data/` change. |
