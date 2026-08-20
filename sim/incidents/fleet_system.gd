class_name FleetSystem
extends RefCounted
## The roster (doc 06 §2.11). Stations house units at doc 06's per-level
## capacity ladders (C-50); the vehicle FSM lives here; arrivals and returns
## are advanced against absolute game-hours so fine and coarse stepping land
## on the same game-minute.
##
## Doc 06 owns HOW MANY units live in a station; doc 02 owns the station shell.

const STATION_ARCHETYPES := [
	"police_station", "fire_station", "substation", "power_facility",
	"water_facility", "construction_yard",
]

var catalog: IncidentCatalog
var travel: TravelTimeProvider
var next_id: int = 1
var now_h: float = 0.0

var _units: Dictionary = {}  # id:int -> Vehicle
var _order: Array = []  # ascending unit ids
var _stations: Dictionary = {}  # station id -> {archetype, level, tile}
var _events: Array = []


func _init(p_catalog: IncidentCatalog, p_travel: TravelTimeProvider = null) -> void:
	catalog = p_catalog
	travel = p_travel if p_travel != null else TravelTimeProvider.new()


# ------------------------------------------------------------------ roster

## stations: [{id, archetype, level, tile}] — doc 02's shells. Units are
## created up to `capacity_per_station_level[level - 1]` per housed type.
func populate_from_stations(stations: Array) -> void:
	var rows := stations.duplicate()
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("id", "")) < String(b.get("id", "")))
	for station in rows:
		var archetype := String(station.get("archetype", ""))
		if not STATION_ARCHETYPES.has(archetype):
			continue
		var station_id := String(station.get("id", ""))
		var level := clampi(int(station.get("level", 1)), 1, 5)
		var tile: Vector2i = station.get("tile", Vector2i.ZERO)
		_stations[station_id] = {"archetype": archetype, "level": level, "tile": tile}
		for type_id in catalog.vehicle_types_for_station(archetype):
			var row: Dictionary = catalog.vehicle_type(type_id)
			var ladder: Array = row.get("capacity_per_station_level", [])
			var capacity := 0 if ladder.size() < level else int(ladder[level - 1])
			for i in capacity:
				_spawn(type_id, station_id, tile)


## ONE station arrived, was upgraded, or changed level — re-house only that
## station (doc 06 §2.11 / C-50). `populate_from_stations` builds the founding
## roster once at boot; this is what keeps the roster true for every station the
## player builds afterwards, so a new `fire_station` is response capacity and not
## just an upkeep line (doc 92 F-3).
##
## An upgrade never destroys a unit the station already houses: only the
## difference between the old and the new capacity rung is commissioned. The
## returned dictionary reports what actually changed, so the caller can stay
## silent when nothing did.
func sync_station(station_id: String, archetype: String, level: int,
		tile: Vector2i) -> Dictionary:
	var out := {"station": station_id, "archetype": archetype, "added": 0,
			"units": [] as Array, "known": _stations.has(station_id)}
	if not STATION_ARCHETYPES.has(archetype):
		return out
	var clamped := clampi(level, 1, 5)
	_stations[station_id] = {"archetype": archetype, "level": clamped, "tile": tile}
	out["level"] = clamped
	# Sorted: `vehicle_types_for_station` walks the catalog's own id order, which
	# is authored and stable, so the ids a station issues never depend on hashing.
	for type_id in catalog.vehicle_types_for_station(archetype):
		var want := capacity_for(archetype, type_id, clamped)
		var have := units_of_type_at(station_id, type_id)
		for _i in maxi(0, want - have):
			var unit := _spawn(type_id, station_id, tile)
			(out["units"] as Array).append(unit.id)
			out["added"] = int(out["added"]) + 1
			_emit("unit_commissioned", {"unit_id": unit.id, "unit_type": type_id,
					"station_id": station_id, "archetype": archetype,
					"station_level": clamped, "tile": [tile.x, tile.y]})
	return out


