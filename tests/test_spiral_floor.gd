extends SimTest
## Wave 20, doc 93 §AR — **the spiral has a floor**. Measured in doc 92 §58,
## shipped as report 98 §61 RR-174…RR-178.
##
## Wave 19 §AP1 stopped wear demolishing PRIVATE stock and shipped. The player's
## own save, loaded by `tools/measure_player_city.gd`, then went from twelve
## standing buildings to **zero** in forty-five game-days on that build — so
## §AP1 had closed a door the player's city was not walking through. The three
## doors it actually used, each with the number that found it:
##
##   1. **The city was billed for its rubble.** `E_building_maint` and
##      `E_departments` both scale on `1 − condition`, and a ruin's condition is
##      0, so a destroyed building was billed 2.5× and a destroyed station 3.0×
##      what the same asset costs in perfect repair. On slot 0 that was
##      **$32,409 a game-day** against a gross of $2,998 — every building that
##      died raised the bill (§AR3).
##   2. **Unanswered fire.** Ten of eleven destructions in the first fourteen
##      game-days came through `burn_down` in a city whose only fire station was
##      already a ruin — 431 incidents abandoned, nothing the player could do
##      (§AR2).
##   3. **Wear could still take the last power plant** — §AP1's own listed
##      exception, on the one archetype a city cannot function or recover
##      without (§AR1).
##
## These tests pin the three rulings AND the doors they deliberately leave open,
## because a ruling that made a city indestructible would be as wrong as the
## ratchet it replaced.


# ------------------------------------------------------------------- §AR1

## The ruling: wear CONDEMNS the generation and water spine and stops. A power
## plant left to rot arrives at the structural-failure threshold and rests there
## at doc 02 §2.12's `output_mult` 0.40 — the lights never go out for good.
func test_wear_cannot_demolish_the_utility_spine() -> void:
	var sim := CitySim.boot_from_files()
	var sim_id := _first_of(sim, &"power_facility")
	assert_ne(sim_id, "", "the founding manifest has a power facility")
	var b: Building = sim.buildings[sim_id]
	assert_false(b.owner_maintained, "a power plant is the CITY's, not an owner's")
	assert_false(b.wear_may_demolish, "and §AR1 says wear may not demolish it")
	b.state = &"damaged"
	b.condition = 0.01

	# The same 10,000 game-hours §AP1's own test uses — 416 game-days, twenty
	# times the horizon `test_building.gd` calls certain collapse. Counted rather
	# than asserted in the loop: one failure is the answer.
	var rng := RngStreams.new(1234)
	var events := 0
	for hour in 10000:
		events += b.roll_structural_failure(rng, 1.0, hour * 60).size()
	assert_eq(events, 0, "10,000 game-hours of the roll produced no destruction")
	assert_eq(String(b.state), "damaged", "condemned, not demolished")
	assert_true(b.output_mult() > 0.0,
			"and a condemned plant still generates — §2.12's 0.40")


## Every archetype the file names, and only those. The spine is a data decision;
## this is the test that the code reads the data rather than a list of its own.
func test_the_spine_is_exactly_what_the_file_names() -> void:
	var catalog := BuildingCatalog.load_from_files()
	assert_true(catalog.is_valid(), "the shipped tables load clean")
	for archetype in ["power_facility", "substation", "water_facility"]:
		assert_true(catalog.is_utility_spine(archetype), archetype + " is the spine")
		assert_false(catalog.wear_may_demolish_for(archetype),
				"so wear may not demolish " + archetype)
	# The line §AR1 draws, and the reason it is drawn there: losing coverage is a
	# loss the player can see, price and rebuild out of; losing the last plant is
	# not recoverable at all while the treasury is negative.
	for archetype in ["police_station", "fire_station", "construction_yard"]:
		assert_false(catalog.is_utility_spine(archetype),
				archetype + " is losable civic stock")
		assert_true(catalog.wear_may_demolish_for(archetype),
				"so wear may still demolish " + archetype)


## A fixture whose rules carry no `utility_spine` block keeps the pre-Wave-20
## physics exactly — the same promise §AP1 made one field over.
func test_a_fixture_without_the_block_keeps_the_old_physics() -> void:
	var rules := _rules_without("utility_spine")
	var catalog := BuildingCatalog.new(_buildings_data(), rules)
	assert_false(catalog.is_utility_spine("power_facility"),
			"no block, no spine")
	assert_true(catalog.wear_may_demolish_for("power_facility"),
			"and wear demolishes a plant exactly as it did before Wave 20")


## The loader refuses a spine that names an archetype which does not exist,
## because that block would be a ruling the loader approved and nothing applied.
func test_the_loader_refuses_a_spine_that_names_nothing() -> void:
	var rules := _rules_with_spine(["power_facility", "not_a_building"])
	var catalog := BuildingCatalog.new(_buildings_data(), rules)
	assert_false(catalog.is_valid(), "a spine naming a non-archetype is an error")
	assert_true(_errors_mention(catalog, "not_a_building"),
			"and the error names the offending id")


# ------------------------------------------------------------------- §AR2

## The floor: a city with no fire department cannot answer anything, so doc 06's
## terminal op CONDEMNS instead of demolishing.
func test_a_city_with_no_fire_department_condemns_instead_of_demolishing() -> void:
	var sim := CitySim.boot_from_files()
	_close_every_fire_department(sim)
	var sim_id := _first_private(sim)
	var b: Building = sim.buildings[sim_id]
	b.state = &"on_fire"
	b.condition = 0.5
	sim.bus.drain()

	sim.incident_world.destroy_building(sim_id, "incident:1")
	assert_eq(String(b.state), "damaged", "condemned, not a ruin")
	assert_almost_eq(b.condition, b.rule("structural_failure_threshold"), 1e-9,
			"and it rests at doc 02 §2.6's own line, not at a new number")


