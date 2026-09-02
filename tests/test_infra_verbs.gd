extends SimTest
## Wave 5's infrastructure verbs — the last missing player powers.
##
##   doc 10 §2.13   `cmd_place_road` / `cmd_upgrade_road` / `cmd_demolish_road`
##   doc 09 §2.9.1  the block road template, stamped at `ROAD_INSTALL`
##   doc 05 §6      `cmd_place_water_component` / `cmd_place_water_main` /
##                  `cmd_upgrade_water_component` / isolate + restore
##   doc 92 F-7     `cmd_place_building` enforces `min_city_level`
##
## Same contract every other verb suite holds itself to: the success path, every
## documented failure code in its documented ORDER, a determinism check and a
## save round-trip taken mid-effect.


# ------------------------------------------------------------------ helpers

const CORE_LO := 32
const CORE_HI := 80


## A vacant, buildable tile in the READY core that touches an existing road —
## the tile `cmd_place_road` is happy with.
static func _road_ready_tile(sim: CitySim) -> Vector2i:
	for z in range(CORE_LO, CORE_HI):
		for x in range(CORE_LO, CORE_HI):
			var t := Vector2i(x, z)
			if not sim.world.grid.can_place(t, Vector2i.ONE):
				continue
			for d in RoadGraph.DIRS:
				var q: Vector2i = t + d
				if TileGrid.in_bounds(q.x, q.y) \
						and sim.world.grid.road_class_at(q.x, q.y) != TileGrid.ROAD_NONE:
					return t
	return Vector2i(-1, -1)


## A vacant core tile with NO road within one step — the E_NOT_CONNECTED case.
static func _isolated_tile(sim: CitySim) -> Vector2i:
	for z in range(CORE_LO, CORE_HI):
		for x in range(CORE_LO, CORE_HI):
			var t := Vector2i(x, z)
			if not sim.world.grid.can_place(t, Vector2i.ONE):
				continue
			var clear := true
			for d in RoadGraph.DIRS:
				var q: Vector2i = t + d
				if TileGrid.in_bounds(q.x, q.y) \
						and sim.world.grid.road_class_at(q.x, q.y) != TileGrid.ROAD_NONE:
					clear = false
					break
			if clear:
				return t
	return Vector2i(-1, -1)


static func _water_tile(sim: CitySim) -> Vector2i:
	for z in TileGrid.SIZE:
		for x in TileGrid.SIZE:
			if sim.world.grid.has_flag(x, z, TileGrid.FLAG_WATER):
				return Vector2i(x, z)
	return Vector2i(-1, -1)


## A site a water component can legally take: footprint free, a main in tap
## range, and a transformer already reaching it.
static func _water_site(sim: CitySim, size: Vector2i) -> Vector2i:
	for z in range(CORE_LO, CORE_HI):
		for x in range(CORE_LO, CORE_HI):
			var t := Vector2i(x, z)
			if not sim.world.grid.can_place(t, size):
				continue
			if sim.water.nearest_main_tile(t, 8).is_empty():
				continue
			if not sim.grid.would_serve(t):
				continue
			return t
	return Vector2i(-1, -1)


static func _serviceable_lot(sim: CitySim, size: Vector2i = Vector2i.ONE) -> Vector2i:
	for z in range(CORE_LO, CORE_HI):
		for x in range(CORE_LO, CORE_HI):
			var t := Vector2i(x, z)
			if sim.world.grid.can_place(t, size) and sim.grid.would_serve(t):
				return t
	return Vector2i(-1, -1)


static func _advance_to_ready(sim: CitySim, block_id: String, cap: int = 4000) -> int:
	for h in cap:
		sim.advance_coarse_hours(1, false)
		if (sim.world.block(block_id) as LandBlock).is_ready():
			return h + 1
	return -1


# =========================================================== doc 10 §2.13 build

