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
