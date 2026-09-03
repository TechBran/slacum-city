extends SceneTree
## **What a night away is worth, in dollars and in seconds of veil** (doc 92 §55).
##
## The player's report of 2026-09-03 is one sentence long and this instrument is
## its measurement: *"I went to bed hoping I'd wake up to a bunch of money. The
## money stops after a certain amount of hours of the game being closed."*
##
## Two numbers per absence, and they are the two halves of doc 08 §2.12's
## argument, which until Wave 19 were one number:
##
##   * **$ credited** — treasury after the catch-up minus treasury before it.
##     This is what the PLAYER experiences and it is the only thing the fairness
##     rule may bound.
##   * **veil ms** — wall clock spent running the plan, and the frames that is at
##     60 fps. This is what the PERFORMANCE budget may bound, and it is measured
##     here rather than derived from a per-hour estimate.
##
## Absences are given in REAL hours, which is the unit the player sleeps in;
## `data/time.json` makes one real hour 60 game-hours at 1x, so the conversion is
## printed beside every row and nothing here owns it.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/measure_offline_night.gd \
##       -- [--absences=1,2,4,6,8,12] [--settle-hours=110] [--seeds=1337]
##          [--city=res://tests/fixtures/bench_city.json] [--cap-hours=N]
##          [--strategy=curriculum] [--no-settle]
##
## `--settle-hours` is game-hours of ONLINE curriculum play before the app is
## closed, so the absence lands on a city the player actually built. 110 gh sits
## inside doc 92's L3 window (L3 arrives at 82 gh, L4 at 135 gh on seed 1337),
## which is why it is the default: the brief's case is "a settled L3 city".
##
## `--cap-hours=N` is the **what-if arm**, and it lives here rather than in the
## planner on purpose. RR-160 deleted `max_coarse_hours` from
## `CatchUpPlanner.plan` — there is no longer any argument by which a caller can
## credit a player less — so the Wave-18 clamp is re-implemented in this tool, in
## one line, exactly as the planner used to apply it:
## `plan(mini(elapsed_ms, N * 60_000), …)`. That keeps the BEFORE arm of doc 92
## §55.3 reproducible from the shipped tree, without leaving a door in `sim/`
## that a future caller could walk through. `--cap-hours=360` reproduces the
## shipped Wave-18 behaviour; omitting it measures what ships now.
##
## Like `tools/profile_sim.gd` and `tools/measure_money_pass.gd` this is a
## MEASURING instrument: it boots the real `CitySim`, drives the real planner and
## the real cursor, owns no constant of its own beyond its defaults, and is never
## imported by `sim/` (constitution §3).

const Playtest := preload("res://tools/playtest.gd")

const DEFAULT_ABSENCES: Array[int] = [1, 2, 4, 6, 8, 12]
const DEFAULT_SEEDS: Array[int] = [1337]
## Doc 92 §55: inside the L3 window on seed 1337 (L3 arrives 82 gh, L4 at 135).
const DEFAULT_SETTLE_HOURS := 110
const STARTER_CITY := "res://data/starter_city.json"
const MS_PER_REAL_HOUR := 3600000
const FRAME_MS := 1000.0 / 60.0


func _initialize() -> void:
	var absences := DEFAULT_ABSENCES.duplicate()
	var seeds := DEFAULT_SEEDS.duplicate()
	var settle_hours := DEFAULT_SETTLE_HOURS
	var city := STARTER_CITY
	var strategy := "curriculum"
	var cap_hours := 0
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--absences="):
			absences = [] as Array[int]
			for part in arg.substr(11).split(","):
				absences.append(int(part))
		elif arg.begins_with("--seeds="):
			seeds = [] as Array[int]
			for part in arg.substr(8).split(","):
				seeds.append(int(part))
		elif arg.begins_with("--settle-hours="):
			settle_hours = int(arg.substr(15))
		elif arg == "--no-settle":
			settle_hours = 0
		elif arg.begins_with("--city="):
			city = arg.substr(7)
		elif arg.begins_with("--strategy="):
			strategy = arg.substr(11)
		elif arg.begins_with("--cap-hours="):
			cap_hours = int(arg.substr(12))

	print("offline night: city=%s settle=%d gh (%s) credited window=%s"
			% [city.get_file(), settle_hours, strategy,
			"doc 01 C-19, %d real h" % CatchUpPlanner.OFFLINE_CAP_REAL_HOURS
					if cap_hours <= 0
					else "what-if clamp %d game-h = %d real h" % [cap_hours, cap_hours / 60]])
	print("1 real hour away = 60 game-hours of city time at 1x (data/time.json)")
	for seed_value in seeds:
		_one_seed(city, strategy, int(seed_value), settle_hours, absences, cap_hours)
	quit(0)