func test_place_road_charges_doc_03_and_enters_under_construction() -> void:
	# §2.13's under-construction lifecycle: the tile joins the grid IMMEDIATELY
	# at `under_construction_seed` behind a `construction_new` closure, so the
	# crew can reach the far end of its own job — and the job's completion is
	# what takes it to 1.00.
	var sim := CitySim.boot_from_files()
	var tile := _road_ready_tile(sim)
	assert_true(tile.x >= 0, "the core has a vacant tile beside a road")
	var quote := sim.cmd_place_road([tile], TileGrid.ROAD_STREET, true)
	assert_true(bool(quote["ok"]), str(quote))
	# doc 03 §2.13(d): STREET is $1,800 per tile, and the preview charges nothing.
	assert_eq(int(quote["payload"]["cost"]), 1800)
	assert_eq(int(quote["payload"]["tiles"]), 1)
	var before: int = sim.treasury.balance
	var placed := sim.cmd_place_road([tile], TileGrid.ROAD_STREET)
	assert_true(bool(placed["ok"]), str(placed))
	assert_eq(before - sim.treasury.balance, 1800, "charged exactly the quote")
	assert_eq(sim.world.grid.road_class_at(tile.x, tile.y), TileGrid.ROAD_STREET)
	assert_almost_eq(sim.roads.condition_of(tile), sim.roads.tun.under_construction_seed,
			0.0001, "seeded at 0.10 while the crew works")
	assert_false(sim.world.grid.has_flag(tile.x, tile.y, TileGrid.FLAG_BUILDABLE),
			"paving takes the tile out of the buildable count")
	# The job is doc 02's, with doc 10's payload on it.
	var jobs := sim.construction.active_jobs()
	var found := false
	for job in jobs:
		if String((job["payload"] as Dictionary).get("roads_kind", "")) == "build":
			found = true
			assert_eq(int((job["payload"] as Dictionary)["cost"]), 1800)
	assert_true(found, "the road job went to doc 02's ConstructionQueue")
	# And it finishes.
	for i in 12:
		sim.advance_hours(1.0)
	assert_almost_eq(sim.roads.condition_of(tile), 1.0, 0.02,
			"job_completed takes it to 1.00")


func test_place_road_reason_codes_in_doc_order() -> void:
	var sim := CitySim.boot_from_files()
	assert_eq(sim.cmd_place_road([Vector2i(40, 40)], 9)["reason_code"],
			&"E_UNKNOWN_ROAD_CLASS")
	assert_eq(sim.cmd_place_road([], TileGrid.ROAD_STREET)["reason_code"], &"E_NO_TILES")
	assert_eq(sim.cmd_place_road([Vector2i(-1, 4)], TileGrid.ROAD_STREET, true)["reason_code"],
			&"E_OUT_OF_BOUNDS")
	var wet := _water_tile(sim)
	assert_true(wet.x >= 0)
	assert_eq(sim.cmd_place_road([wet], TileGrid.ROAD_STREET, true)["reason_code"], &"E_WATER")
	# Doc 09's ring blocks are not developed at t0.
	assert_eq(sim.cmd_place_road([Vector2i(20, 20)], TileGrid.ROAD_STREET, true)["reason_code"],
			&"E_NOT_DEVELOPED")
	var occupied: Building = sim.buildings[sim.buildings.keys()[0]]
	assert_eq(sim.cmd_place_road([occupied.origin], TileGrid.ROAD_STREET, true)["reason_code"],
			&"E_FOOTPRINT")
	var lonely := _isolated_tile(sim)
	assert_true(lonely.x >= 0, "a core courtyard tile away from every road")
	assert_eq(sim.cmd_place_road([lonely], TileGrid.ROAD_STREET, true)["reason_code"],
			&"E_NOT_CONNECTED")
	# An existing road tile is already what it would become.
	var street := Vector2i(-1, -1)
	for z in range(CORE_LO, CORE_HI):
		for x in range(CORE_LO, CORE_HI):
			if sim.world.grid.road_class_at(x, z) == TileGrid.ROAD_STREET:
				street = Vector2i(x, z)
				break
		if street.x >= 0:
			break
	assert_eq(sim.cmd_place_road([street], TileGrid.ROAD_STREET, true)["reason_code"],
			&"E_ALREADY_ROAD")
	# And money is the last gate, never the first.
	sim.treasury.balance = 10
	var tile := _road_ready_tile(sim)
	assert_eq(sim.cmd_place_road([tile], TileGrid.ROAD_STREET)["reason_code"], &"E_FUNDS")


