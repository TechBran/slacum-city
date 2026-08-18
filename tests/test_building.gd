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


func test_rebuild_grace_window() -> void:
	var b := _apartment_l3()
	b.ignite()
	b.burn_down(true, 1000 * 60)
	# Within 72 gh: rebuild at the destroyed level for 0.60 × cost.
	var soon := b.order_rebuild((1000 + 60) * 60)
	assert_true(bool(soon["payload"]["within_grace"]))
	assert_eq(int(soon["payload"]["rebuild_level"]), 3)
	assert_almost_eq(float(soon["payload"]["cost_fraction"]), 0.60, 1e-9)
	# Reset and try after the grace window: back to L1 at full price.
	var b2 := _apartment_l3()
	b2.ignite()
	b2.burn_down(true, 1000 * 60)
	var late := b2.order_rebuild((1000 + 100 * 60) * 60)
	assert_false(bool(late["payload"]["within_grace"]))
	assert_eq(int(late["payload"]["rebuild_level"]), 1)


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
