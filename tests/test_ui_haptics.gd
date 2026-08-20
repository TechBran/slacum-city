extends SimTest
## The last three UX rows doc 91 §15 item 16 and D-11 left open, together
## because they are one shape of work: a control that exists in a data file and
## reaches nothing.
##
##   * **§2.14 haptics** — `data/ui.json.haptics_ms` shipped with the durations
##     and no code in `ui/` or `game/` ever called a vibrator.
##   * **§2.13 auto-response policies** (D-11) — `DispatchPolicy` had no UI, so
##     `auto_dispatch_*` was stuck at whatever `data/dispatch.json` booted with.
##   * **§2.13's progression moment** — `city_level_changed` reached the player
##     as one alert row and nothing else: no toast, no reveal of what it
##     unlocked, and the toast surface itself was drawn by nobody.
##
## The rule this file exists to hold is the one that makes a haptic an
## accessibility feature rather than a nuisance: **`reduce_motion` silences it**
## (A8), and it does so as a suppression, so switching the row back off restores
## the player's own `haptics` choice rather than a default.


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _recorder(haptics: Haptics) -> Array:
	var log: Array = []
	haptics.vibrator = func(ms: int) -> void: log.append(ms)
	return log


# ===========================================================================
# §2.14 — the table, the levels, the gate
# ===========================================================================

func test_the_seven_cues_are_exactly_what_the_data_file_carries() -> void:
	# A cue this class knows and the table does not is a silent buzz; a cue the
	# table carries and this class does not is copy nobody can fire.
	var section := _cfg().section(Haptics.SECTION)
	for level: String in ["light", "full"]:
		var table: Dictionary = section[level]
		assert_eq(table.size(), Haptics.CUES.size(), "%s table size" % level)
		for cue: StringName in Haptics.CUES:
			assert_true(table.has(String(cue)), "%s carries %s" % [level, cue])


func test_the_doc_table_is_read_and_not_restated() -> void:
	var cfg := _cfg()
	var haptics := Haptics.new(cfg)
	var light: Dictionary = cfg.section(Haptics.SECTION)["light"]
	var full: Dictionary = cfg.section(Haptics.SECTION)["full"]
	haptics.level = Haptics.LEVEL_LIGHT
	for cue: StringName in Haptics.CUES:
		assert_eq(haptics.duration_ms(cue), int(light[String(cue)]), String(cue))
	haptics.level = Haptics.LEVEL_FULL
	for cue: StringName in Haptics.CUES:
		assert_eq(haptics.duration_ms(cue), int(full[String(cue)]), String(cue))


func test_light_is_silent_for_the_cues_the_doc_zeroes() -> void:
	# §2.14's light column is 0 for button, tile snap and rotation snap on
	# purpose: the default level buzzes only for the four that carry information.
	var haptics := Haptics.new(_cfg())
	assert_eq(haptics.level, Haptics.LEVEL_LIGHT, "data/ui.json.defaults.haptics")
	assert_eq(haptics.duration_ms(Haptics.CUE_BUTTON), 0)
	assert_eq(haptics.duration_ms(Haptics.CUE_SNAP_TILE), 0)
	assert_eq(haptics.duration_ms(Haptics.CUE_ROTATION_SNAP), 0)
	assert_true(haptics.duration_ms(Haptics.CUE_BLOCKED) > 0)
	assert_true(haptics.duration_ms(Haptics.CUE_ESCALATE) > 0)
	assert_true(haptics.duration_ms(Haptics.CUE_POWER_RESTORED) > 0)
	assert_true(haptics.duration_ms(Haptics.CUE_DISPATCH) > 0)


func test_off_silences_everything() -> void:
	var haptics := Haptics.new(_cfg())
	var log := _recorder(haptics)
	haptics.level = Haptics.LEVEL_OFF
	for cue: StringName in Haptics.CUES:
		assert_eq(haptics.fire(cue), 0, String(cue))
	assert_eq(log.size(), 0, "the vibrator is never reached")


