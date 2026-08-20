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
## §2.9 item 6's three verbs. Each carries the sim's own `{ok, reason_code,
## payload}` so the shell can re-read the city rather than guess what moved.
signal repaired(result: Dictionary)             ## `cmd_repair_building` answered
signal priority_set(result: Dictionary)         ## `cmd_set_priority` answered
signal demolished(sim_id: String, result: Dictionary)  ## `cmd_demolish_building`

const PALETTE_TYPE := "Palette"
## §2.9's `L1 L2 ▮L3▮ L4 L5` level pips — glyphs, not copy (A5 redundancy).
const PIP_ON := "▮"
## Every panel in the deck closes with this glyph and names itself in the tooltip.
const CLOSE_GLYPH := "✕"
## §2.9 item 6: `Demolish` is hold-to-confirm, because it is the one button in
## the deck that cannot be undone. The window is `data/ui.json.layout`'s, with
## the doc's own 800 ms as the floor if the key is missing.
const HOLD_TO_CONFIRM_MS_DEFAULT := 800.0

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

## §2.9 item 6's actions row, built in code below `UpgradeButton`.
var _actions: VBoxContainer
var _repair_button: Button
var _repair_note: Label
var _priority_row: HBoxContainer
var _priority_note: Label
var _demolish_button: Button
var _demolish_note: Label

var _sim_id := ""
var _touch_min := 48.0
var _spacing := 8.0
var _view: Dictionary = {}
var _hold_ms := HOLD_TO_CONFIRM_MS_DEFAULT
## Seconds the demolish button has been held, and the label it is overwriting
## while it counts. `< 0` when nothing is being held.
var _hold_elapsed := -1.0
var _priority_buttons: Dictionary = {}   # class name -> Button


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
	_hold_ms = maxf(1.0, UIConfig.get_num(config.layout(), "hold_to_confirm_ms",
			HOLD_TO_CONFIRM_MS_DEFAULT))
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
	_build_actions()


## §2.9 item 6 — `Repair` · `Priority` · `Demolish`, built in code (doc 12 test
## 19: no `theme_override_*` in a scene file) and appended below the upgrade
## block, which is the order the doc lists them in.
##
## Idempotent: `setup()` runs twice in the real shell, once from
## `UIRoot.bring_up_screens()` and once from `game/main.gd`.
func _build_actions() -> void:
	if _upgrade_button == null:
		return
	var body := _upgrade_button.get_parent() as Control
	if body == null:
		return
	var existing := body.get_node_or_null("Actions") as VBoxContainer
	if existing != null:
		# Second `setup()` pass: re-bind rather than rebuild, exactly as
		# `_bind_nodes()` re-binds the authored half.
		_actions = existing
		_repair_button = existing.get_node_or_null("Repair") as Button
		_repair_note = existing.get_node_or_null("RepairNote") as Label
		_priority_note = existing.get_node_or_null("PriorityNote") as Label
		_priority_row = existing.get_node_or_null("Priority") as HBoxContainer
		_demolish_button = existing.get_node_or_null("Demolish") as Button
		_demolish_note = existing.get_node_or_null("DemolishNote") as Label
		return
	_actions = VBoxContainer.new()
	_actions.name = "Actions"
	_actions.add_theme_constant_override(&"separation", int(_spacing))
	body.add_child(_actions)

	_repair_button = UIWidgets.button("Repair", _text("ui_building_repair", "REPAIR"),
			_text("ui_building_repair", "REPAIR"),
			Vector2(_touch_min * 2.0, _touch_min), &"GhostButton")
	_repair_button.pressed.connect(request_repair)
	_actions.add_child(_repair_button)
	_repair_note = UIWidgets.label("RepairNote", "", &"LegendRow", true)
	_actions.add_child(_repair_note)

	_priority_note = UIWidgets.label("PriorityNote", "", &"LegendRow", true)
	_actions.add_child(_priority_note)
	_priority_row = HBoxContainer.new()
	_priority_row.name = "Priority"
	_priority_row.add_theme_constant_override(&"separation", int(_spacing))
	_actions.add_child(_priority_row)

	_demolish_button = UIWidgets.button("Demolish",
			_text("ui_building_demolish", "DEMOLISH"),
			_text("ui_building_demolish_hint", "Hold to confirm"),
			Vector2(_touch_min * 2.0, _touch_min), &"DangerButton")
	# Hold-to-confirm, so this is press/release rather than `pressed` — the one
	# button in the deck that cannot be undone must not fire on a mis-tap.
	_demolish_button.button_down.connect(_on_demolish_down)
	_demolish_button.button_up.connect(_on_demolish_up)
	_actions.add_child(_demolish_button)
	_demolish_note = UIWidgets.label("DemolishNote", "", &"LegendRow", true)
	_actions.add_child(_demolish_note)


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
	_render_actions(v)


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
# §2.9 item 6 — the actions row
# ---------------------------------------------------------------------------

