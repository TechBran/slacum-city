extends SimTest
## The ruin's SECOND button on S5 — doc 12 §2.9 D-89, doc 93 §AQ2, report 98
## RR-171 / RR-172.
##
## Wave 18 gave a ruin one button and therefore no decision: pay to bring it
## back, or look at rubble. The 2026-09-03 report is the state that makes the
## missing half obvious — *"there's negative money … ALL of my buildings are
## destroyed right now"* — because at a negative balance the one button the panel
## draws is the one button that cannot be pressed.
##
## **This is the door test, not the arithmetic test.** `tests/test_salvage_building.gd`
## holds `cmd_salvage_building`; everything here is about whether a player can
## find it, read it, and be told what it costs them before they commit.


func _sim() -> CitySim:
	return CitySim.boot_from_files()


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _mount(sim: CitySim) -> Dictionary:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	_tree().root.add_child(root)
	root.initialize()
	var cfg: UIConfig = root.config
	var controller := BuildController.new(sim, RequirementFormatter.new(cfg))
	var panel := root.get_node_or_null("SafeArea/PanelLayer/BuildingPanel") as BuildingPanel
	if panel != null:
		panel.setup(cfg, controller)
	return {"root": root, "panel": panel, "controller": controller, "config": cfg}


func _unmount(mounted: Dictionary) -> void:
	var root: Node = mounted["root"]
	_tree().root.remove_child(root)
	root.free()


func _destroy(sim: CitySim, sim_id: String) -> void:
	var b: Building = sim.buildings[sim_id]
	b.ignite()
	b.burn_down(true, sim.clock.sim_time_minutes())


func _first_active(sim: CitySim) -> String:
	for id in sim.roster_ids():
		if (sim.buildings[id] as Building).state == &"active":
			return String(id)
	return ""


## The row exists, it names its money, and it is on a ruin and nowhere else.
func test_the_ruin_gets_a_second_button_and_a_standing_building_does_not() -> void:
	var sim := _sim()
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]

	var standing := _first_active(sim)
	panel.show_building(standing)
	assert_false(panel.salvage_button().visible,
			"a standing building is the demolition verb's, not this one's")

	_destroy(sim, standing)
	panel.show_building(standing)
	assert_true(panel.salvage_button().visible, "a ruin draws the salvage button")
	assert_true(panel.restore_button().visible, "beside the restore button")
	var value: int = (sim.cmd_salvage_building(standing, true)["payload"] as Dictionary)["value"]
	assert_true(panel.salvage_button().text.find(str(value)) >= 0
			or panel.salvage_button().text.find(RequirementFormatter.money(value)) >= 0,
			("the money is on the button's face, not only in a tooltip: %s vs $%d")
					% [panel.salvage_button().text, value])
	_unmount(mounted)
	sim.dispose()


## **The state the row was written for.** A negative balance kills RESTORE and
## must not touch SALVAGE — a verb that spends nothing has nothing to refuse.
func test_a_broke_city_can_still_press_it() -> void:
	var sim := _sim()
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	var ruin := _first_active(sim)
	_destroy(sim, ruin)
	sim.treasury.balance = -12_500

	panel.show_building(ruin)
	assert_true(panel.restore_button().disabled,
			"the paying verb goes dead under water")
	assert_false(panel.restore_button().text.is_empty(),
			"with its price still on its face, per the build-card pattern")
	assert_true(panel.salvage_button().visible)
	assert_false(panel.salvage_button().disabled,
			"and the paying-OUT verb is the one door a negative balance cannot close")
	_unmount(mounted)
	sim.dispose()


## The consequence is stated BEFORE the hold, in words, beside the other verb's
## price — because the decision is not "is $915 a lot", it is "is $915 worth more
## to me than a level-3 building".
func test_the_note_says_what_it_costs_you_before_you_commit() -> void:
	var sim := _sim()
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	var ruin := _first_active(sim)
	_destroy(sim, ruin)
	panel.show_building(ruin)

	var note := panel.salvage_note()
	assert_true(note.visible, "the row explains itself")
	assert_false(note.text.strip_edges().is_empty(), "in words, not in an empty label")
	var restore_cost: int = (sim.cmd_salvage_building(ruin, true)["payload"]
			as Dictionary)["restore_cost"]
	assert_true(note.text.find(RequirementFormatter.money(restore_cost)) >= 0,
			("the note quotes what rebuilding would cost (%s), which is the number "
					+ "the decision is actually against: %s")
					% [RequirementFormatter.money(restore_cost), note.text])
	_unmount(mounted)
	sim.dispose()


## It is HOLD-to-confirm, like `DEMOLISH` and unlike `RESTORE`: a press alone
## must not remove a building. This is the assertion that would catch somebody
## wiring `pressed` to the verb.
func test_a_press_alone_removes_nothing() -> void:
	var sim := _sim()
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	var ruin := _first_active(sim)
	_destroy(sim, ruin)
	panel.show_building(ruin)

	panel.salvage_button().button_down.emit()
	panel.salvage_button().button_up.emit()
	assert_true(sim.buildings.has(ruin),
			"a press and a release inside the window must salvage nothing")
	assert_true(panel.salvage_button().visible, "and the row is still there")
	_unmount(mounted)
	sim.dispose()


## The hold landed: money in, building out, panel closed — the same three things
## a demolition does, because a panel describing a lot that is now empty is worse
## than no panel.
func test_the_hold_pays_and_closes_the_panel() -> void:
	var sim := _sim()
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	var ruin := _first_active(sim)
	_destroy(sim, ruin)
	panel.show_building(ruin)
	var value: int = (sim.cmd_salvage_building(ruin, true)["payload"] as Dictionary)["value"]
	var before := sim.treasury.balance

	panel.request_salvage()
	assert_eq(sim.treasury.balance, before + value, "the money landed")
	assert_false(sim.buildings.has(ruin), "the ruin is gone")
	assert_true(panel.view().is_empty(),
			"and the panel let go of the building it was describing")
	_unmount(mounted)
	sim.dispose()
