extends SimTest
## Wave 19, doc 93 §AP4 — **the bottom of the recovery ladder**. Measured in doc
## 92 §56.5, shipped as report 98 §59 RR-167. The defect rows are doc 91
## A91-D-103 (the era that never existed) and A91-D-104 (the grant that shrank
## with the disaster).
##
## Doc 03 §2.10 layer 5 is the last rung under a city that has fallen over, and
## the player's report of 2026-09-03 is what it looks like from underneath:
## *"there's negative money … I've been trying to restore all the buildings so we
## can get revenue back up."* These tests pin that the rung is reachable, that it
## scales with the loss instead of against it, and that it cannot be farmed.


## A91-D-103. `relief_grants_per_era` carried the word "era" since doc 03 §2.9
## and nothing in the project defined one, so the allowance was a LIFETIME three.
func test_a_city_level_opens_a_new_era() -> void:
	var sim := CitySim.boot_from_files()
	var allowed := int(sim.treasury.difficulty().get("relief_grants_per_era", 0))
	assert_true(allowed > 0, "standard publishes an allowance")

	sim.treasury.relief_grants_used = allowed
	assert_false(sim.treasury.relief_gates_pass(0, -1.0),
			"a spent allowance closes the gate")

	sim.treasury.note_era(1)
	assert_eq(sim.treasury.relief_grants_used, 0, "a new level is a new era")
	assert_eq(sim.treasury.relief_era_level, 1)


## Monotone and idempotent: the same level cannot open a second era, and a level
## already passed cannot re-open one.
func test_an_era_opens_once() -> void:
	var sim := CitySim.boot_from_files()
	sim.treasury.note_era(3)
	sim.treasury.relief_grants_used = 2
	sim.treasury.note_era(3)
	assert_eq(sim.treasury.relief_grants_used, 2, "the same level opens nothing")
	sim.treasury.note_era(2)
	assert_eq(sim.treasury.relief_grants_used, 2, "and neither does a lower one")
	sim.treasury.note_era(4)
	assert_eq(sim.treasury.relief_grants_used, 0, "a higher one does")


## A91-D-104, the ruling itself: relief is the LARGER of the revenue term and a
## fraction of the restore bill, so the worse the catastrophe the bigger the
## grant — the opposite of the shipped behaviour.
func test_relief_scales_with_the_damage_not_against_it() -> void:
	var sim := CitySim.boot_from_files()
	var t := sim.treasury
	t.update_credit_limit(0.0)
	t.balance = -t.credit_limit
	var fraction := float(sim.treasury.recovery_value("RELIEF_DAMAGE_FRACTION"))
	assert_true(fraction > 0.0 and fraction < 1.0,
			"the anti-farm is an inequality: a grant never covers its own bill")

	# A city with no revenue and no ruins gets the floor.
	var floor_grant := t.maybe_grant_relief(0, 0.0, -1.0, 0.0)
	assert_eq(floor_grant, int(sim.treasury.recovery_value("RELIEF_MIN")),
			"no revenue and no damage is RELIEF_MIN, exactly as before")

	# The same city with a large outstanding restore bill gets the damage term.
	var fresh := CitySim.boot_from_files()
	var t2 := fresh.treasury
	t2.update_credit_limit(0.0)
	t2.balance = -t2.credit_limit
	var bill := 400000.0
	var damaged_grant := t2.maybe_grant_relief(0, 0.0, -1.0, bill)
	assert_eq(damaged_grant, CostCurves.round_half_up(fraction * bill),
			"the damage term is the fraction of the bill")
	assert_true(damaged_grant > floor_grant,
			"a catastrophe raises the relief instead of shrinking it")


## The four gates that make it a rescue and not an income. Each is checked alone,
## because a gate that only works alongside another is a gate that will be
## removed by the next person who reads it.
func test_the_gates_that_stop_it_being_an_income() -> void:
	var sim := CitySim.boot_from_files()
	var t := sim.treasury
	t.update_credit_limit(0.0)

	t.balance = 0
	assert_false(t.relief_gates_pass(0, -1.0), "a solvent city draws nothing")

	t.balance = -t.credit_limit
	assert_false(t.relief_gates_pass(0, 1.0), "nor does an earning one")

	assert_true(t.relief_gates_pass(0, -1.0), "insolvent and losing money: yes")
	assert_true(t.maybe_grant_relief(0, 0.0, -1.0, 100000.0) > 0)
	var cooldown := int(sim.treasury.recovery_value("RELIEF_COOLDOWN_HOURS"))
	t.balance = -t.credit_limit
	assert_false(t.relief_gates_pass(cooldown - 1, -1.0), "the cooldown binds")
	assert_true(t.relief_gates_pass(cooldown, -1.0), "and then releases")


## Never more than `RELIEF_MAX`, however large the bill — the clamp is unchanged
## and the damage term lives inside it.
func test_the_damage_term_is_inside_the_published_clamp() -> void:
	var sim := CitySim.boot_from_files()
	var t := sim.treasury
	t.update_credit_limit(0.0)
	t.balance = -t.credit_limit
	var granted := t.maybe_grant_relief(0, 0.0, -1.0, 100000000.0)
	assert_eq(granted, int(sim.treasury.recovery_value("RELIEF_MAX")),
			"an absurd bill still lands on the published ceiling")


## The bill the grant is measured against is doc 03's OWN price for the thing the
## player has to buy — the same call `cmd_restore_building` charges — so the two
## can never disagree (C-07).
func test_the_bill_is_the_price_the_player_is_charged() -> void:
	var sim := CitySim.boot_from_files()
	assert_almost_eq(sim.outstanding_restore_cost(), 0.0, 1e-9,
			"a founding city owes nothing")

	var sim_id := ""
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.state == &"active":
			sim_id = String(id)
			b.demolish(true, 0)
			break
	assert_ne(sim_id, "", "something was standing")

	var quote := sim.cmd_restore_building(sim_id, true)
	var quoted := float((quote["payload"] as Dictionary)["cost"])
	assert_almost_eq(sim.outstanding_restore_cost(), quoted, 0.5,
			"one ruin's bill is one ruin's restore price")


## The grant is counted for life, which is A91-D-100's other half: a relief
## ladder nobody can audit is a ladder nobody can balance.
func test_relief_lands_in_the_lifetime_ledger() -> void:
	var sim := CitySim.boot_from_files()
	var t := sim.treasury
	t.update_credit_limit(0.0)
	t.balance = -t.credit_limit
	assert_eq(int(t.lifetime["lifetime_relief"]), 0)
	var granted := t.maybe_grant_relief(0, 0.0, -1.0, 200000.0)
	assert_eq(int(t.lifetime["lifetime_relief"]), granted,
			"what the state has paid this city is a number the city can quote")
