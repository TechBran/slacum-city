class_name Vehicle
extends RefCounted
## One dispatchable unit (doc 06 §2.11). Construction crews are units too
## (G-2) — the roster is doc 06's, the build-job record stays doc 02's.
##
## `speed` and `heading` are FIRST-CLASS persisted fields, not derived (C-67):
## doc 11's Hermite interpolation needs both to place a vehicle between two
## sim positions, and reconstructing them from consecutive positions doubles
## visible latency.

const IDLE := "IDLE"
const RESPONDING := "RESPONDING"
const ON_SCENE := "ON_SCENE"
const RETURNING := "RETURNING"
const REFIT := "REFIT"
const OFFLINE := "OFFLINE"

var id: int = 0
var type: String = ""
var department: String = ""
var home_station_id: String = ""
var home_tile := Vector2i.ZERO
var tile := Vector2i.ZERO
## Metres per game-minute at the last sim update — REQUIRED by doc 11 (C-67).
var speed: float = 0.0
## Radians in the XZ plane, 0 = +X — REQUIRED by doc 11 (C-67).
var heading: float = 0.0
var status: String = IDLE
var incident_id: int = 0
var route: Array = []  # [Vector2i, …] — two nodes until doc 10's polyline lands
var route_progress: float = 0.0
var depart_h: float = 0.0
var arrive_at_h: float = -1.0
var manual_lock: bool = false
var refit_until_h: float = -1.0
var construction_job_id: int = 0
## The role this unit is answering with on its current incident.
var role: String = ""

## Static rows from data/vehicles.json, injected on construction.
var speed_mpgm: float = 24.0
var siren_mult: float = 1.0
var turnout_min: float = 0.0
var refit_min: int = 0
var suppression: float = 0.0
var capabilities: Array = []
var resolve_rate: Dictionary = {}


static func from_type(p_id: int, row: Dictionary, station_id: String,
		station_tile: Vector2i) -> Vehicle:
	var unit := Vehicle.new()
	unit.id = p_id
	unit.type = String(row.get("type_id", ""))
	unit.department = String(row.get("department", ""))
	unit.home_station_id = station_id
	unit.home_tile = station_tile
	unit.tile = station_tile
	unit.speed_mpgm = float(row.get("speed_mpgm", 24.0))
	unit.siren_mult = float(row.get("siren_mult", 1.0))
	unit.turnout_min = float(row.get("turnout_min", 0.0))
	unit.refit_min = int(row.get("refit_min", 0))
	unit.suppression = float(row.get("suppression", 0.0))
	unit.capabilities = (row.get("capabilities", []) as Array).duplicate()
	unit.resolve_rate = (row.get("resolve_rate", {}) as Dictionary).duplicate()
	return unit


## Doc 06 §2.10's RouteProfile — exactly four fields (C-49). No weather_mult
## and no flood_mult: weather reaches travel time once, inside doc 10.
func route_profile(siren: bool = true) -> Dictionary:
	return {
		"speed_mpgm": speed_mpgm,
		"siren": siren,
		"ignores_closures": false,
		"capabilities": capabilities.duplicate(),
		"siren_mult": siren_mult,
	}


func has_capability_for(role_name: String) -> bool:
	return float(resolve_rate.get(role_name, 0.0)) > 0.0


func rate_for(role_name: String) -> float:
	return float(resolve_rate.get(role_name, 0.0))


## §2.11: role_fit is the resolve rate normalised to this unit's own primary,
## so a construction crew answering a downed line scores a fit penalty and
## contributes only 0.25 — usable in desperation, never preferred.
func role_fit(role_name: String) -> float:
	var best := 0.0
	for key in resolve_rate:
		best = maxf(best, float(resolve_rate[key]))
	if best <= 0.0:
		return 0.0
	return clampf(rate_for(role_name) / best, 0.0, 1.0)


func is_available() -> bool:
	return status == IDLE or status == RETURNING or status == RESPONDING


func is_dispatchable_now() -> bool:
	return status != REFIT and status != OFFLINE


func effective_speed() -> float:
	return speed_mpgm * (siren_mult if status == RESPONDING else 1.0)


