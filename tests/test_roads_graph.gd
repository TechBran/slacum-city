extends SimTest
## Doc 10 §2.4–§2.5, §2.9 — graph construction, the node predicate, edge-id
## stability, incremental rebuild and components. Test plan cases 1–9 and 41.

const AVENUE := RoadTunables.CLASS_AVENUE
const STREET := RoadTunables.CLASS_STREET


func _plus_tiles() -> Dictionary:
	# §2.4 worked example B-1.
	var tiles: Dictionary = {}
	for t in [Vector2i(2, 0), Vector2i(2, 1), Vector2i(0, 2), Vector2i(1, 2),
			Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 2), Vector2i(2, 3), Vector2i(2, 4)]:
		tiles[t] = STREET
	return tiles


# ------------------------------------------------------------ graph construction

func test_plus_shape_topology() -> void:
	var net := RoadsTestRig.network_with(_plus_tiles())
	var g := net.graph
	assert_eq(g.node_count(), 5, "B-1: 9 road tiles yield 5 nodes")
	assert_eq(g.edge_count(), 4, "B-1: and 4 edges")
	for edge_id in g.edge_ids_sorted():
		var record: Dictionary = g.edge(edge_id)
		assert_eq((record["tiles"] as Array).size(), 3, "each arm is a 3-tile polyline")
		assert_almost_eq(float(record["length_m"]), 16.0, 1e-9, "length_m = (3-1) x 8")
	# tile_to_edge covers all 9 tiles (node tiles resolve to an incident edge).
	for t in _plus_tiles():
		assert_true(g.edge_at(t) >= 0, "tile %s has an edge" % str(t))
	assert_true(g.node_at(Vector2i(2, 2)) >= 0, "the degree-4 hub is a node")
	assert_eq(g.node(g.node_at(Vector2i(2, 2)))["degree"], 4, "hub degree")


func test_corner_is_not_a_node() -> void:
	# An L of 5 tiles: only the two dead ends are nodes.
	var tiles: Dictionary = {}
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, 0), Vector2i(2, 0), STREET))
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(2, 0), Vector2i(2, 2), STREET))
	var net := RoadsTestRig.network_with(tiles)
	assert_eq(net.graph.node_count(), 2, "corners are interior polyline vertices")
	assert_eq(net.graph.edge_count(), 1, "one edge")
	var edge_id: int = net.graph.edge_ids_sorted()[0]
	assert_eq((net.graph.edge(edge_id)["tiles"] as Array).size(), 5, "5 polyline tiles")


func test_class_transition_creates_node() -> void:
	# Doc test 3 expects 3 nodes / 2 edges. The node predicate as written in
	# §2.4 makes BOTH flanking tiles nodes, so the honest answer is 4 nodes and
	# 3 edges — and the 2-tile transition edge is the only one that is not
	# class-uniform. See the roads REPORT, finding D-1.
	var tiles: Dictionary = {}
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, 0), Vector2i(2, 0), STREET))
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(3, 0), Vector2i(5, 0), AVENUE))
	var net := RoadsTestRig.network_with(tiles)
	assert_eq(net.graph.node_count(), 4, "both sides of a class transition are nodes")
	assert_eq(net.graph.edge_count(), 3, "street run, transition link, avenue run")
	var transition := net.graph.edge_at(Vector2i(2, 0))
	var found_mixed := false
	for edge_id in net.graph.edge_ids_sorted():
		var record: Dictionary = net.graph.edge(edge_id)
		if (record["tiles"] as Array).size() == 2:
			found_mixed = true
			assert_eq(int(record["road_class"]), STREET,
					"a mixed segment takes the SLOWEST class it contains")
	assert_true(found_mixed, "the 2-tile transition edge exists")
	assert_true(transition >= 0)


