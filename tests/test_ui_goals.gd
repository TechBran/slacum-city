extends SimTest
## Doc 12 §2.18 — S14, the goals chip and the goals sheet.
##
## The sheet is the screen a player opens most after the HUD, so it is held to
## the same three questions every other screen in this deck is: does it say what
## the sim says, does it fit a 360 dp phone at 130 % text, and does the one chip
## it adds to §2.4's top bar cost the bar anything it cannot afford.


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
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim)
	var model := GoalsModel.new(sim, root.config, controller)
	root.goals_sheet.setup(root.config, model)
	return {"root": root, "sim": sim, "sheet": root.goals_sheet, "model": model,
			"hud": root.hud}


func _unmount(mounted: Dictionary) -> void:
	var root: Node = mounted["root"]
	_tree().root.remove_child(root)
	root.free()


static func _finish(sim: CitySim, up_to: int) -> void:
	for entry: Variant in GoalSystem.levels():
		var row: Dictionary = entry
		if int(row["level"]) > up_to:
			continue
		for raw: Variant in (row["objectives"] as Array):
			sim.goals.done[str((raw as Dictionary)["id"])] = true
	sim.goals.earned_level = up_to
	sim.goals.reconcile(sim.goal_state_view())
	sim.goals.drain_events()


# ===========================================================================
# GoalsModel — the headless half
# ===========================================================================

func test_the_chip_reads_the_level_and_the_fraction() -> void:
	var sim := CitySim.boot_from_files()
	var model := GoalsModel.new(sim, _cfg(), null)
	var chip := model.chip_view()
	assert_true(bool(chip["visible"]), "a fresh city has a curriculum to show")
	assert_eq(int(chip["level"]), 1)
	assert_true(str(chip["text"]).begins_with("L1"),
			"the chip leads with the level: %s" % chip["text"])
	assert_true(str(chip["text"]).ends_with("0/3"),
			"and ends with the fraction: %s" % chip["text"])


func test_the_chip_retires_when_the_curriculum_is_done() -> void:
	var sim := CitySim.boot_from_files()
	_finish(sim, GoalSystem.top_level())
	var model := GoalsModel.new(sim, _cfg(), null)
	assert_false(bool(model.chip_view()["visible"]),
			"a teaching surface leaves when there is nothing left to teach")


func test_every_row_carries_resolved_copy_and_a_counter() -> void:
	var sim := CitySim.boot_from_files()
	var model := GoalsModel.new(sim, _cfg(), null)
	var view := model.view()
	assert_false(bool(view["complete"]))
	assert_eq(int(view["level"]), 1)
	assert_ne(str(view["title"]), "ui_level_1_title", "the title resolved")
	assert_true((view["rows"] as Array).size() >= 3)
	for raw: Variant in (view["rows"] as Array):
		var row: Dictionary = raw
		assert_ne(str(row["text"]), str(row["id"]), "%s resolved" % row["id"])
		assert_false(str(row["text"]).begins_with("ui_"),
				"%s is copy, not a key: %s" % [row["id"], row["text"]])
		assert_true(str(row["counter"]).contains("/"),
				"%s reads as a fraction: '%s'" % [row["id"], row["counter"]])


func test_the_population_row_counts_in_residents_not_in_ticks() -> void:
	var sim := CitySim.boot_from_files()
	sim.advance_hours(1.0)
	var model := GoalsModel.new(sim, _cfg(), null)
	for raw: Variant in (model.view()["rows"] as Array):
		var row: Dictionary = raw
		if str(row["id"]) != "l1_population":
			continue
		assert_eq(str(row["counter"]),
				"%s/%s" % [HudModel.pop(sim.population.city_population),
						HudModel.pop(int(row["target"]))],
				"the readout is in the units the population chip uses")
		return
	assert_true(false, "level 1 carries a population row")


func test_the_reward_row_is_read_from_the_build_cards() -> void:
	# The assertion that keeps the screen honest: "level 1 unlocks Apartments" is
	# `min_city_level` on doc 02's card, not a sentence in a data file.
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim)
	var model := GoalsModel.new(sim, _cfg(), controller)
	var names := model.unlocked_card_names(1)
	var expected: PackedStringArray = []
	for card: Dictionary in controller.cards():
		if int(card["min_city_level"]) == 1:
			expected.append(UIWidgets.t(_cfg(), str(card["name_key"]),
					str(card["name_fallback"])))
	assert_eq(str(names), str(expected),
			"the reward names exactly the cards the catalog gates at level 1")
	assert_true(names.size() > 0,
			"level 1 unlocks something — if it does not, the curriculum's first "
			+ "rung pays nothing and the arc has no beat")


