extends SimTest
## **Audit 91 D-17 / D-18, made executable** (filed as D-14 / D-15; renumbered
## 2026-08-19 — doc 91's defect table carried two D-14/D-15 pairs and the
## performance pair keeps the original ids).
##
## `IncidentWorld.water_mains()` and `IncidentWorld.road_intersections()` were
## base-class stubs returning `[]`, and `CityIncidentWorld` overrode NEITHER — so
## doc 06's water and traffic generators scanned an empty array on every
## integrator sub-step since the day they were written and produced **exactly
## zero** at every city size, independent of any rate. A third of doc 06 §2.6's
## generator surface, and the reason two of the five founding departments had no
## ambient work to answer (doc 92 §18.2).
##
## The fix was an adapter JOIN, not a number, so this file asserts the join: the
## rows exist, they are doc-06 shaped, they carry live values from doc 05 and doc
## 10, and the two verbs on the write side of the same seam land on real objects.
## `test_balance_gates.gd::test_gate_19_*` owns the RATE that comes out of them.

const HOUR := 1.0


func _sim() -> CitySim:
	return CitySim.boot_from_files(1337)


# ============================================================ D-17 — the mains

## Every field doc 06 §2.6(d) reads, on every candidate, from the live doc 05
## system. The starter city's authored topology (doc 09 §2.9.6) is 13 mains.
func test_water_mains_join_is_doc06_shaped() -> void:
	var sim := _sim()
	var rows := sim.incident_world.water_mains()
	assert_true(rows.size() > 0,
			"D-17: CityIncidentWorld.water_mains() is still returning [] — the "
			+ "water_main_break generator has no candidate source")
	var total_km := 0.0
	for entry in rows:
		var row: Dictionary = entry
		for key in ["id", "tile", "length_km", "condition", "pressure_ratio",
				"utilization", "freeze_stress", "zone"]:
			assert_true(row.has(key), "candidate row is missing `%s`" % key)
		assert_true(row["tile"] is Vector2i, "`tile` is a global tile")
		assert_true(float(row["length_km"]) > 0.0, "a zero-length main is not a main")
		assert_ne(String(row["zone"]), "", "every live main belongs to a pressure zone")
		total_km += float(row["length_km"])
	assert_almost_eq(total_km, sim.water.inventory()["main_km"], 1e-9,
			"doc 06 sees the same kilometres doc 03 bills for")


## The row's `id` is the id doc 05 answers to, and the tile is ON the main.
func test_water_main_row_addresses_the_real_segment() -> void:
	var sim := _sim()
	var row: Dictionary = sim.incident_world.water_mains()[0]
	var main: WaterEdge = sim.water.edge(String(row["id"]))
	assert_ne(main, null, "`id` round-trips to a live WaterEdge")
	assert_true(main.path.has(row["tile"]), "the candidate tile lies on the main")
	assert_almost_eq(float(row["length_km"]), main.length_km(), 1e-9)


## A floor cannot invent a target (doc 92 §18.1 property 2), and a main that is
## already broken is already somebody's incident.
func test_broken_and_isolated_mains_leave_the_candidate_set() -> void:
	var sim := _sim()
	var before := sim.incident_world.water_mains().size()
	var victim := String((sim.incident_world.water_mains()[0] as Dictionary)["id"])
	sim.water.set_segment_broken(victim, 0.6, "incident:1")
	var after := sim.incident_world.water_mains()
	assert_eq(after.size(), before - 1, "a broken main is not a candidate")
	for entry in after:
		assert_ne(String((entry as Dictionary)["id"]), victim)
	sim.water.set_segment_repaired(victim)
	assert_eq(sim.incident_world.water_mains().size(), before,
			"and it comes back when it is fixed")


## **C-46.** Doc 05 rolls its own main breaks only while nobody else does; the
## adapter that supplies the candidates is what claims the roll.
func test_doc06_claims_the_main_break_roll() -> void:
	var sim := _sim()
	assert_true(sim.water.external_main_breaks,
			"C-46: doc 06 owns the water_main_break roll once its adapter exists")
	# And a save written before the adapter did cannot un-claim it: the load is a
	# latch, because who rolls is a fact about the program, not about the city.
	var state: Dictionary = sim.water.serialize()
	(state["environment"] as Dictionary)["external_main_breaks"] = false
	sim.water.deserialize(state)
	assert_true(sim.water.external_main_breaks,
			"an old save must not switch doc 05's fallback back on underneath doc 06")


