class_name PerfGovernor
extends RefCounted
## Doc 11 §2.13's runtime adaptive governor, and doc 13 §2.8's thermal half.
##
## WHAT IT IS. A model, not a Node: it is fed a frame time every frame and a
## thermal status whenever the platform pushes one, and it answers with a set of
## KNOB VALUES the shell applies. It owns no rendering, no timers and no engine
## singletons, so it is testable headlessly at 1 000 frames a second — which is
## the only way the 5 s / 30 s holds below ever get tested at all.
##
##     governor.configure(render_cfg, "balanced")
##     governor.submit_frame(frame_ms)            # every frame
##     if governor.update(delta):                 # every frame; true = knobs moved
##         apply(governor.knobs())
##     governor.set_thermal_status(status)        # from AndroidNative's signal
##
## THE RULE (doc 11 §2.13, values in `data/render.json.governor`). A rolling
## `window_frames` p95, evaluated every `eval_interval_s`. Step DOWN one rung
## when `p95 > budget × step_down_ratio` has held for `step_down_hold_s`; step UP
## one rung when `p95 < budget × step_up_ratio` has held for `step_up_hold_s`.
## The asymmetry is the whole design: dropping quality is a 5-second reflex,
## restoring it is a 30-second decision, so a single stutter never costs the
## player their picture and a genuinely idle city gets it back.
##
## THE LADDER is data (`governor.knobs`), applied in order and undone LIFO:
##   1. `render_scale`   −0.05, floor 0.60
##   2. `particle_ratio` ×0.60, floor 0.30
##   3. `far_cull_m`     −128 m, floor 600 m
##   4. `street_lights`  −4, floor 4
##   5. `preset_drop`    one preset down, and **latched** for the session
## Rung 5 latches because a preset change rebuilds materials and re-uploads
## buckets; a governor that could oscillate across it would spend more time
## rebuilding than rendering.
##
## WHAT IT MAY NEVER TOUCH (`governor.protected`): `emissive_*`, `blackout.*`
## and `glow_enabled`. The blackout and the relight are the game's signature
## moment (§1 job 1) and are not allowed to degrade — a phone that cannot afford
## them gets fewer streetlights, a shorter draw distance and a smaller
## framebuffer, in that order, and still gets the city going dark properly.
## `assert_protected_knobs()` is the test that keeps that promise honest.
##
## THERMAL (doc 13 §2.8). `PowerManager` statuses 0 NONE … 6 SHUTDOWN, pushed
## through `AndroidNative.thermal_status_changed`. At/above
## `thermal_block_up_status` the governor stops stepping up; at/above
## `thermal_step_down_status` it steps down immediately, bypassing the 5 s hold,
## because thermal headroom does not come back on its own; at/above
## `thermal_force_preset_status` it latches the preset to the cheapest one.
## Cooling is hysteretic: a lower status only takes effect after
## `thermal_recover_s` at that status, so a device sitting on a boundary does
## not oscillate.
##
## **Deliberate divergence from doc 13 §2.8, flagged.** That table also says
## thermal SEVERE turns glow off and shadows off. Glow is on doc 11 §2.13's
## protected list, and doc 11 owns rendering, so this governor does NOT touch
## it — it drops the preset instead, which is what actually recovers the
## milliseconds. See the branch report's open questions.

## `PowerManager.THERMAL_STATUS_*`, mirrored from `game/android_native.gd` so
## this file needs no Android import to be testable.
const THERMAL_UNKNOWN := -1
const THERMAL_NONE := 0
const THERMAL_LIGHT := 1
const THERMAL_MODERATE := 2
const THERMAL_SEVERE := 3
const THERMAL_CRITICAL := 4

const DIR_DOWN := -1
const DIR_UP := 1