func test_place_road_bills_only_fresh_tiles() -> void:
	# A drag that overlaps existing pavement is billed for what it LAYS.
	var sim := CitySim.boot_from_files()
	var tile := _road_ready_tile(sim)
	var neighbour := Vector2i(-1, -1)
	for d in RoadGraph.DIRS:
		var q: Vector2i = tile + d
		if TileGrid.in_bounds(q.x, q.y) \
				and sim.world.grid.road_class_at(q.x, q.y) != TileGrid.ROAD_NONE:
			neighbour = q
			break
	assert_true(neighbour.x >= 0)
	var quote := sim.cmd_place_road([tile, neighbour], TileGrid.ROAD_STREET, true)
	assert_true(bool(quote["ok"]), str(quote))
	assert_eq(int(quote["payload"]["tiles"]), 1, "the existing tile is not re-laid")
	assert_eq(int(quote["payload"]["cost"]), 1800)


# ========================================================== doc 10 §2.13 upgrade

func test_upgrade_road_street_to_avenue() -> void:
	var sim := CitySim.boot_from_files()
	var tile := _road_ready_tile(sim)
	assert_true(bool(sim.cmd_place_road([tile], TileGrid.ROAD_STREET)["ok"]))
	# While the `construction_new` closure stands, doc 10 refuses the upgrade.
	assert_eq(sim.cmd_upgrade_road([tile], true)["reason_code"], &"E_NO_ELIGIBLE_TILES")
	for i in 12:
		sim.advance_hours(1.0)
	var quote := sim.cmd_upgrade_road([tile], true)
	assert_true(bool(quote["ok"]), str(quote))
	assert_eq(int(quote["payload"]["cost"]), 4000, "doc 03 §2.13(d) STREET_TO_AVENUE")
	var before: int = sim.treasury.balance
	assert_true(bool(sim.cmd_upgrade_road([tile])["ok"]))
	assert_eq(before - sim.treasury.balance, 4000)
	for i in 12:
		sim.advance_hours(1.0)
	assert_eq(sim.world.grid.road_class_at(tile.x, tile.y), TileGrid.ROAD_AVENUE)
	assert_almost_eq(sim.roads.condition_of(tile), 1.0, 0.02,
			"§2.13: an upgrade preserves condition, it does not repair")
	assert_eq(sim.cmd_upgrade_road([], true)["reason_code"], &"E_NO_TILES")


# ========================================================= doc 10 §2.13 demolish

func test_demolish_road_refunds_at_the_class_standing() -> void:
	var sim := CitySim.boot_from_files()
	var tile := _road_ready_tile(sim)
	assert_true(bool(sim.cmd_place_road([tile], TileGrid.ROAD_STREET)["ok"]))
	for i in 12:
		sim.advance_hours(1.0)
	var quote := sim.cmd_demolish_road([tile], true)
	assert_true(bool(quote["ok"]), str(quote))
	# doc 03 §2.13(d): 0.25 × build price → STREET $450.
	assert_eq(int(quote["payload"]["refund"]), 450)
	var before: int = sim.treasury.balance
	assert_true(bool(sim.cmd_demolish_road([tile])["ok"]))
	assert_eq(sim.treasury.balance - before, 450)
	assert_eq(sim.world.grid.road_class_at(tile.x, tile.y), TileGrid.ROAD_NONE)
	assert_true(sim.world.grid.can_place(tile, Vector2i.ONE),
			"the ground a demolition frees is buildable again")
	assert_eq(sim.cmd_demolish_road([tile])["reason_code"], &"E_NOT_ROAD")


func test_demolish_road_refuses_to_orphan_a_building() -> void:
	# §2.13: rejected if any building's access tile would lose its last road.
	var sim := CitySim.boot_from_files()
	var victim := ""
	var ring: Array = []
	for sim_id in sim.buildings:
		var record: Dictionary = sim._building_records[sim_id]
		var origin: Vector2i = record["origin_global"]
		var foot: Vector2i = record["footprint"]
		var tiles: Array = []
		for z in range(origin.y - 1, origin.y + foot.y + 1):
			for x in range(origin.x - 1, origin.x + foot.x + 1):
				if TileGrid.in_bounds(x, z) \
						and sim.world.grid.road_class_at(x, z) != TileGrid.ROAD_NONE:
					tiles.append(Vector2i(x, z))
		if not tiles.is_empty():
			victim = String(sim_id)
			ring = tiles
			break
	assert_ne(victim, "", "every authored building fronts a road (doc 09 §2.9.1)")
	var refused := sim.cmd_demolish_road(ring, true)
	assert_false(bool(refused["ok"]))
	assert_eq(refused["reason_code"], &"E_WOULD_ORPHAN")
	assert_true((refused["payload"] as Dictionary).has("access_tile"),
			"and names the tile that would be cut off")
	# The refusal is free: nothing was removed and nothing was refunded.
	assert_ne(sim.world.grid.road_class_at(int(ring[0].x), int(ring[0].y)),
			TileGrid.ROAD_NONE)