## The seam's write half. `severity <= 0` is its word for REPAIRED (doc 06 §2.7
## calls the same verb with zero on resolve), and the tiered pressure delta is
## parked on the segment doc 05 releases when the main is fixed.
func test_water_write_verbs_reach_doc05() -> void:
	var sim := _sim()
	var id := String((sim.incident_world.water_mains()[0] as Dictionary)["id"])
	sim.incident_world.water_set_segment_broken(id, 0.7, "incident:9")
	var main: WaterEdge = sim.water.edge(id)
	assert_true(main.is_broken(), "the segment is broken")
	assert_eq(main.owning_incident, "incident:9", "doc 06's incident holds it")

	sim.incident_world.water_zone_pressure_delta("WTR-1-PMP", -0.35, id)
	assert_almost_eq(main.incident_pressure_penalty, 0.35, 1e-9,
			"the tiered delta is held on the owning segment as a magnitude")

	sim.incident_world.water_set_segment_broken(id, 0.0)
	assert_false(sim.water.edge(id).is_broken(), "severity 0 means repaired")
	assert_almost_eq(sim.water.edge(id).incident_pressure_penalty, 0.0, 1e-9,
			"repairing the main releases doc 06's hold — a FAILED break cannot "
			+ "park a permanent penalty on a zone")


func test_zone_wide_pressure_hold_clears_on_zero() -> void:
	var sim := _sim()
	var zone := String((sim.incident_world.water_mains()[0] as Dictionary)["zone"])
	sim.incident_world.water_zone_pressure_delta(zone, -0.6)
	assert_true((sim.water._zone_incident_delta.get(zone, {}) as Dictionary).size() > 0,
			"a break with no identified main holds the delta zone-wide")
	sim.incident_world.water_zone_pressure_delta(zone, 0.0)
	assert_eq((sim.water._zone_incident_delta.get(zone, {}) as Dictionary).size(), 0,
			"and the same verb with zero releases it")


func test_freeze_flag_comes_from_doc05_not_a_doc06_guess() -> void:
	var sim := _sim()
	assert_eq(sim.incident_world.water_freeze_enabled(),
			bool(sim.water.data.flag("freeze_enabled")),
			"doc 05 §2.9's feature flag is the only answer (MVP: false)")


# ==================================================== D-18 — the intersections

## Every field doc 06 §2.6(e) reads, on every candidate, from the live doc 10
## graph — including the unsignalised nodes `signalised_intersections()` drops
## and doc 06 prices at `f_signal = 1.60`.
func test_road_intersections_join_is_doc06_shaped() -> void:
	var sim := _sim()
	var rows := sim.incident_world.road_intersections()
	assert_true(rows.size() > 0,
			"D-18: CityIncidentWorld.road_intersections() is still returning [] — "
			+ "the traffic_accident generator has no candidate source")
	var signalled := 0
	for entry in rows:
		var row: Dictionary = entry
		for key in ["id", "tile", "congestion_index", "signalised",
				"signal_powered", "condition_hazard_mult"]:
			assert_true(row.has(key), "candidate row is missing `%s`" % key)
		assert_true(row["tile"] is Vector2i, "`tile` is a global tile")
		assert_eq(sim.roads.graph.node_at(row["tile"]), int(row["node_id"]),
				"the row addresses the node that is actually on that tile")
		assert_true(float(row["condition_hazard_mult"]) >= 1.0,
				"doc 10's hazard multiplier is never below 1.00 (C-48)")
		if bool(row["signalised"]):
			signalled += 1
	assert_eq(signalled, sim.roads.signalised_intersections().size(),
			"the signalised subset agrees with the roster doc 06 reads dark_frac from")


## Every candidate is a real junction: doc 10 calls a degree-2 tile part of an
## edge, not an intersection, and an accident there has no approaches to block.
func test_every_candidate_is_a_junction() -> void:
	var sim := _sim()
	var seen: Dictionary = {}
	for entry in sim.incident_world.road_intersections():
		var row: Dictionary = entry
		var record: Dictionary = sim.roads.graph.node(int(row["node_id"]))
		assert_true(int(record["degree"]) >= 3, "degree ≥ 3 for every candidate")
		seen[int(row["node_id"])] = true
	for node_id in sim.roads.graph.node_ids_sorted():
		var record2: Dictionary = sim.roads.graph.node(int(node_id))
		if int(record2["degree"]) >= 3:
			assert_true(seen.has(int(node_id)),
					"node %d is a junction and is missing from the roster" % int(node_id))


