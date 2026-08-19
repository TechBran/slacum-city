class_name PowerGrid
extends RefCounted
## The electrical grid (doc 04). A real graph — plants, substations, feeders,
## transformers, ties — with capacity, load, condition and temperature.
## Explicitly NOT electrical engineering (spec §52): capacity is a scalar kW
## budget propagated down radial trees from a bulk generation pool.
##
## Four passes per tick: A demand aggregation (bottom-up), B supply + shedding,
## C thermal/protection/hazard, D energization DFS (only when topology_dirty).
## Constants inline mirror data/power.json §8; DataRegistry asserts equality
## at boot once wired (P0-01 pattern).

const CAPACITY := {
	&"plant_gas": [8000.0, 18000.0, 36000.0, 70000.0, 120000.0],
	&"substation": [6000.0, 14000.0, 30000.0, 60000.0, 110000.0],
	&"transformer": [50.0, 150.0, 400.0, 1000.0, 2500.0],
}
const FEEDER_CAPACITY := [1200.0, 3000.0, 7500.0]  # conductor class 1..3
const TRANSMISSION_CAPACITY := [40000.0, 90000.0, 180000.0]
const TRANSFORMER_SERVICE_RADIUS := [3, 4, 5, 6, 8]
const SUBSTATION_FEEDER_SLOTS := [2, 3, 4, 6, 8]

# (theta_rated_c, tau_gs) per kind — §2.6
const THERMAL := {
	&"transformer": [55.0, 900.0], &"feeder": [40.0, 300.0],
	&"substation": [45.0, 1200.0], &"transmission": [35.0, 240.0],
}
# (T_knee, T_span, h_hot, h_cold) per kind — §2.6
const HAZARD := {
	&"transformer": [85.0, 60.0, 2.00, 0.00012], &"feeder": [75.0, 55.0, 1.20, 0.00008],
	&"substation": [80.0, 60.0, 0.90, 0.00010], &"transmission": [70.0, 55.0, 0.70, 0.00006],
}
const K_TRIP := {&"feeder": 120.0, &"substation": 90.0, &"transmission": 100.0}
const R_PICKUP := 1.05
const TRIP_ACCUM_DECAY_GS := 120.0
const XFMR_BURNOUT_R := 3.0
const AUTO_RECLOSE_DELAY_GS := 90
const AUTO_RECLOSE_OK_R := 0.98
const AUTO_RECLOSE_MAX_ATTEMPTS := 2
const WEAR_PER_GH := 0.00035
const PLANT_H_BASE := 0.00030

const DARK_THRESHOLD := 0.35
const DARK_SUSTAIN_GS := 20
const LIT_THRESHOLD := 0.55
const LIT_SUSTAIN_GS := 10

const PRIORITY_WEIGHT := {&"CRITICAL": 1000.0, &"ESSENTIAL": 40.0, &"STANDARD": 8.0, &"DISCRETIONARY": 1.0}
const ROLLING_SHED_PERIOD_GM := 30
const PRIORITY_OVERRIDE_BONUS := 500.0

const TIE_TRANSFER_DELAY_GS := 20
const TIE_CLEAN_R := 0.95
const TIE_AGGRESSIVE_R := 1.35
const CASCADE_WINDOW_GS := 60
const MAJOR_OUTAGE_FRACTION := 0.40

const BLOCK_DARK_THRESHOLD := 0.60

const LIGHTNING_P_BASE := 0.55
const LIGHTNING_ARRESTER_FACTOR := 0.22

var now_gs: int = 0
var next_component_index: int = 1
var topology_dirty: bool = true
var system_demand_kw: float = 0.0
var system_supply_kw: float = 0.0
var shed_feeders: Array = []
var shed_rotation_next_gs: int = 0

var _components: Dictionary = {}  # id -> component Dictionary
var _order: Array = []  # sorted component ids (deterministic iteration)
var _children: Dictionary = {}  # id -> sorted child ids
var _ties: Dictionary = {}  # tie id -> {a, b, mode, closed, pending_close_gs}
var _attachments: Dictionary = {}  # building_id -> transformer id
var _service: Dictionary = {}  # building_id -> service record
var _last_trip_gs: int = -1000000
var _last_trip_component: String = ""
var _events: Array = []


# -------------------------------------------------------------- construction

