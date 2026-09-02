extends SimTest
## Doc 12 §2.13 / §3.2 — the settings sheet, the save-slot screen and the pause
## menu.
##
## `game/save_service.gd` is written by the Android track in parallel, so
## everything here runs against `StubSaveService` at the bottom of this file: the
## exact five methods the real service publishes (`save_slot`, `load_slot`,
## `list_slots`, `delete_slot`, `autosave`) and nothing else. If the real service
## drifts from that shape, `SaveSlotsModel` stops working and this file is where
## it shows.


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
	return {
		"root": root,
		"settings": root.settings_sheet,
		"saves": root.save_load_sheet,
		"pause": root.pause_menu,
		"hud": root.hud,
	}


func _unmount(mounted: Dictionary) -> void:
	var root: Node = mounted["root"]
	_tree().root.remove_child(root)
	root.free()


# ===========================================================================
# SettingsModel
# ===========================================================================

func test_rows_and_defaults_come_from_data() -> void:
	var model := SettingsModel.new(_cfg())
	var keys := model.keys()
	for expected: String in ["graphics", "autosave_interval_min", "sound_volume",
			"reduce_motion", "larger_touch_targets", "in_app_banners", "text_scale"]:
		assert_true(keys.has(expected), "the sheet carries a %s row" % expected)
	assert_eq(model.kind("graphics"), SettingsModel.KIND_CHOICE)
	assert_eq(model.kind("reduce_motion"), SettingsModel.KIND_TOGGLE)
	assert_eq(model.kind("sound_volume"), SettingsModel.KIND_SLIDER)
	# Defaults are data/ui.json's `defaults` block, never authored in code.
	var defaults := _cfg().section("defaults")
	assert_eq(str(model.value("graphics")), str(defaults["graphics"]))
	assert_eq(model.value_bool("reduce_motion"), bool(defaults["reduce_motion"]))
	var cfg := _cfg()
	for row: Dictionary in model.rows():
		assert_true(cfg.has_string(str(row["label_key"])),
				"%s has copy" % row["label_key"])


func test_graphics_presets_are_doc11s_and_ordered_cheapest_first() -> void:
	# The list is `data/render.json.presets`, so it can never name a preset the
	# renderer does not have.
	var cfg := _cfg()
	var model := SettingsModel.new(cfg)
	var presets := model.options("graphics")
	var render: Dictionary = cfg.render_data()["presets"]
	assert_eq(presets.size(), render.size())
	assert_eq(str(presets[0]), "performance")
	assert_eq(str(presets[1]), "balanced")
	assert_eq(str(presets[2]), "high")
	for name: Variant in presets:
		assert_true(render.has(str(name)), "%s exists in data/render.json" % name)
		assert_true(cfg.has_string("ui_settings_value_graphics_%s" % str(name)),
				"%s has copy" % name)


func test_the_refresh_row_is_doc_11s_ladder_and_cycles_it() -> void:
	# D-75 / report 98 RR-126. The row is a `choice` like `graphics`, its ladder is
	# `data/render.json.refresh.settings_modes` so it cannot offer a mode
	# `RefreshPin` refuses, and it is one 48 dp cycling target (A3 — no dropdown).
	var cfg := _cfg()
	var model := SettingsModel.new(cfg)
	assert_true(model.has_key("refresh_rate"), "S9 carries the refresh row")
	assert_eq(model.kind("refresh_rate"), SettingsModel.KIND_CHOICE)
	var modes := model.options("refresh_rate")
	var authored: Variant = (cfg.render_data().get("refresh", {}) as Dictionary) \
			.get("settings_modes", [])
	assert_eq(modes, authored as Array,
			"the ladder is doc 11's file, never a second copy in data/ui.json")
	assert_eq(str(model.value("refresh_rate")), "auto",
			"a fresh install declares the cap — data/ui.json.defaults.refresh_rate")
	for mode: Variant in modes:
		assert_true(cfg.has_string("ui_settings_value_refresh_%s" % str(mode)),
				"%s has copy" % mode)
	# The cycle walks the whole ladder and wraps, in the authored order.
	for expected: Variant in modes.slice(1) + [modes[0]]:
		assert_eq(str(model.cycle("refresh_rate")), str(expected))
	assert_eq(model.value_text("refresh_rate"), "Auto")
	model.set_value("refresh_rate", "off")
	assert_eq(model.value_text("refresh_rate"), "Off")
	assert_true(Array(model.device_scoped_keys()).has("refresh_rate"),
			"the panel is a property of the phone, not of the city")


func test_the_refresh_row_round_trips_and_refuses_a_mode_the_pin_would_not_take() -> void:
	var model := SettingsModel.new(_cfg())
	assert_false(model.set_value("refresh_rate", "90"),
			"90 is on the LEVER's ladder and not on the row's")
	assert_false(model.set_value("refresh_rate", "144"))
	assert_true(model.set_value("refresh_rate", "120"))
	var restored := SettingsModel.new(_cfg())
	var dropped := restored.restore_state(model.capture_state())
	assert_eq(dropped.size(), 0)
	assert_eq(str(restored.value("refresh_rate")), "120")
	# …and a saved value the ladder no longer carries is dropped for its default,
	# which is §3.2's whole migration promise applied to a new row.
	var messy := SettingsModel.new(_cfg())
	var dropped2 := messy.restore_state({"refresh_rate": "240"})
	assert_true(Array(dropped2).has("refresh_rate"))
	assert_eq(str(messy.value("refresh_rate")), "auto")


func test_choice_rows_cycle_and_wrap() -> void:
	# One 48 dp target per row: tapping it walks the options (A3 — no dropdowns).
	var model := SettingsModel.new(_cfg())
	model.set_value("graphics", "performance")
	assert_eq(str(model.cycle("graphics")), "balanced")
	assert_eq(str(model.cycle("graphics")), "high")
	assert_eq(str(model.cycle("graphics")), "performance", "it wraps")


