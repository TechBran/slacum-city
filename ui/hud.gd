class_name CityHUD
extends Control
## S1's persistent HUD (doc 12 §2.3): the top-bar stat chips, the clock chip,
## the pause/1×/2×/3× speed rail and the alert banner stack, hung on the
## `UIRoot` scaffold's `HUDLayer`.
##
## This file is deliberately dumb (constitution §3, doc 12 §1). Every number,
## threshold, format, collapse decision and alert budget comes from `HudModel`;
## nothing here computes anything the headless tests could not otherwise reach.
## Widgets are built in code rather than authored in the `.tscn` so that widths
## and touch minimums come from `data/ui.json` at runtime and no `theme_override`
## ever enters a scene file (doc 12 test 19).
##
## Copy: every label resolves through `data/strings.en.json` first
## (`UIConfig.t`); the `HudModel` fallback tables are used only for the HUD keys
## that file does not carry yet, so nothing here is authored copy.

signal chip_activated(chip_id: StringName)     ## → S8 dashboard, scrolled to it
signal clock_activated                          ## → weather/forecast surface
signal speed_selected(multiplier: int)          ## → `set_speed` (doc 01)
signal pause_toggled(paused: bool)              ## → `set_paused` (doc 01)
signal alert_activated(alert_id: String)        ## banner tap → jump + select

const PALETTE_TYPE := "Palette"
const REFERENCE_WIDTH_DP := 880.0
const ALERT_REFRESH_S := 0.2

var config: UIConfig
var model: HudModel

var _chips_box: HBoxContainer
var _clock_chip: Button
var _speed_button: Button
var _speed_options_box: VBoxContainer
var _alert_stack: VBoxContainer

var _chips: Dictionary = {}          # chip id -> Button
var _speed_buttons: Dictionary = {}  # option id -> Button
var _alert_rows: Array[Dictionary] = []

var _speed := 1
var _paused := false
var _rail_expanded := false
var _reduce_motion := false
var _touch_min := 48.0
var _pulse_hz := 1.2
var _pulse_phase := 0.0
var _alert_timer := 0.0
var _last_snapshot: Dictionary = {}


