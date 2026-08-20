extends SimTest
## Doc 12 §2.6 — the incident drawer (S6) and the unit picker (S7).
##
## The events fed here are the **actual dictionaries** `sim/incidents/` puts on
## the bus, `IncidentSystem._emit()`'s clobbering of `type` included (see
## `test_the_created_event_cannot_name_the_kind`), and the snapshot rows are
## `IncidentSystem.snapshot()`'s exact shape — so a rename on either side fails
## this file rather than going quietly missing in the list.


## Fixtures live on an inner class so the lambdas in the tests below can reach
## them from a static context.
class Fixtures:
	## `incident_created` exactly as it arrives on the bus. Note what is NOT here:
	## doc 06 puts the incident's own type under `type`, and `_emit` overwrites
	## that key with the bus event name, so the kind never survives the trip.
	static func created(id: int, at_h: float, severity: float,
			district: String = "D1", tile := Vector2i(4, 7)) -> Dictionary:
		return {"type": "incident_created", "incident_id": id, "subtype": "",
				"tile": [tile.x, tile.y], "severity": severity,
				"tier": int(floor(severity)), "district_id": district,
				"target_ref": {}, "cause": {}, "at_h": at_h,
				"notification_priority": 2}

	## One `IncidentSystem.snapshot()` row — the array doc 06 wrote for §2.6.
	static func snapshot_row(id: int, type_id: String, severity: float,
			assigned: Array = [], eta_min: float = 30.0, assist: float = 0.0,
			wait_min: float = 12.0) -> Dictionary:
		return {"id": id, "type": type_id, "subtype": "",
				"tier": int(floor(severity)), "severity": severity,
				"status": "QUEUED", "pos": [4, 7], "district_id": "D1",
				"wait_min": wait_min, "assigned": assigned, "assist_ratio": assist,
				"progress": 0.0, "escalation_eta_min": eta_min, "priority": 100.0,
				"pinned": false, "seen": false, "unreachable": false,
				"notification_priority": 2}


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _model() -> IncidentModel:
	var model := IncidentModel.new(_cfg())
	model.set_now_h(10.0)
	return model


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _mount() -> Dictionary:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	_tree().root.add_child(root)
	root.initialize()
	return {"root": root, "drawer": root.incident_drawer, "picker": root.unit_picker}


func _unmount(mounted: Dictionary) -> void:
	var root: Node = mounted["root"]
	_tree().root.remove_child(root)
	root.free()


# ===========================================================================
# IncidentModel — ingest
# ===========================================================================

func test_only_doc06_events_reach_the_drawer() -> void:
	var model := _model()
	assert_true(model.feed({"type": "job_started", "building": 4}).is_empty(),
			"the drawer is a list of incidents, not a log")
	assert_true(model.feed({}).is_empty(), "a typeless event is not an incident")
	assert_true(model.feed({"type": "incident_created"}).is_empty(),
			"an event with no incident_id cannot address a row")
	assert_eq(model.size(), 0)


func test_created_builds_a_row_the_view_can_draw() -> void:
	var model := _model()
	var row := model.feed(Fixtures.created(7, 9.5, 3.4))
	assert_false(row.is_empty())
	assert_eq(int(row["id"]), 7)
	assert_eq(int(row["tier"]), 3)
	assert_eq(str(row["district"]), "D1")
	assert_eq(row["tile"], Vector2i(4, 7))
	assert_ne(str(row["tier_pips"]), "", "A5: the tier badge carries a glyph too")
	assert_eq(row["state"], HudModel.STATE_WARNING, "T3 is WARNING, like the chip")
	assert_almost_eq(float(row["escalation01"]), 0.4, 0.0001,
			"§2.6: fill = severity − tier")
	assert_almost_eq(float(row["age_min"]), 30.0, 0.0001, "10.0 h − 9.5 h")
	assert_true(str(row["subtitle"]).contains("D1"), "the row says where")


func test_the_created_event_cannot_name_the_kind() -> void:
	# HISTORY: `IncidentSystem._emit()` stamps `event["type"] = "incident_created"`
	# over the payload's own `type`, which is where doc 06 used to put the incident
	# kind — so the kind never reached the bus and the row fell back to the generic
	# label until the next `refresh()`. Doc 92 pass-2 ruling 8 renamed the field to
	# `incident_type`; the fallback path below still has to work, because a payload
	# that names no kind (an old fixture, a scripted spawn) must not crash the row.
	var model := _model()
	var row := model.feed(Fixtures.created(7, 9.0, 3.4))
	assert_eq(str(row["kind"]), "", "a payload with no `incident_type` names nothing")
	assert_eq(str(row["title"]), UIWidgets.t(_cfg(), "ui_incident_kind_unknown"))
	model.refresh([Fixtures.snapshot_row(7, "transformer_failure", 3.4)])
	assert_eq(str(model.row(7)["kind"]), "transformer_failure")
	assert_eq(str(model.row(7)["title"]),
			UIWidgets.t(_cfg(), "ui_incident_kind_transformer_failure"))
	assert_ne(str(model.row(7)["glyph"]), "", "and now it has its own glyph")
	# And the shipped sim path: doc 06 names the kind, the row reads it live.
	var patched := _model()
	var named := patched.feed({"type": "incident_created", "incident_id": 8,
			"incident_type": "crime", "severity": 2.0, "tier": 2, "at_h": 9.0,
			"tile": [1, 1], "district_id": "D2"})
	assert_eq(str(named["title"]), UIWidgets.t(_cfg(), "ui_incident_kind_crime"))


