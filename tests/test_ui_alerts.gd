extends SimTest
## Doc 12 §2.15 / §4.5 — the alerts centre: ingesting real sim-bus events,
## coalescing them, counting what is unread, resolving copy from the `n_*` keys
## (G-8) and handing the view a focus payload.
##
## The events fed here are the **actual dictionaries** `sim/` emits
## (`BlockDarkChanged`, `PowerComponentFailed`, `credit_line_engaged`,
## `building_completed`, …), so a rename on either side fails this file rather
## than going quietly missing in the feed.


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _model() -> AlertsModel:
	var model := AlertsModel.new(_cfg())
	model.set_clock(372, 2)  # 06:12 on day 3, the §2.3 mock's clock
	return model


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _mount() -> Dictionary:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	_tree().root.add_child(root)
	root.initialize()
	var center := root.get_node_or_null("SafeArea/PanelLayer/AlertsCenter") as AlertsCenter
	return {"root": root, "center": center}


func _unmount(mounted: Dictionary) -> void:
	var root: Node = mounted["root"]
	_tree().root.remove_child(root)
	root.free()


# ===========================================================================
# Ingest
# ===========================================================================

func test_feed_ignores_events_that_are_not_notifiable() -> void:
	var model := _model()
	assert_true(model.feed({"type": &"job_started", "building": 4}).is_empty(),
			"the player is not told about internal bookkeeping")
	assert_true(model.feed({}).is_empty(), "a typeless event is not an alert")
	assert_eq(model.size(), 0)
	assert_eq(model.unread_count(), 0)
	assert_eq(model.badge_text(), "", "an empty feed shows no badge")


func test_block_dark_and_restore_are_two_different_rules_on_one_event() -> void:
	# data/ui.json orders the two BlockDarkChanged rules; the `match` block picks.
	var model := _model()
	var dark := model.feed({"type": &"BlockDarkChanged", "block_id": "B2",
			"block_dark": true, "dark_fraction": 1.0})
	assert_false(dark.is_empty())
	assert_eq(str(dark["notify_id"]), "outage_major")
	assert_eq(str(dark["class"]), "p1")
	assert_eq(dark["state"], HudModel.STATE_CRITICAL)
	assert_true(str(dark["title"]).contains("1"), "the title counts the dark blocks")

	var lit := model.feed({"type": &"BlockDarkChanged", "block_id": "B2",
			"block_dark": false, "powered_fraction": 1.0})
	assert_eq(str(lit["notify_id"]), "power_restored")
	assert_eq(str(lit["class"]), "p2")
	assert_eq(lit["state"], HudModel.STATE_NORMAL)
	assert_eq(model.size(), 2, "restoring power is its own row, not an edit")


func test_repeats_coalesce_while_unread_and_split_once_read() -> void:
	# §2.15's whole reason for a count: three dark blocks are one story, and
	# `{count} blocks are dark` has to be able to say "3".
	var model := _model()
	for block: String in ["B2", "B3", "B4"]:
		model.feed({"type": &"BlockDarkChanged", "block_id": block, "block_dark": true})
	assert_eq(model.size(), 1, "one row for the outage")
	var row: Dictionary = model.entries()[0]
	assert_eq(int(row["count"]), 3)
	assert_true(str(row["title"]).contains("3"), "the title says 3: %s" % row["title"])
	assert_eq(model.unread_count(), 1, "one unread thing to look at, not three")

	model.mark_all_read()
	model.feed({"type": &"BlockDarkChanged", "block_id": "B7", "block_dark": true})
	assert_eq(model.size(), 2, "a repeat after reading starts a new row")
	assert_eq(model.unread_count(), 1)


func test_per_entity_rules_keep_their_own_rows() -> void:
	# A transformer failure names a component, so two of them are two problems.
	var model := _model()
	model.feed({"type": &"PowerComponentFailed", "component": "T-04",
			"cause": "overload"})
	model.feed({"type": &"PowerComponentFailed", "component": "T-09",
			"cause": "overload"})
	assert_eq(model.size(), 2)
	model.feed({"type": &"PowerComponentFailed", "component": "T-04", "cause": "age"})
	assert_eq(model.size(), 2, "the same component coalesces into its own row")
	for entry: Dictionary in model.entries():
		assert_true(str(entry["title"]).contains(str(entry["entity_id"])),
				"the row names the component: %s" % entry["title"])


func test_treasury_events_format_money_the_way_the_hud_does() -> void:
	var model := _model()
	var low := model.feed({"type": &"credit_line_engaged", "balance": -1200000,
			"credit_limit": 5000000})
	assert_false(low.is_empty())
	assert_eq(str(low["class"]), "p1")
	assert_eq(low["state"], HudModel.STATE_WARNING)
	assert_true(str(low["body"]).contains(HudModel.money(-1200000)),
			"the body reads −$1.2M like the chip does: %s" % low["body"])
	var stop := model.feed({"type": &"credit_limit_reached", "balance": -5000000,
			"credit_limit": 5000000})
	assert_eq(stop["state"], HudModel.STATE_CRITICAL)


