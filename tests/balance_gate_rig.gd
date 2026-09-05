class_name BalanceGateRig
extends RefCounted
## Shared driver for doc 92 §10's regression gates. Not a test suite itself (the
## runner only picks up `test_*.gd`), and not a second harness: it drives the
## SAME strategies, the SAME `Api` facade and the SAME summariser as
## `tools/playtest.gd`, so a gate and a report row are the same measurement.
##
## ONE thing differs, and it is the reason this file exists.
## `Playtest.Runner.run_one` advances the coarse path as `advance_coarse_hours(1)`,
## whose `is_catchup` default is `true` — so every hour of the pass-2 matrix ran
## as an offline catch-up hour. Doc 08 §2.3 rule 1 (mirrored into
## `data/director.json` `fairness.offline`, binding as report 98 C-55) allows at
## most ONE hazard per catch-up session and only a **pre-warned** one, and a
## warning can only exist if the Director committed a forecastable event while
## ONLINE. On an all-catch-up run that precondition can never be met, so the
## Disaster Director is structurally silent for the whole run — which is why
## doc 92 pass 2 measured zero Director events and could not see the pressure it
## was looking for. Coarse is a STEP SIZE (doc 01); catch-up is a SESSION KIND
## (doc 08). These gates keep the step size and drop the session kind:
## `advance_coarse_hours(h, false)` — an online city fast-forwarded.
##
## `tools/playtest.gd` wants the same one-word change (see the delivery report).

const Playtest := preload("res://tools/playtest.gd")

const HOURS_PER_DAY := 24


## One run of one strategy, online, on the coarse step. Returns the same
## document shape `Playtest.Runner.run_one` does, minus the file write.
##
## `preset` is doc 03 §2.9's difficulty. It defaults to `standard`, which is what
## every gate and every doc 92 table before §29 is measured on — a run that took
## a different preset would be measuring a different game, so the argument is
## explicit at every call site that uses one (`tests/balance_matrix.gd
## difficulty=…`, gate 29).
## **`road_policy` is the other knob a caller may turn**: doc 10 §2.13's
## automatic repair got a settings dial and a dial that MOVES SPEND has to be
## measured moving it. `{}` — every existing caller — leaves `RoadNetwork` on
## `data/roads.json`'s own defaults, so the control arm of the matrix is the
## matrix this report has always published.
## Keys: `auto_repair_threshold: float`, `auto_repair_daily_cap: int`.
static func run(strategy_id: String, seed_value: int, days: int,
		preset: String = Difficulty.DEFAULT_PRESET,
		road_policy: Dictionary = {}) -> Dictionary:
	var sim := CitySim.boot_from_files(seed_value, preset)
	if not road_policy.is_empty():
		sim.cmd_set_auto_repair_policy(
				float(road_policy.get("auto_repair_threshold",
						sim.roads.auto_repair_threshold)),
				int(road_policy.get("auto_repair_daily_cap",
						sim.roads.auto_repair_daily_cap)))
	var strategy := Playtest.Factory.make(strategy_id)
	var api := Playtest.Api.new(sim)
	var samples: Array[Dictionary] = []
	var events: Dictionary = {}

	sim.bus.drain()
	samples.append(Playtest.Runner._sample(sim, 0, {}, 0.0))
	for h in days * HOURS_PER_DAY:
		api.hour = h
		strategy.act(api, h)
		sim.advance_coarse_hours(1, false)   # online, not catch-up — see above
		var settled: Dictionary = Playtest.Runner._drain(sim, events)
		var blackout: float = Playtest.Runner._blackout_minutes(sim)
		var sample: Dictionary = Playtest.Runner._sample(sim, h + 1, settled, blackout)
		samples.append(sample)
		if strategy is Playtest.Balanced:
			(strategy as Playtest.Balanced).note_expense(float(sample["expenses"]))

	var opts := Playtest.Options.new()
	opts.days = days
	opts.mode = "coarse"
	opts.write_json = false
	return {
		"run": {"strategy": strategy_id, "seed": seed_value, "days": days,
				"difficulty": sim.difficulty_preset()},
		"samples": samples,
		## The per-command action log, same shape `tools/playtest.gd` writes into
		## its JSON. Gates that need a REASON CODE and the game-hour it landed on
		## — doc 92 F-4's `E_UNSERVED` wall is the one — read it from here; the
		## sample stream carries city state only.
		"actions": api.actions,
		"events": events,
		"summary": Playtest.Runner._summarise(sim, api, samples, opts),
		"state_hash": sim.state_hash(),
		"director": _director_facts(sim),
		## Doc 05's pressure zones as the run left them (Wave 26, doc 92 §67.3).
		## ADDITIVE, read-only and computed once — `_director_facts`' shape and
		## for its reason: a tool that measures the water planner has to be able
		## to say what the planner was planning FOR, and the alternative was
		## `tools/measure_utility_plan.gd` driving its own loop, which would make
		## it a second harness measuring a different city.
		"zones": _zone_facts(sim),
	}


