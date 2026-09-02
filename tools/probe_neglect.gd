extends SceneTree
## Lane-B instrument for `test_balance_gates.gd` gate 29 after 99-PA PA-04
## (2026-09-02). Drives the SAME arm the gate drives — `do_nothing`, seed 1337,
## the preset's own horizon, `advance_coarse_hours(1, false)` — and prints the
## first insolvent game-day together with the ledger columns that decide it, so
## a move in the insolvency day can be attributed rather than guessed at.
##
## Runs unchanged on the Wave-17 fork and on the fix, so the two arms are
## comparable.
##
##   --presets=hard,crisis   subset (default all four)
##   --days=N                horizon override (default: gate 29's own table)
##   --seed=N                default 1337, which is gate 29's GATE_SEED

const Rig := preload("res://tests/balance_gate_rig.gd")

const HORIZON := {"casual": 210, "standard": 160, "hard": 120, "crisis": 70}


func _initialize() -> void:
	var presets: Array = ["casual", "standard", "hard", "crisis"]
	var seed_value := 1337
	var days_override := -1
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--presets="):
			presets = arg.substr(10).split(",", false)
		elif arg.begins_with("--seed="):
			seed_value = int(arg.substr(7))
		elif arg.begins_with("--days="):
			days_override = int(arg.substr(7))
	print("probe_neglect seed=%d" % seed_value)
	print("preset    | close_day | hour_d | created | resolved | abandoned"
			+ " | dir_started | services$ | end$")
	for preset in presets:
		var name := String(preset)
		var days: int = days_override if days_override > 0 \
				else int(HORIZON.get(name, 120))
		_run(name, seed_value, days)
	quit(0)


## Gate 29's OWN arm, not an approximation of it: `BalanceGateRig.run` and the
## `day_rows` its summariser publishes, so "insolvent" here means what the gate
## means — the first game-day the treasury CLOSES below zero, not the first hour
## it dips.
func _run(preset: String, seed_value: int, days: int) -> void:
	var doc: Dictionary = Rig.run("do_nothing", seed_value, days, preset)
	var summary: Dictionary = doc["summary"]
	var close_day := -1
	var last := 0
	for row_variant in (summary["day_rows"] as Array):
		var row: Dictionary = row_variant
		last = int(row["treasury"])
		if close_day < 0 and int(row["treasury"]) < 0:
			close_day = int(row["day"])
	# The same claim at hour resolution. A city hovering on the line can dip
	# below zero every evening and close every day above it, and then the
	# day-close reading answers "solvent" about a city that ran out of money
	# seventy game-days ago.
	var hour_day := -1
	var services := 0.0
	var samples: Array = doc["samples"]
	for i in samples.size():
		var sample: Dictionary = samples[i]
		services += float(sample.get("city_services", 0.0))
		if hour_day < 0 and float(sample.get("treasury", 0.0)) < 0.0:
			hour_day = ((i - 1) / 24) + 1
	print("%-9s | %9d | %6d | %7d | %8d | %9d | %11d | %9.0f | %9d" % [
		preset, close_day, hour_day,
		Rig.event_count(doc, "incident_created"),
		Rig.event_count(doc, "incident_resolved"),
		Rig.event_count(doc, "incident_abandoned"),
		Rig.event_count(doc, "director_event_started"),
		services, last])
