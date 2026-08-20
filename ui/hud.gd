class_name CityHUD
extends Control
## S1's persistent HUD (doc 12 §2.3): the top-bar stat chips, the clock chip,
## the pause/1×/2×/3× speed rail and the alert banner stack, hung on the
## `UIRoot` scaffold's `HUDLayer`.
##
## This file is deliberately dumb (constitution §3, doc 12 §1). Every number,
## threshold, format, collapse decision and alert budget comes from `HudModel`;
## nothing here computes anything the headless tests could not otherwise reach.
## Widgets are built in code rather than authored in the `.tscn` so that widths
## and touch minimums come from `data/ui.json` at runtime and no `theme_override`
## ever enters a scene file (doc 12 test 19).
##
## Copy: every label resolves through `data/strings.en.json` first
## (`UIConfig.t`); the `HudModel` fallback tables are used only for the HUD keys
## that file does not carry yet, so nothing here is authored copy.

signal chip_activated(chip_id: StringName)     ## → S8 dashboard, scrolled to it
signal clock_activated                          ## → weather/forecast surface
signal speed_selected(multiplier: int)          ## → `set_speed` (doc 01)
signal pause_toggled(paused: bool)              ## → `set_paused` (doc 01)
signal alert_activated(alert_id: String)        ## banner tap → jump + select
signal menu_requested                           ## → the pause menu on ModalLayer
## §2.13's gate degraded a banner it could not afford into a toast (§2.15).
## `UIRoot` draws it on `ToastLayer`; without this the degraded alert was
## budgeted, recorded and then shown to nobody.
signal toast_requested(text: String, state: StringName)

const PALETTE_TYPE := "Palette"
const REFERENCE_WIDTH_DP := 880.0
const ALERT_REFRESH_S := 0.2
const MENU_GLYPH := "☰"

var config: UIConfig
var model: HudModel

var _top_bar: Control
var _chips_box: VBoxContainer     ## one `Row<i>` HBox per wrapped top-bar row
var _clock_chip: Button
var _menu_button: Button
var _speed_button: Button
var _speed_options_box: VBoxContainer
var _alert_stack: VBoxContainer

var _chips: Dictionary = {}          # chip id -> Button
var _speed_buttons: Dictionary = {}  # option id -> Button
var _alert_rows: Array[Dictionary] = []

var _speed := 1
var _paused := false
var _rail_expanded := false
var _reduce_motion := false
var _touch_min := 48.0
var _chip_gap := 6.0
var _spacing := 8.0
var _max_rows := 1
var _pulse_hz := 1.2
var _pulse_phase := 0.0
var _alert_timer := 0.0
var _row_signature := ""
## Layout width in dp. `< 0` means "measure the tree"; the tests and the
## screenshot harness set it explicitly so a headless run can exercise a Fold's
## near-square box without a window.
var _width_override := -1.0
var _last_snapshot: Dictionary = {}


