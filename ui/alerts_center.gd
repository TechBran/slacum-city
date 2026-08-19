class_name AlertsCenter
extends Control
## The alerts centre (doc 12 §2.15): a chip that carries the unread count and an
## expandable feed of everything the city has told the player, each row tapping
## through to the thing it is about.
##
## The chip is persistent and the list is not, so this screen owns both — the
## same shape as `BuildSheet` owning the FAB and the sheet. `is_open()` /
## `close()` are the `UIRoot` back-stack protocol, so Android BACK closes the
## list without touching the chip.
##
## Every value comes from `AlertsModel`: the copy (resolved from the `n_*` keys
## doc 13 also renders for a push, G-8), the coalesced counts, the unread
## bookkeeping and the focus payload. This file decides nothing except which
## pixels those become. Tapping a row marks it read and emits
## `focus_requested(world_pos)` — the shell moves the camera; the UI never
## touches `CameraState` from here.

signal focus_requested(world_pos: Vector3)          ## row tap → camera jump
signal alert_activated(alert_id: String)            ## row tap, focus or not
signal unread_changed(count: int)
signal panel_toggled(open: bool)

const CHIP_GLYPH := "⚠"

var config: UIConfig
var model: AlertsModel

var _chip: Button
var _panel: PanelContainer
var _title: Label
var _mark_all: Button
var _close: Button
var _empty: Label
var _list: VBoxContainer

var _rows: Dictionary = {}       # alert id -> Button
var _row_titles: Dictionary = {} # alert id -> Label (repainted in place on read)
var _touch_min := 48.0
var _spacing := 8.0
var _row_h := 72.0
var _last_unread := -1


