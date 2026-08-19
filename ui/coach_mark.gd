class_name CoachMark
extends Control
## The coach mark of doc 12 §2.17: a full-screen dim with a rounded-rect cutout
## over the thing the player must touch, one sentence of instruction in a bubble
## no wider than 240 dp, and `Skip tutorial` always reachable.
##
## Built in code, not authored in the `.tscn`, so every dimension comes from
## `data/ui.json` at runtime (doc 12 test 19) and every word from
## `data/strings.en.json` (G-8). It computes nothing about the tutorial: it is
## handed a view Dictionary from `OnboardingModel.current()` and a target
## rectangle, and it draws them.
##
## **How a hard gate can gate without breaking the game.** `_has_point()` is the
## whole mechanism: the mark is `MOUSE_FILTER_STOP`, but it claims only the
## points *outside* the cutout, so the target control underneath keeps receiving
## touches while everything else is swallowed. A soft gate claims nothing at all
## and the bubble's own buttons — real `Control` children with their own hit
## test — stay tappable in both. Nothing here ever pauses the simulation; the
## dim is a picture, not a modal.

signal skip_pressed
signal ack_pressed
signal autohelp_pressed

const PALETTE_TYPE := "Palette"

## Doc 12 §2.17's numbers live in `data/ui.json.onboarding`; these are the
## degrade-loudly fallbacks for a malformed file.
const DIM_ALPHA := 0.55
const CUTOUT_PAD_DP := 8.0
const CUTOUT_RADIUS_DP := 12.0
const CUTOUT_BORDER_DP := 3.0
const BUBBLE_MAX_W_DP := 240.0
const BUBBLE_GAP_DP := 12.0
const ANIM_S := 0.20
## §2.5's critical pulse, reused for the §2.17 hint (`state_pulse_hz.critical`).
const PULSE_HZ := 1.2
const ARROW_DP := 14.0
## §2.17's refusal feedback on a hard gate.
const SHAKE_DP := 6.0
const SHAKE_S := 0.18
const SHAKE_HZ := 14.0

var config: UIConfig

var _dim_alpha := DIM_ALPHA
var _pad := CUTOUT_PAD_DP
var _radius := CUTOUT_RADIUS_DP
var _border := CUTOUT_BORDER_DP
var _bubble_w := BUBBLE_MAX_W_DP
var _gap := BUBBLE_GAP_DP
var _anim_s := ANIM_S
var _pulse_hz := PULSE_HZ
var _touch_min := 48.0
var _spacing := 8.0

var _bubble: PanelContainer
var _text: Label
var _step: Label
var _skip: Button
var _ack: Button
var _help: Button

var _view: Dictionary = {}
var _target := Rect2()          ## where the cutout is going, in local coordinates
var _drawn := Rect2()           ## where it is now (the 0.2 s animation)
var _has_target := false
var _hard := false
var _pulse_t := 0.0
var _shake_t := 0.0
var _bubble_home := Vector2.ZERO


func setup(cfg: UIConfig = null) -> void:
	config = cfg if cfg != null else UIConfig.load_from_files()
	var block := config.section("onboarding")
	var layout := config.layout()
	var defaults := config.section("defaults")
	_dim_alpha = UIConfig.get_num(block, "dim_alpha", DIM_ALPHA)
	_pad = UIConfig.get_num(block, "cutout_pad_dp", CUTOUT_PAD_DP)
	_radius = UIConfig.get_num(block, "cutout_radius_dp", CUTOUT_RADIUS_DP)
	_border = UIConfig.get_num(block, "cutout_border_dp", CUTOUT_BORDER_DP)
	_bubble_w = UIConfig.get_num(block, "bubble_max_w_dp", BUBBLE_MAX_W_DP)
	_gap = UIConfig.get_num(block, "bubble_gap_dp", BUBBLE_GAP_DP)
	_anim_s = UIConfig.get_num(layout, "coach_cutout_anim_s", ANIM_S)
	var pulses := config.section("state_pulse_hz")
	_pulse_hz = UIConfig.get_num(pulses, "critical", PULSE_HZ)
	# A8: reduce motion keeps the state and drops the animation, never the mark.
	if bool(defaults.get("reduce_motion", false)):
		_anim_s = 0.0
		_pulse_hz = 0.0
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(layout, "touch_spacing_min_dp", 8.0)
	name = "CoachMark"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	hide_mark()


func _ready() -> void:
	if config == null:
		setup(UIRoot.config_from(self))


