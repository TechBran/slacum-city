# 92 — Balance report, pass 2: the game as a game

> **RULINGS LANDED, 2026-08-19 — every measurement below is now HISTORICAL.**
> The lead engineer ruled on F-1, F-2, F-3, F-5, F-7 and §4's anchor promotion,
> and they are implemented. `Building.apply_decay` has a caller; the fleet grows
> with the station roster and is what doc 03 bills; the doc 03 §2.10 recovery
> ladder runs every settled hour and all six `spend()` sites respect refusal;
> `data/director.json` carries a size-independent event floor;
> `tax.TAX_RATE_GROWTH_COEFF` is 8.0. §10's gate table is implemented as
> `tests/test_balance_gates.gd`. Doc 93 §E2 carries the new founding anchors and
> the fleet-billing shift. **The tables in §3–§8 describe the sim as it was on
> 2026-08-19 BEFORE those changes** and are kept as the pass-2 baseline the gates
> measure against — see §12 for what moved and where the new numbers live.

**Status:** DATA + RECOMMENDATIONS. **Nothing in `data/` was changed by this
pass.** Every recommendation below is a proposal for the lead engineer to rule
on; the harness owns measurement, not tuning. Each one names the exact
`data/*.json` key it would move.
**Scope:** doc 93 §E — "headless playtest harness (scripted strategies over N
game-days → curves) so tuning decisions come from data, not vibes". Pass 1
measured a sim with no pressure and two verbs. This pass measures the
**integrated** game: water, incidents/dispatch, roads, weather and the Disaster
Director are live, and all six of doc 93 §B's player verbs exist.
**Anchors:** doc 93 §E2's as-integrated founding ledger is the binding baseline,
not doc 03 §2.12's stub-era worked example.
**Instrument:** `tools/playtest.gd` (schema 2), presented by
`tools/playtest_report.py`, tested by `tests/test_playtest_harness.gd`.

---

## 0. Reproduce

```bash
# the matrix: 6 strategies x 3 seeds x 21 game-days (504 game-hours each)
~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
    -s res://tools/playtest.gd -- --days=21 --mode=coarse

# the late curve: one 90-game-day greedy run
~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
    -s res://tools/playtest.gd -- --days=90 --mode=coarse \
    --seeds=1337 --strategies=greedy_growth

# the two controlled micro-experiments (§6 and §7)
~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
    -s res://tools/playtest.gd -- --experiment=transformer_payback --mode=coarse
~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
    -s res://tools/playtest.gd -- --experiment=tax_curve --mode=coarse

# the online/offline pair (§9 F-9)
~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
    -s res://tools/playtest.gd -- --days=7 --mode=fine --seeds=1337 \
    --strategies=do_nothing,greedy_growth,balanced,disaster_neglect

# every table in this document, regenerated from those files
python3 tools/playtest_report.py build/playtest --mode coarse --days 21
python3 tools/playtest_report.py build/playtest --mode coarse --days 7 --section compare
```

Seeds `1337, 4242, 9001`. Run files are
`build/playtest/<strategy>_seed<N>_d<D>_<mode>.json` (schema_version 2) and are
**not committed** — they are regenerated per merge.

**Coverage of this pass: 17 of the 18 matrix runs.** `tax_squeezer` seed 9001
did not finish inside the harness's wall-clock budget, so every `tax_squeezer`
aggregate below is the mean of **two** seeds and is marked where it matters. The
cause is the harness, not the sim: `Api.upgrade_candidates()` previews
`cmd_upgrade_building` for every standing building, and the two agents that call
it do so up to six times per game-hour, so wall time grows with (buildings ×
hours). A very large city therefore costs superlinearly to *measure*, not to
run. Fixing that is a pass-3 harness job and is listed in §9 F-10.
`tests/test_playtest_harness.gd` pins the schema, the determinism guarantee
(same strategy + seed + mode ⇒ byte-identical sample stream and `state_hash`)
and one behavioural signature per strategy.

**A note on the path.** The headline matrix runs on the **coarse** (doc 01
offline catch-up) path, because a 21-game-day fine run costs ~13 minutes and the
matrix is 18 of them. Doc 93 §E2 makes this legitimate — mode-invariance is
per-system and each stochastic subsystem's own suite bounds its sanctioned
parity — but it is not free, and §9 F-9 measures exactly how much it costs on a
paired 7-game-day fine/coarse set. **Every number below is coarse-path unless
the row says otherwise.**

---

## 1. What moved since pass 1

| pass-1 finding | status now | evidence |
|---|---|---|
| **F-3** a failed grid component is failed forever | **CLOSED** | doc 06's dispatch calls `PowerGrid.repair_component` (`sim/incidents/city_incident_world.gd:278`). Across the matrix, `power_restored_by_repair` ≈ `PowerComponentFailed` (greedy: 284.7 restored vs 278.3 failed per run). Grid failures are now transient. |
| **F-1** standing still is the second-most-profitable strategy | **WORSE** — it is now the most profitable on cash by 4.5× | §3 |
| **F-2** growth is rewarded through the collapse it causes | **REVERSED, and overshot** — growth is now punished by a cliff, not a slope | §5.2, §9 F-3 |
| **F-5** the upgrade ladder is dominated by sprawl | **PARTLY SELF-CORRECTING** — greedy now upgrades 26×/run, but only after game-day 16 when it runs out of 2×2 ground | §9 F-6 |
| **F-6** `power_facility` / `substation` are build-sheet traps | **UNCHANGED** | not re-measured this pass; the code path is untouched |
| **F-7** `cmd_place_building` does not enforce `min_city_level` | **UNCHANGED** | `sim/city_sim.gd:742` still has no `E_CITY_LEVEL` gate |
| **F-8** building condition never changes | **PARTLY** — incidents now damage buildings, but `Building.apply_decay()` still has no caller in `sim/` | §9 F-2 |
| **F-9** the doc 03 §2.10 recovery ladder is not wired | **UNCHANGED, and now it costs something** | §9 F-7 — a run ended at −$12,724 with the credit limit still pinned at its floor |
| **F-4** the coarse path does not implement doc 04 §2.12's fidelity rule | **UNCHANGED** | `PowerPhaseSystem.advance_coarse` still calls `advance_fine` unconditionally (`sim/city_sim.gd:1649`) |
| **F-10** the founding ledger drifts from doc 03 §2.12 | **SUPERSEDED** by doc 93 §E2, which this pass measures against and matches | §4 |

---

## 2. The strategies

Six scripted agents, all driving the real command layer, none making a
stochastic choice: site selection scans sorted block ids then row-major tiles,
archetype preference lists sort with an id tie-break.

| id | policy |
|---|---|
| `do_nothing` | issues no commands. The control — what the founding city does when left alone. |
| `greedy_growth` | max heads (population + jobs) per dollar, zero reserve. **Buys no infrastructure, ever**: no transformer, no repair, no land, no priority. When the served ground runs out it walks into `E_UNSERVED` on purpose and then monetises what already stands. |
| `infrastructure_first` | repair → **grid ahead of growth** → **land** → civic → floorspace out of deep surplus. Keeps ≥24 served empty tiles in every owned block, and saves for the next block's purchase *and* development bill rather than spending the difference. |
| `balanced` | doc 03 §2.12's "competent but not optimal": one game-day of gross expense in reserve (floor $12k), 2:1 residential:commercial, upgrade-first, one civic per city level, repairs below condition 0.90, sets doc 04 §2.4 priority classes on the civic roster, buys a transformer when it actually hits the wall, expands on an $80k surplus. |
| `tax_squeezer` | **`balanced` with exactly one knob moved**: the tax slider pinned to `TAX_RATE_MAX` (detent 12, r = 0.16) from game-hour 0. |
| `disaster_neglect` | **`balanced` with exactly one knob moved**: `maintains = false` — never repairs, never sets a priority class, never buys grid. Everything it builds, it builds identically to `balanced`. |

The last two are the design of this pass. They are literally the `Balanced`
class with one field changed (`tests/test_playtest_harness.gd` asserts the
`is Balanced` relationship and that each issues/withholds exactly the verbs its
knob controls), so a difference in their curves is attributable to that knob and
nothing else.

---

## 3. Headline — 21 game-days, coarse path

