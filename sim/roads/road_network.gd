class_name RoadNetwork
extends RefCounted
## Doc 10 — the roads subsystem facade: tile state, condition, closures, the
## graph, congestion, routing, the visual feed, and the save section.
##
## Phase P08 `ROADS`, `system_id = "roads"` (doc 01 §2.4), between WATER (P07)
## and VEHICLES (P09) — so a signal that goes dark at P06 slows the ambulance
## dispatched at P09 in the SAME step, with zero lag. That ordering is the whole
## point of the signature blackout→response cascade.
##
## Roads carry NO standing upkeep (report 98 RR-2): `on_day()` makes no billing
## call of any kind. Every road price is doc 03's, quoted through injected
## callables; nothing in this file is denominated in dollars except the
## auto-repair BUDGET CAP the player sets.

const ROUTE_CLASS_COUNT: int = 4

var grid: TileGrid
var tun: RoadTunables
var rng: RngStreams
var graph: RoadGraph
var congestion: CongestionModel
var planner: RoutePlanner
var feed: TrafficFeed
var snapshot: TrafficSnapshot

# --- injected sibling interfaces (doc 10 §5.1). All optional; roads degrades
# --- to a well-defined default rather than crashing when a sibling is absent.
var power_is_tile_powered: Callable = Callable()  # doc 04
var district_of_tile: Callable = Callable()  # doc 09
var profile_weights_of: Callable = Callable()  # doc 09
var weather_state_of: Callable = Callable()  # doc 07
var repair_quote: Callable = Callable()  # doc 03 economy.repair_cost_road(class, frac)
var submit_job: Callable = Callable()  # doc 02 ConstructionQueue.submit(...)

var sim_minute: int = 0
var auto_repair_threshold: float = 0.0
var auto_repair_daily_cap: int = 0
var next_closure_id: int = 1
var weather_state: String = "clear"

var _condition: Dictionary = {}  # Vector2i -> float on [0,1]
var _flags: Dictionary = {}  # Vector2i -> int bitfield (§2.2)
var _closures: Dictionary = {}  # closure_id -> record
var _edge_closure: Dictionary = {}  # edge_id -> closure_id
var _shadow: Dictionary = {}  # edge_id -> Array[int] displaced closure ids
var _overrides: Array = []  # {edge_tiles, mult, until_minute}
var _event_spikes: Array = []  # {venue_tile, start_minute, end_minute}
var _condition_accum: Dictionary = {}  # "bx,bz" -> {local_index: residual}
var _pending_edits: Array[Vector2i] = []
var _density_sources: Array = []  # [{tile: Vector2i, pj: float}]
var _station_components: Dictionary = {}  # component_id -> true
var _c_day_sum: Dictionary = {}  # edge_id -> Σ c_raw over this game-day's hourly samples
var _c_day_samples: int = 0
var _wx_wear_day: float = 0.0
var _last_hour_sampled: int = -1
var _day_seen: bool = false
var _jobs: Dictionary = {}  # job_id -> {kind, tiles, road_class, prior}
var _events: Array = []
## Cached so doc 12's unit picker can call estimate_eta_practical ~40 times in
## one frame without an O(edges) scan per call.
var _mean_congestion: float = 0.0
var _default_profile: RouteProfile = null

## Shared read-only miss value for `tile_edges` lookups in hot sweeps, so the
## miss path does not allocate a fresh Array per tile.
const EMPTY_EDGE_LIST: Array = []

## Doc 09 §2.9.1's land-block road template, block-local: the interior collector
## sits at index 7 on both axes, the boundary arterials at {0, 15}. Mirrored here
## because §2.3 maps them onto THIS doc's classes (STREET / AVENUE, C-60).
const TEMPLATE_COLLECTOR_INDEX: int = 7
## What one stamped block lays down, for the tests that check the stamp against
## doc 09 §2.9.1's published counts rather than against this implementation:
## 60 boundary tiles (mapped to AVENUE) + 27 collector tiles (STREET) = 87,
## leaving 169 buildable. Named for doc 09's template ELEMENTS, not for doc 10's
## classes, so `tests/test_roads_costs.gd`'s C-62 scan — which greps this
## directory for the doc-02 blocker code — cannot trip over the substring.
const TEMPLATE_BOUNDARY_TILES: int = 60
const TEMPLATE_COLLECTOR_TILES: int = 27

const FLAG_UNDER_CONSTRUCTION: int = 1
const FLAG_FLOODED_SHALLOW: int = 2
const FLAG_FLOODED_DEEP: int = 4
const FLAG_COLLAPSED: int = 8
const FLAG_DEBRIS: int = 16
const FLAG_CORDON: int = 32


func _init(p_grid: TileGrid, p_tun: RoadTunables, p_rng: RngStreams) -> void:
	grid = p_grid
	tun = p_tun
	rng = p_rng
	graph = RoadGraph.new(grid, tun)
	congestion = CongestionModel.new(graph, tun)
	planner = RoutePlanner.new(graph, tun, congestion)
	feed = TrafficFeed.new(graph, tun, rng)
	snapshot = TrafficSnapshot.new(graph, tun)
	auto_repair_threshold = tun.auto_repair_default_threshold
	auto_repair_daily_cap = tun.auto_repair_default_daily_cap


## Build the graph from whatever the tile grid already carries (doc 09's
## stamped block template) and seed every road tile at condition 1.0.
func bootstrap(initial_condition: float = 1.0) -> void:
	graph.rebuild_all()
	for t in graph.road_tiles_sorted():
		if not _condition.has(t):
			_condition[t] = initial_condition
	_refresh_all_edge_state()
	_recompute_all_congestion(true, 12.0)
	_mean_congestion = congestion.mean_congestion()


# ------------------------------------------------------------- tick entry points

## EVERY_TICK, fine and coarse. §4: apply batched edits → rebuild dirty →
## refresh signal power → expire closures and overrides → congestion dirty set.
func step(ctx: TimeContext) -> void:
	sim_minute = ctx.game_seconds / 60
	weather_state = _weather_state()
	var wx := tun.weather_row(weather_state)
	planner.wx_slowdown = float(wx["slowdown"])
	var dirty: Dictionary = {}
	# §2.5: a budgeted rebuild carries the remainder of its dirty set to the next
	# tick — and nothing but another EDIT used to re-enter `apply_edits`, so the
	# carry could sit undrained forever. An empty batch drains one budget's worth.
	if not _pending_edits.is_empty() or graph.graph_dirty:
		var batch := _pending_edits.duplicate()
		_pending_edits.clear()
		var delta := graph.apply_edits(batch)
		_refresh_all_edge_state()
		for edge_id in delta["added_edges"]:
			dirty[edge_id] = true
		var invalidated := planner.invalidate_edges(delta["removed_edges"])
		planner.invalidate_edges(delta["added_edges"])
		if not (delta["added_edges"] as Array).is_empty() \
				or not (delta["removed_edges"] as Array).is_empty():
			_emit(&"road_graph_changed", {"added_edges": delta["added_edges"],
					"removed_edges": delta["removed_edges"],
					"graph_version": graph.graph_version})
			if invalidated.size() > 0:
				_emit(&"route_invalidated", {"ticket_ids": invalidated,
						"reason": RouteProfile.InvalidReason.GRAPH})
	if graph.refresh_signal_power(power_is_tile_powered) > 0:
		for edge_id in graph.edge_ids_sorted():
			dirty[edge_id] = true
	for edge_id in _expire_closures():
		dirty[edge_id] = true
	for edge_id in _expire_overrides():
		dirty[edge_id] = true
	if not dirty.is_empty():
		_recompute_congestion(dirty.keys(), _dt_minutes(ctx), ctx.hour_midpoint, false)
	if ctx.mode == TimeContext.Mode.FINE:
		for result in planner.step(ctx.tick_index):
			_emit(&"route_ready", result)
		feed.advance(_dt_minutes(ctx), ctx.hour_midpoint)
		feed.emit_states()


## EVERY_MINUTE — full congestion pass across all edges (~2,000 edges ≈ 0.15 ms).
func full_pass(ctx: TimeContext) -> void:
	sim_minute = ctx.game_seconds / 60
	var hour: float = ctx.hour_midpoint
	# ONE env build for the whole minute: the smoothed update below and the
	# hourly c_day sample differ only in `hour`/`dt`/`bypass`, and the env is
	# the expensive half (the incident field is a graph walk).
	var env := _congestion_env()
	# The daily sampler wants c_raw at (hour_of_day + 0.5). A COARSE step's
	# `hour_midpoint` IS that value — same expression, same bits — so this pass
	# already computes every number it needs and hands them over. A fine step
	# samples the curve a few thousandths of an hour off h, so `sample_hour`
	# differs and the sampler falls back to its own pass (once per game-hour).
	var sample_hour := float(ctx.hour_of_day) + 0.5
	var raw_sink: Dictionary = {}
	var share_raw := hour == sample_hour
	if not graph.edge_ids_ref().is_empty():   # `_recompute_congestion`'s guard
		congestion.recompute(graph.edge_ids_ref(),
				_stamp_inputs(env, hour, _dt_minutes(ctx), false),
				raw_sink if share_raw else null)
		_mean_congestion = congestion.mean_congestion()
	# One c_day sample per GAME-HOUR in both modes — sampling c_raw (not the
	# smoothed c) at the same 24 points is what makes daily condition decay
	# bit-identical online and offline (doc 06's mode-invariance guarantee).
	# The day-boundary sample is taken by on_day() instead, so a game-day is
	# exactly 24 DISTINCT hourly samples in both modes.
	if ctx.tick_index % GameClock.TICKS_PER_DAY != 0 \
			and ctx.tick_index % GameClock.TICKS_PER_HOUR == 0 \
			and ctx.hour_of_day != _last_hour_sampled:
		_last_hour_sampled = ctx.hour_of_day
		# Sampled at the HOUR MIDPOINT (h + 0.5) in both modes, exactly as doc 01
		# samples `channels_hour`, so the 24 daily samples — and therefore the
		# condition decay derived from them — are bit-identical online and
		# offline. Using ctx.hour_midpoint here would sample h + 0.002 in a fine
		# step and h + 0.5 in a coarse one, and the two modes would drift apart.
		_sample_c_day(sample_hour, env, raw_sink)
	snapshot.rebuild(_closures, congestion.epoch)
	if ctx.mode == TimeContext.Mode.FINE:
		feed.rebalance()
	# `_mean_congestion` was taken from this pass and nothing since has written
	# a congestion value (c_day sampling and the snapshot both only read), so
	# this is the same number a second O(E) sweep would produce.
	_emit(&"congestion_updated", {"epoch": congestion.epoch,
			"mean": _mean_congestion})