func test_the_reward_row_is_capped_by_data() -> void:
	var cfg := _cfg()
	var cap := UIConfig.get_int(cfg.section("goals"), "max_reward_rows", 4)
	var sim := CitySim.boot_from_files()
	var model := GoalsModel.new(sim, cfg, BuildController.new(sim))
	for level in range(1, GoalSystem.top_level() + 1):
		assert_true((model.reward(level)["lines"] as PackedStringArray).size() <= cap,
				"level %d's reward card fits the display" % level)


func test_the_ladder_strip_starts_at_the_tutorial() -> void:
	var sim := CitySim.boot_from_files()
	var model := GoalsModel.new(sim, _cfg(), null)
	var rungs: Array = model.ladder()
	assert_eq(rungs.size(), GoalSystem.top_level() + 1,
			"level 0 — the tutorial — plus every curriculum rung")
	assert_eq(int((rungs[0] as Dictionary)["level"]), 0)
	assert_true(bool((rungs[0] as Dictionary)["earned"]),
			"the tutorial is behind the player by the time they read this")
	assert_true(bool((rungs[1] as Dictionary)["active"]), "level 1 is live")


func test_the_backstop_names_the_population_rung() -> void:
	var sim := CitySim.boot_from_files()
	sim.advance_hours(1.0)
	var model := GoalsModel.new(sim, _cfg(), null)
	var backstop: Dictionary = model.backstop(1)
	assert_true(bool(backstop["has"]), "the other route up is visible")
	assert_eq(int(backstop["target"]), ProgressionSystem.city_level_pop()[1],
			"and it is doc 09 §2.11's own rung, not a second copy of it")


func test_a_finished_curriculum_reads_as_a_payoff_not_as_an_empty_list() -> void:
	var sim := CitySim.boot_from_files()
	_finish(sim, GoalSystem.top_level())
	var view := GoalsModel.new(sim, _cfg(), null).view()
	assert_true(bool(view["complete"]))
	assert_eq((view["rows"] as Array).size(), 0)
	assert_ne(str(view["title"]), "", "it still says something")
	assert_false(str(view["title"]).begins_with("ui_"), "and it is copy")


# ===========================================================================
# The mounted sheet
# ===========================================================================

func test_the_sheet_opens_closed_and_closes_its_siblings() -> void:
	var mounted := _mount()
	var sheet: GoalsSheet = mounted["sheet"]
	assert_false(sheet.is_open(), "S14 comes up closed like every other modal")
	(mounted["root"] as UIRoot).settings_sheet.open()
	sheet.open()
	assert_true(sheet.is_open())
	assert_false((mounted["root"] as UIRoot).settings_sheet.is_open(),
			"one modal at a time")
	_unmount(mounted)


func test_the_sheet_renders_one_row_per_objective() -> void:
	var mounted := _mount()
	var sheet: GoalsSheet = mounted["sheet"]
	sheet.open()
	var sim: CitySim = mounted["sim"]
	var expected: Array = GoalSystem.level_row(1)["objectives"]
	assert_eq(sheet.row_ids().size(), expected.size())
	for raw: Variant in expected:
		var id := str((raw as Dictionary)["id"])
		assert_true(sheet.row_ids().has(id), "%s has a row" % id)
		assert_eq(sheet.row_mark(id), GoalsSheet.MARK_TODO,
				"%s starts unticked" % id)
	assert_true(sheet.ladder_rung_count() >= GoalSystem.top_level() + 1)
	_unmount(mounted)


func test_a_completed_objective_ticks_and_drops_its_counter() -> void:
	var mounted := _mount()
	var sim: CitySim = mounted["sim"]
	var sheet: GoalsSheet = mounted["sheet"]
	sim.goals.done["l1_transformer"] = true
	sheet.open()
	assert_eq(sheet.row_mark("l1_transformer"), GoalsSheet.MARK_DONE)
	assert_eq(sheet.row_counter("l1_transformer"), "",
			"a finished row shows a tick, not 1/1")
	assert_ne(sheet.row_counter("l1_houses"), "", "an unfinished one still counts")
	_unmount(mounted)


func test_the_sheet_survives_the_level_changing_under_it() -> void:
	# The refresh path the shell drives: the row SET changes when a level lands,
	# and the sheet must re-build rather than render the old level's ids.
	var mounted := _mount()
	var sim: CitySim = mounted["sim"]
	var sheet: GoalsSheet = mounted["sheet"]
	sheet.open()
	_finish(sim, 1)
	sheet.refresh()
	for raw: Variant in GoalSystem.level_row(2)["objectives"]:
		assert_true(sheet.row_ids().has(str((raw as Dictionary)["id"])),
				"level 2's rows are up")
	assert_false(sheet.row_ids().has("l1_houses"), "level 1's are gone")
	_unmount(mounted)