## Doc 06 §2.6(e): "the collision happens on the worst approach". Both per-node
## scalars are the MAX over incident edges, not the mean.
func test_node_scalars_are_the_worst_approach() -> void:
	var sim := _sim()
	var rows := sim.incident_world.road_intersections()
	var row: Dictionary = rows[0]
	var record: Dictionary = sim.roads.graph.node(int(row["node_id"]))
	# Decay ONE approach and leave the others pristine; the node must follow the
	# worst one. 0.10 → 1 + 0.40 × 0.65 = 1.26 (doc 10 §2.11's own worked value).
	var edge_id := int((record["edge_ids"] as Array)[0])
	for tile in sim.roads.graph.edge(edge_id)["tiles"]:
		sim.roads.set_condition(tile, 0.10)
	var after: Dictionary = (sim.incident_world.road_intersections()[0] as Dictionary)
	assert_almost_eq(float(after["condition_hazard_mult"]), 1.26, 1e-6,
			"one failing approach sets the whole node's hazard multiplier")
	var worst := 0.0
	for other in record["edge_ids"]:
		worst = maxf(worst, sim.roads.congestion_index(int(other)))
	assert_almost_eq(float(after["congestion_index"]), worst, 1e-9,
			"congestion is the worst approach too, for the same reason")


## The roster is a cache keyed on `graph_version`, and doc 06 scans it sixty
## times a game-hour. A road built underneath it must not be invisible.
func test_roster_follows_the_graph() -> void:
	var sim := _sim()
	var before := sim.incident_world.road_intersections().size()
	assert_eq(sim.incident_world.road_intersections().size(), before,
			"a second read with no graph edit is the same roster")
	# Lifting the junction tile itself drops the node entirely.
	var row: Dictionary = (sim.incident_world.road_intersections()[0] as Dictionary)
	var tile: Vector2i = row["tile"]
	sim.roads.edit_tile(tile, RoadTunables.CLASS_NONE)
	sim.advance_coarse_hours(1, false)   # the real path that flushes the edit
	assert_ne(sim.roads.graph.graph_version, 0, "the graph re-traced")
	var after := sim.incident_world.road_intersections()
	assert_true(after.size() < before, "the roster tracked the edit")
	for entry in after:
		assert_ne((entry as Dictionary)["tile"], tile,
				"a demolished junction is not still a candidate")


# ======================================================== the write half (§3.1)

## Doc 06 addresses a TILE and doc 10 closes an EDGE; the adapter resolves one to
## the other and the closure really lands.
func test_edge_close_and_speed_override_land_on_a_real_edge() -> void:
	var sim := _sim()
	var row: Dictionary = (sim.incident_world.road_intersections()[0] as Dictionary)
	var tile: Vector2i = row["tile"]
	var before := sim.roads.active_closure_count()
	sim.incident_world.road_close_edge(tile, 1.0, "traffic_accident")
	assert_eq(sim.roads.active_closure_count(), before + 1,
			"the blocked_road verb produced a doc 10 closure")
	var closure_id: int = int(sim.roads.closure_ids_sorted()[before])
	var closure: Dictionary = sim.roads.closure(closure_id)
	assert_eq(String(closure["cause"]), "accident_major",
			"doc 06's incident maps onto doc 10's own closure-cause table")
	assert_eq(int(closure["expected_end_minute"]) - int(closure["start_minute"]), 60,
			"duration_h 1.0 is 60 game-minutes")

	sim.incident_world.road_set_edge_speed_mult(tile, 0.3)
	var edge_id := _slowed_edge_at(sim, tile)
	assert_true(edge_id >= 0, "the escalation tier slowed one of the approaches down")
	assert_true(int(sim.roads.graph.edge(edge_id)["override_until_minute"]) > 0,
			"the override carries an expiry, so an ABANDONED accident cannot "
			+ "leave a street permanently slow")
	sim.incident_world.road_set_edge_speed_mult(tile, 1.0)
	assert_almost_eq(float(sim.roads.graph.edge(edge_id)["speed_override"]), 1.0, 1e-9,
			"and doc 06 restores it on resolve")


func _slowed_edge_at(sim: CitySim, tile: Vector2i) -> int:
	for edge_id in sim.roads.graph.edges_at(tile):
		if absf(float(sim.roads.graph.edge(int(edge_id))["speed_override"]) - 0.3) < 1e-9:
			return int(edge_id)
	return -1


## A water main break floods the street; doc 10 §5's interface table already
## says what that is, and it is not an accident.
func test_closure_cause_follows_the_incident() -> void:
	var sim := _sim()
	var tile: Vector2i = (sim.incident_world.road_intersections()[0]
			as Dictionary)["tile"]
	sim.incident_world.road_close_edge(tile, 0.0, "water_main_break")
	var closure: Dictionary = sim.roads.closure(
			int(sim.roads.closure_ids_sorted()[0]))
	assert_eq(String(closure["cause"]), "flood_shallow",
			"a broken main floods the street it is under")


# ============================== the consequence ladder, on a stub (doc 06 §3.1)

