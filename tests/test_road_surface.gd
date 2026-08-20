extends SimTest
## The REAL STREET pass — doc 11 §2.1.2 and §2.10.
##
## Everything here is an INVARIANT of the picture, not a snapshot of it: what
## the packing decodes to, where a footway is allowed to be, where a lamp is
## allowed to stand, and that two runs over one city agree. Tuning numbers
## (dash length, gutter width, tints) live in `data/render.json` and are
## deliberately not asserted — moving them is art, moving these is a bug.
##
## The three that would actually break the player's read, in order:
##
##  1. **A centre line through a junction box.** The whole point of reading the
##     graph is that a 4-way looks like a 4-way. Tests 03 and 05.
##  2. **A kerb down the middle of a 16 m avenue.** The starter city lays its
##     avenues as TWO tiles; per-tile guesswork puts a footway on the inside of
##     each half and a centre line 8 m off where it belongs. Test 04.
##  3. **A lamp in a traffic lane.** Test 12 asserts every pole in the starter
##     city stands on a footway, and test 13 that its arm points at the road.

const RENDER := "res://data/render.json"


func _render() -> Dictionary:
	return StarterCityLoader.read_json(RENDER)


func _view() -> RoadSurfaceView:
	var view := RoadSurfaceView.new()
	view.setup(_render())
	return view


## `tiles` maps Vector2i -> TileGrid.ROAD_*; water tiles are listed separately.
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


# ═════════════════════ 1. the wire format both halves share ════════════════

func test_01_the_direction_order_is_one_wire_format() -> void:
	# `road_surface.gdshader` decodes N=1 E=2 S=4 W=8 out of two of its four
	# channels, and `StreetlightPlacer` picks a kerb out of the same bits. The
	# two files declare the order separately (no load-order coupling), so the
	# agreement has to be asserted rather than commented.
	assert_eq(RoadSurfaceView.DIRS.size(), 4, "four cardinals")
	assert_eq(StreetlightPlacer.DIRS.size(), 4, "four cardinals")
	for i in 4:
		assert_eq(StreetlightPlacer.DIRS[i], RoadSurfaceView.DIRS[i],
				"direction %d agrees" % i)
		assert_eq(int(StreetlightPlacer.BIT[i]), int(RoadSurfaceView.BIT[i]),
				"bit %d agrees" % i)
	assert_eq(RoadSurfaceView.DIRS[0], Vector2i(0, -1), "index 0 is NORTH (-z)")
	assert_eq(RoadSurfaceView.DIRS[1], Vector2i(1, 0), "index 1 is EAST (+x)")


func test_02_a_run_of_street_packs_as_a_two_way_carriageway() -> void:
	var rig := _rig(_line(Vector2i(20, 10), Vector2i(20, 20), TileGrid.ROAD_STREET))
	var view := _view()
	assert_eq(view.rebuild(rig["grid"], rig["graph"]), 11, "eleven tiles drawn")
	var pack := view.pack_of(Vector2i(20, 15))
	assert_eq(int(pack.r), RoadSurfaceView.BIT[0] | RoadSurfaceView.BIT[2],
			"a mid-run tile has north and south neighbours and nothing else")
	assert_eq(int(pack.g), RoadSurfaceView.BIT[1] | RoadSurfaceView.BIT[3],
			"…and therefore a footway east and west")
	var packed := int(pack.b)
	assert_eq(packed / 16, 0, "no crosswalk off a junction")
	assert_eq((packed % 16) / 2, 0, "no dual-carriageway twin")
	assert_eq(packed % 2, 0, "class 0 = street (dashed single yellow)")
	assert_true(pack.a >= 0.0 and pack.a < 1.0, "wear seed is on [0,1)")
	# The slab has to stay exactly where the vehicle layer and the traffic
	# overlay already believe it is (VehicleView.DEF_ROAD_TOP_M = 0.10).
	assert_almost_eq(view.asphalt_origin_y() + view.asphalt_thickness_m * 0.5,
			0.10, 1e-4, "the carriageway's top surface is still y = 0.10")
	assert_eq(view.asphalt_node().multimesh.instance_count, 11,
			"one slab per road tile")
	assert_eq(view.draw_calls(), 2, "the whole road layer is two draw calls")
	view.free()


