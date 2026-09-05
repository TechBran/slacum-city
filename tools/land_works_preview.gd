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
## **WAVE 27 — THREE FRAMES, NOT ONE** (doc 11 §2.19). The player's whole point
## was that this layer read as a still, so one photograph per phase can no longer
## settle it. Every phase is now shot at THREE game-minutes from **the same
## camera** — `t`, `t + 15` and `t + 45` by default — and the work advances with
## the clock, exactly as it does in the running game: the first frame keeps
## Wave 25's filename (`<phase>.png`) and the other two are `<phase>_t15.png`
## and `<phase>_t45.png`. Put them side by side and the dozer is in a different
## strip, the brush behind it is gone, the paver has moved on and the strip
## behind it is longer. A verifier who cannot see motion in three stills should
## fail this lane, and these are the three stills.
##
## `--phase-gm` is the one HARNESS convention in the file. Doc 09 §2.3 prices a
## phase in crew-hours against the queue's crewing, so there is no single "a
## phase takes M minutes" to read out of the sim; 300 game-minutes is five game
## hours, the order of a real one, and it is used for nothing except deciding how
## far the WORK advances between the three frames.
##
## Usage (needs a display — this renders):
##   ~/.local/bin/godot --path "/home/bbx/Slacum City game" \
##       -s res://tools/land_works_preview.gd -- --out=DIR [options]
##
## And a SEVENTH subject, which is the other half of the player's sentence:
## `road_run_p15/50/85.png` are a run the harness lays through the real
## `CitySim.cmd_place_road` — an ordinary `road_crew` job with crew-hours, not a
## stamp — photographed at three points along its own progress, with the paver,
## the roller behind it and the barricade bays across the working end.
##
##   --out=DIR          where the PNGs go (`<phase>.png`, `<phase>_t15.png`, …)
##   --phases=1,3,5     which phases, 1-based in doc 09 §2.3 order (default all)
##   --frames=0,15,45   game-minute offsets photographed        (default 0,15,45)
##   --phase-gm=M       game-minutes a whole phase takes, for the
##                      progress advance between frames           (default 300)
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
## A pseudo-phase: the player's own road run, which is not on a block at all.
const ROAD_RUN := &"ROAD_RUN"
## Tiles the harness drags to make one, and the shortest run it will accept.
const RUN_TILES := 6
const RUN_MIN_TILES := 4

var _opts: Dictionary = {}
var _render_data: Dictionary = {}
var _sim: CitySim
var _works: LandWorksView
var _plant: ConstructionVehicleView
var _env: EnvironmentController
var _camera: Camera3D

var _block_id := ""
var _centre := Vector3.ZERO
var _run_job := 0
var _run_centre := Vector3.ZERO
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
	if phase == ROAD_RUN:
		return _shoot_road_run(delta, shot)
	_works.feed_events([{"type": &"development_phase_started",
			"block": _block_id, "phase": phase}])
	# The harness sets progress directly: a real pipeline never sits still on
	# 0.55, and a phase photographed at whatever the clock happened to reach
	# would be a picture of the harness rather than of the phase. The OFFSET is
	# what makes the three frames a proof rather than three copies — the clock
	# and the work advance together, which is what they do in the game.
	_works.force_progress(_block_id, float(shot["progress"]))
	_plant.set_game_minutes(float(shot["gm"]))
	_works.motion.set_game_minutes(float(shot["gm"]))
	var hour := float(_opts["hour"])
	_env.apply(hour, delta)
	_works.set_focus(_centre)
	# `gm_per_s = 0` and an explicit clock: the layer is PINNED to the game-minute
	# this frame is of, so eight settle frames of real time cannot drift it.
	_works.refresh(delta, _env.last_night, 0.0, float(shot["gm"]))
	_plant.set_focus(_centre)
	_plant.refresh(delta, _env.last_night, 0.0)
	_settle += 1
	if _settle < 8:
		return false
	_settle = 0
	if bool(_opts["census"]):
		var census := _works.census()
		var motion: Dictionary = census["motion"]
		var parts: Array[String] = []
		for key: String in ["stake", "brush", "graded", "spoil", "pave", "trench"]:
			parts.append("%s %d" % [key, int(census[key])])
		var machines: Array[String] = []
		for key: String in ["dozer", "excavator", "tipper", "paver", "roller",
				"crew", "barrier"]:
			if int(motion.get(key, 0)) > 0:
				machines.append("%s %d" % [key, int(motion[key])])
		print("%-18s t+%-3d calls %d (%d dress + %d motion)  %s | %s"
				% [phase, int(shot["offset"]), int(census["total_buffers"]),
				_works.active_buffers(), _works.motion.active_buffers(),
				", ".join(PackedStringArray(parts)),
				", ".join(PackedStringArray(machines))])
	var image := root.get_texture().get_image()
	if image != null:
		image.save_png(String(shot["path"]))
		print("wrote " + String(shot["path"]))
	_shot_index += 1
	return false


