class_name LandWorksView
extends Node3D
## **LAND UNDER DEVELOPMENT, drawn** (doc 11 §2.18, doc 93 §AZ4).
##
## Doc 09 §2.3's six-phase pipeline has run since Wave 4 and **the render layer
## has never known it existed**: `grep -rn "CLEARING\|GRADING\|development_state"
## game/` came back empty, so a block being dug out looked exactly like one
## nobody had touched — for fourteen to fifteen phase charges of $1.2K–$21K per
## 21 game-days. This view is the other half of that sentence.
##
## **What each phase looks like**, keyed off `LandBlock.development_state` and
## the running job's own progress:
##
##   SURVEY             stakes on the lot line and tape between them; the brush
##                      is still standing, because nothing has been cleared yet
##   CLEARING           the brush and the stumps go, clump by clump, as the job
##                      runs — the count is a function of progress, so the block
##                      empties in front of the player
##   GRADING            a graded dirt plane over the block interior, and spoil
##                      heaps that grow where the cut came from
##   ROAD_INSTALL       base laid progressively along the tiles doc 10's own
##                      template will stamp — `RoadNetwork.TEMPLATE_*`, not a
##                      guess, so the strip is exactly where the street lands
##   UTILITY_CORRIDOR   an open trench down the collector line toward the block
##                      centre (which is where `_extend_utility_corridor` runs
##                      the lateral), with pipe and conduit stacked beside it
##   FINAL_DEVELOPMENT  kerbs along the finished runs, the spoil gone, the site
##                      being tidied
##   READY              nothing. The block is ground now.
##
## **SIX DRAW CALLS, and never all six at once.** One MultiMesh per prop kind,
## every buffer born hidden and switched off again the moment it empties, so a
## city with no pipeline in flight costs zero calls (`ConstructionVehicleView`'s
## RR-83 rule, applied here). The busiest phase is UTILITY_CORRIDOR at five live
## buffers; SURVEY costs two.
##
## **Heavy plant is not drawn here.** It goes through
## `ConstructionVehicleView.add_site` — the layer that already drives real
## streets to a site's frontage — with a per-phase profile that says how many
## excavators are working and which way the lorries run, so **the crew type the
## phase names is the machine that turns up**: `heavy_equipment_crew` on
## CLEARING, GRADING and UTILITY_CORRIDOR gets two excavators and lorries
## hauling spoil OUT; `road_crew` on ROAD_INSTALL gets one machine and
## deliveries coming IN; the two `construction_crew` phases get no heavy plant
## at all, which is why a block is not registered with the plant layer until
## CLEARING starts.
##
## **WHAT IT READS, and the ruling behind it** (doc 93 §AZ4). Phase transitions
## are EVENTS — `development_phase_started`, `development_phase_completed`,
## `block_ready`, `block_purchased` — drained by the shell once per tick, so
## membership costs nothing between transitions. Progress *within* a phase is on
## no event and must not be: it moves every tick and an event per tick is a bus
## flooded with a number. So this view polls, and it polls **its own active
## set** — the handful of blocks it has already been told are developing —
## at `POLL_INTERVAL_S`. It never iterates the world's blocks. And it writes
## NOTHING: every choice it makes is a hash of the block id and an index, so it
## is the same on every device and after every load, and the sim's state hash
## cannot move because this view exists (constitution §3).
##
## Integration (`main.gd` owns the wiring — see report 98 §69 RR-211):
##   view.setup(render_data)
##   view.set_preset(preset, render_data)
##   view.bind(sim.world, sim.development, sim.construction)
##   view.set_plant(construction_plant)      # optional; no plant without it
##   view.adopt()                            # blocks already in flight at boot
##   view.feed_events(batch)                 # once per tick, with the drain
##   view.set_focus(camera_focus)            # optional distance gate
##   view.refresh(delta)                     # every frame

## Plant-site ids handed to `ConstructionVehicleView`, which is keyed on the
## BUILDING grid id space. Ids there come off a high-water mark starting at 1
## (`CitySim._next_building_grid_id`) and doc 09's benchmark city has 1,500
## buildings, so a base four hundred times clear of it cannot collide, and
## `plant_id_of` is the one place the mapping is decided.
const PLANT_ID_BASE := 800_000

const PHASES: Array[StringName] = [
	&"SURVEY", &"CLEARING", &"GRADING", &"ROAD_INSTALL",
	&"UTILITY_CORRIDOR", &"FINAL_DEVELOPMENT",
]

## Per phase: the stage the plant layer is put in (which fixes its yard and its
## barricade run), how many excavators are working, and whether the lorries are
## hauling OUT (spoil, timber) or delivering IN (base, pipe). The excavator and
## haul columns are the doc 09 §2.3 PHASE_PRIMARY_CREW column, read as plant.
const PHASE_PLANT := {
	&"SURVEY": {"stage": 1, "excavators": 0, "haul_out": false, "plant": false},
	&"CLEARING": {"stage": 2, "excavators": 2, "haul_out": true, "plant": true},
	&"GRADING": {"stage": 3, "excavators": 2, "haul_out": true, "plant": true},
	&"ROAD_INSTALL": {"stage": 4, "excavators": 1, "haul_out": false, "plant": true},
	&"UTILITY_CORRIDOR": {"stage": 5, "excavators": 2, "haul_out": true, "plant": true},
	&"FINAL_DEVELOPMENT": {"stage": 6, "excavators": 0, "haul_out": true, "plant": true},
}

