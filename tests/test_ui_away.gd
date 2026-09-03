extends SimTest
## Doc 12 §2.12 — WHILE YOU WERE AWAY (S11): the trigger, the section order, the
## caps, and the one CTA that matters.
##
## The digest fed here is **raw sim bus events**, and the classification is
## asserted to come from `data/ui.json.alerts.events` rather than from a second
## opinion — the report's idea of "a P1 happened offline" has to be the same one
## the banner and the push use, or the player is told two different stories about
## the same night.


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _model() -> AwayModel:
	return AwayModel.new(_cfg())


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _mount() -> Dictionary:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	_tree().root.add_child(root)
	root.initialize()
	return {"root": root, "sheet": root.away_report}


func _unmount(mounted: Dictionary) -> void:
	var root: Node = mounted["root"]
	_tree().root.remove_child(root)
	root.free()


## The input contract, filled in. Every key is optional; this is the full shape.
static func _input(elapsed_s: float, digest: Array = [],
		unresolved: Array = []) -> Dictionary:
	return {
		"elapsed_wall_s": elapsed_s,
		"elapsed_game_minutes": elapsed_s,
		"capped": false,
		"before": {"treasury": 8420000, "population": 182904, "day_index": 2,
				"stability": 0.71, "happiness": 0.62},
		"after": {"treasury": 10788800, "population": 184291, "day_index": 4,
				"stability": 0.68, "happiness": 0.62},
		"events_digest": digest,
		"unresolved": unresolved,
	}


static func _incident_row(id: int, tier: int, wait_min: float) -> Dictionary:
	return {"id": id, "tier": tier, "title": "Structure fire",
			"subtitle": "Harbour · no units", "wait_min": wait_min,
			"state": HudModel.STATE_CRITICAL}


# ===========================================================================
# Trigger (§2.12)
# ===========================================================================

func test_the_threshold_is_the_one_in_the_data_file() -> void:
	var model := _model()
	var limit := model.min_real_seconds()
	assert_almost_eq(limit, UIConfig.get_num(_cfg().section("away_report"),
			"min_real_seconds", 120.0), 0.0001)
	assert_true(model.should_show(_input(limit)))
	assert_true(model.should_show(_input(limit + 1.0)))
	assert_false(model.should_show(_input(limit - 1.0)),
			"a 30-second app-switch must never produce a modal")


func test_a_notable_event_shows_the_report_however_short_the_absence() -> void:
	var model := _model()
	var quiet := _input(10.0, [{"type": "building_completed", "building": 3, "level": 2}])
	assert_false(model.should_show(quiet), "a P3 is not worth a modal")
	var loud := _input(10.0, [{"type": "BlockDarkChanged", "block_id": "B2",
			"block_dark": true}])
	assert_true(model.should_show(loud), "a P1 outage is")
	# doc 08's table (not the deleted ui.json stand-in): a level-up is P3 — it is
	# good news, and good news does not open a modal. A broken main is P2.
	var promotion := _input(10.0, [{"type": "city_level_changed", "from": 2, "to": 3}])
	assert_false(model.should_show(promotion), "a level-up is welcome, not urgent")
	var mid := _input(10.0, [{"type": "water_main_break", "edge": "M-12",
			"severity": 0.6, "damage_fraction": 0.4}])
	assert_true(model.should_show(mid), "and a P2 water main break is")


func test_classification_comes_from_the_alerts_table_not_a_second_opinion() -> void:
	var model := _model()
	assert_eq(model.event_class({"type": "BlockDarkChanged", "block_id": "B2",
			"block_dark": true}), AwayModel.CLASS_P1)
	assert_eq(model.event_class({"type": "BlockDarkChanged", "block_id": "B2",
			"block_dark": false}), AwayModel.CLASS_P3,
			"the same event type, the other rule — the table's `match` decides")
	# …and the class is doc 08's now, not the deleted stand-in's: power coming
	# BACK is `P3_routine`, because a problem that has already ended is not a
	# thing the away report needs to put in front of anybody.
	assert_eq(model.event_class({"type": "PowerComponentFailed", "component": "T-04",
			"cause": "overload"}), AwayModel.CLASS_P2,
			"a failed transformer still is")
	assert_eq(model.event_class({"type": "building_completed", "building": 1,
			"level": 2}), AwayModel.CLASS_P3)
	assert_eq(model.event_class({"type": "job_started"}), AwayModel.CLASS_P3,
			"an event the table does not know is routine, not critical")
	# Doc 06's incidents are not in the alerts table; they band off tier (§2.4).
	assert_eq(model.event_class({"type": "incident_created", "incident_id": 1,
			"tier": 5}), AwayModel.CLASS_P1)
	assert_eq(model.event_class({"type": "incident_created", "incident_id": 1,
			"tier": 3}), AwayModel.CLASS_P2)
	assert_eq(model.event_class({"type": "incident_resolved", "incident_id": 1,
			"tier_peak": 1}), AwayModel.CLASS_P3)
	assert_eq(model.event_class({"type": "incident_created", "incident_id": 1,
			"severity": 4.6}), AwayModel.CLASS_P1,
			"severity bands the same way the drawer does when no tier is stated")


