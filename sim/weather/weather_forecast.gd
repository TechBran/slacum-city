class_name WeatherForecast
extends RefCounted
## Forecast over the committed timeline (doc 07 §2.5). Because the future is
## already decided, forecasts CONVERGE toward truth instead of jittering.
##
## All noise is derived from `hash(segment.id, forecast_refresh_index)` where
## `forecast_refresh_index = floor(now_min / refresh_min)` — a pure function of
## (segment, refresh window). Two calls inside one window are byte-identical, so
## the panel never shimmers and reopening it cannot be save-scummed. It also
## means forecasting consumes NO stream state: reading the forecast can never
## perturb the simulation (constitution §5 — the local generator here is seeded
## per query, it is not a shared/global RNG).
##
## Two inviolable honesty rules (§2.5):
##   1. No hidden severe — a Director-scheduled segment is always shown truly.
##   2. No near-term false alarms — the confusion table may never INVENT
##      THUNDERSTORM or HEAT_WAVE at lead ≤ 180 game-minutes.

var tables: WeatherTables
var timeline: WeatherTimeline


func _init(p_tables: WeatherTables, p_timeline: WeatherTimeline) -> void:
	tables = p_tables
	timeline = p_timeline


func refresh_index(now_min: int) -> int:
	var period := maxi(1, int(tables.forecast.get("refresh_min", 60)))
	return int(floorf(float(now_min) / float(period)))


func p_correct(lead_min: int) -> float:
	var config: Dictionary = tables.forecast
	var clamp_band: Array = config.get("clamp", [0.5, 0.99])
	var value := float(config.get("base_accuracy", 0.97)) \
			- float(config.get("accuracy_decay", 0.42)) * (float(lead_min) / 1440.0) \
			+ float(config.get("station_bonus", 0.0))
	return clampf(value, float(clamp_band[0]), float(clamp_band[1]))


func ui_band(lead_min: int) -> String:
	for band in tables.forecast.get("ui_bands", []):
		if lead_min <= int(band.get("max_lead_min", 0)):
			return String(band.get("mode", "exact"))
	return "probability"


## The live segment first (lead 0 — the "now" row the HUD always shows), then
## every segment starting inside `horizon_min`. A long segment such as a
## multi-day heat wave covers the whole horizon and starts no new segment, so
## without the nowcast row the panel would be blank in the middle of a crisis.
func get_forecast(now_min: int, horizon_min: int = -1) -> Array:
	var horizon := tables.horizon_min if horizon_min < 0 else horizon_min
	var index := refresh_index(now_min)
	var out: Array = []
	var live := timeline.segment_at(now_min)
	if not live.is_empty() and int(live["start_min"]) <= now_min:
		out.append(entry_for(live, now_min, index))
	for segment in timeline.segments:
		var start := int(segment["start_min"])
		var lead := start - now_min
		if lead < 0 or lead > horizon:
			continue
		out.append(entry_for(segment, now_min, index))
	return out


## The forecast as it stands for the segment that is live right now (lead 0).
func nowcast(now_min: int) -> Dictionary:
	var segment := timeline.segment_at(now_min)
	if segment.is_empty():
		return {}
	return entry_for(segment, now_min, refresh_index(now_min))


func entry_for(segment: Dictionary, now_min: int, index: int) -> Dictionary:
	var config: Dictionary = tables.forecast
	var true_state := String(segment["state"])
	var true_start := int(segment["start_min"])
	var true_intensity := float(segment["intensity"])
	var lead := maxi(0, true_start - now_min)
	var accuracy := p_correct(lead)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([int(segment["id"]), index])
	# Draw order is fixed: correctness, confusion, intensity, time.
	var correct := rng.randf() < accuracy
	# Honesty rule 1, plus the obvious: a segment that is ALREADY LIVE is not a
	# forecast, it is a window. Lead 0 is always the truth (§7 test 6), and so
	# is every Director-scheduled segment — F7 outranks forecast noise, and
	# showing the true state with a probability phrase is exactly the §2.7.2
	# beat ("Storms possible (58%)" is the true state at 58% confidence).
	var state_is_forced := lead <= 0 \
			or String(segment["source"]) == WeatherTimeline.SOURCE_DIRECTOR
	var displayed_state := true_state
	if not correct and not state_is_forced:
		displayed_state = _confuse(true_state, lead, rng.randf())
	var noise_sigma := float(config.get("intensity_noise_base", 0.06)) \
			+ float(config.get("intensity_noise_lead", 0.10)) * float(lead) / 1440.0
	var displayed_intensity := clampf(true_intensity + rng.randfn(0.0, noise_sigma), 0.0, 1.0)
	var jitter := int(config.get("time_jitter_base_min", 10)) \
			+ int(roundf(float(config.get("time_jitter_lead_min", 40)) * float(lead) / 1440.0))
	var displayed_start := true_start + rng.randi_range(-jitter, jitter)
	if lead <= 0:
		# Live weather: no noise of any kind, and full confidence.
		accuracy = 1.0
		displayed_start = true_start
		displayed_intensity = true_intensity
	return {
		"segment_id": int(segment["id"]),
		"true_state": true_state,
		"state": displayed_state,
		"intensity": displayed_intensity,
		"start_min": displayed_start,
		"true_start_min": true_start,
		"lead_min": lead,
		"p_correct": accuracy,
		"probability_pct": int(roundf(accuracy * 100.0)),
		"band": ui_band(lead),
		"event_id": int(segment.get("event_id", -1)),
		"source": String(segment["source"]),
	}


## Neighbours only — the forecast is wrong, never insane.
func _confuse(true_state: String, lead_min: int, u: float) -> String:
	var row: Dictionary = tables.forecast.get("confusion", {}).get(true_state, {})
	if row.is_empty():
		return true_state
	var no_invent_below := int(tables.forecast.get("no_invent_severe_below_lead_min", 180))
	var entries: Array = []
	var total := 0.0
	for candidate in WeatherTables.STATES:  # canonical order, never dict order
		if not row.has(candidate):
			continue
		if lead_min <= no_invent_below and _is_severe(candidate) and not _is_severe(true_state):
			continue  # honesty rule 2
		entries.append([candidate, float(row[candidate])])
		total += float(row[candidate])
	if entries.is_empty() or total <= 0.0:
		return true_state
	for entry in entries:
		entry[1] = float(entry[1]) / total
	return String(WeatherTables.pick_weighted(entries, u))


static func _is_severe(state: String) -> bool:
	return state == "THUNDERSTORM" or state == "HEAT_WAVE"
