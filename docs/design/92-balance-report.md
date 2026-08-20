# 92 — Balance report: the game as a game

> **PASS 3 IS §13–§16 (2026-08-19, Wave 4) — the maintenance fit.** §13 rebuilds
> `balanced` into a credible player and fits the maintenance pacing (one constant
> moved, `tax.COND_FLOOR` 0.55 → 0.40; `decay_per_hour` and
> `MAINT_CONDITION_PENALTY` **held with the measurements that hold them**). §14
> implements F-4's founding-grid thinning (23 → 18 transformers) and establishes
> the geometric floor that makes doc 92 pass-2's "wall before game-hour 48" a
> core-size ruling rather than a grid edit, and declines F-8 with data. §15 is
> the new 18-of-18 matrix and the headline ordering. §16 lists the doc 03 / doc
> 09 edits this pass could not make itself. **§3–§8's tables are pass 2's and
> remain historical; §15 supersedes them.**

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

# the pacing rate (§18.3). 12 seeds, because an incident rate measured on one
# seed is a sample and not a rate. Flip `ambient_floor.enabled` in
# data/incidents.json to reproduce the floor-off column of the same table.
~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
    -s res://tools/playtest.gd -- --days=28 --mode=coarse --strategies=do_nothing \
    --seeds=1337,4242,9001,101,202,303,404,505,606,707,808,909

# the 50-game-day pair, past the pacing horizon (§15.2, re-run in §19.5)
~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
    -s res://tools/playtest.gd -- --days=50 --mode=coarse --seeds=1337 \
    --strategies=balanced,disaster_neglect

# every table in this document, regenerated from those files
python3 tools/playtest_report.py build/playtest --mode coarse --days 21
python3 tools/playtest_report.py build/playtest --mode coarse --days 7 --section compare
```

Seeds `1337, 4242, 9001`. Run files are
`build/playtest/<strategy>_seed<N>_d<D>_<mode>.json` (schema_version 2) and are
**not committed** — they are regenerated per merge. Since §18 the `events` block
of every run file also buckets `incident_created` **by incident type**
(`incident_created:crime`, …); the terminal table's `WATCH` list still prints the
total only, so the mix is read off the JSON.

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
| `tax_squeezer` value vs `balanced` at d21 | +46 % | ≤ +10 % once `TAX_RATE_GROWTH_COEFF` is ruled (F-5) — **superseded by §20**: value is the wrong column, because a richer agent *should* create more value. The Wave-7 ruling gates the **population** column instead (gate 12c: `tax_squeezer` trails by ≥ 10 %), and value at +35 % is what makes the detent still worth pulling. |
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
| **3** | 2026-08-19 | **The maintenance fit** (Wave-4 rulings 1–5). `balanced` rebuilt as a two-ladder agent with a budget-gated maintenance line, a station roster and a land fund (§13.1); the maintenance pacing fitted against matrix runs — `REPAIR_THRESHOLD` 0.90 → **0.80**, `tax.COND_FLOOR` 0.55 → **0.40**, `decay_per_hour` and `MAINT_CONDITION_PENALTY` **held with the measurements** (§13.2–13.4); F-4's founding-grid thinning implemented, **23 → 18 transformers**, and its geometric floor established (§14.1); F-8 **declined with data** (§14.2); `Api.upgrade_candidates` bounded, closing pass-2 F-10's wall-clock finding (§13.5). **18 of 18** matrix runs at 21 game-days + a paired 50-game-day neglect A/B (§15). Gates 4, 5 and 10 retuned with their measurements; gate 4b added. |
| **6** | 2026-08-19 | **The tax ruling** (Wave 7). `tax.TAX_RATE_HAPPINESS_COEFF` 220 → **360** — the one key that reprices all three of doc 03 §2.2's couplings, because Wave 6's buyable grid gave `tax_squeezer` somewhere to spend ×1.778 revenue and it became strictly dominant again (+104 % value **and +43 % population** for a 1.6-point happiness deficit). Fitted on gate 12b's controlled pair, confirmed on **18 of 18** matrix runs (§20.3–20.4). Gates 12 and 12b retuned with their measurements; **gate 12c added** to hold the ruling's own matrix statement. Save identity verified unchanged on both cities (§20.5). No other `data/` key moved. |

---

## 13. Pass 3 — the maintenance fit

Everything in §13 and §14 is measured on the **online** coarse step
(`tests/balance_matrix.gd` → `BalanceGateRig`), not on an offline catch-up
session, because doc 08 §2.3 rule 1 silences the Disaster Director for the whole
of a catch-up and the pass-2 matrix could not see the pressure it was measuring.
Reproduce with:

```bash
~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
    -s res://tests/balance_matrix.gd -- days=21
~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
    -s tools/run_one.gd -- test_balance_gates.gd      # the 20 gates, ~60 s
