class_name IncidentDrawer
extends Control
## The incident drawer (doc 12 §2.6, S6): the handle that always says how bad it
## is, and the list behind it.
##
## Shape follows §2.6 rather than a generic bottom sheet, because the rest of the
## console is already built for it: `data/ui.json.layout` carries
## `drawer_handle_dp [44,160]`, `drawer_handle_center_from_bottom_dp 140` and the
## `drawer_w = clamp(0.34·W, 260, 340)` solver that `UIRoot.drawer_width_dp()`
## implements, and `HudModel.marker_rect(drawer_w, drawer_open)` already reserves
## the right edge so a world pin never hides behind an open drawer. A drawer
## anywhere else would orphan four tunables and a solver.
##
## It lives on `PanelLayer` next to `BuildingPanel` and `AlertsCenter`, which is
## what makes "one 300 dp surface on the right at a time" fall out of
## `UIWidgets.close_siblings()` for free.
##
## Every value is `IncidentModel`'s; this file decides only which pixels they
## become. Tapping a row focuses the camera and selects the incident (§2.6: "Row
## tap anywhere but ASSIGN → focus_on and selects the incident; the drawer stays
## open"), and expands it to the three actions the sim has commands for —
## ASSIGN (which raises the unit picker), acknowledge and pin.
##
## **A fourth action appears on exactly one kind of row.** Doc 05 §2.12's
## `isolate_main` / `restore_main` are a tactical trade — a neighbourhood's taps
## for the fire's hydrants — against a MAIN, and a main is a thing the player
## only ever meets as the target of a `water_main_break`. Doc 93 §J1 rules that
## the pair belongs HERE, on the row that is already telling the player the main
## is open, rather than on a water-node panel the screen map does not have and
## the player would have to go and find mid-incident. It is drawn only when a
## `WaterActions` is bound and the row names a segment the sim still has.

signal focus_requested(world_pos: Vector3)          ## row tap → camera jump
signal incident_selected(incident_id: int)
signal dispatch_requested(incident_id: int)         ## ASSIGN → S7 unit picker
signal acknowledge_requested(incident_id: int)      ## → cmd_acknowledge_incident
signal pin_requested(incident_id: int, pinned: bool) ## → cmd_pin_incident
signal drawer_toggled(open: bool)
## Doc 05 §2.12's pair, already issued. `action` is `&"isolate"` / `&"restore"`
## and `result` is the sim's own `{ok, reason_code, payload}` — the shell re-reads
## the city from it exactly as it does after a building-panel action.
signal main_action_taken(incident_id: int, edge_id: String, action: StringName,
		result: Dictionary)
## Doc 06 §2.11's recall verb, doc 12 §2.6's "assigned units render as chips …
## (tap → `Recall`)". The chip says WHICH unit; the shell issues
## `CitySim.cmd_recall_unit` and answers through `report_recall()`.
signal recall_requested(unit_id: int, incident_id: int)

const HANDLE_GLYPH := "▤"

var config: UIConfig
var model: IncidentModel
## Doc 05 §6's headless verb model, or `null` in a fixture mount. When it is
## null the drawer is exactly the drawer it was — no button, no branch taken.
var water: WaterActions

var _handle: Button
var _panel: PanelContainer
var _title: Label
var _close: Button
var _sort_box: HBoxContainer
var _empty: Label
var _list: VBoxContainer

var _sort_buttons: Dictionary = {}   # StringName order -> Button
var _rows: Dictionary = {}           # incident id:int -> Button
var _actions: Dictionary = {}        # incident id:int -> Container
var _expanded := 0
## Doc 06 §2.11's verb is only a door when a shell has wired it. Without one the
## chips are not drawn at all, on the same terms as the valve (D-43): a control
## that cannot issue its command is worse than no control.
var _recall_enabled := false
var _pulse_phase := 0.0
var _pulse_hz := 1.2
var _reduce_motion := false
var _touch_min := 48.0
var _spacing := 8.0
var _row_h := 72.0
var _drawer_w := 300.0
## The tab's A3 floor. Its drawn width is `max(this, widest line)` and is
## re-solved on every refresh, so a count that shrinks gives the width back.
var _handle_floor_w := 48.0