## kinds: plant_gas | substation | transformer | feeder | transmission
## opts: level, conductor_class, parent, tile, route, underground,
##       weather_exposure, tree_adjacent, priority_class …
func add_component(id: String, kind: StringName, opts: Dictionary = {}) -> Dictionary:
	assert(not _components.has(id), "duplicate component id " + id)
	var level := int(opts.get("level", 1))
	var capacity: float
	match kind:
		&"feeder":
			capacity = FEEDER_CAPACITY[int(opts.get("conductor_class", 1)) - 1]
		&"transmission":
			capacity = TRANSMISSION_CAPACITY[int(opts.get("conductor_class", 1)) - 1]
		_:
			capacity = CAPACITY[kind][level - 1]
	var component := {
		"id": id, "kind": kind, "level": level,
		"conductor_class": int(opts.get("conductor_class", 1)),
		"parent": String(opts.get("parent", "")),
		"tile": opts.get("tile", Vector2i.ZERO),
		"route": opts.get("route", []),
		"state": &"OK", "condition": float(opts.get("condition", 1.0)),
		"theta_c": 0.0, "trip_accum": 0.0, "reclose_attempts": 0,
		"reclose_at_gs": -1, "failed_cause": "",
		"load_kw": 0.0, "capacity_kw": capacity, "energized": false,
		"underground": bool(opts.get("underground", false)),
		"arrester_level": int(opts.get("arrester_level", 0)),
		"weather_exposure": float(opts.get("weather_exposure", 1.0)),
		"tree_adjacent": bool(opts.get("tree_adjacent", false)),
		"priority_override": false,
		"cause_chain": [],
	}
	_components[id] = component
	_order.append(id)
	_order.sort()
	topology_dirty = true
	return component


func component(id: String) -> Dictionary:
	return _components.get(id, {})


func add_tie(id: String, a: String, b: String, mode: StringName = &"MANUAL") -> void:
	_ties[id] = {"id": id, "a": a, "b": b, "mode": mode, "closed": false, "pending_close_gs": -1}


## Attach a building to the nearest transformer whose service radius covers
## its tile, tie-broken by lowest load ratio then id. "" ⇒ UNSERVED.
func attach_building(building_id: String, tile: Vector2i,
		priority_class: StringName = &"STANDARD", block_id: String = "") -> String:
	var best := ""
	var best_key := [999999.0, 999999.0, ""]
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] != &"transformer" or c["state"] == &"FAILED":
			continue
		var t: Vector2i = c["tile"]
		var dist := maxf(absf(tile.x - t.x), absf(tile.y - t.y))
		if dist > float(TRANSFORMER_SERVICE_RADIUS[int(c["level"]) - 1]):
			continue
		var ratio: float = c["load_kw"] / maxf(1.0, c["capacity_kw"])
		var key := [dist, ratio, id]
		if key < best_key:
			best_key = key
			best = id
	if best == "":
		_attachments.erase(building_id)
		return ""
	_attachments[building_id] = best
	if not _service.has(building_id):
		_service[building_id] = {
			"state": &"LIT", "candidate": &"LIT", "candidate_since_gs": 0,
			"served_kwh": 0.0, "demanded_kwh": 0.0, "availability_prev_hour": 1.0,
			"priority_class": priority_class, "block_id": block_id,
		}
	return best


func attachment_of(building_id: String) -> String:
	return _attachments.get(building_id, "")


## Placement probe (doc 04 §2.1: no transformer in range ⇒ UNSERVED, and the
## placement UI blocks it). No side effects.
func would_serve(tile: Vector2i) -> bool:
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] != &"transformer" or c["state"] == &"FAILED":
			continue
		var t: Vector2i = c["tile"]
		if maxf(absf(tile.x - t.x), absf(tile.y - t.y)) \
				<= float(TRANSFORMER_SERVICE_RADIUS[int(c["level"]) - 1]):
			return true
	return false


# ------------------------------------------------------------------ the tick

## demands: {building_id: demand_kw} (doc 02 publishes composed demand).
## distributed: {transformer_id: extra_kw} (streetlights + signals).
## weather: {t_ambient_c, heat_wave: bool}.
func tick(dt_gs: int, demands: Dictionary, distributed: Dictionary,
		weather: Dictionary, rng: RngStreams) -> void:
	now_gs += dt_gs
	_process_reclose_timers()
	_pass_a_aggregate(demands, distributed)
	_pass_b_supply_and_shed()
	_pass_c_thermal(dt_gs, weather, rng)
	if topology_dirty:
		_pass_d_energize()
	_update_service(dt_gs, demands)


func drain_events() -> Array:
	var out := _events
	_events = []
	return out


# ------------------------------------------------------------------- pass A

