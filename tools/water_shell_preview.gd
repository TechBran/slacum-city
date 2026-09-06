extends SceneTree
## **Every doc-05 water shell, at every rung, from the kerb** (doc 05 §6, doc 11
## §2.14, Wave 31 — A91-D-169).
##
## The player's report of 2026-09-06 is a VISUAL claim — *"they just fall out
## onto the road"* — and no assertion settles a visual claim. `tests/
## test_water_shell_shapes.gd` proves the footprints agree; this proves the
## picture does, by parking the camera **on the street the shell is accused of
## standing in** and walking each variant up its ladder. The road edge is in
## frame in every shot on purpose: it is the line the building was crossing.
##
## The scene is `tools/lot_dressing_preview.gd`'s, borrowed wholesale and given
## one thing that harness does not need — `RoadSurfaceView`, doc 11 §2.1.2's
## actual street, off the real road graph. A shot with a painted ground plane and
## no kerb could not show the defect at all.
##
##   ~/.local/bin/godot --path "/home/bbx/Slacum City game" \
##       -s res://tools/water_shell_preview.gd -- --out=DIR [options]
##
##   --out=DIR          where the PNGs go (`<variant>_L<n>.png`)
##   --variants=a,b     which doc-05 variants to walk
##                      (default source,treatment,pump,tank)
##   --levels=N         how many rungs per variant  (default 5, doc 05's ladder)
##   --hour=H           hour of day, 0..24                     (default 13)
##   --resolution=WxH   render size                     (default 1280x720)
##   --dist=M           camera distance from the lot centre    (default 48)
##   --height=M         camera height                          (default 22)
##   --legacy           draw every shell with the ARCHETYPE mesh, as the
##                      renderer did before this wave — the other arm of the
##                      before/after pair, and the only thing that differs
##                      between the two decks

const RENDER_JSON := "res://data/render.json"
const MESH_MANIFEST := "res://game/meshes/generated/manifest.json"
const TILE_M := 8.0
const DEFAULT_VARIANTS := ["source", "treatment", "pump", "tank"]
## Doc 02's water shell is a 12-hour job; 48 game-hours is four times that.
const BUILD_OUT_HOURS := 48.0

var _opts: Dictionary = {}
var _render_data: Dictionary = {}
var _sim: CitySim
var _model: RenderStateModel
var _city_view: CityView
var _roads: RoadSurfaceView
var _env: EnvironmentController
var _camera: Camera3D
var _family_of: Dictionary = {}
var _shapes: ShapeCatalog

var _shots: Array = []       # {variant, level, sim_id, path}
var _shot_index := 0
var _settle := 0
var _started := false


func _initialize() -> void:
	_opts = _parse(OS.get_cmdline_user_args())
	if String(_opts["out"]) == "":
		printerr("water_shell_preview: --out=DIR is required")
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
		print("water_shell_preview: wrote %d shots to %s"
				% [_shots.size(), String(_opts["out"])])
		return true
	var shot: Dictionary = _shots[_shot_index]
	if _settle == 0:
		_stage(shot)
	var hour := float(_opts["hour"])
	_env.apply(hour, delta)
	_city_view.refresh(delta, hour, _camera.global_position)
	_settle += 1
	if _settle < 8:
		return false
	_settle = 0
	var image := root.get_texture().get_image()
	if image != null:
		image.save_png(String(shot["path"]))
		print("wrote %s  (%s L%d, built %s, mesh %s, overhang %+.1f m/edge)"
				% [String(shot["path"]), String(shot["variant"]), int(shot["level"]),
				str(shot["built"]), str(shot["mesh"]), float(shot["overhang"])])
	_shot_index += 1
	return false


## Put the subject on this shot's rung and re-state it, which is exactly what
## `RenderStateModel` does when a real upgrade completes.
func _stage(shot: Dictionary) -> void:
	var sim_id := String(shot["sim_id"])
	var b: Building = _sim.buildings[sim_id]
	b.level = int(shot["level"])
	b.stats = _sim.catalog.stats(String(b.archetype), b.level)
	_model.add_building(_building_view(sim_id))
	_aim(sim_id)


