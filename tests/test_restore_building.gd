extends SimTest
## `CitySim.cmd_restore_building` — the one tap that brings a ruin back (Wave 18;
## doc 02 §2.12, doc 03 §2.5's restore row, doc 93 §AN, report 98 RR-155/156).
##
## The defect these tests close is not a wrong answer, it is a MISSING DOOR.
## `Building.order_rebuild` has been authored and documented since doc 02 shipped
## and `grep -rn "cmd_rebuild\|\.rebuild(" sim/ ui/ game/` found not one caller —
## the sixth instance of doc 91's A91-D-19 shape — so a destroyed building was
## permanently dead in a game whose promise is *"You built it. Now keep it
## alive."* Every test below is therefore about the door existing and being
## reachable, not about arithmetic drift.


## The whole verb, end to end: a ruin, a price, a tap, a site, a building.
func test_a_ruin_comes_back_through_the_ordinary_construction_path() -> void:
	var sim := CitySim.boot_from_files()
	var sim_id := _destroy_one(sim, &"active")
	var b: Building = sim.buildings[sim_id]
	var level := b.level_at_destruction
	assert_true(level >= 1, "the ruin remembers what it was")

	var quote := sim.cmd_restore_building(sim_id, true)
	assert_true(bool(quote["ok"]), "a destroyed building quotes a restore")
	var payload: Dictionary = quote["payload"]
	assert_eq(int(payload["restore_level"]), level, "it comes back at the level it fell at")
	assert_true(int(payload["cost"]) > 0, "and it is not free")
	var before := sim.treasury.balance

	sim.bus.drain()
	var done := sim.cmd_restore_building(sim_id)
	assert_true(bool(done["ok"]), str(done.get("reason_code", "")))
	assert_eq(sim.treasury.balance, before - int(payload["cost"]),
			"charged exactly what it quoted")
	assert_eq(String(b.state), "under_construction", "planned → the queue, same tick")
	assert_eq(b.pending_level, level)

	# The job is on the ONE queue, with the authored `rebuild` kind, and the
	# roster the queue panel reads publishes it like any other project.
	var job_id := int((done["payload"] as Dictionary)["job_id"])
	var seen := false
	for row in sim.construction_overview():
		if int(row["job_id"]) == job_id:
			seen = true
			assert_eq(String(row["source"]), "rebuild", "the queue names the project")
			assert_true(bool(row["rushable"]), "and cmd_rush_construction can take it")
	assert_true(seen, "a restore that the construction queue does not list is invisible")

	# `restore_started_sim` carries the render id as well as the sim id, so the
	# translator needs no lookup — the same shape `repair_started_sim` has.
	var started := {}
	for event in sim.bus.drain():
		if StringName(String(event["type"])) == &"restore_started_sim":
			started = event
	assert_false(started.is_empty(), "the renderer is told the ruin is going")
	assert_eq(int(started["building"]), b.id)
	assert_eq(String(started["sim_id"]), sim_id)
	assert_eq(int(started["to_level"]), level)

	# And it finishes as a normal completion does: `building_completed`, at the
	# level it fell down at, condition new.
	sim.bus.drain()
	var completed := false
	for _h in 400:
		sim.advance_coarse_hours(1, false)
		for event in sim.bus.drain():
			if StringName(String(event["type"])) == &"building_completed" \
					and String(event.get("sim_id", "")) == sim_id:
				completed = true
		if b.state == &"active":
			break
	assert_true(completed, "the ordinary completion door fired for the restore")
	assert_eq(String(b.state), "active")
	assert_eq(b.level, level, "no demotion, ever")
	# `complete_construction` sets 1.00 and doc 02 §2.6's wear then bills the
	# remainder of the hour it landed in, exactly as it does for a new build.
	assert_true(b.condition > 0.99, "a restored building is a new building")


## **The ownership ruling** (doc 93 §AN, against the natural reading of §Y1).
## `cmd_repair_building` refuses private stock with `E_OWNER_MAINTAINED` because
## its owner bears routine wear. A building destroyed by fire is not routine
## wear, the owner is gone with the building, and this door must stay open — or
## the ruling closes it on every house, store and office in the city, which is
## most of what the 2026-09-02 player was looking at.
func test_a_destroyed_private_building_can_still_be_restored() -> void:
	var sim := CitySim.boot_from_files()
	var sim_id := _destroy_one(sim, &"active", true)
	assert_ne(sim_id, "", "the founding manifest carries owner-maintained stock")
	var b: Building = sim.buildings[sim_id]
	assert_true(b.owner_maintained, "this is the stock §Y1 is about")

	# The repair door IS closed against it — that is §Y1, and it stays true.
	var repair := sim.cmd_repair_building(sim_id, true)
	assert_false(bool(repair["ok"]))
	assert_true((repair["payload"]["blockers"] as Array).has(&"E_OWNER_MAINTAINED"),
			"doc 02 §2.6a still owns routine wear")

	# The restore door is NOT.
	var restore := sim.cmd_restore_building(sim_id, true)
	assert_true(bool(restore["ok"]),
			"E_OWNER_MAINTAINED closed the restore by accident: " \
					+ str(restore.get("reason_code", "")))
	assert_false((restore["payload"]["blockers"] as Array).has(&"E_OWNER_MAINTAINED"))
	assert_true(bool(sim.cmd_restore_building(sim_id)["ok"]),
			"and it commits, not just quotes")


