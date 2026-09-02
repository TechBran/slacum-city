class_name DisasterDirector
extends RefCounted
## The conductor (doc 07 §2.6). Every game-hour it answers one question: what
## is about to test this city, and does the player have a fair chance to see it
## coming?
##
## Two spines hold the whole design up:
##   · `pressure = 0.55 + 0.90·P` — threat scales UP with preparedness and DOWN
##     with distress, so challenge follows capability (§9 item 5);
##   · F1–F10 are hard GATES evaluated before any weighting, identical at every
##     difficulty. Difficulty changes pressure and preparation time, never the
##     fairness list.
##
## It REQUESTS incidents through `IncidentRequestSink`; doc 06 executes them
## (C-53). It resolves no damage (C-54), prices no repair (C-16), writes no
## stability scalar (C-56) and stores no difficulty knob (C-17).

const HISTORY_RING := 32

## PA-04 / A91-D-59 — **the hold cap.** Every committed event must have a way to
## END, and the last of them is a wall clock: no row may sit in `active_events`
## longer than this. 2880 game-minutes is 48 game-hours, which is comfortably
## past doc 06 §2.10's terminal rule (one game-day with nothing committed ends an
## incident as ABANDONED), so a row that hits this wall is a row whose incidents
## are already gone and whose link book has lost them. `data/director.json`'s
## `fairness.max_active_min` is the live knob; this constant is its default and
## the value the save migrator uses, because doc 08 §2.8 forbids a migrator from
## reading `data/`. `tests/test_weather_director.gd` pins the two together.
const MAX_ACTIVE_MIN_DEFAULT := 2880
## §2.7.6's STORM REPORT beat, T+180. Same two-source rule as above.
const STORM_REPORT_AT_MIN_DEFAULT := 180

## `on_event_resolved` outcomes. `expired` is the hold cap firing: the event is
## over as far as the player is concerned and the Director must stop waiting.
const OUTCOME_RESOLVED := "resolved"
const OUTCOME_EXPIRED := "expired"

var tables: DirectorTables
var weather: WeatherSystem = null
var sink: IncidentRequestSink = null
var modifiers: ModifierStack = null
var storm: SevereThunderstorm
## Optional: `func(event_id: String) -> Array` of §2.6.5 target descriptors.
## When set and it returns nothing, the pick is dropped and the TP refunded
## (§2.6.3 step 8). When unset, Phase-1 scheduling proceeds without a target.
var target_provider: Callable = Callable()

var difficulty: String = "standard"
var tp_pool: float = 0.0
var pop_peak_7d: int = 0
var offline_hazard_used: bool = false
var next_event_uid: int = 1

var last_event_start_min: Dictionary = {}  # event id -> minute (F3)
var last_event_end_min: Dictionary = {}
var last_major_end_min: int = -1000000
var last_minor_end_min: int = -1000000
var last_major_district: String = ""
var history: Array = []  # ring of 32
var target_immunity: Dictionary = {}  # ref -> until_min (F4 soft)
var target_hard_exclude: Dictionary = {}  # ref -> until_min (F4 hard)
var suppression: Dictionary = {"active": false, "reasons": [], "since_min": -1, "clear_at_min": -1}
## Scripted suppression — the tutorial's hold (doc 12 §2.17), distinct from F5's
## earned one above so neither can clear the other. `-1` means "not held".
var suppress_until_min: int = -1
var recovery_mode: Dictionary = {"active": false, "until_min": -1}
var scheduled: Array = []
var active_events: Dictionary = {}  # event_uid -> row
var post_event_bleed_until_min: int = -1
var debt_since_min: int = -1
## 99-PA PA-26 — §2.7.7's prep ledger, kept HERE and not on the storm, because
## every prep action is taken in the WARNING window and the storm object does not
## exist yet (`storm.begin()` runs at impact). `_start_event` hands the list over
## when the storm starts; `on_event_resolved` clears it, so one storm's
## preparation can never be counted toward the next one's Storm Ready check.
var prep_actions: Array = []
var prep_event_uid: int = -1

var _now_min: int = 0
var _rng: RngStreams
var _pressure_knobs: Dictionary = {}
var _difficulty_locked: bool = false
var _pop_history: Array = []  # [[day_index, population], …] trimmed to 7 days
var _events: Array = []
var _last_p: float = 0.0


func _init(p_tables: DirectorTables, p_rng: RngStreams) -> void:
	tables = p_tables
	_rng = p_rng
	storm = SevereThunderstorm.new(tables)


func attach(p_weather: WeatherSystem, p_sink: IncidentRequestSink,
		p_modifiers: ModifierStack = null) -> void:
	weather = p_weather
	sink = p_sink
	modifiers = p_modifiers


# ------------------------------------------------------ commands (doc 07 §4)

## Scripted suppression for the onboarding flow (doc 12 §2.17: "lifts
## suppression after 300 s"). `seconds_gs` is GAME seconds, so the hold is a
## game-minute deadline like every other gate in this file and it survives
## save/load, pause and time acceleration identically. Calls EXTEND, never
## shorten: two overlapping tutorial steps cannot uncover each other.
##
## This is not F5. F5 is earned — the city is in trouble and the Director backs
## off — and it must stay observable while the tutorial is talking, so the two
## live in separate fields and `tick_hour` honours both.
func suppress(seconds_gs: float) -> void:
	if seconds_gs <= 0.0:
		return
	var until := _now_min + int(ceil(seconds_gs / 60.0))
	suppress_until_min = maxi(suppress_until_min, until)
	_emit(&"director_scripted_suppression", {"active": true, "minute": _now_min,
			"until_min": suppress_until_min})


## Ends the scripted hold now (tutorial finished or skipped). F5's own
## suppression, if the city has earned it, is untouched.
func release() -> void:
	if suppress_until_min < 0:
		return
	suppress_until_min = -1
	_emit(&"director_scripted_suppression", {"active": false, "minute": _now_min})


## True while the scripted hold is in force. Evaluated against the last hourly
## tick's clock, which is the only clock this class has.
func scripted_suppression_active() -> bool:
	return suppress_until_min >= 0 and _now_min < suppress_until_min


