class_name TransformerPanel
extends Control
## **S18 — the transformer panel** (doc 12 §2.25, Wave 25; report 98 §68 RR-207,
## doc 93 §AY2).
##
##     Transformer T-03        ▮L2▮        ✕
##     Working · 96 % condition
##     ████████░░  78 % — getting full
##     117 kW at peak of 150 kW rated, 150 kW at 26 °C
##     ── FED BY ──
##     Feeder F-NORTH · 62 % · room to spare        [ UPGRADE $210 ]
##     Substation SUB-A · 41 % · room to spare
##     ── SERVING 4 BUILDINGS · 117 kW ──
##     House · L2 · 18 kW · standard · lit          ›
##     Shop · L1 · 34 kW · standard · lit           ›
##     …
##     ── the verbs ──
##     [ CALL A CREW  $150 ]  [ UPGRADE  $1,100 → 150 kW ]  [ REMOVE ]
##
## Dumb by construction, like every other screen in this folder:
## `TransformerPanelModel` computes every value and `RequirementFormatter` writes
## every refusal, so this file holds no price, no threshold and no copy
## (constitution §3, doc 12 §1). It decides three things and nothing else: what
## is on screen, which verb is drawn first (`model.focus_of`), and that a
## purchase takes two taps.
##
## It lives on `PanelLayer` beside the building panel and S4, which means it
## obeys the same two rules they do: one panel at a time
## (`UIWidgets.close_siblings`), and the edge affordances stand down while it is
## up (`UIWidgets.any_sibling_open`, D-16).

signal closed
## The sim's own `{ok, reason_code, payload}` for each verb, so the shell
## re-reads the city rather than predicting what moved — the same shape S5's
## `upgraded` / `grid_demolished` carry.
signal repaired(component_id: String, result: Dictionary)
signal upgraded(component_id: String, result: Dictionary)
signal demolished(component_id: String, result: Dictionary)
## A customer row was tapped: go and look at that building. The shell decides
## whether that is a camera move, a panel, or both (doc 12 §4.5's jump
## affordance) — this view only says which building and where.
signal customer_selected(sim_id: String, world_pos: Vector3)

const PALETTE_TYPE := "Palette"
## Every panel in the deck closes with this glyph and names itself in the tooltip.
const CLOSE_GLYPH := "✕"
## The affordance on a row that goes somewhere. Same glyph the building panel's
## one-row POWER summary uses, because they are the same promise.
const CHEVRON := "›"

var config: UIConfig
var model: TransformerPanelModel
## Set by `UIRoot`; a refusal buzzes and a commit taps (doc 12 §2.14).
var haptics: Haptics

var _panel: PanelContainer
var _body: VBoxContainer
var _title: Label
var _close: Button
var _level: Label
var _reading: Label
var _meter: MeterBar
var _meter_note: Label
var _upstream_title: Label
var _upstream: VBoxContainer
var _customers_title: Label
var _customers: VBoxContainer
var _verbs: VBoxContainer
var _footer: HFlowContainer

var _repair_button: Button
var _upgrade_button: Button
var _remove_button: Button
var _customer_rows: Dictionary = {}   # sim_id -> Button
var _upstream_rows: Dictionary = {}   # component id -> Button

var _component_id := ""
var _view: Dictionary = {}
## **The building a `FIX_POWER` route asked about**, as `FixRouter.route`'s own
## `needs` block (Wave 28 fix pass, doc 12 D-123(c)). Empty when the player
## opened this pad by tapping it, which is the ordinary case and changes nothing.
var _asked_about: Dictionary = {}
var _touch_min := 48.0
var _spacing := 8.0
## The two-tap confirms. Both are cleared by any change of selection, because a
## row armed on one transformer must never fire on the next (S5's own rule).
var _repair_armed := ""
var _remove_armed := ""


func setup(cfg: UIConfig = null, p_model: TransformerPanelModel = null) -> void:
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
		# The root's parse, not a second one — see `CityHUD._ready()`.
		setup(UIRoot.config_from(self))


