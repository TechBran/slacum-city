class_name RenderStateModel
extends RefCounted
## All render bookkeeping and arithmetic for the city view (doc 11 §2.2, §2.3,
## §2.5, §2.6, §2.7).
##
## Deliberately a RefCounted with NO Node dependency: ~90% of rendering logic is
## headless-testable this way (doc 11 §2.3). `RenderBridge` and `ChunkView` are
## thin Node shells over this class.
##
## Time is a parameter, never a wall clock: `advance(delta)` drives every ramp
## and `set_hour()` / `apply_snapshot()` supply sim time. Every constant comes
## from `data/render.json` (constitution §2, §12) — this file holds rules only.

const TIER_NEAR := 0
const TIER_MEDIUM := 1
const TIER_FAR := 2
const TIER_CULLED := 3
const TIER_NAMES := ["NEAR", "MEDIUM", "FAR", "CULLED"]

const OVERLAY_NORMAL := 0
const OVERLAY_WARNING := 1
const OVERLAY_CRITICAL := 2
const OVERLAY_OFFLINE := 3

## §2.6 packed-state constants. `112 = 16 * 7`: 16 variants x 7 stages.
const PACK_VARIANT_SPAN := 16
const PACK_STAGE_SPAN := 7
const PACK_OVERLAY_STRIDE := 112
const INSTANCE_STRIDE := 16  # 12 transform floats + 4 custom-data floats

const RAMP_IDLE := 0
const RAMP_EXP := 1       # exponential approach (blackout fall, plain changes)
const RAMP_RELIGHT := 2   # inrush overshoot curve

const POWER_LIT := &"LIT"

# ------------------------------------------------------------------- config

var cfg: Dictionary = {}
var preset: String = "balanced"

var chunk_m: float = 128.0
var near_max_m: float = 150.0
var medium_max_m: float = 420.0
var far_cull_m: float = 1200.0
## The active preset's authored `far_cull_m` — the ceiling `apply_governor`
## clamps to, so a governor step can shorten the draw distance but never extend
## it past the quality level the player selected.
var preset_far_cull_m: float = 1200.0
## Doc 11 §2.5b — the PITCH-COUPLED cull distance actually in force, and the
## number `raw_tier` reads. It is `far_cull_m` (i.e. the preset's, as the
## governor may have shortened it) clamped down to what the frustum can
## actually reach at the camera's current pitch. Equal to `far_cull_m` until a
## caller supplies a pitch, so a model nobody poses behaves exactly as it did
## before §2.5b — which is what every existing tier test relies on.
var active_far_cull_m: float = 1200.0
## Whether §2.5b is armed at all (`lod.pitch_cull.enabled`), and the pitch the
## last `update_chunk_tiers` was given (< 0 = "no pitch supplied").
var pitch_cull_enabled: bool = true
var culling_pitch_deg: float = -1.0
## Half the VERTICAL field of view — the angle between the camera's forward
## axis and the TOP edge of the frustum, which is the edge that decides how far
## along the ground the frustum reaches. Seeded from `camera.fov_deg`.
var pitch_cull_fov_margin_deg: float = 20.0
## `[[pitch_deg, slack], …]`, piecewise-linear. See `pitch_cull_reach_m`.
var pitch_cull_slack: Array = []
## The cull may never come inside this. Authored as `lod.medium_max_m`: §2.5b
## is allowed to remove FAR chunks and is never allowed to touch the tier the
## player is looking at.
var pitch_cull_floor_m: float = 420.0
## The aspect assumed when no caller can see a viewport. Wider than any box the
## game ships on, so an unknown aspect errs towards culling nothing.
var pitch_cull_max_aspect: float = 2.40
var hysteresis_m: float = 20.0
var lod_dwell_s: float = 0.5

var zoom_min_dist_m: float = 18.0
var zoom_max_dist_m: float = 420.0
var pitch_min_deg: float = 34.0
var pitch_max_deg: float = 62.0

var writes_per_frame: int = 2000
var bucket_granularity: int = 32
var max_instances_per_bucket: int = 256
var max_animating: int = 1200
var bulk_upload_threshold: int = 8

var emissive_cfg: Dictionary = {}
var blackout_cfg: Dictionary = {}
var occupancy_curves: Dictionary = {}

# ------------------------------------------------------------------- state

var _recs: Dictionary = {}        # id -> BuildingRec
var _chunks: Dictionary = {}      # Vector2i -> ChunkRec
var _blocks: Dictionary = {}      # block_id -> BlockRec
var _streetlights: Dictionary = {}  # id -> StreetlightRec
## SHAPE -> int, for the bucket-key packing. A shape is the archetype for
## everything doc 02 owns outright and `water_facility_<variant>` for the doc-05
## shells that have their own massing (Wave 31, RR-254) — see `ShapeCatalog`.
## Buckets are keyed by shape and not by archetype because the MESH is: a tank
## and a pump in one chunk at one level are two meshes on two footprints and
## cannot share a MultiMesh.
var _shape_ids: Dictionary = {}
var _shape_order: Array = []
## The (archetype, variant) → shape map, read from the gray-box manifest. Held
## rather than asked statically per building so a harness can inject its own.
var _shapes: ShapeCatalog = null
var _animating: Array = []        # ids, insertion-ordered
var _out_events: Array = []
var _suppress_events: bool = false

# --------------------------------------------------- overlay channels (§2.5)
#
# Doc 12 §2.5's overlays past POWER are per-building READS of a system that is
# not the emissive ladder: WATER is doc 05's service factor, and the ones after
# it will be their own. Rather than grow a channel in the instance buffer per
# system — 2 bits are all §2.6 packs and C-64 fixes that — each system pushes a
# whole `{render_id: state}` table here and it is MAPPED ONTO `overlay_state`
# only while its mode is the active one. Exiting the mode restores every
# building's own state exactly, so the damage/destroyed states doc 11 owns
# survive a round trip through any overlay.
#
# `_overlay_base` is what makes that true: while a channel is applied it holds
# the pre-overlay value for every id the channel touched, and every OTHER write
# to `overlay_state` (events, snapshots) is routed through `_write_overlay` so
# it lands on the base instead of being clobbered on exit.
var _overlay_channels: Dictionary = {}   # StringName mode -> {int id: int state}
var _overlay_base: Dictionary = {}       # int id -> int, only while overridden
var _overlay_mode: StringName = &"none"

var time_s: float = 0.0           # model clock, advanced only by advance()
var hour: float = 21.0            # game hour, 0..24 (art input, §2.7.1)


# ------------------------------------------------------------------- records

class BuildingRec extends RefCounted:
	var id: int = 0
	var block_id: Variant = 0
	var chunk := Vector2i.ZERO
	var bucket_key: int = 0
	var slot: int = -1
	var archetype: StringName = &""
	## `Building.variant` — doc 05's own name for a water shell (`pump`, `tank`,
	## `treatment`, `source`), empty for everything doc 02 owns outright.
	var variant_id: StringName = &""
	## The MESH this building draws with: the archetype, or the variant's own
	## shape where one exists. Buckets are keyed on it (Wave 31, RR-254).
	var shape: StringName = &""
	var level: int = 1
	var family: String = "residential"
	var world_pos := Vector3.ZERO
	var transform := Transform3D.IDENTITY
	## The ground this building actually holds, in tiles — `built_of_building`.
	## `Vector2i.ZERO` when the view did not say, which means "take the mesh's".
	var built_tiles := Vector2i.ZERO
	## What the transform's basis was scaled by to fit the mesh into
	## `built_tiles`. 1.0 on every building whose mesh is already the right size,
	## which is every one of them once a variant has its own shape.
	var footprint_scale := Vector2.ONE

	var occ_b: float = 1.0
	var powered: bool = true
	var has_backup_power: bool = false
	var priority_load: bool = false
	var damage: float = 0.0
	var condition: float = 1.0
	var stage: int = 0
	var overlay_state: int = 0

	var variant: int = 0
	var anim_phase: float = 0.0

	var emissive_cur: float = 0.0
	var emissive_target: float = 0.0
	var emissive_delay: float = 0.0
	var ramp_mode: int = 0
	var ramp_t: float = 0.0


class StreetlightRec extends RefCounted:
	var id: int = 0
	var block_id: Variant = 0
	var chunk := Vector2i.ZERO
	var world_pos := Vector3.ZERO
	var anim_phase: float = 0.0
	var lit_target: float = 1.0
	var cur: float = 1.0
	var delay: float = 0.0
	var ramp_mode: int = 0
	var ramp_t: float = 0.0


class BlockRec extends RefCounted:
	var block_id: Variant = 0
	var chunk := Vector2i.ZERO
	var buildings: Array = []
	var streetlights: Array = []
	var dark: bool = false
	var powered_fraction: float = 1.0
	var dark_since: float = -1.0
	var envelope_t: float = -1.0     # < 0 = inactive
	var ground_dark: float = 0.0     # 0 lit .. 1 dark, ramped
	var relight_active: bool = false
	var relight_t: float = 0.0
	var relight_peak_fired: bool = true
	var relight_duration: float = 0.0


class Bucket extends RefCounted:
	var key: int = 0
	var chunk := Vector2i.ZERO
	## The doc-02 archetype — what the bucket wears (texture pages, family).
	var archetype: StringName = &""
	## The SHAPE — what the bucket DRAWS. Equal to `archetype` except on a doc-05
	## water variant with its own massing. The manifest, the merged atlas and the
	## far/blob scales are all keyed on this (Wave 31, RR-254).
	var shape: StringName = &""
	var level: int = 1
	var capacity: int = 0
	var visible_count: int = 0
	var mirror := PackedFloat32Array()
	var slot_owner := PackedInt32Array()
	var free_slots: Array = []
	var dirty: Dictionary = {}


class ChunkRec extends RefCounted:
	var coord := Vector2i.ZERO
	var tier: int = -1
	var dwell: float = 0.0
	var buckets: Dictionary = {}
	var buildings: Array = []


# --------------------------------------------------------------------- setup

func _init(render_cfg: Dictionary = {}, preset_name: String = "balanced") -> void:
	configure(render_cfg, preset_name)


