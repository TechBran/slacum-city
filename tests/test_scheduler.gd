extends SimTest
## Doc 01 T-02 (cadence counts), T-03 (phase-order stability),
## T-04 (one-step lag contract), plus coarse-mode firing.


class CountProbe extends SimSystem:
	var id: StringName
	var probe_phase: int
	var probe_cadence: int
	var fine_calls: int = 0
	var coarse_calls: int = 0

	func _init(p_id: StringName, p_phase: int, p_cadence: int) -> void:
		id = p_id
		probe_phase = p_phase
		probe_cadence = p_cadence

	func system_id() -> StringName:
		return id

	func phase() -> int:
		return probe_phase

	func cadence() -> int:
		return probe_cadence

	func advance_fine(_ctx: TimeContext) -> void:
		fine_calls += 1

	func advance_coarse(_ctx: TimeContext) -> void:
		coarse_calls += 1


class OrderProbe extends SimSystem:
	var id: StringName
	var probe_phase: int
	var recorder: Array

	func _init(p_id: StringName, p_phase: int, p_recorder: Array) -> void:
		id = p_id
		probe_phase = p_phase
		recorder = p_recorder

	func system_id() -> StringName:
		return id

	func phase() -> int:
		return probe_phase

	func cadence() -> int:
		return Cadence.EVERY_TICK

	func advance_fine(_ctx: TimeContext) -> void:
		recorder.append(String(id))


class StabilityWriter extends SimSystem:
	var shared: Dictionary

	func _init(p_shared: Dictionary) -> void:
		shared = p_shared

	func system_id() -> StringName:
		return &"districts"

	func phase() -> int:
		return Phase.DISTRICTS

	func cadence() -> int:
		return Cadence.EVERY_TICK

	func advance_fine(ctx: TimeContext) -> void:
		shared["written_at"] = ctx.tick_index


class StabilityReader extends SimSystem:
	var shared: Dictionary
	var observed_lags: Array = []

	func _init(p_shared: Dictionary) -> void:
		shared = p_shared

	func system_id() -> StringName:
		return &"incidents"

	func phase() -> int:
		return Phase.INCIDENTS

	func cadence() -> int:
		return Cadence.EVERY_TICK

	func advance_fine(ctx: TimeContext) -> void:
		if shared.has("written_at"):
			observed_lags.append(ctx.tick_index - int(shared["written_at"]))


func _make_scheduler(start_tick: int = 0) -> TickScheduler:
	var clock := GameClock.new()
	clock.tick_index = start_tick
	var curves := DayCurveSet.new()
	var script: GDScript = load("res://tests/test_day_curves.gd")
	curves.load_from(script.load_time_data())
	return TickScheduler.new(clock, curves, ModifierStack.new())


func test_cadence_counts_from_zero() -> void:
	var scheduler := _make_scheduler(0)
	var tick_probe := CountProbe.new(&"a", SimSystem.Phase.POWER, SimSystem.Cadence.EVERY_TICK)
	var minute_probe := CountProbe.new(&"b", SimSystem.Phase.INCIDENTS, SimSystem.Cadence.EVERY_MINUTE)
	var hour_probe := CountProbe.new(&"c", SimSystem.Phase.ECONOMY, SimSystem.Cadence.EVERY_HOUR)
	var day_probe := CountProbe.new(&"d", SimSystem.Phase.POPULATION, SimSystem.Cadence.EVERY_DAY)
	for probe in [tick_probe, minute_probe, hour_probe, day_probe]:
		scheduler.register(probe)
	scheduler.advance_fine_n(5760)
	assert_eq(tick_probe.fine_calls, 5760)
	assert_eq(minute_probe.fine_calls, 1440)
	assert_eq(hour_probe.fine_calls, 24)
	assert_eq(day_probe.fine_calls, 1)


func test_cadence_counts_nonaligned_start() -> void:
	var scheduler := _make_scheduler(918442)
	var minute_probe := CountProbe.new(&"b", SimSystem.Phase.INCIDENTS, SimSystem.Cadence.EVERY_MINUTE)
	var hour_probe := CountProbe.new(&"c", SimSystem.Phase.ECONOMY, SimSystem.Cadence.EVERY_HOUR)
	var day_probe := CountProbe.new(&"d", SimSystem.Phase.POPULATION, SimSystem.Cadence.EVERY_DAY)
	for probe in [minute_probe, hour_probe, day_probe]:
		scheduler.register(probe)
	scheduler.advance_fine_n(5760)
	assert_eq(minute_probe.fine_calls, 1440)
	assert_eq(hour_probe.fine_calls, 24)
	assert_eq(day_probe.fine_calls, 1)


