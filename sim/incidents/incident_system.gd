class_name IncidentSystem
extends RefCounted
## The crisis half of the core loop (doc 06). Generation, the severity /
## escalation / resolution integrator, cascades, fire dynamics, dispatch and
## the fleet all hang off ONE entry point — `advance_to(t_h)` — so the online
## path and doc 08's offline catch-up run the same code with the same math and
## differ only in step size (§2.13).
##
## `advance()` never integrates blindly across dt: it repeatedly computes the
## next DISCONTINUITY and advances only to it, so every rate is constant over
## every sub-step by construction and `integrate_linear` is exact. That is what
## makes offline and online identical rather than merely similar.
##
## Time is carried as an ABSOLUTE game-hour and the caller supplies the end of
## each step (`advance_to`), never a delta to accumulate — accumulating 1/60
## sixty times is not 1.0 in binary, and the equivalence guarantee cannot
## survive that drift.

const EPS := 1.0e-9

var catalog: IncidentCatalog
var world: IncidentWorld
var rng: RngStreams
var travel: TravelTimeProvider
var fleet: FleetSystem
var policy: DispatchPolicy
var dispatch: DispatchSystem
var spread: FireSpread
var ops: CascadeOps

var now_h: float = 0.0
## Hour-of-day of tick 0 (GameClock founds the city at 06:00). Set by the
## adapter; only the day/night term reads it.
var founding_offset_h: float = 6.0
var next_id: int = 1
var next_cluster_id: int = 1
var generation_enabled: bool = true
var substep_guard_blown: int = 0
var offline_hours_elapsed: float = 0.0

var _active: Dictionary = {}  # id -> Incident
var _order: Array = []  # ascending incident ids
var _recent: Array = []  # terminal incidents, kept KEEP_RESOLVED_MIN game-min
var _events: Array = []
var _spread_next_h: float = 0.0


func _init(p_catalog: IncidentCatalog, p_world: IncidentWorld, p_rng: RngStreams,
		p_travel: TravelTimeProvider = null) -> void:
	catalog = p_catalog
	world = p_world
	rng = p_rng
	travel = p_travel if p_travel != null else TravelTimeProvider.new()
	fleet = FleetSystem.new(catalog, travel)
	policy = DispatchPolicy.new(catalog.policy_defaults)
	dispatch = DispatchSystem.new(catalog, fleet, policy, world, travel)
	dispatch.system = self
	spread = FireSpread.new(catalog, world)
	ops = CascadeOps.new(world, catalog, self)
	_spread_next_h = catalog.global_value("spread_roll_interval_h", 1.0 / 12.0)


# ------------------------------------------------------------------ the tick

## Doc 06 §2.13's single entry point. Online: dt_h = 1/60. Offline: dt_h = 1.0.
func advance(dt_h: float) -> void:
	advance_to(now_h + dt_h)


func advance_to(t_end_h: float) -> void:
	if t_end_h <= now_h + EPS:
		return
	if world.is_offline():
		offline_hours_elapsed += t_end_h - now_h
	var max_substeps := catalog.global_int("max_substeps_per_hour", 64)
	var min_substep := catalog.global_value("min_substep_h", 1.0 / 3600.0)
	var guard := 0
	while now_h < t_end_h - EPS and guard < max_substeps:
		var remaining := t_end_h - now_h
		var step := minf(remaining, maxf(min_substep, _next_discontinuity_h()))
		step = minf(step, remaining)
		_integrate(step, now_h + step)
		guard += 1
	if now_h < t_end_h - EPS:
		# Guard blown: rare, and logged rather than silently dropped.
		substep_guard_blown += 1
		_integrate(t_end_h - now_h, t_end_h)
	now_h = t_end_h
	fleet.now_h = now_h
	_prune_recent()


func _integrate(dt_h: float, t_end_h: float) -> void:
	var dark := _dark_fraction(now_h, t_end_h)
	# --- 1. linear integration; every rate is constant over dt by construction.
	for incident_id in _order:
		var inc: Incident = _active[incident_id]
		if inc.is_terminal():
			continue
		var tier_before := inc.tier()
		var assist := assist_ratio(inc)
		if not inc.is_active() or assist < 1.0:
			var d_severity := escalation_rate(inc, dark) * maxf(0.0, 1.0 - assist)
			inc.severity = clampf(inc.severity + d_severity * dt_h,
					catalog.global_value("severity_min", 1.0),
					catalog.global_value("severity_max", 5.0))
		if inc.accumulates_progress():
			var work := work_required(inc)
			if work > 0.0:
				inc.progress = clampf(inc.progress
						+ assigned_effective_rate(inc) / work * dt_h, 0.0, 1.0)
		_accumulate_terminal_timers(inc, dt_h, assist)
		var tier_after := inc.tier()
		if tier_after != tier_before:
			# Progress is not reset, but work_required grows, so effective
			# completion slips backwards proportionally (§2.5).
			var work_old := work_required_at(inc, tier_before)
			var work_new := work_required_at(inc, tier_after)
			if work_new > 0.0:
				inc.progress = clampf(inc.progress * work_old / work_new, 0.0, 1.0)
	# --- 2. the clock and the fleet reach the boundary together.
	now_h = t_end_h
	fleet.now_h = now_h
	for unit_id in fleet.advance_to(now_h):
		_on_unit_arrived(int(unit_id))
	# --- 3. discontinuities.
	_fire_tier_entries()
	_check_terminal_conditions()
	_roll_spread()
	_generate(dt_h, dark)
	_rescore_and_dispatch()
	_release_finished_units()


# ------------------------------------------------------------ discontinuities

## Duration (game-hours) to the next discontinuity, or INF.
func _next_discontinuity_h() -> float:
	var best := INF
	var fleet_next := fleet.next_event_h()
	if fleet_next < INF:
		best = minf(best, maxf(0.0, fleet_next - now_h))
	var dark := _dark_fraction(now_h, now_h + 1.0 / 3600.0)
	for incident_id in _order:
		var inc: Incident = _active[incident_id]
		if inc.is_terminal():
			continue
		var assist := assist_ratio(inc)
		var d_severity := escalation_rate(inc, dark) * maxf(0.0, 1.0 - assist)
		if inc.is_active() and assist >= 1.0:
			d_severity = 0.0
		if d_severity > 0.0:
			var next_tier: float = floor(inc.severity) + 1.0
			if next_tier <= catalog.global_value("severity_max", 5.0):
				best = minf(best, maxf(0.0, (next_tier - inc.severity) / d_severity))
		if inc.accumulates_progress():
			var work := work_required(inc)
			var rate := assigned_effective_rate(inc)
			if work > 0.0 and rate > 0.0:
				best = minf(best, maxf(0.0, (1.0 - inc.progress) * work / rate))
		var burn_limit := burn_down_hours(inc)
		if burn_limit > 0.0 and _burn_timer_running(inc, assist):
			best = minf(best, maxf(0.0, burn_limit - inc.burn_timer_h))
		var hold_rule: Dictionary = _fail_rule(inc)
		if hold_rule.has("hold_tier") and inc.tier() >= int(hold_rule["hold_tier"]):
			best = minf(best, maxf(0.0, float(hold_rule.get("hold_h", 0.0)) - inc.hold_h))
		var self_resolve := _self_resolve_h(inc)
		if self_resolve > 0.0 and inc.status == Incident.STATUS_QUEUED:
			best = minf(best, maxf(0.0, inc.created_h + self_resolve - now_h))
	best = minf(best, maxf(0.0, _spread_next_h - now_h))
	best = minf(best, _next_daynight_boundary_h())
	var weather_next := world.next_weather_boundary_h()
	if weather_next < INF:
		best = minf(best, maxf(0.0, weather_next))
	return best


