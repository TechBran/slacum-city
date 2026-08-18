class_name Building
extends RefCounted
## One building instance: the eight-state machine, condition/decay and the
## per-state behaviour modifiers (doc 02 §2.5, §2.6, §2.12). Transitions are
## validated here and returned as events; cross-system side effects (charges,
## crew binding, tile stamping) belong to the owning coordinator.

const STATES := [
	&"planned", &"under_construction", &"active", &"damaged",
	&"on_fire", &"repairing", &"destroyed",
]

const AUTO_DAMAGE_THRESHOLD := 0.35
const STRUCTURAL_FAILURE_THRESHOLD := 0.10
const STRUCTURAL_FAILURE_P_PER_H := 0.02
const MIN_CONDITION_TO_UPGRADE := 0.55
const REPAIR_TIME_FACTOR := 0.50
const REPAIR_TARGET_FROM_DAMAGED := 0.85
const REBUILD_GRACE_HOURS := 72

var id: int = 0
var archetype: StringName = &""
var variant: StringName = &""  # water_facility only
var level: int = 0  # 0 while a new build is in progress
var pending_level: int = 0  # target level while under_construction
var origin := Vector2i.ZERO
var state: StringName = &"planned"
var condition: float = 1.0
var built_at_minutes: int = 0
var destroyed_at_minutes: int = 0
var level_at_destruction: int = 0
## Stats row for the CURRENT level, supplied by BuildingCatalog via the
## coordinator on every level change. Keys per data/buildings.json.
var stats: Dictionary = {}


func _init(p_id: int = 0, p_archetype: StringName = &"", p_origin := Vector2i.ZERO,
		p_variant: StringName = &"") -> void:
	id = p_id
	archetype = p_archetype
	origin = p_origin
	variant = p_variant


func is_new_build() -> bool:
	return state == &"under_construction" and level == 0


func is_upgrade_in_progress() -> bool:
	return state == &"under_construction" and level >= 1


# ------------------------------------------------- per-state modifiers (§2.12)

func output_mult() -> float:
	match state:
		&"active": return 1.0
		&"under_construction": return 0.35 if level >= 1 else 0.0
		&"damaged", &"repairing": return 0.40
		_: return 0.0


func power_demand_mult() -> float:
	match state:
		&"active": return 1.0
		&"under_construction": return 1.0 if level >= 1 else 0.15
		&"damaged", &"repairing": return 0.50
		_: return 0.0


func water_demand_mult() -> float:
	match state:
		&"active": return 1.0
		&"under_construction": return 1.0 if level >= 1 else 0.10
		&"damaged", &"repairing": return 0.50
		_: return 0.0


func state_occupancy() -> float:
	match state:
		&"active": return 1.0
		&"under_construction": return 0.50 if level >= 1 else 0.0
		&"damaged", &"repairing": return 0.40
		_: return 0.0


func coverage_mult() -> float:
	match state:
		&"active": return 1.0
		&"under_construction": return 0.50 if level >= 1 else 0.0
		&"damaged", &"repairing": return 0.25
		_: return 0.0


func decays() -> bool:
	match state:
		&"active": return true
		&"under_construction": return level >= 1
		&"damaged": return true
		_: return false


func state_fire_mult() -> float:
	match state:
		&"under_construction": return 1.4
		&"damaged", &"repairing": return 1.8
		&"active": return 1.0
		_: return 0.0  # planned / destroyed / on_fire never (re-)ignite


# ------------------------------------------------------- condition (§2.6)

func fire_condition_mult() -> float:
	return 1.0 + 1.5 * pow(1.0 - condition, 1.5)


func damage_fraction() -> float:
	return clampf(1.0 - condition, 0.0, 1.0)


func repair_crew_hours() -> float:
	return float(stats.get("build_hours", 0.0)) * REPAIR_TIME_FACTOR * damage_fraction()


