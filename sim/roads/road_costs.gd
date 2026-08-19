class_name RoadCosts
extends RefCounted
## Doc 10 §2.6 — the cost function, as pure static functions.
##
##   cost(e, prof) = (L_e / (speed_mpgm · road_class_mult))
##                 · F_cong · F_weather · F_cond · F_closure · F_override
##                 + D_node(n_entry, e, prof)
##
## Every term is separately testable and consumes no state, so worked example C
## can be reproduced arithmetically without building a graph. All times are
## GAME-MINUTES; all speeds metres per game-minute (never km/h — doc 06 §9).

const BLOCKED: float = -1.0


## Free-flow traversal time before any multiplier.
static func free_flow_gm(length_m: float, speed_mpgm: float, road_class_mult: float) -> float:
	var denom := maxf(0.001, speed_mpgm * road_class_mult)
	return length_m / denom


## F_cong = 1 + S_cong(class) · c · (1 − cong_relief(prof)); c ∈ [0,2], 1 = at capacity.
static func f_cong(s_cong: float, congestion_index: float, cong_relief: float) -> float:
	return 1.0 + s_cong * congestion_index * (1.0 - cong_relief)


## F_weather = 1 + wx_slowdown(state) · (1 − wx_resist(prof)).
static func f_weather(wx_slowdown: float, wx_resist: float) -> float:
	return 1.0 + wx_slowdown * (1.0 - wx_resist)


## F_cond = 1 + COND_PENALTY_MAX · (1 − condition)²  — condition on [0,1] (RR-3).
## 1.00 → 1.000 · 0.75 → 1.0375 · 0.50 → 1.150 · 0.25 → 1.3375 · 0 → COLLAPSED.
static func f_cond(condition: float, cond_penalty_max: float) -> float:
	var residual := 1.0 - clampf(condition, 0.0, 1.0)
	return 1.0 + cond_penalty_max * residual * residual


## F_override = 1 / clamp(speed_override, min, 1.0). Doc 06's escalation tiers
## set the override; it is a separate multiplicative channel from F_closure.
static func f_override(speed_override: float, override_min: float) -> float:
	return 1.0 / clampf(speed_override, override_min, 1.0)


## D_node. `base` scales with the congestion of the edge being ENTERED, which is
## what makes the dark-signal cascade bite hardest exactly where traffic is worst.
##   !signalised, degree < 3   → 0
##   !signalised               → STOP_DELAY   · (1 + c)
##   signalised, powered       → SIGNAL_DELAY · (1 + c)
##   signalised, unpowered     → DARK_SIGNAL_DELAY · (1 + 2c)      ← report 98 G-6
static func node_delay_gm(signalised: bool, powered: bool, degree: int,
		congestion_index: float, node_relief: float, stop_delay: float,
		signal_delay: float, dark_delay: float, powered_coeff: float,
		dark_coeff: float) -> float:
	var base := 0.0
	if not signalised:
		if degree < 3:
			base = 0.0
		else:
			base = stop_delay * (1.0 + powered_coeff * congestion_index)
	elif powered:
		base = signal_delay * (1.0 + powered_coeff * congestion_index)
	else:
		base = dark_delay * (1.0 + dark_coeff * congestion_index)
	return base * (1.0 - node_relief)


## Doc 10 §2.11: the road-condition contribution doc 06 folds into its
## traffic_accident rate (report 98 C-48). 0.10 → 1.26, 0.55 → 1.08, ≥0.75 → 1.00.
static func condition_hazard_mult(condition: float, coeff: float, threshold: float) -> float:
	return 1.0 + coeff * maxf(0.0, threshold - clampf(condition, 0.0, 1.0))


## Congestion is quantised BEFORE costing so route_minutes is a pure function of
## a quantised snapshot — the mode-invariance guarantee doc 06 depends on
## (§4 guarantee 2). Integer steps, so the value is bit-identical across modes.
static func quantise_congestion(c: float, step: float) -> float:
	if step <= 0.0:
		return c
	return float(roundi(c / step)) * step


## Doc 10 §2.14 — the O(1) admissible estimate. Never over-estimates, so doc 06
## may prune with it safely.
static func estimate_eta_gm(a: Vector2i, b: Vector2i, speed_mpgm: float,
		tile_m: float, class_mult_max: float) -> float:
	var manhattan_m := float(absi(a.x - b.x) + absi(a.y - b.y)) * tile_m
	return manhattan_m / maxf(0.001, speed_mpgm * class_mult_max)


## The RANKING function doc 12's unit picker uses for ~40 units in one frame.
static func estimate_eta_practical_gm(optimistic_gm: float, detour_factor: float,
		practical_congestion_coeff: float, district_mean_congestion: float) -> float:
	return optimistic_gm * detour_factor * (1.0 + practical_congestion_coeff
			* district_mean_congestion)


## Smoothing: c ← c + (c_raw − c)·smooth(dt); smooth = 1 − (1 − CONG_SMOOTH)^dt_gm.
## dt-aware so one coarse 60 gm step lands where 60 fine steps converge.
static func smoothing_alpha(smooth_per_gm: float, dt_game_minutes: float) -> float:
	if dt_game_minutes <= 0.0:
		return 0.0
	return 1.0 - pow(1.0 - smooth_per_gm, dt_game_minutes)


## Doc 10 §2.12 condition tier name for a condition on [0,1].
static func condition_tier(condition: float, good: float, poor: float,
		failing: float) -> StringName:
	if condition <= 0.0:
		return &"collapsed"
	if condition >= good:
		return &"good"
	if condition >= poor:
		return &"worn"
	if condition >= failing:
		return &"poor"
	return &"failing"


## Doc 10 §2.15 overlay bands (colour + pattern encode the rest).
static func overlay_band(c: float) -> StringName:
	if c < 0.25:
		return &"clear"
	if c < 0.50:
		return &"light"
	if c < 0.75:
		return &"heavy"
	if c < 0.90:
		return &"severe"
	return &"gridlock"