func test_toggles_and_the_slider_step() -> void:
	var model := SettingsModel.new(_cfg())
	var before := model.value_bool("reduce_motion")
	assert_eq(model.toggle("reduce_motion"), not before)
	assert_eq(model.toggle("reduce_motion"), before)

	model.set_value("sound_volume", 0.8)
	assert_almost_eq(model.step_slider("sound_volume", 1), 0.9, 0.0001)
	assert_almost_eq(model.step_slider("sound_volume", 1), 1.0, 0.0001)
	assert_almost_eq(model.step_slider("sound_volume", 1), 0.0, 0.0001,
			"past the top it wraps to the bottom")
	assert_almost_eq(model.step_slider("sound_volume", -1), 1.0, 0.0001)


func test_set_value_validates() -> void:
	var model := SettingsModel.new(_cfg())
	assert_false(model.set_value("graphics", "ultra"), "an option that does not exist")
	assert_false(model.set_value("nonsense", 1), "a row that does not exist")
	assert_true(model.set_value("graphics", "high"))
	assert_false(model.set_value("graphics", "high"), "setting the same value is no change")
	model.set_value("sound_volume", 5.0)
	assert_almost_eq(model.value_num("sound_volume"), 1.0, 0.0001, "clamped to max")
	model.set_value("sound_volume", -2.0)
	assert_almost_eq(model.value_num("sound_volume"), 0.0, 0.0001, "clamped to min")


func test_value_text_resolves_every_row_from_the_string_table() -> void:
	var model := SettingsModel.new(_cfg())
	model.set_value("graphics", "balanced")
	assert_eq(model.value_text("graphics"), "Balanced")
	model.set_value("autosave_interval_min", 0)
	assert_eq(model.value_text("autosave_interval_min"), "Off")
	model.set_value("autosave_interval_min", 15)
	assert_eq(model.value_text("autosave_interval_min"), "Every 15 min")
	assert_almost_eq(model.autosave_interval_s(), 900.0, 0.001)
	model.set_value("sound_volume", 0.8)
	assert_eq(model.value_text("sound_volume"), "80%")
	model.set_value("reduce_motion", true)
	assert_eq(model.value_text("reduce_motion"), "On")
	for row: Dictionary in model.rows():
		assert_false(str(row["value_text"]).contains("{"),
				"%s leaves no placeholder" % row["key"])


# ===========================================================================
# Doc 10 §2.13's automatic road repair (feeder-water open q1, doc 93 §J3)
# ===========================================================================

func test_the_road_dials_read_doc10s_own_ladder_and_default() -> void:
	var cfg := _cfg()
	var model := SettingsModel.new(cfg)
	var condition := cfg.road_condition()
	assert_false(condition.is_empty(), "data/roads.json reached the UI layer")
	assert_eq(model.policy_of("auto_repair_threshold"), SettingsModel.POLICY_ROADS)
	assert_eq(model.policy_of("auto_repair_daily_cap"), SettingsModel.POLICY_ROADS)
	assert_eq(model.policy_of("auto_repair_cost_cap"), SettingsModel.POLICY_DISPATCH,
			"doc 06's dispatch ceiling is a DIFFERENT row and stays where it was")
	# The ladder is `RoadNetwork.cmd_set_auto_repair_policy`'s own allow-list, so
	# the control can never offer a rung the command answers E_BAD_THRESHOLD for.
	assert_eq(str(model.options("auto_repair_threshold")),
			str(condition["auto_repair_thresholds"]))
	assert_almost_eq(model.value_num("auto_repair_threshold"),
			float(condition["auto_repair_default_threshold"]), 0.0001)
	assert_almost_eq(model.value_num("auto_repair_daily_cap"),
			float(condition["auto_repair_default_daily_cap"]), 0.0001)
	var on_ladder := false
	for rung: Variant in model.options("auto_repair_daily_cap"):
		on_ladder = on_ladder or is_equal_approx(float(rung),
				float(condition["auto_repair_default_daily_cap"]))
	assert_true(on_ladder,
			"and the default sits ON the cap ladder rather than beside it: %s"
			% str(model.options("auto_repair_daily_cap")))


func test_the_road_dials_read_as_words_a_player_can_act_on() -> void:
	var model := SettingsModel.new(_cfg())
	model.set_value("auto_repair_threshold", 0.55)
	assert_eq(model.value_text("auto_repair_threshold"), "55%")
	model.set_value("auto_repair_threshold", 0)
	assert_eq(model.value_text("auto_repair_threshold"), "Never",
			"the bottom rung is a state, not a quantity")
	model.set_value("auto_repair_daily_cap", 25000)
	assert_eq(model.value_text("auto_repair_daily_cap"),
			HudModel.money_exact(25000))
	model.set_value("auto_repair_daily_cap", 0)
	assert_eq(model.value_text("auto_repair_daily_cap"), "No budget")


const _ROAD_SEED := {"auto_repair_threshold": 0.40, "auto_repair_daily_cap": 25000}


func test_a_road_row_writes_the_pair_the_command_takes() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var calls: Array = []
	var spy := func(threshold: float, cap: int) -> Dictionary:
		calls.append([threshold, cap])
		return CommandQueue.ok({"threshold": threshold, "daily_cap": cap})
	root.bind_road_policy(spy, _ROAD_SEED)
	assert_eq(calls.size(), 0, "seeding a row is not a command")
	root.settings_sheet.value_button("auto_repair_threshold").pressed.emit()
	assert_eq(calls.size(), 1, "one tap, one command")
	assert_almost_eq(float((calls[0] as Array)[0]), 0.55, 0.0001,
			"the rung after 0.40 on doc 10's ladder")
	assert_eq(int((calls[0] as Array)[1]), 25000,
			"and the OTHER dial rides along unchanged — the command takes both")
	root.settings_sheet.value_button("auto_repair_daily_cap").pressed.emit()
	assert_almost_eq(float((calls[1] as Array)[0]), 0.55, 0.0001,
			"the threshold the player just chose is what the second call carries")
	assert_eq(int((calls[1] as Array)[1]), 75000)
	_unmount(mounted)


