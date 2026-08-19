class_name BuildSheet
extends Control
## S2 + S3 of doc 12 §2.2: the Build FAB, the bottom build sheet (§2.7's card
## list) and the 56 dp `PlacementBar` that replaces it in placement mode.
##
## Dumb by construction (constitution §3, doc 12 §1). Every card value — cost,
## footprint, kW, locked state — comes from `BuildController`, which reads the
## archetype and economy tables; every verdict comes from that controller's
## preflight; every string comes from `data/strings.en.json` through `UIConfig`.
## Nothing here computes a number and nothing here authors a word.
##
## Widgets are built in code rather than authored in the `.tscn` so that widths
## and the 48 dp touch minimum come from `data/ui.json` at runtime and no
## `theme_override_*` property enters a scene file (doc 12 test 19). Every
## interactive `Control` gets `tooltip_text` — that is A15's accessibility name.

signal placement_started(archetype: String, variant: String)  ## card tap accepted
signal placement_changed                                       ## ghost moved / revalidated
signal placement_committed(result: Dictionary)                 ## `place_building` answered
signal placement_cancelled
signal card_refused(failure: Dictionary)  ## locked / unknown card explained in words
signal sheet_toggled(open: bool)

const PALETTE_TYPE := "Palette"
## Every close affordance in the deck is this glyph plus a spoken name in the
## tooltip (`AlertsCenter`, `IncidentDrawer`, `UnitPickerSheet`, `SaveLoadSheet`);
## the sheet reads its name from `ui_build_close` like they do.
const CLOSE_GLYPH := "✕"

var config: UIConfig
var controller: BuildController
var model: HudModel
## Set by `UIRoot`. Doc 12 §2.14: a commit taps, a refusal buzzes, a ghost that
## snaps to a new tile ticks. Never `Input.vibrate_handheld` from here.
var haptics: Haptics

var _fab: Button
var _sheet: PanelContainer
var _tabs: HBoxContainer
var _cards_box: HBoxContainer
var _notice: Label
var _bar: PanelContainer
var _bar_cancel: Button
var _bar_title: Label
var _bar_issue: Label
var _bar_confirm: Button

var _cards: Array[Dictionary] = []
var _tab_buttons: Dictionary = {}   # category -> Button
var _category := ""
var _touch_min := 48.0
var _spacing := 8.0
var _text_scale := 1.0
## Wraps the authored `Tabs` row so six categories plus GRID can be reached on a
## display narrower than they are wide. Built in `_build_static()`, never in the
## scene — see `_wrap_tabs_in_scroller()`.
var _tab_scroll: ScrollContainer
## §2.13's unlock reveal: card ids waiting to be shown off, and the ones
## currently mid-pulse (`card id -> seconds remaining`).
var _pending_unlocks: PackedStringArray = []
var _pulsing: Dictionary = {}
var _pulse_s := 1.2
var _reduce_motion := false
## Ghost state at the last `move_ghost`, so a haptic fires on a *change* rather
## than at the 10 Hz revalidation rate (§2.7) — a buzz per frame is not feedback.
var _last_ghost_origin := Vector2i(-1, -1)
var _last_verdict: StringName = &""


