extends SimTest
## S4 — the land purchase flow (doc 12 §2.8, doc 09 §2.5, doc 91 D-5).
##
## Doc 91 graded this row ABSENT with the sharpest sentence in the audit: the
## sim, the pricing and the six-phase pipeline are built and tested, and **the
## city cannot grow past its founding blocks by any player action**. So the
## thing this file has to prove is not that a panel draws — it is that a tap on
## unowned ground reaches `cmd_buy_block`, that every refusal arrives as a
## sentence rather than a code, and that the two-step PURCHASE → DEVELOP flow the
## doc specifies is the one the panel runs.
##
## Everything here drives a **real `CitySim.boot_from_files()`**, because the
## numbers under test are doc 03's and doc 09's and a fixture would only prove
## the fixture. The starter city's own map decides which block is which, so no
## block id is hardcoded anywhere below.


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _model(sim: CitySim) -> LandPanelModel:
	var cfg := _cfg()
	return LandPanelModel.new(sim, RequirementFormatter.new(cfg), cfg)


## The first block doc 09's starter city offers for sale. Asked, never named.
func _purchasable(sim: CitySim) -> String:
	for id: Variant in sim.world.block_ids_sorted():
		if (sim.world.block(String(id)) as LandBlock).ownership_state == &"PURCHASABLE":
			return String(id)
	return ""


## A block whose `min_city_level` is above the city's, whatever the map says.
func _above_city_level(sim: CitySim) -> String:
	for id: Variant in sim.world.block_ids_sorted():
		var block: LandBlock = sim.world.block(String(id))
		if not block.is_owned() and block.min_city_level > sim.progression.city_level:
			return String(id)
	return ""


## A block the city could afford and could reach the level for, but which shares
## no edge with anything it owns.
func _not_adjacent(sim: CitySim) -> String:
	for id: Variant in sim.world.block_ids_sorted():
		var block: LandBlock = sim.world.block(String(id))
		if block.is_owned() or block.min_city_level > sim.progression.city_level:
			continue
		if String(sim.world.purchase_allowed(String(id),
				sim.progression.city_level).get("reason_code", "")) == "E_NOT_ADJACENT":
			return String(id)
	return ""


func _first_owned_ready(sim: CitySim) -> String:
	for id: Variant in sim.world.block_ids_sorted():
		var block: LandBlock = sim.world.block(String(id))
		if block.is_owned() and block.is_ready():
			return String(id)
	return ""


# ===========================================================================
# The view (doc 12 §2.8 item 2)
# ===========================================================================

func test_a_purchasable_block_quotes_the_sims_own_price() -> void:
	var sim := CitySim.boot_from_files()
	var block_id := _purchasable(sim)
	assert_ne(block_id, "", "the starter city offers at least one block for sale")
	var view := _model(sim).block_view(block_id)
	assert_true(bool(view["exists"]))
	assert_eq(view["stage"], LandPanelModel.STAGE_UNOWNED)
	# The panel never computes a price; it quotes doc 03 §2.7's, to the dollar.
	assert_eq(int(view["price"]),
			sim.economy.land_price(sim.land_price_inputs(block_id)),
			"the header price is EconomySystem.land_price, not a second formula")
	assert_eq(int(view["development_total"]), sim.economy.development_total_cost(
			String(sim.world.block(block_id).dev_terrain),
			float(sim.world.d_from_center(block_id)),
			sim.world.block(block_id).arterial_connections,
			float(sim.treasury.difficulty().get("M_dev", 1.0))),
			"and the development estimate is doc 03 §2.8's total")


func test_an_unknown_block_reports_no_view_rather_than_an_empty_card() -> void:
	var view := _model(CitySim.boot_from_files()).block_view("B_99_99")
	assert_false(bool(view["exists"]))


