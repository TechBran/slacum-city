extends SceneTree
## Render-frame profiler — doc 11 §2.13's table, measured instead of predicted.
##
## `tools/profile_sim.gd` answers "what does a sim step cost?"; this answers the
## other half: **what does a FRAME cost, at each of §2.5's three camera poses,
## on a real city?** It boots a `CitySim` from a city file (doc 09 §2.13's
## benchmark fixture by default), assembles the same render stack `game/main.gd`
## assembles — `RenderStateModel` + `CityView` + `RoadSurfaceView` +
## `StreetlightView` + `VehicleView` + `EnvironmentController` + `CameraRig`,
## with the lamps placed by `StreetlightPlacer` — parks the camera at
## Z0 / Z1 / Z2 in turn, and reports CPU render time, GPU render time, draw
## calls, primitives and the chunk-tier census at each.
##
## It is a MEASURING instrument (constitution §3): it owns no constant, reads
## every threshold from `data/render.json`, and nothing in `sim/` or `game/`
## imports it.
##
## WHAT IT DELIBERATELY DOES NOT BUILD: the UI `CanvasLayer`. Doc 11 §2.13
## budgets UI separately at ~25 batched CanvasItem calls, and mixing it in would
## make the city's own draw-call figure unreadable. Add 25 to the `dc` column to
## compare against the 320 budget; the table prints both.
##
## Usage (needs a display — this renders):
##   ~/.local/bin/godot --path "/home/bbx/Slacum City game" \
##       -s res://tools/profile_frame.gd -- [options]
##
##   --city=PATH        city file (default res://tests/fixtures/bench_city.json)
##   --preset=NAME      performance | balanced | high      (default balanced)
##   --hour=H           hour of day, 0..24                 (default 21 — night,
##                      the emissive/glow worst case)
##   --poses=z0,z1,z2   which §2.5 poses to measure        (default all three)
##   --warmup=N         frames discarded per pose          (default 90)
##   --frames=N         frames measured per pose           (default 180)
##   --resolution=WxH   render size                        (default 1920x1080)
##   --out=FILE         write the run as JSON
##   --shots=DIR        save one PNG per pose into DIR (`<pose>.png`)
##   --focus=TX,TZ      aim the poses at this TILE instead of the city centre
##                      (Z0 sits 18 m off the focus, and the authored centre can
##                      put that camera inside a tower)
##   --atlas-lod=N      cut the merged MEDIUM atlas from LOD N instead of
##                      `CityView.atlas_lod`. 0 keeps the un-merged tier's
##                      picture exactly; 1 is §2.5's ladder and costs the
##                      commercial banding — the A/B behind that ruling.
##   --no-power-infra   leave the visible power layer (`PowerInfraView`) out.
##                      The A/B behind its §2.13 draw-call claim: the two runs
##                      differ in nothing else, so the `dc` delta IS the layer.
##   --power-distress=F force this fraction of the transformer roster into the
##                      SEVERE band (0..1) before measuring, so the smoke and
##                      spark buffer is exercised rather than assumed absent.
##                      Render-side only — the sim is not touched.
##   --no-merge         draw the pre-D-14 renderer: one MultiMesh per
##                      (chunk, archetype, level) at MEDIUM, instead of the
##                      merged per-archetype atlas. The A/B switch the
##                      §2.13 as-shipped table's before column is measured with,
##                      and — with `--shots` — the one the "no visible pop"
##                      claim is checked with, since the two runs differ in
##                      nothing else.
##   --quiet            table only
##
## The first pose absorbs shader compilation and the first MultiMesh uploads,
## which is why `--warmup` exists and why the table prints the warm figure only.

const CITY_DEFAULT := "res://tests/fixtures/bench_city.json"
const RENDER_JSON := "res://data/render.json"
const MESH_MANIFEST := "res://game/meshes/generated/manifest.json"

