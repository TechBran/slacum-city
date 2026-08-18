extends SimTest
## Doc 09 §2.3: the six-phase development pipeline — strict ordering, the
## tutorial-block timing (58.3 gh at first_block_time_mult 0.48), fallback
## crew multipliers, pause-between-phases, and cancel-forfeits-phase.


func _world() -> WorldMap:
	var world := WorldMap.new()
	for bz in 7:
		for bx in 7:
			var owned: bool = bx >= 2 and bx <= 4 and bz >= 2 and bz <= 4
			world.add_block(LandBlock.from_dict({
				"id": WorldMap.block_id_for(bx, bz), "grid": [bx, bz],
				"ownership_state": "OWNED" if owned else "LOCKED",
				"development_state": "READY" if owned else "UNDEVELOPED",
			}))
	return world


func _ctx(eff: float, dt_gs: int = 3600) -> TimeContext:
	var ctx := TimeContext.new()
	ctx.dt_game_seconds = dt_gs
	ctx.channels_hour = {"construction_rate": eff}
	return ctx


## Drive queue + controller with an auto-crew that assigns the requested type.
## Small steps (1/16 gh) keep phase-boundary quantization inside the tolerance.
func _run_until_ready(controller: DevelopmentController, queue: ConstructionQueue,
		block_id: String, eff: float, max_hours: int) -> float:
	var hours := 0.0
	while controller.world.block(block_id).development_state != &"READY" and hours < max_hours:
		for job_id in queue.pending_order():
			queue.assign_crew(job_id, "CREW-1")
		for job in queue.advance(_ctx(eff, 225)):
			controller.on_job_completed(job)
		hours += 225.0 / 3600.0
	return hours


func test_tutorial_block_timing() -> void:
	# Doc 09 §2.3: one construction_crew, first block, clear weather:
	# 97.6 effective crew-hours × 0.48 = 46.85 ch → 46.85 / 0.804 = 58.27 gh.
	var world := _world()
	world.block("B_3_1").ownership_state = &"OWNED"
	var queue := ConstructionQueue.new()
	var controller := DevelopmentController.new(world, queue)
	assert_true(bool(controller.start_development("B_3_1", &"construction_crew")["ok"]))
	var hours := _run_until_ready(controller, queue, "B_3_1", 0.804, 80)
	assert_almost_eq(hours, 58.27, 0.5, "doc 09: 58.3 gh for the tutorial block")
	assert_eq(world.block("B_3_1").development_state, &"READY")
	assert_eq(controller.blocks_developed, 1)


func test_heavy_crew_plan_with_graceful_fallback() -> void:
	# Second block (no first-block multiplier), heavy_equipment_crew plan:
	# SURVEY 4 + CLEARING 8 + GRADING 12 + ROAD_INSTALL (falls back to the
	# generic crew at ×1.8 → 25.2) + UTILITY 16 + FINAL 6 = 71.2 crew-hours
	# → 71.2 / 0.804 = 88.56 gh of wall time.
	var world := _world()
	world.block("B_5_3").ownership_state = &"OWNED"
	var queue := ConstructionQueue.new()
	var controller := DevelopmentController.new(world, queue)
	controller.blocks_developed = 1  # not the first block
	assert_true(bool(controller.start_development("B_5_3", &"heavy_equipment_crew")["ok"]))
	var hours := _run_until_ready(controller, queue, "B_5_3", 0.804, 120)
	assert_almost_eq(hours, 88.56, 0.5, "specialist plan degrades gracefully at ROAD_INSTALL")
	assert_eq(world.block("B_5_3").development_state, &"READY")


func test_phase_order_and_events() -> void:
	var world := _world()
	world.block("B_3_1").ownership_state = &"OWNED"
	var queue := ConstructionQueue.new()
	var controller := DevelopmentController.new(world, queue)
	controller.start_development("B_3_1", &"construction_crew")
	var phases_seen: Array = []
	var hours := 0.0
	while world.block("B_3_1").development_state != &"READY" and hours < 80:
		for job_id in queue.pending_order():
			queue.assign_crew(job_id, "CREW-1")
		for job in queue.advance(_ctx(1.0, 900)):
			controller.on_job_completed(job)
		hours += 0.25
	for event in controller.drain_events():
		if event["type"] == &"development_phase_completed":
			phases_seen.append(event["phase"])
	assert_eq(phases_seen, [&"SURVEY", &"CLEARING", &"GRADING", &"ROAD_INSTALL",
			&"UTILITY_CORRIDOR", &"FINAL_DEVELOPMENT"], "strictly in order")
	var block := world.block("B_3_1")
	assert_true(block.survey_revealed)
	assert_almost_eq(block.vegetation_density, 0.0, 1e-9)
	assert_true(block.tags.has("utility_corridor"))


