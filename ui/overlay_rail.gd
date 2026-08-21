class_name OverlayRail
extends Control
## The overlay button and its sticky chip strip (doc 12 §2.5), hung on the
## `UIRoot` scaffold's `HUDLayer` directly under the speed rail.
##
## Interaction, verbatim from §2.5: tapping the button raises the strip; the
## strip stays up until an overlay is chosen or it is dismissed, so switching
## overlays while diagnosing a cascade is one tap each; the active chip is filled
## and carries a check glyph; and **long-pressing the button toggles
## `NONE ↔ last-used`** — the A/B compare that makes an overlay a diagnostic
## instead of a decoration.
##
## Dumb by construction: `OverlayModel` owns the mode list, the exclusivity, the
## enabled subset and the legend rows; this file binds them to pixels, writes
## doc 11's `sc_overlay_mode` shader global, and emits `overlay_changed` for the
## shell. An overlay whose system has not landed renders greyed with its reason
## in words (A14) rather than vanishing from the strip.
##
## The legend is **not in the strip** (doc 12 §2.5, and report 98's last open
## item against this section): the strip is a control that the player raises to
## pick an overlay and dismisses immediately afterwards, so a legend inside it
## was on screen only while nobody was reading it. It now lives in the separate
## top-left `OverlayLegend` card, which this rail owns, positions and drives —
## the strip keeps the chips and its refusal notice, and nothing else.
##
## The card is **rebuilt on every mode change**, because the four data states are
## not what every overlay means: WATER reads "Full pressure … No water", POLICE
## and FIRE read a coverage margin, and TRAFFIC has five congestion bands rather
## than four states. `OverlayModel` decides which rows those are; the card only
## turns rows into Labels.

signal overlay_changed(mode: StringName, index: int)  ## → doc 11 render mode
signal overlay_refused(mode: StringName, message: String)
signal strip_toggled(open: bool)
signal legend_collapsed(mode: StringName, collapsed: bool)  ## → the `ui` save

const CHECK_GLYPH := "✓"
const OVERLAY_GLYPH := "◈"  ## §2.3's overlay button face
## This screen's slot in §2.3's left rail: above the BUILD FAB, below the speed
## rail. `UIRoot` solves the stack — see `UIWidgets.solve_rail_stack`.
const RAIL_INDEX := 1

## Writing doc 11's global is the whole point of the rail; a test mounts the
## scene without a renderer and turns it off.
@export var applies_shader_global: bool = true

var config: UIConfig
var model: OverlayModel

var _button: Button
var _strip: PanelContainer
var _chips_box: GridContainer
var _legend_box: VBoxContainer
var _legend_card: OverlayLegend
var _notice: Label

var _chip_buttons: Dictionary = {}   # StringName mode -> Button
var _touch_min := 48.0
var _spacing := 8.0
var _longpress_ms := 450.0
var _pressed_at_ms := -1.0
var _suppress_next_press := false
## Which mode's legend is currently on screen, so a repaint that changes nothing
## does not rebuild five Labels. Starts on a sentinel that is not in
## `overlay.modes`, so the first `_apply_active` always builds one.
const LEGEND_UNBUILT := &"__legend_unbuilt__"
## `_legend_left`'s "stand down" answer — see there.
const YIELD_LEFT := -2.0
var _legend_mode: StringName = LEGEND_UNBUILT