```

### 13.1 Ruling 1 — `balanced` is a credible player again

**The finding it answers.** Pass 2 and the Wave-3 report both recorded the same
defect: once doc 02 §2.6 wear is live the maintenance queue is never empty, and
`Balanced.act` was a single-action ladder with a **repair-first early return**.
The agent therefore spent roughly half of every game-hour's action budget on
maintenance and stopped growing — it banked instead. Measured, seed 1337, 21
game-days, pass-2 agent: **153 buildings, 242 repairs, $480,480 of idle cash**.
That is not a competent player, and it poisoned two gates: `value created`
rewarded the agent that let the city rot, and gate 5 passed only because the
"player" was hoarding.

**The redesign.** `Balanced.act` now runs two independent ladders in the same
game-hour, so neither starves the other:

| ladder | what it does | budget |
|---|---|---|
| **maintenance** | one repair at most, worst condition first, only below `REPAIR_THRESHOLD` | a purse credited `MAINT_BUDGET_SHARE` (0.20) of every settled net, capped at `MAINT_PURSE_DAYS` (7) game-days of accrual against a smoothed net |
| **growth** | expand → unwall → civic → upgrade → floorspace, pass 2's order unchanged | the surplus above `reserve()`, which is one game-day of gross expense **plus the land fund** |

Three details are load-bearing and each was found by measurement, not design:

1. **The purse scan walks DOWN the worst-first queue** (`MAINT_SCAN` 12→24
   quotes) instead of stopping at its head. Repair price is
   `capital × damage_fraction × REPAIR_COST_PER_CAPITAL`, so the worst building
   is usually also the dearest: a head-only budget gate head-of-line blocks
   forever on one civic asset while forty cheap houses rot behind it. Measured
   with the head-only gate: **0 repairs in 21 game-days** with the worst
   building at 0.34.
2. **The purse cap is sized against a smoothed net, not the instantaneous one.**
   Hourly net is spiky (construction-completion hours and storm hours bill very
   differently); capping against one bad hour collapses the purse and strands the
   queue. Measured with an instantaneous cap: **4.9 % of net spent, worst
   building 0.34**. With the EMA: **12.1 %, worst building 0.79**.
3. **The civic rule became a station roster.** Pass 2 built one civic building
   per city level, which doc 92 pass-2 F-3 costed as a pure upkeep line — and
   with C-50 live (a finished station is response capacity) that rule is simply
   wrong play. The rebalanced agent builds a bigger city, and the pass-2 rule
   walked it straight into the §5.4 cascade: **a 266-building city with a
   ten-vehicle fleet reached 558 simultaneously open incidents at game-hour
   384.** `STATION_PER_BUILDINGS` 45 (one more engine house per 45 buildings)
   removes it: same seed, same horizon, **open incidents never exceed 7** and
   `incident_abandoned` is 0 across all 18 matrix runs.

**The land fund.** Pass-2's expansion rule was "buy the next block on an $80,000
surplus", and it worked only by accident — the starving agent banked, so it saw
$80k. The rebalanced agent invests its surplus and never sees it again:
measured, seed 1337, 21 game-days, **0 blocks bought and 0 `E_NO_SITE`**, which
fails gate 11. Expansion is therefore a budget line like maintenance:
`LAND_BUDGET_SHARE` 0.15 of every settled net accrues into a land fund that
`reserve()` counts (so the growth ladder cannot spend it), capped at the quoted
all-in cost of the next block, and the purchase fires when the fund covers it.
Doc 92 F-8 measured that all-in at $45k–$66k per ring block. Result: **2 blocks
per 21 game-days on every seed**, gate 11 green by the map and the money
together.

### 13.2 Ruling 2 — what actually made maintenance a chore

The ruling's premise was that at the authored `decay_per_hour` "a ~120-building
city needs more than 1 repair per game-hour to hold 0.90". That is true, and the
measurement says the culprit is **0.90**, not `decay_per_hour`. The two ruled
targets are set by two different parameters:

```
repair $/gh       = Σ_b capital_b × decay_b × REPAIR_COST_PER_CAPITAL   ← the RATE
repair trips/day  = Σ_b decay_b × 24 / (1 − threshold)                  ← the THRESHOLD
```

The money a maintaining city spends does **not** depend on the threshold at
steady state — a repair restores exactly the condition that was lost, at a price
linear in the loss. Only the *trip count* does, and it scales as `1/(1 − T)`.
So the fit is: pin the rate against the money target and the neglect arc, then
solve the trip count with the threshold.

**Step 1 — is the rate right?** Measured directly, `need = Σ capital × decay ×
0.85` against the settled net, on a live `balanced` run (seed 1337):

| game-hour | buildings | need $/gh | net $/gh | need / net |
|---|---|---|---|---|
| 12 | 44 | 166.5 | 495.1 | 33.6 % |
| 84 | 84 | 184.9 | 902.4 | 20.5 % |
| 108 | 104 | 194.0 | 1,127.8 | **17.2 %** |
| 156 | 150 | 221.3 | 1,717.3 | **12.9 %** |
| 204 | 158 | 270.1 | 2,342.9 | **11.5 %** |
| 300 | 207 | 380.5 | 2,530.7 | **15.0 %** |
| 336 | 224 | 445.8 | 3,214.3 | **13.9 %** |

A played city — the 100–250-building range `balanced` lives in for the whole
pacing horizon — costs **11.5–17.2 % of net** to keep at full condition. The
ruled band is 10–20 %. The founding city reads 33–46 % only because 71 % of its
capital is civic (`power_facility` $60,000, two `water_facility` at $45,000,
`police_station` $18,000, `fire_station` $20,000, `construction_yard` $16,000 of
$287,600 total) against 34 buildings' worth of revenue — and it never has to pay
it, because at the fitted threshold the first repair is not due until game-day 8.

**Step 2 — is the neglect arc right?** Measured on the two agents that never
repair, seed 1337, first crossing of each marker:

| marker | `do_nothing` | `disaster_neglect` | ruled target |
|---|---|---|---|
| worst building < doc 03 `COND_FLOOR` | game-day 19.5 (**2.8 gw**) | game-day 15.5 (**2.2 gw**) | 2–3 game-weeks ✅ |
| worst building < `AUTO_DAMAGE_THRESHOLD` 0.35 | ~game-day 28 | game-day 21 (**3.0 gw**) | — |
| worst building at 0.00, mass damage | — | game-day 27 (**3.9 gw**), 297 damaged at day 50 | ≈5 gw within 2× ✅ |

Both ruled arcs are met **at the authored rates**. `data/buildings.json`'s 60
`decay_per_hour` rows are therefore **HELD**, and the ruling's "scale, keep the
relative ladder" is answered with a scale factor of **1.0** and the three
measurements above. Any slow-down large enough to fix the trip count (×0.58 to
reach five trips a game-day at threshold 0.90) would push the danger marker from
2.8 to 4.8 game-weeks and break the arc the same ruling protects.

**Step 3 — solve the trip count with the threshold.** `REPAIR_THRESHOLD`
0.90 → **0.80**, measured over three seeds at 21 game-days:

| threshold | repair trips / game-day | repair spend / net | worst building at day 21 | value created |
|---|---|---|---|---|
| 0.90 (pass 2) | **11.5** | 11.8 % | 0.90 | $847,620 |
| 0.70 | 0.95 / 1.14 / 1.48 | 8.3 / 8.9 / 8.7 % | 0.70 | $1.00–1.03 M |
| **0.80 (fitted)** | **4.4 / 5.1 / 5.1** | **12.1 / 11.4 / 11.3 %** | **0.79 / 0.80 / 0.78** | **$1.02 / 1.01 / 1.02 M** |

0.80 is the only rung that lands both ruled targets at once. 0.70 saves actions
by parking the city at the last rung before doc 03 §2.2's `f_condition` starts
docking revenue, and the money falls out of the band with it; 0.90 is the chore.
`tests/test_balance_gates.gd` gate 4b holds both halves.

### 13.3 `tax.COND_FLOOR` 0.55 → **0.40** — the payback period of a repair

This is the only `data/` constant the fit moved, and the quantity it sets is the
one doc 92 F-2 has been asking about since pass 1: **how long a repair takes to
pay for itself.**

```
repair price     = capital × Δc × REPAIR_COST_PER_CAPITAL (0.85)
revenue recovered = base_tax × (1 − COND_FLOOR) × Δc  per game-hour
payback (gh)     = capital × 0.85 / (base_tax × (1 − COND_FLOOR))
```

`Δc` cancels: the payback is a property of the archetype and the floor alone.
For a `house` L1 (capital $1,200, `base_tax` $12/gh) that is **453 game-hours =
18.9 game-days at `COND_FLOOR` 0.55**, and **340 game-hours = 14.2 game-days at
0.40**. Nineteen game-days is *outside the pacing horizon doc 03 §2.12 models*,
which is the mechanical reason pass 2's A/B could not see maintenance pay and
why `disaster_neglect` beat `balanced` on every axis.

Measured on the A/B, seed 1337, 21 game-days, everything else identical:

| `COND_FLOOR` | `balanced` treasury | `disaster_neglect` treasury | gap |
|---|---|---|---|
| 0.55 | $37,808 | $65,668 | **−$27,860 — neglect wins** |
| **0.40** | **$65,845** | $59,971 | **+$5,874 — maintenance wins** |

**What it does not move.** `f_condition(1.0) = COND_FLOOR + (1 − COND_FLOOR)·1
= 1.0` at every floor, so the founding ledger, the tax ladder, every §7 detent
row and gates 1/2/2b are untouched (measured drift on the first settled hour:
−0.0063 % of gross). What it does move is doc 03 §2.2's worked examples A and B —
`f_condition` 0.9775 → 0.9700, revenue $23.86 → $23.68/gh and $8.23 → $8.17/gh.
`tests/test_economy.gd` carries the new literals with the derivation; **doc 03
§2.2's own printed example is an open edit for that doc's owner** (§16).

### 13.4 `expenses.MAINT_CONDITION_PENALTY` 1.5 — **HELD**, with the measurement

The obvious companion lever, and the data says no. `building_maint` is the single
largest expense line in a grown city — measured **$466.89/gh of $1,289.80 total
(36 %)** on a 320-building `disaster_neglect` city at day 21 — so raising the
penalty from 1.5 to 2.5 is a real edit. Isolated on the same A/B it contributes
**+$703 of the $5,874 maintenance-pays gap (12 %)** while charging *both* agents
8–16 % more on their biggest line. `COND_FLOOR` alone already flips the gate.
Held, and recorded so it is not re-litigated.

### 13.5 Pass-2 F-10 closed — the harness stopped being the bottleneck

`Api.upgrade_candidates()` previewed `cmd_upgrade_building` for **every**
standing building on every call, and the agents call it up to six times a
game-hour. Pass 2 shipped 17 of 18 runs because of it; the rebalance made it
fatal, because the rebalanced `balanced` builds a 358-building city and a
21-game-day run went from **12 s to over 13 minutes on the preview scan alone**.

Fixed as pass-2 F-10 itself recommended — **rank on the cheap fields, price only
the head**. Upgrade price is `econ_curves.upgrade_cost(type, level)`, a pure
function of (archetype, level) with no gate in it, so the cost ordering is known
before any preview runs; only the ordered head is previewed, and only until
`UPGRADE_LIMIT` (8) rows have cleared the doc 02 §2.11 gate, with a hard scan cap
of `UPGRADE_SCAN` (64). Both consumers rank on a cheap key and take the head, so
the bound is invisible to them. **18 of 18 matrix runs now finish, the slowest in
22.5 s**, and the whole 20-gate suite runs in 59 s.

---

## 14. Pass 3 — the founding grid (F-4) and the founding footprint (F-8)

### 14.1 F-4 implemented — 23 → 18 transformers — and its geometric floor

**What landed.** `data/starter_city.json` `power.nodes` drops **T-05, T-08,
T-16, T-21 and T-22** — the five transformers that are redundant against doc 09
§2.9.5's own siting rule. Their 204 streetlights, 24 signals and two building
customers (a house on T-08, `POL-1` on T-21) re-home to the nearest surviving
node (doc 04 §2.3 attaches a sink with no radius limit), which pushes T-19 and
T-20 across the §2.9.5 headroom rule from L1 to L2. Everything conserved,
everything measured:

| quantity | before | after |
|---|---|---|
| transformers | 23 | **18** |
| level histogram | 13 / 9 / 1 | **7 / 10 / 1** |
| `rated_mva` | 2.40 | **2.25** (`7×0.05 + 10×0.15 + 1×0.40`) |
| night peak | 783.3 kW | **783.4 kW** — conserved |
| streetlight / signal sinks | 783 / 81 | **783 / 81** — conserved |
| `F_SOUTH` share of night load | 53.8 % | **53.3 %** — the designed lesson survives |
| `E_grid` | $74.874/gh | **$74.274/gh** (`−0.15 MVA × $4.00`) |
| **served vacant ground** | **510 tiles** | **452 tiles** |
| served 2×2 origins | 257 | **226** |
| `tutorial_lot_a` (11,8) | unserved, one tap away | **unchanged** |
| `tutorial_lot_b` (13,8) | served (by T-09) | **unchanged** |
| `T-04` | L2, tutorial_transformer, 4 customers | **unchanged** |

**What did not land, and why — this is the finding.** Doc 92 pass-2 F-4 asked
for the first `E_UNSERVED` wall "before game-hour 48". It is at **game-hour
385**, and thinning further cannot get it to 48. Two measurements say so.

*First, the wall is money-limited, not ground-limited.* `greedy_growth` is the
fastest builder in the study — three actions per game-hour, zero reserve, buys
no infrastructure ever — and it converts income into floorspace at ~0.35
buildings per game-hour early on, because a founding city nets ~$340/gh against
$1,200 a house and $7,000 an apartment.

| roster | served vacant tiles | buildings placed before the wall | first `E_UNSERVED` |
|---|---|---|---|
| 23 nodes (pass 2) | 510 | 137 | game-hour 362 |
| **18 nodes (now)** | **452** | **126** | **game-hour 385** |

The wall moved *later* even though the ground shrank 11 %, because the same
Wave-4 pass also made the city poorer per hour (wear is billed, `COND_FLOOR` is
0.40) and the builder slowed by more than the ground did. `wall_hour ≈
served_tiles / fill_rate`; hour 48 at the measured fill rate needs **≈35–80
served tiles**, which is doc 92 pass 2's own "60–100" estimate.

*Second, 452 tiles is a geometric floor.* Doc 09 §2.9.5 requires every one of the
34 authored building origins to sit within Chebyshev 3 of a transformer — the
rule `tests/test_starter_city.gd::test_every_building_within_transformer_radius`
enforces — and those 34 buildings are spread across all nine core blocks. A
minimum set cover of them is **16 nodes**; 17 with `tutorial_lot_b`'s server
(T-09, the only node that reaches (13,8)); 18 once the removed nodes' inherited
sinks push two survivors up a level. Eighteen radius-3/4/5 patches already union
to **452 of the core's 1,429 vacant lots**, and every candidate roster below that
darkens an authored building at boot:

| roster | valid? | served vacant tiles |
|---|---|---|
| 23 (authored) | yes | 510 |
| **18 (shipped)** | **yes** | **452** |
| 17 (min cover + T-09, fixed levels) | yes | 427 |
| ≤16 | **no** — orphans a building | — |

Re-siting the survivors (an optimiser over the 783 road tiles, minimising served
vacant ground subject to every doc 09 constraint) reaches **356 tiles** — still
4–7× too much, at the cost of relocating ten of the eighteen nodes off doc 09's
authored table. Not taken: the ruling says respect the authored layout logic, and
96 tiles does not buy the pacing beat.

**The open ruling (doc 09's owner).** Hour 48 is a **core-size** question, not a
grid question. The two levers that reach it are (a) fewer READY blocks at t0 —
which §14.2 shows cannot be done as doc 92 F-8 describes it — or (b) a denser
authored building manifest, so the founding 34 buildings occupy more of the
ground their transformers light. Both are `data/starter_city.json` shape edits
that belong with doc 09 §2.9.3/§2.9.4, not with a balance pass.
`tests/test_balance_gates.gd` gate 10 now holds the measured hour ±1 game-day
with this derivation inline.

**What F-4 did buy.** The 50-game-day runs say the thinner grid is doing real
work later: `balanced` holds condition 0.80 and single-digit open incidents
through game-day 23, then falls off a cliff as its 762 buildings outrun 18
transformers — **66.8 % of building-time dark at day 50**, ten transformer taps
bought and not enough. `cmd_place_grid_component` stops being optional at
game-day ~24 instead of never. That is a pacing beat one game-week later than
the ruling wanted and three game-weeks earlier than pass 2 had it.

### 14.2 F-8 — the READY-core trim is DECLINED, with data

The ruling was conditional: *trim the nine READY blocks if and only if the matrix
shows land purchase becoming a real decision, and gate 11 must stay green.* Both
halves say no.

**It is already a real decision.** With the land fund (§13.1) `balanced` buys
**2 blocks in every 21-game-day run on every seed**, spending 10–13 % of its net
on land, and `tax_squeezer` and `disaster_neglect` do the same. Gate 11 is green
without the trim.

**And the trim as doc 92 F-8 describes it is not available.** "Reduce the READY
core to four or five blocks" strands authored civic infrastructure: the nine core
blocks are not a homogeneous field of housing, they hold the whole starter city,
and doc 09 §2.3 makes building placement require `development_state == READY`.

| block | authored buildings that would be stranded |
|---|---|
| `B_2_3` | `WTR-1` and `WTR-2` — the water works and the tank |
| `B_2_4` | `POL-1` |
| `B_4_2` | `FIRE-1` |
| `B_4_3` | `SUB-A` — the only substation |
| `B_4_4` | `PLANT-1` — the only generation |

Any four- or five-block core leaves at least one of the police station, the fire
station, the substation, the water works or the power plant grandfathered onto
ground the player may not build beside — and `land.STARTER_BLOCKS_FREE` 9,
doc 09's district roster, the t0 stability arithmetic (0.9475) and the 1,429
vacant-lot count all move with it. **Declined.** The founding-footprint question
is re-filed as the same doc-09 open ruling as §14.1: it is one question ("how big
and how full is the starter core?"), not two.

---

## 15. Pass 3 — the matrix

**18 of 18 runs**, 6 strategies × 3 seeds × 21 game-days, online coarse step.
Wall clock 4.0–22.5 s per run; the whole matrix is ~4.5 minutes. `credit` is
`credit_line_engaged`, `dir ev` is `director_event_started`.

| strategy | seed | treasury | value | net $/gh | pop | happy | stab | lvl | dark % | placed | upg | minC | open inc | abandoned |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| do_nothing | 1337 | $159,077 | $159,077 | 262 | 144 | 82.2 | 0.9475 | 0 | 0.59 | 0 | 0 | 0.511 | 0.01 | 0 |
| do_nothing | 4242 | $161,260 | $161,260 | 268 | 144 | 82.2 | 0.9475 | 0 | 0.01 | 0 | 0 | 0.457 | 0.00 | 0 |
| do_nothing | 9001 | $161,147 | $161,147 | 258 | 142 | 83.1 | 0.9486 | 0 | 0.08 | 0 | 0 | 0.505 | 0.01 | 0 |
| greedy_growth | 1337 | $100,635 | $972,630 | 1,313 | 1,845 | 53.4 | 0.7112 | 2 | 34.76 | 126 | 39 | 0.382 | 1.65 | 0 |
| greedy_growth | 4242 | $115,145 | $1,003,783 | 1,448 | 1,690 | 52.9 | 0.7072 | 2 | 37.63 | 127 | 46 | 0.395 | 1.57 | 0 |
| greedy_growth | 9001 | $178,867 | $1,031,084 | 1,477 | 1,906 | 53.6 | 0.7300 | 2 | 35.97 | 126 | 35 | 0.362 | 1.53 | 0 |
| infrastructure_first | 1337 | $11,504 | $127,904 | 364 | 232 | 77.6 | 0.9752 | 0 | 0.65 | 27 | 0 | 0.888 | 0.01 | 0 |
| infrastructure_first | 4242 | $19,166 | $135,566 | 384 | 232 | 77.1 | 0.9690 | 0 | 0.02 | 27 | 0 | 0.891 | 0.00 | 0 |
| infrastructure_first | 9001 | $20,046 | $136,446 | 380 | 230 | 77.1 | 0.9690 | 0 | 0.01 | 27 | 0 | 0.891 | 0.01 | 0 |
| balanced | 1337 | $65,845 | $1,021,565 | 1,794 | 1,366 | 56.7 | 0.7754 | 2 | 25.72 | 291 | 118 | 0.792 | 1.03 | 0 |
| balanced | 4242 | $68,151 | $1,005,901 | 1,880 | 1,447 | 60.9 | 0.8271 | 2 | 20.01 | 274 | 129 | 0.796 | 0.78 | 0 |
| balanced | 9001 | $80,941 | $1,021,801 | 1,882 | 1,500 | 59.3 | 0.7756 | 2 | 21.55 | 277 | 130 | 0.789 | 0.82 | 0 |
| tax_squeezer | 1337 | $89,139 | $1,501,133 | 2,681 | 1,319 | 47.1 | 0.6886 | 2 | 46.47 | 315 | 146 | 0.742 | 1.79 | 0 |
| tax_squeezer | 4242 | $56,252 | $1,643,238 | 2,974 | 1,877 | 52.4 | 0.7404 | 2 | 48.78 | 341 | 117 | 0.664 | 1.70 | 0 |
| tax_squeezer | 9001 | $57,445 | $1,636,415 | 2,975 | 1,691 | 53.7 | 0.7461 | 2 | 49.78 | 317 | 123 | 0.711 | 1.85 | 0 |
| disaster_neglect | 1337 | $59,971 | $1,120,551 | 1,701 | 1,451 | 57.8 | 0.7882 | 2 | 25.67 | 290 | 137 | 0.353 | 1.13 | 0 |
| disaster_neglect | 4242 | $75,064 | $1,108,024 | 1,828 | 1,480 | 56.6 | 0.8071 | 2 | 21.37 | 278 | 148 | 0.401 | 0.94 | 0 |
| disaster_neglect | 9001 | $75,001 | $1,122,938 | 1,855 | 1,348 | 57.1 | 0.7707 | 2 | 23.55 | 279 | 152 | 0.340 | 0.96 | 0 |

| strategy (mean of 3 seeds) | treasury | value | net $/gh | pop | happy | stab | dark % | placed | upg | minC | open inc | inc created | repairs |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **do_nothing** | $160,494 | $160,494 | 263 | 143 | 82.5 | 0.9479 | 0.23 | 0 | 0 | 0.491 | 0.01 | 4.7 | 0 |
| **greedy_growth** | $131,549 | $1,002,499 | 1,412 | 1,813 | 53.3 | 0.7161 | 36.12 | 126 | 40 | 0.380 | 1.59 | 464.7 | 0 |
| **infrastructure_first** | $16,905 | $133,305 | 376 | 231 | 77.3 | 0.9711 | 0.23 | 27 | 0 | 0.890 | 0.01 | 5.3 | 110.0 |
| **balanced** | $71,645 | $1,016,422 | 1,852 | 1,437 | 58.9 | 0.7927 | 22.43 | 280 | 125 | 0.792 | 0.88 | 322.3 | 91.3 |
| **tax_squeezer** | $67,612 | $1,593,595 | 2,877 | 1,629 | 51.1 | 0.7251 | 48.34 | 324 | 128 | 0.706 | 1.78 | 703.7 | 205.3 |
| **disaster_neglect** | $70,012 | $1,117,171 | 1,795 | 1,426 | 57.2 | 0.7886 | 23.53 | 282 | 145 | 0.365 | 1.01 | 372.0 | 0 |

`incident_abandoned` is **0** in all eighteen runs, `credit_line_engaged` is 0 in
all eighteen (nobody went negative), and `director_event_started` is 2 on
seventeen of them — pass-2 F-3's cascade and F-1's silent Director are both
closed and stay closed at every city size the matrix reaches.

### 15.1 The headline ordering, checked

**1. `balanced` beats `do_nothing`. ✅ — but not on idle cash, and it never can.**

| column | `balanced` | `do_nothing` | ratio |
|---|---|---|---|
| value created (cash + city) | **$1,016,422** | $160,494 | **6.3×** |
| population | **1,437** | 143 | 10.0× |
| net $/gh (run mean) | **1,852** | 263 | 7.0× |
| min condition | **0.792** | 0.491 | the control is rotting |
| treasury (idle cash) | $71,645 | $160,494 | 0.45× |

The cash row is the one to read carefully, because pass 2's version of this gate
passed on it and the rebalanced agent fails it. A spend-everything agent's cash
sits at its reserve *by construction* — doc 92 §3 warned about exactly this
before the rebalance made it bite — so ranking a builder below a savings account
because the builder spent its money on buildings is a measurement error. Gate 5
is retuned onto the four columns above, and it gains a new assertion that answers
the other half of F-1: **standing still now costs something.** The control's
worst building falls 1.000 → 0.491 in three game-weeks on wear alone (4.7
incidents per run — it is not being attacked), and its three-week take fell from
$169,592 to $159,077 when `COND_FLOOR` was ruled: **decay alone bills an
untouched city 6.2 % of its earnings**, where pass 2 measured a perfectly
straight, perfectly free line.

**2. Neglect is fatal. ✅ — and the arc is now legible.** `disaster_neglect` is
`balanced` with one field changed, and the two build the same city (282 vs 280
placed, 1,426 vs 1,437 people, 23.5 % vs 22.4 % dark). Every difference is the
knob:

| | `balanced` | `disaster_neglect` |
|---|---|---|
| treasury, day 21 (mean) | **$71,645** | $70,012 |
| min condition, day 21 (mean) | **0.792** | 0.365 |
| worst building reaches 0.00 | day 35 | **day 27** |
| damaged buildings, day 50 | 471 of 762 | 297 of 386 |

Maintenance buys the city **twelve extra game-days of health** at 11–12 % of
net. Note the day-50 rows carefully: **both** cities are wrecked by then, and
the second one is not a maintenance failure — see §15.2.

**3. `tax_squeezer`'s dominance persists, as expected. ✅ (noted, not fought.)**
Doc 92 pass-2 F-5 measured the top detent at **+46 %** value created; it is now
**+57 %** ($1,593,595 vs $1,016,422) for **−7.8** happiness and, on the mean,
**+13 %** population. The coupling agent that would make the detent cost a city
has not landed, and `tax.TAX_RATE_GROWTH_COEFF` 8.0 cannot do it alone —
`tests/test_balance_gates.gd` gate 12 records why in full (the multiplier scales
the *relaxation* of `attractiveness` toward a target that is already 1.0 in a
healthy city, so in a healthy city it multiplies zero). One thing did change and
it is worth the ruling's attention: **the treasury half of the dominance is
gone.** `tax_squeezer` now ends 21 game-days with **$67,612** against
`balanced`'s $71,645, because the same land fund and maintenance purse that make
`balanced` a credible player make the squeezer spend its windfall too. The
dominance is entirely in what it built, which is the honest shape of the finding.

### 15.2 The 50-game-day pair — and a new pass-3 finding

One paired 50-game-day run, seed 1337, the neglect A/B extended past the
fatality arc:

| | `balanced` | `disaster_neglect` |
|---|---|---|
| treasury, day 50 | $273,460 | $905,381 |
| value created | $2,114,700 | $2,215,652 |
| buildings | 762 | 386 |
| population | 2,229 | 1,238 |
| repairs | 200 (4.0 / game-day) | 0 |
| repair spend / net | **17.3 %** | 0 % |
| min condition, by day | 0.80 through **day 23**, 0.00 from day 35 | 0.35 by day 21, 0.00 from **day 27** |
| dark share | **66.8 %** | 44.8 % |

The maintenance line holds exactly as fitted — 4.0 trips per game-day and 17.3 %
of net over fifty game-days, both inside the ruled bands, on a city that grew to
762 buildings. And then it stops working, **for a reason that is not
maintenance**: `balanced` builds 762 buildings onto a founding grid of eighteen
transformers plus the ten taps it buys, ends the run with **two thirds of all
building-time dark**, and an unpowered building decays 1.5× faster (doc 02 §2.6)
and earns a fraction of its tax line. The condition cliff at game-day 23–24 is a
POWER cliff.

**Filed as pass-3 F-11.** After F-4's thinning the binding constraint on a
well-played city moves from land to grid capacity at around game-day 24, and the
agent's reactive `_unwall` rule — buy one transformer when the served ground has
actually run out, on an 8-hour cooldown — cannot keep up with a builder placing
~15 buildings a game-day. This is the good version of the problem doc 93 §A
wanted (*"`cmd_place_grid_component` is THE game"*), and it wants a pass-4
answer on both sides: a `balanced` that buys grid *ahead* of growth the way
`infrastructure_first` does, and a ruling on whether 66.8 % dark should be
survivable at all. **No constant was moved for it in this pass** — it is outside
the 21-game-day pacing horizon the rulings are written against, and moving a grid
or decay constant to paper over it would break §13.2's fit.

---

## 16. Open edits this pass could not make

> **ALL FOUR ARE CLOSED (Wave 5 — see §17.1).** The three doc edits are applied
> in their source docs, and the fourth — the hour-48 ruling — is answered in doc
> 93 §E2 by retiring the goal. This table is kept as the record of what was held
> and where it went; it is no longer a to-do list.


| where | what | why it is here |
|---|---|---|
| doc 03 §2.2, lines quoting `COND_FLOOR = 0.55` and worked examples A/B | `COND_FLOOR` is **0.40**; `f_condition = 0.40 + 0.60 × C`; example A `f_condition` 0.9775 → 0.9700 and revenue $23.86 → **$23.68**/gh; example B $8.23 → **$8.17**/gh | §13.3 ruled the constant; doc 03 is not this pass's file. `tests/test_economy.gd` already carries the new literals with the arithmetic in a comment, so the doc is the only stale copy. |
| doc 03 §2.12's founding ledger | `E_grid` $74.874 → **$74.274**/gh, total expense $520.577 → **$519.977**/gh, net $318.773 → **$319.372**/gh, day net $7,650.55 → **$7,664.94** | §14.1: F-4 took 0.15 MVA of transformer plate out of the inventory. `data/economy.json` `pacing_guardrails` and `tests/test_economy.gd` are re-stamped; doc 93 §E2 carries the shift table. |
| doc 09 §2.9.5's transformer table | 23 rows → **18**; T-05, T-08, T-16, T-21, T-22 deleted; T-03/T-04/T-07/T-12/T-13/T-14/T-15/T-17/T-19/T-20/T-23 re-load; fleet `13×L1 + 9×L2 + 1×L3` → **`7×L1 + 10×L2 + 1×L3`**, `rated_mva` 2.40 → **2.25**; feeder rollups 361.8/421.6 → **365.8/417.6**; `F_SOUTH` 53.8 % → **53.3 %** | §14.1. `data/starter_city.json`, `data/world.json` and `tests/test_starter_city.gd` are updated and carry the derivations; doc 09's printed table is the stale copy. |
| doc 09 §2.9.3/§2.9.4 (a **ruling**, not an edit) | how big and how full is the starter core? Hour-48 pacing for `cmd_place_grid_component` needs ≈35–80 served vacant tiles and the geometric floor under doc 09's own siting rule is 452 | §14.1 and §14.2. Neither a grid edit nor a READY-block trim can reach it; it is a core-size question. |

---

## 17. Pass 4 — the infrastructure verbs and F-11

*Wave 5, 2026-08-19. Same rig, same strategies, same summariser: every number
below is read off the live sim through `tests/balance_matrix.gd`, which drives
`BalanceGateRig` and therefore `tools/playtest.gd`'s own agents.*

### 17.1 The three open edits from §16 are applied

Doc 03 §2.2's `COND_FLOOR` lines and worked examples A/B, doc 03 §2.12's founding
ledger (and the `E_grid` derivation it comes from), and doc 09 §2.9.5's
transformer table are all edited in their SOURCE docs. §16's table is now
historical; the docs are the truth again. Doc 09's table is republished with
loads **metered off the running sim** rather than hand-derived, and carries a
basis note: this doc's own arithmetic gives 783.4 kW (`F_NORTH 365.8 / F_SOUTH
417.6`), the sim meters 801.7 kW (`376.0 / 425.7`), and the ~18.4 kW gap is doc
05's live node roster over its published L1 constants — doc 93 §E2 owns that
shift and always has.

The fourth §16 row was a **ruling**, not an edit, and it is answered in doc 93
§E2: **the hour-48 `E_UNSERVED` goal is retired.** The wall is money-paced by
design and that is correct — teaching the transformer by starving the player of
LAND would be teaching it with a fake shortage. Gate 10 re-anchors onto the
first infrastructure DECISION (a tap bought ahead of growth, inside the first
game-week) and stops asserting an hour.

### 17.2 F-11 — the strategy half, done, and what it bought

F-11 filed two halves. The first is a strategy change and it is made:
`tools/playtest.gd`'s `Balanced` now buys grid **ahead** of growth.

Two rules moved, and the second is the one pass 3 did not see:

1. **The trigger.** Pass 3 asked *"is there a served 1×1 tile anywhere in the
   city"* — which a founding core of 452 served tiles answers `yes` long after
   the block being built on has run dry, and long after a freshly developed block
   (which doc 09 §2.3 hands over with a utility corridor and **no transformer**)
   has gone entirely dark. It is now **`GRID_LEAD_TILES = 40` served, buildable,
   empty tiles per owned+READY block**, checked per block, on a 2-game-hour
   cooldown instead of 8.
2. **The rung.** Pass 3 bought L1 transformers. Doc 04 §8 rates an L1 at **50 kW**
   and gives it a Chebyshev-3 service area — a **49-tile** patch — so the tap
   saturates at roughly a third of the ground it is allowed to serve and the
   surplus is shed. Measured at day 30 of the lead-only run: 37 transformers, 11
   over 100 %, worst **94 kW on a 50 kW rating (1.89×)**. L2 is 150 kW for
   $1,100 against L1's 50 kW for $500 — **3× the capacity for 2.2× the price** —
   and it is the rung whose rating matches its radius. `GRID_LEVEL = 2`.

Seed 1337, 21 game-days, the pacing horizon the rulings are written against:

| column | pass 3 | Wave 5 | |
|---|---|---|---|
| **dark share** | 25.72 % | **8.70 %** | ruled target ≤ 15 % ✅ |
| transformers bought | 1 | **11** | |
| happiness | 56.7 | **73.5** | |
| city stability | 0.7754 | **0.9310** | |
| treasury | $65,845 | **$91,291** | |
| min condition | 0.792 | 0.796 | unchanged, as intended |

Across three seeds the dark share is **8.70 / 9.05 / 11.01 %**. `disaster_neglect`
is still this agent with exactly one field changed, and it now differs on the
lights as well: **26.09 % against 8.70 %**. Gate 18 asserts the target; gate 4
keeps the columns it was fitted on, so neither gate measures two things at once.

### 17.3 F-11's other half — the ruling, and the constants it names

**The ruling asked for ≤ 15 % dark at FIFTY game-days. It is not reachable by
strategy, and this is the report the ruling asked for instead.** Measured with
the improved agent, seed 1337, doc 04's ladder dumped every 10 game-days:

| day | buildings | demand kW | **feeder** | transformer | substation | plant |
|---|---|---|---|---|---|---|
| 10 | 180 | 922 | 51.8 % | 37.7 % | 20.7 % | idle |
| 20 | 256 | 1,599 | 80.1 % | 44.2 % | 32.0 % | idle |
| 30 | 428 | 2,183 | **104.4 %** | 47.7 % | 41.8 % | idle |
| 40 | 626 | 2,539 | **119.2 %** | 45.4 % | 47.7 % | idle |
| 50 | 772 | 2,360 | **111.8 %** | 38.9 % | 44.7 % | idle |

Read the columns in that order. **The transformer fleet is fine** — the strategy
fix did its job and the fleet sits under half loaded. The substation is at 45 %
of its 6 MVA and the plant is barely touched at 8 MW. **Everything the city has
runs through the two class-1 feeders doc 09 §2.9.5 authored, rated 1,200 kW
each**; doc 04 §2.6 derates even that with condition and ambient temperature, and
the city crosses 100 % at roughly **410 buildings**. Dark share by game-day
tracks it exactly: 5.1 % at day 10, 4.2 % at 15, 33.7 % at 20, 66.7 % at 25, and
the 50-game-day run ends at **54.9 %**.

**And no verb answers it.** `data/grid_components.json`'s `placeable` roster ships
exactly one kind. So the late-game ceiling is not a balance constant at all — it
is a command-layer gap, and the fixes are named in this order:

1. **Ship a feeder verb.** Doc 04 §4's `route_feeder` / `place_power_component`
   for `feeder`, and add `feeder` and `substation` to the placeable roster. Doc
   03 §2.13(b) **already prices both** — feeder class 2 at $210/tile, substation
   L1 at $15,000 — so nothing needs a new price. Class 2 raises a feeder
   1,200 → 3,000 kW and moves the ceiling from ~410 buildings to ~1,000.
2. **Make the `substation` / `power_facility` SHELLS real.** `cmd_place_building`
   sells either one today and neither adds a `PowerGrid` component: a $15,000
   building that supplies nothing, and a $60,000 one that generates nothing.
   Either wire the shell to a component — exactly as Wave 5 wired
   `water_facility` to its doc-05 node — or take the cards off the build sheet.
   This is the same class of finding as pass-2 F-3's frozen fleet: a purchase
   that buys the player nothing.
3. **Only then look at a constant.** `PowerGrid.CAPACITY.transformer` L1 = 50 kW
   against a 49-tile service area is the one genuine mismatch in doc 04's ladder
   — every other rung's capacity tracks its radius — and ~90 kW would make L1 a
   sensible first buy rather than a rung to skip. **It is not the late-game
   ceiling**, and moving it would not raise the feeder's.

**No constant was moved for any of this.** Gate 18b pins the ceiling with the
feeder inventory and the one-kind roster, so the day a feeder verb lands the gate
fails and gate 18 gets its 50-game-day threshold.

### 17.4 What else moved, and why

- **A developed ring block now arrives with roads.** Doc 09 §2.9.1's 87-tile
  template had never been stamped, so a bought block reached READY with **256
  placeable tiles and no road access at all** — on a map whose revenue formula
  multiplies by `f_road`. It is now doc 09's published **169 buildable tiles**
  plus 60 AVENUE and 27 STREET. Two things follow and both are corrections: the
  city's road-repair line grows with the network exactly as §2.12's per-block
  term intends, and a ring block's buildings finally earn a road multiplier they
  were previously neither charged for nor paid on.
- **`min_city_level` is enforced at placement**, and the curves did not move —
  because every scripted strategy already filtered on `Api.buildable`, which has
  always applied the same rule. The harness was playing by the UI's rules while
  the sim was not.
- **Gate 4b's band needs its denominator restated.** Maintenance spend fell from
  ~12 % of net to **6.5 / 6.8 / 6.6 %** across three seeds, and neither the decay
  rows nor `REPAIR_COST_PER_CAPITAL` moved. Both halves of the ratio changed for
  the same reason: a lit city earns more (net $1,794 → $2,003/gh) and wears more
  slowly (doc 02 §2.6 decays an unpowered building **1.5×** faster, and a quarter
  of this city used to be unpowered). The ruled purposes both still hold —
  **2.0 trips per game-day** and the worst building held at **0.80** — so the
  band is re-anchored on the measurement and **flagged**: if 10–20 % is wanted
  back on a lit city, the levers are `data/buildings.json`'s `decay_per_hour` or
  `expenses.REPAIR_COST_PER_CAPITAL`, and this pass moved neither.

### 17.5 The matrix — 18 of 18, 21 game-days

Same rig as §15, re-run after every Wave-5 change.

| strategy | seed | treasury | value | net $/gh | pop | happy | stab | dark % | placed | upg | minC | open inc |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| do_nothing | 1337 | $159,077 | $159,077 | 262 | 144 | 82.2 | 0.9475 | 0.59 | 0 | 0 | 0.511 | 0.01 |
| do_nothing | 4242 | $161,260 | $161,260 | 268 | 144 | 82.2 | 0.9475 | 0.01 | 0 | 0 | 0.457 | 0.00 |
| do_nothing | 9001 | $161,147 | $161,147 | 258 | 142 | 83.1 | 0.9486 | 0.08 | 0 | 0 | 0.505 | 0.01 |
| greedy_growth | 1337 | $100,635 | $972,630 | 1,313 | 1,845 | 53.4 | 0.7112 | 34.76 | 126 | 39 | 0.382 | 1.65 |
| greedy_growth | 4242 | $115,145 | $1,003,783 | 1,448 | 1,690 | 52.9 | 0.7072 | 37.63 | 127 | 46 | 0.395 | 1.57 |
| greedy_growth | 9001 | $178,867 | $1,031,084 | 1,477 | 1,906 | 53.6 | 0.7300 | 35.97 | 126 | 35 | 0.362 | 1.53 |
| infrastructure_first | 1337 | $11,504 | $127,904 | 364 | 232 | 77.6 | 0.9752 | 0.65 | 27 | 0 | 0.888 | 0.01 |
| infrastructure_first | 4242 | $19,166 | $135,566 | 384 | 232 | 77.1 | 0.9690 | 0.02 | 27 | 0 | 0.891 | 0.00 |
| infrastructure_first | 9001 | $20,046 | $136,446 | 380 | 230 | 77.1 | 0.9690 | 0.01 | 27 | 0 | 0.891 | 0.01 |
| **balanced** | 1337 | $91,291 | $965,771 | 2,003 | 1,463 | 73.5 | 0.9310 | **8.70** | 236 | 142 | 0.796 | 0.32 |
| **balanced** | 4242 | $86,727 | $976,027 | 2,070 | 1,514 | 72.6 | 0.9097 | **9.05** | 245 | 145 | 0.797 | 0.28 |
| **balanced** | 9001 | $85,754 | $986,634 | 2,029 | 1,602 | 69.4 | 0.8771 | **11.01** | 242 | 142 | 0.797 | 0.35 |
| tax_squeezer | 1337 | $86,708 | $1,616,068 | 3,331 | 1,946 | 53.9 | 0.8229 | 25.92 | 312 | 126 | 0.778 | 0.85 |
| tax_squeezer | 4242 | $87,344 | $1,626,193 | 3,342 | 1,901 | 47.9 | 0.7735 | 27.19 | 287 | 156 | 0.776 | 0.98 |
| tax_squeezer | 9001 | $100,981 | $1,702,861 | 3,541 | 1,974 | 56.8 | 0.7674 | 27.66 | 296 | 147 | 0.775 | 0.82 |
| disaster_neglect | 1337 | $75,219 | $1,125,179 | 1,714 | 1,410 | 55.9 | 0.7542 | 26.09 | 295 | 134 | 0.338 | 1.20 |
| disaster_neglect | 4242 | $65,896 | $1,089,527 | 1,773 | 1,626 | 62.5 | 0.8594 | 24.71 | 279 | 146 | 0.399 | 0.92 |
| disaster_neglect | 9001 | $66,217 | $1,082,077 | 1,768 | 1,407 | 55.0 | 0.7310 | 25.70 | 286 | 144 | 0.382 | 0.95 |

| strategy (mean of 3) | treasury | value | net $/gh | pop | happy | stab | dark % | placed | upg | minC | repairs |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **do_nothing** | $160,494 | $160,494 | 263 | 143 | 82.5 | 0.9479 | 0.23 | 0 | 0 | 0.491 | 0 |
| **greedy_growth** | $131,549 | $1,002,499 | 1,412 | 1,813 | 53.3 | 0.7161 | 36.12 | 126 | 40 | 0.380 | 0 |
| **infrastructure_first** | $16,905 | $133,305 | 376 | 231 | 77.3 | 0.9711 | 0.23 | 27 | 0 | 0.890 | 110.0 |
| **balanced** | $87,924 | $976,144 | 2,034 | 1,526 | 71.8 | 0.9060 | **9.59** | 241 | 143 | 0.797 | 41.7 |
| **tax_squeezer** | $91,677 | $1,648,374 | 3,405 | 1,940 | 52.9 | 0.7880 | 26.92 | 298 | 143 | 0.776 | 113.0 |
| **disaster_neglect** | $69,110 | $1,098,927 | 1,752 | 1,481 | 57.8 | 0.7815 | 25.50 | 286 | 141 | 0.373 | 0 |

**Read the three unchanged rows first.** `do_nothing`, `greedy_growth` and
`infrastructure_first` reproduce §15's numbers **to the digit** on all nine runs.
That is the evidence for two Wave-5 claims that would otherwise be assertions:
`min_city_level` enforcement moved nothing (those agents already filtered on
`Api.buildable`, which has always applied the rule), and the block road stamp
moved nothing for agents that buy no land. Every difference below is the three
agents that descend from `Balanced`, and inside those, the two rules F-11 named.

**The headline ordering survives, and `balanced` improved on every column that
is not cash.** Against §15: value $1,016,422 → $976,144 (−4 %, the honest cost of
169 buildable tiles per ring block instead of 256), population 1,437 → 1,526,
happiness **58.9 → 71.8**, stability **0.7927 → 0.9060**, dark **22.43 % → 9.59 %**,
treasury $71,645 → $87,924. It builds a slightly smaller city and keeps all of it
running, which is the trade the ruling asked for.

**`tax_squeezer` is still dominant on value and still not free.** +69 %
value created against `balanced` (§15: +57 %), for **−18.9** happiness, **−0.118**
stability and **2.8× the dark share** — the detent now visibly buys its revenue
by outrunning the grid, which is a more legible price than §15's could show.
`incident_created` falls 703.7 → 315.3 for the same reason `balanced`'s does: a
lit city catches fire less.

**`incident_abandoned` is 0 and `credit_line_engaged` is 0 on all eighteen runs**,
and `director_event_started` is exactly 2 on every one — pass-2 F-3's cascade and
F-1's silent Director stay closed at every city size this matrix reaches.

### 17.6 The infrastructure verbs are shipped but not yet DRIVEN

`cmd_place_road` / `cmd_upgrade_road` / `cmd_demolish_road` and
`cmd_place_water_component` / `cmd_place_water_main` /
`cmd_upgrade_water_component` are live, tested and probed by the harness — and no
strategy reaches for one. That is deliberate for this pass and it is a gap the
next one should close: roads arrive stamped with doc 09's block template and
water arrives with doc 09's authored topology, so neither is on the critical path
of a 21-game-day run, and an agent that laid roads it did not need would measure
the harness rather than the game. **The measurements they exist to enable, in
priority order:** what does a player-laid street grid on a bought block cost
against the template's, at doc 03 §2.13(d)'s 17–52× piece-rate premium; and at
what city size does the authored water topology (one pump, 40 m³/h, 7.2× headroom
at founding) stop covering the demand — the water twin of §17.3's feeder ceiling,
and the one the new verbs CAN answer.

---

## 18. Pass 5 — incident pacing (audit 91 D-6)

*Wave 6, 2026-08-19. Same rig, same strategies, same summariser. New this pass:
`tools/playtest.gd` buckets `incident_created` **by type**, because the ruling is
about a MIX and a bare count cannot show one.*

Audit 91 **D-6**: *"2 incidents in 287 game-hours … the drawer, the picker, the
fleet and doc 06's whole escalation ladder are almost never seen."* The ruling
this pass answers: **the small-city floor should make the dispatch loop a weekly
beat — 2–4 ambient incidents per game-week at starter scale, scaling smoothly. A
`do_nothing` city must still survive it; a neglected one meets its fires
sooner.**

### 18.1 What the founding city actually generates, and why

Every doc 06 §2.6 generator is priced **per asset** — per 1,000 residents, per
transformer node, per kilometre of main, per intersection, per exposed span — and
report 98 R-11/R-13 calibrated each rate against a city that *has* those assets.
The founding city has 144 residents and 18 transformer nodes. Measured over
**336 game-days** (12 seeds × 28 game-days of `do_nothing`) with the floor
switched off, which is the honest counterfactual because `ambient_floor.enabled`
`false` restores the pre-Wave-6 generation exactly:

| channel | candidate source at t0 | incidents / game-day | / game-week |
|---|---|---|---|
| `transformer_failure` | 18 nodes | 0.134 | 0.94 |
| `structure_fire` | 34 buildings | 0.083 | 0.58 |
| `crime` | 4 districts, 144 residents | 0.051 | 0.35 |
| `water_main_break` | **0 segments** | **0.000** | **0.00** |
| `traffic_accident` | **0 intersections** | **0.000** | **0.00** |
| `storm_damage` | only inside a live doc 07 cell | 0 between storms | — |
| **total ambient** | | **0.268** | **1.88** |
| doc 07 §8 Director floor, for scale | | 0.071 | 0.50 |

1.88 per game-week is *below* the ruled band, and it is also the first thing this
pass found: D-6's headline "2 in 287 game-hours" is a 12-game-day sample of a
0.27/day process, whose expectation is 3.2 — so part of the audit's number is
Poisson noise on a rate that was low, but not as low as one sample read. The rate
being low is real. **The other half is not a rate at all**, and §18.2 is about
that.

**The lever, and why it is a floor.** Raising `generator_base_rates` is the wrong
answer twice over: report 98 calibrated all six per asset against real physics
(R-13 against doc 07's own published storm outcome targets), and a rate that
pressures 34 buildings buries 800. The right instrument already exists one
document over — doc 07 §8's Director floor, which doc 92 pass 2 introduced for
exactly this shape of problem — and it is a `max()`:

```
λ_used(channel) = max( λ_natural(channel), floor_per_hour(channel) × dt_h )
```

`data/incidents.json` `ambient_floor` authors it **per channel**, not in
aggregate, and three properties follow from the shape rather than from the
numbers:

1. **Continuous in city size.** A channel whose own inventory out-generates its
   floor never sees it, and the handover happens at one city size with no cliff
   and no branch. There is no "small city" mode to test, and no size at which the
   rate jumps.
2. **It cannot invent a target.** `λ_natural ≤ 0` means the channel scanned and
   found no eligible candidate; the floor stays out. It changes how OFTEN, never
   WHERE — the target is still drawn from the channel's own weighted candidate
   list, so a floored fire still picks the building doc 02 says is likeliest to
   burn and a floored crime still picks by `crime_weight`.
3. **Still dampened.** The floor sits inside `_poisson(… × damper)`, so
   `load_damper` (an overwhelmed fleet), doc 08's beyond-72-hour offline damper
   and a difficulty's `generation_mult` all still apply to it. A floor is a
   minimum on the *rate*, not a guarantee of an *incident*.

It also works on the **instantaneous** rate rather than the daily mean, which is
worth stating because it is why the three channels respond so differently in
§18.3: the floor fills a channel's troughs without touching its peaks.

### 18.2 Two of the six generators have no candidate source at all — D-14 / D-15

`water_main_break` and `traffic_accident` generate **exactly zero** in the
shipped city, at every city size, for a reason that is not a rate:

```
IncidentWorld.water_mains()        -> []      sim/incidents/incident_world.gd:243
IncidentWorld.road_intersections() -> []      sim/incidents/incident_world.gd:302
```

`CityIncidentWorld` overrides **neither**. They are the base class's pre-doc-05 /
pre-doc-10 stubs, and doc 06's water and traffic generators have been scanning an
empty array since the day they were written. That is a third of doc 06's
generator surface, and two of the five departments in the founding roster — 2
water repair trucks and the construction crew that supports them — with no
ambient work to answer.

For this pass it is also the reason the floor carries **three** rows instead of
five: **a floor row for a channel with no candidate source is dead data**, which
is the thing report 98 spent itself deleting, so none is authored and
`test_gate_19` asserts their absence.

Filed as **D-14** (water) and **D-15** (traffic). Both are adapter work in
`sim/incidents/city_incident_world.gd` and both need a schema join, not a number.
Doc 06 already documents exactly what it wants, and both subsystems already
publish every field:

| generator | row doc 06 wants (`incident_world.gd`) | who has it |
|---|---|---|
| `water_main_break` | `{id, tile, length_km, condition, pressure_ratio, utilization, freeze_stress, zone}` | doc 05 `WaterSystem` |
| `traffic_accident` | `{id, tile, congestion_index, signalised, signal_powered, condition_hazard_mult}` | doc 10 `RoadNetwork` |

When they land, §18.3's budget is re-derived across five channels rather than
three, and **the two new rows come out of the three existing ones** — the ruled
2–4/game-week band is a budget for the whole dispatch loop, not a per-channel
allowance.

### 18.3 The ruling, the numbers, and the A/B they were measured on

**Budget: 3.0 ambient incidents per game-week at starter scale** — the middle of
the ruled band rather than its edge, so Poisson noise on a real session lands
inside the band instead of on its rim. Split by which department answers it and
by how much stake each one carries:

| channel | floor, /game-day | department | why this share |
|---|---|---|---|
| `crime` | **0.20** | police (2 patrol) | the safest channel to floor: it self-resolves at tier ≤ 2 after 2 game-hours, damages no building, and its natural rate at t0 (0.051) is the furthest below a playable beat. It carries the ambient texture. |
| `transformer_failure` | **0.10** | utility (2 trucks) | the *teaching* incident — what the tutorial scripts, and the one whose consequence (a dark block) is legible from the camera without opening a panel. |
| `structure_fire` | **0.10** | fire (1 engine) | deliberately the rarest, and the only one authored within noise of its own natural rate (0.083) — a **1.2×** lift where crime gets 3.9×. One engine, `esc_base 2.20`, a 0.5-game-hour burn-down timer and a building at the end of it: a fire should be an event, not a chore. Its floor is insurance for a *shrunken* roster, not a lift on a full one. |
| **authored total** | **0.40** | | 2.80/game-week of floor, before the natural rate and doc 06's grid-failure map add to it |
| `grace_days` | **2.0** | | the founding day and the one after are quiet, so the tutorial's scripted transformer is the first incident a new player ever meets. One game-day tighter than doc 07 §8's Director grace of 3, so the first *ambient* beat lands before the first Director event. |

**The A/B. Same twelve seeds, same 28 game-days, same `do_nothing` control, one
boolean apart — 336 game-days on each side:**

| | floor off | **floor on** | ruled band |
|---|---|---|---|
| ambient incidents / game-week | 1.88 | **3.04** | 2–4 |
| — `crime` | 0.35 | **1.15** | |
| — `transformer_failure` | 0.94 | **1.31** | |
| — `structure_fire` | 0.58 | **0.58** | |
| Director events / game-week | 0.50 | **0.50** | untouched — doc 07 §8's floor is a different question |
| incidents resolved | 90 / 90 | **146 / 146** | the ruling's survival clause |
| failed / abandoned | 0 / 0 | **0 / 0** | |
| buildings destroyed | 0 | **0** | |
| treasury, 28 game-days, mean | $187,551 | **$189,863** | +1.2 % |

**Three channels, three different answers, one `max()`** — this is the table that
explains the design:

- **`crime` triples** (0.35 → 1.15). Its natural rate is a fifth of its floor at
  every hour of the day, so the floor simply *is* its rate at starter scale.
- **`transformer_failure` rises 40 %** (0.94 → 1.31) even though its daily-mean
  natural rate (0.134) is *above* its floor (0.10). The floor works on the
  instantaneous λ, and doc 06 prices transformer failure on `(load_ratio /
  0.70)³` — at 03:00 the load ratio is pinned at its 0.20 clamp and that cube is
  0.023, so the natural rate collapses overnight. The floor fills the trough and
  leaves the evening peak exactly as doc 04 wrote it.
- **`structure_fire` does not move measurably** (0.58 → 0.58, and 28 incidents on
  both sides — the same integer twice). Its floor is only 1.2× its natural rate,
  so the arithmetic lift is on the order of **+3 expected incidents over 336
  game-days against a standard deviation of 5.6**: below this measurement's own
  noise floor. Landing on *exactly* the same integer rather than merely a similar
  one is the shared RNG stream — `structure_fire` draws from `incidents`, and at
  a per-sub-step λ near 3.5 × 10⁻⁴ the Poisson draw consumes exactly one
  `randf()` whether it returns 0 or 1, so a 20 % λ change moves the break
  threshold by ~7 × 10⁻⁵ and only a handful of the run's ~95,000 draws could flip
  at all. None did. Stated plainly because the tempting reading of this row —
  *"the `max()` never binds for fire"* — is **false**, and a reader who believed
  it would mis-set the next fire constant. Resolving it wants either more seeds
  or a channel-level λ probe, and neither is worth a pass on a 1.2× lift.

  What is true is the design intent behind it: doc 02's `fire_ignition_per_hour`
  is a per-building constant that drifts only with condition, so on a full
  34-building roster fire is the one channel that was already close to a playable
  rate and it is authored to stay there. Its floor is what stands between the
  player and silence when the roster **shrinks** — a city that has just lost
  buildings to a fire, or an early one that has not built many — and that is a
  case this A/B does not contain.

And the last row is the pleasant surprise: because doc 06 credits `reward_base`
on resolve, giving the dispatch loop a heartbeat makes the control city
*slightly richer*, not poorer. The pacing floor is not a tax on standing still;
it is the game's smallest income stream finally having something to bill.

### 18.4 A neglected city meets its fires sooner — the gradient, measured

The ruling's second clause holds without a single constant spent on it, because
the floor is a `max()` and neglect raises the natural rate straight through it.
This document's own six agents, 21 game-days × 3 seeds each:

| strategy | incidents / game-week | of which fires | failed | what it does differently |
|---|---|---|---|---|
| `do_nothing` | 3.11 | 5 | 0 | nothing — the floor IS its rate |
| `infrastructure_first` | 3.00 | 6 | 0 | grid ahead of growth; it stays small, so the floor is still its rate |
| `balanced` | 45.8 | 20 | 4 | 272 buildings by day 21 — the natural rate has left the floor two orders behind |
| `tax_squeezer` | 99.3 | 27 | 13 | `balanced` with the slider pinned: more city, more of everything |
| `disaster_neglect` | 107.2 | **70** | **106** | `balanced` with `maintains = false`: **3.5× the fires and 26× the failures of the agent it is otherwise identical to** |
| `greedy_growth` | 148.1 | **105** | **298** | never repairs, never buys grid, never sets a priority class |

`disaster_neglect` differs from `balanced` in exactly one field
(`tests/test_playtest_harness.gd` asserts the `is Balanced` relationship and that
each issues or withholds exactly the verbs its knob controls), so the
70-fires-against-20 row is attributable to neglect and to nothing else. The
mechanism is doc 06's own: `factors.fire.unpowered_mult` on a dark building,
`arson_k` on a district whose stability has fallen through 0.35, and doc 02's
`fire_condition_mult` on a roster nobody repairs. **The floor is invisible in
every row below the first two**, which is the whole point of writing it as a
`max()`.

### 18.5 Where the pacing floor is NOT the instrument

Three things this pass deliberately did not move, each with its reason:

- **`data/incidents.json` `generator_base_rates`.** Report 98 R-11/R-13
  calibrated all six per asset. A pacing problem at 34 buildings is not evidence
  about a rate per node, and the same edit would make an 800-building city
  unplayable.
- **`data/director.json` `floor`.** Doc 92 pass-2 F-1 set it at 6 tp/game-day,
  `max_hazard_tier 1`, `classes ["minor"]`; it delivers 0.50 events/game-week at
  starter scale — measured, unchanged, and answering a *different question*
  (*does anything ever HAPPEN to this city?*) from the one D-6 asks (*does the
  dispatch loop ever RUN?*). Two floors, two documents, two questions. Raising
  the Director's to fix D-6 would have bought weather instead of dispatch.
- **`data/director.json` `fairness` cooldowns.** The ambient floor is doc 06
  generation and is not subject to doc 07's per-type cooldowns or target
  immunity, which is correct: those exist to stop the *Director* staging the same
  disaster twice, and a neighbourhood having two burglaries in a game-week is not
  unfair — it is a neighbourhood.

### 18.6 Wave 7 — the re-derivation §18.2 asked for, and the band it breaks

*2026-08-19, one wave later. §18.2 filed D-14 and D-15 and said: "when they land,
§18.3's budget is re-derived across five channels rather than three, and the two
new rows come out of the three existing ones." They have landed
(`sim/incidents/city_incident_world.gd`). This is the re-derivation, on the same
rig, the same twelve seeds and the same 28 game-days of `do_nothing` — and it
does not fit inside the ruled band.*

| ambient / game-week | floor **OFF** | floor **ON** (5-channel, shipped) | floor ON (old 3-channel split) |
|---|---|---|---|
| `crime` | 0.35 | **0.73** | 1.19 |
| `structure_fire` | 0.69 | **0.56** | 0.67 |
| `transformer_failure` | 0.81 | **1.08** | 1.23 |
| `water_main_break` | 0.58 | **0.60** | 0.56 |
| `traffic_accident` | 3.58 | **3.60** | 3.60 |
| `storm_damage` | 0.04 | **0.04** | 0.04 |
| **total** | **6.06** | **6.62** | **7.29** |
| resolved / created | 291 / 291 | **318 / 318** | 350 / 350 |
| failed · abandoned · destroyed | 0 · 0 · 0 | **0 · 0 · 0** | 0 · 0 · 0 |
| treasury, 28 gd, mean | $193,627 | **$194,847** | $189,772 |

**The three-channel columns reproduce §18.3.** Its 3.04/game-week against 3.09
here for the same three channels, on different seeds — so the rig is measuring
the same process it measured a wave ago, and the new rows are the only news.

**The budget did not move; the split did.** `per_day` still sums to 0.40, as
§18.2 ruled: `0.20 / 0.10 / 0.10` → `0.14 / 0.08 / 0.08 / 0.06 / 0.04`. Crime
keeps the largest share for §18.3's reason and halves because the loop now has
five channels feeding it. `traffic_accident` takes the **smallest**, and the
reason is the finding below.

**The 2–4/game-week band is not reachable, and the floor is not why.** Switched
entirely OFF the city runs at 6.06 — the floor's whole leverage is 0.56/game-week
and a `max()` cannot subtract. `traffic_accident` alone is 3.58, and that is doc
06 §2.6(e) working exactly as written: **doc 09 stamps a road grid of 389
junctions before the player has built anything**, so the one generator whose
asset base is not player-built is at full size from game-hour zero, while the
other five scale with 34 buildings and 144 residents. §18.1's opening sentence —
*"every generator is priced per asset, so its λ is proportional to what the
player has already built"* — has exactly one exception, and it is the channel
that was dead when that sentence was written.

Nor is the per-node rate too high: doc 06 §2.6(e)'s own worked example intends
**0.687 accidents/game-day** for a 20-intersection city, and the starter city
measures **0.515** — *below* doc 06's stated intent. Bringing the total inside
2–4 would mean cutting `traffic_per_intersection` about 6.5× and invalidating all
four of §2.6(e)'s worked examples, to make the shipped game quieter than its own
specification. **That is not a retune this pass will make on its own authority.**

What the ruling's testable clauses say is that the loop is healthy at the new
rate: 318 of 318 resolved, nothing failed, nothing abandoned, nothing destroyed,
and the control city banks **more** than it did with two generators dead, because
doc 06 credits `reward_base` on resolve. The dispatch loop is now a **daily**
beat rather than a weekly one. Gate 19 is retuned to the measurement and says so
in its own docstring; **the band itself needs a ruling** — see the Wave-7
delivery report's open question 1.

---

## 19. Pass 5 — progression pacing (audit 91 D-7)

Audit 91 **D-7**: *"the soak's city never left city level 0 in 12 game-days, so
every one of 376 upgrade attempts was refused `E_CITY_LEVEL`."*

### 19.1 The old ladder was never measured against anything

`[0, 250, 1000, 4000, 12000, 30000]` was adopted verbatim by report 98 G-1 from a
doc 02 *proposal*, into a `data/progression.json` that report 98 named and nobody
ever wrote — so the six rows lived as a `const` in
`sim/population/progression_system.gd` and were the one balance number in the
game that could not be retuned without a code edit. Set against this document's
own measurements, four of the six rungs are unreachable by anything the game can
currently do:

| evidence | measurement | highest rung it clears |
|---|---|---|
| §8 — 90 game-days of `greedy_growth`, the fastest builder in the study | peak population **1,872** | level 2 (1,000) |
| §19.1 here — **50** game-days of `balanced`, the competent player | population **2,710**, still **city level 2** | level 2 |
| audit 91 §14.2 — the 2-real-hour QA soak, 12 game-days | population never left the founding band | **level 0** |

Level 3 (4,000) was out of reach at fifty game-days. Levels 4 and 5 (12,000 and
30,000) are out of reach by factors of six and sixteen against the highest
population this game has ever produced. Doc 02 §2.10–2.11's entire upgrade
ladder — every L4 and L5 rung, `high_rise` at all, `data_center` at all, doc 10's
`road_crew` at `city_level 3` — sat behind a door with no key.

**The fit's input: measured `balanced` population, seed 1337, coarse path.**

| game-day | 1 | 2 | 3 | 4 | 5 | 10 | 15 | 20 | 25 | 30 | 40 | 50 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| population | 180 | 208 | 244 | 292 | 344 | 678 | 890 | 1,340 | 1,432 | 1,898 | 2,145 | 2,710 |

### 19.2 The retune, and the cadence it is fitted to

The ruling: **a played city hits level 1 inside game-days 2–4 and level 2 by
about day 10–14, and the unlock cadence should feel like progression.** A cadence
is felt in TIME, not in ratios, so the rungs are placed on the measured curve
above at game-days that roughly double — **2, 11, 23** — and the two rungs beyond
the measured window are placed by the ratio the fitted rungs settle into.

| city level | 0 | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|---|
| **was** | 0 | 250 | 1,000 | 4,000 | 12,000 | 30,000 |
| **is** | 0 | **200** | **700** | **1,600** | **3,600** | **8,000** |
| ratio to previous rung | — | — | 3.50× | 2.29× | 2.25× | 2.22× |
| `balanced` reaches it on game-day | t0 | **2** | **11** | **23** | *outside the window* | *outside the window* |

The steep first ratio is deliberate and is the shape of the finding: the founding
city is 62 %-vacant and the first rung has to be **56 residents away** — fourteen
houses or three apartments — or the first session has no beat in it at all. From
level 2 up the ladder settles at a flat ~2.25×, which is what "each rung costs
about twice the last one in game-days" works out to once the occupancy ramp and
the block-development pipeline are both running.

The ladder now lives in **`data/progression.json`** — doc 09 §8.2's file, created
by this pass. `ProgressionSystem.CITY_LEVEL_POP_FALLBACK` holds the same six rows
as a **missing-file degrade and not as a mirror**; gate 20 asserts the two agree,
so a half-landed retune is a test failure rather than a surprise six weeks later.
Doc 09 §8.2 also authors `population`, `happiness`, `milestones`,
`stats_counters` and `bench_city` blocks for that file; their consumers still hold
their own constants and moving them is not this pass's job, so the file ships
with the one block that has a reader and its header says exactly that.

**What levels 4 and 5 are waiting on.** They are placed by ratio because there is
nothing to fit them to: no strategy in this document has ever produced 3,600
residents. That is pass-3 **F-11**'s ceiling and not a progression finding — a
well-played city runs into the two-feeder 2,400 kW supply path at around game-day
24 and its growth flattens (§17.3; gate 18b pins it). **When the feeder verb
lands, levels 4 and 5 get a real fit and this table gets a fourth row.** Until
then they are honest extrapolation, labelled as such.

### 19.3 Measured — the full matrix, 6 strategies × 3 seeds × 21 game-days

| strategy | level 1 | level 2 | level 3 | level at day 21 |
|---|---|---|---|---|
| `greedy_growth` | day 1 | day 7 | **day 11–13** | 3 |
| `tax_squeezer` | day 2 | day 11–12 | **day 18–19** | 3 |
| `balanced` | **day 2** (all 3 seeds) | **day 11** (all 3 seeds) | — | 2 |
| `disaster_neglect` | day 2 | day 10 | — | 2 |
| `infrastructure_first` | day 6–7 | — | — | 1 |
| `do_nothing` | never | — | — | 0 |

Both ruled windows are hit on all three seeds with **no seed-to-seed spread at
all**, which is itself worth recording: the early population curve is driven by
the agent's build order and doc 09's occupancy ramp, not by the RNG, so this is a
rung *placement* and not a lucky sample.

Three things the table shows that the ruling did not ask for but wanted:

- **Level 3 is now reachable inside a three-game-week session** by the two agents
  that push hardest, where it was previously unreachable in fifty game-days by
  anyone. That is `high_rise` on the build sheet, every L4 upgrade, and doc 10's
  `road_crew`, all inside the horizon this document measures. At the 50-game-day
  horizon `balanced` reaches level 3 on **day 23**.
- **`do_nothing` still never levels.** The ladder is not a participation trophy:
  it is population, and population is buildings.
- **`infrastructure_first` reaching level 1 on day 6–7 rather than day 2** is the
  agent, not the ladder. It holds ≥ 24 served empty tiles per owned block and
  saves for the next block's development bill instead of spending the difference,
  so a player who invests before growing pays for it in progression time. That is
  a legitimate trade, and now a visible one.

### 19.4 What did NOT move, and the checks that say so

- **Monotonicity (doc 09 §2.11)** is unchanged and untouchable: a level, once
  earned, survives any disaster. Retuning a threshold *down* can only grant a
  level, never take one back, so this retune cannot un-earn anything in an
  existing save — `city_level_max` in the `progression` save section still wins.
- **The founding city is still below rung 1.** 144 residents against 200, so
  `cmd_place_building("apartment", …)` still answers `E_CITY_LEVEL` at t0: the
  Wave-5 `min_city_level` ruling, gate 14, and the tutorial's first locked build
  card all still bite. Gate 20 asserts it directly rather than trusting it.
- **The tutorial is unaffected.** Every one of the eleven steps places
  `min_city_level 0` archetypes at city level 0.
  `tests/test_tutorial_flow.gd` is green over the real `game/main.tscn` shell,
  5/5, with the eleven steps advancing and the scripted transformer resolving in
  its measured 62-game-minute window.
- **`data/starter_city.json`'s 40 block `min_city_level` rows are untouched.**
  Report 98 G-1 re-based them onto this ladder's *indices*, and indices are what
  they reference — ring 1 still opens at level 0, ring 2 at levels 1–2. What
  changed is when the player earns those indices, which is the point.

### 19.5 The 50-game-day pair, re-run — and what the two passes cost it

Both changes are pressure, so the honest thing is to re-run §15.2's pair past the
pacing horizon and print the bill. Seed 1337, coarse, before → after:

| | `balanced` before | `balanced` after | `disaster_neglect` before | `disaster_neglect` after |
|---|---|---|---|---|
| population, day 50 | 2,710 | **2,274** | 1,015 | **1,012** |
| city level, day 50 | 2 | **3** (day 23) | 2 | **3** (day 22) |
| buildings | 829 | 795 | 369 | 398 |
| treasury | $75,444 | $106,462 | $1,097,301 | $831,313 |
| value created | $2,178,744 | $2,021,692 | $2,288,951 | $2,012,240 |
| incidents created | 1,374 | 1,363 | 1,701 | 1,587 |
| buildings destroyed | 0 | **2** | 97 | 87 |
| dark share | 55.7 % | 56.5 % | 41.7 % | 47.2 % |

`balanced` pays **16 % of its day-50 population** for the two passes, and the two
causes are separable: it now builds one civic building per city level and there
are three levels instead of two, and it loses two buildings to fire where it
previously lost none. Both are the passes working — a city with a real dispatch
loop loses the occasional building, and a city with a reachable ladder spends
some of its floorspace on the stations that ladder unlocks.

Neither is a finding, because **neither is inside the horizon the rulings are
written against**: at 21 game-days every gate holds unmoved (§18.3, §19.3, 25/25
green), and past game-day 24 both columns are governed by pass-3 F-11's power
cliff — 56 % dark, minimum condition 0.000 — which was already true before this
pass and is the feeder verb's problem, not the pacing floor's. Recorded here so
that when the feeder verb lands, the day-50 population is re-measured against
**2,274** and not against pass-3's number.


---

## 20. Pass 6 — the tax ruling (Wave 7)

Everything in §20 is measured on the **online** coarse step through
`tests/balance_matrix.gd` / `BalanceGateRig`, seeds 1337 / 4242 / 9001, 21
game-days, and on gate 12b's controlled pair (seed 1337, identical build plan,
identical tiles, one field different).

### 20.1 The finding: Wave 6 handed `tax_squeezer` a spending problem

Pass 2's F-5 ruled that the top tax detent must be **money now versus a city
later**, and pass 2 + T-1 delivered it: at `TAX_RATE_HAPPINESS_COEFF 220` the
controlled pair showed the detent costing **18.3 %** of a fixed city's
population for **1.71×** the cash, and gate 12b held that.

Wave 6 then made the power grid buyable. That is the missing half of the story,
because `tax_squeezer` is `balanced` with one knob moved: it has 1.778× revenue
and, before Wave 6, nowhere to put it. With feeders, substations and plants on
the build sheet it converted the money into **more city**, and on the 21-game-day
matrix it stopped merely being rich:

| 21 game-days, 3-seed mean, coeff 220 | `balanced` | `tax_squeezer` | delta |
|---|---|---|---|
| value created | $878,217 | $1,787,852 | **+104 %** |
| treasury | $78,704 | $133,122 | +69 % |
| **population** | 1,342 | **1,918** | **+43 %** |
| happiness | 74.6 | 73.0 | **−1.6** |
| buildings placed | 219 | 249 | +14 % |
| city level | 2 | **3** | +1 |

**Strictly dominant again** — ahead on every column a player can see, for a
happiness deficit inside seed noise. The controlled pair was *also* still true;
the two measure different questions, and the one with a build plan in it is the
one a player lives in.

### 20.2 The ruling, and why it is one key

The overseer's ruling: **raise `tax.TAX_RATE_HAPPINESS_COEFF` until the top
detent costs a 21-game-day city ≥ 8 happiness points AND `tax_squeezer` trails
`balanced` on population by ≥ 10 %.** Fit on the controlled-pair rig, confirm on
the matrix.

One key is enough because doc 03 §2.2's three couplings are **all denominated in
the points `happiness_tax_delta` produces**:

```
happiness_tax_delta       = -(r - 0.09) × TAX_RATE_HAPPINESS_COEFF
attractiveness_tax_factor = 1 + TAX_RATE_ATTRACT_PULL × min(0, happiness_tax_delta)/100
growth_rate_multiplier    = 1 - (r - 0.09) × TAX_RATE_GROWTH_COEFF     ← untouched
```

so the coefficient moves the happiness target **and** doc 09's attractiveness
ceiling, and the rate is still read exactly once in the whole chain (report 98's
no-double-count rule). `TAX_RATE_ATTRACT_PULL`, `TAX_RATE_GROWTH_COEFF`,
`TAX_RATE_MIN/MAX`, `TAX_RATE_STEP` and every revenue term are untouched.

### 20.3 The fit — 360, and why not a rounder number

The fit is **steep**, because population trails only once the attractiveness
ceiling falls far enough that the squeezed agent's extra buildings stop paying
for themselves. Measured on the matrix, `tax_squeezer` against `balanced`
(3 seeds except where noted):

| coeff | Δ at `TAX_RATE_MAX` | `A_tax` | population | happiness gap | value created | treasury |
|---|---|---|---|---|---|---|
| 220 (Wave 6) | −15.4 | 0.7998 | **+43 %** | 1.6 | +104 % | +69 % |
| 300¹ | −21.0 | 0.7270 | +8.7 % | 18.6 | +61 % | +14 % |
| 340 | −23.8 | 0.6906 | −5.5 % | 21.2 | +43 % | −3 % |
| **360 (ruled)** | **−25.2** | **0.6724** | **−14.7 %** | **23.0** | **+35 %** | **+22 %** |
| 400¹ | −28.0 | 0.6360 | −21 % | 20.4 | +31 % | −7 % |

¹ seed 1337 only — the two bracketing probes.

**340 misses the ruling** (−5.4 / −5.4 / −5.7 % across the three seeds, against a
required 10 %). **400 overshoots into a trap**: the squeezer ends *poorer* than
`balanced`, and a detent that costs population and money is not a tradeoff, it is
a mistake the UI invites the player to make. **360 clears both halves on every
seed** — −17.2 / −13.6 / −13.1 % population, 22.8 / 23.4 / 22.7 happiness points —
and keeps the slider worth pulling at +35 % value created.

### 20.4 The 18-run matrix at the ruled coefficient

| strategy (3-seed mean) | treasury | value | net $/gh | pop | happy | stab | dark % | placed | upg | minC | open inc |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `do_nothing` | $162,083 | $162,083 | 262 | 141 | 83.1 | 0.9491 | 0.22 | 0 | 0 | 0.491 | 0.02 |
| `greedy_growth` | $70,197 | $990,498 | 1,409 | 1,765 | 52.4 | 0.6964 | 38.07 | 123 | 34 | 0.454 | 1.56 |
| `infrastructure_first` | $17,871 | $134,271 | 378 | 231 | 77.4 | 0.9714 | 0.23 | 27 | 0 | 0.890 | 0.01 |
| `balanced` | $78,704 | $878,217 | 2,101 | 1,342 | 74.6 | 0.9406 | 0.07 | 219 | 133 | 0.798 | 0.03 |
| **`tax_squeezer`** | $96,249 | $1,182,823 | 2,813 | **1,145** | **51.6** | 0.9662 | 0.07 | 248 | 159 | 0.797 | 0.02 |
| `disaster_neglect` | $67,409 | $1,043,323 | 1,757 | 1,358 | 56.1 | 0.7732 | 25.21 | 278 | 144 | 0.364 | 0.93 |

**18 of 18 complete.** `incident_abandoned` 0, `credit_line_engaged` 0 and
`director_event_started` exactly 2 on every run, unchanged from §18/§19.

**Four of the six rows are bit-identical to Wave 6, and that is the check that
matters most.** `do_nothing`, `greedy_growth`, `infrastructure_first` and
`disaster_neglect` never touch the slider, so `happiness_tax_delta` is 0 for all
of them and the coefficient cannot reach them — measured, not assumed:
`balanced` seed 1337 reads $91,906 / $853,126 / 1,364 / 74.7 at both
coefficients, to the digit. **Only the agent that pulls the lever moved.**

`tax_squeezer` is now the richest agent per building and the *fifth* largest city
of six. It still out-earns `balanced` by 35 % on value created and 22 % on cash,
and it now pays 23 happiness points and a fifth of its population for it. That is
the trade F-5 asked for, on the agent a player resembles.

### 20.5 Save identity, and why a balance retune is allowed to be free

`happiness_tax_delta` is **exactly 0 at `TAX_RATE_BASE`**, and nothing in the
game runs at any other rate unless a player moves the slider. So the founding
ledger, doc 03's worked examples, `pacing_guardrails` and every anchor gates 1,
2 and 2b hold are untouched *by construction* — and verified rather than argued:

```
tools/profile_sim.gd --baseline   starter city   HASH OK beb73b276c275ab8 / 2efcb1a8cbb3048c
tools/profile_sim.gd --baseline   bench_city     HASH OK dec792975cd3ba89 / 31a0c6eb8c85a68e
                                                 BEHAVIOUR UNCHANGED vs baseline