func _next_daynight_boundary_h() -> float:
	var hour := fposmod(now_h + founding_offset_h, 24.0)
	var night_start := catalog.global_value("night_start_hour", 19.0)
	var night_end := catalog.global_value("night_end_hour", 6.0)
	var best := INF
	for boundary in [night_end, night_start, night_end + 24.0, night_start + 24.0]:
		var delta: float = float(boundary) - hour
		if delta > EPS:
			best = minf(best, delta)
	return best


## Exact fraction of [t0, t1] that falls in night hours — computed analytically,
## which is why coarse and fine steps agree (§2.4).
func _dark_fraction(t0_h: float, t1_h: float) -> float:
	var night_start := catalog.global_value("night_start_hour", 19.0)
	var night_end := catalog.global_value("night_end_hour", 6.0)
	if t1_h <= t0_h + EPS:
		var hour := fposmod(t0_h + founding_offset_h, 24.0)
		return 1.0 if (hour < night_end or hour >= night_start) else 0.0
	var total := 0.0
	var cursor := t0_h
	while cursor < t1_h - EPS:
		var offset := cursor + founding_offset_h
		var day_start: float = floor(offset / 24.0) * 24.0 - founding_offset_h
		var segment_end := minf(t1_h, day_start + 24.0)
		var a: float = cursor - day_start
		var b: float = segment_end - day_start
		total += _overlap(a, b, 0.0, night_end) + _overlap(a, b, night_start, 24.0)
		cursor = segment_end
	return clampf(total / (t1_h - t0_h), 0.0, 1.0)


static func _overlap(a: float, b: float, lo: float, hi: float) -> float:
	return maxf(0.0, minf(b, hi) - maxf(a, lo))


# ------------------------------------------------------------------ the math

func work_required(inc: Incident) -> float:
	return work_required_at(inc, inc.tier())


func work_required_at(inc: Incident, tier: int) -> float:
	var row := catalog.type_row(inc.type, inc.subtype)
	return float(row.get("w_base", 0.30)) \
			* (1.0 + float(row.get("w_slope", 0.40)) * float(tier - 1))


func required_rate(inc: Incident) -> float:
	var row := catalog.type_row(inc.type, inc.subtype)
	if String(row.get("suppression_model", "generic")) == "fire":
		return spread.required_rate(inc)
	var slope := float(row.get("hold_tier_slope",
			catalog.global_value("hold_tier_slope", 0.40)))
	return float(row.get("hold_base", 1.0)) * (1.0 + slope * float(inc.tier() - 1))


## Σ over on-scene, capability-matching units, capped at RATE_CAP_MULT ×
## required_rate. Support roles enter as the catalog's `rate_bonus` — the
## police "access/crowd control" 1.15 IS the structure_fire support row, so it
## is applied once, here, and never also as a separate access constant.
##
## This is the SUPPRESSION quantity: only units actually on scene contribute,
## because a truck two minutes out is putting out no fire.
func assigned_effective_rate(inc: Incident) -> float:
	return _effective_rate(inc, [Vehicle.ON_SCENE])


## The DISPATCH quantity: units already en route count, so `unmet_needs` stops
## asking for engines once enough are committed rather than emptying the city
## into one fire while the first truck is still driving.
func committed_effective_rate(inc: Incident) -> float:
	return _effective_rate(inc, [Vehicle.ON_SCENE, Vehicle.RESPONDING])


## One unit's contribution if it answers `role` on this incident.
func unit_contribution(u: Vehicle, inc: Incident, role: String) -> float:
	var row := catalog.type_row(inc.type, inc.subtype)
	if role != String(row.get("primary_role", "")):
		return 0.0
	var water := 1.0
	if String(row.get("suppression_model", "generic")) == "fire":
		water = spread.hydrant_factor(inc.tile)
	return u.rate_for(role) * access_factor(inc) * water


func _effective_rate(inc: Incident, states: Array) -> float:
	var row := catalog.type_row(inc.type, inc.subtype)
	var primary := String(row.get("primary_role", ""))
	var base := 0.0
	var support_bonus := 0.0
	for unit_id in inc.assigned_unit_ids():
		var record: Dictionary = inc.assigned[unit_id]
		if not states.has(String(record.get("state", ""))):
			continue
		var u: Vehicle = fleet.unit(int(unit_id))
		if u == null:
			continue
		var role := String(record.get("role", ""))
		if role == primary:
			base += unit_contribution(u, inc, role)
		else:
			support_bonus += _support_bonus(row, role)
	var effective := base * (1.0 + support_bonus)
	var required := required_rate(inc)
	if required > 0.0:
		effective = minf(effective, catalog.global_value("rate_cap_mult", 3.0) * required)
	return effective


static func _support_bonus(row: Dictionary, role: String) -> float:
	for support in row.get("support_roles", []):
		if String((support as Dictionary).get("role", "")) == role:
			return float((support as Dictionary).get("rate_bonus", 0.0))
	return 0.0


func access_factor(inc: Incident) -> float:
	var quality := travel.access_quality(inc.tile)
	if quality < catalog.global_value("access_degraded_knee", 0.60):
		return catalog.global_value("access_degraded_mult", 0.75)
	return 1.0


func assist_ratio(inc: Incident) -> float:
	var required := required_rate(inc)
	var effective := assigned_effective_rate(inc)
	if required <= 0.0:
		return 1.0 if effective > 0.0 else 0.0
	return effective / required


func escalation_rate(inc: Incident, dark_frac: float) -> float:
	var row := catalog.type_row(inc.type, inc.subtype)
	return float(row.get("esc_base", 0.0)) \
			* (1.0 + catalog.global_value("esc_tier_accel", 0.25) * float(inc.tier() - 1)) \
			* esc_env(inc, dark_frac) \
			* world.difficulty_escalation_mult()


