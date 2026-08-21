extends SceneTree
## The reproducer for doc 92 §31.4 — what a NEGLECTED city costs, past the point
## where it stops being a city.
##
## Every other measuring instrument in this tree looks at a city somebody is
## playing. `tools/playtest.gd` and `tests/balance_matrix.gd` stop at 21
## game-days; `tests/test_balance_gates.gd` gate 29 runs to insolvency and no
## further. Doc 92 §29.5(b) was found in the gap after all of them: a `crisis`
## `do_nothing` city is destroyed by game-day 55, sits at total decay for fifty
## more, and then — at game-day **104** — multiplied its open-incident roster
## ~2.8× per game-hour to 89,055, at 269 s of wall clock for one simulated hour.
##
## Doc 06 §2.13(b)'s saturation rule bounds that, and gate 30 asserts the bound.
## This tool is the other half: the bound is one number and the **curve** is what
## says whether carrying it is affordable, which a pass/fail gate cannot show.
##
## Like `tools/profile_sim.gd` it is a MEASURING instrument — it boots the real
## `CitySim`, drives the real strategy through the real `Api`, owns no constant
## of its own, and nothing in `sim/` imports it (constitution §3).
##
## Usage:
##   ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
##       -s res://tools/profile_decay.gd -- [options]
##
##   --days=N        game-days to simulate                 (default 200)
##   --preset=P      doc 03 §2.9 difficulty                (default crisis)
##   --seed=N        RNG seed                              (default 1337)
##   --strategy=S    any `tools/playtest.gd` strategy id   (default do_nothing)
##   --bucket=N      game-days per row of the curve table  (default 20)
##   --stop=N        bail out if the roster passes N open  (default 0 = never)
##
## `--stop` exists for running this against a tree WITHOUT the saturation rule,
## which is the only way to reproduce the "before" column of §31.4's table
## without waiting for a run that does not finish.

const Playtest := preload("res://tools/playtest.gd")

const DEFAULT_DAYS := 200
const DEFAULT_PRESET := "crisis"
const DEFAULT_SEED := 1337
const DEFAULT_STRATEGY := "do_nothing"
const DEFAULT_BUCKET_DAYS := 20
const HOURS_PER_DAY := 24


func _initialize() -> void:
	var days := DEFAULT_DAYS
	var preset := DEFAULT_PRESET
	var seed_value := DEFAULT_SEED
	var strategy_id := DEFAULT_STRATEGY
	var bucket_days := DEFAULT_BUCKET_DAYS
	var stop_at := 0
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		var split := arg.find("=")
		if split < 0:
			continue
		var key := arg.substr(0, split)
		var value := arg.substr(split + 1)
		match key:
			"--days": days = int(value)
			"--preset": preset = value
			"--seed": seed_value = int(value)
			"--strategy": strategy_id = value
			"--bucket": bucket_days = maxi(1, int(value))
			"--stop": stop_at = int(value)
			_:
				printerr("profile_decay: unknown option " + key)
				quit(2)
				return
	if not Difficulty.is_preset(preset):
		printerr("profile_decay: unknown difficulty preset " + preset)
		quit(2)
		return
	var strategy := Playtest.Factory.make(strategy_id)
	if strategy == null:
		printerr("profile_decay: unknown strategy " + strategy_id)
		quit(2)
		return

	var sim := CitySim.boot_from_files(seed_value, preset)
	var api := Playtest.Api.new(sim)
	sim.bus.drain()
	var ceiling: int = sim.incidents.saturation_ceiling()
	var automatic_ceiling: int = sim.incidents.saturation_automatic_ceiling()
	print("profile_decay: %s · %s · seed %d · %d game-days"
			% [strategy_id, preset, seed_value, days])
	print("doc 06 §2.13(b): roster ceiling %d, automatic ceiling %d"
			% [ceiling, automatic_ceiling])

	var started := Time.get_ticks_msec()
	var peak := 0
	var peak_hour := -1
	var worst_ms := 0
	var worst_ms_hour := -1
	var hours_over_ceiling := 0
	var bucket_hours: Dictionary = {}   # bucket index -> [hours, ms, Σopen]
	var bailed := false
	var total_hours := days * HOURS_PER_DAY
	for h in total_hours:
		api.hour = h
		strategy.act(api, h)
		var hour_started := Time.get_ticks_msec()
		sim.advance_coarse_hours(1, false)   # online, not catch-up — see the rig
		var hour_ms := Time.get_ticks_msec() - hour_started
		sim.bus.drain()
		var open_now: int = sim.incidents.active_count()
		if open_now > peak:
			peak = open_now
			peak_hour = h
		if hour_ms > worst_ms:
			worst_ms = hour_ms
			worst_ms_hour = h
		if ceiling > 0 and open_now > ceiling:
			hours_over_ceiling += 1
		var bucket := h / (HOURS_PER_DAY * bucket_days)
		var row: Array = bucket_hours.get(bucket, [0, 0, 0])
		row[0] += 1
		row[1] += hour_ms
		row[2] += open_now
		bucket_hours[bucket] = row
		if stop_at > 0 and open_now > stop_at:
			print("BAILED at game-hour %d (game-day %.1f) with %d open — --stop=%d"
					% [h, float(h) / float(HOURS_PER_DAY), open_now, stop_at])
			bailed = true
			break
	var wall_s := float(Time.get_ticks_msec() - started) / 1000.0

	print("")
	print("peak open        : %d, at game-hour %d (game-day %.1f)"
			% [peak, peak_hour, float(peak_hour) / float(HOURS_PER_DAY)])
	print("game-hours > %-4d: %d" % [ceiling, hours_over_ceiling])
	print("worst game-hour  : %d ms, at game-hour %d" % [worst_ms, worst_ms_hour])
	print("whole run        : %.1f s%s" % [wall_s, "  (BAILED)" if bailed else ""])
	print("")
	print("| game-days | mean open | mean ms/game-hour |")
	print("|---|---|---|")
	var keys := bucket_hours.keys()
	keys.sort()
	for key in keys:
		var row2: Array = bucket_hours[key]
		print("| %d–%d | %.2f | %.1f |" % [
			int(key) * bucket_days, int(key) * bucket_days + bucket_days - 1,
			float(row2[2]) / float(row2[0]), float(row2[1]) / float(row2[0])])
	print("")
	print("final roster: %s" % _roster(sim))
	quit(0)


## What the roster is MADE of at the end — by type, and by the `cause.source`
## that produced it, because "36 open" and "36 open, 28 of them children of each
## other" are different facts and only the second one names a cascade.
func _roster(sim: CitySim) -> String:
	var by_type: Dictionary = {}
	var by_source: Dictionary = {}
	for incident_id in sim.incidents.incident_ids():
		var inc: Incident = sim.incidents.incident(int(incident_id))
		var key := inc.type + ("/" + inc.subtype if inc.subtype != "" else "")
		by_type[key] = int(by_type.get(key, 0)) + 1
		var source := String(inc.cause.get("source", "?"))
		by_source[source] = int(by_source.get(source, 0)) + 1
	var out: Array[String] = []
	var type_keys := by_type.keys()
	type_keys.sort()
	for key in type_keys:
		out.append("%s:%d" % [key, by_type[key]])
	var source_keys := by_source.keys()
	source_keys.sort()
	for key in source_keys:
		out.append("<%s>:%d" % [key, by_source[key]])
	return " ".join(out) if not out.is_empty() else "(empty)"
