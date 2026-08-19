extends SceneTree
## The doc 92 strategy matrix, run ONLINE on the coarse step. Not a test suite
## (the runner only picks up `test_*.gd`) and not a second harness: it drives
## `BalanceGateRig`, which drives `tools/playtest.gd`'s own strategies, `Api` and
## summariser. The ONLY difference from `tools/playtest.gd --mode=coarse` is that
## it does not run the matrix as an offline catch-up session — see the rig's
## header for why that matters (short version: doc 08 §2.3 rule 1 silences the
## Disaster Director for the whole of a catch-up, so the pass-2 matrix could not
## see the pressure it was measuring). This file goes away the day
## `tools/playtest.gd` takes the one-word `advance_coarse_hours(1, false)` fix.
##
##   ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
##       -s res://tests/balance_matrix.gd -- days=21
##   ... -- days=21 strategies=balanced,disaster_neglect seeds=1337

const DEFAULT_STRATEGIES := ["do_nothing", "greedy_growth", "infrastructure_first",
		"balanced", "tax_squeezer", "disaster_neglect"]


func _initialize() -> void:
	var days := 21
	var strategies: Array = DEFAULT_STRATEGIES.duplicate()
	var seeds: Array = [1337, 4242, 9001]
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		var split := arg.find("=")
		if split < 0:
			continue
		var key := arg.substr(0, split)
		var value := arg.substr(split + 1)
		match key:
			"days":
				days = int(value)
			"strategies":
				strategies = []
				for p in value.split(",", false):
					strategies.append(String(p))
			"seeds":
				seeds = []
				for p in value.split(",", false):
					seeds.append(int(p))
	print("| strategy | seed | treasury | value | net $/gh | pop | happy | stab | lvl | dark % | placed | upg | minC | open inc | abandoned | dir ev | credit | wall s |")
	print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
	var agg := {}
	for strategy in strategies:
		for seed_value in seeds:
			var t0 := Time.get_ticks_msec()
			var doc := BalanceGateRig.run(String(strategy), int(seed_value), days)
			var s: Dictionary = doc["summary"]
			var wall := float(Time.get_ticks_msec() - t0) / 1000.0
			print("| %s | %d | %d | %d | %.0f | %d | %.1f | %.4f | %d | %.2f | %d | %d | %.3f | %.2f | %d | %d | %d | %.1f |" % [
				strategy, seed_value, int(s["treasury_end"]), int(s["value_created"]),
				float(s["net_mean_per_hour"]), int(s["population_end"]),
				float(s["happiness_end"]), float(s["stability_end"]),
				int(s["city_level_end"]), 100.0 * float(s["unserved_share"]),
				int(s["placed"]), int(s["upgraded"]), float(s["min_condition"]),
				float(s["open_incidents_mean"]),
				BalanceGateRig.event_count(doc, "incident_abandoned"),
				BalanceGateRig.event_count(doc, "director_event_started"),
				BalanceGateRig.event_count(doc, "credit_line_engaged"), wall])
			var row: Dictionary = agg.get(strategy, {})
			for key in ["treasury_end", "value_created", "net_mean_per_hour",
					"population_end", "happiness_end", "stability_end",
					"unserved_share", "placed", "upgraded", "min_condition",
					"open_incidents_mean", "repaired", "repair_spend", "blocks_bought"]:
				row[key] = float(row.get(key, 0.0)) + float(s[key])
			row["incident_abandoned"] = float(row.get("incident_abandoned", 0.0)) \
					+ float(BalanceGateRig.event_count(doc, "incident_abandoned"))
			row["director_event_started"] = float(row.get("director_event_started", 0.0)) \
					+ float(BalanceGateRig.event_count(doc, "director_event_started"))
			row["credit_line_engaged"] = float(row.get("credit_line_engaged", 0.0)) \
					+ float(BalanceGateRig.event_count(doc, "credit_line_engaged"))
			row["incident_created"] = float(row.get("incident_created", 0.0)) \
					+ float(BalanceGateRig.event_count(doc, "incident_created"))
			row["n"] = float(row.get("n", 0.0)) + 1.0
			agg[strategy] = row
	print("")
	print("| strategy (mean) | treasury | value | net $/gh | pop | happy | stab | dark % | placed | upg | minC | open inc | inc created | abandoned | dir ev | credit | repairs |")
	print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
	for strategy in strategies:
		var row: Dictionary = agg[strategy]
		var n := float(row["n"])
		print("| **%s** | %d | %d | %.0f | %d | %.1f | %.4f | %.2f | %d | %d | %.3f | %.2f | %.1f | %.1f | %.1f | %.1f | %.1f |" % [
			strategy, int(float(row["treasury_end"]) / n), int(float(row["value_created"]) / n),
			float(row["net_mean_per_hour"]) / n, int(float(row["population_end"]) / n),
			float(row["happiness_end"]) / n, float(row["stability_end"]) / n,
			100.0 * float(row["unserved_share"]) / n, int(float(row["placed"]) / n),
			int(float(row["upgraded"]) / n), float(row["min_condition"]) / n,
			float(row["open_incidents_mean"]) / n, float(row["incident_created"]) / n,
			float(row["incident_abandoned"]) / n, float(row["director_event_started"]) / n,
			float(row["credit_line_engaged"]) / n, float(row["repaired"]) / n])
	quit(0)
