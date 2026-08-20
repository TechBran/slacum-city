class_name PowerGrid
extends RefCounted
## The electrical grid (doc 04). A real graph — plants, substations, feeders,
## transformers, ties — with capacity, load, condition and temperature.
## Explicitly NOT electrical engineering (spec §52): capacity is a scalar kW
## budget propagated down radial trees from a bulk generation pool.
##
## Four passes per tick: A demand aggregation (bottom-up), B supply + shedding,
## C thermal/protection/hazard, D energization DFS (only when topology_dirty).
## Constants inline mirror data/power.json §8; DataRegistry asserts equality
## at boot once wired (P0-01 pattern).

const CAPACITY := {
	&"plant_gas": [8000.0, 18000.0, 36000.0, 70000.0, 120000.0],
	&"substation": [6000.0, 14000.0, 30000.0, 60000.0, 110000.0],
	&"transformer": [50.0, 150.0, 400.0, 1000.0, 2500.0],
}
const FEEDER_CAPACITY := [1200.0, 3000.0, 7500.0]  # conductor class 1..3
const TRANSMISSION_CAPACITY := [40000.0, 90000.0, 180000.0]
const TRANSFORMER_SERVICE_RADIUS := [3, 4, 5, 6, 8]
const SUBSTATION_FEEDER_SLOTS := [2, 3, 4, 6, 8]

# (theta_rated_c, tau_gs) per kind — §2.6
const THERMAL := {
	&"transformer": [55.0, 900.0], &"feeder": [40.0, 300.0],
	&"substation": [45.0, 1200.0], &"transmission": [35.0, 240.0],
}
# (T_knee, T_span, h_hot, h_cold) per kind — §2.6
const HAZARD := {
	&"transformer": [85.0, 60.0, 2.00, 0.00012], &"feeder": [75.0, 55.0, 1.20, 0.00008],
	&"substation": [80.0, 60.0, 0.90, 0.00010], &"transmission": [70.0, 55.0, 0.70, 0.00006],
}
const K_TRIP := {&"feeder": 120.0, &"substation": 90.0, &"transmission": 100.0}
const R_PICKUP := 1.05
const TRIP_ACCUM_DECAY_GS := 120.0
const XFMR_BURNOUT_R := 3.0
const AUTO_RECLOSE_DELAY_GS := 90
const AUTO_RECLOSE_OK_R := 0.98
const AUTO_RECLOSE_MAX_ATTEMPTS := 2
const WEAR_PER_GH := 0.00035
const PLANT_H_BASE := 0.00030

const DARK_THRESHOLD := 0.35
const DARK_SUSTAIN_GS := 20
const LIT_THRESHOLD := 0.55
const LIT_SUSTAIN_GS := 10

const PRIORITY_WEIGHT := {&"CRITICAL": 1000.0, &"ESSENTIAL": 40.0, &"STANDARD": 8.0, &"DISCRETIONARY": 1.0}
const ROLLING_SHED_PERIOD_GM := 30
const PRIORITY_OVERRIDE_BONUS := 500.0

const TIE_TRANSFER_DELAY_GS := 20
const TIE_CLEAN_R := 0.95
const TIE_AGGRESSIVE_R := 1.35
const CASCADE_WINDOW_GS := 60
const MAJOR_OUTAGE_FRACTION := 0.40

const BLOCK_DARK_THRESHOLD := 0.60

## The load ratio an ORPHANED transformer (its feeder demolished) reports to
## `adoption_plan`'s ranking. It is a SORT KEY, never an electrical quantity: it
## says "ahead of anything with a real parent", and a real parent cannot reach
## it because §2.5's relay opens a feeder at r = 1.05. Finite rather than `INF`
## so two orphans compare equal and fall through to the distance tie-break
## instead of producing NaN.
const ORPHAN_RATIO := 1.0e9

## Doc 04 §5.10's overlay colour bands (`data/power.json` §8
## `overlay.color_thresholds`), mirrored here because they are the only
## AUTHORED "how loaded is too loaded" numbers in the doc and everything that
## has to decide when to act should read them rather than pick its own:
## `NORMAL` r < 0.75, `WARNING` 0.75 ≤ r < 0.95, `CRITICAL` r ≥ 0.95.
const OVERLAY_WARNING_R := 0.75
const OVERLAY_CRITICAL_R := 0.95

## How full a PLANNED transfer is allowed to leave the receiving component.
##
## Not §2.9's `auto_transfer_max_r` (0.95, `TIE_CLEAN_R`), and the difference is
## the point. 0.95 is the EMERGENCY bound: a trip has already happened, the load
## is dark either way, and taking it at 95 % is better than leaving it out. A
## player who has just paid for new copper is making a PLAN, and a plan that
## fills brand-new plate to 95 % has bought nothing — measured on the 50-game-day
## run, adoption at 0.95 handed every new feeder back at r = 1.51 within a
## game-week of growth. A planned transfer therefore has to leave the receiving
## component where §5.10's overlay still calls it NORMAL: **r < 0.75**.
const ADOPTION_MAX_R := OVERLAY_WARNING_R

const LIGHTNING_P_BASE := 0.55
const LIGHTNING_ARRESTER_FACTOR := 0.22

var now_gs: int = 0
var next_component_index: int = 1
var topology_dirty: bool = true
var system_demand_kw: float = 0.0
var system_supply_kw: float = 0.0
var shed_feeders: Array = []
var shed_rotation_next_gs: int = 0

var _components: Dictionary = {}  # id -> component Dictionary
var _order: Array = []  # sorted component ids (deterministic iteration)
var _children: Dictionary = {}  # id -> sorted child ids
var _ties: Dictionary = {}  # tie id -> {a, b, mode, closed, pending_close_gs}
var _attachments: Dictionary = {}  # building_id -> transformer id
var _service: Dictionary = {}  # building_id -> service record
## The ascending order every `_service` walk iterates in, cached. Six sweeps
## read it and three of them run every tick, so at 1,500 buildings this was
## three full key sorts per tick for an order that only changes when a building
## joins or leaves the grid. Derived: never serialized, rebuilt on demand, and
## invalidated by `attach_building` / `detach_building` / `deserialize`.
var _service_order: Array = []
var _service_order_dirty: bool = true
var _last_trip_gs: int = -1000000
var _last_trip_component: String = ""
var _events: Array = []
## Per-block streetlight state, doc 04 §5.2 / doc 11 §2.10 (report 93 §D).
## DERIVED, never persisted: it is rebuilt from the first energization pass
## after a load, which is also what makes a loaded save re-announce any block
## that came back dark. An unseen block is assumed LIT, so a healthy boot emits
## nothing at all.
var _block_streetlights: Dictionary = {}  # block_id -> bool


# -------------------------------------------------------------- construction

## kinds: plant_gas | substation | transformer | feeder | transmission
## opts: level, conductor_class, parent, tile, route, underground,
##       weather_exposure, tree_adjacent, priority_class …
func add_component(id: String, kind: StringName, opts: Dictionary = {}) -> Dictionary:
	assert(not _components.has(id), "duplicate component id " + id)
	var level := int(opts.get("level", 1))
	var capacity: float
	match kind:
		&"feeder":
			capacity = FEEDER_CAPACITY[int(opts.get("conductor_class", 1)) - 1]
		&"transmission":
			capacity = TRANSMISSION_CAPACITY[int(opts.get("conductor_class", 1)) - 1]
		_:
			capacity = CAPACITY[kind][level - 1]
	var component := {
		"id": id, "kind": kind, "level": level,
		"conductor_class": int(opts.get("conductor_class", 1)),
		"parent": String(opts.get("parent", "")),
		"tile": opts.get("tile", Vector2i.ZERO),
		"route": opts.get("route", []),
		"state": &"OK", "condition": float(opts.get("condition", 1.0)),
		"theta_c": 0.0, "trip_accum": 0.0, "reclose_attempts": 0,
		"reclose_at_gs": -1, "failed_cause": "",
		"load_kw": 0.0, "capacity_kw": capacity, "energized": false,
		"underground": bool(opts.get("underground", false)),
		"arrester_level": int(opts.get("arrester_level", 0)),
		"weather_exposure": float(opts.get("weather_exposure", 1.0)),
		"tree_adjacent": bool(opts.get("tree_adjacent", false)),
		"priority_override": false,
		"cause_chain": [],
		# Player-placed components carry grid geometry the world map must
		# re-reserve after a load; authored ones come back with the loader.
		"player_placed": bool(opts.get("player_placed", false)),
	}
	_components[id] = component
	_order.append(id)
	_order.sort()
	topology_dirty = true
	return component