func test_tier_change_and_assignment_edit_the_row_in_place() -> void:
	var model := _model()
	model.feed(Fixtures.created(7, 9.0, 2.2))
	model.feed({"type": "incident_tier_changed", "incident_id": 7, "tier": 4,
			"severity": 4.1, "at_h": 9.6, "notification_priority": 1})
	var row := model.row(7)
	assert_eq(int(row["tier"]), 4)
	assert_eq(row["state"], HudModel.STATE_CRITICAL, "T4+ is CRITICAL")
	assert_eq(model.size(), 1, "escalating is an edit, never a second row")

	model.feed({"type": "incident_assigned", "incident_id": 7, "unit_id": 3,
			"role": "suppression", "eta_h": 9.7, "manual": true})
	model.feed({"type": "unit_dispatched", "unit_id": 3, "unit_type": "engine",
			"incident_id": 7, "role": "suppression", "eta_h": 0.1, "manual": true})
	assert_eq(int(model.row(7)["assigned_count"]), 1,
			"the assign and the dispatch are one unit, not two")
	model.feed({"type": "unit_arrived", "unit_id": 3, "incident_id": 7,
			"role": "suppression"})
	assert_eq(int(model.row(7)["on_scene"]), 1)
	model.feed({"type": "unit_returned", "unit_id": 3, "refit": false})
	assert_eq(int(model.row(7)["assigned_count"]), 0, "a returned unit leaves the row")


func test_terminal_events_retire_the_row() -> void:
	var model := _model()
	for id in [1, 2, 3]:
		model.feed(Fixtures.created(id, 9.0, 1.5))
	assert_eq(model.size(), 3)
	model.feed({"type": "incident_resolved", "incident_id": 1, "tier_peak": 2,
			"at_h": 10.0, "response_min": 6.0, "reward": 100, "target_ref": {}})
	model.feed({"type": "incident_failed", "incident_id": 2, "tier_peak": 3,
			"target_ref": {}})
	model.feed({"type": "incident_abandoned", "incident_id": 3, "tier_peak": 1})
	assert_eq(model.size(), 0, "resolved, failed and abandoned all leave the list")


func test_snapshot_merges_the_clock_no_event_carries() -> void:
	# Doc 06 recomputes the escalation countdown continuously rather than
	# announcing it, so `snapshot()` is the only place it comes from.
	var model := _model()
	model.feed(Fixtures.created(7, 9.0, 3.4))
	assert_eq(float(model.row(7)["eta_min"]), -1.0, "no clock from events alone")
	assert_false(bool(model.row(7)["has_clock"]))
	assert_false(bool(model.row(7)["held"]),
			"a row nobody has measured is not a row that is under control")
	assert_eq(str(model.row(7)["escalation_text"]), "",
			"and it says nothing rather than printing T4 in 0:00")
	assert_eq(model.row(7)["state"], HudModel.STATE_WARNING,
			"it keeps its tier's colour")

	model.refresh([Fixtures.snapshot_row(7, "structure_fire", 3.4, [], 42.0)])
	var row := model.row(7)
	assert_almost_eq(float(row["eta_min"]), 42.0, 0.0001)
	assert_true(bool(row["has_clock"]))
	assert_false(bool(row["held"]))
	assert_true(str(row["escalation_text"]).contains("T4"),
			"the label names the tier it is heading for: %s" % row["escalation_text"])


func test_snapshot_adopts_and_retires_so_a_loaded_save_is_correct() -> void:
	# A save loaded mid-incident replays no events at all; the drawer must still
	# be right on the first refresh.
	var model := _model()
	model.refresh([
		Fixtures.snapshot_row(11, "crime", 2.0),
		Fixtures.snapshot_row(12, "water_main_break", 4.2),
	])
	assert_eq(model.size(), 2, "rows the events never created are adopted")
	assert_eq(int(model.row(12)["tier"]), 4)
	assert_eq(str(model.row(12)["title"]),
			UIWidgets.t(_cfg(), "ui_incident_kind_water_main_break"))
	model.refresh([Fixtures.snapshot_row(11, "crime", 2.0)])
	assert_eq(model.size(), 1, "a row the sim no longer lists is terminal")
	assert_false(model.has(12))


func test_assist_ratio_freezes_the_bar_and_says_held() -> void:
	# §2.6: "When assist_ratio ≥ 1 … the bar freezes, turns NORMAL green … and
	# the label reads HELD."
	var model := _model()
	model.refresh([Fixtures.snapshot_row(5, "structure_fire", 4.6, [1, 2], -1.0, 1.0)])
	var row := model.row(5)
	assert_true(bool(row["held"]))
	assert_eq(row["escalation_state"], HudModel.STATE_NORMAL,
			"a held bar is green whatever the tier")
	assert_eq(row["state"], HudModel.STATE_NORMAL,
			"and so is the row: enough units are on scene")
	assert_eq(str(row["escalation_text"]), UIWidgets.t(_cfg(), "ui_drawer_held"))


