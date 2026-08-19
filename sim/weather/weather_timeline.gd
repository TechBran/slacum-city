class_name WeatherTimeline
extends RefCounted
## The committed weather future (doc 07 §2.1). Weather is NOT rolled per tick:
## the timeline always covers at least `horizon_min` game-minutes ahead, which
## is what makes an honest forecast, a guaranteed warning lead and exact
## coarse/fine parity all possible from one mechanism.
##
## Segment := {id, state, start_min, end_min, intensity, source, event_id}
## `source ∈ {"chain", "director"}`; `event_id` is -1 for chain segments.
##
## Every draw is on the injected `weather` stream (constitution §5). Generation
## is driven purely by (last.state, season_index, rng) — never by `now_min` —
## so the fine path and the 1-hour coarse path build a byte-identical timeline.

const SOURCE_CHAIN := "chain"
const SOURCE_DIRECTOR := "director"

var tables: WeatherTables
var segments: Array[Dictionary] = []
var next_id: int = 1


func _init(p_tables: WeatherTables) -> void:
	tables = p_tables


## Seed the timeline with a first segment and fill out to the horizon.
func bootstrap(now_min: int, season_index: int, rng: RandomNumberGenerator,
		state: String = "CLEAR") -> void:
	segments.clear()
	next_id = 1
	var duration := _roll_duration(state, rng)
	var intensity := _roll_intensity(state, rng)
	segments.append(_make(state, now_min, now_min + duration, intensity, SOURCE_CHAIN, -1))
	ensure_horizon(now_min, season_index, rng)


## Append chain segments until the committed future reaches the horizon.
## Returns the segments appended (in order) so callers can react.
func ensure_horizon(now_min: int, season_index: int, rng: RandomNumberGenerator) -> Array:
	var added: Array = []
	if segments.is_empty():
		bootstrap(now_min, season_index, rng)
		return segments.duplicate()
	var guard := 0
	while int(segments[segments.size() - 1]["end_min"]) - now_min < tables.horizon_min:
		guard += 1
		if guard > 512:
			break  # data pathology (all durations 0) — never spin the sim
		added.append(_append_chain_segment(season_index, rng))
	return added


func _append_chain_segment(season_index: int, rng: RandomNumberGenerator) -> Dictionary:
	var last: Dictionary = segments[segments.size() - 1]
	var from_state := String(last["state"])
	var row := tables.transition_row(from_state, season_index)
	var next_state := String(WeatherTables.pick_weighted(row, rng.randf()))
	var duration := _roll_duration(next_state, rng)
	var intensity := _roll_intensity(next_state, rng)
	var start := int(last["end_min"])
	var segment := _make(next_state, start, start + duration, intensity, SOURCE_CHAIN, -1)
	segments.append(segment)
	return segment


func _roll_duration(state: String, rng: RandomNumberGenerator) -> int:
	var bounds := tables.duration_bounds(state)
	return tables.quantize(rng.randi_range(int(bounds[0]), int(bounds[1])))


func _roll_intensity(state: String, rng: RandomNumberGenerator) -> float:
	return clampf(pow(rng.randf(), tables.intensity_gamma(state)), 0.0, 1.0)


func _make(state: String, start_min: int, end_min: int, intensity: float,
		source: String, event_id: int) -> Dictionary:
	var segment := {
		"id": next_id, "state": state, "start_min": start_min, "end_min": end_min,
		"intensity": intensity, "source": source, "event_id": event_id,
	}
	next_id += 1
	return segment


# ------------------------------------------------------------------ querying

func segment_at(minute: int) -> Dictionary:
	if segments.is_empty():
		return {}
	for segment in segments:
		if minute >= int(segment["start_min"]) and minute < int(segment["end_min"]):
			return segment
	return segments[0] if minute < int(segments[0]["start_min"]) else segments[segments.size() - 1]


func segment_after(minute: int) -> Dictionary:
	var current := segment_at(minute)
	if current.is_empty():
		return {}
	var index := segments.find(current)
	if index < 0 or index + 1 >= segments.size():
		return {}
	return segments[index + 1]


func state_at(minute: int) -> Dictionary:
	var segment := segment_at(minute)
	if segment.is_empty():
		return {"state": "CLEAR", "intensity": 0.0}
	return {"state": String(segment["state"]), "intensity": float(segment["intensity"])}


## Drop segments that are wholly in the past — the timeline is a rolling window,
## not a history log (history lives in the Director's ring buffer).
func prune(now_min: int) -> void:
	while segments.size() > 1 and int(segments[0]["end_min"]) <= now_min:
		segments.remove_at(0)


# ----------------------------------------------------------------- injection

## Rewrite the future (§2.7.1). The segment covering `start_min` is truncated
## to end there, every later segment is discarded, the new segment is inserted
## and the chain resumes from it. Returns the new segment's id.
##
## Any consumer caching weather must tolerate this — it is the stated cost of
## the committed timeline (§9 item 3).
func inject_segment(state: String, start_min: int, duration_min: int, intensity: float,
		event_id: int, source: String = SOURCE_DIRECTOR) -> int:
	var kept: Array[Dictionary] = []
	for segment in segments:
		if int(segment["end_min"]) <= start_min:
			kept.append(segment)
		elif int(segment["start_min"]) < start_min:
			segment["end_min"] = start_min
			kept.append(segment)
	segments = kept
	var injected := _make(state, start_min, start_min + duration_min,
			clampf(intensity, 0.0, 1.0), source, event_id)
	segments.append(injected)
	return int(injected["id"])


## Append a segment immediately after the last one (the storm's rain tail).
func append_segment(state: String, duration_min: int, intensity: float,
		event_id: int, source: String = SOURCE_DIRECTOR) -> int:
	var start := int(segments[segments.size() - 1]["end_min"]) if not segments.is_empty() else 0
	var segment := _make(state, start, start + duration_min, clampf(intensity, 0.0, 1.0),
			source, event_id)
	segments.append(segment)
	return int(segment["id"])


func find_by_id(segment_id: int) -> Dictionary:
	for segment in segments:
		if int(segment["id"]) == segment_id:
			return segment
	return {}


# ---------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	var out: Array = []
	for segment in segments:
		out.append(segment.duplicate())
	return {"next_id": next_id, "segments": out}


func deserialize(data: Dictionary) -> void:
	segments.clear()
	for raw in data.get("segments", []):
		var segment: Dictionary = (raw as Dictionary).duplicate()
		segment["id"] = int(segment["id"])
		segment["state"] = String(segment["state"])
		segment["start_min"] = int(segment["start_min"])
		segment["end_min"] = int(segment["end_min"])
		segment["intensity"] = float(segment["intensity"])
		segment["source"] = String(segment["source"])
		segment["event_id"] = int(segment.get("event_id", -1))
		segments.append(segment)
	next_id = int(data.get("next_id", segments.size() + 1))
