class_name VehicleView
extends Node3D
## Traffic on the roads (doc 11 §2.12) — the render half of doc 10's civilian
## feed and doc 06's emergency fleet, drawn as one layer.
##
## WHAT THE SIM SENDS. `sim/roads/traffic_feed.gd` publishes a deterministic,
## capped civilian stream on the event bus:
##
##   vehicle_spawned  {id, kind, vehicle_class, pos, heading, speed, edge_id,
##                     siren, lightbar, headlights}
##   traffic_snapshot {count, ids, edge_ids, kinds, flags, pose} — ONE event per
##                    sim TICK carrying EVERY civilian pose in packed columns
##                    (doc 91 D-10's bus diet; format in
##                    `sim/roads/traffic_snapshot.gd`). It replaced the
##                    per-vehicle `vehicle_state` event, which no longer exists.
##   vehicle_despawned{id, reason}
##
## Doc 06's fleet does not publish poses on the bus; it exposes them as
## `IncidentSystem.vehicle_states()` (tile positions, explicit `speed` and
## `heading`, plus a status), with `unit_dispatched` / `unit_arrived` /
## `unit_returned` marking the transitions. Both arrive here:
## `apply_event()` swallows all six event names and ignores everything else, so
## the shell can hand it a whole drained batch; `apply_unit_states()` takes the
## fleet snapshot array. Nothing in this file talks back to the sim.
##
## HOW IT IS DRAWN. Seven MultiMeshes — `car` / `van` / `truck` for the
## civilian kinds, `police` / `fire` / `ambulance` / `utility` for the
## departments — plus one additive `MM_headlights` cone layer: **8 draw calls
## for the whole vehicle layer**, inside doc 11 §2.13's budget of 10. Bodies
## are procedural (`VehicleMesh`, ≤ 90 tris civilian / ≤ 180 emergency), paint
## is the per-instance colour, and lamps and light bars ride
## INSTANCE_CUSTOM into `game/shaders/vehicle.gdshader`.
##
## HOW IT MOVES. States land once per sim tick; frames are 60 Hz. Between
## states every vehicle DEAD-RECKONS along its heading at its speed
## (`VehicleMotion`), and each new state is joined on with doc 11 §2.12's
## Hermite blend so position and velocity stay continuous through a corner.
## Gaps over `interp_teleport_threshold_m` snap instead. Sim speed is passed in
## as game-minutes per real second, so 2×/3× and pause all read correctly.
##
## Integration (`main.gd` owns the wiring — see the branch report for the
## patch):
##   view.setup(render_data)                    # data/render.json
##   view.apply_event(e) / apply_events(batch)  # the drained sim batch
##   view.apply_unit_states(sim.incidents.vehicle_states())   # per TICK
##   view.set_focus(camera_state.focus)         # radius culling
##   view.refresh(delta, night, gm_per_s)       # every frame
##
## RENDER-SIDE RANDOMNESS ONLY (doc 11 §8.1): paint and light-bar phase are
## hashes of the vehicle id. Nothing here is persisted and nothing feeds back —
## the sim already owns the only randomness that matters, on its `traffic`
## stream, which is why the same save always shows the same cars.

const EMERGENCY_KEY_BASE := 1_000_000

## The procedural surface set (`tools/gen_textures.py`). Absent pages are not an
## error: `tex_mix` falls to 0 and the flat-shaded layer that shipped before the
## atlas comes back unchanged, which is what keeps a fresh clone bootable before
## anyone has run the generator and `--import`.
const TEXTURE_MANIFEST := "res://game/textures/generated/manifest.json"

const CIV_KINDS := ["car", "van", "truck"]
const EMERGENCY_MESHES := ["police", "fire", "ambulance", "utility"]

## Department (doc 06's `data/vehicles.json`) → body and paint.
const DEPT_MESH := {
	"police": "police", "fire": "fire", "medical": "ambulance",
	"utility": "utility", "water": "utility", "construction": "utility",
}
const DEPT_PAINT := {
	"police": "#E9EDF2", "fire": "#C0301F", "medical": "#F2F4F6",
	"utility": "#E0A72C", "water": "#2F7F92", "construction": "#E8752A",
}
## Doc 06 statuses that are actually out on the road. IDLE / REFIT / OFFLINE
## units are inside their station and are not drawn.
const ROLLING_STATUS := {"RESPONDING": true, "ON_SCENE": true, "RETURNING": true}

