extends SimTest
## The missing player verbs (audit doc 93 §B): grid-component placement,
## demolition, repair, load priority, the tax knob and land purchase.
##
## Every verb gets its success path, every one of its documented failure codes,
## a determinism check (capture → advance the same span twice → identical
## state hash) and a save round-trip taken mid-effect.


# ------------------------------------------------------------------ helpers

static func _lot_a(sim: CitySim) -> Vector2i:
	return sim.loader.resolve_tag("tutorial_lot_a")["tile_global"]


## The first tile inside `radius` of `centre` where a transformer may legally go.
static func _transformer_spot(sim: CitySim, centre: Vector2i, radius: int) -> Vector2i:
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var tile := centre + Vector2i(dx, dz)
			if bool(sim.cmd_place_grid_component("transformer", tile, 1, true)["ok"]):
				return tile
	return Vector2i(-1, -1)


static func _serviceable_vacant_tile(sim: CitySim) -> Vector2i:
	for z in range(32, 80):
		for x in range(32, 80):
			var origin := Vector2i(x, z)
			if sim.world.grid.can_place(origin, Vector2i.ONE) and sim.grid.would_serve(origin):
				return origin
	return Vector2i(-1, -1)


static func _line_km(sim: CitySim) -> float:
	var total := 0.0
	for line in (sim.grid.grid_inventory()["lines"] as Array):
		total += float((line as Dictionary)["line_km"])
	return total


static func _feeder_route_tiles(sim: CitySim) -> Array:
	var out: Array = []
	for id in sim.grid.component_ids_of_kind(&"feeder"):
		for entry in (sim.grid.component(id)["route"] as Array):
			out.append(PowerGrid.route_tile(entry))
	return out


# ================================================ 1. cmd_place_grid_component

func test_transformer_unblocks_the_tutorial_lot() -> void:
	# THE Wave-1.5 beat (audit doc 93 §B row 1): tutorial_lot_a is 4 tiles from
	# an L1 transformer whose service radius is 3, so doc 04 §2.1 refuses the
	# house. A player transformer is the answer, and after it lands the same
	# placement succeeds — E_UNSERVED became a purchase, not a wall.
	var sim := CitySim.boot_from_files()
	var lot := _lot_a(sim)
	assert_false(sim.grid.would_serve(lot), "the lot starts unserved")
	assert_eq(sim.cmd_place_building("house", lot)["reason_code"], &"E_UNSERVED")

	var spot := _transformer_spot(sim, lot, 3)
	assert_true(spot.x >= 0, "a legal transformer tile exists within the lot's L1 radius")
	var balance: int = sim.treasury.balance
	var placed := sim.cmd_place_grid_component("transformer", spot, 1)
	assert_true(bool(placed["ok"]), str(placed))
	var payload: Dictionary = placed["payload"]

	# doc 03 §2.13(b): transformer L1 $500 + one feeder tile at $110 per lateral
	# tile (class 1, overhead). The quote and the charge are the same number.
	var expected := 500 + int(payload["lateral_tiles"]) * 110
	assert_eq(int(payload["cost"]), expected, "doc 03 §2.13(b) transformer + lateral")
	assert_eq(sim.treasury.balance, balance - expected, "charged exactly once")
	assert_eq(String(payload["feeder"]), "F_NORTH", "tapped the nearest feeder")
	assert_true(sim.grid.has_component(String(payload["component"])))

	assert_true(sim.grid.would_serve(lot), "the lot is serviceable the same command")
	var house := sim.cmd_place_building("house", lot)
	assert_true(bool(house["ok"]), str(house))
	# And it really joins the grid: energized, attached, powered.
	sim.advance_hours(6.0)
	var sim_id := String(house["payload"]["sim_id"])
	assert_eq(sim.grid.attachment_of(sim_id), String(payload["component"]))
	assert_true(sim.grid.is_energized(String(payload["component"])), "the new node is live")
	assert_true(sim.grid.is_powered(sim_id), "and the house it serves is lit")


func test_transformer_adopts_orphaned_buildings() -> void:
	# A building placed while served, then orphaned by its transformer failing,
	# is re-attached by the next transformer that covers it.
	var sim := CitySim.boot_from_files()
	var lot := _lot_a(sim)
	var spot := _transformer_spot(sim, lot, 3)
	sim.cmd_place_grid_component("transformer", spot, 1)
	var sim_id := String(sim.cmd_place_building("house", lot)["payload"]["sim_id"])
	var component := sim.grid.attachment_of(sim_id)
	assert_ne(component, "")
	# Orphan it: a FAILED transformer serves nobody (doc 04 §2.1).
	sim.grid.component(component)["state"] = &"FAILED"
	sim.grid.attach_building(sim_id, lot, &"STANDARD", "B_2_2")
	assert_eq(sim.grid.attachment_of(sim_id), "", "orphaned")
	assert_true(sim.grid.unserved_building_ids().has(sim_id))
	var second := _transformer_spot(sim, lot, 3)
	var placed := sim.cmd_place_grid_component("transformer", second, 2)
	assert_true(bool(placed["ok"]), str(placed))
	assert_true((placed["payload"]["adopted"] as Array).has(sim_id),
			"the new transformer adopts the orphan in the same command")
	assert_ne(sim.grid.attachment_of(sim_id), "")


func test_grid_placement_rejections() -> void:
	var sim := CitySim.boot_from_files()
	var lot := _lot_a(sim)
	var spot := _transformer_spot(sim, lot, 3)

	# 1 unknown kind — a substation is a BUILDING (doc 04 §2.1 / report 98 C-30)
	# and is placed by `cmd_place_building`; it will never be in this roster.
	assert_eq(sim.cmd_place_grid_component("substation", spot, 1)["reason_code"],
			&"E_UNKNOWN_COMPONENT")
	assert_eq(sim.cmd_place_grid_component("battery", spot, 1)["reason_code"],
			&"E_UNKNOWN_COMPONENT")
	# `feeder` IS known now (Wave 6) — it is a LINE, so it routes rather than
	# placing, and its own blockers are tested with `cmd_route_feeder` below.
	assert_eq(sim.cmd_place_grid_component("feeder", spot, 2)["reason_code"],
			&"E_NO_SLOT", "doc 09 §2.9.5 fills both of SUB-A's slots at t0")
	# 2 level outside the placeable roster (L1–L3 in this cut).
	assert_eq(sim.cmd_place_grid_component("transformer", spot, 4)["reason_code"],
			&"E_LEVEL_UNAVAILABLE")
	assert_eq(sim.cmd_place_grid_component("transformer", spot, 0)["reason_code"],
			&"E_LEVEL_UNAVAILABLE")
	assert_true(bool(sim.cmd_place_grid_component("transformer", spot, 3, true)["ok"]),
			"L3 is inside the roster")
	# 3 off the map.
	assert_eq(sim.cmd_place_grid_component("transformer", Vector2i(-1, 5), 1)["reason_code"],
			&"E_OUT_OF_BOUNDS")
	assert_eq(sim.cmd_place_grid_component("transformer",
			Vector2i(TileGrid.SIZE, 5), 1)["reason_code"], &"E_OUT_OF_BOUNDS")
	# 4 unowned ring land.
	assert_eq(sim.cmd_place_grid_component("transformer", Vector2i(8, 8), 1)["reason_code"],
			&"E_NOT_OWNED")
	# 6 the tile is taken — a transformer already there is a reserved tile.
	sim.cmd_place_grid_component("transformer", spot, 1)
	assert_eq(sim.cmd_place_grid_component("transformer", spot, 1)["reason_code"],
			&"E_FOOTPRINT")
	# 8 broke.
	var free_spot := _transformer_spot(sim, lot, 3)
	sim.treasury.spend(sim.treasury.balance - 10, &"misc")
	var broke := sim.cmd_place_grid_component("transformer", free_spot, 1)
	assert_eq(broke["reason_code"], &"E_FUNDS")
	assert_eq(sim.treasury.balance, 10, "a refused placement charges nothing")


