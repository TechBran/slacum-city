class_name OnboardingFlow
extends Control
## S12's view (doc 12 §2.2's `CoachLayer`): it owns one `OnboardingModel`, one
## `CoachMark`, and the two translations between them — a step's `target` into a
## screen rectangle, and the model's action queue into signals the shell can act
## on.
##
## It decides nothing about the tutorial. Every step, every sentence, every
## advance condition is `data/ui.json.onboarding` read by the model; this class
## resolves `{"kind":"ui","path":…}` against the live `UIRoot` and
## `{"kind":"world","tag":…}` against a resolver the shell injects, then re-presents
## the mark each frame so the highlight follows a sheet that slides or a camera
## that moves.
##
## **It never blocks the simulation.** There is no `set_paused`, no `process_mode`
## change and no modal here: a hard gate is a hit-test on the mark (see
## `CoachMark._has_point`), so the city keeps running underneath a coach mark for
## as long as the player leaves it up, and `Skip tutorial` is always one tap away.

signal action_requested(action: StringName, payload: Dictionary)
signal step_changed(step_id: String, index: int)
signal finished(skipped: bool)

## Screen ids the model's `ui_opened` conditions are written against. The shell
## and `UIRoot` feed these names; nothing here knows a node path for them.
const SCREEN_BUILD_SHEET := "build_sheet"
const SCREEN_INCIDENT_DRAWER := "incident_drawer"
## S14. The handoff step (`next_goals`) is satisfied by opening it — doc 09
## §2.14's "here is what to do next", which is what the tutorial ends on now.
const SCREEN_GOALS_SHEET := "goals_sheet"
const SCREEN_BUILD_CATEGORY := "build_category_"

const TARGET_UI := "ui"
const TARGET_WORLD := "world"

var config: UIConfig
var model: OnboardingModel

var _mark: CoachMark
var _world_resolver := Callable()
var _last_step := ""
var _marker_dp := 48.0


