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
	for method_name in names:
		suite.begin_test("%s::%s" % [file, method_name])
		suite.call(method_name)
		# Same guard the gate runs (`tests/run_tests.gd`): a method that ran
		# without asserting either aborted on a runtime error or is empty, and
		# from here the two look identical to a pass.
		suite.end_test()
	print("tests: %d  asserts: %d  failed: %d  silent: %d  user:// %s"
			% [names.size(), suite.assert_count(), suite.failures().size(),
			suite.silent().size(), isolation.user_dir])
	for failure in suite.failures():
		printerr("FAIL " + failure)
	for method_name in suite.silent():
		printerr("SILENT " + method_name + " — ran without asserting anything")
	var ok := suite.failures().is_empty() and suite.silent().is_empty()
	isolation.end()
	quit(0 if ok else 1)