## §2.5's three published poses, as `zoom_t` values `CameraState` maps to
## (D, pitch). The names are doc 11's.
const POSES := {
	"z0": {"zoom_t": 0.0, "label": "Z0  D 18 m / 34°"},
	"z1": {"zoom_t": 0.5, "label": "Z1  D 86.9 m / 48°"},
	"z2": {"zoom_t": 1.0, "label": "Z2  D 420 m / 62°"},
}

## Doc 11 §2.13's non-chunk draw-call terms, for the "predicted" column. The
## harness does not draw the UI, so the comparison has to say so out loud.
const UI_DRAW_CALLS := 25

var _opts: Dictionary = {}
var _render_data: Dictionary = {}
var _sim: CitySim
var _model: RenderStateModel
var _city_view: CityView
var _roads: RoadSurfaceView
var _streetlights: StreetlightView
var _vehicles: VehicleView
var _env: EnvironmentController
var _camera_state: CameraState
var _camera_rig: CameraRig
var _power_infra: PowerInfraView
var _family_of: Dictionary = {}
var _height_of: Dictionary = {}
## Set by `--power-distress=`: the render rows the harness feeds instead of the
## sim's, so the smoke/spark buffer can be measured without cooking the sim.
var _forced_rows: Array = []

var _order: Array = []
var _pose_index := 0
var _frames_seen := 0
var _samples: Array = []
var _results: Array = []
var _started := false


