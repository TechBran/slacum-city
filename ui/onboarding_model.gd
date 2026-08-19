class_name OnboardingModel
extends RefCounted
## S12's step machine (doc 12 §2.17), pure and Node-free: the scripted first
## fifteen minutes as a table in `data/ui.json.onboarding` plus the observations
## that walk it. `ui/onboarding_flow.gd` renders what `current()` returns and
## decides nothing; `ui/coach_mark.gd` draws it.
##
## **One seam, one direction.** The machine never reads the sim, never holds a
## Node and never blocks anything: it takes `feed(observation)` — a Dictionary of
## plain data the shell already has — and hands back a queue of *requests*
## (`take_actions()`) that the shell may honour. A step therefore cannot advance
## on anything the player did not actually do, and a tutorial that fails to
## advance can never stall the simulation.
##
## Observations (`kind` → the rest of the keys):
##
##     tick        {dt: float}                      real seconds, for the hint timers
##     ack         {}                               the card's GOT IT
##     camera      {focus: Vector3, zoom_t: float}  CameraState, sampled per frame
##     ui_opened   {path: String}                   "build_sheet", "incident_drawer", …
##     command     {command: String, ok: bool, archetype: String, tile: Vector2i}
##     verdict     {code: String, tile: Vector2i}   the placement preflight said no
##     sim_event   {event: String, payload: Dictionary}  one SimEventBus event, verbatim
##
## Advance conditions are the same vocabulary, authored per step in the table:
## `ack`, `camera`, `ui_opened`, `command`, `verdict`, `sim_event`, `any_of`.
## A `match` block narrows a command or an event — `archetype`, `region` (a tag
## the shell resolved to a tile through `set_regions()`), `type` — so the doc's
## hard-gate rule holds: a `place_building` for the wrong type, or on a tile
## outside the marked lot, does **not** complete the step.
##
## Actions the machine may request (`take_actions()`), all optional to honour:
##
##     focus_camera {tag}          · open_build_sheet {}
##     open_build_category {category} · open_incident_drawer {}
##     trigger_tutorial_incident {} · suppress_director {seconds}
##     release_director {seconds}
##
## Persistence is doc 12 §3.2's `ui.onboarding` block, keys verbatim:
## `{active, current_step, skipped, completed, director_suppress_until_min}`.
## Restoring mid-flow resumes at the stored step with its timers reset; a
## finished tutorial restores as finished and `start()` refuses to run it again
## unless `reset()` cleared it first (Settings ▸ Replay tutorial).

# --- Step shape --------------------------------------------------------------
const KIND_CARD := &"card"
const KIND_COACH := &"coach"
const GATE_SOFT := &"soft"
const GATE_HARD := &"hard"

# --- Observation / advance kinds --------------------------------------------
const OBS_TICK := "tick"
const OBS_ACK := "ack"
const OBS_CAMERA := "camera"
const OBS_UI_OPENED := "ui_opened"
const OBS_COMMAND := "command"
const OBS_VERDICT := "verdict"
const OBS_SIM_EVENT := "sim_event"
const ADVANCE_ANY_OF := "any_of"

# --- Actions -----------------------------------------------------------------
const ACTION_FOCUS_CAMERA := &"focus_camera"
const ACTION_OPEN_BUILD_SHEET := &"open_build_sheet"
const ACTION_OPEN_BUILD_CATEGORY := &"open_build_category"
const ACTION_OPEN_INCIDENT_DRAWER := &"open_incident_drawer"
const ACTION_TRIGGER_INCIDENT := &"trigger_tutorial_incident"
const ACTION_SUPPRESS_DIRECTOR := &"suppress_director"
const ACTION_RELEASE_DIRECTOR := &"release_director"

