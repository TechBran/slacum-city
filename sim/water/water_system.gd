class_name WaterSystem
extends RefCounted
## The water network (doc 05). Phase 1 scope.
##
## Constitution §8: utilities are graphs with capacity/load/condition, never
## coverage percentages. A pressure zone is a connected component of the live
## main graph; a tile's pressure is that zone's MASS BALANCE times a static
## attachment factor, and it goes to zero the instant the zone's supply does.
##
## Per tick, per zone (O(zones) — everything expensive is cached on topology
## change, §2.2):
##
##   D = (res_base·ch_res + com_base·ch_com + proc_base)·restriction + fire + leak
##   S = min( Σ pump flow , feed_capacity )          # simplified min-cut, §2.5
##   tanks absorb the surplus / pay the deficit      # exact at dt 1/240 and 1.0
##   P → clamp( ratio^1.3 · head_factor − break_pen ) smoothed over 3 game-min
##
## Power is read ONLY through doc 04's published fraction (§2.6): 1.0 lit,
## `coverage_frac` on backup, 0.0 dark. Below `pump_trip_fraction` the pump
## trips and holds a restart lockout — which is the game's headline cascade:
## substation → pump → tank drains → hydrants → fire response.
##
## READING NOTE (doc 05 §2.2 vs §2.14 example C). §2.2's parenthetical calls
## the live graph "edges not broken/isolated", but example C runs a BROKEN main
## that still carries the zone (leaking 37.28 m³/h) and only ISOLATION strands
## the branch — which is also the entire point of the `isolate_main` verb. This
## implementation follows the worked example: `broken` conducts and leaks,
## `isolated` leaves the graph. Flagged for the overseer.

const EPSILON := 1e-6
const MINUTES_PER_HOUR := 60.0

var data: WaterData
var topology: WaterTopology
var demand: WaterDemandCache
var failure_model: WaterFailureModel
var ledger: WaterServiceLedger
var repairs: WaterRepairJobs

## Doc 09's TileGrid (or any object exposing `elev_m(x, z)`). Optional: with no
## terrain every tile is at elevation 0 and the head term is 1.0.
var terrain: Object = null
## Doc 04's `is_powered(building_id) -> bool`, injected. Water never touches
## feeders or transformers (§2.6).
var powered_provider: Callable = Callable()

var now_minutes: float = 0.0
var topology_dirty: bool = true
var demand_dirty: bool = false
var maintenance_level: float = 1.0  # doc 03's maintenance budget, [0,1]
var weather_kind: String = "clear"
var air_temp_c: float = 20.0
var restrictions_active: bool = false
var auto_dispatch_water: bool = true
## True once doc 06's incident system owns the `water_main_break` roll (C-46).
## While false the standalone fallback hazard runs so the system is playable
## and testable on its own.
var external_main_breaks: bool = false

var nodes: Dictionary = {}  # id -> WaterNode
var edges: Dictionary = {}  # id -> WaterEdge
var stats: Dictionary = {
	"delivered_m3_total": 0.0, "m3_treated_total": 0.0, "breaks_total": 0,
	"last_rebuild_minutes": 0.0,
}

var _fire_draws: Dictionary = {}  # draw id -> {tile, flow}
var _power_override: Dictionary = {}  # node id -> forced power_output_multiplier
var _zone_incident_delta: Dictionary = {}  # zone_key -> {incident id -> delta}
var _no_water_hours: Dictionary = {}  # building id -> float
var _events: Array = []
var _next_junction: int = 1
var _delivered_m3_hour: float = 0.0
var _treated_m3_hour: float = 0.0
var _delivered_m3_prev_hour: float = 0.0
var _treated_m3_prev_hour: float = 0.0
# Hot constants, resolved once from `data/water.json` — the per-tick solve must
# never walk a JSON dictionary (§2.2's "everything expensive is cached").
var _k_leak_frac: float = 0.25
var _k_break_fallback: float = 0.12
var _k_break_cap: float = 0.50
var _k_trip_fraction: float = 0.35
var _k_restart_minutes: float = 5.0
var _k_tank_low_frac: float = 0.15
var _k_tank_low_floor: float = 0.40
var _k_pressure_exponent: float = 1.3
var _k_pressure_tau_h: float = 0.05
var _k_restriction_mult: float = 0.75
var _node_order_cache: Array = []
var _edge_order_cache: Array = []
var _pump_order_cache: Array = []


func _init(p_data: WaterData, grid_size: int = 112) -> void:
	data = p_data
	topology = WaterTopology.new(grid_size)
	demand = WaterDemandCache.new(p_data)
	failure_model = WaterFailureModel.new(p_data)
	ledger = WaterServiceLedger.new(p_data.global_value("nominal_pressure", 0.60))
	repairs = WaterRepairJobs.new(p_data)
	_k_leak_frac = p_data.global_value("leak_frac_of_capacity", 0.25)
	_k_break_fallback = p_data.global_value("break_pressure_penalty_fallback", 0.12)
	_k_break_cap = p_data.global_value("break_penalty_cap", 0.50)
	_k_trip_fraction = p_data.global_value("pump_trip_fraction", 0.35)
	_k_restart_minutes = p_data.global_value("pump_restart_minutes", 5.0)
	_k_tank_low_frac = p_data.global_value("tank_low_frac", 0.15)
	_k_tank_low_floor = p_data.global_value("tank_low_head_floor", 0.40)
	_k_pressure_exponent = p_data.global_value("pressure_curve_exponent", 1.3)
	_k_pressure_tau_h = p_data.global_value("pressure_tau_h", 0.05)
	_k_restriction_mult = p_data.global_value("restriction_demand_mult", 0.75)


# ------------------------------------------------------------- construction

func add_node(node_id: String, variant: StringName, tile: Vector2i,
		opts: Dictionary = {}) -> WaterNode:
	assert(not nodes.has(node_id), "duplicate water node id " + node_id)
	var node := WaterNode.make(node_id, variant, tile, opts)
	if node.built_at_minutes == 0.0:
		node.built_at_minutes = now_minutes
	if variant == &"tank":
		var capacity := float(data.component(variant, node.level).get("capacity_m3", 0.0))
		node.volume_m3 = clampf(float(opts.get("volume_m3", capacity)), 0.0, capacity)
	nodes[node_id] = node
	_invalidate_order_caches()
	topology_dirty = true
	return node


func remove_node(node_id: String) -> void:
	nodes.erase(node_id)
	_invalidate_order_caches()
	topology_dirty = true


func node(node_id: String) -> WaterNode:
	return nodes.get(node_id)


## `polyline` may be authored vertices or an explicit tile list; endpoints that
## do not land on a node's terminal tile get an implicit `junction` (§2.1 — a
## junction is topology only: no level, no power, no cost).
func add_main(edge_id: String, polyline: Array, opts: Dictionary = {}) -> WaterEdge:
	assert(not edges.has(edge_id), "duplicate main id " + edge_id)
	var tiles := WaterEdge.polyline_tiles(polyline)
	if tiles.is_empty():
		return null
	var a := _node_or_junction_at(tiles[0])
	var b := _node_or_junction_at(tiles[-1])
	var edge := WaterEdge.make(edge_id, a, b, tiles, opts)
	edges[edge_id] = edge
	_invalidate_order_caches()
	topology_dirty = true
	return edge


func remove_main(edge_id: String) -> void:
	edges.erase(edge_id)
	_invalidate_order_caches()
	topology_dirty = true


func edge(edge_id: String) -> WaterEdge:
	return edges.get(edge_id)


func _node_or_junction_at(tile: Vector2i) -> String:
	for node_id in _node_order():
		if (nodes[node_id] as WaterNode).tile == tile:
			return String(node_id)
	var junction_id := "J-%03d" % _next_junction
	while nodes.has(junction_id):
		_next_junction += 1
		junction_id = "J-%03d" % _next_junction
	_next_junction += 1
	add_node(junction_id, &"junction", tile)
	return junction_id