## Civilian paint, pulled towards the city's muted stylized palette rather than
## showroom colours — traffic should read as texture on the street, not confetti.
const CIV_PAINT := [
	"#B7BCC2", "#8E969E", "#4A5157", "#2C3237", "#D9D5C8",
	"#42607B", "#7C4B3C", "#8E9C86", "#9E3B34", "#C9A24A",
]

const DEF_TILE_M := 8.0
const DEF_ROAD_TOP_M := 0.10
const DEF_LANE_OFFSET_M := 1.85
const DEF_VISIBLE_RADIUS_M := 420.0
const DEF_TELEPORT_M := 40.0
const DEF_NIGHT_THRESHOLD := 0.15
const DEF_LIGHTBAR_HZ := 2.2
const DEF_LIGHTBAR_EMISSION := 3.5
const DEF_FADE_S := 0.40
const DEF_BLEND_S := 0.28
const DEF_CONE_LEN_M := 8.0
const DEF_WORLD_M := 1024.0

var tile_m := DEF_TILE_M
var road_top := DEF_ROAD_TOP_M
var lane_offset := DEF_LANE_OFFSET_M
var visible_radius := DEF_VISIBLE_RADIUS_M
var teleport_m := DEF_TELEPORT_M
var night_threshold := DEF_NIGHT_THRESHOLD
var lightbar_hz := DEF_LIGHTBAR_HZ
var lightbar_emission := DEF_LIGHTBAR_EMISSION
var fade_s := DEF_FADE_S
var blend_s := DEF_BLEND_S
var cone_len := DEF_CONE_LEN_M
var world_m := DEF_WORLD_M
var cast_shadows := true
var preset := "balanced"
## Per-mesh instance ceiling (doc 11 §2.12's preset table). The sim's own cap
## is tighter than every one of these today; the ceilings exist so a future
## preset change cannot make the renderer the thing that falls over.
var caps: Dictionary = {}
var beacon_budget := 4

var _vehicles: Dictionary = {}      # render key -> VehicleMotion
var _layers: Dictionary = {}        # mesh key -> Layer
var _dept_of_type: Dictionary = {}  # doc 06 vehicle type id -> department
var _unit_stamp: Dictionary = {}    # render key -> last pushed fleet pose
var _cone_node: MultiMeshInstance3D
var _cone_mm: MultiMesh
var _cone_material: ShaderMaterial
var _beacons: Array = []            # OmniLight3D pool
var _bar_a: Dictionary = {}         # mesh key -> Color
var _bar_b: Dictionary = {}
## `vehicle_atlas.png` and its 2x2 cell count, from the texture manifest.
var _atlas: Texture2D = null
var _atlas_cells := Vector2(2.0, 2.0)
var _time := 0.0
var _night := 0.0
var _gm_per_s := 1.0
var _focus := Vector3.ZERO
var _has_focus := false
var _configured := false


class Layer extends RefCounted:
	var key := ""
	var node: MultiMeshInstance3D
	var mm: MultiMesh
	var material: ShaderMaterial
	var nose := 0.0
	var cap := 256
	var list: Array = []   # VehicleMotion, spawn order


# -------------------------------------------------------------- public API