func test_03_a_four_way_draws_no_centre_line_and_four_zebras() -> void:
	var tiles := _line(Vector2i(10, 20), Vector2i(30, 20), TileGrid.ROAD_STREET)
	_line(Vector2i(20, 10), Vector2i(20, 30), TileGrid.ROAD_STREET, tiles)
	var rig := _rig(tiles)
	var view := _view()
	view.rebuild(rig["grid"], rig["graph"])
	var pack := view.pack_of(Vector2i(20, 20))
	assert_eq(int(pack.r), 15, "all four legs are road")
	assert_eq(int(pack.g), 0, "a box with four legs carries no footway")
	var packed := int(pack.b)
	assert_eq(packed / 16, 15, "every leg gets a zebra")
	assert_eq((packed % 16) / 2, 0, "not a dual carriageway")
	# The shader suppresses the centre line on any tile with three or more legs
	# and no twin; that is the same predicate `classify` publishes.
	var facts := RoadSurfaceView.classify(rig["grid"], rig["graph"])
	assert_true(bool((facts["junction"] as Dictionary)[Vector2i(20, 20)]),
			"the crossing tile is a junction box")
	assert_false(bool((facts["junction"] as Dictionary)[Vector2i(20, 18)]),
			"…and its approach is not")
	view.free()


# ═══════════════ 4. the two-tile avenue, which is the hard one ══════════════

func test_04_a_dual_carriageway_pairs_and_kerbs_only_outside() -> void:
	# Exactly how data/starter_city.json lays Slacum Ave down: x = 15 AND 16.
	var tiles := _line(Vector2i(15, 4), Vector2i(15, 40), TileGrid.ROAD_AVENUE)
	_line(Vector2i(16, 4), Vector2i(16, 40), TileGrid.ROAD_AVENUE, tiles)
	var rig := _rig(tiles)
	var view := _view()
	view.rebuild(rig["grid"], rig["graph"])

	var west := view.pack_of(Vector2i(15, 20))
	var east := view.pack_of(Vector2i(16, 20))
	assert_eq((int(west.b) % 16) / 2, 2, "the west half's twin is EAST (code 2)")
	assert_eq((int(east.b) % 16) / 2, 4, "the east half's twin is WEST (code 4)")
	assert_eq(int(west.b) % 2, 1, "class 1 = avenue")
	assert_eq(int(west.g), RoadSurfaceView.BIT[3], "the west half kerbs WEST only")
	assert_eq(int(east.g), RoadSurfaceView.BIT[1], "the east half kerbs EAST only")

	# Nothing about a 16 m avenue may read as a junction, or the corridor loses
	# every centre line it has.
	var facts := RoadSurfaceView.classify(rig["grid"], rig["graph"])
	var junction: Dictionary = facts["junction"]
	for z in range(6, 38):
		assert_false(bool(junction[Vector2i(15, z)]),
				"avenue tile (15,%d) is a corridor, not a box" % z)
	# And the footway must be OUTSIDE both halves — never between them.
	var min_x := 1e9
	var max_x := -1e9
	for run: Dictionary in view.runs():
		min_x = minf(min_x, float(run["x"]))
		max_x = maxf(max_x, float(run["x"]) + float(run["dx"]))
	assert_almost_eq(min_x, 15.0 * 8.0, 1e-3, "west kerb hugs the avenue's west edge")
	assert_almost_eq(max_x, 17.0 * 8.0, 1e-3, "east kerb hugs its east edge")
	view.free()


func test_05_an_avenue_meeting_a_street_zebras_outward_only() -> void:
	# Stamped exactly the way `StarterCityLoader` does it, LAST WRITER WINS — so
	# the two crossing tiles come out classed STREET even though they are part of
	# an avenue. That is the case `_pair_of` had to be taught not to choke on:
	# with a class test along the corridor, this one mis-classed tile turned the
	# avenue tiles either side of it into junction boxes.
	var tiles := _line(Vector2i(15, 4), Vector2i(15, 40), TileGrid.ROAD_AVENUE)
	_line(Vector2i(16, 4), Vector2i(16, 40), TileGrid.ROAD_AVENUE, tiles)
	_line(Vector2i(4, 20), Vector2i(30, 20), TileGrid.ROAD_STREET, tiles)
	var rig := _rig(tiles)
	var view := _view()
	view.rebuild(rig["grid"], rig["graph"])
	var north := view.pack_of(Vector2i(15, 19))
	assert_eq((int(north.b) % 16) / 2, 2,
			"the avenue tile beside the crossing keeps its twin")
	assert_eq(int(north.g), RoadSurfaceView.BIT[3], "…and kerbs only outward")
	var west := view.pack_of(Vector2i(15, 20))
	var east := view.pack_of(Vector2i(16, 20))
	# Both crossing tiles are boxes. Neither may paint a zebra at the other:
	# that would put two ladders of white bars down the MIDDLE of the avenue.
	assert_eq((int(west.b) % 16) / 2, 0, "the crossing tile has no twin")
	var west_cw := int(west.b) / 16
	var east_cw := int(east.b) / 16
	assert_eq(west_cw & RoadSurfaceView.BIT[1], 0, "west half paints nothing eastward")
	assert_eq(east_cw & RoadSurfaceView.BIT[3], 0, "east half paints nothing westward")
	assert_ne(west_cw & RoadSurfaceView.BIT[3], 0, "…but does zebra the street it meets")
	assert_ne(west_cw & RoadSurfaceView.BIT[0], 0, "…and the avenue leg north of it")
	view.free()