## Doc 02 publishes the archetype and the access tile; this doc turns them into
## the res/com/proc split (§2.4). The MAGNITUDE arrives through `set_demands`.
func attach_building(building_id: String, access_tile: Vector2i, archetype: String) -> void:
	demand.attach_building(building_id, access_tile, archetype)
	ledger.track(building_id)
	# A building is not a topology change: only the demand cache's zone
	# assignment moves, so this never triggers the tile BFS.
	demand_dirty = true


func detach_building(building_id: String) -> void:
	demand.detach_building(building_id)
	ledger.forget(building_id)
	_no_water_hours.erase(building_id)
	demand_dirty = true


## Doc 02's `W_b` per building, in m³/h (§2.4).
func set_demands(demands: Dictionary) -> void:
	demand.set_demands(demands)


## Sorted id caches: `_sorted()` allocates and sorts, which is fine on a
## topology edit and far too expensive at 4 Hz across a hundred nodes.
func _node_order() -> Array:
	if _node_order_cache.is_empty() and not nodes.is_empty():
		_node_order_cache = _sorted(nodes)
	return _node_order_cache


func _edge_order() -> Array:
	if _edge_order_cache.is_empty() and not edges.is_empty():
		_edge_order_cache = _sorted(edges)
	return _edge_order_cache


func _pump_order() -> Array:
	if _pump_order_cache.is_empty():
		for node_id in _node_order():
			if (nodes[node_id] as WaterNode).variant == &"pump":
				_pump_order_cache.append(node_id)
	return _pump_order_cache


func _invalidate_order_caches() -> void:
	_node_order_cache = []
	_edge_order_cache = []
	_pump_order_cache = []


func rebuild_zones() -> void:
	var carried: Dictionary = {}
	for z: PressureZone in topology.zones:
		carried[z.zone_key] = z.persisted_state()
	for edge_id in _edge_order():
		var main: WaterEdge = edges[edge_id]
		main.capacity_m3h = data.main_capacity(main.tier)
	topology.rebuild(nodes, edges, data, terrain)
	for z: PressureZone in topology.zones:
		if carried.has(z.zone_key):
			z.apply_persisted_state(carried[z.zone_key])
		z.tank_volume_m3 = _tank_volume_of(z)
	demand.reassign(topology)
	topology_dirty = false
	demand_dirty = false
	stats["last_rebuild_minutes"] = now_minutes


func _tank_volume_of(z: PressureZone) -> float:
	var total := 0.0
	for node_id in z.live_tank_ids:
		total += (nodes[node_id] as WaterNode).volume_m3
	return total


# ------------------------------------------------------------------ the tick

## Utilities cadence: `dt_h = 1/240` live, `dt_h = 1.0` during offline
## catch-up — the identical code path, which is why the two agree.
## `channels`: doc 01's `water_demand_residential` / `water_demand_commercial`.
func advance(dt_h: float, channels: Dictionary = {}) -> void:
	if topology_dirty:
		rebuild_zones()
	elif demand_dirty:
		demand.reassign(topology)
		demand_dirty = false
	demand.publish(topology)
	var ch_res := float(channels.get("water_demand_residential", 1.0))
	var ch_com := float(channels.get("water_demand_commercial", 1.0))
	var restriction := _k_restriction_mult if restrictions_active else 1.0
	_advance_pump_timers(dt_h)
	for z: PressureZone in topology.zones:
		_solve_zone(z, dt_h, ch_res, ch_com, restriction)
	_publish_edge_flows()
	_accumulate_service(dt_h)
	_update_zone_notifications(dt_h)
	now_minutes += dt_h * MINUTES_PER_HOUR


func _advance_pump_timers(dt_h: float) -> void:
	var trip := _k_trip_fraction
	var lockout := _k_restart_minutes
	for node_id in _pump_order():
		var pump: WaterNode = nodes[node_id]
		var fraction := power_fraction_of(pump)
		if fraction < trip or not pump.is_live():
			if pump.restart_timer_min < lockout:
				if pump.restart_timer_min <= 0.0 and pump.is_live():
					_emit(&"water_pump_tripped", {"node": node_id, "power_fraction": fraction})
				pump.restart_timer_min = lockout
		elif pump.restart_timer_min > 0.0:
			pump.restart_timer_min = maxf(0.0,
					pump.restart_timer_min - dt_h * MINUTES_PER_HOUR)


## Forces one node's `power_output_multiplier` (debug console, and the harness
## for doc 05 §7 test 10's 0.30 brownout point, which no coverage tier produces).
func set_power_fraction_override(node_id: String, fraction: float) -> void:
	_power_override[node_id] = clampf(fraction, 0.0, 1.0)


func clear_power_fraction_override(node_id: String) -> void:
	_power_override.erase(node_id)


## §2.6: doc 04 sheds whole feeders, so an intermediate value comes from BACKUP
## COVERAGE, not partial grid supply — 1.0 lit | coverage_frac | 0.0 dark.
func power_fraction_of(target: WaterNode) -> float:
	if not target.is_powered_kind():
		return 1.0
	if _power_override.has(target.id):
		return float(_power_override[target.id])
	var lit := true
	if powered_provider.is_valid():
		lit = bool(powered_provider.call(target.power_ref))
	if lit:
		return 1.0
	if target.backup_installed:
		return data.coverage_frac_for(target.level)
	return 0.0


func _solve_zone(z: PressureZone, dt_h: float, ch_res: float, ch_com: float,
		restriction: float) -> void:
	# --- demand ------------------------------------------------------------
	var leak := 0.0
	var breaks_penalty := 0.0
	var fallback := _k_break_fallback
	var leak_frac := _k_leak_frac
	for edge_id in z.broken_edge_ids:
		var main: WaterEdge = edges[edge_id]
		leak += main.capacity_m3h * leak_frac * main.severity
		breaks_penalty += main.incident_pressure_penalty if main.owning_incident != "" \
				else fallback * main.severity
	if _zone_incident_delta.has(z.zone_key):
		for incident_id in _sorted(_zone_incident_delta[z.zone_key]):
			breaks_penalty += float(_zone_incident_delta[z.zone_key][incident_id])
	breaks_penalty = minf(breaks_penalty, _k_break_cap)
	var fire := 0.0
	if not _fire_draws.is_empty():
		for draw_id in _sorted(_fire_draws):
			var draw: Dictionary = _fire_draws[draw_id]
			if topology.zone_at_tile(draw["tile"]) == z.index:
				fire += float(draw["flow"])
	var d_build := (z.res_base * ch_res + z.com_base * ch_com + z.proc_base) * restriction
	z.leak_m3h = leak
	z.fire_draw_m3h = fire
	z.demand_m3h = d_build + fire + leak
	z.break_penalty = breaks_penalty

	# --- supply (§2.5) -----------------------------------------------------
	var supply_raw := 0.0
	var trip := _k_trip_fraction
	for node_id in z.live_pump_ids:
		var pump: WaterNode = nodes[node_id]
		var fraction := power_fraction_of(pump)
		var running := fraction >= trip and pump.restart_timer_min <= 0.0
		if not running:
			pump.flow_m3h = 0.0
			continue
		var rated := float(data.component(pump.variant, pump.level).get("rated_flow_m3h", 0.0))
		pump.flow_m3h = minf(rated * fraction * pump.cond_factor(), pump.share_m3h)
		supply_raw += pump.flow_m3h
	z.supply_m3h = minf(supply_raw, z.feed_capacity_m3h) if not z.edge_ids.is_empty() \
			else supply_raw

	# --- tanks (§2.7, exact at both dt) ------------------------------------
	z.tank_volume_m3 = _tank_volume_of(z)
	var delivered := 0.0
	if z.supply_m3h >= z.demand_m3h:
		delivered = z.demand_m3h
		_fill_tanks(z, z.supply_m3h - z.demand_m3h, dt_h)
	else:
		delivered = z.supply_m3h + _drain_tanks(z, z.demand_m3h - z.supply_m3h, dt_h)
	z.tank_volume_m3 = _tank_volume_of(z)
	z.delivered_m3h = delivered
	z.ratio = clampf(delivered / maxf(z.demand_m3h, 0.001), 0.0, 1.0) \
			if z.demand_m3h > 0.0 else 1.0
	_delivered_m3_hour += delivered * dt_h
	_treated_m3_hour += delivered * dt_h

	# --- pressure (§2.8) ---------------------------------------------------
	var head_factor := 1.0
	var low_frac := _k_tank_low_frac
	if z.has_tanks() and z.level_frac() < low_frac:
		var floor_value := _k_tank_low_floor
		head_factor = floor_value + (1.0 - floor_value) * (z.level_frac() / maxf(low_frac, EPSILON))
	if z.dead:
		# §2.2: a component with no live supply node is P = 0, not a decaying
		# one — there is no pipe storage to smooth over.
		z.pressure = 0.0
		return
	var target := clampf(pow(z.ratio, _k_pressure_exponent) * head_factor - breaks_penalty,
			0.0, 1.0)
	var tau := _k_pressure_tau_h
	z.pressure += (target - z.pressure) * minf(1.0, dt_h / maxf(tau, EPSILON))


