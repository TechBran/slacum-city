class_name WaterPanel
extends Control
## **S19 — the water panel** (doc 12 D-124, Wave 28; doc 93 §BD1, doc 92 §69).
##
##     Pump WTR-1-PMP        ▮L1▮        ✕
##     Working · 87 % condition · 40.0 m³/h rated · 60 kW
##     ████████░░  zone P-072-PMP · 57 % of supply asked for · normal
##     supply 73.5 m³/h · demand 42.1 m³/h · spare 31.3 m³/h · buffer —
##     ── THE CHAIN ──
##     Intake      ███████░░  94.2 m³/h
##     Treatment   ██████░░░  74.6 m³/h   ← BINDS
##     Pumps       ██████░░░  73.6 m³/h  (80.0 rated)
##     Mains       ██████████ 214.0 m³/h
##     ▸ Treatment binds this zone at 74.6 m³/h — raise WTR-1-TRT
##     ── 3 MAINS OPEN · LEAKING 40.1 m³/h ──
##     M_SOUTH · broken · 13.4 m³/h  [ CALL A CREW $13,614 ] [ ISOLATE ]
##     ── SERVING 89 BUILDINGS · 46 UNDER THE UPGRADE GATE ──
##     House · 32 % · 7 tiles from a main   ›
##     ── the verbs ──
##     [ CALL A CREW $… ]  [ UPGRADE $51,750 → 98.0 m³/h ]  [ REMOVE ]
##
## Dumb by construction, like every other screen in this folder:
## `WaterPanelModel` computes every value and `RequirementFormatter` writes every
## refusal, so this file holds no price, no threshold and no copy (constitution
## §3, doc 12 §1). It decides three things and nothing else: what is on screen,
## which verb is drawn first (`model.focus_of`), and that a purchase takes two
## taps.
##
## It lives on `PanelLayer` beside S5, S4 and S18, which means it obeys the same
## two rules they do: one panel at a time (`UIWidgets.close_siblings`), and the
## edge affordances stand down while it is up (`UIWidgets.any_sibling_open`).

signal closed
## The sim's own `{ok, reason_code, payload}` for each verb, so the shell
## re-reads the city rather than predicting what moved — S18's shape exactly.
signal repaired(asset_id: String, result: Dictionary)
signal upgraded(node_id: String, result: Dictionary)
signal removed(node_id: String, result: Dictionary)
signal main_valved(edge_id: String, action: StringName, result: Dictionary)
## A served-building row was tapped: go and look at it. The shell decides whether
## that is a camera move, a panel, or both (doc 12 §4.5).
signal customer_selected(sim_id: String, world_pos: Vector3)

const CLOSE_GLYPH := "✕"
const CHEVRON := "›"
## The glyph that marks the binding stage. A5 / constitution §11: the arrow and
## the word carry it, the tint is the third channel.
const BINDS_GLYPH := "◀"

var config: UIConfig
var model: WaterPanelModel
## Set by `UIRoot`; a refusal buzzes and a commit taps (doc 12 §2.14).
var haptics: Haptics

var _panel: PanelContainer
var _body: VBoxContainer
var _title: Label
var _close: Button
var _level: Label
var _meter: MeterBar
var _reading: Label
var _chain_title: Label
var _chain: VBoxContainer
var _advice: Label
var _breaks_title: Label
var _breaks: VBoxContainer
var _customers_title: Label
var _customers: VBoxContainer
var _verbs: VBoxContainer
var _footer: HFlowContainer

var _repair_button: Button
var _upgrade_button: Button
var _remove_button: Button
var _customer_rows: Dictionary = {}   # sim_id -> Button
var _break_rows: Dictionary = {}      # edge id -> Button

var _node_id := ""
var _view: Dictionary = {}
var _touch_min := 48.0
var _spacing := 8.0
## The two-tap confirms. Cleared by any change of selection, because a row armed
## on one pump must never fire on the next (S5's own rule).
var _repair_armed := ""
var _remove_armed := ""
var _break_armed := ""


func setup(cfg: UIConfig = null, p_model: WaterPanelModel = null) -> void:
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
	_build_static()
	close()


func _ready() -> void:
	if config == null:
		setup(UIRoot.config_from(self))