## `storm_prep_action(action_id, target)` — available T−90 → T−20 only
## (§2.7.7). All optional: a city that does nothing is still playable, just
## worse. Returns false when the action is unknown, already taken, or outside
## the window, so the UI can grey the button rather than lie about it.
func storm_prep_action(action_id: String, target: Dictionary = {}) -> bool:
	var window := storm_prep_window()
	if not bool(window["open"]):
		return false
	var actions: Dictionary = tables.storm.get("prep_actions", {})
	if not actions.has(action_id) or prep_actions.has(action_id):
		return false
	prep_event_uid = int(window["event_uid"])
	prep_actions.append(action_id)
	if storm.active and storm.event_uid == prep_event_uid:
		storm.prep_actions = prep_actions.duplicate()
	if action_id == "load_shed":
		_apply_load_shed(float(actions[action_id].get("power_load_mult", 0.92)))
	elif action_id == "sandbag_block" and weather != null and target.has("block"):
		var block: Array = target["block"]
		weather.flood.set_block_drain_bonus(int(block[0]), int(block[1]),
				float(actions[action_id].get("drain_rate_mult", 1.6)))
	_emit(&"storm_prep_action", {"action": action_id, "event_uid": prep_event_uid,
			"target": target.duplicate()})
	return true


## 99-PA PA-26 — **the row the prep window is measured against, and why it is not
## the storm object.** `SevereThunderstorm.begin()` runs at IMPACT, in
## `_start_event`, and sets `t0_min = now`. The fork's window test was
## `storm.active` AND `−90 ≤ now − t0 ≤ −20`, and those two are never true
## together: while the storm is active `now − t0 ≥ 0`, so the six authored prep
## actions were unreachable through this function as well as through the shell.
## The window is a property of the SCHEDULED row — the one F7's warning went out
## for — so that is what this reads. It falls back to the in-flight row, so a
## storm that has already begun answers "closed" rather than "no storm".
func pending_storm() -> Dictionary:
	for row in scheduled:
		if String(row["type"]) == "severe_thunderstorm":
			return row
	for uid in _sorted_keys(active_events):
		var row: Dictionary = active_events[uid]
		if String(row["type"]) == "severe_thunderstorm":
			return row
	return {}


## §2.7.7's window, T−90 → T−20 relative to the storm's own T=0, with the lead
## scaled by difficulty exactly as F7's warning is (`warning_lead_mult`): a
## casual player gets a longer window because they were given a longer warning.
## `{open, event_uid, t0_min, opens_at_min, closes_at_min, minutes_left,
## minutes_to_impact}`; every field is present even when there is no storm, so a
## surface can bind once and redraw.
func storm_prep_window() -> Dictionary:
	var row := pending_storm()
	if row.is_empty():
		return {"open": false, "event_uid": -1, "t0_min": -1, "opens_at_min": -1,
				"closes_at_min": -1, "minutes_left": 0, "minutes_to_impact": 0}
	var t0 := int(row["impact_min"])
	var lead := int(roundf(float(tables.event_by_id("severe_thunderstorm")
			.get("warn_min", 90)) * knob("warning_lead_mult")))
	var opens := t0 - lead
	var closes := t0 + int(tables.storm_phases().get("cell_entry_min", -20))
	return {
		"open": _now_min >= opens and _now_min <= closes,
		"event_uid": int(row["event_uid"]),
		"t0_min": t0, "opens_at_min": opens, "closes_at_min": closes,
		"minutes_left": maxi(0, closes - _now_min),
		"minutes_to_impact": maxi(0, t0 - _now_min),
	}


## The Director's clock, for a caller that has to line a window up against it.
func now_min() -> int:
	return _now_min


## Voluntary load shed is a POLICY source on the shared ModifierStack, not a
## weather multiplier: `get_effect()` keeps publishing the honest weather number
## and the player's choice multiplies on top of it, at its own source rank.
func _apply_load_shed(factor: float) -> void:
	if modifiers == null or weather == null:
		return
	var mults := {}
	for channel in weather.tables.modifier_channels.get("power_load_mult", []):
		mults[String(channel)] = factor
	modifiers.push_source(&"policy", "storm_load_shed", mults)


func _clear_load_shed() -> void:
	if modifiers != null:
		modifiers.remove_source(&"policy", "storm_load_shed")


## `debug_force_director_event(id)` (§4): schedule a catalog event immediately,
## bypassing the budget but NOT the fairness gates the player can see (F7 still
## warns, F10 still clamps).
func debug_force_director_event(event_id: String, inputs: DirectorInputs,
		ctx: TimeContext) -> bool:
	var event := tables.event_by_id(event_id)
	if event.is_empty():
		return false
	_now_min = ctx.tick_index / GameClock.TICKS_PER_MINUTE
	tp_pool = maxf(tp_pool, float(event["tp_cost"]))
	var director_rng := _rng.stream("director")
	# PA-25: the forced path chooses a target the same way the scheduled one
	# does, so a debug force exercises the seam it is used to exercise. It
	# FORCES, though — a city with no legal target still gets its event, and the
	# sink picks for itself from the same roster.
	var target := _choose_target(event, director_rng)
	if target.has("_no_legal_target"):
		target = {}
	_commit(event, target, inputs, ctx, preparedness(inputs), director_rng)
	return true


## `debug_set_tp(v)` (§4).
func debug_set_tp(value: float) -> void:
	tp_pool = clampf(value, 0.0, tp_pool_cap(false))


## Doc 03 owns `data/difficulty.json`; this is the one write path for its
## `pressure` section (C-17), and since that file shipped it is the ONLY path —
## `CitySim` calls it at boot, at founding and after every load. With nothing
## set, `knob()` reads the nominal row, which is `standard` by construction.
func set_pressure_knobs(knobs: Dictionary) -> void:
	_pressure_knobs = knobs.duplicate()


## Pins the preset. Once pinned, `DirectorInputs.difficulty` no longer
## overrides it — the `set_difficulty` command and doc 08's save meta are one
## write path, not two competing ones.
func set_difficulty(preset: String) -> void:
	difficulty = preset
	_difficulty_locked = true
	_pressure_knobs.clear()


func knob(key: String) -> float:
	if _pressure_knobs.has(key):
		return float(_pressure_knobs[key])
	return float(tables.nominal_pressure().get(key, 1.0))


func soft_suppression_enabled() -> bool:
	if _pressure_knobs.has("soft_suppression"):
		return bool(_pressure_knobs["soft_suppression"])
	return bool(tables.nominal_pressure().get("soft_suppression", true))


# ------------------------------------------------------------ derived scores

## R = 0.50·grid + 0.30·water + 0.20·road (§2.6.1)
func redundancy(inputs: DirectorInputs) -> float:
	var w: Dictionary = tables.preparedness.get("redundancy_weights", {})
	return float(w.get("grid", 0.5)) * inputs.grid_redundancy \
			+ float(w.get("water", 0.3)) * inputs.water_redundancy \
			+ float(w.get("road", 0.2)) * inputs.road_redundancy


