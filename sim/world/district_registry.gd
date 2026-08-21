class_name DistrictRegistry
extends RefCounted
## Districts, stability and city_stability (doc 09 §2.6). A district is 1–4
## orthogonally contiguous blocks; it owns no tiles and no simulation — it
## aggregates. Stability ∈ [0,1] everywhere (report 98 C-56).

const MAX_BLOCKS: int = 4
const DISTRICT_DARK_THRESHOLD: float = 0.60
const REASSIGN_COOLDOWN_MINUTES: int = 1440  # 24 game-hours per block
const POWER_REL_HALFLIFE_H: float = 6.0
const WATER_REL_HALFLIFE_H: float = 24.0  # doc 05 §2.11: EMA over a game-day
## Doc 07 writes stability deltas via apply_stability; the offset decays so a
## one-off event fades rather than permanently rewriting the aggregate.
const EVENT_OFFSET_HALFLIFE_H: float = 6.0

## Doc 10 §2.10's four land-use profile curves, in the order this file sums
## them. A district's `profile_weights` is one normalised number per entry.
const PROFILES: Array[String] = ["res", "com", "ind", "civ"]
## Doc 02's five archetype CATEGORIES folded onto those four curves. The fold is
## read off doc 10 §2.10's own description of what each curve MEANS, not off the
## name of the category:
##
## * `industrial` carries `data_center` (whose TAX class is `tech` — doc 03's
##   axis, not this one) → **ind**.
## * `utility` — power plant, substation, water works — is **ind** as well, and
##   deliberately. Utilities are industrial land use in every zoning taxonomy,
##   and doc 10's `ind` curve is *"flat-shifted, peaking 16:00 and never below
##   0.18 overnight"*, which is precisely a 24/7 plant's trip profile. Folding
##   them into `civ` instead would put a continuously-staffed works on a curve
##   that empties at 03:00 — and would leave the `ind` row of `tod_curves`
##   authored and dead on the founding city, which is the exact defect this
##   wiring exists to end.
## * `service` — police, fire, the construction yard — is **civ**: doc 10 says
##   that curve *"peaks 07:00 (0.75) and 15:00 (0.75) for school and shift
##   changes"*, which is the emergency-service watch change, not a plant.
##
## An unknown category is `civ` rather than a crash: a new archetype must not be
## able to silently zero a district's demand.
const CATEGORY_PROFILE := {
	"residential": "res", "commercial": "com", "industrial": "ind",
	"service": "civ", "utility": "ind",
}

var world: WorldMap
var rng: RngStreams
var name_pool: Array = []
var _districts: Dictionary = {}  # id -> district Dictionary
var _next_index: int = 0
var city_stability: float = 1.0
## Bumped whenever a BLOCK changes hands — creation, auto-assignment, manual
## reassignment, a restore. Nothing here reads it; it exists so a sibling that
## memoises "which district is this tile in" (doc 06's generators ask per
## sub-step, per building) can tell when its answer went stale. Derived, so it
## is neither serialized nor hashed.
var membership_revision: int = 0
## `district_id -> {res, com, ind, civ}`, normalised. Doc 10 §5.1's
## `land.district_profile_weights(id)`, and DERIVED — see `set_building_mix`.
var _profile_weights: Dictionary = {}


func _init(p_world: WorldMap, p_rng: RngStreams, p_name_pool: Array = []) -> void:
	world = p_world
	rng = p_rng
	name_pool = p_name_pool


func district(id: String) -> Dictionary:
	return _districts.get(id, {})


func district_ids_sorted() -> Array:
	var ids := _districts.keys()
	ids.sort()
	return ids


func district_of_block(block_id: String) -> String:
	for id in _districts:
		if (_districts[id]["blocks"] as Array).has(block_id):
			return id
	return ""


