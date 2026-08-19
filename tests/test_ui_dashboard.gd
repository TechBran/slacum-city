extends SimTest
## Doc 12 §2.10 — the city dashboard (S8), the hourly history ring behind its
## charts, the Economy tab's tax detent and ledger, and §2.4's two service chips.
##
## The tax half drives the **real** `CitySim.cmd_set_tax_level`, preview flag and
## all, so the preview payload keys (`rate`, `happiness_delta`,
## `growth_multiplier`, `changed`, `hours_remaining`) are asserted against doc 03
## rather than against a stub of it.


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _mount() -> Dictionary:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	_tree().root.add_child(root)
	root.initialize()
	return {"root": root, "dashboard": root.city_dashboard, "hud": root.hud}


func _unmount(mounted: Dictionary) -> void:
	var root: Node = mounted["root"]
	_tree().root.remove_child(root)
	root.free()


func _snapshot() -> Dictionary:
	return {
		"population": 182904, "treasury": 8420000, "net_per_hour": 5750.0,
		"stability": 0.71, "happiness": 0.64, "power01": 0.97, "water01": 0.88,
		"incidents": {"count": 2, "worst_tier": 4},
		"clock": {"minute_of_day": 372, "day_index": 2}, "speed": 1, "paused": false,
	}


## Doc 03's settle snapshot, trimmed to the keys `data/ui.json.budget` names.
static func _settlement() -> Dictionary:
	return {
		"hour": 40,
		"revenue": {"tax": 12000.0, "power_tariff": 900.0, "water_tariff": 400.0,
				"fines": 0.0, "gross": 13300.0},
		"expenses": {"building_maint": 4000.0, "departments": 2200.0, "fleet": 600.0,
				"vehicle_fuel": 120.0, "grid": 300.0, "generation_fuel": 800.0,
				"water": 250.0, "roads_repair": 0.0, "debt": 0.0, "total": 8270.0},
		"net": 5030.0,
	}


# ===========================================================================
# HistoryModel — the ring
# ===========================================================================

func test_the_ring_is_fixed_size_and_keeps_the_newest() -> void:
	var history := HistoryModel.new(_cfg())
	assert_eq(history.capacity, UIConfig.get_int(_cfg().section("dashboard"),
			"history_capacity", 168))
	assert_eq(history.size(), 0)
	for i in history.capacity + 20:
		history.sample({"treasury": float(i), "hour": i})
	assert_eq(history.size(), history.capacity, "it never grows past its cap")
	assert_true(history.is_full())
	var series := history.series("treasury")
	assert_eq(series.size(), history.capacity)
	assert_almost_eq(series[series.size() - 1], float(history.capacity + 19), 0.0001,
			"the newest sample is last")
	assert_almost_eq(series[0], 20.0, 0.0001, "and the oldest 20 fell off the front")


func test_a_missing_key_is_a_hole_not_a_zero() -> void:
	# A series the sim did not publish this hour must not draw a cliff to zero.
	var history := HistoryModel.new(_cfg())
	history.sample({"treasury": 100.0})
	history.sample({"population": 5.0})
	history.sample({"treasury": 300.0})
	var treasury := history.series("treasury")
	assert_eq(treasury.size(), 2, "only the hours that carried it")
	assert_almost_eq(treasury[0], 100.0, 0.0001)
	assert_almost_eq(treasury[1], 300.0, 0.0001)
	assert_eq(history.size(), 3, "the ring itself still advanced three hours")


func test_limit_takes_the_newest_window() -> void:
	var history := HistoryModel.new(_cfg())
	for i in 50:
		history.sample({"population": float(i)})
	var last24 := history.series("population", 24)
	assert_eq(last24.size(), 24)
	assert_almost_eq(last24[0], 26.0, 0.0001)
	assert_almost_eq(last24[23], 49.0, 0.0001)
	assert_almost_eq(history.latest("population"), 49.0, 0.0001)
	assert_eq(history.range_of("population", 24), Vector2(26.0, 49.0))


func test_normalized_fits_the_unit_square_and_says_so() -> void:
	var history := HistoryModel.new(_cfg())
	for value in [10.0, 20.0, 30.0]:
		history.sample({"treasury": value})
	var shape := history.normalized("treasury")
	var points: PackedVector2Array = shape["points"]
	assert_eq(points.size(), 3)
	assert_eq(points[0], Vector2(0.0, 0.0), "the minimum sits on the floor")
	assert_eq(points[2], Vector2(1.0, 1.0), "the maximum on the ceiling")
	assert_almost_eq(points[1].y, 0.5, 0.0001)
	assert_almost_eq(float(shape["delta"]), 20.0, 0.0001)
	assert_eq(int(shape["count"]), 3)


