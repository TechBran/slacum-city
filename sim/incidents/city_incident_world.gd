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
## Doc 05's hydrant network has not landed; nominal pressure until it does.
var default_hydrant_ratio: float = 1.0

## Doc 02 §2.9's coverage field (C-51), rebuilt from the live station roster.
## `CoverageIndex` is pure — this adapter is the half that knows what a
## `Building` and a `FleetSystem` are.
var coverage: CoverageIndex = null
## The game-hour the field was last rebuilt on, so the answer is stable inside
## one hour (the incident integrator asks per SUB-step) and is recomputed from
## live state after a load rather than being carried in the save. `-1` forces
## the first read to build.
var _coverage_hour: int = -1
var _district_coverage: Dictionary = {}  # district id -> {police, fire}

## Doc 06's fire generator scans the whole roster on every integrator sub-step.
## All of these are DERIVED and revision-keyed (see `fire_candidate_columns`):
## never captured, never restored, rebuilt from live state on the next ask.
var _fire_ids := PackedStringArray()
var _fire_states: Array = []
var _fire_condition := PackedFloat64Array()
var _fire_ignition := PackedFloat64Array()
var _fire_powered := PackedByteArray()
var _fire_district := PackedStringArray()
var _fire_revision: int = -1
var _district_by_building_memo: Dictionary = {}
var _district_memo_key := Vector2i(-1, -1)

## Recorded because CitySim has no city-confidence model yet — doc 06 supplies
## the delta, and the lead engineer wires it when doc 09's scalar exists.
var pending_confidence_delta: float = 0.0
var pending_population_losses: Array = []


func _init(p_sim, p_catalog: IncidentCatalog) -> void:
	sim = p_sim
	catalog = p_catalog
	# **C-46, closed here and only here.** Doc 05 rolls its own main breaks while
	# `external_main_breaks` is false, precisely so it is playable before doc 06
	# has a candidate source; the moment THIS adapter exists, `water_mains()`
	# answers and doc 06 owns the roll. One writer, one owner, and the file that
	# supplies the candidates is the one that claims them. (Audit 91 D-17 left
	# both sides believing the other was rolling: doc 06 scanned an empty array
	# and doc 05's fallback never stood down.)
	if sim != null and sim.water != null:
		sim.water.external_main_breaks = true


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

## The shell already keeps the roster in ascending id order and rebuilds it only
## when a building is added or removed, so this is the same Array it hands its
## own walks — read-only for every caller here, as it was when this method
## re-sorted 1,500 keys on each of the integrator's sub-steps.
func building_ids() -> Array:
	return sim.roster_ids()


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


# ------------------------------------------------- doc 02 §2.9 coverage (C-51)

## `coverage_police(tile)` / `coverage_fire(tile)`, both ∈ [0,1]. Doc 02 owns the
## formula; `CoverageIndex` is it, and this half assembles its inputs from the
## live roster.
func coverage_police(tile: Vector2i) -> float:
	return _coverage().coverage_at_tile(CoverageIndex.KIND_POLICE, tile)


func coverage_fire(tile: Vector2i) -> float:
	return _coverage().coverage_at_tile(CoverageIndex.KIND_FIRE, tile)


## The same answer with its reasons — `{coverage, best, best_id, overlapping,
## redundancy}` — for the §2.7 service tiles and the overlay's tap readout.
func coverage_explain(kind: StringName, tile: Vector2i) -> Dictionary:
	return _coverage().explain(kind, Vector2(float(tile.x), float(tile.y)))


## One district's coverage: the MEAN of `coverage_<kind>` over the buildings that
## district holds. Doc 09 owns `police_coverage` as a district scalar and doc 02
## publishes it per position, so the district figure is the average of the
## positions that district actually occupies — an empty district reads 0.
func district_coverage(district_id: String, kind: StringName) -> float:
	_coverage()
	var row: Variant = _district_coverage.get(district_id, null)
	return float((row as Dictionary).get(String(kind), 0.0)) if row is Dictionary else 0.0


## Force the field to be rebuilt on the next read. The hourly key already covers
## decay and dispatch; this is for the discrete events that move a station —
## a build, an upgrade, a demolition — which the shell knows about first.
func invalidate_coverage() -> void:
	_coverage_hour = -1


func _coverage() -> CoverageIndex:
	var hour := int(floor(float(now_minutes()) / 60.0))
	if coverage != null and _coverage_hour == hour:
		return coverage
	_rebuild_coverage()
	_coverage_hour = hour
	return coverage


