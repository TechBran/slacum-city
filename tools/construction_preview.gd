extends SceneTree
## Eye-level screenshots of ONE construction site (doc 11 §2.16), so the story
## the layer tells can be judged instead of asserted.
##
## `tools/profile_frame.gd` answers "what does it cost?" from §2.5's three
## published camera poses. Those poses are the CITY's, and at Z0 the camera is
## 18 m from a focus that is usually inside a block — which is a fine place to
## measure a frame and a useless place to look at a lorry. This harness parks
## the camera on the site's own street frontage instead, and walks the six
## construction stages at whatever hour is asked for.
##
## It builds the same stack `game/main.gd` does for a site — `CityView` (so the
## building rises through §2.6's stage clamp behind the work), the
## `ConstructionSiteView` hoarding and crane, and `ConstructionVehicleView` on
## top — because the thing being judged is the WHOLE picture, not one layer of
## it. It owns no constant, reads `data/render.json` for everything, and nothing
## in `sim/` or `game/` imports it.
##
## Usage (needs a display — this renders):
##   ~/.local/bin/godot --path "/home/bbx/Slacum City game" \
##       -s res://tools/construction_preview.gd -- --out=DIR [options]
##
##   --out=DIR          where the PNGs go (one per stage, `stage<N>.png`)
##   --stages=1,2,4,6   which stages to shoot           (default 1,2,3,4,5,6)
##   --hour=H           hour of day, 0..24              (default 13)
##   --gm=M             game-minute the construction layer is wound to before
##                      the shot. Pick one where a lorry is at the site if you
##                      want the tip in frame; `--sweep` finds one for you.
##   --sweep            instead of the stage walk, shoot ONE stage across a
##                      whole delivery cadence (`--frames=N` shots), which is
##                      how the arrive → tip → leave beat is checked
##   --frames=N         shots in `--sweep` mode          (default 8)
##   --stage=S          the stage `--sweep` holds        (default 2)
##   --resolution=WxH   render size                      (default 1600x900)
##   --dist=M           camera distance from the work zone (default 26)
##   --height=M         camera height                    (default 13)
##   --swing=D          camera yaw off the frontage normal, degrees (default 34)

const RENDER_JSON := "res://data/render.json"
const MESH_MANIFEST := "res://game/meshes/generated/manifest.json"
const TILE_M := 8.0

var _opts: Dictionary = {}
var _render_data: Dictionary = {}
var _sim: CitySim
var _model: RenderStateModel
var _city_view: CityView
var _site_view: ConstructionSiteView
var _plant: ConstructionVehicleView
var _env: EnvironmentController
var _camera: Camera3D
var _family_of: Dictionary = {}

var _target_id := -1
var _target_pos := Vector3.ZERO
var _shots: Array = []       # {stage, gm, path}
var _shot_index := 0
var _settle := 0
var _started := false


func _initialize() -> void:
	_opts = _parse(OS.get_cmdline_user_args())
	if String(_opts["out"]) == "":
		printerr("construction_preview: --out=DIR is required")
		quit(2)
		return
	_render_data = StarterCityLoader.read_json(RENDER_JSON)
	_sim = CitySim.boot_from_files()
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
		print("construction_preview: wrote %d shots to %s"
				% [_shots.size(), String(_opts["out"])])
		return true
	var shot: Dictionary = _shots[_shot_index]
	_site_view.set_stage(_target_id, int(shot["stage"]))
	_plant.set_stage(_target_id, int(shot["stage"]))
	_model.apply_events([{"type": &"building_construction_stage",
			"building": _target_id, "stage": int(shot["stage"])}])
	_plant.set_game_minutes(float(shot["gm"]))
	var hour := float(_opts["hour"])
	_env.apply(hour, delta)
	_city_view.refresh(delta, hour, _camera.global_position)
	_site_view.refresh(delta, _env.last_night)
	_plant.set_focus(_target_pos)
	_plant.refresh(delta, _env.last_night, 0.0)
	# A few frames per shot: the environment ramps, the chunk tiers settle and
	# the shaders compile on the first one.
	_settle += 1
	if _settle < 8:
		return false
	_settle = 0
	var image := root.get_texture().get_image()
	if image != null:
		image.save_png(String(shot["path"]))
		print("wrote " + String(shot["path"]))
	_shot_index += 1
	return false


# ------------------------------------------------------------------ the shot