const DEF_TILE_M := 8.0
const DEF_BRUSH_PER_BLOCK := 40
const DEF_SPOIL_PER_BLOCK := 6
const DEF_STAKES := 8
const DEF_PAVE_SEGMENTS := 6
const DEF_TRENCH_SEGMENTS := 8
## A pipe bundle beside every OTHER trench segment. Derived, not authored:
## a second constant for the stack count would only ever have to agree with
## this one, and the first draft's `DEF_PIPE_STACKS = 5` was a ceiling that
## eight segments could never reach — a number with no reader.
const TRENCH_PIPE_EVERY := 2
const DEF_VISIBLE_RADIUS_M := 640.0
const DEF_MAX_BLOCKS := 8
## Seconds between progress reads. Four a second is far finer than a stump
## disappearing needs and far coarser than a frame.
const POLL_INTERVAL_S := 0.25

## Per-preset ceilings on the two scatter counts. Everything else on this layer
## is fixed geometry — eight stakes is eight stakes on a phone — so these are
## the only two knobs, and they are the two that scale with the block's area.
const PRESETS := {
	"performance": {"brush": 16, "spoil": 3, "blocks": 4},
	"balanced": {"brush": 40, "spoil": 6, "blocks": 8},
	"quality": {"brush": 64, "spoil": 8, "blocks": 12},
}

const TILES_PER_BLOCK := 16
## Doc 10's own template: the block boundary is AVENUE and local index 7 carries
## the collector cross. Read from `RoadNetwork` rather than restated, so the
## base this layer lays is exactly where the street lands two phases later.
const COLLECTOR_INDEX := RoadNetwork.TEMPLATE_COLLECTOR_INDEX

var tile_m := DEF_TILE_M
var visible_radius := DEF_VISIBLE_RADIUS_M
var max_blocks := DEF_MAX_BLOCKS
var brush_budget := DEF_BRUSH_PER_BLOCK
var spoil_budget := DEF_SPOIL_PER_BLOCK
var preset := "balanced"

## The shipping palette, authored in sRGB and decoded at `setup()` — see `_col`.
## These defaults are pre-decoded so a view nobody configured draws the same
## colours as one that read `data/render.json`.
var stake_color := Color("#D8C24A").srgb_to_linear()
var brush_color := Color("#3B5323").srgb_to_linear()
var stump_color := Color("#5A4A31").srgb_to_linear()
var graded_color := Color("#6B5C48").srgb_to_linear()
var spoil_color := Color("#7A6B54").srgb_to_linear()
var pave_color := Color("#3A3D41").srgb_to_linear()
var trench_color := Color("#241F1A").srgb_to_linear()
var pipe_color := Color("#6E8A72").srgb_to_linear()
var kerb_color := Color("#9AA0A6").srgb_to_linear()

var _world: WorldMap = null
var _development: DevelopmentController = null
var _construction: ConstructionQueue = null
var _plant: ConstructionVehicleView = null
var _sites: Dictionary = {}          # block_id -> Site
var _layers: Dictionary = {}         # key -> Layer
var _focus := Vector3.ZERO
var _has_focus := false
var _configured := false
var _poll_accum := 0.0
var _dirty := true


class Layer extends RefCounted:
	var key := ""
	var node: MultiMeshInstance3D
	var mm: MultiMesh
	var used := 0


class Site extends RefCounted:
	var block_id := ""
	var grid := Vector2i.ZERO
	var centre := Vector3.ZERO
	var phase: StringName = &"SURVEY"
	var progress := 0.0
	var plant_added := false
	## `hash01(block)` — the one number every scatter on this block is derived
	## from, so the same block looks the same on every device and after a load.
	var salt := 0


# -------------------------------------------------------------- public API

## `render_data` is `data/render.json`; `land_works` and `world.tile_m` are the
## only sections read and both may be absent, so this view works against a
## render.json that has never heard of it.
func setup(render_data: Dictionary = {}) -> void:
	var cfg: Dictionary = render_data.get("land_works", {})
	tile_m = _num(render_data.get("world", {}), "tile_m", DEF_TILE_M)
	visible_radius = _num(cfg, "visible_radius_m", DEF_VISIBLE_RADIUS_M)
	max_blocks = int(cfg.get("max_blocks", DEF_MAX_BLOCKS))
	brush_budget = int(cfg.get("brush_per_block", DEF_BRUSH_PER_BLOCK))
	spoil_budget = int(cfg.get("spoil_per_block", DEF_SPOIL_PER_BLOCK))
	stake_color = _col(cfg, "stake_color", "#D8C24A")
	brush_color = _col(cfg, "brush_color", "#3B5323")
	stump_color = _col(cfg, "stump_color", "#5A4A31")
	graded_color = _col(cfg, "graded_color", "#6B5C48")
	spoil_color = _col(cfg, "spoil_color", "#7A6B54")
	pave_color = _col(cfg, "pave_color", "#3A3D41")
	trench_color = _col(cfg, "trench_color", "#241F1A")
	pipe_color = _col(cfg, "pipe_color", "#6E8A72")
	kerb_color = _col(cfg, "kerb_color", "#9AA0A6")
	_build_layers()
	# Re-apply whatever preset is standing. `setup()` reads `data/render.json`'s
	# authored counts, so a `setup()` AFTER a `set_preset()` — which is what a
	# settings change followed by a re-configure looks like — would silently put
	# a phone back on the balanced budgets without this line.
	set_preset(preset, render_data)
	_configured = true
	_dirty = true