## The whole surface, in code. **Nothing is authored in `ui_root.tscn` but the
## empty `Control`**, which is doc 12 test 19's rule taken one step further than
## S4 or S5 take it: those two carry a node tree in the scene and a theme in
## code, and every wave since has had to keep the two in step by hand. A screen
## whose structure is one function cannot drift from its own bindings.
##
## Idempotent: `setup()` runs twice in the real shell, once from
## `UIRoot.bring_up_screens()` and once from `game/main.gd`.
func _build_static() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel = get_node_or_null("Panel") as PanelContainer
	if _panel == null:
		_panel = PanelContainer.new()
		_panel.name = "Panel"
		_panel.mouse_filter = Control.MOUSE_FILTER_STOP
		# The right-edge column, same anchors S5 uses so the two occupy exactly
		# the same rectangle and neither can peek out from behind the other.
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
	# PA-47's ruling, inherited: a `ScrollContainer` whose horizontal mode is
	# DISABLED takes its content's width as its own minimum, so one over-wide row
	# pushes the whole side panel off the screen. Never scroll sideways, never
	# let the content set the width.
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
				_text("ui_transformer_close", "Close"),
				Vector2(_touch_min, _touch_min), &"GhostButton")
		header.add_child(_close)
	if not _close.pressed.is_connected(close):
		_close.pressed.connect(close)

	_level = _ensure_label(_body, "Level", &"LegendRow")
	_meter = _body.get_node_or_null("Meter") as MeterBar
	if _meter == null:
		_meter = MeterBar.new()
		_meter.name = "Meter"
		_meter.custom_minimum_size = Vector2(0.0, maxf(8.0, _touch_min * 0.25))
		_meter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_body.add_child(_meter)
	_reading = _ensure_label(_body, "Reading", &"LegendRow", true)
	_meter_note = _ensure_label(_body, "MeterNote", &"LegendRow", true)

	_upstream_title = _ensure_label(_body, "UpstreamTitle", &"")
	_upstream = _ensure_box(_body, "Upstream")
	_customers_title = _ensure_label(_body, "CustomersTitle", &"")
	_customers = _ensure_box(_body, "Customers")
	_verbs = _ensure_box(_body, "Verbs")

	# The two verbs that must never be below the fold live on `Frame`, OUTSIDE
	# the scroller — S5's PA-47 pattern, for S5's reason. A grown city's widest
	# transformer feeds 17 buildings (doc 92 §65.1), so the customer list alone
	# is most of a phone and the player would have to go looking for the crew.
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
# Selection — the same semantics S5 has, because the player asked for
# "just like a building does"
# ===========================================================================

func is_open() -> bool:
	return _panel != null and _panel.visible


func selected_id() -> String:
	return _component_id


## Tap a transformer → this. An id the grid no longer carries closes the panel
## rather than showing a stale one (§2.2: the panel exits on "tap map"), which is
## also what happens the instant the REMOVE row on this very panel fires.
## `asked_about` is `FixRouter.route(…, FIX_POWER)`'s `needs` block — the
## building whose checklist row sent the player here, and what its next level
## asks of this pad. `{}` for a plain tap.
func show_component(component_id: String, asked_about: Dictionary = {}) -> void:
	if model == null:
		return
	if component_id != _component_id:
		_repair_armed = ""
		_remove_armed = ""
	_asked_about = asked_about
	var view := model.view(component_id)
	if not bool(view.get("exists", false)):
		close()
		return
	UIWidgets.close_siblings(self)
	_component_id = component_id
	_view = view
	if _panel != null:
		_panel.visible = true
	_render(view)


## Re-read the sim for the open transformer — after a tick, a purchase, or a
## crew arriving. Cheap enough to call on every hourly refresh: the whole view
## is one `PowerActions.transformer_block`, which is read-only and allocates one
## row per customer.
func refresh() -> void:
	if _component_id != "" and is_open():
		# **The question survives a refresh; the ANSWER is re-asked** (Wave 28 fix
		# pass). `_asked_about` is `FixRouter`'s reading for the building whose
		# checklist row sent the player here, taken at route time — and the most
		# likely thing to happen next is that the player buys the transformer on
		# this very panel, which changes it. Carrying the snapshot forward would
		# leave a stale sentence under the button that had just fixed it, and
		# dropping it would make the line vanish for no reason the player can
		# see. So the id is kept and the block is re-derived from the sim.
		var asked := _asked_about
		var sim_id := str(asked.get("sim_id", ""))
		if sim_id != "" and model != null and model.sim != null:
			asked = PowerActions.rung_needed_for_next_level(model.sim, sim_id)
		show_component(_component_id, asked)