func test_escalation_state_goes_critical_in_the_last_quarter_tier() -> void:
	var model := _model()
	var margin := UIConfig.get_num(_cfg().section("thresholds"),
			"escalation_bar_critical_remaining_tiers", 0.25)
	assert_eq(model.escalation_state(1.0 - margin * 0.5, false),
			HudModel.STATE_CRITICAL, "inside the margin the bar is CRITICAL")
	assert_eq(model.escalation_state(0.1, false), HudModel.STATE_WARNING)
	assert_eq(model.escalation_state(0.99, true), HudModel.STATE_NORMAL,
			"HELD wins over the margin")
	assert_almost_eq(IncidentModel.escalation_fill(3.4, 3), 0.4, 0.0001)
	assert_almost_eq(IncidentModel.escalation_fill(5.0, 5), 0.0, 0.0001)


# ===========================================================================
# IncidentModel — the four sort orders (§2.6)
# ===========================================================================

func test_priority_sort_is_the_docs_comparator() -> void:
	#     key(i) = (-tier, t_next_tier_h (INF when HELD), -waiting_s, id)
	#     unassigned incidents sort before assigned ones of equal tier
	var model := _model()
	model.refresh([
		Fixtures.snapshot_row(1, "crime", 2.0, [], 60.0),
		Fixtures.snapshot_row(2, "structure_fire", 5.0, [9], 10.0),
		Fixtures.snapshot_row(3, "structure_fire", 5.0, [], 90.0),
		Fixtures.snapshot_row(4, "transformer_failure", 3.0, [], 5.0),
	])
	var ids: Array[int] = []
	for row: Dictionary in model.rows(IncidentModel.SORT_PRIORITY):
		ids.append(int(row["id"]))
	assert_eq(ids, [3, 2, 4, 1] as Array[int],
			"T5 unassigned, then T5 assigned, then T3, then T2: %s" % str(ids))


func test_nearest_newest_and_unassigned_each_reorder_the_same_rows() -> void:
	var model := _model()
	model.set_locator(func(kind: StringName, id: Variant) -> Variant:
		if kind != &"tile":
			return null
		var tile: Vector2i = id
		return Vector3(float(tile.x) * 8.0, 0.0, float(tile.y) * 8.0))
	model.feed(Fixtures.created(1, 1.0, 4.0, "D1", Vector2i(100, 0)))
	model.feed(Fixtures.created(2, 5.0, 4.0, "D1", Vector2i(2, 0)))
	model.feed(Fixtures.created(3, 3.0, 4.0, "D1", Vector2i(50, 0)))
	model.feed({"type": "incident_assigned", "incident_id": 2, "unit_id": 1,
			"role": "police", "eta_h": 5.1, "manual": false})
	model.set_reference(Vector3.ZERO)

	var order: Array[int] = []
	for row: Dictionary in model.rows(IncidentModel.SORT_NEAREST):
		order.append(int(row["id"]))
	assert_eq(order, [2, 3, 1] as Array[int], "nearest the camera first")

	order = []
	for row: Dictionary in model.rows(IncidentModel.SORT_NEWEST):
		order.append(int(row["id"]))
	assert_eq(order, [2, 3, 1] as Array[int], "most recently created first")

	order = []
	for row: Dictionary in model.rows(IncidentModel.SORT_UNASSIGNED):
		order.append(int(row["id"]))
	assert_eq(order[order.size() - 1], 2, "the one with a unit on it sorts last")


func test_the_handle_says_how_bad_it_is_and_pulses_when_it_should() -> void:
	# §2.6: "showing total count, worst-tier colour fill, worst-tier digit …
	# Pulses at 1.2 Hz while any T4/T5 incident is unassigned."
	var model := _model()
	assert_eq(model.handle_view()["state"], HudModel.STATE_OFFLINE,
			"an empty drawer reads OFFLINE, not NORMAL")
	model.refresh([
		Fixtures.snapshot_row(1, "crime", 2.0, [7]),
		Fixtures.snapshot_row(2, "structure_fire", 4.5, []),
	])
	var view := model.handle_view()
	assert_eq(int(view["count"]), 2)
	assert_eq(int(view["worst_tier"]), 4)
	assert_eq(str(view["digit"]), "4")
	assert_eq(view["state"], HudModel.STATE_CRITICAL)
	assert_true(bool(view["pulse"]), "a T4 with nobody on it pulses")
	model.refresh([
		Fixtures.snapshot_row(1, "crime", 2.0, [7]),
		Fixtures.snapshot_row(2, "structure_fire", 4.5, [8]),
	])
	assert_false(bool(model.handle_view()["pulse"]), "assigning it stops the pulse")
	assert_eq(model.hud_incidents(), {"count": 2, "worst_tier": 4},
			"the chip and the drawer are one number")


