extends SceneTree
## Wave-19 Lane-2 instrument (doc 92 §56.1). **What does an ABSENCE do to a
## city?** — measured, per game-day, with the CAUSE of every destruction named,
## before one balance number is touched.
##
## It exists because nothing in the project could answer the player's report of
## 2026-09-03 ("ALL of my buildings are destroyed right now") with a number.
## `tools/probe_neglect.gd` measures the INSOLVENCY day of an ONLINE neglected
## city and prints no building column at all; `tools/playtest.gd` samples
## `destroyed_buildings` but never the cause, and drives the coarse path with
## `is_catchup` defaulting to true, which is a different physics (see below).
##
## THE TWO ARMS, and why both are needed:
##
##   --mode=online    `advance_coarse_hours(1, false)` — an online city
##                    fast-forwarded. This is gate 29's arm and doc 92's whole
##                    pass-2 matrix. Destruction is ALLOWED: `destroy_allowed()`
##                    is `not incident_world.offline`.
##   --mode=absence   `director.catchup_begin()` once, then coarse hours with
##                    `is_catchup = true` — a real closed app. Doc 08 C-47
##                    suppresses burn-down and the structural-failure roll here,
##                    and `data/director.json fairness.offline` caps hazards at
##                    one for the whole session.
##
## They are NOT interchangeable and the difference is the finding: an absence
## and a fast-forward destroy through different doors.
##
## THE ARC. `--warm=N` runs N game-days of the `balanced` agent FIRST, so the
## absence lands on a city that was played rather than on the 34-building
## founding fixture. The player's own city was ~452 population at city level 3;
## `--warm=21` on `standard` lands within a few percent of it (see the report),
## which is what makes "reproduce the player's outcome" a claim and not a hope.
##
##   ~/.local/bin/godot --headless --path <repo> -s res://tools/measure_catastrophe.gd -- [opts]
##
##   --presets=a,b       default casual,standard,hard,crisis
##   --days=N            absence length in GAME-days (default 45)
##   --real-hours=F      absence length in REAL hours instead; 1 real h = 60
##                       game-h = 2.5 game-days, so --real-hours=8 is 20 days
##   --warm=N            game-days of `balanced` play before the absence (0)
##   --mode=online|absence|both   default both
##   --seed=N            default 1337
##   --rows              print the per-game-day table (default: summary only)
##   --stride=N          print every Nth day row (default 1)
##   --then-online=N     after the absence, N more game-days ONLINE — the
##                       RETURN. Doc 08 C-47 suppresses destruction while the
##                       app is closed; it does not repair anything, so the
##                       whole suppressed backlog is still standing at condition
##                       ~0 when the player taps the icon. This flag is the only
##                       way to see what that backlog does, and it is where the
##                       player's "destroyed super fast" actually lives.
##   --warm-strategy=ID  default `balanced`; any tools/playtest.gd agent id
##   --treasury=N        force the balance to N dollars at the START of the
##                       absence (after the warm-up). The player's own report is
##                       "there's negative money", and doc 03 §2.10 layer 2's
##                       AUSTERITY_DECAY_MULT = 2.5 means an insolvent city wears
##                       two and a half times faster than a solvent one — so a
##                       measurement taken on a rich city is measuring a
##                       different game from the one that was reported.

const Playtest := preload("res://tools/playtest.gd")

const HOURS_PER_DAY := 24
## Constitution §1's locked scale: one real second is one game minute, so one
## REAL hour of absence is sixty GAME hours. Stated once, here, because the
## player reports absences in real hours and the sim counts game-days.
const GAME_HOURS_PER_REAL_HOUR := 60.0

## Every terminal cause `Building._destroy` can be handed, in the order the
## report prints them. `damage` is doc 06's `apply_damage` arriving at condition
## zero — the incident/disaster door; `fire` is `burn_down`; `structural_failure`
## is doc 02 §2.6's roll from `damaged` below 0.10.
const DESTROY_CAUSES := ["damage", "fire", "structural_failure"]
## `Building.apply_decay` / `apply_damage` / `suppress_fire` label these.
const DAMAGE_CAUSES := ["decay", "incident", "fire"]
## `--treasury` was not given. Far outside any balance this game can reach, so
## it can never collide with a balance a caller means.
const NO_FORCED_TREASURY := 0x7FFFFFFF


