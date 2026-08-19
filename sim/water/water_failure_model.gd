class_name WaterFailureModel
extends RefCounted
## Doc 05 §2.9. Two jobs:
##
## 1. PUBLISH, per candidate main segment, the three dimensionless hazard
##    multipliers doc 06 multiplies into ITS `water_main_break` rate (C-46).
##    Doc 06 owns the roll; this doc owns condition, load and freeze, which are
##    exactly the levers the player controls.
## 2. ROLL the failures doc 06 does not model — pump, treatment and source —
##    once per game-hour of sim time, live and offline through the identical
##    code path, from the shared `failures` RNG stream (constitution §5).
##
## `main_break` / `freeze_break` rates survive here as the CALIBRATION
## REFERENCE and the standalone fallback: `WaterSystem` must remain runnable
## and testable with no incident system attached.

const FAILURE_STREAM := "failures"
const MINUTES_PER_GAME_DAY := 1440.0

var data: WaterData


func _init(p_data: WaterData) -> void:
	data = p_data


# ------------------------------------------------- multipliers (to doc 06)

func cond_mult(condition: float) -> float:
	return 1.0 + data.failure_value("cond_mult_k", 6.0) * pow(1.0 - clampf(condition, 0.0, 1.0), 2)


func main_load_mult(utilization: float) -> float:
	var knee := data.failure_value("main_load_mult_knee", 0.85)
	var gain := data.failure_value("load_mult_gain", 1.5)
	return 1.0 + gain * maxf(0.0, utilization - knee) / maxf(1.0 - knee, 1e-6)


func pump_load_mult(output_frac: float) -> float:
	var knee := data.failure_value("pump_load_mult_knee", 0.95)
	var gain := data.failure_value("load_mult_gain", 1.5)
	return 1.0 + gain * maxf(0.0, output_frac - knee) / maxf(1.0 - knee, 1e-6)


func freeze_mult(freeze_stress: float) -> float:
	var gain := data.failure_value("freeze_hazard_gain", 2.5)
	var cap := data.failure_value("freeze_mult_cap", 6.0)
	return clampf(1.0 + gain * freeze_stress, 1.0, cap)


## §2.9: age_mult = 1 + 0.15 × floor(age_game_days / 60), capped at 2.0.
func age_mult(age_minutes: float) -> float:
	var per_60 := data.failure_value("age_mult_per_60_days", 0.15)
	var cap := data.failure_value("age_mult_cap", 2.0)
	var days := maxf(0.0, age_minutes) / MINUTES_PER_GAME_DAY
	return minf(1.0 + per_60 * floorf(days / 60.0), cap)


func weather_mult(weather_kind: String) -> float:
	return data.weather_failure_mult(weather_kind)


# ------------------------------------------------------------ hourly rolls

## Returns the failure records for one game-hour, in deterministic node order.
## `context`: {weather_kind, output_frac: {node_id: float}, now_minutes}
func roll_hour(nodes: Dictionary, rng: RngStreams, context: Dictionary) -> Array:
	var out: Array = []
	var stream := rng.stream(FAILURE_STREAM)
	var weather_kind := String(context.get("weather_kind", "clear"))
	var output_frac: Dictionary = context.get("output_frac", {})
	var now_minutes := float(context.get("now_minutes", 0.0))
	var air_temp_c := float(context.get("air_temp_c", 20.0))
	for node_id in _sorted(nodes):
		var node: WaterNode = nodes[node_id]
		var kind := _failure_kind(node.variant)
		if kind == "":
			continue
		if node.state == &"failed" or node.state == &"offline_manual":
			continue
		var base := data.base_failure_rate(kind)
		if base <= 0.0:
			continue
		var load := 1.0
		if node.variant == &"pump":
			load = pump_load_mult(float(output_frac.get(node_id, 0.0)))
		var exposure := 1.0
		if node.variant == &"pump" or node.variant == &"booster":
			if node.insulation == 0 and air_temp_c < data.freeze_value("exposed_pump_temp_c", -12.0):
				exposure = data.freeze_value("exposed_pump_mult", 2.0)
		var p_hour := base * cond_mult(node.condition) * load \
				* weather_mult(weather_kind) * age_mult(now_minutes - node.built_at_minutes) \
				* exposure
		if stream.randf() >= p_hour:
			continue
		var severity := roll_severity(stream, node.condition)
		out.append({"kind": kind, "target_kind": "node", "target_id": String(node_id),
				"tile": node.tile, "severity": severity, "frozen": false,
				"damage_fraction": damage_fraction(severity, false)})
	return out


