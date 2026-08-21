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
##   --async          drive `SaveService.async_writes` — the write half on a
##                    `WorkerThreadPool` task, the capture still on this thread.
##                    The `main` column is then what the FRAME pays and the
##                    `write` column is what the worker did with it; run it
##                    against the same city without the flag and the two columns
##                    are the A/B behind report 98 RR-44.
##   --boot-only      the `boot (cold sim)` row alone, plus the size of doc 04's
##                    warm-filled transformer memo — the A/B behind doc 10's
##                    Wave-12 open q4, without paying for a save and a load
##   --steps          additionally break `restore` into `CitySim.begin_restore()`'s
##                    resumable steps and print the per-step cost. The step COUNT
##                    is a property of the city — the road graph emits one trace
##                    step per node batch — so the rows are numbered and named,
##                    never named alone. This is the table doc 13 §2.9's
##                    loading-veil budget is written against: the LONGEST step is
##                    what a frame has to swallow, not the total.
##   --quiet          table only
##
## The table splits BOTH operations, because the two halves have different
## futures: a save is capture (main thread, determinism) + finalize-and-write
## (bytes, any thread), and a load is read (bytes: decompress, parse, digest,
## gate) + restore (main thread, rebuilds the live city). Doc 08 §2.14's
## streaming design is costed against the load split.

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

	if bool(opts["boot_only"]):
		_boot_table(city_path, int(opts["repeats"]))
		quit(0)
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

	service.async_writes = bool(opts["async"])

	var saves := PackedFloat64Array()
	var writes := PackedFloat64Array()
	var loads := PackedFloat64Array()
	var reads := PackedFloat64Array()
	var restores := PackedFloat64Array()
	var bytes := 0
	var repeats := int(opts["repeats"])
	for i in repeats:
		var meta := service.save_slot(sim, 1, "manual")
		if meta.is_empty():
			printerr("profile_save: save failed — " + service.last_error)
			break
		saves.append(service.last_save_ms)
		# The write has to have LANDED before the next line reads the slot; the
		# flush is what the `write` column measures on the async arm, and it is
		# also what every slot reader does on its own way in.
		service.flush_writes()
		writes.append(service.last_write_ms)
		bytes = maxi(bytes, _dir_bytes(service.slot_dir(1)))
		if not service.load_slot(sim, 1):
			printerr("profile_save: load failed — " + service.last_error)
			break
		loads.append(service.last_load_ms)
		reads.append(service.last_load_read_ms)
		restores.append(service.last_load_restore_ms)

	# The term in front of every other one, and the instrument had no row for it:
	# `CitySim.boot()` on a cold process. A LOAD does not pay it — the shell
	# constructs the sim once at launch and restores into it — but doc 04's
	# per-tile transformer memo is warm-filled there (doc 10's Wave-12 open q4),
	# so the cost of that memo now shows up here instead of inside `roads_signals`
	# below, and a table that could not see both ends of the move would have made
	# the move look free.
	var boots := PackedFloat64Array()
	for i in repeats:
		var t0 := Time.get_ticks_usec()
		var cold := _boot(city_path)
		boots.append(float(Time.get_ticks_usec() - t0) * 0.001)
		if cold != null:
			cold.scheduler.dispose()   # break the sim ↔ adapter cycle (doc 91 D-9)

	if not bool(opts["quiet"]):
		print("profile_save: %s — %d buildings, +%.0f game-hours, %d repeats" % [
				city_path, sim.buildings.size(), hours, repeats])
	print("")
	print("=== SAVE / LOAD COST — %s%s ===" % [city_path.get_file(),
			"  (async writes)" if bool(opts["async"]) else ""])
	print("  %-16s %10s %10s %10s %12s"
			% ["op", "best ms", "mean ms", "worst ms", "slot bytes"])
	print("  " + "-".repeat(64))
	_row("boot (cold sim)", boots, bytes)
	_row("save (caller)", saves, bytes)
	_row("  write half", writes, bytes)
	_row("load", loads, bytes)
	_row("  read half", reads, bytes)
	_row("  restore half", restores, bytes)
	print("  The slot is a doc 08 generation LADDER, so `slot bytes` is every")
	print("  generation on disk, not the size of one save.")
	print("  `save (caller)` is what the CALLING THREAD paid. With --async that is")
	print("  the capture alone and `write half` is the worker's; without it, the")
	print("  first is the sum of both. The float canonicalisation rides")
	print("  `SaveSection.finalize` into the write half either way (report 98 §24).")

	if bool(opts["steps"]):
		_step_table(sim, city_path, repeats)

	_remove_tree(SCRATCH_DIR)
	quit(0)