func test_the_header_says_what_the_player_is_buying() -> void:
	var sim := CitySim.boot_from_files()
	var view := _model(sim).block_view(_purchasable(sim))
	var header := str(view["header"])
	assert_true(header.contains("16"), "16 x 16 tiles (constitution §6)")
	assert_true(header.contains("128"), "128 m across at an 8 m tile: %s" % header)
	var buildable := 0
	for entry: Variant in (view["facts"] as Array):
		if str((entry as Dictionary)["id"]) == "buildable":
			buildable += 1
	assert_eq(buildable, 1, "§2.8 quotes buildable tiles")


func test_every_risk_the_block_carries_gets_a_bar_and_a_word() -> void:
	var sim := CitySim.boot_from_files()
	var model := _model(sim)
	var block_id := _purchasable(sim)
	var block := sim.world.block(block_id)
	var rows: Array = model.block_view(block_id)["risks"]
	assert_eq(rows.size(), block.env_risk.size(),
			"one row per risk the block actually carries")
	var segments := UIConfig.get_int(model.section(), "risk_bar_segments", 5)
	for entry: Variant in rows:
		var risk: Dictionary = entry
		# A5: the bar and the word both carry the reading, so the row survives
		# grayscale. Neither may be empty and neither may disagree with the value.
		assert_eq(str(risk["bar"]).length(), segments, "%s bar" % risk["id"])
		assert_ne(str(risk["word"]), "", "%s has a word" % risk["id"])
		assert_ne(str(risk["word"]), str(risk["word_key"]),
				"%s resolves its band copy" % risk["id"])
		assert_true(float(risk["value"]) >= 0.0 and float(risk["value"]) <= 1.0)


func test_the_risk_bar_never_shows_an_existing_risk_as_empty() -> void:
	var model := _model(CitySim.boot_from_files())
	assert_eq(model.bar(0.0, 5), "▯▯▯▯▯")
	assert_eq(model.bar(0.01, 5), "▮▯▯▯▯", "a risk that exists fills one segment")
	assert_eq(model.bar(0.5, 5), "▮▮▮▯▯")
	assert_eq(model.bar(1.0, 5), "▮▮▮▮▮")


func test_advantages_are_the_price_terms_and_nothing_is_authored_in_ui() -> void:
	# §2.8's `Waterfront +18 % land value` is measured by re-pricing the block
	# with that term neutralised — so a row's percentage is checkable against the
	# price function itself, which is the point of computing it that way.
	var sim := CitySim.boot_from_files()
	var model := _model(sim)
	var block_id := _purchasable(sim)
	var inputs := sim.land_price_inputs(block_id)
	var rows: Array = model.advantages(block_id, inputs,
			sim.economy.land_price(inputs))
	assert_true(rows.size() > 0, "a starter block's price is not term-free")
	var by_id: Dictionary = {}
	for entry: Variant in rows:
		by_id[str((entry as Dictionary)["id"])] = entry
	# Environmental risk is a DISCOUNT in doc 03 §2.7, so its row must read
	# negative — a panel that presented it as a bonus would be a lie about money.
	if by_id.has("risk"):
		assert_true(float((by_id["risk"] as Dictionary)["pct"]) < 0.0,
				"risk discounts the price")
	for entry: Variant in rows:
		var row: Dictionary = entry
		var neutral := inputs.duplicate()
		var term: Dictionary = LandPanelModel.ADVANTAGE_TERMS[StringName(str(row["id"]))]
		neutral[str(term["key"])] = term["neutral"]
		var expected := (sim.economy.land_price_raw(inputs)
				/ sim.economy.land_price_raw(neutral) - 1.0) * 100.0
		assert_almost_eq(float(row["pct"]), expected, 0.001,
				"%s is the price function's own answer" % row["id"])


func test_advantages_are_ordered_by_what_they_are_worth() -> void:
	var sim := CitySim.boot_from_files()
	var block_id := _purchasable(sim)
	var inputs := sim.land_price_inputs(block_id)
	var rows: Array = _model(sim).advantages(block_id, inputs,
			sim.economy.land_price(inputs))
	var previous := INF
	for entry: Variant in rows:
		var magnitude := absf(float((entry as Dictionary)["pct"]))
		assert_true(magnitude <= previous + 0.0001, "biggest effect first")
		previous = magnitude


