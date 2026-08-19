extends SceneTree
## Scratch runner: run one or more tests/test_*.gd files by name, for the tight
## edit loop. `tests/run_tests.gd` is still the suite of record.
##
##   godot --headless --path . -s res://tools/run_one.gd -- test_ui_incidents.gd

func _initialize() -> void:
	var files: Array[String] = []
	for a in OS.get_cmdline_user_args():
		files.append(String(a))
	var total := 0
	var failures: Array[String] = []
	for file in files:
		var script: GDScript = load("res://tests/" + file)
		if script == null or not script.can_instantiate():
			failures.append("%s: failed to load/compile" % file)
			continue
		var suite: SimTest = script.new()
		var names: Array[String] = []
		for m in suite.get_method_list():
			if m.name.begins_with("test_"):
				names.append(m.name)
		names.sort()
		for n in names:
			total += 1
			suite.begin_test("%s::%s" % [file, n])
			suite.call(n)
		failures.append_array(suite.failures())
	print("tests: %d  failed: %d" % [total, failures.size()])
	for f in failures:
		printerr("FAIL " + f)
	quit(1 if not failures.is_empty() else 0)
