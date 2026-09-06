extends SceneTree
## **The water shell OVERHANG probe** (doc 05 §6, doc 11 §2.14, Wave 31,
## A91-D-169), and the instrument the player's report of 2026-09-06 was
## reproduced with:
##
##     "Treatment plants and storage tanks — the buildings are built off-centre,
##      and they just fall out onto the road. They don't follow their grid
##      pattern; they're just off-centre from it."
##
## For every doc-05 water variant, at every level it has, this prints the three
## numbers that settle it and the one that is the defect:
##
##   * the SIM's answer — origin, `built_of_building`, `lot_of_building`, and the
##     mesh centre `TileGrid.centre_of_footprint` puts on the built extent;
##   * the RENDER's answer under the ARCHETYPE key (`water_facility:L:0`), which
##     is what the renderer used before this wave — doc 02's PUMP reference row;
##   * the RENDER's answer under the VARIANT key (`ShapeCatalog.shape_of`), which
##     is what it uses now;
##   * **OVERHANG**: half the difference between the mesh's footprint and the
##     built one, in metres, per edge. Positive means building over the property
##     line, and a lot beside a street means building in the road.
##
## Both render columns are printed on the SAME run on purpose: the before and the
## after of the one number this wave exists to move are then the same
## measurement, taken the same way, on the same city — not two runs of two
## builds that could differ in anything.
##
## It also walks the founding city's own shells (`WTR-1`, a pump; `WTR-2`, a
## tank) and PLACES one of each placeable variant through the real
## `cmd_place_water_component`, because a defect reported on placed buildings is
## measured on placed buildings.
##
## Read-only against `sim/`: it boots a city, places through the real verbs and
## advances the real clock, and nothing here authors a number.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/probe_water_shell.gd \
##       -- [--city=res://tests/fixtures/bench_city.json] [--no-place]
##
##   --city=PATH   boot a different city (default `data/starter_city.json`)
##   --no-place    the standing shells only; place nothing

const STARTER_CITY := "res://data/starter_city.json"
const MESH_MANIFEST := "res://game/meshes/generated/manifest.json"
const TILE_M := 8.0
## Doc 05 §6's placeable roster, in the order the report reads them.
const VARIANTS := ["treatment", "tank", "pump", "source"]
## Long enough for doc 02's 12-hour water shell to finish four times over.
const BUILD_OUT_HOURS := 48.0

var _sim: CitySim
var _shapes: ShapeCatalog
var _manifest: Dictionary = {}


func _initialize() -> void:
	var iso := UserDirIsolation.new().begin()
	var args := OS.get_cmdline_user_args()
	var city := STARTER_CITY
	for raw in args:
		var arg := String(raw)
		if arg.begins_with("--city="):
			city = arg.substr(7)
	_sim = _boot(city)
	_manifest = StarterCityLoader.read_json(MESH_MANIFEST)
	_shapes = ShapeCatalog.from_manifest(_manifest)
	print("city: %s" % city)
	print("")
	_ladders()
	print("")
	_standing()
	if not args.has("--no-place"):
		print("")
		_placed()
	print("")
	_shape_table()
	iso.end()
	quit(0)


