class_name RoadTunables
extends RefCounted
## Parsed `data/roads.json` (doc 10 §8). Pure data in, typed accessors out —
## the sim never touches the filesystem (same precedent as CostCurves).
##
## Every balance number roads uses lives here. Nothing in `sim/roads/` may
## author a constant that is not in this file, and this file carries NO dollar
## figure except the auto-repair *budget cap* (report 98 RR-2, §9.4 q10).

const CLASS_NONE: int = 0
const CLASS_STREET: int = 1
const CLASS_AVENUE: int = 2

var version: int = 0
var errors: PackedStringArray = []

# classes[class_id] -> {road_class_mult, k_base, s_cong, build_crew_hours,
#                       condition_base_decay, signal_min_degree, upgrade_crew_hours, name}
var classes: Dictionary = {}
# route_classes[route_class_id] -> {cong_relief, node_relief, wx_resist}
var route_classes: Dictionary = {}

var tile_m: float = 8.0
var cond_penalty_max: float = 0.60
var desperate_block_mult: float = 12.0
var reverse_penalty_gm: float = 0.50
var speed_override_min: float = 0.10
var congestion_index_max: float = 2.0

var stop_delay_gm: float = 0.04
var signal_delay_gm: float = 0.12
var dark_signal_delay_gm: float = 0.45
var dark_congestion_coeff: float = 2.0
var powered_congestion_coeff: float = 1.0

var smooth_per_game_minute: float = 0.35
var dens_k: float = 0.0022
var dens_min: float = 0.20
var dens_max: float = 1.60
var dens_radius_tiles: int = 6
var spillback_hop1: float = 0.50
var spillback_hop2: float = 0.25
var dark_signal_add: float = 0.19
var max_active_closures: int = 128
var event_peak: float = 1.40
var event_radius_tiles: int = 40
var event_inbound_lead_gm: int = 45
var event_outbound_tail_gm: int = 45
var event_during_factor: float = 0.25
var default_profile_weights: Dictionary = {}

# tod_curves[profile] -> Array[float] of 24
var tod_curves: Dictionary = {}
# weather[state] -> {slowdown, cong_add, wear}
var weather: Dictionary = {}

var closure_dominance: Array = []  # highest severity first
# closure_causes[cause] -> {mult: Array[float] (-1 = BLOCK), cong_add, hard, auto_expire_gm}
var closure_causes: Dictionary = {}
var soft_block_second_chance: Array = []
var flood_deep_to_shallow_depth_m: float = 0.35
var flood_shallow_clear_depth_m: float = 0.10

var congestion_wear_coeff: float = 0.75
var tier_good: float = 0.75
var tier_poor: float = 0.50
var tier_failing: float = 0.25
var tier_critical_event: float = 0.20
var poor_civilian_speed_mult: float = 0.90
var damage: Dictionary = {}
var repair_crew_hours_base: float = 0.35
var repair_min_tiles: int = 4
var under_construction_seed: float = 0.10
var auto_repair_thresholds: Array = []
var auto_repair_default_threshold: float = 0.40
var auto_repair_default_daily_cap: int = 25000
var auto_repair_max_jobs_per_day: int = 3

var block_template_tiles_per_block: int = 87
var block_template_avenue_tiles: int = 60
var block_template_street_tiles: int = 27
var block_template_crew_hours: float = 97.5
var block_template_baseline_decay_per_game_day: float = 0.6030
var core_damage_fraction_accrual_per_gh: float = 0.28548
var work_units_per_crew_hour: int = 100
var snap_radius_tiles: int = 6
var access_radius_tiles: int = 1
var avenue_gate_radius_tiles: int = 4
var generic_crew_speed_mult: float = 0.70
var road_crew_speed_mult: float = 1.00
var road_crew_unlock_city_level: int = 3

var max_routes_per_tick: int = 6
var emergency_overflow: int = 3
var max_expansions_per_tick: int = 1500
var max_expansions_per_route: int = 600
var max_route_ticks: int = 6
var route_cache_size: int = 256
var dispatch_candidates: int = 3
var priority_age_ticks: int = 8
var epsilon_critical: float = 1.00
var epsilon_routine: float = 1.25
var critical_priority_max: int = 1
var detour_factor: float = 1.25
var practical_congestion_coeff: float = 0.45
var estimate_class_mult_max: float = 1.25
var cong_quant: float = 0.05
var rebuild_tile_budget: int = 2048
var component_bfs_budget: int = 4000
var perf_budget_ms_per_tick: float = 4.0
var hierarchical_trigger_road_tiles: int = 8000
var hierarchical_trigger_median_expansions: int = 800