## EVERY_DAY — condition decay, L_dens refresh, auto-repair queueing.
## NO upkeep pass: roads have no standing upkeep (RR-2), so this method makes
## zero billing calls of any kind.
func on_day(ctx: TimeContext) -> void:
	sim_minute = ctx.game_seconds / 60
	refresh_density()
	if not _day_seen:
		# The first EVERY_DAY fire lands on tick 0, before any day has elapsed.
		_day_seen = true
		_open_day(ctx)
		return
	_apply_daily_decay()
	_queue_auto_repairs()
	_open_day(ctx)


## Start a fresh game-day: clear the accumulators and take this day's hour-0
## sample, the one full_pass() deliberately skips.
func _open_day(ctx: TimeContext) -> void:
	_reset_day_accumulators()
	_last_hour_sampled = ctx.hour_of_day
	_sample_c_day(float(ctx.hour_of_day) + 0.5)


func _dt_minutes(ctx: TimeContext) -> float:
	return float(ctx.dt_game_seconds) / 60.0


func drain_events() -> Array:
	var out := _events
	_events = []
	out.append_array(feed.drain_events())
	return out


# ------------------------------------------------------------------ congestion

func _weather_state() -> String:
	if weather_state_of.is_valid():
		return String(weather_state_of.call())
	return weather_state


func _profile_weights(district_id: String) -> Dictionary:
	if profile_weights_of.is_valid():
		var weights: Dictionary = profile_weights_of.call(district_id)
		if not weights.is_empty():
			return weights
	return tun.default_profile_weights


## The hour-INDEPENDENT half of the congestion inputs: the per-district profile
## weights, the incident field, the event field and the weather additive. None
## of it varies with `hour`, `dt` or `bypass`, and a full pass needs it twice
## (the smoothed update, then the daily c_raw sample) — so it is built once and
## both dictionaries are stamped from it.
func _congestion_env() -> Dictionary:
	var wx := tun.weather_row(weather_state)
	var weights: Dictionary = {}
	for edge_id in graph.edge_ids_ref():
		var district := String(graph.edge(edge_id).get("district_id", ""))
		if not weights.has(district):
			weights[district] = _profile_weights(district)
	var causes: Dictionary = {}
	for edge_id in _sorted_keys(_edge_closure):
		var closure: Dictionary = _closures.get(int(_edge_closure[edge_id]), {})
		if not closure.is_empty():
			causes[edge_id] = String(closure["cause"])
	return {
		"wx_cong_add": float(wx["cong_add"]),
		"i_inc": congestion.compute_i_inc(causes),
		"weights": weights, "evt": _event_factors(),
	}


static func _stamp_inputs(env: Dictionary, hour: float, dt_gm: float, bypass: bool) -> Dictionary:
	return {
		"hour": hour, "dt_game_minutes": dt_gm, "bypass_smoothing": bypass,
		"wx_cong_add": env["wx_cong_add"], "i_inc": env["i_inc"],
		"weights": env["weights"], "evt": env["evt"],
	}


func _congestion_inputs(hour: float, dt_gm: float, bypass: bool) -> Dictionary:
	return _stamp_inputs(_congestion_env(), hour, dt_gm, bypass)


func _recompute_all_congestion(bypass: bool, hour: float, dt_gm: float = 1.0) -> void:
	_recompute_congestion(graph.edge_ids_sorted(), dt_gm, hour, bypass)


func _recompute_congestion(edge_ids: Array, dt_gm: float, hour: float, bypass: bool) -> void:
	if edge_ids.is_empty():
		return
	congestion.recompute(edge_ids, _congestion_inputs(hour, dt_gm, bypass))
	_mean_congestion = congestion.mean_congestion()


## §2.10 E_evt. Doc 10 specifies graph distance to the venue; this build uses
## Manhattan TILE distance from the edge midpoint, which is monotone in the same
## direction, O(1) per edge, and deterministic. Off by default (no venue).
func _event_factors() -> Dictionary:
	var out: Dictionary = {}
	if _event_spikes.is_empty():
		return out
	for spike in _event_spikes:
		var venue: Vector2i = spike["venue_tile"]
		var start := int(spike["start_minute"])
		var end := int(spike["end_minute"])
		var ramp := 0.0
		if sim_minute >= start - tun.event_inbound_lead_gm and sim_minute <= start:
			ramp = 1.0
		elif sim_minute > start and sim_minute < end:
			ramp = tun.event_during_factor
		elif sim_minute >= end and sim_minute <= end + tun.event_outbound_tail_gm:
			ramp = 1.0
		if ramp <= 0.0:
			continue
		for edge_id in graph.edge_ids_sorted():
			var tiles: Array = graph.edge(edge_id)["tiles"]
			var mid: Vector2i = tiles[tiles.size() / 2]
			var distance := float(absi(mid.x - venue.x) + absi(mid.y - venue.y))
			var falloff := maxf(0.0, 1.0 - distance / float(tun.event_radius_tiles))
			if falloff <= 0.0:
				continue
			out[edge_id] = float(out.get(edge_id, 1.0)) + tun.event_peak * ramp * falloff
	return out


## `env` lets a caller that already built one this step hand it over; `{}` means
## "build your own" (the day-boundary sampler, which runs on its own). `raw`, if
## non-empty, is this hour's c_raw per edge already computed by `full_pass` —
## the same numbers this would otherwise recompute, summed in the same order.
func _sample_c_day(hour: float, env: Dictionary = {}, raw: Dictionary = {}) -> void:
	if not raw.is_empty():
		for edge_id in graph.edge_ids_ref():
			_c_day_sum[edge_id] = float(_c_day_sum.get(edge_id, 0.0)) \
					+ float(raw.get(edge_id, 0.0))
	else:
		var inputs := _stamp_inputs(env if not env.is_empty() else _congestion_env(),
				hour, 1.0, true)
		congestion.accumulate_c_raw(graph.edge_ids_ref(), inputs, _c_day_sum)
	_c_day_samples += 1
	_wx_wear_day = maxf(_wx_wear_day, float(tun.weather_row(weather_state)["wear"]))


func _reset_day_accumulators() -> void:
	_c_day_sum.clear()
	_c_day_samples = 0
	_wx_wear_day = 0.0


func c_day_of(edge_id: int) -> float:
	if _c_day_samples <= 0:
		return 0.0
	return float(_c_day_sum.get(edge_id, 0.0)) / float(_c_day_samples)


func wx_wear_day() -> float:
	return _wx_wear_day


## §2.10 `pj(e)` refresh. `set_density_sources` takes [{tile, pj}] — doc 02's
## `pop_plus_jobs(id)` at each building's access tile.
func set_density_sources(sources: Array) -> void:
	_density_sources = sources.duplicate()


func refresh_density() -> void:
	var pj_by_edge: Dictionary = {}
	var r := tun.dens_radius_tiles
	for entry in _density_sources:
		var tile: Vector2i = entry["tile"]
		var pj := float(entry["pj"])
		if pj <= 0.0:
			continue
		var touched: Dictionary = {}
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var q := Vector2i(tile.x + dx, tile.y + dz)
				# `tile_edges` read directly: `edges_at()` hands out a defensive
				# copy, and this loop only reads, (2r+1)² times per source.
				for edge_id in graph.tile_edges.get(q, EMPTY_EDGE_LIST):
					touched[edge_id] = true
		for edge_id in _sorted_keys(touched):
			pj_by_edge[edge_id] = float(pj_by_edge.get(edge_id, 0.0)) + pj
	congestion.refresh_density(pj_by_edge)


# ------------------------------------------------------------- edge state sync

## Push per-tile condition, flags, closures and overrides onto the edge records
## the planner and the renderer read.
func _refresh_all_edge_state() -> void:
	for edge_id in graph.edge_ids_sorted():
		_refresh_edge_state(edge_id)
	_assign_districts()


func _refresh_edge_state(edge_id: int) -> void:
	var record: Dictionary = graph.edge(edge_id)
	if record.is_empty():
		return
	var tiles: Array = record["tiles"]
	var total := 0.0
	var collapsed := false
	for t in tiles:
		var value := float(_condition.get(t, 1.0))
		total += value
		if value <= 0.0:
			collapsed = true
	record["condition"] = total / maxf(1.0, float(tiles.size()))
	record["collapsed"] = collapsed
	var closure_id := int(_edge_closure.get(edge_id, -1))
	if closure_id >= 0 and _closures.has(closure_id):
		record["closure_id"] = closure_id
		record["closure_cause"] = String(_closures[closure_id]["cause"])
	else:
		record["closure_id"] = -1
		record["closure_cause"] = ""
	record["blocked_mask"] = _blocked_mask(record)


func _blocked_mask(record: Dictionary) -> int:
	var mask := 0
	if bool(record.get("collapsed", false)):
		return (1 << ROUTE_CLASS_COUNT) - 1
	var cause := String(record.get("closure_cause", ""))
	if cause == "":
		return 0
	var row := tun.cause_row(cause)
	if row.is_empty():
		return 0
	if bool(row.get("hard", false)):
		return (1 << ROUTE_CLASS_COUNT) - 1
	var mults: Array = row["mult"]
	for i in ROUTE_CLASS_COUNT:
		if float(mults[i]) < 0.0:
			mask |= 1 << i
	return mask


