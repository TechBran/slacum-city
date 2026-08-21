class_name UIWidgets
extends RefCounted
## The four lines every screen in `ui/` would otherwise repeat: build a touch
## target that already satisfies A3 and A15, build a label, resolve copy through
## `data/strings.en.json`, and paint one of the four state colours from the
## generated palette.
##
## It also owns the project's answer to the one Godot behaviour that has bitten
## every screen in this folder: **a Control that is allowed to clip reports that
## it needs no width**. `button()` and `label()` therefore never clip, `elide()`
## is the explicit opt-in for a value that must stay inside a fixed row, and
## `fit_width()` raises a data-file dimension to whatever the copy measures.
##
## It exists because the accessibility gates are **construction-time
## invariants**, not review-time ones: `button()` cannot produce a `Button`
## below 48 dp or without an accessibility name, so a new screen passes the tree
## walk (doc 12 test 19) by being written at all. `custom_minimum_size` is the
## floor the walk asserts on; the theme's content margins do the rest.
##
## Static only — no state, no Node, no config of its own.

const PALETTE_TYPE := "Palette"


## Frees every child immediately. Immediate rather than `queue_free()` on
## purpose: a rebuilt row would otherwise collide with the old one for a frame.
static func clear_children(node: Node) -> void:
	if node == null:
		return
	for child in node.get_children():
		node.remove_child(child)
		child.free()


## Detaches without freeing — for widgets that survive a re-flow (the stat chips
## move between top-bar rows rather than being rebuilt).
static func detach_children(node: Node) -> void:
	if node == null:
		return
	for child in node.get_children():
		node.remove_child(child)


## A3 (≥ 48 dp both axes) and A15 (non-empty `tooltip_text`) by construction.
## `tooltip` falls back to the visible text, which is the right accessibility
## name for a labelled button and the only sane default for a glyph one.
##
## **Why nothing here clips.** Godot's `Button::get_minimum_size()` sets the text
## width to **zero** when `clip_text` is on — clipping is a promise that the copy
## needs no room — so a clipping Button is exactly as wide as `min_size`, and
## `min_size` is an A3 *touch* floor, not a measurement of the words. That is the
## whole mechanism behind `GOT IT` rendering as `GOT I` at 130 % text scale and
## behind `✓ Power`, `DELETE` and `Traffic` losing their tails: 48 dp of touch
## target is narrower than the label it carries. A non-clipping Button measures
## its own copy, so the container gives it the width the words need and the touch
## floor stays what it was meant to be — a floor. Where a button genuinely must
## be bounded (a variable-width value in a fixed row), `elide()` says so out loud
## and supplies the floor that keeps it readable.
static func button(node_name: String, text: String, tooltip: String,
		min_size: Vector2, variation: StringName = &"") -> Button:
	var out := Button.new()
	out.name = node_name
	out.text = text
	out.tooltip_text = tooltip if tooltip.strip_edges() != "" else text
	if out.tooltip_text.strip_edges() == "":
		out.tooltip_text = node_name
	out.custom_minimum_size = min_size
	out.focus_mode = Control.FOCUS_NONE
	out.clip_text = false
	if variation != &"":
		out.theme_type_variation = variation
	return out


## Same contract on the read-only side: `Label::get_minimum_size()` reports **1
## px** while `clip_text` is on, so a clipping label beside an `EXPAND_FILL`
## sibling is squeezed to nothing rather than merely shortened — which is what
## reduced the dashboard's axis figures and the economy tab's totals to a
## one-pixel sliver. Labels measure themselves; `elide()` is the opt-in.
static func label(node_name: String, text: String, variation: StringName = &"",
		wrap: bool = false) -> Label:
	var out := Label.new()
	out.name = node_name
	out.text = text
	out.mouse_filter = Control.MOUSE_FILTER_IGNORE
	out.clip_text = false
	if wrap:
		out.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if variation != &"":
		out.theme_type_variation = variation
	return out


## Marks a Control as shortenable and gives it the floor that keeps it legible
## while it shortens. Ellipsis rather than a hard cut, because `Tile occupie` is
## a typo and `Tile occupied…` is a sentence that ran out of room.
##
## `min_w` is the narrowest the caller is willing to read it at; below that the
## row should re-flow instead. Returns its argument so it can wrap a constructor
## call inline.
static func elide(control: Control, min_w: float) -> Control:
	var label_node := control as Label
	if label_node != null:
		label_node.clip_text = true
		label_node.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var button_node := control as Button
	if button_node != null:
		button_node.clip_text = true
		button_node.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	control.custom_minimum_size.x = maxf(control.custom_minimum_size.x, min_w)
	return control