func test_markers_come_off_the_same_rows_the_list_does() -> void:
	var model := _model()
	model.set_locator(func(_kind: StringName, _id: Variant) -> Variant:
		return Vector3(8.0, 0.0, 16.0))
	model.feed(Fixtures.created(1, 1.0, 4.0))
	var markers := model.markers()
	assert_eq(markers.size(), 1)
	assert_eq(markers[0]["position"], Vector3(8.0, 0.0, 16.0))
	assert_eq(int(markers[0]["tier"]), 4)
	# And they are exactly what HudModel.cluster_markers eats.
	var hud := HudModel.new(_cfg())
	assert_eq(hud.cluster_markers([{"id": "1", "position": Vector2(10.0, 10.0),
			"tier": 4}]).size(), 1)


func test_the_list_is_bounded_and_drops_the_least_bad_first() -> void:
	var cap := UIConfig.get_int(_cfg().section("incident_drawer"), "max_rows", 40)
	var model := _model()
	model.feed(Fixtures.created(1, 1.0, 5.0))
	for i in range(2, cap + 6):
		model.feed(Fixtures.created(i, 1.0, 1.2))
	assert_eq(model.size(), cap)
	assert_true(model.has(1), "the T5 survives; the T1s are what fall off")


# ===========================================================================
# UnitPickerModel — the §2.6 rank key
# ===========================================================================

func test_rank_is_eligibility_then_status_then_eta_then_id() -> void:
	#     (not eligible, status_rank, eta_seconds, id)
	#     status_rank = 0 Available, 1 Returning, 2 Reassignable-busy
	var model := UnitPickerModel.new(_cfg())
	var ranked := model.rank([
		{"id": 5, "dept": "fire", "kind": "engine", "eta_gs": 40.0, "state": "ON_SCENE"},
		{"id": 6, "dept": "fire", "kind": "engine", "eta_gs": 200.0, "state": "IDLE"},
		{"id": 7, "dept": "fire", "kind": "ladder", "eta_gs": 30.0, "state": "REFIT"},
		{"id": 8, "dept": "fire", "kind": "engine", "eta_gs": 90.0, "state": "RETURNING"},
		{"id": 9, "dept": "fire", "kind": "engine", "eta_gs": 200.0, "state": "IDLE"},
	])
	var ids: Array[int] = []
	for row: Dictionary in ranked:
		ids.append(int(row["id"]))
	assert_eq(ids, [6, 9, 8, 5, 7] as Array[int],
			"available (id tiebreak), returning, busy, then the refitting one: %s"
			% str(ids))
	assert_eq(ranked[0]["tag"], UnitPickerModel.TAG_REQUIRED)
	assert_eq(ranked[4]["tag"], UnitPickerModel.TAG_INELIGIBLE,
			"REFIT is not dispatchable, so it is WRONG TYPE and sorts last")
	assert_eq(ranked[4]["state_token"], HudModel.STATE_OFFLINE)
	assert_eq(ranked[0]["state_token"], HudModel.STATE_NORMAL)
	assert_eq(ranked[3]["state_token"], HudModel.STATE_WARNING,
			"busy-but-reassignable is WARNING, not OFFLINE")


func test_the_state_names_are_doc06s_vehicle_statuses() -> void:
	# A rename in sim/incidents/vehicle.gd has to break something.
	for state: String in [Vehicle.IDLE, Vehicle.RESPONDING, Vehicle.ON_SCENE,
			Vehicle.RETURNING, Vehicle.REFIT, Vehicle.OFFLINE]:
		assert_true(UnitPickerModel.STATE_RANKS.has(state),
				"the picker knows Vehicle.%s" % state)
		assert_true(_cfg().has_string("ui_picker_state_%s" % state.to_lower()),
				"and has copy for it (G-8)")
	for state: String in [Vehicle.IDLE, Vehicle.RESPONDING, Vehicle.ON_SCENE,
			Vehicle.RETURNING]:
		assert_true(UnitPickerModel.DISPATCHABLE_STATES.has(state),
				"Vehicle.is_dispatchable_now() agrees about %s" % state)
	assert_false(UnitPickerModel.DISPATCHABLE_STATES.has(Vehicle.REFIT))
	assert_false(UnitPickerModel.DISPATCHABLE_STATES.has(Vehicle.OFFLINE))


func test_an_unroutable_unit_sorts_behind_every_routable_one() -> void:
	var model := UnitPickerModel.new(_cfg())
	var ranked := model.rank([
		{"id": 1, "dept": "utility", "kind": "utility_truck", "eta_gs": -1.0,
				"state": "IDLE"},
		{"id": 2, "dept": "utility", "kind": "utility_truck", "eta_gs": 600.0,
				"state": "IDLE"},
	])
	assert_eq(int(ranked[0]["id"]), 2, "a negative ETA is unknown, not instant")
	assert_eq(str(ranked[0]["eta_text"]),
			UIWidgets.t_args(_cfg(), "ui_picker_eta", {"eta": HudModel.eta(600)}))
	assert_eq(str(ranked[1]["eta_text"]), UIWidgets.t(_cfg(), "ui_picker_eta_unknown"))


func test_optional_units_keep_their_place_but_say_so() -> void:
	var model := UnitPickerModel.new(_cfg())
	var ranked := model.rank([
		{"id": 1, "dept": "construction", "kind": "construction_crew", "eta_gs": 60.0,
				"state": "IDLE", "required": false},
		{"id": 2, "dept": "utility", "kind": "utility_truck", "eta_gs": 120.0,
				"state": "IDLE"},
	])
	assert_eq(int(ranked[0]["id"]), 1, "ETA ranks, not the tag")
	assert_eq(ranked[0]["tag"], UnitPickerModel.TAG_OPTIONAL)
	assert_true(bool(ranked[0]["eligible"]), "OPTIONAL can still be sent")


