extends SimTest
## Doc 08 §2.12's NORMATIVE `max_coarse_hours` rule, as implemented
## (report 98 §48, RR-133).
##
## Before this wave the rule was prose and nothing else: `grep -rn
## max_coarse_hours sim/ game/ data/` returned zero hits and
## `CatchUpPlanner.plan` clamped at `OFFLINE_CAP_REAL_MS` alone. Three things
## are pinned here, and they are the three that can rot independently:
##
## 1. **The arithmetic**, against doc 08 §2.12's own worked table, verbatim.
## 2. **The agreement between the measurement and the shipped number.**
##    `data/persistence.json` carries `measured_coarse_ms` AND the derived
##    `max_coarse_hours`; a build must not be able to change one without the
##    other, so the file is re-derived here and the two must match.
## 3. **The clamp reaching the plan, and the copy.** A cap the player is never
##    told about is a silent theft of their time — doc 08 §2.12's own words are
##    "the report says so (`catchup_capped`)".

const HOUR_MS := 3_600_000


func _catchup_block() -> Dictionary:
	var parsed: Variant = JSON.parse_string(
			FileAccess.get_file_as_string("res://data/persistence.json"))
	assert_true(parsed is Dictionary, "data/persistence.json parses")
	var data: Dictionary = parsed
	var block: Variant = data.get("catchup", {})
	assert_true(block is Dictionary, "data/persistence.json carries a catchup block")
	return block


# ===========================================================================
# 1. The rule
# ===========================================================================

func test_the_rule_reproduces_doc_08_s_worked_table() -> void:
	# Every row of doc 08 §2.12's table, which is itself generated from
	# `clamp(floor(ceil(2000/m)/24)*24, 72, 720)`.
	var table := {
		0.6: 720,     # doc 01's retired budget — cap
		2.0: 720,
		2.7: 720,
		4.0: 480,
		8.0: 240,
		27.3: 72,     # doc 08 §2.12's own per-entity accounting
		55.0: 72,     # 24 → below the floor, so the floor wins
	}
	for measured: float in table:
		assert_eq(CatchUpPlanner.derive_max_coarse_hours(measured), int(table[measured]),
				"doc 08 §2.12 row m=%.1f" % measured)


func test_the_two_cities_measured_this_wave() -> void:
	# The workstation figures behind the shipped number (report 98 §48).
	assert_eq(CatchUpPlanner.derive_max_coarse_hours(5.488), 360,
			"starter city, 5.488 ms/hour -> ceil(364.4)=365 -> 360")
	assert_eq(CatchUpPlanner.derive_max_coarse_hours(165.493), 72,
			"bench city, 165.493 ms/hour -> ceil(12.09)=13 -> 0 -> the 72 floor")


func test_an_unmeasured_build_clamps_at_doc_01_s_cap() -> void:
	# A clamp derived from no measurement may not discard a player's time.
	assert_eq(CatchUpPlanner.derive_max_coarse_hours(0.0),
			CatchUpPlanner.MAX_COARSE_HOURS_CEIL)
	assert_eq(CatchUpPlanner.derive_max_coarse_hours(-1.0),
			CatchUpPlanner.MAX_COARSE_HOURS_CEIL)


func test_the_result_is_always_a_whole_game_day_inside_the_bounds() -> void:
	var measured := 0.5
	while measured <= 60.0:
		var hours := CatchUpPlanner.derive_max_coarse_hours(measured)
		assert_true(hours >= CatchUpPlanner.MAX_COARSE_HOURS_FLOOR
				and hours <= CatchUpPlanner.MAX_COARSE_HOURS_CEIL,
				"m=%.2f produced %d, outside [72, 720]" % [measured, hours])
		assert_eq(hours % 24, 0, "m=%.2f produced %d, not a whole game-day"
				% [measured, hours])
		measured += 0.25


# ===========================================================================
# 2. The file
# ===========================================================================

func test_the_shipped_number_is_the_one_the_measurement_derives() -> void:
	var block := _catchup_block()
	var measured := float(block.get("measured_coarse_ms", 0.0))
	assert_true(measured > 0.0, "data/persistence.json records the measurement")
	assert_eq(int(block.get("max_coarse_hours", -1)),
			CatchUpPlanner.derive_max_coarse_hours(measured),
			"the shipped clamp and the measurement beside it must not drift apart")


func test_the_bench_measurement_is_recorded_beside_it() -> void:
	# RR-133 rules which city the rule reads; the other one is kept on the
	# record so the disagreement stays visible rather than being forgotten.
	var block := _catchup_block()
	assert_true(float(block.get("bench_coarse_ms", 0.0)) > 0.0,
			"the 1,500-building figure is recorded even though it is not shipped")


func test_save_policy_is_the_only_reader_and_reads_it() -> void:
	var policy := SavePolicy.load_from_files()
	assert_true(policy.measured_coarse_ms > 0.0)
	assert_eq(policy.max_coarse_hours,
			CatchUpPlanner.derive_max_coarse_hours(policy.measured_coarse_ms))
	assert_eq(CatchUpPlanner.configured_max_coarse_hours(), policy.max_coarse_hours,
			"the planner uses the shipped number and derives nothing itself")


