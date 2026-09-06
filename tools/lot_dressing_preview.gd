extends SceneTree
## **Eye-level screenshots of a LOT at every rung of its ladder** (doc 11 §2.16a,
## doc 02 §2.3a, doc 93 §BE7), so the half of the lot rule the player actually
## sees can be judged instead of asserted.
##
## The claim this harness exists to test is a VISUAL one: *"the un-built part of
## a lot must look intentional, and it must recede as the building grows into
## it."* No assertion can settle that. So this parks a camera on one lot's own
## street frontage and walks the archetype up its ladder, re-stating the building
## at each rung and re-dressing the ground under it — which is exactly what the
## shell does on a completed upgrade.
##
## It builds the same stack `game/main.gd` does — `CityView` for the building and
## `LotDressingView` for the apron — because what is being judged is the whole
## picture. `tools/construction_preview.gd` is its sibling and this borrows its
## scene scaffolding wholesale.
##
## Usage (needs a display — this renders):
##   ~/.local/bin/godot --path "/home/bbx/Slacum City game" \
##       -s res://tools/lot_dressing_preview.gd -- --out=DIR [options]
##
##   --out=DIR          where the PNGs go (`<archetype>_L<n>.png`)
##   --archetypes=a,b   which growers to walk
##                      (default store,construction_yard,power_facility)
##   --hour=H           hour of day, 0..24                     (default 13)
##   --resolution=WxH   render size                     (default 1280x720)
##   --dist=M           camera distance from the lot centre    (default 30)
##   --height=M         camera height                          (default 15)
##   --ratio=R          `lot_prop_ratio`, to photograph the governor's floor
##                      (default 1.0; try 0.0 to see pads with nothing on them)

const RENDER_JSON := "res://data/render.json"
const MESH_MANIFEST := "res://game/meshes/generated/manifest.json"
const TILE_M := 8.0
## The growers, in the order the report lists them.
const DEFAULT_ARCHETYPES := ["store", "construction_yard", "power_facility"]

var _opts: Dictionary = {}
var _render_data: Dictionary = {}
var _sim: CitySim
var _model: RenderStateModel
var _city_view: CityView
var _dressing: LotDressingView
var _env: EnvironmentController
var _camera: Camera3D
var _family_of: Dictionary = {}

var _shots: Array = []       # {archetype, level, sim_id, path}
var _shot_index := 0
var _settle := 0
var _started := false


func _initialize() -> void:
	_opts = _parse(OS.get_cmdline_user_args())
	if String(_opts["out"]) == "":
		printerr("lot_dressing_preview: --out=DIR is required")
		quit(2)
		return
	_render_data = StarterCityLoader.read_json(RENDER_JSON)
	_sim = CitySim.boot_from_files()
	root.size = _opts["resolution"] as Vector2i
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DirAccess.make_dir_recursive_absolute(String(_opts["out"]))


func _process(delta: float) -> bool:
	if not _started:
		_build()
		_plan()
		_started = true
		return false
	if _shot_index >= _shots.size():
		print("lot_dressing_preview: wrote %d shots to %s"
				% [_shots.size(), String(_opts["out"])])
		return true
	var shot: Dictionary = _shots[_shot_index]
	if _settle == 0:
		_stage(shot)
	var hour := float(_opts["hour"])
	_env.apply(hour, delta)
	_city_view.refresh(delta, hour, _camera.global_position)
	# The environment ramps, the chunk tiers settle and the shaders compile on
	# the first frames of a pose; eight is what the sibling harness uses.
	_settle += 1
	if _settle < 8:
		return false
	_settle = 0
	var image := root.get_texture().get_image()
	if image != null:
		image.save_png(String(shot["path"]))
		print("wrote %s  (level %d, %d pads, %d props)"
				% [String(shot["path"]), int(shot["level"]),
				_dressing.pad_count(), _dressing.prop_count()])
	_shot_index += 1
	return false


## Put the subject on the rung this shot is about, and re-dress the ground the
## way `on_construction_completed` would. Re-stating a standing building rather
## than waiting out its ladder is the same shortcut `measure_envelope.gd` takes,
## and it is stated rather than hidden: every number under it — the catalog row,
## the lot, the built extent — is real.
func _stage(shot: Dictionary) -> void:
	var sim_id := String(shot["sim_id"])
	var b: Building = _sim.buildings[sim_id]
	b.level = int(shot["level"])
	b.stats = _sim.catalog.stats(String(b.archetype), b.level)
	_model.add_building(_building_view(sim_id))
	_dressing.apply_rows(LotDressingModel.rows_from_sim(_sim))
	_aim(sim_id)