## Fallbacks only — every one of these is authored in `data/ui.json.onboarding`
## and a malformed file degrades to these rather than crashing (constitution §3).
const DEFAULT_HINT_AFTER_S := 25.0
const DEFAULT_AUTOHELP_AFTER_S := 60.0
const DEFAULT_REGION_RADIUS := 1
const DEFAULT_CAMERA_PAN_M := 48.0
const DEFAULT_CAMERA_ZOOM_T := 0.05
const DEFAULT_SUPPRESS_AFTER_S := 300.0

var config: UIConfig

var active := false
var skipped := false
var finished := false
var current_index := -1

var _block: Dictionary = {}
var _steps: Array = []
var _completed: Array[String] = []
var _regions: Dictionary = {}        # tag -> Vector2i tile (world tiles)
var _actions: Array[Dictionary] = []

var _elapsed_s := 0.0                ## real seconds inside the current step
var _enter_fired := false            ## the step's `on_enter` action already queued
var _cam_base_focus := Vector3.ZERO
var _cam_base_zoom := 0.0
var _cam_based := false


func _init(cfg: UIConfig = null) -> void:
	config = cfg
	if cfg == null:
		return
	_block = cfg.section("onboarding")
	var raw: Variant = _block.get("steps", [])
	_steps = raw if raw is Array else []


static func load_from_files() -> OnboardingModel:
	return OnboardingModel.new(UIConfig.load_from_files())


# ---------------------------------------------------------------------------
# Table
# ---------------------------------------------------------------------------

func step_count() -> int:
	return _steps.size()


func step_ids() -> Array[String]:
	var out: Array[String] = []
	for raw: Variant in _steps:
		if raw is Dictionary:
			out.append(str((raw as Dictionary).get("id", "")))
	return out


func step_at(index: int) -> Dictionary:
	if index < 0 or index >= _steps.size():
		return {}
	var raw: Variant = _steps[index]
	return raw if raw is Dictionary else {}


func index_of(step_id: String) -> int:
	for i in _steps.size():
		if str(step_at(i).get("id", "")) == step_id:
			return i
	return -1


func completed_ids() -> Array[String]:
	return _completed.duplicate()


## Where the world targets are. `Callable`-free on purpose: the shell resolves
## `tutorial_lot_a` through `StarterCityLoader.resolve_tag()` once and hands the
## tiles over, so this class never learns what a starter city is.
func set_regions(regions: Dictionary) -> void:
	_regions.clear()
	for key: Variant in regions:
		var value: Variant = regions[key]
		if value is Vector2i:
			_regions[str(key)] = value
		elif value is Vector2:
			_regions[str(key)] = Vector2i(value)
		elif value is Array and (value as Array).size() >= 2:
			_regions[str(key)] = Vector2i(int((value as Array)[0]), int((value as Array)[1]))


func region_tile(tag: String) -> Variant:
	return _regions.get(tag, null)


func number(key: String, fallback: float) -> float:
	return UIConfig.get_num(_block, key, fallback)


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

## Starts (or resumes) the flow. Refuses a tutorial that is already finished —
## §2.17's "never shows again once done" — unless `reset()` cleared it first.
func start() -> bool:
	if _steps.is_empty() or finished:
		return false
	if active:
		return true
	active = true
	skipped = false
	if current_index < 0 or current_index >= _steps.size():
		current_index = _first_unfinished()
	_enter_step(current_index)
	_queue(ACTION_SUPPRESS_DIRECTOR,
			{"seconds": number("director_suppress_after_s", DEFAULT_SUPPRESS_AFTER_S)})
	return true


func _first_unfinished() -> int:
	for i in _steps.size():
		if not _completed.has(str(step_at(i).get("id", ""))):
			return i
	return _steps.size() - 1


func is_active() -> bool:
	return active and not finished


func is_finished() -> bool:
	return finished


## §2.17: skipping "marks all steps complete, grants nothing, and lifts
## suppression after 300 s". It grants nothing here by construction — the machine
## has never had anything to grant.
func skip() -> void:
	for id: String in step_ids():
		if not _completed.has(id):
			_completed.append(id)
	skipped = true
	_finish()


