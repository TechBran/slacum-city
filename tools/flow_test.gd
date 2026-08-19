extends Node
## The tutorial, played by a robot, **in the shipped shell**.
##
## `tests/test_tutorial_flow.gd` drives the same eleven steps over a mounted
## `ui_root.tscn` with `game/main.gd`'s seam reproduced by hand — that is what a
## headless `SimTest` can reach, and it is the version that runs in the suite.
## This harness answers the question that one cannot: does the *real*
## `game/main.tscn` — its own `_wire_build_ui`, its own `_process`, its own
## `SimHost` accumulator, its own camera rig, its own coach-action handler —
## still walk a player from a fresh boot to a relit block?
##
## Every beat is a real control being pressed on the real tree:
##
##     BuildSheet/Fab                       the BUILD button
##     Sheet/Body/Scroll/Cards/Card_house   the card
##     TouchInput.tapped                    the finger on the ground (the same
##                                          signal `GestureRecognizer` emits)
##     PlacementBar/Row/Confirm             PLACE
##     IncidentDrawer/Handle                the drawer pull
##     Assign_<id> / Unit_<id>              ASSIGN, then the unit row
##     CoachMark's GOT IT                   the two card steps
##
## Usage:
##   ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
##       tools/flow_test.tscn -- [options]
##
##   --time-scale=N   compress the flow's real-time waits (the `blackout` step's
##                    6 s on_enter delay, the repair). Default 1.0 — an honest
##                    run. 6.0 is the usual CI setting.
##   --verbose        print every frame's step id and the actions taken
##   --json=FILE      write the step table (id, wall seconds, game minutes)
##
## Exit code is 0 only when all eleven steps advanced, every city assertion held
## and no step timed out. A CI wrapper should also fail on engine errors:
##
##   godot --headless --path . tools/flow_test.tscn -- --time-scale=6 2>&1 \
##       | tee /tmp/flow.log; grep -q "SCRIPT ERROR" /tmp/flow.log && exit 1
##
## Nothing in `game/` or `ui/` is edited, monkey-patched or stubbed: the harness
## only presses buttons and reads state, like `tools/playtest.gd` only issues
## commands and reads numbers (constitution §3).

const TILE_M := 8.0
## Real seconds a single step may take before the run is called stalled. The
## longest legitimate wait is `relight` (the crew drives and works: ~60 game-
## minutes ≈ 60 real seconds at 1x), so this is that plus headroom.
const STEP_TIMEOUT_S := 150.0
## The whole flow, as a backstop against a step machine that ping-pongs.
const RUN_TIMEOUT_S := 400.0
## How long the city checks wait for doc 04 to re-energise the repaired feeder
## after the tutorial's last card. 30 s of flow time is 30 game-minutes at 1x;
## `tests/test_incidents_transformer_arc.gd` measures the real relight at ~20.
const RELIGHT_GRACE_S := 45.0
const STEP_IDS: Array[String] = [
	"welcome", "look_around", "open_build", "place_house", "unserved_wall",
	"place_transformer", "blackout", "open_drawer", "dispatch", "relight", "payoff",
]

var _time_scale := 1.0
var _verbose := false
var _json_path := ""

var _main: Node
var _ui: UIRoot
var _sim: CitySim
var _camera: CameraState
var _sheet: BuildSheet
var _controller: BuildController

var _lot_a := Vector2i.ZERO
var _lot_b := Vector2i.ZERO
var _incident_id := 0

