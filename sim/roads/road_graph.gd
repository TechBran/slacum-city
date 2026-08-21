class_name RoadGraph
extends RefCounted
## Doc 10 §2.4–§2.5, §2.9: the contracted road graph derived from the tile grid.
##
## Nodes are intersections, dead ends, isolated tiles and class-transition
## points. Corners (degree 2, same class) are interior polyline vertices, which
## roughly halves node count versus a naive per-tile graph. Edges are the
## polylines between nodes, inclusive of both endpoint tiles.
##
## THE GRAPH IS NEVER SAVED (§3.2). It is rebuilt in full from the tile grid on
## load and closures are re-applied over it. Everything here is therefore
## derived state — but it is derived DETERMINISTICALLY: tiles are scanned in
## (y, x) order, neighbours in a fixed direction order, and edge/node ids are
## recycled by tile-list hash so an unrelated edit 30 tiles away cannot
## renumber a corridor (which would storm `route_invalidated`).

## Fixed neighbour order — determinism (constitution §5). No diagonals (§2.2).
const DIRS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1),
]

var grid: TileGrid
var tun: RoadTunables

var graph_version: int = 0
## Signalised nodes currently UNPOWERED, counted by [refresh_signal_power] —
## which is the only writer of `powered` and already visits every node. -1 until
## that has run once, which reads as "unknown" and makes the two dark-signal
## queries do their sweep rather than trust a count they have not been given.
var dark_signals: int = -1
## Instrumented: tiles walked by the last rebuild pass (doc 10 test 6 asserts it).
var last_retraced_tiles: int = 0
## True while a budgeted rebuild still has work queued; route-cache reuse is
## suppressed for pending edges while it is set (§2.5).
var graph_dirty: bool = false

var _nodes: Dictionary = {}  # node_id -> record
var _edges: Dictionary = {}  # edge_id -> record
var _node_order: Array[int] = []
var _edge_order: Array[int] = []
var tile_to_node: Dictionary = {}  # Vector2i -> node_id
var tile_edges: Dictionary = {}  # Vector2i -> Array[int] (ascending)
var _road_tiles: Dictionary = {}  # Vector2i -> road class id (never CLASS_NONE)
var _edge_key: Dictionary = {}  # canonical tile-list key -> edge_id (live)
var _next_node_id: int = 0
var _next_edge_id: int = 0
var _free_node_ids: Array[int] = []
var _free_edge_ids: Array[int] = []
var _pending_dirty: Array[Vector2i] = []
## Id order is kept lazily: appends mark it dirty and the sorted accessors
## resolve it once. Sorting on every create was ~40% of a full rebuild.
var _order_dirty: bool = false
## `road_tiles_sorted()`'s answer, and the `graph_version` it belongs to. See
## the accessor for why this is memoised and why the version is a sound key.
var _tiles_sorted: Array = []
var _tiles_sorted_version: int = -1
var _components: Dictionary = {}  # component_id -> Array[int] node ids
var _component_count: int = 0
## Components are relabelled LAZILY: an edit marks them dirty and the first
## component query resolves it. A per-tick edit that nobody asks about (the
## common case while the player is dragging a road) costs nothing.
var _components_dirty: bool = true


func _init(p_grid: TileGrid, p_tun: RoadTunables) -> void:
	grid = p_grid
	tun = p_tun


# --------------------------------------------------------------- construction

## Full rebuild from the tile grid. Measured target: < 30 ms for 12,000 road
## tiles (§3.2); the 783-tile starter core is ~1 ms.
##
## **This is [rebuild_all_steps] drained on the spot.** There is one
## implementation, cut into four phases, and this runs them back to back — the
## same argument `CitySim.restore_state()` makes about `begin_restore()`, and the
## reason there is no second rebuild to drift.
func rebuild_all() -> Dictionary:
	var held: Dictionary = {}
	for entry in rebuild_all_steps(held, 1):
		((entry as Array)[1] as Callable).call()
	return held["result"]


## How many NODES one `graph_trace` step retraces before handing the frame back.
## The trace is the expensive phase and it is the only one that scales with graph
## COMPLEXITY rather than with map area, so it is the only one that is sliced.
## Slicing it is exact rather than approximate: `_trace_from_nodes` is a loop over
## node ids in ascending order and `seen` / `_edge_key` carry across the calls, so
## a batch boundary changes nothing about which edge is created, in what order, or
## with what id. Tuned on the benchmark city — see `tools/profile_graph_rebuild.gd`.
const REBUILD_TRACE_NODE_BUDGET: int = 700


## `rebuild_all()`, cut into resumable steps for `RestoreCursor` (doc 08 §2.14,
## doc 13 §2.9). Returns `[[label, Callable], …]`; `held` is the caller's scratch
## dictionary, carrying the phases' shared working set and — once the last step
## has run — `held["result"]`, which is what `rebuild_all()` returns.
##
## `trace_slots` is how many `graph_trace` steps to emit. The node roster does not
## exist until `graph_nodes` has run, so the count cannot be derived here and the
## CALLER supplies it — `RoadNetwork.load_section_steps()` counts the road tiles
## out of the saved RLE, which is an exact ceiling on the node count and costs a
## few dozen integer reads. Too few slots is not a correctness problem: whatever
## the slots did not reach, `graph_finish` drains, which is exactly what the
## `trace_slots = 1` of the one-call `rebuild_all()` above relies on.
##
## **Why this exists.** `roads_graph` was the largest indivisible step of a
## restore at **73.7 ms** on the 1,500-building benchmark city, against a 202 ms
## total — so a loading veil that spends one step per frame was bounded by this
## one call and by nothing else (doc 13 §2.9's ANR arithmetic budgets the LONGEST
## step, not the sum). The seams are the phases the function already had:
##
##   * `graph_scan`  — clear, walk the 512 × 512 grid, take the road-tile set.
##     Bounded by map AREA, so it is the same cost on every city.
##   * `graph_nodes` — the §2.4 node predicate over those tiles, in scan order.
##   * `graph_trace` — `_trace_from_nodes`, in `REBUILD_TRACE_NODE_BUDGET`-node
##     batches. The polyline walk, and the phase that actually costs.
##   * `graph_finish` — orphan loops, node meta, the version bump.
##
## The sim is INCONSISTENT at every seam — between `graph_nodes` and the last
## `graph_trace` there are nodes with no edges on them — so nothing may tick,
## render or query the graph between steps. That is the `RestoreCursor` contract
## and the veil is what enforces it.
func rebuild_all_steps(held: Dictionary, trace_slots: int = 1) -> Array:
	var steps: Array = [
		["graph_scan", func() -> void: _rebuild_scan(held)],
		["graph_nodes", func() -> void: _rebuild_nodes(held)],
	]
	for i in maxi(1, trace_slots):
		steps.append(["graph_trace", func() -> void: _rebuild_trace(held)])
	steps.append(["graph_finish", func() -> void: _rebuild_finish(held)])
	return steps


