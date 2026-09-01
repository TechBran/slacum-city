extends SimTest
## Doc 12 P1-32: `HudModel`, the headless half of the HUD. Covers the doc's §7
## rows that this task owns — test 10 (`test_topbar_collapse`), test 14
## (`test_number_format`), test 17 (`test_in_app_alert_gate`) and test 18
## (`test_marker_projection`) — plus the §2.4 chip thresholds and the §2.11 /
## A10 speed-rail state machine. Every expectation traces to a doc line or to
## `data/ui.json`; nothing here asserts a number this repo invented.


func _model() -> HudModel:
	return HudModel.load_from_files()


# ===========================================================================
# NumberFormat — doc 12 §2.4 and test 14
# ===========================================================================

func test_number_format_money_doc_cases() -> void:
	# The four literal expectations of doc 12 test 14.
	assert_eq(HudModel.money(8420), "$8,420")
	assert_eq(HudModel.money(842000), "$842K")
	assert_eq(HudModel.money(8420000), "$8.42M")
	assert_eq(HudModel.money(-1200000), "−$1.2M", "U+2212 minus, not a hyphen")


func test_number_format_money_ladder_boundaries() -> void:
	# `$8,420` below 10K · `$842K` below 10⁶ · `$8.42M` below 10⁹ · else `$8.42B`.
	assert_eq(HudModel.money(0), "$0")
	assert_eq(HudModel.money(999), "$999")
	assert_eq(HudModel.money(9999), "$9,999", "last grouped value")
	assert_eq(HudModel.money(10000), "$10K", "first compacted value")
	assert_eq(HudModel.money(12345), "$12.3K", "3 significant digits above 10K")
	assert_eq(HudModel.money(999999), "$1M", "rounding carries into the next unit")
	assert_eq(HudModel.money(1000000), "$1M")
	assert_eq(HudModel.money(84200000), "$84.2M")
	assert_eq(HudModel.money(842000000), "$842M")
	assert_eq(HudModel.money(1000000000), "$1B", "10⁹ crosses into B")
	assert_eq(HudModel.money(8420000000), "$8.42B")


func test_number_format_money_negatives_and_int64_edges() -> void:
	assert_eq(HudModel.money(-1), "−$1")
	assert_eq(HudModel.money(-8420), "−$8,420")
	assert_eq(HudModel.money(-842000), "−$842K")
	# int64 max/min: the ladder is chosen from the digit count and the rounding is
	# string arithmetic, so neither overflows nor loses low digits to a float.
	var int64_max := 9223372036854775807
	var int64_min := -9223372036854775807 - 1
	assert_eq(HudModel.money(int64_max), "$9223372037B")
	assert_eq(HudModel.money(int64_min), "−$9223372037B")
	assert_eq(HudModel.pop(int64_max), "9,223,372,036,854,775,807",
			"grouping never round-trips through a float")


func test_number_format_rate_per_day() -> void:
	# `rate(per_game_hour)` displays per day as value*24 with +/− and `/d`.
	assert_eq(HudModel.rate_per_day(5750.0), "+$138K/d", "doc 12 test 14")
	assert_eq(HudModel.rate_per_day(0.0), "+$0/d")
	assert_eq(HudModel.rate_per_day(-100.0), "−$2,400/d")
	assert_eq(HudModel.rate_per_day(-5750.0), "−$138K/d")
	assert_eq(HudModel.rate_per_day_compact(5750.0), "+$138K",
			"the 64 dp compact chip drops the /d suffix")


func test_number_format_eta_and_pop_and_clock() -> void:
	assert_eq(HudModel.eta(48), "0:48", "doc 12 test 14")
	assert_eq(HudModel.eta(3720), "1:02", "doc 12 test 14")
	assert_eq(HudModel.eta(0), "0:00")
	assert_eq(HudModel.eta(59), "0:59")
	assert_eq(HudModel.eta(3599), "59:59", "m:ss right up to the hour")
	assert_eq(HudModel.eta(3600), "1:00", "h:mm from one hour")
	assert_eq(HudModel.pop(184291), "184,291", "§2.4 pop() is comma-grouped")
	assert_eq(HudModel.pop(999), "999")
	assert_eq(HudModel.pop(1000), "1,000")
	assert_eq(HudModel.pop(-1500), "−1,500")
	assert_eq(HudModel.clock_hhmm(372), "06:12", "the §2.3 mock's clock face")
	assert_eq(HudModel.clock_hhmm(0), "00:00")
	assert_eq(HudModel.clock_hhmm(1439), "23:59")
	assert_eq(HudModel.clock_hhmm(1440), "00:00", "minute_of_day wraps")


# ===========================================================================
# TopBarLayoutSolver — doc 12 §2.4 worked example, test 10
# ===========================================================================

func test_topbar_collapse_worked_example_640() -> void:
	# §2.4: "W = 640 (COMPACT), clock_w = 100 → avail = 524. FULL widths P1..P7 =
	# 640 + gaps 36 = 676 > 524. Demote P7→64 (628), P6→64 (596), P5→64 (556),
	# P4→56 (532), P3→56 (508 ≤ 524 ✓). All seven chips visible, P3–P7 compact."
	var model := _model()
	var solved := model.solve_top_bar(640.0, 100.0)
	assert_almost_eq(float(solved["avail"]), 524.0, 0.001)
	assert_almost_eq(float(solved["need"]), 508.0, 0.001)
	assert_eq((solved["visible"] as Array).size(), 7, "nothing is hidden at 640 dp")
	var modes: Dictionary = solved["modes"]
	assert_eq(modes["treasury"], HudModel.MODE_FULL, "P1 keeps its full width")
	assert_eq(modes["incidents"], HudModel.MODE_FULL, "P2 keeps its full width")
	for chip_id: String in ["grid", "water", "population", "net_income", "stability"]:
		assert_eq(modes[chip_id], HudModel.MODE_COMPACT, "P3–P7 demote to compact")
	assert_eq(int(solved["iterations"]), 5, "five demotions, deterministic")


