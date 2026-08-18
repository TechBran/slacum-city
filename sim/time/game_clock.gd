class_name GameClock
extends RefCounted
## Canonical simulation clock (doc 01 §2.1–2.2, constitution §4 as amended).
## `tick_index` — whole SimTicks since founding — is the authoritative persisted counter.
## `sim_time_minutes` is a derived view written alongside it (report 98 C-01).
## Structural constants are constitution-locked; data/time.json mirrors them and
## DataRegistry asserts equality at boot.

const GAME_SECONDS_PER_TICK: int = 15
const TICKS_PER_MINUTE: int = 4
const TICKS_PER_HOUR: int = 240
const TICKS_PER_DAY: int = 5760
const MINUTES_PER_DAY: int = 1440
const DAYS_PER_WEEK: int = 7
const DAYS_PER_SEASON: int = 30
const SEASONS_PER_YEAR: int = 4
const DAYS_PER_YEAR: int = 120
const FOUNDING_OFFSET_MINUTES: int = 360  # founded day 0 (Monday) at 06:00

const DAY_PHASES: Array[Dictionary] = [
	{"id": &"DAWN", "start": 300, "end": 420},
	{"id": &"MORNING_RUSH", "start": 420, "end": 570},
	{"id": &"MIDDAY", "start": 570, "end": 990},
	{"id": &"EVENING_RUSH", "start": 990, "end": 1140},
	{"id": &"EVENING", "start": 1140, "end": 1320},
]

var tick_index: int = 0
var residual_game_ms: int = 0  # 0 <= r < 15000; sub-tick remainder, persisted


func advance_ticks(n: int) -> void:
	assert(n >= 0, "clock never goes backwards")
	tick_index += n


func game_seconds() -> int:
	return tick_index * GAME_SECONDS_PER_TICK


func abs_minutes() -> int:
	return game_seconds() / 60 + FOUNDING_OFFSET_MINUTES


func sim_time_minutes() -> int:
	return tick_index / TICKS_PER_MINUTE


func day_index() -> int:
	return abs_minutes() / MINUTES_PER_DAY


func minute_of_day() -> int:
	return abs_minutes() % MINUTES_PER_DAY


func hour_of_day() -> int:
	return minute_of_day() / 60


func day_of_week() -> int:
	return day_index() % DAYS_PER_WEEK  # 0 = Monday


func day_type() -> int:
	return 1 if day_of_week() >= 5 else 0  # 0 weekday, 1 weekend


func season_index() -> int:
	return (day_index() / DAYS_PER_SEASON) % SEASONS_PER_YEAR


func season_progress() -> float:
	return float((day_index() % DAYS_PER_SEASON) * MINUTES_PER_DAY + minute_of_day()) / 43200.0


func year_index() -> int:
	return day_index() / DAYS_PER_YEAR


func day_phase() -> StringName:
	var m := minute_of_day()
	for p in DAY_PHASES:
		if m >= int(p["start"]) and m < int(p["end"]):
			return p["id"]
	return &"NIGHT"  # 22:00–05:00, wrapping midnight


## Curve sample position for the CURRENT fine tick: the midpoint of this tick's
## 15 game-seconds, as an hour-of-day float. The 240 per-tick midpoints of an hour
## are symmetric about h+0.5, so their mean equals the coarse midpoint sample
## exactly (doc 01 §2.6 guarantee; per-tick precision is required for T-09).
func fine_sample_hour() -> float:
	var gs_into_hour := (game_seconds() + FOUNDING_OFFSET_MINUTES * 60) % 3600
	return float(hour_of_day()) + (float(gs_into_hour) + 7.5) / 3600.0


func serialize() -> Dictionary:
	return {
		"section_version": 1,
		"tick_index": tick_index,
		"residual_game_ms": residual_game_ms,
	}


func deserialize(data: Dictionary) -> void:
	tick_index = int(data.get("tick_index", 0))
	residual_game_ms = int(data.get("residual_game_ms", 0))