## Rebuilt from the roster in ONE pass per kind. Sorted throughout: station rows
## come from `building_ids()` (already ascending) and `CoverageIndex` re-sorts
## them by id, so nothing here depends on Dictionary hashing.
func _rebuild_coverage() -> void:
	if coverage == null:
		coverage = CoverageIndex.new(sim.catalog.rules().get("coverage_ladder", {}))
	var rows: Array = []
	for building_id in building_ids():
		var id := String(building_id)
		var b: Building = sim.buildings[id]
		var kind: Variant = CoverageIndex.ARCHETYPE_KIND.get(String(b.archetype), null)
		if kind == null:
			continue
		var level := maxi(1, b.level)
		var stats: Dictionary = sim.catalog.stats(String(b.archetype), level)
		var radius := float(stats.get("coverage_radius_tiles", 0.0))
		if radius <= 0.0:
			continue
		rows.append({
			"id": id, "kind": StringName(str(kind)), "level": level,
			"centroid": _centroid(b.origin, stats.get("footprint", [1, 1])),
			"radius_tiles": radius,
			"staffing": _staffing(id, String(b.archetype), level),
			"condition": b.condition,
			# Doc 02 §2.9 writes the state term as `active ? 1 : 0`; the shipped
			# §2.12 table (`data/building_rules.json.state_modifiers.*.coverage`)
			# is finer — a station mid-upgrade still answers half its calls, a
			# damaged one a quarter — and `Building.coverage_mult()` IS that
			# column. The table is the narrower, later statement of the same rule.
			"state_mult": b.coverage_mult(),
		})
	coverage.set_stations(rows)
	_rebuild_district_coverage()


static func _centroid(origin: Vector2i, footprint: Variant) -> Vector2:
	var w := 1.0
	var h := 1.0
	if footprint is Array and (footprint as Array).size() >= 2:
		w = maxf(1.0, float((footprint as Array)[0]))
		h = maxf(1.0, float((footprint as Array)[1]))
	return Vector2(float(origin.x) + (w - 1.0) * 0.5, float(origin.y) + (h - 1.0) * 0.5)


## Doc 02 §2.9's `staffing(s) = min(1, units_housed(s) / capacity(s))`, with doc
## 06's `capacity_per_station_level` (C-50) as the denominator.
##
## **Ruling — what "housed" counts.** Doc 06 §2.11 says the station shell is doc
## 02's and doc 06 "supplies how many units live in it", so `units_housed` is the
## ROSTER, not the units standing in the bay: a station whose only engine is out
## on a call still covers its district, and the alternative reading would make
## coverage oscillate with every dispatch and feed the crime generator a signal
## that rises the moment police respond to crime. Units parked `OFFLINE` by doc
## 03's austerity layer are excluded — an unaffordable unit does not live
## anywhere. See the report's open questions.
func _staffing(station_id: String, archetype: String, level: int) -> float:
	if sim.incidents == null:
		return 0.0
	var fleet: FleetSystem = sim.incidents.fleet
	if fleet == null:
		return 0.0
	var capacity := 0
	for type_id in catalog.vehicle_types_for_station(archetype):
		capacity += fleet.capacity_for(archetype, String(type_id), level)
	if capacity <= 0:
		return 0.0
	var housed := 0
	for unit_id in fleet.unit_ids():
		var u: Vehicle = fleet.unit(int(unit_id))
		if u != null and u.home_station_id == station_id and u.status != Vehicle.OFFLINE:
			housed += 1
	return minf(1.0, float(housed) / float(capacity))


func _rebuild_district_coverage() -> void:
	var totals: Dictionary = {}
	var district_by_id := _district_by_building()
	for building_id in building_ids():
		var b: Building = sim.buildings[String(building_id)]
		var district_id: String = district_by_id[String(building_id)]
		if district_id == "":
			continue
		var row: Variant = totals.get(district_id)
		var record: Dictionary
		if row == null:
			record = {"police": 0.0, "fire": 0.0, "count": 0}
			totals[district_id] = record
		else:
			record = row
		var pos := Vector2(float(b.origin.x), float(b.origin.y))
		record["police"] = float(record["police"]) \
				+ coverage.coverage(CoverageIndex.KIND_POLICE, pos)
		record["fire"] = float(record["fire"]) \
				+ coverage.coverage(CoverageIndex.KIND_FIRE, pos)
		record["count"] = int(record["count"]) + 1
	var out: Dictionary = {}
	var ids: Array = totals.keys()
	ids.sort()
	for district_id: String in ids:
		var record: Dictionary = totals[district_id]
		var count := maxf(1.0, float(record["count"]))
		out[district_id] = {
			"police": float(record["police"]) / count,
			"fire": float(record["fire"]) / count,
		}
	_district_coverage = out


