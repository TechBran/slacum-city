extends SimTest
## Doc 06 §7 lifecycle, cascade and persistence tests: the FSM end to end, the
## §2.5 resolution arithmetic, burn-down and its offline refusal (C-47), fire
## spread clustering, the load damper, the grep guards report 98 asks for, and
## a save round-trip taken mid-incident.


func _system(world: IncidentTestWorld, seed_value: int = 7331) -> IncidentSystem:
	var system := IncidentSystem.new(IncidentCatalog.load_from_files(), world,
			RngStreams.new(seed_value))
	system.generation_enabled = false
	return system


func _world() -> IncidentTestWorld:
	var world := IncidentTestWorld.new()
	world.add_district("D1", 5000.0, 0.80, 0.5, 0.0)
	return world


# ------------------------------------------------------------------- the FSM

## QUEUED → ASSIGNED → ACTIVE → RESOLVED, with the timestamps, the reward, the
## stability credit and the unit release all landing exactly once.
func test_incident_lifecycle() -> void:
	var world := _world()
	world.add_component("T-1", Vector2i(12, 0), {"customers_downstream": 120})
	var system := _system(world)
	system.fleet.populate_from_stations([{"id": "SUB-A", "archetype": "substation",
			"level": 1, "tile": Vector2i(0, 0)}])
	var inc := system.spawn_component_incident("T-1", world.power_component("T-1"), 1.0,
			{"source": "test"})
	assert_ne(inc, null, "incident created")
	assert_eq(inc.status, Incident.STATUS_QUEUED, "born QUEUED")
	assert_eq(inc.type, "transformer_failure", "a transformer failure")
	assert_eq(inc.tier(), 1, "tier 1")

	system.advance_to(1.0 / 60.0)
	assert_eq(inc.status, Incident.STATUS_ASSIGNED, "a truck was assigned")
	assert_true(inc.first_assign_h >= 0.0, "first_assign stamped")

	var seen_active := false
	for minute in 240:
		system.advance_to(float(minute + 2) / 60.0)
		if inc.status == Incident.STATUS_ACTIVE:
			seen_active = true
		if inc.is_terminal():
			break
	assert_true(seen_active, "went ACTIVE when the truck arrived")
	assert_eq(inc.status, Incident.STATUS_RESOLVED, "and resolved")
	assert_true(inc.first_onscene_h > inc.first_assign_h, "on-scene after assignment")
	assert_true(inc.resolved_h > inc.first_onscene_h, "resolved after arrival")
	assert_eq(world.restored.size(), 1, "the component was repaired exactly once")
	assert_eq(String(world.restored[0]), "T-1", "the right component")
	assert_eq(world.credits.size(), 1, "the reward was paid once")
	assert_true(int(world.credits[0]["amount"]) > 0, "and it is positive")
	var stability_credit := 0
	for row in world.stability_deltas:
		if absf(float(row["delta"]) - 0.015) < 1e-9:
			stability_credit += 1
	assert_eq(stability_credit, 1, "stability_on_resolve applied once")
	for unit_id in system.fleet.unit_ids():
		var u: Vehicle = system.fleet.unit(unit_id)
		assert_true(u.status == Vehicle.RETURNING or u.status == Vehicle.IDLE,
				"units released from a terminal incident")
	assert_eq(system.active_count(), 0, "incident left the active list")
	assert_eq(system.dispatch.stats["resolved_total"], 1, "stats recorded the resolution")


## Doc 06 §2.5's worked resolution example, to the digit.
func test_resolution_math_transformer() -> void:
	var world := _world()
	world.add_component("T-1", Vector2i(0, 0))
	var system := _system(world)
	system.fleet.populate_from_stations([{"id": "SUB-A", "archetype": "substation",
			"level": 2, "tile": Vector2i(0, 0)}])
	var inc := system.spawn_component_incident("T-1", world.power_component("T-1"), 2.0,
			{"source": "test"})
	assert_almost_eq(system.work_required(inc), 1.17, 1e-9, "W = 0.90 × 1.30")
	assert_almost_eq(system.required_rate(inc), 1.4, 1e-9, "required_rate = 1.0 × (1 + 0.4)")
	var units := system.fleet.unit_ids()
	assert_eq(units.size(), 2, "an L2 substation houses two utility trucks")
	var first: Vehicle = system.fleet.unit(int(units[0]))
	inc.assigned[first.id] = {"role": "utility", "state": Vehicle.ON_SCENE, "eta_h": 0.0,
			"manual": false}
	assert_almost_eq(system.assigned_effective_rate(inc), 1.0, 1e-9, "one truck")
	assert_almost_eq(system.assist_ratio(inc), 1.0 / 1.4, 1e-9,
			"0.714 — one truck is not enough for a tier-2 transformer")
	var second: Vehicle = system.fleet.unit(int(units[1]))
	inc.assigned[second.id] = {"role": "utility", "state": Vehicle.ON_SCENE, "eta_h": 0.0,
			"manual": false}
	assert_almost_eq(system.assigned_effective_rate(inc), 2.0, 1e-9, "two trucks")
	assert_almost_eq(system.assist_ratio(inc), 2.0 / 1.4, 1e-9, "1.43 — escalation halted")
	assert_almost_eq(1.17 / 2.0, 0.585, 1e-9, "work done in 0.585 gh")