func _initialize() -> void:
	_opts = _parse(OS.get_cmdline_user_args())
	if _opts.has("error"):
		printerr("profile_frame: " + String(_opts["error"]))
		quit(2)
		return
	_render_data = StarterCityLoader.read_json(RENDER_JSON)
	if _render_data.is_empty():
		printerr("profile_frame: cannot read " + RENDER_JSON)
		quit(2)
		return
	if not FileAccess.file_exists(String(_opts["city"])):
		printerr("profile_frame: no such city file " + String(_opts["city"]))
		quit(2)
		return

	_sim = CitySim.new()
	_sim.boot(1337,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(String(_opts["city"])),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	if not _sim.boot_errors.is_empty():
		for message in _sim.boot_errors:
			printerr("profile_frame: boot error: " + String(message))

	var size: Vector2i = _opts["resolution"]
	root.size = size
	# `measure_render_time` is what makes the CPU/GPU columns real rather than
	# an estimate off the frame delta — without it the server returns 0.
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	# Without this every frame reads as exactly one refresh interval and the
	# mean/p95 columns measure the monitor instead of the renderer.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	if not bool(_opts["quiet"]):
		print("profile_frame: %s — %d buildings, preset %s, hour %.1f, %dx%d" % [
				String(_opts["city"]), _sim.buildings.size(), String(_opts["preset"]),
				float(_opts["hour"]), size.x, size.y])


# ---------------------------------------------------------------- the scene

func _build_scene() -> void:
	var stage := Node3D.new()
	stage.name = "ProfileStage"
	root.add_child(stage)

	# --- environment (sky, sun, moon, fog, glow) -------------------------
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	world_environment.environment = environment
	stage.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	stage.add_child(sun)
	var moon := DirectionalLight3D.new()
	moon.shadow_enabled = false
	stage.add_child(moon)
	_env = EnvironmentController.new()
	stage.add_child(_env)
	_env.world_environment_path = world_environment.get_path()
	_env.sun_path = sun.get_path()
	_env.moon_path = moon.get_path()
	_env.setup(_render_data)

	# --- ground, roads, water -------------------------------------------
	_build_ground(stage)

	# --- the city ---------------------------------------------------------
	_model = RenderStateModel.new(_render_data, String(_opts["preset"]))
	var manifest: Dictionary = StarterCityLoader.read_json(MESH_MANIFEST)
	for entry in manifest.get("meshes", []):
		_family_of[String(entry["archetype"])] = String(entry.get("family", "residential"))
		if int(entry.get("lod", 0)) == 0:
			_height_of["%s:%d" % [entry["archetype"], int(entry["level"])]] = \
					float(entry.get("height_m", 10.0))
	for id in _sim.buildings.keys():
		_model.add_building(_building_view(String(id)))
	_city_view = CityView.new()
	_city_view.medium_merge_enabled = not bool(_opts["no_merge"])
	if int(_opts["atlas_lod"]) >= 0:
		_city_view.atlas_lod = int(_opts["atlas_lod"])
	stage.add_child(_city_view)
	_city_view.setup(_model, _render_data)

	# doc 11 §2.10's art density, off the road graph: one lamp every
	# `road_surface.lamp.spacing_tiles` along a corridor, standing ON the kerb
	# and facing the carriageway. Deliberately NOT doc 04's one-per-road-tile
	# electrical sink.
	var lamps := StreetlightPlacer.place(_sim.world.grid,
			_sim.roads.graph if _sim.roads != null else null, _render_data,
			_sim.world.block_of_tile)
	_streetlights = StreetlightView.new()
	stage.add_child(_streetlights)
	_streetlights.setup(_model, _render_data, lamps)

	_vehicles = VehicleView.new()
	stage.add_child(_vehicles)
	_vehicles.setup(_render_data)
	_vehicles.set_preset(String(_opts["preset"]), _render_data)

	# --- the visible power layer (doc 04's distribution end, drawn) --------
	# Built exactly the way `game/main.gd` builds it, so the `dc` column below
	# is the shipped shape and not a harness-only arrangement.
	if not bool(_opts["no_power_infra"]):
		_power_infra = PowerInfraView.new()
		stage.add_child(_power_infra)
		_power_infra.setup(_render_data, func(archetype: StringName, level: int) -> float:
				return float(_height_of.get("%s:%d" % [archetype, level], 10.0)))
		_power_infra.set_road_probe(PowerInfraFeed.road_probe(_sim.world))
		_power_infra.sync(_sim, 0.0, Vector3.ZERO)
		_force_distress(float(_opts["power_distress"]))

	# --- camera -----------------------------------------------------------
	_camera_state = CameraState.load_from_files()
	# `D_MAX_eff` is derived from the owned-land AABB (doc 12 §2.16), so a rig
	# that never learns the city's extent caps `zoom_t` below 1.0 and Z2 is
	# unreachable — the pose would silently be measured somewhere else.
	var min_xz := Vector2(INF, INF)
	var max_xz := Vector2(-INF, -INF)
	for block_id in _sim.world.block_ids_sorted():
		var block: LandBlock = _sim.world.block(block_id)
		if not block.is_ready():
			continue
		min_xz = Vector2(minf(min_xz.x, block.grid.x * 128.0),
				minf(min_xz.y, block.grid.y * 128.0))
		max_xz = Vector2(maxf(max_xz.x, block.grid.x * 128.0 + 128.0),
				maxf(max_xz.y, block.grid.y * 128.0 + 128.0))
	if min_xz.x < INF:
		_camera_state.set_owned_land_aabb(min_xz, max_xz)
	var centre: Array = (_sim.loader.world_header.get("city_center_tile", [56, 56]) as Array)
	var focus := Vector3(float(centre[0]) * 8.0, 0.0, float(centre[1]) * 8.0)
	var wanted: Vector2 = _opts["focus"]
	if wanted.x >= 0.0:
		focus = Vector3(wanted.x * 8.0, 0.0, wanted.y * 8.0)
	_camera_state.set_focus(focus)
	_camera_rig = CameraRig.new()
	stage.add_child(_camera_rig)
	_camera_rig.setup(_camera_state, _render_data)


## `--power-distress=F`: push the first `F` of the transformer roster (sorted, so
## the choice is reproducible) into doc 04's SEVERE band, RENDER-SIDE ONLY. The
## grid is not touched, no RNG is drawn and no state hash moves — the harness
## simply hands `PowerInfraView` a different set of read-only rows, which is what
## it would have got had those transformers actually been cooking.
func _force_distress(fraction: float) -> void:
	_forced_rows = []
	if _power_infra == null or fraction <= 0.0:
		return
	var rows: Array = PowerInfraFeed.state(_sim)
	var wanted := int(ceil(float(rows.size()) * fraction))
	for i in rows.size():
		var row: Dictionary = (rows[i] as Dictionary).duplicate()
		if i < wanted:
			row["state"] = "OK"
			row["energized"] = true
			row["load_ratio"] = PowerInfraModel.severe_ratio() + 0.25
			row["temp_c"] = 130.0
		_forced_rows.append(row)
	_power_infra.apply_state(_forced_rows)
	if not bool(_opts["quiet"]):
		print("profile_frame: forced %d/%d transformers into SEVERE"
				% [wanted, rows.size()])


func _build_ground(stage: Node3D) -> void:
	var ground := Node3D.new()
	ground.name = "Ground"
	stage.add_child(ground)
	var developed := GroundSurface.material("pavement", Vector2(128.0, 128.0),
			Color(0.52, 0.53, 0.52), 0.90)
	var undeveloped := GroundSurface.material("pavement", Vector2(128.0, 128.0),
			Color(0.40, 0.50, 0.36), 1.00)
	for block_id in _sim.world.block_ids_sorted():
		var block: LandBlock = _sim.world.block(block_id)
		var plane := MeshInstance3D.new()
		var mesh := PlaneMesh.new()
		mesh.size = Vector2(128.0, 128.0)
		plane.mesh = mesh
		plane.material_override = developed if block.is_ready() else undeveloped
		plane.position = Vector3(block.grid.x * 128.0 + 64.0, 0.0, block.grid.y * 128.0 + 64.0)
		ground.add_child(plane)

	# doc 11 §2.1.2's street: asphalt, markings, kerbs and footways off the road
	# GRAPH. Two draw calls city-wide, which is what the `dc` column has to see.
	_roads = RoadSurfaceView.new()
	_roads.name = "RoadSurface"
	ground.add_child(_roads)
	_roads.setup(_render_data)
	_roads.rebuild(_sim.world.grid, _sim.roads.graph if _sim.roads != null else null)

	var water_mm := MultiMesh.new()
	water_mm.transform_format = MultiMesh.TRANSFORM_3D
	var quad := PlaneMesh.new()
	quad.size = Vector2(8.0, 8.0)
	quad.material = GroundSurface.water()
	water_mm.mesh = quad
	water_mm.instance_count = _sim.loader.water_tiles.size()
	var wi := 0
	for pair in _sim.loader.water_tiles:
		var tile := StarterCityLoader.core_to_global(int(pair[0]), int(pair[1]))
		water_mm.set_instance_transform(wi, Transform3D(Basis.IDENTITY,
				Vector3(tile.x * 8.0 + 4.0, 0.08, tile.y * 8.0 + 4.0)))
		wi += 1
	var water_node := MultiMeshInstance3D.new()
	water_node.name = "Water"
	water_node.multimesh = water_mm
	ground.add_child(water_node)


func _building_view(sim_id: String) -> Dictionary:
	var b: Building = _sim.buildings.get(sim_id)
	var record: Dictionary = _sim._building_records[sim_id]
	var size: Vector2i = record["footprint"]
	var centre := Vector3(b.origin.x * 8.0 + size.x * 4.0, 0.0,
			b.origin.y * 8.0 + size.y * 4.0)
	return {
		"id": b.id,
		"archetype_id": StringName(b.archetype),
		"level": maxi(b.level, 1),
		"family": String(_family_of.get(String(b.archetype), "residential")),
		"world_pos": centre,
		"block_id": String(record.get("block", "")),
		"transform": Transform3D(Basis.IDENTITY, centre),
		"occ_b": 1.0,
		"powered": true,
		"condition": b.condition,
		"construction_stage": 0,
	}


# ------------------------------------------------------------------ the loop

func _apply_pose(index: int) -> void:
	_pose_index = index
	_frames_seen = 0
	_samples.clear()
	var key := String(_order[index])
	var wanted := float((POSES[key] as Dictionary)["zoom_t"])
	_camera_state.set_zoom_t(wanted)
	if absf(_camera_state.zoom_t - wanted) > 1e-3:
		printerr(("profile_frame: pose %s wanted zoom_t %.2f but the rig clamped to %.2f "
				+ "(D_MAX_eff) — this measurement is NOT at the published pose")
				% [key, wanted, _camera_state.zoom_t])
	_camera_rig.camera.global_transform = _camera_state.camera_transform()
	# A pose jump re-tiers every chunk, and §2.5 allows at most ONE tier step per
	# `lod_dwell_s`. Leaving that to the warm-up frames is a bug in this harness,
	# not a conservative choice: on the starter city a frame is 0.8 ms, so 90
	# warm-up frames are 72 ms of model time against a 500 ms dwell and the pose
	# is MEASURED MID-TRANSITION — which is how a Z2 row came out "9 NEAR chunks"
	# at a camera 370 m up, where §2.5 says no chunk can be NEAR at all.
	#
	# So the ladder is walked here instead, explicitly: four steps of a full
	# dwell, which is one more than the deepest legal transition (NEAR → MEDIUM →
	# FAR → CULLED). The measured frames then all sit in the steady state, which
	# is what the table claims to report, on a fast city and a slow one alike.
	for _step in 4:
		_model.update_chunk_tiers(_camera_rig.camera.global_position, _model.lod_dwell_s)


func _process(delta: float) -> bool:
	if _sim == null:
		return true
	if not _started:
		# The scene is built on the FIRST frame, not in `_initialize`: nodes are
		# only `get_path()`-addressable once the window's tree is live, and
		# `EnvironmentController` resolves its sun/sky by NodePath.
		_build_scene()
		_order = _opts["poses"]
		_apply_pose(0)
		_started = true
		return false
	var hour := float(_opts["hour"])
	_env.apply(hour, delta)
	var camera_pos := _camera_rig.camera.global_position
	# A large dwell so a pose change re-tiers in ONE call: the profiler is not
	# measuring the hysteresis, it is measuring the steady state on either side.
	_city_view.refresh(delta, hour, camera_pos)
	_streetlights.refresh()
	_vehicles.set_focus(_camera_state.focus)
	_vehicles.refresh(delta, _env.last_night, 1.0)
	if _power_infra != null:
		# `refresh`, not `sync`: the harness holds the sim still, and re-polling
		# a frozen grid every frame would measure the poll instead of the layer.
		# `--power-distress` has already put the rows it wants in place.
		_power_infra.refresh(delta, camera_pos)

	_frames_seen += 1
	if _frames_seen > int(_opts["warmup"]):
		var rid := root.get_viewport_rid()
		_samples.append({
			"frame_ms": delta * 1000.0,
			"cpu_ms": RenderingServer.viewport_get_measured_render_time_cpu(rid),
			"gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(rid),
			"draw_calls": int(Performance.get_monitor(
					Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			"primitives": int(Performance.get_monitor(
					Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		})
	if _samples.size() < int(_opts["frames"]):
		return false

	_capture(String(_order[_pose_index]))
	_results.append(_summarise(String(_order[_pose_index])))
	if _pose_index + 1 < _order.size():
		_apply_pose(_pose_index + 1)
		return false
	_report()
	return true


## The measured frame, as a picture. Taken AFTER the last sample of a pose, so
## what lands on disk is the settled steady state the row above it reports —
## the same frame, not a neighbouring one.
func _capture(pose_key: String) -> void:
	var dir := String(_opts["shots"])
	if dir == "":
		return
	DirAccess.make_dir_recursive_absolute(dir)
	var image := root.get_texture().get_image()
	if image == null:
		printerr("profile_frame: no viewport image to capture")
		return
	var path := dir.path_join("%s.png" % pose_key)
	if image.save_png(path) != OK:
		printerr("profile_frame: cannot write " + path)
	elif not bool(_opts["quiet"]):
		print("wrote " + path)


func _summarise(pose_key: String) -> Dictionary:
	var frame := PackedFloat64Array()
	var cpu := 0.0
	var gpu := 0.0
	var draw_calls := 0
	var primitives := 0
	for s: Dictionary in _samples:
		frame.append(float(s["frame_ms"]))
		cpu += float(s["cpu_ms"])
		gpu += float(s["gpu_ms"])
		draw_calls = maxi(draw_calls, int(s["draw_calls"]))
		primitives = maxi(primitives, int(s["primitives"]))
	var n := maxi(1, frame.size())
	frame.sort()
	var census: Dictionary = _model.tier_census()
	var split: Dictionary = _city_view.perf_stats()
	return {
		"pose": pose_key,
		"label": String((POSES[pose_key] as Dictionary)["label"]),
		"frame_mean_ms": _mean(frame),
		"frame_p95_ms": frame[clampi(int(ceil(0.95 * float(n))) - 1, 0, n - 1)],
		"frame_max_ms": frame[n - 1],
		"cpu_ms": cpu / float(n),
		"gpu_ms": gpu / float(n),
		"draw_calls": draw_calls,
		"draw_calls_with_ui": draw_calls + UI_DRAW_CALLS,
		"primitives": primitives,
		"bucket_nodes_visible": _city_view.building_draw_calls(),
		# D-14's whole question is WHERE the building calls come from, so the
		# three kinds are reported apart: per-(archetype, level) LOD0 buckets,
		# merged per-archetype MEDIUM nodes, and the shared FAR box per chunk.
		"bucket_calls": int(split.get("bucket_calls", 0)),
		"merged_calls": int(split.get("merged_calls", 0)),
		"far_calls": int(split.get("far_calls", 0)),
		"chunks": int(census.get("near", 0)) + int(census.get("medium", 0))
				+ int(census.get("far", 0)),
		"near": int(census.get("near", 0)),
		"medium": int(census.get("medium", 0)),
		"far": int(census.get("far", 0)),
		"culled": int(census.get("culled", 0)),
		"instances": _model.building_count(),
		# The visible power layer, counted the way it is budgeted: nodes
		# SUBMITTED, not nodes allocated.
		"power_calls": _power_infra.draw_calls() if _power_infra != null else 0,
		"power_wire_buckets": _power_infra.visible_wire_bucket_count() \
				if _power_infra != null else 0,
		"power_puffs": _power_infra.live_puff_count() if _power_infra != null else 0,
	}


static func _mean(values: PackedFloat64Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for v in values:
		total += v
	return total / float(values.size())


func _report() -> void:
	var preset_row: Dictionary = (_render_data.get("presets", {}) as Dictionary) \
			.get(String(_opts["preset"]), {})
	var budget := int(preset_row.get("draw_call_budget", 320))
	print("")
	print("=== FRAME COST — %s, preset %s, hour %.1f ===" % [
			String(_opts["city"]).get_file(), String(_opts["preset"]), float(_opts["hour"])])
	var header := "  %-22s %8s %8s %8s %8s %6s %6s %6s %5s %5s %5s %5s %5s %5s %9s" % [
			"pose", "mean ms", "p95 ms", "rs cpu", "rs gpu", "dc", "dc+ui",
			"budget", "buck", "merg", "far#", "near", "med", "far", "prims"]
	print(header)
	print("  " + "-".repeat(header.length()))
	for row: Dictionary in _results:
		print("  %-22s %8.2f %8.2f %8.3f %8.3f %6d %6d %6d %5d %5d %5d %5d %5d %5d %9d" % [
				String(row["label"]), float(row["frame_mean_ms"]), float(row["frame_p95_ms"]),
				float(row["cpu_ms"]), float(row["gpu_ms"]), int(row["draw_calls"]),
				int(row["draw_calls_with_ui"]), budget, int(row["bucket_calls"]),
				int(row["merged_calls"]), int(row["far_calls"]),
				int(row["near"]), int(row["medium"]), int(row["far"]),
				int(row["primitives"])])
	print("  `rs cpu` / `rs gpu` are the RenderingServer's own measured times for"
			+ " this viewport. They do NOT sum to `mean ms`: the remainder is"
			+ " main-thread work (the render layer's per-frame GDScript) plus"
			+ " present. On a large city that remainder is the frame.")
	print("  instances resident %d   (preset instance_budget %d)" % [
			_model.building_count(), int(preset_row.get("instance_budget", 0))])
	if _power_infra != null:
		var power_line := "  power layer (pads / wires / distress) per pose: "
		for row: Dictionary in _results:
			power_line += "%s %d dc (%d wire buckets, %d puffs)   " % [
					String(row["pose"]), int(row["power_calls"]),
					int(row["power_wire_buckets"]), int(row["power_puffs"])]
		print(power_line)
	print("  NOTE: the UI CanvasLayer is not built by this harness; `dc+ui` adds"
			+ " §2.13's %d batched UI calls so the budget column compares." % UI_DRAW_CALLS)
	var out := String(_opts["out"])
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f == null:
			printerr("profile_frame: cannot write " + out)
			return
		f.store_string(JSON.stringify({
			"city": String(_opts["city"]), "preset": String(_opts["preset"]),
			"hour": float(_opts["hour"]), "buildings": _sim.buildings.size(),
			"resolution": [(_opts["resolution"] as Vector2i).x,
					(_opts["resolution"] as Vector2i).y],
			"poses": _results,
		}, "  ", true, true))
		f.close()
		print("wrote " + out)


# ------------------------------------------------------------------- options

func _parse(argv: PackedStringArray) -> Dictionary:
	var opts := {
		"city": CITY_DEFAULT, "preset": "balanced", "hour": 21.0,
		"poses": ["z0", "z1", "z2"], "warmup": 90, "frames": 180,
		"resolution": Vector2i(1920, 1080), "out": "", "quiet": false,
		"shots": "", "no_merge": false, "atlas_lod": -1,
		"focus": Vector2(-1.0, -1.0),
		"no_power_infra": false, "power_distress": 0.0,
	}
	for raw in argv:
		var arg := String(raw)
		if arg == "--quiet":
			opts["quiet"] = true
		elif arg == "--no-merge":
			opts["no_merge"] = true
		elif arg == "--no-power-infra":
			opts["no_power_infra"] = true
		elif arg.begins_with("--power-distress="):
			opts["power_distress"] = clampf(float(arg.substr(17)), 0.0, 1.0)
		elif arg.begins_with("--atlas-lod="):
			opts["atlas_lod"] = int(arg.substr(12))
		elif arg.begins_with("--shots="):
			opts["shots"] = arg.substr(8)
		elif arg.begins_with("--focus="):
			# TILE coordinates. Z0 parks 18 m off the focus, so the default city
			# centre can put the camera INSIDE a tower; aiming at a junction is
			# the only way to review the street surface at that pose.
			var f := arg.substr(8).split(",")
			if f.size() != 2:
				opts["error"] = "--focus wants tile_x,tile_z"
			else:
				opts["focus"] = Vector2(float(f[0]), float(f[1]))
		elif arg.begins_with("--city="):
			opts["city"] = arg.substr(7)
		elif arg.begins_with("--preset="):
			opts["preset"] = arg.substr(9)
		elif arg.begins_with("--hour="):
			opts["hour"] = float(arg.substr(7))
		elif arg.begins_with("--warmup="):
			opts["warmup"] = maxi(0, int(arg.substr(9)))
		elif arg.begins_with("--frames="):
			opts["frames"] = maxi(1, int(arg.substr(9)))
		elif arg.begins_with("--out="):
			opts["out"] = arg.substr(6)
		elif arg.begins_with("--resolution="):
			var parts := arg.substr(13).split("x")
			if parts.size() != 2:
				opts["error"] = "--resolution wants WxH"
			else:
				opts["resolution"] = Vector2i(int(parts[0]), int(parts[1]))
		elif arg.begins_with("--poses="):
			var wanted: Array = []
			for name in arg.substr(8).split(","):
				var key := String(name).strip_edges().to_lower()
				if not POSES.has(key):
					opts["error"] = "unknown pose '%s' (want z0|z1|z2)" % key
				else:
					wanted.append(key)
			if not wanted.is_empty():
				opts["poses"] = wanted
		else:
			opts["error"] = "unknown option: " + arg
	return opts