# =================================================== doc 09 §2.9.1 block template

func test_road_install_stamps_doc_09s_block_template() -> void:
	# The ring-block gap: a developed block used to arrive with NO roads at all,
	# because doc 10 §2.3 says doc 09 owns the template and the stamp had never
	# shipped. It ships here, at doc 09 §2.3's ROAD_INSTALL phase.
	var sim := CitySim.boot_from_files()
	var before := sim.roads.road_tile_counts()
	assert_eq(int(before["AVENUE"]), 540, "doc 09 §2.9.1's authored core")
	assert_eq(int(before["STREET"]), 243)
	sim.treasury.balance = 5_000_000
	assert_true(bool(sim.cmd_buy_block("B_3_1")["ok"]))
	var block := sim.world.block("B_3_1")
	assert_eq(sim.world.grid.count_buildable(block.grid.x, block.grid.y), 0,
			"an undeveloped block opens no ground")
	assert_true(_advance_to_ready(sim, "B_3_1") > 0, "the pipeline reaches READY")
	var after := sim.roads.road_tile_counts()
	assert_eq(int(after["AVENUE"]) - int(before["AVENUE"]),
			RoadNetwork.TEMPLATE_BOUNDARY_TILES, "60 boundary tiles → AVENUE")
	assert_eq(int(after["STREET"]) - int(before["STREET"]),
			RoadNetwork.TEMPLATE_COLLECTOR_TILES, "27 collector tiles → STREET")
	# …and doc 09 §2.9.1's own consequence: 87 paved, 169 buildable.
	assert_eq(sim.world.grid.count_buildable(block.grid.x, block.grid.y), 169)
	# The stamp is billed ONCE by doc 03 §2.8's road_install phase, never per
	# tile (doc 10 §2.3's no-double-billing rule): 87 tiles at §2.13(d) prices
	# would be $360,600, which nothing here spends.
	var stamped_at_tile_prices := RoadNetwork.TEMPLATE_BOUNDARY_TILES * 5200 \
			+ RoadNetwork.TEMPLATE_COLLECTOR_TILES * 1800
	assert_eq(stamped_at_tile_prices, 360_600, "doc 03 §2.13(d)'s recorded figure")
	assert_true(5_000_000 - sim.treasury.balance < stamped_at_tile_prices,
			"the whole development cost less than the per-tile replacement value")


func test_stamped_block_is_reachable_and_buildable() -> void:
	# The point of the template: a bought block joins the road network, so a
	# building placed on it has road access and doc 03 does not zero its revenue.
	var sim := CitySim.boot_from_files()
	sim.treasury.balance = 5_000_000
	assert_true(bool(sim.cmd_buy_block("B_3_1")["ok"]))
	assert_true(_advance_to_ready(sim, "B_3_1") > 0)
	var block := sim.world.block("B_3_1")
	var origin: Vector2i = block.grid * TileGrid.TILES_PER_BLOCK
	var lot := Vector2i(-1, -1)
	for z in range(origin.y, origin.y + TileGrid.TILES_PER_BLOCK):
		for x in range(origin.x, origin.x + TileGrid.TILES_PER_BLOCK):
			if sim.world.grid.can_place(Vector2i(x, z), Vector2i.ONE):
				lot = Vector2i(x, z)
				break
		if lot.x >= 0:
			break
	assert_true(lot.x >= 0, "the block has open ground")
	assert_true(sim.roads.access_quality(lot) > 0.0,
			"and doc 10 §5.2 grants it road access")
	assert_true(sim.roads.has_class_within(lot, RoadTunables.CLASS_AVENUE,
			sim.roads.tun.avenue_gate_radius_tiles),
			"boundary arterials are AVENUE, so doc 02's L4/L5 gate is answerable")