func test_the_provider_is_the_only_seam_and_auto_takes_the_top_of_it() -> void:
	var model := UnitPickerModel.new(_cfg())
	assert_false(model.has_provider())
	assert_true(model.open_for({"id": 4, "title": "Fire", "tier": 3}).is_empty(),
			"no provider means no roster, not a crash")
	assert_ne(str(model.empty_card().get("text", "")), "",
			"A14: an empty sheet still says why")

	var asked: Array[int] = []
	model.set_provider(func(incident_id: int) -> Array:
		asked.append(incident_id)
		return [
			{"id": 2, "dept": "fire", "kind": "engine", "eta_gs": 300.0, "state": "IDLE"},
			{"id": 1, "dept": "fire", "kind": "engine", "eta_gs": 48.0, "state": "IDLE"},
		])
	var rows := model.open_for({"id": 4, "title": "Structure fire", "tier": 3})
	assert_eq(asked, [4] as Array[int], "the provider is asked for one incident")
	assert_eq(rows.size(), 2)
	assert_eq(int(model.auto_pick()["id"]), 1, "AUTO is the soonest eligible unit")
	assert_eq(model.incident_id(), 4)
	assert_true(model.empty_card().is_empty(), "there is a unit, so there is no card")
	assert_true(model.dispatched_text(1).contains("0:48"),
			"the toast names the ETA: %s" % model.dispatched_text(1))
	assert_true(model.header_text().contains("Structure fire"),
			"the header names the incident: %s" % model.header_text())


func test_all_units_busy_names_the_soonest_one_free() -> void:
	# §2.6 step 5's state card, minus the queue (doc 06 has no queue command).
	var model := UnitPickerModel.new(_cfg())
	model.set_provider(func(_incident_id: int) -> Array:
		return [{"id": 1, "dept": "fire", "kind": "engine", "eta_gs": -1.0,
				"state": "REFIT", "frees_in_gs": 100.0}])
	model.open_for({"id": 4, "title": "Fire", "tier": 4})
	var card := model.empty_card()
	assert_false(card.is_empty())
	assert_almost_eq(float(card["soonest_gs"]), 100.0, 0.0001)
	assert_true(str(card["text"]).contains("1:40"),
			"the card says when: %s" % card["text"])
	assert_true(model.auto_pick().is_empty(), "and AUTO has nothing to send")


# ===========================================================================
# The mounted screens
# ===========================================================================

func test_the_drawer_mounts_closed_behind_a_handle_that_counts() -> void:
	var mounted := _mount()
	var drawer: IncidentDrawer = mounted["drawer"]
	assert_ne(drawer, null, "SafeArea/PanelLayer/IncidentDrawer is wired")
	assert_false(drawer.is_open(), "the list starts closed behind the handle")
	drawer.set_now_h(10.0)
	drawer.feed(Fixtures.created(7, 9.5, 3.4))
	assert_true(drawer.handle_button().text.contains("1"), "the handle counts")
	assert_true(drawer.handle_button().text.contains("T3"), "and names the worst tier")
	drawer.open()
	assert_true(drawer.is_open())
	assert_ne(drawer.row_button(7), null, "the row is built")
	_unmount(mounted)


func test_a_row_tap_focuses_selects_and_expands_to_the_actions() -> void:
	var mounted := _mount()
	var drawer: IncidentDrawer = mounted["drawer"]
	var focused: Array[Vector3] = []
	drawer.focus_requested.connect(func(pos: Vector3) -> void: focused.append(pos))
	drawer.set_locator(func(_kind: StringName, _id: Variant) -> Variant:
		return Vector3(32.0, 0.0, 56.0))
	drawer.set_now_h(10.0)
	drawer.feed(Fixtures.created(7, 9.0, 4.2))
	drawer.open()
	assert_eq(drawer.expanded_id(), 0, "rows start collapsed")
	drawer.row_button(7).pressed.emit()
	assert_eq(focused, [Vector3(32.0, 0.0, 56.0)] as Array[Vector3],
			"§2.6: the row tap jumps the camera")
	assert_eq(drawer.expanded_id(), 7, "and expands the row to its actions")
	assert_eq(drawer.model.selected_id(), 7, "and selects the incident")
	assert_ne(drawer.action_button("Assign", 7), null)
	assert_ne(drawer.action_button("Ack", 7), null)
	assert_ne(drawer.action_button("Pin", 7), null)
	drawer.row_button(7).pressed.emit()
	assert_eq(drawer.expanded_id(), 0, "tapping it again folds it back")
	_unmount(mounted)