static func load_config(path: String = "res://data/render.json") -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


func configure(render_cfg: Dictionary, preset_name: String = "balanced") -> void:
	cfg = render_cfg
	preset = preset_name
	var world: Dictionary = cfg.get("world", {})
	chunk_m = float(world.get("chunk_m", chunk_m))

	var lod: Dictionary = cfg.get("lod", {})
	near_max_m = float(lod.get("near_max_m", near_max_m))
	medium_max_m = float(lod.get("medium_max_m", medium_max_m))
	hysteresis_m = float(lod.get("hysteresis_m", hysteresis_m))
	lod_dwell_s = float(lod.get("dwell_s", lod_dwell_s))

	var cam: Dictionary = cfg.get("camera", {})
	zoom_min_dist_m = float(cam.get("zoom_min_dist_m", zoom_min_dist_m))
	zoom_max_dist_m = float(cam.get("zoom_max_dist_m", zoom_max_dist_m))
	pitch_min_deg = float(cam.get("pitch_min_deg", pitch_min_deg))
	pitch_max_deg = float(cam.get("pitch_max_deg", pitch_max_deg))

	# §2.5b. The FOV margin is HALF the vertical FOV and is derived from
	# `camera.fov_deg` rather than authored twice — a projection constant with
	# two homes is a projection constant that will disagree with itself.
	var pitch_cull: Dictionary = lod.get("pitch_cull", {})
	pitch_cull_enabled = bool(pitch_cull.get("enabled", true))
	pitch_cull_fov_margin_deg = 0.5 * float(cam.get("fov_deg", 40.0))
	pitch_cull_slack = pitch_cull.get("slack", [])
	pitch_cull_floor_m = float(pitch_cull.get("floor_m", medium_max_m))
	pitch_cull_max_aspect = float(pitch_cull.get("max_aspect", pitch_cull_max_aspect))

	var streaming: Dictionary = cfg.get("streaming", {})
	writes_per_frame = int(streaming.get("multimesh_instance_writes_per_frame", writes_per_frame))
	bucket_granularity = int(streaming.get("bucket_alloc_granularity", bucket_granularity))
	max_instances_per_bucket = int(streaming.get("max_instances_per_bucket", max_instances_per_bucket))
	max_animating = int(streaming.get("max_animating_buildings", max_animating))
	bulk_upload_threshold = int(streaming.get("bulk_upload_dirty_threshold", bulk_upload_threshold))

	emissive_cfg = cfg.get("emissive", {})
	blackout_cfg = cfg.get("blackout", {})
	occupancy_curves = cfg.get("occupancy_hour_curve", {})
	set_preset(preset_name)


func set_preset(preset_name: String) -> void:
	preset = preset_name
	var presets: Dictionary = cfg.get("presets", {})
	if presets.has(preset_name):
		far_cull_m = float((presets[preset_name] as Dictionary).get("far_cull_m", far_cull_m))
	preset_far_cull_m = far_cull_m
	active_far_cull_m = far_cull_m


## §2.13's adaptive governor, knob 3 (`far_cull_m`, −128 m per step, floor
## 600 m). `game/render/perf_governor.gd` owns the ladder and the hysteresis; all
## that reaches the model is the value in force, and `raw_tier` picks it up on
## the very next `update_chunk_tiers` — a shortened cull distance moves chunks
## straight to `TIER_CULLED` and `CityView` stops submitting them.
##
## The model deliberately holds `preset_far_cull_m` separately: a preset change
## must re-base the ceiling (that is what `set_preset` does), while a governor
## step must never be able to *raise* the cull beyond the preset the player
## chose. Anything the governor sends is clamped to that ceiling here rather
## than trusted, because this is the layer the LOD arithmetic actually reads.
func apply_governor(knobs: Dictionary) -> void:
	if not knobs.has("far_cull_m"):
		return
	far_cull_m = clampf(float(knobs["far_cull_m"]), 1.0, preset_far_cull_m)
	# §2.5b composes by MINIMUM with the ladder, and the ladder wins whenever it
	# is the tighter of the two: a governor in trouble must not be undone by a
	# camera that happens to be looking down.
	active_far_cull_m = minf(active_far_cull_m, far_cull_m)


## Census of the tiers actually assigned right now — `{near, medium, far,
## culled}`. Doc 11 §7.2 test 19 asserts against it at the three §2.5 poses and
## §7.4's PERF line reports it, which is why it lives here (the model owns the
## tiers) rather than being recounted by each caller.
func tier_census() -> Dictionary:
	var out := {"near": 0, "medium": 0, "far": 0, "culled": 0}
	for coord in _chunks:
		match (_chunks[coord] as ChunkRec).tier:
			TIER_NEAR: out["near"] = int(out["near"]) + 1
			TIER_MEDIUM: out["medium"] = int(out["medium"]) + 1
			TIER_FAR: out["far"] = int(out["far"]) + 1
			TIER_CULLED: out["culled"] = int(out["culled"]) + 1
	return out


func set_hour(h: float) -> void:
	hour = fposmod(h, 24.0)
	_retarget_all()


# ------------------------------------------------------------- hashes (§2.3)

## Deterministic 32-bit mix — the renderer's own hash so `variant`/`anim_phase`
## never depend on engine hash internals (doc 11 §9 item 1: render-side
## randomness is not part of sim determinism and is never persisted).
static func hash_u32(x: int) -> int:
	var h := x & 0xFFFFFFFF
	h = (h ^ (h >> 16)) * 0x7FEB352D & 0xFFFFFFFF
	h = (h ^ (h >> 15)) * 0x2545F491 & 0xFFFFFFFF
	h = (h ^ (h >> 16)) & 0xFFFFFFFF
	return h


static func variant_of(id: int) -> int:
	return hash_u32(id) & (PACK_VARIANT_SPAN - 1)


static func anim_phase_of(id: int) -> float:
	return float((hash_u32(id) >> 4) & 0xFFFF) / 65535.0


## Stable per-building [0,1) used by the fractional-outage rule (§2.7.4).
static func hash01(id: int) -> float:
	return float(hash_u32(id ^ 0x9E3779B9) & 0xFFFFFF) / 16777216.0


## Mirrors the shader's `hash21` so the lit-window count is testable headlessly
## (§7.2 test 10).
static func hash21(cell: Vector2, seed_v: float = 0.0) -> float:
	var p := cell + Vector2(seed_v, seed_v)
	var n := sin(p.dot(Vector2(12.9898, 78.233))) * 43758.5453
	return n - floor(n)


## Number of lit window cells for `e = emissive_scale` — `lit = step(1-e, h)`.
func lit_window_count(cols: int, rows: int, faces: int, e: float, variant: int = 0) -> int:
	var lit := 0
	var seed_v := float(variant) * 37.0
	for f in faces:
		for cx in cols:
			for cy in rows:
				var cell := Vector2(float(cx + f * cols), float(cy))
				if hash21(cell, seed_v) >= 1.0 - e:
					lit += 1
	return lit


# ----------------------------------------------------------- custom data §2.6

static func pack_state(variant: int, stage: int, overlay: int) -> float:
	return float(variant + PACK_VARIANT_SPAN * stage + PACK_OVERLAY_STRIDE * overlay)


static func unpack_state(packed: float) -> Dictionary:
	return {
		"variant": int(fposmod(packed, float(PACK_VARIANT_SPAN))),
		"stage": int(fposmod(floor(packed / float(PACK_VARIANT_SPAN)), float(PACK_STAGE_SPAN))),
		"overlay": int(floor(packed / float(PACK_OVERLAY_STRIDE))),
	}


## The four custom-data channels for one building: (emissive, damage, packed, phase).
func custom_data(id: int) -> Color:
	var rec: BuildingRec = _recs.get(id)
	if rec == null:
		return Color(0, 0, 0, 0)
	return Color(emissive_out(id), rec.damage,
			pack_state(rec.variant, rec.stage, rec.overlay_state), rec.anim_phase)


## Emissive actually written to the instance buffer: the ramp state modulated by
## the block-wide brownout stutter envelope (§2.7.2 step 1).
func emissive_out(id: int) -> float:
	var rec: BuildingRec = _recs.get(id)
	if rec == null:
		return 0.0
	return maxf(0.0, rec.emissive_cur * _envelope_mult(rec.block_id))


# ------------------------------------------------------------------- shapes

## The (archetype, variant) → shape map this model resolves buildings with.
## Defaults to the process-wide catalogue over the shipped manifest.
func shapes() -> ShapeCatalog:
	if _shapes == null:
		_shapes = ShapeCatalog.shared()
	return _shapes


## Inject a catalogue — a harness with its own manifest, or a test that wants a
## variant the shipped meshes do not carry. Buildings already added keep the
## shape they were resolved with; call before populating.
func set_shapes(catalog: ShapeCatalog) -> void:
	_shapes = catalog


## **The overhang guard** (Wave 31, RR-256). How far the instance basis must be
## squeezed on X/Z so the mesh sits INSIDE the ground the sim says this building
## holds. `Vector2.ONE` — the whole city, today — whenever the mesh's own
## footprint already fits.
##
## It exists for the variant that has no shape of its own yet. `booster` is the
## live one: doc 05 §6 defers it, so it draws with `water_facility`'s 3×3 pump
## shell, and on its 1×1 L1 footprint that shell would put **8 m of building over
## every edge** — four times the defect the player reported. Scaled, it is a
## squat pump house on one tile: wrong-looking, and standing on its own ground.
##
## It only ever SHRINKS. A mesh smaller than the built footprint is a building
## with room around it, which is what the lot dressing is for (§2.16a) and not a
## reason to inflate the art. And Y is never touched: the height is the
## archetype's own and `build_height_m`'s construction clamp is written against
## it, so scaling it would make a half-built building the wrong fraction.
func footprint_scale_for(shape: StringName, level: int,
		built_tiles: Vector2i) -> Vector2:
	if built_tiles.x <= 0 or built_tiles.y <= 0:
		return Vector2.ONE
	var mesh_tiles := shapes().footprint_of(shape, level)
	if mesh_tiles.x <= 0 or mesh_tiles.y <= 0:
		return Vector2.ONE
	return Vector2(
			minf(1.0, float(built_tiles.x) / float(mesh_tiles.x)),
			minf(1.0, float(built_tiles.y) / float(mesh_tiles.y)))


