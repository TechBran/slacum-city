class_name WaterRepairJobs
extends RefCounted
## Doc 05 §2.12. This class owns CAPABILITY and WORK CONTENT only.
##
##   work_minutes = base_minutes[type] × (0.6 + 0.8 × severity) × type_mods / crew_mult
##   type_mods    = freeze ? 1.6 : 1.0 × flooded ? 1.4 : 1.0 × night ? 1.1 : 1.0
##
## Vehicle routing, travel, the roster and EVERY vehicle price are doc 06/03's;
## the repair PRICE is doc 03's `capital_value × damage_fraction × 0.85 ×
## M_repair` (C-16), which is why this class exposes `damage_fraction` and no
## cost method at all. `work_remaining_min` is held in CREW-minutes: a
## `water_heavy_truck` (crew_mult 1.5) burns 1.5 crew-minutes per game-minute.

var data: WaterData
var jobs: Dictionary = {}  # job_id -> record
var next_job_id: int = 1


func _init(p_data: WaterData) -> void:
	data = p_data


## Pure work-content math (crew-minutes before the crew multiplier).
func work_content_minutes(kind: String, severity: float, mods: Dictionary = {}) -> float:
	var floor_value := float(data.repair.get("severity_floor", 0.6))
	var gain := float(data.repair.get("severity_gain", 0.8))
	var table: Dictionary = data.repair.get("mods", {})
	var multiplier := 1.0
	if bool(mods.get("frozen", false)):
		multiplier *= float(table.get("frozen", 1.6))
	if bool(mods.get("flooded", false)):
		multiplier *= float(table.get("flooded", 1.4))
	if bool(mods.get("night", false)):
		multiplier *= float(table.get("night", 1.1))
	return data.repair_base_minutes(kind) * (floor_value + gain * severity) * multiplier


## Elapsed game-minutes for a given crew — doc 05 §2.12's `work_minutes`.
func work_minutes(kind: String, severity: float, vehicle: String,
		mods: Dictionary = {}) -> float:
	return work_content_minutes(kind, severity, mods) / maxf(data.crew_mult(vehicle), 1e-6)


func create(record: Dictionary, now_minutes: float) -> Dictionary:
	var kind := String(record.get("kind", "main_break"))
	var severity := float(record.get("severity", 0.5))
	var mods: Dictionary = record.get("mods", {"frozen": bool(record.get("frozen", false))})
	var job := {
		"job_id": next_job_id,
		"kind": kind,
		"target_kind": String(record.get("target_kind", "edge")),
		"target_id": String(record.get("target_id", "")),
		"tile": record.get("tile", Vector2i.ZERO),
		"severity": severity,
		"frozen": bool(record.get("frozen", false)),
		"damage_fraction": float(record.get("damage_fraction", 0.0)),
		"work_remaining_min": work_content_minutes(kind, severity, mods),
		"assigned_vehicle": String(record.get("assigned_vehicle", "")),
		"vehicle_type": String(record.get("vehicle_type", "water_repair_truck")),
		"isolated": false,
		"created_at_minutes": now_minutes,
	}
	next_job_id += 1
	jobs[job["job_id"]] = job
	return job


func assign(job_id: int, vehicle_id: String, vehicle_type: String = "water_repair_truck") -> bool:
	if not jobs.has(job_id):
		return false
	jobs[job_id]["assigned_vehicle"] = vehicle_id
	jobs[job_id]["vehicle_type"] = vehicle_type
	return true


func job(job_id: int) -> Dictionary:
	return jobs.get(job_id, {})


func job_for_target(target_id: String) -> Dictionary:
	for id in _sorted(jobs):
		if String(jobs[id]["target_id"]) == target_id:
			return jobs[id]
	return {}


## Burn `dt_minutes` of crew time against every assigned job; returns the jobs
## that finished, in job-id order.
func advance(dt_minutes: float) -> Array:
	var completed: Array = []
	for job_id in _sorted(jobs):
		var record: Dictionary = jobs[job_id]
		if String(record["assigned_vehicle"]) == "":
			continue
		var rate := data.crew_mult(String(record["vehicle_type"]))
		record["work_remaining_min"] = float(record["work_remaining_min"]) - dt_minutes * rate
		if float(record["work_remaining_min"]) <= 0.0:
			record["work_remaining_min"] = 0.0
			completed.append(record)
	for record in completed:
		jobs.erase(int(record["job_id"]))
	return completed


func cancel(job_id: int) -> void:
	jobs.erase(job_id)


func serialize() -> Dictionary:
	var out: Array = []
	for job_id in _sorted(jobs):
		var record: Dictionary = (jobs[job_id] as Dictionary).duplicate()
		var tile: Vector2i = record["tile"]
		record["tile"] = [tile.x, tile.y]
		out.append(record)
	return {"jobs": out, "next_job_id": next_job_id}


func deserialize(state: Dictionary) -> void:
	jobs.clear()
	for record in state.get("jobs", []):
		var job_record: Dictionary = (record as Dictionary).duplicate()
		var tile_pair: Array = job_record["tile"]
		job_record["tile"] = Vector2i(int(tile_pair[0]), int(tile_pair[1]))
		job_record["job_id"] = int(job_record["job_id"])
		jobs[int(job_record["job_id"])] = job_record
	next_job_id = int(state.get("next_job_id", 1))


static func _sorted(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