## Six fields instead of `building()`'s twelve. The fire generator asks for the
## whole roster on every sub-step, and the six it drops are the expensive half
## (catalog stats, occupancy, the crime weight).
##
## The COLUMNS are refilled, not rebuilt: at 1,500 buildings and a dozen
## integrator sub-steps an hour, the row form allocated 18,000 six-key
## dictionaries a game-hour and then charged the generator a Dictionary lookup
## for each of the six numbers. The buffers are re-sized only when the roster
## itself changes (`CitySim.roster_revision`), so they are derived state in the
## same sense the water demand cache is — nothing here survives a save, and a
## load re-derives them on the next ask. `IncidentSystem._generate_structure_fire`
## is the only caller and keeps no reference past its own call.
##
## `state` stays a StringName here; `IncidentWorld.state_fire_mult_value`
## compares rather than converts, so the roster costs no string allocations.
func fire_candidate_columns() -> Dictionary:
	var ids := building_ids()
	var count := ids.size()
	if _fire_revision != int(sim.roster_revision):
		_fire_ids.resize(count)
		_fire_states.resize(count)
		_fire_condition.resize(count)
		_fire_ignition.resize(count)
		_fire_powered.resize(count)
		_fire_district.resize(count)
		for i in count:
			_fire_ids[i] = String(ids[i])
		_fire_revision = int(sim.roster_revision)
	var district_by_id := _district_by_building()
	for i in count:
		var id: String = _fire_ids[i]
		var b: Building = sim.buildings[id]
		_fire_states[i] = b.state
		_fire_condition[i] = b.condition
		_fire_ignition[i] = float(b.stats.get("fire_ignition_per_hour", 0.0))
		_fire_powered[i] = 1 if sim.grid.is_powered(id) else 0
		_fire_district[i] = district_by_id[id]
	return {
		"id": _fire_ids, "state": _fire_states, "condition": _fire_condition,
		"fire_ignition_per_hour": _fire_ignition, "powered": _fire_powered,
		"district_id": _fire_district,
	}


## building id -> district id, memoised. A building's origin never moves, so the
## answer can only change when the roster changes or when a BLOCK changes
## district — both of which carry a revision counter. Same value
## `district_of_tile(b.origin)` returns; only the number of `block_of_tile`
## walks changed.
func _district_by_building() -> Dictionary:
	var key := Vector2i(int(sim.roster_revision), int(sim.districts.membership_revision))
	if key == _district_memo_key:
		return _district_by_building_memo
	var out: Dictionary = {}
	for building_id in building_ids():
		var id := String(building_id)
		out[id] = district_of_tile((sim.buildings[id] as Building).origin)
	_district_by_building_memo = out
	_district_memo_key = key
	return out


## Dispatch priority asks this per live incident per integrator sub-step, so at
## 1,500 buildings it is one of doc 06's hottest sweeps.
##
## The square prefilter is EXACT, not approximate: `|dx| > radius` implies
## `sqrt(dx² + dy²) > radius`, so every building it drops is one the distance
## test below would have dropped anyway. Origins are integers, so the bound is
## taken as an integer and the comparison never touches a float. What survives
## is measured exactly as before — same `Vector2.length()`, same `<=`, same
## boundary decisions — because a squared-distance rewrite would move the
## boundary in the last bit and this membership feeds a float sum.
func buildings_within_m(tile: Vector2i, radius_m: float, exclude_id: String = "") -> Array:
	var radius_tiles := radius_m / METRES_PER_TILE
	var bound := int(ceil(radius_tiles))
	var out: Array = []
	for id in building_ids():
		var b: Building = sim.buildings[id]
		var dx := b.origin.x - tile.x
		if dx > bound or dx < -bound:
			continue
		var dy := b.origin.y - tile.y
		if dy > bound or dy < -bound:
			continue
		if String(id) == exclude_id:
			continue
		if Vector2(float(dx), float(dy)).length() <= radius_tiles:
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
		"police_coverage": district_coverage(id, CoverageIndex.KIND_POLICE),
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
	# The downstream roll-up is built ONCE here (one pass over the roster)
	# instead of once per transformer inside power_component(): the traffic /
	# transformer generator calls this every integrator sub-step, and the naive
	# shape was 2·N_transformers full building scans per call.
	var downstream := _downstream_index()
	var out: Array = []
	for node in sim.loader.power_nodes_of_kind("transformer"):
		var row := _power_component(String(node.get("id", "")), downstream)
		if not row.is_empty():
			out.append(row)
	return out