## The width a Control needs before its own clipping starts eating characters:
## the widest line of its text in the font the theme gives it, plus the
## horizontal content margins of the box it draws itself with. Only meaningful
## once the Control is in the tree — theme lookups walk the ancestor chain — so
## call it after `add_child()`.
static func needed_width(control: Control) -> float:
	return UIAudit.needed_width(control, UIAudit.text_of(control))


## Raises a Control's minimum width to whatever its current text needs, never
## lowering the touch floor it already carries. The one call that turns a
## data-file dimension (`overlay.strip_chip_dp`, `layout.build_card_dp`) from a
## guess about copy into a floor under it.
static func fit_width(control: Control) -> float:
	if control == null:
		return 0.0
	var needed := needed_width(control)
	if needed > control.custom_minimum_size.x:
		control.custom_minimum_size.x = needed
	return control.custom_minimum_size.x


## Re-parents `control` into a `ScrollContainer` in its own slot, keeping its
## place among its siblings. Idempotent — a control already inside one is left
## alone, so a `setup()` that runs twice does not nest two scrollers.
##
## **The short-viewport half of the goals-sheet pattern.** S9, S8 and S14 are
## full-rect modals with a scroller inside, so their content can outgrow the
## display without leaving it. S0 and the pause menu are CENTRED cards, and a
## centred card whose minimum height exceeds the viewport grows through both
## edges: at 880 × 400 with 130 % text the pause menu's `SAVE & QUIT` laid out at
## y 324 … 420 of a 400 dp box, and the title screen's `SETTINGS` and `CANCEL`
## did the same. Wrapping the card's body is what lets `card_height()` cap it.
static func wrap_in_scroller(control: Control, node_name: String,
		vertical: bool = true) -> ScrollContainer:
	if control == null:
		return null
	var existing := control.get_parent() as ScrollContainer
	if existing != null:
		return existing
	var host := control.get_parent() as Control
	if host == null:
		return null
	var slot := control.get_index()
	var scroll := ScrollContainer.new()
	scroll.name = node_name
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO if vertical \
			else ScrollContainer.SCROLL_MODE_DISABLED
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED if vertical \
			else ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host.remove_child(control)
	control.owner = null
	scroll.add_child(control)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host.add_child(scroll)
	host.move_child(scroll, slot)
	return scroll


## Moves `control` into `scroll`, under a `VBoxContainer` column that holds
## whatever the scroller already had. Idempotent: a control already inside the
## column is left where it is, so a `setup()` that runs twice does not reorder
## the screen.
##
## **The full-rect half of the same defect `wrap_in_scroller()` fixes.** A
## full-rect modal's panel is anchored to the display with `grow_* = BOTH`, so a
## body whose MINIMUM exceeds that rect does not clip and does not scroll — it
## grows through both edges. S9's body is `Header + Scroll + About + MANAGE
## SAVES`, and only the rows were inside the scroller: at 640 × 340 dp — the
## project's own `min_safe_box_dp` — the About block measures **164 dp** of plain
## text, the body wants **343** against **284** of panel, and the sheet's ✕ ends
## up at y −1.5 with `MANAGE SAVES` 1.5 dp past the bottom. The header and the
## footer are chrome; About is content, and content belongs in the scroller.
static func scroll_into(control: Control, scroll: ScrollContainer,
		column_name: String = "Column") -> VBoxContainer:
	if control == null or scroll == null:
		return null
	var column := scroll.get_node_or_null(NodePath(column_name)) as VBoxContainer
	if column == null:
		column = VBoxContainer.new()
		column.name = column_name
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var existing: Array[Node] = []
		for child in scroll.get_children():
			existing.append(child)
		scroll.add_child(column)
		for child in existing:
			scroll.remove_child(child)
			child.owner = null
			column.add_child(child)
	if control.get_parent() == column:
		return column
	var host := control.get_parent()
	if host != null:
		host.remove_child(control)
	control.owner = null
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(control)
	return column


## How tall a centred card may be: what it wants, capped at what the display can
## show with `margin` above and below, floored at `floor_h` so a card is never
## smaller than one tap target. `host_h <= 1` (an unlaid-out mount) returns the
## wish unchanged rather than guessing.
static func card_height(host_h: float, content_h: float, margin: float,
		floor_h: float) -> float:
	if host_h <= 1.0:
		return content_h
	return clampf(content_h, floor_h, maxf(floor_h, host_h - margin * 2.0))