# ===========================================================================
# The refusals (doc 12 §2.7's formatter, doc 09 §2.5's five codes)
# ===========================================================================

func test_no_money_reads_as_a_sentence_and_disables_the_button() -> void:
	var sim := CitySim.boot_from_files()
	sim.treasury.balance = 0
	var view := _model(sim).block_view(_purchasable(sim))
	var action: Dictionary = view["action"]
	assert_eq(action["id"], LandPanelModel.ACTION_BUY)
	assert_false(bool(action["enabled"]), "§2.9's rule: disabled while blocked")
	var rows: Array = action["blockers"]
	assert_eq(rows.size(), 1)
	var row: Dictionary = rows[0]
	assert_eq(row["canonical"], &"FUNDS")
	assert_true(str(row["body"]).contains("$"), "the sentence quotes the money")
	assert_ne(str(row["body"]), str(row["key"]), "it is copy, not a key")
	assert_eq(str(action["blocked_by"]["canonical"]), "FUNDS",
			"the button's subtitle names the first blocker")


func test_a_block_above_the_city_level_says_which_level() -> void:
	var sim := CitySim.boot_from_files()
	var block_id := _above_city_level(sim)
	assert_ne(block_id, "", "doc 09's map gates some blocks on city level")
	var rows: Array = (_model(sim).block_view(block_id)["action"] as Dictionary)["blockers"]
	assert_eq(rows.size(), 1)
	assert_eq((rows[0] as Dictionary)["canonical"], &"CITY_LEVEL")
	var body := str((rows[0] as Dictionary)["body"])
	assert_true(body.contains(str(sim.world.block(block_id).min_city_level)),
			"the sentence quotes the level the block needs: %s" % body)


func test_a_block_that_touches_nothing_you_own_explains_adjacency() -> void:
	var sim := CitySim.boot_from_files()
	var block_id := _not_adjacent(sim)
	assert_ne(block_id, "", "doc 09's map has non-adjacent purchasable-level land")
	var rows: Array = (_model(sim).block_view(block_id)["action"] as Dictionary)["blockers"]
	assert_eq(rows.size(), 1)
	var row: Dictionary = rows[0]
	assert_eq(row["canonical"], &"E_NOT_ADJACENT")
	assert_ne(str(row["body"]), str(row["key"]), "E_NOT_ADJACENT has copy")
	assert_true(str(row["body"]).contains(sim.world.block(block_id).label),
			"and names the block: %s" % row["body"])


func test_every_land_refusal_the_sim_can_raise_has_copy() -> void:
	# The gap this closes: `RequirementFormatter` knew nothing about doc 09's
	# codes, so an S4 blocker would have rendered as `BLOCKED BY E_NOT_ADJACENT`.
	var formatter := RequirementFormatter.new(_cfg())
	for code: StringName in LandPanelModel.BUY_CODES + LandPanelModel.DEVELOP_CODES:
		assert_true(RequirementFormatter.is_known(code), "%s is in the table" % code)
		var row := formatter.format(code, {"at": "B4", "cost": 100, "balance": 0})
		assert_ne(str(row["body"]), str(row["key"]), "%s has a body" % code)
		assert_false(str(row["body"]).contains("{"), "%s filled every slot" % code)
		assert_true(_cfg().has_string(RequirementFormatter.string_key(code,
				RequirementFormatter.TITLE_SUFFIX)), "%s has an authored title" % code)


# ===========================================================================
# The two-step flow (doc 12 §2.8 items 3 and 4)
# ===========================================================================

func test_purchase_leaves_the_block_owned_and_undeveloped() -> void:
	# `CitySim.cmd_buy_block` defaults to auto_develop = true, which is right for
	# a script and wrong for this panel: §2.8's flow is PURCHASE, then DEVELOP.
	var sim := CitySim.boot_from_files()
	sim.treasury.balance = 500_000
	var model := _model(sim)
	var block_id := _purchasable(sim)
	var result := model.buy(block_id)
	assert_true(bool(result["ok"]))
	var block := sim.world.block(block_id)
	assert_true(block.is_owned())
	assert_eq(block.development_state, &"UNDEVELOPED",
			"the panel never auto-develops behind the player's back")
	var view := model.block_view(block_id)
	assert_eq(view["stage"], LandPanelModel.STAGE_OWNED)
	assert_eq((view["action"] as Dictionary)["id"], LandPanelModel.ACTION_DEVELOP,
			"§2.8: the primary button becomes DEVELOP")
	assert_true(bool((view["action"] as Dictionary)["enabled"]))