## The station is gone (doc 02 §2.12 demolition). Its units go with it; an
## incident holding a retired unit simply loses that contribution and the
## dispatcher re-asks (every `fleet.unit()` read on an assigned id is
## null-guarded).
func remove_station(station_id: String) -> Dictionary:
	var removed: Array = []
	for unit_id in _order.duplicate():
		var u: Vehicle = _units[unit_id]
		if u.home_station_id != station_id:
			continue
		removed.append(unit_id)
		remove_unit(unit_id)
		_emit("unit_decommissioned", {"unit_id": unit_id, "unit_type": u.type,
				"station_id": station_id})
	var known := _stations.has(station_id)
	_stations.erase(station_id)
	return {"station": station_id, "removed": removed.size(), "units": removed,
			"known": known}


## How many units of one type this station currently houses (any status).
func units_of_type_at(station_id: String, vehicle_type_id: String) -> int:
	var count := 0
	for unit_id in _order:
		var u: Vehicle = _units[unit_id]
		if u.home_station_id == station_id and u.type == vehicle_type_id:
			count += 1
	return count


func capacity_for(archetype: String, vehicle_type_id: String, level: int) -> int:
	if not catalog.vehicle_types_for_station(archetype).has(vehicle_type_id):
		return 0
	var ladder: Array = catalog.vehicle_type(vehicle_type_id).get("capacity_per_station_level", [])
	var index := clampi(level, 1, ladder.size()) - 1
	return 0 if index < 0 or ladder.is_empty() else int(ladder[index])


func _spawn(type_id: String, station_id: String, tile: Vector2i) -> Vehicle:
	var unit := Vehicle.from_type(next_id, catalog.vehicle_type(type_id), station_id, tile)
	next_id += 1
	_units[unit.id] = unit
	_order.append(unit.id)
	_order.sort()
	return unit


func add_unit(type_id: String, station_id: String, tile: Vector2i) -> Vehicle:
	return _spawn(type_id, station_id, tile)


func remove_unit(unit_id: int) -> void:
	_units.erase(unit_id)
	_order.erase(unit_id)


func unit(unit_id: int) -> Vehicle:
	return _units.get(unit_id, null)


func unit_ids() -> Array:
	return _order.duplicate()


## The same ascending order WITHOUT the defensive copy, for the sweeps inside
## `sim/incidents/` that only iterate — the assignment pass walks the whole
## roster once per unmet role per incident per sub-step, and a fresh Array on
## each of those was the copy nobody read. Read-only; never hold it across a
## roster change (a station being built or demolished).
func unit_ids_ref() -> Array:
	return _order


func size() -> int:
	return _order.size()


func station(station_id: String) -> Dictionary:
	return _stations.get(station_id, {})


func station_ids() -> Array:
	var keys := _stations.keys()
	keys.sort()
	return keys


## Doc 07's Director gate: it must not schedule a disaster when the fleet is
## already exhausted (spec §20.2).
func free_units_by_dept() -> Dictionary:
	var out: Dictionary = {}
	for unit_id in _order:
		var u: Vehicle = _units[unit_id]
		if u.status == Vehicle.IDLE:
			out[u.department] = int(out.get(u.department, 0)) + 1
	return out


func idle_count_at_station(department: String, station_id: String) -> int:
	var count := 0
	for unit_id in _order:
		var u: Vehicle = _units[unit_id]
		if u.department == department and u.home_station_id == station_id \
				and u.status == Vehicle.IDLE:
			count += 1
	return count


## Doc 03's per-hour billing input: doc 06 supplies the roster, never a price.
func roster_for_economy() -> Array:
	var out: Array = []
	for unit_id in _order:
		var u: Vehicle = _units[unit_id]
		out.append({"type": String(catalog.vehicle_type(u.type).get("economy_id", u.type)),
				"dispatched": u.status == Vehicle.RESPONDING or u.status == Vehicle.ON_SCENE,
				"km_this_hour": 0.0})
	return out


# ------------------------------------------------------------------ the FSM

## Travel time in game-hours from a unit's current tile to an incident tile,
## including turnout. Returns INF when doc 10 says no route exists.
func eta_h(u: Vehicle, target: Vector2i) -> float:
	var gs := travel.eta_gs(u.tile, target, u.route_profile(true), u.turnout_min)
	if gs >= TravelTimeProvider.UNREACHABLE_GS:
		return INF
	return float(gs) / 3600.0


