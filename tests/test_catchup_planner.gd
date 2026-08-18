extends SimTest
## Doc 01 T-11 (planner determinism) and T-13 (cap and grace, 12 h per C-19).


func test_worked_example_6h12m() -> void:
	# Doc 01 §2.10: away 6 h 12 m at tick 918 442 -> 38 fine, 371 coarse, 162 fine, 40 fine.
	var plan := CatchUpPlanner.plan(22_320_000, 0, 918442)
	assert_eq(plan["credited_real_ms"], 22_320_000)
	assert_false(bool(plan["capped"]))
	assert_eq(plan["total_ticks"], 89_280)
	var segments: Array = plan["segments"]
	assert_eq(segments.size(), 4)
	assert_eq(segments[0], {"kind": "fine", "count": 38})
	assert_eq(segments[1], {"kind": "coarse", "count": 371})
	assert_eq(segments[2], {"kind": "fine", "count": 162})
	assert_eq(segments[3], {"kind": "fine", "count": 40})
	assert_eq(CatchUpPlanner.segments_total_ticks(plan), 89_280)


func test_grace_window() -> void:
	var plan := CatchUpPlanner.plan(90_000, 0, 1000)
	assert_eq(plan["total_ticks"], 0, "90 s is inside the grace window")
	assert_eq((plan["segments"] as Array).size(), 0)
	var plan2 := CatchUpPlanner.plan(130_000, 0, 1000)
	assert_eq(plan2["total_ticks"], 520, "130 s credits in full, not minus grace")


func test_cap_12_hours() -> void:
	# 26 real hours -> capped at 12 h = 720 game-hours = 172,800 ticks (report 98 C-19).
	var plan := CatchUpPlanner.plan(26 * 3_600_000, 0, 0)
	assert_true(bool(plan["capped"]))
	assert_eq(plan["credited_real_ms"], 43_200_000)
	assert_eq(plan["total_ticks"], 172_800)
	assert_eq(CatchUpPlanner.segments_total_ticks(plan), 172_800)


func test_short_absence_all_fine() -> void:
	# 5 game-minutes or less runs entirely fine.
	var plan := CatchUpPlanner.plan(0, 15_000 * 18, 500)  # residual only: 18 ticks
	assert_eq(plan["total_ticks"], 18)
	assert_eq((plan["segments"] as Array).size(), 1)
	assert_eq(plan["segments"][0], {"kind": "fine", "count": 18})


func test_residual_carry() -> void:
	var plan := CatchUpPlanner.plan(130_000, 7_400, 1000)
	# game_ms = 7,800,000 + 7,400 = 7,807,400 -> 520 ticks, residual 7,400
	assert_eq(plan["total_ticks"], 520)
	assert_eq(plan["new_residual_game_ms"], 7_400)


func test_conservation_over_random_inputs() -> void:
	# 200 seeded random elapsed values all conserve total ticks across segments.
	var rng := RngStreams.new(777)
	for i in 200:
		var elapsed := rng.stream("misc").randi_range(0, 50_000_000)
		var residual := rng.stream("misc").randi_range(0, 14_999)
		var tick := rng.stream("misc").randi_range(0, 2_000_000)
		var plan := CatchUpPlanner.plan(elapsed, residual, tick)
		assert_eq(CatchUpPlanner.segments_total_ticks(plan), plan["total_ticks"],
				"conservation for elapsed=%d residual=%d tick=%d" % [elapsed, residual, tick])
		var game_ms: int = int(plan["credited_real_ms"]) * 60 + residual
		assert_eq(int(plan["total_ticks"]) * 15_000 + int(plan["new_residual_game_ms"]), game_ms,
				"no game time created or destroyed")


func test_head_alignment_enables_coarse() -> void:
	# From a non-aligned tick, the head segment must land exactly on an hour boundary.
	var plan := CatchUpPlanner.plan(3_600_000, 0, 918442)  # 1 real hour away
	var segments: Array = plan["segments"]
	assert_eq(segments[0], {"kind": "fine", "count": 38}, "918442 mod 240 = 202 -> 38 to align")
	var after_head: int = 918442 + 38
	assert_eq(after_head % 240, 0)
