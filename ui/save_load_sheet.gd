class_name SaveLoadSheet
extends Control
## The save-slot screen: the slot list, SAVE / LOAD / DELETE per slot, and the
## confirmation every destructive one of those has to pass. A full-screen modal
## on `ModalLayer` (§2.2), so BACK closes it and the scrim is the only `STOP`
## control while it is up.
##
## `SaveSlotsModel` owns the rules — which actions a slot offers, which of them
## ask first, and every word of the prompt — and talks to `game/save_service.gd`
## duck-typed. This file binds three buttons per row and a two-button
## confirmation bar, and it never touches a file.
##
## The confirmation is deliberately a bar inside the sheet rather than a system
## dialog: it keeps the slot list visible behind the question, so "overwrite
## Slot 2" is answered while looking at what is in Slot 2.

signal slot_action(action: StringName, slot: int, result: Dictionary)
signal loaded(slot: int)     ## a load actually happened — the shell re-binds
signal sheet_toggled(open: bool)

const SCRIM_ALPHA := 0.55

var config: UIConfig
var model: SaveSlotsModel

var _scrim: ColorRect
var _panel: PanelContainer
var _title: Label
var _close: Button
var _slots_box: VBoxContainer
var _message: Label
var _confirm_box: HBoxContainer
var _prompt: Label
var _yes: Button
var _no: Button

var _row_buttons: Dictionary = {}   # "<action>_<slot>" -> Button
var _slot_labels: Dictionary = {}   # slot -> {title, summary, saved}
var _touch_min := 48.0
var _spacing := 8.0
var _row_h := 88.0