## The three read-only sim handles. `world` resolves a block id to its grid
## square and its phase; `development` answers which phase is live; `queue`
## answers how far into it. Nothing here writes, and nothing here is held past
## a `clear()` (constitution §3, doc 93 §AZ4).
func bind(world: WorldMap, development: DevelopmentController,
		queue: ConstructionQueue) -> void:
	_world = world
	_development = development
	_construction = queue
	_dirty = true


## Doc 11 §2.16's plant layer. Optional: without it the dressing still draws and
## no machine turns up, which is exactly what a preview harness with no road
## network wants.
func set_plant(plant: ConstructionVehicleView) -> void:
	_plant = plant


## Preset swap from the settings sheet (doc 12 §2.13). Two knobs, and they are
## the two that scale with the block's AREA — the scatter counts. A block on
## `performance` still gets stakes, tape, a graded plane, base, a trench and
## kerbs; it gets fewer stumps and fewer heaps.
func set_preset(name: String, render_data: Dictionary = {}) -> void:
	preset = name
	var row: Dictionary = PRESETS.get(name, PRESETS["balanced"])
	var cfg: Dictionary = render_data.get("land_works", {}) if not render_data.is_empty() else {}
	var overrides: Dictionary = (cfg.get("presets", {}) as Dictionary).get(name, {})
	brush_budget = int(overrides.get("brush", row.get("brush", DEF_BRUSH_PER_BLOCK)))
	spoil_budget = int(overrides.get("spoil", row.get("spoil", DEF_SPOIL_PER_BLOCK)))
	max_blocks = int(overrides.get("blocks", row.get("blocks", DEF_MAX_BLOCKS)))
	_dirty = true


## Camera focus for the distance gate. Optional — with no focus pushed nothing
## is culled, which is what the preview harness and the tests want.
func set_focus(world_pos: Vector3) -> void:
	_focus = world_pos
	_has_focus = true


## Sim → view, once per tick, on the batch the shell already drains. Every arm
## is a MEMBERSHIP change; nothing here reads progress (doc 93 §AZ4).
func feed_events(batch: Array) -> void:
	for entry: Variant in batch:
		if not (entry is Dictionary):
			continue
		var event: Dictionary = entry
		var block_id := String(event.get("block", event.get("block_id", "")))
		if block_id == "":
			continue
		match StringName(String(event.get("type", ""))):
			&"development_phase_started":
				_enter(block_id, StringName(String(event.get("phase", ""))))
			&"development_phase_completed":
				# The dressing for a phase that has just finished is DONE, and
				# the next `development_phase_started` is one line further down
				# this same batch — except on the last phase and on a paused
				# pipeline, where `block_ready` / nothing follows. Snapping the
				# progress to 1 here is what stops the last stump surviving the
				# tick the clearing finished on.
				var site: Site = _sites.get(block_id)
				if site != null:
					site.progress = 1.0
					_dirty = true
			&"block_ready", &"development_paused":
				# READY is nothing left to draw. A PAUSE keeps the dressing and
				# stands the plant down — the site is still a site, the crews
				# have simply gone home — so only READY removes.
				if StringName(String(event.get("type", ""))) == &"block_ready":
					_remove(block_id)
				else:
					_set_plant_profile(block_id, true)


## Blocks already in the pipeline when this view came up — a boot, a load, or a
## `--resume`. The ONE place this view is allowed to walk the world, because it
## is the one moment it has no active set to walk instead; it runs once per
## bring-up and never per frame (doc 93 §AZ4).
func adopt() -> void:
	if _world == null:
		return
	for block_id: String in _world.block_ids_sorted():
		var block := _world.block(block_id)
		if block == null or block.is_ready():
			continue
		if not PHASES.has(block.development_state):
			continue
		_enter(block_id, block.development_state)


func clear() -> void:
	for block_id: String in _sites.keys():
		_drop_plant(block_id)
	_sites.clear()
	_dirty = true
	for key: String in _layers:
		var layer: Layer = _layers[key]
		layer.used = 0
		if layer.mm != null:
			layer.mm.visible_instance_count = 0
		if layer.node != null:
			layer.node.visible = false


## One rendered frame. `night` is doc 11's day/night scalar and is accepted for
## symmetry with the other prop layers; nothing on this layer glows, so it is
## currently unused and the parameter exists so the shell's call site does not
## have to change when a work lamp arrives.
func refresh(delta: float, _night: float = -1.0) -> void:
	_ensure_setup()
	if _sites.is_empty():
		if _dirty:
			_upload()
		return
	_poll_accum += delta
	if _poll_accum >= POLL_INTERVAL_S:
		_poll_accum = 0.0
		_poll()
	if _dirty:
		_upload()


func site_count() -> int:
	return _sites.size()


## Draw calls this layer costs when every kind is on screen at once — the number
## a budget is measured against only in the worst case.
func layer_count() -> int:
	return _layers.size()


## Buffers actually SUBMITTING geometry this frame. On a city with no pipeline
## in flight it is 0 and `layer_count()` is still 6 (RR-83's rule).
func active_buffers() -> int:
	var n := 0
	for key: String in _layers:
		var layer: Layer = _layers[key]
		if layer.node != null and layer.node.visible and layer.used > 0:
			n += 1
	return n


## Live instance census, for the tests and doc 11's table.
func census() -> Dictionary:
	var out := {"blocks": _sites.size(), "buffers": active_buffers()}
	for key: String in _layers:
		out[key] = (_layers[key] as Layer).used
	return out


