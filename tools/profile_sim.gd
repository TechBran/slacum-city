extends SceneTree
## Headless performance harness for the integrated sim.
##
## It answers two questions and nothing else:
##   1. WHERE does a step spend its time?  (per-phase / per-system table,
##      driven by TickScheduler's opt-in `profile_enter/profile_exit` hook —
##      the scheduler owns no clock, this tool does the measuring.)
##   2. Did an optimization CHANGE ANYTHING?  (`state_hash()` of the same seed
##      after the same advance, compared against a recorded baseline.)
##
## Like tools/playtest.gd this is a MEASURING instrument: it boots the real
## `CitySim`, drives the real scheduler, owns no constant of its own, and is
## never imported by `sim/` (constitution §3).
##
## Usage:
##   ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
##       -s res://tools/profile_sim.gd -- [options]
##
##   --seed=N            RNG seed                                (default 1337)
##   --fine-hours=F      game-hours advanced on the fine path    (default 2)
##   --coarse-hours=N    game-hours advanced on the coarse path  (default 24)
##   --repeats=N         timing repeats, best run wins           (default 1)
##   --no-profile        wall-clock totals only (no per-system hook)
##   --hash-only         skip timing, print the two state hashes and exit
##   --baseline=FILE     compare against a saved JSON run; non-zero exit on
##                       any state_hash mismatch
##   --out=FILE          write this run's JSON (hashes + per-system usec)
##   --quiet             table only, no progress lines
##
## Typical optimization loop:
##   ... --out=/tmp/before.json          # record
##   <edit sim/>
##   ... --baseline=/tmp/before.json     # must print HASH OK for both paths
const DEFAULT_SEED := 1337
const DEFAULT_FINE_HOURS := 2.0
const DEFAULT_COARSE_HOURS := 24

var _timer_stack: Array[int] = []
var _timer_ids: Array[StringName] = []
var _usec: Dictionary = {}   # StringName -> int (self time, children excluded)
var _calls: Dictionary = {}  # StringName -> int
var _child_usec: int = 0


func _initialize() -> void:
	var opts := _parse(OS.get_cmdline_user_args())
	if not opts.errors.is_empty():
		for message in opts.errors:
			printerr("profile_sim: " + message)
		quit(2)
		return

	var baseline: Dictionary = {}
	if opts.baseline != "":
		var text := FileAccess.get_file_as_string(opts.baseline)
		if text == "":
			printerr("profile_sim: cannot read baseline " + opts.baseline)
			quit(2)
			return
		var parsed: Variant = JSON.parse_string(text)
		if typeof(parsed) != TYPE_DICTIONARY:
			printerr("profile_sim: baseline is not a JSON object")
			quit(2)
			return
		baseline = parsed

	var result := {
		"seed": opts.seed,
		"fine_hours": opts.fine_hours,
		"coarse_hours": opts.coarse_hours,
	}

	# ---------------------------------------------------------- identity pass
	# Always first, always unprofiled: the hook must never be able to explain
	# away a hash difference.
	if not opts.quiet:
		print("profile_sim: identity pass (seed %d)" % opts.seed)
	result["hash_coarse"] = _hash_after_coarse(opts.seed, opts.coarse_hours)
	result["hash_fine"] = _hash_after_fine(opts.seed, opts.fine_hours)
	print("state_hash  coarse %dh : %s" % [opts.coarse_hours, result["hash_coarse"]])
	print("state_hash  fine  %sh : %s" % [opts.fine_hours, result["hash_fine"]])

	var hash_failed := false
	if not baseline.is_empty():
		hash_failed = not _compare_hashes(baseline, result)

	if opts.hash_only:
		_maybe_write(opts.out, result)
		quit(1 if hash_failed else 0)
		return

	# ------------------------------------------------------------ timing pass
	var fine_ticks := roundi(opts.fine_hours * GameClock.TICKS_PER_HOUR)
	var best_fine := {}
	var best_coarse := {}
	for r in opts.repeats:
		var fine_run := _time_fine(opts.seed, fine_ticks, not opts.no_profile)
		var coarse_run := _time_coarse(opts.seed, opts.coarse_hours, not opts.no_profile)
		if best_fine.is_empty() or float(fine_run["wall_usec"]) < float(best_fine["wall_usec"]):
			best_fine = fine_run
		if best_coarse.is_empty() or float(coarse_run["wall_usec"]) < float(best_coarse["wall_usec"]):
			best_coarse = coarse_run
		if not opts.quiet and opts.repeats > 1:
			print("  repeat %d/%d done" % [r + 1, opts.repeats])
	result["fine"] = best_fine
	result["coarse"] = best_coarse

	_print_headline(best_fine, best_coarse)
	if not opts.no_profile:
		_print_table("COARSE step (1 game-hour)", best_coarse,
				baseline.get("coarse", {}) if typeof(baseline.get("coarse")) == TYPE_DICTIONARY else {})
		_print_table("FINE step (1 SimTick, 15 game-s)", best_fine,
				baseline.get("fine", {}) if typeof(baseline.get("fine")) == TYPE_DICTIONARY else {})

	_maybe_write(opts.out, result)
	quit(1 if hash_failed else 0)