## The whole surface, in code — S18's rule, for S18's reason: a screen whose
## structure is one function cannot drift from its own bindings. Idempotent.
func _build_static() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel = get_node_or_null("Panel") as PanelContainer
	if _panel == null:
		_panel = PanelContainer.new()
		_panel.name = "Panel"
		_panel.mouse_filter = Control.MOUSE_FILTER_STOP
		_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
		_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		add_child(_panel)
	_panel.theme_type_variation = &"SidePanel"
	_panel.custom_minimum_size = Vector2(
			UIConfig.get_num(config.layout(), "side_panel_w_dp", 300.0), 0.0)

	var frame := _panel.get_node_or_null("Frame") as VBoxContainer
	if frame == null:
		frame = VBoxContainer.new()
		frame.name = "Frame"
		_panel.add_child(frame)
	frame.add_theme_constant_override(&"separation", int(_spacing))

	var scroll := frame.get_node_or_null("Scroll") as ScrollContainer
	if scroll == null:
		scroll = ScrollContainer.new()
		scroll.name = "Scroll"
		frame.add_child(scroll)
	# PA-47: never scroll sideways, never let the content set the width.
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.custom_minimum_size.x = 0.0
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_body = scroll.get_node_or_null("Body") as VBoxContainer
	if _body == null:
		_body = VBoxContainer.new()
		_body.name = "Body"
		_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(_body)
	_body.add_theme_constant_override(&"separation", int(_spacing))

	var header := _body.get_node_or_null("Header") as HBoxContainer
	if header == null:
		header = HBoxContainer.new()
		header.name = "Header"
		_body.add_child(header)
	header.add_theme_constant_override(&"separation", int(_spacing))

	_title = _ensure_label(header, "Title", &"")
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_close = header.get_node_or_null("Close") as Button
	if _close == null:
		_close = UIWidgets.button("Close", CLOSE_GLYPH,
				_text("ui_water_close", "Close"),
				Vector2(_touch_min, _touch_min), &"GhostButton")
		header.add_child(_close)
	if not _close.pressed.is_connected(close):
		_close.pressed.connect(close)

	_level = _ensure_label(_body, "Level", &"LegendRow", true)
	_meter = _body.get_node_or_null("Meter") as MeterBar
	if _meter == null:
		_meter = MeterBar.new()
		_meter.name = "Meter"
		_meter.custom_minimum_size = Vector2(0.0, maxf(8.0, _touch_min * 0.25))
		_meter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_body.add_child(_meter)
	_reading = _ensure_label(_body, "Reading", &"LegendRow", true)

	_chain_title = _ensure_label(_body, "ChainTitle", &"")
	_chain = _ensure_box(_body, "Chain")
	_advice = _ensure_label(_body, "Advice", &"LegendRow", true)
	_breaks_title = _ensure_label(_body, "BreaksTitle", &"")
	_breaks = _ensure_box(_body, "Breaks")
	_customers_title = _ensure_label(_body, "CustomersTitle", &"")
	_customers = _ensure_box(_body, "Customers")
	_verbs = _ensure_box(_body, "Verbs")

	# The verbs that must never be below the fold live on `Frame`, OUTSIDE the
	# scroller — S5's PA-47 pattern, for S5's reason. The player's own zone
	# serves 89 buildings (doc 92 §69.1), so the served list alone is eleven
	# screens and the crew button would be somewhere at the bottom of them.
	_footer = frame.get_node_or_null("ActionsFooter") as HFlowContainer
	if _footer == null:
		_footer = HFlowContainer.new()
		_footer.name = "ActionsFooter"
		frame.add_child(_footer)
	_footer.add_theme_constant_override(&"h_separation", int(_spacing))
	_footer.add_theme_constant_override(&"v_separation", int(_spacing))


func _ensure_label(host: Node, node_name: String, variation: StringName,
		wrap: bool = false) -> Label:
	var label := host.get_node_or_null(node_name) as Label
	if label == null:
		label = UIWidgets.label(node_name, "", variation, wrap)
		host.add_child(label)
	if wrap:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _ensure_box(host: Node, node_name: String) -> VBoxContainer:
	var box := host.get_node_or_null(node_name) as VBoxContainer
	if box == null:
		box = VBoxContainer.new()
		box.name = node_name
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		host.add_child(box)
	box.add_theme_constant_override(&"separation", int(_spacing))
	return box