func test_a_flat_series_draws_down_the_middle_rather_than_dividing_by_zero() -> void:
	var history := HistoryModel.new(_cfg())
	for _i in 4:
		history.sample({"stability": 0.7})
	var shape := history.normalized("stability")
	for point: Vector2 in (shape["points"] as PackedVector2Array):
		assert_almost_eq(point.y, 0.5, 0.0001)
	assert_almost_eq(float(shape["delta"]), 0.0, 0.0001)


func test_an_empty_series_is_no_line_at_all() -> void:
	var history := HistoryModel.new(_cfg())
	assert_eq(history.series("treasury").size(), 0)
	var shape := history.normalized("treasury")
	assert_eq(int(shape["count"]), 0, "a chart with no data draws nothing")
	assert_eq((shape["points"] as PackedVector2Array).size(), 0)


# ===========================================================================
# DashboardModel — the Overview bands
# ===========================================================================

func test_every_band_reads_the_same_number_its_hud_chip_does() -> void:
	var cfg := _cfg()
	var model := DashboardModel.new(cfg)
	var hud := HudModel.new(cfg)
	var snapshot := _snapshot()
	var chips := hud.chip_values(snapshot)
	var view := model.build_view(snapshot)
	var by_id: Dictionary = {}
	for row: Variant in (view["rows"] as Array):
		by_id[str((row as Dictionary)["id"])] = row
	for pair: Array in [["treasury", "treasury"], ["population", "population"],
			["grid", "grid"], ["water", "water"], ["stability", "stability"],
			["net_income", "net_income"], ["incidents", "incidents"]]:
		var band: Dictionary = by_id[pair[0]]
		var chip: Dictionary = chips[pair[1]]
		assert_eq(str(band["value_text"]), str(chip["text_full"]),
				"%s says the same thing in both places" % pair[0])
		assert_eq(band["state"], chip["state"], "%s bands the same" % pair[0])
	assert_eq(str(by_id["happiness"]["value_text"]), "64%",
			"happiness is [0,1] in the sim and a percent on screen (§2.4)")


func test_a_band_with_history_gets_a_sparkline_and_one_without_gets_none() -> void:
	var model := DashboardModel.new(_cfg())
	for i in 30:
		model.history.sample({"treasury": float(8000000 + i * 1000),
				"population": float(180000 + i)})
	var view := model.build_view(_snapshot())
	for row: Variant in (view["rows"] as Array):
		var band: Dictionary = row
		var spark: Dictionary = band["spark"]
		if str(band["id"]) == "treasury":
			assert_eq(int(spark["count"]), model.spark_hours(),
					"the sparkline is the last 24 h, not all of history")
		elif str(band["id"]) == "incidents":
			assert_eq(int(spark["count"]), 0, "incidents is a count, not a series")


func test_rows_carry_the_deep_links_2_10_names() -> void:
	var model := DashboardModel.new(_cfg())
	var view := model.build_view(_snapshot())
	var links: Dictionary = {}
	for row: Variant in (view["rows"] as Array):
		links[str((row as Dictionary)["id"])] = str((row as Dictionary)["deeplink"])
	assert_eq(str(links["grid"]), "overlay/power", "§2.10: Grid → power overlay")
	assert_eq(str(links["incidents"]), "drawer", "§2.10: Active incidents → drawer")
	assert_eq(str(links["population"]), "", "a row with nowhere to go says so")


func test_a_hud_chip_maps_to_its_band() -> void:
	var model := DashboardModel.new(_cfg())
	for chip_id: String in HudModel.CHIP_LABELS:
		var row_id := model.row_for_chip(StringName(chip_id))
		assert_true(model.row_ids().has(row_id),
				"chip '%s' lands on a real band ('%s')" % [chip_id, row_id])
	assert_eq(model.row_for_chip(&"grid"), "grid")
	assert_eq(model.row_for_chip(&"treasury"), "treasury")