func test_reduce_motion_silences_haptics_without_forgetting_the_choice() -> void:
	# A8: a vibration is the most literal motion a phone can make. This is the
	# rule that makes the whole feature safe to default ON.
	var haptics := Haptics.new(_cfg())
	var log := _recorder(haptics)
	haptics.level = Haptics.LEVEL_FULL
	assert_true(haptics.fire(Haptics.CUE_BLOCKED) > 0)
	haptics.apply_setting(Haptics.SETTING_REDUCE_MOTION, true)
	assert_eq(haptics.fire(Haptics.CUE_BLOCKED), 0, "reduce_motion silences it")
	assert_eq(haptics.level, Haptics.LEVEL_FULL, "and does not change the row")
	haptics.apply_setting(Haptics.SETTING_REDUCE_MOTION, false)
	assert_true(haptics.fire(Haptics.CUE_BLOCKED) > 0, "the choice comes back")
	assert_eq(log.size(), 2)


func test_an_unknown_level_is_off_rather_than_a_guess() -> void:
	# A settings block from a build that spelled it differently must not become
	# `full` on somebody's phone.
	assert_eq(Haptics.normalize_level("FULL"), Haptics.LEVEL_FULL, "case is forgiven")
	assert_eq(Haptics.normalize_level("gentle"), Haptics.LEVEL_OFF)
	assert_eq(Haptics.normalize_level(null), Haptics.LEVEL_OFF)


func test_apply_setting_claims_only_its_own_two_rows() -> void:
	var haptics := Haptics.new(_cfg())
	assert_true(haptics.apply_setting(Haptics.SETTING_LEVEL, "full"))
	assert_true(haptics.apply_setting(Haptics.SETTING_REDUCE_MOTION, true))
	assert_false(haptics.apply_setting(&"graphics", "high"))


func test_the_settings_row_exists_and_cycles_the_three_levels() -> void:
	var model := SettingsModel.new(_cfg())
	assert_true(model.has_key("haptics"))
	assert_eq(model.kind("haptics"), SettingsModel.KIND_CHOICE)
	assert_eq(model.options("haptics"), ["off", "light", "full"])
	assert_eq(str(model.value("haptics")), "light")
	assert_eq(model.value_text("haptics"), "Light", "the row shows a word, not a key")
	model.cycle("haptics")
	assert_eq(str(model.value("haptics")), "full")
	assert_eq(model.value_text("haptics"), "Full")


# ===========================================================================
# §2.14 wired to the screens that fire it
# ===========================================================================

func _mount() -> UIRoot:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	root.config = UIConfig.load_from_files()
	_tree().root.add_child(root)
	root.initialize()
	return root


func _unmount(root: UIRoot) -> void:
	_tree().root.remove_child(root)
	root.free()


func test_the_root_owns_one_gate_and_hands_it_to_the_screens() -> void:
	var root := _mount()
	assert_ne(root.haptics, null)
	assert_eq(root.build_sheet.haptics, root.haptics, "one instance, not three")
	assert_eq(root.land_panel.haptics, root.haptics)
	_unmount(root)


func test_the_settings_row_reaches_the_gate_the_moment_it_is_tapped() -> void:
	var root := _mount()
	root.haptics.level = Haptics.LEVEL_LIGHT
	root.settings_sheet.value_button("haptics").pressed.emit()
	assert_eq(root.haptics.level, Haptics.LEVEL_FULL,
			"no shell round trip: the row and the gate are one tap apart")
	root.settings_sheet.value_button("reduce_motion").pressed.emit()
	assert_true(root.haptics.reduce_motion)
	assert_eq(root.haptics.duration_ms(Haptics.CUE_BLOCKED), 0)
	_unmount(root)