## Re-rate a component onto a new level (doc 04 §2.2's ladder). The only caller
## is a **shell** that finished an upgrade: a `substation` / `power_facility`
## building IS its grid node (report 98 C-30), so doc 02's L1→L2 job is what
## moves 6,000 kW to 14,000 and two feeder slots to three. Feeders and
## transmission lines are rated by conductor class, not level, and refuse.
func set_level(id: String, level: int) -> bool:
	if not _components.has(id):
		return false
	var c: Dictionary = _components[id]
	var kind: StringName = c["kind"]
	if not CAPACITY.has(kind):
		return false
	var rows: Array = CAPACITY[kind]
	if level < 1 or level > rows.size():
		return false
	c["level"] = level
	c["capacity_kw"] = float(rows[level - 1])
	return true


## Remove a component from the graph (doc 02 §2.12 demolition, applied to the
## two grid nodes that are buildings).
##
## **Children are orphaned, not adopted.** A transformer whose feeder is gone
## keeps its tile and its buildings and simply stops being energized — Pass D
## only walks down from substation roots — which is the honest reading of doc 04
## §2.1's radial tree and is recoverable: `cmd_route_feeder`'s adoption pass
## (§2.9's transfer rule) picks orphans up first.
##
## **One cascade, and only one.** Removing a SUBSTATION removes the feeders it
## roots, because §2.1 says a feeder belongs to exactly one substation at a time
## and nothing in the MVP can re-root one — leaving them standing would leave
## copper that can never be energized again and that doc 03 would keep billing
## `line_km` for. Their transformers orphan as above.
##
## Returns every id removed, sorted — `id` plus whatever it cascaded to.
func remove_component(id: String) -> Array:
	if not _components.has(id):
		return []
	var removed: Array = [id]
	if _components[id]["kind"] == &"substation":
		for child_id in _order:
			if _components[child_id]["kind"] == &"feeder" \
					and String(_components[child_id]["parent"]) == id:
				removed.append(String(child_id))
	removed.sort()
	for gone in removed:
		for other_id in _order:
			if String(_components[other_id]["parent"]) == gone:
				_components[other_id]["parent"] = ""
		if String(_last_trip_component) == gone:
			_last_trip_component = ""
		_components.erase(gone)
		_order.erase(gone)
		shed_feeders.erase(gone)
	for building_id in _sorted_keys(_attachments):
		if removed.has(String(_attachments[building_id])):
			_attachments.erase(building_id)
	for tie_id in _sorted_keys(_ties):
		var tie: Dictionary = _ties[tie_id]
		if removed.has(String(tie["a"])) or removed.has(String(tie["b"])):
			_ties.erase(tie_id)
	_children.clear()
	topology_dirty = true
	return removed


func component(id: String) -> Dictionary:
	return _components.get(id, {})


func has_component(id: String) -> bool:
	return _components.has(id)


## Every component id, in the sorted order every pass iterates.
func component_ids() -> Array:
	return _order.duplicate()


func component_ids_of_kind(kind: StringName) -> Array:
	var out: Array = []
	for id in _order:
		if _components[id]["kind"] == kind:
			out.append(id)
	return out


## Route entries are stored as [x, z] pairs (JSON round-trips them that way);
## authored boot data may hand in Vector2i. One reader for both.
static func route_tile(entry: Variant) -> Vector2i:
	if entry is Vector2i:
		return entry
	var pair: Array = entry
	return Vector2i(int(pair[0]), int(pair[1]))


func add_tie(id: String, a: String, b: String, mode: StringName = &"MANUAL") -> void:
	_ties[id] = {"id": id, "a": a, "b": b, "mode": mode, "closed": false, "pending_close_gs": -1}


## Attach a building to the nearest transformer whose service radius covers
## its tile, tie-broken by lowest load ratio then id. "" ⇒ UNSERVED.
func attach_building(building_id: String, tile: Vector2i,
		priority_class: StringName = &"STANDARD", block_id: String = "") -> String:
	var best := ""
	var best_key := [999999.0, 999999.0, ""]
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] != &"transformer" or c["state"] == &"FAILED":
			continue
		var t: Vector2i = c["tile"]
		var dist := maxf(absf(tile.x - t.x), absf(tile.y - t.y))
		if dist > float(TRANSFORMER_SERVICE_RADIUS[int(c["level"]) - 1]):
			continue
		var ratio: float = c["load_kw"] / maxf(1.0, c["capacity_kw"])
		var key := [dist, ratio, id]
		if key < best_key:
			best_key = key
			best = id
	if best == "":
		_attachments.erase(building_id)
		return ""
	_attachments[building_id] = best
	if not _service.has(building_id):
		_service[building_id] = {
			"state": &"LIT", "candidate": &"LIT", "candidate_since_gs": 0,
			"served_kwh": 0.0, "demanded_kwh": 0.0, "availability_prev_hour": 1.0,
			"priority_class": priority_class, "block_id": block_id,
		}
		_service_order_dirty = true
	return best


func attachment_of(building_id: String) -> String:
	return _attachments.get(building_id, "")


## Drop a building off the grid entirely (demolition, doc 02 §2.12). The
## service record goes with it, so the building stops counting toward
## `block_dark_fractions` and `settle_hour` the instant it is gone.
func detach_building(building_id: String) -> bool:
	var had: bool = _attachments.has(building_id) or _service.has(building_id)
	_attachments.erase(building_id)
	_service.erase(building_id)
	_service_order_dirty = true
	return had


## Doc 04 §2.4: the shed score reads `priority_class` off the service record, so
## this is the whole of `cmd_set_priority`'s grid-side effect. Returns false
## when the building has no service record (never attached ⇒ nothing to weight).
func set_priority_class(building_id: String, priority_class: StringName) -> bool:
	if not _service.has(building_id):
		return false
	_service[building_id]["priority_class"] = priority_class
	return true


func priority_class_of(building_id: String) -> StringName:
	return _service.get(building_id, {}).get("priority_class", &"STANDARD")


## Every building the grid knows about that has NO transformer in range — the
## orphans a newly placed transformer may be able to adopt.
func unserved_building_ids() -> Array:
	var out: Array = []
	for building_id in _service_ids():
		if String(_attachments.get(building_id, "")) == "":
			out.append(building_id)
	return out


## The nearest tappable feeder for a new transformer (doc 04 §2.1's radial
## tree: a transformer is the child of exactly one feeder). Chebyshev distance
## to the closest tile of the feeder's route, tie-broken by lowest load ratio
## then id — the same ordering `attach_building` uses, so the choice is
## deterministic and reads the same way to a player. FAILED feeders are not
## tappable; an OPEN (tripped) one is, because it will reclose.
## Returns {} when nothing is in range.
func nearest_feeder_tap(tile: Vector2i, max_radius: int) -> Dictionary:
	var best := {}
	var best_key := [999999, 999999.0, ""]
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] != &"feeder" or c["state"] == &"FAILED":
			continue
		var route: Array = c["route"]
		var nearest := Vector2i.ZERO
		var nearest_d := 999999
		for entry in route:
			var t := route_tile(entry)
			var d: int = maxi(absi(tile.x - t.x), absi(tile.y - t.y))
			if d < nearest_d or (d == nearest_d and [t.x, t.y] < [nearest.x, nearest.y]):
				nearest_d = d
				nearest = t
		if nearest_d > max_radius:
			continue
		var ratio: float = c["load_kw"] / maxf(1.0, c["capacity_kw"])
		var key := [nearest_d, ratio, id]
		if key < best_key:
			best_key = key
			best = {"feeder": id, "tap_tile": nearest, "distance": nearest_d,
					"conductor_class": int(c["conductor_class"]),
					"underground": bool(c["underground"])}
	return best


## The tiles a lateral must add to reach `to` from a route tile `from`: a
## diagonal run while both axes still differ, then straight — each axis steps
## only while it is short of the target, so an unequal delta cannot overshoot
## (which a single fixed step vector, as in `polyline_tiles`, would). The tap
## tile is already on the route and is excluded, so the count is exactly the
## Chebyshev distance — what doc 03 §2.13(b) prices per tile.
static func lateral_tiles(from: Vector2i, to: Vector2i) -> Array:
	var out: Array = []
	var cursor := from
	while cursor != to:
		cursor.x += signi(to.x - cursor.x)
		cursor.y += signi(to.y - cursor.y)
		out.append([cursor.x, cursor.y])
	return out