## Doc 06 §7 test 20 — a tier-5 fire held for 0.5 gh destroys the building,
## applies each delta exactly once, and spawns the debris incident.
func test_burn_down() -> void:
	var world := _world()
	world.add_building("B1", "house", 2, Vector2i(10, 10), "D1",
			{"fire_load": 40.0, "occupants": 6.0})
	var system := _system(world)
	var inc := system.spawn("structure_fire", "", Vector2i(10, 10),
			{"kind": "building", "id": "B1"}, 4.99)
	for minute in 120:
		system.advance_to(float(minute + 1) / 60.0)
		if inc.is_terminal():
			break
	assert_eq(inc.status, Incident.STATUS_FAILED, "the fire won")
	assert_eq(world.destroyed.size(), 1, "the building was destroyed exactly once")
	assert_eq(String(world.destroyed[0]["id"]), "B1", "the right building")
	assert_eq(world.population_losses.size(), 1, "the fatality fraction applied once")
	assert_almost_eq(float(world.population_losses[0]["fraction"]), 0.02, 1e-9,
			"FIRE_FATALITY_FRACTION")
	var big_hit := 0
	for row in world.stability_deltas:
		if absf(float(row["delta"]) + 0.12) < 1e-9:
			big_hit += 1
	assert_eq(big_hit, 1, "stability −0.12 applied once")
	assert_eq(world.confidence_deltas.size(), 1, "confidence −0.05 applied once")
	var debris := 0
	for incident_id in system.incident_ids():
		var other: Incident = system.incident(incident_id)
		if other.type == "storm_damage" and other.subtype == "blocked_road":
			debris += 1
	assert_eq(debris, 1, "the debris incident was spawned")
	var destroyed_events := 0
	for event in system.drain_events():
		if String(event.get("type", "")) == "building_destroyed_by_fire":
			destroyed_events += 1
	assert_eq(destroyed_events, 1, "building_destroyed_by_fire emitted once")


## Doc 06 §7 test 29 (C-47) — offline the verb is REFUSED, visibly.
func test_destroy_refused_offline() -> void:
	var world := _world()
	world.allow_destroy = false
	world.offline = true
	world.add_building("B1", "house", 2, Vector2i(10, 10), "D1",
			{"fire_load": 40.0, "occupants": 6.0})
	var system := _system(world)
	var inc := system.spawn("structure_fire", "", Vector2i(10, 10),
			{"kind": "building", "id": "B1"}, 4.99)
	var refusals := 0
	for hour in 6:
		system.advance_to(float(hour + 1))
		for event in system.drain_events():
			if String(event.get("type", "")) == "destroy_refused_offline":
				refusals += 1
	assert_eq(refusals, 1, "destroy_refused_offline emitted exactly once, not every sub-step")
	assert_eq(world.destroyed.size(), 0, "buildings.destroy was never called")
	assert_almost_eq(float(world.buildings["B1"]["condition"]), 0.15, 1e-9,
			"condition clamped to OFFLINE_DESTROY_CLAMP_CONDITION")
	assert_false(inc.is_terminal(), "the incident is NOT resolved and NOT failed")
	assert_eq(inc.tier(), 5, "still at tier 5 — the player comes back to it still burning")
	assert_almost_eq(inc.burn_timer_h, 0.50, 1e-9, "burn_timer frozen at the threshold")

	# Come back online and the destruction proceeds.
	world.allow_destroy = true
	world.offline = false
	for hour in 3:
		system.advance_to(6.0 + float(hour + 1))
		if inc.is_terminal():
			break
	assert_eq(inc.status, Incident.STATUS_FAILED, "online, the fire finishes the job")
	assert_eq(world.destroyed.size(), 1, "and the building is destroyed once")


## An unanswered minor crime self-resolves into ABANDONED with its penalty.
func test_self_resolve_abandoned() -> void:
	var world := _world()
	world.add_building("B1", "house", 1, Vector2i(3, 3), "D1")
	var system := _system(world)
	var inc := system.spawn("crime", "", Vector2i(3, 3), {}, 1.0, {}, "D1")
	# No units exist at all, so it can only time out.
	for minute in 240:
		system.advance_to(float(minute + 1) / 60.0)
		if inc.is_terminal():
			break
	assert_eq(inc.status, Incident.STATUS_ABANDONED, "self-resolved with no response")
	assert_eq(system.dispatch.stats["abandoned_total"], 1, "counted as abandoned")
	var penalty := 0
	for row in world.stability_deltas:
		if absf(float(row["delta"]) + 0.10) < 1e-9:
			penalty += 1
	assert_eq(penalty, 1, "the −0.10 stability penalty applied once")


# ================================ §2.10.1 — the terminal rule (report 98 RR-26)
#
# Before Wave 9 three ROWS of `data/incidents.json` authored NO ending at all: a
# `traffic_accident` and a `storm_damage/blocked_road` above tier 2 have left
# their `self_resolve` window behind (`self_resolve_max_tier` is 2) and have no
# other condition, and bare `storm_damage` has no `on_fail` block whatsoever.
# All three used to climb to tier 5 and stand there for the rest of the city's
# life, which is what made doc 10's router unaffordable — the open roster, and
# everything O(open), grew without bound. These four tests hold the rule, its
# mode invariance, and the two things it must NOT do.