# -------------------------------------------------------- building lifecycle

## `view` mirrors doc 11 §5's BuildingView plus the chunk/block the renderer
## places it in: {id, archetype_id, variant_id, level, chunk, block_id,
## world_pos, family, occ_b, powered, has_backup_power, priority_load, damage,
## condition, construction_stage, overlay_state, transform, built_tiles}.
##
## `variant_id` and `built_tiles` are Wave 31's (RR-254/RR-256) and both are
## optional: `variant_id` picks the doc-05 shape and defaults to "this archetype
## has no variants"; `built_tiles` is `CitySim.built_of_building` and is what the
## overhang guard divides the mesh footprint into. A producer that supplies
## neither gets exactly the model it got before this pass.
func add_building(view: Dictionary) -> BuildingRec:
	var id := int(view["id"])
	if _recs.has(id):
		remove_building(id)
	var rec := BuildingRec.new()
	rec.id = id
	rec.archetype = StringName(view.get("archetype_id", &""))
	rec.variant_id = StringName(view.get("variant_id", &""))
	rec.level = int(view.get("level", 1))
	rec.shape = shapes().shape_of(rec.archetype, rec.variant_id)
	rec.family = String(view.get("family", "residential"))
	rec.world_pos = view.get("world_pos", Vector3.ZERO)
	rec.chunk = view.get("chunk", chunk_of(rec.world_pos))
	rec.block_id = view.get("block_id", rec.chunk)
	rec.built_tiles = view.get("built_tiles", Vector2i.ZERO)
	rec.transform = view.get("transform", Transform3D(Basis.IDENTITY, rec.world_pos))
	rec.footprint_scale = footprint_scale_for(rec.shape, rec.level, rec.built_tiles)
	if rec.footprint_scale != Vector2.ONE:
		# LOCAL scale, so the mesh shrinks along its OWN axes: `basis * from_scale`
		# and not `basis.scaled()`, which scales in the parent frame. Identical on
		# the identity bases every producer of a BuildingView writes today, and
		# correct the day one of them writes a yaw.
		rec.transform = Transform3D(
				rec.transform.basis * Basis.from_scale(
						Vector3(rec.footprint_scale.x, 1.0, rec.footprint_scale.y)),
				rec.transform.origin)
	rec.occ_b = float(view.get("occ_b", 1.0))
	rec.powered = bool(view.get("powered", true))
	rec.has_backup_power = bool(view.get("has_backup_power", false))
	rec.priority_load = bool(view.get("priority_load", false))
	rec.condition = float(view.get("condition", 1.0))
	# Doc 02 §2.6: damage IS `1 − condition`. A view that supplies a condition
	# and no damage used to spawn at soot 0 whatever shape the building was in,
	# so `building.gdshader`'s soot ramp and the `damage_dim_gain` on the
	# emissive were dead channels on every worn building in the city — which is
	# the whole "which one needs repair?" cue (doc 12 §2.9 item 6).
	rec.damage = float(view.get("damage",
			clampf(1.0 - rec.condition, 0.0, 1.0)))
	rec.stage = int(view.get("construction_stage", 0))
	rec.overlay_state = int(view.get("overlay_state", OVERLAY_NORMAL))
	rec.variant = variant_of(id)
	rec.anim_phase = anim_phase_of(id)
	rec.emissive_target = emissive_target_for(rec)
	rec.emissive_cur = rec.emissive_target
	rec.ramp_mode = RAMP_IDLE

	_recs[id] = rec
	var chunk := _chunk_rec(rec.chunk)
	chunk.buildings.append(id)
	var block := _block_rec(rec.block_id, rec.chunk)
	block.buildings.append(id)
	_alloc_slot(rec)
	# A building placed while an overlay is up joins it immediately rather than
	# waiting for the next publish — a fresh lot that reads NORMAL under the
	# water overlay when it has no water yet is a lie the player would act on.
	var live: Variant = _overlay_channels.get(_overlay_mode, {})
	if live is Dictionary and (live as Dictionary).has(id):
		_apply_overlay_table({id: int((live as Dictionary)[id])})
	return rec


func remove_building(id: int) -> void:
	var rec: BuildingRec = _recs.get(id)
	if rec == null:
		return
	_free_slot(rec)
	var chunk := _chunk_rec(rec.chunk)
	chunk.buildings.erase(id)
	var block := _block_rec(rec.block_id, rec.chunk)
	block.buildings.erase(id)
	_animating.erase(id)
	_overlay_base.erase(id)
	_recs.erase(id)


# ------------------------------------------------- overlay channels (§2.5)

## Publish one overlay's per-building states: `{render_id: 0..3}`, the same four
## `OVERLAY_*` values doc 11 packs. Additive by construction — a system that has
## not published leaves the buildings alone — and idempotent, so the shell can
## call it every hour with the whole city.
##
## Only the ACTIVE mode's channel is on screen; the rest are held and applied
## the moment the player selects them, which is what makes switching overlays a
## repaint rather than a round trip to the sim.
func set_overlay_channel(mode: StringName, states: Dictionary) -> int:
	var table: Dictionary = {}
	for key: Variant in states:
		table[int(key)] = clampi(int(states[key]), OVERLAY_NORMAL, OVERLAY_OFFLINE)
	_overlay_channels[mode] = table
	if mode != _overlay_mode:
		return table.size()
	# Live: re-point the override at the new table. Ids that dropped out of it
	# go back to their own state; ids that joined save theirs first.
	_restore_overlay_base(table)
	_apply_overlay_table(table)
	return table.size()


func clear_overlay_channel(mode: StringName) -> void:
	if mode == _overlay_mode:
		_restore_overlay_base({})
	_overlay_channels.erase(mode)


func overlay_channel(mode: StringName) -> Dictionary:
	var table: Variant = _overlay_channels.get(mode, {})
	return (table as Dictionary).duplicate() if table is Dictionary else {}


func overlay_mode() -> StringName:
	return _overlay_mode


## The rail's `overlay_changed` lands here. Leaving a mode restores every
## building's own `overlay_state` byte for byte; entering one applies that
## mode's channel if it has published, and is a no-op if it has not.
func set_overlay_mode(mode: StringName) -> void:
	if mode == _overlay_mode:
		return
	_overlay_mode = mode
	var raw: Variant = _overlay_channels.get(mode, {})
	var table: Dictionary = raw if raw is Dictionary else {}
	_restore_overlay_base(table)
	_apply_overlay_table(table)


## The value a building would carry with no overlay applied — its own state.
func base_overlay_state(id: int) -> int:
	if _overlay_base.has(id):
		return int(_overlay_base[id])
	var rec: BuildingRec = _recs.get(id)
	return rec.overlay_state if rec != null else OVERLAY_NORMAL


## Writes a building's OWN overlay state. While a channel is overriding that
## building the write lands on the saved base, so a fire that breaks out during
## a water overlay is still there when the player turns the overlay off.
func _write_overlay(rec: BuildingRec, value: int) -> void:
	var clamped := clampi(value, OVERLAY_NORMAL, OVERLAY_OFFLINE)
	if _overlay_base.has(rec.id):
		_overlay_base[rec.id] = clamped
		return
	rec.overlay_state = clamped
	_mark_dirty(rec)


## Puts back every override that `keep` does not carry forward.
func _restore_overlay_base(keep: Dictionary) -> void:
	var ids: Array = _overlay_base.keys()
	ids.sort()
	for id: int in ids:
		if keep.has(id):
			continue
		var rec: BuildingRec = _recs.get(id)
		if rec != null:
			rec.overlay_state = int(_overlay_base[id])
			_mark_dirty(rec)
		_overlay_base.erase(id)


func _apply_overlay_table(table: Dictionary) -> void:
	var ids: Array = table.keys()
	ids.sort()
	for id: int in ids:
		var rec: BuildingRec = _recs.get(id)
		if rec == null:
			continue
		if not _overlay_base.has(id):
			_overlay_base[id] = rec.overlay_state
		var state := int(table[id])
		if rec.overlay_state == state:
			continue
		rec.overlay_state = state
		_mark_dirty(rec)


## Register a lamp, or MOVE one that is already registered.
##
## Idempotent by construction, and that is the point rather than a nicety.
## `BlockRec.streetlights` is the list §2.7.2's go-dark stagger and §2.7.3's
## relight sweep iterate, and it used to be appended to unconditionally: calling
## this twice for one id put the id in the block TWICE, so every ramp that block
## drove ran the lamp's envelope through `_advance_streetlight` a second time in
## the same frame and the blackout stuttered — the double-stutter the streets
## branch filed. Re-registering now updates the record in place and, when the
## lamp changed block, moves the single list entry across.
func add_streetlight(id: int, block_id: Variant, world_pos: Vector3) -> StreetlightRec:
	var rec: StreetlightRec = _streetlights.get(id)
	if rec != null:
		if rec.block_id != block_id:
			var old: BlockRec = _blocks.get(rec.block_id)
			if old != null:
				old.streetlights.erase(id)
			rec.block_id = block_id
			_block_rec(block_id, chunk_of(world_pos)).streetlights.append(id)
		rec.world_pos = world_pos
		rec.chunk = chunk_of(world_pos)
		return rec
	rec = StreetlightRec.new()
	rec.id = id
	rec.block_id = block_id
	rec.world_pos = world_pos
	rec.chunk = chunk_of(world_pos)
	rec.anim_phase = anim_phase_of(id)
	_streetlights[id] = rec
	_block_rec(block_id, rec.chunk).streetlights.append(id)
	return rec


## Retire a lamp: the record stops being ticked by `advance()` and its id leaves
## the block roster, so nothing downstream can reach a lamp that is no longer
## drawn. Unknown ids are ignored, which is what makes a re-place pass a plain
## set difference at the call site.
##
## Used by the live re-place on a road edit (`StreetlightView.apply_lamps`) —
## before it existed a player who bulldozed a street left the lamp ramping in
## the model for the rest of the session, and its id in `BlockRec.streetlights`
## for the rest of the session's blackouts.
func remove_streetlight(id: int) -> bool:
	var rec: StreetlightRec = _streetlights.get(id)
	if rec == null:
		return false
	var b: BlockRec = _blocks.get(rec.block_id)
	if b != null:
		b.streetlights.erase(id)
	_streetlights.erase(id)
	return true