# ===========================================================================
# Selection
# ===========================================================================

func is_open() -> bool:
	return _panel != null and _panel.visible


func selected_id() -> String:
	return _node_id


## Tap a pump, an intake, a treatment train or a tank → this. An id the water
## system no longer carries closes the panel rather than showing a stale one —
## which is what happens the instant the REMOVE row on this very panel fires.
func show_node(node_id: String) -> void:
	if model == null:
		return
	if node_id != _node_id:
		_repair_armed = ""
		_remove_armed = ""
		_break_armed = ""
	var v := model.view(node_id)
	if not bool(v.get("exists", false)):
		close()
		return
	UIWidgets.close_siblings(self)
	_node_id = node_id
	_view = v
	if _panel != null:
		_panel.visible = true
	_render(v)


## Re-read the sim for the open node — after a tick, a purchase, or a crew
## arriving. One `WaterActions.node_block`, which is read-only.
func refresh() -> void:
	if _node_id != "" and is_open():
		show_node(_node_id)


func close() -> void:
	if _panel != null:
		_panel.visible = false
	_node_id = ""
	_view = {}
	_repair_armed = ""
	_remove_armed = ""
	_break_armed = ""
	closed.emit()


func view() -> Dictionary:
	return _view


# ===========================================================================
# Render
# ===========================================================================

func _render(v: Dictionary) -> void:
	_apply_panel_width()
	var zone: Dictionary = v.get("zone", {})
	if _title != null:
		_title.text = "%s %s" % [_text(str(v["title_key"]), str(v["title_fallback"])),
				str(v["node"])]
		_title.tooltip_text = _title.text
		UIWidgets.elide(_title, _touch_min * 2.0)
	if _level != null:
		_level.text = _text_args("ui_water_level",
				{"pips": str(v["level_pips"]),
				"state": _text(str(v["state_key"]), str(v["state"])),
				"condition": str(v["condition_text"]),
				"rated": str(v["rated_text"]),
				"kw": RequirementFormatter.power(v["kw"])},
				str(v["condition_text"]))
		_apply_state_color(_level, _node_state(v))
	if _meter != null:
		_meter.set_value(clampf(float(v.get("meter01", 0.0)), 0.0, 1.0),
				StringName(String(v.get("meter_state", HudModel.STATE_NORMAL))))
		_meter.tooltip_text = _text_args("ui_water_meter_tip",
				{"supply": str(zone.get("supply_text", "")),
				"demand": str(zone.get("demand_text", ""))},
				"%s / %s" % [zone.get("supply_text", ""), zone.get("demand_text", "")])
	_render_reading(zone)
	_render_chain(v)
	_render_breaks(v)
	_render_customers(v)
	_render_verbs(v)


## The zone line: what it supplies, what it is asked for, what is spare and how
## long the tanks would carry it. Doc 05 §5.8's own four numbers, in its words.
func _render_reading(zone: Dictionary) -> void:
	if _reading == null:
		return
	if not bool(zone.get("exists", false)):
		_reading.text = _text("ui_water_no_zone", "")
		_apply_state_color(_reading, HudModel.STATE_CRITICAL)
		return
	_reading.text = _text_args("ui_water_zone_reading",
			{"zone": str(zone["key"]),
			"supply": str(zone["supply_text"]), "demand": str(zone["demand_text"]),
			"spare": str(zone["headroom_text"]),
			"buffer": str(zone["buffer_text"]),
			"band": _text(str(zone["band_key"]), "")},
			str(zone["headroom_text"]))
	_apply_state_color(_reading, StringName(String(zone["band_state"])))


