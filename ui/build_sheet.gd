class_name BuildSheet
extends Control
## S2 + S3 of doc 12 §2.2: the Build FAB, the bottom build sheet (§2.7's card
## list) and the 56 dp `PlacementBar` that replaces it in placement mode.
##
## Dumb by construction (constitution §3, doc 12 §1). Every card value — cost,
## footprint, kW, locked state — comes from `BuildController`, which reads the
## archetype and economy tables; every verdict comes from that controller's
## preflight; every string comes from `data/strings.en.json` through `UIConfig`.
## Nothing here computes a number and nothing here authors a word.
##
## Widgets are built in code rather than authored in the `.tscn` so that widths
## and the 48 dp touch minimum come from `data/ui.json` at runtime and no
## `theme_override_*` property enters a scene file (doc 12 test 19). Every
## interactive `Control` gets `tooltip_text` — that is A15's accessibility name.

signal placement_started(archetype: String, variant: String)  ## card tap accepted
signal placement_changed                                       ## ghost moved / revalidated
signal placement_committed(result: Dictionary)                 ## `place_building` answered
signal placement_cancelled
signal card_refused(failure: Dictionary)  ## locked / unknown card explained in words
signal sheet_toggled(open: bool)

const PALETTE_TYPE := "Palette"

var config: UIConfig
var controller: BuildController
var model: HudModel

var _fab: Button
var _sheet: PanelContainer
var _tabs: HBoxContainer
var _cards_box: HBoxContainer
var _notice: Label
var _bar: PanelContainer
var _bar_cancel: Button
var _bar_title: Label
var _bar_issue: Label
var _bar_confirm: Button

var _cards: Array[Dictionary] = []
var _tab_buttons: Dictionary = {}   # category -> Button
var _category := ""
var _touch_min := 48.0
var _spacing := 8.0