func streetlight_count() -> int:
	return _streetlights.size()


## The lamp ids this block darkens with, in registration order. Exposed because
## the duplicate-id hazard above is invisible from `streetlight_count()`.
func block_streetlight_ids(block_id: Variant) -> Array:
	var b: BlockRec = _blocks.get(block_id)
	return [] if b == null else b.streetlights.duplicate()


func building(id: int) -> BuildingRec:
	return _recs.get(id)


func streetlight(id: int) -> StreetlightRec:
	return _streetlights.get(id)


func block(block_id: Variant) -> BlockRec:
	return _blocks.get(block_id)


func building_count() -> int:
	return _recs.size()


func chunk_of(world_pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(world_pos.x / chunk_m)), int(floor(world_pos.z / chunk_m)))


func _chunk_rec(coord: Vector2i) -> ChunkRec:
	if not _chunks.has(coord):
		var c := ChunkRec.new()
		c.coord = coord
		_chunks[coord] = c
	return _chunks[coord]


func _block_rec(block_id: Variant, chunk: Vector2i = Vector2i.ZERO) -> BlockRec:
	if not _blocks.has(block_id):
		var b := BlockRec.new()
		b.block_id = block_id
		b.chunk = chunk
		_blocks[block_id] = b
	return _blocks[block_id]


# ------------------------------------------------------- slot allocator §2.2

## Keyed on the SHAPE, not the archetype (Wave 31, RR-254): the bucket owns one
## MultiMesh over one mesh, so a `tank` and a `pump` at the same level in the
## same chunk are two buckets. For everything doc 02 owns outright the shape IS
## the archetype and this key is bit-for-bit the one it always was.
func _bucket_key(shape: StringName, level: int) -> int:
	if not _shape_ids.has(shape):
		_shape_ids[shape] = _shape_order.size()
		_shape_order.append(shape)
	return (int(_shape_ids[shape]) << 3) | (level & 7)


func bucket(chunk: Vector2i, shape: StringName, level: int) -> Bucket:
	var c := _chunk_rec(chunk)
	return c.buckets.get(_bucket_key(shape, level))


func buckets_of(chunk: Vector2i) -> Array:
	var c := _chunk_rec(chunk)
	var out: Array = []
	for k in c.buckets:
		out.append(c.buckets[k])
	return out


func _alloc_slot(rec: BuildingRec) -> void:
	var c := _chunk_rec(rec.chunk)
	var key := _bucket_key(rec.shape, rec.level)
	rec.bucket_key = key
	var b: Bucket = c.buckets.get(key)
	if b == null:
		b = Bucket.new()
		b.key = key
		b.chunk = rec.chunk
		b.archetype = rec.archetype
		b.shape = rec.shape
		b.level = rec.level
		c.buckets[key] = b
	if b.visible_count + 1 > b.capacity:
		_grow_bucket(b, b.visible_count + 1)
	rec.slot = b.visible_count
	b.slot_owner[rec.slot] = rec.id
	b.visible_count += 1
	b.free_slots = _tail_free_slots(b)
	_write_slot(b, rec)
	b.dirty[rec.slot] = true
	assert(b.visible_count <= max_instances_per_bucket,
			"bucket over %d instances — doc 11 §2.2 assertion" % max_instances_per_bucket)


## O(1) removal: the last live slot's 16 floats are copied over the freed slot
## and `slot_owner` patched, so the buffer never develops holes (§2.2).
func _free_slot(rec: BuildingRec) -> void:
	var c := _chunk_rec(rec.chunk)
	var b: Bucket = c.buckets.get(rec.bucket_key)
	if b == null or rec.slot < 0:
		return
	var last := b.visible_count - 1
	if rec.slot != last:
		var moved_id := b.slot_owner[last]
		for i in INSTANCE_STRIDE:
			b.mirror[rec.slot * INSTANCE_STRIDE + i] = b.mirror[last * INSTANCE_STRIDE + i]
		b.slot_owner[rec.slot] = moved_id
		var moved: BuildingRec = _recs.get(moved_id)
		if moved != null:
			moved.slot = rec.slot
		b.dirty[rec.slot] = true
	b.slot_owner[last] = -1
	b.visible_count -= 1
	b.dirty.erase(last)
	b.free_slots = _tail_free_slots(b)
	rec.slot = -1


func _tail_free_slots(b: Bucket) -> Array:
	var out: Array = []
	for s in range(b.visible_count, b.capacity):
		out.append(s)
	return out


func _grow_bucket(b: Bucket, needed: int) -> void:
	var g := maxi(1, bucket_granularity)
	var new_cap := int(ceil(float(needed) / float(g))) * g
	var old_cap := b.capacity
	b.mirror.resize(new_cap * INSTANCE_STRIDE)
	b.slot_owner.resize(new_cap)
	for i in range(old_cap, new_cap):
		b.slot_owner[i] = -1
	b.capacity = new_cap


func _write_slot(b: Bucket, rec: BuildingRec) -> void:
	if rec.slot < 0:
		return
	var base := rec.slot * INSTANCE_STRIDE
	var t := rec.transform
	b.mirror[base + 0] = t.basis.x.x
	b.mirror[base + 1] = t.basis.y.x
	b.mirror[base + 2] = t.basis.z.x
	b.mirror[base + 3] = t.origin.x
	b.mirror[base + 4] = t.basis.x.y
	b.mirror[base + 5] = t.basis.y.y
	b.mirror[base + 6] = t.basis.z.y
	b.mirror[base + 7] = t.origin.y
	b.mirror[base + 8] = t.basis.x.z
	b.mirror[base + 9] = t.basis.y.z
	b.mirror[base + 10] = t.basis.z.z
	b.mirror[base + 11] = t.origin.z
	var custom := custom_data(rec.id)
	b.mirror[base + 12] = custom.r
	b.mirror[base + 13] = custom.g
	b.mirror[base + 14] = custom.b
	b.mirror[base + 15] = custom.a


func mirror_custom(chunk: Vector2i, shape: StringName, level: int, slot: int) -> Color:
	var b := bucket(chunk, shape, level)
	if b == null or slot < 0 or slot >= b.visible_count:
		return Color(0, 0, 0, 0)
	var base := slot * INSTANCE_STRIDE
	return Color(b.mirror[base + 12], b.mirror[base + 13], b.mirror[base + 14],
			b.mirror[base + 15])


func _mark_dirty(rec: BuildingRec) -> void:
	if rec.slot < 0:
		return
	var c := _chunk_rec(rec.chunk)
	var b: Bucket = c.buckets.get(rec.bucket_key)
	if b != null:
		b.dirty[rec.slot] = true


func dirty_instance_count() -> int:
	var n := 0
	for coord in _chunks:
		var c: ChunkRec = _chunks[coord]
		for k in c.buckets:
			n += (c.buckets[k] as Bucket).dirty.size()
	return n


# ------------------------------------------------------------ camera and LOD

func camera_distance_m(zoom_t: float) -> float:
	var t := clampf(zoom_t, 0.0, 1.0)
	return zoom_min_dist_m * pow(zoom_max_dist_m / zoom_min_dist_m, t)


func camera_pitch_deg(zoom_t: float) -> float:
	var t := clampf(zoom_t, 0.0, 1.0)
	return pitch_min_deg + (pitch_max_deg - pitch_min_deg) * smoothstep(0.0, 1.0, t)


## §2.5 camera rig: pivot at the ground focus, camera at (0, D sin p, D cos p)
## rotated by yaw. Doc 12 owns {focus, zoom_t, yaw}; this derives the transform.
func camera_position(focus: Vector3, zoom_t: float, yaw_deg: float) -> Vector3:
	var d := camera_distance_m(zoom_t)
	var p := deg_to_rad(camera_pitch_deg(zoom_t))
	var offset := Vector3(0.0, d * sin(p), d * cos(p))
	return focus + offset.rotated(Vector3.UP, deg_to_rad(yaw_deg))


## Distance from the camera to the nearest point of the chunk's GROUND-PLANE
## AABB — never the building-inclusive AABB (§2.5, test 19b).
func chunk_ground_distance(chunk: Vector2i, camera_pos: Vector3) -> float:
	var x0 := float(chunk.x) * chunk_m
	var z0 := float(chunk.y) * chunk_m
	var x1 := x0 + chunk_m
	var z1 := z0 + chunk_m
	var dx := maxf(maxf(x0 - camera_pos.x, camera_pos.x - x1), 0.0)
	var dz := maxf(maxf(z0 - camera_pos.z, camera_pos.z - z1), 0.0)
	return sqrt(dx * dx + dz * dz + camera_pos.y * camera_pos.y)


