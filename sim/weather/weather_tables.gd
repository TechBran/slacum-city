class_name WeatherTables
extends RefCounted
## Validated view of `data/weather.json` (doc 07 §8.1). Pure data — no clock,
## no RNG, no engine. `load_from()` takes the parsed dictionary; the file read
## lives in `load_from_file()` for the app shell and headless tests only
## (same precedent as BuildingCatalog / StarterCityLoader).
##
## The 17 effect channels of §2.2 are the ONLY weather multiplier interface in
## the game (report 98 C-57): every band is `[min, max]`, resolved as
## `lerp(min, max, intensity)`. `fire_escalation_mult` is flat by ruling
## (RR-15) — its endpoints are equal, so the general lerp returns the constant.

const SCHEMA_VERSION := 1

## Canonical iteration order. NEVER iterate the parsed dictionaries directly:
## a weighted pick over unsorted keys is a determinism bug (constitution §5).
const STATES: Array[String] = [
	"CLEAR", "CLOUDY", "RAIN", "HEAVY_RAIN", "THUNDERSTORM", "HEAT_WAVE",
]
const SEASONS: Array[String] = ["SPRING", "SUMMER", "AUTUMN", "WINTER"]

## §2.2 — 17 channels. The three fire channels answer three different questions
## and may never be substituted for one another (§2.2.1, RR-15).
const CHANNELS: Array[String] = [
	"power_load_mult", "water_demand_mult", "road_speed_mult",
	"fire_spread_mult", "fire_escalation_mult", "fire_ignition_mult",
	"incident_crime_mult", "incident_traffic_mult", "incident_utility_mult",
	"line_failure_rate_mult", "outage_health_risk_mult", "solar_output_mult",
	"construction_speed_mult", "condition_decay_mult",
	"wind_kph", "precip_mm_h", "temp_offset_c",
]

## Doc 02's short call-site names resolve onto the canonical channels (C-57).
const ALIASES := {
	"load_mult": "power_load_mult",
	"water_mult": "water_demand_mult",
	"decay_mult": "condition_decay_mult",
	"fire_mult": "fire_ignition_mult",
	"build_mult": "construction_speed_mult",
}

var horizon_min: int = 1440
var quantize_min: int = 15
var diurnal_amp_c: float = 6.0
var diurnal_peak_min_of_day: int = 900
var precip01_scale_mm_h: float = 35.0
var segment_crossfade_gs: int = 60
var transformer_heat: Dictionary = {"ref_temp_c": 20.0, "per_degree": 0.04, "clamp": [0.7, 2.4]}
var storm_cell: Dictionary = {}
var flood: Dictionary = {}
var forecast: Dictionary = {}
var modifier_channels: Dictionary = {}
var errors: PackedStringArray = []

var _states: Dictionary = {}  # state -> raw state block
var _transitions: Dictionary = {}  # from -> {to: weight}
var _season_temp: Dictionary = {}  # season -> temp_base_c
var _season_mult: Dictionary = {}  # season -> {state: mult}


static func load_from_file(path: String) -> WeatherTables:
	var tables := WeatherTables.new()
	if not FileAccess.file_exists(path):
		tables.errors.append("weather data missing: " + path)
		return tables
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		tables.errors.append("weather data is not a JSON object: " + path)
		return tables
	tables.load_from(parsed)
	return tables


func load_from(data: Dictionary) -> bool:
	errors.clear()
	if int(data.get("schema_version", -1)) != SCHEMA_VERSION:
		errors.append("weather.json schema_version must be %d" % SCHEMA_VERSION)
		return false  # a loader mismatch is a hard error, never a silent default
	horizon_min = int(data.get("horizon_min", 1440))
	quantize_min = int(data.get("quantize_min", 15))
	diurnal_amp_c = float(data.get("diurnal_amp_c", 6.0))
	diurnal_peak_min_of_day = int(data.get("diurnal_peak_min_of_day", 900))
	precip01_scale_mm_h = float(data.get("precip01_scale_mm_h", 35.0))
	segment_crossfade_gs = int(data.get("segment_crossfade_gs", 60))
	transformer_heat = data.get("transformer_heat", transformer_heat)
	storm_cell = data.get("storm_cell", {})
	flood = data.get("flood", {})
	forecast = data.get("forecast", {})
	modifier_channels = data.get("modifier_channels", {})
	_states = data.get("states", {})
	_transitions = data.get("transitions", {})
	var seasons: Dictionary = data.get("seasons", {}).get("table", {})
	_season_temp.clear()
	_season_mult.clear()
	for season in SEASONS:
		if not seasons.has(season):
			errors.append("seasons.table missing " + season)
			continue
		_season_temp[season] = float(seasons[season].get("temp_base_c", 20.0))
		_season_mult[season] = seasons[season].get("transition_mult", {})
	_validate()
	return errors.is_empty()