# ═══════════════════════════ footway geometry ══════════════════════════════

func test_06_kerb_runs_merge_along_a_corridor() -> void:
	var rig := _rig(_line(Vector2i(20, 10), Vector2i(20, 20), TileGrid.ROAD_STREET))
	var view := _view()
	view.rebuild(rig["grid"], rig["graph"])
	var runs := view.runs()
	# 11 tiles x 2 kerbed sides would be 22 boxes. Merged they are 2 runs plus
	# the four corner squares that close the two dead ends.
	var strips: Array = []
	var corners := 0
	for run: Dictionary in runs:
		if String(run["axis"]) == "C":
			corners += 1
		else:
			strips.append(run)
	assert_eq(strips.size(), 4, "two long kerbs plus the two end caps")
	assert_eq(corners, 4, "one corner square per kerb per dead end")
	var longest := 0.0
	for run: Dictionary in strips:
		longest = maxf(longest, maxf(float(run["dx"]), float(run["dz"])))
	assert_almost_eq(longest, 11.0 * 8.0 - 2.0 * view.sidewalk_w_street, 1e-3,
			"a kerb run spans the whole corridor less its two corner squares")
	view.free()


func test_07_no_two_footway_boxes_overlap() -> void:
	# Overlapping boxes share a top face at exactly one height, which is
	# z-fighting nobody can tune away. The trim-and-corner scheme exists to make
	# that impossible; this is the assertion that it does.
	var tiles := _line(Vector2i(10, 10), Vector2i(20, 10), TileGrid.ROAD_STREET)
	_line(Vector2i(20, 10), Vector2i(20, 20), TileGrid.ROAD_STREET, tiles)
	_line(Vector2i(20, 15), Vector2i(28, 15), TileGrid.ROAD_STREET, tiles)
	var rig := _rig(tiles)
	var view := _view()
	view.rebuild(rig["grid"], rig["graph"])
	var runs := view.runs()
	assert_true(runs.size() > 4, "the L plus its T produced real geometry")
	var overlaps := 0
	for i in runs.size():
		var a: Dictionary = runs[i]
		for j in range(i + 1, runs.size()):
			var b: Dictionary = runs[j]
			var ox := minf(float(a["x"]) + float(a["dx"]), float(b["x"]) + float(b["dx"])) \
					- maxf(float(a["x"]), float(b["x"]))
			var oz := minf(float(a["z"]) + float(a["dz"]), float(b["z"]) + float(b["dz"])) \
					- maxf(float(a["z"]), float(b["z"]))
			if ox > 0.002 and oz > 0.002:
				overlaps += 1
	assert_eq(overlaps, 0, "every footway box has the plan area to itself")
	view.free()


func test_08_water_takes_no_footway() -> void:
	var tiles := _line(Vector2i(20, 10), Vector2i(20, 20), TileGrid.ROAD_STREET)
	var water: Array = []
	for z in range(10, 21):
		water.append(Vector2i(19, z))
	var rig := _rig(tiles, water)
	var view := _view()
	view.rebuild(rig["grid"], rig["graph"])
	var pack := view.pack_of(Vector2i(20, 15))
	assert_eq(int(pack.g) & RoadSurfaceView.BIT[3], 0,
			"a kerb is not built out over open water")
	assert_ne(int(pack.g) & RoadSurfaceView.BIT[1], 0, "the dry side still gets one")
	view.free()


