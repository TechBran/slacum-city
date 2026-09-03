extends SimTest
## **The two clamps, separated** (doc 08 §2.12 re-ruled; report 98 §58,
## RR-160/RR-161). This file was `tests/test_catchup_clamp.gd` and it pinned the
## opposite rule.
##
## Wave 17 (RR-133) implemented doc 08 §2.12's performance budget as
## `max_coarse_hours` — a second clamp on the CREDITED ABSENCE, derived from a
## measured coarse-step cost. At 5.488 ms/hour it shipped as 360 game-hours, and
## 360 game-hours is **6 real hours**, so the seventh, eighth and ninth hour of a
## player's night credited nothing at all. Doc 92 §55 measures the bill: an
## eight-hour night on a settled L3 city paid **$281,319** where the uncapped
## absence pays **$354,830**, and a twelve-hour absence paid 57.5% of what those
## hours were worth.
##
## The arithmetic was right and the AXIS was wrong. A performance budget bounds
## how long the catch-up VEIL takes; it may never bound what the player is paid
## for being away. Four things are pinned here, and they are the four that can
## rot independently:
##
## 1. **The credited absence is doc 01's C-19 cap and nothing else** — including
##    the player's own case, an eight-hour night, in ticks.
## 2. **Nothing can tighten it.** `plan()` has no clamp argument any more, and a
##    source scan of `sim/` and `game/` proves the name is gone rather than
##    merely unused — the inverse of the grep that opened RR-133.
## 3. **The budget still exists, on its own axis**, as a measured wall clock
##    against a published allowance, read by this test and by nothing else.
## 4. **The copy.** A cap the player is never told about is a silent theft of
##    their time, and a cap the player is told about when none applied is a lie
##    in the other direction.

const HOUR_MS := 3_600_000
const CAP_MS := 43_200_000        # doc 01 C-19: 12 real hours
const TICKS_PER_HOUR := 240


func _catchup_block() -> Dictionary:
	var parsed: Variant = JSON.parse_string(
			FileAccess.get_file_as_string("res://data/persistence.json"))
	assert_true(parsed is Dictionary, "data/persistence.json parses")
	var data: Dictionary = parsed
	var block: Variant = data.get("catchup", {})
	assert_true(block is Dictionary, "data/persistence.json carries a catchup block")
	return block


# ===========================================================================
# 1. The credited absence is doc 01's cap, and the player's own case
# ===========================================================================

func test_the_eight_hour_night_that_started_this_wave() -> void:
	# The 2026-09-03 report: "I went to bed hoping I'd wake up to a bunch of
	# money." Eight real hours is 480 game-hours, and under Wave 18 it was
	# credited 360. This is the regression, in ticks.
	var plan := CatchUpPlanner.plan(8 * HOUR_MS, 0, 0)
	assert_eq(int(plan["credited_real_ms"]), 8 * HOUR_MS, "eight hours away, eight credited")
	assert_false(bool(plan["capped"]), "a night is not a capped absence")
	assert_eq(int(plan["discarded_real_ms"]), 0)
	assert_eq(int(plan["total_ticks"]), 480 * TICKS_PER_HOUR,
			"480 game-hours, not the 360 the Wave-18 clamp credited")
	assert_eq(CatchUpPlanner.segments_total_ticks(plan), int(plan["total_ticks"]))


func test_every_length_of_night_credits_in_full() -> void:
	# 6, 7, 8, 9, 10, 11 and 12 real hours must each credit themselves. Under
	# the deleted clamp every row from 7 upward returned the 6-hour answer,
	# which is exactly the "money stops" the player described.
	for hours in [6, 7, 8, 9, 10, 11, 12]:
		var plan := CatchUpPlanner.plan(hours * HOUR_MS, 0, 0)
		assert_eq(int(plan["credited_real_ms"]), hours * HOUR_MS,
				"%d real hours away credits %d" % [hours, hours])
		assert_false(bool(plan["capped"]), "%d h is inside doc 01's cap" % hours)