var _last_step := "<boot>"
var _acted := false
var _step_started := 0.0
var _elapsed := 0.0
var _rows: Array[Dictionary] = []
var _failures: Array[String] = []
var _checks := 0
var _done := false
var _tap_landed := 0
var _tap_missed := 0
## Set when the eleventh step is acknowledged. Doc 04 re-energises a repaired
## component on its own cadence, so the city checks wait for the lights rather
## than reading the grid the instant the coach layer goes away.
var _relight_deadline := -1.0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if text.begins_with("--time-scale="):
			_time_scale = maxf(0.1, float(text.trim_prefix("--time-scale=")))
		elif text == "--verbose":
			_verbose = true
		elif text.begins_with("--json="):
			_json_path = text.trim_prefix("--json=")
	Engine.time_scale = _time_scale

	var packed: PackedScene = load("res://game/main.tscn")
	_main = packed.instantiate()
	add_child(_main)

	_ui = _main.get("ui_root") as UIRoot
	var host: Node = _main.get("sim_host") as Node
	_sim = host.get("sim") as CitySim if host != null else null
	_camera = _main.get("camera_state") as CameraState
	_sheet = _main.get("build_sheet") as BuildSheet
	_controller = _main.get("build_controller") as BuildController
	if _ui == null or _sim == null or _camera == null or _sheet == null:
		_fail("the shell did not come up (ui=%s sim=%s camera=%s sheet=%s)"
				% [_ui != null, _sim != null, _camera != null, _sheet != null])
		_finish()
		return

	_check(_sim.boot_errors.is_empty(),
			"the starter city boots clean: %s" % str(_sim.boot_errors))
	_lot_a = _sim.loader.resolve_tag("tutorial_lot_a")["tile_global"]
	_lot_b = _sim.loader.resolve_tag("tutorial_lot_b")["tile_global"]
	_check(_ui.onboarding_active(), "a fresh boot starts the tutorial by itself")
	_check(_ui.onboarding.model.step_ids() == STEP_IDS,
			"data/ui.json still carries the eleven steps this harness plays")
	print("flow_test: shell up, %d buildings, tutorial at '%s'"
			% [_sim.buildings.size(), _step_id()])


func _process(delta: float) -> void:
	if _done or _ui == null:
		return
	_elapsed += delta
	if _elapsed > RUN_TIMEOUT_S:
		_fail("the run exceeded %.0f s without finishing" % RUN_TIMEOUT_S)
		_finish()
		return

	var id := _step_id()
	if id != _last_step:
		_record(_last_step, id)
		_last_step = id
		_acted = false
		_step_started = _elapsed

	if _ui.onboarding.is_finished():
		# §2.17 ends on the card; doc 04 ends when the block is bright again.
		if _relight_deadline < 0.0:
			_relight_deadline = _elapsed + RELIGHT_GRACE_S
			print("flow_test: tutorial finished, waiting for T-04's block to relight")
		if _block_dark("T-04") > 0 and _elapsed < _relight_deadline:
			return
		_after_the_flow()
		_finish()
		return
	if not _ui.onboarding_active():
		_fail("the tutorial went inactive without finishing (step '%s')" % id)
		_finish()
		return
	if _elapsed - _step_started > STEP_TIMEOUT_S:
		_fail("step '%s' did not advance in %.0f s" % [id, STEP_TIMEOUT_S])
		_finish()
		return
	if not _acted:
		_act(id)


# ---------------------------------------------------------------------------
# One player action per step. `_acted` is only set for the steps that HAVE an
# action: `blackout` and `relight` are waits, and re-running their (empty) case
# every frame costs nothing.
# ---------------------------------------------------------------------------

func _act(id: String) -> void:
	match id:
		"welcome", "payoff":
			_press(_ack_button(), "GOT IT")
			_acted = true
		"look_around":
			# Pan six tiles and change the zoom: §2.17 wants both verbs, and
			# main.gd samples CameraState into the coach layer every frame.
			_camera.set_focus(Vector3(_lot_b.x * TILE_M, 0.0, _lot_b.y * TILE_M))
			_camera.set_zoom_t(0.34)
			_acted = true
		"open_build":
			_press(_node("SafeArea/SheetLayer/BuildSheet/Fab"), "BUILD fab")
			_acted = true
		"place_house":
			_place("house", _lot_b, true)
			_acted = true
		"unserved_wall":
			# The wall is a verdict, so this stops at the ghost: PLACE is
			# disabled and the step advances off the preflight.
			_place("house", _lot_a, false)
			_acted = true
		"place_transformer":
			_sheet.cancel_placement()
			_place("transformer", _lot_a + Vector2i(-1, 0), true)
			_acted = true
		"blackout":
			# The step's own on_enter fires the incident after 6 s; nothing to do
			# but let the shell honour it.
			if _incident_id == 0 and _sim.incidents.active_count() > 0:
				for row: Variant in _sim.incidents.snapshot():
					_incident_id = int((row as Dictionary)["id"])
					break
		"open_drawer":
			_press(_node("SafeArea/PanelLayer/IncidentDrawer/Handle"), "drawer handle")
			_acted = true
		"dispatch":
			_dispatch()
			_acted = true
		"relight":
			pass   # the crew is driving; doc 06 owns the clock