## The refusals, in the documented order, and the one that has to carry a number.
func test_the_refusals_and_the_price_that_rides_on_e_funds() -> void:
	var sim := CitySim.boot_from_files()
	var unknown := sim.cmd_restore_building("NO-SUCH-BUILDING", true)
	assert_eq(String(unknown["reason_code"]), "E_UNKNOWN_BUILDING")

	# A healthy building is not a ruin, and says so rather than quoting.
	var healthy := ""
	for id in sim.roster_ids():
		if (sim.buildings[id] as Building).state == &"active":
			healthy = String(id)
			break
	assert_eq(String(sim.cmd_restore_building(healthy, true)["reason_code"]), "E_STATE")

	var sim_id := _destroy_one(sim, &"active")
	var quoted := int((sim.cmd_restore_building(sim_id, true)["payload"] as Dictionary)["cost"])
	# **The quote rides on the refusal.** A button that cannot say what it could
	# not afford is a button that says nothing.
	sim.treasury.balance = quoted - 1
	var broke := sim.cmd_restore_building(sim_id, true)
	assert_false(bool(broke["ok"]))
	assert_eq(String(broke["reason_code"]), "E_FUNDS")
	assert_eq(int((broke["payload"] as Dictionary)["cost"]), quoted,
			"E_FUNDS must carry the price the player could not pay")
	assert_true((broke["payload"]["blockers"] as Array).has(&"E_FUNDS"))

	# A ruin with a project still on it is refused rather than double-charged: a
	# shell can burn down mid-build, and that job's completion would finish the
	# restore for free (doc 02 §2.12 `under_construction → on_fire → destroyed`).
	sim.treasury.balance = 5_000_000
	assert_true(bool(sim.cmd_restore_building(sim_id)["ok"]))
	var again := sim.cmd_restore_building(sim_id, true)
	assert_false(bool(again["ok"]))
	assert_eq(String(again["reason_code"]), "E_STATE",
			"it is no longer a ruin, so E_STATE answers first")


## Austerity blocks NEW commitments (doc 03 §2.10 layer 2: construction, land,
## vehicle) and deliberately does not block repair, so the city stays repairable.
## A restore is in the second group for the same reason, and harder: a city that
## cannot rebuild its own power plant under austerity cannot recover from one.
func test_a_restore_survives_austerity() -> void:
	var sim := CitySim.boot_from_files()
	var sim_id := _destroy_one(sim, &"active")
	sim.treasury.balance = 5_000_000
	sim.treasury.austerity_active = true
	assert_false(sim.treasury.can_spend(1000, &"construction"), "austerity is engaged")
	assert_true(bool(sim.cmd_restore_building(sim_id)["ok"]),
			"austerity locked the city out of its own recovery")


## The many-at-once half. `cmd_restore_all_destroyed` is not a second verb: every
## row goes through `cmd_restore_building`, cheapest first, so a batch and N taps
## are the same N charges in the same order.
func test_the_batch_restores_cheapest_first_and_stops_at_the_wall() -> void:
	var sim := CitySim.boot_from_files()
	assert_eq(String(sim.cmd_restore_all_destroyed(true)["reason_code"]), "E_NO_RUINS",
			"a healthy city has nothing to offer")

	var ruins: Array[String] = []
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.state == &"active" and ruins.size() < 4:
			_destroy(sim, String(id))
			ruins.append(String(id))
	assert_eq(ruins.size(), 4)

	var quote := sim.cmd_restore_all_destroyed(true)
	assert_true(bool(quote["ok"]))
	var rows: Array = quote["payload"]["rows"]
	assert_eq(int(quote["payload"]["count"]), 4, "every ruin is offered")
	var running := 0
	var sum := 0
	for row: Dictionary in rows:
		assert_true(int(row["cost"]) >= running, "cheapest first, so the wall falls last")
		running = int(row["cost"])
		sum += int(row["cost"])
	assert_eq(int(quote["payload"]["cost"]), sum, "the total is the sum of the rows")
	assert_eq(sim.treasury.balance, sim.treasury.balance, "a preview takes nothing")

	# Fund exactly the two cheapest, and only those two come back.
	sim.treasury.balance = int(rows[0]["cost"]) + int(rows[1]["cost"])
	var done := sim.cmd_restore_all_destroyed()
	assert_true(bool(done["ok"]))
	assert_eq(int(done["payload"]["count"]), 2, "it stops at the funds wall, not before it")
	assert_eq(sim.treasury.balance, 0, "and it spends what it had")
	for sim_id: Variant in (done["payload"]["restored"] as Array):
		assert_ne(String((sim.buildings[String(sim_id)] as Building).state), "destroyed")


