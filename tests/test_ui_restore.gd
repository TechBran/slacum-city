extends SimTest
## The RUIN's row on S5 — doc 12 §2.9 D-86, doc 93 §AN6/§AN7, report 98 RR-157.
##
## The defect these close is not a wrong number, it is a panel with nothing on
## it. A destroyed building was already selectable (the tiles stay stamped, so
## `pick_at_ground` resolves it), the panel already opened, and what it drew was:
## a dead `REPAIR` with an `E_STATE` sentence on city stock, and — on private
## stock, where `E_OWNER_MAINTAINED` fires first and folds into "nothing to buy"
## — **no action at all**. So the player looked at their own rubble and the game
## offered them nothing.


func _sim() -> CitySim:
	return CitySim.boot_from_files()


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## Mounts the UI scaffold and wires S5 to `sim`, exactly as
## `tests/test_build_controller.gd::_mount` does. Free with `_unmount`.
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


## Burn one down through doc 02 §2.12's own transitions.
func _destroy(sim: CitySim, sim_id: String) -> void:
	var b: Building = sim.buildings[sim_id]
	b.ignite()
	b.burn_down(true, sim.clock.sim_time_minutes())


func _first_active(sim: CitySim, private_only: bool = false) -> String:
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.state == &"active" and b.owner_maintained == private_only:
			return String(id)
	return ""


# ---------------------------------------------------------------------------
# The pick — a ruin must be reachable before it can be restorable
# ---------------------------------------------------------------------------

## Checked rather than assumed (doc 93 §AN7). `CitySim` does not un-stamp a
## destroyed building's tiles, so the pick still finds it — but "still" is the
## kind of word that stops being true silently, and this is the assertion that
## would notice.
func test_a_ruin_is_still_selectable_and_the_panel_still_opens() -> void:
	var sim := _sim()
	var sim_id := _first_active(sim)
	_destroy(sim, sim_id)
	var b: Building = sim.buildings[sim_id]
	var controller := BuildController.new(sim, RequirementFormatter.load_from_files())
	var centre := Vector3(b.origin.x * 8.0 + 4.0, 0.0, b.origin.y * 8.0 + 4.0)
	var pick := controller.pick_at_ground(centre)
	assert_eq(String(pick["kind"]), String(BuildController.PICK_BUILDING),
			"the tap on a ruin found the ruin, not the land under it")
	assert_eq(String(pick["id"]), sim_id)
	var view := controller.building_view(sim_id)
	assert_true(bool(view["exists"]), "the panel's view model admits a ruin")
	assert_eq(String(view["state"]), "destroyed")
	assert_eq(str(view["state_key"]), "ui_building_state_destroyed")


# ---------------------------------------------------------------------------
# The row itself
# ---------------------------------------------------------------------------

func test_the_ruin_row_is_the_only_action_and_carries_its_price() -> void:
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	var sim_id := _first_active(sim)
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]

	# Before: a healthy building draws no restore row at all.
	panel.show_building(sim_id)
	assert_false(panel.restore_button().visible, "a standing building is not a ruin")

	_destroy(sim, sim_id)
	panel.show_building(sim_id)
	var button := panel.restore_button()
	assert_true(button.visible, "the ruin's panel offers the one verb it has")
	assert_false(button.disabled, "and the city can afford it")
	var quote := int((sim.cmd_restore_building(sim_id, true)["payload"] as Dictionary)["cost"])
	assert_true(button.text.contains(RequirementFormatter.money(quote)),
			"the price is ON THE BUTTON, not behind a dialog: %s" % button.text)
	assert_true(button.tooltip_text.length() > 0, "A15 name")
	assert_true(button.custom_minimum_size.y >= 48.0, "A3 touch target")
	assert_eq(button.theme_type_variation, &"PrimaryFAB",
			"a ruin's only verb is the PRIMARY button on the panel")
	# The note says what happened in the terms the model holds.
	var note := panel.restore_note()
	assert_true(note.visible and note.text.length() > 0)
	assert_false(note.text.contains("{"), "no unresolved placeholder: %s" % note.text)

	# REPAIR is suppressed: it cannot answer `destroyed`, and a dead button
	# beside the live one is the state this row exists to remove.
	assert_false(panel.repair_button().visible,
			"a ruin must not be offered a repair the sim refuses")
	_unmount(mounted)