func test_09_the_pass_is_a_pure_read_of_the_graph() -> void:
	var rig := _rig(_line(Vector2i(20, 10), Vector2i(20, 20), TileGrid.ROAD_STREET))
	var graph: RoadGraph = rig["graph"]
	var version := graph.graph_version
	var edges := graph.edge_count()
	var nodes := graph.node_count()
	var a := _view()
	a.rebuild(rig["grid"], graph)
	var b := _view()
	b.rebuild(rig["grid"], graph)
	assert_eq(graph.graph_version, version, "the renderer did not bump the graph")
	assert_eq(graph.edge_count(), edges, "…nor add an edge")
	assert_eq(graph.node_count(), nodes, "…nor a node")
	# Determinism: the wear seed is a hash of the tile, never a stream draw, so
	# two builds of one city are byte-identical.
	assert_eq(a.tile_count(), b.tile_count(), "same tile count")
	for t: Vector2i in [Vector2i(20, 11), Vector2i(20, 15), Vector2i(20, 19)]:
		assert_eq(a.pack_of(t), b.pack_of(t), "tile %s packs identically twice" % t)
	assert_eq(a.runs().size(), b.runs().size(), "same footway geometry")
	a.free()
	b.free()


# ══════════════════════════ the lamps at the kerb ═══════════════════════════

func test_10_lamps_walk_a_corridor_at_pitch_and_alternate_kerbs() -> void:
	var rig := _rig(_line(Vector2i(20, 4), Vector2i(20, 40), TileGrid.ROAD_STREET))
	var render := _render()
	var spacing := int(((render["road_surface"] as Dictionary)["lamp"]
			as Dictionary)["spacing_tiles"])
	var lamps := StreetlightPlacer.place(rig["grid"], rig["graph"], render)
	assert_true(lamps.size() >= 8, "a 37-tile street is lit: %d lamps" % lamps.size())
	var sides: Array = []
	var last_z := -99
	for lamp: Dictionary in lamps:
		var t: Vector2i = lamp["tile"]
		assert_eq(t.x, 20, "every lamp is on the corridor")
		if bool(lamp["corner"]):
			continue   # the two cul-de-sac heads are lit from their corners
		assert_eq(posmod(t.y, spacing), 0, "…at the authored pitch")
		if last_z >= 0:
			assert_eq(t.y - last_z, spacing, "…evenly, with no stutter")
		last_z = t.y
		sides.append(int(lamp["side"]))
	var swaps := 0
	for i in range(1, sides.size()):
		if sides[i] != sides[i - 1]:
			swaps += 1
	assert_eq(swaps, sides.size() - 1, "consecutive lamps swap kerbs every time")


func test_11_a_dual_carriageway_is_lit_staggered_down_both_kerbs() -> void:
	var tiles := _line(Vector2i(15, 4), Vector2i(15, 40), TileGrid.ROAD_AVENUE)
	_line(Vector2i(16, 4), Vector2i(16, 40), TileGrid.ROAD_AVENUE, tiles)
	var rig := _rig(tiles)
	var render := _render()
	var spacing := int(((render["road_surface"] as Dictionary)["lamp"]
			as Dictionary)["spacing_tiles"])
	var lamps := StreetlightPlacer.place(rig["grid"], rig["graph"], render)
	var west_z: Array = []
	var east_z: Array = []
	for lamp: Dictionary in lamps:
		var t: Vector2i = lamp["tile"]
		if bool(lamp["corner"]):
			continue
		if t.x == 15:
			assert_eq(int(lamp["side"]), 3, "the west half lights its WEST kerb")
			west_z.append(t.y)
		else:
			assert_eq(int(lamp["side"]), 1, "the east half lights its EAST kerb")
			east_z.append(t.y)
	assert_true(west_z.size() >= 4, "the west kerb is lit")
	assert_true(east_z.size() >= 4, "the east kerb is lit")
	# The half whose twin lies to its WEST carries the offset (see
	# `StreetlightPlacer._twin_is_low`), so the east kerb is the staggered one.
	for z: int in west_z:
		assert_eq(posmod(z, spacing * 2), 0, "west lamps sit on the beat")
	for z: int in east_z:
		assert_eq(posmod(z, spacing * 2), spacing,
				"east lamps carry the stagger offset")
	# Which is what makes the AVENUE's effective pitch the same as a street's,
	# with the light coming from alternating kerbs.
	var all_z: Array = west_z + east_z
	all_z.sort()
	for i in range(1, all_z.size()):
		assert_eq(int(all_z[i]) - int(all_z[i - 1]), spacing,
				"the two kerbs interleave at the single-carriageway pitch")