## One settled hour (or dt_h of them) of decay. `powered_fraction` is doc 04's
## power_availability_hour; `overload_excess` = max(0, load/capacity − 1) of
## the serving grid node; `weather_decay_mult` from doc 07 get_effect().
## Returns events (auto-damage transition).
func apply_decay(dt_h: float, overload_excess: float = 0.0, powered_fraction: float = 1.0,
		weather_decay_mult: float = 1.0) -> Array:
	if not decays():
		return []
	var rate := float(stats.get("decay_per_hour", 0.0)) \
			* (1.0 + 0.80 * maxf(0.0, overload_excess)) \
			* (1.0 + 0.50 * (1.0 - clampf(powered_fraction, 0.0, 1.0))) \
			* weather_decay_mult
	if state == &"damaged":
		rate *= 1.5  # §2.12 state table: damaged decays ×1.5
	condition = clampf(condition - rate * dt_h, 0.0, 1.0)
	var events: Array = []
	if state == &"active" and condition < AUTO_DAMAGE_THRESHOLD:
		state = &"damaged"
		events.append({"type": &"building_damaged", "building": id, "cause": &"decay"})
	return events


## Structural-failure roll (§2.6): below condition 0.10, 0.02/gh on the
## `failures` stream. Returns events; may transition damaged → destroyed.
func roll_structural_failure(rng: RngStreams, dt_h: float, now_minutes: int) -> Array:
	if state != &"damaged" or condition >= STRUCTURAL_FAILURE_THRESHOLD:
		return []
	var p := 1.0 - pow(1.0 - STRUCTURAL_FAILURE_P_PER_H, dt_h)
	if rng.stream("failures").randf() < p:
		return _destroy(now_minutes, &"structural_failure")
	return []


# ---------------------------------------------------- transitions (§2.12)

## planned → under_construction (crew assigned).
func start_construction() -> Dictionary:
	if state != &"planned":
		return CommandQueue.fail(&"E_STATE")
	state = &"under_construction"
	if pending_level == 0:
		pending_level = 1
	return CommandQueue.ok({"events": [{"type": &"job_started", "building": id}]})


## under_construction → active (progress complete).
func complete_construction() -> Dictionary:
	if state != &"under_construction":
		return CommandQueue.fail(&"E_STATE")
	level = pending_level if pending_level > 0 else 1
	pending_level = 0
	state = &"active"
	condition = 1.0
	return CommandQueue.ok({"events": [
		{"type": &"building_completed", "building": id, "level": level},
	]})


## active → under_construction with pending_level = L+1. The full §2.11 gate
## (funds, headroom, coverage…) runs in UpgradeGate; here only local checks.
func start_upgrade() -> Dictionary:
	if state != &"active":
		return CommandQueue.fail(&"E_STATE")
	if level >= 5:
		return CommandQueue.fail(&"E_MAX_LEVEL")
	if condition < MIN_CONDITION_TO_UPGRADE:
		return CommandQueue.fail(&"E_CONDITION")
	pending_level = level + 1
	state = &"under_construction"
	return CommandQueue.ok({"events": [{"type": &"upgrade_started", "building": id,
			"to_level": pending_level}]})


## Cancel an in-progress upgrade: building returns to level L, active,
## condition unchanged (refund fraction 0.50 per §2.10 — coordinator applies).
func cancel_upgrade() -> Dictionary:
	if not is_upgrade_in_progress():
		return CommandQueue.fail(&"E_STATE")
	pending_level = 0
	state = &"active"
	return CommandQueue.ok({"refund_fraction": 0.50})


## doc 06 FireStarted (ignition roll or spread).
func ignite() -> Dictionary:
	if state != &"active" and state != &"damaged" and state != &"under_construction":
		return CommandQueue.fail(&"E_STATE")
	state = &"on_fire"
	return CommandQueue.ok({"events": [{"type": &"building_ignited", "building": id}]})


## doc 06 FireSuppressed with the residual damage it computed.
func suppress_fire(residual_damage_fraction: float) -> Dictionary:
	if state != &"on_fire":
		return CommandQueue.fail(&"E_STATE")
	state = &"damaged"
	condition = clampf(1.0 - residual_damage_fraction, 0.0, 1.0)
	return CommandQueue.ok({"events": [{"type": &"building_damaged", "building": id,
			"cause": &"fire"}]})