# ================================================= doc 05 §6 water components

func test_place_water_component_builds_shell_node_and_lateral() -> void:
	var sim := CitySim.boot_from_files()
	sim.treasury.balance = 500_000
	var site := _water_site(sim, Vector2i(3, 3))
	assert_true(site.x >= 0, "the core has a serviceable pump site near a main")
	var quote := sim.cmd_place_water_component("pump", site, 1, true)
	assert_true(bool(quote["ok"]), str(quote))
	# doc 03 §8 water: 45,000 × CAPITAL_VALUE_V[0] × pump ratio 1.00, plus the
	# service lateral at $286/tile.
	var lateral: int = int(quote["payload"]["lateral_tiles"])
	assert_eq(int(quote["payload"]["cost"]), 45_000 + lateral * 286)
	assert_almost_eq(float(quote["payload"]["kw_required"]), 60.0, 0.001,
			"doc 05 §8's L1 pump column, which is doc 02's water_facility kW")
	var before: int = sim.treasury.balance
	var placed := sim.cmd_place_water_component("pump", site)
	assert_true(bool(placed["ok"]), str(placed))
	assert_eq(before - sim.treasury.balance, int(quote["payload"]["cost"]))
	var sim_id := String(placed["payload"]["sim_id"])
	var node_id := String(placed["payload"]["node"])
	# 1. the doc 02 shell
	var shell: Building = sim.buildings[sim_id]
	assert_eq(String(shell.archetype), "water_facility")
	assert_eq(String(shell.variant), "pump")
	assert_eq(String(shell.state), "under_construction")
	assert_ne(sim.grid.attachment_of(sim_id), "", "and doc 04 energises it")
	# 2. the doc 05 node, held offline until the shell finishes
	var node: WaterNode = sim.water.nodes[node_id]
	assert_eq(String(node.variant), "pump")
	assert_eq(String(node.state), "offline_manual")
	assert_eq(node.power_ref, sim_id, "hosted on the shell, as WTR-1 hosts three")
	assert_almost_eq(float(sim._water_kw_by_building[sim_id]), 60.0, 0.001)
	# 3. the lateral that joins it to the network
	assert_true(sim.water.edges.has(sim_id + "-LAT"))
	var capacity_before := float(sim.water.inventory()["pump_capacity_m3h"])
	for i in 20:
		sim.advance_hours(1.0)
	assert_eq(String((sim.water.nodes[node_id] as WaterNode).state), "ok",
			"the node comes online when its shell does")
	assert_true(float(sim.water.inventory()["pump_capacity_m3h"]) > capacity_before,
			"and the city's supply actually grew")


func test_place_water_component_reason_codes() -> void:
	var sim := CitySim.boot_from_files()
	assert_eq(sim.cmd_place_water_component("sewer", Vector2i(50, 50), 1, true)["reason_code"],
			&"E_UNKNOWN_COMPONENT")
	assert_eq(sim.cmd_place_water_component("pump", Vector2i(50, 50), 4, true)["reason_code"],
			&"E_LEVEL_UNAVAILABLE")
	assert_eq(sim.cmd_place_water_component("pump", Vector2i(-1, 0), 1, true)["reason_code"],
			&"E_OUT_OF_BOUNDS")
	assert_eq(sim.cmd_place_water_component("pump", Vector2i(20, 20), 1, true)["reason_code"],
			&"E_NOT_OWNED")
	sim.treasury.balance = 500_000
	# A river intake has to touch the river, and most of the core does not.
	var dry := _water_site(sim, Vector2i(2, 2))
	assert_true(dry.x >= 0)
	assert_eq(sim.cmd_place_water_component("source", dry, 1, true)["reason_code"],
			&"E_NO_WATER")
	# Far from any main is E_NO_MAIN.
	var far := Vector2i(-1, -1)
	for z in range(CORE_LO, CORE_HI):
		for x in range(CORE_LO, CORE_HI):
			var t := Vector2i(x, z)
			if sim.world.grid.can_place(t, Vector2i(3, 3)) \
					and sim.water.nearest_main_tile(t, 8).is_empty():
				far = t
				break
		if far.x >= 0:
			break
	if far.x >= 0:
		assert_eq(sim.cmd_place_water_component("pump", far, 1, true)["reason_code"],
				&"E_NO_MAIN")
	# Money is the last gate.
	var site := _water_site(sim, Vector2i(3, 3))
	sim.treasury.balance = 10
	assert_eq(sim.cmd_place_water_component("pump", site, 1)["reason_code"], &"E_FUNDS")
	assert_false(sim.water.nodes.has("P-035-PMP"), "a refusal places nothing")