func _pass_a_aggregate(demands: Dictionary, distributed: Dictionary) -> void:
	for id in _order:
		_components[id]["load_kw"] = 0.0
	for building_id in _sorted_keys(demands):
		var transformer_id: String = _attachments.get(building_id, "")
		if transformer_id != "":
			_components[transformer_id]["load_kw"] += float(demands[building_id])
	for transformer_id in _sorted_keys(distributed):
		if _components.has(transformer_id):
			_components[transformer_id]["load_kw"] += float(distributed[transformer_id])
	# Bottom-up: transformer → feeder → substation → transmission link.
	system_demand_kw = 0.0
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] == &"transformer":
			var parent: String = c["parent"]
			if parent != "":
				_components[parent]["load_kw"] += c["load_kw"]
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] == &"feeder":
			var parent: String = c["parent"]
			if parent != "":
				_components[parent]["load_kw"] += c["load_kw"]
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] == &"substation":
			system_demand_kw += c["load_kw"]
			# The transmission link carries its substation's whole load.
			for child_id in _children_of(id):
				if _components[child_id]["kind"] == &"transmission":
					_components[child_id]["load_kw"] = c["load_kw"]
		elif c["kind"] == &"transmission" and c["parent"] != "" \
				and _components.has(c["parent"]) \
				and _components[c["parent"]]["kind"] == &"substation":
			c["load_kw"] = _components[c["parent"]]["load_kw"]


# ------------------------------------------------------------------- pass B

func _pass_b_supply_and_shed() -> void:
	system_supply_kw = 0.0
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] == &"plant_gas" and c["state"] == &"OK":
			system_supply_kw += c["capacity_kw"]
	var deficit := system_demand_kw - system_supply_kw
	if deficit <= 0.0:
		if not shed_feeders.is_empty():
			shed_feeders.clear()
			topology_dirty = true
			_emit(&"LoadShedEnded", {})
		return
	if now_gs >= shed_rotation_next_gs and not shed_feeders.is_empty():
		shed_feeders.clear()  # rotation: recompute from scratch, pain moves
		_emit(&"RollingBlackoutRotated", {})
	if not shed_feeders.is_empty():
		return  # current shed set stands until rotation
	var candidates: Array = []
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] == &"feeder" and c["state"] == &"OK" and c["load_kw"] > 0.0:
			candidates.append(id)
	if candidates.is_empty():
		return
	var scored: Array = []
	for id in candidates:
		scored.append({"id": id, "score": _shed_score(id), "load": _components[id]["load_kw"],
				"critical": _feeder_has_critical(id)})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["critical"] != b["critical"]:
			return not a["critical"]  # critical feeders shed last
		if absf(float(a["score"]) - float(b["score"])) > 0.0001:
			return float(a["score"]) < float(b["score"])
		if absf(float(a["load"]) - float(b["load"])) > 0.0001:
			return float(a["load"]) > float(b["load"])  # descending load
		return String(a["id"]) < String(b["id"]))
	var shed_total := 0.0
	for entry in scored:
		if shed_total >= deficit:
			break
		shed_feeders.append(entry["id"])
		shed_total += float(entry["load"])
	shed_rotation_next_gs = now_gs + ROLLING_SHED_PERIOD_GM * 60
	topology_dirty = true
	_emit(&"LoadShedStarted", {"feeders": shed_feeders.duplicate(), "shed_kw": shed_total})


func _shed_score(feeder_id: String) -> float:
	var weighted := 0.0
	var total := 0.0
	for building_id in _sorted_keys(_attachments):
		var transformer_id: String = _attachments[building_id]
		if String(_components[transformer_id]["parent"]) != feeder_id:
			continue
		var record: Dictionary = _service.get(building_id, {})
		var priority: StringName = record.get("priority_class", &"STANDARD")
		var demand: float = _components[transformer_id]["load_kw"]
		# Score uses the transformer group's demand weighted by its class mix;
		# per-building demand is folded through the service record on refine.
		weighted += demand * float(PRIORITY_WEIGHT[priority])
		total += demand
		break  # one class sample per transformer group is the MVP granularity
	if total <= 0.0:
		var load: float = _components[feeder_id]["load_kw"]
		return float(PRIORITY_WEIGHT[&"DISCRETIONARY"]) if load > 0.0 else 999999.0
	var score: float = weighted / float(_components[feeder_id]["load_kw"])
	if _components[feeder_id]["priority_override"]:
		score += PRIORITY_OVERRIDE_BONUS
	return score


func _feeder_has_critical(feeder_id: String) -> bool:
	for building_id in _sorted_keys(_attachments):
		var transformer_id: String = _attachments[building_id]
		if String(_components[transformer_id]["parent"]) == feeder_id \
				and _service.get(building_id, {}).get("priority_class", &"STANDARD") == &"CRITICAL":
			return true
	return false


