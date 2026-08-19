class_name ConstructionQueue
extends RefCounted
## The project queue (doc 02 §2.13, gap G-2 three-way split): this class owns
## the project record and its progress; doc 06 owns crews as dispatchable
## units (bindings only here); docs 09/10 submit their jobs into this queue.
## Progress is an exact integer accumulator — never a float.

const WORK_UNITS_PER_CREW_HOUR: int = 100
## crew_pm × site_pm × eff_pm × dt_gs accumulates here; one work unit equals
## 1000×1000×1000 (permille³) × 3600 (gs/h) / 100 (units per crew-hour).
const UNIT_DENOMINATOR: int = 36_000_000_000

const KINDS := [&"build", &"upgrade", &"repair", &"rebuild", &"clear_rubble", &"road", &"development"]

var next_job_id: int = 1
var _jobs: Dictionary = {}  # job_id -> job Dictionary
var _pending_order: Array = []  # job_ids without crews, player-reorderable


static func max_crews_for(required_crew_hours: float) -> int:
	return clampi(1 + int(required_crew_hours / 20.0), 1, 4)


## Validation of upgrade preconditions happens in UpgradeGate before submit;
## the queue records and progresses jobs. Charging is doc 03's, on submit.
func submit(kind: StringName, target_ref: String, required_crew_hours: float,
		crew_type: StringName = &"construction_crew", payload: Dictionary = {}) -> int:
	assert(KINDS.has(kind), "unknown job kind: " + String(kind))
	var job_id := next_job_id
	next_job_id += 1
	_jobs[job_id] = {
		"job_id": job_id, "kind": kind, "target_ref": target_ref,
		"required_work_units": roundi(required_crew_hours * WORK_UNITS_PER_CREW_HOUR),
		"required_crew_hours": required_crew_hours,
		"work_units": 0, "carry": 0,
		"crew_type": crew_type, "assigned_crews": {},  # crew_id -> rate_permille
		"site_mult_permille": 1000,
		"blocked_reason": "", "payload": payload,
	}
	_pending_order.append(job_id)
	return job_id


func job(job_id: int) -> Dictionary:
	return _jobs.get(job_id, {})


func progress(job_id: int) -> float:
	var j: Dictionary = _jobs.get(job_id, {})
	if j.is_empty():
		return 0.0
	return float(int(j["work_units"])) / maxf(1.0, float(int(j["required_work_units"])))


## Every live job in ascending job_id order — the deterministic read path for
## observers (progress pulses, UI listings) that must never touch _jobs.
func active_jobs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var ids := _jobs.keys()
	ids.sort()
	for job_id in ids:
		out.append(_jobs[job_id])
	return out


func pending_order() -> Array:
	return _pending_order.duplicate()


func active_count() -> int:
	return _jobs.size()


## Player-facing reordering (doc 12). Running jobs keep their crews; only the
## pending order changes.
func reorder(job_id: int, new_index: int) -> bool:
	var current := _pending_order.find(job_id)
	if current < 0:
		return false
	_pending_order.remove_at(current)
	_pending_order.insert(clampi(new_index, 0, _pending_order.size()), job_id)
	return true


## Crew binding — doc 06 assigns; this is a binding, not ownership.
func assign_crew(job_id: int, crew_id: String, rate_permille: int = 1000) -> Dictionary:
	var j: Dictionary = _jobs.get(job_id, {})
	if j.is_empty():
		return CommandQueue.fail(&"E_UNKNOWN_JOB")
	var crews: Dictionary = j["assigned_crews"]
	if crews.size() >= max_crews_for(float(j["required_crew_hours"])):
		return CommandQueue.fail(&"E_MAX_CREWS")
	var was_pending := crews.is_empty()
	crews[crew_id] = rate_permille
	j["blocked_reason"] = ""
	var events: Array = []
	if was_pending:
		_pending_order.erase(job_id)
		events.append({"type": &"job_started", "job_id": job_id,
				"target_ref": j["target_ref"]})
	return CommandQueue.ok({"events": events})