func _plan() -> void:
	var dir := String(_opts["out"])
	for archetype in (_opts["archetypes"] as Array):
		var sim_id := _subject(String(archetype))
		if sim_id == "":
			printerr("lot_dressing_preview: no %s in the founding city" % archetype)
			continue
		for level in range(1, _sim.archetype_top_level(String(archetype)) + 1):
			_shots.append({"archetype": String(archetype), "level": level,
					"sim_id": sim_id,
					"path": dir.path_join("%s_L%d.png" % [archetype, level])})


## The founding city's own instance of this archetype — a real building on real
## ground, not a synthetic one dropped in an empty block.
func _subject(archetype: String) -> String:
	for sim_id in _sim.buildings:
		var b: Building = _sim.buildings[sim_id]
		if String(b.archetype) == archetype:
			return String(sim_id)
	return ""


## Park the camera on the lot's frontage, looking down at the whole reservation.
func _aim(sim_id: String) -> void:
	var b: Building = _sim.buildings[sim_id]
	var lot: Vector2i = _sim.building_record(sim_id).get("footprint", Vector2i.ONE)
	var centre := TileGrid.centre_of_footprint(b.origin, lot)
	var dist := float(_opts["dist"])
	var height := float(_opts["height"])
	var eye := centre + Vector3(-dist * 0.72, height, dist * 0.72)
	_camera.global_position = eye
	_camera.look_at(centre, Vector3.UP)


# ------------------------------------------------------------------ the scene

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
	for id in _sim.buildings.keys():
		_model.add_building(_building_view(String(id)))
	_city_view = CityView.new()
	stage_root.add_child(_city_view)
	_city_view.setup(_model, _render_data)

	_dressing = LotDressingView.new()
	stage_root.add_child(_dressing)
	_dressing.setup(LotDressingModel.new(), _render_data)
	_dressing.apply_governor({"lot_prop_ratio": float(_opts["ratio"])})
	_dressing.apply_rows(LotDressingModel.rows_from_sim(_sim))

	_camera = Camera3D.new()
	_camera.fov = 40.0
	_camera.far = 2000.0
	stage_root.add_child(_camera)
	_camera.make_current()


## A plain lit ground plane under the city, so an apron is judged against ground
## and not against the void.
func _build_ground(stage_root: Node3D) -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(TileGrid.SIZE * TILE_M, TileGrid.SIZE * TILE_M)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.286, 0.310, 0.259)
	mat.roughness = 1.0
	plane.material = mat
	var node := MeshInstance3D.new()
	node.name = "PreviewGround"
	node.mesh = plane
	node.position = Vector3(TileGrid.SIZE * TILE_M * 0.5, -0.01,
			TileGrid.SIZE * TILE_M * 0.5)
	stage_root.add_child(node)


## The BUILT extent, for `construction_preview.gd`'s reason: the record's
## `footprint` is the LOT now, and a mesh centred on it would sit half a tile off
## the ground it stands on (doc 02 §2.3a).
func _building_view(sim_id: String) -> Dictionary:
	var b: Building = _sim.buildings[sim_id]
	var record: Dictionary = _sim.building_record(sim_id)
	var size := _sim.built_of_building(b)
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
		"construction_stage": 0,
	}


func _parse(args: PackedStringArray) -> Dictionary:
	var out := {"out": "", "hour": 13.0, "resolution": Vector2i(1280, 720),
			"dist": 30.0, "height": 15.0, "ratio": 1.0,
			"archetypes": DEFAULT_ARCHETYPES.duplicate()}
	for raw in args:
		var arg := String(raw)
		if arg.begins_with("--out="):
			out["out"] = arg.substr(6)
		elif arg.begins_with("--hour="):
			out["hour"] = float(arg.substr(7))
		elif arg.begins_with("--dist="):
			out["dist"] = float(arg.substr(7))
		elif arg.begins_with("--height="):
			out["height"] = float(arg.substr(9))
		elif arg.begins_with("--ratio="):
			out["ratio"] = float(arg.substr(8))
		elif arg.begins_with("--archetypes="):
			out["archetypes"] = arg.substr(13).split(",", false)
		elif arg.begins_with("--resolution="):
			var parts := arg.substr(13).split("x")
			if parts.size() == 2:
				out["resolution"] = Vector2i(int(parts[0]), int(parts[1]))
	return out