func test_12_every_lamp_in_the_starter_city_stands_on_a_footway() -> void:
	# The regression this exists for: the rule it replaces
	# (`(x + z) % 4 == 0`) puts a pole at the CENTRE of a road tile, which on a
	# 16 m avenue is the middle of four lanes of traffic.
	var loader := StarterCityLoader.new()
	loader.load_from(StarterCityLoader.read_json("res://data/starter_city.json"))
	var grid: TileGrid = loader.world.grid
	var tun := RoadTunables.from_file("res://data/roads.json")
	var graph := RoadGraph.new(grid, tun)
	graph.rebuild_all()
	var render := _render()
	var cfg: Dictionary = render["road_surface"]
	var lamps := StreetlightPlacer.place(grid, graph, render)
	assert_true(lamps.size() > 100, "the starter city is lit: %d lamps" % lamps.size())
	var base_y := float(cfg["asphalt_top_m"]) + float(cfg["kerb_height_m"])
	var facts := RoadSurfaceView.classify(grid, graph)
	var kerb_of: Dictionary = facts["kerb"]
	var cls_of: Dictionary = facts["cls"]
	var bad := 0
	for lamp: Dictionary in lamps:
		var t: Vector2i = lamp["tile"]
		var pos: Vector3 = lamp["pos"]
		if absf(pos.y - base_y) > 1e-4:
			bad += 1
			continue
		# The chosen side must actually carry a footway…
		if (int(kerb_of[t]) & RoadSurfaceView.BIT[int(lamp["side"])]) == 0:
			bad += 1
			continue
		# …and the pole must be inside it, not out in the carriageway.
		var w: float = float(cfg["sidewalk_width_avenue_m"]) \
				if int(cls_of[t]) == TileGrid.ROAD_AVENUE \
				else float(cfg["sidewalk_width_street_m"])
		var centre := Vector3(float(t.x) * 8.0 + 4.0, pos.y, float(t.y) * 8.0 + 4.0)
		var off := maxf(absf(pos.x - centre.x), absf(pos.z - centre.z))
		if off < 4.0 - w - 1e-4 or off > 4.0 + 1e-4:
			bad += 1
	assert_eq(bad, 0, "%d of %d lamps missed the kerb" % [bad, lamps.size()])


func test_13_a_lamp_faces_its_own_roadway() -> void:
	var rig := _rig(_line(Vector2i(20, 4), Vector2i(20, 40), TileGrid.ROAD_STREET))
	var lamps := StreetlightPlacer.place(rig["grid"], rig["graph"], _render())
	for lamp: Dictionary in lamps:
		var t: Vector2i = lamp["tile"]
		var pos: Vector3 = lamp["pos"]
		var centre := Vector3(float(t.x) * 8.0 + 4.0, pos.y, float(t.y) * 8.0 + 4.0)
		# The arm is baked along local +X, so the instance basis has to carry it
		# onto the vector from pole to roadway.
		var arm: Vector3 = Basis.from_euler(Vector3(0.0, float(lamp["yaw"]), 0.0)) \
				* CobraHeadMesh.ARM_AXIS
		var want := (centre - pos)
		want.y = 0.0
		want = want.normalized()
		assert_almost_eq(arm.dot(want), 1.0, 1e-4,
				"the arm at %s reaches over the road" % t)


