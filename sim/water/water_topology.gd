class_name WaterTopology
extends RefCounted
## Connected components, the tile BFS and every cache that is recomputed on
## TOPOLOGY CHANGE ONLY (doc 05 §2.2, §2.3, §2.5) — never per tick.
##
## Connectivity is physical: two entities are joined when they share a tile.
## That is what makes doc 09's starter loop work without authoring `a`/`b` on
## every main — `M_TIE` meets `M_NORTH` at (23,16) because the pipes touch, and
## a pump joins its main because its terminal tile is on the main's path.
##
## Nothing here assigns a service PERCENTAGE to a radius (report 98 C-06):
## `hydrant_reach_tiles` and `max_service_distance_tiles` are attachment
## distances to a real graph edge, and a tile's pressure comes from its zone's
## mass balance, not from how far away it is.

var grid_size: int = 112

var zones: Array = []  # Array[PressureZone], sorted by zone_key
var zone_index_of_key: Dictionary = {}  # zone_key -> index
var zone_of_node: Dictionary = {}  # node id -> zone index
var zone_of_edge: Dictionary = {}  # edge id -> zone index

var zone_of_tile := PackedInt32Array()
var tile_factor := PackedFloat64Array()
var tile_distance := PackedInt32Array()

# Union-find over dense integer slots: nodes take 0..n-1 in sorted id order,
# live edges take n.. in sorted id order. Integer slots (rather than "N:<id>"
# strings) keep `rebuild_zones()` inside its millisecond budget on a full map,
# and because the slots are handed out in sorted order the "smallest root wins"
# rule still resolves exactly as a lexicographic comparison would.
var _parent := PackedInt32Array()
var _slot_of: Dictionary = {}  # "N:<id>" / "E:<id>" -> slot


func _init(p_grid_size: int = 112) -> void:
	grid_size = p_grid_size
	_reset_tile_caches()


func tile_index(x: int, z: int) -> int:
	return z * grid_size + x


func in_bounds(x: int, z: int) -> bool:
	return x >= 0 and z >= 0 and x < grid_size and z < grid_size


func zone_at_tile(tile: Vector2i) -> int:
	if not in_bounds(tile.x, tile.y):
		return -1
	return zone_of_tile[tile_index(tile.x, tile.y)]


func factor_at_tile(tile: Vector2i) -> float:
	if not in_bounds(tile.x, tile.y):
		return 0.0
	return tile_factor[tile_index(tile.x, tile.y)]


func distance_at_tile(tile: Vector2i) -> int:
	if not in_bounds(tile.x, tile.y):
		return -1
	return tile_distance[tile_index(tile.x, tile.y)]


func zone(index: int) -> PressureZone:
	if index < 0 or index >= zones.size():
		return null
	return zones[index]


func zone_by_key(key: String) -> PressureZone:
	return zone(int(zone_index_of_key.get(key, -1)))


func zone_of(node_or_edge_id: String) -> PressureZone:
	if zone_of_node.has(node_or_edge_id):
		return zone(int(zone_of_node[node_or_edge_id]))
	if zone_of_edge.has(node_or_edge_id):
		return zone(int(zone_of_edge[node_or_edge_id]))
	return null


# ---------------------------------------------------------------- rebuild

## `nodes`: {id: WaterNode}. `edges`: {id: WaterEdge}. `terrain` may be null or
## any object exposing `elev_m(x, z) -> int` (doc 09's TileGrid).
func rebuild(nodes: Dictionary, edges: Dictionary, data: WaterData,
		terrain: Object = null) -> void:
	_union_find_components(nodes, edges)
	_build_zones(nodes, edges, data)
	_resolve_supply_chain(nodes, edges, data)
	_run_tile_bfs(edges, data)
	_compute_tile_factors(data, terrain)