func test_a_refused_dial_puts_the_row_back_and_says_why() -> void:
	# A14 again: the sim rules, and its refusal is the formatter's sentence.
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var refuse := func(_threshold: float, _cap: int) -> Dictionary:
		return CommandQueue.fail(&"E_BAD_THRESHOLD",
				{"allowed": [0, 0.25, 0.4, 0.55]})
	root.bind_road_policy(refuse, _ROAD_SEED)
	root.settings_sheet.value_button("auto_repair_threshold").pressed.emit()
	assert_almost_eq(root.settings_sheet.model.value_num("auto_repair_threshold"),
			0.40, 0.0001, "the row shows what the city actually holds")
	var text := root.toast_view.text()
	assert_true(text.contains("55"),
			"the sentence names the rung it refused: '%s'" % text)
	assert_false(text.contains("{"))
	_unmount(mounted)


func test_the_live_city_takes_the_dial_end_to_end() -> void:
	# The whole wire, over a real `CitySim`: the row moves, the command runs, and
	# `RoadNetwork` holds the new policy.
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var sim := CitySim.boot_from_files()
	root.bind_road_policy(sim.cmd_set_auto_repair_policy, sim.auto_repair_policy())
	assert_almost_eq(sim.roads.auto_repair_threshold, 0.40, 0.0001)
	root.settings_sheet.value_button("auto_repair_threshold").pressed.emit()
	assert_almost_eq(sim.roads.auto_repair_threshold, 0.55, 0.0001,
			"doc 10's dial moved because a player tapped a settings row")
	assert_eq(sim.roads.auto_repair_daily_cap, 25000, "the cap is untouched")
	root.settings_sheet.value_button("auto_repair_daily_cap").pressed.emit()
	assert_eq(sim.roads.auto_repair_daily_cap, 75000)
	assert_almost_eq(sim.roads.auto_repair_threshold, 0.55, 0.0001)
	_unmount(mounted)


func test_settings_round_trip_and_the_migration_policy() -> void:
	# §3.2: "unknown settings keys are dropped, missing keys take defaults from
	# data/ui.json — a settings change must never invalidate a city."
	var model := SettingsModel.new(_cfg())
	model.set_value("graphics", "high")
	model.set_value("autosave_interval_min", 30)
	model.set_value("sound_volume", 0.5)
	model.set_value("reduce_motion", true)
	var state := model.capture_state()

	var restored := SettingsModel.new(_cfg())
	var dropped := restored.restore_state(state)
	assert_eq(dropped.size(), 0, "a clean block drops nothing")
	assert_eq(str(restored.value("graphics")), "high")
	assert_eq(int(restored.value("autosave_interval_min")), 30)
	assert_true(restored.value_bool("reduce_motion"))

	var messy := SettingsModel.new(_cfg())
	var dropped2 := messy.restore_state({"graphics": "high", "from_a_future_build": 7,
			"sound_volume": "loud"})
	assert_true(Array(dropped2).has("from_a_future_build"), "unknown key dropped")
	assert_true(Array(dropped2).has("sound_volume"), "invalid value dropped")
	assert_eq(str(messy.value("graphics")), "high", "the valid key still applied")
	assert_eq(int(messy.value("autosave_interval_min")), 5, "a missing key takes its default")


func test_about_rows_name_the_build() -> void:
	var model := SettingsModel.new(_cfg())
	var rows := model.about_rows()
	assert_eq(rows.size(), 2)
	for row: Dictionary in rows:
		assert_false(str(row["text"]).contains("{"), "no placeholder left over")
		assert_true(str(row["text"]).length() > 0)
	assert_true(str(rows[0]["text"]).contains(
			str(ProjectSettings.get_setting("application/config/version", ""))))


# ===========================================================================
# SaveSlotsModel — against the stubbed service
# ===========================================================================

func _slots(service: Object = null) -> SaveSlotsModel:
	var model := SaveSlotsModel.new(_cfg())
	model.bind(service if service != null else StubSaveService.new(), null)
	return model


func test_without_a_service_the_screen_says_so_instead_of_showing_dead_buttons() -> void:
	var model := SaveSlotsModel.new(_cfg())
	assert_false(model.is_available())
	for row: Dictionary in model.rows():
		assert_false(bool(row["can_save"]))
		assert_false(bool(row["can_load"]))
	var refused := model.request(SaveSlotsModel.ACTION_SAVE, 1)
	assert_false(bool(refused["ok"]))
	assert_eq(refused["reason"], SaveSlotsModel.REASON_UNAVAILABLE)
	assert_ne(str(refused["message"]), "", "A14: it says why, in words")


func test_empty_slots_are_rows_not_gaps() -> void:
	var model := _slots()
	var rows := model.rows()
	assert_eq(rows.size(), 3, "data/ui.json.save_slots.count")
	assert_true(bool(rows[0]["is_autosave"]), "slot 0 belongs to autosave")
	for row: Dictionary in rows:
		assert_false(bool(row["used"]))
		assert_eq(str(row["summary"]), "Empty")
		assert_false(bool(row["can_load"]), "you cannot load an empty slot")
		assert_false(bool(row["can_delete"]))


func test_saving_an_empty_slot_needs_no_confirmation_but_overwriting_does() -> void:
	var service := StubSaveService.new()
	var model := _slots(service)
	var first := model.request(SaveSlotsModel.ACTION_SAVE, 1)
	assert_false(bool(first["confirm_required"]), "nothing is lost, so nothing is asked")
	assert_true(bool(first["ok"]))
	assert_eq(service.saves, 1)
	assert_true(model.is_used(1))

	var again := model.request(SaveSlotsModel.ACTION_SAVE, 1)
	assert_true(bool(again["confirm_required"]), "overwriting asks first")
	assert_eq(service.saves, 1, "and nothing happened yet")
	assert_true(str(again["prompt"]).contains("Slot 1"))
	assert_true(bool(model.confirm()["ok"]))
	assert_eq(service.saves, 2)
	assert_false(model.has_pending())


