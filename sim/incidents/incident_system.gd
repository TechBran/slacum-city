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
## Sub-steps integrated since boot. Pure observability for tools/profile_sim.gd
## — nothing reads it, it is not serialized and it is not hashed — but the cost
## of this system is `substeps × roster`, and a perf claim about it that cannot
## quote the first factor is a guess.
var substeps_taken: int = 0
var offline_hours_elapsed: float = 0.0

## Scratch for `_generate_traffic`'s candidate weights, GROWN AND NEVER SHRUNK.
##
## Alone among the six generators, the traffic scan has a candidate set the size
## of the road GRAPH — the starter city hands it 389 junctions, and doc 09 stamps
## that grid before the player has built anything, so it is large from game-hour
## zero. It ran on every integrator sub-step, and the integrator takes up to
## `max_substeps_per_hour` (64) of them in an hour with live incidents: connecting
## D-18's candidate source took the starter city's whole coarse step from
## **7.99 ms to 22.90 ms**. Two caches bought it back to **10.46 ms** — doc 10's
## per-roster-epoch row cache (`RoadNetwork.intersections()`) and the per-node
## weight split above, of which this buffer is the storage. Not sim state: it is
## written and read inside this file, keyed by a roster epoch, and nothing
## outside ever sees it. (The other five scans are per-district, per-building or
## per-node and stay two orders of magnitude smaller — see open question 5.)
var _traffic_scratch: Array = []
var _traffic_used: int = 0
var _traffic_weight_total: float = -1.0   # < 0 ⇒ never built
var _traffic_epoch: int = -1

## `access_factor`'s memo: tile -> factor, valid for one `travel.access_epoch()`.
## Derived, never serialized, never hashed — see `access_factor` for why it
## exists and why the memo is exact rather than approximate.
var _access_cache: Dictionary = {}
var _access_epoch: int = -1

var _active: Dictionary = {}  # id -> Incident
var _order: Array = []  # ascending incident ids
var _recent: Array = []  # terminal incidents, kept KEEP_RESOLVED_MIN game-min
var _events: Array = []
var _spread_next_h: float = 0.0
## §2.13(b)'s edge detector. Derived from the roster, never serialized — see
## `_update_saturation_latch`.
var _saturated_latch: bool = false


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
	substeps_taken += 1
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
	_update_saturation_latch()


# ------------------------------------------------------------ discontinuities

## Duration (game-hours) to the next discontinuity, or INF.
func _next_discontinuity_h() -> float:
	var best := INF
	var fleet_next := fleet.next_event_h()
	if fleet_next < INF:
		best = minf(best, maxf(0.0, fleet_next - now_h))
	var dark := _dark_fraction(now_h, now_h + 1.0 / 3600.0)
	var abandon_h := unanswered_abandon_h()
	var fire_is_live := false
	for incident_id in _order:
		var inc: Incident = _active[incident_id]
		if inc.is_terminal():
			continue
		if inc.type == "structure_fire":
			fire_is_live = true
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
		# RR-26's abandonment boundary. A terminal condition that a coarse hour
		# could step over is a terminal condition the online and offline paths
		# would disagree about, so it is a discontinuity like every other one.
		if abandon_h > 0.0 and _unanswered_clock_running(inc):
			best = minf(best, maxf(0.0, abandon_h - inc.unanswered_h))
	# THE FIRE-SPREAD BREAKPOINT, AND WHY IT IS CONDITIONAL (doc 91 D-15, taken
	# Wave 8). `_roll_spread` walks the live roster looking for `structure_fire`
	# on a 1/12-game-hour grid; splitting the integrator there when the roster
	# holds no fire buys a roll that provably cannot do anything, and it was what
	# set the sub-step count — the single largest term in the coarse step.
	#
	# **It is not a fidelity trade, because `_roll_spread` re-anchors its own
	# grid.** The roll is a HAZARD RATE over a fixed `interval`, and the function
	# that consumes it sets `_spread_next_h = now_h + interval` every time it
	# runs — including the runs that find nothing to roll for. So while no fire
	# is live the grid simply rides along at the end of whatever sub-step the
	# other discontinuities produced, and the instant one ignites the NEXT roll
	# still lands a full `interval` after it. A fire never gets an extra roll,
	# never waits longer for its first one, and the `exp(-rate)` identity that
	# makes fine and coarse steps agree (doc 06 §2.8) is untouched.
	#
	# What DOES change is RNG consumption on quiet hours: the generators are
	# sampled once per sub-step, so fewer sub-steps means fewer, larger Poisson
	# draws over the same λ. Same process, different draw sequence — which is a
	# save-contract break, and why `SAVE_SECTION_VERSION` is 2.
	if fire_is_live:
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
	# Unrolled rather than iterating a literal array: this runs once per
	# integrator sub-step and the literal was a fresh Array every time.
	var best := INF
	best = _closer(best, night_end - hour)
	best = _closer(best, night_start - hour)
	best = _closer(best, night_end + 24.0 - hour)
	best = _closer(best, night_start + 24.0 - hour)
	return best


static func _closer(best: float, delta: float) -> float:
	return minf(best, delta) if delta > EPS else best


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


