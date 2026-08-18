class_name SimSystem
extends RefCounted
## Base contract every simulation system implements (doc 01 §2.5).
## Systems declare a stable id, a phase slot and a cadence; the TickScheduler
## decides when they run. Both advance entry points are mandatory.

enum Phase {
	CLOCK, COMMANDS, TIMERS, EVENTS, WEATHER, DEMAND,
	POWER, WATER, ROADS, VEHICLES, WORK, INCIDENTS,
	CASCADE, DISTRICTS, ECONOMY, POPULATION, DIRECTOR, REPORT,
}

enum Cadence { EVERY_TICK, EVERY_MINUTE, EVERY_HOUR, EVERY_DAY }

const CADENCE_PERIOD_TICKS := {
	Cadence.EVERY_TICK: 1,
	Cadence.EVERY_MINUTE: 4,
	Cadence.EVERY_HOUR: 240,
	Cadence.EVERY_DAY: 5760,
}


func system_id() -> StringName:
	push_error("SimSystem.system_id not implemented")
	return &""


func phase() -> int:
	push_error("SimSystem.phase not implemented")
	return Phase.REPORT


func cadence() -> int:
	return Cadence.EVERY_TICK


func cadence_offset() -> int:
	return 0


func period_ticks() -> int:
	return CADENCE_PERIOD_TICKS[cadence()]


## dt = 15 game-seconds.
func advance_fine(_ctx: TimeContext) -> void:
	pass


## dt = 3600 game-seconds. Must satisfy the coarse contract (doc 01 §2.5):
## ±5% expected equivalence, bounded RNG draws, no render emission.
func advance_coarse(_ctx: TimeContext) -> void:
	pass
