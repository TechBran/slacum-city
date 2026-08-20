extends SimTest
## Doc 12 §2.7's **drag-path** half: `ui/path_tool.gd`, the run cards it puts on
## the build sheet, and the four `CitySim` verbs they reach.
##
## The point of this suite is the one doc 93 §G2 makes: these verbs shipped in
## Wave 5 with **no door** (doc 92 §17.6). So every assertion here is about a
## door — a card exists, a tap enters, a sweep prices, a button commits, and the
## sim's own answer is the one the bar shows. Where a verdict is asserted it is
## asserted against a **real `CitySim`**, exactly as `test_build_controller.gd`
## asserts the footprint half: the preflight and the command are one code path,
## and a test that stubbed the sim would be testing the stub.


func _sim() -> CitySim:
	return CitySim.boot_from_files()


func _tool(sim: CitySim) -> PathTool:
	return PathTool.new(sim, RequirementFormatter.load_from_files())


## A tile inside the founding city that carries a road, plus one of its
## neighbours that does not. The tests never NAME a tile: doc 09's starter city
## is data and it may move.
static func _road_and_neighbour(sim: CitySim) -> Array[Vector2i]:
	for z in TileGrid.SIZE:
		for x in TileGrid.SIZE:
			if sim.world.grid.road_class_at(x, z) == TileGrid.ROAD_NONE:
				continue
			for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1),
					Vector2i(-1, 0), Vector2i(0, -1)]:
				var q := Vector2i(x, z) + d
				if not TileGrid.in_bounds(q.x, q.y):
					continue
				if sim.world.grid.road_class_at(q.x, q.y) != TileGrid.ROAD_NONE:
					continue
				if not sim.world.grid.can_place(q, Vector2i.ONE):
					continue
				var block := sim.world.block_of_tile(q.x, q.y)
				if block == null or not block.is_ready():
					continue
				return [Vector2i(x, z), q] as Array[Vector2i]
	return [] as Array[Vector2i]


static func _first_street(sim: CitySim) -> Vector2i:
	for z in TileGrid.SIZE:
		for x in TileGrid.SIZE:
			if sim.world.grid.road_class_at(x, z) == TileGrid.ROAD_STREET:
				return Vector2i(x, z)
	return Vector2i(-1, -1)


# ===========================================================================
# 1. Geometry — doc 12 §2.7's "L-shaped (Manhattan, longest-leg-first)"
# ===========================================================================

func test_a_straight_sweep_is_a_straight_run() -> void:
	var run := PathTool.l_path(Vector2i(4, 9), Vector2i(8, 9))
	assert_eq(run.size(), 5, "inclusive of both ends")
	assert_eq(run[0], Vector2i(4, 9), "ordered from the anchor")
	assert_eq(run[4], Vector2i(8, 9))
	for i in run.size():
		assert_eq((run[i] as Vector2i).y, 9, "no jog on a straight sweep")


func test_a_single_tile_run_is_one_tile() -> void:
	var run := PathTool.l_path(Vector2i(3, 3), Vector2i(3, 3))
	assert_eq(run.size(), 1)
	assert_eq(run[0], Vector2i(3, 3))


func test_the_longest_leg_goes_first_and_the_corner_appears_once() -> void:
	# 6 across, 2 down: the doc's rule walks X first, so the corner is (10, 4).
	var run := PathTool.l_path(Vector2i(4, 4), Vector2i(10, 6))
	assert_eq(run.size(), 9, "6 + 2 steps, both ends included, corner not doubled")
	assert_eq(run[0], Vector2i(4, 4))
	assert_eq(run[6], Vector2i(10, 4), "the corner is where the long leg ends")
	assert_eq(run[8], Vector2i(10, 6))
	var seen: Array[Vector2i] = []
	for entry: Vector2i in run:
		assert_false(seen.has(entry), "no tile is emitted twice")
		seen.append(entry)