## Fallbacks, used only when `data/render.json` is missing a row. They are the
## doc's published values, not invented ones.
const DEF_WINDOW_FRAMES := 120
const DEF_EVAL_INTERVAL_S := 1.0
const DEF_STEP_DOWN_RATIO := 1.25
const DEF_STEP_DOWN_HOLD_S := 5.0
const DEF_STEP_UP_RATIO := 0.80
const DEF_STEP_UP_HOLD_S := 30.0
const DEF_PERF_LOG_INTERVAL_S := 2.0
const DEF_THERMAL_RECOVER_S := 30.0

const PRESET_ORDER := ["performance", "balanced", "high"]

## The player's "Auto quality" switch (`data/ui.json.settings.auto_quality`).
## Off means the knobs freeze exactly where they are — not that they reset,
## which would be a visible quality *jump* at the moment the player asked for
## manual control.
var enabled := true

var cfg: Dictionary = {}
var preset := "balanced"
## Frame-time budget in milliseconds — `1000 / target_fps` of the ACTIVE preset,
## so a Performance device is judged against 33.3 ms and not against 16.7.
var budget_ms := 16.667

var window_frames := DEF_WINDOW_FRAMES
var eval_interval_s := DEF_EVAL_INTERVAL_S
var step_down_ratio := DEF_STEP_DOWN_RATIO
var step_down_hold_s := DEF_STEP_DOWN_HOLD_S
var step_up_ratio := DEF_STEP_UP_RATIO
var step_up_hold_s := DEF_STEP_UP_HOLD_S
var perf_log_interval_s := DEF_PERF_LOG_INTERVAL_S
var thermal_recover_s := DEF_THERMAL_RECOVER_S
var thermal_block_up_status := THERMAL_MODERATE
var thermal_step_down_status := THERMAL_SEVERE
var thermal_force_preset_status := THERMAL_CRITICAL

## The ladder, straight from `data/render.json.governor.knobs`.
var ladder: Array = []
## Names this governor is forbidden to write, from `governor.protected`.
var protected: Array = []

var _base: Dictionary = {}      # knob id -> the preset's value (the ceiling)
var _value: Dictionary = {}     # knob id -> the value in force now
var _applied: Array[int] = []   # rung indices, in the order they were applied
var _preset_latched := false

var _frames := PackedFloat32Array()
var _frame_head := 0
var _frame_count := 0
var _p95 := 0.0

var _since_eval := 0.0
var _over_budget_s := 0.0
var _under_budget_s := 0.0
var _since_log := 0.0

var _thermal := THERMAL_UNKNOWN
var _thermal_pending := THERMAL_UNKNOWN
var _thermal_pending_s := 0.0
var _thermal_forced := false

var _events: Array = []


func _init(render_cfg: Dictionary = {}, preset_name: String = "balanced") -> void:
	if not render_cfg.is_empty():
		configure(render_cfg, preset_name)


static func load_config(path: String = "res://data/render.json") -> Dictionary:
	return RenderStateModel.load_config(path)


func configure(render_cfg: Dictionary, preset_name: String = "balanced") -> void:
	cfg = render_cfg
	var g: Dictionary = cfg.get("governor", {})
	window_frames = maxi(2, int(g.get("window_frames", DEF_WINDOW_FRAMES)))
	eval_interval_s = float(g.get("eval_interval_s", DEF_EVAL_INTERVAL_S))
	step_down_ratio = float(g.get("step_down_ratio", DEF_STEP_DOWN_RATIO))
	step_down_hold_s = float(g.get("step_down_hold_s", DEF_STEP_DOWN_HOLD_S))
	step_up_ratio = float(g.get("step_up_ratio", DEF_STEP_UP_RATIO))
	step_up_hold_s = float(g.get("step_up_hold_s", DEF_STEP_UP_HOLD_S))
	perf_log_interval_s = float(g.get("perf_log_interval_s", DEF_PERF_LOG_INTERVAL_S))
	thermal_recover_s = float(g.get("thermal_recover_s", DEF_THERMAL_RECOVER_S))
	thermal_block_up_status = int(g.get("thermal_block_up_status", THERMAL_MODERATE))
	thermal_step_down_status = int(g.get("thermal_step_down_status", THERMAL_SEVERE))
	thermal_force_preset_status = int(g.get("thermal_force_preset_status", THERMAL_CRITICAL))
	ladder = g.get("knobs", [])
	protected = g.get("protected", [])
	_frames.resize(window_frames)
	reset(preset_name)


