extends SimTest
## **The LOT rule** (Wave 29, doc 02 §2.3a, doc 93 §BE, RR-236..239).
##
## A building reserves the footprint of its FINAL form the day it is founded, so
## that it has room to grow old in. These tests hold the four halves of that:
## the catalog's two extents, the grid primitive that lets a building grow into
## its own reservation, the placement and upgrade doors, and the migration that
## gives a legacy city its lots without moving or bulldozing anything.


## The site search every test here uses: the ground `archetype`'s LOT needs.
static func _lot_site(sim: CitySim, archetype: String) -> Vector2i:
	var size := sim.lot_for(archetype)
	for z in range(32, 80):
		for x in range(32, 80):
			var origin := Vector2i(x, z)
			if sim.world.grid.can_place(origin, size) and sim.grid.would_serve(origin):
				return origin
	return Vector2i(-1, -1)


# ------------------------------------------------------- doc 02 §2.3a: the two extents

func test_catalog_publishes_lot_and_built_separately() -> void:
	var sim := CitySim.boot_from_files()
	# The three doc-02 growers, at the ceiling each can actually reach.
	assert_eq(sim.built_for("store", 1), Vector2i(1, 1), "a new store covers one tile")
	assert_eq(sim.built_for("store", 3), Vector2i(2, 2), "doc 02: it covers four at L3")
	assert_eq(sim.lot_for("store"), Vector2i(2, 2), "…so its lot is 2×2 from day one")
	assert_eq(sim.lot_for("power_facility"), Vector2i(4, 4), "3×3 built, 4×4 at L4")
	assert_eq(sim.lot_for("construction_yard"), Vector2i(3, 3), "2×2 built, 3×3 at L4")
	# The nine that never grow answer their own footprint, so the rule is
	# invisible on them.
	for flat in ["house", "apartment", "office", "high_rise", "data_center",
			"police_station", "fire_station", "substation"]:
		assert_eq(sim.lot_for(flat), sim.built_for(flat, 1),
				"%s does not grow, so its lot is its footprint" % flat)


func test_lot_is_measured_to_the_reachable_ceiling_not_the_catalog_top() -> void:
	var sim := CitySim.boot_from_files()
	# Doc 05 ships `levels_4_5_enabled` false, so a water shell caps at L3 and its
	# authored 4×4 at L5 is ground no player can ever buy (doc 93 §BE3).
	assert_false(sim.water.data.flag("levels_4_5_enabled"),
			"this test is about the shipped flag; flip it and the numbers below move")
	assert_eq(sim.archetype_top_level("water_facility"), 3)
	assert_eq(sim.lot_for("water_facility"), Vector2i(3, 3),
			"measured to L3, not to the unreachable L5 4×4")
	# The catalog half is a pure function of the table and the ceiling it is given,
	# so the same roster answers 4×4 when the ceiling is lifted.
	assert_eq(sim.catalog.lot_of("water_facility", 5), Vector2i(4, 4),
			"the table still says 4×4 at L5; only the CEILING keeps it out of the lot")


func test_water_lots_are_doc_05s_per_variant() -> void:
	var sim := CitySim.boot_from_files()
	# Doc 02's `water_facility` column is the PUMP reference row (RR-8), and two
	# of the four placeable variants grow inside the shipped ceiling (doc 93 §BE4).
	assert_eq(sim.water_lot_for("pump"), Vector2i(3, 3), "flat to L3")
	assert_eq(sim.water_lot_for("source"), Vector2i(2, 2), "flat to L2 — NOT the pump's 3×3")
	assert_eq(sim.water_lot_for("treatment"), Vector2i(3, 3), "2×2 → 3×3 at L2")
	assert_eq(sim.water_lot_for("tank"), Vector2i(3, 3), "2×2 → 3×3 at L3")


# ------------------------------------------------- doc 09 §2.1a: the grid primitive

func test_can_expand_ignores_the_buildings_own_tiles() -> void:
	var grid := TileGrid.new()
	for z in range(0, 16):
		for x in range(0, 16):
			grid.set_flag(x, z, TileGrid.FLAG_BUILDABLE)
	assert_true(grid.stamp_building(7, Vector2i(4, 4), Vector2i.ONE))
	# `can_place` refuses because tile (4,4) is OCCUPIED — by the very building
	# that is asking. That is the distinction `can_expand` exists to draw.
	assert_false(grid.can_place(Vector2i(4, 4), Vector2i(2, 2)))
	assert_true(grid.can_expand(7, Vector2i(4, 4), Vector2i(2, 2)))
	assert_true(grid.expand_building(7, Vector2i(4, 4), Vector2i(2, 2)))
	assert_eq(grid.building_at(5, 5), 7, "the new ground belongs to the same building")
	assert_eq(grid.building_at(4, 4), 7, "and the old ground still does")
	# Idempotent: running the migration twice must not be different from once.
	assert_true(grid.expand_building(7, Vector2i(4, 4), Vector2i(2, 2)))
	assert_eq(grid.building_at(5, 4), 7)