```

### 20.6 Gates

- **Gate 12** — the coefficient's three published values retuned to −25.2 /
  0.6724 / 0.44 (the growth multiplier is unchanged and stays asserted, because
  the point of the row is that it did *not* move). Both halves of the lever hold:
  the RATE half at 3 game-days (224 people / $33,058 against **148** / $40,842)
  and the TARGET half at 7 (224 against **151**). A new assertion pins
  `happiness_tax_delta(TAX_RATE_BASE) == 0`, which is the whole reason the retune
  is hash-neutral.
- **Gate 12b** — the controlled pair at 21 game-days: **31.1 % fewer people for
  1.258× the cash** (was 18.3 % / 1.710×), attractiveness 0.6724 against 1.0000,
  and a happiness gap of **18.77** points. Its cash threshold drops 1.25× →
  **1.15×**: the measured multiple fell *because the residents the squeezed city
  no longer has were the ones paying the higher rate*, and 1.25 now sits $1,531
  under a measured 1.258 — a gate with a 0.6 % margin measures float noise, not
  balance. A happiness assertion is added at the ruled floor of 8 points.
- **Gate 12c, new** — the ruling's own statement, on the matrix rows: population
  ≤ 90 % of `balanced`'s, happiness gap ≥ 8, and value created still ahead. Its
  header states plainly that it reads two strategy rows and will therefore move
  when someone else's tuning lands; the thresholds are the **ruled** ones and not
  the measured ones, so ordinary drift does not trip it — only a change that gives
  the slider back its free lunch does.

### 20.7 What this pass did not do

`TAX_RATE_ATTRACT_PULL` (1.30) is **held**. It is doc 09's coefficient, it is
authored to the same value as `PopulationSystem.ATTRACT_HAPPINESS_PULL` on
purpose, and moving it would have priced the tax bill differently from every
other source of unhappiness — which is precisely the double-count T-1 exists to
avoid. The whole ruling is one number in doc 03's own block.

The **bottom** detent is unmeasured this pass. At coeff 360 a cut is worth +18.0
happiness points instead of +11.0, which pushes a healthy city's `H_target` past
the 100 clamp — so in practice the bottom detent buys what it always bought (a
1.40× faster refill through `TAX_RATE_GROWTH_COEFF`) plus a slightly higher
`f_happiness`. Whether that is now too generous is a question for a pass that
gives an agent a reason to cut tax; no strategy in this study ever has.