func _plan() -> void:
	var dir := String(_opts["out"])
	# An instrument may buy what it has to photograph and may not author what
	# anything costs — `measure_envelope.gd`'s rule.
	_sim.treasury.credit(5_000_000, &"preview_grant")
	for variant in (_opts["variants"] as Array):
		var name := String(variant)
		var sim_id := _subject(name)
		if sim_id == "":
			printerr("water_shell_preview: no %s could be placed" % name)
			continue
		var rules := _sim.water.data.placeable_rules(name)
		var subtype := String(rules.get("subtype", ""))
		var shape := _shapes.shape_of(&"water_facility", StringName(name))
		for level in range(1, int(_opts["levels"]) + 1):
			var built := _sim.water.data.footprint_of(StringName(name), level, subtype)
			var mesh := _shapes.footprint_of(
					&"water_facility" if bool(_opts["legacy"]) else shape, level)
			_shots.append({"variant": name, "level": level, "sim_id": sim_id,
					"built": built, "mesh": mesh,
					"overhang": maxf(float(mesh.x - built.x), float(mesh.y - built.y))
							* TILE_M * 0.5,
					"path": dir.path_join("%s_L%d.png" % [name, level])})


## The founding city's own shell where it ships one — `WTR-1` is a pump and
## `WTR-2` a tank — and a REAL placement through `cmd_place_water_component`
## where it does not, which is the treatment plant and the river intake.
func _subject(variant: String) -> String:
	for sim_id in _sim.buildings:
		var b: Building = _sim.buildings[sim_id]
		if String(b.archetype) == "water_facility" and String(b.variant) == variant:
			return String(sim_id)
	for z in range(32, 80):
		for x in range(32, 80):
			var tile := Vector2i(x, z)
			if not bool(_sim.cmd_place_water_component(variant, tile, 1, true)
					.get("ok", false)):
				continue
			var placed := _sim.cmd_place_water_component(variant, tile, 1)
			if not bool(placed.get("ok", false)):
				continue
			# Through the real queue, not by writing `state`: a shell forced
			# active by hand would be the one thing in the picture a player
			# could not produce.
			_sim.advance_hours(BUILD_OUT_HOURS)
			return String((placed["payload"] as Dictionary).get("sim_id", ""))
	return ""


## **From the kerb, not from above.** The eye is put on the nearest ROAD tile to
## the lot, at head height plus a little, looking back at the lot centre — so the
## carriageway runs across the bottom of the frame and a building over the
## property line is over a line the viewer can see.
func _aim(sim_id: String) -> void:
	var b: Building = _sim.buildings[sim_id]
	var built := _sim.built_of_building(b)
	var centre := TileGrid.centre_of_footprint(b.origin, built)
	var road := _nearest_road_tile(b.origin, _sim.lot_of_building(b))
	var eye := centre + Vector3(-1.0, 0.0, 1.0).normalized() * float(_opts["dist"])
	if road != Vector2i(-1, -1):
		var road_centre := TileGrid.centre_of_footprint(road, Vector2i.ONE)
		var away := (road_centre - centre)
		away.y = 0.0
		if away.length() > 0.01:
			eye = road_centre + away.normalized() * (float(_opts["dist"]) - away.length())
	eye.y = float(_opts["height"])
	_camera.global_position = eye
	_camera.look_at(centre + Vector3(0.0, 3.0, 0.0), Vector3.UP)


