class_name CatchUpPlanner
extends RefCounted
## Converts real elapsed ms into a deterministic advance schedule
## (doc 01 §2.10, cap amended to 12 real hours per report 98 C-19).
## Same input ⇒ same schedule, which is what makes constitution §5's offline
## determinism guarantee literally true.
##
## **Two clamps, not one (Wave 17, report 98 §48 / RR-133).** [OFFLINE_CAP_REAL_MS]
## is doc 01's C-19 outer bound and has always been here. Doc 08 §2.12's
## `max_coarse_hours` is a second, *performance*-derived clamp that may only ever
## be tighter — it was NORMATIVE prose in doc 08 and implemented nowhere until
## this wave (`grep -rn max_coarse_hours sim/ game/ data/` returned nothing).
## It arrives from `data/persistence.json` through `SavePolicy`, never from a
## live measurement: a clamp that changed with the device would make the same
## absence credit two different cities on two phones, and constitution §5 forbids
## exactly that. See [derive_max_coarse_hours] for the rule, stated once.
##
## **A plan can also be RESUMED (RR-134).** A catch-up that is interrupted by a
## process death mid-veil leaves unspent segments behind; [plan_after] puts them
## back in front of the next absence's plan, in order, as one schedule. The
## alternative — re-deriving the remainder from an elapsed measurement — cannot
## reproduce the head-alignment or the residual the interrupted plan was computed
## with, so the doc-93 §AG ruling is *sequential concatenation, never arithmetic*.

const OFFLINE_CAP_REAL_MS: int = 43200000  # 12 real hours = 720 game-hours
const OFFLINE_GRACE_MS: int = 120000
const FINE_CATCHUP_MAX_TICKS: int = 20
const FINE_TAIL_TICKS: int = 40
const GAME_MS_PER_TICK: int = 15000
## One GAME hour of absence costs this many REAL ms (1 real s = 1 game min at 1x).
const REAL_MS_PER_GAME_HOUR: int = 60000

## Doc 08 §2.12's numerator: the total catch-up work budget, in ms.
const CATCHUP_WORK_BUDGET_MS: float = 2000.0
## Doc 08 §2.12's floor — below three game-days of creditable absence the FULL
## band never ends and the fidelity model stops meaning anything.
const MAX_COARSE_HOURS_FLOOR: int = 72
## Doc 08 §2.12's ceiling — doc 01's C-19 cap, in game hours.
const MAX_COARSE_HOURS_CEIL: int = 720

static var _configured_max_coarse_hours: int = 0


## Doc 08 §2.12's decision rule, NORMATIVE and stated exactly once:
##
##     raw    = ceil(2000 / measured_coarse_ms)
##     floorm = floor(raw / 24) * 24
##     result = clamp(floorm, 72, 720)
##
## `measured_coarse_ms <= 0` means "nobody measured", and the honest answer to
## that is doc 01's cap — a clamp derived from no measurement may not discard a
## player's time.
static func derive_max_coarse_hours(measured_coarse_ms: float) -> int:
	if measured_coarse_ms <= 0.0:
		return MAX_COARSE_HOURS_CEIL
	var raw := int(ceil(CATCHUP_WORK_BUDGET_MS / measured_coarse_ms))
	var floorm := (raw / 24) * 24
	return clampi(floorm, MAX_COARSE_HOURS_FLOOR, MAX_COARSE_HOURS_CEIL)


## The shipped clamp, in game hours — `data/persistence.json`'s `catchup` block
## through `SavePolicy` (which caches its parse, so this is one dictionary read
## after the first call). Tests override it with [set_max_coarse_hours].
static func configured_max_coarse_hours() -> int:
	if _configured_max_coarse_hours <= 0:
		_configured_max_coarse_hours = SavePolicy.load_from_files().max_coarse_hours
	return clampi(_configured_max_coarse_hours, MAX_COARSE_HOURS_FLOOR, MAX_COARSE_HOURS_CEIL)


## Force the clamp for a test. `0` restores "read the file again".
static func set_max_coarse_hours(hours: int) -> void:
	_configured_max_coarse_hours = hours


## Returns {credited_real_ms, capped, total_ticks, new_residual_game_ms,
##          cap_real_ms, cap_game_hours, discarded_real_ms,
##          segments: [{kind: "fine"|"coarse", count}]}  (coarse count in hours)
##
## `max_coarse_hours` overrides the shipped clamp for one call; 0 means "use the
## shipped one". It can only ever make the credited window SMALLER than doc 01's
## cap, never larger.
static func plan(elapsed_real_ms: int, residual_game_ms: int, tick_index: int,
		max_coarse_hours: int = 0) -> Dictionary:
	var cap_hours := max_coarse_hours if max_coarse_hours > 0 else configured_max_coarse_hours()
	cap_hours = clampi(cap_hours, MAX_COARSE_HOURS_FLOOR, MAX_COARSE_HOURS_CEIL)
	var cap_ms := mini(OFFLINE_CAP_REAL_MS, cap_hours * REAL_MS_PER_GAME_HOUR)
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
		residual_game_ms: int, tick_index: int,
		max_coarse_hours: int = 0) -> Dictionary:
	var head_segments: Array = unfinished.get("segments", [])
	var head_ticks := segments_total_ticks({"segments": head_segments})
	if head_ticks <= 0:
		return plan(elapsed_real_ms, residual_game_ms, tick_index, max_coarse_hours)
	var head_residual := int(unfinished.get("new_residual_game_ms", residual_game_ms))
	var tail := plan(elapsed_real_ms, head_residual, tick_index + head_ticks, max_coarse_hours)
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
