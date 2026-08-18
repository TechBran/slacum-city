extends Node3D
## Scene root (doc 11 §2.1). Assembles SimHost, environment, ground,
## placeholder buildings (until the gray-box pipeline is wired), camera and
## UI. Desktop mouse controls are a dev convenience; touch gestures are
## doc 12's GestureRecognizer (wired with the HUD pass).
##
## `--screenshot=<path>` (user arg after `--`): renders ~2 s then saves a
## PNG and quits — used for visual bring-up review.

var sim_host: SimHost
var render_model: RenderStateModel
var city_view: CityView
var streetlights: StreetlightView
var environment_controller: EnvironmentController
var camera_rig: CameraRig
var camera_state: CameraState
var _screenshot_path := ""
var _screenshot_timer := 0.0
var _blackout_at := -1.0
var _shot_at := 2.0


func _ready() -> void:
	var render_data: Dictionary = StarterCityLoader.read_json("res://data/render.json")
	sim_host = SimHost.new()
	sim_host.name = "SimHost"
	add_child(sim_host)

	_build_environment(render_data)
	_build_ground()
	_build_city_view(render_data)

	camera_state = CameraState.load_from_files()
	camera_state.set_focus(Vector3(56 * 8.0, 0.0, 56 * 8.0))  # city centre tile
	camera_state.set_zoom_t(0.55)
	camera_rig = CameraRig.new()
	camera_rig.name = "CameraRig"
	add_child(camera_rig)
	camera_rig.setup(camera_state, render_data)

	var ui_scene: PackedScene = load("res://game/ui/ui_root.tscn")
	if ui_scene != null:
		add_child(ui_scene.instantiate())

	for arg in OS.get_cmdline_user_args():
		if String(arg).begins_with("--screenshot="):
			_screenshot_path = String(arg).trim_prefix("--screenshot=")
		elif String(arg).begins_with("--advance-hours="):
			sim_host.sim.advance_hours(float(String(arg).trim_prefix("--advance-hours=")))
		elif String(arg).begins_with("--zoom="):
			camera_state.set_zoom_t(float(String(arg).trim_prefix("--zoom=")))
		elif String(arg) == "--blackout":
			_blackout_at = 0.8  # trigger partway in so the ramps settle on film
		elif String(arg).begins_with("--shot-at="):
			_shot_at = float(String(arg).trim_prefix("--shot-at="))
		elif String(arg).begins_with("--cut-feeder="):
			sim_host.sim.grid.force_open(String(arg).trim_prefix("--cut-feeder="))


func _build_environment(render_data: Dictionary) -> void:
	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 180.0
	add_child(sun)
	var moon := DirectionalLight3D.new()
	moon.name = "Moon"
	moon.shadow_enabled = false
	add_child(moon)

	environment_controller = EnvironmentController.new()
	environment_controller.name = "EnvironmentController"
	add_child(environment_controller)
	environment_controller.world_environment_path = world_environment.get_path()
	environment_controller.sun_path = sun.get_path()
	environment_controller.moon_path = moon.get_path()
	environment_controller.setup(render_data)


func _build_ground() -> void:
	# 49 chunk planes tinted by development state, plus road and water tiles.
	var loader := sim_host.sim.loader
	var world := sim_host.sim.world
	var ground_root := Node3D.new()
	ground_root.name = "Ground"
	add_child(ground_root)
	var developed := StandardMaterial3D.new()
	developed.albedo_color = Color(0.30, 0.31, 0.30)
	developed.roughness = 0.9
	var undeveloped := StandardMaterial3D.new()
	undeveloped.albedo_color = Color(0.24, 0.30, 0.22)
	undeveloped.roughness = 1.0
	for block_id in world.block_ids_sorted():
		var block: LandBlock = world.block(block_id)
		var plane := MeshInstance3D.new()
		var mesh := PlaneMesh.new()
		mesh.size = Vector2(128.0, 128.0)
		plane.mesh = mesh
		plane.material_override = developed if block.is_ready() else undeveloped
		plane.position = Vector3(block.grid.x * 128.0 + 64.0, 0.0, block.grid.y * 128.0 + 64.0)
		ground_root.add_child(plane)
	# Roads as one MultiMesh of flat slabs.
	var road_mm := MultiMesh.new()
	road_mm.transform_format = MultiMesh.TRANSFORM_3D
	var road_mesh := BoxMesh.new()
	road_mesh.size = Vector3(8.0, 0.1, 8.0)
	var road_material := StandardMaterial3D.new()
	road_material.albedo_color = Color(0.12, 0.12, 0.14)
	road_material.roughness = 0.85
	road_mesh.material = road_material
	road_mm.mesh = road_mesh
	var road_tiles: Array[Vector2i] = []
	for z in TileGrid.SIZE:
		for x in TileGrid.SIZE:
			if world.grid.has_flag(x, z, TileGrid.FLAG_ROAD):
				road_tiles.append(Vector2i(x, z))
	road_mm.instance_count = road_tiles.size()
	for i in road_tiles.size():
		road_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
				Vector3(road_tiles[i].x * 8.0 + 4.0, 0.05, road_tiles[i].y * 8.0 + 4.0)))
	var road_node := MultiMeshInstance3D.new()
	road_node.name = "Roads"
	road_node.multimesh = road_mm
	ground_root.add_child(road_node)
	# Water tiles.
	var water_material := StandardMaterial3D.new()
	water_material.albedo_color = Color(0.10, 0.20, 0.30)
	water_material.roughness = 0.15
	water_material.metallic = 0.2
	for pair in loader.water_tiles:
		var tile := StarterCityLoader.core_to_global(int(pair[0]), int(pair[1]))
		var water_plane := MeshInstance3D.new()
		var water_mesh := PlaneMesh.new()
		water_mesh.size = Vector2(8.0, 8.0)
		water_plane.mesh = water_mesh
		water_plane.material_override = water_material
		water_plane.position = Vector3(tile.x * 8.0 + 4.0, 0.08, tile.y * 8.0 + 4.0)
		ground_root.add_child(water_plane)