## The one wiring entry point, mirroring `BuildSheet.setup()`: `game/main.gd`
## hands over the parsed config, the headless tests hand over a fixture.
func setup(cfg: UIConfig = null, p_model: OverlayModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	model = p_model if p_model != null else OverlayModel.new(config)
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_longpress_ms = UIConfig.get_num(config.gestures(), "longpress_ms", 450.0)
	_bind_nodes()
	_wrap_body_in_scroller()
	_build_button()
	_build_title()
	_build_chips()
	_build_legend_card()
	close()
	# `_apply_active` builds the legend for whatever the active mode is — on a
	# fresh rail that is NONE, on a restored one it is the saved overlay.
	_legend_mode = LEGEND_UNBUILT
	_apply_active(false)
	# The rail is laid out AFTER `setup()` runs, and both the strip's clamp and
	# the card's corner are answers about the display's real size — so they are
	# re-solved on the resize that gives it to us, not only once a frame. The
	# `_process` pass still runs, for the theme and type-scale changes that move
	# the same geometry without resizing anything.
	if not resized.is_connected(_on_resized):
		resized.connect(_on_resized)
	set_process(true)


func _on_resized() -> void:
	if config == null:
		return
	if is_open():
		_clamp_strip()
	_place_legend()


func _ready() -> void:
	if model == null:
		setup(UIRoot.config_from(self))


## `setup()` may run twice (`UIRoot` then a shell that injects its own model), so
## the body is looked up where the scroller put it first and in its authored slot
## second — see `_wrap_body_in_scroller()`.
func _bind_nodes() -> void:
	_button = get_node_or_null("Button") as Button
	_strip = get_node_or_null("Strip") as PanelContainer
	var body := "Strip/Scroll/Body" if get_node_or_null("Strip/Scroll") != null \
			else "Strip/Body"
	_chips_box = get_node_or_null(body + "/Chips") as GridContainer
	_legend_box = get_node_or_null(body + "/Legend") as VBoxContainer
	_notice = get_node_or_null(body + "/Notice") as Label


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build_button() -> void:
	if _button == null:
		return
	var d := maxf(UIConfig.get_num(config.layout(), "rail_button_d_dp", 56.0), _touch_min)
	_button.theme_type_variation = &"RailButton"
	_button.focus_mode = Control.FOCUS_NONE
	_button.custom_minimum_size = Vector2(d, d)
	_button.text = OVERLAY_GLYPH
	_button.tooltip_text = UIWidgets.t(config, "ui_overlay_button")  # A15
	# Second slot of §2.3's rail stack — see `UIWidgets.rail_slot`. This is the
	# FIRST placement only: it runs inside `setup()`, before the theme has
	# propagated and before anything is laid out, so it reads the
	# `custom_minimum_size` two lines up and nothing else. `UIRoot` re-solves the
	# whole stack against one shared pitch once there are real metrics
	# (`UIWidgets.solve_rail_stack`) — this measurement being the last word is
	# what put 28 dp between this button and the speed rail above it.
	UIWidgets.place_in_rail(_button, RAIL_INDEX, config.layout(), _touch_min)
	if not _button.pressed.is_connected(_on_button_pressed):
		_button.pressed.connect(_on_button_pressed)
	if not _button.button_down.is_connected(_on_button_down):
		_button.button_down.connect(_on_button_down)
	if not _button.button_up.is_connected(_on_button_up):
		_button.button_up.connect(_on_button_up)


## The strip's own heading. It went up with a grid of chips and a `Legend` block
## under them, so the *chips* were the only unlabelled thing on it — `ui_overlay_title`
## was authored for this and had never been placed.
func _build_title() -> void:
	if _chips_box == null:
		return
	var body := _chips_box.get_parent() as Control
	if body == null or body.get_node_or_null("Title") != null:
		return
	var title := UIWidgets.label("Title", UIWidgets.t(config, "ui_overlay_title"),
			&"LegendRow")
	body.add_child(title)
	body.move_child(title, 0)


func _build_chips() -> void:
	if _chips_box == null:
		return
	UIWidgets.clear_children(_chips_box)
	_chip_buttons.clear()
	var overlay := config.section("overlay")
	var raw: Variant = overlay.get("strip_chip_dp", [64, 56])
	var dims: Array = raw if raw is Array and (raw as Array).size() >= 2 else [64, 56]
	var chip_size := Vector2(maxf(float(dims[0]), _touch_min),
			maxf(float(dims[1]), _touch_min))
	_chips_box.columns = maxi(1, UIConfig.get_int(overlay, "strip_columns", 2))
	_chips_box.add_theme_constant_override(&"h_separation", int(_spacing))
	_chips_box.add_theme_constant_override(&"v_separation", int(_spacing))
	for chip: Dictionary in model.chips():
		var mode: StringName = chip["id"]
		var label := UIWidgets.t(config, str(chip["label_key"]))
		var tooltip := label
		if not bool(chip["enabled"]):
			tooltip = UIWidgets.t_args(config, str(chip["disabled_reason_key"]),
					{"name": label})
		var button := UIWidgets.button("Chip_" + String(mode), label, tooltip,
				chip_size, &"TabButton")
		button.toggle_mode = true
		# Not `disabled`: a disabled Button swallows its own tooltip on touch, and
		# A14 wants the reason *said*. The chip stays tappable and answers in words.
		button.pressed.connect(_on_chip_pressed.bind(mode))
		_chips_box.add_child(button)
		# `strip_chip_dp` is a guess about how wide a mode name is; `Power` with its
		# selected ✓ needs 80 dp of the 64 the file offers, and `Traffic` and
		# `Water` need 67 and 66. Measure the widest state the chip can be in — the
		# selected one — so the strip neither clips nor reflows on selection.
		var selected_text := "%s %s" % [CHECK_GLYPH, label]
		button.text = selected_text
		UIWidgets.fit_width(button)
		button.text = label
		_chip_buttons[mode] = button


## Puts the strip's whole body in a scroller.
##
## The strip is anchored to the bottom of the display and grows **upward** with
## `grow_vertical = BEGIN`, and a `Control` can never be laid out below its own
## minimum size — so on a short landscape box (the doc's own 880 × 400 reference)
## a title, three rows of chips and a five-row legend simply pushed the `Off` chip
## off the top of the screen, and no amount of moving the offsets could stop it.
## A scroller's minimum height is its own, not its content's, so the strip can be
## clamped to the room it has and the content scrolls inside it.
func _wrap_body_in_scroller() -> void:
	if _strip == null or _chips_box == null:
		return
	var body := _chips_box.get_parent() as Control
	if body == null or body.get_parent() is ScrollContainer:
		return
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0.0, _touch_min)
	_strip.remove_child(body)
	body.owner = null
	scroll.add_child(body)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_strip.add_child(scroll)


