extends SimTest
## **S17's headless half (doc 12 §2.24 / 99-PA PA-26)** — the Storm Prep window
## as a screen, without a scene tree.
##
## `StormPrepModel` reads `CitySim.storm_prep_overview()`'s shape through a
## provider Callable, so every one of these runs against a fixture. That is the
## point: the screen was written before a shell wired it, and A91-D-28's lesson
## is that a surface nothing can open is a surface nothing has ever checked.

const OPEN_WINDOW := {
	"open": true, "event_uid": 7, "minutes_to_impact": 90, "minutes_left": 70,
	"severity_mult": 1.28, "intensity": 0.84,
	"taken": ["load_shed"], "min_prep_actions": 3,
	"actions": [
		{"id": "load_shed", "cost": 0, "taken": true, "available": false,
				"reason_code": "E_ALREADY_TAKEN", "needs_target": false},
		{"id": "top_off_water", "cost": 1240, "taken": false, "available": true,
				"reason_code": "", "needs_target": false},
		{"id": "callout_crew", "cost": 18000, "taken": false, "available": false,
				"reason_code": "E_FUNDS", "needs_target": false},
		{"id": "sandbag_block", "cost": 6000, "taken": false, "available": false,
				"reason_code": "E_NO_TARGET", "needs_target": true},
	],
	"readiness": {"grid_powered_frac": 0.96, "fleet_idle": 3, "water_fill": 0.52},
}


func _model(raw: Dictionary, taken: Array = []) -> StormPrepModel:
	var log: Array = taken
	return StormPrepModel.new(UIConfig.load_from_files(),
			func() -> Dictionary: return raw,
			func(action_id: String, _target: Dictionary) -> Dictionary:
				log.append(action_id)
				return {"ok": true, "reason_code": &"", "payload": {}})


func test_the_window_becomes_a_screen() -> void:
	var view := _model(OPEN_WINDOW).view()
	assert_true(bool(view["visible"]), "a pending storm has a screen")
	assert_true(bool(view["open"]), "…and the door is open at T−90")
	assert_eq((view["rows"] as Array).size(), 4, "one row per action offered")
	assert_eq((view["meters"] as Array).size(), 3,
			"§2.7.7's three readings, one meter each")
	assert_eq(int(view["taken_count"]), 1)
	assert_eq(int(view["target_count"]), 3,
			"the Storm Ready threshold is READ, never authored here")
	assert_false(bool(view["reward_met"]))


func test_no_storm_means_no_screen() -> void:
	var view := _model({}).view()
	assert_false(bool(view["visible"]),
			"a sheet that opened on an empty window is a door onto a corridor")
	assert_false(bool(view["open"]))


func test_every_row_says_what_it_costs_and_why_it_is_shut() -> void:
	var rows: Dictionary = {}
	for entry in (_model(OPEN_WINDOW).view()["rows"] as Array):
		rows[String((entry as Dictionary)["id"])] = entry
	var shed: Dictionary = rows["load_shed"]
	assert_eq(String(shed["state"]), StormPrepModel.STATE_TAKEN)
	assert_eq(String(shed["mark"]), StormPrepModel.MARK_TAKEN,
			"A5: the state is never colour alone")
	assert_false(bool(shed["enabled"]), "an action already taken is not a button")
	var water: Dictionary = rows["top_off_water"]
	assert_eq(String(water["state"]), StormPrepModel.STATE_AVAILABLE)
	assert_true(bool(water["enabled"]))
	assert_eq(String(water["cost_text"]), RequirementFormatter.money(1240))
	var crew: Dictionary = rows["callout_crew"]
	assert_eq(String(crew["state"]), StormPrepModel.STATE_BLOCKED)
	assert_false(bool(crew["enabled"]))
	assert_ne(String(crew["reason"]), "",
			"a greyed button with no reason teaches nothing")
	assert_false(String(crew["reason"]).contains("E_"),
			"and the player never reads a reason CODE (doc 12 §1)")
	assert_eq(String(rows["sandbag_block"]["reason"]),
			UIConfig.load_from_files().t("ui_storm_reason_target"))
	assert_eq(String(shed["cost_text"]),
			UIConfig.load_from_files().t("ui_storm_cost_free"),
			"a free action says so in words rather than showing $0")