func setup(cfg: UIConfig = null, p_model: IncidentModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	model = p_model if p_model != null else IncidentModel.new(config)
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_reduce_motion = bool(defaults.get("reduce_motion", false))
	_pulse_hz = UIConfig.get_num(config.section("state_pulse_hz"), "critical", 1.2)
	var layout := config.layout()
	_spacing = UIConfig.get_num(layout, "touch_spacing_min_dp", 8.0)
	_row_h = maxf(UIConfig.get_num(layout, "drawer_row_h_dp", 72.0), _touch_min)
	_drawer_w = maxf(UIConfig.get_num(layout, "drawer_w_min_dp", 260.0), _touch_min)
	_bind_nodes()
	_build_static()
	_build_sort()
	close()
	refresh()


func _ready() -> void:
	if model == null:
		setup(UIRoot.config_from(self))


## Hands the drawer doc 05's node verbs. Idempotent, and safe to call before or
## after `setup()` — the button is built per refresh, not per binding.
func bind_water(actions: WaterActions) -> void:
	water = actions


## `UIRoot.bind_recall()` calls this. Idempotent, and safe before or after
## `setup()` — the chips are built per refresh, not per binding.
func set_recall_enabled(value: bool) -> void:
	if _recall_enabled == value:
		return
	_recall_enabled = value
	refresh()


func recall_enabled() -> bool:
	return _recall_enabled


func _bind_nodes() -> void:
	_handle = get_node_or_null("Handle") as Button
	_panel = get_node_or_null("Panel") as PanelContainer
	_title = get_node_or_null("Panel/Body/Header/Title") as Label
	_close = get_node_or_null("Panel/Body/Header/Close") as Button
	_sort_box = get_node_or_null("Panel/Body/SortScroll/Sort") as HBoxContainer
	if _sort_box == null:
		_sort_box = get_node_or_null("Panel/Body/Sort") as HBoxContainer
	_empty = get_node_or_null("Panel/Body/Empty") as Label
	_list = get_node_or_null("Panel/Body/Scroll/List") as VBoxContainer


func _build_static() -> void:
	var layout := config.layout()
	if _handle != null:
		var raw: Variant = layout.get("drawer_handle_dp", [44, 160])
		var handle: Array = raw if raw is Array and (raw as Array).size() >= 2 else [44, 160]
		# A3 wins over the doc's 44 dp handle width, the same way it wins over the
		# 44 dp banner height in the HUD: a target below 48 dp is not shippable.
		#
		# The handle is a *tab*: fixed width, text stacked down it. It used to get
		# there with `AUTOWRAP_WORD` over a space-joined `▤ 4 T4`, which wraps at
		# the width the button *has* — 48 dp minus 30 dp of StatChip padding, i.e.
		# 18 dp — so the tier line was laid out as `T4` and drawn as `T`. The digit
		# it lost is the one thing on the handle that must survive.
		#
		# The three tokens are therefore newline-joined (see `_refresh_handle`), so
		# the line breaks are ours rather than the wrapper's, and the tab is widened
		# to whatever the widest of them measures.
		_handle.theme_type_variation = &"StatChip"
		_handle.focus_mode = Control.FOCUS_NONE
		_handle.clip_text = false
		_handle.autowrap_mode = TextServer.AUTOWRAP_OFF
		_handle_floor_w = maxf(float(handle[0]), _touch_min)
		_handle.custom_minimum_size = Vector2(_handle_floor_w,
				maxf(float(handle[1]), _touch_min))
		_handle.tooltip_text = UIWidgets.t(config, "ui_drawer_handle")
		if not _handle.pressed.is_connected(toggle):
			_handle.pressed.connect(toggle)
	if _panel != null:
		_panel.custom_minimum_size = Vector2(_drawer_w, 0.0)
	if _title != null:
		_title.text = UIWidgets.t(config, "ui_drawer_title")
		# See `AlertsCenter`: the scene's `clip_text` alone would let the ✕ beside
		# it claim the whole header.
		UIWidgets.elide(_title, _touch_min * 2.0)
	if _close != null:
		_close.theme_type_variation = &"GhostButton"
		_close.focus_mode = Control.FOCUS_NONE
		_close.custom_minimum_size = Vector2(_touch_min, _touch_min)
		_close.text = "✕"
		_close.tooltip_text = UIWidgets.t(config, "ui_drawer_close")
		if not _close.pressed.is_connected(close):
			_close.pressed.connect(close)
	if _empty != null:
		_empty.text = UIWidgets.t(config, "ui_drawer_empty")
	if _list != null:
		_list.add_theme_constant_override(&"separation", int(_spacing))


## The segmented control scrolls sideways, like the build sheet's category row.
## `Priority · Nearest · Newest · Unassigned` is 528 dp of words at 130 % text and
## the panel is 412 dp wide, so two of the four segments were laid out off the
## left edge of the screen — and the sort words are what the player reads to know
## which order the list is in (A1).
func _wrap_sort_in_scroller() -> void:
	if _sort_box == null or _sort_box.get_parent() is ScrollContainer:
		return
	var body := _sort_box.get_parent() as Control
	if body == null:
		return
	var slot := _sort_box.get_index()
	var scroll := ScrollContainer.new()
	scroll.name = "SortScroll"
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.custom_minimum_size = Vector2(_touch_min, _touch_min)
	body.remove_child(_sort_box)
	_sort_box.owner = null
	scroll.add_child(_sort_box)
	_sort_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(scroll)
	body.move_child(scroll, slot)


## §2.6's segmented control: `Priority | Nearest | Newest | Unassigned`, one
## 48 dp target each, the list order it produces owned by the model.
func _build_sort() -> void:
	if _sort_box == null:
		return
	_wrap_sort_in_scroller()
	UIWidgets.clear_children(_sort_box)
	_sort_buttons.clear()
	_sort_box.add_theme_constant_override(&"separation", int(_spacing))
	for order: StringName in model.sort_orders():
		var text := UIWidgets.t(config, "ui_drawer_sort_%s" % String(order))
		# Four segments across `drawer_w`, each still ≥ 48 dp (A3) — the sort words
		# are what the player reads to know which order they are in, so they may
		# not clip (A1).
		var button := UIWidgets.button("Sort_" + String(order), text, text,
				Vector2(maxf(_touch_min,
						(_drawer_w - _spacing * 5.0) / float(maxi(1,
								model.sort_orders().size()))), _touch_min),
				&"TabButton")
		button.clip_text = false
		button.toggle_mode = true
		button.pressed.connect(_on_sort_pressed.bind(order))
		_sort_box.add_child(button)
		_sort_buttons[order] = button
	_paint_sort()


# ---------------------------------------------------------------------------
# Ingest — the shell pipes the sim bus and doc 06's snapshot straight in
# ---------------------------------------------------------------------------

func feed(event: Dictionary) -> Dictionary:
	var row := model.feed(event)
	if not row.is_empty():
		refresh()
	return row


func feed_batch(events: Array) -> Array[Dictionary]:
	var made := model.feed_batch(events)
	if not made.is_empty():
		refresh()
	return made


## Doc 06's `IncidentSystem.snapshot()`. Called on the HUD's own cadence, which
## is what keeps the escalation clocks moving.
func refresh_from(snapshot_rows: Array) -> void:
	model.refresh(snapshot_rows)
	refresh()


func set_now_h(now_h: float) -> void:
	model.set_now_h(now_h)


func set_locator(locator: Callable) -> void:
	model.set_locator(locator)


func set_reference(world_pos: Vector3) -> void:
	model.set_reference(world_pos)


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _panel != null and _panel.visible


func open() -> void:
	UIWidgets.close_siblings(self)
	if _panel != null:
		_panel.visible = true
	refresh()
	drawer_toggled.emit(true)


func close() -> void:
	if _panel != null:
		_panel.visible = false
	_expanded = 0
	drawer_toggled.emit(false)


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


## The tab shares the right edge with every other `PanelLayer` surface, and the
## drawer is the last child of that layer, so it draws **on top**: with the alerts
## feed open, a 48 × 160 dp bookmark floated over two of its rows with a tap
## target on top of theirs. `UIWidgets.close_siblings()` already guarantees one
## surface at a time; this extends that guarantee to the handle.
func set_handle_visible(value: bool) -> void:
	if _handle != null:
		_handle.visible = value


func handle_is_visible() -> bool:
	return _handle != null and _handle.visible


## The tab of the bottom-right rail (`UIWidgets.solve_corner_rail`). Index 0 is
## the affordance that KEEPS the edge: the handle is a bookmark on the display's
## border and reads as one only there, so the chips that share the corner stack
## in the column beside it rather than the other way round (D-16).
func corner_rail_entry() -> Dictionary:
	return {"control": _handle, "index": 0}


## The shell asks for this to size `HudModel.marker_rect()` — a pin must never
## end up behind an open drawer (§2.15).
func drawer_width_dp() -> float:
	return _drawer_w


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func refresh() -> void:
	if model == null:
		return    # a binding that arrived before `setup()` — see `set_recall_enabled`
	_refresh_handle()
	if not is_open():
		return
	_apply_panel_width()
	_paint_sort()
	_refresh_list()


## Re-solves the panel's width against the display it is actually on. Anchored to
## the right edge with `grow_horizontal = BEGIN`, so the offset is the width.
func _apply_panel_width() -> void:
	if _panel == null or size.x <= 1.0:
		return
	var layout := config.layout()
	var width := UIWidgets.side_panel_width(size.x,
			_panel.get_combined_minimum_size().x,
			UIConfig.get_num(layout, "drawer_w_ratio", 0.34),
			UIConfig.get_num(layout, "drawer_w_min_dp", 260.0),
			UIConfig.get_num(layout, "drawer_w_max_dp", 340.0),
			_touch_min)
	_drawer_w = width
	_panel.offset_left = -width


## The collapsed handle: count, worst-tier digit, and the 1.2 Hz pulse §2.6 asks
## for while any T4/T5 is unassigned (driven in `_process`, suppressed by A8's
## reduce-motion the same way the HUD chips are).
func _refresh_handle() -> void:
	if _handle == null:
		return
	var view := model.handle_view()
	var digit := str(view["digit"])
	var lines: PackedStringArray = [HANDLE_GLYPH, str(view["text"])]
	if digit != "":
		lines.append("T" + digit)
	_handle.text = "\n".join(lines)
	_handle.tooltip_text = str(view["tooltip"])
	_handle.set_meta("pulse", bool(view["pulse"]))
	UIWidgets.paint_state(self, _handle, view["state"])
	# The tab is as wide as its widest line plus the chip's padding; a `T5` and a
	# three-digit count both have to fit, and neither may be clipped.
	_handle.custom_minimum_size.x = maxf(_handle_floor_w,
			UIWidgets.needed_width(_handle))
	# The column the tab just claimed is the column the alerts and event-log chips
	# have to keep out of, and the tab's width is only knowable here — so the tab
	# is what re-solves the rail, on the frame the count changes rather than on
	# the one after it (D-16, `UIWidgets.solve_corner_rail`).
	UIWidgets.solve_corner_rail(self, config.layout(), _touch_min)


func _paint_sort() -> void:
	for order: Variant in _sort_buttons:
		var button: Button = _sort_buttons[order]
		var selected: bool = order == model.sort_order()
		button.set_pressed_no_signal(selected)
		UIWidgets.paint_state(self, button,
				HudModel.STATE_NORMAL if selected else &"")


func _refresh_list() -> void:
	if _list == null:
		return
	UIWidgets.clear_children(_list)
	_rows.clear()
	_actions.clear()
	var rows := model.rows()
	if _empty != null:
		_empty.visible = rows.is_empty()
	for row: Dictionary in rows:
		_list.add_child(_build_row(row))


## §2.6's row: severity badge with the tier digit, title, where, the escalation
## bar with its countdown, and — once expanded — the three actions. The whole
## 72 dp band is one tap target; the actions live *below* it rather than inside
## it, because a Button inside a Button cannot be hit.
func _build_row(row: Dictionary) -> VBoxContainer:
	var incident_id := int(row["id"])
	var holder := VBoxContainer.new()
	holder.name = "Incident_%d" % incident_id
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_theme_constant_override(&"separation", int(_spacing))

	var tooltip := "%s — %s" % [str(row["title"]),
			UIWidgets.t(config, "ui_drawer_focus")] if bool(row["has_focus"]) \
			else str(row["title"])
	var button := UIWidgets.button("Row_%d" % incident_id, "", tooltip,
			Vector2(_touch_min, _row_h), &"DrawerRow")
	button.pressed.connect(_on_row_pressed.bind(incident_id))
	holder.add_child(button)
	_rows[incident_id] = button

	var body := HBoxContainer.new()
	body.name = "Body"
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Inside the row, not on its edge: the drawer's scrollbar lives there.
	body.offset_left = _spacing
	body.offset_right = -_spacing
	body.add_theme_constant_override(&"separation", int(_spacing))
	button.add_child(body)

	# A5: the tier DIGIT is the primary channel, the glyph reinforces it, and the
	# colour is third. The badge is readable in greyscale on its own.
	var badge := _fixed(UIWidgets.label("Badge", "T%d %s" % [int(row["tier"]),
			str(row["tier_pips"])]))
	UIWidgets.paint_state(self, badge, row["state"])
	body.add_child(badge)

	var lines := VBoxContainer.new()
	lines.name = "Lines"
	lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(lines)

	var head := UIWidgets.label("Title", ("%s %s %s" % [str(row["glyph"]),
			str(row["title"]), str(row["state_glyph"])]).strip_edges())
	UIWidgets.paint_state(self, head, row["state"])
	lines.add_child(head)
	lines.add_child(UIWidgets.label("Where", str(row["subtitle"])))

	var clock := HBoxContainer.new()
	clock.name = "Clock"
	clock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clock.add_theme_constant_override(&"separation", int(_spacing))
	lines.add_child(clock)
	var bar := MeterBar.new()
	bar.name = "Escalation"
	bar.custom_minimum_size = Vector2(_touch_min, maxf(4.0, _spacing / 2.0))
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.set_value(float(row["escalation01"]), row["escalation_state"], bool(row["held"]))
	clock.add_child(bar)
	var eta := _fixed(UIWidgets.label("Eta", str(row["escalation_text"])))
	UIWidgets.paint_state(self, eta, row["escalation_state"])
	clock.add_child(eta)
	clock.add_child(_fixed(UIWidgets.label("Age", str(row["age_text"]))))

	var actions := _build_actions(row)
	actions.visible = incident_id == _expanded
	holder.add_child(actions)
	_actions[incident_id] = actions
	return holder


## **An `HFlowContainer`, not an `HBox` (D-47's lesson, one screen over).** The
## row was three controls when it was written; it is four on a water break and
## four plus one chip per assigned unit now, and an `HBox` asks its parent for
## the SUM of those. The drawer is `clamp(0.34·W, 260, 340)` dp wide **whatever
## the display is**, so unlike the sheets there is no box where the sum fits: at
## 100 % the four controls of a water row already measure 348 dp against a 300 dp
## panel, and `_apply_panel_width` answered that by *widening the drawer*, one
## affordance at a time, until it ate the city view behind it. A flow container
## asks for its widest child and wraps the rest onto a second line instead, so
## the drawer keeps the width §2.6 gives it and the row grows downward — which is
## the axis a drawer already scrolls on.
func _build_actions(row: Dictionary) -> HFlowContainer:
	var incident_id := int(row["id"])
	var bar := HFlowContainer.new()
	bar.name = "Actions"
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_constant_override(&"h_separation", int(_spacing))
	bar.add_theme_constant_override(&"v_separation", int(_spacing))

	var assign_text := UIWidgets.t(config, "ui_drawer_assign")
	var assign := UIWidgets.button("Assign_%d" % incident_id, assign_text, assign_text,
			Vector2(maxf(_touch_min * 2.0, 96.0), _touch_min), &"PrimaryFAB")
	assign.pressed.connect(_on_assign_pressed.bind(incident_id))
	bar.add_child(assign)

	var ack_text := UIWidgets.t(config, "ui_drawer_acknowledge")
	var ack := UIWidgets.button("Ack_%d" % incident_id, ack_text, ack_text,
			Vector2(maxf(_touch_min * 1.5, 72.0), _touch_min), &"GhostButton")
	ack.clip_text = false
	ack.disabled = bool(row["acknowledged"])
	ack.pressed.connect(_on_ack_pressed.bind(incident_id))
	bar.add_child(ack)

	var pinned := bool(row["pinned"])
	var pin_text := UIWidgets.t(config,
			"ui_drawer_unpin" if pinned else "ui_drawer_pin")
	var pin := UIWidgets.button("Pin_%d" % incident_id, pin_text, pin_text,
			Vector2(maxf(_touch_min * 1.5, 72.0), _touch_min), &"GhostButton")
	pin.clip_text = false
	pin.pressed.connect(_on_pin_pressed.bind(incident_id))
	bar.add_child(pin)

	# §2.12's pair, on the one row that has a main to act on. ISOLATE while the
	# main is live, RESTORE once it is valved out — one control in two moods,
	# because they are never both available and two buttons would put a dead one
	# on a 300 dp row for the whole life of the incident.
	var segment := _segment_view(row)
	if bool(segment.get("exists", false)):
		var valve := UIWidgets.button("Valve_%d" % incident_id,
				_valve_label(bool(segment["can_isolate"])),
				_valve_hint(bool(segment["can_isolate"]), segment),
				Vector2(maxf(_touch_min * 1.5, 84.0), _touch_min), &"GhostButton")
		valve.clip_text = false
		valve.pressed.connect(_on_valve_pressed.bind(incident_id))
		bar.add_child(valve)

	# §2.6's assigned-unit chips. The doc puts them ON the 72 dp band, "replacing
	# the ASSIGN button"; they are in the actions row instead, beside an ASSIGN
	# that stays live, for the same two reasons the actions row itself is below
	# the band: a Button inside a Button cannot be hit, and sending a SECOND unit
	# to a fire that already has one is a verb doc 06 supports and a player wants.
	#
	# A row's `assigned` list is the sim's own `inc.assigned` map, which only ever
	# holds units that were dispatched and have not been released — so a chip
	# exists exactly when doc 06 §2.11 allows a recall, and the legality question
	# needs no second query. The sim still rules: `report_recall()` draws whatever
	# the command answered.
	if _recall_enabled:
		for value: Variant in (row["assigned"] as Array):
			bar.add_child(_build_recall_chip(incident_id, int(value)))
	return bar


func _build_recall_chip(incident_id: int, unit_id: int) -> Button:
	var label := UIWidgets.t_args(config, "ui_drawer_recall", {"unit": unit_id})
	var chip := UIWidgets.button("Recall_%d_%d" % [incident_id, unit_id], label,
			UIWidgets.t_args(config, "ui_drawer_recall_hint", {"unit": unit_id}),
			Vector2(maxf(_touch_min * 1.5, 72.0), _touch_min), &"GhostButton")
	chip.clip_text = false
	chip.pressed.connect(_on_recall_pressed.bind(incident_id, unit_id))
	return chip


## The valve control's two moods, spelled out rather than assembled: G-8 wants
## every key findable by a literal scan, and a key built with `+ "_hint"` is copy
## the orphan check cannot see.
func _valve_label(isolate: bool) -> String:
	return UIWidgets.t(config, "ui_drawer_isolate") if isolate \
			else UIWidgets.t(config, "ui_drawer_restore")


func _valve_hint(isolate: bool, segment: Dictionary) -> String:
	var args := {"main": str(segment.get("edge", "")),
			"zone": str(segment.get("zone", ""))}
	return UIWidgets.t_args(config, "ui_drawer_isolate_hint", args) if isolate \
			else UIWidgets.t_args(config, "ui_drawer_restore_hint", args)


## The main this row is about, or `{}`. Two guards and no guessing: a drawer with
## no `WaterActions` bound never asks, and a row whose `target_ref` is not a
## water segment has nothing to ask about.
func _segment_view(row: Dictionary) -> Dictionary:
	if water == null:
		return {}
	var edge_id := WaterActions.segment_of_row(row)
	if edge_id == "":
		return {}
	return water.segment_view(edge_id)


## §2.6's 1.2 Hz handle pulse. Both tunables are read once in `setup()`, not here:
## `UIConfig.section()` allocates, and this runs every frame.
func _process(delta: float) -> void:
	if _handle == null:
		return
	# Polled rather than wired: `BuildingPanel` and `AlertsCenter` are siblings
	# with no shared `opened` signal, and the drawer is the one that has to yield.
	# Its own panel counts: on a 400 dp-tall landscape box the tab sat on two of
	# the rows it had just opened, and the panel carries its own ✕.
	set_handle_visible(not is_open() and not UIWidgets.any_sibling_open(self))
	# A tab that has stood down frees its column; the chips beside it take it.
	UIWidgets.solve_corner_rail(self, config.layout(), _touch_min)
	if _reduce_motion or not bool(_handle.get_meta("pulse", false)):
		_handle.modulate.a = 1.0    # A8: a pulse is motion
		return
	_pulse_phase = fmod(_pulse_phase + delta * _pulse_hz, 1.0)
	_handle.modulate.a = 0.65 + 0.35 * (0.5 + 0.5 * cos(TAU * _pulse_phase))


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

## §2.6: the row tap focuses the camera **and** selects, and expands the row to
## its actions. It never dispatches — that is one more deliberate tap.
func _on_row_pressed(incident_id: int) -> void:
	_expanded = 0 if _expanded == incident_id else incident_id
	model.select(incident_id if _expanded != 0 else 0)
	for key: Variant in _actions:
		(_actions[key] as Container).visible = int(key) == _expanded
	incident_selected.emit(incident_id)
	var payload := model.focus_payload(incident_id)
	if payload.is_empty() or not bool(payload["has_focus"]):
		return
	focus_requested.emit(payload["world_pos"] as Vector3)


## Doc 06 §2.11's verb, asked. Like ACK and PIN this never calls `refresh()` —
## rebuilding the list here would free the Button that is emitting `pressed`.
## The chip is stood down in place so the player cannot tap it twice while the
## shell is still answering; `report_recall()` decides whether it comes back.
func _on_recall_pressed(incident_id: int, unit_id: int) -> void:
	var chip := recall_button(incident_id, unit_id)
	if chip != null:
		chip.disabled = true
	recall_requested.emit(unit_id, incident_id)


## The shell's answer to a `recall_requested`. On success the model drops the
## unit and the chip goes with it on the next refresh; on a refusal the chip
## comes back live, because the unit is still out there.
func report_recall(unit_id: int, incident_id: int, ok: bool = true) -> void:
	if not ok:
		var chip := recall_button(incident_id, unit_id)
		if chip != null:
			chip.disabled = false
		return
	model.drop_unit(incident_id, unit_id)
	_refresh_handle()


func _on_assign_pressed(incident_id: int) -> void:
	dispatch_requested.emit(incident_id)


## Both action handlers repaint **in place** and never call `refresh()`. Rebuilding
## the list here would free the very Button that is emitting `pressed`, which is an
## engine error — the same trap `AlertsCenter._repaint_rows` documents. The next
## `refresh_from()` redraws them from the sim's word anyway.
func _on_ack_pressed(incident_id: int) -> void:
	model.set_acknowledged(incident_id, true)
	var button := action_button("Ack", incident_id)
	if button != null:
		button.disabled = true
	_refresh_handle()
	acknowledge_requested.emit(incident_id)


## PIN toggles, so the target is read from the model at press time rather than
## bound at build time — that way the button never has to be re-connected while
## it is emitting.
func _on_pin_pressed(incident_id: int) -> void:
	var pinned := not bool(model.row(incident_id).get("pinned", false))
	model.set_pinned(incident_id, pinned)
	var button := action_button("Pin", incident_id)
	if button != null:
		button.text = UIWidgets.t(config,
				"ui_drawer_unpin" if pinned else "ui_drawer_pin")
		button.tooltip_text = button.text
	_refresh_handle()
	pin_requested.emit(incident_id, pinned)


## §2.12's trade, taken. Like `_on_ack_pressed` this repaints the button IN PLACE
## rather than calling `refresh()`: rebuilding the list here would free the Button
## that is emitting `pressed`. The label flips to the other mood on success,
## which is also how the player sees that the valve moved.
func _on_valve_pressed(incident_id: int) -> void:
	var segment := _segment_view(model.row(incident_id))
	if not bool(segment.get("exists", false)):
		return
	var edge_id := str(segment["edge"])
	var isolate := bool(segment["can_isolate"])
	var action: StringName = &"isolate" if isolate else &"restore"
	var result := water.isolate(edge_id) if isolate else water.restore(edge_id)
	var button := action_button("Valve", incident_id)
	if button != null and bool(result["ok"]):
		# The valve moved, so the control shows the OTHER mood — `isolate` is
		# what it just did, and what is available now is its opposite.
		button.text = _valve_label(not isolate)
		button.tooltip_text = _valve_hint(not isolate, segment)
	main_action_taken.emit(incident_id, edge_id, action, result)


func _on_sort_pressed(order: StringName) -> void:
	model.set_sort_order(order)
	refresh()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Pins a value column to its own measured width, so an `EXPAND_FILL` sibling
## takes the slack instead of taking the column.
static func _fixed(label: Label) -> Label:
	label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	return label


func handle_button() -> Button:
	return _handle


func row_button(incident_id: int) -> Button:
	return _rows.get(incident_id, null)


func action_button(prefix: String, incident_id: int) -> Button:
	var actions: Container = _actions.get(incident_id, null)
	if actions == null:
		return null
	return actions.get_node_or_null("%s_%d" % [prefix, incident_id]) as Button


## The recall chip for one unit on one incident, or `null`.
func recall_button(incident_id: int, unit_id: int) -> Button:
	var actions: Container = _actions.get(incident_id, null)
	if actions == null:
		return null
	return actions.get_node_or_null("Recall_%d_%d" % [incident_id, unit_id]) as Button


func sort_button(order: StringName) -> Button:
	return _sort_buttons.get(order, null)


func expanded_id() -> int:
	return _expanded


func count() -> int:
	return model.size() if model != null else 0