## §2.6's `access_factor`: doc 10's `access_quality` knee, and nothing else.
##
## **Why the police term is not here** *(measured, Wave 5)*. Doc 06 §2.6 writes
## `access_factor` as `road_knee × (1.15 if a police unit is on scene)`, and
## `globals.access_police_bonus` carries that 1.15 — but the same 15 % is ALSO
## `types.<t>.support_roles[police].rate_bonus = 0.15`, which `_effective_rate`
## already bills through `(1 + support_bonus)`. The doc states one effect twice
## and the shipped path implements the support-role half; wiring the global as a
## second multiplier charges it twice.
##
## It is not a harmless duplicate either. Wired as
## `× (1 + 0.15 · coverage_police(tile))` and measured on the doc 92 rig at seed
## 1337 / 21 game-days, balance **gate 04 inverts**: maintained $61,843 against
## neglected $71,644, where the same runs without it read $69,876 / $59,959. A
## blanket suppression buff pays the agent that never repairs the most, because
## fires it would have let burn are put out before they cost it anything.
##
## Doc 02's `coverage_police` is therefore consumed where doc 06 §2.6 actually
## reads it — `factors.crime.police_base / police_slope` in `_generate_crime`,
## through the district scalar, which is now the real C-51 number instead of the
## 0.5 stub. `globals.access_police_bonus` stays unread and is reported as a
## data/doc redundancy rather than being quietly spent.
## **Memoised per tile, keyed on doc 10's `access_epoch()`.** Not an
## optimisation of the formula — of its CALL COUNT. `_effective_rate` reads this
## for every unit on every incident, `coverage` and `_representative_contribution`
## read it again, and all of that runs on every integrator sub-step; doc 10's
## answer is a ring search plus an avenue-gate rect scan, roughly 250 grid
## lookups. A city in collapse — forty open incidents, six hundred sub-steps a
## game-day — was paying that a quarter of a million times a game-day.
##
## The memo is EXACT, not approximate: doc 10 publishes `access_epoch()` as
## "changes whenever `access_quality` could answer differently and never
## otherwise", so a hit is the value a call would have returned. It is derived
## state — not captured, not saved, not hashed — and it repopulates from the
## same inputs after a load, so it cannot move a state hash.
func access_factor(inc: Incident) -> float:
	var epoch := travel.access_epoch()
	if epoch != _access_epoch:
		_access_epoch = epoch
		_access_cache.clear()
	var cached: Variant = _access_cache.get(inc.tile)
	if cached != null:
		return float(cached)
	var quality := travel.access_quality(inc.tile)
	var factor := catalog.global_value("access_degraded_mult", 0.75) \
			if quality < catalog.global_value("access_degraded_knee", 0.60) else 1.0
	_access_cache[inc.tile] = factor
	return factor


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
			# NOT `context.get(key, travel.congestion_index(tile))`: GDScript builds
			# the default BEFORE the lookup, so the road query ran on every
			# `escalation_rate` — twice per incident per integrator sub-step, from
			# `_integrate` and again from `_next_discontinuity_h` — for a value the
			# context already held. `_refresh_traffic_weights` carries the same note
			# about the same shape (C-48); this is the second instance of it, found
			# in the Wave-13 saturation profile where a roster pinned at the ceiling
			# made it visible.
			var congestion := float(inc.context["congestion_index"]) \
					if inc.context.has("congestion_index") \
					else travel.congestion_index(inc.tile)
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
	# Doc 06 §2.10's terminal rule (RR-26). The clock runs only while NOTHING is
	# committed to the incident — no unit assigned, none en route, none on scene
	# — and is zeroed the instant one is. It therefore measures the thing the
	# rule is about (*nobody is coming*) rather than the thing it is not
	# (*this is taking a while*).
	if _unanswered_clock_running(inc):
		inc.unanswered_h += dt_h
	else:
		inc.unanswered_h = 0.0


## The clock is paused, not merely reset, while a `fail_refused` incident waits
## for the player to come back (C-47). The refusal exists so the returning player
## finds the building still burning; abandoning it in their absence would delete
## exactly the drama the refusal was written to keep.
func _unanswered_clock_running(inc: Incident) -> bool:
	if not inc.assigned.is_empty():
		return false
	if bool(inc.context.get("fail_refused", false)):
		return false
	return not inc.is_terminal()