## F = mean_d(clamp(owned/needed, 0, 1.25)) / 1.25 (§2.6.1)
func fleet_strength(inputs: DirectorInputs) -> float:
	var per_unit: Dictionary = tables.preparedness.get("fleet_pop_per_unit", {})
	var cap := float(tables.preparedness.get("fleet_clamp", 1.25))
	var departments := per_unit.keys()
	departments.sort()  # canonical order: the mean must not depend on dict order
	if departments.is_empty():
		return 0.0
	var total := 0.0
	for department in departments:
		var needed := int(ceil(float(inputs.population) / maxf(1.0, float(per_unit[department]))))
		var owned := int(inputs.units_owned.get(department, 0))
		total += clampf(float(owned) / float(maxi(1, needed)), 0.0, cap)
	return (total / float(departments.size())) / cap


## P = 0.35·R + 0.25·F + 0.20·stability + 0.20·clamp(runway/10, 0, 1) (§2.6.1)
func preparedness(inputs: DirectorInputs) -> float:
	var config := tables.preparedness
	var runway_days := float(inputs.treasury) / maxf(1.0, float(inputs.daily_opex))
	var runway_cap := float(config.get("runway_cap_days", 10.0))
	return float(config.get("w_redundancy", 0.35)) * redundancy(inputs) \
			+ float(config.get("w_fleet", 0.25)) * fleet_strength(inputs) \
			+ float(config.get("w_stability", 0.20)) * clampf(inputs.city_stability, 0.0, 1.0) \
			+ float(config.get("w_runway", 0.20)) * clampf(runway_days / runway_cap, 0.0, 1.0)


func tp_rate_per_day(inputs: DirectorInputs, p: float, is_offline: bool) -> float:
	var config := tables.tp
	var base := tables.tp_base_per_day(tables.city_tier(inputs.population))
	var age_ramp := clampf(float(inputs.city_age_days) / float(config.get("age_ramp_days", 10)),
			float(config.get("age_ramp_floor", 0.30)), 1.0)
	var pressure := float(config.get("pressure_base", 0.55)) \
			+ float(config.get("pressure_slope", 0.90)) * p
	var rate := base * age_ramp * pressure * knob("tp_rate_mult")
	if bool(suppression["active"]):
		rate *= float(config.get("suppressed_rate_mult", 0.5))
	if is_offline:
		rate *= float(config.get("offline_rate_mult", 0.35))
	return rate


func tp_pool_cap(is_offline: bool) -> float:
	var config := tables.tp
	if bool(suppression["active"]):
		return float(config.get("pool_cap_suppressed", 40.0))
	if is_offline:
		return float(config.get("pool_cap_offline", 60.0))
	return float(config.get("pool_cap", 180.0))


func severity_for(p: float, scheduled_offline: bool) -> float:
	var config := tables.severity
	var band: Array = config.get("clamp", [0.6, 1.4])
	var value := clampf(float(config.get("base", 0.6)) + float(config.get("slope", 0.8)) * p,
			float(band[0]), float(band[1])) * knob("severity_mult")
	if scheduled_offline:
		value *= float(config.get("offline_mult", 0.75))
	return value


## 99-PA PA-89 — **buy severity** (§2.6.2), authored in `data/director.json`
## since doc 07 shipped and never implemented: `buy_max_cost_mult` and
## `buy_max_severity` had zero readers, and late-game tension plateaued lower
## than the model says because a rich Director could only ever buy the same
## events at the same severity.
##
## The rule, verbatim: the Director may spend up to `1.60 × tp_cost` to add up
## to `+0.30` to `severity_mult`, and *only when `tp_pool > 1.6 × tp_cost` and
## **no other candidate is affordable***. `candidates()` has already filtered
## the pool to what the budget can buy and what the fairness gates allow, so the
## second clause is exactly `pool.size() == 1`: there is money, there is one
## thing to spend it on, and the surplus would otherwise sit against F6's cap
## doing nothing. That is the whole point of the lever — an idle budget becomes
## a nastier event rather than a stockpile.
##
## **The looser reading was measured and rejected.** "Nothing DEARER is
## affordable" fires far more often (any hour whose pool tops out on a cheap
## minor), and over doc 07 §7 test 26's 100-game-day × 12-seed rig it took the
## Standard cadence from one major per 2.64 game-days to one per **3.23** —
## outside §2.6.3's own "one major every 2–2.5 game-days" claim — while lifting
## mean severity by only 2.5 %. The literal reading lands at 2.86 game-days and
## +6.2 % mean severity, which is the trade the section is asking for. Doc 92
## §49 carries both arms.
##
## Returns the multiple of `tp_cost` to spend: `1.0` (buy nothing) or the cap.
## It is all-or-nothing rather than a slider because a partial buy would need a
## draw, and a draw here is a `director` stream position the coarse and fine
## paths would have to agree on for no design gain.
func buy_severity_spend_mult(event: Dictionary, pool: Array) -> float:
	var config := tables.severity
	var cost := float(event.get("tp_cost", 0))
	var cap := float(config.get("buy_max_cost_mult", 1.6))
	if cap <= 1.0 or cost <= 0.0 or tp_pool <= cap * cost:
		return 1.0
	if pool.size() > 1:
		return 1.0
	return cap


## The severity the extra spend buys, linear in the overspend and capped:
## `min(buy_max_severity, (spend/cost − 1) · buy_max_severity/(cost_mult − 1))`.
## At the cap that is exactly `+0.30`, which is §2.6.2's own number.
##
## It is added AFTER `severity_for`'s clamp, deliberately: the clamp is the band
## preparedness alone can reach, and this is the Director paying to go past it.
func severity_buy_bonus(spend_mult: float) -> float:
	var config := tables.severity
	var cap := float(config.get("buy_max_cost_mult", 1.6))
	var max_bonus := float(config.get("buy_max_severity", 0.3))
	if cap <= 1.0:
		return 0.0
	return minf(max_bonus, maxf(0.0, spend_mult - 1.0) * max_bonus / (cap - 1.0))


# ------------------------------------------------------------- the game-hour

## Hourly evaluation on the `director` stream (§2.6.3).
func tick_hour(inputs: DirectorInputs, ctx: TimeContext) -> void:
	_now_min = ctx.tick_index / GameClock.TICKS_PER_MINUTE
	if not _difficulty_locked and inputs.difficulty != "":
		difficulty = inputs.difficulty
	_track_population(inputs, ctx)
	_fire_due_events(inputs)
	var p := preparedness(inputs)
	_last_p = p
	_update_recovery_mode(inputs)
	_update_suppression(inputs)
	_accrue_tp(inputs, p, ctx.is_catchup)
	if bool(recovery_mode["active"]):
		return  # F9: TP is frozen and nothing is scheduled
	if bool(suppression["active"]):
		return  # F5
	if scripted_suppression_active():
		return  # doc 12 §2.17 — the tutorial is holding the floor
	_try_schedule(inputs, ctx, p)


