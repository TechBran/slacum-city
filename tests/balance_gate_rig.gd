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
	}


static func event_count(doc: Dictionary, type_name: String) -> int:
	return int((doc["events"] as Dictionary).get(type_name, 0))


static func summary(doc: Dictionary) -> Dictionary:
	return doc["summary"]