func test_a_tall_sweep_walks_z_first() -> void:
	var run := PathTool.l_path(Vector2i(4, 4), Vector2i(6, 10))
	assert_eq(run[0], Vector2i(4, 4))
	assert_eq(run[6], Vector2i(4, 10), "the long leg is the Z one this time")
	assert_eq(run[run.size() - 1], Vector2i(6, 10))


func test_a_square_sweep_breaks_the_tie_toward_x() -> void:
	# |dx| == |dz| is the case a "longer axis" rule has to decide explicitly, or
	# the ghost flips diagonally as the thumb crosses 45°.
	var run := PathTool.l_path(Vector2i(0, 0), Vector2i(3, 3))
	assert_eq(run[3], Vector2i(3, 0), "the tie goes to X, every time")


func test_the_run_is_ordered_from_the_anchor_in_both_directions() -> void:
	# Doc 05 §2.2 reads `path[0]` as the tap onto the existing network, so a
	# sweep that goes left must still start at the anchor.
	var run := PathTool.l_path(Vector2i(10, 10), Vector2i(6, 10))
	assert_eq(run[0], Vector2i(10, 10))
	assert_eq(run[run.size() - 1], Vector2i(6, 10))


# ===========================================================================
# 2. The roster — one card per placeable run, priced from the economy tables
# ===========================================================================

func test_the_two_category_literals_match_the_controller() -> void:
	# `PathTool` may not depend on `BuildController` (the dependency runs the
	# other way, so the two class files do not form a cycle), which means the
	# category names are spelled twice. This is the assertion that keeps them
	# one name.
	assert_eq(PathTool.CATEGORY_INFRASTRUCTURE, BuildController.CATEGORY_INFRASTRUCTURE)
	assert_true(BuildController.CATEGORY_ORDER.has(PathTool.CATEGORY_ROADS),
			"the ROADS tab has a place in the sheet's tab order")


func test_the_road_class_constants_are_doc_tens_own() -> void:
	assert_eq(PathTool.ROAD_CLASS_NONE, RoadTunables.CLASS_NONE)
	assert_eq(PathTool.ROAD_CLASS_STREET, RoadTunables.CLASS_STREET)
	assert_eq(PathTool.ROAD_CLASS_AVENUE, RoadTunables.CLASS_AVENUE)
	assert_eq(PathTool.ROAD_CLASS_STREET, TileGrid.ROAD_STREET,
			"doc 09's grid and doc 10's tunables agree on the class integers")


func test_every_card_quotes_a_price_read_from_the_economy_tables() -> void:
	var sim := _sim()
	var tool := _tool(sim)
	var cards := tool.cards()
	assert_eq(cards.size(), 6,
			"four road verbs plus the two water-main tiers doc 05 offers today")
	var m_build := float(sim.treasury.difficulty().get("M_build", 1.0))
	var by_id: Dictionary = {}
	for card: Dictionary in cards:
		by_id[str(card["id"])] = card
		assert_true(str(card["name_key"]).begins_with("ui_build_card_"), "G-8 key")
		assert_eq(str(card["component_domain"]), "",
				"a run card is not a component card; `path_verb` is what routes it")
		assert_true(str(card["path_verb"]) != "")
		assert_false(bool(card["locked"]), "no run verb is behind a city level")
	assert_eq(int((by_id["road_street"] as Dictionary)["cost"]),
			sim.econ_curves.road_build_cost("STREET", m_build),
			"doc 03 §2.13(d), through CostCurves — never authored in ui/")
	assert_eq(int((by_id["road_avenue"] as Dictionary)["cost"]),
			sim.econ_curves.road_build_cost("AVENUE", m_build))
	assert_eq(int((by_id["road_widen"] as Dictionary)["cost"]),
			sim.econ_curves.road_upgrade_cost("STREET_TO_AVENUE", m_build))
	assert_eq(int((by_id["water_main_service"] as Dictionary)["cost"]),
			sim.econ_curves.water_main_cost_per_tile("service", m_build))
	assert_eq(int((by_id["water_main_trunk"] as Dictionary)["cost"]),
			sim.econ_curves.water_main_cost_per_tile("trunk", m_build))
	# The refund card is the odd one: it costs nothing and it always affords.
	var remove: Dictionary = by_id["road_remove"]
	assert_eq(int(remove["cost"]), 0)
	assert_true(bool(remove["affordable"]))
	assert_eq(tool.per_tile_price("road_remove"),
			sim.econ_curves.road_demolish_refund("STREET"))