func create_district(block_ids: Array, name: String = "", forced_id: String = "") -> String:
	assert(block_ids.size() >= 1 and block_ids.size() <= MAX_BLOCKS)
	var id := forced_id if forced_id != "" else "D_%03d" % _next_index
	if name == "":
		if not name_pool.is_empty():
			name = String(name_pool[rng.stream("misc").randi_range(0, name_pool.size() - 1)])
		else:
			name = "District %d" % (_next_index + 1)
	_districts[id] = {
		"id": id, "name": name, "blocks": block_ids.duplicate(),
		"color_index": _next_index % 8,
		"population": 0, "jobs": 0, "tax_output": 0,
		"power_reliability": 1.0, "water_reliability": 1.0,
		"crime_index": 0.0, "fire_risk": 0.0, "traffic_state": 0.0,
		"stability": 1.0, "event_offset": 0.0,
		"district_dark": false, "district_dark_fraction": 0.0,
		"block_cooldowns": {},
	}
	_next_index += 1
	membership_revision += 1
	for block_id in block_ids:
		var b := world.block(String(block_id))
		if b != null:
			b.district_id = id
	return id


## Auto-assignment on a block reaching READY (doc 09 §2.6): join the adjacent
## district with the fewest blocks that has < 4 and the same terrain_class;
## else the adjacent district with the fewest blocks; else create a new one.
func auto_assign(block_id: String) -> String:
	var b := world.block(block_id)
	assert(b != null)
	var candidates: Array = []
	for neighbor in world.neighbors4(block_id):
		var district_id := district_of_block((neighbor as LandBlock).id)
		if district_id == "":
			continue
		var d: Dictionary = _districts[district_id]
		if (d["blocks"] as Array).size() >= MAX_BLOCKS:
			continue
		if not candidates.has(district_id):
			candidates.append(district_id)
	candidates.sort()  # deterministic tie-break by id
	var best := ""
	var best_key := [999, 999]
	for district_id in candidates:
		var d: Dictionary = _districts[district_id]
		var same_terrain := 0
		var first_block := world.block(String((d["blocks"] as Array)[0]))
		if first_block != null and first_block.terrain_class == b.terrain_class:
			same_terrain = 0
		else:
			same_terrain = 1
		var key := [same_terrain, (d["blocks"] as Array).size()]
		if key < best_key:
			best_key = key
			best = district_id
	if best != "":
		(_districts[best]["blocks"] as Array).append(block_id)
		b.district_id = best
		membership_revision += 1
		return best
	return create_district([block_id])


## Manual reassignment: contiguity with the target, size cap, and a 24 gh
## per-block cooldown (doc 09 §2.6).
func assign_block_to_district(block_id: String, district_id: String, now_minutes: int) -> Dictionary:
	if not _districts.has(district_id):
		return CommandQueue.fail(&"E_UNKNOWN_DISTRICT")
	var target: Dictionary = _districts[district_id]
	if (target["blocks"] as Array).size() >= MAX_BLOCKS:
		return CommandQueue.fail(&"E_DISTRICT_FULL")
	var cooldown_until := int((target["block_cooldowns"] as Dictionary).get(block_id, 0))
	var source_id := district_of_block(block_id)
	if source_id != "":
		cooldown_until = maxi(cooldown_until,
				int((_districts[source_id]["block_cooldowns"] as Dictionary).get(block_id, 0)))
	if now_minutes < cooldown_until:
		return CommandQueue.fail(&"E_REASSIGN_COOLDOWN", {"until_minute": cooldown_until})
	var contiguous := false
	for neighbor in world.neighbors4(block_id):
		if (target["blocks"] as Array).has((neighbor as LandBlock).id):
			contiguous = true
			break
	if not contiguous:
		return CommandQueue.fail(&"E_NOT_CONTIGUOUS")
	if source_id != "":
		(_districts[source_id]["blocks"] as Array).erase(block_id)
		if (_districts[source_id]["blocks"] as Array).is_empty():
			_districts.erase(source_id)
	(target["blocks"] as Array).append(block_id)
	(target["block_cooldowns"] as Dictionary)[block_id] = now_minutes + REASSIGN_COOLDOWN_MINUTES
	var b := world.block(block_id)
	if b != null:
		b.district_id = district_id
	membership_revision += 1
	return CommandQueue.ok()


