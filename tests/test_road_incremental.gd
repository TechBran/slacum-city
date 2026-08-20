extends SimTest
## The INCREMENTAL street rebuild (doc 11 §2.1.2, the streets branch's open
## question 2).
##
## `RoadSurfaceView.rebuild()` stopped being a pure function of (grid, graph)
## and became a stateful diff, because a full pass is 18.3 ms on the benchmark
## city and it fires on every road the player lays. A stateful diff has exactly
## one contract and this file is nothing but that contract:
##
##   **After ANY sequence of edits, both uploaded buffers are byte-identical to
##   a from-scratch rebuild of the same city.**
##
## Byte-identical is literal here. `asphalt_buffer()` / `sidewalk_buffer()` are
## the PackedFloat32Arrays `_upload()` hands to `MultiMesh.buffer`, so comparing
## them compares what the RenderingServer was told, float for float, on a
## `--headless` run where the server itself reads back nothing (the DUMMY
## driver stores no instance data — `MultiMesh.buffer` comes back empty, which
## is why the view keeps its own mirror at all).
##
## The tests are property tests on purpose. A hand-picked edit exercises the
## case its author thought of; the defect shape here is a dependency radius
## that is one tile too small, and the only thing that finds that is a lot of
## random edits on a lot of random cities. Tests 05 and 06 run 40 sequences of
## 12 edits each and compare every intermediate state.

const RENDER := "res://data/render.json"


func _render() -> Dictionary:
	return StarterCityLoader.read_json(RENDER)


func _view() -> RoadSurfaceView:
	var view := RoadSurfaceView.new()
	view.setup(_render())
	return view


## A grid + graph pair, built from a tile → class map.
func _rig(tiles: Dictionary, water: Array = []) -> Dictionary:
	var grid := TileGrid.new()
	for raw: Variant in tiles:
		var t: Vector2i = raw
		grid.set_road(t.x, t.y, int(tiles[t]))
	for raw: Variant in water:
		var t: Vector2i = raw
		grid.set_flag(t.x, t.y, TileGrid.FLAG_WATER)
	var tun := RoadTunables.from_file("res://data/roads.json")
	var graph := RoadGraph.new(grid, tun)
	graph.rebuild_all()
	return {"grid": grid, "graph": graph}


static func _line(from_tile: Vector2i, to_tile: Vector2i, road_class: int,
		into: Dictionary = {}) -> Dictionary:
	var step := Vector2i(signi(to_tile.x - from_tile.x), signi(to_tile.y - from_tile.y))
	var cursor := from_tile
	into[cursor] = road_class
	while cursor != to_tile:
		cursor += step
		into[cursor] = road_class
	return into


## A small grid city: streets every `pitch` tiles inside `span`, with one
## two-tile avenue pair down the middle so the dual-carriageway rules are live.
static func _grid_city(origin: Vector2i, span: int, pitch: int) -> Dictionary:
	var tiles: Dictionary = {}
	var x := origin.x
	while x <= origin.x + span:
		_line(Vector2i(x, origin.y), Vector2i(x, origin.y + span),
				TileGrid.ROAD_STREET, tiles)
		x += pitch
	var y := origin.y
	while y <= origin.y + span:
		_line(Vector2i(origin.x, y), Vector2i(origin.x + span, y),
				TileGrid.ROAD_STREET, tiles)
		y += pitch
	var mid := origin.x + (span / (2 * pitch)) * pitch
	_line(Vector2i(mid, origin.y), Vector2i(mid, origin.y + span),
			TileGrid.ROAD_AVENUE, tiles)
	_line(Vector2i(mid + 1, origin.y), Vector2i(mid + 1, origin.y + span),
			TileGrid.ROAD_AVENUE, tiles)
	return tiles