## **THE CHAIN** — doc 05 §2.5's four terms, one row each, with the binding one
## named in words as well as marked. This is the read doc 92 §67.4 bought 118
## pumps for the want of.
func _render_chain(v: Dictionary) -> void:
	if _chain == null or _chain_title == null:
		return
	UIWidgets.release_children(_chain)
	var rows: Array = v.get("chain", [])
	_chain_title.text = _text("ui_water_chain", "")
	_chain_title.visible = not rows.is_empty()
	for entry: Variant in rows:
		var row: Dictionary = entry
		var line := UIWidgets.label("Stage_" + str(row["stage"]),
				_text_args("ui_water_chain_binds" if bool(row["binding"])
						else "ui_water_chain_row",
				{"stage": _text(str(row["name_key"]), str(row["stage"])),
				"m3h": str(row["text"]), "glyph": BINDS_GLYPH,
				"rated": str(row["rated_text"])},
				"%s %s" % [row["stage"], row["text"]]), &"LegendRow", true)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_apply_state_color(line, StringName(String(row["state"])))
		_chain.add_child(line)
		var bar := MeterBar.new()
		bar.name = "Bar_" + str(row["stage"])
		bar.custom_minimum_size = Vector2(0.0, maxf(6.0, _touch_min * 0.18))
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.set_value(clampf(float(row["meter01"]), 0.0, 1.0),
				StringName(String(row["state"])))
		_chain.add_child(bar)
	if _advice != null:
		var advice: Dictionary = v.get("advice", {})
		var args: Dictionary = {}
		for key: Variant in (advice.get("args", {}) as Dictionary):
			var value: Variant = (advice["args"] as Dictionary)[key]
			# An arg whose value is itself a string KEY resolves here, so the
			# sentence reads "Treatment binds…" rather than the token.
			args[key] = _text(str(value), str(value)) if str(value).begins_with("ui_") \
					else value
		_advice.text = _text_args(str(advice.get("key", "")), args, "")
		_advice.visible = _advice.text != ""
		_apply_state_color(_advice, HudModel.STATE_WARNING \
				if bool(advice.get("actionable", false)) else HudModel.STATE_NORMAL)


## **THE MAINS THAT ARE OPEN.** Before this panel a break's only surface was doc
## 06's incident drawer, and a break whose incident had gone terminal was on no
## drawer at all — which is how a real save came to be leaking 95 % of its water
## with nothing in the game saying so (doc 92 §69.1, A91-D-145).
func _render_breaks(v: Dictionary) -> void:
	if _breaks == null or _breaks_title == null:
		return
	UIWidgets.release_children(_breaks)
	_break_rows.clear()
	var rows: Array = v.get("break_rows", [])
	_breaks_title.visible = not rows.is_empty()
	if rows.is_empty():
		return
	_breaks_title.text = _text_args("ui_water_breaks",
			{"n": int(v["breaks_total"]), "leak": str(v["leaking_text"])},
			str(v["leaking_text"]))
	_apply_state_color(_breaks_title, HudModel.STATE_CRITICAL)
	for entry: Variant in rows:
		var row: Dictionary = entry
		var edge_id := str(row["edge"])
		var repair: Dictionary = row.get("repair", {})
		var line := UIWidgets.label("Break_" + edge_id, _text_args("ui_water_break_row",
				{"id": edge_id, "state": _text(str(row["state_key"]), str(row["state"])),
				"leak": str(row["leak_text"]), "tier": str(row["tier"])},
				edge_id), &"LegendRow", true)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_apply_state_color(line, HudModel.STATE_CRITICAL)
		_breaks.add_child(line)
		if bool(repair.get("available", false)) and not bool(repair.get("in_flight", false)):
			var armed := _break_armed == edge_id
			var label := _text_args("ui_water_break_repair_confirm" if armed
					else "ui_water_break_repair",
					{"cost": str(repair["cost_text"]), "leak": str(row["leak_text"])},
					str(repair["cost_text"]))
			var button := UIWidgets.button("BreakRepair_" + edge_id, label, label,
					Vector2(_touch_min * 2.0, _touch_min), &"PrimaryFAB")
			button.disabled = not bool(repair.get("ok", false))
			button.pressed.connect(_on_break_repair.bind(edge_id))
			_breaks.add_child(button)
			_break_rows[edge_id] = button
			for check: Variant in (repair.get("checklist", []) as Array):
				_breaks.add_child(_check_row(check))
		elif bool(repair.get("in_flight", false)):
			var crew := UIWidgets.label("BreakCrew_" + edge_id,
					_text_args("ui_water_crew_on_it",
					{"eta": UIWidgets.duration_text(config,
							float(repair.get("eta_gm", -1.0)))}, ""),
					&"LegendRow", true)
			crew.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_apply_state_color(crew, HudModel.STATE_WARNING)
			_breaks.add_child(crew)
		# §2.12's tactical pair, on the main it is about. One control in two
		# moods, exactly as the incident drawer draws it.
		var valve_key := "ui_water_restore" if bool(row.get("can_restore", false)) \
				else "ui_water_isolate"
		var valve_label := _text_args(valve_key,
				{"minutes": int(round(float(row.get("work_minutes", 0.0))))}, "")
		var valve := UIWidgets.button("Valve_" + edge_id, valve_label, valve_label,
				Vector2(_touch_min * 2.0, _touch_min), &"GhostButton")
		valve.pressed.connect(_on_valve_pressed.bind(edge_id,
				bool(row.get("can_restore", false))))
		_breaks.add_child(valve)
	var hidden := int(v.get("breaks_hidden", 0))
	if hidden > 0:
		_breaks.add_child(UIWidgets.label("MoreBreaks",
				_text_args("ui_water_more", {"n": hidden}, "+%d" % hidden),
				&"LegendRow", true))