func _assign_districts() -> void:
	if not district_of_tile.is_valid():
		return
	for edge_id in graph.edge_ids_sorted():
		var record: Dictionary = graph.edge(edge_id)
		var tiles: Array = record["tiles"]
		record["district_id"] = String(district_of_tile.call(tiles[tiles.size() / 2]))


## Doc 07 / doc 06 tell roads which components hold a station of any department;
## `access_quality` returns 0 for a tile no department can reach (§5.2).
func set_station_components(component_ids: Array) -> void:
	_station_components.clear()
	for component_id in component_ids:
		_station_components[int(component_id)] = true


# ------------------------------------------------------------------- editing

## Queue a tile edit for this tick's batch. `road_class` 0 removes the road.
func edit_tile(tile: Vector2i, road_class: int) -> void:
	if not TileGrid.in_bounds(tile.x, tile.y):
		return
	grid.set_road(tile.x, tile.y, road_class)
	if road_class == RoadTunables.CLASS_NONE:
		_condition.erase(tile)
		_flags.erase(tile)
	elif not _condition.has(tile):
		_condition[tile] = 1.0
	_pending_edits.append(tile)


func pending_edit_count() -> int:
	return _pending_edits.size()


func condition_of(tile: Vector2i) -> float:
	return float(_condition.get(tile, 0.0))


func set_condition(tile: Vector2i, value: float) -> void:
	if not graph.is_road_tile(tile):
		return
	var clamped := clampf(value, 0.0, 1.0)
	var previous := float(_condition.get(tile, 1.0))
	_condition[tile] = clamped
	if clamped <= 0.0 and previous > 0.0:
		_flags[tile] = int(_flags.get(tile, 0)) | FLAG_COLLAPSED
		_emit(&"road_collapsed", {"tile": tile,
				"road_class": grid.road_class_at(tile.x, tile.y)})
	elif clamped > 0.0:
		_flags[tile] = int(_flags.get(tile, 0)) & ~FLAG_COLLAPSED
	if clamped <= tun.tier_critical_event and previous > tun.tier_critical_event:
		# Edge-triggered: crossing 0.20 downward fires once, and repairing back
		# above it re-arms the trigger.
		_emit(&"road_condition_critical", {"tile": tile, "condition": clamped})
	for edge_id in graph.edges_at(tile):
		_refresh_edge_state(edge_id)


## Instant damage (§2.12). The delta IS the C-16 `damage_fraction` doc 03 prices.
func apply_damage(tiles: Array, damage_key: String) -> float:
	var delta := tun.damage_delta(damage_key)
	if delta == 0.0:
		return 0.0
	var applied := 0.0
	for entry in RoadGraph._sorted_tiles(tiles):
		var t: Vector2i = entry
		if not graph.is_road_tile(t):
			continue
		var before := condition_of(t)
		set_condition(t, before + delta)
		applied += before - condition_of(t)
	return applied


func flags_of(tile: Vector2i) -> int:
	return int(_flags.get(tile, 0))


func set_flag(tile: Vector2i, flag: int, on: bool) -> void:
	var value := int(_flags.get(tile, 0))
	_flags[tile] = (value | flag) if on else (value & ~flag)


# -------------------------------------------------------------------- closures

## §2.8 — effects applied IMMEDIATELY, not deferred to the next tick.
func add_closure(tiles: Array, cause: String, severity: float = 1.0,
		expected_duration_gm: int = -1, source_incident_id: int = -1) -> int:
	var row := tun.cause_row(cause)
	if row.is_empty():
		return -1
	if _closures.size() >= tun.max_active_closures:
		return -1
	var edge_ids: Array[int] = []
	var edge_tiles: Array = []
	for entry in RoadGraph._sorted_tiles(tiles):
		var t: Vector2i = entry
		for edge_id in graph.edges_at(t):
			if not edge_ids.has(edge_id):
				edge_ids.append(edge_id)
		if graph.is_road_tile(t):
			edge_tiles.append(t)
	if edge_ids.is_empty():
		return -1
	edge_ids.sort()
	var duration := expected_duration_gm
	if duration < 0:
		duration = int(row.get("auto_expire_gm", -1))
	var closure_id := next_closure_id
	next_closure_id += 1
	_closures[closure_id] = {
		"id": closure_id, "edge_ids": edge_ids, "edge_tiles": edge_tiles,
		"cause": cause, "severity": clampf(severity, 0.0, 1.0),
		"start_minute": sim_minute,
		"expected_end_minute": sim_minute + duration if duration > 0 else -1,
		"source_incident_id": source_incident_id, "clearing_unit_id": -1,
	}
	for edge_id in edge_ids:
		_install_closure(edge_id, closure_id)
	_after_closure_change(edge_ids, RouteProfile.InvalidReason.CLOSURE)
	_emit(&"road_closure_opened", {"closure_id": closure_id, "edge_ids": edge_ids,
			"cause": cause, "severity": severity})
	return closure_id


func close_edge(edge_id: int, cause: String, until_min: int = -1,
		source_incident_id: int = -1) -> int:
	var record: Dictionary = graph.edge(edge_id)
	if record.is_empty():
		return -1
	var duration := -1
	if until_min >= 0:
		duration = maxi(0, until_min - sim_minute)
	return add_closure([record["tiles"][0]], cause, 1.0, duration, source_incident_id)


## Only ONE closure may be active per edge; a higher-severity cause replaces a
## lower one, and the replaced closure is retained in a shadow list and
## reinstated if the dominant one clears first (§2.8).
func _install_closure(edge_id: int, closure_id: int) -> void:
	var incumbent := int(_edge_closure.get(edge_id, -1))
	if incumbent < 0:
		_edge_closure[edge_id] = closure_id
		return
	var incoming_rank := tun.cause_rank(String(_closures[closure_id]["cause"]))
	var incumbent_rank := tun.cause_rank(String(_closures[incumbent]["cause"]))
	if incoming_rank < incumbent_rank:
		var shadow: Array = _shadow.get(edge_id, [])
		if not shadow.has(incumbent):
			shadow.append(incumbent)
		_shadow[edge_id] = shadow
		_edge_closure[edge_id] = closure_id
	else:
		var shadow2: Array = _shadow.get(edge_id, [])
		if not shadow2.has(closure_id):
			shadow2.append(closure_id)
		_shadow[edge_id] = shadow2


func remove_closure(closure_id: int) -> void:
	var closure: Dictionary = _closures.get(closure_id, {})
	if closure.is_empty():
		return
	var edge_ids: Array = closure["edge_ids"]
	_closures.erase(closure_id)
	for edge_id in edge_ids:
		if int(_edge_closure.get(edge_id, -1)) == closure_id:
			_edge_closure.erase(edge_id)
			_reinstate_shadow(edge_id)
		var shadow: Array = _shadow.get(edge_id, [])
		shadow.erase(closure_id)
		if shadow.is_empty():
			_shadow.erase(edge_id)
		else:
			_shadow[edge_id] = shadow
	_after_closure_change(edge_ids, RouteProfile.InvalidReason.CLOSURE)
	_emit(&"road_closure_cleared", {"closure_id": closure_id, "edge_ids": edge_ids,
			"cause": String(closure["cause"])})


func _reinstate_shadow(edge_id: int) -> void:
	var shadow: Array = _shadow.get(edge_id, [])
	var best := -1
	var best_rank := 99999
	for candidate in shadow:
		if not _closures.has(candidate):
			continue
		var rank := tun.cause_rank(String(_closures[candidate]["cause"]))
		if rank < best_rank:
			best_rank = rank
			best = int(candidate)
	if best >= 0:
		_edge_closure[edge_id] = best
		shadow.erase(best)
		if shadow.is_empty():
			_shadow.erase(edge_id)
		else:
			_shadow[edge_id] = shadow


## Auto-expiry caps exist so a lost `incident_resolved` can never permanently
## strand a district (§2.8).
func _expire_closures() -> Array:
	var touched: Array = []
	for closure_id in _sorted_keys(_closures):
		var closure: Dictionary = _closures[closure_id]
		var end := int(closure["expected_end_minute"])
		if end >= 0 and sim_minute >= end:
			touched.append_array(closure["edge_ids"])
			remove_closure(int(closure_id))
	return touched


func _expire_overrides() -> Array:
	var touched: Array = []
	var kept: Array = []
	for entry in _overrides:
		if int(entry["until_minute"]) >= 0 and sim_minute >= int(entry["until_minute"]):
			var edge_id := _edge_from_tiles(entry["edge_tiles"])
			if edge_id >= 0:
				graph.edge(edge_id)["speed_override"] = 1.0
				graph.edge(edge_id)["override_until_minute"] = -1
				touched.append(edge_id)
		else:
			kept.append(entry)
	if kept.size() != _overrides.size():
		_overrides = kept
		planner.closure_epoch += 1
		planner.invalidate_edges(touched)
	return touched


func _after_closure_change(edge_ids: Array, reason: int) -> void:
	for edge_id in edge_ids:
		_refresh_edge_state(edge_id)
	planner.closure_epoch += 1
	var tickets := planner.invalidate_edges(edge_ids)
	if tickets.size() > 0:
		_emit(&"route_invalidated", {"ticket_ids": tickets, "reason": reason})
	# Spillback: the closed edges and everything within 2 graph hops recompute
	# immediately (§2.8 step 4), not on the next minute pass.
	var dirty: Dictionary = {}
	for edge_id in edge_ids:
		dirty[edge_id] = true
		for other in graph.edges_within_hops(edge_id, 2):
			dirty[other] = true
	_recompute_congestion(dirty.keys(), 60.0, _last_sample_hour(), true)


