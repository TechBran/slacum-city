extends Node3D
## Scene root (doc 11 §2.1). Assembles SimHost, environment, ground,
## placeholder buildings (until the gray-box pipeline is wired), camera and
## UI. Desktop mouse controls are a dev convenience; device touch runs
## through `TouchInput` → `GestureRecognizer` → `CameraState` (doc 12 §2.16).
##
## `--screenshot=<path>` (user arg after `--`): renders ~2 s then saves a
## PNG and quits — used for visual bring-up review.

## HUD snapshot cadence: doc 12 §2.4 classes the chips "read-only + rare", and
## once a real second is already far more often than a player can read them.
const HUD_REFRESH_S := 1.0

var sim_host: SimHost
var render_model: RenderStateModel
var city_view: CityView
var streetlights: StreetlightView
var environment_controller: EnvironmentController
var camera_rig: CameraRig
var camera_state: CameraState
var touch_input: TouchInput
var hud: CityHUD
## P1-33/P1-34 (doc 12 §2.7/§2.9): build sheet, placement ghost, building panel.
var ui_root: UIRoot
var build_controller: BuildController
var build_sheet: BuildSheet
var building_panel: BuildingPanel
var ghost_view: GhostView
var construction_view: ConstructionSiteView
var save_service: SaveService
var android_lifecycle: AndroidLifecycle
var _autosave_interval_s := 0.0
var _autosave_timer := 0.0
var _family_of: Dictionary = {}  # archetype -> mesh-manifest family
var _height_of: Dictionary = {}  # "archetype:level" -> mesh height_m (lod 0)
var _tap_origin := Vector2.ZERO
var _tap_started_ms := 0.0
var _tap_candidate := false
var _tap_slop_dp := 8.0
var _tap_max_ms := 220.0
var _screenshot_path := ""
var _screenshot_timer := 0.0
var _blackout_at := -1.0
var _shot_at := 2.0
var _hud_timer := 0.0
## Last `economy_hour_settled.net` (doc 03, dollars per game-hour). The net
## income chip renders it per day through `NumberFormat.rate()` (doc 12 §2.4).
var _hud_net_per_hour := 0.0


func _ready() -> void:
	var render_data: Dictionary = StarterCityLoader.read_json("res://data/render.json")
	sim_host = SimHost.new()
	sim_host.name = "SimHost"
	add_child(sim_host)

	save_service = SaveService.new()
	save_service.name = "SaveService"
	add_child(save_service)
	android_lifecycle = AndroidLifecycle.new()
	android_lifecycle.name = "AndroidLifecycle"
	add_child(android_lifecycle)
	android_lifecycle.setup(save_service, sim_host.sim)
	android_lifecycle.resumed.connect(_on_app_resumed)

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
		var ui_instance := ui_scene.instantiate()
		add_child(ui_instance)
		_wire_hud(ui_instance)
		_wire_build_ui(ui_instance)
		_wire_ui_screens(ui_instance)

	touch_input = TouchInput.new()
	touch_input.name = "TouchInput"
	add_child(touch_input)
	touch_input.setup(camera_state, ui_root.config if ui_root != null else null)
	touch_input.tapped.connect(_on_touch_tapped)
	touch_input.long_pressed.connect(_on_touch_tapped)

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
		elif String(arg).begins_with("--place="):
			_place_demo(String(arg).trim_prefix("--place="))
		elif String(arg).begins_with("--focus="):
			var p := String(arg).trim_prefix("--focus=").split(",")
			if p.size() == 2:
				camera_state.set_focus(Vector3(float(p[0]), 0.0, float(p[1])))
		elif String(arg) == "--tutorial-incident":
			sim_host.sim.trigger_tutorial_transformer_failure()


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
	var developed := GroundSurface.material("pavement", Vector2(128.0, 128.0),
			Color(0.52, 0.53, 0.52), 0.90)
	var undeveloped := GroundSurface.material("pavement", Vector2(128.0, 128.0),
			Color(0.40, 0.50, 0.36), 1.00)
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
	var road_material := GroundSurface.material("asphalt", Vector2(8.0, 8.0),
			Color(0.34, 0.34, 0.38), 0.85)
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
	for entry in manifest.get("meshes", []):
		_family_of[String(entry["archetype"])] = String(entry.get("family", "residential"))
		if int(entry.get("lod", 0)) == 0:
			_height_of["%s:%d" % [entry["archetype"], int(entry["level"])]] = \
					float(entry.get("height_m", 10.0))
	for id in sim_host.sim.buildings.keys():
		render_model.add_building(_building_view(String(id)))
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
	construction_view = ConstructionSiteView.new()
	construction_view.name = "ConstructionSites"
	add_child(construction_view)
	construction_view.setup(render_data)
	for id in sim_host.sim.buildings.keys():
		if (sim_host.sim.buildings[id] as Building).state == &"under_construction":
			_add_construction_site(String(id))