func test_grid_placement_needs_a_feeder() -> void:
	# 7 E_NO_FEEDER: doc 04 §2.1's radial tree has no orphan nodes, and a FAILED
	# feeder is not tappable.
	var sim := CitySim.boot_from_files()
	var spot := _transformer_spot(sim, _lot_a(sim), 3)
	for id in sim.grid.component_ids_of_kind(&"feeder"):
		sim.grid.component(id)["state"] = &"FAILED"
	var result := sim.cmd_place_grid_component("transformer", spot, 1)
	assert_eq(result["reason_code"], &"E_NO_FEEDER")
	assert_eq(int(result["payload"]["tap_distance"]), -1)


func test_grid_placement_not_developed() -> void:
	# 5 E_NOT_DEVELOPED: owned but still raw ground.
	var sim := CitySim.boot_from_files()
	sim.treasury.credit(200_000, &"test_grant")
	assert_true(bool(sim.cmd_buy_block("B_3_1", false, false)["ok"]))
	assert_eq(String(sim.world.block("B_3_1").development_state), "UNDEVELOPED")
	var tile := Vector2i(3 * TileGrid.TILES_PER_BLOCK + 8, 1 * TileGrid.TILES_PER_BLOCK + 8)
	var result := sim.cmd_place_grid_component("transformer", tile, 1)
	assert_eq(result["reason_code"], &"E_NOT_DEVELOPED")


func test_grid_placement_preview_is_free() -> void:
	var sim := CitySim.boot_from_files()
	var spot := _transformer_spot(sim, _lot_a(sim), 3)
	var balance: int = sim.treasury.balance
	var preview := sim.cmd_place_grid_component("transformer", spot, 2, true)
	assert_true(bool(preview["ok"]))
	assert_eq(sim.treasury.balance, balance, "preview never spends")
	assert_eq(int(preview["payload"]["service_radius_tiles"]), 4, "doc 04 §2.2 L2 radius")
	assert_false(sim.grid.has_component("PT-001"), "preview places nothing")
	# The quoted price is what the real command charges.
	var placed := sim.cmd_place_grid_component("transformer", spot, 2)
	assert_eq(int(placed["payload"]["cost"]), int(preview["payload"]["cost"]))


func test_feeder_tap_radius_covers_the_authored_city() -> void:
	# The tap radius in data/grid_components.json is not a free parameter: every
	# transformer doc 09 authored must be reproducible by the player's own verb,
	# so each one has to sit inside the radius of some feeder route.
	var sim := CitySim.boot_from_files()
	var radius := int((sim._placeable_rules("transformer"))["feeder_tap_radius_tiles"])
	var routes := _feeder_route_tiles(sim)
	assert_true(routes.size() > 0)
	var worst := 0
	for id in sim.grid.component_ids_of_kind(&"transformer"):
		var tile: Vector2i = sim.grid.component(id)["tile"]
		var nearest := 999999
		for r in routes:
			nearest = mini(nearest, maxi(absi(tile.x - r.x), absi(tile.y - r.y)))
		worst = maxi(worst, nearest)
		assert_true(nearest <= radius,
				"%s at %s is %d tiles from any feeder, radius %d" % [id, tile, nearest, radius])
	assert_eq(worst, radius, "the radius is exactly the authored city's worst tap")
	# And it is half a land block, so a corridor to a block centre covers it all.
	assert_eq(radius, TileGrid.TILES_PER_BLOCK / 2)


func test_grid_rules_mirror_the_power_ladder() -> void:
	# The P0-01 pattern: the placement data file republishes doc 04 §2.2's
	# service radii and boot refuses to start if they have drifted.
	var sim := CitySim.boot_from_files()
	assert_eq(sim.boot_errors.size(), 0, str(sim.boot_errors))
	var radii: Array = (sim._placeable_rules("transformer"))["service_radius_tiles"]
	assert_eq(radii.size(), PowerGrid.TRANSFORMER_SERVICE_RADIUS.size())
	for i in radii.size():
		assert_eq(int(radii[i]), int(PowerGrid.TRANSFORMER_SERVICE_RADIUS[i]))
	# A drifted file is a boot error, not a silent mismatch.
	var broken := CitySim.new()
	broken.boot(1337, StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json("res://data/starter_city.json"),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			{"placeable": {"transformer": {"service_radius_tiles": [9, 9, 9, 9, 9]}}})
	assert_true(broken.boot_errors.size() > 0, "drift is caught at boot")


func test_grid_placement_determinism_and_save_roundtrip() -> void:
	var sim := CitySim.boot_from_files(4242)
	var lot := _lot_a(sim)
	sim.cmd_place_grid_component("transformer", _transformer_spot(sim, lot, 3), 1)
	sim.cmd_place_building("house", lot)
	sim.advance_hours(1.5)  # save mid-construction

	var body := sim.canonical_capture()
	var a := CitySim.boot_from_files(4242)
	a.restore_state(body)
	var b := CitySim.boot_from_files(4242)
	b.restore_state(body)
	assert_eq(a.state_hash(), b.state_hash(), "two restores of one capture agree")
	a.advance_hours(8.0)
	b.advance_hours(8.0)
	assert_eq(a.state_hash(), b.state_hash(), "and stay identical while advancing")
	sim.advance_hours(8.0)
	assert_eq(sim.state_hash(), a.state_hash(), "the live sim matches the reload")
	# The one-tile reservation survives the reload.
	var spot: Vector2i = a.grid.component("PT-001")["tile"]
	assert_false(a.world.grid.can_place(spot, Vector2i.ONE),
			"the transformer's tile is still reserved after a load")


# ============================================ 1b. cmd_route_feeder (doc 04 §4)
#
# The verb doc 92 §17.3 named as the late-game's answer. Its own header carries
# the reason-code order; every one of them gets a case here, plus the success
# path, the adoption that makes it relief, determinism and a save round-trip.

## Build and finish a player substation near `centre`, returning its sim_id.
## A substation IS a building (report 98 C-30), so this is `cmd_place_building`
## plus the construction time doc 02 charges for it.
static func _finished_substation(sim: CitySim, centre: Vector2i) -> String:
	sim.treasury.credit(400_000, &"test_grant")
	var size := Vector2i(2, 2)
	var best := Vector2i(-1, -1)
	var best_distance := 999999
	for z in range(32, 80):
		for x in range(32, 80):
			var origin := Vector2i(x, z)
			var distance: int = maxi(absi(x - centre.x), absi(z - centre.y))
			if distance >= best_distance:
				continue
			if sim.world.grid.can_place(origin, size) and sim.grid.would_serve(origin):
				best = origin
				best_distance = distance
	if best.x < 0:
		return ""
	var placed := sim.cmd_place_building("substation", best)
	if not bool(placed["ok"]):
		return ""
	var sim_id := String((placed["payload"] as Dictionary)["sim_id"])
	# doc 02: substation L1 is 8 build-hours, but the MVP yard crew is shared, so
	# run until the shell is actually standing rather than guessing a number.
	_finish_construction(sim, sim_id)
	return sim_id


## Advance until `sim_id` leaves `under_construction`, bounded so a genuinely
## stuck job fails the test instead of hanging it.
static func _finish_construction(sim: CitySim, sim_id: String) -> bool:
	for i in 20:
		if (sim.buildings[sim_id] as Building).state != &"under_construction":
			return true
		sim.advance_hours(4.0)
	return (sim.buildings[sim_id] as Building).state != &"under_construction"


