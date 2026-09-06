extends SceneTree
## **Where the suite's wall clock goes — per test method, and per agent verb**
## (Wave 30, doc 92 §71, report 98 RR-244).
##
## `tools/profile_sim.gd` profiles the SIM: it boots a city, advances it and
## charges each tick phase for its microseconds. That instrument could not see
## this wave's regression at all, because `tests/test_balance_gates.gd` spends
## most of its wall clock in the scripted agent's `act()` — the gap BETWEEN two
## ticks, which the sim profiler charges to nobody. Wave 26 put a 4,096-preview
## site scan inside that gap and the suite went from ~15 minutes to ~65 with no
## number anywhere naming the cause. This file is the missing half.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/profile_gates.gd -- \
##       [--file=test_balance_gates.gd] [--method=<substring>] [--verbs] [--top=N]
##
##   --file=NAME       the `tests/` suite to time      (default test_balance_gates.gd)
##   --method=SUB      only methods whose name contains SUB
##   --verbs           also open `Playtest.Clock` and print the per-verb table
##   --top=N           how many verb rows to print     (default 24; 0 = all)
##
## It runs the real methods through the real `SimTest` bracket and reports the
## real verdict, so it is a slower runner and never a second, laxer one: a gate
## that fails here fails in `tests/run_tests.gd`, and the exit code says so.
##
## **`--verbs` costs wall clock and must not be read as a wall-clock baseline.**
## The clock takes two `Time.get_ticks_usec()` readings and one allocation per
## instrumented verb call; on a run that makes a million of them that is real
## money. Read the per-method table from a run WITHOUT `--verbs` and the
## attribution from a run with it — which is why the two tables are separately
## switchable rather than one report.

const Playtest := preload("res://tools/playtest.gd")

const DEFAULT_FILE := "test_balance_gates.gd"
const DEFAULT_TOP := 24
const TESTS_DIR := "res://tests/"


func _initialize() -> void:
	var isolation := UserDirIsolation.new().begin()
	var file := DEFAULT_FILE
	var method_filter := ""
	var verbs := false
	var top := DEFAULT_TOP
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--file="):
			file = arg.substr(7)
		elif arg.begins_with("--method="):
			method_filter = arg.substr(9)
		elif arg == "--verbs":
			verbs = true
		elif arg.begins_with("--top="):
			top = int(arg.substr(6))

	var script: GDScript = load(TESTS_DIR + file)
	if script == null or not script.can_instantiate():
		printerr("profile_gates: cannot load " + TESTS_DIR + file)
		isolation.end()
		quit(2)
		return
	var suite: SimTest = script.new()
	var names: Array[String] = []
	for m in suite.get_method_list():
		if m.name.begins_with("test_") and (method_filter == "" or m.name.contains(method_filter)):
			names.append(m.name)
	names.sort()

	if verbs:
		Playtest.Clock.enabled = true
		Playtest.Clock.reset()

	print("profile_gates: %s — %d method(s)%s"
			% [file, names.size(), "  [verb clock ON — wall times inflated]" if verbs else ""])
	var rows: Array[Dictionary] = []
	var wall_total := 0
	for method_name in names:
		var t0 := Time.get_ticks_usec()
		suite.begin_test("%s::%s" % [file, method_name])
		suite.call(method_name)
		suite.end_test()
		var usec := Time.get_ticks_usec() - t0
		wall_total += usec
		rows.append({"method": method_name, "usec": usec})
	Playtest.Clock.enabled = false

	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["usec"]) != int(b["usec"]):
			return int(a["usec"]) > int(b["usec"])
		return String(a["method"]) < String(b["method"]))

	print("")
	print("| seconds | share | cum | test method |")
	print("|---:|---:|---:|---|")
	var cumulative := 0
	for row: Dictionary in rows:
		cumulative += int(row["usec"])
		print("| %7.2f | %4.1f%% | %4.1f%% | %s |"
				% [int(row["usec"]) / 1e6,
				100.0 * float(row["usec"]) / maxf(float(wall_total), 1.0),
				100.0 * float(cumulative) / maxf(float(wall_total), 1.0),
				row["method"]])
	print("| %7.2f |  100%% |       | **%d method(s), total** |"
			% [wall_total / 1e6, rows.size()])

	if verbs:
		_print_verbs(top, wall_total)

	print("")
	print("tests: %d  asserts: %d  failed: %d  silent: %d  wall: %.1fs"
			% [names.size(), suite.assert_count(), suite.failures().size(),
			suite.silent().size(), wall_total / 1e6])
	for failure in suite.failures():
		printerr("FAIL " + failure)
	for method_name in suite.silent():
		printerr("SILENT " + method_name + " — ran without asserting anything")
	var ok := suite.failures().is_empty() and suite.silent().is_empty()
	isolation.end()
	quit(0 if ok else 1)


## The `Playtest.Api` verb table. SELF microseconds first — a verb's own time
## with its callees' excluded — because that is the column that names the code
## to change; `total` beside it is the inclusive figure, which is the column
## that names the call to stop making.
func _print_verbs(top: int, wall_total: int) -> void:
	var rows := Playtest.Clock.rows()
	var self_total := 0
	for row: Dictionary in rows:
		self_total += int(row["self_usec"])
	print("")
	print("| self s | share | total s | calls | µs/call | agent verb |")
	print("|---:|---:|---:|---:|---:|---|")
	var shown := 0
	for row: Dictionary in rows:
		if top > 0 and shown >= top:
			break
		shown += 1
		print("| %6.2f | %4.1f%% | %7.2f | %8d | %7.1f | `%s` |"
				% [int(row["self_usec"]) / 1e6,
				100.0 * float(row["self_usec"]) / maxf(float(self_total), 1.0),
				int(row["total_usec"]) / 1e6, int(row["calls"]),
				float(row["self_usec"]) / maxf(float(row["calls"]), 1.0),
				row["verb"]])
	print("| %6.2f |  100%% |         |          |         | **%d instrumented verb(s)** |"
			% [self_total / 1e6, rows.size()])
	print("")
	print("profile_gates: instrumented verbs account for %.2f s of the run's %.2f s "
			% [self_total / 1e6, wall_total / 1e6]
			+ "(%.1f %%); the remainder is the sim advance, the rig's sampling and "
			% (100.0 * float(self_total) / maxf(float(wall_total), 1.0))
			+ "the strategy code between verbs.")
