class_name AwayReportSheet
extends Control
## WHILE YOU WERE AWAY (doc 12 §2.12, S11): the sheet the player meets on resume.
##
## §2.12's rule is the one that shapes this file: "The report is always
## dismissible in one tap and never blocks a critical action." So the scrim is a
## modal scrim like every other, DISMISS is a 48 dp target at the top of the
## reading order as well as the bottom, and `HANDLE NOW` — the primary CTA —
## closes the report on its way to the incident rather than layering the drawer
## on top of it.
##
## Sections render in §2.12's fixed order and an empty one is not drawn at all:
## a quiet absence is a two-line report, not a page of zeroes.
##
## `AwayModel` decides everything, including whether the sheet should appear:
## `present()` renders and opens, or returns the toast copy and stays shut.

signal handle_now_requested(incident_id: int)   ## → focus + drawer + select
signal dismissed
signal sheet_toggled(open: bool)

const SCRIM_ALPHA := 0.55

var config: UIConfig
var model: AwayModel

var _scrim: ColorRect
var _panel: PanelContainer
var _title: Label
var _close: Button
var _content: VBoxContainer
var _dismiss: Button

var _handle_buttons: Dictionary = {}   # incident id:int -> Button
var _touch_min := 48.0
var _spacing := 8.0
var _row_h := 72.0
var _last_view: Dictionary = {}


