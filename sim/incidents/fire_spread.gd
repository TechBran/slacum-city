class_name FireSpread
extends RefCounted
## Fire dynamics (doc 06 §2.8). Three separate doc 07 questions with three
## separate channels and three separate call sites, and none may stand in for
## another (RR-15):
##   fire_ignition_mult   — how OFTEN a fire starts   (generation, IncidentSystem)
##   fire_escalation_mult — how FAST one already burning grows (esc_env)
##   fire_spread_mult     — how READILY it jumps to a neighbour (g_weather, here)
##
## Wind is not in any of them: it reaches escalation through the §2.4 wind term
## and spread through `g_wind`, both off doc 07's `wind_kph`, exactly once each.
##
## Spread uses a HAZARD RATE, not a flat per-tick probability. That is what
## makes fine and coarse stepping agree: P(no ignition over 1 gh) = exp(-rate)
## whether it is evaluated once or twelve times.

const SPREAD_CHANNEL := "spread"

var catalog: IncidentCatalog
var world: IncidentWorld


func _init(p_catalog: IncidentCatalog, p_world: IncidentWorld) -> void:
	catalog = p_catalog
	world = p_world


## §2.8: S_req(b) = 0.50 × (doc02.fire_load / 20)^0.45, then × stage_mult[tier].
## The consequence ladder enters through exactly one number — doc 02's
## `fire_load` (C-43 / R-12).
func s_req(fire_load: float) -> float:
	return catalog.s_req_for_fire_load(fire_load)


func required_rate(inc: Incident) -> float:
	var fire_load := float(inc.context.get("fire_load", 0.0))
	if fire_load <= 0.0:
		var b := world.building(inc.target_building_id())
		fire_load = float(b.get("fire_load", catalog.fire.get("fire_load_anchor", 20)))
	return s_req(fire_load) * catalog.stage_mult(inc.tier())


## Pressure 0 (a dead water system) still leaves the floor — tank water on the
## engine — so fire response degrades rather than becoming impossible.
func hydrant_factor(tile: Vector2i) -> float:
	var ratio := world.hydrant_pressure_ratio(tile)
	return clampf(catalog.global_value("hydrant_floor", 0.25)
			+ catalog.global_value("hydrant_span", 0.75) * ratio,
			catalog.global_value("hydrant_floor", 0.25),
			catalog.global_value("hydrant_cap", 1.15))


## The §2.4 escalation-side hydrant penalty (doc 05/06 physics, NOT weather).
func hydrant_penalty(tile: Vector2i) -> float:
	var knee := catalog.factor("fire", "esc_hydrant_knee", 0.7)
	var k := catalog.factor("fire", "esc_hydrant_k", 0.6)
	var ratio := world.hydrant_pressure_ratio(tile)
	return 1.0 + k * maxf(0.0, knee - ratio) / maxf(0.0001, knee)


## §2.8 `rate(target)`, in ignitions per game-hour. `assist_ratio` is the
## source fire's — one engine on it takes the rate to zero, in any weather.
## `neighbour_count` and `distance_override_m` exist so §2.8's worked table can
## be reproduced on exact geometry (a tile grid cannot express 14 m); doc 10's
## real polylines will supply both in production.
func spread_rate(source: Incident, target_id: String, assist_ratio: float,
		neighbour_count: int = -1, distance_override_m: float = -1.0) -> float:
	var target := world.building(target_id)
	if target.is_empty():
		return 0.0
	if world.state_fire_mult(target_id) <= 0.0:
		return 0.0
	var g_stage := catalog.g_stage(source.tier())
	if g_stage <= 0.0:
		return 0.0  # tier-1 fires never spread
	var target_tile: Vector2i = target.get("tile", Vector2i.ZERO)
	var distance_m := distance_override_m
	if distance_m < 0.0:
		distance_m = source.centre_m().distance_to(
				Vector2(float(target_tile.x) * 8.0 + 4.0, float(target_tile.y) * 8.0 + 4.0))
	var min_gap := catalog.global_value("spread_min_gap_m", 6.0)
	var decay := maxf(0.0001, catalog.global_value("spread_dist_decay_m", 12.0))
	var g_dist := clampf(exp(-(distance_m - min_gap) / decay), 0.0, 1.0)
	var g_wind := _g_wind(source, target_tile)
	var neighbours := neighbour_count
	if neighbours < 0:
		neighbours = world.buildings_within_m(target_tile,
				float(catalog.fire.get("g_density_radius_m", 24.0)), target_id).size()
	var g_density := 1.0 + float(catalog.fire.get("g_density_k", 0.5)) \
			* float(neighbours) / maxf(1.0, float(catalog.fire.get("g_density_ref", 6)))
	var g_mat := catalog.spread_material_mult(String(target.get("archetype", "")))
	# UNCLAMPED — it is doc 07's number (RR-15).
	var g_weather := world.weather_effect(
			String(catalog.fire_weather_channels.get(SPREAD_CHANNEL, "fire_spread_mult")))
	var rate := catalog.global_value("p_spread_base", 0.30) * g_stage * g_dist * g_wind \
			* g_density * g_mat * g_weather
	return rate * (1.0 - clampf(assist_ratio, 0.0, 1.0))


func _g_wind(source: Incident, target_tile: Vector2i) -> float:
	var k := float(catalog.fire.get("g_wind_k", 1.2))
	var reference := maxf(0.0001, float(catalog.fire.get("g_wind_ref_kph", 60.0)))
	var wind := world.wind_kph()
	if wind <= 0.0:
		return 1.0
	var bearing := Vector2(float(target_tile.x - source.tile.x), float(target_tile.y - source.tile.y))
	var cos_theta := 1.0
	if bearing.length_squared() > 0.0:
		cos_theta = cos(world.wind_dir_rad() - atan2(bearing.y, bearing.x))
	return 1.0 + k * (wind / reference) * maxf(0.0, cos_theta)


## Hazard rate → probability over one roll interval. The multiplication by
## `g_weather` happens BEFORE the exponential, which is the only place it can
## be and still make 5-minute and 1-hour granularity agree (test 9 / RR-15).
static func interval_probability(rate_per_gh: float, interval_h: float) -> float:
	return 1.0 - exp(-rate_per_gh * interval_h)


## Candidate targets for one spread roll batch, ASCENDING by building id.
func spread_candidates(source: Incident) -> Array:
	return world.buildings_within_m(source.tile,
			catalog.global_value("spread_radius_m", 40.0), source.target_building_id())


## §2.8 residual damage when a fire is put out before burn-down.
func residual_damage_fraction(inc: Incident) -> float:
	var table: Dictionary = catalog.fire.get("residual_damage", {})
	var value := float(table.get("tier_k", 0.10)) * float(inc.tier_peak - 1) \
			+ float(table.get("burn_timer_k", 0.30)) * inc.burn_timer_h
	return clampf(value, 0.0, float(table.get("cap", 0.95)))


## A spread ignition creates a NEW structure_fire with severity_0 keyed to the
## parent's tier, `parent_id` = source, and the same `cluster_id`.
func spread_severity_0(parent_tier: int) -> float:
	return 1.0 + float(catalog.fire.get("spread_severity_parent_k", 0.25)) \
			* float(parent_tier - 2)