func test_a_refused_placement_buzzes_and_a_committed_one_taps() -> void:
	var sim := CitySim.boot_from_files()
	var root := _mount()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	root.build_sheet.setup(root.config, controller)
	root.build_sheet.haptics = root.haptics
	root.haptics.level = Haptics.LEVEL_FULL
	var log := _recorder(root.haptics)
	# A card that the city level locks out is a refusal with no placement at all.
	var locked := ""
	for card: Dictionary in controller.cards():
		if bool(card["locked"]):
			locked = str(card["archetype"])
			break
	if locked != "":
		root.build_sheet.open()
		root.build_sheet._on_card_pressed(locked, "")
		assert_eq(root.haptics.last_cue, Haptics.CUE_BLOCKED)
	# And a real commit taps.
	sim.treasury.balance = 5_000_000
	root.build_sheet.open()
	root.build_sheet.select_category("residential")
	root.build_sheet.card_button("house").pressed.emit()
	var tile := _valid_tile(controller)
	root.build_sheet.move_ghost(Vector3(float(tile.x) * controller.tile_m + 4.0, 0.0,
			float(tile.y) * controller.tile_m + 4.0))
	root.build_sheet.confirm_placement()
	assert_eq(root.haptics.last_cue, Haptics.CUE_BUTTON)
	assert_true(log.size() > 0)
	_unmount(root)


func _valid_tile(controller: BuildController) -> Vector2i:
	for z in range(0, TileGrid.SIZE):
		for x in range(0, TileGrid.SIZE):
			var tile := Vector2i(x, z)
			if StringName(str(controller.evaluate(tile).get("verdict", ""))) \
					== BuildController.VERDICT_VALID:
				return tile
	return Vector2i(40, 40)


func test_a_p1_event_and_a_relight_each_fire_once_per_batch() -> void:
	# A batch that carries eight failures is one thing that happened, not eight.
	var root := _mount()
	root.haptics.level = Haptics.LEVEL_FULL
	var log := _recorder(root.haptics)
	root.set_alert_locator(func(_kind: StringName, _id: Variant) -> Variant:
		return Vector3.ZERO)
	root.feed_events([
		{"type": "BlockDarkChanged", "block_id": "Harbour", "block_dark": true},
		{"type": "BlockDarkChanged", "block_id": "Millpond", "block_dark": true},
	])
	assert_eq(log.size(), 1, "two P1 rows, one buzz")
	assert_eq(int(log[0]), root.haptics.duration_ms(Haptics.CUE_ESCALATE))
	log.clear()
	root.feed_events([{"type": "BlockDarkChanged", "block_id": "Harbour",
			"block_dark": false}])
	assert_eq(log.size(), 1, "the relight is its own cue")
	assert_eq(int(log[0]), root.haptics.duration_ms(Haptics.CUE_POWER_RESTORED))
	_unmount(root)


# ===========================================================================
# §2.13 auto-response rows (doc 91 D-11)
# ===========================================================================

func test_every_policy_row_names_a_key_the_sim_actually_has() -> void:
	# A row addressing a policy `DispatchPolicy` does not carry would be a
	# control that silently does nothing — `cmd_set_dispatch_policy` refuses it.
	var sim := CitySim.boot_from_files()
	var model := SettingsModel.new(_cfg())
	var keys := model.policy_keys(SettingsModel.POLICY_DISPATCH)
	assert_true(keys.size() >= 7, "§2.13's auto-response block is on the sheet")
	for key: String in keys:
		assert_true(bool(sim.cmd_set_dispatch_policy(key,
				sim.incidents.dispatch.policy.get_value(key))["ok"]),
				"%s is a real DispatchPolicy key" % key)


func test_policy_defaults_come_from_doc_06s_own_file() -> void:
	var cfg := _cfg()
	var model := SettingsModel.new(cfg)
	var defaults := cfg.dispatch_policy_defaults()
	assert_false(defaults.is_empty(), "data/dispatch.json is readable from ui/")
	for key: String in model.policy_keys(SettingsModel.POLICY_DISPATCH):
		assert_true(defaults.has(key), "%s has a doc 06 default" % key)
		assert_eq(SettingsModel._same_option(model.value(key), defaults[key]), true,
				"%s boots at doc 06's value, not a second copy" % key)