## Same nodes, same order, same filter as `power_transformers()` — four fields
## instead of eleven, and no downstream roll-up at all.
func power_transformer_rates() -> Array:
	var out: Array = []
	for node in sim.loader.power_nodes_of_kind("transformer"):
		var id := String(node.get("id", ""))
		var c: Dictionary = sim.grid.component(id)
		if c.is_empty():
			continue
		var capacity: float = maxf(1.0, sim.grid.cap_eff(id, 22.0))
		out.append({
			"id": id,
			"load_ratio": float(c.get("load_kw", 0.0)) / capacity,
			"condition": float(c.get("condition", 1.0)),
			"temp_c": 22.0 + float(c.get("theta_c", 0.0)),
		})
	return out


func power_component(id: String) -> Dictionary:
	return _power_component(id, _downstream_index())


func _power_component(id: String, downstream: Dictionary) -> Dictionary:
	var c: Dictionary = sim.grid.component(id)
	if c.is_empty():
		return {}
	var capacity: float = maxf(1.0, sim.grid.cap_eff(id, 22.0))
	var roll: Dictionary = downstream.get(id, EMPTY_DOWNSTREAM)
	return {
		"id": id, "kind": String(c.get("kind", "")),
		"tile": c.get("tile", Vector2i.ZERO),
		"load_ratio": float(c.get("load_kw", 0.0)) / capacity,
		"condition": float(c.get("condition", 1.0)),
		"temp_c": 22.0 + float(c.get("theta_c", 0.0)),
		"state": String(c.get("state", "OK")),
		"redundancy": false,  # doc 04's tie table is not exposed per-node yet
		"customers_downstream": int(roll["count"]),
		"critical_downstream": bool(roll["critical"]),
		"underground": bool(c.get("underground", false)),
	}


const EMPTY_DOWNSTREAM := {"count": 0, "critical": false}

## {attachment_id: {count, critical}} in ONE pass over the roster. Order is
## irrelevant — a count and an OR are both commutative — so this deliberately
## skips the keys().sort() that `building_ids()` pays for.
func _downstream_index() -> Dictionary:
	var out: Dictionary = {}
	for building_id in sim.buildings:
		var attachment: String = sim.grid.attachment_of(String(building_id))
		if attachment == "":
			continue
		var existing: Variant = out.get(attachment)  # no `{}` default: it would
		var roll: Dictionary                        # allocate on every hit too
		if existing == null:
			roll = {"count": 0, "critical": false}
			out[attachment] = roll
		else:
			roll = existing
		roll["count"] = int(roll["count"]) + 1
		if not bool(roll["critical"]):
			var b: Building = sim.buildings[building_id]
			if b.archetype == &"water_facility" or b.archetype == &"fire_station" \
					or b.archetype == &"police_station":
				roll["critical"] = true
	return out


func power_customers_downstream(id: String) -> int:
	var count := 0
	for building_id in sim.buildings:
		if sim.grid.attachment_of(String(building_id)) == id:
			count += 1
	return count


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


## **Audit 91 D-17, closed.** `WaterSystem.mains()` publishes every hazard input
## doc 06 §2.6(d) reads; this is the rename between the two vocabularies
## (`segment_id` → `id`, `zone_key` → `zone`) and the eligibility filter, and
## nothing else. No number is authored here — that was the whole finding.
##
## **Which segments are candidates.** `ok` only. A `broken` main is already the
## target of a live incident and a second break on it would be a duplicate the
## player cannot act on separately; an `isolated` one has been valved out of the
## live graph and carries no water to burst. Doc 06's `_ambient_rate` composes
## correctly with this: a city whose every main is broken scans, finds nothing,
## and the pacing floor stays out rather than inventing a target (doc 92 §18.1
## property 2).
func water_mains() -> Array:
	var out: Array = []
	for segment in sim.water.mains():
		var row: Dictionary = segment
		if String(row.get("state", "ok")) != "ok":
			continue
		out.append({
			"id": String(row["segment_id"]),
			"tile": row.get("tile", Vector2i.ZERO),
			"length_km": float(row.get("length_km", 0.0)),
			"condition": float(row.get("condition", 1.0)),
			"pressure_ratio": float(row.get("pressure_ratio", 1.0)),
			"utilization": float(row.get("utilization", 0.0)),
			"freeze_stress": float(row.get("freeze_stress", 0.0)),
			"zone": String(row.get("zone_key", "")),
		})
	return out


