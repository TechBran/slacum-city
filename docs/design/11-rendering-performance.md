# 11 — Rendering Architecture & Performance (Godot 4.7.2 Mobile / Vulkan / Android)

**Status:** Amended per `98-consistency-report.md` (binding), **including the §14 ROUND 2 rulings RR-1 and RR-12**. Complies with `00-constitution.md` (LOCKED).
**Owns:** `game/` scene layer, `game/audio/` (Phase 2, per report G-3), `tools/gen_graybox.gd`, `data/render.json`, `data/building_shapes.json`.
**Owns in `data/render.json`:** the camera **projection** constants (`fov_deg 40`, `near 1`, `far 1600`), the camera **range** endpoints ruled by doc 12 (`D_MIN 18`, `D_MAX 420`, pitch `34°→62°`), the LOD bands, and `occupancy_hour_curve` per building family (report C-63, C-66). `data/ui.json` *references* these rows and does not restate them.
**Does not own:** any `sim/` code; doc 12 (UI/UX) owns overlay *content* and all camera *input/state* mapping, this doc owns the overlay *mechanism* and the camera *node, projection, culling and LOD*.

> **Ruling Zero (report 98 §0) is applied throughout: the on-disk filenames in `docs/design/` are the canonical doc numbers, and there is no other map.** The numbering this doc writes against is therefore: **01** time & ticks, **02** buildings/upgrades/construction, **03** economy, **04** electrical grid, **05** water, **06** incidents, dispatch & fleets, **07** weather & Disaster Director, **08** persistence, offline & notifications, **09** map, land, districts, **population & stability**, starter city, **10** roads, routing & traffic, **11** this doc (rendering & performance), **12** UI/UX, camera input & onboarding, **13** Android integration & export. Every cross-reference in §5 also names the system in words. Former §9 conflict 10 is closed by this ruling.

---

## 1. Overview & Goals

The renderer is the **evidence layer** for the simulation. Constitution Core Rule 14: *the city must look good during normal operation and spectacular during failure.* Everything here exists to make cascading infrastructure failure legible at a glance on a 6-inch landscape screen.

Three jobs, in priority order:

1. **The blackout read.** A block losing power is visible within ~1 s from any zoom, with no overlay open. Restoring it is the most satisfying visual event in the game (spec §24.2). This drives most of the architecture below.
2. **The alive read.** Traffic, cranes, emergency light bars crossing the city, weather, and a day rotating into night every 24 real minutes (constitution §4). Never a static diorama.
3. **The budget.** 60 FPS on a Pixel 6, 30 FPS on a Snapdragon 695, surviving a 20-minute session without thermal throttle-down. Jobs 1 and 2 are subordinate to job 3 except where §2.13's governor explicitly protects them.

**Inherited constraints.** Constitution §3: `sim/` is RefCounted-only, so the renderer *pulls* — it consumes a per-tick event batch plus a queryable snapshot, never hands a Node inward, never mutates sim state. §4: SimTick = 0.25 s, so everything that moves interpolates. §6: chunk == land block == 16×16 tiles == 128 m; there is no separate render grid. §11: placeholder art is procedural gray-box with emissive windows, readable by archetype and level from silhouette alone (§2.14 makes that testable). §2: Mobile (Vulkan) removes SSAO, SSIL, SSR, SDFGI and volumetric fog from the toolbox; every atmosphere effect below is chosen because Mobile supports it.

**Non-goals:** photorealism, real-time GI, per-window geometry, per-building dynamic lights, shadow-casting point lights, individual pedestrians, lightning bolt geometry in MVP.

---

## 2. Mechanics

### 2.1 Scene architecture

```
Main (Node)                                    game/main.tscn
├── SimHost (Node)                             owns Sim, ticks at 0.25 s, never rendered
├── RenderBridge (Node)                        sim events -> render mutations (§2.3)
├── World (Node3D)
│   ├── WorldEnvironment                       sky / fog / glow / tonemap (§2.8)
│   ├── Sun (DirectionalLight3D)               the only shadow caster in the game
│   ├── Moon (DirectionalLight3D)              Balanced+High only, no shadows
│   ├── ChunkRoot -> Chunk_<bx>_<by> (ChunkView) × N
│   ├── LightPool (Node3D)                     pooled OmniLight3D (§2.10)
│   ├── VehicleRoot                            CivMM_car/van/truck, CivMM_headlights,
│   │                                          EmergencyPool -> VehicleView × N (§2.12)
│   ├── WeatherRoot                            Rain / Splash / Snow (GPUParticles3D) (§2.9)
│   ├── OverlayRoot (Node3D)                   ImmediateMesh network lines (§2.11)
│   └── CameraRig -> Camera3D (§2.5)
└── UILayer (CanvasLayer)                      doc 12
```

`ChunkView`, one per land block:

```
Chunk_<bx>_<by> (ChunkView)
├── Ground   (MeshInstance3D)  128×128 m, 8×8 quads, 2 surfaces: terrain + roads
├── Water    (MultiMeshInstance3D)  8 m quads on the block's water tiles, one shared
│                                   material (§2.1.1) — absent on a dry block
├── Buildings
│   ├── MM_<archetype>_<level> (MultiMeshInstance3D)  NEAR/MEDIUM only
│   └── MM_far                 (MultiMeshInstance3D)  FAR only, one for the whole chunk
└── Props: MM_pole, MM_lamp, MM_pool, MM_wetsmear (MultiMeshInstance3D)
```

`MM_blob` — §2.11's per-building contact shadow — used to be listed here, one per
chunk. **It is ONE node for the whole city and it is a child of `CityView`, not of
a chunk** (shipped 2026-09-01, report 98 RR-96): it has no per-chunk state worth
culling on, and per-chunk buckets measured 36 draw calls at Z0 on the benchmark
city against Performance's 180-call budget. §2.11 has the argument and the A/B.

**Rule: LOD is per chunk, not per building.** A chunk is 128 m; the narrowest LOD band is 150 m. Per-building LOD would triple MultiMesh count for no visible gain. This single decision is what keeps draw calls tractable (§2.13 worked example).

#### 2.1.1 Water (`game/shaders/water.gdshader`, `GroundSurface.water()`)

The third ground surface, and the only one that moves. **One material for every water quad in the city**, because the wave field is evaluated in **world space**: adjacent 8 m tiles are one body of water with the pattern crossing their seams, and driving it off UV instead would restart the noise at every quad and read as tiling. Constants are `water_surface` in `data/render.json`.

Two scrolling value-noise octaves at different scales, speeds and headings (7.5 m / 0.035 and 2.6 m / 0.11, crossing), their finite-difference gradients perturbing `NORMAL` so the specular highlight crawls; a fresnel-weighted lift toward `sky_color` at grazing angles; `sc_night` darkening the body to 0.34; a crest-power sparkle on the swell. `sc_wetness` roughens it into chop and kills the glare — the rain read everyone knows and nobody can name. `sc_overlay_mode` greys it back with every other surface, or an overlay leaves one glowing blue rectangle in a desaturated city.

**No reflection probe, at any preset.** §2.11 gates the ONE probe the game may own to High and to the city at large, and that probe is already flagged for on-device validation (§9). Water that needs a second one cannot ship on the mobile presets. The sky read is the fresnel term, which costs one dot product and lands within a few percent of a probe for a flat horizontal surface under a gradient sky at the camera's 34°–62° pitch band.

**Nothing animates on the CPU.** `sc_time` is already published for the window flicker; the water reads it. A `MultiMeshInstance3D` of water quads is touched once, at build time.

#### 2.1.2 The street (`game/render/road_surface_view.gd`, `road_surface.gdshader`, `sidewalk.gdshader`) — **shipped 2026-08-20**

Roads were one MultiMesh of untextured 8 m slabs. The playtest verdict on the Fold was exact and is worth quoting, because every decision below answers a clause of it: *"more like a real street, two lanes, black asphalt, yellow dividing line in the middle, a sidewalk. The street lights need to be in real places, on the side of the streets — they just look like sticks popping out of the ground."*

**Two draw calls, city-wide.** `MM_road_asphalt` (one 8 m slab per road tile, 12 tris) and `MM_sidewalk` (kerb runs and corner squares, unit boxes scaled per instance). Deliberately NOT per-chunk, which is the convention everywhere else in this doc: the world is 7×7 chunks, road runs along every chunk boundary so all 49 hold some, and at Z2 every one is on screen — per-chunk buckets would be **98 calls against 71 of headroom**. Measured on the benchmark city, Z2 Balanced: **194 → 195** (`dc+ui` 219 → 220 of 320). The vertex bill instead: **+20,490 primitives at Z2, +8,696 at Z0**, and the whole road layer of the founding city is 9,396 asphalt triangles + 1,836 footway triangles.

**Everything painted is a fragment, not a mesh.** Centre lines, lane dividers, edge lines, zebra crossings, tile seams, wheel-path polish, patch mottle and kerb grime are all computed in `road_surface.gdshader` from **world metres**, so a dash phase crosses a tile boundary with no seam to align and a 15 cm line stays 15 cm at Z0 and antialiases itself at Z2 through `fwidth`. `dashes()` carries an explicit band limit — past Nyquist it fades to the pattern's duty cycle, because a `fract()` sampled sub-period crawls. **Corrected 2026-08-20 (§2.13's Fold pass): that term is what keeps the CROSSINGS still, not the lane lines.** Measured against §2.5's own Z2 geometry, the ground footprint at that pose is 0.245 m/px at the bottom of the frame and 0.535 m/px at the top, so the 8 m lane dash and the 6 m centre dash are sampled at 33→15 and 24→11 pixels per period — 5× to 16× above Nyquist, held still by `band()`'s smoothstep, with the band limit contributing 5–23 %. The pattern that genuinely needs it is the **0.85 m crosswalk ladder**, at 3.5→1.6 px per period, where the mix correctly reaches 1.0. The claim that the lane lines would shimmer without the band limit is retired; the fragment ladder in §2.13 also prices what the whole file costs.

**The fragment ladder.** `road_surface.gdshader` carries a `detail` uniform — 2 everything, 1 drops the wear terms, 0 also drops the four-leg zebra loop — authored as `road_surface.detail` with a `presets.*.road_detail` ceiling per tier. It is a device escape hatch and NOT a governor rung; §2.13 has the measurement (the zebra loop alone was 2.4× every wear term put together) and the ruling.

**The junction early-out (2026-08-20, RR-42).** That zebra loop ran on **every carriageway tile** and painted on junction tiles only. It now early-outs on `cw_mask`, which is already in the per-instance `.b` channel — and because `v_pack` is `flat`, the test is constant across a primitive and a derivative quad never spans two primitives, so `detail >= 1 && cw_mask > 0.5` is **quad-uniform**: taking `fwidth()` inside it is legal for exactly the reason taking it inside a `detail` branch is. The eight `fwidth()` calls inside the loop are also four, because legs 0/2 and 1/3 differ only in the sign of their perpendicular coordinate and `fwidth(-x) == fwidth(x)` bit-for-bit. **The loop's cost falls 61–69 %**, byte-identical at Z0; §2.13 has the arms and the rejected further step.

**Per-instance contract** (roads are their own bucket; §2.6's stride-448 packing is the BUILDING bucket's and does not apply):

| channel | meaning |
|---|---|
| `.r` | neighbour mask, N=1 E=2 S=4 W=8, from the road GRAPH's tile membership |
| `.g` | kerb mask, same bits: which sides carry a footway (also the gutter/edge-line mask) |
| `.b` | `cls + 2·pair + 16·crosswalk_mask` — see below |
| `.a` | per-tile wear seed on [0,1), a **hash of the tile**, never a stream draw |

**Why the graph and not the tile grid.** Three reads come out wrong from per-tile guesswork:

* **Class** is the graph EDGE's (`RoadGraph._edge_class`, the slowest class on the segment), not the tile's, so the line painted is the class the router charges for.
* **Junctions.** No centre line crosses a junction box, and a zebra is painted on a leg only when the tile it leads to is *not* itself a junction — which is what stops a 2×2 avenue crossing painting four ladders of white bars into its own middle.
* **Dual carriageways.** `data/starter_city.json` lays Slacum Ave down as **x = 15 AND x = 16**: 336 of the founding city's 783 road tiles are one half of a two-tile avenue. A naive degree test calls every one of them a junction and the city loses every centre line it has. `_pair_of` resolves the twin first — the corridor runs through on an axis, exactly one lateral neighbour is road of the same class, and that neighbour runs through too — and each half then paints its own footway on the OUTER side, one solid yellow just inside the shared edge (the two halves together are the double yellow), a dashed white divider between its two same-direction lanes, and a white edge line at its kerb.
  * Measured, and load-bearing: the class test applies to the LATERAL neighbour only, never along the corridor. `StarterCityLoader` stamps its road list in order and the last writer wins, so every avenue-meets-street crossing tile ends up classed STREET; with a class test along the corridor too, that one mis-classed tile broke the pairing of the avenue tile either side of it, turning them into junction boxes and painting zebras across a through carriageway — **sixteen times over in the founding city.**

**Geometry, in metres.** Tile 8.0; carriageway top y = **0.10** (unchanged — `VehicleView.DEF_ROAD_TOP_M` and the traffic overlay's 0.16 both key off it); kerb 0.15, so the footway walks at y = 0.25. A street spends 2 × 1.40 m on footway and 5.20 m on two 2.60 m lanes; a single-tile avenue 2 × 1.05 m and two 2.95 m lanes; a two-tile avenue half carries 1.05 m outside and 6.95 m of carriageway (two 3.475 m lanes).

**Footways merge into runs.** A tile emits at most four strips and four corner squares; strips abutting along the same kerb line are welded into one instance, so a 20-tile avenue kerb is ONE box. Founding city: **153 instances for 783 road tiles** (149 strips + 4 corner squares) where the unmerged form is ~1,500. Where two kerbed sides of one tile meet, both strips give up `w` and a `w × w` corner square fills the gap — so nothing overlaps, no two footway tops are coplanar, and there is no z-fighting to tune away (`tests/test_road_surface.gd` test 07 asserts it exhaustively).

**Zero new texture memory.** Both shaders sample the existing generated `ground_asphalt` / `ground_pavement` pages through `load()`, which is resource-cached, so they share the textures `GroundSurface` already has resident. Everything else — wear, patches, seams, wheel paths, joints, and every line of paint — is procedural.

**Night** (report NIGHT-1, unchanged calibration): the carriageway inherits the ROAD row of `data/render.json.ground` verbatim (`road_night_albedo_lift` 0.34, `road_night_glow` 0.048, `night_glow_wet_mult` 0.55). The footway takes its own row between terrain and road (0.30 / 0.042) and just under the road's on purpose. Matching the terrain leaves a black gap either side of a lit carriageway — measured at the first draft's 0.22 / 0.030, where the footway read darker than the lot behind it at 03:00. Matching the road erases the kerb line, which is the edge this whole pass exists to draw. **The gap between the two is the read.** Paint takes a third: `marking_night_glow` 0.075, which is the **retroreflective** read, and at 03:00 it is the strongest single cue that a dark band is a STREET.

**The carriageway tint is an A/B ARM now, and the ruling it feeds is DEVICE-GATED and NOT TAKEN** (arm 2026-09-01, re-measured 2026-09-02; report 98 RR-97, doc 93 §X3). `RoadSurfaceView.set_tint_gain(k)` multiplies the authored `tint` `#57575F` in LINEAR and re-encodes, so `k` is an exposure step rather than a hex nudge; `k = 1.0` is byte-identical to the shipped street and is the default on every path. Nothing in `sim/`, no preset, no governor rung and no settings row touches it. It exists because §2.17b's street-body blob shadow measures near-invisible **on the carriageway** and the alpha is not the lever.

**Re-measured, and the first table this section carried is replaced rather than kept beside it.** Bench city, High, `--focus=52,44`, 1920 × 1080, `k = 1.0` vs `k = 1.5` — which is `(0.3412, 0.3412, 0.3725)` → `(0.4141, 0.4141, 0.4512)`, a **+21.4 %** lift of the authored triple:

| pose / hour | carriageway in frame | rendered luma, `1.0 → 1.5` | peak pixel move |
|---|---|---|---|
| Z1, hour 13 | 398,686 px (19.2 % of frame) | 72.84 → 75.07, **+3.1 %** | 8/255 |
| Z2, hour 13 | 158,850 px (7.7 %) | 107.78 → 109.04, **+1.2 %** | 5/255 |
| Z1, hour 21 | 36,347 px (1.8 %) | 38.83 → 40.22, **+3.6 %** | 5/255 |
| Z2, hour 21 | 24,787 px (1.2 %) | 36.46 → 37.37, **+2.5 %** | 6/255 |

**Two corrections to what this section used to say, both of which change the question a device session is being sent to answer.**

1. **There is no day/night asymmetry.** This section claimed the tint moves the road by 17 % by day and "buys nothing at all" at night, on the theory that after dark the road's value belongs to `road_night_albedo_lift` and `road_night_glow` in the `ground` block. Measured at Z1 the night arm moves the road **more** than the day arm (+3.6 % against +3.1 %). The theory was reasonable and it is not what the frames do.
2. **The lever has far less authority than "the lever with authority" implies.** A +21.4 % lift of the authored tint moves the rendered carriageway by **at most 8 grey levels anywhere**, and the §2.17b blob needs a change of order 15/255 on a 73-luma road to become legible. The response is near-linear and was measured, not extrapolated: `k = 1.0 → 3.0` at Z1 by day gives 73.55 → 81.96 luma, a slope of **+4.21 luma per unit of `k`** (the `1.0 → 1.5` arm gives +4.46, agreeing). **Reaching 15/255 therefore takes `k ≈ 4.6`** — an authored tint near `(0.68, 0.68, 0.73)`. That is not a tint adjustment; that is a different, pale-grey road, and it is a whole-scene look decision of exactly the kind §X3 says a render branch does not get to make.

> **AND THE ARM ITSELF HAD TO BE CHECKED, which is §X3 recursing one level.** The first re-measurement of this table was taken at Z0, `--focus=52,44`, and moved **zero pixels at `k = 4.0`** — three shots at `k` = 1.0, 1.5 and 4.0 were byte-identical (`md5sum`). The arm was not broken: **that pose has no carriageway in it at all**, and a null result from a frame with none of the thing under test in it looks exactly like a null result from a lever with no authority. What caught it was making the harness print the uniform **read back off the live `ShaderMaterial`** (`RoadSurfaceView.live_tint_color()`) beside the value the arithmetic wanted — the same "read back off the live object, not off the resolver" rule §2.13b's `QUALITY` line follows, for the same reason. `profile_frame`'s `ROAD TINT` line now prints both and flags them when they disagree.

**The exact commands, both ends.** Desktop, the pair the table above was measured from:

```bash
# The two arms. Identical but for K. Z1/Z2 rather than Z0: the Z0 pose at this
# focus contains no carriageway, and an arm measured there returns zero.
for K in 1.0 1.5; do
  ~/.local/bin/godot --path "/home/bbx/Slacum City game" \
    -s res://tools/profile_frame.gd -- --preset=high --poses=z1,z2 \
    --hour=13 --focus=52,44 --warmup=15 --frames=20 --road-tint=$K \
    --shots=/tmp/rt_d$K
done
# …and the same two at --hour=21, which this section used to say the tint
# could not reach. It reaches it: +3.6 % at Z1 against +3.1 % by day.
```

Device (the Fold, where the look decision actually belongs — a 6.2 mm-per-degree
cover screen at arm's length is not a 27" monitor). `game/main.gd` already has
the branch shape for this in `_apply_render_ab_args`, beside `--road-detail=`
and `--pad-shadows=`; **the one-line snippet is in the Wave-17 branch report**:

```bash
adb shell am start -n com.slacum.city/com.godot.game.GodotApp \
  --es args "--preset=balanced --zoom=0.0 --road-tint=1.5"
```

**What a session has to answer, and it is not "is the shadow more visible".** It
is: *does a street one step lighter still read as ASPHALT at Z0, and does the
night street still read as a lit band against a dark lot?* If either answer is
no, the shadow keeps its 15/255 and the question moves to a per-surface
`body_alpha`, which is a different change in a different file.

#### 2.1.2a `rebuild()` is a dirty-tile diff — **shipped 2026-08-20** (closes §2.1.2's open question 2)

The pass above shipped as a pure function of (grid, graph): every call re-classified all 3,132 road tiles of the benchmark city, re-bucketed every kerb run and rewrote both buffers, for **18.3 ms** — and it fires on **every road the player lays**, which is precisely the frame that must not be dropped. Another branch this wave is shipping a road-drawing tool, so a per-tile drag is now the common case and not the exotic one.

`rebuild()` is therefore a **stateful diff** with one contract, and the contract is exact: *after any sequence of edits, both uploaded buffers are byte-identical to a from-scratch rebuild of the same city.* `force` restores the pure-function behaviour and is what a sim swap (a mid-session load) takes.

**Every per-tile fact has a bounded dependency radius, and the diff IS that arithmetic:**

| fact | reads |
|---|---|
| `mask` / `kerb` | `is_road` at r1 |
| `pair` | `is_road` at r2 (the twin's own through-test), `cls` at r1 |
| `junction` | `pair` + degree, so r2 / r1 |
| crosswalk mask | `junction` at r1, so **r3** / r2 |

Manhattan **r = 3** covers everything a single-tile change can move, and the seeds are the tiles whose MEMBERSHIP or CLASS moved. One edit on the benchmark city re-classifies **12 tiles of 3,132**.

**Why the seeds are read off the graph and not off `road_graph_changed`'s `added_edges` / `removed_edges`, which is what the open question proposed.** Two independent reasons, both measured rather than argued:

* `RoadGraph.apply_edits` **excludes from `added_edges` any edge it deleted and recreated with the same id and tile list** — its own §2.5 edge-id stability rule. An upgrade in place is exactly that case.
* A tile that belongs to more than one edge — every junction box — takes its class from the **grid**, and no edge delta can report a grid-class change at all. `tests/test_road_incremental.gd` test 04 stands a solid 5×5 of street, upgrades the middle tile, and asserts that `apply_edits` returns two empty lists while the tile's class channel moves.

So the diff pays an O(N) floor of two sweeps — membership by pass-stamp, then class — and does everything else dirty-only.

**Measured by `tools/profile_road_rebuild.gd`, debug headless, best of 15, one tile laid on a settled city:**

| | founding city (783 road tiles) | benchmark city (3,132) |
|---|---|---|
| full pass (`force`, and the boot path) | 4.76 ms | 19.7 ms |
| **incremental pass** | **1.18 ms** | **4.87 ms** |
| a 10-tile drag, one rebuild per tile | 12.4 ms total (1.24 ms/tile) | 49.9 ms total (4.99 ms/tile) |

**4.0× on both cities**, and the picture is unchanged to the instance: 3,132 asphalt tiles, **576 footway runs**, 469 lamps on the benchmark city before and after.

Two things fell out of the measurement and are worth recording because they are not in this doc's own code:

* **`RoadGraph._sorted_tiles` was the largest single term.** It is `sort_custom` with a GDScript lambda, so every comparison is a scripted call: **3.44 ms** for 3,132 tiles once a few edits have shuffled the dictionary's key order (0.99 ms straight after a boot, when the keys are already in order — which is why it never looked expensive). A tile's (y, x) order is exactly the order of `y·SIZE + x`, so the comparison now goes to `PackedInt32Array.sort()`: **0.29 ms**, ordering identical by construction, with an out-of-bounds fallback to the comparator because `apply_edits` sorts a caller-supplied edit list. It is called four times a tick inside `sim/roads/` as well.
* **`road_tiles_sorted()` is memoised on `graph_version`**, which is an exact key: `_road_tiles` is written in exactly two places and both bump the version before returning. Callers still get a copy.

Both are hash-neutral and proved so on both cities (report RR-31).

**The footway buckets are kept, not rebuilt.** A bucket is `(axis, fixed_z_or_x, width)` and holds `{tile: [lo, hi]}` rather than a bare span list, which is what lets one tile's contribution be pulled back out; a tile can reach a given bucket at most once (its N and S strips sit `TILE_M − w` apart), so nothing is lost by keying on it. Only the buckets a dirty tile touches are re-sorted and re-merged. Merging by `lo` is what makes the result independent of insertion order — and therefore makes an incremental pass and a from-scratch pass agree float for float.

**The road layer uploads through one `MultiMesh.buffer` write per layer, and it is the only layer in this renderer that does.** Not for speed — packing 3,132 rows in GDScript costs ~0.1 ms more than the per-instance setters — but for the CONTRACT: the `PackedFloat32Array` this view keeps between passes *is* what the server holds, so `tests/test_road_incremental.gd` compares an incremental pass against a from-scratch one **byte for byte** on a `--headless` run, where the server itself reads back nothing (the DUMMY driver stores no instance data and `MultiMesh.buffer` comes back empty). The stride is verified against the engine rather than assumed: TRANSFORM_3D is twelve floats — basis **rows** interleaved with the origin — then four for `use_colors`, then four for `use_custom_data`. Asphalt is stride 16, the footway 12.

The property tests are the deliverable, not the decoration: **40 random edit sequences × 12 edits on a grid city, 24 × 10 against water and the map edge, and the founding city under a ten-tile drag**, every intermediate state compared.

### 2.2 Chunk lifecycle and slot allocation

States `UNLOADED → SIM_ONLY → FAR → MEDIUM → NEAR` and back. `SIM_ONLY` = sim owns the block, zero scene nodes. Promotion to `FAR` builds the `ChunkView`, ground mesh, `MM_far`, `MM_lamp`; promotion to `MEDIUM`/`NEAR` allocates per-archetype MultiMeshes and props.

**Streaming budget:** `chunk_builds_per_frame = 2`; a build exceeding `chunk_build_ms_budget = 3.0` ms yields and resumes next frame at the same building index. Teardown 1 chunk/frame.

**Build procedure.** (1) `views = sim.query_buildings_in_block(bx, by)`. (2) Bucket by `(archetype_id, level)`; per bucket allocate a `MultiMeshInstance3D` with `instance_count = ceil(n/32)*32`, `use_custom_data = true`, `transform_format = TRANSFORM_3D`, `mesh = MeshLibraryCache.get(archetype, level, tier)`. (3) Fill a local `PackedFloat32Array` mirror, **stride 16 floats** (12 transform + 4 custom), and assign `multimesh.buffer = mirror` in one call. (4) Set `visible_instance_count = n`.

**Slot allocation.** Each bucket keeps `free_slots: Array[int]` and `slot_owner: Array[int]`. On removal, copy the last live slot's 16 floats over the freed slot, patch `slot_owner`, decrement `visible_instance_count` — O(1), no holes. Growth reallocates to the next multiple of 32 and re-uploads. `max_instances_per_bucket = 256` is an assertion (a 16×16-tile block cannot physically hold 256 of one archetype/level), not a policy.

### 2.3 Sim → render data flow

```
[sim tick @ 4 Hz]                        [render frame @ 30–60 Hz]
Sim.tick() -> SimEventBatch              RenderBridge._process(delta)
RenderBridge.on_sim_tick(batch, snap)      ├ alpha = clamp(accum / 0.25, 0, 1)
  └ model.apply_event(e) for each e        ├ model.advance(delta)   ← emissive ramps, LOD hysteresis
  └ marks dirty (chunk, bucket) pairs      ├ interpolate vehicles (alpha)
                                           ├ write global shader params (§2.4)
                                           └ flush dirty MultiMesh buffers (budgeted)
```

`RenderStateModel` is a **`RefCounted` with no Node dependency** (`game/render/render_state_model.gd`). It holds all per-building bookkeeping and all arithmetic in this section; `RenderBridge` and `ChunkView` are thin Node shells over it. Deliberate: it makes ~90% of rendering logic headless-testable (§7).

Per-building record `BuildingRenderRec`: `chunk: Vector2i`, `bucket_key: int`, `slot: int`, `emissive_cur: float`, `emissive_target: float`, `emissive_delay: float`, `damage: float`, `variant: int = hash(id) & 15`, `anim_phase: float = hash(id >> 4) / 65535.0`, `stage: int`, `overlay_state: int`.

**Flush budget** `multimesh_instance_writes_per_frame = 2000`, dirty chunks drained in ascending distance order, overflow carried to next frame. A chunk with ≥ 8 dirty instances uploads whole via `multimesh.buffer =`; with < 8, via `set_instance_custom_data` (fewer bytes across the RenderingServer boundary). Buildings actively animating are capped at `max_animating_buildings = 1200`; the remainder snap to target.

**No polling.** The bridge never walks all buildings per tick. Full resync happens only on save load, chunk build, and preset change.

### 2.4 Global shader parameters

Declared in Project Settings → `shader_globals`, written once per frame via `RenderingServer.global_shader_parameter_set`.

| name | type | range | driver |
|---|---|---|---|
| `sc_night` | float | 0–1 | day/night curve (§2.8); 0 = full day |
| `sc_time` | float | 0–3600 s, wraps | render clock; flicker, strobe, UV scroll |
| `sc_wetness` | float | 0–1 | weather integrator (§2.9) |
| `sc_lightning` | float | 0–1 | lightning envelope (§2.9) |
| `sc_wind` | vec2 | m/s | doc 07 |
| `sc_overlay_mode` | int | 0–6 | doc 12; 0 = none |
| `sc_overlay_colors` | vec4[4] | — | normal/warning/critical/failed (spec §13.5) |
| `sc_fog_tint` | vec3 | — | day/night curve |

### 2.5 Camera and LOD bands

Camera rig: pivot `Node3D` at a ground focus point, `Camera3D` at `(0, D·sin p, D·cos p)` rotated by yaw. **Projection is this doc's** (report C-63): FOV **40°** vertical, near **1.0**, far **1600**. **The interaction range is doc 12's** (report C-63) and is restated here only because both halves live in one file, `data/render.json`:

```
D(t)     = D_MIN · (D_MAX / D_MIN)^t          D_MIN = 18 m, D_MAX = 420 m, t ∈ [0,1]
pitch(t) = 34° + 28° · smoothstep(0, 1, t)    34° up close, 62° top-down far
```

Doc 12 owns `t`, the gesture mapping, `D_MAX_eff`, yaw and all input damping — this doc reads the resulting `{focus, zoom_t, yaw}` struct and derives the transform. *(The former `yaw_snap_deg`, `pan_damping` and `zoom_damping` rows are deleted from `data/render.json`; rotation snapping and input damping are doc 12's `rotation_mode` / gesture constants in `data/ui.json`.)*

Three reference poses, used by every worked example and by test 19:

| zoom | t | D | pitch | camera height `D·sin p` | use |
|---|---|---|---|---|---|
| Z0 (max in) | 0.00 | 18 m | 34° | 10.1 m | building inspection, construction detail |
| Z1 (mid) | 0.50 | 86.9 m | 48° | 64.6 m | neighbourhood operation; **the sizing pose** |
| Z2 (max out) | 1.00 | 420 m | 62° | 370.8 m | city overview / skyline |

`D(0.5) = 18 · √(420/18) = 18 · 4.8305 = 86.9 m`; `pitch(0.5) = 34 + 28·0.5 = 48°` (smoothstep(0.5) = 0.5). These reproduce doc 12 §2.16's worked example exactly.

**LOD distance `d` = camera position to the nearest point on the chunk's *ground-plane* AABB** — the 128 × 128 m footprint at `y = 0`, **not** the building-inclusive AABB. Centre distance mis-tiers a 128 m chunk by up to 90 m, so a footprint test is required; but including building height would tier a chunk by its tallest tower rather than by the ground the player is looking at, and at Z2 (camera 370.8 m up) a single 217 m `res_highrise` would drag its whole chunk from MEDIUM to NEAR — `sqrt(52² + (370.8−217)²) = 162 m` — dragging the shadow pass back with it. Ground-plane AABB is the rule, and it is what §2.13's re-derivation is computed against.

| tier | band | building mesh | props | shadows | window shader |
|---|---|---|---|---|---|
| **NEAR** | `d ≤ 150` | LOD0, ≤ 320 tris (≤ 420 tall archetypes) | pole + lamp + pool + wetsmear | **casts** | per-window hash + flicker + soot |
| **MEDIUM** | `150 < d ≤ 420` | LOD1, ≤ 96 tris | lamp + pool | no | per-window hash, no flicker |
| **FAR** | `420 < d ≤ 1200` | shared unit box, 12 tris, one MM per chunk | lamp only | no | window *bands*, no per-window hash |
| **CULLED** | `d > 1200` | torn down to `SIM_ONLY` | — | — | — |

**MEDIUM draws LOD0, not the LOD1 this table specifies** (doc 91 D-14, 2026-08-19). A measured, reversible departure, not an oversight: §2.6's bucket-merge paragraph carries the A/B and the reasoning, and `CityView.atlas_lod` is the one-line switch. In short — §2.14's LOD1 rule drops decor (ledges, sign bands, chamfers), and on a mid-rise commercial block those bands are what the building reads as at 374–412 m, so the LOD1 tier dims exactly the blocks a player scans for a blackout. The rest of this row — no shadows, per-window hash, no flicker — is applied, and was not before the merge.

**Hysteresis:** upgrade at `edge − 20 m`, downgrade at `edge + 20 m`, at most one tier change per `lod_dwell_s = 0.5 s`.

**Only NEAR chunks cast shadows** (`cast_shadow = OFF` on all MEDIUM/FAR MultiMeshes), `directional_shadow_max_distance = 180 m`. Biggest single draw-call saving in the design.

**Consequence of the camera table (re-derived, report R-17).** At Z2 the camera sits `420·sin 62° = 370.8` m up, so *every* rendered chunk is at least 370.8 m away and **no chunk is ever NEAR at Z2** — the shadow pass is empty. But 370.8 m is inside the MEDIUM band (`≤ 420 m`), so the nearest two chunk rows are **MEDIUM, not FAR**: the pre-amendment claim that "the entire city is FAR at max zoom" was wrong at a 420 m zoom ceiling and is deleted. The correct statement is: **Z2 is the shadow-free pose, not the cheapest one.** §2.13 re-derives the numbers; the cheapest pose is now Z0.

**Why `medium_max_m` stays at 420 m.** Report C-63 allows either raising `medium_max_m` or accepting ~10 draw calls per chunk at max zoom. Raising it only converts FAR chunks into MEDIUM and makes Z2 *more* expensive. Restoring the all-FAR result would instead require *lowering* `medium_max_m` below 370.8 m — arithmetic in §2.13 — which buys 118 → 48 opaque calls at Z2 but renders the entire skyline as the shared 12-tri box, discarding exactly the LOD1 roof signatures §2.14 authors "to preserve archetype readability at 400 m". **Ruling: keep `medium_max_m = 420`, accept ~10 calls per MEDIUM chunk.** The budget carries it with 48% headroom.

#### 2.5b The pitch-coupled cull, and the bust it turned out not to be (2026-09-02, report 98 RR-98, doc 92 §42)

`far_cull_m` was a constant per preset (900 / 1200 / 1500 m) and the camera's
pitch had no say in it. The camera tilt work handed this lane a ranked fix:
**couple `far_cull_m` to pitch — cull farther when looking down, nearer at the
floor — to bring a manual pitch floor's draw calls back under the 320 budget.**
It is built, it is armed, and **it does not do the job it was ranked for.**
Both halves of that sentence are this section.

**What is built.** `RenderStateModel.pitch_cull_reach_m(camera_y, pitch,
aspect)` computes where the frustum's TOP CORNERS meet the ground, and
`set_camera_pose` clamps the cull ring down to it. `CityView.refresh` supplies
the pitch and the aspect, read off the live `Camera3D` and viewport rather than
passed down from the shell — a fourth argument to `refresh()` would have made
this feature inert in the shipped game until `main.gd` was edited to supply it,
and an authored-but-unapplied knob is precisely the defect §2.13b exists to
close. `lod.pitch_cull` authors `enabled`, a `slack` curve in pitch, a
`floor_m` and a `max_aspect`.

**The corners, not the centre — the correction that matters.** The centre of
the top edge reaches `h / tan(θ − fov_v/2)`, which is 411.9 m at the Z2 pose
and is exactly the `r_far` `lod._z2_derivation` computes by hand. The top
CORNERS reach **532 m at that same pose, 29 % further**, because a corner ray
carries a horizontal component that flattens its descent. The first draft of
this function culled at the centre figure and would have deleted chunks
visible in the top corners of every frame.
`test_the_corners_reach_a_third_further_than_the_centre` is the guard.

**Why the bound is exact at any building height.** Past the range where the top
ray meets the ground, that ray is *below* ground — so every point at that
range, tower tops included, sits above the frame's top edge and is off-screen.
The reach is a true horizon, not a heuristic, which is what makes culling at it
safe rather than merely cheap.

**Two reconciliations the first draft got wrong and this one does not.**
(1) `slack` multiplies the computed REACH, not `far_cull_m`: the reach scales
with camera height as much as with pitch — 48 m from the Z0 pose at the 34°
floor against 1,111 m from the Z2 pose, a factor of 23 — and one multiplier
keyed on pitch alone cannot express both. (2) The reach is a GROUND range and
`chunk_ground_distance` is the 3-D distance from the camera, which is why
`medium_max_m` 420 is a ground radius of 197.3 m at Z2 in the derivation above.
The ring is written as `hypot(reach, camera_y)` or it comes in by the whole
camera height — 371 m of it at Z2.

**Composition.** The pitch ring may only ever SHORTEN the draw distance; it may
never come inside `pitch_cull_floor_m`, which is authored EQUAL to
`medium_max_m` so §2.5b can remove FAR chunks and can never touch the tier the
player is looking at; and it composes with §2.13's ladder by MINIMUM, so a
governor in trouble is not undone by a camera that happens to be looking down.
A model nobody has posed, or one posed with pitch `< 0` (which is what a
headless caller and every pre-§2.5b call site supply), uses the preset's ring
untouched — so nothing that existed before this section changed behaviour.

##### The measurement, and the finding

Bench city, hour 13, `--focus=52,44`, 1920×1080, `--pitch=DEG` pins the pitch
band to a constant at every pose (§2.5's pitch is a pure function of `zoom_t`,
so a manual floor has no other expression). `dc+ui` adds §2.13's 25 batched UI
calls; the budget is Balanced's 320.

| pitch | Z0 dc+ui | Z1 dc+ui | Z2 dc+ui | Z2 tiers (near/med/far) |
|---|---|---|---|---|
| 34° (**the floor**) | 248 | **353** | 264 | 0 / 18 / 18 |
| 48° | 248 | 335 | 221 | 0 / 17 / 19 |
| 62° (**the ceiling**) | 246 | 299 | 221 | 0 / 17 / 19 |
| §2.5 zoom-coupled (34/48/62 by pose) | 248 | **335** | 221 | 0 / 17 / 19 |

**Every one of those numbers is identical with §2.5b armed and disarmed**
(`--pitch-cull=1` vs `--pitch-cull=0`, which differ in nothing else): at 62°
the ring resolves to 675 m against the preset's 1200 and removes **zero** draw
calls; at 34° it resolves to 1,245 m, longer than the preset's ring, and is
clipped to it.

**Why zero, and it is not because the code is wrong.** The bench and starter
cities are about 896 m across and the presets cull at 900 / 1200 / 1500 m. **A
cull ring larger than the city is not a cull.** The proof is `--far-cull=M`,
which brings the ring inside the city with nothing else changed: at Z2 the FAR
chunk count is 19 at 1200 m, 19 at 675 m — and **8 at 500 m**, with `dc`
196 → 191. The tier machinery answers the ring exactly as designed; it simply
has nothing to remove until the ring is inside the city. §2.5b is therefore
**armed for the city sizes doc 09 allows and for the manual pitch floor doc 12
will add, and is worth 0 dc on the fixtures we have today.** That is the honest
statement and it is published rather than buried.

##### The bust is the shadow pass, not the cull

The Z1 bust is real — **353 dc+ui at the pitch floor and 335 at the shipped
zoom-coupled pitch, against a 320 budget, i.e. it busts by 15 before any manual
tilt is involved at all.** `far_cull_m` cannot fix it *in principle*: the Z1
census is 10 NEAR + 26 MEDIUM + **0 FAR**, and a cull distance only ever
removes chunks beyond `medium_max_m`. There are none to remove. The ranked fix
was ranked against a cost it cannot reach.

Two levers were measured against it instead:

* **`medium_max_m`, pulled to 250 m at the pitch floor: Z1 328 → 322 dc
  (−6).** Not the answer either — but the same run takes **Z2 from 239 to 174
  dc (−65)**, so a pitch-coupled `medium_max_m` is a real Z2 lever and is the
  one worth building if Z2 ever becomes the problem.
* **The shadow pass, which is where Z1's draw calls actually are.** Performance
  (`shadows: false`) draws Z1 at **124 dc**; the identical run with the shadow
  pass restored draws **311**. **~187 of Balanced's 310 Z1 draw calls, 60 % of
  the pose, are the sun re-drawing the city into its cascades.** The lever with
  purchase at Z1 is `shadow_max_m` / cascade coverage — `shadow_splits` is not
  one, because Godot batches the PSSM passes and High's four splits cost the
  same 223 draw calls at Z0 as Balanced's two (they cost 67 % more primitives,
  which is the column a shadow setting actually shows up in).

> **OPEN — Z1 busts the draw-call budget by 15 as shipped, and by 33 at a pitch
> floor.** Not closed by this lane, and deliberately not closed by adjusting
> the budget. *Re-open trigger: `profile_frame --preset=balanced --focus=52,44`
> reporting `z1 dc+ui` over 320. The measured candidate is `shadow_max_m`, worth
> ~187 dc at Z1; a pitch-coupled `medium_max_m` is worth 6 there and 65 at Z2.*

### 2.6 Building rendering: MultiMesh + per-instance custom data

**Custom-data contract (LOCKED by this doc):**

| channel | meaning | encoding |
|---|---|---|
| `.r` | `emissive_scale` | 0.0–1.0 continuous |
| `.g` | `damage` | 0.0 pristine → 1.0 gutted |
| `.b` | packed state | `variant + 16·stage + 112·overlay_state` (variant 0–15, stage 0–6, overlay 0–3; max 447, exact in f32) |
| `.a` | `anim_phase` | 0.0–1.0 per-building random |

```glsl
float p = INSTANCE_CUSTOM.b;
float variant = mod(p, 16.0);
float stage   = mod(floor(p / 16.0), 7.0);
float overlay = floor(p / 112.0);
```

**Exactly four building overlay states** — `NORMAL 0`, `WARNING 1`, `CRITICAL 2`, `OFFLINE 3` (report C-64, ruled). `SELECTED` is **not** an `overlay_state`: a selection is transient and single-valued, so doc 12 draws it as an outline/ring in `MarkerLayer` on the UI layer and never touches the instance buffer. The 2-bit field and the packing constant `112` are therefore locked, and test 17's 448-combination round-trip stands. Former §9 conflict 9 is closed.

**Window emission (NEAR/MEDIUM).** UV2 carries the window grid (§2.14): `UV2 = (-1,-1)` on every non-façade surface, otherwise `[0,1]²` across the façade, with `window_cols`/`window_rows` as per-mesh uniforms.

```glsl
if (UV2.x < 0.0) { EMISSION = vec3(0.0); }
else {
  vec2  cell = floor(UV2 * vec2(window_cols, window_rows));
  float h    = hash21(cell + vec2(variant*37.0, variant*11.0));   // stable 0..1
  float gate = mix(0.06, 1.0, sc_night);          // daytime interiors barely read
  float e    = INSTANCE_CUSTOM.r * gate;
  float lit  = step(1.0 - e, h);                  // ← the whole trick
  float vary = 0.35 + 0.65 * hash21(cell + 91.0);
  float flk  = 1.0 - 0.25 * step(0.985, hash21(cell + floor(sc_time*3.0)));  // NEAR only
  EMISSION   = window_color * lit * vary * flk * window_nits * (1.0 - 0.6*INSTANCE_CUSTOM.g);
}
ALBEDO *= COLOR.rgb;                               // baked vertex AO (§2.14)
ALBEDO *= mix(vec3(1.0), soot_color, INSTANCE_CUSTOM.g * 0.8);
```

`lit = step(1 - e, h)` is load-bearing: **`emissive_scale` is literally the fraction of windows lit.** `e = 1.0` → all on. `e = 0.05` → 5% on, distributed stably (never twinkling between frames) — which reads exactly like battery/emergency lighting in a dead building.

**FAR shader** drops the per-window hash (shimmer at 12 tris and 500 m) for horizontal bands; `rows = max(2, floor(height_m / 3.5))` where `height_m = length(MODEL_MATRIX[1].xyz)`:

```glsl
float band    = fract(y01 * rows);                     // y01 = local y, unit box
float along_m = <metres along this wall>;              // picks x or z by normal
float segment = floor(along_m / far_cell_m);           // far_cell_m = 6.4 (2 bays)
float lit     = step(0.30, band) * step(band, 0.78)
              * step(1.0 - e, hash21(vec2(segment, floor(y01*rows)) + variant·k));
float bay     = along_m / far_bay_m;                   // far_bay_m = 3.2
float sharp   = step(1.0 - far_mullion_duty, fract(bay));
lit          *= mix(sharp, far_mullion_duty, clamp(fwidth(bay)*2.0, 0.0, 1.0));
EMISSION      = window_colors[family] * lit * vary
              * window_nits_far * far_energy_scale * gate;
```

**Three amendments, made when the tier was first wired to the renderer and all three measured against the frame** (`game/shaders/building_far.gdshader`, `CityView`):

1. **A lit storey is segmented, not lit end to end.** The original `hash11(storey)` lights a storey's whole perimeter at once. Rendered next to the MEDIUM chunks in front of it, the far city came out as continuous cream chevrons — brighter and far more regular than the tier it must match, so the boundary read as a *lighting change*, which is precisely what the LOD ladder may not do. The hash is now taken over `(segment, storey)` where a segment is `far_cell_m = 6.4` m of façade. **This is not the per-window hash this section rejects**: a 3.2 m window cell is sub-pixel at 500 m and samples white noise per pixel, whereas 6.4 m is ≈ 23 px at 500 m and ≈ 10 px at 1200 m — an order of magnitude above the crawl threshold.
2. **Mullions, filtered analytically.** At 21:00 residential `e ≈ 1`, so nearly every segment lights and a tower reads as one solid stripe per floor — the near tier only escapes that because its §2.14 texture *draws* the wall between the panes. The far tier therefore multiplies in a `far_bay_m = 3.2` m periodic strip at `far_mullion_duty = 0.72`. **A periodic pattern under minification is the textbook moiré case**, and the reason this section banned the per-window hash in the first place; it is legal here only because it is crossfaded to its own mean before it can alias. `fwidth(bay)` is bays-per-pixel: below ≈ 0.5 the strip is resolvable and drawn sharp, above it the term becomes the constant `far_mullion_duty` — which is *exactly* the average the sharp pattern integrates to, so the structure fades out with no brightness step and no shimmer. Structure wherever structure is visible, and nothing where it is not.
3. **`far_energy_scale = 0.98` compensates band coverage.** A lit band covers 100% of its segment's width; a lit near-tier window covers only the pane inside its cell. At equal nits the far tier out-emits the tier in front of it. Measured at the Z2 showcase pose, a swapped chunk now sits at **0.84** of the LOD0 luminance it replaces (whole-frame delta **−2.0%**), against ≈ 1.4× before the scale existed — the residual is aerial perspective's sign, not a lighting change. Brightness only: it never changes how many segments light.

**`INSTANCE_CUSTOM.a` means something different in the FAR buffer.** The §2.6 contract above locks `.a` to `anim_phase` for the NEAR/MEDIUM buffers, which `RenderStateModel` writes and which the mirror tests assert. The FAR buffer is not one of those: `CityView._upload_far` builds it by folding the chunk's buckets together, the FAR shader is its only reader, and there is no flicker at 500 m for a phase to drive. `.a` therefore carries the **family index** (0 residential … 4 civic), which is what buys per-family window colour inside **one draw call per chunk**. `.r`, `.g` and `.b` are copied across untouched, so a chunk crossing the boundary mid-blackout carries its exact emissive ramp, damage and construction stage over the swap.

**The swap is the model's decision, not the renderer's.** `CityView.refresh` calls `RenderStateModel.update_chunk_tiers` with the camera it is already given and reads `chunk_tier` — so the far tier inherits §2.5's 20 m hysteresis and 0.5 s dwell unchanged, and cannot flicker at a band edge. `CityView.lod_enabled = false` restores the pre-tier renderer (every chunk at LOD0) for A/B work.

**The MEDIUM tier is one MultiMesh per (chunk, ARCHETYPE), not per (chunk, archetype, LEVEL)** — doc 91 D-14, shipped 2026-08-19. This paragraph is the bucketing rule; the per-level bucket above it still describes NEAR.

The bucket-per-level rule was written against an assumed ~6 `archetype:level` combinations per chunk. The benchmark city measured **16.4**, because a real block holds five archetypes at four levels, and Z2 went over the Balanced draw-call budget on it (352 against 320). The counting is in §2.13's as-shipped table; this is the fix.

```
                        buckets   nodes   per chunk
per (chunk, arch, level)    591     591       16.42     ← was
per (chunk, archetype)      591     221        6.14     ← is
```

`6.14` is not a target that was aimed at. It is what the bench city's own archetype mix produces, and it lands on §2.13's assumed 6 — so the derivation below is now *true as written* rather than optimistic by 1.7×.

**One MultiMesh cannot hold several meshes, so it holds one mesh that contains them.** `CityView` concatenates the archetype's level meshes into a single `ArrayMesh` at load, tagging every vertex with the level it came from in **`COLOR.a`** — the one vertex channel the gray-box leaves free (`MeshBuf._push` writes `Color(ao, ao, ao, 1.0)` and the shader reads `.rgb` only). The instance says which level it is, and the vertex stage collapses every vertex of every other level onto the instance origin, where the triangles have zero area and the rasteriser drops them before a fragment exists. No `discard`, no depth write, early-Z intact.

**The level rides in `.b`, at stride 448, and that number is the whole design.** `INSTANCE_CUSTOM` has exactly four channels and this section spends all four; there is no fifth to add. `.b` already carries an integer, and `448 = 16 · 28` with `28 ≡ 0 (mod 7)`, so adding `448·level`:

| decoder | before | after `+448·level` |
|---|---|---|
| `variant = mod(p, 16)` | 0–15 | **unchanged** (448 ≡ 0 mod 16) |
| `stage = mod(floor(p/16), 7)` | 0–6 | **unchanged** (28 ≡ 0 mod 7) |
| `overlay = floor(p/112)` | 0–3 | needs `mod(…, 4)` in place of `clamp(…, 0, 3)` |
| `level = floor(p/448)` | — | 1–5 |

The `overlay_of` change is an exact identity on every value this section can pack (0–447 → `floor(p/112)` is already 0–3, where `clamp` and `mod 4` agree), so nothing that existed before moved. Maximum packed value `447 + 448·5 = 2687`, exact in f32. `tests/test_render_merge.gd` checks all 448 combinations × 5 levels rather than arguing the arithmetic.

**Everything except `.b` is the mirror, byte for byte.** The merged buffer is built by folding the chunk's bucket mirrors with one `memcpy` each and then adding the level to one float per instance — the same guarantee the FAR tier makes, so a chunk crossing into MEDIUM mid-blackout carries its exact emissive ramp, damage and construction stage across the swap. `.a` stays `anim_phase`, which is why a construction site keeps its work-light phase at this tier (the FAR buffer, which has no sites, is the only buffer that repurposes `.a`).

**The atlas is cut per LEVEL SET, not per archetype, and this is the design's real cost.** The vertex shader runs over every level *in the mesh*, not just the instance's, so the atlas submits triangles it will never draw. Instance-weighted over the whole bench city, against the 100,674 building triangles the un-merged tier submits:

| atlas contents | building triangles | vs un-merged |
|---|---|---|
| all five levels | 578,834 | 5.75× |
| **the levels the chunk holds** | **397,700** | **3.95×** ← shipped |
| the same, cut from LOD1 | 127,856 | 1.27× ← what `atlas_lod = 1` would buy |

The mask is what buys the middle row, and it comes out of the same histogram that motivated the merge: the 591 buckets fall into 221 groups, **2.67 levels per group, not five**. The `ArrayMesh` is therefore keyed by `(archetype, 5-bit level mask, lod)`, so a chunk holding L1 and L3 of `house` submits two levels rather than five. The level TAG stays absolute (1–5) so the mask is invisible to the shader; a mask changes only when a building is built, upgraded or demolished, and that is when the node's mesh is swapped, never per frame.

**3.95× the triangles for 0.41× the building draw calls.** That is the trade, stated plainly, and the measurement below says it is the right way round: at Z2 the whole frame goes 100,906 → 209,546 primitives (2.08×, diluted by the roads and by the unchanged FAR tier) and **the GPU column does not move — 2.44 → 2.38 ms** against a 13 ms Balanced budget. The triangles bought back are degenerate: transformed once, dropped at the rasteriser, never shaded. The draw-call budget, meanwhile, is the one this doc publishes and the one the bench city broke. It remains the largest cost this design carries, and it is why `atlas_lod = 1` is worth having the day §2.14's LOD1 authoring can pay for it.

**Two more per-mesh uniforms had to stop being per-mesh.** `window_cols`/`window_rows` are baked into UV2 at atlas-build time (`UV2 × (cols, rows)`, uniforms set to 1.0), which lands `floor(UV2 · (cols, rows))` on exactly the same cell and leaves `lit = step(1 − e, h)` untouched; the `(-1,-1)` and `(-1,-2)` sentinels are copied verbatim, because scaling them would flip `has_uv2` and light a windowless data-centre wall. `build_height_m` becomes `level_build_height[6]`, indexed by the same absolute level, so the construction clamp still cuts each instance at its own height.

**LOD0 at MEDIUM, and §2.5's table says LOD1. Measured, and deliberately not taken yet.** Both were A/B-rendered on the bench city with the merge as the only other variable (`tools/profile_frame.gd --atlas-lod=`). The LOD1 atlas is better on triangles (1.27× against 3.95×) and identical on draw calls — but §2.14's LOD1 rule *drops decor: balcony ledges, sign bands, chamfers*, and on a mid-rise commercial block those pale horizontal bands **are** what the building reads as at 374–412 m. Blocks that show as banded structure at LOD0 come out as flat dark boxes: a visible pop at the 150 m boundary, dimming exactly the blocks a player scans for a blackout. D-14 is a draw-call defect and the merge closes it at either LOD, so the LOD that keeps the picture wins. `CityView.atlas_lod` flips to 1 the day §2.14's LOD1 authoring keeps a mid-rise's banding; the renderer side is written and tested for it.

**§2.5's other two MEDIUM rules are now actually applied.** The merged node is a new node, so it takes `cast_shadow = OFF` (the un-merged path left MEDIUM casting and got away with it only because a MEDIUM chunk is past `directional_shadow_max_distance` anyway — §2.13's "shadow, NEAR only" arithmetic is now true by construction rather than by luck) and `near_flicker = 0`. That flicker is the one deliberate pixel difference between the merged tier and the un-merged one: at ≥150 m a lit cell no longer takes a 25% dip on the 1.5% of cells the flicker hash picks, which is what §2.5's table always said MEDIUM should look like.

**NEAR is untouched, and its half of D-14 is still open.** NEAR keeps one LOD0 MultiMesh per (chunk, archetype, level) — measured at the same 16.4 per chunk against §2.13's assumed 8 — because no measured pose fails on it (Z1, the sizing pose, measures 136 calls with UI against 320) and because the NEAR tier is the one the player inspects. The same atlas would close it at LOD0 with no visual change; see §2.13's residual note.

**Materials.** Material lives on the generated `ArrayMesh` surface, shared across levels and chunks: **2 `Shader` resources total** (building, far), instanced as 15 archetypes × 5 levels × 2 LODs = 150 `ShaderMaterial`s differing only in uniforms (`window_cols/rows/color`). Two pipeline states for the entire city — the number that matters on tiled mobile GPUs. Gate: `RENDER_TOTAL_SHADER_COMPILES_IN_FRAME == 0` after warm-up. The merged MEDIUM tier needs **one material per archetype for the whole city**, not one per bucket: with the grid in UV2 and the heights in an array, nothing left in its uniform set varies by chunk or by level.

`window_color` per family: residential `#FFCE8A` (warm tungsten), commercial `#CFE6FF` (cool office), industrial `#BFD0C8` (sodium-green), tech `#7FF0D0` (cyan, data center), civic `#E8F0FF` (clinical white).

**`window_nits` is per family too, and it has to be.** The five hues are not equally bright at equal nits — luma runs civic `0.94` > commercial `0.89` > tech `0.84` > residential `0.83` > industrial `0.80` — so a flat `3.2` pushed the cool-white office and civic bays past the glow's HDR threshold and they read as solid white blocks at Z2 while the warm residential bays still resolved into individual windows. `emissive.window_nits` is now `{family: nits}` — residential `3.2`, commercial `2.4`, industrial `2.7`, tech `2.6`, civic `2.5` — and a plain number is still accepted, meaning the same brightness for every family (an older `data/render.json` still boots). Equal-luma normalisation alone would put commercial at `2.98`; `2.4` goes further deliberately, because an office floor lit for the cleaners at 21:00 *should* sit below a living room. Measured at the Z2 showcase pose: cool-white bays fall from mean luminance `167.7` to `154.2` (below the warm bays' `159.7`, where they were above it), and the warm channel is **byte-identical**.

**Everything in this paragraph is brightness, and only brightness.** `day_gate` alone decides how many cells light. No value of `window_nits`, `window_nits_far` or `far_energy_scale` can move `lit = step(1 − e, h)`, so `RenderStateModel.lit_window_count` keeps mirroring the shader — which is the property job 1 (the blackout read) rests on.

### 2.7 THE BLACKOUT — exact definition

#### 2.7.1 Steady-state emissive target

```
occ = occ_b(building) * occupancy_hour_curve[family](hour)   # both 0..1
if   powered:            E = 0.55 + 0.45 * occ
elif has_backup_power:   E = 0.22
else:                    E = 0.05
E *= (1.0 - 0.50 * damage)
if condition < 0.15:  E *= 0.40          # condition ∈ [0,1] per report C-14
emissive_target = clamp(E, 0.0, 1.0)
```

**`occupancy_hour_curve` is owned by this doc** (report C-66), lives in `data/render.json` §8, and is keyed by building **family** (residential / commercial / industrial / tech / civic), not archetype. It is **art, not simulation**: it never feeds back into `sim/`, adds no save state, and is not a sim input. Doc 02 supplies only the slow structural `occ_b` (its `OCCUPANCY_RAMP_HOURS = 36` ramp); this doc supplies the diurnal shape and multiplies the two. Read the curve as *the fraction of structurally-occupied floor area showing light at that hour* — residents asleep at 03:00 are occupants but not lit windows, which is why the residential curve troughs at night rather than peaking there. Six keyframes per family, linearly interpolated and wrapping across 24:00; values in §8 `occupancy_hour_curve`.

Generating formula for the table below: `E = 0.55 + 0.45 · occ_b · curve[residential](hour)`, then `E ×= (1 − 0.50·damage)`; `lit = round(E · 960)`.

**Worked example — Level-4 residential high-rise, 48 floors, 2×2 tiles = 16×16 m, `occ_b = 0.92`.**
`window_cols = round(16 / 3.2) = 5`, `window_rows = 48` → 240 cells per façade, **960 cells** over four façades.

| state | curve | occ = 0.92·curve | E | lit windows |
|---|---|---|---|---|
| 21:00, powered, undamaged | 1.00 | 0.9200 | `0.55 + 0.45·0.9200 = 0.9640` | `0.9640·960` ≈ **925** |
| 03:00, powered, undamaged | 0.12 | 0.1104 | `0.55 + 0.45·0.1104 = 0.5997` | `0.5997·960` ≈ **576** |
| 21:00, blackout, no backup | 1.00 | 0.9200 | `0.05` | ≈ **48** |
| 21:00, blackout, backup gen | 1.00 | 0.9200 | `0.22` | ≈ **211** |
| 21:00, blackout, 60% fire damage | 1.00 | 0.9200 | `0.05·(1 − 0.50·0.60) = 0.035` | ≈ **34** |

925 → 48 lit windows is unmissable at Z2. That is the mechanic. The 925 → 576 swing between 21:00 and 03:00 is the "city breathes" read that C-66 exists to protect: without the diurnal curve every powered building would sit at a flat `0.55 + 0.45·0.92 = 0.964` all night, and dawn would look identical to midnight.

#### 2.7.2 Going dark

On `BlockDarkChanged{block_id, block_dark: true, powered_fraction: 0.0}`:

> **Naming (report C-38, corrected by report RR-1).** Doc 04's flag is renamed **`block_dark`** — block granularity is correct, because the land block *is* the render chunk (constitution §6). "District" now means doc 09's 1–4 contiguous blocks and is a population-weighted aggregate the renderer never consumes. **The carrying event is renamed with the flag: it is `BlockDarkChanged`, emitted by doc 04 §4.** *(The earlier claim here that "the carrying event keeps its name `DistrictDarkChanged`" is deleted — doc 04 owns the event name and already emits `BlockDarkChanged`; its test 23 asserts the old name is never emitted, so the renderer's former subscription received nothing. Report RR-1.)* Every renderer-side identifier in §2.7, §4 and §5 is `block_id`, never `district_id`, and no live contract in this doc or in `game/` names the old event — the only surviving mention of it is the deletion record in this paragraph and in the §Amendments table.

1. **Brownout stutter** — block-wide multiplier on `emissive_cur`, linear-interpolated keyframes (seconds after event):
   `[(0.00,1.00),(0.07,1.00),(0.09,0.12),(0.15,0.95),(0.17,0.08),(0.24,0.70),(0.30,0.00)]`
   Two visible stutters, then collapse. Streetlight and lamp MultiMeshes get the **same** envelope.
2. **Per-building stagger** — `delay_i = anim_phase_i · 0.35 s`. Nothing snaps in unison; the block crumbles.
3. **Fall** — after delay, `emissive_cur += (target − cur)·(1 − exp(−dt/0.12))`; 99% settled in 0.55 s.
4. **Streetlights first** — their delay is `delay_i · 0.60`. The street dies, then the towers: ground-level darkness before skyline darkness reads as cause-and-effect.
5. **Pooled `OmniLight3D`s** in the block drop `light_energy` to 0 on the same schedule — this is what actually darkens road surfaces near the camera.
6. **Ground** — Mobile cannot localise ambient, so `ChunkView` writes a per-chunk `chunk_power` shader parameter; ground/road albedo multiplies by `mix(1.0, 0.45, block_dark)`.

**Total sim-event → fully dark: 0.30 (envelope) + 0.35 (max stagger) + 0.55 (fall) ≈ 1.20 s worst case, ~0.90 s typical.**

#### 2.7.3 Relighting — the payoff

On `BlockDarkChanged{block_id, block_dark: false, powered_fraction: 1.0, restore_order: PackedInt32Array}`:

**Primary path — energization order (report C-39, ruled).** Doc 04 now carries `restore_order` on the restoration event: the building ids in the order its energization DFS re-energized them. This is strictly better than a `source_pos` because it follows the grid's *real* restoration priority rather than a straight-line guess, and it costs doc 04 nothing — the DFS already produces it. Rank `k_i ∈ [0, n−1]` is the index of building `i` in `restore_order`:

```
n       = restore_order.size()
k_i     = index_of(i, restore_order)
delay_i = 2.2 * (k_i / max(n - 1, 1)) + anim_phase_i * 0.5
```

**Fallback path — distance.** If `restore_order` is absent or empty (a save migrated from before the C-39 schema, or a synthetic event in tests), fall back to the original radial sweep against `source_pos`, and if that is also absent, against the block centroid:

```
d_i     = distance(building_i.world_pos, source_pos)
d_max   = max(d_i over block, 40.0)                       # floor avoids divide-by-tiny
delay_i = 2.2 * (d_i / d_max) + anim_phase_i * 0.5
```

Both paths produce delays on the same `[0, 2.2]` span with the same jitter, so every downstream timing (`relight_peak_event_s = 1.1`, the 3.15 s total, tests 12 and 13) is identical either way. The ordering path simply gets the *sequence* right.

**Worked example — a 28-building block, jitter zeroed.** `n = 28`, so `delay_i = 2.2 · k_i / 27`. The substation-adjacent building (`k = 0`) lights at `t = 0.000 s`; `k = 9` at `2.2·9/27 = 0.733 s`; `k = 18` at `1.467 s`; the last building (`k = 27`) at `2.2·27/27 = 2.200 s` exactly. With jitter the spread is `[0, 2.7]` s.

**Streetlights** use `0.80 ×` the delay of the nearest building in `restore_order` (nearest by world position, resolved once per relight) — **streets relight ahead of buildings**, a wavefront running along the feeder rather than a circle. Each building then ramps, with `t` measured from its own delay expiring:

```
t < 0.15 :  e = target * (t / 0.15) * 1.35            # inrush overshoot
t ≥ 0.15 :  e = target * (1.35 - 0.35 * min(1, (t - 0.15) / 0.30))
```

The 1.35× overshoot for 0.15 s pushes windows past `glow_hdr_threshold` (0.78 at night, Balanced) so each tower **blooms** as it returns, then settles. Total block relight `2.2 + 0.5 + 0.45 = 3.15 s`.

Audio hooks (**owned by this doc** in Phase 2, report G-3 — see §2.15): `render_relight_started(block_id, duration_s)` at t=0, `render_relight_peak(block_id)` at `t = 1.1 s`. The transformer-hum swell must be authored against those two beats (spec §39: "power restoration should have a satisfying audiovisual signature").

#### 2.7.4 Partial and rolling outages

`powered_fraction ∈ [0,1]` is carried on the event **from day one** (report C-39, ruled), even while doc 04's service model is binary — binary is the strict subset `{0.0, 1.0}`, so the renderer works today and load-shed tiers light up later without an event-schema change. Former §9 conflict 13 is closed.

Which buildings go dark is chosen by **stable hash, never randomly**: building `i` stays powered iff `hash01(id) < powered_fraction`. Re-evaluating the same fraction always yields the same set, so a browning-out block does not shimmer. Buildings doc 04 marks `priority_load = true` (hospital, police, fire, water pump, data center) stay lit whenever `powered_fraction > 0`.

#### 2.7.5 Momentary outages, and why the full ceremony must be earned

Doc 04's auto-reclose retries **90 game-seconds after a trip** — 1.5 real seconds at 60× — and states plainly that "momentary outages are therefore common and cheap". Doc 04's own service hysteresis (`dark_hold_gs 20` = 0.33 real s) already suppresses anything shorter, so the renderer receives no event at all for those. But a successful auto-reclose produces a genuine dark→lit pair, and playing the full 1.2 s collapse plus 3.15 s swept relight for it would be both disproportionate and, at 4.35 s of ceremony for a 1.5 s event, still animating after power is long back.

**`momentary_outage_s` is derived, not chosen (report C-40, ruled).** It is a dependency on doc 04's protection tuning and is asserted by a headless test that reads both data files (§7.2 test 24):

```
momentary_outage_s  ≥  1.5 × (auto_reclose_delay_gs / 60) × auto_reclose_max_attempts
```

Evaluated against `data/power.json` as it stands (`auto_reclose_delay_gs = 90`, `auto_reclose_max_attempts = 2`):

```
1.5 × (90 / 60) × 2  =  1.5 × 1.5 × 2  =  4.50 s
```

**`momentary_outage_s` is therefore recomputed from 2.50 → 4.50 real seconds** (= 270 game-seconds). The old 2.50 violated its own stated derivation: it covered a single successful reclose (1.5 s) but not the two-attempt case (3.0 s), so an outage that the grid *did* catch on the second try would have played the full repair ceremony. The 1.5× factor is the safety margin over the worst self-healing case.

**Rule.** Classify on the *relight* event, by how long the block was dark:

| `outage_real_s` | classification | render |
|---|---|---|
| `< 0.33` | (no event — doc 04's `dark_hold_gs 20` filtered it) | nothing |
| `0.33 – 4.50` | **momentary** | stutter envelope only, then ramp straight back: no stagger, no sweep (ordering or distance), `relight_ramp_s` and the 1.35× overshoot retained. Total ≈ 0.75 s. Reads as a hard flicker — which is exactly what a reclose *is*. |
| `> 4.50` | **sustained** | the full §2.7.2 / §2.7.3 ceremony |

**The 4.50 s threshold separates the two populations cleanly**, which is the point of the assertion:

| event | outage length | class |
|---|---|---|
| reclose succeeds on attempt 1 | `90 gs = 1.50 s` | momentary |
| reclose succeeds on attempt 2 | `180 gs = 3.00 s` | momentary |
| lockout → crew | `180 gs (2 failed attempts) + travel (≥ 4 gm = 4.0 s) + manual_reclose_gm 4 (= 4.0 s)` ≈ **≥ 11.0 s** | sustained |

There is no outage between 4.50 s and 11.0 s that the grid can produce, so the threshold sits in a 6.5 s dead band and is robust to retuning on either side — but the test asserts the floor anyway, because if doc 04 raises `auto_reclose_delay_gs` or `auto_reclose_max_attempts` the floor moves and this constant must move with it.

A block that goes dark and is still dark when the collapse finishes always plays the full sequence; the classification only ever *shortens* the relight. This means the signature moment stays rare enough to keep its weight — the player learns that a swept relight means a real repair landed, and a flicker means the grid caught itself.

**`TotalBlackout` (citywide).** Doc 04 recloses substations "in descending `critical_load_kw` order at one per 30 game-seconds" — 0.5 real seconds apart. The renderer does **not** add its own sweep on top: each block relights when its own `BlockDarkChanged` arrives, so doc 04's staged reclose *is* the citywide sweep, and it is a better one than anything invented here because it follows real restoration priority. The per-block sweep (§2.7.3) still runs inside each block. Effect: the city comes back in priority order, hospital blocks first, over `n_substations × 0.5 s`.

#### 2.7.6 Resync after offline catch-up — snap, never animate

**Ruled (report C-68).** Doc 08 flags the first post-catch-up snapshot `is_resync: true`. On that snapshot the renderer **snaps** every `emissive_cur` to `emissive_target` and every streetlight and `chunk_power` value to its steady state, and **schedules no envelope, no stagger, no sweep and no overshoot**. Without this, a 12-real-hour absence (720 game-hours, report C-19) hands the bridge an accumulated event stream and the renderer would play a 3.15 s relight for every block that changed while the app was closed — minutes of ceremony over a city that is already fine.

Concretely, in `RenderStateModel.apply_snapshot(snap)`:

```
if snap.is_resync:
    for rec in records:  rec.emissive_cur = rec.emissive_target; rec.emissive_delay = 0.0
    drop every queued blackout/relight plan
    suppress render_relight_started / render_relight_peak / render_blackout_started for this snapshot
```

The same path already runs on save load, chunk build and preset change (§2.3, "full resync"); `is_resync` simply makes offline catch-up use it. Live events that arrive *after* the resync snapshot animate normally. Asserted by test 25.

### 2.8 Sky, day/night, fog, tonemapping, glow

`ProceduralSkyMaterial`. `DayNightController` derives `hour = (sim_time_minutes / 60.0) mod 24` from the snapshot and interpolates the **6-key gradient in §8 `daynight.keys`** (hours 00:00, 05:00, 07:00, 12:00, 18:30, 21:00, each carrying sky top/horizon colour, sun energy/colour/elevation, fog tint, and `sc_night`), linearly in linear-light space with hue interpolated in Oklab to avoid the muddy midpoint sRGB lerp produces between `#C88A5A` and `#9FBEDC`.

Sun azimuth `az = (hour/24)·360 − 90`. `sc_night` is **not** a function of sun elevation — it is authored so windows begin lighting at 18:00 while the sky is still warm (the best-looking moment) and are fully on by 21:00.

**Tonemap:** `TONE_MAPPER_AGX`, exposure 1.0, white 6.0. AgX over Filmic because it holds saturated neon and emergency-light hues without hue-shifting to white; the noir palette depends on that. Adjustments (Balanced/High): contrast 1.06, `saturation = mix(1.05, 0.92, sc_night)` — night desaturates toward monochrome so colour comes only from emissives.

**Fog:** depth fog only (volumetric is unavailable on Mobile). Four profiles — `clear_day`, `clear_night`, `rain`, `fog_weather` — with full values in §8 `environment.fog`, cross-faded over 4 s on weather change and blended by `sc_night` between the day and night clear profiles. Ranges span `depth_begin` 260→40 m and `depth_end` 1500→420 m as conditions worsen; `fog_density` 0.0012→0.0110.

Fog hides the FAR cull edge. **Invariant: `fog_depth_end ≤ far_cull_distance` for the active preset, always** (tested, §7). Because `far_cull_m` differs per preset *and* is a governor knob (down to 600 m), the invariant is enforced by a clamp at apply time rather than by authoring discipline alone:

```
fog_depth_end_eff = min(profile.end, active_far_cull_m)
fog_depth_begin_eff = min(profile.begin, 0.75 * fog_depth_end_eff)
```

Authored `clear_day.end` is lowered `1500 → 1200` in §8 so the Balanced/High authored values are already legal and the clamp only ever fires on Performance and under the governor. At the re-derived Z2 pose (§2.13) the farthest visible ground is 554 m from the camera, so 1200 m of fog range is ample at every zoom the player can reach.

**Glow** — the neon-noir signature, supported on Mobile. `glow_blend_mode = SCREEN` not ADDITIVE: additive blows out a 960-window tower and destroys the contrast the noir look depends on. Per-preset levels/intensity/threshold in §2.13 and §8; `glow_hdr_threshold` interpolates by `sc_night` so night is more bloom-prone than day.

> **Not yet wired (found by the render-polish pass, not fixed by it — the file has another owner).** `EnvironmentController.setup` pushes `glow_intensity`, `glow_strength` and `glow_bloom`, and **nothing reads `glow_levels`, `glow_hdr_threshold_day/night` or `glow_hdr_scale`**. The threshold in force is therefore Godot's default `1.0` at every preset and every hour, and the `sc_night` interpolation above does not happen. Measured while chasing the commercial blowout: pushing the authored Balanced night value `0.78` makes the frame *marginally brighter*, not dimmer, so this is a correctness gap rather than the cause of that blowout — but the three preset rows are dead data until someone wires them.

> **THE SKY, Wave 17 (2026-09-01) — the material above is no longer the one in force.** Until doc 12 §2.23's manual pitch axis, **no reachable pose could see the sky**: the shallowest authored pitch is 34° against a 40° vertical FOV, so the top of the frame sat 14° below the horizon and the `ProceduralSkyMaterial` reached the image only as ambient. `EnvironmentController.setup()` now installs `game/shaders/sky_gradient.gdshader` in its place (`use_gradient_sky`, on by default; `tools/profile_frame.gd --sky=procedural` is the A/B). It is a gradient and nothing more — zenith→horizon in one `pow`, a haze band at the horizon **drawn in the sampled FOG tint** so the far city and the sky meet on one colour, the ground hemisphere on that tint darkened; no sun disc, no scattering, no clouds, no half/quarter-res pass. Knobs and `radiance_size` (64, against the engine's 256, because the ambient cubemap is re-convolved every frame the hour moves) are in `data/render.json.sky`. Measured: the sky→ground seam at the world's 896 m edge, worst case, is a ≤ 17/255 per-channel step (report 98 RR-114); the draw-call count is identical to the material it replaces in all six A/B cells, and the GPU-time difference is inside this workstation's ±0.9 ms run-to-run spread, so **the sky's cost is owed on the device** (doc 92 §47.4).

**No SSAO.** Compensated at generation time by baked vertex-colour AO (§2.14): free at runtime, and the thing that stops gray boxes looking like floating cardboard.

### 2.9 Weather VFX

**The precipitation input is `precip01` (report C-58, ruled).** Doc 07 publishes `precip01 = clamp(precip_mm_h / 35.0, 0, 1)` — continuous on `[0,1]`, and lerped across the last 60 game-seconds of a weather segment into the next so it never steps. Everything below consumes `precip01`; the renderer does **not** see `precip_mm_h`, the weather enum, or any per-state table. Former §9 conflict 7 is closed.

**Rain.** One `GPUParticles3D`, emission box `90×40×90` m, repositioned each frame to `focus + (0, 20, 0)` with `local_coords = false` so drops do not swim during pans.

> **The box scales in XZ with camera distance (ruled).** `90 m` comfortably overshoots the frame at Z0/Z1. At Z2 the camera is 370.8 m up and the far chunk row is ~717 m wide, so the same box is a 90 m square of rain in the middle of a dry city — the worst weather read in the game, and one that made a thunderstorm look like a sprinkler. `scale = clamp(D / rain_box_dist_ref_m, 1, rain_box_max_scale)` with `ref = 90`, `cap = 8`, applied to the emitter's X and Z extents (and, on a shorter leash, `splash_radius_m`). **`amount` is never written, and THAT is the density cap:** the bed keeps the preset's exact particle count at every zoom and the same drops spread over more ground. Writing `amount` would also dump and restart the bed, which the "nothing restarts" rule forbids. **Y is never scaled** — the fall height sets `lifetime` at build time and re-writing `lifetime` on a live emitter re-ages every drop in flight. `WeatherFX.refresh` takes `D` as an optional third argument and otherwise reads it off the viewport's active camera, so a shell that predates this gets the fix with no integration. Measured at the Z2 pose in `main.tscn`: frame cells containing rain go from **26/48 to 45/48**. Draw pass: quad `0.02×0.55` m, `transform_align = Y_TO_VELOCITY`, unshaded additive, brightened by `sc_lightning`. Intensity uses **`amount_ratio = precip01`** (no particle restart, so it ramps continuously). Wind tilt: `gravity = Vector3(sc_wind.x·2.2, −22.0, sc_wind.y·2.2)`.

**Splash.** Second emitter, ring radius 60 m around focus, quad `0.35×0.35` m, lifetime 0.28 s, `amount_ratio = precip01²` — splashes appear late, which reads as rain "getting serious". At doc 07's heaviest authored rate, `precip_mm_h = 35 → precip01 = 1.00 → amount_ratio = 1.00`; at a light shower, `precip_mm_h = 7 → precip01 = 0.20 → rain 20%, splash 4%`.

**Snow.** Same graph, `gravity.y = −3.0`, quad `0.10×0.10` m, `damping 2.0`, turbulence on High only.

Counts: rain 1,500 / 4,000 / 9,000 and splash 0 / 600 / 1,600 and snow 1,200 / 3,000 / 6,000 for Performance / Balanced / High.

**Wetness integrator** (drives `sc_wetness`): `target = clamp(precip01·1.2, 0, 1)`; `tau = 25.0` rising, `90.0` falling (soaks fast, dries slow); `sc_wetness += (target − sc_wetness)·(1 − exp(−delta/tau))`. `precip01 ≥ 0.834` saturates the target at 1.0 (`0.834 × 1.2 = 1.001`), i.e. anything above ≈ 29 mm/h counts as fully soaked ground.

**Wet-ground cheat** (no SSR available), three stacked tricks:

1. Road/ground `roughness = mix(0.85, 0.18, sc_wetness)`, `specular = mix(0.50, 0.85, ·)`, albedo `× mix(1.0, 0.62, ·)`. Wet asphalt is darker *and* glossier; under the directional light and sky this does most of the work.
2. **Vertical smear instances.** `MM_wetsmear` mirrors every emissive lamp/sign/vehicle-light billboard below `y = 0`, Y-scaled 1.8, additive, alpha `0.35·sc_wetness`, with a vertical gradient fading to zero at the bottom. `visible_instance_count = 0` when `sc_wetness < 0.05`, so dry weather costs nothing. This is the streaked-reflection read, and its buffer is the `MM_lamp` buffer with a mirror transform.
3. High only: one `ReflectionProbe`, `update_mode = ONCE`, size `256×120×256` m, re-baked when focus moves > 100 m or `sc_wetness` crosses 0.3 / 0.7. Flagged for on-device validation (§9).

**Lightning — sky flash, zero particles, zero geometry.** On `lightning_strike{world_pos, magnitude}`, `sc_lightning` follows a two-stroke envelope (seconds after strike, linear interp):
`[(0.00,0.00),(0.02,1.00),(0.09,0.15),(0.13,0.85),(0.30,0.00)]`

Per frame while live, with `f = sc_lightning · magnitude`:

```
sky.energy_multiplier   = sky_base * (1.0 + 6.0 * f)
env.ambient_light_energy= amb_base * (1.0 + 4.0 * f)
sun.light_energy        = sun_base + 2.4 * f
sun.light_color         = lerp(sun_base_color, #C9D6FF, f)
env.fog_light_color     = lerp(fog_tint, #AEBEE0, 0.7 * f)
```

Five property writes per frame for 0.30 s. No fullscreen white quad: a lighting-driven flash correctly lights façades from the sky and avoids a photosensitivity spike. Peak screen luminance is clamped to 1.35× the pre-flash frame average; accessibility setting `reduce_flashes` scales the envelope by 0.25. Thunder delay for doc 13: `distance(camera, strike_pos) / 340.0` seconds.

### 2.9b STANDING WATER — doc 07 §2.4, drawn, **shipped 2026-08-20**

Owner: `game/render/flood_view.gd` + `game/shaders/flood.gdshader` + `data/render.json.flood`. Reviewed with `tools/flood_preview.gd` (the real shell, doc 07's own `debug_force_weather` lever, `--phase=rise|peak|recede|dry`, `--reload`); budgeted with `tools/profile_frame.gd --flood=MM --flood-detail=N`. Closes **A91-D-26**; ruled in report 98 **RR-53**.

**The finding this section exists for.** `sim/weather/flood_field.gd` has been integrating `depth_mm` on the utilities cadence since the weather system shipped — 460 `flood_level_changed` in a two-real-hour soak — and **nothing in the tree matched that event type.** §2.9 above is the whole of what the renderer knew about doc 07, and rain is not flooding: `sc_wetness` is one float for the world, and a flood is per land block, outlives the rain that made it, and sits at different bands on blocks a hundred metres apart. The two facts cannot share a channel.

**One MultiMesh, on the road tiles, and nothing else.** Doc 07 §2.4 says only road tiles accumulate; this draws exactly those, so a flooded 128 m block is its ~87 road tiles and not a 128 m blue square over the buildings on it. Every flooded cell in the city shares one `MultiMeshInstance3D` and one material, so the layer costs **+1 draw call while water stands anywhere and +0 when the city is dry** (the node hides itself). `custom_aabb` is world-sized, and it has to be: the sheet LIFTS as the water rises, and a bounds box computed dry would cull the flood at exactly the depth that matters.

**Per-instance contract — two channels, and the other two are empty on purpose.**

| channel | meaning |
|---|---|
| `INSTANCE_CUSTOM.r` | `water01` — doc 07's own `flood_saturation`, `depth_mm / 350`, eased (τ 1.1 s up, 2.6 s down) |
| `INSTANCE_CUSTOM.g` | `wet01` — the dark-wet memory. Rises with the water, falls on τ 20 s |
| `.b`, `.a` | reserved, zero |

`.b` held a per-tile hash seed for one draft, so that "which corner holds the last puddle" would be a fact about the city. **Any function of the instance draws the tile grid.** Coverage has to be a function of WORLD position for two adjacent 8 m quads to read as one puddle — the same rule `water.gdshader` follows for the canal — and the seeded draft painted a wet 8 m lattice over the whole city. It is in the screenshot record beside the fix. Coverage is therefore a function of world position and cell depth and of nothing else, which also makes the picture a pure function of the sim with no seed to persist.

**Coverage, not height, is where the rise reads.** 350 mm of water on an 8 m tile is a few pixels of geometric lift at the camera's 34°–62° pitch band. So depth drives *how much of the tile is wet*, through a world-space noise threshold, and the sheet also rises by `rise_m = 0.20 m` on top of a `base_y_m = 0.11` so that at the impassable band it stands above the 0.25 m kerb the footway sits on. The lift is the confirmation; the coverage is the read. Coverage is deliberately **not linear in depth** — doc 07's bands are 0–39 / 40–99 / 100–199 / 200–349 / 350+, so `standing water`, the band where vehicles start stalling, is only 0.29 of the way to the divisor. `pow(water01, 0.45)` puts the four bands at roughly 20 / 50 / 90 / 100 % of the tile, which is what the bands mean.

**The recede is the second channel.** `wet01` chases the water up on τ 0.8 s and lets go on τ 20 s, so a street that has just drained stays black and glossy for the best part of a minute and its instances stay in the buffer until `wet01` falls under `min_visible` 0.02 (~78 s from full). That tail is the difference between *the water went away* and *there was a flood here*, and it is §2.9's own asymmetric bet (25 s soak / 90 s dry) taken per tile.

**Night is where this feature actually pays, and the first cut got it backwards.** Measured at 22:00 before the night terms existed: a 490 mm flood over an unlit stretch of asphalt was **invisible** — `night_mult 0.55` on an already-dark body put the water *below* the road it was standing on. A wet road at night is LIGHTER than a dry one, because it has stopped diffusing and started mirroring. So three terms, all on `sc_night`, all zero by day: `night_mult 0.80` barely darkens, `night_lift 0.08` adds a cool bounce off the sampled `sc_fog_tint`, and `night_glow 0.055` is the skyglow floor that survives ambient going to zero. Report NIGHT-1's three ideas, aimed the other way.

**Fragment ladder** (`flood.gdshader`'s `detail`, set from `presets.<name>.flood_detail`): **2** ripple normal + puddle noise (four `vnoise`), **1** puddle noise only (one), **0** a flat sheet that fades in (none). Performance ships **0** — at a 0.70 render scale a puddle's ripple was never resolvable. No texture fetch anywhere in the shader, so the "`texture()` outside divergent flow" question does not arise; `detail` is the only branch and it is uniform across the draw.

**Measured** — `tools/profile_frame.gd --flood=350` against `--flood=0`, bench city, balanced, 1920×1080, three runs of 400 frames each:

| pose | dc, no flood | dc, 350 mm | Δ dc | rs gpu, no flood | rs gpu, 350 mm | Δ gpu |
|---|---|---|---|---|---|---|
| Z0 | 95 | 96 | **+1** | 1.920 ms | 2.071 ms | **+0.151 ms** |
| Z1 | 113 | 114 | **+1** | 1.901 | 2.016 | +0.115 |
| Z2 | 196 | 197 | **+1** | 2.926 | 3.053 | +0.127 |

350 mm on every LOW block is the worst case the layer can be asked to draw: **21 cells, 1,827 tiles, +3,654 primitives, one draw call.** Against the branch's +6 draw-call budget at Z2 that is **+1**. Layer CPU at rest is **zero** — the ease snaps when it reaches its target and the buffer is not re-uploaded after that (`tests/test_flood_view.gd` asserts it), and the ripple rides `sc_time` in the shader.

**And the fragment ladder is below the desktop measurement floor.** Z0 `rs gpu` at rung 0 / 1 / 2 is 2.077 / 2.130 / 2.071 ms against 1.920 dry, i.e. the three rungs are within the ±0.05 ms run-to-run spread of each other. On this GPU the layer's cost is the transparent BLEND and the overdraw, not the arithmetic. The rung stays — the Fold frame is fragment-bound and its ALU is a different machine — but it is a governor lever that desktop numbers do not yet justify, and it is on the device list (§9).

### 2.10 Streetlights without hundreds of dynamic lights

One streetlight every 32 m (4 tiles) along road polylines from doc 10. With doc 09's ~87 road tiles per developed block that is **~22 streetlights per chunk**. Lit state is **not** inferred by the renderer: doc 04 emits `StreetlightsChanged(block_id, lit)` per land block, and every streetlight in that chunk shares that one boolean, ramped through the §2.7 envelopes. Four instances across MultiMeshes:

1. `MM_pole` — the cobra head, lit material, NEAR/MEDIUM only. See §2.10.1.
2. `MM_lamp` — 1.6 m billboard, unshaded additive, `EMISSION = lamp_color · emissive_scale · sc_night`. **The only part rendered at FAR**, and what makes a lit street readable from 900 m.
3. `MM_pool` — downward disc, radius 6 m at `y = 0.06`, unshaded additive with radial falloff. Radius `6·(1 + 0.5·sc_wetness)`, energy `×(1 + 0.6·sc_wetness)`. **This fake light pool replaces the dynamic light for 95% of streetlights.**
4. `MM_wetsmear` — mirrored copy of (2).

**Real lights: a small pool.** `LightPool` holds `OmniLight3D`s: range 14 m, energy 1.6, attenuation 1.6, **`shadow_enabled = false` always**, `distance_fade` 55→70 m. Re-bound at 4 Hz to the N nearest streetlights within radius of the camera focus, preferring the camera-facing side, cross-fading energy over 0.25 s so lights never pop.

| preset | street omnis | radius | emergency omnis |
|---|---|---|---|
| Performance | 6 | 55 m | 2 |
| Balanced | 12 | 70 m | 4 |
| High | 20 | 90 m | 6 |

Godot Mobile caps omni lights per object (default 8). With ≤ 20 omnis spread over 90 m at 14 m range, no building is touched by more than ~4. Verified in the on-device checklist (§7.4).

#### 2.10.1 Where the lamps go, and what they look like (`streetlight_placer.gd`, `cobra_head_mesh.gd`) — **shipped 2026-08-20**

The placement rule this replaces was one line in the scene root:

```gdscript
if world.grid.has_flag(x, z, TileGrid.FLAG_ROAD) and (x + z) % 4 == 0:
```

A parity test over the raw tile grid. It honours the 32 m figure above only on average, it stipples lamps along a **diagonal** across the whole city, it stands every pole in the **middle of the carriageway** — on a 16 m avenue, in the middle of four lanes — and it cannot say which way a lamp faces, because it never asked what a road was. Hence *"sticks popping out of the ground"*.

`StreetlightPlacer.place()` reads **the same `RoadSurfaceView.classify()` the carriageway is drawn from**, so a lamp can never disagree with the kerb it is standing on. Four rules, all deterministic and RNG-free (the output is a pure function of the tile grid and the graph, ordered by (y, x, side); doc 00 §5's hashes cannot move):

1. **Corridor lamps** every `spacing_tiles` = 4 (**32 m**, the authored `world.streetlight_spacing_m`), phase taken off the tile index along the corridor axis rather than off a per-edge counter — doc 10 contracts a corridor into as many edges as it has junctions, so a per-edge counter restarts at every cross street and the pitch visibly stutters through a grid city.
2. **Alternating kerbs**, swapping every lamp. If the chosen side carries no footway the other is taken; if neither does, the lamp is **skipped** rather than planted in a traffic lane.
3. **Dual carriageways stagger**: each half lights every `2 × spacing` offset by `spacing` from its twin, so a 16 m avenue is lit from alternating kerbs at the single-carriageway pitch — which is how a real arterial is lit.
4. **Corners**, where a tile carries two adjacent footways (a bend, a cul-de-sac head). Explicitly *not* "a lamp on each corner of a junction": a one-tile junction has three or four road neighbours and so **at most one kerb**, no corner to stand a pole on, and standing one in the box anyway is the exact defect this pass removes. A **junction guarantee** covers the gap instead — any box left with no lamp within `spacing_tiles` gets one forced onto its first kerbed approach. Measured on the founding city: 51 of 53 boxes were already covered; the two that were not are the avenue-meets-avenue crossings at (63,48) and (48,63), the two widest expanses of asphalt on the map, dark because both crossing corridors put their nearest lamp a full stagger period away.

Founding city: **130 lamps**, 4 of them corner lamps, against the parity rule's **207** — 37 % fewer poles, all of them on a kerb, all of them facing a carriageway. Benchmark city: **469** against 828.

**The mesh.** `CobraHeadMesh` builds one ArrayMesh every lamp in the city shares: a mast standing on its own origin (so the baked grime ramp lands at the footway wherever it is placed), the 0.30 m base collar, a four-segment arm swept as a quarter-ellipse that leaves the mast vertically and arrives over the carriageway horizontal, and a tapered luminaire with a pale lens on its underside. **76 triangles** against the old stick's 34, paid once on the shared mesh; the arm is baked along local **+X** and each instance yaws it toward its own roadway. Founding city total: 9,880 pole triangles, against the parity rule's 207 x 34 = 7,038 — 40 % more triangles for 37 % fewer poles.

**Lamps are LIVE, not boot-time — shipped 2026-08-20** (closes this section's open question 1). A road the player laid used to get asphalt on the next frame and lamps on the next LOAD, because `RenderStateModel` could ADD a streetlight and nothing else: there was no way to retire a record, so a bulldozed lamp kept ramping for the rest of the session and kept its id in `BlockRec.streetlights` for the rest of the session's blackouts. Two halves:

* **`RenderStateModel.remove_streetlight(id)`** retires the record and takes the id off the block roster. `add_streetlight` is now idempotent as well, and that is the point rather than a nicety: it appended to `BlockRec.streetlights` unconditionally, so re-registering one id put it in the roster **twice** and every ramp that block drove — §2.7.2's go-dark stagger, §2.7.3's relight sweep, the terminal envelope fold — hit that lamp twice in the same frame. A live re-place pass re-registers lamps by construction, so that double-stutter is the defect that would otherwise have shipped WITH this feature.
* **`StreetlightView.apply_lamps()`** diffs a fresh `StreetlightPlacer.place()` against the live set. The identity is the **placement key** — `tile + kerb side`, packed by `StreetlightPlacer.key_of` — and never the row's ordinal id, because `place()` numbers its rows in (y, x, side) order: one new tile at the top-left renumbers every lamp below it, so an id-keyed diff would retire and re-create the whole city for one edit, restarting every `anim_phase` and every ramp in it. A key in both sets **keeps its id**. Only the chunks whose roster or geometry moved are re-uploaded; a re-place that changes nothing returns all-`kept` and touches no buffer.

The boot pass adopts the placer's own numbering exactly (it allocates from the same base in the same order), so no city that was already running has an `anim_phase` moved by the diff existing. Measured on a 30-tile corridor extended by twelve tiles: the new run is lit, **every standing lamp keeps its id and its position**, and the one lamp that is legitimately re-placed is the old cul-de-sac head — a dead end carries two adjacent footways and takes a corner lamp; once the corridor runs through it is an ordinary two-kerb tile.

**STREET-1 — the pool that was buried.** `pool_y_m` was **0.06** and the road slab's top is **0.10**: every ground pool in the game failed the depth test against the carriageway it was lighting, and what survived was the ring of it that spilled onto the block either side. A doughnut of light around a dark road is a large part of why a lamp read as a stick. The disc now rides just over the **footway** — the highest surface under a lamp — so one pool covers kerb, gutter and both lanes, and the billboard, the pool and the wet smear all hang off the **luminaire**, out at the end of the arm, instead of off the top of the mast. The 0.155 m the disc floats above the asphalt is invisible: at Z0's 34° of pitch that is 0.23 m of parallax across a 16 m disc with no hard edge anywhere in it.

### 2.10b The distribution layer — pads, service drops and distress, **shipped 2026-08-20**

Doc 04 has owned plants, substations, feeders, transformers and per-building service since Wave 1. Until this pass **none of the distribution end of it rendered.** A player could read an overlay tint and an Infrastructure row, but could not see where the transformer serving their block stood, could not see which buildings it fed, and could not see it cook. The two grid nodes that ARE buildings — `substation` and `power_facility` (report 98 C-30) — have been drawn by `CityView` since Wave 6 and are untouched here; a transformer is **not** a building (doc 04 §2.1: one tile, `FLAG_OCCUPIED`, no footprint row), which is exactly why nothing was drawing it.

Three elements, in `game/render/power_infra_{model,feed,view}.gd` and `game/shaders/power_{pad,wire,smoke}.gdshader`.

**1. Pads.** A pad-mounted transformer at every `transformer` component's tile centre, at every zoom: concrete apron + lip, green-grey cabinet, overhanging lid, a proud radiator panel with end ribs on each flank, three HV bushings on the lid. **204 triangles on one shared mesh.** The seven fins inside each radiator panel are *shaded*, not modelled (`fin_pitch_m` 0.135) — geometry buys the silhouette, a periodic AO/roughness band buys the corrugation, and at Z0 one fin is ~3 px, which is the scale at which triangles cost and a groove term does not. Vertex `COLOR.a` carries `part / 8` (concrete / cabinet / lid / fin / porcelain), the same 8-bit round-trip trick §2.6's level atlas plays with `COLOR.a`; eight parts is the ceiling and a ninth would collide.

**Orientation is doc 10's, not a hash.** The doors face the street: the four orthogonal neighbours are tested in the fixed order −Z, +X, +Z, −X and the first road tile wins, then the four diagonals, then a fixed yaw. A corner pad therefore resolves the same way on every run and after every load. A random spin would have been cheaper and is wrong — a randomly-turned cabinet in an otherwise aligned row is *more* conspicuous than an aligned one facing nowhere.

**2. Service drops.** One catenary-sagged wire from each pad's LV riser to each building `PowerGrid.attachment_map()` says it feeds, landing on the point of the building's footprint rectangle nearest the riser, `service_clearance_m` off the wall, at `clamp(height − 0.90, 2.60, 5.20)` m. Deterministic from the footprint alone — no per-building authored anchor — which is what makes the same city draw the same wires after a load. An UNSERVED building has no row in the attachment map and therefore **no wire**, which is the honest picture.

One instance is one **whole span**: a flat 8-segment strip that `power_wire.gdshader` turns into a camera-facing ribbon, 16 triangles, with the sag as a vertex function of `t` and a round cross-section (and its anti-aliasing) out of the fragment stage. The alternative — one instance per segment of a tessellated tube — was 8× the instances and 3× the triangles for a cable three pixels wide.

**3. Distress, driven by doc 04's own state.** Bands, and the numbers behind them, are read from `PowerGrid` and never re-authored here:

| band | condition | look |
|---|---|---|
| CLEAN | energized, `r <` `OVERLAY_WARNING_R` 0.75 | clean cabinet, no heat |
| STRESSED | `r ≥ 0.75`, **or** winding past §2.6's hazard knee 85 °C, **or** `condition < 0.4226` | fins warm, soot from age |
| TROUBLED | `r ≥` `OVERLAY_CRITICAL_R` 0.95 | wisp of smoke, fins glowing |
| SEVERE | `r ≥ 1.399` | heavy plume + intermittent arcing |
| DARK | OPEN or de-energized | nothing: no hum, no heat, no smoke |
| FAILED | `state == FAILED` | charred, dead, a thin smoulder |

**The SEVERE band is solved, not picked.** §2.6 gives `θ_ss = θ_rated·r²` and `hazard = h_cold + h_hot·stress³` per game-hour; setting hazard = 1.0/gh (odds-on to burn out inside the hour) and inverting gives `stress = ((1 − h_cold)/h_hot)^⅓` and `r = √((knee + span·stress − ambient)/θ_rated)`. With the shipped transformer row (θ_rated 55, knee 85, span 60, h_hot 2.00, h_cold 0.00012) at 25 °C that is **r = 1.399**. `PowerInfraModel.severe_ratio()` computes it at boot, so retuning doc 04 §2.6 moves the smoke with it and there is no second copy to forget. The worn line is the condition at which §2.6's `1 + 3(1−c)²` multiplier has **doubled**: `c = 1 − √⅓ = 0.4226`.

**Smoke and sparks are one premultiplied-alpha MultiMesh, not particle nodes.** With `blend_premul_alpha` a fragment that writes ALBEDO and leaves ALPHA at 0 is purely additive (a spark) and one that writes `colour·a` with ALPHA = a blends normally (smoke) — two blend modes, one pipeline state, **one draw call however bad the city gets**, and the node is hidden outright while nothing is in trouble. A `GPUParticles3D` per troubled transformer would have been one node, one process callback and one draw call *each* on a layer whose whole budget is a couple of calls, and its state would be wall-clock driven, so two runs of the same save would not look the same. Every puff here is a pure function of `sc_time` and a per-instance phase derived from the component id (FNV-1a, mod 2²⁴ so the float is exact), which is also what makes it survive a save/load round trip.

**The ramps are asymmetric on purpose.** `char_rise_s` 0.55 against `char_fall_s` 2.40: a failure is an EVENT and lands in half a second; a repair is a crew leaving and washes clean over a couple of time constants. The player asked to *see* the fix land, and a step change reads as a glitch.

**Draw-call shape — why this layer is not bucketed per chunk.** §2.13 budgets it at +10 calls at Z2, and Z2 has 16 chunks in view (the derivation below), so a per-chunk pad bucket would spend 16 calls on 144 cabinets before a single wire was drawn. The layer is bucketed by what its elements actually need instead:

* **Pads: one MultiMesh for the whole city.** 144 instances × 204 tris = 29,376 triangles, under a third of one bench chunk's buildings, and one call at every zoom. There is nothing worth culling — the buffer is smaller than the cull test's own bookkeeping. It is the one place this layer trades primitives for calls, and the measurement below says the trade is free. **Shadow casting is authored, not hard-coded** (`power_infra.pad_shadows`, default `true`): §2.13's Fold pass prices it at **+1 draw call in the sun's shadow pass and no measurable GPU time on 144 cabinets in full sun**, and it cannot be priced at all at hour 21 — the sun is below the horizon there and the pass is empty, which is how the first attempt at the measurement came back as noise.
* **Wires: one MultiMesh per chunk, submitted only when close.**
* **Distress: one MultiMesh, smoke and sparks together, hidden when idle.**

**The wire gate is the Z1 camera height, not a taste call.** `wire_fade_end_m` = 58 m is BOTH the shader's fade-out distance and the CPU-side bucket gate, so a bucket is dropped only once every wire in it is already zero-width and the gate cannot be seen switching. 58 is chosen because §2.5's Z1 pose is D 86.9 m at 48°, i.e. the camera sits `86.9·sin 48° = 64.6` m above grade and **nothing on the ground is within 58 m of it**. The brief was "visible when you look, never noisy at Z1+", and that is that sentence as a number: at Z0 (camera 10.1 m up, 14.9 m back) every wire in view is inside `wire_fade_begin_m` 26 m and fully drawn; by Z1 the layer is not merely faint but zero buckets submitted. 58 also sits comfortably inside §2.5's 150 m NEAR boundary, so "wires are a NEAR element" holds by construction rather than by mirroring the tier table into a second place.

**Measured — `tools/profile_frame.gd`, bench city (1,500 buildings, 144 transformers), 1920×1080, Balanced, hour 21, 120 frames after 60 warm-up. The A/B is `--no-power-infra`, so the two runs differ in nothing else.** *(§2.13's Fold pass, report RR-28: this table's GPU column was in fact rendered at **1280×720** — the harness silently ignored `--resolution` until 2026-08-20 — and hour 21 has the sun below the horizon, so it does not price the pad SHADOW at all. The draw-call and wire-bucket columns stand as written; §2.13's daylight pad-shadow A/B is the shadow number.)*

| pose | draw calls without | with, grid healthy | with, **all 144 SEVERE** | wire buckets | GPU ms without → with |
|---|---|---|---|---|---|
| Z0 D 18 m | 92 | 94 | 94 | 4 | 0.635 → 0.656 |
| Z1 D 86.9 m | 111 | 112 | 112 | **0** | 2.183 → 2.134 |
| Z2 D 420 m | 194 | **195** | **196** | **0** | 3.092 → 3.033 |

**+1 draw call at Z2 with a healthy grid, +2 with every transformer in the city on fire, against the +10 budget.** Primitives rise by a flat 29,376 at every pose (the pad buffer, which is not culled by design); the RenderingServer's own GPU column does not move outside run-to-run noise at any pose. Worst-case plume is `puff_cap` 132 billboards, spent worst-first — SEVERE before FAILED before TROUBLED, then by id — so a city with forty warm transformers and one on fire always spends its billboards on the fire. The governor's `particle_ratio` knob scales both `puff_cap` and `puffs_per_pad` and is the **only** knob that reaches this layer: a player on a thermally throttled phone still has to be able to see where their transformers are.

**A settled city uploads nothing.** Every animation here — the fin flicker, the smoke loop, the overlay pulse — is a shader function of `sc_time`, so `PowerInfraModel.take_dirty()` returns false and not one `set_instance_custom_data` runs while no ramp is moving. That is what lets the pad buffer be city-wide with no write budget behind it (§2.2's `writes_per_frame` is the building layer's).

**Two scars worth keeping.** `VIEWPORT_SIZE` and `PROJECTION_MATRIX[1][1]` both COMPILE in a spatial **vertex** shader and neither carries a usable value there on Forward Mobile: their product measured as zero, took the shader's own `max(1.0, …)` guard, and widened every service drop to about 130 m of near-opaque black — the entire screen washed out at any close zoom. The screen-space term is now `2·tan(fov_y/2)/height` computed on the CPU from doc 11's own authored FOV (`PowerInfraView._sync_viewport_h`), with `wire_max_radius_m` 0.30 standing behind it as a hard metre ceiling so no future plumbing mistake can repaint the screen. `tests/test_power_infra.gd` locks both.

### 2.11 Overlay mechanism (doc 12 owns content)

`sc_overlay_mode ≠ 0` switches every building and ground shader into overlay mode:

```glsl
vec3 tint = sc_overlay_colors[int(overlay)].rgb;
ALBEDO    = mix(vec3(dot(ALBEDO, vec3(0.299,0.587,0.114))), tint, 0.55);
EMISSION *= 0.40;
```

Network lines (power feeders, water mains, congestion) draw as **one `ImmediateMesh` per overlay layer per 4×4-chunk super-block**: line strips, unshaded additive, `render_priority = 5`, no depth write, UV scrolled by `sc_time · flow_speed` where `flow_speed` is signed by real flow direction (spec §13.5 "animated power flow"). Rebuilt only on `network_topology_changed`; the animation itself is free. Budget ≤ 6 extra draw calls at any zoom.

**Mode 1 (POWER) now lights the PHYSICAL network too, not only the building tints (§2.10b, shipped 2026-08-20).** `power_pad.gdshader` and `power_wire.gdshader` read the same `sc_overlay_mode` global, decode the overlay field with `mod(floor(packed / 112.0), 4.0)` — `building.gdshader`'s expression, character for character, over the same 112 stride — and wear `building.gdshader`'s palette and blend weights, so a pad and the building it feeds carry the same hue for the same state. Two things are POWER-specific: a pad carries an **emission floor** under the grey wash (a 1.5 m cabinet otherwise disappears into the road where a forty-metre lit façade does not), and a wire's minimum screen width is multiplied by `overlay_px_gain` 2.3, because the wire is the only thing on screen that says *which transformer feeds which building* and a 1.4 px dark thread says it to nobody. The wire's NEAR gate is unchanged in POWER mode — the overlay makes the drops thicker and brighter within the same 58 m, it does not extend them. Under WATER/POLICE/FIRE both surfaces desaturate and thin out with the rest of the world, because a pad is world, not that mode's data. The mode integer is only ever **read**; doc 12's rail owns writing it.

### 2.12 Vehicles

**Civilian traffic — cosmetic, MultiMesh, render-side only** (constitution §8). **Doc 10** (roads, routing & traffic) supplies per-edge `density ∈ [0,1]` and cached polylines.

**The pose feed is ONE packed event per tick (doc 91 D-10, shipped 2026-08-19).** `sim/roads/traffic_feed.gd` used to publish a `vehicle_state` dictionary per vehicle per tick — measured at **79.3% of every event on the bus**, and the largest allocator in a running city. It now publishes a single `traffic_snapshot{count, ids, edge_ids, kinds, flags, pose}` carrying every civilian pose in parallel `Packed*Array` columns (`pose` is 4 floats per vehicle: world x, world z, heading, speed; `flags` is a bitfield with headlights and dark-signal bits; civilians carry no siren or light bar, so neither is in the format). `sim/roads/traffic_snapshot.gd` owns the layout and both sides index it through the same constants. `vehicle_spawned` and `vehicle_despawned` stay individual — they are rare, they carry identity rather than motion, and the renderer allocates and retires a pooled record off each one. **The cadence is unchanged at 4 Hz**: the Hermite blend below interpolates between poses at Δt = 0.25 s, and a once-a-game-minute feed would be a 16× longer gap than it is authored for. The saving is the 256-to-1 collapse of the event *count*, not a cadence cut. Content and order are identical (ascending vehicle id), so the stream is as deterministic as it was, and the sim's own state is untouched — proved by the `state_hash` baseline, not asserted. `TrafficVisualizer` keeps ghost cars `(edge_id, s, speed, class)`, advances `s += speed·delta/edge_length`, respawns onto a weighted-random edge on completion. Spawn count per edge = `round(density · edge_length_m / 45.0)` (= `civ_spawn_per_m 0.0222`), capped by preset, only for edges within `civ_visible_radius_m` of focus. Headlights are a paired additive cone quad in `MM_headlights` with `visible_instance_count = 0` when `sc_night < 0.15`.

`civ_visible_radius_m` is **re-derived from the new Z2 pose** (report R-17), because it must cover everything the camera can see at max zoom. At Z2 the camera nadir sits `420·cos 62° = 197.2` m behind the focus and the visible ground runs from 52.1 m to 411.8 m ahead of the nadir — i.e. from `52.1 − 197.2 = −145.1` m to `411.8 − 197.2 = +214.6` m along the view axis relative to focus, and out to `717.1 / 2 = 358.6` m laterally. Worst-case distance from focus: `sqrt(214.6² + 358.6²) = sqrt(46,053 + 128,594) = sqrt(174,647) = 418.0` m. **`civ_visible_radius_m` moves 400 → 420 m**, which covers the far corner with 2 m to spare. (The old 400 m was sized against the old 560 m ceiling and under-covered by 18 m; the coincidence that the number barely moved is because a 420 m orbit at 62° sees roughly as much ground as a 560 m orbit did off-centre.)

| preset | cars | vans | trucks | headlight pairs | emergency nodes | **body shadows** |
|---|---|---|---|---|---|---|
| Performance | 64 | 20 | 12 | 96 | 12 | **off** |
| Balanced | 160 | 60 | 36 | 256 | 20 | **off** |
| High | 320 | 120 | 72 | 512 | 28 | **on** |

**Vehicle shadows are off on mobile (`vehicles.cast_shadows = false`, overridden per preset by `vehicle_shadows`).** A vehicle layer's custom AABB is world-sized — it has to be, because instances are written straight into the MultiMesh buffer and never update the auto AABB — so **every** body layer intersects **every** directional shadow split and is re-drawn once per split whether or not a car is standing in it. At Balanced (2 splits) that is 7 extra draw calls for shadows nobody can see from 87 m up; at High (4 splits) it is 14, which High can afford and takes. The nine remaining `VehicleView` tuning constants (`road_top_m`, `lane_offset_m`, `fade_seconds`, `interp_blend_seconds`, `headlight_cone_m`, `headlight_cone_energy`, `headlight_color`, `lightbar_amber`, `lightbar_amber_pale`) are in `data/render.json`'s `vehicles` block at the same values, with the script constants kept as the fallback.

**Every colour in this renderer is now decoded exactly once, and the LAST place that was not true was the VERTEX** (2026-09-01, report 98 RR-95, doc 93 §X1, closing doc 91 `A91-D-36`'s `awaiting_consumer` half). RR-91 fixed the INSTANCE half — a MultiMesh instance colour takes no sRGB decode, so `VehicleView._paint_for` and `ConstructionActivity._plant_paint` were rendering the whole fleet and every machine about two stops light — and filed the vertex half, because a vertex colour takes no decode either and several constants are used both ways. The seam is now one `srgb_to_linear` in `ConstructionRigMesh._push` (which `StreetLifeMesh` inherits), one in `VehicleMesh._push`, and **one in `ConstructionSiteView.PropMesh._push`, which the hoarding, the crane, the scaffold, the skips AND doc 04's transformer pad are all built with** (`power_pad.gdshader` reads `COLOR.rgb` raw, and a `StandardMaterial3D` with the project's default `vertex_color_is_srgb = false` does too): **at build time, once per vertex, never per frame, and never at the CONSTANT** — `SAND` / `GRAVEL` / `REBAR` are read as instance tints by `ConstructionActivity._stock_linear`, which already decodes them, and converting the constant would decode them twice. The grep that closed the vertex half also found **three instance seams RR-91's closing note had missed** — the hoarding panels and posts (`fence_paint` / `post_paint`), doc 12 §2.5's traffic band (`RoadOverlayView._build_band_paint`, now the legend chip's colour by construction) and the road-drawing ghost (`PathGhostView.tint_for`, filed with a named consumer, report 98 RR-95 (continued)) — and one builder that was recorded as correctly left alone and was NOT: `CobraHeadMesh`'s vertex colour is a grime ramp MULTIPLYING two authored hex tints (`COWL_TINT`, `LENS_TINT`), reaching the shader through `ARRAY_COLOR` and not through the `albedo_color` that note also claimed — fixed 2026-09-02, with the ruling that a channel carrying an authored colour TIMES a computed multiplier decodes the colour and not the multiplier (a ramp is a reflectance multiplier and belongs in linear; decoding the product takes the mast's foot from linear 0.41 to 0.18). Neither cobra constant moved — both are near-white and white is a fixed point of the decode. **The guard is a CENSUS now, not a list**: `test_every_procedural_mesh_decodes_its_authored_vertex_colour` greps `game/render/` for `Mesh.ARRAY_COLOR` and requires `srgb_to_linear` in every file that has one, because a hand-kept list is what missed this file twice. **Two hexes moved with the pictures and the rest did not**: `DARK` `#1D2022` → `#424548` and `TYRE` `#161618` → `#333336`, in both mesh files, because decoded from their authored values they land at linear 0.0125 and 0.0069 — **below the 0.02-linear shaded carriageway**, so an excavator's track band stopped being an object on the road and became a hole cut in it, and a tyre went blacker than fresh asphalt and took the `dark` atlas cell's tread ribs with it. §2.16's plant, §2.12's fleet, §2.17's bodies, the site props and the pads were all re-judged in one screenshot pass (report 98 RR-95 have the census) and the rest of the palette survives it — the correction is a darkening and a darkening is what the fix is FOR.

**Emergency/service vehicles — individual nodes, real routing** (constitution §8). **Doc 06** (incidents, dispatch & fleets) emits `vehicle_state` at 4 Hz, carrying explicit `speed` and `heading` fields (report C-67, ruled). Pooled `VehicleView` = `Body` (MeshInstance3D, ≤ 180 tris, dept colour) + `LightBar` (2 emissive quads) + `Beacon` (`OmniLight3D`, only while checked out from the emergency light budget).

Light bar: `EMISSION = mix(red, blue, step(0.5, fract(sc_time*2.2 + phase))) * (lightbar ? 3.5 : 0.0)` — 2.2 Hz, phase-offset per vehicle so a convoy does not strobe in lockstep.

**Interpolation:** `pos = hermite(p_prev, v_prev·Δt, p_curr, v_curr·Δt, alpha)` with `Δt = 0.25 s`. Hermite not lerp, because vehicles turn corners between ticks and lerp visibly cuts corners at 4 Hz. Heading uses shortest-arc angular lerp. Displacement > 40 m between ticks (respawn/route reset) snaps instead.

### 2.13 Performance budgets, device matrix, adaptive governor

| | **Performance** | **Balanced** | **High** |
|---|---|---|---|
| Target FPS | 30 | 60 | 60 |
| GPU / CPU-main budget | 24.0 / 6.0 ms | 13.0 / 4.0 ms | 13.0 / 4.0 ms |
| `render_scale` of 1080p | 0.70 (756p) | 0.85 (918p) | 1.00 |
| MSAA 3D | off + FXAA | 2× | 2× |
| Draw calls (incl. shadow pass) | ≤ 180 | ≤ 320 | ≤ 520 |
| Visible building instances | ≤ 3,000 | ≤ 7,000 | ≤ 14,000 |
| Resident chunks / max NEAR | 24 / **3** | 40 / **6** | 64 / **8** |
| Far cull distance | 900 m | 1,200 m | 1,500 m |
| Shadow-casting lights | 0 (blob shadows) | 1 sun, 2 splits, 2048, 150 m | 1 sun, 4 splits, 4096, 180 m |
| Glow levels | 3,4 | 2,3,4 | 1,2,3,4,5 |
| Glow intensity / bloom | 0.75 / 0.03 | 0.90 / 0.05 | 1.00 / 0.07 |
| Glow HDR threshold (day→night) | 1.10→0.85 | 1.05→0.78 | 1.00→0.75 |
| Reflection probe / Moon / Adjustments | no / no / no | no / yes / yes | yes / yes / yes |
| VRAM / PSS budget | 220 / 700 MB | 320 / 900 MB | 420 / 1,300 MB |

**Performance replaces shadows with blob shadows:** `MM_blob`, one dark quad per building at `y = 0.04`, footprint × 1.15, alpha `0.35·(1 − sc_night·0.6)`. The difference between "buildings sit on the ground" and "buildings float". **SHIPPED 2026-09-01** (`game/render/city_view.gd`, `game/shaders/blob_shadow.gdshader`; report 98 RR-96, doc 93 §X2) — and three clauses of the sentence above it are corrected by the build:

* **ONE draw call city-wide, not "one per NEAR/MEDIUM chunk".** The per-chunk shape this paragraph priced was built first, because that is what it asked for, and measured: Performance's chunk census on the benchmark city is not the worked example's 3 NEAR + 3 MEDIUM, it is **10 NEAR + 26 MEDIUM at Z0** (`--focus=52,44`; the earlier 12 + 24 was the authored city centre, which puts the Z0 camera inside a tower), so the layer cost **36 draw calls at Z0** against a budget the city is already over. City-wide costs **one, at every pose**, measured. This is §2.1.2's road-surface ruling on a second layer: a layer with no per-chunk state worth culling on buys nothing from per-chunk buckets and pays a call each.
* **Every building is in the buffer, whatever tier its chunk is.** That makes the buffer a function of the ROSTER rather than of the camera: scrubbing across a tier boundary rewrites nothing, and no block drops its shadow as it crosses one. The far field costs 2 triangles and a sub-pixel quad per building.
* **The falloff is a BOX, not a radial gradient.** A radial gradient under a rectangular footprint leaves the building's four corners unshaded and puts penumbra where the wall is. The mask is the Chebyshev distance `max(|u|,|v|)` and `blob_core` is **derived** as `1 / footprint_scale`, so the solid region is exactly the footprint and the ramp is exactly the 15 % overhang — the overhang IS the penumbra and there is no second number to tune.

**Measured, bench city, Performance, hour 13, `--focus=52,44`, 1920×1080,
`--blob=0` vs `--blob=1` (the two runs differ in nothing else):**

| pose | dc, blob off → on | primitives, off → on | `rs gpu`, off → on |
|---|---|---|---|
| Z0 | **89 → 90** | 89,822 → 92,822 | 0.585 → 0.586 ms |
| Z1 | **123 → 124** | 95,494 → 98,494 | 0.741 → 0.742 ms |
| Z2 | **196 → 197** | 261,464 → 264,464 | 0.837 → 0.843 ms |

**One draw call and +3,000 primitives at every pose** — 1,500 buildings × 2
triangles, exactly the roster and not a function of the camera. *(Note that
these draw-call bases are far below the figures the first draft of this section
published: those were taken before §2.13b wired `shadows: false`, so
Performance was still paying a shadow pass it had authored itself out of. The
`0 → 1` delta is the same either way.)* **`rs gpu` is reported and not
claimed:** the in-pair delta is 0.001–0.006 ms, but the same configuration
measured 0.837 and 1.228 ms at Z2 in two runs an hour apart on a workstation
carrying sibling suites — a ±0.4 ms run-to-run band swamps a 0.006 ms effect,
so the honest statement is "below this rig's noise floor" and the number that
matters belongs to a Fold session. Balanced and High are unchanged because
`enabled_presets` names neither: `blob_draw_calls()` is **0 at every pose** on
both, printed on the harness's `BLOB SHADOWS` line in every run above. A
settled city uploads the buffer **zero** times: it is rebuilt every frame and
handed to the server only when it differs (`PackedFloat32Array ==` is a native
compare), the same bargain §2.10b's pad buffer strikes.

**Alpha 0.35 verified against pictures, and then against the arithmetic.** The
screen-space effect, same two arms, `--shots` at each pose:

| pose | frame moved | peak darkening | mean over the moved pixels |
|---|---|---|---|
| Z0 | 39,609 px (**1.91 %**) | 39/255 | 11.1/255 |
| Z1 | 49,002 px (**2.36 %**) | 43/255 | 14.6/255 |
| Z2 | 69,468 px (**3.35 %**) | 49/255 | 10.3/255 |

Screen deltas alone cannot confirm an alpha, because AgX sits between the blend
and the pixel. Linearising both frames (undoing the sRGB transfer) and taking
the ratio over the decal gives **p5 = 0.630 / 0.574 / 0.653** at Z0 / Z1 / Z2
against the **0.650** that `blend_mix` toward black at α = 0.35 predicts — the
match is the verification. The deeper p1 tail (0.457 / 0.423 / 0.521) is where
two neighbouring decals OVERLAP, and 0.65² = **0.42** is exactly where that
tail sits, which is the second, independent check on the same number. Z2 is
where the layer earns most: a city of flat boxes on a flat plane becomes a city
of blocks standing on one.

**The same block has a second consumer, on a different gate.** §2.17's street bodies read the LOOK keys (`y_m`, `footprint_scale`, `body_alpha`, `night_fade`, `body_m`, `body_lift_m`) and take their on/off from the preset's `vehicle_shadows` **inverted** — blob when real is off — rather than from `enabled_presets`, which stays the building decal's alone. That is not an inconsistency, it is the rule: a body is a dynamic object, so it takes the dynamic-shadow knob, and one knob deciding both is what makes "no real shadow and no blob either" unreachable. That state is what shipped in Wave 14 and it is why every crook at Z0 read as a sticker printed on the pavement (report 98 RR-90). ~~The `MM_blob` building layer itself is still unbuilt; `enabled_presets` is waiting for it.~~ **Built 2026-09-01 (RR-96); `enabled_presets` is read by `CityView` and by nothing else, and `body_alpha` / `body_m` / `body_lift_m` are read by `StreetLifeModel` and by nothing else. The two consumers are now both live and the split is enforced by `tests/test_render_polish.gd` section 6 and `tests/test_street_life.gd` section 10.**

**The two decals do NOT share a shader, and that is a decision rather than an accident.** §2.17's blob is a sixth mode on the street fx buffer because it is one of six flat quads a per-frame pool is already writing; §2.11's is its own `blob_shadow.gdshader` because (a) the fx buffer is rewritten every frame for objects that WALK while a building decal moves only when a building does, (b) the fx shader's one unconditional `texture(glyph_page, …)` fetch is right for five of its six modes and would be paid by every fragment of every building decal on the LOWEST tier for nothing, and (c) the two gates differ and sharing a shader would not merge them, only hide the split. The full argument is in that shader's header.

**What §2.11's decal cannot do, measured** (report 98 RR-97): it is `blend_mix`, so it darkens what is behind it by a FRACTION. On the footway that is a 40/255 mark; on the shaded carriageway, which sits near **0.026 linear**, the same alpha is a 15/255 mark. That is the whole of street-polish q4 and §2.1.2's own tint A/B carries it.

**Standing water costs one call, at every pose, in the worst case there is** (§2.9b, shipped 2026-08-20). `--flood=350` against `--flood=0` on the bench city, balanced: `dc` 95→96 / 113→114 / 196→197 at Z0/Z1/Z2, `rs gpu` +0.151 / +0.115 / +0.127 ms, `rs cpu` unmoved. That is 21 flooded land blocks, 1,827 tiles and 3,654 primitives in ONE MultiMesh — the flood field has no larger state, because 350 mm is doc 07's top band and only LOW blocks accumulate. `presets.<name>.flood_detail` is its fragment rung (Performance 0, Balanced 2, High 2) and the three rungs are currently inside each other's measurement noise on desktop; see §2.9b.

#### Worked example — frustum footprint and draw calls (re-derived, report R-17 / C-63)

*This whole subsection is regenerated against the ruled camera: `FOV 40°` vertical, near 1, far 1600 (this doc), `D_MIN 18`, `D_MAX 420`, `pitch 34°→62°` (doc 12). Every row of the previous derivation used `D = 60/180/560` and `pitch 40/50/62` and is void.*

**Generating formulas.** For a pose with distance `D` and pitch `p` (elevation above the ground plane), camera height `h = D·sin p`, and the nadir sits `D·cos p` behind the focus. With vertical FOV `40°` the half-angle is `20°`, so the frustum's top and bottom edges strike the ground at depression angles `p − 20°` and `p + 20°`:

```
r_near  = h / tan(p + 20°)           horizontal distance, nadir → near ground edge
r_far   = h / tan(p − 20°)           horizontal distance, nadir → far  ground edge
s(r)    = sqrt(r² + h²)              slant range, camera → that ground point
w(r)    = 2 · s(r) · tan(hfov/2)     ground width at that depth
area    = 0.5 · (w_near + w_far) · (r_far − r_near)
```

Horizontal FOV at 16:9 from a 40° vertical: `tan(hfov/2) = tan 20° · 16/9 = 0.36397 · 1.7778 = 0.64706` → `hfov/2 = 32.9°`, `hfov = 65.9°`.

**Pose Z2 — `D = 420`, `p = 62°` (max zoom, the pose C-63 forced the re-derivation for).**

```
h        = 420 · sin 62° = 420 · 0.88295 = 370.8 m
nadir    = 420 · cos 62° = 420 · 0.46947 = 197.2 m behind focus
r_near   = 370.8 / tan 82° = 370.8 / 7.11537 =  52.1 m
r_far    = 370.8 / tan 42° = 370.8 / 0.90040 = 411.8 m      depth = 359.7 m
s_near   = sqrt(52.1² + 370.8²)  = sqrt(2,714 + 137,493)  = 374.4 m
s_far    = sqrt(411.8² + 370.8²) = sqrt(169,579 + 137,493) = 554.1 m
w_near   = 2 · 374.4 · 0.64706 = 484.5 m
w_far    = 2 · 554.1 · 0.64706 = 717.1 m
area     = 0.5 · (484.5 + 717.1) · 359.7 = 0.5 · 1,201.6 · 359.7 = 216,108 m²
         = 216,108 / 16,384 = 13.19 land blocks of area
```

**The 499 m figure in the old §2.5 and the "everything is FAR" claim are both dead.** The nearest ground the camera can see at Z2 is `s_near = 374.4` m away, and LOD distance is measured to the nearest point of the chunk's *ground-plane* AABB (§2.5), so the nearest chunk row tiers at ≈ 374 m — **MEDIUM** (`≤ 420`), not FAR.

Tier boundary at Z2: a chunk is MEDIUM while `sqrt(r² + 370.8²) ≤ 420`, i.e. `r ≤ sqrt(176,400 − 137,493) = sqrt(38,907) = 197.3` m.

**Chunk rows (regenerated, report RR-12).** Chunks are 128 m (constitution §6), so the rows the frustum crosses are spaced exactly 128 m apart starting at the near ground edge `r_near = 52.1`:

```
row A :  r ∈ [ 52.1, 180.0 )        origin 52.1
row B :  r ∈ [180.0, 308.0 )        origin 52.1 + 128 = 180.0
row C :  r ∈ [308.0, 411.9 ]        origin 180.0 + 128 = 308.0, clipped by r_far = 411.9
row D :  origin would be 308.0 + 128 = 436.0 m  >  r_far 411.9 m  →  DOES NOT EXIST
```

*The former row D at `r = 412` is deleted (report RR-12).* `412` is `308 + 104` — it was the trapezoid's far **edge** mistaken for a row **origin**. No fourth chunk row can intersect this frustum: the third row already runs out at `r_far`, and the next 128 m row starts 24.1 m beyond it.

Ground width per row from `w(r) = 2·sqrt(r² + h²)·0.64706`:

```
w( 52.1) = 2 · 374.4 · 0.64706 = 484.6 m
w(180.0) = 2 · 412.2 · 0.64706 = 533.4 m
w(308.0) = 2 · 482.1 · 0.64706 = 623.8 m
w(411.9) = 2 · 554.2 · 0.64706 = 717.2 m
```

| chunk row (nearest edge `r`) | LOD distance | tier | ground width near→far | columns `⌈W_far/128⌉` |
|---|---|---|---|---|
| A — `r = 52.1` | `sqrt(2,714 + 137,493) = 374.4` m | **MEDIUM** | 484.6 → 533.4 m | `⌈533.4/128⌉ = ⌈4.167⌉` → **5** |
| B — `r = 180.0` | `sqrt(32,400 + 137,493) = 412.2` m | **MEDIUM** | 533.4 → 623.8 m | `⌈623.8/128⌉ = ⌈4.874⌉` → **5** |
| C — `r = 308.0` | `sqrt(94,864 + 137,493) = 482.0` m | **FAR** | 623.8 → 717.2 m | `⌈717.2/128⌉ = ⌈5.603⌉` → **6** |

**The column rule is the pure ceiling, with no discretionary rounding (report RR-14).** Row B's `4.874` is written **5**, not "5–6": `⌈W/128⌉` is the number of 128 m columns a width `W` spans at the best alignment, and "round 4.874 up to 6 because it is close to 5" was a judgement call smuggled into an arithmetic step — the unfavourable-alignment case is already carried, once, by the grid-alignment band below. *(The former "5–6 → take 6" entry and the `5 + 6 + 6` representative alignment are deleted.)*

Each row is counted at its own widest edge (its far edge), so there are no bounding-box corners left to trim — the count is already the frustum-intersecting set. The columns are therefore `5 + 5 + 6`:

**16 chunks rendered at Z2: 10 MEDIUM (rows A + B, both inside the 197.3 m MEDIUM boundary), 6 FAR (row C), 0 NEAR.** *(Was 17 = 11 MEDIUM + 6 FAR under the discretionary rounding of row B; before RR-12, 21 = 10 MEDIUM + 11 FAR off the phantom row.)* (Chunks the streamer keeps resident as a one-chunk margin are frustum-culled and cost no draw calls; "rendered" here means frustum-intersecting.)

**Grid-alignment band.** A row of ground width `W` covers `⌈W/128⌉` columns when the view axis lands on a column centre and one more when it lands near a boundary, so the count moves within `(5+5+6) = 16` … `(6+6+7) = 19`. **16 is the published design figure** — it is now the *floor* of the band rather than a point inside it, so §7.2 test 19 carries the band as an explicit **`+3 / −0` chunk** tolerance (16–19) rather than a percentage or a symmetric window, and the budget below is checked at the pathological 19.

**Pose Z1 — `D = 86.9`, `p = 48°` (mid zoom; this is now the sizing pose).**

```
h        = 86.9 · sin 48° = 86.9 · 0.74314 =  64.6 m
nadir    = 86.9 · cos 48° = 86.9 · 0.66913 =  58.1 m behind focus
r_near   = 64.6 / tan 68° = 64.6 / 2.47509 =  26.1 m
r_far    = 64.6 / tan 28° = 64.6 / 0.53171 = 121.5 m       depth = 95.4 m
s_near   = sqrt(26.1² + 64.6²)  = sqrt(681 + 4,173)   =  69.7 m
s_far    = sqrt(121.5² + 64.6²) = sqrt(14,762 + 4,173) = 137.6 m
w_near   = 2 ·  69.7 · 0.64706 =  90.2 m
w_far    = 2 · 137.6 · 0.64706 = 178.1 m
area     = 0.5 · (90.2 + 178.1) · 95.4 = 12,798 m² = 0.78 land blocks
```

Every LOD distance at Z1 lies in `[69.7, 137.6]` m — **entirely inside the NEAR band (`≤ 150`)**. A 95.4 m-deep × 178 m-wide footprint straddles at most 2 chunk rows × 3 chunk columns, so the worst-case Z1 pose is **6 chunks, all NEAR.**

**This is what forces `near_chunk_max` up.** At the old `D_MIN = 60` the near band was partly consumed by camera distance; at `D_MIN = 18` the player can put six chunks inside 150 m, and a cap of 4 (Balanced) or 2 (Performance) would demote chunks the player is looking at straight down the barrel. New caps: **Performance 3, Balanced 6, High 8**, sized by the shadow arithmetic below.

**Pose Z0 — `D = 18`, `p = 34°` (max zoom in).**

```
h      = 18 · sin 34° = 10.1 m;   nadir = 18 · cos 34° = 14.9 m behind focus
r_near = 10.1 / tan 54° =  7.3 m ;  r_far = 10.1 / tan 14° = 40.4 m   depth = 33.1 m
w_near = 2 · (10.1/sin 54°) · 0.64706 = 2 · 12.45 · 0.64706 = 16.1 m
w_far  = 2 · (10.1/sin 14°) · 0.64706 = 2 · 41.63 · 0.64706 = 53.9 m
area   = 0.5 · (16.1 + 53.9) · 33.1 = 1,159 m² = 0.07 land blocks
```

At Z0 the camera sees one seventh of one hundredth of a chunk's worth of ground; the footprint straddles at most **4 chunks, all NEAR** (distances 12.5–41.6 m).

**Per-chunk draw calls** (unchanged by the camera ruling): NEAR = 8 building buckets + 2 ground/road + 3 props = **13**; MEDIUM = 6 + 2 + 2 = **10**; FAR = 1 + 1 + 1 = **3**. ~~Performance adds 1 blob-shadow call per NEAR/MEDIUM chunk.~~ **Corrected 2026-09-01 (RR-96): Performance adds ONE blob-shadow call for the whole city, not one per chunk** — see §2.11. The correction is worth more than one line, because the arithmetic below is what made the per-chunk shape look affordable: this model spends 3 NEAR + 3 MEDIUM, and the benchmark city at Z0 on Performance has **12 NEAR + 24 MEDIUM**, so a per-chunk layer costs 36 rather than 6. **A per-chunk cost multiplied by a chunk count taken from the model rather than from the census is the failure mode; the census is the number.**

*The `road` half of the per-chunk `ground/road` term is no longer per chunk: §2.1.2 draws the whole city's carriageway and footway in **two** calls, not `2 × chunks`. The model above is therefore conservative by roughly one call per visible chunk — 16 at Z2 — and is left as written because a budget that over-counts is the safe direction and every table below is a measurement, not this derivation.*

*The MEDIUM figure is now measured at **5.94** on the benchmark city (as-shipped, below) — the merge in §2.6 is what made this line true rather than optimistic by 1.7×. The NEAR figure is still an assumption and still measures 16.4; see the residual note under the as-shipped table.*

**Balanced budget at each pose** (budget 320, 2 shadow splits):

```
                        Z0            Z1 (worst)     Z2
chunks              4 NEAR         6 NEAR        10 MEDIUM + 6 FAR
opaque              4·13 =  52     6·13 =  78    10·10 + 6·3 = 118
shadow (NEAR only)  4·8·2 =  64    6·8·2 =  96   0 NEAR              =   0
vehicles (3 civ MM + 1 headlight + ~6 emergency)  10        10           10
weather (rain + splash)                            2         2            2
sky / fog / glow composite                         4         4            4
UI (doc 12, CanvasItem batched)                  ≈25       ≈25          ≈25
                                          TOTAL  157       215          159
overlays, if open                                 ≤6        ≤6           ≤6
                                          TOTAL  163       221          165
```

`118 + 0 + 10 + 2 + 4 + 25 = 159`; with overlays `159 + 6 = 165`.

**Plus §2.16's LIVING CONSTRUCTION layer: at most `+5` at every pose** (two machine MultiMeshes, two pile kinds, one barricade bay), measured on the benchmark city at 20 simultaneous sites. It does not grow with the site count, only with the kind count. It is *not* folded into the totals above because the derivation those totals belong to predates it; treated as a worst case, Z1 with the layer is `215 + 5 = 220` against 320, `226` with overlays, and headroom at Z1 falls from 31% to **29%**.

**Headroom against 320: Z0 49%, Z1 31%, Z2 48%.** Every pose clears the budget. *(Z2 recomputed per report RR-14: `(320 − 165)/320 = 155/320 = 48.4%`. It was 45% at the 17-chunk figure, and 44% before RR-12 against the phantom-row total of 180.)*

**Z2 across the grid-alignment band** — the same per-chunk costs at the band's endpoints, so the budget is checked at the worst alignment and not only at the representative one:

```
16 chunks (published, best alignment)  10 MEDIUM + 6 FAR   10·10 + 6·3 = 118  + 41 = 159   (165 with overlays)
17 chunks (one row shifted)            11 MEDIUM + 6 FAR   11·10 + 6·3 = 128  + 41 = 169   (175 with overlays)
19 chunks (pathological)               12 MEDIUM + 7 FAR   12·10 + 7·3 = 141  + 41 = 182   (188 with overlays)
```

(The non-chunk terms sum to `10 vehicles + 2 weather + 4 sky/fog + 25 UI = 41` at every alignment; only the opaque chunk term moves.)

Worst alignment still clears 320 with 41% headroom, so no alignment of the 128 m chunk grid against the view axis can put Z2 over budget.

**The headline claim changes.** The pre-amendment doc said the skyline shot was the cheapest frame because everything was FAR. That is false at a 420 m ceiling: **Z2 is the *shadow-free* pose, not the cheapest one** — the cheapest is Z0 at 157, now by only **2 draw calls** (Z2 159; 163 vs 165 with overlays), so the ordering `Z0 157 < Z2 159 < Z1 215` is preserved but no longer has margin worth leaning on. What survives, and what actually matters, is that the shadow pass is the single largest term at close zoom (96 of 215 calls at Z1, 45%) and it is *exactly zero* at Z2, which is why the most instance-dense pose is still the second-cheapest. Chunk-uniform LOD plus the shared FAR box is still doing the work; it is just doing it against MEDIUM chunks rather than FAR ones.

**The rejected alternative, with its arithmetic.** Report C-63 offered "raise `medium_max_m` or accept ~10 calls per chunk". Raising `medium_max_m` is strictly worse (it converts FAR chunks to MEDIUM). *Lowering* it below `h = 370.8` m — say `medium_max_m = 360` — would restore the all-FAR result at Z2: `16·3 = 48` opaque, total `48 + 41 = 89`, saving `118 − 48 = 70` draw calls. **Rejected.** At Z2 the camera is 370.8 m up and §2.14 authors LOD1 specifically to "preserve archetype readability at 400 m" — roof signatures, masts, aviation beacons, the crown ring. Trading the entire skyline's silhouette vocabulary for 70 draw calls out of a `320 − 159 = 161`-call surplus is a bad trade, and job 1 in §1 (the blackout read at any zoom) depends on being able to tell a hospital from a data centre at max zoom. `medium_max_m` **stays at 420 m**, and the ~10-calls-per-chunk option is the one taken.

**Instance budget check.** At Z2, 16 chunks × ~30 buildings/developed block ≈ 480 visible instances against a 7,000 Balanced budget (≈ 570 at the pathological 19-chunk alignment) — the instance budget is sized for streaming residency, not for any single pose, and the shrunken frustum leaves it untouched.

**Performance and High at the Z1 worst case:**

```
Performance (cap 3 NEAR, blob shadows, budget 180)
  3 NEAR·13 + 3 MEDIUM·10 = 39 + 30 = 69; + 1 blob (CITY-WIDE, not per chunk)
                             + veh 6 + wx 1 + sky 4 + UI 25 = 106                            ✓
High (cap 8 NEAR, 4 splits, budget 520)
  8·13 = 104 opaque; shadow 8·8·4 = 256; + 41 = 401                                          ✓
```

#### As shipped — the benchmark city, and what it measured (2026-08-19)

Everything above this line was **arithmetic**. Doc 91 §2.13 filed that as D-8: the device matrix, the draw-call budget and the instance budget were all written against a 1,500-building city that nothing in the repo could produce, so none of them had ever been checked against a running frame. That city now exists and the numbers below are measured, not derived.

**The fixture.** `tools/gen_bench_city.py --profile bench` emits `tests/fixtures/bench_city.json`, byte-identically on a re-run (doc 09 §2.13, test 40). It is the same generator family as the starter city — it imports `tools/gen_starter_city.py` for the environment profiles, the risk weights and the JSON encoder — and it is validated before it is written: 49 block rows, a 6×6 developed core, `36 × 87 = 3,132` road tiles, no building on a road or in the water, no overlaps, every building inside a transformer's service radius, and a night peak inside the grid's headroom.

| as shipped | value | note |
|---|---|---|
| world / developed core | 7×7 blocks, **6×6 core (36 blocks)** | doc 09 §2.13 says an 8×8 world; `TileGrid.BLOCKS` is 7 and `StarterCityLoader` requires exactly 49 block rows, so the world stays 7×7 and the *core* is the doc's 6×6. The contents the doc sizes against are unchanged. |
| buildings | **1,500** | 737 house · 324 store · 236 apartment · 103 office · 59 high_rise · 15 data_center · 26 civic |
| level mix | L1 385 · **L2 519 · L3 347** · L4 209 · L5 40 | weighted to L2–L3 as doc 09 §2.13 asks; every LOD tier has instances |
| road tiles | 3,132 | doc 09 §2.13's figure exactly |
| streetlight *props* | ~780 (one per 4th road tile, §2.10) | the electrical sink is 3,132, one per road tile (doc 04) — deliberately different numbers |
| water tiles | 85 | two lakes, each filling one road-bounded parcel |
| power | 144 transformers (L5) · 36 feeders (class 3) · 6 substations (L4) · 2 plants (L5) | sized against the measured 122.3 MW night peak, not guessed |
| population / jobs | 35,417 / 19,185 | |

**Sim cost** — `tools/profile_sim.gd --city=res://tests/fixtures/bench_city.json`, best of 2, debug headless build on the dev workstation:

| | starter (34 buildings) | **bench (1,500)** | ratio |
|---|---|---|---|
| fine tick (1 SimTick) | 1.58 ms | **22.00 ms** | 13.9× |
| coarse step (1 game-hour) | 8.20 ms | **259.18 ms** | 31.6× |
| 12 h catch-up (doc 01 budget 2 s) | 0.10 s | **3.11 s** | over budget |

The fine tick's largest terms on the bench city are `roads_congestion` 5.17 ms, `water` 4.39, `power` 3.99, `roads` 2.50; the coarse step's are `incidents` 135.07 ms (52%) and `hourly` 62.03 (24%). **This is the headline finding of the exercise and it is a sim finding, not a render one:** at 1,500 buildings one SimTick costs 22 ms of a 250 ms tick period, which is fine for throughput but lands as a 22 ms spike on the frame it runs — over the whole 16.7 ms frame on its own. Doc 13 §2.9's catch-up arithmetic also has to be re-read against 259 ms/step: the 720-step cap is 186 s of veil, not the 39.6 s worst case that table contemplates, so `max_coarse_hours` (doc 08, report C-21's `ceil(2000 / measured_ms)`) resolves to **7** on this city.

##### Wave-7 scaling pass — what the roster sweeps cost, measured (doc 91 D-15)

The table above is the *pre-optimization* record and stays as written; it is what filed D-15. The pass that answered it changed no rule, no cadence and no tunable — `tools/profile_sim.gd --baseline` reports identical `state_hash` for both the fine and the coarse path on both cities — and cut the coarse step by 42 %.

Measurements are interleaved A/B in one session on the same workstation (baseline stashed and restored between runs), best of 2, debug headless. Absolute numbers drift a few per cent with machine load; the *ratio* is what this table claims.

| | starter (34 buildings) | | bench (1,500) | |
|---|---|---|---|---|
| | before | after | before | after |
| coarse step (1 game-hour) | 8.10 ms | **6.28 ms** (−22 %) | 238.6 ms | **132.8 ms** (−44 %) |
| 12 h catch-up (doc 01 budget 2 s) | 0.097 s | **0.076 s** | 2.86 s | **1.59 s** — inside budget |
| fine tick (1 SimTick) | 1.590 ms | **1.511 ms** (−5 %) | 21.80 ms | **17.49 ms** (−20 %) |

Where the coarse hour went, per phase (ms/step):

| phase | before | after | what changed |
|---|---|---|---|
| `incidents` | 124.8 | **54.8** | the fire generator reads six packed columns instead of 1,500 six-key dictionaries; the candidate table is built only on the sub-steps that actually ignite something; `district_of_tile` and the coverage field's district means are memoised per building |
| `hourly` | 62.1 | **34.8** | the avenue gate behind `access_quality` is one array-row scan instead of 81 `road_class_at` calls; the roster order, the district lookup, the demand channel and the building category are all resolved once instead of per building |
| `districts` | 9.43 | **1.31** | every district's power-service ratio comes out of ONE roster pass instead of one pass per district |
| `roads_congestion` | 13.18 | 12.99 | unchanged work (see below) |
| everything else | 30.0 | 29.9 | unchanged |

**The fine tick is still over a frame, and finishing it needs a cadence decision, not more micro-optimization.** Its remaining cost is the per-tick half: `water` 4.1 ms, `power` 3.7, `roads` 2.1 — every one of them O(buildings) on every SimTick — plus `roads_congestion`, which is a per-GAME-MINUTE pass the table amortizes across four ticks. Read un-amortized, the shape is spiky rather than flat: an ordinary tick is ≈ 10.8 ms, the tick that carries the minute pass is ≈ 37 ms, and the tick that carries the settled hour is ≈ 70 ms. Three cadence proposals are costed in doc 91 D-15; none of them is in this change, because each one moves a number the balance gates are written against. The first was measured, not estimated: making the fire-spread breakpoint conditional on a live `structure_fire` takes the integrator from **15.7 to 5.1 sub-steps per coarse hour**, `incidents` from 54.8 to **28.0 ms**, and the coarse step from 133.8 to **104.8 ms** (12 h catch-up 1.26 s) — and changes both state hashes, which is exactly why it is a proposal.

##### Wave-8 sub-step pass — D-15 proposal 1 taken, and what the router would have cost

*2026-08-20. The Wave-7 table above ends by costing three cadence proposals and taking none of them. **Proposal 1 is taken here.** The change it was expected to ship beside — doc 06's dispatch pricing ETAs through doc 10's router — was wired, measured, and held; the last part of this subsection is that measurement, because it is the reason doc 11's fine-tick problem now has a second consumer waiting on it.*

**Method.** Interleaved A/B, three rounds on the starter city and three on the bench, alternating arms *within* each round, against a pristine copy of the pre-change tree built with `git show HEAD:` rather than a stash — two directories, so neither arm can disturb the other. `tools/profile_sim.gd --repeats=2`, debug headless, on a workstation carrying other work; the round-paired ratios are what this table claims.

| | starter (34 buildings) | | bench (1,500) | |
|---|---|---|---|---|
| | before | after | before | after |
| coarse step, round 1 | 8.58 ms | **6.28 ms** (−26.8 %) | 159.7 ms | **127.7 ms** (−20.1 %) |
| coarse step, round 2 | 8.56 ms | **6.32 ms** (−26.2 %) | 153.0 ms | **119.7 ms** (−21.8 %) |
| coarse step, round 3 | 8.23 ms | **6.26 ms** (−23.9 %) | 154.1 ms | **122.0 ms** (−20.9 %) |
| **mean ratio** | | **−25.6 %** | | **−20.9 %** |
| 12 h catch-up (best round) | 0.099 s | **0.075 s** | 1.836 s | **1.437 s** — inside the 2 s budget with 28 % to spare |
| fine tick (best round) | 1.757 ms | **1.808 ms** | 17.95 ms | **17.86 ms** |
| fine tick, round-paired mean | | **+1.4 %** | | **+0.5 %** — noise (+1.3 / −0.5 / +0.7) |
| **integrator sub-steps / coarse hour** | **12.00** | **1.25** | **20.67** | **8.75** |
| integrator sub-steps / fine tick | 0.25 | 0.25 | 0.27 | 0.27 |

**The sub-step column is the entire story, and the fine-tick row is why the fine tick could not move.** The guard removes a breakpoint that fired on a 1/12-game-hour grid whether or not anything was burning, so a *quiet* starter hour now takes **one** sub-step instead of twelve. A fine tick is 15 game-seconds and already took at most one sub-step; there was nothing there to remove, and the measurement agrees to within a per cent — exactly as D-15 predicted.

Where the coarse hour went, per phase (ms/step, best round):

| phase | starter before → after | bench before → after | what changed |
|---|---|---|---|
| `incidents` | 4.00 → **1.60** (−60 %) | 78.79 → **47.10** (−40 %) | −10.75 sub-steps per coarse hour on the starter, −11.9 on the bench |
| `water` | 0.110 → 0.420 | 5.6 → 4.7 | not a code change: the incident mix resampled, and a live `water_main_break` is water work. It moves in opposite directions on the two cities for the same reason |
| everything else | within ±3 % | within ±3 % | untouched |

**`max_coarse_hours` is unchanged at 312.** Doc 01 §2.10 derives it from the measured coarse step on the starter city; `tests/test_perf_governor.gd` reports **6.21 ms/step** on this branch against 6.25 before, both of which floor to the same 312-hour cap. The guard does not buy catch-up headroom on the starter city because there was none to buy — it buys it on the benchmark city, where the 12 h catch-up falls from 1.84 s to 1.44 s.

##### What the router would have cost — measured, and held (doc 06 §2.10)

Doc 06 §2.10's ETA seam was wired in this branch, measured, and taken back out; doc 06's own Wave-8 note carries the ruling. Two numbers belong here because they are doc 11's:

* **A route quote is ≈ 5 ms** on the benchmark city and the route cache cannot amortise it — half the key is a responding unit's tile, which changes every tile it drives. **Raising `route_cache_size` 256 → 4096 changed the hit and miss counts by nothing at all**: the misses are new pairs, not evictions. Doc 10 §2.14's rank-then-quote contract (rank on the O(1) estimate, quote the top 3) takes the incident phase from **211 ms to 55 ms per coarse hour** and planner misses from **589 to 197 per 24 coarse hours** — necessary, and not sufficient.
* **The pre-change tree makes ZERO route-planner calls** over 24 coarse hours on the benchmark city — zero hits, zero misses, an empty cache — while the whole fleet drives to incidents. Doc 10's router was built, tested and shipped, and until this branch nothing in dispatch had ever asked it a question.

The blocker is not doc 11's, but it lands on doc 11's table: with the router wired, doc 92's `greedy_growth` agent goes from **12.6 s for a 21-game-day run to over twenty minutes**, because a rotting city's incidents stop clearing doc 06's `MAX_ACCEPTABLE_COST` and the backlog is unbounded. Doc 10's own routing test already reports *"median P0 expansions 1154 vs trigger 800 → hierarchical routing REQUIRED"*, and that is the work that makes a 5 ms quote affordable inside a per-sub-step loop.

##### Wave-9 cadence pass — D-15 proposals 2 and 3 taken, and what the shipped router actually costs

*2026-08-20. The router is wired (doc 06 §2.10, report 98 RR-26) and the fine tick's two remaining cadence proposals are taken (RR-28). Both arms of every pair below were run in the SAME session with the pre-change tree restored by `git stash`, on a workstation carrying three other agents' test suites — which is why the pairs are stated as pairs and the absolute numbers are not comparable with the Wave-8 table above.*

| bench city (1,500 buildings) | before | after | |
|---|---|---|---|
| **fine tick** | 19.145 ms | **18.011 ms** | **−5.9 %** |
| ├ `water` | 4.100 | **2.451** | **−40.2 %** — D-15 proposal 3 |
| ├ `power` | 3.744 | **3.210** | **−14.3 %** — D-15 proposal 3 |
| ├ `roads_congestion` | 5.013 (0.25 calls/tick) | 5.449 (**1.00 calls/tick**) | amortized flat; the PEAK is what moved — see below |
| ├ `incidents` | 2.650 | 2.911 | +9.8 % — real quotes in the assignment pass |
| └ `roads` / `report` | 2.155 / 0.738 | 2.315 / 0.925 | within this session's noise |
| **coarse step** | 126.41 ms | **189.96 ms** | **+50.3 %** |
| └ `incidents` | 49.54 | **110.61** | +123 % |
| **integrator sub-steps / coarse hour** | 8.75 | **14.54** | +66 % |
| **12 h catch-up** | 1.517 s | **2.280 s** | doc 01 budget 2 s — **breached by 14 %** |

| starter city (34 buildings) — the REFERENCE city | before | after | |
|---|---|---|---|
| **coarse step** | 6.353 ms | **6.690 ms** | +5.3 %, inside this session's noise |
| **fine tick** | 1.842 ms | **1.817 ms** | −1.4 % |
| **12 h catch-up** | 0.076 s | **0.080 s** | 4 % of budget |
| integrator sub-steps / coarse hour | 1.25 | 1.25 | unmoved |

**Proposal 2 does not change the amortized column and was never going to.** The minute's three passes — `congestion.recompute`, `TrafficSnapshot.rebuild`, `TrafficFeed.rebalance` — still each run once per game-minute; what changed is that they run on ticks 0, 1 and 2 of the minute instead of all three on tick 0. The profiler reports a mean over all ticks, so the mean is flat by construction and the `calls/step` column moving 0.25 → 1.00 is the whole visible signature. **The number it moves is the worst tick, which the profiler does not report**: before, one SimTick in four carried all three passes and the other three carried none; now the largest single pass a frame can carry is the congestion sweep alone. That is a frame-pacing win, not a throughput win, and it is what D-15 proposal 2 asked for in those words.

**Proposal 3 is the throughput win, and it is worth 2.2 ms of the fine tick.** `PowerGrid._update_service` and `WaterSystem._accumulate_service` are the only O(buildings) passes in their phases; banking them once per game-minute instead of four times cuts `water` by 40 % and `power` by 14 %. The un-banked remainder is persisted in both sections, because a save taken two ticks into a game-minute otherwise restores a city that banks a different slice of that minute from the live one, and save → load → advance would stop being bit-identical.

**The fine tick lands at 18.0 ms against D-15's 8 ms target, and what remains is not a cadence problem.** After this pass the tick is `roads_congestion` 5.4 (a real O(edges) sweep, once a game-minute), `power` 3.2, `incidents` 2.9, `roads` 2.3, `water` 2.5. Nothing left in it is a *frequency* mistake — every one of those is genuine work at a defensible cadence — so the next honest step is either fewer edges/buildings touched per sweep (a dirty-set congestion pass) or GDExtension, which is where doc 10 §9.3 C-3's ladder already ends.

**The coarse step is where the router is paid for, and it breaches a budget.** The incident phase more than doubles: a real A\* quote replaces arithmetic in the assignment loop, and — the larger term — the integrator takes **66 % more sub-steps**, because street-true arrival times are all distinct where Chebyshev ones collided on a grid, so `fleet.next_event_h()` produces far more breakpoints. On the **reference** city, which is what doc 01 §2.10's `max_coarse_hours` and doc 08's cap are derived from, the coarse step is flat and the cap does not move. On the **benchmark** city the 12 h catch-up goes 1.52 → 2.28 s, 14 % over doc 01's 2 s target for a 1,500-building stress fixture. It is reported rather than papered over, and the cheapest lever if it has to come down is naming arrival times on the SimTick grid (they are already whole game-seconds; quantising to 15 would collapse most of the extra breakpoints) — a fidelity decision doc 06 owns, not a performance one doc 11 can take.

**The router's own price, measured on the workload dispatch really produces.** `tools/profile_routing.gd`, benchmark city aged 120 game-hours, cold cache, `epsilon_critical = 1.0`, doc 10 §2.14's rank-then-quote with `DISPATCH_CANDIDATES = 3`: **0.709 ms mean / 0.556 median / 1.360 p90 / 4.254 max, 46.6 expansions.** Quoting every station instead costs **2.862 / 2.179 / 6.365 / 13.033 ms at 206.2 expansions** — 21× more work per incident. The **≈ 5 ms** figure in the Wave-8 subsection above is a *cross-city* quote and rank-then-quote never pays for one; hierarchical routing was built, measured and rejected (report 98 RR-27).

**Frame cost** — `tools/profile_frame.gd`, 1920×1080, Balanced, hour 21:00 (the emissive/glow worst case), 60 warm-up frames discarded, 240 measured. **Dev workstation, NVIDIA RTX 2000 Ada, Forward+ — this is not a phone and not the Mobile renderer.** It is a *relative* measurement: the draw-call and chunk columns are platform-independent and are the ones the budget is written against; the millisecond columns are here to show where the cost sits, not to claim a device result.

**Frame cost** — `tools/profile_frame.gd`, Balanced, hour 21:00 (the emissive/glow worst case), 60 warm-up frames discarded, 240 measured. *(Labelled 1920×1080; actually rendered at **1280×720**, and taken with the sun down so the shadow pass is empty — §2.13's Fold pass and report RR-35. The draw-call, chunk and primitive columns stand; the ms columns are 720p night figures.)* **Dev workstation, NVIDIA RTX 2000 Ada, Forward+ — this is not a phone and not the Mobile renderer.** It is a *relative* measurement: the draw-call and chunk columns are platform-independent and are the ones the budget is written against; the millisecond columns are here to show where the cost sits, not to claim a device result.

| pose | mean ms | p95 ms | RS cpu | RS gpu | draw calls | +UI | budget | bucket nodes | NEAR | MED | FAR |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Z0 `D 18 / 34°` | 10.83 | 11.11 | 0.13 | 0.83 | 92 | 117 | 320 | 591 | 12 | 24 | 0 |
| Z1 `D 86.9 / 48°` | 11.20 | 13.33 | 0.17 | 2.23 | 133 | 158 | 320 | 591 | 8 | 28 | 0 |
| **Z2 `D 420 / 62°`** | 11.64 | 14.29 | 0.28 | 2.67 | **327** | **352** | **320** | 279 | **0** | 16 | 20 |
| *starter city, Z2, for scale* | 0.96 | 1.23 | 0.06 | 0.83 | 80 | 105 | 320 | 18 | 0 | 9 | 0 |

`RS cpu` / `RS gpu` are the RenderingServer's own measured times for the viewport; they do **not** sum to `mean ms` — the remainder (~8–9 ms) is the render layer's per-frame GDScript plus present.

Three results, in order of how much they matter:

1. **Z2 is over the Balanced draw-call budget: 352 against 320.** Not by a rounding error, and not for the reason §2.13's derivation would predict. The derivation's per-chunk cost model (8 building buckets NEAR, 6 MEDIUM) assumes a chunk holds about six distinct `archetype:level` combinations. The bench city's mix gives **591 bucket nodes across 36 chunks — 16.4 per chunk**, because a real block holds five archetypes at four levels rather than one archetype at one. Every §2.13 conclusion that rests on "10 calls per MEDIUM chunk" is optimistic by roughly 1.7× on a mixed city. *The fix is bucket merging (one MultiMesh per chunk per LOD, with the mesh selected by instance custom data) and it is not in this change; it is filed as a defect against §2.6.* **Closed 2026-08-19 — the next subsection is the fix and its measurement.** Note that **the empty Z2 shadow pass survives intact** — 0 NEAR chunks, exactly as §2.13 claims, and that claim is what keeps the number at 352 rather than several hundred more.
2. **The frame is main-thread bound, not GPU bound, and it scales with the city.** 0.96 ms per frame on 34 buildings against 11.64 ms on 1,500, while the GPU column moves only 0.83 → 2.67 ms. `CityView.refresh` flushes every dirty instance unbudgeted (`flush_dirty(camera_pos, 1000000)`), re-tiers every chunk, and walks all 591 bucket nodes on every frame. §2.2's `multimesh_instance_writes_per_frame = 2000` budget is authored but not enforced by the bring-up path.
3. **The instance budget is comfortable.** 1,500 resident instances against a 7,000 Balanced budget, 100,906 primitives at the densest pose. Nothing in §2.13's instance or VRAM arithmetic is threatened.

#### The bucket merge — result 1, measured and closed (2026-08-19)

Doc 91 D-14. §2.6 now carries the bucketing rule and the reasoning; this is the number it produced. Same harness, same city, same 21:00 pose set, 90 warm-up frames and 240 measured, `--no-merge` against the default — one flag between the two columns and nothing else.

| pose | draw calls | **+UI** | budget | buckets → merged + far | NEAR | MED | FAR | primitives | RS cpu | RS gpu |
|---|---|---|---|---|---|---|---|---|---|---|
| Z0 `D 18 / 34°` | 92 → **92** | 117 → **117** | 320 | 591 → 197 + 149 | 12 | 24 | 0 | 52,602 → 52,602 | 0.10 → 0.10 | 0.61 → 0.63 |
| Z1 `D 86.9 / 48°` | 133 → **111** | 158 → **136** | 320 | 591 → 132 + 173 | 8 | 28 | 0 | 59,850 → 77,536 | 0.10 → 0.10 | 1.94 → 2.06 |
| **Z2 `D 420 / 62°`** | **327 → 194** | **352 → 219** | **320** | 259 + 20 → 0 + 95 + 20 | **0** | 16 | 20 | 100,906 → 209,546 | 0.18 → 0.12 | 2.44 → 2.38 |
| *starter city, Z2* | 78 → **78** | 103 → **103** | 320 | 15 + 1 → 15 + 1 | 0 | 8 | 1 | 18,954 → 18,954 | 0.05 → 0.05 | 0.44 → 0.44 |

**Z2 is inside the budget: 219 against 320, 31.6% headroom** (it was −10% over). The 16 MEDIUM chunks cost **95 building calls — 5.94 per chunk**, against the 6 the worked example above assumes. *§2.13's per-chunk model was never wrong; the renderer was.* Nothing in the derivation had to be retuned to make it true.

Four things this table says that the headline does not:

* **The starter city is unchanged in every column, including the picture.** It holds at most one level of an archetype per chunk, so there is nothing to merge and the merge finds nothing — 78 calls and 18,954 primitives either way. That is the strongest correctness signal in the table: the merged path and the un-merged path agree exactly where they must.
* **Z0 does not move.** Its draw-call and primitive columns are identical to the digit, so the frustum culled every one of its 24 MEDIUM chunks at `D = 18`; only the 12 NEAR chunks reach the GPU, and NEAR is not merged. The bucket column still falls (591 → 346 nodes flagged visible) because the merge is per-chunk work, not per-frustum work.
* **Primitives go up 2.08× at Z2, and the GPU column does not move** (2.44 → 2.38 ms). That is the trade the merge makes and it is the right way round: the extra triangles are degenerate — transformed once, dropped at the rasteriser, never shaded — the draw-call budget is the one this section publishes and the one the bench city broke, and there is no primitive budget to break. §2.6 has the instance-weighted triangle table behind it, and why the level mask is what keeps the merged tier at 3.95× rather than 5.75×.
* **`RS cpu` at Z2 falls 30%** (0.18 → 0.12 ms). Fewer nodes is less per-frame walking, which is the same term result 2 above is about.
* **And the picture is the same picture — measured, not asserted.** 1920×1080 A/B captures through `--shots`, one flag apart: **Z0 and Z1 are BIT-IDENTICAL**, 0 of 921,600 pixels differing. Z2 differs on **0.63% of pixels by at most 18/255** (mean 0.03/255), which is the deliberate `near_flicker = 0` on the MEDIUM tier and nothing else — §2.5's own rule, applied for the first time. The blackout and the POWER overlay were captured the same way through `game/showcase.gd --no-merge`: **0.006%** and **0.27%** of pixels differ respectively — the OFFLINE state's own 0.35 Hz breathe, sampled a frame apart, plus the same flicker term. The dark half stays dark and the OFFLINE wash still paints it.

**What is still open, and it is not small.** NEAR still allocates one MultiMesh per (chunk, archetype, level) and still measures **16.4 per chunk** against this section's assumed 8 — the other half of D-14, filed as doc 91 **D-16**. Re-run the Z1 worst-case arithmetic above with the measured number instead of the assumed one and it does *not* clear the budget:

```
Z1 worst case, 6 NEAR chunks (near_chunk_max, Balanced)
  opaque   6 × (16.4 buckets + 2 ground/road + 3 props)  = 128
  shadow   6 ×  16.4 × 2 splits                          = 197     ← the term
  vehicles + weather + sky + UI                          =  41
                                                    TOTAL  366  vs  320
```

**The shadow pass is where it bites**, because §2.13 costs every NEAR bucket once per split. What keeps the shipped frame well inside the budget is the frustum: the bench city at Z1 measures **136 with UI**, 8 NEAR chunks, because nothing like six full dense chunks is ever simultaneously inside a 95 m-deep footprint. So this is a *derivation* that fails and a *measurement* that passes — the opposite of D-14, where both failed together, and the reason this is filed Low rather than fixed here. The fix is not a design either: the LOD0 level atlas that closes MEDIUM is pixel-exact and already shipping, so extending it to NEAR is the same switch plus a `near_flicker = 1` material. Take it the first time a **device** measurement puts a close-zoom pose near 320 — or the first time a pose is found that really does hold six dense NEAR chunks.

**Bus volume** — `tools/qa_soak.gd`, 0.25 real-hour session on the starter city, before and after the D-10 diet:

| | events on the bus | share |
|---|---|---|
| before (one `vehicle_state` per vehicle per tick) | 55,675 | `vehicle_state` = 44,153 = **79.3%** |
| **after** (one packed `traffic_snapshot` per tick) | **18,221** | `traffic_snapshot` = 6,699 events carrying the same 44,153 poses |

**3.05× less traffic on the bus**, and the 44,153 dictionaries became 6,699 events of five packed buffers. Save identity is unchanged and proved rather than asserted: `tools/profile_sim.gd --hash-only --baseline=…` reports `BEHAVIOUR UNCHANGED` on both the starter and the bench city, on both the fine and the coarse path. The bus is not persisted (`SimEventBus` keeps no history), so this was true by construction; the baseline check is what makes it checked.

**The governor, as shipped.** `game/render/perf_governor.gd` implements the ladder and the holds above and doc 13 §2.8's thermal policy, as a model with no Node and no engine singleton — which is what lets `tests/test_perf_governor.gd` drive the 5 s and 30 s holds in microseconds. Settings row `auto_quality` ("Auto quality", `data/ui.json`), **default on**, device-scoped. Two behaviours worth stating because they are choices, not consequences: switching the row **off freezes the knobs where they stand** rather than restoring the preset (a quality *jump* is the one thing a manual-control switch must not cause), and a preset the *player* picks resets the ladder and clears a latched drop, because their choice outranks the governor's.

#### The street pass — what it cost, measured (2026-08-20)

§2.1.2 and §2.10.1. Same harness, same benchmark city, same 21:00 pose set, 60 warm-up frames and 120 measured, on the same workstation, before and after in one session.

*(Labelled 1920×1080; rendered at 1280×720, and at hour 21 with an empty shadow pass — report RR-28. Draw calls and primitives stand; the GPU column is a 720p night figure.)*

| pose | draw calls | **+UI** | budget | primitives | RS gpu |
|---|---|---|---|---|---|
| Z0 `D 18 / 34°` | 92 → **93** | 117 → **118** | 320 | 52,602 → **61,298** | 0.63 → 0.77 |
| Z1 `D 86.9 / 48°` | 111 → **112** | 136 → **137** | 320 | 77,536 → **87,364** | 2.06 → 1.74 |
| **Z2 `D 420 / 62°`** | 194 → **195** | 219 → **220** | **320** | 209,546 → **230,036** | 2.38 → 2.83 |

**One draw call, everywhere.** The slab MultiMesh the pass replaces already cost one; the asphalt still costs one and the footway is the second. Nothing else in the frame moved: markings, gutters, wear, crosswalks and the kerb lip are all fragment work inside the asphalt call, and the lamps kept the same four per-chunk buffers they already had (there are now **469 of them instead of 828** on the benchmark city, because the placement rule stopped stippling a diagonal). **Z2 sits at 220 of 320 — 31.2% headroom**, against a brief that allowed spending to ~290.

**The bill is in vertices, and it is small.** +20,490 primitives at Z2 (+9.8%), +8,696 at Z0. On the founding city the whole road layer is 9,396 asphalt triangles (783 tiles × 12) + 1,836 footway triangles (153 merged instances × 12) + 9,880 pole triangles (130 × 76) = **21,112 triangles for every street in the city**.

**The rebuild cost, and where it is worse than what it replaces.** `RoadSurfaceView.rebuild()` runs on `road_graph_changed` / `block_roads_stamped`, i.e. every time the player lays road. Debug headless, best of 15:

| | founding city (783 road tiles) | benchmark city (3,132) |
|---|---|---|
| `RoadGraph.road_tiles_sorted` | 0.20 ms | 1.05 ms |
| `RoadSurfaceView.classify` | 2.66 ms | 11.28 ms |
| **`rebuild` total** | **4.41 ms** | **18.30 ms** |
| *the grid sweep the old rebuild opened with* | *7.78 ms* | *7.90 ms* |

On the city a player actually starts in this is **faster than what shipped** — the old `_rebuild_road_multimesh` swept all 12,544 grid cells through `has_flag`, a method call with a bounds assert apiece, and that sweep alone is 7.8 ms. On the 1,500-building benchmark it is 2.3× slower, which is a real regression and is filed as an open question (the fix is a dirty-tile incremental path, not more micro-optimisation). Three things are already taken:

* membership comes from the graph's own map rather than a grid sweep (7.6 ms on the founding city), which is safe mid-edit because `RoadGraph.apply_edits` re-reads tile membership up front and budgets only the edge TRACING;
* `_pair_of` is skipped on any tile with fewer than three legs — a dual carriageway cannot have fewer (3.4 ms on the benchmark city);
* the footway run buckets key on an int, not on `"%s|%.3f|%.3f" %` (3.1 ms on the benchmark city).

And the pass is idempotent per edit: `rebuild` records the `graph_version` it drew and returns immediately for a repeat, because one player edit fires **two** events the shell rebuilds from.

**Texture memory: zero added.** Both shaders sample the existing `ground_asphalt` and `ground_pavement` pages through the resource cache, and every mark, joint, patch and stain on top of them is procedural. Against the 8 MB budget the brief set, the pass spends 0.

*(The 18.30 / 4.41 ms rebuild figures above are the pure-function pass and are still what `force` and the boot path cost. §2.1.2a's dirty-tile diff replaced the per-edit path: **1.18 ms** on the founding city, **4.87 ms** on the benchmark one.)*

#### One-buffer uploads: the premise is refuted, and here is the A/B (2026-08-20)

The construction branch filed "replace the ~200 `set_instance_*` triples per frame with one `multimesh_set_buffer` per layer" as **the named lever for Fold headroom**. It was measured before it was implemented, and it is not a lever: on this build it is a **2× regression**, at every scale.

`tools/profile_mm_upload.gd` writes the same 200 instances every frame for 600 measured frames on the real (Vulkan / Forward Mobile) renderer, once with the three per-instance setters and once by packing a `PackedFloat32Array` and assigning `MultiMesh.buffer`:

| instances / frame | per-instance setters | pack in GDScript | `mm.buffer =` | one-buffer total |
|---|---|---|---|---|
| 200 | **0.031 ms** | 0.061 ms | 0.003 ms | 0.064 ms |
| 2,000 | **0.307 ms** | 0.634 ms | 0.028 ms | 0.662 ms |

Whole-frame wall time agrees at the scale where the difference is above noise: 2,000 instances is **0.518 ms/frame** with the setters and **0.863 ms** with the buffer, and the 0.345 ms gap is exactly the upload block's.

**Why, and it is not surprising once measured.** `set_instance_transform` is ONE binding call around a C++ memcpy of twelve floats; packing the same row is twelve scripted `PackedFloat32Array` writes plus the basis-row reads to feed them, and then the same again for colour and custom data. The server-side write is ~0.003 ms either way, so there is no upload saving to trade against the scripting cost. The premise assumed the cost was the RenderingServer; the cost is GDScript.

**And the uploads were not where the layer's frame went anyway.** Instrumented on the bench city with `--sites=20` (201 instances across five buffers):

| | before | after |
|---|---|---|
| `_service_routes` | 0.001 ms | 0.001 ms |
| `ConstructionActivity.refresh` (pose computation) | 0.316 ms | 0.310 ms |
| `_upload` | 0.088 ms | **0.049 ms** |

So the pass kept the setters and took the reductions that were actually there — the per-instance work that did not have to be repeated. `ConstructionVehicleView._write` hoists the lamp branch out of the loop, caches the `MultiMesh` reference and builds the `Transform3D` inline instead of through `Pose.transform()`; `VehicleView._upload` caches the per-vehicle body-tone hash on spawn (it was `hash01(id, 53)` per vehicle per frame for a number that cannot change), hoists the two cull radii out of a per-vehicle method call, and compares squared distances instead of constructing a `Vector2` and taking its root. Measured at the Balanced cap (90 civilians + 12 units): `VehicleView._upload` **0.194 → 0.158 ms/frame**. `tools/profile_frame.gd --sites=20`'s layer-CPU column moves **0.506 / 0.512 / 0.484 → 0.453 / 0.447 / 0.456 ms** at Z0 / Z1 / Z2; draw calls (100 / 118 / 201) are unmoved.

**The one place the packed buffer IS the right tool is `RoadSurfaceView`** (§2.1.2a), and the reason is not speed: it is a per-EDIT path whose contract needs the bytes, and the array it keeps between passes is what makes an incremental rebuild checkable against a from-scratch one on a headless run.

#### The Fold 6 pass — what was asked, what was measured, and on what (2026-08-20)

Wave 8 filed six questions that only a phone can answer. **The phone did not
appear.** `adb` was polled every 20 s for 45 minutes — 135 attempts, `adb mdns
services` re-run on each, zero endpoints advertised — so what follows is the
workstation half of each answer plus the runbook that takes the other half:
**`tools/device_runbook.md`**, which carries the exact `adb` commands, the exact
poses, and every table below with an empty `Fold 6` column beside the
provisional one. **Nothing in this subsection is a device number, and the two
knob defaults it sets say so in `data/render.json`.**

> **Superseded in part on 2026-08-20 — the phone did appear.** See
> **"Fold 6 measured"** immediately below. Every workstation number in the rest
> of this subsection still stands as written, and the sentence above ("nothing
> in this subsection is a device number") is true of *this* subsection and no
> longer true of the section as a whole. The device session did **not** manage
> to separate the three zoom poses — the reason is a harness fault, it is
> written up below, and the pose matrix is still open.

##### Fold 6 measured — the 2026-08-20 device session

**Device.** Galaxy Z Fold 6, Android 16, `adb` over wireless debugging.
**Qualcomm Adreno 750, Vulkan 1.3.128, Godot "Forward Mobile"** — the renderer
this document is written against. Inner display **1856 × 2160 at 120 Hz**;
`targetSdk` 36, `minSdk` 29, `arm64-v8a`, debug-signed `versionCode` 400.

**The screen is the headline context and it changes how every ms column above
should be read.** The inner panel is **4,008,960 pixels — 2.07× the 1920×1080
every table in this section claims, and 4.35× the 1280×720 those tables were
actually rendered at** (report RR-28, above). Balanced then applies
`render_scale` 0.85, so the real render target is **1836 × 1578 = 2.90 MP**:
**1.40× the resolution this section claims and 3.14× the resolution it actually
measured.** That 3.14× is the number to carry into any fragment argument, and
the fragment ladders in §2.1.2 are the first thing it lands on. `render_scale`
is also the governor's first rung, which is why a Fold frame that is late
degrades resolution before it degrades anything the player would name.

**The city measured is the player's own save**, not a fixture: 70 buildings,
population 255, day 22, treasury $93.5K, preset `balanced` (auto-detected — no
`settings.cfg` existed, so the graphics row had never been touched).
The instrument is the `PERF` line from `game/render/perf_telemetry.gd`, which
**works, and is now the only frame instrument that does** (see the `gfxinfo`
note below). Steady state = lines at `t ≥ 12 s`, after shader warm-up and after
the city has finished streaming in.

| run | fps (med) | p95 ms | cpu ms | gpu_est ms | dc med/max | prim | vram MB | chunks | near | inst | knob |
|---|---|---|---|---|---|---|---|---|---|---|---|
| ungoverned A | 96.6 | 14.1 | 0.50 | 7.0 | 141 / 141 | 125,062 | 144 | 9 | 4 | 70 | 0 |
| ungoverned B | 72.7 | 16.9 | 0.60 | 8.2 | 142 / 142 | 125,184 | 144 | 9 | 4 | 70 | 0 |
| ungoverned C | 71.8 | 16.8 | 0.60 | 8.2 | 142 / 142 | 125,184 | 144 | 9 | 4 | 70 | 0 |
| ungoverned D | 63.0 | 19.8 | 0.70 | 9.9 | 142 / 142 | 125,184 | 144 | 9 | 4 | 70 | 0 |
| ungoverned E | 60.6 | 21.4 | 0.65 | 10.0 | 161 / 189 | 124,975 | 167 | 9 | 4 | 70 | 0 |
| governed F | 53.8 | 26.8 | 0.80 | 12.6 | 143 / 160 | 116,880 | 144 | 9 | 4 | 70 | 4 |
| governed G | 53.9 | 26.8 | 0.75 | 11.1 | 142 / 142 | 125,184 | 144 | 9 | 4 | 70 | 4 |

Rows A–G were taken between 14:02 and 14:07 with the game in the foreground —
verified by screenshot, and with the phone untouched between the reset and the
read. **They are the trustworthy half of this session.**

**Four findings, in the order they matter.**

**1. The draw-call budget is not the constraint on this device, and that
settles the pad-shadow question.** `dc` sits at **141–189 against §2.13's 320**
— 41 % to 56 % headroom, at every capture, including the ones where the frame
was late. The frame is **GPU-bound on fragments, not on submission**: `cpu` is
**0.5–1.2 ms** against Balanced's 4 ms CPU budget (13–30 % of it) while
`gpu_est` is 7.0–13.9 ms against a 16.7 ms frame. Nothing in the draw-call
column is close to the ceiling that the pad-shadow ruling was made revisitable
against.

**2. The governor fires on this device, in the foreground, on a 70-building
city — and that much is clean.** Rows F and G reached `knob = 4` (the whole
non-latching ladder: `render_scale`, `particle_ratio`, `far_cull_m`,
`street_lights`) and still measured **p95 26.8 ms against Balanced's 16.7 ms
budget**. §2.13's device matrix puts the Fold in the top tier and budgets it at
60 fps; on the two daylight-ish captures that budget was met only *after* the
governor had spent its ladder. Two candidate causes, neither separated by this
session: the 4 MP panel (a `render_scale` question) and the shadow pass.

> **A longer run appeared to drive the full ladder — `knob` to 15 and a latched
> preset drop to `performance` at ~30 fps — and it is NOT reported as a result,
> because the app was not reliably in the foreground for it.** The user picked
> the phone up partway through; a screenshot timed against the tail of that run
> shows another app on top while `PERF` lines were still being emitted. A Godot
> `SurfaceView` that keeps ticking while something else is composited in front
> of it is not a frame measurement, and the numbers it produced (`gpu_est`
> *rising* from 11 ms to 18 ms *after* the preset drop, which is backwards for a
> degradation step) look exactly like what a background/DVFS-parked app
> produces. **The raw capture is kept at `tools/device_results/log_sustained.txt`
> and is labelled contaminated.** Whether the ladder really runs to a latched
> preset drop on this device in normal play is *the* open question this session
> leaves, and it wants a foreground-verified 20-minute soak.

**3. Thermal and memory.** `thermal` reported 0 then 1 (NONE → LIGHT) and
`thermal_zone0` sat at **45.7–49.6 °C and drifted DOWN** across the sampled
window, so **nothing in this session is a thermally throttled measurement** and
§7.4's 20-minute thermal gate is not what is limiting these frames. That much
holds regardless of foreground state. Memory is the surprise: process
**PSS ≈ 1.01 GB**, RSS 890 MB, **Graphics 501 MB**, swap PSS 238 MB — against a
renderer-reported `vram` of only 144–167 MB. The gap between the renderer's own
counter and the process total is the thing to chase; 501 MB of graphics memory
for 70 buildings is a 4 MP framebuffer set (shadow atlas, glow chain, MSAA
targets), not city content. **No leak was observed** — PSS moved 1,013,065 →
1,014,041 KB over the sampled window, i.e. flat. *(Sampled during the same
period as the contaminated run above; a process's PSS does not depend on who is
composited on top, so it is reported, but the 20-minute leak gate in §7.4 still
wants a clean session.)*

**4. `near` is 4 and `chunks` is 9 at every zoom the session could reach**, so
the census columns above are one pose repeated, not a tier sweep. That is the
harness fault, next.

**What this session could NOT measure, and why — three harness faults.**

**(a) `--esa command_line_params` does not reach `OS.get_cmdline_user_args()` on
this export template.** This is the fault that cost the pose matrix, and the
runbook's §1.2 pre-flight is the check that catches it. The evidence is not an
absence — it is a positive identity: two runs launched with `--zoom=0.0` and
`--zoom=0.5` produced **byte-identical `dc` and `prim` sequences at matching
timestamps** (140, 141, 141, 141, 141, 141, 141, 141, 142 … and 124,968 /
125,052 / 124,802 / 124,802 / 124,734 …), which is the same deterministic frame
sequence and not a similar one. A screenshot at `--zoom=0.0` shows a mid-zoom
street view, not the 18 m Z0 pose. **Confirmed a second time with the loudest
non-destructive flag in the vocabulary**: a launch carrying
`--rain=1.0,--overlay=2` came up in clear weather with no overlay selected.
The city still loads on every launch — but it
loads through `CrashSentinel`'s recovery branch (`am force-stop` counts as an
unclean exit, so `unclean` is true and `_want_title` is false), **not** through
`--resume`, which is why the app appeared to be honouring its arguments.
`GodotAppLauncher` is an `activity-alias` for `.GodotApp`, so the extra should
forward; where it is being dropped is not yet established. **Until this is
fixed, no per-pose device number can be taken at all**, and §2.13's pose matrix
stays open.

> **⚠ Cross-branch interaction the lead must resolve before merging.** A
> concurrent branch is gating the `PERF`/`PERFIO` wiring behind a **`--perf`
> user argument** (to avoid a per-frame
> `viewport_set_measure_render_time` timestamp query in player sessions — a
> sound motive). **On this export template that gate makes the telemetry
> unreachable on device**, because user arguments do not arrive at all: fault
> (a) above. The two changes are individually reasonable and jointly fatal —
> the only frame instrument that works on this app would be switched off by a
> flag that cannot be delivered. If the query really must not ship to players,
> gate it on `OS.is_debug_build()` or a `settings.cfg` row — something that does
> not travel through `--esa command_line_params` — **or land the argument fix
> (doc 13 D-20) first.** Every number in this subsection was taken on an
> ungated build.

**(b) `dumpsys gfxinfo` measures nothing on this app.** Every `framestats` read
returned **`Total frames rendered: 0`** and every percentile came back as the
sentinel `4950ms`. Godot renders through a `SurfaceView`, which does not go
through HWUI, so the platform's frame instrument never sees the game.
**The whole of `tools/device_runbook.md` §2 is written against `gfxinfo` and
that half of the runbook is void.** The `PERF` line is the replacement and it is
strictly better — it carries `dc`, `prim`, `vram` and the chunk census, which
`gfxinfo` never had.

**(c) The boot LOAD cannot emit its `PERFIO` line on the installed build.**
`game/main.gd` set `save_service.log_io = true` inside `_build_city_view()`
(line ~344), and the boot load runs at line ~133 — **211 lines earlier**. So the
flag was always false for the one call doc 13 §2.9's ANR arithmetic is missing.
`--save-now` *would* have timed a save (the argument loop runs after
`_build_city_view()`), but fault (a) means no argument arrives. **Fixed in this
branch** by setting `log_io` at `SaveService` construction; it needs a new build
to take effect, and then Q6 is one launch rather than a differential.

**Deliverables 1 and 3 are therefore partial and are marked so**: the three-pose
day/night table cannot be filled from this session, and no `PERFIO` save or load
timing was obtained on device. What replaced them is the single-pose steady
state above, which is a real measurement of the player's real city and is the
first frame data this project has from the target device.

**A cost this session charged to the player, recorded because it should inform
how the next one is run.** Every launch resumes the newest save and the sim then
runs — 20–35 s of wall clock per capture, plus doc 08's offline catch-up in
front of it. Across ~15 launches the player's city advanced from
`sim_time_minutes` 32,272 to 33,000 (**day 22 → 23, about 12 sim-hours**) and
its treasury fell **$93,526 → $47,051** to upkeep. Nothing was lost — population
held at 255 → 254 and the save is intact — but the generational ladder keeps
only three entries, so **the pre-session generations rotated off the device** and
survive only in the session's own backup. Two rules for the next device session,
both cheap: **take a `run-as … tar` copy of `files/saves` before the first
launch** (this one did, which is the only reason the pre-session state exists),
and **prefer one long foreground hold over many short launches** — the relaunch
is what costs the player, not the measurement.

##### The 2026-08-21 session — three blockers found, no frame measured

**The pose matrix is still open, and this session did not close it.** It is
recorded because what it found is *why* two device windows in a row produced no
matrix, and because two of the three causes were nobody's suspect.

**The state it walked into was the good one.** The D-20 build was installed
(`lastUpdateTime` 01:10:59, `versionName` 0.4.0), `game/main.gd` reads
`DevArgs.user_args()` at all four sites including `_perf_capture_armed()`, the
launcher alias resolved, the saves were backed up before the first launch, and
`--self-test` passed 25/25. Everything the last session filed as the blocker was
fixed. The window still produced no `PERF` line, for three independent reasons
stacked in front of each other.

**Blocker 1 — the launch command itself was malformed, and had always been.**
`adb shell` does not preserve local argv: it joins everything after `shell` with
single spaces and hands one string to the device's `sh -c`. So the documented

```bash
adb shell am start … --es args "--resume --zoom=1.0"
```

reaches `am` as three tokens and dies with `IllegalArgumentException: Unknown
option: --zoom=1.0` **before the app is launched at all**. The `--esa` form
survived only because its CSV payload contains no spaces. **The consequence is
that the `--es args` half of the "send both extra forms" insurance had never
once reached a device** — including in `tools/bench_device.sh`, whose 20-check
self-test could not see it because the fault is in `adb`'s transport, not in the
string the script builds. Fixed by composing one remote-shell string with the
values single-quoted (`remote_start_cmd`), at both launch sites and in the
`--dry-run` output, which had been printing the broken form for humans to copy.

**Blocker 2 — a locked phone is indistinguishable from a broken build.** The
Fold was on AC at 100 %, screen on, `stay_on_while_plugged_in=15`, `adb`
responsive — and behind a secure lockscreen. In that state `am start` resolves
the activity, launches it, and reports `Starting: Intent {…}` exactly as it does
when unlocked. What the app cannot do is hold a surface:

```
V Godot: OnResume: GodotFragment{…}
V Godot: OnPause:  GodotFragment{…}      <- 21 ms later
V Godot: OnStop:   GodotFragment{…}
```

Godot's main loop is tied to the `SurfaceView`, so **no GDScript runs**: no city
load, no argument parse, no `PERF` line, no screenshot. The symptom is a
telemetry build that appears unarmed and arguments that appear undelivered —
i.e. **it presents as a D-20 regression**, and is only distinguishable from one
by reading the lifecycle callbacks. This is now runbook §1.0, ahead of every
other check. `adb shell wm dismiss-keyguard` raises the Bouncer on a secure lock
and there is nothing further `adb` can do; it needs a human.

**Blocker 3 — the three A/B questions had no lever in the shell.** Independent
of both faults above: `--road-detail`, `--pad-shadows`, `--flood-detail` and
`--flood` existed **only** as `tools/profile_frame.gd` flags. Nothing in `game/`
parsed any of them. So the zebra-optimisation confirmation, the flood-detail
rung and the daylight pad-shadow re-check were **undrivable on the installed
build no matter how well arguments were delivered** — a session that had found
the phone unlocked and the quoting right would still have collected nothing for
those three. `game/main.gd` now has `_apply_render_ab_args()`, applied after the
boot preset seeding so a lever overrides its tier ceiling rather than the other
way round. **It needs a build.**

**What was measured, with the phone locked.** Only what the process logs before
it needs a surface — but one open question closes on it. **The game resolves to
the stock vendor GPU driver**: `Adreno 0762.41`, built 2025-09-19, from
`/vendor/lib64/hw/vulkan.adreno.so`, with `updatable_driver_prerelease_opt_in_apps`
and the production opt-in both `null` and `App is not on the allowlist for
updatable production driver` in the log. **The Qualcomm pre-release driver is
not a suspect for the presentation-corruption bands, and "move it to stable" is
not an available mitigation because it already is stable.** Record that driver
string with any future corruption report.

> **The band has a named suspect and a shipped remedy — Wave 17, 2026-09-01
> (report 98 RR-126, doc 93 §AE, doc 13 §2.8).** The player's verdict after days
> on the Aug-21 build is *"tearing only happens in the sub menus"*; world play is
> clean. That narrows it hard, and it fits one thing in this document better than
> anything else in it: **the app caps `Engine.max_fps` at the preset's
> `target_fps` and had never DECLARED that rate to the display.** `vsync_mode=1`
> is a swapchain property and Swappy consumes the refresh rate rather than
> declaring it, so on this 1856 × 2160 **LTPO 1–120 Hz** panel the platform's only
> input to its mode policy was the app's observed cadence — and a sheet opening
> over a still world is a workload step with no camera motion to hide the re-time.
> `game/render/refresh_pin.gd` plus `SlacumNative.set_frame_rate()` now declare
> it, at the same number and in the same statement as the cap; the mode chosen is
> the smallest supported multiple of the cap, which is also this section's own
> battery answer (60 fps → the 60 Hz mode, not the 120).
>
> **This is a hypothesis with a shipped test, not a fix.** Report 98 §46 has the
> A/B — one binary, `--refresh=off` against `--refresh=auto`, perf capture
> disarmed in both arms so the `viewport_set_measure_render_time` suspect (doc 91
> §19 row 5) is absent from both — and doc 93 §AE3 has the observation that
> refutes it. **Do not close this open band on the pin's existence.** The driver
> string above is still the one to record with any future corruption report, and
> the second suspect if the A/B comes back null is the compositor's handling of a
> full-screen UI layer over the `SurfaceView`, which nothing in this document can
> see from a workstation.

**And the city was read without launching it.** The save manifest carries the
clock, so `--advance-hours` deltas no longer need the HUD read by eye:
`day 31, 09:46, pop 359, $174,414` came out of one `run-as cat` while the phone
was locked. `tools/cap_pose.sh` recomputes it per launch, which makes the
runbook's "re-base `NOW` after every pose" automatic — and because `force-stop`
is an unclean exit that does not write the clock back, a per-pose matrix pays
its delta once per pose instead of accumulating it across the player's city.

**One number the last session left on the floor.** Its contaminated
`log_sustained.txt` contains a `PERFIO` row nobody transcribed:
`kind=save slot=0 reason=manual ms=100.3 bytes=129823 ok=1`. A **100.3 ms save
of a 129 KB slot on device** sits between the workstation's founding-city 14 ms
and its bench-city 149 ms, and is consistent with the 2–3× factor §Q6 asks to
confirm — but it was captured while the app was not reliably foreground, so it
is a plausibility check and **not** the Q6 measurement.

**Still open after two windows, in the order a third should take them:** the
three-pose day/night matrix, the `PERFIO` save/load rows, the zebra A/B, the
flood A/B and screenshot, and the daylight pad-shadow re-check. All five now
need only **an unlocked phone and a build from this branch** — the harness
faults in front of them are fixed and `tools/run_matrix.sh` runs the whole list
in one command, refusing to start if the phone is locked.

> **Superseded by the third session, 2026-08-21 — this list is FIVE items and the
> live one is FOUR.** `PERFIO` is done: the session below took both rows.
> The other four stand, and the sentence about what they need is now true where
> it was aspirational, because the AAR that swallowed every launch argument has
> been rebuilt and `tools/run_matrix.sh build_check` refuses a build that cannot
> receive one. Read the "Still open, and now genuinely unblocked" list at the end
> of the third session, not this one. *(Marker sweep, doc 91 §20.5.)*

##### The 2026-08-21 third session — a settled baseline, both `PERFIO` rows, and why the matrix is *still* open

**The phone was unlocked, awake and in hand, the D-20 branch was installed, and
the matrix still could not run.** The cause was not any of the five things the
previous two sessions had queued up. It is written out in full in
`tools/device_runbook.md`'s "READ FIRST" box; the short form is that **the
`SlacumNative` AAR is a gitignored build artifact that nobody had rebuilt**, so
the installed APK contained the plugin but not `launch_args`, and every dev
argument was dropped in silence. The evidence is static and not inferential:
`launch_args` appears **0 times in all three `classes*.dex`** of the installed
APK while `thermal_status` (the control) appears once.

**The transport half of D-20 is CONFIRMED GOOD on hardware, and that is a real
result.** `logcat` caught the launch line arriving at `am` byte-perfect in both
forms — `--esa command_line_params '--,--resume,--zoom=1.0,--perf' --es args
'--resume --zoom=1.0 --perf'` — so §1.2's quoting fix works and the 2026-08-21
"Blocker 1" is closed. `GodotActivity` still logs `Launch intent … (has extras)
with parameters []`, which is the engine-side drop D-20 exists to route around,
now observed directly rather than deduced.

**The discriminator that separates a stale plugin from a dead build, for the
next session:** with `--perf` on the command line and nothing else arming the
capture, **0 `PERF` lines**; with `touch files/perf_capture.flag` and no
argument at all, **19 `PERF` lines** — same build, same pose, minutes apart.
Telemetry gating on `--perf` is therefore *only* as reliable as argument
delivery, which is the cross-branch hazard the 2026-08-20 box flagged; the flag
file is what made this session measurable at all.

**Measured — the player's real city, foreground, `preset=balanced`
(auto-detected), capture armed by flag file, one 45 s hold.** Day 31, pop 359,
`sim_time_minutes` 45,262. The hold has two regimes and they are reported
separately, because averaging them is what produces a meaningless row:

| phase | t (s) | fps | p95 ms | cpu ms | gpu_est ms | dc | prim | vram MB | chunks | near | inst | knob | thermal |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| streaming in | 2–14 | 111.3–117.9 | 8.3–13.9 | 0.2–0.5 | 5.8–7.1 | 108 | 25,774 | 187 | 9 | 4 | 34 | 0 | 0 |
| **incremental add** | 16 | 80.0 | **36.5** | 0.5 | 6.2 | **149** | 95,186 | 197 | 9 | 4 | 81 | 0 | 0 |
| **settled** | 18–38 | **99.5–112.4** | **10.1–15.8** | **0.3–0.4** | **6.1–6.8** | **103–107** | ~37,270 | **198** | 9 | 4 → 6 | 81 | **0** | **0** |

*(`near` is 4 in the `t = 18 s` sample and 6 from `t = 20 s` onward — the tier
settles one sample after the instance count does. Ranges are the real min..max
across the phase, not a mean ± anything.)*

**Four things this says.**

**1. At this pose the frame is nowhere near any budget, and the governor never
moved.** `dc` **103–107 against §2.13's 320** (a 67 % margin, wider than the
41–56 % the 2026-08-20 session saw), `cpu` **0.3–0.4 ms against 4 ms**,
`gpu_est` **6.1–6.8 ms against 16.7 ms**, `knob = 0` for the entire hold and
`thermal = 0` throughout. This is a **larger** city than the one that drove the
governor to `knob = 4` on 2026-08-20 (pop 359 vs 255, `inst` 81 vs 70), so the
earlier session's governed rows are **not** explained by city size. What
separates them is not yet established and the two candidate causes it named —
the 4 MP panel and the shadow pass — both survive. **The `near` column differs
(6 here, 4 there), so these are different camera positions and the comparison is
suggestive, not controlled.** That is exactly what the pose matrix exists to fix.

**2. The city's incremental stream-in costs one visible hitch.** At `t = 16 s`
`inst` goes 34 → 81 and `dc` spikes to **149** — the run's maximum, and the only
sample above 110 — with **p95 36.5 ms**, i.e. a dropped frame at 120 Hz, four
frames' worth. It resolves in a single 2 s sample and never recurs. It is an
incremental-add cost, not a steady-state one, and it is the first device
evidence that the add path is worth a budget of its own.

**3. `vram` 187 → 198 MB, `static_mem` 138 → 148 MB** across the same
transition, both flat afterwards.

**4. Both `PERFIO` rows are captured — deliverable 3 of the 2026-08-20 session,
which had neither.**

| row | line | note |
|---|---|---|
| **boot load** | `kind=load slot=0 reason=slot ms=165.5 write_ms=0.0 read_ms=24.0 restore_ms=136.2 async=1 bytes=202946 ok=1` | **The first ever.** Fault (c) above — `log_io` set 211 lines after the boot load — is **fixed and confirmed fixed on device.** |
| **lifecycle save** | `kind=save slot=0 reason=pause ms=159.4 write_ms=42.9 bytes=203538 ok=1` | `reason=pause`, i.e. the real backgrounding path, not `--save-now`. |

**Read against doc 13 §2.9's ANR arithmetic:** a **165.5 ms boot load** of a
203 KB slot, of which only **24.0 ms is I/O** and **136.2 ms is restore** — so
the load is CPU-bound on deserialisation, not on storage, and shaving it is a
restore-path question. The **159.4 ms save** (42.9 ms of it the write) sits
close to the 100.3 ms/129 KB row the previous session left on the floor and
scales with it roughly by size. Both are inside a 500 ms `onPause` window with
room to spare, on a 203 KB slot.

> **The capture is stamped `CONTAMINATED` and the frames are still good — read
> the stamp carefully.** `cap_pose.sh` asserts foreground before and after the
> hold; the user picked the phone up during this one, so the *after* assertion
> failed. But Godot stops emitting once it loses its surface: the last `PERF`
> line is `06:05:29.030` and the `PERFIO … reason=pause` is `06:05:29.752`, so
> **every frame above was rendered in the foreground** and the backgrounding is
> what produced the save row. The stamp means "the hold ended dirty", not "the
> samples are dirty" — and the ordering is what proves which.

**Two harness faults found and fixed, one of which made the session's own tool
unrunnable.** `tools/run_matrix.sh` gated on
`printf '%s' "$d" | grep -q 'mDreamingLockscreen=false'`. `grep -q` exits at the
first match, `printf` takes SIGPIPE on the remaining ~200 KB and dies **141**,
and under `set -o pipefail` **the pipeline reports the writer's failure instead
of grep's success** — so on an awake, unlocked, focused phone the script printed
`REFUSING TO RUN: the phone is LOCKED` **every single time**. Verified on device:
status `141` on the 200 KB dump, status `0` on a 25-byte string, which is why no
test caught it. `cap_pose.sh`'s `is_foreground()` carried the same construct,
where it is *racy* instead of constant and intermittently stamps good captures
`CONTAMINATED`. Both are now pipe-free. **Rule: never put `grep -q` downstream
of a large writer under `pipefail`.** Separately, `adb exec-out screencap -p`
with no `-d` prints a *"Multiple displays were found"* warning **ahead of the
PNG bytes** on this two-display phone, so the flood screenshot would have been
an unopenable file with no error — `cap_pose.sh --snap` now resolves the display
and verifies the signature.

**Still open, and now genuinely unblocked:** the three-pose day/night matrix,
the zebra A/B, the flood A/B and screenshot, and the daylight pad-shadow
re-check. All four need arguments; arguments only began working after this
session rebuilt the AAR, re-exported and reinstalled, by which point the phone
was in use. **The fixed build is installed and verified on the device**
(`tools/run_matrix.sh build_check` → `launch_args in dex: 1`), and
`build_check` now refuses the matrix on a build that cannot receive arguments,
so the next window starts at the measurements with no repair in front of it.

**Cost charged to the player this session: two launches, ~3 sim-hours
(`sim_time_minutes` 45,262 → 45,441) and a treasury move $175,791 → $96,141.**
Population held at 359 and the save is intact; a `tar` backup was taken before
the first launch and is at `tools/device_results/saves_backup_prewf187.tgz`.
`adb install -r` preserved the saves through the reinstall, verified after.

**Method, and what it does and does not claim.** Every A/B below is interleaved
*within* each round — both arms measured back to back, three or four rounds — on
a workstation that was carrying other Godot work for part of the session (four
engine processes at 100 % CPU at one point). That is the same convention the
Wave-7 and Wave-8 tables above use and for the same reason: **absolute
milliseconds drift with machine load and the round-paired DELTA does not.** Where
an arm's spread is quoted, it is the actual min..max across rounds, and a delta
smaller than that spread is reported as "below the noise floor" rather than as a
number. The draw-call, chunk-census and primitive columns are exact and repeat to
the digit.

Two things were found before a single question could be asked, and both matter
more than the answers.

**1. The harness was rendering at 1280×720 while every table said 1920×1080.**
`tools/profile_frame.gd` set `root.size` in `_initialize`, which the window
created from `[display] window/size/viewport_*` silently overrides. Caught by
dumping `--shots` and reading the PNG header: 1280×720 whatever `--resolution`
asked for. **Every millisecond column in this section published before today was
measured at 0.44× the pixels it claims** (`1280·720 / 1920·1080 = 0.444`).
**The record corroborates itself**: the bucket-merge subsection above reports
"Z0 and Z1 are BIT-IDENTICAL, **0 of 921,600 pixels** differing" — and 921,600 is
1280 × 720. The true pixel count was printed beside the wrong resolution label
for a year and nobody read the two together. The draw-call, chunk and primitive
columns are unaffected — they are resolution-independent, and they are the ones
the budget is written against — but the ms columns are not comparable with
anything after this date. The fix goes through `DisplayServer.window_set_size`
and `_verify_resolution()` now reads the live viewport back and refuses to print
a number under a resolution it did not get.

**2. Every measured frame in this section was taken at hour 21, and at 21:00 the
sun is down.** The shadow pass in all of them is empty. Measured at hour 13 on
the same build, same city, same poses:

| city | pose | dc at hour 21 | dc at **hour 13** | Δ | +UI vs the 320 budget | headroom |
|---|---|---|---|---|---|---|
| founding | Z0 | 31 | **69** | +38 | 94 | 70.6 % |
| founding | Z1 | 42 | **80** | +38 | 105 | 67.2 % |
| founding | Z2 | 80 | 80 | **0** | 105 | 67.2 % |
| bench | Z0 | 95 | **237** | **+142** | **262** | **18.1 %** |
| bench | Z1 | 113 | **233** | +120 | **258** | 19.4 % |
| bench | Z2 | 196 | 196 | **0** | 221 | 30.9 % |

**The 31.6 % headroom this section advertises at Z2 is a night figure, and the
tightest daylight pose has 18.1 %.** Nothing is over budget and no conclusion in
this section is overturned — but the margin the doc quotes is roughly twice the
margin the game has at noon. **Read carefully which pose moved:** the street
pass's headline "220 of 320" is a **Z2** figure and daylight barely touches it
(221), because Z2 has no shadow pass to fill. What daylight costs is **Z0 and
Z1**, the two poses this section has never published a headroom figure for —
120 → 262 and 138 → 258 — and Z0 is now the tightest pose in the game at 18.1 %,
a title Z2 has held in every table above. Every future frame table in this
section must state its hour.

**The chunk census is identical day and night** — bench Z0 is 12 NEAR / 24 MEDIUM
/ 0 FAR at both hours, Z1 is 8 / 28 / 0, Z2 is 0 / 16 / 20 — so the whole delta
is the shadow pass and nothing else moved. That makes it divisible: **142 extra
calls over 12 NEAR chunks × 2 splits is 5.92 per chunk per split, and 120 over
8 × 2 is 7.50.**

**That closes half of D-16 with a number instead of an argument.** §2.13's Z1
worst case costs the shadow pass at `6 × 16.4 buckets × 2 splits = 197` calls,
using the measured 16.4 per-(chunk, archetype, level) buckets the un-merged NEAR
tier allocates. The daylight measurement says the shadow pass actually submits
**5.9–7.5 per chunk per split** — a quarter of that — because the split frustum
culls most of a NEAR chunk's buckets before they are drawn. D-16's arithmetic is
not merely pessimistic in the abstract; it is **2.2× pessimistic against a
measured sunlit frame**, which is the evidence the "take it the first time a
device measurement puts a close-zoom pose near 320" test was waiting for. Z0 in
daylight is the closest any pose has come, and it is at 262.

The same table **confirms two standing claims by measurement for the first
time**: Z2 is genuinely the shadow-free pose — its draw-call count is **identical
at hour 13 and at hour 21, to the digit, on both cities** (196 on the bench, 80
on the founding), because no NEAR chunk exists there and `shadow_max_m` 150 m is
well below the 370.8 m camera — and the founding city tracks the benchmark
city's shape at a tenth of the scale.

##### The asphalt fragment ladder (streets q3)

`road_surface.gdshader` gains a `detail` uniform — **2** everything, **1** drops
the wear terms (the 11 m hash mottle, the pour joint, the wheel-path polish, the
kerb grime) and keeps every line of paint including the crossings, **0** also
drops the four-leg zebra loop. Every branch on it is on a UNIFORM, so it is one
scalar decision per draw and the `fwidth()` calls inside those branches are taken
in uniform control flow. `data/render.json` → `road_surface.detail` is the
project ceiling, `presets.*.road_detail` the per-tier one,
`RoadSurfaceView.set_detail()` the live rung, and it may only ever be lowered.

Founding city, camera on the Grand/Slacum junction so the carriageway fills the
Z0 frame, `RenderingServer`'s own GPU time, three interleaved rounds per arm,
1920×1080, Balanced, 90 warm-up + 300 measured:

| pose | hour | rung 2 | rung 1 | rung 0 | wear (2→1) | zebra (1→0) | ladder (2→0) | ladder as % of the pose's GPU |
|---|---|---|---|---|---|---|---|---|
| Z0 | 21 | 1.5176 | 1.4730 | 1.3637 | 0.0446 | **0.1093** | 0.1539 | **10.1 %** |
| Z1 | 21 | 1.1181 | 1.1136 | 1.0832 | 0.0045 | 0.0304 | 0.0348 | 3.1 % |
| Z2 | 21 | 0.9929 | 0.9899 | 0.9677 | 0.0030 | 0.0222 | 0.0252 | 2.5 % |
| Z0 | 13 | 1.8584 | 1.8030 | 1.6956 | 0.0554 | **0.1074** | 0.1628 | 8.8 % |

The arms do not overlap at Z0 in either lighting (rung 2 spans 1.5134–1.5223,
rung 1 1.4652–1.4827, rung 0 1.3505–1.3765 at hour 21), so the deltas are
signal, not spread.

**The finding is the split, not the total: the zebra loop costs 2.4× every wear
term put together**, and it paints only on junction tiles. It is the one place in
the file where `fwidth()` is taken eight times and `dashes()` four times inside a
loop, and it is the term to reach for first if a device ever needs the street to
be cheaper.

**Ruling: the ladder is a per-preset ceiling and a device escape hatch, NOT a
governor rung.** Balanced and High take rung 2; Performance takes rung 1
(provisional, marked as such in `data/render.json`) because a tier-C part at
`render_scale` 0.70 resolves an 11 m hash mottle as noise and its ALU:bandwidth
ratio is far worse than this workstation's. Rung 0 is shipped by no preset,
because losing the crossings changes what the street MEANS. It is not on
`governor.knobs` because 0.15 ms does not pay for a street that changes
appearance mid-pan — every existing rung degrades *fidelity*, and this one would
degrade the *drawing*.

**Rung 2 is the shipped look, proved rather than asserted.** 1920×1080 captures
one shader apart, against `git show HEAD:` of the pre-ladder file: **Z0 differs
on 0 of 2,073,600 pixels**, Z1 on 15 and Z2 on 30 — against a same-build control
run that differs on 0 / 4 / 29, i.e. the residual is §2.6's own `near_flicker`
sampled a frame apart and nothing of the road at all. The first attempt did NOT
achieve this: hoisting the per-tile wear trim out of the branch turned
`1 + patch + seed` into `(1 + seed)(1 + patch)` and moved 1,756 Z0 pixels by up
to 4/255. The cross term is now folded back into one multiply and the comment in
the shader says why.

**Do the band-limited dashes hold still at Z2?** Answered from the geometry, and
the derivation reproduces §2.5's own numbers so it is checkable. At Z2 the camera
is `420·sin 62° = 370.83` m up and the 40° vertical FOV spans 42°–82° below
horizontal, putting the near ground edge at `370.83/tan 82° = 52.1` m and the far
at `370.83/tan 42° = 411.8` m — this section's own `r_near` and `r_far`. The
per-pixel ground footprint over 1080 rows is `(h/sin²θ)·(40°/1080)`: **0.245 m/px
at the bottom of the frame, 0.535 m/px at the top.**

| pattern | period | px per period at Z2 | `dashes()` band-limit mix |
|---|---|---|---|
| lane divider | 8.00 m | 33 → 15 | 0.05 → 0.17 |
| centre dash | 6.00 m | 24 → 11 | 0.06 → 0.23 |
| crosswalk ladder | 0.85 m | 3.5 → **1.6** | 0.45 → **1.00** |

*The two right-hand columns are on deliberately different bases and both are
right: pixels-per-period is the footprint along the dash's own axis (0.245 →
0.535 m/px), while the mix is `clamp(0.75·fwidth·2/period)` and GLSL's `fwidth`
SUMS both screen partials, so its worst case at this pose is 0.535 + 0.374 =
0.909 m/px for a carriageway crossing the view. The mix column is therefore the
pessimistic one, which is the direction an anti-aliasing claim should err in.*

`dashes()` reaches a full duty-cycle fade at `aa ≥ period/2`, i.e.
`fwidth ≥ period/1.5` = **5.33 m/px** for the lane dash — ten times the worst
per-pixel footprint anywhere in a Z2 frame, and six times the worst `fwidth`. **So the lane and centre dashes at Z2 are
sampled 5×–16× above Nyquist and cannot crawl, and what holds them still is
`band()`'s own smoothstep rather than the band limit.** The band limit is doing
real work on exactly one pattern — the 0.85 m crosswalk ladder, at or below two
pixels per period at the top of the frame, where it correctly reaches 1.0.
**§2.1.2's sentence "`dashes()` carries an explicit band limit — past Nyquist it
fades to the pattern's duty cycle, because a `fract()` sampled sub-period crawls
and the marketed skyline frame would shimmer along every lane line" is true of
the CROSSINGS and not of the lane lines**, and is corrected there. **Checked with the eye as well as the arithmetic.** A Z2 dolly along Slacum Ave,
eight 1920×1080 frames at 1 m steps — one full 8 m lane-dash period, so a
crawling pattern would visibly reshuffle across the set — was captured through
`tools/profile_frame.gd --poses=z2 --focus= --shots=` and flipped through. The
dashes **translate**: identical mark length and spacing in every frame, at every
depth in the frame, with no beat. The crossings at the junction boxes read as
solid white squares at this zoom rather than as bars, which is the band limit
reaching 1.0 on the 0.85 m ladder — the table's prediction, visible.

Foldable
sensitivity: the footprint scales as `1080 / rendered_rows`, so **unfolded**
(2160×1856 panel, landscape height 1856, `render_scale` 0.85 → ~1578 rows) every
margin improves by **0.68×**, and **folded** (2376×968 cover → ~823 rows) it
worsens by **1.31×** and the lane dash is 25→11 px/period, still 5× above
Nyquist. Neither screen aliases; the cover screen is the one to check first.

##### The pad shadow A/B (power q6)

`PowerInfraView.set_pad_shadows()` existed and had never been priced. **It cannot
be priced at night** — the first attempt was run at hour 21, where the sun is
below the horizon and there is no shadow pass for the pads to be in, and it
measured nothing. Both arms below are hour 13, four interleaved rounds each.

| city | pads | pose | dc with | dc without | Δ dc | GPU with | GPU without | Δ GPU | instrument spread |
|---|---|---|---|---|---|---|---|---|---|
| founding | 18 | Z0 | 69 | 68 | **+1** | 2.0641 | 2.0680 | −0.0039 | ±0.011 |
| founding | 18 | Z1 | 80 | 79 | **+1** | 1.4034 | 1.4088 | −0.0054 | ±0.013 |
| founding | 18 | Z2 | 80 | 80 | **0** | 1.1710 | 1.1541 | +0.0170 | ±0.035 |
| bench | 144 | Z0 | 237 | 236 | **+1** | 2.2780 | 2.2433 | +0.0347 | ±0.28 |
| bench | 144 | Z1 | 233 | 232 | **+1** | 3.2518 | 3.0258 | +0.2260 | ±0.46 |
| bench | 144 | Z2 | 196 | 196 | **0** | 3.0507 | 2.9658 | +0.0848 | ±0.28 |

**The price is exactly one draw call at the two poses that have a shadow pass at
all, and zero at Z2** — the pad buffer is one city-wide MultiMesh under one
custom AABB, so it is submitted whole, once, and the count does not grow with the
roster. On the founding city, where the instrument's own spread is ±0.011 ms, the
GPU delta is **negative in two of three poses**: there is no cost to find. On the
benchmark city the spread is 40× worse and the largest arm difference (+0.226 ms
at Z1, 7 % of that pose's GPU pass) is an **upper bound**, not a measurement.

**Ruling: `power_infra.pad_shadows: true`**, authored in `data/render.json` and
read by `PowerInfraView.setup()` instead of hard-coded in `_build_pads()`. One
draw call of 320 is 0.3 %; turning it off costs the read the layer exists for.
Revisit only if a Fold daylight Z0/Z1 pose lands within 5 % of the budget.

##### The construction layer at real site counts (construction q1/q2)

| city | sites | layer CPU mean (Z1) | p95 | draw calls | §2.16 budget |
|---|---|---|---|---|---|
| founding | 0 | layer not built | — | 42 | — |
| founding | 1 | **0.045 ms** | 0.055 | 47 (**+5**) | 0.8 ms |
| founding | 2 | **0.081 ms** | 0.085 | 47 (+5) | 0.8 ms |
| founding | 3 | **0.105 ms** | 0.112 | 47 (+5) | 0.8 ms |
| founding | 28 (`max_sites`) | **0.549 ms** | 0.590 | 47 (+5) | 0.8 ms |
| bench | 20 | 0.539 ms | 0.567 | +5 | 0.8 ms |
| bench | 28 (`max_sites`) | **0.728 ms** | **0.767** (0.818 at Z2) | +5 | 0.8 ms |

1. **At the counts the founding city actually runs the layer is free.** 0–3
   simultaneous sites is 0.000–0.105 ms — at most **2.6 % of Balanced's 4 ms CPU
   budget**. §2.16's 1.5–1.9 ms estimate at 20 sites was 3× pessimistic; the
   measured slope is **0.020 ms/site** on the founding city, 0.026 on the bench.
2. **The +5 draw calls are now measured from a true zero.** §2.16 could only
   quote 5 as a ceiling because the no-site case had never been run; 0 sites is
   42 calls and 1 site is 47, so five is the whole layer — one MultiMesh per model
   kind — and it does not move between 1 and 28 sites. §2.16's parenthetical is
   closed.
3. **At the shipped ceiling the layer is at its own budget line on a
   workstation.** 28 sites on the bench city is 0.728 ms mean / 0.818 ms p95
   against an authored 0.8 ms that was written against 20 sites, not against
   `max_sites`.

**Ruling on the governor knob: no.** A rung that lowered `max_sites` would only
fire on a city with twenty-plus simultaneous sites — a *player action*, not a
device condition — and what it buys (0.6 ms) is bought by taking half the working
sites in view still, mid-pan. Every existing rung degrades fidelity; this one
would degrade content, and the governor's contract does not reach there.
`max_sites` stays 28 and `construction_vehicle_view.gd`'s ruling that the site
ceiling is an art call stands. **Filed, not taken:** a
`presets.performance.construction_sites` row of 12 (0.31 ms here) would sit
beside `civ_cars` and `emergency_nodes`, which cap exactly this kind of
population per tier; overturning another branch's stated ruling wants the tier-C
number this session did not get.

##### Wires and the pad super-block (power q2) — closed without a change

Asked as *"only if numbers say primitives hurt on Vulkan mobile"*. They do not.
The pad buffer is a flat **+29,376 primitives** and **+1 draw call**, and a
per-chunk super-block would spend 16 calls at Z2 to cull a buffer smaller than
the cull test's own bookkeeping. The wire buckets measure **0 at Z1 and 0 at Z2**
on both cities, because `wire_fade_end_m` 58 m is below the Z1 camera height of
64.6 m and the layer gates itself out before distance could matter — there is
nothing for a fade change to buy. Re-open only if a Fold `PERF` line ever shows
`prim` climbing while `dc` holds and the frame is late at the same time.

##### Save and load — the number nobody had (Wave-7 persistence)

`tools/profile_save.gd` is new and drives the **shipped** path —
`SaveService.save_slot` / `load_slot`, the calls the lifecycle makes — into a
scratch directory it creates and removes. Headless, best of 7 (founding) and
best of 5 (bench):

| city | save best / mean / worst | load best / mean / worst | slot bytes (whole ladder) |
|---|---|---|---|
| founding (34 buildings) | 13.9 / 14.4 / 14.8 ms | **48.5 / 49.2 / 50.0 ms** | 42,359 |
| bench (1,500 buildings) | 119.9 / 138.5 / 154.2 ms | **428.8 / 455.6 / 482.9 ms** | 263,027 |

**A load of the founding city is three frames at 60 Hz on a workstation, and a
save is most of one.** On the 1,500-building city a load is 0.46 s and a save is
0.14 s, synchronously, on the main thread. Two consequences that are not this
doc's to fix but are this doc's to publish: doc 08's autosave lands a **visible
hitch** as soon as a city is a few hundred buildings — the cadence is fine, the
synchronous write is not — and doc 13 §2.9's ANR arithmetic budgets the catch-up
without budgeting the **load in front of it**, which on the bench city is half a
second before a single coarse step runs. `SaveService.last_save_ms` /
`last_load_ms` and the `PERFIO` log line are the instruments; the device half is
`tools/device_runbook.md` §Q6, which gets the same numbers out of the installed
build as a difference of `am start -W` cold starts.

##### And the telemetry §7.4 assumes exists, did not

`PerfGovernor.perf_line()` shipped in Wave 6 with a test on its shape. **Nothing
ever called it.** §7.4 documents `adb logcat -s godot:V | grep '^PERF'` as the
on-device instrument and `tools/bench_device.sh` is built on it, so a device
session against the shipped build collects an empty CSV and the harness's own
summariser prints "NO PERF LINES". `game/render/perf_telemetry.gd` is the
wiring — `RefCounted`, clock-injected, engine-facing, deliberately a separate
file so `PerfGovernor` stays the Node-free model its microsecond tests need. It
takes three lines in `game/main.gd` and it is not applied here, because
`game/main.gd` belongs to the lead.

`tools/bench_device.sh` has two further faults that a device session would have
found the hard way, both readable in `game/main.gd` rather than guessable:
`--es cmdline` is the wrong `am` flag (Godot's launcher reads a string ARRAY
extra, and `OS.get_cmdline_user_args()` returns only what follows a literal
`--`, so the extra must be `--esa command_line_params "--,…"`), and
**`--bench=S1|S2|S3`, `--preset=` and `--city=` are parsed by nothing** — the
shell's whole scenario vocabulary is `--resume`, `--title`, `--zoom=`,
`--focus=`, `--advance-hours=`, `--overlay=`, `--rain=`, `--storm=`, `--wet=`,
`--blackout`, `--cut-feeder=`, `--place=`, `--save-now`, `--screenshot=` and
`--shot-at=`. That vocabulary is enough for all six questions, which is why the
runbook drives the installed build with it instead of asking for a new one.

> **FIXED 2026-08-20 (Wave 12): `tools/bench_device.sh` is rewritten against the
> runbook and the vocabulary above.** All three faults are closed in the script
> rather than described in a document. It resolves the activity live
> (`cmd package resolve-activity --brief`) instead of hard-coding
> `com.godot.game.GodotApp`; it launches with **both** forms —
> `--esa command_line_params "--,a,b"` and `--es args "a b"` — because
> `game/dev_args.gd` merges and de-duplicates them, so either delivery path being
> broken costs nothing; and `--bench=S1|S2|S3` is gone. Doc 11 §7.4's three
> scenarios survive as `--scenario=S1,S2,S3`, re-expressed in flags the shell
> parses (`--resume --zoom=0.5 --hour=13` and so on), beside
> `--question=Q1|Q6|preflight|extras` which drives the runbook's own poses.
>
> **`--hour=H` is the script's shorthand and is resolved to `--advance-hours=`
> before it leaves the process**, against a `--now=H` the operator reads off the
> HUD — because `--advance-hours` is a DELTA and the runbook names getting that
> wrong as the easiest way to spend a device window measuring dusk twice. The
> script re-bases `--now` after every pose, and refuses a pose that names an hour
> when `--now=` was not given.
>
> **`--self-test` runs everything that does not need a device** — the flag
> vocabulary against `game/main.gd`'s own parse table, the hour arithmetic
> including the day wrap and the re-base, the pose and scenario tables, the two
> extra forms on the launch line, and both summarisers against known answers.
> **20 checks, all green.** It found three real bugs while it was being written,
> one of which would have silently ruined every capture: a comma-separated pose
> list set `IFS` globally, `resolve_hours` splits its argument on whitespace, and
> so every pose launched with the unresolved `--hour=` — a flag `game/main.gd`
> ignores — and was captured at whatever hour the save happened to hold. That
> case is now one of the 20 checks.
>
> **The device half remains unverified and the script says so** in its own
> `--self-test` summary: activity resolution, argument delivery, the
> `gfxinfo`/`meminfo`/`thermal` collection and the Q6 cold starts have still
> never met hardware. `--question=preflight` is the first thing a session should
> run.

#### The performance ladder — four named levers, measured (2026-08-20)

The Fold session and the render follow-ups left four levers with a name and a
number against each. This is what taking them cost and bought. Every arm below
is **interleaved within its round** — before, after, before, after, in one
session on one machine — because a shared workstation's absolute millisecond is
not a result and a round-paired delta is.

##### 1. The zebra loop — the junction early-out (§2.1.2, RR-42)

The Fold session's headline finding was the split, not the total: `road_surface
.gdshader`'s four-leg crossing loop cost **0.107–0.109 ms at the Z0 pose, 2.4×
every wear term put together**, and it painted only on junction tiles. The named
fix was to hoist the eight `fwidth()` calls and early-out on the crosswalk mask,
which is already in the per-instance `.b` channel.

`cw_mask` decodes out of `v_pack`, which is `flat` — constant across a primitive,
and a derivative quad never spans two primitives — so `detail >= 1 && cw_mask >
0.5` is **quad-uniform**, which is the scope the derivative rules are written at.
The eight `fwidth()` calls are four distinct values, because legs 0/2 and 1/3
differ only in the sign of their perpendicular coordinate and `fwidth(-x) ==
fwidth(x)` bit-for-bit.

Founding city, camera on the Grand/Slacum junction, 1920×1080 Balanced, 90
warm-up + 300 measured frames, `RenderingServer`'s own GPU time, three
interleaved rounds:

| pose | hour | rung | before (3 rounds) | after (3 rounds) | Δ |
|---|---|---|---|---|---|
| Z0 | 21 | 2 | 1.5115 1.5221 1.5295 | 1.4745 1.4579 1.4694 | **−0.0537** |
| Z0 | 21 | 1 | 1.4867 1.4693 1.4948 | 1.3971 1.4186 1.4177 | **−0.0725** |
| Z0 | 21 | 0 | 1.3624 1.3691 1.3724 | 1.3663 1.3718 1.3887 | +0.0076 |
| Z0 | 13 | 2 | 1.8358 1.8601 1.8539 | 1.7718 1.7927 1.7980 | **−0.0624** |
| Z0 | 13 | 1 | 1.8020 1.7952 1.8030 | 1.7310 1.7368 1.7343 | **−0.0660** |
| Z0 | 13 | 0 | 1.6824 1.6935 1.6955 | 1.6894 1.6935 1.6909 | +0.0008 |
| Z1 | 13 | 2 | 1.4508 1.4688 1.4759 | 1.4166 1.4259 1.4304 | **−0.0409** |
| Z2 | 21 | 2 | 0.9825 0.9848 1.0017 | 0.9804 0.9547 0.9736 | −0.0201 |

**Rung 0 is the control and it is the noise floor.** The zebra block never runs
there, so the two arms are the same program; they agree to +0.0008 at hour 13 and
+0.0076 at hour 21, and the rung-1 and rung-2 arms do not overlap in either
lighting.

**The zebra term itself — `rung 1 − rung 0`, which is what the loop costs:**

| pose | hour | before | after | change |
|---|---|---|---|---|
| Z0 | 21 | 0.1156 | 0.0355 | **−69 %** |
| Z0 | 13 | 0.1096 | 0.0427 | **−61 %** |

The brief asked for the ladder's rung-2 cost to be halved. It is cut by 61–69 %,
and the whole ladder (`rung 2 − rung 0`) falls from 0.153 to 0.092 ms at Z0/21.

**Pixel identity, proved the way RR-33 proved it, and the same scar reappeared.**
Z0 is the pose where a same-build control run is **byte-identical**, so it is the
only pose with no noise floor at all; Z1 and Z2 differ on 2–421 pixels between
two runs of the *same* build (§2.6's `near_flicker`), and nothing measured there
is a result. At Z0, at rungs 2, 1 and 0, at hours 21 and 13: **0 of 2,073,600
pixels differ.**

It took two attempts, exactly as the ladder did. The first version also folded
the shared terms out — legs 0 and 2 provably share their `dashes()` call and
their carriageway clip, and `max(a,b)·k ≡ max(a·k, b·k)` for `k ≥ 0` because
correctly-rounded multiplication is monotone. Algebraically exact; **1 pixel of
2,073,600 moved at hour 21 and 4 at hour 13, at rungs 1 and 2 and never at rung
0**, which places it in the zebra block beyond argument. An algebraically-exact
regrouping is not a codegen-exact one. The shipped form hoists the derivatives
and adds the branch, and leaves every surviving expression as the same
operations on the same floats in the same order. `road_surface.gdshader` records
the rejected version and why.

##### 2. The construction layer's poses — a cache with an exact key (§2.16, RR-42)

RR-32 split `ConstructionVehicleView`'s 0.53 ms at 20 sites into **0.32 ms of
pose computation and 0.09 ms of upload** and named the pose half as the next
lever. `tools/profile_construction.gd` is the instrument for it — headless, real
`RoadNetwork` off `data/starter_city.json`, real `ConstructionVehicleView`, and
**both arms in one process alternating inside each round**, which is the only way
a sub-millisecond GDScript delta on a shared machine is a measurement.

Most of what a site emits is not a function of the clock at all. A barricade run
is fixed by the frontage and the stage; a heap by `delivered` and the stage; a
machine's transform and livery by the frontage. Only the excavator's joint
channels and the lorries animate. And the `Pose` objects are POOLED — so when a
site's slice of a pool has not moved and none of the facts behind those poses
has changed, the objects in that slice already carry exactly the floats this
frame would write. **Skipping is declining to write the same bits twice.**

Three keys, each written in exactly one place: `layout_serial` (bumped by
`_lay_out_fittings` and `_lay_out_barriers`, which every re-route and every stage
change passes through), `stage`, and `delivered`. A site that did not emit on the
immediately preceding pass re-emits unconditionally, because the pool slice it
owned may have been handed to another site while `radius` or `limit` gated it
out — which is the one way a slice-index cache can be wrong and the one no amount
of steady-state running would show.

Two changes ride with it and are worth as much as half the cache: the schedule's
three derived numbers (`leg`, the round trip, the trip window) are settled once
per route in `_reprice` instead of by four nested function calls per site per
frame, and `dig_pose` reads two `PackedFloat64Array` columns instead of an Array
of Arrays.

`ConstructionActivity.refresh()`, 1,500 frames per arm, three interleaved rounds:

| sites | HEAD | branch, cache off | branch, cache on | vs HEAD |
|---|---|---|---|---|
| 20 | 0.2158 0.2195 0.2179 | 0.1888 0.1902 0.1890 | **0.0959 0.0974 0.0960** | **−55.7 %** |
| 28 (`max_sites`) | 0.3030 0.3058 0.3046 | 0.2667 0.2678 0.2695 | **0.1343 0.1354 0.1373** | **−55.4 %** |

**0.096 ms at 20 sites against the 0.10 ms target.** HEAD's own two columns are
the control — it has no cache, so both arms run the same code and agree to
−0.0 %/−0.7 %, which is this instrument's noise floor.

**Confirmed end to end in the shipped harness**, where the number also carries
`_service_routes` and the MultiMesh upload the headless instrument leaves out —
`tools/profile_frame.gd --sites=20`, Z1, hour 13, 60 + 300 frames, three
interleaved rounds:

| round | before | after |
|---|---|---|
| 1 | 0.357 ms (p95 0.363) | **0.211** (p95 0.217) |
| 2 | 0.354 (0.363) | **0.215** (0.222) |
| 3 | 0.352 (0.360) | **0.212** (0.221) |

**0.354 → 0.213 ms, −40 %**, arms nowhere near overlapping. The whole layer at
20 sites now costs less than half what RR-32's upload-optimised pass left it at
(0.447 ms at this pose), against §2.16's 0.8 ms budget. `max_sites` was not
re-measured in this harness — the headless instrument reports 0.136 ms of pose
work there, so the layer's own budget is not the question it was.

**The contract is bit identity, and it is a property test rather than a claim.**
`tests/test_construction_living.gd` replays one scripted 700-frame timeline —
irregular game-minute steps, stage changes at 5 % of frames, a focus gate that
walks the city so sites drop out of the pass and come back — on a cached and an
uncached view, and compares every field of every emitted pose. The profiler
carries the same check as `--verify`.

##### 3. The congestion pass — the dirty set that cannot exist, and the one that can (doc 10 §9.3 C-3, doc 91 D-15, RR-43)

The brief was to build the dirty-set form of `roads_congestion`: only edges whose
inputs changed recompute, with unchanged inputs producing bit-identical output.
**The measurement says the skippable set is empty, and it is a one-line census
rather than an argument:**

```
THE DIRTY SET'S CENSUS
edges whose c_e moved on the last full pass: 3092 of 3092
```

`hour` is an input to **every** edge on **every** pass, through
`D_tod(district, hour)`, and the smoother `c ← c + (c_raw − c)·α` never lands on
its target. So an ordinary pass moves every edge in the graph, a skip-list has
nothing to skip, and a dirty set that skipped an edge whose closures and
condition had not changed would not be an optimisation — it would be a different
simulation, and the hash would say so. **The skip-edges form is refused, and the
census is `CongestionModel.last_moved`, printed by `tools/profile_congestion.gd`
so the refusal stays checkable.**

What DOES hold still between passes is each edge's road CLASS and DISTRICT — and
those two are the whole of `c_raw`'s shared factor, `K_base(class) · D_tod
(district, hour)`. **That is the dirty set this pass can have:** the (class,
district) pairs are resolved once per graph, priced once per pass, and the
per-edge loop reads an index. The key is exact — `district_id` is written only by
`RoadNetwork._assign_districts` and `road_class` only where an edge record is
built, and both are followed by `_refresh_all_edge_state`, which invalidates.
Association is preserved to the term: `K · demand · dens · evt` binds left to
right, so `kd = K · demand` then `kd · dens · evt` is the same float.

Three more whole-graph sweeps went with it, all exact:

* **`mean_congestion()` folded into the pass.** It walked every edge a SECOND
  time immediately after the pass had written every one of them. The sum is now
  taken inside the loop, over the same ids in the same ascending order. Only the
  whole-graph caller may read it; the dirty-set callers in `step()` hand in a
  handful of ids and their mean is over edges the pass never looked at.
* **The district roster memoised on `graph_version`.** `_congestion_env()` swept
  every edge with a `String()` per edge to collect a dozen distinct district ids.
  The WEIGHTS are still fetched fresh every pass — doc 09's land use moves under
  the roster without moving the roster.
* **`dark_signal_counts_by_edge()` early-outs on a maintained count.** Its own doc
  comment claimed O(dark nodes) and it was O(all nodes): 0.28 ms of a 7.76 ms
  pass, taken once a game-minute whether or not a single signal was dark.
  `refresh_signal_power` already visits every node every tick, so the count falls
  out of it for nothing.

`tools/profile_congestion.gd`, benchmark city, 3,092 edges, 2,024 nodes, 60
game-minutes:

| piece | before | after |
|---|---|---|
| tick 0 `RoadNetwork.full_pass` | 7.7568 ms | **3.5902 ms (−53.7 %)** |
| tick 1 `TrafficSnapshot.rebuild` | 5.8748 | 5.5065 |
| tick 2 `TrafficFeed.rebalance` | 8.2395 | 8.3975 |
| `mean_congestion` on its own | 0.7486 | 0.7520 (no longer called) |
| `dark_signal_counts_by_edge` | 0.2793 | **0.0002** |

End to end, `tools/profile_sim.gd`, three interleaved rounds against HEAD:

| city | measure | before | after | Δ |
|---|---|---|---|---|
| bench | `roads_congestion` ms/tick | 5.320 5.224 5.072 | 4.169 4.157 4.055 | **−20.7 %** |
| bench | fine tick ms | 17.646 17.293 16.671 | 16.287 16.253 15.636 | **−6.7 %** |
| bench | coarse step ms | 210.7 206.8 207.0 | 202.5 202.8 203.3 | −2.5 % |
| starter | `roads_congestion` ms/tick | 0.867 0.872 0.881 | 0.666 0.670 0.669 | **−23.5 %** |
| starter | fine tick ms | 1.798 1.792 1.814 | 1.587 1.598 1.592 | **−11.6 %** |
| starter | coarse step ms | 9.472 9.290 9.412 | 8.179 8.221 8.130 | **−12.9 %** |

No arm overlaps. **Hash-neutral on both cities, coarse and fine** —
`tools/profile_sim.gd --baseline` reports HASH OK on all four hashes. D-15's fine
tick moves 17.2 → 16.1 ms against its 8 ms target; `roads_congestion` is no
longer the largest term on the bench city's fine tick, `power` is.

##### 4. Async saves — and the half that turned out to matter (doc 08 §2.14, RR-44)

RR-37 measured the shipped save path at 138 ms to save and 456 ms to load the
benchmark city, synchronously, on the main thread, and filed the synchronous
write as the fault. `SaveManager` now splits into `capture_save` (walks the
sections, calls `CitySim.canonical_capture()` — a read of LIVE sim state, and
the whole reason a save is deterministic) and `commit_save` (stringify, digest,
envelope, zstd write, manifest, retention, sweep — bytes only, and safe on a
worker). `SaveService.async_writes` hands the second to `WorkerThreadPool`.

**The split is not where the brief expected it, and that is the finding.**
`tools/profile_save.gd` now reports both halves of both operations:

| city | op | sync | async | note |
|---|---|---|---|---|
| bench (1,500) | save, caller pays | **148.72 ms** | **97.54 ms** | −34.4 % |
| bench | of which the write half | 52.44 | 38.70 (on the worker) | |
| bench | load | 483.86 | 490.28 | unchanged, and see below |
| bench | of which read (decompress, parse, digest, gate) | **35.22** | 37.24 | 7 % |
| bench | of which `restore_state` | **442.56** | 446.95 | **91 %** |
| founding +6 h | save, caller pays | **16.54** | **11.99** | −27.5 % |
| founding | of which the write half | 4.81 | 5.31 | |
| founding | load / read / restore | 52.13 / 3.35 / 48.40 | | restore is **93 %** |

Two consequences, and the second is a refusal:

1. **Threading the write buys a third of the save, not seven-eighths.** The
   capture is 96 of the benchmark city's 149 ms — `canonical_capture()` walking
   the roster and floating every number into `"~f~%08x%08x"` costs nearly twice
   what stringifying, digesting, compressing and writing the result does. It is
   worth taking; the NEXT lever on this path is the capture, not the file.
2. **Streaming the load is not worth building.** 91 % of a 484 ms load is
   `restore_state`, which rebuilds the live city and can no more leave the main
   thread than the capture can. A threaded reader would move 35 ms of 484 — 7 %,
   for a background thread, a progress model and a re-entrancy contract on the
   load gate. Costed and refused in doc 08 §2.14.

**What does not move.** The capture, always. And the whole of the PAUSE path:
doc 13 §2.2 gives the process no promise it survives the callback, so
`SaveService.SYNC_REASONS` — `pause`, `quit`, `pre_migration`, `pre_catchup` —
commit before the call returns. `AndroidLifecycle` already tags its lifecycle
save `pause`, so it is synchronous whether or not the shell ever sets
`async_writes`. Every reader of a slot flushes the queue on the way in, so
nothing in the codebase can observe a half-written ladder, and
`NOTIFICATION_PREDELETE` / `EXIT_TREE` flush too, so a process that ends with a
write queued still lands it.

#### Wave 14 — the load in front of the frame gets 108 ms shorter (2026-08-21)

Two of this wave's four items move a number this section indexes, and neither is
a *frame* number, so the tables above are unchanged and the measurements live
with their owners:

* **Doc 04's per-tile transformer memo is warm-filled at boot.** It was
  cold-filled by the load seam's signal-power sample — the 96 ms RR-60b split
  into five ~21 ms `roads_signals` restore steps. Interleaved A/B, three rounds,
  benchmark city: `roads_signals` **109.5 → 1.54 ms**, restore total
  **316 → 207 ms**, cold `CitySim.boot()` **211 → 222 ms**. The longest restore
  step is unchanged at `decode` ≈ 31 ms, which is what §2.9.1's veil budget is
  written against. Full table in doc 04 §2.2; ruling in report 98 §29 RR-71.
* **The offline catch-up is sliced.** `CitySim.begin_catchup()` hands the shell a
  cursor and the shell spends whole coarse hours or fine ticks against a 12 ms
  wall-clock budget, so S15's catch-up veil draws every frame instead of one.
  This is a frame-pacing win the profilers here cannot see — the same shape as
  Wave 9's proposal 2 — because the work per absence is identical and only its
  distribution across frames changed. Doc 13 §2.9; report 98 §29 RR-73.

`tools/profile_save.gd` gained a `boot (cold sim)` row and a `--boot-only` mode
so the first of those is measurable at both ends of the trade rather than only
at the end that got faster.

#### The 2026-09-01 session — the whole matrix in one window, and the Fold table re-taken from it

**`tools/run_matrix.sh` ran end to end, on an unlocked and connected phone, and
exited 0.** Galaxy Z Fold 6 (`SM-F956U`), Android 16, **Adreno 750, Vulkan
1.3.128, Godot "Forward Mobile"**, inner panel 1856 × 2160 @ 120 Hz. The
installed build is the **Wave-15 build, `versionName` 0.4.0, installed
2026-08-21** — `build_check` first: `launch_args in dex: 1` (control
`thermal_status`: 1), so the 2026-08-21 killer was checked rather than assumed.
The city is **the player's own live save**, slot 0, restored byte-identically on
every one of the fourteen launches (`bytes=288385` in all fifteen
`PERFIO kind=load` rows of the session). Sections 2–4 pin `--preset=balanced`, and every `PERF` line in the
session reads `preset=balanced`.

**Fourteen captures, 25 `PERF` samples each at a 2 s cadence.** Every row below
is `tools/perf_rows.py`'s median over the steady window `t ≥ 12 s` (`n = 20`) —
the same rule the 2026-08-20 session used, and the same one that drops the
shader-cache and stream-in frames. The raw captures are
`tools/device_results/log_*.txt` and the session log is
`tools/device_results/run_matrix_2026-09-01.log`.

##### The table, re-taken

| capture | hour | what it adds to `--resume … --perf` | fps | p95 ms | cpu ms | gpu ms | dc / budget | prim | vram MB | chunks | near | inst | knob(s) | thermal |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `z0.0_h13` | **13** | `--zoom=0.0` | **109.2** | 12.6 | 0.35 | **6.1** | 100 / 320 | 47,783 | 134 | 9 | 4 | 86 | 0 | 0 |
| `z0.5_h13` | **13** | `--zoom=0.5` | **107.8** | 12.1 | 0.40 | **6.0** | 100 / 320 | 47,783 | 134 | 9 | 4 | 86 | 0 | 0 |
| `z1.0_h13` | **13** | `--zoom=1.0` | **106.5** | 15.2 | 0.40 | **6.0** | 100 / 320 | 47,783 | 134 | 9 | 4 | 86 | 0 | 0 |
| `z0.0_h21` | **21** | `--zoom=0.0` | **71.3** | 16.7 | 0.50 | **8.6** | 100 / 320 | 47,783 | 134 | 9 | 4 | 86 | 0 | 0 |
| `z0.5_h21` | **21** | `--zoom=0.5` | **68.6** | 17.1 | 0.50 | **8.7** | 100 / 320 | 47,783 | 134 | 9 | 4 | 86 | 0 | 0 |
| `z1.0_h21` | **21** | `--zoom=1.0` | **68.1** | 18.1 | 0.40 | **8.6** | 100 / 320 | 47,783 | 134 | 9 | 4 | 86 | 0 | 0 |
| `rd2_h13` | 13 | `--road-detail=2` | 69.7 | 18.0 | 0.50 | 8.5 | 100 / 320 | 47,783 | 134 | 9 | 4 | 86 | 0 | 0 |
| `rd0_h13` | 13 | `--road-detail=0` | 69.4 | 18.3 | 0.50 | 8.9 | 100 / 320 | 47,783 | 134 | 9 | 4 | 86 | 0 | 0 |
| `rd2_h21` | 21 | `--road-detail=2` | 69.5 | 17.3 | 0.50 | 8.6 | 100 / 320 | 47,783 | 134 | 9 | 4 | 86 | 0 | 0 |
| `rd0_h21` | 21 | `--road-detail=0` | **58.0** | **21.3** | 0.60 | **11.1** | **130** / 320 | **54,551** | 134 | 9 | **0** | 86 | **0, 1, 2** | 0 |
| `flood2` | 21 | `--zoom=0.5 --flood=350 --flood-detail=2` | 67.5 | 17.2 | 0.40 | 8.8 | 101 / 320 | 45,889 | 134 | 9 | **7** | 86 | 0 | 0 |
| `flood0` | 21 | `--zoom=0.5 --flood=350 --flood-detail=0` | 69.1 | 17.6 | 0.55 | 8.8 | 100 / 320 | 47,783 | 134 | 9 | 4 | 86 | 0 | 0 |
| `pads1` | 13 | `--pad-shadows=1` | 69.2 | 17.5 | 0.40 | 8.6 | 100 / 320 | 47,783 | 134 | 9 | 4 | 86 | 0 | **1** |
| `pads0` ⚠ | 13 | `--pad-shadows=0` | 91.5 | 15.8 | 0.35 | 6.5 | 100 / 320 | 47,783 | 134 | 9 | 4 | 86 | 0 | **1** |

⚠ **`pads0` is stamped `CONTAMINATED`** by `cap_pose.sh` (`fg_before=0
fg_after=1`) and must not be quoted as a number — report 98 RR-131 says why in
three parts, and the third part is the one that matters.

**Reading the columns.** `dc / budget` is against
`presets.balanced.draw_call_budget = 320`; `prim` is
`RENDER_TOTAL_PRIMITIVES_IN_FRAME`; `vram` is the engine's own
`RENDER_VIDEO_MEM_USED` against `presets.balanced.vram_budget_mb = 320`; `near`
is `RenderStateModel.tier_census()["near"]`, chunks within `near_max_m = 150 m`
of the camera; `knob(s)` is the set of governor rungs seen across the steady
window, not a median. `cpu` and `gpu` are
`RenderingServer.viewport_get_measured_render_time_*`, against
`cpu_budget_ms = 4.0` and `gpu_budget_ms = 13.0`. **The governor's own budget is
neither of those**: `PerfGovernor` uses `1000 / target_fps` = **16.667 ms**
(`perf_governor.gd:175`), with `× 1.25` down (**20.83 ms**, held 5 s) and
`× 0.80` up (**13.33 ms**, held 30 s) — which is the arithmetic the `rd0_h21`
row below is read against.

**One caveat about the last two rows: `step_pads` does NOT pin the preset.** Its
launch line is `--resume --zoom=0.0 --pad-shadows=<n> --perf --advance-hours=19`
with no `--preset=balanced`, so both pads captures read `preset=balanced` by
**auto-detection** rather than by instruction. On this phone that is the same
thing; on a phone that decides differently it would silently be a different
experiment, which is exactly the trap `step_zebra`'s own comment warns about.
Report 98 RR-131's re-run pins it.

##### The headline: night costs +2.60 ms of GPU and NOT ONE draw call

| | day (h13, three poses) | night (h21, three poses) | Δ |
|---|---|---|---|
| `gpu_est` mean | **6.03 ms** | **8.63 ms** | **+2.60 ms (× 1.43)** |
| `fps` mean | 107.83 | 69.33 | **−38.50** |
| `p95` mean | 13.30 ms | 17.30 ms | +4.00 ms |
| `cpu` mean | 0.383 ms | 0.467 ms | +0.083 ms |
| `dc` | 100 | 100 | **0** |
| `prim` | 47,783 | 47,783 | **0** |
| `vram` | 134 MB | 134 MB | **0** |

**Zero on three of those rows is the finding.** The six day and night captures
submit *the same* draw calls and *the same* primitives, sample for sample —
`md5sum` over the `dc … lights` columns of all 25 lines is
`cc761e3e782311b8db9b578f109b2417` for five of the six (`z0.5_h21` differs in
one sample of 25). So the whole 2.60 ms is **per-pixel and post**, paid inside
draws that already existed: §2.7's emissive windows, §2.10's lamp cards, §2.8's
night sky and tonemap, and balanced's three-level glow
(`glow_levels [2,3,4]`, `glow_hdr_threshold_night 0.78` against
`glow_hdr_threshold_day 1.05` — the night threshold is what lets the emissives
into the bloom). **That is exactly the list §2.13 forbids the governor to
touch**, so the 2.60 ms is not a knob and is not meant to be: it is what the
signature moment costs, priced on hardware for the first time.

**Why 2.60 ms costs 38.5 fps, and why that number is an artefact.** The panel is
120 Hz — an 8.33 ms interval. **6.03 ms clears it; 8.63 ms misses it by
0.30 ms**, and a missed interval is a doubled one, which is why every night row's
`p95` sits at or just above **16.7 ms = 2 × 8.33** and every night `fps` sits
near 69 rather than near 120. The frame is free-running because the shipped cap
is never applied (`A91-D-83`), so the `fps` column is a step function of the
`gpu_est` column and not an independent measurement of anything. **Quote
`gpu_est`. The actionable form of this row is that the night pose is 0.30 ms
over a cliff**, not that it is 38 fps slower.

##### The caveat that has to be printed beside the headline

**Three daylight captures also read 8.5–8.9 ms, and the session cannot say
why.** In chronological order, `gpu_est` medians run:

    6.1  6.1  6.1 | 8.5  8.7  8.6 | 8.5  8.8  8.6  10.8  8.8  8.8  8.6 | 6.3
    ^ h13 × 3       ^ h21 × 3       ^ rd2_h13  rd0_h13 …               ^ pads0 (h13)

Every night capture is ≥ 8.5 ms (7 of 7), and **four of the seven day captures
are too** (`rd2_h13`, `rd0_h13`, `pads1` — and `pads0`, the last capture of the
session, comes back to 6.3). So *hour* is sufficient for the 8.6 ms state and
not necessary for it, and the +2.60 ms above is measured across a two-state
whose second cause is unidentified. **The ruled-out list**, so the next window
does not re-walk it: it is not the pad-shadow lever (`pads1` sets the value the
build already boots with — `data/render.json:184`,
`power_infra_view.gd:279`/`:131` — and still costs 2.5 ms, report 98 RR-131); it
is not thermal (`pads1`'s high samples predate its own `0 → 1` step at
`t = 14.1 s`, and the last capture of the session is the fast one); it is not
the city (`prim`, `inst` and the whole census are byte-identical throughout);
and it is not run order (fast, slow, fast).

**What separates the two states cannot be recovered from these files, because
the `PERF` line does not carry the sim hour.** That is the single cheapest fix
in the instrument and it is named here rather than in a backlog: an `hour=`
column in `PerfGovernor.perf_line()` would have settled this in one `grep`, and
until it exists **no capture can prove which hour it rendered**. The
next-window discriminator that needs no code is to interleave the hours *within*
a round — `h13, h21, h13, h21` — instead of running three of one and then three
of the other, which is what `step_q1`'s `for h in 13 21; do for z in …` does
today.

##### Against the 2026-08-21 partial numbers

The previous session settled at **`dc` 103–107, `prim` ≈ 37,270, `vram` 198 MB,
`inst` 81, `fps` 99.5–112.4, `gpu_est` 6.1–6.8, `knob = 0`, `thermal = 0`** on a
202,946-byte slot, at one unknown-hour pose. Against this session's daylight
rows:

| column | 2026-08-21 (settled) | 2026-09-01 (h13) | read |
|---|---|---|---|
| `fps` | 99.5–112.4 | 106.5–109.2 | **the same frame**, which is the first cross-build, cross-city agreement this doc has |
| `gpu_est` | 6.1–6.8 | 6.0–6.1 | the same, at the low end |
| `dc` | 103–107 | 100 | 69 % headroom against 320, up from 67 % |
| `prim` | ≈ 37,270 | 47,783 | **+28 %** — the city grew and the draw count did not |
| `vram` | 198 MB | **134 MB** | **−64 MB across the builds**, on a bigger city; 42 % of balanced's 320 MB budget |
| `inst` | 81 | 86 | +5 buildings |
| slot | 202,946 B | 288,385 B | **+42 %** |
| `knob` / `thermal` | 0 / 0 | 0 / 0 *(except `rd0_h21`, `pads*`)* | the governor still does not move at a settled pose |

**The 2026-08-21 session's one-sample incremental-add spike did not recur.** It
read `dc = 149 / p95 = 36.5 ms` at `t = 16 s` as `inst` went 34 → 81. This
session's `inst` is **86 from the first sample of every capture** and no sample
in the fourteen captures exceeds `dc = 130` (and that one is the pose change of
report 98 RR-129). The add path is still worth its own budget; it simply had
nothing to add here, because the save restores a settled city rather than
streaming one in.

##### Memory, thermal and the driver

`dumpsys meminfo`, taken at the end of the session
(`tools/device_results/meminfo.txt`):

| line | KB | note |
|---|---|---|
| Native Heap | 231,514 PSS (161,035 SwapPss) | the sim, the save buffers and Godot's own |
| **GL mtrack** | **373,804** | 365 MB — the driver's accounting |
| **EGL mtrack** | **126,912** | 124 MB |
| **total PSS** | **840,172** | **820 MB against `presets.balanced.pss_budget_mb = 900` — 91 %** |

    grep -aE "Native Heap|Dalvik|Stack|Ashmem|Other dev|mmap|mtrack" \
      tools/device_results/meminfo.txt \
      | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){s+=$i; break}} END{print s}'
    # 840172

**PSS is the tightest budget in the session by a wide margin** — 91 % used,
against 31 % of the draw-call budget, 66 % of the GPU budget, 12 % of the CPU
budget and 42 % of the engine's own VRAM budget. It is also the one the
engine's `vram` column cannot see: `RENDER_VIDEO_MEM_USED` reports **134 MB**
while the OS attributes **489 MB** to `GL mtrack` + `EGL mtrack`. **A pass that
watches only `vram` is watching a quarter of the graphics memory this app
actually holds**, and the 900 MB row of the preset table has never been checked
against `meminfo` before today.

Thermal at the end of the session (`tools/device_results/thermal.txt`):
`Thermal Status: 1`, `AP 47.4 °C`, `CP 38.4 °C`, `PA 38.8 °C`, `SUBBAT
28.2 °C`. The status stepped `0 → 1` once, **inside `log_pads1.txt` at
`t = 14.1 s`**, i.e. after twelve captures and ~12 minutes of uncapped
120 Hz-seeking rendering (`A91-D-83`). `PerfGovernor.target_fps()` treats
`THERMAL_MODERATE` and above as a cap; status 1 is below that and changed
nothing.

##### Three instrument findings, filed rather than buried

1. **`lights=` has read 0 in every device line ever taken, and it is not a
   measurement.** `PerfTelemetry.set_light_source()` is never called —
   `grep -rn "set_light_source" --include=*.gd .` returns **one** hit, its own
   definition at `game/render/perf_telemetry.gd:80` — and the method's own doc
   says what that means: *"without it the `lights=` column reports 0 rather than
   the preset's authored ceiling, because the ceiling is not a measurement."* So
   `presets.balanced.street_lights = 12` and the governor's rung 4 (street omnis
   −4, floor 4) have **never been observed on hardware**, and the night rows
   above cannot attribute any part of their 2.60 ms to omni count. Wiring it is
   one line at `game/main.gd:402`'s sibling.
2. **`flood2` runs at `near = 7` against `presets.balanced.near_chunk_max = 6`.**
   Constant from its first sample, in the only capture of the fourteen that
   exceeds the ceiling. Either the ceiling is advisory, or the flood layer's
   chunks are counted in a census the ceiling does not gate. Not chased here;
   `grep -a 'near=' tools/device_results/log_flood2.txt` is the whole evidence.
3. **`--zoom` arrives and the camera does not move (`A91-D-84`).** **Eleven of
   the fourteen captures share one `md5`** over their entire render column set —
   all three zoom values at h13, two of three at h21, both zebra day arms,
   `rd2_h21`, `flood0` and both pads arms:

       cd tools/device_results
       for f in log_z0.0_h13 log_z0.5_h13 log_z1.0_h13 log_z0.0_h21 \
                log_z1.0_h21 log_rd0_h13 log_rd2_h13 log_rd2_h21 \
                log_flood0 log_pads0 log_pads1; do
         printf '%s ' "$f"; grep -ao 'dc=.* lights=[0-9]*' "$f.txt" | md5sum
       done
       # cc761e3e782311b8db9b578f109b2417, eleven times

   Only three captures differ, and each for a reason that is not the zoom:
   `z0.5_h21` in one sample of 25, `rd0_h21` at its mid-hold pose change, and
   `flood2` from its first sample. **The `Z0` and
   `Z2` rows of every pose table in this section are still unmeasured**, and
   this is the second session in a row to produce one pose while believing it
   produced three. The 2026-08-20 note — *"the device session did not manage to
   separate the three zoom poses … and the pose matrix is still open"* — stands,
   for a new reason.

##### What this session closes, and what it does not

**Closed.** The day/night half of doc 91 §20.4 device item 2 (six captures, two
hours, one pinned preset, +2.60 ms with the arithmetic above); the `road_detail`
A/B (report 98 RR-129 — free at both hours); the `flood_detail` A/B and the
flood screenshot (RR-130 — free, rung 2 stays, `flood_night.png`); the first
`PERFIO` pair taken as a *median of fifteen* rather than a single sample (doc 13
§2.9.1).

**Not closed.** The three-**pose** half of item 2 (`A91-D-84`); the pad-shadow
A/B (RR-131 — re-run command filed, RR-33 unrevisited and standing); the
2.5 ms two-state above; tier-C `road_detail` (item 4, a different part); and the
governor's ladder ORDER, which this session watched run for the first time and
which spent two pixel-side rungs on a submission-side frame without recovering a
frame (RR-129's last bullet).

**Cost charged to the player: none that survives.** Every launch restored the
same 288,385-byte slot (`bytes=288385` in all fifteen load rows), and the one
pause-save the session produced wrote 345,597 bytes at `15:25:59` after the
matrix was over. A `tar` backup of `files/saves` predates the session as usual.

#### Device matrix

| Tier | Representative devices | GPU | Preset | Target |
|---|---|---|---|---|
| **A Flagship** | Pixel 8 / 8 Pro, Galaxy S23/S24, SD 8 Gen 2/3 | Mali-G715, Adreno 740/750 | High | 60 |
| **B Upper-mid** | **Pixel 6 / 6a / 7**, SD 7 Gen 1, Dimensity 8020 | Mali-G78 MP20, Adreno 644 | Balanced | 60 (45 under thermal) |
| **C Mid** | SD 695 / 6 Gen 1, Helio G99, Exynos 1280 | Adreno 619, Mali-G57 | Performance | 30 |
| **D Floor** | minSdk-29 Vulkan devices, 4 GB RAM | Adreno 610/612 | Performance + `far_cull 700 m`, 16 chunks | 30 |

**Boot auto-select.** First launch runs `tools/bench_boot.gd` — a 3.0 s scripted orbit over the starter city at 20:00 with rain, discarding the first 0.8 s. From p95 frame time `t95`: `≤13 ms → High`, `≤20 → Balanced`, `≤30 → Performance`, `>30 → Performance + tier-D overrides`. Written to `user://settings.cfg`, re-run only on explicit "Re-detect".

**Runtime adaptive governor.** Rolling 120-frame p95, evaluated every 1 s. Step **down** one knob if `p95 > budget·1.25` sustained 5 s; step **up** one knob if `p95 < budget·0.80` sustained 30 s. Ladder (down order): (1) `render_scale −0.05` floor 0.60; (2) particle `amount_ratio ×0.60` floor 0.30; (3) `far_cull −128 m` floor 600 m; (4) street omnis `−4` floor 4; (5) drop one preset and **latch** for the session (never oscillate presets).

The governor never touches `emissive_*`, `blackout.*`, or `glow_enabled`. **The signature moment is not allowed to degrade.**


#### 2.6b The MEDIUM/FAR boundary — the far city was grey because a colour space was applied twice (2026-09-01, report 98 RR-98)

**The finding, and it is a seam bug rather than an art bug.**
`building_far.gdshader` painted a single neutral pair — `base_albedo (0.34,
0.335, 0.325)`, `roof_albedo (0.26, 0.258, 0.252)` — for every building beyond
`medium_max_m`. Both are `source_color` uniforms, **and a `source_color`
uniform IS sRGB-decoded by the engine.** Measured, not assumed: the same 0.5
pushed into a plain `vec3` and into a `source_color` `vec3` renders back
**0.7373** and **0.4980**, and 0.4980 is sRGB(0.214) — the tagged one was
decoded. So what the far tier actually painted was linear **(0.0946, 0.0918,
0.0862)** on walls and **(0.0550, 0.0541, 0.0517)** on roofs: luma 0.092 and
0.054.

The tier immediately in front paints `mix(base_albedo, facade_tex, tex_mix) *
v_color`, so what a MEDIUM chunk shows at range is **the mean of its family's
pages**. As the linear the far shader would see:

| family | wall page | luma | roof page | luma | the neutral pair was |
|---|---|---|---|---|---|
| residential | `brick` | 0.164 | `gravel` | 0.159 | wall **1.8×**, roof **2.9×** too dark |
| commercial | `curtain` | 0.146 | `mech` | 0.257 | wall **1.6×**, roof **4.8×** too dark |
| industrial | `utility` | 0.207 | `metal` | 0.216 | wall **2.3×**, roof **4.0×** too dark |
| tech | `techpanel` | 0.054 | `metal` | 0.216 | wall **1.7× too BRIGHT** |
| civic | `civic` | 0.296 | `gravel` | 0.159 | wall **3.2×**, roof **2.9×** too dark |

So the far city was not "grey" for want of a texture. It was grey **and, for
four families out of five, two to five times too dark** — while being 1.7× too
*bright* for the one family whose page is genuinely near-black. At Z2 the
boundary circle crosses the middle of the frame, which is why it read as a line
drawn across the skyline rather than as haze.

**This is `A91-D-36`'s rule one layer on, and it points the other way.** A
MultiMesh instance colour is NOT decoded (RR-91); a vertex colour is NOT
decoded (RR-95); a `source_color` uniform IS. Three seams, two answers, and
this project has now been bitten in both directions — which is why each one is
written at the write, in the file that performs it.

**What ships.** `CityView._measure_far_family_albedo()` reduces each page the
near tier wears to 8×8 with a Lanczos filter — the filtered footprint a
minified page converges to — averages it **in sRGB**, and hands the five
wall/roof pairs over undecoded, so the engine performs the one and only decode.
`far_family_mix` stays 0 on a checkout with no generated pages, the same "runs
untextured" contract `tex_mix` gives the near tier. **The palette is measured,
never authored**: a hand-written far palette is a second copy of the art, and
`gen_textures.py` can retint the city with the far tier following on the next
boot.

**A distance fade was rejected.** `Environment.fog_aerial_perspective` already
greys the far city with range (§2.8); a second fade in the albedo greys the
skyline twice, which is the shot §1's "show the tall skyline" is about.

**Measured**, `profile_frame --preset=balanced --hour=13 --poses=z2
--resolution=1920x1080 --anim-step=0.016667 --quiet-layers`, over the 420 m
band (474,980 px, **22.9 % of the frame**) isolated with the new
`--medium-max=548` arm:

| the band drawn as | mean linear luma | vs target | per-pixel chroma | vs target |
|---|---|---|---|---|
| MEDIUM — the target | 0.24742 | — | 15.01 | — |
| FAR, neutral grey (`--far-family=0`) | 0.17043 | **−31.1 %** | 13.05 | **−13.1 %** |
| FAR, §2.6b as shipped | **0.25148** | **+1.6 %** | **15.96** | **+6.3 %** |

**No fudge factor is authored.** Sweeping `--far-gain=` at 1.0 and 1.3 fits mean
luma at `0.1116·g + 0.1399`, so the level-matched gain is **0.96** — identity
within the noise. `far_albedo_gain` therefore stays at the shader's 1.0 and is
deliberately **not** in `data/render.json`: a constant of 1.0 that nothing
varies is exactly the inert knob §2.13b spent this wave deleting. It survives
only as `profile_frame --far-gain=`'s sweep lever.

*An AO correction was considered and is not needed. The near tier multiplies
its page by `v_color`, the mesh's baked AO, whose area-weighted mean over all
66 `*_lod1.res` meshes measures **0.8267**, and the far box carries none. With
the decode fixed the band lands at +1.6 % without it; applying it would push
the far tier back under the tier in front of it.*


##### §2.6b (2) — where the boundary sits, how big the step was, and the day façade (2026-09-02)

**Where it sits.** `medium_max_m` is 420 m and the tier test is against
`chunk_ground_distance`, which is the 3-D distance from the camera — so at the
Z2 pose (camera 370.8 m up) the boundary is a ring on the ground at
**197.3 m**, and the FAR tier covers **20.87 % of the Z2 frame** (432,751 px of
1920 × 1080, `--focus=52,44`, hour 13, High). That ring crosses the middle of
the skyline, which is why it read as a line drawn across the shot rather than
as haze.

**How big the step was.** The A/B that measures it is `--medium-max=1500`,
which pushes the boundary past the cull so the same buildings are drawn by the
NEAR/MEDIUM textured shader instead — nothing else differs, so the delta over
the FAR footprint *is* the tier step:

| arm | mean luma over the FAR footprint | vs the textured reference | sd |
|---|---|---|---|
| reference (all textured) | 142.63 | — | 23.10 |
| **FAR flat grey (pre-Wave-17)** | **120.62** | **−15.4 %** | **12.63** |
| FAR per-family palette | 141.70 | **−0.7 %** | 23.70 |

The far city was not merely "grey": it was **15.4 % too dark and carrying 55 %
of the variance**, which is what a boundary is made of. The per-family palette
takes the level error to **−0.7 %** and restores the spread (23.70 against
23.10). **Cost: zero draw calls and zero primitives** — 182 dc / 302,878 prims
either way, both arms measured.

**The day façade, and why the step was only half the row.** With the level
matched, `ALBEDO` was still one flat value per family per face by day: a tower
at 300 m was a coloured slab where the tier in front of it was brick and glass.
The night path already computes a storey band and a bay mullion for `EMISSION`;
§2.6b (2) reuses those exact terms on `ALBEDO` — the audit's own "3.5 m
storey-band darkening" — for **three ALU, no texture fetch and no draw call**.

**It is authored as a ZERO-MEAN modulation and that is the whole trick.**
`1 + depth · (cover − mean_cover)`, with `mean_cover = (band_hi − band_lo) ·
far_mullion_duty` — exactly what the sharp pattern integrates to. Any pattern
whose average is not 1 would throw away the −0.7 % level match above. Measured:
the far-tier walls move **145.53 → 144.58 mean luma, −0.65 %**, at depth 0.90.
It also **self-extinguishes at range with no second boundary**, because both
factors are already `fwidth`-crossfaded to their own means: as a bay or a
storey approaches a pixel, `cover → mean_cover` and the modulation → exactly
1.0.

**The depth is a measured art call.** High-pass detail RMS over the far-tier
walls at Z2 (103,737 px, 24 % of the far footprint):

| depth | 0 (flat) | 0.55 | **0.90 (shipped)** | textured reference |
|---|---|---|---|---|
| detail RMS | 4.46 | 6.07 | **7.66** | 13.30 |
| mean luma | 145.53 | 145.05 | 144.58 | 152.87 |

0.90 is where the towers read as floors in the screenshot pair without reading
as stripes, and it stays well under the reference's density, so the boundary
does not come back as a *contrast* step in the other direction.

> **FILED, with its price, rather than taken: a textured FAR atlas.** The audit
> allows one and notes Z2's headroom. Promoting the whole Z2 frame to the
> textured shader (`--medium-max=1500`) costs **+80 draw calls and +158,322
> primitives** on High (182 → 262, 302,878 → 461,200), which fits inside High's
> 520 budget and inside Balanced's 320 as well (262 + 25 UI = 287) — but it is
> not what the row needed: the level error is already −0.7 % and the walls
> carry structure, so the remaining gap is texture DETAIL, which reads as
> softness and not as a line. **A distance fade was rejected outright**:
> `Environment.fog_aerial_perspective` already greys the far city with range
> (§2.8), and a second fade in the albedo greys the skyline twice — the shot
> §1's "show the tall skyline" is about. *Re-open trigger: a device session in
> which the far tier reads as soft at Z2 on the Fold; the atlas is the fix and
> its price is the paragraph above.*


#### 2.13b The engine-side half of a preset (2026-09-01, report 98 RR-98, doc 93 §X5)

**Until Wave 17, none of it reached the engine.** **Twenty-two** keys in every
preset row of `data/render.json` reached no engine call. Counted, not
remembered — the count below is `grep -rn '"<key>"' --include=*.gd game/ ui/`
against the fork tree (`a5d9021`), and it corrects the "thirteen" the first
draft of this section published:

* **Sixteen are now WIRED**: `render_scale`, `msaa`, `fxaa`, `shadows`,
  `shadow_splits`, `shadow_atlas`, `shadow_max_m`, `glow_levels`, `glow_blend`,
  `glow_hdr_threshold_day`, `glow_hdr_threshold_night`, `glow_hdr_scale`,
  `env_adjustments`, `moon`, `street_lights` (§2.13 ladder rung 4) and
  `civ_headlights`.
* **Six are DELETED**, in the table below, each because the feature it names
  does not exist.

**Twenty-one of the twenty-two never appear as a string literal anywhere in `game/` or `ui/`** — which is the only way a JSON preset key can be read, so they were unreachable, not merely unread. The twenty-second, `render_scale`, appears exactly twice, both inside `ui/settings_model.gd`'s comparator (`:172-173`): **it sorted the graphics menu rows cheapest-first**, so the number that decided the ORDER of the options was the number that did nothing when you chose one.

And
`EnvironmentController.setup` read glow from `presets["balanced"]` with the name
hard-coded, so all three presets wore Balanced's bloom whichever was live.

**The ownership split.** `QualityApplier.resolve(render_data, preset, knobs)`
answers as **plain data** — no engine object touched, which is what lets every
preset's whole engine-side answer be asserted headlessly. Two appliers write it:

| what | who writes it | why there |
|---|---|---|
| `scaling_3d_scale`, `scaling_3d_mode`, `msaa_3d`, `screen_space_aa` | `QualityApplier.apply_viewport(viewport, q)` | viewport properties |
| the directional shadow atlas | same, via `RenderingServer.directional_shadow_atlas_set_size` | it is a process-wide global, not a viewport property |
| glow levels / blend / HDR, `adjustment_enabled`, the sun's split count and distance, the moon | `EnvironmentController.apply_quality(q)` | that file's contract: every write to the `WorldEnvironment`, the sun and the sky belongs to ONE place |
| `street_lights` | `StreetlightView.set_preset()` → `set_light_budget()` | the only file that draws a streetlight |

**Two keys are held rather than written, and the reason is the same both
times: they compose with a per-frame value.** `shadows` is ANDed into
`apply()`'s per-frame `_sun.shadow_enabled` derivation (sun elevation, storm
cover) — written once at preset time it would be overwritten on the next frame.
`glow_hdr_threshold` is lerped day-to-night in `apply()` by the same `night`
scalar everything else uses, because a lit window is ~2.4 nits against a noon
sky the tonemapper puts near 1.0 and the night threshold applied at midday
blooms the whole façade.

**`render_scale` is the cheapest millisecond in the project** and shipping it
inert cost the most: the 2D/UI layer is NOT scaled, so a 0.85 Balanced frame is
72 % of the fill of the 1.0 one it was actually rendering, with a UI that stays
sharp either way. It is also §2.13 ladder rung 1 — a Fold that thermally
throttled used to shed draw distance and then drop a whole preset, having never
once tried rendering fewer pixels. The governor may only ever LOWER it: a stale
knob from a preset the player has since raised must not drag the new one up.

**`street_lights` caps the two FILL layers and nothing else** — the ground light
pool and the §2.9 wet smear — and NOT the pole or the lit billboard. A street
whose lamp posts come and go with the quality setting is a street that changes
shape; the billboard IS the lamp being lit and §2.13's protected list exists
because the night city going dark is job 1, not scenery. 6 / 12 / 20 *per 128 m
chunk* is a plausible count and is what the table already authored; 20 for a
whole city never was. It is a `visible_instance_count` window, not an
`instance_count` change, because raising the latter clears the buffer and every
governor step would re-upload the city's lamps.

**Rungs 1 and 4 are both resolved here now**, and both may only ever LOWER the
preset's value: `QualityApplier.resolve()` takes `min(preset, knob)` for
`render_scale` and for `street_lights`, so a knob left over from a preset the
player has since raised cannot drag the new one anywhere. That is what makes
the ladder's descent monotone across a settings change, which is the property
`PerfGovernor.reset()` assumes and nothing enforced.

**Six keys were DELETED rather than wired**, because each names a FEATURE THAT
DOES NOT EXIST — the only ground on which a preset key may be deleted instead
of given an owner — and the FORBIDDEN_KEYS-style guard
`test_the_deleted_keys_stay_deleted` keeps them out:

| deleted | why it could never work | what would bring it back |
|---|---|---|
| `street_light_radius_m` | the OmniLight pool §2.10 promised for four waves was never built; the billboard-and-decal rig replaced it and needs no radius | nothing: a radius without a light is not a setting |
| `reflection_probe`, `probe_size_m`, `probe_move_refresh_m` | **DEFERRED, not refused.** §2.9 authors a High-only `ReflectionProbe` and no file constructs one; `grep -rn "ReflectionProbe" game/ ui/` is empty | the wave that builds it: a `ReflectionProbe` child of `EnvironmentController` (the file that owns every write to the environment), box `[256, 120, 256]` m about the camera focus, `UPDATE_ONCE` re-armed when the focus has moved `100` m. Re-author the three rows in that commit, and move them into `PRESET_KEYS_APPLIED` naming that file |
| `snow`, `turbulence` | `WeatherFX` has a rain bed and a splash bed; `grep -rn "snow\|turbulence" game/` finds these rows and nothing else | doc 07's snow segment reaching the renderer |

**One key on that list in the first draft of this section was wrong, and is
WIRED instead: `civ_headlights`.** The draft claimed it duplicated a cap
`vehicles.headlight_*` already owns. It does not — those four rows are a night
threshold, a cone length, a cone energy and a colour, none of them a count —
and `MM_headlights` was in fact the ONE buffer in `VehicleView` with no ceiling
at all: `_ensure_capacity` clamps every body layer against `caps`, and
`_ensure_cone_capacity` grew the cone buffer to the next multiple of 32 above
the roster and clamped against nothing. It is now `VehicleView.cone_cap`
(96 / 256 / 512), applied at the buffer so the write loop's existing guard
carries it, and a preset DROP shrinks the buffer rather than merely ceasing to
fill it. This is the one additive, transparent layer the vehicle system draws,
on a device doc §2.13 has measured as fragment-bound — the single worst place
in the tree to have been missing a cap.

**The `test_water_has_two_octaves_and_no_reflection_probe` citation in that
draft was a misreading and is corrected here**, because it would otherwise
stand as a ruling the project never made: that test forbids the WATER SHADER
from faking a reflection, and its own failure message says §2.11 "gates the ONE
probe the game may own to High and to the city at large" — it assumes the
probe, it does not refuse it.

**Eight remaining unread keys are BUDGETS, not knobs**, and were kept and made
CHECKED instead: `profile_frame`'s `BUDGETS` line gates `gpu_budget_ms`,
`cpu_budget_ms`, `chunk_budget`, `near_chunk_max` and `vram_budget_mb` per pose
and prints `OVER` with the figure; `draw_call_budget` and `instance_budget` were
already gated there and in `test_bench_city.gd`; `pss_budget_mb` is an Android
figure whose consumer is `tools/perf_rows.py`. Nothing applies a budget — but
something must check one, and deleting them would have thrown away the only
published statement of what a preset may cost.

**Measured**, bench city, hour 13, 1920×1080, `--focus=52,44`, warmup 30 /
frames 60, on the workstation's RTX 2000 Ada. Every preset was run TWICE — once
as it now ships, and once with `--no-quality`, which reproduces the frame the
game actually drew before this wave, because before this wave nothing applied
the keys. Read the `--no-quality` block first:

**Before — the audit's sentence, as three numbers.** With the engine-side keys
inert, the three presets rendered the SAME FRAME:

| pre-Wave-17 (`--no-quality`) | Z0 dc | Z0 prims | Z0 `rs gpu` | Z1 dc | Z1 `rs gpu` | Z2 dc | measured VRAM |
|---|---|---|---|---|---|---|---|
| performance | 224 | 276,530 | 1.271 ms | 311 | 1.738 ms | 197 | — |
| balanced | 223 | 273,710 | 1.290 ms | 310 | 1.762 ms | 196 | **125 MB** |
| high | 223 | 273,710 | 1.286 ms | 310 | 1.755 ms | 196 | — |

Balanced and High are **identical to the primitive** — 223 draw calls and
273,710 primitives each — and their GPU times differ by 0.3 %, which is noise.
Performance's single extra draw call and its 2,820 extra primitives are the
`MM_blob` decal (§2.11), the only thing on the whole engine side that was
separating the rows. **That is "High is Balanced with more cars", measured.**

**After — each preset renders what it authors:**

| as shipped | 3D framebuffer | Z0 dc | Z0 prims | Z0 `rs gpu` | Z1 dc | Z1 `rs gpu` | Z2 `rs gpu` | measured VRAM |
|---|---|---|---|---|---|---|---|---|
| performance | 1344×756, FXAA, **no shadow pass** | **90** | **92,822** | **0.583 ms** | 124 | 0.739 ms | 1.228 ms | **74 MB** |
| balanced | 1632×918, MSAA 2×, 2 splits, 150 m | 223 | 273,710 | 0.964 ms | 310 | 1.375 ms | 1.442 ms | **123 MB** |
| high | 1920×1080, MSAA 2×, **4 splits, 180 m** | 223 | **455,852** | 1.405 ms | 312 | 1.902 ms | 1.819 ms | **191 MB** |

Three things in that table are the wave:

* **`shadows: false` is finally a shipping state.** Performance's Z0 frame goes
  224 → **90 draw calls** and 276,530 → **92,822 primitives**, because the sun
  stops re-drawing the city into a shadow map it was never going to sample. The
  saving is **134 draw calls and 183,708 primitives in one key**, and it is the
  largest single number in this section. §2.11's `MM_blob` (RR-96) is what
  makes it a look and not just a saving.
* **High costs more than Balanced now, which is the point of it.** Same 223
  draw calls, but **455,852 primitives against 273,710 (+67 %)** and 1.405 ms
  against 0.964 ms (+46 %), because it renders the four shadow splits and the
  180 m shadow distance it authors and Balanced's two and 150 m it does not.
  The draw-call count does not move with the split count — Godot batches the
  PSSM passes — so **`dc` is the wrong column to look for a shadow setting in**,
  and the primitive count is the right one.
* **VRAM was FLAT at 125 MB across all three presets before this wave** and now
  spreads **74 / 123 / 191 MB** with the framebuffer, MSAA and shadow-atlas
  allocations each row asks for.

`rs gpu` is the RenderingServer's own per-viewport figure and it is the softest
column here — these runs share a workstation with sibling suites. The two
deterministic columns (dc, prims) are the evidence; the GPU column agrees with
them in sign and rough size at every pose, which is all that is claimed of it.

**The `QUALITY` line reads back off the live objects** — `root.scaling_3d_scale`,
`root.msaa_3d`, the sun's `directional_shadow_mode`, the `Environment`'s
`adjustment_enabled` — and not off `resolve()`. Printing the resolver's own
answer would prove the resolver runs; the claim that needed proving is that the
ENGINE took the value, which is the exact claim these keys failed for three
waves.

> **OPEN — `performance` misses its `chunk_budget` at every pose and its
> `near_chunk_max` at two.** The new gate reports, on the bench city at
> `--focus=52,44`, `OVER: z0 chunks 36>24, z0 near 10>3, z1 chunks 36>24,
> z1 near 10>3, z2 chunks 36>24` — 24 chunks authored against 36 drawn at all
> three poses, and 3 NEAR authored against 10 drawn at Z0/Z1. Balanced misses
> `near_chunk_max` too (`10>6`), and High (`10>8`); **only the NEAR count at Z2
> is met by any preset, and it is met at 0.** So this is not a Performance
> problem, it is the whole `near_chunk_max` column being authored against a
> chunk census nothing had ever taken. Filed rather than adjusted, because
> changing a published budget to match a measurement is how a budget stops
> meaning anything — and because every one of these numbers was invisible until
> this wave gated it. *Re-open trigger:
> `profile_frame --preset=<row> --focus=52,44`; the item closes when the census
> fits the budget or the budget is re-derived from §2.13's chunk arithmetic the
> way `_z2_derivation` was. Note for whoever takes it: the NEAR count is
> `near_max_m` 150 m against a 128 m chunk grid, which cannot produce fewer
> than 9 chunks at any pose whose camera is inside the city — the authored
> 3 / 6 / 8 may simply be a boundary that was never multiplied out.*

### 2.14 Placeholder-art pipeline: procedural gray-box

**The tool.** `tools/gen_graybox.gd`, `@tool`, runnable headless:

```bash
~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" -s res://tools/gen_graybox.gd
```

Reads `data/building_shapes.json`, writes `game/meshes/generated/*.mesh` (`ArrayMesh`) + `manifest.json`. Idempotent: exits without writing when `generated_from_hash` and `generator_version` both match. Outputs are committed (15 archetypes × 5 levels × 2 LODs × ~6 KB ≈ 900 KB) so a fresh clone runs with no generation step.

**Construction, per (archetype, level).** (1) Emit each `block` as a box: XZ from `pos_t`/`size_t` × 8.0 m, Y from `base_floor·3.5` to `(base_floor+floors)·3.5`. (2) Apply the archetype roof signature and the cumulative `level_marker`. (3) Append `roof_props`: `box` → box; `mast` → 4-tri quad-cross with a 0.6 m emissive red beacon cap on L5 masts, blinking at 0.5 Hz — the aviation beacon that makes a skyline read as a skyline. (4) `SurfaceTool` merge → `generate_normals()` → `index()`. (5) Bake vertex AO, write UV/UV2. (6) Assign the shared material for `(family, lod)`.

**Triangle budgets, asserted by the generator (build error, not warning):** LOD0 ≤ 320 (≤ 420 for `res_highrise`, `com_highrise`, `civ_stadium`); LOD1 ≤ 96 **and** ≤ 0.40 × LOD0.

**LOD1 is derived, not authored:** keep blocks with volume ≥ 15% of total; replace all `roof_props` with one AABB box covering them; drop chamfers, sign bands, balcony ledges; **keep the roof signature silhouette** — that is what preserves archetype readability at 400 m.

**LOD2 is not per-archetype:** a shared 12-tri unit box, scaled per-instance by the transform to `(fx·8, height_m, fz·8)`, using the FAR shader. One mesh for the entire city.

**Window UV strategy (exact).**
- **UV0** → a 4×4 gray-tone atlas cell selected by `variant`, so identical buildings do not look cloned.
- **UV2** → the window grid, **only** on vertical façade quads: `window_cols = max(1, round(width_m / 3.2))`, `window_rows = floors of that block`. UV2 runs `(0,0)`→`(1,1)` across each façade **per block**, so a setback tower's upper block restarts its window grid at its own base (which is what real setbacks do).
- Every non-façade vertex — roof faces, ground-facing faces, all `roof_props`, masts, chimneys, canopies — gets **`UV2 = (-1,-1)`**. The shader's `if (UV2.x < 0.0)` branch is the entire "no windows here" rule.
- `window_cols`/`window_rows` go into the manifest and are set as per-mesh shader uniforms at load by `MeshLibraryCache`.

**Baked vertex-colour AO** (replaces the unavailable SSAO), written to `COLOR.rgb` as a multiplier:

| region | multiplier |
|---|---|
| bottom 3.0 m of any façade (linear ramp to 1.0 at 3.0 m) | 0.55 → 1.00 |
| inner corners where two blocks meet (within 1.0 m) | 0.70 |
| underside of any overhang / canopy / setback ledge | 0.45 |
| roof-prop contact ring (within 0.5 m of the roof plane) | 0.65 |
| everything else | 1.00 |

**Silhouette readability (constitution §11, made testable).** Archetype identity = roof signature + massing rule, **constant across all 5 levels**:

| archetype | footprint | roof signature | massing rule |
|---|---|---|---|
| `res_house` | 1×1 | gable prism | single low block |
| `res_apartment` | 2×1 | flat + 2 stair boxes | balcony ledge band every 2 floors |
| `res_highrise` | 2×2 | setback tower + slender mast | ≥1 setback above 60% height |
| `com_retail` | 2×2 | parapet sign band | wide low block + front canopy overhang |
| `com_office` | 2×2 | rooftop HVAC cluster (3 boxes) | plain slab |
| `com_highrise` | 2×2 | crown ring | chamfered corners (octagonal prism) |
| `ind_factory` | 3×2 | sawtooth (3 tri prisms) | 1 chimney, height ≥ 12 m |
| `ind_warehouse` | 3×2 | low barrel arc | loading-dock notch on long face |
| `tech_datacenter` | 2×2 | 6 rooftop chiller boxes | **windowless** (all UV2 = −1) + fence ring |
| `civ_hospital` | 3×3 | helipad disc + emissive cross | cross-plan (4 L blocks) |
| `civ_school` | 3×2 | flat + flagpole | 2 low wings + courtyard gap |
| `civ_stadium` | 4×4 | open elliptical bowl ring | 4 corner light masts |
| `civ_police` | 2×2 | antenna mast + blue emissive stripe | low box + vehicle apron |
| `civ_fire` | 2×2 | hose tower + red emissive stripe | 3 bay-door notches |
| `civ_utility` | 3×3 | pylon | box + fenced transformer yard |

Level identity = height + a **cumulative** marker: L1 none; L2 +1 rooftop box; L3 +setback at 60% height; L4 +crown band (0.5 m inset ring) + 2 masts; L5 +spire with blinking red aviation beacon; **L6 +crown setback — one further inset storey beneath the spire** *(Wave 10; doc 02 §2.14's tower tier, which only the six growth archetypes carry)*. Height = `floors(archetype, level) · 3.5 m`; `res_highrise` uses spec §9.3 — 12/24/36/48/62/**78** floors → 42/84/126/168/217/**273 m**.

**L6 is authored in BLOCKS, like L3 and unlike L2/L4/L5, and that is arithmetic rather than style.** By L5 this descriptor has saturated `mast_count` at 3 (the crown's two plus the spire) and `prop_count` at 7 on every one of the six archetypes, so a sixth marker made of MORE PROPS moves not one bit of the 24 and §7.1 test 7's "≥ 2 Hamming between levels of one archetype" fails outright. An inset storey moves `setback_count` and `height_bucket` together. Doc 92 §24.5 carries the measurement and the six new silhouette descriptors.

**The level atlas took the ceiling with it.** `CityView.LEVEL_MAX` is 6, `building.gdshader`'s `level_build_height[]` is sized `LEVEL_MAX + 1`, and the §2.6 packed maximum goes `447 + 448·5 = 2,687` → `447 + 448·6 = 3,135` — still 5,354× inside f32's exact-integer range. The vertex tag is `COLOR.a = level / 8`, exact through the 8-bit colour channel at 6/8 = 0.75 (191/255 × 8 = 5.992, and the shader rounds), so **8 is the hard ceiling** and `tests/test_render_merge.gd` now asserts it out loud. An archetype with only five rungs simply has no manifest entry at level 6: `_fold` drops the bucket, `_atlas_for` skips the level, and `atlas_heights` leaves the slot at its placeholder — nothing indexes it, because no instance can pack it.

**Silhouette descriptor** (generated, tested in §7.1), 24 bits: `[height_bucket:4][aspect_bucket:3][roof_sig_id:4][setback_count:2][mast_count:2][prop_count:3][notch_flags:3][windowless:1][footprint_id:2]`. Every pair of archetypes at the same level must differ in ≥ 4 bits; every pair of levels within an archetype in ≥ 2 bits.

### 2.15 Audio — owned by this doc (report G-3), **shipped 2026-08-19**

**Ruled (report G-3).** Spec §39 lists the required sounds and calls out power restoration's audiovisual signature explicitly; no doc owned audio. **This doc owns it**, because it already owns the event hooks and the timing beats the mix must be authored against.

**What ships.** Source root `game/audio/`, tunables in `data/audio.json`, assets in `game/audio/generated/`, tests in `tests/test_audio_model.gd`:

| file | role |
|---|---|
| `game/audio/audio_config.gd` (`AudioConfig`) | the single reader for `data/audio.json` + the asset manifest, `UIConfig`-shaped so everything below is constructible from a fixture |
| `game/audio/audio_events.gd` (`AudioEvents`) | **the brain.** `RefCounted`, Node-free, clock-injected: events in, *scheduled cues* out, plus the ambience picture. Dedup, cooldown, distance attenuation, speed-of-sound delay, bed sources, ducking |
| `game/audio/audio_service.gd` (`AudioService`) | **the hands.** `AudioDirector` under its planning-era name: buses, a 12-voice pool with priority stealing, one looping player per bed. Decides nothing |
| `game/audio/siren_throttle.gd` (`SirenThrottle`) | **the moving-siren policy** (Audio-2, §2.15.1). `RefCounted`, clock-injected: how many sirens are audible, which ones, and when each gets its next baked pass |
| `tools/gen_audio.py` | the whole asset set, synthesised from numpy — ~~19 mono 16-bit WAVs, 55.3 s, **3.23 MB** (77% of the 4 MB budget)~~ **20 WAVs, 83.3 s, 4.54 MB (96.1% of the raised 4.5 MiB budget)** as of Audio-2 (§2.15.1). No samples, no network, no licence trail |

**Two asset-side decisions worth naming.** *Loops are built in the frequency domain*, so they are seamless **by construction**: white noise through `rfft` → spectral shape → `irfft` is exactly periodic over the buffer, every LFO and tone is snapped to a whole number of cycles per loop, and transients are stamped with modulo indexing. No cross-fade, no taper. The generator then *measures* each seam against that buffer's own median sample step and records the ratio in the manifest, so a future edit that breaks periodicity fails `tests/test_audio_model.gd` instead of ticking every few seconds. *Sample rate is chosen per asset from its own bandwidth* — a night bed whose content stops at 460 Hz spends three quarters of its bytes on empty spectrum at 44.1 kHz, and those bytes are worth far more as loop length. Nine assets ship at 22.05 kHz, and the generator fails any of them whose spectrum crowds its own Nyquist. That trade bought the beds 7.5 s each (up from 3.5 s) for *fewer* total bytes; Godot stores `mix_rate` per `AudioStreamWAV` and resamples at playback, so it costs nothing at runtime.

`AudioService` is a listener on the same drained event batch `RenderBridge` consumes — never a second consumer of sim state, and never a `sim/` dependency. Ingest is `feed(event)` taking a sim bus dictionary verbatim, the shape `AlertsModel` already uses.

**Three rules the mix is built on.** *Block granularity is the audio granularity* (below): a blackout that darkens twelve blocks is ONE thunk, folded by cue identity inside a dedup window. *Distance decides audibility before a voice is reserved*: an event past a cue's `max_m` is dropped, not mixed at -60 dB. *The volume slider mutes rather than attenuates at zero* — `ui/settings_model.gd`'s `sound_volume` row drives the Master bus, and 0 sets `set_bus_mute`, because a phone told to be silent should cost nothing to be silent.

**The wired set.** The beat column is what the asset is authored against; every number in it is in the WAV, not in a fader.

| event | source | cue | beat as shipped |
|---|---|---|---|
| `BlockDarkChanged{block_dark: true}`, `render_blackout_started(block_id)` | sim / §2.7.2 t=0 | `blackout_whomp` | mains hum cuts and glides down; the envelope's two stutters are at **0.09 s and 0.17 s** and the rumble reaches its silence floor at **1.20 s** |
| `BlockDarkChanged{block_dark: false}`, `render_relight_started(block_id, duration_s)` | sim / §2.7.3 t=0 | `relight_hum` | transformer swell, file length **3.15 s**, peak at **1.10 s** carrying the **1.35×** inrush overshoot — `render_relight_peak` needs no cue of its own because the beat is baked into the asset |
| `lightning_strike{world_pos, magnitude}` | doc 07 | `thunder_crack` ≤ 260 m, else `thunder_rumble` | delayed by `distance(camera, strike) / 340.0` s; `magnitude` spans a 6 dB range |
| `weather_changed{precip01, wind_kph}` | doc 07 | `rain` / `wind` / **`storm`** beds | rain gain follows `precip01` past a threshold; wind gain *and pitch* follow `wind_kph`; the storm bed needs **both** and sits under the wind bed (§2.15.1) |
| `vehicle_state{siren}` | doc 06 *(doc 10's civilian feed no longer emits it — D-10's diet)* | `siren_pass`, throttled | at most 2 audible, nearest-first, three hysteresis mechanisms, re-triggered every 3.3 s at the unit's current position (§2.15.1) |
| `incident_created` | doc 06 | `alert_high` when `notification_priority == 1`, else `alert_low` | doc 08's notification class picks the sting |
| `unit_dispatched` | doc 06 | `siren_pass` | placed at the incident it is answering (the payload carries no position); the pass-by fade and doppler are in the asset |
| `building_placed_sim` | doc 02 | `purchase` | the player's own confirmation — distance `none`, always crisp |
| `water_component_placed` | doc 05 | `purchase` | the same confirmation on doc 05's own event — a pump/tank/treatment shell is a doc-02 building that announces itself elsewhere, so it needs its own row or it opts out silently *(added 2026-08-20; it was observed for the site bed and mapped to no cue, so the $45,000 purchase the curriculum builds a level around was the one purchase in the game that made no sound)* |
| `building_construction_stage` | doc 02 | `construct_stage` tick + the `site` bed | the bed follows how many sites are live and how near the closest is |
| `building_completed` | doc 02 | `construct_complete` | and the site bed loses one source |
| `city_level_changed` | doc 02 | `level_fanfare` | 2 s, 20 s cooldown |
| `ui_tap` / `ui_confirm` / `ui_deny` | `ui/` via the shell | the three blips | synthetic events, so the UI layer emits intent and never a sound |
| `render_preset_changed(preset)` | §2.13 | — | mix bus reconfiguration only, no diegetic sound |
| `render_governor_stepped(knob, direction)` | §2.13 | — | silent; telemetry only |

**Not wired, deliberately.** ~~`vehicle_state.siren` (doc 06 via §2.12) would give per-vehicle doppler, but doc 10's feed is ~1,400 events per game hour and a per-vehicle emitter needs its own throttle design; `unit_dispatched` is the meaningful beat and is what ships.~~ **Wired 2026-08-19 (Audio-2 ruling) — see §2.15.1.** `render_chunk_ready` per-chunk bed gating is unnecessary while the bed set is six loops. `incident_escalated/resolved` and the flood events (`road_closed_flood`, `flood_level_changed`) are unsonified because the notification table does not fire a *sting* on them either — the mix and the alerts centre tell the player about the same things. *(That table is now doc 08's `data/notifications.json`, not `data/ui.json.alerts`, which was deleted the same day; the events themselves ARE notified in-app now, they simply have no cue.)*

#### 2.15.1 Audio 2 — moving sirens, count gain, the storm bed, the interior muffle (2026-08-19)

Four changes, three of them from the Audio-2 ruling and one from the same pass's weather brief.

**Moving sirens, and the throttle that is the actual deliverable.** `vehicle_state.siren` is wired. What made it wrong before was never the doppler — that stays baked into `siren_pass` and nothing pitch-shifts at runtime — it was that ~1,400 events per game hour with no policy is a wall of noise. `game/audio/siren_throttle.gd` is the policy: at most `sirens.max_sources` (2) audible, nearest-first, with **three separate hysteresis mechanisms** because one radius pops three different ways — `enter_m` 420 < `exit_m` 640 so a source must come closer to win a slot than to keep one; `takeover_margin_m` 90 so a challenger must be *meaningfully* closer than an incumbent, not merely closer; and `min_hold_s` 4.0 to bound how often the audible set can change at all. An audible source re-triggers its baked pass every `retrigger_s` 3.3 **at its current position**, so distance and direction fall out of the ordinary attenuation. Two ingest doors, one table: the `vehicle_state` record shape and doc 06's `IncidentSystem.vehicle_states()` snapshot (`sirens.siren_statuses` is the only place audio names a doc 06 FSM status). `unit_dispatched` keeps its rule as the *departure* beat and shares the throttle's identity (`key_prefix: "u"` → `siren_pass/u7`), so the two can never sound the same unit twice at the station door. A civilian vehicle now costs *nothing at all*: since D-10's bus diet (2026-08-19) doc 10 publishes one packed `traffic_snapshot` per tick carrying no siren field, audio does not subscribe to it, and the ~1,400-events-per-game-hour firehose that made the throttle necessary in the first place never reaches this class. The throttle stays — doc 06's fleet is what it was always really for — and the two-probe fast path stays with it, because a bulk-arriving vehicle record must be cheap whoever sends it.

**`count_gain`.** The dedup fold has always been right — twelve dark blocks are ONE thunk — but it also meant twelve blocks and one block were the same *sound*, which is a lie. `count_gain` adds `per_doubling_db` (1.6) per doubling of the fold count, capped at the ruling's **+4 dB**: legible between one block and eight, identical between twelve and forty. Opt-in per rule (blackout, relight, thunder, routine incidents); a construction tick deliberately does not swell.

**The storm bed.** A sixth loop, `storm_wind`, under the wind bed rather than instead of it: sub-100 Hz buffet, roar and gust-keyed rattle. Its source needs **both** inputs — a dry gale is a gale and a still downpour is a downpour, and only the two together are a storm — so `min_precip01` is a gate and wind is the axis that sets the level.

**The interior muffle.** One `AudioEffectLowPassFilter` on the **Ambient bus alone**, driven by `UIRoot.ui_coverage_changed`: when a sheet or panel covers more than half the screen the city is heard through it (20.5 kHz → 900 Hz, log-interpolated, −4.5 dB, over 0.28 s). SFX and UI are untouched — a confirmation blip is in the room with the player, and a sheet that muffled it would read as a fault.

**Assets.** The set is now **20 WAVs, 83.3 s, 4.54 MB** against the ruling's raised **4.5 MiB** budget (96.1%). The under-8 s loop brief is relaxed: the three atmospheric beds run **12 s** and the storm bed **10 s** — coprime in seconds, so the pair realigns only once a minute — while `site_loop` stays at 6 s because a crane loop is *supposed* to be periodic. `siren_pass` moved to 22.05 kHz (measured: 4.5e-6 of its energy in the top band) and `rain_loop` stayed at 44.1 kHz (measured: 6.0% at the half rate — rain genuinely is hiss past 7 kHz). The judging pass that came with the longer loops found a defect the seam metric could not: a one-cycle-per-buffer LFO gives every bed one swell at a fixed phase, and *a swell at a fixed place is a landmark* — a seamless loop with a landmark still reads as a loop. Every bed now modulates on coprime cycles (2, 3, 5, 7) with searched phases that put t=0 in the middle of the swing, and re-judging rated loop-point audibility 2/10 on both the rain and storm beds, down from "a clear marker for the start of the pattern".

**Deliberately not hooks.** There is no per-window, per-streetlight or per-instance audio event — the same reason there are no per-building dynamic lights. Block granularity is the audio granularity, exactly as it is the blackout granularity (report C-38).

### 2.16 LIVING CONSTRUCTION — plant, deliveries and the yard, **shipped 2026-08-20**

**The defect this closes.** Until this pass a building under construction *grew*. §2.6's vertex stage clamps every vertex to `build_height_m · stage/6`, so the massing rose a sixth at a time and §2.15's site bed ticked, and that was the whole read: a box got taller. `ConstructionSiteView` (the crane/hoarding pass) fenced the lot and stood a tower crane over it, which fixed the *silhouette* and left the *story* untold. Nothing on the lot was ever being **done** by anybody. This section is the other half: **plant that works, lorries that arrive on real streets, and a yard that fills and empties.**

**Where the work happens, and why it is not on the lot.** The stage clamp is VERTICAL only — the footprint is at full size from placement, so from stage 1 the ground inside the property line is under the building. The work zone is therefore the site's **street frontage**, and since the starter city authors no separate footway tile, the property line IS the kerb: the zone is the near half of the 8 m road tile in front of the lot. Stock against the hoarding at 0.95 m out, the barricade run on the lane line at 2.15 m, the plant straddling it at 4.40 m with the boom reaching back over the fence. That is a coned-off lane, which is exactly what an urban infill site takes.

**The hoarding gate faces the street too — shipped 2026-08-20** (closes this section's open question 4). The frontage below is the real road; `ConstructionSiteView` opened its gate on `hash01(id, 7) % 4`, so the two layers agreed **one time in four**, and what a player saw at the other three was a coned-off lane, a heap of aggregate and a lorry standing in front of a solid hoarding panel with the gate round the back. One seam closes it: `ConstructionSiteView.add_site` takes an optional `gate_side` (0 = −Z, 1 = +X, 2 = +Z, 3 = −X — the same four indices it already numbers its hoarding runs with), `ConstructionVehicleView.frontage_side()` publishes the answer as a pure query on a lot that need not be a site yet, and a `site_frontage_changed` signal carries a late or moved frontage into `set_gate_side`. The signal is needed and not belt-and-braces: routes resolve **two sites a frame**, so the frontage regularly lands after the hoarding went up, and a road edit can move it later. Omitting the argument keeps the hash exactly, which is what every pre-frontage call site draws.

The frontage is derived from the ROAD, not from `ConstructionSiteView`'s hoarding gate — the road is published sim state, so nothing can disagree about which way the street is, and this layer needs no coupling to the crane pass at all. It is derived by **walking straight out from each of the lot's four faces**, nearest step first and, within a step, the probe closest to the middle of the face. `RoadGraph.nearest_road_tile` is the wrong tool and it took a screenshot to see why: it answers *Chebyshev*-nearest, so a corner lot with roads on two sides is handed the **diagonal** tile between them. The frontage frame still reads the right side by dominant axis, but the lorry's stop lands twelve metres along the kerb, past the lot's own corner, with the plant strung out after it. A frontage is a face, so the search has to be one. A lot with no street inside the graph's snap radius gets no activity and says so (`Site.frontage_ok == false`).

**The lorry stops in front of the lot, not wherever the lane offset lands it.** Both route ends are pinned to the middle of the frontage tile. Left on the lane offset, a run ends on whichever side the *final approach* made "right" — half the time the far side of the street, facing away from the site it is delivering to, and never twice in the same place, which also means the plant cannot be laid out around it. Pinned, the stop is 4.0 m out from the property line: clear of the barricades at 2.15, square to the site, and the same every time. The two machines are then stood off the STOP — `stop_u ± (0.55·half_frontage + 6.5 m)` — rather than off the middle of the frontage, which is what stops a machine being parked inside the lorry about a third of the time.

**What ships.** All new files; nothing under `sim/` was touched.

| file | role |
|---|---|
| `game/render/construction_rig_mesh.gd` (`ConstructionRigMesh`) | the bodies. Excavator **440 tris**, tipper **432**, heap **27**, bundle stack **108**, barricade bay **240**. Same gray-box language and clockwise winding as `VehicleMesh` |
| `game/shaders/construction_rig.gdshader` | the joint chain, walked in the **vertex** stage |
| `game/render/construction_activity.gd` (`ConstructionActivity`) | the story. `RefCounted`, Node-free, clock-injected: stage + game-minute in, poses out |
| `game/render/construction_vehicle_view.gd` (`ConstructionVehicleView`) | the hands. Five MultiMeshes, the route queue, the distance gate |
| `data/render.json` → `construction_vehicles` | the tunables. A separate block from `construction`, so the crane pass and this one can never contend for a key |
| `tests/test_construction_living.gd` | 3,835 assertions, including the hash gate below |
| `tools/construction_preview.gd` | eye-level screenshots of one site, stage by stage, day and night — the harness this section's art decisions were judged with |

**Articulation without bones — the one idea in the pass.** A machine that reads as a machine moves at its *joints*. The two obvious ways to get that are a `Skeleton3D` per machine (a Node per bone, per machine — unaffordable at twenty sites) or one MultiMesh per part (five draw calls for one excavator, ten for the pair). This takes the third road: **the mesh carries its joint index per vertex in `UV2.x`, the chain's rest pivots are uniforms, and the per-instance joint ANGLES ride `INSTANCE_CUSTOM`.** The vertex stage walks the chain innermost-first:

```
p = VERTEX
if (j ≥ 4)  p = R₄·(p − P₄) + P₄       bucket curl
if (j ≥ 3)  p = R₃·(p − P₃) + P₃       arm
if (j ≥ 2)  p = R₂·(p − P₂) + P₂       boom
if (j ≥ 1)  p = R₁·(p − P₁) + P₁       slew (about +Y; every other joint is +Z)
```

Rotating about each joint's **rest** pivot and then applying the joint below it is exactly `M₁·M₂·M₃·M₄·p`, i.e. real forward kinematics — which is why the pivots are constants and the CPU writes four floats per machine per frame and nothing else. The normal takes the same product. `UV2.y` is the surface code (steel / stock / glass / beacon / lamp); the two prop pages are fetched **unconditionally** in the fragment stage and selected by code, so there is no `texture()` inside divergent control flow. `rig_mode` is a uniform, so the tipper's re-reading of channels 2 and 3 as *load fill* and *lamp intensity* is uniform control flow, not divergence.

**The result: one draw call per machine kind.** Twenty excavators with independent slew, boom, arm and bucket angles cost **one** call; the tipper's bed tilt and draining load cost **one** more.

**The beat the player is meant to read.** Everything below is a pure function of `(building id, stage, game-minute)`; the id is hashed for variation and there is no sim RNG anywhere in it.

| stage | excavators | lorries | yard |
|---|---|---|---|
| 1–2 | **2**, digging the frontage | arrive **loaded**, bed up, tip, leave empty | heaps grow with every delivery |
| 3–4 | **1** | as above | grow, but a stage this far along has already eaten more of it |
| 5–6 | **0** | arrive **empty**, are loaded with the bed DOWN, leave with the spoil | heaps come down; barricades lifted to half the run at 5, one token bay at 6 |

A trip is `depart → drive the route → stand and exchange a load → drive home → despawn`, once per hashed cadence (`delivery_period_gm` 46 game-minutes ±25% per site, phase also hashed, so a street of sites never runs a convoy). Delivering, the bed goes up fast, holds while the load drains, and comes down; the heap grows *during the hold*, so the material visibly moves from the bed to the ground rather than teleporting when the bed drops. Hauling spoil out the bed stays **down** — the load growing in it is the motion, and a tipper that raises its bed to be filled is a lie anyone who has stood on a site reads straight away. Piles rotate through three slots (sand, gravel, bundled steel), and a heap's base widens with `√fill` while its height grows linearly — how a tipped load actually behaves.

**The yard is measured from the START OF THE CURRENT STAGE, and that is not a detail.** The obvious model — a running delivery total minus a fixed per-stage offset — saturates and dies: a site fed for a game-day has delivered thirty loads, every slot pins at 1.0, and the heaps never move again for the rest of the build, which is the exact opposite of the read the pass exists for. Resetting the datum on every stage change gives the beat instead: **the stage consumes the yard, and the next round of deliveries rebuilds it**, with the `pile_consume_per_stage` term making each rebuild smaller than the last so a topping-out site has a clear kerb. `Site.stage_base` is that datum; like `Site.delivered` it is render-side and unpersisted.

**Plant liveries are all four saturated, on purpose.** Plant hire really does field white and grey machines, and the first pass had a pale grey in the table. Over a near-neutral steel page it produced a machine the player could not pick out of a grey street at all — the site read as rubble. "Construction is high-visibility" is worth more here than the catalogue's full range. For the same reason `body_metallic` is **0.08** and not the crane's 0.28: metallic kills diffuse, and at 0.22 a mid-green machine in full sun came out pale sea-green next to a crane that was frankly yellow.

**Street-true, at doc 10's own lane offset.** Routes come from `RoadNetwork.route_tiles(depot, site, RouteProfile.construction(21))` — the same call doc 06's fleet drives on, so a lorry and an ambulance obey the same closures and the same graph. Tile centres are pushed `lane_offset_m` (1.85, read from the `vehicles` block so this layer keeps to the same lane as the cars behind it) to the RIGHT of the centreline along the mitre of each corner, then Chaikin-cut **twice**, which turns a 90° junction into a turn rather than a pivot. The return leg is built from the reversed tile list, so out and back pass on opposite lanes. `tests/test_construction_living.gd` samples the whole run every 2 m and asserts every sample stands on a tile the road graph owns.

**Where the material comes from.** The default depot set is the **outer ring of the road network** — the road tiles at the extreme of its extent, i.e. where the streets leave the built city — subsampled to at most 12 and chosen from the nearest 4 by a hash of the building id. That is the honest answer while the player has no industry: material arrives from off-map. `ConstructionVehicleView.set_depots()` takes an explicit tile list, so a later pass that wants deliveries to leave the player's own industrial roster changes one call in the shell and nothing here.

**Renderer-local, and hash-neutral by construction.** No sim state, no sim RNG stream, no `sim/` edit, nothing persisted. The clock is **game-minutes**, integrated between ticks and re-synced to `GameClock.game_seconds()` whenever the shell offers it, so 3× speed drives the plant three times as fast, pause parks every lorry exactly where it stands, and a load or a catch-up puts the layer where the save says it is. The one piece of retained state is `Site.delivered`, a render-side high-water mark that keeps the delivery count monotone across a re-route — a heap that shrank because the street network changed would be a lie the player cannot account for.

**The hash gate, and why it needed one.** This layer reads `route_tiles()` off the LIVE network, and `route_tiles` goes through `RoutePlanner.quote()`, which touches the planner's LRU. An eviction the *renderer* caused could in principle force a later sim quote to re-run A* instead of re-pricing a cached entry — and `_finish`'s `best_total` and `_price_route`'s re-sum are different summation orders of the same edge costs. `tests/test_construction_living.gd::test_route_lookups_do_not_move_the_state_hash` interleaves 240 lookups (twenty sites' worth of out-and-back legs, every game hour for six hours) into a running `CitySim` and compares `state_hash()` against a clean run. It matches. The same probe was run at 960 lookups over 24 h on the starter city and 1,440 over 24 h on the benchmark city (3,132 road tiles) before the layer was written; both matched. If a future planner change ever makes a renderer read observable, that test goes red rather than a screenshot three waves later.

**Budgets, measured.** `tools/profile_frame.gd --sites=N --site-stage=S --site-gm=M` stands N sites on the N buildings nearest the city centre, winds the layer's clock past a dozen cadences so the yards are FULL, and times the layer's own `refresh()` on the main thread with `Time.get_ticks_usec()`. It is timed rather than inferred because this harness's `frame_ms` is presentation-bound on a fast desktop — mean and p95 both sit on the refresh interval, and a sub-millisecond layer is invisible in it.

Bench city (1,500 buildings), preset balanced, hour 21, 240 measured frames after 90 warm-up, 20 sites at stage 2 → **40 excavators, 24 lorries, 40 heaps, 20 stacks, 78 barricade bays = 202 instances** *(labelled 1920×1080, rendered at 1280×720 — report RR-28; the layer-CPU column is main-thread GDScript and is resolution-independent, so it stands, and §2.13's Fold pass re-measures it at true 1080p across the whole site range anyway)*:

| | `--sites=0` | `--sites=20` | delta | budget |
|---|---|---|---|---|
| Z2 non-building draw calls | 79 | **84** | **+5** | ≤ +12 |
| Z2 primitives | 198,090 | 260,338 | +62,248 | — |
| Z1 layer CPU, mean | — | **0.460 ms** | — | < 0.8 ms |
| Z1 layer CPU, p95 | — | **0.536 ms** | — | — |
| Z2 layer CPU, mean / p95 | — | 0.448 / 0.485 ms | — | — |

The draw-call column is the **non-building** term (total minus the three building terms) because the chunk-tier census wobbles between runs of the harness by ±1 chunk and swamps a +5 delta; it is only meaningful at Z2, where `buck` is 0 and no bucket is re-drawn into a shadow split. +5 is the structural answer as well as the measured one — five MultiMeshes, one per model kind — and it does not grow with the site count, only with the kind count. *(The measurement above is the loaded case, with all five buffers carrying instances. A city with no site under construction leaves all five at `visible_instance_count = 0`; that case was not separately measured, so 5 is quoted as the ceiling and not as a floor.)* **Closed 2026-08-20 by §2.13's Fold pass:** the no-site case is now measured — 0 sites is 42 draw calls at Z1 on the founding city and 1 site is 47 — so five is the whole layer, from a true zero, and it does not move between 1 and 28 sites. **The same pass replaces the 1.5–1.9 ms estimate with a measurement and it was 3× pessimistic:** 0.020 ms/site on the founding city (0.045 at 1 site, 0.105 at 3 — which is the range the founding city actually runs) and 0.026 on the bench, putting `max_sites` 28 at **0.728 ms mean / 0.818 ms p95** against the 0.8 ms budget this section wrote against 20 sites. The governor does **not** get a `max_sites` rung; §2.13 carries the ruling and the alternative that was filed rather than taken.

**What the 0.46 ms is spent on, and what it is not.** Everything a FRONTAGE fixes — the two machines' standing transforms, each pile's position and yaw, the barricade run for the current stage — is computed once per route (and, for the barricades, once per stage) and copied thereafter. The clock moves the bucket, the bed, the lorry along its polyline and the heap's height; it does not move the ground under any of them. Caching that took the figure from 0.584 to 0.460 ms. What is left is dominated by the ~200 `set_instance_transform` / `_color` / `_custom_data` triples — the same per-instance upload path §2.12's traffic layer uses at a comparable count, so it is the incumbent cost, not a new one.

**Shadows are OFF by default**, for the reason `vehicles.cast_shadows` already documents: instances are written straight into the buffer and never update the auto AABB, so the custom AABB is world-sized and every layer intersects EVERY split. The per-preset `vehicle_shadows` row overrides it, so High re-draws the plant into its four splits and Balanced and Performance do not.

**How the picture was judged.** `tools/construction_preview.gd` parks a camera on the site's own frontage at doc 12's Z0 pose — the closest a player can ever get — and walks the six stages, giving each one its own run of deliveries so the yard has had time to fill:

```bash
~/.local/bin/godot --path "/home/bbx/Slacum City game" \
  -s res://tools/construction_preview.gd -- --out=/tmp/site --stages=1,2,3,4,5,6 --hour=13
~/.local/bin/godot --path "/home/bbx/Slacum City game" \
  -s res://tools/construction_preview.gd -- --out=/tmp/site-night --stages=1,3,6 --hour=21.5
~/.local/bin/godot --path "/home/bbx/Slacum City game" \
  -s res://tools/construction_preview.gd -- --out=/tmp/sweep --sweep --frames=8
```

Four defects came out of that pass and out of nothing else: the pale livery, the metallic wash, the diagonal frontage tile, and a single barricade bay stretched across 24 m of kerb at stage 6 (the scale was being taken from the *reduced* bay count instead of the full run — one bay lifted has to look like one bay lifted). All four are fixed above; each is worth naming because none of them could fail a test.

**Deliberately not built.** No dust plume behind a lorry and no exhaust: both are particle systems, both are a second draw call each, and neither survives the 0.8 ms line at twenty sites. No workers on foot — a 1.7 m biped at Z1 is nine pixels tall and would cost a sixth MultiMesh to be a smudge; the machines are the read. No per-site OmniLight for the beacon — §2.10's rule (block granularity, not instance granularity) applies here exactly as it does to streetlights, and the emissive sweep in the shader is what the beacon is.

---

#### 2.16b The pose cache — what a site emits when nothing about it has moved (2026-08-20)

RR-32's instrumented split put **0.32 ms of the layer's 0.53 ms at 20 sites in
`ConstructionActivity`**, deriving every barricade bay, every heap and every
machine's standing transform sixty times a second for values that had not moved.
Most of what a site emits is not a function of the clock at all: a barricade run
is fixed by the frontage and the stage, a heap by `delivered` and the stage, a
machine's transform and livery by the frontage. **Only the excavator's joint
channels and the lorries animate.**

So the emitters cache, and the cache is exact rather than approximate. The `Pose`
objects are POOLED and never reallocated (that pooling is why the layer's
per-frame cost was in "trig-free territory" to begin with), so when a site's
slice of a pool has not moved and none of the facts behind those poses has
changed, the objects in that slice are **already carrying exactly the floats this
frame would write**. Skipping is declining to write the same bits twice, not
substituting an older value for a newer one — which is why the contract can be
BIT identity and why `pose_cache = false` is a property rather than a build flag:
it is the A/B arm the property test and the profiler both drive.

Three keys, each with exactly one writer:

* **`Site.layout_serial`** — bumped by `_lay_out_fittings` and
  `_lay_out_barriers`, which between them are the only places anything a cached
  pose reads is written. Every re-route and every stage change passes through one
  of them.
* **`Site.stage`** — the pile datum (`stage_base`), the machine count and the
  barricade run all move with it.
* **`Site.delivered`** — the yard's high-water mark. `delivered_at()` is still
  evaluated **every frame**, because it feeds that mark and skipping it would let
  a re-route lower a count the uncached path would have held. What the cache
  skips is the expensive half: three `slot_count` pairs, a `sqrt`, a scaled basis
  and four `Color` constructions for heaps that have not moved a millimetre.

And one rule that is not obvious and is the only way a slice-index cache can be
wrong: **a site that did not emit on the immediately preceding pass re-emits
unconditionally.** `radius` and `limit` gate sites out of a pass, and the slots a
gated-out site used to own may have been handed to another site while it sat
there. A steady-state run would never show it; the property test's walking focus
gate does.

Two changes ride with the cache and are worth about half of it. The schedule's
three derived numbers — the leg, the round trip and the trip window — are settled
once per route in `_reprice` instead of by four NESTED function calls per site
per frame (`_trip_window` called `leg_gm` called `has_route`), which at
`max_sites` was thousands of GDScript calls a second re-deriving a constant. And
`dig_pose` reads two `PackedFloat64Array` columns built from the authored
`DIG_KEYS` table instead of unboxing a Variant per element out of an Array of
Arrays. Both are the same floats in the same order; §2.13's table has the
measurement.

### 2.17 STREET LIFE — the crook, the dog, the goat and the glint, **shipped 2026-08-21**

**The defect this closes, in the player's own words.** *"There's not a lot of downtime of absolutely nothing to do… these things just pop up periodically, so a user scrubbing around their town can actually see them and give them money for things."* Until this pass, a city with nothing on fire and nothing under construction had **nothing happening on its streets that the player could act on**. §2.12's traffic moves and §2.16's plant works, but neither of them is *addressed to the player*: a car cannot be tapped, and a lorry that arrives is a thing that happens whether anyone is watching or not. The sim's opportunity system (`sim/street/opportunity_system.gd`) supplies the events; this section is the half that makes them **findable while scrubbing, and irresistible once found.**

**What ships.** All new files; nothing under `sim/` was touched, and this layer never reads it.

| file | role |
|---|---|
| `game/render/street_life_mesh.gd` (`StreetLifeMesh`) | the bodies. Crook **220 tris**, dog **192**, goat **252**, plus the flat quad everything else is drawn on. Extends `ConstructionRigMesh` — see below |
| `game/shaders/street_life.gdshader` | the joint rig, walked in the **vertex** stage; one rotation per vertex, not a chain |
| `game/render/street_glyph_atlas.gd` (`StreetGlyphAtlas`) | sixteen signed-distance marks — the digits, `+`, `$`, `!`, `k`, a paw, a bell — on one 256 × 20 page built in GDScript at boot |
| `game/shaders/street_fx.gdshader` | marker, label, puff, ring and sparkle, **one shader, one buffer**, dispatched on a mode code |
| `game/render/street_life_model.gd` (`StreetLifeModel`) | the story. `RefCounted`, Node-free, clock-injected: events + a tile probe in, poses out |
| `game/render/street_life_view.gd` (`StreetLifeView`) | the hands. Four MultiMeshes, the distance gate, the shell's tap handles |
| `data/render.json` → `street_life` | the tunables |
| `tests/test_street_life.gd` | 526 assertions, including the hash gate below |
| `tools/profile_frame.gd` → `--street-life=N`, `--street-collect=F` | the A/B instrument and the screenshot harness, both |
| `tests/test_asset_completeness.gd` | two rows: §16's shader roster is 16 → **18**, both owned by `StreetLifeView` |

#### The budget was six draw calls. It costs four.

| buffer | what it draws |
|---|---|
| `MM_crook` | the hooded figure with the swag bag |
| `MM_dog` | the stray |
| `MM_goat` | the goat |
| `MM_fx` | **markers, `+$N` labels, poof puffs, rings and stash sparkles** |

The fourth is the interesting one. A marker, a floating digit, a puff of dust and a sparkle are the same object — a flat quad turned to face the camera, alpha-blended, writing no depth — so they are one MultiMesh with a **MODE in `INSTANCE_CUSTOM.r`** rather than four buffers and four calls. The two calls that gives back are what the shell's tap affordance and the next wave get to spend.

The fourth kind of opportunity, a dropped **stash**, deliberately has no body at all: it is a `$` marker over a ground sparkle, so it varies the street for zero extra geometry and is what any *unknown* event kind falls through to. Guessing "goat" for an event this layer has never heard of would put livestock on the street because a string was typo'd.

#### Articulation without a chain — how this rig differs from §2.16's

§2.16's `construction_rig.gdshader` walks a strictly **nested** chain, because a boom carries an arm which carries a bucket. An animal is the opposite shape: four legs, a neck and a tail all hang off ONE barrel and none of them moves any other. So there is no cascade here. Every vertex names its joint in `UV2.x`; that joint names its own pivot and axis in `rig_pivot[8]` and its own `INSTANCE_CUSTOM` channel in `rig_sel[8]`; the vertex stage applies **exactly one rotation**:

```
j     = int(UV2.x)
a     = dot(ang, rig_sel[j])           // channel mask × gain — one dot product
R     = rot_z / rot_y / rot_x by rig_pivot[j].w
VERTEX = R·(VERTEX − pivot) + pivot
```

`dot(ang, rig_sel[j])` rather than `ang[channel]` is deliberate: the mask carries the gain, so no driver has to support dynamic indexing into a vector.

**And the pay-off is in `rig_sel`.** A trot is the two DIAGONAL legs swinging together against the other two — so all four legs read channel 0 and the second diagonal simply carries **gain −1**. Four legs, a neck and a tail — six moving parts — off **three** animated floats. The fourth is the leaving animation. The channels are identical for all three bodies so the model has one animator and not three:

| channel | crook | dog | goat |
|---|---|---|---|
| `.r` LIMB | legs | all four legs, diagonally paired | ditto |
| `.g` HEAD | a furtive **yaw** — he checks over his shoulder, and most while standing still | bob on the stride, nose down at rest | browse: head at the kerb while parked, level on the amble |
| `.b` EXTRA | arms, counter-swinging the legs | tail, hardest while moving | tail flick |
| `.a` FX | 0 = standing there, 1 = gone | | |

The channel envelopes are authored **symmetric about zero** (`±0.62 rad` for limbs and head, `±0.72` for the extra), because `gain = −1` is only a true mirror across a symmetric range — an asymmetric one gives a trotting dog a limp. `tests/test_street_life.gd` asserts that, and asserts that every joint a MESH uses has a row in the rig table its MATERIAL uploads: a vertex on joint 6 of a body whose table stops at 5 rotates about the world origin, the animal draws with a leg through the pavement, and nothing else in the suite would say so.

**The one channel that is not a joint.** `.a` FX is a scalar 0 → 1, and the instance COLOUR's alpha says which kind of leaving it is: **1 = collected**, so the body lifts `fx_lift_m` off the pavement and flashes; **0 = expired**, so it takes none of the lift and shrinks into its own feet instead. Shrinking about the body's own origin — which is on the ground between its feet — is what makes a collect read as a pop upward and an expiry read as sinking, from one float and no second shader.

#### The three gaits ARE the characterisation

Everything below is a pure function of `(id, elapsed game-minutes)`; the id is hashed for variation and there is no sim RNG anywhere in it.

| kind | move | pause | the read |
|---|---|---|---|
| crook | 0.90 gm | 1.55 gm | **SKULKS.** A long wait and a short fast dash, head turning while he waits |
| dog | 1.10 gm | 0.34 gm | **TROTS.** Barely a pause, diagonals swinging, tail going |
| goat | 1.55 gm | 1.95 gm | **BROWSES.** A long head-down pause, an amble, and now and then a straight-legged hop |

Each is hashed ±20% per id, so two crooks on one street never pace the same beat. The three read differently at Z1 *from their timing alone*, before any triangle of their bodies is resolvable — which matters, because at Z1 a 1.8 m body is **30 screen pixels** on a 1080-line frame.

**Stride phase follows DISTANCE, not time.** `sp = travelled_m / stride_m`, so the legs match the speed the body is actually crossing the pavement at. Driving the cycle off the clock instead is the single most common way a walk cycle turns into a body sliding along with its legs waving.

#### The wander is a CLOSED FORM, and that is what makes it deterministic

Each opportunity gets a ring of hashed waypoints round its anchor, each leg gets a hashed move and pause duration, and the position at time `t` is read out of `fposmod(t, cycle)`. So it is a pure function of `(id, elapsed)` — **nothing accumulates.** Nothing drifts across a frame-rate change, a pause, a clock re-sync or a save; the same id walks the same path on every device; and a catch-up that skips six hours puts the goat exactly where the save says rather than where the frame counter got to. The test asserts it by sampling one id through two differently-stepped clocks and by comparing a walked model against one that jumped straight to the same minute.

**TWO CLOCKS, and the split is deliberate.** The **wander** runs on GAME-MINUTES, like §2.12's traffic and §2.16's plant: a paused city is a still city, and a 3× city has three times as much happening. The **FX** — the collect burst, the rising label, a body shrinking as it leaves — run on REAL SECONDS. They are feedback about a TAP, not motion in the world, and a `+$120` that freezes in mid-air because the player paused a quarter-second after collecting is a bug, not a feature.

#### The kerb, because a crook loitering in a live traffic lane is a different event

The anchor is snapped off the road CLASS (`StreetLifeView.road_probe`, bound to the world map exactly as `PowerInfraFeed.road_probe` is), and there are three cases:

* **The spawn tile IS a road** → the body belongs on that tile's FOOTWAY. Kerbed sides are found in a fixed order and the id picks between them, so two crooks on one tile do not stand on the same slab. The anchor lands in the middle of the 1.40 m (street) or 1.05 m (avenue) footway, at `asphalt_top_m + kerb_height_m` = 0.25 m — **the kerb §2.1.2 actually drew**, read from the `road_surface` block rather than restated here.
* **A NEIGHBOUR is a road** → the footway on that road's near side is the pavement in front of this lot, which is exactly where a stray or a dropped wallet would be.
* **No road in reach** → the body wanders its own tile at ground level, and the ellipse stays circular.

**A snapped wander is SQUASHED across the kerb line** (`wander_across` = 0.30). Left circular, a 2.9 m wander round a 1.40 m footway puts the crook in the middle of the carriageway one second in four. Squashed, he never leaves 0.87 m of the kerb line — which is inside the tile, i.e. never in a traffic lane, and the test asserts exactly that bound.

#### The marker holds a SCREEN size, not a metric one

This is the "*a user scrubbing around their town can actually see them*" requirement, in numbers. `marker_angular` is **metres of marker per metre of camera distance** — an angular size — clamped at both ends:

| pose | camera | marker | on a 1080-line frame |
|---|---|---|---|
| **Z0** | 18 m | 0.95 m (min clamp) | **78 px** — a pin, and a comfortable tap target |
| **Z1** | 86.9 m | 2.69 m | **46 px** — legible while scrubbing, which is the pose that matters |
| **Z2** | 420 m | 3.30 m (max clamp) | **12 px** at 0.30 alpha — subtle, present, not gone |

Beyond `marker_fade_begin_m` (150 m) the alpha ramps to `marker_far_alpha` (0.30) at the visible radius, and a faded instance is **collapsed to a point in the vertex stage** so the rasteriser never sees it — the same gate `lamp.gdshader` uses for its daylight quads. The BODIES are gated 190 m earlier than the markers (`body_radius_m` 240 against `visible_radius_m` 430), because a 1.8 m body at Z2 is six pixels and not worth a triangle, while the marker is the thing the player is scrubbing FOR.

The marker is a **map pin**: a rounded chip with a tail, drawn from an SDF in the fragment stage, with the kind's mark inside it — `!` for the crook, a paw for the dog, a bell for the goat, `$` for a stash. It **pulses in brightness and never in size**, and it **bobs on the CPU**, both for the same reason: the marker's size and position are the shell's tap target, so `marker_world_pos(id)` and `marker_radius_m(id)` have to be exactly where the thing is drawn.

#### The page: sixteen marks, one texture, no font

A floating `+$120` wants text, and the obvious tool is a `Label3D` — a Node per label, a `TextMesh` rebuild per value and **a draw call per label**. What ships instead is one 256 × 20 page in which every mark is a **signed distance field**, so a label is a run of MultiMesh quads sharing one buffer and one call, and `smoothstep` across the 0.5 contour reconstructs a hard edge at Z0 (82 px per metre) and Z1 (17 px) alike, with no mipmap chain and no second authored size. The same field gives the labels a dark outline for free, at a second contour.

**The trap, and it is worth writing down.** A glyph here is authored as ink on a 5 × 7 cell grid, so it is a union of unit cells — and the *obvious* field is `min` over the cells of the box distance. That is wrong: at the seam between two touching cells both boxes report distance 0, so `min` puts **a contour along every internal cell edge** and the digits come out striped like graph paper. The distance to a union is the distance to the union's BOUNDARY, so that is what is measured: the boundary is extracted as axis-aligned edge segments (a cell edge with ink on exactly one side), collinear neighbours are welded into runs, and the sign comes from a grid lookup. Exact, seam-free, ~18 segments a glyph over 320 texels, and **8.9 ms of GDScript for the whole page, once per process**. `test_the_page_has_no_internal_seams` samples the four cell junctions at the centre of `+`.

Rewards abbreviate at 10,000 (`+$12k`). That is not cosmetic: a label is a billboard whose width is glyph count × pitch, and `+$1250000` at Z0 is a nine-glyph banner three car-lengths wide lying across the street it was earned on. Six glyphs is the width the art is tuned for, and the ladder stops at `k` because `+$1.2M` would need a decimal point the page does not carry.

#### The collect moment

On `opportunity_collected`: the marker goes **that frame** (the thing has been taken; leaving it up for another 200 ms is the layer telling a lie), a **poof** takes its place — six puffs on hashed bearings plus one expanding ring — the body lifts and flashes as it shrinks, and a `+$N` rises off the marker's own position — `label_rise_frac` of the MARKER's size, not a fixed metre count, so it travels the same number of screen pixels at Z0 as at Z1 — on an ease-out, held solid for the first 55% of its life and faded over the rest. A number that starts dissolving the instant it appears is a number nobody reads. An animal **bounds off** as it goes (`bound_m` along its own heading, on a `sin` arc); the crook does not, because he is cuffed on the spot and the flash is what says so.

On `opportunity_expired`: half the puffs, greyer, falling rather than flying, **no ring and no label** — because nothing was earned, and the absence of the number is the whole message.

#### Measured

`tools/profile_frame.gd --street-life=N` stands N opportunities on the road tiles nearest the focus and drives the layer every frame; `--street-collect=F` collects one every F frames and immediately respawns it, so **every measured frame carries a poof and a rising label** — the worst case, rather than the one-in-thirty a real cadence would happen to put in front of the camera. The two runs differ in nothing else, so the `dc` delta IS the layer.

| pose | `--street-life=0` | `--street-life=5 --street-collect=45` | delta | layer CPU mean / p95 | fx buffers submitting |
|---|---|---|---|---|---|
| **Z0** D 18 m | 237 dc | **241 dc** | **+4** | 0.131 / 0.166 ms | 4 |
| **Z1** D 86.9 m | 233 dc | **237 dc** | **+4** | 0.126 / 0.142 ms | 4 |
| **Z2** D 420 m | 196 dc | **197 dc** | **+1** | 0.074 / 0.085 ms | 1 |

`tools/profile_frame.gd --city=res://tests/fixtures/bench_city.json --preset=balanced --hour=13 --resolution=1920x1080`, 1,500 buildings, five opportunities, one collected every 45 frames. Against a **+6 budget** and a **0.3 ms** layer-CPU budget at five live.

**Z2 costs one call, not four, and that is a line of code rather than luck.** A `MultiMeshInstance3D` whose buffer holds `visible_instance_count == 0` **still costs a draw call**, and this layer's custom AABB is world-sized — it has to be, because instances are written straight into the buffer and never update the auto AABB — so the frustum culler can never drop it either. The first measurement read **200 dc** at Z2 with all three body buffers empty (every body is past `body_radius_m` at that pose) and one live marker buffer. `StreetLifeView._write` now sets `node.visible = n > 0`, and Z2 reads 197. `active_buffers()` is therefore exactly the layer's draw-call count, and the profiler prints it.

The whole page is built once per process at **8.9 ms** of GDScript, which is a boot cost and not a frame cost; `StreetGlyphAtlas.build_usec()` reports it.

#### The repro commands the art was judged with

The harness is `profile_frame` rather than a preview scene of its own, because
the thing being judged is the marker against a REAL street at a REAL pose — a
preview stage would put it against whatever background flattered it.

```bash
# Day, all three poses, five opportunities, one collected every 45 frames so a
# poof and a rising +$N are in every measured frame.
DISPLAY=:0 ~/.local/bin/godot --path "/home/bbx/Slacum City game" \
    -s res://tools/profile_frame.gd -- \
    --street-life=5 --street-collect=45 --hour=13 \
    --warmup=30 --frames=45 --resolution=1920x1080 --shots=/tmp/sl_day

# Night — the marker's emission lift and the glow threshold.
DISPLAY=:0 ~/.local/bin/godot --path "/home/bbx/Slacum City game" \
    -s res://tools/profile_frame.gd -- \
    --street-life=5 --street-collect=40 --hour=21 \
    --warmup=30 --frames=50 --resolution=1920x1080 --shots=/tmp/sl_night

# The A/B control. Identical in every other respect, so the `dc` delta IS the
# layer and an image diff of the two `--shots` directories IS the layer too.
DISPLAY=:0 ~/.local/bin/godot --path "/home/bbx/Slacum City game" \
    -s res://tools/profile_frame.gd -- \
    --street-life=0 --hour=13 \
    --warmup=30 --frames=45 --resolution=1920x1080 --shots=/tmp/sl_off
```

**Diff the two shot directories rather than eyeballing one.** Two of the three
defects this pass fixed were found that way and neither could have been found by
assertion: an SDF page hinted `source_color` drew a *perfect, empty* pin, and a
label laid out in world space read as `+ 20` and skewed with the camera. A
bounding box over `ImageChops.difference(off, on)` puts the crop window exactly
on the layer, at every pose, in one line.

#### The shell's handles

The tap itself belongs to the shell. This layer publishes three things and nothing else:

```gdscript
view.live_ids()             -> Array[int]   # ids with a marker on screen NOW
view.marker_world_pos(id)   -> Vector3      # where to aim, bob included; INF if not drawn
view.marker_radius_m(id)    -> float        # how big the target is at this zoom
```

`marker_radius_m` exists because the target's size is not a constant: at Z0 the pin is 0.95 m across and at Z2 it is 3.30, and a tap radius authored in metres would be four times too generous at one end of the ladder and half the size of the mark at the other.

#### Hash neutrality

This layer is a **pure event consumer**: it takes a drained batch and a tile probe and gives back nothing — no command, no sim query, no route lookup, not one clock read of its own. `test_a_full_street_life_frame_leaves_the_state_hash_alone` pins it the only way it can be pinned: a clean 6-hour run against the same 6 hours with a full frame of this layer — spawns, wanders, collects, expiries and every road probe they take — driven at every hour boundary, comparing `state_hash()`. If a future change ever makes this layer read the simulation, that is what goes red, and not a screenshot three waves later.

### 2.17b STREET POLISH — the flee, the shadow, the anchor, **shipped 2026-08-21**

*The five art items §2.17 filed against itself, plus the one the traffic layer
had been carrying since Wave 6. Arguments and measurements: report 98 §36
(RR-90 … RR-93); the rulings they bind: doc 93 §V.*

#### The crook legs it

An animal bounds away the instant it is collected. A crook now **runs, and is
then caught**: a dash of `flee_s` seconds (hashed per id inside an authored
`[0.40, 0.70]`) over `flee_m` metres, and only then the cuff-flash the shader
already drew. It costs one float on the record, no new buffer, no new event and
no new clock — the dash is a pure function of `(id, elapsed since the tap)`
exactly as the wander is a pure function of `(id, elapsed since spawn)`.

**The order of the three cues is the feature.** Tap → the `+$N` rises AT ONCE
and stays where the finger was (doc 93 §T1: the money landed when the finger
did) → the crook runs → the poof lands **on him, where he was caught**, because
a poof is a physical event and the physical event is the arrest. The animals'
poof still belongs to the spot they were taken at, because the animal is what
left and the dust is what it left behind.

**Direction: along the kerb, sign hashed.** The nearest road exit a man standing
on a pavement has *is that pavement*; a flee across the carriageway would be a
flee into traffic. `Op.along` already carries the kerb line, so the dash takes
it and the id picks the sign — two crooks caught on one corner do not run the
same way, and the same crook runs the same way on every device and after every
load. An unsnapped body (no probe, or a lot with no street in reach) takes a
hashed compass bearing instead, which is the honest answer: there is no street
to head for.

#### Blob shadows — the knob that removed a cue now replaces it

`vehicle_shadows` is `false` on Performance and Balanced, i.e. on every phone,
and §2.11's `blob_shadow` block had existed since the preset table was written
with **nothing reading it** — so every body in this layer floated. One knob now
decides both: `StreetLifeView.set_preset` pushes `vehicle_shadows` into
`StreetLifeModel.set_blob_shadows` **inverted**. Real where the tier can afford
to re-draw a body into every split, a blob decal where it cannot, never neither.

The blob is a **sixth MODE on the existing fx buffer**, not a fifth buffer:
`INSTANCE_CUSTOM.r == 5`, and it is the one quad on that buffer that must not
face the camera, so the vertex stage `mix`es the billboard's three basis columns
against the instance's own on a mode test. Three vec4 mixes, no branch,
**+0 draw calls** — measured at 91/109 dc at Z0/Z1 with and without, +4
instances and +0.010 ms of layer CPU for four bodies.

Two corrections came out of photographing it rather than reading it, and both
generalise (doc 93 §V3): a `blend_mix` pass mixes *towards* a colour rather than
multiplying by one, so a sky-grey shadow was **lighter than the shaded
carriageway** it was cast on; and a body has an **area** of contact, so the
poof's `pow(1 − r, softness)` — which peaks at one pixel — put 244 pixels of
real shadow into a 1920 × 1080 frame. Black plus a core-and-rim falloff, at the
same instruction count, moves 2,637 pixels.

`blob_shadow` therefore has **two consumers with two different gates**, and the
block says so at the point of use: `enabled_presets` belongs to §2.11's
per-BUILDING decal, `body_alpha` / `body_m` / `body_lift_m` to this layer, and
this layer's on/off is `vehicle_shadows`. A body is a dynamic object, so it
takes the dynamic-shadow knob.

#### A body stands on the ground it is walking on

Latent since §2.17 shipped, and found by the decal that had to lie on it. A
body deep inside a junction has four road neighbours, therefore no footway
anywhere on its tile, therefore `_anchor` left it at **y = 0 — ten centimetres
inside the carriageway** it was walking on. Invisible on the body (its boots
were simply gone against a dark road) and fatal to a flat shadow, which was
depth-buried under the road it belonged to. It is the same defect report NIGHT-1
found under the lamp pools, in the same 0.10 m. An unsnapped body on a road tile
now stands on `asphalt_top_m`.

#### `born_gm` — the cold load, which was worse than a missing field

The wander is a closed form in `(id, now − born)`, which is what makes it exact
under pause, catch-up and frame-rate change — and undefined after a cold load.
Worse: **the layer never learned the roster existed.** `CitySim.restore_state`
refills it in silence (there is no `opportunity_spawned` for a row that was
already on the books) and `main.gd`'s load path resyncs the road surface, the
vehicles, the power layer, the lamps and the flood field — and not this one. A
crook the player was walking toward was live, tappable, paying and invisible
until it expired.

Doc 06 §2.16's payload gained `born_gm`, the spawn game-minute, written once and
persisted with the row; this layer gained `seed_roster(rows)`, which replays a
restored roster as spawns carrying it. Every body comes back **mid-wander**. A
row written before the field derives it from `spawned_h × 60`, which is exactly
what the spawner would have written.

> **The shell owes one call.** `street_life.seed_roster(sim.street.live())` on
> the load path, beside `streetlights.replace_from` and `flood_view.prime`.
> Without it the layer is correct and empty.

#### The empty-buffer audit (RR-83's corollary, closed)

`node.visible = n > 0` is now on every layer whose instance count legitimately
reaches zero: `ConstructionVehicleView`'s five buffers, `VehicleView`'s seven
bodies and its headlight cone, `CityView`'s bucket and far nodes.
`PowerInfraView` and `FloodView` already had it; `StreetlightView` frees a
lampless chunk rather than emptying it, so it never applies.

| bench city, balanced, hour 21 | Z0 | Z1 | Z2 |
|---|---|---|---|
| baseline, before | 95 | 113 | 196 |
| layers present and empty, before | 100 | 118 | 201 |
| baseline, **after** | **87** | **105** | **188** |
| layers present and empty, **after** | **87** | **105** | **188** |

**−13 draw calls at every pose on a quiet city.** `VehicleView` and
`ConstructionVehicleView` publish `active_buffers()` and `profile_frame` prints
it, for the reason RR-83 gave: a budget claim that cannot be printed is a budget
claim nobody re-checks.

#### The harness grew four flags, and three of them are why the pictures exist

| flag | what it buys |
|---|---|
| `--quiet-layers` | builds both optional layers with nothing in them — the QUIET CITY, the case that could not be measured before because `--sites=0` did not build the layer at all |
| `--traffic=N` / `--units=N` | stands vehicles on the street with **no UI layer in the frame**; ids are solved so the run walks the whole civilian palette once before repeating, so a screenshot of it is a contact sheet |
| `--street-gm=M` | PINS the wander clock, which is what makes a street-life screenshot A/B-able: free-running, two runs put the bodies in different parts of their beat and a pixel diff measures the frame rate |
| `--street-shot-lag=N` | collects the whole roster N frames before the capture, so `--shots` lands on a chosen moment of the leaving animation — the instrument the flee A/B was taken with |

#### 2.17c WAVE 17 — three more flags, and the one that makes a picture A/B legal at all (2026-09-01)

| flag | what it buys |
|---|---|
| `--anim-step=S` | hands the three layers that keep their OWN `anim_time` — `VehicleView`, `ConstructionVehicleView`, `StreetLifeView` — a FIXED per-frame delta, so their clocks after N frames are exactly `N·S` and two runs of one command are comparable pixel for pixel. **`--street-gm` pinned the wander and NOT `anim_time`, and nothing pinned the other two at all**: two identical free-running runs of the layered Z1 command differ on **0.28 % of the frame — 5,741 px, mean \|Δ\| 2.6, peak 154** — which is the 2.2 Hz light bar and the beacon sweep, and a peak of 154 on a floor that moves every run is enough to swallow an A/B whose whole change is 1–3 % of the frame. Pinned, two runs are **bit-identical — 0 of 2,073,600 pixels, at Z0 and at Z1.** Report 98 RR-95. Every published TIMING row was measured free-running and stays that way; this is a picture instrument |
| `--no-lod` | draws EVERY chunk at LOD0 (`CityView.lod_enabled = false`), the showcase's flag of the same name. The reference arm of the LOD-pop sweep: at Z1 the shipped ladder and this arm are **bit-identical** (every chunk in a Z1 frame is inside the 150 m NEAR band); at Z2 the FAR box differs on 25.6 % of the frame, which is §2.5's far tier by design. Report 98 §38, the visual-bar sweep |
| `--blob=0\|1` | forces §2.11's building decal on or off regardless of `enabled_presets`, the same shape `--pad-shadows` has. The two arms differ in nothing else, so the `dc`, `prims` and `rs gpu` deltas ARE the layer |
| `--road-tint=K` | multiplies §2.1.2's carriageway tint by K in LINEAR and changes nothing else. `1.0` is byte-identical to a run without the flag. The arm behind the device-gated carriageway question, §2.1.2 |

`profile_frame` also prints a **BLOB SHADOWS** line on every run now, on or off, for the reason RR-83 gave: "zero on the other two presets" is half the claim and an unprinted half is a half nobody re-checks.

## 3. Data Schema

### 3.1 `data/render.json`
The single tunables file; full contents in §8.

### 3.2 `data/building_shapes.json` (generator input)

```json
{
  "schema_version": 1,
  "floor_height_m": 3.5, "tile_m": 8.0, "window_spacing_x_m": 3.2,
  "archetypes": [{
    "id": "res_highrise", "family": "residential", "footprint_tiles": [2, 2],
    "roof_signature": "setback_tower_mast",
    "levels": [
      { "level": 1, "floors": 12, "level_marker": "none",
        "blocks": [{"pos_t":[0.0,0.0], "size_t":[2.0,2.0], "base_floor":0, "floors":12, "window":"grid"}],
        "roof_props": [{"type":"box","pos_t":[0.65,0.65],"size_t":[0.7,0.7],"height_m":2.4}] },
      { "level": 4, "floors": 48, "level_marker": "crown_band_plus_masts",
        "blocks": [{"pos_t":[0.0,0.0], "size_t":[2.0,2.0], "base_floor":0,  "floors":30, "window":"grid"},
                   {"pos_t":[0.25,0.25],"size_t":[1.5,1.5],"base_floor":30, "floors":18, "window":"grid"}],
        "roof_props": [{"type":"box","pos_t":[0.5,0.5],"size_t":[0.5,0.5],"height_m":3.0},
                       {"type":"mast","pos_t":[0.4,0.4],"height_m":9.0},
                       {"type":"mast","pos_t":[1.1,1.1],"height_m":9.0}] }
    ]
  }]
}
```

Units: `pos_t`/`size_t` in **tiles** on XZ; block heights in **floors** (× `floor_height_m`); `roof_props` heights in **metres**. `base_floor` offsets a block vertically to form setbacks.

### 3.3 `game/meshes/generated/manifest.json` (generated, never hand-edited)

```json
{ "generated_from_hash": "<sha1 of building_shapes.json>", "generator_version": 3,
  "meshes": [ { "archetype": "res_highrise", "level": 4, "lod": 0,
    "path": "res://game/meshes/generated/res_highrise_L4_lod0.mesh",
    "tris": 288, "height_m": 177.0, "aabb": [16.0, 177.0, 16.0],
    "window_cols": 5, "window_rows": 48, "silhouette_descriptor": "0x4C3A91" } ] }
```

### 3.4 Save-file section — `render_prefs`

The renderer holds **no simulation state**; per the canonical save-section registry (report §11) `render_prefs` is **camera continuity only**.

```json
"render_prefs": { "section_version": 1, "camera_focus": [512.0, 0.0, 384.0],
                  "camera_zoom_t": 0.42, "camera_yaw_deg": 45.0 }
```

Three changes, all registry/ruling compliance:

- **`schema_version` → `section_version`.** Report C-25 rules `section_version` inside every section and `schema_version` only on the save envelope. Doc 11 is not named in C-25's amend list, but the rule is stated as universal and `render_prefs` is in the registry, so it is applied here rather than left as the one colliding key in the file. *(`data/render.json`'s top-level `schema_version` in §8 is a **data-file** version, not a save section, and is untouched.)*
- **`camera_zoom_s` → `camera_zoom_t`**, matching doc 12's `zoom_t ∈ [0,1]` (report C-63 puts the camera curve in doc 12's hands; the persisted parameter must carry doc 12's name). Default `0.42` is doc 12's default new-city zoom.
- **`last_overlay_mode` deleted.** The registry assigns overlay mode to doc 12's `ui` section ("camera, overlay, settings, onboarding"); it is not camera continuity. → see doc 12 §3.2.

Graphics preset is device-scoped, not city-scoped — `user://settings.cfg`:

```
[render]
preset="balanced"          ; performance|balanced|high
auto_detected=true
detected_t95_ms=17.4
render_scale_override=0.0  ; 0 = use preset
reduce_flashes=false
battery_saver=false        ; caps to 30 FPS and forces Performance
```

---

## 4. Sim API Sketch (renderer side)

| class | base | responsibility |
|---|---|---|
| `RenderBridge` | Node | drains sim events; owns the model; per-frame flush |
| `RenderStateModel` | **RefCounted** | all render bookkeeping + arithmetic; headless-testable |
| `ChunkView` | Node3D | one land block; owns MultiMeshes and buffer mirrors |
| `ChunkStreamer` | Node | tier assignment, build/teardown budget |
| `MeshLibraryCache` | RefCounted | loads generated `.mesh` by `(archetype, level, lod)` |
| `DayNightController` | Node | env keyframe interpolation, `sc_night`, sun transform |
| `WeatherView` | Node | particles, wetness integrator, lightning envelope |
| `LightPool` | Node3D | pooled `OmniLight3D` binding |
| `TrafficVisualizer` | Node | cosmetic civilian MultiMesh traffic |
| `VehicleView` | Node3D | one emergency/service vehicle, interpolated |
| `OverlayRenderer` | Node3D | `ImmediateMesh` network lines |
| `PerfGovernor` | **RefCounted** *(as shipped)* | p95 tracking, knob ladder, thermal ladder, `PERF` logcat line. Shipped as a model rather than a Node: it owns no timer and touches no engine singleton, so its 5 s and 30 s holds are driven in microseconds by `tests/test_perf_governor.gd` instead of being untestable. The shell feeds it `submit_frame(ms)` / `update(delta)` and routes `knobs()` to the four owners |
| `GrayboxGenerator` | `@tool` | `tools/gen_graybox.gd`, offline |

**Entry points**

```gdscript
RenderBridge.on_sim_tick(batch: Array, snapshot) -> void      # from SimHost, 4 Hz
RenderBridge._process(delta: float) -> void                   # interpolate + advance + flush
RenderBridge.pick_building(screen_pos: Vector2) -> int        # -1 if none
RenderStateModel.apply_event(e: Dictionary) -> void
RenderStateModel.advance(delta: float) -> void
RenderStateModel.lod_for(dist: float, cur_tier: int, dwell: float) -> int
RenderStateModel.apply_snapshot(snap) -> void                 # honours snap.is_resync (§2.7.6)
RenderStateModel.plan_blackout(block_id: int) -> void
RenderStateModel.plan_relight(block_id: int, restore_order: PackedInt32Array,
                              source_pos: Vector3) -> void    # order first, distance fallback
RenderStateModel.apply_governor(knobs: Dictionary) -> void    # §2.13 knob 3, clamped to the preset
RenderStateModel.tier_census() -> Dictionary                  # {near, medium, far, culled}
CityView.apply_governor(knobs: Dictionary) -> void            # + an immediate re-upload
CityView.perf_stats() -> Dictionary                           # the PERF line's counters

PerfGovernor.submit_frame(frame_ms: float) -> void            # every frame
PerfGovernor.update(delta: float) -> bool                     # true = a knob moved
PerfGovernor.knobs() -> Dictionary                            # {render_scale, particle_ratio,
                                                              #  far_cull_m, street_lights, preset}
PerfGovernor.set_thermal_status(status: int) -> void          # AndroidNative's signal
PerfGovernor.target_fps() -> int                              # doc 13 §2.8's frame cap
PerfGovernor.perf_line(t_s: float, stats: Dictionary) -> String
```

**Knob ownership.** Only `far_cull_m` lands inside this doc's own objects (`RenderStateModel` →
`raw_tier` → `CityView`'s culled chunks). The other three belong to their owners and the shell
routes them: `render_scale` to the 3D `SubViewport` (§5's C-69 ruling), `particle_ratio` to
`WeatherFX`'s `amount_ratio`, `street_lights` to `StreetlightView`'s omni pool, `preset` to whoever
holds the preset switch. The governor deliberately reaches into none of them.

**Commands issued inward:** none. The renderer is read-only. A pick resolves a building **id** via raycast against chunk AABBs + footprint tiles and hands it to `ui/`, which issues the command.

**Events consumed:** `building_placed`, `building_upgraded`, `building_removed`, `building_construction_stage`, `building_damage_changed`, `building_power_changed`, **`BlockDarkChanged{block_id, block_dark, powered_fraction, restore_order}`** *(report RR-1: renamed from `DistrictDarkChanged`; doc 04 §4 is the emitter and owns the name)*, `block_development_changed`, `road_network_changed`, `network_topology_changed`, `vehicle_spawned`, **`traffic_snapshot`** *(doc 91 D-10: the packed civilian pose event that replaced per-vehicle `vehicle_state`; doc 06's emergency fleet still arrives as the `vehicle_states()` snapshot, not on the bus)*, `vehicle_despawned`, `weather_changed{precip01, …}`, `lightning_strike`.

**Events emitted outward** (to `ui/`, and to `game/audio/` from Phase 2 — report G-3): `render_relight_started(block_id, duration_s)`, `render_relight_peak(block_id)`, `render_blackout_started(block_id)`, `render_lightning_flash(world_pos, magnitude)`, `render_preset_changed(preset)`, `render_governor_stepped(knob, direction)`, `render_chunk_ready(bx, by)`. *(The `district_id` parameter is renamed `block_id` throughout, per report C-38: the renderer's unit is the land block, and it is the same integer it always was.)*

---

## 5. Cross-System Interfaces

**Doc 01 — time & ticks.** `snapshot.sim_time_minutes: int`, `snapshot.tick: int`, and an `accum` from `SimHost` so `alpha = accum / 0.25`. The render side reads no wall clock either — the day/night curve is driven by sim time only. Doc 01 exposes a fixed daylight curve (sunrise 06:00 / sunset 19:00, `season_index` reserved); §2.8's `sc_night` keys are authored *independently* of that curve because window-lighting timing is an art decision, not an astronomical one — see §9 conflict 11.

**Doc 02 — buildings, upgrades & construction.** `query_buildings_in_block(bx,by) -> Array[BuildingView]` exposing exactly `id, archetype_id, level, tile, footprint, rotation_quarter, powered, has_backup_power, priority_load, occ_b, damage, condition, construction_stage, overlay_state`. `condition ∈ [0,1]` per report C-14 — §2.7.1's `condition < 0.15` gate reads that scale directly. **Settled (report C-66):** doc 02 supplies only the slow structural `occ_b` (its `OCCUPANCY_RAMP_HOURS = 36` ramp) and changes nothing; **this doc owns `occupancy_hour_curve` per building family** in `data/render.json` and multiplies the two in §2.7.1. The curve is art, not simulation — it is never a sim input, adds no save state, and doc 02 does not need to know it exists. Former §9 conflict 6 is closed.

**Doc 03 — economy, taxes & land market.** No direct interface. Referenced only by §9 open question 19 (window colour as a cosmetic-theme surface).

**Doc 04 — electrical grid.** The critical one, and now fully settled by report 98.

*Doc 04 provides exactly what the renderer needs, per **land block** — which is the render chunk (constitution §6), so no remapping is required:* **`block_dark`** (report C-38: renamed from `district_dark`; set when ≥60% of a block's buildings, weighted by population + jobs, are DARK), `outage_duration_gm`, `power_reliability`. "District" is now doc 09's 1–4-block aggregate and the renderer never consumes it. §2.7 is written against the block flag.

*Events consumed:* **`BlockDarkChanged(block_id, block_dark, powered_fraction, restore_order)`** → §2.7.2 / §2.7.3 *(report RR-1: the carrier is renamed with the flag; doc 04 emits `BlockDarkChanged` and its test 23 asserts `DistrictDarkChanged` is never emitted, so the old subscription was dead wire)*; `BuildingPowerChanged(building_id, state)` → per-building emissive target; `StreetlightsChanged(block_id, lit)` → §2.10; `TrafficSignalPowerChanged(intersection_id, powered)` → signal-head emissive; `PowerRestored`, `AutoReclosedOK`, `AutoRecloseLockout` → momentary-outage classification (§2.7.5); `TotalBlackout` → citywide sequence (§2.7.5); `LoadShedStarted/Ended`, `RollingBlackoutRotated` → fractional path (§2.7.4).

*Debounce is doc 04's job, not mine.* Doc 04's service hysteresis (`dark_threshold_frac 0.35 / dark_hold_gs 20`, `lit_threshold_frac 0.55 / lit_hold_gs 10`) guarantees no event for interruptions under 20 game-seconds (0.33 real s), and its own test asserts "a 15-gs interruption causes no flicker". The renderer therefore trusts every `BlockDarkChanged` it receives and adds no debounce of its own — one filter, one owner.

**`restore_order` on restoration — RESOLVED (report C-39, ruled).** Doc 04 adds `restore_order: PackedInt32Array` to the restoration event: the buildings in the order its energization DFS re-energized them. It falls out of that DFS for free and is strictly better than a `source_pos`, because it follows real restoration priority rather than a straight-line guess. §2.7.3 consumes the ordering as its primary path and keeps the distance sweep as a fallback for events that lack it. This was the renderer's highest-risk cross-doc dependency; it is closed.

**`powered_fraction` from day one — RESOLVED (report C-39, ruled).** Doc 04 carries the fraction on the event even while its service model is binary, so load-shed tiers (§2.7.4) need no later schema change.

**`momentary_outage_s` coupling — RECORDED (report C-40).** §2.7.5's threshold is derived from doc 04's `auto_reclose_delay_gs` and `auto_reclose_max_attempts`, not chosen; test 24 asserts the inequality across both data files, and doc 04 carries a comment on the coupling.

**Doc 05 — water system.** `network_topology_changed{layer:"water"}` and `get_water_polylines(bx,by)` for overlays. Water state never drives emissive state — a water failure does not darken a block.

**Doc 06 — incidents, dispatch & emergency fleets.** `vehicle_state{id, kind, pos: Vector3, heading: float, speed: float, siren: bool, lightbar: bool}` at 4 Hz for emergency/service vehicles only, plus spawn/despawn. **RESOLVED (report C-67, ruled):** `speed` and `heading` are separate explicit fields — the Hermite interpolation in §2.12 needs a velocity term, and deriving it from consecutive positions doubles the visible latency. Incident markers themselves (fire plumes, crime pips) are drawn from `incident_started/escalated/resolved`; the renderer needs only `{id, type, world_pos, severity}`.

**Doc 07 — weather & Disaster Director.** `weather_changed{type, precip01: float, wind: Vector2, fog: float, temp_c: float}` and `lightning_strike{world_pos, magnitude}`. **RESOLVED (report C-58, ruled):** doc 07 publishes `precip01 = clamp(precip_mm_h / 35.0, 0, 1)`, continuous across segment boundaries by lerping the last 60 game-seconds of a segment into the next. §2.9 consumes `precip01` and nothing else. **Also resolved (report C-59):** weather state is **city-wide global**; only the `THUNDERSTORM` storm cell is spatial, and it affects lightning targeting and flood accumulation, not the global effect channels. There is no second weather region and therefore no boundary popping — former §9 conflict 12 is closed.

**Doc 08 — persistence, offline & notifications.** Owns `render_prefs` round-tripping (§3.4) and its migration ladder, and **validates** `tests/fixtures/bench_city.json` against the current save schema in CI (report G-7). **RESOLVED (report C-68, ruled):** doc 08 flags the first post-catch-up snapshot `is_resync: true`, and §2.7.6 snaps emissive state instead of animating — otherwise a 12-real-hour absence (720 game-hours per report C-19) would replay a 3.15 s relight for every block that changed while the app was closed.

**Doc 09 — map, land, districts, population & stability, starter city.** `get_block_terrain(bx,by) -> PackedFloat32Array` (9×9 height samples, metres); `development_state` per block, using doc 09's eight-state ladder `UNDEVELOPED → SURVEY → CLEARING → GRADING → ROADS → UTILITY_CORRIDOR → FINAL → READY`, plus `block_road_access_score ∈ {NONE, STUB, EDGE, ARTERIAL}` (renamed per report C-61 to keep it distinct from doc 10's tile-level `access_quality`); event `block_development_changed{bx, by, state}`. Ground material is keyed off the state (scrub → cleared dirt → graded pad → paved), and the `ROADS` transition is when a chunk gains its road surface mesh. Doc 09's `buildable_tiles = 169` and `road_tiles_est = 87` per flat clean block (report C-60 confirms doc 09 owns the block road template) are the numbers §2.2's `max_instances_per_bucket = 256` and §2.10's ~22 streetlights/block are sized against. **Doc 09 also generates `tests/fixtures/bench_city.json`** via `tools/gen_bench_city.py` (report G-7).

**Doc 10 — roads, routing & traffic.** `get_road_polylines(bx,by) -> Array[PackedVector3Array]` (centreline, world space, per-vertex `width_m`), `get_edge_density(edge_id) -> float` (per-edge congestion, exposed in the slice — this is the input §2.12's cosmetic traffic runs on), `road_network_changed{bx,by}`. Road classes are doc 10's `AVENUE` (block-boundary) / `STREET` (interior collector and player-placed) per report C-60. **Ask:** confirm streetlight anchors are renderer-derived at 32 m spacing along polylines (preferred — streetlights then are not sim entities) rather than sim-owned.

**Doc 12 — UI/UX, camera input & onboarding.** Doc 12 sets `sc_overlay_mode` and supplies `sc_overlay_colors` for exactly **four** building overlay states (report C-64: `SELECTED` is a `MarkerLayer` outline on the UI layer, never a per-instance state); this doc guarantees the shaders honour them and that line meshes rebuild on topology change. Doc 12 owns the graphics-settings screen; this doc supplies the preset list and knob semantics. **Three handshakes, all ruled:**
- **Camera split — RULED (report C-63).** Doc 12 owns camera *state, input and interaction range* (pan/pinch/rotate gestures, focus targets, `focus_on`/`frame_district`, `D_MIN 18`, `D_MAX 420`, `D_MAX_eff`, `pitch 34°→62°`, the `D(t)`/`pitch(t)` curves). This doc owns the camera *node, projection, culling and the LOD driven by them* (`FOV 40°`, `near 1`, `far 1600`) — the draw-call budget in §2.13 is computed against those. **Both halves live in one file, `data/render.json` §8**, and `data/ui.json` references those rows rather than restating them; doc 12's earlier `FOV 45 / near 1 / far 2000` is superseded. The runtime contract is one struct: doc 12 writes `{focus: Vector3, zoom_t: float, yaw_deg: float}` into `CameraRig` each frame; `CameraRig` derives `D`, pitch and the transform from §2.5 and never reads input.
- **Stretch mode — RULED (report C-69, agreement recorded).** Doc 12 needs `content_scale_mode = disabled` + `content_scale_factor` for dp-exact 48 dp touch targets. 3D is rendered to a `SubViewport` sized `viewport_px * render_scale` with its own `Camera3D`, composited under the UI `CanvasLayer`. This decouples §2.13's `render_scale` from UI scale entirely; it is how `render_scale` must be implemented regardless. No conflict remains.
- **Overlay content vs mechanism.** Unchanged: doc 12 owns which layers exist and what they mean, this doc owns `sc_overlay_mode`, the shader branch and the `ImmediateMesh` line budget.

**Doc 13 — Android integration & export.** On `NOTIFICATION_APPLICATION_PAUSED` the renderer sets `Engine.max_fps = 0`, stops particle emission, and releases the reflection probe. On `NOTIFICATION_OS_MEMORY_WARNING` (doc 13 routes it here) the renderer tears every chunk below `MEDIUM` down to `SIM_ONLY`, clears `MeshLibraryCache` LOD0 entries, and drops `far_cull_m` by one governor step — recovering ~40% of VRAM in one frame. **Audio is not doc 13's** (report G-3): it is this doc's, from Phase 2, per §2.15 — doc 13 provides the platform audio session and nothing else.

---

## 6. MVP Cut (vertical slice, spec §43)

**In the slice.**

- Chunk scene architecture, `ChunkView`, streaming, slot allocator (§2.1–2.2).
- `RenderBridge` + `RenderStateModel` with the full event set (§2.3).
- MultiMesh building rendering with the 4-channel custom data contract (§2.6) — the contract must be right from day one because everything else keys off it.
- All three LOD tiers (§2.5). FAR is not optional: it is what makes Z2 cheap.
- **The complete blackout / relight system (§2.7), including the brownout stutter, the distance-swept relight, and the inrush overshoot.** This is the thesis of the game; it ships in the slice or the slice does not prove the thesis.
- Streetlights: poles + lamp billboards + fake light pools + the small omni pool (§2.10).
- Day/night with the 6-key gradient, AgX tonemapping, depth fog, glow (§2.8).
- Rain + splash + wetness integrator + wet-ground roughness and smear instances; lightning sky flash (§2.9). Thunderstorm is the MVP disaster (spec §43.4), so its VFX is slice content.
- Civilian MultiMesh traffic + individual emergency vehicles with light bars and Hermite interpolation (§2.12).
- Gray-box generator for the **12 MVP archetypes** (spec §43.2) × 5 levels × 2 LODs, with baked AO, UV2 window grids, and the silhouette descriptor test (§2.14).
- `PerfGovernor`, the `PERF` logcat line, and the adb bench harness (§7.4).
- Overlay shader mode + power-network line rendering (§2.11) — power overlay only.

**Deferred.**

- Snow / blizzard / fog-weather VFX (only the fog profile table lands; snow particles wait for the weather expansion).
- `ReflectionProbe` on High (§2.9 trick 3) — gated behind on-device validation.
- ~~Construction-site props (cranes, fencing, partial frames) beyond a single scaffold box driven by `construction_stage`. Spec §12.3's six-stage visualisation is Phase 2.~~ **Amended 2026-08-18 (user directive): pulled forward and shipped — six-stage shader growth (`building.gdshader` vertex clamp + concrete shell), `ConstructionSiteView` hoarding/crane/scaffold props, `building_construction_stage` sim events.**
- The remaining 3 archetypes (`ind_warehouse` variants, `civ_school`, `civ_stadium` detail) and all post-launch archetypes.
- Water / police / fire / traffic / construction overlay line layers (mechanism ships, layers are doc 12's Phase 2).
- Decorative pedestrians (spec §29.1 explicitly allows them as visual-only; not slice content). **Still deferred, and §2.17 is not it — annotated 2026-08-21 (doc 91 §20.6's marker sweep).** STREET LIFE puts *characters* on the footway from Wave 14 on, and a reader who meets this line afterwards will reasonably wonder whether it went stale. It did not, and the distinction is the whole design: §2.17's bodies are **one per live `sim/street` opportunity** — a crook, a stray, a goat — each with an id, a bounty and a lifetime the sim owns, and the layer draws **zero** when the roster is empty (RR-83: `node.visible = n > 0`). A decorative pedestrian is ambient population with no sim behind it, costs a draw call whether or not anything is happening, and remains post-MVP. *(This is the §20.5 rule applied in the direction it is usually not: a stale OPEN makes finished work look unfinished, a stale DEFERRED makes finished work look untaken — and a deferred line that a NEW feature merely resembles wants a sentence saying so before someone strikes it by mistake.)*
- Boot auto-detect (§2.13). **Slice ships Balanced only**, hard-coded, with a manual preset switcher for profiling. The preset *table* and the governor ship; the detection benchmark does not.
- Cosmetic city themes / window-colour reskins (§9 open question 19).
- Vehicle headlight cone projection onto road surfaces beyond the additive quad.
- ~~**All audio. MVP ships silent** — owned by this doc from Phase 2 per report G-3 (§2.15). What ships in the slice is the *event hooks* with correct timing (`render_relight_started/peak`, `render_blackout_started`, `render_lightning_flash`), so Phase 2 is a mix pass and not a re-architecture.~~ **Amended 2026-08-19: pulled forward and shipped** — `game/audio/` (`AudioConfig`, `AudioEvents`, `AudioService`), `data/audio.json`, a procedural asset set from `tools/gen_audio.py`, and `tests/test_audio_model.gd`. §2.15 below is now description, not plan. The Phase-2 prediction held: it was a mix pass, and the hooks needed no change.
- Sub-block ground darkening from doc 04's per-tile dark mask (§9 item 5) — polish, nothing depends on it.

**Slice acceptance:** scenario S3 in §7.4 (20:00 thunderstorm, scripted 4-block blackout at t=45 s, relight at t=65 s) runs on a Pixel 6 at Balanced within the §7.4 gates, and the blackout/relight is legible at Z0, Z1 and Z2 without an overlay.

---

## 7. Test Plan

### 7.1 Headless — gray-box generator (`tests/test_graybox_gen.gd`)

1. **Determinism:** two generations from identical input yield byte-identical `.mesh` files.
2. **Coverage:** every archetype produces exactly 5 levels × 2 LODs; manifest entries match files on disk.
3. **Height formula:** `manifest.height_m == floors·3.5 + roof_extra_m` for all entries (±0.01).
4. **Tri budget:** LOD0 ≤ 320 (≤ 420 for the three tall archetypes); LOD1 ≤ 96 **and** ≤ 0.40 × LOD0.
5. **UV2 rule:** every vertex with `|normal.y| > 0.5` has `UV2 == (-1,-1)`; every vertex with `|normal.y| < 0.2` on a `window:"grid"` block has `UV2 ∈ [0,1]²`; `tech_datacenter` has zero valid-UV2 vertices.
6. **AO bake:** every façade-bearing mesh has ≥1 vertex with `COLOR.r ≤ 0.60` and no vertex with `COLOR.r > 1.0`.
7. **Silhouette uniqueness:** pairwise descriptor Hamming distance ≥ 4 across archetypes at equal level, ≥ 2 across levels within an archetype. This is the automated form of constitution §11.

### 7.2 Headless — `RenderStateModel` (`tests/test_render_state.gd`)

8. **LOD banding + hysteresis:** drive `d = 100 → 160 → 145 → 200` with `dwell 0.5`; assert the exact tier sequence NEAR, NEAR (160 < 150+20), NEAR, MEDIUM — no oscillation.
9. **Emissive target formula:** the five rows of §2.7.1 reproduce exactly with `occ_b = 0.92` and the §8 residential curve — **`0.9640, 0.5997, 0.05, 0.22, 0.035`** (±1e-4). *(Recomputed from `0.955, 0.708, …` per report C-66: the curve, not a hand-picked `occ`, now supplies the hourly term.)*
9b. **Occupancy curve:** every family curve in §8 `occupancy_hour_curve` is continuous across the 24 h wrap (|Δ| < 0.05 at the seam), stays in `[0,1]`, and `tech` is flat within 1e-6. Residential is strictly greater at 21:00 than at 12:00 and at 03:00 (the "breathes" ordering), and commercial is the reverse at 13:00 vs 03:00.
10. **Lit-window count:** with `cols=5, rows=48`, four façades, `e = 0.05`, the count of cells with `hash21(cell) > 0.95` falls in `[38, 58]` (statistical band on 960 cells) and is **identical** across two independent evaluations.
11. **Blackout timeline:** `powered_fraction = 0` at t=0, advance in 1/60 s steps; every building within 1% of target by t = 1.25 s, and **block**-mean `emissive_cur` at t = 0.10 s is < 0.25 of its t=0 value (the stutter fired).
12. **Relight ordering (primary path, `restore_order`):** 28 buildings, `restore_order` a known permutation, jitter zeroed → `delay_i` monotonically non-decreasing in rank `k_i`; `delay(k=0) == 0.0`, `delay(k=9) == 2.2·9/27 == 0.733 s ±1e-3`, `delay(k=27) == 2.200 s` exactly; streetlight delays are exactly `0.80 ×` the delay of their nearest building. Rank order is honoured even when it *contradicts* distance order (feed the permutation reversed relative to geometry and assert the delays follow the ranks, not the metres) — that is the whole point of report C-39.
12b. **Relight ordering (fallback path, distance):** the same 28 buildings with `restore_order` empty → falls back to §2.7.3's radial form, `delay_i` monotonically non-decreasing in `d_i`, farthest delay == 2.2 s. With both `restore_order` and `source_pos` absent, falls back to the block centroid and still terminates at 2.2 s.
13. **Overshoot:** peak `emissive_cur` during relight is `1.35 × target` ±1% at `t = delay + 0.15 s`, settling to target ±1% by `t = delay + 0.45 s`.
14. **Momentary vs sustained classification (§2.7.5), recomputed at `momentary_outage_s = 4.50`:** a dark→lit pair **1.5 s** apart (reclose succeeds on attempt 1) plays the stutter + ramp only — assert no sweep delay is scheduled and the block is fully lit by t = 0.85 s. A pair **3.0 s** apart (reclose succeeds on attempt 2) is also momentary — this case was mis-classified as sustained under the old 2.50 s constant. A pair **11.0 s** apart (lockout → crew) plays the full ceremony — assert the last-ranked building's delay == 2.2 s. A pair 6.0 s apart is sustained. Boundary at **4.50 s** exactly classifies as momentary.
15. **Partial-outage stability:** with `powered_fraction = 0.4` the dark set is identical across 100 re-evaluations; every `priority_load` building stays lit.
16. **Slot allocator:** place 100, remove 40 in random order, place 40 more → `visible_instance_count == 100`, no duplicate slots, `slot_owner` consistent, no stale transforms below `visible_instance_count`.
17. **Custom-data packing:** round-trip all `16 × 7 × 4 = 448` `(variant, stage, overlay)` combinations with exact integer recovery.
18. **Dirty-flush budget:** dirty 5,000 instances in one tick with a 2,000/frame budget → exactly 3 frames to drain, flush order ascending by chunk distance.
19. **Draw-call prediction (recomputed, reports R-17, RR-12 and RR-14):** load `tests/fixtures/bench_city.json` (generated by doc 09, validated by doc 08 — report G-7), run tier assignment at the three §2.5 poses, assert predicted draw-call totals against §2.13's re-derivation:

    | pose | `D` / pitch | chunks | tolerance | tiers | predicted total (Balanced) | budget |
    |---|---|---|---|---|---|---|
    | Z0 | 18 m / 34° | 4 | ±10% | 4 NEAR | 157 | 320 |
    | Z1 | 86.9 m / 48° | 6 | ±10% | 6 NEAR (worst case) | 215 | 320 |
    | Z2 | 420 m / 62° | **16** | **+3 / −0 chunks (16–19)** | **10 MEDIUM + 6 FAR** | **159** (accept 159–182) | 320 |

    *Recomputed per report RR-14: the columns are the pure ceiling `⌈W/128⌉` = `⌈4.167⌉ / ⌈4.874⌉ / ⌈5.603⌉` = **5 / 5 / 6** = 16 chunks, opaque `10·10 + 6·3 = 118`, total `118 + 41 = 159` (165 with overlays). The previous 17-chunk / 169-call expectation rounded row B's 4.874 up to 6 by judgement, double-counting the misalignment case that the tolerance band already carries. (RR-12 before it had removed a phantom fourth chunk row at `r = 412` m: rows originate at 52.1 / 180 / 308 m and the next would start at 436 m, beyond `r_far = 411.8 m`.)*

    ***Z2's tolerance is asymmetric `+3 / −0` rather than ±10% or ±2***, because the residual spread is grid alignment, not measurement noise, and 16 is the **minimum** of that spread: the view axis landing on a column boundary rather than a column centre can add at most one column to each of the three rows, giving the hard band `16 … 19` (159 … 182 calls). Fewer than 16 chunks at Z2 is not a favourable alignment — it is a culling bug, and the test must fail on it.

    Also assert **zero NEAR chunks at Z2** (the shadow pass must be empty — it is what makes the densest pose affordable), **exactly three occupied chunk rows at Z2** (the phantom-row regression guard: assert no chunk with nearest-edge `r ≥ 436` m is tier-assigned at Z2), **that every row's column count equals `⌈W_far_of_row/128⌉` at the best alignment** (the RR-14 rounding guard: row B must resolve to 5 columns, never 6, when the view axis is placed on a column centre), and that no pose exceeds its preset's `draw_call_budget` on Performance or High. **This is the budget regression test** and it runs on every commit.
19a. **The streetlight lifecycle (§2.10.1, 2026-08-20).** `remove_streetlight` retires the record and takes the id off `BlockRec.streetlights`; an unknown id is a no-op; the retired lamp reads exactly 0 through a block go-dark that the surviving lamp ramps through, which is the proof it is no longer TICKED. And the hazard the re-place pass would otherwise have shipped: registering one id three times leaves **one** record and **one** roster entry, keeps the lamp's `anim_phase`, moves its position, and — when the block changes — leaves exactly one roster carrying it. The duplicate is invisible to a count and visible only as a lamp whose blackout stutters twice.
19b. **LOD-distance rule:** tier assignment uses the chunk's ground-plane AABB. Place a 217 m `res_highrise` in the chunk directly under the Z2 camera and assert the chunk still tiers **MEDIUM** — the building-inclusive AABB would give `sqrt(52² + (370.8−217)²) = 162 m` and wrongly promote it to NEAR, re-arming the shadow pass at max zoom.

19c. **The MEDIUM bucket merge (`tests/test_render_merge.gd`, doc 91 D-14).** Twenty tests over §2.6's merge, in six groups:

  * **The packing cannot move.** All 448 combinations of `(variant, stage, overlay_state)` crossed with all five levels: `mod(p,16)`, `mod(floor(p/16),7)` and `mod(floor(p/112),4)` must return exactly what they returned before `+448·level` was added, and `floor(p/448)` must return the level. Plus the bound: `447 + 448·5 = 2687 < 2²⁴`, so the whole space is exact in the f32 the channel actually is. **This is the test that makes 448 a fact instead of an argument**, and any future field added to `.b` has to come back through it.
  * **The merge merges.** A MEDIUM chunk holding six `(archetype, level)` buckets over two archetypes submits **two** MultiMeshes; the per-level nodes go dark; `medium_merge_enabled = false` brings all six back; a NEAR chunk is untouched either way.
  * **The merged buffer is the mirror.** Float-by-float against `RenderStateModel`'s own bucket mirrors — every channel identical, `.b` differing by exactly `448·level`. Plus the blackout carry-over (a merged instance's `.r` is the model's ramp, copied not derived) and the overlay decode (one OFFLINE building inside a merged buffer still reads OFFLINE, and its neighbours still read NORMAL).
  * **The atlas.** `COLOR.a` decodes to the levels the mask asked for and to no others; a one-level mask is the level's own mesh vertex for vertex (so a chunk with one level pays nothing for the merge); UV2 façades are scaled by `(cols, rows)` and the `(-1,-1)` / `(-1,-2)` sentinels are copied verbatim — checked specifically on `data_center`, whose `cols = 0` would multiply a sentinel to `(0,0)` and light a blank wall; `level_build_height[]` matches the manifest per level.
  * **§2.5's MEDIUM row.** Every merged node has `cast_shadow = OFF`, `near_flicker = 0`, `level_atlas = 1` and `window_cols = 1`; two chunks drawing the same archetype share **one** `ShaderMaterial`. And the shader source contract: `level_atlas` defaults to 0, the gate is branchless (`step(0.5, level_atlas)`), `overlay_of` wraps rather than clamps, and nothing in the file `discard`s.
  * **The mask at runtime** — the only mutable state the merged tier has, and the one whose failure is silent. A chunk that GAINS a level swaps to the wider atlas (without the swap the new building draws nothing and reports nothing), still on one draw call, with each instance carrying its own level; a chunk that LOSES one swaps back to the narrower atlas, so a demolished level stops submitting triangles; and a chunk that loses its last building submits **zero** calls — neither the merged node nor the emptied per-level bucket behind it.

### 7.2b Headless — the street (`tests/test_road_surface.gd`)

17 tests over `RoadSurfaceView`, `StreetlightPlacer` and `CobraHeadMesh`, on fixture road graphs and on the founding city. Every one is an INVARIANT of the picture rather than a snapshot of it — dash length, gutter width and tints live in `data/render.json` and are deliberately not asserted, because moving them is art and moving these is a bug. The three that would actually break the player's read:

1. **A centre line through a junction box** (tests 03, 05) — the whole reason the pass reads the graph is that a 4-way looks like a 4-way, and that a leg is only zebra'd when what it leads to is not another junction tile.
2. **A kerb down the middle of a 16 m avenue** (test 04) — the dual-carriageway pairing, including the mis-classed crossing tile that broke it.
3. **A lamp in a traffic lane** (test 12) — every pole in the founding city stands on a footway, on a side that carries one, inside the kerb; test 13 that its arm points at the roadway.

Also pinned: the two files' shared N/E/S/W wire format (01), that the carriageway's top surface is still y = 0.10 where the vehicle layer expects it (02), footway run merging (06) and that no two footway boxes overlap in plan (07), water taking no kerb (08), that the pass never mutates the graph and is byte-identical across two builds (09), the corridor pitch and kerb alternation (10), the dual-carriageway stagger (11), the corner rule and the junction guarantee (14, 14b), the cobra head's 76 triangles and overhang (15), STREET-1's pool clearing the carriageway and hanging off the luminaire (16), and the repeat-rebuild guard (17).

**18 and 18b — the live re-place (§2.10.1, 2026-08-20).** Extending a lit corridor by twelve tiles adds lamps, retires only the old cul-de-sac head's corner lamp, and leaves **every other lamp's id and position untouched** — the assertion that says a road edit does not restart the whole city's ramps. The model's roster is checked to match the view's on both sides of the edit. 18b pins the two properties the shell depends on: a re-place that changes nothing reports all-`kept` and touches no buffer, and the boot pass numbers its lamps **exactly** as `StreetlightPlacer.place()` does, so the diff existing moved no `anim_phase` in any city that was already running.

**Note for anyone extending it:** `--headless` runs on the DUMMY rendering driver, where `MultiMesh.get_instance_transform` reads back identity whatever was uploaded. Both views publish their computed placements script-side (`RoadSurfaceView.pack_of/runs/asphalt_origin_y`, `StreetlightView.anchor_of`) for exactly this reason; asserting against the MultiMesh directly silently passes.

### 7.3 Headless — weather / day-night

20. **Wetness integrator:** `precip01 = 1.0` for 60 s → `sc_wetness ≥ 0.90`; then `precip01 = 0` for 300 s → `≤ 0.05`; monotonic within each phase. Also assert continuity: stepping `precip01` through doc 07's segment-boundary lerp produces no `|Δ sc_wetness|` above `delta/tau` in any frame — the C-58 guarantee the renderer depends on.
21. **Lightning envelope:** sampled at 240 Hz — exactly two local maxima, peak 1.0 at t = 0.02, 0.0 at t ≥ 0.30, never exceeds 1.0.
22. **Day/night curve:** `sc_night(hour)` continuous across the 24 h wrap (|Δ| < 0.02 at the seam), 0.00 at 12:00, 1.00 at 00:00, ≥ 0.30 by 18:15.
23. **Fog invariant:** for every weather × time × preset combination **and every governor knob position**, the *effective* fog range obeys `fog_depth_end_eff ≤ far_cull_m` and `fog_depth_begin_eff < fog_depth_end_eff` after §2.8's clamp. Assert the clamp actually fires on Performance (`clear_day` authored 1200 vs `far_cull 900`) rather than being masked by authoring.

### 7.3e Headless — STANDING WATER (`tests/test_flood_view.gd`, §2.9b)

Fifteen tests over `FloodView`. The pixels are not testable headless and are not where the bugs live; every claim §2.9b makes about the picture is.

36. **Doc 07's payload, verbatim.** `flood_level_changed{cell, is_block, depth_mm, band, road_speed_mult}` is claimed and `weather_changed` / `road_closed_flood` are not — the rain integrator stays `WeatherFX`'s and the closure stays doc 10's story. 175 mm resolves to `water01 = 0.50`.
37. **The divisor is read, not restated.** `full_depth_mm` equals the LAST row of `data/weather.json`'s `flood.thresholds` — which is the 350 mm `FloodField.flood_saturation()` divides by. Cross-file, so doc 07 moving its band table moves the picture with it.
38. **The easing is asymmetric.** One rise tau gets ~63 % of the way up; the same wall-clock second on the way down buys measurably less. And **the dark-wet memory outlives the water**: twelve seconds after the water is set to zero, `water01 < 0.02` while `wet01 > 0.50` and the tiles are still in the buffer.
39. **Dry costs nothing.** No water → 0 instances, 0 draw calls, node hidden. Water → exactly **1** draw call whatever the tile count. Fully dry again → the buffer empties.
40. **It paints the block's ROAD tiles.** A 2×2 toy grid with 31 road tiles inside `B0,0` draws 31, not the block's 256. A cell with no roads under it yet tracks its level and draws nothing.
41. **Two identical runs produce a byte-identical buffer**, and `.b`/`.a` are zero in every slot — the assertion that keeps a per-tile term (and the tile lattice it draws) out of this surface.
42. **A loaded save mid-flood shows the flood.** `prime()` off `FloodField.depth_mm` + `snap()` puts the water at its real depth on the first frame with **no event consumed**; a cell the field no longer mentions drains rather than standing (`FloodField` erases a cell that clamps to zero, so absent means dry).
43. **The preset ladder moves the fragment ceiling** — Performance 0, High 2 — and `set_detail` may lower it and never raise it.
44. **A settled flood re-uploads nothing.** 200 frames of easing, then 60 more, and `uploads` does not move.

### 7.3f Headless — THE EVENT MATRIX (`tests/test_event_matrix.gd`, doc 91 §18, doc 93's event ruling)

Six tests, and the ruling they hold is *every event whose payload describes a player-visible state change has a consumer or a written exemption; everything else carries a one-line classification.* The register lives in the test.

45. **Zero unexplained rows.** Every type `sim/` emits is either consumed by `game/`, `ui/`, doc 09's goal system or one of the two data routers, or has a `REGISTER` row naming one of seven classifications and giving a reason. 138 types at this fork: 78 consumed, 60 classified.
46. **The register cannot rot** — in both directions. A row naming an event `sim/` no longer emits fails; so does a row for an event that has since acquired a consumer, because an exemption that has stopped being true is a line of prose nobody re-read.
47. **A classification is a word and a reason.** The word must be one of `covered` / `player_initiated` / `bookkeeping` / `invisible_by_design` / `measurement` / `unreachable` / `not_an_event`, and the reason must be more than a shrug.
48. **Every type the routers name is emitted.** Test 27 held this for doc 04's slice; this holds it for `data/ui.json.event_log.events` and `data/notifications.json.bindings` whole — §18.2's "cheap next step". It is the one assertion here that fails CLOSED, and it is the RR-1 failure mode: copy wired to an event nobody sends renders as silence.
49. **The flood is wired end to end**, and is not sitting in the exemption register — A91-D-26, held down.

> **What this suite deliberately does not claim.** The emit scan is a regex over source and **fails open**: `bus.emit(kind_variable, …)` is invisible to it, exactly as §18.3 says. The consumer scan is generous in the other direction — any literal of the right shape in a live file counts. Both are the right way round for a gate whose job is to stop dead wires: a false "wired" is a missing test, a false "dead" is a stalled commit. Test 48 is the one that fails closed and it is the one that catches a router pointed at nothing.

### 7.3b Headless — cross-file assertions (report C-40, G-7)

These read two or more files and fail the build when a sibling doc's data drifts.

24. **`momentary_outage_s` floor (report C-40).** Load `data/render.json` and `data/power.json` and assert:

    ```
    render.blackout.momentary_outage_s
        >= 1.5 * (power.protection.auto_reclose_delay_gs / 60.0)
                * power.protection.auto_reclose_max_attempts
    ```

    Against today's values: `1.5 × (90/60) × 2 = 4.50` and `momentary_outage_s = 4.50` → passes at equality. Also assert the classification is still *below* the shortest crew-driven restoration, `2 × (auto_reclose_delay_gs/60) + manual_reclose_gm ≥ momentary_outage_s + 1.0` (`3.0 + 4.0 = 7.0 ≥ 5.5` ✓), so the two populations cannot merge. If doc 04 retunes the reclose interval or attempt count, this test fails loudly instead of the renderer silently playing the wrong ceremony.
25. **Resync snaps, never animates (report C-68).** Feed `RenderStateModel` a `BlockDarkChanged` event, then a snapshot with `is_resync: true` in which the block is powered. Assert: every `emissive_cur == emissive_target` on the *same* frame (no ramp), zero queued relight plans, and **no** `render_relight_started` / `render_relight_peak` / `render_blackout_started` emitted. Then feed a normal (non-resync) restoration and assert the full 3.15 s ceremony *does* schedule — the suppression must be scoped to the resync snapshot only.
26. **Bench fixture contract (report G-7).** `tests/fixtures/bench_city.json` exists, parses, and carries the save-schema version the current migration ladder terminates at; every `archetype_id` in it resolves in `game/meshes/generated/manifest.json`. This doc **consumes** the fixture; doc 09 generates it via `tools/gen_bench_city.py`; doc 08 validates it against the save schema in CI. This test is the renderer's own tripwire so the §7.4 acceptance gates cannot silently stop running against a stale city.
27. **Consumed-event names exist on the emitter (report RR-1).** For every event name in §4's *Events consumed* list that doc 04 owns — `BlockDarkChanged`, `BuildingPowerChanged`, `StreetlightsChanged`, `TrafficSignalPowerChanged`, `PowerRestored`, `AutoReclosedOK`, `AutoRecloseLockout`, `TotalBlackout`, `LoadShedStarted/Ended`, `RollingBlackoutRotated` — assert the name is present in the grid system's emitted-event registry, and assert **`DistrictDarkChanged` is subscribed by nothing**. This is the test whose absence let the C-38 rename land on doc 04's side only: doc 04's test 23 asserted it never emits the old name, doc 11's tests were fed synthetic events, and the dead wire between them was invisible to both suites. A subscription to a name no doc emits must fail the build, not fail silently at runtime.

### 7.3d Headless — THE ASSET MATRIX (`tests/test_asset_completeness.gd`, doc 91 §16)

Nineteen tests, 3,167 asserts, added by the Wave-10 completeness re-audit. Every other asset test in this section examines **one** family in depth — §7.1 the generator, `test_building_textures` the emissive grid, `test_vehicle_view` the fleet budget, `test_power_infra` doc 04's bands. This one asks the question none of them asks, and it is the question the standing "textures on everything" directive asks: **is there a mesh and a surface for every row of every roster the game ships, and would a new row without one be noticed?**

It is a **JOIN**, not a depth probe. The rosters are the authored tables (`data/buildings.json`, `data/vehicles.json`, `data/render.json`, and the mesh and texture manifests) and each row of each roster has to land on an asset that exists, loads, carries geometry, and resolves a page. Failure messages name the **cell**, never just the assertion — a matrix is only worth writing if it tells you which square is empty.

36. **The building matrix, 132 cells.** Every `(archetype, level)` in `data/buildings.json` has a LOD0 **and** a LOD1 in the mesh manifest, and the manifest holds exactly the matrix and no orphan rows. The doc 02 §2.14 rung split is asserted in **both** directions — six archetypes at six levels, six at five — so a level 6 appearing on a police station fails as loudly as one vanishing from a house. Each cell then loads as a one-surface `ArrayMesh` whose real index count equals its manifest `tris`, sits inside §11's triangle budget (320 / 420 tall / 96 LOD1), resolves a façade **and** a roof page that is on disk, carries `window_cols` / `window_rows` / `windowless` (positive when windowed, **zero** when not), and declares a `family` that is in `CityView.FAMILY_ORDER` — because a family the renderer does not know is `maxi(idx, 0)`, a civic tower silently lit with residential window colour at Z2.
37. **Geometry agrees across three files.** Per `(archetype, level)`: the mesh's `footprint_tiles` equals the catalog's `footprint`, the AABB's Y equals `height_m` and its X/Z equal the footprint in metres, the LOD1 keeps the LOD0's `roof_signature` and `silhouette_descriptor`, and **the LOD1 is never taller than the LOD0**. It is allowed to be *shorter* — twenty of the 66 cells are, because `lod1_volume_keep_frac` drops every roof prop that is not the signature — and that is safe **only** because `CityView` writes `_far_scale` inside an `if int(entry["lod"]) == 0:` arm, which `test_07b` asserts by source position. Move that write out of the arm and the manifest's row ORDER starts deciding how tall the far city looks, silently, in a way no headless render test can see.
38. **Every other roster.** Five `data/vehicles.json` types → five departments → the three `DEPT_MESH` bodies they share (`water` and `construction` both ride the `utility` truck and are told apart by `DEPT_PAINT`), plus doc 10 §2.15's three civilian kinds, plus the fourth emergency body no department can reach; the 2×2 vehicle atlas with `VehicleMesh.CELL_*` **agreeing with** the manifest's `vehicle_cells` and `vehicle_uv_inset` rather than merely coexisting; §2.16's five `ConstructionRigMesh` factories, each non-empty with real extent, and the `steel` / `stock` pages they wear; §2.10.1's cobra head (one surface, vertex COLOR per vertex, luminaire above grade, arm out over the carriageway); §2.10b's pad and service drop with part ids in `COLOR.a`; the ground pages on disk, the road and canal materials asserted to be `ShaderMaterial` and **not** `GroundSurface`'s untextured fallback — a correct degrade is an invisible regression — and a developed block resolving a material at all; and all three prop pages resolving to a material that actually has a texture.
39. **The two reverse joins.** Every one of the **15** shaders in `game/shaders/` loads as a `Shader` **and** is named by its owning `game/render/*.gd` — a `.gdshader` nothing references is either dead weight or a layer that lost its material in a refactor. Every one of the **18** texture pages is on disk, has an `.import` (or it never reaches the export), and every façade and roof page is **claimed** by some archetype or family — a page nobody wears is dead VRAM in the APK.
40. **The census is an assertion.** One test asserts ten raw counts (132 / 133 / 8 / 4 / 2 / 3 / 1 / 15 / 5 / 1). It is the only number-rather-than-rule test in the file and it is deliberate: doc 91 §16 quotes those totals, so the matrix cannot grow without a wave coming here and moving them, and the audit's headline cannot go stale without a red suite.

### 7.3c Headless — LIVING CONSTRUCTION (`tests/test_construction_living.gd`, §2.16)

28. **Bodies.** Excavator ≤ 520 tris, tipper ≤ 480, each yard prop ≤ 260. The excavator carries geometry on **all five** joints and the tipper on exactly three (chassis, bed, load) — a mesh with a joint the shader's chain does not reach draws in pieces. Every vertex's `UV2.y` is one of the shader's five surface codes. The tipper's load is authored with its lowest vertex **exactly** on `TIP_LOAD_FLOOR_Y`, the plane the vertex stage squashes it to; if the two drift apart an empty bed shows its load sunk through the floor.
29. **The dig loop closes.** `dig_pose(0) == dig_pose(1)` to 5e-4 on all four channels, and every channel stays inside `[0,1]` across the cycle — otherwise every excavator in the city snaps once every seven seconds, or a joint drives past its authored envelope.
30. **Streets.** A polyline built from an L-shaped tile run gains points (the corner cut fired), has monotone cumulative length, sits on the road surface, and is offset **exactly** `lane_offset_m` to the right of the centreline on its opening leg; the reversed tile list lands on the *other* lane. `sample_polyline` clamps at both ends and reads heading 0 as +X.
31. **The lifecycle.** On the starter network: a site finds its frontage (== the nearest road tile), resolves a depot and a route, and **every 2 m of that route stands on a tile the road graph owns**. One cadence produces exactly one lorry — absent before the departure, loaded with the bed down a quarter of the way out, standing at the end of the run with the bed up mid-dump, empty with the bed down on the way home, and **gone** between the trip's end and the next departure. Two sites get different cadences *and* different phases.
32. **The yard.** Sampled 241 times across four cadences at a fixed stage: the delivery count never decreases and no pile ever shrinks. Then the *peak* fill reached during an identical nine-cadence stretch of game time is measured at each of the six stages, and each stage's peak is ≤ the one before, starting above 0.4 and ending at exactly zero — growth is deliveries, shrinkage is stages, and neither can masquerade as the other. Comparing instants rather than peaks would only measure where in a cadence each sample landed, which is why the window is the unit. Every stage change also has to leave the kerb cleared. Excavator count is monotonically non-increasing across the six stages, 2 at stage 1 and 0 at stage 6; the barricade run is several bays at stage 1 and exactly one at stage 6. At `CLEANUP_STAGE` the lorry arrives empty and leaves loaded.
32b. **The frontage is a FACE (regression).** A 2×2 lot tucked into the corner of two streets, where the diagonal road tile is exactly as Chebyshev-near as the two face tiles, must front on one of the FACE tiles and never on the diagonal, and the lorry's stop must land inside the frontage (`|stop_u| ≤ half_frontage`). This is the defect a screenshot found and no assertion could have: the wrong tile still produces a valid frontage frame, a valid route and a lorry that drives real streets — it just parks past the lot's own corner with the plant strung out after it. Also covered: `set_depots()` overrides the outer-ring default and every lorry then leaves from a named tile.
33. **Budget and purity.** The layer is exactly **5** MultiMeshes. Two independently constructed views, given the same sites and the same game-minute, produce byte-identical counts, origins and joint channels — nothing may depend on frame history, allocation order or a wall clock. A site with no road inside the snap radius reports `frontage_ok == false` and draws nothing, without throwing on the way.
34. **The hash gate (§2.16).** Six game-hours of a real `CitySim`, with 240 `route_tiles()` lookups interleaved at the hour boundaries — twenty sites' worth of out-and-back legs, every hour — must leave `state_hash()` **bit-identical** to a clean run. This is the test that keeps a renderer feature from moving the simulation through the route planner's LRU.
35. **The gate faces the street (§2.16, 2026-08-20).** Given a lot one tile south of a corridor, `ConstructionVehicleView.frontage_side()` answers −Z, `ConstructionSiteView.add_site(..., side)` opens the gate on that run, and the two layers name the same face for the same site. A caller that omits the argument gets **exactly** `int(hash01(id, 7) · 4) % 4` for five different ids — the pre-frontage picture, unchanged. `site_frontage_changed` fires **once** when a site's frontage resolves, not again while it is settled, and `set_gate_side` moves the gate (and the skip standing in it) when it does.

36. **The pose cache is bit-identical (§2.16b, 2026-08-20).** One scripted 700-frame timeline — irregular game-minute steps, a stage change at 5 % of frames, and a focus gate that walks the city so sites drop out of a pass and come back — replayed on a cached and an uncached view, comparing **every field of every emitted pose**. The focus gate is in the script on purpose: it is the only way a site loses its slice of a pose pool to another site, which is the one way a slice-index cache can be wrong and the one no amount of steady-state running would ever show. Two narrower tests pin the invalidation events (a stage change and a re-route each re-derive the site against a from-cold view) and one pins `_reprice` (a `configure()` that doubles `truck_speed_mpgm` halves the leg for a site that already has a route). `tools/profile_construction.gd --verify` runs the same comparison at profiling scale.

### 7.3g Headless — STREET LIFE (`tests/test_street_life.gd`, §2.17)

Thirty-one tests, **526 assertions**, over `StreetLifeMesh`, `StreetGlyphAtlas`,
`StreetLifeModel` and `StreetLifeView`. Seven things are pinned and they are the
seven that can break.

37. **Bodies.** Crook ≤ 260 tris, dog ≤ 240, goat ≤ 280 — a body here is a hero
    prop at Z0 and a thirty-pixel silhouette at Z1, so it is allowed more than a
    car (90) and much less than the plant (520). And the one a reviewer would
    miss: **every joint a MESH uses has a row in the rig table its MATERIAL
    uploads.** A vertex on joint 6 of a body whose table stops at 5 rotates about
    the world origin; the animal draws with a leg through the pavement and
    nothing else in the suite would say so. Joint 0's mask is all zeros (the body
    never swings about its own feet) and no joint drives off the FX channel.
38. **The trot is a trot.** Fore-left and hind-right share a channel at gain +1
    and the other diagonal carries −1; get the pairing wrong and the animal paces
    like a camel. The three animation channels are authored **symmetric about
    zero**, because `gain = −1` is only a mirror across a symmetric range.
39. **The page.** Dimensions match what the shader indexes; every glyph has
    texels on BOTH sides of the 0.5 contour inside its own cell (a blank cell is
    a `$` marker with no `$` in it); and `test_the_page_has_no_internal_seams`
    samples the four-cell junction at the centre of `+`, which is exactly where
    the naive `min`-of-box-distances field puts a false contour and turns every
    digit into graph paper. Rewards map to the right glyph run and **no reward
    makes a label longer than six glyphs**, a million included.
40. **The lifecycle.** Spawn puts a body inside its own tile's wander radius and
    the shell can see it. Each kind draws its own body and the stash draws none.
    A collect takes the marker away **that frame**, raises a burst and a label,
    sets the instance alpha that tells the shader to flash, and the record is
    dropped once both the label and the burst are done. An expiry does the same
    minus the ring, minus the flash and — the whole point — **minus the label**.
    A collect on something that already left is a no-op, and so is an unknown id.
    The event feed reads `tile` as a `Vector2i`, an array or a dictionary.
41. **The wander is deterministic.** Two models stepped at 60 Hz and at 10 Hz to
    the same game-minute answer with the same position, heading and stride; a
    model that WALKED there and one that JUMPED straight to it agree (the
    save/load case, and the one an integrator would fail); and the function is
    defined at 9,999 game-minutes, which is what a catch-up needs. Two ids
    diverge by more than half a metre and get different gaits. A wander never
    leaves its own radius **and does actually move**. `gm_per_s = 0` parks every
    body exactly where it stands — while a `+$N` still rises, because the FX
    clock is not the wander's.
42. **The kerb.** A body on a road tile stands at `asphalt_top_m + kerb_height_m`
    exactly in the middle of the 1.40 m footway and paces ALONG the street; a
    body on the lot next door stands on the avenue's own 1.05 m footway across
    the property line; with no road probe nothing snaps and everything still
    draws. And the squash: a snapped wander never leaves 0.87 m of the kerb line,
    which is inside the tile, i.e. **never in the carriageway**.
43. **The budget.** Exactly **4** MultiMeshes, `active_buffers()` never exceeds
    them, and a lone crook submits exactly two. The fx pool survives the worst
    frame the caps allow — every live opportunity collected on one frame — and is
    **sized from the caps rather than guessed at**. The roster evicts a finished
    record before a live one and never the newest. Distance gates the bodies
    before the markers, and past the visible radius nothing is drawn at all.
44. **The marker reads, in screen pixels.** 46 px at Z1, 78 at Z0, 12 at Z2 on a
    1080-line frame at doc 11's 40° FOV — asserted as numbers, because "legible
    while scrubbing" is otherwise an opinion. `marker_world_pos` sits over the
    body and clear of a goat's horns, returns `INF` once collected and for an id
    the layer never had, and the marker **bobs through its full authored travel
    without ever changing size** — the pulse is a brightness, because the size is
    the shell's tap target.
45. **The shaders keep this renderer's rules.** The rig arrays are the mesh
    tables' size; the channel is selected by `dot(ang, rig_sel[j])` and not by a
    dynamic index into a vector; the fx shader fetches **exactly once**, off
    exactly one sampler, **outside every branch**; a faded instance is collapsed
    in the vertex stage; and the pass writes no depth and opts out of fog.
46. **The hash gate (§2.17).** Six game-hours of a real `CitySim` against the
    same six with a full frame of this layer driven at every hour boundary — 48
    spawns on real road tiles, 180 rendered frames, 24 collects, 24 expiries and
    every road probe they take — comparing `state_hash()`. Bit-identical. If a
    future change ever makes this layer read the simulation, this is what goes
    red, and not a screenshot three waves later.

### 7.2c Headless — the incremental street rebuild (`tests/test_road_incremental.gd`, §2.1.2a)

Seven tests over `RoadSurfaceView`'s stateful diff. The contract is one sentence — *after any sequence of edits, both uploaded buffers are byte-identical to a from-scratch rebuild of the same city* — and five of the seven are property tests, because the defect shape here is a dependency radius one tile too small and nothing but a lot of random edits on a lot of random cities finds that.

01. **The diff runs, and it is a diff.** The boot pass is full; the next pass is incremental and says so; one edit re-classifies fewer than 25 tiles (the Manhattan r=3 ball) of the city's 3,132.
02. **`force` throws the memory away** — a mid-session load must not diff against a city that no longer exists — and the result still matches a fresh rebuild.
03. **Five hand-picked shapes**, one per dependency the radii were derived for: a new stub, a tile that closes a junction, an in-place class upgrade, a bulldoze, and a bulldoze that splits a corridor.
04. **The class sweep is load-bearing.** A solid 5×5 of street, middle tile upgraded: `apply_edits` returns two empty lists (every edge came back with its own id — doc 10 §2.5's stability rule) while the tile's class channel moves, because a multi-edge tile takes its class from the GRID. This is the test that would go red if somebody replaced the sweep with an `added_edges` seed.
05. **40 sequences × 12 random edits** on a grid city with a live dual carriageway; every one of the 480 intermediate states compared byte for byte.
06. **24 sequences × 10 random edits against water and the map edge**, where the kerb mask is decided by two different rules (`_is_water` kerbs an off-map neighbour on purpose) and an off-by-one shows up as a footway that stops one tile short.
07. **The founding city under a ten-tile drag**, one rebuild per tile — the way the road-drawing tool will feed it.

### 7.4 On-device — `tools/bench_flythrough.gd` + adb

A deterministic 90 s camera path over `tests/fixtures/bench_city.json` — **generated by doc 09 (`tools/gen_bench_city.py`, same generator family as the starter city), validated by doc 08 against the current save schema in CI, consumed here** (report G-7, ruled; former §9 open question 20 is closed). Contents **as shipped** (see §2.13's as-shipped table): a 7×7 world with a **6×6 developed core (36 blocks)**, **1,500 buildings** across L1–L5, 3,132 road tiles, ~780 streetlight props, and the civic roster that houses the emergency fleet. *(The pre-build figures were "~1,100 buildings" and an 8×8 world; the count moved to doc 91's 1,500 — the size this section's device matrix is written against — and the world stayed 7×7 because `TileGrid.BLOCKS` is 7. Doc 09 §2.13's profile table carries the same numbers.)* The device harness is `tools/bench_device.sh`, which drives the three scenarios below over adb and collects both our `PERF` lines and the platform's `gfxinfo`/`meminfo`/`thermalservice` output; ~~it ships ready and~~ **rewritten 2026-08-20 against `tools/device_runbook.md` and the dev-argument vocabulary `game/main.gd` actually parses — the pre-Wave-12 version could not have run at all (§2.13's note). Its non-device half is now covered by `--self-test` (20 checks, green); it still has not been run against a device.**

> **It also cannot work as written, and §2.13's Fold pass says why (2026-08-20).**
> Three faults, all readable in `game/main.gd` rather than discoverable only with
> a phone on the cable: (a) `PerfGovernor.perf_line()` is **called by nothing**,
> so `grep '^PERF'` returns an empty CSV — `game/render/perf_telemetry.gd` is the
> wiring and it needs `game/main.gd`'s snippet; (b) `--es cmdline` is the wrong
> `am` flag — Godot's Android launcher reads a string ARRAY extra and
> `OS.get_cmdline_user_args()` returns only what follows a literal `--`, so the
> form is `--esa command_line_params "--,…"`; (c) **`--bench=S1|S2|S3`,
> `--preset=` and `--city=` are parsed by nothing.** The shell's actual scenario
> vocabulary is `--resume`, `--title`, `--zoom=`, `--focus=`, `--advance-hours=`,
> `--overlay=`, `--rain=`, `--storm=`, `--wet=`, `--blackout`, `--cut-feeder=`,
> `--place=`, `--save-now`, `--screenshot=` and `--shot-at=` — which is enough
> for every question below. **`tools/device_runbook.md` is the session written
> against that vocabulary**, drives the INSTALLED build, and carries each table
> here with an empty device column beside a workstation provisional.

Three scenarios:

- **S1** — 12:00 clear (worst case for shadows + draw calls)
- **S2** — 20:00 clear (worst case for emissives + glow)
- **S3** — 20:00 thunderstorm, scripted 4-block blackout at t = 45 s, relight at t = 65 s (worst case overall, and the acceptance test for the signature moment)

```bash
# build & install
~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
  --export-debug "Android" build/slacum-debug.apk
adb install -r build/slacum-debug.apk

# run a scenario; PerfGovernor prints a PERF line every 2 s
adb logcat -c
adb shell am start -n com.slacumcity.game/com.godot.game.GodotApp \
  --es cmdline "--bench=S3 --preset=balanced"
adb logcat -s godot:V | grep '^PERF' | tee perf_S3_balanced.csv

# platform-side frame timing (ground truth, independent of our counters)
adb shell dumpsys gfxinfo com.slacumcity.game reset      # ...run scenario...
adb shell dumpsys gfxinfo com.slacumcity.game framestats > framestats_S3.txt

# memory, thermal soak (20 min loop of S3), battery
adb shell dumpsys meminfo com.slacumcity.game > meminfo_S3.txt
adb shell 'while true; do cat /sys/class/thermal/thermal_zone0/temp; sleep 10; done' > thermal.log
adb shell dumpsys thermalservice | grep -i status
adb shell dumpsys batterystats --reset                    # ...run 20 min...
adb shell dumpsys batterystats com.slacumcity.game > batt.txt
```

`PerfGovernor` emits, from `Performance.get_monitor(...)`:

```
PERF t=62.0 fps=58.4 p95=18.9 cpu=3.8 gpu_est=12.1 dc=214 prim=486133 \
     vram=298 static_mem=141 chunks=14 near=3 inst=4120 lights=12 preset=balanced knob=0
```

**Acceptance gates (must pass before the vertical slice is called done):**

| gate | Pixel 6 / Balanced | SD 695 / Performance | Pixel 8 / High |
|---|---|---|---|
| p95 frame time, S1 / S2 | ≤ 16.7 ms | ≤ 33.3 ms | ≤ 16.7 ms |
| p95 frame time, S3 | ≤ 20.0 ms | ≤ 40.0 ms | ≤ 18.0 ms |
| p99 frame time, any | ≤ 33 ms | ≤ 66 ms | ≤ 33 ms |
| jank frames (gfxinfo > 16.7 ms) | ≤ 4% | n/a (30 Hz target) | ≤ 3% |
| peak draw calls | ≤ 320 | ≤ 180 | ≤ 520 |
| **no frame > 50 ms during the blackout or relight window** | required | required | required |
| PSS after 20 min | ≤ 900 MB | ≤ 700 MB | ≤ 1,300 MB |
| thermal rise over 20 min | ≤ 12 °C, no THROTTLING | ≤ 12 °C | ≤ 14 °C |
| battery drain | ≤ 9 %/h | ≤ 8 %/h | ≤ 12 %/h |
| shader compiles after 10 s warm-up | 0 | 0 | 0 |

Deep dives when a gate fails: **Android GPU Inspector** for Adreno/Mali counters (RenderDoc is not viable on most Android devices), **Arm Streamline** on Mali parts, Godot `--debug-gpu` for validation-layer errors in dev builds.

**Manual visual checklist**, per milestone: blackout reads at Z0/Z1/Z2; relight sweep direction is correct relative to the substation; no LOD pop during a slow Z1→Z2 pinch; no light popping when the omni pool re-binds during a pan; rain does not swim during fast pans; lightning lights façades from a plausible direction; overlay mode legible in direct sunlight at 50% screen brightness.

---

## 8. Tunables — `data/render.json`

```json
{
  "schema_version": 1,

  "world": { "tile_m": 8.0, "chunk_tiles": 16, "chunk_m": 128.0, "floor_height_m": 3.5,
             "window_spacing_x_m": 3.2, "streetlight_spacing_m": 32.0 },

  "camera": { "_owner": "projection = doc 11; range = doc 12 (report C-63). data/ui.json references these rows, never restates them.",
              "fov_deg": 40.0, "near": 1.0, "far": 1600.0,
              "zoom_min_dist_m": 18.0, "zoom_max_dist_m": 420.0,
              "pitch_min_deg": 34.0, "pitch_max_deg": 62.0,
              "_deleted": "yaw_snap_deg, pan_damping, zoom_damping -> doc 12 (rotation_mode and gesture constants in data/ui.json)" },

  "lod": { "near_max_m": 150.0, "medium_max_m": 420.0, "hysteresis_m": 20.0, "dwell_s": 0.5,
           "tri_budget_lod0": 320, "tri_budget_lod0_tall": 420, "tri_budget_lod1": 96,
           "lod1_ratio_max": 0.40, "lod1_volume_keep_frac": 0.15,
           "tall_archetypes": ["res_highrise", "com_highrise", "civ_stadium"],
           "_z2_expected_chunks": 16,
           "_z2_expected_chunks_tolerance_plus": 3, "_z2_expected_chunks_tolerance_minus": 0,
           "_z2_expected_tiers": {"near": 0, "medium": 10, "far": 6},
           "_z2_expected_draw_calls": 159, "_z2_expected_draw_calls_with_overlays": 165,
           "_z2_expected_columns_per_row": [5, 5, 6],
           "_z2_derivation": "Reports RR-12 and RR-14. At Z2 (D 420, pitch 62): h 370.8, r_near 52.1, r_far 411.9. On the 128 m chunk grid that is exactly THREE rows, originating at 52.1 / 180.0 / 308.0 m; a fourth row would originate at 436.0 m > r_far and cannot exist (the former row at r=412 was the far EDGE, not a row origin). Columns per row = ceil(w(r_far_of_row)/128) with w(r)=2*sqrt(r^2+h^2)*0.64706, applied as a PURE CEILING with no discretionary rounding (RR-14): w = 533.4 / 623.8 / 717.2 m -> ceil(4.167) / ceil(4.874) / ceil(5.603) -> 5 / 5 / 6 = 16 chunks. Rows A and B are inside the MEDIUM boundary r<=197.3 m, so tiers are 10 MEDIUM + 6 FAR + 0 NEAR; opaque = 10*10 + 6*3 = 118, total = 118 + 41 = 159 (165 with overlays). 16 is the FLOOR of the band: grid alignment against the view axis can add at most one column to each row, giving the hard band 16..19 chunks (159..182 calls) -- hence the asymmetric +3/-0 chunk tolerance in test 19 rather than a percentage or a symmetric window. The earlier 17-chunk / 169-call figure rounded row B's 4.874 up to 6 by judgement and double-counted the misalignment already carried by the band." },

  "streaming": { "chunk_builds_per_frame": 2, "chunk_build_ms_budget": 3.0,
                 "chunk_teardowns_per_frame": 1, "multimesh_instance_writes_per_frame": 2000,
                 "bucket_alloc_granularity": 32, "max_instances_per_bucket": 256,
                 "max_animating_buildings": 1200, "bulk_upload_dirty_threshold": 8 },

  "emissive": { "powered_base": 0.55, "powered_occ_gain": 0.45, "backup_lit": 0.22,
                "dark_lit": 0.05, "damage_dim_gain": 0.50,
                "condition_critical_threshold": 0.15, "condition_critical_mult": 0.40,
                "day_gate": 0.06, "window_nits": 3.2, "window_nits_far": 2.4,
                "window_variance_min": 0.35, "window_variance_gain": 0.65,
                "flicker_prob": 0.015, "flicker_depth": 0.25, "flicker_hz": 3.0,
                "soot_color": "#47433D", "soot_blend": 0.8,
                "far_band_lo": 0.30, "far_band_hi": 0.78,
                "window_color": { "residential": "#FFCE8A", "commercial": "#CFE6FF",
                                  "industrial": "#BFD0C8", "tech": "#7FF0D0",
                                  "civic": "#E8F0FF" } },

  "blackout": { "_carrying_event": "BlockDarkChanged{block_id, block_dark, powered_fraction, restore_order} -- emitted and named by doc 04 §4 (report C-38 + RR-1). The renderer subscribes to this name and to no event named DistrictDarkChanged.",
                "stutter_envelope": [[0.00,1.00],[0.07,1.00],[0.09,0.12],[0.15,0.95],
                                     [0.17,0.08],[0.24,0.70],[0.30,0.00]],
                "stagger_s": 0.35, "tau_fall_s": 0.12, "streetlight_delay_mult": 0.60,
                "ground_darken_mult": 0.45, "relight_sweep_s": 2.2, "relight_jitter_s": 0.5,
                "relight_streetlight_mult": 0.80, "relight_ramp_s": 0.15,
                "relight_settle_s": 0.30, "relight_overshoot": 1.35,
                "relight_source_dist_floor_m": 40.0, "relight_peak_event_s": 1.1,
                "relight_order_source": "restore_order",
                "relight_order_fallback": ["source_pos", "block_centroid"],
                "momentary_outage_s": 4.50, "momentary_relight_total_s": 0.75,
                "_momentary_derivation": "momentary_outage_s >= 1.5 * (power.protection.auto_reclose_delay_gs / 60) * power.protection.auto_reclose_max_attempts = 1.5 * 1.5 * 2 = 4.50 (report C-40; asserted by test 24)" },

  "occupancy_hour_curve": {
    "_owner": "doc 11 (report C-66). Art, not simulation. Multiplied by doc 02's structural occ_b in §2.7.1. Six [hour, value] keyframes per building family, linearly interpolated, wrapping at 24:00. Read as: fraction of occupied floor area showing light.",
    "residential": [[0.0,0.30],[3.0,0.12],[7.0,0.55],[12.0,0.30],[19.0,0.95],[21.0,1.00]],
    "commercial":  [[0.0,0.05],[6.0,0.10],[9.0,0.85],[13.0,1.00],[18.0,0.70],[22.0,0.15]],
    "industrial":  [[0.0,0.45],[6.0,0.70],[9.0,0.95],[15.0,1.00],[20.0,0.65],[22.0,0.50]],
    "tech":        [[0.0,1.00],[6.0,1.00],[12.0,1.00],[15.0,1.00],[18.0,1.00],[22.0,1.00]],
    "civic":       [[0.0,0.40],[6.0,0.55],[9.0,0.95],[15.0,1.00],[19.0,0.70],[22.0,0.50]] },

  "daynight": {
    "keys": [
      {"h":0.0, "sky_top":"#050810","sky_hor":"#0D1524","sun_e":0.05,"sun_c":"#7A90C0","sun_elev":-20,"fog":"#0E1420","night":1.00},
      {"h":5.0, "sky_top":"#0A1024","sky_hor":"#1E2438","sun_e":0.10,"sun_c":"#6E82B4","sun_elev":-6, "fog":"#12182A","night":0.95},
      {"h":7.0, "sky_top":"#2A3C5E","sky_hor":"#C88A5A","sun_e":1.60,"sun_c":"#FFB070","sun_elev":8,  "fog":"#5A5A66","night":0.35},
      {"h":12.0,"sky_top":"#4A78B8","sky_hor":"#9FBEDC","sun_e":3.20,"sun_c":"#FFF4E2","sun_elev":62, "fog":"#8FA3B8","night":0.00},
      {"h":18.5,"sky_top":"#33406A","sky_hor":"#D07A48","sun_e":1.30,"sun_c":"#FF9050","sun_elev":6,  "fog":"#6E5E5E","night":0.40},
      {"h":21.0,"sky_top":"#080C18","sky_hor":"#141C30","sun_e":0.06,"sun_c":"#7A90C0","sun_elev":-14,"fog":"#101624","night":1.00}
    ],
    "sun_azimuth_offset_deg": -90.0, "moon_energy": 0.09, "moon_color": "#8FA8D8",
    "ambient_energy_day": 0.55, "ambient_energy_night": 0.10 },

  "environment": {
    "tonemap": "agx", "tonemap_exposure": 1.0, "tonemap_white": 6.0,
    "contrast": 1.06, "saturation_day": 1.05, "saturation_night": 0.92,
    "fog_crossfade_s": 4.0,
    "_fog_clamp": "fog_depth_end_eff = min(profile.end, active_far_cull_m); fog_depth_begin_eff = min(profile.begin, 0.75 * fog_depth_end_eff). Enforces the §2.8 invariant across presets and governor knob positions (test 23).",
    "fog": {
      "clear_day":   {"begin":260,"end":1200,"curve":1.00,"density":0.0012,"aerial":0.35,"sky":0.6,"height":-20,"h_density":0.02},
      "clear_night": {"begin":180,"end":1200,"curve":1.00,"density":0.0020,"aerial":0.20,"sky":0.4,"height":-20,"h_density":0.05},
      "rain":        {"begin":140,"end":900, "curve":0.85,"density":0.0045,"aerial":0.30,"sky":0.8,"height":-20,"h_density":0.03},
      "fog_weather": {"begin":40, "end":420, "curve":0.70,"density":0.0110,"aerial":0.15,"sky":1.0,"height":-10,"h_density":0.12} } },

  "weather": {
    "rain_box_m": [90.0,40.0,90.0], "rain_box_y_offset_m": 20.0, "rain_quad_m": [0.02,0.55],
    "rain_gravity_y": -22.0, "rain_wind_gain": 2.2,
    "splash_radius_m": 60.0, "splash_quad_m": [0.35,0.35], "splash_lifetime_s": 0.28,
    "snow_gravity_y": -3.0, "snow_quad_m": [0.10,0.10], "snow_damping": 2.0,
    "wetness_tau_up_s": 25.0, "wetness_tau_down_s": 90.0, "wetness_precip_gain": 1.2,
    "wet_roughness_dry": 0.85, "wet_roughness_wet": 0.18,
    "wet_specular_dry": 0.50, "wet_specular_wet": 0.85, "wet_albedo_mult": 0.62,
    "wet_smear_min": 0.05, "wet_smear_y_scale": 1.8, "wet_smear_alpha": 0.35,
    "lightning_envelope": [[0.00,0.00],[0.02,1.00],[0.09,0.15],[0.13,0.85],[0.30,0.00]],
    "lightning_sky_gain": 6.0, "lightning_ambient_gain": 4.0, "lightning_dir_energy": 2.4,
    "lightning_color": "#C9D6FF", "lightning_fog_color": "#AEBEE0", "lightning_fog_blend": 0.7,
    "lightning_luminance_clamp": 1.35, "lightning_reduce_flashes_scale": 0.25,
    "thunder_speed_of_sound_mps": 340.0 },

  "streetlights": { "lamp_billboard_m": 1.6, "lamp_color": "#FFD9A0",
                    "pool_radius_m": 6.0, "pool_y_m": 0.06,
                    "pool_wet_radius_gain": 0.5, "pool_wet_energy_gain": 0.6,
                    "omni_range_m": 14.0, "omni_energy": 1.6, "omni_attenuation": 1.6,
                    "omni_shadows": false, "omni_distance_fade_begin_m": 55.0,
                    "omni_distance_fade_len_m": 15.0,
                    "pool_rebind_hz": 4.0, "pool_crossfade_s": 0.25,
                    "_pool_y_superseded": "STREET-1: pool_y_m 0.06 sat UNDER the carriageway's 0.10 top and every pool in the game was depth-buried by the road it was lighting. StreetlightView now takes its height from road_surface.asphalt_top_m + kerb_height_m + lamp.pool_lift_m. This row is kept for a clone with no road_surface block." },

  "road_surface": { "_owner": "doc 11 §2.1.2 + §2.10.1. RoadSurfaceView reads this block; StreetlightPlacer reads its `lamp` sub-block. Nothing here duplicates the `ground` block's night floor — the carriageway inherits the ROAD row from there.",
                    "detail": 2,
                    "asphalt_top_m": 0.10, "asphalt_thickness_m": 0.10, "kerb_height_m": 0.15,
                    "sidewalk_width_street_m": 1.40, "sidewalk_width_avenue_m": 1.05,
                    "page": "asphalt", "tint": "#57575F", "roughness": 0.85,
                    "sidewalk_page": "pavement", "sidewalk_tint": "#A6A69D",
                    "sidewalk_roughness": 0.93, "sidewalk_kerb_tint": "#96958C",
                    "sidewalk_joint_period_m": 1.20, "sidewalk_joint_darken": 0.30,
                    "sidewalk_kerb_dark": 0.72, "sidewalk_kerb_edge_gain": 0.16,
                    "sidewalk_night_albedo_lift": 0.30, "sidewalk_night_glow": 0.042,
                    "line_yellow": "#E3B637", "line_white": "#C6C6BD",
                    "centre_line_w_m": 0.16, "double_gap_m": 0.12, "edge_line_w_m": 0.12,
                    "edge_line_inset_m": 0.28,
                    "dash_mark_m": 2.40, "dash_gap_m": 3.60,
                    "lane_dash_mark_m": 3.00, "lane_dash_gap_m": 5.00,
                    "dead_end_stop_m": 2.50,
                    "marking_night_glow": 0.075, "marking_roughness": 0.62,
                    "marking_wear_loss": 0.35,
                    "crosswalk_bar_m": 0.45, "crosswalk_period_m": 0.85,
                    "crosswalk_depth_m": 1.35, "crosswalk_inset_m": 0.35,
                    "patch_gain": 0.16, "patch_scale_m": 11.0, "seam_darken": 0.16,
                    "wheel_path_gain": 0.10, "wheel_path_w_m": 0.95,
                    "gutter_m": 0.55, "gutter_darken": 0.22, "wear_tile_gain": 0.07,
                    "lamp": { "spacing_tiles": 4, "corner_lamps": true,
                              "pole_curb_frac": 0.50, "mast_height_m": 7.60,
                              "arm_reach_m": 2.20, "arm_rise_m": 0.75, "head_height_m": 8.35,
                              "head_length_m": 1.05, "head_width_m": 0.40,
                              "head_height_back_m": 0.24, "head_height_front_m": 0.16,
                              "pole_width_m": 0.20, "pool_lift_m": 0.005 } },

  "vehicles": { "civ_spawn_per_m": 0.0222, "civ_visible_radius_m": 420.0,
                "civ_body_tris_max": 90, "emergency_body_tris_max": 180,
                "lightbar_hz": 2.2, "lightbar_emission": 3.5,
                "lightbar_red": "#FF2A22", "lightbar_blue": "#2A5CFF",
                "interp_teleport_threshold_m": 40.0, "headlight_night_threshold": 0.15 },

  "construction_vehicles": { "truck_speed_mpgm": 21.0, "delivery_period_gm": 46.0,
                             "dump_gm": 4.2, "dig_cycle_gm": 7.0,
                             "pile_per_delivery": 0.26, "pile_consume_per_stage": 0.30,
                             "pile_max_m": 1.75, "pile_base_m": 2.60,
                             "barrier_bay_m": 2.55, "barrier_out_m": 2.15,
                             "pile_out_m": 0.95, "rig_out_m": 4.40,
                             "beacon_hz": 1.35, "beacon_energy": 3.2, "lamp_energy": 2.2,
                             "visible_radius_m": 520.0, "max_sites": 28 },

  "_street_life": "§2.17. TWO CLOCKS: the WANDER is in GAME-MINUTES (a paused city is a still city), the FX (collect_s, expire_s, burst_s, label_s) are REAL SECONDS. The footway numbers a body stands on are NOT here - the layer reads road_surface.asphalt_top_m, kerb_height_m and the two sidewalk widths, so a body stands on the kerb §2.1.2 actually drew. marker_angular is METRES OF MARKER PER METRE OF CAMERA DISTANCE, i.e. an ANGULAR size: 46 screen px at Z1 on a 1080-line frame, 78 at Z0, 12 at Z2. label_rise_frac and label_glyph_frac are fractions OF THE MARKER for the same reason - a rise authored in metres is a hand's width at Z0 and a twitch at Z1.",
  "street_life": { "wander_radius_m": 2.9, "wander_across_frac": 0.30, "waypoints": 5,
                   "gait_move_gm": [0.90, 1.10, 1.55, 1.0],
                   "gait_pause_gm": [1.55, 0.34, 1.95, 1.0],
                   "stride_m": [1.35, 1.05, 1.15, 1.0],
                   "marker_angular": 0.0310, "marker_min_m": 0.95, "marker_max_m": 3.30,
                   "marker_gap_m": 0.62, "marker_bob_m": 0.13, "marker_bob_hz": 0.44,
                   "marker_pulse_hz": 0.62, "marker_pulse_depth": 0.20,
                   "marker_energy_day": 1.00, "marker_energy_night": 1.45,
                   "marker_fade_begin_m": 150.0, "marker_far_alpha": 0.30,
                   "body_radius_m": 240.0, "body_fade_m": 45.0, "visible_radius_m": 430.0,
                   "collect_s": 0.62, "expire_s": 0.70, "burst_s": 0.58,
                   "label_s": 1.35, "label_rise_frac": 0.85, "label_energy": 1.35,
                   "label_glyph_frac": 0.50, "label_pitch_frac": 0.66,
                   "bound_m": 3.2, "flee_s": [0.40, 0.70], "flee_m": 3.6,
                   "rim_gain": 0.34, "glint_energy": 1.5,
                   "flash_energy": 2.6,
                   "crook_coat": "#333542", "dog_coat": "#8C6B45",
                   "goat_coat": "#DBD9CC", "stash_coat": "#CCB866",
                   "crook_marker": "#F25242", "dog_marker": "#6BB8F5",
                   "goat_marker": "#8CD670", "stash_marker": "#FFCC3D",
                   "label_tint": "#FFDB57",
                   "max_live": 8, "max_bursts": 6, "max_labels": 6,
                   "puffs_per_burst": 6 },

  "blob_shadow": { "enabled_presets": ["performance"], "y_m": 0.04,
                   "footprint_scale": 1.15, "alpha": 0.35, "night_fade": 0.6,
                   "body_alpha": 0.50, "body_m": [0.62, 0.78, 0.82, 0.0],
                   "body_lift_m": 0.60 },

  "overlay": { "desaturate_blend": 0.55, "emission_mult": 0.40, "render_priority": 5,
               "superblock_chunks": 4, "flow_scroll_speed": 0.35, "max_extra_draw_calls": 6 },

  "presets": {
    "performance": { "target_fps":30, "gpu_budget_ms":24.0, "cpu_budget_ms":6.0,
      "render_scale":0.70, "msaa":0, "fxaa":true,
      "draw_call_budget":180, "instance_budget":3000,
      "chunk_budget":24, "near_chunk_max":3, "far_cull_m":900.0,
      "street_lights":6, "street_light_radius_m":55.0, "emergency_lights":2,
      "shadows":false, "shadow_splits":0, "shadow_atlas":0, "shadow_max_m":0.0,
      "rain":1500, "splash":0, "snow":1200, "turbulence":false,
      "civ_cars":64, "civ_vans":20, "civ_trucks":12, "civ_headlights":96, "emergency_nodes":12,
      "road_detail":1,
      "glow_levels":[3,4], "glow_intensity":0.75, "glow_strength":1.00, "glow_bloom":0.03,
      "glow_blend":"screen", "glow_hdr_threshold_day":1.10, "glow_hdr_threshold_night":0.85,
      "glow_hdr_scale":1.6, "reflection_probe":false, "moon":false, "env_adjustments":false,
      "vram_budget_mb":220, "pss_budget_mb":700 },
    "balanced": { "target_fps":60, "gpu_budget_ms":13.0, "cpu_budget_ms":4.0,
      "render_scale":0.85, "msaa":2, "fxaa":false,
      "draw_call_budget":320, "instance_budget":7000,
      "chunk_budget":40, "near_chunk_max":6, "far_cull_m":1200.0,
      "street_lights":12, "street_light_radius_m":70.0, "emergency_lights":4,
      "shadows":true, "shadow_splits":2, "shadow_atlas":2048, "shadow_max_m":150.0,
      "rain":4000, "splash":600, "snow":3000, "turbulence":false,
      "civ_cars":160, "civ_vans":60, "civ_trucks":36, "civ_headlights":256, "emergency_nodes":20,
      "glow_levels":[2,3,4], "glow_intensity":0.90, "glow_strength":1.00, "glow_bloom":0.05,
      "glow_blend":"screen", "glow_hdr_threshold_day":1.05, "glow_hdr_threshold_night":0.78,
      "glow_hdr_scale":2.0, "reflection_probe":false, "moon":true, "env_adjustments":true,
      "vram_budget_mb":320, "pss_budget_mb":900 },
    "high": { "target_fps":60, "gpu_budget_ms":13.0, "cpu_budget_ms":4.0,
      "render_scale":1.00, "msaa":2, "fxaa":false,
      "draw_call_budget":520, "instance_budget":14000,
      "chunk_budget":64, "near_chunk_max":8, "far_cull_m":1500.0,
      "street_lights":20, "street_light_radius_m":90.0, "emergency_lights":6,
      "shadows":true, "shadow_splits":4, "shadow_atlas":4096, "shadow_max_m":180.0,
      "rain":9000, "splash":1600, "snow":6000, "turbulence":true,
      "civ_cars":320, "civ_vans":120, "civ_trucks":72, "civ_headlights":512, "emergency_nodes":28,
      "glow_levels":[1,2,3,4,5], "glow_intensity":1.00, "glow_strength":1.05, "glow_bloom":0.07,
      "glow_blend":"screen", "glow_hdr_threshold_day":1.00, "glow_hdr_threshold_night":0.75,
      "glow_hdr_scale":2.2, "reflection_probe":true, "probe_size_m":[256,120,256],
      "probe_move_refresh_m":100.0, "moon":true, "env_adjustments":true,
      "vram_budget_mb":420, "pss_budget_mb":1300 } },

  "autodetect": { "bench_duration_s":3.0, "bench_warmup_s":0.8,
                  "t95_high_ms":13.0, "t95_balanced_ms":20.0, "t95_performance_ms":30.0,
                  "tier_d_far_cull_m":700.0, "tier_d_chunk_budget":16 },

  "governor": { "window_frames":120, "eval_interval_s":1.0,
                "step_down_ratio":1.25, "step_down_hold_s":5.0,
                "step_up_ratio":0.80, "step_up_hold_s":30.0,
                "knobs": [ {"id":"render_scale","delta":-0.05,"floor":0.60},
                           {"id":"particle_ratio","mult":0.60,"floor":0.30},
                           {"id":"far_cull_m","delta":-128.0,"floor":600.0},
                           {"id":"street_lights","delta":-4,"floor":4},
                           {"id":"preset_drop","latch":true} ],
                "protected": ["emissive","blackout","glow_enabled"],
                "perf_log_interval_s": 2.0 }
}
```

---

## 9. Conflicts & Open Questions

### Conflicts with the constitution

1. **`game/` holds render-only randomness.** `TrafficVisualizer` and the per-building `variant`/`anim_phase` derive from hashes of building ids plus a render-local seed. Constitution §5 forbids *sim* code from using a shared/global RNG; it does not govern `game/`. I assert render-side randomness is **not** part of determinism, is never persisted, and never feeds back to the sim. If the overseer wants one RNG policy everywhere, `variant`/`anim_phase` already derive purely from `hash(building_id)`, and `TrafficVisualizer` would need its own persisted-seed stream in `render_prefs`.
2. **Streetlights: RESOLVED, no conflict.** Doc 04 already owns lit state and emits `StreetlightsChanged(block_id, lit)` per land block, and bills streetlight load per road tile (`0.35 kW`). The renderer owns only pole *placement* (~22 per developed block at 32 m spacing). Note the deliberate granularity mismatch: doc 04 charges per road tile, the renderer draws one pole per four tiles. That is correct — load is continuous along a lit street, poles are discrete objects — but it means pole count must never be used to derive load, or vice versa. **Related, and I have an opinion:** doc 04's own open question 12 asks whether street lighting should be separately switchable. From the rendering side that is a *strong yes* — shedding lighting while buildings stay lit is the most visually distinctive shed tier available, instantly readable at any zoom (dark streets under a lit skyline), and it costs the renderer nothing since the lamp/pool/omni path is already independent of the building path.
3. **`data/render.json` contains colours and curves, not only balance numbers.** Constitution §2/§12 says all tunable numbers live in `data/`, and art-direction values are tunable numbers by that rule. Flagging in case the overseer prefers art constants beside the shaders.

### Likely conflicts with sibling docs

4. **Restoration ordering: RULED AND CLOSED (report C-39).** Doc 04 adds `restore_order: PackedInt32Array` to the restoration event — it falls out of its existing energization DFS for free and is strictly better than a `source_pos` because it follows real restoration priority. §2.7.3 consumes it as the primary sweep and keeps the distance form as a fallback. This was the renderer's highest-risk cross-doc dependency; it no longer exists.
5. **Block granularity: RULED AND CLOSED (report C-38).** Doc 04's flag is renamed **`block_dark`** and is flagged on the **land block** (at `block_dark_frac 0.60` of buildings weighted by population + jobs), and land block == render chunk (constitution §6). "District" now means doc 09's 1–4-block population-weighted aggregate, which the renderer never consumes. Ground darkening (§2.7.2 step 6) is per-chunk and therefore exactly aligned; no per-tile mask is needed. Doc 04 additionally maintains a per-tile dark mask for its own overlay — if that is cheap to expose, the renderer would take it for sub-block ground darkening as a polish item, but nothing depends on it.
6. **Diurnal occupancy: RULED AND CLOSED (report C-66).** The curve is **art, not simulation**, so it must not become a sim input. **This doc owns `occupancy_hour_curve` per building *family*** in `data/render.json` §8 and multiplies it by doc 02's structural `occ_b` (§2.7.1). Doc 02 changes nothing; no new sim data, no new save state. Without it every powered building would sit at a flat `0.55 + 0.45·occ_b` and the "city breathes between day and night" read would die.
7. **Continuous precipitation: RULED AND CLOSED (report C-58).** Doc 07 publishes `precip01 = clamp(precip_mm_h / 35.0, 0, 1)`, continuous across segment boundaries by lerping the last 60 game-seconds of a segment into the next. §2.9 consumes `precip01` only — no enum, no particle restarts, no step-changes in wetness.
8. **Doc 06 vehicle update rate.** I assumed 4 Hz per constitution §4. If dispatch wants 10 Hz for responsiveness, interpolation still works but `emergency_nodes` budgets and per-tick event volume need re-checking on tier C.
9. **Overlay state count: RULED AND CLOSED (report C-64).** **Four** building overlay states, 2 bits, packing constant `112` — all confirmed. Doc 12's fifth state `SELECTED` is a UI-layer outline drawn by `MarkerLayer`, never a per-instance building state: a selection is transient and single-valued, so it belongs to the UI, not the instance buffer. §2.6 stands unrevised.
10. **Doc numbering: RULED AND CLOSED (report 98 Ruling Zero).** The on-disk filenames in `docs/design/` are canonical and there is no other map. This doc was already written against them; the header note now states the ruling rather than proposing it, and every §5 heading carries the canonical system title. No code may reference a doc number until Ruling Zero has landed in every doc.
11. **Doc 01's daylight curve vs. this doc's `sc_night`.** Doc 01 fixes sunrise 06:00 / sunset 19:00. §2.8 starts window-lighting at 18:00 and reaches full night at 21:00 — deliberately *not* tied to sun elevation, because the best-looking moment is warm sky plus lit windows. These two curves must be allowed to disagree; if the overseer wants them locked together, §2.8's keys become derived and the 18:00–19:00 magic hour is lost.
12. **Weather scope: RULED AND CLOSED (report C-59).** Weather state is **city-wide global**; only the `THUNDERSTORM` storm cell is spatial, and it drives lightning targeting and flood accumulation, not the global effect channels. There is no second visible weather region in MVP and therefore no boundary popping to accept or mitigate. §2.9's single global state is correct rather than a compromise.
13. **Fractional power: RULED AND CLOSED (report C-39).** Doc 04 carries `powered_fraction` on the event from day one even while its model is binary, so §2.7.4's load-shed path needs no later event-schema change.
14. **Auto-reclose coupling: RECORDED AS A DEPENDENCY (report C-40).** A 90 game-second reclose is 1.5 real seconds, which clears doc 04's 20 gs dark-hold and therefore produces real dark→lit event pairs constantly. Playing the 4.35 s full ceremony for those would drown the signature moment in noise, so §2.7.5 classifies short outages as flickers. **`momentary_outage_s` is derived, not chosen:** `momentary_outage_s ≥ 1.5 × (auto_reclose_delay_gs / 60) × auto_reclose_max_attempts` = `1.5 × 1.5 × 2` = **4.50 s** at doc 04's current tuning, recomputed here from the old 2.50 s (which failed its own derivation for the two-attempt case). Test 24 reads both `data/render.json` and `data/power.json` and asserts the inequality, so a retune in doc 04 fails the build instead of silently mis-classifying.

### Open questions for the overseer

15. **Does MVP ship all three presets, or Balanced only?** §6 currently cuts boot auto-detect and ships Balanced hard-coded for the slice, keeping the preset table and governor (both cheap). Confirm.
16. **Is 24 real minutes per day/night cycle right for the night read?** At 60× the player sees ~12 minutes of night per cycle. That suits noir, but the *day* look gets half the attention for the same art cost. I am designing night-first and would like that confirmed.
17. **`ReflectionProbe` on High.** Godot Mobile supports probes, but I have not measured one at 256 m extents on a Tensor G3. Gated to High and marked removable — cut from MVP outright?
18. **Landscape-only, but which aspect ratios?** §2.13's re-derived frustum math assumes 16:9 (`tan(hfov/2) = tan 20° × 16/9 = 0.64706`). A 20:9 phone gives `tan 20° × 20/9 = 0.80882`, widening the ground footprint 25% — at Z2 that is `216,108 × 1.25 = 270,135` m² = 16.5 blocks. **Recomputed against the corrected three-row Z2 and the pure ceiling rule (reports RR-12 and RR-14):** the row *depths* are unchanged (aspect ratio widens only the horizontal FOV, so `r_near`, `r_far` and therefore the 52.1 / 180 / 308 row origins are identical, and there is still no fourth row); only the columns per row grow.

```
row A  W = 533.4 × 1.25 = 666.8 m   → ⌈666.8/128⌉ = ⌈5.209⌉ → 6 columns   MEDIUM
row B  W = 623.8 × 1.25 = 779.8 m   → ⌈779.8/128⌉ = ⌈6.092⌉ → 7 columns   MEDIUM
row C  W = 717.2 × 1.25 = 896.5 m   → ⌈896.5/128⌉ = ⌈7.004⌉ → 8 columns   FAR
                                                       21 chunks = 13 MEDIUM + 8 FAR
opaque = 13·10 + 8·3 = 130 + 24 = 154;  total = 154 + 41 = 195  (201 with overlays)
```

Same pure-ceiling rule as §2.13, applied to the widened rows — note row C at `7.004` is a hair *over* 7 columns, so it genuinely takes 8; nothing here is a judgement call.

≈ **21 chunks instead of 16**, i.e. **+5 chunks = +36 draw calls** (`3 extra MEDIUM · 10 + 2 extra FAR · 3 = 36`; `195 − 159 = 36` ✓), taking Z2 from 159 to ≈ **195** against 320 — `(320 − 201)/320 = 37%` headroom on the with-overlay total, the same basis every other headroom figure in this doc uses. Absorbed by the 48% headroom at 16:9. *(The delta was published as +4 chunks / +26 calls against the discretionary-rounding 17, and as 26 chunks / 204 calls before RR-12 — both stale. The 20:9 column counts themselves are unchanged by RR-14; only the baseline they are differenced against moved.)* Unfolded 21:9 foldables would need the chunk budgets re-derived.
19b. **Does `flood_detail` earn its rung on the FOLD?** (§2.9b, 2026-08-20.) Three rungs measured at Z0 on a desktop RTX read 2.077 / 2.130 / 2.071 ms against 1.920 ms dry — the whole ladder is inside its own ±0.05 ms run-to-run spread, so on that GPU the flood layer costs its transparent BLEND and its overdraw and not its four `vnoise` calls. The Fold frame is fragment-bound (§2.13) with a very different ALU-to-bandwidth ratio, and Performance already ships rung 0 on the render-scale argument alone. The rung stays; what it needs is a device pass on the same A/B (`--flood=350 --flood-detail=0|1|2`), and if the device agrees with the desktop then the ladder should be deleted rather than left as a knob nobody can justify.
19. **Window colour as a monetization surface.** Spec §37.3 lists cosmetic city themes; `window_color` per family is a one-uniform change, making "Neo-Noir / Neon / Retro" themes nearly free post-alpha. The data layout already supports it — confirm no conflict with doc 03 (economy).
20. **`tests/fixtures/bench_city.json`: RULED AND CLOSED (report G-7).** **Doc 09 generates it** (`tools/gen_bench_city.py`, same generator family as the starter city); **doc 08 validates it** against the current save schema in CI; **this doc consumes it** (§7.2 test 19, §7.2 test 26, §7.4). The failure mode the question was raised about — the on-device gates silently stopping when the fixture goes stale — is now covered by test 26 on this side and by doc 08's CI check on the other.

---

## Amendments applied (report 98)

Every row of report 98 §12's worklist for doc 11, plus recomputation R-17 and Ruling Zero. Rulings are binding; where a ruling deleted something it is **removed**, not commented out, with a pointer to the owning doc.

| ruling | what changed here |
|---|---|
| **Ruling Zero** (§0) | Header note restated as the applied ruling rather than a proposal; §5 headings carry the canonical system titles; two mis-numbered references fixed in §2.12 (per-edge traffic density is **doc 10**, not doc 07; `vehicle_state` comes from **doc 06**, not doc 08); doc 13 no longer titled "& audio" (see G-3). Former §9 conflict 10 closed. |
| **C-38** | Doc 04's flag renamed `district_dark` → **`block_dark`** everywhere it appears (§2.7.2 step 6 shader term, §4 events, §5, §9 item 5). Renderer-side identifiers are `block_id`, never `district_id`, including the outward events `render_blackout_started/relight_started/relight_peak`. Doc 09's aggregate `district_dark` is not consumed here. Name change only — no behaviour moved. *(This row originally also claimed the carrying event kept its name; that claim is **deleted and superseded by RR-1** below — the event is `BlockDarkChanged`, owned and emitted by doc 04 §4.)* |
| **C-39** | §2.7.3's relight sweep now consumes **`restore_order: PackedInt32Array`** as its primary ordering (`delay_i = 2.2 · k_i / max(n−1,1) + anim_phase_i · 0.5`), with the original distance sweep retained as an explicit fallback and the block centroid as a second fallback. Streetlights take `0.80 ×` the delay of their nearest ranked building. `powered_fraction` is consumed from day one (§2.7.4). `plan_relight()` signature updated in §4. Tests 12 and 12b split into ordering and fallback paths. §9 items 4 and 13 closed. |
| **C-40** | `momentary_outage_s` recorded as **derived, not chosen**, and recomputed from the stated inequality: `1.5 × (90/60) × 2 = ` **4.50 s** (was 2.50 s, which mis-classified the two-attempt reclose case). Classification bands in §2.7.5 re-cut at `< 0.33 / 0.33–4.50 / > 4.50`, with the population-separation table (1.50 s, 3.00 s, ≥ 11.0 s). New headless test 24 reads **both** `data/render.json` and `data/power.json` and asserts the inequality plus the dead-band check. Test 14 recomputed. §9 item 14 rewritten as a recorded dependency. |
| **C-58** | §2.9 consumes **`precip01`** from doc 07 throughout — rain `amount_ratio`, splash `amount_ratio = precip01²`, and the wetness integrator target. Worked values added (35 mm/h → 1.00; 7 mm/h → 0.20 rain / 0.04 splash; saturation at `precip01 ≥ 0.834`). §5 doc 07 and test 20 updated; §9 item 7 closed. |
| **C-63** | This doc owns the **projection** (`FOV 40°`, near 1, far 1600); the **interaction range is doc 12's** (`D_MIN 18`, `D_MAX 420`, `pitch 34°→62°`) and both halves now live in `data/render.json` §8, which `data/ui.json` references. §2.5's zoom table regenerated to Z0 `18 m / 34°`, Z1 `86.9 m / 48°`, Z2 `420 m / 62°`, reproducing doc 12 §2.16's worked example exactly. The old logarithmic pinch line is deleted (doc 12 owns `D(t)`/`pitch(t)`), as are `yaw_snap_deg`, `pan_damping` and `zoom_damping` → doc 12's `data/ui.json`. §5 doc 12 handshake restated as ruled. |
| **R-17 / C-63** | **§2.13's frustum and draw-call derivation fully regenerated** with the generating formulas stated above the tables. The claim "the entire city is FAR at max zoom" and the 143-call Z2 figure are deleted as wrong. New results: Z2 camera height 370.8 m, ground trapezoid 359.7 m deep × 485→717 m = 216,108 m² (13.19 blocks), **21 chunks = 10 MEDIUM + 11 FAR + 0 NEAR**, **174 draw calls** (180 with overlays) against 320. Z1 re-derived as the sizing pose (6 chunks, all NEAR, **215**); Z0 **157**. LOD distance clarified to the chunk's **ground-plane** AABB (test 19b). `medium_max_m` **kept at 420** with the ~10-calls-per-MEDIUM-chunk option taken, and the rejected `medium_max_m = 360` alternative shown with its arithmetic (104 calls, but the skyline loses LOD1's roof signatures). `near_chunk_max` raised **2/4/6 → 3/6/8** with the shadow arithmetic. `civ_visible_radius_m` re-derived **400 → 420 m**. Test 19 regenerated per pose; §9 item 18 recomputed for 20:9. *(**Superseded in part by RR-12 below:** this row's Z2 figures — 21 chunks = 10 MEDIUM + 11 FAR, 174 calls, 180 with overlays, 44% headroom, the 104-call rejected alternative, and the 26-chunk/204-call 20:9 note — all counted a chunk row that cannot exist. The corrected Z2 is **17 chunks = 11 MEDIUM + 6 FAR, 169 calls**. Everything else in this row stands, including the geometry, the `near_chunk_max` raise and `civ_visible_radius_m`.)* |
| **C-64** | **Four** building overlay states confirmed; 2-bit field and packing constant `112` locked; `SELECTED` recorded as a UI-layer `MarkerLayer` outline, never a per-instance state. Test 17's 448-combination round-trip stands. §9 item 9 closed. |
| **C-66** | This doc **owns `occupancy_hour_curve` per building family** (residential / commercial / industrial / tech / civic), authored as six keyframes each in `data/render.json` §8, multiplied by doc 02's structural `occ_b`. §2.7.1's formula and its whole worked-example table regenerated at `occ_b = 0.92`: **0.9640 / 0.5997 / 0.05 / 0.22 / 0.035** → **925 / 576 / 48 / 211 / 34** lit windows (was 0.955 / 0.708 → 917 / 680). Test 9 expectations recomputed; test 9b added for the curves. Recorded as art, not simulation — no sim input, no save state. §9 item 6 closed. |
| **C-68** | New **§2.7.6**: on a snapshot flagged `is_resync: true`, emissive state, streetlights and `chunk_power` **snap** to target, all queued plans are dropped, and the relight/blackout events are suppressed for that snapshot. `apply_snapshot()` added to §4. New test 25. §5 doc 08 restated as ruled rather than an ask. |
| **G-3** | **Audio is owned by this doc**, deferred to Phase 2. New **§2.15** with the placeholder note (`game/audio/`, `AudioDirector`, `data/audio.json`, MVP ships silent) and the full event-hook table with the beat each sound is authored against. `game/audio/` added to the Owns line; §6 records the deferral explicitly; doc 13 no longer titled "& audio" in §5. |
| **G-7** | `tests/fixtures/bench_city.json` is **generated by doc 09** (`tools/gen_bench_city.py`), **validated by doc 08** in CI, **consumed here**. §7.4 restated; new test 26 as this doc's own tripwire against a stale fixture. §9 open question 20 closed. |
| *(consequential)* | **C-25 applied here although doc 11 is not in its amend list:** `render_prefs.schema_version` → **`section_version`** (the ruling is stated as universal and `render_prefs` is in the report §11 registry). `camera_zoom_s` → `camera_zoom_t` to match doc 12's parameter name; `last_overlay_mode` **deleted** → doc 12's `ui` save section per the registry. **C-14:** §2.7.1's `condition < 0.15` gate and §5's `BuildingView` restated on the ruled `[0,1]` scale. **C-59 / C-67 / C-69 / C-60 / C-61:** recorded in §5 and §9 (weather global-with-cell, explicit `speed`/`heading`, `SubViewport` composition, `AVENUE`/`STREET` classes, `block_road_access_score`). **Fog invariant:** §2.8 gains the explicit clamp `fog_depth_end_eff = min(profile.end, active_far_cull_m)` and `clear_day.end` drops 1500 → 1200, because the authored value violated the doc's own §7 test 23 at every preset. |

### Round 2 (report 98 §14 — post-verification rulings)

Applied after the adversarial verification pass (docs 96/97). Both rows are corrections to the first amendment wave, not new scope.

| ruling | what changed here |
|---|---|
| **RR-1** (verif F-1) | **The carrying event is `BlockDarkChanged`, not `DistrictDarkChanged`.** Doc 04 owns and already emits the renamed event; this doc had renamed only the *flag* and explicitly refused the carrier rename, so §2.7's blackout/relight — the doc's own thesis beat — was subscribed to a name nothing emits. Every consumption site is renamed: **§2.7.2** (go-dark trigger), **§2.7.3** (relight trigger), **§2.7.5** (`TotalBlackout` per-block relight), **§4** *Events consumed*, **§5** doc 04 events + the debounce paragraph. The claim *"the carrying event keeps its name `DistrictDarkChanged`; only the flag is renamed"* is **deleted** from §2.7.2 and from the C-38 row above — event naming is doc 04's, per report §0's ownership table (`sim/power/`). `data/render.json` §8 gains `blackout._carrying_event` naming the event. New **§7.3b test 27** asserts every doc-04 event this doc consumes exists on the emitter and that nothing subscribes to the old name — the missing cross-doc identifier check that let the rename land on one side only. No behaviour, timing or constant moved. |
| **RR-12** (verif S-12 / F-12) | **§2.13's Z2 chunk table regenerated; the phantom fourth row is deleted.** Chunks are 128 m, so from `r_near = 52.1` m the rows originate at **52.1 / 180.0 / 308.0** m and the next would originate at `308 + 128 = 436.0` m — beyond `r_far = 411.8` m. The old row D at `r = 412` was the trapezoid's far **edge** read as a row **origin** (`412 = 308 + 104`, not a 128 m multiple) and could not exist. Re-derived with columns `⌈w(r_far_of_row)/128⌉` from `w(r) = 2·sqrt(r²+370.8²)·0.64706` → `5 / 6 / 6`: **21 chunks (10 MEDIUM + 11 FAR) → 17 chunks (11 MEDIUM + 6 FAR + 0 NEAR)**; opaque **133 → 128**; Z2 total **174 → 169** (180 → 175 with overlays); Z2 headroom **44% → 45%**. Dependents recomputed: the rejected `medium_max_m = 360` alternative **`21·3 = 63` opaque / 104 total / saving 70 → `17·3 = 51` opaque / 92 total / saving 77**; the surplus quoted in that trade **146 → 151** calls; §2.5's forward reference **133 → 63** becomes **128 → 51** and its 44% becomes 45%; the Z2 instance check **630 → 510** instances; §9 item 18's 20:9 sensitivity **26 chunks / 204 calls → 21 chunks / 195 calls** (rows re-scaled at 6/7/8 columns — aspect ratio widens rows, it does not add one). **Test 19**'s Z2 row becomes **17 chunks / 11 MEDIUM + 6 FAR / 169 calls**, its tolerance changes from ±10% to an **absolute ±2 chunks (15–19)** because the residual spread is 128 m-grid alignment against the view axis (a hard 16…19 band a ±10% window would clip), and it gains a **phantom-row regression guard**: no chunk with nearest-edge `r ≥ 436` m may be tier-assigned at Z2. `data/render.json` §8 `lod` gains the `_z2_*` expectation keys and the derivation. **Every §2.13 conclusion survives** — the error was conservative: `medium_max_m` stays at 420, Z2 remains the shadow-free-but-not-cheapest pose (Z0 157 < Z2 169 < Z1 215), and the budget now clears at 320 even at the pathological 19-chunk alignment (182 calls, 188 with overlays, 41% headroom). *(**Superseded in part by RR-14 below:** this row's `5 / 6 / 6` column split kept a discretionary "4.874 → 6" rounding on row B. Under the pure ceiling the split is `5 / 5 / 6` and the corrected Z2 is **16 chunks = 10 MEDIUM + 6 FAR, 159 calls** (165 with overlays, 48% headroom), with the tolerance moving from ±2 to +3/−0. The phantom-row deletion, the three-row geometry, the regression guard and every conclusion in this row stand.)* |

### Round 3 (report 98 §15 — closing-audit rulings)

The final closeout pass. One ruling names this doc; it is an arithmetic correction inside §2.13, not new scope.

| ruling | what changed here |
|---|---|
| **RR-14** (audit N-2) | **The Z2 chunk rows use the pure ceiling `⌈W/128⌉` with no discretionary rounding.** Row B's `623.8/128 = 4.874` was published as "**5–6** → take 6" — a judgement call inside an arithmetic step, and a double count: the unfavourable-alignment column is already carried, once, by the grid-alignment band. The three rows are now `⌈533.4/128⌉ = ⌈4.167⌉ = 5`, `⌈623.8/128⌉ = ⌈4.874⌉ = 5`, `⌈717.2/128⌉ = ⌈5.603⌉ = 6`. Results: **17 chunks (11 MEDIUM + 6 FAR) → 16 chunks (10 MEDIUM + 6 FAR + 0 NEAR)**; opaque **128 → 118**; Z2 total **169 → 159** (**175 → 165** with overlays); Z2 headroom **45% → 48%** (`(320 − 165)/320 = 48.4%`). Dependents recomputed: the rejected `medium_max_m = 360` alternative **`17·3 = 51` opaque / 92 total / saving 77 → `16·3 = 48` opaque / 89 total / saving 70**; the surplus quoted in that trade **151 → 161** calls; §2.5's forward reference **128 → 51** becomes **118 → 48** and its 45% becomes 48%; the Z2 instance check **510 → 480** instances; §9 item 18's 20:9 delta **+4 chunks / +26 calls → +5 chunks / +36 calls** (the 20:9 column counts 6/7/8 and its 21-chunk / 195-call absolute figures are unchanged — only the 16:9 baseline they are differenced against moved, and its headroom basis is restated as "absorbed by 48%"). The **Z0 < Z2 < Z1** cost ordering survives but the Z0→Z2 gap narrows to **2 draw calls** (157 vs 159), and §2.13 now says so rather than implying comfortable separation. **Test 19**'s Z2 row becomes **16 chunks / 10 MEDIUM + 6 FAR / 159 calls**, and its tolerance changes from a symmetric **±2 chunks (15–19)** to an asymmetric **+3 / −0 chunks (16–19)**, because 16 is the band's *floor*, not a point inside it — a Z2 frame rendering fewer than 16 chunks is a culling bug, not a lucky alignment, and the old window let it pass. Test 19 also gains a **rounding guard**: with the view axis on a column centre, each row's column count must equal `⌈W_far_of_row/128⌉` exactly, so row B resolving to 6 fails. `data/render.json` §8 `lod`: `_z2_expected_chunks` **17 → 16**, `_z2_expected_tiers.medium` **11 → 10**, `_z2_expected_draw_calls` **169 → 159**; `_z2_expected_chunks_tolerance: 2` is replaced by `_z2_expected_chunks_tolerance_plus: 3` / `_z2_expected_chunks_tolerance_minus: 0`; new `_z2_expected_draw_calls_with_overlays: 165` and `_z2_expected_columns_per_row: [5, 5, 6]`; `_z2_derivation` restated to match. **Every §2.13 conclusion survives, and the error was again conservative:** `medium_max_m` stays at 420, the shadow pass is still empty at Z2, and the pathological 19-chunk alignment is untouched at 182 calls (188 with overlays, 41% headroom). |

**Nothing in this doc is blocked by report §13.** The renderer carries no priced tables, no `data/buildings.json` rows, no water constants and no starter-city dependency other than the bench fixture; `data/render.json` is implementable as amended.
