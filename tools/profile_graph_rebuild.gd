extends SceneTree
## Where `RoadGraph.rebuild_all()` spends its milliseconds — the measurement the
## restore split (doc 91 A91-D-30 item 4) is cut against.
##
##   godot --headless --script tools/profile_graph_rebuild.gd -- \
##       [--city=res://tests/fixtures/bench_city.json] [--repeats=5]


func _init() -> void:
	var city := "res://tests/fixtures/bench_city.json"
	var repeats := 5
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--city="):
			city = arg.substr(7)
		elif arg.begins_with("--repeats="):
			repeats = int(arg.substr(10))
	var sim := CitySim.new()
	sim.boot(1337,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(city),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	var graph: RoadGraph = sim.roads.graph
	print("%s — %d road tiles, %d nodes, %d edges" % [city,
			graph.road_tile_count(), graph.node_count(), graph.edge_count()])
	var best: Dictionary = {}
	for i in repeats:
		var held: Dictionary = {}
		var index := 0
		for entry in graph.rebuild_all_steps(held,
				RoadGraph.trace_slots_for(graph.road_tile_count())):
			var label := "%02d %s" % [index, String((entry as Array)[0])]
			index += 1
			var work: Callable = (entry as Array)[1]
			var t0 := Time.get_ticks_usec()
			work.call()
			var ms := float(Time.get_ticks_usec() - t0) / 1000.0
			if not best.has(label) or ms < float(best[label]):
				best[label] = ms
	var total := 0.0
	print("  step                 best ms")
	for label in best:
		print("  %-20s %8.3f" % [label, float(best[label])])
		total += float(best[label])
	print("  %-20s %8.3f" % ["TOTAL", total])
	quit()
