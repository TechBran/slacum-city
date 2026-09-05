extends SimTest
## **S18 — the transformer panel** (doc 12 §2.25, Wave 25; report 98 §68
## RR-205..RR-208, doc 93 §AY).
##
## The player, 2026-09-04: *"if you click on the transformer, you can repair it
## — which means calling your crews there … You click the transformer and all of
## that information pops up just like a building does. So we don't clutter the
## building information."*
##
## So the things this file has to prove are not that a panel draws. They are:
##
##   1. **A tap on a pad reaches the transformer**, and does not steal a tap that
##      belongs to the house next door.
##   2. **The panel names every customer**, jumps to each, and reads the same
##      band the pad in the world is drawn in.
##   3. **CALL A CREW spends money once, sends a crew, and the transformer comes
##      back when the crew ARRIVES** — not on the tap.
##   4. **The building panel got shorter**, and the row that replaced the section
##      is a door rather than a label.
##
## Everything drives a **real `CitySim.boot_from_files()`** and the real
## `ui_root.tscn`, because the numbers under test are doc 03's and doc 04's and a
## fixture would only prove the fixture. No transformer id is hardcoded anywhere
## below: the starter city is data and its grid may move.


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _sim(hours: float = 6.0) -> CitySim:
	var sim := CitySim.boot_from_files(1337)
	sim.advance_hours(hours)
	return sim


func _model(sim: CitySim) -> TransformerPanelModel:
	var cfg := _cfg()
	return TransformerPanelModel.new(sim, PowerActions.new(sim,
			RequirementFormatter.new(cfg)), cfg)


## The transformer with the most buildings behind it — the one whose panel has
## something to draw. Asked, never named.
func _busiest(sim: CitySim) -> String:
	var best := ""
	var most := -1
	for id_value in sim.grid.component_ids_of_kind(&"transformer"):
		var n := sim.grid.buildings_served_by(String(id_value)).size()
		if n > most:
			most = n
			best = String(id_value)
	return best


func _mount() -> UIRoot:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	_tree().root.add_child(root)
	root.initialize()
	return root


func _unmount(root: UIRoot) -> void:
	_tree().root.remove_child(root)
	root.free()


# ===========================================================================
# 1. The pick (RR-207)
# ===========================================================================

func test_a_tap_on_a_pad_selects_the_transformer_and_the_fork_selected_nothing() -> void:
	var sim := _sim()
	var controller := BuildController.new(sim)
	controller.set_tap_radius_from(0.05376)   # 48 dp at the default camera height
	var reached := 0
	var pads := sim.grid.component_ids_of_kind(&"transformer")
	for id_value in pads:
		var id := String(id_value)
		var tile := sim.grid.component_tile(id)
		var point := Vector3((float(tile.x) + 0.5) * controller.tile_m, 0.0,
				(float(tile.y) + 0.5) * controller.tile_m)
		var pick := controller.pick_at_ground(point)
		if StringName(String(pick["kind"])) == BuildController.PICK_COMPONENT \
				and String(pick["id"]) == id:
			reached += 1
		# The fork's own answer for the same tap, reconstructed from the two
		# queries `pick_at_ground` made before this wave: no building on the tile
		# and a developed block ⇒ `PICK_NONE` ⇒ the shell DESELECTED.
		assert_eq(controller.sim_id_at_tile(tile), "",
				"doc 09 puts no building on %s's tile" % id)
	assert_eq(reached, pads.size(),
			"every pad in the founding city answers its own tap")
	assert_true(pads.size() >= 10, "the founding city has a grid to tap")


