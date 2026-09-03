class_name CatchUpPlanner
extends RefCounted
## Converts real elapsed ms into a deterministic advance schedule
## (doc 01 §2.10, cap amended to 12 real hours per report 98 C-19).
## Same input ⇒ same schedule, which is what makes constitution §5's offline
## determinism guarantee literally true.
##
## **ONE clamp, and it is a fairness clamp (Wave 19, report 98 §58 / RR-160).**
## [OFFLINE_CAP_REAL_MS] is doc 01's C-19 outer bound and it is the ONLY thing
## that bounds what a returning player is credited. There is no second clamp and
## there is no argument to [plan] by which a caller can credit less: the window
## is a property of the design, not of the workstation the build was packaged on.
##
## **What was here before, and why it was wrong.** Wave 17 (RR-133) implemented
## doc 08 §2.12's `max_coarse_hours` — `clamp(floor(ceil(2000/measured_coarse_ms)
## /24)*24, 72, 720)` — and fed it into this function as a second, tighter cap.
## Measured at 5.488 ms/coarse-hour it shipped as 360 game-hours, so the credited
## absence was **6 real hours** and the seventh, eighth and ninth hours of a
## night paid nothing. Doc 92 §55 measures what that cost: an eight-hour night on
## a settled L3 city paid $281,319 where the uncapped absence pays $354,830, and
## a twelve-hour absence paid 57.5% of what those hours were worth.
##
## The defect was not the arithmetic — it was the AXIS. A performance budget
## bounds how long the catch-up VEIL takes; it may never bound what the player is
## paid for being away. Doc 08 §2.12 now says so, the budget it publishes
## (`veil_budget_ms`) is a wall-clock gate measured by `tests/test_catchup_veil_budget.gd`,
## and **nothing in `sim/` or `game/` reads it** — which is the structural half of
## the fix. `veil_ms_at_cap` below is the estimator that gate uses; it is a static
## function of a measurement and it never touches a plan's credit.
##
## **A plan can also be RESUMED (RR-134).** A catch-up that is interrupted by a
## process death mid-veil leaves unspent segments behind; [plan_after] puts them
## back in front of the next absence's plan, in order, as one schedule. The
## alternative — re-deriving the remainder from an elapsed measurement — cannot
## reproduce the head-alignment or the residual the interrupted plan was computed
## with, so the doc-93 §AG ruling is *sequential concatenation, never arithmetic*.

const OFFLINE_CAP_REAL_MS: int = 43200000  # 12 real hours = 720 game-hours
## The same cap in GAME hours — doc 01 C-19's other face, stated once so no
## caller has to divide.
const OFFLINE_CAP_GAME_HOURS: int = 720
## And in REAL hours, which is the unit a player sleeps in and the unit the away
## report and the veil quote (RR-162).
const OFFLINE_CAP_REAL_HOURS: int = 12
const OFFLINE_GRACE_MS: int = 120000
const FINE_CATCHUP_MAX_TICKS: int = 20
const FINE_TAIL_TICKS: int = 40
const GAME_MS_PER_TICK: int = 15000
## One GAME hour of absence costs this many REAL ms (1 real s = 1 game min at 1x).
const REAL_MS_PER_GAME_HOUR: int = 60000
const REAL_MS_PER_REAL_HOUR: int = 3600000


## Doc 08 §2.12's performance budget, applied to the thing it is a budget FOR:
## the wall clock a full-cap catch-up spends behind the veil, estimated from one
## measured coarse hour.
##
## This is an ESTIMATOR for a gate, never an input to [plan]. It is `static` and
## takes its measurement as an argument for exactly that reason — there is no
## instance state it could quietly reach a credit through.
static func veil_ms_at_cap(measured_coarse_ms: float) -> float:
	return maxf(0.0, measured_coarse_ms) * float(OFFLINE_CAP_GAME_HOURS)