func test_topbar_full_widths_sum_matches_the_doc() -> void:
	# The solver's inputs are data/ui.json's, so the doc's 640 + 36 must hold.
	var model := _model()
	var full := 0.0
	for chip_id: String in model.chip_order():
		full += model.chip_width_dp(chip_id, HudModel.MODE_FULL)
	assert_almost_eq(full, 640.0, 0.001, "104+64+80+80+104+96+112")
	var solved := model.solve_top_bar(2000.0, 100.0)
	assert_almost_eq(float(solved["need"]), 676.0, 0.001, "640 + 6 gaps of 6 dp")


func test_topbar_no_collapse_at_reference_width() -> void:
	# doc 12 test 10: "W=880 keeps all chips FULL". clock_w defaults to
	# data/ui.json's 132 dp, so avail = 880 − 132 − 16 = 732 ≥ 676.
	var model := _model()
	var solved := model.solve_top_bar(880.0)
	assert_almost_eq(float(solved["avail"]), 732.0, 0.001)
	assert_eq(int(solved["iterations"]), 0, "the reference layout never collapses")
	for chip_id: String in model.chip_order():
		assert_eq((solved["modes"] as Dictionary)[chip_id], HudModel.MODE_FULL)
	# WIDE (≥ 900) never collapses either.
	assert_eq(int(model.solve_top_bar(900.0)["iterations"]), 0)


func test_topbar_p1_to_p4_are_never_hidden() -> void:
	# doc 12 test 10: "P1–P4 never HIDDEN at any width ≥ 480; deterministic,
	# ≤ 14 iterations." Asserted from 480 dp up, which is the width the doc states
	# it for; below that see the test underneath.
	var model := _model()
	var never_hidden := ["treasury", "incidents", "grid", "water"]
	var width := 480.0
	while width <= 1200.0:
		var solved := model.solve_top_bar(width)
		var modes: Dictionary = solved["modes"]
		for chip_id: String in never_hidden:
			assert_ne(modes[chip_id], HudModel.MODE_HIDDEN,
					"%s survives at W=%d" % [chip_id, int(width)])
		assert_true(int(solved["iterations"]) <= 14,
				"≤ 14 iterations at W=%d" % int(width))
		width += 10.0


func test_below_480_the_bar_hides_rather_than_overflowing() -> void:
	# Doc 12 delta D-19 (Wave-4 UX sweep). §2.4's never-hidden floor holds at
	# every width the doc states it for, but a 200 dp budget cannot carry four
	# chips plus the clock column at any text scale — and the old `break` left the
	# solver reporting a bar wider than the display, which `grow_horizontal =
	# BOTH` then centred, pushing the treasury chip off the left edge and the ☰
	# button off the right. A1 (nothing clips) and A3 (every target is reachable)
	# win: chips keep dropping, lowest priority first, down to the treasury.
	#
	# EXTENDED by the render follow-ups wave (doc 12 D-13b): "down to the
	# treasury" was one rung short of solving it. `need <= avail_rest` — which is
	# what this test used to check — compares the widest row against the WHOLE
	# bar, and row 0 does not get the whole bar: it shares its line with the clock
	# column. Below ~212 dp the treasury chip alone is wider than row 0's budget,
	# so the old solver kept it, reported a bar that "fits", and overflowed the
	# display by 20 dp anyway. Every row is now checked against ITS OWN line, and
	# the treasury chip is asserted to survive exactly where there is room for it.
	var model := _model()
	var compact_w := model.chip_width_dp("treasury", HudModel.MODE_COMPACT)
	var kept := 0
	var dropped := 0
	var width := 200.0
	while width < 480.0:
		var solved := model.solve_top_bar(width, -1.0, {}, 2)
		var widths: Array = solved["row_widths"]
		for i in widths.size():
			var limit := float(solved["avail"]) if i == 0 else float(solved["avail_rest"])
			assert_true(float(widths[i]) <= limit + 0.001,
					"row %d fits its own line at W=%d (%.1f of %.1f)"
					% [i, int(width), float(widths[i]), limit])
		var hidden: bool = (solved["modes"] as Dictionary)["treasury"] == HudModel.MODE_HIDDEN
		if float(solved["avail"]) >= compact_w:
			assert_false(hidden,
					"the treasury chip is the last one standing at W=%d" % int(width))
			kept += 1
		else:
			dropped += 1
		width += 10.0
	assert_true(kept > 20, "most of the band still keeps the treasury chip (%d)" % kept)
	assert_true(dropped > 0,
			"…and the band that cannot hold it at all is covered too (%d)" % dropped)


func test_topbar_hides_lowest_priority_first() -> void:
	# At 480 dp every chip is already compact (460 dp) and still overflows the
	# 332 dp budget, so P7 then P6 drop — lowest priority first, never P1–P4.
	var model := _model()
	var solved := model.solve_top_bar(480.0)
	var modes: Dictionary = solved["modes"]
	assert_almost_eq(float(solved["avail"]), 332.0, 0.001)
	assert_eq(modes["stability"], HudModel.MODE_HIDDEN, "P7 goes first")
	assert_eq(modes["net_income"], HudModel.MODE_HIDDEN, "P6 goes second")
	assert_eq(modes["population"], HudModel.MODE_COMPACT, "P5 survives at 480 dp")
	assert_eq((solved["visible"] as Array).size(), 5)
	assert_true(float(solved["need"]) <= float(solved["avail"]), "it actually fits")


func test_topbar_is_deterministic() -> void:
	var model := _model()
	for width: float in [321.0, 640.0, 700.0, 880.0]:
		var a := model.solve_top_bar(width)
		var b := model.solve_top_bar(width)
		assert_eq(str(a["modes"]), str(b["modes"]), "same width, same solution")


# ===========================================================================
# Chip values and states — doc 12 §2.4 thresholds
# ===========================================================================