func test_survey_reveals_and_neighbors_gain_access() -> void:
	var world := _world()
	world.block("B_3_1").ownership_state = &"OWNED"
	world.block("B_3_0").road_access = &"NONE"
	var queue := ConstructionQueue.new()
	var controller := DevelopmentController.new(world, queue)
	controller.start_development("B_3_1", &"construction_crew")
	var hours := 0.0
	while world.block("B_3_1").development_state != &"READY" and hours < 80:
		for job_id in queue.pending_order():
			queue.assign_crew(job_id, "CREW-1")
		for job in queue.advance(_ctx(1.0, 900)):
			controller.on_job_completed(job)
		hours += 0.25
	assert_eq(world.block("B_3_0").road_access, &"STUB",
			"ROAD_INSTALL raises undeveloped neighbours to ≥ STUB")


func test_double_start_rejected() -> void:
	var world := _world()
	world.block("B_3_1").ownership_state = &"OWNED"
	var queue := ConstructionQueue.new()
	var controller := DevelopmentController.new(world, queue)
	assert_true(bool(controller.start_development("B_3_1")["ok"]))
	assert_eq(controller.start_development("B_3_1")["reason_code"], &"E_ALREADY_DEVELOPING")
	assert_eq(controller.start_development("B_0_0")["reason_code"], &"E_NOT_OWNED")


func test_pause_between_phases_only() -> void:
	var world := _world()
	world.block("B_3_1").ownership_state = &"OWNED"
	var queue := ConstructionQueue.new()
	var controller := DevelopmentController.new(world, queue)
	controller.start_development("B_3_1", &"construction_crew")
	# Mid-phase (job has progress): rejected.
	for job_id in queue.pending_order():
		queue.assign_crew(job_id, "CREW-1")
	queue.advance(_ctx(1.0, 900))
	assert_eq(controller.pause_development("B_3_1")["reason_code"], &"E_MID_PHASE")
	# Run SURVEY out; pause takes effect between phases (the next phase job is
	# submitted but has no progress → cancelled with full refund).
	var completed: Array = []
	while completed.is_empty():
		completed = queue.advance(_ctx(1.0, 900))
	for job in completed:
		controller.on_job_completed(job)
	assert_true(bool(controller.pause_development("B_3_1")["ok"]))
	assert_eq(queue.active_count(), 0, "pending next-phase job refunded in full")
	# Nothing progresses while paused.
	queue.advance(_ctx(1.0, 3600))
	assert_eq(controller.active_phase("B_3_1"), &"CLEARING")
	# Resume re-submits CLEARING.
	assert_true(bool(controller.resume_development("B_3_1")["ok"]))
	assert_eq(queue.active_count(), 1)


func test_cancel_forfeits_current_phase_keeps_completed() -> void:
	var world := _world()
	world.block("B_3_1").ownership_state = &"OWNED"
	var queue := ConstructionQueue.new()
	var controller := DevelopmentController.new(world, queue)
	controller.start_development("B_3_1", &"construction_crew")
	# Complete SURVEY.
	for job_id in queue.pending_order():
		queue.assign_crew(job_id, "CREW-1")
	var done: Array = []
	while done.is_empty():
		done = queue.advance(_ctx(1.0, 900))
	for job in done:
		controller.on_job_completed(job)
	# CLEARING is mid-flight; cancel forfeits it but keeps SURVEY.
	for job_id in queue.pending_order():
		queue.assign_crew(job_id, "CREW-1")
	queue.advance(_ctx(1.0, 900))
	var cancelled := controller.cancel_development("B_3_1")
	assert_true(bool(cancelled["ok"]))
	assert_eq(int(cancelled["payload"]["resume_at_phase"]), 1, "re-enters at CLEARING")
	assert_true(world.block("B_3_1").survey_revealed, "completed phase effects persist")
	assert_eq(queue.active_count(), 0)


func test_serialize_roundtrip() -> void:
	var world := _world()
	world.block("B_3_1").ownership_state = &"OWNED"
	var queue := ConstructionQueue.new()
	var controller := DevelopmentController.new(world, queue)
	controller.start_development("B_3_1", &"construction_crew")
	controller.blocks_developed = 3
	var restored := DevelopmentController.new(world, ConstructionQueue.new())
	restored.deserialize(controller.serialize())
	assert_eq(restored.blocks_developed, 3)
	assert_eq(restored.active_phase("B_3_1"), &"SURVEY")