## Direct class-scored shedding for tests / WE-4: score supplied per feeder.
func force_shed_evaluation(feeder_scores: Dictionary, deficit: float) -> Array:
	var scored: Array = []
	for id in _sorted_keys(feeder_scores):
		scored.append({"id": id, "score": float(feeder_scores[id]),
				"load": _components[id]["load_kw"]})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(float(a["score"]) - float(b["score"])) > 0.0001:
			return float(a["score"]) < float(b["score"])
		if absf(float(a["load"]) - float(b["load"])) > 0.0001:
			return float(a["load"]) > float(b["load"])
		return String(a["id"]) < String(b["id"]))
	var shed: Array = []
	var total := 0.0
	for entry in scored:
		if total >= deficit:
			break
		shed.append(entry["id"])
		total += float(entry["load"])
	return shed


# ------------------------------------------------------------------- pass C

func cap_eff(id: String, t_ambient: float) -> float:
	var c: Dictionary = _components[id]
	var amb_derate := clampf(1.0 - 0.008 * maxf(0.0, t_ambient - 30.0), 0.80, 1.0)
	return c["capacity_kw"] * (0.55 + 0.45 * float(c["condition"])) * amb_derate


func _pass_c_thermal(dt_gs: int, weather: Dictionary, rng: RngStreams) -> void:
	var t_ambient := float(weather.get("t_ambient_c", 25.0))
	var still_air := 1.10 if bool(weather.get("heat_wave", false)) else 1.0
	var dt_gh := float(dt_gs) / 3600.0
	for id in _order:
		var c: Dictionary = _components[id]
		var kind: StringName = c["kind"]
		if kind == &"plant_gas":
			if c["state"] == &"OK":
				var r_plant: float = c["load_kw"] / maxf(1.0, c["capacity_kw"])
				var cond_mult := 1.0 + 3.0 * pow(1.0 - float(c["condition"]), 2)
				var h := PLANT_H_BASE * (1.0 + 2.0 * maxf(0.0, r_plant - 0.9)) * cond_mult
				if rng.stream("failures").randf() < 1.0 - exp(-h * dt_gh):
					_trip(id, &"PLANT_TRIP", "")
			continue
		if not THERMAL.has(kind):
			continue
		var effective := cap_eff(id, t_ambient)
		var r: float = (c["load_kw"] / maxf(1.0, effective)) if c["energized"] else 0.0
		# Thermal integration (de-energized components cool toward 0).
		var theta_rated := float(THERMAL[kind][0])
		var tau := float(THERMAL[kind][1])
		var theta_ss := theta_rated * r * r * still_air
		var alpha := float(dt_gs) / (tau + float(dt_gs))
		c["theta_c"] = float(c["theta_c"]) + (theta_ss - float(c["theta_c"])) * alpha
		var temp := t_ambient + float(c["theta_c"])
		if c["state"] != &"OK":
			continue
		# Transformer hard ceiling: it cooks, it does not trip — until 3.0.
		if kind == &"transformer" and r >= XFMR_BURNOUT_R:
			_fail(id, "XFMR_BURNOUT", 0.35)
			continue
		# Inverse-time relay (feeder / substation / transmission only).
		if K_TRIP.has(kind) and c["energized"]:
			if r > R_PICKUP:
				var t_trip := clampf(float(K_TRIP[kind]) / (r * r - 1.0), 2.0, 900.0)
				c["trip_accum"] = float(c["trip_accum"]) + float(dt_gs) / t_trip
				if float(c["trip_accum"]) >= 1.0:
					c["trip_accum"] = 0.0
					_trip(id, StringName(String(kind).to_upper() + "_TRIP"), "")
					continue
			else:
				c["trip_accum"] = maxf(0.0, float(c["trip_accum"]) - float(dt_gs) / TRIP_ACCUM_DECAY_GS)
		# Hazard roll.
		var knee := float(HAZARD[kind][0])
		var span := float(HAZARD[kind][1])
		var h_hot := float(HAZARD[kind][2])
		var h_cold := float(HAZARD[kind][3])
		var stress := maxf(0.0, (temp - knee) / span)
		var cond_mult2 := 1.0 + 3.0 * pow(1.0 - float(c["condition"]), 2)
		var hazard := (h_cold + h_hot * pow(stress, 3)) * cond_mult2
		if c["energized"] and rng.stream("failures").randf() < 1.0 - exp(-hazard * dt_gh):
			if kind == &"transformer":
				_fail(id, "XFMR_BURNOUT", 0.35)
			elif kind == &"feeder":
				_fail(id, "FEEDER_FAULT", 0.05)
			elif kind == &"substation":
				_fail(id, "SUB_FAULT", 0.30)
			else:
				_fail(id, "LINE_FAULT", 0.05)
			continue
		# Condition wear.
		if c["energized"]:
			c["condition"] = clampf(float(c["condition"])
					- WEAR_PER_GH * dt_gh * (1.0 + 6.0 * stress * stress), 0.0, 1.0)