| strategy | seed | treasury d21 | value created | net $/gh | pop | happiness | stability | level | dark % | placed | upgraded |
|---|---|---|---|---|---|---|---|---|---|---|---|
| do_nothing | 1337 | $199,757 | $199,757 | 342 | 144 | 82.2 | 0.9475 | 0 | 0.05 | 0 | 0 |
| do_nothing | 4242 | $198,380 | $198,380 | 342 | 144 | 82.2 | 0.9475 | 0 | 0.00 | 0 | 0 |
| do_nothing | 9001 | $200,145 | $200,145 | 336 | 142 | 83.1 | 0.9485 | 0 | 0.07 | 0 | 0 |
| greedy_growth | 1337 | $16,925 | $813,525 | 1,047 | 415 | 58.9 | 0.4325 | 2 | 46.93 | 137 | 0 |
| greedy_growth | 4242 | $55,682 | $1,062,953 | 1,424 | 1,844 | 52.0 | 0.6892 | 2 | 46.01 | 137 | 42 |
| greedy_growth | 9001 | $59,553 | $1,053,469 | 1,422 | 1,963 | 52.1 | 0.6741 | 2 | 46.18 | 137 | 37 |
| infrastructure_first | 1337 | $26,837 | $222,037 | 477 | 304 | 77.7 | 0.9744 | 1 | 0.39 | 47 | 1 |
| infrastructure_first | 4242 | $11,647 | $206,847 | 469 | 304 | 77.6 | 0.9740 | 1 | 0.00 | 47 | 1 |
| infrastructure_first | 9001 | $25,924 | $206,324 | 453 | 295 | 77.6 | 0.9731 | 1 | 0.08 | 47 | 1 |
| balanced | 1337 | $-12,724 | $656,856 | 857 | 279 | 52.0 | 0.6732 | 2 | 39.40 | 237 | 107 |
| balanced | 4242 | $33,442 | $1,060,303 | 1,682 | 1,390 | 61.9 | 0.7144 | 2 | 41.05 | 306 | 157 |
| balanced | 9001 | $32,810 | $1,112,997 | 1,675 | 1,421 | 62.7 | 0.7263 | 2 | 45.23 | 307 | 159 |
| tax_squeezer | 1337 | $-2,577 | $1,203,697 | 1,518 | 7 | 42.4 | 0.9390 | 2 | 30.97 | 245 | 98 |
| tax_squeezer | 4242 | $162,001 | $1,551,746 | 2,734 | 1,816 | 45.7 | 0.7111 | 2 | 70.22 | 271 | 101 |
| disaster_neglect | 1337 | $32,471 | $1,026,628 | 1,444 | 1,463 | 67.1 | 0.7745 | 2 | 49.35 | 327 | 140 |
| disaster_neglect | 4242 | $31,043 | $1,055,144 | 1,679 | 1,434 | 62.1 | 0.7324 | 2 | 42.02 | 309 | 155 |
| disaster_neglect | 9001 | $33,199 | $1,082,950 | 1,608 | 1,460 | 62.9 | 0.7453 | 2 | 45.77 | 317 | 149 |

| strategy (mean of seeds) | treasury d21 | value created | net $/gh | pop | happiness | stability | dark % | placed | upgraded |
|---|---|---|---|---|---|---|---|---|---|
| **do_nothing** | $199,427 | $199,427 | 340 | 143 | 82.5 | 0.9478 | 0.04 | 0 | 0 |
| **greedy_growth** | $44,053 | $976,649 | 1,297 | 1,407 | 54.3 | 0.5986 | 46.37 | 137 | 26 |
| **infrastructure_first** | $21,469 | $211,736 | 466 | 301 | 77.6 | 0.9738 | 0.16 | 47 | 1 |
| **balanced** | $17,843 | $943,385 | 1,405 | 1,030 | 58.9 | 0.7046 | 41.89 | 283 | 141 |
| **tax_squeezer** | $79,712 | $1,377,722 | 2,126 | 912 | 44.0 | 0.8251 | 50.59 | 258 | 100 |
| **disaster_neglect** | $32,238 | $1,054,907 | 1,577 | 1,452 | 64.1 | 0.7507 | 45.71 | 318 | 148 |

The `tax_squeezer` mean row is **two seeds** (§0). Every other row is three.

**Read the two money columns together.** `treasury` is cash; `value created` is
`treasury_end + construction_spend`, i.e. cash plus everything the agent turned
into buildings. Spend-everything agents pin cash near zero, so cash alone ranks
them wrongly — and yet the cash column is the one a player sees.

Three things jump off this table and each one is a finding:

1. **`do_nothing` ends with 2.5× the cash of the best-funded agent that plays,
   and 11× the "competent" one** ($199,427 vs $79,712 vs $17,843) — and it is
   the only strategy that never sees an incident, never loses power, and never
   goes near the credit line. (§9 F-1)
2. **`disaster_neglect` beats `balanced` on every axis** — more cash, more
   value, more people, *higher* happiness and *higher* stability — while
   spending $0 on maintenance. (§9 F-2)
3. **`tax_squeezer` is the richest player in the study**, on cash and on value
   created, on both the seeds it completed. Doubling the tax rate buys 46 % more
   value than the same builder at the founding rate. (§9 F-5)

And one thing that should jump off it and does not: **the seed spread is larger
than the strategy spread.** `greedy_growth` ends at 415 population on one seed
and 1,963 on another; `balanced` ends bankrupt on one and $33k up on another.
That is §9 F-10, and it is the reason every aggregate here should be read as a
range, not a point.

### 3.1 Which verb each agent actually reached for

| strategy (mean of seeds) | transformers | grid $ | repairs | repair $ | blocks | land $ | demolitions | priority sets | tax moves | `E_UNSERVED` walls |
|---|---|---|---|---|---|---|---|---|---|---|
| do_nothing | 0.0 | $0 | 0.0 | $0 | 0.0 | $0 | 0.0 | 0.0 | 0.0 | 0.0 |
| greedy_growth | 0.0 | $0 | 0.0 | $0 | 0.0 | $0 | 0.0 | 0.0 | 0.0 | 18.7 |
| infrastructure_first | 4.3 | $4,000 | 0.0 | $0 | 1.0 | $12,700 | 0.0 | 0.0 | 0.0 | 0.0 |
| balanced | 0.0 | $0 | 5.3 | $7,966 | 0.3 | $4,200 | 0.0 | 6.0 | 0.0 | 0.0 |
| tax_squeezer | 0.0 | $0 | 8.0 | $21,098 | 2.5 | $26,900 | 0.0 | 6.0 | 1.0 | 0.0 |
| disaster_neglect | 0.0 | $0 | 0.0 | $0 | 0.3 | $4,200 | 0.0 | 0.0 | 0.0 | 0.0 |

Doc 93 §B's six verbs are all live, and four of them are barely touched by
anyone. Only `infrastructure_first` ever buys a transformer; nobody demolishes
anything; `balanced` repairs five times in three game-weeks and
`infrastructure_first` — the agent whose whole thesis is maintenance — repairs
**zero** times, because nothing ever gets damaged in a city that small. §9 F-2,
F-3 and F-4 are all about why.

### 3.2 The maintenance and pressure channel

| strategy (mean of seeds) | min condition | mean condition end | damaged end | destroyed end | failed grid components end | open incidents (mean/hour) | dark % | stability end |
|---|---|---|---|---|---|---|---|---|
| do_nothing | 1.000 | 1.000 | 0.7 | 0.0 | 0.0 | 0.01 | 0.04 | 0.9478 |
| greedy_growth | 0.530 | 0.876 | 19.0 | 0.0 | 2.0 | 11.25 | 46.37 | 0.5986 |
| infrastructure_first | 1.000 | 1.000 | 1.3 | 0.0 | 0.0 | 0.02 | 0.16 | 0.9738 |
| balanced | 0.600 | 0.816 | 16.0 | 1.0 | 1.3 | 18.68 | 41.89 | 0.7046 |
| tax_squeezer | 0.475 | 0.570 | 9.0 | 4.5 | 4.5 | 68.44 | 50.59 | 0.8251 |
| disaster_neglect | 0.900 | 1.000 | 18.0 | 0.0 | 2.7 | 7.59 | 45.71 | 0.7507 |

### 3.3 Sim events per run, mean of seeds

| strategy | PowerComponentFailed | BuildingPowerChanged:DARK | BlockDarkChanged | incident_created | incident_resolved | incident_failed | power_restored_by_repair | city_level_changed | building_completed | credit_line_engaged | deferred_liability_accrued |
|---|---|---|---|---|---|---|---|---|---|---|---|
| do_nothing | 2.3 | 3.3 | 1.3 | 4.0 | 4.0 | 0.0 | 3.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| greedy_growth | 278.3 | 583.0 | 94.3 | 445.3 | 373.7 | 0.0 | 284.7 | 2.0 | 163.0 | 0.0 | 0.0 |
| infrastructure_first | 7.3 | 20.3 | 4.0 | 10.0 | 10.0 | 0.0 | 8.3 | 1.0 | 46.7 | 0.0 | 0.0 |
| balanced | 203.0 | 930.0 | 88.7 | 433.7 | 299.7 | 0.0 | 214.7 | 2.0 | 421.0 | 0.0 | 0.0 |
| tax_squeezer | 272.0 | 729.5 | 93.5 | 827.0 | 498.5 | 0.0 | 277.0 | 2.0 | 356.0 | 0.0 | 0.0 |
| disaster_neglect | 242.0 | 1087.7 | 116.7 | 338.3 | 318.7 | 0.0 | 247.3 | 2.0 | 460.7 | 0.0 | 0.0 |

