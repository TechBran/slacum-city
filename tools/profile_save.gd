extends SceneTree
## Save/load cost — the third leg of the profiling set.
##
## `tools/profile_sim.gd` answers "what does a sim step cost?",
## `tools/profile_frame.gd` answers "what does a frame cost?", and until this
## file there was no answer at all to **"what does committing the city to disk
## cost?"** — the question doc 08 §2.7's autosave cadence is written against and
## the one doc 13 §7 needs on a phone, where the flash and the CPU are both
## slower than a workstation's and the answer decides whether an autosave is
## allowed to happen on the main thread at all.
##
## It measures the SHIPPED path: `SaveService.save_slot` / `load_slot`, the same
## calls the lifecycle makes, into a scratch directory under `user://` that it
## creates and removes. Nothing in `sim/` is touched and no state hash moves —
## the save is a capture and the load is a restore of the same city.
##
## Usage:
##   ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
##       -s res://tools/profile_save.gd -- [options]
##
##   --city=PATH      city file (default res://data/starter_city.json)
##   --repeats=N      timed pairs, best-of reported as well as the mean (5)
##   --advance=H      game-hours to advance before saving, so the save carries a
##                    lived-in city rather than a freshly-booted one (0)
##   --quiet          table only

const CITY_DEFAULT := "res://data/starter_city.json"
const SCRATCH_DIR := "user://profile_save"


func _initialize() -> void:
	var opts := _parse(OS.get_cmdline_user_args())
	if opts.has("error"):
		printerr("profile_save: " + String(opts["error"]))
		quit(2)
		return
	var city_path := String(opts["city"])
	if not FileAccess.file_exists(city_path):
		printerr("profile_save: no such city file " + city_path)
		quit(2)
		return

	var sim := _boot(city_path)
	if sim == null:
		quit(2)
		return
	var hours := float(opts["advance"])
	if hours > 0.0:
		sim.advance_hours(hours)

	var service := SaveService.new()
	service.base_dir = SCRATCH_DIR
	service.log_io = false          # this file IS the report; the line would double it
	root.add_child(service)

	var saves := PackedFloat64Array()
	var loads := PackedFloat64Array()
	var bytes := 0
	var repeats := int(opts["repeats"])
	for i in repeats:
		var meta := service.save_slot(sim, 1, "manual")
		if meta.is_empty():
			printerr("profile_save: save failed — " + service.last_error)
			break
		saves.append(service.last_save_ms)
		bytes = maxi(bytes, _dir_bytes(service.slot_dir(1)))
		if not service.load_slot(sim, 1):
			printerr("profile_save: load failed — " + service.last_error)
			break
		loads.append(service.last_load_ms)

	if not bool(opts["quiet"]):
		print("profile_save: %s — %d buildings, +%.0f game-hours, %d repeats" % [
				city_path, sim.buildings.size(), hours, repeats])
	print("")
	print("=== SAVE / LOAD COST — %s ===" % city_path.get_file())
	print("  %-8s %10s %10s %10s %12s" % ["op", "best ms", "mean ms", "worst ms", "slot bytes"])
	print("  " + "-".repeat(56))
	_row("save", saves, bytes)
	_row("load", loads, bytes)
	print("  The slot is a doc 08 generation LADDER, so `slot bytes` is every")
	print("  generation on disk, not the size of one save.")

	_remove_tree(SCRATCH_DIR)
	quit(0)


func _row(name: String, values: PackedFloat64Array, bytes: int) -> void:
	if values.is_empty():
		print("  %-8s %10s" % [name, "no samples"])
		return
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for v in sorted:
		total += v
	print("  %-8s %10.2f %10.2f %10.2f %12d" % [name, sorted[0],
			total / float(sorted.size()), sorted[sorted.size() - 1], bytes])


func _boot(city_path: String) -> CitySim:
	var sim := CitySim.new()
	sim.boot(1337,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(city_path),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	for message in sim.boot_errors:
		printerr("profile_save: boot error: " + String(message))
	return sim


static func _dir_bytes(path: String) -> int:
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	var total := 0
	for name in dir.get_files():
		var f := FileAccess.open(path.path_join(name), FileAccess.READ)
		if f != null:
			total += int(f.get_length())
			f.close()
	return total


static func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for name in dir.get_directories():
		_remove_tree(path.path_join(name))
	for name in dir.get_files():
		dir.remove(name)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _parse(argv: PackedStringArray) -> Dictionary:
	var opts := {"city": CITY_DEFAULT, "repeats": 5, "advance": 0.0, "quiet": false}
	for raw in argv:
		var arg := String(raw)
		if arg == "--quiet":
			opts["quiet"] = true
		elif arg.begins_with("--city="):
			opts["city"] = arg.substr(7)
		elif arg.begins_with("--repeats="):
			opts["repeats"] = maxi(1, int(arg.substr(10)))
		elif arg.begins_with("--advance="):
			opts["advance"] = maxf(0.0, float(arg.substr(10)))
		else:
			opts["error"] = "unknown option: " + arg
	return opts
