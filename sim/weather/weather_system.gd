class_name WeatherSystem
extends RefCounted
## The ambient pressure dial (doc 07). One committed timeline, one global
## (state, intensity), one published multiplier interface.
##
## `get_effect()` is AUTHORITATIVE for all five weather multiplier families
## (report 98 C-57) and accepts doc 02's short aliases. 17 channels; the three
## fire channels are distinct questions and never substitute for one another
## (§2.2.1, RR-15).
##
## Weather is city-wide GLOBAL (C-59): every channel is position-independent.
## Only `in_storm_cell()` and the flood field vary spatially.
##
## Ownership boundaries this class respects, so nobody double-counts:
##   · it rolls NO line failures — doc 06's storm_damage generator is the only
##     line-failure generator in the game (C-53); this publishes `wind_kph`,
##     `in_storm_cell()` and the storm phase, and nothing else about wind;
##   · it resolves NO lightning damage — it emits `LightningStrike` and doc 04 /
##     02 / 06 / 05 resolve it against their own bands (C-54);
##   · it prices NO repair and writes NO stability scalar (C-16, C-56).

const PHASE_LEAD_IN := &"lead_in"
const PHASE_PEAK := &"peak"
const PHASE_TRAILING := &"trailing"

const TILE_METERS := 8.0  # constitution §6
const KPH_TO_MS := 1.0 / 3.6

## Renderer event throttle: `weather_changed` is re-emitted when a rendered
## channel actually moves, never on a fixed timer (doc 11 §5 consumes it).
const PRECIP01_EMIT_EPSILON := 0.01
const WIND_EMIT_EPSILON_KPH := 1.0

var tables: WeatherTables
var timeline: WeatherTimeline
var forecast: WeatherForecast
var cell: StormCell
var flood: FloodField

var city_center_tiles: Vector2 = Vector2.ZERO
var city_radius_tiles: float = 96.0

var now_gs: int = 0
var now_min: int = 0
var season_index: int = 0
var minute_of_day: int = 0

var _rng: RngStreams
var _modifiers: ModifierStack = null
var _events: Array = []
var _current_segment_id: int = -1
var _last_emitted_precip01: float = -1.0
var _last_emitted_wind: float = -1.0
var _last_mults: Dictionary = {}


func _init(p_tables: WeatherTables, p_rng: RngStreams) -> void:
	tables = p_tables
	_rng = p_rng
	timeline = WeatherTimeline.new(tables)
	forecast = WeatherForecast.new(tables, timeline)
	cell = StormCell.new()
	flood = FloodField.new(tables)


## Optional: weather multipliers land on doc 01's day-curve channels through
## the shared ModifierStack under source kind &"weather" (rank 0, so it always
## multiplies first and the product order is stable).
func attach_modifiers(stack: ModifierStack) -> void:
	_modifiers = stack


func set_city_bounds(center_tiles: Vector2, radius_tiles: float) -> void:
	city_center_tiles = center_tiles
	city_radius_tiles = maxf(1.0, radius_tiles)


func bootstrap(ctx: TimeContext, initial_state: String = "CLEAR") -> void:
	_sync_clock(ctx)
	timeline.bootstrap(now_min, season_index, _weather_rng(), initial_state)
	_enter_segment(timeline.segment_at(now_min), false)


# ---------------------------------------------------------------------- tick

## Utilities cadence (doc 01 EVERY_TICK = 15 game-seconds).
func tick(ctx: TimeContext) -> void:
	_advance(ctx, float(ctx.dt_game_seconds) / 60.0, true)


## Offline / catch-up: the SAME rules at 1-game-hour granularity
## (constitution §4 — never a parallel implementation). Renderer events are
## suppressed, per doc 01's coarse contract.
func advance_coarse(ctx: TimeContext) -> void:
	_advance(ctx, float(ctx.dt_game_seconds) / 60.0, false)


func _advance(ctx: TimeContext, dt_min: float, render_events: bool) -> void:
	_sync_clock(ctx)
	if timeline.segments.is_empty():
		timeline.bootstrap(now_min, season_index, _weather_rng())
	timeline.ensure_horizon(now_min, season_index, _weather_rng())
	timeline.prune(now_min)
	var segment := timeline.segment_at(now_min)
	if int(segment.get("id", -1)) != _current_segment_id:
		_enter_segment(segment, render_events)
	if cell.active:
		cell.advance(dt_min)
	# `segment` is already in hand; asking `get_precip_mm_h()` would re-scan the
	# timeline for the same row twice more (state, then intensity).
	flood.integrate(dt_min / 60.0, _effect_of(segment, "precip_mm_h"))
	for event in flood.drain_events():
		_events.append(event)
	_apply_modifiers()
	if render_events:
		_maybe_emit_weather_changed(false)