## And the teeth stay in: a city that HAS a department and can reach the fire
## still loses the building. This is not an invulnerability lane.
func test_a_city_with_a_fire_department_still_loses_the_building() -> void:
	var sim := CitySim.boot_from_files()
	assert_ne(_first_of(sim, &"fire_station"), "",
			"the founding manifest has a fire station")
	var sim_id := _first_private(sim)
	var b: Building = sim.buildings[sim_id]
	b.state = &"on_fire"
	b.condition = 0.5
	sim.bus.drain()

	sim.incident_world.destroy_building(sim_id, "incident:1")
	assert_eq(String(b.state), "destroyed", "the fire took it")


## The second half of the predicate: units exist, but doc 10's graph offers no
## route. `DispatchSystem` records that on the incident and doc 06 reads it back.
func test_an_unreachable_incident_was_not_answerable() -> void:
	var sim := CitySim.boot_from_files()
	var incidents: IncidentSystem = sim.incidents
	var inc := Incident.new()
	inc.id = 1
	assert_true(incidents.incident_was_answerable(inc),
			"nothing recorded means nothing stopped the city")
	inc.unreachable = true
	assert_false(incidents.incident_was_answerable(inc),
			"no route is not a decision the player made")
	# Committed units win over the flag: they are ON it, so the fire beat them.
	inc.assigned[7] = {"state": "ON_SCENE"}
	assert_true(incidents.incident_was_answerable(inc),
			"a fire units are fighting and losing is a fair loss")


## The DAMAGE door, which §AP2 deliberately leaves open for a building already at
## the line — and which §AR2 closes for a city that could not defend it. Without
## this the condemn ruling would buy a building one game-hour.
func test_damage_may_not_finish_a_building_the_city_could_not_defend() -> void:
	var sim := CitySim.boot_from_files()
	_close_every_fire_department(sim)
	var sim_id := _first_private(sim)
	var b: Building = sim.buildings[sim_id]
	b.state = &"damaged"
	b.condition = b.rule("structural_failure_threshold")

	sim.incident_world.apply_building_damage(sim_id, 1.0)
	assert_eq(String(b.state), "damaged", "still standing, still condemned")
	assert_almost_eq(b.condition, b.rule("structural_failure_threshold"), 1e-9)


## …and §AP2 itself is untouched where the city COULD have acted: a second event
## on a building already at the line still finishes it.
func test_ap2_still_finishes_a_condemned_building_in_a_defended_city() -> void:
	var sim := CitySim.boot_from_files()
	var sim_id := _first_private(sim)
	var b: Building = sim.buildings[sim_id]
	b.state = &"damaged"
	b.condition = b.rule("structural_failure_threshold")

	sim.incident_world.apply_building_damage(sim_id, 1.0)
	assert_eq(String(b.state), "destroyed",
			"a city with a fire department still loses it — §AP2 unchanged")


## Doc 91 A91-D-110: `destroy_building` and `apply_building_damage` threw away
## every event the `Building` verbs handed them, so a building taken down by a
## cascade op announced NOTHING — no notification, nothing for `GoalSystem`,
## nothing a report could count. On the player's slot 0 that was 12 of 12
## destructions, silent.
func test_a_building_the_city_loses_is_a_building_the_city_is_told_about() -> void:
	var sim := CitySim.boot_from_files()
	var sim_id := _first_private(sim)
	var b: Building = sim.buildings[sim_id]
	b.state = &"on_fire"
	b.condition = 0.5
	sim.bus.drain()

	sim.incident_world.destroy_building(sim_id, "incident:1")
	var seen := _events_of(sim, &"building_destroyed")
	assert_eq(seen.size(), 1, "the bus was told")
	assert_eq(String((seen[0] as Dictionary).get("sim_id", "")), sim_id,
			"and it carries the ROSTER key, not the int Building.id")
	assert_eq(String((seen[0] as Dictionary).get("cause", "")), "fire")


# ------------------------------------------------------------------- §AR3

## The engine of the spiral, in one assertion: a settlement built on a city with
## a ruin in it must not bill that ruin. Doc 03 §2.4's `E_building_maint` is the
## city's cost of SERVING a building (doc 93 §Y1's own words) and a ruin is
## served by nothing.
func test_a_ruin_is_not_billed_building_maintenance() -> void:
	var sim := CitySim.boot_from_files()
	var sim_id := _first_private(sim)
	var before := _settlement_expense(sim, "building_maint")
	assert_true(before > 0.0, "a standing private building IS billed")

	(sim.buildings[sim_id] as Building).demolish(true, 0)
	var after := _settlement_expense(sim, "building_maint")
	assert_true(after < before, "and the ruin's share comes off the bill")
	# The sharp end: before Wave 20 this went UP, because
	# `MAINT_CONDITION_PENALTY` 1.5 is at its maximum at condition 0.
	assert_true(after < before, "the bill FALLS when a building dies, never rises")


## Its sibling: `station_upkeep` is STAFFING, and a destroyed station has no
## staff. Four ruined stations were costing the player $306.00/gh.
func test_a_ruined_station_is_not_staffed() -> void:
	var sim := CitySim.boot_from_files()
	var sim_id := _first_of(sim, &"police_station")
	assert_ne(sim_id, "", "the founding manifest has a police station")
	var before := _settlement_expense(sim, "departments")
	assert_true(before > 0.0, "a standing station IS staffed")

	(sim.buildings[sim_id] as Building).demolish(true, 0)
	assert_true(_settlement_expense(sim, "departments") < before,
			"a ruin draws no wages")


## And the fleet half: `station_rows()` is `FleetSystem.populate_from_stations`'s
## only source, so a ruined station listed there gives doc 06 a garage that does
## not exist and doc 03 an `E_fleet` line to bill for it.
func test_a_ruined_station_houses_no_engines() -> void:
	var sim := CitySim.boot_from_files()
	var sim_id := _first_of(sim, &"fire_station")
	var before: int = sim.incident_world.station_rows().size()
	assert_true(before > 0, "the founding manifest houses a fleet")

	(sim.buildings[sim_id] as Building).demolish(true, 0)
	assert_eq(sim.incident_world.station_rows().size(), before - 1,
			"the ruined station is gone from the garage list")


