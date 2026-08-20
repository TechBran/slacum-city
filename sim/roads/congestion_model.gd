class_name CongestionModel
extends RefCounted
## Doc 10 §2.10 — one scalar per edge, `congestion_index c_e ∈ [0,2]` with
## `1.0 = at capacity` (doc 06's scale, adopted verbatim so f_flow,
## traffic_accident generation and congestion_ref = 1.5 need no conversion).
##
##   c_raw(e) = clamp(K_base · D_tod · L_dens · E_evt + I_inc + wx_cong_add, 0, 2)
##   c_e ← c_e + (c_raw − c_e) · smooth(dt),  smooth = 1 − (1 − 0.35)^dt_gm
##
## NO civilian vehicles are simulated and there is NO feedback loop: congestion
## is a forward function of city state and time, which is what makes it stable,
## cheap, and reproducible offline (§2.10).
##
## The authoritative value lives on the edge record (`edge["congestion"]`) so
## the planner reads one structure; this class owns writing it.

var tun: RoadTunables
var graph: RoadGraph
## Bumped whenever any c_e moves; the route cache re-prices (never re-paths) on
## a stale epoch (§2.14).
var epoch: int = 0
## Edges whose value moved on the last [recompute] — the number `moved` returns,
## kept because it is the DIRTY SET'S OWN CENSUS and the only honest way to see
## how many edges a skip-list could ever skip. Observational: nothing in the sim
## reads it, it is not serialized, and it cannot reach a state hash.
var last_moved: int = 0


func _init(p_graph: RoadGraph, p_tun: RoadTunables) -> void:
	graph = p_graph
	tun = p_tun


## The four land-use profiles, in the order §2.10 sums them. A `const`, not a
## literal inside the loop: `d_tod` is the innermost thing a full pass does and
## the literal was a fresh Array on every edge.
const PROFILES: Array[String] = ["civ", "com", "ind", "res"]

## §2.10 `D_tod(e,t)`: four land-use curves, 24 hourly samples, linear interp.
## `hour` comes from doc 01's frozen TimeContext — roads never samples a clock.
func d_tod(weights: Dictionary, hour: float) -> float:
	var wrapped := fposmod(hour, 24.0)
	var h := int(floor(wrapped))
	var frac := wrapped - float(h)
	var next := (h + 1) % 24
	var total := 0.0
	for profile in PROFILES:
		var weight := float(weights.get(profile, 0.0))
		if weight == 0.0:
			continue
		var curve: Array = tun.tod_curves.get(profile, [])
		if curve.size() != 24:
			continue
		total += weight * lerp(float(curve[h]), float(curve[next]), frac)
	return total


## §2.10 `L_dens(e) = clamp(0.20 + DENS_K · pj(e), 0.20, 1.60)`.
## `pj_by_edge` is Σ(population + jobs) of buildings whose access tile is within
## DENS_RADIUS_TILES of any tile of the edge. Refreshed once per game-day.
func refresh_density(pj_by_edge: Dictionary) -> void:
	for edge_id in graph.edge_ids_ref():
		var record: Dictionary = graph.edge(edge_id)
		var pj := float(pj_by_edge.get(edge_id, 0.0))
		record["dens_index"] = clampf(tun.dens_min + tun.dens_k * pj, tun.dens_min, tun.dens_max)


func density_of(edge_id: int) -> float:
	return float(graph.edge(edge_id).get("dens_index", tun.dens_min))


## The unsmoothed forward function. `inputs` carries:
##   hour: float · wx_cong_add: float · i_inc: {edge_id: float}
##   weights: {district_id: {res,com,ind,civ}} · evt: {edge_id: float}
func c_raw(edge_id: int, inputs: Dictionary) -> float:
	var record: Dictionary = graph.edge(edge_id)
	if record.is_empty():
		return 0.0
	var hour := float(inputs.get("hour", 12.0))
	return _c_raw_of(edge_id, record,
			_kd(int(record["road_class"]), String(record.get("district_id", "")),
					inputs.get("weights", {}), hour),
			inputs.get("i_inc", {}), inputs.get("evt", {}),
			float(inputs.get("wx_cong_add", 0.0)))


## §2.10's `K_base(class) · D_tod(district, hour)` — the ONLY factor of `c_raw`
## that is not per-edge, in one place so the single-edge path and the
## whole-graph path cannot disagree about it. A whole-graph pass resolves it
## once per (class, district) PROFILE instead of once per edge; see
## `_ensure_profiles`.
func _kd(road_class: int, district: String, weights_by_district: Dictionary,
		hour: float) -> float:
	var weights: Dictionary = weights_by_district.get(district, tun.default_profile_weights)
	return tun.k_base(road_class) * _d_tod_memo(district, weights, hour)