## Adopt a preset and put every knob back at its ceiling. Called at boot and
## whenever the PLAYER picks a preset — their choice outranks the ladder, and a
## governor that kept its old rungs would silently undo the setting they just
## changed. A latched preset drop is cleared here too, for the same reason.
func reset(preset_name: String) -> void:
	preset = preset_name
	_preset_latched = false
	_applied.clear()
	_base.clear()
	_value.clear()
	var row := preset_row(preset_name)
	budget_ms = 1000.0 / maxf(1.0, float(row.get("target_fps", 60)))
	for rung in ladder:
		var id := String((rung as Dictionary).get("id", ""))
		if id == "" or id == "preset_drop":
			continue
		var base := _preset_value(row, id)
		_base[id] = base
		_value[id] = base
	_frame_head = 0
	_frame_count = 0
	_p95 = 0.0
	_over_budget_s = 0.0
	_under_budget_s = 0.0
	_since_eval = 0.0


func preset_row(preset_name: String) -> Dictionary:
	return (cfg.get("presets", {}) as Dictionary).get(preset_name, {})


## The knob's ceiling for a preset. `particle_ratio` is the one knob the preset
## table does not carry: it is a MULTIPLIER on whatever `amount` the weather
## profile asked for, so its ceiling is 1.0 by definition.
func _preset_value(row: Dictionary, id: String) -> float:
	if id == "particle_ratio":
		return 1.0
	return float(row.get(id, 1.0))


# ---------------------------------------------------------------- the window

## One rendered frame, in milliseconds. Cheap by construction: a ring write and
## a counter, no sort — the sort happens once per `eval_interval_s`.
func submit_frame(frame_ms: float) -> void:
	_frames[_frame_head] = maxf(0.0, frame_ms)
	_frame_head = (_frame_head + 1) % window_frames
	_frame_count = mini(_frame_count + 1, window_frames)


func p95_ms() -> float:
	return _p95


func sample_count() -> int:
	return _frame_count


func _recompute_p95() -> void:
	if _frame_count <= 0:
		_p95 = 0.0
		return
	var sorted := PackedFloat32Array()
	sorted.resize(_frame_count)
	for i in _frame_count:
		sorted[i] = _frames[i]
	sorted.sort()
	# p95 by nearest-rank on the samples we actually have, so a half-full window
	# still answers — the governor must be able to react in its first second.
	var rank := int(ceil(0.95 * float(_frame_count))) - 1
	_p95 = float(sorted[clampi(rank, 0, _frame_count - 1)])


# ------------------------------------------------------------------- thermal

## `PowerManager.THERMAL_STATUS_*` from `AndroidNative.thermal_status_changed`.
## Rising status applies at once (the device is already hot); falling status
## waits out `thermal_recover_s` (doc 13 §2.8's hysteresis).
func set_thermal_status(status: int) -> void:
	if status == _thermal:
		_thermal_pending = THERMAL_UNKNOWN
		_thermal_pending_s = 0.0
		return
	if status > _thermal or _thermal == THERMAL_UNKNOWN:
		_thermal = status
		_thermal_pending = THERMAL_UNKNOWN
		_thermal_pending_s = 0.0
		_emit("render_thermal_changed", {"status": status, "direction": "up"})
		return
	_thermal_pending = status
	_thermal_pending_s = 0.0


func thermal_status() -> int:
	return _thermal


# -------------------------------------------------------------------- memory