func _union_find_components(nodes: Dictionary, edges: Dictionary) -> void:
	_slot_of.clear()
	var node_order := _sorted(nodes)
	var edge_order := _sorted(edges)
	for node_id in node_order:
		_slot_of["N:" + String(node_id)] = _slot_of.size()
	for edge_id in edge_order:
		if (edges[edge_id] as WaterEdge).is_live():
			_slot_of["E:" + String(edge_id)] = _slot_of.size()
	_parent.resize(_slot_of.size())
	for i in _parent.size():
		_parent[i] = i
	# Explicit endpoints first — a main always belongs with the nodes it names,
	# even if the endpoint tile was later built over.
	for edge_id in edge_order:
		var edge: WaterEdge = edges[edge_id]
		if not edge.is_live():
			continue
		var edge_slot: int = _slot_of["E:" + String(edge_id)]
		for endpoint: String in [edge.a, edge.b]:
			if nodes.has(endpoint):
				_union(edge_slot, int(_slot_of["N:" + endpoint]))
	# Then physical contact: the first entity to claim a tile owns it, and every
	# later entity on the same tile joins it. Deterministic — nodes then edges,
	# both in sorted id order.
	var occupant: Dictionary = {}
	for node_id in node_order:
		_claim(occupant, (nodes[node_id] as WaterNode).tile,
				int(_slot_of["N:" + String(node_id)]))
	for edge_id in edge_order:
		var edge: WaterEdge = edges[edge_id]
		if not edge.is_live():
			continue
		var edge_slot: int = _slot_of["E:" + String(edge_id)]
		for tile: Vector2i in edge.path:
			_claim(occupant, tile, edge_slot)


func _claim(occupant: Dictionary, tile: Vector2i, slot: int) -> void:
	if not in_bounds(tile.x, tile.y):
		return
	var index := tile_index(tile.x, tile.y)
	if occupant.has(index):
		_union(slot, int(occupant[index]))
	else:
		occupant[index] = slot


func _find(slot: int) -> int:
	var root := slot
	while _parent[root] != root:
		root = _parent[root]
	var cursor := slot
	while _parent[cursor] != root:
		var next := _parent[cursor]
		_parent[cursor] = root
		cursor = next
	return root


func _union(a: int, b: int) -> void:
	var ra := _find(a)
	var rb := _find(b)
	if ra == rb:
		return
	# Smallest slot wins; slots were handed out in sorted id order, so this is
	# the same representative a lexicographic comparison would pick.
	if ra < rb:
		_parent[rb] = ra
	else:
		_parent[ra] = rb


func _build_zones(nodes: Dictionary, edges: Dictionary, data: WaterData) -> void:
	zones.clear()
	zone_index_of_key.clear()
	zone_of_node.clear()
	zone_of_edge.clear()
	var members: Dictionary = {}  # root slot -> {nodes: [], edges: []}
	for node_id in _sorted(nodes):
		var root := _find(int(_slot_of["N:" + String(node_id)]))
		if not members.has(root):
			members[root] = {"nodes": [], "edges": []}
		members[root]["nodes"].append(String(node_id))
	for edge_id in _sorted(edges):
		var edge: WaterEdge = edges[edge_id]
		if not edge.is_live():
			continue
		var root := _find(int(_slot_of["E:" + String(edge_id)]))
		if not members.has(root):
			members[root] = {"nodes": [], "edges": []}
		members[root]["edges"].append(String(edge_id))
	var built: Array = []
	for root in _sorted(members):
		var group: Dictionary = members[root]
		var z := PressureZone.new()
		z.node_ids = group["nodes"]
		z.edge_ids = group["edges"]
		z.zone_key = _zone_key_for(z.node_ids, nodes)
		for node_id in z.node_ids:
			var node: WaterNode = nodes[node_id]
			match node.variant:
				&"pump":
					z.pump_ids.append(node_id)
				&"tank":
					z.tank_ids.append(node_id)
				&"source":
					z.source_ids.append(node_id)
				&"treatment":
					z.treatment_ids.append(node_id)
				&"booster":
					z.booster_ids.append(node_id)
		z.dead = true
		var head := 0.0
		for node_id in z.pump_ids + z.tank_ids:
			var node: WaterNode = nodes[node_id]
			if not node.is_live():
				continue
			z.dead = false
			head = maxf(head, float(data.component(node.variant, node.level, node.subtype)
					.get("head_m", 0.0)))
		for node_id in z.booster_ids:
			var node: WaterNode = nodes[node_id]
			if node.is_live():
				head += float(data.component(node.variant, node.level).get("head_bonus_m", 0.0))
		z.head_m = head
		for node_id in z.tank_ids:
			var node: WaterNode = nodes[node_id]
			if node.is_live():
				z.tank_capacity_m3 += float(data.component(node.variant, node.level)
						.get("capacity_m3", 0.0))
		built.append(z)
	built.sort_custom(func(a: PressureZone, b: PressureZone) -> bool:
		return a.zone_key < b.zone_key)
	for i in built.size():
		var z: PressureZone = built[i]
		z.index = i
		zones.append(z)
		zone_index_of_key[z.zone_key] = i
		for node_id in z.node_ids:
			zone_of_node[node_id] = i
		for edge_id in z.edge_ids:
			zone_of_edge[edge_id] = i