## Append route tiles to a line component (a feeder lateral). `line_km` in
## `grid_inventory()` grows with it, so doc 03's E_grid bills the new copper.
func extend_route(id: String, tiles: Array) -> int:
	if not _components.has(id) or tiles.is_empty():
		return 0
	var route: Array = _components[id]["route"]
	for entry in tiles:
		route.append(entry)
	return tiles.size()


# ------------------------------------------------ doc 04 §4 `route_feeder`

## Doc 04 §2.2's `feeder_slots` ladder, read as a live budget:
## `{total, used, free}` for one substation. A substation roots exactly as many
## feeders as it has slots — L1 two, L5 eight — which is why the answer to a
## saturated feeder pair is a substation and not just more copper.
func feeder_slots(substation_id: String) -> Dictionary:
	if not _components.has(substation_id) \
			or _components[substation_id]["kind"] != &"substation":
		return {"total": 0, "used": 0, "free": 0}
	var total: int = SUBSTATION_FEEDER_SLOTS[int(_components[substation_id]["level"]) - 1]
	var used := 0
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] == &"feeder" and String(c["parent"]) == substation_id:
			used += 1
	return {"total": total, "used": used, "free": maxi(0, total - used)}


## The feeder whose route passes through `tile`, or "" — the "start on an
## existing trunk" half of §2.1 source connectivity. Sorted-id first match, so
## two feeders sharing a tile resolve the same way on every run.
func feeder_at_tile(tile: Vector2i) -> String:
	var found := feeders_at_tile(tile)
	return String(found[0]) if not found.is_empty() else ""


## Every feeder whose route passes through `tile`, sorted. Two circuits sharing
## a tile is normal once laterals fan out, and which one a new run branches from
## decides which SUBSTATION roots it — so the caller gets the whole list and
## picks the one with a free slot rather than being handed the lowest id.
func feeders_at_tile(tile: Vector2i) -> Array:
	var out: Array = []
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] != &"feeder" or c["state"] == &"FAILED":
			continue
		for entry in (c["route"] as Array):
			if route_tile(entry) == tile:
				out.append(String(id))
				break
	return out


## Path continuity (doc 04 §2.1: a feeder is a tile polyline, not a set of
## tiles). Returns the index of the first tile that does not continue the run —
## a repeat, a jump of more than one tile in either axis — or −1 when the whole
## path is walkable. Chebyshev steps, i.e. the same geometry `lateral_tiles`
## emits, so a suggested route is always a legal one.
static func route_break_index(tiles: Array) -> int:
	for i in range(1, tiles.size()):
		var previous: Vector2i = tiles[i - 1]
		var current: Vector2i = tiles[i]
		var step := current - previous
		if maxi(absi(step.x), absi(step.y)) != 1:
			return i
	return -1


## The C-41 routing assist in its geometric form: the tile polyline from `from`
## to `to`, inclusive of both. Doc 04 §4's `suggest_route_along_roads` is the
## richer version (it prefers road tiles); this is the straight run the UI drags
## by hand and the one a headless agent asks for.
static func route_between(from: Vector2i, to: Vector2i) -> Array:
	var out: Array = [from]
	for entry in lateral_tiles(from, to):
		out.append(Vector2i(int(entry[0]), int(entry[1])))
	return out


## §2.9's transfer rule, applied at the moment new copper is energized: the
## transformers a freshly routed feeder picks up.
##
## This is what makes `route_feeder` relief rather than decoration. A new feeder
## with no children carries nothing, and doc 04 ships no verb that re-parents an
## existing transformer, so without this pass the only load a new circuit could
## ever take is load that does not exist yet — and doc 92 §17.3's ceiling would
## move for new districts while the built city stayed on the feeder that is
## already at 104 %.
##
## The rule is §2.9's, not a new one:
##   * candidates are transformers within `max_radius` (Chebyshev) of the new
##     route, not FAILED, not already on this feeder;
##   * an ORPHAN (no parent — its feeder was demolished) ranks first, then the
##     hottest current parent, then the nearest, then the id;
##   * a transformer transfers only while it leaves the new feeder at or below
##     `ADOPTION_MAX_R` **and** its current parent is running hotter than the new
##     feeder would be after the move. The second clause is what stops a new
##     circuit from stripping a healthy one; the first is what stops it from
##     being handed straight back over its own rating.
##
## Loads are last tick's (Pass A recomputes next tick), which is exactly the
## number the player is looking at when they draw the line.
func adopt_transformers(feeder_id: String, max_radius: int,
		t_ambient: float = 25.0) -> Dictionary:
	if not _components.has(feeder_id) or _components[feeder_id]["kind"] != &"feeder":
		return {"adopted": [], "moved_kw": 0.0}
	var feeder: Dictionary = _components[feeder_id]
	var plan := adoption_plan(feeder["route"], float(feeder["capacity_kw"]),
			float(feeder["condition"]), float(feeder["load_kw"]), feeder_id,
			max_radius, t_ambient)
	for id in (plan["adopted"] as Array):
		_components[String(id)]["parent"] = feeder_id
	if not (plan["adopted"] as Array).is_empty():
		_children.clear()
		topology_dirty = true
	return plan


## `adopt_transformers` without the graph: the same ranking and the same two
## acceptance clauses, computed against a route and a rating rather than against
## a live component, so `preview = true` can quote what a run would pick up
## without adding one tick's worth of state. `feeder_id` is "" for a route that
## does not exist yet.
func adoption_plan(route: Array, capacity_kw: float, condition: float,
		carried_kw: float, feeder_id: String, max_radius: int,
		t_ambient: float = 25.0) -> Dictionary:
	var amb_derate := clampf(1.0 - 0.008 * maxf(0.0, t_ambient - 30.0), 0.80, 1.0)
	var effective := capacity_kw * (0.55 + 0.45 * condition) * amb_derate
	var budget := ADOPTION_MAX_R * effective
	var carried := carried_kw
	var candidates: Array = []
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] != &"transformer" or c["state"] == &"FAILED":
			continue
		var parent := String(c["parent"])
		# Already ours ⇒ nothing to transfer. Guarded on a NAMED feeder, because
		# `feeder_id` is "" while quoting a run that does not exist yet and an
		# ORPHAN also carries "" — dropping those would make the quote say
		# "adopts 0" for exactly the case the rule exists to serve.
		if feeder_id != "" and parent == feeder_id:
			continue
		var tile: Vector2i = c["tile"]
		var distance := 999999
		for entry in route:
			var t := route_tile(entry)
			distance = mini(distance, maxi(absi(tile.x - t.x), absi(tile.y - t.y)))
		if distance > max_radius:
			continue
		# An orphan reads as hotter than anything real: it is dark, and nothing
		# else in the MVP will ever take it. A finite sentinel, not INF, so two
		# orphans compare equal and fall through to the distance tie-break
		# instead of hitting NaN.
		var parent_ratio := ORPHAN_RATIO
		if parent != "" and _components.has(parent):
			parent_ratio = float(_components[parent]["load_kw"]) \
					/ maxf(1.0, cap_eff(parent, t_ambient))
		candidates.append({"id": String(id), "ratio": parent_ratio,
				"distance": distance, "load": float(c["load_kw"])})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(float(a["ratio"]) - float(b["ratio"])) > 1e-9:
			return float(a["ratio"]) > float(b["ratio"])
		if int(a["distance"]) != int(b["distance"]):
			return int(a["distance"]) < int(b["distance"])
		return String(a["id"]) < String(b["id"]))
	var adopted: Array = []
	var moved := 0.0
	for entry in candidates:
		var load := float(entry["load"])
		if carried + load > budget:
			continue
		var projected := (carried + load) / maxf(1.0, effective)
		if float(entry["ratio"]) <= projected:
			continue
		carried += load
		moved += load
		adopted.append(String(entry["id"]))
	adopted.sort()
	return {"adopted": adopted, "moved_kw": moved, "carried_kw": carried,
			"effective_kw": effective}


