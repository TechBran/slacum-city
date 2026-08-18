extends Node3D
## Showcase / render-stress scene: a synthetic grown metropolis built straight
## into the RenderStateModel — every archetype at every level, a downtown of
## L3–L5 towers, a data-center campus, residential rings. No simulation; this
## is the renderer's ceiling and the skyline demo.
##
## Args (after --): --screenshot=<path>  --hour=<0..24>
##   --cam=x,y,z --look=x,y,z   (cinematic free camera)

const CHUNKS := 6  # 6×6 chunks = 768 m square
const PARCEL_TILES := 3

var render_model: RenderStateModel
var city_view: CityView
var environment_controller: EnvironmentController
var _screenshot_path := ""
var _hour := 19.0
var _timer := 0.0
var _cam_pos := Vector3(90.0, 210.0, 900.0)
var _cam_look := Vector3(384.0, 70.0, 340.0)

var _ring_mix := {
	0: [["high_rise", 3, 5, 4.0], ["office", 4, 5, 2.5], ["apartment", 4, 5, 1.0]],
	1: [["office", 2, 4, 2.0], ["apartment", 3, 5, 2.5], ["data_center", 2, 4, 1.2],
		["store", 2, 3, 1.5], ["high_rise", 1, 3, 0.8]],
	2: [["house", 1, 3, 3.0], ["apartment", 1, 3, 2.0], ["store", 1, 2, 1.5],
		["police_station", 1, 2, 0.2], ["fire_station", 1, 2, 0.2],
		["water_facility", 1, 2, 0.2], ["office", 1, 2, 0.6]],
}
var _density := {0: 0.70, 1: 0.55, 2: 0.38}


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var s := String(arg)
		if s.begins_with("--screenshot="):
			_screenshot_path = s.trim_prefix("--screenshot=")
		elif s.begins_with("--hour="):
			_hour = float(s.trim_prefix("--hour="))
		elif s.begins_with("--cam="):
			_cam_pos = _parse_vec(s.trim_prefix("--cam="))
		elif s.begins_with("--look="):
			_cam_look = _parse_vec(s.trim_prefix("--look="))

	var render_data: Dictionary = StarterCityLoader.read_json("res://data/render.json")
	_build_environment(render_data)
	_build_ground()
	_build_city(render_data)

	var camera := Camera3D.new()
	camera.fov = 45.0
	camera.far = 2400.0
	add_child(camera)
	camera.position = _cam_pos
	camera.look_at(_cam_look)


static func _parse_vec(text: String) -> Vector3:
	var parts := text.split(",")
	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))


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
	var span := CHUNKS * 128.0
	var ground := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(span + 4000.0, span + 4000.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.155, 0.16, 0.165)
	material.roughness = 0.92
	mesh.material = material
	ground.mesh = mesh
	ground.position = Vector3(span * 0.5, -0.02, span * 0.5)
	add_child(ground)
	# Avenue grid on chunk boundaries.
	var road_mm := MultiMesh.new()
	road_mm.transform_format = MultiMesh.TRANSFORM_3D
	var strip := BoxMesh.new()
	strip.size = Vector3(span, 0.06, 10.0)
	var road_material := StandardMaterial3D.new()
	road_material.albedo_color = Color(0.075, 0.078, 0.085)
	road_material.roughness = 0.8
	strip.material = road_material
	road_mm.mesh = strip
	road_mm.instance_count = (CHUNKS + 1) * 2
	for i in CHUNKS + 1:
		road_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
				Vector3(span * 0.5, 0.0, i * 128.0)))
		road_mm.set_instance_transform(CHUNKS + 1 + i, Transform3D(
				Basis.from_euler(Vector3(0.0, PI * 0.5, 0.0)),
				Vector3(i * 128.0, 0.0, span * 0.5)))
	var roads := MultiMeshInstance3D.new()
	roads.multimesh = road_mm
	add_child(roads)


func _build_city(render_data: Dictionary) -> void:
	render_model = RenderStateModel.new(render_data)
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
					var center := Vector3(tile_x * 8.0 + int(foot[0]) * 4.0, 0.0,
							tile_z * 8.0 + int(foot[1]) * 4.0)
					render_model.add_building({
						"id": next_id, "archetype_id": StringName(archetype),
						"level": level,
						"family": String(family_of.get(archetype, "residential")),
						"world_pos": center, "block_id": "C_%d_%d" % [cx, cz],
						"transform": Transform3D(Basis.IDENTITY, center),
						"occ_b": 0.40 + 0.45 * rng.stream("misc").randf(),
						"powered": true, "condition": 1.0,
					})
					next_id += 1
	print("showcase buildings: ", render_model.building_count())
	city_view = CityView.new()
	add_child(city_view)
	city_view.setup(render_model, render_data)


func _process(delta: float) -> void:
	environment_controller.apply(_hour, delta)
	city_view.refresh(delta, _hour)
	if _screenshot_path != "":
		_timer += delta
		if _timer > 2.0:
			get_viewport().get_texture().get_image().save_png(_screenshot_path)
			print("screenshot saved: ", _screenshot_path)
			get_tree().quit()