## SERVING — and the count that matters is not how many, it is how many are under
## doc 02's upgrade gate, because that is the number that says the city cannot
## grow (doc 92 §69.1: 89 of 89 at the fork, 6 of 89 after the repairs).
func _render_customers(v: Dictionary) -> void:
	if _customers == null or _customers_title == null:
		return
	UIWidgets.release_children(_customers)
	_customer_rows.clear()
	var rows: Array = v.get("customer_rows", [])
	_customers_title.visible = int(v.get("customers_total", 0)) > 0
	if rows.is_empty():
		return
	var under := int(v["customers_under_gate"])
	_customers_title.text = _text_args(
			"ui_water_serving_gated" if under > 0 else "ui_water_serving",
			{"n": int(v["customers_total"]), "gated": under},
			str(v["customers_total"]))
	_apply_state_color(_customers_title,
			HudModel.STATE_WARNING if under > 0 else HudModel.STATE_NORMAL)
	for entry: Variant in rows:
		var row: Dictionary = entry
		var sim_id := str(row["sim_id"])
		var label := _text_args("ui_water_customer",
				{"name": _text(str(row["name_key"]), str(row["archetype"])),
				"pct": str(row["pressure_text"]),
				"tiles": int(row["main_distance_tiles"])},
				sim_id)
		var button := UIWidgets.button("Customer_" + sim_id,
				"%s  %s" % [label, CHEVRON], label,
				Vector2(_touch_min * 2.0, _touch_min), &"GhostButton")
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(_on_customer_pressed.bind(sim_id))
		UIWidgets.paint_state(self, button, StringName(String(row["state"])))
		_customers.add_child(button)
		_customer_rows[sim_id] = button
	var hidden := int(v.get("customers_hidden", 0))
	if hidden > 0:
		_customers.add_child(UIWidgets.label("MoreCustomers",
				_text_args("ui_water_more", {"n": hidden}, "+%d" % hidden),
				&"LegendRow", true))


## The three verbs, in `model.focus_of()`'s order.
func _render_verbs(v: Dictionary) -> void:
	if _verbs == null or _footer == null:
		return
	UIWidgets.release_children(_verbs)
	UIWidgets.release_children(_footer)
	_repair_button = null
	_upgrade_button = null
	_remove_button = null
	if StringName(str(v["focus"])) == WaterPanelModel.FOCUS_REPAIR:
		_build_repair(v.get("repair", {}) as Dictionary)
		_build_upgrade(v.get("upgrade", {}) as Dictionary)
	else:
		_build_upgrade(v.get("upgrade", {}) as Dictionary)
		_build_repair(v.get("repair", {}) as Dictionary)
	_build_remove(v.get("remove", {}) as Dictionary)