## The §2.5 card, built once and re-driven on every mode change. It is parented
## to the rail — which is anchored full-rect over the HUD layer and ignores the
## mouse — so the card reaches the top-left corner without `ui_root.tscn` gaining
## a node, and the rail stays the one owner of everything overlay.
##
## The strip's authored `Legend` box is emptied and hidden rather than deleted:
## a scene node this file did not create is not this file's to free, and a build
## that turns the card off gets the old behaviour back by flipping one line.
func _build_legend_card() -> void:
	if _legend_box != null:
		UIWidgets.clear_children(_legend_box)
		_legend_box.visible = false
	if _legend_card == null:
		_legend_card = OverlayLegend.new()
		add_child(_legend_card)
		_legend_card.collapse_toggled.connect(_on_legend_collapsed)
	# `setup()` may run twice (UIRoot, then a shell or a test injecting its own
	# model); the card follows whichever model the rail ended up with.
	_legend_card.setup(config, model)
	_place_legend()
	_legend_mode = LEGEND_UNBUILT


## The top bar as MEASURED, falling back to the authored `top_bar_h_dp`. §2.4's
## `solve_top_bar` wraps the chips onto a second row on a narrow phone, so the
## bar is not the constant — this is the same reservation `_clamp_strip` makes
## for the strip at the other end of the same column.
## Where the card's left edge belongs. Its own authored offset normally; to the
## RIGHT of the raised strip when the two would share the left edge, which is
## what happens on the doc's own 880 × 400 landscape box once the type is turned
## up: the strip grows toward the top bar and reaches the card. `-1` means "your
## own offset is fine".
func _legend_left() -> float:
	if not is_open() or _strip == null or _legend_card == null:
		return -1.0
	# Measured against where the card WANTS to be, never against where it
	# currently is: testing its live rect would un-collide it the moment it moved
	# and bounce it back and forth once a frame.
	var block := config.section("overlay").get("legend_card", {}) as Dictionary
	var wanted := Rect2(
			Vector2(UIConfig.get_num(block, "left_dp", 12.0), _top_bar_h()),
			_legend_card.get_combined_minimum_size())
	var strip := _strip_rect()
	if not strip.intersects(wanted):
		return -1.0
	var beside := strip.end.x + _spacing
	# A 360 dp phone at 130 % type has no room beside the strip either. Rather
	# than hang the card off the display, it stands down until the strip — which
	# is one tap from being dismissed — goes away.
	if beside + wanted.size.x > size.x:
		return YIELD_LEFT
	return beside


