class_name Incident
extends RefCounted
## One incident (doc 06 §2.2). Data + the derived quantities that are pure
## functions of it; every rate lives in IncidentSystem, every consequence in
## CascadeOps. `severity` is continuous, `tier` is derived — never stored twice.
##
## Times are game-hours since founding as floats; the save schema's *_min
## fields are derived on serialize so a save reads like doc 06 §3.3.

const STATUS_NEW := "NEW"
const STATUS_QUEUED := "QUEUED"
const STATUS_ASSIGNED := "ASSIGNED"
const STATUS_ACTIVE := "ACTIVE"
const STATUS_RESOLVED := "RESOLVED"
const STATUS_FAILED := "FAILED"
const STATUS_ABANDONED := "ABANDONED"

const TERMINAL := [STATUS_RESOLVED, STATUS_FAILED, STATUS_ABANDONED]

var id: int = 0
var type: String = ""
var subtype: String = ""
var tile := Vector2i.ZERO
var district_id: String = ""
var target_ref: Dictionary = {}
var cluster_id: int = 0
var parent_id: int = 0

var severity: float = 1.0
var progress: float = 0.0
var status: String = STATUS_NEW
var burn_timer_h: float = 0.0
## Time held at the terminal tier, for the `hold_tier` / `hold_h` fail rule.
var hold_h: float = 0.0
var tier_peak: int = 1

var created_h: float = 0.0
var first_assign_h: float = -1.0
var first_onscene_h: float = -1.0
var resolved_h: float = -1.0

## unit_id -> {role, state, eta_h, manual}
var assigned: Dictionary = {}
var tiers_fired: Array = []
var cause: Dictionary = {}
var pinned: bool = false
var manual_requested: bool = false
var unreachable: bool = false
var seen: bool = false
var priority_cache: float = 0.0
var notification_priority: int = 3
## Set once when the incident is created; only fire uses it (S_req anchor).
var required_rate_cache: float = 0.0
var work_required_cache: float = 0.0
## Extra per-incident context the generator captured (injury flag, zone id,
## feeder id, storm subtype inputs…). Persisted verbatim.
var context: Dictionary = {}


func _init(p_id: int = 0, p_type: String = "", p_subtype: String = "") -> void:
	id = p_id
	type = p_type
	subtype = p_subtype


func tier() -> int:
	return clampi(int(floor(severity)), 1, 5)


func is_terminal() -> bool:
	return TERMINAL.has(status)


func is_active() -> bool:
	return status == STATUS_ACTIVE


## Doc 06 §2.2: QUEUED and ASSIGNED escalate at full rate; ACTIVE escalates at
## the suppressed rate; only ACTIVE accumulates progress.
func accumulates_progress() -> bool:
	return status == STATUS_ACTIVE


func key() -> String:
	return subtype if subtype != "" else type


func centre_m() -> Vector2:
	return Vector2(float(tile.x) * 8.0 + 4.0, float(tile.y) * 8.0 + 4.0)


func wait_hours(now_h: float) -> float:
	return maxf(0.0, now_h - created_h)


func response_minutes() -> float:
	if first_onscene_h < 0.0:
		return -1.0
	return (first_onscene_h - created_h) * 60.0


func on_scene_unit_ids() -> Array:
	var out: Array = []
	for unit_id in _sorted_int_keys(assigned):
		if String(assigned[unit_id].get("state", "")) == "ON_SCENE":
			out.append(unit_id)
	return out


func assigned_unit_ids() -> Array:
	return _sorted_int_keys(assigned)


func has_role_on_scene(role: String) -> bool:
	for unit_id in assigned:
		var record: Dictionary = assigned[unit_id]
		if String(record.get("state", "")) == "ON_SCENE" and String(record.get("role", "")) == role:
			return true
	return false


func target_building_id() -> String:
	if String(target_ref.get("kind", "")) == "building":
		return String(target_ref.get("id", ""))
	return ""