func setup(cfg: UIConfig = null, p_model: AwayModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	model = p_model if p_model != null else AwayModel.new(config)
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	var layout := config.layout()
	_spacing = UIConfig.get_num(layout, "touch_spacing_min_dp", 8.0)
	_row_h = maxf(UIConfig.get_num(layout, "drawer_row_h_dp", 72.0), _touch_min)
	_bind_nodes()
	_build_static()
	close()


func _ready() -> void:
	if model == null:
		setup(UIRoot.config_from(self))


func _bind_nodes() -> void:
	_scrim = get_node_or_null("Scrim") as ColorRect
	_panel = get_node_or_null("Panel") as PanelContainer
	_title = get_node_or_null("Panel/Body/Header/Title") as Label
	_close = get_node_or_null("Panel/Body/Header/Close") as Button
	_content = get_node_or_null("Panel/Body/Scroll/Content") as VBoxContainer
	_dismiss = get_node_or_null("Panel/Body/Dismiss") as Button


func _build_static() -> void:
	if _scrim != null:
		_scrim.color = UIWidgets.scrim_color(self, SCRIM_ALPHA)
	if _title != null:
		_title.text = UIWidgets.t(config, "ui_away_header")
		# Authored with `clip_text` in the scene, which reports a one-pixel minimum
		# and lets the ✕ beside it claim the whole header row.
		UIWidgets.elide(_title, _touch_min * 2.0)
	for button: Button in [_close, _dismiss]:
		if button == null:
			continue
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(
				maxf(_touch_min * 2.0, 96.0) if button == _dismiss else _touch_min,
				_touch_min)
		button.text = UIWidgets.t(config, "ui_away_dismiss") if button == _dismiss else "✕"
		button.tooltip_text = UIWidgets.t(config, "ui_away_dismiss")
		button.theme_type_variation = &"PrimaryFAB" if button == _dismiss \
				else &"GhostButton"
		if not button.pressed.is_connected(_on_dismiss):
			button.pressed.connect(_on_dismiss)
	if _content != null:
		_content.add_theme_constant_override(&"separation", int(_spacing))


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

## The whole resume handshake in one call. Returns `""` when the sheet opened,
## and the toast copy when §2.12's threshold says a toast is the right surface —
## the shell raises that toast; this screen stays out of the way.
func present(input: Dictionary) -> String:
	var view := model.build(input)
	_last_view = view
	if not bool(view["show"]):
		return str(view["toast"])
	_render(view)
	UIWidgets.close_siblings(self)
	_set_visible(true)
	sheet_toggled.emit(true)
	return ""


func is_open() -> bool:
	return _panel != null and _panel.visible


func open() -> void:
	if _last_view.is_empty():
		return
	UIWidgets.close_siblings(self)
	_set_visible(true)
	sheet_toggled.emit(true)


func close() -> void:
	_set_visible(false)
	sheet_toggled.emit(false)


func _set_visible(value: bool) -> void:
	if _panel != null:
		_panel.visible = value
	if _scrim != null:
		_scrim.visible = value
		_scrim.mouse_filter = Control.MOUSE_FILTER_STOP if value \
				else Control.MOUSE_FILTER_IGNORE


# ---------------------------------------------------------------------------
# Rendering — §2.12's fixed order, empty sections omitted
# ---------------------------------------------------------------------------

func _render(view: Dictionary) -> void:
	if _content == null:
		return
	UIWidgets.clear_children(_content)
	_handle_buttons.clear()
	_render_header(view["header"] as Dictionary)
	_render_needs_you(view["needs_you"] as Dictionary)
	_render_ledger(view["ledger"] as Dictionary)
	_render_change(view["change"] as Dictionary)
	_render_timeline(view["timeline"] as Dictionary)


func _render_header(header: Dictionary) -> void:
	_content.add_child(UIWidgets.label("Elapsed", str(header["text"]), &"", true))
	if str(header["days_text"]) != "":
		_content.add_child(UIWidgets.label("Days", str(header["days_text"])))
	if str(header["capped_text"]) != "":
		var capped := UIWidgets.label("Capped", str(header["capped_text"]), &"", true)
		UIWidgets.paint_state(self, capped, HudModel.STATE_WARNING)
		_content.add_child(capped)


## §2.12 section 2 — the primary CTA. Up to `max_unresolved_shown` §2.6 rows,
## each with its own `HANDLE NOW`, in CRITICAL styling and rendered first.
func _render_needs_you(section: Dictionary) -> void:
	if not bool(section["visible"]):
		return
	var title := UIWidgets.label("NeedsYouTitle", str(section["title"]), &"LegendRow")
	UIWidgets.paint_state(self, title, section["state"])
	_content.add_child(title)
	for raw: Variant in (section["rows"] as Array):
		var row: Dictionary = raw
		var incident_id := int(row.get("id", 0))
		var line := HBoxContainer.new()
		line.name = "Needs_%d" % incident_id
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_theme_constant_override(&"separation", int(_spacing))

		var label := UIWidgets.label("Label", "T%d %s · %s" % [
				int(row.get("tier", 1)), str(row.get("title", "")),
				str(row.get("subtitle", ""))], &"", true)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UIWidgets.paint_state(self, label, row.get("state", HudModel.STATE_CRITICAL))
		line.add_child(label)

		var action := UIWidgets.button("Handle_%d" % incident_id,
				str(section["action_text"]), str(section["action_text"]),
				Vector2(maxf(_touch_min * 2.5, 120.0), _touch_min), &"PrimaryFAB")
		action.pressed.connect(_on_handle_now.bind(incident_id))
		line.add_child(action)
		_handle_buttons[incident_id] = action
		_content.add_child(line)
	if str(section["more_text"]) != "":
		_content.add_child(UIWidgets.label("NeedsMore", str(section["more_text"])))


func _render_ledger(section: Dictionary) -> void:
	if not bool(section["visible"]):
		return
	_content.add_child(UIWidgets.label("LedgerTitle", str(section["title"]),
			&"LegendRow"))
	var line := UIWidgets.label("Ledger", str(section["text"]), &"", true)
	UIWidgets.paint_state(self, line, section["net_state"])
	_content.add_child(line)
	_content.add_child(UIWidgets.label("Treasury", str(section["treasury_text"]),
			&"", true))


func _render_change(section: Dictionary) -> void:
	if not bool(section["visible"]):
		return
	_content.add_child(UIWidgets.label("ChangeTitle", str(section["title"]),
			&"LegendRow"))
	for raw: Variant in (section["lines"] as Array):
		var record: Dictionary = raw
		var label := UIWidgets.label("Change_" + str(record["id"]),
				str(record["text"]), &"", true)
		UIWidgets.paint_state(self, label, record["state"])
		_content.add_child(label)


func _render_timeline(section: Dictionary) -> void:
	_content.add_child(UIWidgets.label("TimelineTitle", str(section["title"]),
			&"LegendRow"))
	if not bool(section["visible"]):
		_content.add_child(UIWidgets.label("TimelineEmpty",
				str(section["empty_text"]), &"", true))
		return
	for raw: Variant in (section["rows"] as Array):
		var row: Dictionary = raw
		var label := UIWidgets.label("Event_" + str(row["type"]), str(row["label"]),
				&"", true)
		UIWidgets.paint_state(self, label, row["state"])
		_content.add_child(label)
	if str(section["more_text"]) != "":
		_content.add_child(UIWidgets.label("TimelineMore", str(section["more_text"])))


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

## §2.12: HANDLE NOW "dismisses the report, jumps the camera, opens the drawer
## and preselects the incident". The last three are the shell's; dismissing is
## this screen's, and it happens first so the player never sees the report on
## top of the thing it sent them to.
func _on_handle_now(incident_id: int) -> void:
	close()
	handle_now_requested.emit(incident_id)


func _on_dismiss() -> void:
	close()
	dismissed.emit()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func handle_button(incident_id: int) -> Button:
	return _handle_buttons.get(incident_id, null)


func dismiss_button() -> Button:
	return _dismiss


func last_view() -> Dictionary:
	return _last_view.duplicate(true)