## §2.4. Every DOC 06-AUTHORED factor clamps to [0.4, 3.0]; the doc 07 channel
## is passed through UNCLAMPED — re-clamping a doc 07 value would be doc 06
## quietly retuning doc 07 (C-57's exact failure mode).
func esc_env(inc: Incident, dark_frac: float) -> float:
	var lo := 0.4
	var hi := 3.0
	var clamp_row: Array = catalog.globals.get("esc_env_clamp", [0.4, 3.0])
	if clamp_row.size() == 2:
		lo = float(clamp_row[0])
		hi = float(clamp_row[1])
	match inc.type:
		"crime":
			var d := world.district(inc.district_id)
			var stability := float(inc.context.get("stability", d.get("stability", 1.0)))
			var outage := float(inc.context.get("outage_frac", d.get("outage_frac", 0.0)))
			return clampf((1.0 + catalog.factor("crime", "esc_stability_k", 1.5) * (1.0 - stability))
					* (1.0 + catalog.factor("crime", "esc_dark_k", 0.20) * dark_frac)
					* (1.0 + catalog.factor("crime", "esc_outage_k", 0.35) * outage), lo, hi)
		"structure_fire":
			var wind_term := 1.0 + catalog.factor("fire", "esc_wind_k", 0.010) \
					* maxf(0.0, world.wind_kph() - catalog.factor("fire", "esc_wind_knee_kph", 20.0))
			var doc06_factors := clampf(wind_term * spread.hydrant_penalty(inc.tile), lo, hi)
			var f_wx_esc := world.weather_effect(String(catalog.fire_weather_channels.get(
					"escalation", "fire_escalation_mult")))
			return doc06_factors * f_wx_esc
		"transformer_failure":
			var load_ratio := float(inc.context.get("load_ratio", 1.0))
			return clampf((1.0 + catalog.factor("transformer", "esc_storm_k", 0.30)
					* (1.0 if world.storm_flag() else 0.0))
					* (1.0 + catalog.factor("transformer", "esc_load_k", 0.5)
					* maxf(0.0, load_ratio - 1.0)), lo, hi)
		"water_main_break":
			var pressure := float(inc.context.get("pressure_ratio", 1.0))
			return clampf((1.0 + catalog.factor("water_main", "esc_press_k", 0.4)
					* maxf(0.0, pressure - 1.0))
					* (1.0 + catalog.factor("water_main", "esc_flood_k", 0.5)
					* world.flood_saturation()), lo, hi)
		"traffic_accident":
			var congestion := float(inc.context.get("congestion_index",
					travel.congestion_index(inc.tile)))
			return clampf((1.0 + catalog.factor("traffic", "esc_congestion_k", 0.6) * congestion)
					* (1.0 + catalog.factor("traffic", "esc_dark_k", 0.25) * dark_frac), lo, hi)
		"storm_damage":
			return clampf(1.0 + catalog.factor("storm", "esc_wind_k", 0.015)
					* maxf(0.0, world.wind_kph()
					- catalog.factor("storm", "esc_wind_knee_kph", 40.0)), lo, hi)
	return 1.0


func burn_down_hours(inc: Incident) -> float:
	var row := catalog.type_row(inc.type, inc.subtype)
	var key := String(row.get("burn_down_key", ""))
	if key == "":
		return 0.0
	return catalog.global_value(key, 0.0)


func expected_damage_fraction(inc: Incident) -> float:
	var table: Dictionary = catalog.fire.get("residual_damage", {})
	return clampf(float(table.get("tier_k", 0.10)) * float(inc.tier() - 1)
			+ float(table.get("burn_timer_k", 0.30)) * inc.burn_timer_h,
			0.0, float(table.get("cap", 0.95)))


func _burn_timer_running(inc: Incident, assist: float) -> bool:
	if burn_down_hours(inc) <= 0.0:
		return false
	if bool(inc.context.get("fail_refused", false)) and not world.destroy_allowed():
		return false
	return inc.tier() >= 5 and assist < 0.5


func _accumulate_terminal_timers(inc: Incident, dt_h: float, assist: float) -> void:
	if _burn_timer_running(inc, assist):
		inc.burn_timer_h += dt_h
	var rule := _fail_rule(inc)
	if rule.has("hold_tier") and inc.tier() >= int(rule["hold_tier"]):
		inc.hold_h += dt_h
	elif rule.has("hold_tier"):
		inc.hold_h = 0.0


func _fail_rule(inc: Incident) -> Dictionary:
	var row := catalog.type_row(inc.type, inc.subtype)
	return (row.get("on_fail", {}) as Dictionary).get("condition", {})


func _self_resolve_h(inc: Incident) -> float:
	var row := catalog.type_row(inc.type, inc.subtype)
	if inc.tier() > int(row.get("self_resolve_max_tier", 0)):
		return 0.0
	return float(row.get("self_resolve_h", 0.0))


# ------------------------------------------------------------- state changes

func _on_unit_arrived(unit_id: int) -> void:
	var u: Vehicle = fleet.unit(unit_id)
	if u == null:
		return
	var inc: Incident = incident(u.incident_id)
	if inc == null or inc.is_terminal():
		fleet.release_from_incident(u)
		return
	if not inc.assigned.has(unit_id):
		inc.assigned[unit_id] = {"role": u.role, "state": Vehicle.ON_SCENE,
				"eta_h": now_h, "manual": u.manual_lock}
	else:
		(inc.assigned[unit_id] as Dictionary)["state"] = Vehicle.ON_SCENE
	var row := catalog.type_row(inc.type, inc.subtype)
	if u.role == String(row.get("primary_role", "")):
		if inc.first_onscene_h < 0.0:
			inc.first_onscene_h = now_h
		if inc.status != Incident.STATUS_ACTIVE:
			inc.status = Incident.STATUS_ACTIVE


func _fire_tier_entries() -> void:
	for incident_id in _order:
		var inc: Incident = _active[incident_id]
		if inc.is_terminal():
			continue
		var tier := inc.tier()
		if tier > inc.tier_peak:
			inc.tier_peak = tier
		var row := catalog.type_row(inc.type, inc.subtype)
		var priorities: Array = row.get("notification_priority_by_tier", [3, 3, 2, 1, 1])
		var entries: Dictionary = row.get("on_tier_enter", {})
		for t in range(2, tier + 1):
			if inc.tiers_fired.has(t):
				continue
			inc.tiers_fired.append(t)
			if priorities.size() >= t:
				inc.notification_priority = int(priorities[t - 1])
			_emit("incident_tier_changed", {"incident_id": inc.id, "tier": t,
					"severity": inc.severity, "type": inc.type, "subtype": inc.subtype,
					"at_h": now_h, "notification_priority": inc.notification_priority})
			ops.run(inc, entries.get(str(t), []))


func _check_terminal_conditions() -> void:
	for incident_id in _order.duplicate():
		var inc: Incident = _active.get(incident_id)
		if inc == null or inc.is_terminal():
			continue
		if inc.progress >= 1.0 - EPS and inc.accumulates_progress():
			_resolve(inc)
			continue
		var rule := _fail_rule(inc)
		var burn_limit := burn_down_hours(inc)
		if burn_limit > 0.0 and inc.burn_timer_h >= burn_limit - EPS:
			if bool(inc.context.get("fail_refused", false)) and not world.destroy_allowed():
				continue
			_run_fail(inc)
			continue
		if rule.has("hold_tier") and inc.tier() >= int(rule["hold_tier"]) \
				and inc.hold_h >= float(rule.get("hold_h", 0.0)) - EPS:
			_run_fail(inc)
			continue
		if bool(rule.get("self_resolve", false)) or _self_resolve_h(inc) > 0.0:
			var window := _self_resolve_h(inc)
			if window > 0.0 and inc.status == Incident.STATUS_QUEUED \
					and now_h - inc.created_h >= window - EPS:
				_run_fail(inc)


func _resolve(inc: Incident) -> void:
	var row := catalog.type_row(inc.type, inc.subtype)
	inc.status = Incident.STATUS_RESOLVED
	inc.resolved_h = now_h
	_apply_resolution_effects(inc, row)
	var reward := _pay_reward(inc, row)
	if inc.district_id != "":
		world.apply_district_stability(inc.district_id,
				float(row.get("stability_on_resolve", 0.0)))
	dispatch.record_outcome(inc, Incident.STATUS_RESOLVED,
			float(row.get("target_response_min", 10.0)))
	_emit("incident_resolved", {"incident_id": inc.id, "type": inc.type,
			"subtype": inc.subtype, "tier_peak": inc.tier_peak, "at_h": now_h,
			"response_min": inc.response_minutes(), "reward": reward,
			"target_ref": inc.target_ref.duplicate(true)})


