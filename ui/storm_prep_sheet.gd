class_name StormPrepSheet
extends Control
## **S17 (doc 12 §2.24) — the Storm Prep window.**
##
## Doc 07 §2.7.7's seventy game-minutes, given a screen. Same shape as S14: a
## full-screen modal on `ModalLayer`, the scrim the only `STOP` control while it
## is up, Android BACK closes it first (§2.2).
##
##     Storm prep                                            ✕
##     Storm hits in 1h 30m  ·  1h 10m left to prepare
##     Forecast: this one will be felt.
##     ─────────────────────────────────────────────
##     Power holding  ▓▓▓▓▓▓▓▓▓░  96%
##     Water stored   ▓▓▓▓▓░░░░░  52%
##     Crews free     ▓▓▓░░░░░░░  3 idle
##     ─────────────────────────────────────────────
##     ○  Voluntary load shed                          No charge
##        Shave 8% off demand for the storm…           [ DO IT ]
##     ✓  Top off water storage                           $1,240
##        Fill every tank, so hydrant pressure…        [ DO IT ]
##     —  Call out a crew                                $18,000
##        Not enough in the treasury.                  [ DO IT ]
##     ─────────────────────────────────────────────
##     1 of 3  ·  2 more earns Storm Ready
##
## Every value comes from `StormPrepModel`, which reads only
## `CitySim.storm_prep_overview()` and `CitySim.cmd_storm_prep_action()`. This
## file decides nothing except which pixels those become — no price, no window,
## no availability rule, and no copy: `title`, `detail`, `cost_text` and
## `reason` all arrive resolved.

signal sheet_toggled(open: bool)
signal action_taken(action_id: String, result: Dictionary)

const SCRIM_ALPHA := 0.55
const CLOSE_GLYPH := "✕"
const METER_W_DP := 96.0
## The floor a clipping label may be squeezed to before it starts eating its own
## characters (`UIAudit.KIND_UNBOUNDED_CLIP`). An action title and a meter label
## are both short enough that this is generous; the point is that the promise is
## made in one place instead of six.
const CLIP_MIN_W_DP := 120.0


var config: UIConfig
var model: StormPrepModel

var _scrim: ColorRect
var _panel: PanelContainer
var _title: Label
var _close: Button
var _body: VBoxContainer

var _countdown: Label
var _severity: Label
var _meter_box: VBoxContainer
var _rows_box: VBoxContainer
var _reward: Label

var _meter_nodes: Dictionary = {}   # meter id -> {label, bar, value}
var _row_nodes: Dictionary = {}     # action id -> {mark, title, cost, detail, button}
var _touch_min := 48.0
var _spacing := 8.0
var _row_h := 72.0
var _meter_h := 6.0