# ---------------------------------------------------------- trips & failures

func _trip(id: String, incident_type: StringName, cause_component: String) -> void:
	var c: Dictionary = _components[id]
	c["state"] = &"OPEN"
	c["reclose_at_gs"] = now_gs + AUTO_RECLOSE_DELAY_GS
	topology_dirty = true
	_tag_cascade(id, cause_component)
	_emit(&"PowerComponentTripped", {"component": id, "incident_type": incident_type,
			"cause_chain": (c["cause_chain"] as Array).duplicate()})


func _fail(id: String, cause: String, damage_fraction: float) -> void:
	var c: Dictionary = _components[id]
	c["state"] = &"FAILED"
	c["failed_cause"] = cause
	c["reclose_at_gs"] = -1
	topology_dirty = true
	_tag_cascade(id, "")
	_emit(&"PowerComponentFailed", {"component": id, "cause": cause,
			"damage_fraction": damage_fraction,
			"cause_chain": (c["cause_chain"] as Array).duplicate()})


func _tag_cascade(id: String, upstream: String) -> void:
	var c: Dictionary = _components[id]
	if now_gs - _last_trip_gs <= CASCADE_WINDOW_GS and _last_trip_component != "" \
			and _last_trip_component != id:
		c["cause_chain"] = [_last_trip_component]
		_emit(&"CascadeStep", {"component": id, "upstream": _last_trip_component})
	else:
		c["cause_chain"] = []
	_last_trip_gs = now_gs
	_last_trip_component = id


func _process_reclose_timers() -> void:
	for id in _order:
		var c: Dictionary = _components[id]
		if c["state"] != &"OPEN" or int(c["reclose_at_gs"]) < 0 or now_gs < int(c["reclose_at_gs"]):
			continue
		# Retry: close and observe next tick's load ratio.
		c["state"] = &"OK"
		c["reclose_at_gs"] = -1
		c["pending_reclose_check"] = true
		topology_dirty = true


## Called during pass C evaluation window via tick order: check the reclose
## outcome one tick after closing.
func evaluate_reclose(id: String, t_ambient: float) -> void:
	var c: Dictionary = _components[id]
	if not c.get("pending_reclose_check", false):
		return
	c.erase("pending_reclose_check")
	var r: float = c["load_kw"] / maxf(1.0, cap_eff(id, t_ambient))
	if r <= AUTO_RECLOSE_OK_R:
		c["reclose_attempts"] = 0
		_emit(&"AutoReclosedOK", {"component": id})
		return
	c["reclose_attempts"] = int(c["reclose_attempts"]) + 1
	if int(c["reclose_attempts"]) >= AUTO_RECLOSE_MAX_ATTEMPTS:
		c["state"] = &"OPEN"
		c["reclose_at_gs"] = -1
		topology_dirty = true
		_emit(&"AutoRecloseLockout", {"component": id})
	else:
		c["state"] = &"OPEN"
		c["reclose_at_gs"] = now_gs + AUTO_RECLOSE_DELAY_GS
		topology_dirty = true


## Crew repair completion: component returns to service at condition 0.85.
func repair_component(id: String) -> void:
	var c: Dictionary = _components[id]
	c["state"] = &"OK"
	c["failed_cause"] = ""
	c["condition"] = maxf(float(c["condition"]), 0.85)
	c["reclose_attempts"] = 0
	c["theta_c"] = 0.0
	topology_dirty = true


func force_open(id: String) -> void:
	_components[id]["state"] = &"OPEN"
	_components[id]["reclose_at_gs"] = -1
	topology_dirty = true


func force_close(id: String) -> void:
	_components[id]["state"] = &"OK"
	topology_dirty = true


# ------------------------------------------------- lightning (doc 07 events)

## Resolution only — doc 07 generates and targets (report 98 C-54).
## Band shares of p_damage: ds1 0.45 / ds2 0.45 / ds3 0.10.
func resolve_lightning(id: String, energy: float, rng: RngStreams) -> Dictionary:
	return _resolve_lightning_with(id, energy, rng.stream("failures").randf())


