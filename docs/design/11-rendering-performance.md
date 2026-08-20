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
├── Props: MM_pole, MM_lamp, MM_pool, MM_wetsmear (MultiMeshInstance3D)
└── MM_blob  (MultiMeshInstance3D)  fake blob shadows, Performance preset only
```

**Rule: LOD is per chunk, not per building.** A chunk is 128 m; the narrowest LOD band is 150 m. Per-building LOD would triple MultiMesh count for no visible gain. This single decision is what keeps draw calls tractable (§2.13 worked example).

#### 2.1.1 Water (`game/shaders/water.gdshader`, `GroundSurface.water()`)

The third ground surface, and the only one that moves. **One material for every water quad in the city**, because the wave field is evaluated in **world space**: adjacent 8 m tiles are one body of water with the pattern crossing their seams, and driving it off UV instead would restart the noise at every quad and read as tiling. Constants are `water_surface` in `data/render.json`.

Two scrolling value-noise octaves at different scales, speeds and headings (7.5 m / 0.035 and 2.6 m / 0.11, crossing), their finite-difference gradients perturbing `NORMAL` so the specular highlight crawls; a fresnel-weighted lift toward `sky_color` at grazing angles; `sc_night` darkening the body to 0.34; a crest-power sparkle on the swell. `sc_wetness` roughens it into chop and kills the glare — the rain read everyone knows and nobody can name. `sc_overlay_mode` greys it back with every other surface, or an overlay leaves one glowing blue rectangle in a desaturated city.

**No reflection probe, at any preset.** §2.11 gates the ONE probe the game may own to High and to the city at large, and that probe is already flagged for on-device validation (§9). Water that needs a second one cannot ship on the mobile presets. The sky read is the fresnel term, which costs one dot product and lands within a few percent of a probe for a flat horizontal surface under a gradient sky at the camera's 34°–62° pitch band.

**Nothing animates on the CPU.** `sc_time` is already published for the window flicker; the water reads it. A `MultiMeshInstance3D` of water quads is touched once, at build time.

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

**Hysteresis:** upgrade at `edge − 20 m`, downgrade at `edge + 20 m`, at most one tier change per `lod_dwell_s = 0.5 s`.

**Only NEAR chunks cast shadows** (`cast_shadow = OFF` on all MEDIUM/FAR MultiMeshes), `directional_shadow_max_distance = 180 m`. Biggest single draw-call saving in the design.

**Consequence of the camera table (re-derived, report R-17).** At Z2 the camera sits `420·sin 62° = 370.8` m up, so *every* rendered chunk is at least 370.8 m away and **no chunk is ever NEAR at Z2** — the shadow pass is empty. But 370.8 m is inside the MEDIUM band (`≤ 420 m`), so the nearest two chunk rows are **MEDIUM, not FAR**: the pre-amendment claim that "the entire city is FAR at max zoom" was wrong at a 420 m zoom ceiling and is deleted. The correct statement is: **Z2 is the shadow-free pose, not the cheapest one.** §2.13 re-derives the numbers; the cheapest pose is now Z0.

**Why `medium_max_m` stays at 420 m.** Report C-63 allows either raising `medium_max_m` or accepting ~10 draw calls per chunk at max zoom. Raising it only converts FAR chunks into MEDIUM and makes Z2 *more* expensive. Restoring the all-FAR result would instead require *lowering* `medium_max_m` below 370.8 m — arithmetic in §2.13 — which buys 118 → 48 opaque calls at Z2 but renders the entire skyline as the shared 12-tri box, discarding exactly the LOD1 roof signatures §2.14 authors "to preserve archetype readability at 400 m". **Ruling: keep `medium_max_m = 420`, accept ~10 calls per MEDIUM chunk.** The budget carries it with 48% headroom.

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

**Materials.** Material lives on the generated `ArrayMesh` surface, shared across levels and chunks: **2 `Shader` resources total** (building, far), instanced as 15 archetypes × 5 levels × 2 LODs = 150 `ShaderMaterial`s differing only in uniforms (`window_cols/rows/color`). Two pipeline states for the entire city — the number that matters on tiled mobile GPUs. Gate: `RENDER_TOTAL_SHADER_COMPILES_IN_FRAME == 0` after warm-up.

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

### 2.10 Streetlights without hundreds of dynamic lights

One streetlight every 32 m (4 tiles) along road polylines from doc 10. With doc 09's ~87 road tiles per developed block that is **~22 streetlights per chunk**. Lit state is **not** inferred by the renderer: doc 04 emits `StreetlightsChanged(block_id, lit)` per land block, and every streetlight in that chunk shares that one boolean, ramped through the §2.7 envelopes. Four instances across MultiMeshes:

1. `MM_pole` — 6-tri cylinder + arm, lit material, NEAR/MEDIUM only.
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

### 2.11 Overlay mechanism (doc 12 owns content)

`sc_overlay_mode ≠ 0` switches every building and ground shader into overlay mode:

```glsl
vec3 tint = sc_overlay_colors[int(overlay)].rgb;
ALBEDO    = mix(vec3(dot(ALBEDO, vec3(0.299,0.587,0.114))), tint, 0.55);
EMISSION *= 0.40;
```

Network lines (power feeders, water mains, congestion) draw as **one `ImmediateMesh` per overlay layer per 4×4-chunk super-block**: line strips, unshaded additive, `render_priority = 5`, no depth write, UV scrolled by `sc_time · flow_speed` where `flow_speed` is signed by real flow direction (spec §13.5 "animated power flow"). Rebuilt only on `network_topology_changed`; the animation itself is free. Budget ≤ 6 extra draw calls at any zoom.

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

**Performance replaces shadows with blob shadows:** `MM_blob`, one dark radial-gradient quad per building at `y = 0.04`, footprint × 1.15, alpha `0.35·(1 − sc_night·0.6)`. One extra draw call per NEAR/MEDIUM chunk, and the difference between "buildings sit on the ground" and "buildings float".

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

**Per-chunk draw calls** (unchanged by the camera ruling): NEAR = 8 building buckets + 2 ground/road + 3 props = **13**; MEDIUM = 6 + 2 + 2 = **10**; FAR = 1 + 1 + 1 = **3**. Performance adds 1 blob-shadow call per NEAR/MEDIUM chunk.

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
  3 NEAR·(13+1 blob) + 3 MEDIUM·(10+1) = 42 + 33 = 75; + veh 6 + wx 1 + sky 4 + UI 25 = 111  ✓
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

**Frame cost** — `tools/profile_frame.gd`, 1920×1080, Balanced, hour 21:00 (the emissive/glow worst case), 60 warm-up frames discarded, 240 measured. **Dev workstation, NVIDIA RTX 2000 Ada, Forward+ — this is not a phone and not the Mobile renderer.** It is a *relative* measurement: the draw-call and chunk columns are platform-independent and are the ones the budget is written against; the millisecond columns are here to show where the cost sits, not to claim a device result.

| pose | mean ms | p95 ms | RS cpu | RS gpu | draw calls | +UI | budget | bucket nodes | NEAR | MED | FAR |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Z0 `D 18 / 34°` | 10.83 | 11.11 | 0.13 | 0.83 | 92 | 117 | 320 | 591 | 12 | 24 | 0 |
| Z1 `D 86.9 / 48°` | 11.20 | 13.33 | 0.17 | 2.23 | 133 | 158 | 320 | 591 | 8 | 28 | 0 |
| **Z2 `D 420 / 62°`** | 11.64 | 14.29 | 0.28 | 2.67 | **327** | **352** | **320** | 279 | **0** | 16 | 20 |
| *starter city, Z2, for scale* | 0.96 | 1.23 | 0.06 | 0.83 | 80 | 105 | 320 | 18 | 0 | 9 | 0 |

`RS cpu` / `RS gpu` are the RenderingServer's own measured times for the viewport; they do **not** sum to `mean ms` — the remainder (~8–9 ms) is the render layer's per-frame GDScript plus present.

Three results, in order of how much they matter:

1. **Z2 is over the Balanced draw-call budget: 352 against 320.** Not by a rounding error, and not for the reason §2.13's derivation would predict. The derivation's per-chunk cost model (8 building buckets NEAR, 6 MEDIUM) assumes a chunk holds about six distinct `archetype:level` combinations. The bench city's mix gives **591 bucket nodes across 36 chunks — 16.4 per chunk**, because a real block holds five archetypes at four levels rather than one archetype at one. Every §2.13 conclusion that rests on "10 calls per MEDIUM chunk" is optimistic by roughly 1.7× on a mixed city. *The fix is bucket merging (one MultiMesh per chunk per LOD, with the mesh selected by instance custom data) and it is not in this change; it is filed as a defect against §2.6.* Note that **the empty Z2 shadow pass survives intact** — 0 NEAR chunks, exactly as §2.13 claims, and that claim is what keeps the number at 352 rather than several hundred more.
2. **The frame is main-thread bound, not GPU bound, and it scales with the city.** 0.96 ms per frame on 34 buildings against 11.64 ms on 1,500, while the GPU column moves only 0.83 → 2.67 ms. `CityView.refresh` flushes every dirty instance unbudgeted (`flush_dirty(camera_pos, 1000000)`), re-tiers every chunk, and walks all 591 bucket nodes on every frame. §2.2's `multimesh_instance_writes_per_frame = 2000` budget is authored but not enforced by the bring-up path.
3. **The instance budget is comfortable.** 1,500 resident instances against a 7,000 Balanced budget, 100,906 primitives at the densest pose. Nothing in §2.13's instance or VRAM arithmetic is threatened.

**Bus volume** — `tools/qa_soak.gd`, 0.25 real-hour session on the starter city, before and after the D-10 diet:

| | events on the bus | share |
|---|---|---|
| before (one `vehicle_state` per vehicle per tick) | 55,675 | `vehicle_state` = 44,153 = **79.3%** |
| **after** (one packed `traffic_snapshot` per tick) | **18,221** | `traffic_snapshot` = 6,699 events carrying the same 44,153 poses |

**3.05× less traffic on the bus**, and the 44,153 dictionaries became 6,699 events of five packed buffers. Save identity is unchanged and proved rather than asserted: `tools/profile_sim.gd --hash-only --baseline=…` reports `BEHAVIOUR UNCHANGED` on both the starter and the bench city, on both the fine and the coarse path. The bus is not persisted (`SimEventBus` keeps no history), so this was true by construction; the baseline check is what makes it checked.

**The governor, as shipped.** `game/render/perf_governor.gd` implements the ladder and the holds above and doc 13 §2.8's thermal policy, as a model with no Node and no engine singleton — which is what lets `tests/test_perf_governor.gd` drive the 5 s and 30 s holds in microseconds. Settings row `auto_quality` ("Auto quality", `data/ui.json`), **default on**, device-scoped. Two behaviours worth stating because they are choices, not consequences: switching the row **off freezes the knobs where they stand** rather than restoring the preset (a quality *jump* is the one thing a manual-control switch must not cause), and a preset the *player* picks resets the ladder and clears a latched drop, because their choice outranks the governor's.

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

Level identity = height + a **cumulative** marker: L1 none; L2 +1 rooftop box; L3 +setback at 60% height; L4 +crown band (0.5 m inset ring) + 2 masts; L5 +spire with blinking red aviation beacon. Height = `floors(archetype, level) · 3.5 m`; `res_highrise` uses spec §9.3 — 12/24/36/48/62 floors → 42/84/126/168/217 m.

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

---

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
- Decorative pedestrians (spec §29.1 explicitly allows them as visual-only; not slice content).
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
19b. **LOD-distance rule:** tier assignment uses the chunk's ground-plane AABB. Place a 217 m `res_highrise` in the chunk directly under the Z2 camera and assert the chunk still tiers **MEDIUM** — the building-inclusive AABB would give `sqrt(52² + (370.8−217)²) = 162 m` and wrongly promote it to NEAR, re-arming the shadow pass at max zoom.

### 7.3 Headless — weather / day-night

20. **Wetness integrator:** `precip01 = 1.0` for 60 s → `sc_wetness ≥ 0.90`; then `precip01 = 0` for 300 s → `≤ 0.05`; monotonic within each phase. Also assert continuity: stepping `precip01` through doc 07's segment-boundary lerp produces no `|Δ sc_wetness|` above `delta/tau` in any frame — the C-58 guarantee the renderer depends on.
21. **Lightning envelope:** sampled at 240 Hz — exactly two local maxima, peak 1.0 at t = 0.02, 0.0 at t ≥ 0.30, never exceeds 1.0.
22. **Day/night curve:** `sc_night(hour)` continuous across the 24 h wrap (|Δ| < 0.02 at the seam), 0.00 at 12:00, 1.00 at 00:00, ≥ 0.30 by 18:15.
23. **Fog invariant:** for every weather × time × preset combination **and every governor knob position**, the *effective* fog range obeys `fog_depth_end_eff ≤ far_cull_m` and `fog_depth_begin_eff < fog_depth_end_eff` after §2.8's clamp. Assert the clamp actually fires on Performance (`clear_day` authored 1200 vs `far_cull 900`) rather than being masked by authoring.

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

### 7.4 On-device — `tools/bench_flythrough.gd` + adb

A deterministic 90 s camera path over `tests/fixtures/bench_city.json` — **generated by doc 09 (`tools/gen_bench_city.py`, same generator family as the starter city), validated by doc 08 against the current save schema in CI, consumed here** (report G-7, ruled; former §9 open question 20 is closed). Contents **as shipped** (see §2.13's as-shipped table): a 7×7 world with a **6×6 developed core (36 blocks)**, **1,500 buildings** across L1–L5, 3,132 road tiles, ~780 streetlight props, and the civic roster that houses the emergency fleet. *(The pre-build figures were "~1,100 buildings" and an 8×8 world; the count moved to doc 91's 1,500 — the size this section's device matrix is written against — and the world stayed 7×7 because `TileGrid.BLOCKS` is 7. Doc 09 §2.13's profile table carries the same numbers.)* The device harness is `tools/bench_device.sh`, which drives the three scenarios below over adb and collects both our `PERF` lines and the platform's `gfxinfo`/`meminfo`/`thermalservice` output; it ships ready and **has not been run against a device yet**. Three scenarios:

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
                    "pool_rebind_hz": 4.0, "pool_crossfade_s": 0.25 },

  "vehicles": { "civ_spawn_per_m": 0.0222, "civ_visible_radius_m": 420.0,
                "civ_body_tris_max": 90, "emergency_body_tris_max": 180,
                "lightbar_hz": 2.2, "lightbar_emission": 3.5,
                "lightbar_red": "#FF2A22", "lightbar_blue": "#2A5CFF",
                "interp_teleport_threshold_m": 40.0, "headlight_night_threshold": 0.15 },

  "blob_shadow": { "enabled_presets": ["performance"], "y_m": 0.04,
                   "footprint_scale": 1.15, "alpha": 0.35, "night_fade": 0.6 },

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
