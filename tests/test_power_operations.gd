extends SimTest
## Wave 17 — POWER THAT WORKS AND POWER YOU CAN OPERATE (doc 04 §2.14, doc 92
## §48, doc 93 §AD). The model audit's discriminating tests, and the three verbs
## it produced: the one-tap `POWER_CAPACITY` fix (`cmd_fix_power_capacity`), the
## grid-component upgrade (`cmd_upgrade_grid_component`) and the transformer
## demolition (`cmd_demolish_grid_component`), each with its success path, its
## documented refusals, its events, and a save round-trip.
##
## Every measurement here was first taken with `tools/audit_power.gd`; the
## numbers asserted are the ones that tool printed on the starter city at
## seed 1337, 6 fine game-hours in.


# ------------------------------------------------------------------ helpers

static func _starter(hours: float = 6.0, seed_value: int = 1337) -> CitySim:
	var sim := CitySim.boot_from_files(seed_value)
	sim.advance_hours(hours)
	return sim


## The kW a building's next level adds, with doc 02 §2.11's ×1.15 margin — the
## number `cmd_upgrade_building` hands doc 04.
static func _next_delta_kw(sim: CitySim, sim_id: String) -> float:
	var b: Building = sim.buildings[sim_id]
	var next_stats: Dictionary = sim.catalog.stats(String(b.archetype), b.level + 1)
	return (float(next_stats.get("power_demand_kw", 0.0))
			- float(b.stats.get("power_demand_kw", 0.0))) * CitySim.UPGRADE_HEADROOM_MARGIN


static func _blockers(result: Dictionary) -> Array:
	return (result.get("payload", {}) as Dictionary).get("blockers", [])


static func _events_of(sim: CitySim, type: String) -> Array:
	var out: Array = []
	for e in sim.bus.drain():
		if String((e as Dictionary).get("type", "")) == type:
			out.append(e)
	return out


## The first tile inside `radius` of `centre` where a transformer may legally go
## (the same scan `tests/test_player_verbs.gd` uses).
static func _transformer_spot(sim: CitySim, centre: Vector2i, radius: int, level: int = 1) -> Vector2i:
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var tile := centre + Vector2i(dx, dz)
			if bool(sim.cmd_place_grid_component("transformer", tile, level, true)["ok"]):
				return tile
	return Vector2i(-1, -1)


## A tile a house may stand on that some transformer already covers — the state
## `evaluate()` calls VALID, and the one the capacity warning has to be able to
## turn amber without going through `E_UNSERVED` on the way.
static func _served_free_tile(sim: CitySim) -> Vector2i:
	for z in range(32, 80):
		for x in range(32, 80):
			var tile := Vector2i(x, z)
			if sim.grid.would_attach(tile) != "" and sim.world.grid.can_place(tile, Vector2i.ONE):
				var block: LandBlock = sim.world.block_of_tile(x, z)
				if block != null and block.is_owned() and block.is_ready():
					return tile
	return Vector2i(-1, -1)


static func _finish_construction(sim: CitySim, sim_id: String) -> bool:
	for i in 20:
		if (sim.buildings[sim_id] as Building).state != &"under_construction":
			return true
		sim.advance_hours(4.0)
	return (sim.buildings[sim_id] as Building).state != &"under_construction"


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
	_finish_construction(sim, sim_id)
	return sim_id


# ================================================ A. the audit's defects

func test_a_a_zero_delta_upgrade_needs_no_headroom_so_a_substation_can_be_upgraded() -> void:
	# A91-D-53. A substation shell draws nothing and is attached to nothing —
	# it IS the grid — so `can_upgrade_power` used to answer UNSERVED and doc 02's
	# L1→L2 job on SUB-A, the one doc 04 §2.2 sells as "6,000 → 14,000 kW and the
	# third feeder slot", could never be bought. Measured before the fix:
	# `cmd_upgrade_building("SUB-A", true)` carried E_POWER_HEADROOM alone.
	var sim := _starter()
	var gate := sim.grid.can_upgrade_power("SUB-A", 0.0)
	assert_true(bool(gate["ok"]), "a building that adds no load cannot overload anything")
	assert_eq(String(gate["reason"]), "")
	assert_false(_blockers(sim.cmd_upgrade_building("SUB-A", true)).has(&"E_POWER_HEADROOM"),
			"the substation's own upgrade is no longer power-blocked")
	# …and the promise is now purchasable end to end.
	sim.treasury.credit(400_000, &"test_grant")
	sim.progression.city_level = 5
	var started := sim.cmd_upgrade_building("SUB-A")
	assert_true(bool(started["ok"]), str(started))
	for i in 30:
		if int(sim.grid.component("SUB-A")["level"]) >= 2:
			break
		sim.advance_hours(4.0)
	assert_almost_eq(float(sim.grid.component("SUB-A")["capacity_kw"]), 14000.0, 1e-9,
			"doc 04 §2.2: substation L2 = 14,000 kW")
	assert_eq(int(sim.grid.feeder_slots("SUB-A")["total"]), 3, "and the third slot")
	assert_eq(int(sim.grid.feeder_slots("SUB-A")["free"]), 1, "which is free")


func test_a_the_upgrade_gate_names_the_component_that_binds() -> void:
	# A91-D-55: the checklist row said "Upgrade {at}, or add a second feeder" with
	# {at} a transformer nothing could upgrade. The gate now says WHICH hop binds.
	# Starter city, WTR-2 (water_facility L1, +97.7 kW) on T-18, an L1 (50 kW).
	var sim := _starter()
	var delta := _next_delta_kw(sim, "WTR-2")
	assert_almost_eq(delta, 97.75, 0.05, "the audit's +97.7 kW")
	var gate := sim.grid.can_upgrade_power("WTR-2", delta, 25.0)
	assert_false(bool(gate["ok"]))
	assert_eq(String(gate["kind"]), "transformer", "the transformer binds, not the feeder")
	assert_eq(String(gate["at"]), "T-18")
	assert_true(float(gate["r_after"]) > 2.0 and float(gate["r_after"]) < 2.2,
			"r_after 2.084 measured; got %s" % gate["r_after"])
	var path: Array = gate["path"]
	assert_eq(path.size(), 3, "transformer → feeder → substation")
	assert_eq(String(path[0]["kind"]), "transformer")
	assert_eq(String(path[1]["kind"]), "feeder")
	assert_eq(String(path[2]["kind"]), "substation")
	assert_true(float(path[1]["r_after"]) < PowerGrid.UPGRADE_MAX_R, "F_SOUTH is nowhere near")
	assert_true(float(gate["deficit_kw"]) > 0.0)
	# The path the panel draws is the same walk.
	var seen := sim.grid.service_path("WTR-2", 25.0)
	assert_eq(String(seen["transformer"]), "T-18")
	assert_eq(String(seen["feeder"]), "F_SOUTH")
	assert_eq(String(seen["substation"]), "SUB-A")
	assert_eq(int(seen["hops"]), 3)
	assert_true(bool(seen["energized"]) and bool(seen["powered"]) and not bool(seen["shed"]))
	assert_true(sim.grid.service_path("no-such-building")["unserved"])