## Game-hours of continuous non-answer after which an incident is ABANDONED.
## Zero or absent disables the rule entirely, which is what every pre-RR-26 save
## and every test fixture with no `assignment` block gets.
func unanswered_abandon_h() -> float:
	return float(catalog.assignment.get("unanswered_abandon_h", 0.0))


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
					"severity": inc.severity, "incident_type": inc.type, "subtype": inc.subtype,
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
				continue
		# **Doc 06 §2.10's terminal rule for an incident no unit can answer**
		# (RR-26). It is checked LAST on purpose: every authored `on_fail` above
		# fires strictly sooner than this clock on every type that has one, so
		# reaching here means the catalog wrote no ending for this incident and
		# the city wrote none either.
		var abandon_h := unanswered_abandon_h()
		if abandon_h > 0.0 and inc.unanswered_h >= abandon_h - EPS:
			_abandon_unanswered(inc)


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
	_emit("incident_resolved", {"incident_id": inc.id, "incident_type": inc.type,
			"subtype": inc.subtype, "tier_peak": inc.tier_peak, "at_h": now_h,
			"response_min": inc.response_minutes(), "reward": reward,
			# RR-77: the payout and the loss it prevented travel together, so the
			# moral-hazard ratio is a thing a reader — and balance gate 31 — can
			# check on a live city instead of on a spreadsheet. `-1` means doc 03
			# prices no capital for this target's asset class.
			"prevented_loss": world.prevented_loss_value(inc.target_ref,
					_residual_damage_fraction(inc, row)),
			"manual": inc.manual_requested,
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
			var segment := String(inc.target_ref.get("id", ""))
			# Order matters: the zone/segment penalty is released first, because
			# repairing the segment is also what clears doc 05's own hold on it.
			world.water_zone_pressure_delta(String(inc.context.get("zone", "")),
					0.0, segment)
			world.water_set_segment_broken(segment, 0.0)
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


## **The payout, and the two things doc 06 no longer decides about it**
## *(report 98 RR-77).*
##
## This method still owns the SHAPE — `(1 + tier_k·(tier_peak − 1)) ×
## speed_bonus`, doc 06 §2.7's own two questions: *how much more is a tier-3
## worth than a tier-1*, and *how much is a fast answer worth*. It no longer
## owns a dollar. `reward_base` left `data/incidents.json` for
## `data/economy.json`'s `city_services.dispatch_payout_base`, at the same six
## values, so the currency monopoly C-07 built now covers the last column that
## stood outside it — and `IncidentCatalog` refuses a file that carries the key
## back.
##
## Two things arrive with the move. **Who answered** now changes the price: a
## human working the incident drawer (`Incident.manual_requested`, set only by
## `cmd_dispatch_unit`) is paid doc 06's own `speed_bonus_max`, 1.50×, and the
## auto-dispatcher is paid 1.00× — exactly the dollars it has quietly earned
## since Wave 1. And the **moral-hazard ceiling** is applied by doc 03 against
## the loss the response actually prevented, which is why the target and the
## residual damage fraction cross the seam with the shape.
##
## The money is credited as a `city_services` receipt rather than a bare
## `credit`: it lands in the treasury now, and doc 03's next settlement prints
## it on a ledger line that says what it was. Before this wave it landed in the
## treasury and appeared nowhere at all — which is the whole of the player's
## report that automatic dispatch "should pay us money". It always did.
func _pay_reward(inc: Incident, row: Dictionary) -> int:
	var reward_table: Dictionary = catalog.reward
	var tier_k := float(reward_table.get("tier_k", 0.35))
	var speed_bonus := 1.0
	var response := inc.response_minutes()
	if response >= 0.0:
		var target := maxf(0.001, float(row.get("target_response_min", 10.0)))
		speed_bonus = clampf(float(reward_table.get("speed_bonus_base", 1.5))
				- float(reward_table.get("speed_bonus_k", 0.5)) * (response / target),
				float(reward_table.get("speed_bonus_min", 0.60)),
				float(reward_table.get("speed_bonus_max", 1.50)))
	var shape := (1.0 + tier_k * float(inc.tier_peak - 1)) * speed_bonus
	var reward := world.dispatch_payout(inc.type, shape, inc.manual_requested,
			inc.target_ref, _residual_damage_fraction(inc, row))
	if reward > 0:
		world.credit_city_service(reward, "dispatch", "incident_resolved")
	for unit_id in inc.assigned_unit_ids():
		var u: Vehicle = fleet.unit(int(unit_id))
		if u != null:
			var cost := world.vehicle_dispatch_cost(u.type)
			if cost > 0:
				world.debit(cost, "vehicle_dispatch")
	return reward


## The damage that DID land on the target, so doc 03 can subtract it from what
## the target is worth and get the loss the response prevented. It is the same
## fraction `_apply_resolution_effects` charges the player for repairing, read
## the same way: doc 06 §2.8's residual curve for a fire, §2.4's expected
## fraction for everything else.
func _residual_damage_fraction(inc: Incident, row: Dictionary) -> float:
	if String(row.get("suppression_model", "generic")) == "fire":
		return spread.residual_damage_fraction(inc)
	return expected_damage_fraction(inc)


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
		_emit("incident_abandoned", {"incident_id": inc.id, "incident_type": inc.type,
				"subtype": inc.subtype, "tier_peak": inc.tier_peak})
	else:
		_emit("incident_failed", {"incident_id": inc.id, "incident_type": inc.type,
				"subtype": inc.subtype, "tier_peak": inc.tier_peak,
				"target_ref": inc.target_ref.duplicate(true)})


## **Doc 06 §2.10's terminal rule (RR-26): nobody came, and nobody was ever
## going to.** The incident runs whatever consequence its type authored — a
## wreck left in the road still closes the road, a downed line left down still
## costs confidence — and then goes ABANDONED rather than FAILED, because
## ABANDONED is the status doc 06 already reserves for *the city did not answer
## this* and the one balance gate 9 measures.
##
## A type with no `on_fail` block at all (`storm_damage`) simply runs no actions
## and still terminates: before this rule it escalated to tier 5 and stood there
## for the rest of the city's life, which is what the Wave-8 measurement found at
## the bottom of the unbounded backlog.
##
## A REFUSED action list leaves the incident live, exactly as `_run_fail` does
## (C-47) — a consequence the world will not accept must not become a silent
## terminal status.
func _abandon_unanswered(inc: Incident) -> void:
	var row := catalog.type_row(inc.type, inc.subtype)
	var fail: Dictionary = row.get("on_fail", {})
	var results := ops.run(inc, fail.get("actions", []))
	for result in results:
		if String((result as Dictionary).get("result", "")) == CascadeOps.REFUSED:
			inc.context["fail_refused"] = true
			return
	inc.context.erase("fail_refused")
	inc.status = Incident.STATUS_ABANDONED
	inc.resolved_h = now_h
	dispatch.record_outcome(inc, Incident.STATUS_ABANDONED,
			float(row.get("target_response_min", 10.0)))
	_emit("incident_abandoned", {"incident_id": inc.id, "incident_type": inc.type,
			"subtype": inc.subtype, "tier_peak": inc.tier_peak,
			"unanswered_h": inc.unanswered_h,
			"reason": "unanswered", "target_ref": inc.target_ref.duplicate(true)})


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
		# §2.13(b), checked BEFORE the candidate query and BEFORE the hazard roll:
		# a roll whose ignition would be refused is a draw spent on nothing, and
		# `spread_candidates` is a spatial query. The grid is still re-anchored
		# below, so the saturated hours cost a fire neither an extra roll nor a
		# delayed one — the same argument `_next_discontinuity_h` makes.
		if saturated():
			break
		var inc: Incident = _active.get(incident_id)
		if inc == null or inc.type != "structure_fire" or inc.is_terminal():
			continue
		if catalog.g_stage(inc.tier()) <= 0.0:
			continue
		var assist := assist_ratio(inc)
		for target_id in spread.spread_candidates(inc):
			if saturated():
				break
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
			var child := spawn_automatic("structure_fire", "", target.get("tile", inc.tile),
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
	# §2.13(b) rides OUTSIDE the [floor, 1] clamp on purpose: the anti-death-spiral
	# damper is a taper and never reaches zero, and the saturation rule has to.
	return damper * saturation_damper()


# ------------------------------------------------------- §2.13(b) saturation

## **Doc 06 §2.13(b) — the saturation rule.** §2.13 has costed this system against
## "≤ 40 active incidents" since it was written and NOTHING ENFORCED IT, and
## §2.10.1's ceiling — `arrival_rate × T` — is only a ceiling while arrivals are
## EXOGENOUS. **Eight** `spawn_incident` actions in `data/incidents.json` make
## them endogenous, and five of those resolve to a BUILDING and take it off the
## board — self-limiting, the way fire spread is, because buildings run out. The
## three that consume nothing are `crime`'s two (one child at tier 4, two more at
## tier 5, both `scope: "district"`) and `traffic_accident`'s one at tier 5. RR-26
## bounds an incident's LIFETIME; nothing bounded its FERTILITY, and a mean
## offspring of three is a supercritical branching process whichever way it is
## measured (doc 92 §31: crisis `do_nothing` multiplies its roster ~2.8× per
## game-hour from game-day 104, to 89,055 open incidents and 269 s of wall clock
## per game-hour).
##
## The rule is THREE numbers, and the middle one is the one a first draft misses:
##
##     N        = open (non-terminal) incidents
##     CEIL     = 40   §2.13's own worst-case accounting — the ROSTER bound
##     RESERVE  =  4   slots inside CEIL that doc 06 may not spend
##     A_CEIL   = CEIL − RESERVE = 36   where AUTOMATIC births stop
##     KNEE     = 26   §2.10.1's measured worst LEGITIMATE backlog
##     sat(N)   = clamp((A_CEIL − N) / (A_CEIL − KNEE), 0, 1)
##
## **Why the reserve exists.** Doc 04 hands `on_power_event` a component failure
## exactly once — `PowerComponentFailed` is not re-emitted for a component that is
## already failed — so refusing that incident does not defer it, it STRANDS the
## component: nothing else calls `power_restore_component`, and the grid keeps a
## dead node forever. So the doc 04 path is not an automatic birth and is never
## refused, and the roster can therefore stand above `A_CEIL`. A first cut without
## the reserve measured **42** open on a 200-game-day `crisis` run against a
## ceiling of 40, and the two extra were both `PowerComponentFailed`. The reserve
## is that measurement doubled, and it puts the ROSTER bound back on §2.13's own
## number instead of near it.
##
## **A doc 04 admission cannot branch**, which is what makes the reserve a bound
## and not a leak: the only endogenous child a `transformer_failure` authors is a
## `structure_fire` on `nearest_building` at `chance 0.3`, and that IS an
## automatic birth, so it is refused above `A_CEIL` like any other.
##
## `sat` multiplies ambient generation (`load_damper`); `saturated()` refuses
## every automatic birth outright. Below the knee `sat` is exactly 1.0 and
## `saturated()` is false, so a city inside its own measured band cannot tell the
## rule is there — the whole 7×3×21 matrix peaks at **13** open — which is why it
## does not soften a live city's pressure and why the starter and bench
## determinism baselines do not move.
##
## Zero or absent disables it, which is what every fixture with a bare globals
## block gets.
func saturation_ceiling() -> int:
	return catalog.global_int("saturation_ceiling", 0)


func saturation_world_reserve() -> int:
	return catalog.global_int("saturation_world_reserve", 0)


func saturation_knee() -> int:
	return catalog.global_int("saturation_knee", 0)


## The ceiling AUTOMATIC births actually meet — §2.13's roster bound less the
## slots held for the world's own one-shot events.
func saturation_automatic_ceiling() -> int:
	var ceiling := saturation_ceiling()
	if ceiling <= 0:
		return 0
	return maxi(1, ceiling - saturation_world_reserve())


func saturation_damper() -> float:
	if saturation_ceiling() <= 0:
		return 1.0
	var ceiling := saturation_automatic_ceiling()
	var knee := mini(saturation_knee(), ceiling - 1)
	var span := float(ceiling - knee)
	return clampf((float(ceiling) - float(_order.size())) / span, 0.0, 1.0)


## True when the roster is at the automatic ceiling. Deterministic and RNG-free:
## a refusal draws nothing, so a city below it is bit-identical to one running
## without the rule.
func saturated() -> bool:
	return saturation_ceiling() > 0 and _order.size() >= saturation_automatic_ceiling()


## **The one seam every AUTOMATIC birth passes through** — the six ambient
## generators, fire spread's child ignition, and `CascadeOps`' `spawn_incident`
## verb. `spawn()` itself stays open, and deliberately: a scripted incident, a
## player-driven one, a doc 07 Director event and a doc 04 component failure are
## not what the ceiling is about. Refusing a component failure would strand a
## failed transformer with no repair path and no way back onto the grid, and
## refusing a Director event would be doc 06 overruling doc 07's pacing — the
## Director has already costed that event against its own threat-point budget.
func spawn_automatic(type_id: String, subtype: String, tile: Vector2i,
		target_ref: Dictionary, severity_0: float = -1.0, cause: Dictionary = {},
		district_id: String = "") -> Incident:
	if saturated():
		return null
	return spawn(type_id, subtype, tile, target_ref, severity_0, cause, district_id)


## Saturation is a STATE, not a stream. A dead city at the ceiling refuses
## thousands of births a game-day, and one event per refusal would be a second
## ANR in the history ring — so the bus hears the two EDGES and nothing else.
## The latch is derived, never serialized: `deserialize_incidents` recomputes it
## from the roster it just loaded, so a save carries no new key (doc 06 §3.3 is
## unchanged and the section version does not move).
func _update_saturation_latch() -> void:
	var now_saturated := saturated()
	if now_saturated == _saturated_latch:
		return
	_saturated_latch = now_saturated
	if now_saturated:
		_emit("incident_roster_saturated", {"open": _order.size(),
				"ceiling": saturation_automatic_ceiling(), "at_h": now_h})
	else:
		_emit("incident_roster_relieved", {"open": _order.size(),
				"ceiling": saturation_automatic_ceiling(), "at_h": now_h})


## Doc 92 §18 — the small-city ambient floor (audit 91 D-6).
##
## Every doc 06 §2.6 generator is PER ASSET, so its λ is proportional to what the
## player has already built; a founding city therefore generates almost nothing
## and the dispatch half of the game never starts. This is the same instrument
## doc 07 §8 already uses for the Director's threat points — a size-independent
## floor expressed as a `max()` — applied one channel at a time:
##
##     λ_used = max(λ_natural, floor_per_hour(type) × dt_h)
##
## Three properties, all of them the reason it is a max() and not an addend:
##
## 1. **Continuous.** A channel whose own inventory out-generates its floor never
##    sees it, and the handover happens at exactly one city size with no cliff
##    and no branch. There is no "small city" mode.
## 2. **Never invents a target.** `λ_natural <= 0` means the channel scanned and
##    found no eligible candidate — no district with residents, no unbroken main,
##    no storm cell — and the floor stays out. It changes how OFTEN, never WHERE.
## 3. **Still dampened.** The caller multiplies by `damper`, so an overwhelmed
##    fleet and doc 08's beyond-72-hour offline damper both still apply, and a
##    difficulty's `generation_mult` still scales it.
func _ambient_rate(natural: float, type_id: String, dt_h: float) -> float:
	if natural <= 0.0 or not catalog.ambient_floor_enabled:
		return natural
	if now_h < catalog.ambient_floor_grace_h:
		return natural
	return maxf(natural, catalog.ambient_floor_per_hour(type_id) * dt_h)


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
	# Hoisted: constants for the whole sub-step, and this loop runs on each one.
	var k_stability := catalog.factor("crime", "k_stability", 3.0)
	var k_dark := catalog.factor("crime", "k_dark", 0.35)
	var k_outage_in_dark := catalog.factor("crime", "k_outage_in_dark", 1.5)
	var police_base := catalog.factor("crime", "police_base", 1.4)
	var police_slope := catalog.factor("crime", "police_slope", 0.6)
	var police_min := catalog.factor("crime", "police_min", 0.5)
	var police_max := catalog.factor("crime", "police_max", 1.4)
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
		var f_stab := 1.0 + k_stability * pow(1.0 - stability, 2)
		var f_dark := 1.0 + k_dark * dark_frac \
				* (1.0 + k_outage_in_dark * outage)
		var f_police := clampf(police_base - police_slope * coverage,
				police_min, police_max)
		var lam := base * (population / 1000.0) * dt_h * f_stab * f_dark * f_police * f_weather
		if lam <= 0.0:
			continue
		candidates.append({"id": String(district_id), "lambda": lam})
		total += lam
	var count := _poisson(_ambient_rate(total, "crime", dt_h) * damper, stream)
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
		spawn_automatic("crime", "", tile, target_ref, -1.0,
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


## The rate is stated ONCE, in `_structure_fire_rates`, and asked for twice.
##
## The Poisson draw needs only Σλ; only the pick needs the per-candidate table.
## A sub-step that ignites nothing is the overwhelming majority, so the sum is
## taken with `collect = false` and the table is asked for only when the draw
## comes back positive. At 1,500 buildings and a dozen sub-steps a game-hour
## that is 18,000 candidate rows an hour a quiet city no longer builds.
##
## The second ask re-reads the same roster and re-evaluates the same expression
## in the same order — `_poisson` only draws, and nothing between the two touches
## roster state — so its `total` is the one already drawn against and every
## `lambda` is bit-for-bit what a single pass produced.
func _generate_structure_fire(dt_h: float, damper: float) -> void:
	var stream := catalog.stream_for("structure_fire")
	var total := float(_structure_fire_rates(dt_h, false)["total"])
	var count := _poisson(_ambient_rate(total, "structure_fire", dt_h) * damper, stream)
	if count <= 0:
		return
	var table := _structure_fire_rates(dt_h, true)
	var pick_ids: PackedStringArray = table["id"]
	var pick_lambdas: PackedFloat64Array = table["lambda"]
	for i in count:
		var picked := _weighted_pick_packed(pick_ids, pick_lambdas, total, stream)
		if picked == "":
			continue
		var b2 := world.building(picked)
		spawn_automatic("structure_fire", "", b2.get("tile", Vector2i.ZERO),
				{"kind": "building", "id": picked}, -1.0,
				{"source": "generator", "archetype": b2.get("archetype", ""),
				"level": b2.get("level", 1)})


## Doc 06 §2.6's per-building ignition rate over the whole roster:
## `{total, id, lambda}`. `collect` decides only whether the two candidate
## columns are filled; the arithmetic, the iteration order and the sum are the
## same either way, which is what lets the caller ask for the sum alone.
##
## The roster arrives as six parallel columns rather than 1,500 six-key
## dictionaries (`IncidentWorld.fire_candidate_columns`): this loop reads six
## fields per building on every integrator sub-step, and the Dictionary form
## charged it a hash lookup for each one.
func _structure_fire_rates(dt_h: float, collect: bool) -> Dictionary:
	var f_weather := world.weather_effect(catalog.weather_channel_for("structure_fire"))
	var base := float(catalog.generator_base_rates.get("structure_fire_global_scalar", 0.40))
	# Hoisted out of the roster loop: these are constants for the whole
	# sub-step, and this generator runs on every one of them.
	var unpowered_mult := catalog.factor("fire", "unpowered_mult", 0.8)
	var knee := catalog.factor("fire", "arson_stability_knee", 0.35)
	var arson_k := catalog.factor("fire", "arson_k", 2.0)
	var stability_by_district: Dictionary = {}
	var columns := world.fire_candidate_columns()
	var ids: PackedStringArray = columns["id"]
	var states: Array = columns["state"]
	var conditions: PackedFloat64Array = columns["condition"]
	var ignitions: PackedFloat64Array = columns["fire_ignition_per_hour"]
	var powered: PackedByteArray = columns["powered"]
	var districts: PackedStringArray = columns["district_id"]
	var pick_ids := PackedStringArray()
	var pick_lambdas := PackedFloat64Array()
	var total := 0.0
	for i in ids.size():
		var state_mult := IncidentWorld.state_fire_mult_value(states[i])
		if state_mult <= 0.0:
			continue
		var p_ignite := ignitions[i] \
				* IncidentWorld.fire_condition_mult_value(conditions[i]) * state_mult
		if p_ignite <= 0.0:
			continue
		var f_power := 1.0 + unpowered_mult * (0.0 if powered[i] != 0 else 1.0)
		var district_id := districts[i]
		if not stability_by_district.has(district_id):
			stability_by_district[district_id] = clampf(
					float(world.district(district_id).get("stability", 1.0)), 0.0, 1.0)
		var stability: float = stability_by_district[district_id]
		var f_arson := 1.0 + arson_k \
				* maxf(0.0, knee - stability) / maxf(0.0001, knee)
		var lam := base * p_ignite * dt_h * f_power * f_weather * f_arson
		if lam <= 0.0:
			continue
		total += lam
		if collect:
			pick_ids.append(ids[i])
			pick_lambdas.append(lam)
	return {"total": total, "id": pick_ids, "lambda": pick_lambdas}


func _generate_transformer(dt_h: float, damper: float) -> void:
	var stream := catalog.stream_for("transformer_failure")
	var f_weather := world.weather_effect(catalog.weather_channel_for("transformer_failure"))
	var base := float(catalog.generator_base_rates.get("transformer_per_node", 0.0012))
	var clamp_row: Array = catalog.factors.get("transformer", {}).get("load_clamp", [0.20, 1.60])
	# Hoisted: constants for the whole sub-step (see _generate_crime).
	var clamp_lo := float(clamp_row[0])
	var clamp_hi := float(clamp_row[1])
	var load_ref := maxf(0.0001, catalog.factor("transformer", "load_ref", 0.70))
	var load_exp := catalog.factor("transformer", "load_exp", 3.0)
	var temp_k := catalog.factor("transformer", "temp_k", 0.9)
	var temp_knee_c := catalog.factor("transformer", "temp_knee_c", 65.0)
	var temp_span_c := maxf(0.0001, catalog.factor("transformer", "temp_span_c", 35.0))
	var candidates: Array = []
	var total := 0.0
	# The scan reads three numbers per node; `power_transformer_rates()` carries
	# exactly those.
	for node in world.power_transformer_rates():
		var row: Dictionary = node
		var load_ratio := clampf(float(row.get("load_ratio", 0.0)), clamp_lo, clamp_hi)
		var f_load := pow(load_ratio / load_ref, load_exp)
		var f_cond := pow(2.0 - clampf(float(row.get("condition", 1.0)), 0.0, 1.0), 2)
		var f_temp := 1.0 + temp_k \
				* maxf(0.0, (float(row.get("temp_c", 25.0)) - temp_knee_c) / temp_span_c)
		var lam := base * dt_h * f_load * f_cond * f_temp * f_weather
		if lam <= 0.0:
			continue
		candidates.append({"id": String(row.get("id", "")), "lambda": lam, "row": row})
		total += lam
	var count := _poisson(_ambient_rate(total, "transformer_failure", dt_h) * damper, stream)
	if count > 0:
		# Only a sub-step that actually spawns needs the FULL component rows
		# `spawn_component_incident` reads (kind, tile, the downstream roll-up).
		# Nothing between the scan above and here touches grid state — `_poisson`
		# only draws — so these are the rows the scan would have captured.
		var full_by_id: Dictionary = {}
		for full_row in world.power_transformers():
			full_by_id[String((full_row as Dictionary).get("id", ""))] = full_row
		for candidate in candidates:
			var entry: Dictionary = candidate
			entry["row"] = full_by_id.get(String(entry["id"]), entry["row"])
	for i in count:
		# §2.13(b). This generator is the one that cannot go through
		# `spawn_automatic`: it needs `spawn_component_incident`'s component
		# plumbing, and that entry point also serves doc 04's real failures, which
		# the ceiling must never refuse (see `spawn_automatic`). So the AMBIENT
		# path takes the check and the doc 04 path does not.
		if saturated():
			break
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
	var count := _poisson(_ambient_rate(total, "water_main_break", dt_h) * damper, stream)
	for i in count:
		var picked := _weighted_pick_row(candidates, total, stream)
		if picked.is_empty():
			continue
		var row2: Dictionary = picked.get("row", {})
		var inc := spawn_automatic("water_main_break", "", row2.get("tile", Vector2i.ZERO),
				{"kind": "water_segment", "id": String(picked.get("id", ""))}, -1.0,
				{"source": "generator"})
		if inc != null:
			inc.context["zone"] = String(row2.get("zone", ""))
			inc.context["pressure_ratio"] = float(row2.get("pressure_ratio", 1.0))
			world.water_set_segment_broken(String(picked.get("id", "")), inc.severity,
					"incident:%d" % inc.id)


## Doc 06 §2.6(e), split along the line the arithmetic already had in it:
##
##     λ_node = R_acc_base · f_flow · f_signal · f_road_cond      per NODE
##     λ      = λ_node · dt_h · f_weather · f_dark                city-wide
##
## The first line moves only when doc 10's roster does — a congestion re-price, a
## repaired approach, a signal losing power, a road built — and the second is one
## scalar the whole city shares (weather and night are global, C-59). So the
## per-node half is built once per roster epoch and the sub-step multiplies
## through it, instead of every sub-step re-deriving ~400 identical numbers.
## Same product, same candidate weights, same one `randf()` per spawn.
func _generate_traffic(dt_h: float, dark_frac: float, damper: float) -> void:
	var stream := catalog.stream_for("traffic_accident")
	var f_weather := world.weather_effect(catalog.weather_channel_for("traffic_accident"))
	# `f_dark` has no per-candidate term at all: night is city-wide (C-59).
	var f_dark := 1.0 + catalog.factor("traffic", "dark_k", 0.25) * dark_frac
	_refresh_traffic_weights()
	if _traffic_used == 0:
		return
	var total := _traffic_weight_total * dt_h * f_weather * f_dark
	var count := _poisson(_ambient_rate(total, "traffic_accident", dt_h) * damper, stream)
	for i in count:
		var picked := _weighted_pick_row(_traffic_scratch, _traffic_weight_total,
				stream, _traffic_used)
		if picked.is_empty():
			continue
		var row2: Dictionary = picked.get("row", {})
		var inc := spawn_automatic("traffic_accident", "", row2.get("tile", Vector2i.ZERO),
				{"kind": "intersection", "id": String(picked.get("id", ""))}, -1.0,
				{"source": "generator"})
		if inc != null:
			inc.context["congestion_index"] = float(row2.get("congestion_index", 0.0))
			inc.context["signal_powered"] = bool(row2.get("signal_powered", true))


## The per-node half of §2.6(e), rebuilt only when doc 10 says the roster moved.
## A world that cannot answer that returns `-1` from `road_intersections_epoch()`
## and every call rebuilds, which is the pre-cache behaviour exactly — so a test
## stub is never cached wrongly.
func _refresh_traffic_weights() -> void:
	var epoch := world.road_intersections_epoch()
	if epoch >= 0 and epoch == _traffic_epoch and _traffic_weight_total >= 0.0:
		return
	_traffic_epoch = epoch
	var base := float(catalog.generator_base_rates.get("traffic_per_intersection", 0.0020))
	var clamp_row: Array = catalog.factors.get("traffic", {}).get("flow_clamp", [0.05, 2.0])
	var clamp_lo := float(clamp_row[0])
	var clamp_hi := float(clamp_row[1])
	var flow_exp := catalog.factor("traffic", "flow_exp", 1.5)
	var k_unsignalised := catalog.factor("traffic", "unsignalised", 1.6)
	var k_signal_powered := catalog.factor("traffic", "signal_powered", 1.0)
	var k_signal_unpowered := catalog.factor("traffic", "signal_unpowered", 3.0)
	var used := 0
	var total := 0.0
	for node in world.road_intersections():
		var row: Dictionary = node
		var congestion := clampf(float(row.get("congestion_index", 0.0)),
				clamp_lo, clamp_hi)
		var f_flow := pow(congestion, flow_exp)
		var f_signal := k_unsignalised
		if bool(row.get("signalised", false)):
			f_signal = k_signal_powered if bool(row.get("signal_powered", true)) \
					else k_signal_unpowered
		# Doc 10 owns condition_hazard_mult; doc 06 does not rescale it (C-48).
		# NOT `row.get(key, travel.condition_hazard_mult(tile))`: GDScript builds
		# the default BEFORE the lookup, so the fallback used to fire on every
		# candidate even when the adapter supplies the column.
		var f_road := float(row["condition_hazard_mult"]) \
				if row.has("condition_hazard_mult") \
				else travel.condition_hazard_mult(row.get("tile", Vector2i.ZERO))
		var weight := base * f_flow * f_signal * f_road
		if weight <= 0.0:
			continue
		if used < _traffic_scratch.size():
			var slot: Dictionary = _traffic_scratch[used]
			slot["id"] = String(row.get("id", ""))
			slot["lambda"] = weight
			slot["row"] = row
		else:
			_traffic_scratch.append({"id": String(row.get("id", "")),
					"lambda": weight, "row": row})
		used += 1
		total += weight
	_traffic_used = used
	_traffic_weight_total = total


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
	# No `_ambient_rate` here, deliberately: storm damage is not ambient. Its
	# candidates exist only inside a live doc 07 storm cell, and while one is
	# overhead the player has plenty to answer — doc 92 §18 authors no floor row
	# for it, so a call here would be a no-op that reads like a rule.
	var count := _poisson(total * damper, stream)
	for i in count:
		var picked := _weighted_pick_row(candidates, total, stream)
		if picked.is_empty():
			continue
		var subtype := _pick_storm_subtype(stream)
		var row2: Dictionary = picked.get("row", {})
		spawn_automatic("storm_damage", subtype, row2.get("tile", Vector2i.ZERO),
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


## Packed-column twin of `_weighted_pick`, for the structure-fire generator's
## candidate table. Same draw from the same stream, the same cumulative walk in
## the same order, the same last-element fallback — it is the Array-of-
## dictionaries form with the dictionaries taken out.
func _weighted_pick_packed(ids: PackedStringArray, lambdas: PackedFloat64Array,
		total: float, stream: String) -> String:
	if ids.is_empty() or total <= 0.0:
		return ""
	var roll := rng.stream(stream).randf() * total
	var cumulative := 0.0
	for i in ids.size():
		cumulative += lambdas[i]
		if roll < cumulative:
			return ids[i]
	return ids[ids.size() - 1]


## `count < 0` means "the whole array". A caller that fills a REUSED scratch
## buffer passes how much of it it filled, so the buffer never has to be resized
## and the rows in it are never reallocated (see `_traffic_scratch`).
func _weighted_pick_row(candidates: Array, total: float, stream: String,
		count: int = -1) -> Dictionary:
	var size := candidates.size() if count < 0 else mini(count, candidates.size())
	if size <= 0 or total <= 0.0:
		return {}
	var roll := rng.stream(stream).randf() * total
	var cumulative := 0.0
	for i in size:
		var candidate: Dictionary = candidates[i]
		cumulative += float(candidate["lambda"])
		if roll < cumulative:
			return candidate
	return candidates[size - 1]


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
	# `incident_type`, never `type`: `_emit` stamps the BUS event name into
	# `type`, so an incident that named its own kind there lost it on the way out
	# (doc 92 ruling 8 — pre-1.0, no compatibility key).
	_emit("incident_created", {"incident_id": inc.id, "incident_type": type_id,
			"subtype": subtype,
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
			# What this incident is ABOUT, not just where it is. `incident_created`
			# has always carried it; the snapshot did not, so a UI that came up on
			# a loaded save — which replays no lifecycle event — knew the tier and
			# the tile of a `water_main_break` and not which main. Doc 05 §2.12's
			# isolate/restore pair needs the id, so the read-only view publishes
			# what the event already published. Nothing is hashed here: the save is
			# `canonical_capture()`, and this is a snapshot.
			"target_ref": inc.target_ref.duplicate(true),
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
	# §2.13(b)'s latch is DERIVED from the roster, which is why the save section
	# carries no new key: a city loaded at the ceiling is a city at the ceiling,
	# and it must not announce the crossing a second time.
	_saturated_latch = saturated()