func test_treasury_and_net_income_states() -> void:
	var model := _model()
	# P1: `< 0` → CRITICAL; projected-insolvent-in-24 h → WARNING.
	assert_eq(model.treasury_state(-1, 0.0), HudModel.STATE_CRITICAL)
	assert_eq(model.treasury_state(1000, -100.0), HudModel.STATE_WARNING,
			"1000 − 2400/day is insolvent inside 24 h")
	assert_eq(model.treasury_state(1000000, -100.0), HudModel.STATE_NORMAL)
	# P6: `<0` → WARNING, `<−5%` treasury/day → CRITICAL.
	assert_eq(model.net_income_state(100.0, 1000000), HudModel.STATE_NORMAL)
	assert_eq(model.net_income_state(-100.0, 1000000), HudModel.STATE_WARNING,
			"−2,400/day is 0.24% of a $1M treasury")
	assert_eq(model.net_income_state(-5000.0, 1000000), HudModel.STATE_CRITICAL,
			"−120K/day is over 5% of a $1M treasury")


func test_grid_and_water_health_bands() -> void:
	# ≥95 NORMAL, 85–94 WARNING, 60–84 CRITICAL, <60 CRITICAL+pulse.
	var model := _model()
	for prefix: String in ["grid", "water"]:
		assert_eq(model.health_state(100.0, prefix), HudModel.STATE_NORMAL)
		assert_eq(model.health_state(95.0, prefix), HudModel.STATE_NORMAL)
		assert_eq(model.health_state(94.0, prefix), HudModel.STATE_WARNING)
		assert_eq(model.health_state(85.0, prefix), HudModel.STATE_WARNING)
		assert_eq(model.health_state(84.0, prefix), HudModel.STATE_CRITICAL)
		assert_eq(model.health_state(60.0, prefix), HudModel.STATE_CRITICAL)
		assert_eq(model.health_state(59.0, prefix), HudModel.STATE_CRITICAL)
		assert_false(model.health_pulses(60.0, prefix), "60% is critical, not pulsing")
		assert_true(model.health_pulses(59.0, prefix), "<60 pulses")
		# No reading yet is the fourth state, not a fake 100%.
		assert_eq(model.health_state(-1.0, prefix), HudModel.STATE_OFFLINE)
		assert_false(model.health_pulses(-1.0, prefix))


func test_stability_conversion_and_bands() -> void:
	# doc 09 publishes [0,1]; §2.4: "the conversion happens once, in the chip".
	var model := _model()
	assert_eq(model.stability_percent(0.684), 68)
	assert_eq(model.stability_percent(1.0), 100)
	assert_eq(model.stability_percent(-3.0), 0, "clamped to the published range")
	assert_eq(model.stability_band(0.75), HudModel.STABILITY_HIGH)
	assert_eq(model.stability_band(0.74), HudModel.STABILITY_MODERATE)
	assert_eq(model.stability_band(0.50), HudModel.STABILITY_MODERATE)
	assert_eq(model.stability_band(0.49), HudModel.STABILITY_LOW)
	assert_eq(model.stability_band(0.25), HudModel.STABILITY_LOW)
	assert_eq(model.stability_band(0.24), HudModel.STABILITY_CRITICAL)
	assert_eq(model.stability_state(0.80), HudModel.STATE_NORMAL)
	assert_eq(model.stability_state(0.60), HudModel.STATE_WARNING)
	assert_eq(model.stability_state(0.10), HudModel.STATE_CRITICAL)


func test_population_and_incident_states() -> void:
	var model := _model()
	assert_eq(model.population_state(-0.4), HudModel.STATE_NORMAL)
	assert_eq(model.population_state(-0.6), HudModel.STATE_WARNING,
			"Δ < −0.5%/day → WARNING")
	# doc 06: tier = clamp(floor(severity), 1, 5); the chip badge is max(tier).
	assert_eq(HudModel.incident_tier(0.4), 1)
	assert_eq(HudModel.incident_tier(3.9), 3)
	assert_eq(HudModel.incident_tier(5.4), 5)
	assert_eq(HudModel.worst_tier([1.2, 4.7, 2.0]), 4)
	assert_eq(HudModel.worst_tier([]), 0)
	assert_eq(model.incidents_state(0, 0), HudModel.STATE_NORMAL)
	assert_eq(model.incidents_state(3, 2), HudModel.STATE_NORMAL)
	assert_eq(model.incidents_state(3, 3), HudModel.STATE_WARNING)
	assert_eq(model.incidents_state(3, 5), HudModel.STATE_CRITICAL)


func test_state_glyphs_come_from_the_data_file() -> void:
	# A5: colour is never load-bearing, so every non-normal state has a glyph.
	var model := _model()
	assert_eq(model.state_glyph(HudModel.STATE_NORMAL), "●")
	assert_eq(model.state_glyph(HudModel.STATE_WARNING), "▲")
	assert_eq(model.state_glyph(HudModel.STATE_CRITICAL), "◆")
	assert_eq(model.state_glyph(HudModel.STATE_OFFLINE), "✕")