## The plant-layer id this block's machines are registered under. Public because
## the tests assert it cannot collide with a building's, and because the shell's
## `site_frontage_changed` handler has to be able to tell the two apart.
static func plant_id_of(block_id: String) -> int:
	return PLANT_ID_BASE + (absi(hash(block_id)) % 100_000)


static func is_plant_id(id: int) -> bool:
	return id >= PLANT_ID_BASE


## What one block is showing right now — phase, progress and whether its plant
## is registered. `{}` for a block this view is not drawing.
func site_view(block_id: String) -> Dictionary:
	var site: Site = _sites.get(block_id)
	if site == null:
		return {}
	return {"block_id": site.block_id, "phase": site.phase, "progress": site.progress,
			"plant": site.plant_added, "centre": site.centre}


# ------------------------------------------------------------- membership

func _enter(block_id: String, phase: StringName) -> void:
	if not PHASE_PLANT.has(phase):
		return
	var site: Site = _sites.get(block_id)
	if site == null:
		if _world == null:
			return
		var block := _world.block(block_id)
		if block == null:
			return
		site = Site.new()
		site.block_id = block_id
		site.grid = block.grid
		site.salt = absi(hash(block_id))
		site.centre = _block_centre(block.grid)
		_sites[block_id] = site
	site.phase = phase
	site.progress = 0.0
	_dirty = true
	_sync_plant(site)


func _remove(block_id: String) -> void:
	if not _sites.has(block_id):
		return
	_drop_plant(block_id)
	_sites.erase(block_id)
	_dirty = true


## Progress for the blocks THIS VIEW already knows about, and nothing else — the
## §AZ4 rule. Also picks up a phase the view missed (a batch dropped while the
## game was paused, a `restore_state` between ticks), because `active_view` is
## the pipeline's own answer and is cheaper than being wrong.
func _poll() -> void:
	if _development == null or _construction == null:
		return
	for block_id: String in _sites.keys():
		var site: Site = _sites[block_id]
		var live := _development.active_view(block_id)
		if live.is_empty():
			# **The pipeline let go of this block and no event said so.**
			# `DevelopmentController.cancel_development` erases its record and
			# emits nothing (it has no door in the shell today — the verb is
			# there, `cmd_cancel_development` is not), and a `restore_state`
			# between ticks can do the same. A block that is READY or back to
			# UNDEVELOPED has nothing left to draw, so it goes; a block sitting
			# on a completed phase with no job running KEEPS its dressing,
			# because that is the honest picture — the work stopped, the site
			# did not disappear.
			var block := _world.block(block_id) if _world != null else null
			if block == null or block.is_ready() \
					or block.development_state == &"UNDEVELOPED":
				_remove(block_id)
			continue
		var index := int(live.get("phase_index", -1))
		if index >= 0 and index < PHASES.size() and PHASES[index] != site.phase:
			site.phase = PHASES[index]
			site.progress = 0.0
			_sync_plant(site)
			_dirty = true
		var job_id := int(live.get("job_id", 0))
		var p := _construction.progress(job_id) if job_id > 0 else site.progress
		if absf(p - site.progress) > 0.004:
			site.progress = p
			_dirty = true


# ------------------------------------------------------------------ plant

func _sync_plant(site: Site) -> void:
	if _plant == null:
		return
	var row: Dictionary = PHASE_PLANT[site.phase]
	if not bool(row["plant"]):
		# SURVEY: a survey crew is two people and a tripod. Registering a site
		# here would send an excavator to look at a theodolite.
		_drop_plant(site.block_id)
		return
	var id := plant_id_of(site.block_id)
	if not site.plant_added:
		# A block is a 16×16 footprint with no building on it; the height is the
		# plant layer's clearance number and 1 m is the honest one for open
		# ground (`ConstructionActivity.add_site` floors it there anyway).
		_plant.add_site(id, site.centre,
				Vector2i(TILES_PER_BLOCK, TILES_PER_BLOCK), 1.0)
		site.plant_added = true
	_plant.set_stage(id, int(row["stage"]))
	_plant.set_site_profile(id, int(row["excavators"]), bool(row["haul_out"]))


## A pause stands the machines down without taking the site away: the hoarding
## and the spoil stay, the excavators stop. `paused` false restores the phase's
## own profile.
func _set_plant_profile(block_id: String, paused: bool) -> void:
	var site: Site = _sites.get(block_id)
	if site == null or _plant == null or not site.plant_added:
		return
	if paused:
		_plant.set_site_profile(plant_id_of(block_id), 0, false)
	else:
		_sync_plant(site)


func _drop_plant(block_id: String) -> void:
	var site: Site = _sites.get(block_id)
	if site == null or not site.plant_added:
		return
	site.plant_added = false
	if _plant != null:
		_plant.remove_site(plant_id_of(block_id))


# ------------------------------------------------------------------ layers

func _ensure_setup() -> void:
	if not _configured:
		setup({})


