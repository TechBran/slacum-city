extends SceneTree
## **The dark-share curve** — gate 18b's own reading, on demand, with the grid
## purchases that produced it (Wave 24, doc 92 §63.3).
##
## `tests/test_balance_gates.gd` gate 18b asserts ONE cell of this: `balanced`,
## seed 1337, 50 game-days, against a ruled ceiling. That single cell is not
## enough to answer the question Wave 24 had to answer — *does a rich city
## outrun its own grid, or does a REACTIVE AGENT outrun it?* — because the two
## have the same signature at one horizon on one agent. This prints the curve:
## every strategy the caller names, every seed, at a horizon, with the columns
## that say what the city BOUGHT while it was going dark.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/measure_dark_share.gd \
##       -- [--days=50] [--seeds=1337,4242,9001] [--strategies=balanced,grid_planner]
##
## Same rig `tests/balance_gate_rig.gd` uses, so a number printed here is the
## number the gate reads. It owns no constant of its own (constitution §3).

const DEFAULT_DAYS := 50
const DEFAULT_SEEDS: Array[int] = [1337, 4242, 9001]
const DEFAULT_STRATEGIES: Array[String] = ["balanced"]


func _initialize() -> void:
	var days := DEFAULT_DAYS
	var seeds := DEFAULT_SEEDS.duplicate()
	var strategies := DEFAULT_STRATEGIES.duplicate()
	for raw: Variant in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--days="):
			days = int(arg.substr(7))
		elif arg.begins_with("--seeds="):
			seeds = [] as Array[int]
			for part in arg.substr(8).split(","):
				seeds.append(int(part))
		elif arg.begins_with("--strategies="):
			strategies = [] as Array[String]
			for part in arg.substr(13).split(","):
				strategies.append(String(part))

	print("dark share, %d game-days, standard preset" % days)
	print("| strategy | seed | dark % | taps | feeders | subs | worst feeder | "
			+ "buildings | upgrades | treasury |")
	print("|---|---|---|---|---|---|---|---|---|---|")
	for strategy: String in strategies:
		var totals := 0.0
		for raw_seed: Variant in seeds:
			var seed_value := int(raw_seed)
			var doc := BalanceGateRig.run(strategy, seed_value, days)
			var s: Dictionary = doc["summary"]
			totals += float(s["unserved_share"])
			print("| %s | %d | **%.2f** | %d | %d | %d | %.2f | %d | %d | $%d |"
					% [strategy, seed_value, 100.0 * float(s["unserved_share"]),
					int(s["grid_placed"]), int(s["feeders_routed"]),
					int(s["substations_built"]), float(s["feeder_peak_ratio_end"]),
					int(s["buildings_end"]), int(s["upgraded"]),
					int(s["treasury_end"])])
		print("| %s | MEAN | **%.2f** |  |  |  |  |  |  |  |"
				% [strategy, 100.0 * totals / float(maxi(seeds.size(), 1))])
	quit(0)