func _last_sample_hour() -> float:
	return float(_last_hour_sampled) + 0.5 if _last_hour_sampled >= 0 else 12.0


func closure(closure_id: int) -> Dictionary:
	return _closures.get(closure_id, {})


func closure_ids_sorted() -> Array:
	return _sorted_keys(_closures)


func closure_of_edge(edge_id: int) -> int:
	return int(_edge_closure.get(edge_id, -1))


func active_closure_count() -> int:
	return _closures.size()


## Doc 06's escalation tiers set a direct speed multiplier on a segment. A
## separate multiplicative channel from F_closure, so the two compose predictably.
func set_edge_speed_mult(edge_id: int, mult: float, until_min: int) -> void:
	var record: Dictionary = graph.edge(edge_id)
	if record.is_empty():
		return
	record["speed_override"] = clampf(mult, tun.speed_override_min, 1.0)
	record["override_until_minute"] = until_min
	var tiles: Array = record["tiles"]
	_overrides.append({"edge_tiles": [tiles[0], tiles[tiles.size() - 1]],
			"mult": record["speed_override"], "until_minute": until_min})
	planner.closure_epoch += 1
	planner.invalidate_edges([edge_id])


func _edge_from_tiles(tiles: Array) -> int:
	for t in tiles:
		var edge_id := graph.edge_at(t)
		if edge_id >= 0:
			return edge_id
	return -1


# ------------------------------------------------------------- doc 06 / 02 / 03 API

## AUTHORITATIVE, SYNCHRONOUS, MODE-INVARIANT. Returns INF if unreachable.
func route_minutes(a: Vector2i, b: Vector2i, prof: RouteProfile) -> float:
	return planner.route_minutes(a, b, prof)


## The TravelTimeProvider contract doc 06's dispatch injects: whole game-seconds,
## −1 when unreachable (INF has no int representation).
func travel_gs(from: Vector2i, to: Vector2i) -> int:
	return travel_gs_for(from, to, default_profile())


## One shared profile object, so the planner's per-query constant cache is not
## invalidated by a fresh RouteProfile on every call.
func default_profile() -> RouteProfile:
	if _default_profile == null:
		_default_profile = RouteProfile.emergency(32.0, 0)
	return _default_profile


func travel_gs_for(from: Vector2i, to: Vector2i, prof: RouteProfile) -> int:
	var minutes := route_minutes(from, to, prof)
	if is_inf(minutes):
		return -1
	return roundi(minutes * 60.0)


## A provider object doc 06 can hold without knowing about RoadNetwork.
func travel_time_provider(prof: RouteProfile = null) -> RoadTravelTimeProvider:
	return RoadTravelTimeProvider.new(self, prof if prof != null else default_profile())


func is_reachable(a: Vector2i, b: Vector2i, prof: RouteProfile) -> bool:
	return planner.is_reachable(a, b, prof)


func nearest_node(pos: Vector2i) -> int:
	return graph.nearest_node(pos)


## §2.8: a vehicle hard-blocked mid-edge reverses to the node it last passed and
## pays this. Doc 10 publishes it; doc 06 applies it, because vehicle movement
## is doc 06's.
func reverse_penalty_gm() -> float:
	return tun.reverse_penalty_gm


func congestion_index(edge_id: int) -> float:
	return congestion.congestion_of(edge_id)


func condition_hazard_mult(edge_id: int) -> float:
	return RoadCosts.condition_hazard_mult(float(graph.edge(edge_id).get("condition", 1.0)),
			tun.hazard_condition_coeff, tun.hazard_condition_threshold)


## Doc 03's C-16 argument (RR-2). Doc 10 supplies the fraction; doc 03 every dollar.
func road_damage_fraction(tile: Vector2i) -> float:
	if not graph.is_road_tile(tile):
		return 0.0
	return 1.0 - condition_of(tile)


func road_tile_counts() -> Dictionary:
	return graph.road_tile_counts()


func signalised_intersections(district_id: String = "") -> Array:
	return graph.signalised_intersections(district_id, district_of_tile)


## Doc 06 computes `dark_frac` from `signalised_intersections`; this is the same
## number, offered directly because every consumer wants exactly it.
func dark_fraction(district_id: String = "") -> float:
	var rows := signalised_intersections(district_id)
	if rows.is_empty():
		return 0.0
	var dark := 0
	for row in rows:
		if not bool(row["powered"]):
			dark += 1
	return float(dark) / float(rows.size())


func estimate_eta(a: Vector2i, b: Vector2i, prof: RouteProfile) -> float:
	return planner.estimate_eta(a, b, prof)


## O(1): the district-mean term is a cached scalar, refreshed by the congestion
## pass. Doc 12 §9.2 needs ~40 of these inside one frame.
func estimate_eta_practical(a: Vector2i, b: Vector2i, prof: RouteProfile) -> float:
	return planner.estimate_eta_practical(a, b, prof, _mean_congestion)


func mean_congestion() -> float:
	return _mean_congestion


func request_path(from_tile: Vector2i, to_tile: Vector2i, prof: RouteProfile,
		priority: int = 2, requester_id: int = -1, tick_index: int = 0) -> int:
	return planner.request_path(from_tile, to_tile, prof, priority, requester_id, tick_index)


## §5.2 — the SINGLE tile-level definition of road access (report 98 C-61).
## Docs 02 (E_ROAD / road_access_mult), 03 (a_b in f_road) and 06 (< 0.6
## degraded response) all consume this and define none of their own.
func access_quality(pos: Vector2i) -> float:
	var road := graph.nearest_road_tile(pos, tun.snap_radius_tiles)
	if road.x < 0:
		return 0.0
	var distance := maxi(absi(road.x - pos.x), absi(road.y - pos.y))
	var w_dist := tun.aq_w_dist_none
	if distance <= 1:
		w_dist = tun.aq_w_dist_1
	elif distance == 2:
		w_dist = tun.aq_w_dist_2
	elif distance <= tun.snap_radius_tiles:
		w_dist = tun.aq_w_dist_3_6
	if w_dist <= 0.0:
		return 0.0
	var w_class := tun.aq_w_class_avenue if has_class_within(pos, RoadTunables.CLASS_AVENUE,
			tun.avenue_gate_radius_tiles) else tun.aq_w_class_street
	var w_state := tun.aq_w_state_normal
	if condition_of(road) <= 0.0:
		w_state = tun.aq_w_state_hard
	else:
		var edge_id := graph.edge_at(road)
		if edge_id >= 0:
			var record: Dictionary = graph.edge(edge_id)
			var cause := String(record.get("closure_cause", ""))
			if cause != "":
				w_state = tun.aq_w_state_hard if bool(tun.cause_row(cause).get("hard", false)) \
						else tun.aq_w_state_soft
	if not _station_components.is_empty():
		var component := graph.component_of_tile(road)
		if component >= 0 and not _station_components.has(component):
			w_state = tun.aq_w_state_no_station
	return w_dist * w_class * w_state


## Doc 02 §2.10's placement multiplier, sourced from access_quality's w_dist
## bands so the two can never drift (C-61).
func road_access_mult(tile: Vector2i) -> float:
	var road := graph.nearest_road_tile(tile, 2)
	if road.x < 0:
		return 0.0
	var distance := maxi(absi(road.x - tile.x), absi(road.y - tile.y))
	if distance <= tun.access_radius_tiles:
		return tun.aq_w_dist_1
	if distance == 2:
		return tun.aq_w_dist_2
	return 0.0


func has_road_access(tile: Vector2i) -> bool:
	return road_access_mult(tile) > 0.0


## The lookup behind doc 02's upgrade check #13 `E_AVENUE` (C-62). Doc 10 does
## NOT evaluate the gate, format its message, or store its result.
func has_class_within(tile: Vector2i, road_class: int, radius: int) -> bool:
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var x := tile.x + dx
			var z := tile.y + dz
			if TileGrid.in_bounds(x, z) and grid.road_class_at(x, z) == road_class:
				return true
	return false


## Doc 07's evacuation / Director scoring input (§5.2).
func components_summary() -> Array:
	var tile_counts: Dictionary = {}
	for component_id in graph.component_ids_sorted():
		tile_counts[component_id] = (graph.component_members(component_id) as Array).size()
	# One pass over the edges, adding each edge's interior tiles to its own
	# component (endpoint tiles are already counted as nodes).
	for edge_id in graph.edge_ids_sorted():
		var record: Dictionary = graph.edge(edge_id)
		var component_id := graph.component_of_node(int(record["node_a"]))
		if component_id < 0:
			continue
		tile_counts[component_id] = int(tile_counts.get(component_id, 0)) \
				+ maxi(0, (record["tiles"] as Array).size() - 2)
	var out: Array = []
	for component_id in graph.component_ids_sorted():
		out.append({"component_id": component_id,
				"tile_count": int(tile_counts.get(component_id, 0)),
				"has_station": _station_components.has(component_id)})
	return out


## The live inputs doc 03's `e_roads_repair` wants — replacing CitySim's held
## `{tiles: {AVENUE: 540, STREET: 243}, c_day: 0.35, wx_wear_day: 0.0}` constant.
func settlement_inputs() -> Dictionary:
	var counts := road_tile_counts()
	var weighted := 0.0
	var total := 0.0
	for edge_id in graph.edge_ids_sorted():
		var tiles := float((graph.edge(edge_id)["tiles"] as Array).size())
		weighted += c_day_of(edge_id) * tiles
		total += tiles
	return {
		"tiles": counts,
		"c_day": weighted / total if total > 0.0 else 0.0,
		"wx_wear_day": _wx_wear_day,
		"base_decay_per_game_day": {
			"AVENUE": tun.base_decay(RoadTunables.CLASS_AVENUE),
			"STREET": tun.base_decay(RoadTunables.CLASS_STREET),
		},
	}


# ------------------------------------------------------ condition decay & repair