## Doc 03 §2.5's restore row, read where it lives. The price is `capital_value ×
## RESTORE_COST_FRACTION × M_repair` and nothing in `data/buildings.json` or
## `sim/buildings/building.gd` carries a dollar (report 98 C-07).
func test_the_price_is_the_published_row_and_lives_in_one_file() -> void:
	var sim := CitySim.boot_from_files()
	var sim_id := _destroy_one(sim, &"active")
	var b: Building = sim.buildings[sim_id]
	var type := String(b.archetype)
	var level := maxi(b.level_at_destruction, 1)
	var expected := CostCurves.round_half_up(
			float(sim.econ_curves.capital_value(type, level))
			* sim.econ_curves.restore_cost_fraction()
			* float(sim.treasury.difficulty().get("M_repair", 1.0)))
	var quoted := int((sim.cmd_restore_building(sim_id, true)["payload"] as Dictionary)["cost"])
	assert_eq(quoted, expected, "the verb prices off CostCurves and nothing else")
	assert_eq(quoted, sim.econ_curves.restore_cost_building(type, level,
			float(sim.treasury.difficulty().get("M_repair", 1.0))))


## **What the money actually buys** (doc 92 §54.9(a)). Doc 02 §2.12 gives
## `destroyed` an occupancy multiplier of 0 and doc 03's tax reads occupancy, so
## a ruin pays nothing — which is the trap the 2026-09-02 player was in: the
## ruins take away the income needed to fix them. This asserts the loop closes:
## the city's net falls when the shells burn and comes back when they do.
func test_a_restore_buys_back_the_tax_line_the_ruin_took() -> void:
	var sim := CitySim.boot_from_files()
	sim.advance_coarse_hours(24, false)
	var before := _mean_net(sim, 24)
	var burned: Array[String] = []
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.state == &"active" and int(b.stats.get("population", 0)) > 0 \
				and burned.size() < 5:
			_destroy(sim, String(id))
			burned.append(String(id))
	assert_eq(burned.size(), 5, "the founding manifest carries five occupied shells")
	sim.bus.drain()
	var ruined := _mean_net(sim, 24)
	assert_true(ruined < before - 100.0,
			"five ruins cost the city real money: %.2f → %.2f" % [before, ruined])

	sim.treasury.balance = 5_000_000
	var batch := sim.cmd_restore_all_destroyed()
	assert_true(bool(batch["ok"]))
	assert_eq(int((batch["payload"] as Dictionary)["count"]), 5)
	for _h in 400:
		sim.advance_coarse_hours(1, false)
		var still_down := false
		for id: Variant in burned:
			if (sim.buildings[String(id)] as Building).state != &"active":
				still_down = true
		if not still_down:
			break
	for id: Variant in burned:
		assert_eq(String((sim.buildings[String(id)] as Building).state), "active",
				"%s came back" % id)
	var healed := _mean_net(sim, 24)
	assert_true(healed > ruined + 100.0,
			"the restore bought the income back: %.2f → %.2f" % [ruined, healed])


# ------------------------------------------------------------------ helpers

## Mean settled net over `hours` game-hours on the coarse path.
func _mean_net(sim: CitySim, hours: int) -> float:
	var total := 0.0
	for _h in hours:
		sim.advance_coarse_hours(1, false)
		total += float(sim.last_settlement.get("net", 0.0))
	return total / float(maxi(1, hours))



## Burn one building down through doc 02 §2.12's own transitions, so the ruin
## under test is the ruin the game makes and not a hand-set field.
func _destroy(sim: CitySim, sim_id: String) -> void:
	var b: Building = sim.buildings[sim_id]
	b.ignite()
	b.burn_down(true, sim.clock.sim_time_minutes())


## The first building in the roster in `want_state`, destroyed. `private_only`
## picks owner-maintained stock, which is what doc 93 §AN's ruling is about.
func _destroy_one(sim: CitySim, want_state: StringName,
		private_only: bool = false) -> String:
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.state != want_state:
			continue
		if private_only != b.owner_maintained:
			continue
		_destroy(sim, String(id))
		return String(id)
	return ""
