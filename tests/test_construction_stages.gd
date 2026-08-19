extends SimTest
## Construction stage pulses (doc 11 §5 event table): a site under build or
## upgrade walks six visual stages and the renderer swaps its crane/site loop
## on each `building_construction_stage`. The sim owes exactly one event per
## stage change — no repeats, no skips, and nothing left behind when the job
## finishes. The tracking is DERIVED state: it stays out of the save.


static func _serviceable_vacant_tile(sim: CitySim) -> Vector2i:
	# A buildable, vacant, power-serviceable 1×1 lot inside the core.
	for z in range(32, 80):
		for x in range(32, 80):
			var origin := Vector2i(x, z)
			if sim.world.grid.can_place(origin, Vector2i.ONE) and sim.grid.would_serve(origin):
				return origin
	return Vector2i(-1, -1)


## Drain the bus and keep the stage pulses belonging to one building.
static func _drain_stages(sim: CitySim, sim_id: String) -> Array:
	var out: Array = []
	for event in sim.bus.drain():
		if event["type"] == &"building_construction_stage" \
				and String(event["sim_id"]) == sim_id:
			out.append(event)
	return out


static func _stage_numbers(events: Array) -> Array:
	var out: Array = []
	for event in events:
		out.append(int(event["stage"]))
	return out


## Step in fractional hours, accumulating one building's pulses.
static func _run_stages(sim: CitySim, sim_id: String, steps: int, hours: float) -> Array:
	var out: Array = []
	for _i in range(steps):
		sim.advance_hours(hours)
		out.append_array(_drain_stages(sim, sim_id))
	return out


func test_placed_house_walks_all_six_stages() -> void:
	var sim := CitySim.boot_from_files()
	var origin := _serviceable_vacant_tile(sim)
	assert_true(origin.x >= 0, "core has serviceable vacant lots")
	var placed := sim.cmd_place_building("house", origin)
	assert_true(bool(placed["ok"]), str(placed))
	var sim_id := String(placed["payload"]["sim_id"])
	var b: Building = sim.buildings[sim_id]
	sim.bus.drain()
	# 60 × 0.1 gh = 6 gh; a 2 crew-hour house finishes well inside that.
	var pulses := _run_stages(sim, sim_id, 60, 0.1)
	assert_eq(_stage_numbers(pulses), [1, 2, 3, 4, 5, 6],
			"one pulse per stage, in order, no repeats")
	for event in pulses:
		assert_eq(int(event["building"]), b.id, "carries the render id, not the sim id")
	assert_eq(b.state, &"active", "the site finished building")
	# Nothing pulses once the job is gone, and no stale tracking survives it.
	assert_true(sim._last_construction_stage.is_empty(), "the completed job dropped its entry")
	assert_eq(_run_stages(sim, sim_id, 10, 0.1).size(), 0, "a finished site is silent")


func test_upgrade_restarts_the_stage_walk() -> void:
	# The walk belongs to the JOB, not to the building's lifetime: an upgrade
	# on an already-built house starts again at stage 1.
	var sim := CitySim.boot_from_files()
	sim.progression.city_level = 1  # house L2 needs city level 1
	sim.advance_hours(1.0)
	var upgraded := sim.cmd_upgrade_building("H-001")
	assert_true(bool(upgraded["ok"]), str(upgraded))
	sim.bus.drain()
	var pulses := _run_stages(sim, "H-001", 60, 0.1)
	assert_eq(_stage_numbers(pulses), [1, 2, 3, 4, 5, 6], "the upgrade walks its own six")
	var b: Building = sim.buildings["H-001"]
	assert_eq(b.level, 2)
	for event in pulses:
		assert_eq(int(event["building"]), b.id)
	assert_true(sim._last_construction_stage.is_empty(), "no residue after the upgrade")


func test_two_sites_pulse_independently() -> void:
	var sim := CitySim.boot_from_files()
	var first := sim.cmd_place_building("house", _serviceable_vacant_tile(sim))
	var second := sim.cmd_place_building("store", _serviceable_vacant_tile(sim))
	assert_true(bool(first["ok"]) and bool(second["ok"]), str(second))
	var house_id := String(first["payload"]["sim_id"])
	var store_id := String(second["payload"]["sim_id"])
	sim.bus.drain()
	var house: Array = []
	var store: Array = []
	for _i in range(80):
		sim.advance_hours(0.1)
		for event in sim.bus.drain():
			if event["type"] != &"building_construction_stage":
				continue
			var id := String(event["sim_id"])
			if id == house_id:
				house.append(int(event["stage"]))
			elif id == store_id:
				store.append(int(event["stage"]))
			else:
				assert_true(false, "unexpected site pulsed: " + id)
	assert_eq(house, [1, 2, 3, 4, 5, 6], "the house keeps its own stage cursor")
	assert_eq(store, [1, 2, 3, 4, 5, 6], "and so does the slower store")


func test_stage_tracking_is_derived_never_saved() -> void:
	var sim := CitySim.boot_from_files(777)
	assert_true(bool(sim.cmd_place_building("store", _serviceable_vacant_tile(sim))["ok"]))
	sim.advance_hours(1.0)
	assert_false(sim._last_construction_stage.is_empty(), "a live site is being tracked")
	var before := sim.state_hash()
	# Poisoning the derived dict cannot move the canonical state one bit.
	sim._last_construction_stage["NOT-A-BUILDING"] = 99
	sim._last_construction_stage.clear()
	assert_eq(sim.state_hash(), before, "stage tracking sits outside canonical state")
	for key in sim.capture_state():
		assert_false(String(key).contains("stage"), "the save has no stage-tracking section")


func test_stages_survive_save_roundtrip() -> void:
	var sim := CitySim.boot_from_files(777)
	var placed := sim.cmd_place_building("store", _serviceable_vacant_tile(sim))
	assert_true(bool(placed["ok"]))
	var sim_id := String(placed["payload"]["sim_id"])
	sim.advance_hours(2.0)
	var body := sim.canonical_capture()
	var restored := CitySim.boot_from_files(777)
	restored.restore_state(body)
	# A loaded game knows nothing yet, so it re-announces where the site is —
	# the renderer needs the current stage, not the history of getting there.
	restored.bus.drain()
	var resumed := _run_stages(restored, sim_id, 1, 0.05)
	assert_eq(resumed.size(), 1, "the loaded site re-announces its stage exactly once")
	assert_true(int(resumed[0]["stage"]) >= 2, "and resumes mid-walk, not at stage 1")
	# The pulses never perturb the sim: both instances stay bit-identical.
	sim.advance_hours(6.0)
	restored.advance_hours(5.95)
	assert_eq(sim.state_hash(), restored.state_hash(),
			"stage emission leaves determinism untouched")