# ===========================================================================
# 3. The clamp in the plan
# ===========================================================================

func test_the_clamp_credits_min_of_elapsed_cap_and_max_coarse_hours() -> void:
	# 8 real hours away with a 360 game-hour clamp: 360 game-hours is 6 real
	# hours (1 real s = 1 game min), so 2 real hours are discarded.
	var plan := CatchUpPlanner.plan(8 * HOUR_MS, 0, 0, 360)
	assert_eq(int(plan["credited_real_ms"]), 6 * HOUR_MS)
	assert_eq(int(plan["cap_game_hours"]), 360)
	assert_eq(int(plan["discarded_real_ms"]), 2 * HOUR_MS)
	assert_true(bool(plan["capped"]))
	assert_eq(int(plan["total_ticks"]), 360 * GameClock.TICKS_PER_HOUR)
	assert_eq(CatchUpPlanner.segments_total_ticks(plan), int(plan["total_ticks"]))


func test_an_absence_inside_the_clamp_is_not_capped() -> void:
	var plan := CatchUpPlanner.plan(5 * HOUR_MS, 0, 0, 360)
	assert_false(bool(plan["capped"]))
	assert_eq(int(plan["credited_real_ms"]), 5 * HOUR_MS)
	assert_eq(int(plan["discarded_real_ms"]), 0)


func test_the_clamp_may_only_ever_tighten_doc_01_s_cap() -> void:
	# Doc 08 §2.12: "a performance clamp that may only ever be <= the doc-01
	# cap". Asking for more than 720 game-hours gets 720.
	var plan := CatchUpPlanner.plan(30 * HOUR_MS, 0, 0, 100_000)
	assert_eq(int(plan["credited_real_ms"]), CatchUpPlanner.OFFLINE_CAP_REAL_MS)
	assert_eq(int(plan["cap_game_hours"]), 720)


func test_the_clamp_can_never_go_under_the_72_hour_floor() -> void:
	var plan := CatchUpPlanner.plan(30 * HOUR_MS, 0, 0, 1)
	assert_eq(int(plan["cap_game_hours"]), 72)
	assert_eq(int(plan["total_ticks"]), 72 * GameClock.TICKS_PER_HOUR)


func test_the_shipped_clamp_is_what_an_unqualified_plan_gets() -> void:
	var shipped := CatchUpPlanner.configured_max_coarse_hours()
	var explicit := CatchUpPlanner.plan(30 * HOUR_MS, 0, 918_442, shipped)
	var implicit := CatchUpPlanner.plan(30 * HOUR_MS, 0, 918_442)
	assert_eq(int(implicit["total_ticks"]), int(explicit["total_ticks"]))
	assert_eq(int(implicit["cap_game_hours"]), shipped)


# ===========================================================================
# 3b. The copy
# ===========================================================================

func test_the_veil_names_the_cap_it_actually_applied() -> void:
	var model := VeilModel.new(UIConfig.load_from_files())
	# 360 game-hours is 6 REAL hours; the veil line quotes real hours, because
	# "the longest stretch this city simulates at once" is a wall-clock promise.
	model.begin_catchup(360, 86_400, true, 6)
	var detail := str(model.build_view()["detail"])
	assert_true(detail.contains("6 hours"),
			"the veil quoted '%s' — it must name the cap that was applied" % detail)
	model.begin_catchup(720, 172_800, true, 12)
	assert_true(str(model.build_view()["detail"]).contains("12 hours"),
			"and the C-19 cap still reads as 12 when that is what applied")


func test_an_uncapped_catchup_still_says_nothing() -> void:
	var model := VeilModel.new(UIConfig.load_from_files())
	model.begin_catchup(3, 720, false, 6)
	assert_eq(str(model.build_view()["detail"]), "")


func test_the_away_report_can_state_the_cap_in_game_hours() -> void:
	# `ui/away_model.gd` has carried a `capped_text` since S12 and `game/main.gd`
	# never passed it anything to say — the report dict had no `capped` key at
	# all, so the line was dead code. The shell snippet in report 98 §48 passes
	# `capped` and `cap_game_hours` straight out of the plan; this is the model
	# half of that, pinned so the copy cannot go quiet again.
	var model := AwayModel.new(UIConfig.load_from_files())
	var view := model.build({
		"elapsed_wall_s": 8.0 * 3600.0,
		"before": {"treasury": 1000, "population": 100, "day_index": 1,
				"stability": 0.5, "happiness": 0.5},
		"after": {"treasury": 1200, "population": 110, "day_index": 16,
				"stability": 0.5, "happiness": 0.5},
		"capped": true,
		"cap_game_hours": 360.0,
	})
	var header: Dictionary = view["header"]
	assert_true(bool(header["capped"]))
	assert_true(str(header["capped_text"]).contains("360"),
			"the away report quoted '%s'" % str(header["capped_text"]))