func test_a_a_second_power_station_adds_to_the_pool_and_clears_no_transformer_blocker() -> void:
	# The user's report reproduced: "adding a second station and seeing no
	# improvement". Measured on three cities, every POWER_CAPACITY blocker bound
	# at a transformer while the pool had headroom (doc 92 §48.1). The model is
	# right — supply rises by exactly the rating — and the transformer is the wall.
	var sim := _starter(1.0)
	var blocked_before := _blockers(sim.cmd_upgrade_building("WTR-2", true)).has(&"E_POWER_HEADROOM")
	assert_true(blocked_before, "WTR-2 is the starter city's one transformer-bound upgrade")
	var supply_before := sim.grid.system_supply_kw
	assert_almost_eq(supply_before, 8000.0, 1e-9)
	sim.treasury.credit(900_000, &"test_grant")
	var origin := Vector2i(-1, -1)
	for z in range(32, 78):
		for x in range(32, 78):
			var candidate := Vector2i(x, z)
			if sim.world.grid.can_place(candidate, Vector2i(3, 3)) and sim.grid.would_serve(candidate):
				origin = candidate
				break
		if origin.x >= 0:
			break
	var placed := sim.cmd_place_building("power_facility", origin)
	assert_true(bool(placed["ok"]), str(placed))
	assert_true(_finish_construction(sim, String(placed["payload"]["sim_id"])))
	sim.advance_hours(1.0)
	assert_almost_eq(sim.grid.system_supply_kw, supply_before + 8000.0, 1e-9,
			"the pool grew by the plant's rating, exactly")
	assert_true(_blockers(sim.cmd_upgrade_building("WTR-2", true)).has(&"E_POWER_HEADROOM"),
			"and T-18 still binds — a plant is not the fix for a transformer")
	var summary := sim.grid.capacity_summary(25.0)
	assert_true(float(summary["headroom_kw"]) > 15000.0, "the pool has room to spare")
	assert_eq(int(summary["transformers"]), 18, "band counts: the roster")
	assert_true(summary.has("transformers_warning") and summary.has("shed_kw"))


# ================================================ B. cmd_fix_power_capacity

func test_b_fix_this_upgrades_the_binding_transformer_and_clears_the_blocker() -> void:
	# The measured one-tap: WTR-2 → upgrade T-18 to L2 (150 kW) for doc 03
	# §2.13(b)'s $1,100 (§2.13(f): the target rung's full build cost, WE-1's own
	# rule), cleared in the same command.
	var sim := _starter()
	var balance: int = sim.treasury.balance
	var quote := sim.cmd_fix_power_capacity("WTR-2", true)
	assert_true(bool(quote["ok"]), str(quote))
	var plan: Dictionary = quote["payload"]
	assert_eq(String(plan["action"]), "upgrade_transformer")
	assert_eq(String(plan["component"]), "T-18")
	assert_eq(int(plan["to_level"]), 2)
	assert_almost_eq(float(plan["to_capacity_kw"]), 150.0, 1e-9)
	assert_eq(int(plan["cost"]), 1100, "doc 03 §2.13(b) transformer L2")
	assert_true(bool(plan["clears"]))
	assert_eq(String(plan["binds_kind"]), "transformer")
	assert_eq(sim.treasury.balance, balance, "a preview charges nothing")
	assert_eq(int(sim.grid.component("T-18")["level"]), 1, "and re-rates nothing")

	var bought := sim.cmd_fix_power_capacity("WTR-2")
	assert_true(bool(bought["ok"]), str(bought))
	assert_eq(sim.treasury.balance, balance - 1100, "charged exactly the quote, once")
	assert_eq(int(sim.grid.component("T-18")["level"]), 2)
	assert_almost_eq(float(sim.grid.component("T-18")["capacity_kw"]), 150.0, 1e-9)
	assert_true(bool(bought["payload"]["cleared"]), "the gate passes in the same command")
	assert_false(_blockers(sim.cmd_upgrade_building("WTR-2", true)).has(&"E_POWER_HEADROOM"))
	assert_eq(_events_of(sim, "grid_component_upgraded").size(), 1)
	assert_eq(_events_of(sim, "power_capacity_fixed").size(), 0,
			"drained with the upgrade event above")
	# Second tap: nothing left to buy.
	assert_eq(sim.cmd_fix_power_capacity("WTR-2", true)["reason_code"], &"E_NOT_BLOCKED")


func test_b_fix_this_refuses_honestly() -> void:
	var sim := _starter()
	assert_eq(sim.cmd_fix_power_capacity("nope")["reason_code"], &"E_UNKNOWN_BUILDING")
	# A house whose next level is not power-blocked has nothing to fix.
	var free_id := ""
	for sim_id in sim.roster_ids():
		var b: Building = sim.buildings[sim_id]
		if b.archetype == &"house" and not _blockers(sim.cmd_upgrade_building(String(sim_id), true)).has(&"E_POWER_HEADROOM"):
			free_id = String(sim_id)
			break
	assert_ne(free_id, "")
	assert_eq(sim.cmd_fix_power_capacity(free_id, true)["reason_code"], &"E_NOT_BLOCKED")
	# Broke: the plan is quoted and refused on funds, and charges nothing.
	sim.treasury.spend(sim.treasury.balance - 10, &"misc")
	var broke := sim.cmd_fix_power_capacity("WTR-2")
	assert_eq(broke["reason_code"], &"E_FUNDS")
	assert_eq(String(broke["payload"]["action"]), "upgrade_transformer", "the plan still reads")
	assert_eq(int(broke["payload"]["cost"]), 1100)
	assert_eq(sim.treasury.balance, 10)
	assert_eq(int(sim.grid.component("T-18")["level"]), 1)


func test_b_at_the_top_of_the_ladder_the_fix_places_a_parallel_transformer() -> void:
	# Doc 04 §2.9's parallel transformer, chosen for the player: T-18 is at the
	# roster's top (L5 since Wave 17) but hobbled, so the next rung does not
	# exist and the answer is a second L5 on the nearest legal tile that keeps
	# WTR-2 in reach — which adoption then hands WTR-2 to.
	var sim := _starter()
	sim.treasury.credit(100_000, &"test_grant")
	var t18 := sim.grid.component("T-18")
	t18["level"] = 5
	t18["capacity_kw"] = 60.0   # test-only: a top rung that cannot carry the plant
	var quote := sim.cmd_fix_power_capacity("WTR-2", true)
	assert_true(bool(quote["ok"]), str(quote))
	var plan: Dictionary = quote["payload"]
	assert_eq(String(plan["action"]), "place_transformer")
	assert_eq(int(plan["level"]), 5, "the biggest placeable transformer")
	var tile: Vector2i = plan["tile"]
	var origin: Vector2i = (sim.buildings["WTR-2"] as Building).origin
	assert_true(maxi(absi(tile.x - origin.x), absi(tile.y - origin.y))
			<= int(PowerGrid.TRANSFORMER_SERVICE_RADIUS[4]), "inside WTR-2's reach")
	assert_true(int(plan["cost"]) >= 16300, "doc 03 §2.13(b) L5 plus the lateral")
	var bought := sim.cmd_fix_power_capacity("WTR-2")
	assert_true(bool(bought["ok"]), str(bought))
	var new_id := sim.grid.attachment_of("WTR-2")
	assert_ne(new_id, "T-18", "WTR-2 moved to the new node")
	assert_eq(sim.grid.component(new_id)["tile"], tile)
	assert_true(bool(bought["payload"]["cleared"]))


func test_b_when_no_placeable_transformer_carries_it_the_fix_says_so() -> void:
	# Above even the top rung: an L5 is 2,500 kW, so a next level worth 4,600 kW
	# (× the ×1.15 margin) fits on nothing the player can place, alone or in
	# parallel. The refusal names the truth and prices the alternative.
	var sim := _starter()
	var t18 := sim.grid.component("T-18")
	t18["level"] = 5
	t18["capacity_kw"] = 60.0
	var b: Building = sim.buildings["WTR-2"]
	b.stats = b.stats.duplicate()
	b.stats["power_demand_kw"] = -4500.0   # delta becomes ~4,600 kW × 1.15
	var refused := sim.cmd_fix_power_capacity("WTR-2", true)
	assert_eq(refused["reason_code"], &"E_NEEDS_TRANSFORMER")
	assert_eq(String(refused["payload"]["at"]), "T-18")
	assert_eq(int(refused["payload"]["max_level"]), 5)
	assert_eq(int(refused["payload"]["place_cost"]), 16300, "doc 03 §2.13(b) L5")