func test_substation_shell_becomes_a_real_grid_node() -> void:
	# Doc 92 §17.3 fix 2, and the same class of bug as pass-2 F-3's frozen
	# fleet: `cmd_place_building` sold a $15,000 substation that added no
	# capacity at all. The shell's sim_id IS the node's id — doc 09 §2.9.5
	# already authors `SUB-A` that way, so authored and player nodes are one
	# thing, not two.
	var sim := CitySim.boot_from_files()
	assert_true(sim.grid.has_component("SUB-A"), "the authored pair share one id")
	var sub := _finished_substation(sim, Vector2i(64, 50))
	assert_true(sub != "")
	var node := sim.grid.component(sub)
	assert_eq(String(node["kind"]), "substation")
	assert_almost_eq(float(node["capacity_kw"]), 6000.0, 1e-9, "doc 04 §2.2 L1")
	assert_eq(int(sim.grid.feeder_slots(sub)["free"]), 2, "§2.2: L1 roots two feeders")
	assert_true(sim.grid.is_energized(sub) or sim.grid.topology_dirty)
	# …and it is the ONLY thing that unblocks more copper: SUB-A is full at t0.
	assert_eq(int(sim.grid.feeder_slots("SUB-A")["free"]), 0)


func test_plant_shell_generates_and_re_rates_on_upgrade() -> void:
	var sim := CitySim.boot_from_files()
	sim.advance_hours(1.0)
	var before := sim.grid.system_supply_kw
	assert_almost_eq(before, 8000.0, 1e-9, "one authored plant_gas L1")
	sim.treasury.credit(900_000, &"test_grant")
	var origin := Vector2i(-1, -1)
	for z in range(32, 78):
		for x in range(32, 78):
			var candidate := Vector2i(x, z)
			if sim.world.grid.can_place(candidate, Vector2i(3, 3)) \
					and sim.grid.would_serve(candidate):
				origin = candidate
				break
		if origin.x >= 0:
			break
	assert_true(origin.x >= 0, "a 3×3 site exists somewhere in the core")
	var placed := sim.cmd_place_building("power_facility", origin)
	assert_true(bool(placed["ok"]), str(placed))
	var sim_id := String((placed["payload"] as Dictionary)["sim_id"])
	assert_false(sim.grid.has_component(sim_id), "a hole in the ground generates nothing")
	assert_true(_finish_construction(sim, sim_id))
	sim.advance_hours(1.0)
	assert_true(sim.grid.has_component(sim_id))
	assert_almost_eq(sim.grid.system_supply_kw, before + 8000.0, 1e-9,
			"doc 04 §2.2: plant_gas L1 = 8,000 kW of bulk pool")
	# The doc 02 upgrade job is what buys the next rung of the §2.2 ladder.
	sim.progression.city_level = 3  # doc 02: power_facility L2 is min_city_level 1
	var upgraded := sim.cmd_upgrade_building(sim_id)
	assert_true(bool(upgraded["ok"]), str(upgraded))
	for i in 30:
		if int(sim.grid.component(sim_id)["level"]) >= 2:
			break
		sim.advance_hours(4.0)
	assert_almost_eq(float(sim.grid.component(sim_id)["capacity_kw"]), 18000.0, 1e-9,
			"L2 = 18 MW")


func test_route_feeder_success_relieves_the_authored_pair() -> void:
	var sim := CitySim.boot_from_files()
	sim.advance_hours(6.0)
	var hot := sim.grid.worst_feeder(25.0)
	var target := Vector2i.ZERO
	var best_load := -1.0
	for id in sim.grid.component_ids_of_kind(&"transformer"):
		var c: Dictionary = sim.grid.component(String(id))
		if String(c["parent"]) == String(hot["id"]) and float(c["load_kw"]) > best_load:
			best_load = float(c["load_kw"])
			target = c["tile"]
	var sub := _finished_substation(sim, target)
	assert_true(sub != "")

	var preview := sim.cmd_place_grid_component("feeder", target, 2, true)
	assert_true(bool(preview["ok"]), str(preview))
	var quote: Dictionary = preview["payload"]
	var balance: int = sim.treasury.balance
	var line_km_before := _line_km(sim)
	assert_almost_eq(float(quote["capacity_kw"]), 3000.0, 1e-9, "doc 04 §2.2 class 2")
	assert_eq(int(quote["cost"]),
			int(quote["billed_tiles"]) * 210, "doc 03 §2.13(b): $210/tile class 2")
	assert_true(int(quote["adopts"]) > 0,
			"the quote names what the run would pick up, or it is quoting a price "
			+ "for an effect the player cannot see")
	assert_eq(sim.treasury.balance, balance, "a preview charges nothing")
	assert_eq(sim.grid.component_ids_of_kind(&"feeder").size(), 2,
			"…and adds nothing to the graph")

	var routed := sim.cmd_place_grid_component("feeder", target, 2)
	assert_true(bool(routed["ok"]), str(routed))
	var payload: Dictionary = routed["payload"]
	assert_eq(int(payload["cost"]), int(quote["cost"]), "the quote is the price")
	assert_eq(sim.treasury.balance, balance - int(quote["cost"]))
	var feeder_id := String(payload["component"])
	assert_eq(String(sim.grid.component(feeder_id)["parent"]), sub)
	assert_eq(int(sim.grid.feeder_slots(sub)["free"]), 1, "one slot spent")
	assert_true(int(payload["adopts"]) > 0 and float(payload["adopted_kw"]) > 0.0)
	# The relief is real: the hot feeder's load falls by what moved.
	var before: float = float(sim.grid.component(String(hot["id"]))["load_kw"])
	sim.advance_hours(1.0)
	assert_true(float(sim.grid.component(String(hot["id"]))["load_kw"]) < before,
			"routing copper into a saturated circuit takes load OFF it (§2.9)")
	# `line_km` grew by exactly the run, so doc 03's E_grid bills the new copper
	# (report 98 C-12: `line_km = route_tiles × 0.008`).
	assert_almost_eq(_line_km(sim) - line_km_before,
			int(payload["tiles"]) * 0.008, 1e-9,
			"every tile of the polyline is inventory, at 8 m each")