func _fill_tanks(z: PressureZone, surplus: float, dt_h: float) -> void:
	if surplus <= 0.0 or z.tank_ids.is_empty() or dt_h <= 0.0:
		return
	var free_total := 0.0
	var live: Array = []
	for node_id in z.tank_ids:
		var tank: WaterNode = nodes[node_id]
		if not tank.is_live():
			continue
		var capacity := float(data.component(tank.variant, tank.level).get("capacity_m3", 0.0))
		var free := maxf(0.0, capacity - tank.volume_m3)
		if free <= 0.0:
			continue
		live.append({"node": tank, "free": free, "capacity": capacity})
		free_total += free
	if free_total <= 0.0:
		return
	for entry in live:
		var tank: WaterNode = entry["node"]
		var record: Dictionary = data.component(tank.variant, tank.level)
		var inflow := minf(minf(surplus * float(entry["free"]) / free_total,
				float(record.get("max_inflow_m3h", 0.0))), float(entry["free"]) / dt_h)
		tank.volume_m3 = clampf(tank.volume_m3 + inflow * dt_h, 0.0, float(entry["capacity"]))


func _drain_tanks(z: PressureZone, need: float, dt_h: float) -> float:
	if need <= 0.0 or z.tank_ids.is_empty() or dt_h <= 0.0:
		return 0.0
	var volume_total := 0.0
	var live: Array = []
	for node_id in z.tank_ids:
		var tank: WaterNode = nodes[node_id]
		if not tank.is_live() or tank.volume_m3 <= 0.0:
			continue
		live.append(tank)
		volume_total += tank.volume_m3
	if volume_total <= 0.0:
		return 0.0
	var drawn := 0.0
	for tank: WaterNode in live:
		var record: Dictionary = data.component(tank.variant, tank.level)
		var out := minf(minf(need * tank.volume_m3 / volume_total,
				float(record.get("max_outflow_m3h", 0.0))), tank.volume_m3 / dt_h)
		tank.volume_m3 = maxf(0.0, tank.volume_m3 - out * dt_h)
		drawn += out
	return drawn


## No head-loss solve (§1 non-goals). Mains incident to a supply node carry the
## zone's supply; the rest carry its delivered flow — both split in proportion
## to capacity, which is what makes the trunk upgrade legible in the overlay.
func _publish_edge_flows() -> void:
	for z: PressureZone in topology.zones:
		var feed_share := z.supply_m3h / maxf(z.feed_capacity_m3h, EPSILON)
		var rest_share := z.delivered_m3h / maxf(z.rest_capacity_m3h, EPSILON)
		for edge_id in z.edge_ids:
			var main: WaterEdge = edges[edge_id]
			main.flow_m3h = main.capacity_m3h \
					* (feed_share if z.feed_edge_set.has(edge_id) else rest_share)


func _accumulate_service(dt_h: float) -> void:
	for building_id in demand.sorted_ids():
		var record: Dictionary = demand.buildings[building_id]
		var zone_index := int(record["zone"])
		var ratio := 1.0
		if zone_index >= 0:
			ratio = (topology.zones[zone_index] as PressureZone).ratio
		else:
			ratio = 0.0
		ledger.accumulate(String(building_id), pressure_at(record["tile"]),
				float(record["w_b"]), ratio, dt_h)


func _update_zone_notifications(dt_h: float) -> void:
	var bands: Dictionary = data.effects.get("bands", {})
	var warn := float(bands.get("warn", 0.35))
	var normal := float(bands.get("normal", 0.60))
	var critical := float(bands.get("critical", 0.10))
	var low_warn := data.global_value("tank_low_warn_frac", 0.25)
	var shortage_minutes := data.global_value("shortage_warn_minutes", 20.0)
	for z: PressureZone in topology.zones:
		if z.building_count == 0 and z.edge_ids.is_empty():
			continue
		# Capacity shortage is a STATE, not a component failure (§2.9): no
		# repair job exists — the player has to build.
		if z.ratio < 0.98:
			z.shortage_timer_min += dt_h * MINUTES_PER_HOUR
			if z.shortage_timer_min >= shortage_minutes and not z.shortage_latched:
				z.shortage_latched = true
				_emit(&"water_capacity_shortage", {"zone": z.zone_key,
						"demand_m3h": z.demand_m3h, "supply_m3h": z.supply_m3h})
		else:
			z.shortage_timer_min = 0.0
			z.shortage_latched = false
		if z.has_tanks():
			var frac := z.level_frac()
			if frac <= low_warn and not z.tank_low_latched:
				z.tank_low_latched = true
				_emit(&"water_tank_low", {"zone": z.zone_key, "level_frac": frac})
			elif frac > low_warn + 0.10:
				z.tank_low_latched = false
			if z.tank_volume_m3 <= 0.0 and not z.tank_empty_latched:
				z.tank_empty_latched = true
				_emit(&"water_tank_empty", {"zone": z.zone_key})
			elif z.tank_volume_m3 > 0.0:
				z.tank_empty_latched = false
		if z.pressure < warn and not z.pressure_low_latched:
			z.pressure_low_latched = true
			_emit(&"water_pressure_low", {"zone": z.zone_key, "pressure": z.pressure})
		elif z.pressure >= normal and z.pressure_low_latched:
			z.pressure_low_latched = false
			_emit(&"water_pressure_restored", {"zone": z.zone_key, "pressure": z.pressure})
		if z.pressure < critical:
			if not z.offline_latched:
				z.offline_latched = true
				_emit(&"water_zone_offline", {"zone": z.zone_key, "dead": z.dead,
						"buildings": z.building_count})
			z.no_supply_hours += dt_h
		else:
			z.no_supply_hours = 0.0
			z.offline_latched = false


# ------------------------------------------------------------- the game hour