func _initialize() -> void:
	var presets: Array = ["casual", "standard", "hard", "crisis"]
	var days := 45
	var warm := 0
	var seed_value := 1337
	var modes: Array = ["online", "absence"]
	var rows := false
	var stride := 1
	var then_online := 0
	var warm_strategy := "balanced"
	## A sentinel is wrong here — 0 and every negative balance are values the
	## flag must be able to ask for — so the presence of the flag is its own flag.
	var forced_treasury := 0
	var force_treasury := false
	var relief_probe := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--presets="):
			presets = arg.substr(10).split(",", false)
		elif arg.begins_with("--days="):
			days = int(arg.substr(7))
		elif arg.begins_with("--real-hours="):
			days = int(ceil(float(arg.substr(13)) * GAME_HOURS_PER_REAL_HOUR
					/ float(HOURS_PER_DAY)))
		elif arg.begins_with("--warm="):
			warm = int(arg.substr(7))
		elif arg.begins_with("--seed="):
			seed_value = int(arg.substr(7))
		elif arg.begins_with("--mode="):
			var m := arg.substr(7)
			modes = ["online", "absence"] if m == "both" else [m]
		elif arg == "--rows":
			rows = true
		elif arg.begins_with("--stride="):
			stride = maxi(1, int(arg.substr(9)))
		elif arg.begins_with("--then-online="):
			then_online = int(arg.substr(14))
		elif arg.begins_with("--warm-strategy="):
			warm_strategy = arg.substr(16)
		elif arg.begins_with("--treasury="):
			forced_treasury = int(arg.substr(11))
			force_treasury = true
		elif arg == "--relief":
			relief_probe = true

	print("measure_catastrophe seed=%d days=%d warm=%d  (1 real h = %d game-h)"
			% [seed_value, days, warm, int(GAME_HOURS_PER_REAL_HOUR)])
	if relief_probe:
		for preset_variant in presets:
			_relief(String(preset_variant), seed_value, warm, warm_strategy)
		quit(0)
		return
	print("mode     preset    | pop0 lvl0 | bld | ruin | dmg | dstr:damage"
			+ " fire struct | dir_ev | inc_new | treasury0 -> treasury")
	for mode_variant in modes:
		var mode := String(mode_variant)
		for preset_variant in presets:
			_run(mode, String(preset_variant), seed_value, days, warm, rows,
					stride, then_online, warm_strategy,
					forced_treasury if force_treasury else NO_FORCED_TREASURY)
	quit(0)


## Doc 92 §56.5's table: what doc 03 §2.10 layer 5 actually OFFERS a city that
## has fallen over, priced at both ends of the ladder rather than asserted.
##
## The arm is the report's own limit case — every building a ruin, no revenue —
## so the two grants it prints are the before and after of doc 93 §AP4(b) on the
## worst city the game can produce, not on a convenient one. Buildings are put
## down with `demolish()`, which is the same terminal path doc 06's own
## `destroy_building` op takes, so `level_at_destruction` is set exactly as a
## real catastrophe would set it and the bill is priced off real levels.
func _relief(preset: String, seed_value: int, warm: int,
		warm_strategy_id: String) -> void:
	var sim := CitySim.boot_from_files(seed_value, preset)
	var api := Playtest.Api.new(sim)
	sim.bus.drain()
	if warm > 0:
		var warm_strategy := Playtest.Factory.make(warm_strategy_id)
		for h in warm * HOURS_PER_DAY:
			api.hour = h
			warm_strategy.act(api, h)
			sim.advance_coarse_hours(1, false)
			for event in sim.bus.drain():
				if String(event["type"]) == "economy_hour_settled" \
						and warm_strategy is Playtest.Balanced:
					(warm_strategy as Playtest.Balanced).note_expense(
							float(event.get("expense", 0.0)))

	var standing := _standing(sim)
	for id in sim.roster_ids():
		(sim.buildings[id] as Building).demolish(true, sim.clock.sim_time_minutes())
	var bill := sim.outstanding_restore_cost()

	# The ladder's own two terms, evaluated by the ladder itself. `update_*`
	# first, because the trigger is a fraction of the credit limit and the credit
	# limit is a function of revenue the ruins are no longer producing.
	var t := sim.treasury
	t.update_credit_limit(0.0)
	t.balance = -t.credit_limit
	var fraction := t.recovery_value("RELIEF_DAMAGE_FRACTION")
	var before: int = clampi(CostCurves.round_half_up(
			t.recovery_value("RELIEF_DAYS_OF_REVENUE") * 0.0),
			int(t.recovery_value("RELIEF_MIN")), int(t.recovery_value("RELIEF_MAX")))
	var after := t.maybe_grant_relief(0, 0.0, -1.0, bill)
	print(("relief  %-9s | ruined %3d buildings | bill $%d | fraction %.2f"
			+ " | grant BEFORE $%d | grant AFTER $%d | per-era %d")
			% [preset, standing, int(bill), fraction, before, after,
			int(t.difficulty().get("relief_grants_per_era", 0))])
	sim.dispose()