## How many `graph_trace` slots a graph of `road_tiles` tiles wants. Every road
## tile can be a node — a city of isolated single tiles is the worst case §2.4
## admits — so this is an exact ceiling and never a guess.
static func trace_slots_for(road_tiles: int) -> int:
	return maxi(1, ceili(float(maxi(0, road_tiles)) / float(REBUILD_TRACE_NODE_BUDGET)))


func _rebuild_scan(held: Dictionary) -> void:
	held["removed"] = edge_ids_sorted()
	_nodes.clear()
	_edges.clear()
	_node_order.clear()
	_edge_order.clear()
	tile_to_node.clear()
	tile_edges.clear()
	_edge_key.clear()
	_road_tiles.clear()
	_free_node_ids.clear()
	_free_edge_ids.clear()
	_next_node_id = 0
	_next_edge_id = 0
	_pending_dirty.clear()
	last_retraced_tiles = 0
	var tiles := _scan_road_tiles()
	for t in tiles:
		_road_tiles[t] = grid.road_class_at(t.x, t.y)
	held["tiles"] = tiles
	held["seen"] = {}
	held["added"] = [] as Array[int]
	held["cursor"] = 0


func _rebuild_nodes(held: Dictionary) -> void:
	for t in (held["tiles"] as Array):
		if _is_node_tile(t):
			_create_node(t)
	# Taken ONCE, here, and then walked by the trace batches below. Asking
	# `node_ids_sorted()` per batch would re-sort and re-copy the whole roster on
	# every one of them, and — worse — the roster GROWS during the trace
	# (`_promote_orphan_loops` aside, `_create_node` is not reached, but the
	# contract should not depend on that), so a re-read could hand a later batch a
	# different list than the one this phase settled.
	held["node_ids"] = node_ids_sorted()


func _rebuild_trace(held: Dictionary) -> void:
	var node_ids: Array = held.get("node_ids", [])
	var cursor := int(held.get("cursor", 0))
	if cursor >= node_ids.size():
		return
	var stop := mini(node_ids.size(), cursor + REBUILD_TRACE_NODE_BUDGET)
	_trace_from_nodes(node_ids.slice(cursor, stop), held["seen"], held["added"])
	held["cursor"] = stop


func _rebuild_finish(held: Dictionary) -> void:
	# Drain whatever the fixed slot count did not reach. It cannot happen on a
	# city the ceiling above was computed for, and a rebuild that silently left
	# half a graph untraced is not a failure mode worth being elegant about.
	while int(held.get("cursor", 0)) < (held.get("node_ids", []) as Array).size():
		_rebuild_trace(held)
	_promote_orphan_loops(held["tiles"], held["seen"], held["added"])
	_refresh_node_meta(node_ids_sorted())
	_components_dirty = true
	graph_dirty = false
	graph_version += 1
	held["result"] = {"added_edges": held["added"], "removed_edges": held["removed"]}