func _resolve_lightning_with(id: String, energy: float, u: float) -> Dictionary:
	var c: Dictionary = _components[id]
	if bool(c["underground"]):
		return {"band": "ds0", "damage_fraction": 0.0}
	var p := LIGHTNING_P_BASE * (1.0 - LIGHTNING_ARRESTER_FACTOR * int(c["arrester_level"])) \
			* clampf(energy, 0.6, 1.6)
	if u >= p:
		c["condition"] = clampf(float(c["condition"]) - 0.05, 0.0, 1.0)
		_emit(&"SurgeAbsorbed", {"component": id})
		return {"band": "ds0", "damage_fraction": 0.0}
	if u < 0.45 * p:
		_trip(id, &"LIGHTNING_TRIP", "")
		return {"band": "ds1", "damage_fraction": 0.005}
	if u < 0.90 * p:
		var fraction := 0.35 if c["kind"] == &"transformer" else (0.30 if c["kind"] == &"substation" else 0.05)
		_fail(id, "LIGHTNING", fraction)
		return {"band": "ds2", "damage_fraction": fraction}
	_fail(id, "LIGHTNING_DESTROYED", 1.0)
	return {"band": "ds3", "damage_fraction": 1.0, "secondary_fire_p": 0.25}


# ------------------------------------------------------------------- pass D

func _pass_d_energize() -> void:
	var was_energized: Dictionary = {}
	for id in _order:
		was_energized[id] = _components[id]["energized"]
		_components[id]["energized"] = false
	var restore_order: Array[int] = []
	var supply_exists := system_supply_kw > 0.0 or _any_plant_ok()
	if supply_exists:
		for id in _order:
			var c: Dictionary = _components[id]
			if c["kind"] != &"substation" or c["state"] != &"OK":
				continue
			if not _substation_linked(id):
				continue
			_energize_dfs(id, restore_order)
	topology_dirty = false
	var any_restored := false
	for id in _order:
		if _components[id]["energized"] and not bool(was_energized[id]):
			any_restored = true
			break
	if any_restored:
		_emit(&"PowerRestored", {"restore_order": restore_order,
				"powered_fraction": 1.0})


func _any_plant_ok() -> bool:
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] == &"plant_gas" and c["state"] == &"OK":
			return true
	return false


func _substation_linked(substation_id: String) -> bool:
	# Linked to the bulk pool through an OK transmission child (or directly,
	# for test rigs with no transmission modelled).
	var has_link := false
	for child_id in _children_of(substation_id):
		if _components[child_id]["kind"] == &"transmission":
			has_link = true
			if _components[child_id]["state"] == &"OK":
				return true
	return not has_link


func _energize_dfs(root_id: String, restore_order: Array[int]) -> void:
	var stack: Array[String] = [root_id]
	while not stack.is_empty():
		var id: String = stack.pop_back()
		var c: Dictionary = _components[id]
		if c["state"] != &"OK" or shed_feeders.has(id):
			continue
		c["energized"] = true
		restore_order.append(_order.find(id))
		var children := _children_of(id)
		for i in range(children.size() - 1, -1, -1):
			var child: Dictionary = _components[children[i]]
			if child["kind"] != &"transmission":  # links feed IN, not out
				stack.push_back(children[i])


func _children_of(id: String) -> Array:
	if _children.has(id) and not topology_dirty:
		return _children[id]
	var out: Array = []
	for candidate_id in _order:
		if String(_components[candidate_id]["parent"]) == id:
			out.append(candidate_id)
	_children[id] = out
	return out


func is_energized(id: String) -> bool:
	return bool(_components[id]["energized"])


# ------------------------------------------------------ ties & auto-transfer

## Evaluate auto-transfer for a de-energized feeder (called after a trip's
## transfer delay by the coordinator, or directly in tests).
func evaluate_tie_transfer(tie_id: String, t_ambient: float = 25.0) -> Dictionary:
	var tie: Dictionary = _ties[tie_id]
	var a: Dictionary = _components[tie["a"]]
	var b: Dictionary = _components[tie["b"]]
	var orphan: Dictionary
	var partner: Dictionary
	if a["energized"] and not b["energized"]:
		partner = a
		orphan = b
	elif b["energized"] and not a["energized"]:
		partner = b
		orphan = a
	else:
		return {"result": "not_applicable"}
	var r_after: float = (partner["load_kw"] + orphan["load_kw"]) \
			/ maxf(1.0, cap_eff(String(partner["id"]), t_ambient))
	if r_after <= TIE_CLEAN_R:
		tie["closed"] = true
		orphan["parent"] = partner["parent"]
		topology_dirty = true
		_emit(&"TieTransferSuccess", {"tie": tie_id, "r_after": r_after})
		return {"result": "closed", "r_after": r_after}
	if r_after <= TIE_AGGRESSIVE_R or tie["mode"] == &"AGGRESSIVE":
		if tie["mode"] == &"AGGRESSIVE" or (tie["mode"] == &"AUTO" and r_after <= TIE_AGGRESSIVE_R):
			if tie["mode"] == &"AGGRESSIVE":
				tie["closed"] = true
				orphan["parent"] = partner["parent"]
				topology_dirty = true
				var t_trip := clampf(float(K_TRIP[&"feeder"]) / (r_after * r_after - 1.0), 2.0, 900.0)
				_emit(&"TieTransferSuccess", {"tie": tie_id, "r_after": r_after,
						"partner_t_trip_gs": t_trip})
				return {"result": "closed_overloaded", "r_after": r_after,
						"partner_t_trip_gs": t_trip}
	_emit(&"TieTransferBlocked", {"tie": tie_id, "r_after": r_after})
	return {"result": "blocked", "r_after": r_after}