## The strip's rect in this rail's own space, computed from its OFFSETS rather
## than read from `get_rect()`. `_clamp_strip()` has usually just written those
## offsets and a `Control` does not resize until the next layout pass, so the
## live rect is one frame stale — and one frame is all the collision test gets in
## the preview harness.
func _strip_rect() -> Rect2:
	return Rect2(Vector2(_strip.offset_left, size.y + _strip.offset_top),
			Vector2(_strip.offset_right - _strip.offset_left,
			_strip.offset_bottom - _strip.offset_top))


func _top_bar_h() -> float:
	var top_bar := get_parent().get_node_or_null("TopBar") as Control \
			if get_parent() != null else null
	if top_bar == null:
		return UIConfig.get_num(config.layout(), "top_bar_h_dp", 48.0)
	return maxf(top_bar.size.y, top_bar.get_combined_minimum_size().y)


func _on_legend_collapsed(mode: StringName, collapsed: bool) -> void:
	_place_legend()
	legend_collapsed.emit(mode, collapsed)


## Re-solve the card's corner. Called from every place the geometry moves —
## raising or dismissing the strip, changing overlay, folding the card — and once
## a frame besides, because the theme and the type scale settle late.
func _place_legend() -> void:
	if _legend_card == null:
		return
	var left := _legend_left()
	# `YIELD_LEFT` is "there is nowhere to put you": see `_legend_left`.
	var yielded := is_equal_approx(left, YIELD_LEFT)
	_legend_card.set_yielded(yielded)
	if not yielded:
		_legend_card.place(_top_bar_h(), left)


# ---------------------------------------------------------------------------
# Open / close (the `UIRoot` back-stack protocol)
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _strip != null and _strip.visible


func open() -> void:
	if _strip != null:
		_strip.visible = true
		_clamp_strip()
	_place_legend()
	_set_notice("")
	strip_toggled.emit(true)


## Sizes the strip to the room it has: its content's height, capped at
## `layout.legend_max_h_dp` and at whatever is left above the overlay button.
func _clamp_strip() -> void:
	if _strip == null or size.y <= 1.0:
		return
	var scroll := _strip.get_node_or_null("Scroll") as ScrollContainer
	if scroll == null:
		return
	var body := scroll.get_child(0) as Control if scroll.get_child_count() > 0 else null
	var content := body.get_combined_minimum_size().y if body != null else _touch_min
	# The top bar owns the other end of this column, so the strip's room stops
	# below it — on a 400 dp landscape box the strip reached the chips and its
	# `Power` chip shared a tap target with the grid-health chip.
	var top_bar := get_parent().get_node_or_null("TopBar") as Control
	var reserved := top_bar.get_combined_minimum_size().y if top_bar != null \
			else UIConfig.get_num(config.layout(), "top_bar_h_dp", 48.0)
	var available := size.y + _strip.offset_bottom - reserved - _spacing * 2.0
	var wanted := minf(content,
			UIConfig.get_num(config.layout(), "legend_max_h_dp", 180.0) * 2.0)
	var height := maxf(_touch_min, minf(wanted, available))
	scroll.custom_minimum_size.y = height
	_strip.offset_top = _strip.offset_bottom - _strip.get_combined_minimum_size().y
	# The strip sits beside the button that raises it, and that button widens with
	# the type — at 130 % it reached 3 dp *into* the strip's authored left edge and
	# shared a tap target with the `Water` chip.
	if _button != null:
		var width := _strip.offset_right - _strip.offset_left
		_strip.offset_left = _button.offset_left \
				+ maxf(_button.size.x, _button.custom_minimum_size.x) + _spacing
		_strip.offset_right = _strip.offset_left + maxf(width,
				_strip.get_combined_minimum_size().x)


