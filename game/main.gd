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
## doc 13 §2.9's catch-up slice. WHOLE units only, so one unit longer than this
## still runs to completion — the ANR margin is structural, not budgetary, and
## the budget is here rather than in `sim/` because `sim/` may not read a clock
## (constitution §5). At the measured 6.3 ms (founding) to 190 ms (bench) per
## coarse step this spends exactly one step per frame, which is §2.9's own
## worst-case row.
const CATCHUP_SLICE_USEC := 12000

var sim_host: SimHost
var render_model: RenderStateModel
var city_view: CityView
var streetlights: StreetlightView
var environment_controller: EnvironmentController
var weather_fx: WeatherFX
var flood_view: FloodView
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
## doc 12 §2.7's RUN ghost (roads, water mains). The box ghost's twin; see
## `ui/path_ghost_view.gd`.
var path_ghost_view: PathGhostView
var construction_view: ConstructionSiteView
var construction_plant: ConstructionVehicleView   # doc 11 §2.16: plant + deliveries
## doc 11 §2.17: the crook, the stray, the goat and the dropped stash. A pure
## event consumer — three `opportunity_*` types in, four MultiMeshes out.
var street_life: StreetLifeView
var vehicle_view: VehicleView
## doc 11 §2.10b's distribution layer: transformer pads, service drops and the
## distress plume. Reads the grid on its own schedule, writes nothing back.
var power_infra: PowerInfraView
## doc 12 §2.5 mode 5. Congestion is per road EDGE, so it is the one overlay
## that cannot ride the packed per-building state and gets its own MultiMesh.
var road_overlay: RoadOverlayView
var audio: AudioService
var notification_router: NotificationRouter
var crash_sentinel: CrashSentinel
var permission_flow: PermissionFlow
var perf_governor: PerfGovernor
## doc 13 §2.8 / RR-126 — the rate is DECLARED, not merely capped.
var refresh_pin: RefreshPin
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
var _want_title := false  # clean player launch → the title door owns the load
var _title_up := false    # true while the door is showing; gates saves + catch-up
## The load in flight, or null. While it is non-null the sim is HALF-RESTORED —
## every `_process` line below the guard would read a city that does not exist
## yet — and the title door is still up, which is what the player sees instead
## of a frozen frame (doc 08 §2.15.2, doc 13 §2.9.1).
var _restore_cursor: RestoreCursor = null
var _restore_slot := -1
## The offline catch-up in flight, or null (doc 13 §2.9, report 98 §29 RR-73).
## While it is non-null the city is MID-ABSENCE: every hour of it is a real sim
## state, but it is not the state the HUD, the bus drain or the away report are
## written against, and `SimHost` must not add live ticks on top of the plan.
var _catchup_cursor: CatchUpCursor = null
## What `_finish_catchup()` needs that the cursor does not carry.
var _catchup_after: Dictionary = {}
var _catchup_was_paused := false
var _render_data: Dictionary = {}
var road_surface: RoadSurfaceView
## doc 11 §7.4's PERF line — emitted by this, because nothing ever called
## `PerfGovernor.perf_line()`. See `game/render/perf_telemetry.gd`.
var perf_telemetry: PerfTelemetry


func _ready() -> void:
	var render_data: Dictionary = StarterCityLoader.read_json("res://data/render.json")
	_render_data = render_data
	sim_host = SimHost.new()
	sim_host.name = "SimHost"
	add_child(sim_host)

	save_service = SaveService.new()
	save_service.name = "SaveService"
	# doc 13 §7 D-17: one PERFIO line per save/load, ^PERF-anchored so one logcat
	# grep collects both halves. Set HERE, at construction, and not beside the
	# PerfTelemetry wiring in _build_city_view() — the Fold 6 session of
	# 2026-08-20 found that the boot LOAD runs well before _build_city_view(),
	# so a flag set there can only ever time SAVES; the load in front of the
	# catch-up is the one doc 13 §2.9's ANR arithmetic is missing. Gated: the
	# capture rig is not a player feature.
	save_service.log_io = _perf_capture_armed()
	# doc 08 §2.14 / RR-44: the ENVELOPE half of a save goes to a worker thread.
	# The capture stays here — it reads live sim state — and so does the whole
	# pause path, which `SaveService.SYNC_REASONS` pins. Measured 148.7 -> 97.5 ms
	# of main-thread cost on the 1,500-building city.
	save_service.async_writes = true
	add_child(save_service)
	android_lifecycle = AndroidLifecycle.new()
	android_lifecycle.name = "AndroidLifecycle"
	add_child(android_lifecycle)
	android_lifecycle.setup(save_service, sim_host.sim)
	android_lifecycle.resumed.connect(_on_app_resumed)
	android_lifecycle.paused.connect(_on_app_paused)
	# RR-134: what is LEFT of a catch-up, for doc 13 §3.2's pause stamp to carry
	# across a process death. `{}` whenever none is running, which is almost
	# always.
	android_lifecycle.catchup_probe = _catchup_remainder

	audio = AudioService.new()
	audio.name = "AudioService"
	add_child(audio)
	audio.setup()
	audio.set_locator(_alert_world_pos)
	android_lifecycle.focus_changed.connect(
			func(has_focus: bool) -> void: audio.set_muted(not has_focus))
	notification_router = NotificationRouter.load_from_files()
	notification_router.set_sink(NativeNotificationSink.new())
	android_lifecycle.notification_router = notification_router
	permission_flow = PermissionFlow.new(android_lifecycle.native)
	# PA-14: the counters are per INSTALL, not per city (doc 08 §2.5), so they
	# come off `user://settings.cfg` before anything can ask.
	permission_flow.load_device()
	permission_flow.state_changed.connect(_on_permission_state_changed)
	if android_lifecycle.native != null:
		android_lifecycle.native.permission_result.connect(permission_flow.confirm)
		android_lifecycle.native.notification_opened.connect(_on_notification_opened)

	# Session restore (doc 08 §2.1): on a PLAIN launch — no dev args, which is
	# every real device launch — the most recent save IS the city, restored
	# BEFORE the views build so the world below is the player's progress, not
	# the authored founding state. Dev/screenshot runs stay on the founding
	# city for reproducibility unless they pass --resume. After an UNCLEAN
	# exit (doc 13 §2.11) the crash sentinel picks the newest autosave half
	# that actually PARSES rather than merely the newest.
	crash_sentinel = CrashSentinel.new()
	# doc 13 D-20: on device the export template drops `--esa command_line_params`
	# before `OS` ever sees it, so `DevArgs` merges the plugin's reading of the
	# launching Intent with the engine's list. Off device the two are identical.
	var user_args := DevArgs.user_args()
	var unclean := crash_sentinel.boot()
	# The title door opens on every clean player launch (doc 12 §2.19). Crash
	# recovery and --resume dev runs skip it and load directly; the door's own
	# CONTINUE is what performs the load on the plain path.
	_want_title = not unclean and not user_args.has("--resume") \
			and (user_args.is_empty() or user_args.has("--title"))
	if unclean:
		var recovery_slot := crash_sentinel.recovery_slot(save_service)
		if recovery_slot >= 0 and save_service.load_slot(sim_host.sim, recovery_slot):
			_resumed_slot = recovery_slot
		push_warning("[crash] unclean exit #%d; breadcrumb %s"
				% [crash_sentinel.unclean_exits, crash_sentinel.breadcrumb_path()])
	elif not _want_title and (user_args.is_empty() or user_args.has("--resume")):
		_resumed_slot = save_service.load_latest(sim_host.sim)
	if _resumed_slot >= 0 and save_service.last_load_recovered:
		# Doc 08 §2.9's recovery UX: say what generation the ladder fell back to.
		push_warning("[save] recovered from a checkpoint; %d sim-minutes lost%s"
				% [save_service.last_load_lost_minutes,
				"" if save_service.repair_notes.is_empty()
				else " (%d repairs)" % save_service.repair_notes.size()])
	if _resumed_slot >= 0 and android_lifecycle != null:
		# Doc 08's Core Rule 2 on a COLD launch (report 98 §48, RR-132): the city
		# owes the real time since the generation it just came off was committed.
		# `pump_resume()` in `_process` spends it on the first frame with no
		# cursor in flight, which is after the views exist.
		android_lifecycle.arm_cold_resume(save_service)

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
	# doc 12 §2.7: a single-finger stroke DRAWS a run while a run tool is up
	# and pans the camera otherwise.
	touch_input.world_drag_router = _route_world_drag

	for arg in DevArgs.user_args():
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
	# doc 11 §2.1.2: asphalt, lane markings, kerbs and footways, off doc 10's
	# road graph. Two draw calls city-wide — the slab MultiMesh this replaces
	# was one, and every line of paint is fragment work inside the first of them.
	road_surface = RoadSurfaceView.new()
	road_surface.name = "RoadSurface"
	ground_root.add_child(road_surface)
	road_surface.setup(_render_data)
	road_surface.rebuild(world.grid,
			sim_host.sim.roads.graph if sim_host.sim.roads != null else null)
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
	# doc 11 §2.9b / doc 07 §2.4: standing water on flooded LOW blocks' road
	# tiles. ONE MultiMesh for the whole city; the node hides itself when the
	# city is dry, so a dry frame costs nothing (A91-D-26).
	flood_view = FloodView.new()
	flood_view.name = "Flood"
	ground_root.add_child(flood_view)
	flood_view.setup(_render_data)
	flood_view.rebuild(world.grid)
	# Doc 07 PERSISTS the flood field, so a save resumed mid-flood has its
	# answer before the first frame rather than after the next band crossing.
	flood_view.prime(sim_host.sim.weather.flood.depth_mm)
	flood_view.snap()


## doc 11 §2.13b — the engine-side half of a graphics preset, in ONE place, so
## boot, the settings row and the governor's latched drop cannot drift apart
## (report 98 RR-98: render_scale, MSAA/FXAA, shadows, glow and the street-light
## budget were authored per preset and applied nowhere).
func _apply_quality(preset_name: String) -> void:
	var q := QualityApplier.resolve(_render_data, preset_name,
			perf_governor.knobs() if perf_governor != null else {})
	QualityApplier.apply_viewport(get_viewport(), q)
	if environment_controller != null:
		environment_controller.apply_quality(q)
	if streetlights != null:
		streetlights.set_light_budget(int(q["street_lights"]))


func _build_city_view(render_data: Dictionary) -> void:
	render_model = RenderStateModel.new(render_data)
	# doc 11 §7.4 / tools/bench_device.sh: pin the graphics preset from the
	# launch arguments, BEFORE PerfGovernor and the per-layer seeds read it.
	for preset_arg in DevArgs.user_args():
		if String(preset_arg).begins_with("--preset="):
			render_model.set_preset(String(preset_arg).trim_prefix("--preset="))
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
	# doc 11 §2.10.1: lamps on the KERB at `road_surface.lamp.spacing_tiles`
	# (4 tiles = the authored 32 m), alternating sides down a corridor,
	# staggered across a dual carriageway, arm over the carriageway. The
	# `(x + z) % 4 == 0` parity test this replaces stipples a diagonal across
	# the city and stands every pole in the middle of the road.
	var lamps := StreetlightPlacer.place(sim_host.sim.world.grid,
			sim_host.sim.roads.graph if sim_host.sim.roads != null else null,
			render_data, sim_host.sim.world.block_of_tile)
	streetlights = StreetlightView.new()
	streetlights.name = "Streetlights"
	add_child(streetlights)
	streetlights.setup(render_model, render_data, lamps)
	vehicle_view = VehicleView.new()
	vehicle_view.name = "Vehicles"
	add_child(vehicle_view)
	vehicle_view.setup(render_data)
	perf_governor = PerfGovernor.new(render_data, render_model.preset)
	refresh_pin = RefreshPin.new(render_data, android_lifecycle.native)
	refresh_pin.apply_lever(DevArgs.user_args())
	_apply_frame_cap(perf_governor.target_fps())
	# doc 11 §2.13's Fold pass: the PERF capture rig — measurement machinery,
	# NOT a player feature, so it arms only when `_perf_capture_armed()`.
	# Always-on it cost every session a per-frame GPU timestamp query
	# (`viewport_set_measure_render_time`), exactly the class of driver sync
	# point filed while chasing the Fold's presentation-corruption bands.
	# (`save_service.log_io` arms at construction, under the same check — the
	# boot LOAD runs long before this line, and it is the one doc 13 §2.9's
	# ANR arithmetic is missing.)
	if _perf_capture_armed():
		perf_telemetry = PerfTelemetry.new(render_data)
		perf_telemetry.set_viewport(get_viewport().get_viewport_rid())
		perf_telemetry.set_census_source(func() -> Dictionary:
				return render_model.tier_census())
		perf_telemetry.set_instance_source(func() -> int:
				return render_model.building_count())
	# Boot-time presets: a phone that auto-detected into Performance used to come
	# up with Balanced counts on every per-layer view until the player touched
	# the settings row. Seed them all from the resolved preset once, here.
	# doc 11 §2.13b: the ENGINE-side half of the same preset (report 98 RR-98).
	_apply_quality(render_model.preset)
	if streetlights != null:
		streetlights.set_preset(render_model.preset, render_data)
	if road_surface != null:
		road_surface.set_preset(render_model.preset, render_data)
	if flood_view != null:
		flood_view.set_preset(render_model.preset, render_data)
	vehicle_view.set_preset(render_model.preset, render_data)
	android_lifecycle.thermal_status_changed.connect(perf_governor.set_thermal_status)
	construction_view = ConstructionSiteView.new()
	construction_view.name = "ConstructionSites"
	add_child(construction_view)
	construction_view.setup(render_data)
	# doc 11 §2.16: plant, deliveries and the yard. Same three site calls the
	# hoarding view takes; the road network is the one extra thing it needs.
	construction_plant = ConstructionVehicleView.new()
	construction_plant.name = "ConstructionPlant"
	add_child(construction_plant)
	construction_plant.setup(render_data)
	construction_plant.set_preset(render_model.preset, render_data)
	construction_plant.set_road_network(sim_host.sim.roads)
	# Routes resolve two sites a frame, so a site's frontage can land AFTER its
	# hoarding went up — and a road edit can move it later. This is the wire
	# that turns the gate when it does (doc 11 §2.16).
	construction_plant.site_frontage_changed.connect(
			func(id: int, side: int) -> void:
				if construction_view != null:
					construction_view.set_gate_side(id, side))
	# doc 11 §2.17 — STREET LIFE. The road CLASS probe is what puts a crook on a
	# footway rather than in a traffic lane; without it the layer still draws,
	# it just wanders the spawn tile.
	street_life = StreetLifeView.new()
	street_life.name = "StreetLife"
	add_child(street_life)
	street_life.setup(render_data)
	street_life.set_preset(render_model.preset, render_data)
	street_life.set_road_probe(StreetLifeView.road_probe(sim_host.sim.world))
	# doc 11 §2.10b — the visible power grid. The height lookup is the mesh
	# manifest's (a service drop lands on the eave, not on the roof); the road
	# probe is doc 10's tile flags, which turn each cabinet's doors to the street.
	power_infra = PowerInfraView.new()
	power_infra.name = "PowerInfra"
	add_child(power_infra)
	power_infra.setup(render_data, func(archetype: StringName, level: int) -> float:
			return float(_height_of.get("%s:%d" % [archetype, level], 10.0)))
	power_infra.set_road_probe(PowerInfraFeed.road_probe(sim_host.sim.world))
	for id in sim_host.sim.buildings.keys():
		if (sim_host.sim.buildings[id] as Building).state == &"under_construction":
			_add_construction_site(String(id))
	_apply_render_ab_args()


## The render A/B levers, as launch arguments (doc 11 §2.13, runbook §3.3).
##
## **Why these are here and not in the main argument loop.** That loop runs
## during bring-up, before `road_surface`, `flood_view` or `power_infra` exist;
## these have to be applied after every view is built AND after the preset seeding
## above, because each one deliberately OVERRIDES the per-tier ceiling that
## `set_preset()` just applied. That is the whole point of an A/B lever: it asks
## "what would this rung cost here", not "what does this tier allow".
##
## **The fault this closes (2026-08-21).** `--road-detail`, `--pad-shadows` and
## `--flood-detail` existed only as `tools/profile_frame.gd` flags, so the three
## questions that most needed a device answer — does the RR-42 zebra early-out's
## 61-69 % win survive on Adreno 750, does `flood_detail` earn its rung, does the
## pad-shadow ruling hold at a daylight pose — were undrivable on hardware no
## matter how well the arguments were delivered. They were the last of the three
## items in the runbook's "what needs the telemetry build" list.
##
## **A lever can only LOWER a rung, never raise one.** Both `set_detail`s clamp
## to their view's `detail_ceiling`, which the preset sets — the same one-way
## contract `PerfGovernor` has with every other knob, and the right rule, but it
## makes one A/B silently dishonest: on a phone that auto-detected into
## `performance` (`road_detail` 1) a `--road-detail=2` arm IS rung 1, so the
## ladder measures as free. That is the answer such a session is hoping for,
## which is what makes it dangerous. **Pin `--preset=balanced` alongside any
## rung-2 arm** (its ceiling is 2 for both road and flood);
## `tools/run_matrix.sh` does.
##
## Debug/QA only, and they are read from the same merged list as everything else,
## so they arrive over `--es args` exactly like `--zoom`.
## doc 13 §2.8 / RR-126: the ONE door for the frame cap. Capping without
## declaring the rate leaves a 1-120 Hz LTPO panel hunting between modes on
## every cadence change — the sub-menu bands the user reported — so the pin
## tells the compositor and the panel the same number the cap does.
func _apply_frame_cap(fps: int) -> void:
	Engine.max_fps = fps
	if refresh_pin != null:
		refresh_pin.pin(fps)


func _apply_render_ab_args() -> void:
	for arg in DevArgs.user_args():
		var a := String(arg)
		if a.begins_with("--road-detail=") and road_surface != null:
			road_surface.set_detail(int(a.trim_prefix("--road-detail=")))
		elif a.begins_with("--pad-shadows=") and power_infra != null:
			power_infra.set_pad_shadows(a.trim_prefix("--pad-shadows=") != "0")
		elif a.begins_with("--flood-detail=") and flood_view != null:
			flood_view.set_detail(int(a.trim_prefix("--flood-detail=")))
		elif a.begins_with("--road-tint=") and road_surface != null:
			# doc 12 D-74 / doc 11 §2.1.2: the carriageway tint gain, in LINEAR — the
			# device-gated A/B for the blob shadow's body_alpha question (RR-97).
			road_surface.set_tint_gain(float(a.trim_prefix("--road-tint=")))
		elif a.begins_with("--flood=") and flood_view != null:
			# Standing water on demand, in mm, over every tile the flood layer
			# knows about — the device's first look at the wet look without
			# waiting for doc 07's director to route a storm to a basin.
			var mm := float(a.trim_prefix("--flood="))
			var depths := {}
			for key: Variant in flood_view.floodable_cell_keys():
				depths[String(key)] = mm
			flood_view.prime(depths)
			flood_view.snap()


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
	# doc 11 §2.16: the hoarding's gate takes the frontage the vehicle layer
	# derives off doc 10's live network, so the gate, the skip standing in it
	# and the coned-off lane are all on the same face of the lot.
	var gate_side := -1
	if construction_plant != null:
		gate_side = construction_plant.frontage_side(center, size)
	construction_view.add_site(b.id, center, size, height, gate_side)
	if construction_plant != null:
		construction_plant.add_site(b.id, center, size, height)


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
	if flood_view != null:
		flood_view.feed_events(batch)   # doc 07's flood_level_changed
	if street_life != null:
		street_life.feed_events(batch)  # doc 11 §2.17's opportunity_* trio
	for event in batch:
		match StringName(String(event.get("type", ""))):
			&"road_graph_changed", &"block_roads_stamped":
				# Player roads and stamped ring blocks would otherwise be
				# invisible until restart — the street surface is built at boot.
				_rebuild_road_multimesh()
			&"grid_component_placed", &"grid_feeder_routed", \
					&"grid_node_commissioned", &"grid_node_retired", \
					&"grid_component_upgraded", &"grid_component_removed", \
					&"building_placed_sim", &"building_removed":
				# doc 11 §2.10b: the pad/wire topology moved. A flag only; the
				# rebuild lands on the next `sync` and is a no-op if the grid's
				# shape turns out to be what it already was.
				if power_infra != null:
					power_infra.note_topology_changed()
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
		# PA-14: the same classified plans answer the one question a re-prompt
		# has to answer — was there a P1 the player never heard about?
		_note_permission_evidence(notification_router.feed_batch(batch))
	_note_permission_trigger(batch)
	_maybe_auto_speed_reset(batch)
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
			&"water_component_placed":
				# The pump/tank/treatment SHELL is a real doc-02 building
				# (`cmd_place_water_component` step 1), but it announces itself
				# on doc 05's own event — without this arm it never reached the
				# renderer until the next relaunch re-read the roster, and the
				# player watched their money buy a blank tile.
				var water_view := _building_view(String(event.get("sim_id", "")))
				if not water_view.is_empty():
					translated.append({"type": &"building_placed", "view": water_view})
					_add_construction_site(String(event.get("sim_id", "")))
			&"upgrade_started_sim":
				_add_construction_site(String(event.get("sim_id", "")))
			&"building_construction_stage":
				translated.append(event)  # already carries the int render id
				var stage_rid := int(event.get("building", -1))
				var stage_no := int(event.get("stage", 1))
				if construction_view != null:
					construction_view.set_stage(stage_rid, stage_no)
				if construction_plant != null:
					construction_plant.set_stage(stage_rid, stage_no)
			&"BuildingPowerChanged":
				var rid := _render_id(String(event.get("building", "")))
				if rid >= 0:
					translated.append({"type": &"BuildingPowerChanged",
							"building": rid, "state": event.get("state", &"LIT")})
			&"building_removed":
				# The payload's `building` is already the render id; without this
				# the mesh survives its own demolition.
				translated.append(event)
				var gone := int(event.get("building", -1))
				if construction_view != null:
					construction_view.remove_site(gone)
				if construction_plant != null:
					construction_plant.remove_site(gone)
			&"building_damaged", &"building_destroyed", &"building_completed", \
					&"building_repaired":
				var rid2 := _render_id_from_int(event.get("building", -1))
				if rid2 >= 0:
					var out: Dictionary = event.duplicate()
					out["building"] = rid2
					translated.append(out)
					if StringName(String(event["type"])) == &"building_completed":
						if construction_view != null:
							construction_view.remove_site(rid2)
						if construction_plant != null:
							construction_plant.remove_site(rid2)
			&"PowerRestored":
				pass  # per-block relights arrive via BlockDarkChanged(false)
			_:
				pass
	if not translated.is_empty():
		render_model.apply_events(translated)


## A player verb that COMPLETES work (doc 03 §2.13(f)'s rush) emits its events
## from inside the command, and the only live drain is `SimHost._process`'s,
## which does not run while the game is paused (`sim_host.gd:27`). This is the
## door that lets a command's own batch through immediately. It is NOT a
## second translator — it is `_on_sim_batch`, called once, with the events
## already on the bus — and it is idempotent: a second call drains an empty
## array and does nothing. The same two lines `_apply_offline_progress` runs.
func flush_sim_events() -> void:
	if sim_host == null or sim_host.sim == null:
		return
	var batch: Array = sim_host.sim.bus.drain()
	if not batch.is_empty():
		_on_sim_batch(batch)


func _render_id(sim_id: String) -> int:
	var b: Building = sim_host.sim.buildings.get(sim_id)
	return b.id if b != null else -1


func _render_id_from_int(value: Variant) -> int:
	return int(value) if typeof(value) != TYPE_STRING else _render_id(String(value))


## Dev arg `--place=<archetype>`: buy one building on the first serviceable
## vacant core lot, exactly as a player tap would — verifies the incremental
## render add end-to-end.
## The PERF/PERFIO capture rig's arming switch. `--perf` works on desktop and,
## since doc 13 D-20 landed, on device too:
##   adb shell am start -n $PKG/$ACT --es args "--resume --perf"
## The flag FILE stays as the route for a session that wants the capture armed
## across relaunches without repeating the argument:
##   adb shell run-as com.slacumcity.game touch files/perf_capture.flag
## (debug builds only — which is what every measured build is). Delete the file
## to disarm; a player never has either.
static func _perf_capture_armed() -> bool:
	return DevArgs.user_args().has("--perf") \
			or FileAccess.file_exists("user://perf_capture.flag")


func _place_demo(archetype: String) -> void:
	var sim := sim_host.sim
	# A water kind routes through doc 05's verb, sited by its own preview —
	# the water quote also needs a main within tap radius, which `would_serve`
	# knows nothing about.
	if not sim.water.data.placeable_rules(archetype).is_empty():
		for z in range(32, 80):
			for x in range(32, 80):
				var spot := Vector2i(x, z)
				if bool(sim.cmd_place_water_component(archetype, spot, 1, true).get("ok", false)):
					print("[place-demo] ", archetype, " at ", spot, " -> ",
							sim.cmd_place_water_component(archetype, spot))
					return
		print("[place-demo] no plumbable vacant lot found")
		return
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
	var conditions: Dictionary = {}
	for sim_id: String in sim.buildings:
		power[sim_id] = 0.0 if unserved.has(sim_id) \
				else sim.grid.power_availability_hour(sim_id)
		# doc 12 §2.9 item 6's world-side cue: condition → the renderer's damage
		# channel, so wear is visible on the building and a repair washes it off.
		conditions[(sim.buildings[sim_id] as Building).id] = \
				(sim.buildings[sim_id] as Building).condition
	if render_model != null:
		render_model.ingest_conditions(conditions)
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
		elif active_overlay == OverlayModel.MODE_POWER:
			_feed_power_overlay_summary()
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
		ui_root.refresh_land_panel()
		# The goal chip and, while it is up, the sheet. Cheap — a five-row
		# objective list and a six-rung strip — so it rides the same 1 Hz
		# cadence every other reading does. This is also what re-seeds the chip
		# after a save load: `_on_ui_save_loaded` calls `_refresh_hud()`, and
		# `GoalsModel` holds the same `CitySim` instance the load restores into.
		ui_root.refresh_goals()
		# S16: the chip's badge while the panel is shut, the bars and the ETAs
		# while it is open. Bounded by the city's in-flight job count.
		ui_root.refresh_construction()


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
	path_ghost_view = PathGhostView.new()
	path_ghost_view.name = "PathGhost"
	add_child(path_ghost_view)
	path_ghost_view.setup(cfg, build_controller.tile_m)

	build_sheet = ui_instance.get_node_or_null(
			"SafeArea/SheetLayer/BuildSheet") as BuildSheet
	if build_sheet != null:
		build_sheet.setup(cfg, build_controller)
	if ui_root != null:
		ui_root.bind_water_actions(build_controller.water)
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
		# doc 12 §2.9 item 6: the three actions the panel performs.
		building_panel.repaired.connect(_on_building_action)
		building_panel.priority_set.connect(_on_building_action)
		building_panel.demolished.connect(_on_building_demolished)
		# doc 05 §6's node ladder (doc 93 §J1). Two args, so not `_on_building_action`.
		building_panel.water_upgraded.connect(
				func(_node_id: String, _result: Dictionary) -> void: _refresh_hud())
		# doc 04 §4's operating verbs (Wave 17, doc 12 D-70/D-71). Same shape as
		# the water ladder above: two args, and the city moved, so the chips do.
		building_panel.power_fixed.connect(
				func(_sim_id: String, _result: Dictionary) -> void: _refresh_hud())
		building_panel.grid_upgraded.connect(
				func(_component_id: String, _result: Dictionary) -> void: _refresh_hud())
		building_panel.grid_demolished.connect(
				func(_component_id: String, _result: Dictionary) -> void: _refresh_hud())
		# S16 on S5 (doc 12 §2.22 item 3): the SAME model instance the queue
		# panel holds, so the two can never publish different numbers for one
		# project. Three args, so the refusal is forwarded by hand — an accepted
		# rush is felt from the bus (flushed by the bound verb, see
		# `bind_construction` below) and `report_rush` deliberately says nothing.
		if ui_root != null and ui_root.construction_queue != null:
			building_panel.bind_construction(ui_root.construction_queue.model)
			building_panel.rushed.connect(
					func(_sim_id: String, job_id: int, result: Dictionary) -> void:
						ui_root.report_rush(job_id, result))
	if ui_root != null and ui_root.land_panel != null:
		ui_root.land_panel.setup(cfg, LandPanelModel.new(sim_host.sim,
				build_controller.formatter, cfg, build_controller.tile_m))
		ui_root.land_purchased.connect(_on_land_changed)
		ui_root.land_developed.connect(_on_land_changed)
		ui_root.land_fix_requested.connect(_on_fix_requested)

	# S14, the goals sheet (doc 12 §2.19). `UIRoot.bring_up_screens()` already
	# brought it up with the shared config and NO model, exactly as it does the
	# build sheet. This is the one thing only the shell can supply: a model over
	# the live sim, plus the build controller the reward card reads its unlock
	# table from. Idempotent.
	if ui_root != null and ui_root.goals_sheet != null:
		ui_root.goals_sheet.setup(cfg,
				GoalsModel.new(sim_host.sim, cfg, build_controller))

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
	# PA-14: S10's state row and the rationale modal's two answers.
	root.settings_action.connect(_on_ui_setting_action)
	root.permission_answered.connect(_on_permission_answered)
	root.save_loaded.connect(_on_ui_save_loaded)
	root.set_incident_locator(_alert_world_pos)
	root.set_unit_provider(_dispatchable_units)
	root.dispatch_requested.connect(_on_ui_dispatch)
	root.incident_action.connect(_on_ui_incident_action)
	# doc 05 §2.12's valve — already issued by the drawer; the shell only re-reads.
	root.water_main_action.connect(
			func(_id: int, _edge: String, _action: StringName, _r: Dictionary) -> void:
				_feed_water_overlay())
	root.deeplink_requested.connect(_on_ui_deeplink)
	root.bind_tax(sim_host.sim.cmd_set_tax_level, sim_host.sim.tax_level(),
			sim_host.sim.tax_level_count(), sim_host.sim.tax_rate)
	# Doc 10 §2.13's automatic road repair (doc 12 D-50): the PAIR of dials
	# `RoadNetwork` takes, seeded from what this city actually holds so a
	# restored save's policy wins over the data default.
	root.bind_road_policy(sim_host.sim.cmd_set_auto_repair_policy,
			sim_host.sim.auto_repair_policy())
	# Doc 06 §2.11's recall (doc 12 D-48, doc 91 A91-D-24): one line is the door.
	root.bind_recall(sim_host.sim.cmd_recall_unit)
	# S16 (doc 12 §2.22, D-66): the construction seam — the overview provider,
	# the rush door and a treasury reading so an unaffordable rush shows its
	# price on a disabled face instead of vanishing. The rush door is WRAPPED:
	# a verb that completes work emits from inside the command, and the only
	# live drain (`SimHost._process`) does not run while paused — so the crane
	# a paused player just paid to remove would stand until they un-paused
	# (doc 98 RR-108). The camera jump already rides `set_incident_locator()`;
	# the toast, the chip pulse and the `purchase` cue ride `feed_events()`.
	root.bind_construction(sim_host.sim.construction_overview,
			func(job_id: Variant) -> Dictionary:
				var result: Dictionary = sim_host.sim.cmd_rush_construction(job_id)
				if bool(result.get("ok", false)):
					flush_sim_events()
				return result,
			func() -> int: return int(sim_host.sim.treasury.balance))
	root.bind_dispatch_policy(sim_host.sim.cmd_set_dispatch_policy,
			sim_host.sim.incidents.dispatch.policy.serialize())
	# Doc 03 §2.9: S9 shows the city's difficulty read-only (doc 93 §K1 — there
	# is no setter, so this is a REPORT and not a binding).
	root.set_city_difficulty(sim_host.sim.difficulty_preset())
	# §2.13's level-up moment fires on a CHANGE; seed the level the city already
	# has so a resumed save does not celebrate it a second time.
	root.set_city_level(sim_host.sim.progression.city_level)
	if save_service != null:
		root.bind_save_service(save_service, sim_host.sim)
	if root.settings_sheet != null:
		# PA-15: `user://settings.cfg` FIRST, before anything below reads a row.
		# It is the device's answer — graphics preset, refresh pin, text scale,
		# the notification switches — and it outranks both the data defaults the
		# model booted on and the `ui` block a resumed save is about to restore
		# (doc 08 §2.5, doc 12 §3.2, constitution §2 amendment #3). The three
		# reads under it therefore pick the device's numbers up for free.
		var dropped_device := root.load_device_settings()
		if not dropped_device.is_empty():
			push_warning("[settings] device file dropped %s" % str(dropped_device))
		# The preset is the one device row whose effect is spread over eight
		# views and the governor, and all of them were seeded at boot from the
		# data default. One re-apply through the change path puts them on the
		# player's preset instead of duplicating that list here.
		_on_ui_setting_changed(&"graphics", root.settings_sheet.model.value("graphics"))
		_refresh_permission_row()
		_autosave_interval_s = root.settings_sheet.model.autosave_interval_s()
		if audio != null:
			audio.set_sound_volume(root.settings_sheet.model.value_num("sound_volume"))
		if refresh_pin != null and perf_governor != null:
			# doc 12 D-75: the saved refresh mode, applied before the first frame cap.
			refresh_pin.set_mode(str(root.settings_sheet.model.value("refresh_rate")), true)
			_apply_frame_cap(perf_governor.target_fps())
	_wire_audio_ui(root)
	root.ui_coverage_changed.connect(audio.set_ui_coverage)  # interior muffle
	# Saves carry the UI section (doc 12 §3.2) so a restored city keeps its
	# tutorial progress and overlay prefs; the provider rides every save.
	# Doc 12 §2.16's tilt axis (Wave 17, D-68): the slider, the gesture and the
	# camera save block all hang off this one binding.
	root.bind_camera(camera_state)
	save_service.ui_provider = root.capture_ui_state
	if _resumed_slot >= 0:
		root.restore_ui_state(save_service.last_loaded_ui)
	# Onboarding (doc 12 S12): starts only on a genuinely new city. A resumed
	# save's flow — mid-tutorial or finished — came back through the UI section
	# above; the regions are set either way so world-tag cutouts work on resume.
	root.set_onboarding_world_resolver(_coach_world_rect)
	root.set_onboarding_world_projector(_coach_world_point)
	root.onboarding_action.connect(_on_coach_action)
	var tutorial_regions := {
		"tutorial_lot_a": sim_host.sim.loader.resolve_tag("tutorial_lot_a")["tile_global"],
		"tutorial_lot_b": sim_host.sim.loader.resolve_tag("tutorial_lot_b")["tile_global"],
	}
	if root.onboarding != null and root.onboarding.model != null:
		root.onboarding.model.set_regions(tutorial_regions)
	if _want_title:
		# The title door (doc 12 §2.19): the world idles paused underneath; the
		# shell loads/founds only when the door says so. Lifecycle saves stand
		# down too — the founding city under the door must never be committed
		# over the player's autosave.
		root.title_continue.connect(_on_title_continue)
		root.title_new_game.connect(_on_title_new_game)
		sim_host.paused = true
		_title_up = true
		if android_lifecycle != null:
			android_lifecycle.save_enabled = false
		root.present_title()
	elif _resumed_slot < 0:
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
	_feed_power_overlay_summary()
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
	elif mode == OverlayModel.MODE_POWER:
		_feed_power_overlay_summary()
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


## §2.5's three aggregate lines for the POWER overlay (doc 12 §2.10 D-72). The
## legend card's own reading: the pool, the WIRES, and which of the two is the
## wall. `PowerActions` computes it, `UIRoot.power_summary_lines` shapes it, and
## this only decides when — the same contract `_feed_coverage_overlay` has.
func _feed_power_overlay_summary() -> void:
	if ui_root == null or build_controller == null or build_controller.power == null:
		return
	ui_root.feed_overlay_summary(OverlayModel.MODE_POWER,
			UIRoot.power_summary_lines(build_controller.power.grid_reading(),
					ui_root.config))


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


## Wave 14 (doc 12 §2.21 / D-63): where a one-shot street notice points. The
## tag resolver above answers for a fixed tutorial lot; a collectable walks, so
## the mark is handed the metres themselves.
func _coach_world_point(world: Vector3) -> Variant:
	var answer := camera_state.project_to_screen(world,
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
	if kind == &"cell":
		# doc 07 §2.4 keys a flood cell "B<bx>,<bz>" (land block) or "<tx>,<tz>".
		var parts := str(id).split(",")
		if parts.size() == 2:
			if str(id).begins_with("B"):
				var bx := int(parts[0].substr(1))
				var bz := int(parts[1])
				return Vector3((bx * 16 + 8) * tile_m, 0.0, (bz * 16 + 8) * tile_m)
			return Vector3(int(parts[0]) * tile_m + 4.0, 0.0,
					int(parts[1]) * tile_m + 4.0)
	return null


func _on_ui_focus_requested(world_pos: Vector3) -> void:
	camera_state.focus_on(world_pos)


func _on_ui_quit_requested() -> void:
	# Single-scene game: quit means save, then close. The view only asks.
	if save_service != null:
		save_service.autosave(sim_host.sim, "quit")
		if save_service.last_error == "" and crash_sentinel != null:
			crash_sentinel.mark_clean_exit()
	get_tree().quit()


func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST:
		return
	# Desktop window close (and Android task close): same contract as the quit
	# menu — commit, then mark clean. Skipped under the title door, where the
	# only world held is the founding city and committing it would overwrite
	# the player's autosave.
	if save_service != null and sim_host != null and not _title_up:
		save_service.autosave(sim_host.sim, "quit")
		if save_service.last_error == "" and crash_sentinel != null:
			crash_sentinel.mark_clean_exit()


func _on_ui_setting_changed(key: StringName, _value: Variant) -> void:
	var model: SettingsModel = ui_root.settings_sheet.model
	match key:
		&"graphics":
			render_model.set_preset(str(model.value("graphics")))
			_apply_quality(str(model.value("graphics")))
			if streetlights != null:
				streetlights.set_preset(str(model.value("graphics")), _render_data)
			if vehicle_view != null:
				vehicle_view.set_preset(str(model.value("graphics")),
						StarterCityLoader.read_json("res://data/render.json"))
			if construction_plant != null:
				construction_plant.set_preset(str(model.value("graphics")),
						StarterCityLoader.read_json("res://data/render.json"))
			if road_surface != null:
				road_surface.set_preset(str(model.value("graphics")),
						StarterCityLoader.read_json("res://data/render.json"))
			if flood_view != null:
				flood_view.set_preset(str(model.value("graphics")),
						StarterCityLoader.read_json("res://data/render.json"))
			if street_life != null:
				street_life.set_preset(str(model.value("graphics")),
						StarterCityLoader.read_json("res://data/render.json"))
			if perf_governor != null:
				# A player's preset choice clears the ladder and any latched drop.
				perf_governor.reset(str(model.value("graphics")))
				# RR-126: Performance's target_fps is 30 and reset() re-reads it — the
				# cap used to wait for the governor to step a knob before it moved.
				_apply_frame_cap(perf_governor.target_fps())
		&"autosave_interval_min":
			_autosave_interval_s = model.autosave_interval_s()
			_autosave_timer = 0.0
		&"notifications_enabled", &"notify_p1_critical", &"notify_p2_important", \
		&"notify_p3_routine", &"quiet_hours_allow_critical":
			notification_router.apply_settings(model.capture_state())
		&"auto_quality":
			if perf_governor != null:
				perf_governor.enabled = bool(model.value("auto_quality"))
		&"refresh_rate":
			if refresh_pin != null and perf_governor != null:
				refresh_pin.set_mode(str(model.value("refresh_rate")), true)
				_apply_frame_cap(perf_governor.target_fps())
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


## doc 01 §2.9 / doc 12 §2.11's `auto_speed_reset_on_critical`, wired (PA-84).
##
## `HudModel.auto_speed_reset` had no caller outside its own test. It has one
## now, and the whole design decision is in WHAT reaches it: three authored
## events (`data/ui.json.speed.auto_speed_reset_triggers`), not every CRITICAL
## alert, plus a ten-real-minute re-arm — because the naive wiring drops the
## player to 1× several times an hour under PA-07's alert load, and a speed
## control that keeps being taken away is worse than a feature that never landed.
##
## It never touches `paused`: §2.11 is explicit that pausing the player mid-crisis
## is worse than the crisis. The alert banner is not raised here either — the same
## event is already on its way to `AlertsModel` through `feed_events` above.
var _auto_speed_reset_at_ms := -1.0e12


func _maybe_auto_speed_reset(batch: Array) -> void:
	if ui_root == null or hud == null or hud.model == null:
		return
	if sim_host.paused or sim_host.speed <= 1:
		return   # nothing to hand back
	var now_ms := float(Time.get_ticks_msec())
	if now_ms - _auto_speed_reset_at_ms < hud.model.auto_speed_reset_rearm_s() * 1000.0:
		return
	for raw: Variant in batch:
		if not (raw is Dictionary):
			continue
		if not hud.model.is_auto_speed_reset_trigger(raw as Dictionary):
			continue
		var answer := hud.model.auto_speed_reset(sim_host.speed, sim_host.paused)
		sim_host.speed = int(answer["speed"])
		_auto_speed_reset_at_ms = now_ms
		_refresh_hud()   # the rail's face follows the sim, as it does for a tap
		return


# ---------------------------------------------------------------------------
# POST_NOTIFICATIONS (PA-14 · A91-D-69) — doc 13 §2.7, wired at last
# ---------------------------------------------------------------------------
#
# `PermissionFlow` has been complete and tested since Wave 11 and had no caller:
# the app on the Fold has never requested the permission, so on a targetSdk-33+
# device nothing in the notification stack could post at all. What was missing
# was five seams, and they are all here:
#
#   1. the TRIGGER      — `_note_permission_trigger`, below
#   2. the IDLE FRAME   — `_pump_permission_prompt`, called from `_process`
#   3. the MODAL        — `UIRoot.present_permission_rationale` → `PermissionSheet`
#   4. the ANSWER       — `_on_permission_answered` → `accept()` / `decline()`
#   5. the FALLBACK     — S10's row, `_on_ui_setting_action`
#
# Doc 13 §2.7 step 1 names the trigger: "the FIRST time the shell wants to
# schedule anything, which in practice is the end of onboarding step 10
# (`Upgrade one building` → first construction timer exists)". Doc 08 §2.13.4
# names the other one: the first resolved incident. Both are here; whichever the
# player reaches first wins, and neither is launch — a cold prompt converts
# badly and burns one of the two chances Android allows.
#
# **`building_placed_sim` is deliberately NOT a trigger** even though it creates
# a construction timer too. The tutorial has the player place a house within its
# first minute; asking there is asking a player who has not yet seen the city do
# anything worth being told about, which is the cold prompt with extra steps.

## Doc 13 §2.7 step 1 and doc 08 §2.13.4, as event types.
const PERMISSION_TRIGGERS: Array[StringName] = [
	&"upgrade_started_sim",   # the first construction timer the player CHOSE
	&"incident_resolved",     # …or the first thing they fixed
]
## doc 08's own class rank for P1 (`data/notifications.json.classes`).
const PERMISSION_EVIDENCE_RANK := 1


func _note_permission_trigger(batch: Array) -> void:
	if permission_flow == null or permission_flow.triggered:
		return
	for raw: Variant in batch:
		if not (raw is Dictionary):
			continue
		if PERMISSION_TRIGGERS.has(StringName(String((raw as Dictionary).get("type", "")))):
			permission_flow.note_trigger()
			return


## The evidence a SECOND prompt needs (doc 13 §2.7 step 7): a P1 the player was
## never told about, because the app had no permission to tell them. Recorded
## from the router's own classification so this file holds no copy of doc 08's
## class table, and only while the permission is genuinely absent — a P1 that
## DID buzz is not a reason to ask for anything.
func _note_permission_evidence(plans: Array) -> void:
	if permission_flow == null or notification_router == null:
		return
	if permission_flow.notifications_enabled():
		return
	for raw: Variant in plans:
		if not (raw is Dictionary):
			continue
		var class_id := str((raw as Dictionary).get("class", ""))
		if notification_router.config().class_rank(class_id) == PERMISSION_EVIDENCE_RANK:
			permission_flow.note_missed_p1()
			return


## One frame with nothing else on it. The rationale is a modal and a modal that
## opens over the title door, over the veil, over a placement or over another
## modal is a modal the player dismisses without reading — which costs one of
## the two chances and buys nothing.
func _pump_permission_prompt() -> void:
	if permission_flow == null or ui_root == null or _title_up:
		return
	if _restore_cursor != null or _catchup_cursor != null or ui_root.veil_open():
		return
	if not permission_flow.should_prompt():
		return
	if ui_root.modal_open():
		return
	ui_root.present_permission_rationale(permission_flow.request_rationale())


func _on_permission_answered(accepted: bool) -> void:
	if permission_flow == null:
		return
	# Step 4 opens the system dialog and the answer comes back on
	# `permission_result`; step 5 records the refusal here and now. Both spend a
	# chance, and both are written to the device file immediately — a counter
	# that only reached disk at the next autosave would let a process death hand
	# the player a third prompt Android will not honour.
	if accepted:
		permission_flow.accept()
	else:
		permission_flow.decline()
	permission_flow.save_device()
	_refresh_permission_row()


func _on_permission_state_changed(_state: String) -> void:
	_refresh_permission_row()


func _refresh_permission_row() -> void:
	if ui_root != null and permission_flow != null:
		ui_root.set_permission_state(permission_flow.settings_row_state())


func _on_ui_setting_action(key: StringName, _action: StringName) -> void:
	if String(key) == UIRoot.PERMISSION_ROW:
		_on_permission_row_tapped()


## Doc 13 §2.7 step 6, plus the state the step does not name. The row offers the
## one action that is legal in each state and nothing else — a row that is
## tappable and does nothing is the control §2.13 forbids.
func _on_permission_row_tapped() -> void:
	if permission_flow == null or ui_root == null:
		return
	match permission_flow.settings_row_state():
		"off":
			# The player asked for it, so the flow's own "not yet" does not
			# apply — this is the one place both of `should_prompt`'s gates (the
			# trigger, and once-a-session) are bypassed. Everything downstream is
			# unchanged: NOT NOW still spends one of Android's two chances, BACK
			# still spends none, and `accept()` still returns false on a platform
			# that has none left to spend.
			permission_flow.note_trigger()
			ui_root.present_permission_rationale(PermissionSheet.REASON_FIRST)
		"blocked":
			# Android has stopped showing the dialog. The app's own page in
			# system settings is the only route left, and saying so is the whole
			# of what this row can honestly offer.
			permission_flow.open_system_settings()
		_:
			# `on` and `unavailable`: nothing to do, and the row's value text
			# already says which of the two it is.
			pass


func _on_ui_save_loaded(_slot: int) -> void:
	# The sim was replaced in place; re-seed EVERYTHING that cached from it —
	# and don't carry the old city's thunder into the new one.
	if audio != null:
		audio.reset()
	_resync_world_views()
	if ui_root != null:
		ui_root.restore_ui_state(save_service.last_loaded_ui)
		# The preset is part of the city (doc 08 §2.8 v6), so a loaded city can
		# carry a different one than the process booted on.
		ui_root.set_city_difficulty(sim_host.sim.difficulty_preset())
	_refresh_hud()


func _on_title_continue(slot: int) -> void:
	if _restore_cursor != null:
		return   # a second press while the first load is still stepping
	var target := slot if slot >= 0 else save_service.latest_slot()
	if target < 0:
		_refuse_title_continue()
		return
	_begin_restore(target)


## One step per frame, behind S15 (doc 12 §2.20, doc 13 §2.9.1). The title door
## used to stand in for the veil; there is a real one now, and it covers the
## paths the door never could — a resume, and any load with no door up.
func _begin_restore(target: int) -> void:
	_restore_slot = target
	_restore_cursor = save_service.begin_load_slot(sim_host.sim, target)
	ui_root.present_veil_load(ui_root.slot_title(target),
			_restore_cursor.step_count())


## Runs INSTEAD of the rest of `_process` while a load is in flight.
func _advance_restore() -> void:
	if not save_service.step_load(_restore_cursor):
		ui_root.advance_veil_load(_restore_cursor.completed())
		return
	ui_root.advance_veil_load(_restore_cursor.step_count())
	_restore_cursor = null
	if not save_service.last_load_ok:
		# Exactly the old fallback: the named slot, then the newest other one.
		var fallback := save_service.latest_slot()
		if fallback >= 0 and fallback != _restore_slot:
			_begin_restore(fallback)
			return
		_refuse_title_continue()
		return
	_resumed_slot = _restore_slot
	_on_ui_save_loaded(_restore_slot)
	ui_root.set_city_level(sim_host.sim.progression.city_level)
	ui_root.dismiss_title()
	ui_root.dismiss_veil()
	sim_host.paused = false
	_title_up = false
	if android_lifecycle != null:
		android_lifecycle.save_enabled = true
		# The door's CONTINUE is a cold launch too, and it is the DEFAULT one
		# (doc 12 §2.19) — the same absence is owed (RR-132). Spent on THIS
		# frame, before `SimHost` (this node's child, and so processed after it)
		# can put a live tick into a city that has not caught up yet.
		if android_lifecycle.arm_cold_resume(save_service):
			android_lifecycle.pump_resume()


func _refuse_title_continue() -> void:
	_restore_cursor = null
	_restore_slot = -1
	ui_root.dismiss_veil()   # a refused load must not leave the veil up
	ui_root.push_toast(UIWidgets.t(ui_root.config, "ui_saves_failed"),
			HudModel.STATE_CRITICAL)
	ui_root.refresh_title()   # the door survives a corrupt save


func _on_title_new_game(slot: int, difficulty: String) -> void:
	# Doc 03 §2.9 / doc 93 §K1: the preset is chosen ONCE, here, and the window
	# closes at the founding tick — `found_with_difficulty` refuses after
	# `tick_index == 0`. It runs BEFORE the capture below, because that capture
	# is what a KEEP round trip restores.
	sim_host.sim.found_with_difficulty(difficulty)
	# `slot` is where the OLD city goes (the door's replace/archive ruling), or
	# -1 when there is nothing worth keeping.
	if slot >= 0:
		var founding: Dictionary = sim_host.sim.canonical_capture()
		var from := save_service.latest_slot()
		if from >= 0 and save_service.load_slot(sim_host.sim, from):
			save_service.save_slot(sim_host.sim, slot)
		sim_host.sim.restore_state(founding)
		_resync_world_views()
	_resumed_slot = -1
	ui_root.dismiss_title()
	sim_host.paused = false
	_title_up = false
	if android_lifecycle != null:
		android_lifecycle.save_enabled = true
	# PA-15: the door hands a NEW city a clean `ui` section — the overlay choice,
	# the street tally and the city-scoped settings rows all go back to their
	# data defaults, because they belonged to the city that just left. The
	# device-scoped rows do not move: `SettingsModel.restore_state` re-applies
	# `user://settings.cfg` last, so a player who turned notifications off does
	# not get them back by founding a city (doc 08 §2.13.4).
	ui_root.reset_ui_state_for_new_city()
	ui_root.start_onboarding({
		"tutorial_lot_a": sim_host.sim.loader.resolve_tag("tutorial_lot_a")["tile_global"],
		"tutorial_lot_b": sim_host.sim.loader.resolve_tag("tutorial_lot_b")["tile_global"]})
	save_service.autosave(sim_host.sim)   # stake the rotation for the new city


## Re-read the road layer and rewrite the street surface — fired on
## `road_graph_changed` / `block_roads_stamped` and after a mid-session load.
## The view guards itself on `RoadGraph.graph_version`, so the two events one
## player edit fires cost ONE pass. Streetlights are not re-placed here (they
## are boot-time, as they always were — doc 11 §2.10.1's open item).
func _rebuild_road_multimesh() -> void:
	if road_surface == null:
		return
	var graph: RoadGraph = sim_host.sim.roads.graph if sim_host.sim.roads != null else null
	road_surface.rebuild(sim_host.sim.world.grid, graph)
	# The lamps follow the asphalt on the SAME frame (doc 11 §2.10.1). The
	# re-place is a set difference on the placement key, so a lamp that did not
	# move keeps its id, its `anim_phase` and whatever ramp it is in.
	if streetlights != null:
		streetlights.replace_from(sim_host.sim.world.grid, graph,
				sim_host.sim.world.block_of_tile)
	# A street laid across a low block is a street that can now flood.
	if flood_view != null:
		flood_view.rebuild(sim_host.sim.world.grid)


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
	if construction_plant != null:
		construction_plant.clear()
		construction_plant.set_road_network(sim.roads)
	if construction_view != null:
		construction_view.clear()
		for sim_id: String in sim.buildings:
			if (sim.buildings[sim_id] as Building).state == &"under_construction":
				_add_construction_site(String(sim_id))
	# `true`: a loaded save swaps the CitySim for a fresh object whose graph's
	# `graph_version` could collide with the old one's — force the repack.
	if road_surface != null:
		road_surface.rebuild(sim.world.grid,
				sim.roads.graph if sim.roads != null else null, true)
	# The vehicle layer keys off a live event stream; the cheapest correct
	# resync is a fresh view (its whole state rebuilds within a game-minute).
	if vehicle_view != null:
		vehicle_view.queue_free()
		vehicle_view = VehicleView.new()
		vehicle_view.name = "Vehicles"
		add_child(vehicle_view)
		vehicle_view.setup(_render_data)
	# doc 11 §2.10b: a loaded save is a different grid. One flag; the rebuild
	# lands on the next frame's `sync`.
	if power_infra != null:
		power_infra.note_topology_changed()
	# A loaded save is a different city, and the lamps were never resynced:
	# `apply_lamps` is a set difference, so this retires the city that is gone
	# and lights the one that arrived in one pass.
	if streetlights != null:
		streetlights.replace_from(sim.world.grid,
				sim.roads.graph if sim.roads != null else null,
				sim.world.block_of_tile)
	# A loaded save is a different flood field. `prime` takes doc 07's own
	# persisted depths; `snap` puts the water at its real level on the first
	# frame instead of rising into it.
	if flood_view != null:
		flood_view.rebuild(sim.world.grid)
		flood_view.prime(sim.weather.flood.depth_mm)
		flood_view.snap()
	# doc 11 §2.17b: a loaded save restores the sim's opportunity roster in
	# SILENCE — there is no `opportunity_spawned` for a row that was already on
	# the books — so a crook the player was walking toward is live, tappable,
	# paying and INVISIBLE until it expires. `born_gm` on each row puts every
	# body back MID-WANDER rather than on its first waypoint (report 98 RR-93).
	if street_life != null:
		street_life.seed_roster(sim.street.live())


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


## A notification tap (doc 13 §2.5): route its payload to the thing it was
## about. Payload forms: `incident/42`, `building/B-7`, `overlay/power`, `report`.
func _on_notification_opened(payload: String) -> void:
	if payload.begins_with("overlay/"):
		_on_ui_deeplink(payload)
	elif payload.begins_with("incident/") and ui_root != null:
		if ui_root.incident_drawer != null:
			ui_root.incident_drawer.open()
	elif payload.begins_with("building/"):
		var pos: Variant = _alert_world_pos(&"building", payload.trim_prefix("building/"))
		if pos is Vector3:
			camera_state.focus_on(pos)
	elif payload == "report" and ui_root != null and ui_root.away_report != null:
		ui_root.away_report.open()


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


func _on_app_paused(saved: bool) -> void:
	# The pause save committed the city, so a kill from here on is a CLEAN exit
	# (doc 13 §2.11 — the flag comes back down in `_on_app_resumed`). Without
	# this, every launch ever made was "unclean" and the recovery path was the
	# only door into the game.
	if saved and crash_sentinel != null:
		crash_sentinel.mark_clean_exit()
	# RR-134: mid-catch-up the 'before' is already in flight and the city under
	# it is a MID-absence one. Overwriting the snapshot here is what made the
	# away report diff the city against a half-advanced version of itself.
	if _catchup_cursor != null:
		return
	_before_snapshot = _snapshot_city(sim_host.sim)


## The five figures the WHILE YOU WERE AWAY report diffs (doc 12 §2.12).
func _snapshot_city(sim: CitySim) -> Dictionary:
	return {"treasury": sim.treasury.balance,
			"population": sim.population.city_population,
			"day_index": sim.clock.day_index(),
			"stability": sim.districts.city_stability,
			"happiness": sim.happiness.happiness}


## doc 13 §2.3: the shell measures, the sim decides. The catch-up SHAPE is
## CatchUpPlanner's (doc 01) — the naive fine-then-coarse split violated
## `advance_coarse_n`'s hour-alignment contract on 239 of 240 tick offsets
## (doc 91 D-1); the planner emits segments that always land on boundaries.
func _on_app_resumed(elapsed_wall_s: float) -> void:
	if crash_sentinel != null:
		crash_sentinel.arm()
	if _title_up or _restore_cursor != null:
		return   # the title door is up, or a load already owns the frame
	# A SECOND absence on top of an unfinished one — the player backgrounded the
	# app while the catch-up veil was still up. RR-134: QUEUE it. Draining the
	# old cursor here ran up to 720 coarse steps in ONE frame (119 s on the
	# benchmark city — an ANR twenty-four times over) and planned the second
	# absence against a clock the first plan had not finished moving.
	if _catchup_cursor != null:
		if android_lifecycle != null:
			android_lifecycle.defer_absence(elapsed_wall_s)
		return
	var sim := sim_host.sim
	# The unspent tail of a plan a process death interrupted, when this is the
	# cold launch that inherited one (RR-134). `{}` on every warm resume.
	var unfinished: Dictionary = {}
	if android_lifecycle != null:
		unfinished = android_lifecycle.take_unfinished_catchup()
	# The report's 'before' is the PRE-absence city. A warm resume captured it at
	# the pause; a cold launch either finds it in the stamp or takes the city
	# that just came off the disk, which IS the city the player left.
	if _before_snapshot.is_empty():
		var carried: Dictionary = unfinished.get("before", {})
		_before_snapshot = carried if not carried.is_empty() else _snapshot_city(sim)
	var plan: Dictionary = CatchUpPlanner.plan_after(unfinished,
			int(elapsed_wall_s * 1000.0),
			sim.clock.residual_game_ms, sim.clock.tick_index)
	# S15's catch-up phase (doc 13 §2.9, report 98 §29 RR-73). One slice per
	# frame through `CatchUpCursor`, so the veil draws for the whole absence.
	var total_ticks := int(plan.get("total_ticks", 0))
	var cap_game_hours := int(plan.get("cap_game_hours", 720))
	if ui_root != null:
		# 60 game-hours is one real hour, and the veil line promises REAL time
		# (doc 08 §2.12 / RR-133 — the cap stopped being 12 h this wave).
		ui_root.present_veil_catchup(total_ticks / GameClock.TICKS_PER_HOUR,
				total_ticks, bool(plan.get("capped", false)), cap_game_hours / 60)
	# THE PAUSE IS LOAD-BEARING: unpaused, `SimHost._process` would add live
	# fine ticks BETWEEN the plan's slices and the sliced resume would land on
	# a different city from the synchronous one.
	_catchup_was_paused = sim_host.paused
	sim_host.paused = true
	_catchup_after = {
		"elapsed_wall_s": elapsed_wall_s + float(unfinished.get("elapsed_wall_s", 0.0)),
		"residual_game_ms": int(plan.get("new_residual_game_ms", 0)),
		"capped": bool(plan.get("capped", false)),
		"cap_game_hours": float(cap_game_hours),
	}
	_catchup_cursor = sim.begin_catchup(plan)
	_advance_catchup()   # spend the first slice on THIS frame, as the loop did


## The unspent tail of the catch-up in flight, in `CatchUpPlanner.plan`'s own
## segment shape, or `{}` — doc 13 §3.2's `last_pause.unfinished` (RR-134). The
## pre-absence snapshot rides with it so a relaunch can still report against the
## city the player actually left.
func _catchup_remainder() -> Dictionary:
	if _catchup_cursor == null:
		return {}
	var rest := _catchup_cursor.remaining_plan()
	if int(rest.get("total_ticks", 0)) <= 0:
		return {}
	rest["new_residual_game_ms"] = int(_catchup_after.get("residual_game_ms", 0))
	rest["elapsed_wall_s"] = float(_catchup_after.get("elapsed_wall_s", 0.0))
	if not _before_snapshot.is_empty():
		rest["before"] = _before_snapshot.duplicate()
	return rest


## Runs INSTEAD of the rest of `_process` while a catch-up is in flight. Whole
## units against a wall-clock budget: the sim owns the unit, the shell owns the
## budget (doc 13 §2.9, `CatchUpCursor`'s own class doc).
func _advance_catchup() -> void:
	var started := Time.get_ticks_usec()
	var done := false
	while not done:
		done = _catchup_cursor.step()
		if Time.get_ticks_usec() - started >= CATCHUP_SLICE_USEC:
			break
	if ui_root != null:
		ui_root.advance_veil_catchup(_catchup_cursor.done_ticks())
	if done:
		_finish_catchup()


## Everything the synchronous loop did AFTER it: the residual the planner left,
## the offline event batch (which is what puts buildings finished offline into
## the world — `_on_sim_batch` is the only door), and the away report.
func _finish_catchup() -> void:
	var sim := sim_host.sim
	_catchup_cursor = null
	sim_host.paused = _catchup_was_paused
	if ui_root != null:
		ui_root.dismiss_veil()
	sim.clock.residual_game_ms = int(_catchup_after.get("residual_game_ms", 0))
	var offline_batch: Array = sim.bus.drain()
	_on_sim_batch(offline_batch)
	var elapsed_wall_s := float(_catchup_after.get("elapsed_wall_s", 0.0))
	var capped := bool(_catchup_after.get("capped", false))
	var cap_game_hours := float(_catchup_after.get("cap_game_hours", 720.0))
	_catchup_after = {}
	# The 'before' belongs to the absence that just finished. A QUEUED second
	# absence (RR-134) gets its own, captured in `_on_app_resumed` from the city
	# this catch-up left behind — which is exactly the city it was then away
	# from. Clearing it here is what makes that true.
	var before := _before_snapshot
	_before_snapshot = {}
	if ui_root == null or before.is_empty() or elapsed_wall_s < 60.0:
		return
	var toast := ui_root.present_away_report({
		"elapsed_wall_s": elapsed_wall_s,
		"elapsed_game_minutes": elapsed_wall_s,      # 1 real s = 1 game min at 1x
		"before": before,
		"after": _snapshot_city(sim),
		# Doc 08 §2.12: "the report says so (`catchup_capped`)". Until this wave
		# the dictionary carried no `capped` key at all, so `AwayModel`'s
		# `capped_text` branch could never fire (doc 12 D-77).
		"capped": capped,
		"cap_game_hours": cap_game_hours,
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
	# doc 12 §2.7: the run ghost. `BuildSheet.path_ghost()` answers
	# `{visible: false}` whenever no run tool is up.
	if path_ghost_view != null and build_sheet != null:
		path_ghost_view.apply(build_sheet.path_ghost())
	if ui_root != null:
		# ONE question about placement, for both tools — without this the back
		# stack has no `cancel_placement` rung while a run is being drawn.
		ui_root.placement_active = build_sheet.is_placing() if build_sheet != null \
				else (build_controller != null and build_controller.is_placing())


## `TouchInput.world_drag_router`: hand a single-finger stroke to the build
## sheet's run tool, or decline and let the camera have it.
func _route_world_drag(phase: StringName, position: Vector2) -> bool:
	if build_sheet == null or camera_state == null:
		return false
	var answer := camera_state.ground_hit(position,
			Vector2(get_viewport().get_visible_rect().size))
	var ground: Vector3 = answer["position"]
	var on_ground := bool(answer["hit"])
	match phase:
		TouchInput.PHASE_BEGIN:
			return on_ground and build_sheet.begin_world_drag(ground)
		TouchInput.PHASE_UPDATE:
			return build_sheet.update_world_drag(ground) if on_ground \
					else build_sheet.is_drag_drawing()
		TouchInput.PHASE_END:
			return build_sheet.end_world_drag()
	return false


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


## §2.9 item 6's repair / priority: the city moved, so the chips do.
func _on_building_action(_result: Dictionary) -> void:
	_refresh_hud()


## A demolition takes the building out of the world as well as out of the sim.
## The renderer is told by `building_removed` on the bus; this only has to drop
## the selection and re-read the chips.
func _on_building_demolished(_sim_id: String, result: Dictionary) -> void:
	if bool(result.get("ok", false)) and ui_root != null:
		ui_root.selected_entity_id = ""
	_refresh_hud()


## A block was bought or entered development — the city just grew.
func _on_land_changed(_block_id: String, _result: Dictionary) -> void:
	_refresh_hud()


## §2.7's `Fix this →`: focus the blocking entity. `FIX_POWER` and `FIX_REPAIR`
## never reach here — the building panel performs both in place, because their
## target is the building the player already has open (A91-D-54). Of the kinds
## that do, only a block and a building resolve to a placed entity today (docs
## 05/06/10 own the rest), so anything else is a no-op rather than a camera jump
## to nowhere.
func _on_fix_requested(fix_target: Dictionary) -> void:
	var id := str(fix_target.get("id", ""))
	if id == "" or build_controller == null:
		return
	if StringName(str(fix_target.get("kind", ""))) == RequirementFormatter.FIX_BLOCK:
		var block: LandBlock = sim_host.sim.world.block(id)
		if block == null:
			return
		var centre: Vector2i = block.grid * TileGrid.TILES_PER_BLOCK \
				+ Vector2i(TileGrid.TILES_PER_BLOCK / 2, TileGrid.TILES_PER_BLOCK / 2)
		camera_state.focus_on(Vector3(float(centre.x) * build_controller.tile_m, 0.0,
				float(centre.y) * build_controller.tile_m))
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
	var answer := camera_state.ground_hit(screen_pos, viewport_size)
	var ground: Vector3 = answer["position"]
	var on_ground := bool(answer["hit"])
	if build_sheet != null and build_sheet.is_placing():
		if on_ground:
			build_sheet.move_ghost(ground)
		return
	if build_sheet != null and build_sheet.is_open():
		# A tap that reached the world missed every sheet control: dismiss.
		build_sheet.close()
		return
	if not on_ground:
		# Not a pick, and not a deselect either: the selection survives a tap on
		# the sky, because the player did not touch anything to change it.
		return
	# doc 12 §2.8: one pick, three answers, decided in the controller so the two
	# panels can never both claim a tap. `""` used to mean "deselect", which is
	# the mechanical reason land was unreachable.
	# Wave 14 (doc 12 §2.21 / D-61): 48 dp of finger, in metres, AT THIS ZOOM,
	# before the pick — a tap near a street collectable has to catch it rather
	# than the house it is standing in front of.
	build_controller.set_tap_radius_from(camera_state.m_per_dp(viewport_size))
	var pick := build_controller.pick_at_ground(ground)
	if StringName(str(pick["kind"])) == BuildController.PICK_OPPORTUNITY:
		var collected := build_controller.collect_opportunity(str(pick["id"]))
		var payday: Dictionary = ui_root.report_collect(collected,
				pick.get("opportunity", {}) as Dictionary) if ui_root != null else {}
		# `payday["cue"]`, not `collected["ok"]`: a build whose sim has no
		# collect verb refuses E_NO_COMMAND, and the honest sound for a feature
		# that is not there is silence, not a buzz.
		if bool(payday.get("cue", false)) and audio != null:
			audio.ui_cue(AudioService.UI_CASH)
		return
	if StringName(str(pick["kind"])) == BuildController.PICK_BUILDING \
			and building_panel != null:
		building_panel.show_building(str(pick["id"]))   # closes S4 (doc 12 D-27)
		if ui_root != null:
			ui_root.selected_entity_id = str(pick["id"])
		return
	if StringName(str(pick["kind"])) == BuildController.PICK_BLOCK \
			and ui_root != null and ui_root.show_land_block(str(pick["id"])):
		if building_panel != null:
			building_panel.close()
		ui_root.selected_entity_id = ""
		return
	if building_panel != null:
		building_panel.close()
	if ui_root != null:
		ui_root.close_land_panel()
		ui_root.selected_entity_id = ""


func _on_touch_tapped(position: Vector2) -> void:
	_handle_tap(position, Vector2(get_viewport().get_visible_rect().size))


func _on_hud_speed_selected(multiplier: int) -> void:
	sim_host.speed = multiplier
	sim_host.paused = false


func _on_hud_pause_toggled(paused: bool) -> void:
	sim_host.paused = paused


func _process(delta: float) -> void:
	# A restore in flight owns the frame: the sim is half-rebuilt at every step
	# boundary. `sim_host.paused` is already true (the door set it), so no tick
	# can land in a seam either.
	if _restore_cursor != null:
		_advance_restore()
		return
	# A catch-up in flight owns the frame for the same reason a restore does,
	# with one extra: `SimHost.paused` is set below, so no LIVE tick and no
	# residual accumulation can interleave with the plan.
	if _catchup_cursor != null:
		_advance_catchup()
		# A QUEUED absence starts on the SAME frame the one in front of it
		# finished, so no live tick can land between two absences (RR-134).
		if _catchup_cursor == null and android_lifecycle != null and not _title_up:
			android_lifecycle.pump_resume()
		return
	# Doc 08's Core Rule 2 on a COLD launch, and the second absence a background
	# mid-veil left behind: both arrive here, on a frame with no cursor in
	# flight, through the ONE path that owns catch-up (report 98 §48, RR-132 /
	# RR-134). `Main` is `SimHost`'s parent and so processes before it.
	if android_lifecycle != null and not _title_up:
		android_lifecycle.pump_resume()
	# PA-14, doc 13 §2.7 step 3: "next idle frame". Everything that owns a frame
	# has already returned above, so reaching this line IS the definition of idle
	# — and `should_prompt()` answers false for every reason it possibly can.
	_pump_permission_prompt()
	var hour := sim_host.hour_of_day_float()
	_hud_timer += delta
	if _hud_timer >= HUD_REFRESH_S:
		_hud_timer = 0.0
		_refresh_hud()
	if weather_fx != null:
		weather_fx.refresh(delta, camera_state.focus)
	if flood_view != null:
		flood_view.refresh(delta)
	environment_controller.apply(hour, delta)
	city_view.refresh(delta, hour, camera_rig.camera.global_position)
	if construction_view != null:
		construction_view.refresh(delta, environment_controller.last_night)
	# doc 11 §2.16. `gm_per_s` is the sim speed — 0 while paused, which parks
	# every lorry exactly where it stands. `game_minutes` pins the layer to the
	# save's own clock, so a load or a catch-up puts it where the save says.
	if construction_plant != null:
		construction_plant.set_focus(camera_state.focus)
		construction_plant.refresh(delta, environment_controller.last_night,
				0.0 if sim_host.paused else float(sim_host.speed),
				float(sim_host.sim.clock.game_seconds()) / 60.0)
	# doc 11 §2.17. Same two arguments the plant takes and for the same reasons,
	# plus the CAMERA position — the marker's angular size and the distance gate
	# are both computed from it.
	if street_life != null:
		street_life.refresh(delta, environment_controller.last_night,
				0.0 if sim_host.paused else float(sim_host.speed),
				float(sim_host.sim.clock.game_seconds()) / 60.0,
				camera_rig.camera.global_position)
	if power_infra != null:
		# One call: it owns its own poll schedules (state 4 Hz, topology 0.2 Hz
		# plus the event hook above) and its own wire gating off the camera.
		power_infra.sync(sim_host.sim, delta, camera_rig.camera.global_position)
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
	if perf_governor != null:
		perf_governor.submit_frame(delta * 1000.0)
		if perf_telemetry != null:
			perf_telemetry.tick(delta, perf_governor)
		if perf_governor.update(delta):
			var knobs := perf_governor.knobs()
			city_view.apply_governor(knobs)
			# §2.13b rungs 1 and 4: render_scale -> the viewport, street_lights
			# -> StreetlightView. Both were computed and applied nowhere.
			_apply_quality(String(knobs["preset"]))
			if power_infra != null:
				power_infra.apply_governor(knobs)   # `particle_ratio` only
			_apply_frame_cap(perf_governor.target_fps())          # doc 13 §2.8 / RR-126
			if String(knobs["preset"]) != render_model.preset:   # a latched drop
				render_model.set_preset(String(knobs["preset"]))
				vehicle_view.set_preset(String(knobs["preset"]), _render_data)
				if construction_plant != null:
					construction_plant.set_preset(String(knobs["preset"]), _render_data)
				if road_surface != null:
					road_surface.set_preset(String(knobs["preset"]), _render_data)
				if flood_view != null:
					flood_view.set_preset(String(knobs["preset"]), _render_data)
				if street_life != null:
					street_life.set_preset(String(knobs["preset"]), _render_data)
			if audio != null:
				audio.feed_batch(perf_governor.drain_events())   # telemetry cue
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
			if crash_sentinel != null:
				crash_sentinel.mark_clean_exit()  # dev exits are not crashes
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
				# §2.7: a stroke that was drawing a run ends without committing.
				if build_sheet != null and build_sheet.is_drag_drawing():
					build_sheet.end_world_drag()
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
			# §2.7: while a run tool is up the drag DRAWS. Anchored on the press
			# point, so the run starts under the finger.
			if build_sheet != null and build_sheet.is_placing_path():
				var from_hit := camera_state.ground_hit(_tap_origin, viewport_size)
				var at_hit := camera_state.ground_hit(motion.position, viewport_size)
				if bool(from_hit["hit"]) and bool(at_hit["hit"]):
					if not build_sheet.is_drag_drawing():
						build_sheet.begin_world_drag(from_hit["position"])
					build_sheet.update_world_drag(at_hit["position"])
			else:
				camera_state.update_pan(motion.position, viewport_size,
						get_process_delta_time())
		elif build_sheet != null and build_sheet.is_placing():
			# Hover keeps the ghost under the pointer; the verdict is recomputed
			# on every move (§2.7) and only PLACE ever commits it.
			var hover := camera_state.ground_hit(motion.position, viewport_size)
			if bool(hover["hit"]):
				build_sheet.move_ghost(hover["position"])