func _track_population(inputs: DirectorInputs, ctx: TimeContext) -> void:
	if _pop_history.is_empty() or int(_pop_history[_pop_history.size() - 1][0]) != ctx.day_index:
		_pop_history.append([ctx.day_index, inputs.population])
	else:
		_pop_history[_pop_history.size() - 1][1] = maxi(
				int(_pop_history[_pop_history.size() - 1][1]), inputs.population)
	while _pop_history.size() > 7:
		_pop_history.remove_at(0)
	var peak := inputs.pop_peak_7d
	for entry in _pop_history:
		peak = maxi(peak, int(entry[1]))
	pop_peak_7d = peak


func _accrue_tp(inputs: DirectorInputs, p: float, is_offline: bool) -> void:
	if bool(recovery_mode["active"]):
		return  # F9 freezes the pool where it stands
	var rate := tp_rate_per_day(inputs, p, is_offline)
	var pool := tp_pool + rate * (float(tables.scheduling.get("eval_period_min", 60)) / 1440.0)
	if _now_min < post_event_bleed_until_min:
		pool = minf(pool, tp_pool)  # post-event bleed window: no net accrual
	tp_pool = minf(pool, tp_pool_cap(is_offline))  # F6: no revenge spike


# ------------------------------------------------------------ fairness gates

## F9 — unrecoverable guard.
func _update_recovery_mode(inputs: DirectorInputs) -> void:
	var config: Dictionary = tables.fairness.get("recovery_mode", {})
	if inputs.treasury < 0:
		if debt_since_min < 0:
			debt_since_min = _now_min
	else:
		debt_since_min = -1
	var pop_collapse := pop_peak_7d > 0 \
			and float(inputs.population) < float(config.get("pop_frac_of_peak", 0.6)) * float(pop_peak_7d)
	var long_debt := debt_since_min >= 0 \
			and _now_min - debt_since_min > int(config.get("debt_duration_min", 1440))
	if bool(recovery_mode["active"]):
		var may_exit := _now_min >= int(recovery_mode["until_min"]) \
				and inputs.city_stability >= float(config.get("exit_stability", 0.55)) \
				and not pop_collapse and not long_debt
		if may_exit:
			recovery_mode = {"active": false, "until_min": -1}
			_emit(&"director_recovery_mode", {"active": false, "minute": _now_min})
		return
	if pop_collapse or long_debt:
		recovery_mode = {"active": true,
				"until_min": _now_min + int(config.get("min_duration_min", 4320))}
		_emit(&"director_recovery_mode", {"active": true, "minute": _now_min,
				"until_min": int(recovery_mode["until_min"]),
				"reason": "population" if pop_collapse else "treasury"})


## F5 — no kick while down. Suppression clears only when every condition is
## false PLUS a 12-game-hour recovery grace.
func _update_suppression(inputs: DirectorInputs) -> void:
	var config: Dictionary = tables.fairness.get("suppress", {})
	var reasons: Array = []
	if inputs.city_stability < float(config.get("stability", 0.35)):
		reasons.append("stability")
	if inputs.unresolved_major_incidents > 0:
		reasons.append("unresolved_major")
	if inputs.customers_out_pct > float(config.get("customers_out_pct", 0.25)):
		reasons.append("customers_out")
	if inputs.treasury < 0:
		reasons.append("treasury")
	if inputs.roads_impassable_pct > float(config.get("roads_impassable_pct", 0.40)):
		reasons.append("roads_impassable")
	var grace := int(config.get("recovery_grace_min", 720))
	if not reasons.is_empty():
		if not bool(suppression["active"]):
			_emit(&"director_suppressed", {"active": true, "reasons": reasons,
					"minute": _now_min})
		suppression = {"active": true, "reasons": reasons, "since_min": _now_min,
				"clear_at_min": _now_min + grace}
		tp_pool = minf(tp_pool, float(tables.tp.get("pool_cap_suppressed", 40.0)))
		return
	if bool(suppression["active"]):
		if int(suppression["clear_at_min"]) < 0:
			suppression["clear_at_min"] = _now_min + grace
		if _now_min >= int(suppression["clear_at_min"]):
			suppression = {"active": false, "reasons": [], "since_min": -1, "clear_at_min": -1}
			_emit(&"director_suppressed", {"active": false, "reasons": [], "minute": _now_min})


## F1 — grace period. The doc's gate is age AND population, which a founding
## city fails forever on the population half (doc 92 F-1): 144 people against a
## threshold of 400, so the Director never wakes up in a small city. The floor
## (doc 92 F-1 ruling) keeps the age half and drops the population half, and
## `candidates()` still holds everything but cheap tier-1 minors back until the
## city is genuinely big enough for the doc's own ladder.
func _grace_passed(inputs: DirectorInputs) -> bool:
	if inputs.city_age_days >= int(tables.fairness.get("grace_days", 3)) \
			and inputs.population >= int(tables.fairness.get("grace_population", 400)):
		return true
	return tables.floor_enabled() and inputs.city_age_days >= tables.floor_grace_days()


func cooldown(key: String) -> int:
	return int(roundf(float(tables.fairness.get(key, 0)) * knob("cooldown_mult")))


## PA-04: the hold cap, in game-minutes.
func max_active_min() -> int:
	return int(tables.fairness.get("max_active_min", MAX_ACTIVE_MIN_DEFAULT))


## §2.7.6's report beat, in game-minutes after the storm's T=0.
func storm_report_at_min() -> int:
	var recovery: Dictionary = tables.storm.get("recovery", {})
	return int(recovery.get("report_at_min", STORM_REPORT_AT_MIN_DEFAULT))


## Nothing new is scheduled while a Director event is still in flight — either
## committed and waiting for its impact, or impacted and not yet resolved.
## F2's cooldowns are measured from RESOLUTION, so without this the gate would
## read a stale `last_*_end_min` and stack two majors on top of each other.
func has_pending_event() -> bool:
	return not scheduled.is_empty() or not active_events.is_empty()


## A major in flight is the headline: nothing else is committed on top of it.
func has_pending_major() -> bool:
	for row in scheduled:
		if String(row["class"]) == DirectorTables.CLASS_MAJOR:
			return true
	for uid in active_events:
		if String(active_events[uid]["class"]) == DirectorTables.CLASS_MAJOR:
			return true
	return false