func test_build_view_reproduces_the_mock_top_bar() -> void:
	# §2.3's mock: [$8.42M][⚠7][⚡91%][💧97%][👥184,291][+$138K/d][Stab: Mod] ⛈ 06:12
	var model := _model()
	var view := model.build_view({
		"treasury": 8420000,
		"net_per_hour": 5750.0,
		"population": 184291,
		"stability": 0.68,
		"grid_pct": 91.0,
		"water_pct": 97.0,
		"incidents": {"count": 7, "worst_tier": 4},
		"clock": {"minute_of_day": 372, "day_index": 2},
		"speed": 1,
		"paused": false,
	}, 880.0)
	var by_id: Dictionary = {}
	for chip: Variant in (view["chips"] as Array):
		by_id[str((chip as Dictionary)["id"])] = chip
	assert_eq(str((by_id["treasury"] as Dictionary)["text"]), "$8.42M")
	assert_eq(str((by_id["incidents"] as Dictionary)["text"]), "7")
	assert_eq(int((by_id["incidents"] as Dictionary)["badge_tier"]), 4)
	assert_eq(str((by_id["grid"] as Dictionary)["text"]), "91%")
	assert_eq(str((by_id["water"] as Dictionary)["text"]), "97%")
	assert_eq(str((by_id["population"] as Dictionary)["text"]), "184,291")
	assert_eq(str((by_id["net_income"] as Dictionary)["text"]), "+$138K/d")
	assert_eq(str((by_id["stability"] as Dictionary)["text"]), "Moderate 68")
	assert_eq(str((by_id["stability"] as Dictionary)["label_key"]),
			"ui_hud_stability_moderate", "copy resolves from the string table")
	assert_eq(str((view["clock"] as Dictionary)["time"]), "06:12")
	assert_eq(str((view["clock"] as Dictionary)["day"]), "Day 3")
	# The grid chip is WARNING at 91%, so it carries the ▲ glyph as well.
	assert_eq((by_id["grid"] as Dictionary)["state"], HudModel.STATE_WARNING)
	assert_eq(str((by_id["grid"] as Dictionary)["state_glyph"]), "▲")


func test_build_view_compact_texts_and_missing_readings() -> void:
	var model := _model()
	var view := model.build_view({
		"treasury": 8420000, "net_per_hour": 5750.0, "population": 184291,
		"stability": 0.68, "incidents": 0, "clock": 372,
	}, 640.0, 100.0)
	var by_id: Dictionary = {}
	for chip: Variant in (view["chips"] as Array):
		by_id[str((chip as Dictionary)["id"])] = chip
	# The 640 dp solution demotes P3–P7, so those chips render their compact text.
	assert_eq(str((by_id["population"] as Dictionary)["text"]), "184K",
			"a 64 dp population chip compacts the number")
	assert_eq(str((by_id["net_income"] as Dictionary)["text"]), "+$138K")
	assert_eq(str((by_id["stability"] as Dictionary)["text"]), "68")
	assert_eq(str((by_id["treasury"] as Dictionary)["text"]), "$8.42M",
			"P1 is still FULL at 640 dp")
	# docs 04/05 publish no city-wide health yet: "—" and OFFLINE, never a fake.
	assert_eq(str((by_id["grid"] as Dictionary)["text"]), HudModel.NO_DATA)
	assert_eq((by_id["water"] as Dictionary)["state"], HudModel.STATE_OFFLINE)


# ===========================================================================
# InAppAlertGate — doc 12 §2.13, test 17
# ===========================================================================

func _alert(class_id: String, event_type: String, title: String = "t") -> Dictionary:
	return {"class": class_id, "event_type": event_type, "title": title}


func test_in_app_gate_five_p2_in_one_hour() -> void:
	# doc 12 test 17: "5 P2 in one real hour → 3 banners delivered, 2 degraded to
	# toasts, bucket refills after an hour."
	var model := _model()
	var delivered := 0
	var toasts := 0
	for i in 5:
		var verdict := model.submit_alert(float(i), _alert("p2", "type_%d" % i))
		if bool(verdict["delivered"]):
			delivered += 1
			assert_eq(verdict["surface"], HudModel.SURFACE_BANNER)
		else:
			toasts += 1
			assert_eq(verdict["surface"], HudModel.SURFACE_TOAST, "degrade, never silence")
			assert_eq(verdict["reason"], HudModel.REASON_BUCKET_EMPTY)
	assert_eq(delivered, 3, "bucket_capacity 3 for P2")
	assert_eq(toasts, 2)
	# An hour later the bucket has refilled at 3 per real hour.
	var after := model.submit_alert(3600.0, _alert("p2", "type_refill"))
	assert_true(bool(after["delivered"]), "the bucket refills after an hour")


func test_in_app_gate_shared_global_cap_over_p2_and_p3() -> void:
	# doc 12 test 17: "4 mixed P2+P3 in one hour → 3 delivered on the shared
	# global_max_per_hour."
	var model := _model()
	var verdicts := [
		model.submit_alert(0.0, _alert("p2", "a")),
		model.submit_alert(1.0, _alert("p3", "b")),
		model.submit_alert(2.0, _alert("p2", "c")),
		model.submit_alert(3.0, _alert("p2", "d")),
	]
	var delivered := 0
	for verdict: Variant in verdicts:
		if bool((verdict as Dictionary)["delivered"]):
			delivered += 1
	assert_eq(delivered, 3, "global_max_per_hour = 3 over P2+P3 combined")
	assert_eq((verdicts[3] as Dictionary)["reason"], HudModel.REASON_GLOBAL_CAP,
			"the P2 bucket still had a token; the shared cap refused it")
	assert_eq((verdicts[3] as Dictionary)["surface"], HudModel.SURFACE_TOAST)


func test_in_app_gate_p1_is_never_dropped_and_coalesces() -> void:
	# doc 12 test 17: "7 P1 in one hour → all 7 shown (P1 is never_drop and exempt
	# from the global cap), with any pair inside 300 s coalescing into one updated
	# banner."
	var model := _model()
	for i in 7:
		var verdict := model.submit_alert(float(i) * 10.0,
				_alert("p1", "p1_type_%d" % i, "critical %d" % i))
		assert_true(bool(verdict["delivered"]), "P1 #%d is never dropped" % i)
		assert_eq(verdict["surface"], HudModel.SURFACE_BANNER)
		assert_eq(bool(verdict["coalesced"]), i > 0,
				"every P1 after the first is inside the 300 s window")
	var live := model.active_alerts(70.0)
	assert_eq(live.size(), 1, "seven P1s coalesce into one banner")
	assert_eq(int((live[0] as Dictionary)["count"]), 7)
	assert_eq(str((live[0] as Dictionary)["title"]), "critical 6",
			"the banner is replaced in place with an updated title")
	assert_almost_eq(model.alert_tokens("p1"), 0.0, 0.02,
			"the bucket empties but never blocks a P1")
	# Outside the 300 s window a P1 raises its own banner instead of coalescing.
	var later := model.submit_alert(400.0, _alert("p1", "p1_late", "late"))
	assert_false(bool(later["coalesced"]))
	assert_eq(model.active_alerts(400.0).size(), 2, "alert_max_stack = 2")


