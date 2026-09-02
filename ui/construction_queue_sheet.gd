class_name ConstructionQueueSheet
extends Control
## **S16 (doc 12 §2.22) — the construction queue.** One row per project the city
## has under way: what it is, the level it is climbing to, a live bar, when it
## lands, who is on it, and what it costs to make it land now.
##
## Same shape as `AlertsCenter` and `EventLog` — a persistent chip plus a panel
## that is not — so all three live on `PanelLayer`, `UIWidgets.close_siblings()`
## keeps exactly one of them up, and `is_open()` / `close()` are the `UIRoot`
## back-stack protocol so Android BACK closes the panel without touching the chip.
##
## **A side panel and not a modal, and the reason is the camera.** Tapping a row
## focuses the site it names, and a full-screen scrim would have to be dismissed
## before the player could see the thing they asked to look at. The incident
## drawer settled this one screen over (§2.6): a list whose rows point AT the
## city has to leave the city visible.
##
## Every value comes from `ConstructionQueueModel`, which in turn reads only
## `CitySim.construction_overview()` and `CitySim.cmd_rush_construction()`. This
## file decides nothing except which pixels those become — no price, no ETA
## arithmetic, no affordability rule.

signal focus_requested(world_pos: Vector3)            ## row tap → camera jump
signal job_activated(job_id: int)                     ## row tap, focus or not
signal rushed(job_id: int, result: Dictionary)        ## the door answered
signal panel_toggled(open: bool)

## A5: the chip is never the colour alone. `⚒` is the kind of thing the chip is
## about; the count beside it is the value.
const CHIP_GLYPH := "⚒"
const CLOSE_GLYPH := "✕"
## The rung of the bottom-right rail this screen takes — above the event log's,
## which is the least urgent of the four (§2.22). Named because
## `tests/test_ui_audit.gd` asserts the four indices against these constants
## rather than against literals.
const RAIL_INDEX := 3

var config: UIConfig
var model: ConstructionQueueModel

var _chip: Button
var _panel: PanelContainer
var _title: Label
var _close: Button
var _summary: Label
var _empty: Label
var _list: VBoxContainer

var _rows: Dictionary = {}        # job_id -> Button (the row head)
var _rush_buttons: Dictionary = {}  # job_id -> Button
var _locator := Callable()
var _touch_min := 48.0
var _spacing := 8.0
var _row_h := 96.0
var _bar_h := 6.0