func test_place_water_main_prices_and_connects() -> void:
	var sim := CitySim.boot_from_files()
	sim.treasury.balance = 500_000
	# Start part-way ALONG `M_TIE` (a vertical main) and run east, so the tap tile
	# is on the network and nothing after it doubles up on another main —
	# `M_TIE`'s own head sits on `M_NORTH`'s crossing, which is an overlap.
	var tie: Array = (sim.water.edges["M_TIE"] as WaterEdge).path
	var seed_tile: Vector2i = tie[tie.size() / 2]
	var run: Array = [seed_tile]
	var cursor: Vector2i = seed_tile
	for i in 3:
		cursor += Vector2i(1, 0)
		run.append(cursor)
	var quote := sim.cmd_place_water_main(run, "service", true)
	assert_true(bool(quote["ok"]), str(quote))
	assert_eq(int(quote["payload"]["cost"]), run.size() * 286, "doc 03 §8 water, service")
	var trunk := sim.cmd_place_water_main(run, "trunk", true)
	assert_eq(int(trunk["payload"]["cost"]), run.size() * 804, "and trunk at 2.81×")
	assert_eq(sim.cmd_place_water_main(run, "arterial", true)["reason_code"],
			&"E_TIER_LOCKED")
	assert_eq(sim.cmd_place_water_main(run, "sewer", true)["reason_code"], &"E_UNKNOWN_TIER")
	assert_eq(sim.cmd_place_water_main([seed_tile], "service", true)["reason_code"],
			&"E_NO_TILES")
	var before: int = sim.treasury.balance
	var placed := sim.cmd_place_water_main(run, "service")
	assert_true(bool(placed["ok"]), str(placed))
	assert_eq(before - sim.treasury.balance, run.size() * 286)
	var main_id := String(placed["payload"]["main"])
	assert_true(sim.water.edges.has(main_id))
	assert_almost_eq((sim.water.edges[main_id] as WaterEdge).capacity_m3h, 53.5, 0.01)
	# A run that touches nothing is refused.
	var orphan: Array = [Vector2i(100, 100), Vector2i(101, 100)]
	assert_false(bool(sim.cmd_place_water_main(orphan, "service", true)["ok"]))


func test_upgrade_water_component() -> void:
	var sim := CitySim.boot_from_files()
	sim.treasury.balance = 2_000_000
	assert_eq(sim.cmd_upgrade_water_component("NO-SUCH", true)["reason_code"],
			&"E_UNKNOWN_NODE")
	# A junction has no level.
	var junction := ""
	for node_id in sim.water.nodes:
		if (sim.water.nodes[node_id] as WaterNode).variant == &"junction":
			junction = String(node_id)
			break
	assert_ne(junction, "")
	assert_eq(sim.cmd_upgrade_water_component(junction, true)["reason_code"],
			&"E_NOT_UPGRADEABLE")
	# The authored tank: doc 03 §2.3's upgrade_cost on the water_plant anchor,
	# scaled by doc 05's tank ratio 1.33.
	var expected := sim.econ_curves.water_component_upgrade_cost(
			sim.water.data.variant_cost_ratio(&"tank"), 1)
	# **The follow, asserted as a follow** (doc 93 §Y7a). `UPG_COEFF` 1.45 → 1.15
	# moved the anchor step 65,250 → 51,750, and doc 05 owns the RATIO, not the
	# price, so the component ladder came with it: 86,783 → 68,828, which is
	# exactly 1.15/1.45 = 79.31 % of what it was. Pinning it instead would have
	# authored a second upgrade curve — a second currency authority in the one
	# place C-07 names by hand.
	assert_eq(expected, CostCurves.round_half_up(51750.0 * 1.33),
			"upgrade_cost_by_step[0] for water_plant is $51,750 (doc 93 §Y7)")
	assert_eq(expected, 68828, "and the tank's own step is the ratio of it")
	var quote := sim.cmd_upgrade_water_component("WTR-2", true)
	assert_true(bool(quote["ok"]), str(quote))
	assert_eq(int(quote["payload"]["cost"]), expected)
	var before: int = sim.treasury.balance
	assert_true(bool(sim.cmd_upgrade_water_component("WTR-2")["ok"]))
	assert_eq(before - sim.treasury.balance, expected)
	assert_eq((sim.water.nodes["WTR-2"] as WaterNode).level, 2)
	assert_almost_eq(float(sim._water_kw_by_building["WTR-2"]), 12.0, 0.001,
			"doc 05 §8's L2 tank kW, re-derived from the live node")