func test_the_three_actions_emit_intents_and_never_touch_the_sim() -> void:
	var mounted := _mount()
	var drawer: IncidentDrawer = mounted["drawer"]
	var assigned: Array[int] = []
	var acked: Array[int] = []
	var pinned: Array = []
	drawer.dispatch_requested.connect(func(id: int) -> void: assigned.append(id))
	drawer.acknowledge_requested.connect(func(id: int) -> void: acked.append(id))
	drawer.pin_requested.connect(func(id: int, value: bool) -> void:
		pinned.append([id, value]))
	drawer.set_now_h(10.0)
	drawer.feed(Fixtures.created(7, 9.0, 2.0))
	drawer.open()
	drawer.row_button(7).pressed.emit()
	drawer.action_button("Assign", 7).pressed.emit()
	drawer.action_button("Ack", 7).pressed.emit()
	assert_eq(assigned, [7] as Array[int])
	assert_eq(acked, [7] as Array[int])
	assert_true(bool(drawer.model.row(7)["acknowledged"]),
			"the flag flips optimistically so the row does not lag the tap")
	drawer.row_button(7).pressed.emit()
	drawer.action_button("Pin", 7).pressed.emit()
	assert_eq(pinned, [[7, true]], "PIN asks for the opposite of what it is now")
	# And the sim's word overwrites the optimistic flag on the next refresh.
	drawer.refresh_from([Fixtures.snapshot_row(7, "crime", 2.0)])
	assert_false(bool(drawer.model.row(7)["pinned"]),
			"the sim refused, so the row goes back")
	_unmount(mounted)


func test_the_sort_control_reorders_the_live_list() -> void:
	var mounted := _mount()
	var drawer: IncidentDrawer = mounted["drawer"]
	drawer.set_now_h(10.0)
	drawer.feed(Fixtures.created(1, 1.0, 4.0))
	drawer.feed(Fixtures.created(2, 5.0, 4.0))
	drawer.open()
	assert_eq(drawer.model.sort_order(), IncidentModel.SORT_PRIORITY)
	drawer.sort_button(IncidentModel.SORT_NEWEST).pressed.emit()
	assert_eq(drawer.model.sort_order(), IncidentModel.SORT_NEWEST)
	assert_eq(int((drawer.model.rows()[0] as Dictionary)["id"]), 2)
	_unmount(mounted)


func test_assign_raises_the_picker_and_a_pick_reaches_the_shell() -> void:
	# The whole two-tap flow §2.6 calls blocking for the slice, through the root.
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var drawer: IncidentDrawer = mounted["drawer"]
	var picker: UnitPickerSheet = mounted["picker"]
	assert_ne(picker, null, "SafeArea/SheetLayer/UnitPicker is wired")
	var dispatched: Array = []
	root.dispatch_requested.connect(func(unit_id: int, incident_id: int) -> void:
		dispatched.append([unit_id, incident_id]))
	root.set_unit_provider(func(_incident_id: int) -> Array:
		return [
			{"id": 9, "dept": "utility", "kind": "utility_truck", "eta_gs": 600.0,
					"state": "IDLE"},
			{"id": 4, "dept": "utility", "kind": "utility_truck", "eta_gs": 48.0,
					"state": "IDLE"},
		])
	drawer.set_now_h(10.0)
	drawer.feed(Fixtures.created(7, 9.0, 3.4))
	drawer.open()
	drawer.row_button(7).pressed.emit()          # tap 1: the row
	assert_false(picker.is_open())
	drawer.action_button("Assign", 7).pressed.emit()
	assert_true(picker.is_open(), "ASSIGN raises the picker over the drawer")
	assert_true(drawer.is_open(), "and the drawer stays open behind it")
	assert_eq(picker.incident_id(), 7)
	picker.auto_button().pressed.emit()          # tap 2: AUTO
	assert_eq(dispatched, [[4, 7]], "AUTO sent the soonest unit")
	assert_eq(root.report_dispatch_result(4, true),
			picker.model.dispatched_text(4), "the shell's verdict makes the toast")
	assert_false(picker.is_open(), "a successful dispatch closes the sheet")
	_unmount(mounted)


func test_a_refused_dispatch_keeps_the_sheet_up_and_says_so() -> void:
	var mounted := _mount()
	var picker: UnitPickerSheet = mounted["picker"]
	picker.set_provider(func(_incident_id: int) -> Array:
		return [{"id": 4, "dept": "fire", "kind": "engine", "eta_gs": 48.0,
				"state": "IDLE"}])
	picker.open_for({"id": 7, "title": "Structure fire", "tier": 4})
	assert_ne(picker.unit_button(4), null)
	picker.report_result(4, false)
	assert_true(picker.is_open(), "the player must be able to pick something else")
	assert_eq(picker.message_text(), UIWidgets.t(_cfg(), "ui_picker_failed"))
	_unmount(mounted)


func test_an_ineligible_row_is_shown_and_disabled_rather_than_hidden() -> void:
	var mounted := _mount()
	var picker: UnitPickerSheet = mounted["picker"]
	picker.set_provider(func(_incident_id: int) -> Array:
		return [{"id": 4, "dept": "fire", "kind": "engine", "eta_gs": -1.0,
				"state": "OFFLINE"}])
	picker.open_for({"id": 7, "title": "Structure fire", "tier": 4})
	var button := picker.unit_button(4)
	assert_ne(button, null, "the player learns the unit exists")
	assert_true(button.disabled, "and that it cannot go")
	assert_true(picker.auto_button().disabled, "AUTO has nothing to send")
	_unmount(mounted)