## Builds every widget from `data/ui.json`. `_ready()` calls it; callers may call
## it earlier to inject an already-parsed config (child `_ready()` runs before
## `UIRoot._ready()`, so the HUD cannot rely on the root having loaded one), and
## the headless tests call it to exercise the binding without a live tree.
func setup(cfg: UIConfig = null, hud_model: HudModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	if hud_model != null:
		model = hud_model
	if model == null:
		model = HudModel.new(config)
	var defaults := config.section("defaults")
	_reduce_motion = bool(defaults.get("reduce_motion", false))
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	var pulse := config.section("state_pulse_hz")
	_pulse_hz = UIConfig.get_num(pulse, "critical", 1.2)
	_bind_nodes()
	_rebuild()
	set_process(true)


func _ready() -> void:
	if model == null:
		setup()


## Immediate rather than deferred: `setup()` may be called twice (once by an
## injecting owner, once by `_ready()`) and a queued free would leave the old
## widgets in place for a frame, colliding with the rebuilt ones.
static func _clear_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.free()


func _bind_nodes() -> void:
	_chips_box = get_node_or_null("TopBar/Chips") as HBoxContainer
	_clock_chip = get_node_or_null("TopBar/ClockChip") as Button
	_speed_button = get_node_or_null("LeftRail/SpeedButton") as Button
	_speed_options_box = get_node_or_null("LeftRail/SpeedOptions") as VBoxContainer
	_alert_stack = get_node_or_null("AlertStack") as VBoxContainer


func _rebuild() -> void:
	_build_chips()
	_build_clock()
	_build_speed_rail()
	_build_alert_rows()
	if not _last_snapshot.is_empty():
		refresh(_last_snapshot)


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build_chips() -> void:
	if _chips_box == null:
		return
	_clear_children(_chips_box)
	_chips.clear()
	for chip_id: String in model.chip_order():
		var button := Button.new()
		button.name = "Chip_" + chip_id
		button.theme_type_variation = &"StatChip"
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(
				model.chip_width_dp(chip_id, HudModel.MODE_FULL), _touch_min)
		button.clip_text = true
		button.tooltip_text = _chip_label(chip_id)  # A15 accessibility name
		button.pressed.connect(_on_chip_pressed.bind(StringName(chip_id)))
		_chips_box.add_child(button)
		_chips[chip_id] = button


func _build_clock() -> void:
	if _clock_chip == null:
		return
	_clock_chip.theme_type_variation = &"StatChip"
	_clock_chip.focus_mode = Control.FOCUS_NONE
	_clock_chip.custom_minimum_size = Vector2(
			UIConfig.get_num(config.layout(), "clock_chip_w_dp", 132.0), _touch_min)
	_clock_chip.tooltip_text = _text("ui_hud_clock", "City clock")
	if not _clock_chip.pressed.is_connected(_on_clock_pressed):
		_clock_chip.pressed.connect(_on_clock_pressed)


func _build_speed_rail() -> void:
	if _speed_button == null or _speed_options_box == null:
		return
	var rail_d := UIConfig.get_num(config.layout(), "rail_button_d_dp", 56.0)
	var button_size := Vector2(maxf(rail_d, _touch_min), maxf(rail_d, _touch_min))
	_speed_button.theme_type_variation = &"RailButton"
	_speed_button.focus_mode = Control.FOCUS_NONE
	_speed_button.custom_minimum_size = button_size
	_speed_button.tooltip_text = _text("ui_hud_speed", "Game speed")
	if not _speed_button.pressed.is_connected(_on_speed_button_pressed):
		_speed_button.pressed.connect(_on_speed_button_pressed)

	_clear_children(_speed_options_box)
	_speed_buttons.clear()
	# A10: the rail raises on one tap and any of the four targets is the second.
	for option: Dictionary in (model.speed_view(_speed, _paused)["options"] as Array):
		var id: StringName = option["id"]
		var button := Button.new()
		button.name = "Speed_" + String(id)
		button.theme_type_variation = &"RailButton"
		button.focus_mode = Control.FOCUS_NONE
		button.toggle_mode = true
		button.custom_minimum_size = button_size
		button.text = str(option["text"])
		button.tooltip_text = _text("ui_hud_speed_%s" % String(id), str(option["text"]))
		button.pressed.connect(_on_speed_option_pressed.bind(id))
		_speed_options_box.add_child(button)
		_speed_buttons[id] = button
	_speed_options_box.visible = _rail_expanded


func _build_alert_rows() -> void:
	if _alert_stack == null:
		return
	_clear_children(_alert_stack)
	_alert_rows.clear()
	var layout := config.layout()
	var raw: Variant = layout.get("alert_dp", [400, 44])
	var alert_dp: Array = raw if raw is Array and (raw as Array).size() >= 2 else [400, 44]
	var max_stack := UIConfig.get_int(layout, "alert_max_stack", 2)
	for i in max_stack:
		var panel := PanelContainer.new()
		panel.name = "Alert%d" % i
		panel.theme_type_variation = &"AlertBanner"
		# A3 wins over the doc's 44 dp banner height: the row carries a tap target.
		panel.custom_minimum_size = Vector2(float(alert_dp[0]),
				maxf(float(alert_dp[1]), _touch_min))
		panel.visible = false
		var row := HBoxContainer.new()
		row.name = "Row"
		panel.add_child(row)
		var badge := Label.new()
		badge.name = "Badge"
		badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(badge)
		var title := Label.new()
		title.name = "Title"
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		title.clip_text = true
		row.add_child(title)
		var view := Button.new()
		view.name = "View"
		view.theme_type_variation = &"GhostButton"
		view.focus_mode = Control.FOCUS_NONE
		view.custom_minimum_size = Vector2(_touch_min, _touch_min)
		view.text = _text("ui_hud_alert_view", "VIEW")
		view.tooltip_text = view.text
		row.add_child(view)
		_alert_stack.add_child(panel)
		_alert_rows.append({"panel": panel, "badge": badge, "title": title,
				"view": view, "alert_id": ""})
		view.pressed.connect(_on_alert_pressed.bind(i))


# ---------------------------------------------------------------------------
# Binding
# ---------------------------------------------------------------------------

## The one entry point `game/main.gd` calls. `snapshot` is plain data — see
## `HudModel.build_view()` for the key list; the HUD never holds a sim reference.
func refresh(snapshot: Dictionary) -> void:
	_last_snapshot = snapshot
	if model == null:
		return
	_speed = int(snapshot.get("speed", _speed))
	_paused = bool(snapshot.get("paused", _paused))
	var view := model.build_view(snapshot, _width_dp())
	_apply_chips(view["chips"])
	_apply_clock(view["clock"])
	_apply_speed(view["speed"])
	_render_alerts(_now_s())


func _width_dp() -> float:
	var w := size.x
	if w <= 1.0:
		var parent := get_parent() as Control
		w = parent.size.x if parent != null else 0.0
	return w if w > 1.0 else REFERENCE_WIDTH_DP


func _apply_chips(chips: Array) -> void:
	for entry: Variant in chips:
		var chip: Dictionary = entry
		var button: Button = _chips.get(str(chip["id"]), null)
		if button == null:
			continue
		var mode: StringName = chip["mode"]
		button.visible = mode != HudModel.MODE_HIDDEN
		if not button.visible:
			continue
		button.custom_minimum_size = Vector2(float(chip["width_dp"]), _touch_min)
		button.text = _chip_text(chip)
		button.set_meta("state", chip["state"])
		button.set_meta("pulse", bool(chip.get("pulse", false)))
		_apply_state_color(button, chip["state"])


func _chip_text(chip: Dictionary) -> String:
	var parts: PackedStringArray = []
	var glyph := str(chip["glyph"])
	if glyph != "":
		parts.append(glyph)
	parts.append(str(chip["text"]))
	# A5: colour is never load-bearing, so a non-NORMAL chip also carries the
	# state glyph. NORMAL stays clean — the §2.3 mock has no glyph on a good chip.
	var state_glyph := str(chip["state_glyph"])
	if state_glyph != "" and chip["state"] != HudModel.STATE_NORMAL:
		parts.append(state_glyph)
	if str(chip["id"]) == "incidents" and int(chip.get("badge_tier", 0)) > 0:
		parts.append("T%d" % int(chip["badge_tier"]))
	return " ".join(parts)


func _apply_clock(clock: Dictionary) -> void:
	if _clock_chip == null:
		return
	var glyph := str(clock.get("weather_glyph", ""))
	_clock_chip.text = ("%s %s" % [glyph, clock["time"]]).strip_edges() \
			if glyph != "" else str(clock["time"])
	_clock_chip.tooltip_text = _text("ui_hud_day", str(clock["day"]))


func _apply_speed(view: Dictionary) -> void:
	if _speed_button != null:
		_speed_button.text = str(view["face"])
	for option: Variant in (view["options"] as Array):
		var entry: Dictionary = option
		var button: Button = _speed_buttons.get(entry["id"], null)
		if button == null:
			continue
		button.set_pressed_no_signal(bool(entry["selected"]))
		_apply_state_color(button, HudModel.STATE_NORMAL if bool(entry["selected"]) else &"")
	if _speed_options_box != null:
		_speed_options_box.visible = _rail_expanded


func _render_alerts(now_s: float) -> void:
	if _alert_stack == null or model == null:
		return
	var alerts := model.active_alerts(now_s)
	for i in _alert_rows.size():
		var row: Dictionary = _alert_rows[i]
		var panel: PanelContainer = row["panel"]
		if i >= alerts.size():
			panel.visible = false
			row["alert_id"] = ""
			continue
		var alert: Dictionary = alerts[i]
		panel.visible = true
		row["alert_id"] = str(alert["id"])
		var count := int(alert["count"])
		(row["badge"] as Label).text = String(alert["class"]).to_upper()
		var title := str(alert["title"])
		(row["title"] as Label).text = title if count <= 1 else "%s (%d)" % [title, count]
		_apply_state_color(row["badge"] as Label,
				HudModel.STATE_CRITICAL if str(alert["class"]) == "p1"
				else HudModel.STATE_WARNING)


## Raise an in-app alert through the §2.13 gate. Returns the gate's verdict —
## `{delivered, surface, coalesced, reason, id, count}`; a refused banner has
## already been turned into a toast by the model.
func push_alert(alert: Dictionary, now_s: float = -1.0) -> Dictionary:
	if model == null:
		return {}
	var stamp := now_s if now_s >= 0.0 else _now_s()
	var verdict := model.submit_alert(stamp, alert)
	_render_alerts(stamp)  # the same clock, or the new banner prunes on arrival
	return verdict


func _process(delta: float) -> void:
	_alert_timer += delta
	if _alert_timer >= ALERT_REFRESH_S:
		_alert_timer = 0.0
		_render_alerts(_now_s())
	if _reduce_motion:  # A8: pulses are motion
		return
	_pulse_phase = fmod(_pulse_phase + delta * _pulse_hz, 1.0)
	var alpha := 0.65 + 0.35 * (0.5 + 0.5 * cos(TAU * _pulse_phase))
	for chip_id: Variant in _chips:
		var button: Button = _chips[chip_id]
		if not button.visible:
			continue
		button.modulate.a = alpha if bool(button.get_meta("pulse", false)) else 1.0


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _on_chip_pressed(chip_id: StringName) -> void:
	chip_activated.emit(chip_id)


func _on_clock_pressed() -> void:
	clock_activated.emit()


func _on_speed_button_pressed() -> void:
	_rail_expanded = not _rail_expanded
	if _speed_options_box != null:
		_speed_options_box.visible = _rail_expanded


func _on_speed_option_pressed(option: StringName) -> void:
	var next := model.apply_speed_option(option, _speed, _paused)
	var was_paused := _paused
	_speed = int(next["speed"])
	_paused = bool(next["paused"])
	_rail_expanded = false
	_apply_speed(model.speed_view(_speed, _paused))
	if _paused != was_paused:
		pause_toggled.emit(_paused)
	if option != HudModel.SPEED_PAUSE:
		speed_selected.emit(_speed)


func _on_alert_pressed(row_index: int) -> void:
	if row_index >= _alert_rows.size():
		return
	var alert_id := str((_alert_rows[row_index] as Dictionary)["alert_id"])
	if alert_id == "":
		return
	model.dismiss_alert(alert_id)
	_render_alerts(_now_s())
	alert_activated.emit(alert_id)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func is_speed_rail_expanded() -> bool:
	return _rail_expanded


func chip_button(chip_id: String) -> Button:
	return _chips.get(chip_id, null)


func speed_option_button(option: StringName) -> Button:
	return _speed_buttons.get(option, null)


func _chip_label(chip_id: String) -> String:
	return _text(HudModel.chip_label_key(chip_id),
			str(HudModel.CHIP_LABELS.get(chip_id, chip_id)))


## `data/strings.en.json` first (G-8); the fallback covers the HUD keys that
## table does not carry yet and never overrides one that it does.
func _text(key: String, fallback: String) -> String:
	if config != null and config.has_string(key):
		return config.t(key)
	return fallback


func _apply_state_color(control: Control, state: StringName) -> void:
	if state == &"" or not has_theme_color(state, PALETTE_TYPE):
		control.remove_theme_color_override(&"font_color")
		return
	control.add_theme_color_override(&"font_color", get_theme_color(state, PALETTE_TYPE))


static func _now_s() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