func test_can_expand_still_refuses_a_neighbours_ground() -> void:
	var grid := TileGrid.new()
	for z in range(0, 16):
		for x in range(0, 16):
			grid.set_flag(x, z, TileGrid.FLAG_BUILDABLE)
	assert_true(grid.stamp_building(7, Vector2i(4, 4), Vector2i.ONE))
	assert_true(grid.stamp_building(8, Vector2i(5, 4), Vector2i.ONE))
	assert_false(grid.can_expand(7, Vector2i(4, 4), Vector2i(2, 2)),
			"a lot may never be taken out of a neighbour")
	assert_false(grid.expand_building(7, Vector2i(4, 4), Vector2i(2, 2)))
	assert_eq(grid.building_at(5, 4), 8, "the neighbour still owns its tile")
	# A road is refused for the same reason `can_place` refuses one.
	var road := TileGrid.new()
	for z in range(0, 16):
		for x in range(0, 16):
			road.set_flag(x, z, TileGrid.FLAG_BUILDABLE)
	assert_true(road.stamp_building(3, Vector2i(4, 4), Vector2i.ONE))
	road.set_road(5, 4, TileGrid.ROAD_STREET)
	assert_false(road.can_expand(3, Vector2i(4, 4), Vector2i(2, 2)))


# ------------------------------------------------------ the placement door

func test_placement_reserves_the_lot_not_the_first_days_footprint() -> void:
	var sim := CitySim.boot_from_files()
	var origin := _lot_site(sim, "store")
	assert_true(origin.x >= 0, "the core has room for a store's lot")
	var placed := sim.cmd_place_building("store", origin)
	assert_true(bool(placed["ok"]), str(placed))
	var sim_id := String(placed["payload"]["sim_id"])
	# All four tiles are reserved on the day it is founded, at level 0.
	for d: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
		assert_eq(sim.world.grid.building_at(origin.x + d.x, origin.y + d.y),
				sim.buildings[sim_id].id,
				"the whole 2×2 lot belongs to the store at +%d,%d" % [d.x, d.y])
	assert_eq(sim.building_record(sim_id).get("footprint"), Vector2i(2, 2),
			"the record carries the RESERVED extent")
	# …and nothing else can be founded on the ground its L3 mesh will stand on.
	# At the fork this succeeded, which is the overlap doc 93 §BE2 measured.
	assert_eq(sim.cmd_place_building("house", origin + Vector2i(1, 0))["reason_code"],
			&"E_FOOTPRINT", "no second building inside the store's own lot")


func test_a_store_in_a_one_tile_hole_is_refused_rather_than_squeezed_in() -> void:
	var sim := CitySim.boot_from_files()
	var origin := _lot_site(sim, "store")
	assert_true(origin.x >= 0)
	# Box the site in on +X so only a 1×1 hole is left at `origin`.
	assert_true(bool(sim.cmd_place_building("house", origin + Vector2i(1, 0))["ok"]))
	assert_true(bool(sim.cmd_place_building("house", origin + Vector2i(0, 1))["ok"]))
	assert_true(sim.world.grid.can_place(origin, Vector2i.ONE),
			"the single tile is still free…")
	assert_eq(sim.cmd_place_building("store", origin)["reason_code"], &"E_FOOTPRINT",
			"…but a store needs its whole lot, so the door says so BEFORE taking money")
	assert_true(sim.world.grid.can_place(origin, Vector2i.ONE),
			"a refused placement reserves nothing")


func test_the_ghost_shows_the_lot() -> void:
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim, RequirementFormatter.load_from_files())
	assert_true(bool(controller.enter("store")["ok"]))
	assert_eq(controller.size, Vector2i(2, 2),
			"doc 12 D-128: the ghost is the ground the player is being asked to find")
	assert_true(bool(controller.enter("house")["ok"]))
	assert_eq(controller.size, Vector2i(1, 1), "and it is honest on a flat archetype")


# -------------------------------------------------------- the upgrade door

func test_an_upgrade_never_has_to_find_room() -> void:
	# Doc 02 §2.11's check 12 authored an `E_FOOTPRINT` on the upgrade that never
	# existed (doc 93 §BE2). Under the lot rule it CANNOT exist: a building placed
	# this way already holds every tile any rung of its ladder will ever need.
	var sim := CitySim.boot_from_files()
	for archetype in ["store", "power_facility", "construction_yard"]:
		var lot := sim.lot_for(archetype)
		for level in range(1, sim.archetype_top_level(archetype) + 1):
			var built := sim.built_for(archetype, level)
			assert_true(built.x <= lot.x and built.y <= lot.y,
					"%s L%d (%dx%d) must fit inside its own lot (%dx%d)"
					% [archetype, level, built.x, built.y, lot.x, lot.y])


