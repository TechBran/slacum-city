class_name CityDashboard
extends Control
## The city dashboard (doc 12 §2.10, S8), all four tabs: the **Overview** band
## list with a sparkline per vital and a full-size chart under the selected one;
## the **Economy** tab — doc 03's tax detent and the ledger of the hour that just
## settled; **Infrastructure** — doc 04's generation/demand/headroom with the
## worst feeders and transformers, and doc 05's lowest pressure zones; and
## **Response** — doc 06's per-department roster and its rolling response times.
##
## The last two are `data/ui.json.dashboard.tabs` entries like the first two, and
## the two feeds behind them (`feed_infrastructure`, `feed_response`) are plain
## dictionaries the shell fills from `PowerGrid` / `WaterSnapshot` / `FleetSystem`
## — dropping a tab is still an edit to that array and no code change here.
##
## A full-screen modal on `ModalLayer`, so its scrim is the only `STOP` control
## while it is up and Android BACK closes it first (§2.2).
##
## Every number is `DashboardModel`'s, every chart is `HistoryModel`'s geometry
## drawn by `LineChart`, and every tax figure is `BudgetModel`'s — which is to
## say `CitySim.cmd_set_tax_level(level, preview = true)`'s. This file computes
## nothing.

signal deeplink_requested(target: String)          ## "overlay/power", "drawer", …
signal row_selected(row_id: String)
signal tax_applied(level: int, rate: float)
signal sheet_toggled(open: bool)
## The Upkeep band's batch (99-PA PA-33). Carries `cmd_repair_all_worn`'s whole
## result so a shell can toast the count and the price without asking again.
signal repair_all_worn(result: Dictionary)

const SCRIM_ALPHA := 0.55
const STEP_DOWN := "−"
const STEP_UP := "+"

var config: UIConfig
var model: DashboardModel

var _scrim: ColorRect
var _panel: PanelContainer
var _title: Label
var _close: Button
var _tabs_box: HBoxContainer
var _content: VBoxContainer

var _tab_buttons: Dictionary = {}    # StringName -> Button
var _row_buttons: Dictionary = {}    # row id -> Button
var _chart: LineChart
var _chart_box: VBoxContainer
var _tax_rate_label: Label
var _tax_note: Label
var _tax_apply: Button
var _tax_happiness: Label
var _tax_growth: Label
## The Upkeep band's three wires (`bind_upkeep`). All three may be invalid — a
## shell that has not bound them draws the band's loss half and no button.
var _repair_all := Callable()
var _upkeep_policy := Callable()
var _upkeep_balance := Callable()
var _touch_min := 48.0
var _spacing := 8.0
var _row_h := 48.0
var _spark_dp := Vector2(64.0, 24.0)
var _chart_dp := Vector2(280.0, 96.0)
var _last_snapshot: Dictionary = {}