func test_the_cap_still_binds_past_twelve_real_hours() -> void:
	# C-19 is unchanged: past 12 real hours the surplus is discarded, never
	# banked, and the plan says so.
	var plan := CatchUpPlanner.plan(26 * HOUR_MS, 0, 0)
	assert_true(bool(plan["capped"]))
	assert_eq(int(plan["credited_real_ms"]), CAP_MS)
	assert_eq(int(plan["discarded_real_ms"]), 26 * HOUR_MS - CAP_MS)
	assert_eq(int(plan["total_ticks"]), 720 * TICKS_PER_HOUR)
	assert_eq(int(plan["cap_game_hours"]), 720)
	assert_eq(int(plan["cap_real_hours"]), 12)


func test_the_grace_window_is_untouched() -> void:
	# Doc 01's 2-minute grace is a FAIRNESS rule and was never in dispute.
	assert_eq(int(CatchUpPlanner.plan(90_000, 0, 1000)["total_ticks"]), 0)
	assert_eq(int(CatchUpPlanner.plan(130_000, 0, 1000)["total_ticks"]), 520)


# ===========================================================================
# 2. Nothing can tighten it
# ===========================================================================

func test_the_planner_carries_no_clamp_name_at_all() -> void:
	# RR-133 opened with "`grep -rn max_coarse_hours sim/ game/ data/` returned
	# nothing". This is that grep inverted, and it is the structural half of the
	# fix: a performance number that cannot be named inside `sim/` cannot reach
	# a player's wallet from there.
	for path in ["res://sim/time/catchup_planner.gd", "res://sim/persistence/save_policy.gd",
			"res://data/persistence.json"]:
		var text := FileAccess.get_file_as_string(path)
		assert_true(text != "", "%s is readable" % path)
		assert_false(text.contains("max_coarse_hours("),
				"%s still calls a clamp accessor" % path)
	var planner := FileAccess.get_file_as_string("res://sim/time/catchup_planner.gd")
	assert_false(planner.contains("configured_max_coarse_hours"),
			"the planner still reads a shipped clamp")
	assert_false(planner.contains("derive_max_coarse_hours"),
			"the planner still derives a clamp")


func test_the_cap_is_a_constant_and_not_a_file_read() -> void:
	# The window is a property of the design, not of the workstation the build
	# was packaged on: two phones must credit the same absence identically
	# (constitution §5), and a clamp that moved with a measurement could not.
	assert_eq(CatchUpPlanner.OFFLINE_CAP_REAL_MS, CAP_MS)
	assert_eq(CatchUpPlanner.OFFLINE_CAP_GAME_HOURS, 720)
	assert_eq(CatchUpPlanner.OFFLINE_CAP_REAL_HOURS, 12)
	assert_eq(int(CatchUpPlanner.plan(26 * HOUR_MS, 0, 0)["cap_real_ms"]),
			CatchUpPlanner.OFFLINE_CAP_REAL_MS)


func test_the_save_policy_no_longer_publishes_a_credit_clamp() -> void:
	var policy := SavePolicy.load_from_files()
	assert_false(policy.get_property_list().any(func(p: Dictionary) -> bool:
			return String(p.get("name", "")) == "max_coarse_hours"),
			"SavePolicy still exposes max_coarse_hours")


# ===========================================================================
# 3. The budget, on its own axis
# ===========================================================================

func test_the_shipped_veil_measurement_meets_the_shipped_budget() -> void:
	# THE GATE. Two wall-clock numbers, no arithmetic in between: the measured
	# cost of a whole 12-real-hour plan on the settled reference city against
	# what it is allowed to be (doc 92 §55.6).
	var block := _catchup_block()
	var measured := float(block.get("veil_ms_at_cap", 0.0))
	var budget := float(block.get("veil_budget_ms", 0.0))
	assert_true(measured > 0.0, "data/persistence.json records the veil measurement")
	assert_true(budget > 0.0, "data/persistence.json records the veil budget")
	assert_true(measured <= budget,
			"a 12-real-hour catch-up costs %.0f ms against a %.0f ms budget — the answer"
			% [measured, budget] + " is a cheaper coarse hour (doc 92 §55.7 AC-19-1),"
			+ " never a smaller credit")