## **§AR3's REMAINDER, AND IT IS THE ONE STATION ROW THE GUARD COULD NOT SEE —
## doc 93 §AV3.** `build_settlement_inputs` says of itself *"one guard, one
## place: this loop is the sole author of both arrays"*, and it is not: the
## `water_works` row is appended by a SECOND loop, over `water.nodes`, keyed on a
## pump existing in the GRAPH. A `water_facility` that is demolished takes its
## nodes with it (`_retire_water_nodes`), but one that BURNS DOWN does not — so on
## the player's own slot 0, with all three water plants in rubble and 2 pump
## nodes still in the graph, `E_departments` billed $20.00/gh for plants that do
## not exist.
func test_a_burned_down_water_plant_draws_no_wages() -> void:
	var sim := CitySim.boot_from_files()
	assert_ne(_first_of(sim, &"water_facility"), "",
			"the founding manifest has a water plant")
	var before := _settlement_expense(sim, "departments")

	# The fire/failure door, NOT `demolish`: demolition retires the nodes and
	# would close the hole by a route this ruling is not about. Every plant,
	# because `has_pump` is one boolean for the whole graph.
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.archetype != &"water_facility":
			continue
		b.state = &"destroyed"
		b.condition = 0.0
	var after := _settlement_expense(sim, "departments")
	var upkeep := sim.economy.station_upkeep("water_works", 1, false)
	assert_true(upkeep > 0.0, "doc 03 prices water_works staffing")
	assert_true(after < before,
			"the wages of a plant that burned down come off the bill"
			+ " ($%.2f -> $%.2f)" % [before, after])
	assert_true(sim.water.nodes.size() > 0,
			"and the nodes are STILL in the graph — this is a roster reading,"
			+ " not a graph edit")

	# …and the other direction, which is what stops this from being "never bill
	# water_works": a plant still standing is still staffed.
	var alive := CitySim.boot_from_files()
	assert_almost_eq(_settlement_expense(alive, "departments"), before, 1e-9,
			"a standing plant is billed exactly as it was")


## The whole ruling in the shape the player feels it: a city that has lost most
## of its stock is billed LESS than it was when the stock was standing, not more.
func test_the_bill_falls_as_the_city_falls() -> void:
	var sim := CitySim.boot_from_files()
	var whole := _settlement_expense(sim, "total")
	for id in sim.roster_ids():
		(sim.buildings[id] as Building).demolish(true, 0)
	var razed := _settlement_expense(sim, "total")
	assert_true(razed < whole,
			"a city of ruins costs less to run than a city of buildings")


## The one branch of §AR2 that still demolishes: a NEW BUILD has no standing
## structure to board up, and putting a level-0 site in `damaged` would strand it
## — `complete_construction` can never run from there, and `damaged` at level 0
## is a state doc 02 §2.12's table does not describe.
func test_a_new_build_site_is_still_lost() -> void:
	var sim := CitySim.boot_from_files()
	_close_every_fire_department(sim)
	var sim_id := _first_private(sim)
	var b: Building = sim.buildings[sim_id]
	b.state = &"under_construction"
	b.level = 0
	b.pending_level = 1

	sim.incident_world.destroy_building(sim_id, "incident:1")
	assert_eq(String(b.state), "destroyed",
			"a site that never opened is a site, not a building")


## …and an UPGRADE in flight IS a real building, so it is condemned like any
## other and keeps the level it already had.
func test_an_upgrade_in_flight_is_condemned_not_lost() -> void:
	var sim := CitySim.boot_from_files()
	_close_every_fire_department(sim)
	var sim_id := _first_private(sim)
	var b: Building = sim.buildings[sim_id]
	b.state = &"under_construction"
	b.level = 2
	b.pending_level = 3

	sim.incident_world.destroy_building(sim_id, "incident:1")
	assert_eq(String(b.state), "damaged", "a level-2 building still stands")
	assert_eq(b.level, 2, "at the level it had")


# --------------------------------------------------- §AS1 (Wave 21, replacing
#                                                       §AR2's austerity clause)

## **WEALTH IS NOT IN THE PREDICATE, IN BOTH DIRECTIONS.** Wave 20's draft opened
## `_could_have_answered` with `if not treasury.austerity_active: return true` —
## "could the player have BOUGHT a station?" — and it is deleted. These two
## assertions are the deletion: the answer does not change when the treasury
## does, either way round.
func test_the_ruling_does_not_read_the_treasury() -> void:
	# Rich, and no fire service: still condemned. Under the Wave-20 draft this
	# was `destroyed`, and it is the assertion that pins the deletion.
	var rich := CitySim.boot_from_files()
	_close_every_fire_department(rich)
	rich.treasury.austerity_active = false
	rich.treasury.balance = 397081
	var rich_id := _first_private(rich)
	var rich_b: Building = rich.buildings[rich_id]
	rich_b.state = &"on_fire"
	rich_b.condition = 0.5
	rich.incident_world.destroy_building(rich_id, "incident:1")
	assert_eq(String(rich_b.state), "damaged",
			"no engine to send is no engine to send, at any balance")

	# Broke, WITH a fire service: still destroyed. Under the Wave-20 draft this
	# was the total-immunity exploit — 76 buildings alive at game-day 45 and the
	# identical 76 at 90, bought by staying under the austerity line.
	var broke := CitySim.boot_from_files()
	assert_true(broke.incident_world.has_fire_capability(),
			"the founding manifest owns a fire service")
	broke.treasury.austerity_active = true
	broke.treasury.balance = -22624
	var broke_id := _first_private(broke)
	var broke_b: Building = broke.buildings[broke_id]
	broke_b.state = &"on_fire"
	broke_b.condition = 0.5
	broke.incident_world.destroy_building(broke_id, "incident:1")
	assert_eq(String(broke_b.state), "destroyed",
			"a city that owns engines and loses the fight loses the building")


