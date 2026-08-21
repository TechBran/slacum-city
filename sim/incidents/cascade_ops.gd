class_name CascadeOps
extends RefCounted
## The declarative cascade verbs (doc 06 §3.1, constitution §8: cascades are
## data, not `if type == FIRE` branches). Each verb is one small handler;
## adding a cascade never requires new incident code.
##
## Two verbs — `destroy_building` and `feeder_destroy` — are IRREVERSIBLE and
## both open with an explicit `world.destroy_allowed()` check (C-47). The point
## of the guard is that the refusal is VISIBLE: a REFUSED result, an event and
## a history entry, rather than being swallowed by doc 08's OfflineGuard at a
## lower layer where neither the player nor a test can see it.

const DONE := "DONE"
const REFUSED := "REFUSED"
const SKIPPED := "SKIPPED"

const OP_NAMES := [
	"district_stability", "city_confidence", "spawn_incident", "set_district_flag",
	"building_condition", "destroy_building", "feeder_load_shed", "feeder_offline",
	"feeder_destroy", "zone_pressure_delta", "edge_speed_mult", "edge_close",
	"population_delta", "notify",
]

var world: IncidentWorld
var catalog: IncidentCatalog
var system  # IncidentSystem — untyped, avoids a cyclic class_name pair


func _init(p_world: IncidentWorld, p_catalog: IncidentCatalog, p_system) -> void:
	world = p_world
	catalog = p_catalog
	system = p_system


## Run an ordered action list. Returns one result row per action so a test can
## assert the refusal path fired exactly once.
func run(inc: Incident, actions: Array) -> Array:
	var results: Array = []
	for action in actions:
		results.append(run_one(inc, action))
	return results


func run_one(inc: Incident, action: Dictionary) -> Dictionary:
	var op := String(action.get("op", ""))
	if not OP_NAMES.has(op):
		return {"op": op, "result": SKIPPED, "reason": "unknown_op"}
	var chance := float(action.get("chance", 1.0))
	if chance < 1.0:
		var chance_roll: float = system.roll_unit("incidents")
		if chance_roll >= chance:
			return {"op": op, "result": SKIPPED, "reason": "chance"}
	match op:
		"district_stability":
			if inc.district_id != "":
				world.apply_district_stability(inc.district_id, float(action.get("value", 0.0)))
			return {"op": op, "result": DONE}
		"city_confidence":
			world.apply_city_confidence(float(action.get("value", 0.0)))
			return {"op": op, "result": DONE}
		"set_district_flag":
			if inc.district_id != "":
				world.set_district_flag(inc.district_id, String(action.get("flag", "")),
						float(action.get("value", 1.0)), float(action.get("duration_h", 0.0)))
			return {"op": op, "result": DONE}
		"building_condition":
			var building_id := inc.target_building_id()
			if building_id == "":
				return {"op": op, "result": SKIPPED, "reason": "no_building_target"}
			if action.has("floor"):
				world.set_building_condition_floor(building_id, float(action["floor"]))
			else:
				world.apply_building_damage(building_id, -float(action.get("value", 0.0)))
			return {"op": op, "result": DONE}
		"destroy_building":
			return _destroy_building(inc, action)
		"feeder_load_shed":
			var component := inc.target_component_id()
			if component == "":
				return {"op": op, "result": SKIPPED, "reason": "no_component_target"}
			world.power_feeder_load_shed(component, float(action.get("fraction", 0.0)))
			return {"op": op, "result": DONE}
		"feeder_offline":
			var component2 := inc.target_component_id()
			if component2 == "":
				return {"op": op, "result": SKIPPED, "reason": "no_component_target"}
			world.power_feeder_offline(component2)
			return {"op": op, "result": DONE}
		"feeder_destroy":
			return _feeder_destroy(inc, action)
		"zone_pressure_delta":
			world.water_zone_pressure_delta(String(inc.context.get("zone", "")),
					float(action.get("value", 0.0)), inc.target_segment_id())
			return {"op": op, "result": DONE}
		"edge_speed_mult":
			world.road_set_edge_speed_mult(inc.tile, float(action.get("value", 1.0)))
			return {"op": op, "result": DONE}
		"edge_close":
			# The cause is the incident, unless the row names one: doc 10's
			# closure table prices a flooded street and a wrecked one
			# differently, and only doc 06 knows which this is.
			world.road_close_edge(inc.tile, float(action.get("duration_h", 0.0)),
					String(action.get("cause",
							inc.subtype if inc.subtype != "" else inc.type)))
			return {"op": op, "result": DONE}
		"population_delta":
			var building_id2 := inc.target_building_id()
			if building_id2 == "":
				return {"op": op, "result": SKIPPED, "reason": "no_building_target"}
			world.apply_population_loss(building_id2, float(action.get("fraction", 0.0)))
			return {"op": op, "result": DONE}
		"notify":
			inc.notification_priority = int(action.get("priority", inc.notification_priority))
			system.emit_event("incident_notify", {"incident_id": inc.id,
					"priority": inc.notification_priority, "tier": inc.tier()})
			return {"op": op, "result": DONE}
		"spawn_incident":
			return _spawn_incident(inc, action)
	return {"op": op, "result": SKIPPED}