## Incremental rebuild (§2.5). `edited` is this tick's batch of tiles that were
## added, removed or class-changed. Returns {added_edges, removed_edges}.
##
## The dirty set is the edits plus their orthogonal neighbours, because those
## are exactly the tiles whose node predicate an edit can change. Retracing
## never walks past a surviving node, so cost is O(length of affected chains).
func apply_edits(edited: Array) -> Dictionary:
	last_retraced_tiles = 0
	var dirty: Dictionary = {}
	for entry in _pending_dirty:
		dirty[entry] = true
	_pending_dirty.clear()
	for entry in edited:
		var t: Vector2i = entry
		dirty[t] = true
		for d in DIRS:
			var q: Vector2i = t + d
			if TileGrid.in_bounds(q.x, q.y):
				dirty[q] = true
	# Re-read tile membership for every dirty tile (the grid is authoritative).
	for t in _sorted_tiles(dirty.keys()):
		var live := _grid_class(t)
		if live != RoadTunables.CLASS_NONE:
			_road_tiles[t] = live
		else:
			_road_tiles.erase(t)

	var dirty_tiles := _sorted_tiles(dirty.keys())
	# 1. Delete every edge whose tile list intersects the dirty set.
	var removed: Array[int] = []
	var doomed: Dictionary = {}
	for t in dirty_tiles:
		for edge_id in tile_edges.get(t, []):
			doomed[edge_id] = true
	var doomed_ids := doomed.keys()
	doomed_ids.sort()
	var stash: Dictionary = {}  # key -> {id, record}
	for edge_id in doomed_ids:
		var record: Dictionary = _edges[edge_id]
		stash[String(record["key"])] = {"id": edge_id, "record": record}
		_delete_edge(edge_id)
		removed.append(edge_id)
	_settle_order()  # free lists must be ascending before any id is recycled
	# §2.5's id-stability rule RESERVES a deleted edge's id for its own key, so
	# the generic free-list path must not be able to hand that id to a different
	# edge first. It could: `_delete_edge` pushes the id onto `_free_edge_ids`
	# AND stashes it, and a retrace that reached an unrelated new key before the
	# stashed one popped the same id — then `_create_edge` re-entered with the
	# stashed key, overwrote `_edges[id]`, and left the first edge's tiles
	# pointing at an id that now describes a different corridor. Measured on a
	# 24-tile build: 12 corrupt `tile_edges` entries and 12 lost edges, which is
	# also why the live graph stopped agreeing with a rebuild-from-tiles.
	for stash_key in stash:
		_free_edge_ids.erase(int(stash[stash_key]["id"]))

	# 2. Re-evaluate the node predicate across the dirty set.
	var touched: Array[int] = []
	for t in dirty_tiles:
		var is_road := _road_tiles.has(t)
		var was_node: bool = tile_to_node.has(t)
		var should_be_node := is_road and _is_node_tile(t)
		if was_node and not should_be_node:
			_delete_node(int(tile_to_node[t]))
		elif should_be_node and not was_node:
			touched.append(_create_node(t))
		elif should_be_node:
			touched.append(int(tile_to_node[t]))
	# Endpoints of deleted edges that still exist must be retraced too — an
	# edit can merge two edges through a node that itself did not change.
	for key in _sorted_keys(stash):
		var record: Dictionary = stash[key]["record"]
		for tile in [record["tiles"][0], record["tiles"][-1]]:
			if tile_to_node.has(tile):
				touched.append(int(tile_to_node[tile]))
	# Neighbours of dirty tiles that are nodes: their outgoing chain may now
	# reach a different place.
	for t in dirty_tiles:
		for d in DIRS:
			var q: Vector2i = t + d
			if tile_to_node.has(q):
				touched.append(int(tile_to_node[q]))

	var unique_touched: Array[int] = []
	var seen_nodes: Dictionary = {}
	for node_id in touched:
		if not seen_nodes.has(node_id):
			seen_nodes[node_id] = true
			unique_touched.append(node_id)
	unique_touched.sort()

	# 3. Retrace, within the per-tick tile budget.
	var seen: Dictionary = {}
	var added: Array[int] = []
	var budget := tun.rebuild_tile_budget
	var deferred: Array[Vector2i] = []
	for i in unique_touched.size():
		if last_retraced_tiles >= budget:
			# Carry the rest: the graph stays valid, just not yet complete.
			for j in range(i, unique_touched.size()):
				if _nodes.has(unique_touched[j]):
					deferred.append(_nodes[unique_touched[j]]["tile"])
			break
		_trace_from_nodes([unique_touched[i]], seen, added, stash)
	_promote_orphan_loops(dirty_tiles, seen, added, stash)
	# Reservations nobody claimed go back on the free list, ascending.
	for stash_key in _sorted_keys(stash):
		var reserved_id := int(stash[stash_key]["id"])
		if not _edges.has(reserved_id) and not _free_edge_ids.has(reserved_id):
			_free_edge_ids.append(reserved_id)
	_free_edge_ids.sort()
	_refresh_node_meta(unique_touched)
	_pending_dirty = deferred
	graph_dirty = not _pending_dirty.is_empty()
	_components_dirty = true
	graph_version += 1
	# An edge that was deleted and recreated with the SAME id and tile list is
	# not a change at all — §2.5's edge-id stability rule.
	var net_removed: Array[int] = []
	for edge_id in removed:
		if not _edges.has(edge_id):
			net_removed.append(edge_id)
	var net_added: Array[int] = []
	for edge_id in added:
		if not removed.has(edge_id):
			net_added.append(edge_id)
	return {"added_edges": net_added, "removed_edges": net_removed}


# --------------------------------------------------------------- tile queries

## Reads the AUTHORITATIVE tile grid. Used only where membership is in question;
## every hot path uses `_class_of`, which reads the cached membership map.
func _grid_class(t: Vector2i) -> int:
	if not TileGrid.in_bounds(t.x, t.y):
		return RoadTunables.CLASS_NONE
	return grid.road_class_at(t.x, t.y)


func _class_of(t: Vector2i) -> int:
	return int(_road_tiles.get(t, RoadTunables.CLASS_NONE))


## Doc 10 §2.4 calls an edge's class "uniform by construction", but at a class
## TRANSITION both flanking tiles satisfy the node predicate, so the 2-tile edge
## between them is genuinely mixed (see §9 of the roads REPORT). An edge takes
## the SLOWEST class it contains, so a mixed segment can never be priced with
## the arterial bonus it does not fully deserve.
func _edge_class(tiles: Array) -> int:
	var best := _class_of(tiles[0])
	var best_mult := tun.class_mult(best)
	for t in tiles:
		var candidate := _class_of(t)
		var mult := tun.class_mult(candidate)
		if mult < best_mult or (mult == best_mult and candidate < best):
			best = candidate
			best_mult = mult
	return best


func _is_road(t: Vector2i) -> bool:
	return _road_tiles.has(t)


func is_road_tile(t: Vector2i) -> bool:
	return _road_tiles.has(t)


func road_tile_count() -> int:
	return _road_tiles.size()


## Every road tile in (y, x) order — the scan order the whole project agrees on.
##
## MEMOISED on `graph_version`, and the key is exact rather than approximate:
## `_road_tiles` is written in exactly two places (`rebuild_all` and the
## membership re-read at the top of `apply_edits`), both of which bump
## `graph_version` before they return, and nothing calls this between the write
## and the bump. Callers still get a COPY, so the cache cannot be mutated from
## outside and the semantics of this accessor have not moved.
##
## Why it is worth caching: the sort is `sort_custom` with a GDScript lambda, so
## every comparison is a scripted call. On the benchmark city's 3,132 tiles that
## is **3.44 ms** once the dictionary's key order has been shuffled by a few
## edits (0.99 ms straight after a boot, when the keys are already in order —
## which is why it never looked expensive). This is called four times per tick
## inside `road_network.gd` and once per road edit by the renderer's street
## rebuild; the copy that replaces it is 0.17 ms.
func road_tiles_sorted() -> Array:
	if _tiles_sorted_version != graph_version:
		_tiles_sorted = _sorted_tiles(_road_tiles.keys())
		_tiles_sorted_version = graph_version
	return _tiles_sorted.duplicate()


func road_tile_counts() -> Dictionary:
	var street := 0
	var avenue := 0
	for t in _road_tiles:
		if int(_road_tiles[t]) == RoadTunables.CLASS_AVENUE:
			avenue += 1
		else:
			street += 1
	return {"STREET": street, "AVENUE": avenue}


func _road_neighbours(t: Vector2i) -> Array:
	var out: Array = []
	for d in DIRS:
		var q: Vector2i = t + d
		if _is_road(q):
			out.append(q)
	return out


## §2.4 node predicate: degree ≠ 2, or degree 2 with a class transition.
func _is_node_tile(t: Vector2i) -> bool:
	var neighbours := _road_neighbours(t)
	if neighbours.size() != 2:
		return true
	var own := _class_of(t)
	var a := _class_of(neighbours[0])
	var b := _class_of(neighbours[1])
	return a != b or a != own