## `severity <= 0` is the seam's word for REPAIRED (doc 06 §2.7 calls this verb
## with zero on resolve rather than owning a second one), and doc 05 has the two
## verbs the two meanings want.
func water_set_segment_broken(id: String, severity: float,
		incident_id: String = "") -> void:
	if sim.water.edge(id) == null:
		return
	if severity <= 0.0:
		sim.water.set_segment_repaired(id)
	else:
		sim.water.set_segment_broken(id, severity, incident_id)


func water_zone_pressure_delta(zone: String, delta: float,
		segment_id: String = "") -> void:
	# With an owning main, doc 05 §2.8 holds the magnitude ON the segment and
	# releases it when the segment is repaired — so a break that FAILS cannot
	# leave a zone permanently depressurised with nothing left to clear it.
	if segment_id != "" and sim.water.edge(segment_id) != null:
		sim.water.set_incident_pressure(segment_id, delta)
		return
	if zone == "":
		return
	if absf(delta) <= 0.0:
		sim.water.clear_zone_pressure_delta(zone, ZONE_HOLD_KEY)
	else:
		sim.water.zone_pressure_delta(zone, ZONE_HOLD_KEY, delta)


## Doc 06 does not carry an incident id across this verb, and it does not need
## to: the zone-wide form only exists for a break with no identified main, of
## which there is at most one shape in the game. One key, cleared by the same
## verb with a zero delta.
const ZONE_HOLD_KEY := "doc06_zone"


func water_freeze_enabled() -> bool:
	return bool(sim.water.data.flag("freeze_enabled"))


# ------------------------------------------------------------------ doc 10

## **Audit 91 D-18, closed.** Doc 10's `RoadNetwork.intersections()` already
## answers in doc 06's five columns; this is the join and the id cast, and — like
## `water_mains()` above — it authors no number.
##
## The rows are doc 10's live cache and are REUSED between calls, which is the
## contract `road_intersections()` documents and what keeps a 389-node starter
## city off the allocator on all sixty of an hour's sub-steps.
func road_intersections() -> Array:
	var rows: Array = sim.roads.intersections()
	return rows


## Doc 10 can say cheaply whether anything on that roster moved, so doc 06 keeps
## its per-node hazard weights across sub-steps instead of rescanning the whole
## road graph sixty times a game-hour.
func road_intersections_epoch() -> int:
	return int(sim.roads.intersections_epoch())


## Doc 06's escalation tiers slow a segment down (`edge_speed_mult 0.6 / 0.3 /
## 0.5`) and doc 06 restores it with `1.0` on resolve. The override also carries
## its own expiry, taken from doc 10's own closure table rather than authored
## here, so an ABANDONED accident cannot leave a street permanently slow with
## nothing left alive to lift it.
func road_set_edge_speed_mult(tile: Vector2i, mult: float) -> void:
	var edge_id := _worst_edge_at(tile)
	if edge_id < 0:
		return
	var until: int = -1
	if mult < 1.0:
		until = int(sim.roads.sim_minute) + _incident_override_gm()
	sim.roads.set_edge_speed_mult(edge_id, mult, until)


## `duration_h <= 0` means "doc 10 decides", which is what its `auto_expire_gm`
## column is for — the two `edge_close` rows that pass no duration
## (`traffic_accident` T4, `storm_damage/blocked_road` T3) are exactly the two
## that want the cause's own clock.
func road_close_edge(tile: Vector2i, duration_h: float, cause: String = "") -> void:
	var edge_id := _worst_edge_at(tile)
	if edge_id < 0:
		return
	var until: int = -1
	if duration_h > 0.0:
		until = int(sim.roads.sim_minute) + int(round(duration_h * 60.0))
	sim.roads.close_edge(edge_id, _closure_cause(cause), until)


## Doc 06 names an incident; doc 10 names a closure CAUSE, with its own
## dominance order, per-route-class multipliers and expiry. This is the map, and
## every row on the right is doc 10's — doc 10 §5's interface table already
## pairs a main break with `flood_shallow` and debris with `debris`.
const CLOSURE_CAUSE_BY_INCIDENT := {
	"traffic_accident": "accident_major",
	"water_main_break": "flood_shallow",
	"storm_damage": "debris",
	"blocked_road": "debris",
}