func test_opening_the_drawer_puts_the_other_right_hand_panels_away() -> void:
	# One 300 dp surface on the right at a time, or the two overlap.
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var drawer: IncidentDrawer = mounted["drawer"]
	root.alerts_center.set_clock(372, 2)
	root.alerts_center.feed({"type": &"PowerComponentFailed", "component": "T-04",
			"cause": "overload"})
	root.alerts_center.open()
	assert_true(root.alerts_center.is_open())
	drawer.open()
	assert_false(root.alerts_center.is_open(), "opening the drawer closed the feed")
	assert_eq(root.handle_back(0.0), UIRoot.BACK_CLOSE_PANEL,
			"§2.2: BACK closes the topmost panel")
	assert_false(drawer.is_open())
	_unmount(mounted)


## The doc 12 test-19 tree walk, extended to the Wave-2 screens with their lists
## **populated** — a target that only exists once there is a row in it is exactly
## the target a static walk misses.
func test_every_wave2_target_clears_the_a3_and_a15_gates() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var drawer: IncidentDrawer = mounted["drawer"]
	var picker: UnitPickerSheet = mounted["picker"]
	drawer.set_now_h(10.0)
	drawer.feed(Fixtures.created(7, 9.0, 4.2))
	drawer.feed(Fixtures.created(8, 9.2, 2.0))
	drawer.open()
	drawer.row_button(7).pressed.emit()          # expand the actions
	picker.set_provider(func(_incident_id: int) -> Array:
		return [
			{"id": 4, "dept": "fire", "kind": "engine", "eta_gs": 48.0, "state": "IDLE"},
			{"id": 5, "dept": "fire", "kind": "ladder", "eta_gs": -1.0,
					"state": "OFFLINE"},
		])
	picker.open_for(drawer.model.row(7))
	root.city_dashboard.refresh({"population": 1000, "treasury": 5000,
			"net_per_hour": 10.0, "stability": 0.6, "happiness": 0.6,
			"power01": 0.9, "water01": 0.9, "incidents": 1})
	root.city_dashboard.open(DashboardModel.TAB_ECONOMY)
	root.away_report.present({"elapsed_wall_s": 3000.0,
			"before": {"treasury": 1, "population": 1, "day_index": 0},
			"after": {"treasury": 2, "population": 2, "day_index": 1},
			"unresolved": [{"id": 7, "tier": 4, "title": "Fire", "subtitle": "D1"}]})

	var minimum := float(ThemeBuilder.touch_min_dp(root.config, 1.0, false))
	var seen: Array[String] = []
	for node: Node in _walk(root):
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
	for expected: String in ["Handle", "Sort_priority", "Sort_unassigned", "Row_7",
			"Assign_7", "Ack_7", "Pin_7", "Unit_4", "Unit_5", "Tab_overview",
			"Tab_economy", "TaxUp", "TaxDown", "TaxApply", "Dismiss", "Handle_7"]:
		assert_true(seen.has(expected), "the walk reached %s" % expected)
	_unmount(mounted)


func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child: Node in node.get_children():
		out.append_array(_walk(child))
	return out


func test_the_root_pipes_one_batch_and_one_snapshot_into_both_feeds() -> void:
	# This is the seam `game/main.gd` uses: one call per tick, one per refresh.
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var drawer: IncidentDrawer = mounted["drawer"]
	root.set_sim_clock(372, 2)
	root.feed_events([
		Fixtures.created(7, 9.0, 3.4),
		{"type": &"BlockDarkChanged", "block_id": "B2", "block_dark": true},
	])
	assert_eq(drawer.count(), 1, "the incident reached the drawer")
	# Two rows, not one: doc 08's table wires `incident_created` as well as the
	# outage, so the drawer and the feed now tell the player about the SAME
	# incident from their two angles — a live job to dispatch, and a line in the
	# history. Under the deleted stand-in the fire never reached the feed at all.
	assert_eq(root.alerts_center.model.size(), 2,
			"the outage AND the incident reached the feed")
	var notify_ids: PackedStringArray = []
	for row: Dictionary in root.alerts_center.model.entries():
		notify_ids.append(str(row["notify_id"]))
	notify_ids.sort()
	assert_eq(notify_ids, PackedStringArray(["incident_started", "outage_major"]))
	root.refresh_incidents([Fixtures.snapshot_row(7, "structure_fire", 3.4, [], 18.0)],
			10.0)
	assert_almost_eq(float(drawer.model.row(7)["eta_min"]), 18.0, 0.0001)
	_unmount(mounted)


# ===========================================================================
# Doc 05 §2.12's valve — the fourth action, on the one row that has a main
# ===========================================================================

func test_a_row_carries_the_target_the_sim_named() -> void:
	var model := _model()
	var created := Fixtures.created(9, 9.0, 2.4)
	created["target_ref"] = {"kind": "water_segment", "id": "M_TIE"}
	model.feed(created)
	assert_eq(str(model.row(9)["target_kind"]), "water_segment")
	assert_eq(str(model.row(9)["target_id"]), "M_TIE")
	# A later lifecycle event carries no target and must not blank the one the
	# create supplied.
	model.feed({"type": "incident_tier_changed", "incident_id": 9, "tier": 3})
	assert_eq(str(model.row(9)["target_id"]), "M_TIE")
	# And a row born from a snapshot alone — a save loaded mid-incident — gets
	# it from `IncidentSystem.snapshot()`.
	var fresh := _model()
	var snap := Fixtures.snapshot_row(9, "water_main_break", 2.4)
	snap["target_ref"] = {"kind": "water_segment", "id": "M_TIE"}
	fresh.refresh([snap])
	assert_eq(str(fresh.row(9)["target_id"]), "M_TIE")