## Stable across rebuilds: the smallest FACILITY node id in the component
## (junctions are renumbered by main edits, facilities are not).
static func _zone_key_for(node_ids: Array, nodes: Dictionary) -> String:
	var best := ""
	for node_id in node_ids:
		var node: WaterNode = nodes[node_id]
		if node.variant == &"junction":
			continue
		if best == "" or String(node_id) < best:
			best = String(node_id)
	if best != "":
		return best
	for node_id in node_ids:
		if best == "" or String(node_id) < best:
			best = String(node_id)
	return best


## §2.5: shared upstream capacity is split among a component's pumps in
## proportion to `rated_flow_m3h`, and `feed_capacity` is the simplified
## min-cut — the mains actually incident to the zone's supply nodes.
func _resolve_supply_chain(nodes: Dictionary, edges: Dictionary, data: WaterData) -> void:
	for z: PressureZone in zones:
		var source_yield := 0.0
		var treatment_throughput := 0.0
		for node_id in z.source_ids:
			var node: WaterNode = nodes[node_id]
			if node.is_live():
				source_yield += float(data.component(node.variant, node.level, node.subtype)
						.get("yield_m3h", 0.0)) * node.cond_factor()
		for node_id in z.treatment_ids:
			var node: WaterNode = nodes[node_id]
			if node.is_live():
				treatment_throughput += float(data.component(node.variant, node.level)
						.get("throughput_m3h", 0.0)) * node.cond_factor()
		z.upstream_cap_m3h = minf(source_yield, treatment_throughput)
		var rated_total := 0.0
		for node_id in z.pump_ids:
			var node: WaterNode = nodes[node_id]
			if node.is_live():
				rated_total += float(data.component(node.variant, node.level).get("rated_flow_m3h", 0.0))
		for node_id in z.pump_ids:
			var node: WaterNode = nodes[node_id]
			var rated := float(data.component(node.variant, node.level).get("rated_flow_m3h", 0.0))
			node.share_m3h = 0.0 if (rated_total <= 0.0 or not node.is_live()) \
					else z.upstream_cap_m3h * rated / rated_total
		# feed_capacity: live mains touching a supply node's tile. Resolved here
		# and cached on the zone — the per-tick solve only reads the sums.
		var supply_tiles: Dictionary = {}
		z.live_pump_ids.clear()
		z.live_tank_ids.clear()
		for node_id in z.pump_ids:
			var node: WaterNode = nodes[node_id]
			if node.is_live():
				z.live_pump_ids.append(node_id)
				supply_tiles[tile_index(node.tile.x, node.tile.y)] = true
		for node_id in z.tank_ids:
			var node: WaterNode = nodes[node_id]
			if node.is_live():
				z.live_tank_ids.append(node_id)
				supply_tiles[tile_index(node.tile.x, node.tile.y)] = true
		var feed := 0.0
		var rest := 0.0
		z.feed_edge_ids.clear()
		z.feed_edge_set.clear()
		z.broken_edge_ids.clear()
		for edge_id in z.edge_ids:
			var edge: WaterEdge = edges[edge_id]
			if edge.is_broken():
				z.broken_edge_ids.append(edge_id)
			var touches := edge.a in z.pump_ids or edge.a in z.tank_ids \
					or edge.b in z.pump_ids or edge.b in z.tank_ids
			if not touches:
				for tile: Vector2i in edge.path:
					if supply_tiles.has(tile_index(tile.x, tile.y)):
						touches = true
						break
			if touches:
				z.feed_edge_ids.append(edge_id)
				z.feed_edge_set[edge_id] = true
				feed += edge.capacity_m3h
			else:
				rest += edge.capacity_m3h
		z.feed_capacity_m3h = feed
		z.rest_capacity_m3h = rest