func test_load_and_delete_always_confirm_and_cancel_really_cancels() -> void:
	var service := StubSaveService.new()
	var model := _slots(service)
	model.request(SaveSlotsModel.ACTION_SAVE, 2)

	var load_request := model.request(SaveSlotsModel.ACTION_LOAD, 2)
	assert_true(bool(load_request["confirm_required"]))
	assert_true(str(load_request["prompt"]).length() > 0)
	model.cancel()
	assert_false(model.has_pending())
	assert_eq(service.loads, 0, "a cancelled load never touched the sim")
	assert_false(bool(model.confirm()["ok"]), "confirming nothing is refused")

	model.request(SaveSlotsModel.ACTION_LOAD, 2)
	var loaded := model.confirm()
	assert_true(bool(loaded["ok"]))
	assert_eq(service.loads, 1)
	assert_true(str(loaded["message"]).contains("Slot 2"))

	model.request(SaveSlotsModel.ACTION_DELETE, 2)
	assert_true(bool(model.confirm()["ok"]))
	assert_false(model.is_used(2), "the row is empty again")
	assert_eq(service.deletes, 1)


func test_a_failed_service_call_reports_failure_and_changes_nothing() -> void:
	var service := StubSaveService.new()
	service.fail = true
	var model := _slots(service)
	var result := model.request(SaveSlotsModel.ACTION_SAVE, 1)
	assert_false(bool(result["ok"]))
	assert_eq(result["reason"], SaveSlotsModel.REASON_FAILED)
	assert_ne(str(result["message"]), "")
	assert_false(model.is_used(1))


func test_slot_rows_format_meta_the_way_the_hud_does() -> void:
	var service := StubSaveService.new()
	var model := _slots(service)
	model.request(SaveSlotsModel.ACTION_SAVE, 1)
	var row := model.row(1)
	assert_true(bool(row["used"]))
	assert_true(str(row["summary"]).contains(HudModel.pop(184291)))
	assert_true(str(row["summary"]).contains(HudModel.money(8420000)))
	assert_true(str(row["summary"]).contains("Day 4"), "day_index 3 reads as Day 4")
	assert_true(str(row["saved_text"]).begins_with("Saved "))
	assert_false(str(row["saved_text"]).contains("{"))


func test_autosave_never_prompts() -> void:
	var service := StubSaveService.new()
	var model := _slots(service)
	assert_true(model.autosave())
	assert_eq(service.autosaves, 1)
	assert_false(model.has_pending(), "autosave asks nobody anything")
	assert_true(model.is_used(model.autosave_slot()))


# ===========================================================================
# The mounted screens
# ===========================================================================

func test_modals_start_closed_and_answer_the_back_stack_in_order() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var settings: SettingsSheet = mounted["settings"]
	var saves: SaveLoadSheet = mounted["saves"]
	var pause: PauseMenu = mounted["pause"]
	for screen: Variant in [settings, saves, pause]:
		assert_ne(screen, null, "the scaffold carries every modal")
		assert_false(bool(screen.call("is_open")))
	settings.open()
	assert_true(settings.is_open())
	assert_eq(root.handle_back(0.0), UIRoot.BACK_CLOSE_MODAL)
	assert_false(settings.is_open(), "BACK closed it without freeing it")
	assert_ne(root.get_node_or_null("SafeArea/ModalLayer/SettingsSheet"), null)
	_unmount(mounted)


func test_only_one_modal_is_up_at_a_time() -> void:
	var mounted := _mount()
	var settings: SettingsSheet = mounted["settings"]
	var pause: PauseMenu = mounted["pause"]
	pause.open()
	settings.open()
	assert_false(pause.is_open(), "opening settings put the pause menu away")
	assert_true(settings.is_open())
	_unmount(mounted)


func test_hud_menu_button_opens_the_pause_menu_and_pausing_is_an_intent() -> void:
	# §2.11: `paused` is doc 01's, so the menu asks rather than sets.
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var hud: CityHUD = mounted["hud"]
	var pause: PauseMenu = mounted["pause"]
	var intents: Array[bool] = []
	root.pause_intent.connect(func(paused: bool) -> void: intents.append(paused))
	assert_ne(hud.menu_button(), null, "the top bar carries the menu button")
	hud.menu_button().pressed.emit()
	assert_true(pause.is_open())
	assert_eq(intents, [true] as Array[bool], "opening it asks for a pause")
	pause.action_button(PauseMenu.ACTION_RESUME).pressed.emit()
	assert_false(pause.is_open())
	assert_eq(intents, [true, false] as Array[bool], "resuming asks for the resume")
	_unmount(mounted)


func test_pause_menu_routes_settings_saves_and_quit() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var pause: PauseMenu = mounted["pause"]
	# An Array, not an int: GDScript lambdas capture locals by value.
	var quits: Array[int] = []
	root.quit_requested.connect(func() -> void: quits.append(1))
	pause.open()
	pause.action_button(PauseMenu.ACTION_SETTINGS).pressed.emit()
	assert_true((mounted["settings"] as SettingsSheet).is_open())
	pause.open()
	pause.action_button(PauseMenu.ACTION_SAVE).pressed.emit()
	assert_true((mounted["saves"] as SaveLoadSheet).is_open())
	pause.open()
	pause.action_button(PauseMenu.ACTION_QUIT).pressed.emit()
	assert_eq(quits.size(), 1, "QUIT is an intent — the shell saves and closes")
	assert_true(pause.is_open(), "and the menu stays up until it does")
	_unmount(mounted)