func test_the_countdown_and_the_reward_line_are_copy_not_numbers() -> void:
	var config := UIConfig.load_from_files()
	var view := _model(OPEN_WINDOW).view()
	assert_true(String(view["countdown"]).length() > 0)
	assert_false(String(view["countdown"]).contains("{"),
			"every placeholder resolved")
	assert_false(String(view["reward"]).contains("{"))
	assert_eq(String(view["severity"]), config.t("ui_storm_severity_severe"),
			"1.28 reads as the hard band; the player never sees a multiplier")
	# One more taken and the line changes from a count to the promise.
	var almost := OPEN_WINDOW.duplicate(true)
	almost["taken"] = ["load_shed", "top_off_water", "callout_crew"]
	var met := _model(almost).view()
	assert_true(bool(met["reward_met"]))
	assert_eq(String(met["reward"]), config.t("ui_storm_reward_met"))


func test_the_closed_window_says_so_instead_of_counting_down_to_nothing() -> void:
	var shut := OPEN_WINDOW.duplicate(true)
	shut["open"] = false
	shut["minutes_left"] = 0
	for entry in (shut["actions"] as Array):
		(entry as Dictionary)["available"] = false
		(entry as Dictionary)["reason_code"] = "E_PREP_WINDOW"
	var view := _model(shut).view()
	assert_true(bool(view["visible"]), "the storm is still coming")
	assert_false(bool(view["open"]))
	assert_eq(String(view["countdown"]),
			UIConfig.load_from_files().t("ui_storm_window_closed"))
	for entry in (view["rows"] as Array):
		var row: Dictionary = entry
		if bool(row["state"] == StormPrepModel.STATE_TAKEN):
			continue
		assert_false(bool(row["enabled"]), "nothing is buyable after T−20")


func test_the_model_takes_no_decision_of_its_own() -> void:
	var taken: Array = []
	var model := _model(OPEN_WINDOW, taken)
	var result := model.take("top_off_water")
	assert_true(bool(result["ok"]), "the door's answer comes back unchanged")
	assert_eq(taken, ["top_off_water"], "…and the door is what was called")
	# Without a door it refuses rather than pretending.
	var bare := StormPrepModel.new(UIConfig.load_from_files())
	assert_false(bool(bare.take("load_shed")["ok"]))


func test_every_string_the_screen_uses_is_in_the_table() -> void:
	# Doc 12 §1: no copy in a `.gd` file. A missing key renders as the key, which
	# is the one bug this screen could ship that nobody would read as a bug.
	var config := UIConfig.load_from_files()
	var keys: Array = ["ui_storm_prep_title", "ui_storm_countdown",
			"ui_storm_window_closed", "ui_storm_cost_free", "ui_storm_take",
			"ui_storm_reward_met", "ui_storm_reward_progress",
			"ui_storm_meter_grid", "ui_storm_meter_water", "ui_storm_meter_fleet",
			"ui_storm_meter_fleet_value", "ui_storm_severity_mild",
			"ui_storm_severity_moderate", "ui_storm_severity_severe"]
	for action_id in CitySim.STORM_PREP_ACTIONS:
		keys.append("ui_storm_action_%s" % action_id)
		keys.append("ui_storm_action_%s_detail" % action_id)
	for key in StormPrepModel.REASON_KEYS.values():
		keys.append(String(key))
	for key in keys:
		assert_true(config.has_string(String(key)),
				"data/strings.en.json is missing `%s`" % key)


func test_the_screen_and_the_sim_agree_on_the_six_actions() -> void:
	# The census that stops the two halves drifting: every action the verb
	# accepts has copy, and no copy exists for an action the verb refuses.
	var config := UIConfig.load_from_files()
	var sim := CitySim.boot_from_files(4242)
	var overview := sim.storm_prep_overview()
	var ids: Array = []
	for entry in (overview["actions"] as Array):
		ids.append(String((entry as Dictionary)["id"]))
	assert_eq(ids, CitySim.STORM_PREP_ACTIONS as Array,
			"the overview draws exactly the verb's own six, in §2.7.7's order")
	for action_id in ids:
		assert_true(config.has_string("ui_storm_action_%s" % action_id))
	sim.dispose()