func test_route_feeder_rejections() -> void:
	var sim := CitySim.boot_from_files()
	var routes := _feeder_route_tiles(sim)
	var trunk: Vector2i = routes[0]

	# 2 E_CLASS_UNAVAILABLE — doc 04 §6 ships class 1–2 overhead, not class 3.
	assert_eq(sim.cmd_route_feeder([trunk, trunk + Vector2i(1, 0)], 3)["reason_code"],
			&"E_CLASS_UNAVAILABLE")
	assert_eq(sim.cmd_route_feeder([trunk, trunk + Vector2i(1, 0)], 0)["reason_code"],
			&"E_CLASS_UNAVAILABLE")
	# 3 E_NO_TILES.
	assert_eq(sim.cmd_route_feeder([trunk], 2)["reason_code"], &"E_NO_TILES")
	assert_eq(sim.cmd_route_feeder([], 2)["reason_code"], &"E_NO_TILES")
	# 4 E_OUT_OF_BOUNDS.
	assert_eq(sim.cmd_route_feeder([Vector2i(-1, 0), Vector2i(0, 0)], 2)["reason_code"],
			&"E_OUT_OF_BOUNDS")
	# 5 E_DISCONTINUOUS — a feeder is a polyline, not a set of tiles.
	assert_eq(sim.cmd_route_feeder([trunk, trunk + Vector2i(4, 0)], 2)["reason_code"],
			&"E_DISCONTINUOUS")
	# 7 E_NOT_CONNECTED — a run that starts nowhere near the network.
	var orphan := Vector2i(40, 40)
	assert_eq(sim.cmd_route_feeder([orphan, orphan + Vector2i(1, 0)], 2)["reason_code"],
			&"E_NOT_CONNECTED")
	# 8 E_NO_SLOT — SUB-A is L1, doc 09 §2.9.5 fills both slots at t0, and no
	#   amount of money buys copper the substation cannot root.
	assert_eq(sim.cmd_route_feeder([trunk, trunk + Vector2i(0, 1)], 2)["reason_code"],
			&"E_NO_SLOT")

	# With a substation to hang it on, the same run is legal — so 6 and 9 are
	# testable against a command that would otherwise pass.
	var sub := _finished_substation(sim, trunk)
	var pad: Vector2i = sim.buildings[sub].origin
	var start := pad + Vector2i(-1, 0)
	assert_true(bool(sim.cmd_route_feeder([start, start + Vector2i(0, 1)], 2, true)["ok"]))
	# 6 E_NOT_DEVELOPED — a run out over unowned ring land.
	var into_the_ring := PowerGrid.route_between(start, Vector2i(8, 8))
	assert_eq(sim.cmd_route_feeder(into_the_ring, 2)["reason_code"], &"E_NOT_DEVELOPED")
	# 9 E_FUNDS, and a refused run charges nothing. Even one billed tile is
	# $210 at class 2, so $10 cannot buy the shortest legal run there is.
	sim.treasury.spend(sim.treasury.balance - 10, &"misc")
	assert_eq(sim.cmd_route_feeder([start, start + Vector2i(0, 1)], 2)["reason_code"],
			&"E_FUNDS")
	assert_eq(sim.treasury.balance, 10)


func test_route_feeder_assist_stays_on_owned_ground() -> void:
	# The C-41 assist is what makes the one-tap path usable: a straight
	# Chebyshev line between two owned tiles routinely crosses land the city
	# does not own, and the verb would refuse it. Every tile it suggests is one
	# `cmd_route_feeder` will accept.
	var sim := CitySim.boot_from_files()
	var a := Vector2i(34, 34)
	var b := Vector2i(76, 76)
	var path := sim.suggest_feeder_route(a, b)
	assert_eq(PowerGrid.route_break_index(path), -1, "a walkable polyline")
	assert_eq(path[0], a)
	assert_eq(path[path.size() - 1], b)
	for entry in path:
		var tile: Vector2i = entry
		var block := sim.world.block_of_tile(tile.x, tile.y)
		assert_true(block != null and block.is_owned() and block.is_ready(),
				"%s is off the developed city" % tile)


func test_route_feeder_survives_save_roundtrip_and_is_deterministic() -> void:
	var sim := CitySim.boot_from_files(4242)
	sim.advance_hours(4.0)
	var sub := _finished_substation(sim, Vector2i(70, 60))
	assert_true(sub != "")
	assert_true(bool(sim.cmd_place_grid_component("feeder", Vector2i(70, 60), 2)["ok"]))
	sim.advance_hours(1.5)

	var body := sim.canonical_capture()
	var a := CitySim.boot_from_files(4242)
	a.restore_state(body)
	var b := CitySim.boot_from_files(4242)
	b.restore_state(body)
	assert_eq(a.state_hash(), b.state_hash(), "two restores of one capture agree")
	a.advance_hours(8.0)
	b.advance_hours(8.0)
	assert_eq(a.state_hash(), b.state_hash())
	sim.advance_hours(8.0)
	assert_eq(sim.state_hash(), a.state_hash(), "the live sim matches the reload")
	# The routed copper is still copper, still rooted, still carrying.
	var reloaded: Dictionary = a.grid.component("PF-001")
	assert_eq(String(reloaded["kind"]), "feeder")
	assert_eq(String(reloaded["parent"]), sub)
	assert_almost_eq(float(reloaded["capacity_kw"]), 3000.0, 1e-9)
	assert_true((reloaded["route"] as Array).size() > 1)
	# A line reserves no ground. The reload re-stamps the one-tile reservation
	# every PLACEABLE player component carries, and a feeder is not one of them —
	# it has no `tile`, so re-stamping it would occupy (0, 0) on every load.
	assert_false(a.world.grid.has_flag(0, 0, TileGrid.FLAG_OCCUPIED),
			"a routed feeder reserved the origin tile on reload")


func test_demolishing_a_substation_takes_its_circuits_and_leaves_a_way_back() -> void:
	var sim := CitySim.boot_from_files()
	sim.advance_hours(4.0)
	var sub := _finished_substation(sim, Vector2i(70, 60))
	assert_true(bool(sim.cmd_place_grid_component("feeder", Vector2i(70, 60), 2)["ok"]))
	sim.advance_hours(1.0)
	var adopted := sim.grid.component("PF-001")["route"] as Array
	assert_true(adopted.size() > 1)
	var moved: Array = []
	for id in sim.grid.component_ids_of_kind(&"transformer"):
		if String(sim.grid.component(String(id))["parent"]) == "PF-001":
			moved.append(String(id))
	assert_true(moved.size() > 0, "the run picked something up")

	assert_true(bool(sim.cmd_demolish_building(sub)["ok"]))
	assert_false(sim.grid.has_component(sub), "the shell IS the node")
	assert_false(sim.grid.has_component("PF-001"),
			"§2.1: a feeder does not outlive the substation that roots it")
	for id in moved:
		assert_eq(String(sim.grid.component(String(id))["parent"]), "",
				"%s stands, orphaned" % id)
	sim.advance_hours(1.0)
	# And the recovery path is the verb itself: a new substation and a new run.
	var replacement := _finished_substation(sim, sim.grid.component(moved[0])["tile"])
	assert_true(replacement != "")
	var again := sim.cmd_place_grid_component("feeder",
			sim.grid.component(moved[0])["tile"], 2)
	assert_true(bool(again["ok"]), str(again))
	assert_true(int((again["payload"] as Dictionary)["adopts"]) > 0,
			"an orphan is the first thing new copper picks up")


func test_parallel_transformer_relieves_a_hotspot_through_the_verb() -> void:
	# Doc 04 §2.9's "parallel transformer on one service group", end to end
	# through `cmd_place_grid_component`. Before Wave 6 this purchase moved no
	# load at all, because §2.1's attachment rule only ever runs for a building
	# with NO transformer.
	var sim := CitySim.boot_from_files()
	sim.advance_hours(8.0)
	var hot := sim.grid.worst_transformer(25.0)
	assert_true(String(hot["id"]) != "")
	var before: float = float(hot["load_kw"])
	assert_true(before > 0.0)
	var spot := _transformer_spot(sim, hot["tile"], 2)
	assert_true(spot.x >= 0)
	var preview := sim.cmd_place_grid_component("transformer", spot, 3, true)
	assert_true(bool(preview["ok"]), str(preview))
	assert_true(int((preview["payload"] as Dictionary)["relieves"]) > 0,
			"the quote says what it takes off the neighbour")
	var placed := sim.cmd_place_grid_component("transformer", spot, 3)
	assert_true(bool(placed["ok"]))
	assert_eq(int((placed["payload"] as Dictionary)["relieves"]),
			int((preview["payload"] as Dictionary)["relieves"]),
			"and the quote is what happens")
	sim.advance_hours(1.0)
	assert_true(float(sim.grid.component(String(hot["id"]))["load_kw"]) < before,
			"the cooking transformer is measurably cooler for the purchase")


# =================================================== 2. cmd_demolish_building

