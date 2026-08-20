class_name WaterServiceLedger
extends RefCounted
## Doc 05 §5.4 (report 98 C-37). Doc 03's `f_water` needs the FRACTION of the
## settled hour a building actually had usable water; a boolean or an
## instantaneous pressure erases most of the cascade signal.
##
##   w_accum_h += clamp(P_tile(access_tile) / NOMINAL_PRESSURE, 0, 1) * dt_h
##   elapsed_h += dt_h
##   water_service_factor_hour = w_accum_h / max(elapsed_h, 1e-6)
##
## The accumulator uses the same `dt_h` at 1/240 and at 1.0, so offline
## catch-up produces the identical figure a live hour would, and it is
## persisted mid-hour so a save inside an hour can neither inflate nor erase a
## building's revenue.

const EPSILON := 1e-6

var nominal_pressure: float = 0.60

var _accum: Dictionary = {}  # building id -> {w_accum_h, elapsed_h, served_m3, demanded_m3}
var _settled: Dictionary = {}  # building id -> {pressure_factor, delivered_fraction}


func _init(p_nominal_pressure: float = 0.60) -> void:
	nominal_pressure = p_nominal_pressure


func track(building_id: String) -> void:
	if not _accum.has(building_id):
		_accum[building_id] = {"w_accum_h": 0.0, "elapsed_h": 0.0,
				"served_m3": 0.0, "demanded_m3": 0.0}


func forget(building_id: String) -> void:
	_accum.erase(building_id)
	_settled.erase(building_id)


## One tick's contribution. `delivered_ratio` is the zone's delivered/demand.
## The whole roster comes through here on every SimTick, so the row is fetched
## ONCE — `track()` + `_accum[id]` was a `has` and two more lookups for the same
## row. Same row, same fields, created on first sight exactly as before.
func accumulate(building_id: String, p_tile: float, demand_m3h: float,
		delivered_ratio: float, dt_h: float) -> void:
	var found: Variant = _accum.get(building_id)
	if found == null:
		found = {"w_accum_h": 0.0, "elapsed_h": 0.0, "served_m3": 0.0, "demanded_m3": 0.0}
		_accum[building_id] = found
	var record: Dictionary = found
	record["w_accum_h"] = float(record["w_accum_h"]) \
			+ clampf(p_tile / maxf(nominal_pressure, EPSILON), 0.0, 1.0) * dt_h
	record["elapsed_h"] = float(record["elapsed_h"]) + dt_h
	record["demanded_m3"] = float(record["demanded_m3"]) + demand_m3h * dt_h
	record["served_m3"] = float(record["served_m3"]) \
			+ demand_m3h * clampf(delivered_ratio, 0.0, 1.0) * dt_h


## Game-hour boundary, BEFORE doc 03's `tick_hour()` runs in the same hour
## (doc 01 phase order P07 WATER → P14 ECONOMY).
func settle_hour() -> Dictionary:
	var out: Dictionary = {}
	for building_id in _sorted(_accum):
		var record: Dictionary = _accum[building_id]
		# **An hour with no elapsed time has nothing to settle** (Wave 9). The
		# founding tick fires the EVERY_HOUR cadence before a single game-second
		# has been integrated, and `w_accum_h / max(elapsed_h, EPSILON)` turned
		# that into a settled pressure factor of **0.0** — a whole founding hour
		# billed as if the city had no water at all. It was invisible while the
		# ledger accumulated on every SimTick, because the tick-0 pass had
		# already banked 15 game-seconds of real pressure by the time the hourly
		# system ran; the moment the ledger moved to a game-minute cadence (doc
		# 91 D-15 proposal 3) the founding hour banked nothing and the defect
		# cost the starter city $436 of its first hour. Skipping the row leaves
		# the documented default in place — 1.0 for a building that has not
		# settled an hour yet — which is what this class's own header promises.
		if float(record["elapsed_h"]) <= EPSILON:
			continue
		var elapsed := maxf(float(record["elapsed_h"]), EPSILON)
		var pressure_factor := clampf(float(record["w_accum_h"]) / elapsed, 0.0, 1.0)
		var demanded := float(record["demanded_m3"])
		var delivered_fraction := 1.0 if demanded <= 0.0 \
				else clampf(float(record["served_m3"]) / demanded, 0.0, 1.0)
		_settled[building_id] = {"pressure_factor": pressure_factor,
				"delivered_fraction": delivered_fraction}
		out[building_id] = pressure_factor
		record["w_accum_h"] = 0.0
		record["elapsed_h"] = 0.0
		record["served_m3"] = 0.0
		record["demanded_m3"] = 0.0
	return out


## Doc 03's `w_b`. Defaults to 1.0 for a building that has not settled an hour
## yet — a city that just booted bills a full water term, not a zero one.
func service_factor_hour(building_id: String) -> float:
	return float(_settled.get(building_id, {}).get("pressure_factor", 1.0))


## The volumetric sibling — doc 03's water tariff and the WHILE YOU WERE AWAY
## report read this; only the pressure figure feeds `f_water`.
func delivered_fraction_hour(building_id: String) -> float:
	return float(_settled.get(building_id, {}).get("delivered_fraction", 1.0))


## Mid-hour partial, for UI and for the in-flight value during a coarse step.
func partial_factor(building_id: String) -> float:
	var record: Dictionary = _accum.get(building_id, {})
	if record.is_empty() or float(record["elapsed_h"]) <= 0.0:
		return service_factor_hour(building_id)
	return clampf(float(record["w_accum_h"]) / float(record["elapsed_h"]), 0.0, 1.0)


func all_service_factors() -> Dictionary:
	var out: Dictionary = {}
	for building_id in _sorted(_settled):
		out[building_id] = float(_settled[building_id]["pressure_factor"])
	return out


func serialize() -> Dictionary:
	var accum: Dictionary = {}
	for building_id in _sorted(_accum):
		accum[building_id] = (_accum[building_id] as Dictionary).duplicate()
	var settled: Dictionary = {}
	for building_id in _sorted(_settled):
		settled[building_id] = (_settled[building_id] as Dictionary).duplicate()
	return {"service_accum": accum, "settled": settled}


func deserialize(state: Dictionary) -> void:
	_accum.clear()
	_settled.clear()
	for building_id in _sorted(state.get("service_accum", {})):
		var record: Dictionary = state["service_accum"][building_id]
		_accum[String(building_id)] = {
			"w_accum_h": float(record.get("w_accum_h", 0.0)),
			"elapsed_h": float(record.get("elapsed_h", 0.0)),
			"served_m3": float(record.get("served_m3", 0.0)),
			"demanded_m3": float(record.get("demanded_m3", 0.0)),
		}
	for building_id in _sorted(state.get("settled", {})):
		var record: Dictionary = state["settled"][building_id]
		_settled[String(building_id)] = {
			"pressure_factor": float(record.get("pressure_factor", 1.0)),
			"delivered_fraction": float(record.get("delivered_fraction", 1.0)),
		}


static func _sorted(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