# --------------------------------------------------------------- identity

func _hash_after_coarse(seed_value: int, hours: int) -> String:
	var sim := CitySim.boot_from_files(seed_value)
	sim.advance_coarse_hours(hours)
	return sim.state_hash()


func _hash_after_fine(seed_value: int, hours: float) -> String:
	var sim := CitySim.boot_from_files(seed_value)
	sim.advance_hours(hours)
	return sim.state_hash()


func _compare_hashes(baseline: Dictionary, result: Dictionary) -> bool:
	var ok := true
	for key in ["hash_coarse", "hash_fine"]:
		var was := String(baseline.get(key, ""))
		if was == "":
			continue
		var now := String(result.get(key, ""))
		if was == now:
			print("HASH OK      %s  %s" % [key, now.substr(0, 16)])
		else:
			ok = false
			printerr("HASH CHANGED %s\n  baseline %s\n  now      %s" % [key, was, now])
	if ok:
		print("BEHAVIOUR UNCHANGED vs baseline.")
	else:
		printerr("BEHAVIOUR CHANGED — this is a bug in the optimization, not a new baseline.")
	return ok


# ----------------------------------------------------------------- timing

func _time_fine(seed_value: int, ticks: int, profiled: bool) -> Dictionary:
	var sim := CitySim.boot_from_files(seed_value)
	_reset()
	if profiled:
		_attach(sim.scheduler)
	var t0 := Time.get_ticks_usec()
	sim.scheduler.advance_fine_n(ticks)
	var wall := Time.get_ticks_usec() - t0
	_detach(sim.scheduler)
	return _run_record(wall, ticks)


func _time_coarse(seed_value: int, hours: int, profiled: bool) -> Dictionary:
	var sim := CitySim.boot_from_files(seed_value)
	_reset()
	if profiled:
		_attach(sim.scheduler)
	var t0 := Time.get_ticks_usec()
	sim.advance_coarse_hours(hours)
	var wall := Time.get_ticks_usec() - t0
	_detach(sim.scheduler)
	return _run_record(wall, hours)


func _run_record(wall_usec: int, steps: int) -> Dictionary:
	var systems: Dictionary = {}
	for id in _usec:
		systems[String(id)] = {"usec": int(_usec[id]), "calls": int(_calls[id])}
	return {"wall_usec": wall_usec, "steps": steps, "systems": systems}


func _attach(scheduler: TickScheduler) -> void:
	scheduler.profile_enter = _enter
	scheduler.profile_exit = _exit
	scheduler.profiling = true


func _detach(scheduler: TickScheduler) -> void:
	scheduler.profiling = false
	scheduler.profile_enter = Callable()
	scheduler.profile_exit = Callable()


func _reset() -> void:
	_usec.clear()
	_calls.clear()
	_timer_stack.clear()
	_timer_ids.clear()
	_child_usec = 0


## Self-time accounting: each frame carries the child time charged beneath it,
## so a nested hook (none today, but the scheduler may grow sub-phases) never
## double-counts into its parent.
func _enter(id: StringName) -> void:
	_timer_ids.append(id)
	_timer_stack.append(Time.get_ticks_usec())
	_timer_stack.append(_child_usec)
	_child_usec = 0


func _exit(_id: StringName) -> void:
	var now := Time.get_ticks_usec()
	var parent_children: int = _timer_stack.pop_back()
	var started: int = _timer_stack.pop_back()
	var id: StringName = _timer_ids.pop_back()
	var total := now - started
	var self_time := total - _child_usec
	_usec[id] = int(_usec.get(id, 0)) + self_time
	_calls[id] = int(_calls.get(id, 0)) + 1
	_child_usec = parent_children + total


# ------------------------------------------------------------------ output

