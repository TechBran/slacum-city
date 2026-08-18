class_name SimHost
extends Node
## Owns the CitySim and drives it from real frame time (doc 01 §2.9's
## accumulator: 1 real second = 60 game-seconds × speed, ticks of 15 game-
## seconds, backlog-capped per frame). The ONLY place wall time meets the sim.

signal ticked(batch: Array)

const GAME_MS_PER_REAL_MS := 60.0
const TICK_GAME_MS := 15000
const MAX_TICKS_PER_FRAME := 8

var sim: CitySim
var speed: int = 1
var paused: bool = false
var interpolation_alpha: float = 0.0


func _ready() -> void:
	if sim == null:
		sim = CitySim.boot_from_files()
		if not sim.boot_errors.is_empty():
			push_error("CitySim boot errors: " + ", ".join(sim.boot_errors))


func _process(delta: float) -> void:
	if paused or sim == null:
		return
	sim.clock.residual_game_ms += roundi(delta * 1000.0 * GAME_MS_PER_REAL_MS * speed)
	var n: int = sim.clock.residual_game_ms / TICK_GAME_MS
	sim.clock.residual_game_ms %= TICK_GAME_MS
	n = mini(n, MAX_TICKS_PER_FRAME)
	if n > 0:
		sim.scheduler.advance_fine_n(n)
		var batch := sim.bus.drain()
		if not batch.is_empty():
			ticked.emit(batch)
	interpolation_alpha = clampf(float(sim.clock.residual_game_ms) / float(TICK_GAME_MS), 0.0, 1.0)


func hour_of_day_float() -> float:
	if sim == null:
		return 12.0
	return float(sim.clock.minute_of_day()) / 60.0 \
			+ float(sim.clock.residual_game_ms) / 3_600_000.0