## `render_data` is data/render.json. `vehicles`, `presets` and `world.tile_m`
## are the only sections read and every key is optional, so the view works
## against a render.json that has never heard of it.
##
## Already in `vehicles` today and honoured here: `civ_visible_radius_m`,
## `interp_teleport_threshold_m`, `headlight_night_threshold`, `lightbar_hz`,
## `lightbar_emission`, `lightbar_red`, `lightbar_blue`.
##
## The nine tuning knobs this view once carried as script constants were
## promoted into `data/render.json`'s `vehicles` block by the render-polish
## pass and are read from there now — `road_top_m`, `lane_offset_m`,
## `fade_seconds`, `interp_blend_seconds`, `headlight_cone_m`,
## `headlight_cone_energy`, `headlight_color`, `lightbar_amber`,
## `lightbar_amber_pale`. The `DEF_*` constants above stay as the fallback for
## a render.json that predates them, so nothing here is load-bearing on the
## file having been updated.
##
## `cast_shadows` is the tenth and reads in two steps: `vehicles.cast_shadows`
## is the baseline, and a preset row's `vehicle_shadows` overrides it. It ships
## OFF on Performance and Balanced and ON on High — see `_build_layers` for why
## a world-sized AABB makes this a per-split cost rather than a per-car one.
func setup(render_data: Dictionary = {}) -> void:
	var cfg: Dictionary = render_data.get("vehicles", {})
	tile_m = _num(render_data.get("world", {}), "tile_m", DEF_TILE_M)
	world_m = _num(cfg, "world_m", maxf(DEF_WORLD_M, tile_m * 128.0))
	road_top = _num(cfg, "road_top_m", DEF_ROAD_TOP_M)
	lane_offset = _num(cfg, "lane_offset_m", DEF_LANE_OFFSET_M)
	visible_radius = _num(cfg, "civ_visible_radius_m", DEF_VISIBLE_RADIUS_M)
	teleport_m = _num(cfg, "interp_teleport_threshold_m", DEF_TELEPORT_M)
	night_threshold = _num(cfg, "headlight_night_threshold", DEF_NIGHT_THRESHOLD)
	lightbar_hz = maxf(0.05, _num(cfg, "lightbar_hz", DEF_LIGHTBAR_HZ))
	lightbar_emission = _num(cfg, "lightbar_emission", DEF_LIGHTBAR_EMISSION)
	fade_s = maxf(0.01, _num(cfg, "fade_seconds", DEF_FADE_S))
	blend_s = maxf(0.02, _num(cfg, "interp_blend_seconds", DEF_BLEND_S))
	cone_len = _num(cfg, "headlight_cone_m", DEF_CONE_LEN_M)
	cast_shadows = bool(cfg.get("cast_shadows", true))
	_bar_a = {
		"police": _col(cfg, "lightbar_red", "#FF2A22"),
		"ambulance": _col(cfg, "lightbar_red", "#FF2A22"),
		"fire": _col(cfg, "lightbar_red", "#FF2A22"),
		"utility": _col(cfg, "lightbar_amber", "#FFAE1E"),
	}
	_bar_b = {
		"police": _col(cfg, "lightbar_blue", "#2A5CFF"),
		"ambulance": _col(cfg, "lightbar_blue", "#2A5CFF"),
		"fire": _col(cfg, "lightbar_amber", "#FFAE1E"),
		"utility": _col(cfg, "lightbar_amber_pale", "#FFD873"),
	}
	_read_presets(render_data)
	_read_departments()
	_load_atlas()
	_build_layers(cfg)
	_configured = true


## The vehicle micro-atlas. One page for the whole fleet, so the traffic layer
## still costs one texture unit however many body kinds it draws.
func _load_atlas() -> void:
	_atlas = null
	if not ResourceLoader.exists(TEXTURE_MANIFEST):
		return
	var doc: Dictionary = StarterCityLoader.read_json(TEXTURE_MANIFEST)
	var cells: Dictionary = doc.get("vehicle_cells", {})
	if not cells.is_empty():
		# The atlas is as wide/tall as the largest cell index plus one, read off
		# the manifest rather than assumed, so a future 2x3 page needs no code.
		var mx := 1.0
		var my := 1.0
		for name: String in cells:
			var pair: Array = cells[name]
			if pair.size() >= 2:
				mx = maxf(mx, float(pair[0]) + 1.0)
				my = maxf(my, float(pair[1]) + 1.0)
		_atlas_cells = Vector2(mx, my)
	var pages: Dictionary = doc.get("vehicles", {})
	var entry: Dictionary = pages.get("atlas", {})
	var path := String(entry.get("path", ""))
	if path != "" and ResourceLoader.exists(path):
		_atlas = load(path)
	else:
		push_warning("vehicle_view: no vehicle atlas, running flat-shaded")


## Preset swap from the settings sheet (doc 12 §2.13). Only the instance
## ceilings and the beacon budget move; nothing already on the road is lost.
func set_preset(name: String, render_data: Dictionary = {}) -> void:
	preset = name
	if not render_data.is_empty():
		_read_presets(render_data)
	var shadow_setting := GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for key: String in _layers:
		var layer := _layers[key] as Layer
		layer.cap = int(caps.get(key, 256))
		if layer.node != null:
			layer.node.cast_shadow = shadow_setting
	_size_beacons()


## Camera focus for doc 11 §2.12's `civ_visible_radius_m` gate. Optional — with
## no focus pushed, nothing is distance-culled.
func set_focus(world_pos: Vector3) -> void:
	_focus = world_pos
	_has_focus = true


