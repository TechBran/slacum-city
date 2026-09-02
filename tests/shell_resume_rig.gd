class_name ShellResumeRig
extends RefCounted
## `game/main.gd`'s catch-up state machine, lifted out so it can be driven a
## frame at a time from a test (report 98 §48).
##
## **This is a MIRROR, and it says so.** `game/main.gd` is the lead's file and
## this branch delivers its changes as snippets; the five methods below are those
## snippets, verbatim apart from the two things a test cannot have — `ui_root`
## becomes a recording stub and `sim_host` becomes [paused] plus [sim]. Every
## decision they make lives in `AndroidLifecycle`, `CatchUpPlanner` or
## `CatchUpCursor` and is pinned there on its own; what is pinned HERE is the
## ORDERING between them, which is the thing the P0 and the first P1 were both
## actually about:
##
## * a cold launch's absence reaches `_on_app_resumed` and reaches it ONCE;
## * a second absence measured mid-veil is queued, not drained on the spot;
## * a pause mid-veil leaves the away report's 'before' alone;
## * the catch-up is the only thing that advances the clock while it runs.
##
## `tests/test_cold_launch_catchup.gd` drives it. When the snippets land in
## `main.gd`, this file stays: it is the only place the ordering is executable
## without a window.

## The live city.
var sim: CitySim
var save_service: SaveService
var lifecycle: AndroidLifecycle

## `SimHost.paused`.
var paused := false
## `Main._title_up` / `Main._restore_cursor != null`.
var title_up := false
var restore_in_flight := false

var _catchup_cursor: CatchUpCursor = null
var _catchup_after: Dictionary = {}
var _catchup_was_paused := false
var _before_snapshot: Dictionary = {}

## What the stub `ui_root` was told, in order. Each veil entry is
## `{hours, total_ticks, capped, cap_real_hours}`; each report is the dictionary
## `present_away_report` was handed.
var veil_calls: Array[Dictionary] = []
var reports: Array[Dictionary] = []
var batches: Array[Array] = []
## How many frames [process_frame] has spent inside `_advance_catchup`.
var catchup_frames := 0
## One slice per frame, so the test counts frames rather than racing a clock.
var slice_units := 1


func setup(p_sim: CitySim, p_service: SaveService, p_lifecycle: AndroidLifecycle) -> void:
	sim = p_sim
	save_service = p_service
	lifecycle = p_lifecycle
	lifecycle.resumed.connect(on_app_resumed)
	lifecycle.paused.connect(on_app_paused)
	lifecycle.catchup_probe = catchup_remainder


func catchup_in_flight() -> bool:
	return _catchup_cursor != null


# --------------------------------------------------------- the main.gd body

## `Main._snapshot_city` — the five figures the away report diffs (doc 12 §2.12).
func snapshot_city(p_sim: CitySim) -> Dictionary:
	return {"treasury": p_sim.treasury.balance,
			"population": p_sim.population.city_population,
			"day_index": p_sim.clock.day_index(),
			"stability": p_sim.districts.city_stability,
			"happiness": p_sim.happiness.happiness}


## `Main._on_app_paused`.
func on_app_paused(_saved: bool) -> void:
	# RR-134: mid-catch-up the 'before' is already in flight and the city under
	# it is a MID-absence one. Overwriting the snapshot here is what made the
	# away report diff a city against itself.
	if _catchup_cursor != null:
		return
	_before_snapshot = snapshot_city(sim)