func test_a_placed_store_reaches_l3_on_the_ground_it_reserved() -> void:
	var sim := CitySim.boot_from_files()
	var origin := _lot_site(sim, "store")
	assert_true(origin.x >= 0)
	var sim_id := String(sim.cmd_place_building("store", origin)["payload"]["sim_id"])
	sim.advance_hours(8.0)
	var b: Building = sim.buildings[sim_id]
	assert_eq(b.state, &"active", "the build finished")
	# Re-stat it to its grown rung the way `on_construction_completed` does, and
	# assert the ground under the bigger mesh is this building's and no one else's.
	b.level = 3
	b.stats = sim.catalog.stats("store", 3)
	assert_eq(sim.built_of_building(b), Vector2i(2, 2), "the L3 mesh covers four tiles")
	assert_true(sim.lot_lock(sim_id).is_empty(), "it holds its whole lot, so it is not locked")
	for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
		assert_eq(sim.world.grid.building_at(origin.x + d.x, origin.y + d.y), b.id,
				"tile +%d,%d under the L3 mesh belongs to the store" % [d.x, d.y])


# ---------------------------------------------------------- the migration

func test_the_founding_city_migrates_with_nothing_lot_locked() -> void:
	var sim := CitySim.boot_from_files()
	# Doc 93 §BE6. Authored with its stores two tiles apart, so every grower has
	# the room its lot needs.
	assert_eq(sim.lot_locked_ids().size(), 0, "no founding building is boxed in")
	# The eight growers: five stores, the plant, the yard, and WTR-2 — which is a
	# doc-05 TANK, the grower doc 02's pump-reference column hides (§BE4).
	var grew := 0
	for sim_id in sim.buildings:
		var b: Building = sim.buildings[sim_id]
		if sim.building_record(String(sim_id)).get("footprint") != sim.built_of_building(b):
			grew += 1
	assert_eq(grew, 8, "eight founding buildings now hold more ground than they cover")
	assert_eq(sim.building_record("STR-001").get("footprint"), Vector2i(2, 2))
	assert_eq(sim.building_record("PLANT-1").get("footprint"), Vector2i(4, 4))
	assert_eq(sim.building_record("YARD-1").get("footprint"), Vector2i(3, 3))
	assert_eq(sim.building_record("WTR-2").get("footprint"), Vector2i(3, 3),
			"the tank's lot is doc 05's, not doc 02's pump column")
	assert_eq(sim.building_record("WTR-1").get("footprint"), Vector2i(3, 3),
			"the pump does not grow, so its reservation is unchanged")


func test_a_boxed_in_building_is_lot_locked_and_never_moved_or_bulldozed() -> void:
	var sim := CitySim.boot_from_files()
	var origin := _lot_site(sim, "store")
	assert_true(origin.x >= 0)
	# A house on the tile the store's lot wants, placed FIRST so the store cannot
	# have it. Then hand the store the single tile the old rule would have given
	# it, the way a legacy body does.
	var blocker := String(sim.cmd_place_building("house",
			origin + Vector2i(1, 0))["payload"]["sim_id"])
	var store_id := "P-900"
	var b := Building.new(900, &"store", origin)
	b.level = 1
	b.state = &"active"
	b.stats = sim.catalog.stats("store", 1)
	b.max_level = sim.catalog.max_level_of("store")
	sim.buildings[store_id] = b
	sim._building_records[store_id] = {"id": store_id, "grid_id": 900, "type": "store",
			"block": "", "footprint": Vector2i.ONE, "origin_global": origin}
	assert_true(sim.world.grid.stamp_building(900, origin, Vector2i.ONE))

	var census := sim.migrate_lots("test")
	assert_true((census["expanded"] as Array).is_empty(), "there was nowhere to expand to")
	assert_true((census["locked"] as Array).has(store_id))
	# The building keeps EXACTLY the ground it had. Nothing moved, nothing fell.
	assert_eq(b.origin, origin, "a lot-locked building is never moved")
	assert_true(sim.buildings.has(blocker), "and its neighbour is never bulldozed")
	assert_eq(sim.building_record(store_id).get("footprint"), Vector2i.ONE)

	var lock := sim.lot_lock(store_id)
	assert_false(lock.is_empty())
	assert_eq(lock["held"], Vector2i.ONE)
	assert_eq(lock["lot"], Vector2i(2, 2))
	assert_eq(int(lock["reachable_level"]), 2,
			"1×1 carries a store to L2; L3 is where doc 02 makes it 2×2")
	assert_true((lock["blockers"] as Array).has(StringName(blocker)),
			"the remedy names the neighbour, not a generic 'no room'")


func test_freeing_the_ground_unlocks_the_lot_at_the_demolition() -> void:
	var sim := CitySim.boot_from_files()
	var origin := _lot_site(sim, "store")
	assert_true(origin.x >= 0)
	var blocker := String(sim.cmd_place_building("house",
			origin + Vector2i(1, 0))["payload"]["sim_id"])
	var store_id := "P-901"
	var b := Building.new(901, &"store", origin)
	b.level = 1
	b.state = &"active"
	b.stats = sim.catalog.stats("store", 1)
	sim.buildings[store_id] = b
	sim._building_records[store_id] = {"id": store_id, "grid_id": 901, "type": "store",
			"block": "", "footprint": Vector2i.ONE, "origin_global": origin}
	sim.world.grid.stamp_building(901, origin, Vector2i.ONE)
	sim.migrate_lots("test")
	assert_false(sim.lot_lock(store_id).is_empty(), "boxed in to begin with")

	# The remedy the fix router names, taken. It must land NOW — a verb whose
	# door is a restart is the shape doc 91 keeps filing (doc 93 §BE5).
	assert_true(bool(sim.cmd_demolish_building(blocker)["ok"]))
	assert_true(sim.lot_lock(store_id).is_empty(),
			"the store claims its lot at the demolition, not at the next load")
	assert_eq(sim.building_record(store_id).get("footprint"), Vector2i(2, 2))
	assert_eq(sim.world.grid.building_at(origin.x + 1, origin.y), 901)


