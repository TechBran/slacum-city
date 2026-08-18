# 95 — Round 2 Closing Audit of the RR-1…RR-12 Amendment Pass

**Scope:** every one of the 22 defects raised by `96-verification-structural.md` (F-1…F-8, R-1, R-2) and `97-verification-numeric.md` (F-01…F-12), re-checked against the seven amended docs (02, 03, 04, 05, 06, 10, 11) plus their unamended counterparties (07, 09, 12), and a sweep for contradictions the fixes introduced.

**Method.** Every arithmetic claim below was re-derived from the generating formula, not read from a changelog. The full doc-03 ledger, all 24 pacing rows, all 12 guardrail rows, G3/G4/G5, the E_grid/E_water/E_roads_repair derivations, the doc-11 Z2 frustum, doc 06's two moved worked examples and doc 05's component footprints were recomputed independently.

**Verdict: 22 of 22 original findings CLOSED. FAIL on the second half of the mandate — 2 substantive new contradictions and 7 lesser ones were introduced or left by the fix pass.**

---

## 1. Original findings — closure status

| # | ruling | status | evidence |
|---|---|---|---|
| 96 F-1 | RR-1 | **CLOSED** | `grep DistrictDarkChanged` in 04 = 3 hits, in 11 = 6 hits; **all 9 are deletion records, "renamed from" annotations or negative assertions**. Zero live consumption/emission. Doc 11 §2.7.2 (233), §2.7.3 (250), §2.7.5 (327), §4 (819), §5 (837, 839) all read `BlockDarkChanged`; `data/render.json` gains `blackout._carrying_event`; new test 27 asserts nothing subscribes to the old name; the C-38 changelog row's old claim is explicitly deleted. |
| 96 F-2 | RR-10a | **CLOSED** | Doc 04 §9 item 13 now reads "RESOLVED, SATISFIED"; §8 `_reclose_render_coupling` reads "SATISFIED: doc 11 ships 4.50"; the C-40 changelog row is annotated. No doc asks doc 11 to raise the constant. `grep "2.50 s"` = 0 live hits. |
| 96 F-3 / 97 F-10 | RR-10b | **CLOSED** | Doc 04 §2.13 (397) deletes the 508 kW / 15× quote and restates **402.0 kW nameplate, 783.3 kW night peak**, headroom ×19.90 / ×10.21, `SUB-A` at 13.1 %. Re-derived: 8000/402.0 = 19.90 ✔, 8000/783.3 = 10.21 ✔, 783.3/6000 = 13.06 % ✔. The only surviving "508" in 04 is the deletion record. |
| 96 F-4 / 97 F-06 | RR-2 | **CLOSED** | `data/roads.json` carries no price key; doc 10 §2.3/§2.11/§2.12/§4/§5/§8 all point at `data/economy.json → roads`; new doc-10 test 47 mirrors doc 03's test 33. Doc 03 §2.13(d) ships STREET 1,800 / AVENUE 5,200 / upgrade 4,000 / refund 0.25 / `ROAD_REPAIR_CAPITAL_FRACTION` 0.20 and a `roads` block in §8. |
| 96 F-5 / 97 F-05 | RR-11 | **CLOSED** | Doc 05 §2.4, §2.13, §2.14, §8 `_provenance` and new test 30 all carry **5.56 m³/h / 7.2×**; the 8.2/4.9× figure survives only as an explicit withdrawal. `18×0.08 + 3×0.48 + 5×0.13 + 1×0.32 + 0.19 + 0.40 + 0.96 + 0.16 = 5.56` ✔; `40.0/5.56 = 7.194` ✔. |
| 96 F-6 / 97 F-03 | RR-6 | **CLOSED** | Doc 03 §2.12(d): pump O&M `40.0 × 0.35 = 14.000` ✔, treatment `5.56 × 0.06 = 0.334` ✔, mains `1.512 km × 0.7 = 1.058` ✔ → `E_water 15.392` ✔. Mains re-derived from doc 09 §2.9.6: `4 + 51 + 55 + 16 = 126` trunk + `9 × 7 = 63` laterals = 189 tiles × 8 m = **1.512 km** ✔. |
| 96 F-7 | RR-6 | **CLOSED** | Doc 03 §2.12(a): `0.9722 × 1.110 = 1.07914`, `686 × 1.07914 = 740.29` ✔. Re-derived doc 09's factors: `0.25 + 0.75 × 0.9475^0.70 = 0.972218` ✔; `1 + 0.50 × 22/100 = 1.110` ✔. The 0.90 assumption is gone. |
| 96 F-8 / 97 F-11 | RR-7 | **CLOSED** | `REQUIRED_DEMAND_LEVEL_GROWTH: 2.35` deleted; `REQUIRED_MIN_DEMAND_LEVEL_GROWTH: 2.15` + `_EXCLUSIVE: true` shipped; §5 row and §9 item 4 restated as the strict inequality with doc 02 named as authority. |
| 96 R-1 | RR-4 | **CLOSED** | `weather_mults` deleted from doc 06 §8 and `data/incidents.json`, replaced by a name-only `weather_channels` map. The four consumed channel names — `incident_crime_mult`, `fire_ignition_mult`, `incident_utility_mult`, `incident_traffic_mult` — match doc 07 §2.2's published table **exactly**. New tests 38/39/40. |
| 96 R-2 | RR-3 | **CLOSED** | Doc 10 rescales with no carve-out (§2.2 states it explicitly); `condition_hazard_mult = 1 + 0.40·max(0, 0.75 − c)`; doc 06 §2.11 consumes `1.00 / 0.55 / 0.10`. Outputs verified unchanged: 0.55 → 1.08 ✔, 0.10 → 1.26 ✔. No `0..100` road condition survives in 10 or 06. |
| 97 F-01 | RR-5 | **CLOSED** | `TAX_YIELD` demoted to descriptive; rows and the $686 anchor locked; test 7 → `test_base_tax_yield_drift`, ±6 %. Drift table re-derived: store/office −4.76 % ✔, factory +0.48 % ✔, data_center −0.28 % ✔; the anchor-conforming alternative is correctly stated as $698. |
| 97 F-02 | RR-6 | **CLOSED** | `8.00×5.0 + 6.00×4.0 + 2.40×4.0 + 1.416×0.9 = 74.874` ✔ in doc 03 §2.4/§2.12 **and** doc 04 §2.2. Doc 04 test 24 re-based to `13×L1 + 9×L2 + 1×L3 = 2.40 MVA`, `177 tiles = 1.416 km`, `$74.9 ± 0.5`; doc 03 test 37 carries `74.9 ± 1`. Both contain 74.874. |
| 97 F-04 | RR-6 | **CLOSED** | Full ledger restated and re-run. All arithmetic reproduces — see §2 below. |
| 97 F-07 | RR-8 | **CLOSED** | Doc 02 §2.3 publishes the unrounded seeds (`store 0.128`, `high_rise 1.28`, `police_station 0.192`) in prose, in the per-archetype notes and in `§8 seed_rows`; test 2 regenerates from `seed_rows`, never from a printed cell. Re-derived: `0.128 × 2.35² = 0.70688 → 0.71` ✔ vs the cell-based `0.72` ✗. |
| 97 F-08 | RR-8 | **CLOSED** | Doc 02 deletes the "all variants reuse the shell" claim, keeps only the `pump` reference row, and points at doc 05 for the other four; new test 6b asserts `tank L1 == [2,2]`. Doc 05 §8 `components.tank` L1 = `2,2` and `base_kw 5.0` — **unchanged**, and `pump` = `3,3` matches doc 02's shell row exactly. Doc 09's 77-tile total stands. |
| 97 F-09 | RR-9 | **CLOSED** | Report 98 §5 C-43 corrected **in place** (the gloss now reads 3.06 with the RR-9 pointer); doc 02 §2.7/§8/§9 item 9 and test 24 adopt 3.06 and withdraw the 0.474 proposal; doc 06 unchanged, as ruled. |
| 97 F-12 | RR-12 | **CLOSED on substance** | The phantom row D is deleted; rows originate at 52.1 / 180.0 / 308.0 and row D would start at 436.0 > `r_far` 411.8 ✔. Every dependent figure was moved (opaque 133→128, total 174→169, headroom 44→45 %, the rejected-alternative arithmetic, the 20:9 note, test 19's tolerance and its new phantom-row guard). **But the published column count does not re-derive — see N-2.** |

97 F-03, F-05, F-06, F-11 are the doc-97 counterparts of 96 F-6, F-5, F-4, F-8 and close with them. **22/22.**

---

## 2. Re-derivations that pass

**Doc 03's restated ledger (RR-2 + RR-6), from its own lines.**
Revenue `740.29 + 93 + 3.058 + 3 = 839.35`. Expense `27.44 + 96 + 58 + 74.874 + 57 + 6 + 15.392 + 147.224 + 0 = 481.930` ✔ (the doc's own check line). Net `839 − 481.930 = 357.07` → **+357/gh** ✔.

**Road-repair line.** `540 × 1,040 × 0.0060 × 0.85 / 24 = 119.34` ✔; `243 × 360 × 0.0090 × 0.85 / 24 = 27.884` ✔; total **147.224** ✔. `147.224 / 9 = 16.35825` ✔ exactly the shipped `PACING_ROAD_PER_DEVELOPED_BLOCK`. The 1.00-basis counterfactual `596.70 + 139.42 = 736.12` ✔.

**Pacing regeneration.** `K = (839 − 334.706)/373 = 1.35200` ✔, and `334.706 = 481.930 − 147.224` ✔. **All 23 `net_r2` cells reproduce** from `round(1.35200 × net_r1 − 16.35825 × blocks)` (S1 358, S3 471, S6 673, S8 917, S12 4,050 …). **All 24 treasury rows close to the dollar** (S1 `25,000 + 16,110 + 10,000 − 17,940 = 33,170` ✔ … S12 `1,187,787 + 405,000 − 620,000 = 972,787` ✔). Founding sanity check `1.352 × 373 − 147.224 = 357.08` ✔.

**Guardrails.** G1/G2: all 12 `treasury/(net×24)` ratios reproduce; peak **12.548 at S7** ≤ 14 ✔, floor **3.860 at S1** ≥ 1.5 ✔. G3: `382,637` at decision ✔, `483,600/382,637 = 1.2638` ✔, `222,600/382,637 = 0.5818` ✔ — both gates hold. G4: offline `1,523,658` / online `1,218,665` = **1.2503** ✔, inside [1.2, 2.0]. G5: `25,000 + 10,000 + 16,110 + 53.2×395 (21,014) = 72,124` vs `59,988` ✔.

**Doc 06's two moved examples (RR-4).** Fire: `lerp(1.80, 3.00, 0.77) = 2.724` ✔; `0.06891537 + 0.03101192 = 0.09992729 /gh = 2.398/gd` ✔; lift `0.09992729/0.0316242 = 3.160×` ✔. Traffic: dark node `0.0020 × 0.715542 × 3.00 × 1.40 × 1.25 × 1.08 = 0.00811425` ✔ ×8, lit `0.00270475` ✔ ×12 → `0.0973709 /gh = 2.337/gd` ✔, ×3.15 on 0.742 ✔.

**Doc 11's Z2 geometry.** `h 370.84`, `r_near 52.12`, `r_far 411.86`, `s_near 374.44`, `s_far 554.14`, `w_near 484.5`, `w_far 717.1`, area `216,108 m² = 13.19` blocks, MEDIUM boundary `sqrt(38,907) = 197.25` — all reproduce. Draw calls `11·10 + 6·3 = 128`, `+41 = 169`, `(320−175)/320 = 45.3 %` ✔; band endpoints 159 / 182 ✔; 20:9 `6+7+8 = 21 → 154 + 41 = 195`, `(320−201)/320 = 37 %` ✔.

**Doc 05 ↔ doc 02 footprints.** All six variant ladders in `data/water.json` match doc 02 §2.3's restatement digit for digit; `pump` = doc 02's shell row; `tank` L1 = 2×2 / 5.0 kW.

---

## 3. New contradictions introduced by the fix pass

### N-1 — **doc 10 and doc 03 disagree about the operating point of the road-repair line they jointly created** *(severity: medium — the number is 26 % low, or doc 10's claim is false)*

`10 §2.3` publishes the accrual **at `c_day = 0.35`**:

> `540 × 0.0060 × 1.2625 = 4.09050` + `243 × 0.0090 × 1.2625 = 2.76109` = `6.85159 /gd` = **`0.28548 /gh`** … "That accrual is **exactly** the `damage_fraction` throughput doc 03 multiplies through C-16 … to get the starter ledger's road-repair line."

`03 §2.12(f)` derives its line **at `c_day ≈ 0`**:

> "at t0 the core carries `c_day ~ 0` in clear weather, so the multiplier is **1.00** and this line is a FLOOR"

Doc 03's implied accrual is `(540×0.0060 + 243×0.0090)/24 = 0.226125 /gh` — doc 10's own 0.6030/block/gd baseline, **not** the 0.28548 it says doc 03 uses. The two docs also make incompatible factual claims about the starter city's congestion (`c_day = 0.35` "quiet-starter sample point" vs `c_day ~ 0`).

Money: at doc 10's stated operating point the line is `147.22 × 1.2625 = **$185.87/gh**`, net falls `+357 → +318`, `PACING_ROAD_PER_DEVELOPED_BLOCK` moves `16.358 → 20.652`, and every one of the 24 pacing rows and 12 guardrail rows shifts. Doc 03's test 43 (`c_day = 0`, $147.2 ± 0.5) and doc 10's test 42 (`c_day = 0.35`, 0.28548) are each internally fine and jointly assert two different starter cities.

**This is the RR-2 failure mode reproduced inside RR-2's own fix:** one doc supplies a physical input, the other prices it, and neither read the other's operating point.

**Fix owner:** doc 03 and doc 10 must agree one `c_day` for the starter core. If 0.35 is right, §2.12(f), the ledger, `K`, `ROAD_PER_BLOCK` and the whole pacing table move; if 0 is right, doc 10 §2.3's "exactly … doc 03" sentence and its published constant must be restated as a floor plus a sample point.

### N-2 — **doc 11 §2.13's Z2 chunk count is still not reproducible from its own stated formula** *(severity: low-medium — conservative, but it is the same defect class RR-12 was raised to fix)*

The table's column header is `⌈W_far/128⌉` and the widths it prints are correct. Applying that rule:

```
row A  W_far = 533.4  →  533.4/128 = 4.167  →  5      (doc: 5)
row B  W_far = 623.8  →  623.8/128 = 4.874  →  5      (doc: "5–6", takes 6)
row C  W_far = 717.2  →  717.2/128 = 5.603  →  6      (doc: 6)
                                     total   =  16     (doc: 17)
```

The doc's own grid-alignment sentence confirms the ceiling set is `(5+5+6) = 16`, yet the "representative alignment" published is `5 + 6 + 6 = 17` — the ceiling value for rows A and C and the alignment-shifted value for row B, with no stated reason for mixing them. `data/render.json`'s `_z2_derivation` repeats "`→ 5 / 6 / 6`" directly under the same `ceil()` formula. Consistently applied, Z2 is **16 chunks = 10 MEDIUM + 6 FAR = 118 + 41 = 159 calls (165 with overlays)**, not 17 / 169 / 175. The 20:9 note, by contrast, *does* use the pure ceiling rule (6/7/8 = 21), so the two aspect-ratio figures are computed on different conventions and their stated `+4 chunks` delta is really `+5`.

**Non-fatal:** the error is conservative, 16 sits inside test 19's `±2` band, and every §2.13 conclusion survives. But the published headline figure is again a count that does not follow from the published geometry.

---

## 4. Lesser new or surviving inconsistencies

**N-3 — doc 03 test 7's negative case is mis-stated.** "Re-classing `data_center` to `residential` drifts **14.5 %** and fails." Under the test's own formula `|base/(cost × yield) − 1|` it is `|2,100/1,800 − 1| = **16.7 %**`. 14.5 % is `(0.0117 − 0.0100)/0.0117`, a different ratio. The test still fails the mis-classification, so the guard works; the quoted magnitude is wrong.

**N-4 — doc 04's C-12 changelog row is now stale.** It still reads "new test 24 asserts the starter set yields `E_grid = $73/gh`". RR-6 changed test 24 to `$74.9 ± 0.5`. The C-40 row was annotated with its correction; the C-12 row was not. Same shape as the F-2 defect this pass closed.

**N-5 — test 33's "grep-style" wording vs the new ownership-pointer comments.** RR-2 states doc 03's test 33 "then passes as written". Test 33 asserts the literal tokens `build_cost`, `upkeep_per_game_day`, `repair_cost_base` … "appear in **no** file except `data/economy.json`". `data/roads.json` §8 now contains all three tokens inside `_pricing_owner_note`, `_classes_price_note` and `_repair_price_note`; `data/water.json`'s `price_inputs._note` contains `build_cost` as well. Doc 10's mirror test 47 is key-based ("absent at every depth") and passes. Either test 33 must be specified as key-based like test 47, or the pointer notes must not name the tokens.

**N-6 — doc 09 (not amended in Round 2) still flags docs 04 and 05 in the present tense.** §9 "New cross-doc notes" asserts doc 04 test 24 "expects 14 × L1 + 9 × L2 … 0.88 km", doc 04 §2.13 "cites 508 kW … the figure should be restated", and doc 05 §2.13 "quotes 8.2 m³/h". All three are now false — the docs were corrected. Doc 09 §9 open question 7 likewise still says doc 03 "is re-running that whole table under R-04 anyway". Harmless to the sim, misleading to a reader, and it is the reverse-direction instance of the exact leak the verifiers identified.

**N-7 — doc 06 §9 item 10 is an honest new residual, not a contradiction.** Applying RR-4 surfaced two weather-keyed constants the ruling does not reach: §2.4's `esc_env[structure_fire]` `heat_mult 1.25` / `rain_mult 0.80`, and §2.8 not consuming doc 07's `fire_spread_mult` (a channel doc 07 publishes that nothing reads). Doc 06 changed nothing and requested a ruling, with the downstream cost stated (25–44 % escalation change, test 23's 39.1 gm vs 39.3 gm invariant would need re-deriving). This is R-1's shape one level down and should be ruled in Round 3.

**N-8 — arithmetic nits in doc 03's new text.** (a) The ledger's own check line computes net from the *rounded* revenue: `839 − 481.930 = 357.07`, while the exact lines give `839.349 − 481.930 = 357.42`; both round to +357. (b) The per-district refinement's alternative `K` is quoted as **1.36285**; re-derived from its own $744.34 it is **1.36378**. (c) Doc 03 test 37 uses `74.9 ± 1` while doc 04 test 24 uses `74.9 ± 0.5`, though doc 03 says both "carry the same expectation".

**N-9 — an arguable double-charge the RR-6 re-derivation makes visible.** §2.12(b) excludes `PLANT-1` and `SUB-A` from departments because "their recurring cost is `E_grid`'s `PLANT_OM_PER_MW_HOUR` and `GRID_MAINT_PER_MW_HOUR`, and billing them here as well is precisely the double-charge C-08 removed" — but keeps `water_works 20` while `E_water` bills that same facility's treatment, mains and pump O&M ($15.39/gh). The `station_upkeep_l1` table predates this pass, so this is not newly created; the new justification simply makes the asymmetry explicit. Either the water works line is staffing-only (say so), or it is the same double-charge.

---

## 5. Pattern

Round 1's failure mode was *"the doc that owns a number amended it; the doc that quotes it did not."* Round 2 fixed all ten instances of that — and then produced **one new instance of it inside the fix itself** (N-1: doc 10 authored the accrual, doc 03 priced a different one, each citing RR-2), plus **one new instance of the "count not derivable from the stated geometry" defect** (N-2) inside the ruling that existed to remove exactly that defect from the same table.

The verifiers' two proposed guards would have caught both: a quoted-number registry (`⟨owner: doc NN §X⟩`, which doc 05 adopted and no other doc did) kills N-1; a "regenerate every published count from its stated formula" test kills N-2. Doc 05 §9 item 15 is the only doc that adopted the remedy. **Recommendation: make the `⟨owner⟩` tag mandatory across docs 01–13 before Milestone 1, and require that any table with a stated generating formula ship a regeneration test — doc 02's test 2 and doc 11's test 19 are the models.**