## The knob doc 11's memory-warning response names by name: *"drop `far_cull_m`
## one governor step"*. Kept beside the ladder rather than inside the response so
## a re-ordered ladder cannot silently point the response at a different knob.
const MEMORY_KNOB := "far_cull_m"
const MEMORY_REASON := "memory_warning"


## `NOTIFICATION_OS_MEMORY_WARNING`, answered (PA-20).
##
## At the Wave-17 fork `AndroidLifecycle.memory_warning` was **emitted into a
## void**: `grep -rn "memory_warning" --include=*.gd .` found the declaration,
## the emit, and one test asserting it does NOT save — no listener anywhere. Docs
## 11 and 13 both specify a response (tear chunks below MEDIUM, clear the LOD0
## mesh cache, drop `far_cull_m` one governor step — *"~40 % of VRAM in one
## frame"*), and on a Fold running a large city beside other apps the cost of not
## having one is a silent task kill.
##
## **Not `_step_down`.** The ladder's next rung is `render_scale`, which is a
## FRAME-TIME lever and costs nothing in memory; the ladder is ordered by what is
## cheapest to lose per millisecond, not per megabyte. Android is telling us
## about bytes, so the response takes the one rung that returns them and takes it
## out of ladder order. It still enters `_applied`, so `_step_up` unwinds it LIFO
## like any other rung once the frame budget says there is room.
##
## Returns `true` when a rung was actually taken — `false` at the floor, which is
## the honest answer and lets the shell log "already at the floor" rather than
## claiming a step it did not make. The cache shed the shell performs alongside
## this is `CityView.shed_caches()`; it is not called from here, because a
## governor that reached into the scene tree would stop being testable headless.
func on_memory_warning() -> bool:
	for i in ladder.size():
		var rung: Dictionary = ladder[i]
		if String(rung.get("id", "")) != MEMORY_KNOB:
			continue
		if not _has_room_down(rung, MEMORY_KNOB):
			return false
		return _apply_rung(i, MEMORY_REASON)
	return false


## Doc 13 §2.8's frame cap, for the shell to write into `Engine.max_fps`. The
## governor computes it because it is the one object that knows both the active
## preset and the thermal status; it never writes it itself (constitution §3 —
## no engine singletons in a model).
func target_fps() -> int:
	var base := int(preset_row(preset).get("target_fps", 60))
	if _thermal >= THERMAL_SEVERE:
		return 30
	if _thermal == THERMAL_MODERATE:
		return mini(base, 45)
	return base


# --------------------------------------------------------------------- knobs

## Everything the shell has to apply, including the preset name so a latched
## drop is visible to the caller in the same dictionary as the rest.
func knobs() -> Dictionary:
	var out := _value.duplicate()
	out["preset"] = preset
	return out


func knob(id: String) -> float:
	return float(_value.get(id, _base.get(id, 1.0)))


func rungs_applied() -> int:
	return _applied.size()


func preset_latched() -> bool:
	return _preset_latched


func at_floor() -> bool:
	return _next_down_rung() < 0


func drain_events() -> Array:
	var out := _events
	_events = []
	return out


func _emit(event_type: String, payload: Dictionary) -> void:
	var event := payload.duplicate()
	event["type"] = StringName(event_type)
	_events.append(event)


# -------------------------------------------------------------------- update