# ------------------------------------------------------------- movement

## Place the unit along its route for the current time. Straight-line between
## the two route nodes until doc 10 hands over a real polyline; `speed` and
## `heading` are written every call so doc 11 never has to guess (C-67).
func update_motion(now_h: float) -> void:
	if status != RESPONDING and status != RETURNING:
		speed = 0.0
		route_progress = 0.0 if route.is_empty() else route_progress
		return
	if route.size() < 2 or arrive_at_h <= depart_h:
		route_progress = 1.0
		speed = 0.0
		return
	var span := arrive_at_h - depart_h
	route_progress = clampf((now_h - depart_h) / span, 0.0, 1.0)
	var from: Vector2i = route[0]
	var to: Vector2i = route[route.size() - 1]
	var delta := Vector2(float(to.x - from.x), float(to.y - from.y))
	if delta.length_squared() > 0.0:
		heading = atan2(delta.y, delta.x)
	speed = effective_speed()
	tile = Vector2i(
			int(round(float(from.x) + delta.x * route_progress)),
			int(round(float(from.y) + delta.y * route_progress)))


## Doc 11's per-tick snapshot record (§4). `speed` and `heading` are explicit.
func snapshot() -> Dictionary:
	return {
		"id": id, "type": type, "pos": [tile.x, tile.y],
		"speed": speed, "heading": heading, "status": status,
		"incident_id": incident_id, "route_progress": route_progress,
	}


# ------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	var route_rows: Array = []
	for node in route:
		route_rows.append([(node as Vector2i).x, (node as Vector2i).y])
	return {
		"id": id, "type": type, "department": department,
		"home_station_id": home_station_id,
		"home_tile": [home_tile.x, home_tile.y], "pos": [tile.x, tile.y],
		"speed": speed, "heading": heading, "status": status,
		"incident_id": incident_id, "route": route_rows,
		"route_progress": route_progress, "depart_h": depart_h,
		"arrive_at_h": arrive_at_h, "manual_lock": manual_lock,
		"refit_until_h": refit_until_h, "construction_job_id": construction_job_id,
		"role": role,
	}


static func deserialize(data: Dictionary, row: Dictionary) -> Vehicle:
	var unit := Vehicle.new()
	unit.id = int(data.get("id", 0))
	unit.type = String(data.get("type", ""))
	unit.department = String(data.get("department", ""))
	unit.home_station_id = String(data.get("home_station_id", ""))
	var home: Array = data.get("home_tile", [0, 0])
	unit.home_tile = Vector2i(int(home[0]), int(home[1]))
	var pos: Array = data.get("pos", [0, 0])
	unit.tile = Vector2i(int(pos[0]), int(pos[1]))
	unit.speed = float(data.get("speed", 0.0))
	unit.heading = float(data.get("heading", 0.0))
	unit.status = String(data.get("status", IDLE))
	unit.incident_id = int(data.get("incident_id", 0))
	unit.route.clear()
	for node in data.get("route", []):
		unit.route.append(Vector2i(int(node[0]), int(node[1])))
	unit.route_progress = float(data.get("route_progress", 0.0))
	unit.depart_h = float(data.get("depart_h", 0.0))
	unit.arrive_at_h = float(data.get("arrive_at_h", -1.0))
	unit.manual_lock = bool(data.get("manual_lock", false))
	unit.refit_until_h = float(data.get("refit_until_h", -1.0))
	unit.construction_job_id = int(data.get("construction_job_id", 0))
	unit.role = String(data.get("role", ""))
	unit.speed_mpgm = float(row.get("speed_mpgm", 24.0))
	unit.siren_mult = float(row.get("siren_mult", 1.0))
	unit.turnout_min = float(row.get("turnout_min", 0.0))
	unit.refit_min = int(row.get("refit_min", 0))
	unit.suppression = float(row.get("suppression", 0.0))
	unit.capabilities = (row.get("capabilities", []) as Array).duplicate()
	unit.resolve_rate = (row.get("resolve_rate", {}) as Dictionary).duplicate()
	return unit