## One arm. Boots, optionally warms with the `balanced` agent, then runs the
## absence hour by hour, draining the bus every hour so a destruction can be
## attributed to the game-day it happened on and to the door it came through.
func _run(mode: String, preset: String, seed_value: int, days: int, warm: int,
		rows: bool, stride: int, then_online: int, warm_strategy_id: String,
		forced_treasury: int) -> void:
	var sim := CitySim.boot_from_files(seed_value, preset)
	var api := Playtest.Api.new(sim)
	sim.bus.drain()

	# ---- the warm-up: a PLAYED city, not the founding fixture ---------------
	if warm > 0:
		var warm_strategy := Playtest.Factory.make(warm_strategy_id)
		for h in warm * HOURS_PER_DAY:
			api.hour = h
			warm_strategy.act(api, h)
			sim.advance_coarse_hours(1, false)
			for event in sim.bus.drain():
				if String(event["type"]) == "economy_hour_settled" \
						and warm_strategy is Playtest.Balanced:
					(warm_strategy as Playtest.Balanced).note_expense(
							float(event.get("expense", 0.0)))

	if forced_treasury != NO_FORCED_TREASURY:
		sim.treasury.balance = forced_treasury
	var pop0 := int(sim.population.city_population)
	var level0 := int(sim.progression.city_level)
	var treasury0 := int(sim.treasury.balance)
	var standing0 := _standing(sim)

	# ---- the absence --------------------------------------------------------
	# `catchup_begin()` is called ONCE, exactly as `advance_coarse_hours(n, true)`
	# calls it once for the whole session (doc 07 C-55) — calling it per hour
	# would hand the Director a fresh offline hazard budget every game-hour and
	# measure a game nobody plays.
	var catchup := mode == "absence"
	if catchup and sim.director != null:
		sim.director.catchup_begin()
	var total := days * HOURS_PER_DAY
	var destroyed_by_cause := {}
	var damaged_by_cause := {}
	var director_events := 0
	var incidents_created := 0
	var day_rows: Array[Dictionary] = []
	for h in total:
		sim.scheduler.advance_coarse_n(1, catchup, h, total)
		director_events += _tally(sim, destroyed_by_cause, damaged_by_cause,
				"director_event_started")
		incidents_created += _pending_incidents
		if (h + 1) % HOURS_PER_DAY == 0:
			day_rows.append(_day_row(sim, (h + 1) / HOURS_PER_DAY,
					destroyed_by_cause, "away"))

	# ---- THE RETURN: the app reopens and C-47's suppression lifts -----------
	# Nothing here repairs anything. Every building the absence rotted below
	# `structural_failure_threshold` is still standing at that condition, and the
	# roll that was NOT TAKEN while the app was closed is taken every game-hour
	# from the moment it opens.
	var ruins_at_return := _count_state(sim, &"destroyed")
	var damaged_at_return := _count_state(sim, &"damaged")
	var at_risk := _count_below(sim, &"damaged", 0.10)
	for h in then_online * HOURS_PER_DAY:
		sim.scheduler.advance_coarse_n(1, false, 0, 0)
		director_events += _tally(sim, destroyed_by_cause, damaged_by_cause,
				"director_event_started")
		incidents_created += _pending_incidents
		if (h + 1) % HOURS_PER_DAY == 0:
			day_rows.append(_day_row(sim, days + (h + 1) / HOURS_PER_DAY,
					destroyed_by_cause, "back"))

	var ruins := _count_state(sim, &"destroyed")
	print("%-8s %-9s | %4d %4d | %3d | %4d | %3d | %11d %4d %6d | %6d | %7d | %9d -> %d"
			% [mode, preset, pop0, level0, standing0, ruins,
			_count_state(sim, &"damaged"),
			int(destroyed_by_cause.get("damage", 0)),
			int(destroyed_by_cause.get("fire", 0)),
			int(destroyed_by_cause.get("structural_failure", 0)),
			director_events, incidents_created, treasury0,
			int(sim.treasury.balance)])
	if not damaged_by_cause.is_empty():
		var parts: Array[String] = []
		for cause in DAMAGE_CAUSES:
			parts.append("%s=%d" % [cause, int(damaged_by_cause.get(cause, 0))])
		print("           damaged-by-cause: " + " ".join(parts))
	if then_online > 0:
		print(("           AT RETURN: ruins %d, damaged %d, of which %d already"
				+ " below the 0.10 structural-failure line."
				+ " AFTER %d online game-days: ruins %d (+%d), standing %d.")
				% [ruins_at_return, damaged_at_return, at_risk, then_online,
				ruins, ruins - ruins_at_return, _standing(sim)])
	if rows:
		print("    day | ph   | standing ruins damaged | dmg fire str |"
				+ " dark fail meanC | treasury | pop | flood")
		for row in day_rows:
			if int(row["day"]) % stride != 0 and int(row["day"]) != days \
					and int(row["day"]) != days + then_online:
				continue
			var by: Dictionary = row["by_cause"]
			print("    %3d | %-4s | %8d %5d %7d | %3d %4d %3d | %4d %4d  %.3f | %9d | %4d | %.3f" % [
				int(row["day"]), String(row["phase"]),
				int(row["standing"]), int(row["ruins"]),
				int(row["damaged"]), int(by.get("damage", 0)),
				int(by.get("fire", 0)), int(by.get("structural_failure", 0)),
				int(row["dark"]), int(row["failed_components"]),
				float(row["mean_condition"]),
				int(row["treasury"]), int(row["population"]),
				float(row["flood_saturation"])])
	sim.dispose()


