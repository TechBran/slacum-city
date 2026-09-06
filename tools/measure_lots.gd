extends SceneTree
## **The LOT census** (doc 02 §2.3a, doc 93 §BE6, Wave 29).
##
## A building reserves the footprint of its FINAL form at placement, and every
## city that already existed was laid out under the old rule. `migrate_lots()`
## gives each standing building the rest of its lot where the ground is free and
## reports the rest as LOT-LOCKED. **This is the instrument that publishes those
## counts**. It ASKS — `lot_locked_ids()` and `lot_lock()` — rather than
## listening: a census is a question, and an event announcing one would have been
## a publication with no subscriber (see `CitySim.migrate_lots`).
##
## It also prints the DENSITY the rule costs — how much ground the lots take and
## how much is left — because bigger lots mean fewer sites per block, and doc 92
## §70 is fitted to what this prints rather than to an estimate.
##
## Read-only: it boots a city, reads it, and advances nothing. Nothing in `sim/`
## imports it.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/measure_lots.gd \
##       -- [--city=res://tests/fixtures/bench_city.json] [--list] [--sites]
##
##   --city=PATH   boot a different city (default `data/starter_city.json`)
##   --saves=DIR   INSTEAD of an authored city: load a real slot out of DIR
##                 through the real `SaveService`, into a private `user://`.
##                 This is how the PLAYER's own city is counted —
##                 `tests/fixtures/player_save_0903` — and it is the only one of
##                 the three that exercises the restore path's migration rather
##                 than the boot path's.
##   --slot=N      which slot `--saves` loads (default 0)
##   --list        one line per lot-locked building, with its blockers
##   --sites       the placement-density half: how many legal sites each growing
##                 archetype has, at its LOT and at its old level-1 footprint

const STARTER_CITY := "res://data/starter_city.json"
## Doc 02 §2.3a's growing set. `water_facility` is here because its per-VARIANT
## ladder grows even though its doc-02 column does not (doc 93 §BE4).
const GROWERS := ["store", "power_facility", "construction_yard", "water_facility"]


func _initialize() -> void:
	var iso := UserDirIsolation.new().begin()
	var args := OS.get_cmdline_user_args()
	var city := STARTER_CITY
	var saves := ""
	var slot := 0
	for raw in args:
		var arg := String(raw)
		if arg.begins_with("--city="):
			city = arg.substr(7)
		elif arg.begins_with("--saves="):
			saves = arg.substr(8)
		elif arg.begins_with("--slot="):
			slot = int(arg.substr(7))
	var sim: CitySim = null
	if saves != "":
		sim = _load(saves, slot, iso)
		if sim == null:
			iso.end()
			quit(2)
			return
		print("city: %s (slot %d, through the real SaveService)" % [saves, slot])
	else:
		sim = _boot(city)
		print("city: %s" % city)
	print("")
	_ladders(sim)
	print("")
	_census(sim, args.has("--list"))
	print("")
	_ground(sim)
	if args.has("--sites"):
		print("")
		_sites(sim)
	iso.end()
	quit(0)


## **The player's own city, through the real `SaveService`** — the only one of
## the three cities counted here that reaches `migrate_lots` by the RESTORE path
## rather than by boot, which is the path every phone in the world will take.
##
## The slot is copied into this process's private `user://` (already isolated by
## `UserDirIsolation`) rather than read in place, because `SaveService` writes —
## a load can promote a legacy file and roll a generation — and a measurement
## must not edit the fixture it is measuring.
func _load(saves: String, slot: int, iso: UserDirIsolation) -> CitySim:
	var dest := iso.user_dir.path_join("saves")
	DirAccess.make_dir_recursive_absolute(dest)
	if _copy_tree(saves, dest) == 0:
		printerr("measure_lots: nothing copied out of " + saves)
		return null
	var sim := CitySim.boot_from_files(1337)
	var service := SaveService.new()
	root.add_child(service)
	var ok := service.load_slot(sim, slot)
	root.remove_child(service)
	service.free()
	if not ok:
		printerr("measure_lots: slot %d did not load out of %s" % [slot, saves])
		return null
	return sim


func _copy_tree(source: String, dest: String) -> int:
	var dir := DirAccess.open(source)
	if dir == null:
		return 0
	var copied := 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var from := source.path_join(entry)
		var to := dest.path_join(entry)
		if dir.current_is_dir():
			DirAccess.make_dir_recursive_absolute(to)
			copied += _copy_tree(from, to)
		elif DirAccess.copy_absolute(from, to) == OK:
			copied += 1
		entry = dir.get_next()
	dir.list_dir_end()
	return copied


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


## Which archetypes actually grow, measured to the ceiling each can REACH — not
## to the last row of doc 02's table (doc 93 §BE3).
##
## The `grows` column asks `BuildingCatalog.grows()` rather than comparing the
## two extents here (Wave 29 fix): the catalog owns "does this ladder change
## footprint", the comparison was a second spelling of it, and a public accessor
## with no caller is the A91-D-19 shape this whole wave is named after.
func _ladders(sim: CitySim) -> void:
	print("LADDERS (lot is measured to the reachable ceiling)")
	print("  archetype            L1     lot    top   grows")
	for archetype in GROWERS:
		var first := sim.built_for(archetype, 1)
		var lot := sim.lot_for(archetype)
		var top := sim.archetype_top_level(archetype)
		print("  %-20s %dx%d    %dx%d    L%d    %s" % [archetype, first.x, first.y,
				lot.x, lot.y, top,
				"YES" if sim.catalog.grows(archetype, top) else "no"])
	print("  -- doc 05's per-variant water ladders (doc 02's column is the PUMP row) --")
	for variant in ["source", "treatment", "pump", "tank"]:
		var rules := sim.water.data.placeable_rules(variant)
		var subtype := String(rules.get("subtype", ""))
		var first := sim.water.data.footprint_of(StringName(variant), 1, subtype)
		var lot := sim.water_lot_for(variant)
		print("  %-20s %dx%d    %dx%d    L%d    %s" % [variant, first.x, first.y,
				lot.x, lot.y, sim.water_variant_top_level(variant),
				"YES" if lot != first else "no"])