## The window is one GAME-DAY, and it is derived (§2.10.1): 1.77× the longest
## terminal path any row authors, which is the subtype `storm_damage/roof_damage`
## at 13.574 gh on casual difficulty.
func test_an_incident_nobody_answers_is_abandoned_after_a_game_day() -> void:
	var world := _world()
	world.add_building("B1", "house", 1, Vector2i(3, 3), "D1")
	var system := _system(world)
	assert_almost_eq(system.unanswered_abandon_h(), 24.0, 1e-9,
			"data/dispatch.json carries the ruled window")
	# Above `self_resolve_max_tier`, so the catalog offers this incident no
	# ending of any kind. Before RR-26 it stayed on the roster for ever.
	var inc := system.spawn("traffic_accident", "", Vector2i(3, 3), {}, 3.0, {}, "D1")
	assert_true(inc.tier() > 2, "spawned past the self-resolve window")
	for hour in 26:
		system.advance_to(float(hour + 1))
		if inc.is_terminal():
			break
	assert_eq(inc.status, Incident.STATUS_ABANDONED,
			"an incident nobody can answer ends (§2.10.1)")
	assert_true(inc.resolved_h >= 24.0 - 1e-6 and inc.resolved_h <= 24.05,
			"…at the ruled game-day, not before (%f)" % inc.resolved_h)
	# ≥ 1 rather than == 1: §2.7's tier-4 row spawns a secondary collision, and
	# the child has the same gap in the catalog, so it is abandoned too. That is
	# the rule working on both of them, not a double count on one.
	assert_true(int(system.dispatch.stats["abandoned_total"]) >= 1,
			"counted as abandoned (%d)" % int(system.dispatch.stats["abandoned_total"]))
	assert_eq(int(system.dispatch.stats["failed_total"]), 0,
			"ABANDONED, never FAILED — §2.2 reserves the two words for two things")


func test_the_clock_lands_on_the_same_game_second_online_and_offline() -> void:
	# Mode invariance (§2.1): the boundary is a discontinuity, so a coarse hour
	# cannot step over it and the two paths must agree to the game-second.
	var fine_world := _world()
	fine_world.add_building("B1", "house", 1, Vector2i(3, 3), "D1")
	var fine := _system(fine_world)
	var fine_inc := fine.spawn("traffic_accident", "", Vector2i(3, 3), {}, 3.0, {}, "D1")
	for minute in 26 * 60:
		fine.advance_to(float(minute + 1) / 60.0)
		if fine_inc.is_terminal():
			break
	var coarse_world := _world()
	coarse_world.add_building("B1", "house", 1, Vector2i(3, 3), "D1")
	var coarse := _system(coarse_world)
	var coarse_inc := coarse.spawn("traffic_accident", "", Vector2i(3, 3), {}, 3.0, {}, "D1")
	for hour in 26:
		coarse.advance(1.0)
		if coarse_inc.is_terminal():
			break
	assert_eq(coarse_inc.status, fine_inc.status)
	assert_almost_eq(coarse_inc.resolved_h, fine_inc.resolved_h, 1.0 / 3600.0,
			"the offline path abandons on the same game-second the online one does")


func test_a_committed_unit_zeroes_the_clock() -> void:
	# The rule measures NOBODY IS COMING, not THIS IS SLOW. Committing a unit
	# must RESET the clock, not merely pause it.
	var world := _world()
	world.add_building("B1", "house", 1, Vector2i(3, 3), "D1")
	var system := _system(world)
	var inc := system.spawn("traffic_accident", "", Vector2i(3, 3), {}, 3.0, {}, "D1")
	for hour in 20:
		system.advance_to(float(hour + 1))
	assert_almost_eq(inc.unanswered_h, 20.0, 0.05, "twenty game-hours of nobody")
	assert_false(inc.is_terminal(), "and not yet abandoned")
	# Committing anything at all is what the rule is about.
	inc.assigned[1] = {"role": "police", "state": Vehicle.RESPONDING,
			"eta_h": 20.1, "manual": false}
	system.advance_to(20.5)
	assert_almost_eq(inc.unanswered_h, 0.0, 1e-9, "one commitment zeroes the clock")
	assert_false(inc.is_terminal(), "and the incident is emphatically not abandoned")
	# Take it away again and the incident gets the FULL window back, not the
	# remainder of the old one.
	inc.assigned.clear()
	for hour in 23:
		system.advance_to(21.0 + float(hour))
	assert_false(inc.is_terminal(),
			"23 game-hours since the unit left is not yet a game-day")
	system.advance_to(45.0)
	assert_eq(inc.status, Incident.STATUS_ABANDONED, "…and a game-day is")