## Settings ▸ Replay tutorial. Everything the machine remembers, forgotten.
func reset() -> void:
	active = false
	skipped = false
	finished = false
	current_index = -1
	_completed.clear()
	_actions.clear()
	_reset_step_timers()


func _finish() -> void:
	active = false
	finished = true
	current_index = _steps.size()
	_queue(ACTION_RELEASE_DIRECTOR,
			{"seconds": number("director_suppress_after_s", DEFAULT_SUPPRESS_AFTER_S)})


func _enter_step(index: int) -> void:
	current_index = index
	_reset_step_timers()
	var step := step_at(index)
	var enter: Variant = step.get("on_enter", null)
	if enter is Dictionary and UIConfig.get_num(enter as Dictionary, "delay_s", 0.0) <= 0.0:
		_fire_enter(enter as Dictionary)


func _reset_step_timers() -> void:
	_elapsed_s = 0.0
	_enter_fired = false
	_cam_based = false
	_cam_base_focus = Vector3.ZERO
	_cam_base_zoom = 0.0


func _fire_enter(enter: Dictionary) -> void:
	if _enter_fired:
		return
	_enter_fired = true
	var payload: Dictionary = enter.duplicate()
	payload.erase("action")
	payload.erase("delay_s")
	_queue(StringName(str(enter.get("action", ""))), payload)


# ---------------------------------------------------------------------------
# The view model (`ui/onboarding_flow.gd` binds exactly this)
# ---------------------------------------------------------------------------

## `{}` when nothing should be on screen. Copy is resolved here, from
## `data/strings.en.json` (G-8), so the view authors no words.
func current() -> Dictionary:
	if not is_active():
		return {}
	var step := step_at(current_index)
	if step.is_empty():
		return {}
	var target: Variant = step.get("target", {})
	return {
		"id": str(step.get("id", "")),
		"index": current_index,
		"count": _steps.size(),
		"kind": StringName(str(step.get("kind", String(KIND_COACH)))),
		"gate": StringName(str(step.get("gate", String(GATE_SOFT)))),
		"text": _t(str(step.get("text_key", ""))),
		"target": (target as Dictionary) if target is Dictionary else {},
		"show_ack": str(step.get("kind", "")) == String(KIND_CARD),
		"ack_text": _t("ui_coach_got_it"),
		"skip_text": _t("ui_coach_skip"),
		"step_text": _t_args("ui_coach_step",
				{"n": current_index + 1, "total": _steps.size()}),
		"show_hint": show_hint(),
		"show_autohelp": show_autohelp(),
		"autohelp_text": _t("ui_coach_show_me"),
		"elapsed_s": _elapsed_s,
	}


## §2.17: after 25 s an arrow and a pulse are added to the mark; after 60 s a
## `Show me` button appears that performs the camera move or opens the menu —
## never the final commit, which is always the player's tap.
func show_hint() -> bool:
	return is_active() and _elapsed_s >= _hint_after_s()


func show_autohelp() -> bool:
	if not is_active():
		return false
	var step := step_at(current_index)
	return step.has("autohelp") and _elapsed_s >= _autohelp_after_s()


func _hint_after_s() -> float:
	var step := step_at(current_index)
	return UIConfig.get_num(step, "hint_after_s",
			number("hint_after_s", DEFAULT_HINT_AFTER_S))


func _autohelp_after_s() -> float:
	var step := step_at(current_index)
	return UIConfig.get_num(step, "autohelp_after_s",
			number("autohelp_after_s", DEFAULT_AUTOHELP_AFTER_S))


## The `Show me` tap. Queues the step's authored assist and nothing else.
func request_autohelp() -> bool:
	var step := step_at(current_index)
	var raw: Variant = step.get("autohelp", null)
	if not (raw is Dictionary) or not is_active():
		return false
	var help: Dictionary = raw
	var payload: Dictionary = help.duplicate()
	payload.erase("action")
	_queue(StringName(str(help.get("action", ""))), payload)
	return true


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