func test_save_policy_reads_the_pair_and_nothing_derives_it() -> void:
	var block := _catchup_block()
	var policy := SavePolicy.load_from_files()
	assert_almost_eq(policy.veil_ms_at_cap, float(block["veil_ms_at_cap"]), 1e-6)
	assert_almost_eq(policy.veil_budget_ms, float(block["veil_budget_ms"]), 1e-6)
	assert_true(policy.measured_coarse_ms > 0.0, "the founding-city hour is still recorded")
	assert_true(policy.bench_coarse_ms > 0.0, "the 1,500-building hour is still recorded")


func test_the_budget_is_a_gate_and_has_no_runtime_reader() -> void:
	# `sim/persistence/save_policy.gd` parses the file; nothing else in `sim/`,
	# `ui/` or `game/` may name either field. This is what makes the budget
	# structurally incapable of reaching a credit — the lesson of RR-133.
	# A READ is a property access or a dictionary key; prose in a `##` comment is
	# not, and the planner's class doc names the budget on purpose.
	for dir_path in ["res://sim", "res://ui", "res://game"]:
		for path in _gd_files(dir_path):
			if path == "res://sim/persistence/save_policy.gd":
				continue
			var text := FileAccess.get_file_as_string(path)
			assert_false(text.contains(".veil_budget_ms") or text.contains("\"veil_budget_ms\""),
					"%s reads the veil budget — it is a gate, not a tunable" % path)
	# And the strongest form of the same property: the planner reads NO data
	# file at all any more. It used to call `SavePolicy.load_from_files()` to
	# fetch the clamp, and that call was the whole path by which a workstation
	# measurement reached a player's wallet (RR-133).
	var planner := FileAccess.get_file_as_string("res://sim/time/catchup_planner.gd")
	assert_false(planner.contains("SavePolicy"),
			"the planner reads a policy file again — the credited window is a"
			+ " constant of the design, not of the machine that packaged the build")


func test_the_estimator_is_a_pure_function_of_the_measurement() -> void:
	assert_almost_eq(CatchUpPlanner.veil_ms_at_cap(5.488), 3951.36, 0.01,
			"the founding city's hour at the full cap")
	assert_almost_eq(CatchUpPlanner.veil_ms_at_cap(165.493), 119154.96, 0.01,
			"the benchmark city's hour at the full cap — AC-19-1")
	assert_almost_eq(CatchUpPlanner.veil_ms_at_cap(0.0), 0.0)
	assert_almost_eq(CatchUpPlanner.veil_ms_at_cap(-3.0), 0.0, 1e-9,
			"an unmeasured city estimates nothing rather than a negative veil")
	assert_true(CatchUpPlanner.meets_veil_budget(5.488, 9000.0))
	assert_false(CatchUpPlanner.meets_veil_budget(165.493, 9000.0))


func test_the_founding_city_hour_is_still_in_the_league_it_was_measured_in() -> void:
	# A LIVE measurement, printed rather than gated. A wall-clock assertion in a
	# suite that runs beside a fleet of sibling suites is a flake, not a gate
	# (`tests/test_milestone1.gd` makes the same argument); the shipped gate is
	# the recorded pair above. The loose bound still catches an order-of-
	# magnitude regression in the coarse step.
	var sim := CitySim.boot_from_files()
	sim.advance_coarse_hours(2)          # warm caches outside the timed window
	var t0 := Time.get_ticks_usec()
	sim.advance_coarse_hours(24)
	var per_hour := float(Time.get_ticks_usec() - t0) / 1000.0 / 24.0
	print("  [veil] founding-city coarse hour %.3f ms -> %.0f ms at the 12 h cap"
			% [per_hour, CatchUpPlanner.veil_ms_at_cap(per_hour)])
	assert_true(per_hour < 50.0,
			"founding-city coarse hour %.2f ms is an order of magnitude off" % per_hour)
	sim.dispose()