func rename_district(district_id: String, name: String) -> void:
	if _districts.has(district_id):
		_districts[district_id]["name"] = name


# ------------------------------------------------------- written by siblings

func set_population_jobs(district_id: String, population: int, jobs: int) -> void:
	var d: Dictionary = _districts[district_id]
	d["population"] = population
	d["jobs"] = jobs


## Doc 10 §5.1's `land.district_profile_weights(id) -> {res, com, ind, civ}` —
## the per-district land-use mix doc 10 §2.10's `D_tod` sums the four hourly
## curves with. A residential district's twin rush-hour peaks and an industrial
## district's flat-shifted 16:00 peak are the same four curves read through two
## different rows of this table; without it every district got doc 10's default
## row and the authored curves were four copies of one curve.
##
## A district this registry has never been given a mix for — or one whose
## buildings generate no trips at all — answers `{}`, which is roads' signal to
## use `data/roads.json`'s authored `default_profile_weights`. It is deliberately
## NOT a fabricated uniform row: an empty district has no land use, and inventing
## one would be a number nobody authored.
func profile_weights(district_id: String) -> Dictionary:
	return _profile_weights.get(district_id, {})


## The one writer. `mix` is `{district_id: {profile: pj}}` of RAW
## `Σ(population + jobs)` per profile — trip generation, the same `pj` doc 10
## §2.10's `L_dens` counts, and NOT a building count: a 60-resident high-rise is
## not one house. `CitySim` builds it from doc 02's roster (it owns the
## cross-doc seam); this normalises it, because a row that reached doc 10
## un-normalised would silently rescale `D_tod`.
##
## **Derived, and therefore neither serialized nor hashed.** The mix is a pure
## function of the building roster and district membership, both of which the
## save already carries, so a restored city re-derives the identical row before
## its first tick rather than carrying a second copy that could disagree with
## the roster it was saved beside.
func set_building_mix(mix: Dictionary) -> void:
	_profile_weights.clear()
	var district_ids := mix.keys()
	district_ids.sort()   # float division order is not state, but reproducibility is cheap
	for district_id in district_ids:
		var row: Dictionary = mix[district_id]
		var total := 0.0
		for profile in PROFILES:
			total += float(row.get(profile, 0.0))
		if total <= 0.0:
			continue
		var normalised: Dictionary = {}
		for profile in PROFILES:
			normalised[profile] = float(row.get(profile, 0.0)) / total
		_profile_weights[String(district_id)] = normalised


func set_indices(district_id: String, crime_index: float, fire_risk: float, traffic_state: float) -> void:
	var d: Dictionary = _districts[district_id]
	d["crime_index"] = crime_index
	d["fire_risk"] = fire_risk
	d["traffic_state"] = traffic_state


func update_power_reliability(district_id: String, served_ratio: float, dt_h: float) -> void:
	_ema(district_id, "power_reliability", served_ratio, dt_h, POWER_REL_HALFLIFE_H)


func update_water_reliability(district_id: String, pressure_ratio: float, dt_h: float) -> void:
	_ema(district_id, "water_reliability", clampf(pressure_ratio, 0.0, 1.0), dt_h, WATER_REL_HALFLIFE_H)


func _ema(district_id: String, field: String, x: float, dt_h: float, halflife_h: float) -> void:
	var d: Dictionary = _districts[district_id]
	var alpha := 1.0 - pow(2.0, -dt_h / halflife_h)
	d[field] = float(d[field]) + (x - float(d[field])) * alpha


