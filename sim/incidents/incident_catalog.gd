class_name IncidentCatalog
extends RefCounted
## Parsed `data/incidents.json` + `data/vehicles.json` + `data/dispatch.json`
## (doc 06 §8 — one document, three files). Every balance number this system
## uses is read from here; `sim/incidents/` contains no magic number that is
## not a pure algebraic identity.
##
## Validation is deliberately loud: the grep guards report 98 asks for
## (tests 33 / 38) are enforced HERE as well as in the test suite, so a
## reintroduced price or weather table fails the boot, not just CI.

## C-07 / R-14 and C-49: none of these keys may exist in doc 06's data.
const FORBIDDEN_KEYS := [
	"purchase_cost", "upkeep_per_game_hour", "dispatch_cost",
	"repair_material_base", "weather_speed_mult", "road_class_mult",
	"weather_mults", "base_fire_risk_by_archetype", "level_risk_slope",
	"s_req_base_by_archetype", "s_level_slope", "heat_mult", "rain_mult",
	"unit_slots", "crew_slots", "flood_mult", "weather_mult",
]
## RR-4: the dead winter columns died with the table they lived in.
const FORBIDDEN_WEATHER_STATE_KEYS := ["snow", "blizzard", "fog"]
## C-49: RouteProfile carries exactly these four fields.
const ROUTE_PROFILE_FIELDS := ["speed_mpgm", "siren", "ignores_closures", "capabilities"]
## RR-4 / RR-15: the six doc 07 channels doc 06 may read, and no others.
const ALLOWED_WEATHER_CHANNELS := [
	"incident_crime_mult", "fire_ignition_mult", "incident_utility_mult",
	"incident_traffic_mult", "fire_escalation_mult", "fire_spread_mult",
]

var errors: PackedStringArray = []

var globals: Dictionary = {}
var factors: Dictionary = {}
var generator_base_rates: Dictionary = {}
var generator_order: Array = []
var rng_streams: Dictionary = {}
var weather_channels: Dictionary = {}
var fire_weather_channels: Dictionary = {}
var power_event_map: Dictionary = {}
var tutorial: Dictionary = {}
var fire: Dictionary = {}
var reward: Dictionary = {}
var difficulty_escalation: Dictionary = {}

var vehicle_types: Dictionary = {}
var vehicle_type_ids: Array = []

var scoring: Dictionary = {}
var exposure: Dictionary = {}
var assignment: Dictionary = {}
var policy_defaults: Dictionary = {}
var response_score_ewma_alpha: float = 0.05

var _types: Dictionary = {}  # "crime" / "storm_damage/blocked_road" -> merged row
var _type_ids: Array = []
var _parent_types: Array = []


func _init(incidents_data: Dictionary = {}, vehicles_data: Dictionary = {},
		dispatch_data: Dictionary = {}) -> void:
	_load_incidents(incidents_data)
	_load_vehicles(vehicles_data)
	_load_dispatch(dispatch_data)


static func load_from_files() -> IncidentCatalog:
	return IncidentCatalog.new(
			StarterCityLoader.read_json("res://data/incidents.json"),
			StarterCityLoader.read_json("res://data/vehicles.json"),
			StarterCityLoader.read_json("res://data/dispatch.json"))


func is_valid() -> bool:
	return errors.is_empty()


# ------------------------------------------------------------------ queries

## Merged row for "crime" or for "storm_damage/blocked_road" — a subtype row
## overrides its parent's keys (§3.1) and inherits everything else.
func type_row(type_id: String, subtype: String = "") -> Dictionary:
	if subtype != "" and _types.has(type_id + "/" + subtype):
		return _types[type_id + "/" + subtype]
	return _types.get(type_id, {})


func has_type(type_id: String) -> bool:
	return _types.has(type_id)


func type_ids() -> Array:
	return _type_ids.duplicate()


func parent_type_ids() -> Array:
	return _parent_types.duplicate()