## F2 / F3 — class and per-type cooldowns, measured from RESOLUTION.
## The per-type clock is anchored on IMPACT (the minute the player experiences
## the event), not on the minute it was quietly committed.
func _cooldowns_clear(event: Dictionary) -> bool:
	var id := String(event["id"])
	if _now_min - int(last_event_start_min.get(id, -1000000)) < cooldown("per_type_cooldown_min"):
		return false
	if _now_min - last_minor_end_min < cooldown("minor_cooldown_min"):
		return false
	if String(event["class"]) == DirectorTables.CLASS_MAJOR \
			and _now_min - last_major_end_min < cooldown("major_cooldown_min"):
		return false
	return true


## F8 — offline fairness, tightened to doc 08 §2.3 rule 1 verbatim (C-55).
## At most ONE hazard per catch-up session, `hazard_tier == 1` only, pre-warned
## before backgrounding, FULL band only, and zero on casual.
func _offline_allows(event: Dictionary, ctx: TimeContext) -> bool:
	var config: Dictionary = tables.fairness.get("offline", {})
	if difficulty == "casual":
		return int(config.get("hazards_on_casual", 0)) > 0
	if offline_hazard_used:
		return false
	if int(event.get("hazard_tier", 3)) > int(config.get("max_hazard_tier", 1)):
		return false
	if bool(config.get("requires_prewarning", true)):
		# An offline hazard is never new information: it must already be a
		# warned, committed segment on the timeline the player last saw.
		if not _has_prewarning(String(event["id"])):
			return false
	if ctx.catchup_total > 0 and ctx.catchup_index > 71:
		return false  # doc 08's DAMPED band: the Director is suppressed entirely
	return true


func _has_prewarning(event_id: String) -> bool:
	for row in scheduled:
		if String(row["type"]) == event_id and bool(row["warned"]):
			return true
	return false


## F10 — nothing irreplaceable is destroyed. The gate is evaluated here, where
## "last of its kind" is knowable; it travels to the resolver as
## `condition_floor` on the LightningStrike payload (§2.7.3).
func condition_floor_for(target: Dictionary) -> float:
	return float(tables.fairness.get("irreplaceable_condition_floor", 0.1)) \
			if bool(target.get("f10_protected", false)) else 0.0


# ---------------------------------------------------------------- scheduling

func candidates(inputs: DirectorInputs, ctx: TimeContext, p: float) -> Array:
	var out: Array = []
	if not _grace_passed(inputs):
		return out
	var soft := soft_suppression_enabled() \
			and inputs.city_stability < float(tables.fairness.get("soft_suppress_stability", 0.5))
	var soft_max := int(tables.fairness.get("soft_suppress_max_cost", 12))
	var city_tier := tables.city_tier(inputs.population)
	for event in tables.events:  # file order — never dictionary order
		if city_tier < int(event.get("min_city_tier", 1)) and not tables.floor_allows(event):
			continue
		if p < float(event.get("min_preparedness", 0.0)):
			continue
		if float(event.get("tp_cost", 0)) > tp_pool:
			continue
		if not _cooldowns_clear(event):
			continue
		if soft and (String(event["class"]) != DirectorTables.CLASS_MINOR
				or int(event["tp_cost"]) > soft_max):
			continue
		if ctx.is_catchup and not _offline_allows(event, ctx):
			continue
		out.append(event)
	return out


## §2.6.3 step 7 — novelty × budget pressure × season affinity.
func candidate_weight(event: Dictionary, season_index: int) -> float:
	var config := tables.scheduling
	var id := String(event["id"])
	var novelty := 1.0
	var last_seen: int = int(last_event_start_min.get(id, -1000000))
	if _now_min - last_seen > int(config.get("novelty_days", 10)) * 1440:
		novelty = float(config.get("novelty_mult", 1.5))
	var budget_bias := 1.0 + float(config.get("budget_bias_slope", 0.6)) \
			* float(event["tp_cost"]) / maxf(1.0, tp_pool)
	var affinity := 1.0
	var season_table: Dictionary = event.get("season_affinity", {})
	if not season_table.is_empty():
		affinity = float(season_table.get(WeatherTables.SEASONS[posmod(season_index, 4)], 1.0))
	return float(event["base_weight"]) * novelty * budget_bias * affinity


func _try_schedule(inputs: DirectorInputs, ctx: TimeContext, p: float) -> void:
	# Pacing gate: a major in flight blocks everything, and at most two Director
	# events may ever be in flight at once. Without it F2's from-resolution
	# cooldowns read a stale timestamp and two crises stack.
	if has_pending_major() or scheduled.size() + active_events.size() >= 2:
		return
	var pool := candidates(inputs, ctx, p)
	if pool.is_empty():
		return
	var director_rng := _rng.stream("director")
	var attempt_p := clampf(tp_pool / float(tables.scheduling.get("attempt_pool_target", 40.0)),
			0.0, 1.0) * float(tables.scheduling.get("attempt_base_p", 0.25))
	if director_rng.randf() >= attempt_p:
		return
	var entries: Array = []
	var total := 0.0
	for event in pool:
		var w := candidate_weight(event, inputs.season_index)
		if w <= 0.0:
			continue
		entries.append([event, w])
		total += w
	if entries.is_empty():
		return
	for entry in entries:
		entry[1] = float(entry[1]) / total
	var pick: Dictionary = WeatherTables.pick_weighted(entries, director_rng.randf())
	var target := _choose_target(pick, director_rng)
	if target.has("_no_legal_target"):
		return  # §2.6.3 step 8: drop the pick, spend nothing
	_commit(pick, target, inputs, ctx, p, director_rng,
			buy_severity_spend_mult(pick, pool))  # §2.6.2 / PA-89


func _choose_target(event: Dictionary, director_rng: RandomNumberGenerator) -> Dictionary:
	# PA-25: a WEATHER event has no target roster because its target is the whole
	# city — the segment lands on everyone. Step 8's "no legal target, drop the
	# pick" is about an event that needs something to hit and cannot find it, and
	# reading it the other way would delete `storm_minor`, `heat_wave` and the
	# authored thunderstorm from the schedule the moment a provider was bound.
	if tables.incident_kind(String(event["id"])).is_empty():
		return {}
	if not target_provider.is_valid():
		return {}
	var legal: Array = target_provider.call(String(event["id"]))
	var entries: Array = []
	var total := 0.0
	for target in legal:
		var ref := String(target.get("ref", ""))
		if _now_min < int(target_hard_exclude.get(ref, -1)):
			continue  # F4 hard exclusion is a filter, never a weight
		if String(event["class"]) == DirectorTables.CLASS_MAJOR \
				and String(target.get("district_id", "")) != "" \
				and String(target.get("district_id", "")) == last_major_district:
			continue  # F4: no two consecutive majors in one district
		var w := _target_weight(target)
		if w <= 0.0:
			continue
		entries.append([target, w])
		total += w
	if entries.is_empty():
		return {"_no_legal_target": true}
	for entry in entries:
		entry[1] = float(entry[1]) / total
	return WeatherTables.pick_weighted(entries, director_rng.randf())