func _plan() -> void:
	var site: ConstructionActivity.Site = _plant.activity.sites[_target_id]
	var period := site.period_gm
	var leg := _plant.activity.leg_gm(site)
	var dir := String(_opts["out"])
	if bool(_opts["sweep"]):
		var frames := int(_opts["frames"])
		var span := period * 1.02
		for i in frames:
			_shots.append({"stage": int(_opts["stage"]),
					"gm": site.offset_gm + span * float(i) / float(frames - 1),
					"path": dir.path_join("sweep%d.png" % i)})
		return
	# Stage walk: park the clock mid-DUMP so the beat the pass exists for — the
	# bed up, the load draining, the heap growing — is in every frame, and give
	# each stage its own run of deliveries. Shooting every stage at ONE game
	# time would show a yard that never had time to fill, which is a picture of
	# the harness rather than of the game.
	var fixed: float = float(_opts["gm"])
	var stages: Array = _opts["stages"]
	for i in stages.size():
		var stage := int(stages[i])
		var gm := fixed
		if gm < 0.0:
			gm = site.offset_gm + period * (9.0 * float(i + 1)) \
					+ leg + _plant.activity.dump_gm * 0.45
		_shots.append({"stage": stage, "gm": gm,
				"path": dir.path_join("stage%d.png" % stage)})


# ----------------------------------------------------------------- the scene

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
	sun.directional_shadow_max_distance = 180.0
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

	_build_ground(stage_root)

	_model = RenderStateModel.new(_render_data, "high")
	var manifest: Dictionary = StarterCityLoader.read_json(MESH_MANIFEST)
	for entry in manifest.get("meshes", []):
		_family_of[String(entry["archetype"])] = String(entry.get("family", "residential"))
	_pick_target()
	for id in _sim.buildings.keys():
		_model.add_building(_building_view(String(id)))
	_city_view = CityView.new()
	stage_root.add_child(_city_view)
	_city_view.setup(_model, _render_data)

	_site_view = ConstructionSiteView.new()
	stage_root.add_child(_site_view)
	_site_view.setup(_render_data)

	_plant = ConstructionVehicleView.new()
	stage_root.add_child(_plant)
	_plant.setup(_render_data)
	_plant.set_road_network(_sim.roads)

	var record: Dictionary = _sim.building_record(_sim_id_of(_target_id))  # PA-100
	var footprint: Vector2i = record["footprint"]
	# doc 11 §2.16: the hoarding's gate takes the frontage the vehicle layer
	# derives, so the coned-off lane and the gate are on the same face of the
	# lot. Both halves of the seam the shell wires — the query up front, and the
	# signal for a frontage that lands late or moves.
	_plant.site_frontage_changed.connect(func(id: int, side: int) -> void:
		_site_view.set_gate_side(id, side))
	_site_view.add_site(_target_id, _target_pos, footprint, 22.0,
			_plant.frontage_side(_target_pos, footprint))
	_plant.add_site(_target_id, _target_pos, footprint, 22.0)
	for _step in 8:
		_plant.refresh(0.0, 0.0, 0.0)

	_camera = Camera3D.new()
	_camera.fov = 40.0
	_camera.near = 0.5
	_camera.far = 1600.0
	stage_root.add_child(_camera)
	_aim()


## Stand on the site's own street, off to one side, looking back at the work
## zone — the angle a player gets when they pinch in on a site.
func _aim() -> void:
	var site: ConstructionActivity.Site = _plant.activity.sites[_target_id]
	var focus := site.edge + site.out * 3.2 + Vector3(0.0, 2.2, 0.0)
	var swing := deg_to_rad(float(_opts["swing"]))
	var back := (site.out * cos(swing) + site.along * sin(swing)).normalized()
	var eye := focus + back * float(_opts["dist"]) \
			+ Vector3(0.0, float(_opts["height"]), 0.0)
	_camera.global_transform = Transform3D(Basis.IDENTITY, eye) \
			.looking_at(focus, Vector3.UP)


## The building whose lot has the most street frontage and the fewest
## neighbours in the way: a corner lot on the widest road near the centre.
func _pick_target() -> void:
	var best := -1.0
	for id in _sim.buildings.keys():
		var b: Building = _sim.buildings[String(id)]
		var record: Dictionary = _sim.building_record(String(id))  # PA-100
		var size: Vector2i = record["footprint"]
		var origin: Vector2i = b.origin
		var lot := Vector2i(origin.x + size.x / 2, origin.y + size.y / 2)
		var road := _sim.roads.graph.nearest_road_tile(lot, 3)
		if road.x < 0:
			continue
		# Prefer a lot that touches a road on the side the camera will stand,
		# and one near the middle of the map so the backdrop is a city.
		var centre := Vector2(56.0, 56.0)
		var score := 40.0 - Vector2(lot).distance_to(centre) \
				+ float(size.x * size.y) * 2.0
		if score > best:
			best = score
			_target_id = b.id
			_target_pos = Vector3(origin.x * TILE_M + size.x * TILE_M * 0.5, 0.0,
					origin.y * TILE_M + size.y * TILE_M * 0.5)