func test_settings_sheet_binds_the_model_and_reports_changes() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var settings: SettingsSheet = mounted["settings"]
	var changes: Array[String] = []
	root.settings_changed.connect(func(key: StringName, _v: Variant) -> void:
		changes.append(String(key)))
	settings.open()
	var button := settings.value_button("graphics")
	assert_ne(button, null)
	var before := button.text
	button.pressed.emit()
	assert_ne(button.text, before, "the row shows its new value immediately")
	assert_eq(changes, ["graphics"] as Array[String])
	assert_eq(button.text, settings.model.value_text("graphics"))
	_unmount(mounted)


func test_settings_saves_button_opens_the_slot_screen() -> void:
	var mounted := _mount()
	var settings: SettingsSheet = mounted["settings"]
	var saves: SaveLoadSheet = mounted["saves"]
	settings.open()
	var saves_button := settings.get_node(
			"Panel/Body/Saves") as Button
	saves_button.pressed.emit()
	assert_true(saves.is_open())
	assert_false(settings.is_open(), "one modal at a time")
	_unmount(mounted)


func test_save_sheet_runs_the_whole_confirm_flow_through_the_buttons() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var saves: SaveLoadSheet = mounted["saves"]
	var service := StubSaveService.new()
	root.bind_save_service(service, null)
	var actions: Array[String] = []
	root.save_slot_action.connect(func(action: StringName, _slot: int, _r: Dictionary) -> void:
		actions.append(String(action)))
	saves.open()

	saves.action_button(SaveSlotsModel.ACTION_SAVE, 1).pressed.emit()
	assert_eq(service.saves, 1, "an empty slot saves straight away")
	assert_eq(actions, ["save"] as Array[String])
	assert_false(saves.action_button(SaveSlotsModel.ACTION_LOAD, 1).disabled,
			"the row now offers LOAD")

	saves.action_button(SaveSlotsModel.ACTION_DELETE, 1).pressed.emit()
	assert_eq(service.deletes, 0, "a delete asks first")
	assert_true(saves.model.has_pending())
	saves.cancel_button().pressed.emit()
	assert_false(saves.model.has_pending())
	assert_eq(service.deletes, 0)

	saves.action_button(SaveSlotsModel.ACTION_DELETE, 1).pressed.emit()
	saves.confirm_button().pressed.emit()
	assert_eq(service.deletes, 1)
	assert_true(saves.action_button(SaveSlotsModel.ACTION_LOAD, 1).disabled,
			"the row went back to empty")
	_unmount(mounted)


func test_a_load_tells_the_shell_the_sim_was_replaced() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var saves: SaveLoadSheet = mounted["saves"]
	var service := StubSaveService.new()
	root.bind_save_service(service, null)
	var loaded: Array[int] = []
	root.save_loaded.connect(func(slot: int) -> void: loaded.append(slot))
	saves.open()
	saves.action_button(SaveSlotsModel.ACTION_SAVE, 2).pressed.emit()
	saves.action_button(SaveSlotsModel.ACTION_LOAD, 2).pressed.emit()
	saves.confirm_button().pressed.emit()
	assert_eq(loaded, [2] as Array[int])
	_unmount(mounted)


func test_ui_state_round_trips_through_the_root() -> void:
	# §3.2's `ui` save section, as far as this slice fills it.
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	root.overlay_rail.select(&"power")
	root.settings_sheet.model.set_value("graphics", "high")
	var state := root.capture_ui_state()
	assert_eq(int(state["section_version"]), 1, "C-25: sections version themselves")
	assert_eq(str(state["overlay"]), "power")
	assert_eq(str((state["settings"] as Dictionary)["graphics"]), "high")

	root.overlay_rail.select(OverlayModel.MODE_NONE)
	root.settings_sheet.model.set_value("graphics", "performance")
	root.restore_ui_state(state)
	assert_eq(root.overlay_rail.active_mode(), &"power")
	assert_eq(str(root.settings_sheet.model.value("graphics")), "high")
	assert_eq(root.settings_sheet.value_button("graphics").text, "High",
			"the sheet re-rendered, not just the model")
	_unmount(mounted)


# ===========================================================================
# PA-58 — the Gameplay rows, and the follow mode they turn on
# ===========================================================================

func test_the_gameplay_defaults_finally_have_rows_and_readers() -> void:
	# `invert_pan`, `follow_dispatched_unit` and `rotation_mode` were authored in
	# `data/ui.json.defaults` with no `settings.rows` entry and no reader:
	# `grep -rn 'set_follow_target\|clear_follow' ui/ game/ | grep -v 'func '`
	# found nothing at all.
	var model := SettingsModel.new(_cfg())
	var defaults := _cfg().section("defaults")
	for key: String in ["follow_dispatched_unit", "invert_pan", "rotation_mode"]:
		assert_true(model.has_key(key), "%s is a row" % key)
	assert_eq(model.value_bool("follow_dispatched_unit"),
			bool(defaults["follow_dispatched_unit"]),
			"the row boots at the authored default, not a second copy")
	assert_eq(model.value_bool("invert_pan"), bool(defaults["invert_pan"]))
	# The rotation ladder's default is doc 12's own camera block — the same key
	# `CameraState.setup()` boots from, so the row and the camera cannot disagree.
	assert_eq(str(model.value("rotation_mode")),
			str(_cfg().camera()["rotation_mode_default"]))
	var camera := CameraState.load_from_files()
	assert_eq(camera.rotation_mode,
			CameraState.rotation_mode_from_string(str(model.value("rotation_mode"))))


func test_the_two_camera_rows_reach_the_camera_on_the_tap() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var camera := CameraState.load_from_files()
	root.bind_camera(camera)
	assert_false(camera.invert_pan, "the shipped default")

	root.settings_sheet.value_button("invert_pan").pressed.emit()
	assert_true(camera.invert_pan, "live on the next touch, not one frame later")

	var before := camera.rotation_mode
	root.settings_sheet.value_button("rotation_mode").pressed.emit()
	assert_true(camera.rotation_mode != before, "the ladder walked and the camera followed")
	for option: Variant in root.settings_sheet.model.options("rotation_mode"):
		assert_true(CameraState.rotation_mode_from_string(str(option))
				!= CameraState.RotationMode.SNAP45 or str(option) == "snap45",
				"%s is a real RotationMode and not a fallback" % option)
	_unmount(mounted)