## The O(1) RANKING estimate of the same trip (doc 10 §2.14). Never authoritative
## for an arrival — `eta_h` is the only answer to *when* — and used solely to
## decide which candidates are worth a real quote. Identical to `eta_h` on a
## provider with no street network.
func estimate_h(u: Vehicle, target: Vector2i) -> float:
	var gs := travel.estimate_eta_gs(u.tile, target, u.route_profile(true), u.turnout_min)
	if gs >= TravelTimeProvider.UNREACHABLE_GS:
		return INF
	return float(gs) / 3600.0


## The cheap reachability screen, again from doc 10 §2.14. Conservative: it may
## admit a unit whose real quote comes back unreachable, never hide one.
func maybe_reachable(u: Vehicle, target: Vector2i) -> bool:
	return travel.is_reachable_estimate(u.tile, target, u.route_profile(true))


func dispatch(u: Vehicle, incident_id: int, target: Vector2i, role: String,
		manual: bool = false) -> bool:
	var eta := eta_h(u, target)
	if is_inf(eta):
		return false
	if u.status == Vehicle.ON_SCENE and u.incident_id != incident_id:
		return false
	u.status = Vehicle.RESPONDING
	u.incident_id = incident_id
	u.role = role
	u.route = _polyline(u.tile, target, u.route_profile(true))
	u.route_progress = 0.0
	u.route_segment = 0
	u.route_s_m = 0.0
	u.depart_h = now_h
	u.arrive_at_h = now_h + eta
	u.manual_lock = manual
	# One call writes speed, heading and the segment cursor from the route that
	# was just installed, instead of three fields set three different ways.
	u.update_motion(now_h)
	_emit("unit_dispatched", {"unit_id": u.id, "unit_type": u.type,
			"incident_id": incident_id, "role": role, "eta_h": eta, "manual": manual})
	return true


func recall(u: Vehicle) -> void:
	if u.status == Vehicle.IDLE or u.status == Vehicle.OFFLINE:
		return
	_send_home(u)


func release_from_incident(u: Vehicle, refit: bool = false) -> void:
	u.incident_id = 0
	u.role = ""
	u.manual_lock = false
	if refit and u.refit_min > 0:
		u.status = Vehicle.REFIT
		u.refit_until_h = now_h + float(u.refit_min) / 60.0
		u.tile = u.home_tile
		u.route = []
		u.route_progress = 0.0
		u.speed = 0.0
		_emit("unit_returned", {"unit_id": u.id, "refit": true})
		return
	_send_home(u)


func _send_home(u: Vehicle) -> void:
	u.incident_id = 0
	u.role = ""
	u.manual_lock = false
	var gs := travel.eta_gs(u.tile, u.home_tile, u.route_profile(false), 0.0)
	if gs >= TravelTimeProvider.UNREACHABLE_GS:
		gs = 0
	u.status = Vehicle.RETURNING
	u.route = _polyline(u.tile, u.home_tile, u.route_profile(false))
	u.route_progress = 0.0
	u.route_segment = 0
	u.route_s_m = 0.0
	u.depart_h = now_h
	u.arrive_at_h = now_h + float(gs) / 3600.0
	u.update_motion(now_h)


## The tiles a unit drives between two points. Doc 10's router answers with a
## STREET polyline; a provider that has no street network answers `[]` and the
## unit keeps the two-point route doc 06 has always used, so this is the one
## place the two eras differ.
##
## Two guards, both of them about not trusting a foreign answer with the unit's
## position: a polyline that does not START where the unit is standing or does
## not END on the target would teleport it, so it is rejected. (The router snaps
## both endpoints to the nearest road tile — a station set back from the kerb is
## the normal case, not an error — and doc 06 owns the two tiles that matter.)
func _polyline(from: Vector2i, to: Vector2i, profile: Dictionary) -> Array:
	var tiles: Array = travel.route_tiles(from, to, profile)
	if tiles.size() < 2:
		return [from, to]
	var out: Array = tiles.duplicate()
	if out[0] != from:
		out.insert(0, from)
	if out[out.size() - 1] != to:
		out.append(to)
	return out