func test_14_a_bend_is_lit_from_the_corner_of_its_own_footway() -> void:
	# A one-tile JUNCTION has three or four road neighbours and therefore at most
	# ONE kerb: there is no corner to stand a pole on, and standing one in the
	# box anyway would put it in a traffic lane. What does have a corner is a
	# bend or a cul-de-sac head — the tile's two footways meet there, which is
	# exactly where a real pole goes.
	var tiles := _line(Vector2i(20, 10), Vector2i(20, 20), TileGrid.ROAD_STREET)
	_line(Vector2i(20, 20), Vector2i(30, 20), TileGrid.ROAD_STREET, tiles)
	var rig := _rig(tiles)
	var facts := RoadSurfaceView.classify(rig["grid"], rig["graph"])
	assert_false(bool((facts["junction"] as Dictionary)[Vector2i(20, 20)]),
			"a two-leg bend is not a junction")
	var lamps := StreetlightPlacer.place(rig["grid"], rig["graph"], _render())
	var corner: Dictionary = {}
	for lamp: Dictionary in lamps:
		if bool(lamp["corner"]) and (lamp["tile"] as Vector2i) == Vector2i(20, 20):
			corner = lamp
	assert_false(corner.is_empty(), "the bend got a corner lamp")
	if corner.is_empty():
		return
	var pos: Vector3 = corner["pos"]
	var centre := Vector3(20.0 * 8.0 + 4.0, pos.y, 20.0 * 8.0 + 4.0)
	# The road arrives from the north and leaves to the east, so the footway —
	# and the pole — is on the outside of the bend: south-west.
	assert_true(pos.x < centre.x - 2.0, "displaced west")
	assert_true(pos.z > centre.z + 2.0, "…and south: a true corner, not a kerb")
	var arm: Vector3 = Basis.from_euler(Vector3(0.0, float(corner["yaw"]), 0.0)) \
			* CobraHeadMesh.ARM_AXIS
	var want := (centre - pos)
	want.y = 0.0
	assert_almost_eq(arm.dot(want.normalized()), 1.0, 1e-4,
			"and it still reaches across the bend")


func test_14b_no_junction_in_the_starter_city_sits_in_the_dark() -> void:
	# The corner rule deliberately does not light junction boxes. This is the
	# assertion that the corridor rule already does: every box in the founding
	# city has a lamp within `spacing_tiles` of it.
	var loader := StarterCityLoader.new()
	loader.load_from(StarterCityLoader.read_json("res://data/starter_city.json"))
	var grid: TileGrid = loader.world.grid
	var tun := RoadTunables.from_file("res://data/roads.json")
	var graph := RoadGraph.new(grid, tun)
	graph.rebuild_all()
	var render := _render()
	var spacing := int(((render["road_surface"] as Dictionary)["lamp"]
			as Dictionary)["spacing_tiles"])
	var lamps := StreetlightPlacer.place(grid, graph, render)
	var lit: Dictionary = {}
	for lamp: Dictionary in lamps:
		lit[lamp["tile"]] = true
	var facts := RoadSurfaceView.classify(grid, graph)
	var junction: Dictionary = facts["junction"]
	var dark := 0
	var boxes := 0
	for raw: Variant in facts["tiles"]:
		var t: Vector2i = raw
		if not bool(junction[t]):
			continue
		boxes += 1
		var near := false
		for dx in range(-spacing, spacing + 1):
			for dz in range(-spacing, spacing + 1):
				if absi(dx) + absi(dz) <= spacing and lit.has(t + Vector2i(dx, dz)):
					near = true
		if not near:
			dark += 1
	assert_true(boxes > 20, "the starter city has junctions to check: %d" % boxes)
	assert_eq(dark, 0, "%d of %d junction boxes had no lamp within %d tiles"
			% [dark, boxes, spacing])


# ════════════════════════════ the cobra head ════════════════════════════════

func test_15_the_cobra_head_leans_over_the_road() -> void:
	var lamp_cfg: Dictionary = (_render()["road_surface"] as Dictionary)["lamp"]
	var mesh := CobraHeadMesh.build(lamp_cfg)
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	assert_eq(idx.size() / 3, 76, "mast, collar, arm and luminaire: 76 triangles")
	var lowest := 9.0
	var top := -9.0
	var reach := 0.0
	var back := 0.0
	for p: Vector3 in verts:
		lowest = minf(lowest, p.y)
		top = maxf(top, p.y)
		reach = maxf(reach, p.x)
		back = minf(back, p.x)
	assert_almost_eq(lowest, 0.0, 1e-4,
			"the mast rests on y = 0 so the grime lands at the footway")
	var head_h := float(lamp_cfg["head_height_m"])
	assert_true(top >= head_h and top <= head_h + float(lamp_cfg["pole_width_m"]),
			"the luminaire sits at the authored head height (%.3f vs %.3f)"
					% [top, head_h])
	# The whole point of a cobra: the head is OUT over the carriageway, not on
	# top of the pole. Anything under about a metre is still a stick.
	assert_true(reach > float(lamp_cfg["arm_reach_m"]),
			"the head overhangs past the arm's reach (%.2f m)" % reach)
	assert_true(absf(back) < 0.2, "…and the mast is still the thing at the origin")
	# Baked base weathering: grade is dirtier than the head.
	var at_grade := 9.0
	var at_head := 0.0
	for i in verts.size():
		if verts[i].y < 0.01:
			at_grade = minf(at_grade, cols[i].r)
		if verts[i].y > float(lamp_cfg["mast_height_m"]):
			at_head = maxf(at_head, cols[i].r)
	assert_true(at_grade < at_head,
			"grade %.3f must be dirtier than the head %.3f" % [at_grade, at_head])


