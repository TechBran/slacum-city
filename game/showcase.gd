extends Node3D
## Showcase / render-stress scene: a synthetic grown metropolis built straight
## into the RenderStateModel — every archetype at every level, a downtown of
## L3–L5 towers, a data-center campus, residential rings, a canal cut through
## the middle of it and a dozen live construction sites with traffic on the
## avenues. No simulation; this is the renderer's ceiling and the skyline demo,
## and it is the frame the project is marketed on.
##
## It exists to exercise the WHOLE render stack in one scene, so every pass
## that lands in `game/render` or `game/shaders` shows up here or it is not
## finished: textured façades and roofs, the per-family window nits, the FAR
## band tier, the animated water, weather + wetness + lightning, streetlights,
## construction shells and props, and the vehicle layer.
##
## The surface pass added three things that had nowhere else to be judged:
## the ground is built as one 128 m plane per chunk with the four DISTRICT
## tones quartered across the grid (doc 09's `color_index`, which the showcase
## has no sim to ask for and so synthesises); the traffic batch carries one body
## from each department so the LIVERY cells and the light-bar strobe are on
## screen; and `--overlay=N` now pushes the mode into the RenderStateModel as
## well as into `sc_overlay_mode`, without which the FAR tier's chunk-aggregate
## overlay has no state to draw.
##
## Args (after `--`), all optional:
##   --screenshot=<path>   --shot-at=<seconds>    --hour=<0..24>
##   --zoom=<0..1>         doc 12's zoom_t: 0 = Z0 street, 1 = Z2 skyline
##   --focus=x,z           ground point the zoom pose looks at
##   --yaw=<deg>           orbit around that focus
##   --cam=x,y,z --look=x,y,z    cinematic free camera (overrides --zoom)
##   --storm=<0..1>        THUNDERSTORM at that precip01
##   --rain=<0..1>         RAIN at that precip01
##   --lightning-at=<s>    fire one stroke at that time
##   --overlay=<0..5>      doc 12 §2.5 overlay mode
##   --blackout-at=<s>     cut the eastern half at that time
##   --preset=<name>       performance | balanced | high
##   --no-lod              draw every chunk at LOD0 (the pre-far-tier renderer)
##   --stats               print the frame-time / draw-call summary

const CHUNKS := 6  # 6×6 chunks = 768 m square
const PARCEL_TILES := 3
const SPAN := CHUNKS * 128.0
## The canal, in tiles. A straight cut west→east plus one branch running south,
## so the water shader is seen both broadside and end-on in the hero pose.
const CANAL_Z := Vector2i(46, 48)
const CANAL_X := Vector2i(69, 71)
const CANAL_BRANCH_FROM_Z := 48
## Construction sites, as a fraction of the buildings placed.
const SITE_FRACTION := 0.03
## Frames before the frame-time average starts counting.
const WARMUP_S := 1.0
## `data/ui.json`'s `overlay.modes`, in the order `sc_overlay_mode` indexes them
## (doc 12 §2.5). `--overlay=N` picks one; the name is what the RenderStateModel
## needs, the index is what the shaders read.
const OVERLAY_MODES := ["none", "power", "water", "police", "fire", "traffic"]

var render_model: RenderStateModel
var city_view: CityView
var streetlights: StreetlightView
var sites: ConstructionSiteView
var vehicles: VehicleView
var weather: WeatherFX
var environment_controller: EnvironmentController

var _screenshot_path := ""
var _hour := 21.0
var _timer := 0.0
var _shot_at := 2.0
var _blackout_at := -1.0
var _lightning_at := -1.0
var _cam_pos := Vector3(90.0, 210.0, 900.0)
var _cam_look := Vector3(384.0, 70.0, 340.0)
var _free_camera := true
var _zoom_t := 1.0
var _yaw_deg := 0.0
var _focus := Vector3(SPAN * 0.5, 0.0, SPAN * 0.5)
var _preset := "high"
var _overlay := 0
var _storm := ""
var _precip := 0.0
var _stats := false
var _lod := true
var _camera: Camera3D
var _frames := 0
var _frame_ms_sum := 0.0
var _frame_ms_max := 0.0
var _draw_calls := 0
var _gpu_ms_sum := 0.0
var _cpu_ms_sum := 0.0