var civ_density_k: float = 0.9
var civ_base_speed_mpgm: float = 34.0
var civ_max_cars_per_edge: int = 6
var civ_caps: Dictionary = {}
var civ_speed_congestion_coeff: float = 0.325
var civ_speed_jitter_min: float = 0.85
var civ_speed_jitter_max: float = 1.15
var civ_headlights_on_hour: int = 19
var civ_headlights_off_hour: int = 6
var civ_trip_hops_min: int = 2
var civ_trip_hops_max: int = 6
var civ_kind_weights: Dictionary = {}

var hazard_condition_coeff: float = 0.40
var hazard_condition_threshold: float = 0.75

var aq_w_dist_1: float = 1.00
var aq_w_dist_2: float = 0.85
var aq_w_dist_3_6: float = 0.60
var aq_w_dist_none: float = 0.00
var aq_w_class_avenue: float = 1.00
var aq_w_class_street: float = 0.90
var aq_w_state_normal: float = 1.00
var aq_w_state_soft: float = 0.55
var aq_w_state_hard: float = 0.20
var aq_w_state_no_station: float = 0.00


func _init(data: Dictionary = {}) -> void:
	if not data.is_empty():
		load_from(data)


static func from_file(path: String = "res://data/roads.json") -> RoadTunables:
	return RoadTunables.new(StarterCityLoader.read_json(path))


func is_valid() -> bool:
	return errors.is_empty()