# --------------------------------------------------------------- guarded ops

func _destroy_building(inc: Incident, _action: Dictionary) -> Dictionary:
	var target := inc.target_building_id()
	if target == "":
		return {"op": "destroy_building", "result": SKIPPED, "reason": "no_building_target"}
	if not world.destroy_allowed():
		world.clamp_building_condition_max(target,
				catalog.global_value("offline_destroy_clamp_condition", 0.15))
		# Frozen AT the threshold: it does not re-arm, so the verb cannot fire
		# again every sub-step for the rest of the absence.
		inc.burn_timer_h = float(system.burn_down_hours(inc))
		system.emit_event("destroy_refused_offline", {"incident_id": inc.id,
				"target": target, "reason": "offline"})
		return {"op": "destroy_building", "result": REFUSED}
	world.destroy_building(target, "incident:%d" % inc.id)
	system.emit_event("building_destroyed_by_fire", {"incident_id": inc.id, "target": target})
	return {"op": "destroy_building", "result": DONE}


func _feeder_destroy(inc: Incident, _action: Dictionary) -> Dictionary:
	var target := inc.target_component_id()
	if target == "":
		return {"op": "feeder_destroy", "result": SKIPPED, "reason": "no_component_target"}
	if not world.destroy_allowed():
		world.power_clamp_condition_max(target,
				catalog.global_value("offline_destroy_clamp_condition", 0.15))
		inc.burn_timer_h = float(system.burn_down_hours(inc))
		system.emit_event("destroy_refused_offline", {"incident_id": inc.id,
				"target": target, "reason": "offline"})
		return {"op": "feeder_destroy", "result": REFUSED}
	world.power_feeder_destroy(target)
	system.emit_event("power_component_destroyed", {"incident_id": inc.id, "target": target})
	return {"op": "feeder_destroy", "result": DONE}


# ------------------------------------------------------------------- spawns