func setup(cfg: UIConfig = null, p_model: AlertsModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	model = p_model if p_model != null else AlertsModel.new(config)
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_row_h = maxf(UIConfig.get_num(config.section("alerts"), "row_h_dp", 72.0), _touch_min)
	_bind_nodes()
	_build_static()
	close()
	refresh()


func _ready() -> void:
	if model == null:
		setup(UIRoot.config_from(self))


func _bind_nodes() -> void:
	_chip = get_node_or_null("Chip") as Button
	_panel = get_node_or_null("Panel") as PanelContainer
	_title = get_node_or_null("Panel/Body/Header/Title") as Label
	_mark_all = get_node_or_null("Panel/Body/Header/MarkAll") as Button
	_close = get_node_or_null("Panel/Body/Header/Close") as Button
	_empty = get_node_or_null("Panel/Body/Empty") as Label
	_list = get_node_or_null("Panel/Body/Scroll/List") as VBoxContainer


func _build_static() -> void:
	var alerts := config.section("alerts")
	if _chip != null:
		_chip.theme_type_variation = &"StatChip"
		_chip.focus_mode = Control.FOCUS_NONE
		_chip.custom_minimum_size = Vector2(
				maxf(UIConfig.get_num(alerts, "chip_w_dp", 72.0), _touch_min), _touch_min)
		_chip.tooltip_text = UIWidgets.t(config, "ui_alerts_chip")  # A15
		if not _chip.pressed.is_connected(toggle):
			_chip.pressed.connect(toggle)
	if _panel != null:
		_panel.custom_minimum_size = Vector2(
				UIConfig.get_num(alerts, "panel_w_dp", 300.0), 0.0)
	if _title != null:
		_title.text = UIWidgets.t(config, "ui_alerts_title")
	if _mark_all != null:
		_mark_all.theme_type_variation = &"GhostButton"
		_mark_all.focus_mode = Control.FOCUS_NONE
		_mark_all.custom_minimum_size = Vector2(_touch_min * 2.0, _touch_min)
		_mark_all.text = UIWidgets.t(config, "ui_alerts_mark_read")
		_mark_all.tooltip_text = _mark_all.text
		if not _mark_all.pressed.is_connected(mark_all_read):
			_mark_all.pressed.connect(mark_all_read)
	if _close != null:
		_close.theme_type_variation = &"GhostButton"
		_close.focus_mode = Control.FOCUS_NONE
		_close.custom_minimum_size = Vector2(_touch_min, _touch_min)
		_close.text = "✕"
		_close.tooltip_text = UIWidgets.t(config, "ui_alerts_close")
		if not _close.pressed.is_connected(close):
			_close.pressed.connect(close)
	if _empty != null:
		_empty.text = UIWidgets.t(config, "ui_alerts_empty")
	if _list != null:
		_list.add_theme_constant_override(&"separation", int(_spacing))


# ---------------------------------------------------------------------------
# Ingest — the shell pipes the sim bus straight in
# ---------------------------------------------------------------------------

## One event. Returns the model's row (or `{}` when the event is not notifiable).
func feed(event: Dictionary) -> Dictionary:
	var entry := model.feed(event)
	if not entry.is_empty():
		refresh()
	return entry


## A whole `SimEventBus.drain()` batch, refreshing once at the end rather than
## once per event — a blackout drains dozens in one tick.
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
	_refresh_list()


func _refresh_chip() -> void:
	if _chip == null:
		return
	var badge := model.badge_text()
	_chip.text = ("%s %s" % [CHIP_GLYPH, badge]).strip_edges() if badge != "" else CHIP_GLYPH
	var count := model.unread_count()
	_chip.tooltip_text = UIWidgets.t(config, "ui_alerts_chip") if count <= 0 \
			else UIWidgets.t_args(config, "ui_alerts_unread", {"n": count})
	UIWidgets.paint_state(self, _chip, _worst_unread_state())
	if count != _last_unread:
		_last_unread = count
		unread_changed.emit(count)


## The chip inherits the worst state among unread rows, so a P1 outage colours it
## CRITICAL while a finished building leaves it plain (A5: the glyph and the
## number carry the same information without the colour).
func _worst_unread_state() -> StringName:
	var worst := &""
	for entry: Dictionary in model.entries():
		if bool(entry["read"]):
			continue
		var state: StringName = entry["state"]
		if state == HudModel.STATE_CRITICAL:
			return state
		if state == HudModel.STATE_WARNING:
			worst = state
	return worst


func _refresh_list() -> void:
	if _list == null:
		return
	UIWidgets.clear_children(_list)
	_rows.clear()
	_row_titles.clear()
	var entries := model.entries()
	if _empty != null:
		_empty.visible = entries.is_empty()
	for entry: Dictionary in entries:
		var button := _build_row(entry)
		_list.add_child(button)
		_rows[str(entry["id"])] = button
	_repaint_rows()


## Read/unread styling only, applied in place. Tapping a row must never rebuild
## the list it lives in — freeing a Button while it is emitting `pressed` is an
## engine error, and the row the player just hit is exactly that Button.
func _repaint_rows() -> void:
	if _mark_all != null:
		_mark_all.visible = model.unread_count() > 0
	for entry: Dictionary in model.entries():
		var title: Label = _row_titles.get(str(entry["id"]), null)
		if title == null:
			continue
		UIWidgets.paint_state(self, title,
				entry["state"] if not bool(entry["read"]) else HudModel.STATE_OFFLINE)


## The whole 72 dp row is the tap target (A3/A4); its children never take the
## touch, so there is exactly one thing to hit per alert.
func _build_row(entry: Dictionary) -> Button:
	var title := str(entry["title"])
	var count := int(entry["count"])
	if count > 1:
		title = "%s %s" % [title, UIWidgets.t_args(config, "ui_alerts_repeat", {"n": count})]
	var tooltip := title
	if bool(entry["has_focus"]):
		tooltip = "%s — %s" % [title, UIWidgets.t(config, "ui_alerts_focus")]
	var button := UIWidgets.button("Alert_" + str(entry["id"]), "", tooltip,
			Vector2(_touch_min, _row_h), &"DrawerRow")
	button.pressed.connect(_on_row_pressed.bind(str(entry["id"])))

	var body := VBoxContainer.new()
	body.name = "Body"
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	button.add_child(body)

	# A5 again: an unread row keeps its state colour, a read one goes OFFLINE
	# grey, and both carry the glyph, so the list survives greyscale.
	var head := UIWidgets.label("Title",
			("%s %s" % [str(entry["glyph"]), title]).strip_edges())
	body.add_child(head)
	_row_titles[str(entry["id"])] = head

	var body_text := str(entry["body"])
	if body_text != "":
		body.add_child(UIWidgets.label("Body", body_text, &"", true))
	body.add_child(UIWidgets.label("Time",
			HudModel.clock_hhmm(int(entry["at_minute"]))))
	return button


func _on_row_pressed(alert_id: String) -> void:
	var payload := model.focus_payload(alert_id)
	_refresh_chip()
	_repaint_rows()
	alert_activated.emit(alert_id)
	if payload.is_empty() or not bool(payload["has_focus"]):
		return
	focus_requested.emit(payload["world_pos"] as Vector3)


func mark_all_read() -> void:
	if model.mark_all_read() <= 0:
		return
	_refresh_chip()
	_repaint_rows()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func chip_button() -> Button:
	return _chip


func row_button(alert_id: String) -> Button:
	return _rows.get(alert_id, null)


func unread_count() -> int:
	return model.unread_count() if model != null else 0
