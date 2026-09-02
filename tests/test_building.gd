extends SimTest
## Doc 02 §2.6, §2.12: condition/decay (worked example E4), the eight-state
## machine, state modifier tables, and the offline destroy guard.


func _apartment_l3() -> Building:
	var b := Building.new(1, &"apartment", Vector2i(10, 10))
	b.level = 3
	b.state = &"active"
	b.stats = {"population": 82, "jobs": 7, "power_demand_kw": 130.0,
			"water_demand": 2.9, "build_hours": 14.5, "decay_per_hour": 0.000720}
	return b


func test_decay_worked_example_e4_healthy() -> void:
	var b := _apartment_l3()
	b.apply_decay(168.0)  # one game-week, healthy grid
	assert_almost_eq(b.condition, 0.879, 0.0005)
	assert_eq(b.state, &"active")


func test_decay_worked_example_e4_overloaded() -> void:
	var b := _apartment_l3()
	# 130% node load, P = 0.7: rate ×1.24 ×1.15 → 0.828 after a week.
	b.apply_decay(168.0, 0.30, 0.70)
	assert_almost_eq(b.condition, 0.828, 0.0005)
	assert_almost_eq(b.damage_fraction(), 0.172, 0.0005)
	assert_almost_eq(b.repair_crew_hours(), 1.25, 0.01, "14.5 × 0.50 × 0.172")


func test_fire_condition_mult() -> void:
	var b := _apartment_l3()
	b.condition = 1.0
	assert_almost_eq(b.fire_condition_mult(), 1.0, 1e-9)
	b.condition = 0.5
	assert_almost_eq(b.fire_condition_mult(), 1.53, 0.005)
	b.condition = 0.0
	assert_almost_eq(b.fire_condition_mult(), 2.5, 1e-9)


func test_auto_damage_at_threshold() -> void:
	var b := _apartment_l3()
	b.condition = 0.36
	var events := b.apply_decay(20.0)  # crosses 0.35
	assert_eq(b.state, &"damaged")
	assert_eq(events.size(), 1)
	assert_eq(events[0]["type"], &"building_damaged")


func test_damaged_decays_faster() -> void:
	var a := _apartment_l3()
	var d := _apartment_l3()
	d.state = &"damaged"
	a.apply_decay(100.0)
	d.apply_decay(100.0)
	var a_loss := 1.0 - a.condition
	var d_loss := 1.0 - d.condition
	assert_almost_eq(d_loss / a_loss, 1.5, 0.001, "damaged decays ×1.5")


func test_structural_failure_deterministic() -> void:
	# Same seed ⇒ same outcome; low condition eventually collapses.
	var outcomes: Array = []
	for run in 2:
		var b := _apartment_l3()
		b.state = &"damaged"
		b.condition = 0.05
		var rng := RngStreams.new(1234)
		var destroyed_at := -1
		for hour in 500:
			var events := b.roll_structural_failure(rng, 1.0, hour * 60)
			if not events.is_empty():
				destroyed_at = hour
				break
		outcomes.append(destroyed_at)
	assert_eq(outcomes[0], outcomes[1], "seeded determinism")
	assert_true(int(outcomes[0]) >= 0, "0.02/gh collapses within 500 h")
	# Above the threshold: never rolls.
	var safe := _apartment_l3()
	safe.state = &"damaged"
	safe.condition = 0.5
	assert_eq(safe.roll_structural_failure(RngStreams.new(1), 1000.0, 0).size(), 0)


func test_new_build_lifecycle() -> void:
	var b := Building.new(2, &"house", Vector2i(3, 3))
	assert_eq(b.state, &"planned")
	assert_almost_eq(b.output_mult(), 0.0, 1e-9)
	assert_true(bool(b.start_construction()["ok"]))
	assert_true(b.is_new_build())
	assert_almost_eq(b.power_demand_mult(), 0.15, 1e-9, "site power only")
	assert_almost_eq(b.water_demand_mult(), 0.10, 1e-9)
	var done := b.complete_construction()
	assert_true(bool(done["ok"]))
	assert_eq(b.level, 1)
	assert_eq(b.state, &"active")
	assert_almost_eq(b.condition, 1.0, 1e-9)


func test_upgrade_lifecycle_and_the_starvation_row() -> void:
	var b := _apartment_l3()
	assert_true(bool(b.start_upgrade()["ok"]))
	assert_eq(b.pending_level, 4)
	assert_true(b.is_upgrade_in_progress())
	# §2.12: an upgrading tower keeps its old draw at a third of its output.
	assert_almost_eq(b.power_demand_mult(), 1.0, 1e-9)
	assert_almost_eq(b.output_mult(), 0.35, 1e-9)
	assert_almost_eq(b.state_occupancy(), 0.50, 1e-9)
	var done := b.complete_construction()
	assert_true(bool(done["ok"]))
	assert_eq(b.level, 4)
	assert_almost_eq(b.condition, 1.0, 1e-9)


