extends SimTest
## Doc 12 S13 — the event log: the ledger behind the alerts centre.
##
## What these pin down: one row per event (never coalesced), category filtering,
## relative ages, tap-to-focus, the shared `n_*` copy keys, the ingest seam the
## shell already calls, and §3.2's "nothing here is persisted".


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _model() -> EventLogModel:
	return EventLogModel.new(_cfg())


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _mount() -> Dictionary:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false  # never touch the test runner's window
	_tree().root.add_child(root)
	root.initialize()
	return {"root": root, "log": root.event_log}


func _unmount(mounted: Dictionary) -> void:
	var root: Node = mounted["root"]
	_tree().root.remove_child(root)
	root.free()


static func _dark(block_id: String) -> Dictionary:
	return {"type": "BlockDarkChanged", "block_id": block_id, "block_dark": true}


static func _break(edge_id: String) -> Dictionary:
	return {"type": "water_main_break", "edge": edge_id, "severity": 0.6,
			"damage_fraction": 0.4}


# ===========================================================================
# EventLogModel
# ===========================================================================

func test_the_table_covers_every_category_and_every_row_has_copy() -> void:
	var cfg := _cfg()
	var model := EventLogModel.new(cfg)
	var categories := model.categories()
	assert_true(categories.has(EventLogModel.CATEGORY_ALL), "`all` is a chip")
	for wanted: StringName in [&"power", &"water", &"incidents", &"economy", &"weather"]:
		assert_true(categories.has(wanted), "S13 lists %s" % wanted)
		assert_true(cfg.has_string(EventLogModel.category_label_key(wanted)),
				"%s has copy" % wanted)
	var seen: Dictionary = {}
	var rules: Array = cfg.section("event_log").get("events", [])
	assert_true(rules.size() >= 20, "the log records more than the alert-worthy few")
	for raw: Variant in rules:
		var rule: Dictionary = raw
		var category := StringName(str(rule.get("category", "")))
		assert_true(categories.has(category),
				"%s is filed under a listed category" % rule.get("type", ""))
		seen[category] = true
		var notify_id := str(rule.get("notify_id", ""))
		# G-8: the SAME keys the alerts centre and doc 13's pushes resolve.
		assert_true(cfg.has_string("n_%s_title" % notify_id),
				"n_%s_title exists" % notify_id)
		assert_true(cfg.has_string("n_%s_body" % notify_id),
				"n_%s_body exists" % notify_id)
	for wanted2: StringName in [&"power", &"water", &"incidents", &"economy", &"weather"]:
		assert_true(seen.has(wanted2), "at least one rule files under %s" % wanted2)


func test_repeats_are_separate_lines_not_a_count() -> void:
	# This is the whole difference from the alerts centre: three trips are three
	# lines, because the third one is the interesting one.
	var model := _model()
	model.set_clock(600, 0)
	model.feed(_dark("B1"))
	model.feed(_dark("B1"))
	model.feed(_dark("B1"))
	assert_eq(model.size(), 3)
	var rows := model.entries()
	assert_eq(rows.size(), 3)
	assert_ne(str(rows[0]["id"]), str(rows[1]["id"]), "each line has its own id")
	assert_true(int(rows[0]["seq"]) > int(rows[1]["seq"]), "newest first")


func test_an_unlisted_event_is_not_logged() -> void:
	var model := _model()
	assert_true(model.feed({"type": "vehicle_spawned", "unit": 4}).is_empty())
	assert_true(model.feed({}).is_empty(), "and a typeless dictionary is not a row")
	assert_eq(model.size(), 0)


func test_the_match_clause_splits_one_event_type_in_two() -> void:
	var model := _model()
	model.set_clock(60, 0)
	var dark := model.feed(_dark("B2"))
	var lit := model.feed({"type": "BlockDarkChanged", "block_id": "B2",
			"block_dark": false})
	assert_eq(str(dark["notify_id"]), "outage_major")
	assert_eq(str(lit["notify_id"]), "power_restored")
	assert_eq(dark["state"], HudModel.STATE_CRITICAL)
	assert_eq(lit["state"], HudModel.STATE_NORMAL)