## The build-card pattern: broke does not blank the button, it disables it with
## the price still legible and the reason underneath.
func test_unaffordable_keeps_the_price_on_the_face() -> void:
	var sim := _sim()
	var sim_id := _first_active(sim)
	_destroy(sim, sim_id)
	var quote := int((sim.cmd_restore_building(sim_id, true)["payload"] as Dictionary)["cost"])
	sim.treasury.balance = quote - 1
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	panel.show_building(sim_id)
	var button := panel.restore_button()
	assert_true(button.visible, "the offer stays on screen")
	assert_true(button.disabled, "and it is dead")
	assert_true(button.text.contains(RequirementFormatter.money(quote)),
			"a player who cannot afford it still learns the number: %s" % button.text)
	var note := panel.restore_note()
	assert_true(note.text.length() > 0, "with the formatter's sentence under it")
	assert_false(note.text.contains("{"))
	_unmount(mounted)


## Doc 93 §AN4 on the surface: the ownership ruling must not hide the row.
func test_a_private_ruin_gets_the_row_the_repair_ruling_would_have_hidden() -> void:
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	var sim_id := _first_active(sim, true)
	assert_ne(sim_id, "", "the founding manifest carries owner-maintained stock")
	assert_true((sim.buildings[sim_id] as Building).owner_maintained)
	_destroy(sim, sim_id)
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	panel.show_building(sim_id)
	assert_true(panel.restore_button().visible,
			"E_OWNER_MAINTAINED hid the only verb a burnt-out house has")
	assert_false(panel.restore_button().disabled)
	_unmount(mounted)


## The one tap goes through the door, the panel re-reads, and the signal carries
## the sim's own answer.
func test_one_tap_restores_and_the_panel_re_reads() -> void:
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	var sim_id := _first_active(sim)
	_destroy(sim, sim_id)
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	panel.show_building(sim_id)
	var seen: Array[Dictionary] = []
	panel.restored.connect(func(_id: String, result: Dictionary) -> void: seen.append(result))
	var before := sim.treasury.balance
	var quote := int((sim.cmd_restore_building(sim_id, true)["payload"] as Dictionary)["cost"])

	panel.restore_button().pressed.emit()

	assert_eq(seen.size(), 1, "the panel published the sim's own answer")
	assert_true(bool(seen[0]["ok"]), str(seen[0].get("reason_code", "")))
	assert_eq(sim.treasury.balance, before - quote, "one tap, one charge")
	assert_eq(String((sim.buildings[sim_id] as Building).state), "under_construction")
	# The panel re-read rather than predicting: the row is gone because the sim
	# says the building is no longer a ruin.
	assert_false(panel.restore_button().visible, "the row leaves with the rubble")
	_unmount(mounted)


# ---------------------------------------------------------------------------
# The many-at-once row
# ---------------------------------------------------------------------------

func test_the_batch_row_appears_only_when_there_is_more_than_one_ruin() -> void:
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	var first := _first_active(sim)
	_destroy(sim, first)
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	panel.show_building(first)
	assert_false(panel.restore_all_button().visible,
			"one ruin: the primary button already IS the whole offer")

	var second := _first_active(sim)
	_destroy(sim, second)
	panel.show_building(first)
	var batch := panel.restore_all_button()
	assert_true(batch.visible, "two ruins: the city-wide offer appears")
	var total := int((sim.cmd_restore_all_destroyed(true)["payload"] as Dictionary)["cost"])
	assert_true(batch.text.contains(RequirementFormatter.money(total)),
			"the batch names its own total: %s" % batch.text)
	assert_true(batch.text.contains("2"), "and how many it covers: %s" % batch.text)
	assert_true(batch.custom_minimum_size.y >= 48.0, "A3 touch target")
	assert_true(batch.tooltip_text.length() > 0, "A15 name")

	batch.pressed.emit()
	assert_ne(String((sim.buildings[first] as Building).state), "destroyed")
	assert_ne(String((sim.buildings[second] as Building).state), "destroyed")
	_unmount(mounted)