`power_restored_by_repair` ≈ `PowerComponentFailed` in every row: pass-1 F-3 is
closed, grid failures are transient now. `incident_failed` is **0** in every row,
which is not good news — see §9 F-3.

### 3.4 What the command layer answered

| strategy | command results (mean per run) |
|---|---|
| do_nothing | — |
| greedy_growth | `E_NO_SITE` 122, `E_UNSERVED` 19, `OK` 163 |
| infrastructure_first | `OK` 53 |
| balanced | `E_FUNDS` 4, `E_UNSERVED` 1, `OK` 436 |
| tax_squeezer | `E_FUNDS` 12, `E_NO_SITE` 62, `E_UNSERVED` 1, `OK` 375 |
| disaster_neglect | `OK` 466 |

---

## 4. Regression anchors — doc 93 §E2's as-integrated founding ledger

Measured at the first settled game-hour of a `do_nothing` run:

| founding line | doc 03 §2.12 (stub-era) | doc 93 §E2 (as-integrated) | measured (hour 1, do_nothing) | drift vs §E2 |
|---|---|---|---|---|
| gross revenue $/gh | 839.349 | — | 841.440 | — |
| expense $/gh | 520.577 | — | 492.757 | — |
| net $/gh | 318.773 | ≈ 345 | 348.683 | +1.07% |
| first game-day net | ≈ 7,650 | ≈ 8,350 | 8,351 | +0.01% |
| day-1 mean net $/gh | — | — | 347.948 | — |

Doc 93 §E2's two as-integrated anchors are **hit almost exactly**: the first
settled hour lands at $348.68/gh against "≈ +$345", and the first game-day at
$8,351 against "≈ +$8,350" — 0.01 % on the day figure. The expense line has
moved further from doc 03 §2.12's stub-era $520.58 (measured $492.76, −5.3 %)
because docs 05/10 now bill live inventories rather than the held constants;
§E2 already sanctions that the chain, not the number, is what is preserved.

**Recommendation (bookkeeping, no ruling needed on the numbers).** Doc 93 §E2
publishes the net anchors to two significant figures ("≈ +$345", "≈ +$8,350").
Now that the integration has settled, promote them to the measured values —
**$348.68/gh and $8,351/game-day** — and add the gross/expense pair
(**$841.44 / $492.76**), so the next pass has a three-line regression target
instead of a one-line approximate one. `data/economy.json`'s
`STARTER_EXPENSE_PER_HOUR_EXACT` (520.576566) and `STARTER_NET_PER_HOUR_EXACT`
(318.772846) are still the stub-era pair and are now 5.3 % and 9.4 % adrift of
what the sim bills; they should be re-stamped in the same ruling.

---

## 5. The curves

### 5.1 Treasury by game-day, mean of seeds ($)

| day | do_nothing | greedy_growth | infrastructure_first | balanced | tax_squeezer | disaster_neglect |
|---|---|---|---|---|---|---|
| 3 | $50,281 | $3,738 | $25,807 | $14,031 | $22,205 | $13,956 |
| 6 | $75,035 | $4,758 | $26,098 | $15,925 | $25,936 | $16,093 |
| 9 | $99,864 | $6,607 | $19,092 | $40,449 | $39,546 | $41,722 |
| 12 | $125,070 | $6,296 | $19,315 | $26,695 | $35,708 | $24,700 |
| 15 | $150,580 | $5,779 | $53,009 | $29,199 | $29,089 | $29,327 |
| 18 | $175,163 | $6,971 | $9,860 | $22,175 | $82,086 | $29,839 |
| 21 | $199,427 | $44,053 | $21,469 | $17,843 | $79,712 | $32,238 |

### 5.2 Net income $/gh, mean of seeds

| day | do_nothing | greedy_growth | infrastructure_first | balanced | tax_squeezer | disaster_neglect |
|---|---|---|---|---|---|---|
| 3 | 345.79 | 867.26 | 344.21 | 769.65 | 2,384.38 | 772.22 |
| 6 | 343.27 | 1,614.05 | 469.18 | 1,463.44 | 5,079.20 | 1,461.24 |
| 9 | 341.47 | 2,817.47 | 501.82 | 2,409.47 | 3,404.71 | 2,415.93 |
| 12 | 340.24 | 1,562.23 | 447.76 | 2,483.90 | 2,118.90 | 2,467.71 |
| 15 | 337.71 | 1,313.83 | 444.19 | 1,705.56 | 1,187.25 | 1,542.31 |
| 18 | 336.22 | 587.75 | 515.43 | 573.66 | 156.35 | 1,288.61 |
| 21 | 334.21 | 280.99 | 592.26 | 482.96 | 119.45 | 1,255.32 |

**Every growth curve turns over, and this time it is a cliff, not a slope.**

| strategy | peak net $/gh | peak day | day-21 net $/gh | fall from peak |
|---|---|---|---|---|
| `tax_squeezer` | 5,513 | 7 | 119 | **−98 %** |
| `greedy_growth` | 2,817 | 9 | 281 | **−90 %** |
| `balanced` | 2,498 | 10 | 483 | **−81 %** |
| `disaster_neglect` | 2,492 | 10 | 1,255 | −50 % |
| `infrastructure_first` | 592 | 21 | 592 | still climbing |
| `do_nothing` | 348 | 1 | 334 | −4 % |

Pass 1 measured the same shape and blamed permanent grid failures. That cause is
gone (§1). The new cause is §9 F-3: an incident cascade that the fixed
eight-vehicle fleet cannot answer.

### 5.3 Population by game-day, mean of seeds

| day | do_nothing | greedy_growth | infrastructure_first | balanced | tax_squeezer | disaster_neglect |
|---|---|---|---|---|---|---|
| 3 | 143 | 351 | 155 | 295 | 295 | 295 |
| 6 | 143 | 671 | 207 | 523 | 672 | 527 |
| 9 | 143 | 1,310 | 230 | 671 | 1,176 | 676 |
| 12 | 143 | 1,484 | 230 | 855 | 1,380 | 835 |
| 15 | 143 | 1,811 | 230 | 1,113 | 914 | 1,110 |
| 18 | 143 | 1,750 | 257 | 893 | 898 | 1,265 |
| 21 | 143 | 1,407 | 301 | 1,030 | 912 | 1,452 |

### 5.4 The collapse, hour by hour (seed 1337)

Three runs on the same seed, at day granularity. The bold columns are the same
event in all three, arriving on a different day each time: the city crosses the
fleet's capacity and stops being a city.

| `balanced` seed 1337 | d9 | d12 | d15 | **d16** | **d17** | d18 | d21 |
|---|---|---|---|---|---|---|---|
| net $/gh | 2,451 | 978 | 1,768 | 414 | **−67** | −722 | −763 |
| population | 676 | 767 | 1,051 | 1,027 | **401** | 151 | 279 |
| stability | 0.938 | 0.748 | 0.793 | 0.705 | **0.188** | 0.531 | 0.673 |
| open incidents | 0 | 14 | 13 | 14 | **127** | 210 | 183 |
| min condition | 1.00 | 1.00 | 0.90 | 1.00 | **0.10** | 0.10 | 0.10 |
| treasury | $42,018 | $22,911 | $30,642 | $20,549 | $19,922 | **−$91** | **−$12,724** |

| `tax_squeezer` seed 1337 | d12 | d13 | d14 | **d15** | **d16** | d18 | d21 |
|---|---|---|---|---|---|---|---|
| net $/gh | 1,490 | 2,203 | 2,775 | **300** | −1,514 | −1,575 | −1,577 |
| population | 1,328 | 1,449 | 1,629 | **104** | **0** | 13 | **7** |
| open incidents | 22 | 23 | 21 | **442** | 384 | 375 | 339 |
| min condition | 0.90 | 0.90 | 0.90 | **0.10** | 0.10 | 0.10 | 0.10 |

