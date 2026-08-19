class_name OverlayRail
extends Control
## The overlay button and its sticky chip strip (doc 12 §2.5), hung on the
## `UIRoot` scaffold's `HUDLayer` directly under the speed rail.
##
## Interaction, verbatim from §2.5: tapping the button raises the strip; the
## strip stays up until an overlay is chosen or it is dismissed, so switching
## overlays while diagnosing a cascade is one tap each; the active chip is filled
## and carries a check glyph; and **long-pressing the button toggles
## `NONE ↔ last-used`** — the A/B compare that makes an overlay a diagnostic
## instead of a decoration.
##
## Dumb by construction: `OverlayModel` owns the mode list, the exclusivity, the
## enabled subset and the legend rows; this file binds them to pixels, writes
## doc 11's `sc_overlay_mode` shader global, and emits `overlay_changed` for the
## shell. An overlay whose system has not landed renders greyed with its reason
## in words (A14) rather than vanishing from the strip.

signal overlay_changed(mode: StringName, index: int)  ## → doc 11 render mode
signal overlay_refused(mode: StringName, message: String)
signal strip_toggled(open: bool)

const CHECK_GLYPH := "✓"
const OVERLAY_GLYPH := "◈"  ## §2.3's overlay button face

## Writing doc 11's global is the whole point of the rail; a test mounts the
## scene without a renderer and turns it off.
@export var applies_shader_global: bool = true

var config: UIConfig
var model: OverlayModel

var _button: Button
var _strip: PanelContainer
var _chips_box: GridContainer
var _legend_box: VBoxContainer
var _notice: Label

var _chip_buttons: Dictionary = {}   # StringName mode -> Button
var _touch_min := 48.0
var _spacing := 8.0
var _longpress_ms := 450.0
var _pressed_at_ms := -1.0
var _suppress_next_press := false