func test_the_component_pick_is_capped_at_half_a_tile_so_it_cannot_steal_a_house() -> void:
	# 48 dp is 16.04 m of ground at full zoom-out (doc 92 §38.3) — two tiles in
	# every direction. Without the cap a tap squarely on a house would open the
	# transformer next door, which is the regression this constant exists to
	# prevent, and it is measured here rather than asserted in a comment.
	var sim := _sim()
	var controller := BuildController.new(sim)
	var id := _busiest(sim)
	var tile := sim.grid.component_tile(id)
	var centre := Vector3((float(tile.x) + 0.5) * controller.tile_m, 0.0,
			(float(tile.y) + 0.5) * controller.tile_m)
	controller.set_tap_radius_from(0.35)     # a far-out camera: 16.8 m of finger
	assert_true(controller.tap_radius_m > controller.tile_m,
			"the finger really is wider than a tile at this zoom")
	# One tile away is outside half a tile, so the pad does NOT answer.
	var far := centre + Vector3(controller.tile_m, 0.0, 0.0)
	assert_true(controller.component_near(far).is_empty(),
			"a tap a whole tile from the pad is not a tap on the pad")
	# …and a tap on the pad still is.
	assert_eq(String(controller.component_near(centre).get("id", "")), id,
			"the pad still answers its own centre at any zoom")


func test_an_opportunity_still_outranks_a_transformer() -> void:
	# The order is `opportunity → component → building → block`, and the dog
	# keeps its place: a collectable is LEAVING and a transformer is not.
	var sim := _sim()
	var controller := BuildController.new(sim)
	var id := _busiest(sim)
	var tile := sim.grid.component_tile(id)
	var centre := Vector3((float(tile.x) + 0.5) * controller.tile_m, 0.0,
			(float(tile.y) + 0.5) * controller.tile_m)
	controller.set_tap_radius_from(0.05376)
	controller.collect_command = func(_id: String) -> Dictionary:
		return CommandQueue.ok({})
	var roster := StubRoster.new()
	roster.row = {"id": "opp_1", "reward": 90, "world_pos": centre}
	controller.street = roster
	var pick := controller.pick_at_ground(centre)
	assert_eq(pick["kind"], BuildController.PICK_OPPORTUNITY,
			"a collectable standing on the pad still wins the tap")


class StubRoster extends RefCounted:
	var row: Dictionary = {}
	func opportunity_near(_point: Vector3, _radius: float) -> Dictionary:
		return row


# ===========================================================================
# 2. The reading (RR-205, RR-207)
# ===========================================================================

func test_the_panel_names_every_building_behind_the_pad() -> void:
	var sim := _sim()
	var model := _model(sim)
	var id := _busiest(sim)
	var view := model.view(id)
	assert_true(bool(view["exists"]), "the panel opens on a real transformer")
	var expected: Array = sim.grid.buildings_served_by(id)
	assert_eq(int(view["customer_count"]), expected.size(),
			"the count is the grid's own roster")
	var named: Array = []
	for entry: Variant in (view["customer_rows"] as Array):
		named.append(String((entry as Dictionary)["sim_id"]))
	assert_eq(str(named), str(expected),
			"every customer is named, in the grid's ascending order")
	var total := 0.0
	for sim_id: Variant in expected:
		total += sim.building_demand_kw(String(sim_id))
	assert_true(absf(float(view["customer_demand_kw"]) - total) < 0.001,
			"the kW total is the sum of the rows, not a second reading")


func test_the_panel_and_the_pad_are_the_same_verdict() -> void:
	# A5's whole argument: the word on the panel and the smoke on the cabinet may
	# not be two opinions. Both call `PowerGrid.distress_band`, and this drives
	# the RENDER model to prove the delegation is real rather than asserted.
	var sim := _sim()
	var model := _model(sim)
	var render := PowerInfraModel.new(StarterCityLoader.read_json("res://data/render.json"))
	var id := _busiest(sim)
	for ratio: float in [0.20, 0.80, 0.99, 1.60]:
		var c := sim.grid.component(id)
		c["load_kw"] = ratio * sim.grid.cap_eff(id, sim.ambient_c())
		c["energized"] = true
		var view := model.view(id)
		var mirrored := render.distress_for(String(c["state"]), true,
				float(view["load_ratio"]), float(c["condition"]),
				float(view["temp_c"]))
		assert_eq(int(view["distress"]), mirrored,
				"panel and renderer agree at load ratio %.2f" % ratio)