func _apply_resolution_effects(inc: Incident, row: Dictionary) -> void:
	match inc.type:
		"structure_fire":
			var damage := spread.residual_damage_fraction(inc)
			world.suppress_building_fire(inc.target_building_id(), damage)
			world.repair_cost(inc.target_ref, damage)
		"transformer_failure":
			world.power_restore_component(inc.target_component_id())
			_emit("power_restored_by_repair", {"incident_id": inc.id,
					"component": inc.target_component_id()})
		"water_main_break":
			world.water_set_segment_broken(String(inc.target_ref.get("id", "")), 0.0)
			world.water_zone_pressure_delta(String(inc.context.get("zone", "")), 0.0)
		"storm_damage":
			if inc.subtype == "downed_power_line":
				world.power_restore_component(inc.target_component_id())
				_emit("power_restored_by_repair", {"incident_id": inc.id,
						"component": inc.target_component_id()})
			elif inc.subtype == "roof_damage":
				world.repair_cost(inc.target_ref, expected_damage_fraction(inc))
			else:
				world.road_set_edge_speed_mult(inc.tile, 1.0)
		"traffic_accident":
			world.road_set_edge_speed_mult(inc.tile, 1.0)
	if String(row.get("suppression_model", "generic")) != "fire" \
			and inc.target_building_id() != "":
		world.repair_cost(inc.target_ref, expected_damage_fraction(inc))


func _pay_reward(inc: Incident, row: Dictionary) -> int:
	var reward_table: Dictionary = catalog.reward
	var base := float(row.get("reward_base", 0))
	var tier_k := float(reward_table.get("tier_k", 0.35))
	var speed_bonus := 1.0
	var response := inc.response_minutes()
	if response >= 0.0:
		var target := maxf(0.001, float(row.get("target_response_min", 10.0)))
		speed_bonus = clampf(float(reward_table.get("speed_bonus_base", 1.5))
				- float(reward_table.get("speed_bonus_k", 0.5)) * (response / target),
				float(reward_table.get("speed_bonus_min", 0.60)),
				float(reward_table.get("speed_bonus_max", 1.50)))
	var reward := int(round(base * (1.0 + tier_k * float(inc.tier_peak - 1)) * speed_bonus))
	if reward > 0:
		world.credit(reward, "incident_resolved")
	for unit_id in inc.assigned_unit_ids():
		var u: Vehicle = fleet.unit(int(unit_id))
		if u != null:
			var cost := world.vehicle_dispatch_cost(u.type)
			if cost > 0:
				world.debit(cost, "vehicle_dispatch")
	return reward


func _run_fail(inc: Incident) -> void:
	var row := catalog.type_row(inc.type, inc.subtype)
	var fail: Dictionary = row.get("on_fail", {})
	var results := ops.run(inc, fail.get("actions", []))
	var refused := false
	for result in results:
		if String((result as Dictionary).get("result", "")) == CascadeOps.REFUSED:
			refused = true
			break
	if refused:
		# C-47: the incident is NOT resolved and NOT failed — a player arriving
		# to a building still burning is the better drama, and the refusal is
		# visible rather than swallowed.
		inc.context["fail_refused"] = true
		return
	inc.context.erase("fail_refused")
	var terminal := String(fail.get("terminal_status", Incident.STATUS_FAILED))
	inc.status = terminal
	inc.resolved_h = now_h
	dispatch.record_outcome(inc, terminal, float(row.get("target_response_min", 10.0)))
	if terminal == Incident.STATUS_ABANDONED:
		_emit("incident_abandoned", {"incident_id": inc.id, "type": inc.type,
				"subtype": inc.subtype, "tier_peak": inc.tier_peak})
	else:
		_emit("incident_failed", {"incident_id": inc.id, "type": inc.type,
				"subtype": inc.subtype, "tier_peak": inc.tier_peak,
				"target_ref": inc.target_ref.duplicate(true)})


func _release_finished_units() -> void:
	for incident_id in _order.duplicate():
		var inc: Incident = _active.get(incident_id)
		if inc == null or not inc.is_terminal():
			continue
		for unit_id in inc.assigned_unit_ids():
			var u: Vehicle = fleet.unit(int(unit_id))
			if u == null:
				continue
			var refit := u.refit_min > 0 and u.status == Vehicle.ON_SCENE
			fleet.release_from_incident(u, refit)
		inc.assigned.clear()
		_recent.append(inc)
		_active.erase(incident_id)
		_order.erase(incident_id)


func _prune_recent() -> void:
	var keep_h := catalog.global_value("keep_resolved_min", 15.0) / 60.0
	var kept: Array = []
	for inc in _recent:
		if now_h - (inc as Incident).resolved_h <= keep_h:
			kept.append(inc)
	_recent = kept


func _rescore_and_dispatch() -> void:
	var cluster_sizes: Dictionary = {}
	for incident_id in _order:
		var inc: Incident = _active[incident_id]
		if inc.cluster_id != 0:
			cluster_sizes[inc.cluster_id] = int(cluster_sizes.get(inc.cluster_id, 0)) + 1
	var live: Array = []
	for incident_id in _order:
		var inc2: Incident = _active[incident_id]
		if inc2.is_terminal():
			continue
		inc2.priority_cache = dispatch.priority(inc2,
				int(cluster_sizes.get(inc2.cluster_id, 1)), now_h)
		live.append(inc2)
	dispatch.assign_tick(live, now_h)


# ------------------------------------------------------------------- spread

func _roll_spread() -> void:
	var interval := catalog.global_value("spread_roll_interval_h", 1.0 / 12.0)
	if now_h < _spread_next_h - EPS:
		return
	for incident_id in _order.duplicate():
		var inc: Incident = _active.get(incident_id)
		if inc == null or inc.type != "structure_fire" or inc.is_terminal():
			continue
		if catalog.g_stage(inc.tier()) <= 0.0:
			continue
		var assist := assist_ratio(inc)
		for target_id in spread.spread_candidates(inc):
			var rate := spread.spread_rate(inc, String(target_id), assist)
			if rate <= 0.0:
				continue
			var p := FireSpread.interval_probability(rate, interval)
			if rng.stream("incidents").randf() >= p:
				continue
			if inc.cluster_id == 0:
				inc.cluster_id = next_cluster_id
				next_cluster_id += 1
			var target := world.building(String(target_id))
			var child := spawn("structure_fire", "", target.get("tile", inc.tile),
					{"kind": "building", "id": String(target_id)},
					spread.spread_severity_0(inc.tier()),
					{"source": "fire_spread", "source_id": inc.id})
			if child != null:
				child.parent_id = inc.id
				child.cluster_id = inc.cluster_id
				_emit("fire_spread", {"from_incident": inc.id, "to_incident": child.id,
						"target": String(target_id), "cluster_id": inc.cluster_id})
	_spread_next_h = now_h + interval


# --------------------------------------------------------------- generation

func load_damper() -> float:
	var excess := maxi(0, _order.size() - fleet.size())
	var damper := clampf(1.0 - catalog.global_value("load_damper_per_excess", 0.06) * float(excess),
			catalog.global_value("load_damper_floor", 0.25), 1.0)
	if world.is_offline() \
			and offline_hours_elapsed > catalog.global_value("offline_full_fidelity_h", 72.0):
		damper *= catalog.global_value("offline_beyond_damper", 0.5)
	return damper


func _generate(dt_h: float, dark_frac: float) -> void:
	if not generation_enabled:
		return
	var damper := load_damper() * world.difficulty_generation_mult()
	for type_id in catalog.generator_order:
		match String(type_id):
			"crime": _generate_crime(dt_h, dark_frac, damper)
			"structure_fire": _generate_structure_fire(dt_h, damper)
			"transformer_failure": _generate_transformer(dt_h, damper)
			"water_main_break": _generate_water_main(dt_h, damper)
			"traffic_accident": _generate_traffic(dt_h, dark_frac, damper)
			"storm_damage": _generate_storm(dt_h, damper)