## §2.12: decay(tile) = base_decay(class) · (1 + 0.75·c_day) · (1 + wx_wear_day),
## applied once per game-day.
func _apply_daily_decay() -> void:
	var wear := 1.0 + _wx_wear_day
	for t in graph.road_tiles_sorted():
		var edge_id := graph.edge_at(t)
		var c_day := c_day_of(edge_id) if edge_id >= 0 else 0.0
		var road_class := grid.road_class_at(t.x, t.y)
		var decay := tun.base_decay(road_class) * (1.0 + tun.congestion_wear_coeff * c_day) * wear
		if decay <= 0.0:
			continue
		set_condition(t, condition_of(t) - decay)


## §2.12 auto-maintenance. Roads AUTHORS NO DOLLAR HERE: each candidate run is
## evaluated against the quote doc 03 returns, and the cap is a player budget
## setting, not a price.
func _queue_auto_repairs() -> Array:
	if auto_repair_threshold <= 0.0:
		return []
	var runs := _contiguous_runs_below(auto_repair_threshold)
	runs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(float(a["congestion"]) - float(b["congestion"])) > 1e-9:
			return float(a["congestion"]) > float(b["congestion"])
		if absf(float(a["condition"]) - float(b["condition"])) > 1e-9:
			return float(a["condition"]) < float(b["condition"])
		return String(a["key"]) < String(b["key"]))
	var spent := 0
	var queued: Array = []
	for run in runs:
		if queued.size() >= tun.auto_repair_max_jobs_per_day:
			break
		var quote := _repair_quote_for(run["tiles"])
		if spent + quote > auto_repair_daily_cap:
			continue
		var job_id := _submit_repair(run["tiles"], quote)
		if job_id < 0:
			continue
		spent += quote
		queued.append(job_id)
	return queued


func _contiguous_runs_below(threshold: float) -> Array:
	var candidates: Dictionary = {}
	for t in graph.road_tiles_sorted():
		if condition_of(t) < threshold:
			candidates[t] = true
	var out: Array = []
	var visited: Dictionary = {}
	for entry in RoadGraph._sorted_tiles(candidates.keys()):
		var seed: Vector2i = entry
		if visited.has(seed):
			continue
		var run: Array = []
		var stack: Array = [seed]
		visited[seed] = true
		while not stack.is_empty():
			var cur: Vector2i = stack.pop_back()
			run.append(cur)
			for d in RoadGraph.DIRS:
				var q: Vector2i = cur + d
				if candidates.has(q) and not visited.has(q):
					visited[q] = true
					stack.push_back(q)
		if run.size() < tun.repair_min_tiles:
			continue
		var sorted_run := RoadGraph._sorted_tiles(run)
		var condition_sum := 0.0
		var congestion_sum := 0.0
		for t in sorted_run:
			condition_sum += condition_of(t)
			var edge_id := graph.edge_at(t)
			congestion_sum += congestion.congestion_of(edge_id) if edge_id >= 0 else 0.0
		out.append({
			"tiles": sorted_run, "key": "%d,%d" % [sorted_run[0].x, sorted_run[0].y],
			"condition": condition_sum / float(sorted_run.size()),
			"congestion": congestion_sum / float(sorted_run.size()),
		})
	return out


func _repair_quote_for(tiles: Array) -> int:
	if not repair_quote.is_valid():
		return 0
	var total := 0
	for t in tiles:
		var road_class := grid.road_class_at(t.x, t.y)
		total += int(repair_quote.call(tun.class_name_of(road_class), road_damage_fraction(t)))
	return total


## §2.12 repair: crew_hours = ROAD_REPAIR_HOURS_BASE · damage_fraction, submitted
## to doc 02's ConstructionQueue as work units. Roads runs no queue of its own.
func repair_crew_hours(tiles: Array) -> float:
	var total := 0.0
	for t in tiles:
		total += tun.repair_crew_hours_base * road_damage_fraction(t)
	return total


func _submit_repair(tiles: Array, quote: int) -> int:
	if not submit_job.is_valid():
		return -1
	var crew_hours := repair_crew_hours(tiles)
	var job_id := int(submit_job.call(&"road", "road_repair", crew_hours, &"road_crew",
			{"roads_kind": "repair", "tiles": tiles.duplicate(), "cost": quote}))
	if job_id < 0:
		return -1
	_jobs[job_id] = {"kind": "repair", "tiles": tiles.duplicate(), "road_class": -1}
	add_closure(tiles, "construction_work", 0.4, -1, -1)
	return job_id


# ------------------------------------------------------------------- commands

## §2.13 validation. `land_ok` is doc 09's `is_developed(tile) and
## is_buildable(tile)`; when it is not injected, only the grid's own rules apply.
var land_is_buildable: Callable = Callable()


func query_road_preview(tiles: Array, road_class: int) -> Dictionary:
	var reasons: Array = []
	var fresh: Array = []
	for entry in RoadGraph._sorted_tiles(tiles):
		var t: Vector2i = entry
		if not TileGrid.in_bounds(t.x, t.y):
			reasons.append(&"E_OUT_OF_BOUNDS")
			continue
		if grid.has_flag(t.x, t.y, TileGrid.FLAG_WATER):
			reasons.append(&"E_WATER")
			continue
		if grid.has_flag(t.x, t.y, TileGrid.FLAG_OCCUPIED):
			reasons.append(&"E_FOOTPRINT")
			continue
		if land_is_buildable.is_valid() and not bool(land_is_buildable.call(t)):
			reasons.append(&"E_NOT_DEVELOPED")
			continue
		# A tile that already carries ANY road is not fresh, whatever class the
		# drag asked for. §2.13 keeps build, upgrade and demolish as three verbs:
		# re-laying a STREET over an AVENUE would be a silent downgrade, and
		# re-laying an AVENUE over a STREET would buy the upgrade at the build
		# price AND reset the tile to `under_construction_seed`. Both are the
		# upgrade/demolish verbs' business, so the build verb passes over them.
		if grid.road_class_at(t.x, t.y) != RoadTunables.CLASS_NONE:
			continue
		fresh.append(t)
	var connected := fresh.is_empty()
	for entry in fresh:
		var t: Vector2i = entry
		for d in RoadGraph.DIRS:
			var q: Vector2i = t + d
			if TileGrid.in_bounds(q.x, q.y) \
					and grid.road_class_at(q.x, q.y) != RoadTunables.CLASS_NONE:
				connected = true
				break
		if connected:
			break
	if not connected and not fresh.is_empty():
		reasons.append(&"E_NOT_CONNECTED")
	return {
		"ok": reasons.is_empty(), "reasons": reasons, "tiles": fresh,
		"crew_hours": float(fresh.size()) * tun.build_crew_hours(road_class),
		"work_units": roundi(float(fresh.size()) * tun.build_crew_hours(road_class)
				* float(tun.work_units_per_crew_hour)),
	}


func cmd_road_build(tiles: Array, road_class: int, cost: int = 0) -> Dictionary:
	var preview := query_road_preview(tiles, road_class)
	if not bool(preview["ok"]):
		_emit(&"road_job_rejected", {"reasons": preview["reasons"], "kind": "build"})
		return CommandQueue.fail(preview["reasons"][0], preview)
	if not submit_job.is_valid():
		return CommandQueue.fail(&"E_NO_QUEUE")
	var fresh: Array = preview["tiles"]
	var job_id := int(submit_job.call(&"road", "road_build",
			float(preview["crew_hours"]), &"road_crew",
			{"roads_kind": "build", "tiles": fresh.duplicate(), "road_class": road_class,
			"cost": cost}))
	_jobs[job_id] = {"kind": "build", "tiles": fresh.duplicate(), "road_class": road_class}
	# §2.13 under-construction lifecycle: tiles enter the grid immediately at
	# condition 0.10 with a construction_new closure, so the crew can reach the
	# far end of its own job and the player can see the corridor forming.
	for entry in fresh:
		var t: Vector2i = entry
		edit_tile(t, road_class)
		_condition[t] = tun.under_construction_seed
		set_flag(t, FLAG_UNDER_CONSTRUCTION, true)
	_flush_edits()
	add_closure(fresh, "construction_new", 1.0, -1, -1)
	return CommandQueue.ok({"job_id": job_id, "crew_hours": preview["crew_hours"],
			"work_units": preview["work_units"], "tiles": fresh})


## §2.13 upgrade eligibility, quoted without submitting anything: a STREET tile
## with no active closure other than `construction_work`. Split out of
## `cmd_road_upgrade` so the money layer (doc 03, through `CitySim`) can price
## the SAME tile set the command will act on — a preview that re-derived
## eligibility from its own copy of this rule could quote a job that never runs.
func query_upgrade_preview(tiles: Array) -> Dictionary:
	var eligible: Array = []
	for entry in RoadGraph._sorted_tiles(tiles):
		var t: Vector2i = entry
		if not TileGrid.in_bounds(t.x, t.y):
			continue
		if grid.road_class_at(t.x, t.y) != RoadTunables.CLASS_STREET:
			continue
		var edge_id := graph.edge_at(t)
		if edge_id >= 0:
			var cause := String(graph.edge(edge_id).get("closure_cause", ""))
			if cause != "" and cause != "construction_work":
				continue
		eligible.append(t)
	var crew_hours := float(eligible.size()) * _upgrade_crew_hours_per_tile()
	return {
		"ok": not eligible.is_empty(),
		"reasons": [] if not eligible.is_empty() else [&"E_NO_ELIGIBLE_TILES"],
		"tiles": eligible, "crew_hours": crew_hours,
		"work_units": roundi(crew_hours * float(tun.work_units_per_crew_hour)),
	}


func _upgrade_crew_hours_per_tile() -> float:
	return float(tun.class_row(RoadTunables.CLASS_AVENUE).get("upgrade_crew_hours", 0.9))