func _scan_road_tiles() -> Array:
	var out: Array = []
	for z in TileGrid.SIZE:
		for x in TileGrid.SIZE:
			if grid.road_class_at(x, z) != RoadTunables.CLASS_NONE:
				out.append(Vector2i(x, z))
	return out


# ------------------------------------------------------------- nodes & edges

func _create_node(t: Vector2i) -> int:
	if tile_to_node.has(t):
		return int(tile_to_node[t])
	var node_id: int
	if not _free_node_ids.is_empty():
		node_id = _free_node_ids.pop_front()
	else:
		node_id = _next_node_id
		_next_node_id += 1
	_nodes[node_id] = {
		"id": node_id, "tile": t, "edge_ids": [] as Array[int], "degree": 0,
		"signalised": false, "powered": true, "component_id": -1,
	}
	tile_to_node[t] = node_id
	_node_order.append(node_id)
	_order_dirty = true
	return node_id


func _delete_node(node_id: int) -> void:
	if not _nodes.has(node_id):
		return
	var t: Vector2i = _nodes[node_id]["tile"]
	tile_to_node.erase(t)
	_nodes.erase(node_id)
	_node_order.erase(node_id)
	_free_node_ids.append(node_id)
	_order_dirty = true


func _create_edge(tiles: Array, key: String, stash: Dictionary = {}) -> int:
	var edge_id: int
	var carried: Dictionary = {}
	# The `_edges.has` guard belts the reservation braces in `apply_edits`: an id
	# that is somehow already live is never handed out a second time, whatever
	# the stash says.
	if stash.has(key) and not _edges.has(int(stash[key]["id"])):
		edge_id = int(stash[key]["id"])
		carried = stash[key]["record"]
		_free_edge_ids.erase(edge_id)
	elif not _free_edge_ids.is_empty():
		edge_id = _free_edge_ids.pop_front()
	else:
		edge_id = _next_edge_id
		_next_edge_id += 1
	var typed: Array[Vector2i] = []
	for t in tiles:
		typed.append(t)
	var node_a := int(tile_to_node.get(typed[0], -1))
	var node_b := int(tile_to_node.get(typed[typed.size() - 1], -1))
	var record := {
		"id": edge_id, "key": key,
		"node_a": node_a, "node_b": node_b,
		"tiles": typed,
		"length_m": float(typed.size() - 1) * tun.tile_m,
		"road_class": _edge_class(typed),
		"condition": float(carried.get("condition", 1.0)),
		"congestion": float(carried.get("congestion", 0.0)),
		"closure_id": int(carried.get("closure_id", -1)),
		"closure_cause": String(carried.get("closure_cause", "")),
		"blocked_mask": int(carried.get("blocked_mask", 0)),
		"district_id": String(carried.get("district_id", "")),
		"dens_index": float(carried.get("dens_index", tun.dens_min)),
		"speed_override": float(carried.get("speed_override", 1.0)),
		"override_until_minute": int(carried.get("override_until_minute", -1)),
	}
	_edges[edge_id] = record
	_edge_order.append(edge_id)
	_order_dirty = true
	_edge_key[key] = edge_id
	for t in typed:
		var list: Array = tile_edges.get(t, [])
		if not list.has(edge_id):
			list.append(edge_id)
			list.sort()
		tile_edges[t] = list
	if node_a >= 0:
		_attach_edge_to_node(node_a, edge_id)
	if node_b >= 0 and node_b != node_a:
		_attach_edge_to_node(node_b, edge_id)
	return edge_id


func _attach_edge_to_node(node_id: int, edge_id: int) -> void:
	var list: Array[int] = _nodes[node_id]["edge_ids"]
	if not list.has(edge_id):
		list.append(edge_id)
		list.sort()


func _delete_edge(edge_id: int) -> void:
	if not _edges.has(edge_id):
		return
	var record: Dictionary = _edges[edge_id]
	for t in record["tiles"]:
		var list: Array = tile_edges.get(t, [])
		list.erase(edge_id)
		if list.is_empty():
			tile_edges.erase(t)
		else:
			tile_edges[t] = list
	for node_key in ["node_a", "node_b"]:
		var node_id := int(record[node_key])
		if _nodes.has(node_id):
			(_nodes[node_id]["edge_ids"] as Array).erase(edge_id)
	_edge_key.erase(String(record["key"]))
	_edges.erase(edge_id)
	_edge_order.erase(edge_id)
	_free_edge_ids.append(edge_id)
	_order_dirty = true


# ------------------------------------------------------------------- tracing

func _direction_covered(node_tile: Vector2i, toward: Vector2i) -> bool:
	for edge_id in tile_edges.get(node_tile, []):
		var tiles: Array = _edges[edge_id]["tiles"]
		if tiles[0] == node_tile and tiles.size() >= 2 and tiles[1] == toward:
			return true
		if tiles[tiles.size() - 1] == node_tile and tiles.size() >= 2 \
				and tiles[tiles.size() - 2] == toward:
			return true
	return false


func _walk(from_tile: Vector2i, first: Vector2i) -> Array:
	var out: Array = [from_tile, first]
	var prev := from_tile
	var cur := first
	var guard := 0
	var limit := TileGrid.SIZE * TileGrid.SIZE
	while not tile_to_node.has(cur):
		var nxt := Vector2i(-1, -1)
		var found := false
		for d in DIRS:
			var q: Vector2i = cur + d
			if q == prev:
				continue
			if _is_road(q):
				nxt = q
				found = true
				break
		if not found:
			break
		prev = cur
		cur = nxt
		out.append(cur)
		guard += 1
		if guard > limit:
			break
	return out


func _trace_from_nodes(node_ids: Array, seen: Dictionary, added: Array,
		stash: Dictionary = {}) -> void:
	for node_id in node_ids:
		if not _nodes.has(node_id):
			continue
		var nt: Vector2i = _nodes[node_id]["tile"]
		for d in DIRS:
			var p: Vector2i = nt + d
			if not _is_road(p):
				continue
			if _direction_covered(nt, p):
				continue
			var tiles := _walk(nt, p)
			if tiles.size() < 2:
				continue
			if not tile_to_node.has(tiles[tiles.size() - 1]):
				continue  # incomplete chain (budget stop) — retried next pass
			var key := _tiles_key(tiles)
			if seen.has(key) or _edge_key.has(key):
				continue
			seen[key] = true
			added.append(_create_edge(tiles, key, stash))
			last_retraced_tiles += tiles.size()


