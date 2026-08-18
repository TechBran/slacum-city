# 97 — Adversarial Numeric Verification of the Report-98 Amendments

**Method.** Every load-bearing figure below was **re-derived from the stated generating formula**, not read from a changelog. Where a doc says "regenerated", the table was regenerated independently (Python, `Decimal`, half-up) and diffed cell by cell. Changelog claims (`§10 Amendments applied`) were treated as assertions to be falsified, not as evidence.

**Verdict: FAIL — 12 substantive findings.** The arithmetic of the amendments is overwhelmingly sound (≈340 of ≈360 re-derived cells reproduce exactly), but three of the forced recomputations (R-04, R-09/R-16, C-07) did not propagate across doc boundaries, and doc 03 — the sole currency authority — violates its own yield anchor in 4 of 8 revenue rows.

---

## 1. Doc 02 — `k_dem` and the 60 demand rows (report C-13 / R-01)

### 1.1 `k_dem > TAX_LEVEL_GROWTH` — **PASS**

| class | `k_dem` | > 2.15? | efficiency loss `1 − 2.15/k_dem` | doc 02 §2.2 claim |
|---|---|---|---|---|
| steady | 2.35 | ✔ | 0.085106 = **8.5 %** | 8.5 % ✔ |
| standard | 2.45 | ✔ | 0.122449 = **12.2 %** | 12.2 % ✔ |
| vertical | 2.55 | ✔ | 0.156863 = **15.7 %** | 15.7 % ✔ |

Compounded L1→L5, against `2.15⁴ = 21.36751`:
`2.35⁴ = 30.49801` → `30.49801/21.36751 = 1.42727` (**+42.7 %**) ✔
`2.45⁴ = 36.03001` → `1.68625` (**+68.6 %**) ✔
`2.55⁴ = 42.28251` → `1.97882` (**+97.8 %**) ✔

All three ordering and magnitude claims in §2.2 verify. Core Rule 3 is restored for all 12 archetypes.

### 1.2 Spot-recomputation of the 60 power rows — **PASS (60/60)**

Formula: `round_kw(power_kw_L1 × k_dem^(L−1))`, `round_kw` = 0.5 / 1 / 5 / 10 / 50 by decade.

| row | raw | rounded | published |
|---|---|---|---|
| house L2 (`3.0 × 2.35`) | 7.050 | 7.0 | 7.0 ✔ |
| house L5 (`3.0 × 2.35⁴`) | 91.494 | 91 | 91 ✔ |
| apartment L3 (`22 × 2.45²`) | 132.055 | 130 | 130 ✔ |
| office L5 (`35 × 2.45⁴`) | 1 261.050 | 1 260 | 1 260 ✔ |
| high_rise L4 (`90 × 2.55³`) | 1 492.324 | 1 490 | 1 490 ✔ |
| data_center L5 (`400 × 2.55⁴`) | 16 913.002 | 16 900 | 16 900 ✔ |
| water_facility L4 (`60 × 2.45³`) | 882.368 | 880 | 880 ✔ |
| construction_yard L3 (`12 × 2.35²`) | 66.270 | 66 | 66 ✔ |

Full sweep: **all 60 `power_demand_kw` cells reproduce exactly.**

### 1.3 The 60 water rows — **PASS on value, FAIL on reproducibility (finding F-07)**

`house` L1 water = **0.08**, and `4 residents × 0.020 m³/h = 0.08` **exactly** — the C-34 anchor holds to the digit. `apartment` L1 = `24 × 0.020 = 0.48` ✔.

But regenerating from the **printed L1 cell** breaks 8 of 60 cells:

| row | from printed L1 | published | from unrounded seed (`old/6.25`) |
|---|---|---|---|
| store L2 | `0.13×2.35 = 0.3055 → 0.31` | 0.30 | `0.128×2.35 = 0.3008 → 0.30` ✔ |
| store L3 | 0.71793 → 0.72 | 0.71 | 0.70688 → 0.71 ✔ |
| store L5 | 3.96474 → 4.0 | 3.9 | 3.90372 → 3.9 ✔ |
| high_rise L3 | 8.45325 → 8.5 | 8.3 | 8.3232 → 8.3 ✔ |
| high_rise L4 | 21.55579 → 21.5 | 21.0 | 21.2242 → 21.0 ✔ |
| high_rise L5 | 54.96726 → 55.0 | 54.0 | 54.1216 → 54.0 ✔ |
| police L3 | 1.14048 → 1.1 | 1.2 | 1.15248 → 1.2 ✔ |
| police L5 | 6.84570 → 6.8 | 6.9 | 6.91776 → 6.9 ✔ |