func test_in_app_gate_per_type_cooldown() -> void:
	# 600 s per-event-type cooldown (data/ui.json in_app_alerts).
	var model := _model()
	assert_true(bool(model.submit_alert(0.0, _alert("p2", "outage_major"))["delivered"]))
	var soon := model.submit_alert(100.0, _alert("p2", "outage_major"))
	assert_false(bool(soon["delivered"]), "same type inside 600 s")
	assert_eq(soon["reason"], HudModel.REASON_TYPE_COOLDOWN)
	assert_eq(soon["surface"], HudModel.SURFACE_TOAST)
	var late := model.submit_alert(601.0, _alert("p2", "outage_major"))
	assert_true(bool(late["delivered"]), "the cooldown expires at 600 s")


func test_in_app_gate_expiry_stack_and_stickiness() -> void:
	# §2.15: banners are 6 s auto-dismiss, max 2 stacked; P1 is sticky until
	# tapped; toasts are 2.5 s and max 1 (newest replaces).
	var model := _model()
	model.submit_alert(0.0, _alert("p2", "a", "first"))
	assert_eq(model.active_alerts(5.9).size(), 1, "still inside alert_ttl_s")
	assert_eq(model.active_alerts(6.0).size(), 0, "auto-dismissed at 6 s")
	model.submit_alert(10.0, _alert("p1", "b", "sticky"))
	assert_eq(model.active_alerts(1000.0).size(), 1, "P1 is sticky until tapped")
	assert_true(model.dismiss_alert(str((model.active_alerts(1000.0)[0])["id"])))
	assert_eq(model.active_alerts(1000.0).size(), 0)
	# Three banners inside the window keep only the newest two.
	var fresh := _model()
	fresh.submit_alert(0.0, _alert("p2", "x"))
	fresh.submit_alert(1.0, _alert("p2", "y"))
	fresh.submit_alert(2.0, _alert("p2", "z"))
	assert_eq(fresh.active_alerts(3.0).size(), 2, "alert_max_stack = 2")
	assert_eq(str((fresh.active_alerts(3.0)[1] as Dictionary)["event_type"]), "z")
	# Toast: newest replaces, gone after toast_ttl_s.
	fresh.submit_alert(4.0, _alert("p2", "over_budget", "toasted"))
	assert_eq(str(fresh.active_toast(4.0)["title"]), "toasted")
	assert_true(fresh.active_toast(7.0).is_empty(), "toast_ttl_s = 2.5 s")


func test_in_app_gate_never_touches_push_policy() -> void:
	# C-71/C-72: the gate reads `in_app_alerts` only. It emits no push, never
	# consults quiet hours, and doc 08 owns the class map it defers to.
	var model := _model()
	assert_false(model.may_emit_push(), "an in-app banner is never a push")
	assert_false(model.consults_quiet_hours(),
			"quiet hours are a push concern; the player is looking at the app")
	assert_true(model.alert_class("p1").get("never_drop", false))
	assert_true(model.alert_class("p1").get("exempt_from_global", false))
	assert_false(model.alert_class("p2").get("exempt_from_global", true))
	assert_true(model.alert_class("p4").is_empty(),
			"P4 ships disabled and is doc 08's, not this gate's")


func test_in_app_gate_banner_setting_degrades_everything_to_toast() -> void:
	# §3.2 `settings.in_app_banners` — the one notification control this doc owns.
	var model := _model()
	model.banners_enabled = false
	var verdict := model.submit_alert(0.0, _alert("p1", "a"))
	assert_false(bool(verdict["delivered"]))
	assert_eq(verdict["reason"], HudModel.REASON_DISABLED)
	assert_eq(verdict["surface"], HudModel.SURFACE_TOAST,
			"a never_drop P1 is still surfaced, just not as a banner")
	assert_eq(model.active_alerts(0.0).size(), 0)


# ===========================================================================
# MarkerProjector — doc 12 §2.15, test 18
# ===========================================================================

func _marker(id: String, x: float, y: float, tier: int) -> Dictionary:
	return {"id": id, "position": Vector2(x, y), "tier": tier}


## `Rect2.has_point` excludes the far edges, and a clamped pin lands exactly on
## one of them by construction.
func _inside(point: Vector2, rect: Rect2) -> bool:
	return point.x >= rect.position.x - 0.001 and point.x <= rect.end.x + 0.001 \
			and point.y >= rect.position.y - 0.001 and point.y <= rect.end.y + 0.001


func test_marker_rect_insets_and_drawer() -> void:
	# doc 12 test 18: "the rect shrinks by drawer_w when the drawer is open".
	var model := _model()
	var closed := model.marker_rect(Vector2(880.0, 400.0), 299.0, false)
	assert_almost_eq(closed.position.x, 12.0, 0.001)
	assert_almost_eq(closed.position.y, 60.0, 0.001)
	assert_almost_eq(closed.size.x, 856.0, 0.001, "880 − 12 − 12")
	assert_almost_eq(closed.size.y, 270.0, 0.001, "400 − 60 − 70")
	var open_rect := model.marker_rect(Vector2(880.0, 400.0), 299.0, true)
	assert_almost_eq(open_rect.size.x, 557.0, 0.001, "856 − 299")
	assert_almost_eq(open_rect.size.y, closed.size.y, 0.001, "only the width moves")