## The one wiring entry point. `game/main.gd` hands over the parsed config and
## the controller; the headless tests call it with fixtures.
func setup(cfg: UIConfig = null, p_controller: BuildController = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	if p_controller != null:
		controller = p_controller
	model = HudModel.new(config)
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_bind_nodes()
	_build_static()
	rebuild_cards()
	close()
	_refresh_bar()


func _ready() -> void:
	if config == null:
		setup()


func _bind_nodes() -> void:
	_fab = get_node_or_null("Fab") as Button
	_sheet = get_node_or_null("Sheet") as PanelContainer
	_tabs = get_node_or_null("Sheet/Body/Tabs") as HBoxContainer
	_cards_box = get_node_or_null("Sheet/Body/Scroll/Cards") as HBoxContainer
	_notice = get_node_or_null("Sheet/Body/Notice") as Label
	_bar = get_node_or_null("PlacementBar") as PanelContainer
	_bar_cancel = get_node_or_null("PlacementBar/Row/Cancel") as Button
	_bar_title = get_node_or_null("PlacementBar/Row/Title") as Label
	_bar_issue = get_node_or_null("PlacementBar/Row/Issue") as Label
	_bar_confirm = get_node_or_null("PlacementBar/Row/Confirm") as Button


static func _clear_children(node: Node) -> void:
	if node == null:
		return
	for child in node.get_children():
		node.remove_child(child)
		child.free()


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build_static() -> void:
	var layout := config.layout()
	var fab_d := maxf(UIConfig.get_num(layout, "fab_d_dp", 64.0), _touch_min)
	if _fab != null:
		_fab.theme_type_variation = &"PrimaryFAB"
		_fab.focus_mode = Control.FOCUS_NONE
		_fab.custom_minimum_size = Vector2(fab_d, fab_d)
		_fab.text = _text("ui_build_open", "BUILD")
		_fab.tooltip_text = _fab.text
		if not _fab.pressed.is_connected(toggle):
			_fab.pressed.connect(toggle)
	if _bar_cancel != null:
		_bar_cancel.theme_type_variation = &"GhostButton"
		_bar_cancel.focus_mode = Control.FOCUS_NONE
		_bar_cancel.custom_minimum_size = Vector2(_touch_min, _touch_min)
		_bar_cancel.text = _text("ui_placement_cancel", "CANCEL")
		_bar_cancel.tooltip_text = _bar_cancel.text
		if not _bar_cancel.pressed.is_connected(cancel_placement):
			_bar_cancel.pressed.connect(cancel_placement)
	if _bar_confirm != null:
		_bar_confirm.theme_type_variation = &"PrimaryFAB"
		_bar_confirm.focus_mode = Control.FOCUS_NONE
		_bar_confirm.custom_minimum_size = Vector2(maxf(fab_d, _touch_min), _touch_min)
		_bar_confirm.text = _text("ui_placement_confirm", "PLACE")
		_bar_confirm.tooltip_text = _bar_confirm.text
		if not _bar_confirm.pressed.is_connected(confirm_placement):
			_bar_confirm.pressed.connect(confirm_placement)
	for box: Node in [_tabs, _cards_box]:
		if box != null:
			(box as Control).add_theme_constant_override(&"separation", int(_spacing))


## Cards + category tabs, rebuilt whenever the city level changes a lock state.
func rebuild_cards() -> void:
	_cards = controller.cards() if controller != null else ([] as Array[Dictionary])
	_build_tabs()
	_build_cards()


func _build_tabs() -> void:
	if _tabs == null:
		return
	BuildSheet._clear_children(_tabs)
	_tab_buttons.clear()
	var categories: Array[String] = []
	for card: Dictionary in _cards:
		var category := str(card["category"])
		if not categories.has(category):
			categories.append(category)
	if _category == "" or not categories.has(_category):
		_category = categories[0] if not categories.is_empty() else ""
	for category: String in categories:
		var button := Button.new()
		button.name = "Tab_" + category
		button.theme_type_variation = &"TabButton"
		button.focus_mode = Control.FOCUS_NONE
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(_touch_min * 2.0, _touch_min)
		button.text = _text(BuildController.category_tab_key(category), category.capitalize())
		button.tooltip_text = button.text
		button.set_pressed_no_signal(category == _category)
		button.pressed.connect(_on_tab_pressed.bind(category))
		_tabs.add_child(button)
		_tab_buttons[category] = button
	# Right-aligned ✕ so backing out never depends on knowing the FAB toggles.
	var spacer := Control.new()
	spacer.name = "TabSpacer"
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tabs.add_child(spacer)
	var close_button := Button.new()
	close_button.name = "CloseSheet"
	close_button.theme_type_variation = &"GhostButton"
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.custom_minimum_size = Vector2(_touch_min, _touch_min)
	close_button.text = _text("ui_sheet_close", "✕")
	close_button.tooltip_text = _text("ui_sheet_close_tip", "Close")
	close_button.pressed.connect(close)
	_tabs.add_child(close_button)


func _build_cards() -> void:
	if _cards_box == null:
		return
	BuildSheet._clear_children(_cards_box)
	var layout := config.layout()
	var raw: Variant = layout.get("build_card_dp", [96, 120])
	var dims: Array = raw if raw is Array and (raw as Array).size() >= 2 else [96, 120]
	var card_size := Vector2(maxf(float(dims[0]), _touch_min), maxf(float(dims[1]), _touch_min))
	for card: Dictionary in _cards:
		if str(card["category"]) != _category:
			continue
		_cards_box.add_child(_build_card(card, card_size))


## A 96 × 120 dp card: name, cost, and the §2.7 micro-row (kW + footprint). The
## whole card is the tap target, so its children never take the touch.
func _build_card(card: Dictionary, card_size: Vector2) -> Button:
	var button := Button.new()
	button.name = "Card_" + str(card["id"])
	button.theme_type_variation = &"GhostButton"
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = card_size
	var name_text := _text(str(card["name_key"]), str(card["name_fallback"]))
	button.tooltip_text = name_text  # A15
	button.set_meta("archetype", str(card["archetype"]))
	button.set_meta("variant", str(card["variant"]))
	button.pressed.connect(_on_card_pressed.bind(
			str(card["archetype"]), str(card["variant"])))

	var body := VBoxContainer.new()
	body.name = "Body"
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	button.add_child(body)

	var title := Label.new()
	title.name = "Name"
	title.text = name_text
	title.clip_text = true
	body.add_child(title)

	var cost := Label.new()
	cost.name = "Cost"
	cost.text = str(card["cost_text"])
	# §2.7: an unaffordable cost reads CRITICAL but the card stays tappable.
	_apply_state_color(cost, HudModel.STATE_NORMAL if bool(card["affordable"])
			else HudModel.STATE_CRITICAL)
	body.add_child(cost)

	var micro := Label.new()
	micro.name = "Micro"
	var foot: Vector2i = card["footprint"]
	micro.text = _text_args("ui_build_card_micro",
			{"kw": str(card["power_text"]), "w": foot.x, "h": foot.y},
			"%s %dx%d" % [card["power_text"], foot.x, foot.y])
	micro.clip_text = true
	body.add_child(micro)

	if bool(card["locked"]):
		var lock := Label.new()
		lock.name = "Lock"
		lock.text = _text_args("ui_build_locked",
				{"level": int(card["min_city_level"])}, str(card["min_city_level"]))
		_apply_state_color(lock, HudModel.STATE_OFFLINE)
		body.add_child(lock)
	return button


# ---------------------------------------------------------------------------
# Sheet open / close
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _sheet != null and _sheet.visible


func open() -> void:
	rebuild_cards()  # locks follow the live city level
	if _sheet != null:
		_sheet.visible = true
	_set_notice("")
	sheet_toggled.emit(true)


func close() -> void:
	if _sheet != null:
		_sheet.visible = false
	sheet_toggled.emit(false)


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


## Switch the visible category (the §2.7 tab bar). Public so the onboarding
## director and the `Buy a unit` deep link can preselect a tab.
func select_category(category: String) -> void:
	_category = category
	for id: Variant in _tab_buttons:
		(_tab_buttons[id] as Button).set_pressed_no_signal(str(id) == category)
	_build_cards()


func _on_tab_pressed(category: String) -> void:
	select_category(category)


# ---------------------------------------------------------------------------
# Placement mode
# ---------------------------------------------------------------------------

func _on_card_pressed(archetype: String, variant: String) -> void:
	if controller == null:
		return
	var entered := controller.enter(archetype, variant)
	if not bool(entered["ok"]):
		# §2.7: a locked card explains its unlock condition instead of placing.
		var failure := controller.formatter.format(entered["reason_code"], entered["payload"])
		_set_notice(str(failure["body"]))
		card_refused.emit(failure)
		return
	close()
	_refresh_bar()
	placement_started.emit(archetype, variant)
	placement_changed.emit()


## Ground point from `CameraState.screen_to_ground()` — the ghost follows and
## the verdict is recomputed (§2.7 re-evaluates while dragging).
func move_ghost(ground_point: Vector3) -> void:
	if controller == null or not controller.is_placing():
		return
	controller.move_to_ground(ground_point)
	_refresh_bar()
	placement_changed.emit()


## §2.7: "Placement is never committed on finger-up" — only this button commits.
func confirm_placement() -> void:
	if controller == null or not controller.is_placing():
		return
	var result := controller.commit()
	if bool(result["ok"]):
		_set_notice("")
	else:
		var failure := controller.formatter.format(result["reason_code"], result["payload"])
		_set_notice(str(failure["body"]))
	_refresh_bar()
	placement_committed.emit(result)
	placement_changed.emit()


func cancel_placement() -> void:
	if controller == null:
		return
	controller.cancel()
	_refresh_bar()
	placement_cancelled.emit()
	placement_changed.emit()


func is_placing() -> bool:
	return controller != null and controller.is_placing()


func _refresh_bar() -> void:
	if _bar == null or controller == null:
		return
	var view := controller.placement_view()
	var active := bool(view["active"])
	_bar.visible = active
	if _fab != null:
		_fab.visible = not active
	if not active:
		return
	var name_text := _text(str(view["name_key"]), str(view["archetype"]))
	if _bar_title != null:
		_bar_title.text = _text_args("ui_placement_summary",
				{"name": name_text, "cost": str(view["cost_text"])},
				"%s %s" % [name_text, str(view["cost_text"])])
	if _bar_confirm != null:
		_bar_confirm.disabled = not bool(view["can_confirm"])
	if _bar_issue == null:
		return
	var failure: Dictionary = view["failure"]
	if failure.is_empty():
		_bar_issue.text = _text("ui_placement_ready", "")
		_apply_state_color(_bar_issue, HudModel.STATE_NORMAL)
		return
	# A5/A14: the reason is in words, and the state glyph carries the verdict
	# without relying on colour.
	var state: StringName = failure["state"]
	var glyph := model.state_glyph(state)
	_bar_issue.text = ("%s %s" % [glyph, str(failure["body"])]).strip_edges()
	_apply_state_color(_bar_issue, state)


func _set_notice(text: String) -> void:
	if _notice == null:
		return
	_notice.text = text
	_notice.visible = text != ""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func card_button(card_id: String) -> Button:
	if _cards_box == null:
		return null
	return _cards_box.get_node_or_null("Card_" + card_id) as Button


func cards() -> Array[Dictionary]:
	return _cards


func active_category() -> String:
	return _category


func _text(key: String, fallback: String) -> String:
	if config != null and config.has_string(key):
		return config.t(key)
	return fallback


## Same contract with `{named}` arguments — `data/strings.en.json` first, the
## fallback only while a key is missing (G-8).
func _text_args(key: String, args: Dictionary, fallback: String) -> String:
	if config != null and config.has_string(key):
		return config.t(key, args)
	return fallback


func _apply_state_color(control: Control, state: StringName) -> void:
	if state == &"" or not has_theme_color(state, PALETTE_TYPE):
		control.remove_theme_color_override(&"font_color")
		return
	control.add_theme_color_override(&"font_color", get_theme_color(state, PALETTE_TYPE))