func test_upgrade_preconditions_local() -> void:
	var b := _apartment_l3()
	b.condition = 0.50
	assert_eq(b.start_upgrade()["reason_code"], &"E_CONDITION")
	b.condition = 1.0
	b.level = 5
	assert_eq(b.start_upgrade()["reason_code"], &"E_MAX_LEVEL")
	b.level = 3
	b.state = &"damaged"
	assert_eq(b.start_upgrade()["reason_code"], &"E_STATE")


func test_cancel_upgrade_restores_active() -> void:
	var b := _apartment_l3()
	b.condition = 0.9
	b.start_upgrade()
	var cancelled := b.cancel_upgrade()
	assert_true(bool(cancelled["ok"]))
	assert_almost_eq(float(cancelled["payload"]["refund_fraction"]), 0.50, 1e-9)
	assert_eq(b.state, &"active")
	assert_eq(b.level, 3)
	assert_almost_eq(b.condition, 0.9, 1e-9, "condition unchanged")


func test_fire_path_suppressed() -> void:
	var b := _apartment_l3()
	assert_true(bool(b.ignite()["ok"]))
	assert_eq(b.state, &"on_fire")
	assert_almost_eq(b.power_demand_mult(), 0.0, 1e-9)
	assert_almost_eq(b.state_fire_mult(), 0.0, 1e-9, "cannot re-ignite")
	var out := b.suppress_fire(0.45)
	assert_true(bool(out["ok"]))
	assert_eq(b.state, &"damaged")
	assert_almost_eq(b.condition, 0.55, 1e-9, "condition set from residual damage")


func test_burn_down_guarded_offline() -> void:
	var b := _apartment_l3()
	b.ignite()
	b.condition = 0.05
	# Offline: destroy refused VISIBLY, condition clamped to 0.15, still burning.
	var refused := b.burn_down(false, 5000)
	assert_false(bool(refused["ok"]))
	assert_eq(refused["reason_code"], &"E_DESTROY_SUPPRESSED_OFFLINE")
	assert_eq(b.state, &"on_fire")
	assert_almost_eq(b.condition, 0.15, 1e-9, "doc 08 clamp")
	# Online: it burns down.
	var burned := b.burn_down(true, 6000)
	assert_true(bool(burned["ok"]))
	assert_eq(b.state, &"destroyed")
	assert_eq(b.level_at_destruction, 3)


## Wave 18, doc 93 §AN. This test used to be `test_rebuild_grace_window` and it
## asserted the two halves that ruling retired: a 72-game-hour clock, and a
## demotion to L1 after it. **The level now survives, at any age**, and the age
## itself comes back as a FACT rather than a price — `sim/buildings/` carries no
## dollar and no dollar fraction (report 98 C-07), so there is no `cost_fraction`
## left to assert.
func test_the_level_survives_a_rebuild_at_any_age() -> void:
	var b := _apartment_l3()
	b.ignite()
	b.burn_down(true, 1000 * 60)
	var soon := b.order_rebuild((1000 + 60) * 60)
	assert_true(bool(soon["ok"]))
	assert_eq(int(soon["payload"]["rebuild_level"]), 3, "one game-hour later: L3")
	assert_almost_eq(float(soon["payload"]["hours_destroyed"]), 60.0, 1e-9)
	assert_false(soon["payload"].has("cost_fraction"), "no price lives in sim/buildings/")
	assert_eq(b.state, &"planned")
	assert_eq(b.pending_level, 3)
	# A hundred game-hours later — past the retired 72-hour window, and well
	# inside doc 08's own 720-hour offline cap, which is the whole reason the
	# window was wrong.
	var b2 := _apartment_l3()
	b2.ignite()
	b2.burn_down(true, 1000 * 60)
	var late := b2.order_rebuild((1000 + 100 * 60) * 60)
	assert_true(bool(late["ok"]))
	assert_eq(int(late["payload"]["rebuild_level"]), 3,
			"a ruin does not get shorter while the player is asleep")
	assert_almost_eq(float(late["payload"]["hours_destroyed"]), 6000.0, 1e-9)
	# And a thousand game-hours later, past the cap itself.
	var b3 := _apartment_l3()
	b3.ignite()
	b3.burn_down(true, 1000 * 60)
	assert_eq(int(b3.order_rebuild((1000 + 1000 * 60) * 60)["payload"]["rebuild_level"]), 3)