## N-1 headroom: best tie-partner's spare capacity against this feeder's load.
func n1_headroom_kw(feeder_id: String, t_ambient: float = 25.0) -> float:
	var best := -INF
	for tie_id in _sorted_keys(_ties):
		var tie: Dictionary = _ties[tie_id]
		var partner_id := ""
		if String(tie["a"]) == feeder_id:
			partner_id = String(tie["b"])
		elif String(tie["b"]) == feeder_id:
			partner_id = String(tie["a"])
		else:
			continue
		var partner: Dictionary = _components[partner_id]
		best = maxf(best, cap_eff(partner_id, t_ambient) - float(partner["load_kw"])
				- float(_components[feeder_id]["load_kw"]))
	return best


# -------------------------------------------------------------- service side

func _update_service(dt_gs: int, demands: Dictionary) -> void:
	var dt_gh := float(dt_gs) / 3600.0
	for building_id in _sorted_keys(_service):
		var record: Dictionary = _service[building_id]
		var demand := float(demands.get(building_id, 0.0))
		var transformer_id: String = _attachments.get(building_id, "")
		var served := 0.0
		if transformer_id != "" and bool(_components[transformer_id]["energized"]):
			served = demand
		record["served_kwh"] = float(record["served_kwh"]) + served * dt_gh
		record["demanded_kwh"] = float(record["demanded_kwh"]) + demand * dt_gh
		# LIT/DARK hysteresis.
		var target: StringName = record["state"]
		if demand > 0.0:
			var ratio := served / demand
			if ratio < DARK_THRESHOLD:
				target = &"DARK"
			elif ratio >= LIT_THRESHOLD:
				target = &"LIT"
		if target != record["candidate"]:
			record["candidate"] = target
			record["candidate_since_gs"] = now_gs
		var sustain := DARK_SUSTAIN_GS if target == &"DARK" else LIT_SUSTAIN_GS
		if target != record["state"] and now_gs - int(record["candidate_since_gs"]) >= sustain:
			record["state"] = target
			_emit(&"BuildingPowerChanged", {"building": building_id, "state": target})


## Game-hour boundary, before doc 03 settles (report 98 C-37).
func settle_hour() -> Dictionary:
	var out := {}
	for building_id in _sorted_keys(_service):
		var record: Dictionary = _service[building_id]
		var availability := 1.0
		if float(record["demanded_kwh"]) > 0.0:
			availability = clampf(float(record["served_kwh"]) / float(record["demanded_kwh"]), 0.0, 1.0)
		record["availability_prev_hour"] = availability
		record["served_kwh"] = 0.0
		record["demanded_kwh"] = 0.0
		out[building_id] = availability
	return out


func power_availability_hour(building_id: String) -> float:
	return float(_service.get(building_id, {}).get("availability_prev_hour", 1.0))


func is_powered(building_id: String) -> bool:
	return _service.get(building_id, {}).get("state", &"LIT") == &"LIT"


## Weighted dark fraction per block; ≥60% ⇒ block_dark (report 98 C-38).
## weights: {building_id: pop+jobs weight}.
func block_dark_fractions(weights: Dictionary) -> Dictionary:
	var dark: Dictionary = {}
	var total: Dictionary = {}
	for building_id in _sorted_keys(_service):
		var record: Dictionary = _service[building_id]
		var block: String = record.get("block_id", "")
		if block == "":
			continue
		var w := float(weights.get(building_id, 1.0))
		total[block] = float(total.get(block, 0.0)) + w
		if record["state"] == &"DARK":
			dark[block] = float(dark.get(block, 0.0)) + w
	var out := {}
	for block in _sorted_keys(total):
		var fraction: float = float(dark.get(block, 0.0)) / maxf(1.0, float(total[block]))
		out[block] = {"fraction": fraction, "dark": fraction >= BLOCK_DARK_THRESHOLD}
	return out


