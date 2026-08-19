class_name SevereThunderstorm
extends RefCounted
## The MVP disaster, beat by beat (doc 07 §2.7). It generates lightning
## attempts, selects targets and emits `LightningStrike` payloads. It resolves
## nothing: grid damage is doc 04's, building damage doc 02/06's, water nodes
## doc 05's (report 98 C-54), and every wind failure is doc 06's storm_damage
## generator (C-53).
##
## Phases, relative to T = 0 (cell centre over city centre):
##   T−20 … T=0   lead-in    phase_mult 0.00 — COSMETIC flashes only, so the
##                           player always gets a sensory beat before the first
##                           failure
##   T=0 … T+60   peak       phase_mult 1.00
##   T+60 … end   trailing   phase_mult 0.35
##
## `strike_attempts_per_hour = base_strike_rate · intensity · severity_mult
##  · phase_mult`, integrated on an accumulator rather than drawn per tick: the
## count is then exactly the expectation, the RNG draw count per step is
## bounded (doc 01's coarse contract), and fine and coarse ticking produce the
## same attempts at the same minutes.

const PHASE_IDLE := &"idle"
const PHASE_LEAD_IN := &"lead_in"
const PHASE_PEAK := &"peak"
const PHASE_TRAILING := &"trailing"
const PHASE_ENDED := &"ended"

var tables: DirectorTables
var targeter: LightningTargeter

var active: bool = false
var event_uid: int = -1
var severity_mult: float = 1.0
var intensity: float = 0.77
var t0_min: int = 0
var duration_min: int = 120
var phase: StringName = PHASE_IDLE
var total_response_units: int = 8
var prep_actions: Array = []
var struck: Dictionary = {}  # ref -> true, for this storm only (F4)
var metrics: Dictionary = _empty_metrics()

var _attempt_accum: float = 0.0
var _cosmetic_accum: float = 0.0
var _incident_window: Array = []  # [[minute, count], …] for the 10-minute cap
var _open_incidents: int = 0
var _root_causes: Array = []
var _events: Array = []


func _init(p_tables: DirectorTables) -> void:
	tables = p_tables
	targeter = LightningTargeter.new(tables.lightning())


static func _empty_metrics() -> Dictionary:
	return {"attempts": 0, "strikes": 0, "asset_hits": 0, "ground_strikes": 0,
			"cosmetic_flashes": 0, "wind_fails": 0, "downgraded": 0,
			"incidents_requested": 0, "outage_customer_minutes": 0, "repair_cost": 0}


## §2.7.1: the Director sets intensity explicitly rather than letting the chain
## roll it — a better-prepared city earns a materially nastier storm.
static func intensity_for(severity_mult_value: float, config: Dictionary) -> float:
	var band: Array = config.get("clamp", [0.6, 1.0])
	var value := float(config.get("base", 0.62)) \
			+ float(config.get("slope", 0.3)) * (severity_mult_value - 0.60) / 0.80
	return clampf(value, float(band[0]), float(band[1]))


## `attempt_phase ∈ [0,1)` is one draw taken at storm start. Without it the
## accumulator would FLOOR the attempt count every storm (5.967 expected
## attempts would always deliver 5); seeding the phase uniformly makes the
## per-storm count round stochastically, so the mean is exactly the expectation
## while the per-step draw count stays bounded for the coarse path.
func begin(p_event_uid: int, p_severity_mult: float, p_intensity: float,
		p_t0_min: int, p_duration_min: int, response_units: int = 8,
		attempt_phase: float = 0.0) -> void:
	active = true
	event_uid = p_event_uid
	severity_mult = p_severity_mult
	intensity = p_intensity
	t0_min = p_t0_min
	duration_min = p_duration_min
	total_response_units = maxi(1, response_units)
	phase = PHASE_IDLE
	struck.clear()
	metrics = _empty_metrics()
	_attempt_accum = clampf(attempt_phase, 0.0, 0.999999)
	_cosmetic_accum = 0.0
	_incident_window.clear()
	_open_incidents = 0
	_root_causes.clear()


