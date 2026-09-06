extends SimTest
## `PowerInfraFeed` — PA-72's missing gate.
##
## This is the **one renderer file that knows what a `CitySim` is**, and
## `grep -rn PowerInfraFeed tests/` returned nothing at the Wave-17 fork. Its
## sibling `PowerInfraModel` has a whole test file (`test_power_infra.gd`)
## precisely because it never sees a sim; the adapter that does see one had none,
## so the two ways it can lie — a topology row built from the wrong record, and a
## change detector that cannot see a change — were unobserved.
##
## `test_power_infra.gd` covers the model against hand-built fixtures. Everything
## here runs against a REAL booted city, because the defects are in the reading.

const CORE_LO := 32
const CORE_HI := 80


func _sim() -> CitySim:
	return CitySim.boot_from_files()


static func _vacant_lot(sim: CitySim, size: Vector2i = Vector2i.ONE) -> Vector2i:
	for z in range(CORE_LO, CORE_HI):
		for x in range(CORE_LO, CORE_HI):
			var t := Vector2i(x, z)
			if sim.world.grid.can_place(t, size) and sim.grid.would_serve(t):
				return t
	return Vector2i(-1, -1)


# ------------------------------------------------------------------- topology

func test_one_row_per_transformer_carrying_its_real_level() -> void:
	# The pad mesh is chosen by `level`; a row that carried the wrong one draws
	# an L1 pad for an L4 transformer and the player reads the wrong capacity off
	# the map.
	var sim := _sim()
	var topology := PowerInfraFeed.topology(sim)
	var rows: Array = topology["transformers"]
	var ids: Array = sim.grid.component_ids_of_kind(&"transformer")
	assert_eq(rows.size(), ids.size(), "one row per transformer, no more, no less")
	assert_eq(rows.size(), 18, "the starter roster (doc 92 F-4 thinned it to 18)")
	for row: Dictionary in rows:
		var id := String(row["id"])
		assert_eq(int(row["level"]), int(sim.grid.component(id).get("level", -1)),
				"%s level" % id)
		assert_eq(row["tile"], sim.grid.component_tile(id), "%s tile" % id)


func test_the_topology_carries_every_building_and_the_attachment_map() -> void:
	var sim := _sim()
	var topology := PowerInfraFeed.topology(sim)
	assert_eq((topology["buildings"] as Dictionary).size(), sim.buildings.size())
	assert_eq(topology["attachments"], sim.grid.attachment_map())
	assert_true((topology["attachments"] as Dictionary).has("APT-001"),
			"an attached building appears in the map it is attached by")


func test_a_building_view_centres_on_its_footprint_not_its_origin() -> void:
	# The same formula the shell wrote by hand three more times (PA-76). APT-001
	# is 2×2 at (40, 33).
	var sim := _sim()
	var view := PowerInfraFeed.building_view(sim, "APT-001")
	assert_almost_eq((view["world_pos"] as Vector3).x, 328.0, 0.001)
	assert_almost_eq((view["world_pos"] as Vector3).z, 272.0, 0.001)
	assert_eq(view["world_pos"],
			TileGrid.centre_of_footprint(Vector2i(40, 33), Vector2i(2, 2)),
			"and it agrees with the geometry authority")
	assert_almost_eq((view["footprint_m"] as Vector2).x, 16.0, 0.001)


func test_an_unknown_building_gives_an_empty_view_rather_than_raising() -> void:
	# **PA-100.** This read `sim._building_records[sim_id]` with `[]`, so an id
	# the renderer knew and the roster did not was an index error inside a
	# `_process` frame — not a blank pad.
	var sim := _sim()
	assert_eq(PowerInfraFeed.building_view(sim, "NOPE-999"), {})
	assert_eq(sim.building_record("NOPE-999"), {},
			"the accessor answers {} where the reach-through raised")