| `greedy_growth` seed 1337 | d16 | d17 | d18 | d19 | **d20** | **d21** |
|---|---|---|---|---|---|---|
| net $/gh | 1,381 | 282 | 33 | 23 | **−102** | **−624** |
| population | 1,863 | 1,528 | 1,534 | 1,464 | **887** | **415** |
| stability | 0.731 | 0.612 | 0.672 | 0.628 | **0.197** | 0.433 |
| open incidents | 20 | 18 | 16 | 17 | **48** | **87** |
| min condition | 0.80 | 0.45 | 0.45 | 0.45 | **0.10** | 0.10 |

A city of 1,629 people goes to **zero in two game-days** and never recovers over
the remaining game-week. Whatever else is true, that is not a difficulty curve —
and note the shape is identical in all three: a slow bleed of condition
(1.00 → 0.90 → 0.45) that costs almost nothing, then a two-day vertical drop.

---

## 6. Experiment — what does one transformer buy?

A strategy run cannot isolate this, so the harness runs a controlled pair: boot
two identical cities, give one an L1 transformer on the tile that lights the most
dark ground plus houses on **exactly** the tiles that tap lit, and compare the
settled net $/gh of both after construction and the doc 03 §8 36-hour occupancy
ramp have finished.

| seed | tap tile | tap $ | lateral tiles | tiles lit | houses | house $ | total outlay | Δ net $/gh | tap payback (gh) | total payback (gh) | total payback (game-days) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1337 | (43,57) | $1,270 | 7 | 35 | 19 | $22,800 | $24,070 | +180.03 | **7** | 134 | 5.6 |
| 4242 | (43,57) | $1,270 | 7 | 35 | 19 | $22,800 | $24,070 | +166.41 | **8** | 145 | 6.0 |
| 9001 | (43,57) | $1,270 | 7 | 35 | 19 | $22,800 | $24,070 | +174.51 | **7** | 138 | 5.7 |

The three seeds agree to the tile because the choice is deterministic and the
founding grid is authored; only the settled net differs, by the weather and
incident draw.

And the price of the verb itself, read straight off `cmd_place_grid_component`'s
own preview (doc 03 §2.13(b): `transformer` L1 build cost + one feeder lateral
per Chebyshev tile at that feeder's conductor price):

| lateral tiles | tap price | example tile |
|---|---|---|
| 1 | $610 | (38,38) |
| **2** | **$720** | (37,38) |
| 3 | $830 | (36,38) |
| 4 | $940 | (43,37) |
| 5 | $1,050 | (44,41) |
| 6 | $1,160 | (45,41) |
| 7 | $1,270 | (46,41) |
| 8 | $1,380 | (40,56) |

The **$720 two-tile tap is confirmed exactly**: `$500` from
`data/economy.json` `expenses.grid_components.transformer.build_cost[0]`, plus
`2 × $110` from `expenses.grid_components.feeder.cost_per_tile_overhead[0]`.

---

## 7. Experiment — what does one tax detent cost?

Every detent of doc 03 §8's 13-rung ladder, one game-week each, same seed, same
untouched `do_nothing` city. The only thing that differs between rows is `r`.

| level | rate | policy factor | published Δhappy | published growth× | treasury after 7 gd | net $/gh | pop | happiness | stability |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 0.04 | 0.4444 | +11.00 | 1.175 | $16,423 | **−51.1** | 144 | 93.2 | 0.9475 |
| 1 | 0.05 | 0.5556 | +8.80 | 1.140 | $30,286 | 31.5 | 144 | 91.0 | 0.9475 |
| 2 | 0.06 | 0.6667 | +6.60 | 1.105 | $43,895 | 112.5 | 144 | 88.8 | 0.9475 |
| 3 | 0.07 | 0.7778 | +4.40 | 1.070 | $57,250 | 192.0 | 144 | 86.6 | 0.9475 |
| 4 | 0.08 | 0.8889 | +2.20 | 1.035 | $70,351 | 269.9 | 144 | 84.4 | 0.9475 |
| **5** | **0.09** | **1.0000** | **0.00** | **1.000** | **$83,198** | **346.4** | **144** | **82.2** | **0.9475** |
| 6 | 0.10 | 1.1111 | −2.20 | 0.965 | $95,790 | 421.4 | 144 | 80.0 | 0.9475 |
| 7 | 0.11 | 1.2222 | −4.40 | 0.930 | $108,129 | 494.8 | 144 | 77.8 | 0.9475 |
| 8 | 0.12 | 1.3333 | −6.60 | 0.895 | $120,214 | 566.8 | 144 | 75.6 | 0.9475 |
| 9 | 0.13 | 1.4444 | −8.80 | 0.860 | $132,044 | 637.2 | 144 | 73.4 | 0.9475 |
| 10 | 0.14 | 1.5556 | −11.00 | 0.825 | $143,620 | 706.1 | 144 | 71.2 | 0.9475 |
| 11 | 0.15 | 1.6667 | −13.20 | 0.790 | $154,942 | 773.5 | 144 | 69.0 | 0.9475 |
| **12** | **0.16** | **1.7778** | **−15.40** | **0.755** | **$166,011** | **839.4** | **144** | **66.8** | **0.9475** |

---

## 8. The late curve — 90 game-days of `greedy_growth`

Three game-weeks is the pacing horizon doc 03 §2.12 models. This is what happens
if you keep going: one 90-game-day run (2,160 game-hours) of the fastest builder
in the study.

_seed 4242, coarse path, one row every 5 game-days_

| day | treasury | net $/gh | population | happiness | stability | buildings | damaged | open incidents | min condition |
|---|---|---|---|---|---|---|---|---|---|
| 1 | $5,032 | 568 | 256 | 76.0 | 0.943 | 62 | 0 | 0 | 1.00 |
| 2 | $954 | 705 | 304 | 75.1 | 0.946 | 65 | 0 | 0 | 1.00 |
| 3 | $7,904 | 873 | 352 | 74.4 | 0.940 | 67 | 0 | 0 | 1.00 |
| 5 | $8,048 | 1,324 | 544 | 73.6 | 0.927 | 76 | 0 | 1 | 1.00 |
| 10 | $7,803 | 2,667 | 1,448 | 62.4 | 0.801 | 123 | 4 | 5 | 0.90 |
| 15 | $3,408 | 1,362 | 1,872 | 53.3 | 0.725 | 171 | 19 | 17 | 0.90 |
| 20 | $16,710 | 796 | 1,769 | 52.1 | 0.651 | 171 | 21 | 27 | 0.90 |
| 25 | $205,517 | 727 | 1,835 | 52.0 | 0.698 | 171 | 26 | 27 | 0.54 |
| 30 | $398,907 | 658 | 1,821 | 52.0 | 0.701 | 171 | 28 | 37 | 0.54 |
| 35 | $590,607 | 682 | 1,844 | 52.0 | 0.701 | 171 | 28 | 37 | 0.54 |
| 40 | $771,862 | 316 | 1,777 | 52.0 | 0.640 | 171 | 28 | 48 | 0.54 |
| 45 | $895,246 | 282 | 1,620 | 52.0 | 0.695 | 171 | 29 | 42 | 0.54 |
| 50 | $1,043,048 | 498 | 1,752 | 52.0 | 0.696 | 171 | 30 | 54 | 0.54 |
| 55 | $1,120,156 | 348 | 1,725 | 52.0 | 0.658 | 171 | 30 | 56 | 0.54 |
| 60 | $1,270,201 | 348 | 1,768 | 52.0 | 0.662 | 171 | 30 | 63 | 0.54 |
| 65 | $1,424,364 | 379 | 1,813 | 52.0 | 0.675 | 171 | 31 | 60 | 0.54 |
| 70 | $1,558,320 | -492 | 121 | 53.4 | 0.225 | 171 | 6 | 330 | 0.10 |
| 75 | $1,555,682 | -1,368 | 154 | 52.0 | 0.644 | 171 | 5 | 248 | 0.10 |
| 80 | $1,514,246 | -1,355 | 175 | 52.0 | 0.615 | 171 | 8 | 231 | 0.10 |
| 85 | $1,424,427 | -1,449 | 24 | 52.2 | 0.481 | 171 | 5 | 234 | 0.10 |
| 90 | $1,315,347 | -1,517 | 19 | 52.0 | 0.266 | 171 | 4 | 220 | 0.10 |

The curve has **three regimes and none of them is a game**:

1. **Days 1–15, growth.** Population 144 → 1,872, net income peaks at
   **$2,667/gh** on day 10, 171 buildings go up.
2. **Days 15–67, the plateau.** The city stops. Building count is frozen at
   **171** for **fifty-three consecutive game-days** — over the run
   `cmd_place_building` answers `E_NO_SITE` **1,834 times** and `E_UNSERVED`
   **300 times** against **198** successes, and the agent, which by design never
   buys a transformer, has nothing left to do but upgrade (61 upgrades) and bank
   the difference. Treasury runs from **$16,710** on day
   20 to **$1,424,364** on day 65 with nothing to spend it on. Happiness is
   pinned at exactly 52.0 for the whole stretch (§9 F-5); minimum condition sits
   at 0.54, just under doc 03 §2.2's `COND_FLOOR` 0.55, for forty game-days.
3. **Days 68–90, the cascade and after.** Population 1,813 → **19** in under a
   game-week, open incidents peak above 330, net income goes to **−$1,500/gh**
   and stays there. The run ends with **$1,315,347 in the bank and 19 residents.**

The plateau is the finding. A player who reaches game-day 20 has a city that
cannot grow, an income that cannot rise, and a treasury that cannot be spent —
and the only event left in their future is the one that destroys it. Everything
§9 recommends (a reachable transformer wall, F-4; a smaller READY core, F-8; a
fleet that grows, F-3) exists to give days 16–67 something to be.

---

## 9. Findings

Each finding is **evidence → doc anchor → recommendation with the exact key**.
Recommendations are proposals for the lead engineer; **no `data/*.json` was
touched by this pass.**

### F-1 — Doing nothing is now, by a wide margin, the richest a player can be

**Evidence.** Over 21 game-days `do_nothing` ends with **$199,427** in cash. The
best-funded agent that actually plays ends with **$79,712** (`tax_squeezer`),
and the "competent" agent ends with **$17,843**. Over the whole three
weeks the control sees **4 incidents**, **0.04 %** of building-time dark, **0** damaged
buildings at the end, and stability **0.9478**. Its curve is a straight line of
**+$8,306/game-day** that never bends.

The pressure systems that pass 1 said would bend this curve have all landed —
and none of them touch it, because every one of them scales with the city:
`crime_per_1000_pop` 0.012 on a population of 144, `transformer_per_node` 0.0012
on 24 nodes, `structure_fire_global_scalar` 0.4 against 34 buildings' `fire_load`.
A 34-building city is below every threshold in doc 06.

**Anchor.** Constitution §1 — *"You built it. Now keep it alive."* Doc 06 §2.6's
generator rates; doc 07's `DirectorInputs`.

**Interpretation.** This is not the same finding as pass-1 F-1. Pass 1's null
strategy won because nothing existed to threaten it. This one wins because
*everything that exists is proportional to what the player built*. That is a
defensible design for incident **volume**, but it means the founding city is a
risk-free savings account, and doc 03's own pacing model (§2.12, "competent but
not optimal play") is scored against a baseline that beats it.

**Recommendation (ruling needed).** Do **not** raise the ambient rates — that
would multiply the late-game cascade in §9 F-3, which is already too strong. The
honest lever is a **floor** rather than a slope, and it belongs to the Director,
not to the generators:

- `data/director.json` — add a minimum scheduled-event cadence that does not
  scale with city size, so a 34-building city still gets a storm and a
  transformer failure inside the first game-week. This is also exactly what doc
  93 §C.3's scripted tutorial needs, so the two asks are the same ask.
- Do **not** move `data/incidents.json` `generator_base_rates.*`. Every one of
  those is calibrated per-asset by report 98 R-11/R-13, and raising them to
  pressure a small city would make a large one unplayable.

### F-2 — Maintenance is unpriced: the agent that never repairs wins

**Evidence.** `disaster_neglect` is `balanced` with `maintains = false` and
nothing else changed. Over 21 game-days, mean of three seeds:

| | `balanced` | `disaster_neglect` | delta |
|---|---|---|---|
| treasury d21 | $17,843 | **$32,238** | **+81 %** |
| value created | $943,385 | **$1,054,907** | +12 % |
| population | 1,030 | **1,452** | +41 % |
| happiness | 58.9 | **64.1** | +5.2 |
| stability | 0.7046 | **0.7507** | +0.046 |
| repair spend | $7,966 | **$0** | — |
| min condition | 0.600 | 0.900 | — |

Per seed, the picture is sharper and more damning:

| seed | balanced treasury | neglect treasury | balanced repairs | neglect repairs | note |
|---|---|---|---|---|---|
| 1337 | **−$12,724** | $32,471 | 14 | 0 | the cascade hit `balanced` and missed `neglect` |
| 4242 | $33,442 | $31,043 | **0** | 0 | indistinguishable |
| 9001 | $32,810 | $33,199 | **2** | 0 | indistinguishable |

**Read the middle two rows first.** On the two seeds where no cascade fired,
`balanced` performed **zero and two** repairs in 504 game-hours each — because
there was nothing to repair. The maintenance queue fires below condition 0.90,
and the lowest condition anywhere in those two cities across three game-weeks
was **0.90 and 0.80**. Seed 1337's $45k gap is chaotic divergence (a repair
consumes construction-crew capacity, which shifts every subsequent RNG draw into
a different weather and incident stream), not a causal effect of repairing —
which is itself the point: **the maintenance verb has so little to do that its
main measurable effect is to perturb the seed.**

