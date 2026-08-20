class_name LandPanel
extends Control
## S4 of doc 12 §2.2, laid out per §2.8: the land purchase flow.
##
##     Block B4 · 16×16 tiles · 128 m
##     Price $12,600   Development $38,915   Time 1d 22h   Buildable 169 / 256
##     Flood      ▮▮▮▯▯ Elevated
##     Waterfront +18%
##     ── the six phases, with the live one's bar and ETA ──
##     [ PURCHASE $12,600 ]
##
## Dumb by construction, like every other screen in this folder:
## `LandPanelModel` computes every value and `RequirementFormatter` writes every
## refusal, so this file holds no price, no threshold and no copy (constitution
## §3, doc 12 §1). It draws four things the doc asks for and decides none of
## them — the header, the risk/advantage read-out, the six-step progress list,
## and one primary button that is disabled while the sim would refuse it.
##
## It lives on `PanelLayer` beside the building panel and the incident drawer,
## which means it obeys the same two rules they do: one panel at a time
## (`UIWidgets.close_siblings`), and the edge affordances stand down while it is
## up (`UIWidgets.any_sibling_open`, D-16).

signal closed
signal purchased(result: Dictionary)            ## `cmd_buy_block` answered
signal developed(result: Dictionary)            ## `cmd_start_development` answered
signal fix_requested(fix_target: Dictionary)    ## `Fix this →` on a blocker row

const PALETTE_TYPE := "Palette"
## Every panel in the deck closes with this glyph and names itself in the tooltip.
const CLOSE_GLYPH := "✕"

var config: UIConfig
var model: LandPanelModel
## Set by `UIRoot`; a refusal buzzes and a commit taps (doc 12 §2.14).
var haptics: Haptics

var _panel: PanelContainer
var _title: Label
var _close: Button
var _subtitle: Label
var _facts: GridContainer
var _risk_title: Label
var _risks: VBoxContainer
var _advantage_title: Label
var _advantages: VBoxContainer
var _note: Label
var _phase_title: Label
var _phases: VBoxContainer
var _progress: Label
var _blockers: VBoxContainer
var _action: Button
var _action_note: Label

var _block_id := ""
var _view: Dictionary = {}
var _touch_min := 48.0
var _spacing := 8.0


