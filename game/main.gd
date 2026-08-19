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
var weather_fx: WeatherFX
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
var vehicle_view: VehicleView
## doc 12 §2.5 mode 5. Congestion is per road EDGE, so it is the one overlay
## that cannot ride the packed per-building state and gets its own MultiMesh.
var road_overlay: RoadOverlayView
var audio: AudioService
var notification_router: NotificationRouter
var save_service: SaveService
var _before_snapshot: Dictionary = {}   # captured on pause for the away report
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
var _lightning_at := -1.0
var _shot_at := 2.0
var _hud_timer := 0.0
## Last `economy_hour_settled.net` (doc 03, dollars per game-hour). The net
## income chip renders it per day through `NumberFormat.rate()` (doc 12 §2.4).
var _hud_net_per_hour := 0.0
var _last_overlay_minute := -1
var _resumed_slot := -1   # >= 0 when this session restored a save at boot
var _render_data: Dictionary = {}
var _road_node: MultiMeshInstance3D


func _ready() -> void:
	var render_data: Dictionary = StarterCityLoader.read_json("res://data/render.json")
	_render_data = render_data
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
	android_lifecycle.paused.connect(_on_app_paused)

	audio = AudioService.new()
	audio.name = "AudioService"
	add_child(audio)
	audio.setup()
	audio.set_locator(_alert_world_pos)
	android_lifecycle.focus_changed.connect(
			func(has_focus: bool) -> void: audio.set_muted(not has_focus))
	notification_router = NotificationRouter.load_from_files()
	notification_router.set_sink(NativeNotificationSink.new())  # inert until doc 13 phase 2
	android_lifecycle.notification_router = notification_router

	# Session restore (doc 08 §2.1): on a PLAIN launch — no dev args, which is
	# every real device launch — the most recent save IS the city, restored
	# BEFORE the views build so the world below is the player's progress, not
	# the authored founding state. Dev/screenshot runs stay on the founding
	# city for reproducibility unless they pass --resume.
	var user_args := OS.get_cmdline_user_args()
	if user_args.is_empty() or user_args.has("--resume"):
		_resumed_slot = save_service.load_latest(sim_host.sim)

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
		elif String(arg).begins_with("--rain="):
			weather_fx.pin_weather("RAIN",
					float(String(arg).trim_prefix("--rain=")), 0.6, Vector2(3.2, 1.4))
		elif String(arg).begins_with("--storm="):
			weather_fx.pin_weather("THUNDERSTORM",
					float(String(arg).trim_prefix("--storm=")), 0.9, Vector2(6.0, 2.5))
		elif String(arg).begins_with("--wet="):
			weather_fx.wetness = float(String(arg).trim_prefix("--wet="))
		elif String(arg).begins_with("--lightning-at="):
			_lightning_at = float(String(arg).trim_prefix("--lightning-at="))
		elif String(arg).begins_with("--overlay="):
			_select_overlay(int(String(arg).trim_prefix("--overlay=")))
		elif String(arg).begins_with("--focus="):
			var p := String(arg).trim_prefix("--focus=").split(",")
			if p.size() == 2:
				camera_state.set_focus(Vector3(float(p[0]), 0.0, float(p[1])))
		elif String(arg) == "--tutorial-incident":
			var inc := sim_host.sim.trigger_tutorial_transformer_failure()
			if inc != null:
				camera_state.set_focus(Vector3(inc.tile.x * 8.0, 0.0, inc.tile.y * 8.0))
		elif String(arg) == "--save-now":
			save_service.autosave(sim_host.sim)
			print("[save-now] autosaved, slot meta: ", save_service.list_slots())


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

	# doc 11 §2.9: rain, splashes, wetness and the lightning flash. It pushes
	# the storm scalars into EnvironmentController, which owns every write to
	# the sky/sun/fog, and writes sc_wetness / sc_wind / sc_lightning itself.
	weather_fx = WeatherFX.new()
	weather_fx.name = "WeatherFX"
	add_child(weather_fx)
	weather_fx.setup(render_data, environment_controller)


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
	_road_node = road_node
	# Water tiles: ONE animated material for the whole city (doc 11 §2.1.1).
	# The wave field is world-space, so the quads read as one body.
	var water_mm := MultiMesh.new()
	water_mm.transform_format = MultiMesh.TRANSFORM_3D
	var water_quad := PlaneMesh.new()
	water_quad.size = Vector2(8.0, 8.0)
	water_quad.material = GroundSurface.water()
	water_mm.mesh = water_quad
	water_mm.instance_count = loader.water_tiles.size()
	var wi := 0
	for pair in loader.water_tiles:
		var tile := StarterCityLoader.core_to_global(int(pair[0]), int(pair[1]))
		water_mm.set_instance_transform(wi, Transform3D(Basis.IDENTITY,
				Vector3(tile.x * 8.0 + 4.0, 0.08, tile.y * 8.0 + 4.0)))
		wi += 1
	var water_node := MultiMeshInstance3D.new()
	water_node.name = "Water"
	water_node.multimesh = water_mm
	ground_root.add_child(water_node)


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
	vehicle_view = VehicleView.new()
	vehicle_view.name = "Vehicles"
	add_child(vehicle_view)
	vehicle_view.setup(render_data)
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
	if weather_fx != null:
		weather_fx.feed_events(batch)   # doc 07's weather_changed / lightning_strike
	for event in batch:
		match StringName(String(event.get("type", ""))):
			&"road_graph_changed", &"block_roads_stamped":
				# Player roads and stamped ring blocks would otherwise be
				# invisible until restart — the slab MultiMesh is built at boot.
				_rebuild_road_multimesh()
	if vehicle_view != null:
		vehicle_view.apply_events(batch)
		# Idempotent fleet pose sync — per TICK batch, never per frame.
		vehicle_view.apply_unit_states(sim_host.sim.incidents.vehicle_states())
	if audio != null:
		audio.feed_batch(batch)
		# Moving sirens: the same fleet snapshot vehicle_view already takes,
		# once per TICK — the siren follows the streets, throttled inside.
		audio.feed_unit_states(sim_host.sim.incidents.vehicle_states())
	if notification_router != null:
		notification_router.feed_batch(batch)
	var translated: Array = []
	for event in batch:
		match StringName(String(event["type"])):
			&"BlockDarkChanged", &"StreetlightsChanged":
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
			_on_hour_settled(data)


