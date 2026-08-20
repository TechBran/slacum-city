extends SceneTree
## Doc 92 §22.3's curriculum arrival table, on demand.
##
## `tests/test_balance_gates.gd` gate 21 asserts the BOUNDS; this prints the
## MEASUREMENT they are fitted to — the game-hour each curriculum level is
## earned, per seed, plus the verb counters the arc drives. It exists because a
## re-arc of `data/goals.json` moves those hours and the doc has to be re-derived
## rather than re-asserted.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/measure_curriculum.gd \
##       -- [--days=21] [--seeds=1337,4242,9001] [--strategy=curriculum]
##
## Same rig `tests/balance_gate_rig.gd` uses, so a number printed here is the
## number the gate reads.

const DEFAULT_DAYS := 21
const DEFAULT_SEEDS: Array[int] = [1337, 4242, 9001]
const HOURS_PER_DAY := 24


func _initialize() -> void:
	var days := DEFAULT_DAYS
	var seeds := DEFAULT_SEEDS.duplicate()
	var strategy := "curriculum"
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--days="):
			days = int(arg.substr(7))
		elif arg.begins_with("--strategy="):
			strategy = arg.substr(11)
		elif arg.begins_with("--seeds="):
			seeds = [] as Array[int]
			for part in arg.substr(8).split(","):
				seeds.append(int(part))

	var top := GoalSystem.top_level()
	print("curriculum: %d levels, strategy=%s, %d game-days" % [top, strategy, days])
	var header := "| level "
	for seed_value in seeds:
		header += "| %6d " % int(seed_value)
	print(header + "| duration (game-hours) |")

	var runs: Array[Dictionary] = []
	for seed_value in seeds:
		runs.append(BalanceGateRig.run(strategy, int(seed_value), days))

	var earned: Array[Dictionary] = []
	for run: Dictionary in runs:
		earned.append(_first_hour_at(run))

	for level in range(1, top + 1):
		var row := "| %5d " % level
		var lo := 1 << 30
		var hi := -1
		for i in earned.size():
			var hour := int((earned[i] as Dictionary).get(level, -1))
			row += "| %6s " % (str(hour) if hour >= 0 else "—")
			if hour < 0:
				continue
			var previous := int((earned[i] as Dictionary).get(level - 1, 0))
			var duration := hour - previous
			lo = mini(lo, duration)
			hi = maxi(hi, duration)
		print(row + "| %s |" % ("—" if hi < 0 else ("%d" % lo if lo == hi else "%d–%d" % [lo, hi])))

	print("")
	for key: String in ["goal_level_end", "city_level_end", "road_tiles_built",
			"road_spend", "repaired", "repair_spend", "water_placed", "water_spend",
			"tax_changes", "treasury_end", "population_end"]:
		var cells := ""
		for run: Dictionary in runs:
			cells += "%14s" % str((run["summary"] as Dictionary).get(key, "—"))
		print("%-20s%s" % [key, cells])
	print("")
	for i in runs.size():
		print("seed %d  state_hash %s" % [int(seeds[i]),
				str((runs[i] as Dictionary).get("state_hash", ""))])
	quit(0)


## Objective level → the first game-hour a sample carried it. Level 0 is the
## founding hour, so a duration is always `hour(N) − hour(N−1)`.
func _first_hour_at(run: Dictionary) -> Dictionary:
	var out: Dictionary = {0: 0}
	for entry: Variant in (run["samples"] as Array):
		var sample: Dictionary = entry
		var level := int(sample.get("goal_level", 0))
		if level > 0 and not out.has(level):
			out[level] = int(sample["h"])
	return out