## The one wiring entry point. `game/main.gd` hands over the parsed config and
## the controller; the headless tests call it with fixtures.
func setup(cfg: UIConfig = null, p_controller: BuildController = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	if p_controller != null:
		controller = p_controller
	model = HudModel.new(config)
	var defaults := config.section("defaults")
	_text_scale = maxf(1.0, UIConfig.get_num(defaults, "text_scale", 1.0))
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_reduce_motion = bool(defaults.get("reduce_motion", false))
	_pulse_s = UIConfig.get_num(config.layout(), "unlock_pulse_s", 1.2)
	_bind_nodes()
	_build_static()
	rebuild_cards()
	close()
	_refresh_bar()


func _ready() -> void:
	if config == null:
		# The root's parse, not a second one — see `CityHUD._ready()`.
		setup(UIRoot.config_from(self))


## The FAB owns the bottom-left corner, and three other things want it: this
## sheet, the placement bar, and the unit picker rising from the same edge. Polled
## rather than wired, because `UIWidgets.close_siblings()` only speaks to screens
## that are already open — a closed build sheet is never told the picker arrived.
func _process(delta: float) -> void:
	_advance_pulse(delta)
	if _fab == null:
		return
	_fab.visible = not is_open() and not is_placing() \
			and not UIWidgets.any_sibling_open(self)
	# First slot of §2.3's rail stack, re-solved for the same reason the other two
	# are: a button's height is only knowable once the theme and the layout have
	# both run (see `UIWidgets.place_in_rail`).
	UIWidgets.place_in_rail(_fab, 0, config.layout(), _touch_min)


## `setup()` is called twice in the real shell — once by `UIRoot.bring_up_screens()`
## with the config alone, once by `game/main.gd` with the controller — so this has
## to find the tab row wherever the previous pass left it. The scroller path is
## checked first because that is where the row lives after `_wrap_tabs_in_scroller()`
## has run; the authored path is the first-pass answer.
func _bind_nodes() -> void:
	_fab = get_node_or_null("Fab") as Button
	_sheet = get_node_or_null("Sheet") as PanelContainer
	_tab_scroll = get_node_or_null("Sheet/Body/TabStrip/TabScroll") as ScrollContainer
	_tabs = get_node_or_null("Sheet/Body/TabStrip/TabScroll/Tabs") as HBoxContainer
	if _tabs == null:
		_tabs = get_node_or_null("Sheet/Body/Tabs") as HBoxContainer
	_cards_box = get_node_or_null("Sheet/Body/Scroll/Cards") as HBoxContainer
	_notice = get_node_or_null("Sheet/Body/Notice") as Label
	_bar = get_node_or_null("PlacementBar") as PanelContainer
	_bar_cancel = get_node_or_null("PlacementBar/Row/Cancel") as Button
	_bar_title = get_node_or_null("PlacementBar/Row/Copy/Title") as Label
	if _bar_title == null:
		_bar_title = get_node_or_null("PlacementBar/Row/Title") as Label
	_bar_issue = get_node_or_null("PlacementBar/Row/Copy/Issue") as Label
	if _bar_issue == null:
		_bar_issue = get_node_or_null("PlacementBar/Row/Issue") as Label
	_bar_confirm = get_node_or_null("PlacementBar/Row/Confirm") as Button


static func _clear_children(node: Node) -> void:
	if node == null:
		return
	for child in node.get_children():
		node.remove_child(child)
		child.free()


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build_static() -> void:
	var layout := config.layout()
	var fab_d := maxf(UIConfig.get_num(layout, "fab_d_dp", 64.0), _touch_min)
	if _fab != null:
		_fab.theme_type_variation = &"PrimaryFAB"
		_fab.focus_mode = Control.FOCUS_NONE
		_fab.custom_minimum_size = Vector2(fab_d, fab_d)
		_fab.text = _text("ui_build_open", "BUILD")
		_fab.tooltip_text = _fab.text
		# First slot of §2.3's rail stack — see `UIWidgets.rail_slot`.
		UIWidgets.place_in_rail(_fab, 0, layout, _touch_min)
		if not _fab.pressed.is_connected(toggle):
			_fab.pressed.connect(toggle)
	if _bar_cancel != null:
		_bar_cancel.theme_type_variation = &"GhostButton"
		_bar_cancel.focus_mode = Control.FOCUS_NONE
		_bar_cancel.custom_minimum_size = Vector2(_touch_min, _touch_min)
		_bar_cancel.text = _text("ui_placement_cancel", "CANCEL")
		_bar_cancel.tooltip_text = _bar_cancel.text
		if not _bar_cancel.pressed.is_connected(cancel_placement):
			_bar_cancel.pressed.connect(cancel_placement)
	if _bar_confirm != null:
		_bar_confirm.theme_type_variation = &"PrimaryFAB"
		_bar_confirm.focus_mode = Control.FOCUS_NONE
		_bar_confirm.custom_minimum_size = Vector2(maxf(fab_d, _touch_min), _touch_min)
		_bar_confirm.text = _text("ui_placement_confirm", "PLACE")
		_bar_confirm.tooltip_text = _bar_confirm.text
		if not _bar_confirm.pressed.is_connected(confirm_placement):
			_bar_confirm.pressed.connect(confirm_placement)
	_stack_placement_copy()
	for box: Node in [_tabs, _cards_box]:
		if box != null:
			(box as Control).add_theme_constant_override(&"separation", int(_spacing))
	_wrap_tabs_in_scroller()


## Stacks the placement bar's two sentences instead of racing them for one line.
##
## `CANCEL │ House · $1,200 │ ◆ Tile occupied │ PLACE` is four things on a 56 dp
## row; on a 412 dp phone the two words in the middle had 168 dp between them, so
## the summary rendered as `House · …` and the verdict as a 49 px sliver. Stacked,
## each gets the whole column between the two buttons, and the bar grows the ~24
## dp it needs — a placement bar that cannot say why it is refusing is not doing
## its job.
func _stack_placement_copy() -> void:
	if _bar_title == null or _bar_issue == null:
		return
	var row := _bar_title.get_parent() as Control
	# `setup()` runs twice in the real shell, and on the second pass the labels are
	# already inside the box this builds — without this guard it wraps the wrapper.
	if row == null or str(row.name) == "Copy":
		return
	var slot := _bar_title.get_index()
	var copy := VBoxContainer.new()
	copy.name = "Copy"
	copy.mouse_filter = Control.MOUSE_FILTER_IGNORE
	copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	copy.add_theme_constant_override(&"separation", 0)
	row.remove_child(_bar_title)
	row.remove_child(_bar_issue)
	_bar_title.owner = null
	_bar_issue.owner = null
	copy.add_child(_bar_title)
	copy.add_child(_bar_issue)
	row.add_child(copy)
	row.move_child(copy, slot)
	# Both still shorten rather than force the bar wider than the display; each
	# now has a whole line to shorten within, and a tooltip carrying the rest.
	# One touch target's worth of floor, not two: CANCEL and PLACE together are
	# 258 dp of a 412 dp bar at 130 % text, and the copy column is the flexible
	# one — a bigger floor pushed both buttons off the edges.
	UIWidgets.elide(_bar_title, _touch_min)
	UIWidgets.elide(_bar_issue, _touch_min)
	_bar_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bar_issue.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bar_issue.theme_type_variation = &"LegendRow"


## Six categories plus GRID at 96 dp each is a 720 dp row; a 412 dp phone has 404
## dp of safe area. The authored `Tabs` HBox has no scroller, so its minimum size
## became the sheet's minimum size, the sheet grew wider than the display, and
## `grow_horizontal = BOTH` centred the overflow — putting `Residential` off the
## left edge and `Grid` and the ✕ off the right. GRID is where the tutorial sends
## the player in step 6, so that is not a cosmetic loss.
##
## The row is therefore re-parented, at bring-up, into a horizontal scroller with
## no minimum width of its own — the standard mobile tab strip. The ✕ stays
## outside it, pinned to the right, so backing out never requires scrolling
## first. The scene is untouched: this file already builds every widget in code
## (doc 12 test 19), and the node path `Sheet/Body/Tabs` is preserved by moving
## the scroller into the row's old slot and the row into the scroller.
func _wrap_tabs_in_scroller() -> void:
	if _tabs == null or _tab_scroll != null:
		return
	var body := _tabs.get_parent() as Control
	if body == null:
		return
	var slot := _tabs.get_index()
	_tab_scroll = ScrollContainer.new()
	_tab_scroll.name = "TabScroll"
	_tab_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tab_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_tab_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_scroll.custom_minimum_size = Vector2(_touch_min, _touch_min)
	body.remove_child(_tabs)
	# A node re-parented out of its authored slot keeps a stale `owner`, which
	# Godot warns about on every mount; the row is code-owned from here on.
	_tabs.owner = null
	_tab_scroll.add_child(_tabs)
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var strip := HBoxContainer.new()
	strip.name = "TabStrip"
	strip.add_theme_constant_override(&"separation", int(_spacing))
	strip.add_child(_tab_scroll)
	body.add_child(strip)
	body.move_child(strip, slot)


## Cards + category tabs, rebuilt whenever the city level changes a lock state.
func rebuild_cards() -> void:
	_cards = controller.cards() if controller != null else ([] as Array[Dictionary])
	_build_tabs()
	_build_cards()


func _build_tabs() -> void:
	if _tabs == null:
		return
	BuildSheet._clear_children(_tabs)
	_tab_buttons.clear()
	var categories: Array[String] = []
	for card: Dictionary in _cards:
		var category := str(card["category"])
		if not categories.has(category):
			categories.append(category)
	if _category == "" or not categories.has(_category):
		_category = categories[0] if not categories.is_empty() else ""
	for category: String in categories:
		var button := Button.new()
		button.name = "Tab_" + category
		button.theme_type_variation = &"TabButton"
		button.focus_mode = Control.FOCUS_NONE
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(_touch_min * 2.0, _touch_min)
		button.text = _text(BuildController.category_tab_key(category), category.capitalize())
		button.tooltip_text = button.text
		button.pressed.connect(_on_tab_pressed.bind(category))
		_tabs.add_child(button)
		_tab_buttons[category] = button
	_build_tab_close()
	select_category(_category)


## The ✕ lives **beside** the scroller, not inside it: backing out of the sheet
## may never require scrolling a tab strip first. Rebuilt with the tabs so a
## category list that changes length cannot leave two of them behind.
func _build_tab_close() -> void:
	var strip := _tab_scroll.get_parent() as Control if _tab_scroll != null else null
	if strip == null:
		return
	var existing := strip.get_node_or_null("CloseSheet")
	if existing != null:
		strip.remove_child(existing)
		existing.free()
	var close_button := UIWidgets.button("CloseSheet", CLOSE_GLYPH,
			_text("ui_build_close", "Close"),
			Vector2(_touch_min, _touch_min), &"GhostButton")
	close_button.pressed.connect(close)
	strip.add_child(close_button)


func _build_cards() -> void:
	if _cards_box == null:
		return
	BuildSheet._clear_children(_cards_box)
	var layout := config.layout()
	var raw: Variant = layout.get("build_card_dp", [96, 120])
	var dims: Array = raw if raw is Array and (raw as Array).size() >= 2 else [96, 120]
	# A card holds three lines of copy, so it grows with the text the same way a
	# touch target does (A2) — a 96 dp card at 130 % text scale clips its own kW
	# figure, and the micro row is the one line on the card that is pure data.
	var card_size := Vector2(
			maxf(float(dims[0]) * _text_scale, _touch_min),
			maxf(float(dims[1]) * _text_scale, _touch_min))
	for card: Dictionary in _cards:
		if str(card["category"]) != _category:
			continue
		_cards_box.add_child(_build_card(card, card_size))
	_fit_cards(card_size.x)


## A card's copy lives in an **anchored** `Body`, so it contributes nothing to the
## Button's own minimum size — a card that is too narrow does not grow, it just
## paints its kW figure over the card beside it. The width is therefore measured
## here, once the cards are in the tree and the theme is real, and applied to all
## of them: a row of cards that are each a different width reads as a bug.
func _fit_cards(floor_w: float) -> void:
	var widest := floor_w
	for child in _cards_box.get_children():
		var body := child.get_node_or_null("Body")
		if body == null:
			continue
		for line in body.get_children():
			var label := line as Label
			if label == null or label.clip_text:
				continue   # an elided line has already said it may shorten
			widest = maxf(widest, UIWidgets.needed_width(label) + _spacing)
	for child in _cards_box.get_children():
		(child as Control).custom_minimum_size.x = widest


## A 96 × 120 dp card: name, cost, and the §2.7 micro-row (kW + footprint). The
## whole card is the tap target, so its children never take the touch.
func _build_card(card: Dictionary, card_size: Vector2) -> Button:
	var button := Button.new()
	button.name = "Card_" + str(card["id"])
	button.theme_type_variation = &"GhostButton"
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = card_size
	var name_text := _text(str(card["name_key"]), str(card["name_fallback"]))
	button.tooltip_text = name_text  # A15
	button.set_meta("archetype", str(card["archetype"]))
	button.set_meta("variant", str(card["variant"]))
	button.pressed.connect(_on_card_pressed.bind(
			str(card["archetype"]), str(card["variant"])))

	var body := VBoxContainer.new()
	body.name = "Body"
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	# The card is a Button, so its own stylebox margin does not inset an anchored
	# child — without this the copy would start on the card's outline.
	body.offset_left = _spacing * 0.5
	body.offset_right = -_spacing * 0.5
	button.add_child(body)

	# The name is the only line here that may be shortened: a building's name is
	# recoverable from the picture and the tooltip, its price and its footprint
	# are not.
	var title := UIWidgets.elide(UIWidgets.label("Name", name_text), _touch_min)
	body.add_child(title)

	var cost := UIWidgets.label("Cost", str(card["cost_text"]))
	# §2.7: an unaffordable cost reads CRITICAL but the card stays tappable.
	_apply_state_color(cost, HudModel.STATE_NORMAL if bool(card["affordable"])
			else HudModel.STATE_CRITICAL)
	body.add_child(cost)

	var foot: Vector2i = card["footprint"]
	var micro := UIWidgets.label("Micro", _text_args("ui_build_card_micro",
			{"kw": str(card["power_text"]), "w": foot.x, "h": foot.y},
			"%s %dx%d" % [card["power_text"], foot.x, foot.y]))
	body.add_child(micro)

	if bool(card["locked"]):
		var level := int(card["min_city_level"])
		var lock := UIWidgets.label("Lock", _text_args("ui_build_locked",
				{"level": level}, str(level)))
		_apply_state_color(lock, HudModel.STATE_OFFLINE)
		body.add_child(lock)
		# A14: a locked card says what would unlock it, not just that it is locked.
		button.tooltip_text = "%s — %s" % [name_text,
				_text_args("ui_build_locked_hint", {"level": level}, "")]
	return button


# ---------------------------------------------------------------------------
# Sheet open / close
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _sheet != null and _sheet.visible


# ---------------------------------------------------------------------------
# The unlock reveal (doc 12 §2.13's progression payoff)
# ---------------------------------------------------------------------------

## A city level landed. The cards it unlocked pulse **once**, so the reward is
## visible on the thing that was rewarded rather than only in a line of alert
## text that scrolls away — `city_level_changed` used to reach the player as an
## alert row and nothing else, which is a progression loop with no payoff.
##
## Safe while the sheet is closed: the ids are held and the reveal runs the next
## time it opens, which is the moment the player is actually looking. Returns
## what the level unlocked either way, because the caller announces it in a toast
## whether or not the sheet happens to be up.
func reveal_unlocked(city_level: int) -> PackedStringArray:
	var ids := unlocked_ids(city_level)
	_pending_unlocks = ids
	rebuild_cards()  # the lock glyphs are stale the instant the level moves
	if is_open():
		_reveal_pending()
	return ids


## Card ids whose `min_city_level` is exactly this level — the ones that were
## locked one level ago and are not any more. Empty when a level unlocks nothing,
## which is a normal answer and must not pulse the whole sheet.
func unlocked_ids(city_level: int) -> PackedStringArray:
	var out: PackedStringArray = []
	for card: Dictionary in _cards:
		if int(card["min_city_level"]) == city_level:
			out.append(str(card["id"]))
	return out


func pending_unlocks() -> PackedStringArray:
	return _pending_unlocks


## Switches to the category the first newly-unlocked card lives in and starts the
## pulse. The category switch is deliberate and is the *only* time this file
## overrides the player's last tab: a reveal that leaves the new card on a tab
## the player is not looking at has revealed nothing.
func _reveal_pending() -> void:
	if _pending_unlocks.is_empty():
		return
	for card: Dictionary in _cards:
		if str(card["id"]) == _pending_unlocks[0]:
			select_category(str(card["category"]))
			break
	# A8: a pulse is motion, so `reduce_motion` gets the rebuilt sheet and the
	# toast and no animation at all.
	if not _reduce_motion:
		for id: String in _pending_unlocks:
			if card_button(id) != null:
				_pulsing[id] = _pulse_s
	_pending_unlocks = []


## One cosine hump per card: opaque → half → opaque, over `unlock_pulse_s`.
func _advance_pulse(delta: float) -> void:
	if _pulsing.is_empty():
		return
	var done: PackedStringArray = []
	for id: Variant in _pulsing:
		var left := float(_pulsing[id]) - delta
		var button := card_button(str(id))
		if button == null or left <= 0.0:
			if button != null:
				button.modulate.a = 1.0
			done.append(str(id))
			continue
		_pulsing[id] = left
		button.modulate.a = 1.0 - 0.5 * sin(PI * (1.0 - left / maxf(_pulse_s, 0.001)))
	for id: String in done:
		_pulsing.erase(id)


func pulsing_ids() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray(_pulsing.keys())
	out.sort()
	return out


func open() -> void:
	rebuild_cards()  # locks follow the live city level
	if _sheet != null:
		_sheet.visible = true
	# The FAB and the sheet share the bottom-left corner. The FAB already stands
	# down for the placement bar; it has to stand down for the sheet too, or it
	# sits on top of the first card with a tap target over that card's.
	if _fab != null:
		_fab.visible = false
	_set_notice("")
	_reveal_pending()  # §2.13: whatever the last city level unlocked, shown now
	sheet_toggled.emit(true)


func close() -> void:
	if _sheet != null:
		_sheet.visible = false
	if _fab != null and not is_placing():
		# `SheetLayer` shows one surface at a time; the unit picker is the other
		# one, and it covers the same corner.
		_fab.visible = not UIWidgets.any_sibling_open(self)
	sheet_toggled.emit(false)


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


## Switch the visible category (the §2.7 tab bar). Public so the onboarding
## director and the `Buy a unit` deep link can preselect a tab.
func select_category(category: String) -> void:
	_category = category
	for id: Variant in _tab_buttons:
		var button: Button = _tab_buttons[id]
		var selected := str(id) == category
		button.set_pressed_no_signal(selected)
		# The same "this one is live" colour the drawer's sort segments and the
		# dashboard's tabs use — a `TabButton`'s pressed fill is a 12 % lightening
		# of a transparent box, which is not a state a player can see.
		UIWidgets.paint_state(self, button,
				HudModel.STATE_NORMAL if selected else &"")
	_build_cards()


func _on_tab_pressed(category: String) -> void:
	select_category(category)


# ---------------------------------------------------------------------------
# Placement mode
# ---------------------------------------------------------------------------

func _on_card_pressed(archetype: String, variant: String) -> void:
	if controller == null:
		return
	var entered := controller.enter(archetype, variant)
	if not bool(entered["ok"]):
		# §2.7: a locked card explains its unlock condition instead of placing.
		var failure := controller.formatter.format(entered["reason_code"], entered["payload"])
		_set_notice(str(failure["body"]))
		_cue(Haptics.CUE_BLOCKED)
		card_refused.emit(failure)
		return
	close()
	_refresh_bar()
	placement_started.emit(archetype, variant)
	placement_changed.emit()


## Ground point from `CameraState.screen_to_ground()` — the ghost follows and
## the verdict is recomputed (§2.7 re-evaluates while dragging).
func move_ghost(ground_point: Vector3) -> void:
	if controller == null or not controller.is_placing():
		return
	controller.move_to_ground(ground_point)
	_cue_ghost()
	_refresh_bar()
	placement_changed.emit()


## §2.14's two placement cues, fired on a *change* rather than on every
## revalidation: the ghost is re-evaluated at 10 Hz (§2.7), and a device that
## buzzes ten times a second while a thumb is moving is a fault, not feedback.
func _cue_ghost() -> void:
	var origin := controller.origin
	var verdict := StringName(str(controller.verdict().get("verdict", "")))
	if origin != _last_ghost_origin:
		_last_ghost_origin = origin
		_cue(Haptics.CUE_SNAP_TILE)
	if verdict == BuildController.VERDICT_BLOCKED and verdict != _last_verdict:
		_cue(Haptics.CUE_BLOCKED)
	_last_verdict = verdict


func _cue(cue: StringName) -> void:
	if haptics != null:
		haptics.fire(cue)


## §2.7: "Placement is never committed on finger-up" — only this button commits.
func confirm_placement() -> void:
	if controller == null or not controller.is_placing():
		return
	var result := controller.commit()
	if bool(result["ok"]):
		_set_notice("")
		_cue(Haptics.CUE_BUTTON)
	else:
		var failure := controller.formatter.format(result["reason_code"], result["payload"])
		_set_notice(str(failure["body"]))
		_cue(Haptics.CUE_BLOCKED)
	_last_ghost_origin = Vector2i(-1, -1)
	_last_verdict = &""
	_refresh_bar()
	placement_committed.emit(result)
	placement_changed.emit()


func cancel_placement() -> void:
	if controller == null:
		return
	controller.cancel()
	_refresh_bar()
	placement_cancelled.emit()
	placement_changed.emit()


func is_placing() -> bool:
	return controller != null and controller.is_placing()


func _refresh_bar() -> void:
	if _bar == null or controller == null:
		return
	var view := controller.placement_view()
	var active := bool(view["active"])
	_bar.visible = active
	if _fab != null:
		_fab.visible = not active and not is_open()
	if not active:
		return
	var name_text := _text(str(view["name_key"]), str(view["archetype"]))
	if _bar_title != null:
		_bar_title.text = _text_args("ui_placement_summary",
				{"name": name_text, "cost": str(view["cost_text"])},
				"%s %s" % [name_text, str(view["cost_text"])])
		_bar_title.tooltip_text = _bar_title.text
	if _bar_confirm != null:
		_bar_confirm.disabled = not bool(view["can_confirm"])
	if _bar_issue == null:
		return
	var failure: Dictionary = view["failure"]
	if failure.is_empty():
		_bar_issue.text = _text("ui_placement_ready", "")
		_bar_issue.tooltip_text = _bar_issue.text
		_apply_state_color(_bar_issue, HudModel.STATE_NORMAL)
		return
	# A5/A14: the reason is in words, and the state glyph carries the verdict
	# without relying on colour.
	#
	# The **title** of the requirement, not its body: a 56 dp bar shares one line
	# with CANCEL, the summary and PLACE, and the body is a whole sentence — at
	# 412 dp it was being squeezed into 49 px, which is not a shortened sentence
	# but an invisible one. The sentence is still reachable, on the bar's own
	# tooltip and in the sheet's notice line when a card is refused outright.
	var state: StringName = failure["state"]
	var glyph := model.state_glyph(state)
	_bar_issue.text = ("%s %s" % [glyph, str(failure["title"])]).strip_edges()
	_bar_issue.tooltip_text = str(failure["body"])
	_apply_state_color(_bar_issue, state)


func _set_notice(text: String) -> void:
	if _notice == null:
		return
	_notice.text = text
	_notice.visible = text != ""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func card_button(card_id: String) -> Button:
	if _cards_box == null:
		return null
	return _cards_box.get_node_or_null("Card_" + card_id) as Button


func cards() -> Array[Dictionary]:
	return _cards


func active_category() -> String:
	return _category


## The placement bar's two lines. Exposed rather than reached by node path: they
## are re-parented into a `Copy` box at bring-up (`_stack_placement_copy`).
func placement_title_text() -> String:
	return _bar_title.text if _bar_title != null else ""


func placement_issue_text() -> String:
	return _bar_issue.text if _bar_issue != null else ""


func _text(key: String, fallback: String) -> String:
	if config != null and config.has_string(key):
		return config.t(key)
	return fallback


## Same contract with `{named}` arguments — `data/strings.en.json` first, the
## fallback only while a key is missing (G-8).
func _text_args(key: String, args: Dictionary, fallback: String) -> String:
	if config != null and config.has_string(key):
		return config.t(key, args)
	return fallback


func _apply_state_color(control: Control, state: StringName) -> void:
	if state == &"" or not has_theme_color(state, PALETTE_TYPE):
		control.remove_theme_color_override(&"font_color")
		return
	control.add_theme_color_override(&"font_color", get_theme_color(state, PALETTE_TYPE))