## CALL A CREW, for the NODE. Two states and they are different screens: a crew
## already on it draws a progress bar and an ETA, and no crew draws a two-tap
## purchase with its price on its face.
func _build_repair(repair: Dictionary) -> void:
	if not bool(repair.get("available", false)):
		return
	if bool(repair.get("in_flight", false)):
		var crew := UIWidgets.label("RepairCrew", _text_args("ui_water_crew_on_it",
				{"eta": UIWidgets.duration_text(config, float(repair["eta_gm"]))}, ""),
				&"LegendRow", true)
		crew.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_apply_state_color(crew, HudModel.STATE_WARNING)
		_verbs.add_child(crew)
		var bar := MeterBar.new()
		bar.name = "RepairProgress"
		bar.custom_minimum_size = Vector2(0.0, maxf(8.0, _touch_min * 0.25))
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.set_value(clampf(float(repair["progress01"]), 0.0, 1.0),
				HudModel.STATE_WARNING)
		_verbs.add_child(bar)
		return
	var armed := _repair_armed == _node_id and _node_id != ""
	var cost := str(repair["cost_text"])
	var label := _text_args("ui_water_repair_confirm" if armed else "ui_water_repair",
			{"cost": cost, "target": str(repair["repair_target_text"]),
			"crew": _text(str(repair["crew_key"]), "")}, cost)
	_repair_button = UIWidgets.button("Repair", label, label,
			Vector2(_touch_min * 2.0, _touch_min),
			&"PrimaryFAB" if bool(repair.get("down", false)) else &"GhostButton")
	_repair_button.disabled = not bool(repair.get("ok", false))
	_repair_button.pressed.connect(_on_repair_pressed)
	_footer.add_child(_repair_button)
	var note := UIWidgets.label("RepairNote", _text_args("ui_water_repair_note",
			{"damage": str(repair["damage_text"]),
			"target": str(repair["repair_target_text"]),
			"customers": int(repair["customers"])}, ""), &"LegendRow", true)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_verbs.add_child(note)
	for check: Variant in (repair.get("checklist", []) as Array):
		_verbs.add_child(_check_row(check))


## UPGRADE — doc 05 §6's `cmd_upgrade_water_component`. It is the same button
## `ui/water_actions.gd` has drawn on the SHELL's panel since Wave 11; it is here
## too, on the node it raises, beside the chain row that says whether raising
## this one moves anything.
func _build_upgrade(upgrade: Dictionary) -> void:
	if not bool(upgrade.get("available", false)):
		return
	var label := _text_args("ui_water_upgrade",
			{"cost": str(upgrade["cost_text"]), "level": int(upgrade["to_level"]),
			"kw": RequirementFormatter.power(upgrade["delta_kw"])},
			str(upgrade["cost_text"]))
	_upgrade_button = UIWidgets.button("Upgrade", label, label,
			Vector2(_touch_min * 2.0, _touch_min), &"GhostButton")
	_upgrade_button.disabled = not bool(upgrade["ok"])
	_upgrade_button.pressed.connect(_on_upgrade_pressed)
	_footer.add_child(_upgrade_button)
	for check: Variant in (upgrade.get("checklist", []) as Array):
		_verbs.add_child(_check_row(check))


## REMOVE. The first tap names the casualties — `WTR-1` hosts three nodes and
## removing the building removes all three — and the second one does it.
func _build_remove(quote: Dictionary) -> void:
	if not bool(quote.get("available", false)):
		return
	var armed := _remove_armed == _node_id and _node_id != ""
	var label := _text_args("ui_water_remove_confirm" if armed else "ui_water_remove",
			{"refund": str(quote["refund_text"]), "hosted": int(quote["hosted_nodes"])},
			str(quote["refund_text"]))
	_remove_button = UIWidgets.button("Remove", label, label,
			Vector2(_touch_min * 2.0, _touch_min), &"DangerButton")
	_remove_button.disabled = not bool(quote.get("ok", false))
	_remove_button.pressed.connect(_on_remove_pressed)
	_verbs.add_child(_remove_button)


func _check_row(entry: Variant) -> Control:
	var row: Dictionary = entry
	var line := UIWidgets.label("Check", "%s  %s" % [str(row["glyph"]),
			str(row["text"])], &"LegendRow", true)
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_apply_state_color(line, StringName(str(row.get("state", HudModel.STATE_NORMAL))))
	return line


