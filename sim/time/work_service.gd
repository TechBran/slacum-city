class_name WorkService
extends RefCounted
## Work units (doc 01 §2.7b): progress accruing at a variable rate.
## Exact integer milli-unit accumulation with carry — no float drift, exact
## save round-trip. Anything whose speed varies with weather/night/crews MUST
## be a work unit, never a timer.

const ACCUMULATOR_DENOMINATOR: int = 3600000  # mu·gh per (mu/h · gs · permille)

var next_work_id: int = 1
var _units: Dictionary = {}  # id -> unit Dictionary


func create(kind: StringName, owner: StringName, work_required_mu: int, rate_mu_per_hour: int,
		rate_channel: String = "", payload: Dictionary = {}) -> int:
	var id := next_work_id
	next_work_id += 1
	_units[id] = {
		"id": id, "kind": kind, "owner": owner,
		"work_required_mu": work_required_mu, "work_done_mu": 0, "carry_mu": 0,
		"rate_mu_per_hour": rate_mu_per_hour, "rate_channel": rate_channel,
		"blocked": false, "payload": payload,
	}
	return id


func get_unit(work_id: int) -> Dictionary:
	return _units.get(work_id, {})


func set_blocked(work_id: int, blocked: bool) -> void:
	if _units.has(work_id):
		_units[work_id]["blocked"] = blocked


func set_rate(work_id: int, rate_mu_per_hour: int) -> void:
	if _units.has(work_id):
		_units[work_id]["rate_mu_per_hour"] = rate_mu_per_hour


func cancel(work_id: int) -> bool:
	return _units.erase(work_id)


func active_count() -> int:
	return _units.size()


## Advances every unblocked unit by rate × dt × efficiency; returns completed
## units in ascending-id order (deterministic iteration).
func advance(ctx: TimeContext) -> Array[Dictionary]:
	var completed: Array[Dictionary] = []
	var ids := _units.keys()
	ids.sort()
	for id in ids:
		var unit: Dictionary = _units[id]
		if bool(unit["blocked"]):
			continue
		var eff_permille := 1000
		var channel := String(unit["rate_channel"])
		if channel != "" and ctx.channels_hour.has(channel):
			# Hour-midpoint efficiency: identical in fine and coarse mode, which
			# is what makes work accumulation exactly fine/coarse-equivalent.
			eff_permille = roundi(float(ctx.channels_hour[channel]) * 1000.0)
		var num: int = int(unit["rate_mu_per_hour"]) * ctx.dt_game_seconds * eff_permille
		unit["work_done_mu"] = int(unit["work_done_mu"]) + num / ACCUMULATOR_DENOMINATOR
		unit["carry_mu"] = int(unit["carry_mu"]) + num % ACCUMULATOR_DENOMINATOR
		if int(unit["carry_mu"]) >= ACCUMULATOR_DENOMINATOR:
			unit["work_done_mu"] = int(unit["work_done_mu"]) + 1
			unit["carry_mu"] = int(unit["carry_mu"]) - ACCUMULATOR_DENOMINATOR
		if int(unit["work_done_mu"]) >= int(unit["work_required_mu"]):
			completed.append(unit)
	for unit in completed:
		_units.erase(int(unit["id"]))
	return completed


func serialize() -> Dictionary:
	var units: Array = []
	var ids := _units.keys()
	ids.sort()
	for id in ids:
		units.append(_units[id].duplicate(true))
	return {"next_work_id": next_work_id, "work_units": units}


func deserialize(data: Dictionary) -> void:
	next_work_id = int(data.get("next_work_id", 1))
	_units.clear()
	for unit in data.get("work_units", []):
		_units[int(unit["id"])] = unit