## **THE WAVE-20 EXPLOITS STAY SHUT, ON THE ROSTER AND NOT ONLY ON A PREDICATE.**
##
## `test_the_ruling_does_not_read_the_treasury` pins the PREDICATE at two
## balances. This pins the OUTCOME: two cities, identical but for a treasury at
## the insolvency floor and a treasury at +$5,000,000, driven through three doors
## on the same buildings in the same order. The rosters must come out identical,
## because wealth is not in §AV1 either — and §AV1 WIDENED the door to every
## hazard, so the assertion has to be re-taken on the wider door rather than
## inherited from the narrow one.
func test_wealth_moves_no_roster_at_either_extreme() -> void:
	var rosters: Array[String] = []
	for balance in [-20000, 5000000]:
		var city := CitySim.boot_from_files()
		city.treasury.balance = int(balance)
		city.treasury.austerity_active = int(balance) < 0
		_close_every_fire_department(city)
		var ids := city.roster_ids()
		var burned := String(ids[0])
		var flooded := String(ids[1])
		var stormed := String(ids[2])
		(city.buildings[burned] as Building).state = &"on_fire"
		(city.buildings[burned] as Building).condition = 0.5
		city.incident_world.destroy_building(burned, "incident:1", true, "fire")
		city.incident_world.apply_building_damage(flooded, 1.0, true, "water")
		city.incident_world.apply_building_damage(stormed, 1.0, true, "construction")
		rosters.append(_roster_states(city))
	assert_eq(rosters[0], rosters[1],
			"an insolvent city and a city with five million in the bank lose"
			+ " exactly the same buildings")
	assert_true(rosters[0].length() > 0, "and the roster was actually read")


## **CAPABILITY IS THE SERVICE, NOT THE SHELL — doc 93 §AV1, re-fitting §AS1.**
##
## §AS1 read two halves and called neither sufficient. The station half is
## DELETED here, and the assertion that used to pin it is INVERTED, with the
## measurement that inverted it: on the player's own slot 0 the station was
## rubble, `has_fire_capability()` was false and the protection was on — while
## one fire engine was still in the fleet and answered 28 of 28 incidents
## (doc 92 §62.1). An engine with no station rolls.
func test_capability_is_the_service_not_the_shell() -> void:
	var sim := CitySim.boot_from_files()
	assert_true(sim.incident_world.has_fire_capability(),
			"a founding city owns engines")

	# Take the engines away and leave the station standing. This half of §AS1
	# survives §AV1 unchanged, because it was always the fleet doing the work:
	# a garage contributes no unit.
	var fleet: FleetSystem = sim.incidents.fleet
	for unit_id in fleet.unit_ids_ref().duplicate():
		var u: Vehicle = fleet.unit(unit_id)
		if u != null and u.has_capability_for("fire"):
			fleet.remove_unit(int(unit_id))
	assert_false(sim.incident_world.has_fire_capability(),
			"a garage with no engine in it is not a fire service")

	# …and the half §AV1 inverts, on a fresh city: the shell is gone and the
	# engines are not. `Building.demolish` does not retire a unit (doc 93 §AR3),
	# which is the real shape of the player's own save — and the city that shape
	# describes STILL HAS a fire department.
	var razed := CitySim.boot_from_files()
	for id in razed.roster_ids():
		var b: Building = razed.buildings[id]
		if b.archetype == &"fire_station":
			b.demolish(true, 0)
	assert_true(razed.incident_world.has_fire_capability(),
			"engines that outlive their station are still a fire service")

	# The one verb that ends it is the player's own bulldoze, which retires the
	# units with the shell (`CitySim._take_building_off_the_map`).
	_close_every_fire_department(razed)
	assert_false(razed.incident_world.has_fire_capability(),
			"a bulldozed department is a department the city no longer owns")


## **A HAZARD IS ANSWERABLE BY THE SERVICE THAT HAZARD NEEDS — doc 93 §AV1.**
##
## §AS1 put `has_fire_capability()` on `apply_building_damage`, which is the door
## EVERY hazard's `building_condition` op goes through, so a city with no fire
## department could not have a building finished off by a storm, a flood or
## anything else. The city below owns every construction crew in the founding
## manifest and no fire department at all; a `roof_damage` — `primary_role`
## `construction` — is answerable and finishes the building.
## **§AV4's TERM, ON THE UNIT RIG RATHER THAN ON A 90-GAME-DAY ARC.** Doc 92
## §62.6 measures what fire coverage is WORTH; this measures that it is wired,
## in one assertion that cannot be absorbed by a Poisson draw: the same roster,
## the same hour, the same everything, with the district's `fire_coverage` at 0
## and at 1, read off doc 06's own rate sum.
func test_fire_coverage_lowers_the_ignition_rate() -> void:
	var uncovered := _fire_rate_total(0.0)
	var covered := _fire_rate_total(1.0)
	assert_true(uncovered > 0.0, "the rig has something that can burn")
	var slope := 0.4286
	assert_almost_eq(covered / uncovered, 1.0 - slope, 1e-6,
			"full fire coverage cuts doc 06's ignition rate by crime's own"
			+ " full-coverage reduction, 0.6 / 1.4")


## The fallback in [CityIncidentWorld._could_have_answered] — an empty `role`
## reading as the fire role — must be UNREACHABLE from the shipped catalogue, or
## §AV1's per-hazard scoping is one missing key away from being §AS1 again. Every
## merged row names the service that answers it; a subtype inherits its parent's.
func test_every_hazard_names_the_service_that_answers_it() -> void:
	var catalog := IncidentCatalog.load_from_files()
	var checked := 0
	for type_id in catalog.type_ids():
		var row := catalog.type_row(String(type_id))
		assert_ne(String(row.get("primary_role", "")), "",
				"%s names the service that answers it" % String(type_id))
		checked += 1
	assert_true(checked >= 6, "every type in data/incidents.json was checked")