func test_an_unresolved_incident_alone_is_enough_to_show_it() -> void:
	var model := _model()
	assert_true(model.should_show(_input(5.0, [], [_incident_row(1, 4, 47.0)])),
			"something still needs the player, so the player gets told")


# ===========================================================================
# Sections (§2.12's fixed order)
# ===========================================================================

func test_the_header_states_both_clocks_and_the_cap_when_it_bit() -> void:
	var model := _model()
	var header: Dictionary = model.build(_input(22320.0))["header"]
	assert_true(str(header["text"]).contains("6:12"),
			"6 h 12 m of wall clock: %s" % header["text"])
	assert_false(bool(header["capped"]))
	assert_eq(str(header["capped_text"]), "")

	var capped := _input(26.0 * 3600.0)
	capped["capped"] = true
	capped["cap_real_hours"] = 12.0
	capped["elapsed_game_minutes"] = 720.0 * 60.0
	var capped_header: Dictionary = model.build(capped)["header"]
	assert_true(bool(capped_header["capped"]))
	# RR-162: the cap is stated in the unit the player was AWAY in. The line
	# used to quote `cap_game_hours` and render "Your city ran for 720h", which
	# is city time in a sentence about somebody's night.
	assert_true(str(capped_header["capped_text"]).contains("12"),
			"doc 01's cap is stated honestly: %s" % capped_header["capped_text"])
	assert_false(str(capped_header["capped_text"]).contains("720"),
			"and not in city time: %s" % capped_header["capped_text"])
	assert_almost_eq(float(capped_header["game_days"]), 30.0, 0.001,
			"720 game-hours is 30 game-days")

	# The legacy spelling still says something true rather than something
	# absurd, so a caller that has not been updated is not a new bug.
	var legacy := _input(26.0 * 3600.0)
	legacy["capped"] = true
	legacy["cap_game_hours"] = 720.0
	legacy["elapsed_game_minutes"] = 720.0 * 60.0
	assert_true(str((model.build(legacy)["header"] as Dictionary)["capped_text"]).contains("12"),
			"cap_game_hours 720 converts to the 12 real hours the player slept")


func test_needs_you_now_is_first_capped_and_worst_first() -> void:
	var model := _model()
	var cap := model.max_unresolved_shown()
	var rows: Array = []
	for i in cap + 3:
		rows.append(_incident_row(i + 1, 1 + (i % 5), float(i) * 10.0))
	var section: Dictionary = model.build(_input(300.0, [], rows))["needs_you"]
	assert_true(bool(section["visible"]))
	assert_eq((section["rows"] as Array).size(), cap, "§2.12 caps the list")
	assert_eq(int(section["total"]), cap + 3)
	assert_ne(str(section["more_text"]), "", "and says how many it did not show")
	assert_eq(section["state"], HudModel.STATE_CRITICAL, "rendered in CRITICAL styling")
	var first: Dictionary = (section["rows"] as Array)[0]
	assert_eq(int(first["tier"]), 5, "the worst one is the one you see")
	assert_eq(str(section["action_text"]), UIWidgets.t(_cfg(), "ui_away_handle_now"))


func test_an_empty_section_is_omitted_rather_than_drawn_empty() -> void:
	var model := _model()
	var view := model.build(_input(300.0))
	assert_false(bool((view["needs_you"] as Dictionary)["visible"]),
			"nothing needs you, so there is no NEEDS YOU NOW")
	assert_false(bool((view["timeline"] as Dictionary)["visible"]))
	assert_ne(str((view["timeline"] as Dictionary)["empty_text"]), "",
			"but the section still has words for the quiet case")