## Called once per crossed game-hour by the scheduler, live and offline, so the
## failure sequence is identical either way (§2.9, §5.4).
func hourly_step(rng: RngStreams, context: Dictionary = {}) -> Dictionary:
	var dt_h := 1.0
	weather_kind = String(context.get("weather_kind", weather_kind))
	air_temp_c = float(context.get("air_temp_c", air_temp_c))
	_step_freeze_and_condition(dt_h)
	var incidents := _roll_failures(rng)
	_step_contamination(rng, incidents, dt_h)
	_step_no_water_counters(dt_h)
	var completed := repairs.advance(dt_h * MINUTES_PER_HOUR) if auto_dispatch_water else []
	for job in completed:
		_complete_repair(job)
	var factors := ledger.settle_hour()
	stats["delivered_m3_total"] = float(stats["delivered_m3_total"]) + _delivered_m3_hour
	stats["m3_treated_total"] = float(stats["m3_treated_total"]) + _treated_m3_hour
	_delivered_m3_prev_hour = _delivered_m3_hour
	_treated_m3_prev_hour = _treated_m3_hour
	_delivered_m3_hour = 0.0
	_treated_m3_hour = 0.0
	return {"service_factors": factors, "incidents": incidents}


func _step_freeze_and_condition(dt_h: float) -> void:
	var freeze_on := data.flag("freeze_enabled")
	for edge_id in _edge_order():
		var main: WaterEdge = edges[edge_id]
		if freeze_on:
			main.freeze_stress = failure_model.step_freeze_stress(
					main.freeze_stress, air_temp_c, main.insulation, dt_h)
		if main.state == &"ok":
			main.condition = failure_model.decayed_condition(
					main.condition, "main", maintenance_level, dt_h)
	for node_id in _node_order():
		var target: WaterNode = nodes[node_id]
		if target.variant == &"junction" or not target.is_live():
			continue
		var kind := "source" if target.variant == &"source" else String(target.variant)
		target.condition = failure_model.decayed_condition(
				target.condition, kind, maintenance_level, dt_h)


func _roll_failures(rng: RngStreams) -> Array:
	var output_frac: Dictionary = {}
	for node_id in _node_order():
		var pump: WaterNode = nodes[node_id]
		if pump.variant != &"pump":
			continue
		var rated := float(data.component(pump.variant, pump.level).get("rated_flow_m3h", 0.0))
		output_frac[node_id] = pump.flow_m3h / maxf(rated, EPSILON)
	var incidents := failure_model.roll_hour(nodes, rng, {
		"weather_kind": weather_kind, "output_frac": output_frac,
		"now_minutes": now_minutes, "air_temp_c": air_temp_c,
	})
	if not external_main_breaks:
		var utilization: Dictionary = {}
		for edge_id in _edge_order():
			var main: WaterEdge = edges[edge_id]
			utilization[edge_id] = main.flow_m3h / maxf(main.capacity_m3h, EPSILON)
		incidents.append_array(failure_model.roll_mains_fallback(edges, rng, {
			"weather_kind": weather_kind, "utilization": utilization,
		}))
	for incident in incidents:
		_apply_failure(incident)
	return incidents


func _apply_failure(incident: Dictionary) -> void:
	var target_id := String(incident["target_id"])
	var kind := String(incident["kind"])
	if String(incident["target_kind"]) == "edge":
		var main: WaterEdge = edges[target_id]
		main.state = &"broken"
		main.severity = float(incident["severity"])
		main.frozen = bool(incident.get("frozen", false))
		main.broken_at_minutes = now_minutes
		stats["breaks_total"] = int(stats["breaks_total"]) + 1
		topology_dirty = true
		_emit(&"water_freeze_break" if main.frozen else &"water_main_break",
				{"edge": target_id, "severity": main.severity,
				"damage_fraction": float(incident["damage_fraction"])})
	else:
		var failed: WaterNode = nodes[target_id]
		failed.state = &"failed"
		topology_dirty = true
		match kind:
			"pump_failure":
				_emit(&"water_pump_failed", {"node": target_id, "severity": incident["severity"]})
			"treatment_failure":
				_emit(&"water_treatment_failed", {"node": target_id, "severity": incident["severity"]})
			"source_failure":
				_emit(&"water_source_failed", {"node": target_id, "severity": incident["severity"]})
	var job := repairs.create(incident, now_minutes)
	if auto_dispatch_water:
		repairs.assign(int(job["job_id"]), "AUTO-WATER-1", "water_repair_truck")
	_emit(&"water_incident_raised", {"kind": kind, "target_kind": incident["target_kind"],
			"target_id": target_id, "severity": incident["severity"],
			"damage_fraction": incident["damage_fraction"], "job_id": job["job_id"]})


func _complete_repair(job: Dictionary) -> void:
	var kind := String(job["kind"])
	var target_id := String(job["target_id"])
	var restored := data.repair_post_condition(kind)
	if String(job["target_kind"]) == "edge" and edges.has(target_id):
		var main: WaterEdge = edges[target_id]
		main.state = &"ok"
		main.severity = 0.0
		main.frozen = false
		main.owning_incident = ""
		main.incident_pressure_penalty = 0.0
		main.condition = maxf(main.condition, restored)
	elif nodes.has(target_id):
		var repaired: WaterNode = nodes[target_id]
		repaired.state = &"ok"
		repaired.condition = maxf(repaired.condition, restored)
		repaired.restart_timer_min = 0.0
	topology_dirty = true
	_emit(&"water_repair_completed", {"kind": kind, "target_id": target_id,
			"job_id": job["job_id"]})


## §2.10 stub: a zone-level flag with no chemistry model, no pressure effect
## and NO hydrant effect — fire suppression is untouched by a boil-water order.
func _step_contamination(rng: RngStreams, incidents: Array, dt_h: float) -> void:
	if not data.flag("contamination_enabled"):
		return
	var chance := float(data.contamination.get("on_treatment_fail_chance", 0.35))
	var base_minutes := float(data.contamination.get("base_minutes", 720.0))
	for incident in incidents:
		if String(incident["kind"]) != "treatment_failure":
			continue
		if rng.stream(WaterFailureModel.FAILURE_STREAM).randf() >= chance:
			continue
		var z := topology.zone_of(String(incident["target_id"]))
		if z == null or z.contaminated:
			continue
		z.contaminated = true
		z.contaminated_until_minutes = now_minutes + base_minutes
		z.flush_remaining_minutes = float(data.contamination.get("flush_minutes", 360.0))
		_emit(&"water_contamination_started", {"zone": z.zone_key,
				"until_minutes": z.contaminated_until_minutes})
	for z: PressureZone in topology.zones:
		if not z.contaminated:
			continue
		if now_minutes < z.contaminated_until_minutes:
			continue
		# Clearing needs the plant back AND the flush countdown (§2.10).
		if not _treatment_healthy(z):
			continue
		z.flush_remaining_minutes = maxf(0.0,
				z.flush_remaining_minutes - dt_h * MINUTES_PER_HOUR)
		if z.flush_remaining_minutes <= 0.0:
			z.contaminated = false
			_emit(&"water_contamination_cleared", {"zone": z.zone_key})


func _treatment_healthy(z: PressureZone) -> bool:
	for node_id in z.treatment_ids:
		if not (nodes[node_id] as WaterNode).is_live():
			return false
	return true


## §2.11: no deaths from a water outage alone (spec §31) — residents leave.
func _step_no_water_counters(dt_h: float) -> void:
	var no_water := data.effect("no_water_pressure_threshold", 0.10)
	var recover := data.effect("recovery_pressure_threshold", 0.35)
	var decay := data.effect("no_water_counter_decay_per_hour", 4.0)
	for building_id in demand.sorted_ids():
		var pressure := pressure_at(demand.access_tile(String(building_id)))
		var hours := float(_no_water_hours.get(building_id, 0.0))
		if pressure < no_water:
			hours += dt_h
		elif pressure >= recover:
			hours = maxf(0.0, hours - decay * dt_h)
		_no_water_hours[building_id] = hours


# ------------------------------------------------------------------ queries

func pressure_at(tile: Vector2i) -> float:
	var index := topology.zone_at_tile(tile)
	if index < 0:
		return 0.0
	return (topology.zones[index] as PressureZone).pressure * topology.factor_at_tile(tile)