## The §2.5 supply chain of every live zone, in `zone_key` order: what it
## supplies, what it is asked for, and the three terms whose MINIMUM is the
## first of those two numbers.
static func _zone_facts(sim: CitySim) -> Array:
	var out: Array = []
	for raw: Variant in sim.water.topology.zones:
		var z: PressureZone = raw
		if z.dead:
			continue
		var source_yield := 0.0
		for id: Variant in z.source_ids:
			var n: WaterNode = sim.water.nodes[String(id)]
			if n.is_live():
				source_yield += float(sim.water.data.component(n.variant, n.level,
						n.subtype).get("yield_m3h", 0.0)) * n.cond_factor()
		var treatment := 0.0
		for id: Variant in z.treatment_ids:
			var n: WaterNode = sim.water.nodes[String(id)]
			if n.is_live():
				treatment += float(sim.water.data.component(n.variant, n.level)
						.get("throughput_m3h", 0.0)) * n.cond_factor()
		var pump := 0.0
		for id: Variant in z.pump_ids:
			var n: WaterNode = sim.water.nodes[String(id)]
			if n.is_live():
				pump += float(sim.water.data.component(n.variant, n.level)
						.get("rated_flow_m3h", 0.0))
		out.append({"key": z.zone_key, "supply": z.supply_m3h, "demand": z.demand_m3h,
				"pressure": z.pressure, "headroom": z.headroom_m3h(),
				"source": source_yield, "treatment": treatment, "pump": pump,
				"nodes": z.node_ids.size()})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["key"]) < String(b["key"]))
	return out


## The same run on the FINE path, cut into game-minutes (RR-86).
##
## **Why a second entry point instead of a flag on the first**: the coarse `run`
## above is what every gate and every doc 92 table is measured on, and it must
## stay the cheapest thing this file can do. This one is ~60× slower per
## game-day, and it exists for exactly one question — doc 06 §2.16's opportunity
## layer, whose spawner draws NOTHING on the coarse step (report 98 RR-77(a)).
## An agent that taps is only an agent here.
##
## The loop body is `Playtest.Runner`'s own (`advance_hour_by_minutes`), not a
## copy: a gate and a report row have to be the same measurement, and a slice
## that drifted between the two would make the gate's number unreproducible from
## the tool the report quotes.
##
## `days` is small at every call site on purpose — see gate 32's own header for
## the budget argument.
static func run_fine(strategy_id: String, seed_value: int, days: int,
		preset: String = Difficulty.DEFAULT_PRESET) -> Dictionary:
	var sim := CitySim.boot_from_files(seed_value, preset)
	var strategy := Playtest.Factory.make(strategy_id)
	var api := Playtest.Api.new(sim)
	var samples: Array[Dictionary] = []
	var events: Dictionary = {}
	var sliced: bool = strategy.wants_game_minutes()

	sim.bus.drain()
	samples.append(Playtest.Runner._sample(sim, 0, {}, 0.0))
	for h in days * HOURS_PER_DAY:
		api.hour = h
		strategy.act(api, h)
		if sliced:
			Playtest.Runner.advance_hour_by_minutes(sim, strategy, api, h)
		else:
			sim.advance_hours(1.0)
		var settled: Dictionary = Playtest.Runner._drain(sim, events)
		var blackout: float = Playtest.Runner._blackout_minutes(sim)
		var sample: Dictionary = Playtest.Runner._sample(sim, h + 1, settled, blackout)
		samples.append(sample)
		if strategy is Playtest.Balanced:
			(strategy as Playtest.Balanced).note_expense(float(sample["expenses"]))

	var opts := Playtest.Options.new()
	opts.days = days
	opts.mode = "fine"
	opts.write_json = false
	return {
		"run": {"strategy": strategy_id, "seed": seed_value, "days": days,
				"difficulty": sim.difficulty_preset(), "mode": "fine"},
		"samples": samples,
		"actions": api.actions,
		"events": events,
		"summary": Playtest.Runner._summarise(sim, api, samples, opts),
		"state_hash": sim.state_hash(),
		"director": _director_facts(sim),
	}


## 99-PA PA-04 / A91-D-59's gate reads this. The Director's own end-of-run books
## say two things no counter of bus events can: how LONG each resolved event was
## held (`history` records `start_min` and `end_min` for every one) and whether
## the schedule was still alive at the end (`last_start_min`). Before the stall
## repair both were unreadable, because `history` never gained an entry — nothing
## resolved, so nothing was ever written to it.
##
## `history` is a 32-entry ring, so `max_hold_min` is over the last 32
## resolutions. On a 60-day run that is the whole tail, which is the half a hold
## bound cares about.
static func _director_facts(sim: CitySim) -> Dictionary:
	if sim.director == null:
		return {}
	var max_hold := 0
	var holds: Array = []
	for row in sim.director.history:
		var hold := int(row["end_min"]) - int(row["start_min"])
		max_hold = maxi(max_hold, hold)
		holds.append(hold)
	var last_start := -1
	for id in sim.director.last_event_start_min:
		last_start = maxi(last_start, int(sim.director.last_event_start_min[id]))
	return {
		"resolved": sim.director.history.size(),
		"active_end": sim.director.active_events.size(),
		"scheduled_end": sim.director.scheduled.size(),
		"max_hold_min": max_hold,
		"holds": holds,
		"last_start_min": last_start,
		"tp_pool": sim.director.tp_pool,
		"max_active_min": sim.director.max_active_min(),
	}


static func event_count(doc: Dictionary, type_name: String) -> int:
	return int((doc["events"] as Dictionary).get(type_name, 0))


static func summary(doc: Dictionary) -> Dictionary:
	return doc["summary"]