func test_a_building_under_construction_is_clamped_to_the_site_pole() -> void:
	# Doc 11: the drop lands on the hoarding, not forty metres up where the roof
	# will be. The height source is bypassed entirely while the shell is going up.
	var sim := _sim()
	var lot := _vacant_lot(sim)
	assert_true(lot.x >= 0, "the core has a serviceable vacant tile")
	assert_true(bool(sim.cmd_place_building("house", lot)["ok"]))
	var sim_id := ""
	for id: String in sim.buildings:
		if (sim.buildings[id] as Building).state == &"under_construction":
			sim_id = id
			break
	assert_ne(sim_id, "", "a placement starts under construction")
	var tall := func(_a: StringName, _b: int) -> float: return 40.0
	var view := PowerInfraFeed.building_view(sim, sim_id, tall)
	assert_almost_eq(float(view["height_m"]),
			PowerInfraFeed.CONSTRUCTION_SERVICE_HEIGHT_M, 0.001,
			"the height lookup is not consulted while the shell is going up")


func test_the_view_jumps_to_the_finished_height_on_completion() -> void:
	var sim := _sim()
	var lot := _vacant_lot(sim)
	assert_true(bool(sim.cmd_place_building("house", lot)["ok"]))
	var sim_id := ""
	for id: String in sim.buildings:
		if (sim.buildings[id] as Building).state == &"under_construction":
			sim_id = id
			break
	var tall := func(_a: StringName, _b: int) -> float: return 40.0
	var during := float(PowerInfraFeed.building_view(sim, sim_id, tall)["height_m"])
	sim.advance_hours(240.0)
	assert_eq((sim.buildings[sim_id] as Building).state, &"active", "it topped out")
	var after := float(PowerInfraFeed.building_view(sim, sim_id, tall)["height_m"])
	assert_almost_eq(during, PowerInfraFeed.CONSTRUCTION_SERVICE_HEIGHT_M, 0.001)
	assert_almost_eq(after, 40.0, 0.001, "and the drop moves to the eave")


## **The weatherhead lands on the WALL, not on the property line** (Wave 29 fix,
## doc 02 §2.3a). A grower's `record["footprint"]` is its LOT since the lot rule,
## and this feed read it raw: a level-1 store reported world_pos (344, 0, 272)
## and 16×16 m for a mesh that is 8 m wide centred on (340, 0, 268), so
## `PowerInfraModel.service_point` clamped the drop to the lot boundary and
## pushed it out from THERE — a wire ending 4 m clear of the shop, in mid-air
## over its own empty forecourt. The numbers below are that measurement.
func test_a_young_growers_service_drop_lands_on_its_wall_not_its_lot_line() -> void:
	var sim := _sim()
	var origin := Vector2i(42, 33)
	var placed := sim.cmd_place_building("store", origin)
	assert_true(bool(placed["ok"]), "the founding city has room for a store at (42, 33)")
	var sim_id := String((placed["payload"] as Dictionary)["sim_id"])
	var b: Building = sim.buildings[sim_id]
	assert_eq(sim.built_of_building(b), Vector2i(1, 1), "a new store covers one tile…")
	assert_eq(sim.lot_of_building(b), Vector2i(2, 2), "…and holds four")

	var view := PowerInfraFeed.building_view(sim, sim_id)
	assert_eq(view["world_pos"], Vector3(340.0, 0.0, 268.0),
			"the BUILT centre — 42 * 8 + 4, 33 * 8 + 4")
	assert_almost_eq((view["footprint_m"] as Vector2).x, 8.0, 0.001, "8 m of shop")
	assert_almost_eq((view["footprint_m"] as Vector2).y, 8.0, 0.001)
	# The reservation, for contrast: this is the answer the raw record gives, and
	# it is half a tile off in both axes.
	assert_eq(TileGrid.centre_of_footprint(origin, sim.lot_of_building(b)),
			Vector3(344.0, 0.0, 272.0), "the LOT centre, which is NOT where the mesh is")

	# …and the drop that lands on it. Approaching from the east, the east wall is
	# at x = 344 (tile 42's far edge) and the lot line is a whole tile further out
	# at x = 352.
	var model := PowerInfraModel.new()
	var head := model.service_point(view, Vector3(400.0, 0.0, 268.0))
	assert_almost_eq(head.x, 344.0 + model.service_clearance_m, 0.001,
			"the weatherhead stands off the WALL by the authored clearance")
	assert_true(head.x < 352.0,
			"and never out on the lot line, which is where the record's footprint put it")