## The same arithmetic in the same order as `c_raw`, with the shared factor and
## the `inputs` lookups hoisted to the caller — a whole-graph pass does them
## once instead of once per edge. `c_raw` above IS this function; there is no
## second formula.
##
## The association is deliberately preserved. `K · demand · dens · evt` binds
## left to right, so `kd = K · demand` and then `kd · dens · evt` is the SAME
## float, term for term and rounding for rounding. Regrouping it any other way
## is the pour-joint mistake in `road_surface.gdshader` wearing a different hat.
func _c_raw_of(edge_id: int, record: Dictionary, kd: float,
		i_inc: Dictionary, evt_by_edge: Dictionary, wx_cong_add: float) -> float:
	var evt := float(evt_by_edge.get(edge_id, 1.0))
	var base := kd * float(record.get("dens_index", tun.dens_min)) * evt
	var additive := float(i_inc.get(edge_id, 0.0)) + wx_cong_add
	return clampf(base + additive, 0.0, tun.congestion_index_max)


# --- the (class, district) profile table -----------------------------------
#
# **This is the dirty set the congestion pass can actually have** (report 98
# RR-39). A skip-list over EDGES cannot exist: `hour` reaches every edge through
# `D_tod` and the smoother never lands on its target, so an ordinary pass moves
# every edge in the graph — 3,092 of 3,092 on the benchmark city, which
# `tools/profile_congestion.gd` prints as a census rather than a claim. What DOES
# hold still between passes is each edge's road CLASS and DISTRICT, and those two
# are the whole of `c_raw`'s shared factor. So they are resolved once per graph
# and priced once per pass, and the per-edge loop reads an index.
#
# The key is exact. `road_class` is written only where an edge record is built,
# and `district_id` only in `RoadNetwork._assign_districts` — both of which are
# followed by `RoadNetwork._refresh_all_edge_state`, which calls
# `invalidate_profiles`. `graph_version` is carried as well, so an edit that
# somehow skipped that path still cannot serve a stale slot.
var profile_epoch: int = 0
var _built_epoch: int = -1
var _built_version: int = -1
var _profile_of: Dictionary = {}                       # edge_id -> profile index
var _profile_class: PackedInt32Array = PackedInt32Array()
var _profile_district: PackedStringArray = PackedStringArray()
var _profile_kd: PackedFloat64Array = PackedFloat64Array()


## Drop the table. Called by `RoadNetwork._refresh_all_edge_state`, which is the
## only place an edge's class or district can move.
func invalidate_profiles() -> void:
	profile_epoch += 1


func _ensure_profiles() -> void:
	if _built_epoch == profile_epoch and _built_version == graph.graph_version:
		return
	_built_epoch = profile_epoch
	_built_version = graph.graph_version
	_profile_of.clear()
	_profile_class.clear()
	_profile_district.clear()
	var seen: Dictionary = {}
	for edge_id in graph.edge_ids_ref():
		var record: Dictionary = graph.edge(edge_id)
		if record.is_empty():
			continue
		var road_class := int(record["road_class"])
		var district := String(record.get("district_id", ""))
		var key := "%d|%s" % [road_class, district]
		var slot := int(seen.get(key, -1))
		if slot < 0:
			slot = _profile_class.size()
			seen[key] = slot
			_profile_class.append(road_class)
			_profile_district.append(district)
		_profile_of[edge_id] = slot
	_profile_kd.resize(_profile_class.size())


## Price every profile for THIS pass's hour. Called inside the pass memo, so a
## district shared by two classes still samples `D_tod` exactly once.
func _price_profiles(weights_by_district: Dictionary, hour: float) -> void:
	for i in _profile_class.size():
		_profile_kd[i] = _kd(_profile_class[i], _profile_district[i],
				weights_by_district, hour)


# --- D_tod memo ------------------------------------------------------------
# D_tod depends only on (district profile weights, hour), and a whole-graph pass
# holds `hour` fixed while sweeping thousands of edges across a HANDFUL of
# districts. The memo is per-pass scratch: opened by the batch entry points
# below, cleared when they finish, never read outside one, never serialized.
var _memo_open: bool = false
var _memo: Dictionary = {}  # district_id -> D_tod