func test_copy_resolves_the_shared_keys_and_never_prints_a_hole() -> void:
	var model := _model()
	model.set_clock(732, 0)
	var row := model.feed(_break("W_MAIN_3"))
	assert_eq(str(row["title_key"]), "n_water_main_break_title")
	assert_ne(str(row["title"]), "", "the row says something")
	assert_true(str(row["body"]).contains("W_MAIN_3"), "and names the main")
	assert_false(str(row["body"]).contains("{"), "no placeholder survives to the screen")
	assert_ne(str(row["glyph"]), "", "A5: the state carries a glyph too")


func test_an_incident_type_id_is_never_shown_raw() -> void:
	var model := _model()
	model.set_clock(500, 0)
	var row := model.feed({"type": "incident_created", "incident_id": 7,
			"incident_type": "structure_fire", "tile": [12, 20], "tier": 4})
	assert_true(str(row["title"]).contains("Structure fire"),
			"@kind: resolves ui_incident_kind_structure_fire")
	assert_false(str(row["title"]).contains("structure_fire"))
	assert_true(str(row["body"]).contains("4"), "and a float tier prints as `4`, not `4.0`")
	assert_false(str(row["body"]).contains("4.0"))


func test_a_number_is_quoted_not_measured() -> void:
	# doc 06's `response_min` carries the solver's full float. "Crews cleared it
	# in 7.93333333333333 minutes" is not a sentence anybody wrote.
	var model := _model()
	model.set_clock(500, 0)
	var row := model.feed({"type": "incident_resolved", "incident_id": 7,
			"incident_type": "transformer_failure", "tier_peak": 2,
			"response_min": 7.93333333333333})
	assert_true(str(row["body"]).contains("7.9"))
	assert_false(str(row["body"]).contains("7.93"))
	var whole := model.feed({"type": "incident_resolved", "incident_id": 8,
			"incident_type": "crime", "tier_peak": 1, "response_min": 12.0})
	assert_true(str(whole["body"]).contains("12 "), "12.0 prints as `12`")
	assert_false(str(whole["body"]).contains("12.0"))


func test_an_enum_from_the_sim_is_looked_up_not_printed() -> void:
	# Doc 07 publishes `HEAVY_RAIN`; the player is told about heavy rain.
	var model := _model()
	model.set_clock(480, 0)
	var row := model.feed({"type": "weather_changed", "weather_state": "HEAVY_RAIN",
			"intensity": 0.8})
	assert_true(str(row["title"]).contains("heavy rain"))
	assert_false(str(row["title"]).contains("HEAVY_RAIN"))
	# A state with no copy yet degrades to the raw value rather than to a hole.
	var unknown := model.feed({"type": "weather_changed", "weather_state": "HAIL"})
	assert_true(str(unknown["title"]).contains("HAIL"))


func test_filter_chips_narrow_the_list_and_count_it() -> void:
	var model := _model()
	model.set_clock(300, 0)
	model.feed(_dark("B1"))
	model.feed(_break("W1"))
	model.feed(_break("W2"))
	assert_eq(model.size(), 3)
	assert_eq(model.visible_count(), 3, "`all` shows everything")

	assert_eq(model.set_filter(&"water"), &"water")
	assert_eq(model.visible_count(), 2)
	for row: Dictionary in model.entries():
		assert_eq(row["category"], &"water")
	assert_eq(model.size(), 3, "the filter hides rows, it does not delete them")

	# Tapping the live chip again goes back to `all` — one chip, both switches.
	assert_eq(model.set_filter(&"water"), EventLogModel.CATEGORY_ALL)
	assert_eq(model.visible_count(), 3)
	assert_eq(model.set_filter(&"nonsense"), EventLogModel.CATEGORY_ALL,
			"an unknown category changes nothing")

	model.set_filter(&"incidents")
	assert_eq(model.visible_count(), 0, "an empty category is honestly empty")
	for chip: Dictionary in model.chips():
		if chip["id"] == &"water":
			assert_eq(int(chip["count"]), 2, "and the chip says how many it holds")
		if chip["id"] == EventLogModel.CATEGORY_ALL:
			assert_eq(int(chip["count"]), 3)