static func spacer(node_name: String = "Spacer") -> Control:
	var out := Control.new()
	out.name = node_name
	out.mouse_filter = Control.MOUSE_FILTER_IGNORE
	out.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return out


## `data/strings.en.json` first (G-8). `fallback` covers a key that file does not
## carry yet and never overrides one that it does.
static func t(cfg: UIConfig, key: String, fallback: String = "") -> String:
	if cfg != null and cfg.has_string(key):
		return cfg.t(key)
	return fallback if fallback != "" else key


static func t_args(cfg: UIConfig, key: String, args: Dictionary,
		fallback: String = "") -> String:
	if cfg != null and cfg.has_string(key):
		return cfg.t(key, args)
	return fallback if fallback != "" else key


## Paints one of the four data-state colours (§2.5) from the theme's generated
## palette. `source` is any Control in the tree — the lookup is a theme lookup,
## so it follows the one Theme rather than an override table.
##
## A `Button` draws its label with `font_pressed_color` while it is held **or
## toggled on**, so overriding `font_color` alone left every selected segment —
## the drawer's sort order, the dashboard's tab, the build sheet's category —
## painted in the unselected colour. All three names carry the same state.
const BUTTON_FONT_COLORS: Array[StringName] = [
	&"font_color", &"font_pressed_color", &"font_hover_color",
	&"font_hover_pressed_color", &"font_focus_color",
]


static func paint_state(source: Control, target: Control, state: StringName) -> void:
	if target == null or source == null:
		return
	var names: Array[StringName] = BUTTON_FONT_COLORS if target is Button \
			else ([&"font_color"] as Array[StringName])
	if state == &"" or not source.has_theme_color(state, PALETTE_TYPE):
		for name: StringName in names:
			target.remove_theme_color_override(name)
		return
	var color := source.get_theme_color(state, PALETTE_TYPE)
	for name: StringName in names:
		target.add_theme_color_override(name, color)


## The scrim colour behind a modal: the palette's `bg` at the given alpha, so a
## colourblind variant or an art repaint carries it automatically.
static func scrim_color(source: Control, alpha: float) -> Color:
	var base := Color(0.0, 0.0, 0.0)
	if source != null and source.has_theme_color(&"bg", PALETTE_TYPE):
		base = source.get_theme_color(&"bg", PALETTE_TYPE)
	return Color(base.r, base.g, base.b, clampf(alpha, 0.0, 1.0))


## How wide a right-edge panel should actually be (doc 12 §2.1's
## `drawer_w = clamp(0.34·W, 260, 340)`), with the two answers that formula alone
## cannot give:
##
##   * a panel is never narrower than its own contents — four sort segments that
##     read `Priority | Nearest | Newest | Unassigned` need the width those words
##     need, and shrinking them below it is how the segments lost their labels;
##   * once the strip left beside it is too thin to be anything, the panel takes
##     the whole display. On a 412 dp phone a 364 dp panel left a 48 dp ribbon of
##     half-drawn HUD chips down the left edge, which reads as a rendering fault.
##
## Pure and static so the breakpoint behaviour is testable without a scene.
static func side_panel_width(host_w: float, content_w: float, ratio: float,
		min_dp: float, max_dp: float, gutter_dp: float) -> float:
	if host_w <= 1.0:
		return maxf(content_w, min_dp)
	var wanted := maxf(clampf(ratio * host_w, min_dp, max_dp), content_w)
	if wanted >= host_w - gutter_dp:
		return host_w
	return wanted


## Where one of the thumb-zone rail buttons sits, measured up from the bottom of
## the safe area (doc 12 §2.3's stack: the BUILD FAB, the overlay button above
## it, the speed control above that).
##
## The three live in three different files on two different layers, and the scene
## gave each a hard-coded offset pair sized for a 56 dp button. At 130 % text with
## larger touch targets those buttons are 85 dp tall, so the speed control landed
## on top of the overlay button — same layer, overlapping tap targets. Solving the
## stack from the same four tunables in all three places is what keeps them
## stacked at every scale.
##
## Returns `{bottom, height}` in dp. `index` is 0 for the FAB, 1 for the overlay
## button, 2 for the speed rail. `measured_h` is what the button in this slot
## actually needs — the three share a theme and a font class, so each one
## measuring itself yields the same pitch, and the stack stays a stack when the
## type grows.
static func rail_slot(index: int, layout: Dictionary, touch_min: float,
		measured_h: float = 0.0) -> Dictionary:
	var margin := UIConfig.get_num(layout, "rail_margin_dp", 12.0)
	var gap := UIConfig.get_num(layout, "rail_gap_dp", 8.0)
	var fab_d := maxf(UIConfig.get_num(layout, "fab_d_dp", 64.0), touch_min)
	var rail_d := maxf(UIConfig.get_num(layout, "rail_button_d_dp", 56.0), touch_min)
	var pitch := maxf(maxf(fab_d, rail_d), measured_h)
	return {"bottom": margin + float(maxi(0, index)) * (pitch + gap),
			"height": pitch}


