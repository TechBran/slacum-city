class_name PressureZone
extends RefCounted
## A derived aggregate (doc 05 §2.2): the connected component of the LIVE main
## graph, plus everything the per-tick mass balance needs. Never authored,
## never saved as a whole — `rebuild_zones()` recreates it and only the fields
## in `persisted_state()` survive a save, keyed by the stable `zone_key`
## (the smallest facility node id in the component).

var zone_key: String = ""
var index: int = -1  # dense, sorted-by-zone_key index used by `zone_of_tile`
var dead: bool = true  # no live supply node in the component

var node_ids: Array = []  # sorted
var edge_ids: Array = []  # sorted
var pump_ids: Array = []  # sorted
var tank_ids: Array = []  # sorted
var source_ids: Array = []  # sorted
var treatment_ids: Array = []  # sorted
var booster_ids: Array = []  # sorted

# --- topology-derived (recomputed on rebuild only) ------------------------
var head_m: float = 0.0
var feed_capacity_m3h: float = 0.0
var rest_capacity_m3h: float = 0.0
var upstream_cap_m3h: float = 0.0
var tank_capacity_m3: float = 0.0
var building_count: int = 0
## Mains incident to a supply node — the simplified min-cut set (§2.5) — and
## the segments currently leaking. Both are pure topology, so they are resolved
## on rebuild and read, never recomputed, per tick.
var feed_edge_ids: Array = []
var feed_edge_set: Dictionary = {}  # O(1) membership for the per-tick flow split
var broken_edge_ids: Array = []
var live_tank_ids: Array = []
var live_pump_ids: Array = []

# --- demand cache (event-driven, §2.4) ------------------------------------
var res_base: float = 0.0
var com_base: float = 0.0
var proc_base: float = 0.0

# --- per-tick ------------------------------------------------------------
var demand_m3h: float = 0.0
var supply_m3h: float = 0.0
var delivered_m3h: float = 0.0
var leak_m3h: float = 0.0
var fire_draw_m3h: float = 0.0
var tank_volume_m3: float = 0.0
var ratio: float = 1.0
var break_penalty: float = 0.0

# --- persisted -----------------------------------------------------------
var pressure: float = 1.0
var contaminated: bool = false
var contaminated_until_minutes: float = 0.0
var flush_remaining_minutes: float = 0.0
var no_supply_hours: float = 0.0
var shortage_timer_min: float = 0.0
var shortage_latched: bool = false
var tank_low_latched: bool = false
var tank_empty_latched: bool = false
var pressure_low_latched: bool = false
var offline_latched: bool = false


func level_frac() -> float:
	if tank_capacity_m3 <= 0.0:
		return 1.0
	return clampf(tank_volume_m3 / tank_capacity_m3, 0.0, 1.0)


func has_tanks() -> bool:
	return tank_capacity_m3 > 0.0


## ∞ (reported as -1.0, shown as "—") while supply covers demand.
func buffer_hours() -> float:
	var deficit := demand_m3h - supply_m3h
	if deficit <= 0.0:
		return -1.0
	return tank_volume_m3 / maxf(deficit, 0.001)


## §2.11 upgrade gate input, doc 02's check E_WATER_HEADROOM.
func headroom_m3h() -> float:
	return maxf(0.0, supply_m3h - demand_m3h)


## §5.8 overlay band — colour AND icon, never colour alone (constitution §11).
func color_band(bands: Dictionary) -> String:
	if pressure >= float(bands.get("normal", 0.60)):
		return "normal"
	if pressure >= float(bands.get("warn", 0.35)):
		return "warn"
	if pressure >= float(bands.get("critical", 0.10)):
		return "critical"
	return "none"


func persisted_state() -> Dictionary:
	return {
		"zone_key": zone_key, "pressure": pressure, "contaminated": contaminated,
		"contaminated_until_minutes": contaminated_until_minutes,
		"flush_remaining_minutes": flush_remaining_minutes,
		"no_supply_hours": no_supply_hours, "shortage_timer_min": shortage_timer_min,
		"shortage_latched": shortage_latched,
		"tank_low_latched": tank_low_latched, "tank_empty_latched": tank_empty_latched,
		"pressure_low_latched": pressure_low_latched, "offline_latched": offline_latched,
	}


func apply_persisted_state(record: Dictionary) -> void:
	pressure = float(record.get("pressure", 1.0))
	contaminated = bool(record.get("contaminated", false))
	contaminated_until_minutes = float(record.get("contaminated_until_minutes", 0.0))
	flush_remaining_minutes = float(record.get("flush_remaining_minutes", 0.0))
	no_supply_hours = float(record.get("no_supply_hours", 0.0))
	shortage_timer_min = float(record.get("shortage_timer_min", 0.0))
	shortage_latched = bool(record.get("shortage_latched", false))
	tank_low_latched = bool(record.get("tank_low_latched", false))
	tank_empty_latched = bool(record.get("tank_empty_latched", false))
	pressure_low_latched = bool(record.get("pressure_low_latched", false))
	offline_latched = bool(record.get("offline_latched", false))