func _sim_id_of(render_id: int) -> String:
	for id in _sim.buildings.keys():
		if (_sim.buildings[String(id)] as Building).id == render_id:
			return String(id)
	return ""


func _building_view(sim_id: String) -> Dictionary:
	var b: Building = _sim.buildings[sim_id]
	var record: Dictionary = _sim.building_record(sim_id)  # PA-100
	var size: Vector2i = record["footprint"]
	var centre := Vector3(b.origin.x * TILE_M + size.x * TILE_M * 0.5, 0.0,
			b.origin.y * TILE_M + size.y * TILE_M * 0.5)
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
		"construction_stage": 1 if b.id == _target_id else 0,
	}


func _build_ground(stage_root: Node3D) -> void:
	var ground := Node3D.new()
	ground.name = "Ground"
	stage_root.add_child(ground)
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
		plane.position = Vector3(block.grid.x * 128.0 + 64.0, 0.0,
				block.grid.y * 128.0 + 64.0)
		ground.add_child(plane)
	var road_mm := MultiMesh.new()
	road_mm.transform_format = MultiMesh.TRANSFORM_3D
	var road_mesh := BoxMesh.new()
	road_mesh.size = Vector3(TILE_M, 0.1, TILE_M)
	road_mesh.material = GroundSurface.material("asphalt", Vector2(8.0, 8.0),
			Color(0.34, 0.34, 0.38), 0.85)
	road_mm.mesh = road_mesh
	var tiles: Array = _sim.roads.graph.road_tiles_sorted()
	road_mm.instance_count = tiles.size()
	for i in tiles.size():
		var t: Vector2i = tiles[i]
		road_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
				Vector3(t.x * TILE_M + 4.0, 0.05, t.y * TILE_M + 4.0)))
	var road_node := MultiMeshInstance3D.new()
	road_node.name = "Roads"
	road_node.multimesh = road_mm
	ground.add_child(road_node)


# ------------------------------------------------------------------- options

func _parse(argv: PackedStringArray) -> Dictionary:
	var opts := {
		"out": "", "hour": 13.0, "gm": -1.0, "resolution": Vector2i(1600, 900),
		"stages": [1, 2, 3, 4, 5, 6], "sweep": false, "frames": 8, "stage": 2,
		# Doc 12's Z0 pose, near enough: D 21 m at 35° elevation, which is the
		# closest a player can ever get to a site. Shooting the layer from
		# under that band would judge it at a pitch the game never shows.
		"dist": 17.0, "height": 12.0, "swing": 34.0,
	}
	for raw in argv:
		var arg := String(raw)
		if arg == "--sweep":
			opts["sweep"] = true
		elif arg.begins_with("--out="):
			opts["out"] = arg.substr(6)
		elif arg.begins_with("--hour="):
			opts["hour"] = float(arg.substr(7))
		elif arg.begins_with("--gm="):
			opts["gm"] = float(arg.substr(5))
		elif arg.begins_with("--frames="):
			opts["frames"] = maxi(2, int(arg.substr(9)))
		elif arg.begins_with("--stage="):
			opts["stage"] = clampi(int(arg.substr(8)), 1, 6)
		elif arg.begins_with("--dist="):
			opts["dist"] = float(arg.substr(7))
		elif arg.begins_with("--height="):
			opts["height"] = float(arg.substr(9))
		elif arg.begins_with("--swing="):
			opts["swing"] = float(arg.substr(8))
		elif arg.begins_with("--stages="):
			var wanted: Array = []
			for part in arg.substr(9).split(","):
				wanted.append(clampi(int(String(part).strip_edges()), 1, 6))
			if not wanted.is_empty():
				opts["stages"] = wanted
		elif arg.begins_with("--resolution="):
			var parts := arg.substr(13).split("x")
			if parts.size() == 2:
				opts["resolution"] = Vector2i(int(parts[0]), int(parts[1]))
	return opts