func test_16_the_glow_hangs_off_the_luminaire_and_clears_the_carriageway() -> void:
	var render := _render()
	var cfg: Dictionary = render["road_surface"]
	var model := RenderStateModel.new(render)
	var view := StreetlightView.new()
	# A lamp on the WEST kerb of a north-south street: yaw 0 aims the arm east.
	view.setup(model, render, [{"id": 1, "block_id": "B", "yaw": 0.0,
			"pos": Vector3(40.0, float(cfg["asphalt_top_m"])
					+ float(cfg["kerb_height_m"]), 40.0)}])
	var meshes: Dictionary = {}
	for child in view.get_children():
		var node := child as MultiMeshInstance3D
		if node == null:
			continue
		var mat := node.material_override as ShaderMaterial
		var key := "pole" if mat == null else String(mat.shader.resource_path).get_file()
		meshes[key] = node
	assert_true(meshes.has("light_pool.gdshader"), "the ground pool is still built")
	assert_true(meshes.has("lamp.gdshader"), "…and the tuned billboard")
	assert_true(meshes.has("pole"), "…and the pole")
	var anchor := view.anchor_of(1)
	assert_false(anchor.is_empty(), "the lamp was placed")
	if anchor.is_empty():
		view.free()
		return
	var pool: Vector3 = anchor["pool"]
	var head: Vector3 = anchor["head"]
	var base: Vector3 = anchor["base"]
	# STREET-1: the pool used to be uploaded UNDER the road slab (0.07 against
	# the carriageway's 0.10) and was depth-buried by the very surface it was
	# lighting. It now rides over the footway, which is over the carriageway.
	assert_true(pool.y > float(cfg["asphalt_top_m"]),
			"the pool clears the asphalt (%.3f m)" % pool.y)
	assert_true(pool.y >= float(cfg["asphalt_top_m"]) + float(cfg["kerb_height_m"]),
			"…and the kerb too")
	# And it is centred under the LUMINAIRE, out over the road, not on the pole.
	var reach := float((cfg["lamp"] as Dictionary)["arm_reach_m"])
	assert_true(head.x > base.x + reach * 0.8,
			"the head hangs out over the carriageway")
	assert_almost_eq(pool.x, head.x, 1e-4, "the pool is centred under the head")
	assert_almost_eq(pool.z, head.z, 1e-4, "…on both axes")
	assert_true(head.y > 8.0, "…at lamp height (%.2f m)" % head.y)
	view.free()


func test_17_a_repeat_rebuild_for_one_edit_is_free() -> void:
	# One player road edit fires both `road_graph_changed` and, on a stamped ring
	# block, `block_roads_stamped`, and the shell rebuilds from both. A full pass
	# is 4.4 ms on the founding city and 18.3 ms on the benchmark one, so doing it
	# twice for one edit is a dropped frame for nothing.
	var rig := _rig(_line(Vector2i(20, 10), Vector2i(20, 20), TileGrid.ROAD_STREET))
	var grid: TileGrid = rig["grid"]
	var graph: RoadGraph = rig["graph"]
	var view := _view()
	assert_eq(view.rebuild(grid, graph), 11, "the first pass draws the corridor")
	assert_eq(view.rebuild_passes, 1, "…and it is one pass")
	assert_eq(view.built_version(), graph.graph_version,
			"…which records the version it drew")
	view.rebuild(grid, graph)
	view.rebuild(grid, graph)
	assert_eq(view.rebuild_passes, 1,
			"repeat calls for the same graph version do no work")
	view.rebuild(grid, graph, true)
	assert_eq(view.rebuild_passes, 2,
			"…and `force` is the way past it, for a mid-session load")
	# A REAL edit bumps the version, so the guard never hides one.
	grid.set_road(20, 21, TileGrid.ROAD_STREET)
	graph.apply_edits([Vector2i(20, 21)])
	assert_eq(view.rebuild(grid, graph), 12, "the new tile is paved")
	assert_eq(view.rebuild_passes, 3, "…by a pass the guard let through")
	view.free()