func test_the_ledger_is_doc03s_when_it_has_one_and_honest_when_it_does_not() -> void:
	var model := _model()
	var plain: Dictionary = model.build(_input(300.0))["ledger"]
	assert_true(bool(plain["visible"]), "the treasury moved, so there is something")
	assert_false(bool(plain["has_ledger"]))
	assert_almost_eq(float(plain["net"]), 2368800.0, 0.001,
			"without doc 03's figures the treasury delta stands in")
	assert_true(str(plain["treasury_text"]).contains(HudModel.money(8420000)))

	var with_ledger := _input(300.0)
	with_ledger["ledger"] = {"taxes": 3120400.0, "expenses": 751600.0,
			"net": 2368800.0, "treasury_before": 8420000, "treasury_after": 10788800}
	var rich: Dictionary = model.build(with_ledger)["ledger"]
	assert_true(bool(rich["has_ledger"]))
	assert_true(str(rich["text"]).contains(HudModel.money(3120400)),
			"taxes are stated: %s" % rich["text"])
	assert_true(str(rich["text"]).contains(HudModel.money(751600)))
	assert_eq(rich["net_state"], HudModel.STATE_NORMAL)


func test_a_losing_night_bands_the_net_as_a_warning() -> void:
	var model := _model()
	var input := _input(300.0)
	(input["after"] as Dictionary)["treasury"] = 1000
	assert_eq((model.build(input)["ledger"] as Dictionary)["net_state"],
			HudModel.STATE_WARNING)


func test_city_change_drops_the_lines_that_did_not_change() -> void:
	var model := _model()
	var view := model.build(_input(300.0))
	var change: Dictionary = view["change"]
	assert_true(bool(change["visible"]))
	var ids: Array[String] = []
	for line: Variant in (change["lines"] as Array):
		ids.append(str((line as Dictionary)["id"]))
	assert_true(ids.has("population"))
	assert_true(ids.has("days"))
	assert_true(ids.has("stability"))
	assert_false(ids.has("happiness"),
			"happiness did not move, so it is not a line that says +0")

	var quiet := _input(300.0)
	quiet["after"] = (quiet["before"] as Dictionary).duplicate()
	assert_false(bool((model.build(quiet)["change"] as Dictionary)["visible"]),
			"a night in which nothing changed shows no change section at all")


func test_the_timeline_groups_by_type_and_ranks_the_worst_class_first() -> void:
	var model := _model()
	var digest: Array = []
	for i in 9:
		digest.append({"type": "building_completed", "building": i, "level": 2})
	digest.append({"type": "BlockDarkChanged", "block_id": "B2", "block_dark": true})
	# A P2, so the three rows are one of each class and the ranking is what is
	# being measured rather than a tie-break. (`city_level_changed` used to sit
	# here; doc 08's table files a level-up as P3, which made it a tie with the
	# completions and the assertion below meaningless.)
	digest.append({"type": "PowerComponentFailed", "component": "T-04",
			"cause": "overload"})
	var timeline: Dictionary = model.build(_input(3000.0, digest))["timeline"]
	var rows: Array = timeline["rows"]
	assert_eq(rows.size(), 3, "nine completions are one line, not nine")
	assert_eq(str((rows[0] as Dictionary)["class"]), AwayModel.CLASS_P1,
			"the P1 outage is the first thing you read")
	assert_eq((rows[0] as Dictionary)["state"], HudModel.STATE_CRITICAL)
	assert_eq(str((rows[2] as Dictionary)["type"]), "building_completed")
	assert_eq(int((rows[2] as Dictionary)["count"]), 9)
	assert_true(str((rows[2] as Dictionary)["label"]).contains("9"),
			"and the line carries the count: %s" % (rows[2] as Dictionary)["label"])


func test_the_timeline_is_capped_at_the_docs_number() -> void:
	var model := _model()
	var cap := model.max_timeline_entries()
	var digest: Array = []
	for i in cap + 4:
		digest.append({"type": "kind_%d" % i})
	var timeline: Dictionary = model.build(_input(3000.0, digest))["timeline"]
	assert_eq((timeline["rows"] as Array).size(), cap)
	assert_eq(int(timeline["total"]), cap + 4)
	assert_ne(str(timeline["more_text"]), "", "with a `See all (n)` for the rest")


func test_timeline_copy_reuses_the_push_keys_so_the_two_cannot_drift() -> void:
	# G-8: an event the alerts table names resolves the same `n_<id>_title` a push
	# would render, so the report and the notification say one thing.
	var cfg := _cfg()
	var model := AwayModel.new(cfg)
	var timeline: Dictionary = model.build(_input(3000.0, [
		{"type": "BlockDarkChanged", "block_id": "B2", "block_dark": true},
	]))["timeline"]
	var row: Dictionary = (timeline["rows"] as Array)[0]
	assert_eq(str(row["label"]), cfg.t("n_outage_major_title", {"count": 1}))
	assert_false(str(row["label"]).contains("{"), "no hole in the label")