var _ring_mix := {
	0: [["high_rise", 3, 5, 4.0], ["office", 4, 5, 2.5], ["apartment", 4, 5, 1.0]],
	1: [["office", 2, 4, 2.0], ["apartment", 3, 5, 2.5], ["data_center", 2, 4, 1.2],
		["store", 2, 3, 1.5], ["high_rise", 1, 3, 0.8]],
	2: [["house", 1, 3, 3.0], ["apartment", 1, 3, 2.0], ["store", 1, 2, 1.5],
		["police_station", 1, 2, 0.2], ["fire_station", 1, 2, 0.2],
		["water_facility", 1, 2, 0.2], ["office", 1, 2, 0.6]],
}
var _density := {0: 0.82, 1: 0.66, 2: 0.46}


func _ready() -> void:
	_parse_args()
	var render_data: Dictionary = StarterCityLoader.read_json("res://data/render.json")
	_build_environment(render_data)
	_build_ground()
	_build_water()
	_build_city(render_data)
	_build_weather(render_data)
	_build_vehicles(render_data)
	_build_camera()
	if _stats:
		# A vsync-capped (or, under a virtual X server, present-bound) frame
		# time measures the display, not the renderer. Uncap what can be
		# uncapped, and measure the viewport itself for the number that
		# actually answers "did this pass make the frame cheaper".
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		RenderingServer.viewport_set_measure_render_time(
				get_viewport().get_viewport_rid(), true)
	if _overlay > 0:
		RenderingServer.global_shader_parameter_set("sc_overlay_mode", _overlay)
		# The shader global alone only greys the world back. The per-building
		# states — and the FAR tier's chunk aggregate — come from the MODEL, so
		# the mode has to be pushed there too, exactly as the overlay rail does
		# it in main.gd. Without this the far city washes out and then says
		# nothing, which is the defect the far overlay exists to fix.
		if _overlay < OVERLAY_MODES.size():
			city_view.set_overlay_mode(StringName(OVERLAY_MODES[_overlay]),
					_cam_pos)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var s := String(arg)
		if s.begins_with("--screenshot="):
			_screenshot_path = s.trim_prefix("--screenshot=")
		elif s.begins_with("--hour="):
			_hour = float(s.trim_prefix("--hour="))
		elif s.begins_with("--cam="):
			_cam_pos = _parse_vec(s.trim_prefix("--cam="))
			_free_camera = true
		elif s.begins_with("--look="):
			_cam_look = _parse_vec(s.trim_prefix("--look="))
			_free_camera = true
		elif s.begins_with("--shot-at="):
			_shot_at = float(s.trim_prefix("--shot-at="))
		elif s.begins_with("--blackout-at="):
			_blackout_at = float(s.trim_prefix("--blackout-at="))
		elif s.begins_with("--lightning-at="):
			_lightning_at = float(s.trim_prefix("--lightning-at="))
		elif s.begins_with("--zoom="):
			_zoom_t = clampf(float(s.trim_prefix("--zoom=")), 0.0, 1.0)
			_free_camera = false
		elif s.begins_with("--yaw="):
			_yaw_deg = float(s.trim_prefix("--yaw="))
			_free_camera = false
		elif s.begins_with("--focus="):
			var p := s.trim_prefix("--focus=").split(",")
			if p.size() == 2:
				_focus = Vector3(float(p[0]), 0.0, float(p[1]))
		elif s.begins_with("--storm="):
			_storm = "THUNDERSTORM"
			_precip = clampf(float(s.trim_prefix("--storm=")), 0.0, 1.0)
		elif s.begins_with("--rain="):
			_storm = "RAIN"
			_precip = clampf(float(s.trim_prefix("--rain=")), 0.0, 1.0)
		elif s.begins_with("--overlay="):
			_overlay = int(s.trim_prefix("--overlay="))
		elif s.begins_with("--preset="):
			_preset = s.trim_prefix("--preset=")
		elif s == "--no-lod":
			_lod = false
		elif s == "--stats":
			_stats = true