func zone_at(tile: Vector2i) -> PressureZone:
	return topology.zone(topology.zone_at_tile(tile))


## §2.8 — doc 06 consumes a ratio that may exceed 1.0: a strong system with
## full tanks suppresses faster than nominal.
func hydrant_pressure_ratio(tile: Vector2i) -> float:
	var index := topology.zone_at_tile(tile)
	if index < 0:
		return 0.0
	var z: PressureZone = topology.zones[index]
	return clampf(pressure_at(tile) * overpressure(z), 0.0, 1.2)


func overpressure(z: PressureZone) -> float:
	var bonus := data.global_value("overpressure_bonus_max", 0.20)
	var margin := clampf((z.supply_m3h / maxf(z.demand_m3h, EPSILON) - 1.0) / 0.5, 0.0, 1.0)
	var storage := clampf((z.level_frac() - 0.80) / 0.20, 0.0, 1.0) if z.has_tanks() else 0.0
	return 1.0 + bonus * margin * storage


## §2.11's building-facing bundle. Doc 02 / doc 09 consume it.
func get_water_service(building_id: String) -> Dictionary:
	var tile := demand.access_tile(building_id)
	var pressure := pressure_at(tile)
	var z := zone_at(tile)
	var reference := data.effect("happiness_pressure_ref", 0.60)
	var penalty := data.effect("happiness_penalty_max", 40.0) \
			* pow(clampf((reference - pressure) / maxf(reference, EPSILON), 0.0, 1.0),
					data.effect("happiness_exponent", 1.2))
	var floor_value := data.effect("output_mult_floor", 0.15)
	var output := floor_value + (1.0 - floor_value) \
			* clampf(pressure / maxf(data.effect("output_pressure_ref", 0.60), EPSILON), 0.0, 1.0)
	return {
		"pressure": pressure,
		"output_mult": output,
		"happiness_penalty": penalty,
		"contaminated": z != null and z.contaminated,
		"band": z.color_band(data.effects.get("bands", {})) if z != null else "none",
		"zone_key": z.zone_key if z != null else "",
		"no_water_hours": float(_no_water_hours.get(building_id, 0.0)),
	}


## Doc 03's `w_b` (§5.4). 1.0 until the first hour settles.
func water_service_factor_hour(building_id: String) -> float:
	return ledger.service_factor_hour(building_id)


func water_delivered_fraction_hour(building_id: String) -> float:
	return ledger.delivered_fraction_hour(building_id)


func service_factors() -> Dictionary:
	return ledger.all_service_factors()


## §2.11: residents leave at `abandon_rate_per_hour` past `abandon_hours`.
func abandonment_rate_per_hour(building_id: String) -> float:
	var hours := float(_no_water_hours.get(building_id, 0.0))
	if hours < data.effect("abandon_hours", 36.0):
		return 0.0
	return data.effect("abandon_rate_per_hour", 0.005)


func no_water_hours(building_id: String) -> float:
	return float(_no_water_hours.get(building_id, 0.0))


## Doc 02's upgrade gate input (§2.11, its check E_WATER_HEADROOM).
func zone_headroom_m3h(building_id: String) -> float:
	var z := zone_at(demand.access_tile(building_id))
	return 0.0 if z == null else z.headroom_m3h()


func can_upgrade_water(building_id: String, delta_water_m3h: float) -> Dictionary:
	var tile := demand.access_tile(building_id)
	var z := zone_at(tile)
	if z == null or z.dead:
		return {"ok": false, "reason": "BLOCKED_WATER_CAPACITY", "deficit_m3h": delta_water_m3h}
	var safety := data.effect("upgrade_headroom_safety", 1.10)
	var required := delta_water_m3h * safety
	var headroom := z.headroom_m3h()
	if headroom < required:
		return {"ok": false, "reason": "BLOCKED_WATER_CAPACITY",
				"deficit_m3h": required - headroom}
	if pressure_at(tile) < data.effect("upgrade_min_pressure", 0.55):
		return {"ok": false, "reason": "BLOCKED_WATER_CAPACITY", "deficit_m3h": 0.0}
	return {"ok": true, "reason": "", "deficit_m3h": 0.0}


## §2.9 / C-46: the candidate set AND the three hazard multipliers doc 06
## multiplies into its own `water_main_break` rate. Doc 06 owns the roll.
##
## **`tile` and `zone_key` are additive (Wave 7, audit 91 D-14).** Doc 06's
## candidate row wants a POSITION (the break has to be somewhere on the map, and
## its incident carries a tile) and the ZONE the segment belongs to (§2.8's
## tiered pressure delta is a zone effect). Both were already inside this class —
## `WaterEdge.path` and `topology.zone_of()`, the latter already resolved on the
## line above for `pressure_ratio` — and neither costs a lookup that this method
## was not already paying. The join into doc 06's vocabulary (`segment_id` → `id`,
## `zone_key` → `zone`) stays in `CityIncidentWorld`, where every other
## cross-document rename lives.
func mains() -> Array:
	var out: Array = []
	for edge_id in _edge_order():
		var main: WaterEdge = edges[edge_id]
		var utilization := main.flow_m3h / maxf(main.capacity_m3h, EPSILON)
		var z := topology.zone_of(edge_id)
		out.append({
			"segment_id": edge_id, "tier": main.tier,
			"length_km": main.length_km(), "condition": main.condition,
			"utilization": utilization,
			"pressure_ratio": z.pressure if z != null else 0.0,
			"freeze_stress": main.freeze_stress,
			"ground_saturation": 0.0,  # doc 07 supplies it; 0 with no weather system
			"cond_mult": failure_model.cond_mult(main.condition),
			"load_mult": failure_model.main_load_mult(utilization),
			"freeze_mult": failure_model.freeze_mult(main.freeze_stress),
			"break_rate_mult": data.main_break_rate_mult(main.tier),
			"state": String(main.state),
			"tile": main_tile(main),
			"zone_key": z.zone_key if z != null else "",
		})
	return out


## The tile a break on this main happens ON. The MIDPOINT of the run, not an
## endpoint: an endpoint tile is shared with the adjoining segment (and with a
## facility node), so two different mains breaking would report the same
## position and the map would show one incident where there are two. Integer
## division, so the answer is the same tile on every platform and after a save.
static func main_tile(main: WaterEdge) -> Vector2i:
	if main.path.is_empty():
		return Vector2i.ZERO
	return main.path[main.path.size() / 2]


## Doc 06's tiered `zone_pressure_delta` (−0.15 / −0.35 / −0.60 / −0.80) applied
## to the segment its incident OWNS — §2.8 and `WaterEdge`'s own header say this
## is where the magnitude lives, and `_solve_zone` only reads it while
## `owning_incident` is set. Separate from `set_segment_broken` because
## escalation re-states the magnitude on every tier and must not re-count the
## break in `stats.breaks_total`.
func set_incident_pressure(edge_id: String, magnitude: float) -> void:
	var main: WaterEdge = edges.get(edge_id)
	if main == null:
		return
	main.incident_pressure_penalty = absf(magnitude)


## Doc 03's `E_water` inputs and the water tariff basis (§5.3). Never a dollar.
func inventory() -> Dictionary:
	var main_km := 0.0
	var weighted_condition := 0.0
	var pump_capacity := 0.0
	for edge_id in _edge_order():
		var main: WaterEdge = edges[edge_id]
		var km := main.length_km()
		main_km += km
		weighted_condition += km * main.condition
	for node_id in _node_order():
		var pump: WaterNode = nodes[node_id]
		if pump.variant == &"pump" and pump.is_live():
			pump_capacity += float(data.component(pump.variant, pump.level)
					.get("rated_flow_m3h", 0.0))
	return {
		"m3_treated": _treated_m3_prev_hour,
		"delivered_m3": _delivered_m3_prev_hour,
		"main_km": main_km,
		"main_condition": weighted_condition / main_km if main_km > 0.0 else 1.0,
		"pump_capacity_m3h": pump_capacity,
	}