**The mechanism.** `Building.apply_decay(dt_h, overload_excess,
powered_fraction, weather_decay_mult)` — the doc 02 §2.6 wear model — is called
**only from `tests/test_building.gd`**. Nothing in `sim/` calls it. So condition
does not creep; it only jumps, in discrete lumps, when an incident lands on the
building. `data/buildings.json` authors `decay_per_hour` on all 60 archetype
levels (apartment L1 = 0.0005/gh, i.e. condition 1.00 → the 0.35 auto-damage
threshold in 1,300 game-hours ≈ 54 game-days) and every one of those numbers is
dead data.

**Anchor.** Doc 02 §2.6 (condition & decay); doc 03 §2.4
`MAINT_CONDITION_PENALTY`; doc 03 §2.2 `COND_FLOOR 0.55`; doc 93 §B
(`cmd_repair_building` — *"condition decay already punishes neglect"* — it still
does not). Pass-1 F-8, unchanged.

**Recommendation (highest-value item in this report).**
1. **Wire the decay call.** `HourlyPhaseSystem.advance_fine` already holds
   everything `apply_decay` needs: `availability` from `grid.settle_hour()` is
   `powered_fraction`, the serving node's overload is on the grid, and doc 07's
   `get_effect()` publishes `weather_decay_mult`. One call per building per
   settled hour, before the economy settles. Until this exists there is no
   routine input to the repair verb, and the entire second half of the
   constitution's sentence is unreachable.
2. **Do not touch a single repair or condition constant until it is wired.**
   `data/economy.json` `expenses.REPAIR_COST_PER_CAPITAL`, `tax.COND_FLOOR`
   0.55, `expenses.MAINT_CONDITION_PENALTY` and every
   `data/buildings.json` `decay_per_hour` are currently being measured against a
   city where wear does not happen. Any number fitted to that will be wrong
   twice.
3. Once decay is live, re-run this exact A/B. `disaster_neglect` losing to
   `balanced` is the acceptance test for the core loop, and it should be added to
   §10's gate table as a hard one.

### F-3 — The fleet is frozen at eight vehicles, and that is what kills every city

**Evidence.** `FleetSystem.populate_from_stations()` has **exactly one caller**,
`CitySim._boot_incidents()` (`sim/city_sim.gd:204`), which runs once at boot.
Measured directly: a booted starter city has a fleet of **8**; place a
`fire_station`, run 72 game-hours until it completes, and `station_rows()`
reports the new station while `fleet.size()` is **still 8**.

Incident volume, meanwhile, scales with the city. Per run, mean of seeds:

| strategy | buildings end | incidents created | resolved | abandoned | fire_spread | open incidents (mean/hour) |
|---|---|---|---|---|---|---|
| `do_nothing` | 34 | 4.0 | 4.0 | 0.0 | 0.0 | 0.01 |
| `infrastructure_first` | 81 | 10.0 | 10.0 | 0.0 | 0.0 | 0.02 |
| `disaster_neglect` | 352 | 338.3 | 318.7 | 0.0 | 0.3 | 7.59 |
| `greedy_growth` | 171 | 445.3 | 373.7 | 25.3 | 27.0 | 11.25 |
| `balanced` | 317 | 433.7 | 299.7 | 59.0 | 70.3 | 18.68 |
| `tax_squeezer`¹ | 292 | 827.0 | 498.5 | 145.5 | 223.0 | **68.44** |

¹ two seeds (§0).