func test_the_meter_is_read_at_todays_ambient_and_says_so() -> void:
	# Doc 04 §2.7 derates a transformer with the weather, so a panel that printed
	# the nameplate would be wrong on exactly the hot day the player opens it.
	var sim := _sim()
	var model := _model(sim)
	var id := _busiest(sim)
	var view := model.view(id)
	assert_true(absf(float(view["capacity_kw"])
			- sim.grid.cap_eff(id, sim.ambient_c())) < 0.001,
			"the capacity on the panel is `cap_eff` at today's ambient")
	assert_true(float(view["nameplate_kw"])
			>= float(sim.grid.component(id)["capacity_kw"]) - 0.001,
			"the nameplate is published beside it")


func test_the_upstream_rows_are_the_hops_that_left_the_building_panel() -> void:
	var sim := _sim()
	var model := _model(sim)
	var id := _busiest(sim)
	var view := model.view(id)
	var ids: Array = []
	for entry: Variant in (view["upstream"] as Array):
		ids.append(String((entry as Dictionary)["id"]))
	var walk: Array = []
	var parent := String(sim.grid.component(id)["parent"])
	while parent != "" and sim.grid.has_component(parent):
		walk.append(parent)
		parent = String(sim.grid.component(parent)["parent"])
	assert_eq(str(ids), str(walk), "FED BY walks the radial tree to the pool")
	assert_true(ids.size() >= 2, "an authored transformer has a feeder and a substation")


func test_a_transformer_that_feeds_nobody_says_so_rather_than_drawing_an_empty_box() -> void:
	var sim := _sim()
	var model := _model(sim)
	var id := _busiest(sim)
	for sim_id: Variant in sim.grid.buildings_served_by(id):
		sim.grid.detach_building(String(sim_id))
	var view := model.view(id)
	assert_true(bool(view["unattached"]), "a pad with no customers is UNATTACHED")
	assert_eq(int(view["customer_count"]), 0)
	assert_true(bool(view["exists"]), "…and the panel still opens on it")


# ===========================================================================
# 3. Call the crews (RR-206)
# ===========================================================================

func test_the_panel_opens_on_the_crew_when_the_unit_is_dead() -> void:
	var sim := _sim()
	var model := _model(sim)
	var id := _busiest(sim)
	assert_eq(model.focus_of(model.power.transformer_block(id)),
			TransformerPanelModel.FOCUS_UPGRADE,
			"a working transformer opens on the ladder")
	sim.grid.component(id)["state"] = &"FAILED"
	sim.treasury.balance = 500_000
	assert_eq(model.focus_of(model.power.transformer_block(id)),
			TransformerPanelModel.FOCUS_REPAIR,
			"a burned-out one opens on the crew — that is why the player tapped it")


func test_call_a_crew_takes_two_taps_spends_once_and_the_unit_comes_back_when_they_finish() -> void:
	var sim := _sim()
	var root := _mount()
	var controller := BuildController.new(sim)
	var panel := root.transformer_panel
	panel.setup(root.config, TransformerPanelModel.new(sim, controller.power,
			root.config, controller.tile_m))
	var id := _busiest(sim)
	sim.grid.component(id)["state"] = &"FAILED"
	sim.grid.component(id)["condition"] = 0.72
	sim.treasury.balance = 500_000
	var before := sim.treasury.balance
	panel.show_component(id)
	var button := panel.repair_button()
	assert_true(button != null, "a dead transformer draws CALL A CREW")
	assert_false(button.disabled, "…and the city can afford it")

	# Tap one ARMS. Doc 12 §2.7: never spend on one tap.
	button.pressed.emit()
	panel.refresh()
	assert_eq(sim.treasury.balance, before, "the first tap spends nothing")
	assert_eq(String(sim.grid.component(id)["state"]), "FAILED",
			"…and changes nothing about the grid")

	# Tap two SENDS.
	panel.repair_button().pressed.emit()
	panel.refresh()
	assert_true(sim.treasury.balance < before, "the second tap pays for it")
	assert_eq(String(sim.grid.component(id)["state"]), "FAILED",
			"a crew has to ARRIVE — the transformer does not heal on the tap")
	assert_true(sim.grid_repair_job(id) >= 0, "there is a job in the queue")
	var view := panel.view()
	assert_true(bool((view["repair"] as Dictionary)["in_flight"]),
			"and the panel shows it")

	# The crew arrives.
	sim.advance_hours(2.0)
	assert_eq(String(sim.grid.component(id)["state"]), "OK",
			"it comes back when the crew finishes")
	assert_true(float(sim.grid.component(id)["condition"]) >= 0.85 - 0.001,
			"…at doc 02 §2.12's post-damage target")
	_unmount(root)


