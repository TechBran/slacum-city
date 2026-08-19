class_name RoadsPhaseSystems
extends RefCounted
## The doc 01 scheduler adapters for the roads subsystem, so integrating doc 10
## into `CitySim` is three lines rather than a sixty-line paste:
##
##     roads = RoadNetwork.new(world.grid, RoadTunables.from_file(), rng)
##     roads.bootstrap()
##     RoadsPhaseSystems.register_all(scheduler, roads, bus.emit)
##
## All three sit in phase **P08 `ROADS`** (doc 01 §2.4), between WATER (P07) and
## VEHICLES (P09). Their system ids sort as `roads` → `roads_congestion` →
## `roads_daily`, which is exactly the order the cadences must run in: apply
## edits and re-read power, then the congestion pass, then the daily decay that
## consumes that day's congestion samples.
##
## Cadence is declared as DATA (doc 01 §2.5) — roads owns no internal timers.

const SYSTEM_ID_STEP := &"roads"
const SYSTEM_ID_MINUTE := &"roads_congestion"
const SYSTEM_ID_DAY := &"roads_daily"


## Registers all three adapters. `emit` is `SimEventBus.emit` (or any
## `func(type: StringName, payload: Dictionary)`); pass an empty Callable to
## drain events yourself via `RoadNetwork.drain_events()`.
static func register_all(scheduler: TickScheduler, network: RoadNetwork,
		emit: Callable = Callable()) -> Array:
	var systems: Array = [
		StepSystem.new(network, emit),
		MinuteSystem.new(network),
		DaySystem.new(network),
	]
	for system in systems:
		scheduler.register(system)
	return systems


## EVERY_TICK, fine AND coarse: batched edits → dirty rebuild → signal power →
## closure/override expiry → dirty-set congestion. Drains the event queue last,
## so a listener never sees a half-applied step.
class StepSystem extends SimSystem:
	var network: RoadNetwork
	var emit: Callable

	func _init(p_network: RoadNetwork, p_emit: Callable = Callable()) -> void:
		network = p_network
		emit = p_emit

	func system_id() -> StringName:
		return RoadsPhaseSystems.SYSTEM_ID_STEP

	func phase() -> int:
		return Phase.ROADS

	func cadence() -> int:
		return Cadence.EVERY_TICK

	func advance_fine(ctx: TimeContext) -> void:
		network.step(ctx)
		_drain()

	## Coarse (offline) steps run the IDENTICAL code with dt = 60 gm. Only the
	## async polyline planner and the cosmetic feed sit out — no vehicle needs a
	## polyline offline, and doc 06's offline dispatch uses route_minutes(),
	## which is available in both modes (§4).
	func advance_coarse(ctx: TimeContext) -> void:
		network.step(ctx)
		_drain()

	func _drain() -> void:
		if not emit.is_valid():
			return
		for event in network.drain_events():
			emit.call(StringName(String(event["type"])), event)


## EVERY_MINUTE: the full congestion pass across all edges, the c_day hourly
## sample, and the TrafficSnapshot rebuild.
class MinuteSystem extends SimSystem:
	var network: RoadNetwork

	func _init(p_network: RoadNetwork) -> void:
		network = p_network

	func system_id() -> StringName:
		return RoadsPhaseSystems.SYSTEM_ID_MINUTE

	func phase() -> int:
		return Phase.ROADS

	func cadence() -> int:
		return Cadence.EVERY_MINUTE

	func advance_fine(ctx: TimeContext) -> void:
		network.full_pass(ctx)

	func advance_coarse(ctx: TimeContext) -> void:
		network.full_pass(ctx)


## EVERY_DAY: condition decay, L_dens refresh, auto-repair queueing.
## Makes NO billing call of any kind — roads carry no standing upkeep (RR-2).
class DaySystem extends SimSystem:
	var network: RoadNetwork

	func _init(p_network: RoadNetwork) -> void:
		network = p_network

	func system_id() -> StringName:
		return RoadsPhaseSystems.SYSTEM_ID_DAY

	func phase() -> int:
		return Phase.ROADS

	func cadence() -> int:
		return Cadence.EVERY_DAY

	func advance_fine(ctx: TimeContext) -> void:
		network.on_day(ctx)

	func advance_coarse(ctx: TimeContext) -> void:
		network.on_day(ctx)
