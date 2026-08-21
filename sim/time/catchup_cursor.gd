class_name CatchUpCursor
extends RefCounted
## An offline catch-up, cut into resumable units (doc 13 §2.9, A91-D-31).
##
## `game/main.gd::_on_app_resumed` ran `CatchUpPlanner`'s segments in one
## synchronous `for` loop, so the veil S15 raises in front of it drew for exactly
## one frame and then froze until the whole absence had been simulated. On the
## benchmark city a coarse step is ~130–190 ms and a 12-hour absence is 720 of
## them, so that freeze is measured in SECONDS. This is the other half of doc 13
## §2.9's own design: hand the shell a cursor and let it spend units until its
## frame budget is gone.
##
## **The unit is ONE COARSE HOUR or ONE FINE TICK — the smallest indivisible
## piece of a plan — and the BUDGET lives in the shell**, exactly as it does for
## `RestoreCursor`. `sim/` may not read a clock (constitution §5), so a cursor
## cannot decide for itself that it has spent long enough; and doc 13 §2.9's own
## table says the honest slice on any city whose coarse step is over ~6 ms is one
## step per frame anyway. The shell writes
##
##     var t0 := Time.get_ticks_usec()
##     while not cursor.step():
##         if Time.get_ticks_usec() - t0 >= CATCHUP_SLICE_USEC:
##             break
##
## which spends 12 ms of whole steps and returns the frame. ANR safety is
## structural and not budgetary for the same reason it is there: a single step
## longer than the budget still runs to completion, so the main loop is blocked
## for at most ONE coarse step against Android's 5 s line — a 25× margin at the
## benchmark city's 190 ms.
##
## **Slicing may not change the simulation, and the seam that guarantees it is
## `TickScheduler.advance_coarse_n`'s `catchup_index_base`.** A coarse step reads
## `ctx.catchup_index` / `ctx.catchup_total` — doc 03's offline yield decay
## (`EconomySystem.offline_yield_mult`) and doc 07's 72-hour offline event gate
## both consume them — so an hour has to be told which hour OF ITS SEGMENT it is,
## not which hour of its slice. This cursor therefore issues
## `advance_coarse_n(1, true, hours_done_in_segment, segment_hours)` where the
## monolithic path issued `advance_coarse_n(n, true, 0, n)` once, and the two
## produce byte-identical `TimeContext`s.  `catchup_begin()` fires ONCE per coarse
## segment, at its first unit, where `CitySim.advance_coarse_hours` fired it once
## per call (doc 07 C-55). `tests/test_catchup_cursor.gd` proves bit-identity on
## both cities, at four different slice sizes, including a hash of the drained
## event bus.
##
## The planner's segments are already hour-aligned (doc 91 D-1), so every coarse
## unit starts on an hour boundary and `advance_coarse_n`'s own assert holds at
## every seam. Nothing may tick, render or query the sim between [step] calls for
## the same reason `RestoreCursor` says so: mid-catch-up is a real sim state, but
## it is not the state the shell's HUD, the bus drain or the away report are
## written against — those run after [is_done].

const KIND_COARSE := "coarse"

var _scheduler: TickScheduler
## Called with no arguments before the FIRST unit of each coarse segment — doc 07
## C-55's `DisasterDirector.catchup_begin`. Empty is legal (a sim with no
## director, which is what most road and power tests boot).
var _on_coarse_segment_begin: Callable

var _segments: Array = []
var _segment: int = 0        # index into _segments
var _unit: int = 0           # units already spent inside _segments[_segment]
var _done_ticks: int = 0
var _total_ticks: int = 0
var _steps_done: int = 0
var _steps_total: int = 0


func _init(p_scheduler: TickScheduler, plan: Dictionary,
		p_on_coarse_segment_begin: Callable = Callable()) -> void:
	_scheduler = p_scheduler
	_on_coarse_segment_begin = p_on_coarse_segment_begin
	# Segments with a non-positive count are dropped HERE rather than skipped in
	# `step()`: a unit that does nothing would still cost the shell a frame, and
	# `steps_total()` is a progress bar's denominator.
	for segment: Dictionary in plan.get("segments", []):
		var count := int(segment.get("count", 0))
		if count <= 0:
			continue
		var coarse := String(segment.get("kind", "")) == KIND_COARSE
		_segments.append({"coarse": coarse, "count": count})
		_steps_total += count
		_total_ticks += count * GameClock.TICKS_PER_HOUR if coarse else count
	_skip_empty()


## Ticks this plan will advance in total — `CatchUpPlanner`'s own `total_ticks`,
## recomputed from the segments so a caller cannot hand the veil one number and
## the sim another.
func total_ticks() -> int:
	return _total_ticks


## Ticks advanced so far. This is what `UIRoot.advance_veil_catchup()` wants: it
## is proportional to GAME time, which is the only thing the catch-up phase's bar
## can honestly claim (doc 13 §2.9.1's argument, from the other side).
func done_ticks() -> int:
	return _done_ticks


## Units in the plan — coarse hours plus fine ticks. Doc 13 §2.9's
## `steps_total()`; the veil uses [done_ticks] instead, because a fine tick and a
## coarse hour are one step each and 1/240 of an hour apart.
func steps_total() -> int:
	return _steps_total


func steps_done() -> int:
	return _steps_done


func is_done() -> bool:
	return _segment >= _segments.size()


## Spend exactly ONE unit. Returns [is_done] afterwards, so a caller can write
## `while not cursor.step():` and never ask twice. Calling it on a finished
## cursor is a no-op, not an error — a veil that runs one frame long must not
## crash the catch-up it was hiding.
func step() -> bool:
	if is_done():
		return true
	var segment: Dictionary = _segments[_segment]
	if bool(segment["coarse"]):
		if _unit == 0 and _on_coarse_segment_begin.is_valid():
			_on_coarse_segment_begin.call()
		# `_unit` IS the segment-relative hour index, which is the whole point:
		# see the class doc. `catchup_total` is the segment's own length.
		_scheduler.advance_coarse_n(1, true, _unit, int(segment["count"]))
		_done_ticks += GameClock.TICKS_PER_HOUR
	else:
		_scheduler.advance_fine_n(1)
		_done_ticks += 1
	_unit += 1
	_steps_done += 1
	if _unit >= int(segment["count"]):
		_segment += 1
		_unit = 0
	_skip_empty()
	return is_done()


## Drain every remaining unit now. This is what the synchronous resume was, and
## it is what a tool, a test or a shell with no frame to protect still wants.
func run() -> void:
	while not is_done():
		step()


# A plan whose segments are all empty must report `is_done()` from the start,
# and `_init` already dropped those — this is the guard that keeps `step()` from
# ever landing on one if the drop rule is ever relaxed.
func _skip_empty() -> void:
	while _segment < _segments.size() and int(_segments[_segment]["count"]) <= 0:
		_segment += 1
		_unit = 0