func test_repair_targets() -> void:
	var damaged := _apartment_l3()
	damaged.state = &"damaged"
	damaged.condition = 0.30
	var started := damaged.start_repair()
	assert_almost_eq(float(started["payload"]["repair_target"]), 0.85, 1e-9)
	damaged.complete_repair(0.85)
	assert_eq(damaged.state, &"active")
	assert_almost_eq(damaged.condition, 0.85, 1e-9, "post-damage repairs never restore to new")
	var preventive := _apartment_l3()
	preventive.condition = 0.70
	var started2 := preventive.start_repair()
	assert_almost_eq(float(started2["payload"]["repair_target"]), 1.0, 1e-9)
	preventive.complete_repair(1.0)
	assert_almost_eq(preventive.condition, 1.0, 1e-9)


func test_repair_interrupted() -> void:
	var b := _apartment_l3()
	b.state = &"damaged"
	b.condition = 0.30
	b.start_repair()
	assert_true(bool(b.interrupt_repair()["ok"]))
	assert_eq(b.state, &"damaged")


func test_serialize_roundtrip() -> void:
	var b := _apartment_l3()
	b.start_upgrade()
	var restored := Building.deserialize(b.serialize())
	assert_eq(restored.archetype, &"apartment")
	assert_eq(restored.level, 3)
	assert_eq(restored.pending_level, 4)
	assert_eq(restored.state, &"under_construction")
	assert_eq(restored.origin, Vector2i(10, 10))


# ------------------------- doc 02 §2.6a / §2.6 — PA-13's readers and ownership

## PA-13's own gate, and the reason this pass could not simply edit the JSON:
## every key in `data/building_rules.json.condition` was validated for presence,
## asserted by `tests/test_building_catalog.gd`, and read by NOTHING. The test is
## therefore not "the loader accepted the key" — it is "perturb the key and the
## BEHAVIOUR moves" (doc 93 §Y2).
func test_pa13_condition_keys_move_behaviour() -> void:
	var b := _apartment_l3()
	b.condition = 0.40
	b.apply_decay(1.0)
	assert_eq(b.state, &"active", "0.35 is the shipped auto-damage line")
	var perturbed := _apartment_l3()
	perturbed.condition_rules = Building.DEFAULT_CONDITION.duplicate()
	perturbed.condition_rules["auto_damage_threshold"] = 0.45
	perturbed.condition = 0.40
	perturbed.apply_decay(1.0)
	assert_eq(perturbed.state, &"damaged",
			"auto_damage_threshold is READ, not hardcoded (PA-13)")


func test_pa13_decay_coefficients_are_read() -> void:
	var flat := _apartment_l3()
	flat.condition_rules = Building.DEFAULT_CONDITION.duplicate()
	flat.condition_rules["unpowered_decay_coefficient"] = 0.0
	flat.apply_decay(168.0, 0.0, 0.0)
	var shipped := _apartment_l3()
	shipped.apply_decay(168.0, 0.0, 0.0)
	assert_true(flat.condition > shipped.condition,
			"unpowered_decay_coefficient is READ: 0.0 must wear less than 0.50")
	var no_overload := _apartment_l3()
	no_overload.condition_rules = Building.DEFAULT_CONDITION.duplicate()
	no_overload.condition_rules["overload_decay_coefficient"] = 0.0
	no_overload.apply_decay(168.0, 0.30, 1.0)
	var with_overload := _apartment_l3()
	with_overload.apply_decay(168.0, 0.30, 1.0)
	assert_true(no_overload.condition > with_overload.condition,
			"overload_decay_coefficient is READ")


func test_pa13_repair_time_factor_and_targets_are_read() -> void:
	var b := _apartment_l3()
	b.condition = 0.50
	assert_almost_eq(b.repair_crew_hours(), 14.5 * 0.50 * 0.50, 1e-9)
	b.condition_rules = Building.DEFAULT_CONDITION.duplicate()
	b.condition_rules["repair_time_factor"] = 0.25
	assert_almost_eq(b.repair_crew_hours(), 14.5 * 0.25 * 0.50, 1e-9,
			"repair_time_factor is READ")
	b.state = &"damaged"
	assert_almost_eq(b.repair_target(), 0.85, 1e-9)
	b.condition_rules["repair_target_damaged"] = 0.70
	assert_almost_eq(b.repair_target(), 0.70, 1e-9, "repair_target_damaged is READ")