func test_no_height_lookup_falls_back_rather_than_guessing() -> void:
	var sim := _sim()
	var view := PowerInfraFeed.building_view(sim, "APT-001")
	assert_almost_eq(float(view["height_m"]), PowerInfraFeed.DEFAULT_HEIGHT_M, 0.001)


# ------------------------------------------------------------------ signature

func test_the_signature_moves_when_a_transformer_is_re_rated() -> void:
	# Wave 17's `mutation_epoch` fold. Before it, an upgrade changed no count and
	# the pad kept the old level for up to `topology_poll_s` (5 s).
	var sim := _sim()
	var before := PowerInfraFeed.signature(sim)
	sim.grid.set_level("T-18", 3)
	assert_ne(PowerInfraFeed.signature(sim), before, "a re-rate is a change")


func test_the_signature_moves_when_a_building_finishes_construction() -> void:
	# **PA-72's surviving hole.** The key was already in `sim.buildings` and no
	# component moved, so `mutation_epoch`, the transformer count and the
	# building count were all unchanged — while `building_view` swapped the
	# service height from a 4.10 m pole to the finished eave. A tower topped out
	# and kept its wire pinned to the hoarding.
	var sim := _sim()
	var lot := _vacant_lot(sim)
	assert_true(bool(sim.cmd_place_building("house", lot)["ok"]))
	var roster_before := sim.buildings.size()
	var epoch_before := sim.grid.mutation_epoch
	var signature_before := PowerInfraFeed.signature(sim)
	# Run to completion, then freeze the two terms the OLD signature was made of
	# and prove they did not move.
	sim.advance_hours(240.0)
	assert_eq(sim.buildings.size(), roster_before, "the roster did not change")
	assert_eq(sim.grid.mutation_epoch, epoch_before,
			"and neither did the grid's shape — the OLD signature saw nothing")
	assert_ne(PowerInfraFeed.signature(sim), signature_before,
			"the new one sees the completion")


func test_the_signature_moves_when_a_building_is_placed() -> void:
	var sim := _sim()
	var before := PowerInfraFeed.signature(sim)
	assert_true(bool(sim.cmd_place_building("house", _vacant_lot(sim))["ok"]))
	assert_ne(PowerInfraFeed.signature(sim), before)


func test_the_signature_is_stable_when_nothing_structural_happens() -> void:
	# A detector that moved every hour would rebuild the topology every hour and
	# the poll would be worthless. Advance the clock without touching the roster
	# or the grid and the signature must hold.
	var sim := _sim()
	var before := PowerInfraFeed.signature(sim)
	sim.advance_hours(2.0)
	assert_eq(PowerInfraFeed.signature(sim), before,
			"hours pass; the topology does not")


# -------------------------------------------------------------------- ambient

func test_ambient_is_the_grids_own_ambient() -> void:
	# `main.gd._feed_dashboard_tabs` re-derived this expression with its own
	# literal fallback (PA-38); it now calls here, so the pad that smokes is the
	# pad the Infrastructure tab lists as hottest.
	var sim := _sim()
	assert_almost_eq(PowerInfraFeed.ambient_c(sim),
			float(sim.weather.env_for_grid().get("t_ambient_c", -999.0)), 0.001)


func test_state_rows_are_taken_at_that_ambient() -> void:
	var sim := _sim()
	var rows := PowerInfraFeed.state(sim)
	assert_eq(rows, sim.grid.transformer_rows(PowerInfraFeed.ambient_c(sim)))
	assert_true(rows.size() > 0)


# ---------------------------------------------------------------- hash safety

func test_reading_the_feed_never_moves_the_sim() -> void:
	# Every method here is a READ; that is what keeps the visible power layer
	# hash-neutral by construction rather than by inspection (the file's own
	# class doc). Now asserted rather than claimed.
	var sim := _sim()
	sim.advance_hours(3.0)
	var before := sim.state_hash()
	PowerInfraFeed.topology(sim)
	PowerInfraFeed.state(sim)
	PowerInfraFeed.signature(sim)
	PowerInfraFeed.building_view(sim, "APT-001")
	PowerInfraFeed.ambient_c(sim)
	assert_eq(sim.state_hash(), before)