func _generate_crime(dt_h: float, dark_frac: float, damper: float) -> void:
	var stream := catalog.stream_for("crime")
	# ONE get_effect read per sub-step: weather is city-wide global (C-59), so
	# the multiplier is identical across every candidate by construction.
	var f_weather := world.weather_effect(catalog.weather_channel_for("crime"))
	var base := float(catalog.generator_base_rates.get("crime_per_1000_pop", 0.012))
	var candidates: Array = []
	var total := 0.0
	for district_id in world.district_ids():
		var d := world.district(String(district_id))
		var population := float(d.get("population", 0))
		if population <= 0.0:
			continue
		var stability := clampf(float(d.get("stability", 1.0)), 0.0, 1.0)
		var outage := clampf(float(d.get("outage_frac", 0.0)), 0.0, 1.0)
		var coverage := clampf(float(d.get("police_coverage", 0.0)), 0.0, 1.0)
		var f_stab := 1.0 + catalog.factor("crime", "k_stability", 3.0) * pow(1.0 - stability, 2)
		var f_dark := 1.0 + catalog.factor("crime", "k_dark", 0.35) * dark_frac \
				* (1.0 + catalog.factor("crime", "k_outage_in_dark", 1.5) * outage)
		var f_police := clampf(catalog.factor("crime", "police_base", 1.4)
				- catalog.factor("crime", "police_slope", 0.6) * coverage,
				catalog.factor("crime", "police_min", 0.5),
				catalog.factor("crime", "police_max", 1.4))
		var lam := base * (population / 1000.0) * dt_h * f_stab * f_dark * f_police * f_weather
		if lam <= 0.0:
			continue
		candidates.append({"id": String(district_id), "lambda": lam})
		total += lam
	var count := _poisson(total * damper, stream)
	for i in count:
		var district_id2 := String(_weighted_pick(candidates, total, stream))
		if district_id2 == "":
			continue
		var building_id := _pick_crime_target(district_id2, stream)
		var tile := Vector2i.ZERO
		var target_ref: Dictionary = {}
		if building_id != "":
			tile = world.building(building_id).get("tile", Vector2i.ZERO)
			target_ref = {"kind": "building", "id": building_id}
		var d2 := world.district(district_id2)
		spawn("crime", "", tile, target_ref, -1.0,
				{"source": "generator", "district": district_id2,
				"stability": d2.get("stability", 1.0)}, district_id2)


## C-44: doc 06 owns generation, doc 02 owns attractiveness. Its per-archetype
## per-level `crime_weight` is adopted verbatim; doc 06 authors no
## attractiveness term of its own. Drawn from the `crime` stream (C-45).
func _pick_crime_target(district_id: String, stream: String) -> String:
	var candidates: Array = []
	var total := 0.0
	for building_id in world.building_ids():
		var b := world.building(String(building_id))
		if String(b.get("district_id", "")) != district_id:
			continue
		if _state_eligible(String(b.get("state", "active"))) <= 0.0:
			continue
		var weight := float(b.get("crime_weight", 0.0))
		if weight <= 0.0:
			continue
		candidates.append({"id": String(building_id), "lambda": weight})
		total += weight
	return String(_weighted_pick(candidates, total, stream))


static func _state_eligible(state: String) -> float:
	return 0.0 if state == "on_fire" or state == "under_construction" \
			or state == "destroyed" or state == "planned" else 1.0


func _generate_structure_fire(dt_h: float, damper: float) -> void:
	var stream := catalog.stream_for("structure_fire")
	var f_weather := world.weather_effect(catalog.weather_channel_for("structure_fire"))
	var base := float(catalog.generator_base_rates.get("structure_fire_global_scalar", 0.40))
	var candidates: Array = []
	var total := 0.0
	for building_id in world.building_ids():
		var id := String(building_id)
		var b := world.building(id)
		var state_mult := world.state_fire_mult(id)
		if state_mult <= 0.0:
			continue
		var p_ignite := float(b.get("fire_ignition_per_hour", 0.0)) \
				* world.fire_condition_mult(id) * state_mult
		if p_ignite <= 0.0:
			continue
		var f_power := 1.0 + catalog.factor("fire", "unpowered_mult", 0.8) \
				* (0.0 if bool(b.get("powered", true)) else 1.0)
		var stability := clampf(float(world.district(String(b.get("district_id", "")))
				.get("stability", 1.0)), 0.0, 1.0)
		var knee := catalog.factor("fire", "arson_stability_knee", 0.35)
		var f_arson := 1.0 + catalog.factor("fire", "arson_k", 2.0) \
				* maxf(0.0, knee - stability) / maxf(0.0001, knee)
		var lam := base * p_ignite * dt_h * f_power * f_weather * f_arson
		if lam <= 0.0:
			continue
		candidates.append({"id": id, "lambda": lam})
		total += lam
	var count := _poisson(total * damper, stream)
	for i in count:
		var picked := String(_weighted_pick(candidates, total, stream))
		if picked == "":
			continue
		var b2 := world.building(picked)
		spawn("structure_fire", "", b2.get("tile", Vector2i.ZERO),
				{"kind": "building", "id": picked}, -1.0,
				{"source": "generator", "archetype": b2.get("archetype", ""),
				"level": b2.get("level", 1)})


func _generate_transformer(dt_h: float, damper: float) -> void:
	var stream := catalog.stream_for("transformer_failure")
	var f_weather := world.weather_effect(catalog.weather_channel_for("transformer_failure"))
	var base := float(catalog.generator_base_rates.get("transformer_per_node", 0.0012))
	var clamp_row: Array = catalog.factors.get("transformer", {}).get("load_clamp", [0.20, 1.60])
	var candidates: Array = []
	var total := 0.0
	for node in world.power_transformers():
		var row: Dictionary = node
		var load_ratio := clampf(float(row.get("load_ratio", 0.0)),
				float(clamp_row[0]), float(clamp_row[1]))
		var f_load := pow(load_ratio / maxf(0.0001,
				catalog.factor("transformer", "load_ref", 0.70)),
				catalog.factor("transformer", "load_exp", 3.0))
		var f_cond := pow(2.0 - clampf(float(row.get("condition", 1.0)), 0.0, 1.0), 2)
		var f_temp := 1.0 + catalog.factor("transformer", "temp_k", 0.9) \
				* maxf(0.0, (float(row.get("temp_c", 25.0))
				- catalog.factor("transformer", "temp_knee_c", 65.0))
				/ maxf(0.0001, catalog.factor("transformer", "temp_span_c", 35.0)))
		var lam := base * dt_h * f_load * f_cond * f_temp * f_weather
		if lam <= 0.0:
			continue
		candidates.append({"id": String(row.get("id", "")), "lambda": lam, "row": row})
		total += lam
	var count := _poisson(total * damper, stream)
	for i in count:
		var picked := _weighted_pick_row(candidates, total, stream)
		if picked.is_empty():
			continue
		spawn_component_incident(String(picked.get("id", "")), picked.get("row", {}), -1.0,
				{"source": "generator"})