func setup(cfg: UIConfig = null, p_model: DashboardModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	model = p_model if p_model != null else DashboardModel.new(config)
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	var block := config.section("dashboard")
	_row_h = maxf(UIConfig.get_num(block, "row_h_dp", 48.0), _touch_min)
	_spark_dp = CityDashboard._size_of(block, "sparkline_dp", Vector2(64.0, 24.0))
	_chart_dp = CityDashboard._size_of(block, "chart_dp", Vector2(280.0, 96.0))
	_bind_nodes()
	_build_static()
	_build_tabs()
	close()


func _ready() -> void:
	if model == null:
		setup(UIRoot.config_from(self))


static func _size_of(block: Dictionary, key: String, fallback: Vector2) -> Vector2:
	var raw: Variant = block.get(key, null)
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2(float((raw as Array)[0]), float((raw as Array)[1]))
	return fallback


func _bind_nodes() -> void:
	_scrim = get_node_or_null("Scrim") as ColorRect
	_panel = get_node_or_null("Panel") as PanelContainer
	_title = get_node_or_null("Panel/Body/Header/Title") as Label
	_close = get_node_or_null("Panel/Body/Header/Close") as Button
	_tabs_box = get_node_or_null("Panel/Body/Tabs") as HBoxContainer
	_content = get_node_or_null("Panel/Body/Scroll/Content") as VBoxContainer


func _build_static() -> void:
	if _scrim != null:
		_scrim.color = UIWidgets.scrim_color(self, SCRIM_ALPHA)
	if _title != null:
		_title.text = UIWidgets.t(config, "ui_dashboard_title")
		# Authored with `clip_text` in the scene, which reports a one-pixel minimum
		# and lets the ✕ beside it claim the whole header row.
		UIWidgets.elide(_title, _touch_min * 2.0)
	if _close != null:
		_close.theme_type_variation = &"GhostButton"
		_close.focus_mode = Control.FOCUS_NONE
		_close.custom_minimum_size = Vector2(_touch_min, _touch_min)
		_close.text = "✕"
		_close.tooltip_text = UIWidgets.t(config, "ui_dashboard_close")
		if not _close.pressed.is_connected(close):
			_close.pressed.connect(close)
	if _content != null:
		_content.add_theme_constant_override(&"separation", int(_spacing))


func _build_tabs() -> void:
	if _tabs_box == null:
		return
	UIWidgets.clear_children(_tabs_box)
	_tab_buttons.clear()
	_tabs_box.add_theme_constant_override(&"separation", int(_spacing))
	# §2.10 has FOUR tabs and a 360 dp phone has 344 dp of panel: a fixed strip of
	# four 96 dp buttons reports a 408 dp minimum and drags the whole modal — ✕ and
	# all — off the display. The strip wraps instead, and each chip is only as wide
	# as its own word (never under the A3 touch floor), so it wraps as late as it
	# can and never clips a label.
	var flow := HFlowContainer.new()
	flow.name = "Flow"
	flow.add_theme_constant_override(&"h_separation", int(_spacing))
	flow.add_theme_constant_override(&"v_separation", int(_spacing))
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs_box.add_child(flow)
	for tab: Dictionary in model.tabs():
		var id: StringName = tab["id"]
		var text := str(tab["label"])
		var button := UIWidgets.button("Tab_" + String(id), text, text,
				Vector2(_touch_min, _touch_min), &"TabButton")
		button.toggle_mode = true
		button.pressed.connect(_on_tab_pressed.bind(id))
		flow.add_child(button)
		UIWidgets.fit_width(button)
		_tab_buttons[id] = button


# ---------------------------------------------------------------------------
# Ingest
# ---------------------------------------------------------------------------

## One settled game-hour into the ring the sparklines are drawn from. The shell
## calls it on `economy_hour_settled`, which is the only moment doc 03 says the
## city's books are true.
func sample(row: Dictionary) -> void:
	model.history.sample(row)
	if is_open():
		refresh(_last_snapshot)


## Doc 03's settle snapshot, or the `economy_hour_settled` bus event — see
## `BudgetModel.feed_settlement`.
func feed_settlement(snapshot: Dictionary) -> void:
	model.budget.feed_settlement(snapshot)
	if is_open():
		refresh(_last_snapshot)


## `CitySim.cmd_set_tax_level` itself, and the detent it currently sits on.
func bind_tax(command: Callable, level: int, level_count: int, rate: float) -> void:
	model.budget.set_tax_command(command)
	model.budget.set_tax_state(level, level_count, rate)
	if is_open():
		refresh(_last_snapshot)


## `{power01, water01}` — the same call the HUD chips get, so the Grid and Water
## bands read what the chips read.
func ingest_service(snapshot: Dictionary) -> void:
	model.ingest_service(snapshot)
	if is_open():
		refresh(_last_snapshot)


## §2.10's Infrastructure feed: `{power, feeders, transformers, water}`, straight
## out of `PowerGrid.capacity_summary/feeder_rows/transformer_rows` and
## `WaterSnapshot.build`. Only the shell holds a sim, so only the shell can fill
## it; this class still computes nothing.
func feed_infrastructure(snapshot: Dictionary) -> void:
	model.feed_infrastructure(snapshot)
	if is_open() and model.tab() == DashboardModel.TAB_INFRASTRUCTURE:
		refresh(_last_snapshot)


## §2.10's Response feed: `{units, stats, open}` — doc 06's roster, its dispatch
## statistics and the live incident count.
func feed_response(snapshot: Dictionary) -> void:
	model.feed_response(snapshot)
	if is_open() and model.tab() == DashboardModel.TAB_RESPONSE:
		refresh(_last_snapshot)


## The same plain snapshot `CityHUD.refresh()` takes.
func refresh(snapshot: Dictionary) -> void:
	_last_snapshot = snapshot
	if not is_open():
		return
	_render(model.build_view(snapshot))


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _panel != null and _panel.visible


func open(tab_id: StringName = &"") -> void:
	UIWidgets.close_siblings(self)
	if tab_id != &"":
		model.set_tab(tab_id)
	_set_visible(true)
	_render(model.build_view(_last_snapshot))
	sheet_toggled.emit(true)


## What `CityHUD.chip_activated` opens: the dashboard, scrolled to that chip's
## band (§2.10's "tapping a row deep-links" in reverse).
func open_for_chip(chip_id: StringName) -> void:
	var row_id := model.row_for_chip(chip_id)
	if row_id != "":
		model.select_row(row_id)
	open(DashboardModel.ROW_TAB.get(row_id, DashboardModel.TAB_OVERVIEW))


func close() -> void:
	_set_visible(false)
	sheet_toggled.emit(false)


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


func _set_visible(value: bool) -> void:
	if _panel != null:
		_panel.visible = value
	if _scrim != null:
		_scrim.visible = value
		_scrim.mouse_filter = Control.MOUSE_FILTER_STOP if value \
				else Control.MOUSE_FILTER_IGNORE


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func _render(view: Dictionary) -> void:
	for id: Variant in _tab_buttons:
		var button: Button = _tab_buttons[id]
		var selected: bool = id == view["tab"]
		button.set_pressed_no_signal(selected)
		UIWidgets.paint_state(self, button,
				HudModel.STATE_NORMAL if selected else &"")
	if _content == null:
		return
	UIWidgets.clear_children(_content)
	_row_buttons.clear()
	_chart = null
	_chart_box = null
	_tax_rate_label = null
	_tax_note = null
	_tax_apply = null
	_tax_happiness = null
	_tax_growth = null
	match view["tab"]:
		DashboardModel.TAB_ECONOMY:
			_build_economy(view)
		DashboardModel.TAB_INFRASTRUCTURE:
			_build_sections(view["infrastructure"] as Dictionary)
		DashboardModel.TAB_RESPONSE:
			_build_sections(view["response"] as Dictionary)
		_:
			_build_overview(view)


## §2.10: "each row a 48 dp band with label, value, state glyph, and a 64 × 24 dp
## sparkline of the last 24 game-hours".
func _build_overview(view: Dictionary) -> void:
	for row: Variant in (view["rows"] as Array):
		_content.add_child(_build_band(row as Dictionary))
	# The chart lives in its own container so a row tap can redraw it without
	# freeing the band that is emitting `pressed` — the same trap
	# `AlertsCenter._repaint_rows` documents.
	_chart_box = VBoxContainer.new()
	_chart_box.name = "Chart"
	_chart_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chart_box.add_theme_constant_override(&"separation", int(_spacing))
	_content.add_child(_chart_box)
	_fill_chart(view["chart"] as Dictionary)


## Rebuilds the chart alone. Safe from a row handler; the rows are siblings of
## this box, never children of it.
func _rebuild_chart() -> void:
	if _chart_box == null:
		return
	UIWidgets.clear_children(_chart_box)
	_chart = null
	_fill_chart(model.chart(model.selected_row()))


func _build_band(row: Dictionary) -> Button:
	var row_id := str(row["id"])
	var label := str(row["label"])
	var value := str(row["value_text"])
	var button := UIWidgets.button("Row_" + row_id, "", "%s: %s" % [label, value],
			Vector2(_touch_min, _row_h), &"DrawerRow")
	button.pressed.connect(_on_row_pressed.bind(row_id))
	_row_buttons[row_id] = button

	var line := HBoxContainer.new()
	line.name = "Body"
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.set_anchors_preset(Control.PRESET_FULL_RECT)
	# A row's contents sit inside the button, not on its edge — the panel's own
	# scrollbar lives on that edge and would clip the sparkline.
	line.offset_left = _spacing
	line.offset_right = -_spacing
	line.add_theme_constant_override(&"separation", int(_spacing))
	button.add_child(line)

	var name_label := UIWidgets.label("Label", label)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(name_label)

	# A5: the state glyph rides with the value, so a CRITICAL band is legible in
	# greyscale exactly like its HUD chip.
	var value_label := _fixed(UIWidgets.label("Value",
			("%s %s" % [value, str(row["state_glyph"])]).strip_edges()))
	UIWidgets.paint_state(self, value_label, row["state"])
	line.add_child(value_label)

	var spark := LineChart.new()
	spark.name = "Spark"
	spark.custom_minimum_size = _spark_dp
	spark.size_flags_horizontal = Control.SIZE_SHRINK_END
	spark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	spark.set_baseline(false)
	spark.set_shape(row["spark"] as Dictionary, row["state"], config)
	line.add_child(spark)
	return button


func _fill_chart(chart: Dictionary) -> void:
	if _chart_box == null:
		return
	_chart_box.add_child(UIWidgets.label("Title", str(chart["title"]), &"LegendRow"))
	if int(chart["count"]) <= 0:
		# A14: an empty chart says why in words rather than drawing an empty box.
		_chart_box.add_child(UIWidgets.label("Empty", str(chart["empty_text"]),
				&"", true))
		return
	_chart = LineChart.new()
	_chart.name = "Line"
	_chart.custom_minimum_size = _chart_dp
	_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chart.set_shape(chart, chart["state"], config)
	_chart_box.add_child(_chart)
	var axis := HBoxContainer.new()
	axis.name = "Axis"
	axis.mouse_filter = Control.MOUSE_FILTER_IGNORE
	axis.add_theme_constant_override(&"separation", int(_spacing))
	axis.add_child(UIWidgets.label("Min", str(chart["min_text"])))
	axis.add_child(UIWidgets.spacer())
	var delta := UIWidgets.label("Delta", str(chart["delta_text"]))
	UIWidgets.paint_state(self, delta, chart["state"])
	axis.add_child(delta)
	axis.add_child(UIWidgets.spacer("Spacer2"))
	axis.add_child(UIWidgets.label("Max", str(chart["max_text"])))
	_chart_box.add_child(axis)


# ---------------------------------------------------------------------------
# Infrastructure and Response — §2.10's other two tabs
# ---------------------------------------------------------------------------

## Both tabs are the same shape: titled sections of `label · value · detail`
## lines, in the model's order. Which sections exist, which rows are in them and
## which of them are the "worst N" is entirely `DashboardModel`'s — this draws
## whatever it is handed, so adding the condition histogram §2.10 also asks for
## is a section in the model and no code here.
func _build_sections(view: Dictionary) -> void:
	var raw: Variant = view.get("sections", [])
	for value: Variant in (raw as Array if raw is Array else []):
		if value is Dictionary:
			_content.add_child(_build_section(value as Dictionary))


func _build_section(section: Dictionary) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "Section_" + str(section.get("id", ""))
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override(&"separation", int(_spacing))
	box.add_child(UIWidgets.label("Title", str(section.get("title", "")), &"LegendRow"))
	var raw: Variant = section.get("rows", [])
	var rows: Array = raw if raw is Array else []
	if rows.is_empty():
		# A14: an empty section says why in words rather than showing a blank gap.
		box.add_child(UIWidgets.label("Empty", str(section.get("empty_text", "")),
				&"", true))
		return box
	for value: Variant in rows:
		if value is Dictionary:
			box.add_child(_build_section_row(value as Dictionary))
	return box


## One reading. `detail` rides UNDER the value rather than beside it: `78 %` and
## `12 lots` on one line is 3 dp wider than a 360 dp panel at 130 % text, and the
## figure — the thing the row exists to show — was the half that lost.
func _build_section_row(row: Dictionary) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "Row_" + str(row.get("id", ""))
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var line := HBoxContainer.new()
	line.name = "Line"
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override(&"separation", int(_spacing))
	var label := UIWidgets.elide(UIWidgets.label("Label", str(row.get("label", ""))),
			_touch_min) as Label
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(label)
	# A5: the state glyph rides with the value, so a CRITICAL feeder is legible in
	# greyscale exactly like its HUD chip.
	var state: StringName = StringName(str(row.get("state", "")))
	var value := _fixed(UIWidgets.label("Value",
			("%s %s" % [str(row.get("value", "")),
					str(row.get("state_glyph", ""))]).strip_edges()))
	UIWidgets.paint_state(self, value, state)
	line.add_child(value)
	line.add_child(_gutter())
	box.add_child(line)

	var detail := str(row.get("detail", ""))
	if detail != "":
		box.add_child(UIWidgets.label("Detail", detail, &"", true))
	return box


# ---------------------------------------------------------------------------
# Economy tab — the tax detent and the settled hour
# ---------------------------------------------------------------------------

func _build_economy(view: Dictionary) -> void:
	_content.add_child(_build_tax())
	# After the box is in the tree, so the preview writes into live labels.
	_apply_preview(model.budget.preview(model.budget.pending_level()))
	# The Upkeep band is refreshed HERE and nowhere else: its sim half is a
	# roster walk and a preview per candidate, and there is no reason to pay for
	# it on the three tabs that do not draw it (99-PA PA-31).
	_refresh_upkeep()
	_content.add_child(_build_upkeep(model.upkeep_view()))
	var ledger: Dictionary = view["budget"]
	if not bool(ledger["has_data"]):
		_content.add_child(UIWidgets.label("NoData",
				UIWidgets.t(config, "ui_budget_no_data"), &"", true))
		return
	if bool(ledger["has_breakdown"]):
		_content.add_child(_build_ledger("Revenue",
				UIWidgets.t(config, "ui_budget_revenue_title"),
				ledger["revenue"] as Array))
		_content.add_child(_build_ledger("Expenses",
				UIWidgets.t(config, "ui_budget_expense_title"),
				ledger["expenses"] as Array))
	# Three bare figures side by side — `$14K  $8,630  Net +$128K/d` — asked the
	# reader to remember which was which and to notice that one of them was per
	# day, and the row was 3 dp wider than a 360 dp phone. They are now three more
	# lines in the ledger's own shape: name on the left, figure on the right, same
	# unit as everything above them.
	var totals := VBoxContainer.new()
	totals.name = "Totals"
	totals.mouse_filter = Control.MOUSE_FILTER_IGNORE
	totals.add_theme_constant_override(&"separation", int(_spacing))
	totals.add_child(_total_line("Gross", "ui_budget_total_revenue",
			str(ledger["gross_text"]), &""))
	totals.add_child(_total_line("Expense", "ui_budget_total_expenses",
			str(ledger["expense_text"]), &""))
	totals.add_child(_total_line("Net", "ui_budget_total_net",
			str(ledger["net_text"]), ledger["net_state"]))
	_content.add_child(totals)


# ---------------------------------------------------------------------------
# The Upkeep band (99-PA PA-31 + PA-33, doc 98 RR-149 / RR-150)
# ---------------------------------------------------------------------------

## `CitySim.cmd_repair_all_worn` (preview and commit are the same Callable, taken
## with a different first argument), `CitySim.building_repair_policy` and a
## treasury reading, so an unaffordable batch shows its price on a disabled face
## instead of vanishing — the same contract S16's rush door uses.
##
## The shell binds this; a shell that does not gets the band's LOSS half only,
## which is still the whole of PA-31.
func bind_upkeep(repair_all: Callable, policy: Callable, balance: Callable) -> void:
	_repair_all = repair_all
	_upkeep_policy = policy
	_upkeep_balance = balance
	if is_open():
		refresh(_last_snapshot)


func _refresh_upkeep() -> void:
	if not _repair_all.is_valid():
		return
	var quoted: Variant = _repair_all.call(true)
	var quote: Dictionary = {}
	if quoted is Dictionary and bool((quoted as Dictionary).get("ok", false)):
		var payload: Variant = (quoted as Dictionary).get("payload", {})
		quote = payload if payload is Dictionary else {}
	model.feed_upkeep({
		"quote": quote,
		"policy": _upkeep_policy.call() if _upkeep_policy.is_valid() else {},
		"balance": float(_upkeep_balance.call()) if _upkeep_balance.is_valid() else 0.0,
	})


## The audit's target for PA-31, drawn: *the lost $/gh and the repair total on
## one screen*. Four lines and a button — what wear costs, how much of the taxed
## stock is below Good, what the city's own repairable stock would cost, and the
## standing policy that would buy it without being asked again.
func _build_upkeep(upkeep: Dictionary) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "Upkeep"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override(&"separation", int(_spacing))
	box.add_child(UIWidgets.label("Title", str(upkeep["title"]), &"LegendRow"))

	var loss := HBoxContainer.new()
	loss.name = "Loss"
	loss.mouse_filter = Control.MOUSE_FILTER_IGNORE
	loss.add_theme_constant_override(&"separation", int(_spacing))
	var loss_label := UIWidgets.elide(UIWidgets.label("Label",
			str(upkeep["loss_label"])), _touch_min) as Label
	loss_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	loss.add_child(loss_label)
	var loss_value := _fixed(UIWidgets.label("Amount", str(upkeep["loss_text"])))
	UIWidgets.paint_state(self, loss_value, upkeep["loss_state"])
	loss.add_child(loss_value)
	loss.add_child(_gutter())
	box.add_child(loss)
	box.add_child(UIWidgets.label("Worn", str(upkeep["worn_text"]), &"", true))

	if bool(upkeep["has_repair"]):
		var button := UIWidgets.button("RepairAllWorn", str(upkeep["repair_text"]),
				str(upkeep["repair_text"]),
				Vector2(maxf(_touch_min * 2.0, 96.0), _touch_min), &"GhostButton")
		button.disabled = not bool(upkeep["can_repair"])
		button.pressed.connect(_on_repair_all_pressed)
		box.add_child(button)
	else:
		box.add_child(UIWidgets.label("NoRepair", str(upkeep["none_text"]), &"", true))
	box.add_child(UIWidgets.label("Policy", str(upkeep["policy_text"]), &"", true))
	return box


func _on_repair_all_pressed() -> void:
	if not _repair_all.is_valid():
		return
	var result: Variant = _repair_all.call(false)
	repair_all_worn.emit(result if result is Dictionary else {})
	# The band is a reading of the roster, and the roster just changed.
	refresh(_last_snapshot)


## §2.10's tax-rate control: a stepper, not a slider. Doc 03's ladder is a set of
## detents, and a stepper cannot land between two of them — which is also why
## every step previews through the sim rather than being predicted here.
func _build_tax() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "Tax"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override(&"separation", int(_spacing))
	box.add_child(UIWidgets.label("Title",
			UIWidgets.t(config, "ui_budget_tax_label"), &"LegendRow"))

	var row := HBoxContainer.new()
	row.name = "Stepper"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override(&"separation", int(_spacing))
	box.add_child(row)

	var down := UIWidgets.button("TaxDown", STEP_DOWN,
			UIWidgets.t(config, "ui_budget_tax_down"),
			Vector2(_touch_min, _touch_min), &"GhostButton")
	down.pressed.connect(_on_tax_step.bind(-1))
	row.add_child(down)

	_tax_rate_label = UIWidgets.label("Rate", "")
	_tax_rate_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tax_rate_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(_tax_rate_label)

	var up := UIWidgets.button("TaxUp", STEP_UP,
			UIWidgets.t(config, "ui_budget_tax_up"),
			Vector2(_touch_min, _touch_min), &"GhostButton")
	up.pressed.connect(_on_tax_step.bind(1))
	row.add_child(up)

	# APPLY on its own line. `− 9% level 6 of 13 + APPLY` is 322 dp of content on
	# one line; a 412 dp phone has 388 dp of panel, and the rate — the number the
	# stepper exists to change — was the part that lost.
	_tax_apply = UIWidgets.button("TaxApply",
			UIWidgets.t(config, "ui_budget_tax_apply"),
			UIWidgets.t(config, "ui_budget_tax_apply"),
			Vector2(maxf(_touch_min * 2.0, 96.0), _touch_min), &"PrimaryFAB")
	_tax_apply.pressed.connect(_on_tax_apply)
	box.add_child(_tax_apply)

	var preview_box := VBoxContainer.new()
	preview_box.name = "Preview"
	preview_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(preview_box)
	_tax_happiness = UIWidgets.label("Happiness", "")
	preview_box.add_child(_tax_happiness)
	_tax_growth = UIWidgets.label("Growth", "")
	preview_box.add_child(_tax_growth)
	_tax_note = UIWidgets.label("Note", "", &"", true)
	preview_box.add_child(_tax_note)
	return box


func _build_ledger(node_name: String, title: String, lines: Array) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = node_name
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override(&"separation", int(_spacing))
	box.add_child(UIWidgets.label("Title", title, &"LegendRow"))
	for raw: Variant in lines:
		var line: Dictionary = raw
		var record := HBoxContainer.new()
		record.name = "Line_" + str(line["key"])
		record.mouse_filter = Control.MOUSE_FILTER_IGNORE
		record.add_theme_constant_override(&"separation", int(_spacing))
		var label := UIWidgets.label("Label", str(line["label"]))
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		record.add_child(label)
		record.add_child(_fixed(UIWidgets.label("Amount", str(line["text"]))))
		record.add_child(_gutter())
		# A line may carry a NOTE — one sentence under its own figure, in the
		# muted style, saying something the amount cannot (99-PA PA-32: the
		# founding grant's per-day rate and the game-day it ends on). It is drawn
		# here rather than appended to the label because the label is the left
		# half of a two-column row and a longer one pushes the figure off the
		# panel; a note is its own line and can wrap.
		var note := str(line.get("note", ""))
		if note == "":
			box.add_child(record)
			continue
		var stack := VBoxContainer.new()
		stack.name = "Note_" + str(line["key"])
		stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stack.add_child(record)
		stack.add_child(UIWidgets.label("Note", note, &"", true))
		box.add_child(stack)
	return box


## One summary line, in the same shape as a ledger line so the eye reads straight
## down the column of figures.
func _total_line(node_name: String, label_key: String, amount: String,
		state: StringName) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = node_name
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override(&"separation", int(_spacing))
	var label := UIWidgets.elide(UIWidgets.label("Label",
			UIWidgets.t(config, label_key)), _touch_min) as Label
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var value := _fixed(UIWidgets.label("Amount", amount))
	UIWidgets.paint_state(self, value, state)
	row.add_child(value)
	row.add_child(_gutter())
	return row


## A fixed strip that keeps a right-aligned number off the scrollbar. The rows
## here are not inside a Button, so they have no content margin of their own.
func _gutter() -> Control:
	var pad := Control.new()
	pad.name = "Gutter"
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.custom_minimum_size = Vector2(_spacing * 2.0, 0.0)
	return pad


## See `IncidentDrawer._fixed`: pins a value column to its own measured width.
static func _fixed(label: Label) -> Label:
	label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	return label


func _apply_preview(preview: Dictionary) -> void:
	if _tax_rate_label != null:
		_tax_rate_label.text = "%s  %s" % [str(preview["rate_text"]),
				str(preview["level_text"])]
	if _tax_apply != null:
		_tax_apply.disabled = not bool(preview["can_apply"])
	if _tax_note != null:
		_tax_note.text = str(preview["note"])
		UIWidgets.paint_state(self, _tax_note,
				HudModel.STATE_WARNING if str(preview["note"]) != "" else &"")
	if _tax_happiness != null:
		_tax_happiness.text = str(preview["happiness_text"])
		UIWidgets.paint_state(self, _tax_happiness, preview["happiness_state"])
	if _tax_growth != null:
		_tax_growth.text = str(preview["growth_text"])
		UIWidgets.paint_state(self, _tax_growth, preview["growth_state"])


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _on_tab_pressed(tab_id: StringName) -> void:
	model.set_tab(tab_id)
	_render(model.build_view(_last_snapshot))


## §2.10: "tapping a row deep-links (Grid → power overlay + close; Active
## incidents → drawer)". The link is data on the row; the shell decides what to
## do with it, because only the shell owns the overlay and the camera.
##
## Only the chart is redrawn here — a full `_render()` would free the band that
## is emitting `pressed`, which is an engine error.
func _on_row_pressed(row_id: String) -> void:
	model.select_row(row_id)
	_rebuild_chart()
	row_selected.emit(row_id)
	var target := str(DashboardModel.ROW_DEEPLINK.get(row_id, ""))
	if target == "":
		return
	# §2.10's "Grid → power overlay + close": a deep link takes the player
	# somewhere else, so the dashboard gets out of the way first.
	close()
	deeplink_requested.emit(target)


func _on_tax_step(delta: int) -> void:
	_apply_preview(model.budget.step(delta))


## The stepper repaints in place; the ledger does not change until the next hour
## settles, and rebuilding the tab here would free the APPLY button mid-press.
func _on_tax_apply() -> void:
	var result := model.budget.apply()
	_apply_preview(result)
	if bool(result["applied"]):
		tax_applied.emit(int(result["level"]), float(result["rate"]))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func tab_button(tab_id: StringName) -> Button:
	return _tab_buttons.get(tab_id, null)


func row_button(row_id: String) -> Button:
	return _row_buttons.get(row_id, null)


## One Infrastructure / Response section by its model id, and one row inside it.
func section_box(section_id: String) -> VBoxContainer:
	if _content == null:
		return null
	return _content.get_node_or_null("Section_" + section_id) as VBoxContainer


func section_row(section_id: String, row_id: String) -> VBoxContainer:
	var box := section_box(section_id)
	return box.get_node_or_null("Row_" + row_id) as VBoxContainer if box != null \
			else null


## The stepper's three keys plus APPLY, which sits on the tax block's second line
## rather than in the stepper row (see `_build_tax`).
func tax_button(node_name: String) -> Button:
	if _content == null:
		return null
	var button := _content.get_node_or_null("Tax/Stepper/" + node_name) as Button
	return button if button != null \
			else _content.get_node_or_null("Tax/" + node_name) as Button


func tax_rate_text() -> String:
	return _tax_rate_label.text if _tax_rate_label != null else ""


func tax_note_text() -> String:
	return _tax_note.text if _tax_note != null else ""


func chart_control() -> LineChart:
	return _chart