func setup(cfg: UIConfig = null, p_model: OnboardingModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	model = p_model if p_model != null else OnboardingModel.new(config)
	_marker_dp = UIConfig.get_num(config.layout(), "marker_tap_dp", 48.0)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _mark == null:
		_mark = CoachMark.new()
		add_child(_mark)
		_mark.setup(config)
		_mark.skip_pressed.connect(_on_skip)
		_mark.ack_pressed.connect(_on_ack)
		_mark.autohelp_pressed.connect(_on_autohelp)
	_refresh()


func _ready() -> void:
	if model == null:
		setup(UIRoot.config_from(self))


## `Callable(tag: String) -> Variant` — a `Rect2` in screen coordinates, a
## `Vector2` screen point (which becomes a 48 dp square), or null when the tag is
## off screen. Only the shell can project a world tag, so only the shell supplies
## this; without it a world step still runs, with a centred bubble and no cutout.
func set_world_resolver(resolver: Callable) -> void:
	_world_resolver = resolver


func mark() -> CoachMark:
	return _mark


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

## Starts the flow unless it is already finished (§2.17: it never shows twice).
## `regions` maps a step's `region`/world tag to a world tile, e.g.
## `{"tutorial_lot_a": Vector2i(43, 40)}`.
func start(regions: Dictionary = {}) -> bool:
	if model == null:
		return false
	if not regions.is_empty():
		model.set_regions(regions)
	var started := model.start()
	_drain()
	_refresh(true)
	return started


func is_active() -> bool:
	return model != null and model.is_active()


func is_finished() -> bool:
	return model != null and model.is_finished()


## Settings ▸ Replay tutorial: forget everything and be startable again.
func reset() -> void:
	if model == null:
		return
	model.reset()
	_last_step = ""
	_refresh(true)


func skip() -> void:
	_on_skip()


# ---------------------------------------------------------------------------
# Ingest
# ---------------------------------------------------------------------------

## One observation into the step machine (see `OnboardingModel` for the shapes).
## Returns true when it completed a step.
func feed(observation: Dictionary) -> bool:
	if model == null or not model.is_active():
		return false
	var advanced := model.feed(observation)
	_drain()
	_refresh(advanced)
	if advanced and model.is_finished():
		finished.emit(model.skipped)
	return advanced


## Sugar for the two observations the shell produces most often.
func feed_camera(focus: Vector3, zoom_t: float) -> bool:
	return feed({"kind": OnboardingModel.OBS_CAMERA, "focus": focus, "zoom_t": zoom_t})


func feed_ui_opened(path: String) -> bool:
	return feed({"kind": OnboardingModel.OBS_UI_OPENED, "path": path})


func _process(delta: float) -> void:
	if model == null or not model.is_active():
		return
	model.feed({"kind": OnboardingModel.OBS_TICK, "dt": delta})
	_drain()
	# Re-presented every frame: the cutout has to follow a sliding sheet, a
	# scrolling list and a moving camera, and none of those announce themselves.
	_refresh()


func _drain() -> void:
	if model == null:
		return
	for entry: Dictionary in model.take_actions():
		action_requested.emit(StringName(str(entry.get("action", ""))),
				entry.get("payload", {}) as Dictionary)


# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------

func _refresh(force: bool = false) -> void:
	if _mark == null:
		return
	var view: Dictionary = model.current() if model != null else {}
	if view.is_empty():
		if _mark.is_showing() or force:
			_mark.hide_mark()
		return
	_mark.present(view, target_rect(view.get("target", {}) as Dictionary))
	var id := str(view.get("id", ""))
	if id != _last_step:
		_last_step = id
		step_changed.emit(id, int(view.get("index", 0)))


## The highlight, in screen coordinates. An unresolvable target is not an error:
## the mark simply dims everything and centres its bubble, which is exactly what
## the doc's card steps want.
func target_rect(target: Dictionary) -> Rect2:
	match str(target.get("kind", "")):
		TARGET_UI:
			var node := _resolve_ui(str(target.get("path", "")))
			if node == null or not OnboardingFlow.is_shown(node):
				return Rect2()
			var rect := node.get_global_rect()
			return rect if rect.size.x > 0.0 and rect.size.y > 0.0 else Rect2()
		TARGET_WORLD:
			if not _world_resolver.is_valid():
				return Rect2()
			var answer: Variant = _world_resolver.call(str(target.get("tag", "")))
			if answer is Rect2:
				return answer
			if answer is Vector2:
				var point: Vector2 = answer
				return Rect2(point - Vector2(_marker_dp, _marker_dp) * 0.5,
						Vector2(_marker_dp, _marker_dp))
			return Rect2()
	return Rect2()


## Is this control actually on screen? Deliberately **not**
## `is_visible_in_tree()`: that answer folds in the viewport's own rendering
## state, and under `--headless` it is false for every Control in a mounted
## scene, which would make a coach mark untestable and its target unresolvable in
## exactly the harness the tests use. Walking the `CanvasItem` chain asks the
## only question the highlight cares about — did somebody hide this, or a box it
## sits in.
static func is_shown(node: CanvasItem) -> bool:
	var current: Node = node
	while current is CanvasItem:
		if not (current as CanvasItem).visible:
			return false
		current = current.get_parent()
	return true


## Paths in the table are written from `UIRoot` down ("SafeArea/…"), because that
## is the tree the doc's §4.1 diagram names.
func _resolve_ui(path: String) -> Control:
	if path == "":
		return null
	var root := _ui_root()
	if root == null:
		return null
	return root.get_node_or_null(path) as Control


func _ui_root() -> Node:
	var current: Node = get_parent()
	while current != null:
		if current is UIRoot:
			return current
		current = current.get_parent()
	return null


# ---------------------------------------------------------------------------
# Input from the bubble
# ---------------------------------------------------------------------------

func _on_skip() -> void:
	if model == null:
		return
	model.skip()
	_drain()
	_refresh(true)
	finished.emit(true)


func _on_ack() -> void:
	feed({"kind": OnboardingModel.OBS_ACK})


func _on_autohelp() -> void:
	if model == null:
		return
	model.request_autohelp()
	_drain()


# ---------------------------------------------------------------------------
# Persistence — the `ui.onboarding` block of doc 12 §3.2
# ---------------------------------------------------------------------------

func capture_state() -> Dictionary:
	return model.capture_state() if model != null else {}


func restore_state(state: Dictionary) -> void:
	if model == null:
		return
	model.restore_state(state)
	_last_step = ""
	_drain()
	_refresh(true)
