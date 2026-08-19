class_name NotificationBudget
extends RefCounted
## doc 08 §2.13.2's rate limiter and §2.13.3's quiet hours, verbatim.
##
## `RefCounted`, Node-free, **clock-injected**: every call takes the time, so a
## test can walk six hours in six lines and get the same answer twice. There is
## no `Time` call anywhere in this file — the one device-local wall-clock read in
## the game lives in `NotificationRouter`, which is the platform layer, and is
## handed here as two plain numbers.
##
## The doc's rule, in the doc's order:
##
##     allow(event, class, now) =
##           user_enabled[class]
##       and class_bucket.tokens >= 1  and  global_bucket.tokens >= 1
##       and now - last_any_sent            >= global_min_gap_minutes (5)
##       and now - last_sent_class[class]   >= class.min_gap_minutes
##       and now - last_sent_key[event.key] >= event.cooldown_minutes
##       and not blocked_by_quiet_hours(class, event.severity, now)
##
## **A denial is not a loss.** Doc 08 is explicit and it is the whole ethic of
## the feature: on deny the event *still enters the ring and still appears in the
## report* — only the buzz is withheld. So this class returns a reason, never a
## silence, and `NotificationRouter` keeps every denied plan.
##
## Two token buckets, both refilled continuously rather than on a tick, because
## the app is not running most of the time a bucket is refilling. `refill` is a
## pure function of elapsed minutes, so an eight-hour absence and eight hours of
## foreground produce identical buckets.

## Why a request was refused. These strings are the `reason` doc 08 attaches to
## `notification_suppressed(key, reason)` and they are stable — a test asserts
## on them and so, eventually, will a support log.
const REASON_OK := ""
const REASON_CLASS_DISABLED := "class_disabled"
const REASON_CLASS_BUCKET := "class_bucket"
const REASON_GLOBAL_BUCKET := "global_bucket"
const REASON_GLOBAL_GAP := "global_min_gap"
const REASON_CLASS_GAP := "class_min_gap"
const REASON_KEY_COOLDOWN := "key_cooldown"
const REASON_QUIET_HOURS := "quiet_hours"

const MINUTES_PER_DAY := 1440

var _cfg: NotificationConfig
var _runtime: Dictionary = {}
var _quiet: Dictionary = {}

## class id -> tokens (float; a bucket is only meaningful as a fraction).
var _tokens: Dictionary = {}
var _global_tokens := 0.0
## The minute each bucket was last refilled to, so refill is idempotent.
var _refilled_at := 0.0
var _started := false

var _last_any := -1.0e9
var _last_class: Dictionary = {}
var _last_key: Dictionary = {}

## Player switches (doc 08 §2.13.4). Defaults come from the class table; the
## shell overwrites them from `user://settings.cfg`, which is why they are
## per-instance state and not a config read.
var _enabled: Dictionary = {}
var _allow_critical_in_quiet := false


func _init(cfg: NotificationConfig = null) -> void:
	_cfg = cfg if cfg != null else NotificationConfig.new()
	_runtime = _cfg.runtime()
	_quiet = _cfg.quiet_hours()
	_allow_critical_in_quiet = bool(_quiet.get("allow_critical", false))
	for class_id: String in _cfg.class_ids():
		_enabled[class_id] = _cfg.class_enabled(class_id)
		_tokens[class_id] = float(AudioConfig.get_int(_cfg.class_def(class_id), "capacity", 0))
	_global_tokens = float(AudioConfig.get_int(_runtime, "global_capacity", 0))


func config() -> NotificationConfig:
	return _cfg


## The player's per-class switch (doc 08 §2.13.4). A class the slice ships
## disabled can never be switched ON here — P4 has no Android channel in MVP, so
## enabling it would promise a delivery nothing can make.
func set_class_enabled(class_id: String, on: bool) -> void:
	if not _cfg.class_enabled(class_id):
		_enabled[class_id] = false
		return
	_enabled[class_id] = on


func class_enabled(class_id: String) -> bool:
	return bool(_enabled.get(class_id, false))