## Pins a Control into one rail slot. The control must be anchored to the bottom
## edge with `grow_vertical = BEGIN`, which every one of the three already is.
## Re-run it whenever the screen refreshes: a Control measured before its theme
## has landed reports the default theme's metrics, and one measured before it has
## been laid out reports only its minimum. Both answers are too small, and both
## correct themselves on the next pass — `size` is the truth once there is one.
##
## **This places ONE control against its OWN measurement, which is what
## `solve_rail_stack()` exists to stop being the last word** — see there. It
## remains the first placement each of the three files makes (a rail button that
## waited a frame for its offsets would visibly jump), and the solver overwrites
## it with the stack's shared pitch on the first pass that has real metrics.
static func place_in_rail(control: Control, index: int, layout: Dictionary,
		touch_min: float) -> void:
	if control == null:
		return
	var slot := rail_slot(index, layout, touch_min,
			maxf(control.get_combined_minimum_size().y, control.size.y))
	control.offset_bottom = -float(slot["bottom"])
	control.offset_top = control.offset_bottom - float(slot["height"])


## Solves §2.3's LEFT rail the way `solve_corner_rail()` solves the right one:
## **one pitch for the whole stack**, applied to every member in one pass.
##
## The three affordances live in three files on two layers — the BUILD FAB
## (`ui/build_sheet.gd`, `SheetLayer`), the overlay button (`ui/overlay_rail.gd`,
## `HUDLayer`) and the speed rail (`ui/hud.gd`, `HUDLayer`) — so they cannot find
## each other by walking a parent, and each was calling `place_in_rail()` with
## its own measurement. That is only a stack while the three measurements agree,
## and they did not: `OverlayRail._build_button()` places its button inside
## `setup()`, before the theme has propagated and before anything is laid out, so
## it read its own `custom_minimum_size` (**73 dp** at 880 × 400 / 130 % / larger
## targets) while `CityHUD.refresh()` re-places the speed rail every frame and
## read the laid-out **93 dp**. Two placers, two pitches, one column: the overlay
## button sat at y 210…303 and the speed rail at y 89…182 — **28 dp of gap where
## `rail_gap_dp` says 8**, and `HudModel.top_bar_left_inset()` solved the top bar
## against a rail top that no button actually had.
##
## `entries` is `{control, index}` in any order; the caller collects them, because
## the members are not siblings. Indices are FIXED and gaps are not closed — the
## FAB hides while a placement bar is up, and an overlay button that slid down to
## take its slot would move under the player's thumb mid-gesture. Returns the
## pitch, so the top bar can be solved against the same number.
static func solve_rail_stack(entries: Array, layout: Dictionary,
		touch_min: float) -> float:
	var pitch := float(rail_slot(0, layout, touch_min)["height"])
	for raw: Variant in entries:
		var entry: Dictionary = raw
		var control := entry.get("control") as Control
		if control == null:
			continue
		pitch = maxf(pitch, control.get_combined_minimum_size().y)
	for raw: Variant in entries:
		var entry: Dictionary = raw
		var control := entry.get("control") as Control
		if control == null:
			continue
		var slot := rail_slot(int(entry.get("index", 0)), layout, touch_min, pitch)
		control.offset_bottom = -float(slot["bottom"])
		control.offset_top = control.offset_bottom - float(slot["height"])
	return pitch