## §2.4 degenerate case: a connected component with zero node candidates (a
## pure loop) gets its lowest-(y, x) tile promoted to a node.
func _promote_orphan_loops(candidates: Array, seen: Dictionary, added: Array,
		stash: Dictionary = {}) -> void:
	var visited: Dictionary = {}
	for entry in candidates:
		var t: Vector2i = entry
		if not _is_road(t) or visited.has(t) or tile_to_node.has(t) or tile_edges.has(t):
			continue
		# Flood the component; abort if it already contains a node.
		var component: Array = []
		var stack: Array = [t]
		var local: Dictionary = {t: true}
		var has_node := false
		while not stack.is_empty():
			var cur: Vector2i = stack.pop_back()
			component.append(cur)
			if tile_to_node.has(cur):
				has_node = true
				break
			for d in DIRS:
				var q: Vector2i = cur + d
				if _is_road(q) and not local.has(q):
					local[q] = true
					stack.push_back(q)
		for c in local:
			visited[c] = true
		if has_node:
			continue
		var sorted_component := _sorted_tiles(component)
		if sorted_component.is_empty():
			continue
		var promoted := _create_node(sorted_component[0])
		_trace_from_nodes([promoted], seen, added, stash)


func _refresh_node_meta(node_ids: Array) -> void:
	var ids := node_ids if not node_ids.is_empty() else node_ids_sorted()
	for node_id in ids:
		if not _nodes.has(node_id):
			continue
		var record: Dictionary = _nodes[node_id]
		var t: Vector2i = record["tile"]
		record["degree"] = _road_neighbours(t).size()
		record["signalised"] = _compute_signalised(record)
	# A node that just changed its signalised verdict has not been through
	# `refresh_signal_power` yet, so the dark count it maintains is no longer
	# authoritative. -1 reads as "unknown" and puts the two dark-signal queries
	# back on their sweep until the next tick settles it.
	dark_signals = -1


## `signalised = degree ≥ 3 AND (any incident edge is AVENUE OR degree ≥ 4)`,
## generalised through each class's `signal_min_degree` (avenue 3, street 4).
func _compute_signalised(record: Dictionary) -> bool:
	var degree := int(record["degree"])
	if degree < 3:
		return false
	var min_degree := 99
	for edge_id in record["edge_ids"]:
		if not _edges.has(edge_id):
			continue
		min_degree = mini(min_degree, tun.signal_min_degree(int(_edges[edge_id]["road_class"])))
	if min_degree == 99:
		min_degree = tun.signal_min_degree(_class_of(record["tile"]))
	return degree >= min_degree


# ---------------------------------------------------------------- components

## Deterministic component labelling by union-find over the edge list, with
## component ids handed out in ascending node-id order so the partition is
## reproducible. Union-find over a plain int Array is ~30x faster than the
## dictionary BFS it replaced, which mattered: this runs on every road edit.
func _relabel_components() -> void:
	_components.clear()
	var parent: Array[int] = []
	parent.resize(_next_node_id)
	for i in _next_node_id:
		parent[i] = i
	for edge_id in _edge_order:
		var record: Dictionary = _edges[edge_id]
		var a := int(record["node_a"])
		var b := int(record["node_b"])
		if a >= 0 and b >= 0:
			_union(parent, a, b)
	var root_to_component: Dictionary = {}
	var next_component := 0
	for node_id in node_ids_sorted():
		var root := _find(parent, node_id)
		if not root_to_component.has(root):
			root_to_component[root] = next_component
			next_component += 1
		var component_id := int(root_to_component[root])
		_nodes[node_id]["component_id"] = component_id
		var members: Array = _components.get(component_id, [])
		members.append(node_id)
		_components[component_id] = members
	_component_count = next_component
	_components_dirty = false


static func _find(parent: Array[int], start: int) -> int:
	var root := start
	while parent[root] != root:
		root = parent[root]
	var cursor := start
	while parent[cursor] != root:
		var next := parent[cursor]
		parent[cursor] = root
		cursor = next
	return root


