extends SceneTree
## What does laying one road tile cost the STREET SURFACE? (doc 11 §2.1.2a.)
##
## `RoadSurfaceView.rebuild()` is a stateful dirty-tile diff, and the numbers in
## §2.1.2a's table are this tool's. It boots a real `CitySim` from a city file,
## builds the view, and times three things: the full pass (what `force` and the
## boot path cost), one player edit on a settled city, and a ten-tile drag with
## one rebuild per tile — which is what a road-drawing tool feeds it. The
## breakdown underneath names every O(N) term left in the incremental pass, so a
## future optimisation can be aimed rather than guessed.
##
## Like `tools/profile_sim.gd` this is a MEASURING instrument (constitution §3):
## it owns no constant, and nothing in `sim/` or `game/` imports it.
##
## Usage:
##   ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
##       -s res://tools/profile_road_rebuild.gd -- [--city=PATH]
##
## Defaults to doc 09 §2.13's benchmark fixture; pass
## `--city=res://data/starter_city.json` for the founding city.
##
## The correctness half is NOT here — it is `tests/test_road_incremental.gd`,
## which property-tests the buffers byte for byte against a from-scratch
## rebuild. A faster wrong answer is not an optimisation.

const RENDER_JSON := "res://data/render.json"


func _initialize() -> void:
	var city := "res://tests/fixtures/bench_city.json"
	for arg in OS.get_cmdline_user_args():
		if String(arg).begins_with("--city="):
			city = String(arg).substr(7)
	var render_data: Dictionary = StarterCityLoader.read_json(RENDER_JSON)
	var sim := CitySim.new()
	sim.boot(1337,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(city),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	var grid: TileGrid = sim.world.grid
	var graph: RoadGraph = sim.roads.graph
	print("city=%s road tiles=%d" % [city, graph.road_tile_count()])

	var view := RoadSurfaceView.new()
	view.setup(render_data)
	for i in 3:
		view.rebuild(grid, graph, true)
	print("PICTURE tiles=%d footway_runs=%d" % [view.tile_count(),
			view.sidewalk_instance_count()])
	var lamps := StreetlightPlacer.place(grid, graph, render_data)
	print("PICTURE lamps=%d" % lamps.size())

	var best := 1 << 60
	for i in 15:
		var t0 := Time.get_ticks_usec()
		view.rebuild(grid, graph, true)
		best = mini(best, Time.get_ticks_usec() - t0)
	print("full rebuild        : %.3f ms" % (best / 1000.0))

	# One player edit: lay a tile, then time the incremental pass.
	var free_tile := _free_tile(grid)
	best = 1 << 60
	var samples := 0
	for i in 15:
		var t := free_tile + Vector2i(0, i * 2)
		grid.set_road(t.x, t.y, TileGrid.ROAD_STREET)
		graph.apply_edits([t])
		var guard := 0
		while graph.graph_dirty and guard < 32:
			graph.apply_edits([])
			guard += 1
		var t0 := Time.get_ticks_usec()
		view.rebuild(grid, graph)
		var took := Time.get_ticks_usec() - t0
		if not view.last_pass_incremental:
			print("  !! pass %d was not incremental" % i)
		best = mini(best, took)
		samples += 1
	print("incremental (1 tile): %.3f ms   [%d samples, %d dirty tiles last]"
			% [best / 1000.0, samples, view.last_dirty_tiles])

	# A ten-tile drag, one rebuild per tile — what the drawing tool will feed.
	var start := _free_tile(grid)
	var total := 0
	for i in 10:
		var t := start + Vector2i(i, 40)
		grid.set_road(t.x, t.y, TileGrid.ROAD_STREET)
		graph.apply_edits([t])
		var guard := 0
		while graph.graph_dirty and guard < 32:
			graph.apply_edits([])
			guard += 1
		var t0 := Time.get_ticks_usec()
		view.rebuild(grid, graph)
		total += Time.get_ticks_usec() - t0
	print("10-tile drag        : %.3f ms total (%.3f ms/tile)"
			% [total / 1000.0, total / 10000.0])
	print("--- where the incremental pass goes ---")
	var tiles: Array = graph.road_tiles_sorted()
	print("road_tiles_sorted   : %.3f ms" % _best(func() -> void:
		graph.road_tiles_sorted()))
	print("membership stamp    : %.3f ms" % _best(func() -> void:
		var stamp: Dictionary = {}
		for raw: Variant in tiles:
			stamp[raw] = 1))
	print("class sweep         : %.3f ms" % _best(func() -> void:
		var cls: Dictionary = {}
		for raw: Variant in tiles:
			var t: Vector2i = raw
			cls[t] = RoadSurfaceView._class_of(grid, graph, t)))
	print("slot rebuild        : %.3f ms" % _best(func() -> void:
		var slot: Dictionary = {}
		for i in tiles.size():
			slot[tiles[i]] = i))
	print("_cover              : %.3f ms" % _best(func() -> void:
		view._cover(tiles, -0.5, 1.0)))
	print("_upload             : %.3f ms" % _best(func() -> void:
		view._upload()))
	print("_emit_runs          : %.3f ms" % _best(func() -> void:
		view._emit_runs()))
	view.free()
	quit()


func _best(fn: Callable) -> float:
	var best := 1 << 60
	for i in 15:
		var t0 := Time.get_ticks_usec()
		fn.call()
		best = mini(best, Time.get_ticks_usec() - t0)
	return best / 1000.0


func _free_tile(grid: TileGrid) -> Vector2i:
	for y in range(2, TileGrid.SIZE - 40):
		for x in range(2, TileGrid.SIZE - 20):
			if not grid.has_flag(x, y, TileGrid.FLAG_ROAD) \
					and not grid.has_flag(x, y, TileGrid.FLAG_WATER):
				return Vector2i(x, y)
	return Vector2i(2, 2)