func _one_seed(city: String, strategy: String, seed_value: int, settle_hours: int,
		absences: Array, cap_hours: int) -> void:
	print("")
	print("seed %d" % seed_value)
	print("| away real h | credited gh | capped | coarse h | $ credited | $/real h away"
			+ " | veil ms | veil frames | $ same h ONLINE | offline share |")
	for raw: Variant in absences:
		var away_h := int(raw)
		var sim := _settled(city, strategy, seed_value, settle_hours)
		var before := sim.treasury.balance
		# The what-if arm, in one line: the Wave-18 clamp as the planner used to
		# apply it. `cap_hours <= 0` is what ships.
		var elapsed_ms := away_h * MS_PER_REAL_HOUR
		if cap_hours > 0:
			elapsed_ms = mini(elapsed_ms, cap_hours * CatchUpPlanner.REAL_MS_PER_GAME_HOUR)
		var plan := CatchUpPlanner.plan(elapsed_ms,
				sim.clock.residual_game_ms, sim.clock.tick_index)
		var cursor := sim.begin_catchup(plan)
		var t0 := Time.get_ticks_usec()
		cursor.run()
		var wall_ms := float(Time.get_ticks_usec() - t0) / 1000.0
		sim.clock.residual_game_ms = int(plan["new_residual_game_ms"])
		var delta := sim.treasury.balance - before
		var credited_gh := float(plan["credited_real_ms"]) / 60000.0
		var coarse_h := 0
		for segment: Dictionary in plan["segments"]:
			if String(segment["kind"]) == "coarse":
				coarse_h += int(segment["count"])
		sim.dispose()
		# The control arm: the SAME city, the SAME number of REAL hours, run
		# ONLINE with the player present but buying nothing. Doc 92 §55's ruling
		# is a ratio against this, because "what would those hours have been
		# worth if I had been holding the phone" is the only comparison a player
		# actually makes.
		var online := _online_delta(city, strategy, seed_value, settle_hours, away_h * 60)
		var capped := bool(plan["capped"]) or elapsed_ms < away_h * MS_PER_REAL_HOUR
		print("| %11d | %11.0f | %6s | %8d | %10d | %13.0f | %7.0f | %11.0f | %15d | %12.1f%% |"
				% [away_h, credited_gh, "yes" if capped else "no",
				coarse_h, delta, float(delta) / float(away_h), wall_ms,
				ceil(wall_ms / FRAME_MS), online,
				100.0 * float(delta) / maxf(1.0, float(online))])


## Treasury moved by `hours` ONLINE coarse game-hours on the same settled city,
## with no player spend — the control arm above.
func _online_delta(city: String, strategy: String, seed_value: int,
		settle_hours: int, hours: int) -> int:
	var sim := _settled(city, strategy, seed_value, settle_hours)
	var before := sim.treasury.balance
	sim.advance_coarse_hours(hours, false)
	var delta := sim.treasury.balance - before
	sim.dispose()
	return delta


## A city the player actually built: `settle_hours` game-hours of ONLINE
## curriculum play on the coarse step, exactly `BalanceGateRig.run`'s loop — the
## gates and this instrument have to be measuring the same city.
func _settled(city: String, strategy_id: String, seed_value: int, hours: int) -> CitySim:
	var sim := _boot(city, seed_value)
	if hours <= 0:
		return sim
	var strategy := Playtest.Factory.make(strategy_id)
	var api := Playtest.Api.new(sim)
	var events: Dictionary = {}
	sim.bus.drain()
	for h in hours:
		api.hour = h
		strategy.act(api, h)
		sim.advance_coarse_hours(1, false)   # online, not catch-up
		var settled: Dictionary = Playtest.Runner._drain(sim, events)
		var blackout: float = Playtest.Runner._blackout_minutes(sim)
		var sample: Dictionary = Playtest.Runner._sample(sim, h + 1, settled, blackout)
		if strategy is Playtest.Balanced:
			(strategy as Playtest.Balanced).note_expense(float(sample["expenses"]))
	sim.bus.drain()
	return sim


func _boot(city: String, seed_value: int) -> CitySim:
	if city == STARTER_CITY:
		return CitySim.boot_from_files(seed_value)
	var sim := CitySim.new()
	sim.boot(seed_value,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(city),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	return sim