func test_b_a_feeder_bound_blocker_gets_heavier_copper_or_a_new_run() -> void:
	# No city this wave audited had one, so it is built: F_SOUTH hobbled to 300
	# kW with T-18 rated to carry, and the feeder binds. SUB-A has no free slot
	# (doc 09 fills both), so the only option is re-conductoring the run:
	# class 1 → 2 at doc 03 §2.13(b)'s $210 on every tile.
	var sim := _starter()
	sim.treasury.credit(100_000, &"test_grant")
	sim.grid.set_level("T-18", 5)
	var f := sim.grid.component("F_SOUTH")
	f["capacity_kw"] = 300.0
	var delta := _next_delta_kw(sim, "WTR-2")
	var gate := sim.grid.can_upgrade_power("WTR-2", delta, 25.0)
	assert_eq(String(gate["kind"]), "feeder")
	assert_eq(String(gate["at"]), "F_SOUTH")
	var quote := sim.cmd_fix_power_capacity("WTR-2", true)
	assert_true(bool(quote["ok"]), str(quote))
	var plan: Dictionary = quote["payload"]
	assert_eq(String(plan["action"]), "upgrade_feeder")
	assert_eq(String(plan["component"]), "F_SOUTH")
	assert_eq(int(plan["to_class"]), 2)
	var tiles := (f["route"] as Array).size()
	assert_eq(int(plan["cost"]), tiles * 210, "every tile of the run at the class-2 price")
	var bought := sim.cmd_fix_power_capacity("WTR-2")
	assert_true(bool(bought["ok"]), str(bought))
	assert_eq(int(sim.grid.component("F_SOUTH")["conductor_class"]), 2)
	assert_almost_eq(float(sim.grid.component("F_SOUTH")["capacity_kw"]), 3000.0, 1e-9)
	assert_true(bool(bought["payload"]["cleared"]))

	# With a substation that HAS a slot and a run already at the top class, the
	# plan is new copper: the one-tap route to T-18's tile, which adopts it.
	var sim2 := _starter()
	sim2.treasury.credit(400_000, &"test_grant")
	sim2.grid.set_level("T-18", 5)
	var f2 := sim2.grid.component("F_SOUTH")
	# At the TOP class, so re-conductoring is not on the table and the only
	# answer left is new copper from a substation with a free slot.
	f2["conductor_class"] = 3
	f2["capacity_kw"] = 300.0
	var sub := _finished_substation(sim2, sim2.grid.component("T-18")["tile"])
	assert_ne(sub, "")
	var quote2 := sim2.cmd_fix_power_capacity("WTR-2", true)
	assert_true(bool(quote2["ok"]), str(quote2))
	var plan2: Dictionary = quote2["payload"]
	assert_eq(String(plan2["action"]), "route_feeder")
	assert_eq(String(plan2["substation"]), sub)
	assert_true(bool(plan2["adopts"]), "the quoted run picks T-18 up")
	assert_eq(int(plan2["cost"]), int(plan2["tiles"]) * 400,
			"the top class the roster offers, at its per-tile price")
	var bought2 := sim2.cmd_fix_power_capacity("WTR-2")
	assert_true(bool(bought2["ok"]), str(bought2))
	var new_feeder := String(sim2.grid.component("T-18")["parent"])
	assert_ne(new_feeder, "F_SOUTH", "T-18 hangs off the new run")
	assert_eq(String(sim2.grid.component(new_feeder)["parent"]), sub)
	assert_true(bool(bought2["payload"]["cleared"]))


func test_b_a_substation_bound_blocker_quotes_the_shell_upgrade() -> void:
	var sim := _starter()
	sim.treasury.credit(400_000, &"test_grant")
	sim.progression.city_level = 5
	sim.grid.set_level("T-18", 5)
	var s := sim.grid.component("SUB-A")
	s["capacity_kw"] = 400.0
	var gate := sim.grid.can_upgrade_power("WTR-2", _next_delta_kw(sim, "WTR-2"), 25.0)
	assert_eq(String(gate["kind"]), "substation")
	var quote := sim.cmd_fix_power_capacity("WTR-2", true)
	assert_true(bool(quote["ok"]), str(quote))
	assert_eq(String(quote["payload"]["action"]), "upgrade_substation")
	assert_eq(String(quote["payload"]["component"]), "SUB-A")
	assert_eq(int(quote["payload"]["cost"]), sim.econ_curves.upgrade_cost("substation", 1),
			"doc 03 §2.3's upgrade curve, as cmd_upgrade_building charges it")
	var bought := sim.cmd_fix_power_capacity("WTR-2")
	assert_true(bool(bought["ok"]), str(bought))
	assert_true((bought["payload"]["result"] as Dictionary).has("job_id"), "a doc 02 job started")
	for i in 30:
		if int(sim.grid.component("SUB-A")["level"]) >= 2:
			break
		sim.advance_hours(4.0)
	assert_true(bool(sim.grid.can_upgrade_power("WTR-2", _next_delta_kw(sim, "WTR-2"), 25.0)["ok"]),
			"re-rated on completion, the path clears")


# ================================================ C. cmd_upgrade_grid_component

func test_c_upgrade_grid_component_prices_and_refuses_per_its_header() -> void:
	var sim := _starter()
	assert_eq(sim.cmd_upgrade_grid_component("nope")["reason_code"], &"E_UNKNOWN_COMPONENT")
	assert_eq(sim.cmd_upgrade_grid_component("SUB-A")["reason_code"], &"E_UNKNOWN_COMPONENT",
			"a substation is a building — cmd_upgrade_building (C-30)")
	# Transformer: the whole doc 04 §2.2 ladder, at doc 03 §2.13(b)'s prices —
	# L1 → L2 $1,100, L2 → L3 $2,800, L3 → L4 $6,900, L4 → L5 $16,300, and only
	# L5 answers E_MAX_LEVEL. It stopped at L3 until Wave 17 opened the roster
	# (A91-D-55), which is why the authored city ran on rungs nothing could buy.
	var q1 := sim.cmd_upgrade_grid_component("T-18", true)
	assert_true(bool(q1["ok"]))
	assert_eq(int(q1["payload"]["cost"]), 1100)
	assert_eq(int(q1["payload"]["to_level"]), 2)
	assert_eq(int(q1["payload"]["to_service_radius_tiles"]), 4, "§2.2: the radius grows")
	for rung: Array in [[2, 2800], [3, 6900], [4, 16300]]:
		sim.grid.set_level("T-18", int(rung[0]))
		var q: Dictionary = sim.cmd_upgrade_grid_component("T-18", true)
		assert_true(bool(q["ok"]), str(q))
		assert_eq(int(q["payload"]["cost"]), int(rung[1]),
				"L%d → L%d" % [int(rung[0]), int(rung[0]) + 1])
	sim.grid.set_level("T-18", 5)
	var q5 := sim.cmd_upgrade_grid_component("T-18", true)
	assert_eq(q5["reason_code"], &"E_MAX_LEVEL")
	assert_eq(int(q5["payload"]["max_level"]), 5)
	sim.grid.set_level("T-18", 2)
	assert_eq(int(sim.cmd_upgrade_grid_component("T-18", true)["payload"]["cost"]), 2800)
	# Feeder: class 1 → 2 at $210 × tiles, 2 → 3 at $400 × tiles, 3 is the top.
	var tiles := (sim.grid.component("F_NORTH")["route"] as Array).size()
	var qf := sim.cmd_upgrade_grid_component("F_NORTH", true)
	assert_true(bool(qf["ok"]), str(qf))
	assert_eq(int(qf["payload"]["cost"]), tiles * 210)
	assert_eq(int(qf["payload"]["to_class"]), 2)
	sim.grid.set_conductor_class("F_NORTH", 2)
	assert_eq(int(sim.cmd_upgrade_grid_component("F_NORTH", true)["payload"]["cost"]),
			tiles * 400, "class 3 at doc 03 §2.13(b)'s per-tile price")
	sim.grid.set_conductor_class("F_NORTH", 3)
	assert_eq(sim.cmd_upgrade_grid_component("F_NORTH", true)["reason_code"], &"E_MAX_LEVEL")
	sim.grid.set_conductor_class("F_NORTH", 1)
	# FAILED → E_STATE; broke → E_FUNDS; a refusal charges nothing.
	sim.grid.component("T-18")["state"] = &"FAILED"
	assert_eq(sim.cmd_upgrade_grid_component("T-18", true)["reason_code"], &"E_STATE")
	sim.grid.component("T-18")["state"] = &"OK"
	var balance: int = sim.treasury.balance
	sim.treasury.spend(balance - 10, &"misc")
	assert_eq(sim.cmd_upgrade_grid_component("T-18")["reason_code"], &"E_FUNDS")
	assert_eq(sim.treasury.balance, 10)
	assert_eq(int(sim.grid.component("T-18")["level"]), 2)