func test_chart_axis_labels_speak_each_series_own_units() -> void:
	var model := DashboardModel.new(_cfg())
	for i in 5:
		model.history.sample({"treasury": float(8000000 + i * 100000),
				"population": float(180000 + i * 100), "stability": 0.6 + 0.01 * float(i)})
	model.select_row("treasury")
	var chart := model.chart("treasury")
	assert_eq(str(chart["min_text"]), HudModel.money(8000000))
	assert_eq(str(chart["max_text"]), HudModel.money(8400000))
	assert_eq(model.chart("population")["min_text"], HudModel.pop(180000))
	assert_eq(str(model.chart("stability")["max_text"]), "64%",
			"the ×100 happens once, at the point of display")
	assert_eq(int(model.chart("incidents")["count"]), 0)
	assert_ne(str(model.chart("incidents")["empty_text"]), "",
			"and says so in words rather than drawing an empty box")


# ===========================================================================
# BudgetModel — preview through the sim, never around it
# ===========================================================================

func test_the_stepper_previews_through_the_sim_and_changes_nothing() -> void:
	var sim := CitySim.boot_from_files()
	var budget := BudgetModel.new(_cfg())
	budget.set_tax_command(sim.cmd_set_tax_level)
	budget.set_tax_state(sim.tax_level(), sim.tax_level_count(), sim.tax_rate)
	var before := sim.tax_rate
	var start := budget.level()

	var up := budget.step(1)
	assert_true(bool(up["ok"]))
	assert_eq(int(up["level"]), start + 1)
	assert_almost_eq(float(up["rate"]), sim.tax_rate_for_level(start + 1), 0.000001)
	assert_true(bool(up["changed"]))
	assert_true(bool(up["can_apply"]))
	assert_almost_eq(sim.tax_rate, before, 0.000001,
			"a preview is a preview: the sim did not move")
	assert_eq(str(up["rate_text"]), BudgetModel.rate_text(float(up["rate"])))
	assert_ne(str(up["happiness_text"]), "", "the player sees the happiness cost")
	assert_ne(str(up["growth_text"]), "", "and the growth cost")

	# Doc 03: happiness_tax_delta = −(r − 0.09) × 220, so raising tax hurts.
	assert_true(float(up["happiness_delta"]) < 0.0)
	assert_true(float(up["growth_multiplier"]) < 1.0)
	var down := budget.step(-2)
	assert_true(float(down["happiness_delta"]) > 0.0, "and lowering it helps")
	assert_true(float(down["growth_multiplier"]) > 1.0)


func test_the_ladder_clamps_rather_than_erroring_at_either_end() -> void:
	var sim := CitySim.boot_from_files()
	var budget := BudgetModel.new(_cfg())
	budget.set_tax_command(sim.cmd_set_tax_level)
	budget.set_tax_state(sim.tax_level(), sim.tax_level_count(), sim.tax_rate)
	for _i in sim.tax_level_count() + 5:
		budget.step(1)
	assert_eq(budget.pending_level(), sim.tax_level_count() - 1)
	for _i in sim.tax_level_count() + 5:
		budget.step(-1)
	assert_eq(budget.pending_level(), 0)


func test_standing_still_is_ok_but_not_applicable() -> void:
	var sim := CitySim.boot_from_files()
	var budget := BudgetModel.new(_cfg())
	budget.set_tax_command(sim.cmd_set_tax_level)
	budget.set_tax_state(sim.tax_level(), sim.tax_level_count(), sim.tax_rate)
	var same := budget.preview(sim.tax_level())
	assert_true(bool(same["ok"]))
	assert_false(bool(same["changed"]))
	assert_false(bool(same["can_apply"]), "APPLY is off when nothing would change")
	assert_eq(str(same["note"]), UIWidgets.t(_cfg(), "ui_budget_unchanged"))


func test_apply_moves_the_sim_and_the_cooldown_then_blocks_the_next_move() -> void:
	var sim := CitySim.boot_from_files()
	var budget := BudgetModel.new(_cfg())
	budget.set_tax_command(sim.cmd_set_tax_level)
	budget.set_tax_state(sim.tax_level(), sim.tax_level_count(), sim.tax_rate)
	var start := sim.tax_level()
	budget.step(1)
	var applied := budget.apply()
	assert_true(bool(applied["applied"]))
	assert_eq(sim.tax_level(), start + 1, "the sim really moved")
	assert_eq(budget.level(), sim.tax_level(), "and the model re-synced from it")

	var cooldown := int((sim.econ_curves.economy_data().get("tax", {}) as Dictionary)
			.get("TAX_RATE_COOLDOWN_HOURS", 0))
	if cooldown <= 0:
		return
	var blocked := budget.step(1)
	assert_false(bool(blocked["ok"]), "doc 03's cooldown refuses the second move")
	assert_eq(blocked["reason"], &"E_TAX_COOLDOWN")
	assert_false(bool(blocked["can_apply"]))
	assert_true(str(blocked["note"]).contains(str(cooldown)),
			"A14: the block says how long in words — '%s'" % blocked["note"])
	assert_ne(str(blocked["rate_text"]), "",
			"and still previews the rate it refused, so the player can see it")