func _sync_clock(ctx: TimeContext) -> void:
	now_gs = ctx.tick_index * GameClock.GAME_SECONDS_PER_TICK
	now_min = now_gs / 60
	# The calendar is doc 01's (C-28): this system READS season_index and
	# season_progress and derives no calendar of its own.
	season_index = ctx.season_index
	minute_of_day = ctx.minute_of_day


func _enter_segment(segment: Dictionary, render_events: bool) -> void:
	if segment.is_empty():
		return
	var previous := _current_segment_id
	_current_segment_id = int(segment["id"])
	var state := String(segment["state"])
	if state == "THUNDERSTORM":
		if not cell.active:
			cell.spawn(city_center_tiles, city_radius_tiles, tables,
					hash([_current_segment_id, "storm_cell"]))
			_events.append({"type": &"storm_phase_changed", "phase": PHASE_LEAD_IN,
					"segment_id": _current_segment_id, "state": state,
					"cell": cell.serialize()})
	elif cell.active:
		cell.despawn()
		_events.append({"type": &"storm_phase_changed", "phase": &"ended",
				"segment_id": previous, "state": state})
	_last_mults.clear()  # force a modifier re-push on every state change
	if render_events:
		_maybe_emit_weather_changed(true)


# -------------------------------------------------------- published channels

func get_state() -> String:
	var segment := timeline.segment_at(now_min)
	return String(segment["state"]) if not segment.is_empty() else "CLEAR"


func get_intensity() -> float:
	var segment := timeline.segment_at(now_min)
	return float(segment["intensity"]) if not segment.is_empty() else 0.0


func state_at(gmin: int) -> Dictionary:
	return timeline.state_at(gmin)


## THE published multiplier interface (C-57). Accepts canonical names and doc
## 02's aliases. An unknown channel returns NAN and raises — it never returns a
## silent 1.0, because a silently-neutral weather multiplier is a bug that
## survives every test.
func get_effect(channel: String) -> float:
	return _effect_of(timeline.segment_at(now_min), channel)


## `get_effect` against a segment the caller already resolved. Same lookup, same
## error, same NAN — it just does not re-scan the timeline twice to rediscover
## the state and intensity the caller is holding.
func _effect_of(segment: Dictionary, channel: String) -> float:
	var canonical := WeatherTables.canonical_channel(channel)
	if canonical == "":
		push_error("WeatherSystem.get_effect: unknown channel '%s'" % channel)
		return NAN
	var state := String(segment["state"]) if not segment.is_empty() else "CLEAR"
	var intensity := float(segment["intensity"]) if not segment.is_empty() else 0.0
	return tables.effect(state, canonical, intensity)


func get_wind_kph() -> float:
	return get_effect("wind_kph")


func get_precip_mm_h() -> float:
	return get_effect("precip_mm_h")


## §2.2 / C-58 — the one channel that is CONTINUOUS across segment boundaries.
## Every other channel stays a step function, because sim math needs step
## semantics for coarse/fine parity; only the renderer needs the ramp.
func get_precip01() -> float:
	return _precip01_of(timeline.segment_at(now_min))


func _precip01_of(segment: Dictionary) -> float:
	var scale := maxf(0.001, tables.precip01_scale_mm_h)
	var here := clampf(_effect_of(segment, "precip_mm_h") / scale, 0.0, 1.0)
	if segment.is_empty():
		return here
	var crossfade_gs := tables.segment_crossfade_gs
	var remaining_gs := int(segment["end_min"]) * 60 - now_gs
	if remaining_gs > crossfade_gs or remaining_gs < 0:
		return here
	var next_segment := timeline.segment_after(now_min)
	if next_segment.is_empty():
		return here
	var there := clampf(tables.effect(String(next_segment["state"]), "precip_mm_h",
			float(next_segment["intensity"])) / scale, 0.0, 1.0)
	var u := float(crossfade_gs - remaining_gs) / float(crossfade_gs)
	return lerpf(here, there, u)


## §2.2: one source of truth for temperature — the transformer heat rate is
## DERIVED from it, never a second hand-authored table.
func get_ambient_temp_c() -> float:
	var base := tables.season_temp_base_c(season_index)
	var diurnal := tables.diurnal_amp_c * cos(TAU
			* float(minute_of_day - tables.diurnal_peak_min_of_day) / 1440.0)
	return base + diurnal + get_effect("temp_offset_c")


func get_transformer_heat_mult() -> float:
	var config := tables.transformer_heat
	var band: Array = config.get("clamp", [0.7, 2.4])
	var value := 1.0 + (get_ambient_temp_c() - float(config.get("ref_temp_c", 20.0))) \
			* float(config.get("per_degree", 0.04))
	return clampf(value, float(band[0]), float(band[1]))


## Doc 10 §2.11 consumes exactly this.
func wx_slowdown() -> float:
	return 1.0 - get_effect("road_speed_mult")