## A whole drained sim batch. Names this view does not own are ignored, so the
## shell can forward the batch unfiltered.
func apply_events(batch: Array) -> void:
	for event: Variant in batch:
		if event is Dictionary:
			apply_event(event)


## One sim event. Doc 10's `vehicle_spawned` / `vehicle_state` /
## `vehicle_despawned`, and doc 06's `unit_dispatched` / `unit_arrived` /
## `unit_returned` (which carry no pose — they only flip siren and bar state;
## `apply_unit_states` supplies the poses).
func apply_event(e: Dictionary) -> void:
	_ensure_setup()
	match String(e.get("type", "")):
		"vehicle_spawned":
			_ingest(e, true)
		"traffic_snapshot":
			_ingest_snapshot(e)
		"vehicle_despawned":
			_retire(_key_for(e))
		"unit_dispatched":
			_flag_unit(int(e.get("unit_id", 0)), true, true)
		"unit_arrived":
			_flag_unit(int(e.get("unit_id", 0)), false, true)
		"unit_returned":
			_flag_unit(int(e.get("unit_id", 0)), false, false)
		_:
			pass


## Doc 06's fleet snapshot (`IncidentSystem.vehicle_states()`): one record per
## unit, `pos` in TILES, plus `speed`, `heading` and `status`. Call it once per
## sim TICK — calling it per frame is harmless (a pose that has not changed is
## not re-pushed, so the dead reckoning is never reset out from under itself),
## but it buys nothing.
##
## Units inside their station (IDLE / REFIT / OFFLINE) are not drawn; a unit
## that goes home is retired with the usual fade.
func apply_unit_states(states: Array) -> void:
	_ensure_setup()
	var seen: Dictionary = {}
	for entry: Variant in states:
		var s: Dictionary = entry
		var unit_id := int(s.get("id", 0))
		var key := EMERGENCY_KEY_BASE + unit_id
		var status := String(s.get("status", ""))
		if not ROLLING_STATUS.has(status):
			_retire(key)
			continue
		seen[key] = true
		var tile: Array = s.get("pos", [0, 0])
		var pos := Vector3((float(tile[0]) + 0.5) * tile_m, 0.0,
				(float(tile[1]) + 0.5) * tile_m)
		var heading := float(s.get("heading", 0.0))
		var speed := float(s.get("speed", 0.0))
		var stamp := "%d,%d,%s,%.3f,%.4f" % [int(tile[0]), int(tile[1]), status,
				speed, heading]
		var department := _department_of(String(s.get("type", "")))
		var v: VehicleMotion = _vehicles.get(key)
		if v == null:
			v = _make(key, String(DEPT_MESH.get(department, "utility")), department)
			v.kind = String(s.get("type", ""))
			v.paint = _paint_for(v)
			v.set_state(pos, heading, speed, _gm_per_s, true)
		elif String(_unit_stamp.get(key, "")) != stamp:
			v.set_state(pos, heading, speed, _gm_per_s)
		_unit_stamp[key] = stamp
		v.alive = true
		# A unit that is out is running its lamps; the night gate in `_upload`
		# decides whether they are visible.
		v.headlights = status != "ON_SCENE"
		# RESPONDING runs hot; ON_SCENE keeps the bar up as a scene marker;
		# RETURNING goes quiet — the shape of doc 06 §2.11's FSM, in light.
		v.siren = status == "RESPONDING"
		v.lightbar = status == "RESPONDING" or status == "ON_SCENE"
	for key: int in _vehicles.keys():
		if key >= EMERGENCY_KEY_BASE and not seen.has(key):
			_retire(key)


## One rendered frame. `night` is doc 11's day/night scalar (0 day … 1 night);
## pass -1 to leave it as it was. `gm_per_s` is game-minutes elapsed per real
## second — the sim speed multiplier, or 0 while paused, which parks every
## vehicle exactly where it stands instead of letting it drift.
func refresh(delta: float, night: float = -1.0, gm_per_s: float = -1.0) -> void:
	_ensure_setup()
	if night >= 0.0:
		_night = clampf(night, 0.0, 1.0)
	if gm_per_s >= 0.0:
		_gm_per_s = gm_per_s
	_time += delta
	var expired: Array = []
	for key: int in _vehicles:
		var v: VehicleMotion = _vehicles[key]
		v.advance(delta, _gm_per_s)
		if v.expired():
			expired.append(key)
	for key: int in expired:
		_drop(key)
	_upload()