## THE INVARIANT THE WINDOW WAS DERIVED FOR: every row that authors its own
## ending still reaches it FIRST, so the neglect-fatal identity is untouched.
## Two rows are checked — the shortest authored path and the LONGEST, which is
## the one that decided the window.
func test_the_terminal_rule_never_pre_empts_an_authored_ending() -> void:
	# The shortest and most important: an unanswered fire destroys its building.
	var world := _world()
	world.add_building("B1", "house", 2, Vector2i(3, 3), "D1")
	world.allow_destroy = true
	var system := _system(world)
	var inc := system.spawn("structure_fire", "", Vector2i(3, 3),
			{"kind": "building", "id": "B1"}, 1.0, {}, "D1")
	for minute in 26 * 60:
		system.advance_to(float(minute + 1) / 60.0)
		if inc.is_terminal():
			break
	assert_eq(inc.status, Incident.STATUS_FAILED,
			"an unanswered fire still DESTROYS its building — it does not get "
			+ "quietly abandoned a game-day later")
	assert_eq(world.destroyed.size(), 1, "the building is gone, which is the point")
	assert_true(inc.resolved_h < 24.0,
			"and it happened well inside the abandonment window (%f gh)" % inc.resolved_h)

	# The LONGEST authored path in the catalog, and the row that set T = 24:
	# `storm_damage/roof_damage` holds tier 5 for 2.0 gh before it fails.
	var slow_world := _world()
	slow_world.add_building("B2", "house", 2, Vector2i(9, 9), "D1")
	var slow := _system(slow_world)
	var slow_inc := slow.spawn("storm_damage", "roof_damage", Vector2i(9, 9),
			{"kind": "building", "id": "B2"}, 1.0, {}, "D1")
	for minute in 26 * 60:
		slow.advance_to(float(minute + 1) / 60.0)
		if slow_inc.is_terminal():
			break
	assert_eq(slow_inc.status, Incident.STATUS_FAILED,
			"the slowest-escalating row in the catalog still reaches its OWN "
			+ "ending first — this is the row the window was fitted against")
	assert_true(slow_inc.resolved_h < 24.0,
			"…inside the window (%f gh against 24)" % slow_inc.resolved_h)


## Doc 06 §7 test 18 — the transformer cascade is declarative data: shed at
## tier 2, feeder offline at tier 3, and neither fires twice.
func test_cascade_tier_entries_are_data() -> void:
	var world := _world()
	world.add_component("T-1", Vector2i(20, 20))
	var system := _system(world)
	var inc := system.spawn_component_incident("T-1", world.power_component("T-1"), 1.0,
			{"source": "test"})
	for minute in 400:
		system.advance_to(float(minute + 1) / 60.0)
		if inc.tier() >= 4:
			break
	assert_true(inc.tier() >= 4, "escalated with no response")
	assert_eq(world.shed_calls.size(), 1, "feeder_load_shed fired once at tier 2")
	assert_almost_eq(float(world.shed_calls[0]["fraction"]), 0.25, 1e-9, "25% load shed")
	assert_eq(world.offline_calls.size(), 1, "feeder_offline fired once at tier 3")
	assert_eq(inc.tiers_fired, [2, 3, 4], "each tier recorded exactly once")


## Doc 06 §7 test 21 — a dense wooden block with no response produces multiple
## spread ignitions, all sharing one cluster_id, and the cluster bonus applies.
func test_spread_cluster() -> void:
	var world := _world()
	world.add_building("SRC", "apartment", 2, Vector2i(10, 10), "D1", {"fire_load": 90.0})
	var index := 0
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			world.add_building("H%d" % index, "house", 2, Vector2i(10 + dx, 10 + dz), "D1",
					{"fire_load": 40.0})
			index += 1
	var system := _system(world, 24680)
	var source := system.spawn("structure_fire", "", Vector2i(10, 10),
			{"kind": "building", "id": "SRC"}, 3.0)
	for minute in 120:
		system.advance_to(float(minute + 1) / 60.0)
	var children: Array = []
	for incident_id in system.incident_ids():
		var inc: Incident = system.incident(incident_id)
		if inc.parent_id != 0 and inc.type == "structure_fire":
			children.append(inc)
	assert_true(children.size() >= 2, "at least two spread ignitions, got %d" % children.size())
	assert_true(source.cluster_id != 0, "the source allocated a cluster on first spread")
	for child in children:
		assert_eq((child as Incident).cluster_id, source.cluster_id, "one cluster")
	var solo := system.dispatch.priority(source, 1, system.now_h)
	var clustered := system.dispatch.priority(source, 4, system.now_h)
	assert_almost_eq(clustered - solo, 75.0, 1e-6, "CLUSTER_BONUS 25 × (4 − 1)")


## Doc 06 §7 test 22 — the anti-death-spiral damper hits its 0.25 floor.
##
## **Measured at the SATURATION KNEE, not at 40.** This test used to fill the
## roster to 40 and read the damper there; §2.13(b) now zeroes generation at 40,
## and a product of two dampers cannot measure either one. The knee is the last
## roster size at which §2.13(b)'s factor is exactly 1.0, so it is where the
## anti-death-spiral damper alone is visible — and it is well past the excess the
## floor needs.
func test_load_damper() -> void:
	var world := _world()
	var system := _system(world)
	system.fleet.populate_from_stations([{"id": "POL-1", "archetype": "police_station",
			"level": 3, "tile": Vector2i(0, 0)}])
	assert_almost_eq(system.load_damper(), 1.0, 1e-9, "no incidents ⇒ no damping")
	var knee := system.saturation_knee()
	for i in knee:
		system.spawn("crime", "", Vector2i(i, 0), {}, 1.2, {}, "D1")
	assert_eq(system.active_count(), knee, "%d active incidents" % knee)
	assert_true(system.fleet.size() < knee, "against a small fleet")
	assert_almost_eq(system.saturation_damper(), 1.0, 1e-9,
			"§2.13(b) is still exactly 1.0 at its own knee")
	assert_almost_eq(system.load_damper(), 0.25, 1e-9, "damper pinned to its floor")


