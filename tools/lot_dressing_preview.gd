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
##   --archetypes=a,b   which growers to walk. A doc-05 water grower is named
##                      `water_facility:<variant>` — its ladder is doc 05's, per
##                      variant, not doc 02's `water_facility` column
##                      (default store,construction_yard,power_facility,
##                      water_facility:treatment,water_facility:tank)
##   --hour=H           hour of day, 0..24                     (default 13)
##   --resolution=WxH   render size                     (default 1280x720)
##   --dist=M           camera distance from the lot centre    (default 30)
##   --height=M         camera height                          (default 15)
##   --ratio=R          `lot_prop_ratio`, to photograph the governor's floor
##                      (default 1.0; try 0.0 to see pads with nothing on them)

const RENDER_JSON := "res://data/render.json"
const MESH_MANIFEST := "res://game/meshes/generated/manifest.json"
const TILE_M := 8.0
## **All FIVE growers, in the order the report lists them** (Wave 29 fix).
##
## The first cut shipped three, and the two it left out are the two the wave had
## to INVENT a rule for: doc 02's `water_facility` column is the pump reference
## row, and doc 05's own per-variant table grows `treatment` (2×2 → 3×3 at L2)
## and `tank` (2×2 → 3×3 at L3) — A91-D-156, which this lane filed itself. So the
## deck said "every rung of every grower" and photographed three fifths of them,
## including none of the archetype whose lot rule was new. The founding city's
## own `WTR-2` is a tank.
const DEFAULT_ARCHETYPES := ["store", "construction_yard", "power_facility",
		"water_facility:treatment", "water_facility:tank"]
## How long to let a shell this harness had to PLACE finish building. Doc 02's
## water shell is a 12-hour job; 48 game-hours is four times that and costs a
## preview nothing.
const BUILD_OUT_HOURS := 48.0

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


## One walk per subject, and **only for a subject that actually grows**.
##
## `BuildingCatalog.grows()` is the reader here (Wave 29 fix): the set of growers
## is doc 02's table plus doc 05's per-variant one, and asking the catalog is the
## only way this list cannot drift from the rule. A named archetype that does not
## grow is skipped out loud rather than photographed — its lot IS its footprint,
## there is no apron, and sixteen identical shots of a house would say nothing.
func _plan() -> void:
	var dir := String(_opts["out"])
	for spec in (_opts["archetypes"] as Array):
		var archetype := _archetype_of(String(spec))
		var variant := _variant_of(String(spec))
		if not _grows(archetype, variant):
			printerr("lot_dressing_preview: %s does not grow — nothing to dress" % spec)
			continue
		var sim_id := _subject(archetype, variant)
		if sim_id == "":
			printerr("lot_dressing_preview: no %s in the founding city, and none "
					% spec + "could be placed")
			continue
		for level in range(1, _top_level(archetype, variant) + 1):
			_shots.append({"archetype": String(spec), "level": level,
					"sim_id": sim_id,
					"path": dir.path_join("%s_L%d.png"
							% [String(spec).replace(":", "_"), level])})


## `store` → `store`; `water_facility:tank` → `water_facility`.
static func _archetype_of(spec: String) -> String:
	return spec.split(":")[0]


## …and the variant half, empty for a doc-02 archetype.
static func _variant_of(spec: String) -> String:
	var parts := spec.split(":")
	return parts[1] if parts.size() > 1 else ""


## Does this subject's footprint grow at all, under the ceiling it can REACH?
## Doc 02's answer comes from the catalog; doc 05's comes from its own per-variant
## table, because doc 02's `water_facility` column is the pump reference row and
## says `no` for both of the water growers (A91-D-156).
func _grows(archetype: String, variant: String) -> bool:
	if variant == "":
		return _sim.catalog.grows(archetype, _sim.archetype_top_level(archetype))
	return _sim.water_lot_for(variant) != _first_water_footprint(variant)


func _first_water_footprint(variant: String) -> Vector2i:
	var rules := _sim.water.data.placeable_rules(variant)
	return _sim.water.data.footprint_of(StringName(variant), 1,
			String(rules.get("subtype", "")))


func _top_level(archetype: String, variant: String) -> int:
	if variant == "":
		return _sim.archetype_top_level(archetype)
	return _sim.water_variant_top_level(variant)


## The founding city's own instance of this archetype — a real building on real
## ground, not a synthetic one dropped in an empty block.
##
## **Except where the founding city has none.** It ships two water shells, a pump
## (`WTR-1`) and a tank (`WTR-2`), and no `treatment` shell at all: doc 09 §2.9.6
## puts the treatment NODE inside `WTR-1`, whose own shell variant is `pump`. So
## a treatment subject is PLACED, through the real `cmd_place_water_component`
## and built out through the real construction queue — the same ground, the same
## verb and the same 3×3 reservation a player would get.
func _subject(archetype: String, variant: String) -> String:
	for sim_id in _sim.buildings:
		var b: Building = _sim.buildings[sim_id]
		if String(b.archetype) != archetype:
			continue
		if variant != "" and String(b.variant) != variant:
			continue
		return String(sim_id)
	if variant == "":
		return ""
	return _place_water_subject(variant)


func _place_water_subject(variant: String) -> String:
	# The founding city opens with $25,000 and doc 03 prices a treatment plant
	# above that, so every otherwise-legal site answers `E_FUNDS`. The grant is
	# `measure_envelope.gd`'s: an instrument may buy what it has to photograph,
	# and it may not author what anything costs.
	_sim.treasury.credit(5_000_000, &"preview_grant")
	for z in range(32, 80):
		for x in range(32, 80):
			var tile := Vector2i(x, z)
			if not bool(_sim.cmd_place_water_component(variant, tile, 1, true)
					.get("ok", false)):
				continue
			var placed := _sim.cmd_place_water_component(variant, tile, 1)
			if not bool(placed.get("ok", false)):
				continue
			var sim_id := String((placed["payload"] as Dictionary).get("sim_id", ""))
			# Through the real queue, not by writing `state`: a shell forced
			# active by hand would be the one thing in this picture that a player
			# could not produce.
			_sim.advance_hours(BUILD_OUT_HOURS)
			print("lot_dressing_preview: placed %s %s at %s (the founding city "
					% [variant, sim_id, str(tile)] + "ships none)")
			return sim_id
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
	# Wave 31 (RR-254/RR-256): the doc-05 variant picks the SHAPE, and the built
	# extent is the guard that keeps a mesh inside its own ground.
	var shape := ShapeCatalog.shared().shape_of(
			StringName(b.archetype), StringName(b.variant))
	return {
		"id": b.id,
		"archetype_id": StringName(b.archetype),
		"variant_id": StringName(b.variant),
		"level": maxi(b.level, 1),
		"family": String(_family_of.get(String(shape), "residential")),
		"world_pos": centre,
		"built_tiles": size,
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