func test_without_a_command_the_panel_says_so_instead_of_lying() -> void:
	var budget := BudgetModel.new(_cfg())
	budget.set_tax_state(4, 13, 0.09)
	var view := budget.preview(5)
	assert_false(bool(view["ok"]))
	assert_eq(view["reason"], BudgetModel.REASON_NO_COMMAND)
	assert_false(bool(view["can_apply"]))
	assert_eq(str(view["note"]), UIWidgets.t(_cfg(), "ui_budget_unavailable"))
	assert_false(bool(budget.apply()["applied"]))


func test_rate_text_reads_the_way_doc03_states_the_ladder() -> void:
	assert_eq(BudgetModel.rate_text(0.09), "9%")
	assert_eq(BudgetModel.rate_text(0.095), "9.5%")
	assert_eq(BudgetModel.rate_text(0.16), "16%")
	assert_eq(BudgetModel.signed(-3.2, 1), HudModel.MINUS + "3.2")
	assert_eq(BudgetModel.signed(1387.0), HudModel.PLUS + "1387")


# ===========================================================================
# BudgetModel — the settled hour
# ===========================================================================

func test_the_breakdown_uses_doc03s_own_keys() -> void:
	var budget := BudgetModel.new(_cfg())
	assert_false(budget.has_settlement())
	assert_false(bool(budget.breakdown()["has_data"]),
			"before the first settled hour there is nothing to show")
	budget.feed_settlement(_settlement())
	var ledger := budget.breakdown()
	assert_true(bool(ledger["has_data"]))
	assert_true(bool(ledger["has_breakdown"]))
	assert_almost_eq(float(ledger["gross"]), 13300.0, 0.0001)
	assert_almost_eq(float(ledger["expense"]), 8270.0, 0.0001)
	assert_almost_eq(float(ledger["net"]), 5030.0, 0.0001)
	var revenue_keys: Array[String] = []
	for line: Variant in (ledger["revenue"] as Array):
		revenue_keys.append(str((line as Dictionary)["key"]))
	assert_eq(revenue_keys, ["tax", "power_tariff", "water_tariff"] as Array[String],
			"the zero line (fines) is dropped, not printed as $0")
	for line: Variant in (ledger["expenses"] as Array):
		var record: Dictionary = line
		assert_ne(str(record["label"]), "ui_budget_expense_%s" % record["key"],
				"every expense line resolves its copy (G-8): %s" % record["key"])
		assert_ne(str(record["text"]), "")


func test_the_bus_event_alone_still_gives_the_three_totals() -> void:
	# `economy_hour_settled` is what the shell can wire without touching sim/.
	var budget := BudgetModel.new(_cfg())
	budget.feed_settlement({"type": &"economy_hour_settled", "hour": 40,
			"gross": 13300.0, "expense": 8270.0, "net": 5030.0})
	var ledger := budget.breakdown()
	assert_true(bool(ledger["has_data"]))
	assert_false(bool(ledger["has_breakdown"]), "and the view knows to hide the lines")
	assert_almost_eq(float(ledger["net"]), 5030.0, 0.0001)
	# Doc 12 delta D-18: the total line reports the settled **hour**, like the
	# lines above it. A per-day net beside a per-hour gross and a per-hour expense
	# is a unit error, not a summary — the per-day reading is still published, as
	# `net_per_day_text`, for the chip that wants it.
	assert_eq(str(ledger["net_text"]), HudModel.money_signed(5030))
	assert_eq(str(ledger["net_per_day_text"]), HudModel.rate_per_day(5030.0))
	assert_eq(ledger["net_state"], HudModel.STATE_NORMAL)


func test_a_losing_hour_bands_as_a_warning() -> void:
	var budget := BudgetModel.new(_cfg())
	budget.feed_settlement({"gross": 1000.0, "expense": 4000.0, "net": -3000.0})
	assert_eq(budget.breakdown()["net_state"], HudModel.STATE_WARNING)


# ===========================================================================
# The real HUD chips (§2.4 P3/P4)
# ===========================================================================