func test_marker_clamping_off_screen() -> void:
	var model := _model()
	var rect := model.marker_rect(Vector2(880.0, 400.0))
	var inside := model.clamp_marker(Vector2(400.0, 200.0), rect)
	assert_false(bool(inside["offscreen"]))
	assert_eq(inside["position"], Vector2(400.0, 200.0), "an on-screen pin never moves")
	var above_left := model.clamp_marker(Vector2(-500.0, -900.0), rect)
	assert_true(bool(above_left["offscreen"]))
	assert_eq(above_left["position"], Vector2(12.0, 60.0), "clamped to the rect corner")
	var below_right := model.clamp_marker(Vector2(5000.0, 5000.0), rect)
	assert_true(bool(below_right["offscreen"]))
	assert_eq(below_right["position"], Vector2(868.0, 330.0))
	assert_true(_inside(below_right["position"] as Vector2, rect),
			"clamped inside the marker rect")
	assert_true((above_left["direction"] as Vector2).x < 0.0, "arrow points off-screen")


func test_marker_clustering_radius() -> void:
	# doc 12 test 18: "30 dp apart clusters, 50 dp does not" (marker_cluster_dp 40).
	var model := _model()
	assert_almost_eq(model.marker_cluster_dp(), 40.0, 0.001)
	var near := model.cluster_markers([
		_marker("a", 100.0, 100.0, 2), _marker("b", 130.0, 100.0, 4)])
	assert_eq(near.size(), 1, "30 dp apart clusters")
	assert_eq(int((near[0] as Dictionary)["count"]), 2)
	assert_eq(int((near[0] as Dictionary)["worst_tier"]), 4,
			"the badge carries the worst tier digit")
	assert_true(bool((near[0] as Dictionary)["clustered"]))
	assert_eq((near[0] as Dictionary)["position"], Vector2(115.0, 100.0),
			"the badge sits at the centroid")
	var far := model.cluster_markers([
		_marker("a", 100.0, 100.0, 2), _marker("b", 150.0, 100.0, 4)])
	assert_eq(far.size(), 2, "50 dp apart does not cluster")
	for cluster: Variant in far:
		assert_eq(int((cluster as Dictionary)["count"]), 1)
		assert_false(bool((cluster as Dictionary)["clustered"]))
	# Exactly on the radius still clusters.
	assert_eq(model.cluster_markers([
			_marker("a", 0.0, 0.0, 1), _marker("b", 40.0, 0.0, 1)]).size(), 1)


func test_marker_clustering_is_deterministic_and_worst_tier_seeded() -> void:
	var markers := [
		_marker("c", 200.0, 200.0, 1),
		_marker("a", 100.0, 100.0, 3),
		_marker("b", 120.0, 110.0, 5),
		_marker("d", 205.0, 215.0, 2),
		_marker("e", 600.0, 300.0, 4),
	]
	var model := _model()
	var first := model.cluster_markers(markers)
	var shuffled := [markers[3], markers[0], markers[4], markers[2], markers[1]]
	var second := model.cluster_markers(shuffled)
	assert_eq(first.size(), 3, "two pairs and a loner")
	assert_eq(first.size(), second.size(), "input order does not change the result")
	for i in first.size():
		var a: Dictionary = first[i]
		var b: Dictionary = second[i]
		assert_eq(str(a["ids"]), str(b["ids"]), "same members, same order")
		assert_eq(int(a["worst_tier"]), int(b["worst_tier"]))
	assert_eq(int((first[0] as Dictionary)["worst_tier"]), 5,
			"the worst tier seeds the first cluster")


func test_marker_projection_through_the_camera() -> void:
	# §2.15: pins are positioned from the camera projection each frame, then
	# clamped into the marker rect. Uses the real CameraState (doc 12 §2.16).
	var model := _model()
	var camera := CameraState.new({}, 40.0, {})
	camera.bounds_enabled = false
	camera.set_focus(Vector3(400.0, 0.0, 400.0))
	camera.set_zoom_t(0.42)
	var viewport := Vector2(880.0, 400.0)
	var rect := model.marker_rect(viewport)
	var projected := model.project_markers(camera, [
		{"id": "at_focus", "position": Vector3(400.0, 0.0, 400.0), "tier": 3},
		{"id": "far_away", "position": Vector3(400.0, 0.0, 40000.0), "tier": 5},
	], viewport)
	assert_eq(projected.size(), 2)
	var centre: Dictionary = projected[0]
	assert_false(bool(centre["offscreen"]), "the focus point projects on-screen")
	assert_almost_eq((centre["position"] as Vector2).x, 440.0, 1.0,
			"the focus lands on the horizontal centre line")
	var far: Dictionary = projected[1]
	assert_true(bool(far["offscreen"]))
	assert_true(_inside(far["position"] as Vector2, rect),
			"an off-screen pin clamps into the marker rect")


# ===========================================================================
# Speed & pause — doc 12 §2.11 and A10
# ===========================================================================

func test_speed_view_face_and_targets() -> void:
	# §2.11: "The button face shows ⏸ while paused, otherwise the current
	# multiplier"; the rail carries four targets (A10).
	var model := _model()
	var running := model.speed_view(2, false)
	assert_eq(str(running["face"]), "2×")
	assert_eq((running["options"] as Array).size(), 4, "pause + 1× + 2× + 3×")
	assert_eq(int(running["taps_to_target"]), 2, "A10: reachable in ≤ 2 taps")
	var selected := ""
	for option: Variant in (running["options"] as Array):
		if bool((option as Dictionary)["selected"]):
			selected = String((option as Dictionary)["id"])
	assert_eq(selected, "2x", "exactly the running multiplier is selected")
	var paused := model.speed_view(2, true)
	assert_eq(str(paused["face"]), HudModel.PAUSE_GLYPH)
	assert_true(bool((paused["options"] as Array)[0]["selected"]),
			"the pause target is the selected one while paused")