func _queue(action: StringName, payload: Dictionary = {}) -> void:
	if action == &"":
		return
	_actions.append({"action": action, "payload": payload})


## Drains the pending requests, oldest first. The shell decides which it honours;
## an unhandled action is a no-op, never an error.
func take_actions() -> Array[Dictionary]:
	var out: Array[Dictionary] = _actions.duplicate()
	_actions.clear()
	return out


func pending_action_count() -> int:
	return _actions.size()


# ---------------------------------------------------------------------------
# Ingest
# ---------------------------------------------------------------------------

## The one entry point. Returns true when this observation completed a step.
func feed(observation: Dictionary) -> bool:
	if not is_active():
		return false
	var kind := str(observation.get("kind", ""))
	if kind == OBS_TICK:
		_advance_clock(UIConfig.get_num(observation, "dt", 0.0))
		return false
	var step := step_at(current_index)
	var advance: Variant = step.get("advance", {})
	if not (advance is Dictionary):
		return false
	if not _matches(advance as Dictionary, observation):
		return false
	_complete_current()
	return true


## Convenience for the card's GOT IT, so a view never has to author the shape.
func ack() -> bool:
	return feed({"kind": OBS_ACK})


func _advance_clock(dt: float) -> void:
	_elapsed_s += maxf(0.0, dt)
	var step := step_at(current_index)
	var enter: Variant = step.get("on_enter", null)
	if enter is Dictionary and not _enter_fired:
		if _elapsed_s >= UIConfig.get_num(enter as Dictionary, "delay_s", 0.0):
			_fire_enter(enter as Dictionary)


func _complete_current() -> void:
	var id := str(step_at(current_index).get("id", ""))
	if id != "" and not _completed.has(id):
		_completed.append(id)
	if current_index + 1 >= _steps.size():
		_finish()
		return
	_enter_step(current_index + 1)


# ---------------------------------------------------------------------------
# Matching — one condition, one observation
# ---------------------------------------------------------------------------

func _matches(condition: Dictionary, obs: Dictionary) -> bool:
	var want := str(condition.get("kind", ""))
	if want == ADVANCE_ANY_OF:
		var raw: Variant = condition.get("conditions", [])
		if not (raw is Array):
			return false
		for entry: Variant in (raw as Array):
			if entry is Dictionary and _matches(entry as Dictionary, obs):
				return true
		return false
	var got := str(obs.get("kind", ""))
	# `camera` is the one condition that accumulates rather than triggering, so it
	# is measured even when this observation is not the one that crosses the line.
	if want == OBS_CAMERA:
		return got == OBS_CAMERA and _camera_moved_enough(condition, obs)
	if want != got:
		return false
	match want:
		OBS_ACK:
			return true
		OBS_UI_OPENED:
			return str(obs.get("path", "")) == str(condition.get("path", ""))
		OBS_COMMAND:
			if not bool(obs.get("ok", false)):
				return false
			if str(obs.get("command", "")) != str(condition.get("command", "")):
				return false
			return _match_block(condition, obs)
		OBS_VERDICT:
			if str(obs.get("code", "")).to_upper() \
					!= str(condition.get("code", "")).to_upper():
				return false
			return _match_block(condition, obs)
		OBS_SIM_EVENT:
			if str(obs.get("event", "")) != str(condition.get("event", "")):
				return false
			var payload: Variant = obs.get("payload", {})
			return _match_block(condition,
					(payload as Dictionary) if payload is Dictionary else {}, obs)
	return false


## The `match` block of §3.1's step shape. Every key must hold, and a key the
## observation does not carry is a miss — the doc's hard-gate test asserts that a
## `place_building` with the wrong `type_id`, or a tile outside the lot, does not
## complete the step.
func _match_block(condition: Dictionary, obs: Dictionary,
		fallback: Dictionary = {}) -> bool:
	var raw: Variant = condition.get("match", {})
	if not (raw is Dictionary):
		return true
	var want: Dictionary = raw
	for key: Variant in want:
		var name := str(key)
		if name == "region":
			if not _tile_in_region(str(want[key]), obs, fallback):
				return false
			continue
		var value: Variant = obs.get(name, fallback.get(name, null))
		if value == null or str(value) != str(want[key]):
			return false
	return true