func setup(cfg: UIConfig = null, p_model: ConstructionQueueModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	if p_model != null:
		model = p_model
	if model == null:
		model = ConstructionQueueModel.new(config)
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_row_h = maxf(model.row_h_dp(), _touch_min)
	_bar_h = model.bar_h_dp()
	_bind_nodes()
	_build_static()
	close()
	refresh()


func _ready() -> void:
	if config == null:
		setup(UIRoot.config_from(self))


func _bind_nodes() -> void:
	_chip = get_node_or_null("Chip") as Button
	_panel = get_node_or_null("Panel") as PanelContainer
	_title = get_node_or_null("Panel/Body/Header/Title") as Label
	_close = get_node_or_null("Panel/Body/Header/Close") as Button
	_summary = get_node_or_null("Panel/Body/Summary") as Label
	_empty = get_node_or_null("Panel/Body/Empty") as Label
	_list = get_node_or_null("Panel/Body/Scroll/List") as VBoxContainer


func _build_static() -> void:
	if _chip != null:
		_chip.theme_type_variation = &"StatChip"
		_chip.focus_mode = Control.FOCUS_NONE
		_chip.custom_minimum_size = Vector2(
				maxf(model.chip_w_dp(), _touch_min), _touch_min)
		_chip.text = CHIP_GLYPH
		_chip.tooltip_text = model.chip_tooltip()  # A15
		if not _chip.pressed.is_connected(toggle):
			_chip.pressed.connect(toggle)
	if _panel != null:
		_panel.custom_minimum_size = Vector2(model.panel_w_dp(), 0.0)
	if _title != null:
		_title.text = UIWidgets.t(config, "ui_queue_title", "Under construction")
		# Authored with `clip_text` in the scene, which reports a one-pixel
		# minimum and collapses beside the header's ✕. It may shorten — but only
		# down to a floor (`AlertsCenter`'s lesson).
		UIWidgets.elide(_title, _touch_min * 2.0)
	if _close != null:
		_close.theme_type_variation = &"GhostButton"
		_close.focus_mode = Control.FOCUS_NONE
		_close.custom_minimum_size = Vector2(_touch_min, _touch_min)
		_close.text = CLOSE_GLYPH
		_close.tooltip_text = UIWidgets.t(config, "ui_queue_close", "Close the queue")
		if not _close.pressed.is_connected(close):
			_close.pressed.connect(close)
	if _empty != null:
		_empty.text = UIWidgets.t(config, "ui_queue_empty",
				"Nothing is being built right now.")
	if _list != null:
		_list.add_theme_constant_override(&"separation", int(_spacing))


# ---------------------------------------------------------------------------
# Binding
# ---------------------------------------------------------------------------

## `Callable(kind: StringName, id) -> Vector3`, called as `(&"tile", Vector2i)` —
## the same shape and, in the shell, literally the same function the drawer and
## the alerts centre already take (`game/main.gd::_alert_world_pos`). That is why
## the camera half of this screen needs no new shell wiring: `UIRoot.
## set_incident_locator()` hands it over on the call the shell already makes.
func set_locator(locator: Callable) -> void:
	_locator = locator


## The contract row's tile, through the shell's map, into a camera target. `null`
## — an unresolvable id, or no locator at all — means the row simply does not
## jump, which is what a fixture mount and a headless test both want.
func _world_of(tile: Vector2i) -> Variant:
	if not _locator.is_valid():
		return null
	return _locator.call(&"tile", tile)


## Re-reads the provider and repaints. Rides the shell's 1 Hz HUD cadence: the
## bars have to move while the panel is open, and the chip's badge has to be
## right while it is not.
func refresh() -> void:
	if model == null:
		return
	model.refresh()
	_refresh_chip()
	if not is_open():
		return
	_apply_panel_width()
	_refresh_list()


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _panel != null and _panel.visible


func open() -> void:
	UIWidgets.close_siblings(self)   # one panel at a time on PanelLayer
	if _panel != null:
		_panel.visible = true
	# The chip and the panel share the right edge and the chip draws over it.
	if _chip != null:
		_chip.visible = false
	refresh()
	panel_toggled.emit(true)


func close() -> void:
	if _panel != null:
		_panel.visible = false
	if _chip != null:
		_chip.visible = _has_work()
	panel_toggled.emit(false)


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


# ---------------------------------------------------------------------------
# The rail
# ---------------------------------------------------------------------------

## The THIRD chip rung of the bottom-right rail — above the alerts chip and the
## event log's, and beside the drawer's tab (`UIWidgets.solve_corner_rail`).
##
## **It is also the first rung that can be absent**, which is why the wrapping
## solver arrived with it: at `640 × 340` with 150 % text and larger targets a
## third rung in one column lands at y −48 of a 340 dp box. The solver wraps it
## into a second column instead of hiding a door.
func corner_rail_entry() -> Dictionary:
	return {"control": _chip, "index": RAIL_INDEX}


## Same corner discipline as `AlertsCenter` and `EventLog` (doc 91 D-12), plus
## this screen's own rule: **an empty queue has no affordance at all.** A chip
## that says `0` is a chip that teaches the player to stop looking at it, and
## every other reading on this HUD is about something that is happening.
func _process(_delta: float) -> void:
	_fit_rows()
	if _chip == null or is_open():
		return
	_chip.visible = _has_work() and not UIWidgets.any_sibling_open(self)
	UIWidgets.solve_corner_rail(self, config.layout(), _touch_min, size.y)


func _has_work() -> bool:
	return model != null and not model.is_empty()


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func _refresh_chip() -> void:
	if _chip == null:
		return
	var badge := model.badge_text()
	_chip.text = ("%s %s" % [CHIP_GLYPH, badge]).strip_edges() if badge != "" \
			else CHIP_GLYPH
	_chip.tooltip_text = model.chip_tooltip()
	if not is_open():
		_chip.visible = _has_work() and not UIWidgets.any_sibling_open(self)
	# `⚒ 3` is wider than `⚒`, and the chip grows leftward out of a column the
	# rail owns — so a badge changing is a re-solve, not just a repaint.
	UIWidgets.solve_corner_rail(self, config.layout(), _touch_min, size.y)


## The right-edge column, solved against the display it is on — the same call
## the alerts feed and the drawer make, so the three never disagree about how
## wide a side panel is on a 360 dp phone.
func _apply_panel_width() -> void:
	if _panel == null or size.x <= 1.0:
		return
	var layout := config.layout()
	var width := UIWidgets.side_panel_width(size.x,
			_panel.get_combined_minimum_size().x,
			UIConfig.get_num(layout, "drawer_w_ratio", 0.34),
			model.panel_w_dp(),
			UIConfig.get_num(layout, "drawer_w_max_dp", 340.0),
			_touch_min)
	_panel.offset_left = -width


func _refresh_list() -> void:
	if _list == null:
		return
	# `release_children`, not `clear_children`: `_on_rush_pressed` rebuilds this
	# list from INSIDE the pressed button's own signal, and the row the door just
	# took is the row that button lives in. Freeing it there is an engine error
	# and a potential crash; detaching now and freeing at frame end is not
	# (`tests/test_ui_construction_queue.gd`, the tap-then-rush test).
	UIWidgets.release_children(_list)
	_rows.clear()
	_rush_buttons.clear()
	var rows := model.rows()
	if _empty != null:
		_empty.visible = rows.is_empty()
	if _summary != null:
		_summary.text = model.summary_text()
		_summary.visible = _summary.text != ""
	for row: Dictionary in rows:
		_list.add_child(_build_row(row))


## One project.
##
## The shape is the incident drawer's, for the reason D-47 gives: a row head that
## is the whole tap target, with its actions as a **sibling `HFlowContainer`
## below it** rather than as children of the button. Two independent targets in a
## 320 dp column that both have to clear 48 dp cannot share a line at 150 % text,
## and a flow container drops the tail onto a second line instead of widening the
## panel that holds it.
func _build_row(row: Dictionary) -> VBoxContainer:
	var job_id := int(row["job_id"])
	var holder := VBoxContainer.new()
	holder.name = "Job_%d" % job_id
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_theme_constant_override(&"separation", int(_spacing * 0.5))

	var tooltip := "%s — %s" % [str(row["title"]),
			UIWidgets.t(config, "ui_queue_focus", "Show me")]
	var button := UIWidgets.button("Row_%d" % job_id, "", tooltip,
			Vector2(_touch_min, _row_h), &"DrawerRow")
	button.pressed.connect(_on_row_pressed.bind(job_id))
	holder.add_child(button)
	_rows[job_id] = button

	var body := VBoxContainer.new()
	body.name = "Body"
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Inside the row, not on its edge: the panel's scrollbar lives there.
	body.offset_left = _spacing
	body.offset_right = -_spacing
	body.add_theme_constant_override(&"separation", 0)
	button.add_child(body)

	var head := UIWidgets.label("Title", str(row["title"]), &"", true)
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(head)

	# The kind and the level climb, on one line. Both are words: `source` is not
	# one of §2.5's data states, so it takes no colour and needs no glyph.
	var kind_text := str(row["source_label"])
	if str(row["level_text"]) != "":
		kind_text = "%s %s %s" % [kind_text,
				UIWidgets.t(config, "ui_queue_separator", "·"), str(row["level_text"])]
	body.add_child(UIWidgets.label("Kind", kind_text, &"LegendRow", true))

	var clock := HBoxContainer.new()
	clock.name = "Clock"
	clock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clock.add_theme_constant_override(&"separation", int(_spacing))
	body.add_child(clock)
	var bar := MeterBar.new()
	bar.name = "Progress"
	bar.custom_minimum_size = Vector2(_touch_min, maxf(4.0, _bar_h))
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# A5: a stalled bar is HATCHED as well as amber, which is the same channel
	# §2.6's held escalation clock uses for the same fact.
	bar.set_value(float(row["progress01"]), row["state"], not bool(row["working"]))
	clock.add_child(bar)
	var percent := UIWidgets.label("Percent", str(row["percent_text"]))
	UIWidgets.paint_state(self, percent, row["state"])
	clock.add_child(percent)

	var status := HBoxContainer.new()
	status.name = "Status"
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status.add_theme_constant_override(&"separation", int(_spacing))
	body.add_child(status)
	# **The ETA is a sentence, and when nothing is working the project it says so
	# out loud** (§2.8's rule): `0:00` reads as *finishing now* and this is its
	# opposite. The model writes the words; this line only paints them.
	var eta := UIWidgets.label("Eta", str(row["eta_text"]), &"", true)
	eta.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIWidgets.paint_state(self, eta, row["state"])
	status.add_child(eta)
	var crew := UIWidgets.label("Crew", str(row["crew_text"]))
	UIWidgets.paint_state(self, crew,
			&"" if bool(row["working"]) else HudModel.STATE_WARNING)
	status.add_child(crew)

	holder.add_child(_build_actions(row))
	return holder


## The RUSH button, with the quoted price on its FACE — the build-card pattern
## (§2.7), and the reason §2.22 rules a rush one-tap rather than confirmed: a
## button that names what it will take has already asked.
##
## Unaffordable is DISABLED-WITH-PRICE, never hidden and never blank: the price
## is the reading, and a control that vanishes when the player cannot afford it
## takes the number they needed with it.
func _build_actions(row: Dictionary) -> HFlowContainer:
	var job_id := int(row["job_id"])
	var bar := HFlowContainer.new()
	bar.name = "Actions"
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_constant_override(&"h_separation", int(_spacing))
	bar.add_theme_constant_override(&"v_separation", int(_spacing))
	if not bool(row["rushable"]):
		return bar
	var button := UIWidgets.button("Rush_%d" % job_id, str(row["rush_text"]),
			str(row["rush_tooltip"]),
			Vector2(maxf(_touch_min * 2.0, 96.0), _touch_min), &"PrimaryFAB")
	button.clip_text = false
	button.disabled = not bool(row["affordable"])
	button.pressed.connect(_on_rush_pressed.bind(job_id))
	bar.add_child(button)
	_rush_buttons[job_id] = button
	return bar


## Grows each row to the height its own copy needs.
##
## The row is a `Button` and its four lines are an **anchored** child, so they
## contribute nothing to the button's minimum: at 150 % text a wrapped title
## simply pushed the ETA sentence out of the fixed row, which is the one line
## this screen exists to show. An autowrapped `Label` only knows its height once
## it knows its width, so this is polled rather than computed at build time —
## it settles on the first frame the panel is open and then costs a cached
## lookup per row. `AlertsCenter._fit_rows()` is the same fix, one screen over.
func _fit_rows() -> void:
	if not is_open() or _list == null:
		return
	for entry: Variant in _rows.values():
		var button := entry as Button
		if button == null:
			continue
		var body := button.get_node_or_null("Body") as Control
		if body == null:
			continue
		button.custom_minimum_size.y = maxf(_row_h,
				body.get_combined_minimum_size().y + _spacing)


# ---------------------------------------------------------------------------
# Verbs
# ---------------------------------------------------------------------------

func _on_row_pressed(job_id: int) -> void:
	job_activated.emit(job_id)
	var row := model.row(job_id)
	if row.is_empty():
		return
	var world: Variant = _world_of(row["tile"] as Vector2i)
	if world is Vector3:
		focus_requested.emit(world as Vector3)


## One tap, and the price was on the button (§2.22's ruling). The door is asked;
## whatever it answers is what the player is told, and the list is re-read from
## the provider rather than predicted — a UI that guesses at success is the
## defect §4.4 exists to forbid.
func _on_rush_pressed(job_id: int) -> void:
	var result := model.rush(job_id)
	rushed.emit(job_id, result)
	refresh()


# ---------------------------------------------------------------------------
# Helpers for the tests and the screenshot harness
# ---------------------------------------------------------------------------

func chip_button() -> Button:
	return _chip


func row_button(job_id: int) -> Button:
	return _rows.get(job_id, null)


func rush_button(job_id: int) -> Button:
	return _rush_buttons.get(job_id, null)


func count() -> int:
	return model.count() if model != null else 0