func _validate() -> void:
	for state in STATES:
		if not _states.has(state):
			errors.append("states missing " + state)
			continue
		var block: Dictionary = _states[state]
		if int(block.get("dur_min", 0)) <= 0 or int(block.get("dur_max", 0)) < int(block.get("dur_min", 0)):
			errors.append("%s: bad duration bounds" % state)
		if float(block.get("intensity_gamma", 0.0)) <= 0.0:
			errors.append("%s: intensity_gamma must be > 0" % state)
		var effects: Dictionary = block.get("effects", {})
		for channel in CHANNELS:
			if not effects.has(channel):
				errors.append("%s: missing effect channel %s" % [state, channel])
				continue
			var band: Array = effects[channel]
			if band.size() != 2:
				errors.append("%s.%s: band must be [min, max]" % [state, channel])
		if not _transitions.has(state):
			errors.append("transitions missing row " + state)
			continue
		var row: Dictionary = _transitions[state]
		var total := 0.0
		for to_state in STATES:
			if to_state == state and row.has(to_state) and float(row[to_state]) != 0.0:
				errors.append("%s: self-transition must not exist" % state)
			total += float(row.get(to_state, 0.0))
		if absf(total - 1.0) > 1e-6:
			errors.append("%s: transition row sums to %f, not 1.0" % [state, total])
	# The channel list is closed: an unlisted key in the data is a typo, not a
	# feature — it would silently never be read.
	for state in STATES:
		var effects: Dictionary = _states.get(state, {}).get("effects", {})
		for key in effects:
			if not CHANNELS.has(String(key)):
				errors.append("%s: unknown effect channel '%s'" % [state, key])


func is_valid() -> bool:
	return errors.is_empty()


func has_state(state: String) -> bool:
	return _states.has(state)


## Canonical channel name for a raw name, resolving doc 02's aliases (C-57).
## "" when the name is not a channel at all.
static func canonical_channel(channel: String) -> String:
	if ALIASES.has(channel):
		return String(ALIASES[channel])
	return channel if CHANNELS.has(channel) else ""


func effect_band(state: String, channel: String) -> Array:
	var canonical := canonical_channel(channel)
	if canonical == "" or not _states.has(state):
		return []
	return _states[state]["effects"][canonical]


## §2.2: the live value is lerp(min, max, intensity). Flat bands (min == max)
## fall out of the same expression — no special case (RR-15).
func effect(state: String, channel: String, intensity: float) -> float:
	var band := effect_band(state, channel)
	if band.is_empty():
		return NAN
	return lerpf(float(band[0]), float(band[1]), clampf(intensity, 0.0, 1.0))


func duration_bounds(state: String) -> Array:
	return [int(_states[state]["dur_min"]), int(_states[state]["dur_max"])]


func intensity_gamma(state: String) -> float:
	return float(_states[state]["intensity_gamma"])


func season_name(season_index: int) -> String:
	return SEASONS[posmod(season_index, SEASONS.size())]


func season_temp_base_c(season_index: int) -> float:
	return float(_season_temp.get(season_name(season_index), 20.0))


## Base row ⊙ season multiplier, renormalised, in canonical STATES order.
## Returns [[to_state, probability], …] — an Array, so the weighted pick can
## never depend on Dictionary iteration order.
func transition_row(from_state: String, season_index: int) -> Array:
	var row: Dictionary = _transitions.get(from_state, {})
	var mult: Dictionary = _season_mult.get(season_name(season_index), {})
	var weights: Array = []
	var total := 0.0
	for to_state in STATES:
		if to_state == from_state:
			continue
		var w := float(row.get(to_state, 0.0)) * float(mult.get(to_state, 1.0))
		if w <= 0.0:
			continue
		weights.append([to_state, w])
		total += w
	var out: Array = []
	if total <= 0.0:
		# Degenerate season (every edge zeroed): fall back to the unweighted row.
		for to_state in STATES:
			if to_state == from_state:
				continue
			var w := float(row.get(to_state, 0.0))
			if w > 0.0:
				out.append([to_state, w])
				total += w
		for entry in out:
			entry[1] = float(entry[1]) / total
		return out
	for entry in weights:
		out.append([entry[0], float(entry[1]) / total])
	return out


## Weighted pick over a canonical-order [[key, probability], …] list.
static func pick_weighted(entries: Array, u: float) -> Variant:
	var cumulative := 0.0
	for entry in entries:
		cumulative += float(entry[1])
		if u < cumulative:
			return entry[0]
	return entries[entries.size() - 1][0] if not entries.is_empty() else null


## Segment boundaries land on whole SimTicks (§2.1): 15 game-minutes = 60 ticks.
func quantize(minutes: int) -> int:
	var q := maxi(1, quantize_min)
	return maxi(q, int(roundf(float(minutes) / float(q))) * q)
