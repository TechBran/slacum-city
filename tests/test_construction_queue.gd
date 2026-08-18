extends SimTest
## Doc 02 §2.13 + §2.10: the project queue — exact integer progress, worked
## example E3, refund table, crew binding/preemption, reordering.


func _ctx(eff: float, dt_gs: int = 15) -> TimeContext:
	var ctx := TimeContext.new()
	ctx.dt_game_seconds = dt_gs
	ctx.channels_hour = {"construction_rate": eff}
	return ctx


func test_max_crews_rule() -> void:
	assert_eq(ConstructionQueue.max_crews_for(4.0), 1)
	assert_eq(ConstructionQueue.max_crews_for(30.0), 2, "E3: 1 + floor(30/20)")
	assert_eq(ConstructionQueue.max_crews_for(65.0), 4)
	assert_eq(ConstructionQueue.max_crews_for(200.0), 4, "cap at 4")


func test_e3_two_crews_at_mean_rate() -> void:
	# Doc 02 E3: office L4→L5, 30 crew-hours, two crews at the 0.804 mean →
	# 18.7 game-hours of wall time.
	var queue := ConstructionQueue.new()
	var job_id := queue.submit(&"upgrade", "O-001", 30.0)
	queue.assign_crew(job_id, "CREW-1")
	queue.assign_crew(job_id, "CREW-2")
	assert_eq(queue.assign_crew(job_id, "CREW-3")["reason_code"], &"E_MAX_CREWS")
	var ctx := _ctx(0.804)
	var hours := 0.0
	var completed: Array = []
	while completed.is_empty() and hours < 25.0:
		completed = queue.advance(ctx)
		hours += 15.0 / 3600.0
	assert_almost_eq(hours, 18.66, 0.01, "30 / (2 × 0.804) crew-hours of wall time")
	assert_eq(String(completed[0]["target_ref"]), "O-001")
	assert_eq(queue.active_count(), 0)


func test_single_crew_night_floor() -> void:
	# E3: one crew at the 0.60 night floor → 50 game-hours.
	var queue := ConstructionQueue.new()
	var job_id := queue.submit(&"build", "H-001", 30.0)
	queue.assign_crew(job_id, "CREW-1")
	var ctx := _ctx(0.60)
	var hours := 0.0
	while queue.active_count() > 0 and hours < 60.0:
		queue.advance(ctx)
		hours += 15.0 / 3600.0
	assert_almost_eq(hours, 50.0, 0.01)


func test_fine_coarse_exact_equivalence() -> void:
	var fine := ConstructionQueue.new()
	var coarse := ConstructionQueue.new()
	# Non-round crew rate + site multiplier to stress the integer path.
	for queue in [fine, coarse]:
		var id: int = queue.submit(&"development", "B_3_1", 100.0)
		queue.assign_crew(id, "CREW-1", 1001)
		queue.set_site_mult(id, 0.999)
	for i in 240 * 6:
		fine.advance(_ctx(0.807, 15))
	for i in 6:
		coarse.advance(_ctx(0.807, 3600))
	assert_eq(fine.job(1)["work_units"], coarse.job(1)["work_units"])
	assert_eq(fine.job(1)["carry"], coarse.job(1)["carry"], "bit-exact, carry included")


func test_no_crew_no_progress() -> void:
	var queue := ConstructionQueue.new()
	var job_id := queue.submit(&"road", "R-7", 10.0)
	for i in 240:
		queue.advance(_ctx(1.0))
	assert_eq(int(queue.job(job_id)["work_units"]), 0)
	assert_true(queue.pending_order().has(job_id))


func test_refund_table() -> void:
	var queue := ConstructionQueue.new()
	# Planned, never started → 1.00.
	var planned := queue.submit(&"build", "A", 10.0)
	assert_almost_eq(float(queue.cancel(planned)["payload"]["refund_fraction"]), 1.0, 1e-9)
	# Running new build at 40% → 0.60 × 0.60 = 0.36.
	var build := queue.submit(&"build", "B", 10.0)
	queue.assign_crew(build, "C1")
	var ctx := _ctx(1.0, 3600)
	for i in 4:
		queue.advance(ctx)  # 4 crew-hours of 10 → progress 0.40
	assert_almost_eq(queue.progress(build), 0.40, 0.001)
	assert_almost_eq(float(queue.cancel(build)["payload"]["refund_fraction"]), 0.36, 0.001)
	# Running upgrade → flat 0.50.
	var upgrade := queue.submit(&"upgrade", "C", 10.0)
	queue.assign_crew(upgrade, "C1")
	queue.advance(ctx)
	assert_almost_eq(float(queue.cancel(upgrade)["payload"]["refund_fraction"]), 0.50, 1e-9)


func test_preemption_keeps_progress() -> void:
	var queue := ConstructionQueue.new()
	var job_id := queue.submit(&"repair", "H-002", 10.0)
	queue.assign_crew(job_id, "C1")
	queue.advance(_ctx(1.0, 3600))
	var units_before: int = queue.job(job_id)["work_units"]
	assert_true(units_before > 0)
	queue.release_crew(job_id, "C1", "crew_preempted")
	assert_eq(String(queue.job(job_id)["blocked_reason"]), "crew_preempted")
	assert_true(queue.pending_order().has(job_id), "re-enters the queue")
	queue.advance(_ctx(1.0, 3600))
	assert_eq(int(queue.job(job_id)["work_units"]), units_before, "progress never lost")
	# Crew returns: resumes from where it stopped.
	queue.assign_crew(job_id, "C2")
	assert_eq(String(queue.job(job_id)["blocked_reason"]), "")


func test_reorder_pending_only() -> void:
	var queue := ConstructionQueue.new()
	var a := queue.submit(&"build", "A", 10.0)
	var b := queue.submit(&"build", "B", 10.0)
	var c := queue.submit(&"build", "C", 10.0)
	assert_eq(queue.pending_order(), [a, b, c])
	assert_true(queue.reorder(c, 0))
	assert_eq(queue.pending_order(), [c, a, b])
	queue.assign_crew(a, "C1")  # running job leaves the pending order
	assert_eq(queue.pending_order(), [c, b])
	assert_false(queue.reorder(a, 0), "running jobs are not in the pending order")


func test_serialize_roundtrip_mid_carry() -> void:
	var queue := ConstructionQueue.new()
	var job_id := queue.submit(&"build", "H-003", 7.5, &"construction_crew", {"level": 1})
	queue.assign_crew(job_id, "C1", 1001)
	queue.advance(_ctx(0.807))
	assert_true(int(queue.job(job_id)["carry"]) > 0, "mid-carry state")
	var restored := ConstructionQueue.new()
	restored.deserialize(queue.serialize())
	queue.advance(_ctx(0.807))
	restored.advance(_ctx(0.807))
	assert_eq(restored.job(job_id)["work_units"], queue.job(job_id)["work_units"])
	assert_eq(restored.job(job_id)["carry"], queue.job(job_id)["carry"])
	assert_eq(restored.pending_order(), queue.pending_order())
	assert_eq(int(restored.job(job_id)["payload"]["level"]), 1)
