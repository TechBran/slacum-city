extends SimTest
## Doc 01 T-11 (planner determinism) and T-13 (cap and grace, 12 h per C-19).
##
## **RE-PINNED 2026-09-03 — report 98 §58 / RR-160.** Wave 17 (RR-133) added
## doc 08 §2.12's `max_coarse_hours` as a SECOND clamp on the credited absence
## and shipped it at 360 game-hours = 6 real hours, and the two assertions below
## had to pass the C-19 cap explicitly to say what doc 01's ladder does. That
## clamp is deleted: the credited absence is doc 01's cap and there is no
## argument to `plan()` by which anything can tighten it, so the explicit and
## default forms are once again the same call. What a player on this build gets
## and what doc 01 §2.10 specifies are the same plan.


func test_worked_example_6h12m() -> void:
	# Doc 01 §2.10: away 6 h 12 m at tick 918 442 -> 38 fine, 371 coarse, 162 fine, 40 fine.
	# This is what a player on this build actually gets. Under the Wave-18
	# clamp the same absence was capped at 6 h and 12 minutes of it were thrown
	# away; doc 01's ladder is unclamped again.
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


func test_the_same_absence_is_no_longer_capped_at_all() -> void:
	# The Wave-18 regression, named where it was pinned. This assertion used to
	# read `assert_true(plan["capped"])` — the shipped clamp discarded 12 of the
	# absence's 372 minutes and the report was told to say so. RR-160: 6 h 12 m
	# is a normal absence and every minute of it is credited.
	var plan := CatchUpPlanner.plan(22_320_000, 0, 918442)
	assert_false(bool(plan["capped"]), "6 h 12 m is well inside doc 01's 12-hour cap")
	assert_eq(int(plan["credited_real_ms"]), 22_320_000)
	assert_eq(int(plan["discarded_real_ms"]), 0)
	assert_eq(int(plan["cap_game_hours"]), CatchUpPlanner.OFFLINE_CAP_GAME_HOURS)
	assert_eq(int(plan["cap_real_hours"]), CatchUpPlanner.OFFLINE_CAP_REAL_HOURS)
	assert_eq(CatchUpPlanner.segments_total_ticks(plan), int(plan["total_ticks"]))


func test_grace_window() -> void:
	var plan := CatchUpPlanner.plan(90_000, 0, 1000)
	assert_eq(plan["total_ticks"], 0, "90 s is inside the grace window")
	assert_eq((plan["segments"] as Array).size(), 0)
	var plan2 := CatchUpPlanner.plan(130_000, 0, 1000)
	assert_eq(plan2["total_ticks"], 520, "130 s credits in full, not minus grace")


func test_cap_12_hours() -> void:
	# 26 real hours -> capped at 12 h = 720 game-hours = 172,800 ticks (report 98
	# C-19). This is doc 01's OUTER bound and, since RR-160, the ONLY bound.
	var plan := CatchUpPlanner.plan(26 * 3_600_000, 0, 0)
	assert_true(bool(plan["capped"]))
	assert_eq(plan["credited_real_ms"], 43_200_000)
	assert_eq(plan["total_ticks"], 172_800)
	assert_eq(CatchUpPlanner.segments_total_ticks(plan), 172_800)


func test_the_credited_window_is_C_19_and_nothing_narrower() -> void:
	# Both directions in one assertion: an over-cap absence credits exactly the
	# cap, and every absence UNDER it credits itself. Wave 18 failed the second
	# half — 8 real hours credited 6 (report 98 §58, RR-160).
	assert_eq(int(CatchUpPlanner.plan(26 * 3_600_000, 0, 0)["credited_real_ms"]),
			CatchUpPlanner.OFFLINE_CAP_REAL_MS)
	for hours in [3, 6, 8, 11, 12]:
		var plan := CatchUpPlanner.plan(hours * 3_600_000, 0, 0)
		assert_eq(int(plan["credited_real_ms"]), hours * 3_600_000,
				"%d real hours away credits %d" % [hours, hours])
		assert_eq(int(plan["cap_game_hours"]), CatchUpPlanner.OFFLINE_CAP_GAME_HOURS)


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