func test_the_cards_land_on_the_two_tabs_doc_twelve_names() -> void:
	var tool := _tool(_sim())
	for card: Dictionary in tool.cards():
		var expected := PathTool.CATEGORY_ROADS if str(card["id"]).begins_with("road_") \
				else PathTool.CATEGORY_INFRASTRUCTURE
		assert_eq(str(card["category"]), expected,
				"%s sits on the tab §2.7's table files it under" % card["id"])


func test_a_flag_locked_tier_is_not_offered_at_all() -> void:
	var sim := _sim()
	var tool := _tool(sim)
	assert_false(sim.water.data.flag("levels_4_5_enabled"),
			"the fixture this assertion is written against")
	for card: Dictionary in tool.cards():
		assert_ne(str(card["id"]), "water_main_arterial",
				"a card that can never be placed is noise, not progression")
	assert_true(tool.available("water_main_service"))


# ===========================================================================
# 3. The state machine — aim, anchor, draw, commit
# ===========================================================================

func test_a_fresh_tool_is_idle_and_shows_nothing() -> void:
	var tool := _tool(_sim())
	assert_false(tool.is_active())
	assert_false(bool(tool.ghost()["visible"]))
	assert_false(bool(tool.placement_view()["active"]))


func test_entering_a_card_aims_and_the_first_move_does_not_pin_the_anchor() -> void:
	# The whole reason the anchor is a button press: a desktop HOVER and a device
	# TAP arrive here as the same call, so a move may never commit a start tile.
	var sim := _sim()
	var tool := _tool(sim)
	assert_true(bool(tool.enter("road_street")["ok"]))
	assert_true(tool.is_aiming())
	tool.move_to_tile(Vector2i(40, 40))
	assert_true(tool.is_aiming(), "still aiming — a move is not a decision")
	assert_eq(tool.tiles().size(), 1, "the ghost is one tile while it hunts")
	tool.move_to_tile(Vector2i(44, 40))
	assert_eq(tool.tiles().size(), 1, "and it is still one tile, at the new place")
	assert_eq(tool.tiles()[0], Vector2i(44, 40))
	assert_eq(str(tool.placement_view()["mode"]), String(PathTool.STATE_AIMING))


func test_starting_a_run_pins_the_anchor_and_the_sweep_prices_it() -> void:
	var sim := _sim()
	var pair := _road_and_neighbour(sim)
	assert_eq(pair.size(), 2, "the founding city has a road with a free neighbour")
	var tool := _tool(sim)
	tool.enter("road_street")
	tool.move_to_tile(pair[1])
	tool.begin_run()
	assert_true(tool.is_drawing())
	assert_eq(tool.anchor, pair[1], "START pins the tile the ghost was on")
	var view := tool.placement_view()
	assert_eq(int(view["tile_count"]), 1)
	assert_eq(int(view["cost"]), sim.econ_curves.road_build_cost("STREET",
			float(sim.treasury.difficulty().get("M_build", 1.0))),
			"one fresh tile is billed at exactly one tile's price")
	assert_eq(str(view["verdict"]), String(PathTool.VERDICT_VALID),
			"beside an existing road, so doc 10's E_NOT_CONNECTED does not fire")
	assert_true(bool(view["can_confirm"]))


