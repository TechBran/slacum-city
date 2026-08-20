extends SceneTree
## Scratch runner: run one or more tests/test_*.gd files by name, for the tight
## edit loop. `tests/run_tests.gd` is still the suite of record.
##
##   godot --headless --path . -s res://tools/run_one.gd -- test_ui_incidents.gd
##
## Takes the gate's two guarantees, because a scratch runner that lies is worse
## than no scratch runner: `user://` is per-process (`UserDirIsolation`), and a
## method that ran without asserting anything is a failure (`SimTest.end_test`).

func _initialize() -> void:
	var isolation := UserDirIsolation.new().begin()
	var files: Array[String] = []
	for a in OS.get_cmdline_user_args():
		files.append(String(a))
	var total := 0
	var failures: Array[String] = []
	var silent: Array[String] = []
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
			suite.end_test()
		failures.append_array(suite.failures())
		silent.append_array(suite.silent())
	print("tests: %d  failed: %d  silent: %d" % [total, failures.size(), silent.size()])
	for f in failures:
		printerr("FAIL " + f)
	for n in silent:
		printerr("SILENT " + n + " — ran without asserting anything")
	var ok := failures.is_empty() and silent.is_empty()
	isolation.end()
	quit(0 if ok else 1)