## Doc 11 §2.5b — how far along the ground this camera's frustum actually
## reaches, in metres from the camera's ground point, measured at the TOP
## CORNERS of the frame.
##
## THE GEOMETRY, and why the corner and not the centre. Take the camera basis
## pitched `θ` below horizontal. A top-corner ray is
## `right·tan(h½) + up·tan(v½) + forward`, whose vertical component is
## `tan(v½)·cos θ − sin θ` and whose horizontal magnitude is
## `√(tan(h½)² + (tan(v½)·sin θ + cos θ)²)`; the ground it reaches is the
## camera height times their ratio. The CENTRE of the top edge reaches only
## `h / tan(θ − v½)` — 412 m at the Z2 pose, which is exactly the `r_far 411.9`
## `lod._z2_derivation` computes by hand and is the check that this function is
## the same geometry that paragraph is. **The corners reach 532 m at that same
## pose, 29 % further**, and a cull drawn at the centre figure would delete
## chunks that are visible in the top corners of the frame. The first draft of
## this function used the centre figure; the corner form is the one that
## shipped.
##
## WHY THE BOUND IS EXACT, at any building height. Past the range where the top
## ray meets the ground that ray is below ground, so EVERY point at that range
## — at any altitude, tower tops included — sits above the frame's top edge and
## is off-screen. The reach is therefore a true horizon and not a heuristic,
## which is what makes culling at it safe rather than merely cheap.
##
## WHY IT IS NOT A CURVE IN PITCH ALONE. The reach scales with camera HEIGHT as
## much as with pitch: at the 34° floor it is 48 m from the Z0 pose and 1,111 m
## from the Z2 pose, a factor of 23. One multiplier keyed on pitch cannot
## express both, which is why the authored `slack` multiplies this COMPUTED
## reach rather than multiplying `far_cull_m`.
##
## `aspect` is width/height of the render target, because `h½` is derived from
## the vertical FOV through it (Godot's `KEEP_HEIGHT` default) and a wider frame
## reaches further at its corners. Callers that cannot see a viewport pass the
## authored `max_aspect`, which is wider than any box the game ships on, so an
## unknown aspect errs towards culling nothing.
##
## Returns INF when the top ray clears the horizon (`θ ≤ v½`), which is the
## honest answer: a frustum that sees sky reaches forever, and only
## `far_cull_m` can stop it.
func pitch_cull_reach_m(camera_y: float, pitch_deg: float,
		aspect: float = -1.0) -> float:
	var v_half := deg_to_rad(pitch_cull_fov_margin_deg)
	var theta := deg_to_rad(pitch_deg)
	var tan_v := tan(v_half)
	var descent := sin(theta) - tan_v * cos(theta)
	if descent <= 0.001:
		return INF
	var tan_h := tan_v * (aspect if aspect > 0.0 else pitch_cull_max_aspect)
	var forward_ground := tan_v * sin(theta) + cos(theta)
	var horizontal := sqrt(tan_h * tan_h + forward_ground * forward_ground)
	return maxf(0.0, camera_y) * horizontal / descent * _pitch_slack(pitch_deg)


## The authored `lod.pitch_cull.slack` curve, piecewise-linear in pitch and
## flat outside its ends. An empty curve is slack 1.0 — the bare geometry.
func _pitch_slack(pitch_deg: float) -> float:
	if pitch_cull_slack.is_empty():
		return 1.0
	var first: Array = pitch_cull_slack[0]
	if pitch_deg <= float(first[0]):
		return float(first[1])
	for i in range(pitch_cull_slack.size() - 1):
		var a: Array = pitch_cull_slack[i]
		var b: Array = pitch_cull_slack[i + 1]
		if pitch_deg <= float(b[0]):
			var span := maxf(0.0001, float(b[0]) - float(a[0]))
			return lerpf(float(a[1]), float(b[1]),
					(pitch_deg - float(a[0])) / span)
	return float((pitch_cull_slack[pitch_cull_slack.size() - 1] as Array)[1])


## §2.5b's composition, in one place: the pitch cull may only ever SHORTEN the
## draw distance, may never come inside `pitch_cull_floor_m`, and loses to the
## governor whenever the governor is tighter. `pitch_deg < 0` means "no pitch
## supplied" and leaves `far_cull_m` standing untouched.
func set_camera_pose(camera_y: float, pitch_deg: float,
		aspect: float = -1.0) -> void:
	culling_pitch_deg = pitch_deg
	if not pitch_cull_enabled or pitch_deg < 0.0:
		active_far_cull_m = far_cull_m
		return
	var reach := pitch_cull_reach_m(camera_y, pitch_deg, aspect)
	if is_inf(reach):
		active_far_cull_m = far_cull_m
		return
	# `reach` is a GROUND range and `chunk_ground_distance` is the 3-D distance
	# from the camera — which is why `medium_max_m` 420 corresponds to a ground
	# r of 197.3 m at Z2 in `_z2_derivation` and not to 420 m of ground. The
	# two metrics have to be reconciled or the cull comes in by the camera
	# height, which at Z2 is 371 m of it.
	var d := sqrt(reach * reach + camera_y * camera_y)
	active_far_cull_m = clampf(d, minf(pitch_cull_floor_m, far_cull_m),
			far_cull_m)


func tier_band_max(tier: int) -> float:
	match tier:
		TIER_NEAR: return near_max_m
		TIER_MEDIUM: return medium_max_m
		TIER_FAR: return active_far_cull_m
		_: return INF


func raw_tier(dist: float) -> int:
	if dist <= near_max_m:
		return TIER_NEAR
	if dist <= medium_max_m:
		return TIER_MEDIUM
	if dist <= active_far_cull_m:
		return TIER_FAR
	return TIER_CULLED


## §2.5: upgrade at `edge - hysteresis`, downgrade at `edge + hysteresis`, at
## most one tier step per `lod_dwell_s`. `cur_tier < 0` means "no tier yet".
func lod_for(dist: float, cur_tier: int, dwell: float) -> int:
	var target := raw_tier(dist)
	if cur_tier < 0:
		return target
	if target == cur_tier:
		return cur_tier
	if dwell < lod_dwell_s:
		return cur_tier
	if target < cur_tier:
		# more detail: must be inside the upper edge of the next tier up
		var next_tier := cur_tier - 1
		if dist <= tier_band_max(next_tier) - hysteresis_m:
			return next_tier
		return cur_tier
	# less detail: must be outside this tier's edge plus hysteresis
	if dist > tier_band_max(cur_tier) + hysteresis_m:
		return cur_tier + 1
	return cur_tier


## Advances per-chunk dwell timers and applies `lod_for` to every known chunk.
## Returns {chunk: tier} for the chunks whose tier changed this call.
func update_chunk_tiers(camera_pos: Vector3, delta: float,
		pitch_deg: float = -1.0, aspect: float = -1.0) -> Dictionary:
	# §2.5b, applied here because this is the one call that already knows where
	# the camera IS and is the only reader of the answer.
	set_camera_pose(camera_pos.y, pitch_deg, aspect)
	var changed: Dictionary = {}
	for coord in _sorted_chunk_coords():
		var c: ChunkRec = _chunks[coord]
		c.dwell += delta
		var dist := chunk_ground_distance(coord, camera_pos)
		var tier := lod_for(dist, c.tier, c.dwell)
		if tier != c.tier:
			c.tier = tier
			c.dwell = 0.0
			changed[coord] = tier
	return changed


func chunk_tier(coord: Vector2i) -> int:
	var c: ChunkRec = _chunks.get(coord)
	return c.tier if c != null else -1


func set_chunk_tier(coord: Vector2i, tier: int) -> void:
	var c := _chunk_rec(coord)
	c.tier = tier
	c.dwell = 0.0


func _sorted_chunk_coords() -> Array:
	var out: Array = []
	for coord in _chunks:
		out.append(coord)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x == b.x:
			return a.y < b.y
		return a.x < b.x)
	return out


# ----------------------------------------------------- emissive targets §2.7.1

func occupancy_curve(family: String, at_hour: float) -> float:
	var keys: Array = occupancy_curves.get(family, [])
	if keys.is_empty():
		return 1.0
	var h := fposmod(at_hour, 24.0)
	var n := keys.size()
	var first: Array = keys[0]
	var last: Array = keys[n - 1]
	if h <= float(first[0]):
		# wrap segment: last key -> first key + 24
		var span := 24.0 - float(last[0]) + float(first[0])
		var t := (h + 24.0 - float(last[0])) / maxf(0.0001, span)
		return lerpf(float(last[1]), float(first[1]), t)
	if h >= float(last[0]):
		var span2 := 24.0 - float(last[0]) + float(first[0])
		var t2 := (h - float(last[0])) / maxf(0.0001, span2)
		return lerpf(float(last[1]), float(first[1]), t2)
	for i in range(n - 1):
		var a: Array = keys[i]
		var b: Array = keys[i + 1]
		if h >= float(a[0]) and h <= float(b[0]):
			var t3 := (h - float(a[0])) / maxf(0.0001, float(b[0]) - float(a[0]))
			return lerpf(float(a[1]), float(b[1]), t3)
	return float(last[1])


func emissive_target_for(rec: BuildingRec) -> float:
	var occ := rec.occ_b * occupancy_curve(rec.family, hour)
	var e := 0.0
	if rec.powered:
		e = float(emissive_cfg.get("powered_base", 0.55)) \
				+ float(emissive_cfg.get("powered_occ_gain", 0.45)) * occ
	elif rec.has_backup_power:
		e = float(emissive_cfg.get("backup_lit", 0.22))
	else:
		e = float(emissive_cfg.get("dark_lit", 0.05))
	e *= 1.0 - float(emissive_cfg.get("damage_dim_gain", 0.50)) * rec.damage
	if rec.condition < float(emissive_cfg.get("condition_critical_threshold", 0.15)):
		e *= float(emissive_cfg.get("condition_critical_mult", 0.40))
	return clampf(e, 0.0, 1.0)


func _retarget_all(animate: bool = true) -> void:
	for id in _recs:
		_retarget(_recs[id], animate)


func _retarget(rec: BuildingRec, animate: bool = true) -> void:
	rec.emissive_target = emissive_target_for(rec)
	if animate:
		if not is_equal_approx(rec.emissive_cur, rec.emissive_target):
			rec.ramp_mode = RAMP_EXP
			_touch_animating(rec.id)
	else:
		rec.emissive_cur = rec.emissive_target
		rec.ramp_mode = RAMP_IDLE
	_mark_dirty(rec)


func _touch_animating(id: int) -> void:
	if not _animating.has(id):
		_animating.append(id)


# --------------------------------------------------------- blackout §2.7.2

func _envelope_keys() -> Array:
	return blackout_cfg.get("stutter_envelope", [])


func _envelope_value(t: float) -> float:
	var keys := _envelope_keys()
	if keys.is_empty():
		return 1.0
	var first: Array = keys[0]
	if t <= float(first[0]):
		return float(first[1])
	var last: Array = keys[keys.size() - 1]
	if t >= float(last[0]):
		return float(last[1])
	for i in range(keys.size() - 1):
		var a: Array = keys[i]
		var b: Array = keys[i + 1]
		if t >= float(a[0]) and t <= float(b[0]):
			var span := maxf(0.0001, float(b[0]) - float(a[0]))
			return lerpf(float(a[1]), float(b[1]), (t - float(a[0])) / span)
	return float(last[1])