func clear() -> void:
	for key: int in _vehicles.keys():
		_drop(key)
	_unit_stamp.clear()


func vehicle_count() -> int:
	return _vehicles.size()


func live_count() -> int:
	var n := 0
	for key: int in _vehicles:
		if (_vehicles[key] as VehicleMotion).alive:
			n += 1
	return n


func motion(key: int) -> VehicleMotion:
	return _vehicles.get(key)


## Draw calls this layer costs: one per body mesh plus the headlight cone.
func layer_count() -> int:
	return _layers.size() + (1 if _cone_node != null else 0)


# ------------------------------------------------------------------ ingest

func _ingest(e: Dictionary, spawned: bool) -> void:
	var key := _key_for(e)
	var v: VehicleMotion = _vehicles.get(key)
	var vehicle_class := String(e.get("vehicle_class", "civilian"))
	if v == null:
		var kind := String(e.get("kind", "car"))
		var mesh_key := String(DEPT_MESH[vehicle_class]) if DEPT_MESH.has(vehicle_class) \
				else (kind if CIV_KINDS.has(kind) else "car")
		v = _make(key, mesh_key, vehicle_class)
		v.kind = kind
		v.paint = _paint_for(v)
		spawned = true
	v.alive = true
	v.edge_id = int(e.get("edge_id", -1))
	v.headlights = bool(e.get("headlights", false))
	v.siren = bool(e.get("siren", false))
	v.lightbar = bool(e.get("lightbar", false))
	v.set_state(_as_vec3(e.get("pos", Vector3.ZERO)),
			float(e.get("heading", 0.0)), float(e.get("speed", 0.0)),
			_gm_per_s, spawned)


## Doc 10's packed pose event (doc 91 D-10's bus diet) — one event carrying
## every civilian vehicle's pose for this tick, in ascending id.
##
## The columns are read STRAIGHT out of the `Packed*Array`s. Round-tripping
## each row through `TrafficSnapshot.vehicle_at()` would be tidier to read and
## would re-allocate the 256 dictionaries the diet exists to delete, so the
## layout constants are used directly and the accessor is left for tests.
##
## A pose for a vehicle we have never seen is not an error and is not dropped:
## it is a spawn we missed (a save was loaded, the view was rebuilt, the batch
## was truncated), so the row seeds a fresh record exactly as `vehicle_spawned`
## would. The layer keys off the packed `kind` byte for its mesh.
func _ingest_snapshot(e: Dictionary) -> void:
	var count := TrafficSnapshot.vehicle_count(e)
	if count <= 0:
		return
	var ids: PackedInt32Array = e[TrafficSnapshot.KEY_IDS]
	var edge_ids: PackedInt32Array = e[TrafficSnapshot.KEY_EDGES]
	var kinds: PackedByteArray = e[TrafficSnapshot.KEY_KINDS]
	var flags: PackedByteArray = e[TrafficSnapshot.KEY_FLAGS]
	var pose: PackedFloat32Array = e[TrafficSnapshot.KEY_POSE]
	for index in count:
		var key := int(ids[index])
		var v: VehicleMotion = _vehicles.get(key)
		var spawned := false
		if v == null:
			var kind := TrafficSnapshot.kind_name(int(kinds[index]))
			v = _make(key, kind if CIV_KINDS.has(kind) else "car", "civilian")
			v.kind = kind
			v.paint = _paint_for(v)
			spawned = true
		var bits := int(flags[index])
		v.alive = true
		v.edge_id = int(edge_ids[index])
		v.headlights = (bits & TrafficSnapshot.FLAG_HEADLIGHTS) != 0
		# Civilians have neither, always — the packed format does not carry them.
		v.siren = false
		v.lightbar = false
		var base := index * TrafficSnapshot.POSE_STRIDE
		v.set_state(Vector3(pose[base + TrafficSnapshot.POSE_X], 0.0,
						pose[base + TrafficSnapshot.POSE_Z]),
				float(pose[base + TrafficSnapshot.POSE_HEADING]),
				float(pose[base + TrafficSnapshot.POSE_SPEED]),
				_gm_per_s, spawned)


func _key_for(e: Dictionary) -> int:
	var id := int(e.get("id", 0))
	var vehicle_class := String(e.get("vehicle_class", "civilian"))
	return id if vehicle_class == "civilian" else EMERGENCY_KEY_BASE + id