func test_no_reading_is_a_dash_in_offline_grey_not_a_zero() -> void:
	var hud := HudModel.new(_cfg())
	var chips := hud.chip_values({"treasury": 100})
	assert_eq(str(chips["grid"]["text_full"]), HudModel.NO_DATA)
	assert_eq(chips["grid"]["state"], HudModel.STATE_OFFLINE)
	assert_eq(str(chips["water"]["text_full"]), HudModel.NO_DATA)
	assert_eq(chips["water"]["state"], HudModel.STATE_OFFLINE)


func test_ingested_fractions_render_as_percentages_with_the_right_state() -> void:
	var hud := HudModel.new(_cfg())
	hud.ingest_service({"power01": 0.97, "water01": 0.88})
	var chips := hud.chip_values({})
	assert_eq(str(chips["grid"]["text_full"]), "97%")
	assert_eq(chips["grid"]["state"], HudModel.STATE_NORMAL, "≥95 % is NORMAL")
	assert_eq(str(chips["water"]["text_full"]), "88%")
	assert_eq(chips["water"]["state"], HudModel.STATE_WARNING, "85–94 % is WARNING")
	assert_false(bool(chips["water"]["pulse"]))

	hud.ingest_service({"power01": 0.42})
	chips = hud.chip_values({})
	assert_eq(chips["grid"]["state"], HudModel.STATE_CRITICAL)
	assert_true(bool(chips["grid"]["pulse"]), "<60 % pulses (§2.4 P3/P4)")
	assert_eq(str(chips["water"]["text_full"]), "88%",
			"a partial ingest leaves the other reading alone")


func test_a_snapshot_reading_wins_over_the_ingested_one() -> void:
	var hud := HudModel.new(_cfg())
	hud.ingest_service({"power01": 0.50})
	assert_eq(str(hud.chip_values({"grid_pct": 99.0})["grid"]["text_full"]), "99%")
	assert_eq(str(hud.chip_values({"power01": 0.80})["grid"]["text_full"]), "80%")
	assert_eq(str(hud.chip_values({})["grid"]["text_full"]), "50%")


func test_mean01_is_the_shells_one_liner_and_empty_means_no_reading() -> void:
	assert_almost_eq(HudModel.mean01({"a": 1.0, "b": 0.0}), 0.5, 0.0001)
	assert_almost_eq(HudModel.mean01([1.0, 1.0, 0.4]), 0.8, 0.0001)
	assert_almost_eq(HudModel.mean01({}), -1.0, 0.0001,
			"a city with no buildings has no reading, not a reading of zero")
	assert_almost_eq(HudModel.mean01([]), -1.0, 0.0001)
	assert_almost_eq(HudModel.mean01({"a": 3.0}), 1.0, 0.0001, "clamped to [0,1]")
	assert_almost_eq(HudModel.mean01("nonsense"), -1.0, 0.0001)


func test_a_negative_ingest_puts_the_chip_back_to_no_reading() -> void:
	var hud := HudModel.new(_cfg())
	hud.ingest_service({"power01": 0.9})
	hud.ingest_service({"power01": -1.0})
	assert_eq(str(hud.chip_values({})["grid"]["text_full"]), HudModel.NO_DATA)


# ===========================================================================
# The mounted dashboard
# ===========================================================================

func test_the_dashboard_mounts_closed_and_opens_on_a_chip() -> void:
	var mounted := _mount()
	var dashboard: CityDashboard = mounted["dashboard"]
	var hud: CityHUD = mounted["hud"]
	assert_ne(dashboard, null, "SafeArea/ModalLayer/CityDashboard is wired")
	assert_false(dashboard.is_open())
	dashboard.refresh(_snapshot())
	hud.chip_button("population").pressed.emit()
	assert_true(dashboard.is_open(), "§2.4's chip opens §2.10's dashboard")
	assert_eq(dashboard.model.selected_row(), "population", "scrolled to that band")
	assert_ne(dashboard.row_button("population"), null)
	_unmount(mounted)


func test_the_treasury_chip_lands_on_the_economy_tab() -> void:
	var mounted := _mount()
	var dashboard: CityDashboard = mounted["dashboard"]
	var hud: CityHUD = mounted["hud"]
	dashboard.refresh(_snapshot())
	hud.chip_button("treasury").pressed.emit()
	assert_true(dashboard.is_open())
	assert_eq(dashboard.model.tab(), DashboardModel.TAB_ECONOMY)
	assert_ne(dashboard.tax_button("TaxUp"), null, "the tax stepper is there")
	_unmount(mounted)


