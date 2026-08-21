extends SimTest
## `CatchUpCursor` — the sliced offline catch-up (doc 13 §2.9, A91-D-31).
##
## ONE property carries this file: **sliced == monolithic, bit for bit, whatever
## the slice size**. `game/main.gd::_on_app_resumed` used to run the planner's
## segments in a synchronous `for` loop; it now spends units out of a cursor
## across frames, and a returning player has to land on exactly the city the old
## loop would have produced or every save written after a resume is a different
## save from the one the same absence used to write.
##
## The seam that could have broken it is `TimeContext.catchup_index`: a coarse
## step reads it (doc 03's offline yield decay, doc 07's 72-hour offline gate),
## and it is an index into the SEGMENT, not into the slice. `test_a_sliced_run
## _is_bit_identical_at_every_slice_size` is what would have caught a cursor that
## restarted the count per slice — `test_the_index_a_coarse_step_sees_is_the
## _segments_own` pins the mechanism directly, so a failure names the cause and
## not only the symptom.

const BENCH_CITY := "res://tests/fixtures/bench_city.json"


func _boot(city_path: String = "", seed_value: int = 1337) -> CitySim:
	if city_path == "":
		return CitySim.boot_from_files(seed_value)
	var sim := CitySim.new()
	sim.boot(seed_value,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(city_path),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	return sim


## EXACTLY the loop `game/main.gd::_on_app_resumed` ran before this change, kept
## here as the oracle. If the shell's loop is ever rewritten, this copy is what
## the cursor is still measured against.
func _advance_monolithic(sim: CitySim, plan: Dictionary) -> void:
	for segment: Dictionary in plan.get("segments", []):
		var count := int(segment.get("count", 0))
		if count <= 0:
			continue
		if String(segment.get("kind", "")) == "coarse":
			sim.advance_coarse_hours(count)
		else:
			sim.scheduler.advance_fine_n(count)


## Spend the plan through a cursor, `budget` units per "frame". `budget` is the
## shell's, never the cursor's — `sim/` may not read a clock (constitution §5).
func _advance_sliced(sim: CitySim, plan: Dictionary, budget: int) -> int:
	var cursor := sim.begin_catchup(plan)
	var frames := 0
	while not cursor.is_done():
		frames += 1
		for i in budget:
			if cursor.step():
				break
	return frames


## The event bus is part of the answer: an away report is built from
## `sim.bus.drain()`, so two runs that agree on `state_hash` and disagree on the
## drained stream are still two different resumes.
func _bus_digest(sim: CitySim) -> String:
	var parts := PackedStringArray()
	for event in sim.bus.drain():
		parts.append(String(event.get("type", "")))
	return "%d|%s" % [parts.size(), "|".join(parts)]


# ------------------------------------------------------------ the one property

func test_a_sliced_run_is_bit_identical_at_every_slice_size() -> void:
	# 7 h 41 m of absence at 1 real s = 1 game min: a fine head-align, a coarse
	# body and a 40-tick fine tail — every segment kind the planner emits.
	var elapsed_ms := 27_660_000
	for city in ["", BENCH_CITY]:
		var oracle := _boot(city)
		var plan: Dictionary = CatchUpPlanner.plan(elapsed_ms,
				oracle.clock.residual_game_ms, oracle.clock.tick_index)
		_advance_monolithic(oracle, plan)
		var want := oracle.state_hash()
		var want_bus := _bus_digest(oracle)
		var name := "founding" if city == "" else "bench"
		assert_true(int(plan["total_ticks"]) > 1000,
				"%s: the plan is a real absence (%d ticks, %d segments)"
				% [name, int(plan["total_ticks"]), (plan["segments"] as Array).size()])
		for budget in [1, 3, 12, 100000]:
			var sliced := _boot(city)
			var frames := _advance_sliced(sliced, plan, budget)
			assert_eq(sliced.state_hash(), want,
					"%s: %d units/frame lands on the monolithic city (%d frames)"
					% [name, budget, frames])
			assert_eq(_bus_digest(sliced), want_bus,
					"%s: %d units/frame drains the identical event stream" % [name, budget])


func test_the_index_a_coarse_step_sees_is_the_segments_own() -> void:
	# The mechanism behind the property above. A cursor that restarted
	# `catchup_index` per slice would still pass a 1-unit budget and fail here.
	var probe := CatchUpProbe.new()
	var curves := DayCurveSet.new()
	curves.load_from(StarterCityLoader.read_json("res://data/time.json"))
	var scheduler := TickScheduler.new(GameClock.new(), curves, ModifierStack.new())
	scheduler.register(probe)
	var cursor := CatchUpCursor.new(scheduler,
			{"segments": [{"kind": "coarse", "count": 5}]})
	# Two units, then one, then the rest: deliberately ragged slice boundaries.
	cursor.step()
	cursor.step()
	cursor.step()
	cursor.run()
	assert_eq(probe.seen, PackedInt32Array([0, 1, 2, 3, 4]),
			"five coarse hours see 0..4, whatever the slice boundaries were")
	assert_eq(probe.totals, PackedInt32Array([5, 5, 5, 5, 5]),
			"and every one of them is told the SEGMENT's length, not the slice's")


func test_catchup_begin_fires_once_per_coarse_segment() -> void:
	# Doc 07 C-55: once per catch-up session, not once per frame. A cursor that
	# called it per slice would re-open the director's offline window 720 times.
	var sim := _boot()
	var plan: Dictionary = CatchUpPlanner.plan(27_660_000,
			sim.clock.residual_game_ms, sim.clock.tick_index)
	var calls := [0]
	var cursor := CatchUpCursor.new(sim.scheduler, plan,
			func() -> void: calls[0] += 1)
	cursor.run()
	assert_eq(int(calls[0]), 1, "one coarse segment, one catchup_begin")


# -------------------------------------------------------------- the small print

func test_the_cursor_reports_the_plans_own_totals() -> void:
	var sim := _boot()
	var plan: Dictionary = CatchUpPlanner.plan(27_660_000,
			sim.clock.residual_game_ms, sim.clock.tick_index)
	var cursor := sim.begin_catchup(plan)
	assert_eq(cursor.total_ticks(), int(plan["total_ticks"]),
			"the veil's denominator is the planner's own number")
	assert_eq(cursor.total_ticks(), CatchUpPlanner.segments_total_ticks(plan))
	assert_eq(cursor.done_ticks(), 0)
	assert_eq(cursor.steps_done(), 0)
	assert_true(cursor.steps_total() > 0 and cursor.steps_total() < cursor.total_ticks(),
			"units are coarse hours plus fine ticks, so fewer units than ticks")
	var ticks_before_last := 0
	while not cursor.step():
		ticks_before_last = cursor.done_ticks()
	assert_true(ticks_before_last < cursor.total_ticks(), "the bar moved before it finished")
	assert_eq(cursor.done_ticks(), cursor.total_ticks(), "and lands exactly on the total")
	assert_eq(cursor.steps_done(), cursor.steps_total())


func test_an_empty_plan_is_done_before_it_starts() -> void:
	# The `< min_steps` absence S15 refuses a veil for still reaches this: the
	# shell asks for a cursor whatever the plan says, and a plan with no ticks
	# must not cost a frame.
	var sim := _boot()
	var cursor := sim.begin_catchup(CatchUpPlanner.plan(0, 0, 0))
	assert_true(cursor.is_done(), "nothing to advance")
	assert_eq(cursor.total_ticks(), 0)
	assert_eq(cursor.steps_total(), 0)
	assert_true(cursor.step(), "stepping a finished cursor is a no-op, not a crash")
	var tick_before := sim.clock.tick_index
	cursor.run()
	assert_eq(sim.clock.tick_index, tick_before, "and it advanced nothing")


func test_a_fine_only_plan_slices_one_tick_at_a_time() -> void:
	# `CatchUpPlanner`'s `total_ticks <= FINE_CATCHUP_MAX_TICKS` branch emits ONE
	# fine segment and no coarse one. The 120 s grace means no real elapsed time
	# can currently reach that branch with work in it — the smallest credited
	# absence is already 480 ticks — so the plan is written by hand here rather
	# than pretended into existence. The cursor still has to spend it, because
	# the shell hands over whatever the planner emitted and this branch is live
	# code with a live tunable in front of it.
	var plan := {"total_ticks": 17, "segments": [{"kind": "fine", "count": 17}]}
	var sim := _boot()
	var cursor := sim.begin_catchup(plan)
	assert_eq(cursor.steps_total(), cursor.total_ticks(),
			"fine only: one unit per tick")
	var oracle := _boot()
	_advance_monolithic(oracle, plan)
	cursor.run()
	assert_eq(sim.state_hash(), oracle.state_hash(),
			"and a fine-only plan slices identically too")


## A `SimSystem` that records the catch-up coordinates every coarse step hands
## it. `sim/` may not be edited to observe itself, so the observer is a test.
class CatchUpProbe extends SimSystem:
	var seen := PackedInt32Array()
	var totals := PackedInt32Array()

	func system_id() -> StringName:
		return &"catchup_probe"

	func phase() -> int:
		return SimSystem.Phase.CLOCK

	func cadence() -> int:
		return SimSystem.Cadence.EVERY_HOUR

	func advance_coarse(ctx: TimeContext) -> void:
		seen.append(ctx.catchup_index)
		totals.append(ctx.catchup_total)