func _make(key: int, mesh_key: String, vehicle_class: String) -> VehicleMotion:
	var v := VehicleMotion.new(key)
	v.vehicle_class = vehicle_class
	v.mesh_key = mesh_key if _layers.has(mesh_key) else "car"
	v.blend_s = blend_s
	v.fade_s = fade_s
	v.teleport_m = teleport_m
	v.phase = VehicleMotion.hash01(key, 37)
	_vehicles[key] = v
	var layer: Layer = _layers[v.mesh_key]
	layer.list.append(v)
	return v


func _paint_for(v: VehicleMotion) -> Color:
	if v.vehicle_class != "civilian" and DEPT_PAINT.has(v.vehicle_class):
		return Color(String(DEPT_PAINT[v.vehicle_class]))
	var index := int(VehicleMotion.hash01(v.id, 91) * float(CIV_PAINT.size()))
	return Color(String(CIV_PAINT[clampi(index, 0, CIV_PAINT.size() - 1)]))


## Despawn: the record stays until it has faded out, so cars leave rather than
## blink away mid-street.
func _retire(key: int) -> void:
	var v: VehicleMotion = _vehicles.get(key)
	if v != null:
		v.alive = false


func _drop(key: int) -> void:
	var v: VehicleMotion = _vehicles.get(key)
	if v == null:
		return
	_vehicles.erase(key)
	_unit_stamp.erase(key)
	var layer: Layer = _layers.get(v.mesh_key)
	if layer != null:
		layer.list.erase(v)


func _flag_unit(unit_id: int, siren: bool, lightbar: bool) -> void:
	var v: VehicleMotion = _vehicles.get(EMERGENCY_KEY_BASE + unit_id)
	if v == null:
		return
	v.siren = siren
	v.lightbar = lightbar


func _department_of(type_id: String) -> String:
	return String(_dept_of_type.get(type_id, "utility"))


# ------------------------------------------------------------------ upload

## Rewrite every visible instance. At the sim's own cap (90 civilians on
## Balanced plus a dozen units) this is a couple of hundred transform writes a
## frame — far cheaper than tracking slot churn across spawns and despawns.
func _upload() -> void:
	var cone_i := 0
	var lit_min := 1.0 if night_threshold <= 0.0 else \
			clampf((_night - night_threshold) / 0.30, 0.0, 1.0)
	# Buffers are sized BEFORE anything is written: raising `instance_count`
	# clears the buffer, so growing mid-write would drop the instances already
	# placed this frame.
	if _cone_mm != null:
		_ensure_cone_capacity(_vehicles.size())
	for key: String in _layers:
		var layer: Layer = _layers[key]
		_ensure_capacity(layer, mini(layer.list.size(), layer.cap))
		var used := 0
		for entry: Variant in layer.list:
			var v: VehicleMotion = entry
			if used >= layer.cap:
				break
			if not v.seeded():
				continue
			var scale := VehicleMotion.smooth01(v.fade)
			if scale <= 0.001:
				continue
			var radius := _cull_radius(v)
			if radius > 0.0:
				var pos := v.position()
				if Vector2(pos.x - _focus.x, pos.z - _focus.z).length() > radius:
					continue
			var xform := v.transform(road_top, lane_offset, scale)
			layer.mm.set_instance_transform(used, xform)
			layer.mm.set_instance_color(used, v.paint)
			var lamps := lit_min if v.headlights else 0.0
			var bar := v.phase if v.lightbar else -1.0
			layer.mm.set_instance_custom_data(used,
					Color(VehicleMotion.hash01(v.id, 53), lamps, bar, v.fade))
			used += 1
			if lamps > 0.01 and _cone_mm != null and cone_i < _cone_mm.instance_count:
				_cone_mm.set_instance_transform(cone_i,
						xform.translated_local(Vector3(layer.nose, 0.0, 0.0)))
				_cone_mm.set_instance_custom_data(cone_i,
						Color(0.0, lamps, 0.0, v.fade))
				cone_i += 1
		layer.mm.visible_instance_count = used
		if layer.material != null:
			layer.material.set_shader_parameter("anim_time", _time)
			layer.material.set_shader_parameter("night_amt", _night)
	if _cone_mm != null:
		_cone_mm.visible_instance_count = cone_i
	_drive_beacons()


## Emergency traffic is never distance-culled at the civilian radius — a unit
## crossing the far side of the city is exactly the thing doc 11 §1 calls "the
## alive read". Returning 0 means "do not cull".
func _cull_radius(v: VehicleMotion) -> float:
	if not _has_focus or visible_radius <= 0.0:
		return 0.0
	return visible_radius if v.vehicle_class == "civilian" else visible_radius * 2.2