func test_a_policy_row_writes_the_sim_and_the_sim_seeds_the_row() -> void:
	var sim := CitySim.boot_from_files()
	var root := _mount()
	# The sim was not booted at the data defaults — a loaded city may have moved.
	sim.cmd_set_dispatch_policy("auto_dispatch_fire", false)
	root.bind_dispatch_policy(sim.cmd_set_dispatch_policy,
			sim.incidents.dispatch.policy.serialize())
	assert_false(root.settings_sheet.model.value_bool("auto_dispatch_fire"),
			"the row shows the CITY's policy, not the file's default")
	root.settings_sheet.value_button("auto_dispatch_fire").pressed.emit()
	assert_true(sim.incidents.dispatch.policy.get_bool("auto_dispatch_fire"),
			"and a tap reaches cmd_set_dispatch_policy")
	assert_true(bool(root.dispatch_policy_values()["auto_dispatch_fire"]))
	_unmount(root)


func test_a_stale_ui_block_cannot_overwrite_the_citys_policy() -> void:
	# The policy lives in the city's save, not the UI's. A restored `ui.settings`
	# block carries a copy of the rows, and it must lose.
	var sim := CitySim.boot_from_files()
	var root := _mount()
	sim.cmd_set_dispatch_policy("auto_dispatch_fire", false)
	root.bind_dispatch_policy(sim.cmd_set_dispatch_policy,
			sim.incidents.dispatch.policy.serialize())
	root.restore_ui_state({"settings": {"auto_dispatch_fire": true}})
	assert_false(root.settings_sheet.model.value_bool("auto_dispatch_fire"),
			"the sim wins over a restored UI copy")
	assert_false(sim.incidents.dispatch.policy.get_bool("auto_dispatch_fire"))
	_unmount(root)


func test_the_money_row_reads_as_money_and_the_ladder_covers_the_docs_range() -> void:
	var model := SettingsModel.new(_cfg())
	var options := model.options("auto_repair_cost_cap")
	assert_eq(int(options[0]), 0, "§2.13's slider starts at $0")
	assert_eq(int(options[options.size() - 1]), 250000, "and ends at $250K")
	model.set_value("auto_repair_cost_cap", 25000)
	assert_eq(model.value_text("auto_repair_cost_cap"), "$25,000",
			"a ceiling is a sum, not a bare integer")


func test_every_row_on_the_sheet_still_has_copy() -> void:
	# Eight new rows landed here; §3.1's rule is that every one of them has a
	# name, and A14's is that a row whose effect is not obvious explains itself.
	var cfg := _cfg()
	var model := SettingsModel.new(cfg)
	for row: Dictionary in model.rows():
		assert_true(cfg.has_string(str(row["label_key"])),
				"%s has a name" % row["label_key"])
		if str(row["hint_key"]) != "":
			assert_true(cfg.has_string(str(row["hint_key"])),
					"%s has its note" % row["hint_key"])
		if str(row["policy"]) == SettingsModel.POLICY_DISPATCH:
			assert_ne(str(row["hint_key"]), "",
					"%s says what it does (A14)" % row["key"])


# ===========================================================================
# §2.13's progression moment + §2.15's toast surface
# ===========================================================================

func test_a_city_level_raises_a_toast_on_a_surface_that_exists() -> void:
	# The toast *budget* has been in the deck since Wave 2 and nothing drew one.
	var root := _mount()
	assert_ne(root.toast_view, null, "ToastLayer has a view on it")
	assert_false(root.toast_view.is_open())
	root.set_city_level(2)
	root.feed_events([{"type": "city_level_changed", "from": 2, "to": 3}])
	assert_true(root.toast_view.is_open())
	assert_true(root.toast_view.text().contains("3"),
			"the toast names the level: %s" % root.toast_view.text())
	assert_false(root.toast_view.text().contains("{"))
	_unmount(root)


func test_the_moment_fires_once_and_never_on_attach() -> void:
	var root := _mount()
	var seen: Array = []
	root.city_level_changed.connect(func(level: int, _unlocked: PackedStringArray) -> void:
		seen.append(level))
	# First reading: the shell attached to a city already at level 3.
	root.feed_events([{"type": "city_level_changed", "from": 2, "to": 3}])
	assert_eq(seen.size(), 0, "attaching to a level is not levelling up")
	root.feed_events([{"type": "city_level_changed", "from": 3, "to": 4}])
	assert_eq(seen, [4])
	root.feed_events([{"type": "city_level_changed", "from": 3, "to": 4}])
	assert_eq(seen, [4], "a replayed batch does not celebrate twice")
	_unmount(root)