## Where one of the bottom-RIGHT corner affordances sits — the mirror of
## `rail_slot()` for the other thumb (doc 12 §2.3's drawer handle, the alerts
## chip and the event-log chip).
##
## `index` 0 is the **tab** (the incident drawer's handle): it is the bookmark on
## the edge, so it keeps the edge and this function never moves it. `index` 1 and
## up are the chips, stacked bottom-first in the column *beside* the tab, each in
## a slot as tall as it measures. `measured_h` is what the chip in this slot
## actually needs; `reserved_w` is the column the tab has taken.
##
## Returns `{bottom, height, right}` in dp, all measured inward from the safe
## area's bottom-right corner. At 100 % text with 48 dp targets it reproduces the
## scene's authored offsets exactly (alerts −92/−140/−56/−128, event log
## −148/−196), which is why the reference box does not move.
static func corner_slot(index: int, layout: Dictionary, touch_min: float,
		measured_h: float = 0.0, reserved_w: float = 0.0) -> Dictionary:
	var margin := UIConfig.get_num(layout, "corner_rail_margin_dp", 92.0)
	var gap := UIConfig.get_num(layout, "rail_gap_dp", 8.0)
	var pitch := maxf(touch_min, measured_h)
	return {"bottom": margin + float(maxi(0, index - 1)) * (pitch + gap),
			"height": pitch, "right": reserved_w}


## Solves the whole bottom-right corner in one pass and applies it.
##
## Three edge affordances claim that corner — the incident drawer's handle, the
## alerts chip and the event-log chip — on the same layer, from three different
## files, each with a hard-coded offset pair sized for a 48 dp target. At 130 %
## text with larger targets those chips measure 100 dp tall against a 56 dp pitch
## and the handle 94 dp wide against a 56 dp reserve, so the alerts chip covered
## 1 848 px² of the event-log chip and the handle covered 2 736 px² of it:
## D-16's collision, one corner over, and worth 73 `overlapping_targets` findings
## on every supported box. Solving the stack from the same tunables in all three
## places is what keeps it a stack when the type grows.
##
## Duck-typed like `close_siblings()`: a sibling joins the rail by answering
## `corner_rail_entry()` with `{"control": Control, "index": int}`. A hidden
## affordance is skipped and the ones above it close the gap, so an affordance
## that has stood down (D-16) costs the others nothing.
static func solve_corner_rail(node: Node, layout: Dictionary,
		touch_min: float) -> void:
	var parent := node.get_parent() if node != null else null
	if parent == null:
		return
	var tab: Control = null
	var chips: Array[Dictionary] = []
	for child in parent.get_children():
		if not child.has_method("corner_rail_entry"):
			continue
		var entry: Dictionary = child.call("corner_rail_entry")
		var control := entry.get("control") as Control
		if control == null or not control.visible:
			continue
		if int(entry.get("index", 0)) <= 0:
			tab = control
		else:
			chips.append({"control": control, "index": int(entry["index"])})
	chips.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["index"]) < int(b["index"]))
	var gap := UIConfig.get_num(layout, "rail_gap_dp", 8.0)
	# The tab's own measured width, not its declared floor: it widens itself to
	# whatever its count and tier line need, and only the combined minimum knows.
	var reserved := 0.0 if tab == null \
			else maxf(tab.custom_minimum_size.x,
					tab.get_combined_minimum_size().x) + gap
	# One pitch for the whole column, like `rail_slot()`: the chips share a theme
	# and a font class, so the tallest of them is the pitch all of them keep and
	# the stack stays evenly spaced when the type grows.
	var pitch := touch_min
	for chip: Dictionary in chips:
		pitch = maxf(pitch, (chip["control"] as Control).get_combined_minimum_size().y)
	var slot_index := 1
	for chip: Dictionary in chips:
		var control: Control = chip["control"]
		var slot := corner_slot(slot_index, layout, touch_min, pitch, reserved)
		control.offset_bottom = -float(slot["bottom"])
		control.offset_top = control.offset_bottom - float(slot["height"])
		control.offset_right = -float(slot["right"])
		control.offset_left = control.offset_right \
				- maxf(touch_min, control.get_combined_minimum_size().x)
		slot_index += 1


## Is any sibling screen open? The read-only half of `close_siblings()`, for a
## screen that has a second surface (a handle, a chip) which also has to yield
## the edge it shares.
static func any_sibling_open(node: Node) -> bool:
	var parent := node.get_parent() if node != null else null
	if parent == null:
		return false
	for child in parent.get_children():
		if child == node or not child.has_method("is_open"):
			continue
		if bool(child.call("is_open")):
			return true
	return false


## Closes every sibling screen that answers `is_open()`. Panels and modals are
## persistent children of their layer (they own their own entry point), so
## "opening" one is also the moment to put the others away.
static func close_siblings(node: Node) -> int:
	var parent := node.get_parent() if node != null else null
	if parent == null:
		return 0
	var closed := 0
	for child in parent.get_children():
		if child == node or not child.has_method("is_open") or not child.has_method("close"):
			continue
		if bool(child.call("is_open")):
			child.call("close")
			closed += 1
	return closed