func _census(sim: CitySim, list: bool) -> void:
	var locked := sim.lot_locked_ids()
	var growers := {}
	var locked_by := {}
	for sim_id in sim.buildings:
		var b: Building = sim.buildings[sim_id]
		var key := _key(sim, b)
		if sim.lot_of_building(b) != _first_of(sim, b):
			growers[key] = int(growers.get(key, 0)) + 1
	for sim_id in locked:
		var b: Building = sim.buildings[sim_id]
		var key := _key(sim, b)
		locked_by[key] = int(locked_by.get(key, 0)) + 1
	print("CENSUS AFTER MIGRATION")
	print("  buildings          : %d" % sim.buildings.size())
	print("  growing buildings  : %d  %s" % [_total(growers), _fmt(growers)])
	print("  LOT-LOCKED         : %d  %s" % [locked.size(), _fmt(locked_by)])
	if not list:
		return
	print("")
	for sim_id in locked:
		var info := sim.lot_lock(String(sim_id))
		print("    %-12s %-18s held=%dx%d lot=%dx%d reaches L%d of %d  blocked by %s"
				% [sim_id, String(info["archetype"]),
				(info["held"] as Vector2i).x, (info["held"] as Vector2i).y,
				(info["lot"] as Vector2i).x, (info["lot"] as Vector2i).y,
				int(info["reachable_level"]), int(info["top_level"]),
				str(info["blockers"])])


## What the rule costs in ground: reserved tiles against the buildable ground the
## city has. This is the number doc 92 §70's density derivation is fitted to.
func _ground(sim: CitySim) -> void:
	var reserved := 0
	var built := 0
	for sim_id in sim.buildings:
		var b: Building = sim.buildings[sim_id]
		var held: Vector2i = sim.building_record(String(sim_id)).get("footprint", Vector2i.ONE)
		var extent := sim.built_of_building(b)
		reserved += held.x * held.y
		built += extent.x * extent.y
	var free := 0
	var occupied := 0
	for z in range(TileGrid.SIZE):
		for x in range(TileGrid.SIZE):
			var flags := sim.world.grid.flags_at(x, z)
			if (flags & TileGrid.FLAG_OCCUPIED) != 0:
				occupied += 1
			elif (flags & TileGrid.FLAG_BUILDABLE) != 0:
				free += 1
	print("GROUND")
	print("  reserved tiles (lots)       : %d" % reserved)
	print("  built tiles (meshes)        : %d" % built)
	print("  apron tiles (lot - built)   : %d" % (reserved - built))
	print("  OCCUPIED on the grid        : %d" % occupied)
	print("  buildable and free          : %d" % free)


## The DENSITY half: how many legal origins each grower has on the ground the
## city has today, at its LOT and at the level-1 footprint the old rule reserved.
## The ratio is what "fewer sites per block" actually means, measured.
func _sites(sim: CitySim) -> void:
	print("PLACEMENT DENSITY (legal origins over the whole map)")
	print("  archetype             at L1 foot    at LOT    ratio")
	for archetype in GROWERS:
		var first := sim.built_for(archetype, 1)
		var lot := sim.lot_for(archetype)
		var n_first := _count_sites(sim, first)
		var n_lot := _count_sites(sim, lot)
		print("  %-20s %8d  %8d    %.3f" % [archetype, n_first, n_lot,
				float(n_lot) / maxf(1.0, float(n_first))])


func _count_sites(sim: CitySim, size: Vector2i) -> int:
	var count := 0
	for z in range(TileGrid.SIZE - size.y + 1):
		for x in range(TileGrid.SIZE - size.x + 1):
			if sim.world.grid.can_place(Vector2i(x, z), size):
				count += 1
	return count


func _key(sim: CitySim, b: Building) -> String:
	if b.archetype == StringName("water_facility"):
		return "water_facility:" + String(b.variant)
	return String(b.archetype)


func _first_of(sim: CitySim, b: Building) -> Vector2i:
	if b.archetype == StringName("water_facility"):
		var rules := sim.water.data.placeable_rules(String(b.variant))
		return sim.water.data.footprint_of(b.variant, 1, String(rules.get("subtype", "")))
	return sim.built_for(String(b.archetype), 1)


func _total(counts: Dictionary) -> int:
	var sum := 0
	for key in counts:
		sum += int(counts[key])
	return sum


func _fmt(counts: Dictionary) -> String:
	if counts.is_empty():
		return "{}"
	var parts: Array[String] = []
	var keys := counts.keys()
	keys.sort()
	for key in keys:
		parts.append("%s %d" % [key, int(counts[key])])
	return "(" + ", ".join(parts) + ")"