func test_a_lot_locked_building_cannot_climb_past_the_ground_it_holds() -> void:
	# **The half that makes the rule sound.** There is no `E_FOOTPRINT` on the
	# upgrade path and this wave did not add one (doc 93 §BE2) — so without a cap
	# a boxed-in store would climb to L3, grow a 2×2 mesh over its neighbour's
	# tile, and put back the exact overlap the wave exists to close, for precisely
	# the buildings the migration could not help.
	var sim := CitySim.boot_from_files()
	var origin := _lot_site(sim, "store")
	assert_true(origin.x >= 0)
	sim.cmd_place_building("house", origin + Vector2i(1, 0))
	var store_id := "P-903"
	var b := Building.new(903, &"store", origin)
	b.level = 2
	b.state = &"active"
	b.condition = 1.0
	b.stats = sim.catalog.stats("store", 2)
	b.max_level = sim.catalog.max_level_of("store")
	sim._stamp_building_rules(b)
	sim.buildings[store_id] = b
	sim._building_records[store_id] = {"id": store_id, "grid_id": 903, "type": "store",
			"block": "", "footprint": Vector2i.ONE, "origin_global": origin}
	sim.world.grid.stamp_building(903, origin, Vector2i.ONE)
	sim.treasury.credit(500_000, &"test_grant")

	var lock := sim.lot_lock(store_id)
	assert_eq(int(lock["reachable_level"]), 2, "1×1 carries a store to L2 and no further")
	# The panel says level 2 is the top. The COMMAND has to agree, or the panel
	# was the only thing that believed it.
	var preview := sim.cmd_upgrade_building(store_id, true)
	assert_true((preview.get("payload", {}).get("blockers", []) as Array)
			.has(&"E_MAX_LEVEL"),
			"L2 IS the top of this building's ladder, on this ground: %s" % str(preview))
	assert_false(bool(sim.cmd_upgrade_building(store_id)["ok"]),
			"and the real command refuses too, so no mesh grows over the neighbour")
	assert_eq(b.level, 2, "it is still a level-2 store")

	# Free the ground and the ladder comes back — the remedy is real.
	var blocker := _neighbour_at(sim, origin + Vector2i(1, 0))
	assert_true(blocker != "", "the house is on the tile the lot wants")
	assert_true(bool(sim.cmd_demolish_building(blocker)["ok"]))
	assert_true(sim.lot_lock(store_id).is_empty(), "it holds its whole lot now")
	assert_false((sim.cmd_upgrade_building(store_id, true)
			.get("payload", {}).get("blockers", []) as Array).has(&"E_MAX_LEVEL"),
			"…so level 3 is on the table again")


## The sim id of whatever building occupies `tile`, or "".
static func _neighbour_at(sim: CitySim, tile: Vector2i) -> String:
	var grid_id := sim.world.grid.building_at(tile.x, tile.y)
	for sim_id in sim.buildings:
		if (sim.buildings[sim_id] as Building).id == grid_id:
			return String(sim_id)
	return ""


func test_the_migration_is_idempotent_and_order_stable() -> void:
	var a := CitySim.boot_from_files()
	var b := CitySim.boot_from_files()
	# Boot already migrated both. Running it again must change nothing at all…
	var again := a.migrate_lots("test")
	assert_true((again["expanded"] as Array).is_empty(), "nothing left to expand")
	assert_true((again["locked"] as Array).is_empty(), "and nothing newly locked")
	# …and two independent boots must agree, which is what the id-order tie-break
	# buys (doc 93 §BE5).
	assert_eq(a.state_hash(), b.state_hash())
	assert_eq(a.lot_locked_ids(), b.lot_locked_ids())


func test_a_legacy_body_gets_its_lots_on_restore() -> void:
	var sim := CitySim.boot_from_files(4242)
	var origin := _lot_site(sim, "store")
	assert_true(origin.x >= 0)
	var sim_id := String(sim.cmd_place_building("store", origin)["payload"]["sim_id"])
	var body := sim.canonical_capture()
	# Rewrite the player's row the way a v11 binary wrote it: the first day's
	# footprint, which is what every save on disk today carries.
	var rows: Array = body["placed_records"]
	var touched := 0
	for row: Dictionary in rows:
		if String(row["id"]) == sim_id:
			row["footprint"] = [1, 1]
			touched += 1
	assert_eq(touched, 1, "the placed row is the one a v11 body would have written")

	var restored := CitySim.boot_from_files(4242)
	restored.restore_state(body)
	assert_true(restored.buildings.has(sim_id), "the building came back")
	assert_eq(restored.building_record(sim_id).get("footprint"), Vector2i(2, 2),
			"…and the restore offered it the rest of its lot")
	assert_true(restored.lot_lock(sim_id).is_empty())