## The road tile nearest the lot, searched face-outward the way doc 11 §2.16's
## frontage probe is — a frontage is a FACE, so a corner lot is not handed the
## diagonal tile between two streets.
func _nearest_road_tile(origin: Vector2i, lot: Vector2i) -> Vector2i:
	for step in range(1, 7):
		for side in 4:
			for along in range(maxi(lot.x, lot.y)):
				var t := Vector2i(-1, -1)
				match side:
					0: t = Vector2i(origin.x + along, origin.y - step)
					1: t = Vector2i(origin.x + lot.x - 1 + step, origin.y + along)
					2: t = Vector2i(origin.x + along, origin.y + lot.y - 1 + step)
					3: t = Vector2i(origin.x - step, origin.y + along)
				if not TileGrid.in_bounds(t.x, t.y):
					continue
				if _sim.world.grid.has_flag(t.x, t.y, TileGrid.FLAG_ROAD):
					return t
	return Vector2i(-1, -1)


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
	# The street itself, off the real graph — the line the report is about.
	_roads = RoadSurfaceView.new()
	_roads.name = "RoadSurface"
	stage_root.add_child(_roads)
	_roads.setup(_render_data)
	_roads.set_preset("high", _render_data)
	_roads.rebuild(_sim.world.grid,
			_sim.roads.graph if _sim.roads != null else null)

	var manifest: Dictionary = StarterCityLoader.read_json(MESH_MANIFEST)
	_shapes = ShapeCatalog.from_manifest(manifest)
	for entry in manifest.get("meshes", []):
		_family_of[String(entry["archetype"])] = String(entry.get("family", "residential"))
	_model = RenderStateModel.new(_render_data, "high")
	_model.set_shapes(_shapes)
	for id in _sim.buildings.keys():
		_model.add_building(_building_view(String(id)))
	_city_view = CityView.new()
	stage_root.add_child(_city_view)
	_city_view.setup(_model, _render_data)

	_camera = Camera3D.new()
	_camera.fov = 45.0
	_camera.far = 2000.0
	stage_root.add_child(_camera)
	_camera.make_current()


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
	node.position = Vector3(TileGrid.SIZE * TILE_M * 0.5, -0.02,
			TileGrid.SIZE * TILE_M * 0.5)
	stage_root.add_child(node)


## The BUILT extent, and the doc-05 variant that picks the shape. `--legacy`
## withholds the variant, which is precisely the state the renderer was in
## before this wave: the model can only see `archetype_id`, resolves the pump
## reference shape for every shell, and the picture is the defect.
func _building_view(sim_id: String) -> Dictionary:
	var b: Building = _sim.buildings[sim_id]
	var record: Dictionary = _sim.building_record(sim_id)
	var size := _sim.built_of_building(b)
	var centre := TileGrid.centre_of_footprint(b.origin, size)
	var variant := &"" if bool(_opts["legacy"]) else StringName(b.variant)
	var shape := _shapes.shape_of(StringName(b.archetype), variant)
	var view := {
		"id": b.id,
		"archetype_id": StringName(b.archetype),
		"variant_id": variant,
		"level": maxi(b.level, 1),
		"family": String(_family_of.get(String(shape), "residential")),
		"world_pos": centre,
		"block_id": String(record.get("block", "")),
		"transform": Transform3D(Basis.IDENTITY, centre),
		"occ_b": 1.0,
		"powered": true,
		"condition": b.condition,
		"construction_stage": 0,
	}
	if not bool(_opts["legacy"]):
		# The overhang guard is part of the after arm and not of the before one:
		# the whole point of `--legacy` is a picture of the renderer with neither.
		view["built_tiles"] = size
	return view


func _parse(args: PackedStringArray) -> Dictionary:
	var out := {"out": "", "hour": 13.0, "resolution": Vector2i(1280, 720),
			"dist": 48.0, "height": 22.0, "levels": 5, "legacy": false,
			"variants": DEFAULT_VARIANTS.duplicate()}
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
		elif arg.begins_with("--levels="):
			out["levels"] = int(arg.substr(9))
		elif arg == "--legacy":
			out["legacy"] = true
		elif arg.begins_with("--variants="):
			out["variants"] = arg.substr(11).split(",", false)
		elif arg.begins_with("--resolution="):
			var parts := arg.substr(13).split("x")
			if parts.size() == 2:
				out["resolution"] = Vector2i(int(parts[0]), int(parts[1]))
	return out