# ===========================================================================
# 4. The copy
# ===========================================================================

func test_the_veil_names_the_cap_in_real_hours() -> void:
	var model := VeilModel.new(UIConfig.load_from_files())
	model.begin_catchup(720, 172_800, true, CatchUpPlanner.OFFLINE_CAP_REAL_HOURS)
	var detail := str(model.build_view()["detail"])
	assert_true(detail.contains("12 hours"),
			"the veil quoted '%s' — it must name the cap that was applied" % detail)


func test_an_uncapped_catchup_still_says_nothing() -> void:
	var model := VeilModel.new(UIConfig.load_from_files())
	model.begin_catchup(3, 720, false, 12)
	assert_eq(str(model.build_view()["detail"]), "")


func test_the_away_report_states_the_cap_in_the_unit_the_player_was_away_in() -> void:
	# RR-162. The line used to quote `cap_game_hours` — "Your city ran for 720h"
	# — which is city time in a sentence about the player's night. It quotes
	# REAL hours now, and it is the plan's own `cap_real_hours` that fills it.
	var model := AwayModel.new(UIConfig.load_from_files())
	var view := model.build({
		"elapsed_wall_s": 26.0 * 3600.0,
		"elapsed_game_minutes": float(CatchUpPlanner.OFFLINE_CAP_REAL_MS) / 1000.0,
		"before": {"treasury": 1000, "population": 100, "day_index": 1},
		"after": {"treasury": 1200, "population": 110, "day_index": 31},
		"capped": true,
		"cap_real_hours": 12.0,
	})
	var header: Dictionary = view["header"]
	assert_true(bool(header["capped"]))
	var text := str(header["capped_text"])
	assert_true(text.contains("12"), "the away report quoted '%s'" % text)
	assert_false(text.contains("720"),
			"the away report quoted city time at a player who slept: '%s'" % text)


func test_an_uncapped_away_report_does_not_imply_a_cap() -> void:
	# The other direction, and it is the one D-77 never tested: an eight-hour
	# night is NOT capped any more, so the line must be empty.
	var plan := CatchUpPlanner.plan(8 * HOUR_MS, 0, 0)
	var model := AwayModel.new(UIConfig.load_from_files())
	var view := model.build({
		"elapsed_wall_s": 8.0 * 3600.0,
		"elapsed_game_minutes": float(plan["credited_real_ms"]) / 1000.0,
		"before": {"treasury": 1000, "population": 100, "day_index": 1},
		"after": {"treasury": 90000, "population": 140, "day_index": 21},
		"capped": bool(plan["capped"]),
		"cap_real_hours": float(plan["cap_real_hours"]),
	})
	var header: Dictionary = view["header"]
	assert_false(bool(header["capped"]))
	assert_eq(str(header["capped_text"]), "")


func test_the_header_counts_the_city_time_that_actually_ran() -> void:
	# The credited minutes, not the wall clock. A 26-hour absence credits 12
	# real hours = 720 game-hours = 30 game-days, and a header that reported 26
	# hours of city time would be claiming 65 days the city never lived.
	var plan := CatchUpPlanner.plan(26 * HOUR_MS, 0, 0)
	var model := AwayModel.new(UIConfig.load_from_files())
	var view := model.build({
		"elapsed_wall_s": 26.0 * 3600.0,
		"elapsed_game_minutes": float(plan["credited_real_ms"]) / 1000.0,
		"before": {"treasury": 1000, "population": 100, "day_index": 1},
		"after": {"treasury": 1200, "population": 110, "day_index": 31},
		"capped": true,
		"cap_real_hours": float(plan["cap_real_hours"]),
	})
	var header: Dictionary = view["header"]
	assert_almost_eq(float(header["elapsed_game_minutes"]), 43_200.0, 0.5,
			"720 game-hours of city time, which is what the sim actually ran")
	assert_almost_eq(float(header["game_days"]), 30.0, 0.01)


func _gd_files(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := "%s/%s" % [dir_path, entry]
		if dir.current_is_dir():
			out.append_array(_gd_files(full))
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out