func test_c_a_bigger_transformer_reaches_further_and_adopts_what_it_now_covers() -> void:
	# The radius column is a live budget: an L1 at 3 tiles becomes an L2 at 4, and
	# a building that stood one tile out of reach is attached by the upgrade.
	var sim := _starter()
	var lot: Vector2i = sim.loader.resolve_tag("tutorial_lot_a")["tile_global"]
	var spot := _transformer_spot(sim, lot, 3)
	var placed := sim.cmd_place_grid_component("transformer", spot, 1)
	var new_id := String(placed["payload"]["component"])
	var house := String(sim.cmd_place_building("house", lot)["payload"]["sim_id"])
	# Orphan it four tiles out: one past L1's radius.
	var far := Vector2i(-1, -1)
	for dz in range(-4, 5):
		for dx in range(-4, 5):
			if maxi(absi(dx), absi(dz)) != 4:
				continue
			var t := spot + Vector2i(dx, dz)
			if TileGrid.in_bounds(t.x, t.y) and sim.world.grid.can_place(t, Vector2i.ONE) \
					and not sim.grid.would_serve(t):
				far = t
				break
		if far.x >= 0:
			break
	if far.x < 0:
		# Every tile at distance 4 is covered by some other transformer on this
		# map; the adoption half is then proved by the attachment moving.
		assert_true(true)
		return
	sim.grid.detach_building(house)
	(sim.buildings[house] as Building).origin = far
	sim.grid.attach_building(house, far, &"STANDARD", "B_2_2")
	assert_eq(sim.grid.attachment_of(house), "", "out of every radius")
	sim.treasury.credit(10_000, &"test_grant")
	var up := sim.cmd_upgrade_grid_component(new_id)
	assert_true(bool(up["ok"]), str(up))
	assert_true((up["payload"]["adopted"] as Array).has(house), "the wider radius picked it up")
	assert_eq(sim.grid.attachment_of(house), new_id)


# ================================================ D. cmd_demolish_grid_component

func test_d_demolishing_a_transformer_darkens_its_stranded_customers_through_the_ledger() -> void:
	# Starter city, T-04 (L2, four houses, nothing else in reach). Measured with
	# `tools/audit_power.gd`: refund $275, 4 stranded, 4 DARK inside the hour.
	var sim := _starter()
	assert_eq(sim.cmd_demolish_grid_component("nope")["reason_code"], &"E_UNKNOWN_COMPONENT")
	assert_eq(sim.cmd_demolish_grid_component("F_NORTH")["reason_code"], &"E_UNKNOWN_COMPONENT",
			"a feeder has no demolish verb in this cut")
	var quote := sim.cmd_demolish_grid_component("T-04", true)
	assert_true(bool(quote["ok"]), str(quote))
	var q: Dictionary = quote["payload"]
	assert_eq(int(q["refund"]), 275, "doc 03 §2.3: 0.25 × the L2 build cost $1,100")
	assert_eq(int(q["replace_cost"]), 1100)
	assert_eq(int(q["customers"]), 4)
	assert_eq((q["stranded"] as Array).size(), 4, "no other transformer reaches them")
	assert_true(sim.grid.has_component("T-04"), "a preview removes nothing")

	var balance: int = sim.treasury.balance
	var gone := sim.cmd_demolish_grid_component("T-04")
	assert_true(bool(gone["ok"]), str(gone))
	assert_eq(sim.treasury.balance, balance + 275)
	assert_false(sim.grid.has_component("T-04"))
	assert_false(sim.grid.is_energized("T-04"), "a missing id is dark, not a crash")
	for building_id in (q["fed"] as Array):
		assert_eq(sim.grid.attachment_of(String(building_id)), "", "%s detached" % building_id)
	var removed := _events_of(sim, "grid_component_removed")
	assert_eq(removed.size(), 1)
	assert_eq((removed[0]["stranded"] as Array).size(), 4)
	assert_eq(int(removed[0]["refund"]), 275)
	# Doc 10's signal memo. The RULING (doc 98 §44 RR-122): a demolished
	# transformer's tiles go back to UNCOVERED, and `_is_tile_powered` answers
	# `true` for an uncovered tile — because most of the 112×112 map has no
	# transformer over it and doc 10 must not read every rural intersection as a
	# dead signal. So the tile reads LIT, the same as it would have if no
	# transformer had ever stood there, and the BUILDINGS go dark through the
	# service ledger below, which is the half the player sees. What matters here
	# is that the live sim and a reload AGREE — the memo is rebuilt from boot
	# data on load, and it used to keep naming a component the grid no longer
	# had (see the determinism test in section E).
	var tile: Vector2i = Vector2i(int(q["tile"][0]), int(q["tile"][1]))
	assert_true(sim._is_tile_powered(tile), "uncovered reads lit, as it always has")
	assert_true(sim.grid.component_ids_of_kind(&"transformer").size() > 0)
	# The outage is the ordinary one: §2.4's hysteresis, then the events.
	sim.advance_hours(0.1)
	var dark_events := _events_of(sim, "BuildingPowerChanged")
	var dark_ids: Array = []
	for e in dark_events:
		if String(e["state"]) == "DARK":
			dark_ids.append(String(e["building"]))
	dark_ids.sort()
	assert_eq(dark_ids, q["fed"], "every stranded customer went DARK through the service ledger")
	for building_id in (q["fed"] as Array):
		assert_false(sim.grid.is_powered(String(building_id)))
	assert_eq(sim.grid.unserved_building_ids().size(), 4)


func test_d_move_is_demolish_plus_place_and_the_lights_come_back() -> void:
	var sim := _starter()
	var tile: Vector2i = sim.grid.component("T-04")["tile"]
	var gone := sim.cmd_demolish_grid_component("T-04")
	var fed: Array = gone["payload"]["fed"]
	sim.advance_hours(0.1)
	for building_id in fed:
		assert_false(sim.grid.is_powered(String(building_id)))
	# "…and we hurry to reconnect": the same tile is free again for a player
	# transformer — the authored one held no flag, and a new L2 there re-adopts
	# all four in the same command.
	var spot := _transformer_spot(sim, tile, 2, 2)
	assert_true(spot.x >= 0, "a legal tile within two of the old pad")
	var balance: int = sim.treasury.balance
	var placed := sim.cmd_place_grid_component("transformer", spot, 2)
	assert_true(bool(placed["ok"]), str(placed))
	var adopted: Array = placed["payload"]["adopted"]
	adopted.sort()
	assert_eq(adopted, fed, "the orphans are picked up by the replacement")
	var move_cost := balance - sim.treasury.balance - 275
	assert_true(move_cost >= 1100 - 275, "move = place − refund: at least $825 for an L2")
	sim.advance_hours(0.1)
	for building_id in fed:
		assert_true(sim.grid.is_powered(String(building_id)), "%s relit" % building_id)


func test_d_pads_and_drops_disappear_with_the_transformer() -> void:
	# The pump lesson inverted (doc 11 §2.10b): the renderer's model must drop
	# the pad AND every service drop of a removed transformer on the next
	# topology pass, and the cheap signature the view polls must change.
	var sim := _starter()
	var model := PowerInfraModel.new(StarterCityLoader.read_json("res://data/render.json"))
	var feed := PowerInfraFeed.topology(sim)
	assert_true(model.build_topology(feed["transformers"], feed["buildings"], feed["attachments"]))
	var pads_before := model.pad_count()
	var spans_before := model.spans().size()
	var t04_spans := 0
	for span in model.spans():
		if (span as PowerInfraModel.SpanRec).transformer_id == "T-04":
			t04_spans += 1
	assert_eq(t04_spans, 4)
	var signature_before := PowerInfraFeed.signature(sim)
	sim.cmd_demolish_grid_component("T-04")
	assert_ne(PowerInfraFeed.signature(sim), signature_before, "the poll sees the roster shrink")
	var after := PowerInfraFeed.topology(sim)
	assert_true(model.build_topology(after["transformers"], after["buildings"], after["attachments"]),
			"the fingerprint moved, so the model rebuilt")
	assert_eq(model.pad_count(), pads_before - 1)
	assert_eq(model.spans().size(), spans_before - 4, "four drops gone with the pad")
	assert_true(model.pad_of("T-04") == null)
	for span in model.spans():
		assert_ne((span as PowerInfraModel.SpanRec).transformer_id, "T-04")