func _build_city_view(render_data: Dictionary) -> void:
	render_model = RenderStateModel.new(render_data)
	var manifest: Dictionary = StarterCityLoader.read_json(
			"res://game/meshes/generated/manifest.json")
	var family_of := {}
	for entry in manifest.get("meshes", []):
		family_of[String(entry["archetype"])] = String(entry.get("family", "residential"))
	for id in sim_host.sim.buildings.keys():
		var b: Building = sim_host.sim.buildings[id]
		var record: Dictionary = sim_host.sim._building_records[id]
		var size: Vector2i = record["footprint"]
		var center := Vector3(b.origin.x * 8.0 + size.x * 4.0, 0.0,
				b.origin.y * 8.0 + size.y * 4.0)
		render_model.add_building({
			"id": b.id,
			"archetype_id": StringName(b.archetype),
			"level": maxi(b.level, 1),
			"family": String(family_of.get(String(b.archetype), "residential")),
			"world_pos": center,
			"block_id": String(record.get("block", "")),
			"transform": Transform3D(Basis.IDENTITY, center),
			"occ_b": 1.0,
			"powered": true,
			"condition": b.condition,
		})
	city_view = CityView.new()
	city_view.name = "CityView"
	add_child(city_view)
	city_view.setup(render_model, render_data)
	sim_host.ticked.connect(_on_sim_batch)
	# Streetlights: one every 4th road tile (32 m), doc 11 §2.10.
	var lamps: Array = []
	var next_lamp_id := 100000
	var world := sim_host.sim.world
	for z in TileGrid.SIZE:
		for x in TileGrid.SIZE:
			if world.grid.has_flag(x, z, TileGrid.FLAG_ROAD) and (x + z) % 4 == 0:
				var block := world.block_of_tile(x, z)
				lamps.append({"id": next_lamp_id,
						"block_id": block.id if block != null else "",
						"pos": Vector3(x * 8.0 + 4.0, 0.0, z * 8.0 + 4.0)})
				next_lamp_id += 1
	streetlights = StreetlightView.new()
	streetlights.name = "Streetlights"
	add_child(streetlights)
	streetlights.setup(render_model, render_data, lamps)


## Sim → render event bridge: translate string building ids to render ids and
## feed the model. The renderer follows the SIMULATION — nothing is staged.
func _on_sim_batch(batch: Array) -> void:
	var translated: Array = []
	for event in batch:
		match StringName(String(event["type"])):
			&"BlockDarkChanged":
				translated.append(event)
			&"BuildingPowerChanged":
				var rid := _render_id(String(event.get("building", "")))
				if rid >= 0:
					translated.append({"type": &"BuildingPowerChanged",
							"building": rid, "state": event.get("state", &"LIT")})
			&"building_damaged", &"building_destroyed", &"building_completed":
				var rid2 := _render_id_from_int(event.get("building", -1))
				if rid2 >= 0:
					var out: Dictionary = event.duplicate()
					out["building"] = rid2
					translated.append(out)
			&"PowerRestored":
				pass  # per-block relights arrive via BlockDarkChanged(false)
			_:
				pass
	if not translated.is_empty():
		render_model.apply_events(translated)


func _render_id(sim_id: String) -> int:
	var b: Building = sim_host.sim.buildings.get(sim_id)
	return b.id if b != null else -1


func _render_id_from_int(value: Variant) -> int:
	return int(value) if typeof(value) != TYPE_STRING else _render_id(String(value))


## Demo controls act on the SIM only; the renderer reacts through events.
func _trigger_blackout_demo(active: bool) -> void:
	if active:
		sim_host.sim.grid.force_open("F_SOUTH")
	else:
		sim_host.sim.grid.force_close("F_SOUTH")


func _process(delta: float) -> void:
	var hour := sim_host.hour_of_day_float()
	environment_controller.apply(hour, delta)
	city_view.refresh(delta, hour, camera_rig.camera.global_position)
	streetlights.refresh()
	if _blackout_at >= 0.0 and _screenshot_timer >= _blackout_at:
		_trigger_blackout_demo(true)
		_blackout_at = -1.0
	if _screenshot_path != "":
		_screenshot_timer += delta
		if _screenshot_timer > _shot_at:
			var image := get_viewport().get_texture().get_image()
			image.save_png(_screenshot_path)
			print("screenshot saved: ", _screenshot_path)
			get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	# Desktop dev controls; touch is doc 12's recognizer (HUD pass).
	if event is InputEventKey and (event as InputEventKey).pressed:
		match (event as InputEventKey).keycode:
			KEY_B: _trigger_blackout_demo(true)
			KEY_N: _trigger_blackout_demo(false)
	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_WHEEL_UP and button.pressed:
			camera_state.step_zoom(button.position, viewport_size, -1)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN and button.pressed:
			camera_state.step_zoom(button.position, viewport_size, 1)
		elif button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				camera_state.begin_pan(button.position, viewport_size)
			else:
				camera_state.end_pan()
	elif event is InputEventMouseMotion and (event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT:
		camera_state.update_pan((event as InputEventMouseMotion).position, viewport_size,
				get_process_delta_time())
