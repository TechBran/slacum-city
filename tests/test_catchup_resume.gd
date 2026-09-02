extends SimTest
## BACKGROUNDING MID-CATCH-UP (report 98 §48, RR-134) — the first P1.
##
## **The defect.** `Main._on_app_resumed` used to answer a second absence
## arriving on top of an unfinished one with `_catchup_cursor.run()` —
## *drain the whole rest of the plan on this frame*. Up to 720 coarse steps in
## one go, which on the benchmark city is 720 x 165 ms = 119 s of blocked main
## thread and an ANR twenty-four times over. And the pause in between had already
## committed a MID-ABSENCE city and overwritten `_before_snapshot` with it, so
## the away report diffed the city against a version of itself that was already
## half way through the absence it was reporting.
##
## **The ruling (doc 93 §AG): SEQUENTIAL, never merged, and never re-derived.**
## What is unspent of plan 1 is carried as SEGMENTS, in front of plan 2's, in one
## schedule. The alternative — turning the remainder back into "owed
## milliseconds" and re-planning — cannot reproduce plan 1's head-alignment, its
## 40-tick fine tail or its residual, and cannot reproduce the segment-relative
## `ctx.catchup_index` that doc 03's offline yield decay and doc 07's 72-hour
## event gate both read. This file proves the carried version is bit-identical
## and the arithmetic version could not have been.

const TEST_DIR := "user://test_catchup_resume/slots"
const T0 := 1_800_000_000.0
const FOUR_HOURS_MS := 4 * 3_600_000


class ClockRig extends RefCounted:
	var wall: float = T0
	var mono: float = 100.0

	func wall_now() -> float:
		return wall

	func mono_now() -> float:
		return mono


class CountingRouter extends NotificationRouter:
	var planned := 0
	var replanned := 0

	func plan_for_background(_sim: Object = null,
			_now_unix: float = -1.0) -> Array[Dictionary]:
		planned += 1
		return [] as Array[Dictionary]

	func replan_after_resume(_now_unix: float = -1.0) -> int:
		replanned += 1
		return 0