static func _parse_vec(text: String) -> Vector3:
	var parts := text.split(",")
	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 45.0
	_camera.far = 2400.0
	add_child(_camera)
	if _free_camera:
		_camera.position = _cam_pos
		_camera.look_at(_cam_look)
	else:
		# doc 12's zoom curve, straight off the model that owns it: D(t) and
		# pitch(t) are the same numbers the game's own camera rig uses, so a
		# `--zoom=1` frame here IS the Z2 pose §2.13 costs the budget against.
		_cam_pos = render_model.camera_position(_focus, _zoom_t, _yaw_deg)
		_cam_look = _focus
		_camera.position = _cam_pos
		_camera.look_at(_cam_look)


func _build_environment(render_data: Dictionary) -> void:
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	world_environment.environment = environment
	add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 600.0
	add_child(sun)
	var moon := DirectionalLight3D.new()
	add_child(moon)
	environment_controller = EnvironmentController.new()
	add_child(environment_controller)
	environment_controller.world_environment_path = world_environment.get_path()
	environment_controller.sun_path = sun.get_path()
	environment_controller.moon_path = moon.get_path()
	environment_controller.setup(render_data)
	environment_controller.far_cull_m = 2400.0  # cinematic scene, no cull pressure


func _build_ground() -> void:
	# The hinterland: one big plane under everything, at the undeveloped tone, so
	# the city reads as a built patch inside unbought land rather than as a
	# floating slab.
	var ground := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(SPAN + 4000.0, SPAN + 4000.0)
	# Textured ground (tools/gen_textures.py); falls back to the flat tint when
	# the pages are absent.
	mesh.material = GroundSurface.block_material(-1, false, mesh.size)
	ground.mesh = mesh
	ground.position = Vector3(SPAN * 0.5, -0.06, SPAN * 0.5)
	add_child(ground)
	# The developed core, one 128 m plane per chunk, tinted by DISTRICT (doc 11
	# §2.1 / doc 09's `color_index`). The showcase has no sim to ask, so it
	# quarters the grid into four synthetic districts — which is exactly the
	# starter city's shape (Northgate / Downtown / Millpond / Foundry Flats) and
	# puts all four ground tones in one frame, which is the only way to judge
	# whether the trims are readable without being loud.
	var tones := maxi(GroundSurface.district_tone_count(), 1)
	for cz in CHUNKS:
		for cx in CHUNKS:
			var district := (0 if cx < CHUNKS / 2 else 1) \
					+ (0 if cz < CHUNKS / 2 else 2)
			var plane := MeshInstance3D.new()
			var block := PlaneMesh.new()
			block.size = Vector2(128.0, 128.0)
			block.material = GroundSurface.block_material(district % tones, true,
					block.size)
			plane.mesh = block
			plane.position = Vector3(cx * 128.0 + 64.0, 0.0, cz * 128.0 + 64.0)
			add_child(plane)
	# Avenue grid on chunk boundaries.
	var road_mm := MultiMesh.new()
	road_mm.transform_format = MultiMesh.TRANSFORM_3D
	var strip := BoxMesh.new()
	strip.size = Vector3(SPAN, 0.06, 10.0)
	strip.material = GroundSurface.road_material(
			Vector2(strip.size.x, strip.size.z))
	road_mm.mesh = strip
	road_mm.instance_count = (CHUNKS + 1) * 2
	for i in CHUNKS + 1:
		road_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
				Vector3(SPAN * 0.5, 0.0, i * 128.0)))
		road_mm.set_instance_transform(CHUNKS + 1 + i, Transform3D(
				Basis.from_euler(Vector3(0.0, PI * 0.5, 0.0)),
				Vector3(i * 128.0, 0.0, SPAN * 0.5)))
	var roads := MultiMeshInstance3D.new()
	roads.multimesh = road_mm
	add_child(roads)


## Is this tile in the canal? The building placer and the water mesh read the
## same predicate, so nothing is ever built in the water.
static func _is_water(tile_x: int, tile_z: int) -> bool:
	if tile_z >= CANAL_Z.x and tile_z <= CANAL_Z.y:
		return true
	return tile_x >= CANAL_X.x and tile_x <= CANAL_X.y and tile_z >= CANAL_BRANCH_FROM_Z