func _generate_water_main(dt_h: float, damper: float) -> void:
	var stream := catalog.stream_for("water_main_break")
	var base := float(catalog.generator_base_rates.get("water_main_per_km", 0.0022))
	var freeze_enabled := world.water_freeze_enabled()
	var candidates: Array = []
	var total := 0.0
	for segment in world.water_mains():
		var row: Dictionary = segment
		var condition := clampf(float(row.get("condition", 1.0)), 0.0, 1.0)
		var pressure := float(row.get("pressure_ratio", 1.0))
		var utilization := float(row.get("utilization", 0.0))
		var f_press := 1.0 + catalog.factor("water_main", "press_k", 1.5) \
				* maxf(0.0, pressure - catalog.factor("water_main", "press_knee", 1.05))
		# Doc 05 §2.9's curves, consumed verbatim (C-46).
		var cond_mult := 1.0 + 6.0 * pow(1.0 - condition, 2)
		var load_mult := 1.0 + 1.5 * maxf(0.0, utilization - 0.85) / 0.15
		var f_ground := 1.0 + catalog.factor("water_main", "ground_k", 0.5) * world.flood_saturation()
		var mechanical := base * float(row.get("length_km", 0.0)) * f_press * cond_mult \
				* load_mult * f_ground
		var freeze := 0.0
		if freeze_enabled:
			freeze = catalog.factor("water_main", "freeze_break_base", 0.0020) \
					* float(row.get("freeze_stress", 0.0)) \
					* (catalog.factor("water_main", "freeze_cond_offset", 1.2) - condition)
		var lam := dt_h * (mechanical + freeze)
		if lam <= 0.0:
			continue
		candidates.append({"id": String(row.get("id", "")), "lambda": lam, "row": row})
		total += lam
	var count := _poisson(total * damper, stream)
	for i in count:
		var picked := _weighted_pick_row(candidates, total, stream)
		if picked.is_empty():
			continue
		var row2: Dictionary = picked.get("row", {})
		var inc := spawn("water_main_break", "", row2.get("tile", Vector2i.ZERO),
				{"kind": "water_segment", "id": String(picked.get("id", ""))}, -1.0,
				{"source": "generator"})
		if inc != null:
			inc.context["zone"] = String(row2.get("zone", ""))
			inc.context["pressure_ratio"] = float(row2.get("pressure_ratio", 1.0))
			world.water_set_segment_broken(String(picked.get("id", "")), inc.severity)


func _generate_traffic(dt_h: float, dark_frac: float, damper: float) -> void:
	var stream := catalog.stream_for("traffic_accident")
	var f_weather := world.weather_effect(catalog.weather_channel_for("traffic_accident"))
	var base := float(catalog.generator_base_rates.get("traffic_per_intersection", 0.0020))
	var clamp_row: Array = catalog.factors.get("traffic", {}).get("flow_clamp", [0.05, 2.0])
	var candidates: Array = []
	var total := 0.0
	for node in world.road_intersections():
		var row: Dictionary = node
		var congestion := clampf(float(row.get("congestion_index", 0.0)),
				float(clamp_row[0]), float(clamp_row[1]))
		var f_flow := pow(congestion, catalog.factor("traffic", "flow_exp", 1.5))
		var f_signal := catalog.factor("traffic", "unsignalised", 1.6)
		if bool(row.get("signalised", false)):
			f_signal = catalog.factor("traffic", "signal_powered", 1.0) \
					if bool(row.get("signal_powered", true)) \
					else catalog.factor("traffic", "signal_unpowered", 3.0)
		var f_dark := 1.0 + catalog.factor("traffic", "dark_k", 0.25) * dark_frac
		# Doc 10 owns condition_hazard_mult; doc 06 does not rescale it (C-48).
		var f_road := float(row.get("condition_hazard_mult",
				travel.condition_hazard_mult(row.get("tile", Vector2i.ZERO))))
		var lam := base * dt_h * f_flow * f_signal * f_weather * f_dark * f_road
		if lam <= 0.0:
			continue
		candidates.append({"id": String(row.get("id", "")), "lambda": lam, "row": row})
		total += lam
	var count := _poisson(total * damper, stream)
	for i in count:
		var picked := _weighted_pick_row(candidates, total, stream)
		if picked.is_empty():
			continue
		var row2: Dictionary = picked.get("row", {})
		var inc := spawn("traffic_accident", "", row2.get("tile", Vector2i.ZERO),
				{"kind": "intersection", "id": String(picked.get("id", ""))}, -1.0,
				{"source": "generator"})
		if inc != null:
			inc.context["congestion_index"] = float(row2.get("congestion_index", 0.0))
			inc.context["signal_powered"] = bool(row2.get("signal_powered", true))


func _generate_storm(dt_h: float, damper: float) -> void:
	var stream := catalog.stream_for("storm_damage")
	var cell := world.storm_cell()
	if not bool(cell.get("active", false)):
		return
	var base := float(catalog.generator_base_rates.get("storm_per_exposed_asset", 0.0149))
	var wind := world.wind_kph()
	var knee := catalog.factor("storm", "wind_knee_kph", 40.0)
	var span := maxf(0.0001, catalog.factor("storm", "wind_span_kph", 30.0))
	var wind_factor := pow(maxf(0.0, (wind - knee) / span),
			catalog.factor("storm", "wind_exp", 2.0))
	if wind_factor <= 0.0:
		return
	var cell_tile: Vector2i = cell.get("tile", Vector2i.ZERO)
	var cell_radius := float(cell.get("radius_tiles", 0.0))
	var candidates: Array = []
	var total := 0.0
	for asset in world.power_exposed_components():
		var row: Dictionary = asset
		if bool(row.get("underground", false)):
			continue
		var tile: Vector2i = row.get("tile", Vector2i.ZERO)
		if Vector2(float(tile.x - cell_tile.x), float(tile.y - cell_tile.y)).length() > cell_radius:
			continue
		var lam := base * dt_h * wind_factor \
				* catalog.exposure_class(String(row.get("exposure_class", "overhead_span"))) \
				* (2.0 - clampf(float(row.get("condition", 1.0)), 0.0, 1.0))
		if lam <= 0.0:
			continue
		candidates.append({"id": String(row.get("id", "")), "lambda": lam, "row": row})
		total += lam
	var count := _poisson(total * damper, stream)
	for i in count:
		var picked := _weighted_pick_row(candidates, total, stream)
		if picked.is_empty():
			continue
		var subtype := _pick_storm_subtype(stream)
		var row2: Dictionary = picked.get("row", {})
		spawn("storm_damage", subtype, row2.get("tile", Vector2i.ZERO),
				{"kind": "power_component", "id": String(picked.get("id", ""))}, -1.0,
				{"source": "generator", "wind_kph": wind})


func _pick_storm_subtype(stream: String) -> String:
	var weights: Dictionary = catalog.storm_subtype_weights()
	var keys := weights.keys()
	keys.sort()
	var total := 0.0
	for key in keys:
		total += float(weights[key])
	if total <= 0.0:
		return ""
	var roll := rng.stream(stream).randf() * total
	var cumulative := 0.0
	for key in keys:
		cumulative += float(weights[key])
		if roll < cumulative:
			return String(key)
	return String(keys[keys.size() - 1])


## Inverse-transform Poisson (Knuth for λ < 30); a two-draw normal
## approximation above that keeps RNG consumption bounded for the offline path.
func _poisson(lam: float, stream: String) -> int:
	if lam <= 0.0:
		return 0
	var generator := rng.stream(stream)
	if lam < 30.0:
		var limit := exp(-lam)
		var k := 0
		var p := 1.0
		while true:
			k += 1
			p *= generator.randf()
			if p <= limit:
				break
			if k > 10000:
				break
		return k - 1
	var u1 := maxf(1e-12, generator.randf())
	var u2 := generator.randf()
	var normal := sqrt(-2.0 * log(u1)) * cos(TAU * u2)
	return maxi(0, int(round(lam + sqrt(lam) * normal)))