## Rebuild a SECOND view from scratch on the same world, and compare buffers.
func _assert_matches_fresh(view: RoadSurfaceView, grid: TileGrid, graph: RoadGraph,
		what: String) -> void:
	var fresh := _view()
	fresh.rebuild(grid, graph, true)
	assert_true(fresh.last_pass_incremental == false, "%s: the reference is a full pass" % what)
	assert_eq(view.tile_count(), fresh.tile_count(), "%s: same tile count" % what)
	assert_eq(view.sidewalk_instance_count(), fresh.sidewalk_instance_count(),
			"%s: same footway instance count" % what)
	var a := view.asphalt_buffer()
	var b := fresh.asphalt_buffer()
	assert_eq(a.size(), b.size(), "%s: asphalt buffer is the same length" % what)
	var bad := -1
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]:
			bad = i
			break
	assert_eq(bad, -1, "%s: asphalt buffer byte-identical (first differing float %d)"
			% [what, bad])
	var c := view.sidewalk_buffer()
	var d := fresh.sidewalk_buffer()
	assert_eq(c.size(), d.size(), "%s: footway buffer is the same length" % what)
	bad = -1
	for i in mini(c.size(), d.size()):
		if c[i] != d[i]:
			bad = i
			break
	assert_eq(bad, -1, "%s: footway buffer byte-identical (first differing float %d)"
			% [what, bad])
	fresh.free()


## Apply one edit to grid + graph the way the sim does: the grid is
## authoritative, `apply_edits` re-reads membership for the dirty set.
static func _edit(grid: TileGrid, graph: RoadGraph, t: Vector2i, road_class: int) -> void:
	grid.set_road(t.x, t.y, road_class)
	graph.apply_edits([t])
	# The retrace is BUDGETED (doc 10 §2.5); drain it, so the graph the view
	# reads is the graph a from-scratch boot would produce.
	var guard := 0
	while graph.graph_dirty and guard < 32:
		graph.apply_edits([])
		guard += 1


# ══════════════════════ 1. the diff actually runs ══════════════════════════

func test_01_the_second_pass_takes_the_diff() -> void:
	var rig := _rig(_grid_city(Vector2i(20, 20), 24, 6))
	var grid: TileGrid = rig["grid"]
	var graph: RoadGraph = rig["graph"]
	var view := _view()
	view.rebuild(grid, graph)
	assert_eq(view.incremental_passes, 0, "the boot pass is a full one")
	assert_false(view.last_pass_incremental, "…and says so")
	_edit(grid, graph, Vector2i(23, 23), TileGrid.ROAD_STREET)
	view.rebuild(grid, graph)
	assert_eq(view.incremental_passes, 1, "the next pass takes the diff")
	assert_true(view.last_pass_incremental, "…and says so")
	# One tile is one dependency ball, not a city. 25 tiles is the Manhattan
	# r=3 ball; the intersection with the road layer is a good deal smaller.
	assert_true(view.last_dirty_tiles < 25,
			"one edit re-classifies a neighbourhood, not the city (%d tiles of %d)"
			% [view.last_dirty_tiles, view.tile_count()])
	view.free()


func test_02_force_throws_the_memory_away() -> void:
	var rig := _rig(_grid_city(Vector2i(20, 20), 18, 6))
	var grid: TileGrid = rig["grid"]
	var graph: RoadGraph = rig["graph"]
	var view := _view()
	view.rebuild(grid, graph)
	_edit(grid, graph, Vector2i(24, 24), TileGrid.ROAD_STREET)
	view.rebuild(grid, graph)
	assert_eq(view.incremental_passes, 1, "diffed once")
	# `force` is what a swapped sim (a mid-session load) takes, and it must not
	# diff against a city that no longer exists.
	view.rebuild(grid, graph, true)
	assert_eq(view.incremental_passes, 1, "`force` is a full pass")
	assert_false(view.last_pass_incremental, "…and says so")
	_assert_matches_fresh(view, grid, graph, "after force")
	view.free()


# ══════════════════ 2. the contract, on hand-picked shapes ═════════════════