## Builds every widget from `data/ui.json`. `_ready()` calls it; callers may call
## it earlier to inject an already-parsed config (child `_ready()` runs before
## `UIRoot._ready()`, so the HUD cannot rely on the root having loaded one), and
## the headless tests call it to exercise the binding without a live tree.
func setup(cfg: UIConfig = null, hud_model: HudModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	if hud_model != null:
		model = hud_model
	if model == null:
		model = HudModel.new(config)
	var defaults := config.section("defaults")
	_reduce_motion = bool(defaults.get("reduce_motion", false))
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	var layout := config.layout()
	_chip_gap = UIConfig.get_num(layout, "chip_gap_dp", 6.0)
	_spacing = UIConfig.get_num(layout, "touch_spacing_min_dp", 8.0)
	_max_rows = model.top_bar_max_rows()
	var pulse := config.section("state_pulse_hz")
	_pulse_hz = UIConfig.get_num(pulse, "critical", 1.2)
	_bind_nodes()
	_rebuild()
	set_process(true)


func _ready() -> void:
	if model == null:
		# The root's parse, not a second one. `UIRoot._enter_tree` loads the config
		# before any child's `_ready()` precisely so the deck shares it — and a
		# screen that re-parses does not merely waste the file read, it misses
		# whatever the shell injected. That is how the speed rail ended up solving
		# its 48 dp touch floor while the overlay button beside it solved a 56 dp
		# one, and the two stacked on top of each other at 130 % text.
		setup(UIRoot.config_from(self))


## Immediate rather than deferred: `setup()` may be called twice (once by an
## injecting owner, once by `_ready()`) and a queued free would leave the old
## widgets in place for a frame, colliding with the rebuilt ones.
static func _clear_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.free()


func _bind_nodes() -> void:
	_top_bar = get_node_or_null("TopBar") as Control
	_chips_box = get_node_or_null("TopBar/Chips") as VBoxContainer
	_clock_chip = get_node_or_null("TopBar/ClockChip") as Button
	_menu_button = get_node_or_null("TopBar/MenuButton") as Button
	_speed_button = get_node_or_null("LeftRail/SpeedButton") as Button
	_speed_options_box = get_node_or_null("LeftRail/SpeedOptions") as VBoxContainer
	_alert_stack = get_node_or_null("AlertStack") as VBoxContainer


func _rebuild() -> void:
	_adopt_trailing_block()
	_build_chips()
	_build_clock()
	_build_menu_button()
	_build_speed_rail()
	_build_alert_rows()
	if not _last_snapshot.is_empty():
		refresh(_last_snapshot)


## Moves the clock chip and the ☰ button **into the chip rows**, out of the
## top-bar HBox they are authored beside.
##
## `HudModel._pack_rows` is written against "row 0 shares its line with the clock
## chip; every wrapped row below spans the whole bar". The scene's original shape
## — `TopBar[ Chips(VBox) | Spacer | Clock | Menu ]` — cannot express that: the
## `Chips` column is one column, so its width is the width of its **widest** row,
## and a second row solved against the full bar made `TopBar`'s minimum ~200 dp
## wider than a 412 dp phone. `grow_horizontal = BOTH` then centred the overflow,
## which pushed the treasury chip off the left edge and the ☰ button — the only
## way into the pause menu — off the right. Two rows, both bounded by `avail`,
## would fit the chips but waste the whole clock column on row 1.
##
## So the view is made to match the model instead: the clock and the menu become
## the tail of row 0, and every wrapped row genuinely does span the bar.
func _adopt_trailing_block() -> void:
	if _top_bar == null:
		return
	# The authored spacer between the chips and the clock has no job once the
	# clock lives inside a row — and left in place it would still claim the bar.
	var spacer := _top_bar.get_node_or_null("Spacer") as Control
	if spacer != null:
		spacer.visible = false
		spacer.custom_minimum_size = Vector2.ZERO
	if _chips_box != null:
		_chips_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL


## Re-parents a node without freeing it, and without leaving it parented to a row
## `_apply_rows` is about to free.
static func _detach(node: Node) -> void:
	if node == null or node.get_parent() == null:
		return
	node.get_parent().remove_child(node)
	# A node moved out of its authored slot keeps a stale `owner`, which Godot
	# warns about on every re-flow; these are code-placed from here on.
	node.owner = null


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

## Chips are built once and then **re-flowed** between top-bar rows as the width
## changes — rebuilding them on every resize would drop their state and their
## measured widths for no gain.
func _build_chips() -> void:
	if _chips_box == null:
		return
	_clear_children(_chips_box)
	_chips.clear()
	_row_signature = ""
	_chips_box.add_theme_constant_override(&"separation", int(_spacing))
	var row := _new_chip_row(0)
	_chips_box.add_child(row)
	for chip_id: String in model.chip_order():
		var button := Button.new()
		button.name = "Chip_" + chip_id
		button.theme_type_variation = &"StatChip"
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(
				model.chip_width_dp(chip_id, HudModel.MODE_FULL), _touch_min)
		button.clip_text = true
		button.tooltip_text = _chip_label(chip_id)  # A15 accessibility name
		button.pressed.connect(_on_chip_pressed.bind(StringName(chip_id)))
		row.add_child(button)
		_chips[chip_id] = button


func _new_chip_row(index: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Row%d" % index
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override(&"separation", int(_chip_gap))
	return row


func _build_clock() -> void:
	if _clock_chip == null:
		return
	_clock_chip.theme_type_variation = &"StatChip"
	_clock_chip.focus_mode = Control.FOCUS_NONE
	_clock_chip.custom_minimum_size = Vector2(
			UIConfig.get_num(config.layout(), "clock_chip_w_dp", 132.0), _touch_min)
	_clock_chip.tooltip_text = _text("ui_hud_clock", "City clock")
	if not _clock_chip.pressed.is_connected(_on_clock_pressed):
		_clock_chip.pressed.connect(_on_clock_pressed)


## The pause menu's entry point. Top-right, in the "rare" reach zone (§2.3) —
## nothing time-critical lives behind it, so 340 dp from the thumb is correct.
func _build_menu_button() -> void:
	if _menu_button == null:
		return
	_menu_button.theme_type_variation = &"RailButton"
	_menu_button.focus_mode = Control.FOCUS_NONE
	_menu_button.custom_minimum_size = Vector2(_touch_min, _touch_min)
	_menu_button.text = MENU_GLYPH
	_menu_button.tooltip_text = _text("ui_hud_pause_menu", "Pause menu")
	if not _menu_button.pressed.is_connected(_on_menu_pressed):
		_menu_button.pressed.connect(_on_menu_pressed)


func _build_speed_rail() -> void:
	if _speed_button == null or _speed_options_box == null:
		return
	var rail_d := UIConfig.get_num(config.layout(), "rail_button_d_dp", 56.0)
	var button_size := Vector2(maxf(rail_d, _touch_min), maxf(rail_d, _touch_min))
	_speed_button.theme_type_variation = &"RailButton"
	_speed_button.focus_mode = Control.FOCUS_NONE
	_speed_button.custom_minimum_size = button_size
	_speed_button.tooltip_text = _text("ui_hud_speed", "Game speed")
	# Third slot of §2.3's rail stack, solved rather than authored — see
	# `UIWidgets.rail_slot`.
	UIWidgets.place_in_rail(_speed_button.get_parent() as Control, 2,
			config.layout(), _touch_min)
	if not _speed_button.pressed.is_connected(_on_speed_button_pressed):
		_speed_button.pressed.connect(_on_speed_button_pressed)

	_clear_children(_speed_options_box)
	_speed_buttons.clear()
	# A10: the rail raises on one tap and any of the four targets is the second.
	for option: Dictionary in (model.speed_view(_speed, _paused)["options"] as Array):
		var id: StringName = option["id"]
		var button := Button.new()
		button.name = "Speed_" + String(id)
		button.theme_type_variation = &"RailButton"
		button.focus_mode = Control.FOCUS_NONE
		button.toggle_mode = true
		button.custom_minimum_size = button_size
		button.text = str(option["text"])
		button.tooltip_text = _text("ui_hud_speed_%s" % String(id), str(option["text"]))
		button.pressed.connect(_on_speed_option_pressed.bind(id))
		_speed_options_box.add_child(button)
		_speed_buttons[id] = button
	_speed_options_box.visible = _rail_expanded


func _build_alert_rows() -> void:
	if _alert_stack == null:
		return
	_clear_children(_alert_stack)
	_alert_rows.clear()
	var layout := config.layout()
	var raw: Variant = layout.get("alert_dp", [400, 44])
	var alert_dp: Array = raw if raw is Array and (raw as Array).size() >= 2 else [400, 44]
	var max_stack := UIConfig.get_int(layout, "alert_max_stack", 2)
	for i in max_stack:
		var panel := PanelContainer.new()
		panel.name = "Alert%d" % i
		panel.theme_type_variation = &"AlertBanner"
		# A3 wins over the doc's 44 dp banner height: the row carries a tap target.
		# The 400 dp width is a *maximum*, not a demand — a 412 dp phone has 404 dp
		# of safe area, and 400 plus the panel's own margins put the banner's VIEW
		# button off the right edge of the screen.
		panel.custom_minimum_size = Vector2(_banner_width_dp(float(alert_dp[0])),
				maxf(float(alert_dp[1]), _touch_min))
		panel.visible = false
		var row := HBoxContainer.new()
		row.name = "Row"
		panel.add_child(row)
		var badge := Label.new()
		badge.name = "Badge"
		badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(badge)
		var title := Label.new()
		title.name = "Title"
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		# The one line on the banner allowed to run long, so it is the one that
		# shortens — with an ellipsis, and never below a readable floor.
		UIWidgets.elide(title, _touch_min * 2.0)
		row.add_child(title)
		var view := Button.new()
		view.name = "View"
		view.theme_type_variation = &"GhostButton"
		view.focus_mode = Control.FOCUS_NONE
		view.custom_minimum_size = Vector2(_touch_min, _touch_min)
		view.text = _text("ui_hud_alert_view", "VIEW")
		view.tooltip_text = view.text
		row.add_child(view)
		_alert_stack.add_child(panel)
		_alert_rows.append({"panel": panel, "badge": badge, "title": title,
				"view": view, "alert_id": ""})
		view.pressed.connect(_on_alert_pressed.bind(i))


# ---------------------------------------------------------------------------
# Binding
# ---------------------------------------------------------------------------

## The one entry point `game/main.gd` calls. `snapshot` is plain data — see
## `HudModel.build_view()` for the key list; the HUD never holds a sim reference.
func refresh(snapshot: Dictionary) -> void:
	_last_snapshot = snapshot
	if model == null:
		return
	_speed = int(snapshot.get("speed", _speed))
	_paused = bool(snapshot.get("paused", _paused))
	var view := model.build_view(snapshot, _width_dp(), _clock_width_dp(),
			_measure_chips(snapshot), _max_rows)
	_apply_chips(view["chips"])
	_apply_rows((view["top_bar"] as Dictionary)["rows"] as Array)
	_apply_clock(view["clock"])
	_apply_speed(view["speed"])
	if _speed_button != null:
		UIWidgets.place_in_rail(_speed_button.get_parent() as Control, 2,
				config.layout(), _touch_min)
	_render_alerts(_now_s())


## The ⚡ and 💧 chips' readings, `{power01, water01}` on `[0, 1]` (doc 12 §2.4
## P3/P4). Separate from `refresh()` because docs 04/05 settle them on the
## game-hour boundary while the HUD repaints several times a second — the shell
## calls this once an hour and `refresh()` picks the stored reading up.
func ingest_service(snapshot: Dictionary) -> void:
	if model == null:
		return
	model.ingest_service(snapshot)
	if not _last_snapshot.is_empty():
		refresh(_last_snapshot)


## Overrides the measured layout width (dp). The tests and the screenshot
## harness use it to solve the top bar for a device box — a Fold's near-square
## inner display, say — without opening a window that size.
func set_width_dp(width_dp: float) -> void:
	_width_override = width_dp
	if not _last_snapshot.is_empty():
		refresh(_last_snapshot)


func _width_dp() -> float:
	if _width_override > 1.0:
		return _width_override
	var w := size.x
	if w <= 1.0:
		var parent := get_parent() as Control
		w = parent.size.x if parent != null else 0.0
	return w if w > 1.0 else REFERENCE_WIDTH_DP


## The clock chip and the menu button share row 0 with the stat chips, so both
## come out of the chips' budget (§2.4's `avail = W - clock_w - 16`).
##
## Three chip gaps, not one: row 0 ends `… chip │ spacer │ clock │ menu`, and an
## `HBoxContainer` puts its separation between every pair. Under-reserving them
## is how a bar that solves to exactly `avail` still overflows by 18 dp.
func _clock_width_dp() -> float:
	var clock_w := UIConfig.get_num(config.layout(), "clock_chip_w_dp", 132.0)
	if _clock_chip != null:
		clock_w = maxf(clock_w, _clock_chip.custom_minimum_size.x)
	if _menu_button != null and _menu_button.visible:
		clock_w += _menu_button.custom_minimum_size.x
	return clock_w + _chip_gap * 3.0


## What each chip's text actually needs, in dp, for both collapse modes. The
## solver widens the doc's budget to this, which is what stops a value string
## from clipping on a narrow display (A1/A2) — and it is measured against the
## live theme, so a text-scale change re-measures for free.
func _measure_chips(snapshot: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if model == null:
		return out
	var values := model.chip_values(snapshot)
	for chip_id: Variant in _chips:
		var button: Button = _chips[chip_id]
		var chip: Dictionary = values.get(str(chip_id), {})
		if chip.is_empty():
			continue
		out[str(chip_id)] = {
			"full": _measure_text(button, _chip_text(chip, str(chip["text_full"]))),
			"compact": _measure_text(button, _chip_text(chip, str(chip["text_compact"]))),
		}
	return out


## Text width plus the theme's own horizontal content margins — the two halves
## of what a themed Button needs before `clip_text` starts eating characters.
static func _measure_text(control: Control, text: String) -> float:
	if control == null or text == "":
		return 0.0
	var font := control.get_theme_font(&"font")
	if font == null:
		return 0.0
	var font_size := control.get_theme_font_size(&"font_size")
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			font_size).x
	var box := control.get_theme_stylebox(&"normal")
	if box != null:
		width += box.content_margin_left + box.content_margin_right
	return ceilf(width)


func _apply_chips(chips: Array) -> void:
	for entry: Variant in chips:
		var chip: Dictionary = entry
		var button: Button = _chips.get(str(chip["id"]), null)
		if button == null:
			continue
		var mode: StringName = chip["mode"]
		button.visible = mode != HudModel.MODE_HIDDEN
		if not button.visible:
			continue
		button.custom_minimum_size = Vector2(float(chip["width_dp"]), _touch_min)
		button.text = _chip_text(chip, str(chip["text"]))
		button.set_meta("state", chip["state"])
		button.set_meta("pulse", bool(chip.get("pulse", false)))
		_apply_state_color(button, chip["state"])


## Re-parents the chips into the rows the solver produced. Hidden chips stay in
## row 0 as invisible children — a container skips those, and keeping them in
## the tree means no chip is ever an orphan waiting to be freed.
##
## Row 0 always ends with a spacer, the clock chip and the ☰ button, which is the
## line `HudModel.solve_top_bar` reserves `clock_w` on. Both are detached first:
## a row that is about to be freed must never still own them.
func _apply_rows(rows: Array) -> void:
	if _chips_box == null:
		return
	var signature := str(rows)
	if signature == _row_signature:
		return
	_row_signature = signature
	for chip_id: Variant in _chips:
		CityHUD._detach(_chips[chip_id] as Button)
	CityHUD._detach(_clock_chip)
	CityHUD._detach(_menu_button)
	# The spacer is rebuilt each pass, so the previous one has to go or row 0
	# grows by 8 dp of nothing on every reflow.
	for i in _chips_box.get_child_count():
		var stale := _chips_box.get_child(i).get_node_or_null("ClockGap")
		if stale != null:
			stale.get_parent().remove_child(stale)
			stale.free()
	var wanted := maxi(1, rows.size())
	while _chips_box.get_child_count() < wanted:
		_chips_box.add_child(_new_chip_row(_chips_box.get_child_count()))
	while _chips_box.get_child_count() > wanted:
		var extra := _chips_box.get_child(_chips_box.get_child_count() - 1)
		_chips_box.remove_child(extra)
		extra.free()
	var placed: Dictionary = {}
	for i in rows.size():
		var row := _chips_box.get_child(i) as HBoxContainer
		for chip_id: Variant in (rows[i] as Array):
			var button: Button = _chips.get(str(chip_id), null)
			if button == null:
				continue
			row.add_child(button)
			placed[str(chip_id)] = true
	var first_row := _chips_box.get_child(0) as HBoxContainer
	for chip_id: Variant in _chips:
		if not placed.has(str(chip_id)):
			first_row.add_child(_chips[chip_id] as Button)
	first_row.add_child(UIWidgets.spacer("ClockGap"))
	if _clock_chip != null:
		first_row.add_child(_clock_chip)
	if _menu_button != null:
		first_row.add_child(_menu_button)
	_reposition_alert_stack()


## How wide a banner may actually be: the doc's figure, or the room the display
## has, whichever is smaller.
func _banner_width_dp(doc_w: float) -> float:
	return maxf(_touch_min, minf(doc_w, _width_dp() - _spacing * 2.0))


## The banner stack sits under the top bar (§2.3); when the bar wraps to two rows
## the banners follow it down instead of landing on top of the chips. Its width
## is re-solved here too, because the bar and the stack share one display and the
## stack is centre-anchored with hard offsets in the scene.
func _reposition_alert_stack() -> void:
	if _alert_stack == null or _top_bar == null:
		return
	var bar_h := maxf(_top_bar.get_combined_minimum_size().y,
			UIConfig.get_num(config.layout(), "top_bar_h_dp", 48.0))
	var height := _alert_stack.offset_bottom - _alert_stack.offset_top
	_alert_stack.offset_top = bar_h + _spacing
	_alert_stack.offset_bottom = _alert_stack.offset_top + maxf(height, 0.0)
	var raw: Variant = config.layout().get("alert_dp", [400, 44])
	var doc_w: float = float((raw as Array)[0]) if raw is Array \
			and (raw as Array).size() >= 2 else 400.0
	var half := _banner_width_dp(doc_w) * 0.5
	_alert_stack.offset_left = -half
	_alert_stack.offset_right = half
	for row: Dictionary in _alert_rows:
		(row["panel"] as PanelContainer).custom_minimum_size.x = half * 2.0


func _chip_text(chip: Dictionary, text: String) -> String:
	var parts: PackedStringArray = []
	var glyph := str(chip["glyph"])
	if glyph != "":
		parts.append(glyph)
	parts.append(text)
	# A5: colour is never load-bearing, so a non-NORMAL chip also carries the
	# state glyph. NORMAL stays clean — the §2.3 mock has no glyph on a good chip.
	var state_glyph := str(chip["state_glyph"])
	if state_glyph != "" and chip["state"] != HudModel.STATE_NORMAL:
		parts.append(state_glyph)
	if str(chip["id"]) == "incidents" and int(chip.get("badge_tier", 0)) > 0:
		parts.append("T%d" % int(chip["badge_tier"]))
	return " ".join(parts)


func _apply_clock(clock: Dictionary) -> void:
	if _clock_chip == null:
		return
	var glyph := str(clock.get("weather_glyph", ""))
	_clock_chip.text = ("%s %s" % [glyph, clock["time"]]).strip_edges() \
			if glyph != "" else str(clock["time"])
	_clock_chip.tooltip_text = _text_args("ui_hud_day",
			{"day": int(clock["day_index"]) + 1}, str(clock["day"]))


func _apply_speed(view: Dictionary) -> void:
	if _speed_button != null:
		_speed_button.text = str(view["face"])
	for option: Variant in (view["options"] as Array):
		var entry: Dictionary = option
		var button: Button = _speed_buttons.get(entry["id"], null)
		if button == null:
			continue
		button.set_pressed_no_signal(bool(entry["selected"]))
		_apply_state_color(button, HudModel.STATE_NORMAL if bool(entry["selected"]) else &"")
	if _speed_options_box != null:
		_speed_options_box.visible = _rail_expanded


func _render_alerts(now_s: float) -> void:
	if _alert_stack == null or model == null:
		return
	var alerts := model.active_alerts(now_s)
	for i in _alert_rows.size():
		var row: Dictionary = _alert_rows[i]
		var panel: PanelContainer = row["panel"]
		if i >= alerts.size():
			panel.visible = false
			row["alert_id"] = ""
			continue
		var alert: Dictionary = alerts[i]
		panel.visible = true
		row["alert_id"] = str(alert["id"])
		var count := int(alert["count"])
		(row["badge"] as Label).text = String(alert["class"]).to_upper()
		var title := str(alert["title"])
		(row["title"] as Label).text = title if count <= 1 else "%s (%d)" % [title, count]
		_apply_state_color(row["badge"] as Label,
				HudModel.STATE_CRITICAL if str(alert["class"]) == "p1"
				else HudModel.STATE_WARNING)


## Raise an in-app alert through the §2.13 gate. Returns the gate's verdict —
## `{delivered, surface, coalesced, reason, id, count}`; a refused banner has
## already been turned into a toast by the model.
func push_alert(alert: Dictionary, now_s: float = -1.0) -> Dictionary:
	if model == null:
		return {}
	var stamp := now_s if now_s >= 0.0 else _now_s()
	var verdict := model.submit_alert(stamp, alert)
	_render_alerts(stamp)  # the same clock, or the new banner prunes on arrival
	if StringName(str(verdict.get("surface", ""))) == HudModel.SURFACE_TOAST:
		var toast := model.active_toast(stamp)
		if not toast.is_empty():
			toast_requested.emit(str(toast["title"]),
					HudModel.STATE_CRITICAL if str(toast["class"]) == "p1"
					else HudModel.STATE_WARNING)
	return verdict


func _process(delta: float) -> void:
	_alert_timer += delta
	if _alert_timer >= ALERT_REFRESH_S:
		_alert_timer = 0.0
		_render_alerts(_now_s())
	if _reduce_motion:  # A8: pulses are motion
		return
	_pulse_phase = fmod(_pulse_phase + delta * _pulse_hz, 1.0)
	var alpha := 0.65 + 0.35 * (0.5 + 0.5 * cos(TAU * _pulse_phase))
	for chip_id: Variant in _chips:
		var button: Button = _chips[chip_id]
		if not button.visible:
			continue
		button.modulate.a = alpha if bool(button.get_meta("pulse", false)) else 1.0


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _on_chip_pressed(chip_id: StringName) -> void:
	chip_activated.emit(chip_id)


func _on_clock_pressed() -> void:
	clock_activated.emit()


func _on_menu_pressed() -> void:
	menu_requested.emit()


func _on_speed_button_pressed() -> void:
	_rail_expanded = not _rail_expanded
	if _speed_options_box != null:
		_speed_options_box.visible = _rail_expanded


func _on_speed_option_pressed(option: StringName) -> void:
	var next := model.apply_speed_option(option, _speed, _paused)
	var was_paused := _paused
	_speed = int(next["speed"])
	_paused = bool(next["paused"])
	_rail_expanded = false
	_apply_speed(model.speed_view(_speed, _paused))
	if _paused != was_paused:
		pause_toggled.emit(_paused)
	if option != HudModel.SPEED_PAUSE:
		speed_selected.emit(_speed)


func _on_alert_pressed(row_index: int) -> void:
	if row_index >= _alert_rows.size():
		return
	var alert_id := str((_alert_rows[row_index] as Dictionary)["alert_id"])
	if alert_id == "":
		return
	model.dismiss_alert(alert_id)
	_render_alerts(_now_s())
	alert_activated.emit(alert_id)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func is_speed_rail_expanded() -> bool:
	return _rail_expanded


func chip_button(chip_id: String) -> Button:
	return _chips.get(chip_id, null)


func speed_option_button(option: StringName) -> Button:
	return _speed_buttons.get(option, null)


func _chip_label(chip_id: String) -> String:
	return _text(HudModel.chip_label_key(chip_id),
			str(HudModel.CHIP_LABELS.get(chip_id, chip_id)))


## `data/strings.en.json` first (G-8); the fallback covers the HUD keys that
## table does not carry yet and never overrides one that it does.
func _text(key: String, fallback: String) -> String:
	if config != null and config.has_string(key):
		return config.t(key)
	return fallback


## Same contract with `{named}` arguments (G-8): the table first, the fallback
## only while a key is missing.
func _text_args(key: String, args: Dictionary, fallback: String) -> String:
	if config != null and config.has_string(key):
		return config.t(key, args)
	return fallback


func menu_button() -> Button:
	return _menu_button


## Both of these move into top-bar row 0 at bring-up (see `_adopt_trailing_block`),
## so nothing outside this file should reach them by node path.
func clock_chip() -> Button:
	return _clock_chip


## Which top-bar row each visible chip landed on — what the layout tests assert
## against, and what a screenshot harness prints.
func chip_rows() -> Array:
	var out: Array = []
	if _chips_box == null:
		return out
	for i in _chips_box.get_child_count():
		var row := _chips_box.get_child(i) as HBoxContainer
		if row == null:
			continue
		var ids: Array[String] = []
		for child in row.get_children():
			var button := child as Button
			# Row 0 also carries the clock chip and the ☰ button (they share its
			# line, §2.4's `clock_w`); neither is a *reading*.
			if button != null and button.visible and str(button.name).begins_with("Chip_"):
				ids.append(str(button.name).trim_prefix("Chip_"))
		out.append(ids)
	return out


func _apply_state_color(control: Control, state: StringName) -> void:
	if state == &"" or not has_theme_color(state, PALETTE_TYPE):
		control.remove_theme_color_override(&"font_color")
		return
	control.add_theme_color_override(&"font_color", get_theme_color(state, PALETTE_TYPE))


static func _now_s() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
