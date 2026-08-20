class_name PauseMenu
extends Control
## The pause menu: RESUME · SAVE · SETTINGS · SAVE & QUIT, on `ModalLayer`.
##
## Two decisions worth stating. **Opening it pauses and closing it resumes** —
## `pause_intent(bool)` is emitted rather than the sim being touched, because
## doc 01 owns `paused` and this is a view. And **QUIT is an intent, not an
## exit**: Slacum City is a single-scene game with no menu to return to, so
## quitting means "save, then close the app", which only the shell can sequence.
## This class never calls `get_tree().quit()`.
##
## The action list is data (`data/ui.json.pause_menu.actions`) and every label is
## a `data/strings.en.json` key, so the menu is one loop over that list.

signal resume_requested
signal save_requested
signal settings_requested
signal quit_requested
signal pause_intent(paused: bool)
signal menu_toggled(open: bool)

const ACTION_RESUME := &"resume"
const ACTION_SAVE := &"save"
const ACTION_SETTINGS := &"settings"
const ACTION_QUIT := &"quit"

const SCRIM_ALPHA := 0.55
const _DEFAULT_ACTIONS := ["resume", "save", "settings", "quit"]

var config: UIConfig

var _scrim: ColorRect
var _panel: PanelContainer
var _title: Label
var _buttons_box: VBoxContainer

var _scroll: ScrollContainer
var _buttons: Dictionary = {}   # StringName action -> Button
var _touch_min := 48.0
var _spacing := 8.0


func setup(cfg: UIConfig = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_bind_nodes()
	_build_static()
	_build_buttons()
	close()
	set_process(true)


func _ready() -> void:
	if config == null:
		setup(UIRoot.config_from(self))


func _bind_nodes() -> void:
	_scrim = get_node_or_null("Scrim") as ColorRect
	_panel = get_node_or_null("Panel") as PanelContainer
	_title = get_node_or_null("Panel/Body/Title") as Label
	# Both paths, because `setup()` may run twice (an injecting owner, then
	# `_ready()`) and the second pass finds the list already inside the scroller
	# `_build_static()` put it in — the same two-address bind the incident
	# drawer's sort strip makes.
	_buttons_box = get_node_or_null("Panel/Body/Scroll/Buttons") as VBoxContainer
	if _buttons_box == null:
		_buttons_box = get_node_or_null("Panel/Body/Buttons") as VBoxContainer


func _build_static() -> void:
	if _scrim != null:
		_scrim.color = UIWidgets.scrim_color(self, SCRIM_ALPHA)
	if _title != null:
		_title.text = UIWidgets.t(config, "ui_pause_title")
	if _buttons_box != null:
		_buttons_box.add_theme_constant_override(&"separation", int(_spacing))
		# Four 96 dp targets and their separations are 408 dp of card on a 400 dp
		# display: the menu grew through both edges of the viewport and `SAVE &
		# QUIT` — the one action a player cannot reach any other way — laid out at
		# y 324 … 420 (A91-D-22's family, at 880 × 400 / 130 % / larger targets).
		# The list scrolls instead, and `_apply_card_box()` caps the card.
		_scroll = UIWidgets.wrap_in_scroller(_buttons_box, "Scroll")


## The card is centre-anchored with `grow_vertical = BOTH`, so its own minimum is
## what decides its height and a minimum bigger than the display overflows in
## both directions. This solves the height the display can actually show: the
## content's wish, capped, applied as the anchored box.
func _apply_card_box() -> void:
	if _panel == null or size.y <= 1.0:
		return
	var content := 0.0
	if _title != null:
		content += _title.get_combined_minimum_size().y + _spacing
	if _buttons_box != null:
		content += _buttons_box.get_combined_minimum_size().y
	# The panel's own padding, which its stylebox owns and only it knows.
	var box := _panel.get_theme_stylebox(&"panel")
	if box != null:
		content += box.content_margin_top + box.content_margin_bottom
	var height := UIWidgets.card_height(size.y, content, _spacing, _touch_min)
	_panel.offset_top = -height * 0.5
	_panel.offset_bottom = height * 0.5


## Cheap and idempotent: the pause menu is the one screen that can be opened at
## any window size and never re-laid out afterwards, and a rotation while it is
## up is exactly when the card would overflow.
func _process(_delta: float) -> void:
	if is_open():
		_apply_card_box()


func _build_buttons() -> void:
	if _buttons_box == null:
		return
	UIWidgets.clear_children(_buttons_box)
	_buttons.clear()
	var menu := config.section("pause_menu")
	var raw: Variant = menu.get("actions", _DEFAULT_ACTIONS)
	var actions: Array = raw if raw is Array else _DEFAULT_ACTIONS
	var width := maxf(UIConfig.get_num(menu, "button_w_dp", 220.0), _touch_min)
	for value: Variant in actions:
		var action := StringName(str(value))
		var text := UIWidgets.t(config, "ui_pause_%s" % String(action))
		var tooltip := text
		if action == ACTION_QUIT:
			tooltip = UIWidgets.t(config, "ui_pause_quit_confirm")
		var button := UIWidgets.button("Action_" + String(action), text, tooltip,
				Vector2(width, _touch_min),
				&"PrimaryFAB" if action == ACTION_RESUME else &"GhostButton")
		button.pressed.connect(_on_action.bind(action))
		_buttons_box.add_child(button)
		_buttons[action] = button


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

func _on_action(action: StringName) -> void:
	match action:
		ACTION_RESUME:
			close()
			resume_requested.emit()
		ACTION_SAVE:
			save_requested.emit()
		ACTION_SETTINGS:
			settings_requested.emit()
		ACTION_QUIT:
			# The shell saves and then closes; the menu stays up behind that so a
			# failed save never leaves the player staring at a dead screen.
			quit_requested.emit()


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _panel != null and _panel.visible


func open() -> void:
	UIWidgets.close_siblings(self)
	_set_visible(true)
	_apply_card_box()
	menu_toggled.emit(true)
	pause_intent.emit(true)


func close() -> void:
	var was_open := is_open()
	_set_visible(false)
	menu_toggled.emit(false)
	if was_open:
		pause_intent.emit(false)


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


func _set_visible(value: bool) -> void:
	if _panel != null:
		_panel.visible = value
	if _scrim != null:
		_scrim.visible = value
		_scrim.mouse_filter = Control.MOUSE_FILTER_STOP if value \
				else Control.MOUSE_FILTER_IGNORE


func action_button(action: StringName) -> Button:
	return _buttons.get(action, null)