Eight vehicles against 68 simultaneous open incidents. `incident_abandoned` —
the dispatcher giving up — reaches 145 per run. `fire_spread` reaches 223: fires
that no engine gets to, spreading building-to-building, which is precisely the
§5.4 cliff. Note `incident_failed` is **0** in every row: incidents do not fail,
they queue forever and burn. The one run that finished with the largest city
(`disaster_neglect`, 352 buildings) is *not* the one with the worst backlog —
the backlog tracks how far into the cascade the run got, not how big it was.

**Anchor.** Doc 06 §2.x fleet capacity; `data/vehicles.json`
`types.<id>.capacity_per_station_level` (patrol car `[2,3,4,5,6]`, fire engine
similar) — an authored ladder per station level that the sim reads exactly once.
Doc 06's `load_damper()` already anticipates saturation
(`excess = max(0, open_incidents − fleet.size())`) but damps the *generation
rate*, not the backlog.

**Recommendation (ruling needed; this is the top mechanical fix).**
1. **Re-populate the fleet when the station roster changes.** Call
   `incidents.fleet.populate_from_stations(incident_world.station_rows())` from
   `CitySim.on_construction_completed` (station archetypes only) and from
   `cmd_demolish_building`, or give `FleetSystem` an incremental
   `sync_stations()`. This is a code fix, not a balance edit, and it converts
   `fire_station` from a pure cost line (`data/economy.json`
   `expenses.station_upkeep_l1.fire_station` = 30 $/gh, pass-1 F-6) into the
   answer to the cascade. **Until it lands, no incident-rate constant should be
   retuned**, because the city has no way to buy response capacity.
2. Once it lands, the honest tuning question becomes the *ratio* of
   `data/vehicles.json` `capacity_per_station_level` to
   `data/incidents.json` `generator_base_rates.structure_fire_global_scalar`
   (0.4). Recommend re-running this matrix before touching either.
3. Separately, consider whether an abandoned incident should be able to *fail*
   rather than queue. `balanced` seed 1337 ends game-day 21 with **183
   simultaneously open incidents** and `tax_squeezer` seed 1337 with **339** —
   a backlog the player can never clear and doc 12's incident drawer can never
   usefully show. `incident_failed` fired **zero** times in 17 runs.

### F-4 — The transformer is priced well; the problem is that nothing makes you buy one for two game-weeks

**Evidence (price).** The L1 tap costs `$500 + $110 × lateral tiles`, i.e.
**$610 at one tile, $720 at two, $1,380 at eight** (the tap radius limit). The
controlled experiment: one tap at the densest dark patch cost **$1,270**, lit
**35** buildable tiles, and the 19 houses that fit on them added **+$174/gh**
(mean of three seeds). Payback:

- **tap alone: 7–8 game-hours.**
- tap + the houses it enables: **134–145 game-hours (5.6–6.0 game-days)**, which
  is simply the payback of a house.

The verb is close to free relative to what it unlocks. It is not mispriced.

**Evidence (pacing).** The founding core ships with **510 transformer-served
buildable tiles and 919 unserved ones**. `greedy_growth` — the fastest possible
builder, three actions per game-hour, zero reserve — does not see its first
`E_NO_SITE` until **game-hour 362 — game-day 16** — and its first `E_UNSERVED`
in that same hour. `balanced` never buys a transformer in 21 game-days on any seed,
because it never runs out of 1×1 ground. Only `infrastructure_first`, which buys
land, ever needs the verb — and it needs it *because* a block bought and
developed through doc 09 §2.3 arrives with a utility corridor to its centre and
**no transformer**, so all 256 of its tiles answer `E_UNSERVED`.

**Anchor.** Doc 93 §A calls `cmd_place_grid_component` "THE game" and doc 93 §B
ranks it first. Doc 04 §2.1. Doc 09 §2.3's `utility_corridor` phase.

**Recommendation (ruling needed — this is a starter-city shape question, not a
price question).** Do **not** move
`data/economy.json` `expenses.grid_components.transformer.build_cost` or
`expenses.grid_components.feeder.cost_per_tile_overhead`. The measured payback
says both are right. Instead, make the verb reachable:

1. **Thin the founding grid.** `data/starter_city.json` `power.nodes` currently
   serves 510 of the core's 1,429 buildable tiles. Cutting the authored
   transformer roster so the founding core has ~60–100 served tiles puts the
   first `E_UNSERVED` inside game-day 1–2, which is where doc 93 §C.3's tutorial
   beat wants it, and it costs nothing but an authored-data edit. Every
   consequence is already tested: `tests/test_playtest_harness.gd` asserts the
   harness's siting heuristic against `PowerGrid.TRANSFORMER_SERVICE_RADIUS`, and
   the pass-2 harness will show the change as a shift in first-`E_UNSERVED` hour.
2. Alternatively (or additionally), raise the **land** side: the city can grow
   to 500+ buildings inside nine blocks it already owns. See F-8.

### F-5 — Doubling the tax rate is a 78 % revenue multiplier bought for a happiness number that changes nothing

**Evidence (static).** Thirteen booted cities, one per detent, one game-week
each, nothing else touched:

| level | rate | policy factor | treasury after 7 gd | net $/gh | pop | happiness | stability |
|---|---|---|---|---|---|---|---|
| 0 | 0.04 | 0.4444 | $16,423 | **−51.1** | 144 | 93.2 | 0.9475 |
| 5 (base) | 0.09 | 1.0000 | $83,198 | 346.4 | 144 | 82.2 | 0.9475 |
| 12 (max) | 0.16 | 1.7778 | **$166,011** | **839.4** | **144** | 66.8 | **0.9475** |

Level 12 earns **exactly twice** level 5's treasury over a game-week. Population
is **144 at every detent** and stability is **0.9475 at every detent** — the two
channels doc 03 §2.2 says the tax rate is supposed to cost you.
`growth_rate_multiplier` 0.755 has no observable effect because the founding
city has no growth to slow, and `happiness_tax_delta −15.4` lands happiness at
66.8, which is still comfortably inside `HAPPY_FACTOR_MIN/MAX`'s band and
therefore costs a few percent of revenue against a 78 % gain.

Note also that **level 0 is a trap**: at r = 0.04 the founding city runs at
−$51/gh and slowly dies. The ladder is not symmetric around the base.

**Evidence (dynamic).** `tax_squeezer` vs `balanced` — same builder, only the
detent differs — over 21 game-days:

| | mean of seeds¹ | seed 4242 only² |
|---|---|---|
| value created | $1,377,722 vs $943,385 — **+46 %** | $1,551,746 vs $1,060,303 — **+46 %** |
| treasury d21 | $79,712 vs $17,843 — **+347 %** | $162,001 vs $33,442 — **+384 %** |
| happiness | 44.0 vs 58.9 — **−14.9** | 45.7 vs 61.9 — **−16.2** |
| population | 912 vs 1,030 — −11 % | 1,816 vs 1,390 — **+31 %** |

¹ `tax_squeezer` two seeds, `balanced` three; both means are contaminated by
seed 1337's cascade (§9 F-10).
² the one seed on which neither agent's city collapsed inside the horizon — the
cleanest paired comparison in this report.

On the clean pair the growth penalty does not appear **at all**: the
max-tax city ends with 31 % *more* people than the base-rate city, because the
extra revenue bought floorspace faster than `growth_rate_multiplier` 0.755 slowed
occupancy. The published −15.4 happiness shows up almost exactly (−16.2) and
costs nothing that shows up in any other column.

**Anchor.** Doc 03 §2.2; `data/economy.json` `tax.TAX_RATE_HAPPINESS_COEFF`
220.0, `tax.TAX_RATE_GROWTH_COEFF` 3.5, `tax.TAX_RATE_MAX` 0.16,
`tax.TAX_RATE_COOLDOWN_HOURS` 48, `tax.HAPPY_SLOPE` 0.5,
`tax.HAPPY_FACTOR_MIN` 0.75 / `HAPPY_FACTOR_MAX` 1.25.

**Recommendation (ruling needed — one of these three, not all).**
1. **Cheapest and most targeted: raise `tax.TAX_RATE_GROWTH_COEFF` from 3.5.**
   At 3.5, the top detent multiplies growth by 0.755 and costs 11 % of
   population against +46 % value. A coefficient near **8.0** would put the top
   detent at ~0.44× growth, which is a real choice: money now versus a city
   later. This is one number, it is already read on every settlement
   (`EconomySystem.growth_rate_multiplier`), and it does not touch revenue.