func _build_layers() -> void:
	for key: String in _layers.keys():
		(_layers[key] as Layer).node.queue_free()
	_layers.clear()
	var tile := PropSurface.tile_m()
	# **Three of the six get a PAGE and three do not, and the split is the
	# instance transform.** `ConstructionRigMesh` bakes its UVs in MESH space, so
	# a page is only physical while an instance is near unit size — a stake, a
	# clump of scrub and a spoil heap are (1.0–6.4×), and they carry the same
	# `prop_*` grain every other prop in the city carries. The graded plane, the
	# base runs and the trench are the opposite case: their whole SIZE is the
	# instance transform (126 m of plane, 20 m of run), so a tiled page would be
	# stretched by two orders of magnitude and read as smeared rectangles rather
	# than as ground. Those three are flat vertex-colour materials, which is
	# exactly what `PropSurface` degrades to on a clone with no generated pages.
	_add_layer("stake", _stake_mesh(tile), PropSurface.material("steel", 0.80, 0.05), 3.0)
	_add_layer("brush", _brush_mesh(tile), PropSurface.material("stock", 0.98, 0.0), 3.0)
	_add_layer("graded", _plane_mesh(tile), _flat_material(0.99), 1.0)
	_add_layer("spoil", _spoil_mesh(tile), PropSurface.material("stock", 0.96, 0.0), 4.0)
	_add_layer("pave", _slab_mesh(tile), _flat_material(0.90), 1.0)
	_add_layer("trench", _trench_mesh(tile), _flat_material(0.98), 2.0)


func _add_layer(key: String, builder: ConstructionRigMesh, material: Material,
		height_m: float) -> void:
	var layer := Layer.new()
	layer.key = key
	layer.mm = MultiMesh.new()
	layer.mm.transform_format = MultiMesh.TRANSFORM_3D
	layer.mm.use_colors = true
	layer.mm.mesh = builder.to_mesh(material)
	layer.mm.instance_count = 1
	layer.mm.visible_instance_count = 0
	layer.node = MultiMeshInstance3D.new()
	layer.node.name = "MM_%s" % key
	layer.node.multimesh = layer.mm
	# Instances are written straight into the buffer and never update the auto
	# AABB, so every MultiMesh in this project carries an explicit one. A land
	# block is 128 m across; the world is 1,024 m.
	layer.node.custom_aabb = AABB(Vector3(-64.0, -4.0, -64.0),
			Vector3(1152.0, height_m + 8.0, 1152.0))
	layer.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Born hidden — `_upload` switches it on the first frame it has anything to
	# draw. A layer built for a city with no pipeline in flight would otherwise
	# cost its call from boot until the first block is bought.
	layer.node.visible = false
	add_child(layer.node)
	_layers[key] = layer


# ------------------------------------------------------------------ upload

func _upload() -> void:
	_dirty = false
	_reserve()
	for key: String in _layers:
		(_layers[key] as Layer).used = 0
	var ids: Array = _sites.keys()
	ids.sort()   # stable buffers frame to frame, and a reproducible screenshot
	var drawn := 0
	for block_id: String in ids:
		if drawn >= max_blocks:
			break
		var site: Site = _sites[block_id]
		if _has_focus and visible_radius > 0.0 \
				and site.centre.distance_to(_focus) > visible_radius:
			continue
		drawn += 1
		_dress(site)
	for key: String in _layers:
		var layer: Layer = _layers[key]
		layer.mm.visible_instance_count = layer.used
		layer.node.visible = layer.used > 0


## Everything one block shows at its current phase and progress.
func _dress(site: Site) -> void:
	var index := PHASES.find(site.phase)
	if index < 0:
		return
	var half := float(TILES_PER_BLOCK) * tile_m * 0.5
	# SURVEY and CLEARING: the lot is pegged out.
	if index <= 1:
		_lay_stakes(site, half)
	# Brush stands until CLEARING takes it, and CLEARING takes it as it runs.
	if index <= 1:
		var keep := 1.0 if index == 0 else (1.0 - clampf(site.progress, 0.0, 1.0))
		_scatter_brush(site, half, keep)
	# The graded plane appears with GRADING and stays until the block is ground.
	if index >= 2:
		_lay_graded(site, half, 1.0 if index > 2 else clampf(site.progress, 0.0, 1.0))
	# Spoil: raised by the cut, still there through the trench, gone in the tidy.
	if index == 2:
		_heap_spoil(site, half, clampf(site.progress, 0.0, 1.0))
	elif index == 3:
		_heap_spoil(site, half, 1.0)
	elif index == 4:
		_heap_spoil(site, half, 1.0 - 0.5 * clampf(site.progress, 0.0, 1.0))
	elif index == 5:
		_heap_spoil(site, half, 1.0 - clampf(site.progress, 0.0, 1.0))
	# Base and blacktop, laid along doc 10's own template.
	if index == 3:
		_lay_pave(site, half, clampf(site.progress, 0.0, 1.0), false)
	elif index > 3:
		_lay_pave(site, half, 1.0, false)
	# The trench, open down the collector line to the block centre.
	if index == 4:
		_lay_trench(site, half, clampf(site.progress, 0.0, 1.0))
	# Kerbs go in last, and they are the only thing FINAL_DEVELOPMENT adds.
	if index == 5:
		_lay_pave(site, half, clampf(site.progress, 0.0, 1.0), true)


func _lay_stakes(site: Site, half: float) -> void:
	for i in DEF_STAKES:
		var edge := i % 4
		var along := lerpf(-half + 6.0, half - 6.0, _hash01(site.salt, 31 + i))
		var p := site.centre
		match edge:
			0: p += Vector3(along, 0.0, -half + 1.2)
			1: p += Vector3(half - 1.2, 0.0, along)
			2: p += Vector3(along, 0.0, half - 1.2)
			_: p += Vector3(-half + 1.2, 0.0, along)
		p.y = 0.0
		# The tape ribbon is authored along +X, so the peg yaws to lie along its
		# own edge of the lot rather than pointing at the neighbour's garden.
		var yaw := 0.0 if edge % 2 == 0 else PI * 0.5
		_push("stake", Transform3D(Basis.from_euler(Vector3(0.0, yaw, 0.0)), p),
				stake_color)