func test_a_new_level_marks_the_cards_it_just_unlocked() -> void:
	var sim := CitySim.boot_from_files()
	var root := _mount()
	root.build_sheet.setup(root.config,
			BuildController.new(sim, RequirementFormatter.new(root.config)))
	# Whatever level the catalogue actually gates something at — asked, not named.
	var level := 0
	for card: Dictionary in root.build_sheet.cards():
		if int(card["min_city_level"]) > 0:
			level = int(card["min_city_level"])
			break
	assert_true(level > 0, "doc 02 gates at least one archetype on city level")
	sim.progression.city_level = level
	root.set_city_level(level - 1)
	# The sheet is closed: the reveal is held, not lost.
	var announced: Array = []
	root.city_level_changed.connect(func(_l: int, ids: PackedStringArray) -> void:
		announced.append(ids))
	root.feed_events([{"type": "city_level_changed", "from": level - 1, "to": level}])
	assert_true((announced[0] as PackedStringArray).size() > 0,
			"level %d unlocked something" % level)
	assert_eq(root.build_sheet.pending_unlocks(),
			announced[0] as PackedStringArray, "held until the player looks")
	assert_eq(root.build_sheet.pulsing_ids().size(), 0, "nothing pulses off screen")
	root.build_sheet.open()
	var revealed := root.build_sheet.pulsing_ids()
	assert_true(revealed.size() > 0, "the sheet marked what level %d opened" % level)
	assert_eq(root.build_sheet.pending_unlocks().size(), 0, "and the debt is paid")
	for id: String in revealed:
		assert_eq(int(_card_of(root.build_sheet, id)["min_city_level"]), level,
				"only the cards THIS level unlocked, not every unlocked card")
	_unmount(root)


func test_reduce_motion_gets_the_unlock_without_the_animation() -> void:
	# A8 again: the sheet still rebuilds and the toast still lands; only the
	# pulse is dropped.
	var sim := CitySim.boot_from_files()
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	root.config = UIConfig.load_from_files()
	(root.config.ui_data()["defaults"] as Dictionary)["reduce_motion"] = true
	_tree().root.add_child(root)
	root.initialize()
	root.build_sheet.setup(root.config,
			BuildController.new(sim, RequirementFormatter.new(root.config)))
	var level := 0
	for card: Dictionary in root.build_sheet.cards():
		if int(card["min_city_level"]) > 0:
			level = int(card["min_city_level"])
			break
	sim.progression.city_level = level
	root.set_city_level(level - 1)
	root.build_sheet.open()
	root.feed_events([{"type": "city_level_changed", "from": level - 1, "to": level}])
	assert_eq(root.build_sheet.pulsing_ids().size(), 0, "no motion")
	assert_true(root.toast_view.is_open(), "but the player is still told")
	assert_false(root.build_sheet.card_button(_first_unlocked(root.build_sheet, level))
			== null, "and the card is on the sheet, unlocked and tappable")
	_tree().root.remove_child(root)
	root.free()


func _first_unlocked(sheet: BuildSheet, level: int) -> String:
	for card: Dictionary in sheet.cards():
		if int(card["min_city_level"]) == level:
			return str(card["id"])
	return ""


func _card_of(sheet: BuildSheet, id: String) -> Dictionary:
	for card: Dictionary in sheet.cards():
		if str(card["id"]) == id:
			return card
	return {}


func test_a_degraded_banner_lands_on_the_toast_surface() -> void:
	# §2.13's gate turns a banner it cannot afford into a toast, and until now
	# that toast was budgeted, recorded and shown to nobody.
	var root := _mount()
	for i in 8:
		root.hud.push_alert({"id": "p3_%d" % i, "class": "p3",
				"event_type": "routine_%d" % i, "title": "Routine %d" % i}, float(i))
	assert_true(root.toast_view.is_open(),
			"the gate's overflow reached a surface a player can see")
	_unmount(root)