## §2.2 multi-source BFS: cost = Chebyshev tile steps from the nearest live
## main tile, cutoff `max_service_distance_tiles`. Ties resolve to the smaller
## zone index, so the result never depends on iteration order.
func _run_tile_bfs(edges: Dictionary, data: WaterData) -> void:
	_reset_tile_caches()
	var cutoff := int(data.global_value("max_service_distance_tiles", 12.0))
	var frontier := PackedInt32Array()
	for edge_id in _sorted(edges):
		var edge: WaterEdge = edges[edge_id]
		if not edge.is_live():
			continue
		var index: int = int(zone_of_edge.get(edge_id, -1))
		if index < 0:
			continue
		for tile: Vector2i in edge.path:
			if not in_bounds(tile.x, tile.y):
				continue
			var flat := tile_index(tile.x, tile.y)
			if tile_distance[flat] < 0:
				tile_distance[flat] = 0
				zone_of_tile[flat] = index
				frontier.append(flat)
			elif index < zone_of_tile[flat]:
				zone_of_tile[flat] = index
	# `claimed` is a scratch PackedInt32Array rather than a Dictionary: the BFS
	# touches ~100k neighbours on a full map and hashing dominated the rebuild.
	# Order does not matter — a tile's owner is the MINIMUM zone index over its
	# claimants, which is commutative, so the result is iteration-independent.
	var claimed := PackedInt32Array()
	claimed.resize(zone_of_tile.size())
	claimed.fill(-1)
	for d in range(1, cutoff + 1):
		var next := PackedInt32Array()
		for flat: int in frontier:
			var x := flat % grid_size
			var z := flat / grid_size
			var owner := zone_of_tile[flat]
			var x_lo := maxi(x - 1, 0)
			var x_hi := mini(x + 1, grid_size - 1)
			var z_lo := maxi(z - 1, 0)
			var z_hi := mini(z + 1, grid_size - 1)
			for nz in range(z_lo, z_hi + 1):
				var row := nz * grid_size
				for nx in range(x_lo, x_hi + 1):
					var n := row + nx
					if tile_distance[n] >= 0:
						continue
					if claimed[n] < 0:
						claimed[n] = owner
						next.append(n)
					elif owner < claimed[n]:
						claimed[n] = owner
		for flat: int in next:
			tile_distance[flat] = d
			zone_of_tile[flat] = claimed[flat]
		frontier = next
		if frontier.is_empty():
			break


func _compute_tile_factors(data: WaterData, terrain: Object) -> void:
	var reach := int(data.global_value("hydrant_reach_tiles", 2.0))
	var falloff := data.global_value("prox_falloff_per_tile", 0.10)
	var elev_penalty := data.global_value("elev_penalty_per_m", 0.015)
	var elev_floor := data.global_value("elev_factor_floor", 0.30)
	var has_terrain := terrain != null and terrain.has_method("elev_m")
	for flat in tile_distance.size():
		var d := tile_distance[flat]
		if d < 0:
			continue
		var prox := 1.0 if d <= reach else clampf(1.0 - falloff * float(d - reach), 0.0, 1.0)
		if prox <= 0.0:
			tile_factor[flat] = 0.0
			continue
		var elev_factor := 1.0
		if has_terrain:
			var z: PressureZone = zones[zone_of_tile[flat]]
			var elevation := float(terrain.call("elev_m", flat % grid_size, flat / grid_size))
			elev_factor = clampf(1.0 - elev_penalty * maxf(0.0, elevation - z.head_m),
					elev_floor, 1.0)
		tile_factor[flat] = prox * elev_factor


func _reset_tile_caches() -> void:
	var count := grid_size * grid_size
	zone_of_tile = PackedInt32Array()
	zone_of_tile.resize(count)
	zone_of_tile.fill(-1)
	tile_distance = PackedInt32Array()
	tile_distance.resize(count)
	tile_distance.fill(-1)
	tile_factor = PackedFloat64Array()
	tile_factor.resize(count)
	tile_factor.fill(0.0)


## §5.8: the overlay's per-tile heat tint, quantized to 0-255.
func quantized_factors() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(tile_factor.size())
	for i in tile_factor.size():
		out[i] = int(roundf(clampf(tile_factor[i], 0.0, 1.0) * 255.0))
	return out


static func _sorted(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