func test_the_valve_appears_only_on_a_row_with_a_main_behind_it() -> void:
	var mounted := _mount()
	var drawer: IncidentDrawer = mounted["drawer"]
	var sim := CitySim.boot_from_files()
	drawer.bind_water(WaterActions.new(sim, RequirementFormatter.load_from_files()))
	var fire := Fixtures.snapshot_row(7, "structure_fire", 3.4)
	fire["target_ref"] = {"kind": "building", "id": "R-1"}
	var leak := Fixtures.snapshot_row(9, "water_main_break", 2.4)
	leak["target_ref"] = {"kind": "water_segment", "id": "M_TIE"}
	var ghost := Fixtures.snapshot_row(11, "water_main_break", 2.4)
	ghost["target_ref"] = {"kind": "water_segment", "id": "NO-SUCH-MAIN"}
	drawer.refresh_from([fire, leak, ghost])
	drawer.open()
	assert_eq(drawer.action_button("Valve", 7), null,
			"a fire's target is a building — there is no valve to turn")
	assert_eq(drawer.action_button("Valve", 11), null,
			"and a main the sim does not have draws no button either")
	var valve := drawer.action_button("Valve", 9)
	assert_ne(valve, null, "§2.12's pair, beside ASSIGN")
	assert_eq(valve.text, UIWidgets.t(drawer.config, "ui_drawer_isolate"))
	assert_true(valve.tooltip_text.contains("M_TIE"), "A15: it names the main")
	assert_false(valve.tooltip_text.contains("{"))
	_unmount(mounted)


func test_an_unbound_drawer_is_exactly_the_drawer_it_was() -> void:
	# No `WaterActions` — a fixture mount, or a shell that never built a
	# controller. The row is the three actions it has always had.
	var mounted := _mount()
	var drawer: IncidentDrawer = mounted["drawer"]
	var leak := Fixtures.snapshot_row(9, "water_main_break", 2.4)
	leak["target_ref"] = {"kind": "water_segment", "id": "M_TIE"}
	drawer.refresh_from([leak])
	drawer.open()
	assert_eq(drawer.action_button("Valve", 9), null)
	assert_ne(drawer.action_button("Assign", 9), null)
	_unmount(mounted)


func test_pressing_the_valve_runs_the_command_and_flips_the_control() -> void:
	var mounted := _mount()
	var drawer: IncidentDrawer = mounted["drawer"]
	var sim := CitySim.boot_from_files()
	drawer.bind_water(WaterActions.new(sim, RequirementFormatter.load_from_files()))
	var leak := Fixtures.snapshot_row(9, "water_main_break", 2.4)
	leak["target_ref"] = {"kind": "water_segment", "id": "M_TIE"}
	drawer.refresh_from([leak])
	drawer.open()
	var seen: Array[Dictionary] = []
	drawer.main_action_taken.connect(
			func(incident_id: int, edge_id: String, action: StringName,
					result: Dictionary) -> void:
				seen.append({"incident": incident_id, "edge": edge_id,
						"action": String(action), "ok": bool(result["ok"])}))
	drawer.action_button("Valve", 9).pressed.emit()
	assert_eq(String((sim.water.edges["M_TIE"] as WaterEdge).state), "isolated",
			"the real command ran (doc 12 §4.4)")
	assert_eq(seen.size(), 1)
	assert_eq(str(seen[0]["action"]), "isolate")
	assert_eq(str(seen[0]["edge"]), "M_TIE")
	assert_true(bool(seen[0]["ok"]))
	# The control now offers the other half of the pair, in place — the list is
	# NOT rebuilt, because that would free the Button that is emitting.
	var valve := drawer.action_button("Valve", 9)
	assert_eq(valve.text, UIWidgets.t(drawer.config, "ui_drawer_restore"))
	valve.pressed.emit()
	assert_eq(String((sim.water.edges["M_TIE"] as WaterEdge).state), "ok")
	assert_eq(str(seen[1]["action"]), "restore")
	_unmount(mounted)


func test_the_root_resolves_the_water_binding_from_the_build_sheet() -> void:
	# The shell builds the `BuildController` after `bring_up_screens()`, so the
	# root takes doc 05's verb model off the sheet the first time it feeds a
	# snapshot rather than asking `game/main.gd` for a second binding call.
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var drawer: IncidentDrawer = mounted["drawer"]
	assert_eq(drawer.water, null, "nothing is bound before the shell arrives")
	var sim := CitySim.boot_from_files()
	root.build_sheet.setup(root.config,
			BuildController.new(sim, RequirementFormatter.load_from_files()))
	root.refresh_incidents([], 10.0)
	assert_ne(drawer.water, null, "and the drawer has it after one refresh")
	assert_eq(drawer.water, root.build_sheet.controller.water)
	_unmount(mounted)
