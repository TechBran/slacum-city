class_name WaterEdge
extends RefCounted
## One main (doc 05 §2.1). Mains occupy tiles (constitution §6), carry a tier
## capacity, and are the only thing that seeds a pressure zone's tile BFS.
##
## Doc 06 owns the `water_main_break` roll and the incident behind it (C-46);
## `owning_incident` records which incident holds this segment, and
## `incident_pressure_penalty` is the MAGNITUDE of doc 06's tiered
## −0.15/−0.35/−0.60/−0.80 delta, held until the incident resolves. With no
## owning incident the flat `break_pressure_penalty_fallback` applies instead.
##
## The penalty is stored as a magnitude (§2.8 consumes `|delta|` anyway) so no
## negative float ever enters the save section — see the note in `WaterSystem`
## about `CitySim._encode_floats`.

const TIERS := [&"service", &"trunk", &"arterial"]
const METRES_PER_TILE := 8.0  # doc 09: a land block is 16 tiles = 128 m

var id: String = ""
var a: String = ""  # node id
var b: String = ""  # node id
var path: Array = []  # Array[Vector2i], every tile the main passes through
var tier: String = "service"
## Doc 05 §2.1's edge field, resolved from the tier table on every topology
## change so the per-tick solve never re-reads `data/water.json`.
var capacity_m3h: float = 0.0
var condition: float = 1.0
var state: StringName = &"ok"  # ok | broken | isolated
var severity: float = 0.0
var frozen: bool = false
var freeze_stress: float = 0.0
var insulation: int = 0
var broken_at_minutes: float = 0.0
var owning_incident: String = ""
var incident_pressure_penalty: float = 0.0
var flow_m3h: float = 0.0


static func make(edge_id: String, node_a: String, node_b: String, tiles: Array,
		opts: Dictionary = {}) -> WaterEdge:
	var edge := WaterEdge.new()
	edge.id = edge_id
	edge.a = node_a
	edge.b = node_b
	edge.path = tiles.duplicate()
	edge.tier = String(opts.get("tier", "service"))
	edge.condition = float(opts.get("condition", 1.0))
	edge.insulation = int(opts.get("insulation", 0))
	return edge


## A BROKEN main still conducts (and leaks); only an ISOLATED one leaves the
## live graph. See the reading note at the top of `WaterSystem` — doc 05 §2.14
## example C runs a broken trunk that keeps its zone alive, and `isolate_main`
## exists precisely because breaking alone does not strand the branch.
func is_live() -> bool:
	return state != &"isolated"


func is_broken() -> bool:
	return state == &"broken"


func length_km() -> float:
	return float(maxi(path.size() - 1, 0)) * METRES_PER_TILE / 1000.0


func serialize() -> Dictionary:
	var tiles: Array = []
	for tile: Vector2i in path:
		tiles.append([tile.x, tile.y])
	return {
		"id": id, "a": a, "b": b, "path": tiles, "tier": tier,
		"condition": condition, "state": String(state), "severity": severity,
		"frozen": frozen, "freeze_stress": freeze_stress, "insulation": insulation,
		"broken_at_minutes": broken_at_minutes, "owning_incident": owning_incident,
		"incident_pressure_penalty": incident_pressure_penalty,
	}


static func deserialize(record: Dictionary) -> WaterEdge:
	var edge := WaterEdge.new()
	edge.id = String(record.get("id", ""))
	edge.a = String(record.get("a", ""))
	edge.b = String(record.get("b", ""))
	edge.path = []
	for pair in record.get("path", []):
		edge.path.append(Vector2i(int(pair[0]), int(pair[1])))
	edge.tier = String(record.get("tier", "service"))
	edge.condition = float(record.get("condition", 1.0))
	edge.state = StringName(String(record.get("state", "ok")))
	edge.severity = float(record.get("severity", 0.0))
	edge.frozen = bool(record.get("frozen", false))
	edge.freeze_stress = float(record.get("freeze_stress", 0.0))
	edge.insulation = int(record.get("insulation", 0))
	edge.broken_at_minutes = float(record.get("broken_at_minutes", 0.0))
	edge.owning_incident = String(record.get("owning_incident", ""))
	edge.incident_pressure_penalty = float(record.get("incident_pressure_penalty", 0.0))
	return edge


## Every tile a polyline passes through, in the order it passes through them.
## Axis-aligned or 45° segments only (mains follow the road grid).
static func polyline_tiles(polyline: Array) -> Array:
	var tiles: Array = []
	for i in range(1, polyline.size()):
		var from := _as_tile(polyline[i - 1])
		var to := _as_tile(polyline[i])
		var step := Vector2i(signi(to.x - from.x), signi(to.y - from.y))
		var cursor := from
		var guard := 0
		while cursor != to and guard < 4096:
			tiles.append(cursor)
			cursor += step
			guard += 1
	if not polyline.is_empty():
		tiles.append(_as_tile(polyline[-1]))
	return tiles


static func _as_tile(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	var pair: Array = value
	return Vector2i(int(pair[0]), int(pair[1]))
