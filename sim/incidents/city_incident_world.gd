class_name CityIncidentWorld
extends IncidentWorld
## The live CitySim adapter for doc 06's cross-system seam. This is the ONLY
## file in `sim/incidents/` that knows PowerGrid, Building, DistrictRegistry or
## Treasury exist — the incident engine itself talks to `IncidentWorld` and
## nothing else, which is what let doc 06 land before docs 05, 07 and 10.
##
## `sim` is held UNTYPED so that CitySim gaining an `IncidentSystem` member can
## never turn this into a cyclic class_name pair.
##
## Where a sibling system has not landed yet the method returns its documented
## neutral value and says so in a comment — never a doc-06-authored guess.

const STATION_ARCHETYPES := [
	"police_station", "fire_station", "substation", "power_facility",
	"water_facility", "construction_yard",
]

var sim  # CitySim
var catalog: IncidentCatalog
## Set by the phase adapter from `ctx.is_catchup`: the only path by which doc 06
## learns it is offline (doc 08 fairness rule 4 / C-47).
var offline: bool = false
## Doc 02 §2.4's `coverage_police(pos)` is not implemented yet (C-51); until it
## is, every district reports the same neutral coverage.
var default_police_coverage: float = 0.5
## Doc 05's hydrant network has not landed; nominal pressure until it does.
var default_hydrant_ratio: float = 1.0

## Recorded because CitySim has no city-confidence model yet — doc 06 supplies
## the delta, and the lead engineer wires it when doc 09's scalar exists.
var pending_confidence_delta: float = 0.0
var pending_population_losses: Array = []


func _init(p_sim, p_catalog: IncidentCatalog) -> void:
	sim = p_sim
	catalog = p_catalog


## Every station shell doc 02 owns, as `FleetSystem.populate_from_stations`
## wants it. Doc 06 supplies how many units live in each (C-50).
func station_rows() -> Array:
	var out: Array = []
	var ids: Array = sim.buildings.keys()
	ids.sort()
	for building_id in ids:
		var b: Building = sim.buildings[building_id]
		var archetype := String(b.archetype)
		if not STATION_ARCHETYPES.has(archetype):
			continue
		out.append({"id": String(building_id), "archetype": archetype,
				"level": maxi(1, b.level), "tile": b.origin})
	return out


# ---------------------------------------------------------------- doc 01 time

func destroy_allowed() -> bool:
	return not offline


func is_offline() -> bool:
	return offline


func now_minutes() -> int:
	return sim.clock.sim_time_minutes()


# ----------------------------------------------------------- doc 02 buildings

func building_ids() -> Array:
	var ids: Array = sim.buildings.keys()
	ids.sort()
	return ids


func building(id: String) -> Dictionary:
	var b: Building = sim.buildings.get(id, null)
	if b == null:
		return {}
	var stats: Dictionary = b.stats
	return {
		"id": id, "archetype": String(b.archetype), "level": b.level,
		"condition": b.condition, "state": String(b.state), "tile": b.origin,
		"powered": sim.grid.is_powered(id),
		"occupants": float(int(stats.get("population", 0))) * b.state_occupancy(),
		"fire_load": float(stats.get("fire_load", 0)),
		"fire_ignition_per_hour": float(stats.get("fire_ignition_per_hour", 0.0)),
		"crime_weight": float(stats.get("crime_weight", 0.0)),
		"district_id": district_of_tile(b.origin),
	}


func buildings_within_m(tile: Vector2i, radius_m: float, exclude_id: String = "") -> Array:
	var radius_tiles := radius_m / METRES_PER_TILE
	var out: Array = []
	for id in building_ids():
		if String(id) == exclude_id:
			continue
		var b: Building = sim.buildings[id]
		var delta := Vector2(float(b.origin.x - tile.x), float(b.origin.y - tile.y))
		if delta.length() <= radius_tiles:
			out.append(String(id))
	return out


## `fraction` is DAMAGE: a positive number lowers the condition by that much.
func apply_building_damage(id: String, fraction: float) -> void:
	var b: Building = sim.buildings.get(id, null)
	if b == null:
		return
	b.apply_damage(fraction, now_minutes())