func close() -> void:
	if _panel != null:
		_panel.visible = false
	_component_id = ""
	_view = {}
	_repair_armed = ""
	_remove_armed = ""
	closed.emit()


func view() -> Dictionary:
	return _view


# ===========================================================================
# Render
# ===========================================================================

func _render(v: Dictionary) -> void:
	_apply_panel_width()
	if _title != null:
		_title.text = "%s %s" % [_text(str(v["title_key"]), str(v["title_fallback"])),
				str(v["component"])]
		_title.tooltip_text = _title.text
		UIWidgets.elide(_title, _touch_min * 2.0)
	if _level != null:
		# Level pips, the working/failed word, and the condition — the same three
		# facts S5's header carries, in the same order, so a player reads the two
		# panels the same way (A5: the digits and the word carry it, not colour).
		_level.text = _text_args("ui_transformer_level",
				{"pips": str(v["level_pips"]),
				"state": _text(str(v["state_key"]), str(v["state"])),
				"condition": str(v["condition_text"])},
				str(v["condition_text"]))
		_apply_state_color(_level, _distress_state(int(v["distress"])))
	if _meter != null:
		_meter.set_value(float(v["meter01"]), StringName(String(v["meter_state"])))
		_meter.tooltip_text = _text_args("ui_transformer_meter_tip",
				{"peak": str(v["peak_text"]), "capacity": str(v["capacity_text"])},
				"%s / %s" % [v["peak_text"], v["capacity_text"]])
	if _reading != null:
		_reading.text = _text_args("ui_transformer_reading",
				{"pct": RequirementFormatter.percent(v["load_ratio"]),
				"band": _text(str(v["band_key"]), ""),
				"headroom": str(v["headroom_text"])},
				str(v["headroom_text"]))
		_apply_state_color(_reading, StringName(String(v["band_state"])))
	if _meter_note != null:
		# Doc 04 §2.7's derating, said out loud: a player who reads "150 kW" on
		# the build card and 132 kW here has to be told it is the weather and not
		# a bug, and a unit that is NOT derated must not claim it is.
		_meter_note.text = _text_args(
				"ui_transformer_derated" if bool(v["derated"]) else "ui_transformer_rated",
				{"peak": str(v["peak_text"]), "now": str(v["load_text"]),
				"capacity": str(v["capacity_text"]),
				"nameplate": str(v["nameplate_text"]),
				"temp": _temperature(float(v["ambient_c"])),
				"hour": int(v["peak_hour"])},
				str(v["capacity_text"]))
	_render_upstream(v.get("upstream", []) as Array)
	_render_customers(v)
	_render_verbs(v)


## The right-edge column, solved against the display it is on — `UIWidgets.
## side_panel_width`, the same call S5 makes, so the two panels are the same
## width at every box and swapping between them does not move the screen.
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