## `true` when a city whose coarse hour costs `measured_coarse_ms` finishes a
## full 12-real-hour catch-up inside `budget_ms`. When it is `false` the answer
## is a cheaper coarse hour (doc 92 §55.7 AC-19-1) — never a smaller credit.
static func meets_veil_budget(measured_coarse_ms: float, budget_ms: float) -> bool:
	return veil_ms_at_cap(measured_coarse_ms) <= budget_ms


## Returns {credited_real_ms, capped, total_ticks, new_residual_game_ms,
##          cap_real_ms, cap_game_hours, cap_real_hours, discarded_real_ms,
##          segments: [{kind: "fine"|"coarse", count}]}  (coarse count in hours)
##
## There is deliberately no `max_hours` argument. RR-160: the credited absence is
## doc 01's cap and nothing else may tighten it, and a parameter that could is a
## parameter someone will eventually pass.
static func plan(elapsed_real_ms: int, residual_game_ms: int,
		tick_index: int) -> Dictionary:
	var cap_ms := OFFLINE_CAP_REAL_MS
	var credited := 0
	var capped := false
	if elapsed_real_ms >= OFFLINE_GRACE_MS:
		credited = mini(elapsed_real_ms, cap_ms)
		capped = elapsed_real_ms > cap_ms
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
		"cap_real_ms": cap_ms,
		"cap_game_hours": cap_ms / REAL_MS_PER_GAME_HOUR,
		# The away report and the veil quote the cap in the unit the player was
		# away in, not in city time (RR-162). Carried rather than divided at the
		# call site so the two surfaces cannot disagree.
		"cap_real_hours": cap_ms / REAL_MS_PER_REAL_HOUR,
		"discarded_real_ms": maxi(0, elapsed_real_ms - credited) if capped else 0,
		"segments": segments,
	}


## The plan for "finish what was interrupted, THEN credit the new absence"
## (RR-134). `unfinished` is a [CatchUpCursor.remaining_plan] tail — `{}` when
## nothing was interrupted, in which case this is exactly [plan].
##
## The tail is planned from the clock the head will LEAVE the sim on
## (`tick_index + head_ticks`, and the interrupted plan's own final residual),
## which is the same clock an uninterrupted pair of absences would have handed
## it. That is the whole reason the head is carried as SEGMENTS rather than as a
## count of owed milliseconds: `plan()`'s head-alignment, its 40-tick fine tail
## and its residual are not recoverable from a duration.
static func plan_after(unfinished: Dictionary, elapsed_real_ms: int,
		residual_game_ms: int, tick_index: int) -> Dictionary:
	var head_segments: Array = unfinished.get("segments", [])
	var head_ticks := segments_total_ticks({"segments": head_segments})
	if head_ticks <= 0:
		return plan(elapsed_real_ms, residual_game_ms, tick_index)
	var head_residual := int(unfinished.get("new_residual_game_ms", residual_game_ms))
	var tail := plan(elapsed_real_ms, head_residual, tick_index + head_ticks)
	var segments: Array[Dictionary] = []
	for segment: Variant in head_segments:
		segments.append((segment as Dictionary).duplicate())
	for segment: Dictionary in tail["segments"]:
		segments.append(segment)
	tail["segments"] = segments
	tail["total_ticks"] = head_ticks + int(tail["total_ticks"])
	# The head's real ms were credited by the plan that made it; re-reporting
	# them keeps the away report's "credited" honest across the interruption.
	tail["credited_real_ms"] = int(tail["credited_real_ms"]) \
			+ head_ticks * GAME_MS_PER_TICK / 60
	tail["resumed_head_ticks"] = head_ticks
	return tail


## Total ticks across a plan's segments — must always equal plan.total_ticks.
static func segments_total_ticks(plan_result: Dictionary) -> int:
	var total := 0
	for segment in plan_result.get("segments", []):
		if String(segment["kind"]) == "coarse":
			total += int(segment["count"]) * GameClock.TICKS_PER_HOUR
		else:
			total += int(segment["count"])
	return total
