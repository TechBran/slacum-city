class_name NotificationScheduler
extends RefCounted
## **What the city will do while nobody is watching** (doc 13 §2.4, doc 08 §2.13.0,
## doc 01 §2.11).
##
## The sim does not run while the app is closed — not a compromise, an
## architecture (doc 13 §2.1: there is no foreground-service type for "keep
## simulating a city", and a partial background sim would make offline outcomes
## depend on the player's battery settings, which constitution §5 forbids). So
## every notification about the future must be *predicted at pause time* and armed
## with Android before the process stops existing.
##
## Report C-23 split that problem by **how the fire time is known**, and the split
## is what makes the horizon question disappear:
##
## | Class | Fire time known from | Horizon | Projection |
## |---|---|---|---|
## | **(a) deterministic timers** | already in the save | the full 12-real-hour cap | none |
## | **(b) pre-rolled Director forecast** | already in the save | the full cap | none |
## | (c) emergent risk | only by running the sim | 12–60 real *minutes* | **ships disabled** |
##
## This class implements (a) and (b) and nothing else, which is not a shortcut:
## they carry every notification the vertical slice needs, out to the whole cap,
## for zero milliseconds of pause budget. Class (c) buys minutes, not hours
## (`data/notifications.json` → `emergent_projection_enabled: false`).
##
## The conversion is doc 01 §2.11's, and this is the only place in the game that
## performs it:
##
##     real_ms  = (due_tick − now_tick) × 250        # 15 game-s per tick ÷ 60×
##     fire_at  = background_unix + real_ms / 1000
##
## Two guards then decide whether an entry is worth arming at all:
##
## * **Beyond the offline cap → dropped.** A timer 44 000 real seconds out would
##   describe a future the catch-up never reaches: `elapsed` is clamped to
##   `catchup.offline_cap_real_ms` (12 real hours, ruling C-19), so the sim would
##   still be short of that tick when the player returns. An alarm for a thing
##   that has not happened is worse than silence.
## * **Inside the Doze slop → dropped.** Alarms are inexact by choice (doc 13 §2.6:
##   `SCHEDULE_EXACT_ALARM` is Play-restricted to clocks and calendars, and asking
##   for it risks the listing), so delivery can slip ~15 minutes. An entry with
##   less lead than `doze_slop_s + min_useful_lead_s` would arrive after the thing
##   it announces. Dropped, not delivered late.
##
## **What this class never does:** rate limiting, quiet hours, coalescing, class
## assignment. All four are doc 08's and live in `NotificationRouter` /
## `NotificationBudget` (report C-71). This class answers one question — *when* —
## and hands the answer to the router, which decides *whether*.

## doc 01 §2.11: 15 game-seconds per tick at the locked 60× scale.
const REAL_MS_PER_TICK := 250
## Fallback when `data/time.json` cannot be read: ruling C-19's 12 real hours.
const DEFAULT_OFFLINE_CAP_S := 43_200.0
## doc 13 §8 `notification_platform.doze_slop_s` + `min_useful_lead_s`.
const DOZE_SLOP_S := 900.0
const MIN_USEFUL_LEAD_S := 300.0
## The ETA walk never looks further than the cap — 720 game-hours, one step each.
const MAX_ETA_HOURS := 720

const TIME_JSON_PATH := "res://data/time.json"

## Job kinds worth telling the player about, and the event key each becomes.
## `repair`, `road` and `clear_rubble` are deliberately absent: they finish in
## minutes and doc 08's table has no push row for them.
const JOB_NOTIFY_ID := {
	"build": "construction_complete",
	"upgrade": "construction_complete",
	"development": "land_developed",
}

var errors: PackedStringArray = []

## Real seconds of absence the sim will actually simulate (doc 01's cap).
var offline_cap_s: float = DEFAULT_OFFLINE_CAP_S
## Set false to keep scheduling but stop applying the Doze feasibility filter —
## used by tests that assert the guard rather than depend on it.
var doze_guard_enabled := true
## `data/notifications.json.delivery`'s two guard numbers, and the map of which
## events are predictable at all. Defaults match the constants above so an
## unconfigured scheduler still behaves.
var doze_slop_s: float = DOZE_SLOP_S
var min_useful_lead_s: float = MIN_USEFUL_LEAD_S
var offline_sources: Dictionary = {}

## Why each rejected candidate was rejected, newest last. Diagnostics only.
var last_drops: Array[Dictionary] = []


