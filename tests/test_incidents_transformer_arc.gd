extends SimTest
## The Milestone 3 deliverable, end to end on the REAL starter city:
##
##   TUT_TRANSFORMER_FAIL → T-04 opens → six-ish customers go dark →
##   the incident is filed → a utility truck is dispatched by travel time →
##   it drives, arrives, works → the incident resolves → doc 04 closes the
##   component → the block relights.
##
## Nothing here is stubbed except the systems that genuinely have not landed
## (doc 05 hydrants, doc 07 weather, doc 10 routing), and each of those returns
## its documented neutral value.

const MAX_MINUTES := 240


## The exact PhaseSystem the integration patch adds to CitySim, verified here
## against the real TickScheduler so the lead engineer's paste is known-good.
## In CitySim it reaches through `sim.incidents` / `sim.incident_world`; here it
## carries its own references because CitySim does not own them yet.
class IncidentPhaseSystem extends SimSystem:
	var system: IncidentSystem
	var world: CityIncidentWorld
	var bus: SimEventBus

	func _init(p_system: IncidentSystem, p_world: CityIncidentWorld,
			p_bus: SimEventBus) -> void:
		system = p_system
		world = p_world
		bus = p_bus

	func system_id() -> StringName:
		return &"incidents"

	func phase() -> int:
		return Phase.INCIDENTS

	func cadence() -> int:
		return Cadence.EVERY_MINUTE

	func advance_fine(ctx: TimeContext) -> void:
		_run(ctx, period_ticks())

	func advance_coarse(ctx: TimeContext) -> void:
		_run(ctx, GameClock.TICKS_PER_HOUR)

	func _run(ctx: TimeContext, step_ticks: int) -> void:
		# The only path by which doc 06 learns it is offline (doc 08 rule 4).
		world.offline = ctx.is_catchup
		# Absolute game-hours, never an accumulated delta: `tick_index` is an
		# exact integer, so the fine and coarse paths land on the same hour
		# boundaries instead of drifting apart 1/60 at a time.
		system.advance_to(float(ctx.tick_index + step_ticks)
				/ float(GameClock.TICKS_PER_HOUR))
		for event in system.drain_events():
			bus.emit(StringName(String(event["type"])), event)


func _boot() -> Dictionary:
	var sim := CitySim.boot_from_files(1337)
	var catalog := IncidentCatalog.load_from_files()
	var world := CityIncidentWorld.new(sim, catalog)
	var system := IncidentSystem.new(catalog, world, sim.rng)
	system.founding_offset_h = float(GameClock.FOUNDING_OFFSET_MINUTES) / 60.0
	system.fleet.populate_from_stations(world.station_rows())
	return {"sim": sim, "world": world, "system": system, "catalog": catalog}


## One game-minute of the whole city: CitySim's four ticks, then the incident
## engine caught up to the same absolute game-hour. This is exactly what the
## IncidentPhaseSystem in the integration patch does.
func _step_minute(rig: Dictionary) -> void:
	var sim: CitySim = rig["sim"]
	var system: IncidentSystem = rig["system"]
	var world: CityIncidentWorld = rig["world"]
	world.offline = false
	sim.advance_hours(1.0 / 60.0)
	system.advance_to(float(sim.clock.tick_index) / float(GameClock.TICKS_PER_HOUR))


func test_starter_city_boots_with_a_fleet() -> void:
	var rig := _boot()
	var sim: CitySim = rig["sim"]
	var system: IncidentSystem = rig["system"]
	assert_true(sim.boot_errors.is_empty(), "starter city boots clean: %s" % str(sim.boot_errors))
	assert_true(system.fleet.size() > 0, "the starter city has a fleet")
	var by_department: Dictionary = {}
	for unit_id in system.fleet.unit_ids():
		var u: Vehicle = system.fleet.unit(unit_id)
		by_department[u.department] = int(by_department.get(u.department, 0)) + 1
	# Doc 06 §2.11's ladders against doc 09's authored stations: POL-1 L1 → 2
	# patrol, FIRE-1 L1 → 1 engine, SUB-A + PLANT-1 → 2 utility,
	# WTR-1 + WTR-2 → 2 water, YARD-1 → 1 crew.
	assert_eq(int(by_department.get("police", 0)), 2, "two patrol cars")
	assert_eq(int(by_department.get("fire", 0)), 1, "one engine")
	assert_eq(int(by_department.get("utility", 0)), 2, "two utility trucks")
	assert_eq(int(by_department.get("water", 0)), 2, "two water trucks")
	assert_eq(int(by_department.get("construction", 0)), 1, "one construction crew")
	for unit_id in system.fleet.unit_ids():
		var u: Vehicle = system.fleet.unit(unit_id)
		assert_eq(u.status, Vehicle.IDLE, "every unit starts idle")
		assert_true(u.tile != Vector2i.ZERO, "and parked at its station")