func _ensure_capacity(layer: Layer, needed: int) -> void:
	if needed <= layer.mm.instance_count:
		return
	# Growing resets the buffer; every visible instance is rewritten each frame
	# anyway, so there is nothing to preserve.
	layer.mm.instance_count = mini(layer.cap, ((needed / 32) + 1) * 32)


func _ensure_cone_capacity(needed: int) -> void:
	if needed <= _cone_mm.instance_count:
		return
	_cone_mm.instance_count = ((needed / 32) + 1) * 32


# ------------------------------------------------------------------ beacons

## Doc 11 §2.12's `Beacon`: a tiny pool of real OmniLight3Ds checked out to the
## nearest flashing units, so an emergency response throws colour onto the
## street instead of only glowing on its own roof. Everything else makes do
## with the emissive bar.
func _drive_beacons() -> void:
	if _beacons.is_empty():
		return
	var candidates: Array = []
	for key: int in _vehicles:
		var v: VehicleMotion = _vehicles[key]
		if not v.lightbar or not v.alive or not v.seeded():
			continue
		var d := 0.0
		if _has_focus:
			var p := v.position()
			d = Vector2(p.x - _focus.x, p.z - _focus.z).length()
		candidates.append({"d": d, "v": v})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(float(a["d"]) - float(b["d"])) > 0.01:
			return float(a["d"]) < float(b["d"])
		return (a["v"] as VehicleMotion).id < (b["v"] as VehicleMotion).id)
	for i in _beacons.size():
		var light: OmniLight3D = _beacons[i]
		if i >= candidates.size():
			light.visible = false
			continue
		var v: VehicleMotion = (candidates[i] as Dictionary)["v"]
		var cycle := fposmod(_time * lightbar_hz + v.phase, 1.0)
		var side := cycle >= 0.5
		var flash := 0.35 + 0.65 * (1.0 if fposmod(cycle * 4.0, 1.0) > 0.5 else 0.0)
		light.light_color = _bar_b.get(v.mesh_key, Color.WHITE) if side \
				else _bar_a.get(v.mesh_key, Color.WHITE)
		light.light_energy = lightbar_emission * 0.30 * flash \
				* lerpf(0.45, 1.0, _night) * v.fade
		light.position = v.position() + VehicleMotion.right_xz(v.heading()) \
				* lane_offset + Vector3(0.0, 2.2, 0.0)
		light.visible = true


func _size_beacons() -> void:
	while _beacons.size() > beacon_budget:
		var light: Node = _beacons.pop_back()
		light.queue_free()
	while _beacons.size() < beacon_budget:
		var light := OmniLight3D.new()
		light.name = "Beacon%d" % _beacons.size()
		light.omni_range = 13.0
		light.omni_attenuation = 1.6
		light.light_energy = 0.0
		light.shadow_enabled = false
		light.visible = false
		add_child(light)
		_beacons.append(light)


# -------------------------------------------------------------------- setup

func _ensure_setup() -> void:
	if not _configured:
		setup()


func _read_presets(render_data: Dictionary) -> void:
	var presets: Dictionary = render_data.get("presets", {})
	var row: Dictionary = presets.get(preset, {})
	caps = {
		"car": int(row.get("civ_cars", 160)),
		"van": int(row.get("civ_vans", 60)),
		"truck": int(row.get("civ_trucks", 36)),
	}
	var nodes := int(row.get("emergency_nodes", 20))
	for key: String in EMERGENCY_MESHES:
		caps[key] = nodes
	beacon_budget = clampi(int(row.get("emergency_lights", 4)), 0, 8)
	# The preset has the last word on shadows: a quality tier that has already
	# decided how many splits it can afford is the right place to decide whether
	# the traffic layer gets re-drawn into all of them. A row without the key
	# leaves `vehicles.cast_shadows` standing.
	if row.has("vehicle_shadows"):
		cast_shadows = bool(row["vehicle_shadows"])


## doc 06's `data/vehicles.json` is the only place that knows a type's
## department; reading it here keeps the department colours out of the shell.
func _read_departments() -> void:
	_dept_of_type.clear()
	var data: Dictionary = StarterCityLoader.read_json("res://data/vehicles.json")
	var types: Dictionary = data.get("types", {})
	for type_id: String in types:
		_dept_of_type[type_id] = String((types[type_id] as Dictionary).get(
				"department", "utility"))