func _weighted_pick(candidates: Array, total: float, stream: String) -> String:
	var picked := _weighted_pick_row(candidates, total, stream)
	return String(picked.get("id", ""))


func _weighted_pick_row(candidates: Array, total: float, stream: String) -> Dictionary:
	if candidates.is_empty() or total <= 0.0:
		return {}
	var roll := rng.stream(stream).randf() * total
	var cumulative := 0.0
	for candidate in candidates:
		cumulative += float((candidate as Dictionary)["lambda"])
		if roll < cumulative:
			return candidate
	return candidates[candidates.size() - 1]


func roll_unit(stream: String) -> float:
	return rng.stream(stream).randf()


# ------------------------------------------------------------------ spawning

## The one place an Incident is born. `severity_0 < 0` ⇒ roll it from the
## type's own stream with the §2.3 context bonus; ≥ 0 ⇒ scripted, no draw.
func spawn(type_id: String, subtype: String, tile: Vector2i, target_ref: Dictionary,
		severity_0: float = -1.0, cause: Dictionary = {},
		district_id: String = "") -> Incident:
	if not catalog.has_type(type_id):
		return null
	var inc := Incident.new(next_id, type_id, subtype)
	next_id += 1
	inc.tile = tile
	inc.target_ref = target_ref.duplicate(true)
	inc.created_h = now_h
	inc.cause = cause.duplicate(true)
	inc.district_id = district_id if district_id != "" else _district_for(inc)
	_seed_context(inc)
	if severity_0 >= 0.0:
		inc.severity = clampf(severity_0, catalog.global_value("severity_min", 1.0),
				catalog.global_value("severity_spawn_max", 4.99))
	else:
		inc.severity = _roll_severity(inc)
	inc.tier_peak = inc.tier()
	var row := catalog.type_row(type_id, subtype)
	var priorities: Array = row.get("notification_priority_by_tier", [3, 3, 2, 1, 1])
	var index := clampi(inc.tier(), 1, priorities.size()) - 1
	inc.notification_priority = 3 if priorities.is_empty() else int(priorities[index])
	inc.status = Incident.STATUS_QUEUED
	if type_id == "structure_fire" and inc.target_building_id() != "":
		world.ignite_building(inc.target_building_id())
	_active[inc.id] = inc
	_order.append(inc.id)
	_order.sort()
	_emit("incident_created", {"incident_id": inc.id, "type": type_id, "subtype": subtype,
			"tile": [tile.x, tile.y], "severity": inc.severity, "tier": inc.tier(),
			"district_id": inc.district_id, "target_ref": inc.target_ref.duplicate(true),
			"cause": inc.cause.duplicate(true), "at_h": now_h,
			"notification_priority": inc.notification_priority})
	return inc


func _district_for(inc: Incident) -> String:
	var building_id := inc.target_building_id()
	if building_id != "":
		var b := world.building(building_id)
		if b.has("district_id"):
			return String(b["district_id"])
	return world.district_of_tile(inc.tile)


## Cache the cause-block inputs at spawn so the UI can say exactly why this
## happened (Core Rule 12) and so escalation does not re-query a moving world.
func _seed_context(inc: Incident) -> void:
	match inc.type:
		"structure_fire":
			var b := world.building(inc.target_building_id())
			inc.context["fire_load"] = float(b.get("fire_load",
					catalog.fire.get("fire_load_anchor", 20)))
			inc.context["level"] = int(b.get("level", 1))
			inc.context["occupants"] = float(b.get("occupants", 0))
			inc.context["archetype"] = String(b.get("archetype", ""))
		"transformer_failure":
			var component := world.power_component(inc.target_component_id())
			if not component.is_empty():
				inc.context["load_ratio"] = float(component.get("load_ratio", 1.0))
				inc.context["condition"] = float(component.get("condition", 1.0))
				inc.context["redundancy"] = bool(component.get("redundancy", false))
				inc.context["customers_downstream"] = int(component.get("customers_downstream", 0))
				inc.context["critical_downstream"] = bool(component.get("critical_downstream", false))
		"crime":
			var d := world.district(inc.district_id)
			inc.context["stability"] = float(d.get("stability", 1.0))
			inc.context["outage_frac"] = float(d.get("outage_frac", 0.0))
			inc.context["district_pop"] = float(d.get("population", 0))


func _roll_severity(inc: Incident) -> float:
	var row := catalog.type_row(inc.type, inc.subtype)
	var stream := catalog.stream_for(inc.type)
	var roll := rng.stream(stream).randf()
	var severity := 1.0 + float(row.get("sev_bias", 0.0)) \
			+ roll * float(row.get("sev_spread", 0.0)) + _context_bonus(inc)
	return clampf(severity, catalog.global_value("severity_min", 1.0),
			catalog.global_value("severity_spawn_max", 4.99))


func _context_bonus(inc: Incident) -> float:
	match inc.type:
		"crime":
			var stability := clampf(float(inc.context.get("stability", 1.0)), 0.0, 1.0)
			var knee := catalog.factor("crime", "sev_stability_knee", 0.5)
			var bonus := catalog.factor("crime", "sev_stability_k", 1.2) \
					* maxf(0.0, knee - stability) / maxf(0.0001, knee)
			if float(inc.context.get("outage_frac", 0.0)) > 0.0:
				bonus += catalog.factor("crime", "sev_unpowered_bonus", 0.3)
			return bonus
		"structure_fire":
			var level := int(inc.context.get("level", 1))
			var bonus2 := catalog.factor("fire", "sev_level_k", 0.15) * float(level - 1)
			if world.hydrant_pressure_ratio(inc.tile) \
					< catalog.factor("fire", "sev_hydrant_knee", 0.5):
				bonus2 += catalog.factor("fire", "sev_hydrant_bonus", 0.4)
			return bonus2
		"transformer_failure":
			var load_ratio := float(inc.context.get("load_ratio", 1.0))
			var bonus3 := catalog.factor("transformer", "sev_load_k", 0.8) \
					* maxf(0.0, load_ratio - 1.0)
			if not bool(inc.context.get("redundancy", false)):
				bonus3 += catalog.factor("transformer", "sev_no_redundancy_bonus", 0.5)
			return bonus3
		"water_main_break":
			return catalog.factor("water_main", "sev_press_k", 0.6) \
					* maxf(0.0, float(inc.context.get("pressure_ratio", 1.0))
					- catalog.factor("water_main", "sev_press_knee", 1.15))
		"traffic_accident":
			var bonus4 := 0.0
			if not bool(inc.context.get("signal_powered", true)):
				bonus4 += catalog.factor("traffic", "sev_unpowered_bonus", 0.5)
			if bool(inc.context.get("injury", false)):
				bonus4 += catalog.factor("traffic", "sev_injury_bonus", 0.4)
			return bonus4
		"storm_damage":
			var knee2 := catalog.factor("storm", "sev_wind_knee_kph", 60.0)
			var span := maxf(0.0001, catalog.factor("storm", "sev_wind_span_kph", 40.0))
			return catalog.factor("storm", "sev_wind_k", 0.5) \
					* clampf((world.wind_kph() - knee2) / span, 0.0, 1.0)
	return 0.0


