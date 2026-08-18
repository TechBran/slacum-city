class_name CatchUpPlanner
extends RefCounted
## Converts real elapsed ms into a deterministic advance schedule
## (doc 01 §2.10, cap amended to 12 real hours per report 98 C-19).
## Same input ⇒ same schedule, which is what makes constitution §5's offline
## determinism guarantee literally true.

const OFFLINE_CAP_REAL_MS: int = 43200000  # 12 real hours = 720 game-hours
const OFFLINE_GRACE_MS: int = 120000
const FINE_CATCHUP_MAX_TICKS: int = 20
const FINE_TAIL_TICKS: int = 40
const GAME_MS_PER_TICK: int = 15000


## Returns {credited_real_ms, capped, total_ticks, new_residual_game_ms,
##          segments: [{kind: "fine"|"coarse", count}]}  (coarse count in hours)
static func plan(elapsed_real_ms: int, residual_game_ms: int, tick_index: int) -> Dictionary:
	var credited := 0
	var capped := false
	if elapsed_real_ms >= OFFLINE_GRACE_MS:
		credited = mini(elapsed_real_ms, OFFLINE_CAP_REAL_MS)
		capped = elapsed_real_ms > OFFLINE_CAP_REAL_MS
	var game_ms := credited * 60 + residual_game_ms
	var total_ticks := game_ms / GAME_MS_PER_TICK
	var new_residual := game_ms % GAME_MS_PER_TICK
	var segments: Array[Dictionary] = []
	if total_ticks <= FINE_CATCHUP_MAX_TICKS:
		if total_ticks > 0:
			segments.append({"kind": "fine", "count": total_ticks})
	else:
		var tail := mini(FINE_TAIL_TICKS, total_ticks)
		var head_align := (GameClock.TICKS_PER_HOUR - (tick_index % GameClock.TICKS_PER_HOUR)) \
				% GameClock.TICKS_PER_HOUR
		var head := mini(head_align, total_ticks - tail)
		var coarse_hours := (total_ticks - tail - head) / GameClock.TICKS_PER_HOUR
		var mid_fine := total_ticks - tail - head - coarse_hours * GameClock.TICKS_PER_HOUR
		if head > 0:
			segments.append({"kind": "fine", "count": head})
		if coarse_hours > 0:
			segments.append({"kind": "coarse", "count": coarse_hours})
		if mid_fine > 0:
			segments.append({"kind": "fine", "count": mid_fine})
		if tail > 0:
			segments.append({"kind": "fine", "count": tail})
	return {
		"credited_real_ms": credited,
		"capped": capped,
		"total_ticks": total_ticks,
		"new_residual_game_ms": new_residual,
		"segments": segments,
	}


## Total ticks across a plan's segments — must always equal plan.total_ticks.
static func segments_total_ticks(plan_result: Dictionary) -> int:
	var total := 0
	for segment in plan_result["segments"]:
		if String(segment["kind"]) == "coarse":
			total += int(segment["count"]) * GameClock.TICKS_PER_HOUR
		else:
			total += int(segment["count"])
	return total