## The full arc. This is the test Milestone 3 signs off against.
func test_transformer_fail_dispatch_repair_power_restored() -> void:
	var rig := _boot()
	var sim: CitySim = rig["sim"]
	var system: IncidentSystem = rig["system"]

	# Settle the grid so every customer is genuinely LIT before we break it.
	for i in 5:
		_step_minute(rig)
	var customers := _customers_of(sim, "T-04")
	assert_true(customers.size() >= 3, "T-04 actually serves customers, got %d" % customers.size())
	for building_id in customers:
		assert_true(sim.grid.is_powered(String(building_id)),
				"%s is lit before the failure" % building_id)

	# --- the scripted failure, addressed by TAG, never by raw id (doc 09 §2.9.7)
	var inc := system.spawn_scripted_from_tag(sim.loader, "transformer_fail")
	assert_ne(inc, null, "TUT_TRANSFORMER_FAIL resolved and filed an incident")
	assert_eq(inc.type, "transformer_failure", "it is a transformer failure")
	assert_eq(inc.target_component_id(), "T-04", "on the tutorial transformer")
	assert_eq(inc.status, Incident.STATUS_QUEUED, "queued, awaiting units")
	assert_eq(inc.tile, Vector2i(67, 32), "positioned on T-04's global tile")
	assert_eq(String(sim.grid.component("T-04")["state"]), "OPEN", "doc 04 took it out")
	assert_true(int(inc.context.get("customers_downstream", 0)) >= 3,
			"the cause block recorded who is affected")

	# --- the lights go out
	var went_dark := false
	for i in 10:
		_step_minute(rig)
		var all_dark := true
		for building_id in customers:
			if sim.grid.is_powered(String(building_id)):
				all_dark = false
		if all_dark:
			went_dark = true
			break
	assert_true(went_dark, "every T-04 customer went dark")

	# --- a utility truck rolls, drives the real distance, and works the job
	var dispatched_unit := 0
	var arrived := false
	var resolved := false
	var restored_component := ""
	for minute in MAX_MINUTES:
		_step_minute(rig)
		for event in system.drain_events():
			match String(event.get("type", "")):
				"unit_dispatched":
					if int(event.get("incident_id", 0)) == inc.id:
						dispatched_unit = int(event["unit_id"])
				"unit_arrived":
					if int(event.get("incident_id", 0)) == inc.id:
						arrived = true
				"incident_resolved":
					if int(event.get("incident_id", 0)) == inc.id:
						resolved = true
				"power_restored_by_repair":
					restored_component = String(event.get("component", ""))
		if resolved:
			break
	assert_true(dispatched_unit != 0, "a unit was dispatched")
	var responder: Vehicle = system.fleet.unit(dispatched_unit)
	assert_eq(responder.department, "utility", "a utility crew answered, not a patrol car")
	assert_true(arrived, "it arrived on scene")
	assert_true(resolved, "and the incident resolved")
	assert_eq(restored_component, "T-04", "doc 04's component was restored by the repair")
	assert_true(inc.first_onscene_h > inc.first_assign_h, "on-scene came after dispatch")
	assert_true(inc.response_minutes() > 0.0 and inc.response_minutes() < 60.0,
			"response inside the §1.1 starter-city band, got %f gm" % inc.response_minutes())

	# --- the block relights
	assert_eq(String(sim.grid.component("T-04")["state"]), "OK", "the transformer is back")
	var relit := false
	for i in 20:
		_step_minute(rig)
		var all_lit := true
		for building_id in customers:
			if not sim.grid.is_powered(String(building_id)):
				all_lit = false
		if all_lit:
			relit = true
			break
	assert_true(relit, "every T-04 customer relit")
	assert_eq(system.dispatch.stats["resolved_total"], 1, "one resolution on the books")
	for unit_id in system.fleet.unit_ids():
		var u: Vehicle = system.fleet.unit(unit_id)
		assert_true(u.status == Vehicle.IDLE or u.status == Vehicle.RETURNING,
				"the fleet stood down")


