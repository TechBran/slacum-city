class_name TimeContext
extends RefCounted
## Frozen per-step time view (doc 01 §4). Built once at P00; read-only downstream.
## No sim system ever asks "what time is it?" — it reads this.

enum Mode { FINE, COARSE }

var tick_index: int = 0
var game_seconds: int = 0
var dt_game_seconds: int = 15
var mode: int = Mode.FINE
var is_catchup: bool = false
var catchup_index: int = 0
var catchup_total: int = 0
var minute_of_day: int = 0
var hour_of_day: int = 0
var hour_midpoint: float = 0.0  # the curve sample position used this step
var day_index: int = 0
var day_of_week: int = 0
var day_type: int = 0
var day_phase: StringName = &"NIGHT"
var season_index: int = 0
var season_progress: float = 0.0
var channels: Dictionary = {}  # channel name -> resolved float (step-midpoint sample)
## Channel values sampled at the HOUR midpoint (h + 0.5) regardless of mode.
## Work units use these so fine and coarse accumulation are exactly equal
## (per-tick samples on sloped curve segments would half-round differently).
var channels_hour: Dictionary = {}
var speed: int = 1  # renderer interpolation ONLY — never read in sim math (T-06)
var slice_index: int = 0
var slice_count: int = 1