# ------------------------------------------------- §2.13(b) the saturation rule

## **Doc 06 §2.13(b) — the roster ceiling is a KNEE, not a cliff.** All three
## numbers come out of `data/incidents.json`; the shape is asserted at four
## points, and the first two are the ones that matter: below and AT the knee the
## factor is exactly 1.0, which is why no measured city's pressure moves and why
## the starter and bench determinism baselines are byte-identical.
func test_saturation_is_a_knee_not_a_cliff() -> void:
	var world := _world()
	var system := _system(world)
	var knee := system.saturation_knee()
	var ceiling := system.saturation_automatic_ceiling()
	assert_true(knee > 0 and ceiling > knee,
			"the rule is authored: knee %d, automatic ceiling %d" % [knee, ceiling])
	assert_eq(system.saturation_ceiling() - system.saturation_world_reserve(), ceiling,
			"the automatic ceiling is §2.13's roster bound less the world reserve")
	assert_almost_eq(system.saturation_damper(), 1.0, 1e-9, "an empty roster is undamped")
	assert_false(system.saturated(), "and not saturated")
	while system.active_count() < knee:
		system.spawn("crime", "", Vector2i(system.active_count(), 0), {}, 1.2, {}, "D1")
	assert_almost_eq(system.saturation_damper(), 1.0, 1e-9,
			"exactly 1.0 AT the knee — this is the property the gates rest on")
	while system.active_count() < (knee + ceiling) / 2:
		system.spawn("crime", "", Vector2i(system.active_count(), 0), {}, 1.2, {}, "D1")
	assert_almost_eq(system.saturation_damper(), 0.5, 0.06,
			"about half way down at the midpoint")
	while system.active_count() < ceiling:
		system.spawn("crime", "", Vector2i(system.active_count(), 0), {}, 1.2, {}, "D1")
	assert_true(system.saturated(), "saturated at the automatic ceiling")
	assert_almost_eq(system.saturation_damper(), 0.0, 1e-9,
			"and generation is zero there, not merely floored")
	assert_eq(system.spawn_automatic("crime", "", Vector2i(0, 0), {}, 1.2, {}, "D1"), null,
			"an AUTOMATIC birth is refused at the ceiling")
	assert_ne(system.spawn("crime", "", Vector2i(0, 0), {}, 1.2, {}, "D1"), null,
			"a scripted or player-driven one is not — `spawn()` stays open")


## **Doc 06 §2.13(b) part 2 — a cascade may not invent a subject the GENERATOR
## would not have found** (doc 92 §31). `crime`'s tier-4 and tier-5 cascades are
## authored `scope: "district"`, which needs no entity at all, so they kept
## producing crimes in a district whose population had been zero for a hundred
## game-days. Doc 92 §18 already states the rule for the ambient floor — it
## changes how OFTEN, never WHERE — and this is the same rule one layer up.
func test_a_district_cascade_needs_a_district_that_can_host_it() -> void:
	var world := IncidentTestWorld.new()
	world.add_district("D_LIVE", 5000.0, 0.10, 0.0, 0.0)
	world.add_district("D_DEAD", 0.0, 0.0, 0.0, 0.0)
	var system := _system(world)
	var action := {"op": "spawn_incident", "type": "crime", "count": 2, "scope": "district"}

	var live := system.spawn("crime", "", Vector2i(0, 0), {}, 1.0, {}, "D_LIVE")
	var live_result := system.ops.run_one(live, action)
	assert_eq(String(live_result["result"]), CascadeOps.DONE, "a district with residents hosts it")
	assert_eq((live_result["spawned"] as Array).size(), 2, "both children born")

	var dead := system.spawn("crime", "", Vector2i(9, 9), {}, 1.0, {}, "D_DEAD")
	var dead_result := system.ops.run_one(dead, action)
	assert_eq((dead_result["spawned"] as Array).size(), 0,
			"an emptied district has nobody to commit the crime")
	# Every other type stays per-asset and its `district` scope is unrestricted:
	# doc 06 §2.6 only makes a DISTRICT ineligible for crime.
	var storm_result := system.ops.run_one(dead,
			{"op": "spawn_incident", "type": "storm_damage", "count": 1, "scope": "district"})
	assert_eq((storm_result["spawned"] as Array).size(), 1,
			"only crime has a district eligibility test to fail")