## §2.6.5 generic target weighting.
func _target_weight(target: Dictionary) -> float:
	var ref := String(target.get("ref", ""))
	var condition_factor := 1.0 + 1.5 * (1.0 - clampf(float(target.get("condition", 1.0)), 0.0, 1.0))
	var immunity := 1.0
	if _now_min < int(target_immunity.get(ref, -1)):
		immunity = float(tables.fairness.get("immunity_weight_mult", 0.15))
	return float(target.get("base_type_weight", 1.0)) * condition_factor \
			* float(target.get("exposure_factor", 1.0)) \
			* float(target.get("protection_factor", 1.0)) \
			* immunity * float(target.get("spatial_factor", 1.0))


func _commit(event: Dictionary, target: Dictionary, inputs: DirectorInputs,
		ctx: TimeContext, p: float, director_rng: RandomNumberGenerator,
		spend_mult: float = 1.0) -> void:
	var forecastable := bool(event.get("forecastable", false))
	var lead := 0
	if forecastable:
		lead = int(roundf(float(event["warn_min"]) * knob("warning_lead_mult")))
		if lead <= 0:
			return  # F7: a warning that cannot be delivered means no event, TP refunded
	else:
		var delay: Array = tables.scheduling.get("sudden_delay_min", [10, 120])
		lead = director_rng.randi_range(int(delay[0]), int(delay[1]))
	var severity := severity_for(p, ctx.is_catchup) + severity_buy_bonus(spend_mult)
	var uid := next_event_uid
	next_event_uid += 1
	var row := {
		"event_uid": uid, "type": String(event["id"]), "impact_min": _now_min + lead,
		"warned": forecastable, "severity_mult": severity,
		"hazard_tier": int(event.get("hazard_tier", 1)),
		"class": String(event["class"]), "tp_cost": int(event["tp_cost"]),
		"target": target.duplicate(), "scheduled_min": _now_min,
		"warn_lead_min": lead if forecastable else 0,
		# §2.6.2 / PA-89: what it actually cost, which is `tp_cost` unless the
		# Director bought severity. The report and the save both want the bill.
		"tp_spent": float(event["tp_cost"]) * spend_mult,
	}
	tp_pool -= float(event["tp_cost"]) * spend_mult
	scheduled.append(row)
	last_event_start_min[String(event["id"])] = int(row["impact_min"])
	if ctx.is_catchup:
		offline_hazard_used = true
	if forecastable:
		_inject_weather(row, director_rng)
		# F7: notification class CRITICAL / Priority 1, exempt from ALL rate
		# limiting. It goes out the moment the event is committed.
		_emit(&"weather_warning", {"event_uid": uid, "kind": String(event["id"]),
				"impact_min": int(row["impact_min"]), "lead_min": lead,
				"severity_mult": severity, "notify_class": "CRITICAL", "priority": 1})
	# PA-04: AFTER `_inject_weather`, because that is where a weather row learns
	# its `duration_min` and the stamp is written from it.
	_stamp_resolution(row)
	_emit(&"director_event_scheduled", _row_payload(row))


## PA-04 / A91-D-59 — **give every committed event a way to end.** Two fields,
## written once at commit and carried through the save:
##
##   * `resolve_after_min` — the EARLIEST minute the event may resolve. A weather
##     event is not over while its segment is still running, so it is
##     `impact + duration`; a `severe_thunderstorm` also owes the player §2.7.6's
##     STORM REPORT, so it is `impact + max(duration, report_at_min)` — for the
##     beat sheet's 120-minute storm that is exactly T+180. An event that only
##     requests incidents may resolve the moment the last of them closes, so it
##     is `impact`.
##   * `expire_at_min` — the hold cap (`MAX_ACTIVE_MIN_DEFAULT`). Nothing waits
##     forever, however the link book was lost.
##
## The `busy` half of the test — "does this event still have an incident open?"
## — is NOT knowable here: `CitySim` owns the incident-to-event link book. This
## file owns the CLOCK half and `CitySim` joins them (`_sweep_director_events`).
func _stamp_resolution(row: Dictionary) -> void:
	stamp_resolution(row, max_active_min(), storm_report_at_min())


## The stamp, with its two knobs passed in rather than read. The live path hands
## it `data/director.json`'s values; `CitySim._v7_to_v8` hands it the constants,
## because doc 08 §2.8 forbids a migrator from opening `data/`.
static func stamp_resolution(row: Dictionary, max_active: int, report_at: int) -> void:
	var impact := int(row.get("impact_min", 0))
	var after := impact
	if row.has("duration_min"):
		after = impact + int(row["duration_min"])
	if String(row.get("type", "")) == "severe_thunderstorm":
		after = maxi(after, impact + report_at)
	row["resolve_after_min"] = after
	row["expire_at_min"] = impact + max_active


## PA-04 — which in-flight events are ready to close, as `[[uid, outcome], …]`
## in ascending uid order (the caller resolves them in that order, so two events
## closing on the same tick close in a canonical one).
##
## `busy_uids` is the set of event uids that still have at least one incident
## open, supplied by the caller. An event whose sink request was REFUSED — an
## unknown catalog type, an unresolvable target — never enters that set, so it
## resolves on the first sweep after its impact, which is the honest answer: it
## produced nothing, so there is nothing to wait for.
func events_due_for_resolution(now_min: int, busy_uids: Dictionary) -> Array:
	var out: Array = []
	for uid in _sorted_keys(active_events):
		var row: Dictionary = active_events[uid]
		var impact := int(row["impact_min"])
		if now_min >= int(row.get("expire_at_min", impact + max_active_min())):
			out.append([int(uid), OUTCOME_EXPIRED])
			continue
		if now_min < int(row.get("resolve_after_min", impact)):
			continue
		if busy_uids.has(int(uid)):
			continue
		out.append([int(uid), OUTCOME_RESOLVED])
	return out


func _inject_weather(row: Dictionary, director_rng: RandomNumberGenerator) -> void:
	if weather == null:
		return
	var impact := int(row["impact_min"])
	var uid := int(row["event_uid"])
	match String(row["type"]):
		"severe_thunderstorm":
			var band: Array = tables.storm.get("duration_min", [90, 180])
			var duration := director_rng.randi_range(int(band[0]), int(band[1]))
			var intensity := SevereThunderstorm.intensity_for(float(row["severity_mult"]),
					tables.storm.get("intensity_from_severity", {}))
			row["duration_min"] = duration
			row["intensity"] = intensity
			weather.inject_storm(impact, duration, intensity, uid)
		"heat_wave":
			var bounds := weather.tables.duration_bounds("HEAT_WAVE")
			var duration := int(bounds[0])
			row["duration_min"] = duration
			row["intensity"] = clampf(0.55 + 0.35 * float(row["severity_mult"]) - 0.35, 0.0, 1.0)
			weather.inject_segment("HEAT_WAVE", impact, duration, float(row["intensity"]), uid)
		"storm_minor":
			var duration := int(weather.tables.duration_bounds("THUNDERSTORM")[0])
			row["duration_min"] = duration
			row["intensity"] = clampf(0.30 * float(row["severity_mult"]), 0.0, 1.0)
			weather.inject_segment("THUNDERSTORM", impact, duration, float(row["intensity"]), uid)


