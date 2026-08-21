extends SimTest
## Doc 06 §7 dispatch tests: the §2.9 priority ordering that "defines the game",
## nearest-available assignment, the reassignment threshold, manual lock,
## reserves, construction preemption, unreachability — and the determinism the
## constitution requires of all of it.


## A doc-10 stand-in that can make one approach slow, so the "choice flips
## under congestion" case is testable before the real router lands.
class PenaltyTravel extends TravelTimeProvider:
	var penalties: Dictionary = {}  # "x,y" -> extra game-seconds

	func travel_gs(from: Vector2i, to: Vector2i, profile: Dictionary = {}) -> int:
		var base := super.travel_gs(from, to, profile)
		if base >= TravelTimeProvider.UNREACHABLE_GS:
			return base
		return base + int(penalties.get(TravelTimeProvider._key(from), 0))


func _system(world: IncidentTestWorld, travel: TravelTimeProvider = null,
		seed_value: int = 4242) -> IncidentSystem:
	var system := IncidentSystem.new(IncidentCatalog.load_from_files(), world,
			RngStreams.new(seed_value), travel)
	system.generation_enabled = false
	return system


func _basic_world() -> IncidentTestWorld:
	var world := IncidentTestWorld.new()
	world.add_district("D1", 5000.0, 0.55, 0.5, 0.0)
	return world


## Doc 06 §7 test 10 — the four §2.9 worked incidents sort
## 575.5 / 370.0 / 354.6 / 338.0. That reads correctly to a human, which is
## the test.
func test_priority_ordering() -> void:
	var world := _basic_world()
	world.add_district("D2", 5000.0, 0.30, 0.5, 0.0)
	world.add_building("HR", "high_rise", 3, Vector2i(20, 20), "D1",
			{"fire_load": 280.0, "occupants": 320.0})
	world.add_component("T-9", Vector2i(30, 30),
			{"customers_downstream": 800, "critical_downstream": true})
	var system := _system(world)
	system.now_h = 10.0

	var fire := system.spawn("structure_fire", "", Vector2i(20, 20),
			{"kind": "building", "id": "HR"}, 3.0)
	fire.created_h = system.now_h - 0.2
	fire.context["occupants"] = 320.0
	fire.context["neighbour_occupants"] = 50.0

	var transformer := system.spawn("transformer_failure", "", Vector2i(30, 30),
			{"kind": "power_component", "id": "T-9"}, 2.0)
	transformer.created_h = system.now_h - 0.5

	var crime := system.spawn("crime", "", Vector2i(5, 5), {}, 4.0, {}, "D2")
	crime.created_h = system.now_h - 1.5
	crime.context["district_pop"] = 5000.0
	crime.context["stability"] = 0.30

	var accident := system.spawn("traffic_accident", "", Vector2i(8, 8), {}, 1.0)
	accident.created_h = system.now_h - 0.1
	accident.context["injury"] = true
	accident.context["congestion_index"] = 0.75

	assert_almost_eq(system.dispatch.priority(fire, 1, system.now_h), 575.5, 0.05, "high-rise fire")
	assert_almost_eq(system.dispatch.priority(transformer, 1, system.now_h), 370.0, 0.05,
			"transformer feeding a hospital")
	assert_almost_eq(system.dispatch.priority(crime, 1, system.now_h), 354.6, 0.05, "riot-adjacent crime")
	assert_almost_eq(system.dispatch.priority(accident, 1, system.now_h), 338.0, 0.05,
			"traffic accident with injury")
	# Pin and cluster bonuses ride on top without disturbing the base score.
	fire.pinned = true
	assert_almost_eq(system.dispatch.priority(fire, 1, system.now_h), 1075.5, 0.05, "PIN_BONUS 500")
	fire.pinned = false
	assert_almost_eq(system.dispatch.priority(fire, 3, system.now_h), 575.5 + 50.0, 0.05,
			"CLUSTER_BONUS 25 × (n − 1)")