## **The cascade itself, reproduced and bounded** (doc 92 §31). One populated
## district at stability zero, no fleet, ambient generation off: a single crime
## left unanswered is a branching process with a mean offspring of THREE — one
## child at tier 4, two more at tier 5 — and RR-26's terminal rule bounds each
## incident's lifetime without touching its fertility.
##
## Before §2.13(b) this test could not be written: the roster passed five figures
## inside a game-day and the run never came back. The two assertions are the
## whole rule — it saturates (so the ceiling is what is holding it, not some
## accident of the fixture) and it never exceeds the ceiling, over a horizon long
## enough for any leak of one incident per generation to show.
func test_the_crime_cascade_is_bounded_by_the_ceiling() -> void:
	var world := IncidentTestWorld.new()
	world.add_district("D1", 5000.0, 0.0, 0.0, 0.0)
	var system := _system(world)
	var ceiling := system.saturation_automatic_ceiling()
	system.spawn("crime", "", Vector2i(0, 0), {}, 1.0, {}, "D1")
	var peak := 0
	for hour in 14 * 24:
		system.advance_to(float(hour + 1))
		peak = maxi(peak, system.active_count())
		assert_true(system.active_count() <= ceiling,
				"game-hour %d carried %d open incidents against an automatic ceiling of %d"
						% [hour, system.active_count(), ceiling])
	assert_eq(peak, ceiling,
			"the cascade must actually reach the ceiling or this test proves nothing "
			+ "(peaked at %d)" % peak)
	assert_true(peak <= system.saturation_ceiling(),
			"and the roster bound §2.13 costs itself against is never crossed")


# ------------------------------------------------------------- generation

## Doc 06 §7 test 27 (C-45) — crime generation AND crime target selection draw
## from the `crime` stream; `incidents` is untouched by the crime generator,
## and nothing in sim/ consumes `traffic`.
func test_crime_uses_crime_stream() -> void:
	var world := _world()
	world.add_district("D1", 60000.0, 0.20, 0.0, 1.0)
	for i in 6:
		world.add_building("B%d" % i, "store", 2, Vector2i(i, 0), "D1", {"crime_weight": 4.8})
	var system := _system(world)
	system.generation_enabled = true
	var incidents_before := system.rng.stream("incidents").state
	var crime_before := system.rng.stream("crime").state
	var traffic_before := system.rng.stream("traffic").state
	system._generate_crime(1.0, 1.0, 1.0)
	assert_ne(system.rng.stream("crime").state, crime_before, "the crime stream was consumed")
	assert_eq(system.rng.stream("incidents").state, incidents_before,
			"the incidents stream was NOT touched by the crime generator")
	assert_eq(system.rng.stream("traffic").state, traffic_before, "traffic is reserved")
	# And no doc-06 file draws from `traffic` at all. (Doc 10's cosmetic feed
	# is the stream's one sanctioned consumer and guards that itself.)
	assert_false(_read_tree("res://sim/incidents").contains("stream(\"traffic\")"),
			"no doc-06 code consumes the traffic stream")


## Doc 06 §7 test 26 (C-44) — the within-district pick is doc 02's
## `crime_weight`, verbatim, and a burning building is never picked.
func test_crime_target_weighting() -> void:
	var world := _world()
	for i in 40:
		world.add_building("H%02d" % i, "house", 1, Vector2i(i, 0), "D1", {"crime_weight": 1.00})
	for i in 6:
		world.add_building("S%02d" % i, "store", 2, Vector2i(i, 1), "D1", {"crime_weight": 4.80})
	for i in 2:
		world.add_building("X%02d" % i, "substation", 1, Vector2i(i, 2), "D1",
				{"crime_weight": 1.50})
	world.buildings["H00"]["state"] = "on_fire"
	var system := _system(world)
	var picks := 20000
	var stores := 0
	var substations := 0
	var burning := 0
	for i in picks:
		var picked := system._pick_crime_target("D1", "crime")
		if picked.begins_with("S"):
			stores += 1
		elif picked.begins_with("X"):
			substations += 1
		elif picked == "H00":
			burning += 1
	# Σ weights without the burning house = 39·1.00 + 6·4.80 + 2·1.50 = 70.8.
	assert_almost_eq(float(stores) / float(picks), 28.8 / 70.8, 0.012, "P(store)")
	assert_almost_eq(float(substations) / float(picks), 3.0 / 70.8, 0.008, "P(substation)")
	assert_eq(burning, 0, "a building already on fire is never picked")


# ----------------------------------------------------------- persistence

## Doc 06 §7 test 37 (C-25) — the three save sections carry `section_version`
## and none carries `schema_version`.
func test_section_version_keys() -> void:
	var world := _world()
	var system := _system(world)
	var saved := system.serialize()
	for section in ["incidents", "fleet", "dispatch"]:
		var body: Dictionary = saved[section]
		assert_true(body.has("section_version"), "%s carries section_version" % section)
		assert_false(body.has("schema_version"), "%s carries no schema_version" % section)