func _fire_due_events(inputs: DirectorInputs) -> void:
	var pending: Array = []
	for row in scheduled:
		if int(row["impact_min"]) > _now_min:
			pending.append(row)
			continue
		_start_event(row, inputs)
	scheduled = pending


func _start_event(row: Dictionary, inputs: DirectorInputs) -> void:
	var uid := int(row["event_uid"])
	if not row.has("expire_at_min"):
		_stamp_resolution(row)  # PA-04: a pre-v8 row arriving from a save
	active_events[uid] = row
	_emit(&"director_event_started", _row_payload(row))
	var target: Dictionary = row.get("target", {})
	var ref := String(target.get("ref", ""))
	if ref != "":
		target_hard_exclude[ref] = _now_min + cooldown("target_hard_exclude_min")
		target_immunity[ref] = _now_min + cooldown("target_immunity_min")
	if String(row["class"]) == DirectorTables.CLASS_MAJOR:
		last_major_district = String(target.get("district_id", last_major_district))
	if String(row["type"]) == "severe_thunderstorm":
		storm.begin(uid, float(row["severity_mult"]), float(row.get("intensity", 0.77)),
				_now_min, int(row.get("duration_min", 120)),
				maxi(1, inputs.total_response_units), _rng.stream("weather").randf())
		# PA-26: the warning window's ledger becomes this storm's report line.
		storm.prep_actions = prep_actions.duplicate() if prep_event_uid == uid else []
		return
	# Everything else is one request into doc 06, which decides what it becomes.
	#
	# PA-25 / A91-D-80: the request carries doc 06's OWN type id, not this
	# catalog's. Four of the eight rows are named for the drama and not for the
	# type — a `traffic_pileup` is a `traffic_accident` — and the sink refuses
	# what it cannot find, so before this column existed those four picks were
	# silently free of consequence and expensive in TP. A row with no
	# `incident_kind` has no incident half at all (the weather rows), and asking
	# for one would be the same dead request in a different costume.
	var kind_row: Dictionary = tables.incident_kind(String(row["type"]))
	if sink != null and not kind_row.is_empty():
		sink.request_incident(StringName(String(kind_row["type"])), {
			"event_uid": uid, "ref": ref, "domain": String(target.get("domain", "")),
			"district_id": String(target.get("district_id", "")),
			"subtype": String(kind_row.get("subtype", "")),
			"candidate_source": String(kind_row.get("source", "")),
			"severity_mult": float(row["severity_mult"]),
			"hazard_tier": int(row["hazard_tier"]),
			"condition_floor": condition_floor_for(target),
			"reason": "director",
		})


## Doc 06 tells us when one requested incident closes; the storm's concurrency
## cap frees a slot. This is NOT the event's resolution — an event resolves when
## ALL its spawned incidents are cleared or expired (F2).
func on_incident_resolved(_incident_id: int, event_uid: int) -> void:
	if storm.active and storm.event_uid == event_uid:
		storm.on_incident_resolved()


## Doc 06 tells us when an event's spawned incidents are all cleared. F2's
## class cooldown starts HERE, at resolution — not at the start.
##
## PA-04: `now_min` is the caller's clock. Resolution happens at REPORT, every
## tick, while `_now_min` is only refreshed on the hourly DIRECTOR phase — so
## without it F2's from-resolution cooldowns would be quantised to the last hour
## boundary and could read up to 59 minutes early. `-1` keeps the old behaviour
## for the tests and tools that call this by hand. It only ever moves the clock
## FORWARD: `_now_min` is monotone by construction everywhere else in this file.
func on_event_resolved(event_uid: int, outcome: String = OUTCOME_RESOLVED,
		now_min: int = -1) -> void:
	if not active_events.has(event_uid):
		return
	if now_min >= 0:
		_now_min = maxi(_now_min, now_min)
	var row: Dictionary = active_events[event_uid]
	active_events.erase(event_uid)
	if String(row["type"]) == "severe_thunderstorm":
		_clear_load_shed()  # the shed lasts the storm's duration, not forever
		storm.active = false
		# PA-26: one storm's preparation is never counted toward the next one's.
		prep_actions = []
		prep_event_uid = -1
	last_event_end_min[String(row["type"])] = _now_min
	if String(row["class"]) == DirectorTables.CLASS_MAJOR:
		last_major_end_min = _now_min
		# Post-event bleed: a well-handled storm does not immediately fund the next.
		tp_pool *= float(tables.tp.get("post_event_bleed_mult", 0.5))
		post_event_bleed_until_min = _now_min + int(tables.tp.get("post_event_bleed_min", 720))
	else:
		last_minor_end_min = _now_min
	history.append({"type": String(row["type"]), "start_min": int(row["impact_min"]),
			"end_min": _now_min, "severity_mult": float(row["severity_mult"]),
			"targets": [String(row.get("target", {}).get("ref", ""))], "outcome": outcome})
	while history.size() > HISTORY_RING:
		history.remove_at(0)
	_emit(&"director_event_ended", {"event_uid": event_uid, "kind": String(row["type"]),
			"outcome": outcome, "minute": _now_min})


## Doc 08 schedules honest offline alarms off this (committed and persisted).
func forecast_queue() -> Array:
	var out: Array = []
	for row in scheduled:
		out.append({
			"event_id": int(row["event_uid"]), "kind": String(row["type"]),
			"severity": float(row["severity_mult"]), "onset_gmin": int(row["impact_min"]),
			"warning_lead_gmin": int(row.get("warn_lead_min", 0)),
			"confidence": 1.0 if bool(row["warned"]) else 0.0,
		})
	return out


## Doc 08 calls this once per catch-up session (C-55: the cap is per session,
## not per real hour).
func catchup_begin() -> void:
	offline_hazard_used = false


func drain_events() -> Array:
	var out := _events
	_events = []
	return out


func get_debug_state() -> Dictionary:
	return {"tp_pool": tp_pool, "P": _last_p, "difficulty": difficulty,
			"suppressed": bool(suppression["active"]),
			"scripted_suppressed": scripted_suppression_active(),
			"recovery": bool(recovery_mode["active"]),
			"scheduled": scheduled.size(), "active": active_events.size()}