## Press a card, put the finger on the ground, and (optionally) press PLACE.
func _place(card_id: String, tile: Vector2i, confirm: bool) -> void:
	if not _sheet.is_open():
		_sheet.open()
	for card: Dictionary in _controller.cards():
		if str(card["id"]) == card_id:
			_sheet.select_category(str(card["category"]))
			break
	var button := _sheet.card_button(card_id)
	if button == null:
		_fail("no %s card on the build sheet" % card_id)
		return
	_press(button, "%s card" % card_id)
	# A player pans to the lot before tapping it; the coach mark's own
	# `focus_camera` is a tween, and a tween is not a place to aim a finger from.
	_camera.set_focus(Vector3(tile.x * TILE_M + TILE_M * 0.5, 0.0,
			tile.y * TILE_M + TILE_M * 0.5))
	_tap_ground(tile)
	if not confirm:
		return
	var place_button := _node("SafeArea/SheetLayer/BuildSheet/PlacementBar/Row/Confirm")
	_check(place_button != null and not (place_button as Button).disabled,
			"PLACE is live for %s at %s" % [card_id, str(tile)])
	_press(place_button, "PLACE")


## The finger, through the same signal `GestureRecognizer` emits on a real tap.
## Falls back to the ghost call only if the projection missed, and says so —
## a tap that does not land where the player aimed is a defect, not a detail.
func _tap_ground(tile: Vector2i) -> void:
	var viewport := Vector2(get_viewport().get_visible_rect().size)
	var world := Vector3(tile.x * TILE_M + TILE_M * 0.5, 0.0, tile.y * TILE_M + TILE_M * 0.5)
	var answer := _camera.project_to_screen(world, viewport)
	var touch: Node = _main.get("touch_input") as Node
	if not bool(answer["behind"]) and touch != null:
		touch.emit_signal("tapped", answer["position"] as Vector2)
		if _controller.is_placing() and _controller.origin == tile:
			_tap_landed += 1
			return
		_tap_missed += 1
		print("  [tap] projected %s -> tile %s (wanted %s); using move_ghost"
				% [str(answer["position"]), str(_controller.origin), str(tile)])
	_sheet.move_ghost(world)


## §2.6's two taps: ASSIGN on the incident row, then a unit in the picker.
func _dispatch() -> void:
	var drawer: IncidentDrawer = _ui.incident_drawer
	if _incident_id == 0:
		for row: Variant in drawer.model.rows():
			_incident_id = int((row as Dictionary)["id"])
			break
	if _incident_id == 0:
		_fail("the drawer has no incident to dispatch to")
		return
	var row_button := drawer.row_button(_incident_id)
	if row_button == null:
		_fail("incident %d has no row in the drawer" % _incident_id)
		return
	_press(row_button, "incident row")
	var assign := drawer.action_button("Assign", _incident_id)
	if assign == null:
		_fail("the expanded row has no ASSIGN button")
		return
	_press(assign, "ASSIGN")
	_check(_ui.unit_picker.is_open(), "ASSIGN opened the unit picker")
	var unit_id := -1
	for row: Dictionary in _ui.unit_picker.model.eligible_rows():
		unit_id = int(row["id"])
		break
	if unit_id < 0:
		_fail("the picker offers no dispatchable unit")
		return
	_press(_ui.unit_picker.unit_button(unit_id), "unit %d" % unit_id)
	var unit: Vehicle = _sim.incidents.fleet.unit(unit_id)
	_check(unit != null and unit.incident_id == _incident_id,
			"unit %d is on the job" % unit_id)


# ---------------------------------------------------------------------------
# The city the player is left with
# ---------------------------------------------------------------------------