# ------------------------------------------------- the doors (doc 12 §2.9a)

func test_the_panel_shows_the_lot_and_routes_the_neighbour() -> void:
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim, RequirementFormatter.load_from_files())
	# A flat archetype draws no row at all.
	var house_origin := _lot_site(sim, "house")
	var house := String(sim.cmd_place_building("house", house_origin)["payload"]["sim_id"])
	assert_false(bool((controller.building_view(house)["lot_block"] as Dictionary)
			.get("available", false)), "a house never grows, so it has no lot row")

	# A store that holds its lot states the fact and offers no button.
	var origin := _lot_site(sim, "store")
	var store := String(sim.cmd_place_building("store", origin)["payload"]["sim_id"])
	var ok_block: Dictionary = controller.building_view(store)["lot_block"]
	assert_true(bool(ok_block["available"]))
	assert_false(bool(ok_block["locked"]))
	assert_eq(String(ok_block["text_key"]), "ui_building_lot_reserved")
	assert_eq(StringName(str((ok_block["fix_target"] as Dictionary)["kind"])),
			RequirementFormatter.FIX_NONE, "nothing to fix, so no door")

	# A lot-locked one names the neighbour, the level it can still reach, and the
	# refund — and routes FIX_BUILDING at the neighbour.
	var boxed_origin := _lot_site(sim, "store")
	var blocker := String(sim.cmd_place_building("house",
			boxed_origin + Vector2i(1, 0))["payload"]["sim_id"])
	var locked_id := "P-902"
	var b := Building.new(902, &"store", boxed_origin)
	b.level = 1
	b.state = &"active"
	b.stats = sim.catalog.stats("store", 1)
	sim.buildings[locked_id] = b
	sim._building_records[locked_id] = {"id": locked_id, "grid_id": 902, "type": "store",
			"block": "", "footprint": Vector2i.ONE, "origin_global": boxed_origin}
	sim.world.grid.stamp_building(902, boxed_origin, Vector2i.ONE)

	var block: Dictionary = controller.building_view(locked_id)["lot_block"]
	assert_true(bool(block["available"]))
	assert_true(bool(block["locked"]))
	assert_eq(String(block["text_key"]), "ui_building_lot_locked")
	assert_eq(int(block["reachable_level"]), 2)
	assert_eq(String(block["blocked_by"]), blocker)
	var target: Dictionary = block["fix_target"]
	assert_eq(StringName(str(target["kind"])), RequirementFormatter.FIX_BUILDING)
	assert_eq(String(target["id"]), blocker)
	# …and the router answers it rather than falling through, which is the whole
	# point of routing it at all.
	var routed := FixRouter.route(sim, target)
	assert_eq(StringName(str(routed["action"])), FixRouter.ACTION_FOCUS,
			"the remedy is a PLACE: go and look at what is standing on your lot")


## **The row is BUILT, not merely modelled.** The view model above is plain data;
## this mounts the real S5 and asserts `BuildingPanel` actually draws the section
## and wires the button — which is the half A91-D-150 was filed for (a model with
## a passing unit test and no caller looks exactly like a shipped feature).
##
## It is asserted here rather than photographed because on a 412×915 screen the
## panel is taller than the viewport by the time it reaches this row: the upgrade
## block's own requirement checklist fills the screen on its own. The row sits
## directly under that block — the sentence it finishes — and the player scrolls.
func test_the_panel_actually_draws_the_lot_row_and_wires_its_button() -> void:
	var sim := CitySim.boot_from_files()
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	(Engine.get_main_loop() as SceneTree).root.add_child(root)
	root.initialize()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	var panel := root.get_node_or_null(
			"SafeArea/PanelLayer/BuildingPanel") as BuildingPanel
	assert_true(panel != null, "S5 is in the scene")
	panel.setup(root.config, controller)

	# A store holding its whole lot: the section draws, and there is no button.
	panel.show_building("STR-001")
	var section := panel.get_node_or_null("%s/LotSection" % panel.body_path())
	assert_true(section != null, "the LOT section exists in the panel body")
	assert_true((section as Control).visible, "…and a grower draws it")
	assert_true(panel.lot_fix_button() == null, "nothing to fix, so no door")

	# A house never grows, so the row is not drawn at all.
	panel.show_building("H-001")
	assert_false((section as Control).visible,
			"a flat archetype draws no lot row — doc 12 D-116's rule")

	# Now box a store in and assert the door appears and carries the neighbour.
	var boxed: Building = sim.buildings["STR-005"]
	var record: Dictionary = sim.building_record("STR-005")
	var lot: Vector2i = record.get("footprint", Vector2i.ONE)
	sim.world.grid.remove_building(boxed.id, boxed.origin, lot)
	sim.world.grid.stamp_building(boxed.id, boxed.origin, Vector2i.ONE)
	record["footprint"] = Vector2i.ONE
	var blocker := String(sim.cmd_place_building("house",
			boxed.origin + Vector2i(1, 0))["payload"]["sim_id"])
	panel.show_building("STR-005")
	assert_true((section as Control).visible)
	var button := panel.lot_fix_button()
	assert_true(button != null, "a lot-locked building gets its `Fix this →`")
	assert_eq(button.tooltip_text, blocker,
			"…and the button names the neighbour standing on its ground")

	(Engine.get_main_loop() as SceneTree).root.remove_child(root)
	root.free()


