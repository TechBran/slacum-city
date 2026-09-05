extends SceneTree
## **The balance gates' own summary columns, printed** (Wave 24, doc 92 §63.7).
##
## `tests/test_balance_gates.gd` asserts BOUNDS on
## `BalanceGateRig.run(...)["summary"]`; when a bound fails, the gate prints the
## one cell it tripped on and nothing else, so a lane that has to re-derive a
## bound has to guess at the row around it. This prints the whole row, on the
## gates' own rig, for any strategy / seed / horizon — so a re-fit is argued
## against a table rather than against an error message.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/measure_gate_row.gd \
##       -- [--days=21] [--seeds=1337,4242,9001]
##          [--strategies=balanced,disaster_neglect,tax_squeezer]
##
## It owns no constant and asserts nothing (constitution §3): every number here
## is a measurement, and the ruling that reads it lives in doc 92.

const DEFAULT_DAYS := 21
const DEFAULT_SEEDS: Array[int] = [1337, 4242, 9001]
const DEFAULT_STRATEGIES: Array[String] = ["balanced", "disaster_neglect"]


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

	print("gate rows, %d game-days, standard preset" % days)
	print("| strategy | seed | net/gh | value created | repaired | repair/net % | "
			+ "damaged | destroyed | min cond | floored cond | mean cond | dark % | "
			+ "pop | buildings | treasury |")
	print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
	for strategy: String in strategies:
		for raw_seed: Variant in seeds:
			var seed_value := int(raw_seed)
			var doc := BalanceGateRig.run(strategy, seed_value, days)
			var s: Dictionary = doc["summary"]
			# The gate's own denominator: the SUM of every settled hour's net,
			# not `net_mean_per_hour × hours` — gate 4b sums the sample stream.
			var net := 0.0
			var samples: Array = doc["samples"]
			for i in range(1, samples.size()):
				net += float((samples[i] as Dictionary)["net"])
			print(("| %s | %d | %.1f | %d | %d | %.2f | %d | %d | %.3f | %.3f | "
					+ "%.3f | %.2f | %d | %d | %d |") % [strategy, seed_value,
					float(s["net_mean_per_hour"]), int(s["value_created"]),
					int(s["repaired"]),
					100.0 * float(int(s["repair_spend"])) / maxf(1.0, net),
					int(s["damaged_end"]), int(s["destroyed_end"]),
					float(s["min_condition_end"]),
					float(s.get("min_condition_floored_end", -1.0)),
					float(s["mean_condition_end"]),
					100.0 * float(s["unserved_share"]), int(s["population_end"]),
					int(s["buildings_end"]), int(s["treasury_end"])])
	quit(0)
