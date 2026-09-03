extends SimTest
## Milestone 1 closing criteria (master plan §5): fine/coarse agreement,
## save → load → advance identity through the SaveManager, and the P0-30
## coarse-step cost measurement.


class CitySection extends SaveSection:
	var body: Dictionary = {}

	func section_key() -> StringName:
		return &"city"

	func serialize() -> Dictionary:
		return body

	func deserialize(data: Dictionary) -> void:
		body = data


static func _wipe(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			_wipe(path + "/" + entry)
			DirAccess.remove_absolute(path + "/" + entry)
		else:
			DirAccess.remove_absolute(path + "/" + entry)
		entry = dir.get_next()
	dir.list_dir_end()


func test_fine_coarse_treasury_agreement() -> void:
	# Criterion 5: 24 coarse hours vs 5,760 fine ticks agree on the treasury
	# within 5% (deterministic constant-input hours agree near-exactly).
	# Ambient incident generation is OFF for this comparison: doc 06 §2.6
	# sanctions different Poisson draw counts per step size, so a spawned
	# incident in one mode is not a mode-invariance failure — doc 06's own
	# suite bounds its sub-step parity. This test guards the DETERMINISTIC
	# core: clock, population, happiness, and the settled economy.
	var fine := CitySim.boot_from_files(777)
	var coarse := CitySim.boot_from_files(777)
	fine.incidents.generation_enabled = false
	coarse.incidents.generation_enabled = false
	fine.advance_hours(24.0)
	coarse.advance_coarse_hours(24)
	assert_eq(fine.clock.tick_index, coarse.clock.tick_index, "same game time elapsed")
	var fine_net: int = fine.treasury.balance
	var coarse_net: int = coarse.treasury.balance
	assert_true(absi(fine_net - coarse_net) <= maxi(5, int(absi(fine_net) / 20)),
			"treasuries agree (fine %d vs coarse %d)" % [fine_net, coarse_net])
	# The coarse path also keeps availability and population coherent.
	assert_eq(coarse.population.city_population, fine.population.city_population)
	assert_true(absf(coarse.happiness.happiness - fine.happiness.happiness) < 0.5)


func test_save_load_advance_identity() -> void:
	# Criterion 8: save at hour 5, load into a fresh instance, advance both
	# 1,000 more ticks → identical state hashes.
	_wipe("user://test_saves/m1")
	var a := CitySim.boot_from_files(2026)
	a.advance_hours(5.0)
	var manager := SaveManager.new("user://test_saves/m1")
	var section := CitySection.new()
	section.body = a.canonical_capture()  # saving commits A to the canonical state
	manager.register_section(section)
	var saved := manager.request_save("manual", a.clock.sim_time_minutes(), 1_700_000)
	assert_true(bool(saved["ok"]))

	var b := CitySim.boot_from_files(2026)
	var loader := SaveManager.new("user://test_saves/m1")
	var restored_section := CitySection.new()
	loader.register_section(restored_section)
	var loaded := loader.load_newest()
	assert_true(bool(loaded["ok"]))
	b.restore_state(restored_section.body)
	assert_eq(b.clock.tick_index, a.clock.tick_index)
	assert_eq(b.treasury.balance, a.treasury.balance)

	a.scheduler.advance_fine_n(1000)
	b.scheduler.advance_fine_n(1000)
	assert_eq(a.state_hash(), b.state_hash(),
			"the loaded city is indistinguishable from the one that never left")


func test_coarse_step_cost_budget() -> void:
	# P0-30 (report 98 C-21): measure, don't argue. This is the STARTER city
	# (34 buildings); the authoritative measurement re-runs on the 800-building
	# reference fixture when tools/gen_bench_city.py lands. Wall-clock use is
	# legal here — tests are not sim/ (the scan test guards sim/ only).
	var sim := CitySim.boot_from_files()
	sim.advance_coarse_hours(2)  # warm caches outside the timed window
	var start := Time.get_ticks_usec()
	sim.advance_coarse_hours(24)
	var elapsed_ms := float(Time.get_ticks_usec() - start) / 1000.0
	var per_step := elapsed_ms / 24.0
	print("  [P0-30] coarse step on starter city: %.2f ms/step (24 steps in %.1f ms)"
			% [per_step, elapsed_ms])
	# RR-161: the budget this feeds is the VEIL's, not the player's. It used to
	# print `max_coarse_hours` — a clamp on the CREDITED ABSENCE derived from
	# this very number, which is how a 5.488 ms measurement came to cost a
	# sleeping player 42.5% of a twelve-hour night (doc 92 §55).
	var veil_ms := CatchUpPlanner.veil_ms_at_cap(per_step)
	print("  [P0-30] whole 12-real-hour catch-up at that step: %.0f ms of veil" % veil_ms)
	assert_true(per_step < 50.0, "starter-city coarse step must be far under budget")
	assert_true(veil_ms > 0.0, "a measured step estimates a veil")
