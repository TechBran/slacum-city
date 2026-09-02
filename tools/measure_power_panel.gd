extends SceneTree
## What Wave 17's POWER section costs to compute, on the city where it costs most.
##
##     godot --headless --script tools/measure_power_panel.gd -- [--city=PATH]
##
## The building panel refreshes on the HUD's 1 Hz cadence, so `building_view()`
## is a once-a-second cost on the main thread and the POWER section is new work
## inside it: a service-path walk, a peak-load table, one
## `cmd_fix_power_capacity` preview and one `cmd_upgrade_grid_component` preview
## per hop. This prints the three numbers that decide whether that is affordable
## on the Fold, over 40 buildings so a single outlier cannot carry the mean.

const Bench := "res://tests/fixtures/bench_city.json"

var city_path := ""


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if text.begins_with("--city="):
			city_path = text.trim_prefix("--city=")
	var sim := _boot()
	sim.advance_hours(6.0)
	var controller := BuildController.new(sim)
	var ids: Array = sim.roster_ids()
	ids.sort()
	var sample: Array = []
	for i in mini(40, ids.size()):
		sample.append(String(ids[i * maxi(1, ids.size() / 40) % ids.size()]))

	# 1. the peak-load table, cold (the memo is dropped by the epoch bump).
	var t0 := Time.get_ticks_usec()
	for i in 10:
		sim.grid.mutation_epoch += 1
		sim.peak_component_loads()
	var peak_ms := float(Time.get_ticks_usec() - t0) / 10000.0

	# 2. the POWER block alone.
	t0 = Time.get_ticks_usec()
	for sim_id in sample:
		controller.power.building_block(String(sim_id))
	var block_ms := float(Time.get_ticks_usec() - t0) / (1000.0 * float(sample.size()))

	# 3. the whole panel view, which is what the 1 Hz refresh actually pays.
	t0 = Time.get_ticks_usec()
	for sim_id in sample:
		controller.building_view(String(sim_id))
	var view_ms := float(Time.get_ticks_usec() - t0) / (1000.0 * float(sample.size()))

	# 2b. the two halves of the block, split — the path walk the section draws,
	# and the fix quote under it, which is the only part that plans a purchase.
	t0 = Time.get_ticks_usec()
	for sim_id in sample:
		sim.grid.service_path(String(sim_id), sim.ambient_c(), sim.peak_component_loads())
	var path_ms := float(Time.get_ticks_usec() - t0) / (1000.0 * float(sample.size()))
	t0 = Time.get_ticks_usec()
	var blocked := 0
	for sim_id in sample:
		var q := controller.power.fix_quote(String(sim_id))
		if bool(q.get("available", false)):
			blocked += 1
	var fix_ms := float(Time.get_ticks_usec() - t0) / (1000.0 * float(sample.size()))

	print("  service_path                 %.3f ms / building" % path_ms)
	print("  fix_quote                    %.3f ms / building (%d of %d blocked)"
			% [fix_ms, blocked, sample.size()])
	print("measure_power_panel: city=%s buildings=%d components=%d sample=%d"
			% [city_path if city_path != "" else "starter", sim.buildings.size(),
			sim.grid.component_ids().size(), sample.size()])
	print("  peak_component_loads (cold)  %.3f ms" % peak_ms)
	print("  power.building_block         %.3f ms / building" % block_ms)
	print("  building_view (whole panel)  %.3f ms / building" % view_ms)
	sim.dispose()
	quit(0)


func _boot() -> CitySim:
	if city_path == "":
		return CitySim.boot_from_files(1337)
	var sim := CitySim.new()
	sim.boot(1337,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(city_path),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	return sim
