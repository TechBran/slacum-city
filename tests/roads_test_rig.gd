class_name RoadsTestRig
extends RefCounted
## Shared fixtures for the doc 10 test files. Not a test suite itself (the
## runner only picks up `test_*.gd`).

const AVENUE := RoadTunables.CLASS_AVENUE
const STREET := RoadTunables.CLASS_STREET


## Command results follow the project convention `CommandQueue.ok/fail`:
## {ok, reason_code, payload}. These two keep the tests readable.
static func payload(result: Dictionary) -> Dictionary:
	return result.get("payload", {})


static func reason(result: Dictionary) -> StringName:
	return StringName(String(result.get("reason_code", "")))


static func tunables() -> RoadTunables:
	return RoadTunables.from_file("res://data/roads.json")


## `tiles` maps Vector2i -> road class id.
static func grid_with(tiles: Dictionary) -> TileGrid:
	var grid := TileGrid.new()
	for t in tiles:
		var tile: Vector2i = t
		grid.set_road(tile.x, tile.y, int(tiles[t]))
	return grid


static func network_with(tiles: Dictionary, seed_value: int = 1337) -> RoadNetwork:
	var tun := tunables()
	var net := RoadNetwork.new(grid_with(tiles), tun, RngStreams.new(seed_value))
	net.bootstrap()
	return net


static func line(from_tile: Vector2i, to_tile: Vector2i, road_class: int) -> Dictionary:
	var out: Dictionary = {}
	var step := Vector2i(signi(to_tile.x - from_tile.x), signi(to_tile.y - from_tile.y))
	var cursor := from_tile
	out[cursor] = road_class
	while cursor != to_tile:
		cursor += step
		out[cursor] = road_class
	return out


static func merge(into: Dictionary, extra: Dictionary, overwrite: bool = true) -> Dictionary:
	for key in extra:
		if overwrite or not into.has(key):
			into[key] = extra[key]
	return into


## The doc 09 starter city, stamped exactly as `data/starter_city.json` authors it.
static func starter_network(seed_value: int = 1337) -> RoadNetwork:
	var loader := StarterCityLoader.new()
	loader.load_from(StarterCityLoader.read_json("res://data/starter_city.json"))
	var net := RoadNetwork.new(loader.world.grid, tunables(), RngStreams.new(seed_value))
	net.bootstrap()
	return net


## A frozen TimeContext. `hour` is the curve sample position doc 01 hands down.
static func context(tick_index: int, hour: float, mode: int = TimeContext.Mode.FINE) -> TimeContext:
	var ctx := TimeContext.new()
	ctx.tick_index = tick_index
	ctx.game_seconds = tick_index * GameClock.GAME_SECONDS_PER_TICK
	ctx.mode = mode
	ctx.dt_game_seconds = 15 if mode == TimeContext.Mode.FINE else 3600
	ctx.hour_midpoint = hour
	ctx.hour_of_day = int(hour) % 24
	ctx.minute_of_day = int(hour * 60.0) % 1440
	ctx.day_index = tick_index / GameClock.TICKS_PER_DAY
	ctx.channels = {"construction_rate": 0.804}
	ctx.channels_hour = {"construction_rate": 0.804}
	return ctx


## The §2.6 worked-example-C geometry, laid out so both route endpoints are
## dead-end nodes (which contribute no delay) and the two interior nodes are the
## signalised ones the example prices.
##   E_a  avenue 480 m  ·  N1 signalised+powered  ·  E_b street 240 m
##   N2 signalised+DARK ·  E_c street 160 m
## Every tile is stamped STREET and E_a's CLASS is overridden to AVENUE
## afterwards. Stamping the avenue into the grid instead would put a class
## TRANSITION one tile past N1, and §2.4's predicate makes BOTH flanking tiles
## nodes — splitting E_b into a 2-tile bridge plus a 232 m remainder and adding
## a third node delay the worked example does not price. See REPORT finding D-1.
static func worked_example_c() -> Dictionary:
	var tiles: Dictionary = {}
	merge(tiles, line(Vector2i(0, 20), Vector2i(60, 20), STREET))
	merge(tiles, line(Vector2i(60, 20), Vector2i(60, 50), STREET), false)
	merge(tiles, line(Vector2i(60, 50), Vector2i(80, 50), STREET), false)
	# Stubs that raise N1 and N2 to degree 4 so both are signalised.
	tiles[Vector2i(60, 19)] = STREET
	tiles[Vector2i(61, 20)] = STREET
	tiles[Vector2i(59, 50)] = STREET
	tiles[Vector2i(60, 51)] = STREET
	var net := network_with(tiles)
	var n1 := net.graph.node_at(Vector2i(60, 20))
	var n2 := net.graph.node_at(Vector2i(60, 50))
	var e_a := _edge_between(net, Vector2i(0, 20), n1)
	var e_b := _edge_between(net, Vector2i(60, 35), n1)
	var e_c := _edge_between(net, Vector2i(70, 50), n2)
	net.graph.edge(e_a)["road_class"] = AVENUE
	net.graph._refresh_node_meta([n1])
	return {"net": net, "n1": n1, "n2": n2, "e_a": e_a, "e_b": e_b, "e_c": e_c,
			"start": Vector2i(0, 20), "goal": Vector2i(80, 50)}


static func _edge_between(net: RoadNetwork, tile: Vector2i, node_id: int) -> int:
	for edge_id in net.graph.edges_at(tile):
		var record: Dictionary = net.graph.edge(edge_id)
		if int(record["node_a"]) == node_id or int(record["node_b"]) == node_id:
			return edge_id
	var list := net.graph.edges_at(tile)
	return int(list[0]) if not list.is_empty() else -1


## Force an edge's derived state to exact doc values (worked examples are
## authored per-EDGE; per-tile means cannot hit them when tiles are shared).
static func force_edge(net: RoadNetwork, edge_id: int, condition: float,
		congestion_value: float) -> void:
	var record: Dictionary = net.graph.edge(edge_id)
	record["condition"] = condition
	record["collapsed"] = false
	record["congestion"] = congestion_value