## §2.13 demolish, quoted without removing anything: the road tiles in `tiles`,
## sorted. The money layer prices the refund off exactly this list.
func query_demolish_preview(tiles: Array) -> Dictionary:
	var victims: Array = []
	for entry in RoadGraph._sorted_tiles(tiles):
		var t: Vector2i = entry
		if graph.is_road_tile(t):
			victims.append(t)
	return {
		"ok": not victims.is_empty(),
		"reasons": [] if not victims.is_empty() else [&"E_NOT_ROAD"],
		"tiles": victims,
	}


func cmd_road_upgrade(tiles: Array, cost: int = 0) -> Dictionary:
	var preview := query_upgrade_preview(tiles)
	var eligible: Array = preview["tiles"]
	if eligible.is_empty():
		_emit(&"road_job_rejected", {"reasons": [&"E_NO_ELIGIBLE_TILES"], "kind": "upgrade"})
		return CommandQueue.fail(&"E_NO_ELIGIBLE_TILES")
	if not submit_job.is_valid():
		return CommandQueue.fail(&"E_NO_QUEUE")
	var crew_hours := float(preview["crew_hours"])
	var job_id := int(submit_job.call(&"road", "road_upgrade", crew_hours, &"road_crew",
			{"roads_kind": "upgrade", "tiles": eligible.duplicate(), "cost": cost}))
	_jobs[job_id] = {"kind": "upgrade", "tiles": eligible.duplicate(),
			"road_class": RoadTunables.CLASS_AVENUE}
	add_closure(eligible, "construction_work", 0.5, -1, -1)
	return CommandQueue.ok({"job_id": job_id, "crew_hours": crew_hours,
			"work_units": roundi(crew_hours * float(tun.work_units_per_crew_hour))})


func cmd_road_repair(tiles: Array) -> Dictionary:
	var damaged: Array = []
	for entry in RoadGraph._sorted_tiles(tiles):
		var t: Vector2i = entry
		if graph.is_road_tile(t) and condition_of(t) < 1.0:
			damaged.append(t)
	if damaged.size() < tun.repair_min_tiles:
		_emit(&"road_job_rejected", {"reasons": [&"E_MIN_TILES"], "kind": "repair"})
		return CommandQueue.fail(&"E_MIN_TILES", {"min_tiles": tun.repair_min_tiles})
	var job_id := _submit_repair(damaged, _repair_quote_for(damaged))
	if job_id < 0:
		return CommandQueue.fail(&"E_NO_QUEUE")
	return CommandQueue.ok({"job_id": job_id, "crew_hours": repair_crew_hours(damaged),
			"tiles": damaged})


## §2.13's orphan test, evaluated without removing anything: would any of doc
## 02's `access_tiles` lose its last adjacent road tile if `victims` went away?
## `{ok, access_tile}` — the same verdict `cmd_road_demolish` reaches, so a
## preview and the command can never disagree.
func query_demolish_orphan(victims: Array, access_tiles: Array) -> Dictionary:
	var removing: Dictionary = {}
	for t in victims:
		removing[t] = true
	for entry in access_tiles:
		var access: Vector2i = entry
		var still_served := false
		for d in RoadGraph.DIRS:
			var q: Vector2i = access + d
			if graph.is_road_tile(q) and not removing.has(q):
				still_served = true
				break
		if not still_served:
			return {"ok": false, "access_tile": access}
	return {"ok": true, "access_tile": Vector2i(-1, -1)}


## §2.13 demolish: REJECTED if, after removal, any building's access tile would
## have no adjacent road tile. `access_tiles` is doc 02's building access list.
func cmd_road_demolish(tiles: Array, access_tiles: Array = []) -> Dictionary:
	var victims: Array = []
	for entry in RoadGraph._sorted_tiles(tiles):
		var t: Vector2i = entry
		if graph.is_road_tile(t):
			victims.append(t)
	if victims.is_empty():
		return CommandQueue.fail(&"E_NOT_ROAD")
	var removing: Dictionary = {}
	for t in victims:
		removing[t] = true
	for entry in access_tiles:
		var access: Vector2i = entry
		var still_served := false
		for d in RoadGraph.DIRS:
			var q: Vector2i = access + d
			if graph.is_road_tile(q) and not removing.has(q):
				still_served = true
				break
		if not still_served:
			_emit(&"road_job_rejected", {"reasons": [&"E_WOULD_ORPHAN"], "kind": "demolish",
					"access_tile": access})
			return CommandQueue.fail(&"E_WOULD_ORPHAN", {"access_tile": access})
	for entry in victims:
		var t: Vector2i = entry
		edit_tile(t, RoadTunables.CLASS_NONE)
	_flush_edits()
	_emit(&"road_removed", {"tiles": victims})
	return CommandQueue.ok({"tiles": victims})


## Doc 09 §2.9.1's land-block road template, stamped at doc 09's `ROAD_INSTALL`
## development phase. **Doc 09 owns the template; this doc owns the class
## semantics** (report 98 C-60), and §2.3's mapping is the whole of this method:
##
##   block-local rows/cols {0, 15}  → AVENUE   2×16 + 2×16 − 4 =  60 tiles
##   block-local row/col 7          → STREET   16 + 16 − 1 − 4 =  27 tiles
##                                              total             87 tiles
##
## leaving **169 buildable tiles** on a clean 16×16 block — the `0.34` road-area
## constant doc 09 §2.2's price and placement math depends on, reproduced from
## the template rather than asserted.
##
## Boundary tiles belong to the block that contributed them, so stamping a block
## whose neighbour is already developed widens that boundary from one AVENUE
## tile to two — doc 09 §2.9.1's "half AVENUE widens when the neighbour reaches
## ROAD_INSTALL", with no special case: each block simply stamps its own {0,15}.
##
## A tile already carrying AVENUE is never demoted to STREET (the loader's own
## crossing rule), and water / blocked / building tiles are skipped rather than
## paved. The graph rebuilds incrementally through `_flush_edits`, so the caller
## gets a coherent graph before this returns.
##
## **This method books no money.** The stamp is billed once by doc 03 §2.8's
## `road_install` phase price (doc 10 §2.3's no-double-billing rule); the §2.13(d)
## per-tile prices are for player-placed tiles only, and doc 10 test 42 asserts
## that a stamped block produces zero `Treasury.spend()` calls from `sim/roads/`.
func stamp_block_template(block_grid: Vector2i, condition: float = 1.0) -> Dictionary:
	var origin := block_grid * TileGrid.TILES_PER_BLOCK
	var last := TileGrid.TILES_PER_BLOCK - 1
	var fresh: Array = []
	var avenue := 0
	var street := 0
	for lz in TileGrid.TILES_PER_BLOCK:
		for lx in TileGrid.TILES_PER_BLOCK:
			var road_class := RoadTunables.CLASS_NONE
			if lx == 0 or lx == last or lz == 0 or lz == last:
				road_class = RoadTunables.CLASS_AVENUE
			elif lx == TEMPLATE_COLLECTOR_INDEX or lz == TEMPLATE_COLLECTOR_INDEX:
				road_class = RoadTunables.CLASS_STREET
			if road_class == RoadTunables.CLASS_NONE:
				continue
			var t := origin + Vector2i(lx, lz)
			if not TileGrid.in_bounds(t.x, t.y):
				continue
			if grid.has_flag(t.x, t.y, TileGrid.FLAG_WATER) \
					or grid.has_flag(t.x, t.y, TileGrid.FLAG_BLOCKED) \
					or grid.has_flag(t.x, t.y, TileGrid.FLAG_OCCUPIED):
				continue
			var existing := grid.road_class_at(t.x, t.y)
			# AVENUE wins where the two classes meet, and an existing AVENUE is
			# never demoted (doc 09 §2.9.1's crossing rule, as the loader applies it).
			if existing == road_class or existing == RoadTunables.CLASS_AVENUE:
				continue
			edit_tile(t, road_class)
			_condition[t] = clampf(condition, 0.0, 1.0)
			fresh.append(t)
			if road_class == RoadTunables.CLASS_AVENUE:
				avenue += 1
			else:
				street += 1
	if fresh.is_empty():
		return {"tiles": fresh, "avenue": 0, "street": 0}
	_flush_edits()
	_emit(&"road_block_stamped", {"block_grid": [block_grid.x, block_grid.y],
			"tiles": fresh.size(), "avenue": avenue, "street": street})
	return {"tiles": fresh, "avenue": avenue, "street": street}


func cmd_set_auto_repair_policy(threshold: float, daily_cap: int) -> Dictionary:
	if not tun.auto_repair_thresholds.has(threshold):
		return CommandQueue.fail(&"E_BAD_THRESHOLD", {"allowed": tun.auto_repair_thresholds})
	auto_repair_threshold = threshold
	auto_repair_daily_cap = maxi(0, daily_cap)
	return CommandQueue.ok({"threshold": auto_repair_threshold,
			"daily_cap": auto_repair_daily_cap})


## §2.5's `REBUILD_TILE_BUDGET` carry needs a bounded number of drains: each
## pass either finishes the dirty set or retraces a full budget of tiles, and
## the dirty set is bounded by the map.
const MAX_REBUILD_PASSES: int = 64


## Apply queued edits immediately (commands need the graph coherent before they
## return; `step()` batches everything else).
##
## **Drained to completion**, not left at §2.5's per-tick tile budget. The budget
## exists to bound the cost of a TICK; a command is a player action and may pay
## its own retrace in full. Leaving it half-done was measured to matter: a 24-tile
## road build blew the 2,048-tile budget, and because nothing re-enters
## `apply_edits` until the NEXT tile edit, the carried dirty set was never
## drained — the live graph sat 12 edges short of the graph a rebuild-from-tiles
## produces, which is both wrong for routing and a save→load divergence
## (the loaded city rebuilds in full and finds all 687).
func _flush_edits() -> void:
	if _pending_edits.is_empty():
		return
	var batch := _pending_edits.duplicate()
	_pending_edits.clear()
	var added: Array = []
	var removed: Array = []
	for pass_index in MAX_REBUILD_PASSES:
		var delta := graph.apply_edits(batch if pass_index == 0 else [])
		added.append_array(delta["added_edges"])
		removed.append_array(delta["removed_edges"])
		if not graph.graph_dirty:
			break
	_refresh_all_edge_state()
	planner.invalidate_edges(removed)
	planner.invalidate_edges(added)
	_emit(&"road_graph_changed", {"added_edges": added,
			"removed_edges": removed, "graph_version": graph.graph_version})


