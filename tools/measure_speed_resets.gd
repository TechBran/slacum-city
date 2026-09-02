extends SceneTree
## PA-84's target, on demand: **how often would the game take the speed control
## away on the curriculum path?**
##
##   ~/.local/bin/godot --headless -s res://tools/measure_speed_resets.gd \
##       -- [--days=21] [--seeds=1337,4242,9001] [--strategy=curriculum]
##
## The audit sets the bar at **≤ 1 forced reset per real hour**, and a real hour
## is 60 game-hours (constitution §4: 1 real second = 1 game minute at 1×). So the
## denominator here is game-hours ÷ 60, the re-arm is ten game-hours (600 real
## seconds at 1×), and the trigger test is the shipped one —
## `HudModel.is_auto_speed_reset_trigger`, reading
## `data/ui.json.speed.auto_speed_reset_triggers` — so a number printed here is
## the number `game/main.gd` would produce.
##
## Two counts per seed, and the gap between them is the point:
##
##   * `raw`     — every trigger event the run produced.
##   * `forced`  — how many of those would actually have moved the speed, after
##                 the re-arm. This is the number the ≤ 1/hour bar applies to.
##
## It drives the same rig `tests/balance_gates.gd` does (online, coarse step,
## `Playtest.Factory` strategies), so this is the curriculum path and not a
## second harness's idea of one.

const Playtest := preload("res://tools/playtest.gd")

const DEFAULT_DAYS := 21
const DEFAULT_SEEDS: Array[int] = [1337, 4242, 9001]
const HOURS_PER_DAY := 24
## Constitution §4: 1 real s = 1 game min at 1×, so one real hour of play is
## sixty game-hours of city.
const GAME_HOURS_PER_REAL_HOUR := 60.0


func _initialize() -> void:
	var days := DEFAULT_DAYS
	var seeds := DEFAULT_SEEDS.duplicate()
	var strategy_id := "curriculum"
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--days="):
			days = int(arg.substr(7))
		elif arg.begins_with("--strategy="):
			strategy_id = arg.substr(11)
		elif arg.begins_with("--seeds="):
			seeds = [] as Array[int]
			for part in arg.substr(8).split(","):
				seeds.append(int(part))

	var model := HudModel.new(UIConfig.load_from_files())
	var rearm_game_hours := model.auto_speed_reset_rearm_s() / 60.0
	print("auto_speed_reset: strategy=%s, %d game-days, re-arm %.0f real s (%.0f game-hours)"
			% [strategy_id, days, model.auto_speed_reset_rearm_s(), rearm_game_hours])
	print("triggers: %s" % str(model.auto_speed_reset_triggers()))
	print("")
	print("|   seed | game-h |  raw | forced | forced per real hour |")
	print("|-------:|-------:|-----:|-------:|---------------------:|")

	var worst := 0.0
	for seed_value: int in seeds:
		var row := _run(strategy_id, seed_value, days, model, rearm_game_hours)
		var hours := float(days * HOURS_PER_DAY)
		var per_real_hour := float(row["forced"]) / (hours / GAME_HOURS_PER_REAL_HOUR)
		worst = maxf(worst, per_real_hour)
		print("| %6d | %6d | %4d | %6d | %20.3f |"
				% [seed_value, int(hours), int(row["raw"]), int(row["forced"]),
				per_real_hour])
	print("")
	print("worst seed: %.3f forced resets per real hour (bar: <= 1.000) -> %s"
			% [worst, "PASS" if worst <= 1.0 else "FAIL"])
	quit(0 if worst <= 1.0 else 1)


## One online coarse run, draining the bus a game-hour at a time so the trigger
## stream can be counted in the order the shell would see it.
func _run(strategy_id: String, seed_value: int, days: int, model: HudModel,
		rearm_game_hours: float) -> Dictionary:
	var sim := CitySim.boot_from_files(seed_value, Difficulty.DEFAULT_PRESET)
	var strategy := Playtest.Factory.make(strategy_id)
	var api := Playtest.Api.new(sim)
	sim.bus.drain()
	var raw := 0
	var forced := 0
	var last_forced_h := -1.0e12
	for h in days * HOURS_PER_DAY:
		api.hour = h
		strategy.act(api, h)
		sim.advance_coarse_hours(1, false)   # online, not catch-up — the rig's rule
		var batch: Array = sim.bus.drain()
		var fired_this_hour := false
		for entry: Variant in batch:
			if not (entry is Dictionary):
				continue
			if not model.is_auto_speed_reset_trigger(entry as Dictionary):
				continue
			raw += 1
			if fired_this_hour:
				continue
			if float(h) - last_forced_h < rearm_game_hours:
				continue
			forced += 1
			last_forced_h = float(h)
			fired_this_hour = true
	return {"raw": raw, "forced": forced}
