extends SceneTree
## Run ONE `tests/test_*.gd` suite. `tests/run_tests.gd` is the gate and runs
## everything; this is the inner loop while a single suite is being written.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/run_one_test.gd \
##       -- --file=test_power_infra.gd
##   tools/run_suite.sh --one=test_power_infra.gd
##
## It takes the same two guarantees the gate does, because the inner loop is
## exactly where a sibling run collides with you: `user://` is moved to a
## per-process directory (`UserDirIsolation`), and a test method that finishes
## without asserting anything is a FAILURE rather than a pass (`SimTest.end_test`).

## How many method rows the wall-clock table prints. Small on purpose: this is a
## trip-wire, and `tools/profile_gates.gd` is the instrument that prints all of
## them plus the per-agent-verb attribution underneath.
const TOP_METHODS := 8


func _initialize() -> void:
	var isolation := UserDirIsolation.new().begin()
	var file := ""
	for arg in OS.get_cmdline_user_args():
		if String(arg).begins_with("--file="):
			file = String(arg).substr(7)
	if file == "":
		printerr("run_one_test: --file=test_*.gd is required")
		isolation.end()
		quit(2)
		return
	var script: GDScript = load("res://tests/" + file)
	if script == null or not script.can_instantiate():
		printerr("run_one_test: cannot load res://tests/" + file)
		isolation.end()
		quit(2)
		return
	var suite: SimTest = script.new()
	var names: Array[String] = []
	for m in suite.get_method_list():
		if m.name.begins_with("test_"):
			names.append(m.name)
	names.sort()
	# The wall clock, per method (Wave 30, doc 92 §71, RR-246) — the same reading
	# `tests/run_tests.gd` prints, on the loop an agent actually watches. A file
	# is asked for by name here precisely when somebody is working on it, so the
	# slow method is named on every run rather than behind a flag.
	var method_usec: Array[Dictionary] = []
	for method_name in names:
		var t0 := Time.get_ticks_usec()
		suite.begin_test("%s::%s" % [file, method_name])
		suite.call(method_name)
		# Same guard the gate runs (`tests/run_tests.gd`): a method that ran
		# without asserting either aborted on a runtime error or is empty, and
		# from here the two look identical to a pass.
		suite.end_test()
		method_usec.append({"name": method_name,
				"usec": Time.get_ticks_usec() - t0})
	var wall := 0
	for row: Dictionary in method_usec:
		wall += int(row["usec"])
	method_usec.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["usec"]) != int(b["usec"]):
			return int(a["usec"]) > int(b["usec"])
		return String(a["name"]) < String(b["name"]))
	print("wall clock: %.1f s over %d method(s); slowest %d:"
			% [wall / 1e6, method_usec.size(), mini(TOP_METHODS, method_usec.size())])
	for i in mini(TOP_METHODS, method_usec.size()):
		var row: Dictionary = method_usec[i]
		print("  %8.1f s  %5.1f%%  %s" % [int(row["usec"]) / 1e6,
				100.0 * float(row["usec"]) / maxf(float(wall), 1.0), row["name"]])
	print("tests: %d  asserts: %d  failed: %d  silent: %d  wall: %.1fs  user:// %s"
			% [names.size(), suite.assert_count(), suite.failures().size(),
			suite.silent().size(), wall / 1e6, isolation.user_dir])
	for failure in suite.failures():
		printerr("FAIL " + failure)
	for method_name in suite.silent():
		printerr("SILENT " + method_name + " — ran without asserting anything")
	var ok := suite.failures().is_empty() and suite.silent().is_empty()
	isolation.end()
	quit(0 if ok else 1)