## A scheduled row keys the catalog id as `type`, but `type` is the event-bus's
## own name field — so the id ships as `kind` and the row's `type` is dropped.
static func _row_payload(row: Dictionary) -> Dictionary:
	var payload := row.duplicate(true)
	payload["kind"] = String(row["type"])
	payload.erase("type")
	return payload


func _emit(event_type: StringName, payload: Dictionary) -> void:
	var event := payload.duplicate()
	event["type"] = event_type
	_events.append(event)


# -------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	var immunity := {}
	for ref in _sorted_keys(target_immunity):
		immunity[ref] = int(target_immunity[ref])
	var hard := {}
	for ref in _sorted_keys(target_hard_exclude):
		hard[ref] = int(target_hard_exclude[ref])
	var starts := {}
	for id in _sorted_keys(last_event_start_min):
		starts[id] = int(last_event_start_min[id])
	var ends := {}
	for id in _sorted_keys(last_event_end_min):
		ends[id] = int(last_event_end_min[id])
	var actives: Array = []
	for uid in _sorted_keys(active_events):
		actives.append((active_events[uid] as Dictionary).duplicate(true))
	return {
		"section_version": 1,
		"difficulty": difficulty,
		"tp_pool": tp_pool,
		"now_min": _now_min,
		"next_event_uid": next_event_uid,
		"last_event_start_min": starts,
		"last_event_end_min": ends,
		"last_major_end_min": last_major_end_min,
		"last_minor_end_min": last_minor_end_min,
		"last_major_district": last_major_district,
		"history": history.duplicate(true),
		"target_immunity": immunity,
		"target_hard_exclude": hard,
		"suppression": suppression.duplicate(true),
		"suppress_until_min": suppress_until_min,
		"recovery_mode": recovery_mode.duplicate(true),
		"scheduled": scheduled.duplicate(true),
		"active_events": actives,
		"pop_peak_7d": pop_peak_7d,
		"pop_history": _pop_history.duplicate(true),
		"offline_hazard_used": offline_hazard_used,
		"post_event_bleed_until_min": post_event_bleed_until_min,
		"debt_since_min": debt_since_min,
		"prep_actions": prep_actions.duplicate(),
		"prep_event_uid": prep_event_uid,
		"active_storm": storm.serialize() if storm.active else null,
	}


func deserialize(data: Dictionary) -> void:
	difficulty = String(data.get("difficulty", "standard"))
	_difficulty_locked = data.has("difficulty")
	tp_pool = float(data.get("tp_pool", 0.0))
	_now_min = int(data.get("now_min", 0))
	next_event_uid = int(data.get("next_event_uid", 1))
	last_event_start_min.clear()
	for id in data.get("last_event_start_min", {}):
		last_event_start_min[String(id)] = int(data["last_event_start_min"][id])
	last_event_end_min.clear()
	for id in data.get("last_event_end_min", {}):
		last_event_end_min[String(id)] = int(data["last_event_end_min"][id])
	last_major_end_min = int(data.get("last_major_end_min", -1000000))
	last_minor_end_min = int(data.get("last_minor_end_min", -1000000))
	last_major_district = String(data.get("last_major_district", ""))
	# JSON hands every number back as a double, so integer fields are re-cast on
	# load. Without this the save is not a fixed point and a reloaded city would
	# drift from the one that saved it (constitution §5).
	history.clear()
	for raw in data.get("history", []):
		var row: Dictionary = (raw as Dictionary).duplicate()
		row["start_min"] = int(row.get("start_min", 0))
		row["end_min"] = int(row.get("end_min", 0))
		history.append(row)
	target_immunity.clear()
	for ref in data.get("target_immunity", {}):
		target_immunity[String(ref)] = int(data["target_immunity"][ref])
	target_hard_exclude.clear()
	for ref in data.get("target_hard_exclude", {}):
		target_hard_exclude[String(ref)] = int(data["target_hard_exclude"][ref])
	var raw_suppression: Dictionary = data.get("suppression",
			{"active": false, "reasons": [], "since_min": -1, "clear_at_min": -1})
	suppression = {"active": bool(raw_suppression.get("active", false)),
			"reasons": raw_suppression.get("reasons", []),
			"since_min": int(raw_suppression.get("since_min", -1)),
			"clear_at_min": int(raw_suppression.get("clear_at_min", -1))}
	suppress_until_min = int(data.get("suppress_until_min", -1))
	var raw_recovery: Dictionary = data.get("recovery_mode", {"active": false, "until_min": -1})
	recovery_mode = {"active": bool(raw_recovery.get("active", false)),
			"until_min": int(raw_recovery.get("until_min", -1))}
	# PA-04: a body written before rung 8 carries rows with no resolution stamp.
	# `CitySim._v7_to_v8` writes one in on the way past, and this is the second
	# belt: a fragment restored without the ladder (a fixture, a test, a tool)
	# still gets an event that can end.
	scheduled.clear()
	for raw in data.get("scheduled", []):
		var pending := _normalize_row(raw)
		if not pending.has("expire_at_min"):
			_stamp_resolution(pending)
		scheduled.append(pending)
	active_events.clear()
	for raw in data.get("active_events", []):
		var row := _normalize_row(raw)
		if not row.has("expire_at_min"):
			_stamp_resolution(row)
		active_events[int(row["event_uid"])] = row
	pop_peak_7d = int(data.get("pop_peak_7d", 0))
	_pop_history.clear()
	for entry in data.get("pop_history", []):
		_pop_history.append([int(entry[0]), int(entry[1])])
	offline_hazard_used = bool(data.get("offline_hazard_used", false))
	post_event_bleed_until_min = int(data.get("post_event_bleed_until_min", -1))
	debt_since_min = int(data.get("debt_since_min", -1))
	prep_actions = []
	for action in data.get("prep_actions", []):
		prep_actions.append(String(action))
	prep_event_uid = int(data.get("prep_event_uid", -1))
	var storm_state: Variant = data.get("active_storm", null)
	if typeof(storm_state) == TYPE_DICTIONARY:
		storm.deserialize(storm_state)
	else:
		storm = SevereThunderstorm.new(tables)


static func _normalize_row(raw: Variant) -> Dictionary:
	var row: Dictionary = (raw as Dictionary).duplicate(true)
	for key in ["event_uid", "impact_min", "hazard_tier", "tp_cost", "scheduled_min",
			"warn_lead_min", "duration_min", "resolve_after_min", "expire_at_min"]:
		if row.has(key):
			row[key] = int(row[key])
	return row


static func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