func test_the_price_and_the_clock_are_doc_03s_and_doc_06s_and_nothing_is_authored_in_ui() -> void:
	var sim := _sim()
	var model := _model(sim)
	var id := _busiest(sim)
	var c := sim.grid.component(id)
	c["state"] = &"FAILED"
	c["condition"] = 0.72
	sim.treasury.balance = 500_000
	var quote := model.power.repair_quote(id)
	var damage := (1.0 - 0.72) + float(PowerGrid.FAILURE_DAMAGE[&"transformer"])
	var capital := sim.econ_curves.capital_value_grid("transformer", int(c["level"]))
	assert_eq(int(quote["cost"]), sim.econ_curves.repair_cost(capital, damage,
			float(sim.treasury.difficulty().get("M_repair", 1.0))),
			"doc 03 §2.5's one repair formula, on §2.5's own grid capital")
	var row := sim.incident_catalog.type_row("transformer_failure", "")
	assert_true(absf(float(quote["crew_hours"])
			- float(row["w_base"]) * damage) < 0.0001,
			"doc 06's own `transformer_failure.w_base`, scaled by the damage")


func test_a_second_crew_is_refused_by_name_and_the_button_says_why() -> void:
	var sim := _sim()
	var model := _model(sim)
	var id := _busiest(sim)
	sim.grid.component(id)["state"] = &"FAILED"
	sim.treasury.balance = 500_000
	assert_true(bool(model.repair(id)["ok"]), "the first crew goes")
	var second := sim.cmd_repair_grid_component(id, true)
	assert_eq(String(second["reason_code"]), "E_ALREADY_REPAIRING")
	var quote := model.power.repair_quote(id)
	assert_true(bool(quote["in_flight"]), "the panel shows the crew, not a button")
	assert_true(float(quote["eta_gm"]) > 0.0, "…with the queue's own ETA")


func test_a_transformer_in_good_repair_is_offered_no_crew_at_all() -> void:
	var sim := _sim(0.5)
	var model := _model(sim)
	var id := _busiest(sim)
	sim.grid.component(id)["condition"] = 1.0
	sim.grid.component(id)["state"] = &"OK"
	var quote := model.power.repair_quote(id)
	assert_false(bool(quote.get("available", false)),
			"E_NOT_DAMAGED draws no strip — a refusal is not a requirement")


func test_the_crew_survives_a_save_and_finishes_on_the_other_side() -> void:
	var sim := _sim()
	var id := _busiest(sim)
	sim.grid.component(id)["state"] = &"FAILED"
	sim.treasury.balance = 500_000
	assert_true(bool(sim.cmd_repair_grid_component(id)["ok"]))
	var body := sim.canonical_capture()
	var a := CitySim.boot_from_files(1337)
	a.restore_state(body)
	var b := CitySim.boot_from_files(1337)
	b.restore_state(body)
	assert_true(a.grid_repair_job(id) >= 0, "the job is in the queue after a load")
	assert_eq(String(a.grid.component(id)["state"]), "FAILED",
			"…and the transformer is still down on the other side")
	assert_eq(a.state_hash(), b.state_hash(), "two restores of one capture agree")
	a.advance_hours(2.0)
	b.advance_hours(2.0)
	assert_eq(String(a.grid.component(id)["state"]), "OK",
			"the crew finishes after the save exactly as it would have before")
	assert_eq(a.state_hash(), b.state_hash(),
			"…and the two restores stay identical while it does")


# ===========================================================================
# 4. The building panel diet (RR-208)
# ===========================================================================