## FED BY — the feeder and the substation behind this pad, with the feeder's own
## UPGRADE button. **These rows MOVED here from the building panel** (doc 12
## D-115): they are facts about the transformer, and drawing them on every house
## it feeds is what made S5 76 rows long (doc 92 §65.4).
func _render_upstream(rows: Array) -> void:
	if _upstream == null:
		return
	UIWidgets.release_children(_upstream)
	_upstream_rows.clear()
	_upstream_title.visible = not rows.is_empty()
	_upstream.visible = not rows.is_empty()
	if rows.is_empty():
		return
	_upstream_title.text = _text("ui_transformer_fed_by", "")
	for entry: Variant in rows:
		var hop: Dictionary = entry
		var id := str(hop["id"])
		var row := VBoxContainer.new()
		row.name = "Hop_" + id
		row.add_theme_constant_override(&"separation", int(_spacing))
		var line := UIWidgets.label("Line", _text_args("ui_transformer_hop",
				{"kind": _text(str(hop["name_key"]), str(hop["kind"])), "id": id,
				"pct": RequirementFormatter.percent(hop["load_ratio"]),
				"band": _text(str(hop["band_key"]), ""),
				"headroom": str(hop["headroom_text"])},
				"%s %s" % [hop["kind"], id]), &"LegendRow", true)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		line.tooltip_text = id
		_apply_state_color(line, StringName(String(hop["band_state"])))
		row.add_child(line)
		var upgrade: Dictionary = hop.get("upgrade", {})
		if bool(upgrade.get("available", false)):
			var label := _text_args("ui_power_upgrade",
					{"cost": str(upgrade["cost_text"]),
					"capacity": str(upgrade["to_capacity_text"])},
					str(upgrade["cost_text"]))
			var button := UIWidgets.button("Upgrade_" + id, label, label,
					Vector2(_touch_min * 2.0, _touch_min), &"GhostButton")
			button.disabled = not bool(upgrade["ok"])
			button.pressed.connect(_on_upstream_upgrade.bind(id))
			row.add_child(button)
			_upstream_rows[id] = button
			for check: Variant in (upgrade.get("checklist", []) as Array):
				row.add_child(_check_row(check))
		_upstream.add_child(row)


## SERVING — the list the grid could not draw before RR-205. Each row is a
## 48 dp target that jumps the camera to that building, and carries the two facts
## a player opening this panel during an outage is looking for: how much it
## draws, and which shed class it is in.
func _render_customers(v: Dictionary) -> void:
	if _customers == null:
		return
	UIWidgets.release_children(_customers)
	_customer_rows.clear()
	var rows: Array = v.get("customer_rows", [])
	if bool(v.get("unattached", false)):
		# A real state, not an error: a pad placed ahead of the houses, or one
		# whose customers were demolished. Said in words rather than drawn as an
		# empty box.
		_customers_title.text = _text("ui_transformer_serving_none", "")
		_apply_state_color(_customers_title, HudModel.STATE_WARNING)
		return
	# A5: the COUNT of dark customers is in the words, not only in the colour —
	# "three of these are dark right now" is the sentence a player opening this
	# panel during an outage came for, and a tinted heading does not say it.
	var dark := int(v["customers_dark"])
	_customers_title.text = _text_args(
			"ui_transformer_serving_dark" if dark > 0 else "ui_transformer_serving",
			{"n": int(v["customer_count"]), "kw": str(v["customer_demand_text"]),
			"dark": dark},
			str(v["customer_demand_text"]))
	_apply_state_color(_customers_title,
			HudModel.STATE_CRITICAL if dark > 0 else HudModel.STATE_NORMAL)
	for entry: Variant in rows:
		var row: Dictionary = entry
		var sim_id := str(row["sim_id"])
		var label := _text_args("ui_transformer_customer",
				{"name": _text(str(row["name_key"]), str(row["name_fallback"])),
				"level": int(row.get("level", 1)),
				"kw": str(row["demand_text"]),
				"priority": _text(str(row["priority_key"]), str(row["priority"])),
				"power": _text(str(row["power_key"]), "")},
				str(row["name_fallback"]))
		var button := UIWidgets.button("Customer_" + sim_id,
				"%s  %s" % [label, CHEVRON], label,
				Vector2(_touch_min * 2.0, _touch_min), &"GhostButton")
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(_on_customer_pressed.bind(sim_id))
		UIWidgets.paint_state(self, button, StringName(String(row["state"])))
		_customers.add_child(button)
		_customer_rows[sim_id] = button
	# **What the buildings under this pad want it to BE** (Wave 28, doc 12 D-123,
	# doc 93 §BC-3). S18's whole promise is "everything about this transformer in
	# one place", and the decision a player opens it to make is whether to
	# re-rate it — which is a question about the customers, not about the pad.
	# The line is drawn in every state THAT HAS CUSTOMERS: silence when nothing
	# needs a bigger unit reads as "the panel does not know", and the point of the
	# row is that it does. A pad serving NOBODY returned above, where the title
	# already says so, because "nothing under this wants a bigger pad" is a
	# strange thing to tell a player about an empty one. `customer_stranded`
	# wins over the other two, because "no rung carries this" is a wall and the
	# rows below it would send the player shopping for nothing.
	var stranded := str(v.get("customer_stranded", ""))
	var second := str(v.get("customer_needs_second", ""))
	var needs_key := "ui_transformer_customers_fit"
	var needs_state := HudModel.STATE_NORMAL
	var needs_args := {}
	var asked := _asked_about_line()
	if not asked.is_empty():
		# **The building the player came FROM wins the line** (Wave 28 fix pass).
		# A `FIX_POWER` route hands this panel `FixRouter`'s own `needs` reading
		# for the building whose checklist row was tapped, and that building is
		# the question. The summary below answers a different one — "the
		# hungriest customer" — and it cannot be made to answer this one, because
		# the customer list is CAPPED (`customers_hidden` above): the building
		# the player asked about may have no row on this panel at all.
		needs_key = str(asked["key"])
		needs_state = StringName(String(asked["state"]))
		needs_args = asked["args"]
	elif stranded != "":
		needs_key = "ui_transformer_customer_stranded"
		needs_state = HudModel.STATE_CRITICAL
		needs_args = {"id": stranded}
	elif second != "":
		# **A second transformer is a PURCHASE, not a wall** (Wave 28 fix pass,
		# doc 04 §2.9). This pad cannot be re-rated to carry that customer's next
		# level — its own load is already past the top rung — but the fix verb
		# sells a parallel unit beside it that adoption hands the building to, so
		# the line points at the purchase instead of at the ceiling. It sits
		# between the two because it is worse news than "buy a bigger one" and
		# better news than "nothing carries this".
		needs_key = "ui_transformer_customer_needs_second"
		needs_state = HudModel.STATE_WARNING
		needs_args = {"id": second}
	elif bool(v.get("customers_need_bigger", false)):
		needs_key = "ui_transformer_customers_need_rung"
		needs_state = HudModel.STATE_WARNING
		needs_args = {"id": str(v.get("customers_need_rung_for", "")),
				"rung": int(v.get("customers_need_rung", 0)),
				"kw": str(v.get("customers_need_capacity_text", "")),
				"host": int(v.get("level", 1))}
	var wants := UIWidgets.label("CustomersNeedRung",
			_text_args(needs_key, needs_args, ""), &"LegendRow", true)
	wants.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_apply_state_color(wants, needs_state)
	_customers.add_child(wants)
	var hidden := int(v.get("customers_hidden", 0))
	if hidden > 0:
		# The cap is a LAYOUT decision and the panel says so, rather than
		# silently drawing a shorter list than the count above it (doc 92 §65.1).
		var more := UIWidgets.label("More", _text_args("ui_transformer_more",
				{"n": hidden}, "+%d" % hidden), &"LegendRow", true)
		more.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_customers.add_child(more)