## The env dictionary doc 04's `PowerGrid.tick()` takes.
func env_for_grid() -> Dictionary:
	return {"t_ambient_c": get_ambient_temp_c(), "heat_wave": get_state() == "HEAT_WAVE"}


func is_heat_wave() -> bool:
	return get_state() == "HEAT_WAVE"


func is_thunderstorm() -> bool:
	return get_state() == "THUNDERSTORM"


# ------------------------------------------------------------------ spatial

func get_storm_cell() -> StormCell:
	return cell


func in_storm_cell(pos_tiles: Vector2) -> bool:
	return cell.contains(pos_tiles)


func flood_depth_mm(tx: int, tz: int) -> float:
	return flood.depth_at(tx, tz)


func flood_saturation(tx: int, tz: int) -> float:
	return flood.flood_saturation(tx, tz)


## Per-tile road speed: the global weather multiplier × the tile's flood band.
## Doc 07 §4 sketches `get_edge_speed_mult(edge_id)`; edges are doc 10's, so the
## seam is per-TILE here and doc 10 folds it over an edge's tiles — this system
## never needs to know the road graph.
func tile_speed_mult(tx: int, tz: int) -> float:
	return get_effect("road_speed_mult") * flood.road_speed_mult_at(tx, tz)


## Doc 10 convenience: the worst flood band along an edge's tile run, already
## multiplied by the global weather term.
func edge_speed_mult(tiles: Array) -> float:
	var worst := 1.0
	for tile in tiles:
		var tx: int
		var tz: int
		if tile is Vector2i:
			tx = tile.x
			tz = tile.y
		else:
			tx = int(tile[0])
			tz = int(tile[1])
		worst = minf(worst, flood.road_speed_mult_at(tx, tz))
	return get_effect("road_speed_mult") * worst


# ----------------------------------------------------------------- forecast

func get_forecast(horizon_min: int = -1) -> Array:
	return forecast.get_forecast(now_min, horizon_min)


# ---------------------------------------------------------------- injection

## Director hook (§2.7.1). Rewrites the committed future so the forecast can
## show the storm honestly the moment it is scheduled.
func inject_segment(state: String, start_min: int, duration_min: int, intensity: float,
		event_id: int) -> int:
	var id := timeline.inject_segment(state, start_min, duration_min, intensity, event_id)
	timeline.ensure_horizon(now_min, season_index, _weather_rng())
	return id


## §2.7.1's exact edit: truncate to T−30, THUNDERSTORM [T−30, T+dur), then
## HEAVY_RAIN 45, RAIN 90, then the chain resumes.
func inject_storm(t0_min: int, duration_min: int, intensity: float, event_id: int,
		lead_in_min: int = 30, tail_heavy_min: int = 45, tail_rain_min: int = 90) -> int:
	var id := timeline.inject_segment("THUNDERSTORM", t0_min - lead_in_min,
			duration_min + lead_in_min, intensity, event_id)
	timeline.append_segment("HEAVY_RAIN", tail_heavy_min, maxf(0.0, intensity - 0.35), event_id)
	timeline.append_segment("RAIN", tail_rain_min, maxf(0.0, intensity - 0.50), event_id)
	timeline.ensure_horizon(now_min, season_index, _weather_rng())
	return id


# ------------------------------------------------------------------- events

func drain_events() -> Array:
	var out := _events
	_events = []
	return out


func emit_event(event_type: StringName, payload: Dictionary) -> void:
	var event := payload.duplicate()
	event["type"] = event_type
	_events.append(event)


## Doc 11 §5's renderer contract. NOTE: doc 11 names the weather enum field
## `type`, but `type` is this codebase's event-name key on the bus, so the enum
## ships as `weather_state` (and `weather_type`, unchanged in value) — the only
## rename in the payload.
func _maybe_emit_weather_changed(force: bool) -> void:
	# One timeline resolve for both gate values — this runs every tick and the
	# gate almost always closes, so the scans it used to do were pure overhead.
	var segment := timeline.segment_at(now_min)
	var precip01 := _precip01_of(segment)
	var wind := _effect_of(segment, "wind_kph")
	if not force \
			and absf(precip01 - _last_emitted_precip01) < PRECIP01_EMIT_EPSILON \
			and absf(wind - _last_emitted_wind) < WIND_EMIT_EPSILON_KPH:
		return
	_last_emitted_precip01 = precip01
	_last_emitted_wind = wind
	var heading := wind_heading_deg()
	var speed_ms := wind * KPH_TO_MS
	_events.append({
		"type": &"weather_changed",
		"weather_state": get_state(),
		"weather_type": get_state(),
		"intensity": get_intensity(),
		"precip01": precip01,
		"wind": Vector2(cos(deg_to_rad(heading)), sin(deg_to_rad(heading))) * speed_ms,
		"wind_kph": wind,
		"fog": 0.0,  # FOG is a deferred state (§6); the channel ships at 0.
		"temp_c": get_ambient_temp_c(),
		"segment_id": _current_segment_id,
	})


