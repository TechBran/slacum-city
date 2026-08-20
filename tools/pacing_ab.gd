extends SceneTree
## Doc 92 §18's ambient-pacing A/B, as a re-runnable instrument.
##
## Doc 92 pass 5 measured the incident MIX by hand and wrote the numbers into
## §18.3; the Wave-7 D-14/D-15 landing had to re-derive the same table across
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
	var strategy := "do_nothing"
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
			strategy = arg.substr(9)
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
	quit()
