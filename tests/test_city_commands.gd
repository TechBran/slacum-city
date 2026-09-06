extends SimTest
## The player command layer (doc 02 §2.11/§2.12 through CitySim): placement
## validation + charging, construction completion, and the upgrade gate —
## with the starter city's own "grid stops the skyline" case.


## A buildable, vacant, power-serviceable site inside the core, big enough for
## `archetype`'s LOT (doc 02 §2.3a, Wave 29). It used to look for a 1×1 hole and
## hand it to `cmd_place_building("store", …)`, which now reserves 2×2 — so the
## helper found sites the command refused, and the failure read as a placement
## bug rather than as two functions disagreeing about how big a store is.
static func _serviceable_vacant_tile(sim: CitySim,
		archetype: String = "store") -> Vector2i:
	var size := sim.lot_for(archetype)
	for z in range(32, 80):
		for x in range(32, 80):
			var origin := Vector2i(x, z)
			if sim.world.grid.can_place(origin, size) and sim.grid.would_serve(origin):
				return origin
	return Vector2i(-1, -1)


func test_tutorial_lot_is_just_out_of_service() -> void:
	# tutorial_lot_a sits 4 tiles from an L1 transformer (radius 3): placement
	# is blocked UNSERVED per doc 04 §2.1 — the tutorial's "connect power"
	# beat exists precisely because of this.
	var sim := CitySim.boot_from_files()
	var lot := sim.loader.resolve_tag("tutorial_lot_a")
	assert_eq(sim.cmd_place_building("house", lot["tile_global"])["reason_code"], &"E_UNSERVED")


func test_place_house_full_lifecycle() -> void:
	var sim := CitySim.boot_from_files()
	var origin := _serviceable_vacant_tile(sim)
	assert_true(origin.x >= 0, "core has serviceable vacant lots")
	var start_balance: int = sim.treasury.balance
	var placed := sim.cmd_place_building("house", origin)
	assert_true(bool(placed["ok"]), str(placed))
	var cost := int(placed["payload"]["cost"])
	assert_eq(cost, 1200, "doc 03: house build_cost_l1")
	assert_eq(sim.treasury.balance, start_balance - cost)
	var sim_id := String(placed["payload"]["sim_id"])
	var b: Building = sim.buildings[sim_id]
	assert_eq(b.state, &"under_construction")
	assert_eq(sim.buildings.size(), 35)
	# Tiles reserved: a second placement on the same spot fails.
	assert_eq(sim.cmd_place_building("house", origin)["reason_code"], &"E_FOOTPRINT")
	# Construction completes (2 crew-hours at ≥0.6 rate → well under 6 gh).
	sim.advance_hours(6.0)
	assert_eq(b.state, &"active")
	assert_eq(b.level, 1)
	# doc 02 §2.6 wear is live (doc 92 F-2): the house completes at 1.00 and has
	# been standing (and wearing, at 0.00045/gh) for the rest of the six hours.
	assert_almost_eq(b.condition, 1.0, 6.0 * 0.00045)
	# The new building draws power and houses people.
	assert_eq(sim.grid.attachment_of(sim_id) != "", true, "attached to a transformer")
	sim.advance_hours(1.0)
	assert_true(sim.population.city_population > 144, "the city grew")


func test_place_rejections() -> void:
	var sim := CitySim.boot_from_files()
	# Undeveloped ring block.
	assert_eq(sim.cmd_place_building("house", Vector2i(8, 8))["reason_code"], &"E_NOT_OWNED")
	# Unknown archetype.
	assert_eq(sim.cmd_place_building("stadium", Vector2i(40, 40))["reason_code"],
			&"E_UNKNOWN_ARCHETYPE")
	# Insufficient funds.
	sim.treasury.spend(sim.treasury.balance - 100, &"misc")
	assert_eq(sim.cmd_place_building("house", _serviceable_vacant_tile(sim))["reason_code"],
			&"E_FUNDS")