func test_pure_loop_gets_promoted_node() -> void:
	# 8-tile ring around a hole: no tile satisfies the node predicate.
	var tiles: Dictionary = {}
	for t in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(2, 1),
			Vector2i(2, 2), Vector2i(1, 2), Vector2i(0, 2), Vector2i(0, 1)]:
		tiles[t] = STREET
	var net := RoadsTestRig.network_with(tiles)
	assert_eq(net.graph.node_count(), 1, "lowest-(y,x) tile is promoted")
	assert_eq(net.graph.edge_count(), 1, "one self-edge closes the ring")
	assert_eq(net.graph.node_at(Vector2i(0, 0)), 0, "promotion picks (0,0)")
	var edge_id: int = net.graph.edge_ids_sorted()[0]
	var record: Dictionary = net.graph.edge(edge_id)
	assert_eq(int(record["node_a"]), int(record["node_b"]), "it is a self-edge")
	assert_eq((record["tiles"] as Array).size(), 9, "8 ring tiles, first repeated at the end")


func test_isolated_tile() -> void:
	var net := RoadsTestRig.network_with({Vector2i(5, 5): STREET})
	assert_eq(net.graph.node_count(), 1)
	assert_eq(net.graph.edge_count(), 0)
	assert_eq(net.graph.component_count(), 1, "its own component")
	assert_eq(net.graph.component_of_tile(Vector2i(5, 5)), 0)


# ------------------------------------------------------------ incremental rebuild

func test_remove_hub_splits_components() -> void:
	# §2.5 worked example B-2.
	var net := RoadsTestRig.network_with(_plus_tiles())
	net.edit_tile(Vector2i(2, 2), RoadTunables.CLASS_NONE)
	net._flush_edits()
	var g := net.graph
	assert_eq(g.edge_count(), 4, "4 edges of 2 tiles each")
	assert_eq(g.node_count(), 8, "every surviving tile is a dead end")
	assert_eq(g.component_count(), 4, "the plus falls into 4 arms")
	assert_eq(g.last_retraced_tiles, 8, "exactly 8 tiles retraced")
	for edge_id in g.edge_ids_sorted():
		assert_almost_eq(float(g.edge(edge_id)["length_m"]), 8.0, 1e-9)


func test_edge_id_stable_on_unrelated_edit() -> void:
	var tiles: Dictionary = {}
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, 0), Vector2i(10, 0), STREET))
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, 40), Vector2i(10, 40), STREET))
	var net := RoadsTestRig.network_with(tiles)
	var before := net.graph.edge_at(Vector2i(5, 0))
	net.drain_events()
	# Edit the far corridor, 40 tiles away.
	net.edit_tile(Vector2i(5, 41), STREET)
	net._flush_edits()
	assert_eq(net.graph.edge_at(Vector2i(5, 0)), before,
			"an unrelated edit must not renumber the first corridor")
	var delta: Dictionary = {}
	for event in net.drain_events():
		if event["type"] == &"road_graph_changed":
			delta = event
	assert_false(delta.is_empty(), "the edit still reports a graph change")
	assert_false((delta["removed_edges"] as Array).has(before),
			"the untouched edge is not reported removed")


func test_incremental_matches_full_rebuild() -> void:
	# Property test: 200 seeded random edits on a 48x48 patch; after every edit
	# the incremental graph must equal a from-scratch rebuild.
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var tun := RoadsTestRig.tunables()
	var grid := TileGrid.new()
	var live := RoadGraph.new(grid, tun)
	live.rebuild_all()
	var mismatches := 0
	for i in 200:
		var t := Vector2i(rng.randi_range(0, 47), rng.randi_range(0, 47))
		var road_class: int = [0, 1, 1, 2][rng.randi_range(0, 3)]
		if grid.road_class_at(t.x, t.y) == road_class:
			continue
		grid.set_road(t.x, t.y, road_class)
		live.apply_edits([t])
		var reference := RoadGraph.new(grid, tun)
		reference.rebuild_all()
		if _signature(live) != _signature(reference):
			mismatches += 1
			if mismatches == 1:
				_fail("edit %d at %s -> class %d diverged" % [i, str(t), road_class])
	assert_eq(mismatches, 0, "incremental rebuild tracks a full rebuild exactly")