func _build() -> void:
	if _bubble != null:
		return
	_bubble = PanelContainer.new()
	_bubble.name = "Bubble"
	_bubble.theme_type_variation = &"CoachBubble"
	_bubble.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_bubble)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override(&"separation", int(_spacing))
	_bubble.add_child(body)

	_step = UIWidgets.label("Step", "", &"LegendRow")
	body.add_child(_step)

	_text = UIWidgets.label("Text", "", &"", true)
	body.add_child(_text)

	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override(&"separation", int(_spacing))
	body.add_child(row)

	# `Skip tutorial` is the longest label in the bubble and the one that may never
	# be abbreviated (§2.17 names it verbatim), so it gets the width its copy
	# needs — 2.4 × the touch floor — and does not clip. A card step shows Skip +
	# GOT IT and a coach step shows Skip + `Show me`; never all three, which is
	# what keeps the row inside the 240 dp cap.
	_skip = UIWidgets.button("Skip", UIWidgets.t(config, "ui_coach_skip", "Skip tutorial"),
			UIWidgets.t(config, "ui_coach_skip", "Skip tutorial"),
			Vector2(_touch_min * 2.4, _touch_min), &"GhostButton")
	_skip.clip_text = false
	_skip.pressed.connect(func() -> void: skip_pressed.emit())
	row.add_child(_skip)

	row.add_child(UIWidgets.spacer())

	_help = UIWidgets.button("ShowMe", UIWidgets.t(config, "ui_coach_show_me", "Show me"),
			UIWidgets.t(config, "ui_coach_show_me", "Show me"),
			Vector2(_touch_min * 1.4, _touch_min), &"GhostButton")
	_help.pressed.connect(func() -> void: autohelp_pressed.emit())
	row.add_child(_help)

	_ack = UIWidgets.button("Ack", UIWidgets.t(config, "ui_coach_got_it", "GOT IT"),
			UIWidgets.t(config, "ui_coach_got_it", "GOT IT"),
			Vector2(_touch_min * 1.4, _touch_min), &"PrimaryFAB")
	_ack.pressed.connect(func() -> void: ack_pressed.emit())
	row.add_child(_ack)


# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------

## `view` is `OnboardingModel.current()` verbatim. `target` is the highlight in
## **global** screen coordinates; an empty rect means "no cutout" and the bubble
## centres itself.
func present(view: Dictionary, target: Rect2 = Rect2()) -> void:
	_view = view
	if view.is_empty():
		hide_mark()
		return
	visible = true
	_hard = StringName(str(view.get("gate", "soft"))) == OnboardingModel.GATE_HARD
	# A soft gate lets every touch through; a hard one swallows what is outside
	# the cutout (§2.17). Either way the bubble's buttons keep their own hits.
	mouse_filter = Control.MOUSE_FILTER_STOP if _hard else Control.MOUSE_FILTER_IGNORE
	var local := _to_local_rect(target)
	_has_target = local.size.x > 0.0 and local.size.y > 0.0
	_target = local.grow(_pad) if _has_target else Rect2()
	if not _has_target:
		_drawn = Rect2()
	elif _drawn.size == Vector2.ZERO or _anim_s <= 0.0:
		_drawn = _target
	if _step != null:
		_step.text = str(view.get("step_text", ""))
	if _text != null:
		_text.text = str(view.get("text", ""))
	if _ack != null:
		_ack.visible = bool(view.get("show_ack", false))
	if _help != null:
		_help.visible = bool(view.get("show_autohelp", false))
	_layout_bubble()
	queue_redraw()


func hide_mark() -> void:
	visible = false
	_view = {}
	_has_target = false
	_target = Rect2()
	_drawn = Rect2()
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func is_showing() -> bool:
	return visible and not _view.is_empty()


## The rectangle the cutout is currently drawn at, in local coordinates — what
## the headless tests assert against.
func cutout_rect() -> Rect2:
	return _drawn


func _to_local_rect(global: Rect2) -> Rect2:
	if global.size.x <= 0.0 or global.size.y <= 0.0:
		return Rect2()
	var inverse := get_global_transform().affine_inverse()
	return Rect2(inverse * global.position, global.size)


## Below the cutout when there is room, above it when there is not, and
## bottom-centred (thumb reach, §2.3) when there is no cutout at all. The bubble
## never covers the thing it points at — except when the cutout is taller than
## the screen has room for, where the least-bad answer is the bottom edge.
func _layout_bubble() -> void:
	if _bubble == null:
		return
	var width := minf(_bubble_w, maxf(_touch_min * 2.0, size.x - _gap * 2.0))
	if _text != null:
		_text.custom_minimum_size.x = width - _spacing * 2.0
	_bubble.custom_minimum_size.x = width
	_bubble.size = Vector2(width, _bubble.get_combined_minimum_size().y)
	var height := _bubble.size.y
	var x := clampf(size.x * 0.5 - width * 0.5, _gap, maxf(_gap, size.x - width - _gap))
	var y := size.y - height - _gap
	if _has_target:
		x = clampf(_target.get_center().x - width * 0.5, _gap,
				maxf(_gap, size.x - width - _gap))
		var below := _target.end.y + _gap
		var above := _target.position.y - height - _gap
		y = below if below + height <= size.y - _gap else above
		if y < _gap:
			y = clampf(size.y - height - _gap, _gap, maxf(_gap, size.y - height - _gap))
	_bubble_home = Vector2(x, maxf(_gap, y))
	_bubble.position = _bubble_home


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_showing():
		_layout_bubble()
		queue_redraw()


