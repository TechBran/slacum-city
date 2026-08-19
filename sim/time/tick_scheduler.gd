class_name TickScheduler
extends RefCounted
## The spine (doc 01 §2.3–2.5). One registry, 18 phases, four cadences.
## Systems are sorted by (phase, system_id) so registration order can never
## affect results. Fine and coarse advances drive the same registry in the
## same phase order.
##
## Firing rule (both modes): a system with period P and offset O runs on a step
## starting at tick t iff (t - O) mod P == 0. Coarse steps must start
## hour-aligned (CatchUpPlanner's head-align guarantees it), so hourly systems
## fire at the same tick boundaries online and offline.

var clock: GameClock
var curves: DayCurveSet
var modifiers: ModifierStack
var speed: int = 1
var paused: bool = false

var _systems: Array[SimSystem] = []
# Per-hour channel cache: recomputed when (day, hour, modifier revision) changes.
var _hour_cache_key := Vector3i(-1, -1, -1)
var _hour_cache: Dictionary = {}

## Opt-in per-system timing hook for tools/profile_sim.gd. OFF by default and
## the profiled path is a SEPARATE loop, so an unprofiled step pays exactly one
## boolean test per step — never one per system, never a call.
##
## The scheduler owns no clock of its own (constitution §3 forbids `Time` inside
## sim/): the tool injects two Callables and does the measuring. Purely
## observational — it changes no ordering, no RNG draw, no state.
##   profile_enter.call(id: StringName)
##   profile_exit.call(id: StringName)
var profiling: bool = false
var profile_enter: Callable = Callable()
var profile_exit: Callable = Callable()


func _init(p_clock: GameClock, p_curves: DayCurveSet, p_modifiers: ModifierStack) -> void:
	clock = p_clock
	curves = p_curves
	modifiers = p_modifiers


func register(system: SimSystem) -> void:
	assert(system.system_id() != &"", "system needs a stable id")
	_systems.append(system)
	_systems.sort_custom(_system_less)


func system_count() -> int:
	return _systems.size()


func advance_fine_n(n: int) -> void:
	for i in n:
		_step_fine()


func advance_coarse_n(hours: int, is_catchup: bool = false, catchup_index_base: int = 0, catchup_total: int = 0) -> void:
	assert(clock.tick_index % GameClock.TICKS_PER_HOUR == 0,
			"coarse advance requires an hour-aligned tick_index (head-align first)")
	for h in hours:
		_step_coarse(is_catchup, catchup_index_base + h, catchup_total)


func _step_fine() -> void:
	if profiling:
		_step_fine_profiled()
		return
	var t := clock.tick_index
	var ctx := _build_context(TimeContext.Mode.FINE)
	for system in _systems:
		if (t - system.cadence_offset()) % system.period_ticks() == 0:
			system.advance_fine(ctx)
	clock.tick_index += 1


func _step_coarse(is_catchup: bool, catchup_index: int, catchup_total: int) -> void:
	if profiling:
		_step_coarse_profiled(is_catchup, catchup_index, catchup_total)
		return
	var t := clock.tick_index
	var ctx := _build_context(TimeContext.Mode.COARSE)
	ctx.is_catchup = is_catchup
	ctx.catchup_index = catchup_index
	ctx.catchup_total = catchup_total
	for system in _systems:
		# t is hour-aligned, so EVERY_TICK/MINUTE/HOUR always fire (one
		# integrated call for the hour); EVERY_DAY fires only on day boundary.
		if (t - system.cadence_offset()) % system.period_ticks() == 0:
			system.advance_coarse(ctx)
	clock.tick_index += GameClock.TICKS_PER_HOUR


# ------------------------------------------------------------- profiled twins
# Byte-identical work to the loops above, wrapped in the injected hook. They
# exist only so the unprofiled loops stay free of any per-system branch.

func _step_fine_profiled() -> void:
	var t := clock.tick_index
	profile_enter.call(&"@context")
	var ctx := _build_context(TimeContext.Mode.FINE)
	profile_exit.call(&"@context")
	for system in _systems:
		if (t - system.cadence_offset()) % system.period_ticks() == 0:
			var id := system.system_id()
			profile_enter.call(id)
			system.advance_fine(ctx)
			profile_exit.call(id)
	clock.tick_index += 1


func _step_coarse_profiled(is_catchup: bool, catchup_index: int, catchup_total: int) -> void:
	var t := clock.tick_index
	profile_enter.call(&"@context")
	var ctx := _build_context(TimeContext.Mode.COARSE)
	ctx.is_catchup = is_catchup
	ctx.catchup_index = catchup_index
	ctx.catchup_total = catchup_total
	profile_exit.call(&"@context")
	for system in _systems:
		if (t - system.cadence_offset()) % system.period_ticks() == 0:
			var id := system.system_id()
			profile_enter.call(id)
			system.advance_coarse(ctx)
			profile_exit.call(id)
	clock.tick_index += GameClock.TICKS_PER_HOUR


func _build_context(mode: int) -> TimeContext:
	var ctx := TimeContext.new()
	ctx.tick_index = clock.tick_index
	ctx.game_seconds = clock.game_seconds()
	ctx.mode = mode
	ctx.dt_game_seconds = 15 if mode == TimeContext.Mode.FINE else 3600
	ctx.minute_of_day = clock.minute_of_day()
	ctx.hour_of_day = clock.hour_of_day()
	ctx.day_index = clock.day_index()
	ctx.day_of_week = clock.day_of_week()
	ctx.day_type = clock.day_type()
	ctx.day_phase = clock.day_phase()
	ctx.season_index = clock.season_index()
	ctx.season_progress = clock.season_progress()
	ctx.speed = speed
	if mode == TimeContext.Mode.FINE:
		ctx.hour_midpoint = clock.fine_sample_hour()
	else:
		ctx.hour_midpoint = float(clock.hour_of_day()) + 0.5
	ctx.channels_hour = _hour_channels()
	if mode == TimeContext.Mode.COARSE:
		ctx.channels = ctx.channels_hour
	else:
		for channel_name in curves.channel_names():
			var value: float = curves.channel_curve_value(channel_name, ctx.hour_midpoint) \
					* modifiers.product_for(channel_name)
			ctx.channels[channel_name] = curves.channel_clamp(channel_name, value)
	return ctx


func _hour_channels() -> Dictionary:
	var key := Vector3i(clock.day_index(), clock.hour_of_day(), modifiers.revision)
	if key == _hour_cache_key:
		return _hour_cache
	var midpoint := float(clock.hour_of_day()) + 0.5
	var out := {}
	for channel_name in curves.channel_names():
		var value: float = curves.channel_curve_value(channel_name, midpoint) \
				* modifiers.product_for(channel_name)
		out[channel_name] = curves.channel_clamp(channel_name, value)
	_hour_cache_key = key
	_hour_cache = out
	return out


static func _system_less(a: SimSystem, b: SimSystem) -> bool:
	if a.phase() != b.phase():
		return a.phase() < b.phase()
	return String(a.system_id()) < String(b.system_id())


## Break the sim ↔ scheduler ↔ adapter reference cycle (doc 91 D-9): every
## phase adapter holds its CitySim strongly while the sim holds this scheduler,
## so a RefCounted-only sim can never free itself. Call when a sim is retired.
func dispose() -> void:
	_systems.clear()