func test_03_single_edits_of_every_kind() -> void:
	# Each row is (label, tile, class). Together they cover the four shapes the
	# dependency radii were derived for: a new stub, a tile that closes a
	# junction, an in-place class UPGRADE (the case `added_edges` cannot see),
	# and a bulldoze.
	var cases: Array = [
		["a new stub off a corridor", Vector2i(27, 26), TileGrid.ROAD_STREET],
		["closing a junction", Vector2i(26, 26), TileGrid.ROAD_STREET],
		["an upgrade in place", Vector2i(26, 24), TileGrid.ROAD_AVENUE],
		["a bulldoze", Vector2i(26, 30), TileGrid.ROAD_NONE],
		["a bulldoze that splits a corridor", Vector2i(32, 26), TileGrid.ROAD_NONE],
	]
	for case: Array in cases:
		var rig := _rig(_grid_city(Vector2i(20, 20), 24, 6))
		var grid: TileGrid = rig["grid"]
		var graph: RoadGraph = rig["graph"]
		var view := _view()
		view.rebuild(grid, graph)
		_edit(grid, graph, case[1], int(case[2]))
		view.rebuild(grid, graph)
		assert_true(view.last_pass_incremental, "%s: took the diff" % case[0])
		_assert_matches_fresh(view, grid, graph, String(case[0]))
		view.free()


func test_04_an_upgrade_moves_a_class_the_edge_delta_cannot_see() -> void:
	# WHY THE DIFF SWEEPS CLASS instead of seeding off `road_graph_changed`'s
	# `added_edges` / `removed_edges`, which is the obvious thing to do and is
	# what the open question proposed.
	#
	# A tile that belongs to more than one edge — every junction box — takes its
	# class from the GRID (`RoadSurfaceView._class_of`), and no edge delta can
	# report a grid-class change. Here is the case in its cleanest form: a solid
	# 5x5 of street, where every interior tile has degree 4 and is therefore a
	# node both before and after. Upgrading the middle one moves its class and
	# `apply_edits` reports NOTHING, because every edge it touched came back
	# with the same key, the same id and the same tile list — doc 10 §2.5's
	# edge-id stability rule, working exactly as intended.
	var tiles: Dictionary = {}
	for x in range(30, 35):
		for y in range(40, 45):
			tiles[Vector2i(x, y)] = TileGrid.ROAD_STREET
	var rig := _rig(tiles)
	var grid: TileGrid = rig["grid"]
	var graph: RoadGraph = rig["graph"]
	var view := _view()
	view.rebuild(grid, graph)
	var centre := Vector2i(32, 42)
	var before: Color = view.pack_of(centre)
	grid.set_road(centre.x, centre.y, TileGrid.ROAD_AVENUE)
	var delta := graph.apply_edits([centre])
	assert_true((delta["added_edges"] as Array).is_empty(),
			"every edge came back with its own id, so the delta reports no addition")
	assert_true((delta["removed_edges"] as Array).is_empty(), "…and no removal")
	view.rebuild(grid, graph)
	assert_true(view.last_pass_incremental, "the diff ran")
	var after: Color = view.pack_of(centre)
	assert_true(before.b != after.b,
			"…and the upgraded tile's class channel moved anyway (%f -> %f)"
			% [before.b, after.b])
	_assert_matches_fresh(view, grid, graph, "in-place upgrade")
	view.free()


# ════════════════════ 3. the property test, hard ═══════════════════════════