func _scatter_brush(site: Site, half: float, keep: float) -> void:
	var total := maxi(0, brush_budget)
	var live := int(round(float(total) * clampf(keep, 0.0, 1.0)))
	for i in live:
		var x := lerpf(-half + 5.0, half - 5.0, _hash01(site.salt, 101 + i * 7))
		var z := lerpf(-half + 5.0, half - 5.0, _hash01(site.salt, 211 + i * 13))
		# 2.6–5.4 m: scrub and the odd small tree, at the scale a 128 m block
		# has to be read at. Below about two metres a clump is a speck and
		# CLEARING looks like nothing happening.
		var s := lerpf(2.6, 5.4, _hash01(site.salt, 307 + i * 3))
		var yaw := _hash01(site.salt, 401 + i) * TAU
		var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0)) \
				.scaled_local(Vector3(s, s * 0.8, s))
		# Biased toward the GREEN end: the `prop_stock` page is sand-coloured and
		# multiplies the tint, so an even lerp between scrub and stump renders a
		# field of brown lumps. At 0.45 the stumps are the minority they are.
		var tint := brush_color.lerp(stump_color, _hash01(site.salt, 509 + i) * 0.45)
		_push("brush", Transform3D(basis, site.centre + Vector3(x, 0.0, z)), tint)


func _lay_graded(site: Site, half: float, fill: float) -> void:
	# ONE instance for the whole block: a 128 m quad is two triangles, and a
	# per-tile grid here would be 256 instances for a flat colour.
	var span := (half - 1.0) * 2.0 * clampf(fill, 0.05, 1.0)
	var basis := Basis.IDENTITY.scaled_local(Vector3(span, 1.0, span))
	_push("graded", Transform3D(basis, site.centre + Vector3(0.0, 0.02, 0.0)),
			graded_color)


func _heap_spoil(site: Site, half: float, amount: float) -> void:
	var live := int(round(float(maxi(0, spoil_budget)) * clampf(amount, 0.0, 1.0)))
	for i in live:
		var x := lerpf(-half + 12.0, half - 12.0, _hash01(site.salt, 601 + i * 11))
		var z := lerpf(-half + 12.0, half - 12.0, _hash01(site.salt, 701 + i * 17))
		var s := lerpf(3.2, 6.4, _hash01(site.salt, 809 + i))
		var basis := Basis.from_euler(Vector3(0.0, _hash01(site.salt, 907 + i) * TAU, 0.0)) \
				.scaled_local(Vector3(s, s * 0.42, s))
		_push("spoil", Transform3D(basis, site.centre + Vector3(x, 0.0, z)), spoil_color)


## The base course, laid along the SIX runs doc 10's template will stamp — four
## boundary avenues and the two collector lines at local index 7. `kerb` draws
## the same runs as a thin edge instead, which is what FINAL_DEVELOPMENT adds.
func _lay_pave(site: Site, half: float, fill: float, kerb: bool) -> void:
	var runs := _template_runs(site, half)
	var segments := maxi(1, DEF_PAVE_SEGMENTS)
	var total := runs.size() * segments
	var laid := int(round(float(total) * clampf(fill, 0.0, 1.0)))
	var made := 0
	for run: Dictionary in runs:
		var a: Vector3 = run["a"]
		var b: Vector3 = run["b"]
		var width := float(run["w"])
		for seg in segments:
			if made >= laid:
				return
			made += 1
			var t0 := float(seg) / float(segments)
			var t1 := float(seg + 1) / float(segments)
			var p0 := a.lerp(b, t0)
			var p1 := a.lerp(b, t1)
			var mid := (p0 + p1) * 0.5
			var dir := p1 - p0
			var length := dir.length()
			if length <= 0.01:
				continue
			var yaw := -atan2(dir.z, dir.x)
			var thickness := 0.10 if not kerb else 0.22
			# `scaled_local`, NOT `scaled`: `Basis.scaled` applies the factors on
			# the WORLD axes after the rotation, so a run laid along Z would come
			# out `width` long and `length` wide — which is what turned four
			# clean edges into a zigzag the first time this was photographed.
			var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0)).scaled_local(
					Vector3(length, thickness, width if not kerb else 0.55))
			mid.y = 0.04 if not kerb else 0.06
			_push("pave", Transform3D(basis, mid), pave_color if not kerb else kerb_color)


## The utility trench: down the collector line from the block edge to the CENTRE,
## because that is where `CitySim._extend_utility_corridor` runs the lateral.
## Pipe and conduit are stacked on the spoil side of it, one bundle every other
## segment, out of the same buffer — a trench and the pipe going into it are one
## story and a second draw call for six boxes would be a bad trade.
func _lay_trench(site: Site, half: float, fill: float) -> void:
	var segments := maxi(1, DEF_TRENCH_SEGMENTS)
	var dug := int(round(float(segments) * clampf(fill, 0.0, 1.0)))
	var start := site.centre + Vector3(-half + 1.0, 0.0, _collector_offset())
	var end := site.centre + Vector3(0.0, 0.0, _collector_offset())
	for seg in dug:
		var t0 := float(seg) / float(segments)
		var t1 := float(seg + 1) / float(segments)
		var p0 := start.lerp(end, t0)
		var p1 := start.lerp(end, t1)
		var mid := (p0 + p1) * 0.5
		var length := (p1 - p0).length()
		mid.y = 0.0
		_push("trench", Transform3D(Basis.IDENTITY.scaled_local(
				Vector3(length, 1.0, 2.2)), mid), trench_color)
		if seg % TRENCH_PIPE_EVERY == 0:
			var side := mid + Vector3(0.0, 0.0, 2.8)
			side.y = 0.0
			_push("trench", Transform3D(Basis.IDENTITY
					.scaled_local(Vector3(length * 0.7, 1.4, 1.1)), side), pipe_color)