func phase_at(now_min: int) -> StringName:
	if not active:
		return PHASE_IDLE
	var phases := tables.storm_phases()
	var t := now_min - t0_min
	if t < int(phases.get("cell_entry_min", -20)):
		return PHASE_IDLE
	if t < 0:
		return PHASE_LEAD_IN
	if t >= duration_min:
		return PHASE_ENDED
	if t < int(phases.get("peak_min", 60)):
		return PHASE_PEAK
	return PHASE_TRAILING


func phase_mult(p: StringName) -> float:
	match p:
		PHASE_PEAK:
			return 1.0
		PHASE_TRAILING:
			return float(tables.storm_phases().get("trailing_frac", 0.35))
		_:
			return 0.0


## One step. `targets` is the §2.7.3 roster (any domain); `hard_until` /
## `immune_until` are the Director's F4 books. Returns the LightningStrike
## payloads generated this step — the caller routes each to its owning doc.
func tick(now_min: int, dt_min: float, rng: RngStreams, targets: Array, cell: StormCell,
		hard_until: Dictionary = {}, immune_until: Dictionary = {}) -> Array:
	if not active:
		return []
	var previous := phase
	phase = phase_at(now_min)
	if phase != previous:
		_events.append({"type": &"storm_phase_changed", "phase": phase,
				"event_uid": event_uid, "t_min": now_min - t0_min})
	if phase == PHASE_ENDED:
		active = false
		return []
	var config := tables.lightning()
	var weather_rng := rng.stream("weather")
	var out: Array = []
	if phase == PHASE_LEAD_IN:
		_tick_cosmetic(now_min, dt_min, config, weather_rng)
		return out
	if phase == PHASE_IDLE:
		return out
	var rate := float(config.get("base_strike_rate_per_hour", 6.0)) * intensity \
			* severity_mult * phase_mult(phase)
	_attempt_accum += rate * dt_min / 60.0
	var guard := 0
	while _attempt_accum >= 1.0 and guard < 64:
		guard += 1
		_attempt_accum -= 1.0
		var strike := _attempt(now_min, config, weather_rng, targets, cell,
				hard_until, immune_until)
		if not strike.is_empty():
			out.append(strike)
	return out


func _tick_cosmetic(now_min: int, dt_min: float, config: Dictionary,
		weather_rng: RandomNumberGenerator) -> void:
	var phases := tables.storm_phases()
	if now_min - t0_min < int(phases.get("cosmetic_flash_min", -10)):
		return
	_cosmetic_accum += float(config.get("cosmetic_flash_rate_per_hour", 18.0)) \
			* intensity * dt_min / 60.0
	var guard := 0
	while _cosmetic_accum >= 1.0 and guard < 32:
		guard += 1
		_cosmetic_accum -= 1.0
		metrics["cosmetic_flashes"] = int(metrics["cosmetic_flashes"]) + 1
		_events.append({"type": &"lightning_flash_cosmetic", "event_uid": event_uid,
				"magnitude": weather_rng.randf_range(0.3, 0.8), "t_min": now_min - t0_min})


func _attempt(now_min: int, config: Dictionary, weather_rng: RandomNumberGenerator,
		targets: Array, cell: StormCell, hard_until: Dictionary,
		immune_until: Dictionary) -> Dictionary:
	metrics["attempts"] = int(metrics["attempts"]) + 1
	var hit_roll := weather_rng.randf()
	var select_roll := weather_rng.randf()
	var energy_roll := weather_rng.randf()
	var ground_roll := weather_rng.randf()
	if hit_roll >= float(config.get("p_asset_hit", 0.55)):
		return _ground_strike(cell, weather_rng, config, ground_roll)
	var target := targeter.select(targets, cell, now_min, struck, hard_until,
			immune_until, select_roll,
			float(tables.fairness.get("immunity_weight_mult", 0.15)))
	if target.is_empty():
		return _ground_strike(cell, weather_rng, config, ground_roll)
	var ref := String(target["ref"])
	struck[ref] = true  # F4: weight 0.00 for the rest of this storm
	metrics["strikes"] = int(metrics["strikes"]) + 1
	metrics["asset_hits"] = int(metrics["asset_hits"]) + 1
	var pos: Vector2 = target.get("pos", Vector2.ZERO)
	var energy := targeter.roll_energy(energy_roll)
	var strike := {
		"type": &"lightning_strike",
		"target_ref": ref,
		"domain": String(target.get("domain", "grid")),
		"energy": energy,
		"event_uid": event_uid,
		"condition_floor": float(tables.fairness.get("irreplaceable_condition_floor", 0.1)) \
				if bool(target.get("f10_protected", false)) else 0.0,
		"tile": [int(pos.x), int(pos.y)],
		"world_pos": Vector3(pos.x * WeatherSystem.TILE_METERS, 0.0,
				pos.y * WeatherSystem.TILE_METERS),
		"magnitude": clampf((energy - 0.6) / 1.0, 0.0, 1.0),
		"ground": false,
		"t_min": now_min - t0_min,
	}
	_root_causes.append({"ref": ref, "reason": _reason_for(target),
			"condition": float(target.get("condition", 1.0))})
	_events.append(strike.duplicate())
	return strike