## The organic path: doc 04 fails a component on its own, and doc 06 turns that
## event into the same repairable incident — one per component, never two.
func test_power_event_becomes_a_repairable_incident() -> void:
	var rig := _boot()
	var system: IncidentSystem = rig["system"]
	var event := {"type": "PowerComponentFailed", "component": "T-07",
			"cause": "XFMR_BURNOUT", "damage_fraction": 0.35}
	var inc := system.on_power_event(event)
	assert_ne(inc, null, "a burnout files an incident")
	assert_eq(inc.type, "transformer_failure", "mapped through data/incidents.json")
	assert_eq(inc.target_component_id(), "T-07", "on the failed component")
	assert_eq(String(inc.cause.get("cause", "")), "XFMR_BURNOUT", "the cause block is legible")
	assert_eq(system.on_power_event(event), null, "a second event does not double-file")
	# A relay lockout is the same shape: a crew has to go close it.
	var lockout := system.on_power_event({"type": "AutoRecloseLockout", "component": "F_SOUTH"})
	assert_ne(lockout, null, "a lockout files an incident too")
	assert_eq(lockout.type, "storm_damage", "a feeder maps to the line-work row")
	assert_eq(lockout.subtype, "downed_power_line", "as downed_power_line")
	# And an event doc 06 does not own is ignored.
	assert_eq(system.on_power_event({"type": "AutoReclosedOK", "component": "F_NORTH"}), null,
			"a successful reclose is not an incident")


## The three save sections round-trip through CitySim's float bit-encoder in
## the middle of the arc, and the resumed city finishes the same job.
func test_arc_survives_a_save_mid_repair() -> void:
	var rig := _boot()
	var sim: CitySim = rig["sim"]
	var system: IncidentSystem = rig["system"]
	for i in 5:
		_step_minute(rig)
	var inc := system.spawn_scripted_from_tag(sim.loader, "transformer_fail")
	assert_ne(inc, null, "incident filed")
	# Run until the truck is on scene and the job is under way.
	for minute in MAX_MINUTES:
		_step_minute(rig)
		if inc.status == Incident.STATUS_ACTIVE and inc.progress > 0.1:
			break
	assert_eq(inc.status, Incident.STATUS_ACTIVE, "work under way at save time")
	assert_true(inc.progress > 0.1 and inc.progress < 1.0, "mid-repair")

	var encoded: Variant = CitySim._encode_floats(system.serialize())
	var round_tripped: Variant = CitySim._decode_floats(
			JSON.parse_string(JSON.stringify(encoded, "", true, true)))
	var resumed := IncidentSystem.new(rig["catalog"], rig["world"], sim.rng)
	resumed.founding_offset_h = system.founding_offset_h
	resumed.deserialize(round_tripped)
	var inc_b: Incident = resumed.incident(inc.id)
	assert_ne(inc_b, null, "the incident came back")
	assert_almost_eq(inc_b.progress, inc.progress, 0.0, "progress bit-identical")
	assert_almost_eq(inc_b.severity, inc.severity, 0.0, "severity bit-identical")
	assert_eq(inc_b.status, inc.status, "still ACTIVE")
	assert_eq(resumed.fleet.size(), system.fleet.size(), "the fleet came back whole")
	var on_scene := 0
	for unit_id in resumed.fleet.unit_ids():
		if (resumed.fleet.unit(unit_id) as Vehicle).status == Vehicle.ON_SCENE:
			on_scene += 1
	assert_true(on_scene >= 1, "the crew is still on scene after the reload")

	rig["system"] = resumed
	var resolved := false
	for minute in MAX_MINUTES:
		_step_minute(rig)
		for event in resumed.drain_events():
			if String(event.get("type", "")) == "incident_resolved" \
					and int(event.get("incident_id", 0)) == inc.id:
				resolved = true
		if resolved:
			break
	assert_true(resolved, "the resumed city finishes the repair")
	assert_eq(String(sim.grid.component("T-04")["state"]), "OK", "and the power comes back")