## `data/incidents.json` gives `traffic_accident` four `on_tier_enter` rows and
## an `on_fail`, and until D-18 landed **none of them had ever executed** — the
## incident that fires them could not be generated. Same shape as doc 06 §7 test
## 20 for the transformer ladder.
func _stub() -> IncidentTestWorld:
	var world := IncidentTestWorld.new()
	world.add_district("D1", 4000.0, 0.6)
	world.intersections = [{"id": "N-1", "tile": Vector2i(20, 20),
			"congestion_index": 1.2, "signalised": true, "signal_powered": false,
			"condition_hazard_mult": 1.26}]
	return world


func _stub_system(world: IncidentTestWorld) -> IncidentSystem:
	var system := IncidentSystem.new(IncidentCatalog.load_from_files(), world,
			RngStreams.new(1337))
	system.generation_enabled = false
	return system


func test_traffic_accident_consequence_ladder_fires() -> void:
	var world := _stub()
	var system := _stub_system(world)
	var inc := system.spawn("traffic_accident", "", Vector2i(20, 20),
			{"kind": "intersection", "id": "N-1"}, 1.0, {"source": "test"}, "D1")
	assert_ne(inc, null, "the accident spawned")
	inc.context["congestion_index"] = 1.2
	# A BAD one. `self_resolve_h` is 1.0 while the tier is ≤ 2, so an accident
	# that starts minor and is never answered is abandoned before it can reach
	# the closure tiers — which is the design, and is what the next test covers.
	# This one starts severe enough to climb out of that window.
	inc.severity = 2.9
	for minute in 600:
		system.advance_to(float(minute + 1) / 60.0)
		if inc.tier() >= 4:
			break
	assert_true(inc.tier() >= 4, "escalated with no response")
	assert_true(inc.tiers_fired.has(2) and inc.tiers_fired.has(3),
			"the two edge_speed_mult tiers fired: %s" % str(inc.tiers_fired))
	assert_true(world.edge_speed.size() >= 2, "T2 = 0.6 then T3 = 0.3, once each")
	assert_almost_eq(float(world.edge_speed[0]["mult"]), 0.6, 1e-9)
	assert_almost_eq(float(world.edge_speed[1]["mult"]), 0.3, 1e-9)
	assert_true(world.edge_closed.size() >= 1, "T4 closes the segment")
	assert_eq(world.edge_closed[0]["tile"], Vector2i(20, 20),
			"on the intersection the accident is at")
	assert_eq(String(world.edge_closed[0]["cause"]), "traffic_accident",
			"and doc 06 names the incident so doc 10 can price the closure")
	assert_true(world.stability_deltas.size() > 0, "T4 also costs the district")


## The ABANDONED branch: nobody came, the wreck sits in the road for a game-hour
## and the city's confidence takes the hit.
func test_traffic_accident_abandonment_closes_the_road() -> void:
	var world := _stub()
	var system := _stub_system(world)
	var inc := system.spawn("traffic_accident", "", Vector2i(20, 20),
			{"kind": "intersection", "id": "N-1"}, 1.0, {"source": "test"}, "D1")
	# `self_resolve_h` is 1.0 with `self_resolve_max_tier` 2, so an accident that
	# is never dispatched to and never escalates past T2 is abandoned at 1 gh.
	system.advance_to(1.5)
	if inc.status == Incident.STATUS_ABANDONED:
		var closed := false
		for row in world.edge_closed:
			if float((row as Dictionary)["duration_h"]) == 1.0:
				closed = true
		assert_true(closed, "on_fail closes the segment for 1.0 game-hour")
		assert_true(world.confidence_deltas.size() > 0, "and costs city confidence")
	else:
		# It escalated past tier 2 instead, which is the other legal outcome; the
		# ladder test above owns that branch.
		assert_true(inc.tier() > 2,
				"an accident either self-resolves out or escalates past T2")


## The resolution effect: doc 06 hands the street back at full speed.
func test_resolved_accident_restores_the_street() -> void:
	var world := _stub()
	var system := _stub_system(world)
	var inc := system.spawn("traffic_accident", "", Vector2i(20, 20),
			{"kind": "intersection", "id": "N-1"}, 1.0, {"source": "test"}, "D1")
	inc.status = Incident.STATUS_ACTIVE   # a unit is on scene and working
	inc.progress = 1.0
	system.advance_to(1.0 / 60.0)
	assert_eq(inc.status, Incident.STATUS_RESOLVED, "the accident cleared")
	assert_true(world.edge_speed.size() > 0, "the street was handed back")
	assert_almost_eq(float(world.edge_speed[world.edge_speed.size() - 1]["mult"]),
			1.0, 1e-9, "at full speed")