func close() -> void:
	if _strip != null:
		_strip.visible = false
	_place_legend()
	strip_toggled.emit(false)


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

func active_mode() -> StringName:
	return model.active() if model != null else OverlayModel.MODE_NONE


func active_index() -> int:
	return model.active_index() if model != null else 0


## Programmatic select — used by the save restore and by the onboarding
## director's `confirm_power` step. Returns the model's verdict.
func select(mode: StringName) -> Dictionary:
	var verdict := model.select(mode)
	_after_verdict(verdict, mode)
	return verdict


## Alias for `select`, and the name §2.10's deep links use: the city dashboard
## emits `overlay/<mode>` and the shell forwards it here. Kept because a deep
## link is a different intent from a chip tap even though it resolves the same
## way — and because a caller that says `select_mode` should not have to know.
func select_mode(mode: StringName) -> Dictionary:
	return select(mode)


## §2.5's long press: `NONE ↔ last-used overlay`. Public so the gesture layer,
## the tests and the button's own hold timer all reach the same path.
func long_press() -> Dictionary:
	var verdict := model.toggle_last()
	_after_verdict(verdict, model.active())
	return verdict


func _on_chip_pressed(mode: StringName) -> void:
	var verdict := model.toggle(mode)
	_after_verdict(verdict, mode)
	# Sticky (§2.5): the strip stays up so the next overlay is one more tap.


func _after_verdict(verdict: Dictionary, mode: StringName) -> void:
	if not bool(verdict["ok"]):
		var label := UIWidgets.t(config, OverlayModel.label_key(mode))
		var message := UIWidgets.t_args(config, "ui_overlay_disabled", {"name": label})
		_set_notice(message)
		overlay_refused.emit(mode, message)
		_apply_active(false)
		return
	_set_notice("")
	_apply_active(bool(verdict["changed"]))


func _apply_active(changed: bool) -> void:
	var active := model.active()
	for chip: Dictionary in model.chips():
		var id: StringName = chip["id"]
		var button: Button = _chip_buttons.get(id, null)
		if button == null:
			continue
		var selected := id == active
		button.set_pressed_no_signal(selected)
		var label := UIWidgets.t(config, str(chip["label_key"]))
		# A5: the active chip carries a glyph, not just a fill.
		button.text = ("%s %s" % [CHECK_GLYPH, label]) if selected else label
		UIWidgets.paint_state(self, button,
				HudModel.STATE_NORMAL if selected
				else (&"" if bool(chip["enabled"]) else HudModel.STATE_OFFLINE))
	if _button != null:
		var name_text := UIWidgets.t(config, OverlayModel.label_key(active))
		_button.tooltip_text = UIWidgets.t(config, "ui_overlay_button") \
				if active == OverlayModel.MODE_NONE \
				else UIWidgets.t_args(config, "ui_overlay_active", {"name": name_text})
	# The legend belongs to the ACTIVE overlay, not to the console: TRAFFIC's
	# five bands, WATER's pressure words and POLICE/FIRE's coverage margin are
	# different rows, and a legend that keeps saying "Normal / Warning" while a
	# congestion map is on screen is worse than no legend at all.
	if active != _legend_mode and _legend_card != null:
		_legend_mode = active
		_legend_card.show_mode(active)
		_place_legend()
	if changed:
		_write_shader_global()
		overlay_changed.emit(active, model.active_index())