## *"Allow critical alerts during quiet hours"*, default OFF (doc 08 §2.13.3).
func set_allow_critical_in_quiet(on: bool) -> void:
	_allow_critical_in_quiet = on


func allow_critical_in_quiet() -> bool:
	return _allow_critical_in_quiet


# ---------------------------------------------------------------------------
# Buckets
# ---------------------------------------------------------------------------

## `b.tokens = min(b.capacity, b.tokens + elapsed_min * b.capacity / b.window_minutes)`
## — doc 08's line, for every bucket at once. Called before every decision and
## idempotent within a minute, so asking twice cannot refill twice.
func refill(now_min: float) -> void:
	if not _started:
		_started = true
		_refilled_at = now_min
		return
	var elapsed := now_min - _refilled_at
	if elapsed <= 0.0:
		return
	_refilled_at = now_min
	for class_id: String in _cfg.class_ids():
		var row := _cfg.class_def(class_id)
		var capacity := float(AudioConfig.get_int(row, "capacity", 0))
		var window := maxf(1.0, float(AudioConfig.get_int(row, "window_minutes", 1)))
		_tokens[class_id] = minf(capacity,
				float(_tokens.get(class_id, 0.0)) + elapsed * capacity / window)
	var global_capacity := float(AudioConfig.get_int(_runtime, "global_capacity", 0))
	var global_window := maxf(1.0, float(AudioConfig.get_int(_runtime,
			"global_window_minutes", 1)))
	_global_tokens = minf(global_capacity,
			_global_tokens + elapsed * global_capacity / global_window)


func tokens(class_id: String) -> float:
	return float(_tokens.get(class_id, 0.0))


func global_tokens() -> float:
	return _global_tokens


# ---------------------------------------------------------------------------
# Quiet hours (doc 08 §2.13.3)
# ---------------------------------------------------------------------------

## Device-local minutes past midnight. The window **wraps**: 22:00–08:00 is
## `start 1320, end 480`, and a zero-length window disables the feature outright
## (a player who set both ends the same asked for no quiet hours, not for a
## permanently quiet game).
func in_quiet_window(minute_of_day: int) -> bool:
	if not bool(_quiet.get("enabled", false)):
		return false
	var start := AudioConfig.get_int(_quiet, "start_min", 0)
	var end := AudioConfig.get_int(_quiet, "end_min", 0)
	if start == end:
		return false
	var minute := posmod(minute_of_day, MINUTES_PER_DAY)
	if start < end:
		return minute >= start and minute < end
	return minute >= start or minute < end


## The bypass is deliberately hard to earn: the class must nominate a severity
## floor (only P1 does — every other class's is 99), the event must reach it,
## AND the player must have turned the bypass on, which ships OFF. A P1 at 03:00
## is otherwise deferred, not lost: it is in the ring, it is in the report, and
## it is in the 08:00 summary. Informed, not woken.
func blocked_by_quiet_hours(class_id: String, severity: int, minute_of_day: int) -> bool:
	if not in_quiet_window(minute_of_day):
		return false
	if not _allow_critical_in_quiet:
		return true
	var floor_severity := AudioConfig.get_int(_cfg.class_def(class_id),
			"quiet_bypass_min_severity", NotificationConfig.RANK_UNKNOWN)
	return severity < floor_severity


# ---------------------------------------------------------------------------
# The decision
# ---------------------------------------------------------------------------