## §5.3's resilience input: how much of the city's demand the live supply
## covers, weighted by zone demand. 1.0 = every zone has headroom.
func water_margin_score() -> float:
	var demand_total := 0.0
	var served := 0.0
	for z: PressureZone in topology.zones:
		demand_total += z.demand_m3h
		served += minf(z.supply_m3h, z.demand_m3h)
	return 1.0 if demand_total <= 0.0 else clampf(served / demand_total, 0.0, 1.0)


## §2.11's district input: mean over the game-day of clamp(P/0.6). Reported
## instantaneously here; doc 09 does the day-averaging.
func water_reliability_at(tile: Vector2i) -> float:
	return clampf(pressure_at(tile) / maxf(data.global_value("nominal_pressure", 0.60),
			EPSILON), 0.0, 1.0)


## §5.8 HUD figure — `Water: NN%`, zone-pressure weighted by building count.
func water_health_pct() -> float:
	var total := 0
	var weighted := 0.0
	var reference := data.global_value("nominal_pressure", 0.60)
	for z: PressureZone in topology.zones:
		total += z.building_count
		weighted += float(z.building_count) * clampf(z.pressure / reference, 0.0, 1.0)
	return 100.0 if total == 0 else roundf(100.0 * weighted / float(total))


# ------------------------------------------------------------ doc 06 verbs

func fire_flow_per_engine_m3h() -> float:
	return data.global_value("fire_flow_per_engine_m3h", 8.0)


func register_fire_draw(draw_id: String, tile: Vector2i, flow_m3h: float) -> void:
	_fire_draws[draw_id] = {"tile": tile, "flow": flow_m3h}


func register_fire_engines(draw_id: String, tile: Vector2i, engines: int) -> void:
	register_fire_draw(draw_id, tile, float(engines) * fire_flow_per_engine_m3h())


func clear_fire_draw(draw_id: String) -> void:
	_fire_draws.erase(draw_id)


## Doc 06 drives the break; its tiered `zone_pressure_delta` (−0.15 / −0.35 /
## −0.60 / −0.80) is authoritative and is held until the incident resolves.
func set_segment_broken(edge_id: String, severity: float, incident_id: String = "",
		pressure_delta: float = 0.0) -> void:
	if not edges.has(edge_id):
		return
	var main: WaterEdge = edges[edge_id]
	main.state = &"broken"
	main.severity = clampf(severity, 0.0, 1.0)
	main.owning_incident = incident_id
	# Stored as a magnitude: §2.8 consumes |delta|, and the save section stays
	# free of negative floats (see the CitySim._encode_floats note).
	main.incident_pressure_penalty = absf(pressure_delta)
	main.broken_at_minutes = now_minutes
	stats["breaks_total"] = int(stats["breaks_total"]) + 1
	topology_dirty = true


func set_segment_repaired(edge_id: String) -> void:
	if not edges.has(edge_id):
		return
	var main: WaterEdge = edges[edge_id]
	main.state = &"ok"
	main.severity = 0.0
	main.frozen = false
	main.owning_incident = ""
	main.incident_pressure_penalty = 0.0
	main.condition = maxf(main.condition, data.repair_post_condition("main_break"))
	topology_dirty = true


## A zone-wide held delta for a doc-06 incident with no owning segment.
func zone_pressure_delta(zone_key: String, incident_id: String, delta: float) -> void:
	if not _zone_incident_delta.has(zone_key):
		_zone_incident_delta[zone_key] = {}
	_zone_incident_delta[zone_key][incident_id] = absf(delta)


func clear_zone_pressure_delta(zone_key: String, incident_id: String) -> void:
	if _zone_incident_delta.has(zone_key):
		_zone_incident_delta[zone_key].erase(incident_id)


func damage_fraction(severity: float, frozen: bool = false) -> float:
	return failure_model.damage_fraction(severity, frozen)


# --------------------------------------------------- §6 placement (siting)

## The nearest LIVE main tile to `tile`, within `max_radius` Chebyshev, or `{}`.
## Connectivity in this doc is physical — two entities are joined when they
## share a tile (§2.2) — so this is the whole of "can a new site reach the
## network": run a lateral from the tile this returns to the site, and the
## union-find joins them on the next `rebuild_zones()`.
##
## Deterministic: edges in sorted id order, tiles in path order, and the key
## `[distance, tile]` breaks every tie the same way on every machine.
func nearest_main_tile(tile: Vector2i, max_radius: int) -> Dictionary:
	var best: Dictionary = {}
	var best_key: Array = [999999, 999999, 999999]
	for edge_id in _edge_order():
		var main: WaterEdge = edges[edge_id]
		if not main.is_live():
			continue
		for entry in main.path:
			var t: Vector2i = entry
			var d: int = maxi(absi(tile.x - t.x), absi(tile.y - t.y))
			if d > max_radius:
				continue
			var key: Array = [d, t.y, t.x]
			if key < best_key:
				best_key = key
				best = {"edge": String(edge_id), "tap_tile": t, "distance": d,
						"tier": main.tier}
	return best


## The tile run a lateral takes from `from` to `to`, EXCLUSIVE of `from` and
## inclusive of `to` — the same diagonal-then-straight shape doc 04 §2.1's
## feeder lateral uses, so a water lateral and a power lateral of the same span
## are the same number of tiles and the two prices stay comparable.
static func lateral_tiles(from: Vector2i, to: Vector2i) -> Array:
	var out: Array = []
	var cursor := from
	while cursor != to:
		cursor.x += signi(to.x - cursor.x)
		cursor.y += signi(to.y - cursor.y)
		out.append(cursor)
	return out


## The facility or junction whose terminal tile is `tile`, or "".
func node_at_tile(tile: Vector2i) -> String:
	for node_id in _node_order():
		if (nodes[node_id] as WaterNode).tile == tile:
			return String(node_id)
	return ""


## Player component ids are `<PREFIX>-NNN`, numbered above every id the system
## already carries so a reload can never collide with an authored node.
func next_node_id(prefix: String) -> String:
	var highest := 0
	for node_id in _node_order():
		var id := String(node_id)
		if id.begins_with(prefix + "-"):
			highest = maxi(highest, id.substr(prefix.length() + 1).to_int())
	return "%s-%03d" % [prefix, highest + 1]


func next_main_id(prefix: String) -> String:
	var highest := 0
	for edge_id in _edge_order():
		var id := String(edge_id)
		if id.begins_with(prefix + "-"):
			highest = maxi(highest, id.substr(prefix.length() + 1).to_int())
	return "%s-%03d" % [prefix, highest + 1]


## §2.1: a main's tiles may not double up on a live main's tiles except at the
## junction it taps. Returns the first offending tile, or (−1, −1).
func first_occupied_main_tile(tiles: Array, ignore_edge: String = "") -> Vector2i:
	var claimed: Dictionary = {}
	for edge_id in _edge_order():
		if String(edge_id) == ignore_edge:
			continue
		for entry in (edges[edge_id] as WaterEdge).path:
			claimed[entry] = true
	for entry in tiles:
		if claimed.has(entry):
			return entry
	return Vector2i(-1, -1)


# ------------------------------------------------------------- player verbs

func cmd_place_water_node(node_id: String, variant: String, tile: Vector2i,
		opts: Dictionary = {}) -> Dictionary:
	if not WaterNode.VARIANTS.has(StringName(variant)):
		return CommandQueue.fail(&"E_UNKNOWN_VARIANT")
	if variant == "booster" and not data.flag("boosters_enabled"):
		return CommandQueue.fail(&"E_VARIANT_LOCKED")
	if variant == "source" and String(opts.get("subtype", "river")) == "well" \
			and not data.flag("source_well_enabled"):
		return CommandQueue.fail(&"E_VARIANT_LOCKED")
	if nodes.has(node_id):
		return CommandQueue.fail(&"E_DUPLICATE_ID")
	var placed := add_node(node_id, StringName(variant), tile, opts)
	return CommandQueue.ok({"node": node_id, "variant": variant,
			"kw_required": data.kw_required(placed.variant, placed.level, placed.subtype)})