static func _union(parent: Array[int], a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra == rb:
		return
	if ra < rb:
		parent[rb] = ra
	else:
		parent[ra] = rb


func _settle_components() -> void:
	if _components_dirty:
		_relabel_components()


func component_count() -> int:
	_settle_components()
	return _component_count


func component_members(component_id: int) -> Array:
	_settle_components()
	return _components.get(component_id, [])


func component_ids_sorted() -> Array:
	_settle_components()
	var ids := _components.keys()
	ids.sort()
	return ids


func component_of_node(node_id: int) -> int:
	_settle_components()
	return int(_nodes.get(node_id, {}).get("component_id", -1))


func component_of_tile(t: Vector2i) -> int:
	if tile_to_node.has(t):
		return component_of_node(int(tile_to_node[t]))
	var list: Array = tile_edges.get(t, [])
	if list.is_empty():
		return -1
	return component_of_node(int(_edges[list[0]]["node_a"]))


# ------------------------------------------------------------------ accessors

func node(node_id: int) -> Dictionary:
	return _nodes.get(node_id, {})


func edge(edge_id: int) -> Dictionary:
	return _edges.get(edge_id, {})


## The live edge record, or `null` when there is no such edge. `edge()` returns
## a FRESH empty dictionary on a miss — allocated on every call, hit or miss,
## because the `{}` default is built before the lookup runs — which the sweeps
## that touch every edge every minute cannot afford.
func edge_or_null(edge_id: int) -> Variant:
	return _edges.get(edge_id)


func has_edge(edge_id: int) -> bool:
	return _edges.has(edge_id)


## §3.2 + §2.4's edge-id stability rule, applied across a SAVE. The graph is
## rebuilt from tiles on load, and `rebuild_all()` numbers edges in its own scan
## order — which is NOT the order the live graph reached through §2.5's
## incremental retrace, because that recycles ids off a free list. The two
## orderings agree only while nothing has ever edited a tile; the moment a road
## is built the loaded graph holds the same id SET over a different tile
## partition, every consumer holding an id is silently pointed at a different
## corridor, and the cosmetic traffic feed's per-edge draws diverge.
##
## So the labelling travels with the save, keyed by each edge's canonical tile
## key — the orientation-independent polyline signature this class already
## recycles ids by — and is re-applied here. Edges whose key is not in the map
## (an old save, or a tile edited between save and load) keep an id no adopted
## edge claimed, so the result is always a valid, collision-free labelling.
##
## `next_id` / `free_ids` restore the ALLOCATOR too, so an edge created after
## the load lands on the id the live run would have given it.
## Returns the number of edges that adopted a saved id.
func adopt_edge_ids(key_to_id: Dictionary, next_id: int = -1,
		free_ids: Array = []) -> int:
	if _edges.is_empty():
		return 0
	var records: Array = []
	for edge_id in edge_ids_sorted():
		records.append(_edges[edge_id])
	var claimed: Dictionary = {}
	var relabelled: Array = []       # [record, new_id]
	var leftovers: Array = []
	var adopted := 0
	for entry in records:
		var record: Dictionary = entry
		var key := String(record["key"])
		if key_to_id.has(key):
			var wanted := int(key_to_id[key])
			if not claimed.has(wanted):
				claimed[wanted] = true
				relabelled.append([record, wanted])
				adopted += 1
				continue
		leftovers.append(record)
	# Unclaimed ids, lowest first, so the fallback is deterministic.
	var spare := 0
	for entry in leftovers:
		while claimed.has(spare):
			spare += 1
		claimed[spare] = true
		relabelled.append([entry, spare])
	_edges.clear()
	_edge_key.clear()
	_edge_order.clear()
	for t in tile_edges:
		(tile_edges[t] as Array).clear()
	for node_id in _nodes:
		(_nodes[node_id]["edge_ids"] as Array).clear()
	for pair in relabelled:
		var record: Dictionary = pair[0]
		var new_id := int(pair[1])
		record["id"] = new_id
		_edges[new_id] = record
		_edge_key[String(record["key"])] = new_id
		_edge_order.append(new_id)
		for t in record["tiles"]:
			(tile_edges[t] as Array).append(new_id)
		for node_key in ["node_a", "node_b"]:
			var node_id := int(record[node_key])
			if _nodes.has(node_id) and not (_nodes[node_id]["edge_ids"] as Array).has(new_id):
				(_nodes[node_id]["edge_ids"] as Array).append(new_id)
	# Relabelling never changes the edge SET, so no tile should end up with an
	# empty list — but `_promote_orphan_loops` reads `tile_edges.has(t)` as
	# "this tile is already on an edge", so an empty entry left behind would be
	# a silent lie. Sweep them.
	var empty_tiles: Array = []
	for t in tile_edges:
		var list: Array = tile_edges[t]
		if list.is_empty():
			empty_tiles.append(t)
		else:
			list.sort()
	for t in empty_tiles:
		tile_edges.erase(t)
	for node_id in _nodes:
		(_nodes[node_id]["edge_ids"] as Array).sort()
	_order_dirty = true
	var highest := 0
	for edge_id in _edges:
		highest = maxi(highest, int(edge_id) + 1)
	_next_edge_id = maxi(next_id, highest) if next_id >= 0 else highest
	_free_edge_ids.clear()
	for entry in free_ids:
		var free_id := int(entry)
		if not _edges.has(free_id) and free_id < _next_edge_id:
			_free_edge_ids.append(free_id)
	return adopted


## The allocator half of `adopt_edge_ids`, for the save section.
func edge_allocator_state() -> Dictionary:
	return {"next_edge_id": _next_edge_id, "free_edge_ids": _free_edge_ids.duplicate()}


## `adopt_edge_ids`' twin for NODES, keyed by the node's tile (`"x,y"`), which
## is its only rebuild-stable name. Node ids are as load-bearing as edge ids:
## `node_ids_sorted()` is the iteration order of the per-tick signal-power
## refresh and the congestion environment, and the cosmetic feed picks a car's
## next edge off `_nodes[id].edge_ids` — so a renumbered node set is a different
## city, however identical its geometry.
func adopt_node_ids(tile_to_id: Dictionary, next_id: int = -1,
		free_ids: Array = []) -> int:
	if _nodes.is_empty():
		return 0
	var records: Array = []
	for node_id in node_ids_sorted():
		records.append(_nodes[node_id])
	var claimed: Dictionary = {}
	var relabelled: Array = []
	var leftovers: Array = []
	var remap: Dictionary = {}   # old id -> new id
	var adopted := 0
	for entry in records:
		var record: Dictionary = entry
		var t: Vector2i = record["tile"]
		var key := "%d,%d" % [t.x, t.y]
		if tile_to_id.has(key):
			var wanted := int(tile_to_id[key])
			if not claimed.has(wanted):
				claimed[wanted] = true
				relabelled.append([record, wanted])
				adopted += 1
				continue
		leftovers.append(record)
	var spare := 0
	for entry in leftovers:
		while claimed.has(spare):
			spare += 1
		claimed[spare] = true
		relabelled.append([entry, spare])
	_nodes.clear()
	_node_order.clear()
	tile_to_node.clear()
	for pair in relabelled:
		var record: Dictionary = pair[0]
		var new_id := int(pair[1])
		remap[int(record["id"])] = new_id
		record["id"] = new_id
		_nodes[new_id] = record
		_node_order.append(new_id)
		tile_to_node[record["tile"]] = new_id
	for edge_id in _edges:
		var edge_record: Dictionary = _edges[edge_id]
		for node_key in ["node_a", "node_b"]:
			var old_id := int(edge_record[node_key])
			edge_record[node_key] = int(remap.get(old_id, old_id))
	_order_dirty = true
	_components_dirty = true
	var highest := 0
	for node_id in _nodes:
		highest = maxi(highest, int(node_id) + 1)
	_next_node_id = maxi(next_id, highest) if next_id >= 0 else highest
	_free_node_ids.clear()
	for entry in free_ids:
		var free_id := int(entry)
		if not _nodes.has(free_id) and free_id < _next_node_id:
			_free_node_ids.append(free_id)
	return adopted


## The third thing a rebuild does not reproduce: an edge's polyline ORIENTATION.
## `_tiles_key` is deliberately orientation-independent (so an edge keeps its id
## whichever end a retrace reaches first), which means a rebuilt edge can come
## back head-to-tail. That is not cosmetic — the cosmetic feed stores each car's
## `forward` flag and arc-length `s_m` against the tile order, and doc 06's
## polylines are consumed in it — so the saved head tile is re-applied here.
## `head_by_key` is `{canonical key: Vector2i}`. Returns how many were flipped.
func orient_edges(head_by_key: Dictionary) -> int:
	var flipped := 0
	for edge_id in _edges:
		var record: Dictionary = _edges[edge_id]
		var key := String(record["key"])
		if not head_by_key.has(key):
			continue
		var tiles: Array = record["tiles"]
		if tiles.is_empty() or tiles[0] == head_by_key[key]:
			continue
		var reversed_tiles: Array[Vector2i] = []
		for i in range(tiles.size() - 1, -1, -1):
			reversed_tiles.append(tiles[i])
		record["tiles"] = reversed_tiles
		var node_a := int(record["node_a"])
		record["node_a"] = int(record["node_b"])
		record["node_b"] = node_a
		flipped += 1
	return flipped


## `{canonical key: [head_x, head_y]}` for the save section.
func edge_heads() -> Dictionary:
	var out := {}
	for edge_id in edge_ids_sorted():
		var record: Dictionary = _edges[edge_id]
		var head: Vector2i = (record["tiles"] as Array)[0]
		out[String(record["key"])] = [head.x, head.y]
	return out


func node_allocator_state() -> Dictionary:
	return {"next_node_id": _next_node_id, "free_node_ids": _free_node_ids.duplicate()}


## `{"x,y": node_id}` for the save section.
func node_labels() -> Dictionary:
	var out := {}
	for node_id in node_ids_sorted():
		var t: Vector2i = _nodes[node_id]["tile"]
		out["%d,%d" % [t.x, t.y]] = node_id
	return out


func node_ids_sorted() -> Array[int]:
	_settle_order()
	return _node_order.duplicate()


func edge_ids_sorted() -> Array[int]:
	_settle_order()
	return _edge_order.duplicate()


## The ascending id orders WITHOUT the defensive copy the `_sorted()` accessors
## make. STRICTLY read-only, and never held across a graph edit — for the
## per-tick sweeps inside sim/roads/ that only iterate. Everything outside this
## directory gets the copy.
func edge_ids_ref() -> Array[int]:
	_settle_order()
	return _edge_order


func node_ids_ref() -> Array[int]:
	_settle_order()
	return _node_order


func _settle_order() -> void:
	if not _order_dirty:
		return
	_node_order.sort()
	_edge_order.sort()
	_free_node_ids.sort()
	_free_edge_ids.sort()
	_order_dirty = false


func node_count() -> int:
	return _nodes.size()


func edge_count() -> int:
	return _edges.size()


func node_at(t: Vector2i) -> int:
	return int(tile_to_node.get(t, -1))


## One representative edge for a tile (the lowest id containing it); node tiles
## resolve too, so `tile_to_edge` covers every road tile (doc 10 test 1).
func edge_at(t: Vector2i) -> int:
	var list: Array = tile_edges.get(t, [])
	return int(list[0]) if not list.is_empty() else -1


func edges_at(t: Vector2i) -> Array:
	return (tile_edges.get(t, []) as Array).duplicate()


func edge_tile_index(edge_id: int, t: Vector2i) -> int:
	if not _edges.has(edge_id):
		return -1
	return (_edges[edge_id]["tiles"] as Array).find(t)


## §2.7 endpoint snapping: expanding ring up to SNAP_RADIUS_TILES, ties broken
## by (dist, y, x). Returns Vector2i(-1, -1) when nothing is in range.
func nearest_road_tile(t: Vector2i, radius: int = -1) -> Vector2i:
	if _is_road(t):
		return t
	var limit := radius if radius >= 0 else tun.snap_radius_tiles
	# The tie-break is lexicographic on (y, x) and both coordinates are inside
	# [0, TileGrid.SIZE), so `y * SIZE + x` orders exactly as the `[q.y, q.x]`
	# array pair did — same winner, without allocating a two-element Array (and
	# comparing it) for every road tile in every ring.
	var r := 1
	while r <= limit:
		var best := Vector2i(-1, -1)
		var best_key := 0x7FFFFFFF
		var dz := -r
		while dz <= r:
			var dx := -r
			var step := 1 if absi(dz) == r else 2 * r
			while dx <= r:
				var q := Vector2i(t.x + dx, t.y + dz)
				dx += step
				if not _is_road(q):
					continue
				var key := q.y * TileGrid.SIZE + q.x
				if best.x < 0 or key < best_key:
					best = q
					best_key = key
			dz += 1
		if best.x >= 0:
			return best
		r += 1
	return Vector2i(-1, -1)


func nearest_node(t: Vector2i) -> int:
	var road := nearest_road_tile(t)
	if road.x < 0:
		return -1
	if tile_to_node.has(road):
		return int(tile_to_node[road])
	var edge_id := edge_at(road)
	if edge_id < 0:
		return -1
	var record: Dictionary = _edges[edge_id]
	var index := (record["tiles"] as Array).find(road)
	var from_a := index
	var from_b := (record["tiles"] as Array).size() - 1 - index
	return int(record["node_a"]) if from_a <= from_b else int(record["node_b"])


func other_node(edge_id: int, node_id: int) -> int:
	var record: Dictionary = _edges[edge_id]
	return int(record["node_b"]) if int(record["node_a"]) == node_id else int(record["node_a"])


## Signal power refresh (§2.6): read at P08 from THIS step's P06 output, so a
## signal that goes dark at P06 slows the ambulance dispatched at P09 with zero
## lag. `powered_of` is `power.is_tile_powered(tile) -> bool`.
func refresh_signal_power(powered_of: Callable) -> int:
	var changed := 0
	var dark := 0
	for node_id in node_ids_ref():   # EVERY_TICK: no defensive copy of the order
		var record: Dictionary = _nodes[node_id]
		if not bool(record["signalised"]):
			record["powered"] = true
			continue
		var powered := true
		if powered_of.is_valid():
			powered = bool(powered_of.call(record["tile"]))
		if bool(record["powered"]) != powered:
			record["powered"] = powered
			changed += 1
		if not powered:
			dark += 1
	# This loop is the only place `powered` moves and it visits every node, so
	# the count falls out of it for nothing. `dark_signal_counts_by_edge` and
	# `dark_signal_node_ids` read it to answer "{}" without a sweep, which is
	# the normal case and is taken once a game-minute by the congestion pass.
	dark_signals = dark
	return changed


## Doc 06 consumes this for `dark_frac` (§2.11). `district_of` maps a tile to a
## district id; pass "" to list every signalised intersection in the city.
func signalised_intersections(district_id: String, district_of: Callable) -> Array:
	var out: Array = []
	for node_id in node_ids_sorted():
		var record: Dictionary = _nodes[node_id]
		if not bool(record["signalised"]):
			continue
		if district_id != "":
			var owner := ""
			if district_of.is_valid():
				owner = String(district_of.call(record["tile"]))
			if owner != district_id:
				continue
		out.append({"node_id": node_id, "tile": record["tile"], "powered": bool(record["powered"])})
	return out


func dark_signal_endpoints(edge_id: int) -> int:
	var record: Dictionary = _edges.get(edge_id, {})
	if record.is_empty():
		return 0
	# Unrolled over the two endpoints (a loop edge counts its node once), so a
	# per-tick caller pays no Array and no Dictionary for the dedupe.
	var node_a := int(record["node_a"])
	var node_b := int(record["node_b"])
	var count := _dark_at(node_a)
	if node_b != node_a:
		count += _dark_at(node_b)
	return count


func _dark_at(node_id: int) -> int:
	if node_id < 0:
		return 0
	var n: Dictionary = _nodes.get(node_id, {})
	if n.is_empty():
		return 0
	return 1 if (bool(n["signalised"]) and not bool(n["powered"])) else 0


## The dark signalised nodes as a membership set {node_id: true}. Empty when
## every signal is lit, which is the normal case — a caller that needs the flag
## for many edges asks once instead of probing the node table twice per edge.
func dark_signal_node_ids() -> Dictionary:
	var out: Dictionary = {}
	if dark_signals == 0:
		return out
	for node_id in _nodes:
		var n: Dictionary = _nodes[node_id]
		if bool(n["signalised"]) and not bool(n["powered"]):
			out[node_id] = true
	return out


## The inverse of `dark_signal_endpoints` over the WHOLE graph: {edge_id: count}
## for every edge with at least one dark signalised endpoint, and `{}` — the
## normal case, all signals lit — without touching a single edge.
##
## Built by walking the dark NODES and their incident-edge lists, which
## `_attach_edge_to_node` keeps as the exact deduped inverse of each edge's
## (node_a, node_b). So this agrees edge-for-edge with asking
## `dark_signal_endpoints` about all E edges, at O(dark nodes) instead.
func dark_signal_counts_by_edge() -> Dictionary:
	var out: Dictionary = {}
	if dark_signals == 0:
		return out
	for node_id in _nodes:
		var n: Dictionary = _nodes[node_id]
		if not bool(n["signalised"]) or bool(n["powered"]):
			continue
		for edge_id in n["edge_ids"]:
			out[edge_id] = int(out.get(edge_id, 0)) + 1
	return out


## Edges within `hops` graph hops of `edge_id`, keyed edge_id -> hop count
## (excluding the edge itself). Used by closure spillback (§2.10).
func edges_within_hops(edge_id: int, hops: int) -> Dictionary:
	var out: Dictionary = {}
	var frontier: Array[int] = [edge_id]
	var seen: Dictionary = {edge_id: 0}
	for hop in range(1, hops + 1):
		var next_frontier: Array[int] = []
		for current in frontier:
			if not _edges.has(current):
				continue
			var record: Dictionary = _edges[current]
			for node_key in ["node_a", "node_b"]:
				var node_id := int(record[node_key])
				if not _nodes.has(node_id):
					continue
				var incident: Array = _nodes[node_id]["edge_ids"]
				for neighbour in incident:
					if seen.has(neighbour):
						continue
					seen[neighbour] = hop
					out[neighbour] = hop
					next_frontier.append(neighbour)
		frontier = next_frontier
	return out


# --------------------------------------------------------------------- helpers

static func _tiles_key(tiles: Array) -> String:
	var count := tiles.size()
	var forward := PackedStringArray()
	var reverse := PackedStringArray()
	for i in count:
		var a: Vector2i = tiles[i]
		var b: Vector2i = tiles[count - 1 - i]
		forward.append("%d,%d" % [a.x, a.y])
		reverse.append("%d,%d" % [b.x, b.y])
	var fwd := "|".join(forward)
	var rev := "|".join(reverse)
	return fwd if fwd <= rev else rev


## (y, x) order, via a packed integer key rather than `sort_custom`.
##
## `sort_custom` calls a GDScript lambda for every comparison, which on the
## benchmark city's 3,132 road tiles is **3.44 ms** — the single largest term in
## the renderer's street rebuild and four calls a tick inside this directory.
## A tile's (y, x) order is exactly the order of `y·SIZE + x`, so the comparison
## can be handed to `PackedInt32Array.sort()`, which is one C++ sort over plain
## ints: **0.29 ms** for the same city, ordering identical by construction.
##
## The out-of-bounds fallback is not defensive padding: `apply_edits` sorts its
## dirty set, and the edit list it is handed is the caller's, so a tile outside
## the grid must still sort the way it always did rather than fold onto another
## row.
static func _sorted_tiles(tiles: Array) -> Array:
	var n := tiles.size()
	var keys := PackedInt32Array()
	keys.resize(n)
	var i := 0
	for raw: Variant in tiles:
		var t: Vector2i = raw
		if t.x < 0 or t.x >= TileGrid.SIZE or t.y < 0 or t.y >= TileGrid.SIZE:
			return _sorted_tiles_compared(tiles)
		keys[i] = t.y * TileGrid.SIZE + t.x
		i += 1
	keys.sort()
	var out: Array = []
	out.resize(n)
	for j in n:
		var key := keys[j]
		out[j] = Vector2i(key % TileGrid.SIZE, key / TileGrid.SIZE)
	return out


static func _sorted_tiles_compared(tiles: Array) -> Array:
	var out: Array = tiles.duplicate()
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	return out


static func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