## Crew preemption (doc 06, priority 400): progress is never lost, only paused.
func release_crew(job_id: int, crew_id: String, reason: String = "") -> void:
	var j: Dictionary = _jobs.get(job_id, {})
	if j.is_empty():
		return
	(j["assigned_crews"] as Dictionary).erase(crew_id)
	if (j["assigned_crews"] as Dictionary).is_empty():
		j["blocked_reason"] = reason if reason != "" else "no_crew"
		if not _pending_order.has(job_id):
			_pending_order.append(job_id)


func set_site_mult(job_id: int, site_mult: float) -> void:
	var j: Dictionary = _jobs.get(job_id, {})
	if not j.is_empty():
		j["site_mult_permille"] = roundi(clampf(site_mult, 0.0, 4.0) * 1000.0)


## §2.10 refund table; doc 03 converts the fraction to dollars.
func cancel(job_id: int) -> Dictionary:
	var j: Dictionary = _jobs.get(job_id, {})
	if j.is_empty():
		return CommandQueue.fail(&"E_UNKNOWN_JOB")
	var refund: float
	if int(j["work_units"]) == 0 and (j["assigned_crews"] as Dictionary).is_empty():
		refund = 1.00  # planned, never started
	elif j["kind"] == &"upgrade":
		refund = 0.50
	else:
		refund = 0.60 * (1.0 - progress(job_id))
	_jobs.erase(job_id)
	_pending_order.erase(job_id)
	return CommandQueue.ok({"refund_fraction": refund,
			"events": [{"type": &"job_cancelled", "job_id": job_id,
					"refund_fraction": refund}]})


## Advance every crewed job by one step; ctx.channels_hour.construction_rate is
## mandatory (report 98 C-29). Returns completed jobs in ascending-id order.
func advance(ctx: TimeContext) -> Array[Dictionary]:
	var eff_permille := 1000
	if ctx.channels_hour.has("construction_rate"):
		eff_permille = roundi(float(ctx.channels_hour["construction_rate"]) * 1000.0)
	var completed: Array[Dictionary] = []
	var ids := _jobs.keys()
	ids.sort()
	for job_id in ids:
		var j: Dictionary = _jobs[job_id]
		var crews: Dictionary = j["assigned_crews"]
		if crews.is_empty():
			continue
		var crew_permille := 0
		for crew_id in crews:
			crew_permille += int(crews[crew_id])
		# Full product stays well inside int64 (≤ 4000×4000×2000×3600 ≈ 1.2e14),
		# so no early division — truncation there would break the exact
		# fine/coarse equivalence for non-round crew rates.
		var num: int = crew_permille * int(j["site_mult_permille"]) * eff_permille \
				* ctx.dt_game_seconds + int(j["carry"])
		j["work_units"] = int(j["work_units"]) + num / UNIT_DENOMINATOR
		j["carry"] = num % UNIT_DENOMINATOR
		if int(j["work_units"]) >= int(j["required_work_units"]):
			completed.append(j)
	for j in completed:
		_jobs.erase(int(j["job_id"]))
		_pending_order.erase(int(j["job_id"]))
	return completed


func serialize() -> Dictionary:
	var jobs: Array = []
	var ids := _jobs.keys()
	ids.sort()
	for job_id in ids:
		jobs.append((_jobs[job_id] as Dictionary).duplicate(true))
	return {"section_version": 1, "next_job_id": next_job_id, "jobs": jobs,
			"pending_order": _pending_order.duplicate()}


func deserialize(data: Dictionary) -> void:
	_jobs.clear()
	for j in data.get("jobs", []):
		_jobs[int(j["job_id"])] = j
	next_job_id = int(data.get("next_job_id", 1))
	_pending_order.clear()
	for job_id in data.get("pending_order", []):
		_pending_order.append(int(job_id))