## Hourly UI feeds (doc 12 §2.4/§2.10): service chips, history samples, budget.
func _on_hour_settled(data: Dictionary) -> void:
	if ui_root == null:
		return
	var sim := sim_host.sim
	var settlement: Dictionary = sim.last_settlement if not sim.last_settlement.is_empty() \
			else data
	ui_root.feed_settlement(settlement)
	var unserved: Dictionary = {}
	for id: String in sim.grid.unserved_building_ids():
		unserved[id] = true
	var power: Dictionary = {}
	for sim_id: String in sim.buildings:
		power[sim_id] = 0.0 if unserved.has(sim_id) \
				else sim.grid.power_availability_hour(sim_id)
	var power01 := HudModel.mean01(power)
	var water01 := HudModel.mean01(sim.water.service_factors())
	ui_root.ingest_service({"power01": power01, "water01": water01})
	# §2.5 mode 2. The chips take the city-wide MEAN; the overlay wants to know
	# WHICH taps are dry, which is a different question and a different feed.
	_feed_water_overlay()
	ui_root.sample_history({
		"hour": sim.clock.sim_time_minutes() / 60,
		"population": float(sim.population.city_population),
		"treasury": float(sim.treasury.balance),
		"net_per_hour": _hud_net_per_hour,
		"happiness": sim.happiness.happiness,
		"stability": sim.districts.city_stability,
		"power01": power01, "water01": water01,
	})


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
		"incidents": sim.incidents.active_count(),
		"speed": sim_host.speed,
		"paused": sim_host.paused,
	})
	# The live overlay refreshes on GAME-MINUTE boundaries (doc 10 rebuilds the
	# snapshot per game-minute; HUD's 1 Hz reads stale at 3×) — and ONLY the
	# live one: a channel nobody is looking at is republished on the hour.
	var active_overlay: StringName = ui_root.overlay_rail.active_mode() \
			if ui_root != null and ui_root.overlay_rail != null \
			else OverlayModel.MODE_NONE
	var sim_minute: int = sim.clock.tick_index / GameClock.TICKS_PER_MINUTE
	var interval := maxi(1, int(float(ui_root.overlay_rail.model
			.traffic_render_opts().get("traffic_refresh_game_minutes", 1.0)))) \
			if ui_root != null and ui_root.overlay_rail != null else 1
	if sim_minute != _last_overlay_minute and sim_minute % interval == 0:
		_last_overlay_minute = sim_minute
		if active_overlay == OverlayModel.MODE_WATER:
			_feed_water_overlay()
		elif active_overlay == OverlayModel.MODE_TRAFFIC:
			_feed_traffic_overlay()
		elif active_overlay == OverlayModel.MODE_POLICE \
				or active_overlay == OverlayModel.MODE_FIRE:
			_feed_coverage_overlay(active_overlay)
	if ui_root != null:
		ui_root.refresh_incidents(sim.incidents.snapshot(), sim.incidents.now_h)
		ui_root.set_incident_reference(camera_state.focus)
		ui_root.refresh_dashboard({
			"population": sim.population.city_population,
			"treasury": sim.treasury.balance,
			"net_per_hour": _hud_net_per_hour,
			"stability": sim.districts.city_stability,
			"happiness": sim.happiness.happiness,
		})
		_feed_dashboard_tabs()


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
	_wire_overlays(root)
	root.pause_intent.connect(_on_hud_pause_toggled)     # doc 01 owns `paused`
	root.quit_requested.connect(_on_ui_quit_requested)
	root.settings_changed.connect(_on_ui_setting_changed)
	root.save_loaded.connect(_on_ui_save_loaded)
	root.set_incident_locator(_alert_world_pos)
	root.set_unit_provider(_dispatchable_units)
	root.dispatch_requested.connect(_on_ui_dispatch)
	root.incident_action.connect(_on_ui_incident_action)
	root.deeplink_requested.connect(_on_ui_deeplink)
	root.bind_tax(sim_host.sim.cmd_set_tax_level, sim_host.sim.tax_level(),
			sim_host.sim.tax_level_count(), sim_host.sim.tax_rate)
	if save_service != null:
		root.bind_save_service(save_service, sim_host.sim)
	if root.settings_sheet != null:
		_autosave_interval_s = root.settings_sheet.model.autosave_interval_s()
		if audio != null:
			audio.set_sound_volume(root.settings_sheet.model.value_num("sound_volume"))
	_wire_audio_ui(root)
	root.ui_coverage_changed.connect(audio.set_ui_coverage)  # interior muffle
	# Saves carry the UI section (doc 12 §3.2) so a restored city keeps its
	# tutorial progress and overlay prefs; the provider rides every save.
	save_service.ui_provider = root.capture_ui_state
	if _resumed_slot >= 0:
		root.restore_ui_state(save_service.last_loaded_ui)
	# Onboarding (doc 12 S12): starts only on a genuinely new city. A resumed
	# save's flow — mid-tutorial or finished — came back through the UI section
	# above; the regions are set either way so world-tag cutouts work on resume.
	root.set_onboarding_world_resolver(_coach_world_rect)
	root.onboarding_action.connect(_on_coach_action)
	var tutorial_regions := {
		"tutorial_lot_a": sim_host.sim.loader.resolve_tag("tutorial_lot_a")["tile_global"],
		"tutorial_lot_b": sim_host.sim.loader.resolve_tag("tutorial_lot_b")["tile_global"],
	}
	if root.onboarding != null and root.onboarding.model != null:
		root.onboarding.model.set_regions(tutorial_regions)
	if _resumed_slot < 0:
		root.start_onboarding(tutorial_regions)


# ---------------------------------------------------------------------------
# Data overlays (doc 12 §2.5 modes 2 and 5)
#
# The rail owns which overlay is live and writes doc 11's `sc_overlay_mode`; the
# shell owns the DATA, because only the shell holds the sim. Two feeds, both of
# them plain dictionaries, neither of which any `ui/` or `game/render/` file
# could build for itself:
#
#   * WATER is per BUILDING and rides the two `overlay_state` bits doc 11
#     already packs (C-64) — `RenderStateModel.set_overlay_channel` maps it in
#     while mode 2 is up and restores every building's own state on the way out.
#   * TRAFFIC is per road EDGE and cannot ride those bits at all, so it is a
#     second translucent MultiMesh over the road slabs, built from doc 10's
#     `TrafficSnapshot` and visible only in mode 5.
# ---------------------------------------------------------------------------

## Dev arg `--overlay=<index>`: goes through the RAIL rather than straight at
## the shader global, so the data feeds and the road overlay come up with it and
## the screenshot shows the overlay a player would see, not a grey city.
func _select_overlay(index: int) -> void:
	if ui_root == null or ui_root.overlay_rail == null:
		RenderingServer.global_shader_parameter_set("sc_overlay_mode", index)
		return
	var modes := ui_root.overlay_rail.model.modes()
	if index >= 0 and index < modes.size():
		ui_root.overlay_rail.select(modes[index])


func _wire_overlays(root: UIRoot) -> void:
	var cfg: UIConfig = root.config if root.config != null else UIConfig.load_from_files()
	var overlay_model: OverlayModel = root.overlay_rail.model \
			if root.overlay_rail != null else null
	road_overlay = RoadOverlayView.new()
	road_overlay.name = "RoadOverlay"
	add_child(road_overlay)
	var variant := "default"
	if root.settings_sheet != null:
		variant = str(root.settings_sheet.model.value("colorblind"))
	road_overlay.setup(cfg, overlay_model, 8.0, variant)
	root.overlay_changed.connect(_on_overlay_changed)
	# Publish every channel once at boot so the first tap on a chip is a
	# repaint and not a wait for the next settled hour.
	_feed_water_overlay()
	_feed_traffic_overlay()
	_feed_coverage_overlay(OverlayModel.MODE_POLICE, true)
	_feed_coverage_overlay(OverlayModel.MODE_FIRE, true)
	# A6: the four state hues the 3D city tints with follow the same palette the
	# legend does. One table, `data/ui.json.overlay.building_state_paint`.
	_apply_overlay_palette(variant)


func _apply_overlay_palette(variant: String) -> void:
	if city_view == null or ui_root == null or ui_root.overlay_rail == null:
		return
	city_view.set_overlay_palette(
			ui_root.overlay_rail.model.building_state_paint_ordered(variant))


func _on_overlay_changed(mode: StringName, _index: int) -> void:
	if mode == OverlayModel.MODE_WATER:
		_feed_water_overlay()
	elif mode == OverlayModel.MODE_TRAFFIC:
		_feed_traffic_overlay()
	elif mode == OverlayModel.MODE_POLICE or mode == OverlayModel.MODE_FIRE:
		_feed_coverage_overlay(mode, true)
	if city_view != null:
		city_view.set_overlay_mode(mode, camera_rig.camera.global_position)
	if road_overlay != null:
		road_overlay.set_overlay_mode(mode)


## Doc 05's per-building reading, through §2.5's authored bands. `pressure` and
## not `service_factors()` on purpose: the settled hourly factor is the right
## number for a BILL and the wrong one for a map — a main that breaks at 08:05
## has to turn its block red at 08:05, not at 09:00.
func _feed_water_overlay() -> void:
	if render_model == null or ui_root == null or ui_root.overlay_rail == null:
		return
	var overlay_model := ui_root.overlay_rail.model
	var sim := sim_host.sim
	var states: Dictionary = {}
	for sim_id: String in sim.buildings:
		var render_id := _render_id(sim_id)
		if render_id < 0:
			continue
		states[render_id] = overlay_model.water_state(
				float(sim.water.get_water_service(sim_id).get("pressure", 1.0)))
	render_model.set_overlay_channel(OverlayModel.MODE_WATER, states)


## Doc 10 rebuilds `snapshot` every game-minute and each row already carries its
## band, so this is a read and a repaint — no classification, no graph walk.
func _feed_traffic_overlay() -> void:
	if road_overlay == null or sim_host.sim.roads == null:
		return
	road_overlay.apply_edges(sim_host.sim.roads.snapshot.visible_edges)


## §2.5 modes 3 and 4. Doc 02 §2.9's coverage field, sampled at every building's
## own tile and banded against that building's own requirement rung — which is
## why the shell reads the catalog here and hands `OverlayModel` a pair rather
## than a bare scalar: doc 02 is explicit that the UI must show the MARGIN, and
## an L4 office at 0.55 cover is failing while an L1 house at 0.55 is fine.
##
## `rebuild` forces the field to be re-solved before it is read. It is memoised
## per game-hour for the incident integrator's sake, which is right for a rate
## and wrong for the moment a player places a station — so the two calls that
## follow a change (entering the overlay, and the boot publish) pay for a rebuild
## and the 1 Hz repaint does not.
func _feed_coverage_overlay(mode: StringName, rebuild: bool = false) -> void:
	if render_model == null or ui_root == null or ui_root.overlay_rail == null:
		return
	var overlay_model := ui_root.overlay_rail.model
	var sim := sim_host.sim
	var world: CityIncidentWorld = sim.incident_world
	if rebuild:
		world.invalidate_coverage()
	var police := mode == OverlayModel.MODE_POLICE
	var kind: StringName = CoverageIndex.KIND_POLICE if police else CoverageIndex.KIND_FIRE
	var requirement_key := "req_police_coverage" if police else "req_fire_coverage"
	var rows: Dictionary = {}
	var uncovered := 0
	var below := 0
	for sim_id: String in sim.buildings:
		var render_id := _render_id(sim_id)
		if render_id < 0:
			continue
		var b: Building = sim.buildings[sim_id]
		var cover := world.coverage_police(b.origin) if police \
				else world.coverage_fire(b.origin)
		var stats: Dictionary = sim.catalog.stats(String(b.archetype), maxi(1, b.level))
		var requirement := float(stats.get(requirement_key, 0.0))
		rows[render_id] = {"coverage": cover, "requirement": requirement}
		if cover <= 0.0:
			uncovered += 1
		elif requirement > 0.0 and cover < requirement:
			below += 1
	render_model.set_overlay_channel(mode, overlay_model.coverage_states(rows))
	# §2.5's 1–3 aggregate lines on the legend card.
	ui_root.feed_overlay_summary(mode, [
		{"label": UIWidgets.t(ui_root.config, "ui_overlay_summary_stations"),
				"value": str(world.coverage.station_count(kind))},
		{"label": UIWidgets.t(ui_root.config, "ui_overlay_summary_uncovered"),
				"value": str(uncovered),
				"state": HudModel.STATE_NORMAL if uncovered == 0 else HudModel.STATE_CRITICAL},
		{"label": UIWidgets.t(ui_root.config, "ui_overlay_summary_below_req"),
				"value": str(below),
				"state": HudModel.STATE_NORMAL if below == 0 else HudModel.STATE_WARNING},
	])


## §2.10's Infrastructure and Response tabs. Both are pure reads of queries the
## sim already publishes — `PowerGrid`'s additive row queries, doc 05's §5.8
## snapshot, doc 06's roster and dispatch statistics — so the shell assembles
## them and the models do the sorting, the trimming and the words.
func _feed_dashboard_tabs() -> void:
	var sim := sim_host.sim
	# The same ambient doc 04's own tick derates on, so the headroom the tab
	# prints is the headroom the protection pass is working against.
	var t_ambient := float(sim.weather.env_for_grid().get("t_ambient_c", 25.0)) \
			if sim.weather != null else 25.0
	ui_root.feed_infrastructure({
		"power": sim.grid.capacity_summary(t_ambient),
		"feeders": sim.grid.feeder_rows(t_ambient),
		"transformers": sim.grid.transformer_rows(t_ambient),
		"water": WaterSnapshot.build(sim.water),
	})
	var units: Array = []
	for unit_id in sim.incidents.fleet.unit_ids():
		var u: Vehicle = sim.incidents.fleet.unit(int(unit_id))
		if u != null:
			units.append({"id": u.id, "type": u.type, "department": u.department,
					"status": u.status, "station": u.home_station_id})
	ui_root.feed_response({
		"units": units,
		"stats": sim.incidents.dispatch.stats,
		"open": sim.incidents.active_count(),
	})


func _coach_world_rect(tag: String) -> Variant:
	var tile: Vector2i = sim_host.sim.loader.resolve_tag(tag).get("tile_global",
			Vector2i.ZERO)
	var answer := camera_state.project_to_screen(
			Vector3(tile.x * 8.0 + 4.0, 0.0, tile.y * 8.0 + 4.0),
			Vector2(get_viewport().get_visible_rect().size))
	return null if bool(answer["behind"]) else answer["position"]


func _on_coach_action(action: StringName, payload: Dictionary) -> void:
	match action:
		&"focus_camera":
			var tile: Vector2i = sim_host.sim.loader.resolve_tag(
					str(payload["tag"]))["tile_global"]
			camera_state.focus_on(Vector3(tile.x * 8.0, 0.0, tile.y * 8.0))
		&"trigger_tutorial_incident":
			sim_host.sim.trigger_tutorial_transformer_failure()
		&"suppress_director":
			# Doc 12 §2.17's budget is REAL seconds; doc 07's hold is game time.
			# `SimHost.GAME_MS_PER_REAL_MS` is the shell's own published rate, so
			# the tutorial's 300 s is 5 game-hours at speed 1 — long enough to
			# cover the Director's hourly evaluation, which 300 game-seconds
			# (5 game-minutes) would step straight over.
			sim_host.sim.suppress_director(float(payload.get("seconds", 300.0))
					* SimHost.GAME_MS_PER_REAL_MS)
		&"release_director":
			sim_host.sim.release_director()


## `Callable(kind, id) -> Vector3` for the alerts centre: only the shell knows
## where an entity id sits in metres. `null` means "no jump affordance".
func _alert_world_pos(kind: StringName, id: Variant) -> Variant:
	var tile_m := 8.0
	if kind == &"tile":
		var t: Vector2i = id
		return Vector3(t.x * 8.0 + 4.0, 0.0, t.y * 8.0 + 4.0)
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
			if vehicle_view != null:
				vehicle_view.set_preset(str(model.value("graphics")),
						StarterCityLoader.read_json("res://data/render.json"))
		&"autosave_interval_min":
			_autosave_interval_s = model.autosave_interval_s()
			_autosave_timer = 0.0
		&"sound_volume":
			if audio != null:
				audio.set_sound_volume(model.value_num("sound_volume"))
		&"text_scale", &"larger_touch_targets":
			ui_root.rebuild_theme(model.theme_opts())
		&"colorblind":
			# The traffic bands and the building tint both borrow the legend's
			# hues, so the whole map follows the palette the theme just switched
			# to — A6 is not a UI-layer-only promise.
			ui_root.rebuild_theme(model.theme_opts())
			if road_overlay != null:
				road_overlay.set_palette_variant(str(model.value("colorblind")))
			_apply_overlay_palette(str(model.value("colorblind")))
		_:
			pass   # reduce_motion / in_app_banners are read where used


func _on_ui_save_loaded(_slot: int) -> void:
	# The sim was replaced in place; re-seed EVERYTHING that cached from it —
	# and don't carry the old city's thunder into the new one.
	if audio != null:
		audio.reset()
	_resync_world_views()
	if ui_root != null:
		ui_root.restore_ui_state(save_service.last_loaded_ui)
	_refresh_hud()


## Re-scan the tile grid for FLAG_ROAD and rebuild the slab MultiMesh — fired
## on `road_graph_changed` / `block_roads_stamped` and after a mid-session load.
func _rebuild_road_multimesh() -> void:
	if _road_node == null or _road_node.multimesh == null:
		return
	var world := sim_host.sim.world
	var road_tiles: Array[Vector2i] = []
	for z in TileGrid.SIZE:
		for x in TileGrid.SIZE:
			if world.grid.has_flag(x, z, TileGrid.FLAG_ROAD):
				road_tiles.append(Vector2i(x, z))
	var mm := _road_node.multimesh
	mm.instance_count = road_tiles.size()
	for i in road_tiles.size():
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
				Vector3(road_tiles[i].x * 8.0 + 4.0, 0.05, road_tiles[i].y * 8.0 + 4.0)))


## Rebuild every world view from the (just-replaced) sim. The render model's
## roster is diffed rather than recreated — CityView's buckets self-heal from
## `_upload_all`, so removing the stale records and re-adding the live ones is
## the whole job; `resync_snap` then snaps emissive/blackout ceremony to the
## restored steady state (doc 11 §2.7.6).
func _resync_world_views() -> void:
	var sim := sim_host.sim
	var live: Dictionary = {}
	for sim_id: String in sim.buildings:
		live[int((sim.buildings[sim_id] as Building).id)] = String(sim_id)
	var stale: Array = []
	for rid: int in render_model._recs:
		if not live.has(int(rid)):
			stale.append(int(rid))
	for rid: int in stale:
		render_model.remove_building(rid)
	var render_ids := live.keys()
	render_ids.sort()
	for rid: int in render_ids:
		render_model.add_building(_building_view(live[rid]))
	render_model.resync_snap()
	if construction_view != null:
		construction_view.clear()
		for sim_id: String in sim.buildings:
			if (sim.buildings[sim_id] as Building).state == &"under_construction":
				_add_construction_site(String(sim_id))
	_rebuild_road_multimesh()
	# The vehicle layer keys off a live event stream; the cheapest correct
	# resync is a fresh view (its whole state rebuilds within a game-minute).
	if vehicle_view != null:
		vehicle_view.queue_free()
		vehicle_view = VehicleView.new()
		vehicle_view.name = "Vehicles"
		add_child(vehicle_view)
		vehicle_view.setup(_render_data)


func _on_ui_dispatch(unit_id: int, incident_id: int) -> void:
	var r := sim_host.sim.cmd_dispatch_unit(unit_id, incident_id)
	ui_root.report_dispatch_result(unit_id, bool(r["ok"]))


func _on_ui_incident_action(action: StringName, incident_id: int, value: Variant) -> void:
	if action == &"pin":
		sim_host.sim.cmd_pin_incident(incident_id, bool(value))
	elif action == &"acknowledge":
		sim_host.sim.cmd_acknowledge_incident(incident_id)


func _on_ui_deeplink(target: String) -> void:
	if target.begins_with("overlay/") and ui_root.overlay_rail != null:
		ui_root.overlay_rail.select_mode(StringName(target.trim_prefix("overlay/")))


## Unit rows for the picker (doc 12 §2.6 step 4): ETA-ranked, capability-aware.
func _dispatchable_units(incident_id: int) -> Array:
	var sim := sim_host.sim
	var inc: Incident = sim.incidents.incident(incident_id)
	if inc == null:
		return []
	var primary := String(sim.incidents.catalog.type_row(inc.type, inc.subtype)
			.get("primary_role", ""))
	var out: Array = []
	for uid: int in sim.incidents.fleet.unit_ids():
		var u: Vehicle = sim.incidents.fleet.unit(uid)
		var eta: float = sim.incidents.fleet.eta_h(u, inc.tile)
		out.append({
			"id": u.id, "dept": u.department, "kind": u.type, "state": u.status,
			"eta_gs": -1.0 if is_inf(eta) else eta * 3600.0,
			"eligible": u.is_dispatchable_now(),
			"required": u.has_capability_for(primary),
			"incident_id": u.incident_id,
			"frees_in_gs": maxf(0.0, u.refit_until_h - sim.incidents.now_h) * 3600.0
					if u.status == Vehicle.REFIT else -1.0,
		})
	return out


## The UI emits INTENT and never a sound; the shell is where an intent becomes
## a cue, so no ui/ file knows audio exists.
func _wire_audio_ui(root: UIRoot) -> void:
	if audio == null:
		return
	var tap := func(_a = null, _b = null) -> void: audio.ui_cue(AudioService.UI_TAP)
	var deny := func(_a = null, _b = null) -> void: audio.ui_cue(AudioService.UI_DENY)
	if hud != null:
		hud.speed_selected.connect(tap)
		hud.pause_toggled.connect(tap)
		if hud.has_signal("menu_requested"):
			hud.menu_requested.connect(tap)
	if build_sheet != null:
		build_sheet.placement_started.connect(tap)
	if building_panel != null:
		building_panel.closed.connect(tap)
		building_panel.upgraded.connect(_on_audio_result)
	if root.overlay_rail != null:
		root.overlay_rail.overlay_changed.connect(tap)
		root.overlay_rail.overlay_refused.connect(deny)
	if root.alerts_center != null:
		root.alerts_center.panel_toggled.connect(tap)
	if root.pause_menu != null:
		root.pause_menu.menu_toggled.connect(tap)
	if root.settings_sheet != null:
		root.settings_sheet.sheet_toggled.connect(tap)
	if root.save_load_sheet != null:
		root.save_load_sheet.slot_action.connect(
				func(_action: StringName, _slot: int, result: Dictionary) -> void:
					_on_audio_result(result))


func _on_audio_result(result: Dictionary) -> void:
	audio.ui_cue(AudioService.UI_CONFIRM if bool(result.get("ok", false))
			else AudioService.UI_DENY)


func _on_app_paused(_saved: bool) -> void:
	var sim := sim_host.sim
	_before_snapshot = {"treasury": sim.treasury.balance,
			"population": sim.population.city_population,
			"day_index": sim.clock.day_index(),
			"stability": sim.districts.city_stability,
			"happiness": sim.happiness.happiness}


## doc 13 §2.3: the shell measures, the sim decides. The catch-up SHAPE is
## CatchUpPlanner's (doc 01) — the naive fine-then-coarse split violated
## `advance_coarse_n`'s hour-alignment contract on 239 of 240 tick offsets
## (doc 91 D-1); the planner emits segments that always land on boundaries.
func _on_app_resumed(elapsed_wall_s: float) -> void:
	var sim := sim_host.sim
	var plan: Dictionary = CatchUpPlanner.plan(int(elapsed_wall_s * 1000.0),
			sim.clock.residual_game_ms, sim.clock.tick_index)
	for segment: Dictionary in plan.get("segments", []):
		var count := int(segment.get("count", 0))
		if count <= 0:
			continue
		if String(segment.get("kind", "")) == "coarse":
			sim.advance_coarse_hours(count)
		else:
			sim.scheduler.advance_fine_n(count)
	sim.clock.residual_game_ms = int(plan.get("new_residual_game_ms", 0))
	var offline_batch: Array = sim.bus.drain()
	_on_sim_batch(offline_batch)
	if ui_root == null or _before_snapshot.is_empty() or elapsed_wall_s < 60.0:
		return
	var toast := ui_root.present_away_report({
		"elapsed_wall_s": elapsed_wall_s,
		"elapsed_game_minutes": elapsed_wall_s,      # 1 real s = 1 game min at 1x
		"before": _before_snapshot,
		"after": {"treasury": sim.treasury.balance,
				"population": sim.population.city_population,
				"day_index": sim.clock.day_index(),
				"stability": sim.districts.city_stability,
				"happiness": sim.happiness.happiness},
		"events_digest": offline_batch,
		"unresolved": ui_root.incident_drawer.model.rows() \
				if ui_root.incident_drawer != null else [],
	})
	if toast != "" and hud != null:
		hud.push_alert({"class": "p3", "title": toast})


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
	# Success is announced by building_placed_sim → the purchase cue; only the
	# refusal needs a blip here.
	if audio != null and not bool(result.get("ok", false)):
		audio.ui_cue(AudioService.UI_DENY)
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
	if weather_fx != null:
		weather_fx.refresh(delta, camera_state.focus)
	environment_controller.apply(hour, delta)
	city_view.refresh(delta, hour, camera_rig.camera.global_position)
	if construction_view != null:
		construction_view.refresh(delta, environment_controller.last_night)
	if vehicle_view != null:
		vehicle_view.set_focus(camera_state.focus)
		vehicle_view.refresh(delta, environment_controller.last_night,
				0.0 if sim_host.paused else float(sim_host.speed))
	if ui_root != null:
		# The one onboarding observation the root cannot make for itself.
		ui_root.feed_onboarding({"kind": "camera", "focus": camera_state.focus,
				"zoom_t": camera_state.zoom_t})
	if audio != null:
		# doc 11 §2.15's renderer hooks share cue identities with the sim events,
		# so feeding both sources still yields ONE thunk per blackout.
		audio.feed_batch(render_model.drain_render_events())
		audio.update_audio(delta, camera_rig.camera.global_position,
				environment_controller.last_night)
	if _autosave_interval_s > 0.0 and save_service != null:
		_autosave_timer += delta
		if _autosave_timer >= _autosave_interval_s:
			_autosave_timer = 0.0
			save_service.autosave(sim_host.sim)
	streetlights.refresh(weather_fx.wetness if weather_fx != null else -1.0)
	if _blackout_at >= 0.0 and _screenshot_timer >= _blackout_at:
		_trigger_blackout_demo(true)
		_blackout_at = -1.0
	if _lightning_at >= 0.0 and _screenshot_timer >= _lightning_at:
		weather_fx.strike(0.9)
		_lightning_at = -1.0
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