Substituting the unrounded seeds (`store 0.128`, `high_rise 1.28`, `police 0.192` — i.e. the old 0.8 / 8.0 / 1.2 divided by 6.25) makes **all 60 cells reproduce exactly**. So the *values* are right; the *stated formula* (`water_wu_L1 = old_water_wu_L1 / 6.25`, applied to the table's own L1 cell) is not reproducible as written. A regeneration test reading L1 from the table fails on 8 cells.

**Verdict: PASS on the ruling, FAIL on the audit trail (F-07).** Fix: print the seed at 3 dp, or state that generation uses the unrounded quotient.

### 1.4 Secondary columns (240 cells) — **PASS (238/240)**

`decay` (k 1.20), `fire p/gh` (k 1.28), `FireLoad` (k 2.00), `crime` (k 1.60) all regenerate. Two last-digit nits: `house` L4 fire raw 0.00031457 → published 0.00032 (should be 0.00031); `construction_yard` L3 raw 0.00065536 → published 0.00065 (should be 0.00066). Coverage radii (k 1.25) verify except `fire_station` L2 (`18 × 1.25 = 22.5` printed 22, while `construction_yard` L2 rounds `37.5 → 38` — inconsistent tie-break).

### 1.5 Doc 02's payback table (R-03) — **PASS**

Regenerated from doc 03's curves. `house` L3: `capital_value = 1200 × 6.147 = 7 376.4`; maint `× 0.00040 = 2.9506`; `net = 55 − 2.95 = 52.05`; `upgrade_cost(2→3) = 1200 × 3.6975 = 4 437`; `4 437 / 52.05 = 85.24` ✔ (published 85.2). All 30 payback cells and all six `total_spend` figures (`build_cost_l1 × 39.620`) verify: 47 544 / 103 012 / 277 340 / 515 060 / 1 030 120 / 7 131 600 ✔. `V(L) = [1.000, 2.450, 6.147, 15.576, 39.620]` reproduces from `1 + (1.45/1.55)(2.55^(L−1) − 1)` ✔.

---

## 2. Currency containment and the doc 03 grid anchors (report C-07)

### 2.1 Grid rescale — **PASS (40/40 rows)**

Rule: `× 1/8` (grid) or `× 1/3` (plants), `round_currency` = nearest 10 / 100 / 1 000 by decade.

| check | derived | published |
|---|---|---|
| substation L1 `120 000/8` | 15 000 | **15 000** ✔ (ruled anchor) |
| plant_gas L1 `180 000/3` | 60 000 | **60 000** ✔ (ruled anchor) |
| substation L4 `1 050 000/8 = 131 250` | 131 000 | 131 000 ✔ |
| substation L5 `2 100 000/8 = 262 500` | 263 000 | 263 000 ✔ |
| transformer L2 `9 000/8 = 1 125` | 1 100 | 1 100 ✔ |
| transformer L5 `130 000/8 = 16 250` | 16 300 | 16 300 ✔ |
| feeder cls-1 `900/8 = 112.5` | 110 | 110 ✔ |
| transmission cls-1 `5 800/8 = 725` | 730 | 730 ✔ |
| plant_gas L5 `2 900 000/3 = 966 667` | 967 000 | 967 000 ✔ |
| plant_solar L1 `220 000/3 = 73 333` | 73 300 | 73 300 ✔ |
| flood_wall `45 000/8 = 5 625` | 5 600 | 5 600 ✔ |

Every remaining row also reproduces. The S8 cross-check `15 000 + 34×1 200 + 3 500 = 59 300 ≈ "≈60 000"` holds ✔.

### 2.2 Vehicle rescale (R-14) — **PASS**

`GAMMA = ln(1.60)/ln(4.22222) = 0.4700036 / 1.4403615 = 0.3263072` ✔ (published 0.32631).
`fire_engine: 9 000 × 4.22222^0.3263072 = 9 000 × 1.600000 = 14 400` — lands **exactly** on the ruled 1.60× ✔.
`water 1.88889^γ = 1.23063 → 11 076 → 11 100` ✔ · `utility 2.11111^γ = 1.27611 → 11 485 → 11 500` ✔ · `crew 2.66667^γ = 1.37723 → 12 395 → 12 400` ✔.
All 15 `dispatch_cost` cells reproduce from `round(2.4 × upkeep)` ✔.
Starter fleet `2×7 + 12 + 9 + 9 + 14 = 58` ✔ — matches §2.12's `fleet 58` line exactly.
*(Nit: §2.13(c) claims the upkeep band is 0.05 %–0.11 %; `construction_crew` is 14/12 400 = **0.113 %**.)*

### 2.3 Containment — **FAIL (finding F-06)**

| doc | still carries a price? | verdict |
|---|---|---|
| 02 | build costs appear only as **row labels** in the §2.2 payback table, all matching doc 03 exactly | acceptable restatement |
| 04 | quotes doc 03's $6 900 / $2 800 / $95-per-MWh **as citations** ("doc 03 price") | compliant |
| 05 | `price_inputs` are dimensionless ratios only; loader guard forbids dollar magnitudes | compliant |
| 06 | quotes doc 03's `$29` / `$2 940` as citations | compliant |
| 07 | repair totals deleted; consumes `economy.repair_cost()` | compliant |
| 09 | quotes doc 03's roster and the land ladder it computes with doc 03's formula | compliant |
| 12 | UI mock-ups only | compliant |
| **10** | **`street $1 800/tile`, `avenue $5 200/tile`, `upgrade $4 000/tile`, `upkeep $2.20 / $6.00 per tile-day`, `ROAD_REPAIR_COST_BASE $600/tile`, block replacement `$360 600`, core `$3 245 400`** | **NON-COMPLIANT** |

Doc 10 flags this itself as open question X-9 and refuses to move unilaterally, which is procedurally correct — but the result is a live contradiction with real magnitude:

- a STREET tile ($1 800) costs **more than a house** ($1 200) on the sole ladder;
- one block's stamped template prices at **$360 600** against doc 03's `road_install` phase charge of **$6 930–$21 090** — a **17–52×** gap;
- doc 10's per-tile upkeep prices the 9-block core at **$157.28/gh** (verified: `9 × (60×6.00 + 27×2.20) / 24 = 9 × 419.40 / 24 = 157.275`), and **doc 03 §2.12's ledger has no roads line at all**. Booking it would take the restated net from **+$373/gh to +$216/gh — a 42 % cut** that invalidates the entire S1–S12 arc.

Doc 10's own block arithmetic is internally correct (`60×5 200 + 27×1 800 = 360 600` ✔; `60×1.40 + 27×0.50 = 97.5` ch ✔; `12 × 600 × 0.60 = 4 320`, `12 × 0.35 × 0.60 = 2.52` ch ✔; template `60 + 27 = 87` tiles from a 16×16 perimeter of 60 plus a 14+14−1 = 27 collector cross ✔; `256 − 87 = 169` buildable ✔; `87/256 = 0.3398 ≈ 0.34` ✔).

---

## 3. Doc 03 — the starter anchor, expenses and worked example E

### 3.1 `$686/gh` gross base tax — **PASS**

`18×12 + 5×26 + 3×70 + 1×130 = 216 + 130 + 210 + 130 = 686` ✔ exactly, with zero tolerance consumed. Doc 09 §2.9.4 reproduces the same sum and correctly shows the withdrawn 28/8/6/1 mix at `336 + 208 + 420 + 130 = 1 094` = **+59.5 %** ✔.

### 3.2 The yield anchor — **FAIL (finding F-01, the most serious)**

Doc 03 §2.2 states `base_tax_L1 = build_cost_L1 × TAX_YIELD[class]`, and §7 test 7 (`test_base_tax_yield_invariant`) asserts equality for **every** entry. Re-derived:

| type | class | cost | `round(cost × yield)` | published | |
|---|---|---|---|---|---|
| house | residential 0.0100 | 1 200 | 12 | 12 | ✔ |
| apartment | residential 0.0100 | 7 000 | 70 | 70 | ✔ |
| highrise_res | residential 0.0100 | 26 000 | 260 | 260 | ✔ |
| **store** | **commercial 0.0105** | **2 600** | **27** | **26** | **✗** |
| **office** | **commercial 0.0105** | **13 000** | **137** | **130** | **✗** |
| highrise_com | commercial 0.0105 | 40 000 | 420 | 420 | ✔ |
| **factory** | **industrial 0.0095** | **22 000** | **209** | **210** | **✗** |
| **data_center** | **tech 0.0117** | **180 000** | **2 106** | **2 100** | **✗** |

`store` and `office` are priced at the **residential** yield 0.0100 (`2 600 × 0.01 = 26`, `13 000 × 0.01 = 130`), not the commercial 0.0105 they are labelled with. **Test 7 fails on 4 of 8 revenue archetypes as the tables ship.**

This is load-bearing, not cosmetic: the $686 anchor *depends on the non-conforming values.* Applying the stated anchor gives
`18×12 + 5×27 + 3×70 + 1×137 = 216 + 135 + 210 + 137 = **$698/gh**` — still inside the ±5 % gate (+1.75 %), but C-11's headline "evaluates **exactly**" becomes false and `STARTER_GROSS_TAX_PER_HOUR = 686` would need to move to 698.

Either the four `base_tax_l1` cells or the `TAX_YIELD` map (or test 7) must change. **Nothing here is self-consistent today.**

*Also, three level-curve cells are off by one:* `highrise_res` L5 `260 × 21.36751 = 5 555.55 → 5 556` (published 5 555); `data_center` L4 `2 100 × 9.938375 = 20 870.59 → 20 871` (published 20 870); L5 `44 871.76 → 44 872` (published 44 871). The other 37 cells reproduce exactly.

### 3.3 Starter expense $347 / net +$373 — **internally consistent, but built on a stale inventory (findings F-02, F-03, F-04)**

Doc 03's own arithmetic checks out:
`27+116+58+40+57+6+1+5+32+1+4 = 347` ✔ · `720 − 347 = 373` ✔ · `Δ = 30 + 16 − 5 = +41` ✔ · `414 × (1 − 41/414) = 414 × 0.900966 = 373.0` ✔ · revenue `686 × 0.90 = 617.4 → 617`, `617+93+7+3 = 720` ✔.

The §2.4 `E_grid` worked value is also self-consistent:
`8.00 MW × 5.0 = 40.00` + `6.00 MVA × 4.0 = 24.00` + `2.05 MVA × 4.0 = 8.20` + `0.88 km × 0.9 = 0.79` = **$72.99 → $73** ✔.

**But the inventory it prices is not doc 09's.** Doc 09 §2.9.5 (recomputation R-16, verified transformer by transformer in §7 below) publishes:

| quantity | doc 03 §2.4 + doc 04 test 24 | doc 09 §2.9.5 (authoritative) |
|---|---|---|
| transformers | 14 × L1 + 9 × L2 | **13 × L1 + 9 × L2 + 1 × L3** |
| `rated_mva` (transformers) | 2.05 | **2.40** |
| line tiles | 110 feeder = 0.88 km | **147 feeder + 30 transmission = 177 tiles = 1.416 km** |

Re-deriving `E_grid` on doc 09's real inventory:

```
plant        8.00 MW  × 5.0            = 40.000
substation   6.00 MVA × 4.0 × 1.0      = 24.000
transformers 2.40 MVA × 4.0 × 1.0      =  9.600
lines        1.416 km × 0.9 × 1.0      =  1.274
                              E_grid   = 74.874  →  $75/gh      (not $73)
```

**F-02.** Doc 04 §7 test 24 asserts `E_grid = $73 ± 1/gh` on the stale set. Against doc 09's published inventory the value is **$74.87 — outside the ±1 tolerance. The test fails as written.**

**F-03.** Doc 03 §2.12 keeps `pump O&M 5`, while doc 05 §2.13 explicitly derives, from **doc 03's own `E_water` formula**, `pump_capacity_m3h 40.0 × PUMP_OM_PER_M3H_HOUR 0.35 = **$14/gh**` and states in so many words that this is "not the $5/gh assumed in doc 03 §2.12's starter table". Doc 03's R-04 amendment says "every other line is unchanged" — so the R-09 downstream consequence was never applied.

**F-04 (compound).** Correcting both:

```
grid   32 → 33.6  (24.0 + 9.6)      lines 1 → 1.3      pump O&M 5 → 14
E_total                  = 347 + 1.6 + 0.3 + 9 ≈  $358/gh
NET                      = 720 − 358           ≈ +$362/gh   (published +373)
haircut factor           = 362 / 414           =  0.874     (published 0.90097)
```

Every one of the 24 pacing rows, the 12 guardrail rows and the "end state ≈ $470K" headline is ~2.9 % optimistic. *(The arc almost certainly survives — G1's peak ratio is 12.77 of 14 and scales with both numerator and denominator — but the published figures are wrong and the S7 row is already the one flagged "to watch".)*

### 3.4 The pacing table's internal arithmetic — **PASS (24/24 rows)**

Every `flow = net × hours` and every `treasury_end = start + flow + grants − spend` was recomputed. All 24 rows close to the dollar, e.g. `S1: 25 000 + 45×374 + 10 000 − 17 940 = 33 890` ✔ … `S12: 774 221 + 100×3 153 − 620 000 = 469 521` ✔.

G4: offline `1 256 762`, online `982 295`, ratio **1.27942** ✔ (published 1.279, gate [1.2, 2.0] ✔).
G1/G2 table: all 12 `treasury / (net × 24)` ratios reproduce to 2 dp; peak **12.767 at S7** ✔.
G3 (S8 crunch): treasury at decision `283 556 + 64 880 = 348 436` ✔; Growth `180 000 + 60 000 + 21 000 = 261 000` ✔; Resilience `15 000 + 40 800 + 3 500 + 87 500 + 41 400 + 20 000 + 14 400 = 222 600` ✔; `483 600 / 348 436 = 1.3880` ✔; `222 600 / 348 436 = 0.6389` ✔. Both gates pass.

### 3.5 Worked example E — `$6,700` at `d = 3` — **PASS**

```
D = 0.55 + 0.45·e^(−2/4) = 0.55 + 0.45×0.6065307 = 0.8229388   ✔ (0.822939)
9 000 × 0.8229388                                  = 7 406.449  ✔
      × 0.80   (marsh)                             = 5 925.159  ✔
      × (1 − 0.45×0.443 = 0.80065)                 = 4 743.977  ✔
      × (1 + 0.55×0.75 = 1.4125)                   = 6 700.867  → round_to_100 → $6,700  ✔
```

Every intermediate matches to 5 significant figures. Example F verifies phase by phase: marsh `1 399 + 5 232 + 12 753 + 21 090 + 20 916 + 7 188 = 68 578` ✔; riverfront `1 248 + 3 180 + 4 770 + 6 930 + 12 960 + 5 500 = 34 588` ✔; all-in `75 278` vs `46 988`, ratio **1.6021** ✔ (test 11's 1.602 and its ≥1.50 gate both hold). Example D's intermediate is quoted as 12 389; re-derivation gives **12 394.7** (0.05 % off, rounds to $12,400 either way — nit).

---

## 4. Doc 05 — the WU rescale (report C-34 / R-09 / R-10)

### 4.1 Four constants × 0.1333 — **PASS**

| constant | native | `× 0.1333` | published |
|---|---|---|---|
| `pump` L1 `rated_flow_m3h` | 300 | 39.990 → **40.0** | 40.0 ✔ |
| `tank` L1 `capacity_m3` | 900 | 119.970 → **120** | 120 ✔ |
| `trunk` main capacity | 1 600 | 213.280 → **213** | 213 ✔ |
| `fire_flow_per_engine` | 60 | 7.998 → **8.0** | 8.0 ✔ |
| *(bonus)* `service` main | 400 | 53.320 → **53.5** | 53.5 ✔ |
| *(bonus)* `arterial` main | 4 800 | 639.840 → **640** | 640 ✔ |

### 4.2 ~2 000 residents per L1 facility — **PASS, exactly**

`40.0 m³/h ÷ 0.020 m³/h per resident = **2 000**` ✔, and from the other end `40.0 / 0.08 = 500` L1 houses `× 4 = **2 000**` ✔. Both readings agree to the digit, as §2.4 claims.

### 4.3 Ladder + `base_kw` cross-check — **PASS (30/30 + 24/24)**

`1.50 kW per m³/h × pump capacity` reproduces doc 02's `water_facility` column **digit for digit**: `60 / 145 / 360 / 880 / 2160` (raw `60, 147, 360.15, 882.4, 2161.5` under the 1/5/10 rounding decades) ✔. All 30 per-variant `base_kw` cells regenerate from `kw_per_m3h × capacity` (river 0.30, well 0.75, treatment 0.50, pump 1.50, booster 1.50, tank anchored 5.0 on the 2.45 curve) ✔. All 24 `backup_kw` cells regenerate from `round_kw(coverage_frac × base_kw)` with `coverage_frac = [—, 0.60, 0.70, 0.85, 1.00]` ✔.

### 4.4 Hydrant flow ↔ doc 06 suppression — **PASS**

Doc 05 Example C: `prox = 1 − 0.10×(3−2) = 0.90`; `hydrant_pressure_ratio = 0.85 × 0.90 = 0.765` ✔.
Doc 06's `hydrant_factor = clamp(0.25 + 0.75 × 0.765, 0.25, 1.15) = 0.25 + 0.573750 = **0.82375 → 0.824**` ✔ — identical in both docs and in doc 05 test 15.
Fire draw `2 engines × 8.0 = 16.0 m³/h` ✔; `D_eff = 91.03 + 16.0 = 107.03`, `need = 107.03 − 93.10 = 13.93` ✔; tank `205.8 → 44.1` in `161.7/13.93 = 11.608 h` ✔, empty at `205.8/13.93 = 14.774 h` ✔.

All six worked examples A–F verify end to end (A: `26.93 m³/h`, `3.342 h` to 15 %, `4.011 h` empty ✔; B: `27.21 m³` residual, `92.79/19.20 = 4.833 h` refill ✔; D: `0.28 × 87 = 24.36 L/h`, `400/24.36 = 16.42 h`, `1.4268 MWh × 95 = $135.5` ✔; E: `freeze_mult 5.50`, `cond_mult 1.54`, `0.001863/h`, `1 − 0.998137⁶⁰ = 0.10585 → 1 per 9.45 h` ✔; F: `75.16`, `17.94` headroom, `32.0 × 1.10 = 35.2` blocked, `0.8638^1.3 = 0.8267` ✔).

### 4.5 Two defects

**F-05.** §2.13's "Downstream consequences" still states *"doc 09's starter water demand lands at **8.2 m³/h** against 40 m³/h of L1 supply (**4.9× headroom**, R-16)"*. Doc 09 §2.9.4 recomputes the same quantity on the C-11 manifest as **5.56 m³/h / 7.2× headroom** and explicitly says the report's 8.2 "double-counts the mix in words but not in arithmetic". Re-derived independently: `18×0.08 + 3×0.48 + 5×0.13 + 1×0.32 + 0.19 + 0.40 + 0.96 + 0.16 = **5.56**` ✔ — **doc 09 is right, doc 05 §2.13 is stale.**

**Nit.** §2.4's `demand_split` for `store` publishes **0.00 / 0.55 / 0.45**; the row's own numbers give `0.072 / 0.139 = 0.518` and `0.067 / 0.139 = 0.482` → **0.52 / 0.48**. Every other row's shares reproduce to 2 dp (police 0.52/0.48 from the same 0.144-vs-0.133 structure — the store row is the sole outlier).

---

## 5. Doc 06 — `S_req_base` from `fire_load` (report C-43 / R-12)

### 5.1 The anchor and the 60-row table — **PASS (60/60)**

`S_req = 0.50 × (fire_load/20)^0.45`:

- `house` L1: `0.50 × 1^0.45 = **0.500**` ✔ — exact, as ruled.
- `high_rise` L5: `0.50 × 56^0.45 = 0.50 × 6.1189585 = **3.05948 → 3.060**` ✔.
- `power_facility` L5: `0.50 × 72^0.45 = 0.50 × 6.8522896 = **3.42614 → 3.426**` ✔.
- Per-level ratio `2^0.45 = 1.3660402` ✔.

All 60 published cells reproduce to 3 dp with zero mismatches. The suppression-sizing table also reproduces (`high_rise` L5 T4 `3.060 × 1.80 = 5.508 → 6 engines` ✔; `apartment` L5 T4 `2.508 × 1.80 = 4.514 → 5` ✔).

### 5.2 The mandated "≈3.6" expectation — **the REPORT is wrong, not doc 06 (finding F-09)**

Report 98 C-43 publishes the formula `0.50 × (fire_load/20)^0.45` **and** glosses it as yielding "high_rise L5 ≈ 3.6". These are arithmetically incompatible:

```
0.50 × 56^0.45           = 3.0595        (the published formula)
to reach 3.60 you need   exp = ln(7.2)/ln(56) = 1.9740810 / 4.0253517 = 0.490424
doc 02's suggested 0.474 → 0.50 × 56^0.474 = 3.3697
```

Doc 06 §2.8 identifies this contradiction explicitly, rules for the formula over the gloss, satisfies the exact anchor, and records the one-constant fix (`S_REQ_EXP: 0.45 → 0.4904`) if the overseer prefers 3.60. **Doc 06's arithmetic is correct and its reasoning is sound; the report's "≈3.6" is the defect.** Recorded so it is not silently re-litigated.

*(Nit: doc 06 §2.7's reward example `900 × 1.70 × 1.083333 = 1 657.5` is quoted as `$1,657`; half-up gives 1 658. Downstream `1 657 − 29 − 500 = 1 128` ✔; `2 940 × 0.20 × 0.85 = 499.8 → 500` ✔.)*

---

## 6. Doc 08 — `M(720)` and the 720-hour cap (report C-19 / R-15)

### 6.1 `M(H)` — **PASS**

`M(H) = 1.00 × min(H,72) + 0.60 × clamp(H−72, 0, 648)`, DAMPED span `720 − 72 = 648` ✔.

| H | `min(H,72)` | `clamp(H−72,0,648)` | `M(H)` | `M/H` | published |
|---|---|---|---|---|---|
| 24 | 24 | 0 | 24.0 | 1.000 | ✔ |
| 72 | 72 | 0 | 72.0 | 1.000 | ✔ |
| 240 | 72 | 168 | `72 + 100.8` = **172.8** | 0.720 | ✔ |
| 372 | 72 | 300 | `72 + 180.0` = **252.0** | 0.6774 | ✔ (`fidelity_rate 0.677`) |
| 480 | 72 | 408 | `72 + 244.8` = **316.8** | 0.660 | ✔ |
| **720** | **72** | **648** | **`72 + 388.8` = 460.8** | **0.640** | **✔** |

`460.8 / 720 = 0.64` exactly ✔.

### 6.2 Cap consistency across docs 01 / 08 / 13 — **PASS, no stale 8 h or 72 h caps**

`12 × 3 600 × 1 000 = 43 200 000 ms` ✔ · `12 × 60 = 720 game-hours` ✔ · `720/24 = 30 game-days` ✔ · `720 × 240 = 172 800 ticks` ✔ (240 ticks/gh = 3 600/15).

Grepped all three docs: every occurrence of 8 h / 480 gh / 115 200 ticks / 72 real hours / 4 320 gh / 180 game-days is inside an explicitly historical "was / retired / deleted" clause. Every **normative** figure is 720. Doc 13's `offline_max_hours` is gone (`"//time_bridge": "offline_max_hours DELETED"`). The surviving bare `72` in doc 08 §2.2 is `OFFLINE_FULL_FIDELITY_H`, a *band boundary*, which is correct and required by `M(H)`.

Downstream: doc 13 A-05 `30 × 86 400 = 2 592 000 → clamp 43 200`, `discarded = 2 548 800` ✔; over-cap example `259 200 − 43 200 = 216 000 s = 60 real hours` ✔; slice cost `720 × 12.0 ms = 8.64 s`, `720 × 55 = 39.6 s` ✔. Doc 01's `max_coarse_hours` table (`0.6 → 3 334 → 3 312 → 720`; `2.0 → 1 000 → 984 → 720`; `2.77 → 723 → 720`) reproduces ✔.

*(Nit: doc 01 puts the break-even at `measured_ms ≤ 2.77`, doc 08 at `2.78` (`720 × 2.78 = 2 002`). Re-derived: the rule `clamp(floor₂₄(ceil(2000/m)), 72, 720)` yields 720 for any `m < 2.7816`, so **2.78 is correct and 2.77 is one tick conservative** — harmless, but the two docs should agree.)*

---

## 7. Doc 09 — starter city (report C-11 / R-16)

### 7.1 Population 144 — **PASS**

`18 × 4 + 3 × 24 = 72 + 72 = **144**` ✔. Jobs `(5×6 + 3×2 + 1×30) = 66` market + `(12+14+20+4+2×10+16) = 86` civic = **152** ✔. Workforce `144 × 0.55 = 79.2`; `clamp01(79.2/66) = 1.00` ✔. Per-block tax/pop/jobs table sums to `686 / 144 / 152` ✔ across all nine blocks.

### 7.2 Night peak 783.3 kW — **PASS, verified two ways**

Class aggregation:
`RES (18×3.0 + 3×22) = 120.0 × 1.4600 = 175.20` ✔ · `COM (5×9.0 + 35) = 80.0 × 1.1400 = 91.20` ✔ · `IND 12.0 × 1.0033 = 12.04` ✔ · `CIV (25+28+0+132+5) = 190.0 × 0.9592 = 182.25` ✔ → building total **460.69** ✔.
`streetlights 783 × 0.35 = 274.05` ✔ · `signals 81 × 0.6 = 48.60` ✔ → **783.34 kW** ✔.
`783.34/8 000 = 9.79 %` ✔ · `783.34/6 000 = 13.06 %` ✔ · distributed `322.65/783.34 = 41.19 %` ✔.

Independent cross-check against the 23-transformer table (each row recomputed from its customers + streetlights + signals): `T-01 = 12.04+2.45+0.60 = 15.09` ✔ · `T-04 = 26.86+13.14+16.80+3.60 = 60.40` ✔ · `T-13 = 39.90+10.26+8.75+1.20 = 60.11` ✔ · `T-15 = 126.61+6.65+1.80 = 135.06` ✔ · `T-23 = 0+50.40+10.20 = 60.60` ✔. Column sums: streetlights `272 + 511 = **783**` ✔, signals `28 + 53 = **81**` ✔, feeder loads `361.8 + 421.7 ≈ 783.4` ✔. `F_SOUTH` share `421.6/783.3 = 53.83 %` ✔ against 44/144 = 30.6 % of residents ✔. **This is the most thoroughly self-consistent table in the whole doc set.**

### 7.3 Water totals — **PASS** (see F-05: doc 05 carries the stale 8.2)

`5.56 m³/h` re-derived cell by cell ✔. Headroom `40.0/5.56 = 7.19×` ✔, `40.0/7.10 = 5.63×` at the morning peak ✔, `107/7.10 = 15.07×` source ✔, `80.0/7.10 = 11.27×` treatment ✔. `144 / 2 000 = 7.2 %` of one pump ✔. `WTR-1 site load = 32 + 40 + 60 = 132 kW` ✔ (river L1 + treatment L1 + pump L1 from doc 05 §8).

### 7.4 Stability — **PASS**

Base `0.300+0.200+0.180+0.150+0.044 = 0.874` ✔. Northgate `34/(100×0.55) = 0.61818 → 0.874 + 0.0618 = 0.9358` ✔; the other three clamp to 1.00 → 0.9740 ✔.
`city_stability = (93.580 + 23.376 + 15.584 + 3.896)/144 = 136.436/144 = **0.94747**` ✔.
Under `F_SOUTH`: `(93.580 + 17.604 + 15.584 + 3.896)/144 = 130.664/144 = **0.90739**` ✔; Δ = 0.0401 against a 0.241 district collapse at 16.7 % of population ✔. Downtown's degraded value `0.165+0.140+0.144+0.150+0.100+0.0345 = 0.7335` ✔.

### 7.5 Tutorial block — **PASS**

`4×1.0 + 8×1.4 + 12×1.6 + 14×1.8 + 16×2.0 + 6×1.0 = 4 + 11.2 + 19.2 + 25.2 + 32 + 6 = **97.6** crew-hours` (base 60 ch) ✔.
`97.6 / 0.804 = **121.393 gh**` ✔; all six per-phase wall times reproduce and sum to 121.39 ✔.
`first_block_time_mult 0.48`: `97.6 × 0.48 = 46.848 ch`; `46.848 / 0.804 = **58.269 gh**` ✔ (`2 811` crew-minutes, `3 496` wall game-minutes ✔).
Against the report's target of 58.6 gh: **−0.57 %** — doc 09 states "within 0.6 %" ✔. Specialist path `60/0.804 = 74.63 gh` (38.5 % saving) ✔; rain `121.39/0.85 = 142.81 gh` ✔.

### 7.6 The inventory doc 03 and doc 04 did not pick up

Doc 09's `rated_mva = 13×0.05 + 9×0.15 + 1×0.40 = **2.40**` ✔ and lines `34+27+46+28+12 = 147` feeder + `30` transmission `= 177 tiles = 1.416 km` ✔. **Both differ from the 2.05 MVA / 0.88 km that doc 03 §2.4 and doc 04 test 24 price** — see F-02.

Vacant-lot arithmetic verifies: `2 304 − 783 − 15 − 77 = 1 429` ✔, footprint `18 + 12 + 5 + 4 + 16 + 9 + 9 + 4 = 77` ✔ — but the last term (`WTR-2` tank at 2×2) depends on doc 05's per-variant footprint, which doc 02 contradicts (F-08).

---

## 8. Doc 11 — frustum and draw-call re-derivation at `D_MAX = 420` (report R-17 / C-63)

### 8.1 Present, and the stale 143 is gone — **PASS**

§2.13 is fully regenerated with the generating formulas stated above the tables. The pre-amendment "entire city is FAR at max zoom" claim and the **143** figure are explicitly deleted; the new Z2 total is **174** (180 with overlays).

### 8.2 Geometry re-derived — **PASS on every scalar**

```
Z2:  h      = 420 · sin62° = 420 × 0.8829476 = 370.838   ✔ (370.8)
     nadir  = 420 · cos62° = 420 × 0.4694716 = 197.178   ✔ (197.2)
     r_near = 370.8 / tan82° = 370.8 / 7.115370 =  52.12  ✔
     r_far  = 370.8 / tan42° = 370.8 / 0.900404 = 411.86  ✔   depth 359.74 ✔
     s_near = √(52.1² + 370.8²) = 374.44                  ✔
     s_far  = √(411.8² + 370.8²) = 554.14                 ✔
     tan(hfov/2) = tan20° × 16/9 = 0.3639702 × 1.77778 = 0.6470581  ✔
     w_near = 2 × 374.4 × 0.64706 = 484.53                ✔
     w_far  = 2 × 554.1 × 0.64706 = 717.08                ✔
     area   = ½(484.5+717.1) × 359.7 = 216 107.8 m²       ✔  = 216 108/16 384 = 13.19 blocks ✔
MEDIUM boundary: √(176 400 − 137 493) = √38 907 = 197.25 m ✔
Z1:  h 64.58 ✔ · r_near 26.10 ✔ · r_far 121.50 ✔ · s 69.67–137.61 ✔ · area 12 798 m² = 0.78 blocks ✔
Z0:  h 10.07 ✔ · r 7.34–40.37 ✔ · area 1 159 m² = 0.07 blocks ✔
D(0.5) = 18·√(420/18) = 18 × 4.83046 = 86.95 ✔ · pitch(0.5) = 48° ✔
```

`civ_visible_radius_m`: `√(214.6² + 358.6²) = √174 647 = **417.95 m** → 420` ✔ (2 m spare ✔).
20:9 sensitivity: `0.36397 × 20/9 = 0.80882` (+25.0 %) → `216 108 × 1.25 = 270 135 m² = 16.49 blocks`, `21 × 1.25 ≈ 26 chunks`, `174 + 30 = 204` ✔.

### 8.3 Draw-call budget restated — **PASS**

`Z0 = 4×13 + 4×8×2 + 41 = 52 + 64 + 41 = 157` ✔ · `Z1 = 78 + 96 + 41 = 215` ✔ · `Z2 = (10×10 + 11×3) + 0 + 41 = 133 + 41 = 174` ✔. Headroom against 320, measured on the with-overlay totals: `(320−163)/320 = 49.1 %`, `(320−221)/320 = 30.9 %`, `(320−180)/320 = 43.75 %` ✔ (published 49/31/44 %). Rejected alternative `21×3 = 63`, `63+41 = 104`, saving 70 ✔; "146-call surplus" `= 320 − 174` ✔; shadow share `96/215 = 44.7 %` ✔.

### 8.4 One geometric slip — **finding F-12**

The Z2 chunk-row table lists four rows at nearest-edge `r = 52, 180, 308, **412**`. Chunks are 128 m (§2.2), and the first three rows are correctly spaced `52 → 180 → 308`. The **next** row therefore begins at `308 + 128 = 436 m`, which is **beyond `r_far = 411.8 m` and outside the frustum**. Row D's stated `r = 412` is `308 + 104`, not a chunk multiple — it is the far edge, not a row origin.

Dropping the phantom row: `5 + 6 + 6 = 17` chunks in the bounding rows, ~15 after corner trimming, of which rows A and B (both inside the 197.3 m MEDIUM boundary) are MEDIUM. Opaque falls from **133 to ≈ 110–128**, total from **174 to ≈ 151–169**.

**The error is conservative** (it over-counts), so every conclusion — 44 % headroom, `medium_max_m` stays at 420, Z2 is the shadow-free-but-not-cheapest pose — survives unchanged. Test 19's `±10 %` chunk-count tolerance would nonetheless fail against a correct implementation (21 vs ~16 is −24 %).

*(Nit: `hfov = 2 × 32.90° = 65.80°`, printed as 65.9°. Separately, doc 11 derives ground coverage at 16:9 while doc 12 §2.16 derives it at aspect 2.2 — the two coverage tables are not comparable; doc 11 §9.18 already flags aspect ratio as open.)*

---

## 9. Condition scale — **PASS**

Grepped docs 02, 03, 04, 05, 06 and 07 for `[0,100]`, `/100`, `(100 − condition)`, and threshold literals 85/60/35 used as points.

| doc | result |
|---|---|
| 02 | `condition ∈ [0,1]`; bands 0.85/0.60/0.35, `auto_damage 0.35`, `structural 0.10`, `min_condition_to_upgrade 0.55`, decay ÷100 ✔. Loader guard `decay_per_hour < 0.01` explicitly "fails loudly if anyone re-imports the old `[0,100]` numbers" ✔ |
| 03 | `f_condition = 0.55 + 0.45·C` ✔; `f_stability` note states the `[0,100]` scale "is deleted — there is no `/100`" ✔. Remaining `[0,100]`: **happiness `H`**, a different quantity ✔ |
| 04, 05, 06, 07 | zero hits ✔ |

The only `[0,100]` conditions left are **road** condition in doc 10 (its own scale) and doc 06's citation of doc 10's `condition_hazard_mult(e) = 1 + 0.004·max(0, 75 − condition_e)` — explicitly annotated "on doc 10's own `[0,100]` road-condition scale". Values verify (`55 → 1.08`, `10 → 1.26`, `≥75 → 1.00` ✔). This is arguably a residual violation of C-14's literal "everywhere", but it is a *different quantity on a labelled scale* and is the only surviving instance.

Doc 02's rescaled formulas verify: `fire_condition_mult = 1 + 1.5(1−C)^1.5` → `C=0.85 → 1.087`, `0.60 → 1.380`, `0.35 → 1.786`, `0.00 → 2.500` ✔, matching the band table's 1.09/1.38/1.79/2.50. Example E4: `1 − 0.000720×168 = 0.87904` ✔; `0.000720 × 1.24 × 1.15 = 0.00102672`, `1 − 0.172489 = 0.82751` ✔; repair `43 029 × 0.172 × 0.85 = $6 291` ✔; `14.5 × 0.50 × 0.172 = 1.247 ch` ✔.

---

## 10. Findings

### Substantive

| # | Doc / § | Finding | Magnitude |
|---|---|---|---|
| **F-01** | 03 §2.2, §7 t7 | `base_tax_l1` violates `round(build_cost_l1 × TAX_YIELD[class])` for **store (26 vs 27), office (130 vs 137), factory (210 vs 209), data_center (2 100 vs 2 106)**. `test_base_tax_yield_invariant` fails on 4/8 rows. The $686 anchor depends on the non-conforming 26 and 130; the anchor-conforming mix is **$698**. | high — sole currency authority is self-inconsistent |
| **F-02** | 03 §2.4, 04 §7 t24 | `E_grid = $73/gh` is priced on **14×L1+9×L2 = 2.05 MVA, 110 tiles = 0.88 km**; doc 09 §2.9.5 publishes **13×L1+9×L2+1×L3 = 2.40 MVA, 177 tiles = 1.416 km** → `E_grid = **$74.87**`. Test 24's ±1 tolerance fails. | +$1.9/gh; test failure |
| **F-03** | 03 §2.12 vs 05 §2.13 | Ledger keeps `pump O&M 5` while doc 05 derives **$14/gh** from doc 03's own `E_water` against the rescaled 40 m³/h pump, and says so in writing. R-09's downstream consequence was never applied to R-04. | +$9/gh |
| **F-04** | 03 §2.12 | Compounding F-02+F-03: starter expense ≈ **$358/gh**, net ≈ **+$362/gh** (published 347 / +373); the pacing haircut is **0.874**, not 0.90097. All 24 rows and the "$470K end state" are ~2.9 % optimistic. | whole pacing table |
| **F-05** | 05 §2.13 | Still quotes doc 09's starter water demand as **8.2 m³/h / 4.9× headroom**; the recomputed value is **5.56 m³/h / 7.2×**. Doc 09 identifies the error; doc 05 was not updated. | 47 % overstatement |
| **F-06** | 10 §2.3, §8 | Doc 10 is the **only non-03 doc still carrying a price table** (street $1 800, avenue $5 200, upgrade $4 000, upkeep $2.20/$6.00 per tile-day, repair base $600). A street tile costs more than a house; the block template is **17–52×** doc 03's `road_install` phase; **$157.28/gh** of core road upkeep is absent from doc 03's ledger (**42 % of the restated net**). Flagged as X-9, unresolved. | C-07 not fully landed |
| **F-07** | 02 §2.3 | The water column is **not reproducible from the printed L1 cell** — 8 of 60 cells require the unrounded seed (0.128 / 1.28 / 0.192 vs printed 0.13 / 1.3 / 0.19). Values are right; the stated formula is not. | audit trail / regen test |
| **F-08** | 02 §2.3 vs 05 §2.1 | Doc 02 says the four non-reference `water_facility` variants "reuse the same footprint … shell"; doc 05 owns and publishes per-variant footprints (**tank 2×2**, not 3×3), which doc 09 uses in its 77-tile footprint total. Direct contradiction with a numeric consequence. | 5 tiles + ownership |
| **F-09** | 98 C-43 | The report's own **"high_rise L5 ≈ 3.6"** is arithmetically impossible with the formula it publishes (`0.50 × 56^0.45 = 3.0595`). **Doc 06 is correct**; the report's gloss is the defect. Reaching 3.60 needs `S_REQ_EXP = 0.4904`. | report defect |
| **F-10** | 04 §2.13 | Quotes "the C-11 starter city's **508 kW** building load"; doc 09 R-16 gives **402.0 kW** nameplate / **460.7 kW** at the night peak. Stale. | headroom claim only |
| **F-11** | 03 §5, §8 | Requires "`DEMAND_LEVEL_GROWTH` **must equal 2.35**" and stores `REQUIRED_DEMAND_LEVEL_GROWTH: 2.35`, but C-13 sets **three per-class values** (2.35/2.45/2.55). An equality assertion fails for `standard` and `vertical`. Should be `> TAX_LEVEL_GROWTH`. | test/spec mismatch |
| **F-12** | 11 §2.13 | Z2 chunk-row **D at `r = 412`** cannot exist on a 128 m grid rowed at 52/180/308 (next row starts at 436 > `r_far` 411.8). Real count ≈ 15–17 chunks / ≈ 151–169 calls, not 21 / 174. **Conservative** — every conclusion survives, but test 19's ±10 % chunk tolerance fails. | −24 % chunk count |

### Nits (recorded, not counted as failures)

- 03 §2.2: `highrise_res` L5 `5 555` (→5 556); `data_center` L4 `20 870` (→20 871), L5 `44 871` (→44 872).
- 03 §2.7 example D: intermediate `12 389` vs re-derived `12 394.7` (rounds identically).
- 03 §2.13(c): band claimed 0.05–0.11 %; `construction_crew` is 0.113 %.
- 02: `house` L4 fire `0.00032` (→0.00031); `construction_yard` L3 `0.00065` (→0.00066); `fire_station` L2 radius `22.5 → 22` while `construction_yard` rounds `37.5 → 38`.
- 02 §2.4 and §9(8): "97.8 % **less** utility-efficient" — the ratio is **+97.8 % demand per tax dollar**, i.e. 49.4 % less efficient. §2.2 states it correctly.
- 05 §2.4: `store` demand_split `0.55/0.45` vs computed `0.52/0.48`.
- 06 §2.7: `900 × 1.70 × 1.083333 = 1 657.5` quoted as `$1,657`.
- 01 vs 08: `max_coarse_hours` break-even quoted as 2.77 ms and 2.78 ms (2.78 is correct).
- 09 §2.4 prices `B_3_1` at `$12 600`; doc 03's S1 beat says "buy block 2 (**$12,400**)" — 1.6 % apart, reconciled in words only.
- 11 §2.13 uses aspect 16:9, doc 12 §2.16 uses 2.2 — the two ground-coverage tables are not comparable.
- 11 §2.13: `hfov` printed 65.9°, derived 65.80°.

---

## 11. What was verified and passed

Re-derived independently and reproducing exactly: all 60 `power_demand_kw` cells · 52 of 60 `water_demand` cells (60/60 from the unrounded seed) · 240 secondary building-column cells (238 exact) · all 40 grid-component prices from both ruled anchors · all 15 vehicle prices and 15 `dispatch_cost` cells · the `$686` anchor · the `$6,700` land price and its 12-phase development table · all 24 pacing rows and 12 guardrail rows (internally) · G3's crunch ratios · all 60 `S_req` cells · all 30 water `base_kw` and 24 `backup_kw` cells · six water worked examples · `M(H)` at six points and the 720-hour cap across three docs · doc 09's 23-transformer power table (row by row, plus both column sums) · doc 09's stability, population, jobs, tax and vacancy arithmetic · doc 11's three-pose frustum geometry and draw-call totals · the `[0,1]` condition rescale across six docs.

**Every one of the nine mandated checks was executed. Four pass cleanly (1 partial, 4, 5, 6, 9); five surface defects (1's audit trail, 2, 3, 7's doc-05 counterpart, 8's row D).**
