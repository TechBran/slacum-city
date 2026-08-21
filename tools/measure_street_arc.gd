extends SceneTree
## Doc 06 §2.16's opportunity layer measured ON AN ARC, which is the one thing
## doc 92 §35 could not do (report 98 RR-86).
##
## §35.2's ceiling was taken from SPAWN TELEMETRY on a founding city that never
## changed: no city level, no second police station, no growing kerb pool, and
## nothing to compare the money against but the founding hour's net. Three of
## those four move the bounty and the fourth moves the denominator, so the honest
## instrument is a played city — `collector` (doc 06 §2.16's tap, once a
## game-minute) against `curriculum` (the same agent with the tap removed) on the
## same seeds, the same days and the same FINE path.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/measure_street_arc.gd \
##       -- [--days=21] [--seeds=1337,4242,9001] [--difficulty=standard]
##
## **It is a controlled pair, not two runs.** `Collector extends Curriculum` and
## overrides exactly `tick_minute`, so any difference between the two rows is the
## street layer and nothing else — the builder underneath is the same object with
## the same reserve, the same maintenance purse and the same checklist.
##
## **It is a CEILING measurement even so**, and the report has to say so: the
## agent has no camera and no travel time, so every offer it is awake for is an
## offer it takes. A session collects a fraction of it. What this measures is the
## MOST the layer can pay somebody who is playing the game — which is exactly the
## bound `data/economy.json`'s `STREET_CEILING_SHARE_MAX` is written against.
##
## Cost: the fine path is ~60x the coarse step, so 21 game-days is **~4.3
## minutes per run** (measured 259 / 260 s, both agents) and this tool is
## **~26 minutes** at its defaults, six runs. That is why gate 32
## holds a SHORT arm of the same measurement and this holds the published one.

const Rig := preload("res://tests/balance_gate_rig.gd")


func _initialize() -> void:
	var days := 21
	var seeds: Array[int] = [1337, 4242, 9001]
	var preset := Difficulty.DEFAULT_PRESET
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--days="):
			days = maxi(1, int(arg.substr(7)))
		elif arg.begins_with("--difficulty="):
			preset = arg.substr(13)
		elif arg.begins_with("--seeds="):
			seeds = [] as Array[int]
			for part in arg.substr(8).split(",", false):
				seeds.append(int(part))
	if not Difficulty.is_preset(preset):
		printerr("measure_street_arc: unknown difficulty preset " + preset)
		quit(2)
		return

	print("street arc: %d game-days x %d seeds, FINE path, %s"
			% [days, seeds.size(), preset])
	print("")
	print("| seed | agent | net $/gh | street $ | offers | street share of net | lvl | treasury | value |")
	print("|---|---|---|---|---|---|---|---|---|")

	var totals: Dictionary = {}
	var by_level: Dictionary = {}   # city_level -> {n, dollars}
	for seed_value in seeds:
		for agent in ["curriculum", "collector"]:
			var t0 := Time.get_ticks_msec()
			var doc := Rig.run_fine(agent, seed_value, days, preset)
			var s: Dictionary = doc["summary"]
			print("| %d | `%s` | %.0f | %d | %d | **%.2f %%** | %d | %d | %d |"
					% [seed_value, agent, float(s["net_mean_per_hour"]),
					int(s["street_income"]), int(s["opportunities_collected"]),
					100.0 * float(s["street_share_of_net"]),
					int(s["city_level_end"]), int(s["treasury_end"]),
					int(s["value_created"])])
			var row: Dictionary = totals.get(agent, {})
			for key in ["net_mean_per_hour", "street_income",
					"opportunities_collected", "street_share_of_net",
					"treasury_end", "value_created", "population_end",
					"city_level_end"]:
				row[key] = float(row.get(key, 0.0)) + float(s[key])
			row["n"] = float(row.get("n", 0.0)) + 1.0
			row["wall_s"] = float(row.get("wall_s", 0.0)) \
					+ float(Time.get_ticks_msec() - t0) / 1000.0
			totals[agent] = row
			for level_key: Variant in (s["street_by_level"] as Dictionary):
				var cell: Dictionary = (s["street_by_level"] as Dictionary)[level_key]
				var acc: Dictionary = by_level.get(int(level_key), {"n": 0, "dollars": 0})
				acc["n"] = int(acc["n"]) + int(cell["n"])
				acc["dollars"] = int(acc["dollars"]) + int(cell["dollars"])
				by_level[int(level_key)] = acc

	print("")
	print("| agent (mean of %d) | net $/gh | street $ | offers | street share | pop | lvl | treasury | value | wall s |"
			% seeds.size())
	print("|---|---|---|---|---|---|---|---|---|---|")
	for agent in ["curriculum", "collector"]:
		var row: Dictionary = totals[agent]
		var n := float(row["n"])
		print("| **`%s`** | %.0f | %d | %.1f | **%.2f %%** | %d | %.1f | %d | %d | %.0f |"
				% [agent, float(row["net_mean_per_hour"]) / n,
				int(float(row["street_income"]) / n),
				float(row["opportunities_collected"]) / n,
				100.0 * float(row["street_share_of_net"]) / n,
				int(float(row["population_end"]) / n),
				float(row["city_level_end"]) / n,
				int(float(row["treasury_end"]) / n),
				int(float(row["value_created"]) / n),
				float(row["wall_s"]) / n])

	# Doc 92 §35.3's second-order question 4, which the founding-city ceiling
	# could not ask: the layer scales its bounty by `1 + k*(city_level - 1)`, and
	# nobody had measured whether the mean bounty a level-4+ city sees tracks
	# that multiplier or drifts from it. `expected` below is the multiplier the
	# constant promises, normalised to the level the run spent most of its time
	# at, so a reader can see tracking rather than take it on trust.
	print("")
	print("| city level | offers | street $ | mean bounty | vs the lowest level sampled | `1 + k(L-1)`, same base |")
	print("|---|---|---|---|---|---|")
	var levels: Array = by_level.keys()
	levels.sort()
	var k := CostCurves.load_from_files().street_reward_city_level_k()
	var base_mean := 0.0
	for level_variant: Variant in levels:
		var level := int(level_variant)
		var cell: Dictionary = by_level[level]
		var mean := float(cell["dollars"]) / maxf(1.0, float(cell["n"]))
		if base_mean <= 0.0:
			base_mean = mean
		print("| %d | %d | %d | $%.2f | %.3f | %.3f |"
				% [level, int(cell["n"]), int(cell["dollars"]), mean,
				mean / maxf(1.0, base_mean),
				(1.0 + k * float(maxi(1, level) - 1))
						/ (1.0 + k * float(maxi(1, int(levels[0])) - 1))])
	quit(0)