2. **Or make happiness bite harder**: `tax.HAPPY_FACTOR_MIN` 0.75 is the floor of
   the revenue multiplier that happiness buys. Widening it (e.g. 0.55) makes a
   66.8-happiness city visibly poorer per building. Riskier, and for a reason
   the 90-game-day run makes plain: **happiness saturates.** From game-day 20 to
   game-day 68 the greedy city's happiness sits at **exactly 52.0**, unmoved,
   while stability wanders between 0.64 and 0.70 and open incidents climb from
   27 to 63. `HappinessModel.target` is `60 + 14·u(stability) + 8·u(uptime) +
   8·u(employment) + 6·u(condition) + tax_delta` with every `u` a unit ramp
   clamped to ±1 over a narrow window, so a city at 46 % dark is already pinned
   at −1 on two terms and cannot get any unhappier for any additional damage.
   52.0 is `60 − 14 − 8 + 8 + 6` to the decimal. Any lever routed through
   happiness therefore acts as a step, not a gradient, for every large city —
   which is precisely why lever (1) is the recommendation.
3. **Do not clamp `TAX_RATE_MAX`.** The ladder's top detent existing is fine; it
   simply has to cost something. Note also that if (1) is adopted, the
   `tax_squeezer` strategy in this harness becomes the regression test for it.

Separately and independently: **level 0 running the founding city at a loss**
should be a deliberate ruling, not an accident. If it is intended (a "starve the
city" option), doc 03 §2.2 should say so; if not, `tax.TAX_RATE_MIN` 0.04 wants
raising to the break-even detent, which the table puts between 0.04 and 0.05.

### F-6 — Sprawl still beats upgrading, until the footprint runs out — and then upgrading is all there is

**Evidence.** `greedy_growth` scores builds and upgrades on the same axis and
takes the better one. Its action log (seed 4242) reads:

```
place apartment  OK          n=109   first at game-hour 27
place house      OK          n= 28   first at game-hour 0
place apartment  E_NO_SITE   n=162   first at game-hour 362
place apartment  E_UNSERVED  n= 24   first at game-hour 362
upgrade  …       OK          n= 42   first at game-hour 378
```

**Zero upgrades before game-hour 378 (day 16); 42 after.** The switch is not a
change of mind, it is the 2×2 apartment footprint running out of served ground.
Pass-1 F-5 measured the same dominance with no upgrades at all in 14 game-days;
the ladder has not become more attractive, the map has become fuller.

**Anchor.** Doc 02 Core Design Rule 5; doc 03 §2.2 `base_tax_by_level` (LOCKED by
RR-5); `data/building_rules.json` `growth_classes.k_out`.

**Recommendation.** Unchanged from pass 1 and reinforced: **do not reprice
`base_tax_by_level`.** The ladder is dominated because floorspace inside an
owned block is free, and the fix is the land/grid scarcity of F-4 and F-8, not a
yield edit. Revisit `growth_classes.k_out` only if the ladder is still dominated
after the footprint actually becomes scarce.

### F-7 — A city can now go $12,724 into the red with the entire doc 03 §2.10 recovery ladder asleep

**Evidence.** `balanced` seed 1337 ends at **−$12,724** with a minimum of
**−$13,309**. In that same run:

| §2.10 layer | key | value at day 21 | expected |
|---|---|---|---|
| credit limit (layer 3) | `recovery.CREDIT_LIMIT_DAYS_OF_REVENUE` 6 | **$20,000** | ~6 game-days of gross revenue |
| austerity (layer 2) | `recovery.AUSTERITY_EXPENSE_MULT` 0.55 | **false** | engaged |
| deferred liability (layer 4) | `recovery.DEFERRED_REPAY_FRACTION` 0.35 | **0** | accruing |
| relief grants (layer 5) | `recovery.RELIEF_MIN` 8000 | never offered | offered |
| `credit_line_engaged` events | — | **0** across all 17 runs | ≥1 |

`Treasury.update_credit_limit()`, `update_austerity()` and
`maybe_grant_relief()` still have no caller in `sim/` outside tests. The credit
limit is therefore pinned at `CREDIT_LIMIT_FLOOR` for the whole game.

**And the latent bug from pass-1 F-9 is still live and has grown.** Six call
sites now discard the result of `Treasury.spend()`:

```
sim/city_sim.gd:763   treasury.spend(cost,  &"construction")          # cmd_place_building
sim/city_sim.gd:828   treasury.spend(cost,  &"construction")          # cmd_upgrade_building
sim/city_sim.gd:912   treasury.spend(cost,  &"construction")          # cmd_place_grid_component
sim/city_sim.gd:1091  treasury.spend(cost,  &"repair", …)             # cmd_repair_building
sim/city_sim.gd:1305  treasury.spend(price, &"land", …)               # cmd_buy_block
sim/city_sim.gd:1423  treasury.spend(cost,  &"construction", …)       # development phases
```

`Treasury.AUSTERITY_BLOCKED_CATEGORIES` contains `&"construction"`, and a blocked
`spend()` charges nothing and returns `ok = false`. The day austerity is wired,
every build, every transformer, every land purchase and every development phase
placed under austerity is **free**.

**Anchor.** Doc 03 §2.10 layers 2/3/4/5; doc 03 §5 ("every earn/spend goes
through `credit()`/`spend()`").

**Recommendation.** Unchanged from pass-1 F-9 but now with a live negative
balance behind it: call the three ladder functions from `HourlyPhaseSystem` (they
need only trailing gross revenue and gross expense, both already in the
`BudgetSnapshot` that `EconomySystem.settle_hour()` returns), and make all six
`cmd_*` sites read the `spend()` result and fail with its `reason_code`. **Fix
the second half first**, or turning the ladder on ships a free-everything
exploit. No `data/economy.json` `recovery.*` value needs to move — they have
simply never been exercised.

### F-8 — Land is priced for a city that runs out of room, and no city runs out of room

**Evidence.** A ring block costs **$10,400–$16,700** to buy plus
**$34,588–$49,570** to develop — call it **$45k–$66k all-in**, against a
founding treasury of $25,000 and a `do_nothing` income of $8,306/game-day. That
is a serious, well-shaped purchase.

Nobody makes it. Over 21 game-days: `greedy_growth` **0 blocks**, `balanced`
**0.3 blocks**, `disaster_neglect` **0.3**, `infrastructure_first` **1.0**,
`tax_squeezer` **2.5**. The reason is not the price — it is that the nine
founding blocks hold **1,429 buildable tiles** and the biggest city any agent
built in three game-weeks stood on **352 buildings**. `E_NO_SITE` appears only
for the 2×2 apartment footprint, only after game-day 16, and only for the single
fastest builder.

**Anchor.** Doc 09 §2.5; doc 03 §2.7 `land.LAND_BASE` 9000,
`land.LAND_ESCALATION` 0.06; doc 03 §2.8 `development.phases[].base`.

**Recommendation.** The land *price* needs no ruling — it is never tested. What
needs a ruling is the **founding footprint**: `data/starter_city.json` ships nine
owned+READY blocks (`land.STARTER_BLOCKS_FREE` 9). Reducing the READY core to
**four or five** blocks would make expansion a real mid-game decision, put the
$45k land bill on the critical path where it was designed to sit, and — with
F-4's thinner grid — make the two headline verbs (`cmd_buy_block`,
`cmd_place_grid_component`) the spine of the first game-week instead of
optional. Both are authored-data edits with no code change and no constant move.

### F-9 — The online/offline gap has all but closed, and the reason is F-3's fix, not a fidelity fix

**Evidence.** Same seed, same scripts, both paths, 7 game-days:

| strategy | seed | value online | value offline | offline edge | pop on/off | stability on/off | dark % on/off |
|---|---|---|---|---|---|---|---|
| do_nothing | 1337 | $84,442 | $83,198 | -1.5% | 144 / 144 | 0.9475 / 0.9475 | 0.00 / 0.00 |
| greedy_growth | 1337 | $267,694 | $233,731 | -12.7% | 930 / 832 | 0.9169 / 0.9211 | 1.27 / 0.80 |
| balanced | 1337 | $205,390 | $206,534 | +0.6% | 592 / 580 | 0.9479 / 0.9449 | 0.26 / 0.56 |
| disaster_neglect | 1337 | $209,560 | $206,773 | -1.3% | 580 / 586 | 0.9442 / 0.9396 | 0.46 / 0.55 |
| **all 4 pairs** | | | | **mean -3.7%, median -1.4%, offline ahead in 1 of 4** | | | |

Pass 1 measured **mean +17.3 %, median +7.5 %, offline ahead in 10 of 12** —
offline players were measurably luckier. This pass measures **mean −3.7 %,
median −1.4 %, offline ahead in 1 of 4**. `do_nothing` is now identical on both
paths to 1.5 %, where pass 1 had it at +13 % on the worst seed.

**But nothing was fixed in the coarse path.**
`CitySim.PowerPhaseSystem.advance_coarse()` (`sim/city_sim.gd:1649`) still calls
`advance_fine(ctx)` unconditionally, with its own comment quoting the doc 04
§2.12 precondition it never checks. What changed is pass-1 F-3: component
failures used to be permanent, so the paths' differing blackout resolution
compounded forever; now doc 06's dispatch repairs them and the difference stays
local. The gap is smaller because the ratchet is gone, not because the fidelity
rule arrived.

The blackout channel still diverges by the amount doc 04 §2.12 predicts:
`greedy_growth` spends **1.27 %** of building-time dark online and **0.80 %**
offline — a 59 % relative difference on exactly the channel that
`ROLLING_SHED_PERIOD_GM` (30 game-minutes) and the LIT/DARK hysteresis (20/10
game-seconds) cannot resolve inside a single 3,600-game-second step.

**Anchor.** Doc 04 §2.12's fidelity rule; constitution §4; doc 93 §E2
(mode-invariance is per-system and each subsystem's suite bounds its own
sanctioned parity).

**Recommendation.** Unchanged in substance from pass-1 F-4, but the priority
drops: implement the fidelity rule in `PowerPhaseSystem.advance_coarse` — track
whether any component ended the previous step with `r > 1.0` (or a storm is
active) and if so run `grid.tick(300, …)` twelve times instead of
`grid.tick(3600, …)` once. No `data/*.json` key moves.

**The budget claim from pass 1 no longer holds and should be re-checked before
this is scheduled.** Pass 1 justified the 12× sub-step by quoting
`tests/test_milestone1.gd`'s P0-30 probe at **0.82 ms/coarse-step**; with Wave 1
integrated the same probe now reports **≈28.6 ms/step**, and `max_coarse_hours`
at the 2-second budget has fallen from the 720 cap to **72**. A blanket 12×
sub-step of the grid phase on overloaded hours is no longer obviously free, and
the fidelity rule's own precondition (*only* when something ended overloaded, or
a storm is active) is doing much more work than it was. Measure before
implementing.