# ------------------------------------------------ doc 04 events → incidents

## Doc 04 fails the component; doc 06 turns that into a REPAIRABLE incident.
## This is the whole tutorial arc's first link.
func on_power_event(event: Dictionary) -> Incident:
	var event_type := String(event.get("type", ""))
	if event_type != "PowerComponentFailed" and event_type != "AutoRecloseLockout":
		return null
	var component_id := String(event.get("component", ""))
	if component_id == "":
		return null
	if incident_for_component(component_id) != null:
		return null  # one live incident per component
	var component := world.power_component(component_id)
	return spawn_component_incident(component_id, component, -1.0, {
		"source": "power", "cause": String(event.get("cause", event_type)),
		"event": event_type,
	})


func spawn_component_incident(component_id: String, component: Dictionary,
		severity_0: float, cause: Dictionary) -> Incident:
	var kind := String(component.get("kind", "transformer"))
	var row := catalog.power_event_row(kind)
	if row.is_empty():
		row = catalog.power_event_row("transformer")
	var tile: Vector2i = component.get("tile", Vector2i.ZERO)
	var merged_cause := cause.duplicate(true)
	merged_cause["component"] = component_id
	merged_cause["load_ratio"] = component.get("load_ratio", 0.0)
	merged_cause["condition"] = component.get("condition", 1.0)
	var inc := spawn(String(row.get("type", "transformer_failure")),
			String(row.get("subtype", "")), tile,
			{"kind": "power_component", "id": component_id}, severity_0, merged_cause)
	if inc != null:
		inc.context["load_ratio"] = float(component.get("load_ratio", 1.0))
		inc.context["customers_downstream"] = int(component.get("customers_downstream",
				world.power_customers_downstream(component_id)))
		inc.context["critical_downstream"] = bool(component.get("critical_downstream", false))
	return inc


func incident_for_component(component_id: String) -> Incident:
	for incident_id in _order:
		var inc: Incident = _active[incident_id]
		if inc.target_component_id() == component_id and not inc.is_terminal():
			return inc
	return null


## The doc 12 / doc 07 scripted-incident hook. Resolves a starter-city tag to a
## live entity, takes the component out, and files the repairable incident.
## `TUT_TRANSFORMER_FAIL` is the tag Milestone 3 drives.
func spawn_scripted_from_tag(loader: StarterCityLoader, tag_group: String = "transformer_fail",
		severity_0: float = -1.0) -> Incident:
	var recipe: Dictionary = catalog.tutorial.get(tag_group, {})
	if recipe.is_empty():
		return null
	var entry: Dictionary = {}
	for tag in recipe.get("tags", []):
		entry = loader.resolve_tag(String(tag))
		if not entry.is_empty():
			break
	if entry.is_empty():
		return null
	var component_id := String(entry.get("id", ""))
	if component_id == "":
		return null
	var severity := severity_0 if severity_0 >= 0.0 else float(recipe.get("severity_0", -1.0))
	return spawn_scripted_component_failure(component_id, severity,
			recipe.get("cause", {"source": "scripted"}))


func spawn_scripted_component_failure(component_id: String, severity_0: float,
		cause: Dictionary = {}) -> Incident:
	if not world.power_fail_component(component_id, "SCRIPTED"):
		return null
	var component := world.power_component(component_id)
	var existing := incident_for_component(component_id)
	if existing != null:
		return existing
	return spawn_component_incident(component_id, component, severity_0, cause)


# ------------------------------------------------------------------ queries

func incident(incident_id: int) -> Incident:
	return _active.get(incident_id, null)


func incident_ids() -> Array:
	return _order.duplicate()


func active_count() -> int:
	return _order.size()


func recent() -> Array:
	return _recent.duplicate()


func active_on_building(building_id: String) -> Array:
	var out: Array = []
	for incident_id in _order:
		var inc: Incident = _active[incident_id]
		if inc.target_building_id() == building_id and not inc.is_terminal():
			out.append(incident_id)
	return out


## Doc 12's incident drawer (§40.2): `escalation_eta_min` is the readable clock.
func snapshot() -> Array:
	var dark := _dark_fraction(now_h, now_h + 1.0 / 3600.0)
	var out: Array = []
	for incident_id in _order:
		var inc: Incident = _active[incident_id]
		var assist := assist_ratio(inc)
		var d_severity := escalation_rate(inc, dark) * maxf(0.0, 1.0 - assist)
		var eta_min := -1.0
		if d_severity > 0.0 and inc.tier() < 5:
			eta_min = (float(floor(inc.severity)) + 1.0 - inc.severity) / d_severity * 60.0
		out.append({
			"id": inc.id, "type": inc.type, "subtype": inc.subtype,
			"tier": inc.tier(), "severity": inc.severity, "status": inc.status,
			"pos": [inc.tile.x, inc.tile.y], "district_id": inc.district_id,
			"wait_min": inc.wait_hours(now_h) * 60.0,
			"assigned": inc.assigned_unit_ids(),
			"assist_ratio": assist, "progress": inc.progress,
			"escalation_eta_min": eta_min, "priority": inc.priority_cache,
			"pinned": inc.pinned, "seen": inc.seen, "unreachable": inc.unreachable,
			"notification_priority": inc.notification_priority,
		})
	return out


func vehicle_states() -> Array:
	return fleet.vehicle_states()


func emit_event(event_type: String, payload: Dictionary) -> void:
	_emit(event_type, payload)


func _emit(event_type: String, payload: Dictionary) -> void:
	var event := payload.duplicate()
	event["type"] = event_type
	_events.append(event)


## Doc 06's events, drained by the coordinator into the shared bus. Fleet and
## dispatch events are folded in here so there is one drain point.
func drain_events() -> Array:
	var out: Array = []
	out.append_array(_events)
	out.append_array(fleet.drain_events())
	out.append_array(dispatch.drain_events())
	_events = []
	return out


# ------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	return {"incidents": serialize_incidents(), "fleet": fleet.serialize(),
			"dispatch": dispatch.serialize()}


func serialize_incidents() -> Dictionary:
	var active: Array = []
	for incident_id in _order:
		active.append((_active[incident_id] as Incident).serialize())
	var recent_rows: Array = []
	for inc in _recent:
		recent_rows.append((inc as Incident).serialize())
	return {
		"section_version": 1, "next_id": next_id, "next_cluster_id": next_cluster_id,
		"now_h": now_h, "spread_next_h": _spread_next_h,
		"offline_hours_elapsed": offline_hours_elapsed,
		"active": active, "recent": recent_rows,
		"gen_accumulators": {},
	}


func deserialize(data: Dictionary) -> void:
	deserialize_incidents(data.get("incidents", {}))
	fleet.deserialize(data.get("fleet", {}))
	dispatch.deserialize(data.get("dispatch", {}))


func deserialize_incidents(data: Dictionary) -> void:
	_active.clear()
	_order.clear()
	_recent.clear()
	for row in data.get("active", []):
		var inc := Incident.deserialize(row)
		_active[inc.id] = inc
		_order.append(inc.id)
	_order.sort()
	for row in data.get("recent", []):
		_recent.append(Incident.deserialize(row))
	next_id = int(data.get("next_id", 1))
	next_cluster_id = int(data.get("next_cluster_id", 1))
	now_h = float(data.get("now_h", 0.0))
	_spread_next_h = float(data.get("spread_next_h", now_h))
	offline_hours_elapsed = float(data.get("offline_hours_elapsed", 0.0))
	fleet.now_h = now_h
