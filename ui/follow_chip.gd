class_name FollowChip
extends Control
## Doc 12 §2.6 step 6's chip: **`Following Utility 1 ✕`** (PA-58).
##
## When the player sends a unit and `follow_dispatched_unit` is on, the camera
## rides it. That is a mode, and an invisible mode is a bug — a camera that
## keeps re-centring on something the player did not ask for reads as a broken
## camera rather than as a feature. So the mode has a face, and the face is its
## own off switch: the whole chip is the target and tapping it stops following.
##
## There are three other ways out and none of them needs this chip: a PAN drops
## `CameraState._following` on touch-down (the finger always wins), the unit
## going off duty ends the follow, and so does a dispatch of a different unit.
## The chip exists for the fourth case — the player who wants their camera back
## without moving it.
##
## Placed above doc 12's left rail rather than inside it: the rail is the speed
## and overlay column and this is not a mode the player switches INTO, it is one
## they are already in. `game/ui/ui_root.tscn` does not carry it — `UIRoot`
## creates it, because a HUD element that is absent for whole sessions should
## not cost every mount a node.

## The chip was tapped: stop following.
signal dismissed

## The rail slot above the speed rail. A *fallback* only: `UIRoot.solve_follow_chip()`
## measures the rail's solved offsets and overrides this, because a hard-coded
## bottom offset that reads well at 360 × 800 lands inside the top bar at
## 880 × 400 — which is exactly what the first draft of this file did.
const FALLBACK_RAIL_SLOT := 3
const LEFT_INSET_DP := 16.0
## Wide enough for `Following Heavy Repair 12 ✕` at 100 % text, narrow enough to
## leave the right rail alone on a 360 dp phone.
const MAX_WIDTH_DP := 260.0

var config: UIConfig

var _button: Button
var _touch_min := 48.0
var _unit_name := ""


func setup(cfg: UIConfig = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_build()
	hide_chip()


func _ready() -> void:
	if config == null:
		setup(UIRoot.config_from(self))


func _build() -> void:
	if _button != null:
		return
	name = "FollowChip"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_left = LEFT_INSET_DP
	offset_right = LEFT_INSET_DP + MAX_WIDTH_DP
	UIWidgets.place_in_rail(self, FALLBACK_RAIL_SLOT, config.layout(), _touch_min)

	_button = UIWidgets.button("Chip", "", "", Vector2(_touch_min, _touch_min),
			&"StatChip")
	_button.set_anchors_preset(Control.PRESET_FULL_RECT)
	# The chip shortens rather than pushing the right rail: a unit name is a
	# label, and `Following Heavy Repai…` is still a sentence (see UIWidgets.elide).
	_button.clip_text = true
	_button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_button.pressed.connect(_on_pressed)
	add_child(_button)


## `unit_name` is already formatted — `UnitPickerModel.unit_name_for()` — so this
## file holds no naming rule of its own.
func show_for(unit_name: String) -> void:
	if _button == null:
		setup(config)
	_unit_name = unit_name
	var text := UIWidgets.t_args(config, "ui_follow_chip", {"unit": unit_name})
	_button.text = text
	_button.tooltip_text = UIWidgets.t_args(config, "ui_follow_chip_stop",
			{"unit": unit_name})
	visible = true
	_button.visible = true
	_button.mouse_filter = Control.MOUSE_FILTER_STOP


func hide_chip() -> void:
	_unit_name = ""
	visible = false
	if _button != null:
		_button.visible = false
		_button.mouse_filter = Control.MOUSE_FILTER_IGNORE


func is_shown() -> bool:
	return _button != null and _button.visible


## `UIRoot.solve_follow_chip()`'s two writes. `bottom_offset` is negative — the
## chip is bottom-anchored, like every other member of doc 12's left column.
func place(bottom_offset: float, height: float, max_width: float) -> void:
	if _button == null:
		return
	offset_bottom = bottom_offset
	offset_top = bottom_offset - maxf(height, _touch_min)
	offset_right = offset_left + maxf(_touch_min, max_width)


## Step out while something is drawn over this slot. Same ruling the tilt slider
## makes about right-edge panels (§2.23): a target under a panel is a target
## nobody can reach, and leaving it there is worse than taking it away — the
## follow is still running and the three other ways out of it (a pan, the unit
## going off duty, a second dispatch) are untouched.
func set_yielded(yielded: bool) -> void:
	if _button == null or _unit_name == "":
		return
	visible = not yielded
	_button.visible = not yielded
	_button.mouse_filter = Control.MOUSE_FILTER_IGNORE if yielded \
			else Control.MOUSE_FILTER_STOP


func unit_name() -> String:
	return _unit_name


func chip_button() -> Button:
	return _button


func _on_pressed() -> void:
	hide_chip()
	dismissed.emit()