## Doc 04 §2.9's **parallel transformer**, made real: the buildings a newly
## placed transformer takes off an overloaded neighbour.
##
## §2.9 sells "parallel transformer on one service group, each taking
## `load × own_cap / Σ cap`" as redundancy the player can buy, but §2.1's
## service attachment is only ever evaluated for a building that has NO
## transformer — so before this, a second transformer next to a cooking one
## adopted nothing and the player's money bought them nothing. Same class of gap
## as the feeder verb, one level down the tree, and the same rule fixes it.
##
## Only TRANSFERS live here. A building with no transformer at all is
## `attach_building`'s (and `_reattach_unserved`'s) business, and always was.
##
## Acceptance is §2.9's clean-transfer bound again: take a building only while
## it leaves the new transformer at or below `TIE_CLEAN_R`, and only while its
## current transformer is running hotter than the new one would be after the
## move. `demands` is the last tick's per-building kW and `origins` their tiles —
## both doc 02's, passed in rather than mirrored here, because the grid stores
## neither and a second copy of a building's position is a second thing to keep
## in step.
func adopt_buildings(transformer_id: String, demands: Dictionary,
		origins: Dictionary, t_ambient: float = 25.0) -> Dictionary:
	if not _components.has(transformer_id) \
			or _components[transformer_id]["kind"] != &"transformer":
		return {"adopted": [], "moved_kw": 0.0}
	var c: Dictionary = _components[transformer_id]
	var plan := building_adoption_plan(c["tile"],
			TRANSFORMER_SERVICE_RADIUS[int(c["level"]) - 1], float(c["capacity_kw"]),
			float(c["condition"]), float(c["load_kw"]), transformer_id, demands,
			origins, t_ambient)
	for building_id in (plan["adopted"] as Array):
		_attachments[String(building_id)] = transformer_id
	return plan


## `adopt_buildings` without the graph — the quote half, so a placement preview
## can say what it would relieve without attaching anything.
func building_adoption_plan(tile: Vector2i, service_radius: int, capacity_kw: float,
		condition: float, carried_kw: float, transformer_id: String,
		demands: Dictionary, origins: Dictionary, t_ambient: float = 25.0) -> Dictionary:
	var amb_derate := clampf(1.0 - 0.008 * maxf(0.0, t_ambient - 30.0), 0.80, 1.0)
	var effective := capacity_kw * (0.55 + 0.45 * condition) * amb_derate
	var budget := ADOPTION_MAX_R * effective
	var carried := carried_kw
	var candidates: Array = []
	for building_id in _sorted_keys(_attachments):
		var host := String(_attachments[building_id])
		# Same guard as `adoption_plan`: "" means "quoting a node that does not
		# exist yet", not "already attached to it".
		if (transformer_id != "" and host == transformer_id) or not _components.has(host):
			continue
		if not origins.has(building_id):
			continue
		var origin: Vector2i = origins[building_id]
		var distance: int = maxi(absi(origin.x - tile.x), absi(origin.y - tile.y))
		if distance > service_radius:
			continue
		candidates.append({"id": String(building_id), "distance": distance,
				"load": float(demands.get(building_id, 0.0)),
				"ratio": float(_components[host]["load_kw"])
						/ maxf(1.0, cap_eff(host, t_ambient))})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(float(a["ratio"]) - float(b["ratio"])) > 1e-9:
			return float(a["ratio"]) > float(b["ratio"])
		if int(a["distance"]) != int(b["distance"]):
			return int(a["distance"]) < int(b["distance"])
		return String(a["id"]) < String(b["id"]))
	var adopted: Array = []
	var moved := 0.0
	for entry in candidates:
		var load := float(entry["load"])
		if carried + load > budget:
			continue
		var projected := (carried + load) / maxf(1.0, effective)
		if float(entry["ratio"]) <= projected:
			continue
		carried += load
		moved += load
		adopted.append(String(entry["id"]))
	adopted.sort()
	return {"adopted": adopted, "moved_kw": moved, "carried_kw": carried,
			"effective_kw": effective}


## The hottest transformer in the city — the same row shape `worst_feeder`
## publishes, one level down. A transformer has no protection (§2.5): past
## r = 3.0 it burns out, and below that it just cooks, so this is the reading
## that has to be watched rather than a relay that will act for you.
func worst_transformer(t_ambient: float = 25.0) -> Dictionary:
	var worst := {"id": "", "load_ratio": 0.0, "load_kw": 0.0, "capacity_kw": 0.0,
			"tile": Vector2i.ZERO}
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] != &"transformer" or c["state"] == &"FAILED":
			continue
		var ratio: float = float(c["load_kw"]) / maxf(1.0, cap_eff(String(id), t_ambient))
		if ratio > float(worst["load_ratio"]):
			worst = {"id": String(id), "load_ratio": ratio, "load_kw": float(c["load_kw"]),
					"capacity_kw": float(c["capacity_kw"]), "tile": c["tile"]}
	return worst


## The hottest feeder in the city — `{id, load_ratio, load_kw, capacity_kw}`,
## or an empty ratio-0 row when there is no feeder. Load ratio is against the
## §2.5 derated capacity, i.e. the number the relay trips on, which is the whole
## point of publishing it: doc 92 §17.3's ceiling is a feeder ratio and this is
## the query that sees it coming.
func worst_feeder(t_ambient: float = 25.0) -> Dictionary:
	var worst := {"id": "", "load_ratio": 0.0, "load_kw": 0.0, "capacity_kw": 0.0}
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] != &"feeder":
			continue
		var ratio: float = float(c["load_kw"]) / maxf(1.0, cap_eff(String(id), t_ambient))
		if ratio > float(worst["load_ratio"]):
			worst = {"id": String(id), "load_ratio": ratio,
					"load_kw": float(c["load_kw"]), "capacity_kw": float(c["capacity_kw"])}
	return worst


## Placement probe (doc 04 §2.1: no transformer in range ⇒ UNSERVED, and the
## placement UI blocks it). No side effects.
func would_serve(tile: Vector2i) -> bool:
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] != &"transformer" or c["state"] == &"FAILED":
			continue
		var t: Vector2i = c["tile"]
		if maxf(absf(tile.x - t.x), absf(tile.y - t.y)) \
				<= float(TRANSFORMER_SERVICE_RADIUS[int(c["level"]) - 1]):
			return true
	return false


# ------------------------------------------------------------------ the tick

## demands: {building_id: demand_kw} (doc 02 publishes composed demand).
## distributed: {transformer_id: extra_kw} (streetlights + signals).
## weather: {t_ambient_c, heat_wave: bool}.
func tick(dt_gs: int, demands: Dictionary, distributed: Dictionary,
		weather: Dictionary, rng: RngStreams) -> void:
	now_gs += dt_gs
	_process_reclose_timers()
	_pass_a_aggregate(demands, distributed)
	_pass_b_supply_and_shed()
	_pass_c_thermal(dt_gs, weather, rng)
	if topology_dirty:
		_pass_d_energize()
	_update_service(dt_gs, demands)


func drain_events() -> Array:
	var out := _events
	_events = []
	return out


# ------------------------------------------------------------------- pass A

func _pass_a_aggregate(demands: Dictionary, distributed: Dictionary) -> void:
	for id in _order:
		_components[id]["load_kw"] = 0.0
	for building_id in _sorted_keys(demands):
		var transformer_id: String = _attachments.get(building_id, "")
		if transformer_id != "":
			_components[transformer_id]["load_kw"] += float(demands[building_id])
	for transformer_id in _sorted_keys(distributed):
		if _components.has(transformer_id):
			_components[transformer_id]["load_kw"] += float(distributed[transformer_id])
	# Bottom-up: transformer → feeder → substation → transmission link.
	system_demand_kw = 0.0
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] == &"transformer":
			var parent: String = c["parent"]
			if parent != "":
				_components[parent]["load_kw"] += c["load_kw"]
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] == &"feeder":
			var parent: String = c["parent"]
			if parent != "":
				_components[parent]["load_kw"] += c["load_kw"]
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] == &"substation":
			system_demand_kw += c["load_kw"]
			# The transmission link carries its substation's whole load.
			for child_id in _children_of(id):
				if _components[child_id]["kind"] == &"transmission":
					_components[child_id]["load_kw"] = c["load_kw"]
		elif c["kind"] == &"transmission" and c["parent"] != "" \
				and _components.has(c["parent"]) \
				and _components[c["parent"]]["kind"] == &"substation":
			c["load_kw"] = _components[c["parent"]]["load_kw"]


# ------------------------------------------------------------------- pass B