func test_purchase_charges_the_quoted_price() -> void:
	var sim := CitySim.boot_from_files()
	sim.treasury.balance = 500_000
	var model := _model(sim)
	var block_id := _purchasable(sim)
	var quoted := int(model.block_view(block_id)["price"])
	var before := sim.treasury.balance
	model.buy(block_id)
	assert_eq(before - sim.treasury.balance, quoted,
			"the player pays exactly what the panel said")


func test_develop_starts_the_six_phase_pipeline_and_shows_it() -> void:
	var sim := CitySim.boot_from_files()
	sim.treasury.balance = 500_000
	var model := _model(sim)
	var block_id := _purchasable(sim)
	model.buy(block_id)
	assert_true(bool(model.develop(block_id)["ok"]))
	sim.advance_hours(2.0)
	var view := model.block_view(block_id)
	assert_eq(view["stage"], LandPanelModel.STAGE_DEVELOPING)
	var phases: Array = view["phases"]
	assert_eq(phases.size(), DevelopmentController.PHASES.size(),
			"all six phases are listed from the first tap, not just the live one")
	var active := 0
	for entry: Variant in phases:
		var phase: Dictionary = entry
		assert_ne(str(phase["cost_text"]), "", "%s quotes doc 03 §2.8" % phase["id"])
		if StringName(str(phase["state"])) == LandPanelModel.PHASE_STATE_ACTIVE:
			active += 1
			assert_true(float(phase["progress"]) > 0.0, "the live phase has moved")
	assert_eq(active, 1, "exactly one phase runs at a time (doc 09 §2.3)")
	var progress: Dictionary = view["progress"]
	assert_true(bool(progress["active"]))
	assert_true(float(progress["eta_minutes"]) > 0.0, "the ETA is a real number")
	assert_ne(str(progress["eta_text"]), HudModel.NO_DATA)
	assert_true(float(progress["eta_total_minutes"]) >= float(progress["eta_minutes"]),
			"the whole block takes at least as long as the phase running now")
	assert_ne(str(progress["crew"]), "", "§2.8 names the assigned crew")


func test_a_developed_block_is_not_a_panel_the_player_can_open() -> void:
	var sim := CitySim.boot_from_files()
	var model := _model(sim)
	assert_false(model.opens_for(_first_owned_ready(sim)),
			"finished ground is a tap on the map, not on a block")
	assert_true(model.opens_for(_purchasable(sim)))
	assert_false(model.opens_for("B_99_99"))


func test_the_eta_is_the_construction_queues_own_arithmetic() -> void:
	# `ConstructionQueue.eta_game_minutes` is a *presentation* of the exact
	# integer accumulator, so it has to agree with running the accumulator.
	var queue := ConstructionQueue.new()
	var job_id := queue.submit(&"development", "B_9_9", 10.0)
	queue.assign_crew(job_id, "CREW-1")
	var eta := queue.eta_game_minutes(job_id)
	assert_almost_eq(eta, 600.0, 0.5, "10 crew-hours at one full crew is 10 game-hours")
	var ctx := TimeContext.new()
	ctx.dt_game_seconds = 3600
	ctx.channels_hour = {"construction_rate": 1.0}
	queue.advance(ctx)
	assert_almost_eq(queue.eta_game_minutes(job_id), 540.0, 0.5,
			"one hour of work later, one hour less to go")
	assert_almost_eq(queue.eta_game_minutes(job_id, 0.5), 1080.0, 1.0,
			"a halved construction_rate doubles the wait")