## One MultiMesh of 8 m quads carrying ONE water material. The wave field is
## world-space, so the quads read as a single body — which is the whole reason
## the shader does not use UV.
func _build_water() -> void:
	var tiles: Array[Vector2i] = []
	for z in CHUNKS * 16:
		for x in CHUNKS * 16:
			if _is_water(x, z):
				tiles.append(Vector2i(x, z))
	if tiles.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var quad := PlaneMesh.new()
	quad.size = Vector2(8.0, 8.0)
	quad.material = GroundSurface.water()
	mm.mesh = quad
	mm.instance_count = tiles.size()
	for i in tiles.size():
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
				Vector3(tiles[i].x * 8.0 + 4.0, 0.10, tiles[i].y * 8.0 + 4.0)))
	var node := MultiMeshInstance3D.new()
	node.name = "Water"
	node.multimesh = mm
	add_child(node)


func _build_city(render_data: Dictionary) -> void:
	render_model = RenderStateModel.new(render_data, _preset)
	var manifest: Dictionary = StarterCityLoader.read_json(
			"res://game/meshes/generated/manifest.json")
	var entry_of := {}
	var family_of := {}
	for entry in manifest.get("meshes", []):
		if int(entry["lod"]) == 0:
			entry_of["%s:%d" % [entry["archetype"], int(entry["level"])]] = entry
		family_of[String(entry["archetype"])] = String(entry.get("family", "residential"))
	var rng := RngStreams.new(20260818)
	var next_id := 1
	var site_records: Array = []
	for cz in CHUNKS:
		for cx in CHUNKS:
			var ring := maxi(absi(cx * 2 - (CHUNKS - 1)), absi(cz * 2 - (CHUNKS - 1))) / 2
			ring = mini(ring, 2)
			var mix: Array = _ring_mix[ring]
			var total_weight := 0.0
			for option in mix:
				total_weight += float(option[3])
			for pz in 5:
				for px in 5:
					if rng.stream("misc").randf() > float(_density[ring]):
						continue
					var pick := rng.stream("misc").randf() * total_weight
					var chosen: Array = mix[0]
					for option in mix:
						pick -= float(option[3])
						if pick <= 0.0:
							chosen = option
							break
					var level := rng.stream("misc").randi_range(int(chosen[1]), int(chosen[2]))
					var archetype := String(chosen[0])
					var entry: Dictionary = entry_of.get("%s:%d" % [archetype, level], {})
					if entry.is_empty():
						continue
					var foot: Array = entry["footprint_tiles"]
					if int(foot[0]) > PARCEL_TILES or int(foot[1]) > PARCEL_TILES:
						continue
					var tile_x := cx * 16 + 1 + px * PARCEL_TILES
					var tile_z := cz * 16 + 1 + pz * PARCEL_TILES
					if _lot_touches_water(tile_x, tile_z, int(foot[0]), int(foot[1])):
						continue
					var center := Vector3(tile_x * 8.0 + int(foot[0]) * 4.0, 0.0,
							tile_z * 8.0 + int(foot[1]) * 4.0)
					# A live city always has scaffolding in it. One in ~33 lots
					# is mid-build, at a stage drawn from the RNG, which puts
					# every sixth of the §2.6 construction shell on screen.
					var stage := 0
					if rng.stream("misc").randf() < SITE_FRACTION:
						stage = rng.stream("misc").randi_range(1, 6)
					render_model.add_building({
						"id": next_id, "archetype_id": StringName(archetype),
						"level": level,
						"family": String(family_of.get(archetype, "residential")),
						"world_pos": center, "block_id": "C_%d_%d" % [cx, cz],
						"transform": Transform3D(Basis.IDENTITY, center),
						"occ_b": 0.40 + 0.45 * rng.stream("misc").randf(),
						"powered": true, "condition": 1.0,
						"construction_stage": stage,
					})
					if stage > 0:
						site_records.append([next_id, center, Vector2i(int(foot[0]),
								int(foot[1])), float(entry.get("height_m", 10.0)), stage])
					next_id += 1
	print("showcase buildings: ", render_model.building_count(),
			"  sites: ", site_records.size())
	city_view = CityView.new()
	add_child(city_view)
	city_view.setup(render_model, render_data)
	city_view.lod_enabled = _lod
	_build_sites(render_data, site_records)
	_build_streetlights(render_data)


static func _lot_touches_water(tile_x: int, tile_z: int, fx: int, fz: int) -> bool:
	for z in range(tile_z, tile_z + fz):
		for x in range(tile_x, tile_x + fx):
			if _is_water(x, z):
				return true
	return false