func _ground_strike(cell: StormCell, weather_rng: RandomNumberGenerator,
		config: Dictionary, ground_roll: float) -> Dictionary:
	metrics["ground_strikes"] = int(metrics["ground_strikes"]) + 1
	var pos := cell.center() if cell != null and cell.active else Vector2.ZERO
	var jitter := cell.radius_t if cell != null and cell.active else 8.0
	pos += Vector2(weather_rng.randf_range(-jitter, jitter),
			weather_rng.randf_range(-jitter, jitter))
	_events.append({
		"type": &"lightning_strike", "target_ref": "", "domain": "ground",
		"energy": 0.0, "event_uid": event_uid, "condition_floor": 0.0,
		"tile": [int(pos.x), int(pos.y)],
		"world_pos": Vector3(pos.x * WeatherSystem.TILE_METERS, 0.0,
				pos.y * WeatherSystem.TILE_METERS),
		"magnitude": 0.6, "ground": true,
		"starts_fire": ground_roll < float(config.get("ground_fire_p", 0.06)),
	})
	return {}


static func _reason_for(target: Dictionary) -> String:
	var condition := float(target.get("condition", 1.0))
	if condition < 0.60:
		return "condition %.2f" % condition
	if not (target.get("protections", []) as Array).has("arrester"):
		return "no lightning arrester"
	return "exposed asset inside storm cell"


# ------------------------------------------------------- choreography caps

## §2.7.5. Anti-unwinnable: rolls exceeding a cap are DOWNGRADED, never
## deleted — the player still pays (a condition ding and a report line), but
## never faces an infinite queue.
func max_concurrent() -> int:
	var config: Dictionary = tables.storm.get("choreography", {})
	return int(roundf(float(config.get("concurrent_base", 3.0))
			+ float(config.get("concurrent_per_unit", 1.1)) * float(total_response_units)))


func max_new_per_10min() -> int:
	var config: Dictionary = tables.storm.get("choreography", {})
	return maxi(int(config.get("new_per_10min_min", 2)),
			int(ceil(float(total_response_units) * float(config.get("new_per_10min_per_unit", 0.5)))))


func can_spawn_incident(now_min: int) -> bool:
	_trim_window(now_min)
	if _open_incidents >= max_concurrent():
		return false
	var recent := 0
	for entry in _incident_window:
		recent += int(entry[1])
	return recent < max_new_per_10min()


## Request one storm incident through the doc 06 seam, honouring the caps.
## Returns true if the request went out, false if it was downgraded.
func request_incident(sink: IncidentRequestSink, now_min: int, kind: StringName,
		target: Dictionary) -> bool:
	if not can_spawn_incident(now_min):
		metrics["downgraded"] = int(metrics["downgraded"]) + 1
		_events.append({"type": &"storm_incident_downgraded", "event_uid": event_uid,
				"kind": kind, "ref": String(target.get("ref", "")),
				"condition_delta": float(tables.storm.get("choreography", {})
						.get("downgrade_condition_delta", -0.03))})
		return false
	_incident_window.append([now_min, 1])
	_open_incidents += 1
	metrics["incidents_requested"] = int(metrics["incidents_requested"]) + 1
	if sink != null:
		var payload := target.duplicate()
		payload["event_uid"] = event_uid
		payload["severity_mult"] = severity_mult
		sink.request_incident(kind, payload)
	return true


