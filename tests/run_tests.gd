extends SceneTree
## Headless test runner. Usage:
##   godot --headless --path "/home/bbx/Slacum City game" -s res://tests/run_tests.gd
## Discovers tests/test_*.gd, runs every test_* method, exits 0 on success / 1 on failure.

const TESTS_DIR := "res://tests"


func _initialize() -> void:
	var test_files: Array[String] = []
	var dir := DirAccess.open(TESTS_DIR)
	if dir == null:
		push_error("Cannot open tests directory")
		quit(1)
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.begins_with("test_") and entry.ends_with(".gd"):
			test_files.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	test_files.sort()

	var total_tests := 0
	var total_asserts := 0
	var all_failures: Array[String] = []

	for file in test_files:
		var script: GDScript = load(TESTS_DIR + "/" + file)
		if script == null or not script.can_instantiate():
			all_failures.append("%s: failed to load/compile script" % file)
			continue
		var instance: Object = script.new()
		if not (instance is SimTest):
			all_failures.append("%s: does not extend SimTest" % file)
			continue
		var suite: SimTest = instance
		var method_names: Array[String] = []
		for m in suite.get_method_list():
			if m.name.begins_with("test_"):
				method_names.append(m.name)
		method_names.sort()
		for method_name in method_names:
			total_tests += 1
			suite.begin_test("%s::%s" % [file, method_name])
			suite.call(method_name)
		total_asserts += suite.assert_count()
		all_failures.append_array(suite.failures())

	print("")
	print("========================================")
	print("Slacum City sim tests")
	print("  files:   %d" % test_files.size())
	print("  tests:   %d" % total_tests)
	print("  asserts: %d" % total_asserts)
	print("  failed:  %d" % all_failures.size())
	print("========================================")
	for failure in all_failures:
		printerr("FAIL " + failure)
	if all_failures.is_empty():
		print("ALL TESTS PASSED")
		quit(0)
	else:
		quit(1)
