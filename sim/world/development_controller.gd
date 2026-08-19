class_name DevelopmentController
extends RefCounted
## The six-phase land development pipeline (doc 09 §2.3): SURVEY → CLEARING →
## GRADING → ROAD_INSTALL → UTILITY_CORRIDOR → FINAL_DEVELOPMENT → READY.
## Phases run strictly in order, one crew per phase; progress runs through the
## ConstructionQueue's exact integer accumulator with the construction_rate
## channel (report 98 C-29). Costs are doc 03's; this controller only asks.

const PHASES: Array[StringName] = [
	&"SURVEY", &"CLEARING", &"GRADING", &"ROAD_INSTALL",
	&"UTILITY_CORRIDOR", &"FINAL_DEVELOPMENT",
]
const PHASE_CREW_HOURS := {
	&"SURVEY": 4.0, &"CLEARING": 8.0, &"GRADING": 12.0,
	&"ROAD_INSTALL": 14.0, &"UTILITY_CORRIDOR": 16.0, &"FINAL_DEVELOPMENT": 6.0,
}
const PHASE_PRIMARY_CREW := {
	&"SURVEY": &"construction_crew", &"CLEARING": &"heavy_equipment_crew",
	&"GRADING": &"heavy_equipment_crew", &"ROAD_INSTALL": &"road_crew",
	&"UTILITY_CORRIDOR": &"heavy_equipment_crew", &"FINAL_DEVELOPMENT": &"construction_crew",
}
## Fallback crew-type → crew-hours multiplier per phase (doc 09 §2.3 table).
const PHASE_FALLBACK := {
	&"SURVEY": {&"construction_crew": 1.0, &"heavy_equipment_crew": 1.0, &"road_crew": 1.0},
	&"CLEARING": {&"heavy_equipment_crew": 1.0, &"construction_crew": 1.4},
	&"GRADING": {&"heavy_equipment_crew": 1.0, &"construction_crew": 1.6},
	&"ROAD_INSTALL": {&"road_crew": 1.0, &"construction_crew": 1.8},
	&"UTILITY_CORRIDOR": {&"heavy_equipment_crew": 1.0, &"road_crew": 1.3, &"construction_crew": 2.0},
	&"FINAL_DEVELOPMENT": {&"construction_crew": 1.0, &"heavy_equipment_crew": 1.0, &"road_crew": 1.0},
}
const FIRST_BLOCK_TIME_MULT := 0.48  # retuned per report 98 C-29

var world: WorldMap
var queue: ConstructionQueue
var blocks_developed: int = 0
var _active: Dictionary = {}  # block_id -> {phase_index, job_id, crew_type, paused}
var _events: Array = []
## Phase costs owed to doc 03 for phases submitted since the last drain. This
## controller never touches money (§ header); it only records what was started
## so the coordinator can charge `EconomySystem.development_phase_cost()`.
## Produced and drained inside one tick, so it is derived state and never saved.
var _pending_charges: Array = []


func _init(p_world: WorldMap, p_queue: ConstructionQueue) -> void:
	world = p_world
	queue = p_queue


func drain_events() -> Array:
	var out := _events
	_events = []
	return out


## Doc 03 §2.8 phase costs owed since the last call, in submission order:
## `[{block_id, phase, phase_index, job_id, crew_type}]`. The coordinator prices
## and charges each, and binds the job's crew (doc 06 owns crews, not this class).
func take_phase_charges() -> Array:
	var out := _pending_charges
	_pending_charges = []
	return out


func is_first_block() -> bool:
	return blocks_developed == 0


## Begin development on an OWNED, UNDEVELOPED block. The caller has already
## charged doc 03's phase cost. crew_type must be legal for SURVEY (any is).
func start_development(block_id: String, crew_type: StringName = &"construction_crew") -> Dictionary:
	var block := world.block(block_id)
	if block == null:
		return CommandQueue.fail(&"E_UNKNOWN_BLOCK")
	if not block.is_owned():
		return CommandQueue.fail(&"E_NOT_OWNED")
	if block.development_state != &"UNDEVELOPED":
		return CommandQueue.fail(&"E_ALREADY_DEVELOPING")
	if _active.has(block_id):
		return CommandQueue.fail(&"E_ALREADY_DEVELOPING")
	_active[block_id] = {"phase_index": 0, "job_id": 0, "crew_type": crew_type,
			"paused": false, "first_block": is_first_block()}
	return _submit_phase(block_id)


func _submit_phase(block_id: String) -> Dictionary:
	var record: Dictionary = _active[block_id]
	var phase: StringName = PHASES[int(record["phase_index"])]
	var crew_type: StringName = record["crew_type"]
	var fallback: Dictionary = PHASE_FALLBACK[phase]
	if not fallback.has(crew_type):
		# Every phase accepts the generic crew (at its fallback multiplier), so
		# a specialist plan degrades gracefully instead of stalling.
		crew_type = &"construction_crew"
	var crew_hours: float = float(PHASE_CREW_HOURS[phase]) * float(fallback[crew_type])
	if bool(record["first_block"]):
		crew_hours *= FIRST_BLOCK_TIME_MULT
	var job_id := queue.submit(&"development", block_id, crew_hours, crew_type,
			{"block_id": block_id, "phase": String(phase)})
	record["job_id"] = job_id
	var block := world.block(block_id)
	block.development_state = phase
	_pending_charges.append({"block_id": block_id, "phase": String(phase),
			"phase_index": int(record["phase_index"]), "job_id": job_id,
			"crew_type": String(crew_type)})
	_events.append({"type": &"development_phase_started", "block": block_id,
			"phase": phase, "crew_hours": crew_hours})
	return CommandQueue.ok({"job_id": job_id, "phase": phase, "crew_hours": crew_hours})