func _build_layers(cfg: Dictionary) -> void:
	for key: String in _layers.keys():
		(_layers[key] as Layer).node.queue_free()
	_layers.clear()
	var shader: Shader = load("res://game/shaders/vehicle.gdshader")
	var aabb := AABB(Vector3(-world_m * 0.05, -4.0, -world_m * 0.05),
			Vector3(world_m * 1.1, 24.0, world_m * 1.1))
	var keys: Array = []
	keys.append_array(CIV_KINDS)
	keys.append_array(EMERGENCY_MESHES)
	for key: String in keys:
		var layer := Layer.new()
		layer.key = key
		layer.cap = int(caps.get(key, 128))
		layer.nose = VehicleMesh.nose_x(key)
		layer.material = ShaderMaterial.new()
		layer.material.shader = shader
		layer.material.set_shader_parameter("bar_hz", lightbar_hz)
		layer.material.set_shader_parameter("bar_energy", lightbar_emission)
		layer.material.set_shader_parameter("atlas_cells", _atlas_cells)
		if _atlas != null:
			layer.material.set_shader_parameter("body_tex", _atlas)
			layer.material.set_shader_parameter("tex_mix", 1.0)
		else:
			layer.material.set_shader_parameter("tex_mix", 0.0)
		if _bar_a.has(key):
			layer.material.set_shader_parameter("bar_a_color", _bar_a[key])
			layer.material.set_shader_parameter("bar_b_color", _bar_b[key])
		layer.mm = MultiMesh.new()
		layer.mm.transform_format = MultiMesh.TRANSFORM_3D
		layer.mm.use_colors = true
		layer.mm.use_custom_data = true
		layer.mm.mesh = VehicleMesh.factory(key).to_mesh(layer.material)
		layer.mm.instance_count = mini(layer.cap, 32)
		layer.mm.visible_instance_count = 0
		layer.node = MultiMeshInstance3D.new()
		layer.node.name = "MM_%s" % key
		layer.node.multimesh = layer.mm
		layer.node.custom_aabb = aabb
		# Shadows are a real quality win on traffic and a real cost: the
		# world-sized custom AABB means each body layer is always inside EVERY
		# shadow split, so a layer is re-drawn once per split whether or not a
		# car is standing in it. The performance pass took the switch (report 98
		# / vehicle q5): OFF on Performance and Balanced, ON on High, driven by
		# the preset's `vehicle_shadows` row.
		layer.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
				if cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(layer.node)
		_layers[key] = layer

	if _cone_node != null:
		_cone_node.queue_free()
	_cone_material = ShaderMaterial.new()
	_cone_material.shader = load("res://game/shaders/vehicle_headlight.gdshader")
	_cone_material.set_shader_parameter("cone_color",
			_col(cfg, "headlight_color", "#FFE7B4"))
	_cone_material.set_shader_parameter("cone_energy",
			_num(cfg, "headlight_cone_energy", 0.22))
	_cone_mm = MultiMesh.new()
	_cone_mm.transform_format = MultiMesh.TRANSFORM_3D
	_cone_mm.use_custom_data = true
	_cone_mm.mesh = VehicleMesh.headlight_cone(cone_len, 0.66,
			maxf(cone_len * 0.32, 1.3), 0.03)
	_cone_mm.mesh.surface_set_material(0, _cone_material)
	_cone_mm.instance_count = 32
	_cone_mm.visible_instance_count = 0
	_cone_node = MultiMeshInstance3D.new()
	_cone_node.name = "MM_headlights"
	_cone_node.multimesh = _cone_mm
	_cone_node.custom_aabb = aabb
	_cone_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_cone_node)
	_size_beacons()


# ------------------------------------------------------------------ helpers

static func _num(cfg: Dictionary, key: String, fallback: float) -> float:
	return float(cfg.get(key, fallback))


static func _col(cfg: Dictionary, key: String, fallback: String) -> Color:
	var hex := String(cfg.get(key, fallback))
	return Color(hex) if Color.html_is_valid(hex) else Color(fallback)


## `pos` arrives as a Vector3 from doc 10's feed; a caller reshaping doc 06's
## tile pairs may hand over an Array instead.
static func _as_vec3(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and (value as Array).size() >= 3:
		var a: Array = value
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO
