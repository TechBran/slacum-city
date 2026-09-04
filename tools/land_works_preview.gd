extends SceneTree
## Eye-level shots of ONE developing block, one per phase (doc 11 §2.18) — so
## the story `LandWorksView` tells can be judged instead of asserted.
##
## `tools/construction_preview.gd` does this for a BUILDING site and this is its
## sibling for a LAND BLOCK: same stack minus the building, same camera rule
## (stand on the block's own frontage and look back at the work), and the same
## reason for existing. `tests/test_land_works_view.gd` holds the counts; only a
## picture can hold whether a graded plane with three spoil heaps on it reads as
## ground being worked.
##
## It builds the layers `game/main.gd` builds — the ground planes, the
## `LandWorksView` dressing, and `ConstructionVehicleView` on top so the
## excavator and the tipper the phase called for are in frame — because the
## thing being judged is the WHOLE picture. It owns no constant, reads
## `data/render.json` for everything, and nothing in `sim/`, `game/` or `ui/`
## imports it.
##
## Usage (needs a display — this renders):
##   ~/.local/bin/godot --path "/home/bbx/Slacum City game" \
##       -s res://tools/land_works_preview.gd -- --out=DIR [options]
##
##   --out=DIR          where the PNGs go (one per phase, `<phase>.png`)
##   --phases=1,3,5     which phases, 1-based in doc 09 §2.3 order (default all)
##   --progress=P       how far into each phase, 0..1              (default 0.55)
##   --hour=H           hour of day, 0..24                         (default 13)
##   --gm=M             game-minute the plant layer is wound to    (default auto)
##   --resolution=WxH   render size                        (default 1600x900)
##   --dist=M           camera distance from the work zone        (default 150)
##   --height=M         camera height                              (default 88)
##   --swing=D          camera yaw off the frontage normal, deg    (default 30)
##   --census           print the per-phase draw-call and instance table too

const RENDER_JSON := "res://data/render.json"
const TILE_M := 8.0
const PHASES: Array[StringName] = [
	&"SURVEY", &"CLEARING", &"GRADING", &"ROAD_INSTALL",
	&"UTILITY_CORRIDOR", &"FINAL_DEVELOPMENT",
]

var _opts: Dictionary = {}
var _render_data: Dictionary = {}
var _sim: CitySim
var _works: LandWorksView
var _plant: ConstructionVehicleView
var _env: EnvironmentController
var _camera: Camera3D

var _block_id := ""
var _centre := Vector3.ZERO
var _shots: Array = []
var _shot_index := 0
var _settle := 0
var _started := false


func _initialize() -> void:
	_opts = _parse(OS.get_cmdline_user_args())
	if String(_opts["out"]) == "":
		printerr("land_works_preview: --out=DIR is required")
		quit(2)
		return
	_render_data = StarterCityLoader.read_json(RENDER_JSON)
	_sim = CitySim.boot_from_files()
	if not _sim.boot_errors.is_empty():
		printerr("land_works_preview: " + str(_sim.boot_errors))
		quit(2)
		return
	_sim.treasury.balance = 50_000_000
	var size: Vector2i = _opts["resolution"]
	root.size = size
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DirAccess.make_dir_recursive_absolute(String(_opts["out"]))


func _process(delta: float) -> bool:
	if not _started:
		_build()
		_plan()
		_started = true
		return false
	if _shot_index >= _shots.size():
		print("land_works_preview: wrote %d shots to %s"
				% [_shots.size(), String(_opts["out"])])
		return true
	var shot: Dictionary = _shots[_shot_index]
	var phase: StringName = shot["phase"]
	_works.feed_events([{"type": &"development_phase_started",
			"block": _block_id, "phase": phase}])
	# The harness sets progress directly: a real pipeline never sits still on
	# 0.55, and a phase photographed at whatever the clock happened to reach
	# would be a picture of the harness rather than of the phase.
	_works._sites[_block_id].progress = float(_opts["progress"])
	_works._dirty = true
	_plant.set_game_minutes(float(shot["gm"]))
	var hour := float(_opts["hour"])
	_env.apply(hour, delta)
	_works.set_focus(_centre)
	_works.refresh(delta, _env.last_night)
	_plant.set_focus(_centre)
	_plant.refresh(delta, _env.last_night, 0.0)
	_settle += 1
	if _settle < 8:
		return false
	_settle = 0
	if bool(_opts["census"]):
		var census := _works.census()
		var keys: Array = census.keys()
		keys.sort()
		var parts: Array[String] = []
		for key: String in keys:
			parts.append("%s %d" % [key, int(census[key])])
		print("%-18s calls %d  %s" % [phase, _works.active_buffers(),
				", ".join(PackedStringArray(parts))])
	var image := root.get_texture().get_image()
	if image != null:
		image.save_png(String(shot["path"]))
		print("wrote " + String(shot["path"]))
	_shot_index += 1
	return false


func _plan() -> void:
	var dir := String(_opts["out"])
	var fixed: float = float(_opts["gm"])
	var site: ConstructionActivity.Site = _plant.activity.sites.get(
			LandWorksView.plant_id_of(_block_id))
	var period := site.period_gm if site != null else 46.0
	var leg := _plant.activity.leg_gm(site) if site != null else 8.0
	for index in (_opts["phases"] as Array):
		var i := int(index)
		if i < 0 or i >= PHASES.size():
			continue
		var gm := fixed
		if gm < 0.0:
			# Mid-DUMP, a few deliveries in, so the beat the plant layer exists
			# for is in frame rather than an empty street.
			gm = site.offset_gm + period * (5.0 * float(i + 1)) + leg \
					+ _plant.activity.dump_gm * 0.45 if site != null else 0.0
		_shots.append({"phase": PHASES[i], "gm": gm,
				"path": dir.path_join("%s.png" % String(PHASES[i]).to_lower())})


func _build() -> void:
	var stage_root := Node3D.new()
	stage_root.name = "PreviewStage"
	root.add_child(stage_root)

	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	world_environment.environment = environment
	stage_root.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 260.0
	stage_root.add_child(sun)
	var moon := DirectionalLight3D.new()
	moon.shadow_enabled = false
	stage_root.add_child(moon)
	_env = EnvironmentController.new()
	stage_root.add_child(_env)
	_env.world_environment_path = world_environment.get_path()
	_env.sun_path = sun.get_path()
	_env.moon_path = moon.get_path()
	_env.setup(_render_data)

	_pick_block()
	_build_ground(stage_root)

	_plant = ConstructionVehicleView.new()
	stage_root.add_child(_plant)
	_plant.setup(_render_data)
	_plant.set_road_network(_sim.roads)

	_works = LandWorksView.new()
	stage_root.add_child(_works)
	_works.setup(_render_data)
	_works.bind(_sim.world, _sim.development, _sim.construction)
	_works.set_plant(_plant)
	for _step in 8:
		_plant.refresh(0.0, 0.0, 0.0)

	_camera = Camera3D.new()
	_camera.fov = 40.0
	_camera.near = 0.5
	_camera.far = 2200.0
	stage_root.add_child(_camera)
	_aim()


## Stand off the block's own frontage, looking back across it. A block is 128 m
## across, so the pose is `construction_preview`'s at four times the distance.
func _aim() -> void:
	var swing := deg_to_rad(float(_opts["swing"]))
	var back := (Vector3(0.0, 0.0, -1.0) * cos(swing)
			+ Vector3(1.0, 0.0, 0.0) * sin(swing)).normalized()
	var eye := _centre + back * float(_opts["dist"]) \
			+ Vector3(0.0, float(_opts["height"]), 0.0)
	_camera.global_transform = Transform3D(Basis.IDENTITY, eye) \
			.looking_at(_centre, Vector3.UP)


## A block the player could actually buy next, taken through the real command so
## the pipeline it is photographed in is the one the game runs.
func _pick_block() -> void:
	for id: String in _sim.world.block_ids_sorted():
		if _sim.world.block(id).ownership_state != &"PURCHASABLE":
			continue
		if not bool(_sim.world.purchase_allowed(id, _sim.progression.city_level)["ok"]):
			continue
		_block_id = id
		break
	if _block_id == "":
		printerr("land_works_preview: the starter city has no purchasable block")
		quit(2)
		return
	_sim.cmd_buy_block(_block_id, false, true)
	var block := _sim.world.block(_block_id)
	_centre = Vector3((float(block.grid.x) * 16.0 + 8.0) * TILE_M, 0.0,
			(float(block.grid.y) * 16.0 + 8.0) * TILE_M)


func _build_ground(stage_root: Node3D) -> void:
	var ground := Node3D.new()
	ground.name = "Ground"
	stage_root.add_child(ground)
	var developed := GroundSurface.material("pavement", Vector2(128.0, 128.0),
			Color(0.52, 0.53, 0.52), 0.90)
	var undeveloped := GroundSurface.material("pavement", Vector2(128.0, 128.0),
			Color(0.40, 0.50, 0.36), 1.00)
	for block_id: String in _sim.world.block_ids_sorted():
		var block: LandBlock = _sim.world.block(block_id)
		var plane := MeshInstance3D.new()
		var mesh := PlaneMesh.new()
		mesh.size = Vector2(128.0, 128.0)
		plane.mesh = mesh
		plane.material_override = developed if block.is_ready() else undeveloped
		plane.position = Vector3(float(block.grid.x) * 128.0 + 64.0, 0.0,
				float(block.grid.y) * 128.0 + 64.0)
		ground.add_child(plane)


func _parse(args: PackedStringArray) -> Dictionary:
	var out := {"out": "", "progress": 0.55, "hour": 13.0, "gm": -1.0,
			"resolution": Vector2i(1600, 900), "dist": 150.0, "height": 88.0,
			"swing": 30.0, "census": false,
			"phases": [0, 1, 2, 3, 4, 5]}
	for raw: Variant in args:
		var arg := String(raw)
		if arg.begins_with("--out="):
			out["out"] = arg.substr(6)
		elif arg.begins_with("--progress="):
			out["progress"] = clampf(float(arg.substr(11)), 0.0, 1.0)
		elif arg.begins_with("--hour="):
			out["hour"] = float(arg.substr(7))
		elif arg.begins_with("--gm="):
			out["gm"] = float(arg.substr(5))
		elif arg.begins_with("--dist="):
			out["dist"] = float(arg.substr(7))
		elif arg.begins_with("--height="):
			out["height"] = float(arg.substr(9))
		elif arg.begins_with("--swing="):
			out["swing"] = float(arg.substr(8))
		elif arg == "--census":
			out["census"] = true
		elif arg.begins_with("--phases="):
			var picked: Array = []
			for part in arg.substr(9).split(",", false):
				picked.append(int(part) - 1)
			out["phases"] = picked
		elif arg.begins_with("--resolution="):
			var wh := arg.substr(13).split("x", false)
			if wh.size() == 2:
				out["resolution"] = Vector2i(int(wh[0]), int(wh[1]))
	return out