func set_building_condition_floor(id: String, condition: float) -> void:
	var b: Building = sim.buildings.get(id, null)
	if b != null:
		b.condition = maxf(b.condition, condition)


func clamp_building_condition_max(id: String, condition: float) -> void:
	var b: Building = sim.buildings.get(id, null)
	if b != null:
		b.condition = minf(b.condition, condition)


func ignite_building(id: String) -> bool:
	var b: Building = sim.buildings.get(id, null)
	if b == null:
		return false
	return bool(b.ignite().get("ok", false))


func suppress_building_fire(id: String, residual_damage_fraction: float) -> void:
	var b: Building = sim.buildings.get(id, null)
	if b != null:
		b.suppress_fire(residual_damage_fraction)


func destroy_building(id: String, _cause: String) -> void:
	var b: Building = sim.buildings.get(id, null)
	if b == null:
		return
	# Building.burn_down carries the same C-47 guard; doc 06 has already checked
	# it, so this call only ever runs on the allowed branch.
	if b.state == &"on_fire":
		b.burn_down(destroy_allowed(), now_minutes())
	else:
		b.apply_damage(1.0, now_minutes())


# ------------------------------------------------------- doc 09 districts/pop

func district_ids() -> Array:
	return sim.districts.district_ids_sorted()


func district(id: String) -> Dictionary:
	var row: Dictionary = sim.districts.district(id)
	if row.is_empty():
		return {}
	return {
		"id": id,
		"population": float(row.get("population", 0)),
		"stability": clampf(float(row.get("stability", 1.0)), 0.0, 1.0),
		"police_coverage": default_police_coverage,
		"outage_frac": clampf(float(row.get("district_dark_fraction", 0.0)), 0.0, 1.0),
	}


func district_of_tile(tile: Vector2i) -> String:
	var block: LandBlock = sim.world.block_of_tile(tile.x, tile.y)
	return "" if block == null else block.district_id


func apply_district_stability(id: String, delta: float) -> void:
	if id != "":
		sim.districts.apply_stability(id, delta)


func apply_city_confidence(delta: float) -> void:
	# Doc 09's city-confidence scalar does not exist yet; the delta is banked so
	# the lead engineer can drain it when it does.
	pending_confidence_delta += delta


func apply_population_loss(building_id: String, fraction: float) -> void:
	# Doc 09 owns population; there is no "kill N occupants" verb yet.
	pending_population_losses.append({"building": building_id, "fraction": fraction})


# ------------------------------------------------------------------ doc 04

## Doc 04 publishes no component enumerator yet, so the authored starter-city
## node list stands in. Swap this one body for `power.components_of_kind()`
## when doc 04 exposes it — nothing else changes.
func power_transformers() -> Array:
	var out: Array = []
	for node in sim.loader.power_nodes_of_kind("transformer"):
		var row := power_component(String(node.get("id", "")))
		if not row.is_empty():
			out.append(row)
	return out


func power_component(id: String) -> Dictionary:
	var c: Dictionary = sim.grid.component(id)
	if c.is_empty():
		return {}
	var capacity: float = maxf(1.0, sim.grid.cap_eff(id, 22.0))
	return {
		"id": id, "kind": String(c.get("kind", "")),
		"tile": c.get("tile", Vector2i.ZERO),
		"load_ratio": float(c.get("load_kw", 0.0)) / capacity,
		"condition": float(c.get("condition", 1.0)),
		"temp_c": 22.0 + float(c.get("theta_c", 0.0)),
		"state": String(c.get("state", "OK")),
		"redundancy": false,  # doc 04's tie table is not exposed per-node yet
		"customers_downstream": power_customers_downstream(id),
		"critical_downstream": _has_critical_downstream(id),
		"underground": bool(c.get("underground", false)),
	}


func power_customers_downstream(id: String) -> int:
	var count := 0
	for building_id in building_ids():
		if sim.grid.attachment_of(String(building_id)) == id:
			count += 1
	return count


func _has_critical_downstream(id: String) -> bool:
	for building_id in building_ids():
		if sim.grid.attachment_of(String(building_id)) != id:
			continue
		var b: Building = sim.buildings[building_id]
		if b.archetype == &"water_facility" or b.archetype == &"fire_station" \
				or b.archetype == &"police_station":
			return true
	return false