## doc 11 §5's BuildingView for one sim building, as the render model wants it.
## Used for the boot population and for every incremental placement after.
func _building_view(sim_id: String) -> Dictionary:
	var b: Building = sim_host.sim.buildings.get(sim_id)
	if b == null:
		return {}
	var record: Dictionary = sim_host.sim._building_records[sim_id]
	var size: Vector2i = record["footprint"]
	var center := Vector3(b.origin.x * 8.0 + size.x * 4.0, 0.0,
			b.origin.y * 8.0 + size.y * 4.0)
	return {
		"id": b.id,
		"archetype_id": StringName(b.archetype),
		"level": maxi(b.level, 1),
		"family": String(_family_of.get(String(b.archetype), "residential")),
		"world_pos": center,
		"block_id": String(record.get("block", "")),
		"transform": Transform3D(Basis.IDENTITY, center),
		"occ_b": 1.0,
		"powered": true,
		"condition": b.condition,
		"construction_stage": 1 if b.state == &"under_construction" else 0,
	}


## Fence/crane props for one under-construction building. The crane is sized
## to the level being BUILT (pending_level during upgrades), not the current one.
func _add_construction_site(sim_id: String) -> void:
	var b: Building = sim_host.sim.buildings.get(sim_id)
	if b == null or construction_view == null:
		return
	var record: Dictionary = sim_host.sim._building_records[sim_id]
	var size: Vector2i = record["footprint"]
	var center := Vector3(b.origin.x * 8.0 + size.x * 4.0, 0.0,
			b.origin.y * 8.0 + size.y * 4.0)
	var target_level := maxi(b.pending_level, maxi(b.level, 1))
	var height := float(_height_of.get("%s:%d" % [b.archetype, target_level], 10.0))
	construction_view.add_site(b.id, center, size, height)


## Sim → render event bridge: translate string building ids to render ids and
## feed the model. The renderer follows the SIMULATION — nothing is staged.
func _on_sim_batch(batch: Array) -> void:
	# doc 12 §4.5: the same drained batch feeds the alerts centre. Clock first,
	# so `{time}` placeholders read the sim's clock and not a stale one.
	if ui_root != null:
		ui_root.set_sim_clock(sim_host.sim.clock.minute_of_day(),
				sim_host.sim.clock.day_index())
		ui_root.feed_events(batch)
	var translated: Array = []
	for event in batch:
		match StringName(String(event["type"])):
			&"BlockDarkChanged":
				translated.append(event)
			&"building_placed_sim":
				var view := _building_view(String(event.get("sim_id", "")))
				if not view.is_empty():
					translated.append({"type": &"building_placed", "view": view})
					_add_construction_site(String(event.get("sim_id", "")))
			&"upgrade_started_sim":
				_add_construction_site(String(event.get("sim_id", "")))
			&"building_construction_stage":
				translated.append(event)  # already carries the int render id
				if construction_view != null:
					construction_view.set_stage(int(event.get("building", -1)),
							int(event.get("stage", 1)))
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
					if StringName(String(event["type"])) == &"building_completed" \
							and construction_view != null:
						construction_view.remove_site(rid2)
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


## Dev arg `--place=<archetype>`: buy one building on the first serviceable
## vacant core lot, exactly as a player tap would — verifies the incremental
## render add end-to-end.
func _place_demo(archetype: String) -> void:
	var sim := sim_host.sim
	var foot: Array = sim.catalog.stats(archetype, 1).get("footprint", [1, 1])
	var size := Vector2i(int(foot[0]), int(foot[1]))
	for z in range(32, 80):
		for x in range(32, 80):
			var origin := Vector2i(x, z)
			if sim.world.grid.can_place(origin, size) and sim.grid.would_serve(origin):
				print("[place-demo] ", archetype, " at ", origin, " -> ",
						sim.cmd_place_building(archetype, origin))
				return
	print("[place-demo] no serviceable vacant lot found")


## Demo controls act on the SIM only; the renderer reacts through events.
func _trigger_blackout_demo(active: bool) -> void:
	if active:
		sim_host.sim.grid.force_open("F_SOUTH")
	else:
		sim_host.sim.grid.force_close("F_SOUTH")