## The one wiring entry point, mirroring `BuildSheet.setup()`: `game/main.gd`
## hands over the parsed config, the headless tests hand over a fixture.
func setup(cfg: UIConfig = null, p_model: OverlayModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	model = p_model if p_model != null else OverlayModel.new(config)
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_longpress_ms = UIConfig.get_num(config.gestures(), "longpress_ms", 450.0)
	_bind_nodes()
	_build_button()
	_build_chips()
	_build_legend()
	close()
	_apply_active(false)
	set_process(true)


func _ready() -> void:
	if model == null:
		setup(UIRoot.config_from(self))


func _bind_nodes() -> void:
	_button = get_node_or_null("Button") as Button
	_strip = get_node_or_null("Strip") as PanelContainer
	_chips_box = get_node_or_null("Strip/Body/Chips") as GridContainer
	_legend_box = get_node_or_null("Strip/Body/Legend") as VBoxContainer
	_notice = get_node_or_null("Strip/Body/Notice") as Label


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build_button() -> void:
	if _button == null:
		return
	var d := maxf(UIConfig.get_num(config.layout(), "rail_button_d_dp", 56.0), _touch_min)
	_button.theme_type_variation = &"RailButton"
	_button.focus_mode = Control.FOCUS_NONE
	_button.custom_minimum_size = Vector2(d, d)
	_button.text = OVERLAY_GLYPH
	_button.tooltip_text = UIWidgets.t(config, "ui_overlay_button")  # A15
	if not _button.pressed.is_connected(_on_button_pressed):
		_button.pressed.connect(_on_button_pressed)
	if not _button.button_down.is_connected(_on_button_down):
		_button.button_down.connect(_on_button_down)
	if not _button.button_up.is_connected(_on_button_up):
		_button.button_up.connect(_on_button_up)


func _build_chips() -> void:
	if _chips_box == null:
		return
	UIWidgets.clear_children(_chips_box)
	_chip_buttons.clear()
	var overlay := config.section("overlay")
	var raw: Variant = overlay.get("strip_chip_dp", [64, 56])
	var dims: Array = raw if raw is Array and (raw as Array).size() >= 2 else [64, 56]
	var chip_size := Vector2(maxf(float(dims[0]), _touch_min),
			maxf(float(dims[1]), _touch_min))
	_chips_box.columns = maxi(1, UIConfig.get_int(overlay, "strip_columns", 2))
	_chips_box.add_theme_constant_override(&"h_separation", int(_spacing))
	_chips_box.add_theme_constant_override(&"v_separation", int(_spacing))
	for chip: Dictionary in model.chips():
		var mode: StringName = chip["id"]
		var label := UIWidgets.t(config, str(chip["label_key"]))
		var tooltip := label
		if not bool(chip["enabled"]):
			tooltip = UIWidgets.t_args(config, str(chip["disabled_reason_key"]),
					{"name": label})
		var button := UIWidgets.button("Chip_" + String(mode), label, tooltip,
				chip_size, &"TabButton")
		button.toggle_mode = true
		# Not `disabled`: a disabled Button swallows its own tooltip on touch, and
		# A14 wants the reason *said*. The chip stays tappable and answers in words.
		button.pressed.connect(_on_chip_pressed.bind(mode))
		_chips_box.add_child(button)
		_chip_buttons[mode] = button


func _build_legend() -> void:
	if _legend_box == null:
		return
	UIWidgets.clear_children(_legend_box)
	_legend_box.add_child(UIWidgets.label("Title",
			UIWidgets.t(config, "ui_overlay_legend_title"), &"LegendRow"))
	for row: Dictionary in model.legend_rows():
		var text := "%s %s" % [str(row["glyph"]),
				UIWidgets.t(config, str(row["label_key"]))]
		var line := UIWidgets.label("State_" + String(row["state"]), text.strip_edges())
		_legend_box.add_child(line)
		UIWidgets.paint_state(self, line, row["state"])
	if _notice != null:
		_notice.visible = false


# ---------------------------------------------------------------------------
# Open / close (the `UIRoot` back-stack protocol)
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _strip != null and _strip.visible


func open() -> void:
	if _strip != null:
		_strip.visible = true
	_set_notice("")
	strip_toggled.emit(true)


func close() -> void:
	if _strip != null:
		_strip.visible = false
	strip_toggled.emit(false)


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

func active_mode() -> StringName:
	return model.active() if model != null else OverlayModel.MODE_NONE


func active_index() -> int:
	return model.active_index() if model != null else 0


## Programmatic select — used by the save restore and by the onboarding
## director's `confirm_power` step. Returns the model's verdict.
func select(mode: StringName) -> Dictionary:
	var verdict := model.select(mode)
	_after_verdict(verdict, mode)
	return verdict


## §2.5's long press: `NONE ↔ last-used overlay`. Public so the gesture layer,
## the tests and the button's own hold timer all reach the same path.
func long_press() -> Dictionary:
	var verdict := model.toggle_last()
	_after_verdict(verdict, model.active())
	return verdict


func _on_chip_pressed(mode: StringName) -> void:
	var verdict := model.toggle(mode)
	_after_verdict(verdict, mode)
	# Sticky (§2.5): the strip stays up so the next overlay is one more tap.


func _after_verdict(verdict: Dictionary, mode: StringName) -> void:
	if not bool(verdict["ok"]):
		var label := UIWidgets.t(config, OverlayModel.label_key(mode))
		var message := UIWidgets.t_args(config, "ui_overlay_disabled", {"name": label})
		_set_notice(message)
		overlay_refused.emit(mode, message)
		_apply_active(false)
		return
	_set_notice("")
	_apply_active(bool(verdict["changed"]))


func _apply_active(changed: bool) -> void:
	var active := model.active()
	for chip: Dictionary in model.chips():
		var id: StringName = chip["id"]
		var button: Button = _chip_buttons.get(id, null)
		if button == null:
			continue
		var selected := id == active
		button.set_pressed_no_signal(selected)
		var label := UIWidgets.t(config, str(chip["label_key"]))
		# A5: the active chip carries a glyph, not just a fill.
		button.text = ("%s %s" % [CHECK_GLYPH, label]) if selected else label
		UIWidgets.paint_state(self, button,
				HudModel.STATE_NORMAL if selected
				else (&"" if bool(chip["enabled"]) else HudModel.STATE_OFFLINE))
	if _button != null:
		var name_text := UIWidgets.t(config, OverlayModel.label_key(active))
		_button.tooltip_text = UIWidgets.t(config, "ui_overlay_button") \
				if active == OverlayModel.MODE_NONE \
				else UIWidgets.t_args(config, "ui_overlay_active", {"name": name_text})
	if changed:
		_write_shader_global()
		overlay_changed.emit(active, model.active_index())


## Doc 11 reads the active overlay here (data/ui.json.overlay.shader_global).
## The value is the mode's index into `overlay.modes`, and this is the only
## writer in the project.
func _write_shader_global() -> void:
	if not applies_shader_global or model == null:
		return
	var global_name := StringName(model.shader_global_name())
	if not RenderingServer.global_shader_parameter_get_list().has(global_name):
		return
	RenderingServer.global_shader_parameter_set(global_name, model.active_index())


func _set_notice(text: String) -> void:
	if _notice == null:
		return
	_notice.text = text
	_notice.visible = text != ""
	UIWidgets.paint_state(self, _notice, HudModel.STATE_WARNING)


# ---------------------------------------------------------------------------
# Hold-to-A/B on the rail button
# ---------------------------------------------------------------------------

func _on_button_down() -> void:
	_pressed_at_ms = float(Time.get_ticks_msec())
	_suppress_next_press = false


func _on_button_up() -> void:
	_pressed_at_ms = -1.0


func _on_button_pressed() -> void:
	if _suppress_next_press:
		_suppress_next_press = false
		return
	toggle()


func _process(_delta: float) -> void:
	if _pressed_at_ms < 0.0 or _suppress_next_press:
		return
	if float(Time.get_ticks_msec()) - _pressed_at_ms < _longpress_ms:
		return
	_suppress_next_press = true  # the release must not also toggle the strip
	_pressed_at_ms = -1.0
	long_press()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func chip_button(mode: StringName) -> Button:
	return _chip_buttons.get(mode, null)


func rail_button() -> Button:
	return _button


func capture_state() -> Dictionary:
	return model.capture_state() if model != null else {}


func restore_state(state: Dictionary) -> void:
	if model == null:
		return
	model.restore_state(state)
	_apply_active(true)