## Partial affordability stays LIVE, and says so before the tap rather than
## after it: the verb buys cheapest-first and stops at the wall.
func test_a_partly_affordable_batch_says_how_far_the_money_reaches() -> void:
	var sim := _sim()
	var ruins: Array[String] = []
	for _i in 3:
		var id := _first_active(sim)
		_destroy(sim, id)
		ruins.append(id)
	var rows: Array = (sim.cmd_restore_all_destroyed(true)["payload"] as Dictionary)["rows"]
	sim.treasury.balance = int((rows[0] as Dictionary)["cost"])
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	panel.show_building(ruins[0])
	var batch := panel.restore_all_button()
	assert_true(batch.visible)
	assert_false(batch.disabled, "one of the three is affordable, so the offer is live")
	var note := panel.restore_all_note()
	assert_true(note.text.length() > 0 and not note.text.contains("{"),
			"the partial sentence resolves: %s" % note.text)
	assert_true(note.text.contains("1") and note.text.contains("3"),
			"and it names both numbers: %s" % note.text)

	# And a treasury that cannot reach even the cheapest ruin gets a sentence
	# rather than "Enough for 0 of 3", which is arithmetic.
	sim.treasury.balance = 0
	panel.show_building(ruins[0])
	assert_true(panel.restore_all_button().disabled, "nothing is affordable")
	var broke_note := panel.restore_all_note().text
	assert_true(broke_note.length() > 0 and not broke_note.contains("{"))
	assert_false(broke_note.contains("0 of"), "not arithmetic: %s" % broke_note)
	_unmount(mounted)


# ---------------------------------------------------------------------------
# The renderer half — the ruin must go the same frame (report 98 RR-157)
# ---------------------------------------------------------------------------

## `restore_started_sim` clears the soot and the OFFLINE tint the
## `building_destroyed` arm wrote, and puts the record at construction stage 1.
## Without this arm the lot renders a burnt-out shell through the whole rebuild
## AND past its completion, because the `building_completed` arm carries `damage`
## forward when the event does not name one — and `complete_construction` emits
## `{type, building, level}` and no condition.
func test_the_translator_clears_the_ruin_at_restore_start_not_at_completion() -> void:
	var model := RenderStateModel.new(RenderStateModel.load_config())
	model.set_hour(21.0)
	var pos := Vector3(8.0, 0.0, 8.0)
	model.add_building({"id": 7, "archetype_id": &"apartment", "level": 3,
			"family": "residential", "world_pos": pos, "block_id": 0,
			"chunk": Vector2i(0, 0), "occ_b": 0.9,
			"transform": Transform3D(Basis.IDENTITY, pos)})
	model.apply_event({"type": &"building_destroyed", "building": 7})
	assert_almost_eq(model.building(7).damage, 1.0, 1e-6, "the ruin is sooty")
	assert_eq(model.building(7).overlay_state, RenderStateModel.OVERLAY_OFFLINE)

	model.apply_event({"type": &"restore_started_sim", "building": 7,
			"sim_id": "P-007", "cost": 1220, "to_level": 3})
	assert_almost_eq(model.building(7).damage, 0.0, 1e-6, "the rubble is cleared")
	assert_eq(model.building(7).overlay_state, RenderStateModel.OVERLAY_NORMAL)
	assert_eq(model.building(7).stage, 1, "and a site stands in its place")

	# And the completion, which carries no damage of its own, leaves it clean.
	model.apply_event({"type": &"building_completed", "building": 7, "level": 3})
	assert_almost_eq(model.building(7).damage, 0.0, 1e-6,
			"the finished building is not still burnt")
	assert_eq(model.building(7).stage, 0)
