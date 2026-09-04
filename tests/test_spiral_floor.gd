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
	_raze_every_fire_station(rich)
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


## Capability has TWO halves and neither is sufficient. Doc 93 §AR3 measured why:
## `sync_station` fires on completion and never on destruction, so a station and
## its engines drift apart in both directions.
func test_capability_is_a_station_and_an_engine() -> void:
	var sim := CitySim.boot_from_files()
	assert_true(sim.incident_world.has_fire_capability(),
			"a founding city has both halves")

	# Take the engines away and leave the station standing.
	var fleet: FleetSystem = sim.incidents.fleet
	for unit_id in fleet.unit_ids_ref().duplicate():
		var u: Vehicle = fleet.unit(unit_id)
		if u != null and u.has_capability_for("fire"):
			fleet.remove_unit(int(unit_id))
	assert_false(sim.incident_world.has_fire_capability(),
			"a garage with no engine in it is not a fire service")

	# …and the other half, on a fresh city: the engines exist, the station does
	# not. `demolish` does not retire a unit (doc 93 §AR3), so this is the real
	# shape of the player's own save.
	var razed := CitySim.boot_from_files()
	_raze_every_fire_station(razed)
	assert_false(razed.incident_world.has_fire_capability(),
			"an engine with no station to roll out of is not a fire service")


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


## **Doc 93 §AS1's fixture, and Wave 21 DELETED a line from it.** Wave 20's
## version also set `austerity_active = true`, because that draft read the
## treasury; §AS1 does not read money at all, so the fixture no longer has to
## bankrupt the city to reach the ruling. What is left is the only fact §AS1
## turns on: the city has no fire service.
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


# ------------------------------------------------------------------- §AS2

## **THE BOUND.** A shell an unanswered fire has gutted is not fuel: doc 06's
## §2.6 ignition roll and §2.8 spread screen both stop seeing it, so the chain
## that clears a roster terminates the same way destruction used to terminate it.
func test_a_gutted_shell_is_not_fuel() -> void:
	var sim := CitySim.boot_from_files()
	_raze_every_fire_station(sim)
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
	_raze_every_fire_station(sim)
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
	_raze_every_fire_station(sim)
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
	_raze_every_fire_station(sim)
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
	_raze_every_fire_station(sim)
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