## **THE PLAYER'S OWN ROAD, being built** (doc 11 §2.19). Not a phase and not on
## a block: a run the harness lays through `CitySim.cmd_place_road`, which is an
## ordinary `road_crew` job with crew-hours, photographed at three points along
## its own progress. A paver, a roller and the barricade bays across the working
## end, on a corridor that really is under construction in the sim.
func _shoot_road_run(delta: float, shot: Dictionary) -> bool:
	_works.motion.motion.set_run(_run_job, [], float(shot["progress"]))
	_plant.set_game_minutes(float(shot["gm"]))
	_works.motion.set_game_minutes(float(shot["gm"]))
	_env.apply(float(_opts["hour"]), delta)
	_works.set_focus(_run_centre)
	_works.refresh(delta, _env.last_night, 0.0, float(shot["gm"]))
	_plant.set_focus(_run_centre)
	_plant.refresh(delta, _env.last_night, 0.0)
	_aim_at(_run_centre, 62.0, 30.0)
	_settle += 1
	if _settle < 8:
		return false
	_settle = 0
	if bool(_opts["census"]):
		var motion: Dictionary = _works.census()["motion"]
		print("%-18s p%.2f  calls %d motion  paver %d, roller %d, barrier %d, crew %d"
				% ["ROAD_RUN", float(shot["progress"]),
				_works.motion.active_buffers(), int(motion["paver"]),
				int(motion["roller"]), int(motion["barrier"]), int(motion["crew"])])
	var image := root.get_texture().get_image()
	if image != null:
		image.save_png(String(shot["path"]))
		print("wrote " + String(shot["path"]))
	_shot_index += 1
	# Put the camera back on the block for whatever comes next.
	_aim()
	return false


