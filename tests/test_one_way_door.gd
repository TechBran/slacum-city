extends SimTest
## Wave 19, doc 93 §AP — **the one-way door**. Measured in doc 92 §56, shipped as
## report 98 §59 RR-164/RR-165/RR-166.
##
## The player, on their own city, 2026-09-03: *"The buildings are still being
## destroyed super fast … ALL of my buildings are destroyed right now."*
## `tools/measure_catastrophe.gd` found that every destruction in the game — 45
## game-days × 4 presets × 2 session kinds — came through ONE door,
## `Building.roll_structural_failure`, and none through any disaster. These tests
## pin the two rulings that close it and the four doors that stay open, because a
## ruling that made a city indestructible would be as wrong as the ratchet it
## replaced.


# ---------------------------------------------------------------- §AP1

## The ruling: wear CONDEMNS private stock and stops. A house left dark and
## rotting arrives at the structural-failure threshold and stays there.
func test_wear_cannot_demolish_a_private_building() -> void:
	var sim := CitySim.boot_from_files()
	var sim_id := _first(sim, true)
	assert_ne(sim_id, "", "the founding manifest has private stock")
	var b: Building = sim.buildings[sim_id]
	assert_true(b.owner_maintained, "residential/commercial/industrial/tech")
	assert_false(b.wear_may_demolish, "and the file says wear may not demolish it")
	b.state = &"damaged"
	b.condition = 0.01

	# Ten thousand game-hours of the roll — 416 game-days, twenty times the
	# 500-hour horizon `test_building.gd` calls certain collapse. Counted rather
	# than asserted inside the loop: one failure is the answer, and ten thousand
	# passing asserts would drown the suite's own count.
	var rng := RngStreams.new(1234)
	var events := 0
	for hour in 10000:
		events += b.roll_structural_failure(rng, 1.0, hour * 60).size()
	assert_eq(events, 0, "10,000 game-hours of the roll produced no destruction")
	assert_eq(String(b.state), "damaged", "condemned, not demolished")


## And the city's OWN stock is still losable, which is what keeps neglect fatal
## for the things the player chose to build.
func test_wear_still_demolishes_what_the_city_owns() -> void:
	var sim := CitySim.boot_from_files()
	var sim_id := _first(sim, false)
	assert_ne(sim_id, "", "the founding manifest has civic/utility stock")
	var b: Building = sim.buildings[sim_id]
	assert_false(b.owner_maintained, "civic and utility are not private stock")
	b.state = &"damaged"
	b.condition = 0.05

	var rng := RngStreams.new(1234)
	var destroyed_at := -1
	for hour in 500:
		if not b.roll_structural_failure(rng, 1.0, hour * 60).is_empty():
			destroyed_at = hour
			break
	assert_true(destroyed_at >= 0, "0.02/gh still collapses a city asset")
	assert_eq(String(b.state), "destroyed")


## The ruling travels through the SIM, not just the model: the hourly loop is
## where `roll_structural_failure` is actually called, and the stamp that carries
## the rule is applied by the coordinator.
func test_the_hourly_loop_carries_the_ruling() -> void:
	var sim := CitySim.boot_from_files(4242)
	var private_ids: Array = []
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.owner_maintained and b.decays():
			b.state = &"damaged"
			b.condition = 0.02
			private_ids.append(String(id))
	assert_true(private_ids.size() >= 3, "several private buildings, all condemned")

	sim.advance_coarse_hours(400, false)   # online: destruction is ALLOWED

	for id in private_ids:
		assert_ne(String((sim.buildings[id] as Building).state), "destroyed",
				"400 online game-hours at 0.02/gh demolished a private building")


# ---------------------------------------------------------------- §AP2

## One event may not take a standing building past the structural-failure line,
## however large the fraction.
func test_one_event_cannot_demolish_a_standing_building() -> void:
	var sim := CitySim.boot_from_files()
	var b: Building = sim.buildings[_first(sim, true)]
	b.state = &"active"
	b.condition = 1.0
	var floor_condition := b.rule("structural_failure_threshold")

	var events := b.apply_damage(1.0, 0)
	assert_almost_eq(b.condition, floor_condition, 1e-9,
			"a full-fraction hit condemns; it does not demolish")
	assert_ne(String(b.state), "destroyed")
	var kinds: Array = []
	for event in events:
		kinds.append(String(event["type"]))
	assert_true(kinds.has("building_damaged"), "it is damage, and it says so")


## …but a building ALREADY at or below the line is finished off, so nothing the
## ruling touches is immortal.
func test_a_condemned_building_is_still_finished_by_an_event() -> void:
	var sim := CitySim.boot_from_files()
	var b: Building = sim.buildings[_first(sim, true)]
	b.state = &"damaged"
	b.condition = b.rule("structural_failure_threshold")
	var events := b.apply_damage(0.5, 120)
	assert_eq(String(b.state), "destroyed", "the second event lands")
	assert_eq(String((events[0] as Dictionary)["cause"]), "damage")


## `destroy_building` is an op whose name is its specification. Splitting the
## floor onto the damage path had to leave it able to destroy — otherwise §AP2
## would have silently disarmed doc 06's terminal outcomes.
func test_the_explicit_destroy_op_still_destroys() -> void:
	var sim := CitySim.boot_from_files()
	var b: Building = sim.buildings[_first(sim, true)]
	b.state = &"active"
	b.condition = 1.0
	var events := b.demolish(true, 240)
	assert_eq(String(b.state), "destroyed", "an explicit demolition demolishes")
	assert_eq(events.size(), 1)
	assert_eq(b.level_at_destruction, b.level, "and it remembers what it was")


## …and it now carries doc 08 C-47's guard, which the `apply_damage(1.0)` line it
## replaced never had. Before Wave 19 an explicit destroy was the one door an
## ABSENCE could still take a building through.
func test_the_explicit_destroy_op_is_refused_offline() -> void:
	var sim := CitySim.boot_from_files()
	var b: Building = sim.buildings[_first(sim, true)]
	b.state = &"damaged"
	b.condition = 0.02
	assert_eq(b.demolish(false, 240).size(), 0, "no destruction while away")
	assert_ne(String(b.state), "destroyed")
	# The clamp is a FLOOR, not an assignment: it lifts a wreck up to the line
	# doc 08 leaves standing and never lowers a healthy building to it.
	assert_almost_eq(b.condition, b.rule("offline_burn_down_clamp"), 1e-9,
			"clamped to the wreck the player comes back to, not to a ruin")
	b.condition = 1.0
	b.demolish(false, 240)
	assert_almost_eq(b.condition, 1.0, 1e-9, "and it never damages anything")


## The whole point, end to end, on the arm that produced the player's report: an
## online city nobody touches. Before the ruling this arm destroyed 42 of 251
## buildings on `standard` (doc 92 §56.1); the private stock must now survive.
func test_a_neglected_city_keeps_its_private_stock() -> void:
	var sim := CitySim.boot_from_files(1337)
	var private_before := 0
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.owner_maintained:
			b.state = &"damaged"
			b.condition = 0.02
			private_before += 1
	assert_true(private_before > 0)

	for _day in 45:
		sim.advance_coarse_hours(24, false)

	var private_ruins := 0
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.owner_maintained and b.state == &"destroyed":
			private_ruins += 1
	assert_eq(private_ruins, 0,
			"45 online game-days of the worst case cost the city no private stock")


# ------------------------------------------------------------------ helpers

## The first building in roster order that is (or is not) private stock and that
## doc 02 §2.12 lets wear touch.
func _first(sim: CitySim, private: bool) -> String:
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.owner_maintained == private and b.decays():
			return String(id)
	return ""