## The six runs of doc 10's block template, in world space: four boundary
## avenues (2 tiles wide at the block edge) and the two collector lines.
func _template_runs(site: Site, half: float) -> Array[Dictionary]:
	var c := site.centre
	var edge := half - tile_m * 0.5
	var collector := _collector_offset()
	var avenue_w := tile_m
	var street_w := tile_m * 0.75
	var out: Array[Dictionary] = []
	out.append({"a": c + Vector3(-edge, 0.0, -edge), "b": c + Vector3(edge, 0.0, -edge),
			"w": avenue_w})
	out.append({"a": c + Vector3(edge, 0.0, -edge), "b": c + Vector3(edge, 0.0, edge),
			"w": avenue_w})
	out.append({"a": c + Vector3(edge, 0.0, edge), "b": c + Vector3(-edge, 0.0, edge),
			"w": avenue_w})
	out.append({"a": c + Vector3(-edge, 0.0, edge), "b": c + Vector3(-edge, 0.0, -edge),
			"w": avenue_w})
	out.append({"a": c + Vector3(-edge, 0.0, collector), "b": c + Vector3(edge, 0.0, collector),
			"w": street_w})
	out.append({"a": c + Vector3(collector, 0.0, -edge), "b": c + Vector3(collector, 0.0, edge),
			"w": street_w})
	return out


## Metres from the block centre to the collector line. `TEMPLATE_COLLECTOR_INDEX`
## is a LOCAL tile index (7 of 0..15), so the offset is measured from the
## block's own middle rather than restated as a number.
func _collector_offset() -> float:
	return (float(COLLECTOR_INDEX) + 0.5 - float(TILES_PER_BLOCK) * 0.5) * tile_m


func _block_centre(grid: Vector2i) -> Vector3:
	var origin := Vector2(grid) * float(TILES_PER_BLOCK)
	var mid := origin + Vector2(float(TILES_PER_BLOCK) * 0.5, float(TILES_PER_BLOCK) * 0.5)
	return Vector3(mid.x * tile_m, 0.0, mid.y * tile_m)


## Buffer capacity for the blocks this frame COULD draw, computed once before
## anything is written. A `MultiMesh` resize reallocates and copies, so growing
## it inside the write loop would do that up to six times a frame on the frame a
## second block starts; this does it only when the ceiling actually moves, which
## is a preset change or an extra pipeline starting.
func _reserve() -> void:
	var blocks := mini(_sites.size(), maxi(1, max_blocks))
	var need := {
		"stake": DEF_STAKES,
		"brush": maxi(1, brush_budget),
		"graded": 1,
		"spoil": maxi(1, spoil_budget),
		# TWICE the runs: FINAL_DEVELOPMENT draws the finished base AND the
		# kerbs going in along it, out of the same buffer.
		"pave": 12 * DEF_PAVE_SEGMENTS,
		"trench": DEF_TRENCH_SEGMENTS
				+ (DEF_TRENCH_SEGMENTS + TRENCH_PIPE_EVERY - 1) / TRENCH_PIPE_EVERY,
	}
	for key: String in _layers:
		var layer: Layer = _layers[key]
		var want := maxi(1, int(need.get(key, 1)) * maxi(blocks, 1))
		if layer.mm.instance_count < want:
			layer.mm.instance_count = want


func _push(key: String, xform: Transform3D, tint: Color) -> void:
	var layer: Layer = _layers.get(key)
	if layer == null or layer.used >= layer.mm.instance_count:
		return
	layer.mm.set_instance_transform(layer.used, xform)
	layer.mm.set_instance_color(layer.used, tint)
	layer.used += 1