# ----------------------------------------------------- doc 02 job callbacks

func on_job_started(job_id: int) -> void:
	var job: Dictionary = _jobs.get(job_id, {})
	if job.is_empty():
		return
	if String(job["kind"]) == "upgrade" or String(job["kind"]) == "repair":
		add_closure(job["tiles"], "construction_work", 0.5, -1, -1)


func on_job_completed(job_id: int) -> void:
	var job: Dictionary = _jobs.get(job_id, {})
	if job.is_empty():
		return
	_jobs.erase(job_id)
	var tiles: Array = job["tiles"]
	match String(job["kind"]):
		"build":
			for entry in tiles:
				var t: Vector2i = entry
				set_flag(t, FLAG_UNDER_CONSTRUCTION, false)
				set_condition(t, 1.0)
			_clear_closures_on(tiles, "construction_new")
			_emit(&"road_built", {"tiles": tiles, "road_class": int(job["road_class"])})
		"upgrade":
			for entry in tiles:
				var t: Vector2i = entry
				edit_tile(t, RoadTunables.CLASS_AVENUE)  # condition preserved
			_flush_edits()
			_clear_closures_on(tiles, "construction_work")
			_emit(&"road_upgraded", {"tiles": tiles})
		"repair":
			for entry in tiles:
				set_condition(entry, 1.0)
			_clear_closures_on(tiles, "construction_work")
			_emit(&"road_built", {"tiles": tiles, "repaired": true})


func on_job_cancelled(job_id: int) -> void:
	var job: Dictionary = _jobs.get(job_id, {})
	if job.is_empty():
		return
	_jobs.erase(job_id)
	if String(job["kind"]) == "build":
		for entry in job["tiles"]:
			edit_tile(entry, RoadTunables.CLASS_NONE)
		_flush_edits()
	_clear_closures_on(job["tiles"], "")


func on_job_blocked(job_id: int, reason: String) -> void:
	_emit(&"road_job_rejected", {"job_id": job_id, "reason": reason})


func _clear_closures_on(tiles: Array, cause: String) -> void:
	var doomed: Array = []
	for closure_id in _sorted_keys(_closures):
		var closure: Dictionary = _closures[closure_id]
		if cause != "" and String(closure["cause"]) != cause:
			continue
		for t in tiles:
			if (closure["edge_tiles"] as Array).has(t):
				doomed.append(int(closure_id))
				break
	for closure_id in doomed:
		remove_closure(closure_id)


# ------------------------------------------------------------------ persistence

## §3.2. The graph is DERIVED and never serialised: it is rebuilt in full from
## the tile grid on load and closures are re-applied. Congestion is not saved —
## it is a pure function of time-of-day, density, weather and closures, so it is
## recomputed cold with smoothing bypassed. The route cache is not saved.
func save_section() -> Dictionary:
	return {
		"section_version": SECTION_VERSION,
		"blocks": _serialize_blocks(),
		"closures": _serialize_closures(),
		"next_closure_id": next_closure_id,
		"speed_overrides": _serialize_overrides(),
		"auto_repair": {"threshold": auto_repair_threshold, "daily_cap": auto_repair_daily_cap},
		"condition_accum": _condition_accum.duplicate(true),
		"event_spikes": _event_spikes.duplicate(true),
		"traffic_feed": feed.serialize(),
		# Smoothed congestion AND the daily density index carry history — a
		# post-load recompute lands on c_raw at empty density, not where the
		# live run's smoother and last EVERY_DAY refresh had them, so both
		# persist. They are keyed by the edge's CANONICAL TILE KEY, never by its
		# edge id — see `SECTION_VERSION`.
		"edge_dynamics": _serialize_edge_dynamics(),
		# §2.4's edge-id labelling and its allocator. The graph is still derived
		# — this is only what each derived edge is CALLED, which every consumer
		# holding an id depends on and a full rebuild cannot re-derive.
		"edge_allocator": graph.edge_allocator_state(),
		"node_labels": graph.node_labels(),
		"node_allocator": graph.node_allocator_state(),
		"edge_heads": graph.edge_heads(),
		# In-flight road jobs. Doc 02's `ConstructionQueue` persists the WORK; this
		# is what the work is FOR, and without it a job that spans a save lands on
		# `on_job_completed` with nothing to complete — the tiles stay at
		# `under_construction_seed` behind a `construction_new` closure forever.
		"jobs": _serialize_jobs(),
		"day_seen": _day_seen,
		"sim_minute": sim_minute,
		# Day-scoped billing accumulators: doc 03 settles e_roads_repair from
		# this day's hourly c_raw samples — losing the morning's samples on a
		# midday load shifts the bill. Keyed by canonical tile key, as above.
		"c_day_sum": _serialize_c_day_sum(),
		"c_day_samples": _c_day_samples,
		"wx_wear_day": _wx_wear_day,
	}


## §3.2 wire version.
##
##   1 → 2  `edge_dynamics` and `c_day_sum` move from **edge id** keys to the
##          edge's **canonical tile key** (`RoadGraph._tiles_key`, the same
##          orientation-independent polyline signature §2.4's id-stability rule
##          hashes), `edge_dynamics` carries the edge's id as its first column,
##          and a new `edge_allocator` object carries `next_edge_id` /
##          `free_edge_ids`. Together they let the loaded graph adopt the live
##          graph's LABELLING (`RoadGraph.adopt_edge_ids`).
##          Version 1's note claimed edge ids were "stable across
##          rebuild-from-blocks", and while nothing could edit a road tile that
##          was vacuously true. It is not true in general: a live graph reaches
##          its edge ids through §2.5's INCREMENTAL retrace (which recycles ids
##          from a free list), a loaded one through `rebuild_all()`, and the two
##          orderings only agree while no edit has ever happened. Measured on
##          the first player-placed road tile: 645 edges, identical id SET,
##          **405 of them holding different tiles** — so every smoothed
##          congestion and density value landed on the wrong edge, and
##          save→load→advance identity broke one game-hour later.
##
## A version-1 section is read for everything else and its two id-keyed maps are
## dropped: both are recomputable (congestion is a pure function of the state
## §4 recomputes cold, `c_day_sum` re-accumulates over the running game-day), so
## an old save loads to a city that is at most one game-day of road-repair
## billing off, instead of one that is silently wrong forever.
const SECTION_VERSION: int = 2


## `{canonical tile key: [edge_id, congestion, dens_index]}` — one map doing
## three jobs, because all three are the same per-edge row and the key is the
## only rebuild-stable name an edge has (§2.4).
func _serialize_edge_dynamics() -> Dictionary:
	var out := {}
	for edge_id in graph.edge_ids_sorted():
		var record: Dictionary = graph.edge(edge_id)
		out[String(record["key"])] = [edge_id, float(record.get("congestion", 0.0)),
				float(record.get("dens_index", tun.dens_min))]
	return out


func _serialize_jobs() -> Dictionary:
	var out := {}
	for job_id in _sorted_keys(_jobs):
		var job: Dictionary = _jobs[job_id]
		var tiles: Array = []
		for t in job["tiles"]:
			tiles.append([(t as Vector2i).x, (t as Vector2i).y])
		out[str(job_id)] = {"kind": String(job["kind"]), "tiles": tiles,
				"road_class": int(job.get("road_class", -1))}
	return out


func _deserialize_jobs(saved: Dictionary) -> void:
	_jobs.clear()
	for key in _sorted_keys(saved):
		var record: Dictionary = saved[key]
		var tiles: Array = []
		for pair in record.get("tiles", []):
			tiles.append(Vector2i(int(pair[0]), int(pair[1])))
		_jobs[int(key)] = {"kind": String(record.get("kind", "build")), "tiles": tiles,
				"road_class": int(record.get("road_class", -1))}


func _serialize_c_day_sum() -> Dictionary:
	var out := {}
	for edge_id in _sorted_keys(_c_day_sum):
		var record: Dictionary = graph.edge(int(edge_id))
		if record.is_empty():
			continue
		out[String(record["key"])] = float(_c_day_sum[edge_id])
	return out