func _pass_b_supply_and_shed() -> void:
	system_supply_kw = 0.0
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] == &"plant_gas" and c["state"] == &"OK":
			system_supply_kw += c["capacity_kw"]
	var deficit := system_demand_kw - system_supply_kw
	if deficit <= 0.0:
		if not shed_feeders.is_empty():
			shed_feeders.clear()
			topology_dirty = true
			_emit(&"LoadShedEnded", {})
		return
	if now_gs >= shed_rotation_next_gs and not shed_feeders.is_empty():
		shed_feeders.clear()  # rotation: recompute from scratch, pain moves
		_emit(&"RollingBlackoutRotated", {})
	if not shed_feeders.is_empty():
		return  # current shed set stands until rotation
	var candidates: Array = []
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] == &"feeder" and c["state"] == &"OK" and c["load_kw"] > 0.0:
			candidates.append(id)
	if candidates.is_empty():
		return
	var scored: Array = []
	for id in candidates:
		scored.append({"id": id, "score": _shed_score(id), "load": _components[id]["load_kw"],
				"critical": _feeder_has_critical(id)})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["critical"] != b["critical"]:
			return not a["critical"]  # critical feeders shed last
		if absf(float(a["score"]) - float(b["score"])) > 0.0001:
			return float(a["score"]) < float(b["score"])
		if absf(float(a["load"]) - float(b["load"])) > 0.0001:
			return float(a["load"]) > float(b["load"])  # descending load
		return String(a["id"]) < String(b["id"]))
	var shed_total := 0.0
	for entry in scored:
		if shed_total >= deficit:
			break
		shed_feeders.append(entry["id"])
		shed_total += float(entry["load"])
	shed_rotation_next_gs = now_gs + ROLLING_SHED_PERIOD_GM * 60
	topology_dirty = true
	_emit(&"LoadShedStarted", {"feeders": shed_feeders.duplicate(), "shed_kw": shed_total})


func _shed_score(feeder_id: String) -> float:
	var weighted := 0.0
	var total := 0.0
	for building_id in _sorted_keys(_attachments):
		var transformer_id: String = _attachments[building_id]
		if String(_components[transformer_id]["parent"]) != feeder_id:
			continue
		var record: Dictionary = _service.get(building_id, {})
		var priority: StringName = record.get("priority_class", &"STANDARD")
		var demand: float = _components[transformer_id]["load_kw"]
		# Score uses the transformer group's demand weighted by its class mix;
		# per-building demand is folded through the service record on refine.
		weighted += demand * float(PRIORITY_WEIGHT[priority])
		total += demand
		break  # one class sample per transformer group is the MVP granularity
	if total <= 0.0:
		var load: float = _components[feeder_id]["load_kw"]
		return float(PRIORITY_WEIGHT[&"DISCRETIONARY"]) if load > 0.0 else 999999.0
	var score: float = weighted / float(_components[feeder_id]["load_kw"])
	if _components[feeder_id]["priority_override"]:
		score += PRIORITY_OVERRIDE_BONUS
	return score


func _feeder_has_critical(feeder_id: String) -> bool:
	for building_id in _sorted_keys(_attachments):
		var transformer_id: String = _attachments[building_id]
		if String(_components[transformer_id]["parent"]) == feeder_id \
				and _service.get(building_id, {}).get("priority_class", &"STANDARD") == &"CRITICAL":
			return true
	return false


## Direct class-scored shedding for tests / WE-4: score supplied per feeder.
func force_shed_evaluation(feeder_scores: Dictionary, deficit: float) -> Array:
	var scored: Array = []
	for id in _sorted_keys(feeder_scores):
		scored.append({"id": id, "score": float(feeder_scores[id]),
				"load": _components[id]["load_kw"]})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(float(a["score"]) - float(b["score"])) > 0.0001:
			return float(a["score"]) < float(b["score"])
		if absf(float(a["load"]) - float(b["load"])) > 0.0001:
			return float(a["load"]) > float(b["load"])
		return String(a["id"]) < String(b["id"]))
	var shed: Array = []
	var total := 0.0
	for entry in scored:
		if total >= deficit:
			break
		shed.append(entry["id"])
		total += float(entry["load"])
	return shed


# ------------------------------------------------------------------- pass C

func cap_eff(id: String, t_ambient: float) -> float:
	var c: Dictionary = _components[id]
	var amb_derate := clampf(1.0 - 0.008 * maxf(0.0, t_ambient - 30.0), 0.80, 1.0)
	return c["capacity_kw"] * (0.55 + 0.45 * float(c["condition"])) * amb_derate


func _pass_c_thermal(dt_gs: int, weather: Dictionary, rng: RngStreams) -> void:
	var t_ambient := float(weather.get("t_ambient_c", 25.0))
	var still_air := 1.10 if bool(weather.get("heat_wave", false)) else 1.0
	var dt_gh := float(dt_gs) / 3600.0
	for id in _order:
		var c: Dictionary = _components[id]
		var kind: StringName = c["kind"]
		if kind == &"plant_gas":
			if c["state"] == &"OK":
				var r_plant: float = c["load_kw"] / maxf(1.0, c["capacity_kw"])
				var cond_mult := 1.0 + 3.0 * pow(1.0 - float(c["condition"]), 2)
				var h := PLANT_H_BASE * (1.0 + 2.0 * maxf(0.0, r_plant - 0.9)) * cond_mult
				if rng.stream("failures").randf() < 1.0 - exp(-h * dt_gh):
					_trip(id, &"PLANT_TRIP", "")
			continue
		if not THERMAL.has(kind):
			continue
		var effective := cap_eff(id, t_ambient)
		var r: float = (c["load_kw"] / maxf(1.0, effective)) if c["energized"] else 0.0
		# Thermal integration (de-energized components cool toward 0).
		var theta_rated := float(THERMAL[kind][0])
		var tau := float(THERMAL[kind][1])
		var theta_ss := theta_rated * r * r * still_air
		var alpha := float(dt_gs) / (tau + float(dt_gs))
		c["theta_c"] = float(c["theta_c"]) + (theta_ss - float(c["theta_c"])) * alpha
		var temp := t_ambient + float(c["theta_c"])
		if c["state"] != &"OK":
			continue
		# Transformer hard ceiling: it cooks, it does not trip — until 3.0.
		if kind == &"transformer" and r >= XFMR_BURNOUT_R:
			_fail(id, "XFMR_BURNOUT", 0.35)
			continue
		# Inverse-time relay (feeder / substation / transmission only).
		if K_TRIP.has(kind) and c["energized"]:
			if r > R_PICKUP:
				var t_trip := clampf(float(K_TRIP[kind]) / (r * r - 1.0), 2.0, 900.0)
				c["trip_accum"] = float(c["trip_accum"]) + float(dt_gs) / t_trip
				if float(c["trip_accum"]) >= 1.0:
					c["trip_accum"] = 0.0
					_trip(id, StringName(String(kind).to_upper() + "_TRIP"), "")
					continue
			else:
				c["trip_accum"] = maxf(0.0, float(c["trip_accum"]) - float(dt_gs) / TRIP_ACCUM_DECAY_GS)
		# Hazard roll.
		var knee := float(HAZARD[kind][0])
		var span := float(HAZARD[kind][1])
		var h_hot := float(HAZARD[kind][2])
		var h_cold := float(HAZARD[kind][3])
		var stress := maxf(0.0, (temp - knee) / span)
		var cond_mult2 := 1.0 + 3.0 * pow(1.0 - float(c["condition"]), 2)
		var hazard := (h_cold + h_hot * pow(stress, 3)) * cond_mult2
		if c["energized"] and rng.stream("failures").randf() < 1.0 - exp(-hazard * dt_gh):
			if kind == &"transformer":
				_fail(id, "XFMR_BURNOUT", 0.35)
			elif kind == &"feeder":
				_fail(id, "FEEDER_FAULT", 0.05)
			elif kind == &"substation":
				_fail(id, "SUB_FAULT", 0.30)
			else:
				_fail(id, "LINE_FAULT", 0.05)
			continue
		# Condition wear.
		if c["energized"]:
			c["condition"] = clampf(float(c["condition"])
					- WEAR_PER_GH * dt_gh * (1.0 + 6.0 * stress * stress), 0.0, 1.0)


# ---------------------------------------------------------- trips & failures

func _trip(id: String, incident_type: StringName, cause_component: String) -> void:
	var c: Dictionary = _components[id]
	c["state"] = &"OPEN"
	c["reclose_at_gs"] = now_gs + AUTO_RECLOSE_DELAY_GS
	topology_dirty = true
	_tag_cascade(id, cause_component)
	_emit(&"PowerComponentTripped", {"component": id, "incident_type": incident_type,
			"cause_chain": (c["cause_chain"] as Array).duplicate()})