func test_demolish_active_building() -> void:
	var sim := CitySim.boot_from_files()
	sim.advance_hours(1.0)
	var b: Building = sim.buildings["H-001"]
	var grid_id := b.id
	var origin := b.origin
	var population_before: int = sim.districts.district(
			sim._block_to_district[String(sim._building_records["H-001"]["block"])])["population"]
	var balance: int = sim.treasury.balance

	var preview := sim.cmd_demolish_building("H-001", true)
	assert_true(bool(preview["ok"]))
	# doc 03 §2.3: DEMOLITION_REFUND_FRACTION 0.25 × capital_value(house, L1).
	assert_eq(int(preview["payload"]["refund"]), 300, "0.25 × $1,200 capital")
	assert_eq(sim.treasury.balance, balance, "preview credits nothing")

	var result := sim.cmd_demolish_building("H-001")
	assert_true(bool(result["ok"]), str(result))
	assert_eq(sim.treasury.balance, balance + 300)
	assert_false(sim.buildings.has("H-001"))
	assert_true(sim.world.grid.can_place(origin, Vector2i.ONE), "tiles cleared")
	assert_eq(sim.world.grid.building_at(origin.x, origin.y), 0)
	assert_eq(sim.grid.attachment_of("H-001"), "", "detached from the grid")
	assert_false(sim._block_dark_weights.has("H-001"), "block-dark weight cleaned up")
	var population_after: int = sim.districts.district(
			sim._block_to_district["B_2_2"])["population"]
	assert_true(population_after < population_before, "the district rollup shrank at once")
	# The renderer's event, which render_state_model already consumes.
	var seen := false
	for event in sim.bus.drain():
		if String(event.get("type", "")) == "building_removed" \
				and int(event.get("building", -1)) == grid_id:
			seen = true
			assert_eq(int(event["refund"]), 300)
	assert_true(seen, "building_removed emitted for the renderer")


func test_demolish_mid_construction_uses_the_queue_refund_table() -> void:
	# doc 02 §2.10: a job with progress refunds 0.60 × (1 − progress) of what it
	# was charged; a level-0 site has no capital, so that is the whole refund.
	var sim := CitySim.boot_from_files()
	var origin := _serviceable_vacant_tile(sim)
	var placed := sim.cmd_place_building("store", origin)
	var sim_id := String(placed["payload"]["sim_id"])
	var cost := int(placed["payload"]["cost"])
	sim.advance_hours(1.0)
	var balance: int = sim.treasury.balance
	var progress := sim.construction.progress(int(placed["payload"]["job_id"]))
	assert_true(progress > 0.0 and progress < 1.0, "mid-build")
	var result := sim.cmd_demolish_building(sim_id)
	assert_true(bool(result["ok"]), str(result))
	var expected := CostCurves.round_half_up(float(cost) * 0.60 * (1.0 - progress))
	assert_eq(int(result["payload"]["capital_refund"]), 0, "nothing was ever completed")
	assert_eq(int(result["payload"]["job_refund"]), expected)
	assert_eq(sim.treasury.balance, balance + expected)
	assert_eq(sim.construction.job(int(placed["payload"]["job_id"])).size(), 0,
			"the job left the queue")
	assert_true(sim.world.grid.can_place(origin, Vector2i.ONE))


func test_demolish_rejections() -> void:
	var sim := CitySim.boot_from_files()
	assert_eq(sim.cmd_demolish_building("NOPE")["reason_code"], &"E_UNKNOWN_BUILDING")
	var b: Building = sim.buildings["H-002"]
	b.state = &"on_fire"
	assert_eq(sim.cmd_demolish_building("H-002")["reason_code"], &"E_STATE")
	b.state = &"destroyed"
	assert_eq(sim.cmd_demolish_building("H-002")["reason_code"], &"E_STATE")
	assert_true(sim.buildings.has("H-002"), "a refused demolition removes nothing")


func test_demolish_survives_save_roundtrip() -> void:
	var sim := CitySim.boot_from_files(99)
	sim.advance_hours(1.0)
	var origin: Vector2i = (sim.buildings["H-003"] as Building).origin
	sim.cmd_demolish_building("H-003")
	sim.advance_hours(0.5)
	var body := sim.canonical_capture()
	var restored := CitySim.boot_from_files(99)
	restored.restore_state(body)
	assert_false(restored.buildings.has("H-003"), "the demolition is not undone by a load")
	assert_true(restored.world.grid.can_place(origin, Vector2i.ONE),
			"nor is its tile reservation")
	sim.advance_hours(6.0)
	restored.advance_hours(6.0)
	assert_eq(sim.state_hash(), restored.state_hash())


func test_demolished_ids_are_never_recycled() -> void:
	# Regression: grid ids are a high-water mark. If a demolished id were handed
	# out again, the save would carry the same sim_id in both `placed_records`
	# and `removed_records`, and the reload would erase the live building while
	# replaying the old demolition.
	var sim := CitySim.boot_from_files(63)
	var first_tile := _serviceable_vacant_tile(sim)
	var first := String(sim.cmd_place_building("house", first_tile)["payload"]["sim_id"])
	var first_id: int = (sim.buildings[first] as Building).id
	sim.cmd_demolish_building(first)
	# The same tile is free again, so this is the exact collision case.
	var second := String(sim.cmd_place_building("house", first_tile)["payload"]["sim_id"])
	assert_ne(second, first, "the demolished sim_id is retired, not reissued")
	assert_eq((sim.buildings[second] as Building).id, first_id + 1)
	sim.advance_hours(4.0)
	var body := sim.canonical_capture()
	var restored := CitySim.boot_from_files(63)
	restored.restore_state(body)
	assert_true(restored.buildings.has(second), "the live building survives the reload")
	assert_false(restored.buildings.has(first), "and the demolished one stays gone")
	assert_false(restored.world.grid.can_place(first_tile, Vector2i.ONE),
			"the surviving building still holds its tile")
	sim.advance_hours(6.0)
	restored.advance_hours(6.0)
	assert_eq(sim.state_hash(), restored.state_hash())


func test_id_retirement_survives_a_reload() -> void:
	# The high-water mark is persisted, so a reload cannot re-open a retired id
	# even though the live roster has forgotten it.
	var sim := CitySim.boot_from_files(64)
	var tile := _serviceable_vacant_tile(sim)
	var placed := String(sim.cmd_place_building("house", tile)["payload"]["sim_id"])
	var retired: int = (sim.buildings[placed] as Building).id
	sim.cmd_demolish_building(placed)
	var restored := CitySim.boot_from_files(64)
	restored.restore_state(sim.canonical_capture())
	var after := String(restored.cmd_place_building("house", tile)["payload"]["sim_id"])
	assert_ne(after, placed, "a retired id stays retired across a save")
	assert_true((restored.buildings[after] as Building).id > retired)


func test_demolish_determinism() -> void:
	var sim := CitySim.boot_from_files(7)
	sim.advance_hours(1.0)
	sim.cmd_demolish_building("H-004")
	var body := sim.canonical_capture()
	var a := CitySim.boot_from_files(7)
	a.restore_state(body)
	var b := CitySim.boot_from_files(7)
	b.restore_state(body)
	a.advance_hours(12.0)
	b.advance_hours(12.0)
	assert_eq(a.state_hash(), b.state_hash())


# ===================================================== 3. cmd_repair_building

