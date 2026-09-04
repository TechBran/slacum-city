extends SceneTree
## Wave-20 instrument (doc 92 §58.7). **Gate 29's own reading, on its own rig,
## without paying for the other thirty-one gates.**
##
## Gate 29 is the slow one, and re-fitting it means running it, reading the day it
## measured, editing a constant and running it again. `tools/measure_insolvency.gd`
## is not a substitute: it is a different reading (it stops at insolvency and
## reports the day it stopped) and it answers a different number — 49 where the
## gate says 47 on `hard`, because the gate reads the first HOUR the treasury goes
## below zero (99-PA PA-04, doc 92 §49.5) and the tool reads its own sampler.
## Re-fitting a gate against a number a different instrument produced is how a
## pinned constant stops meaning what its note says.
##
## So this calls `tests/balance_gate_rig.gd` with gate 29's own arguments and
## applies gate 29's own hour-resolution scan, and prints the four days plus the
## peak open-incident count the cascade tripwire asserts on.
##
##   ~/.local/bin/godot --headless --path <repo> -s res://tools/measure_gate29.gd \
##       -- [--horizons=casual:300,standard:210] [--presets=a,b] [--seed=N]
##
## Lives in `tools/` and imports out of `tests/`, which is the one direction that
## is allowed: `tests/` may not import `tools/`, and neither may `sim/`.

const Rig := preload("res://tests/balance_gate_rig.gd")

## Gate 29's own seed (`test_balance_gates.gd::GATE_SEED`).
const GATE_SEED := 1337
## Gate 29's own horizons, as they stand on this branch. Overridable so a re-fit
## can ask "how far would it have to run?" without editing the gate first.
const DEFAULT_HORIZONS := {"casual": 210, "standard": 160, "hard": 120, "crisis": 70}
const HOURS_PER_DAY := 24


func _initialize() -> void:
	var horizons := DEFAULT_HORIZONS.duplicate()
	## Gate 29 itself only ever runs `GATE_SEED`; the seeds beside it are what
	## `STANDARD_LIFETIME_BAND` is fitted to, and the band is meaningless without
	## them (doc 92 §43.8's own note).
	var seed_value := GATE_SEED
	var presets: Array = Difficulty.PRESETS.duplicate()
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--horizons="):
			for pair in arg.substr(11).split(",", false):
				var halves := pair.split(":", false)
				if halves.size() == 2:
					horizons[halves[0]] = int(halves[1])
		elif arg.begins_with("--seed="):
			seed_value = int(arg.substr(7))
		elif arg.begins_with("--presets="):
			presets = Array(arg.substr(10).split(",", false))

	print("gate 29's reading · do_nothing · seed %d" % seed_value)
	print("| preset | horizon | insolvent on game-day | peak open incidents |")
	print("|---|---|---|---|")
	for preset_variant in presets:
		var preset := String(preset_variant)
		var horizon := int(horizons.get(preset, 200))
		var run := Rig.run("do_nothing", seed_value, horizon, preset)
		var peak_open := 0
		for row_variant in ((run["summary"] as Dictionary)["day_rows"] as Array):
			peak_open = maxi(peak_open, int((row_variant as Dictionary)["open_incidents"]))
		# Gate 29's own scan, character for character: `samples[0]` is the
		# pre-run reading and `samples[i]` closes game-hour `i`.
		var samples: Array = run["samples"]
		var day := -1
		for i in range(1, samples.size()):
			if float((samples[i] as Dictionary).get("treasury", 0.0)) < 0.0:
				day = ((i - 1) / 24) + 1
				break
		print("| `%s` | %d | **%d** | %d |" % [preset, horizon, day, peak_open])
	quit(0)