func load_from(data: Dictionary) -> bool:
	errors.clear()
	if data.is_empty():
		errors.append("roads tunables empty")
		return false
	version = int(data.get("version", 0))

	var class_rows: Dictionary = data.get("classes", {})
	for key in _sorted(class_rows):
		var row: Dictionary = class_rows[key]
		classes[int(row.get("id", 0))] = {
			"name": String(key),
			"doc06_name": String(row.get("doc06_name", "")),
			"road_class_mult": float(row.get("road_class_mult", 1.0)),
			"k_base": float(row.get("k_base", 1.0)),
			"s_cong": float(row.get("s_cong", 0.8)),
			"build_crew_hours": float(row.get("build_crew_hours", 0.5)),
			"condition_base_decay": float(row.get("condition_base_decay", 0.009)),
			"signal_min_degree": int(row.get("signal_min_degree", 4)),
			"upgrade_crew_hours": float(row.get("upgrade_from_street_crew_hours", 0.0)),
		}
	if not classes.has(CLASS_STREET) or not classes.has(CLASS_AVENUE):
		errors.append("roads.classes must define street (id 1) and avenue (id 2)")

	var rc_rows: Dictionary = data.get("route_classes", {})
	for key in _sorted(rc_rows):
		var row: Dictionary = rc_rows[key]
		route_classes[int(row.get("id", 0))] = {
			"name": String(key),
			"cong_relief": float(row.get("cong_relief", 0.0)),
			"node_relief": float(row.get("node_relief", 0.0)),
			"wx_resist": float(row.get("wx_resist", 0.0)),
		}
	if route_classes.size() != 4:
		errors.append("roads.route_classes must define exactly 4 rows")

	var cost: Dictionary = data.get("cost", {})
	tile_m = float(cost.get("tile_m", tile_m))
	cond_penalty_max = float(cost.get("cond_penalty_max", cond_penalty_max))
	desperate_block_mult = float(cost.get("desperate_block_mult", desperate_block_mult))
	reverse_penalty_gm = float(cost.get("reverse_penalty_gm", reverse_penalty_gm))
	speed_override_min = float(cost.get("speed_override_min", speed_override_min))
	congestion_index_max = float(cost.get("congestion_index_max", congestion_index_max))

	var nd: Dictionary = data.get("node_delay", {})
	stop_delay_gm = float(nd.get("stop_delay_gm", stop_delay_gm))
	signal_delay_gm = float(nd.get("signal_delay_gm", signal_delay_gm))
	dark_signal_delay_gm = float(nd.get("dark_signal_delay_gm", dark_signal_delay_gm))
	dark_congestion_coeff = float(nd.get("dark_congestion_coeff", dark_congestion_coeff))
	powered_congestion_coeff = float(nd.get("powered_congestion_coeff", powered_congestion_coeff))

	var cg: Dictionary = data.get("congestion", {})
	smooth_per_game_minute = float(cg.get("smooth_per_game_minute", smooth_per_game_minute))
	dens_k = float(cg.get("dens_k", dens_k))
	dens_min = float(cg.get("dens_min", dens_min))
	dens_max = float(cg.get("dens_max", dens_max))
	dens_radius_tiles = int(cg.get("dens_radius_tiles", dens_radius_tiles))
	spillback_hop1 = float(cg.get("spillback_hop1", spillback_hop1))
	spillback_hop2 = float(cg.get("spillback_hop2", spillback_hop2))
	dark_signal_add = float(cg.get("dark_signal_add", dark_signal_add))
	max_active_closures = int(cg.get("max_active_closures", max_active_closures))
	event_peak = float(cg.get("event_peak", event_peak))
	event_radius_tiles = int(cg.get("event_radius_tiles", event_radius_tiles))
	event_inbound_lead_gm = int(cg.get("event_inbound_lead_gm", event_inbound_lead_gm))
	event_outbound_tail_gm = int(cg.get("event_outbound_tail_gm", event_outbound_tail_gm))
	event_during_factor = float(cg.get("event_during_factor", event_during_factor))
	default_profile_weights = cg.get("default_profile_weights",
			{"res": 0.55, "com": 0.30, "ind": 0.05, "civ": 0.10})

	var curves: Dictionary = data.get("tod_curves", {})
	for key in _sorted(curves):
		var samples: Array = curves[key]
		if samples.size() != 24:
			errors.append("tod_curve %s has %d samples, expected 24" % [key, samples.size()])
			continue
		var typed: Array[float] = []
		for s in samples:
			typed.append(float(s))
		tod_curves[String(key)] = typed
	for required in ["res", "com", "ind", "civ"]:
		if not tod_curves.has(required):
			errors.append("tod_curves missing profile " + required)

	var wx: Dictionary = data.get("weather", {})
	for key in _sorted(wx):
		var row: Dictionary = wx[key]
		weather[String(key)] = {
			"slowdown": float(row.get("slowdown", 0.0)),
			"cong_add": float(row.get("cong_add", 0.0)),
			"wear": float(row.get("wear", 0.0)),
		}
	if not weather.has("clear"):
		errors.append("weather table missing 'clear'")

	var cl: Dictionary = data.get("closures", {})
	closure_dominance = (cl.get("dominance_order", []) as Array).duplicate()
	soft_block_second_chance = (cl.get("soft_block_second_chance", []) as Array).duplicate()
	var causes: Dictionary = cl.get("causes", {})
	for key in _sorted(causes):
		var row: Dictionary = causes[key]
		var mults: Array[float] = []
		for m in row.get("mult", []):
			mults.append(float(m))
		if mults.size() != 4:
			errors.append("closure cause %s needs 4 class multipliers" % key)
			continue
		closure_causes[String(key)] = {
			"mult": mults,
			"cong_add": float(row.get("cong_add", 0.0)),
			"hard": bool(row.get("hard", false)),
			"auto_expire_gm": int(row.get("auto_expire_gm", -1)),
		}
	flood_deep_to_shallow_depth_m = float(cl.get("flood_deep_to_shallow_depth_m",
			flood_deep_to_shallow_depth_m))
	flood_shallow_clear_depth_m = float(cl.get("flood_shallow_clear_depth_m",
			flood_shallow_clear_depth_m))

	var cd: Dictionary = data.get("condition", {})
	congestion_wear_coeff = float(cd.get("congestion_wear_coeff", congestion_wear_coeff))
	var tiers: Dictionary = cd.get("tiers", {})
	tier_good = float(tiers.get("good", tier_good))
	tier_poor = float(tiers.get("poor", tier_poor))
	tier_failing = float(tiers.get("failing", tier_failing))
	tier_critical_event = float(tiers.get("critical_event", tier_critical_event))
	poor_civilian_speed_mult = float(cd.get("poor_civilian_speed_mult", poor_civilian_speed_mult))
	damage = cd.get("damage", {})
	repair_crew_hours_base = float(cd.get("repair_crew_hours_base", repair_crew_hours_base))
	repair_min_tiles = int(cd.get("repair_min_tiles", repair_min_tiles))
	under_construction_seed = float(cd.get("under_construction_seed", under_construction_seed))
	auto_repair_thresholds = (cd.get("auto_repair_thresholds", []) as Array).duplicate()
	auto_repair_default_threshold = float(cd.get("auto_repair_default_threshold",
			auto_repair_default_threshold))
	auto_repair_default_daily_cap = int(cd.get("auto_repair_default_daily_cap",
			auto_repair_default_daily_cap))
	auto_repair_max_jobs_per_day = int(cd.get("auto_repair_max_jobs_per_day",
			auto_repair_max_jobs_per_day))

	var bd: Dictionary = data.get("build", {})
	block_template_tiles_per_block = int(bd.get("block_template_tiles_per_block",
			block_template_tiles_per_block))
	block_template_avenue_tiles = int(bd.get("block_template_avenue_tiles",
			block_template_avenue_tiles))
	block_template_street_tiles = int(bd.get("block_template_street_tiles",
			block_template_street_tiles))
	block_template_crew_hours = float(bd.get("block_template_crew_hours",
			block_template_crew_hours))
	block_template_baseline_decay_per_game_day = float(
			bd.get("block_template_baseline_decay_per_game_day",
			block_template_baseline_decay_per_game_day))
	core_damage_fraction_accrual_per_gh = float(bd.get("core_damage_fraction_accrual_per_gh",
			core_damage_fraction_accrual_per_gh))
	work_units_per_crew_hour = int(bd.get("work_units_per_crew_hour", work_units_per_crew_hour))
	snap_radius_tiles = int(bd.get("snap_radius_tiles", snap_radius_tiles))
	access_radius_tiles = int(bd.get("access_radius_tiles", access_radius_tiles))
	avenue_gate_radius_tiles = int(bd.get("avenue_gate_radius_tiles", avenue_gate_radius_tiles))
	generic_crew_speed_mult = float(bd.get("generic_crew_speed_mult", generic_crew_speed_mult))
	road_crew_speed_mult = float(bd.get("road_crew_speed_mult", road_crew_speed_mult))
	road_crew_unlock_city_level = int(bd.get("road_crew_unlock_city_level",
			road_crew_unlock_city_level))

	var rt: Dictionary = data.get("routing", {})
	max_routes_per_tick = int(rt.get("max_routes_per_tick", max_routes_per_tick))
	emergency_overflow = int(rt.get("emergency_overflow", emergency_overflow))
	max_expansions_per_tick = int(rt.get("max_expansions_per_tick", max_expansions_per_tick))
	max_expansions_per_route = int(rt.get("max_expansions_per_route", max_expansions_per_route))
	max_route_ticks = int(rt.get("max_route_ticks", max_route_ticks))
	route_cache_size = int(rt.get("route_cache_size", route_cache_size))
	dispatch_candidates = int(rt.get("dispatch_candidates", dispatch_candidates))
	priority_age_ticks = int(rt.get("priority_age_ticks", priority_age_ticks))
	epsilon_critical = float(rt.get("epsilon_critical", epsilon_critical))
	epsilon_routine = float(rt.get("epsilon_routine", epsilon_routine))
	critical_priority_max = int(rt.get("critical_priority_max", critical_priority_max))
	detour_factor = float(rt.get("detour_factor", detour_factor))
	practical_congestion_coeff = float(rt.get("practical_congestion_coeff",
			practical_congestion_coeff))
	estimate_class_mult_max = float(rt.get("estimate_class_mult_max", estimate_class_mult_max))
	cong_quant = float(rt.get("cong_quant", cong_quant))
	rebuild_tile_budget = int(rt.get("rebuild_tile_budget", rebuild_tile_budget))
	component_bfs_budget = int(rt.get("component_bfs_budget", component_bfs_budget))
	perf_budget_ms_per_tick = float(rt.get("perf_budget_ms_per_tick", perf_budget_ms_per_tick))
	hierarchical_trigger_road_tiles = int(rt.get("hierarchical_trigger_road_tiles",
			hierarchical_trigger_road_tiles))
	hierarchical_trigger_median_expansions = int(rt.get(
			"hierarchical_trigger_median_expansions", hierarchical_trigger_median_expansions))

	var ct: Dictionary = data.get("civilian_traffic", {})
	civ_density_k = float(ct.get("density_k", civ_density_k))
	civ_base_speed_mpgm = float(ct.get("base_speed_mpgm", civ_base_speed_mpgm))
	civ_max_cars_per_edge = int(ct.get("max_cars_per_edge", civ_max_cars_per_edge))
	civ_caps = {
		"performance": int(ct.get("global_cap_performance", 40)),
		"balanced": int(ct.get("global_cap_balanced", 90)),
		"high": int(ct.get("global_cap_high", 160)),
	}
	civ_speed_congestion_coeff = float(ct.get("speed_congestion_coeff", civ_speed_congestion_coeff))
	civ_speed_jitter_min = float(ct.get("speed_jitter_min", civ_speed_jitter_min))
	civ_speed_jitter_max = float(ct.get("speed_jitter_max", civ_speed_jitter_max))
	civ_headlights_on_hour = int(ct.get("headlights_on_hour", civ_headlights_on_hour))
	civ_headlights_off_hour = int(ct.get("headlights_off_hour", civ_headlights_off_hour))
	civ_trip_hops_min = int(ct.get("trip_hops_min", civ_trip_hops_min))
	civ_trip_hops_max = int(ct.get("trip_hops_max", civ_trip_hops_max))
	civ_kind_weights = ct.get("kind_weights", {"car": 0.7, "van": 0.2, "truck": 0.1})

	var hz: Dictionary = data.get("hazard", {})
	hazard_condition_coeff = float(hz.get("condition_coeff", hazard_condition_coeff))
	hazard_condition_threshold = float(hz.get("condition_threshold", hazard_condition_threshold))

	var aq: Dictionary = data.get("access_quality", {})
	aq_w_dist_1 = float(aq.get("w_dist_1_tile", aq_w_dist_1))
	aq_w_dist_2 = float(aq.get("w_dist_2_tiles", aq_w_dist_2))
	aq_w_dist_3_6 = float(aq.get("w_dist_3_to_6_tiles", aq_w_dist_3_6))
	aq_w_dist_none = float(aq.get("w_dist_none", aq_w_dist_none))
	aq_w_class_avenue = float(aq.get("w_class_avenue_within_4", aq_w_class_avenue))
	aq_w_class_street = float(aq.get("w_class_street_only", aq_w_class_street))
	aq_w_state_normal = float(aq.get("w_state_normal", aq_w_state_normal))
	aq_w_state_soft = float(aq.get("w_state_soft_closed", aq_w_state_soft))
	aq_w_state_hard = float(aq.get("w_state_hard_blocked", aq_w_state_hard))
	aq_w_state_no_station = float(aq.get("w_state_no_station_in_component", aq_w_state_no_station))

	return errors.is_empty()