func _open_memo() -> void:
	_memo.clear()
	_memo_open = true


func _close_memo() -> void:
	_memo_open = false
	_memo.clear()


func _d_tod_memo(district: String, weights: Dictionary, hour: float) -> float:
	if not _memo_open:
		return d_tod(weights, hour)
	var hit: Variant = _memo.get(district)
	if hit != null:
		return float(hit)
	var value := d_tod(weights, hour)
	_memo[district] = value
	return value


## Σ c_raw over `edge_ids` into `sink` (edge_id -> running total), in the given
## order. The daily condition sampler's inner loop, lifted here so it shares the
## pass memo — same additions, same order, same floats.
func accumulate_c_raw(edge_ids: Array, inputs: Dictionary, sink: Dictionary) -> void:
	var weights_by_district: Dictionary = inputs.get("weights", {})
	var hour := float(inputs.get("hour", 12.0))
	var i_inc: Dictionary = inputs.get("i_inc", {})
	var evt_by_edge: Dictionary = inputs.get("evt", {})
	var wx_cong_add := float(inputs.get("wx_cong_add", 0.0))
	_open_memo()
	_ensure_profiles()
	_price_profiles(weights_by_district, hour)
	for edge_id in edge_ids:
		var found: Variant = graph.edge_or_null(edge_id)
		var value := 0.0
		if found != null:
			value = _c_raw_of(edge_id, found,
					_kd_for(edge_id, found, weights_by_district, hour),
					i_inc, evt_by_edge, wx_cong_add)
		sink[edge_id] = float(sink.get(edge_id, 0.0)) + value
	_close_memo()


## This edge's priced profile. The fallback is not dead code: a caller may hand
## in an id the table was built without, and the answer must be the same float
## either way — which it is, because both roads end at `_kd`.
func _kd_for(edge_id: int, record: Dictionary, weights_by_district: Dictionary,
		hour: float) -> float:
	var slot := int(_profile_of.get(edge_id, -1))
	if slot >= 0:
		return _profile_kd[slot]
	return _kd(int(record["road_class"]), String(record.get("district_id", "")),
			weights_by_district, hour)