# ---------------------------------------------------------------------------
# HUD (doc 12 §2.3/§2.11) — the UI reads snapshots and issues commands, never
# the reverse (constitution §3). `CityHUD` gets plain data; the only things
# travelling back are the speed and pause intents.
# ---------------------------------------------------------------------------

func _wire_hud(ui_root: Node) -> void:
	hud = ui_root.get_node_or_null("SafeArea/HUDLayer") as CityHUD
	if hud == null:
		return
	hud.speed_selected.connect(_on_hud_speed_selected)
	hud.pause_toggled.connect(_on_hud_pause_toggled)
	sim_host.ticked.connect(_on_sim_ticked)
	_refresh_hud()


## doc 03 settles the economy on the game-hour boundary; the chip shows the last
## settled hour rather than a partial one.
func _on_sim_ticked(batch: Array) -> void:
	for event: Variant in batch:
		var data: Dictionary = event
		if StringName(data.get("type", &"")) == &"economy_hour_settled":
			_hud_net_per_hour = float(data.get("net", 0.0))


func _refresh_hud() -> void:
	if hud == null or sim_host.sim == null:
		return
	var sim := sim_host.sim
	hud.refresh({
		"population": sim.population.city_population,
		"treasury": sim.treasury.balance,
		"net_per_hour": _hud_net_per_hour,
		"stability": sim.districts.city_stability,
		"happiness": sim.happiness.happiness,
		"clock": {
			"minute_of_day": sim.clock.minute_of_day(),
			"day_index": sim.clock.day_index(),
		},
		# doc 06's incident system is not in the slice yet, and docs 04/05 do not
		# publish a city-wide grid/water health figure; those chips read "—"
		# (OFFLINE) rather than showing an invented number.
		"incidents": 0,
		"speed": sim_host.speed,
		"paused": sim_host.paused,
	})


# ---------------------------------------------------------------------------
# Build sheet, placement ghost & building panel (doc 12 §2.7 / §2.9) — P1-33,
# P1-34. Same contract as the HUD block above: the UI reads sim state through
# `BuildController` and issues the two `CitySim` commands; nothing about
# placement validity or requirement copy lives in this file.
# ---------------------------------------------------------------------------

func _wire_build_ui(ui_instance: Node) -> void:
	ui_root = ui_instance as UIRoot
	var cfg: UIConfig = ui_root.config if ui_root != null and ui_root.config != null \
			else UIConfig.load_from_files()
	var gestures := cfg.gestures()
	_tap_slop_dp = UIConfig.get_num(gestures, "tap_slop_dp", 8.0)
	_tap_max_ms = UIConfig.get_num(gestures, "tap_max_ms", 220.0)

	build_controller = BuildController.new(sim_host.sim, RequirementFormatter.new(cfg))

	ghost_view = GhostView.new()
	ghost_view.name = "PlacementGhost"
	add_child(ghost_view)
	ghost_view.setup(cfg, build_controller.tile_m)

	build_sheet = ui_instance.get_node_or_null(
			"SafeArea/SheetLayer/BuildSheet") as BuildSheet
	if build_sheet != null:
		build_sheet.setup(cfg, build_controller)
		build_sheet.placement_started.connect(_on_placement_started)
		build_sheet.placement_changed.connect(_on_placement_changed)
		build_sheet.placement_committed.connect(_on_placement_committed)
		build_sheet.placement_cancelled.connect(_on_placement_changed)

	building_panel = ui_instance.get_node_or_null(
			"SafeArea/PanelLayer/BuildingPanel") as BuildingPanel
	if building_panel != null:
		building_panel.setup(cfg, build_controller)
		building_panel.closed.connect(_on_building_panel_closed)
		building_panel.upgraded.connect(_on_building_upgraded)
		building_panel.fix_requested.connect(_on_fix_requested)

	if ui_root != null:
		ui_root.back_requested.connect(_on_ui_back)


## doc 12 §2.5/§2.13/§2.15. `UIRoot.bring_up_screens()` already built and wired
## the overlay rail, alerts centre, settings sheet, save slots and pause menu
## against one shared UIConfig; this only binds them to the sim and the camera.
func _wire_ui_screens(ui_instance: Node) -> void:
	var root := ui_instance as UIRoot
	if root == null:
		return
	root.set_alert_locator(_alert_world_pos)
	root.focus_requested.connect(_on_ui_focus_requested)
	root.pause_intent.connect(_on_hud_pause_toggled)     # doc 01 owns `paused`
	root.quit_requested.connect(_on_ui_quit_requested)
	root.settings_changed.connect(_on_ui_setting_changed)
	root.save_loaded.connect(_on_ui_save_loaded)
	if save_service != null:
		root.bind_save_service(save_service, sim_host.sim)
	if root.settings_sheet != null:
		_autosave_interval_s = root.settings_sheet.model.autosave_interval_s()