static func load_from_files(path: String = TIME_JSON_PATH) -> NotificationScheduler:
	var scheduler := NotificationScheduler.new()
	if not FileAccess.file_exists(path):
		scheduler.errors.append("missing %s" % path)
		return scheduler
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		scheduler.errors.append("cannot parse %s" % path)
		return scheduler
	var catchup: Variant = (parsed as Dictionary).get("catchup", {})
	if catchup is Dictionary:
		# The cap is doc 01's constant and this class only reads it — doc 13 owns
		# no cap of its own (ruling C-19 deleted the one it used to have).
		scheduler.offline_cap_s = float(AudioConfig.get_num(catchup,
				"offline_cap_real_ms", DEFAULT_OFFLINE_CAP_S * 1000.0)) / 1000.0
	return scheduler


## Take the platform half of `data/notifications.json` (`delivery`). Separate from
## the constructor because the router owns that file and this class must never
## open it — one reader per file is the rule the whole notification stack keeps.
func configure(delivery: Dictionary) -> void:
	doze_slop_s = AudioConfig.get_num(delivery, "doze_slop_s", DOZE_SLOP_S)
	min_useful_lead_s = AudioConfig.get_num(delivery, "min_useful_lead_s",
			MIN_USEFUL_LEAD_S)
	var sources: Variant = delivery.get("offline_sources", {})
	offline_sources = sources if sources is Dictionary else {}


## Whether an event may be pre-scheduled at all, per the `offline_sources` map.
## An unconfigured scheduler says yes to everything it can predict, which is what
## a fixture-driven test wants; a configured one obeys the file.
func offline_allowed(notify_id: String) -> bool:
	return offline_sources.is_empty() or offline_sources.has(notify_id)


# ---------------------------------------------------------------------------
# Collection
# ---------------------------------------------------------------------------

## Everything the city can honestly promise, as router-ready entries:
## `{notify_id, ref, args, fire_at_unix, due_tick, source}`.
##
## `sim` is read through public members only and every read is guarded — this
## runs inside the pause sequence, where a missing subsystem must degrade to
## "fewer notifications", never to a crash on the way out of the app.
func collect(sim: Object, now_unix: float) -> Array[Dictionary]:
	last_drops.clear()
	var out: Array[Dictionary] = []
	if sim == null:
		return out
	var now_tick := _now_tick(sim)
	if now_tick < 0:
		return out
	out.append_array(_construction_entries(sim, now_tick))
	out.append_array(_timer_entries(sim, now_tick))
	out.append_array(_forecast_entries(sim, now_tick))
	var kept: Array[Dictionary] = []
	for entry: Dictionary in out:
		var delay_s := _real_delay_s(int(entry["due_tick"]), now_tick)
		if not offline_allowed(str(entry["notify_id"])):
			_drop(entry, "not_offline_schedulable", delay_s)
			continue
		if delay_s > offline_cap_s:
			_drop(entry, "beyond_offline_cap", delay_s)
			continue
		if doze_guard_enabled and delay_s < doze_slop_s + min_useful_lead_s:
			_drop(entry, "inside_doze_slop", delay_s)
			continue
		entry["fire_at_unix"] = now_unix + delay_s
		entry["real_delay_s"] = delay_s
		kept.append(entry)
	# Sorted by fire time, then by key: the router spends its budget forward in
	# time, so the order it sees has to be the order the player will.
	kept.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a["fire_at_unix"]), float(b["fire_at_unix"])):
			return float(a["fire_at_unix"]) < float(b["fire_at_unix"])
		return str(a["ref"]) < str(b["ref"]))
	return kept


## doc 01 §2.11's conversion, and the only copy of it in the game.
func _real_delay_s(due_tick: int, now_tick: int) -> float:
	return float(maxi(0, due_tick - now_tick)) * float(REAL_MS_PER_TICK) / 1000.0


func _drop(entry: Dictionary, reason: String, delay_s: float) -> void:
	last_drops.append({
		"notify_id": str(entry.get("notify_id", "")),
		"ref": str(entry.get("ref", "")),
		"reason": reason,
		"real_delay_s": delay_s,
	})


# --------------------------------------------------- (a) deterministic timers