func target_component_id() -> String:
	var kind := String(target_ref.get("kind", ""))
	if kind == "power_component" or kind == "feeder":
		return String(target_ref.get("id", ""))
	return ""


# ------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	var assigned_rows: Array = []
	for unit_id in _sorted_int_keys(assigned):
		var record: Dictionary = assigned[unit_id]
		assigned_rows.append({
			"unit_id": unit_id, "role": String(record.get("role", "")),
			"state": String(record.get("state", "")),
			"eta_h": float(record.get("eta_h", 0.0)),
			"manual": bool(record.get("manual", false)),
		})
	var tiers: Array = []
	for t in tiers_fired:
		tiers.append(int(t))
	return {
		"id": id, "type": type, "subtype": subtype,
		"tile": [tile.x, tile.y], "district_id": district_id,
		"target_ref": target_ref.duplicate(true),
		"cluster_id": cluster_id, "parent_id": parent_id,
		"severity": severity, "progress": progress, "status": status,
		"burn_timer_h": burn_timer_h, "hold_h": hold_h, "tier_peak": tier_peak,
		"created_h": created_h, "first_assign_h": first_assign_h,
		"first_onscene_h": first_onscene_h, "resolved_h": resolved_h,
		"created_min": int(round(created_h * 60.0)),
		"first_assign_min": int(round(first_assign_h * 60.0)),
		"first_onscene_min": int(round(first_onscene_h * 60.0)),
		"resolved_min": int(round(resolved_h * 60.0)),
		"assigned": assigned_rows, "tiers_fired": tiers,
		"cause": cause.duplicate(true), "context": context.duplicate(true),
		"pinned": pinned, "manual_requested": manual_requested,
		"unreachable": unreachable, "seen": seen,
		"priority_cache": priority_cache,
		"notification_priority": notification_priority,
	}


static func deserialize(data: Dictionary) -> Incident:
	var inc := Incident.new(int(data.get("id", 0)), String(data.get("type", "")),
			String(data.get("subtype", "")))
	var tile_data: Array = data.get("tile", [0, 0])
	inc.tile = Vector2i(int(tile_data[0]), int(tile_data[1]))
	inc.district_id = String(data.get("district_id", ""))
	inc.target_ref = data.get("target_ref", {})
	inc.cluster_id = int(data.get("cluster_id", 0))
	inc.parent_id = int(data.get("parent_id", 0))
	inc.severity = float(data.get("severity", 1.0))
	inc.progress = float(data.get("progress", 0.0))
	inc.status = String(data.get("status", STATUS_QUEUED))
	inc.burn_timer_h = float(data.get("burn_timer_h", 0.0))
	inc.hold_h = float(data.get("hold_h", 0.0))
	inc.tier_peak = int(data.get("tier_peak", 1))
	inc.created_h = float(data.get("created_h", 0.0))
	inc.first_assign_h = float(data.get("first_assign_h", -1.0))
	inc.first_onscene_h = float(data.get("first_onscene_h", -1.0))
	inc.resolved_h = float(data.get("resolved_h", -1.0))
	inc.assigned.clear()
	for row in data.get("assigned", []):
		inc.assigned[int(row["unit_id"])] = {
			"role": String(row.get("role", "")), "state": String(row.get("state", "")),
			"eta_h": float(row.get("eta_h", 0.0)), "manual": bool(row.get("manual", false)),
		}
	inc.tiers_fired.clear()
	for t in data.get("tiers_fired", []):
		inc.tiers_fired.append(int(t))
	inc.cause = data.get("cause", {})
	inc.context = data.get("context", {})
	inc.pinned = bool(data.get("pinned", false))
	inc.manual_requested = bool(data.get("manual_requested", false))
	inc.unreachable = bool(data.get("unreachable", false))
	inc.seen = bool(data.get("seen", false))
	inc.priority_cache = float(data.get("priority_cache", 0.0))
	inc.notification_priority = int(data.get("notification_priority", 3))
	return inc


static func _sorted_int_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