## Doc 06 §7 test 4 — serialise mid-incident (unit en route, two tiers fired),
## deserialise, continue: no tier re-fires and the arrival lands on the same
## game-minute. The save goes through CitySim's float bit-encoder, so the
## restored instance proceeds bit-identically.
func test_save_load_midflight() -> void:
	var system_a := _mid_incident_system()
	var inc_a: Incident = system_a.incident(system_a.incident_ids()[0])
	assert_true(inc_a.tier() >= 3, "mid-incident at tier ≥ 3, got %d" % inc_a.tier())
	assert_true(inc_a.tiers_fired.size() >= 2, "at least two tiers already fired")
	var responding := false
	for unit_id in system_a.fleet.unit_ids():
		if (system_a.fleet.unit(unit_id) as Vehicle).status == Vehicle.RESPONDING:
			responding = true
	assert_true(responding, "a unit is en route at save time")
	var arrive_at: float = (system_a.fleet.unit(
			int(inc_a.assigned_unit_ids()[0])) as Vehicle).arrive_at_h

	var encoded: Variant = CitySim._encode_floats(system_a.serialize())
	var round_tripped: Variant = CitySim._decode_floats(
			JSON.parse_string(JSON.stringify(encoded, "", true, true)))

	var system_b := _mid_incident_system(true)
	system_b.deserialize(round_tripped)
	system_b.rng.deserialize(system_a.rng.serialize())
	var inc_b: Incident = system_b.incident(inc_a.id)
	assert_ne(inc_b, null, "the incident came back")
	assert_almost_eq(inc_b.severity, inc_a.severity, 0.0, "severity bit-identical")
	assert_almost_eq(inc_b.progress, inc_a.progress, 0.0, "progress bit-identical")
	assert_eq(inc_b.status, inc_a.status, "status preserved")
	assert_eq(inc_b.tiers_fired, inc_a.tiers_fired, "fired tiers preserved")
	assert_almost_eq(system_b.now_h, system_a.now_h, 0.0, "clock preserved")
	var unit_b: Vehicle = system_b.fleet.unit(int(inc_a.assigned_unit_ids()[0]))
	assert_almost_eq(unit_b.arrive_at_h, arrive_at, 0.0, "arrival lands on the same minute")

	var fired_before := inc_b.tiers_fired.duplicate()
	system_a.drain_events()
	system_b.drain_events()
	var events_a: Array = []
	var events_b: Array = []
	for minute in 30:
		system_a.advance_to(system_a.now_h + 1.0 / 60.0)
		system_b.advance_to(system_b.now_h + 1.0 / 60.0)
		for event in system_a.drain_events():
			events_a.append("%s:%s" % [event.get("type", ""), str(event.get("incident_id", 0))])
		for event in system_b.drain_events():
			events_b.append("%s:%s" % [event.get("type", ""), str(event.get("incident_id", 0))])
	assert_eq(events_b.size(), events_a.size(), "the resumed city produces the same events")
	for i in events_a.size():
		assert_eq(String(events_b[i]), String(events_a[i]), "event %d identical" % i)
	for tier in fired_before:
		assert_eq(inc_b.tiers_fired.count(tier), 1, "tier %s did not re-fire" % str(tier))
	assert_almost_eq(system_b.incident(inc_a.id).severity if system_b.incident(inc_a.id) != null
			else -1.0,
			system_a.incident(inc_a.id).severity if system_a.incident(inc_a.id) != null else -1.0,
			0.0, "the two runs stay bit-identical after the reload")


## A city caught exactly where the doc's test 4 wants it: two tiers already
## fired, and a truck en route that has not arrived yet.
func _mid_incident_system(empty: bool = false) -> IncidentSystem:
	var world := _world()
	world.add_component("T-1", Vector2i(60, 0), {"customers_downstream": 300})
	var system := _system(world, 555)
	system.fleet.populate_from_stations([{"id": "SUB-A", "archetype": "substation",
			"level": 1, "tile": Vector2i(0, 0)}])
	if empty:
		return system
	# Nobody answers while it escalates …
	system.dispatch.cmd_set_policy("auto_dispatch_utility", false)
	var inc := system.spawn_component_incident("T-1", world.power_component("T-1"), 1.0,
			{"source": "test"})
	for minute in 400:
		system.advance_to(float(minute + 1) / 60.0)
		if inc.tiers_fired.size() >= 2:
			break
	# … then a truck rolls, and we save while it is still driving.
	system.dispatch.cmd_set_policy("auto_dispatch_utility", true)
	system.advance_to(system.now_h + 1.0 / 60.0)
	return system


# -------------------------------------------------------------- grep guards

## Doc 06 §7 test 33 (C-07 / R-14, extended by RR-78) — no price lives in doc
## 06's data, and every vehicle's economy_id resolves in doc 03's table.
##
## `reward_base` is the newest name on the list and was the last dollar column
## standing outside doc 03's monopoly. The match is quote-delimited, which is
## what lets `data/incidents.json`'s `_reward_note` name the retired key in prose
## — RR-17's rule, and the same one doc 10's `_pricing_owner_note` relies on.
func test_no_price_in_doc06_data() -> void:
	var forbidden := ["purchase_cost", "upkeep_per_game_hour", "dispatch_cost",
			"repair_material_base", "reward_base", "weather_speed_mult",
			"road_class_mult"]
	for path in ["res://data/incidents.json", "res://data/vehicles.json",
			"res://data/dispatch.json"]:
		var text := JSON.stringify(StarterCityLoader.read_json(path))
		for key in forbidden:
			assert_false(text.contains("\"%s\"" % key), "%s must not contain %s" % [path, key])
	var economy := StarterCityLoader.read_json("res://data/economy.json")
	var priced: Dictionary = economy.get("expenses", {}).get("vehicles", {})
	assert_false(priced.is_empty(), "doc 03 publishes the vehicle price table")
	var catalog := IncidentCatalog.load_from_files()
	for type_id in catalog.vehicle_type_ids:
		var economy_id := String(catalog.vehicle_type(String(type_id)).get("economy_id", ""))
		assert_true(priced.has(economy_id),
				"%s → economy_id %s resolves in data/economy.json" % [type_id, economy_id])