## §2.10 `I_inc(e)`: own closure + 0.50 × 1 hop + 0.25 × 2 hops + the dark-signal
## additive (report 98 G-6). Computed by BFS outward from each closure — never
## by scanning every edge — because closures are few (cap 128).
## `closure_cause_by_edge` is {edge_id: cause_name}.
func compute_i_inc(closure_cause_by_edge: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var closed_ids: Array = closure_cause_by_edge.keys()
	closed_ids.sort()
	for edge_id in closed_ids:
		var cause := String(closure_cause_by_edge[edge_id])
		var add := float(tun.cause_row(cause).get("cong_add", 0.0))
		if add == 0.0:
			continue
		out[edge_id] = float(out.get(edge_id, 0.0)) + add
		var neighbours := graph.edges_within_hops(edge_id, 2)
		var neighbour_ids := neighbours.keys()
		neighbour_ids.sort()
		for other in neighbour_ids:
			var hop := int(neighbours[other])
			var scale := tun.spillback_hop1 if hop == 1 else tun.spillback_hop2
			out[other] = float(out.get(other, 0.0)) + add * scale
	# Dark signalised endpoints add congestion on top of their delay (G-6).
	# Asked of the graph as {edge_id: dark endpoints} rather than edge by edge:
	# with every signal lit — the normal case — that is an empty dictionary and
	# this loop does not run at all, instead of an O(E) sweep every recompute.
	var dark_by_edge := graph.dark_signal_counts_by_edge()
	var dark_edges := dark_by_edge.keys()
	dark_edges.sort()
	for edge_id in dark_edges:
		out[edge_id] = float(out.get(edge_id, 0.0)) \
				+ tun.dark_signal_add * float(int(dark_by_edge[edge_id]))
	return out


## Smoothed update over a set of edges. `dt_game_minutes` makes coarse offline
## steps agree with fine online steps: one 1-game-hour coarse step applies
## 1 − 0.65^60 ≈ 1.0, landing exactly on c_raw — where 60 fine steps converge.
## Returns the number of edges whose value moved.
##
## `raw_sink`, when given, receives this pass's c_raw per edge. The daily
## condition sampler wants exactly those numbers whenever it samples at the same
## hour this pass ran at (every coarse step does), and c_raw is by far the
## expensive half — `dt_game_minutes` and `bypass_smoothing` only shape `alpha`,
## which is applied afterwards.
##
## `ids_ascending` is the caller promising that `edge_ids` is ALREADY in
## ascending id order — which `RoadGraph.edge_ids_ref()` is by construction, and
## which the every-game-minute full pass hands straight in. The defensive
## duplicate-and-sort of three thousand ids that the promise skips is not free at
## sixty passes a game-hour. Callers that pass a dirty SET (`dirty.keys()`) leave
## it alone and still get sorted; the iteration order is unchanged either way,
## which is what the float sums downstream depend on.
func recompute(edge_ids: Array, inputs: Dictionary, raw_sink: Variant = null,
		ids_ascending: bool = false) -> int:
	var dt_gm := float(inputs.get("dt_game_minutes", 0.25))
	var bypass := bool(inputs.get("bypass_smoothing", false))
	var alpha := 1.0 if bypass else RoadCosts.smoothing_alpha(tun.smooth_per_game_minute, dt_gm)
	var moved := 0
	var sorted_ids: Array = edge_ids
	if not ids_ascending:
		sorted_ids = edge_ids.duplicate()
		sorted_ids.sort()
	# One `inputs` unpack for the whole pass instead of six lookups per edge.
	var weights_by_district: Dictionary = inputs.get("weights", {})
	var hour := float(inputs.get("hour", 12.0))
	var i_inc: Dictionary = inputs.get("i_inc", {})
	var evt_by_edge: Dictionary = inputs.get("evt", {})
	var wx_cong_add := float(inputs.get("wx_cong_add", 0.0))
	var cap := tun.congestion_index_max
	var raw: Dictionary = raw_sink if raw_sink != null else {}
	var collect := raw_sink != null
	# The pass's own running mean. `mean_congestion()` used to walk every edge a
	# SECOND time immediately after this loop had written every one of them; the
	# sum is taken here instead, over the same ids in the same ascending order,
	# adding each value the instant it is stored. A `null` record contributes
	# nothing, which is what `+ 0.0` did.
	var sum := 0.0
	_open_memo()
	_ensure_profiles()
	_price_profiles(weights_by_district, hour)
	for edge_id in sorted_ids:
		var found: Variant = graph.edge_or_null(edge_id)
		if found == null:
			continue
		var record: Dictionary = found
		var target := _c_raw_of(edge_id, record,
				_kd_for(edge_id, record, weights_by_district, hour),
				i_inc, evt_by_edge, wx_cong_add)
		if collect:
			raw[edge_id] = target
		var current := float(record["congestion"])
		var updated := current + (target - current) * alpha
		if absf(updated - current) > 1e-9:
			moved += 1
		var stored := clampf(updated, 0.0, cap)
		record["congestion"] = stored
		sum += stored
	_close_memo()
	last_moved = moved
	last_pass_sum = sum
	last_pass_count = sorted_ids.size()
	if moved > 0:
		epoch += 1
	return moved


## The mean of the c_e values the last [recompute] wrote, over the ids it was
## given. `RoadNetwork.full_pass` reads this instead of calling
## [mean_congestion] — same values, same ascending order, same additions, one
## whole-graph sweep instead of two. **Only a pass over the WHOLE graph may use
## it**: the dirty-set callers hand in a handful of ids and their mean is over
## edges the pass never looked at, so they still take the second sweep.
var last_pass_sum: float = 0.0
var last_pass_count: int = 0


func last_pass_mean() -> float:
	return 0.0 if last_pass_count <= 0 else last_pass_sum / float(last_pass_count)


func congestion_of(edge_id: int) -> float:
	return float(graph.edge(edge_id).get("congestion", 0.0))


func set_congestion(edge_id: int, value: float) -> void:
	var record: Dictionary = graph.edge(edge_id)
	if not record.is_empty():
		record["congestion"] = clampf(value, 0.0, tun.congestion_index_max)
		epoch += 1


func mean_congestion(edge_ids: Array = []) -> float:
	# Ascending-id order is load-bearing: this is a float sum, and summing the
	# same values in a different order is not guaranteed to be the same number.
	var ids: Array = edge_ids if not edge_ids.is_empty() else graph.edge_ids_ref()
	if ids.is_empty():
		return 0.0
	var total := 0.0
	for edge_id in ids:
		var found: Variant = graph.edge_or_null(edge_id)
		total += float(found.get("congestion", 0.0)) if found != null else 0.0
	return total / float(ids.size())