func _fail(id: String, cause: String, damage_fraction: float) -> void:
	var c: Dictionary = _components[id]
	c["state"] = &"FAILED"
	c["failed_cause"] = cause
	c["reclose_at_gs"] = -1
	topology_dirty = true
	_tag_cascade(id, "")
	_emit(&"PowerComponentFailed", {"component": id, "cause": cause,
			"damage_fraction": damage_fraction,
			"cause_chain": (c["cause_chain"] as Array).duplicate()})


func _tag_cascade(id: String, upstream: String) -> void:
	var c: Dictionary = _components[id]
	if now_gs - _last_trip_gs <= CASCADE_WINDOW_GS and _last_trip_component != "" \
			and _last_trip_component != id:
		c["cause_chain"] = [_last_trip_component]
		_emit(&"CascadeStep", {"component": id, "upstream": _last_trip_component})
	else:
		c["cause_chain"] = []
	_last_trip_gs = now_gs
	_last_trip_component = id


func _process_reclose_timers() -> void:
	for id in _order:
		var c: Dictionary = _components[id]
		if c["state"] != &"OPEN" or int(c["reclose_at_gs"]) < 0 or now_gs < int(c["reclose_at_gs"]):
			continue
		# Retry: close and observe next tick's load ratio.
		c["state"] = &"OK"
		c["reclose_at_gs"] = -1
		c["pending_reclose_check"] = true
		topology_dirty = true


## Called during pass C evaluation window via tick order: check the reclose
## outcome one tick after closing.
func evaluate_reclose(id: String, t_ambient: float) -> void:
	var c: Dictionary = _components[id]
	if not c.get("pending_reclose_check", false):
		return
	c.erase("pending_reclose_check")
	var r: float = c["load_kw"] / maxf(1.0, cap_eff(id, t_ambient))
	if r <= AUTO_RECLOSE_OK_R:
		c["reclose_attempts"] = 0
		_emit(&"AutoReclosedOK", {"component": id})
		return
	c["reclose_attempts"] = int(c["reclose_attempts"]) + 1
	if int(c["reclose_attempts"]) >= AUTO_RECLOSE_MAX_ATTEMPTS:
		c["state"] = &"OPEN"
		c["reclose_at_gs"] = -1
		topology_dirty = true
		_emit(&"AutoRecloseLockout", {"component": id})
	else:
		c["state"] = &"OPEN"
		c["reclose_at_gs"] = now_gs + AUTO_RECLOSE_DELAY_GS
		topology_dirty = true


## Crew repair completion: component returns to service at condition 0.85.
func repair_component(id: String) -> void:
	var c: Dictionary = _components[id]
	c["state"] = &"OK"
	c["failed_cause"] = ""
	c["condition"] = maxf(float(c["condition"]), 0.85)
	c["reclose_attempts"] = 0
	c["theta_c"] = 0.0
	topology_dirty = true


func force_open(id: String) -> void:
	_components[id]["state"] = &"OPEN"
	_components[id]["reclose_at_gs"] = -1
	topology_dirty = true


func force_close(id: String) -> void:
	_components[id]["state"] = &"OK"
	topology_dirty = true


# ------------------------------------------------- lightning (doc 07 events)

## Resolution only — doc 07 generates and targets (report 98 C-54).
## Band shares of p_damage: ds1 0.45 / ds2 0.45 / ds3 0.10.
func resolve_lightning(id: String, energy: float, rng: RngStreams) -> Dictionary:
	return _resolve_lightning_with(id, energy, rng.stream("failures").randf())


func _resolve_lightning_with(id: String, energy: float, u: float) -> Dictionary:
	var c: Dictionary = _components[id]
	if bool(c["underground"]):
		return {"band": "ds0", "damage_fraction": 0.0}
	var p := LIGHTNING_P_BASE * (1.0 - LIGHTNING_ARRESTER_FACTOR * int(c["arrester_level"])) \
			* clampf(energy, 0.6, 1.6)
	if u >= p:
		c["condition"] = clampf(float(c["condition"]) - 0.05, 0.0, 1.0)
		_emit(&"SurgeAbsorbed", {"component": id})
		return {"band": "ds0", "damage_fraction": 0.0}
	if u < 0.45 * p:
		_trip(id, &"LIGHTNING_TRIP", "")
		return {"band": "ds1", "damage_fraction": 0.005}
	if u < 0.90 * p:
		var fraction := 0.35 if c["kind"] == &"transformer" else (0.30 if c["kind"] == &"substation" else 0.05)
		_fail(id, "LIGHTNING", fraction)
		return {"band": "ds2", "damage_fraction": fraction}
	_fail(id, "LIGHTNING_DESTROYED", 1.0)
	return {"band": "ds3", "damage_fraction": 1.0, "secondary_fire_p": 0.25}


# ------------------------------------------------------------------- pass D

func _pass_d_energize() -> void:
	var was_energized: Dictionary = {}
	for id in _order:
		was_energized[id] = _components[id]["energized"]
		_components[id]["energized"] = false
	var restore_order: Array[int] = []
	var supply_exists := system_supply_kw > 0.0 or _any_plant_ok()
	if supply_exists:
		for id in _order:
			var c: Dictionary = _components[id]
			if c["kind"] != &"substation" or c["state"] != &"OK":
				continue
			if not _substation_linked(id):
				continue
			_energize_dfs(id, restore_order)
	topology_dirty = false
	var any_restored := false
	for id in _order:
		if _components[id]["energized"] and not bool(was_energized[id]):
			any_restored = true
			break
	if any_restored:
		_emit(&"PowerRestored", {"restore_order": restore_order,
				"powered_fraction": 1.0})
	_emit_streetlight_changes()


## §5.2's `StreetlightsChanged(block_id, lit)`, per land block.
##
## "Today streetlights die with their transformer" (§9 item 12) is the shipped
## rule, and this is it stated exactly: a block's lights are LIT while at least
## one transformer serving that block is energized, and go dark when the last
## one drops. That is deliberately NOT `block_dark_fractions`' ≥60 % weighted
## threshold — that threshold answers "does this block READ as blacked out",
## which is a renderer-ceremony question about buildings. A street is lit or it
## is not, and it goes out with the circuit, not with a quorum of its
## neighbours' windows.
##
## Called from pass D, i.e. exactly when energization is recomputed, so the
## event cannot describe a stale graph. Blocks are visited in sorted order and
## only transitions emit, which keeps the stream identical between the fine and
## coarse paths (report 98 E2 mode-invariance).
func _emit_streetlight_changes() -> void:
	var lit_by_block: Dictionary = {}
	# See `_update_service`: one pass over the components instead of three
	# lookups per building, on a sweep that runs every energization pass.
	var energized := _energized_flags()
	for building_id in _service_ids():
		var block: String = _service[building_id].get("block_id", "")
		if block == "":
			continue
		var transformer_id: String = _attachments.get(building_id, "")
		var lit: bool = transformer_id != "" and bool(energized.get(transformer_id, false))
		lit_by_block[block] = bool(lit_by_block.get(block, false)) or lit
	for block in _sorted_keys(lit_by_block):
		var lit: bool = lit_by_block[block]
		if bool(_block_streetlights.get(block, true)) == lit:
			continue
		_block_streetlights[block] = lit
		_emit(&"StreetlightsChanged", {"block_id": block, "lit": lit})


## The per-block streetlight state doc 11 §2.10 draws, for tests and for a
## renderer that wants to seed itself without waiting for a transition.
func streetlights_lit(block_id: String) -> bool:
	return bool(_block_streetlights.get(block_id, true))


func _any_plant_ok() -> bool:
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] == &"plant_gas" and c["state"] == &"OK":
			return true
	return false


func _substation_linked(substation_id: String) -> bool:
	# Linked to the bulk pool through an OK transmission child (or directly,
	# for test rigs with no transmission modelled).
	var has_link := false
	for child_id in _children_of(substation_id):
		if _components[child_id]["kind"] == &"transmission":
			has_link = true
			if _components[child_id]["state"] == &"OK":
				return true
	return not has_link