static func _wipe(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	var files: Array[String] = []
	var dirs: Array[String] = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			dirs.append(entry)
		else:
			files.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	for child in files:
		DirAccess.remove_absolute(path + "/" + child)
	for child in dirs:
		_wipe(path + "/" + child)
		DirAccess.remove_absolute(path + "/" + child)


func _fresh_service() -> SaveService:
	var service := SaveService.new()
	service.base_dir = TEST_DIR
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_wipe(TEST_DIR)
	return service


func _lifecycle(service: SaveService, sim: CitySim, rig: ClockRig) -> AndroidLifecycle:
	var lifecycle := AndroidLifecycle.new()
	lifecycle.setup(service, sim)
	lifecycle.wall_clock = rig.wall_now
	lifecycle.mono_clock = rig.mono_now
	return lifecycle


# ===========================================================================
# CatchUpCursor.remaining_plan
# ===========================================================================

func test_an_untouched_cursor_owes_its_whole_plan() -> void:
	var sim := CitySim.boot_from_files(3)
	var plan := CatchUpPlanner.plan(FOUR_HOURS_MS, 0, sim.clock.tick_index)
	var cursor := sim.begin_catchup(plan)
	var rest := cursor.remaining_plan()
	assert_eq(int(rest["total_ticks"]), int(plan["total_ticks"]))
	assert_eq(CatchUpPlanner.segments_total_ticks(rest), int(plan["total_ticks"]))


func test_a_finished_cursor_owes_nothing() -> void:
	var sim := CitySim.boot_from_files(3)
	var cursor := sim.begin_catchup(CatchUpPlanner.plan(FOUR_HOURS_MS, 0,
			sim.clock.tick_index))
	cursor.run()
	var rest := cursor.remaining_plan()
	assert_eq(int(rest["total_ticks"]), 0)
	assert_true((rest["segments"] as Array).is_empty())


func test_the_remainder_plus_what_was_spent_is_always_the_whole_plan() -> void:
	var sim := CitySim.boot_from_files(3)
	sim.scheduler.advance_fine_n(137)   # a mid-hour offset, so there IS a head
	var plan := CatchUpPlanner.plan(FOUR_HOURS_MS, 0, sim.clock.tick_index)
	var cursor := sim.begin_catchup(plan)
	var total := int(plan["total_ticks"])
	for _i in 137:
		cursor.step()
		assert_eq(cursor.done_ticks() + int(cursor.remaining_plan()["total_ticks"]),
				total, "spent + owed is invariant")


func test_a_plan_carried_across_a_process_death_is_BIT_IDENTICAL() -> void:
	# The load-bearing claim of RR-134. Two cities, the same absence: one runs
	# the plan straight through, the other is interrupted 130 units in and
	# finishes from the carried remainder alone.
	var whole := CitySim.boot_from_files(918_442)
	whole.advance_hours(2.0)
	var interrupted := CitySim.boot_from_files(918_442)
	interrupted.advance_hours(2.0)
	assert_eq(whole.state_hash(), interrupted.state_hash(), "the same starting city")

	var plan := CatchUpPlanner.plan(FOUR_HOURS_MS, whole.clock.residual_game_ms,
			whole.clock.tick_index)
	whole.begin_catchup(plan).run()

	var cursor := interrupted.begin_catchup(plan)
	for _i in 130:
		cursor.step()
	var carried := cursor.remaining_plan()
	assert_true(int(carried["total_ticks"]) > 0, "the interruption left work")
	# The process dies here; `carried` is what the pause stamp holds.
	interrupted.begin_catchup(carried).run()

	assert_eq(interrupted.clock.tick_index, whole.clock.tick_index)
	assert_eq(interrupted.state_hash(), whole.state_hash(),
			"a plan finished from its carried remainder is the same city as one "
			+ "that was never interrupted")


func test_a_partly_spent_coarse_segment_keeps_its_segment_index() -> void:
	# The seam that makes the claim above true. A coarse hour reads
	# `ctx.catchup_index` / `ctx.catchup_total`, so the tail of a segment has to
	# be told it is hours 4..9 of 10, not hours 0..5 of 6.
	var sim := CitySim.boot_from_files(5)
	var plan := CatchUpPlanner.plan(FOUR_HOURS_MS, 0, 0)
	var cursor := sim.begin_catchup(plan)
	# Spend the fine head and four coarse hours.
	while cursor.steps_done() < 44:
		cursor.step()
	var rest := cursor.remaining_plan()
	var coarse: Dictionary = {}
	for segment: Dictionary in rest["segments"]:
		if String(segment["kind"]) == "coarse":
			coarse = segment
			break
	assert_false(coarse.is_empty(), "the remainder still has a coarse body")
	assert_true(int(coarse["index_base"]) > 0,
			"the carried segment knows how many of its hours are already gone")
	assert_eq(int(coarse["total"]), int(coarse["count"]) + int(coarse["index_base"]),
			"and it still reports the ORIGINAL segment length")


# ===========================================================================
# CatchUpPlanner.plan_after
# ===========================================================================

func test_plan_after_with_no_remainder_is_just_plan() -> void:
	var a := CatchUpPlanner.plan_after({}, FOUR_HOURS_MS, 400, 137)
	var b := CatchUpPlanner.plan(FOUR_HOURS_MS, 400, 137)
	assert_eq(int(a["total_ticks"]), int(b["total_ticks"]))
	assert_eq(int(a["new_residual_game_ms"]), int(b["new_residual_game_ms"]))
	assert_eq((a["segments"] as Array).size(), (b["segments"] as Array).size())


func test_plan_after_puts_the_remainder_in_front_and_counts_both() -> void:
	var head := {"segments": [{"kind": "coarse", "count": 3, "index_base": 2,
			"total": 5}], "new_residual_game_ms": 7_500}
	var merged := CatchUpPlanner.plan_after(head, FOUR_HOURS_MS, 0, 0)
	assert_eq(CatchUpPlanner.segments_total_ticks(merged), int(merged["total_ticks"]),
			"the merged segments still add up to the merged total")
	var tail := CatchUpPlanner.plan(FOUR_HOURS_MS, 7_500, 3 * GameClock.TICKS_PER_HOUR)
	assert_eq(int(merged["total_ticks"]),
			3 * GameClock.TICKS_PER_HOUR + int(tail["total_ticks"]))
	assert_eq(int(merged["new_residual_game_ms"]), int(tail["new_residual_game_ms"]),
			"the residual is the LAST plan's — the head's was already consumed")
	assert_eq(String((merged["segments"][0] as Dictionary)["kind"]), "coarse")
	assert_eq(int((merged["segments"][0] as Dictionary)["index_base"]), 2,
			"the carried segment's index survives the merge")


func test_two_absences_run_sequentially_land_where_one_merged_plan_would() -> void:
	# Doc 93 §AG's ruling checked from the other side: crediting absence 1 then
	# absence 2 has to be the same city as crediting them as one schedule, or
	# "sequential" would be a different game from "merged".
	var sequential := CitySim.boot_from_files(777)
	var merged := CitySim.boot_from_files(777)
	var p1 := CatchUpPlanner.plan(FOUR_HOURS_MS, 0, sequential.clock.tick_index)
	var cursor1 := sequential.begin_catchup(p1)
	for _i in 90:
		cursor1.step()
	var carried := cursor1.remaining_plan()
	var p2 := CatchUpPlanner.plan_after(carried, 3_600_000,
			int(p1["new_residual_game_ms"]),
			sequential.clock.tick_index + int(carried["total_ticks"]))
	sequential.begin_catchup(carried).run()
	sequential.clock.residual_game_ms = int(p1["new_residual_game_ms"])
	var tail_only := CatchUpPlanner.plan(3_600_000, int(p1["new_residual_game_ms"]),
			sequential.clock.tick_index)
	sequential.begin_catchup(tail_only).run()
	sequential.clock.residual_game_ms = int(tail_only["new_residual_game_ms"])

	var cursor_m := merged.begin_catchup(p1)
	for _i in 90:
		cursor_m.step()
	merged.begin_catchup(p2).run()
	merged.clock.residual_game_ms = int(p2["new_residual_game_ms"])

	assert_eq(merged.clock.tick_index, sequential.clock.tick_index)
	assert_eq(merged.state_hash(), sequential.state_hash())


# ===========================================================================
# The shell: a second absence is QUEUED
# ===========================================================================

func _world(seed_value: int) -> Dictionary:
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(seed_value)
	sim.advance_hours(2.0)
	var rig := ClockRig.new()
	var lifecycle := _lifecycle(service, sim, rig)
	var router := CountingRouter.new()
	lifecycle.notification_router = router
	var shell := ShellResumeRig.new()
	shell.setup(sim, service, lifecycle)
	return {"sim": sim, "service": service, "lifecycle": lifecycle,
			"rig": rig, "shell": shell, "router": router}


func _free(world: Dictionary) -> void:
	(world["lifecycle"] as AndroidLifecycle).free()
	(world["service"] as SaveService).free()


func test_a_second_absence_mid_veil_is_queued_not_drained() -> void:
	var world := _world(31)
	var shell: ShellResumeRig = world["shell"]
	var life: AndroidLifecycle = world["lifecycle"]
	var rig: ClockRig = world["rig"]

	life.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	rig.wall += 4.0 * 3600.0
	life.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	assert_true(shell.catchup_in_flight(), "the first absence is running")
	var frames_at_interrupt := shell.catchup_frames

	# Backgrounded again, with the veil still up.
	life.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	rig.wall += 3_600.0
	life.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	assert_true(shell.catchup_in_flight(),
			"the OLD plan is still stepping — it was not drained on the spot")
	assert_eq(life.deferred_absences.size(), 1,
			"and the second absence is queued rather than dropped")

	shell.run_until_settled()
	assert_eq(shell.veil_calls.size(), 2, "two absences, two veils, in order")
	assert_true(shell.catchup_frames > frames_at_interrupt + 2,
			"the rest of plan 1 was spent a slice at a time, not in one frame")
	assert_eq(int(shell.veil_calls[0]["total_ticks"]), 240 * 240,
			"4 real hours = 57,600 ticks")
	assert_eq(int(shell.veil_calls[1]["total_ticks"]), 60 * 240,
			"then 1 real hour = 14,400 ticks")
	assert_false(life.owes_resume())
	_free(world)


func test_the_pause_mid_veil_does_not_overwrite_the_away_report_s_before() -> void:
	var world := _world(32)
	var shell: ShellResumeRig = world["shell"]
	var life: AndroidLifecycle = world["lifecycle"]
	var rig: ClockRig = world["rig"]
	var sim: CitySim = world["sim"]

	life.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	var pre_absence_day := sim.clock.day_index()
	rig.wall += 4.0 * 3600.0
	life.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	shell.process_frame()
	shell.process_frame()
	var mid_day := sim.clock.day_index()
	assert_true(mid_day >= pre_absence_day)

	life.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	rig.wall += 120.0
	life.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	shell.run_until_settled()

	assert_true(shell.reports.size() >= 1)
	var first: Dictionary = shell.reports[0]
	assert_eq(int((first["before"] as Dictionary)["day_index"]), pre_absence_day,
			"the 'before' is the PRE-absence city, not the one the mid-veil "
			+ "pause committed")
	assert_true(int((first["after"] as Dictionary)["day_index"]) > pre_absence_day)
	_free(world)


func test_a_pause_mid_veil_is_tagged_and_plans_no_notifications() -> void:
	var world := _world(33)
	var shell: ShellResumeRig = world["shell"]
	var life: AndroidLifecycle = world["lifecycle"]
	var rig: ClockRig = world["rig"]
	var service: SaveService = world["service"]
	var router: CountingRouter = world["router"]

	life.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	assert_eq(router.planned, 1, "an ordinary pause schedules its alarms")
	rig.wall += 4.0 * 3600.0
	life.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	assert_true(shell.catchup_in_flight())

	life.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	assert_eq(router.planned, 1,
			"a pause mid-catch-up plans NOTHING: the city it would predict from "
			+ "is still being simulated")
	var listed := service.list_slots()
	var reason := ""
	for entry: Dictionary in listed:
		if int(entry.get("slot", -1)) == SaveService.AUTOSAVE_SLOT:
			reason = String(entry.get("save_reason", ""))
	assert_eq(reason, "pause_mid_catchup",
			"and the generation says so, so a cold launch can finish the plan")
	assert_true(SaveService.SYNC_REASONS.has("pause_mid_catchup"),
			"it is a sync write for the same reason `pause` is")
	_free(world)


# ===========================================================================
# The two orderings, end to end
# ===========================================================================

func _cold_relaunch(seed_value: int, at_wall: float) -> Dictionary:
	var service := SaveService.new()
	service.base_dir = TEST_DIR
	var sim := CitySim.boot_from_files(seed_value)
	var rig := ClockRig.new()
	rig.wall = at_wall
	var lifecycle := _lifecycle(service, sim, rig)
	var shell := ShellResumeRig.new()
	shell.setup(sim, service, lifecycle)
	return {"sim": sim, "service": service, "lifecycle": lifecycle,
			"rig": rig, "shell": shell}


func test_ordering_A_process_death_mid_veil_finishes_the_plan_on_relaunch() -> void:
	var world := _world(41)
	var shell: ShellResumeRig = world["shell"]
	var life: AndroidLifecycle = world["lifecycle"]
	var rig: ClockRig = world["rig"]
	var sim: CitySim = world["sim"]

	life.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	rig.wall += 4.0 * 3600.0
	life.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	shell.process_frame()
	shell.process_frame()
	var owed := int(shell.catchup_remainder()["total_ticks"])
	assert_true(owed > 0, "there is unspent plan")
	# The pause that commits the mid-absence city, then the process dies.
	life.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	var saved_ticks := sim.clock.tick_index

	var cold := _cold_relaunch(41, rig.wall + 1.0)
	var cold_life: AndroidLifecycle = cold["lifecycle"]
	var cold_service: SaveService = cold["service"]
	var cold_sim: CitySim = cold["sim"]
	assert_true(cold_service.load_slot(cold_sim, SaveService.AUTOSAVE_SLOT))
	assert_eq(cold_sim.clock.tick_index, saved_ticks, "it loaded the mid-absence city")
	assert_true(cold_life.arm_cold_resume(cold_service),
			"and it is armed even though only ~1 s of NEW absence passed")
	(cold["shell"] as ShellResumeRig).run_until_settled()
	assert_eq(cold_sim.clock.tick_index, saved_ticks + owed,
			"the relaunch finished EXACTLY the plan the death interrupted")
	_free(world)
	cold_life.free()
	cold_service.free()


func test_ordering_B_death_mid_veil_then_a_long_absence_credits_both() -> void:
	var world := _world(42)
	var shell: ShellResumeRig = world["shell"]
	var life: AndroidLifecycle = world["lifecycle"]
	var rig: ClockRig = world["rig"]
	var sim: CitySim = world["sim"]

	life.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	rig.wall += 4.0 * 3600.0
	life.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	shell.process_frame()
	shell.process_frame()
	var owed := int(shell.catchup_remainder()["total_ticks"])
	life.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	var saved_ticks := sim.clock.tick_index

	# The phone stayed off for two more real hours before the relaunch.
	var cold := _cold_relaunch(42, rig.wall + 2.0 * 3600.0)
	var cold_life: AndroidLifecycle = cold["lifecycle"]
	var cold_service: SaveService = cold["service"]
	var cold_sim: CitySim = cold["sim"]
	var cold_shell: ShellResumeRig = cold["shell"]
	assert_true(cold_service.load_slot(cold_sim, SaveService.AUTOSAVE_SLOT))
	assert_true(cold_life.arm_cold_resume(cold_service))
	cold_shell.run_until_settled()

	assert_eq(cold_shell.veil_calls.size(), 1,
			"the unfinished tail and the new absence are ONE schedule, one veil")
	assert_eq(cold_sim.clock.tick_index - saved_ticks, owed + 120 * 240,
			"the interrupted plan's remainder AND 2 real hours of new absence")
	assert_eq(int(cold_shell.veil_calls[0]["total_ticks"]), owed + 120 * 240,
			"and the veil counted both")
	_free(world)
	cold_life.free()
	cold_service.free()