func test_a_camera_bound_after_the_rows_still_gets_them() -> void:
	# The ordering bug this guards: `game/main.gd` restores the `ui` section and
	# then binds the camera, so a camera that only listened for CHANGES would
	# boot on the data default and ignore the player until they tapped the row.
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	root.settings_sheet.model.set_value("invert_pan", true)
	root.settings_sheet.model.set_value("rotation_mode", "locked")
	var camera := CameraState.load_from_files()
	root.bind_camera(camera)
	assert_true(camera.invert_pan)
	assert_eq(camera.rotation_mode, CameraState.RotationMode.LOCKED)
	_unmount(mounted)


func test_inverted_pan_moves_the_same_distance_the_other_way() -> void:
	# The 1:1 world lock cannot hold both ways — it is what makes the DEFAULT
	# exact. So the inverted path preserves the magnitude and flips the sign,
	# which is the only part of it that is a preference.
	var viewport := Vector2(360.0, 800.0)
	var from := Vector2(180.0, 400.0)
	var to := Vector2(240.0, 400.0)

	var normal := CameraState.load_from_files()
	normal.set_focus(Vector3(400.0, 0.0, 400.0))
	var start := normal.focus
	normal.begin_pan(from, viewport)
	normal.update_pan(to, viewport)
	normal.end_pan()
	var moved := normal.focus - start

	var inverted := CameraState.load_from_files()
	inverted.invert_pan = true
	inverted.set_focus(Vector3(400.0, 0.0, 400.0))
	inverted.begin_pan(from, viewport)
	inverted.update_pan(to, viewport)
	inverted.end_pan()
	var moved_back := inverted.focus - start

	assert_true(moved.length() > 1.0, "the control arm actually panned")
	assert_true(is_equal_approx(moved.length(), moved_back.length()),
			"same distance: %.3f vs %.3f" % [moved.length(), moved_back.length()])
	assert_true(moved.dot(moved_back) < 0.0, "…and the opposite direction")


func test_the_follow_chip_is_the_modes_own_off_switch() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	assert_false(root.follow_chip_shown(), "no mode, no chip")

	var name := UnitPickerModel.unit_name_for(root.config, 12, "heavy_repair")
	assert_eq(name, "Heavy Repair 12", "one spelling of a unit's name, not two")
	root.present_follow_chip(name)
	assert_true(root.follow_chip_shown())
	assert_true(root.follow_chip.chip_button().text.contains(name),
			"the chip says which unit, or it is a mystery light")

	# An Array, not an int: a GDScript lambda captures a local by VALUE.
	var cancels: Array = []
	root.follow_cancelled.connect(func() -> void: cancels.append(true))
	root.follow_chip.chip_button().pressed.emit()
	assert_eq(cancels.size(), 1, "the ✕ asks the shell to stop following")
	assert_false(root.follow_chip_shown())
	_unmount(mounted)


func test_the_chip_yields_the_column_while_the_overlay_strip_is_over_it() -> void:
	# §2.23's ruling, applied to the left column: a target under a panel is a
	# target nobody can reach, and the follow keeps running either way.
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	root.present_follow_chip("Engine 1")
	assert_true(root.follow_chip_shown())
	root.overlay_rail.open()
	root.solve_follow_chip()
	assert_false(root.follow_chip_shown(), "the strip reaches 300 dp up this column")
	root.overlay_rail.close()
	root.solve_follow_chip()
	assert_true(root.follow_chip_shown(), "…and the chip comes back with the column")
	_unmount(mounted)


# ===========================================================================
# PA-59 — the auto-response row with nothing behind it
# ===========================================================================

func test_no_settings_row_writes_a_key_the_sim_never_reads() -> void:
	# `auto_spend_contractor` was a `policy: dispatch` toggle that wrote a flag
	# `DispatchPolicy` stores and no code consults, because there is no
	# contractor unit to hire (doc 06 line 1749). A control the sim never reads
	# is a control that lies about what the player just did.
	var model := SettingsModel.new(_cfg())
	assert_false(model.keys().has("auto_spend_contractor"),
			"the row is withdrawn until there is a unit behind it")
	assert_false(model.policy_keys(SettingsModel.POLICY_DISPATCH)
			.has("auto_spend_contractor"), "…and it seeds nothing from the sim")


func test_a_withdrawn_row_is_not_an_unknown_key() -> void:
	# The distinction PA-59 asks for in its own words: "keep the key and default
	# so saves stay valid". A save written while the control existed still
	# restores clean, and doc 06 still owns the number.
	var model := SettingsModel.new(_cfg())
	assert_true(model.retired_keys().has("auto_spend_contractor"))
	var dropped := model.restore_state({
		"auto_spend_contractor": true,   # written by a build that had the row
		"favourite_colour": "teal",      # never a row at all
	})
	assert_eq(str(dropped), "[\"favourite_colour\"]",
			"the withdrawn key is ignored in silence; the unknown one is reported")
	var policy: Dictionary = _cfg().dispatch_policy_defaults()
	assert_true(policy.has("auto_spend_contractor"),
			"doc 06 still carries the default, so the sim is unchanged")


# ===========================================================================
# PA-14 · A91-D-69 — S10's permission row and the rationale modal
# ===========================================================================