func test_every_lot_string_the_panel_can_ask_for_exists() -> void:
	var table: Dictionary = StarterCityLoader.read_json("res://data/strings.en.json")
	for key in ["ui_building_lot_title", "ui_building_lot_reserved",
			"ui_building_lot_locked", "ui_building_lot_locked_ground",
			"ui_building_lot_locked_badge", "ui_building_lot_locked_salvage",
			"ui_building_lot_locked_partial", "ui_building_lot_locked_stuck"]:
		assert_true(table.has(key), "data/strings.en.json is missing %s" % key)


## **The row has to be ON THE SCREEN** (Wave 29 fix). The first two cuts put this
## section at the bottom of the panel body and `ui_preview --screen=
## building_lot_locked --size=412x915 --rects=Lot` laid it out at y = 943, with
## its `Fix this →` at y = 1033, in a viewport 915 px tall: the player had to
## scroll ~270 px past the whole panel to reach the one control that decides
## whether the building has a future, and the strict audit called the screen
## clean because content inside a scroller is exempt from `offscreen`.
##
## A headless run never flushes a `Container`'s queued sort, so `size` is zero
## everywhere and this cannot measure pixels — but `get_combined_minimum_size()`
## is live, which is what `tests/test_ui_audit.gd` is built on. So the budget is
## the arithmetic one: everything above the row, plus the row, has to fit the
## scroller. `tools/ui_preview.gd`'s `MUST_BE_ON_SCREEN` is the pixel-accurate
## companion and fails `--audit --strict`.
func test_the_lot_row_fits_the_first_screenful_of_a_412x915_phone() -> void:
	var sim := CitySim.boot_from_files()
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	(Engine.get_main_loop() as SceneTree).root.add_child(root)
	root.initialize()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	var panel := root.get_node_or_null(
			"SafeArea/PanelLayer/BuildingPanel") as BuildingPanel
	panel.setup(root.config, controller)
	_box_in_a_store(sim)
	panel.show_building("STR-005")

	var body := panel.get_node(panel.body_path()) as VBoxContainer
	var section := body.get_node_or_null("LotSection") as Control
	assert_true(section != null and section.visible, "the lot row is drawn")
	var vitals := body.get_node_or_null("Vitals") as Control
	assert_eq(section.get_index(), vitals.get_index() + 1,
			"the LOT row sits directly under the vitals, above the checklist")

	var separation := float(body.get_theme_constant(&"separation"))
	var above := 0.0
	for child in body.get_children():
		var control := child as Control
		if control == section:
			break
		if control == null or not control.visible:
			continue
		above += control.get_combined_minimum_size().y + separation
	var bottom := above + section.get_combined_minimum_size().y
	# The scroller's own height at 412×915, measured with
	# `ui_preview --screen=building_lot_locked --size=412x915 --rects=BuildingPanel`:
	# `Panel/Frame/Scroll` is P(116, 68) S(284, 719), the panel's verbs being
	# pinned below it since PA-47.
	assert_true(bottom <= 719.0,
			"the lot row ends %d px into a 719 px scroller" % int(bottom))
	(Engine.get_main_loop() as SceneTree).root.remove_child(root)
	root.free()


# ------------------------------------- the door, on the four states it can face

## Box `STR-005` in with a house on the tile its lot wants, exactly as
## `tools/ui_preview.gd` stages the lot-locked screen. The house is the ONLY
## blocker — the other two tiles of the 2×2 stay free — which is the one shape
## where clearing something actually frees the ground.
static func _box_in_a_store(sim: CitySim) -> String:
	var boxed: Building = sim.buildings["STR-005"]
	var record: Dictionary = sim.building_record("STR-005")
	var lot: Vector2i = record.get("footprint", Vector2i.ONE)
	sim.world.grid.remove_building(boxed.id, boxed.origin, lot)
	sim.world.grid.stamp_building(boxed.id, boxed.origin, Vector2i.ONE)
	record["footprint"] = Vector2i.ONE
	return String(sim.cmd_place_building("house",
			boxed.origin + Vector2i(1, 0))["payload"]["sim_id"])