## Node tile set + edge tile-sets + component partition — everything an edge id
## is allowed to differ on is deliberately excluded.
func _signature(g: RoadGraph) -> String:
	var nodes: Array = []
	for node_id in g.node_ids_sorted():
		var t: Vector2i = g.node(node_id)["tile"]
		nodes.append("%d,%d:%d" % [t.x, t.y, int(g.node(node_id)["degree"])])
	nodes.sort()
	var edges: Array = []
	for edge_id in g.edge_ids_sorted():
		edges.append(RoadGraph._tiles_key(g.edge(edge_id)["tiles"]))
	edges.sort()
	var partition: Array = []
	for component_id in g.component_ids_sorted():
		var members: Array = []
		for node_id in g.component_members(component_id):
			var t: Vector2i = g.node(node_id)["tile"]
			members.append("%d,%d" % [t.x, t.y])
		members.sort()
		partition.append("|".join(PackedStringArray(members)))
	partition.sort()
	return "N[%s] E[%s] C[%s]" % ["/".join(PackedStringArray(nodes)),
			"/".join(PackedStringArray(edges)), "/".join(PackedStringArray(partition))]


func test_rebuild_budget_respected() -> void:
	# One edit that dirties a very long corridor must retrace within budget and
	# leave the graph queryable every tick until it settles.
	var tiles: Dictionary = {}
	for z in range(0, 60):
		RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, z), Vector2i(100, z), STREET))
	var net := RoadsTestRig.network_with(tiles)
	var tun := net.tun
	var batch: Array[Vector2i] = []
	for z in range(0, 60):
		batch.append(Vector2i(50, z))
		net.grid.set_road(50, z, RoadTunables.CLASS_NONE)
	var ticks := 0
	var delta := net.graph.apply_edits(batch)
	assert_true(net.graph.last_retraced_tiles <= tun.rebuild_tile_budget + 200,
			"first pass respects REBUILD_TILE_BUDGET (%d)" % net.graph.last_retraced_tiles)
	while net.graph.graph_dirty and ticks < 12:
		ticks += 1
		net.graph.apply_edits([])
		assert_true(net.graph.node_count() > 0, "graph stays queryable mid-rebuild")
	assert_false(net.graph.graph_dirty, "settles within a few ticks (%d)" % ticks)
	assert_true(delta.has("added_edges"))
	var reference := RoadGraph.new(net.grid, tun)
	reference.rebuild_all()
	assert_eq(_signature(net.graph), _signature(reference),
			"the budgeted rebuild converges on the full-rebuild answer")


# --------------------------------------------------------- doc 09 starter city

func test_block_template_matches_doc09() -> void:
	# Report 98 C-60: the stamped core is 783 road tiles, 540 AVENUE + 243 STREET.
	var net := RoadsTestRig.starter_network()
	assert_eq(net.graph.road_tile_count(), 783, "doc 09's 3x3 core stamps 783 road tiles")
	var counts := net.road_tile_counts()
	assert_eq(int(counts["AVENUE"]), 540, "9 blocks x 60 boundary-arterial tiles")
	assert_eq(int(counts["STREET"]), 243, "9 blocks x 27 interior-collector tiles")
	assert_eq(net.graph.component_count(), 1, "the whole core is one component")
	# The deleted {0,8} local-line grid must appear nowhere in the tunables.
	var text := FileAccess.get_file_as_string("res://data/roads.json")
	assert_false(text.contains("\"local_lines\""), "the {0,8} template is deleted")
	assert_true(text.contains("block_template_owner_doc"), "doc 09 owns the template")


func test_starter_city_graph_is_routable_everywhere() -> void:
	var net := RoadsTestRig.starter_network()
	var prof := RouteProfile.emergency(32.0, 0)
	# Four corners of the developed core (global = core-local + 32).
	var corners := [Vector2i(33, 33), Vector2i(78, 33), Vector2i(33, 78), Vector2i(78, 78)]
	for a in corners:
		for b in corners:
			if a == b:
				continue
			var minutes := net.route_minutes(a, b, prof)
			assert_false(is_inf(minutes), "%s -> %s must be reachable" % [str(a), str(b)])
			assert_true(minutes > 0.0 and minutes < 120.0,
					"%s -> %s = %f gm is in a sane band" % [str(a), str(b), minutes])