func test_the_permission_row_reports_a_state_and_never_stores_one() -> void:
	var model := SettingsModel.new(_cfg())
	assert_eq(model.kind(UIRoot.PERMISSION_ROW), SettingsModel.KIND_STATE)
	assert_eq(str(model.value(UIRoot.PERMISSION_ROW)), "unavailable",
			"off Android there is no permission to hold, and the row says so")
	assert_false(model.is_device_scoped(UIRoot.PERMISSION_ROW),
			"there is nothing to remember: the platform re-answers every time")
	assert_false(model.capture_state().has(UIRoot.PERMISSION_ROW),
			"a report is not a preference — it never enters a save")
	# …and a save that carries one anyway is ignored rather than obeyed — while
	# what the PLATFORM last reported survives the reset, because a load or a
	# New City must never put "Not available" in front of a player whose
	# notifications are on until the shell happens to re-report.
	model.set_value(UIRoot.PERMISSION_ROW, "on")
	model.restore_state({UIRoot.PERMISSION_ROW: "blocked"})
	assert_eq(str(model.value(UIRoot.PERMISSION_ROW)), "on",
			"the save was ignored and the reported state was kept")


func test_every_permission_state_reads_as_a_sentence_and_only_one_offers_a_route()\
		-> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var seen: Array[String] = []
	for token: String in ["on", "off", "blocked", "unavailable"]:
		root.set_permission_state(token)
		var text := root.settings_sheet.value_button(UIRoot.PERMISSION_ROW).text
		assert_false(text.begins_with("ui_"), "%s has copy" % token)
		assert_false(seen.has(text), "%s reads differently from the others" % token)
		seen.append(text)
	assert_true(seen[1].to_lower().contains("tap"),
			"`off` is the state that invites a tap")
	assert_true(seen[2].to_lower().contains("settings"),
			"`blocked` names the only route Android has left")
	_unmount(mounted)


func test_tapping_the_permission_row_asks_the_shell_instead_of_cycling() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	root.set_permission_state("off")
	var asked: Array = []
	root.settings_action.connect(func(key: StringName, action: StringName) -> void:
		asked.append([String(key), String(action)]))
	var changed: Array = []
	root.settings_changed.connect(func(key: StringName, _v: Variant) -> void:
		changed.append(String(key)))

	root.settings_sheet.value_button(UIRoot.PERMISSION_ROW).pressed.emit()
	assert_eq(str(asked), '[["notification_permission", "permission"]]')
	assert_eq(str(changed), "[]",
			"nothing CHANGED — a listener that acts on settings_changed must not fire")
	assert_eq(root.permission_state(), "off",
			"…and the tap did not cycle the row to the next token")
	_unmount(mounted)


func test_the_rationale_modal_carries_the_reasons_copy_and_joins_the_back_stack()\
		-> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	assert_false(root.present_permission_rationale(""),
			"no reason, no modal — `should_prompt` said no")

	assert_true(root.present_permission_rationale(PermissionSheet.REASON_FIRST))
	assert_true(root.permission_rationale_open())
	var first := (root.permission_sheet.get_node("Panel/Body/Title") as Label).text
	assert_false(first.begins_with("ui_"), "the first-ask copy resolves")
	assert_eq(root.back_context(0.0)["modal_open"], true,
			"a modal on the modal layer is the back stack's first rung")

	root.present_permission_rationale(PermissionSheet.REASON_MISSED_P1)
	var second := (root.permission_sheet.get_node("Panel/Body/Title") as Label).text
	assert_true(second != first,
			"'You missed a citywide blackout' is a different sentence from the first ask")
	_unmount(mounted)


func test_back_costs_nothing_and_the_two_buttons_each_cost_a_chance() -> void:
	# The asymmetry doc 13 §2.7 depends on: NOT NOW is an ANSWER and spends one
	# of Android's two chances; BACK is "close the thing in front of me" (doc 12
	# §2.2) and spends none. Getting this wrong burns a permission silently.
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var answers: Array = []
	root.permission_answered.connect(func(ok: bool) -> void: answers.append(ok))

	root.present_permission_rationale(PermissionSheet.REASON_FIRST)
	assert_eq(root.handle_back(0.0), UIRoot.BACK_CLOSE_MODAL)
	assert_false(root.permission_rationale_open(), "BACK closed it")
	assert_eq(str(answers), "[]", "…and answered nothing")

	root.present_permission_rationale(PermissionSheet.REASON_FIRST)
	root.permission_sheet.decline_button().pressed.emit()
	assert_eq(str(answers), "[false]")
	assert_false(root.permission_rationale_open())

	root.present_permission_rationale(PermissionSheet.REASON_FIRST)
	root.permission_sheet.accept_button().pressed.emit()
	assert_eq(str(answers), "[false, true]")
	_unmount(mounted)


# ===========================================================================
# PA-15 · A91-D-70 — `user://settings.cfg`, the file that is not in a save
# ===========================================================================

## A fresh path per test, so two methods in this file cannot read each other's
## file and the suite's `UserDirIsolation` keeps it off the developer's own.
var _device_seq := 0


func _device_path() -> String:
	_device_seq += 1
	return "user://test_settings_%d.cfg" % _device_seq


func test_the_device_file_round_trips_only_the_device_scoped_rows() -> void:
	var path := _device_path()
	var model := SettingsModel.new(_cfg())
	model.set_value("text_scale", 1.3)
	model.set_value("notifications_enabled", false)
	model.set_value("replay_tutorial", true)   # city-scoped: a door into THIS city
	assert_true(model.save_device(path))

	var stored := DeviceSettings.read_section(path, DeviceSettings.SECTION_SETTINGS)
	assert_true(stored.has("text_scale"), "an accessibility row is the device's")
	assert_false(stored.has("replay_tutorial"),
			"the tutorial door belongs to the city, not the phone")
	assert_eq(stored.size(), model.device_scoped_keys().size(),
			"every device-scoped row is written, and nothing else is")

	# A second model — a relaunch, or the next city — sees the same answers.
	var fresh := SettingsModel.new(_cfg())
	assert_eq(fresh.value_num("text_scale"), 1.0, "…before it reads the file")
	assert_eq(str(fresh.load_device(path)), "[]", "nothing dropped")
	assert_eq(fresh.value_num("text_scale"), 1.3)
	assert_false(fresh.value_bool("notifications_enabled"))
	assert_false(fresh.value_bool("replay_tutorial"), "and the door stayed shut")