func test_phase_order_stable_across_registration_orders() -> void:
	# T-03: shuffled registration must never change execution order.
	var ids: Array[StringName] = [&"water", &"power", &"clock", &"report", &"roads", &"weather"]
	var phases: Array[int] = [
		SimSystem.Phase.WATER, SimSystem.Phase.POWER, SimSystem.Phase.CLOCK,
		SimSystem.Phase.REPORT, SimSystem.Phase.ROADS, SimSystem.Phase.WEATHER,
	]
	var expected := ["clock", "weather", "power", "water", "roads", "report"]
	var orders := [[0, 1, 2, 3, 4, 5], [5, 4, 3, 2, 1, 0], [3, 0, 5, 1, 4, 2], [2, 5, 0, 4, 1, 3]]
	for order in orders:
		var recorder: Array = []
		var scheduler := _make_scheduler(0)
		for i: int in order:
			scheduler.register(OrderProbe.new(ids[i], phases[i], recorder))
		scheduler.advance_fine_n(1)
		assert_eq(recorder, expected, "order %s" % [order])


func test_same_phase_ties_break_by_system_id() -> void:
	var recorder: Array = []
	var scheduler := _make_scheduler(0)
	scheduler.register(OrderProbe.new(&"zeta", SimSystem.Phase.POWER, recorder))
	scheduler.register(OrderProbe.new(&"alpha", SimSystem.Phase.POWER, recorder))
	scheduler.advance_fine_n(1)
	assert_eq(recorder, ["alpha", "zeta"])


func test_one_step_lag_contract() -> void:
	# T-04: a P13 write is observed by a P11 reader exactly one step later.
	var shared := {}
	var scheduler := _make_scheduler(0)
	var reader := StabilityReader.new(shared)
	scheduler.register(StabilityWriter.new(shared))
	scheduler.register(reader)
	scheduler.advance_fine_n(50)
	assert_eq(reader.observed_lags.size(), 49, "reader sees nothing on the first tick")
	for lag in reader.observed_lags:
		assert_eq(lag, 1, "always exactly one step, never zero, never two")


func test_coarse_firing_and_clock_advance() -> void:
	var scheduler := _make_scheduler(0)
	var tick_probe := CountProbe.new(&"a", SimSystem.Phase.POWER, SimSystem.Cadence.EVERY_TICK)
	var hour_probe := CountProbe.new(&"c", SimSystem.Phase.ECONOMY, SimSystem.Cadence.EVERY_HOUR)
	var day_probe := CountProbe.new(&"d", SimSystem.Phase.POPULATION, SimSystem.Cadence.EVERY_DAY)
	for probe in [tick_probe, hour_probe, day_probe]:
		scheduler.register(probe)
	scheduler.advance_coarse_n(48)
	assert_eq(scheduler.clock.tick_index, 48 * 240)
	assert_eq(tick_probe.coarse_calls, 48, "one integrated call per coarse hour")
	assert_eq(hour_probe.coarse_calls, 48)
	assert_eq(day_probe.coarse_calls, 2, "day boundaries at tick 0 and 5760")
	assert_eq(tick_probe.fine_calls, 0)


func test_context_channels_present() -> void:
	var scheduler := _make_scheduler(0)
	var captured := {}
	var probe := ContextCapture.new(captured)
	scheduler.register(probe)
	scheduler.advance_fine_n(1)
	var ctx: TimeContext = captured["ctx"]
	assert_eq(ctx.channels.size(), 15, "all 15 channels resolved (doc 01 T-22)")
	assert_eq(ctx.channels_hour.size(), 15)
	assert_true(ctx.channels.has("traffic_density"))
	assert_eq(ctx.dt_game_seconds, 15)
	assert_eq(ctx.day_phase, &"DAWN")


class ContextCapture extends SimSystem:
	var captured: Dictionary

	func _init(p_captured: Dictionary) -> void:
		captured = p_captured

	func system_id() -> StringName:
		return &"capture"

	func phase() -> int:
		return Phase.CLOCK

	func cadence() -> int:
		return Cadence.EVERY_TICK

	func advance_fine(ctx: TimeContext) -> void:
		captured["ctx"] = ctx