func test_the_quote_is_the_commands_own_and_the_commit_charges_it() -> void:
	var sim := _sim()
	var pair := _road_and_neighbour(sim)
	var tool := _tool(sim)
	tool.enter("road_street")
	tool.move_to_tile(pair[1])
	tool.begin_run()
	var quoted := int(tool.placement_view()["cost"])
	var before := sim.treasury.balance
	var result := tool.commit()
	assert_true(bool(result["ok"]), str(result))
	assert_eq(before - sim.treasury.balance, quoted,
			"the bar quoted the price the treasury actually paid")
	assert_eq(sim.world.grid.road_class_at(pair[1].x, pair[1].y), TileGrid.ROAD_STREET,
			"and doc 10 stamped the tile")
	# A player laying a grid lays several runs: the tool re-arms rather than
	# dropping back out to the sheet.
	assert_true(tool.is_active())
	assert_true(tool.is_aiming())


func test_a_run_that_crosses_an_existing_road_bills_only_the_fresh_tiles() -> void:
	# Doc 10 §2.13's own rule, and the reason the ghost dims what it passes over.
	var sim := _sim()
	var street := _first_street(sim)
	assert_true(street.x >= 0, "the founding city has a street")
	var tool := _tool(sim)
	tool.enter("road_street")
	tool.move_to_tile(street)
	tool.begin_run()
	var flags := tool.billable_flags()
	assert_eq(flags.size(), 1)
	assert_false(flags[0], "a tile that already carries a road is not billed")
	assert_eq(str(tool.placement_view()["verdict"]), String(PathTool.VERDICT_BLOCKED),
			"and a run of nothing but existing road is E_ALREADY_ROAD")
	assert_eq(str(tool.verdict()["code"]), "E_ALREADY_ROAD")


func test_a_disconnected_run_is_refused_in_the_commands_own_words() -> void:
	var sim := _sim()
	var tool := _tool(sim)
	# Far from anything the founding city built: doc 10 refuses a run that
	# touches no existing road.
	var lonely := Vector2i(TileGrid.SIZE - 2, TileGrid.SIZE - 2)
	tool.enter("road_street")
	tool.move_to_tile(lonely)
	tool.begin_run()
	var view := tool.placement_view()
	assert_ne(str(view["verdict"]), String(PathTool.VERDICT_VALID))
	assert_false(bool(view["can_confirm"]), "and PLACE is dead")
	assert_false((view["failure"] as Dictionary).is_empty(),
			"the bar has a sentence to show, not just a colour")
	assert_true(bool(sim.treasury.balance > 0))
	var refused := tool.commit()
	assert_false(bool(refused["ok"]), "a blocked run cannot be committed past the bar")


func test_the_run_is_capped_so_a_slipped_thumb_cannot_quote_the_map() -> void:
	var sim := _sim()
	var tool := _tool(sim)
	tool.enter("road_street")
	tool.move_to_tile(Vector2i(4, 4))
	tool.begin_run()
	tool.move_to_tile(Vector2i(TileGrid.SIZE - 1, 4))
	assert_eq(tool.tiles().size(), tool.max_run_tiles,
			"the far end is truncated, so the preview IS the run")
	assert_eq(tool.tiles()[0], Vector2i(4, 4), "and the anchor end is the one kept")


func test_restart_unpins_the_anchor_without_dropping_the_card() -> void:
	var sim := _sim()
	var tool := _tool(sim)
	tool.enter("road_street")
	tool.move_to_tile(Vector2i(40, 40))
	tool.begin_run()
	tool.move_to_tile(Vector2i(44, 40))
	assert_true(tool.tiles().size() > 1)
	tool.reset_run()
	assert_true(tool.is_aiming(), "back to hunting for a start tile")
	assert_eq(tool.card_id, "road_street", "and still holding the card")
	assert_eq(tool.tiles().size(), 1)