func _envelope_mult(block_id: Variant) -> float:
	var b: BlockRec = _blocks.get(block_id)
	if b == null or b.envelope_t < 0.0:
		return 1.0
	return _envelope_value(b.envelope_t)


func envelope_mult(block_id: Variant) -> float:
	return _envelope_mult(block_id)


## Per-chunk ground/road albedo multiplier (§2.7.2 step 6).
func chunk_power_mult(block_id: Variant) -> float:
	var b: BlockRec = _blocks.get(block_id)
	if b == null:
		return 1.0
	return lerpf(1.0, float(blackout_cfg.get("ground_darken_mult", 0.45)), b.ground_dark)


## §2.7.2. `powered_fraction < 1` keeps a stable hashed subset lit (§2.7.4).
func plan_blackout(block_id: Variant, powered_fraction: float = 0.0) -> void:
	var b := _block_rec(block_id)
	b.dark = true
	b.powered_fraction = clampf(powered_fraction, 0.0, 1.0)
	b.dark_since = time_s
	b.envelope_t = 0.0
	b.relight_active = false
	var stagger := float(blackout_cfg.get("stagger_s", 0.35))
	for id in b.buildings:
		var rec: BuildingRec = _recs.get(id)
		if rec == null:
			continue
		rec.powered = _stays_powered(rec, b.powered_fraction)
		rec.emissive_target = emissive_target_for(rec)
		rec.emissive_delay = rec.anim_phase * stagger
		rec.ramp_mode = RAMP_EXP
		rec.ramp_t = 0.0
		_touch_animating(id)
		_mark_dirty(rec)
	var sl_mult := float(blackout_cfg.get("streetlight_delay_mult", 0.60))
	for sid in b.streetlights:
		var sl: StreetlightRec = _streetlights.get(sid)
		if sl == null:
			continue
		sl.lit_target = 0.0
		sl.delay = sl.anim_phase * stagger * sl_mult
		sl.ramp_mode = RAMP_EXP
	_emit(&"render_blackout_started", {"block_id": block_id})


func _stays_powered(rec: BuildingRec, powered_fraction: float) -> bool:
	if powered_fraction >= 1.0:
		return true
	if powered_fraction <= 0.0:
		return false
	if rec.priority_load:
		return true
	return hash01(rec.id) < powered_fraction


## Which buildings of a block stay lit at a given fraction — stable by hash,
## never random (§2.7.4).
func powered_set(block_id: Variant, powered_fraction: float) -> Array:
	var b: BlockRec = _blocks.get(block_id)
	var out: Array = []
	if b == null:
		return out
	for id in b.buildings:
		var rec: BuildingRec = _recs.get(id)
		if rec != null and _stays_powered(rec, powered_fraction):
			out.append(id)
	return out


# --------------------------------------------------------- relight §2.7.3/5

## `restore_order` first (report C-39), `source_pos` then block centroid as
## fallbacks. Classifies momentary vs sustained from how long the block was dark.
func plan_relight(block_id: Variant, restore_order: Array = [],
		source_pos: Variant = null, powered_fraction: float = 1.0) -> Dictionary:
	var b := _block_rec(block_id)
	var outage := -1.0 if b.dark_since < 0.0 else time_s - b.dark_since
	var momentary_s := float(blackout_cfg.get("momentary_outage_s", 4.50))
	var momentary := outage >= 0.0 and outage <= momentary_s
	var sweep := float(blackout_cfg.get("relight_sweep_s", 2.2))
	var jitter := float(blackout_cfg.get("relight_jitter_s", 0.5))

	var ranks := _relight_ranks(b, restore_order, source_pos)
	var delays: Dictionary = {}
	for id in b.buildings:
		var rec: BuildingRec = _recs.get(id)
		if rec == null:
			continue
		var d := 0.0
		if not momentary:
			d = sweep * float(ranks.get(id, 0.0)) + rec.anim_phase * jitter
		rec.powered = _stays_powered(rec, powered_fraction)
		rec.emissive_target = emissive_target_for(rec)
		rec.emissive_delay = d
		rec.ramp_mode = RAMP_RELIGHT
		rec.ramp_t = 0.0
		delays[id] = d
		_touch_animating(id)
		_mark_dirty(rec)

	var sl_mult := float(blackout_cfg.get("relight_streetlight_mult", 0.80))
	for sid in b.streetlights:
		var sl: StreetlightRec = _streetlights.get(sid)
		if sl == null:
			continue
		sl.lit_target = 1.0
		sl.ramp_mode = RAMP_RELIGHT
		sl.ramp_t = 0.0
		if momentary:
			sl.delay = 0.0
		else:
			sl.delay = sl_mult * float(delays.get(_nearest_building(b, sl.world_pos), 0.0))

	b.dark = false
	b.powered_fraction = powered_fraction
	b.relight_active = true
	b.relight_t = 0.0
	b.relight_peak_fired = momentary
	var ramp := float(blackout_cfg.get("relight_ramp_s", 0.15))
	var settle := float(blackout_cfg.get("relight_settle_s", 0.30))
	b.relight_duration = float(blackout_cfg.get("momentary_relight_total_s", 0.75)) if momentary \
			else sweep + jitter + ramp + settle
	_emit(&"render_relight_started", {"block_id": block_id,
			"duration_s": b.relight_duration, "momentary": momentary})
	return {"momentary": momentary, "outage_s": outage, "delays": delays,
			"duration_s": b.relight_duration}


## Normalised sweep position in [0,1] per building.
func _relight_ranks(b: BlockRec, restore_order: Array, source_pos: Variant) -> Dictionary:
	var ranks: Dictionary = {}
	var order: Array = []
	for v in restore_order:
		var id := int(v)
		if _recs.has(id) and b.buildings.has(id):
			order.append(id)
	if not order.is_empty():
		var n := order.size()
		for k in n:
			ranks[order[k]] = float(k) / float(maxi(n - 1, 1))
		# buildings missing from the order sweep last
		for id in b.buildings:
			if not ranks.has(id):
				ranks[id] = 1.0
		return ranks
	var origin: Vector3 = source_pos if source_pos is Vector3 else _block_centroid(b)
	var floor_m := float(blackout_cfg.get("relight_source_dist_floor_m", 40.0))
	var d_max := floor_m
	for id in b.buildings:
		var rec: BuildingRec = _recs.get(id)
		if rec != null:
			d_max = maxf(d_max, rec.world_pos.distance_to(origin))
	for id in b.buildings:
		var rec2: BuildingRec = _recs.get(id)
		if rec2 != null:
			ranks[id] = rec2.world_pos.distance_to(origin) / maxf(0.0001, d_max)
	return ranks


func _block_centroid(b: BlockRec) -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	for id in b.buildings:
		var rec: BuildingRec = _recs.get(id)
		if rec != null:
			sum += rec.world_pos
			n += 1
	return sum / float(maxi(n, 1))


func _nearest_building(b: BlockRec, pos: Vector3) -> int:
	var best := -1
	var best_d := INF
	for id in b.buildings:
		var rec: BuildingRec = _recs.get(id)
		if rec == null:
			continue
		var d := rec.world_pos.distance_to(pos)
		if d < best_d:
			best_d = d
			best = id
	return best


# ------------------------------------------------------------ events §2.3/§4