## **The verb that turned a bounded roster into a branching process** (doc 06
## §2.13(b), doc 92 §31). `crime` spawns one child at tier 4 and two more at
## tier 5, so an unanswered crime has a mean offspring of **three** — and three
## children per parent is supercritical no matter how briefly each parent lives.
## RR-26 bounds LIFETIME; §2.13(b) is what bounds FERTILITY, and it does it in
## the two places a cascade can be wrong:
##
## 1. **The roster ceiling** (`system.spawn_automatic`). A cascade child is an
##    automatic birth like any other, so it stops at §2.13(b)'s AUTOMATIC ceiling
##    — the roster bound less the slots reserved for doc 04's own one-shot events
##    — and the refusal comes back as a `SKIPPED` row rather than a silent `null`
##    so a test can see it.
## 2. **A cascade may not invent a subject the GENERATOR would not have found.**
##    Doc 92 §18 states this for the ambient floor — *"λ_natural ≤ 0 means the
##    channel scanned and found no eligible candidate … it changes how OFTEN,
##    never WHERE"* — and `district_random_building` / `nearest_building` already
##    obey it by returning `""`. `scope: "district"` did not, because it needs no
##    entity at all: a target-less crime in a district with no residents is a
##    token, not an incident, and the measured cascade was made of 89,055 of them
##    in a district whose population had been zero since its first game-hour.
func _spawn_incident(inc: Incident, action: Dictionary) -> Dictionary:
	var count := int(action.get("count", 1))
	var type_id := String(action.get("type", inc.type))
	var subtype := String(action.get("subtype", ""))
	var scope := String(action.get("scope", "self"))
	var severity_0 := float(action.get("severity_0", 1.0))
	var spawned: Array = []
	var refused := 0
	for i in count:
		if system.saturated():
			refused += 1
			continue
		var target_ref: Dictionary = {}
		var tile := inc.tile
		match scope:
			"self":
				target_ref = inc.target_ref.duplicate(true)
			"district":
				if not _district_can_host(inc, type_id):
					continue
				target_ref = {}
			"adjacent_edge":
				target_ref = {}
			"district_random_building", "nearest_building":
				var building_id := _pick_building(inc, scope)
				if building_id == "":
					continue
				target_ref = {"kind": "building", "id": building_id}
				tile = world.building(building_id).get("tile", inc.tile)
		var child: Incident = system.spawn_automatic(type_id, subtype, tile, target_ref,
				severity_0, {"source": inc.type, "source_id": inc.id, "cascade": true})
		if child != null:
			child.parent_id = inc.id
			child.cluster_id = inc.cluster_id
			spawned.append(child.id)
	if spawned.is_empty() and refused > 0:
		return {"op": "spawn_incident", "result": SKIPPED, "reason": "saturated"}
	return {"op": "spawn_incident", "result": DONE, "spawned": spawned}


## The eligibility test the type's own GENERATOR applies, asked on behalf of a
## district-scoped cascade. Only `crime` has one that a district can fail —
## doc 06 §2.6(a) skips a district with no residents, so a crime cascade in an
## emptied district is a crime with nobody to commit it. Every other type is
## per-asset and its `district` scope is unrestricted, exactly as before.
func _district_can_host(inc: Incident, type_id: String) -> bool:
	if type_id != "crime":
		return true
	if inc.district_id == "":
		return false
	return float(world.district(inc.district_id).get("population", 0)) > 0.0


func _pick_building(inc: Incident, scope: String) -> String:
	if scope == "nearest_building":
		var best := ""
		var best_distance := 1 << 30
		for building_id in world.building_ids():
			var b := world.building(String(building_id))
			if world.state_fire_mult(String(building_id)) <= 0.0:
				continue
			var tile: Vector2i = b.get("tile", Vector2i.ZERO)
			var distance := maxi(absi(tile.x - inc.tile.x), absi(tile.y - inc.tile.y))
			if distance < best_distance:
				best_distance = distance
				best = String(building_id)
		return best
	# district_random_building — weighted only by eligibility, drawn from the
	# incidents stream (this is a cascade, not the crime generator's C-45 pick).
	var candidates: Array = []
	for building_id in world.building_ids():
		var b2 := world.building(String(building_id))
		if String(b2.get("district_id", "")) != inc.district_id:
			continue
		if world.state_fire_mult(String(building_id)) <= 0.0:
			continue
		candidates.append(String(building_id))
	if candidates.is_empty():
		return ""
	var roll: float = system.roll_unit("incidents")
	var index := int(floor(roll * float(candidates.size())))
	return String(candidates[clampi(index, 0, candidates.size() - 1)])
