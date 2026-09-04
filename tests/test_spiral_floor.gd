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
	_raze_every_fire_station(sim)
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
	_raze_every_fire_station(sim)
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
	_raze_every_fire_station(sim)
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
	_raze_every_fire_station(sim)
	var sim_id := _first_private(sim)
	var b: Building = sim.buildings[sim_id]
	b.state = &"under_construction"
	b.level = 2
	b.pending_level = 3

	sim.incident_world.destroy_building(sim_id, "incident:1")
	assert_eq(String(b.state), "damaged", "a level-2 building still stands")
	assert_eq(b.level, 2, "at the level it had")


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


func _raze_every_fire_station(sim: CitySim) -> void:
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.archetype == &"fire_station":
			b.demolish(true, 0)


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