func apply_event(e: Dictionary) -> void:
	var type := StringName(e.get("type", &""))
	match type:
		&"BuildingPowerChanged", &"building_power_changed":
			var rec := _rec_of(e.get("building", e.get("building_id", -1)))
			if rec != null:
				var state: Variant = e.get("state", POWER_LIT)
				if typeof(state) == TYPE_BOOL:
					rec.powered = bool(state)
				else:
					rec.powered = StringName(state) == POWER_LIT
				_retarget(rec)
		&"BlockDarkChanged":
			var block_id: Variant = e.get("block_id", e.get("block", 0))
			var fraction := float(e.get("powered_fraction", 0.0))
			if bool(e.get("block_dark", true)):
				plan_blackout(block_id, fraction)
			else:
				plan_relight(block_id, e.get("restore_order", []),
						e.get("source_pos", null), maxf(fraction, 0.0))
		&"PowerRestored":
			# doc 04's citywide restoration: each dark block relights on its own
			# sweep, no extra citywide sweep on top (§2.7.5).
			var order: Array = e.get("restore_order", [])
			for bid in _dark_block_ids():
				plan_relight(bid, order, e.get("source_pos", null),
						float(e.get("powered_fraction", 1.0)))
		&"StreetlightsChanged":
			_set_streetlights(e.get("block_id", 0), bool(e.get("lit", true)))
		&"TotalBlackout":
			for bid in _sorted_block_ids():
				plan_blackout(bid, 0.0)
		&"building_damaged", &"building_damage_changed":
			var rec2 := _rec_of(e.get("building", e.get("building_id", -1)))
			if rec2 != null:
				if e.has("condition"):
					rec2.condition = clampf(float(e["condition"]), 0.0, 1.0)
				# Doc 02 §2.6's decay transition carries `{building, cause}` and
				# nothing else — the sim owns the numbers and does not repeat
				# them in an event. So a bare `building_damaged` derives its
				# soot from the condition this model is holding rather than
				# leaving the channel at zero on a building that just went
				# `damaged`, which is what made the state invisible in the world.
				rec2.damage = clampf(float(e["damage"]), 0.0, 1.0) if e.has("damage") \
						else clampf(1.0 - rec2.condition, 0.0, 1.0)
				if base_overlay_state(rec2.id) == OVERLAY_NORMAL:
					_write_overlay(rec2, OVERLAY_WARNING)
				_retarget(rec2)
		&"building_destroyed":
			var rec3 := _rec_of(e.get("building", e.get("building_id", -1)))
			if rec3 != null:
				rec3.damage = 1.0
				rec3.powered = false
				_write_overlay(rec3, OVERLAY_OFFLINE)
				_retarget(rec3)
		&"restore_started_sim":
			# **The ruin has to GO the same frame** (Wave 18, report 98 RR-157).
			# The pump lesson (RR-108) says a thing the player just bought appears
			# immediately rather than on the next relaunch; a rubble lot is that
			# statement inverted — the player paid to clear it, so the soot and
			# the OFFLINE tint the `building_destroyed` arm wrote come off here,
			# and the record goes to construction stage 1.
			#
			# **And it has to come off HERE rather than at completion.** The
			# `building_completed` arm below carries `damage` FORWARD when the
			# event does not name one, and `Building.complete_construction` emits
			# `{type, building, level}` — no condition, no damage. So a lot whose
			# soot was not cleared at restore-start would still be rendering a
			# burnt-out shell after the crew finished and the building was
			# `active` at condition 1.00, which is the renderer lying about a
			# state the sim has left.
			var rec_ruin := _rec_of(e.get("building", e.get("building_id", -1)))
			if rec_ruin != null:
				rec_ruin.damage = 0.0
				rec_ruin.condition = 1.0
				rec_ruin.stage = 1
				_write_overlay(rec_ruin, OVERLAY_NORMAL)
				_retarget(rec_ruin)
		&"building_repaired":
			# The soot's OTHER end (Wave 17, doc 93 §Y1). `building_repaired` has
			# been emitted by `Building.complete_repair` since doc 02 §2.6 shipped
			# and consumed by nothing, so the damage channel and the WARNING tint
			# a `building_damaged` wrote were never cleared — a repaired building
			# stayed sooty until something else happened to it. Doc 02 §2.6a makes
			# that visible rather than rare: a private building the city left dark
			# goes damaged and then, when the lights come back, repairs ITSELF with
			# no player action at all, so nothing else is coming to clear it.
			# `condition` rides the event where the sim sends it and the damage is
			# derived from it otherwise, exactly as the `building_damaged` branch
			# above does.
			var rec_fixed := _rec_of(e.get("building", e.get("building_id", -1)))
			if rec_fixed != null:
				if e.has("condition"):
					rec_fixed.condition = clampf(float(e["condition"]), 0.0, 1.0)
				rec_fixed.damage = clampf(1.0 - rec_fixed.condition, 0.0, 1.0)
				if base_overlay_state(rec_fixed.id) == OVERLAY_WARNING:
					_write_overlay(rec_fixed, OVERLAY_NORMAL)
				_retarget(rec_fixed)
		&"building_completed", &"building_upgraded":
			var rec4 := _rec_of(e.get("building", e.get("building_id", -1)))
			if rec4 != null:
				var new_level := int(e.get("level", rec4.level))
				if new_level != rec4.level:
					# **The rung that MOVES the building** (Wave 31, RR-255).
					# Half of doc 02's roster changes footprint as it climbs — a
					# store 1×1 → 2×2 at L3, a treatment plant 2×2 → 3×3 at L2 —
					# and a mesh is centred on the ground it holds, so growing
					# one puts its centre half a tile further along both axes.
					# This arm rebucketed the LEVEL and left the transform where
					# the old rung put it, which stood every grown building 4 m
					# off its own lot for the rest of the game. The two optional
					# fields are the shell handing over what only the sim can
					# answer; without them the arm is exactly what it was.
					_rebucket(rec4, new_level, e.get("world_pos", null),
							e.get("built_tiles", Vector2i.ZERO))
				rec4.stage = 0
				rec4.damage = float(e.get("damage", rec4.damage))
				_write_overlay(rec4, OVERLAY_NORMAL)
				_retarget(rec4)
		&"building_construction_stage":
			var rec5 := _rec_of(e.get("building", e.get("building_id", -1)))
			if rec5 != null:
				rec5.stage = clampi(int(e.get("stage", 0)), 0, PACK_STAGE_SPAN - 1)
				_mark_dirty(rec5)
		&"building_removed":
			var id := int(e.get("building", e.get("building_id", -1)))
			if _recs.has(id):
				remove_building(id)
		&"building_placed":
			if e.has("view"):
				add_building(e["view"])
		&"AutoReclosedOK", &"AutoRecloseLockout", &"LoadShedStarted", &"LoadShedEnded", \
		&"RollingBlackoutRotated", &"TrafficSignalPowerChanged", &"network_topology_changed", \
		&"road_network_changed", &"block_development_changed":
			pass  # consumed by other views; no per-building emissive effect here
		_:
			pass


func apply_events(batch: Array) -> void:
	for e in batch:
		if typeof(e) == TYPE_DICTIONARY:
			apply_event(e)


## §2.7.6 — on `is_resync` every value SNAPS and no ceremony is scheduled.
func apply_snapshot(snap: Dictionary) -> void:
	var resync := bool(snap.get("is_resync", false))
	if resync:
		_suppress_events = true
	if snap.has("sim_time_minutes"):
		hour = fposmod(float(snap["sim_time_minutes"]) / 60.0, 24.0)
	elif snap.has("hour"):
		hour = fposmod(float(snap["hour"]), 24.0)
	for v in snap.get("buildings", []) as Array:
		var view: Dictionary = v
		var rec := _rec_of(view.get("id", -1))
		if rec == null:
			continue
		if view.has("powered"):
			rec.powered = bool(view["powered"])
		if view.has("has_backup_power"):
			rec.has_backup_power = bool(view["has_backup_power"])
		if view.has("condition"):
			rec.condition = float(view["condition"])
		# Same derivation as `add_building`: a feed that publishes conditions
		# and no damage still lights the soot channel, so wear is visible on
		# the building rather than only inside the building panel.
		if view.has("damage"):
			rec.damage = clampf(float(view["damage"]), 0.0, 1.0)
		elif view.has("condition"):
			rec.damage = clampf(1.0 - float(view["condition"]), 0.0, 1.0)
		if view.has("occ_b"):
			rec.occ_b = float(view["occ_b"])
		if view.has("construction_stage"):
			rec.stage = int(view["construction_stage"])
		if view.has("overlay_state"):
			_write_overlay(rec, int(view["overlay_state"]))
	for v in snap.get("blocks", []) as Array:
		var bv: Dictionary = v
		var b := _block_rec(bv.get("block_id", 0))
		b.dark = bool(bv.get("block_dark", false))
		b.powered_fraction = float(bv.get("powered_fraction", 1.0 if not b.dark else 0.0))
	if resync:
		resync_snap()
		_out_events.clear()
		_suppress_events = false
	else:
		_retarget_all()


## Full resync: snap every value to steady state and drop queued ceremony.
## Also used on save load, chunk build and preset change (§2.3).
## **The wear feed** (doc 12 §2.9 item 6's world-side cue). `rows` is
## `{render_id: condition}` — the cheapest possible shape, because the shell
## already walks the building roster once a game-hour and this rides that walk.
##
## Condition is the only reading a repair changes that the renderer can show, and
## it is the reading that answers *which building needs one*: doc 02 §2.6 decays
## it continuously and fires exactly ONE event (`building_damaged`, at the
## auto-damage threshold), so an event-only renderer sees a building go from
## pristine to `damaged` in one step and shows nothing in between. Feeding the
## condition instead makes `building.gdshader`'s soot ramp and the
## `damage_dim_gain` on the emissive read as continuous wear, and washes both
## clean the game-hour after a repair completes.
##
## Skips a building whose condition has not moved, so a healthy city costs one
## float compare each and marks nothing dirty.
func ingest_conditions(rows: Dictionary) -> void:
	for key: Variant in rows:
		var rec := _rec_of(key)
		if rec == null:
			continue
		var condition := clampf(float(rows[key]), 0.0, 1.0)
		if is_equal_approx(rec.condition, condition):
			continue
		rec.condition = condition
		rec.damage = clampf(1.0 - condition, 0.0, 1.0)
		_retarget(rec)


func resync_snap() -> void:
	for id in _recs:
		var rec: BuildingRec = _recs[id]
		rec.emissive_target = emissive_target_for(rec)
		rec.emissive_cur = rec.emissive_target
		rec.emissive_delay = 0.0
		rec.ramp_mode = RAMP_IDLE
		rec.ramp_t = 0.0
		_mark_dirty(rec)
	for sid in _streetlights:
		var sl: StreetlightRec = _streetlights[sid]
		sl.cur = sl.lit_target
		sl.delay = 0.0
		sl.ramp_mode = RAMP_IDLE
		sl.ramp_t = 0.0
	for bid in _blocks:
		var b: BlockRec = _blocks[bid]
		b.envelope_t = -1.0
		b.relight_active = false
		b.relight_peak_fired = true
		b.relight_t = 0.0
		b.ground_dark = 1.0 if b.dark else 0.0
	_animating.clear()


func queued_plan_count() -> int:
	var n := 0
	for bid in _blocks:
		var b: BlockRec = _blocks[bid]
		if b.envelope_t >= 0.0 or b.relight_active:
			n += 1
	return n


func animating_count() -> int:
	return _animating.size()


func _rec_of(id_value: Variant) -> BuildingRec:
	return _recs.get(int(id_value))


## Move one building to another level's bucket, and — when the caller can say
## where the new rung stands — to the centre and the footprint scale that rung
## needs. `world_pos` null and `built_tiles` zero keep both, which is what every
## producer that has nothing to say hands over.
##
## The chunk is deliberately NOT re-derived: a footprint growing by a tile moves
## a centre by 4 m and could cross a 128 m chunk line, and a rec whose `chunk`
## disagrees with the ChunkRec holding it corrupts the slot allocator. The
## streamer re-homes buildings; this only re-centres one inside its own chunk.
func _rebucket(rec: BuildingRec, new_level: int, world_pos: Variant = null,
		built_tiles: Vector2i = Vector2i.ZERO) -> void:
	_free_slot(rec)
	rec.level = new_level
	if built_tiles.x > 0 and built_tiles.y > 0:
		rec.built_tiles = built_tiles
	if world_pos != null:
		rec.world_pos = world_pos
	rec.footprint_scale = footprint_scale_for(rec.shape, rec.level, rec.built_tiles)
	# Rebuilt from the identity rather than composed onto the old basis, because
	# the old basis already carries the OLD rung's footprint scale and there is
	# nothing else in it: every producer of a BuildingView in this project writes
	# `Transform3D(Basis.IDENTITY, centre)` — the same fact `_upload_blob` reads
	# the far and blob transforms under.
	rec.transform = Transform3D(
			Basis.from_scale(Vector3(rec.footprint_scale.x, 1.0,
					rec.footprint_scale.y)),
			rec.world_pos)
	_alloc_slot(rec)