## **The verb the row quotes is the verb the neighbour's STATE answers** (Wave 29
## fix). The first cut quoted `cmd_demolish_building` unconditionally and never
## read the quote's `ok`, so a RUIN on the missing ground produced "clearing it
## refunds $0" over a verb that answers `E_STATE`.
func test_a_ruined_neighbour_is_quoted_and_routed_as_a_SALVAGE() -> void:
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim, RequirementFormatter.load_from_files())
	var blocker := _box_in_a_store(sim)

	# Standing: the demolition, with its own refund.
	var standing: Dictionary = controller.building_view("STR-005")["lot_block"]
	assert_eq(String(standing["text_key"]), "ui_building_lot_locked")
	assert_eq(String(standing["free_verb"]), "demolish")
	assert_eq(int(standing["free_refund"]),
			int((sim.cmd_demolish_building(blocker, true)["payload"] as Dictionary)["refund"]),
			"the row quotes the verb it names, not a number of its own")

	# …and the same neighbour as a RUIN: the other verb, the other number.
	var other: Building = sim.buildings[blocker]
	other.state = &"destroyed"
	other.level_at_destruction = maxi(other.level, 1)
	assert_false(bool(sim.cmd_demolish_building(blocker, true)["ok"]),
			"a ruin refuses the demolition — this is the state that found the bug")
	var quote := sim.cmd_salvage_building(blocker, true)
	assert_true(bool(quote["ok"]), "…and takes the salvage")

	var ruined: Dictionary = controller.building_view("STR-005")["lot_block"]
	assert_eq(String(ruined["text_key"]), "ui_building_lot_locked_salvage")
	assert_eq(String(ruined["free_verb"]), "salvage")
	assert_eq(int(ruined["free_refund"]),
			int((quote["payload"] as Dictionary)["value"]),
			"the money on the row is the salvage's own value")
	assert_true(int(ruined["free_refund"]) > 0, "and it is not the $0 the row used to read")
	var target: Dictionary = ruined["fix_target"]
	assert_eq(StringName(str(target["kind"])), RequirementFormatter.FIX_BUILDING)
	assert_eq(String(target["id"]), blocker)

	# **The door opens.** Buy the verb the row named and the ground comes back in
	# the same call — which is what makes it a remedy rather than a label.
	assert_true(bool(sim.cmd_salvage_building(blocker)["ok"]))
	assert_eq(sim.building_record("STR-005").get("footprint"), Vector2i(2, 2),
			"the store took its lot the moment the rubble left")
	assert_true(sim.lot_lock("STR-005").is_empty(), "…and it is not lot-locked any more")
	var freed: Dictionary = controller.building_view("STR-005")["lot_block"]
	assert_false(bool(freed["locked"]))
	assert_eq(String(freed["text_key"]), "ui_building_lot_reserved")


## A BURNING neighbour takes neither verb. The row says so and arms nothing —
## the quote's `ok` is what decides, so a state nobody thought of gets the honest
## branch rather than a $0.
func test_a_burning_neighbour_gets_a_sentence_and_no_button() -> void:
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim, RequirementFormatter.load_from_files())
	var blocker := _box_in_a_store(sim)
	(sim.buildings[blocker] as Building).state = &"on_fire"
	assert_false(bool(sim.cmd_demolish_building(blocker, true)["ok"]))
	assert_false(bool(sim.cmd_salvage_building(blocker, true)["ok"]))

	var block: Dictionary = controller.building_view("STR-005")["lot_block"]
	assert_eq(String(block["text_key"]), "ui_building_lot_locked_stuck")
	assert_eq(String(block["free_verb"]), "")
	assert_false(block.has("free_refund"), "no number, because there is no quote")
	assert_eq(StringName(str((block["fix_target"] as Dictionary)["kind"])),
			RequirementFormatter.FIX_NONE, "nothing to press")
	assert_true(String(block["params"]["state"]) == "on fire",
			"the sentence names the state, in the case a sentence wants")


## **A lot grows all at once or not at all**, so a neighbour beside ground the
## player cannot clear is not a door. `TileGrid.can_expand` refuses the whole
## rectangle if one tile of it is taken, which is what makes this a rule and not
## a preference.
func test_a_neighbour_beside_unclearable_ground_is_not_offered_as_a_remedy() -> void:
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim, RequirementFormatter.load_from_files())
	var blocker := _box_in_a_store(sim)
	# A second house on the diagonal tile of the same lot: now the store is
	# blocked by two buildings, and freeing one leaves the other.
	var boxed: Building = sim.buildings["STR-005"]
	var second := sim.cmd_place_building("house", boxed.origin + Vector2i(1, 1))
	assert_true(bool(second["ok"]), "the diagonal tile of the lot is free to build on")
	# …and then make that second one un-clearable ground rather than a building,
	# which is the player's own case: a kerb.
	sim.world.grid.set_flag(boxed.origin.x, boxed.origin.y + 1, TileGrid.FLAG_ROAD)

	var lock := sim.lot_lock("STR-005")
	var ground: Array = []
	for entry in (lock["blockers"] as Array):
		if not sim.buildings.has(String(entry)):
			ground.append(String(entry))
	assert_false(ground.is_empty(), "the lot has ground on it no verb takes")
	assert_true((lock["blockers"] as Array).has(StringName(blocker)),
			"…and a building as well")

	var block: Dictionary = controller.building_view("STR-005")["lot_block"]
	assert_eq(String(block["text_key"]), "ui_building_lot_locked_partial")
	assert_eq(String(block["blocked_by"]), blocker, "the row still NAMES the neighbour")
	assert_eq(StringName(str((block["fix_target"] as Dictionary)["kind"])),
			RequirementFormatter.FIX_NONE,
			"but it does not offer a remedy that would move nothing")
	# The arithmetic that makes that the honest answer: clearing the building
	# leaves the lot exactly as locked as it was.
	var before := int(sim.lot_lock("STR-005")["reachable_level"])
	assert_true(bool(sim.cmd_demolish_building(blocker)["ok"]))
	assert_false(sim.lot_lock("STR-005").is_empty(), "still boxed in")
	assert_eq(int(sim.lot_lock("STR-005")["reachable_level"]), before,
			"and not one rung better for it")