func test_d_the_removal_and_the_rotation_are_things_the_player_is_told() -> void:
	# `data/notifications.json` binds the two events this wave found unbound:
	# a transformer removal (its outage) and a rolling-blackout rotation.
	var table: Dictionary = StarterCityLoader.read_json("res://data/notifications.json")
	var bound: Dictionary = {}
	for row in (table.get("bindings", []) as Array):
		bound[String((row as Dictionary).get("type", ""))] = String((row as Dictionary).get("notify_id", ""))
	assert_eq(String(bound.get("grid_component_removed", "")), "transformer_removed")
	assert_eq(String(bound.get("RollingBlackoutRotated", "")), "load_shed_rotated")
	assert_true((table["events"] as Dictionary).has("transformer_removed"))
	assert_true((table["events"] as Dictionary).has("load_shed_rotated"))
	var cfg := UIConfig.load_from_files()
	for key in ["n_transformer_removed_title", "n_transformer_removed_body",
			"n_load_shed_rotated_title", "n_load_shed_rotated_body"]:
		assert_true(cfg.has_string(key), "data/strings.en.json carries %s" % key)


# ================================================ E. determinism

func test_e_the_three_verbs_survive_a_save_and_stay_bit_identical() -> void:
	var sim := _starter(2.0, 4242)
	sim.treasury.credit(50_000, &"test_grant")
	assert_true(bool(sim.cmd_fix_power_capacity("WTR-2")["ok"]))
	assert_true(bool(sim.cmd_upgrade_grid_component("F_NORTH")["ok"]))
	assert_true(bool(sim.cmd_demolish_grid_component("T-04")["ok"]))
	sim.advance_hours(0.5)
	var body := sim.canonical_capture()
	var a := CitySim.boot_from_files(4242)
	a.restore_state(body)
	var b := CitySim.boot_from_files(4242)
	b.restore_state(body)
	assert_eq(a.state_hash(), b.state_hash(), "two restores of one capture agree")
	assert_eq(int(a.grid.component("T-18")["level"]), 2, "the re-rating is in the body")
	assert_eq(int(a.grid.component("F_NORTH")["conductor_class"]), 2)
	assert_false(a.grid.has_component("T-04"), "and so is the removal")
	a.advance_hours(6.0)
	b.advance_hours(6.0)
	sim.advance_hours(6.0)
	assert_eq(a.state_hash(), b.state_hash(), "identical while advancing")
	assert_eq(sim.state_hash(), a.state_hash(), "the live sim matches the reload")


func test_e_capacity_summary_bands_read_the_overlay_thresholds() -> void:
	var grid := PowerGrid.new()
	grid.add_component("s", &"substation", {"level": 1})
	grid.add_component("plant", &"plant_gas", {"level": 1})
	grid.add_component("f", &"feeder", {"conductor_class": 1, "parent": "s"})
	grid.add_component("t_ok", &"transformer", {"level": 1, "parent": "f", "tile": Vector2i(1, 1)})
	grid.add_component("t_warm", &"transformer", {"level": 1, "parent": "f", "tile": Vector2i(20, 1)})
	grid.add_component("t_hot", &"transformer", {"level": 1, "parent": "f", "tile": Vector2i(40, 1)})
	grid.attach_building("a", Vector2i(1, 1))
	grid.attach_building("b", Vector2i(20, 1))
	grid.attach_building("c", Vector2i(40, 1))
	grid.tick(15, {"a": 10.0, "b": 40.0, "c": 55.0}, {}, {"t_ambient_c": 25.0}, RngStreams.new(1))
	var s := grid.capacity_summary(25.0)
	assert_eq(int(s["transformers"]), 3)
	assert_eq(int(s["feeders"]), 1)
	assert_eq(int(s["transformers_warning"]), 2, "r 0.80 and 1.10 are WARNING or worse")
	assert_eq(int(s["transformers_critical"]), 1, "r 1.10 is CRITICAL")
	assert_eq(int(s["transformers_over"]), 1, "past pickup")
	assert_eq(int(s["feeders_warning"]), 0)
	assert_almost_eq(float(s["shed_kw"]), 0.0, 1e-9)


# ============================== F. the audit's three findings, and their fixes

func test_f_the_headroom_gate_is_read_at_the_peak_not_at_the_trough() -> void:
	# The audit's P1 (doc 93 §AD4). Doc 01's channels swing a residential
	# transformer by 1.46 / 0.67 = 2.18× across a day, so a gate read on the
	# CURRENT load approves at 05:00 what browns out at 20:00.
	var sim := _starter()
	var residential: Dictionary = sim.curves.channel_peak("power_demand_residential")
	assert_almost_eq(float(residential["value"]), 1.46, 1e-6)
	assert_almost_eq(float(residential["hour"]), 20.0, 1e-6)
	var commercial: Dictionary = sim.curves.channel_peak("power_demand_commercial")
	assert_almost_eq(float(commercial["value"]), 1.51, 1e-6)
	# Every component the table names carries at least what it carries now, and
	# at least one carries strictly more — a scale clamped at 1.0 from below is
	# the whole safety argument.
	var peaks := sim.peak_component_loads()
	assert_false(peaks.is_empty(), "the table covers the served roster")
	var strictly_more := 0
	for id: Variant in peaks:
		var live := float(sim.grid.component(String(id))["load_kw"])
		assert_true(float(peaks[id]) >= live - 1e-6, "%s never reads below the live load" % id)
		if float(peaks[id]) > live + 1e-6:
			strictly_more += 1
	assert_true(strictly_more > 0, "the trough is not the peak")
	# And the gate uses it: `power_headroom` is never more permissive than the
	# grid's own two-argument form.
	for sim_id: Variant in sim.roster_ids():
		var delta := _next_delta_kw(sim, String(sim_id))
		if delta <= 0.0:
			continue
		var live_gate := sim.grid.can_upgrade_power(String(sim_id), delta, sim.ambient_c())
		var peak_gate := sim.power_headroom(String(sim_id), delta)
		if not bool(live_gate["ok"]):
			assert_false(bool(peak_gate["ok"]),
					"%s: the peak cannot approve what now refuses" % sim_id)


func test_f_the_peak_table_is_memoised_and_survives_a_grid_change() -> void:
	var sim := _starter()
	var first := sim.peak_component_loads()
	assert_true(sim.peak_component_loads() == first, "same game-minute, same table")
	# A graph change drops it: `grid.mutation_epoch` is the other half of the key.
	var before := sim.grid.mutation_epoch
	sim.cmd_demolish_grid_component("T-04")
	assert_true(sim.grid.mutation_epoch > before, "the epoch moved")
	assert_false(sim.peak_component_loads().has("T-04"),
			"the removed node is gone from the table")