func power_feeder_load_shed(_id: String, _fraction: float) -> void:
	# Doc 04's shedding is system-wide (`_pass_b_supply_and_shed`) and exposes no
	# per-feeder entry point. Requested interface: `power.feeder_load_shed(id, f)`.
	pass


func power_feeder_offline(id: String) -> void:
	if not sim.grid.component(id).is_empty():
		sim.grid.force_open(id)


func power_feeder_destroy(id: String) -> void:
	if sim.grid.component(id).is_empty():
		return
	sim.grid.force_open(id)
	sim.grid.component(id)["condition"] = 0.0


func power_clamp_condition_max(id: String, condition: float) -> void:
	var c: Dictionary = sim.grid.component(id)
	if not c.is_empty():
		c["condition"] = minf(float(c.get("condition", 1.0)), condition)


## The verb the whole tutorial arc hangs on. Doc 06 says "this is fixed now";
## the adapter picks the doc 04 call that means that for this component state.
func power_restore_component(id: String) -> void:
	var c: Dictionary = sim.grid.component(id)
	if c.is_empty():
		return
	match String(c.get("state", "OK")):
		"FAILED":
			sim.grid.repair_component(id)
		"OPEN":
			sim.grid.force_close(id)
			c["reclose_attempts"] = 0
			c["trip_accum"] = 0.0
		_:
			pass


func power_fail_component(id: String, _cause: String) -> bool:
	if sim.grid.component(id).is_empty():
		return false
	# A relay lockout: open, and NOT scheduled to auto-reclose. Only a crew
	# closes it again, which is exactly the tutorial's shape.
	sim.grid.force_open(id)
	return true


func power_exposed_components() -> Array:
	var out: Array = []
	for line in sim.loader.power.get("lines", []):
		var id := String(line.get("id", ""))
		var c: Dictionary = sim.grid.component(id)
		if c.is_empty() or bool(c.get("underground", false)):
			continue
		var route: Array = c.get("route", [])
		var tile := Vector2i.ZERO
		if not route.is_empty():
			tile = Vector2i(int(route[0][0]), int(route[0][1]))
		out.append({"id": id, "tile": tile, "exposure_class": "overhead_span",
				"condition": float(c.get("condition", 1.0)), "underground": false})
	return out


# ------------------------------------------------------------------ doc 05

func hydrant_pressure_ratio(_tile: Vector2i) -> float:
	return default_hydrant_ratio


# ------------------------------------------------------------------ doc 03

func repair_cost(target_ref: Dictionary, damage_fraction: float) -> int:
	if damage_fraction <= 0.0:
		return 0
	match String(target_ref.get("kind", "")):
		"building":
			var b: Building = sim.buildings.get(String(target_ref.get("id", "")), null)
			if b == null:
				return 0
			return sim.econ_curves.repair_cost_building(String(b.archetype),
					maxi(1, b.level), damage_fraction)
		"power_component":
			var c: Dictionary = sim.grid.component(String(target_ref.get("id", "")))
			if c.is_empty():
				return 0
			var capital: int = sim.econ_curves.capital_value_grid(
					String(c.get("kind", "transformer")), int(c.get("level", 1)))
			return sim.econ_curves.repair_cost(capital, damage_fraction)
	return 0


func vehicle_dispatch_cost(vehicle_type: String) -> int:
	var economy_id := String(catalog.vehicle_type(vehicle_type).get("economy_id", vehicle_type))
	return int(sim.econ_curves.vehicle_row(economy_id).get("dispatch_cost", 0))


func credit(amount: int, reason: String) -> void:
	if amount > 0:
		sim.treasury.credit(amount, &"incident", reason)


func debit(amount: int, reason: String) -> bool:
	if amount <= 0:
		return true
	return bool(sim.treasury.spend(amount, &"incident", reason).get("ok", false))


func difficulty_escalation_mult() -> float:
	var rows: Dictionary = sim.treasury.difficulty()
	return float(rows.get("escalation_mult", 1.0))


# -------------------------------------------------------- doc 02 construction

func release_crew_from_job(job_id: int, crew_id: String) -> void:
	sim.construction.release_crew(job_id, crew_id, "preempted_by_incident")