## S18's line for the building a `FIX_POWER` route asked about, or `{}` when
## nothing did — or when that building's next level fits on the pad it has, in
## which case the pad's own summary is the more useful sentence.
##
## The three states are `PowerActions.rung_needed`'s three and they are read
## here rather than recomputed: `no_rung_carries` is the only wall (nothing on
## doc 04 §2.2's ladder feeds this building at any price), `needs_second` is
## §2.9's parallel transformer — a purchase `cmd_fix_power_capacity` sells — and
## `needs_bigger` is one rung up on this pad.
func _asked_about_line() -> Dictionary:
	var sim_id := str(_asked_about.get("sim_id", ""))
	if sim_id == "":
		return {}
	if bool(_asked_about.get("no_rung_carries", false)):
		return {"key": "ui_transformer_customer_stranded",
				"state": HudModel.STATE_CRITICAL, "args": {"id": sim_id}}
	if bool(_asked_about.get("needs_second", false)):
		return {"key": "ui_transformer_customer_needs_second",
				"state": HudModel.STATE_WARNING, "args": {"id": sim_id}}
	if bool(_asked_about.get("needs_bigger", false)):
		return {"key": "ui_transformer_customers_need_rung",
				"state": HudModel.STATE_WARNING,
				"args": {"id": sim_id, "rung": int(_asked_about.get("needs_rung", 0)),
				"kw": RequirementFormatter.power(_asked_about.get("needs_capacity_kw", 0.0)),
				"host": int(_asked_about.get("host_level", 0))}}
	return {}