## `Repair` · `Priority` · `Demolish`. Every value comes from
## `BuildController.actions_view()`, which asks the three commands themselves
## with `preview = true`; this method decides only what is on screen.
func _render_actions(v: Dictionary) -> void:
	if _actions == null:
		return
	var actions: Dictionary = v.get("actions", {})
	_render_repair(actions.get("repair", {}))
	_render_priority(actions.get("priority", {}))
	_render_demolish(actions.get("demolish", {}))


## The repair affordance. It is **only drawn when there is something to buy** —
## doc 02 §2.6 refuses `E_NOT_DAMAGED` at condition 1.00 — and when it is drawn
## it always names the price and where the condition will land, because "repair"
## with no number is a button, not a decision.
func _render_repair(repair: Dictionary) -> void:
	if _repair_button == null or _repair_note == null:
		return
	var available := bool(repair.get("available", false))
	_repair_button.visible = available
	_repair_note.visible = available
	if not available:
		return
	_repair_button.text = _text_args("ui_building_repair_cost",
			{"cost": str(repair["cost_text"])}, _text("ui_building_repair", "REPAIR"))
	_repair_button.tooltip_text = _repair_button.text
	_repair_button.disabled = not bool(repair["ok"])
	var reason: Dictionary = repair.get("reason", {})
	if not reason.is_empty():
		_repair_note.text = str(reason["body"])
		_apply_state_color(_repair_note, StringName(str(reason["state"])))
		_repair_note.tooltip_text = _repair_note.text
		return
	# `85 % → 100 %`: the condition it is at and the condition doc 02 §2.12's
	# repair target will actually restore it to, which is 0.85 and not 1.00 once
	# a building has been DAMAGED rather than merely worn.
	_repair_note.text = _text_args("ui_building_repair_note",
			{"from": str(repair["condition_text"]), "to": str(repair["target_text"])},
			"%s → %s" % [str(repair["condition_text"]), str(repair["target_text"])])
	_repair_note.tooltip_text = _repair_note.text
	_apply_state_color(_repair_note, &"")


## Doc 04 §2.4's shed tier, as a segmented row — one 48 dp target per class, the
## live one painted the way every other "this one is selected" control in the
## deck is (`BuildSheet.select_category`, the drawer's sort segments).
func _render_priority(priority: Dictionary) -> void:
	if _priority_row == null or _priority_note == null:
		return
	var available := bool(priority.get("available", false))
	_priority_row.visible = available
	_priority_note.visible = available
	if not available:
		BuildingPanel._clear_children(_priority_row)
		_priority_buttons.clear()
		return
	_priority_note.text = _text("ui_building_priority_title", "")
	_priority_note.tooltip_text = _priority_note.text
	var classes: Array = priority.get("classes", [])
	var current := str(priority.get("current", ""))
	if _priority_buttons.size() != classes.size():
		BuildingPanel._clear_children(_priority_row)
		_priority_buttons.clear()
		for entry: Variant in classes:
			var priority_class := str(entry)
			var label := _text(BuildController.priority_key(priority_class),
					priority_class.capitalize())
			var button := UIWidgets.button("Priority_" + priority_class, label, label,
					Vector2(_touch_min, _touch_min), &"TabButton")
			button.toggle_mode = true
			button.pressed.connect(_on_priority_pressed.bind(priority_class))
			_priority_row.add_child(button)
			_priority_buttons[priority_class] = button
	for id: Variant in _priority_buttons:
		var button: Button = _priority_buttons[id]
		var selected := str(id) == current
		button.set_pressed_no_signal(selected)
		UIWidgets.paint_state(self, button, HudModel.STATE_NORMAL if selected else &"")