## Doc 06 §7 test 11 — three stations, one incident: the minimum-ETA unit wins;
## slow the near approach and the choice flips.
func test_nearest_unit_assignment() -> void:
	var world := _basic_world()
	world.add_building("B1", "house", 2, Vector2i(20, 20), "D1", {"fire_load": 40.0})
	var travel := PenaltyTravel.new()
	var system := _system(world, travel)
	system.fleet.populate_from_stations([
		{"id": "FIRE-NEAR", "archetype": "fire_station", "level": 1, "tile": Vector2i(22, 20)},
		{"id": "FIRE-MID", "archetype": "fire_station", "level": 1, "tile": Vector2i(30, 20)},
		{"id": "FIRE-FAR", "archetype": "fire_station", "level": 1, "tile": Vector2i(40, 20)},
	])
	var inc := system.spawn("structure_fire", "", Vector2i(20, 20),
			{"kind": "building", "id": "B1"}, 1.0)
	system.advance_to(1.0 / 60.0)
	assert_eq(inc.assigned_unit_ids().size(), 1, "exactly one engine assigned")
	var chosen: Vehicle = system.fleet.unit(int(inc.assigned_unit_ids()[0]))
	assert_eq(chosen.home_station_id, "FIRE-NEAR", "the nearest engine answered")

	# Same city, but the near station's approach is congested.
	var travel2 := PenaltyTravel.new()
	travel2.penalties[TravelTimeProvider._key(Vector2i(22, 20))] = 3000
	var world2 := _basic_world()
	world2.add_building("B1", "house", 2, Vector2i(20, 20), "D1", {"fire_load": 40.0})
	var system2 := _system(world2, travel2)
	system2.fleet.populate_from_stations([
		{"id": "FIRE-NEAR", "archetype": "fire_station", "level": 1, "tile": Vector2i(22, 20)},
		{"id": "FIRE-MID", "archetype": "fire_station", "level": 1, "tile": Vector2i(30, 20)},
		{"id": "FIRE-FAR", "archetype": "fire_station", "level": 1, "tile": Vector2i(40, 20)},
	])
	var inc2 := system2.spawn("structure_fire", "", Vector2i(20, 20),
			{"kind": "building", "id": "B1"}, 1.0)
	system2.advance_to(1.0 / 60.0)
	assert_eq(inc2.assigned_unit_ids().size(), 1, "still exactly one engine")
	var chosen2: Vehicle = system2.fleet.unit(int(inc2.assigned_unit_ids()[0]))
	assert_eq(chosen2.home_station_id, "FIRE-MID", "congestion on the near route flips the choice")


## Doc 06 §7 test 12 — 5 incidents, 1 unit: one ASSIGNED, four QUEUED, all four
## escalate, `dispatch_blocked_no_units` emitted.
func test_no_units_queues() -> void:
	var world := _basic_world()
	var system := _system(world)
	system.fleet.populate_from_stations([{"id": "POL-1", "archetype": "police_station",
			"level": 1, "tile": Vector2i(0, 0)}])
	# One patrol car only.
	while system.fleet.size() > 1:
		system.fleet.remove_unit(int(system.fleet.unit_ids()[system.fleet.size() - 1]))
	var incidents: Array = []
	for i in 5:
		incidents.append(system.spawn("crime", "", Vector2i(4 + i, 4), {}, 1.5, {}, "D1"))
	var before: Array = []
	for inc in incidents:
		before.append((inc as Incident).severity)
	system.advance_to(0.2)
	var assigned := 0
	var queued := 0
	for inc in incidents:
		var incident: Incident = inc
		if incident.assigned_unit_ids().is_empty():
			queued += 1
			assert_true(incident.status == Incident.STATUS_QUEUED, "unstaffed incident stays QUEUED")
		else:
			assigned += 1
	assert_eq(assigned, 1, "exactly one incident got the only car")
	assert_eq(queued, 4, "four stay queued")
	var blocked := 0
	for event in system.drain_events():
		if String(event.get("type", "")) == "dispatch_blocked_no_units":
			blocked += 1
	assert_true(blocked > 0, "dispatch_blocked_no_units emitted")
	for i in 5:
		assert_true((incidents[i] as Incident).severity > float(before[i]),
				"queued incident %d escalated" % i)


## Doc 06 §7 test 13 — Δ ≥ 120 pulls a responding unit; Δ = 100 does not.
func test_reassignment_threshold() -> void:
	for delta in [130.0, 100.0]:
		var world := _basic_world()
		var system := _system(world)
		system.fleet.populate_from_stations([{"id": "POL-1", "archetype": "police_station",
				"level": 1, "tile": Vector2i(0, 0)}])
		while system.fleet.size() > 1:
			system.fleet.remove_unit(int(system.fleet.unit_ids()[system.fleet.size() - 1]))
		var low := system.spawn("crime", "", Vector2i(6, 0), {}, 1.5, {}, "D1")
		low.priority_cache = 300.0
		system.dispatch.assign_tick([low], 0.0)
		var unit: Vehicle = system.fleet.unit(int(system.fleet.unit_ids()[0]))
		assert_eq(unit.incident_id, low.id, "car en route to the low-priority call")
		var high := system.spawn("crime", "", Vector2i(7, 0), {}, 1.5, {}, "D1")
		high.priority_cache = 300.0 + delta
		low.priority_cache = 300.0
		system.dispatch.assign_tick([high, low], 0.0)
		if delta >= 120.0:
			assert_eq(unit.incident_id, high.id, "Δ=130 ≥ REASSIGN_THRESHOLD pulls the car")
			assert_false(low.assigned.has(unit.id), "the old incident released the car")
			assert_eq(low.status, Incident.STATUS_QUEUED, "and dropped back to QUEUED")
		else:
			assert_eq(unit.incident_id, low.id, "Δ=100 < REASSIGN_THRESHOLD leaves it alone")