## Call once per rendered frame with the real delta. Returns true when a knob
## moved, which is the shell's cue to re-apply `knobs()`.
func update(delta: float) -> bool:
	_since_log += delta
	if _thermal_pending != THERMAL_UNKNOWN:
		_thermal_pending_s += delta
		if _thermal_pending_s >= thermal_recover_s:
			_thermal = _thermal_pending
			_thermal_pending = THERMAL_UNKNOWN
			_thermal_pending_s = 0.0
			_emit("render_thermal_changed", {"status": _thermal, "direction": "down"})
	if not enabled:
		return false

	var moved := false
	# Thermal CRITICAL is not a hint. It skips the ladder entirely and latches
	# the cheapest preset, because at that status the platform is about to start
	# taking the clocks away whatever we do.
	if _thermal >= thermal_force_preset_status and not _thermal_forced:
		_thermal_forced = true
		if _drop_preset("thermal"):
			moved = true

	_since_eval += delta
	if _since_eval < eval_interval_s:
		return moved
	_since_eval = 0.0
	_recompute_p95()
	if _frame_count < 2:
		return moved

	var over := _p95 > budget_ms * step_down_ratio
	var under := _p95 < budget_ms * step_up_ratio
	# Thermal SEVERE forces a step down on the next evaluation even when the
	# frame time looks fine — it looks fine precisely because the governor has
	# not yet paid for the heat.
	var thermal_forces_down := _thermal >= thermal_step_down_status
	if over or thermal_forces_down:
		_under_budget_s = 0.0
		_over_budget_s += eval_interval_s
		if thermal_forces_down or _over_budget_s >= step_down_hold_s:
			_over_budget_s = 0.0
			if _step_down("thermal" if thermal_forces_down and not over else "frame_time"):
				moved = true
	elif under:
		_over_budget_s = 0.0
		_under_budget_s += eval_interval_s
		# Above `thermal_block_up_status` the device is warm: hold what we have.
		if _thermal >= thermal_block_up_status:
			_under_budget_s = 0.0
		elif _under_budget_s >= step_up_hold_s:
			_under_budget_s = 0.0
			if _step_up():
				moved = true
	else:
		_over_budget_s = 0.0
		_under_budget_s = 0.0
	return moved


func should_log(consume: bool = true) -> bool:
	if _since_log < perf_log_interval_s:
		return false
	if consume:
		_since_log = 0.0
	return true


# ------------------------------------------------------------------- stepping

## The first rung that still has room. `preset_drop` is last and is only offered
## once every other rung is on its floor.
func _next_down_rung() -> int:
	for i in ladder.size():
		var rung: Dictionary = ladder[i]
		var id := String(rung.get("id", ""))
		if id == "preset_drop":
			if not _preset_latched and _preset_below(preset) != "":
				return i
			continue
		if _has_room_down(rung, id):
			return i
	return -1


func _has_room_down(rung: Dictionary, id: String) -> bool:
	if not _value.has(id):
		return false
	var floor_value := float(rung.get("floor", 0.0))
	return float(_value[id]) > floor_value + 1e-6


func _step_down(reason: String) -> bool:
	var index := _next_down_rung()
	if index < 0:
		return false
	return _apply_rung(index, reason)


## Take ONE named rung. Split out of `_step_down` so the memory-warning response
## can take the rung doc 11 names (`far_cull_m`) rather than the rung the ladder
## happens to offer next (PA-20); `_step_down` still chooses by ladder order and
## nothing about the arithmetic, the floor, the guard or the emitted event
## changed when it moved down here.
func _apply_rung(index: int, reason: String) -> bool:
	var rung: Dictionary = ladder[index]
	var id := String(rung.get("id", ""))
	if id == "preset_drop":
		return _drop_preset(reason)
	_guard_protected(id)
	var floor_value := float(rung.get("floor", 0.0))
	var was := float(_value[id])
	var now := was
	if rung.has("mult"):
		now = was * float(rung["mult"])
	else:
		now = was + float(rung.get("delta", 0.0))
	now = maxf(now, floor_value)
	_value[id] = now
	_applied.append(index)
	_emit("render_governor_stepped", {"knob": id, "direction": DIR_DOWN,
			"from": was, "to": now, "reason": reason, "rungs": _applied.size()})
	return true