func setup(cfg: UIConfig = null, p_model: SaveSlotsModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	model = p_model if p_model != null else SaveSlotsModel.new(config)
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_row_h = maxf(UIConfig.get_num(config.section("save_slots"), "row_h_dp", 88.0),
			_touch_min)
	_bind_nodes()
	_build_static()
	refresh()
	close()


func _ready() -> void:
	if model == null:
		setup(UIRoot.config_from(self))


func _bind_nodes() -> void:
	_scrim = get_node_or_null("Scrim") as ColorRect
	_panel = get_node_or_null("Panel") as PanelContainer
	_title = get_node_or_null("Panel/Body/Header/Title") as Label
	_close = get_node_or_null("Panel/Body/Header/Close") as Button
	_slots_box = get_node_or_null("Panel/Body/Scroll/Slots") as VBoxContainer
	_message = get_node_or_null("Panel/Body/Message") as Label
	_confirm_box = get_node_or_null("Panel/Body/Confirm") as HBoxContainer
	_prompt = get_node_or_null("Panel/Body/Confirm/Prompt") as Label
	_yes = get_node_or_null("Panel/Body/Confirm/Yes") as Button
	_no = get_node_or_null("Panel/Body/Confirm/No") as Button


func _build_static() -> void:
	if _scrim != null:
		_scrim.color = UIWidgets.scrim_color(self, SCRIM_ALPHA)
	if _title != null:
		_title.text = UIWidgets.t(config, "ui_saves_title")
		# Authored with `clip_text` in the scene, which reports a one-pixel minimum
		# and lets the ✕ beside it claim the whole header row.
		UIWidgets.elide(_title, _touch_min * 2.0)
	if _close != null:
		_close.theme_type_variation = &"GhostButton"
		_close.focus_mode = Control.FOCUS_NONE
		_close.custom_minimum_size = Vector2(_touch_min, _touch_min)
		_close.text = "✕"
		_close.tooltip_text = UIWidgets.t(config, "ui_saves_close")
		if not _close.pressed.is_connected(close):
			_close.pressed.connect(close)
	if _slots_box != null:
		_slots_box.add_theme_constant_override(&"separation", int(_spacing))
	if _yes != null:
		_yes.theme_type_variation = &"DangerButton"
		_yes.focus_mode = Control.FOCUS_NONE
		_yes.custom_minimum_size = Vector2(maxf(_touch_min * 1.5, 72.0), _touch_min)
		_yes.text = UIWidgets.t(config, "ui_saves_confirm_yes")
		_yes.tooltip_text = _yes.text
		if not _yes.pressed.is_connected(_on_confirm):
			_yes.pressed.connect(_on_confirm)
	if _no != null:
		_no.theme_type_variation = &"GhostButton"
		_no.focus_mode = Control.FOCUS_NONE
		_no.custom_minimum_size = Vector2(maxf(_touch_min * 1.5, 72.0), _touch_min)
		_no.text = UIWidgets.t(config, "ui_saves_confirm_no")
		_no.tooltip_text = _no.text
		if not _no.pressed.is_connected(_on_cancel):
			_no.pressed.connect(_on_cancel)


## Binds the live service and sim. Both stay `Object`: `ui/` never depends on
## `game/save_service.gd`'s type, which is what lets the tests stub it.
func bind_service(service: Object, sim: Object = null) -> void:
	model.bind(service, sim)
	refresh()


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

## Rows are built once and then **updated in place**. Rebuilding them here would
## free the very Button whose `pressed` signal is running — the row the player
## just tapped — which the engine refuses outright.
func refresh() -> void:
	if _slots_box == null:
		return
	if _slots_box.get_child_count() == 0:
		for row: Dictionary in model.rows():
			_slots_box.add_child(_build_slot(row))
	for row: Dictionary in model.rows():
		_update_slot(row)
	_refresh_confirm()


func _update_slot(row: Dictionary) -> void:
	var slot := int(row["slot"])
	var labels: Dictionary = _slot_labels.get(slot, {})
	if not labels.is_empty():
		(labels["title"] as Label).text = str(row["title"])
		var summary := labels["summary"] as Label
		summary.text = str(row["summary"])
		UIWidgets.paint_state(self, summary,
				&"" if bool(row["used"]) else HudModel.STATE_OFFLINE)
		var saved := labels["saved"] as Label
		saved.text = str(row["saved_text"])
		saved.visible = str(row["saved_text"]) != ""
	for pair: Array in [[SaveSlotsModel.ACTION_SAVE, "can_save"],
			[SaveSlotsModel.ACTION_LOAD, "can_load"],
			[SaveSlotsModel.ACTION_DELETE, "can_delete"]]:
		var button := action_button(pair[0], slot)
		if button != null:
			button.disabled = not bool(row[pair[1]])


## Two lines, not one. `SAVE | LOAD | DELETE` are three ~80 dp targets, and on a
## 412 dp phone they left the slot's own name 18 px to live in — `Autosave`,
## `Slot 1` and `Empty` were all invisible while three buttons sat beside them.
## Stacking the actions under the description gives each half the full width, and
## the 88 dp row already has the height for it.
func _build_slot(row: Dictionary) -> PanelContainer:
	var slot := int(row["slot"])
	var panel := PanelContainer.new()
	panel.name = "Slot%d" % slot
	panel.theme_type_variation = &"DrawerRow"
	panel.custom_minimum_size = Vector2(0.0, _row_h)

	var line := VBoxContainer.new()
	line.name = "Row"
	line.add_theme_constant_override(&"separation", int(_spacing))
	panel.add_child(line)

	var info := VBoxContainer.new()
	info.name = "Info"
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(info)
	var title := UIWidgets.label("Title", str(row["title"]))
	info.add_child(title)
	# The summary carries a day, a population and a treasury figure, so it is the
	# one line here long enough to need an ellipsis on a narrow display.
	var summary := UIWidgets.elide(UIWidgets.label("Summary", str(row["summary"])),
			_touch_min * 2.0) as Label
	info.add_child(summary)
	var saved := UIWidgets.label("Saved", str(row["saved_text"]))
	saved.visible = str(row["saved_text"]) != ""
	info.add_child(saved)
	_slot_labels[slot] = {"title": title, "summary": summary, "saved": saved}

	# `SAVE · LOAD · DELETE` measure 110 + 120 + 134 dp at 130 % text with larger
	# targets, so an `HBox` asked for 380 dp of row, the slot list asked the
	# scroller for it, and a `grow_horizontal = BOTH` sheet then centred 420 dp on
	# a 360 dp phone with its ✕ 20 dp off the right edge. Three peers with no
	# left-to-right meaning are exactly what a flow container is for: it asks for
	# its widest child (134 dp) and wraps DELETE onto a second line when the row
	# is narrow, while a wide box still lays all three side by side (D-38).
	var actions := HFlowContainer.new()
	actions.name = "Actions"
	actions.add_theme_constant_override(&"h_separation", int(_spacing))
	actions.add_theme_constant_override(&"v_separation", int(_spacing))
	line.add_child(actions)
	actions.add_child(_action_button(SaveSlotsModel.ACTION_SAVE, slot, "ui_saves_save",
			bool(row["can_save"]), &"PrimaryFAB", str(row["title"])))
	actions.add_child(_action_button(SaveSlotsModel.ACTION_LOAD, slot, "ui_saves_load",
			bool(row["can_load"]), &"GhostButton", str(row["title"])))
	actions.add_child(_action_button(SaveSlotsModel.ACTION_DELETE, slot, "ui_saves_delete",
			bool(row["can_delete"]), &"DangerButton", str(row["title"])))
	return panel


func _action_button(action: StringName, slot: int, key: String, enabled: bool,
		variation: StringName, slot_title: String) -> Button:
	var text := UIWidgets.t(config, key)
	var button := UIWidgets.button("%s_%d" % [String(action).capitalize(), slot], text,
			"%s — %s" % [text, slot_title],
			Vector2(maxf(_touch_min * 1.5, 72.0), _touch_min), variation)
	button.disabled = not enabled
	button.pressed.connect(_on_action.bind(action, slot))
	_row_buttons["%s_%d" % [String(action), slot]] = button
	return button


func _refresh_confirm() -> void:
	var pending := model.pending()
	if _confirm_box != null:
		_confirm_box.visible = not pending.is_empty()
	if _prompt != null:
		_prompt.text = str(pending.get("prompt", ""))
		UIWidgets.paint_state(self, _prompt, HudModel.STATE_WARNING)


func _set_message(text: String, state: StringName) -> void:
	if _message == null:
		return
	_message.text = text
	_message.visible = text != ""
	UIWidgets.paint_state(self, _message, state)


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

func _on_action(action: StringName, slot: int) -> void:
	var result := model.request(action, slot)
	if bool(result.get("confirm_required", false)):
		_refresh_confirm()
		_set_message("", &"")
		return
	_finish(result)


func _on_confirm() -> void:
	_finish(model.confirm())


func _on_cancel() -> void:
	model.cancel()
	_refresh_confirm()
	_set_message("", &"")


func _finish(result: Dictionary) -> void:
	refresh()
	_set_message(str(result.get("message", "")),
			HudModel.STATE_NORMAL if bool(result.get("ok", false))
			else HudModel.STATE_CRITICAL)
	slot_action.emit(StringName(str(result.get("action", ""))),
			int(result.get("slot", -1)), result)
	if bool(result.get("ok", false)) \
			and StringName(str(result.get("action", ""))) == SaveSlotsModel.ACTION_LOAD:
		loaded.emit(int(result["slot"]))


## Public entry for the pause menu's SAVE and for quit-saves: goes through the
## same confirmation gate as a tap on the row.
func request(action: StringName, slot: int) -> Dictionary:
	var result := model.request(action, slot)
	if bool(result.get("confirm_required", false)):
		_refresh_confirm()
	else:
		_finish(result)
	return result


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _panel != null and _panel.visible


func open() -> void:
	UIWidgets.close_siblings(self)
	model.cancel()
	model.refresh()
	refresh()
	_set_message("", &"")
	_set_visible(true)
	sheet_toggled.emit(true)


func close() -> void:
	model.cancel()
	_refresh_confirm()
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
# Helpers
# ---------------------------------------------------------------------------

func action_button(action: StringName, slot: int) -> Button:
	return _row_buttons.get("%s_%d" % [String(action), slot], null)


func confirm_button() -> Button:
	return _yes


func cancel_button() -> Button:
	return _no