func test_tapping_the_incidents_band_opens_the_drawer_through_the_root() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var dashboard: CityDashboard = mounted["dashboard"]
	dashboard.open(DashboardModel.TAB_OVERVIEW)
	dashboard.refresh(_snapshot())
	dashboard.row_button("incidents").pressed.emit()
	assert_false(dashboard.is_open(), "the dashboard got out of the way")
	assert_true(root.incident_drawer.is_open(), "§2.10's deep link landed")
	_unmount(mounted)


func test_an_overlay_deep_link_is_re_emitted_for_the_shell() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var dashboard: CityDashboard = mounted["dashboard"]
	var links: Array[String] = []
	root.deeplink_requested.connect(func(target: String) -> void: links.append(target))
	dashboard.open(DashboardModel.TAB_OVERVIEW)
	dashboard.refresh(_snapshot())
	dashboard.row_button("grid").pressed.emit()
	assert_eq(links, ["overlay/power"] as Array[String],
			"only the shell owns the render mode, so it decides")
	_unmount(mounted)


func test_the_tax_stepper_walks_the_ladder_and_applies_once() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var dashboard: CityDashboard = mounted["dashboard"]
	var sim := CitySim.boot_from_files()
	var applied: Array = []
	root.tax_applied.connect(func(level: int, rate: float) -> void:
		applied.append([level, rate]))
	root.bind_tax(sim.cmd_set_tax_level, sim.tax_level(), sim.tax_level_count(),
			sim.tax_rate)
	dashboard.open(DashboardModel.TAB_ECONOMY)
	var start := sim.tax_level()
	assert_true(dashboard.tax_button("TaxApply").disabled,
			"APPLY starts off — nothing has moved yet")
	dashboard.tax_button("TaxUp").pressed.emit()
	assert_false(dashboard.tax_button("TaxApply").disabled)
	assert_true(dashboard.tax_rate_text().contains(
			BudgetModel.rate_text(sim.tax_rate_for_level(start + 1))),
			"the face shows the previewed rate: %s" % dashboard.tax_rate_text())
	assert_eq(sim.tax_level(), start, "and the sim has not moved")
	dashboard.tax_button("TaxApply").pressed.emit()
	assert_eq(sim.tax_level(), start + 1, "APPLY is what moves it")
	assert_eq(applied.size(), 1)
	assert_eq(int(applied[0][0]), start + 1)
	_unmount(mounted)


func test_the_economy_tab_shows_the_settled_hour() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var dashboard: CityDashboard = mounted["dashboard"]
	dashboard.open(DashboardModel.TAB_ECONOMY)
	root.feed_settlement(_settlement())
	var view := dashboard.model.build_view(_snapshot())
	assert_true(bool((view["budget"] as Dictionary)["has_breakdown"]))
	assert_ne(dashboard.model.budget.breakdown()["net_text"], "")
	_unmount(mounted)


func test_the_root_samples_history_and_the_charts_follow() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var dashboard: CityDashboard = mounted["dashboard"]
	for i in 30:
		root.sample_history({"hour": i, "treasury": float(8000000 + i * 1000),
				"population": float(180000 + i), "power01": 0.9, "water01": 0.9})
	dashboard.open(DashboardModel.TAB_OVERVIEW)
	root.refresh_dashboard(_snapshot())
	assert_eq(dashboard.model.history.size(), 30)
	assert_ne(dashboard.chart_control(), null, "a chart is drawn once there is data")
	assert_true((dashboard.chart_control().points as PackedVector2Array).size() > 1)
	_unmount(mounted)


func test_the_root_feeds_the_service_chips() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var hud: CityHUD = mounted["hud"]
	hud.refresh(_snapshot())
	root.ingest_service({"power01": 0.60, "water01": 0.99})
	hud.refresh({"treasury": 100, "clock": 0})
	assert_true(hud.chip_button("grid").text.contains("60%"),
			"the ⚡ chip reads the served fraction: %s" % hud.chip_button("grid").text)
	assert_true(hud.chip_button("water").text.contains("99%"))
	_unmount(mounted)


func test_the_dashboard_is_a_modal_and_back_closes_it_first() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var dashboard: CityDashboard = mounted["dashboard"]
	dashboard.open()
	assert_true(dashboard.is_open())
	root.settings_sheet.open()
	assert_false(dashboard.is_open(), "one modal at a time")
	dashboard.open()
	assert_false(root.settings_sheet.is_open())
	assert_eq(root.handle_back(0.0), UIRoot.BACK_CLOSE_MODAL)
	assert_false(dashboard.is_open())
	_unmount(mounted)