# ══════════════════ live lamps: §2.10.1's open item 1 ══════════════════════

func test_18_a_road_edit_re_places_the_lamps_it_touched() -> void:
	# Lamps were BOOT-TIME. A road the player laid got asphalt on the next frame
	# and lamps on the next LOAD — the defect this closes.
	var render := _render()
	var rig := _rig(_line(Vector2i(20, 10), Vector2i(20, 40), TileGrid.ROAD_STREET))
	var grid: TileGrid = rig["grid"]
	var graph: RoadGraph = rig["graph"]
	var model := RenderStateModel.new(render)
	var view := StreetlightView.new()
	view.setup(model, render, StreetlightPlacer.place(grid, graph, render))
	var boot := view.lamp_count()
	assert_true(boot >= 6, "the corridor is lit at boot (%d lamps)" % boot)
	assert_eq(model.streetlight_count(), boot, "…and the model agrees")

	# Extend the corridor: new lamps appear, and NOTHING already standing moves.
	var before: Dictionary = {}
	for y in range(10, 41):
		for side in 4:
			var id := view.lamp_id_at(Vector2i(20, y), side)
			if id >= 0:
				before[id] = view.anchor_of(id)["base"]
	for y in range(41, 53):
		grid.set_road(20, y, TileGrid.ROAD_STREET)
		graph.apply_edits([Vector2i(20, y)])
	var diff := view.replace_from(grid, graph)
	assert_true(int(diff["added"]) > 0, "the new run got lamps (%d)" % diff["added"])
	# The only lamp allowed to go is the old DEAD END's corner lamp: a cul-de-sac
	# head carries two adjacent footways and takes a corner lamp, and once the
	# corridor runs through it is an ordinary tile with two kerbs.
	assert_true(int(diff["removed"]) <= 1,
			"only the old cul-de-sac head was re-placed (%d retired)" % diff["removed"])
	assert_true(view.lamp_count() > boot, "the city has more lamps than it did")
	assert_eq(model.streetlight_count(), view.lamp_count(),
			"the model roster matches the view's")
	var held := 0
	for id: int in before:
		var anchor := view.anchor_of(id)
		if anchor.is_empty():
			continue
		assert_eq(anchor["base"], before[id],
				"lamp %d did not move, so its ramp did not restart" % id)
		held += 1
	assert_true(held >= boot - 1, "every lamp but the cul-de-sac head kept its id")

	# Bulldoze the extension: the lamps on it retire, and the model stops
	# ticking them.
	for y in range(41, 53):
		grid.set_road(20, y, TileGrid.ROAD_NONE)
		graph.apply_edits([Vector2i(20, y)])
	diff = view.replace_from(grid, graph)
	assert_true(int(diff["removed"]) > 0, "the bulldozed run lost its lamps")
	assert_eq(view.lamp_count(), boot, "the city is back to its founding count")
	assert_eq(model.streetlight_count(), boot, "…and so is the model")
	view.free()


func test_18b_a_re_place_that_changes_nothing_touches_nothing() -> void:
	# The shell calls this wherever it rebuilds the street surface, including for
	# edits nowhere near a lamp. It has to be free, and it has to leave every id
	# alone — a lamp that is re-created loses its `anim_phase` and its ramp.
	var render := _render()
	var rig := _rig(_line(Vector2i(30, 10), Vector2i(30, 30), TileGrid.ROAD_STREET))
	var grid: TileGrid = rig["grid"]
	var graph: RoadGraph = rig["graph"]
	var model := RenderStateModel.new(render)
	var view := StreetlightView.new()
	var lamps := StreetlightPlacer.place(grid, graph, render)
	view.setup(model, render, lamps)
	# The boot pass adopts the placer's own numbering exactly, so no city that
	# was already running has an `anim_phase` moved by this diff existing.
	for raw: Variant in lamps:
		var row: Dictionary = raw
		assert_eq(view.lamp_id_at(row["tile"], int(row["side"])), int(row["id"]),
				"boot numbering is the placer's own")
	var diff := view.replace_from(grid, graph)
	assert_eq(int(diff["added"]), 0, "nothing added")
	assert_eq(int(diff["removed"]), 0, "nothing removed")
	assert_eq(int(diff["moved"]), 0, "nothing moved")
	assert_eq(int(diff["kept"]), view.lamp_count(), "every lamp kept")
	view.free()