func test_relative_times_read_as_words() -> void:
	var model := _model()
	model.set_clock(600, 3)
	model.feed(_dark("B1"))
	assert_eq(str(model.entries()[0]["age_text"]), model._t("ui_event_log_now", {}))

	model.set_clock(612, 3)                     # 12 game-minutes later
	assert_true(str(model.entries()[0]["age_text"]).contains("12"))
	model.set_clock(780, 3)                     # 3 hours
	assert_true(str(model.entries()[0]["age_text"]).contains("3"))
	model.set_clock(600, 5)                     # 2 days
	assert_true(str(model.entries()[0]["age_text"]).contains("2"))

	# A clock that went backwards (a save loaded under the model) reads as
	# `just now` rather than as a negative age.
	model.set_clock(0, 0)
	assert_eq(str(model.entries()[0]["age_text"]), model._t("ui_event_log_now", {}))


func test_the_cap_drops_the_oldest_line() -> void:
	var model := _model()
	model.set_clock(0, 0)
	var cap := UIConfig.get_int(_cfg().section("event_log"), "max_entries", 200)
	for i in cap + 5:
		model.feed(_dark("B%d" % i))
	assert_eq(model.size(), cap)
	assert_eq(int(model.entries()[0]["seq"]), cap + 5, "the newest line is still there")


func test_focus_needs_a_locator_and_never_offers_a_jump_it_cannot_make() -> void:
	var model := _model()
	model.set_clock(400, 0)
	# No locator: nothing is focusable, and no row pretends otherwise.
	var no_loc := model.feed(_dark("B1"))
	assert_false(bool(no_loc["has_focus"]))
	assert_true(model.focus_payload(str(no_loc["id"]))["has_focus"] == false)

	var seen: Array[StringName] = []
	model.set_locator(func(kind: StringName, id: Variant) -> Variant:
		seen.append(kind)
		if kind == &"block_id":
			return Vector3(64.0, 0.0, 128.0)
		if kind == &"tile":
			# The contract is (&"tile", Vector2i) — doc 06 publishes [x, y].
			var tile: Vector2i = id
			return Vector3(float(tile.x) * 8.0, 0.0, float(tile.y) * 8.0)
		return null)
	var block_row := model.feed(_dark("B2"))
	assert_true(bool(block_row["has_focus"]))
	assert_eq(block_row["world_pos"], Vector3(64.0, 0.0, 128.0))

	var incident := model.feed({"type": "incident_created", "incident_id": 9,
			"incident_type": "crime", "tile": [10, 4], "tier": 2})
	assert_true(bool(incident["has_focus"]), "an [x, y] tile still resolves")
	assert_eq(incident["world_pos"], Vector3(80.0, 0.0, 32.0))
	assert_true(seen.has(&"block_id") and seen.has(&"tile"))

	# A water zone is a fine coalescing key and a useless camera target: it is
	# never handed to the locator at all.
	var water := model.feed(_break("W9"))
	assert_false(bool(water["has_focus"]))
	assert_false(seen.has(&"zone"))


func test_reading_a_row_changes_nothing_about_it() -> void:
	# The alerts centre marks read on tap; history does not get consumed.
	var model := _model()
	model.set_clock(100, 0)
	var row := model.feed(_dark("B1"))
	var before := model.entry(str(row["id"]))
	model.focus_payload(str(row["id"]))
	var after := model.entry(str(row["id"]))
	assert_eq(after["seq"], before["seq"])
	assert_eq(model.size(), 1)
	assert_false(after.has("read"), "a log line has no read state to begin with")


func test_the_log_persists_nothing() -> void:
	# doc 12 §3.2 lists no feed in the `ui` save section. The proof is that the
	# model has no capture/restore at all, and a round trip through the root's
	# ui-state block carries nothing of it.
	var model := _model()
	assert_false(model.has_method("capture_state"))
	assert_false(model.has_method("restore_state"))
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	root.feed_events([_dark("B1"), _break("W1")])
	var state := root.capture_ui_state()
	assert_false(state.has("event_log"))
	assert_false(str(state).contains("W1"))
	_unmount(mounted)


# ===========================================================================
# EventLog — the Control half, in a live tree
# ===========================================================================

func test_the_root_mounts_the_log_and_pipes_one_batch_into_both_feeds() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var log_screen: EventLog = mounted["log"]
	assert_ne(log_screen, null, "SafeArea/PanelLayer/EventLog is wired")
	assert_false(log_screen.is_open(), "the sheet starts down")
	root.set_sim_clock(372, 2)
	root.feed_events([
		_dark("B1"),
		{"type": "PowerComponentFailed", "component": "T-04", "cause": "overload"},
		{"type": "vehicle_spawned", "unit": 3},
	])
	assert_eq(log_screen.count(), 2, "two of the three were loggable")
	assert_eq(root.alerts_center.model.size(), 2, "the same batch fed the alerts centre")
	_unmount(mounted)