func setup(cfg: UIConfig = null, p_model: LandPanelModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	if p_model != null:
		model = p_model
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


## The three controls that must never be below the fold live on `Frame`,
## **outside** the scroller. S4 is the longest panel in the deck — a header, four
## facts, six risk rows, six price terms, a note and six phases — and on a 412 dp
## phone `PURCHASE` starts three screenfuls down. A primary action a player has
## to go looking for is not a primary action, and the ETA is the whole reason to
## open the panel while a block is developing. The two are mutually exclusive by
## construction (a block that is developing has no primary button), so the pinned
## strip is one line and a button, never both.
func _bind_nodes() -> void:
	_panel = get_node_or_null("Panel") as PanelContainer
	_progress = get_node_or_null("Panel/Frame/Progress") as Label
	_action = get_node_or_null("Panel/Frame/ActionButton") as Button
	_action_note = get_node_or_null("Panel/Frame/ActionNote") as Label
	var body := "Panel/Frame/Scroll/Body/"
	_title = get_node_or_null(body + "Header/Title") as Label
	_close = get_node_or_null(body + "Header/Close") as Button
	_subtitle = get_node_or_null(body + "Subtitle") as Label
	_facts = get_node_or_null(body + "Facts") as GridContainer
	_risk_title = get_node_or_null(body + "RiskTitle") as Label
	_risks = get_node_or_null(body + "Risks") as VBoxContainer
	_advantage_title = get_node_or_null(body + "AdvantageTitle") as Label
	_advantages = get_node_or_null(body + "Advantages") as VBoxContainer
	_note = get_node_or_null(body + "Note") as Label
	_phase_title = get_node_or_null(body + "PhaseTitle") as Label
	_phases = get_node_or_null(body + "Phases") as VBoxContainer
	_blockers = get_node_or_null(body + "Blockers") as VBoxContainer


func _build_static() -> void:
	var layout := config.layout()
	if _panel != null:
		_panel.theme_type_variation = &"SidePanel"
		_panel.custom_minimum_size = Vector2(
				UIConfig.get_num(layout, "side_panel_w_dp", 300.0), 0.0)
	if _close != null:
		_close.theme_type_variation = &"GhostButton"
		_close.focus_mode = Control.FOCUS_NONE
		_close.custom_minimum_size = Vector2(_touch_min, _touch_min)
		_close.text = CLOSE_GLYPH
		_close.tooltip_text = _text("ui_land_close")
		if not _close.pressed.is_connected(close):
			_close.pressed.connect(close)
	if _action != null:
		_action.theme_type_variation = &"PrimaryFAB"
		_action.focus_mode = Control.FOCUS_NONE
		_action.clip_text = false
		_action.custom_minimum_size = Vector2(_touch_min * 2.0, _touch_min)
		if not _action.pressed.is_connected(_on_action_pressed):
			_action.pressed.connect(_on_action_pressed)
	if _facts != null:
		_facts.columns = 2
		_facts.add_theme_constant_override(&"h_separation", int(_spacing))
	for box: Node in [_risks, _advantages, _phases, _blockers]:
		if box != null:
			(box as Control).add_theme_constant_override(&"separation", int(_spacing))
	for pair: Array in [[_risk_title, "ui_land_risk_title"],
			[_advantage_title, "ui_land_advantage_title"],
			[_phase_title, "ui_land_phase_title"]]:
		var label: Label = pair[0]
		if label != null:
			label.theme_type_variation = &"LegendRow"
			label.text = _text(str(pair[1]))


# ---------------------------------------------------------------------------
# Binding
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _panel != null and _panel.visible


func selected_id() -> String:
	return _block_id


## Tap an unowned or developing block → this. An id the world does not carry, or
## one that is already finished ground, closes the panel rather than showing a
## card with nothing on it (§2.2: the panel exits on "tap map").
func show_block(block_id: String) -> void:
	if model == null:
		return
	var view := model.block_view(block_id)
	if not bool(view.get("exists", false)):
		close()
		return
	UIWidgets.close_siblings(self)  # one panel at a time on PanelLayer
	_block_id = block_id
	_view = view
	if _panel != null:
		_panel.visible = true
	_render(view)


## Re-reads the sim for the selected block — after a purchase, a phase tick, or a
## treasury change that unblocks the button.
func refresh() -> void:
	if _block_id != "" and is_open():
		var view := model.block_view(_block_id)
		if not bool(view.get("exists", false)):
			close()
			return
		_view = view
		_render(view)


func close() -> void:
	if _panel != null:
		_panel.visible = false
	_block_id = ""
	_view = {}
	closed.emit()


func view() -> Dictionary:
	return _view


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func _apply_panel_width() -> void:
	if _panel == null or size.x <= 1.0:
		return
	var layout := config.layout()
	_panel.offset_left = -UIWidgets.side_panel_width(size.x,
			_panel.get_combined_minimum_size().x,
			UIConfig.get_num(layout, "drawer_w_ratio", 0.34),
			UIConfig.get_num(layout, "side_panel_w_dp", 300.0),
			UIConfig.get_num(layout, "drawer_w_max_dp", 340.0),
			_touch_min)


func _render(v: Dictionary) -> void:
	_apply_panel_width()
	if _title != null:
		_title.text = _text_args("ui_land_title", {"label": str(v["label"])})
		_title.tooltip_text = _title.text
		# See `AlertsCenter`: the scene's `clip_text` alone would let the ✕ beside
		# it claim the whole header.
		UIWidgets.elide(_title, _touch_min * 2.0)
	if _subtitle != null:
		_subtitle.text = str(v["header"])
		_subtitle.tooltip_text = _subtitle.text
	_render_facts(v)
	_render_risks(v)
	_render_advantages(v)
	_render_phases(v)
	_render_blockers(v)
	_render_action(v)
	if _note != null:
		_note.text = _text(str(v["note_key"]))


func _render_facts(v: Dictionary) -> void:
	if _facts == null:
		return
	UIWidgets.clear_children(_facts)
	for entry: Variant in (v["facts"] as Array):
		var fact: Dictionary = entry
		_facts.add_child(UIWidgets.label("Label_" + str(fact["id"]),
				_text(str(fact["label_key"]))))
		var value := UIWidgets.label("Value_" + str(fact["id"]), str(fact["value"]))
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_facts.add_child(value)


## §2.8's risk profile. One `Label` per risk, never a tap target: the row is a
## reading, and a 48 dp button that does nothing is worse than a line of text.
func _render_risks(v: Dictionary) -> void:
	if _risks == null:
		return
	UIWidgets.clear_children(_risks)
	var rows: Array = v["risks"]
	if _risk_title != null:
		_risk_title.visible = not rows.is_empty()
	_risks.visible = not rows.is_empty()
	for entry: Variant in rows:
		var risk: Dictionary = entry
		var label := UIWidgets.label("Risk_" + str(risk["id"]), "%s %s %s" % [
				_text(str(risk["label_key"])), str(risk["bar"]), str(risk["word"])])
		UIWidgets.paint_state(self, label, StringName(str(risk["state"])))
		_risks.add_child(label)


func _render_advantages(v: Dictionary) -> void:
	if _advantages == null:
		return
	UIWidgets.clear_children(_advantages)
	var rows: Array = v["advantages"]
	if _advantage_title != null:
		_advantage_title.visible = not rows.is_empty()
	_advantages.visible = not rows.is_empty()
	for entry: Variant in rows:
		var advantage: Dictionary = entry
		var row := HBoxContainer.new()
		row.name = "Advantage_" + str(advantage["id"])
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override(&"separation", int(_spacing))
		var label := UIWidgets.label("Label", _text(str(advantage["label_key"])))
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var value := UIWidgets.label("Value", str(advantage["value"]))
		UIWidgets.paint_state(self, value, StringName(str(advantage["state"])))
		row.add_child(value)
		_advantages.add_child(row)


## The six phases, always all six (§2.8 item 4). The live one also draws its bar
## and its ETA — a done phase's bar says nothing a `✓` has not already said.
func _render_phases(v: Dictionary) -> void:
	if _phases == null:
		return
	UIWidgets.clear_children(_phases)
	for entry: Variant in (v["phases"] as Array):
		var phase: Dictionary = entry
		var box := VBoxContainer.new()
		box.name = "Phase_" + str(phase["id"])
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_theme_constant_override(&"separation", 0)
		var row := HBoxContainer.new()
		row.name = "Row"
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override(&"separation", int(_spacing))
		var name_label := UIWidgets.label("Name", "%s %s" % [str(phase["glyph"]),
				_text(str(phase["label_key"]))])
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UIWidgets.paint_state(self, name_label, _phase_state_colour(str(phase["state"])))
		row.add_child(name_label)
		row.add_child(UIWidgets.label("Cost", str(phase["cost_text"])))
		box.add_child(row)
		if StringName(str(phase["state"])) == LandPanelModel.PHASE_STATE_ACTIVE:
			box.add_child(UIWidgets.label("Bar", str(phase["bar"]), &"LegendRow"))
		_phases.add_child(box)
	_render_progress(v)


static func _phase_state_colour(state: String) -> StringName:
	match StringName(state):
		LandPanelModel.PHASE_STATE_DONE:
			return HudModel.STATE_NORMAL
		LandPanelModel.PHASE_STATE_ACTIVE:
			return HudModel.STATE_WARNING
	return &""


func _render_progress(v: Dictionary) -> void:
	if _progress == null:
		return
	var progress: Dictionary = v["progress"]
	if not bool(progress["active"]):
		_progress.text = ""
		_progress.visible = false
		return
	_progress.visible = true
	_progress.text = _text_args("ui_land_progress", {
		"phase": _text(str(progress["phase_label_key"])),
		"eta": str(progress["eta_text"]),
		"total": str(progress["eta_total_text"]),
	})
	_progress.tooltip_text = _progress.text


## One row per refusal, in the sim's own order, with the §2.7 `Fix this →`
## affordance wherever the blocker resolves to something navigable.
func _render_blockers(v: Dictionary) -> void:
	if _blockers == null:
		return
	UIWidgets.clear_children(_blockers)
	var rows: Array = v["blockers"]
	_blockers.visible = not rows.is_empty()
	for entry: Variant in rows:
		_blockers.add_child(_build_blocker_row(entry))


func _build_blocker_row(entry: Variant) -> HBoxContainer:
	var data: Dictionary = entry
	var row := HBoxContainer.new()
	row.name = "Blocker_" + str(data["canonical"])
	row.add_theme_constant_override(&"separation", int(_spacing))

	var glyph := UIWidgets.label("Glyph", str(data["glyph"]))
	UIWidgets.paint_state(self, glyph, StringName(str(data["state"])))
	row.add_child(glyph)

	var body := UIWidgets.label("Body", str(data.get("text", data["body"])), &"", true)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(body)

	var fix: Dictionary = data["fix_target"]
	if str(fix["kind"]) != String(RequirementFormatter.FIX_NONE) \
			and str(fix["id"]) != "":
		var button := UIWidgets.button("Fix", _text("ui_land_fix_this"),
				"%s %s" % [_text("ui_land_fix_this"), str(data["title"])],
				Vector2(_touch_min * 2.0, _touch_min), &"GhostButton")
		button.pressed.connect(_on_fix_pressed.bind(fix))
		row.add_child(button)
	return row


func _render_action(v: Dictionary) -> void:
	var action: Dictionary = v["action"]
	var id := StringName(str(action["id"]))
	if _action != null:
		_action.visible = id != LandPanelModel.ACTION_NONE
		if _action.visible:
			_action.text = _text_args(str(action["label_key"]),
					{"cost": str(action["cost_text"])})
			_action.tooltip_text = _action.text
			# §2.9's rule, applied to land: the button is disabled while the sim
			# would refuse it, and the line under it names the first reason.
			_action.disabled = not bool(action["enabled"])
	if _action_note == null:
		return
	var blocker: Dictionary = action["blocked_by"]
	if id == LandPanelModel.ACTION_NONE or blocker.is_empty():
		_action_note.text = ""
		_action_note.visible = false
		return
	_action_note.visible = true
	_action_note.text = _text_args("ui_land_action_blocked",
			{"first": str(blocker["title"])})


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

## The real command (doc 12 §4.4) — the UI never predicts success, it re-reads
## whatever the sim answers.
func _on_action_pressed() -> void:
	if model == null or _block_id == "" or _view.is_empty():
		return
	var block_id := _block_id
	var id := StringName(str((_view["action"] as Dictionary)["id"]))
	var result: Dictionary = {}
	match id:
		LandPanelModel.ACTION_BUY:
			result = model.buy(block_id)
			refresh()
			purchased.emit(result)
		LandPanelModel.ACTION_DEVELOP:
			result = model.develop(block_id)
			refresh()
			developed.emit(result)
		_:
			return
	if haptics != null:
		haptics.fire(Haptics.CUE_BUTTON if bool(result.get("ok", false))
				else Haptics.CUE_BLOCKED)


func _on_fix_pressed(fix_target: Dictionary) -> void:
	fix_requested.emit(fix_target)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func action_button() -> Button:
	return _action


func blocker_rows() -> Array[Node]:
	return _blockers.get_children() if _blockers != null else ([] as Array[Node])


func phase_rows() -> Array[Node]:
	return _phases.get_children() if _phases != null else ([] as Array[Node])


func risk_rows() -> Array[Node]:
	return _risks.get_children() if _risks != null else ([] as Array[Node])


func _text(key: String) -> String:
	return UIWidgets.t(config, key)


func _text_args(key: String, args: Dictionary) -> String:
	return UIWidgets.t_args(config, key, args)