## Feed completed ConstructionQueue jobs back in. Applies the phase's world
## effect; auto-continues to the next phase unless paused. Returns whether the
## job belonged to this controller.
func on_job_completed(job: Dictionary) -> bool:
	if job.get("kind", &"") != &"development":
		return false
	var block_id := String(job["payload"]["block_id"])
	if not _active.has(block_id):
		return false
	var record: Dictionary = _active[block_id]
	var phase: StringName = PHASES[int(record["phase_index"])]
	_apply_phase_effect(block_id, phase)
	_events.append({"type": &"development_phase_completed", "block": block_id, "phase": phase})
	record["phase_index"] = int(record["phase_index"]) + 1
	record["job_id"] = 0
	if int(record["phase_index"]) >= PHASES.size():
		var block := world.block(block_id)
		block.development_state = &"READY"
		blocks_developed += 1
		_active.erase(block_id)
		_events.append({"type": &"block_ready", "block": block_id})
		return true
	if bool(record["paused"]):
		return true
	_submit_phase(block_id)
	return true


func _apply_phase_effect(block_id: String, phase: StringName) -> void:
	var block := world.block(block_id)
	match phase:
		&"SURVEY":
			block.survey_revealed = true
			_events.append({"type": &"block_surveyed", "block": block_id})
		&"CLEARING":
			block.vegetation_density = 0.0
		&"GRADING":
			block.slope_index = 0.0
		&"ROAD_INSTALL":
			# Template stamping is the loader/road system's job; here the
			# access attributes advance (doc 09: neighbours rise to ≥ STUB).
			if block.road_access == &"NONE":
				block.road_access = &"EDGE"
			for neighbor in world.neighbors4(block_id):
				if (neighbor as LandBlock).road_access == &"NONE":
					(neighbor as LandBlock).road_access = &"STUB"
			_events.append({"type": &"block_road_access_changed", "block": block_id})
		&"UTILITY_CORRIDOR":
			if not block.tags.has("utility_corridor"):
				block.tags.append("utility_corridor")
		&"FINAL_DEVELOPMENT":
			pass  # READY transition handled by the caller


## Pause is legal only BETWEEN phases (doc 09 §2.3): while a phase job is
## running, pausing is rejected; the flag stops the auto-continue.
func pause_development(block_id: String) -> Dictionary:
	if not _active.has(block_id):
		return CommandQueue.fail(&"E_NOT_DEVELOPING")
	var record: Dictionary = _active[block_id]
	var job: Dictionary = queue.job(int(record["job_id"]))
	if not job.is_empty() and int(job["work_units"]) > 0:
		return CommandQueue.fail(&"E_MID_PHASE")
	record["paused"] = true
	if not job.is_empty() and int(job["work_units"]) == 0:
		queue.cancel(int(record["job_id"]))  # never started: full refund
		record["job_id"] = 0
	_events.append({"type": &"development_paused", "block": block_id})
	return CommandQueue.ok()


func resume_development(block_id: String) -> Dictionary:
	if not _active.has(block_id):
		return CommandQueue.fail(&"E_NOT_DEVELOPING")
	var record: Dictionary = _active[block_id]
	if not bool(record["paused"]):
		return CommandQueue.fail(&"E_NOT_PAUSED")
	record["paused"] = false
	if int(record["job_id"]) == 0:
		return _submit_phase(block_id)
	return CommandQueue.ok()


## Mid-phase cancel forfeits the phase (doc 09 §2.3); queue refund rules apply.
func cancel_development(block_id: String) -> Dictionary:
	if not _active.has(block_id):
		return CommandQueue.fail(&"E_NOT_DEVELOPING")
	var record: Dictionary = _active[block_id]
	var refund := 0.0
	if int(record["job_id"]) != 0:
		var cancelled := queue.cancel(int(record["job_id"]))
		if bool(cancelled["ok"]):
			refund = float(cancelled["payload"]["refund_fraction"])
	var block := world.block(block_id)
	# Completed phases are kept: the block re-enters at the next phase later.
	block.development_state = &"UNDEVELOPED" if int(record["phase_index"]) == 0 \
			else PHASES[int(record["phase_index"]) - 1]
	_active.erase(block_id)
	return CommandQueue.ok({"refund_fraction": refund,
			"resume_at_phase": int(record["phase_index"])})


func active_phase(block_id: String) -> StringName:
	if not _active.has(block_id):
		return &""
	return PHASES[int(_active[block_id]["phase_index"])]


func serialize() -> Dictionary:
	var active := {}
	for block_id in _active:
		active[block_id] = (_active[block_id] as Dictionary).duplicate()
	return {"blocks_developed": blocks_developed, "active": active}


func deserialize(data: Dictionary) -> void:
	blocks_developed = int(data.get("blocks_developed", 0))
	_active.clear()
	for block_id in data.get("active", {}):
		_active[block_id] = data["active"][block_id]
