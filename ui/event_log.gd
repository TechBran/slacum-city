class_name EventLog
extends Control
## The event log (doc 12 S13): a chip on the HUD and a scrollable sheet of
## everything the city has done, filtered by category and dated in words.
##
## Same shape as `AlertsCenter` — a persistent chip plus a panel that is not —
## so the two live side by side on `PanelLayer`, `UIWidgets.close_siblings`
## keeps exactly one of them up, and `is_open()` / `close()` are the `UIRoot`
## back-stack protocol so Android BACK closes the sheet without touching the
## chip.
##
## Every value comes from `EventLogModel`: the copy (resolved from the same
## `n_*` keys doc 13 renders for a push, G-8), the categories, the relative
## ages and the focus payload. This file decides nothing except which pixels
## those become. Tapping a row emits `focus_requested(world_pos)` — the shell
## moves the camera; the UI never touches `CameraState` from here — and unlike
## an alert it changes nothing about the row, because reading history does not
## consume it.

signal focus_requested(world_pos: Vector3)          ## row tap → camera jump
signal entry_activated(log_id: String)              ## row tap, focus or not
signal filter_changed(category: StringName)
signal panel_toggled(open: bool)

const CHIP_GLYPH := "≡"
const CHECK_GLYPH := "✓"

var config: UIConfig
var model: EventLogModel

var _chip: Button
var _panel: PanelContainer
var _title: Label
var _close: Button
var _empty: Label
var _filters: HBoxContainer
var _list: VBoxContainer

var _rows: Dictionary = {}        # log id -> Button
var _chip_buttons: Dictionary = {}  # StringName category -> Button
var _touch_min := 48.0
var _spacing := 8.0
var _row_h := 72.0