func test_repair_from_active_restores_to_new() -> void:
	# doc 02 §2.6 / doc 03 §2.5, on the house L1 fixture: capital $1,200,
	# damage 0.50 ⇒ cost 1,200 × 0.50 × 0.85 = $510 and crew-hours
	# build_time_hours 2.0 × 0.50 × 0.50 = 0.50.
	var sim := CitySim.boot_from_files()
	var b: Building = sim.buildings["H-001"]
	b.condition = 0.50
	var balance: int = sim.treasury.balance
	var preview := sim.cmd_repair_building("H-001", true)
	assert_true(bool(preview["ok"]), str(preview))
	assert_eq(int(preview["payload"]["cost"]), 510)
	assert_almost_eq(float(preview["payload"]["crew_hours"]), 0.50, 1e-9)
	assert_almost_eq(float(preview["payload"]["repair_target"]), 1.00, 1e-9)
	assert_eq(sim.treasury.balance, balance, "preview never spends")

	var result := sim.cmd_repair_building("H-001")
	assert_true(bool(result["ok"]), str(result))
	assert_eq(sim.treasury.balance, balance - 510)
	assert_eq(b.state, &"repairing")
	var job: Dictionary = sim.construction.job(int(result["payload"]["job_id"]))
	assert_eq(job["kind"], &"repair", "doc 02 §2.13 job kind")
	sim.advance_hours(4.0)
	assert_eq(b.state, &"active")
	# doc 02 §2.6 wear is live (doc 92 F-2), so the hours the house stands AFTER
	# its repair have already cost it condition: the target is 1.00 and what is
	# left of it is `1.00 − hours_since × decay_per_hour` (house L1, 0.00045/gh).
	assert_almost_eq(b.condition, 1.0, 4.0 * 0.00045,
			"repair from active targets 1.00, less the wear since")
	assert_true(b.condition < 1.0, "and the city keeps wearing out afterwards")


func test_repair_from_damaged_targets_085() -> void:
	# doc 02 §2.12: post-damage repairs never restore to new.
	var sim := CitySim.boot_from_files()
	var b: Building = sim.buildings["H-002"]
	b.condition = 0.20
	b.state = &"damaged"
	var result := sim.cmd_repair_building("H-002")
	assert_true(bool(result["ok"]), str(result))
	assert_almost_eq(float(result["payload"]["repair_target"]),
			Building.REPAIR_TARGET_FROM_DAMAGED, 1e-9)
	sim.advance_hours(4.0)
	assert_eq(b.state, &"active")
	assert_almost_eq(b.condition, 0.85, 4.0 * 0.00045,
			"0.85 target, less doc 02 §2.6 wear since (doc 92 F-2)")


func test_repair_rejections() -> void:
	var sim := CitySim.boot_from_files()
	assert_eq(sim.cmd_repair_building("NOPE")["reason_code"], &"E_UNKNOWN_BUILDING")
	# Nothing wrong with it.
	assert_eq(sim.cmd_repair_building("H-001")["reason_code"], &"E_NOT_DAMAGED")
	# Wrong state.
	var b: Building = sim.buildings["H-002"]
	b.condition = 0.5
	b.state = &"under_construction"
	assert_eq(sim.cmd_repair_building("H-002")["reason_code"], &"E_STATE")
	b.state = &"active"
	# Already queued.
	assert_true(bool(sim.cmd_repair_building("H-002")["ok"]))
	b.state = &"active"  # force the state gate open to reach the queue check
	assert_eq(sim.cmd_repair_building("H-002")["reason_code"], &"E_JOB_IN_FLIGHT")
	# Broke.
	var c: Building = sim.buildings["H-003"]
	c.condition = 0.1
	var balance: int = sim.treasury.balance
	sim.treasury.spend(balance - 1, &"misc")
	assert_eq(sim.cmd_repair_building("H-003")["reason_code"], &"E_FUNDS")
	assert_eq(sim.treasury.balance, 1, "a refused repair charges nothing")


func test_repair_survives_save_roundtrip_mid_job() -> void:
	var sim := CitySim.boot_from_files(21)
	var b: Building = sim.buildings["APT-001"]
	b.condition = 0.40
	assert_true(bool(sim.cmd_repair_building("APT-001")["ok"]))
	sim.advance_hours(0.25)  # save with the repair job in flight
	var body := sim.canonical_capture()
	var restored := CitySim.boot_from_files(21)
	restored.restore_state(body)
	assert_eq((restored.buildings["APT-001"] as Building).state, &"repairing")
	sim.advance_hours(10.0)
	restored.advance_hours(10.0)
	assert_eq(sim.state_hash(), restored.state_hash())
	assert_eq((restored.buildings["APT-001"] as Building).state, &"active")


# ========================================================= 4. cmd_set_priority

func test_set_priority_and_aliases() -> void:
	var sim := CitySim.boot_from_files()
	assert_eq(sim.grid.priority_class_of("H-001"), &"STANDARD")
	var result := sim.cmd_set_priority("H-001", "CRITICAL")
	assert_true(bool(result["ok"]), str(result))
	assert_eq(String(result["payload"]["previous"]), "STANDARD")
	assert_eq(sim.grid.priority_class_of("H-001"), &"CRITICAL")
	# The audit's "PRIORITY" spelling resolves onto doc 04's ESSENTIAL tier.
	assert_eq(String(sim.cmd_set_priority("H-001", "PRIORITY")["payload"]["priority_class"]),
			"ESSENTIAL")
	assert_eq(sim.grid.priority_class_of("H-001"), &"ESSENTIAL")


func test_set_priority_rejections() -> void:
	var sim := CitySim.boot_from_files()
	assert_eq(sim.cmd_set_priority("NOPE", "CRITICAL")["reason_code"], &"E_UNKNOWN_BUILDING")
	assert_eq(sim.cmd_set_priority("H-001", "URGENT")["reason_code"], &"E_UNKNOWN_PRIORITY")
	assert_eq(sim.cmd_set_priority("H-001", "critical")["reason_code"], &"E_UNKNOWN_PRIORITY")
	# A building the grid never gave a service record to cannot carry a class.
	var origin := _serviceable_vacant_tile(sim)
	var sim_id := String(sim.cmd_place_building("house", origin)["payload"]["sim_id"])
	sim.grid.detach_building(sim_id)
	assert_eq(sim.cmd_set_priority(sim_id, "CRITICAL")["reason_code"], &"E_UNSERVED")


func test_priority_loads_survive_shedding() -> void:
	# Doc 04 §2.4: critical feeders shed last. Same city, same deficit, one
	# priority change — and the blackout moves to the other feeder.
	var baseline := _shed_set_under_deficit(false)
	var protected := _shed_set_under_deficit(true)
	assert_eq(baseline, ["F_NORTH"], "with every load STANDARD the bigger feeder sheds")
	assert_eq(protected, ["F_SOUTH"],
			"one CRITICAL load on F_NORTH moves the same blackout to F_SOUTH")


## Run the city to the evening peak, flatten every priority class, optionally
## promote one F_NORTH load to CRITICAL, then starve generation by 40 kW — a
## deficit small enough that exactly one feeder must go dark.
static func _shed_set_under_deficit(promote: bool) -> Array:
	var sim := CitySim.boot_from_files()
	sim.advance_hours(13.0)
	for id in ["WTR-1", "WTR-2"]:
		sim.cmd_set_priority(id, "STANDARD")
	if promote:
		for id in CitySim._sorted(sim.buildings):
			var transformer := sim.grid.attachment_of(String(id))
			if transformer != "" \
					and String(sim.grid.component(transformer)["parent"]) == "F_NORTH":
				sim.cmd_set_priority(String(id), "CRITICAL")
				break
	sim.grid.component("PLANT-1")["capacity_kw"] = sim.grid.system_demand_kw - 40.0
	sim.scheduler.advance_fine_n(2)
	return sim.grid.shed_feeders.duplicate()