func test_a_storm_is_answered_by_the_crew_not_the_engine() -> void:
	var sim := CitySim.boot_from_files()
	_close_every_fire_department(sim)
	assert_false(sim.incident_world.has_fire_capability(),
			"no fire service")
	assert_true(sim.incident_world.has_service_capability("construction"),
			"but the construction yard's crews are still in the fleet")

	var sim_id := _first_private(sim)
	var b: Building = sim.buildings[sim_id]
	b.state = &"damaged"
	b.condition = b.rule("structural_failure_threshold")
	sim.incident_world.apply_building_damage(sim_id, 1.0, true, "construction")
	assert_eq(String(b.state), "destroyed",
			"the roof came off and the city owned the crew that answers roofs")

	# …and the same door, same city, for the hazard the city really cannot
	# answer: the fire floor is untouched.
	var other := CitySim.boot_from_files()
	_close_every_fire_department(other)
	var other_id := _first_private(other)
	var ob: Building = other.buildings[other_id]
	ob.state = &"damaged"
	ob.condition = ob.rule("structural_failure_threshold")
	other.incident_world.apply_building_damage(other_id, 1.0, true, "fire")
	assert_eq(String(ob.state), "damaged",
			"and a fire it has no engine for still condemns")


## **AN UPGRADE IN FLIGHT IS NOT A CLOSED DEPARTMENT — doc 93 §AV1.** §AS1
## excluded `under_construction` from the station half on the stated ground that
## "a station that has not opened cannot roll an engine". That is true of a
## level-0 new build and FALSE of a level-1 upgrade, whose engines are in the
## fleet and dispatchable for every hour of the works — so starting an upgrade
## switched the protection on. Reading the fleet answers it with no special case.
func test_an_upgrade_in_flight_does_not_close_the_department() -> void:
	var sim := CitySim.boot_from_files()
	var station := _first_of(sim, &"fire_station")
	assert_ne(station, "", "the founding manifest has a fire station")
	var b: Building = sim.buildings[station]
	b.state = &"under_construction"
	b.pending_level = maxi(b.level, 1) + 1
	assert_true(sim.incident_world.has_fire_capability(),
			"the engines are still in the bay while the works run")

	var sim_id := _first_private(sim)
	var victim: Building = sim.buildings[sim_id]
	victim.state = &"on_fire"
	victim.condition = 0.5
	sim.incident_world.destroy_building(sim_id, "incident:1")
	assert_eq(String(victim.state), "destroyed",
			"so a fire during the works is answerable, exactly as it was before")


## The line §AS1 draws inside a city that DOES own a service, and it is the
## sentence that keeps neglect expensive: "every engine is already out" is a
## fleet-sizing choice, and doc 06 reads it as ANSWERABLE. The building burns.
func test_a_department_with_no_free_engine_still_loses_the_building() -> void:
	var sim := CitySim.boot_from_files()
	var incidents: IncidentSystem = sim.incidents
	var inc := Incident.new()
	inc.id = 1
	assert_true(incidents.incident_was_answerable(inc),
			"nothing committed and no route problem = the city could have come")
	var sim_id := _first_private(sim)
	var b: Building = sim.buildings[sim_id]
	b.state = &"on_fire"
	b.condition = 0.5
	sim.incident_world.destroy_building(sim_id, "incident:1",
			incidents.incident_was_answerable(inc))
	assert_eq(String(b.state), "destroyed",
			"too few engines is a decision, and it still costs the building")


# ---------------------------------------------------------------- helpers

func _first_of(sim: CitySim, archetype: StringName) -> String:
	for id in sim.roster_ids():
		if (sim.buildings[id] as Building).archetype == archetype:
			return String(id)
	return ""


func _first_private(sim: CitySim) -> String:
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.owner_maintained and b.state == &"active":
			return String(id)
	return ""


## **Doc 93 §AS1's fixture, and Wave 23 CORRECTED it (§AV1).** Wave 20's version
## also set `austerity_active = true`, because that draft read the treasury; §AS1
## does not read money at all, so the fixture no longer has to bankrupt the city
## to reach the ruling.
##
## What Wave 21 left was `b.demolish()` and nothing else, and that is a SHELL
## verb: it takes the building off the map and leaves every engine in
## `FleetSystem`, on duty, answering calls. Under §AV1's service reading that
## city still owns a fire department, so the old fixture no longer reaches the
## ruling at all — it reached it under §AS1 only because §AS1 was reading the
## wrong thing. The fixture is now the pair `CitySim._take_building_off_the_map`
## performs for a real player bulldoze: the shell goes AND
## `FleetSystem.remove_station` retires its units. That is the one door in the
## game that ends a service (doc 93 §AV1), so it is the one door the fixture may
## use.
func _close_every_fire_department(sim: CitySim) -> void:
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.archetype != &"fire_station":
			continue
		b.demolish(true, 0)
		sim.incidents.fleet.remove_station(String(id))


func _events_of(sim: CitySim, type: StringName) -> Array:
	var out: Array = []
	for event in sim.bus.drain():
		if StringName(String(event["type"])) == type:
			out.append(event)
	return out


## One settled game-hour's expense line, taken through the real settlement so
## the test measures doc 03's arithmetic and not a restatement of it.
## `apply_to_treasury` is false: this is a reading, not a charge.
func _settlement_expense(sim: CitySim, line: String) -> float:
	var ctx := TimeContext.new()
	ctx.tick_index = sim.clock.tick_index
	var inputs := sim.build_settlement_inputs(ctx, {})
	inputs["apply_to_treasury"] = false
	var settled := sim.economy.settle_hour(inputs)
	return float((settled.get("expenses", {}) as Dictionary).get(line, 0.0))