func test_the_device_copy_outranks_a_citys_saved_block() -> void:
	# Doc 12 §3.2: "on load `settings.cfg` wins for those keys". The failure this
	# pins is the one a player notices: a city saved at 100 % text scale putting
	# their 130 % back every single time they load it.
	var path := _device_path()
	var device := SettingsModel.new(_cfg())
	device.set_value("text_scale", 1.3)
	device.set_value("graphics", "performance")
	assert_true(device.save_device(path))

	var model := SettingsModel.new(_cfg())
	model.load_device(path)
	var dropped := model.restore_state({"text_scale": 1.0, "graphics": "high",
			"in_app_banners": false})
	assert_eq(str(dropped), "[]")
	assert_eq(model.value_num("text_scale"), 1.3, "the device wins")
	assert_eq(str(model.value("graphics")), "performance")
	assert_false(model.value_bool("in_app_banners"),
			"…and a city-scoped row still comes from the city")


func test_a_settings_change_survives_the_city_that_was_deleted() -> void:
	# PA-15's own acceptance test, spelled the way the audit spells it: change
	# text scale, delete the city, relaunch, the scale survives.
	var path := _device_path()
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	root.settings_sheet.model.load_device(path)
	root.settings_sheet.value_button("text_scale").pressed.emit()   # one tap
	var chosen: float = root.settings_sheet.model.value_num("text_scale")
	assert_true(chosen != 1.0, "the tap moved the row")
	assert_true(FileAccess.file_exists(path), "the tap COMMITTED it")

	# The city goes away and a new one is founded over the same shell.
	root.set_permission_state("on")
	root.reset_ui_state_for_new_city()
	assert_eq(root.settings_sheet.model.value_num("text_scale"), chosen,
			"New City does not reset the phone's accessibility settings")
	assert_eq(root.permission_state(), "on",
			"…and it does not tell the player their notifications went away either")

	# …and a whole new process comes up on the same device file.
	var relaunched := _mount()
	var fresh: UIRoot = relaunched["root"]
	assert_eq(fresh.settings_sheet.model.value_num("text_scale"), 1.0,
			"before the read, the model is on data defaults")
	fresh.load_device_settings(path)
	assert_eq(fresh.settings_sheet.model.value_num("text_scale"), chosen)
	assert_eq(fresh.settings_sheet.value_button("text_scale").text,
			root.settings_sheet.value_button("text_scale").text,
			"the sheet re-rendered from the file, not just the model")
	_unmount(relaunched)
	_unmount(mounted)


func test_a_nonsense_device_file_costs_preferences_and_never_the_launch() -> void:
	var path := _device_path()
	DeviceSettings.write_section(path, DeviceSettings.SECTION_SETTINGS, {
		"text_scale": "enormous",          # wrong type for a choice row
		"replay_tutorial": true,           # real row, but not device-scoped
		"favourite_colour": "teal",        # no row at all
	})
	var model := SettingsModel.new(_cfg())
	var dropped := model.load_device(path)
	assert_eq(str(dropped), "[\"favourite_colour\", \"replay_tutorial\", \"text_scale\"]",
			"every refusal is reported, sorted, and none of them threw")
	assert_eq(model.value_num("text_scale"), 1.0, "the default is kept")
	assert_false(model.value_bool("replay_tutorial"))


func test_two_owners_share_one_file_without_overwriting_each_other() -> void:
	# doc 08 §2.5: docs 08, 11, 12 and 13 all write into this one file. The
	# permission block and the settings block are written by different classes
	# at different moments, and a write of either must leave the other standing.
	var path := _device_path()
	var model := SettingsModel.new(_cfg())
	model.set_value("notifications_enabled", false)
	assert_true(model.save_device(path))

	var flow := PermissionFlow.new(null)
	flow.asked_count = 2
	flow.last_asked_unix = 1_700_000_000
	flow.reprompt_count = 1
	assert_true(flow.save_device(path))

	assert_false(bool(DeviceSettings.read_section(path,
			DeviceSettings.SECTION_SETTINGS)["notifications_enabled"]),
			"the permission write left the settings block alone")
	model.set_value("notifications_enabled", true)
	assert_true(model.save_device(path))
	var back := PermissionFlow.new(null)
	back.load_device(path)
	assert_eq(back.asked_count, 2, "…and the settings write left the permission block alone")
	assert_eq(back.last_asked_unix, 1_700_000_000)
	assert_eq(back.reprompt_count, 1)


func test_the_device_write_is_atomic_and_leaves_no_temporary_behind() -> void:
	var path := _device_path()
	var model := SettingsModel.new(_cfg())
	assert_true(model.save_device(path))
	assert_true(FileAccess.file_exists(path))
	assert_false(FileAccess.file_exists(path + ".tmp"),
			"tmp+rename: the half-written file never has the real name")


# ===========================================================================
# The stub — exactly `game/save_service.gd`'s published API, nothing more
# ===========================================================================

class StubSaveService extends RefCounted:
	var slots: Dictionary = {}
	var fail := false
	var saves := 0
	var loads := 0
	var deletes := 0
	var autosaves := 0

	func save_slot(_sim: Variant, slot: int) -> Dictionary:
		if fail:
			return {}
		saves += 1
		var meta := {"slot": slot, "saved_at_unix": 1755500000 + slot,
				"day_index": 3, "population": 184291, "treasury": 8420000}
		slots[slot] = meta
		return meta

	func load_slot(_sim: Variant, slot: int) -> bool:
		if fail or not slots.has(slot):
			return false
		loads += 1
		return true

	func list_slots() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		var keys: Array = slots.keys()
		keys.sort()
		for key: Variant in keys:
			out.append((slots[key] as Dictionary).duplicate())
		return out

	func delete_slot(slot: int) -> bool:
		if fail or not slots.has(slot):
			return false
		slots.erase(slot)
		deletes += 1
		return true

	func autosave(sim: Variant) -> void:
		autosaves += 1
		save_slot(sim, 0)