func test_an_uncrewed_job_says_so_instead_of_quoting_zero() -> void:
	var queue := ConstructionQueue.new()
	var job_id := queue.submit(&"development", "B_9_9", 10.0)
	assert_eq(queue.eta_game_minutes(job_id), -1.0)
	assert_eq(queue.units_per_game_hour(job_id), 0.0)
	assert_eq(queue.eta_game_minutes(9999), -1.0, "an unknown job is not 0:00 either")


func test_the_quoted_schedule_is_the_pipelines_own() -> void:
	# The panel's `Development time` must be the crew-hours the controller will
	# actually submit — the first-block discount included, or the tutorial block
	# would advertise twice the wait it has.
	var queue := ConstructionQueue.new()
	var world := WorldMap.new()
	world.add_block(LandBlock.from_dict({"id": "B_3_3", "grid": [3, 3],
			"ownership_state": "OWNED"}))
	var controller := DevelopmentController.new(world, queue)
	var first := controller.total_crew_hours(&"construction_crew", true)
	var later := controller.total_crew_hours(&"construction_crew", false)
	assert_almost_eq(later, 97.6, 0.01, "doc 09 §2.3's generic-crew schedule")
	assert_almost_eq(first, later * DevelopmentController.FIRST_BLOCK_TIME_MULT, 0.01)
	# And the submitted job has to match the quote, phase for phase.
	controller.start_development("B_3_3", &"construction_crew")
	var record := controller.active_view("B_3_3")
	var job := queue.job(int(record["job_id"]))
	assert_almost_eq(float(job["required_crew_hours"]),
			controller.phase_crew_hours(DevelopmentController.PHASES[0],
					&"construction_crew", true), 0.0001,
			"the quote and the job are one formula")


# ===========================================================================
# The tap seam (doc 12 §2.8's entry, doc 91 D-5)
# ===========================================================================

func test_a_tap_on_unowned_ground_resolves_to_a_block() -> void:
	# Before S4 this returned "" and the shell deselected — which is exactly why
	# land was unreachable. The seam now answers with the block.
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim)
	var block_id := _purchasable(sim)
	var block := sim.world.block(block_id)
	var tile: Vector2i = block.grid * TileGrid.TILES_PER_BLOCK + Vector2i(3, 3)
	var point := Vector3(float(tile.x) * controller.tile_m + 1.0, 0.0,
			float(tile.y) * controller.tile_m + 1.0)
	assert_eq(controller.sim_id_at_ground(point), "", "no building there")
	assert_eq(controller.block_id_at_ground(point), block_id)
	var pick := controller.pick_at_ground(point)
	assert_eq(pick["kind"], BuildController.PICK_BLOCK)
	assert_eq(str(pick["id"]), block_id)


func test_a_tap_on_a_building_still_wins_over_its_block() -> void:
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim)
	var ids := sim.buildings.keys()
	ids.sort()
	var building: Building = sim.buildings[str(ids[0])]
	var point := Vector3(float(building.origin.x) * controller.tile_m + 1.0, 0.0,
			float(building.origin.y) * controller.tile_m + 1.0)
	var pick := controller.pick_at_ground(point)
	assert_eq(pick["kind"], BuildController.PICK_BUILDING)
	assert_eq(str(pick["id"]), str(ids[0]))
	assert_ne(str(pick["block"]), "", "the block comes back anyway")


func test_a_tap_on_finished_ground_still_deselects() -> void:
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim)
	var block := sim.world.block(_first_owned_ready(sim))
	var origin: Vector2i = block.grid * TileGrid.TILES_PER_BLOCK
	for z in range(origin.y, origin.y + TileGrid.TILES_PER_BLOCK):
		for x in range(origin.x, origin.x + TileGrid.TILES_PER_BLOCK):
			if sim.world.grid.building_at(x, z) > 0:
				continue
			var point := Vector3(float(x) * controller.tile_m + 1.0, 0.0,
					float(z) * controller.tile_m + 1.0)
			assert_eq(controller.pick_at_ground(point)["kind"],
					BuildController.PICK_NONE,
					"owned, developed and empty is not a land panel")
			return