func test_priority_survives_save_roundtrip() -> void:
	var sim := CitySim.boot_from_files(5)
	sim.cmd_set_priority("H-001", "CRITICAL")
	sim.advance_hours(0.5)
	var body := sim.canonical_capture()
	var restored := CitySim.boot_from_files(5)
	restored.restore_state(body)
	assert_eq(restored.grid.priority_class_of("H-001"), &"CRITICAL")
	sim.advance_hours(4.0)
	restored.advance_hours(4.0)
	assert_eq(sim.state_hash(), restored.state_hash())


# ======================================================== 5. cmd_set_tax_level

func test_tax_ladder_matches_doc_03() -> void:
	var sim := CitySim.boot_from_files()
	# doc 03 §8: 0.04 … 0.16 in 0.01 steps ⇒ 13 detents, base 0.09 at level 5.
	assert_eq(sim.tax_level_count(), 13)
	assert_almost_eq(sim.tax_rate_for_level(0), 0.04, 1e-12)
	assert_almost_eq(sim.tax_rate_for_level(12), 0.16, 1e-12)
	assert_eq(sim.tax_rate_for_level(5), 0.09, "level 5 lands exactly on TAX_RATE_BASE")
	assert_eq(sim.tax_level(), 5, "the city starts at base")
	assert_eq(sim.tax_rate, 0.09)


func test_set_tax_level_effects() -> void:
	var sim := CitySim.boot_from_files()
	var result := sim.cmd_set_tax_level(12)
	assert_true(bool(result["ok"]), str(result))
	assert_eq(sim.tax_rate, 0.16)
	assert_eq(sim.tax_level(), 12)
	# doc 03 §2.2's two couplings, exactly.
	assert_almost_eq(float(result["payload"]["happiness_delta"]), -25.2, 1e-9,
			"−(0.16 − 0.09) × 360")
	assert_almost_eq(float(result["payload"]["growth_multiplier"]), 0.44, 1e-9,
			"1 − (0.16 − 0.09) × 8.0")
	# And they reach the sim: happiness falls where the base rate held it.
	var base := CitySim.boot_from_files()
	base.advance_hours(6.0)
	sim.advance_hours(6.0)
	assert_true(sim.happiness.happiness < base.happiness.happiness,
			"a tax hike erodes happiness")
	assert_true(sim.population.attractiveness <= base.population.attractiveness,
			"and slows growth")


func test_set_tax_level_raises_revenue() -> void:
	# doc 03 §2.2: `tax_policy_factor = r / TAX_RATE_BASE` scales every building's
	# revenue, so the settled hour is worth more at a higher rate.
	var low := CitySim.boot_from_files()
	var high := CitySim.boot_from_files()
	assert_true(bool(high.cmd_set_tax_level(12)["ok"]))
	assert_almost_eq(high.economy.tax_policy_factor(high.tax_rate), 0.16 / 0.09, 1e-9)
	low.advance_hours(1.0)
	high.advance_hours(1.0)
	assert_true(_settled_gross(high) > _settled_gross(low),
			"the settled hour is worth more at the higher rate")


## Gross revenue of the last settled game-hour, off the event stream.
static func _settled_gross(sim: CitySim) -> float:
	var gross := 0.0
	for event in sim.bus.drain():
		if String(event.get("type", "")) == "economy_hour_settled":
			gross = float(event["gross"])
	return gross


func test_set_tax_level_rejections() -> void:
	var sim := CitySim.boot_from_files()
	assert_eq(sim.cmd_set_tax_level(-1)["reason_code"], &"E_TAX_LEVEL_RANGE")
	assert_eq(sim.cmd_set_tax_level(13)["reason_code"], &"E_TAX_LEVEL_RANGE")
	assert_eq(sim.tax_rate, 0.09, "a refused change moves nothing")
	# Re-setting the level the city is on is a free no-op — no cooldown started.
	var same := sim.cmd_set_tax_level(5)
	assert_true(bool(same["ok"]))
	assert_false(bool(same["payload"]["changed"]))
	assert_eq(sim.tax_rate_changed_hour, -1)
	# The first real change takes; the second is inside doc 03's 48 gh window.
	assert_true(bool(sim.cmd_set_tax_level(6)["ok"]))
	var blocked := sim.cmd_set_tax_level(7)
	assert_eq(blocked["reason_code"], &"E_TAX_COOLDOWN")
	assert_eq(int(blocked["payload"]["hours_remaining"]), 48)
	assert_eq(sim.tax_rate, sim.tax_rate_for_level(6))
	# Past the window it moves again.
	sim.advance_hours(48.0)
	assert_true(bool(sim.cmd_set_tax_level(7)["ok"]), "the cooldown expires")


func test_tax_level_survives_save_roundtrip() -> void:
	var sim := CitySim.boot_from_files(11)
	sim.advance_hours(2.0)
	assert_true(bool(sim.cmd_set_tax_level(2)["ok"]))
	var body := sim.canonical_capture()
	var restored := CitySim.boot_from_files(11)
	restored.restore_state(body)
	assert_eq(restored.tax_rate, sim.tax_rate)
	assert_eq(restored.tax_rate_changed_hour, sim.tax_rate_changed_hour)
	assert_eq(restored.cmd_set_tax_level(3)["reason_code"], &"E_TAX_COOLDOWN",
			"the cooldown is not reset by a reload")
	sim.advance_hours(6.0)
	restored.advance_hours(6.0)
	assert_eq(sim.state_hash(), restored.state_hash())


# ============================================================ 6. cmd_buy_block

func test_buy_block_price_matches_doc_09() -> void:
	var sim := CitySim.boot_from_files()
	# doc 09 §2.8.2 / doc 03 worked example E: the tidal-marsh block, the
	# cheapest land on the board, has no owned neighbours so its price carries
	# no live prestige term and must land exactly on the published figure.
	assert_eq(sim.economy.land_price(sim.land_price_inputs("B_0_6")), 6700)
	# Ring-1 prices track doc 09's t0 sheet; prestige is live (doc 09 §2.2 reads
	# it off district stability), so the sheet is matched to within 1 %.
	for row in [["B_1_1", 9200], ["B_5_3", 16700], ["B_2_5", 10800], ["B_1_4", 12500]]:
		var price := sim.economy.land_price(sim.land_price_inputs(String(row[0])))
		assert_true(absi(price - int(row[1])) * 100 <= int(row[1]),
				"%s priced %d against doc 09's %d" % [row[0], price, int(row[1])])


func test_buy_block_success_and_escalation() -> void:
	var sim := CitySim.boot_from_files()
	sim.treasury.credit(300_000, &"test_grant")
	var balance: int = sim.treasury.balance
	var preview := sim.cmd_buy_block("B_3_1", true)
	assert_true(bool(preview["ok"]), str(preview))
	assert_eq(sim.treasury.balance, balance, "preview never spends")
	var price := int(preview["payload"]["price"])
	assert_true(int(preview["payload"]["development_estimate"]) > 0,
			"the purchase dialog gets doc 03 §2.8's TCO half too")

	var bought := sim.cmd_buy_block("B_3_1")
	assert_true(bool(bought["ok"]), str(bought))
	assert_true(sim.world.block("B_3_1").is_owned())
	assert_eq(sim.world.block("B_3_1").purchase_price, price)
	assert_eq(sim.world.owned_count(), 10)
	# Land plus the first development phase, both charged.
	assert_true(sim.treasury.balance < balance - price)
	assert_true(bool(bought["payload"]["development_started"]))
	assert_eq(String(sim.world.block("B_3_1").development_state), "SURVEY")
	# doc 03 §2.7's growth brake: the 10th block owned makes the 11th 6 % dearer.
	var before_escalation := 1.0
	var after := sim.economy.escalation_factor(sim.world.owned_count())
	assert_almost_eq(after, 1.06, 1e-9)
	assert_almost_eq(sim.economy.escalation_factor(9), before_escalation, 1e-9)