func cmd_place_main(edge_id: String, polyline: Array, tier: String = "service") -> Dictionary:
	if not data.mains.has(tier):
		return CommandQueue.fail(&"E_UNKNOWN_TIER")
	if tier == "arterial" and not data.flag("levels_4_5_enabled"):
		return CommandQueue.fail(&"E_TIER_LOCKED")
	if edges.has(edge_id):
		return CommandQueue.fail(&"E_DUPLICATE_ID")
	var placed := add_main(edge_id, polyline, {"tier": tier})
	if placed == null:
		return CommandQueue.fail(&"E_EMPTY_PATH")
	return CommandQueue.ok({"edge": edge_id, "tiles": placed.path.size(),
			"capacity_m3h": data.main_capacity(tier)})


func cmd_remove_main(edge_id: String) -> Dictionary:
	if not edges.has(edge_id):
		return CommandQueue.fail(&"E_UNKNOWN_MAIN")
	remove_main(edge_id)
	return CommandQueue.ok({"edge": edge_id})


func cmd_upgrade_water_node(node_id: String) -> Dictionary:
	if not nodes.has(node_id):
		return CommandQueue.fail(&"E_UNKNOWN_NODE")
	var target: WaterNode = nodes[node_id]
	if target.variant == &"junction":
		return CommandQueue.fail(&"E_NOT_UPGRADEABLE")
	var next_level := target.level + 1
	if next_level > 5 or (next_level >= 4 and not data.flag("levels_4_5_enabled")):
		return CommandQueue.fail(&"E_MAX_LEVEL")
	target.level = next_level
	if target.variant == &"tank":
		var capacity := float(data.component(target.variant, next_level).get("capacity_m3", 0.0))
		target.volume_m3 = minf(target.volume_m3, capacity)
	topology_dirty = true
	return CommandQueue.ok({"node": node_id, "level": next_level,
			"kw_required": data.kw_required(target.variant, next_level, target.subtype),
			"backup_kw": data.backup_kw_for(target.variant, next_level, target.subtype)})


## Doc 04 owns the generator itself (C-36). This validates the node and hands
## doc 04 the three numbers it needs: `kw_required`, `backup_kw`, `coverage_frac`.
func cmd_install_backup_generator(node_id: String) -> Dictionary:
	if not nodes.has(node_id):
		return CommandQueue.fail(&"E_UNKNOWN_NODE")
	var target: WaterNode = nodes[node_id]
	if target.variant == &"junction":
		return CommandQueue.fail(&"E_NOT_BACKUP_CAPABLE")
	if target.level < 2:
		return CommandQueue.fail(&"E_BACKUP_LEVEL")
	target.backup_installed = true
	return CommandQueue.ok(backup_spec(node_id))


## The doc 04 contract for one node (§5.5).
func backup_spec(node_id: String) -> Dictionary:
	var target: WaterNode = nodes[node_id]
	return {
		"node": node_id, "power_ref": target.power_ref,
		"priority_class": "CRITICAL", "backup_capable": true,
		"kw_required": data.kw_required(target.variant, target.level, target.subtype),
		"backup_kw": data.backup_kw_for(target.variant, target.level, target.subtype),
		"coverage_frac": data.coverage_frac_for(target.level),
		"installed": target.backup_installed,
	}


## The key tactical verb (§2.12): leak → 0, but everything downstream leaves
## the live graph. Trading a neighbourhood's taps for the fire's hydrants.
func cmd_isolate_main(edge_id: String) -> Dictionary:
	if not edges.has(edge_id):
		return CommandQueue.fail(&"E_UNKNOWN_MAIN")
	var main: WaterEdge = edges[edge_id]
	main.state = &"isolated"
	topology_dirty = true
	_emit(&"water_main_isolated", {"edge": edge_id})
	return CommandQueue.ok({"edge": edge_id,
			"work_minutes": repairs.work_content_minutes("isolate_main", 0.5)})


func cmd_restore_main(edge_id: String) -> Dictionary:
	if not edges.has(edge_id):
		return CommandQueue.fail(&"E_UNKNOWN_MAIN")
	var main: WaterEdge = edges[edge_id]
	if main.state != &"isolated":
		return CommandQueue.fail(&"E_NOT_ISOLATED")
	main.state = &"ok"
	topology_dirty = true
	return CommandQueue.ok({"edge": edge_id})


## Priced by doc 03 as `repair_cost(node, damage_fraction = 1 − condition)`.
func cmd_overhaul_node(node_id: String) -> Dictionary:
	if not nodes.has(node_id):
		return CommandQueue.fail(&"E_UNKNOWN_NODE")
	var target: WaterNode = nodes[node_id]
	var job := repairs.create({"kind": "overhaul", "target_kind": "node",
			"target_id": node_id, "tile": target.tile, "severity": 1.0,
			"damage_fraction": clampf(1.0 - target.condition, 0.0, 1.0)}, now_minutes)
	if auto_dispatch_water:
		repairs.assign(int(job["job_id"]), "AUTO-WATER-1", "water_repair_truck")
	return CommandQueue.ok({"job_id": job["job_id"],
			"damage_fraction": job["damage_fraction"]})


func cmd_set_water_restrictions(active: bool) -> Dictionary:
	if not data.flag("restrictions_enabled"):
		return CommandQueue.fail(&"E_POLICY_LOCKED")
	restrictions_active = active
	return CommandQueue.ok({"water_restrictions": active})


func cmd_set_water_policy(policy: Dictionary) -> Dictionary:
	if policy.has("auto_dispatch_water"):
		auto_dispatch_water = bool(policy["auto_dispatch_water"])
	if policy.has("water_restrictions") and data.flag("restrictions_enabled"):
		restrictions_active = bool(policy["water_restrictions"])
	return CommandQueue.ok({"water_restrictions": restrictions_active,
			"auto_dispatch_water": auto_dispatch_water})


func cmd_deploy_pump_truck(_zone_key: String) -> Dictionary:
	# Post-MVP (§6): `water_pump_truck` temporary supply is gated off.
	return CommandQueue.fail(&"E_FEATURE_LOCKED")


# ------------------------------------------------------------------ overlay

func get_overlay_snapshot() -> Dictionary:
	return WaterSnapshot.build(self)


func drain_events() -> Array:
	var out := _events
	_events = []
	return out


func _emit(event_type: StringName, payload: Dictionary) -> void:
	var event := payload.duplicate()
	event["type"] = event_type
	_events.append(event)


# -------------------------------------------------------------- persistence

