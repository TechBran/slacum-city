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

## A file quiet enough to be noise. One second: the suite has ~90 files and a
## ninety-row table of near-zeroes is a table nobody reads.
const WALL_FILE_FLOOR_USEC := 1_000_000
const WALL_TOP_METHODS := 12


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
	# `-- --file=<substring> --method=<substring>`: run one file or one method
	# alone. Added 2026-09-01, when a fleet of sibling suites made wall-clock
	# budget asserts flake under load and the only way to re-check one failure
	# was the whole 10-minute run — and when a verifier needs to re-run a single
	# named failure, "the whole suite again" is not an answer. Filters are
	# substrings; the summary still refuses green on silent methods.
	var file_filter := ""
	var method_filter := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--file="):
			file_filter = arg.trim_prefix("--file=")
		elif arg.begins_with("--method="):
			method_filter = arg.trim_prefix("--method=")
	if file_filter != "":
		test_files = test_files.filter(func(f: String) -> bool: return f.contains(file_filter))
		print("filter: files containing '%s' -> %d file(s)" % [file_filter, test_files.size()])

	var total_tests := 0
	var total_asserts := 0
	var all_failures: Array[String] = []
	var all_silent: Array[String] = []
	# **The wall clock, per file and per method** (Wave 30, doc 92 §71, RR-246).
	# Wave 26 put a 4,096-preview site scan inside the scripted agent's `act()`
	# and this suite went from ~15 minutes to ~65 with nothing in the log to say
	# so — four waves of runs, every one of them slower than the last, and the
	# only number any of them printed was `tests:`. Two `Time.get_ticks_usec()`
	# reads per method are what it costs to make the next one a number instead of
	# a memory. See `_print_wall_clock` for what is printed and why not all of it.
	var file_usec: Dictionary = {}     # file -> int
	var method_usec: Array[Dictionary] = []

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
		if method_filter != "":
			method_names = method_names.filter(func(m: String) -> bool: return m.contains(method_filter))
		for method_name in method_names:
			total_tests += 1
			var t0 := Time.get_ticks_usec()
			suite.begin_test("%s::%s" % [file, method_name])
			suite.call(method_name)
			# The close is what turns "aborted on a runtime error" from an
			# invisible pass into a named failure. It must run even when the
			# method above died mid-way, which it does: a GDScript runtime error
			# unwinds `method_name` and nothing else.
			suite.end_test()
			var usec := Time.get_ticks_usec() - t0
			file_usec[file] = int(file_usec.get(file, 0)) + usec
			method_usec.append({"name": "%s::%s" % [file, method_name], "usec": usec})
		total_asserts += suite.assert_count()
		all_failures.append_array(suite.failures())
		all_silent.append_array(suite.silent())

	_print_wall_clock(file_usec, method_usec)

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


## **The wall clock, printed where the next regression will be read.**
##
## Two tables and a deliberate cut-off. Every file that spent at least
## [WALL_FILE_FLOOR_USEC] gets a row, because a file under a second cannot hide a
## regression worth chasing. The slowest [WALL_TOP_METHODS] individual methods
## follow, because a file total says WHICH file and a method name says WHERE —
## Wave 26's regression was one method in one file and both halves are needed to
## find the next one in a single reading.
##
## `tools/profile_gates.gd` is the instrument for the deeper look (every method
## of one file, and the per-agent-verb table underneath); this is the trip-wire
## that says whether to reach for it.
static func _print_wall_clock(file_usec: Dictionary, method_usec: Array[Dictionary]) -> void:
	var files: Array[Dictionary] = []
	var total := 0
	for name: Variant in file_usec:
		total += int(file_usec[name])
		if int(file_usec[name]) >= WALL_FILE_FLOOR_USEC:
			files.append({"name": String(name), "usec": int(file_usec[name])})
	files.sort_custom(_by_usec_then_name)
	var methods: Array[Dictionary] = method_usec.duplicate()
	methods.sort_custom(_by_usec_then_name)

	print("")
	print("---------------- wall clock (%.1f s in test methods) ----------------"
			% (total / 1e6))
	for row: Dictionary in files:
		print("  %8.1f s  %5.1f%%  %s" % [int(row["usec"]) / 1e6,
				100.0 * float(row["usec"]) / maxf(float(total), 1.0), row["name"]])
	print("  slowest %d method(s):" % mini(WALL_TOP_METHODS, methods.size()))
	for i in mini(WALL_TOP_METHODS, methods.size()):
		var row: Dictionary = methods[i]
		print("  %8.1f s  %5.1f%%  %s" % [int(row["usec"]) / 1e6,
				100.0 * float(row["usec"]) / maxf(float(total), 1.0), row["name"]])


## Slowest first, name as the tie-break, so two runs of the same tree print the
## same order.
static func _by_usec_then_name(a: Dictionary, b: Dictionary) -> bool:
	if int(a["usec"]) != int(b["usec"]):
		return int(a["usec"]) > int(b["usec"])
	return String(a["name"]) < String(b["name"])