func test_the_sheet_lists_rows_and_a_filter_chip_narrows_them() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var log_screen: EventLog = mounted["log"]
	root.set_sim_clock(372, 2)
	root.feed_events([_dark("B1"), _break("W1")])
	log_screen.open()
	assert_true(log_screen.is_open())
	var rows := log_screen.model.entries()
	assert_eq(rows.size(), 2)
	for row: Dictionary in rows:
		assert_ne(log_screen.row_button(str(row["id"])), null,
				"row %s is on screen" % row["id"])
	log_screen.filter_button(&"water").pressed.emit()
	assert_eq(log_screen.model.filter(), &"water")
	assert_eq(log_screen.model.visible_count(), 1)
	assert_true(log_screen.filter_button(&"water").text.contains(EventLog.CHECK_GLYPH),
			"the live chip carries a glyph, not just a fill (A5)")
	_unmount(mounted)


func test_a_row_tap_asks_the_shell_to_move_the_camera() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var log_screen: EventLog = mounted["log"]
	var jumps: Array[Vector3] = []
	root.focus_requested.connect(func(pos: Vector3) -> void: jumps.append(pos))
	root.set_alert_locator(func(kind: StringName, _id: Variant) -> Variant:
		return Vector3(8.0, 0.0, 16.0) if kind == &"block_id" else null)
	root.set_sim_clock(100, 0)
	root.feed_events([_dark("B7")])
	log_screen.open()
	var row_id := str(log_screen.model.entries()[0]["id"])
	log_screen.row_button(row_id).pressed.emit()
	assert_eq(jumps.size(), 1, "the root re-emitted it once")
	assert_eq(jumps[0], Vector3(8.0, 0.0, 16.0))
	_unmount(mounted)


func test_one_panel_at_a_time_and_back_closes_it() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var log_screen: EventLog = mounted["log"]
	root.alerts_center.open()
	log_screen.open()
	assert_false(root.alerts_center.is_open(), "opening the log put the alerts away")
	assert_eq(root.handle_back(0.0), UIRoot.BACK_CLOSE_PANEL,
			"§2.2: BACK closes the topmost panel")
	assert_false(log_screen.is_open())
	_unmount(mounted)


func test_the_deep_link_opens_the_log() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	root._on_deeplink_requested("event_log")
	assert_true((mounted["log"] as EventLog).is_open())
	_unmount(mounted)


func test_every_log_target_clears_the_a3_and_a15_gates() -> void:
	# The doc 12 test-19 tree walk, on a POPULATED log — a row button only
	# exists once there is a row, which is exactly what a static walk misses.
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var log_screen: EventLog = mounted["log"]
	root.set_sim_clock(372, 2)
	root.feed_events([_dark("B1"), _break("W1"),
			{"type": "incident_created", "incident_id": 3, "incident_type": "crime",
					"tile": [4, 4], "tier": 2}])
	log_screen.open()
	var minimum := float(ThemeBuilder.touch_min_dp(root.config, 1.0, false))
	var seen: Array[String] = []
	for node: Node in _walk(log_screen):
		var button := node as Button
		if button == null:
			continue
		seen.append(str(button.name))
		assert_true(button.custom_minimum_size.x >= minimum,
				"%s is %d dp wide, needs %d" % [button.name,
						int(button.custom_minimum_size.x), int(minimum)])
		assert_true(button.custom_minimum_size.y >= minimum,
				"%s is %d dp tall, needs %d" % [button.name,
						int(button.custom_minimum_size.y), int(minimum)])
		assert_true(button.tooltip_text.strip_edges().length() > 0,
				"%s has an A15 name" % button.name)
	for expected: String in ["Chip", "Close", "Filter_all", "Filter_water",
			"Filter_incidents"]:
		assert_true(seen.has(expected), "the walk reached %s" % expected)
	assert_true(seen.size() >= 9, "and it reached the three rows too")
	_unmount(mounted)


func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child: Node in node.get_children():
		out.append_array(_walk(child))
	return out
