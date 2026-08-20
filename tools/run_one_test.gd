extends SceneTree
## Run ONE `tests/test_*.gd` suite. `tests/run_tests.gd` is the gate and runs
## everything; this is the inner loop while a single suite is being written.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/run_one_test.gd \
##       -- --file=test_power_infra.gd


func _initialize() -> void:
	var file := ""
	for arg in OS.get_cmdline_user_args():
		if String(arg).begins_with("--file="):
			file = String(arg).substr(7)
	if file == "":
		printerr("run_one_test: --file=test_*.gd is required")
		quit(2)
		return
	var script: GDScript = load("res://tests/" + file)
	if script == null or not script.can_instantiate():
		printerr("run_one_test: cannot load res://tests/" + file)
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
	print("tests: %d  asserts: %d  failed: %d"
			% [names.size(), suite.assert_count(), suite.failures().size()])
	for failure in suite.failures():
		printerr("FAIL " + failure)
	quit(0 if suite.failures().is_empty() else 1)