func setup(cfg: UIConfig = null, p_model: EventLogModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	model = p_model if p_model != null else EventLogModel.new(config)
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_row_h = maxf(UIConfig.get_num(config.section("event_log"), "row_h_dp", 72.0),
			_touch_min)
	_bind_nodes()
	_build_static()
	_build_filters()
	close()
	refresh()


func _ready() -> void:
	if model == null:
		setup(UIRoot.config_from(self))


## Same corner discipline as AlertsCenter (doc 91 D-12): the chip yields to any
## other PanelLayer surface so two edge affordances never overlap.
func _process(_delta: float) -> void:
	if _chip == null or is_open():
		return
	_chip.visible = not UIWidgets.any_sibling_open(self)


func _bind_nodes() -> void:
	_chip = get_node_or_null("Chip") as Button
	_panel = get_node_or_null("Panel") as PanelContainer
	_title = get_node_or_null("Panel/Body/Header/Title") as Label
	_close = get_node_or_null("Panel/Body/Header/Close") as Button
	# The chip strip scrolls horizontally: six 48 dp targets do not fit a 320 dp
	# side panel on a phone, and shrinking them below 48 is not an option (A3).
	_filters = get_node_or_null("Panel/Body/FilterScroll/Filters") as HBoxContainer
	_empty = get_node_or_null("Panel/Body/Empty") as Label
	_list = get_node_or_null("Panel/Body/Scroll/List") as VBoxContainer


func _build_static() -> void:
	var block := config.section("event_log")
	if _chip != null:
		_chip.theme_type_variation = &"StatChip"
		_chip.focus_mode = Control.FOCUS_NONE
		_chip.custom_minimum_size = Vector2(
				maxf(UIConfig.get_num(block, "chip_w_dp", 72.0), _touch_min), _touch_min)
		_chip.text = CHIP_GLYPH
		_chip.tooltip_text = UIWidgets.t(config, "ui_event_log_chip")  # A15
		if not _chip.pressed.is_connected(toggle):
			_chip.pressed.connect(toggle)
	if _panel != null:
		_panel.custom_minimum_size = Vector2(
				UIConfig.get_num(block, "panel_w_dp", 320.0), 0.0)
	if _title != null:
		_title.text = UIWidgets.t(config, "ui_event_log_title")
	if _close != null:
		_close.theme_type_variation = &"GhostButton"
		_close.focus_mode = Control.FOCUS_NONE
		_close.custom_minimum_size = Vector2(_touch_min, _touch_min)
		_close.text = "✕"
		_close.tooltip_text = UIWidgets.t(config, "ui_event_log_close")
		if not _close.pressed.is_connected(close):
			_close.pressed.connect(close)
	if _empty != null:
		_empty.text = UIWidgets.t(config, "ui_event_log_empty")
	if _list != null:
		_list.add_theme_constant_override(&"separation", int(_spacing))
	if _filters != null:
		_filters.add_theme_constant_override(&"separation", int(_spacing))


## One chip per category, built once. The counts change every drain; the
## buttons do not, so a filter tap never rebuilds the strip it lives in.
func _build_filters() -> void:
	if _filters == null:
		return
	UIWidgets.clear_children(_filters)
	_chip_buttons.clear()
	var height := maxf(UIConfig.get_num(config.section("event_log"), "chip_h_dp", 48.0),
			_touch_min)
	for chip: Dictionary in model.chips():
		var category: StringName = chip["id"]
		var label := UIWidgets.t(config, str(chip["label_key"]))
		var button := UIWidgets.button("Filter_" + String(category), label,
				UIWidgets.t_args(config, "ui_event_log_filter", {"name": label}),
				Vector2(maxf(_touch_min, height * 1.6), height), &"TabButton")
		button.toggle_mode = true
		# `UIWidgets.button` clips by default, which is right for a fixed rail
		# and wrong here: the strip scrolls, so width is free, and a chip that
		# says `Incide` is a chip nobody can read. The 48 dp floor is untouched.
		button.clip_text = false
		button.pressed.connect(_on_filter_pressed.bind(category))
		_filters.add_child(button)
		_chip_buttons[category] = button


# ---------------------------------------------------------------------------
# Ingest — the shell pipes the sim bus straight in, same call as the alerts feed
# ---------------------------------------------------------------------------

func feed(event: Dictionary) -> Dictionary:
	var entry := model.feed(event)
	if not entry.is_empty():
		refresh()
	return entry


## A whole `SimEventBus.drain()` batch, refreshing once at the end rather than
## once per event — a storm drains dozens in one tick.
func feed_batch(events: Array) -> Array[Dictionary]:
	var made := model.feed_batch(events)
	if not made.is_empty():
		refresh()
	return made


func set_clock(minute_of_day: int, day_index: int = 0) -> void:
	model.set_clock(minute_of_day, day_index)


func set_locator(locator: Callable) -> void:
	model.set_locator(locator)


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _panel != null and _panel.visible


func open() -> void:
	UIWidgets.close_siblings(self)  # one panel at a time on PanelLayer
	if _panel != null:
		_panel.visible = true
	refresh()
	panel_toggled.emit(true)


func close() -> void:
	if _panel != null:
		_panel.visible = false
	panel_toggled.emit(false)


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func refresh() -> void:
	_refresh_chip()
	if not is_open():
		return
	_refresh_filters()
	_refresh_list()


func _refresh_chip() -> void:
	if _chip == null:
		return
	var total := model.size()
	_chip.tooltip_text = UIWidgets.t(config, "ui_event_log_chip") if total <= 0 \
			else UIWidgets.t_args(config, "ui_event_log_count", {"n": total})


func _refresh_filters() -> void:
	for chip: Dictionary in model.chips():
		var button: Button = _chip_buttons.get(chip["id"], null)
		if button == null:
			continue
		var selected := bool(chip["selected"])
		button.set_pressed_no_signal(selected)
		var label := UIWidgets.t(config, str(chip["label_key"]))
		# A5: the live filter carries a glyph, not just a fill; an empty
		# category says so with its count rather than by looking identical.
		var count := int(chip["count"])
		var text := "%s %d" % [label, count] if count > 0 else label
		button.text = ("%s %s" % [CHECK_GLYPH, text]) if selected else text
		UIWidgets.paint_state(self, button,
				HudModel.STATE_NORMAL if selected
				else (&"" if count > 0 else HudModel.STATE_OFFLINE))


func _refresh_list() -> void:
	if _list == null:
		return
	UIWidgets.clear_children(_list)
	_rows.clear()
	var entries := model.entries()
	if _empty != null:
		_empty.visible = entries.is_empty()
	for entry: Dictionary in entries:
		var button := _build_row(entry)
		_list.add_child(button)
		_rows[str(entry["id"])] = button


## The whole row is the tap target (A3/A4); its children never take the touch,
## so there is exactly one thing to hit per line.
func _build_row(entry: Dictionary) -> Button:
	var title := str(entry["title"])
	var tooltip := title if title != "" else str(entry["event_type"])
	if bool(entry["has_focus"]):
		tooltip = "%s — %s" % [tooltip, UIWidgets.t(config, "ui_event_log_focus")]
	var button := UIWidgets.button("Log_" + str(entry["id"]), "", tooltip,
			Vector2(_touch_min, _row_h), &"DrawerRow")
	button.pressed.connect(_on_row_pressed.bind(str(entry["id"])))

	var body := VBoxContainer.new()
	body.name = "Body"
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	button.add_child(body)

	# A5: the state colour is never alone — the glyph carries it in greyscale.
	var head := UIWidgets.label("Title",
			("%s %s" % [str(entry["glyph"]), title]).strip_edges())
	body.add_child(head)
	UIWidgets.paint_state(self, head, entry["state"])

	var body_text := str(entry["body"])
	if body_text != "":
		body.add_child(UIWidgets.label("Body", body_text, &"", true))
	# Relative, not absolute: "12 min ago" is what a player asks, and the model
	# owns the thresholds and the copy.
	body.add_child(UIWidgets.label("Age", str(entry["age_text"])))
	return button


func _on_row_pressed(log_id: String) -> void:
	var payload := model.focus_payload(log_id)
	entry_activated.emit(log_id)
	if payload.is_empty() or not bool(payload["has_focus"]):
		return
	focus_requested.emit(payload["world_pos"] as Vector3)


func _on_filter_pressed(category: StringName) -> void:
	var applied := model.set_filter(category)
	_refresh_filters()
	_refresh_list()
	filter_changed.emit(applied)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func chip_button() -> Button:
	return _chip


func filter_button(category: StringName) -> Button:
	return _chip_buttons.get(category, null)


func row_button(log_id: String) -> Button:
	return _rows.get(log_id, null)


func count() -> int:
	return model.size() if model != null else 0