## The three verbs. Order is `model.focus_of()`'s: a FAILED transformer, or one
## with a crew already rolling, opens on REPAIR — because that is the moment the
## player tapped it (doc 93 §AY2).
func _render_verbs(v: Dictionary) -> void:
	if _verbs == null or _footer == null:
		return
	UIWidgets.release_children(_verbs)
	UIWidgets.release_children(_footer)
	_repair_button = null
	_upgrade_button = null
	_remove_button = null
	if StringName(str(v["focus"])) == TransformerPanelModel.FOCUS_REPAIR:
		_build_repair(v.get("repair", {}) as Dictionary)
		_build_upgrade(v.get("upgrade", {}) as Dictionary)
	else:
		_build_upgrade(v.get("upgrade", {}) as Dictionary)
		_build_repair(v.get("repair", {}) as Dictionary)
	_build_remove(v.get("demolish", {}) as Dictionary)


## CALL A CREW. Two states and they are different screens, not two labels:
## a crew already on it draws a PROGRESS BAR and an ETA (the question is *when*),
## and no crew draws a two-tap purchase with its price on its face.
func _build_repair(repair: Dictionary) -> void:
	if not bool(repair.get("available", false)):
		return
	if bool(repair.get("in_flight", false)):
		var crew := UIWidgets.label("RepairCrew", _text_args("ui_transformer_crew_on_it",
				{"eta": UIWidgets.duration_text(config, float(repair["eta_gm"])),
				"crews": int(repair["crewed"])},
				""), &"LegendRow", true)
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
	var armed := _repair_armed == _component_id and _component_id != ""
	var cost := str(repair["cost_text"])
	var label := _text_args("ui_transformer_repair_confirm" if armed
			else "ui_transformer_repair",
			{"cost": cost, "target": str(repair["repair_target_text"]),
			"crew": _text(str(repair["crew_key"]), "")}, cost)
	_repair_button = UIWidgets.button("Repair", label, label,
			Vector2(_touch_min * 2.0, _touch_min),
			&"PrimaryFAB" if bool(repair.get("failed", false)) else &"GhostButton")
	_repair_button.disabled = not bool(repair.get("ok", false))
	_repair_button.pressed.connect(_on_repair_pressed)
	_footer.add_child(_repair_button)
	var note := UIWidgets.label("RepairNote", _text_args("ui_transformer_repair_note",
			{"damage": str(repair["damage_text"]),
			"target": str(repair["repair_target_text"]),
			"customers": int(repair["customers"])}, ""), &"LegendRow", true)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_verbs.add_child(note)
	for check: Variant in (repair.get("checklist", []) as Array):
		_verbs.add_child(_check_row(check))


## UPGRADE — `cmd_upgrade_grid_component`, the verb Wave 17 shipped on the
## building panel. It is the same button; it has moved to the thing it upgrades.
func _build_upgrade(upgrade: Dictionary) -> void:
	if not bool(upgrade.get("available", false)):
		return
	var label := _text_args("ui_power_upgrade",
			{"cost": str(upgrade["cost_text"]),
			"capacity": str(upgrade["to_capacity_text"])},
			str(upgrade["cost_text"]))
	_upgrade_button = UIWidgets.button("Upgrade", label, label,
			Vector2(_touch_min * 2.0, _touch_min), &"GhostButton")
	_upgrade_button.disabled = not bool(upgrade["ok"])
	_upgrade_button.pressed.connect(_on_upgrade_pressed)
	_footer.add_child(_upgrade_button)
	for check: Variant in (upgrade.get("checklist", []) as Array):
		_verbs.add_child(_check_row(check))


## REMOVE / MOVE — the armed-confirm row Wave 17 put on the hop, on the thing it
## removes. The first tap names the casualties and what moving it back costs; the
## second one takes the street's lights out.
func _build_remove(quote: Dictionary) -> void:
	if not bool(quote.get("available", false)):
		return
	var armed := _remove_armed == _component_id and _component_id != ""
	var label := _text_args("ui_power_remove_confirm" if armed else "ui_power_remove",
			{"refund": str(quote["refund_text"]), "dark": int(quote["stranded"]),
			"move": str(quote["move_cost_text"])}, str(quote["refund_text"]))
	_remove_button = UIWidgets.button("Remove", label, label,
			Vector2(_touch_min * 2.0, _touch_min), &"DangerButton")
	_remove_button.pressed.connect(_on_remove_pressed)
	_verbs.add_child(_remove_button)