func subtype_ids(type_id: String) -> Array:
	var out: Array = []
	var prefix := type_id + "/"
	for key in _type_ids:
		if String(key).begins_with(prefix):
			out.append(String(key).substr(prefix.length()))
	out.sort()
	return out


func global_value(key: String, fallback: float = 0.0) -> float:
	return float(globals.get(key, fallback))


func global_int(key: String, fallback: int = 0) -> int:
	return int(globals.get(key, fallback))


func factor(group: String, key: String, fallback: float = 0.0) -> float:
	var block: Dictionary = factors.get(group, {})
	return float(block.get(key, fallback))


func stream_for(type_id: String) -> String:
	return String(rng_streams.get(type_id, "incidents"))


func weather_channel_for(type_id: String) -> String:
	var value: Variant = weather_channels.get(type_id, null)
	return "" if value == null else String(value)


func vehicle_type(type_id: String) -> Dictionary:
	return vehicle_types.get(type_id, {})


func vehicle_types_for_station(archetype: String) -> Array:
	var out: Array = []
	for type_id in vehicle_type_ids:
		var row: Dictionary = vehicle_types[type_id]
		if String(row.get("home_department_station", "")) == archetype:
			out.append(type_id)
			continue
		for extra in row.get("also_housed_at", []):
			if String(extra) == archetype:
				out.append(type_id)
				break
	return out


## Doc 06 §2.8: S_req(b) = 0.50 × (fire_load / 20) ^ 0.45. The consequence
## ladder is doc 02's `fire_load` and nothing else (C-43 / R-12).
func s_req_for_fire_load(fire_load: float) -> float:
	var anchor := float(fire.get("s_req_anchor", 0.50))
	var load_anchor := maxf(1.0, float(fire.get("fire_load_anchor", 20)))
	var exponent := float(fire.get("s_req_exp", 0.45))
	if fire_load <= 0.0:
		return anchor
	return anchor * pow(fire_load / load_anchor, exponent)


func stage_mult(tier: int) -> float:
	var table: Array = fire.get("stage_mult", [])
	var index := clampi(tier, 0, table.size() - 1)
	return float(table[index]) if index >= 0 and not table.is_empty() else 1.0


func g_stage(tier: int) -> float:
	var table: Array = fire.get("g_stage", [])
	var index := clampi(tier, 0, table.size() - 1)
	return float(table[index]) if index >= 0 and not table.is_empty() else 0.0


func spread_material_mult(archetype: String) -> float:
	var table: Dictionary = fire.get("spread_material_mult", {})
	return float(table.get(archetype, table.get("default", 1.0)))


func exposure_class(name: String) -> float:
	var table: Dictionary = factors.get("storm", {}).get("exposure_class", {})
	return float(table.get(name, 1.0))


func storm_subtype_weights() -> Dictionary:
	return factors.get("storm", {}).get("subtype_weights", {})


func power_event_row(kind: String) -> Dictionary:
	return power_event_map.get(kind, {})


# ------------------------------------------------------------------ loading