## `CitySim.begin_restore()` step by step. The body is read ONCE and replayed
## into a scratch sim per repeat, so what is timed is the restore and not the
## decompress in front of it.
func _step_table(sim: CitySim, city_path: String, repeats: int) -> void:
	var body: Dictionary = sim.canonical_capture()
	var totals: Dictionary = {}
	var labels: Array[String] = []
	for r in repeats:
		var target := _boot(city_path)
		if target == null:
			return
		var cursor := target.begin_restore(body)
		var index := 0
		while not cursor.is_done():
			# Positional, not by name: a step LABEL repeats (the road graph emits
			# one `graph_trace` per node batch), and keying the table by label alone
			# collapsed those rows onto one another — the table then showed the
			# cheapest trace batch and dropped the rest of the total on the floor.
			var label := "%02d %s" % [index, cursor.next_label()]
			index += 1
			var t0 := Time.get_ticks_usec()
			cursor.step()
			var ms := float(Time.get_ticks_usec() - t0) * 0.001
			if not totals.has(label):
				totals[label] = 1.0e30
				labels.append(label)
			totals[label] = minf(float(totals[label]), ms)
	print("")
	print("=== RESTORE STEPS — best of %d ===" % repeats)
	print("  %-20s %10s" % ["step", "best ms"])
	print("  " + "-".repeat(32))
	var worst := 0.0
	var sum := 0.0
	for label in labels:
		var ms := float(totals[label])
		sum += ms
		worst = maxf(worst, ms)
		print("  %-20s %10.2f" % [label, ms])
	print("  " + "-".repeat(32))
	print("  %-20s %10.2f" % ["total", sum])
	print("  %-20s %10.2f  <- doc 13 §2.9's per-frame worst case" % ["longest step", worst])


## `--boot-only`: the cold boot on its own, plus the size of the memo the Wave-14
## warm fill puts there. The memo is derived state with no accessor and does not
## want one — it is read here the way a profiler reads anything, by name, and a
## sim that has never heard of it reports 0 rather than failing.
func _boot_table(city_path: String, repeats: int) -> void:
	var boots := PackedFloat64Array()
	var memo := 0
	for i in repeats:
		var t0 := Time.get_ticks_usec()
		var cold := _boot(city_path)
		boots.append(float(Time.get_ticks_usec() - t0) * 0.001)
		if cold == null:
			return
		var cover: Variant = cold.get("_transformer_cover")
		memo = (cover as Dictionary).size() if cover is Dictionary else 0
		cold.scheduler.dispose()
	print("")
	print("=== COLD BOOT — %s, best of %d ===" % [city_path.get_file(), repeats])
	print("  %-16s %10s %10s %10s %12s"
			% ["op", "best ms", "mean ms", "worst ms", "slot bytes"])
	print("  " + "-".repeat(64))
	_row("boot (cold sim)", boots, 0)
	print("  transformer memo %10d tiles" % memo)


func _row(name: String, values: PackedFloat64Array, bytes: int) -> void:
	if values.is_empty():
		print("  %-16s %10s" % [name, "no samples"])
		return
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for v in sorted:
		total += v
	print("  %-16s %10.2f %10.2f %10.2f %12d" % [name, sorted[0],
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
	var opts := {"city": CITY_DEFAULT, "repeats": 5, "advance": 0.0,
			"quiet": false, "async": false, "steps": false, "boot_only": false}
	for raw in argv:
		var arg := String(raw)
		if arg == "--quiet":
			opts["quiet"] = true
		elif arg == "--async":
			opts["async"] = true
		elif arg == "--steps":
			opts["steps"] = true
		elif arg == "--boot-only":
			opts["boot_only"] = true
		elif arg.begins_with("--city="):
			opts["city"] = arg.substr(7)
		elif arg.begins_with("--repeats="):
			opts["repeats"] = maxi(1, int(arg.substr(10)))
		elif arg.begins_with("--advance="):
			opts["advance"] = maxf(0.0, float(arg.substr(10)))
		else:
			opts["error"] = "unknown option: " + arg
	return opts