## Test the rule without spending anything. Returns `REASON_OK` or the first
## reason that failed, in doc 08's order — the order matters, because it is the
## reason the player is eventually shown.
func check(class_id: String, severity: int, key: String, cooldown_minutes: float,
		now_min: float, minute_of_day: int) -> String:
	if not class_enabled(class_id):
		return REASON_CLASS_DISABLED
	if float(_tokens.get(class_id, 0.0)) < 1.0:
		return REASON_CLASS_BUCKET
	if _global_tokens < 1.0:
		return REASON_GLOBAL_BUCKET
	if now_min - _last_any < AudioConfig.get_num(_runtime, "global_min_gap_minutes", 0.0):
		return REASON_GLOBAL_GAP
	var class_gap := float(AudioConfig.get_int(_cfg.class_def(class_id), "min_gap_minutes", 0))
	if now_min - float(_last_class.get(class_id, -1.0e9)) < class_gap:
		return REASON_CLASS_GAP
	if key != "" and now_min - float(_last_key.get(key, -1.0e9)) < cooldown_minutes:
		return REASON_KEY_COOLDOWN
	if blocked_by_quiet_hours(class_id, severity, minute_of_day):
		return REASON_QUIET_HOURS
	return REASON_OK


## Refill, decide, and — on allow — spend. Both buckets are decremented and all
## three timestamps stamped, exactly as doc 08 specifies; on deny nothing moves,
## so a refused notification costs the next one nothing.
func request(class_id: String, severity: int, key: String, cooldown_minutes: float,
		now_min: float, minute_of_day: int) -> String:
	refill(now_min)
	var reason := check(class_id, severity, key, cooldown_minutes, now_min, minute_of_day)
	if reason != REASON_OK:
		return reason
	_tokens[class_id] = float(_tokens[class_id]) - 1.0
	_global_tokens -= 1.0
	_last_any = now_min
	_last_class[class_id] = now_min
	if key != "":
		_last_key[key] = now_min
	return REASON_OK


# ---------------------------------------------------------------------------
# Persistence — doc 08 §2.13.2: "persisted in the `notifications` section so
# limits survive restarts". A player who closes the app cannot get a fresh
# bucket by doing so.
# ---------------------------------------------------------------------------

func serialize() -> Dictionary:
	var per_class: Dictionary = {}
	var last_class: Dictionary = {}
	for class_id: String in _cfg.class_ids():
		per_class[class_id] = float(_tokens.get(class_id, 0.0))
		last_class[class_id] = float(_last_class.get(class_id, -1.0e9))
	var keys: Dictionary = {}
	for key: Variant in _sorted(_last_key):
		keys[str(key)] = float(_last_key[key])
	return {
		"section_version": 1,
		"tokens": per_class,
		"global_tokens": _global_tokens,
		"refilled_at_min": _refilled_at,
		"started": _started,
		"last_any_min": _last_any,
		"last_class_min": last_class,
		"last_key_min": keys,
		"enabled": _enabled.duplicate(true),
		"allow_critical_in_quiet": _allow_critical_in_quiet,
	}


func deserialize(data: Dictionary) -> void:
	var per_class: Variant = data.get("tokens", {})
	if per_class is Dictionary:
		for class_id: String in _cfg.class_ids():
			if (per_class as Dictionary).has(class_id):
				_tokens[class_id] = float((per_class as Dictionary)[class_id])
	_global_tokens = AudioConfig.get_num(data, "global_tokens", _global_tokens)
	_refilled_at = AudioConfig.get_num(data, "refilled_at_min", _refilled_at)
	_started = bool(data.get("started", _started))
	_last_any = AudioConfig.get_num(data, "last_any_min", _last_any)
	var last_class: Variant = data.get("last_class_min", {})
	if last_class is Dictionary:
		for key: Variant in (last_class as Dictionary):
			_last_class[str(key)] = float((last_class as Dictionary)[key])
	var last_key: Variant = data.get("last_key_min", {})
	if last_key is Dictionary:
		for key: Variant in (last_key as Dictionary):
			_last_key[str(key)] = float((last_key as Dictionary)[key])
	var enabled: Variant = data.get("enabled", {})
	if enabled is Dictionary:
		for key: Variant in (enabled as Dictionary):
			set_class_enabled(str(key), bool((enabled as Dictionary)[key]))
	_allow_critical_in_quiet = bool(data.get("allow_critical_in_quiet",
			_allow_critical_in_quiet))


## Sorted keys, so a save file is byte-stable across runs (constitution §5).
static func _sorted(source: Dictionary) -> Array:
	var out: Array = source.keys()
	out.sort()
	return out