## Wind direction is DERIVED, never persisted: the storm cell's heading while a
## cell is live, otherwise a stable hash of the segment id. Deriving it keeps
## the save section exactly the seven fields doc 07 §3.2 lists.
func wind_heading_deg() -> float:
	if cell.active:
		return cell.heading_deg
	return float(absi(hash(_current_segment_id)) % 3600) / 10.0


# --------------------------------------------------------------- modifiers

## Weather lands on doc 01's day-curve channels — the ONLY place this system
## writes into another system's numbers. Pushed only when a value actually
## changes, so the scheduler's per-hour channel cache is not invalidated every
## tick (ModifierStack.revision is the cache key).
## The pushed multipliers are a pure function of the CURRENT SEGMENT's (state,
## intensity), and both are constant for that segment's whole life — so once a
## segment's mults have been settled, every later tick inside it recomputed the
## identical dictionary only to throw it away at `_mults_equal`. The id of the
## segment those mults were settled for is remembered instead. Transient and
## derived: `_enter_segment` and `deserialize` both clear `_last_mults`, which
## re-opens the gate, so a loaded game re-settles on its first tick exactly as
## it did before.
var _mults_settled_segment_id: int = -1


func _apply_modifiers() -> void:
	if _modifiers == null:
		return
	if _mults_settled_segment_id == _current_segment_id and not _last_mults.is_empty():
		return
	var mults := modifier_mults()
	_mults_settled_segment_id = _current_segment_id
	if _mults_equal(mults, _last_mults):
		return
	_last_mults = mults.duplicate()
	_modifiers.push_source(&"weather", "weather", mults)


func modifier_mults() -> Dictionary:
	var segment := timeline.segment_at(now_min)
	var out := {}
	for channel in WeatherTables.CHANNELS:
		if not tables.modifier_channels.has(channel):
			continue
		var value := _effect_of(segment, channel)
		for target in tables.modifier_channels[channel]:
			out[String(target)] = float(out.get(String(target), 1.0)) * value
	return out


static func _mults_equal(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for key in a:
		if not b.has(key) or absf(float(a[key]) - float(b[key])) > 1e-9:
			return false
	return true


func _weather_rng() -> RandomNumberGenerator:
	return _rng.stream("weather")


# --------------------------------------------------------- debug commands

## `debug_force_weather(state, intensity, duration)` (§4). Rewrites the
## committed future exactly the way the Director does, so debug weather is
## indistinguishable from real weather to every consumer.
func debug_force_weather(state: String, intensity: float, duration_min: int) -> int:
	if not tables.has_state(state):
		push_error("debug_force_weather: unknown state " + state)
		return -1
	var id := timeline.inject_segment(state, now_min, duration_min, intensity, -1,
			WeatherTimeline.SOURCE_CHAIN)
	timeline.ensure_horizon(now_min, season_index, _weather_rng())
	_current_segment_id = -1  # force a segment-entry pass on the next tick
	return id


# ------------------------------------------------------------- persistence

## The `weather` save section (doc 07 §3.2). RNG is NOT duplicated here: the
## named streams persist once, in the shared `rng_streams` block
## (constitution §5 / §9) — a second copy could only ever disagree.
func serialize() -> Dictionary:
	return {
		"section_version": 1,
		"now_gs": now_gs,
		"current_segment_id": _current_segment_id,
		"timeline": timeline.serialize(),
		"storm_cell": cell.serialize(),
		"flood": flood.serialize(),
		"city_center_tiles": [city_center_tiles.x, city_center_tiles.y],
		"city_radius_tiles": city_radius_tiles,
	}


func deserialize(data: Dictionary) -> void:
	now_gs = int(data.get("now_gs", 0))
	now_min = now_gs / 60
	_current_segment_id = int(data.get("current_segment_id", -1))
	timeline.deserialize(data.get("timeline", {}))
	cell.deserialize(data.get("storm_cell", {}))
	flood.deserialize(data.get("flood", {}))
	var center: Array = data.get("city_center_tiles", [0, 0])
	city_center_tiles = Vector2(float(center[0]), float(center[1]))
	city_radius_tiles = float(data.get("city_radius_tiles", 96.0))
	_last_mults.clear()
	_last_emitted_precip01 = -1.0
	_last_emitted_wind = -1.0
	# The boot that preceded this load pushed ITS OWN rolled segment's channel
	# mults into the ModifierStack; the restored timeline may sit in another
	# segment. Re-apply now — push_source is a keyed SET — so the first tick
	# after load samples exactly the channels the saving instance sampled.
	_apply_modifiers()