Until then, doc 08's WHILE YOU WERE AWAY sheet is describing a city
whose *blackout* history is understated by roughly a third, even though its
*money* is now honest to a few percent — and this report's headline matrix,
being coarse, is understating dark-time by the same factor.

### F-10 — Three seeds are not enough, because the outcome is a coin flip

**Evidence.** `tax_squeezer` seed 1337 ends with **7 residents and −$2,577**;
seed 4242 ends with **1,816 residents and $162,001**. Same strategy, same
horizon, same everything except the RNG seed. `greedy_growth` seed 1337 ends at
415 population and stability 0.4325; seeds 4242 and 9001 end at ~1,900 and
~0.68. `balanced` seed 1337 goes bankrupt; 4242 and 9001 do not.

In every case the split is the same event: whether the §5.4 cascade fired inside
the horizon. It is not a difficulty gradient — it is a **bimodal outcome**, and a
three-seed mean over a bimodal distribution is a number with no meaning. Several
of the aggregate rows in §3 are dominated by one seed's catastrophe.

**Recommendation (two, one for the harness and one for the game).**
1. **Harness (mine, next pass).** Raise the default seed count from 3 to 8 and
   report median plus min/max rather than the mean, at least for the columns the
   cascade dominates. A per-strategy "cascade fired: n of m runs" column is more
   informative than any mean in §3. `tools/playtest.gd` `DEFAULT_SEEDS`.
   Prerequisite: `Api.upgrade_candidates()` previews every standing building on
   every call and is called up to six times per game-hour by `greedy_growth`,
   which is why one run of this matrix did not finish (§0). Eight seeds needs
   that scan bounded first — most likely by ranking on the *cheap* fields
   (level, archetype, condition) and previewing only the top few — which is a
   behaviour change and so belongs to a pass boundary, not to a re-run.
2. **Game (ruling needed).** A single unrecoverable cascade that takes a city
   from 1,629 people to 0 in two game-days, with no recovery over the following
   game-week, is a failure state disguised as a difficulty curve. Doc 03 §2.10's
   recovery ladder (F-7) is precisely the mechanism that is supposed to catch
   this, and it is asleep. **Wire F-7 before tuning F-3's fleet**, so that the
   measurement of "how hard should the cascade be" is taken on a game that has
   its safety net switched on.

---

## 10. Proposed regression gates for the next run

Not implemented as tests by this pass — they are proposals, and several of them
should *fail* today on purpose.

| gate | today | proposed threshold |
|---|---|---|
| founding first settled hour, net $/gh | 348.68 | ruled figure ±1 % (§4) |
| founding first game-day net | $8,351 | ruled figure ±1 % (§4) |
| `do_nothing` 21-day treasury | $199,427 | **upper** bound; must fall once F-1's Director floor lands |
| `balanced` beats `disaster_neglect` on value at d21 | ✗ ($943k vs $1,055k) | **must hold** once decay is wired (F-2) |
| `balanced` beats `do_nothing` on cash at d21 | ✗ ($17,843 vs $199,427) | must hold |
| minimum building condition after 21 game-days, `do_nothing` | 1.000 | < 1.000 once decay is wired (F-2) |
| fleet size after building a station | 8 (unchanged) | > 8 (F-3) |
| open incidents, mean/hour, `balanced` | 18.68 | ≤ 3 once the fleet tracks stations (F-3) |
| `incident_abandoned` per run, `balanced` | 59.0 | ≈ 0 (F-3) |
| first `E_UNSERVED` for `greedy_growth` | game-hour 362 | < game-hour 48 once the founding grid is thinned (F-4) |
| blocks bought by `balanced` in 21 game-days | 0.3 | ≥ 2 once the READY core is trimmed (F-8) |
| `tax_squeezer` value vs `balanced` at d21 | +46 % | ≤ +10 % once `TAX_RATE_GROWTH_COEFF` is ruled (F-5) |
| `credit_line_engaged` events on a run that ends negative | 0 | ≥ 1 (F-7) |
| `cmd_place_building` on a locked archetype | succeeds | must return `E_CITY_LEVEL` (pass-1 F-7) |
| offline/online value edge, 7 game-days | mean −3.7 % | \|Δ\| ≤ 5 % held once doc 04 §2.12's fidelity rule is implemented (F-9) |
| offline/online **dark %** edge, `greedy_growth`, 7 game-days | 1.27 vs 0.80 (−37 %) | \|Δ\| ≤ 10 % (F-9) |
| matrix runs completed | 17 of 18 | 18 of 18, then 8 seeds (F-10) |

---

## 11. What this pass still could not see

| system | state in this run |
|---|---|
| building wear (doc 02 §2.6) | `apply_decay` has no caller; `decay_per_hour` is dead data on all 60 archetype levels (F-2) |
| coverage gating (doc 02 §2.4) | `req_fire_coverage` / `req_police_coverage` are loaded, validated and read by nothing — so civic buildings are still pure cost (pass-1 F-6) |
| fleet growth (doc 06) | frozen at the founding 8 vehicles (F-3) |
| recovery ladder (doc 03 §2.10) | never engages (F-7) |
| `min_city_level` on placement | not enforced by the sim (pass-1 F-7, unchanged) |
| demolition | no strategy had a reason to demolish; `cmd_demolish_building` is exercised only by its own tests |
| difficulty multipliers | every run is at `M_build`/`M_repair`/`M_land` = 1.0; the difficulty ladder is untested by the harness |
| the fine path at scale | only a 7-game-day paired subset (F-9); the 21-day matrix is coarse-only |

---

## 12. Changelog

| pass | date | what changed |
|---|---|---|
| **1** | 2026-08-18 | First harness pass. 24 runs (4 strategies × 3 seeds × 2 paths × 14 game-days) against a sim with two player verbs and no pressure systems. Findings F-1 … F-11. No `data/` change. |
| **2** | 2026-08-19 | Post-Wave-1 integration. Strategies rewritten to use the full doc 93 §B verb set; `tax_squeezer` and `disaster_neglect` added as single-variable variants of `balanced`; two controlled micro-experiments added (transformer payback, tax ladder); schema → 2; `tests/test_playtest_harness.gd` grows six behavioural tests (909 suite tests green). 17 of 18 matrix runs (6 strategies × 3 seeds × 21 game-days, `tax_squeezer` seed 9001 excepted — §0) + a 90-game-day late curve + a paired 7-day fine/coarse set. Findings F-1 … F-10 restated from new data. No `data/` change. |