## `Main._on_app_resumed`.
func on_app_resumed(elapsed_wall_s: float) -> void:
	if title_up or restore_in_flight:
		return
	# A SECOND absence on top of an unfinished one. RR-134: QUEUE it.
	if _catchup_cursor != null:
		lifecycle.defer_absence(elapsed_wall_s)
		return
	var unfinished: Dictionary = lifecycle.take_unfinished_catchup()
	if _before_snapshot.is_empty():
		var carried: Dictionary = unfinished.get("before", {})
		_before_snapshot = carried if not carried.is_empty() else snapshot_city(sim)
	var plan: Dictionary = CatchUpPlanner.plan_after(unfinished,
			int(elapsed_wall_s * 1000.0),
			sim.clock.residual_game_ms, sim.clock.tick_index)
	var total_ticks := int(plan.get("total_ticks", 0))
	veil_calls.append({
		"hours": total_ticks / GameClock.TICKS_PER_HOUR,
		"total_ticks": total_ticks,
		"capped": bool(plan.get("capped", false)),
		"cap_real_hours": int(plan.get("cap_game_hours", 720)) / 60,
	})
	_catchup_was_paused = paused
	paused = true
	_catchup_after = {
		"elapsed_wall_s": elapsed_wall_s + float(unfinished.get("elapsed_wall_s", 0.0)),
		"residual_game_ms": int(plan.get("new_residual_game_ms", 0)),
		"capped": bool(plan.get("capped", false)),
		"cap_game_hours": float(int(plan.get("cap_game_hours", 720))),
	}
	_catchup_cursor = sim.begin_catchup(plan)
	advance_catchup()


## `Main._advance_catchup`, with the wall-clock budget replaced by [slice_units]
## so a test can stop a catch-up in the middle deterministically.
func advance_catchup() -> void:
	catchup_frames += 1
	var done := false
	var spent := 0
	while not done:
		done = _catchup_cursor.step()
		spent += 1
		if spent >= slice_units:
			break
	if done:
		finish_catchup()


## `Main._finish_catchup`.
func finish_catchup() -> void:
	_catchup_cursor = null
	paused = _catchup_was_paused
	sim.clock.residual_game_ms = int(_catchup_after.get("residual_game_ms", 0))
	var offline_batch: Array = sim.bus.drain()
	batches.append(offline_batch)
	var elapsed_wall_s := float(_catchup_after.get("elapsed_wall_s", 0.0))
	var capped := bool(_catchup_after.get("capped", false))
	var cap_game_hours := float(_catchup_after.get("cap_game_hours", 720.0))
	_catchup_after = {}
	# The 'before' belongs to the absence that just finished. A QUEUED second
	# absence gets its own, captured in [on_app_resumed] from the city this
	# catch-up left behind — which is exactly the city it was then away from.
	var before := _before_snapshot
	_before_snapshot = {}
	if before.is_empty() or elapsed_wall_s < 60.0:
		return
	reports.append({
		"elapsed_wall_s": elapsed_wall_s,
		"elapsed_game_minutes": elapsed_wall_s,
		"before": before,
		"after": snapshot_city(sim),
		"capped": capped,
		"cap_game_hours": cap_game_hours,
		"events_digest": offline_batch,
	})


## `Main._catchup_remainder` — what the pause stamp carries across a process
## death (doc 13 §3.2's `last_pause.unfinished`, RR-134).
func catchup_remainder() -> Dictionary:
	if _catchup_cursor == null:
		return {}
	var rest := _catchup_cursor.remaining_plan()
	if int(rest.get("total_ticks", 0)) <= 0:
		return {}
	rest["new_residual_game_ms"] = int(_catchup_after.get("residual_game_ms", 0))
	rest["elapsed_wall_s"] = float(_catchup_after.get("elapsed_wall_s", 0.0))
	if not _before_snapshot.is_empty():
		rest["before"] = _before_snapshot.duplicate()
	return rest


## `Main._process`'s first three branches, and nothing after them: the live HUD
## and render work below is not what this rig is for.
func process_frame() -> void:
	if restore_in_flight:
		return
	if _catchup_cursor != null:
		advance_catchup()
		# A queued absence starts on the SAME frame the one in front of it
		# finished. `SimHost` is this node's child and therefore processes
		# after it, so nothing live can tick between two absences (RR-134).
		if _catchup_cursor == null and not title_up:
			lifecycle.pump_resume()
		return
	if not title_up:
		lifecycle.pump_resume()


## Frames until nothing is owed and nothing is in flight, or `limit` — which is
## a failure the caller asserts on rather than a hang.
func run_until_settled(limit: int = 200000) -> int:
	var frames := 0
	while frames < limit:
		if _catchup_cursor == null and not lifecycle.owes_resume():
			return frames
		process_frame()
		frames += 1
	return frames