func _closure_cause(key: String) -> String:
	return String(CLOSURE_CAUSE_BY_INCIDENT.get(key, "debris"))


## Doc 06 addresses a TILE; doc 10 closes an EDGE. At a mid-block tile there is
## one candidate. At an intersection there are three or four, and doc 06 §2.6(e)
## has already ruled which one the incident is on — "the collision happens on the
## worst approach" — so the same reading picks the segment that gets closed.
## Ties break on the lowest edge id, which is stable across a save (§2.5's
## edge-id stability rule).
func _worst_edge_at(tile: Vector2i) -> int:
	var edge_ids: Array = sim.roads.graph.edges_at(tile)
	if edge_ids.is_empty():
		return -1
	var best := -1
	var best_congestion := -1.0
	for edge_id: int in edge_ids:
		var c: float = sim.roads.congestion_index(edge_id)
		if c > best_congestion:
			best_congestion = c
			best = edge_id
	return best


## Doc 10's own expiry for an accident closure, reused as the expiry of doc 06's
## speed override so no constant is authored on this side of the seam.
func _incident_override_gm() -> int:
	var row: Dictionary = sim.roads.tun.cause_row("accident_major")
	return maxi(1, int(row.get("auto_expire_gm", 240)))


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


## Report 98 RR-77. Doc 06 hands over the shape; doc 03 owns the dollars AND the
## ceiling, so the whole moral-hazard guard lives on this side of the seam.
func dispatch_payout(type_id: String, shape_mult: float, manual: bool,
		target_ref: Dictionary, residual_fraction: float) -> int:
	var base: float = sim.econ_curves.dispatch_payout_base(type_id)
	if base <= 0.0:
		return 0
	var dispatcher: float = sim.econ_curves.manual_dispatch_mult() if manual else 1.0
	var payout := CostCurves.round_half_up(base * shape_mult * dispatcher)
	var prevented := prevented_loss_value(target_ref, residual_fraction)
	if prevented < 0:
		return payout  # doc 03 prices no capital for this asset class — gate 31
	var cap_fraction: float = sim.econ_curves.moral_hazard_cap_fraction()
	return mini(payout, CostCurves.round_half_up(cap_fraction * float(prevented)))


## `capital_value(target) − repair_cost(target, residual)`, or **−1** where doc
## 03 prices no capital for that asset class (road edges, water segments) — see
## the base class for why the difference matters.
func prevented_loss_value(target_ref: Dictionary, residual_fraction: float) -> int:
	match String(target_ref.get("kind", "")):
		"building":
			var b: Building = sim.buildings.get(String(target_ref.get("id", "")), null)
			if b == null:
				return -1
			var capital: int = sim.econ_curves.capital_value(String(b.archetype),
					maxi(1, b.level))
			return maxi(0, capital - repair_cost(target_ref, residual_fraction))
		"power_component":
			var c: Dictionary = sim.grid.component(String(target_ref.get("id", "")))
			if c.is_empty():
				return -1
			var grid_capital: int = sim.econ_curves.capital_value_grid(
					String(c.get("kind", "transformer")), int(c.get("level", 1)))
			return maxi(0, grid_capital - repair_cost(target_ref, residual_fraction))
	return -1


func credit_city_service(amount: int, source: String, reason: String) -> void:
	if amount > 0:
		sim.treasury.credit_city_service(amount, source, reason)


func debit(amount: int, reason: String) -> bool:
	if amount <= 0:
		return true
	return bool(sim.treasury.spend(amount, &"incident", reason).get("ok", false))


## Doc 06 §8's two knobs, read through doc 03's one loader (C-17). They used to
## be asked of `Treasury.difficulty()`, which never carried them — the economic
## row is twelve keys and neither of these is one of them, so the `.get(…, 1.0)`
## fallback WAS the read path and every preset escalated at 1.0 (doc 91
## A91-D-19). They now come from `escalation`, where doc 06 authors them.
func difficulty_escalation_mult() -> float:
	return sim.difficulty.number("escalation", "escalation_mult", 1.0)


func difficulty_generation_mult() -> float:
	return sim.difficulty.number("escalation", "generation_mult", 1.0)


# -------------------------------------------------------- doc 02 construction

func release_crew_from_job(job_id: int, crew_id: String) -> void:
	sim.construction.release_crew(job_id, crew_id, "preempted_by_incident")