## Drains the bus once, folding `building_destroyed` / `building_damaged` into
## their cause buckets, and returns how many events of `wanted` went past. The
## bus may only be drained ONCE per game-hour, so the incident count this pass
## saw is left in [_pending_incidents] for the caller rather than counted by a
## second drain that would find nothing.
var _pending_incidents := 0

func _tally(sim: CitySim, destroyed: Dictionary, damaged: Dictionary,
		wanted: String) -> int:
	var hits := 0
	_pending_incidents = 0
	for event in sim.bus.drain():
		var type := String(event["type"])
		if type == "building_destroyed":
			var cause := String(event.get("cause", "?"))
			destroyed[cause] = int(destroyed.get(cause, 0)) + 1
		elif type == "building_damaged":
			var dcause := String(event.get("cause", "?"))
			damaged[dcause] = int(damaged.get(dcause, 0)) + 1
		elif type == "incident_created":
			_pending_incidents += 1
		if type == wanted:
			hits += 1
	return hits


func _day_row(sim: CitySim, day: int, destroyed_by_cause: Dictionary,
		phase: String) -> Dictionary:
	return {
		"day": day,
		"phase": phase,
		"standing": _standing(sim),
		"damaged": _count_state(sim, &"damaged"),
		"ruins": _count_state(sim, &"destroyed"),
		"by_cause": destroyed_by_cause.duplicate(),
		"treasury": int(sim.treasury.balance),
		"population": int(sim.population.city_population),
		"flood_saturation": sim.weather.flood.flood_saturation_city(),
		# The CAUSAL columns. Doc 02 §2.6a's ownership floor lifts the moment a
		# building's `powered_fraction` reaches zero (the §Y1a service clause),
		# and that — not any disaster — is what lets private stock fall past
		# `auto_damage_threshold` and on down to the structural-failure line. A
		# report that showed ruins without `dark` would be describing the
		# symptom and hiding the mechanism.
		"dark": _count_dark(sim),
		"failed_components": _failed_components(sim),
		"mean_condition": _mean_condition(sim),
	}


## Buildings with no power at all this hour. Substations draw no service load
## (doc 04 §2.3) and are excluded, exactly as `Playtest.Runner._blackout_minutes`
## excludes them.
func _count_dark(sim: CitySim) -> int:
	var dark := 0
	for id in sim.buildings:
		var b: Building = sim.buildings[id]
		if b.archetype == &"substation" or b.state == &"destroyed":
			continue
		if sim.grid.power_availability_hour(String(id)) <= 0.0:
			dark += 1
	return dark


## Grid components doc 04 §2.6's thermal model has taken out permanently. A
## neglected city never calls `PowerGrid.repair_component()`, so this only rises.
func _failed_components(sim: CitySim) -> int:
	var failed := 0
	for id in sim.grid.component_ids():
		if String((sim.grid.component(String(id)) as Dictionary).get("state", "")) == "FAILED":
			failed += 1
	return failed


func _mean_condition(sim: CitySim) -> float:
	var total := 0.0
	var counted := 0
	for id in sim.buildings:
		var b: Building = sim.buildings[id]
		if b.state == &"destroyed":
			continue
		total += b.condition
		counted += 1
	return total / maxf(1.0, float(counted))


## Buildings in `state` whose condition is already under `limit` — the backlog
## doc 08 C-47 refused to spend while the app was closed.
func _count_below(sim: CitySim, state: StringName, limit: float) -> int:
	var n := 0
	for id in sim.buildings:
		var b: Building = sim.buildings[id]
		if b.state == state and b.condition < limit:
			n += 1
	return n


## Buildings that are not ruins — the earning stock.
func _standing(sim: CitySim) -> int:
	var n := 0
	for id in sim.buildings:
		if (sim.buildings[id] as Building).state != &"destroyed":
			n += 1
	return n


func _count_state(sim: CitySim, state: StringName) -> int:
	var n := 0
	for id in sim.buildings:
		if (sim.buildings[id] as Building).state == state:
			n += 1
	return n