func _apply_panel_width() -> void:
	if _panel != null:
		_panel.custom_minimum_size = Vector2(
				UIConfig.get_num(config.layout(), "side_panel_w_dp", 300.0), 0.0)


# ===========================================================================
# The verbs, each two taps or none
# ===========================================================================

func _on_repair_pressed() -> void:
	if model == null or _node_id == "":
		return
	if _repair_armed != _node_id:
		_repair_armed = _node_id
		call_deferred("refresh")
		return
	var node_id := _node_id
	_repair_armed = ""
	var result := model.repair(node_id)
	# Deferred: the button that fired this lives inside the block a refresh
	# rebuilds, and freeing an emitter while its own signal is in flight is the
	# crash S5's `_on_fix_pressed` documents.
	call_deferred("refresh")
	repaired.emit(node_id, result)


func _on_break_repair(edge_id: String) -> void:
	if model == null:
		return
	if _break_armed != edge_id:
		_break_armed = edge_id
		call_deferred("refresh")
		return
	_break_armed = ""
	var result := model.repair(edge_id)
	call_deferred("refresh")
	repaired.emit(edge_id, result)


func _on_valve_pressed(edge_id: String, restoring: bool) -> void:
	if model == null:
		return
	var result := model.restore(edge_id) if restoring else model.isolate(edge_id)
	call_deferred("refresh")
	main_valved.emit(edge_id, &"restore" if restoring else &"isolate", result)


func _on_upgrade_pressed() -> void:
	if model == null or _node_id == "":
		return
	var node_id := _node_id
	var result := model.upgrade(node_id)
	call_deferred("refresh")
	upgraded.emit(node_id, result)


func _on_remove_pressed() -> void:
	if model == null or _node_id == "":
		return
	if _remove_armed != _node_id:
		_remove_armed = _node_id
		call_deferred("refresh")
		return
	var node_id := _node_id
	_remove_armed = ""
	var result := model.remove(node_id)
	# The panel CLOSES on success, as S5 and S18 do: the thing it was describing
	# is gone.
	if bool(result.get("ok", false)):
		call_deferred("close")
	else:
		call_deferred("refresh")
	removed.emit(node_id, result)


func _on_customer_pressed(sim_id: String) -> void:
	if model == null:
		return
	var where: Variant = model.customer_world_pos(sim_id)
	# `null` is a STATEMENT — "there is nowhere to jump" — and the row simply
	# does not fire rather than emitting a zero vector the camera would fly to.
	if where is Vector3:
		customer_selected.emit(sim_id, where)


# ===========================================================================
# Handles for tests, coach marks and the audit sweep
# ===========================================================================

func repair_button() -> Button:
	return _repair_button


func upgrade_button() -> Button:
	return _upgrade_button


func remove_button() -> Button:
	return _remove_button


func customer_button(sim_id: String) -> Button:
	return _customer_rows.get(sim_id, null)


func break_repair_button(edge_id: String) -> Button:
	return _break_rows.get(edge_id, null)


func body_path() -> String:
	return "Panel/Frame/Scroll/Body"


# ===========================================================================
# Copy and colour
# ===========================================================================

## Doc 05's `WaterNode.state` as a doc 12 §2.5 data state. `offline_manual` is
## OFFLINE and not CRITICAL: a node held out of service before its shell finishes
## is not a fault, and painting it red would teach the player to fear a state
## every new pump passes through.
static func _node_state(v: Dictionary) -> StringName:
	match String(v.get("state", "ok")):
		"failed":
			return HudModel.STATE_CRITICAL
		"degraded":
			return HudModel.STATE_WARNING
		"offline_manual":
			return HudModel.STATE_OFFLINE
	if bool(v.get("tripped", false)):
		return HudModel.STATE_WARNING
	return HudModel.STATE_NORMAL


func _text(key: String, fallback: String) -> String:
	return UIWidgets.t(config, key, fallback)


func _text_args(key: String, args: Dictionary, fallback: String) -> String:
	return UIWidgets.t_args(config, key, args, fallback)


func _apply_state_color(control: Control, state: StringName) -> void:
	UIWidgets.paint_state(self, control, state)