func _buildings_data() -> Dictionary:
	var parsed: Variant = JSON.parse_string(
			FileAccess.get_file_as_string("res://data/buildings.json"))
	return parsed if parsed is Dictionary else {}


func _rules_without(key: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(
			FileAccess.get_file_as_string("res://data/building_rules.json"))
	var rules: Dictionary = parsed if parsed is Dictionary else {}
	rules.erase(key)
	return rules


func _rules_with_spine(archetypes: Array) -> Dictionary:
	var rules := _rules_without("")
	rules["utility_spine"] = {"archetypes": archetypes, "wear_may_demolish": false}
	return rules


func _errors_mention(catalog: BuildingCatalog, needle: String) -> bool:
	for line in catalog.errors:
		if String(line).contains(needle):
			return true
	return false


# ------------------------------------------------------------------- §AS2

## **THE BOUND.** A shell an unanswered fire has gutted is not fuel: doc 06's
## §2.6 ignition roll and §2.8 spread screen both stop seeing it, so the chain
## that clears a roster terminates the same way destruction used to terminate it.
func test_a_gutted_shell_is_not_fuel() -> void:
	var sim := CitySim.boot_from_files()
	_close_every_fire_department(sim)
	var sim_id := _first_private(sim)
	var b: Building = sim.buildings[sim_id]
	b.state = &"on_fire"
	b.condition = 0.5
	assert_false(b.burnt_out, "nothing is burnt out until a fire guts it")

	sim.incident_world.destroy_building(sim_id, "incident:1")
	assert_eq(String(b.state), "damaged", "condemned by §AS1")
	assert_true(b.burnt_out, "and gutted by §AS2")
	assert_eq(b.state_fire_mult(), 0.0,
			"a gutted shell cannot ignite — it rests in `damaged`, whose table"
			+ " row is 1.8, the most flammable rung in the game")
	# The seam doc 06 §2.8's spread screen actually reads.
	assert_eq(sim.incident_world.state_fire_mult(sim_id), 0.0,
			"and the row form agrees with the object form")


## The other side of the bound, and the reason it is not a farm: repairing the
## shell makes it a building again, and a building burns.
func test_repairing_the_shell_makes_it_fuel_again() -> void:
	var sim := CitySim.boot_from_files()
	_close_every_fire_department(sim)
	var sim_id := _first_private(sim)
	var b: Building = sim.buildings[sim_id]
	b.state = &"on_fire"
	b.condition = 0.5
	sim.incident_world.destroy_building(sim_id, "incident:1")
	assert_true(b.burnt_out, "gutted")

	b.start_repair()
	b.complete_repair(0.85)
	assert_false(b.burnt_out, "repaired is rebuilt")
	assert_true(b.state_fire_mult() > 0.0, "and rebuilt burns")


## A RESTORE arrives through `complete_construction`, which is the door a player
## tapping *Restore All* walks through. It lifts the flag too.
func test_a_restored_building_is_fuel_again() -> void:
	var b := Building.new(1, &"house", Vector2i.ZERO)
	b.state = &"damaged"
	b.condition = 0.10
	b.burnt_out = true
	b.level = 2
	b.demolish(true, 0)
	assert_false(b.burnt_out, "rubble is not a gutted shell, it is rubble")
	b.order_rebuild(0)
	b.start_construction()
	b.complete_construction()
	assert_false(b.burnt_out, "and a restored building is a building")
	assert_true(b.state_fire_mult() > 0.0)


## **THE KEY IS SPARSE, AND THAT IS WHY WAVE 21's BASELINES ARE COMPARABLE.**
## `Building.serialize()` is inside `state_hash()`, so an unconditional key would
## move every determinism baseline on every city for a flag no city without a
## gutted shell has ever set.
func test_the_burnt_out_key_is_written_only_when_it_is_true() -> void:
	var b := Building.new(1, &"house", Vector2i.ZERO)
	b.state = &"active"
	assert_false(b.serialize().has("burnt_out"),
			"a building that has never burned writes the pre-§AS2 save exactly")
	b.burnt_out = true
	assert_true(bool(b.serialize().get("burnt_out", false)))
	assert_true(Building.deserialize(b.serialize()).burnt_out,
			"and it survives the round trip")
	# The default a pre-§AS2 save means.
	var legacy := b.serialize()
	legacy.erase("burnt_out")
	assert_false(Building.deserialize(legacy).burnt_out)


# ------------------------------------------------------------------- §AS3

## **AN EVENT STORM IS ITS OWN DEFECT.** The old de-dup kept ONE slot, so an
## incident blocked on two roles for two reasons overwrote it on every need and
## announced both on every integrator sub-step: 279,071
## `dispatch_blocked_unreachable` in 45 game-days on the player's slot 0, and
## 466,321 in 90. Each
## reason is now announced once per incident until something is assigned.
func test_a_blocked_incident_says_each_reason_once() -> void:
	var sim := CitySim.boot_from_files()
	var dispatch: DispatchSystem = sim.incidents.dispatch
	dispatch.drain_events()
	var inc := Incident.new()
	inc.id = 1
	for _repeat in 50:
		dispatch._emit_blocked(inc, "dispatch_blocked_unreachable", "fire")
		dispatch._emit_blocked(inc, "dispatch_blocked_no_units", "police")
	assert_eq(dispatch.drain_events().size(), 2,
			"two reasons, two announcements — not one hundred")

	# A reason that CHANGES is a different sentence, and it is still said once.
	for _repeat in 50:
		dispatch._emit_blocked(inc, "dispatch_blocked_no_units", "fire")
	assert_eq(dispatch.drain_events().size(), 1, "the new reason, once")

	# …and the slot clears where it always cleared: something is finally coming.
	inc.context.erase("blocked_reason")
	dispatch._emit_blocked(inc, "dispatch_blocked_unreachable", "fire")
	assert_eq(dispatch.drain_events().size(), 1,
			"after an assignment the next block is genuine news again")


## The bus may not report a destruction that did not happen. Under §AS1 the
## terminal op condemns, and the old line said `building_destroyed_by_fire`
## either way — 3,891 times in 45 game-days about buildings still standing.
func test_the_bus_does_not_announce_a_destruction_that_did_not_happen() -> void:
	var sim := CitySim.boot_from_files()
	_close_every_fire_department(sim)
	var sim_id := _first_private(sim)
	var b: Building = sim.buildings[sim_id]
	b.state = &"on_fire"
	b.condition = 0.5
	sim.incidents.drain_events()
	var inc := Incident.new()
	inc.id = 1
	inc.target_ref = {"kind": "building", "id": sim_id}
	sim.incidents.ops.run_one(inc, {"op": "destroy_building"})
	var types := _incident_event_types(sim)
	assert_true(types.has("building_condemned_by_fire"),
			"the city is told the building was condemned")
	assert_false(types.has("building_destroyed_by_fire"),
			"and NOT that it was destroyed, because it was not")
	assert_eq(String(b.state), "damaged")


# ------------------------------------------------------------------- §AS4

## **THE ANTI-FARM INEQUALITY, PER ERA.** §AP4 authored 0.35 with the argument
## "0.35 < 1, so the grant never covers the bill". Three grants an era makes that
## 1.05, and the player's own save collected 1.03× its restore bill. Each grant
## now sees what the era already paid.
func test_relief_may_not_out_pay_the_bill_it_is_measured_against() -> void:
	var treasury := _broke_treasury()
	var bill := 296438.0
	var fraction := treasury.recovery_value("RELIEF_DAMAGE_FRACTION")
	var cooldown := int(treasury.recovery_value("RELIEF_COOLDOWN_HOURS"))
	var paid := 0
	var hour := 0
	for _grant in 3:
		# The revenue term is zero here on purpose: this asserts the DAMAGE side,
		# which is the side §AP4's inequality was written about.
		paid += treasury.maybe_grant_relief(hour, 0.0, -1.0, bill)
		treasury.balance = -treasury.credit_limit
		hour += cooldown
	assert_true(paid > 0, "the ladder still has a bottom rung")
	# The damage side sums to at most the fraction; what is left over is
	# `RELIEF_MIN`, the floor doc 03 §2.10 layer 5 guarantees EVERY grant, which
	# the cap deliberately does not take away — a city with nothing left to
	# measure still gets the bottom rung.
	var floor_rungs := float(int(treasury.difficulty().get("relief_grants_per_era", 0)) - 1) \
			* treasury.recovery_value("RELIEF_MIN")
	assert_true(float(paid) <= fraction * bill + floor_rungs + 1.0,
			"an ERA of relief is the fraction of the bill plus the guaranteed"
			+ " floors, and no more (got $%d of $%d)" % [paid, int(bill)])
	assert_true(float(paid) < bill,
			"and therefore never covers the bill it is measured against")


## **AND THE SAME SENTENCE ON A SMALL BILL, WHICH IS WHERE IT WAS FALSE — doc 93
## §AV2.** §AS4 capped the two terms and left `RELIEF_MIN` outside both, so an era
## paid `$8,000 × relief_grants_per_era` however little it was measured against.
## At the fork a $2,000 bill drew $24,000 — 12.0× — and the heading above claimed
## it could not.
func test_the_floor_may_not_multiply_an_era() -> void:
	var treasury := _broke_treasury()
	var bill := 2000.0
	var cooldown := int(treasury.recovery_value("RELIEF_COOLDOWN_HOURS"))
	var paid := 0
	var hour := 0
	for _grant in int(treasury.difficulty().get("relief_grants_per_era", 3)) + 2:
		paid += treasury.maybe_grant_relief(hour, 0.0, -1.0, bill)
		treasury.balance = -treasury.credit_limit
		hour += cooldown
	assert_true(float(paid) <= bill,
			"an era never out-pays the bill it is measured against (got $%d of"
			% paid + " $%d)" % int(bill))
	assert_true(paid > 0, "and a city with a small bill is still helped")


## …and the ask that prices to zero may not burn one of the era's three rescues.
## The ceiling closes the money, not the ladder.
func test_a_zero_priced_ask_does_not_spend_the_allowance() -> void:
	var treasury := _broke_treasury()
	var bill := 2000.0
	var cooldown := int(treasury.recovery_value("RELIEF_COOLDOWN_HOURS"))
	assert_true(treasury.maybe_grant_relief(0, 0.0, -1.0, bill) > 0,
			"the first ask is paid")
	var used_after_first := treasury.relief_grants_used
	treasury.balance = -treasury.credit_limit
	assert_eq(treasury.maybe_grant_relief(cooldown, 0.0, -1.0, bill), 0,
			"the second is priced at nothing")
	assert_eq(treasury.relief_grants_used, used_after_first,
			"and costs the era none of its allowance")

	# …and the room re-opens when the city has more to be measured on, which is
	# the property that keeps the revenue ladder alive under the ceiling.
	treasury.balance = -treasury.credit_limit
	assert_true(treasury.maybe_grant_relief(cooldown * 2, 40000.0, -1.0, bill) > 0,
			"a city earning again is measured on what it earns")


## The first grant is not made smaller by the cap: a city in the hole still gets
## the full fraction of its own damage the first time it asks.
func test_the_first_grant_is_the_full_fraction() -> void:
	var treasury := _broke_treasury()
	var bill := 100000.0
	var fraction := treasury.recovery_value("RELIEF_DAMAGE_FRACTION")
	assert_eq(treasury.maybe_grant_relief(0, 0.0, -1.0, bill),
			CostCurves.round_half_up(fraction * bill),
			"the ladder's bottom rung is unchanged for the city that needs it")


## A new era is a new bill. `note_era` resets the allowance and the money it may
## hand out together, because they are one thing.
func test_a_new_era_resets_what_the_cap_remembers() -> void:
	var treasury := _broke_treasury()
	treasury.maybe_grant_relief(0, 0.0, -1.0, 100000.0)
	assert_true(treasury.relief_era_paid > 0, "the era remembers")
	treasury.note_era(treasury.relief_era_level + 1)
	assert_eq(treasury.relief_era_paid, 0, "and a new era forgets")
	assert_eq(treasury.relief_grants_used, 0, "with its allowance, together")


## A save written before the cap carries no counter, and 0 is the honest reading:
## it is the same answer a city that had taken no grant yet would get.
func test_a_save_without_the_counter_loads_at_zero() -> void:
	var treasury := _broke_treasury()
	var data := treasury.serialize()
	assert_true(data.has("relief_era_paid"), "the counter is persisted")
	data.erase("relief_era_paid")
	treasury.deserialize(data)
	assert_eq(treasury.relief_era_paid, 0)


# ------------------------------------------------------- helpers (Wave 21)

## Doc 06 §2.6's per-building ignition rate summed over one district, on the
## doc-06 unit rig, at a stated `fire_coverage`. Everything else is held: same
## building, same condition, same hour, same catalog.
func _fire_rate_total(fire_coverage: float) -> float:
	var world := IncidentTestWorld.new()
	world.add_district("D1", 5000.0, 1.0, 0.5, 0.0, fire_coverage)
	world.add_building("H1", "house", 1, Vector2i(4, 4), "D1",
			{"fire_ignition_per_hour": 0.01})
	var system := IncidentSystem.new(IncidentCatalog.load_from_files(), world,
			RngStreams.new(4242), null)
	system.generation_enabled = false
	return float(system._structure_fire_rates(1.0, false)["total"])


## Every building's id, state and condition, in roster order, as one string —
## the cheapest total ordering two cities can be compared on.
func _roster_states(sim: CitySim) -> String:
	var parts: Array[String] = []
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		parts.append("%s=%s@%.6f" % [String(id), String(b.state), b.condition])
	return "|".join(parts)


func _incident_event_types(sim: CitySim) -> Array:
	var out: Array = []
	for event in sim.incidents.drain_events():
		out.append(String((event as Dictionary).get("type", "")))
	return out


## A treasury deep enough in the credit line that `relief_gates_pass` says yes,
## built from the shipped `data/economy.json` so the test quotes no number the
## file does not own (C-07).
func _broke_treasury() -> Treasury:
	var parsed: Variant = JSON.parse_string(
			FileAccess.get_file_as_string("res://data/economy.json"))
	var economy: Dictionary = parsed if parsed is Dictionary else {}
	var treasury := Treasury.new(economy, {}, 0)
	treasury.credit_limit = int(treasury.recovery_value("CREDIT_LIMIT_FLOOR"))
	treasury.balance = -treasury.credit_limit
	return treasury


## **AN OWNER BOARDS UP A GUTTED SHELL, THEY DO NOT REBUILD IT.** §Y1's routine
## upkeep keeps a STANDING building standing; without this the bound was a
## two-game-hour delay and the same building burned 156 times a game-day.
func test_owner_upkeep_does_not_rebuild_a_gutted_shell() -> void:
	var sim := CitySim.boot_from_files()
	_close_every_fire_department(sim)
	var sim_id := _first_private(sim)
	var b: Building = sim.buildings[sim_id]
	b.state = &"on_fire"
	b.condition = 0.5
	sim.incident_world.destroy_building(sim_id, "incident:1")
	assert_true(b.burnt_out, "gutted")
	var line := b.rule("structural_failure_threshold")

	# A full game-day of the owner's own upkeep, at full power.
	for _hour in 24:
		b.apply_decay(1.0, 0.0, 1.0)
	assert_true(b.burnt_out, "still boarded up after a game-day")
	assert_almost_eq(b.condition, line, 1e-9,
			"HELD at the line — boarded up, not rotted away and not rebuilt")
	assert_eq(b.state_fire_mult(), 0.0, "so it is still not fuel")
	assert_true(b.output_mult() > 0.0,
			"and it is still worth a fifth of a building, which is the whole"
			+ " promise §AS1 makes to a city that cannot answer a fire")

	# The control: an ordinary condemned building the fire never touched IS
	# maintained by its owner, exactly as §Y1 has always had it.
	var other_id := _first_private_other_than(sim, sim_id)
	var other: Building = sim.buildings[other_id]
	other.state = &"damaged"
	other.condition = line
	for _hour in 24:
		other.apply_decay(1.0, 0.0, 1.0)
	assert_true(other.condition > line,
			"§Y1's owner floor is untouched where no fire gutted the building")


## …and the player's own paid repair is the door out. This is the "spends instead
## of being erased" half: doing nothing costs four fifths of the asset forever,
## and a repair ends it.
func test_a_paid_repair_is_the_door_out_of_the_shell() -> void:
	var sim := CitySim.boot_from_files()
	_close_every_fire_department(sim)
	var sim_id := _first_private(sim)
	var b: Building = sim.buildings[sim_id]
	b.state = &"on_fire"
	b.condition = 0.5
	sim.incident_world.destroy_building(sim_id, "incident:1")
	assert_true(b.output_mult() > 0.0,
			"a boarded shell still earns doc 02 §2.12's share — it is a loss,"
			+ " not a deletion")

	b.start_repair()
	b.complete_repair(b.rule("repair_target_damaged"))
	assert_false(b.burnt_out, "somebody paid, so the shell is a building again")
	assert_true(b.state_fire_mult() > 0.0, "and it can burn again")


func _first_private_other_than(sim: CitySim, exclude: String) -> String:
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.owner_maintained and String(id) != exclude and b.state != &"destroyed":
			return String(id)
	return ""