## The snapshot contracts doc 11 (vehicles) and doc 12 (drawer) consume.
func test_snapshots_for_render_and_ui() -> void:
	var rig := _boot()
	var sim: CitySim = rig["sim"]
	var system: IncidentSystem = rig["system"]
	for i in 3:
		_step_minute(rig)
	var inc := system.spawn_scripted_from_tag(sim.loader, "transformer_fail")
	assert_ne(inc, null, "incident filed")
	for i in 3:
		_step_minute(rig)
	var drawer := system.snapshot()
	assert_eq(drawer.size(), 1, "one incident in the drawer")
	var row: Dictionary = drawer[0]
	for key in ["id", "type", "tier", "severity", "status", "pos", "wait_min", "assigned",
			"escalation_eta_min", "priority", "notification_priority"]:
		assert_true(row.has(key), "drawer row carries %s" % key)
	# C-67: speed and heading are first-class on every vehicle_state record.
	var states := system.vehicle_states()
	assert_eq(states.size(), system.fleet.size(), "one record per unit")
	var moving := 0
	for state in states:
		var record: Dictionary = state
		for key in ["id", "type", "pos", "speed", "heading", "status", "incident_id",
				"route_progress"]:
			assert_true(record.has(key), "vehicle_state carries %s" % key)
		if String(record["status"]) == Vehicle.RESPONDING:
			moving += 1
			assert_true(float(record["speed"]) > 0.0, "a responding unit reports a real speed")
	assert_true(moving >= 1, "at least one unit is en route")


## The integration patch, run for real: register the phase system on the live
## TickScheduler and drive the whole arc through `CitySim.advance_hours()`
## alone. If this passes, the snippet in the REPORT pastes in clean.
func test_phase_adapter_rides_the_scheduler() -> void:
	var rig := _boot()
	var sim: CitySim = rig["sim"]
	var system: IncidentSystem = rig["system"]
	var registered_before := sim.scheduler.system_count()
	sim.scheduler.register(IncidentPhaseSystem.new(system, rig["world"], sim.bus))
	assert_eq(sim.scheduler.system_count(), registered_before + 1, "phase system registered")

	sim.advance_hours(0.1)
	assert_almost_eq(system.now_h, float(sim.clock.tick_index) / 240.0, 1e-9,
			"the incident clock tracks the game clock exactly through the scheduler")

	var inc := system.spawn_scripted_from_tag(sim.loader, "transformer_fail")
	assert_ne(inc, null, "incident filed")
	sim.bus.drain()
	# Two game-hours of ordinary play, no hand-stepping of the incident engine.
	sim.advance_hours(2.0)
	assert_true(inc.is_terminal(), "the scheduler drove the arc to completion")
	assert_eq(inc.status, Incident.STATUS_RESOLVED, "and it resolved")
	assert_eq(String(sim.grid.component("T-04")["state"]), "OK", "power restored")
	var seen: Dictionary = {}
	for event in sim.bus.drain():
		seen[String(event.get("type", ""))] = true
	for event_type in ["unit_dispatched", "unit_arrived", "incident_resolved",
			"power_restored_by_repair"]:
		assert_true(seen.has(event_type), "doc 06 event %s reached the bus" % event_type)


func _customers_of(sim: CitySim, component_id: String) -> Array:
	var out: Array = []
	var ids: Array = sim.buildings.keys()
	ids.sort()
	for building_id in ids:
		if sim.grid.attachment_of(String(building_id)) == component_id:
			out.append(String(building_id))
	return out