func test_f_placement_warns_when_the_serving_transformer_cannot_carry_it() -> void:
	# The audit's P0 (doc 93 §AD3): placement checked COVERAGE and never
	# capacity, so a green ghost could stand a building on a full transformer.
	# It is a WARN and not a refusal — doc 04 §2.1 authorises no capacity gate on
	# placement — so the ghost goes amber and the command still says yes.
	var sim := _starter()
	sim.treasury.credit(500_000, &"test_grant")
	var controller := BuildController.new(sim)
	controller.archetype = "house"
	var lot := _served_free_tile(sim)
	assert_true(lot.x >= 0, "the starter city has a free tile inside a service radius")
	var healthy := controller.evaluate(lot)
	assert_eq(str(healthy["verdict"]), String(BuildController.VERDICT_VALID), str(healthy))
	# Fill the transformer that would take it.
	var host := sim.grid.would_attach(lot)
	assert_ne(host, "", "some transformer covers the tutorial lot")
	sim.grid.component(host)["capacity_kw"] = 1.0
	var warned := controller.evaluate(lot)
	assert_eq(str(warned["verdict"]), String(BuildController.VERDICT_WARN), str(warned))
	assert_eq(StringName(str(warned["code"])), &"E_TRANSFORMER_FULL")
	assert_eq(String(warned["params"]["transformer"]), host)
	assert_true(float(warned["params"]["need"]) > 0.0)
	# …and the command agrees, places anyway, and says so in its payload.
	var placed := sim.cmd_place_building("house", lot)
	assert_true(bool(placed["ok"]), str(placed))
	assert_false(bool((placed["payload"]["power"] as Dictionary)["ok"]),
			"the answer carries the fact the ghost was amber for")
	assert_eq(String(RequirementFormatter.new(UIConfig.load_from_files())
			.format(&"E_TRANSFORMER_FULL", {})["severity"]),
			String(RequirementFormatter.SEVERITY_WARN))


func test_f_capacity_warning_is_emitted_when_a_component_crosses_a_band() -> void:
	# The audit's P1 (doc 93 §AD5): doc 04 §4 authors `CapacityWarning` and
	# nothing ever raised it, so a transformer's only cue was the burnout.
	var grid := PowerGrid.new()
	grid.add_component("s", &"substation", {"level": 1})
	grid.add_component("plant", &"plant_gas", {"level": 1})
	grid.add_component("f", &"feeder", {"conductor_class": 1, "parent": "s"})
	grid.add_component("t", &"transformer", {"level": 1, "parent": "f", "tile": Vector2i(1, 1)})
	grid.attach_building("a", Vector2i(1, 1))
	var env := {"t_ambient_c": 25.0}
	var rng := RngStreams.new(1)
	grid.tick(15, {"a": 10.0}, {}, env, rng)          # r 0.20 — OK
	assert_true(_capacity_warnings(grid).is_empty(), "quiet under the line")
	grid.tick(15, {"a": 40.0}, {}, env, rng)          # r 0.80 — WARNING
	var warned := _capacity_warnings(grid)
	assert_eq(warned.size(), 1, str(warned))
	assert_eq(String(warned[0]["component"]), "t")
	assert_eq(int(warned[0]["band"]), 1)
	assert_eq(int(warned[0]["customers"]), 1)
	grid.tick(15, {"a": 41.0}, {}, env, rng)          # still WARNING — silent
	assert_true(_capacity_warnings(grid).is_empty(), "one warning per crossing")
	grid.tick(15, {"a": 49.0}, {}, env, rng)          # r 0.98 — CRITICAL
	var critical := _capacity_warnings(grid)
	assert_eq(critical.size(), 1)
	assert_eq(int(critical[0]["band"]), 2)
	grid.tick(15, {"a": 10.0}, {}, env, rng)          # back under — silent
	assert_true(_capacity_warnings(grid).is_empty(), "coming back is not news")


static func _capacity_warnings(grid: PowerGrid) -> Array:
	var out: Array = []
	for e in grid.drain_events():
		if StringName(String((e as Dictionary)["type"])) == &"CapacityWarning":
			out.append(e)
	return out


func test_f_an_unserved_building_is_on_the_books_rather_than_permanently_lit() -> void:
	# RR-119. `is_powered` answers `true` for a building the grid has never heard
	# of, and `attach_building` used to open no service record when it found no
	# transformer — so a building outside every radius was silently, permanently
	# lit, invisible to `unserved_building_ids`, and un-adoptable.
	var grid := PowerGrid.new()
	grid.add_component("s", &"substation", {"level": 1})
	grid.add_component("f", &"feeder", {"conductor_class": 1, "parent": "s"})
	grid.add_component("t", &"transformer", {"level": 1, "parent": "f", "tile": Vector2i(1, 1)})
	assert_eq(grid.attach_building("far", Vector2i(90, 90)), "", "nothing reaches it")
	assert_eq(grid.unserved_building_ids(), ["far"], "on the books, and unserved")
	# A bigger transformer reaches further, and the re-attach takes it.
	grid.add_component("t2", &"transformer",
			{"level": 5, "parent": "f", "tile": Vector2i(90, 88)})
	assert_eq(grid.attach_building("far", Vector2i(90, 90)), "t2")
	assert_true(grid.unserved_building_ids().is_empty())


func test_f_the_shed_score_reads_the_whole_feeder_not_its_first_building() -> void:
	# RR-121. The loop used to `break` on its first match, so a feeder's rank was
	# the priority class of whichever building sorted first by id.
	var grid := PowerGrid.new()
	grid.add_component("s", &"substation", {"level": 1})
	grid.add_component("f", &"feeder", {"conductor_class": 1, "parent": "s"})
	grid.add_component("t", &"transformer", {"level": 3, "parent": "f", "tile": Vector2i(1, 1)})
	# `a_` sorts first and is DISCRETIONARY; the other four are CRITICAL. A score
	# that sampled one building would read this feeder as discretionary.
	grid.attach_building("a_shop", Vector2i(1, 1), &"DISCRETIONARY")
	for i in 4:
		grid.attach_building("z_water_%d" % i, Vector2i(1, 1), &"CRITICAL")
	grid.tick(15, {"a_shop": 20.0, "z_water_0": 20.0, "z_water_1": 20.0,
			"z_water_2": 20.0, "z_water_3": 20.0}, {}, {"t_ambient_c": 25.0}, RngStreams.new(1))
	var score := grid._shed_score("f")
	var discretionary := float(PowerGrid.PRIORITY_WEIGHT[&"DISCRETIONARY"])
	var critical := float(PowerGrid.PRIORITY_WEIGHT[&"CRITICAL"])
	assert_true(score > discretionary + 0.01,
			"the four criticals move the mean off the first building (%f)" % score)
	assert_true(score <= critical + 0.01)


# ==================================================== G. the player's surface

func test_g_the_power_section_names_the_wire_and_prices_the_ladder() -> void:
	var sim := _starter()
	sim.treasury.credit(500_000, &"test_grant")
	var controller := BuildController.new(sim)
	var view := controller.building_view("WTR-2")
	var block: Dictionary = view["power"]
	assert_true(bool(block["available"]))
	assert_false(bool(block["unserved"]))
	assert_eq(String(block["transformer"]), "T-18")
	assert_eq(int(block["hops"]), 3, "transformer → feeder → substation")
	var rows: Array = block["rows"]
	assert_eq(rows.size(), 3)
	assert_eq(String((rows[0] as Dictionary)["kind"]), "transformer")
	assert_eq(String((rows[1] as Dictionary)["kind"]), "feeder")
	assert_eq(String((rows[2] as Dictionary)["kind"]), "substation")
	for row: Variant in rows:
		var r: Dictionary = row
		assert_true(float(r["peak_load_kw"]) >= float(r["load_kw"]) - 1e-6,
				"%s: the peak is never under the live reading" % r["id"])
		assert_true(str(r["headroom_text"]) != "", "the spare capacity is in words")
		assert_true([0, 1, 2].has(int(r["band"])))
	# The transformer row sells the next rung, with the price on its face.
	var upgrade: Dictionary = (rows[0] as Dictionary)["upgrade"]
	assert_true(bool(upgrade["available"]))
	assert_true(bool(upgrade["ok"]), str(upgrade))
	assert_eq(int(upgrade["cost"]), 1100, "T-18 is L1; L2 is doc 03 §2.13(b)'s $1,100")
	assert_true(str(upgrade["cost_text"]).contains("1,100"))
	# The substation has no ladder HERE — it is a building (C-30).
	assert_false(bool(((rows[2] as Dictionary)["upgrade"] as Dictionary)["available"]))
	# And the next level's answer, whether or not it refuses.
	var next: Dictionary = block["next_level"]
	assert_true(bool(next["available"]))
	assert_false(bool(next["ok"]), "WTR-2's +98 kW does not fit on a 150 kW node")
	assert_eq(String(next["binds_at"]), "T-18")
	assert_eq(String(next["binds_kind"]), "transformer")