func _build_sites(render_data: Dictionary, records: Array) -> void:
	if records.is_empty():
		return
	sites = ConstructionSiteView.new()
	sites.name = "Sites"
	add_child(sites)
	sites.setup(render_data)
	for record: Array in records:
		sites.add_site(int(record[0]), record[1], record[2], float(record[3]))
		sites.set_stage(int(record[0]), int(record[4]))
	# Where the hoarding and the cranes actually are, so a `--cam=` inspection
	# pose can be aimed at one instead of hunted for across 768 m of city.
	for i in mini(4, records.size()):
		var r: Array = records[i]
		print("showcase site %d at %.0f,%.0f h=%.0f stage=%d crane=%s"
				% [int(r[0]), (r[1] as Vector3).x, (r[1] as Vector3).z,
				float(r[3]), int(r[4]), sites.has_crane(int(r[0]))])


func _build_streetlights(render_data: Dictionary) -> void:
	var lamps: Array = []
	var next_id := 100000
	for i in CHUNKS + 1:
		var line := i * 128.0
		var along := 16.0
		while along < SPAN:
			var chunk_a := mini(int(along / 128.0), CHUNKS - 1)
			var chunk_l := mini(i, CHUNKS - 1)
			lamps.append({"id": next_id, "block_id": "C_%d_%d" % [chunk_a, chunk_l],
					"pos": Vector3(along, 0.0, line - 6.0)})
			next_id += 1
			lamps.append({"id": next_id, "block_id": "C_%d_%d" % [chunk_l, chunk_a],
					"pos": Vector3(line + 6.0, 0.0, along)})
			next_id += 1
			along += 32.0
	streetlights = StreetlightView.new()
	add_child(streetlights)
	streetlights.setup(render_model, render_data, lamps)


func _build_weather(render_data: Dictionary) -> void:
	weather = WeatherFX.new()
	weather.name = "WeatherFX"
	add_child(weather)
	weather.setup(render_data, environment_controller, _preset)
	if _storm != "":
		weather.pin_weather(_storm, _precip, 0.9 if _storm == "THUNDERSTORM" else 0.6,
				Vector2(6.0, 2.5) if _storm == "THUNDERSTORM" else Vector2(3.2, 1.4))


## Traffic on the avenue grid: one lane each way on every chunk boundary,
## right-hand drive, at a plausible arterial speed. Cheap — the whole fleet is
## three MultiMeshes and one headlight pass (§2.13's 10-call line).
func _build_vehicles(render_data: Dictionary) -> void:
	vehicles = VehicleView.new()
	vehicles.name = "Vehicles"
	add_child(vehicles)
	vehicles.setup(render_data)
	vehicles.set_preset(_preset, render_data)
	var rng := RngStreams.new(770145)
	var kinds := ["car", "car", "car", "van", "truck"]
	var id := 1
	var batch: Array = []
	for i in CHUNKS + 1:
		var line := i * 128.0
		var along := 20.0
		while along < SPAN:
			if rng.stream("misc").randf() < 0.55:
				var kind := String(kinds[rng.stream("misc").randi_range(0, kinds.size() - 1)])
				var east := rng.stream("misc").randf() < 0.5
				batch.append(_car(id, kind,
						Vector3(along, 0.0, line + (1.85 if east else -1.85)),
						0.0 if east else PI, rng))
				id += 1
			if rng.stream("misc").randf() < 0.55:
				var kind2 := String(kinds[rng.stream("misc").randi_range(0, kinds.size() - 1)])
				var south := rng.stream("misc").randf() < 0.5
				batch.append(_car(id, kind2,
						Vector3(line + (-1.85 if south else 1.85), 0.0, along),
						PI * 0.5 if south else -PI * 0.5, rng))
				id += 1
			along += 26.0
	# A response in progress: one body from each department, bars running, out on
	# the avenues with the traffic. The showcase exists to put every render pass
	# on screen at once, and the department LIVERIES and the light-bar strobe are
	# a pass — without a rolling fleet they are only ever seen in a unit test.
	# These go down doc 10's cosmetic feed rather than doc 06's fleet snapshot
	# because `vehicle_class` names the department directly, and doc 06's roster
	# has no medical type to borrow an ambulance from.
	var fleet := ["police", "fire", "medical", "utility"]
	for i in fleet.size():
		var line := float(2 + i) * 128.0
		batch.append({"type": &"vehicle_spawned", "id": 900 + i, "kind": "car",
				"vehicle_class": String(fleet[i]),
				"pos": Vector3(SPAN * (0.26 + 0.13 * float(i)), 0.0, line + 1.85),
				"heading": 0.0, "speed": 11.0, "edge_id": 900 + i,
				"siren": true, "lightbar": true, "headlights": true})
	vehicles.apply_events(batch)
	print("showcase vehicles: ", vehicles.vehicle_count())


