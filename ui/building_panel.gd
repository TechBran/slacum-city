class_name BuildingPanel
extends Control
## S5 of doc 12 §2.2, laid out per §2.9: header (name + level pips + condition),
## the 2×3 vitals grid, the four service-coverage tiles, and the upgrade block —
## cost, the **requirement checklist**, and an `UPGRADE` button that is disabled
## while any `✗` remains and whose subtitle names the first blocker.
##
## Dumb by construction: `BuildController.building_view()` computes every value
## and `RequirementFormatter` writes every requirement line, so this file holds
## no threshold, no gate and no copy. Each checklist row carries the `Fix this →`
## affordance of §2.7 — "the single most important teaching device in the game" —
## which this panel surfaces as a signal for the camera/panel router to act on.

signal closed
signal upgraded(result: Dictionary)             ## `upgrade_building` answered
signal fix_requested(fix_target: Dictionary)    ## `Fix this →` on a blocker row

const PALETTE_TYPE := "Palette"
## §2.9's `L1 L2 ▮L3▮ L4 L5` level pips — glyphs, not copy (A5 redundancy).
const PIP_ON := "▮"
## Every panel in the deck closes with this glyph and names itself in the tooltip.
const CLOSE_GLYPH := "✕"

var config: UIConfig
var controller: BuildController

var _panel: PanelContainer
var _title: Label
var _close: Button
var _level: Label
var _vitals: GridContainer
var _coverage: GridContainer
var _upgrade_header: Label
var _upgrade_note: Label
var _checklist: VBoxContainer
var _upgrade_button: Button

var _sim_id := ""
var _touch_min := 48.0
var _spacing := 8.0
var _view: Dictionary = {}