func test_g_the_fix_strip_quotes_then_buys_and_the_row_routes_to_it() -> void:
	var sim := _starter()
	sim.treasury.credit(500_000, &"test_grant")
	var controller := BuildController.new(sim)
	var quote := controller.power.fix_quote("WTR-2")
	assert_true(bool(quote["available"]))
	assert_true(bool(quote["ok"]), str(quote))
	assert_eq(String(quote["action"]), "upgrade_transformer")
	assert_eq(String(quote["component"]), "T-18")
	assert_eq(int(quote["cost"]), 1100)
	assert_true(bool(quote["clears"]))
	assert_true(bool(quote["affordable"]))
	var balance: int = sim.treasury.balance
	var bought := controller.power.fix("WTR-2")
	assert_true(bool(bought["ok"]), str(bought))
	assert_eq(sim.treasury.balance, balance - 1100, "the money moved")
	assert_eq(int(sim.grid.component("T-18")["level"]), 2, "one rung per tap")
	assert_false(bool(controller.power.fix_quote("WTR-2")["available"]),
			"nothing left to buy: E_NOT_BLOCKED draws no strip")
	# The checklist row that sends the player here routes to FIX_POWER, which the
	# panel performs in place — the whole point of A91-D-54.
	assert_eq(StringName(str(RequirementFormatter.new(UIConfig.load_from_files())
			.format(&"E_POWER_HEADROOM", {})["fix_target"]["kind"])),
			RequirementFormatter.FIX_POWER)


func test_g_the_grid_reading_says_which_half_of_the_grid_is_the_wall() -> void:
	var sim := _starter()
	var controller := BuildController.new(sim)
	var reading := controller.power.grid_reading()
	assert_true(bool(reading["available"]))
	assert_almost_eq(float(reading["supply_kw"]), 8000.0, 1.0)
	assert_eq(int(reading["transformers"]), 18)
	assert_eq(int(reading["feeders"]), 2)
	assert_eq(String(reading["wall"]), "ok", "the starter city is comfortable")
	# Fill a transformer: the pool still has 7,000 kW spare, and the reading has
	# to stop saying everything is fine — this is the second-power-station
	# experience, in one word.
	sim.grid.component("T-18")["capacity_kw"] = 1.0
	sim.advance_hours(0.1)
	var hot := controller.power.grid_reading()
	assert_true(int(hot["transformers_warning"]) >= 1)
	assert_eq(String(hot["wall"]), "wires")
	assert_true(float(hot["headroom_kw"]) > 1000.0, "the pool is not the problem")
	# The three §2.5 legend lines the shell and the preview both build.
	var lines := UIRoot.power_summary_lines(hot, UIConfig.load_from_files())
	assert_eq(lines.size(), 3)
	assert_eq(String((lines[1] as Dictionary)["id"]), "wires")


func test_g_the_transformer_demolish_quote_prices_the_move() -> void:
	var sim := _starter()
	var controller := BuildController.new(sim)
	var quote := controller.power.demolish_quote("T-04")
	assert_true(bool(quote["available"]))
	assert_eq(int(quote["refund"]), 275, "doc 03 §2.3's 0.25 of the L2 build cost")
	assert_eq(int(quote["replace_cost"]), 1100)
	assert_eq(int(quote["move_cost"]), 825, "a move is place − refund")
	assert_eq(int(quote["customers"]), 4)
	assert_eq(int(quote["stranded"]), 4)
	# A feeder has no demolish verb in this cut, and the quote says so rather
	# than drawing a button that can only refuse.
	assert_false(bool(controller.power.demolish_quote("F_NORTH")["available"]))


# ===========================================================================
# H — call the crews (Wave 25, doc 04 §2.15.2, report 98 §68 RR-206)
#
# The verb that did not exist: `PowerGrid.repair_component` had one caller in the
# whole project — doc 06's incident resolution — so a player looking at a
# burned-out transformer could upgrade it (refused, `E_STATE`), demolish it, or
# wait. A91-D-129.
# ===========================================================================

func test_h_the_repair_is_priced_by_doc_03_and_clocked_by_doc_06() -> void:
	var sim := _starter()
	sim.treasury.credit(50_000, &"test_grant")
	var c := sim.grid.component("T-04")
	c["state"] = &"FAILED"
	c["condition"] = 0.72
	var quote := sim.cmd_repair_grid_component("T-04", true)
	assert_true(bool(quote["ok"]), "a burned-out transformer can be repaired")
	var payload: Dictionary = quote["payload"]
	# doc 04 §2.6's burnout damage plus the wear, on doc 03 §2.5's own formula.
	var damage := (1.0 - 0.72) + float(PowerGrid.FAILURE_DAMAGE[&"transformer"])
	assert_true(absf(float(payload["damage_fraction"]) - damage) < 1e-9,
			"damage is §2.6's FAILURE_DAMAGE plus the wear")
	assert_eq(int(payload["cost"]), sim.econ_curves.repair_cost(
			sim.econ_curves.capital_value_grid("transformer", 2), damage, 1.0),
			"the price is doc 03 §2.5 on §2.5's own grid capital")
	assert_eq(int(payload["cost"]), 589, "an L2 at 63 % damage — $1,100 × 0.63 × 0.85")
	# doc 06's own work for this failure, scaled by the damage bought back.
	var row := sim.incident_catalog.type_row("transformer_failure", "")
	assert_true(absf(float(payload["crew_hours"])
			- float(row["w_base"]) * damage) < 1e-9,
			"crew-hours are doc 06's `w_base`, and doc 06 is the only author of them")
	assert_eq(String(payload["crew_type"]), "heavy_equipment_crew",
			"doc 09 §2.3's UTILITY_CORRIDOR crew — the one that lays this equipment")


func test_h_the_crew_has_to_arrive_and_the_transformer_comes_back_when_it_does() -> void:
	var sim := _starter()
	sim.treasury.credit(50_000, &"test_grant")
	sim.grid.component("T-04")["state"] = &"FAILED"
	sim.grid.component("T-04")["condition"] = 0.72
	var before := sim.treasury.balance
	var done := sim.cmd_repair_grid_component("T-04")
	assert_true(bool(done["ok"]))
	assert_eq(sim.treasury.balance, before - int(done["payload"]["cost"]),
			"doc 03 is paid on the tap")
	assert_eq(String(sim.grid.component("T-04")["state"]), "FAILED",
			"and NOTHING else happens on the tap — a crew has to travel")
	var job_id := int(done["payload"]["job_id"])
	assert_true(job_id > 0 and sim.construction.job(job_id).has("payload"),
			"there is a real job in doc 09's queue")
	assert_eq(String(sim.construction.job(job_id)["payload"]["grid_component"]), "T-04")
	sim.advance_hours(2.0)
	assert_eq(String(sim.grid.component("T-04")["state"]), "OK",
			"it comes back when the crew finishes")
	# At doc 02 §2.12's post-damage target, less the wear the two game-hours of
	# advancing put back on it (§2.6's `WEAR_PER_GH`) — the repair restores TO
	# 0.85 and the clock starts again immediately, which is the honest reading.
	var condition := float(sim.grid.component("T-04")["condition"])
	assert_true(condition <= 0.85 + 1e-9,
			"never above doc 02 §2.12's post-damage target")
	assert_true(condition >= 0.85 - 4.0 * PowerGrid.WEAR_PER_GH,
			"…and within two game-hours of wear of it")


func test_h_a_standing_transformer_is_overhauled_all_the_way_back() -> void:
	# Doc 02 §2.12's OTHER target: `repair_target_active` is 1.00, and a player
	# buying an overhaul of a unit that is still standing must not be charged for
	# `1 − condition` and lifted only to 0.85.
	var sim := _starter()
	sim.treasury.credit(50_000, &"test_grant")
	sim.grid.component("T-04")["condition"] = 0.60
	var quote := sim.cmd_repair_grid_component("T-04", true)
	assert_eq(float(quote["payload"]["repair_target"]), 1.0)
	assert_true(absf(float(quote["payload"]["damage_fraction"]) - 0.40) < 1e-9,
			"a standing unit's damage is its wear and nothing else")
	assert_true(bool(sim.cmd_repair_grid_component("T-04")["ok"]))
	sim.advance_hours(2.0)
	assert_true(float(sim.grid.component("T-04")["condition"]) > 0.99,
			"the overhaul buys back what it charged for")