func setup(cfg: UIConfig = null, p_model: StormPrepModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	if p_model != null:
		model = p_model
	if model == null:
		model = StormPrepModel.new(config)
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_row_h = maxf(model.row_h_dp(), _touch_min)
	_meter_h = model.meter_h_dp()
	_bind_nodes()
	_build_static()
	refresh()
	close()


func _ready() -> void:
	if config == null:
		setup(UIRoot.config_from(self))


func _bind_nodes() -> void:
	_scrim = get_node_or_null("Scrim") as ColorRect
	_panel = get_node_or_null("Panel") as PanelContainer
	_title = get_node_or_null("Panel/Body/Header/Title") as Label
	_close = get_node_or_null("Panel/Body/Header/Close") as Button
	_body = get_node_or_null("Panel/Body/Scroll/Content") as VBoxContainer


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build_static() -> void:
	if _scrim != null:
		_scrim.color = UIWidgets.scrim_color(self, SCRIM_ALPHA)
		_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
		if not _scrim.gui_input.is_connected(_on_scrim_input):
			_scrim.gui_input.connect(_on_scrim_input)
	if _title != null:
		_title.text = config.t("ui_storm_prep_title")
		UIWidgets.elide(_title, _touch_min * 2.0)
	if _close != null:
		_close.text = CLOSE_GLYPH
		_close.custom_minimum_size = Vector2(_touch_min, _touch_min)
		if not _close.pressed.is_connected(close):
			_close.pressed.connect(close)
	if _body == null:
		return
	for child in _body.get_children():
		child.queue_free()
	_body.add_theme_constant_override("separation", int(_spacing))
	_meter_nodes.clear()
	_row_nodes.clear()

	_countdown = Label.new()
	_countdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_countdown.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(_countdown)

	_severity = Label.new()
	_severity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_severity.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(_severity)

	_meter_box = VBoxContainer.new()
	_meter_box.add_theme_constant_override("separation", int(_spacing * 0.5))
	_body.add_child(_meter_box)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", int(_spacing))
	_body.add_child(_rows_box)

	_reward = Label.new()
	_reward.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reward.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(_reward)


## One readiness meter: a word, a bar and the reading. The reading is a LABEL and
## not a tooltip, because a bar with no number on it is a decoration (A5).
func _meter_row(meter: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(_spacing))
	var label := Label.new()
	label.text = String(meter["label"])
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIWidgets.elide(label, CLIP_MIN_W_DP)
	row.add_child(label)
	var bar := MeterBar.new()
	bar.custom_minimum_size = Vector2(METER_W_DP, _meter_h)
	row.add_child(bar)
	var value := Label.new()
	value.text = String(meter["value"])
	row.add_child(value)
	_meter_box.add_child(row)
	_meter_nodes[String(meter["id"])] = {"label": label, "bar": bar, "value": value}


## One action row. The button is the only `STOP` control in it: the row itself is
## not tappable, because a whole-row tap on a screen with a countdown running is
## how a player buys $18,000 of crew they meant to read about.
##
## **Two lines, and the button is on the second one.** A single line —
## `mark · title · cost · [ DO IT ]` — has a minimum width that no accessible
## small phone can pay: at 360 dp with A2's 1.3 text scale and A3's larger touch
## targets the four minima sum to **395 dp** against **292 dp** of content box,
## and a `ScrollContainer` with horizontal scrolling off hands that number
## straight up its parents, so the SHEET grows to 423 dp and its close button
## leaves the screen (`UIAudit.KIND_OFFSCREEN`; doc 12 §2.24, delta D-78). The
## button moves down beside the detail sentence, which autowraps and therefore
## has a minimum width of one character — the shape `ui/building_panel.gd`'s
## requirement rows already use, and the reason they survive the same sweep.
## Line 1 then needs 245 dp and line 2 needs 157 dp.
func _action_row(row: Dictionary) -> void:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(0.0, _row_h)
	box.add_theme_constant_override("separation", 2)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", int(_spacing))
	var mark := Label.new()
	head.add_child(mark)
	var title := Label.new()
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIWidgets.elide(title, CLIP_MIN_W_DP)
	head.add_child(title)
	var cost := Label.new()
	head.add_child(cost)
	box.add_child(head)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", int(_spacing))
	var detail := Label.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	foot.add_child(detail)
	var button := Button.new()
	button.custom_minimum_size = Vector2(_touch_min * 2.0, _touch_min)
	button.text = config.t("ui_storm_take")
	# A15: a button whose only label is two shouted words is invisible to a
	# screen reader once it is one of six. The tooltip names the action.
	button.tooltip_text = String(row["title"])
	button.pressed.connect(_on_action_pressed.bind(String(row["id"])))
	foot.add_child(button)
	box.add_child(foot)
	_rows_box.add_child(box)
	_row_nodes[String(row["id"])] = {"mark": mark, "title": title, "cost": cost,
			"detail": detail, "button": button}


# ---------------------------------------------------------------------------
# Refresh
# ---------------------------------------------------------------------------

func refresh() -> void:
	if _body == null or model == null:
		return
	var view := model.view()
	if _title != null:
		_title.text = String(view["title"])
	_countdown.text = String(view["countdown"])
	_severity.text = String(view["severity"])
	_severity.visible = String(view["severity"]) != ""
	for meter in (view["meters"] as Array):
		var row: Dictionary = meter
		if not _meter_nodes.has(String(row["id"])):
			_meter_row(row)
		var nodes: Dictionary = _meter_nodes[String(row["id"])]
		(nodes["label"] as Label).text = String(row["label"])
		(nodes["value"] as Label).text = String(row["value"])
		(nodes["bar"] as MeterBar).set_value(float(row["ratio"]),
				_meter_state(float(row["ratio"])))
	for entry in (view["rows"] as Array):
		var row: Dictionary = entry
		if not _row_nodes.has(String(row["id"])):
			_action_row(row)
		var nodes: Dictionary = _row_nodes[String(row["id"])]
		(nodes["mark"] as Label).text = String(row["mark"])
		(nodes["title"] as Label).text = String(row["title"])
		(nodes["button"] as Button).tooltip_text = String(row["title"])
		(nodes["cost"] as Label).text = String(row["cost_text"])
		var detail := nodes["detail"] as Label
		detail.text = String(row["reason"]) if String(row["reason"]) != "" \
				else String(row["detail"])
		var button := nodes["button"] as Button
		button.disabled = not bool(row["enabled"])
	_reward.text = String(view["reward"])


## §5.10's three bands, as doc 12 §2.5 state tokens: a meter that is nearly
## empty is the one the player should be looking at, and A5 says the colour is
## the third channel — the word and the reading carry it first.
static func _meter_state(ratio: float) -> StringName:
	if ratio < 0.35:
		return HudModel.STATE_CRITICAL
	if ratio < 0.70:
		return HudModel.STATE_WARNING
	return HudModel.STATE_NORMAL


func _on_action_pressed(action_id: String) -> void:
	var result := model.take(action_id)
	emit_signal("action_taken", action_id, result)
	refresh()


func _on_scrim_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		close()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		close()


# ---------------------------------------------------------------------------
# The back-stack protocol (doc 12 §2.2)
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _panel != null and _panel.visible


func open() -> void:
	refresh()
	if _scrim != null:
		_scrim.visible = true
	if _panel != null:
		_panel.visible = true
	emit_signal("sheet_toggled", true)


func close() -> void:
	var was := is_open()
	if _scrim != null:
		_scrim.visible = false
	if _panel != null:
		_panel.visible = false
	if was:
		emit_signal("sheet_toggled", false)