func load_section(data: Dictionary) -> void:
	if data.is_empty():
		return
	_closures.clear()
	_edge_closure.clear()
	_shadow.clear()
	_overrides.clear()
	_condition.clear()
	_flags.clear()
	var version := int(data.get("section_version", 1))
	_deserialize_blocks(data.get("blocks", {}))
	graph.rebuild_all()
	# BEFORE anything reads an edge id: adopt the live run's labelling (§2.4).
	# Closures, overrides, the traffic feed and the congestion history are all
	# restored against edge ids below, so this has to be the first thing after
	# the rebuild — see `SECTION_VERSION` for what went wrong when it was not.
	if version >= 2:
		var labels := {}
		for key in (data.get("edge_dynamics", {}) as Dictionary):
			var row: Array = data["edge_dynamics"][key]
			if not row.is_empty():
				labels[String(key)] = int(row[0])
		var node_allocator: Dictionary = data.get("node_allocator", {})
		graph.adopt_node_ids(data.get("node_labels", {}),
				int(node_allocator.get("next_node_id", -1)),
				node_allocator.get("free_node_ids", []))
		var allocator: Dictionary = data.get("edge_allocator", {})
		graph.adopt_edge_ids(labels, int(allocator.get("next_edge_id", -1)),
				allocator.get("free_edge_ids", []))
		var heads := {}
		for key in (data.get("edge_heads", {}) as Dictionary):
			var pair: Array = data["edge_heads"][key]
			heads[String(key)] = Vector2i(int(pair[0]), int(pair[1]))
		graph.orient_edges(heads)
	_refresh_all_edge_state()
	next_closure_id = int(data.get("next_closure_id", 1))
	for entry in data.get("closures", []):
		_restore_closure(entry)
	for entry in data.get("speed_overrides", []):
		var tiles: Array = []
		for pair in entry.get("edge_tiles", []):
			tiles.append(Vector2i(int(pair[0]), int(pair[1])))
		var edge_id := _edge_from_tiles(tiles)
		if edge_id >= 0:
			graph.edge(edge_id)["speed_override"] = float(entry.get("mult", 1.0))
			graph.edge(edge_id)["override_until_minute"] = int(entry.get("until_minute", -1))
			_overrides.append({"edge_tiles": tiles, "mult": float(entry.get("mult", 1.0)),
					"until_minute": int(entry.get("until_minute", -1))})
	var policy: Dictionary = data.get("auto_repair", {})
	auto_repair_threshold = float(policy.get("threshold", tun.auto_repair_default_threshold))
	auto_repair_daily_cap = int(policy.get("daily_cap", tun.auto_repair_default_daily_cap))
	_condition_accum = (data.get("condition_accum", {}) as Dictionary).duplicate(true)
	_event_spikes = (data.get("event_spikes", []) as Array).duplicate(true)
	_deserialize_jobs(data.get("jobs", {}))
	_apply_condition_residuals()
	_refresh_all_edge_state()
	feed.reset(false)
	feed.deserialize(data.get("traffic_feed", {}))
	planner.invalidate_all()
	_recompute_all_congestion(true, 12.0)
	# Overwrite the recompute with the SAVED smoother + density state so the
	# loaded run continues from exactly where the live run's history had it.
	_day_seen = bool(data.get("day_seen", _day_seen))
	sim_minute = int(data.get("sim_minute", sim_minute))
	# A version-1 section keys these two maps by edge id, which does not survive
	# a rebuild once any tile has ever been edited (see `SECTION_VERSION`), so
	# they are dropped rather than mis-applied.
	_c_day_sum.clear()
	_c_day_samples = 0
	if version >= 2:
		var saved_c_day: Dictionary = data.get("c_day_sum", {})
		for edge_id in graph.edge_ids_sorted():
			var key := String(graph.edge(edge_id).get("key", ""))
			if saved_c_day.has(key):
				_c_day_sum[edge_id] = float(saved_c_day[key])
		_c_day_samples = int(data.get("c_day_samples", 0))
	_wx_wear_day = float(data.get("wx_wear_day", 0.0))
	var saved_dyn: Dictionary = data.get("edge_dynamics", {}) if version >= 2 else {}
	if not saved_dyn.is_empty():
		for edge_id in graph.edge_ids_sorted():
			var key := String(graph.edge(edge_id).get("key", ""))
			if saved_dyn.has(key):
				var pair: Array = saved_dyn[key]   # [edge_id, congestion, dens_index]
				graph.edge(edge_id)["congestion"] = float(pair[1])
				graph.edge(edge_id)["dens_index"] = float(pair[2])
		congestion.epoch += 1
		planner.invalidate_all()


func _restore_closure(entry: Dictionary) -> void:
	var tiles: Array = []
	for pair in entry.get("edge_tiles", []):
		tiles.append(Vector2i(int(pair[0]), int(pair[1])))
	var edge_ids: Array[int] = []
	for t in tiles:
		for edge_id in graph.edges_at(t):
			if not edge_ids.has(edge_id):
				edge_ids.append(edge_id)
	edge_ids.sort()
	if edge_ids.is_empty():
		return
	var closure_id := int(entry["id"])
	_closures[closure_id] = {
		"id": closure_id, "edge_ids": edge_ids, "edge_tiles": tiles,
		"cause": String(entry["cause"]), "severity": float(entry.get("severity", 1.0)),
		"start_minute": int(entry.get("start_minute", 0)),
		"expected_end_minute": int(entry.get("expected_end_minute", -1)),
		"source_incident_id": int(entry.get("source_incident_id", -1)),
		"clearing_unit_id": int(entry.get("clearing_unit_id", -1)),
	}
	for edge_id in edge_ids:
		_install_closure(edge_id, closure_id)
		_refresh_edge_state(edge_id)


## RLE `[value, run]` over each block's 256 tiles in row-major local order.
## `condition` stores the uint8 quantisation round(condition × 100) — the wire
## format the doc specifies — and `condition_accum` carries the sub-quantum
## residual so daily decay is lossless across a save (§3.2).
func _serialize_blocks() -> Dictionary:
	var out: Dictionary = {}
	var per_block: Dictionary = {}
	for t in graph.road_tiles_sorted():
		var block := TileGrid.block_of(t.x, t.y)
		var key := "%d,%d" % [block.x, block.y]
		per_block[key] = true
	_condition_accum.clear()
	for key in _sorted_keys(per_block):
		var parts: PackedStringArray = String(key).split(",")
		var bx := int(parts[0])
		var bz := int(parts[1])
		var classes: Array = []
		var conditions: Array = []
		var flags: Array = []
		var residuals: Dictionary = {}
		for local in 256:
			var x := bx * TileGrid.TILES_PER_BLOCK + local % TileGrid.TILES_PER_BLOCK
			var z := bz * TileGrid.TILES_PER_BLOCK + local / TileGrid.TILES_PER_BLOCK
			var t := Vector2i(x, z)
			var road_class := grid.road_class_at(x, z)
			classes.append(road_class)
			var condition := float(_condition.get(t, 0.0)) if road_class != 0 else 0.0
			var quantised := roundi(condition * 100.0)
			conditions.append(quantised)
			flags.append(int(_flags.get(t, 0)))
			var residual := condition - float(quantised) / 100.0
			if absf(residual) > 1e-12:
				residuals[str(local)] = residual
		if not residuals.is_empty():
			_condition_accum[key] = residuals
		out[key] = {"class": _rle(classes), "condition": _rle(conditions),
				"flags": _rle(flags)}
	return out


func _deserialize_blocks(blocks: Dictionary) -> void:
	for key in _sorted_keys(blocks):
		var parts: PackedStringArray = String(key).split(",")
		var bx := int(parts[0])
		var bz := int(parts[1])
		var record: Dictionary = blocks[key]
		var classes := _unrle(record.get("class", []))
		var conditions := _unrle(record.get("condition", []))
		var flags := _unrle(record.get("flags", []))
		for local in mini(256, classes.size()):
			var x := bx * TileGrid.TILES_PER_BLOCK + local % TileGrid.TILES_PER_BLOCK
			var z := bz * TileGrid.TILES_PER_BLOCK + local / TileGrid.TILES_PER_BLOCK
			var road_class := int(classes[local])
			grid.set_road(x, z, road_class)
			if road_class == RoadTunables.CLASS_NONE:
				continue
			var t := Vector2i(x, z)
			_condition[t] = float(int(conditions[local])) / 100.0 if local < conditions.size() \
					else 1.0
			if local < flags.size() and int(flags[local]) != 0:
				_flags[t] = int(flags[local])


func _apply_condition_residuals() -> void:
	for key in _sorted_keys(_condition_accum):
		var parts: PackedStringArray = String(key).split(",")
		var bx := int(parts[0])
		var bz := int(parts[1])
		var residuals: Dictionary = _condition_accum[key]
		for local_key in _sorted_keys(residuals):
			var local := int(local_key)
			var x := bx * TileGrid.TILES_PER_BLOCK + local % TileGrid.TILES_PER_BLOCK
			var z := bz * TileGrid.TILES_PER_BLOCK + local / TileGrid.TILES_PER_BLOCK
			var t := Vector2i(x, z)
			if _condition.has(t):
				_condition[t] = clampf(float(_condition[t]) + float(residuals[local_key]),
						0.0, 1.0)


func _serialize_closures() -> Array:
	var out: Array = []
	for closure_id in _sorted_keys(_closures):
		var closure: Dictionary = _closures[closure_id]
		var tiles: Array = []
		for t in closure["edge_tiles"]:
			tiles.append([t.x, t.y])
		out.append({
			"id": int(closure["id"]), "edge_tiles": tiles,
			"cause": String(closure["cause"]), "severity": float(closure["severity"]),
			"start_minute": int(closure["start_minute"]),
			"expected_end_minute": int(closure["expected_end_minute"]),
			"source_incident_id": int(closure["source_incident_id"]),
			"clearing_unit_id": int(closure["clearing_unit_id"]),
		})
	return out


func _serialize_overrides() -> Array:
	var out: Array = []
	for entry in _overrides:
		var tiles: Array = []
		for t in entry["edge_tiles"]:
			tiles.append([t.x, t.y])
		out.append({"edge_tiles": tiles, "mult": float(entry["mult"]),
				"until_minute": int(entry["until_minute"])})
	return out


static func _rle(values: Array) -> Array:
	var out: Array = []
	var index := 0
	while index < values.size():
		var value: int = values[index]
		var run := 1
		while index + run < values.size() and int(values[index + run]) == value:
			run += 1
		out.append([value, run])
		index += run
	return out


static func _unrle(runs: Array) -> Array:
	var out: Array = []
	for pair in runs:
		var value := int(pair[0])
		for i in int(pair[1]):
			out.append(value)
	return out


# ---------------------------------------------------------------- plumbing

func add_event_spike(venue_tile: Vector2i, start_minute: int, end_minute: int) -> void:
	_event_spikes.append({"venue_tile": venue_tile, "start_minute": start_minute,
			"end_minute": end_minute})


func _emit(event_type: StringName, payload: Dictionary) -> void:
	var event := payload.duplicate()
	event["type"] = event_type
	_events.append(event)


static func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