## `_has_point` is the gate. Outside the cutout on a hard step: mine, swallowed.
## Inside it, or on any soft step: not mine, and the touch falls through to the
## control the mark is pointing at — which is the only way `Tap BUILD` can be
## satisfied by tapping BUILD.
##
## A hard step whose target did not resolve claims **nothing**. That is the safe
## failure: a cutout-less hard gate would swallow the whole screen and leave the
## player with one working button (Skip), so a missing target degrades the gate
## to soft rather than trapping the game.
func _has_point(point: Vector2) -> bool:
	if not _hard or not visible or not _has_target:
		return false
	return not _drawn.has_point(point)


## §2.17's "swallows touches outside the cutout with a 6 dp shake" — the shake is
## the only feedback a refused touch gets, so it has to happen where the touch
## actually lands, which is here.
func _gui_input(event: InputEvent) -> void:
	if not _hard or _anim_s <= 0.0:
		return
	var touched := (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed) \
			or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed)
	if touched:
		_shake_t = SHAKE_S


func _process(delta: float) -> void:
	if not is_showing():
		return
	var redraw := false
	if _has_target and _drawn != _target:
		if _anim_s <= 0.0:
			_drawn = _target
		else:
			var k := clampf(delta / _anim_s, 0.0, 1.0)
			_drawn = Rect2(_drawn.position.lerp(_target.position, k),
					_drawn.size.lerp(_target.size, k))
			if _drawn.position.distance_to(_target.position) < 0.5 \
					and _drawn.size.distance_to(_target.size) < 0.5:
				_drawn = _target
		_layout_bubble()
		redraw = true
	if _pulse_hz > 0.0 and bool(_view.get("show_hint", false)):
		_pulse_t += delta
		redraw = true
	if _shake_t > 0.0 and _bubble != null:
		_shake_t = maxf(0.0, _shake_t - delta)
		var amplitude := SHAKE_DP * (_shake_t / SHAKE_S)
		_bubble.position = _bubble_home \
				+ Vector2(sin(_shake_t * TAU * SHAKE_HZ) * amplitude, 0.0)
	if redraw:
		queue_redraw()


# ---------------------------------------------------------------------------
# Drawing — dim, cutout, arrow
# ---------------------------------------------------------------------------

func _draw() -> void:
	if _view.is_empty():
		return
	var dim := Color(0.0, 0.0, 0.0, _dim_alpha)
	var full := Rect2(Vector2.ZERO, size)
	if not _has_target:
		draw_rect(full, dim)
		return
	var hole := _drawn
	# Four bands around the hole: no shader, no mask texture, no per-pixel cost.
	draw_rect(Rect2(0.0, 0.0, size.x, hole.position.y), dim)
	draw_rect(Rect2(0.0, hole.end.y, size.x, size.y - hole.end.y), dim)
	draw_rect(Rect2(0.0, hole.position.y, hole.position.x, hole.size.y), dim)
	draw_rect(Rect2(hole.end.x, hole.position.y, size.x - hole.end.x, hole.size.y), dim)
	_draw_ring(hole)
	if bool(_view.get("show_hint", false)):
		_draw_arrow(hole)


func _draw_ring(hole: Rect2) -> void:
	var color := _ring_color()
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	box.border_color = color
	box.set_border_width_all(int(maxf(1.0, _border)))
	box.set_corner_radius_all(int(_radius))
	draw_style_box(box, hole)


func _ring_color() -> Color:
	var base := Color(0.31, 0.66, 1.0)   # `accent` when the theme has none yet
	if has_theme_color(&"selected", PALETTE_TYPE):
		base = get_theme_color(&"selected", PALETTE_TYPE)
	if _pulse_hz <= 0.0 or not bool(_view.get("show_hint", false)):
		return base
	# §2.5's 1.2 Hz pulse: alpha only, so the colour never becomes the channel.
	var wave := 0.65 + 0.35 * (0.5 + 0.5 * sin(_pulse_t * TAU * _pulse_hz))
	return Color(base.r, base.g, base.b, wave)


## The §2.17 hint arrow, pointing from the bubble at the cutout.
func _draw_arrow(hole: Rect2) -> void:
	if _bubble == null:
		return
	var from_below := _bubble.position.y > hole.end.y
	var tip := Vector2(hole.get_center().x, hole.end.y if from_below else hole.position.y)
	var dir := 1.0 if from_below else -1.0
	var a := tip + Vector2(0.0, dir * _gap)
	var b := a + Vector2(-ARROW_DP * 0.5, dir * ARROW_DP)
	var c := a + Vector2(ARROW_DP * 0.5, dir * ARROW_DP)
	draw_colored_polygon(PackedVector2Array([a, b, c]), _ring_color())


# ---------------------------------------------------------------------------
# Handles for the tests and the flow
# ---------------------------------------------------------------------------

func skip_button() -> Button:
	return _skip


func ack_button() -> Button:
	return _ack


func autohelp_button() -> Button:
	return _help


func bubble() -> PanelContainer:
	return _bubble


func text_label() -> Label:
	return _text