func _energize_dfs(root_id: String, restore_order: Array[int]) -> void:
	var stack: Array[String] = [root_id]
	while not stack.is_empty():
		var id: String = stack.pop_back()
		var c: Dictionary = _components[id]
		if c["state"] != &"OK" or shed_feeders.has(id):
			continue
		c["energized"] = true
		restore_order.append(_order.find(id))
		var children := _children_of(id)
		for i in range(children.size() - 1, -1, -1):
			var child: Dictionary = _components[children[i]]
			if child["kind"] != &"transmission":  # links feed IN, not out
				stack.push_back(children[i])


func _children_of(id: String) -> Array:
	if _children.has(id) and not topology_dirty:
		return _children[id]
	var out: Array = []
	for candidate_id in _order:
		if String(_components[candidate_id]["parent"]) == id:
			out.append(candidate_id)
	_children[id] = out
	return out


func is_energized(id: String) -> bool:
	return bool(_components[id]["energized"])


# ------------------------------------------------------ ties & auto-transfer

## Evaluate auto-transfer for a de-energized feeder (called after a trip's
## transfer delay by the coordinator, or directly in tests).
func evaluate_tie_transfer(tie_id: String, t_ambient: float = 25.0) -> Dictionary:
	var tie: Dictionary = _ties[tie_id]
	var a: Dictionary = _components[tie["a"]]
	var b: Dictionary = _components[tie["b"]]
	var orphan: Dictionary
	var partner: Dictionary
	if a["energized"] and not b["energized"]:
		partner = a
		orphan = b
	elif b["energized"] and not a["energized"]:
		partner = b
		orphan = a
	else:
		return {"result": "not_applicable"}
	var r_after: float = (partner["load_kw"] + orphan["load_kw"]) \
			/ maxf(1.0, cap_eff(String(partner["id"]), t_ambient))
	if r_after <= TIE_CLEAN_R:
		tie["closed"] = true
		orphan["parent"] = partner["parent"]
		topology_dirty = true
		_emit(&"TieTransferSuccess", {"tie": tie_id, "r_after": r_after})
		return {"result": "closed", "r_after": r_after}
	if r_after <= TIE_AGGRESSIVE_R or tie["mode"] == &"AGGRESSIVE":
		if tie["mode"] == &"AGGRESSIVE" or (tie["mode"] == &"AUTO" and r_after <= TIE_AGGRESSIVE_R):
			if tie["mode"] == &"AGGRESSIVE":
				tie["closed"] = true
				orphan["parent"] = partner["parent"]
				topology_dirty = true
				var t_trip := clampf(float(K_TRIP[&"feeder"]) / (r_after * r_after - 1.0), 2.0, 900.0)
				_emit(&"TieTransferSuccess", {"tie": tie_id, "r_after": r_after,
						"partner_t_trip_gs": t_trip})
				return {"result": "closed_overloaded", "r_after": r_after,
						"partner_t_trip_gs": t_trip}
	_emit(&"TieTransferBlocked", {"tie": tie_id, "r_after": r_after})
	return {"result": "blocked", "r_after": r_after}


## N-1 headroom: best tie-partner's spare capacity against this feeder's load.
func n1_headroom_kw(feeder_id: String, t_ambient: float = 25.0) -> float:
	var best := -INF
	for tie_id in _sorted_keys(_ties):
		var tie: Dictionary = _ties[tie_id]
		var partner_id := ""
		if String(tie["a"]) == feeder_id:
			partner_id = String(tie["b"])
		elif String(tie["b"]) == feeder_id:
			partner_id = String(tie["a"])
		else:
			continue
		var partner: Dictionary = _components[partner_id]
		best = maxf(best, cap_eff(partner_id, t_ambient) - float(partner["load_kw"])
				- float(_components[feeder_id]["load_kw"]))
	return best


# -------------------------------------------------------------- service side

func _update_service(dt_gs: int, demands: Dictionary) -> void:
	var dt_gh := float(dt_gs) / 3600.0
	# Components are hundreds and buildings are thousands, so "is my transformer
	# energized" is answered once per component instead of twice per building.
	var energized := _energized_flags()
	for building_id in _service_ids():
		var record: Dictionary = _service[building_id]
		var demand := float(demands.get(building_id, 0.0))
		var transformer_id: String = _attachments.get(building_id, "")
		var served := 0.0
		if transformer_id != "" and bool(energized.get(transformer_id, false)):
			served = demand
		record["served_kwh"] = float(record["served_kwh"]) + served * dt_gh
		record["demanded_kwh"] = float(record["demanded_kwh"]) + demand * dt_gh
		# LIT/DARK hysteresis.
		var target: StringName = record["state"]
		if demand > 0.0:
			var ratio := served / demand
			if ratio < DARK_THRESHOLD:
				target = &"DARK"
			elif ratio >= LIT_THRESHOLD:
				target = &"LIT"
		if target != record["candidate"]:
			record["candidate"] = target
			record["candidate_since_gs"] = now_gs
		var sustain := DARK_SUSTAIN_GS if target == &"DARK" else LIT_SUSTAIN_GS
		if target != record["state"] and now_gs - int(record["candidate_since_gs"]) >= sustain:
			record["state"] = target
			_emit(&"BuildingPowerChanged", {"building": building_id, "state": target})


## Game-hour boundary, before doc 03 settles (report 98 C-37).
func settle_hour() -> Dictionary:
	var out := {}
	for building_id in _service_ids():
		var record: Dictionary = _service[building_id]
		var availability := 1.0
		if float(record["demanded_kwh"]) > 0.0:
			availability = clampf(float(record["served_kwh"]) / float(record["demanded_kwh"]), 0.0, 1.0)
		record["availability_prev_hour"] = availability
		record["served_kwh"] = 0.0
		record["demanded_kwh"] = 0.0
		out[building_id] = availability
	return out


func power_availability_hour(building_id: String) -> float:
	return float(_service.get(building_id, {}).get("availability_prev_hour", 1.0))


## The single most-asked question in the sim: doc 06's fire generator asks it for
## every building on every integrator sub-step, and doc 09's district service
## ratio asks it for every building every step. The `{}` default in the old
## one-liner was BUILT BEFORE THE LOOKUP RAN — an empty Dictionary allocated on
## every call, hit or miss. The answer is unchanged, including the "a building
## the grid has never heard of counts as lit" branch that fell out of
## `{}.get("state", &"LIT")`.
func is_powered(building_id: String) -> bool:
	var record: Variant = _service.get(building_id)
	if record == null:
		return true
	return (record as Dictionary).get("state", &"LIT") == &"LIT"


## Weighted dark fraction per block; ≥60% ⇒ block_dark (report 98 C-38).
## weights: {building_id: pop+jobs weight}.
func block_dark_fractions(weights: Dictionary) -> Dictionary:
	var dark: Dictionary = {}
	var total: Dictionary = {}
	for building_id in _service_ids():
		var record: Dictionary = _service[building_id]
		var block: String = record.get("block_id", "")
		if block == "":
			continue
		var w := float(weights.get(building_id, 1.0))
		total[block] = float(total.get(block, 0.0)) + w
		if record["state"] == &"DARK":
			dark[block] = float(dark.get(block, 0.0)) + w
	var out := {}
	for block in _sorted_keys(total):
		var fraction: float = float(dark.get(block, 0.0)) / maxf(1.0, float(total[block]))
		out[block] = {"fraction": fraction, "dark": fraction >= BLOCK_DARK_THRESHOLD}
	return out


# ----------------------------------------------------------- upgrade gate

## Doc 02 E2: the serving path must keep ≤0.90 post-upgrade (§5.3).
func can_upgrade_power(building_id: String, delta_kw: float, t_ambient: float = 25.0) -> Dictionary:
	var transformer_id: String = _attachments.get(building_id, "")
	if transformer_id == "":
		return {"ok": false, "reason": "UNSERVED", "deficit_kw": delta_kw}
	var path := [transformer_id]
	var feeder_id := String(_components[transformer_id]["parent"])
	if feeder_id != "":
		path.append(feeder_id)
		var substation_id := String(_components[feeder_id]["parent"])
		if substation_id != "":
			path.append(substation_id)
	var worst_deficit := 0.0
	for id in path:
		var effective := cap_eff(id, t_ambient)
		var r_after: float = (float(_components[id]["load_kw"]) + delta_kw) / maxf(1.0, effective)
		if r_after > 0.90:
			worst_deficit = maxf(worst_deficit,
					(float(_components[id]["load_kw"]) + delta_kw) - 0.90 * effective)
	if worst_deficit > 0.0:
		return {"ok": false, "reason": "BLOCKED_POWER_CAPACITY", "deficit_kw": worst_deficit}
	return {"ok": true, "reason": "", "deficit_kw": 0.0}