func test_the_power_section_is_one_row_and_the_row_is_a_door() -> void:
	var sim := _sim()
	var root := _mount()
	var controller := BuildController.new(sim)
	var panel: BuildingPanel = root.building_panel
	assert_true(panel != null, "the root binds S5")
	panel.setup(root.config, controller)
	root.transformer_panel.setup(root.config, TransformerPanelModel.new(
			sim, controller.power, root.config, controller.tile_m))
	var sim_id := ""
	for key: Variant in sim.grid.attachment_map():
		sim_id = String(key)
		break
	panel.show_building(sim_id)
	var row := panel.power_row_button()
	assert_true(row != null, "a served building draws the one-row summary")
	assert_true(row.text.contains(String(sim.grid.attachment_of(sim_id))),
			"…and it names the transformer")
	assert_true(row.custom_minimum_size.y >= 48.0, "A3: it is a tap target")
	assert_true(row.tooltip_text != "", "A15: it has an accessibility name")

	# The door.
	row.pressed.emit()
	assert_true(root.transformer_panel.is_open(), "the row opens S18")
	assert_eq(root.transformer_panel.selected_id(),
			String(sim.grid.attachment_of(sim_id)),
			"…on the transformer that feeds this building")
	assert_false(panel.is_open(), "and S5 stands down — one panel at a time")
	_unmount(root)


func test_an_unserved_building_still_says_so_on_its_own_panel() -> void:
	var sim := _sim()
	var root := _mount()
	var controller := BuildController.new(sim)
	var panel: BuildingPanel = root.building_panel
	panel.setup(root.config, controller)
	var sim_id := ""
	for key: Variant in sim.grid.attachment_map():
		sim_id = String(key)
		break
	sim.grid.detach_building(sim_id)
	panel.show_building(sim_id)
	var row := panel.power_row_button()
	assert_true(row != null, "an unserved building still gets the row")
	var found := false
	for child in panel.get_node(panel.body_path() + "/PowerSection").get_children():
		if child is Label and String((child as Label).name) == "Unserved":
			found = true
	assert_true(found, "the UNSERVED sentence is on THIS panel, not behind a tap")
	_unmount(root)


func test_the_fix_this_row_on_a_power_blocker_now_opens_the_transformer() -> void:
	# PA-05's row, one wave on. Wave 17 armed a confirm strip; Wave 25 takes the
	# player to the wall, because the wall is now a place.
	var sim := _sim()
	var root := _mount()
	var controller := BuildController.new(sim)
	var panel: BuildingPanel = root.building_panel
	panel.setup(root.config, controller)
	root.transformer_panel.setup(root.config, TransformerPanelModel.new(
			sim, controller.power, root.config, controller.tile_m))
	var sim_id := ""
	for key: Variant in sim.grid.attachment_map():
		sim_id = String(key)
		break
	var component := String(sim.grid.attachment_of(sim_id))
	panel.show_building(sim_id)
	panel._on_fix_pressed({"kind": RequirementFormatter.FIX_POWER, "id": component})
	assert_true(root.transformer_panel.is_open(), "the row opens S18")
	assert_eq(root.transformer_panel.selected_id(), component,
			"…on the component the headroom binds at, which is what the id has always been")
	_unmount(root)


# ===========================================================================
# 5. The world highlight (RR-207 item 5)
# ===========================================================================

func test_the_selected_pad_is_ringed_and_the_ring_leaves_with_the_selection() -> void:
	var sim := _sim()
	var view := PowerInfraView.new()
	view.setup(StarterCityLoader.read_json("res://data/render.json"))
	_tree().root.add_child(view)
	view.sync(sim, 0.1, Vector3.ZERO)
	var id := _busiest(sim)
	view.set_selected(id)
	assert_eq(view.selected(), id)
	var ring := view.get_node_or_null("SelectionRing") as MeshInstance3D
	assert_true(ring != null and ring.visible, "the pad is ringed")
	var pad: PowerInfraModel.PadRec = view.model.pad_of(id)
	assert_true(ring.position.distance_to(pad.world_pos) < 0.1,
			"…on the pad, not near it")
	view.set_selected("")
	assert_false(ring.visible, "and the ring leaves with the selection")
	view.set_selected("T-DOES-NOT-EXIST")
	assert_false(ring.visible,
			"an id the view has never heard of clears it rather than stranding it")
	_tree().root.remove_child(view)
	view.free()