func test_upgrade_house_passes_the_gate() -> void:
	var sim := CitySim.boot_from_files()
	sim.advance_hours(1.0)
	sim.progression.city_level = 1  # L2 unlocks at 250 residents by design
	var preview := sim.cmd_upgrade_building("H-001", true)
	assert_true(bool(preview["ok"]), str(preview))
	assert_eq((preview["payload"]["blockers"] as Array).size(), 0)
	var start_balance: int = sim.treasury.balance
	var upgraded := sim.cmd_upgrade_building("H-001")
	assert_true(bool(upgraded["ok"]))
	assert_eq(int(upgraded["payload"]["to_level"]), 2)
	assert_true(sim.treasury.balance < start_balance)
	var b: Building = sim.buildings["H-001"]
	assert_true(b.is_upgrade_in_progress())
	sim.advance_hours(8.0)
	assert_eq(b.level, 2)
	assert_eq(b.state, &"active")
	assert_almost_eq(float(b.stats.get("power_demand_kw", 0.0)), 7.0, 0.11,
			"L2 stats swapped in (3 × 2.35 rounded)")


func test_upgrade_apartment_blocked_by_the_grid() -> void:
	# Doc 02 E2, the signature gate, on real starter data. The authored city
	# is properly engineered — apartments sit on L2 transformers (150 kW), so
	# L1→L2 passes. It is L2→L3 (+76 kW, needing 87.4 kW of headroom) that
	# the transformer cannot carry: the wallet says yes, the grid says no.
	var sim := CitySim.boot_from_files()
	sim.advance_hours(1.0)
	sim.progression.city_level = 2
	sim.treasury.credit(100_000, &"test_grant")
	var first := sim.cmd_upgrade_building("APT-001")
	assert_true(bool(first["ok"]), "L1→L2 fits the L2 transformer")
	sim.advance_hours(12.0)
	assert_eq((sim.buildings["APT-001"] as Building).level, 2)
	sim.advance_hours(13.0)  # reach the evening peak so the load is honest
	var preview := sim.cmd_upgrade_building("APT-001", true)
	assert_false(bool(preview["ok"]))
	assert_eq(preview["reason_code"], &"E_POWER_HEADROOM")
	assert_true(float(preview["payload"]["deficit_kw"]) > 0.0,
			"the UI shows the exact kW shortfall")
	# And the treasury is never touched by a failed upgrade.
	var balance: int = sim.treasury.balance
	sim.cmd_upgrade_building("APT-001")
	assert_eq(sim.treasury.balance, balance)


func test_upgrade_precondition_order() -> void:
	var sim := CitySim.boot_from_files()
	sim.progression.city_level = 1
	var b: Building = sim.buildings["H-002"]
	b.condition = 0.40
	var preview := sim.cmd_upgrade_building("H-002", true)
	assert_false(bool(preview["ok"]))
	assert_true((preview["payload"]["blockers"] as Array).has(&"E_CONDITION"))
	b.condition = 1.0
	b.state = &"damaged"
	assert_eq(sim.cmd_upgrade_building("H-002", true)["reason_code"], &"E_STATE")


func test_avenue_gate_for_tall_levels() -> void:
	# L4+ requires an AVENUE within 4 tiles (report 98 C-62). Verify against
	# the geometric truth of the building's own surroundings.
	var sim := CitySim.boot_from_files()
	sim.advance_hours(1.0)
	sim.progression.city_level = 5
	var b: Building = sim.buildings["H-001"]
	b.level = 3
	b.stats = sim.catalog.stats("house", 3)
	var has_avenue := false
	for z in range(b.origin.y - 4, b.origin.y + 5):
		for x in range(b.origin.x - 4, b.origin.x + 5):
			if TileGrid.in_bounds(x, z) \
					and sim.world.grid.road_class_at(x, z) == TileGrid.ROAD_AVENUE:
				has_avenue = true
	var preview := sim.cmd_upgrade_building("H-001", true)
	var blocked_by_avenue: bool = false
	if not bool(preview["ok"]):
		blocked_by_avenue = (preview["payload"]["blockers"] as Array).has(&"E_AVENUE")
	assert_eq(blocked_by_avenue, not has_avenue,
			"E_AVENUE fires exactly when no avenue is in reach")


func test_placement_survives_save_roundtrip() -> void:
	var sim := CitySim.boot_from_files(777)
	var placed := sim.cmd_place_building("store", _serviceable_vacant_tile(sim))
	assert_true(bool(placed["ok"]))
	sim.advance_hours(2.0)
	var body := sim.canonical_capture()
	var restored := CitySim.boot_from_files(777)
	restored.restore_state(body)
	sim.advance_hours(6.0)
	restored.advance_hours(6.0)
	assert_eq(sim.state_hash(), restored.state_hash(),
			"placed buildings persist and stay deterministic")