## Chebyshev distance to the tag's tile, within `region_radius_tiles`. A tag the
## shell never resolved matches nothing — a coach mark pointing at a lot that does
## not exist must not be completable by accident.
func _tile_in_region(tag: String, obs: Dictionary, fallback: Dictionary = {}) -> bool:
	var anchor: Variant = _regions.get(tag, null)
	if not (anchor is Vector2i):
		return false
	var raw: Variant = obs.get("tile", fallback.get("tile", null))
	var tile: Vector2i
	if raw is Vector2i:
		tile = raw
	elif raw is Array and (raw as Array).size() >= 2:
		tile = Vector2i(int((raw as Array)[0]), int((raw as Array)[1]))
	else:
		return false
	var radius := int(number("region_radius_tiles", float(DEFAULT_REGION_RADIUS)))
	var delta: Vector2i = tile - (anchor as Vector2i)
	return maxi(absi(delta.x), absi(delta.y)) <= radius


## Step 1's completion: the camera actually moved. The first observation of a
## step is the baseline, so a step that begins mid-drag cannot complete on the
## drag that was already happening.
func _camera_moved_enough(condition: Dictionary, obs: Dictionary) -> bool:
	var focus: Variant = obs.get("focus", null)
	var zoom := UIConfig.get_num(obs, "zoom_t", 0.0)
	var pos: Vector3 = focus if focus is Vector3 else Vector3.ZERO
	if not _cam_based:
		_cam_based = true
		_cam_base_focus = pos
		_cam_base_zoom = zoom
		return false
	var pan_m := UIConfig.get_num(condition, "pan_m",
			number("camera_pan_m", DEFAULT_CAMERA_PAN_M))
	var zoom_t := UIConfig.get_num(condition, "zoom_t",
			number("camera_zoom_t", DEFAULT_CAMERA_ZOOM_T))
	var panned := _cam_base_focus.distance_to(pos) >= pan_m
	var zoomed := absf(zoom - _cam_base_zoom) >= zoom_t
	if str(condition.get("mode", "all")) == "any":
		return panned or zoomed
	return panned and zoomed


# ---------------------------------------------------------------------------
# Persistence (doc 12 §3.2 `ui.onboarding`)
# ---------------------------------------------------------------------------

func capture_state() -> Dictionary:
	return {
		"active": is_active(),
		"current_step": str(step_at(current_index).get("id", "")),
		"skipped": skipped,
		"completed": _completed.duplicate(),
		"finished": finished,
	}


## §3.2's migration policy applies here too: unknown step ids are dropped, a
## missing key takes its default, and a save can never resurrect a step this
## build no longer has.
func restore_state(state: Dictionary) -> void:
	reset()
	if state.is_empty():
		return
	var known := step_ids()
	var raw: Variant = state.get("completed", [])
	if raw is Array:
		for entry: Variant in (raw as Array):
			var id := str(entry)
			if known.has(id) and not _completed.has(id):
				_completed.append(id)
	skipped = bool(state.get("skipped", false))
	finished = bool(state.get("finished", skipped and not _completed.is_empty()))
	if _completed.size() >= known.size() and not known.is_empty():
		finished = true
	if finished:
		active = false
		current_index = _steps.size()
		return
	var step_id := str(state.get("current_step", ""))
	var index := index_of(step_id)
	current_index = index if index >= 0 else _first_unfinished()
	if bool(state.get("active", false)):
		active = true
		_enter_step(current_index)
	else:
		active = false
		_reset_step_timers()


func _t(key: String) -> String:
	if key == "":
		return ""
	return config.t(key) if config != null else key


func _t_args(key: String, args: Dictionary) -> String:
	return config.t(key, args) if config != null else key