func test_the_finished_sheet_has_no_rows_and_still_has_a_badge() -> void:
	var mounted := _mount()
	_finish(mounted["sim"] as CitySim, GoalSystem.top_level())
	var sheet: GoalsSheet = mounted["sheet"]
	sheet.open()
	assert_eq(sheet.row_ids().size(), 0)
	assert_ne(sheet.level_badge_text(), "", "the payoff card still reads as one")
	_unmount(mounted)


# ===========================================================================
# The chip on the top bar (doc 12 §2.4)
# ===========================================================================

func test_the_bar_is_untouched_until_the_chip_is_fed() -> void:
	# The property that keeps §2.4's reference layout true: a HUD that nobody has
	# handed a curriculum to solves exactly the seven-chip bar doc 12 is written
	# against.
	var model := HudModel.new(_cfg())
	assert_eq(model.chip_order().size(), 7)
	assert_eq(int(model.solve_top_bar(880.0)["iterations"]), 0,
			"doc 12 test 10: W=880 keeps all chips FULL")


func test_the_goal_chip_joins_the_bar_and_keeps_p1_to_p4_on_it() -> void:
	var model := HudModel.new(_cfg())
	model.ingest_goals({"visible": true, "text": "L2 · 2/3", "level": 2})
	var order := model.chip_order()
	assert_eq(order.size(), 8)
	assert_eq(str(order[model.goal_chip_index()]), HudModel.CHIP_GOALS)
	var width := 480.0
	while width <= 1200.0:
		var modes: Dictionary = model.solve_top_bar(width, 132.0, {}, 2)["modes"]
		for chip_id: String in ["treasury", "incidents", "grid", "water"]:
			assert_ne(modes[chip_id], HudModel.MODE_HIDDEN,
					"%s survives at W=%d with the goal chip up" % [chip_id, int(width)])
		assert_ne(modes[HudModel.CHIP_GOALS], HudModel.MODE_HIDDEN,
				"and so does the chip that is teaching the player, at W=%d"
						% int(width))
		width += 10.0


func test_the_goal_chip_renders_its_level_and_retires_with_the_curriculum() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	var hud: CityHUD = mounted["hud"]
	hud.refresh({"population": 144, "treasury": 25000, "net_per_hour": 0.0,
			"stability": 0.9, "happiness": 0.8, "incidents": 0,
			"clock": {"minute_of_day": 0, "day_index": 0}, "speed": 1})
	root.refresh_goals()
	var button := hud.chip_button(HudModel.CHIP_GOALS)
	assert_ne(button, null, "the chip is on the bar")
	assert_true(button.text.contains("L1"), "and reads its level: %s" % button.text)
	_finish(mounted["sim"] as CitySim, GoalSystem.top_level())
	root.refresh_goals()
	assert_eq(hud.chip_button(HudModel.CHIP_GOALS), null,
			"and it leaves when the curriculum is finished")
	assert_ne(hud.menu_button().get_parent(), null,
			"a chip-set rebuild does not take the pause menu button with it")
	_unmount(mounted)


func test_tapping_the_chip_opens_the_sheet_rather_than_the_dashboard() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	root.hud.chip_activated.emit(StringName(HudModel.CHIP_GOALS))
	assert_true(root.goals_open(), "the goal chip's action is S14")
	assert_false(root.city_dashboard.is_open(), "not §2.10's dashboard")
	_unmount(mounted)


# ===========================================================================
# The events the shell reacts to
# ===========================================================================

func test_an_objectives_met_event_raises_the_celebration() -> void:
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	root.feed_events([{"type": "city_level_objectives_met", "level": 1}])
	assert_true(root.toast_view.is_open(),
			"the level-up is announced: '%s'" % root.toast_view.text())
	assert_true(root.toast_view.text().contains("1"),
			"and it names the level: '%s'" % root.toast_view.text())
	_unmount(mounted)


func test_opening_the_sheet_satisfies_the_tutorials_handoff_step() -> void:
	# Doc 09 §2.14's handoff: the tutorial's last step points at the chip, and
	# opening the sheet is one of the two things that finishes it.
	var steps: Array = UIConfig.load_from_files().section("onboarding")["steps"]
	var last: Dictionary = steps[steps.size() - 1]
	assert_eq(str(last["id"]), "next_goals",
			"the tutorial ends by pointing at the goals chip")
	var conditions: Array = (last["advance"] as Dictionary)["conditions"]
	var paths: PackedStringArray = []
	for raw: Variant in conditions:
		paths.append(str((raw as Dictionary).get("path", "")))
	assert_true(paths.has(OnboardingFlow.SCREEN_GOALS_SHEET),
			"and opening S14 is what satisfies it")