## Doc 06 §7 test 14 — a manually dispatched unit is never reassigned, even by
## a tier-5 fire; cmd_recall_unit releases it.
func test_manual_lock() -> void:
	var world := _basic_world()
	world.add_building("B1", "house", 2, Vector2i(30, 0), "D1", {"fire_load": 40.0})
	var system := _system(world)
	system.fleet.populate_from_stations([{"id": "POL-1", "archetype": "police_station",
			"level": 1, "tile": Vector2i(0, 0)}])
	while system.fleet.size() > 1:
		system.fleet.remove_unit(int(system.fleet.unit_ids()[system.fleet.size() - 1]))
	var minor := system.spawn("crime", "", Vector2i(4, 0), {}, 1.2, {}, "D1")
	var unit_id := int(system.fleet.unit_ids()[0])
	var result := system.dispatch.cmd_dispatch_unit(unit_id, minor.id, 0.0)
	assert_true(bool(result["ok"]), "manual dispatch accepted")
	var unit: Vehicle = system.fleet.unit(unit_id)
	assert_true(unit.manual_lock, "manual_lock set")
	var inferno := system.spawn("structure_fire", "", Vector2i(30, 0),
			{"kind": "building", "id": "B1"}, 4.99)
	inferno.priority_cache = 5000.0
	minor.priority_cache = 10.0
	system.dispatch.assign_tick([inferno, minor], 0.0)
	assert_eq(unit.incident_id, minor.id, "even a tier-5 fire cannot strip a locked unit")
	assert_true(bool(system.dispatch.cmd_recall_unit(unit_id)["ok"]), "recall accepted")
	assert_eq(unit.status, Vehicle.RETURNING, "recalled unit is heading home")
	assert_false(unit.manual_lock, "lock cleared on recall")
	assert_false(minor.assigned.has(unit_id), "incident released the unit")
	# …and a second recall is refused rather than answered `ok` for a no-op:
	# `FleetSystem.recall` already does nothing to a unit that is on its way home,
	# and a door whose command says yes to nothing is a door that lies (A91-D-24
	# gave this verb its first caller — doc 12 §2.6's unit chips).
	var again := system.dispatch.cmd_recall_unit(unit_id)
	assert_false(bool(again["ok"]), "a RETURNING unit cannot be recalled again")
	assert_eq(String(again["reason_code"]), "E_UNIT_NOT_DEPLOYED")
	assert_eq(str((again["payload"] as Dictionary)["status"]), Vehicle.RETURNING,
			"and the refusal names the state it refused for")
	assert_false(bool(system.dispatch.cmd_recall_unit(9999)["ok"]),
			"an unknown unit is still E_UNKNOWN_UNIT")


## Doc 06 §7 test 15 — with fire_reserve_units = 1 and two engines, a tier-2
## fire takes one; a tier-4 fire takes both.
func test_fire_reserve() -> void:
	for tier in [2, 4]:
		var world := _basic_world()
		world.add_building("AP", "apartment", 4, Vector2i(10, 0), "D1", {"fire_load": 360.0})
		var system := _system(world)
		system.fleet.populate_from_stations([{"id": "FIRE-1", "archetype": "fire_station",
				"level": 2, "tile": Vector2i(0, 0)}])
		assert_eq(system.fleet.size(), 2, "an L2 fire station houses two engines")
		assert_eq(system.policy.get_int("fire_reserve_units", -1), 1, "reserve default is 1")
		var inc := system.spawn("structure_fire", "", Vector2i(10, 0),
				{"kind": "building", "id": "AP"}, float(tier) + 0.2)
		system.advance_to(1.0 / 60.0)
		if tier == 2:
			assert_eq(inc.assigned_unit_ids().size(), 1,
					"the reserve engine stays at station below reserve_break_tier")
		else:
			assert_eq(inc.assigned_unit_ids().size(), 2,
					"at tier 4 the reserve may be committed")