## Construction and upgrades. The completion tick is not stored anywhere — a job
## carries work units, not a deadline — so it is *derived* by walking the
## construction-rate curve forward, which is exact under the one assumption that
## the crew roster does not change while the app is closed. It cannot: nothing
## runs.
func _construction_entries(sim: Object, now_tick: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var queue: Object = _member(sim, "construction")
	if queue == null or not queue.has_method("active_jobs"):
		return out
	for raw: Variant in queue.call("active_jobs"):
		if not (raw is Dictionary):
			continue
		var job: Dictionary = raw
		var notify_id := str(JOB_NOTIFY_ID.get(str(job.get("kind", "")), ""))
		if notify_id == "":
			continue
		var due := eta_tick(sim, job, now_tick)
		if due < 0:
			continue
		var payload: Variant = job.get("payload", {})
		var sim_id := str((payload as Dictionary).get("sim_id", "")) if payload is Dictionary else ""
		var ref := sim_id if sim_id != "" else str(job.get("target_ref", ""))
		out.append({
			"notify_id": notify_id,
			"ref": ref,
			"args": _construction_args(sim, job, ref),
			"due_tick": due,
			"source": "construction",
		})
	return out


func _construction_args(sim: Object, job: Dictionary, ref: String) -> Dictionary:
	if str(JOB_NOTIFY_ID.get(str(job.get("kind", "")), "")) == "land_developed":
		return {"block": ref}
	var level := 0
	var buildings: Variant = sim.get("buildings") if "buildings" in sim else null
	if buildings is Dictionary and (buildings as Dictionary).has(ref):
		var building: Variant = (buildings as Dictionary)[ref]
		if building is Object and "level" in building:
			level = int((building as Object).get("level"))
	# `Building.level` is **0 while a build is in progress** — the level the
	# player will see is the one the job delivers, not the one it started from.
	# A new build delivers L1; an upgrade delivers one above where it is now.
	# Reading the live field alone would render "A Level 0 building came online."
	if str(job.get("kind", "")) == "upgrade":
		level += 1
	return {"level": maxi(1, level)}


## The completion tick of one job, or -1 when it has no crew (a job nobody is
## working on has no honest completion time, and promising one would be the
## worst kind of notification: confidently wrong).
##
## The accumulation mirrors `ConstructionQueue.advance()` exactly — crew rate ×
## site multiplier × the hour's `construction_rate` channel — and steps hour by
## hour because that channel is a day curve, not a constant. Walking it is what
## makes an overnight job land on the right minute instead of the mean.
func eta_tick(sim: Object, job: Dictionary, now_tick: int) -> int:
	var required := int(job.get("required_work_units", 0))
	var done := int(job.get("work_units", 0))
	if required <= 0:
		return -1
	if done >= required:
		return now_tick
	var crew_permille := 0
	var crews: Variant = job.get("assigned_crews", {})
	if crews is Dictionary:
		for crew_id: Variant in (crews as Dictionary):
			crew_permille += int((crews as Dictionary)[crew_id])
	if crew_permille <= 0:
		return -1
	var site_permille := int(job.get("site_mult_permille", 1000))
	var remaining := float(required - done)
	var tick := now_tick
	for _step in MAX_ETA_HOURS:
		var eff_permille := _construction_rate_permille(sim, tick)
		# Per game-second, by ConstructionQueue's own arithmetic:
		#   units = crew × site × eff × dt / 36_000_000_000
		var per_second := float(crew_permille) * float(site_permille) \
				* float(eff_permille) / 36_000_000_000.0
		var seconds_left_in_hour := _seconds_to_next_hour(tick)
		if per_second <= 0.0:
			tick += seconds_left_in_hour / GameClock.GAME_SECONDS_PER_TICK
			continue
		var seconds_needed := remaining / per_second
		if seconds_needed <= float(seconds_left_in_hour):
			return tick + int(ceil(seconds_needed / float(GameClock.GAME_SECONDS_PER_TICK)))
		remaining -= per_second * float(seconds_left_in_hour)
		tick += seconds_left_in_hour / GameClock.GAME_SECONDS_PER_TICK
	return -1


## Game-seconds from `tick` to the next whole game-hour (never 0 — a walk that
## could stand still would not terminate).
static func _seconds_to_next_hour(tick: int) -> int:
	var absolute := tick * GameClock.GAME_SECONDS_PER_TICK \
			+ GameClock.FOUNDING_OFFSET_MINUTES * 60
	var into_hour := absolute % 3600
	return 3600 - into_hour if into_hour > 0 else 3600


## `construction_rate` for the hour containing `tick`, in per-mille — the same
## value `TickScheduler._hour_channels()` would resolve, sampled at the hour
## midpoint and passed through the modifier stack and the channel clamp.
func _construction_rate_permille(sim: Object, tick: int) -> int:
	var curves: Object = _member(sim, "curves")
	if curves == null or not curves.has_method("channel_curve_value"):
		return 1000
	var minutes := tick * GameClock.GAME_SECONDS_PER_TICK / 60 \
			+ GameClock.FOUNDING_OFFSET_MINUTES
	var hour := (minutes % GameClock.MINUTES_PER_DAY) / 60
	var midpoint := float(hour) + 0.5
	var value := float(curves.call("channel_curve_value", "construction_rate", midpoint))
	var modifiers: Object = _member(sim, "modifiers")
	if modifiers != null and modifiers.has_method("product_for"):
		value *= float(modifiers.call("product_for", "construction_rate"))
	if curves.has_method("channel_clamp"):
		value = float(curves.call("channel_clamp", "construction_rate", value))
	return roundi(value * 1000.0)


## doc 01's own class (a): any timer the sim flagged `notify_offline`. Its
## `due_tick` is absolute and already in the save, so no derivation is involved —
## this is the case doc 01 §2.11 says "converts cleanly", and it does.
func _timer_entries(sim: Object, now_tick: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var timers: Object = _member(sim, "timers")
	if timers == null or not timers.has_method("serialize"):
		return out
	var state: Variant = timers.call("serialize")
	if not (state is Dictionary):
		return out
	var rows: Variant = (state as Dictionary).get("timers", [])
	if not (rows is Array):
		return out
	for raw: Variant in (rows as Array):
		if not (raw is Dictionary):
			continue
		var timer: Dictionary = raw
		if not bool(timer.get("notify_offline", false)):
			continue
		var due := int(timer.get("due_tick", -1))
		if due <= now_tick:
			continue
		var payload: Variant = timer.get("payload", {})
		var payload_dict: Dictionary = payload if payload is Dictionary else {}
		var notify_id := str(payload_dict.get("notify_id", ""))
		if notify_id == "":
			continue  # nothing to render; a timer without a key is not a message
		var args: Variant = payload_dict.get("args", {})
		out.append({
			"notify_id": notify_id,
			"ref": str(payload_dict.get("ref", timer.get("id", ""))),
			"args": args if args is Dictionary else {},
			"due_tick": due,
			"source": "timer",
		})
	return out


# ------------------------------------------------ (b) pre-rolled Director events

## The Disaster Director commits its forecastable events at *roll* time, not at
## onset (doc 07's `forecast_queue()`), which is the entire reason a storm warning
## can be scheduled at all: the storm exists in the save before the player leaves.
## Without that commitment, class (b) is empty and spec §22's flagship
## notification — the storm warning — becomes impossible, because class (c) ships
## disabled and buys minutes anyway.
func _forecast_entries(sim: Object, now_tick: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var director: Object = _member(sim, "director")
	if director == null or not director.has_method("forecast_queue"):
		return out
	for raw: Variant in director.call("forecast_queue"):
		if not (raw is Dictionary):
			continue
		var row: Dictionary = raw
		# doc 08 §2.13.0: scheduled only at confidence ≥ 0.80. An unwarned event
		# is not a forecast, it is a surprise, and announcing it would be a lie
		# about what the city knows.
		if float(row.get("confidence", 0.0)) < 0.8:
			continue
		var lead_gmin := int(row.get("warning_lead_gmin", 0))
		if lead_gmin <= 0:
			continue
		var warn_gmin := int(row.get("onset_gmin", 0)) - lead_gmin
		var due := _tick_of_game_minute(warn_gmin)
		if due <= now_tick:
			continue
		out.append({
			"notify_id": "weather_warning",
			"ref": str(row.get("event_id", "")),
			"args": {"minutes": lead_gmin, "kind": str(row.get("kind", ""))},
			"due_tick": due,
			"source": "forecast",
		})
	return out


## Director minutes are `_now_min` — sim minutes since founding, the same scale
## `GameClock.sim_time_minutes()` reports — so the tick is a multiplication and
## not a calendar conversion.
static func _tick_of_game_minute(game_minute: int) -> int:
	return game_minute * GameClock.TICKS_PER_MINUTE


func _now_tick(sim: Object) -> int:
	var clock: Object = _member(sim, "clock")
	if clock == null or not ("tick_index" in clock):
		return -1
	return int(clock.get("tick_index"))


static func _member(owner: Object, property: String) -> Object:
	if owner == null or not (property in owner):
		return null
	var value: Variant = owner.get(property)
	return value as Object if value is Object else null