func test_buy_block_rejections() -> void:
	var sim := CitySim.boot_from_files()
	assert_eq(sim.cmd_buy_block("B_9_9")["reason_code"], &"E_UNKNOWN_BLOCK")
	assert_eq(sim.cmd_buy_block("B_2_2")["reason_code"], &"E_ALREADY_OWNED")
	# Ring 2 needs a higher city level (doc 09 §2.8.2 minLvl column).
	assert_eq(sim.cmd_buy_block("B_0_0")["reason_code"], &"E_CITY_LEVEL")
	# Diagonal contact does not qualify (doc 09 §2.5).
	assert_eq(sim.cmd_buy_block("B_1_1")["reason_code"], &"E_NOT_ADJACENT")
	# Broke.
	sim.treasury.spend(sim.treasury.balance - 100, &"misc")
	var broke := sim.cmd_buy_block("B_3_1")
	assert_eq(broke["reason_code"], &"E_FUNDS")
	assert_eq(sim.treasury.balance, 100, "a refused purchase charges nothing")
	assert_false(sim.world.block("B_3_1").is_owned())


func test_buy_block_grows_the_city_outward() -> void:
	# The whole point of the verb: buy → develop → build. Doc 03 §2.8's six
	# phases run and are billed, `final_development` opens the ground, and
	# `utility_corridor` brings the feeder within tap range of the new block.
	var sim := CitySim.boot_from_files()
	sim.treasury.credit(400_000, &"test_grant")
	assert_true(bool(sim.cmd_buy_block("B_3_1")["ok"]))
	var block := sim.world.block("B_3_1")
	var centre := block.grid * TileGrid.TILES_PER_BLOCK \
			+ Vector2i(TileGrid.TILES_PER_BLOCK / 2, TileGrid.TILES_PER_BLOCK / 2)
	assert_false(sim.world.grid.can_place(centre, Vector2i.ONE), "raw ground is not buildable")

	var spent_before: int = sim.treasury.balance
	for _i in range(0, 40):
		sim.advance_hours(4.0)
		if block.is_ready():
			break
	assert_true(block.is_ready(), "the six-phase pipeline completes")
	assert_eq(sim.development.blocks_developed, 1)
	assert_true(sim.treasury.balance < spent_before, "every phase was billed")
	assert_true(sim.world.grid.can_place(centre, Vector2i.ONE),
			"final_development opened the ground")

	var placed := sim.cmd_place_grid_component("transformer", centre, 1)
	assert_true(bool(placed["ok"]), str(placed))
	assert_true(sim.grid.would_serve(centre), "the new block can be served")
	var house := sim.cmd_place_building("house", centre + Vector2i(1, 0))
	assert_true(bool(house["ok"]), str(house))


func test_start_development_rejections() -> void:
	var sim := CitySim.boot_from_files()
	assert_eq(sim.cmd_start_development("B_9_9")["reason_code"], &"E_UNKNOWN_BLOCK")
	assert_eq(sim.cmd_start_development("B_3_1")["reason_code"], &"E_NOT_OWNED")
	# Core blocks shipped READY.
	assert_eq(sim.cmd_start_development("B_2_2")["reason_code"], &"E_ALREADY_DEVELOPING")
	sim.treasury.credit(300_000, &"test_grant")
	sim.cmd_buy_block("B_3_1", false, false)
	assert_true(bool(sim.cmd_start_development("B_3_1", true)["ok"]), "preview passes")
	assert_true(bool(sim.cmd_start_development("B_3_1")["ok"]))
	assert_eq(sim.cmd_start_development("B_3_1")["reason_code"], &"E_ALREADY_DEVELOPING")


func test_buy_block_without_funds_for_survey_still_buys() -> void:
	# Doc 09 §2.3 keeps buying and developing separate, so a purchase the player
	# can afford is never refused because the NEXT step is unaffordable.
	var sim := CitySim.boot_from_files()
	var price := sim.economy.land_price(sim.land_price_inputs("B_3_1"))
	sim.treasury.spend(sim.treasury.balance - price - 10, &"misc")
	var bought := sim.cmd_buy_block("B_3_1")
	assert_true(bool(bought["ok"]), str(bought))
	assert_true(sim.world.block("B_3_1").is_owned())
	assert_false(bool(bought["payload"]["development_started"]))
	assert_eq(bought["payload"]["development_reason"], &"E_FUNDS")
	assert_eq(String(sim.world.block("B_3_1").development_state), "UNDEVELOPED")


func test_buy_block_survives_save_roundtrip_mid_development() -> void:
	var sim := CitySim.boot_from_files(31)
	sim.treasury.credit(400_000, &"test_grant")
	sim.cmd_buy_block("B_3_1")
	sim.advance_hours(9.0)  # save part-way through the pipeline
	assert_false(sim.world.block("B_3_1").is_ready())
	var body := sim.canonical_capture()
	var restored := CitySim.boot_from_files(31)
	restored.restore_state(body)
	assert_true(restored.world.block("B_3_1").is_owned())
	assert_eq(String(restored.world.block("B_3_1").development_state),
			String(sim.world.block("B_3_1").development_state))
	for _i in range(0, 20):
		sim.advance_hours(4.0)
		restored.advance_hours(4.0)
	assert_true(restored.world.block("B_3_1").is_ready())
	assert_eq(sim.state_hash(), restored.state_hash(),
			"a reload mid-pipeline stays bit-identical to the live run")


# ======================================================= cross-verb integrity

func test_every_verb_together_is_deterministic() -> void:
	# One session that uses all six verbs, captured, then advanced twice from
	# the same capture: the constitution §5 contract, applied to the new layer.
	var script := func(sim: CitySim) -> void:
		sim.treasury.credit(400_000, &"test_grant")
		var lot := _lot_a(sim)
		sim.cmd_place_grid_component("transformer", _transformer_spot(sim, lot, 3), 2)
		sim.cmd_place_building("house", lot)
		sim.cmd_set_priority("H-001", "CRITICAL")
		sim.cmd_set_tax_level(7)
		sim.cmd_buy_block("B_3_1")
		sim.advance_hours(3.0)
		var b: Building = sim.buildings["H-002"]
		b.condition = 0.45
		sim.cmd_repair_building("H-002")
		sim.cmd_demolish_building("H-005")
		sim.advance_hours(5.0)

	var sim := CitySim.boot_from_files(2026)
	script.call(sim)
	var body := sim.canonical_capture()
	var a := CitySim.boot_from_files(2026)
	a.restore_state(body)
	var b := CitySim.boot_from_files(2026)
	b.restore_state(body)
	assert_eq(a.state_hash(), b.state_hash())
	a.advance_hours(24.0)
	b.advance_hours(24.0)
	assert_eq(a.state_hash(), b.state_hash(), "24 game-hours on, still identical")
	sim.advance_hours(24.0)
	assert_eq(sim.state_hash(), a.state_hash(),
			"and the reload matches the sim that never stopped")


func test_verbs_never_charge_on_failure() -> void:
	# One invariant across the whole layer: a refused command is free.
	var sim := CitySim.boot_from_files()
	var balance: int = sim.treasury.balance
	sim.cmd_place_grid_component("transformer", Vector2i(8, 8), 1)
	sim.cmd_place_grid_component("transformer", Vector2i(40, 40), 9)
	sim.cmd_demolish_building("NOPE")
	sim.cmd_repair_building("NOPE")
	sim.cmd_set_priority("NOPE", "CRITICAL")
	sim.cmd_set_tax_level(99)
	sim.cmd_buy_block("B_0_0")
	sim.cmd_start_development("B_0_0")
	assert_eq(sim.treasury.balance, balance)