func test_copy_comes_from_the_string_table_and_never_shows_a_hole() -> void:
	# G-8: every row resolves `n_<notify_id>_title` / `_body`, the same keys doc 13
	# renders for a push. A sentence whose data the sim did not supply is dropped
	# rather than printed with a `{placeholder}` in it.
	var cfg := _cfg()
	var model := AlertsModel.new(cfg)
	model.set_clock(372, 2)
	var events: Array = [
		{"type": &"BlockDarkChanged", "block_id": "B2", "block_dark": true},
		{"type": &"BlockDarkChanged", "block_id": "B2", "block_dark": false},
		{"type": &"PowerComponentFailed", "component": "T-04", "cause": "overload"},
		{"type": &"PowerComponentTripped", "component": "F_SOUTH"},
		{"type": &"LoadShedStarted", "feeders": ["F_SOUTH"], "shed_kw": 420.0},
		{"type": &"credit_line_engaged", "balance": -1200},
		{"type": &"credit_limit_reached", "balance": -5000},
		{"type": &"austerity_entered"},
		{"type": &"city_level_changed", "level": 3},
		{"type": &"building_completed", "building": 12, "level": 2},
		{"type": &"block_ready", "block_id": "E4"},
	]
	var made := model.feed_batch(events)
	assert_eq(made.size(), events.size(), "every listed event is notifiable")
	for entry: Dictionary in model.entries():
		assert_true(cfg.has_string(str(entry["title_key"])),
				"%s exists" % entry["title_key"])
		assert_true(cfg.has_string(str(entry["body_key"])), "%s exists" % entry["body_key"])
		assert_ne(str(entry["title"]), "", "%s renders a title" % entry["notify_id"])
		assert_false(str(entry["title"]).contains("{"),
				"no hole in %s" % entry["title"])
		assert_false(str(entry["body"]).contains("{"), "no hole in %s" % entry["body"])
		assert_ne(str(entry["glyph"]), "", "every row carries a state glyph (A5)")


func test_outage_body_drops_the_sentence_the_sim_cannot_fill() -> void:
	# `n_outage_major_body` mentions responding crews; doc 06 is not in the slice,
	# so that sentence is dropped and the district/time one survives intact.
	var model := _model()
	var entry := model.feed({"type": &"BlockDarkChanged", "block_id": "B2",
			"block_dark": true})
	assert_true(str(entry["body"]).contains("B2"), "the district is named")
	assert_true(str(entry["body"]).contains("06:12"), "the time is the sim clock")
	assert_false(str(entry["body"]).contains("crews"),
			"the unfillable sentence is dropped, not printed with a hole")


func test_unread_count_badge_and_marking() -> void:
	var model := _model()
	for i in 5:
		model.feed({"type": &"PowerComponentFailed", "component": "T-%02d" % i,
				"cause": "overload"})
	assert_eq(model.unread_count(), 5)
	assert_eq(model.badge_text(), "5")
	var newest: Dictionary = model.entries()[0]
	assert_true(model.mark_read(str(newest["id"])))
	assert_false(model.mark_read(str(newest["id"])), "reading twice changes nothing")
	assert_eq(model.unread_count(), 4)
	assert_eq(model.mark_all_read(), 4)
	assert_eq(model.badge_text(), "")


func test_the_feed_is_bounded_so_a_blackout_cannot_grow_it_forever() -> void:
	var cap := UIConfig.get_int(_cfg().section("alerts"), "max_entries", 50)
	var model := _model()
	for i in cap * 2:
		model.feed({"type": &"PowerComponentFailed", "component": "T-%03d" % i,
				"cause": "age"})
	assert_eq(model.size(), cap, "the oldest rows fall off the end")
	assert_eq(model.badge_text(), str(cap))
	# The newest event survived; the first one did not.
	assert_true(str((model.entries()[0] as Dictionary)["entity_id"])
			.contains("%03d" % (cap * 2 - 1)))


func test_badge_caps_so_the_chip_never_outgrows_its_target() -> void:
	# Asserted against a fixture rather than data/ui.json, so the rule holds
	# whatever the shipped cap is set to.
	var model := AlertsModel.new(UIConfig.new({
		"alerts": {
			"max_entries": 20, "unread_badge_max": 3,
			"events": [{"type": "PowerComponentFailed", "notify_id": "component_failed",
					"class": "p1", "state": "critical", "key": "component"}],
		},
		"state_glyphs": {"normal": "circle_filled", "warning": "triangle",
				"critical": "diamond", "offline": "cross"},
	}, {"n_component_failed_title": "It failed"}))
	for i in 3:
		model.feed({"type": &"PowerComponentFailed", "component": "T-%d" % i})
	assert_eq(model.badge_text(), "3", "at the cap it is still just the number")
	model.feed({"type": &"PowerComponentFailed", "component": "T-9"})
	assert_eq(model.badge_text(), "3+", "past it the chip stops growing")