static func _car(id: int, kind: String, pos: Vector3, heading: float,
		rng: RngStreams) -> Dictionary:
	return {"type": &"vehicle_spawned", "id": id, "kind": kind,
			"vehicle_class": "civilian", "pos": pos, "heading": heading,
			"speed": 9.0 + 7.0 * rng.stream("misc").randf(), "edge_id": id,
			"siren": false, "lightbar": false, "headlights": true}


func _process(delta: float) -> void:
	environment_controller.apply(_hour, delta)
	city_view.refresh(delta, _hour, _cam_pos)
	streetlights.refresh()
	if sites != null:
		sites.refresh(delta, environment_controller.last_night)
	if weather != null:
		weather.refresh(delta, _focus if not _free_camera else _cam_look,
				_cam_pos.distance_to(_focus if not _free_camera else _cam_look))
	if vehicles != null:
		vehicles.refresh(delta, environment_controller.last_night, 1.0)
	_timer += delta
	# Steady state only. The first second is shader compilation, the first
	# MultiMesh uploads and the particle preprocess — real costs, but not the
	# per-frame cost a budget is written against.
	if _timer > WARMUP_S:
		_frames += 1
		var frame_ms := delta * 1000.0
		_frame_ms_sum += frame_ms
		_frame_ms_max = maxf(_frame_ms_max, frame_ms)
	_draw_calls = int(Performance.get_monitor(
			Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	if _stats and _timer > WARMUP_S:
		var rid := get_viewport().get_viewport_rid()
		_gpu_ms_sum += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		_cpu_ms_sum += RenderingServer.viewport_get_measured_render_time_cpu(rid)
	if _blackout_at >= 0.0 and _timer >= _blackout_at:
		_blackout_at = -1.0
		for cz in CHUNKS:
			for cx in range(3, CHUNKS):
				render_model.plan_blackout("C_%d_%d" % [cx, cz])
		print("blackout: eastern chunks cut")
	if _lightning_at >= 0.0 and _timer >= _lightning_at:
		_lightning_at = -1.0
		weather.strike(0.9)
	if _screenshot_path != "":
		if _timer > _shot_at:
			get_viewport().get_texture().get_image().save_png(_screenshot_path)
			print("screenshot saved: ", _screenshot_path)
			_report()
			get_tree().quit()
	elif _stats and _timer > _shot_at:
		_report()
		get_tree().quit()


func _report() -> void:
	if not _stats:
		return
	# The last frame's tiers, which is what a Z2 draw-call figure has to be read
	# against: doc 11 §2.13 costs FAR at 3 calls per chunk and MEDIUM at 10.
	var tiers := {0: 0, 1: 0, 2: 0, 3: 0, -1: 0}
	for chunk: Vector2i in render_model._sorted_chunk_coords():
		var t := render_model.chunk_tier(chunk)
		tiers[t] = int(tiers.get(t, 0)) + 1
	var n := maxf(1.0, float(_frames))
	print("stats frames=%d avg_ms=%.2f max_ms=%.2f gpu_ms=%.3f cpu_ms=%.3f draw_calls=%d" % [
			_frames, _frame_ms_sum / n, _frame_ms_max,
			_gpu_ms_sum / n, _cpu_ms_sum / n, _draw_calls])
	print("stats tiers near=%d medium=%d far=%d culled=%d unset=%d far_nodes=%d" % [
			tiers[0], tiers[1], tiers[2], tiers[3], tiers[-1],
			city_view.far_chunk_count()])
	print("stats building_draw_calls=%d lod_enabled=%s" % [
			city_view.building_draw_calls(), city_view.lod_enabled])