func test_a_tap_off_the_map_picks_nothing() -> void:
	var controller := BuildController.new(CitySim.boot_from_files())
	var pick := controller.pick_at_ground(Vector3(-4000.0, 0.0, -4000.0))
	assert_eq(pick["kind"], BuildController.PICK_NONE)
	assert_eq(str(pick["block"]), "")


# ===========================================================================
# The panel on the real scaffold
# ===========================================================================

func _mount(sim: CitySim) -> UIRoot:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	root.config = UIConfig.load_from_files()
	_tree().root.add_child(root)
	root.initialize()
	root.land_panel.setup(root.config, _model(sim))
	return root


func _unmount(root: UIRoot) -> void:
	_tree().root.remove_child(root)
	root.free()


func test_the_panel_is_in_the_scene_and_opens_on_a_block() -> void:
	var sim := CitySim.boot_from_files()
	sim.treasury.balance = 500_000
	var root := _mount(sim)
	assert_ne(root.land_panel, null, "S4 has a node in ui_root.tscn (doc 12 §2.2)")
	assert_false(root.land_panel.is_open())
	assert_true(root.show_land_block(_purchasable(sim)))
	assert_true(root.land_panel.is_open())
	var button := root.land_panel.action_button()
	assert_true(button.visible)
	assert_false(button.disabled)
	assert_true(button.text.contains("$"), "the button names the price: %s" % button.text)
	assert_eq(root.land_panel.risk_rows().size(),
			(root.land_panel.view()["risks"] as Array).size())
	assert_eq(root.land_panel.phase_rows().size(), DevelopmentController.PHASES.size())
	_unmount(root)


func test_the_panel_and_the_building_panel_never_share_the_edge() -> void:
	# D-16: two 300 dp panels on the same layer and the same edge do not occlude,
	# they collide — and so do their tap targets.
	var sim := CitySim.boot_from_files()
	var root := _mount(sim)
	var building_panel := root.safe_area.get_node_or_null(
			"PanelLayer/BuildingPanel") as BuildingPanel
	building_panel.setup(root.config, BuildController.new(sim))
	root.show_land_block(_purchasable(sim))
	var ids := sim.buildings.keys()
	ids.sort()
	building_panel.show_building(str(ids[0]))
	assert_true(building_panel.is_open())
	assert_false(root.land_panel.is_open(), "S5 put S4 away")
	root.show_land_block(_purchasable(sim))
	assert_false(building_panel.is_open(), "and S4 puts S5 away")
	_unmount(root)


func test_the_panel_buys_through_the_command_and_re_reads_the_answer() -> void:
	var sim := CitySim.boot_from_files()
	sim.treasury.balance = 500_000
	var root := _mount(sim)
	var block_id := _purchasable(sim)
	root.show_land_block(block_id)
	var seen: Array = []
	root.land_purchased.connect(func(id: String, result: Dictionary) -> void:
		seen.append([id, result]))
	root.land_panel.action_button().pressed.emit()
	assert_eq(seen.size(), 1, "the shell hears about it once")
	assert_true(bool((seen[0][1] as Dictionary)["ok"]))
	assert_true(sim.world.block(block_id).is_owned())
	# The panel re-read the sim rather than predicting: the button is DEVELOP now.
	assert_eq((root.land_panel.view()["action"] as Dictionary)["id"],
			LandPanelModel.ACTION_DEVELOP)
	_unmount(root)


func test_a_broke_panel_shows_the_blocker_row_and_a_dead_button() -> void:
	var sim := CitySim.boot_from_files()
	sim.treasury.balance = 0
	var root := _mount(sim)
	root.show_land_block(_purchasable(sim))
	assert_true(root.land_panel.action_button().disabled)
	assert_eq(root.land_panel.blocker_rows().size(), 1)
	var row: Node = root.land_panel.blocker_rows()[0]
	var body := row.get_node_or_null("Body") as Label
	assert_ne(body, null)
	assert_true(body.text.contains("$"), "the row is the formatter's sentence")
	_unmount(root)