## Doc 11 reads the active overlay here (data/ui.json.overlay.shader_global).
## The value is the mode's index into `overlay.modes`, and this is the only
## writer in the project.
##
## The write is UNGUARDED, and that is the fix for a bug that made every
## overlay a no-op outside the editor. `RenderingServer.
## global_shader_parameter_get_list()` is editor-only: in a game build
## (`renderer_rd/storage_rd/material_storage.cpp:1848`) it fails with "This
## function should never be used outside the editor" and returns an EMPTY
## list — so the `if not …has(name): return` this used to open with was always
## true on device, the global was never written, and the city never greyed out.
## It passed the suite because the HEADLESS dummy renderer has no such guard
## and answers honestly. `project.godot` declares `sc_overlay_mode`, so there is
## nothing to check for: `applies_shader_global` is still the switch a test
## mounting the rail without a renderer turns off.
func _write_shader_global() -> void:
	if not applies_shader_global or model == null:
		return
	RenderingServer.global_shader_parameter_set(
			StringName(model.shader_global_name()), model.active_index())


func _set_notice(text: String) -> void:
	if _notice == null:
		return
	_notice.text = text
	_notice.visible = text != ""
	UIWidgets.paint_state(self, _notice, HudModel.STATE_WARNING)


# ---------------------------------------------------------------------------
# Hold-to-A/B on the rail button
# ---------------------------------------------------------------------------

func _on_button_down() -> void:
	_pressed_at_ms = float(Time.get_ticks_msec())
	_suppress_next_press = false


func _on_button_up() -> void:
	_pressed_at_ms = -1.0


func _on_button_pressed() -> void:
	if _suppress_next_press:
		_suppress_next_press = false
		return
	toggle()


func _process(_delta: float) -> void:
	# Godot processes any script that defines `_process`, including before this
	# screen has been set up.
	if config == null or _button == null:
		return
	# Second slot of §2.3's rail stack, re-solved because the button's height is
	# only knowable once the theme and the layout have both run.
	UIWidgets.place_in_rail(_button, 1, config.layout(), _touch_min)
	if _legend_card != null:
		# Same reason the rail button is re-placed: the card's height is only
		# knowable once the theme and the type scale have both run, and it grows
		# when the player turns the text up. The top bar is measured, not assumed
		# — its chips wrap onto a second row on a narrow phone.
		_place_legend()
	if is_open():
		_clamp_strip()
	if _pressed_at_ms < 0.0 or _suppress_next_press:
		return
	if float(Time.get_ticks_msec()) - _pressed_at_ms < _longpress_ms:
		return
	_suppress_next_press = true  # the release must not also toggle the strip
	_pressed_at_ms = -1.0
	long_press()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func chip_button(mode: StringName) -> Button:
	return _chip_buttons.get(mode, null)


func rail_button() -> Button:
	return _button


## One legend line by its row id — a state token (`normal`…`offline`) or, in
## TRAFFIC, a band name (`clear`…`gridlock`). Reads the §2.5 card, which is where
## the legend lives now.
func legend_row(row_id: StringName) -> Label:
	return _legend_card.legend_row(row_id) if _legend_card != null else null


func legend_mode() -> StringName:
	return _legend_mode


func legend_card() -> OverlayLegend:
	return _legend_card


## This screen's member of §2.3's rail stack — see `UIWidgets.solve_rail_stack`.
func rail_entry() -> Dictionary:
	return {"control": _button, "index": RAIL_INDEX}


## §2.5's "1–3 overlay-specific aggregate lines", from the shell — only the shell
## holds a sim. `[{label, value, state?}]`, already formatted.
func set_summary_lines(mode: StringName, lines: Array) -> void:
	if model == null:
		return
	model.set_summary_lines(mode, lines)
	if _legend_card != null and _legend_card.mode() == mode:
		_legend_card.refresh()


func capture_state() -> Dictionary:
	return model.capture_state() if model != null else {}


func restore_state(state: Dictionary) -> void:
	if model == null:
		return
	model.restore_state(state)
	_apply_active(true)