func test_cancel_returns_the_tool_to_idle() -> void:
	var tool := _tool(_sim())
	tool.enter("road_avenue")
	tool.move_to_tile(Vector2i(40, 40))
	tool.begin_run()
	tool.cancel()
	assert_false(tool.is_active())
	assert_eq(tool.card_id, "")
	assert_true(tool.tiles().is_empty())
	# Idempotent: the Android back stack calls it blind (doc 12 §2.15).
	tool.cancel()
	assert_false(tool.is_active())


# ===========================================================================
# 4. The other three verbs
# ===========================================================================

func test_widen_upgrades_a_street_and_bills_doc_threes_upgrade_price() -> void:
	var sim := _sim()
	var street := _first_street(sim)
	var tool := _tool(sim)
	tool.enter("road_widen")
	tool.move_to_tile(street)
	tool.begin_run()
	var view := tool.placement_view()
	assert_eq(int(view["cost"]), sim.econ_curves.road_upgrade_cost("STREET_TO_AVENUE",
			float(sim.treasury.difficulty().get("M_build", 1.0))))
	assert_true(tool.billable_flags()[0], "a STREET is exactly what widen touches")
	var before := sim.treasury.balance
	var result := tool.commit()
	assert_true(bool(result["ok"]), str(result))
	assert_eq(before - sim.treasury.balance, int(view["cost"]))


func test_remove_quotes_a_refund_rather_than_a_cost() -> void:
	var sim := _sim()
	var tool := _tool(sim)
	# A tile the player laid themselves, so removing it cannot orphan anything
	# doc 10 §2.13 is protecting.
	var pair := _road_and_neighbour(sim)
	var build := _tool(sim)
	build.enter("road_street")
	build.move_to_tile(pair[1])
	build.begin_run()
	assert_true(bool(build.commit()["ok"]))

	tool.enter("road_remove")
	tool.move_to_tile(pair[1])
	tool.begin_run()
	var view := tool.placement_view()
	assert_true(bool(view["refunds"]), "the card pays rather than charges")
	assert_true(int(view["cost"]) < 0, "one field, both directions")
	assert_eq(-int(view["cost"]), sim.econ_curves.road_demolish_refund("STREET"))
	var before := sim.treasury.balance
	assert_true(bool(tool.commit()["ok"]))
	assert_eq(sim.treasury.balance - before, -int(view["cost"]),
			"and the treasury went UP by the quote")


func test_a_water_main_needs_two_tiles_before_it_can_be_priced() -> void:
	# Doc 05 §6 refuses a main shorter than two tiles, so the aim state has
	# nothing to quote — and says so instead of inventing an error.
	var sim := _sim()
	var tool := _tool(sim)
	tool.enter("water_main_service")
	var node_tile := _first_main_tile(sim)
	assert_true(node_tile.x >= 0, "doc 09 authored a water topology to tap")
	tool.move_to_tile(node_tile)
	assert_true(tool.quote().is_empty(), "one tile is not a run doc 05 will price")
	assert_true((tool.verdict() as Dictionary).is_empty())
	assert_eq(str(tool.placement_view()["verdict"]), String(PathTool.VERDICT_VALID),
			"an aim tile is neutral, not blocked")


func test_a_water_main_run_starts_on_the_network_and_is_billed_per_tile() -> void:
	var sim := _sim()
	var tool := _tool(sim)
	var start := _first_main_tile(sim)
	tool.enter("water_main_service")
	tool.move_to_tile(start)
	tool.begin_run()
	tool.move_to_tile(start + Vector2i(1, 0))
	var view := tool.placement_view()
	assert_eq(int(view["tile_count"]), 2)
	if str(view["verdict"]) == String(PathTool.VERDICT_VALID):
		assert_eq(int(view["cost"]), 2 * sim.econ_curves.water_main_cost_per_tile(
				"service", float(sim.treasury.difficulty().get("M_build", 1.0))),
				"doc 03 §8 water, per tile laid")
	else:
		# The neighbour is not always developed ground in every fixture; what
		# matters is that the refusal is doc 05's own and reaches the bar.
		assert_false((view["failure"] as Dictionary).is_empty())
	for billed: bool in tool.billable_flags():
		assert_true(billed, "doc 05 bills every tile of a main, the tap included")


