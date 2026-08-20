extends SceneTree
## Doc 92 §18's ambient-pacing A/B, as a re-runnable instrument.
##
## Doc 92 pass 5 measured the incident MIX by hand and wrote the numbers into
## §18.3; the Wave-7 D-17/D-18 landing had to re-derive the same table across
## five live channels instead of three, and gate 19's band is set from it. This
## is the thing that produced both, so the next person to move a floor row does
## not have to rebuild the harness first.
##
## It is a MEASURING instrument (constitution §3): it drives `BalanceGateRig`,
## which drives the same strategies, the same `Api` facade and the same
## summariser the gates and `tools/playtest.gd` use, so a number here and a gate
## threshold are the same measurement. It owns no constant.
##
## Usage:
##   ~/.local/bin/godot --headless --path . -s res://tools/pacing_ab.gd -- \
##       seeds=1337,4242,9001 days=28 strategy=do_nothing label=floor_on
##
## `strategy=` takes a COMMA LIST, and that is how doc 92 §18.4's gradient table
## ("a neglected city meets its fires sooner") is produced in one command:
##
##   ... -- seeds=1337,4242,9001 days=21 label=w8 strategy=do_nothing,\
##       greedy_growth,infrastructure_first,balanced,tax_squeezer,disaster_neglect
##
## Every strategy prints its own channel block, and a §18.4-shaped summary table
## is printed at the end so the doc row and the measurement are the same text.
##
## To measure the counterfactual, set `ambient_floor.enabled` to `false` in
## `data/incidents.json` and run it again — that restores pre-floor generation
## exactly, which is what makes it an honest A/B.

const Rig := preload("res://tests/balance_gate_rig.gd")

const CHANNELS := ["crime", "structure_fire", "transformer_failure",
		"water_main_break", "traffic_accident", "storm_damage"]


func _initialize() -> void:
	var seeds: Array = [1337, 4242, 9001, 101, 202, 303]
	var days := 28
	var label := "run"
	var strategies: Array = ["do_nothing"]
	for a in OS.get_cmdline_user_args():
		var arg := String(a)
		if arg.begins_with("seeds="):
			seeds = []
			for piece in arg.substr(6).split(","):
				seeds.append(int(piece))
		elif arg.begins_with("days="):
			days = int(arg.substr(5))
		elif arg.begins_with("label="):
			label = arg.substr(6)
		elif arg.begins_with("strategy="):
			strategies = []
			for piece in arg.substr(9).split(",", false):
				strategies.append(String(piece))
	var rows: Array = []
	for strategy in strategies:
		rows.append(_measure(String(strategy), seeds, days, label))
	if rows.size() > 1:
		_print_gradient(rows, seeds.size(), days)
	quit()


## One strategy, every seed. Returns the row `_print_gradient` tabulates.
func _measure(strategy: String, seeds: Array, days: int, label: String) -> Dictionary:
	var totals: Dictionary = {}
	var created := 0
	var resolved := 0
	var failed := 0
	var abandoned := 0
	var destroyed := 0
	var treasury := 0
	var banked := 0
	for seed_value in seeds:
		var doc: Dictionary = Rig.run(strategy, int(seed_value), days)
		created += Rig.event_count(doc, "incident_created")
		resolved += Rig.event_count(doc, "incident_resolved")
		failed += Rig.event_count(doc, "incident_failed")
		abandoned += Rig.event_count(doc, "incident_abandoned")
		for channel in CHANNELS:
			totals[channel] = int(totals.get(channel, 0)) \
					+ Rig.event_count(doc, "incident_created:" + channel)
		var summary: Dictionary = doc["summary"]
		destroyed += int(summary["destroyed_end"])
		treasury += int(summary["treasury_end"])
		if int(summary["treasury_end"]) > int(summary["treasury_start"]):
			banked += 1
	var game_days := float(seeds.size() * days)
	print("== %s  strategy=%s seeds=%d days=%d  (%d game-days)"
			% [label, strategy, seeds.size(), days, int(game_days)])
	for channel in CHANNELS:
		var n := int(totals.get(channel, 0))
		print("   %-22s %4d   %.3f/day  %.2f/week"
				% [channel, n, float(n) / game_days, float(n) / game_days * 7.0])
	print("   %-22s %4d   %.3f/day  %.2f/week"
			% ["TOTAL", created, float(created) / game_days,
			float(created) / game_days * 7.0])
	print("   resolved=%d failed=%d abandoned=%d destroyed=%d banked=%d/%d mean_treasury=%d"
			% [resolved, failed, abandoned, destroyed, banked, seeds.size(),
			treasury / maxi(1, seeds.size())])
	return {
		"strategy": strategy, "created": created, "resolved": resolved,
		"failed": failed, "abandoned": abandoned, "destroyed": destroyed,
		"fires": int(totals.get("structure_fire", 0)),
		"traffic": int(totals.get("traffic_accident", 0)),
		"treasury": treasury / maxi(1, seeds.size()),
	}


## Doc 92 §18.4's table, in doc 92's own units: per-game-week rates over the
## whole (seeds × days) sample, and the raw fire / failure counts beside them,
## because the gradient's whole claim is that the RATIO between rows is caused
## by neglect rather than by city size.
func _print_gradient(rows: Array, seed_count: int, days: int) -> void:
	var game_days := float(seed_count * days)
	print("")
	print("| strategy | incidents / game-week | of which fires | failed | destroyed | mean treasury |")
	print("|---|---|---|---|---|---|")
	for row_variant in rows:
		var row: Dictionary = row_variant
		print("| `%s` | %.2f | %d | %d | %d | $%d |" % [
				String(row["strategy"]),
				float(int(row["created"])) / game_days * 7.0,
				int(row["fires"]), int(row["failed"]), int(row["destroyed"]),
				int(row["treasury"])])
	print("")
	print("(%d seeds × %d game-days = %d game-days per row.)"
			% [seed_count, days, int(game_days)])