func _load_incidents(data: Dictionary) -> void:
	if data.is_empty():
		errors.append("data/incidents.json missing or unparseable")
		return
	_assert_clean("data/incidents.json", data)
	globals = data.get("globals", {})
	factors = data.get("factors", {})
	generator_base_rates = data.get("generator_base_rates", {})
	generator_order = data.get("generator_order", [])
	rng_streams = data.get("rng_streams", {})
	weather_channels = data.get("weather_channels", {})
	fire_weather_channels = data.get("fire_weather_channels", {})
	power_event_map = data.get("power_event_map", {})
	tutorial = data.get("tutorial", {})
	fire = data.get("fire", {})
	reward = data.get("reward", {})
	difficulty_escalation = data.get("difficulty_escalation", {})

	for channel_name in weather_channels.values():
		if channel_name != null and not ALLOWED_WEATHER_CHANNELS.has(String(channel_name)):
			errors.append("unknown doc 07 channel in weather_channels: %s" % channel_name)
	for channel_name in fire_weather_channels.values():
		if not ALLOWED_WEATHER_CHANNELS.has(String(channel_name)):
			errors.append("unknown doc 07 channel in fire_weather_channels: %s" % channel_name)

	var raw_types: Dictionary = data.get("types", {})
	var parent_ids := raw_types.keys()
	parent_ids.sort()
	for type_id in parent_ids:
		var row: Dictionary = (raw_types[type_id] as Dictionary).duplicate(true)
		var subtypes: Dictionary = row.get("subtypes", {})
		row.erase("subtypes")
		row["type_id"] = type_id
		row["subtype_id"] = ""
		_types[type_id] = row
		_type_ids.append(type_id)
		_parent_types.append(type_id)
		var subtype_ids_sorted := subtypes.keys()
		subtype_ids_sorted.sort()
		for subtype_id in subtype_ids_sorted:
			var merged: Dictionary = row.duplicate(true)
			for key in (subtypes[subtype_id] as Dictionary):
				merged[key] = (subtypes[subtype_id] as Dictionary)[key]
			merged["type_id"] = type_id
			merged["subtype_id"] = subtype_id
			var full_id: String = type_id + "/" + subtype_id
			_types[full_id] = merged
			_type_ids.append(full_id)
	_type_ids.sort()
	if generator_order.is_empty():
		generator_order = _parent_types.duplicate()


func _load_vehicles(data: Dictionary) -> void:
	if data.is_empty():
		errors.append("data/vehicles.json missing or unparseable")
		return
	_assert_clean("data/vehicles.json", data)
	var raw: Dictionary = data.get("types", {})
	vehicle_type_ids = raw.keys()
	vehicle_type_ids.sort()
	for type_id in vehicle_type_ids:
		var row: Dictionary = (raw[type_id] as Dictionary).duplicate(true)
		row["type_id"] = type_id
		if not row.has("economy_id"):
			errors.append("vehicle %s has no economy_id join key (C-07)" % type_id)
		var ladder: Array = row.get("capacity_per_station_level", [])
		if ladder.size() != 5:
			errors.append("vehicle %s capacity_per_station_level must have 5 rows (C-50)" % type_id)
		# JSON numbers parse as doubles; the ladder is a count, so it is an int.
		var int_ladder: Array = []
		for entry in ladder:
			int_ladder.append(int(entry))
		row["capacity_per_station_level"] = int_ladder
		vehicle_types[type_id] = row


func _load_dispatch(data: Dictionary) -> void:
	if data.is_empty():
		errors.append("data/dispatch.json missing or unparseable")
		return
	_assert_clean("data/dispatch.json", data)
	scoring = data.get("scoring", {})
	exposure = data.get("exposure", {})
	assignment = data.get("assignment", {})
	policy_defaults = data.get("policy_defaults", {})
	response_score_ewma_alpha = float(data.get("response_score_ewma_alpha", 0.05))
	var fields: Array = data.get("route_profile_fields", [])
	if fields.size() != ROUTE_PROFILE_FIELDS.size():
		errors.append("route_profile_fields must be exactly %s (C-49)" % str(ROUTE_PROFILE_FIELDS))
	else:
		for field in ROUTE_PROFILE_FIELDS:
			if not fields.has(field):
				errors.append("route_profile_fields missing %s (C-49)" % field)


## Recursive grep guard: no price, no deleted table, no weather state key.
func _assert_clean(file_label: String, value: Variant) -> void:
	match typeof(value):
		TYPE_DICTIONARY:
			for key in (value as Dictionary):
				var key_text := String(key)
				if FORBIDDEN_KEYS.has(key_text):
					errors.append("%s carries deleted key `%s` (report 98 C-07/C-42/C-43/C-49/RR-4/RR-15)"
							% [file_label, key_text])
				if FORBIDDEN_WEATHER_STATE_KEYS.has(key_text):
					errors.append("%s carries dead weather state key `%s` (RR-4)"
							% [file_label, key_text])
				_assert_clean(file_label, (value as Dictionary)[key])
		TYPE_ARRAY:
			for entry in (value as Array):
				_assert_clean(file_label, entry)
		_:
			pass