static func _first_main_tile(sim: CitySim) -> Vector2i:
	for z in TileGrid.SIZE:
		for x in TileGrid.SIZE:
			if not sim.water.nearest_main_tile(Vector2i(x, z), 0).is_empty():
				return Vector2i(x, z)
	return Vector2i(-1, -1)


# ===========================================================================
# 5. The ghost — what the renderer is handed
# ===========================================================================

func test_the_ghost_carries_one_centre_per_tile_and_the_verdict_state() -> void:
	var sim := _sim()
	var pair := _road_and_neighbour(sim)
	var tool := _tool(sim)
	tool.enter("road_street")
	tool.move_to_tile(pair[1])
	tool.begin_run()
	var ghost := tool.ghost()
	assert_true(bool(ghost["visible"]))
	assert_eq((ghost["centres"] as Array).size(), (ghost["tiles"] as Array).size())
	assert_eq((ghost["billable"] as Array).size(), (ghost["tiles"] as Array).size())
	assert_eq(ghost["anchor"], pair[1])
	assert_eq(StringName(str(ghost["state"])), HudModel.STATE_NORMAL,
			"a valid run tints with §2.5's NORMAL, same ladder as the box ghost")
	var centre: Vector3 = (ghost["centres"] as Array)[0]
	assert_almost_eq(centre.x, float(pair[1].x) * tool.tile_m + tool.tile_m * 0.5, 0.001)


func test_a_blocked_run_hands_the_renderer_the_critical_state() -> void:
	var sim := _sim()
	var tool := _tool(sim)
	tool.enter("road_street")
	tool.move_to_tile(Vector2i(TileGrid.SIZE - 2, TileGrid.SIZE - 2))
	tool.begin_run()
	assert_eq(StringName(str(tool.ghost()["state"])), HudModel.STATE_CRITICAL)


# ===========================================================================
# 6. `game/ui/path_ghost_view.gd` — the MultiMesh the run is drawn with
# ===========================================================================

func test_the_ghost_view_draws_one_slab_per_tile_and_hides_on_an_empty_run() -> void:
	var view := PathGhostView.new()
	view.setup(UIConfig.load_from_files(), 8.0)
	assert_eq(view.slab_count(), 0, "a fresh ghost draws nothing")

	var sim := _sim()
	var pair := _road_and_neighbour(sim)
	var tool := _tool(sim)
	tool.enter("road_street")
	tool.move_to_tile(pair[1])
	tool.begin_run()
	tool.move_to_tile(pair[1] + Vector2i(3, 0))
	view.apply(tool.ghost())
	assert_true(view.visible)
	assert_eq(view.slab_count(), tool.tiles().size(),
			"one slab per tile — a run's refusal is usually about ONE tile in it")

	view.apply({"visible": false})
	assert_false(view.visible)
	assert_eq(view.slab_count(), 0)
	view.free()


func test_the_ghost_views_tints_are_the_same_four_states_the_box_ghost_uses() -> void:
	var view := PathGhostView.new()
	view.setup(UIConfig.load_from_files(), 8.0)
	var normal := view.tint_for(HudModel.STATE_NORMAL)
	var critical := view.tint_for(HudModel.STATE_CRITICAL)
	assert_true(normal != critical, "the ladder has more than one rung")
	assert_almost_eq(normal.a, view.tint_alpha, 1e-6,
			"and every rung is at §2.7's validity tint alpha")
	# A token the palette does not carry falls back rather than inventing a hue.
	assert_eq(view.tint_for(&"not_a_state"), critical)
	view.free()