## Doc 07's write path (report 98 C-56): a delta on the event offset, never a
## direct write to stability or a city scalar. Decays in recompute_slow.
func apply_stability(district_id: String, delta: float) -> void:
	var d: Dictionary = _districts[district_id]
	d["event_offset"] = clampf(float(d["event_offset"]) + delta, -1.0, 1.0)


## block_dark_by_block: {block_id: bool} from doc 04; population weights from
## per-block population {block_id: int}.
func update_district_dark(district_id: String, block_dark: Dictionary, block_population: Dictionary) -> void:
	var d: Dictionary = _districts[district_id]
	var weighted := 0.0
	var total_pop := 0.0
	var dark_blocks := 0
	var blocks: Array = d["blocks"]
	for block_id in blocks:
		var pop := float(block_population.get(block_id, 0))
		var dark := 1.0 if bool(block_dark.get(block_id, false)) else 0.0
		weighted += pop * dark
		total_pop += pop
		dark_blocks += int(dark)
	var fraction: float
	if total_pop > 0.0:
		fraction = weighted / total_pop
	else:
		fraction = float(dark_blocks) / maxf(1.0, float(blocks.size()))
	d["district_dark_fraction"] = fraction
	d["district_dark"] = fraction >= DISTRICT_DARK_THRESHOLD


# ----------------------------------------------------------------- recompute

## 1 Hz (EVERY_MINUTE): the stability aggregate (doc 09 §2.6 formula).
func recompute_fast(district_id: String) -> float:
	var d: Dictionary = _districts[district_id]
	var road_quality := 0.0
	var blocks: Array = d["blocks"]
	for block_id in blocks:
		var b := world.block(String(block_id))
		road_quality += b.block_road_access_score() if b != null else 0.0
	road_quality /= maxf(1.0, float(blocks.size()))
	var employment := clampf(float(d["jobs"]) / maxf(1.0, float(d["population"]) * 0.55), 0.0, 1.0)
	var stability := 0.30 * float(d["power_reliability"]) \
			+ 0.20 * float(d["water_reliability"]) \
			+ 0.20 * (1.0 - float(d["crime_index"])) \
			+ 0.15 * road_quality \
			+ 0.10 * employment \
			+ 0.05 * (1.0 - float(d["fire_risk"]))
	d["stability"] = clampf(stability + float(d["event_offset"]), 0.0, 1.0)
	return d["stability"]


## Per game-hour: event-offset decay + the city aggregate (doc 09 §2.6).
func recompute_slow(dt_h: float = 1.0) -> float:
	var decay := pow(2.0, -dt_h / EVENT_OFFSET_HALFLIFE_H)
	var weighted := 0.0
	var total_pop := 0.0
	var plain_sum := 0.0
	for id in district_ids_sorted():
		var d: Dictionary = _districts[id]
		d["event_offset"] = float(d["event_offset"]) * decay
		weighted += float(d["population"]) * float(d["stability"])
		total_pop += float(d["population"])
		plain_sum += float(d["stability"])
	if _districts.is_empty():
		city_stability = 1.0
	elif total_pop > 0.0:
		city_stability = weighted / total_pop
	else:
		city_stability = plain_sum / float(_districts.size())
	return city_stability


# --------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	var out: Array = []
	for id in district_ids_sorted():
		out.append((_districts[id] as Dictionary).duplicate(true))
	return {"section_version": 1, "districts": out, "city_stability": city_stability,
			"next_index": _next_index}


func deserialize(data: Dictionary) -> void:
	_districts.clear()
	# The mix is derived from a roster this call does not restore, so it is
	# dropped rather than carried: `membership_revision` moves here, which is
	# half of `CitySim`'s memo key, so the next reader rebuilds it from the
	# roster the restore is about to lay down.
	_profile_weights.clear()
	membership_revision += 1
	for d in data.get("districts", []):
		_districts[String(d["id"])] = d
	city_stability = float(data.get("city_stability", 1.0))
	_next_index = int(data.get("next_index", _districts.size()))