func _dark_block_ids() -> Array:
	var out: Array = []
	for bid in _sorted_block_ids():
		if (_blocks[bid] as BlockRec).dark:
			out.append(bid)
	return out


func _sorted_block_ids() -> Array:
	var out: Array = []
	for bid in _blocks:
		out.append(bid)
	out.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	return out


func _set_streetlights(block_id: Variant, lit: bool) -> void:
	var b := _block_rec(block_id)
	var stagger := float(blackout_cfg.get("stagger_s", 0.35))
	var mult := float(blackout_cfg.get("streetlight_delay_mult", 0.60))
	for sid in b.streetlights:
		var sl: StreetlightRec = _streetlights.get(sid)
		if sl == null:
			continue
		sl.lit_target = 1.0 if lit else 0.0
		sl.delay = sl.anim_phase * stagger * mult
		sl.ramp_mode = RAMP_RELIGHT if lit else RAMP_EXP
		sl.ramp_t = 0.0


func _emit(type: StringName, payload: Dictionary) -> void:
	if _suppress_events:
		return
	var e := payload.duplicate()
	e["type"] = type
	e["t"] = time_s
	_out_events.append(e)


func drain_render_events() -> Array:
	var out := _out_events
	_out_events = []
	return out


func peek_render_events() -> Array:
	return _out_events


# ------------------------------------------------------------------- advance

## Advances every ramp by `delta` seconds. `max_animating_buildings` caps the
## number of buildings actually interpolated; the remainder snap to target
## (§2.3).
func advance(delta: float) -> void:
	time_s += delta
	_advance_blocks(delta)

	if _animating.size() > max_animating:
		var overflow := _animating.slice(max_animating)
		for id in overflow:
			var rec: BuildingRec = _recs.get(id)
			if rec != null:
				rec.emissive_cur = rec.emissive_target
				rec.emissive_delay = 0.0
				rec.ramp_mode = RAMP_IDLE
				_mark_dirty(rec)
		_animating = _animating.slice(0, max_animating)

	var still: Array = []
	for id in _animating:
		var rec: BuildingRec = _recs.get(id)
		if rec == null:
			continue
		if _advance_rec(rec, delta):
			still.append(id)
		_mark_dirty(rec)
	_animating = still

	for sid in _streetlights:
		_advance_streetlight(_streetlights[sid], delta)


func _advance_blocks(delta: float) -> void:
	var env_keys := _envelope_keys()
	var env_end := 0.0
	if not env_keys.is_empty():
		env_end = float((env_keys[env_keys.size() - 1] as Array)[0])
	var tau := float(blackout_cfg.get("tau_fall_s", 0.12))
	var peak_at := float(blackout_cfg.get("relight_peak_event_s", 1.1))
	for bid in _sorted_block_ids():
		var b: BlockRec = _blocks[bid]
		if b.envelope_t >= 0.0:
			b.envelope_t += delta
			if b.envelope_t > env_end:
				# The envelope's terminal keyframe is the collapse to black. Fold
				# it into every ramp state as it expires so releasing the block
				# multiplier cannot flash the block back up (§2.7.2 steps 1-3:
				# 0.30 envelope + 0.35 stagger + 0.55 fall = 1.20 s worst case).
				var final_mult := _envelope_value(env_end)
				for id in b.buildings:
					var rec: BuildingRec = _recs.get(id)
					if rec != null:
						rec.emissive_cur *= final_mult
						_mark_dirty(rec)
				for sid in b.streetlights:
					var sl: StreetlightRec = _streetlights.get(sid)
					if sl != null:
						sl.cur *= final_mult
				b.envelope_t = -1.0
		var target := 1.0 if b.dark else 0.0
		if not is_equal_approx(b.ground_dark, target):
			b.ground_dark += (target - b.ground_dark) * (1.0 - exp(-delta / maxf(0.0001, tau)))
			if absf(target - b.ground_dark) < 0.001:
				b.ground_dark = target
		if b.relight_active:
			b.relight_t += delta
			if not b.relight_peak_fired and b.relight_t >= peak_at:
				b.relight_peak_fired = true
				_emit(&"render_relight_peak", {"block_id": bid})
			if b.relight_t >= b.relight_duration:
				b.relight_active = false


## Returns true while the record still needs animating.
func _advance_rec(rec: BuildingRec, delta: float) -> bool:
	var dt := delta
	if rec.emissive_delay > 0.0:
		if rec.emissive_delay >= dt:
			rec.emissive_delay -= dt
			return true
		dt -= rec.emissive_delay
		rec.emissive_delay = 0.0
	match rec.ramp_mode:
		RAMP_RELIGHT:
			rec.ramp_t += dt
			var ramp := float(blackout_cfg.get("relight_ramp_s", 0.15))
			var settle := float(blackout_cfg.get("relight_settle_s", 0.30))
			var over := float(blackout_cfg.get("relight_overshoot", 1.35))
			if rec.ramp_t < ramp:
				rec.emissive_cur = rec.emissive_target * (rec.ramp_t / maxf(0.0001, ramp)) * over
				return true
			var k := minf(1.0, (rec.ramp_t - ramp) / maxf(0.0001, settle))
			rec.emissive_cur = rec.emissive_target * (over - (over - 1.0) * k)
			if k >= 1.0:
				rec.emissive_cur = rec.emissive_target
				rec.ramp_mode = RAMP_IDLE
				return false
			return true
		RAMP_EXP:
			var tau := float(blackout_cfg.get("tau_fall_s", 0.12))
			rec.emissive_cur += (rec.emissive_target - rec.emissive_cur) \
					* (1.0 - exp(-dt / maxf(0.0001, tau)))
			if absf(rec.emissive_target - rec.emissive_cur) < 0.0005:
				rec.emissive_cur = rec.emissive_target
				rec.ramp_mode = RAMP_IDLE
				return false
			return true
		_:
			return false


func _advance_streetlight(sl: StreetlightRec, delta: float) -> void:
	var dt := delta
	if sl.delay > 0.0:
		if sl.delay >= dt:
			sl.delay -= dt
			return
		dt -= sl.delay
		sl.delay = 0.0
	if sl.ramp_mode == RAMP_RELIGHT:
		sl.ramp_t += dt
		var ramp := float(blackout_cfg.get("relight_ramp_s", 0.15))
		var settle := float(blackout_cfg.get("relight_settle_s", 0.30))
		var over := float(blackout_cfg.get("relight_overshoot", 1.35))
		if sl.ramp_t < ramp:
			sl.cur = sl.lit_target * (sl.ramp_t / maxf(0.0001, ramp)) * over
			return
		var k := minf(1.0, (sl.ramp_t - ramp) / maxf(0.0001, settle))
		sl.cur = sl.lit_target * (over - (over - 1.0) * k)
		if k >= 1.0:
			sl.cur = sl.lit_target
			sl.ramp_mode = RAMP_IDLE
	elif sl.ramp_mode == RAMP_EXP:
		var tau := float(blackout_cfg.get("tau_fall_s", 0.12))
		sl.cur += (sl.lit_target - sl.cur) * (1.0 - exp(-dt / maxf(0.0001, tau)))
		if absf(sl.lit_target - sl.cur) < 0.0005:
			sl.cur = sl.lit_target
			sl.ramp_mode = RAMP_IDLE


## Value a streetlight MultiMesh writes, including the block stutter envelope.
func streetlight_out(id: int) -> float:
	var sl: StreetlightRec = _streetlights.get(id)
	if sl == null:
		return 0.0
	return maxf(0.0, sl.cur * _envelope_mult(sl.block_id))


# ------------------------------------------------------------- dirty flush

## Drains dirty instances in ascending chunk-distance order under the
## `multimesh_instance_writes_per_frame` budget; overflow carries to the next
## call (§2.3). Returns {writes, chunks, bulk_uploads, single_writes, remaining}.
func flush_dirty(camera_pos: Vector3, budget: int = -1) -> Dictionary:
	var remaining_budget := writes_per_frame if budget < 0 else budget
	var order: Array = []
	for coord in _sorted_chunk_coords():
		var c: ChunkRec = _chunks[coord]
		var count := 0
		for k in c.buckets:
			count += (c.buckets[k] as Bucket).dirty.size()
		if count > 0:
			order.append({"coord": coord, "dist": chunk_ground_distance(coord, camera_pos),
					"count": count})
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["dist"]), float(b["dist"])):
			var ca: Vector2i = a["coord"]
			var cb: Vector2i = b["coord"]
			if ca.x == cb.x:
				return ca.y < cb.y
			return ca.x < cb.x
		return float(a["dist"]) < float(b["dist"]))

	var writes := 0
	var bulk := 0
	var singles := 0
	var touched: Array = []
	for entry_v in order:
		if remaining_budget <= 0:
			break
		var entry: Dictionary = entry_v
		var coord: Vector2i = entry["coord"]
		var c: ChunkRec = _chunks[coord]
		var chunk_writes := 0
		for k in _sorted_bucket_keys(c):
			var b: Bucket = c.buckets[k]
			if b.dirty.is_empty():
				continue
			if b.dirty.size() >= bulk_upload_threshold:
				bulk += 1
			else:
				singles += b.dirty.size()
			var slots: Array = b.dirty.keys()
			slots.sort()
			for slot in slots:
				if remaining_budget <= 0:
					break
				var owner_id := b.slot_owner[slot] if slot < b.slot_owner.size() else -1
				var rec: BuildingRec = _recs.get(owner_id)
				if rec != null:
					_write_slot(b, rec)
				b.dirty.erase(slot)
				remaining_budget -= 1
				writes += 1
				chunk_writes += 1
		if chunk_writes > 0:
			touched.append(coord)
	return {"writes": writes, "chunks": touched, "bulk_uploads": bulk,
			"single_writes": singles, "remaining": dirty_instance_count()}


func _sorted_bucket_keys(c: ChunkRec) -> Array:
	var keys: Array = c.buckets.keys()
	keys.sort()
	return keys