## doc 06 BurnDown — guarded by world.destroy_allowed() (report 98 C-47):
## refused VISIBLY during offline catch-up, never silently swallowed.
func burn_down(destroy_allowed: bool, now_minutes: int) -> Dictionary:
	if state != &"on_fire":
		return CommandQueue.fail(&"E_STATE")
	if not destroy_allowed:
		condition = maxf(condition, 0.15)  # doc 08 clamp; incident stays open
		return CommandQueue.fail(&"E_DESTROY_SUPPRESSED_OFFLINE")
	return CommandQueue.ok({"events": _destroy(now_minutes, &"fire")})


## Incident/disaster damage arriving as a damage_fraction (one pricing path).
func apply_damage(fraction: float, now_minutes: int) -> Array:
	if state == &"destroyed" or state == &"planned":
		return []
	condition = clampf(condition - fraction, 0.0, 1.0)
	var events: Array = []
	if condition <= 0.0:
		events.append_array(_destroy(now_minutes, &"damage"))
	elif state == &"active" and condition < AUTO_DAMAGE_THRESHOLD:
		state = &"damaged"
		events.append({"type": &"building_damaged", "building": id, "cause": &"incident"})
	return events


## damaged/active → repairing. Target: 1.00 preventive from active,
## 0.85 after damage (post-damage repairs never restore to new).
func start_repair() -> Dictionary:
	if state != &"damaged" and state != &"active":
		return CommandQueue.fail(&"E_STATE")
	var target := 1.0 if state == &"active" else REPAIR_TARGET_FROM_DAMAGED
	state = &"repairing"
	return CommandQueue.ok({"repair_target": target,
			"crew_hours": repair_crew_hours()})


func complete_repair(repair_target: float) -> Dictionary:
	if state != &"repairing":
		return CommandQueue.fail(&"E_STATE")
	state = &"active"
	condition = maxf(condition, repair_target)
	return CommandQueue.ok({"events": [{"type": &"building_repaired", "building": id}]})


## Crew withdrawn or new damage mid-repair: partial progress kept upstream.
func interrupt_repair() -> Dictionary:
	if state != &"repairing":
		return CommandQueue.fail(&"E_STATE")
	state = &"damaged"
	return CommandQueue.ok()


## destroyed → planned. Within the grace window the rebuild is priced at the
## destroyed level (0.60 × build cost); after it, back to L1 (doc 02 §2.12).
func order_rebuild(now_minutes: int) -> Dictionary:
	if state != &"destroyed":
		return CommandQueue.fail(&"E_STATE")
	var within_grace := (now_minutes - destroyed_at_minutes) <= REBUILD_GRACE_HOURS * 60
	pending_level = level_at_destruction if within_grace else 1
	level = 0
	state = &"planned"
	return CommandQueue.ok({"within_grace": within_grace,
			"rebuild_level": pending_level,
			"cost_fraction": 0.60 if within_grace else 1.0})


func _destroy(now_minutes: int, cause: StringName) -> Array:
	state = &"destroyed"
	level_at_destruction = maxi(level, pending_level)
	destroyed_at_minutes = now_minutes
	condition = 0.0
	return [{"type": &"building_destroyed", "building": id, "cause": cause}]


# ------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	return {
		"id": id, "archetype": String(archetype), "variant": String(variant),
		"level": level, "pending_level": pending_level,
		"origin": [origin.x, origin.y], "state": String(state),
		"condition": condition, "built_at_minutes": built_at_minutes,
		"destroyed_at_minutes": destroyed_at_minutes,
		"level_at_destruction": level_at_destruction,
	}


static func deserialize(data: Dictionary) -> Building:
	var b := Building.new(int(data.get("id", 0)),
			StringName(String(data.get("archetype", ""))),
			Vector2i(int(data["origin"][0]), int(data["origin"][1])),
			StringName(String(data.get("variant", ""))))
	b.level = int(data.get("level", 0))
	b.pending_level = int(data.get("pending_level", 0))
	b.state = StringName(String(data.get("state", "planned")))
	b.condition = float(data.get("condition", 1.0))
	b.built_at_minutes = int(data.get("built_at_minutes", 0))
	b.destroyed_at_minutes = int(data.get("destroyed_at_minutes", 0))
	b.level_at_destruction = int(data.get("level_at_destruction", 0))
	return b