func test_pa13_min_condition_to_upgrade_is_read() -> void:
	var b := _apartment_l3()
	b.condition = 0.60
	b.max_level = 6
	assert_true(bool(b.start_upgrade()["ok"]), "0.60 clears the shipped 0.55")
	var strict := _apartment_l3()
	strict.condition_rules = Building.DEFAULT_CONDITION.duplicate()
	strict.condition_rules["min_condition_to_upgrade"] = 0.75
	strict.condition = 0.60
	strict.max_level = 6
	var refused := strict.start_upgrade()
	assert_false(bool(refused["ok"]))
	assert_eq(refused["reason_code"], &"E_CONDITION",
			"min_condition_to_upgrade is READ (PA-13)")


## Doc 93 §Y1: a SERVED private building wears exactly as §2.6 says and then
## STOPS at the Worn band's floor. It never reaches the auto-damage line from
## wear, and the floor is above `min_condition_to_upgrade` — the ordering that
## makes it a floor rather than a trap.
func test_owner_maintained_building_floors_at_band_worn_while_served() -> void:
	var b := _apartment_l3()
	b.owner_maintained = true
	var lowest := 1.0
	var events := 0
	for i in range(4000):
		events += b.apply_decay(1.0, 0.0, 1.0).size()
		lowest = minf(lowest, b.condition)
	assert_eq(b.state, &"active", "4000 game-hours of wear, never damaged")
	assert_eq(events, 0, "and never an event: routine private wear is silent")
	assert_almost_eq(b.condition, 0.60, 1e-9,
			"it settles exactly on condition.band_worn")
	assert_almost_eq(lowest, 0.60, 1e-9, "and never goes below it")
	assert_true(b.condition > b.min_condition_to_upgrade(),
			"the floor is ABOVE the upgrade gate (0.60 > 0.55) — otherwise it "
			+ "would be a trap, not a floor, because the recovery is an upgrade")


## …and the wear ITSELF is untouched: the first 800 game-hours of an
## owner-maintained building are bit-identical to an unowned one, because doc 93
## §Y1 moved no `decay_per_hour` cell. Only the floor is new.
func test_owner_maintenance_moves_no_decay_rate() -> void:
	var owned := _apartment_l3()
	owned.owner_maintained = true
	var plain := _apartment_l3()
	for i in range(500):
		owned.apply_decay(1.0, 0.0, 1.0)
		plain.apply_decay(1.0, 0.0, 1.0)
	assert_true(plain.condition > 0.60, "the control has not reached the floor yet")
	assert_eq(owned.condition, plain.condition,
			"identical wear until the floor binds — the ruling is a floor, "
			+ "not a rate change")


## Doc 93 §Y1a — the service clause. A building the city has left DARK is not
## maintained at all: it wears, it reaches the line, and it emits. This is the
## half of the ruling that keeps gate 29's neglect fatal.
func test_owner_maintenance_stops_when_the_city_stops_serving() -> void:
	var b := _apartment_l3()
	b.owner_maintained = true
	var events := 0
	var hours := 0
	while hours < 4000 and b.state == &"active":
		events += b.apply_decay(1.0, 0.0, 0.0).size()
		hours += 1
	assert_eq(b.state, &"damaged", "a dark private building still fails")
	assert_eq(events, 1, "exactly one building_damaged, when it crosses")
	assert_true(hours < 4000, "and it gets there: %d game-hours" % hours)
	assert_true(b.condition < 0.60,
			"the floor lifted with the lights — %.3f" % b.condition)


## The owner rebuilds after an incident to §2.12's post-damage target, and says
## so with `cause: owner` so a surface can tell it from a city crew's work.
func test_owner_rebuilds_after_damage_with_its_own_cause() -> void:
	var b := _apartment_l3()
	b.owner_maintained = true
	b.condition = 0.20
	b.state = &"damaged"
	var seen := {}
	for i in range(200):
		for event in b.apply_decay(1.0, 0.0, 1.0):
			seen[String(event["type"])] = String(event.get("cause", ""))
		if b.state == &"active":
			break
	assert_eq(b.state, &"active")
	assert_eq(seen.get("building_repaired", ""), "owner",
			"an owner's rebuild is labelled as one")
	assert_true(b.condition >= 0.85)


## And the default is OFF: a `Building` nobody stamped is the pre-Wave-17
## building, which is what keeps every fixture in this file true.
func test_owner_maintenance_defaults_off() -> void:
	var b := _apartment_l3()
	assert_false(b.owner_maintained)
	b.apply_decay(168.0)
	assert_almost_eq(b.condition, 0.879, 0.0005,
			"worked example E4 is unmoved by the ruling")
	# …and it is unmoved WITH the flag on too, because 0.879 is above the floor.
	var owned := _apartment_l3()
	owned.owner_maintained = true
	owned.apply_decay(168.0)
	assert_almost_eq(owned.condition, 0.879, 0.0005,
			"E4 is above band_worn, so the floor does not touch it either")