func _after_the_flow() -> void:
	_record(_last_step, "<finished>")
	var model := _ui.onboarding.model
	_check(not model.skipped, "the flow was played, not skipped")
	_check(model.completed_ids().size() == STEP_IDS.size(),
			"all %d steps completed, got %d" % [STEP_IDS.size(), model.completed_ids().size()])
	_check(String(_sim.grid.component("T-04")["state"]) == "OK",
			"the tutorial transformer was repaired (state=%s)"
					% String(_sim.grid.component("T-04")["state"]))
	var placed := 0
	for id: Variant in _sim.grid.component_ids():
		var component: Dictionary = _sim.grid.component(String(id))
		if bool(component.get("player_placed", false)):
			placed += 1
	_check(placed >= 1, "the transformer the player bought is on the grid")
	var dark := _block_dark("T-04")
	_check(dark == 0, "T-04's block is relit (%d customers still dark)" % dark)
	var coach: Dictionary = _ui.capture_ui_state().get("onboarding", {})
	_check(bool(coach.get("finished", false)),
			"doc 12 §3.2's ui.onboarding.finished is set for the save")


# ---------------------------------------------------------------------------
# Bookkeeping
# ---------------------------------------------------------------------------

func _step_id() -> String:
	if _ui == null or _ui.onboarding == null:
		return ""
	return str(_ui.onboarding.model.current().get("id", ""))


## Customers of `component_id` that are still unlit.
func _block_dark(component_id: String) -> int:
	var dark := 0
	for id: Variant in _sim.buildings.keys():
		if _sim.grid.attachment_of(String(id)) == component_id \
				and not _sim.grid.is_powered(String(id)):
			dark += 1
	return dark


func _record(from: String, to: String) -> void:
	if from == "<boot>" or not STEP_IDS.has(from):
		return
	var row := {
		"step": from,
		"next": to,
		"wall_s": snappedf(_elapsed - _step_started, 0.001),
		"game_minute": _sim.clock.sim_time_minutes() if _sim != null else 0,
	}
	_rows.append(row)
	if _verbose:
		print("  [step] %-18s -> %-18s  %.2f s" % [from, to, float(row["wall_s"])])


func _press(button: Object, what: String) -> void:
	if button == null:
		_fail("missing control: %s" % what)
		return
	var control := button as Button
	if control == null:
		_fail("%s is not a Button" % what)
		return
	if control.disabled:
		_fail("%s is disabled" % what)
		return
	control.pressed.emit()
	if _verbose:
		print("  [tap] %s" % what)


func _node(path: String) -> Control:
	return _ui.get_node_or_null(path) as Control


func _ack_button() -> Button:
	var mark: CoachMark = _ui.onboarding.mark()
	return mark.ack_button() if mark != null else null


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)
	printerr("flow_test FAIL: " + message)


func _finish() -> void:
	if _done:
		return
	_done = true
	Engine.time_scale = 1.0
	var seen: Array[String] = []
	for row: Dictionary in _rows:
		seen.append(str(row["step"]))
	print("")
	print("========================================")
	print("flow_test — doc 12 §2.17 over game/main.tscn")
	for row: Dictionary in _rows:
		print("  %-18s %6.2f s  (game minute %d)"
				% [row["step"], float(row["wall_s"]), int(row["game_minute"])])
	print("  steps advanced: %d/%d" % [seen.size(), STEP_IDS.size()])
	print("  checks:         %d" % _checks)
	print("  taps landed:    %d  (fell back to move_ghost: %d)" % [_tap_landed, _tap_missed])
	print("  time scale:     %.1fx   wall: %.1f s" % [_time_scale, _elapsed])
	print("  failed:         %d" % _failures.size())
	print("========================================")
	if seen.size() < STEP_IDS.size():
		for id in STEP_IDS:
			if not seen.has(id):
				printerr("flow_test FAIL: step '%s' was never reached" % id)
				_failures.append("step '%s' never reached" % id)
	if _json_path != "":
		var file := FileAccess.open(_json_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify({
				"steps": _rows, "checks": _checks,
				"failures": _failures, "wall_s": _elapsed,
				"time_scale": _time_scale}, "  "))
	if _failures.is_empty():
		print("FLOW TEST PASSED")
	else:
		printerr("FLOW TEST FAILED (%d)" % _failures.size())
	get_tree().quit(0 if _failures.is_empty() else 1)