func test_water_component_demolition_retires_its_node() -> void:
	var sim := CitySim.boot_from_files()
	sim.treasury.balance = 500_000
	var site := _water_site(sim, Vector2i(3, 3))
	var placed := sim.cmd_place_water_component("pump", site)
	var sim_id := String(placed["payload"]["sim_id"])
	var node_id := String(placed["payload"]["node"])
	for i in 20:
		sim.advance_hours(1.0)
	assert_true(sim.water.nodes.has(node_id))
	assert_true(bool(sim.cmd_demolish_building(sim_id)["ok"]))
	assert_false(sim.water.nodes.has(node_id), "the node goes with its shell")
	assert_false(sim.water.edges.has(sim_id + "-LAT"), "and so does its own lateral")
	assert_false(sim._water_kw_by_building.has(sim_id))


func test_isolate_and_restore_a_main() -> void:
	var sim := CitySim.boot_from_files()
	var isolated := sim.cmd_isolate_water_main("M_TIE")
	assert_true(bool(isolated["ok"]), str(isolated))
	assert_eq(String((sim.water.edges["M_TIE"] as WaterEdge).state), "isolated")
	assert_true(bool(sim.cmd_restore_water_main("M_TIE")["ok"]))
	assert_eq(String((sim.water.edges["M_TIE"] as WaterEdge).state), "ok")
	assert_eq(sim.cmd_restore_water_main("M_TIE")["reason_code"], &"E_NOT_ISOLATED")
	assert_eq(sim.cmd_isolate_water_main("NOPE")["reason_code"], &"E_UNKNOWN_MAIN")


# ================================================= doc 92 F-7 min_city_level

func test_placement_enforces_min_city_level() -> void:
	# Pass-1 F-7, ruled in Wave 5. `data/buildings.json` gives apartment L1
	# `min_city_level` 1, and the command now says so rather than leaving the
	# rule to the build sheet's lock glyph.
	var sim := CitySim.boot_from_files()
	assert_eq(sim.progression.city_level, 0)
	assert_eq(int(sim.catalog.stats("apartment", 1).get("min_city_level", 0)), 1)
	var lot := _serviceable_lot(sim, Vector2i(2, 2))
	assert_true(lot.x >= 0)
	var refused := sim.cmd_place_building("apartment", lot)
	assert_false(bool(refused["ok"]))
	assert_eq(refused["reason_code"], &"E_CITY_LEVEL")
	assert_eq(int(refused["payload"]["required_level"]), 1)
	assert_eq(int(refused["payload"]["city_level"]), 0)
	# Nothing was charged and nothing was stamped.
	assert_true(sim.world.grid.can_place(lot, Vector2i(2, 2)))
	# The level-0 roster still builds.
	assert_true(bool(sim.cmd_place_building("house", _serviceable_lot(sim))["ok"]))
	# And the gate is checked BEFORE the money, so a broke city gets the honest
	# reason rather than E_FUNDS.
	sim.treasury.balance = 0
	assert_eq(sim.cmd_place_building("apartment", lot)["reason_code"], &"E_CITY_LEVEL")


# ================================================== determinism & persistence

func test_infra_verbs_are_deterministic() -> void:
	var hashes: Array[String] = []
	for run in 2:
		var sim := CitySim.boot_from_files(4242)
		sim.treasury.balance = 500_000
		var tile := _road_ready_tile(sim)
		sim.cmd_place_road([tile], TileGrid.ROAD_STREET)
		var site := _water_site(sim, Vector2i(3, 3))
		sim.cmd_place_water_component("pump", site)
		for i in 24:
			sim.advance_hours(1.0)
		hashes.append(sim.state_hash())
	assert_eq(hashes[0], hashes[1], "same seed, same commands, same state")