func _print_headline(fine: Dictionary, coarse: Dictionary) -> void:
	var fine_steps: int = maxi(1, int(fine.get("steps", 1)))
	var coarse_steps: int = maxi(1, int(coarse.get("steps", 1)))
	print("")
	print("=== HEADLINE (best of run; debug headless) ===")
	print("  coarse step   %8.3f ms/hour   (%d hours, %.1f ms total)" % [
			float(coarse["wall_usec"]) / 1000.0 / coarse_steps, coarse_steps,
			float(coarse["wall_usec"]) / 1000.0])
	print("  fine tick     %8.4f ms/tick   (%d ticks, %.1f ms total)" % [
			float(fine["wall_usec"]) / 1000.0 / fine_steps, fine_steps,
			float(fine["wall_usec"]) / 1000.0])
	print("  fine game-hr  %8.3f ms/hour   (240 ticks at that rate)" % [
			float(fine["wall_usec"]) / 1000.0 / fine_steps * GameClock.TICKS_PER_HOUR])
	print("  12h catch-up  %8.3f s          (doc 01 budget: 2 s)" % [
			float(coarse["wall_usec"]) / 1e6 / coarse_steps * 12.0])


func _print_table(title: String, run: Dictionary, was: Dictionary) -> void:
	var systems: Dictionary = run.get("systems", {})
	if systems.is_empty():
		return
	var steps: int = maxi(1, int(run.get("steps", 1)))
	var prev: Dictionary = was.get("systems", {}) if typeof(was.get("systems")) == TYPE_DICTIONARY else {}
	var prev_steps: int = maxi(1, int(was.get("steps", 1)))
	var rows: Array = []
	var total := 0
	for key in systems:
		var usec := int(systems[key]["usec"])
		total += usec
		rows.append({"id": key, "usec": usec, "calls": int(systems[key]["calls"])})
	rows.sort_custom(func(a, b): return a["usec"] > b["usec"])
	print("")
	print("=== %s ===" % title)
	var header := "  %-22s %10s %8s %9s %7s" % ["system", "ms/step", "share", "calls/step", "before"]
	print(header)
	print("  " + "-".repeat(header.length()))
	for row in rows:
		var per_step := float(row["usec"]) / 1000.0 / steps
		var before := ""
		if prev.has(row["id"]):
			var b := float(prev[row["id"]]["usec"]) / 1000.0 / prev_steps
			before = "%7.3f" % b
		print("  %-22s %10.4f %7.1f%% %9.2f %7s" % [
				row["id"], per_step, 100.0 * float(row["usec"]) / maxf(1.0, float(total)),
				float(row["calls"]) / steps, before])
	print("  %-22s %10.4f" % ["TOTAL (hooked)", float(total) / 1000.0 / steps])


func _maybe_write(path: String, result: Dictionary) -> void:
	if path == "":
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("profile_sim: cannot write " + path)
		return
	f.store_string(JSON.stringify(result, "  ", true, true))
	f.close()
	print("wrote " + path)


# ------------------------------------------------------------------- options

class Options:
	var seed: int = DEFAULT_SEED
	var fine_hours: float = DEFAULT_FINE_HOURS
	var coarse_hours: int = DEFAULT_COARSE_HOURS
	var repeats: int = 1
	var no_profile: bool = false
	var hash_only: bool = false
	var baseline: String = ""
	var out: String = ""
	var quiet: bool = false
	var errors: PackedStringArray = PackedStringArray()


func _parse(argv: PackedStringArray) -> Options:
	var opts := Options.new()
	for raw in argv:
		var arg := String(raw)
		if arg == "--no-profile":
			opts.no_profile = true
		elif arg == "--hash-only":
			opts.hash_only = true
		elif arg == "--quiet":
			opts.quiet = true
		elif arg.begins_with("--seed="):
			opts.seed = int(arg.substr(7))
		elif arg.begins_with("--fine-hours="):
			opts.fine_hours = float(arg.substr(13))
		elif arg.begins_with("--coarse-hours="):
			opts.coarse_hours = int(arg.substr(15))
		elif arg.begins_with("--repeats="):
			opts.repeats = maxi(1, int(arg.substr(10)))
		elif arg.begins_with("--baseline="):
			opts.baseline = arg.substr(11)
		elif arg.begins_with("--out="):
			opts.out = arg.substr(6)
		else:
			opts.errors.append("unknown option: " + arg)
	if opts.fine_hours < 0.0:
		opts.errors.append("--fine-hours must be >= 0")
	if opts.coarse_hours < 0:
		opts.errors.append("--coarse-hours must be >= 0")
	return opts
