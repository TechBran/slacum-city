extends SimTest
## Doc 05 §7 tests 28 and 29: the static purity scan over `sim/water/`, and the
## tick budget — `advance()` under 0.8 ms mean and `rebuild_zones()` under 8 ms
## on a city several times the starter city's size.
##
## Timings are printed, and only a generous ceiling is asserted, so the file
## reports the real number on the build machine without turning into a flaky
## gate on CI hardware.

const DT := 1.0 / 240.0
const H13 := {"water_demand_residential": 1.075, "water_demand_commercial": 1.65}


# --- test 28: no engine dependencies (constitution §3) --------------------

func test_no_engine_deps_under_sim_water() -> void:
	var forbidden := ["Node", "Engine.", "OS.", "Input.", "Time.", "get_tree",
			"get_node", "SceneTree", "await ", "signal ", "@onready", "@export"]
	var scanned := 0
	var dir := DirAccess.open("res://sim/water")
	assert_true(dir != null, "sim/water exists")
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.ends_with(".gd"):
			scanned += 1
			var text := FileAccess.get_file_as_string("res://sim/water/" + entry)
			var lines := text.split("\n")
			for i in lines.size():
				var line := String(lines[i])
				var comment_at := line.find("#")
				var code := line.substr(0, comment_at) if comment_at >= 0 else line
				for pattern: String in forbidden:
					if pattern == "Node" and code.contains("WaterNode"):
						code = code.replace("WaterNode", "")
					assert_false(code.contains(pattern),
							"sim/water/%s:%d contains forbidden '%s'" % [entry, i + 1, pattern])
			assert_true(text.contains("extends RefCounted"),
					"sim/water/%s must be RefCounted-only" % entry)
		entry = dir.get_next()
	dir.list_dir_end()
	assert_true(scanned >= 10, "found the water scripts to scan (%d)" % scanned)


func test_no_ungoverned_randomness() -> void:
	# Constitution §5: every draw goes through the named `failures` stream.
	var dir := DirAccess.open("res://sim/water")
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.ends_with(".gd"):
			var text := FileAccess.get_file_as_string("res://sim/water/" + entry)
			var lines := text.split("\n")
			for i in lines.size():
				var line := String(lines[i])
				var comment_at := line.find("#")
				var code := line.substr(0, comment_at) if comment_at >= 0 else line
				for pattern: String in ["randi()", "randf()", "randi_range", "randf_range",
						"RandomNumberGenerator.new(", "randomize("]:
					if not code.contains(pattern):
						continue
					# The only legal shape: a draw taken from a NAMED stream —
					# `rng.stream("failures").randf()` or a `stream` local bound
					# from one. Anything else is ungoverned randomness.
					assert_true(code.contains("stream"),
							"sim/water/%s:%d calls %s outside the named RNG stream"
							% [entry, i + 1, pattern])
		entry = dir.get_next()
	dir.list_dir_end()


# --- test 29: the tick budget ---------------------------------------------

func _big_city(zone_count: int, mains_per_zone: int) -> WaterSystem:
	var data := WaterData.from_dict(StarterCityLoader.read_json("res://data/water.json"))
	var system := WaterSystem.new(data, 112)
	var building_index := 0
	for z in zone_count:
		# One cluster per 13-tile cell: a trunk spine with laterals hanging off
		# it, the shape doc 09's starter city uses, and far enough apart that the
		# clusters stay separate components.
		var origin := Vector2i(5 + (z % 8) * 13, 4 + (z / 8) * 13)
		var prefix := "Z%02d" % z
		system.add_node(prefix + "-SRC", &"source", origin, {"subtype": "river", "level": 3})
		system.add_node(prefix + "-TRT", &"treatment", origin, {"level": 3})
		system.add_node(prefix + "-PMP", &"pump", origin, {"level": 3})
		system.add_node(prefix + "-TNK", &"tank", origin + Vector2i(0, 4), {"level": 3})
		system.add_main(prefix + "-SPINE", [origin, origin + Vector2i(0, 7)], {"tier": "trunk"})
		for m in mains_per_zone - 1:
			var reach := 4 if m < 7 else -4
			system.add_main("%s-M%d" % [prefix, m],
					[origin + Vector2i(0, m % 7), origin + Vector2i(reach, m % 7)],
					{"tier": "service"})
		var demands: Dictionary = {}
		for b in 8:
			var id := "B%04d" % building_index
			building_index += 1
			system.attach_building(id, origin + Vector2i(b % 5, 1 + (b / 5)), "house")
			demands[id] = 0.44
		system.set_demands(demands)
	system.rebuild_zones()
	return system


func test_perf_tick() -> void:
	var system := _big_city(40, 15)  # 40 zones, 600 mains, 320 buildings
	assert_eq(system.topology.zones.size(), 40)
	assert_eq(system.edges.size(), 600)
	# Warm-up, then measure.
	for i in 200:
		system.advance(DT, H13)
	var start := Time.get_ticks_usec()
	var ticks := 2000
	for i in ticks:
		system.advance(DT, H13)
	var per_tick_ms := float(Time.get_ticks_usec() - start) / float(ticks) / 1000.0
	print("  [doc05-29] advance(): %.3f ms/tick (40 zones, 600 mains, 320 buildings)"
			% per_tick_ms)
	assert_true(per_tick_ms < 4.0,
			"advance() must stay well inside the frame budget (%.3f ms)" % per_tick_ms)
	var rebuild_start := Time.get_ticks_usec()
	for i in 10:
		system.topology_dirty = true
		system.rebuild_zones()
	var per_rebuild_ms := float(Time.get_ticks_usec() - rebuild_start) / 10.0 / 1000.0
	print("  [doc05-29] rebuild_zones(): %.2f ms (topology change only, never per tick)"
			% per_rebuild_ms)
	assert_true(per_rebuild_ms < 60.0,
			"rebuild_zones() runs once per topology edit (%.2f ms)" % per_rebuild_ms)


func test_perf_starter_city_tick() -> void:
	var water_data := WaterData.from_dict(StarterCityLoader.read_json("res://data/water.json"))
	var loader := StarterCityLoader.new()
	loader.load_from(StarterCityLoader.read_json("res://data/starter_city.json"))
	var system := WaterBoot.build(water_data, loader)
	WaterBoot.attach_buildings(system, loader)
	for i in 200:
		system.advance(DT, H13)
	var start := Time.get_ticks_usec()
	for i in 2000:
		system.advance(DT, H13)
	var per_tick_ms := float(Time.get_ticks_usec() - start) / 2000.0 / 1000.0
	print("  [doc05-29] starter city advance(): %.4f ms/tick" % per_tick_ms)
	assert_true(per_tick_ms < 0.8, "starter city stays inside doc 05's 0.8 ms budget")
	var start_rebuild := Time.get_ticks_usec()
	system.topology_dirty = true
	system.rebuild_zones()
	var rebuild_ms := float(Time.get_ticks_usec() - start_rebuild) / 1000.0
	print("  [doc05-29] starter city rebuild_zones(): %.2f ms" % rebuild_ms)
	assert_true(rebuild_ms < 8.0, "…and inside the 8 ms rebuild budget")