func setup(cfg: UIConfig = null, p_controller: BuildController = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	if p_controller != null:
		controller = p_controller
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_bind_nodes()
	_build_static()
	close()


func _ready() -> void:
	if config == null:
		# The root's parse, not a second one — see `CityHUD._ready()`.
		setup(UIRoot.config_from(self))


func _bind_nodes() -> void:
	_panel = get_node_or_null("Panel") as PanelContainer
	_title = get_node_or_null("Panel/Scroll/Body/Header/Title") as Label
	_close = get_node_or_null("Panel/Scroll/Body/Header/Close") as Button
	_level = get_node_or_null("Panel/Scroll/Body/Level") as Label
	_vitals = get_node_or_null("Panel/Scroll/Body/Vitals") as GridContainer
	_coverage = get_node_or_null("Panel/Scroll/Body/Coverage") as GridContainer
	_upgrade_header = get_node_or_null("Panel/Scroll/Body/UpgradeHeader") as Label
	_upgrade_note = get_node_or_null("Panel/Scroll/Body/UpgradeNote") as Label
	_checklist = get_node_or_null("Panel/Scroll/Body/Checklist") as VBoxContainer
	_upgrade_button = get_node_or_null("Panel/Scroll/Body/UpgradeButton") as Button


static func _clear_children(node: Node) -> void:
	if node == null:
		return
	for child in node.get_children():
		node.remove_child(child)
		child.free()


func _build_static() -> void:
	var panel_w := UIConfig.get_num(config.layout(), "side_panel_w_dp", 300.0)
	if _panel != null:
		_panel.theme_type_variation = &"SidePanel"
		_panel.custom_minimum_size = Vector2(panel_w, 0.0)
	if _close != null:
		_close.theme_type_variation = &"GhostButton"
		_close.focus_mode = Control.FOCUS_NONE
		_close.custom_minimum_size = Vector2(_touch_min, _touch_min)
		# The glyph, with the word in the tooltip — the shape every other close in
		# the deck uses (alerts, drawer, picker, saves, dashboard). This one was
		# the odd one out: a 48 dp square target rendering the word `Close`, which
		# reads as a different control from the ✕ on the panel beside it.
		_close.text = CLOSE_GLYPH
		_close.tooltip_text = _text("ui_building_close", "Close")
		if not _close.pressed.is_connected(close):
			_close.pressed.connect(close)
	if _upgrade_button != null:
		_upgrade_button.theme_type_variation = &"PrimaryFAB"
		_upgrade_button.focus_mode = Control.FOCUS_NONE
		_upgrade_button.custom_minimum_size = Vector2(_touch_min * 2.0, _touch_min)
		_upgrade_button.text = _text("ui_building_upgrade", "UPGRADE")
		_upgrade_button.tooltip_text = _upgrade_button.text
		if not _upgrade_button.pressed.is_connected(request_upgrade):
			_upgrade_button.pressed.connect(request_upgrade)
	# §2.9's 2×3 vitals grid, and the four coverage tiles as 2×2 — four in one row
	# does not fit a 300 dp column at any text scale.
	for grid: GridContainer in [_vitals, _coverage]:
		if grid != null:
			grid.columns = 2
			grid.add_theme_constant_override(&"h_separation", int(_spacing))
	if _checklist != null:
		_checklist.add_theme_constant_override(&"separation", int(_spacing))


# ---------------------------------------------------------------------------
# Binding
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _panel != null and _panel.visible


func selected_id() -> String:
	return _sim_id


## Tap a building → this. An unknown id closes the panel rather than showing a
## stale one (§2.2: the panel exits on "tap map").
func show_building(sim_id: String) -> void:
	if controller == null:
		return
	var view := controller.building_view(sim_id)
	if not bool(view.get("exists", false)):
		close()
		return
	# `PanelLayer` shows one surface at a time (D-16). S4 landed beside this
	# panel on the same layer and the same right edge, so opening either one has
	# to put the other away — two 300 dp panels sharing an edge do not occlude,
	# they collide, and their tap targets collide with them.
	UIWidgets.close_siblings(self)
	_sim_id = sim_id
	_view = view
	if _panel != null:
		_panel.visible = true
	_render(view)


## Re-reads the sim for the currently selected building (after an upgrade, a
## tick, or a construction completion).
func refresh() -> void:
	if _sim_id != "" and is_open():
		show_building(_sim_id)


func close() -> void:
	if _panel != null:
		_panel.visible = false
	_sim_id = ""
	_view = {}
	closed.emit()


func view() -> Dictionary:
	return _view


## The right-edge column, solved against the display it is on — see
## `UIWidgets.side_panel_width`. A checklist row is a whole sentence, so this
## panel is the one most likely to want the full width of a phone.
func _apply_panel_width() -> void:
	if _panel == null or size.x <= 1.0:
		return
	var layout := config.layout()
	var width := UIWidgets.side_panel_width(size.x,
			_panel.get_combined_minimum_size().x,
			UIConfig.get_num(layout, "drawer_w_ratio", 0.34),
			UIConfig.get_num(layout, "side_panel_w_dp", 300.0),
			UIConfig.get_num(layout, "drawer_w_max_dp", 340.0),
			_touch_min)
	_panel.offset_left = -width


func _render(v: Dictionary) -> void:
	_apply_panel_width()
	if _title != null:
		_title.text = _text(str(v["name_key"]), str(v["name_fallback"]))
		_title.tooltip_text = _title.text
		# See `AlertsCenter`: the scene's `clip_text` alone would let the ✕ beside
		# it claim the whole header.
		UIWidgets.elide(_title, _touch_min * 2.0)
	if _level != null:
		_level.text = "%s  %s" % [BuildingPanel.level_pips(int(v["level"]),
				int(v["max_level"])), _text(str(v["state_key"]), String(v["state"]))]
	_render_vitals(v)
	_render_coverage(v)
	_render_upgrade(v)


## `L1 L2 ▮L3▮ L4 L5` (§2.9), the doc's row verbatim: only the current level is
## bracketed, and the digits carry the meaning so the row survives grayscale.
static func level_pips(level: int, max_level: int) -> String:
	var parts: PackedStringArray = []
	for i in range(1, maxi(max_level, 1) + 1):
		parts.append("%sL%d%s" % [PIP_ON, i, PIP_ON] if i == level else "L%d" % i)
	return " ".join(parts)


func _render_vitals(v: Dictionary) -> void:
	if _vitals == null:
		return
	BuildingPanel._clear_children(_vitals)
	for entry: Variant in (v["vitals"] as Array):
		var vital: Dictionary = entry
		var label := Label.new()
		label.name = "Label_" + str(vital["id"])
		label.text = _text(str(vital["label_key"]), str(vital["id"]).capitalize())
		_vitals.add_child(label)
		var value := Label.new()
		value.name = "Value_" + str(vital["id"])
		value.text = str(vital["value"])
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_vitals.add_child(value)


## Four 40 dp tiles (§2.9 item 4). Each carries the §2.5 state glyph as well as
## the colour, so the row survives grayscale (A5).
func _render_coverage(v: Dictionary) -> void:
	if _coverage == null:
		return
	BuildingPanel._clear_children(_coverage)
	var model := HudModel.new(config)
	for entry: Variant in (v["coverage"] as Array):
		var tile: Dictionary = entry
		var label := Label.new()
		label.name = "Coverage_" + str(tile["id"])
		var state: StringName = tile["state"]
		label.text = "%s %s %s" % [_text(str(tile["label_key"]), str(tile["id"]).capitalize()),
				model.state_glyph(state), str(tile["value"])]
		label.tooltip_text = str(tile.get("attachment", ""))
		_apply_state_color(label, state)
		_coverage.add_child(label)


func _render_upgrade(v: Dictionary) -> void:
	var upgrade: Dictionary = v["upgrade"]
	if _upgrade_header != null:
		if bool(upgrade["available"]):
			_upgrade_header.text = _text_args("ui_building_upgrade_to",
					{"level": int(upgrade["to_level"])},
					"Level %d" % int(upgrade["to_level"]))
		else:
			_upgrade_header.text = _text("ui_building_upgrade_unavailable", "")
	if _upgrade_note != null:
		_upgrade_note.text = _upgrade_note_text(upgrade)
	if _checklist != null:
		BuildingPanel._clear_children(_checklist)
		for entry: Variant in (upgrade["checklist"] as Array):
			_checklist.add_child(_build_check_row(entry))
	if _upgrade_button != null:
		# §2.9: disabled while any ✗ remains.
		_upgrade_button.disabled = not (bool(upgrade["available"]) and bool(upgrade["ok"]))
		_upgrade_button.tooltip_text = _upgrade_button.text


func _upgrade_note_text(upgrade: Dictionary) -> String:
	if not bool(upgrade["available"]):
		return _text("ui_building_upgrade_unavailable", "")
	var blocker: Dictionary = upgrade["blocked_by"]
	if not blocker.is_empty():
		return _text_args("ui_building_upgrade_blocked",
				{"first": str(blocker["title"])}, str(blocker["title"]))
	return "%s  %s" % [
		_text_args("ui_building_upgrade_cost", {"cost": str(upgrade["cost_text"])},
				str(upgrade["cost_text"])),
		_text("ui_building_upgrade_ready", ""),
	]


## One checklist line: `✓`/`✗` + the formatter's sentence + `Fix this →` when the
## blocker has a navigable target (§2.7).
func _build_check_row(entry: Variant) -> HBoxContainer:
	var row_data: Dictionary = entry
	var row := HBoxContainer.new()
	row.name = "Check_" + str(row_data["canonical"])
	row.add_theme_constant_override(&"separation", int(_spacing))

	var glyph := Label.new()
	glyph.name = "Glyph"
	glyph.text = str(row_data["glyph"])
	_apply_state_color(glyph, StringName(str(row_data["state"])))
	row.add_child(glyph)

	var body := Label.new()
	body.name = "Body"
	# `text` is the checklist voice: the requirement's name when it passes, the
	# whole formatter sentence when it does not.
	body.text = str(row_data.get("text", row_data["body"]))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(body)

	var fix: Dictionary = row_data["fix_target"]
	if not bool(row_data.get("ok", true)) \
			and str(fix["kind"]) != String(RequirementFormatter.FIX_NONE):
		var button := Button.new()
		button.name = "Fix"
		button.theme_type_variation = &"GhostButton"
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(_touch_min * 2.0, _touch_min)
		button.text = _text("ui_building_fix_this", "")
		button.tooltip_text = "%s %s" % [button.text, str(row_data["title"])]
		button.pressed.connect(_on_fix_pressed.bind(fix))
		row.add_child(button)
	return row


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

## The real command (doc 12 §4.4) — the UI never predicts success, it refreshes
## from whatever the sim answers.
func request_upgrade() -> void:
	if controller == null or _sim_id == "":
		return
	var result := controller.upgrade(_sim_id)
	refresh()
	upgraded.emit(result)


func _on_fix_pressed(fix_target: Dictionary) -> void:
	fix_requested.emit(fix_target)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func upgrade_button() -> Button:
	return _upgrade_button


func checklist_rows() -> Array[Node]:
	return _checklist.get_children() if _checklist != null else ([] as Array[Node])


func _text(key: String, fallback: String) -> String:
	if config != null and config.has_string(key):
		return config.t(key)
	return fallback


func _text_args(key: String, args: Dictionary, fallback: String) -> String:
	if config != null and config.has_string(key):
		return config.t(key, args)
	return fallback


func _apply_state_color(control: Control, state: StringName) -> void:
	if state == &"" or not has_theme_color(state, PALETTE_TYPE):
		control.remove_theme_color_override(&"font_color")
		return
	control.add_theme_color_override(&"font_color", get_theme_color(state, PALETTE_TYPE))