## Undo exactly the last step, LIFO. Not "raise the highest knob": the ladder is
## an order, and unwinding it out of order would restore an expensive knob while
## a cheap one stayed clamped.
func _step_up() -> bool:
	if _applied.is_empty():
		return false
	var index: int = _applied[_applied.size() - 1]
	var rung: Dictionary = ladder[index]
	var id := String(rung.get("id", ""))
	if id == "preset_drop":
		return false  # latched for the session (§2.13: never oscillate presets)
	_guard_protected(id)
	var was := float(_value[id])
	var ceiling := float(_base.get(id, was))
	var now := was
	if rung.has("mult"):
		var mult := float(rung["mult"])
		now = was / mult if mult > 0.0 else ceiling
	else:
		now = was - float(rung.get("delta", 0.0))
	now = minf(now, ceiling)
	_value[id] = now
	_applied.remove_at(_applied.size() - 1)
	_emit("render_governor_stepped", {"knob": id, "direction": DIR_UP,
			"from": was, "to": now, "reason": "frame_time", "rungs": _applied.size()})
	return true


func _drop_preset(reason: String) -> bool:
	var below := _preset_below(preset)
	if below == "" or _preset_latched:
		return false
	var was := preset
	# The drop keeps the rungs already spent: the new preset is cheaper on every
	# axis, so re-basing to its ceilings would RAISE quality mid-emergency.
	var carried := _value.duplicate()
	var carried_rungs := _applied.duplicate()
	reset(below)
	for id in carried:
		if _value.has(id):
			_value[id] = minf(float(carried[id]), float(_base[id]))
	_applied = carried_rungs
	_preset_latched = true
	_emit("render_preset_changed", {"preset": below, "from": was, "reason": reason})
	_emit("render_governor_stepped", {"knob": "preset_drop", "direction": DIR_DOWN,
			"from": was, "to": below, "reason": reason, "rungs": _applied.size()})
	return true


static func _preset_below(preset_name: String) -> String:
	var index := PRESET_ORDER.find(preset_name)
	if index <= 0:
		return ""
	return String(PRESET_ORDER[index - 1])


## The §2.13 promise, enforced at the point of writing rather than in a comment:
## a `data/render.json` edit that put `glow_enabled` on the ladder would trip
## this the first time the governor tried to step it.
func _guard_protected(id: String) -> void:
	for name: Variant in protected:
		if id.begins_with(String(name)):
			push_error("PerfGovernor: knob '%s' is protected (§2.13) and must not be stepped"
					% id)
			return


## Test-facing form of the same rule: no rung may name a protected knob.
func assert_protected_knobs() -> PackedStringArray:
	var offenders := PackedStringArray()
	for rung in ladder:
		var id := String((rung as Dictionary).get("id", ""))
		for name: Variant in protected:
			if id.begins_with(String(name)):
				offenders.append(id)
	return offenders


# ------------------------------------------------------------------ PERF line

## Doc 11 §7.4's on-device log line, verbatim in shape so
## `tools/bench_device.sh` can `grep '^PERF'` and hand the result to a
## spreadsheet without a parser.
func perf_line(t_s: float, stats: Dictionary = {}) -> String:
	var fps := 1000.0 / maxf(0.001, _mean_ms())
	return ("PERF t=%.1f fps=%.1f p95=%.1f cpu=%.1f gpu_est=%.1f dc=%d prim=%d "
			+ "vram=%d static_mem=%d chunks=%d near=%d inst=%d lights=%d "
			+ "preset=%s knob=%d thermal=%d") % [
		t_s, fps, _p95,
		float(stats.get("cpu_ms", 0.0)), float(stats.get("gpu_ms", 0.0)),
		int(stats.get("draw_calls", 0)), int(stats.get("primitives", 0)),
		int(stats.get("vram_mb", 0)), int(stats.get("static_mem_mb", 0)),
		int(stats.get("chunks", 0)), int(stats.get("near_chunks", 0)),
		int(stats.get("instances", 0)), int(stats.get("lights", 0)),
		preset, _applied.size(), _thermal,
	]


func _mean_ms() -> float:
	if _frame_count <= 0:
		return 0.0
	var total := 0.0
	for i in _frame_count:
		total += _frames[i]
	return total / float(_frame_count)