func test_focus_payload_uses_the_injected_locator_and_marks_the_row_read() -> void:
	var model := _model()
	model.set_locator(func(kind: StringName, id: Variant) -> Variant:
		if kind == &"block_id" and str(id) == "B2":
			return Vector3(448.0, 0.0, 512.0)
		return null)
	var dark := model.feed({"type": &"BlockDarkChanged", "block_id": "B2",
			"block_dark": true})
	assert_true(bool(dark["has_focus"]))
	var payload := model.focus_payload(str(dark["id"]))
	assert_true(bool(payload["has_focus"]))
	assert_eq(payload["world_pos"], Vector3(448.0, 0.0, 512.0))
	assert_eq(str(payload["entity_kind"]), "block_id")
	assert_eq(model.unread_count(), 0, "tapping a row is also reading it")

	# An event the locator cannot place simply has no jump affordance.
	var unplaced := model.feed({"type": &"austerity_entered"})
	assert_false(bool(unplaced["has_focus"]))
	assert_false(bool(model.focus_payload(str(unplaced["id"]))["has_focus"]))


func test_an_event_carrying_its_own_position_needs_no_locator() -> void:
	var model := _model()
	var entry := model.feed({"type": &"building_completed", "building": 12,
			"level": 2, "world_pos": Vector3(8.0, 0.0, 16.0)})
	assert_true(bool(entry["has_focus"]))
	assert_eq(entry["world_pos"], Vector3(8.0, 0.0, 16.0))


# ===========================================================================
# AlertsCenter — the Control half, in a live tree
# ===========================================================================

func test_center_chip_carries_the_unread_count_and_the_list_opens() -> void:
	var mounted := _mount()
	var center: AlertsCenter = mounted["center"]
	assert_ne(center, null, "SafeArea/PanelLayer/AlertsCenter is wired")
	assert_false(center.is_open(), "the list starts closed behind the chip")
	center.set_clock(372, 2)
	center.feed({"type": &"PowerComponentFailed", "component": "T-04",
			"cause": "overload"})
	assert_eq(center.unread_count(), 1)
	assert_true(center.chip_button().text.contains("1"), "the chip badges the count")
	center.open()
	assert_true(center.is_open())
	var entries := center.model.entries()
	assert_eq(entries.size(), 1)
	assert_ne(center.row_button(str(entries[0]["id"])), null, "the row is built")
	_unmount(mounted)


func test_row_tap_emits_focus_and_clears_the_badge() -> void:
	var mounted := _mount()
	var center: AlertsCenter = mounted["center"]
	center.set_locator(func(_kind: StringName, _id: Variant) -> Variant:
		return Vector3(64.0, 0.0, 128.0))
	var focused: Array[Vector3] = []
	center.focus_requested.connect(func(pos: Vector3) -> void: focused.append(pos))
	center.feed({"type": &"BlockDarkChanged", "block_id": "B2", "block_dark": true})
	center.open()
	var alert_id := str(center.model.entries()[0]["id"])
	center.row_button(alert_id).pressed.emit()
	assert_eq(focused, [Vector3(64.0, 0.0, 128.0)] as Array[Vector3])
	assert_eq(center.unread_count(), 0)
	assert_eq(center.chip_button().text.strip_edges(), AlertsCenter.CHIP_GLYPH,
			"a read feed drops the badge")
	_unmount(mounted)


func test_the_root_pipes_a_whole_drain_batch_and_re_emits_focus() -> void:
	# This is the integration seam `game/main.gd` uses: one call per tick.
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var center: AlertsCenter = mounted["center"]
	var focused: Array[Vector3] = []
	root.focus_requested.connect(func(pos: Vector3) -> void: focused.append(pos))
	root.set_alert_locator(func(_kind: StringName, _id: Variant) -> Variant:
		return Vector3(1.0, 0.0, 2.0))
	root.set_sim_clock(372, 2)
	root.feed_events([
		{"type": &"BlockDarkChanged", "block_id": "B2", "block_dark": true},
		{"type": &"job_started", "building": 1},
	])
	assert_eq(center.model.size(), 1, "only the notifiable event became a row")
	center.open()
	center.row_button(str(center.model.entries()[0]["id"])).pressed.emit()
	assert_eq(focused, [Vector3(1.0, 0.0, 2.0)] as Array[Vector3],
			"UIRoot re-emits the focus request for the shell")
	_unmount(mounted)


func test_opening_the_alerts_list_closes_the_building_panel() -> void:
	# One panel at a time on PanelLayer, or the two 300 dp panels overlap.
	var mounted := _mount()
	var center: AlertsCenter = mounted["center"]
	var root: UIRoot = mounted["root"]
	var panel := root.get_node_or_null("SafeArea/PanelLayer/BuildingPanel") as BuildingPanel
	assert_ne(panel, null)
	panel.setup(root.config, BuildController.new(CitySim.boot_from_files(),
			RequirementFormatter.new(root.config)))
	panel.show_building("H-001")
	assert_true(panel.is_open())
	center.open()
	assert_false(panel.is_open(), "opening the alerts list put the panel away")
	assert_true(center.is_open())
	# And BACK closes the topmost panel, exactly as §2.2 orders it.
	assert_eq(root.handle_back(0.0), UIRoot.BACK_CLOSE_PANEL)
	assert_false(center.is_open())
	_unmount(mounted)
