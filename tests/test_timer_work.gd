extends SimTest
## Doc 01 T-15 (timer heap ordering), T-10 (work accumulation exactness),
## plus repeat timers and serialization round-trips.


class WorkRunner extends SimSystem:
	var work: WorkService
	var completions: Array = []

	func _init(p_work: WorkService) -> void:
		work = p_work

	func system_id() -> StringName:
		return &"work"

	func phase() -> int:
		return Phase.WORK

	func cadence() -> int:
		return Cadence.EVERY_TICK

	func advance_fine(ctx: TimeContext) -> void:
		for unit in work.advance(ctx):
			completions.append({"unit": unit, "minute_of_day": ctx.minute_of_day})

	func advance_coarse(ctx: TimeContext) -> void:
		advance_fine(ctx)


func test_timer_heap_ordering_with_duplicates() -> void:
	var timers := TimerService.new()
	var rng := RngStreams.new(1234)
	var stream := timers  # silence unused warning pattern
	assert_true(stream != null)
	var scheduled: Array = []
	for i in 200:
		var due := 100 + rng.stream("misc").randi_range(0, 20)  # heavy duplicates
		var id := timers.schedule(&"policy_window", &"test", due)
		scheduled.append({"id": id, "due": due})
	var collected := timers.collect_due(200)
	assert_eq(collected.size(), 200)
	for i in range(1, collected.size()):
		var a: Dictionary = collected[i - 1]
		var b: Dictionary = collected[i]
		var ordered: bool = int(a["due_tick"]) < int(b["due_tick"]) \
				or (int(a["due_tick"]) == int(b["due_tick"]) and int(a["id"]) < int(b["id"]))
		assert_true(ordered, "collect_due yields (due_tick, id) order at index %d" % i)


func test_timer_partial_collection_and_cancel() -> void:
	var timers := TimerService.new()
	var early := timers.schedule(&"hazard_phase", &"weather", 10)
	var late := timers.schedule(&"hazard_phase", &"weather", 500)
	var due := timers.collect_due(100)
	assert_eq(due.size(), 1)
	assert_eq(int(due[0]["id"]), early)
	assert_eq(timers.pending_count(), 1)
	assert_true(timers.cancel(late))
	assert_false(timers.cancel(late), "double-cancel returns false")
	assert_eq(timers.pending_count(), 0)


func test_repeating_timer_rearms() -> void:
	var timers := TimerService.new()
	timers.schedule(&"policy_window", &"test", 10, {}, false, 100, 3)
	assert_eq(timers.collect_due(10).size(), 1)
	assert_eq(timers.pending_count(), 1, "re-armed at 110")
	assert_eq(timers.collect_due(110).size(), 1)
	assert_eq(timers.collect_due(210).size(), 1)
	assert_eq(timers.collect_due(310).size(), 1)
	assert_eq(timers.pending_count(), 0, "repeats exhausted")


func test_timer_serialize_roundtrip() -> void:
	var timers := TimerService.new()
	timers.schedule(&"incident_escalation", &"incidents", 400, {"incident_id": 7})
	timers.schedule(&"director_cooldown", &"director", 200)
	var restored := TimerService.new()
	restored.deserialize(timers.serialize())
	assert_eq(restored.pending_count(), 2)
	assert_eq(restored.next_timer_id, timers.next_timer_id)
	var due := restored.collect_due(1000)
	assert_eq(int(due[0]["due_tick"]), 200)
	assert_eq(int(due[1]["due_tick"]), 400)
	assert_eq(int(due[1]["payload"]["incident_id"]), 7)


func _make_scheduler_with_work(start_tick: int) -> Array:
	var clock := GameClock.new()
	clock.tick_index = start_tick
	var curves := DayCurveSet.new()
	var script: GDScript = load("res://tests/test_day_curves.gd")
	curves.load_from(script.load_time_data())
	var scheduler := TickScheduler.new(clock, curves, ModifierStack.new())
	var work := WorkService.new()
	var runner := WorkRunner.new(work)
	scheduler.register(runner)
	return [scheduler, work, runner]


func test_overnight_highrise_worked_example_fine() -> void:
	# Doc 01 §2.7: 8 crew-hours started at 20:00 completes at 08:09 next day.
	# Tick 3360 = day 0, 20:00 (abs_minutes 1200).
	var parts := _make_scheduler_with_work(3360)
	var scheduler: TickScheduler = parts[0]
	var work: WorkService = parts[1]
	var runner: WorkRunner = parts[2]
	work.create(&"construction", &"construction", 8_000_000, 1_000_000, "construction_rate",
			{"project_id": 311})
	scheduler.advance_fine_n(3000)  # 12.5 game-hours, past the expected completion
	assert_eq(runner.completions.size(), 1)
	var minute: int = runner.completions[0]["minute_of_day"]
	assert_eq(minute / 60, 8, "completes during hour 08")
	assert_eq(minute % 60, 9, "completes during minute 09 (doc: 08:09:43)")


func test_work_fine_coarse_exact_equivalence() -> void:
	# T-10: the same 12 hours as coarse steps accumulate identical work_done_mu.
	var fine_parts := _make_scheduler_with_work(3360)
	var coarse_parts := _make_scheduler_with_work(3360)
	var fine_id: int = (fine_parts[1] as WorkService).create(
			&"construction", &"c", 100_000_000, 1_000_000, "construction_rate")
	var coarse_id: int = (coarse_parts[1] as WorkService).create(
			&"construction", &"c", 100_000_000, 1_000_000, "construction_rate")
	(fine_parts[0] as TickScheduler).advance_fine_n(12 * 240)
	(coarse_parts[0] as TickScheduler).advance_coarse_n(12)
	var fine_done: int = (fine_parts[1] as WorkService).get_unit(fine_id)["work_done_mu"]
	var coarse_done: int = (coarse_parts[1] as WorkService).get_unit(coarse_id)["work_done_mu"]
	assert_eq(fine_done, 7_838_000, "doc 01 §2.7 arithmetic: 638k + 9×600k + 800k + 1000k")
	assert_eq(coarse_done, fine_done, "fine and coarse work accumulation are exactly equal")


func test_blocked_work_does_not_advance() -> void:
	var parts := _make_scheduler_with_work(3360)
	var work: WorkService = parts[1]
	var id := work.create(&"utility_repair", &"w", 2_000_000, 1_000_000, "")
	work.set_blocked(id, true)
	(parts[0] as TickScheduler).advance_fine_n(240)
	assert_eq(int(work.get_unit(id)["work_done_mu"]), 0)
	work.set_blocked(id, false)
	(parts[0] as TickScheduler).advance_fine_n(240)
	assert_eq(int(work.get_unit(id)["work_done_mu"]), 1_000_000, "one hour at rate 1M/h, no channel")


func test_work_serialize_roundtrip_mid_carry() -> void:
	var work := WorkService.new()
	var id := work.create(&"construction", &"c", 5_000_000, 1_000_000, "construction_rate")
	var ctx := TimeContext.new()
	ctx.dt_game_seconds = 15
	ctx.channels_hour = {"construction_rate": 0.638}
	work.advance(ctx)  # leaves a non-zero carry
	var unit := work.get_unit(id)
	assert_true(int(unit["carry_mu"]) > 0, "mid-carry state for the round-trip")
	var restored := WorkService.new()
	restored.deserialize(work.serialize())
	work.advance(ctx)
	restored.advance(ctx)
	assert_eq(restored.get_unit(id)["work_done_mu"], work.get_unit(id)["work_done_mu"])
	assert_eq(restored.get_unit(id)["carry_mu"], work.get_unit(id)["carry_mu"])