func test_infra_verbs_survive_a_save_mid_job() -> void:
	# Constitution §5 / M1 criterion 8: save → load → advance must be EXACT,
	# with a road job and a water shell both still under construction.
	var sim := CitySim.boot_from_files(4242)
	sim.treasury.balance = 500_000
	var tile := _road_ready_tile(sim)
	assert_true(bool(sim.cmd_place_road([tile], TileGrid.ROAD_STREET)["ok"]))
	var site := _water_site(sim, Vector2i(3, 3))
	var placed := sim.cmd_place_water_component("pump", site)
	assert_true(bool(placed["ok"]))
	sim.advance_hours(3.0)
	var saved := sim.canonical_capture()
	var reloaded := CitySim.boot_from_files(4242)
	reloaded.restore_state(saved.duplicate(true))
	assert_eq(reloaded.state_hash(), sim.state_hash(), "the load lands on the save")
	for i in 24:
		sim.advance_hours(1.0)
		reloaded.advance_hours(1.0)
	assert_eq(reloaded.state_hash(), sim.state_hash(),
			"and stays there for a game-day of live stepping")
	# The jobs really did finish on both sides.
	assert_almost_eq(reloaded.roads.condition_of(tile), 1.0, 0.05)
	assert_eq(String((reloaded.water.nodes[String(placed["payload"]["node"])]
			as WaterNode).state), "ok")


func test_stamped_block_survives_a_save() -> void:
	var sim := CitySim.boot_from_files(4242)
	sim.treasury.balance = 5_000_000
	assert_true(bool(sim.cmd_buy_block("B_3_1")["ok"]))
	assert_true(_advance_to_ready(sim, "B_3_1") > 0)
	var counts := sim.roads.road_tile_counts()
	var saved := sim.canonical_capture()
	var reloaded := CitySim.boot_from_files(4242)
	reloaded.restore_state(saved.duplicate(true))
	assert_eq(reloaded.roads.road_tile_counts(), counts, "the stamp is persisted")
	assert_eq(reloaded.state_hash(), sim.state_hash())
	for i in 12:
		sim.advance_coarse_hours(1, false)
		reloaded.advance_coarse_hours(1, false)
	assert_eq(reloaded.state_hash(), sim.state_hash())


# ==================================================== the graph under an edit

func test_an_edited_graph_matches_a_rebuild_from_tiles() -> void:
	# Doc 10 §2.5's incremental retrace must land where `rebuild_all()` lands —
	# otherwise routing is wrong on the live city and a save disagrees with the
	# city that loads it. Two bugs made it not: the free list could hand a
	# recycled id to an unrelated key before its own key claimed it, and the
	# `REBUILD_TILE_BUDGET` carry had no pump.
	var sim := CitySim.boot_from_files()
	sim.treasury.balance = 500_000
	var run: Array = []
	for z in range(48, 64):
		for x in range(48, 64):
			if run.size() >= 24:
				break
			if sim.world.grid.can_place(Vector2i(x, z), Vector2i.ONE):
				run.append(Vector2i(x, z))
	assert_eq(run.size(), 24)
	assert_true(bool(sim.cmd_place_road(run, TileGrid.ROAD_STREET)["ok"]))
	assert_false(sim.roads.graph.graph_dirty, "a command drains its own retrace")
	var incremental: Dictionary = {}
	for edge_id in sim.roads.graph.edge_ids_sorted():
		incremental[String(sim.roads.graph.edge(edge_id)["key"])] = edge_id
	sim.roads.graph.rebuild_all()
	var rebuilt: Dictionary = {}
	for edge_id in sim.roads.graph.edge_ids_sorted():
		rebuilt[String(sim.roads.graph.edge(edge_id)["key"])] = edge_id
	assert_eq(incremental.size(), rebuilt.size(), "same edge count")
	var missing := 0
	for key in rebuilt:
		if not incremental.has(key):
			missing += 1
	assert_eq(missing, 0, "and the same edges, tile for tile")