# ------------------------------------------------------------------- accessors

func class_row(road_class: int) -> Dictionary:
	return classes.get(road_class, classes.get(CLASS_STREET, {}))


func class_mult(road_class: int) -> float:
	return float(class_row(road_class).get("road_class_mult", 1.0))


func k_base(road_class: int) -> float:
	return float(class_row(road_class).get("k_base", 1.0))


func s_cong(road_class: int) -> float:
	return float(class_row(road_class).get("s_cong", 0.8))


func build_crew_hours(road_class: int) -> float:
	return float(class_row(road_class).get("build_crew_hours", 0.5))


func base_decay(road_class: int) -> float:
	return float(class_row(road_class).get("condition_base_decay", 0.009))


func signal_min_degree(road_class: int) -> int:
	return int(class_row(road_class).get("signal_min_degree", 4))


func class_name_of(road_class: int) -> String:
	return String(class_row(road_class).get("name", "street")).to_upper()


func route_row(route_class: int) -> Dictionary:
	return route_classes.get(route_class, {"cong_relief": 0.0, "node_relief": 0.0, "wx_resist": 0.0})


func cong_relief(route_class: int) -> float:
	return float(route_row(route_class).get("cong_relief", 0.0))


func node_relief(route_class: int) -> float:
	return float(route_row(route_class).get("node_relief", 0.0))


func wx_resist(route_class: int) -> float:
	return float(route_row(route_class).get("wx_resist", 0.0))


func weather_row(state: String) -> Dictionary:
	return weather.get(state, weather.get("clear", {"slowdown": 0.0, "cong_add": 0.0, "wear": 0.0}))


func cause_row(cause: String) -> Dictionary:
	return closure_causes.get(cause, {})


## Rank in the dominance order; lower = more severe. Unknown causes rank last.
func cause_rank(cause: String) -> int:
	var index := closure_dominance.find(cause)
	return index if index >= 0 else closure_dominance.size() + 1


func damage_delta(key: String) -> float:
	return float(damage.get(key, 0.0))


func civ_cap(preset: String) -> int:
	return int(civ_caps.get(preset, civ_caps.get("balanced", 90)))


static func _sorted(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