## Next FSM discontinuity in absolute game-hours, or INF.
func next_event_h() -> float:
	var best := INF
	for unit_id in _order:
		var u: Vehicle = _units[unit_id]
		match u.status:
			Vehicle.RESPONDING, Vehicle.RETURNING:
				if u.arrive_at_h > now_h:
					best = minf(best, u.arrive_at_h)
			Vehicle.REFIT:
				if u.refit_until_h > now_h:
					best = minf(best, u.refit_until_h)
	return best


## Advance to an absolute game-hour. Returns the ids of units that just
## arrived on scene, ascending — the incident engine turns those into
## ASSIGNED → ACTIVE transitions.
func advance_to(t_h: float) -> Array:
	now_h = t_h
	var arrived: Array = []
	for unit_id in _order:
		var u: Vehicle = _units[unit_id]
		match u.status:
			Vehicle.RESPONDING:
				if u.arrive_at_h >= 0.0 and now_h + 1e-12 >= u.arrive_at_h:
					u.status = Vehicle.ON_SCENE
					u.tile = u.route[u.route.size() - 1] if not u.route.is_empty() else u.tile
					u.route_progress = 1.0
					u.speed = 0.0
					arrived.append(unit_id)
					_emit("unit_arrived", {"unit_id": unit_id, "incident_id": u.incident_id,
							"role": u.role})
				else:
					u.update_motion(now_h)
			Vehicle.RETURNING:
				if u.arrive_at_h >= 0.0 and now_h + 1e-12 >= u.arrive_at_h:
					u.tile = u.home_tile
					u.route = []
					u.route_progress = 0.0
					u.speed = 0.0
					if u.refit_min > 0 and u.refit_until_h > now_h:
						u.status = Vehicle.REFIT
					else:
						u.status = Vehicle.IDLE
					_emit("unit_returned", {"unit_id": unit_id, "refit": false})
				else:
					u.update_motion(now_h)
			Vehicle.REFIT:
				if u.refit_until_h >= 0.0 and now_h + 1e-12 >= u.refit_until_h:
					u.status = Vehicle.IDLE
					u.refit_until_h = -1.0
			_:
				u.speed = 0.0
	return arrived


## Doc 11's per-tick vehicle_state snapshot (C-67).
func vehicle_states() -> Array:
	var out: Array = []
	for unit_id in _order:
		out.append((_units[unit_id] as Vehicle).snapshot())
	return out


func drain_events() -> Array:
	var out := _events
	_events = []
	return out


func _emit(event_type: String, payload: Dictionary) -> void:
	var event := payload.duplicate()
	event["type"] = event_type
	_events.append(event)


# ------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	var units: Array = []
	for unit_id in _order:
		units.append((_units[unit_id] as Vehicle).serialize())
	var stations: Array = []
	for station_id in station_ids():
		var s: Dictionary = _stations[station_id]
		stations.append({"id": station_id, "archetype": s["archetype"],
				"level": s["level"], "tile": [(s["tile"] as Vector2i).x, (s["tile"] as Vector2i).y]})
	return {"section_version": 1, "next_id": next_id, "now_h": now_h,
			"units": units, "stations": stations}


func deserialize(data: Dictionary) -> void:
	_units.clear()
	_order.clear()
	_stations.clear()
	for row in data.get("stations", []):
		var tile: Array = row.get("tile", [0, 0])
		_stations[String(row["id"])] = {"archetype": String(row.get("archetype", "")),
				"level": int(row.get("level", 1)),
				"tile": Vector2i(int(tile[0]), int(tile[1]))}
	for row in data.get("units", []):
		var unit := Vehicle.deserialize(row, catalog.vehicle_type(String(row.get("type", ""))))
		_units[unit.id] = unit
		_order.append(unit.id)
	_order.sort()
	next_id = int(data.get("next_id", 1))
	now_h = float(data.get("now_h", 0.0))