## Doc 06 §7 test 35 (G-2) — crews default to manual, and a crew on a doc 02
## job is preempted only above priority 400.
func test_construction_preempt_and_default() -> void:
	var world := _basic_world()
	var system := _system(world)
	assert_false(system.policy.get_bool("auto_dispatch_construction", true),
			"auto_dispatch_construction defaults false (G-2)")
	system.fleet.populate_from_stations([{"id": "YARD-1", "archetype": "construction_yard",
			"level": 1, "tile": Vector2i(0, 0)}])
	var crew: Vehicle = system.fleet.unit(int(system.fleet.unit_ids()[0]))
	crew.construction_job_id = 77
	var inc := system.spawn("storm_damage", "blocked_road", Vector2i(6, 0), {}, 2.0)
	# Policy blocks it entirely while crews belong to the build queue.
	inc.priority_cache = 900.0
	system.dispatch.assign_tick([inc], 0.0)
	assert_eq(crew.construction_job_id, 77, "policy default keeps the crew on its job")
	system.dispatch.cmd_set_policy("auto_dispatch_construction", true)
	inc.priority_cache = 399.0
	system.dispatch.assign_tick([inc], 0.0)
	assert_eq(crew.construction_job_id, 77, "below 400 the crew is not preempted")
	inc.priority_cache = 401.0
	system.dispatch.assign_tick([inc], 0.0)
	assert_eq(crew.construction_job_id, 0, "above 400 the crew is preempted")
	assert_eq(world.released_jobs.size(), 1, "doc 02's job was released, not lost")
	assert_eq(int(world.released_jobs[0]["job_id"]), 77, "the right job")
	var preempted := 0
	for event in system.drain_events():
		if String(event.get("type", "")) == "construction_job_preempted":
			preempted += 1
	assert_eq(preempted, 1, "construction_job_preempted emitted exactly once")


## Doc 06 §7 test 17 — no route ⇒ no assignment, an event, and the incident
## keeps escalating.
func test_unreachable() -> void:
	var world := _basic_world()
	world.add_building("B1", "house", 2, Vector2i(20, 20), "D1", {"fire_load": 40.0})
	var travel := TravelTimeProvider.new()
	travel.set_unreachable(Vector2i(20, 20))
	var system := _system(world, travel)
	system.fleet.populate_from_stations([{"id": "FIRE-1", "archetype": "fire_station",
			"level": 1, "tile": Vector2i(0, 0)}])
	var inc := system.spawn("structure_fire", "", Vector2i(20, 20),
			{"kind": "building", "id": "B1"}, 1.0)
	var before := inc.severity
	system.advance_to(0.2)
	assert_true(inc.assigned_unit_ids().is_empty(), "no unit assigned")
	assert_true(inc.unreachable, "incident flagged unreachable for the UI")
	assert_true(inc.severity > before, "and it still escalates")
	var blocked := 0
	for event in system.drain_events():
		if String(event.get("type", "")) == "dispatch_blocked_unreachable":
			blocked += 1
	assert_true(blocked > 0, "dispatch_blocked_unreachable emitted")


## Doc 06 §7 test 36 (C-50) — doc 06 owns unit capacity per station level, and
## doc 02's data carries no unit_slots / crew_slots key.
func test_station_capacity_ladders() -> void:
	var catalog := IncidentCatalog.load_from_files()
	assert_eq(catalog.vehicle_type("police_patrol").get("capacity_per_station_level"),
			[2, 3, 4, 5, 6], "police ladder")
	for type_id in ["fire_engine", "utility_service_truck", "water_repair_truck",
			"construction_crew_vehicle"]:
		assert_eq(catalog.vehicle_type(type_id).get("capacity_per_station_level"),
				[1, 2, 3, 4, 5], "%s ladder" % type_id)
	# The keys must be absent from the DATA (they survive only in doc 02's own
	# forbidden-key guard list, which is where they belong).
	var archetypes := JSON.stringify(
			StarterCityLoader.read_json("res://data/buildings.json").get("archetypes", {}))
	assert_false(archetypes.contains("unit_slots"), "no archetype carries unit_slots")
	assert_false(archetypes.contains("crew_slots"), "no archetype carries crew_slots")
	# And the ladder actually populates.
	var world := _basic_world()
	var system := _system(world)
	system.fleet.populate_from_stations([
		{"id": "POL-1", "archetype": "police_station", "level": 3, "tile": Vector2i(0, 0)},
		{"id": "FIRE-1", "archetype": "fire_station", "level": 1, "tile": Vector2i(4, 0)},
	])
	assert_eq(system.fleet.size(), 5, "L3 police (4) + L1 fire (1)")


