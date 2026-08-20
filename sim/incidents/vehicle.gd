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
## The tiles this unit drives, in order, `route[0]` = where it left from and
## `route[-1]` = where it is going. Doc 10's router fills it with a STREET
## polyline (`TravelTimeProvider.route_tiles`); with no router, or when the
## router has no path, it is the two endpoints and the motion below degrades to
## the straight line it has always been.
var route: Array = []
var route_progress: float = 0.0
## Which segment of `route` the unit is on (`route[i] → route[i+1]`) and how far
## into it, in metres. Both are DERIVED from `route_progress`, and both are
## persisted anyway — doc 11 §2.12's Hermite blend reads a pose every tick and a
## reload that recomputed them would put the vehicle back at the segment
## boundary for one frame. `serialize()` carries them; `update_motion()` is the
## only writer.
var route_segment: int = 0
var route_s_m: float = 0.0
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

const METRES_PER_TILE := 8.0


## Arc length of `route` in metres, tile centre to tile centre.
func route_length_m() -> float:
	var total := 0.0
	for i in range(1, route.size()):
		var a: Vector2i = route[i - 1]
		var b: Vector2i = route[i]
		total += Vector2(float(b.x - a.x), float(b.y - a.y)).length()
	return total * METRES_PER_TILE


## Place the unit along its route for the current time, segment by segment.
##
## **The reconciliation (doc 10's answer is still the arrival time).** `depart_h`
## and `arrive_at_h` are set once at dispatch from
## `TravelTimeProvider.eta_gs()` — turnout, road classes, congestion, weather and
## closures all already inside it — and this method never touches them. What the
## polyline changes is only WHERE the unit is at each moment in between:
## distance along the route is carried at a CONSTANT fraction of arc length,
##
##     s(t) = route_length_m × (t − depart_h) / (arrive_at_h − depart_h)
##
## so `s(depart_h) = 0`, `s(arrive_at_h) = route_length_m`, and the trip takes
## exactly the number of game-seconds doc 10 quoted whether the route is two
## tiles or two hundred. A longer path through real streets is therefore driven
## FASTER, not for longer — which is the correct reading, because doc 10 priced
## that path and not the diagonal: the straight line was always the wrong
## picture of the same duration, never a different duration.
##
## `speed` is the REALISED metres per game-minute (C-67 — "at the last sim
## update"), i.e. `route_length_m / span_minutes`, not the nominal cruise speed.
## Doc 11 §2.12 dead-reckons `pos + dir(heading) × speed` between the 4 Hz
## snapshots, so a nominal figure would have every unit overshoot its own pose
## and be yanked back on the next tick. `heading` is the bearing of the segment
## the unit is ON, which is the visible point of the whole change: vehicles now
## turn corners.
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
	var length_m := route_length_m()
	speed = length_m / (span * 60.0)
	var target_m := length_m * route_progress
	var walked_m := 0.0
	var index := 0
	# Walk from the head every call: the route is short (a starter-city response
	# is tens of tiles), the arithmetic is exact rather than accumulated, and a
	# resumed save with no cursor lands in the same place as a live tick would.
	while index < route.size() - 1:
		var a: Vector2i = route[index]
		var b: Vector2i = route[index + 1]
		var segment_m := Vector2(float(b.x - a.x), float(b.y - a.y)).length() * METRES_PER_TILE
		if walked_m + segment_m >= target_m or index == route.size() - 2:
			var into := target_m - walked_m
			var fraction := clampf(into / segment_m, 0.0, 1.0) if segment_m > 0.0 else 0.0
			if b != a:
				heading = atan2(float(b.y - a.y), float(b.x - a.x))
			tile = Vector2i(
					int(round(float(a.x) + float(b.x - a.x) * fraction)),
					int(round(float(a.y) + float(b.y - a.y) * fraction)))
			route_segment = index
			route_s_m = clampf(into, 0.0, segment_m)
			return
		walked_m += segment_m
		index += 1
	route_segment = maxi(0, route.size() - 2)
	route_s_m = 0.0


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
		"route_segment": route_segment, "route_s_m": route_s_m,
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
	unit.route_segment = int(data.get("route_segment", 0))
	unit.route_s_m = float(data.get("route_s_m", 0.0))
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