## §2.9 fallback: the standalone main-break hazard, used ONLY when no doc-06
## incident system is attached (the debug / test harness path).
func roll_mains_fallback(edges: Dictionary, rng: RngStreams, context: Dictionary) -> Array:
	var out: Array = []
	var stream := rng.stream(FAILURE_STREAM)
	var weather_kind := String(context.get("weather_kind", "clear"))
	var utilization: Dictionary = context.get("utilization", {})
	var base := data.base_failure_rate("main_break")
	var freeze_base := data.freeze_value("break_base", 0.0020)
	for edge_id in _sorted(edges):
		var edge: WaterEdge = edges[edge_id]
		if not edge.is_live():
			continue
		var mechanical := base * data.main_break_rate_mult(edge.tier) \
				* cond_mult(edge.condition) \
				* main_load_mult(float(utilization.get(edge_id, 0.0))) \
				* weather_mult(weather_kind)
		var freeze := 0.0
		if data.flag("freeze_enabled") and edge.freeze_stress > 0.0:
			freeze = freeze_base * edge.freeze_stress * maxf(0.0, 1.2 - edge.condition)
		var p_hour := mechanical + freeze
		if p_hour <= 0.0 or stream.randf() >= p_hour:
			continue
		var frozen := freeze > mechanical
		var severity := roll_severity(stream, edge.condition)
		out.append({"kind": "freeze_break" if frozen else "main_break",
				"target_kind": "edge", "target_id": String(edge_id),
				"tile": edge.path[0] if not edge.path.is_empty() else Vector2i.ZERO,
				"severity": severity, "frozen": frozen,
				"damage_fraction": damage_fraction(severity, frozen)})
	return out


func roll_severity(stream: RandomNumberGenerator, condition: float) -> float:
	var base := data.failure_value("severity_base", 0.25)
	var random_gain := data.failure_value("severity_random", 0.60)
	var condition_gain := data.failure_value("severity_condition_gain", 0.20)
	return clampf(base + stream.randf() * random_gain
			+ condition_gain * (1.0 - clampf(condition, 0.0, 1.0)), 0.1, 1.0)


## §2.12 / C-16: this doc publishes `damage_fraction` and NEVER a price.
## Doc 03 turns it into money through `capital_value × f × 0.85 × M_repair`.
func damage_fraction(severity: float, frozen: bool) -> float:
	var conversion: Dictionary = data.repair.get("damage_fraction", {})
	var base := float(conversion.get("severity_base", 0.5))
	var gain := float(conversion.get("severity_gain", 1.0))
	var frozen_mult := float(conversion.get("frozen_mult", 1.15)) if frozen else 1.0
	return clampf(clampf(base + gain * severity, 0.0, 1.0) * frozen_mult, 0.0, 1.0)


# ------------------------------------------------------- freeze & condition

## §2.9. `insulation` cuts the accumulation; thaw is unconditional above the
## threshold. Returns the new stress value.
func step_freeze_stress(stress: float, air_temp_c: float, insulation: int, dt_h: float) -> float:
	var threshold := data.freeze_value("threshold_c", -6.0)
	if air_temp_c < threshold:
		var divisor := data.freeze_value("stress_gain_div", 10.0)
		var reduction := data.freeze_value("insulation_reduction_per_level", 0.45)
		return stress + ((threshold - air_temp_c) / divisor) * dt_h \
				* maxf(0.0, 1.0 - reduction * float(insulation))
	return maxf(0.0, stress - data.freeze_value("thaw_rate_per_hour", 0.5) * dt_h)


## §2.12 maintenance decay: at full funding a pump ages 1.0 → 0.0 in ≈10,000
## game-hours; at zero funding ≈4,000 (2.5×).
func decayed_condition(condition: float, kind: String, maintenance_level: float,
		dt_h: float) -> float:
	var curve: Dictionary = data.failures.get("maintenance_decay_curve", {})
	var at_zero := float(curve.get("at_zero_funding", 2.5))
	var gain := float(curve.get("gain", 1.5))
	var rate := data.condition_decay_per_hour(kind)
	return clampf(condition - rate * (at_zero - gain * clampf(maintenance_level, 0.0, 1.0)) * dt_h,
			0.0, 1.0)


static func _failure_kind(variant: StringName) -> String:
	match variant:
		&"pump":
			return "pump_failure"
		&"treatment":
			return "treatment_failure"
		&"source":
			return "source_failure"
		_:
			return ""


static func _sorted(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
