extends SceneTree
## Headless test runner. Usage:
##   godot --headless --path "/home/bbx/Slacum City game" -s res://tests/run_tests.gd
##   tools/run_suite.sh
## Discovers tests/test_*.gd, runs every test_* method, exits 0 on success / 1 on failure.
##
## **Two runs of this file at once used to corrupt each other, whatever directory
## they were launched from.** `user://` is keyed on `application/config/name`,
## which every worktree and every checkout of this project shares, so two agents
## running the suite in two worktrees both wrote
## `~/.local/share/godot/app_userdata/Slacum City/saves` — and the save-service
## tests write real generations into real slots. Measured 2026-08-20: with a
## sibling suite running, `test_save_service.gd` failed
## `test_a_ruined_generation_falls_through_to_the_one_behind_it` and *aborted*
## `test_a_pinned_checkpoint_is_never_swept` on a missing manifest key — and an
## aborted method contributed no assert and no failure, so the run still printed
## ALL TESTS PASSED with a test that never ran.
##
## Both halves of that are closed here, and neither depends on how the run is
## invoked, because "remember the environment variable" is not a fix:
##
## **1. `user://` is moved to a per-process directory by `UserDirIsolation`**
## (`tests/user_dir_isolation.gd`), from inside `_initialize()`. Two suites can
## no longer see each other's saves however they are launched.
## `tools/run_suite.sh` is a convenience wrapper, not a requirement.
##
## **2. A test method that makes no assertion FAILS the run** — see
## `SimTest.end_test`. A GDScript runtime error unwinds one function and returns
## quietly to the caller, so "aborted" and "passed" used to look identical from
## here; now the assert counter is read on both sides of every method and a
## method that did not move it is reported by name.
##
## A green run prints `failed: 0` AND `silent: 0`.

const TESTS_DIR := "res://tests"


func _initialize() -> void:
	var isolation := UserDirIsolation.new().begin()

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
	var all_silent: Array[String] = []

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
			# The close is what turns "aborted on a runtime error" from an
			# invisible pass into a named failure. It must run even when the
			# method above died mid-way, which it does: a GDScript runtime error
			# unwinds `method_name` and nothing else.
			suite.end_test()
		total_asserts += suite.assert_count()
		all_failures.append_array(suite.failures())
		all_silent.append_array(suite.silent())

	print("")
	print("========================================")
	print("Slacum City sim tests")
	print("  files:   %d" % test_files.size())
	print("  tests:   %d" % total_tests)
	print("  asserts: %d" % total_asserts)
	print("  failed:  %d" % all_failures.size())
	print("  silent:  %d" % all_silent.size())
	print("  user://  %s" % isolation.user_dir)
	print("========================================")
	for failure in all_failures:
		printerr("FAIL " + failure)
	for method_name in all_silent:
		printerr("SILENT " + method_name
				+ " — ran without asserting anything (aborted, or empty)")

	var ok := all_failures.is_empty() and all_silent.is_empty()
	if ok:
		print("ALL TESTS PASSED")
	elif all_failures.is_empty():
		printerr("NOT PASSED: %d test method(s) never asserted. A method that "
				% all_silent.size()
				+ "aborts on a runtime error looks exactly like one that "
				+ "passed, so the suite refuses to call this green.")
	isolation.end()
	quit(0 if ok else 1)