## Doc 06 §7 test 31 (C-49) — RouteProfile has exactly four fields, and no
## weather or flood multiplier survives anywhere in doc 06's data or code.
func test_route_profile_fields() -> void:
	var catalog := IncidentCatalog.load_from_files()
	var fields: Array = StarterCityLoader.read_json("res://data/dispatch.json") \
			.get("route_profile_fields", [])
	assert_eq(fields.size(), 4, "exactly four RouteProfile fields")
	var unit := Vehicle.from_type(1, catalog.vehicle_type("fire_engine"), "FIRE-1", Vector2i.ZERO)
	var profile := unit.route_profile(true)
	for field in ["speed_mpgm", "siren", "ignores_closures", "capabilities"]:
		assert_true(profile.has(field), "profile carries %s" % field)
	assert_false(profile.has("weather_mult"), "no weather_mult (C-49)")
	assert_false(profile.has("flood_mult"), "no flood_mult (C-49)")


## Constitution §5 — the same save and the same elapsed time produce the same
## dispatch decisions, run after run.
func test_dispatch_choice_is_deterministic() -> void:
	var first := _run_dispatch_scenario()
	var second := _run_dispatch_scenario()
	assert_eq(first.size(), second.size(), "same number of dispatch decisions")
	assert_true(first.size() > 0, "the scenario actually dispatched something")
	for i in first.size():
		assert_eq(String(first[i]), String(second[i]), "decision %d identical" % i)


func _run_dispatch_scenario() -> Array:
	var world := _basic_world()
	for i in 4:
		world.add_building("B%d" % i, "house", 2, Vector2i(20 + i * 3, 20), "D1",
				{"fire_load": 40.0, "occupants": 6.0})
	var system := _system(world, TravelTimeProvider.new(), 90210)
	system.fleet.populate_from_stations([
		{"id": "FIRE-1", "archetype": "fire_station", "level": 2, "tile": Vector2i(10, 20)},
		{"id": "POL-1", "archetype": "police_station", "level": 1, "tile": Vector2i(12, 22)},
	])
	for i in 4:
		system.spawn("structure_fire", "", Vector2i(20 + i * 3, 20),
				{"kind": "building", "id": "B%d" % i}, 1.5 + 0.4 * float(i))
	var log: Array = []
	for minute in 60:
		system.advance_to(float(minute + 1) / 60.0)
		for event in system.drain_events():
			var event_type := String(event.get("type", ""))
			if event_type == "unit_dispatched" or event_type == "unit_arrived":
				log.append("%s:%d:%s" % [event_type, int(event.get("unit_id", 0)),
						str(event.get("incident_id", 0))])
	return log


## Doc 06 §7 test 3 — DispatchPolicy.allows() is ONE function with no
## offline-only branch: the same inputs give the same call sequence and the
## same results whether or not the offline driver is running.
func test_policy_identical_both_paths() -> void:
	var online := _trace_policy(false)
	var offline := _trace_policy(true)
	assert_eq(online.size(), offline.size(), "same number of policy evaluations")
	assert_true(online.size() > 0, "the policy was actually consulted")
	for i in online.size():
		assert_eq(String(online[i]), String(offline[i]), "policy call %d identical" % i)


func _trace_policy(offline: bool) -> Array:
	var world := _basic_world()
	world.offline = offline
	world.add_building("B1", "house", 2, Vector2i(20, 20), "D1", {"fire_load": 40.0})
	var system := _system(world)
	system.policy.trace_enabled = true
	system.fleet.populate_from_stations([
		{"id": "FIRE-1", "archetype": "fire_station", "level": 2, "tile": Vector2i(10, 20)},
		{"id": "POL-1", "archetype": "police_station", "level": 1, "tile": Vector2i(12, 22)},
	])
	system.spawn("structure_fire", "", Vector2i(20, 20), {"kind": "building", "id": "B1"}, 2.0)
	system.spawn("crime", "", Vector2i(14, 20), {}, 2.0, {}, "D1")
	system.advance_to(0.1)
	var out: Array = []
	for row in system.policy.trace:
		out.append("%d:%d:%s" % [int(row["unit_id"]), int(row["incident_id"]),
				str(row["result"])])
	return out