## `Callable(kind, id) -> Vector3` for the alerts centre: only the shell knows
## where an entity id sits in metres. `null` means "no jump affordance".
func _alert_world_pos(kind: StringName, id: Variant) -> Variant:
	var tile_m := 8.0
	if kind == &"block_id":
		var block: LandBlock = sim_host.sim.world.block(str(id))
		if block == null:
			return null
		return Vector3((block.grid.x * 16 + 8) * tile_m, 0.0,
				(block.grid.y * 16 + 8) * tile_m)
	if kind == &"building":
		for sim_id: String in sim_host.sim.buildings.keys():
			var b: Building = sim_host.sim.buildings[sim_id]
			if sim_id == str(id) or b.id == int(id):
				return Vector3(b.origin.x * tile_m, 0.0, b.origin.y * tile_m)
	return null


func _on_ui_focus_requested(world_pos: Vector3) -> void:
	camera_state.focus_on(world_pos)


func _on_ui_quit_requested() -> void:
	# Single-scene game: quit means save, then close. The view only asks.
	if save_service != null:
		save_service.autosave(sim_host.sim)
	get_tree().quit()


func _on_ui_setting_changed(key: StringName, _value: Variant) -> void:
	var model: SettingsModel = ui_root.settings_sheet.model
	match key:
		&"graphics":
			render_model.set_preset(str(model.value("graphics")))
		&"autosave_interval_min":
			_autosave_interval_s = model.autosave_interval_s()
			_autosave_timer = 0.0
		&"text_scale", &"larger_touch_targets":
			ui_root.rebuild_theme(model.theme_opts())
		_:
			pass   # reduce_motion / in_app_banners / sound are read where used


func _on_ui_save_loaded(_slot: int) -> void:
	# The sim was replaced in place; re-seed anything that cached from it.
	_refresh_hud()


## doc 13 §2.3: the shell measures, the sim decides. The 12 real-hour cap and
## the coarse catch-up are CitySim's; this only hands over the measurement.
func _on_app_resumed(elapsed_wall_s: float) -> void:
	if elapsed_wall_s < 60.0:
		sim_host.sim.scheduler.advance_fine_n(mini(int(elapsed_wall_s * 4.0), 240))
	else:
		sim_host.sim.advance_coarse_hours(int(elapsed_wall_s / 60.0))


func _on_placement_started(_archetype: String, _variant: String) -> void:
	if building_panel != null:
		building_panel.close()
	_on_placement_changed()


func _on_placement_changed() -> void:
	if ghost_view != null and build_controller != null:
		ghost_view.apply(build_controller.ghost())
	if ui_root != null and build_controller != null:
		ui_root.placement_active = build_controller.is_placing()


func _on_placement_committed(result: Dictionary) -> void:
	_on_placement_changed()
	if bool(result.get("ok", false)):
		# The sim charged and stamped; the HUD's treasury chip follows on the
		# next refresh, and doc 11's instance buffer picks the new building up
		# when the render bridge grows an incremental add (tracked separately).
		_refresh_hud()


func _on_building_panel_closed() -> void:
	if ui_root != null:
		ui_root.selected_entity_id = ""


func _on_building_upgraded(_result: Dictionary) -> void:
	_refresh_hud()


## §2.7's `Fix this →`: focus the blocking entity. Only the power path resolves
## to a placed entity today (docs 05/06/10 own the rest), so anything else is a
## no-op rather than a camera jump to nowhere.
func _on_fix_requested(fix_target: Dictionary) -> void:
	var id := str(fix_target.get("id", ""))
	if id == "" or build_controller == null:
		return
	var b: Building = sim_host.sim.buildings.get(id)
	if b == null:
		return
	camera_state.focus_on(Vector3(b.origin.x * build_controller.tile_m, 0.0,
			b.origin.y * build_controller.tile_m))


func _on_ui_back(action: StringName) -> void:
	if action == UIRoot.BACK_CANCEL_PLACEMENT and build_sheet != null:
		build_sheet.cancel_placement()