func _boot(city: String) -> CitySim:
	if city == STARTER_CITY:
		return CitySim.boot_from_files()
	var sim := CitySim.new()
	sim.boot(1337,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(city),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	for message in sim.boot_errors:
		printerr("  boot error: " + String(message))
	return sim


## The whole table, variant by variant and rung by rung, with no city involved:
## doc 05's built footprint against the mesh each key resolves to. This is the
## defect in its general form — the rows where OLD is non-zero are every shell
## the renderer could ever have put in the road.
func _ladders() -> void:
	print("LADDERS — doc 05's built footprint vs the mesh the render picks")
	print("  variant    L  built   lot   | archetype-key mesh  overhang/edge "
			+ "| variant-key mesh    overhang/edge")
	for variant in VARIANTS:
		var rules := _sim.water.data.placeable_rules(variant)
		var subtype := String(rules.get("subtype", ""))
		var lot := _sim.water_lot_for(variant, subtype)
		var shape := _shapes.shape_of(StringName("water_facility"), StringName(variant))
		for level in range(1, 6):
			var built := _sim.water.data.footprint_of(StringName(variant), level, subtype)
			var old_mesh := _mesh_footprint("water_facility", level)
			var new_mesh := _mesh_footprint(String(shape), level)
			print(("  %-9s L%d  %dx%d   %dx%d  | %-9s %dx%d  %+5.1f m  "
					+ "| %-26s %dx%d  %+5.1f m")
					% [variant, level, built.x, built.y, lot.x, lot.y,
					"water_facility", old_mesh.x, old_mesh.y,
					_overhang_m(old_mesh, built),
					String(shape), new_mesh.x, new_mesh.y,
					_overhang_m(new_mesh, built)])


## The shells the founding city SHIPS — `WTR-1` (pump) and `WTR-2` (tank) — read
## through the same calls `game/main.gd::_building_view` makes.
func _standing() -> void:
	print("STANDING SHELLS in this city")
	_header()
	for sim_id in _sorted(_sim.buildings):
		var b: Building = _sim.buildings[String(sim_id)]
		if String(b.archetype) != "water_facility":
			continue
		_row(String(sim_id), b)


## One of each placeable variant, PLACED through the real verb and built out
## through the real construction queue, because the report is about placement.
func _placed() -> void:
	print("PLACED through cmd_place_water_component (real verb, real queue)")
	_header()
	# An instrument may buy what it has to measure and may not author what
	# anything costs — `measure_envelope.gd`'s rule.
	_sim.treasury.credit(5_000_000, &"probe_grant")
	for variant in VARIANTS:
		var sim_id := _place(variant)
		if sim_id == "":
			printerr("  %s: nothing placeable in the core" % variant)
			continue
		_row(sim_id, _sim.buildings[sim_id])


func _place(variant: String) -> String:
	for z in range(32, 80):
		for x in range(32, 80):
			var tile := Vector2i(x, z)
			if not bool(_sim.cmd_place_water_component(variant, tile, 1, true)
					.get("ok", false)):
				continue
			var placed := _sim.cmd_place_water_component(variant, tile, 1)
			if not bool(placed.get("ok", false)):
				continue
			_sim.advance_hours(BUILD_OUT_HOURS)
			return String((placed["payload"] as Dictionary).get("sim_id", ""))
	return ""


func _header() -> void:
	print("  id        variant    L  origin     built  lot   centre                "
			+ "| old mesh  over | new mesh  over")


func _row(sim_id: String, b: Building) -> void:
	var built := _sim.built_of_building(b)
	var lot := _sim.lot_of_building(b)
	var centre := TileGrid.centre_of_footprint(b.origin, built)
	var level := maxi(b.level, 1)
	var shape := _shapes.shape_of(StringName(b.archetype), StringName(b.variant))
	var old_mesh := _mesh_footprint(String(b.archetype), level)
	var new_mesh := _mesh_footprint(String(shape), level)
	print(("  %-9s %-9s L%d (%d,%d)  %dx%d  %dx%d  (%.0f,%.0f,%.0f)  "
			+ "| %dx%d %+5.1f | %dx%d %+5.1f")
			% [sim_id, String(b.variant), level, b.origin.x, b.origin.y,
			built.x, built.y, lot.x, lot.y, centre.x, centre.y, centre.z,
			old_mesh.x, old_mesh.y, _overhang_m(old_mesh, built),
			new_mesh.x, new_mesh.y, _overhang_m(new_mesh, built)])


## What `ShapeCatalog` resolves, printed so the render's own map can be read
## rather than inferred — including the variant that deliberately has no shape.
func _shape_table() -> void:
	print("SHAPES resolved by ShapeCatalog (the render's own map)")
	for variant in ["source", "treatment", "pump", "tank", "booster"]:
		var shape := _shapes.shape_of(StringName("water_facility"), StringName(variant))
		var own := _shapes.has_own_shape(StringName("water_facility"), StringName(variant))
		print("  water_facility/%-10s -> %-26s %s" % [variant, String(shape),
				"own shape" if own else "FALLBACK (scaled into its built footprint)"])


## The mesh's own footprint at this level, off the LOD0 manifest row.
func _mesh_footprint(shape: String, level: int) -> Vector2i:
	for entry_v in _manifest.get("meshes", []) as Array:
		var entry: Dictionary = entry_v
		if String(entry.get("archetype", "")) != shape:
			continue
		if int(entry.get("level", 0)) != level or int(entry.get("lod", 0)) != 0:
			continue
		var foot: Array = entry.get("footprint_tiles", [0, 0])
		return Vector2i(int(foot[0]), int(foot[1]))
	return Vector2i.ZERO


## Metres of mesh past the built footprint's edge, per edge — the number the
## player is looking at. Half the difference, because the mesh is CENTRED.
func _overhang_m(mesh: Vector2i, built: Vector2i) -> float:
	if mesh.x <= 0 or built.x <= 0:
		return 0.0
	return maxf(float(mesh.x - built.x), float(mesh.y - built.y)) * TILE_M * 0.5


func _sorted(d: Dictionary) -> Array:
	var out: Array = d.keys()
	out.sort()
	return out