## **The player's own city, through the real `SaveService`** — the city the fix
## was found on. 77 of its 89 buildings are `destroyed`, so every lot-locked
## building whose blocker is a building names a RUIN, and every one of them is
## also blocked by the kerb. Nothing on this city may claim a refund it cannot
## pay or a remedy that would not free the ground.
func test_no_lot_row_on_the_players_own_save_promises_what_it_cannot_do() -> void:
	var sim := _restore_player_save()
	if sim == null:
		assert_true(false, "tests/fixtures/player_save_0903 did not restore")
		return
	var controller := BuildController.new(sim, RequirementFormatter.load_from_files())
	var locked := sim.lot_locked_ids()
	assert_eq(locked.size(), 10, "the player's own city, counted through the restore path")
	var named := 0
	var doors := 0
	for sim_id in locked:
		var block: Dictionary = controller.building_view(String(sim_id))["lot_block"]
		assert_true(bool(block["locked"]), "%s is lot-locked" % sim_id)
		var neighbour := String(block.get("blocked_by", ""))
		if neighbour == "":
			assert_eq(String(block["text_key"]), "ui_building_lot_locked_ground")
			continue
		named += 1
		# Whatever the row says, a quoted verb must ANSWER and a quoted number
		# must be that verb's own.
		if block.has("free_refund"):
			var verb := String(block["free_verb"])
			var quote := sim.cmd_salvage_building(neighbour, true) if verb == "salvage" \
					else sim.cmd_demolish_building(neighbour, true)
			assert_true(bool(quote["ok"]),
					"%s quotes %s on %s, which refuses" % [sim_id, verb, neighbour])
		if StringName(str((block["fix_target"] as Dictionary)["kind"])) \
				!= RequirementFormatter.FIX_NONE:
			doors += 1
			assert_true((block["ground_blockers"] as Array).is_empty(),
					"%s offers a door onto a lot that ground also holds" % sim_id)
	assert_eq(named, 7, "seven of the ten name a neighbour")
	assert_eq(doors, 0,
			"and none of them can be freed by a verb, because the kerb holds part of every one")
	# The measurement the fix was made from: every one of those seven neighbours
	# is a RUIN, which is the state the old row quoted a demolition on.
	for sim_id in locked:
		var block: Dictionary = controller.building_view(String(sim_id))["lot_block"]
		var neighbour := String(block.get("blocked_by", ""))
		if neighbour == "":
			continue
		assert_eq(String(block["blocked_by_state"]), "destroyed", "%s's blocker" % sim_id)
		assert_false(bool(sim.cmd_demolish_building(neighbour, true)["ok"]),
				"the demolition the first cut quoted refuses %s" % neighbour)
		assert_true(bool(sim.cmd_salvage_building(neighbour, true)["ok"]),
				"the salvage takes it")


## The fixture, copied into this process's own `user://` and loaded through the
## real `SaveService` — never read in place, because a load can promote a legacy
## file and roll a generation, and a test must not edit the fixture it reads.
func _restore_player_save() -> CitySim:
	var dest := "user://test_saves/lot_fixture"
	DirAccess.make_dir_recursive_absolute(dest)
	if _copy_tree("res://tests/fixtures/player_save_0903", dest) == 0:
		return null
	var sim := CitySim.boot_from_files(1337)
	var service := SaveService.new()
	service.base_dir = dest
	(Engine.get_main_loop() as SceneTree).root.add_child(service)
	var ok := service.load_slot(sim, 0)
	(Engine.get_main_loop() as SceneTree).root.remove_child(service)
	service.free()
	return sim if ok else null


static func _copy_tree(source: String, dest: String) -> int:
	var dir := DirAccess.open(source)
	if dir == null:
		return 0
	var copied := 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var from := source.path_join(entry)
		var to := dest.path_join(entry)
		if dir.current_is_dir():
			DirAccess.make_dir_recursive_absolute(to)
			copied += _copy_tree(from, to)
		elif DirAccess.copy_absolute(from, to) == OK:
			copied += 1
		entry = dir.get_next()
	dir.list_dir_end()
	return copied