func test_speed_option_transitions() -> void:
	var model := _model()
	# ⏸ toggles the separate bool and leaves the multiplier alone (doc 01).
	var paused := model.apply_speed_option(HudModel.SPEED_PAUSE, 3, false)
	assert_eq(int(paused["speed"]), 3, "pausing never changes the stored speed")
	assert_true(bool(paused["paused"]))
	var unpaused := model.apply_speed_option(HudModel.SPEED_PAUSE, 3, true)
	assert_false(bool(unpaused["paused"]), "the same target toggles back")
	# Picking `▶ n×` sets the speed and resumes — the target is a play glyph.
	var fast := model.apply_speed_option(&"3x", 1, true)
	assert_eq(int(fast["speed"]), 3)
	assert_false(bool(fast["paused"]))
	# An unknown target is inert rather than a crash.
	var noop := model.apply_speed_option(&"4x", 2, false)
	assert_eq(int(noop["speed"]), 2)


func test_speed_clamping_follows_doc01() -> void:
	var model := _model()
	var options := model.speed_options()
	assert_eq(options.size(), 3, "doc 01 locks {1,2,3}")
	assert_eq(options[0], 1)
	assert_eq(options[1], 2)
	assert_eq(options[2], 3)
	assert_eq(model.clamp_speed(1), 1)
	assert_eq(model.clamp_speed(3), 3)
	assert_eq(model.clamp_speed(4), 1, "no 4× exists (C-65)")
	assert_eq(model.clamp_speed(0), 1, "and no sub-1× slow motion in MVP")
	assert_eq(HudModel.speed_option_id(2), &"2x")


func test_auto_speed_reset_never_force_pauses() -> void:
	# §2.11: `auto_speed_reset_on_critical` "resets speed to 1× and never
	# force-pauses — pausing the player mid-crisis is worse than the crisis".
	var model := _model()
	var reset := model.auto_speed_reset(3, false)
	assert_eq(int(reset["speed"]), 1)
	assert_false(bool(reset["paused"]))
	var while_paused := model.auto_speed_reset(3, true)
	assert_eq(int(while_paused["speed"]), 1)
	assert_true(bool(while_paused["paused"]), "an existing pause is left alone")


# ===========================================================================
# CityHUD binding — the Control half, exercised in a live tree
# ===========================================================================

## The scaffold scene with the HUD built. `setup()` is what `_ready()` calls, so
## the binding is exercised exactly as it runs in `game/main.tscn` — without
## needing a live tree (nodes added during `SceneTree._initialize()` are not
## inside the tree yet, so `_ready()` would not have fired).
func _hud_scene() -> Dictionary:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: Node = packed.instantiate()
	var hud := root.get_node("SafeArea/HUDLayer") as CityHUD
	hud.setup()
	return {"root": root, "hud": hud}


func test_hud_scene_builds_every_target_at_48dp() -> void:
	# A3: "min 48 × 48 dp for every interactive Control"; A15: every interactive
	# Control sets `tooltip_text`, used as the accessibility name.
	var scene := _hud_scene()
	var hud: CityHUD = scene["hud"]
	assert_ne(hud, null, "SafeArea/HUDLayer carries the CityHUD script")
	var targets: Array[Button] = []
	for chip_id: String in hud.model.chip_order():
		var button := hud.chip_button(chip_id)
		assert_ne(button, null, "chip %s is built from data/ui.json" % chip_id)
		targets.append(button)
	assert_eq(targets.size(), 7, "the doc 40.1 stat set")
	for option: Variant in (hud.model.speed_view(1, false)["options"] as Array):
		var button := hud.speed_option_button((option as Dictionary)["id"])
		assert_ne(button, null, "speed target %s exists" % str((option as Dictionary)["id"]))
		targets.append(button)
	targets.append(scene["root"].get_node("SafeArea/HUDLayer/TopBar/ClockChip") as Button)
	targets.append(scene["root"].get_node("SafeArea/HUDLayer/LeftRail/SpeedButton") as Button)
	for button: Button in targets:
		assert_true(button.custom_minimum_size.x >= 48.0 and button.custom_minimum_size.y >= 48.0,
				"%s is at least 48 × 48 dp" % button.name)
		assert_ne(button.tooltip_text, "", "%s has an accessibility name" % button.name)
	(scene["root"] as Node).free()


func test_hud_scene_refresh_binds_the_snapshot() -> void:
	var scene := _hud_scene()
	var hud: CityHUD = scene["hud"]
	hud.refresh({
		"treasury": 8420000, "net_per_hour": 5750.0, "population": 184291,
		"stability": 0.68, "incidents": {"count": 7, "worst_tier": 4},
		"clock": {"minute_of_day": 372, "day_index": 2}, "speed": 2, "paused": false,
	})
	assert_true(hud.chip_button("treasury").text.contains("$8.42M"))
	assert_true(hud.chip_button("population").text.contains("184,291"))
	assert_true(hud.chip_button("net_income").text.contains("+$138K/d"))
	assert_true(hud.chip_button("incidents").text.contains("T4"),
			"the tier digit is the primary redundancy channel (A5)")
	assert_true(hud.chip_button("grid").text.contains(HudModel.NO_DATA),
			"no grid reading published yet")
	# Through the HUD, not by node path: the clock chip and the ☰ button move into
	# top-bar row 0 at bring-up (doc 12 delta D-12).
	assert_eq(hud.clock_chip().text, "06:12")
	var speed_button := scene["root"].get_node(
			"SafeArea/HUDLayer/LeftRail/SpeedButton") as Button
	assert_eq(speed_button.text, "2×", "the face shows the current multiplier")
	(scene["root"] as Node).free()


func test_hud_scene_speed_rail_emits_commands() -> void:
	# A10: one tap raises the rail, the second selects any of the four targets.
	var scene := _hud_scene()
	var hud: CityHUD = scene["hud"]
	var speeds: Array[int] = []
	var pauses: Array[bool] = []
	hud.speed_selected.connect(func(multiplier: int) -> void: speeds.append(multiplier))
	hud.pause_toggled.connect(func(paused: bool) -> void: pauses.append(paused))
	var rail := scene["root"].get_node("SafeArea/HUDLayer/LeftRail/SpeedButton") as Button
	assert_false(hud.is_speed_rail_expanded())
	rail.pressed.emit()
	assert_true(hud.is_speed_rail_expanded(), "one tap raises the rail")
	hud.speed_option_button(&"3x").pressed.emit()
	assert_eq(speeds, [3] as Array[int], "the second tap issues set_speed{3}")
	assert_true(pauses.is_empty(), "picking a multiplier while running never pauses")
	assert_false(hud.is_speed_rail_expanded(), "the rail closes on selection")
	rail.pressed.emit()
	hud.speed_option_button(HudModel.SPEED_PAUSE).pressed.emit()
	assert_eq(pauses, [true] as Array[bool], "⏸ issues set_paused{true}")
	assert_eq(speeds.size(), 1, "pausing is not a speed command (doc 01)")
	(scene["root"] as Node).free()