## Tap-vs-drag on the desktop mouse path (doc 12 §2.16 thresholds). Device
## touch reaches the same selection through `TouchInput.tapped`.
func _handle_tap(screen_pos: Vector2, viewport_size: Vector2) -> void:
	if build_controller == null:
		return
	var ground := camera_state.screen_to_ground(screen_pos, viewport_size)
	if build_sheet != null and build_sheet.is_placing():
		build_sheet.move_ghost(ground)
		return
	if build_sheet != null and build_sheet.is_open():
		# A tap that reached the world missed every sheet control: dismiss.
		build_sheet.close()
		return
	var sim_id := build_controller.sim_id_at_ground(ground)
	if building_panel == null:
		return
	if sim_id == "":
		building_panel.close()
		return
	building_panel.show_building(sim_id)
	if ui_root != null:
		ui_root.selected_entity_id = sim_id


func _on_touch_tapped(position: Vector2) -> void:
	_handle_tap(position, Vector2(get_viewport().get_visible_rect().size))


func _on_hud_speed_selected(multiplier: int) -> void:
	sim_host.speed = multiplier
	sim_host.paused = false


func _on_hud_pause_toggled(paused: bool) -> void:
	sim_host.paused = paused


func _process(delta: float) -> void:
	var hour := sim_host.hour_of_day_float()
	_hud_timer += delta
	if _hud_timer >= HUD_REFRESH_S:
		_hud_timer = 0.0
		_refresh_hud()
	environment_controller.apply(hour, delta)
	city_view.refresh(delta, hour, camera_rig.camera.global_position)
	if construction_view != null:
		construction_view.refresh(delta, environment_controller.last_night)
	if _autosave_interval_s > 0.0 and save_service != null:
		_autosave_timer += delta
		if _autosave_timer >= _autosave_interval_s:
			_autosave_timer = 0.0
			save_service.autosave(sim_host.sim)
	streetlights.refresh()
	if _blackout_at >= 0.0 and _screenshot_timer >= _blackout_at:
		_trigger_blackout_demo(true)
		_blackout_at = -1.0
	if _screenshot_path != "":
		_screenshot_timer += delta
		if _screenshot_timer > _shot_at:
			var image := get_viewport().get_texture().get_image()
			image.save_png(_screenshot_path)
			print("screenshot saved: ", _screenshot_path,
					" render_buildings=", render_model.building_count())
			get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	# Desktop dev controls. Device touch runs through TouchInput; the mouse
	# events Godot synthesises FROM touch (device id -1, needed so
	# ScrollContainer and friends pan on Android) must not double-drive the
	# camera on top of the gesture layer.
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if event is InputEventKey and (event as InputEventKey).pressed:
		match (event as InputEventKey).keycode:
			KEY_B: _trigger_blackout_demo(true)
			KEY_N: _trigger_blackout_demo(false)
			KEY_T:
				# Milestone 3's arc: the tutorial transformer cooks, the block
				# darkens, dispatch sends a utility truck, repair relights it.
				var incident := sim_host.sim.trigger_tutorial_transformer_failure()
				print("[tutorial] transformer incident: ",
						incident.id if incident != null else "none")
	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_WHEEL_UP and button.pressed:
			camera_state.step_zoom(button.position, viewport_size, -1)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN and button.pressed:
			camera_state.step_zoom(button.position, viewport_size, 1)
		elif button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				_tap_origin = button.position
				_tap_started_ms = float(Time.get_ticks_msec())
				_tap_candidate = true
				camera_state.begin_pan(button.position, viewport_size)
			else:
				camera_state.end_pan()
				# doc 12 §2.16: ≤8 dp of travel in ≤220 ms is a TAP, not a pan —
				# and a tap is what selects a building or moves the ghost.
				if _tap_candidate \
						and float(Time.get_ticks_msec()) - _tap_started_ms <= _tap_max_ms:
					_handle_tap(button.position, viewport_size)
				_tap_candidate = false
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if motion.button_mask & MOUSE_BUTTON_MASK_LEFT:
			if motion.position.distance_to(_tap_origin) > _tap_slop_dp:
				_tap_candidate = false
			camera_state.update_pan(motion.position, viewport_size,
					get_process_delta_time())
		elif build_sheet != null and build_sheet.is_placing():
			# Hover keeps the ghost under the pointer; the verdict is recomputed
			# on every move (§2.7) and only PLACE ever commits it.
			build_sheet.move_ghost(camera_state.screen_to_ground(
					motion.position, viewport_size))