func _plan() -> void:
	var dir := String(_opts["out"])
	var fixed: float = float(_opts["gm"])
	var site: ConstructionActivity.Site = _plant.activity.sites.get(
			LandWorksView.plant_id_of(_block_id))
	var period := site.period_gm if site != null else 46.0
	var leg := _plant.activity.leg_gm(site) if site != null else 8.0
	var phase_gm := float(_opts["phase_gm"])
	var base := float(_opts["progress"])
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
		var name := String(PHASES[i]).to_lower()
		for offset: float in (_opts["frames"] as Array):
			# The first frame keeps Wave 25's filename, so the comparison a
			# reviewer already knows how to make still works; the others carry
			# the offset they were taken at.
			var file := "%s.png" % name if is_zero_approx(offset) \
					else "%s_t%d.png" % [name, int(offset)]
			_shots.append({"phase": PHASES[i], "gm": gm + offset,
					"offset": offset,
					"progress": clampf(base + offset / maxf(phase_gm, 1.0), 0.0, 1.0),
					"path": dir.path_join(file)})
	if _run_job > 0:
		for progress: float in [0.15, 0.50, 0.85]:
			_shots.append({"phase": ROAD_RUN, "gm": fixed if fixed >= 0.0 else 480.0,
					"offset": 0.0, "progress": progress,
					"path": dir.path_join("road_run_p%d.png" % int(progress * 100.0))})


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
	# **THE PIPELINE IS DELIBERATELY NOT BOUND**, and it is a fix rather than a
	# shortcut. `LandWorksView._poll` re-reads `DevelopmentController.active_view`
	# every `POLL_INTERVAL_S` and is the ONLY writer of a block's phase and
	# progress in a running city — which is correct there and fatal here, because
	# this harness is the writer instead. With the controller bound, the poll
	# fired every fifteenth frame, found a block the pipeline had not started a
	# job for yet, and put the site back to whatever the SIM said: the six
	# per-phase shots Wave 25 published were, intermittently, six photographs of
	# SURVEY. (Caught by diffing `survey.png` against `clearing.png` — two pixels
	# apart out of 921,600.) `_world` is still bound, because `_enter` needs it
	# to resolve a block id to a grid square.
	_works.bind(_sim.world, null, null)
	_works.set_plant(_plant)
	# Doc 11 §2.19's road-crew pass needs doc 10's live network and the queue to
	# find the tiles of an in-flight build. The queue is passed to THIS call and
	# not to `bind` above for one reason: `_enter_run` reads it and the phase poll
	# does not, and the poll is the thing that must stay off in this harness.
	_works.set_roads(_sim.roads)
	_lay_a_road()
	for _step in 16:
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
	_aim_at(_centre, float(_opts["dist"]), float(_opts["height"]))


func _aim_at(target: Vector3, dist: float, height: float) -> void:
	var swing := deg_to_rad(float(_opts["swing"]))
	var back := (Vector3(0.0, 0.0, -1.0) * cos(swing)
			+ Vector3(1.0, 0.0, 0.0) * sin(swing)).normalized()
	var eye := target + back * dist + Vector3(0.0, height, 0.0)
	_camera.global_transform = Transform3D(Basis.IDENTITY, eye) \
			.looking_at(target, Vector3.UP)


## **Lay a road the way the player does** — through `CitySim.cmd_place_road`,
## which is doc 10 §2.13's real job with real crew-hours, not a stamp. A short
## run out from an existing street, because doc 10 refuses one that touches
## nothing (`E_NOT_CONNECTED`). Silent if the starter city has nowhere to put
## one: the six phase shots are the point and this is the seventh.
func _lay_a_road() -> void:
	for t: Vector2i in _sim.roads.graph.road_tiles_sorted():
		for step: Vector2i in [Vector2i(0, 1), Vector2i(1, 0),
				Vector2i(0, -1), Vector2i(-1, 0)]:
			var run: Array = []
			for i in range(1, RUN_TILES + 1):
				var candidate := t + step * i
				if not bool(_sim.cmd_place_road([candidate],
						RoadTunables.CLASS_STREET, true)["ok"]):
					break
				run.append(candidate)
			if run.size() < RUN_MIN_TILES:
				continue
			var placed := _sim.cmd_place_road(run, RoadTunables.CLASS_STREET)
			if not bool(placed["ok"]):
				continue
			_run_job = int(placed["payload"]["job_id"])
			_works.feed_events(_sim.bus.drain())
			var mid: Vector2i = run[run.size() / 2]
			_run_centre = Vector3((float(mid.x) + 0.5) * TILE_M, 0.0,
					(float(mid.y) + 0.5) * TILE_M)
			print("land_works_preview: laid a %d-tile run at %s, job %d"
					% [run.size(), mid, _run_job])
			return


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
			"frames": [0.0, 15.0, 45.0] as Array, "phase_gm": 300.0,
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
		elif arg.begins_with("--frames="):
			var offs: Array = []
			for part in arg.substr(9).split(",", false):
				offs.append(float(part))
			out["frames"] = offs
		elif arg.begins_with("--phase-gm="):
			out["phase_gm"] = maxf(1.0, float(arg.substr(11)))
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