# -------------------------------------------------------- read-only rows (UI)

## Doc 12 §2.10's Infrastructure tab: "power gen/cap/load + worst 5 feeders".
##
## Three ADDITIVE queries, in the same shape as `grid_inventory()`: they compute
## nothing the passes do not already hold, they mutate nothing, and they walk
## `_order` (already sorted) so two calls on the same state produce byte-identical
## rows. `t_ambient` is the reader's — `cap_eff` derates with it, and the UI is
## the only caller that has the weather in hand.

const _UI_ROW_KINDS := {&"feeder": true, &"transmission": true}


## One row per feeder / transmission line, ascending by id:
## `{id, kind, parent, load_kw, capacity_kw, effective_kw, load_ratio,
##   headroom_kw, condition, state, energized, shed, customers}`.
## `load_ratio` is against the CONDITION- and temperature-derated capacity, which
## is the number the protection pass trips on — a UI that showed nameplate would
## call a feeder healthy while it was opening.
func feeder_rows(t_ambient: float = 25.0) -> Array:
	var downstream := _customer_index()
	var out: Array = []
	for id in _order:
		var c: Dictionary = _components[id]
		if not _UI_ROW_KINDS.has(c["kind"]):
			continue
		out.append(_row(String(id), c, t_ambient, _feeder_customers(String(id), downstream)))
	return out


## One row per transformer, ascending by id — the same shape as `feeder_rows()`
## plus the winding temperature, which is what puts a transformer on the worst
## list before its load ratio does.
func transformer_rows(t_ambient: float = 25.0) -> Array:
	var downstream := _customer_index()
	var out: Array = []
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] != &"transformer":
			continue
		var row := _row(String(id), c, t_ambient, int(downstream.get(String(id), 0)))
		row["temp_c"] = t_ambient + float(c["theta_c"])
		out.append(row)
	return out


func _row(id: String, c: Dictionary, t_ambient: float, customers: int) -> Dictionary:
	var effective := cap_eff(id, t_ambient)
	var load: float = float(c["load_kw"])
	return {
		"id": id,
		"kind": String(c["kind"]),
		"parent": String(c["parent"]),
		"level": int(c["level"]),
		"load_kw": load,
		"capacity_kw": float(c["capacity_kw"]),
		"effective_kw": effective,
		"load_ratio": load / maxf(1.0, effective),
		"headroom_kw": effective - load,
		"condition": float(c["condition"]),
		"state": String(c["state"]),
		"energized": bool(c["energized"]),
		"shed": shed_feeders.has(id),
		"customers": customers,
	}


## {transformer id: attached building count}, one pass over the attachment map.
## Order is irrelevant to a count, so this deliberately skips a sort.
func _customer_index() -> Dictionary:
	var out: Dictionary = {}
	for building_id in _attachments:
		var transformer_id: String = _attachments[building_id]
		out[transformer_id] = int(out.get(transformer_id, 0)) + 1
	return out


func _feeder_customers(feeder_id: String, downstream: Dictionary) -> int:
	var count := 0
	for id in _order:
		var c: Dictionary = _components[id]
		if c["kind"] == &"transformer" and String(c["parent"]) == feeder_id:
			count += int(downstream.get(String(id), 0))
	return count


## The three city-wide figures §2.10 puts above the worst-N lists:
## `{supply_kw, demand_kw, plant_capacity_kw, headroom_kw, load_ratio,
##   feeders_over, transformers_over, shed_feeders}`. `over` counts what the
## protection pass calls loaded past pickup (`R_PICKUP`), not past 100 %.
func capacity_summary(t_ambient: float = 25.0) -> Dictionary:
	var plant_capacity := 0.0
	var feeders_over := 0
	var transformers_over := 0
	for id in _order:
		var c: Dictionary = _components[id]
		match c["kind"]:
			&"plant_gas":
				if String(c["state"]) == "OK":
					plant_capacity += cap_eff(String(id), t_ambient)
			&"feeder", &"transmission":
				if float(c["load_kw"]) > R_PICKUP * cap_eff(String(id), t_ambient):
					feeders_over += 1
			&"transformer":
				if float(c["load_kw"]) > R_PICKUP * cap_eff(String(id), t_ambient):
					transformers_over += 1
	return {
		"supply_kw": system_supply_kw,
		"demand_kw": system_demand_kw,
		"plant_capacity_kw": plant_capacity,
		"headroom_kw": system_supply_kw - system_demand_kw,
		"load_ratio": system_demand_kw / maxf(1.0, system_supply_kw),
		"feeders_over": feeders_over,
		"transformers_over": transformers_over,
		"shed_feeders": shed_feeders.size(),
	}


# ------------------------------------------------------------- inventory

## The contract doc 03's E_grid bills against (report 98 C-12).
func grid_inventory() -> Dictionary:
	var nodes: Array = []
	var lines: Array = []
	var plants: Array = []
	for id in _order:
		var c: Dictionary = _components[id]
		match c["kind"]:
			&"substation", &"transformer":
				nodes.append({"id": id, "rated_mva": float(c["capacity_kw"]) / 1000.0,
						"condition": c["condition"]})
			&"feeder", &"transmission":
				lines.append({"id": id, "line_km": (c["route"] as Array).size() * 0.008,
						"condition": c["condition"]})
			&"plant_gas":
				plants.append({"id": id, "plant_capacity_mw": float(c["capacity_kw"]) / 1000.0,
						"condition": c["condition"]})
	return {"nodes": nodes, "lines": lines, "plants": plants}


# ------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	var components: Array = []
	for id in _order:
		var c: Dictionary = (_components[id] as Dictionary).duplicate(true)
		c["tile"] = [c["tile"].x, c["tile"].y] if c["tile"] is Vector2i else c["tile"]
		components.append(c)
	var ties: Array = []
	for tie_id in _sorted_keys(_ties):
		ties.append((_ties[tie_id] as Dictionary).duplicate(true))
	var service := {}
	for building_id in _service_ids():
		service[building_id] = (_service[building_id] as Dictionary).duplicate(true)
	return {"section_version": 1, "now_gs": now_gs, "components": components,
			"ties": ties, "attachments": _attachments.duplicate(),
			"service": service, "shed_feeders": shed_feeders.duplicate(),
			"shed_rotation_next_gs": shed_rotation_next_gs}


func deserialize(data: Dictionary) -> void:
	_components.clear()
	_order.clear()
	_children.clear()
	for c in data.get("components", []):
		var component: Dictionary = c
		if component["tile"] is Array:
			component["tile"] = Vector2i(int(component["tile"][0]), int(component["tile"][1]))
		component["kind"] = StringName(String(component["kind"]))
		component["state"] = StringName(String(component["state"]))
		_components[String(component["id"])] = component
		_order.append(String(component["id"]))
	_order.sort()
	_ties.clear()
	for tie in data.get("ties", []):
		var record: Dictionary = tie
		record["mode"] = StringName(String(record["mode"]))
		_ties[String(record["id"])] = record
	_attachments = data.get("attachments", {})
	_service.clear()
	_service_order_dirty = true
	for building_id in data.get("service", {}):
		var record: Dictionary = data["service"][building_id]
		record["state"] = StringName(String(record["state"]))
		record["candidate"] = StringName(String(record["candidate"]))
		record["priority_class"] = StringName(String(record["priority_class"]))
		_service[building_id] = record
	now_gs = int(data.get("now_gs", 0))
	shed_feeders = data.get("shed_feeders", [])
	shed_rotation_next_gs = int(data.get("shed_rotation_next_gs", 0))
	topology_dirty = true


# ---------------------------------------------------------------- plumbing

func _emit(event_type: StringName, payload: Dictionary) -> void:
	var event := payload.duplicate()
	event["type"] = event_type
	_events.append(event)


static func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys


## {component_id: energized} for the whole roster, built once per sweep. Order
## is irrelevant — it is a lookup table, not a sum.
func _energized_flags() -> Dictionary:
	var out: Dictionary = {}
	for component_id in _components:
		out[component_id] = bool((_components[component_id] as Dictionary)["energized"])
	return out


## Ascending building ids over `_service`. Read-only for every caller; none of
## the six sweeps adds or removes a service record while iterating.
func _service_ids() -> Array:
	if _service_order_dirty:
		_service_order = _sorted_keys(_service)
		_service_order_dirty = false
	return _service_order