func _check_row(entry: Variant) -> Control:
	var row: Dictionary = entry
	var line := UIWidgets.label("Check", "%s  %s" % [str(row["glyph"]),
			str(row["text"])], &"LegendRow", true)
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_apply_state_color(line, StringName(str(row.get("state", HudModel.STATE_NORMAL))))
	return line


# ===========================================================================
# The verbs, each two taps or none
# ===========================================================================

func _on_repair_pressed() -> void:
	if model == null or _component_id == "":
		return
	if _repair_armed != _component_id:
		# Doc 12 §2.7's "never spend on one tap". The first tap re-labels the
		# button with the confirm copy; the second calls the verb.
		_repair_armed = _component_id
		call_deferred("refresh")
		return
	var component := _component_id
	_repair_armed = ""
	var result := model.repair(component)
	# Deferred: the button that fired this lives inside the block a refresh
	# rebuilds, and freeing an emitter while its own signal is in flight is the
	# crash S5's `_on_fix_pressed` documents.
	call_deferred("refresh")
	repaired.emit(component, result)


func _on_upgrade_pressed() -> void:
	if model == null or _component_id == "":
		return
	var component := _component_id
	var result := model.upgrade(component)
	call_deferred("refresh")
	upgraded.emit(component, result)


func _on_upstream_upgrade(component_id: String) -> void:
	if model == null:
		return
	var result := model.upgrade(component_id)
	call_deferred("refresh")
	upgraded.emit(component_id, result)


func _on_remove_pressed() -> void:
	if model == null or _component_id == "":
		return
	if _remove_armed != _component_id:
		_remove_armed = _component_id
		call_deferred("refresh")
		return
	var component := _component_id
	_remove_armed = ""
	var result := model.demolish(component)
	# The panel CLOSES on success, exactly as S5 does after a demolition: the
	# thing it was describing is gone.
	if bool(result.get("ok", false)):
		call_deferred("close")
	else:
		call_deferred("refresh")
	demolished.emit(component, result)


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


func upstream_upgrade_button(component_id: String) -> Button:
	return _upstream_rows.get(component_id, null)


func body_path() -> String:
	return "Panel/Frame/Scroll/Body"


# ===========================================================================
# Copy and colour
# ===========================================================================

## §5.10's band as a doc 12 §2.5 data state. Two of the six bands are not a LOAD
## reading at all — DARK and FAILED are states — and they take the offline and
## critical tokens rather than a colour read off a ratio.
static func _distress_state(distress: int) -> StringName:
	match distress:
		PowerGrid.DISTRESS_FAILED:
			return HudModel.STATE_CRITICAL
		PowerGrid.DISTRESS_DARK:
			return HudModel.STATE_OFFLINE
		PowerGrid.DISTRESS_SEVERE, PowerGrid.DISTRESS_TROUBLED:
			return HudModel.STATE_CRITICAL
		PowerGrid.DISTRESS_STRESSED:
			return HudModel.STATE_WARNING
	return HudModel.STATE_NORMAL


## Today's ambient, as the one string the derating line splices. Whole degrees:
## a transformer's plate moves with the weather in steps a player can feel, and a
## tenth of a degree on a panel is a number nobody reads. The UNIT lives in
## `data/strings.en.json`'s template, not here — this supplies the figure.
func _temperature(celsius: float) -> String:
	return _text_args("ui_transformer_temp", {"c": int(round(celsius))},
			"%d °C" % int(round(celsius)))


func _text(key: String, fallback: String) -> String:
	return UIWidgets.t(config, key, fallback)


func _text_args(key: String, args: Dictionary, fallback: String) -> String:
	return UIWidgets.t_args(config, key, args, fallback)


func _apply_state_color(control: Control, state: StringName) -> void:
	UIWidgets.paint_state(self, control, state)