## Save section `"water"` (doc 05 §3.2). Zone ids are unstable across rebuilds,
## so the zones array is keyed by `zone_key` and re-mapped on load; zone→tile
## maps, `tile_factor`, `feed_capacity`, `upstream_cap` and the demand sums are
## NOT saved — `deserialize()` ends with a `rebuild_zones()`.
##
## Doc 07's `weather_kind` / `air_temp_c` are deliberately absent: doc 07 owns
## them and re-injects them through `hourly_step`'s context, and `air_temp_c` is
## the one field here that could go negative. `CitySim._encode_floats` currently
## corrupts every negative non-integral float to 0.0 (`"%016x"` on a negative
## int64 emits a leading `-`, and `hex_to_int` then rejects it), so this section
## keeps every persisted float non-negative until that encoder is fixed.
func serialize() -> Dictionary:
	var node_records: Array = []
	for node_id in _node_order():
		node_records.append((nodes[node_id] as WaterNode).serialize())
	var edge_records: Array = []
	for edge_id in _edge_order():
		edge_records.append((edges[edge_id] as WaterEdge).serialize())
	var zone_records: Array = []
	for z: PressureZone in topology.zones:
		zone_records.append(z.persisted_state())
	var fire: Dictionary = {}
	for draw_id in _sorted(_fire_draws):
		var draw: Dictionary = _fire_draws[draw_id]
		fire[draw_id] = {"tile": [draw["tile"].x, draw["tile"].y], "flow": float(draw["flow"])}
	var deltas: Dictionary = {}
	for zone_key in _sorted(_zone_incident_delta):
		var per_zone: Dictionary = {}
		for incident_id in _sorted(_zone_incident_delta[zone_key]):
			per_zone[incident_id] = float(_zone_incident_delta[zone_key][incident_id])
		deltas[zone_key] = per_zone
	var counters: Dictionary = {}
	for building_id in _sorted(_no_water_hours):
		counters[building_id] = float(_no_water_hours[building_id])
	return {
		"section_version": 2,
		"now_minutes": now_minutes,
		"next_junction": _next_junction,
		"nodes": node_records,
		"edges": edge_records,
		"zones": zone_records,
		"jobs": repairs.serialize(),
		"demand": demand.serialize(),
		"service": ledger.serialize(),
		"fire_draws": fire,
		"zone_incident_delta": deltas,
		"no_water_hours": counters,
		"policy": {"water_restrictions": restrictions_active,
				"auto_dispatch_water": auto_dispatch_water},
		"environment": {"maintenance_level": maintenance_level,
				"external_main_breaks": external_main_breaks},
		"hour_accum": {"delivered_m3": _delivered_m3_hour, "treated_m3": _treated_m3_hour,
				"delivered_m3_prev": _delivered_m3_prev_hour,
				"treated_m3_prev": _treated_m3_prev_hour},
		"stats": stats.duplicate(),
	}


func deserialize(state: Dictionary) -> void:
	nodes.clear()
	edges.clear()
	_invalidate_order_caches()
	for record in state.get("nodes", []):
		var restored := WaterNode.deserialize(record)
		nodes[restored.id] = restored
	for record in state.get("edges", []):
		var restored := WaterEdge.deserialize(record)
		edges[restored.id] = restored
	now_minutes = float(state.get("now_minutes", 0.0))
	_next_junction = int(state.get("next_junction", 1))
	repairs.deserialize(state.get("jobs", {}))
	demand.deserialize(state.get("demand", {}))
	ledger.deserialize(state.get("service", {}))
	_fire_draws.clear()
	for draw_id in _sorted(state.get("fire_draws", {})):
		var draw: Dictionary = state["fire_draws"][draw_id]
		var tile_pair: Array = draw["tile"]
		_fire_draws[String(draw_id)] = {"tile": Vector2i(int(tile_pair[0]), int(tile_pair[1])),
				"flow": float(draw["flow"])}
	_zone_incident_delta.clear()
	for zone_key in _sorted(state.get("zone_incident_delta", {})):
		var per_zone: Dictionary = {}
		for incident_id in _sorted(state["zone_incident_delta"][zone_key]):
			per_zone[String(incident_id)] = float(state["zone_incident_delta"][zone_key][incident_id])
		_zone_incident_delta[String(zone_key)] = per_zone
	_no_water_hours.clear()
	for building_id in _sorted(state.get("no_water_hours", {})):
		_no_water_hours[String(building_id)] = float(state["no_water_hours"][building_id])
	var policy: Dictionary = state.get("policy", {})
	restrictions_active = bool(policy.get("water_restrictions", false))
	auto_dispatch_water = bool(policy.get("auto_dispatch_water", true))
	var environment: Dictionary = state.get("environment", {})
	maintenance_level = float(environment.get("maintenance_level", 1.0))
	# A LATCH, not a restore. Who rolls the main break is a fact about the
	# program that is running — whether a doc 06 `IncidentSystem` is wired in at
	# all — and not a fact about this city. A save written before doc 06's
	# adapter existed (audit 91 D-14) carries `false`, and honouring it would
	# switch doc 05's standalone fallback back ON underneath a running incident
	# engine, so both would roll. Loading can only ever ADD the claim.
	external_main_breaks = external_main_breaks \
			or bool(environment.get("external_main_breaks", false))
	var accum: Dictionary = state.get("hour_accum", {})
	_delivered_m3_hour = float(accum.get("delivered_m3", 0.0))
	_treated_m3_hour = float(accum.get("treated_m3", 0.0))
	_delivered_m3_prev_hour = float(accum.get("delivered_m3_prev", 0.0))
	_treated_m3_prev_hour = float(accum.get("treated_m3_prev", 0.0))
	topology_dirty = true
	rebuild_zones()
	# AFTER the rebuild: `rebuild_zones()` restamps `last_rebuild_minutes`, and
	# a load must reproduce the saved value, not the load's own timestamp.
	stats = (state.get("stats", stats) as Dictionary).duplicate()
	# Zone pressures are keyed by the stable zone_key; an unknown key defaults
	# to 1.0 rather than to a dry zone (§3.2).
	for record in state.get("zones", []):
		var z := topology.zone_by_key(String(record.get("zone_key", "")))
		if z != null:
			z.apply_persisted_state(record)


## `section_version` 1 → 2 (§3.2): `kind` → `variant` (+ `subtype`), the
## `backup` object collapses to `backup_installed` with fuel moving to doc 04's
## section (C-36), `owning_incident` on edges (C-46), `damage_fraction` on jobs
## (C-16), `service_accum` added (C-37), `auto_refuel_backup` removed.
static func migrate_water_v1_to_v2(state: Dictionary) -> Dictionary:
	if int(state.get("section_version", 1)) >= 2:
		return state
	var out: Dictionary = state.duplicate(true)
	var migrated_nodes: Array = []
	for record in out.get("nodes", []):
		var node_record: Dictionary = record
		if node_record.has("kind") and not node_record.has("variant"):
			var kind := String(node_record["kind"])
			if kind == "well":
				node_record["variant"] = "source"
				node_record["subtype"] = "well"
			elif kind == "river_intake" or kind == "intake":
				node_record["variant"] = "source"
				node_record["subtype"] = "river"
			else:
				node_record["variant"] = kind
				node_record["subtype"] = node_record.get("subtype", "")
			node_record.erase("kind")
		var backup: Variant = node_record.get("backup", null)
		if typeof(backup) == TYPE_DICTIONARY:
			node_record["backup_installed"] = bool((backup as Dictionary).get("installed", true))
		node_record.erase("backup")
		node_record.erase("fuel_l")
		node_record.erase("start_timer_min")
		migrated_nodes.append(node_record)
	out["nodes"] = migrated_nodes
	var migrated_edges: Array = []
	for record in out.get("edges", []):
		var edge_record: Dictionary = record
		if not edge_record.has("owning_incident"):
			edge_record["owning_incident"] = ""
		migrated_edges.append(edge_record)
	out["edges"] = migrated_edges
	var jobs_section: Dictionary = out.get("jobs", {})
	var migrated_jobs: Array = []
	for record in jobs_section.get("jobs", []):
		var job_record: Dictionary = record
		if not job_record.has("damage_fraction"):
			job_record["damage_fraction"] = 0.0
		migrated_jobs.append(job_record)
	jobs_section["jobs"] = migrated_jobs
	out["jobs"] = jobs_section
	var policy: Dictionary = out.get("policy", {})
	policy.erase("auto_refuel_backup")
	out["policy"] = policy
	if not out.has("service"):
		out["service"] = {"service_accum": {}, "settled": {}}
	out["section_version"] = 2
	return out


static func _sorted(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