## §2.9 item 6's hold-to-confirm. The refund is quoted before the hold starts,
## broken out into what the standing capital returns and what the construction
## queue gives back on a job it is cancelling — those are two different pieces of
## news and a player about to lose a half-built tower should read both.
func _render_demolish(demolish: Dictionary) -> void:
	if _demolish_button == null or _demolish_note == null:
		return
	var available := bool(demolish.get("available", false))
	_demolish_button.visible = available
	_demolish_note.visible = available
	if not available:
		return
	_demolish_button.disabled = not bool(demolish["ok"])
	_demolish_button.text = _text("ui_building_demolish", "DEMOLISH")
	_demolish_button.tooltip_text = _text("ui_building_demolish_hint", "Hold to confirm")
	var reason: Dictionary = demolish.get("reason", {})
	if not reason.is_empty():
		_demolish_note.text = str(reason["body"])
		_apply_state_color(_demolish_note, StringName(str(reason["state"])))
		_demolish_note.tooltip_text = _demolish_note.text
		return
	var key := "ui_building_demolish_note_jobs" if int(demolish["cancelled_jobs"]) > 0 \
			else "ui_building_demolish_note"
	_demolish_note.text = _text_args(key, {"refund": str(demolish["refund_text"]),
			"jobs": int(demolish["cancelled_jobs"])}, str(demolish["refund_text"]))
	_demolish_note.tooltip_text = _demolish_note.text
	_apply_state_color(_demolish_note, &"")


func _on_demolish_down() -> void:
	if _demolish_button == null or _demolish_button.disabled:
		return
	_hold_elapsed = 0.0
	set_process(true)


func _on_demolish_up() -> void:
	if _hold_elapsed >= 0.0:
		# Released early: the hold is abandoned and the label goes back to the
		# word. A partial hold demolishes nothing and says nothing.
		_hold_elapsed = -1.0
		_render_demolish((_view.get("actions", {}) as Dictionary).get("demolish", {}))
	set_process(false)


## Counts the hold out and fires once. Runs only while a finger is down, which is
## why `set_process` is toggled rather than left on — a panel that is not being
## held has nothing to advance.
func _process(delta: float) -> void:
	if _hold_elapsed < 0.0 or _demolish_button == null:
		set_process(false)
		return
	_hold_elapsed += delta * 1000.0
	var fraction := clampf(_hold_elapsed / _hold_ms, 0.0, 1.0)
	if fraction < 1.0:
		# The button counts itself down, so the hold is visible on the control
		# being held rather than somewhere else on the panel (A5: the progress is
		# in the label, not only in a colour).
		_demolish_button.text = _text_args("ui_building_demolish_holding",
				{"percent": HudModel.percent_text(fraction * 100.0)},
				_text("ui_building_demolish", "DEMOLISH"))
		return
	_hold_elapsed = -1.0
	set_process(false)
	request_demolish()


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


func request_repair() -> void:
	if controller == null or _sim_id == "":
		return
	var result := controller.repair(_sim_id)
	refresh()
	repaired.emit(result)


func _on_priority_pressed(priority_class: String) -> void:
	if controller == null or _sim_id == "":
		return
	var result := controller.set_priority(_sim_id, priority_class)
	refresh()
	priority_set.emit(result)


## The hold landed. The panel CLOSES on success, because the thing it was
## describing is gone and a stale panel over an empty lot is worse than no panel.
func request_demolish() -> void:
	if controller == null or _sim_id == "":
		return
	var target := _sim_id
	var result := controller.demolish(target)
	if bool(result["ok"]):
		close()
	else:
		refresh()
	demolished.emit(target, result)


## `Fix this →`. `E_CONDITION` is answered HERE rather than by the shell: its fix
## target is the building the player already has open, so focusing the camera on
## it — which is all the shell can do — moves nothing. The row's remedy is a
## repair, so the row buys one.
func _on_fix_pressed(fix_target: Dictionary) -> void:
	if StringName(str(fix_target.get("kind", ""))) == RequirementFormatter.FIX_REPAIR:
		if controller == null or _sim_id == "":
			return
		# **Not `request_repair()`.** The button that fired this lives INSIDE the
		# checklist, and a refresh rebuilds the checklist — which frees the
		# emitter while its own signal is still being emitted ("Object was freed
		# or unreferenced while a signal is being emitted from it"). The command
		# runs now, because that is what the player asked for; the re-render
		# waits for the frame to finish.
		var result := controller.repair(_sim_id)
		call_deferred("refresh")
		repaired.emit(result)
		return
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