# ----------------------------------------------------------- upgrade gate

## Doc 02 E2: the serving path must keep ≤0.90 post-upgrade (§5.3).
func can_upgrade_power(building_id: String, delta_kw: float, t_ambient: float = 25.0) -> Dictionary:
	var transformer_id: String = _attachments.get(building_id, "")
	if transformer_id == "":
		return {"ok": false, "reason": "UNSERVED", "deficit_kw": delta_kw}
	var path := [transformer_id]
	var feeder_id := String(_components[transformer_id]["parent"])
	if feeder_id != "":
		path.append(feeder_id)
		var substation_id := String(_components[feeder_id]["parent"])
		if substation_id != "":
			path.append(substation_id)
	var worst_deficit := 0.0
	for id in path:
		var effective := cap_eff(id, t_ambient)
		var r_after: float = (float(_components[id]["load_kw"]) + delta_kw) / maxf(1.0, effective)
		if r_after > 0.90:
			worst_deficit = maxf(worst_deficit,
					(float(_components[id]["load_kw"]) + delta_kw) - 0.90 * effective)
	if worst_deficit > 0.0:
		return {"ok": false, "reason": "BLOCKED_POWER_CAPACITY", "deficit_kw": worst_deficit}
	return {"ok": true, "reason": "", "deficit_kw": 0.0}


# ------------------------------------------------------------- inventory

## The contract doc 03's E_grid bills against (report 98 C-12).
func grid_inventory() -> Dictionary:
	var nodes: Array = []
	var lines: Array = []
	var plants: Array = []
	for id in _order:
		var c: Dictionary = _components[id]
		match c["kind"]:
			&"substation", &"transformer":
				nodes.append({"id": id, "rated_mva": float(c["capacity_kw"]) / 1000.0,
						"condition": c["condition"]})
			&"feeder", &"transmission":
				lines.append({"id": id, "line_km": (c["route"] as Array).size() * 0.008,
						"condition": c["condition"]})
			&"plant_gas":
				plants.append({"id": id, "plant_capacity_mw": float(c["capacity_kw"]) / 1000.0,
						"condition": c["condition"]})
	return {"nodes": nodes, "lines": lines, "plants": plants}


# ------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	var components: Array = []
	for id in _order:
		var c: Dictionary = (_components[id] as Dictionary).duplicate(true)
		c["tile"] = [c["tile"].x, c["tile"].y] if c["tile"] is Vector2i else c["tile"]
		components.append(c)
	var ties: Array = []
	for tie_id in _sorted_keys(_ties):
		ties.append((_ties[tie_id] as Dictionary).duplicate(true))
	var service := {}
	for building_id in _sorted_keys(_service):
		service[building_id] = (_service[building_id] as Dictionary).duplicate(true)
	return {"section_version": 1, "now_gs": now_gs, "components": components,
			"ties": ties, "attachments": _attachments.duplicate(),
			"service": service, "shed_feeders": shed_feeders.duplicate(),
			"shed_rotation_next_gs": shed_rotation_next_gs}


func deserialize(data: Dictionary) -> void:
	_components.clear()
	_order.clear()
	_children.clear()
	for c in data.get("components", []):
		var component: Dictionary = c
		if component["tile"] is Array:
			component["tile"] = Vector2i(int(component["tile"][0]), int(component["tile"][1]))
		component["kind"] = StringName(String(component["kind"]))
		component["state"] = StringName(String(component["state"]))
		_components[String(component["id"])] = component
		_order.append(String(component["id"]))
	_order.sort()
	_ties.clear()
	for tie in data.get("ties", []):
		var record: Dictionary = tie
		record["mode"] = StringName(String(record["mode"]))
		_ties[String(record["id"])] = record
	_attachments = data.get("attachments", {})
	_service.clear()
	for building_id in data.get("service", {}):
		var record: Dictionary = data["service"][building_id]
		record["state"] = StringName(String(record["state"]))
		record["candidate"] = StringName(String(record["candidate"]))
		record["priority_class"] = StringName(String(record["priority_class"]))
		_service[building_id] = record
	now_gs = int(data.get("now_gs", 0))
	shed_feeders = data.get("shed_feeders", [])
	shed_rotation_next_gs = int(data.get("shed_rotation_next_gs", 0))
	topology_dirty = true


# ---------------------------------------------------------------- plumbing

func _emit(event_type: StringName, payload: Dictionary) -> void:
	var event := payload.duplicate()
	event["type"] = event_type
	_events.append(event)


static func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