func test_the_toast_replaces_the_modal_below_the_threshold() -> void:
	# §2.12: "Below the threshold with no notable events, a toast (`Away 4m ·
	# +$3.1K`) replaces it."
	var model := _model()
	var view := model.build(_input(60.0))
	assert_false(bool(view["show"]))
	var toast := str(view["toast"])
	assert_true(toast.contains("1:00"), "the toast says how long: %s" % toast)
	assert_true(toast.contains(HudModel.money(2368800)),
			"and what it earned: %s" % toast)
	assert_true(toast.contains(HudModel.PLUS), "with a sign on it")


func test_a_bare_input_still_renders_something_true() -> void:
	# Every key is optional; a resume that only knows how long it was is still a
	# legitimate report.
	var model := _model()
	var view := model.build({"elapsed_wall_s": 600.0})
	assert_true(bool(view["show"]))
	assert_ne(str((view["header"] as Dictionary)["text"]), "")
	assert_false(bool((view["needs_you"] as Dictionary)["visible"]))
	assert_false(bool((view["ledger"] as Dictionary)["visible"]))
	assert_false(bool((view["change"] as Dictionary)["visible"]))


# ===========================================================================
# The mounted sheet
# ===========================================================================

func test_present_opens_the_sheet_or_hands_back_a_toast() -> void:
	var mounted := _mount()
	var sheet: AwayReportSheet = mounted["sheet"]
	assert_ne(sheet, null, "SafeArea/ModalLayer/AwayReport is wired")
	assert_false(sheet.is_open())
	var toast := sheet.present(_input(30.0))
	assert_false(sheet.is_open(), "a 30 s absence is not a modal")
	assert_ne(toast, "", "it is a toast, and present() hands the shell the copy")

	assert_eq(sheet.present(_input(3000.0, [], [_incident_row(4, 4, 47.0)])), "",
			"a real absence opens the sheet and returns no toast")
	assert_true(sheet.is_open())
	_unmount(mounted)


func test_handle_now_dismisses_jumps_and_opens_the_drawer() -> void:
	# §2.12: HANDLE NOW "dismisses the report, jumps the camera, opens the drawer
	# and preselects the incident".
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var sheet: AwayReportSheet = mounted["sheet"]
	var handled: Array[int] = []
	var focused: Array[Vector3] = []
	root.handle_now_requested.connect(func(id: int) -> void: handled.append(id))
	root.focus_requested.connect(func(pos: Vector3) -> void: focused.append(pos))
	root.set_incident_locator(func(_kind: StringName, _id: Variant) -> Variant:
		return Vector3(24.0, 0.0, 48.0))
	root.feed_events([{"type": "incident_created", "incident_id": 4, "severity": 4.2,
			"tier": 4, "at_h": 1.0, "tile": [3, 6], "district_id": "D1"}])
	sheet.present(_input(3000.0, [], [_incident_row(4, 4, 47.0)]))
	assert_true(sheet.is_open())
	assert_ne(sheet.handle_button(4), null)
	sheet.handle_button(4).pressed.emit()
	assert_false(sheet.is_open(), "the report got out of the way first")
	assert_true(root.incident_drawer.is_open(), "and the drawer took over")
	assert_eq(root.incident_drawer.model.selected_id(), 4, "preselected")
	assert_eq(focused, [Vector3(24.0, 0.0, 48.0)] as Array[Vector3], "camera jumped")
	assert_eq(handled, [4] as Array[int])
	_unmount(mounted)


func test_dismiss_is_one_tap_and_tells_the_shell() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var sheet: AwayReportSheet = mounted["sheet"]
	var dismissed: Array[bool] = []
	root.away_dismissed.connect(func() -> void: dismissed.append(true))
	sheet.present(_input(3000.0))
	assert_true(sheet.is_open())
	sheet.dismiss_button().pressed.emit()
	assert_false(sheet.is_open())
	assert_eq(dismissed.size(), 1)
	_unmount(mounted)


func test_the_report_answers_the_back_stack_like_every_other_modal() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var sheet: AwayReportSheet = mounted["sheet"]
	sheet.present(_input(3000.0))
	assert_eq(root.handle_back(0.0), UIRoot.BACK_CLOSE_MODAL,
			"§2.12: always dismissible in one tap, BACK included")
	assert_false(sheet.is_open())
	_unmount(mounted)


func test_the_root_is_the_one_call_the_shell_makes_on_resume() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	assert_eq(root.present_away_report(_input(3000.0)), "")
	assert_true(root.away_report.is_open())
	root.away_report.close()
	assert_ne(root.present_away_report(_input(10.0)), "",
			"a short quiet absence comes back as toast copy instead")
	assert_false(root.away_report.is_open())
	_unmount(mounted)