func test_05_random_edit_sequences_match_a_fresh_rebuild() -> void:
	# 40 sequences x 12 edits, every intermediate state compared. The edits are
	# drawn from a fixed-seed RNG local to the test — never a doc 00 §5 stream,
	# which belongs to the sim.
	var rng := RandomNumberGenerator.new()
	var mismatch := 0
	var checked := 0
	for run in 40:
		rng.seed = 90210 + run
		var rig := _rig(_grid_city(Vector2i(18, 18), 24, 6))
		var grid: TileGrid = rig["grid"]
		var graph: RoadGraph = rig["graph"]
		var view := _view()
		view.rebuild(grid, graph)
		for step in 12:
			var t := Vector2i(18 + rng.randi_range(0, 24), 18 + rng.randi_range(0, 24))
			var roll := rng.randi_range(0, 3)
			var road_class := TileGrid.ROAD_NONE
			if roll == 1 or roll == 2:
				road_class = TileGrid.ROAD_STREET
			elif roll == 3:
				road_class = TileGrid.ROAD_AVENUE
			_edit(grid, graph, t, road_class)
			view.rebuild(grid, graph)
			checked += 1
			if not _same_as_fresh(view, grid, graph):
				mismatch += 1
		view.free()
	assert_eq(mismatch, 0,
			"%d intermediate states, every buffer byte-identical to a fresh rebuild"
			% checked)
	assert_true(checked >= 480, "the sequence actually ran (%d states)" % checked)


func test_06_random_sequences_against_water_and_the_map_edge() -> void:
	# Water decides the kerb mask and the map edge decides it differently
	# again (`_is_water` kerbs an off-map neighbour on purpose), so a city
	# pinned to both corners is where an off-by-one in the dependency ball
	# shows up as a footway that stops one tile short.
	var rng := RandomNumberGenerator.new()
	var water: Array = []
	for y in range(0, 9):
		water.append(Vector2i(6, y))
		water.append(Vector2i(7, y))
	var mismatch := 0
	var checked := 0
	for run in 24:
		rng.seed = 4242 + run
		var tiles := _grid_city(Vector2i(0, 0), 12, 4)
		var rig := _rig(tiles, water)
		var grid: TileGrid = rig["grid"]
		var graph: RoadGraph = rig["graph"]
		var view := _view()
		view.rebuild(grid, graph)
		for step in 10:
			var t := Vector2i(rng.randi_range(0, 12), rng.randi_range(0, 12))
			if grid.has_flag(t.x, t.y, TileGrid.FLAG_WATER):
				continue
			var roll := rng.randi_range(0, 2)
			var road_class := TileGrid.ROAD_NONE
			if roll == 1:
				road_class = TileGrid.ROAD_STREET
			elif roll == 2:
				road_class = TileGrid.ROAD_AVENUE
			_edit(grid, graph, t, road_class)
			view.rebuild(grid, graph)
			checked += 1
			if not _same_as_fresh(view, grid, graph):
				mismatch += 1
		view.free()
	assert_eq(mismatch, 0,
			"%d states against water and the map edge, all byte-identical" % checked)
	assert_true(checked >= 150, "the sequence actually ran (%d states)" % checked)


func test_07_the_founding_city_survives_a_drag() -> void:
	# The real thing: doc 09's starter city, then a ten-tile road drag through
	# it, one tile at a time, the way the drawing tool will feed it.
	var net := RoadsTestRig.starter_network()
	var grid: TileGrid = net.graph.grid
	var view := _view()
	view.rebuild(grid, net.graph)
	var boot := view.tile_count()
	for i in 10:
		_edit(grid, net.graph, Vector2i(40 + i, 37), TileGrid.ROAD_STREET)
		view.rebuild(grid, net.graph)
	assert_true(view.tile_count() > boot, "the drag paved new tiles")
	assert_true(view.last_pass_incremental, "…on the diff path")
	_assert_matches_fresh(view, grid, net.graph, "starter city + a 10-tile drag")
	view.free()


## The comparison of test 03 without the assertion noise — the property tests
## run it hundreds of times and only report the count.
func _same_as_fresh(view: RoadSurfaceView, grid: TileGrid, graph: RoadGraph) -> bool:
	var fresh := _view()
	fresh.rebuild(grid, graph, true)
	var ok := view.asphalt_buffer() == fresh.asphalt_buffer() \
			and view.sidewalk_buffer() == fresh.sidewalk_buffer()
	fresh.free()
	return ok