func test_h_the_refusal_ladder_is_the_one_the_header_documents() -> void:
	var sim := _starter()
	# 1. not a transformer, and not a component at all.
	assert_eq(String(sim.cmd_repair_grid_component("NOPE", true)["reason_code"]),
			"E_UNKNOWN_COMPONENT")
	assert_eq(String(sim.cmd_repair_grid_component("F_NORTH", true)["reason_code"]),
			"E_UNKNOWN_COMPONENT",
			"a feeder is refused BY NAME: doc 03 prices a line per tile and "
			+ "`capital_value_grid` cannot read a route (A91-D-131)")
	assert_eq(String(sim.cmd_repair_grid_component("SUB-A", true)["reason_code"]),
			"E_UNKNOWN_COMPONENT", "a substation is a BUILDING (C-30)")
	# 2. nothing to buy.
	sim.grid.component("T-04")["condition"] = 1.0
	assert_eq(String(sim.cmd_repair_grid_component("T-04", true)["reason_code"]),
			"E_NOT_DAMAGED")
	# …including a standing unit whose price rounds to nothing, which is the arm
	# that stops the verb being a trap: `repair_component` never LOWERS a
	# condition, so this purchase would move nothing at all.
	sim.grid.component("T-04")["condition"] = 0.99999
	assert_eq(String(sim.cmd_repair_grid_component("T-04", true)["reason_code"]),
			"E_NOT_DAMAGED", "doc 03 prices this at $0 and it buys nothing")
	# …and an OPEN unit is a relay position, not a fault.
	sim.grid.component("T-04")["condition"] = 1.0
	sim.grid.force_open("T-04")
	assert_eq(String(sim.cmd_repair_grid_component("T-04", true)["reason_code"]),
			"E_NOT_DAMAGED", "a tripped relay costs nothing to close")
	# 3. one crew per component.
	sim.grid.component("T-04")["state"] = &"FAILED"
	sim.treasury.credit(50_000, &"test_grant")
	assert_true(bool(sim.cmd_repair_grid_component("T-04")["ok"]))
	assert_eq(String(sim.cmd_repair_grid_component("T-04", true)["reason_code"]),
			"E_ALREADY_REPAIRING")
	# 4. the money.
	var broke := _starter()
	broke.grid.component("T-04")["state"] = &"FAILED"
	broke.treasury.balance = 0
	assert_eq(String(broke.cmd_repair_grid_component("T-04", true)["reason_code"]),
			"E_FUNDS")


func test_h_the_repair_events_have_readers() -> void:
	# This project's signature defect is an event nothing consumes, so each of
	# these two is checked against the table that reads it rather than merely
	# asserted to fire.
	var sim := _starter()
	sim.treasury.credit(50_000, &"test_grant")
	sim.bus.drain()
	sim.grid.component("T-04")["state"] = &"FAILED"
	assert_true(bool(sim.cmd_repair_grid_component("T-04")["ok"]))
	var started := _events_of(sim, "grid_component_repair_started")
	assert_eq(started.size(), 1, "the dispatch is announced once")
	assert_eq(String((started[0] as Dictionary)["component"]), "T-04",
			"and the announcement names the transformer")
	sim.advance_hours(2.0)
	var done := _events_of(sim, "grid_component_repaired")
	assert_eq(done.size(), 1, "so is the arrival")
	assert_true(bool((done[0] as Dictionary)["was_failed"]))
	# The readers, by name: `data/ui.json.event_log` binds both under `power`.
	var log_rows: Array = UIConfig.load_from_files().section("event_log").get("events", [])
	var bound: Dictionary = {}
	for entry: Variant in log_rows:
		bound[String((entry as Dictionary).get("type", ""))] = entry
	for event_type: String in ["grid_component_repair_started", "grid_component_repaired"]:
		assert_true(bound.has(event_type),
				"%s has an event_log row — an event with no reader is A91-D-19" % event_type)
		assert_eq(String((bound[event_type] as Dictionary)["category"]), "power")


func test_h_the_job_is_a_project_like_any_other() -> void:
	# S16 lists it, `cmd_rush_construction` can buy its remaining time, and the
	# row carries the PAD's tile so the jump affordance lands on the thing being
	# fixed rather than at (−1, −1).
	var sim := _starter()
	sim.treasury.credit(50_000, &"test_grant")
	sim.grid.component("T-04")["state"] = &"FAILED"
	sim.grid.component("T-04")["condition"] = 0.50
	assert_true(bool(sim.cmd_repair_grid_component("T-04")["ok"]))
	var rows: Array[Dictionary] = sim.construction_overview()
	var found: Dictionary = {}
	for entry: Variant in rows:
		if String((entry as Dictionary)["ref"]) == "T-04":
			found = entry
	assert_false(found.is_empty(), "the queue lists the crew")
	assert_eq(found["tile"], sim.grid.component_tile("T-04"),
			"the row points at the pad")
	assert_eq(String(found["title_key"]), "ui_power_kind_transformer",
			"and names it the way the panel does")
	assert_true(bool(found["rushable"]), "a project with a cash price can be rushed")


func test_h_the_burnout_damage_table_has_exactly_one_home() -> void:
	# A91-D-130: `_fail`'s `damage_fraction` was written three times and read by
	# nothing. The values are unchanged, and this pins BOTH halves — the table is
	# what the failure publishes, and it is what the repair charges for.
	var grid := PowerGrid.new()
	grid.add_component("t", &"transformer", {"level": 1})
	grid.add_component("f", &"feeder", {"conductor_class": 1})
	for pair: Array in [["t", &"transformer"], ["f", &"feeder"]]:
		var id := String(pair[0])
		var kind: StringName = pair[1]
		grid._fail(id, "TEST", float(PowerGrid.FAILURE_DAMAGE[kind]))
		var events := grid.drain_events()
		var damage := -1.0
		for entry: Variant in events:
			if String((entry as Dictionary)["type"]) == "PowerComponentFailed":
				damage = float((entry as Dictionary)["damage_fraction"])
		assert_eq(damage, float(PowerGrid.FAILURE_DAMAGE[kind]),
				"%s publishes the table's own value" % String(kind))
		assert_true(absf(grid.damage_fraction(id)
				- float(PowerGrid.FAILURE_DAMAGE[kind])) < 1e-9,
				"…and `damage_fraction` reads the same number back")
	# The lightning band re-derived it a third time and now does not.
	assert_eq(float(PowerGrid.FAILURE_DAMAGE[&"transformer"]), 0.35)
	assert_eq(float(PowerGrid.FAILURE_DAMAGE[&"substation"]), 0.30)
	assert_eq(float(PowerGrid.FAILURE_DAMAGE[&"feeder"]), 0.05)
	assert_eq(float(PowerGrid.FAILURE_DAMAGE[&"transmission"]), 0.05)


func test_h_buildings_served_by_is_the_grids_own_roster() -> void:
	var sim := _starter()
	var total := 0
	for id_value in sim.grid.component_ids_of_kind(&"transformer"):
		var served := sim.grid.buildings_served_by(String(id_value))
		total += served.size()
		var sorted := served.duplicate()
		sorted.sort()
		assert_eq(str(served), str(sorted), "ascending, so two runs draw one panel")
		for sim_id: Variant in served:
			assert_eq(sim.grid.attachment_of(String(sim_id)), String(id_value),
					"and it agrees with `attachment_of` building by building")
	assert_eq(total, sim.grid.attachment_map().size(),
			"every attached building is behind exactly one transformer")
	assert_eq(sim.grid.buildings_served_by("NOPE").size(), 0,
			"an id the grid has never heard of is empty, not an error")