func on_incident_resolved() -> void:
	_open_incidents = maxi(0, _open_incidents - 1)


func _trim_window(now_min: int) -> void:
	var kept: Array = []
	for entry in _incident_window:
		if now_min - int(entry[0]) < 10:
			kept.append(entry)
	_incident_window = kept


# --------------------------------------------------------------- reporting

## §2.7.6. Repair totals are SUMMED FROM DOC 03's ledger by `event_uid`
## (report 98 C-16) — this module owns no price constant and quotes no figure
## it did not read back. `ledger_repair_total` is that read-back.
func build_report(ledger_repair_total: int = 0) -> Dictionary:
	var reward: Dictionary = tables.storm.get("reward", {})
	var causes := _root_causes.duplicate()
	causes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(float(a["condition"]) - float(b["condition"])) > 1e-9:
			return float(a["condition"]) < float(b["condition"])
		return String(a["ref"]) < String(b["ref"]))
	return {
		"event_uid": event_uid,
		"severity_mult": severity_mult,
		"intensity": intensity,
		"duration_min": duration_min,
		"metrics": metrics.duplicate(),
		"struck": _sorted_keys(struck),
		"prep_actions": prep_actions.duplicate(),
		"root_causes": causes.slice(0, mini(3, causes.size())),
		"repair_cost": ledger_repair_total,
		"reimburse_frac": float(reward.get("reimburse_frac", 0.15)),
	}


## §2.7.6 Storm Ready: preparation must be PROFITABLE, not merely less painful.
func storm_ready_earned(population: int) -> bool:
	var reward: Dictionary = tables.storm.get("reward", {})
	if prep_actions.size() < int(reward.get("min_prep_actions", 3)):
		return false
	var budget := float(reward.get("outage_cm_per_1k_pop", 250)) * float(population) / 1000.0
	return float(metrics["outage_customer_minutes"]) < budget


func drain_events() -> Array:
	var out := _events
	_events = []
	return out


func serialize() -> Dictionary:
	return {
		"active": active, "event_uid": event_uid, "severity_mult": severity_mult,
		"intensity": intensity, "t0_min": t0_min, "duration_min": duration_min,
		"phase": String(phase), "total_response_units": total_response_units,
		"struck_ids": _sorted_keys(struck), "prep_actions": prep_actions.duplicate(),
		"metrics": metrics.duplicate(), "attempt_accum": _attempt_accum,
		"cosmetic_accum": _cosmetic_accum, "open_incidents": _open_incidents,
		"new_incidents_window": _incident_window.duplicate(true),
		"root_causes": _root_causes.duplicate(true),
	}


func deserialize(data: Dictionary) -> void:
	active = bool(data.get("active", false))
	event_uid = int(data.get("event_uid", -1))
	severity_mult = float(data.get("severity_mult", 1.0))
	intensity = float(data.get("intensity", 0.77))
	t0_min = int(data.get("t0_min", 0))
	duration_min = int(data.get("duration_min", 120))
	phase = StringName(String(data.get("phase", "idle")))
	total_response_units = int(data.get("total_response_units", 8))
	struck.clear()
	for ref in data.get("struck_ids", []):
		struck[String(ref)] = true
	prep_actions = data.get("prep_actions", [])
	# JSON returns doubles; the metric counters are integers and must reload as
	# integers or the save is not a fixed point.
	metrics = _empty_metrics()
	for key in data.get("metrics", {}):
		metrics[String(key)] = int(data["metrics"][key])
	_attempt_accum = float(data.get("attempt_accum", 0.0))
	_cosmetic_accum = float(data.get("cosmetic_accum", 0.0))
	_open_incidents = int(data.get("open_incidents", 0))
	_incident_window.clear()
	for entry in data.get("new_incidents_window", []):
		_incident_window.append([int(entry[0]), int(entry[1])])
	_root_causes = data.get("root_causes", [])


static func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