## A page-less prop material: vertex colour straight to albedo, nothing tiled.
## For the layers whose instance transform is their whole size — see
## `_build_layers` for why a page cannot follow them.
static func _flat_material(roughness: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = roughness
	mat.metallic = 0.0
	mat.metallic_specular = 0.35
	return mat


# ----------------------------------------------------------------- meshes

## A survey peg: a square post with a flagged head, unit-ish so the instance
## transform is only its yaw.
static func _stake_mesh(tile_uv: float) -> ConstructionRigMesh:
	var m := ConstructionRigMesh.new()
	m.uv_tile_m = tile_uv
	# **2.4 m of lath, and the exaggeration is deliberate.** A real survey peg is
	# knee-high; a block is 128 m across and the camera looks at one from 150 m,
	# so a knee-high peg is one pixel. This is the same call doc 11 §2.10.1 makes
	# for a streetlight and §2.16 makes for a traffic cone: the prop is drawn at
	# the size it has to be to say what it is, not at the size it is.
	m.add_box(Vector3(0.0, 1.20, 0.0), Vector3(0.13, 2.40, 0.13), Color.WHITE,
			ConstructionRigMesh.JOINT_BASE, ConstructionRigMesh.SURF_STEEL)
	m.add_box(Vector3(0.0, 2.34, 0.0), Vector3(0.20, 0.42, 0.20),
			ConstructionRigMesh.CONE_ORANGE, ConstructionRigMesh.JOINT_BASE,
			ConstructionRigMesh.SURF_STEEL)
	# The tape, hanging off the head toward the next peg. One ribbon rather than
	# a span between two instances: a span needs both ends in the same buffer
	# entry, and a ribbon reads the same at the distance a block is seen from.
	# Its colour is BAKED and is `ConstructionRigMesh.BARRIER_ORANGE` — the same
	# hazard orange this project's barricades and cones already wear. A
	# `tape_color` knob was authored on the first draft and applied nowhere,
	# which is a number with no reader; the honest single source is the constant.
	m.add_box(Vector3(2.6, 2.10, 0.0), Vector3(5.2, 0.14, 0.04),
			ConstructionRigMesh.BARRIER_ORANGE, ConstructionRigMesh.JOINT_BASE,
			ConstructionRigMesh.SURF_STEEL)
	return m


## A clump of scrub with a stump in it — unit-sized, base on Y = 0, so the
## instance transform is the whole of its size.
static func _brush_mesh(tile_uv: float) -> ConstructionRigMesh:
	var m := ConstructionRigMesh.new()
	m.uv_tile_m = tile_uv
	m.add_heap(7, 613, Color.WHITE, ConstructionRigMesh.JOINT_BASE,
			ConstructionRigMesh.SURF_STOCK)
	m.add_box(Vector3(0.22, 0.16, -0.18), Vector3(0.26, 0.32, 0.26),
			Color(0.72, 0.66, 0.55), ConstructionRigMesh.JOINT_BASE,
			ConstructionRigMesh.SURF_STOCK)
	return m


## A unit quad on the ground plane, 1 m × 1 m centred on the origin. Scaled to a
## whole block by the instance transform.
static func _plane_mesh(tile_uv: float) -> ConstructionRigMesh:
	var m := ConstructionRigMesh.new()
	m.uv_tile_m = tile_uv
	m.add_box(Vector3.ZERO, Vector3(1.0, 0.02, 1.0), Color.WHITE,
			ConstructionRigMesh.JOINT_BASE, ConstructionRigMesh.SURF_STOCK)
	return m


static func _spoil_mesh(tile_uv: float) -> ConstructionRigMesh:
	var m := ConstructionRigMesh.new()
	m.uv_tile_m = tile_uv
	m.add_heap(9, 331, Color.WHITE, ConstructionRigMesh.JOINT_BASE,
			ConstructionRigMesh.SURF_STOCK)
	return m


## A unit slab: 1 m × 1 m × 1 m about the origin with its underside on Y = 0, so
## a run's length, width and thickness are all the instance transform.
static func _slab_mesh(tile_uv: float) -> ConstructionRigMesh:
	var m := ConstructionRigMesh.new()
	m.uv_tile_m = tile_uv
	m.add_box(Vector3(0.0, 0.5, 0.0), Vector3(1.0, 1.0, 1.0), Color.WHITE,
			ConstructionRigMesh.JOINT_BASE, ConstructionRigMesh.SURF_STOCK)
	return m


## An open cut: a sunk floor with a lip either side, unit-sized along X and Z so
## one segment of trench is one instance. The same mesh, scaled shallower and
## narrower and tinted, is the pipe bundle stacked beside it.
static func _trench_mesh(tile_uv: float) -> ConstructionRigMesh:
	var m := ConstructionRigMesh.new()
	m.uv_tile_m = tile_uv
	m.add_box(Vector3(0.0, -0.30, 0.0), Vector3(1.0, 0.60, 0.62), Color.WHITE,
			ConstructionRigMesh.JOINT_BASE, ConstructionRigMesh.SURF_STOCK)
	for sz: float in [1.0, -1.0]:
		m.add_box(Vector3(0.0, 0.09, sz * 0.40), Vector3(1.0, 0.18, 0.20),
				Color(0.78, 0.74, 0.68), ConstructionRigMesh.JOINT_BASE,
				ConstructionRigMesh.SURF_STOCK)
	return m


# ---------------------------------------------------------------- plumbing

## The same integer hash `ConstructionActivity` uses, so a block's scatter is a
## pure function of its id and an index — identical on every device, unchanged
## by a load, and incapable of moving the sim's state hash.
static func _hash01(value: int, salt: int) -> float:
	var h: int = absi((value * 73856093) ^ (salt * 19349663)) % 100003
	return float(h) / 100003.0


static func _num(cfg: Dictionary, key: String, fallback: float) -> float:
	return float(cfg.get(key, fallback))


## **DECODED ONCE, HERE** (doc 91 A91-D-36's rule, and `ConstructionRigMesh`'s
## own note on it). Every colour on this layer is authored as an sRGB hex and
## every one of them is written to a MultiMesh instance tint, which the renderer
## reads as LINEAR. Converting at the read means each hex decodes exactly once,
## from one authored source of truth; converting at the write would put a
## `srgb_to_linear()` allocation in a per-instance loop, and converting nowhere
## is what makes a dark olive scrub render as pale sand.
static func _col(cfg: Dictionary, key: String, fallback: String) -> Color:
	var raw := String(cfg.get(key, fallback))
	var authored := Color(raw) if Color.html_is_valid(raw) else Color(fallback)
	return authored.srgb_to_linear()