## Doc 06 §7 test 38 (RR-4 / RR-15) — no weather table, no weather state key
## and no weather-keyed float literal survives anywhere in doc 06's tree.
func test_no_weather_table_in_doc06() -> void:
	for path in ["res://data/incidents.json", "res://data/vehicles.json",
			"res://data/dispatch.json"]:
		var text := JSON.stringify(StarterCityLoader.read_json(path))
		assert_false(text.contains("weather_mults"), "%s has no weather_mults table" % path)
		for state in ["\"snow\"", "\"blizzard\"", "\"fog\"", "\"thunderstorm\"",
				"\"heat_wave\"", "\"clear\""]:
			assert_false(text.contains(state), "%s carries no weather state key %s" % [path, state])
	# Scan doc 06's OWN tree as CODE — comments and string literals stripped —
	# so the guard catches a reintroduced identifier without tripping over the
	# guard lists that name the deleted keys on purpose. (Doc 07 legitimately
	# owns heat multipliers in sim/weather/; the ban is on doc 06 owning them.)
	var code := _strip_comments_and_strings(_read_tree("res://sim/incidents"))
	assert_false(code.contains("heat_mult"), "heat_mult does not exist in sim/incidents/")
	assert_false(code.contains("rain_mult"), "rain_mult does not exist in sim/incidents/")
	assert_false(code.contains("weather_mults"), "no weather_mults table in sim/incidents/")
	# The four generators name exactly the four RR-4 channels; water_main_break
	# and storm_damage name none.
	var catalog := IncidentCatalog.load_from_files()
	assert_eq(catalog.weather_channel_for("crime"), "incident_crime_mult", "crime channel")
	assert_eq(catalog.weather_channel_for("structure_fire"), "fire_ignition_mult", "fire channel")
	assert_eq(catalog.weather_channel_for("transformer_failure"), "incident_utility_mult",
			"transformer channel")
	assert_eq(catalog.weather_channel_for("traffic_accident"), "incident_traffic_mult",
			"traffic channel")
	assert_eq(catalog.weather_channel_for("water_main_break"), "", "water main reads no channel")
	assert_eq(catalog.weather_channel_for("storm_damage"), "", "storm damage reads no channel")


## Doc 06 §7 test 40 (RR-4 / C-59) — weather is city-wide global, so a
## generator reads its channel ONCE per sub-step and applies the same value to
## every candidate. A per-candidate read would show up as N reads.
func test_weather_is_global_in_generation() -> void:
	var world := _world()
	world.add_district("D1", 6000.0, 0.55, 0.5, 0.0)
	for i in 25:
		world.add_building("B%02d" % i, "house", 2, Vector2i(i, 5), "D1",
				{"fire_ignition_per_hour": 0.00019, "crime_weight": 1.0})
	var system := _system(world)
	world.channel_reads.clear()
	system._generate_structure_fire(1.0, 1.0)
	var ignition_reads := 0
	for channel in world.channel_reads:
		if String(channel) == "fire_ignition_mult":
			ignition_reads += 1
	assert_eq(ignition_reads, 1, "one get_effect read for 25 candidates")
	world.channel_reads.clear()
	system._generate_crime(1.0, 0.0, 1.0)
	var crime_reads := 0
	for channel in world.channel_reads:
		if String(channel) == "incident_crime_mult":
			crime_reads += 1
	assert_eq(crime_reads, 1, "one get_effect read for the whole crime generator")


func _sim_tree_text() -> String:
	return _read_tree("res://sim")


func _sim_tree_code() -> String:
	return _strip_comments_and_strings(_read_tree("res://sim"))


## Everything outside a comment and outside a quoted literal — i.e. the code a
## grep guard actually cares about.
static func _strip_comments_and_strings(text: String) -> String:
	var out := ""
	for raw_line in text.split("\n"):
		var line := String(raw_line)
		var hash_at := line.find("#")
		if hash_at >= 0:
			line = line.substr(0, hash_at)
		var stripped := ""
		var in_string := false
		var quote := ""
		var i := 0
		while i < line.length():
			var ch := line[i]
			if in_string:
				if ch == "\\":
					i += 2
					continue
				if ch == quote:
					in_string = false
			elif ch == "\"" or ch == "'":
				in_string = true
				quote = ch
			else:
				stripped += ch
			i += 1
		out += stripped + "\n"
	return out


func _read_tree(path: String) -> String:
	var out := ""
	var dir := DirAccess.open(path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := path + "/" + entry
		if dir.current_is_dir():
			out += _read_tree(full)
		elif entry.ends_with(".gd"):
			out += FileAccess.get_file_as_string(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out