func test_hud_scene_alert_stack_renders_the_gate_output() -> void:
	var scene := _hud_scene()
	var hud: CityHUD = scene["hud"]
	var stack := scene["root"].get_node("SafeArea/HUDLayer/AlertStack") as VBoxContainer
	assert_eq(stack.get_child_count(), 2, "alert_max_stack = 2 pooled rows")
	for child: Node in stack.get_children():
		assert_false((child as Control).visible, "an empty stack shows nothing")
	var verdict := hud.push_alert({"class": "p1", "event_type": "outage_major",
			"title": "3 blocks are dark"}, 0.0)
	assert_true(bool(verdict["delivered"]))
	assert_eq(verdict["surface"], HudModel.SURFACE_BANNER)
	var first := stack.get_child(0) as PanelContainer
	assert_true(first.visible)
	assert_eq((first.get_node("Row/Title") as Label).text, "3 blocks are dark")
	assert_eq((first.get_node("Row/Badge") as Label).text, "P1")
	# Tapping VIEW dismisses the sticky banner and reports the id upward.
	var seen: Array[String] = []
	hud.alert_activated.connect(func(id: String) -> void: seen.append(id))
	(first.get_node("Row/View") as Button).pressed.emit()
	assert_eq(seen.size(), 1, "the banner tap routes to jump + select")
	assert_false(first.visible, "and the sticky P1 leaves the stack")
	(scene["root"] as Node).free()


func test_resize_re_solves_the_chip_rows() -> void:
	# The chip solve is priced against the width `refresh()` ran at, and
	# `refresh()` arrives on the SIM cadence — so a paused game that changed
	# width (the Fold folding, the preview harness resizing after its one boot
	# refresh) kept the stale solve, and a row 0 solved wider than the new box
	# was centred whole by `grow_horizontal`: the treasury chip measured at
	# x = −121.5 in the 880×400 audit box (doc 12 D-65). `NOTIFICATION_RESIZED`
	# now queues one deferred re-solve.
	#
	# Two headless facts shape this test (measured 2026-09-01, the two failures
	# that had been hiding behind a piped exit code): a Control OUTSIDE the tree
	# never receives `NOTIFICATION_RESIZED` from `set_size`, and a container
	# outside the tree reports a ZERO combined minimum size. So the engine's
	# emission is taken as its contract and the notification is delivered by
	# hand, and the observable is the SOLVE — the row signature and the chips
	# row 0 keeps — not a container's measured width.
	var scene := _hud_scene()
	var hud: CityHUD = scene["hud"]
	var snapshot := {
		"treasury": 8420000, "net_per_hour": 5750.0, "population": 184291,
		"stability": 0.68, "incidents": {"count": 7, "worst_tier": 4},
		"clock": {"minute_of_day": 372, "day_index": 2}, "speed": 2, "paused": false,
	}
	hud.size = Vector2(1280.0, 720.0)
	hud.refresh(snapshot)
	var row0 := hud.get_node("TopBar/Chips/Row0") as HBoxContainer
	var wide_signature: String = hud._row_signature
	var wide_visible := 0
	for chip_id: String in hud.model.chip_order():
		if hud.chip_button(chip_id).visible:
			wide_visible += 1
	assert_eq(wide_visible, hud.model.chip_order().size(),
			"at 1280 dp every chip is on the bar")
	assert_eq(hud.get_node("TopBar/Chips").get_child_count(), 1, "and on one row")
	# The Fold folds: 480 dp of width, the same snapshot, no sim tick.
	hud.size = Vector2(480.0, 900.0)
	assert_false(hud._resize_solve_queued,
			"headless: set_size alone delivers no NOTIFICATION_RESIZED (Godot's "
			+ "contract is that the engine sends it in-tree)")
	hud.notification(Control.NOTIFICATION_RESIZED)
	assert_true(hud._resize_solve_queued,
			"NOTIFICATION_RESIZED queues the deferred re-solve")
	hud.notification(Control.NOTIFICATION_RESIZED)
	assert_true(hud._resize_solve_queued, "a resize burst queues it once, not once per event")
	hud._solve_after_resize()
	assert_false(hud._resize_solve_queued, "the queue drains with the solve")
	assert_ne(hud._row_signature, wide_signature,
			"re-solved at 480 dp, the rows are not the 1280 dp rows")
	var narrow_visible := 0
	for chip_id: String in hud.model.chip_order():
		if hud.chip_button(chip_id).visible:
			narrow_visible += 1
	var rows := hud.get_node("TopBar/Chips").get_child_count()
	assert_true(rows > 1 or narrow_visible < wide_visible,
			"the narrow solve wrapped or hid something (rows=%d, visible %d->%d)"
			% [rows, wide_visible, narrow_visible])
	assert_true(row0.get_child_count() > 0, "row 0 still carries the clock and the menu")
	(scene["root"] as Node).free()


func test_resume_from_save_is_unpaused() -> void:
	# §2.11: "A save that was paused resumes unpaused at its stored speed."
	var model := _model()
	var resumed := model.resume_from_save(2, true)
	assert_eq(int(resumed["speed"]), 2)
	assert_false(bool(resumed["paused"]))
	assert_eq(int(model.resume_from_save(9, false)["speed"]), 1,
			"a corrupt stored speed falls back to the 1× floor")
