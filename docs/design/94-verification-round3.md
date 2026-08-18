# 94 — Round 3 spot-check verification

**Scope:** the four items named for Round 3 re-audit, each **re-derived from first principles** (not read back). Every figure below was recomputed independently and compared against the published text.

**Verdict: PASS.** All four items reproduce. One sub-milli-scale rounding nit is recorded in §5; it changes no ruling and no balance figure, but it can make two doc-06 test tolerances unsatisfiable as literally written.

---

## 1. Doc 03 — the road line at `c_day = 0.35`

### 1.1 The line itself

Re-derived per class from doc 10's inventory and decay rates, at multiplier `1 + 0.75 × 0.35 = 1.2625` (`wx_wear_day = 0`), C-16 pricing `capital × fraction × 0.85 / 24`:

| term | derivation | value |
|---|---|---|
| AVENUE | `540 × 1,040 × 0.0060 × 1.2625 × 0.85 / 24` | **150.66675** |
| STREET | `243 × 360 × 0.0090 × 1.2625 × 0.85 / 24` | **35.203866** |
| `E_roads_repair` | sum | **185.870616 $/gh** |
| floor at `c_day = 0` | `147.22425` | ✓ |
| identity | `147.22425 × 1.2625 = 185.870616` | ✓ exact |
| per developed block | `185.87057 / 9 = 20.652290` | ✓ |

The published `185.87057` is the sum rounded at 5 dp (exact 185.870616); the doc's own §2.12 line prints `150.667 + 35.204 = 185.871`. Consistent.

**Cross-checks in §2.12(f) all reproduce:** mean tile capital `(540×1,040 + 243×360)/783 = 828.9655`; `0.28548 × 828.9655 × 0.85 = 201.16` (doc: $201.1); capital rates `0.0060×1.2625×0.85 = 0.644 %` / `0.0090×1.2625×0.85 = 0.966 %` per gd vs `BUILDING_MAINT_RATE` 0.96 %; 1.00-basis line `753.334 + 176.019 = 929.353` (doc: $929.35), and `929.353 / 1.2625 = 736.12` floor. The `147.22 vs 157.28` like-for-like gap is 6.40 %, and `185.87 / 157.28 = 1.182` (doc: 18.2 % above). All ✓.

### 1.2 The restated net

Revenue `740.291412 + 93 + 3.058 + 3 = 839.349412` (tax `686 × 0.9722 × 1.110 = 686 × 1.079142 = 740.291412` ✓).
Expense `27.44 + 96 + 58 + 74.874 + 57 + 6 + 15.392 + 185.870566 = 520.576566` ✓.
Net `839.349412 − 520.576566 = 318.772846 $/gh` → **+$319/gh**, `× 24 = 7,650.548` → **+$7,650.55/game-day** ✓. Both sides unrounded, as RR-18 requires.

Founding sanity check `1.35200 × 373 − 20.65229 × 9 = 504.296 − 185.871 = 318.425` against 318.773 — the $0.35 / 0.11 % gap the doc records rather than absorbs ✓. `(839.349 − 334.706)/373 = 1.35293`, the re-derivation the doc declines to apply ✓.

### 1.3 Test 43

§7 test 43 asserts **`c_day = 0.35`, multiplier 1.2625, `$185.9 ± 0.5/gh`**, plus the doc-10 test-42 accrual `0.28548` and the `c_day = 0` floor `$147.2 ± 0.5` ✓. `data/economy.json` §8 ships `STARTER_ROAD_C_DAY 0.35`, `STARTER_ROAD_DECAY_MULT 1.2625`, `STARTER_ROAD_REPAIR_PER_HOUR 185.87`, `..._AT_C_DAY_0 147.22`, and `PACING_ROAD_PER_DEVELOPED_BLOCK 16.35825` is listed under `_deleted` ✓. Tests 27–31 re-anchored to the Round-3 rows ✓.

Every surviving `147.22` / `16.35825` occurrence in doc 03 (lines 331, 721, 751, 753, 755, 794, 801, 812–813, 1309, 1456, 1464, 1569, and the RR-2/RR-13 changelog rows) is explicitly labelled as the `c_day = 0` **floor** or as superseded history. No stale live use found.

### 1.4 Pacing table re-run

All 23 rows regenerated from `net_r3 = round(1.35200 × net_r1 − 20.65229 × blocks_developed)`:

- **Every one of the 23 `net $/gh` cells reproduces exactly** (S1 320 … S12 3,994).
- **Every `flow` cell equals `net × gh`** (with S1's +10,000 grant separated).
- **The whole treasury chain reproduces** from a $25,000 opening balance: my running total sits exactly 25,000 below each published `treasury end` at all 23 rows, i.e. the chain `treasury_start + flow + grants − one_off` is internally exact end-to-end (S1 $31,460 … S8 $80,107 … S12 $897,900).
- End state `$897,900` ≈ $898K, net income `3,994 × 24 = $95,856/game-day` ✓.
- RR-13 deltas: `20.65229 − 16.35825 = $4.294`/block ⇒ $38.65/gh at 9 blocks, $55.82/gh at 13 ✓; S1 net 358 → 320 = −10.6 % ✓; S1 treasury −5.2 % ✓; S12 −$74,887 = −7.7 % ✓.
- The `f_happiness = 1.000` sensitivity also reproduces: tax `686 × 0.9722 = 666.93` → 667, gross `765.99`, net `765.99 − 520.58 = 245.41` → +245, `K = (766.0 − 334.706)/373 = 1.15628` ≈ 1.15630 ✓.

### 1.5 Guardrails

| guardrail | re-derived | published | ✓ |
|---|---|---|---|
| G1 peak | S7 `206,147 / 17,952 = 11.483` | 11.48 at S7 (≤ 14) | ✓ |
| G2 floor | S8 `80,107 / 20,856 = 3.841`; S1 `4.096` | 3.84 at S8; S1 4.10 | ✓ |
| G1/G2 table | **all 12 session rows recomputed; every ratio matches to 0.01** | — | ✓ |
| G3 | treasury `271,587 + 69,520 = 341,107`; sum `483,600/341,107 = 1.4177`; min `222,600/341,107 = 0.6526` | 1.418 / 0.653 (≥1.15 / ≥0.45) | ✓ |
| G4 | offline `1,477,566` / online `1,189,870` = `1.24179` | 1.242 ∈ [1.2, 2.0] | ✓ |
| G5 | `25,000 + 10,000 + 14,400 + 53.2 × 356 = 68,339.2` vs `12,400 + 34,588 + 13,000 = 59,988` | $68,339 vs $59,988, margin $8,351 | ✓ |

The G4 offline and online sums were re-added from the table's own 11 away rows and 12 play rows — both totals match to the dollar. **All five hold**, so the claim "no expense constant was retuned" is substantiated: `ROAD_REPAIR_CAPITAL_FRACTION` stays 0.20 and `PACING_ROUND2_K` stays 1.35200, and `data/economy.json`'s `MODEL_*` guardrail keys (11.48 / S7, 3.84 / S8, 1.242, 68,339, and the G3 block) match the prose ✓.

§9 item 15's re-swept band also re-derives exactly: each Round-2 break point ÷ 1.2625 → `0.20→0.1584`, `0.2525→0.2000`, `0.26→0.2059`, `0.30→0.2376`, `0.32→0.2535`; band `[0.10, 0.31] → [0.0792, 0.2455]` ≈ `[0.08, 0.245]`; shipped 0.20 sits at `0.20/0.25347 = 78.9 %` of break (doc: 79 %; Round 2: 62.5 % ≈ 63 %) ✓.

---

## 2. Docs 06 + 07 — the fire channels (RR-15)

### 2.1 `fire_escalation_mult` matches what doc 06 deleted

Doc 07 §2.2 table row and `data/weather.json` §8.1 rows for all six MVP states: `CLEAR 1.00→1.00`, `CLOUDY 1.00→1.00`, `RAIN 0.80→0.80`, `HEAVY_RAIN 0.80→0.80`, `THUNDERSTORM 0.80→0.80`, `HEAT_WAVE 1.25→1.25`. Doc 06 §2.4's adoption table publishes the identical six values as the product `heat_mult × rain_mult` of the deleted inline constants. **Verbatim match, state by state, in prose, table and JSON** ✓. Bands are flat, so the channel is intensity-invariant as ruled ✓.

### 2.2 Doc 06 consumes both channels

- §2.4: `esc_env[structure_fire] = (1 + 0.010·max(0, wind−20)) × f_wx_esc × hydrant_penalty`, `f_wx_esc = weather.get_effect("fire_escalation_mult")`, passed through unclamped ✓. `heat_mult` / `rain_mult` deleted, and recorded in the deleted-key table ✓.
- §2.8: `rate(target)` multiplies `g_weather = weather.get_effect("fire_spread_mult")` ✓.
- §5 interface row lists **six** doc-07 channels with call sites ✓; §2.1 `next_discontinuity_h()` gains the weather-segment breakpoint (h) ✓; §8 carries `fire_weather_channels` as names only, no numbers ✓; tests 41/42/43 enforce site separation, non-substitution and no wind double-count ✓.

### 2.3 §1.1 band and test 23 unchanged

Re-derived through the channel at CLEAR (`f_wx_esc = 1.00`): wind term `1 + 0.010×25 = 1.250`, hydrant `1.000`, `esc_env = 1.250`. Tier ladder `2.2 × {1.00, 1.25, 1.50, 1.75} × 1.25 = 2.750 / 3.4375 / 4.125 / 4.8125 /gh`; times `21.818 / 17.455 / 14.545 / 12.468` gm; **tier 3 at 39.273 gm, tier 5 at 66.286 gm** ✓. §1.1's response band (4–14 / 24.2 / 39.1 gm) and test 23's `39.3 − 39.1 = 0.2 gm` margin are therefore untouched, exactly as both docs claim ✓. `esc_base[structure_fire] = 2.20` unmoved ✓.

### 2.4 Spread worked values, re-derived with the multiplier

Fixed geometry: `g_stage 1.00`, `g_dist = exp(−8/12) = 0.5134171`, `g_density = 1.333333`, `g_mat 1.40`, `P_spread_base 0.30`.

| state · intensity | my `g_wind` | my `g_weather` | my `rate /gh` | my `p` 5-min | my `p` 1 gh | published |
|---|---|---|---|---|---|---|
| CLEAR 0.50 (10.0 kph) | 1.200000 | 1.050000 | **0.362267** | 2.974 % | **30.39 %** | 0.362267 / 2.97 % / 30.4 % ✓ |
| HEAT_WAVE 0.80 (10.2 kph) | 1.204000 | 1.630000 | **0.564251** | 4.593 % | **43.12 %** | 0.564251 / 4.59 % / 43.1 % ✓ |
| THUNDERSTORM 0.3636 (50.0 kph) | 2.000000 | 0.545455 | **0.313651** | 2.580 % | **26.92 %** | 0.313651 / 2.58 % / 26.9 % ✓ |
| THUNDERSTORM 0.77 (72.4 kph) | 2.448000 | 0.484500 | **0.341007** | 2.802 % | **28.89 %** | 0.341007 / 2.80 % / 28.9 % ✓ |

Also verified: pre-weather product at 50 kph `0.575027` (and the recorded 0.5746 → 0.575027 rounding note) ✓; dry-air reference-storm rate `0.703833` with `p_1gh = 50.53 %` ✓; the cut ratio `0.341007 / 0.703833 = 0.48450` = doc 07's `lerp(0.60,0.45,0.77) = 0.4845` ✓; storm escalation cross-check `1.524 × 0.80 = 1.2192` → tier 2 at `60/2.68224 = 22.369` gm ✓; the rejected-substitution arithmetic `0.60/0.80 = 0.750`, `0.45/0.80 = 0.5625` (25.0–43.8 % cut) ✓.

---

## 3. Doc 11 — 16 chunks / 159 calls / +5 delta

Geometry re-derived: `h = 420·sin62° = 370.84`, MEDIUM boundary `sqrt(420² − 370.8²) = 197.25` → 197.3 m ✓. Row far-edge widths from `w(r) = 2·sqrt(r² + 370.8²)·0.64706`: `w(180) = 533.41`, `w(308) = 623.81`, `w(411.9) = 717.22` → `⌈4.1673⌉ / ⌈4.8735⌉ / ⌈5.6033⌉ = 5 / 5 / 6` = **16 chunks** ✓ (pure ceiling, no discretionary rounding). Rows A+B nearest edges 52.1 / 180.0 both < 197.3 ⇒ **10 MEDIUM + 6 FAR + 0 NEAR** ✓.

Draw calls: `10×10 + 6×3 = 118` opaque; `118 + 0 + 10 + 2 + 4 + 25 = 159`; with overlays 165; headroom `(320−165)/320 = 48.4 %` ✓. Band endpoints: 17 → 169 (175), 19 = `6+6+7` → `12×10 + 7×3 = 141 + 41 = 182` (188, 41.25 % headroom) ✓.

Consistency sweep — **159 / 16 appears consistently at every site**:

| site | content | ✓ |
|---|---|---|
| §2.13 headline (L537) | 16 chunks, 10 MEDIUM + 6 FAR | ✓ |
| §2.13 grid-alignment band (L539) | 16 = floor of 16…19, `+3/−0` | ✓ |
| §2.13 budget table (L584) | TOTAL 157 / 215 / **159** | ✓ |
| §2.13 sum line (L589) | `118+0+10+2+4+25 = 159`, 165 with overlays | ✓ |
| §2.13 band table (L596) | 16 → 159 (165) | ✓ |
| §2.13 ordering (L605) | Z0 157 < Z2 159 < Z1 215, 2-call gap | ✓ |
| §2.5 forward ref (L145) | `118 → 48`, 48 % headroom | ✓ |
| §2.13 rejected alternative (L607) | `16·3 = 48` / 89 total / saves 70, surplus `320−159 = 161` | ✓ |
| §2.13 instance check (L609) | 16 × ~30 ≈ 480; 19 ⇒ ~570 | ✓ |
| §7.2 test 19 (L942) | 16, `+3/−0` (16–19), 10 MEDIUM + 6 FAR, **159** (accept 159–182) | ✓ |
| `data/render.json` §8 (L1054–1059) | `_z2_expected_chunks 16`, tiers `{0,10,6}`, `_z2_expected_draw_calls 159`, `..._with_overlays 165`, `_z2_expected_columns_per_row [5,5,6]`, tolerance `plus 3 / minus 0`, derivation text matching | ✓ |
| §9 item 18, 20:9 (L1254) | 21 vs 16 = **+5 chunks**; `3×10 + 2×3 = 36`; `195 − 159 = 36`; `(320−201)/320 = 37 %`; absorbed by 48 % | ✓ |

The 20:9 delta re-derives: columns 6/7/8 ⇒ 13 MEDIUM + 8 FAR ⇒ `130 + 24 + 41 = 195`; extra MEDIUM 3, extra FAR 2 ⇒ +36 calls ✓. The only surviving `17 / 169 / 175` figures are (a) the deliberate mid-band row in the alignment table and (b) changelog rows RR-12 / R-17, each explicitly marked superseded ✓.

---

## 4. One-liners

- **Doc 04 changelog says 74.9.** The C-12 row (L760) is annotated in place with the RR-6 correction — test 24 asserts **`E_grid = $74.9 ± 0.5/gh`** — and the RR-18 row (L790) restates the arithmetic `40.000 + 24.000 + 9.600 + 1.2744 = 74.8744 → $74.9`. Recomputed: `8.00×5.0 + 6.00×4.0 + 2.40×4.0 + 1.416×0.9 = 74.8744` ✓, and $73 is 1.874 outside the `[74.4, 75.4]` band, as stated. The three remaining `$73` occurrences (§2.2 deleted-set, test 24 parenthetical, RR-6 row) all read as explicitly superseded ✓. Doc 03's tolerance is the same `±0.5` ✓ — both docs assert one band.
- **Doc 09 §9 notes marked resolved.** All three cross-doc notes (L1374–1376) are struck through and carry a **RESOLVED** tag with a pointer: doc 04 test 24 → RR-6, doc 04 §2.13's 508 kW → RR-10, doc 05's 8.2 m³/h → RR-11. The section heading itself reads "ALL RESOLVED IN ROUND 2" with an RR-18 disposition line ✓. Open question 7 (L1386) marks its cross-doc half **RESOLVED (RR-6)** and leaves only the overseer's taste call open ✓.

---

## 5. Open issue (minor, precision only)

**`wind_kph` at intensity 0.77 is rounded before use, and two `± 1e-6` tolerances are stated against the rounded value.**

`lerp(30, 85, 0.77) = 72.35`, but docs 06 and 07 both carry it as **72.4** and derive from that:

- doc 06 §2.8 / doc 07 §2.2.1: `g_wind = 1 + 1.2×(72.4/60) = 2.448` → `rate = 0.341007 /gh`. From the exact 72.35: `g_wind = 2.447` → `rate = 0.340938` (Δ 6.9e-5).
- doc 06 §2.4: wind term `1 + 0.010×52.4 = 1.524` → `esc_env = 1.2192`. From 72.35: `1.5235` → `1.2188` (Δ 4e-4).

Both docs use the same rounded figure, so **nothing is inconsistent between them and no balance conclusion moves** (the four-weather ordering, the 48.45 % cut, the 22.37 gm tier-2 time and test 23's margin are all unaffected). The nit is testability: **doc 06 test 42** asserts `THUNDERSTORM 0.77 → rate == 0.341007 ± 1e-6`, which an implementation that computes `wind_kph` from the published `[30, 85]` band at intensity 0.77 will fail by ~69×. Doc 06 test 41 sidesteps this by naming `wind_kph 72.4` as a stub input; test 42 does not. Cheapest fixes: state the stub `wind_kph` in test 42 the way test 41 does, or widen that one expectation to `± 1e-4`. Not a Round-3 regression — the 72.4 rounding predates RR-15.

---

*Method: every figure above was recomputed in a scratch session (double-precision, no figures copied from the docs into the recomputation), then diffed against the published text. Files audited: `03-economy.md`, `04-power-grid.md`, `06-incidents-dispatch.md`, `07-weather-disaster-director.md`, `09-map-land-starter-city.md`, `10-roads-traffic-routing.md`, `11-rendering-performance.md`.*
