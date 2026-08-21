class_name TitleScreen
extends Control
## S0, doc 12 §2.2's front door — the one screen in the map that had no node.
## Shown at boot BEFORE the city: the game's name over its own skyline, CONTINUE
## (with the newest save's day, population and treasury on it), NEW CITY (with
## the confirmation `TitleModel` prices) and SETTINGS.
##
## **It is absent unless someone asks for it.** The scene authors it closed, like
## every other screen on the deck, and nothing in `ui/` ever opens it — only
## `UIRoot.present_title()` does, which only `game/main.gd` calls. That is what
## keeps `tests/test_tutorial_flow.gd` and `tools/ui_preview.gd` driving the deck
## with no front door in the way while the shipped game still boots into one.
##
## **It closes nothing by itself.** CONTINUE and NEW CITY are *intents*: the sim
## belongs to the shell, only the shell knows whether a restore actually
## succeeded, and a corrupt save must leave the player looking at the door rather
## than at an empty city. So the shell calls `dismiss_title()` when it has acted.
## SETTINGS deliberately does not dismiss at all — S9 opens *over* the title.
##
## The skyline is drawn here rather than blitted, from
## `data/ui.json.title.skyline`, which is `tools/gen_icon.py`'s own `TOWERS`
## table in the generator's own coordinate system. The launcher icon crops five
## towers around the hero; this shows all fifteen. One drawing, three places, and
## the amber window is the same window.

signal continue_requested(slot: int)
## `slot` is the slot the OUTGOING city was preserved into, or −1 when nothing
## was preserved — see `TitleModel.confirm_new_game`. `difficulty` is doc 03
## §2.9's preset the new city is FOUNDED on: chosen here because doc 93 §K1 says
## a city keeps it for life, so this is the last screen that can ask.
signal new_game_requested(slot: int, difficulty: String)
signal settings_requested
signal title_toggled(open: bool)

const _DEFAULT_BUTTON_W_DP := 240.0
const _DEFAULT_SKYLINE_H_DP := 220.0
## Crown shapes, as authored in `title.skyline.towers[i][3]`.
const CROWN_NONE := 0
const CROWN_STEP := 1
const CROWN_SPIRE := 2
## The amber window's halo, as concentric translucent discs: [radius_factor of
## the window's long side, alpha]. Discs and not rectangles — a square glow round
## a square window reads as a rendering artefact rather than as light.
const GLOW_RINGS: Array = [[3.0, 0.05], [2.2, 0.07], [1.5, 0.11], [1.0, 0.18]]

var config: UIConfig
var model: TitleModel

var _panel: PanelContainer
var _wordmark: Label
var _tagline: Label
var _meta: Label
var _saved: Label
var _buttons_box: VBoxContainer
var _confirm_box: VBoxContainer
var _prompt: Label
var _note: Label
var _confirm_actions: VBoxContainer

var _buttons: Dictionary = {}          # StringName action -> Button
var _confirm_buttons: Dictionary = {}  # StringName id -> Button
var _difficulty_button: Button
var _difficulty_hint: Label
var _touch_min := 48.0
var _spacing := 8.0
var _button_w := _DEFAULT_BUTTON_W_DP
var _skyline: Dictionary = {}
var _paint: Dictionary = {}            # token -> Color
var _open := false


func setup(cfg: UIConfig = null, p_model: TitleModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	model = p_model if p_model != null else TitleModel.new(config)
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	var title_cfg := config.section("title")
	_button_w = maxf(UIConfig.get_num(title_cfg, "button_w_dp", _DEFAULT_BUTTON_W_DP),
			_touch_min)
	var skyline: Variant = title_cfg.get("skyline", {})
	_skyline = skyline if skyline is Dictionary else {}
	_load_paint(title_cfg)
	_bind_nodes()
	_build_static()
	_build_buttons()
	refresh()
	close()
	if not resized.is_connected(queue_redraw):
		resized.connect(queue_redraw)


func _ready() -> void:
	if model == null:
		setup(UIRoot.config_from(self))


func _bind_nodes() -> void:
	_panel = get_node_or_null("Center/Panel") as PanelContainer
	_wordmark = get_node_or_null("Center/Panel/Body/Wordmark") as Label
	_tagline = get_node_or_null("Center/Panel/Body/Tagline") as Label
	_meta = get_node_or_null("Center/Panel/Body/Meta") as Label
	_saved = get_node_or_null("Center/Panel/Body/Saved") as Label
	_buttons_box = get_node_or_null("Center/Panel/Body/Buttons") as VBoxContainer
	_confirm_box = get_node_or_null("Center/Panel/Body/Confirm") as VBoxContainer
	_prompt = get_node_or_null("Center/Panel/Body/Confirm/Prompt") as Label
	_note = get_node_or_null("Center/Panel/Body/Confirm/Note") as Label
	_confirm_actions = get_node_or_null("Center/Panel/Body/Confirm/Actions") as VBoxContainer


func _load_paint(title_cfg: Dictionary) -> void:
	_paint.clear()
	var raw: Variant = title_cfg.get("palette", {})
	var table: Dictionary = raw if raw is Dictionary else {}
	for token: String in table:
		if token.begins_with("_"):
			continue
		var hex := str(table[token])
		if Color.html_is_valid(hex):
			_paint[token] = Color.html(hex)


func _build_static() -> void:
	if _wordmark != null:
		_wordmark.text = UIWidgets.t(config, "ui_title_name")
		_wordmark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_wordmark.theme_type_variation = &"Wordmark"
	if _tagline != null:
		_tagline.text = UIWidgets.t(config, "ui_title_tagline")
		_tagline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for box: VBoxContainer in [_buttons_box, _confirm_box, _confirm_actions]:
		if box != null:
			box.add_theme_constant_override(&"separation", int(_spacing))


# ---------------------------------------------------------------------------
# The three doors
# ---------------------------------------------------------------------------

func _build_buttons() -> void:
	if _buttons_box == null:
		return
	UIWidgets.clear_children(_buttons_box)
	_buttons.clear()
	_difficulty_button = null
	_difficulty_hint = null
	for row: Dictionary in model.actions():
		var action: StringName = row["action"]
		var text := str(row["label"])
		var button := UIWidgets.button("Action_" + String(action), text, text,
				Vector2(_button_w, _touch_min),
				&"PrimaryFAB" if bool(row["primary"]) else &"GhostButton")
		button.disabled = not bool(row["enabled"])
		button.pressed.connect(_on_action.bind(action))
		_buttons_box.add_child(button)
		_buttons[action] = button
		if action == TitleModel.ACTION_NEW_GAME:
			_build_difficulty_chip()
	_build_confirm_buttons()


## Doc 03 §2.9's preset, directly under NEW CITY: one 48 dp target that cycles
## the four names and wraps, plus the sentence that says the choice is permanent.
##
## It is here rather than inside the confirmation because a FIRST launch never
## sees the confirmation — doc 12 starts that city immediately and
## `tests/test_ui_title.gd` holds the door to it — so a chip behind the confirm
## panel would be invisible to the one player who has never chosen a difficulty
## before. See `TitleModel`'s own header for the ruling.
##
## The hint WRAPS, which is what makes it width-safe: an autowrapping Label
## reports its longest word as its minimum, so this sentence costs the card
## nothing at 360 dp and 130 % text (`test_the_front_door_fits_…`).
func _build_difficulty_chip() -> void:
	var row := model.difficulty_row()
	var label := str(row["label"])
	_difficulty_button = UIWidgets.button("Action_difficulty", label, label,
			Vector2(_button_w, _touch_min), &"GhostButton")
	_difficulty_button.pressed.connect(_on_difficulty_pressed)
	_buttons_box.add_child(_difficulty_button)
	_difficulty_hint = UIWidgets.label("DifficultyHint", str(row["hint"]),
			&"LegendRow", true)
	_difficulty_hint.custom_minimum_size.x = _button_w
	_difficulty_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_buttons_box.add_child(_difficulty_hint)


func _on_difficulty_pressed() -> void:
	model.cycle_difficulty()
	_refresh_difficulty()


func _refresh_difficulty() -> void:
	if _difficulty_button == null:
		return
	var label := str(model.difficulty_row()["label"])
	_difficulty_button.text = label
	_difficulty_button.tooltip_text = label


func _build_confirm_buttons() -> void:
	if _confirm_actions == null:
		return
	UIWidgets.clear_children(_confirm_actions)
	_confirm_buttons.clear()
	# Stacked rather than a row: three verbs this long side by side leave each of
	# them 90 dp on a 360 dp phone, which is the defect the save sheet already
	# learned (`ui/save_load_sheet.gd::_build_slot`).
	for spec: Array in [
			[&"keep", "ui_title_new_keep", &"PrimaryFAB"],
			[&"start", "ui_title_new_confirm", &"DangerButton"],
			[&"cancel", "ui_title_new_cancel", &"GhostButton"]]:
		var text := UIWidgets.t(config, str(spec[1]))
		var button := UIWidgets.button("Confirm_" + String(spec[0]), text, text,
				Vector2(_button_w, _touch_min), spec[2])
		button.pressed.connect(_on_confirm.bind(StringName(spec[0])))
		_confirm_actions.add_child(button)
		_confirm_buttons[StringName(spec[0])] = button


func _on_action(action: StringName) -> void:
	match action:
		TitleModel.ACTION_CONTINUE:
			var row := model.continue_row()
			if bool(row["enabled"]):
				continue_requested.emit(int(row["slot"]))
		TitleModel.ACTION_NEW_GAME:
			var plan := model.new_game_plan()
			if not bool(plan["needs_confirm"]):
				new_game_requested.emit(-1, str(plan["difficulty"]))
				return
			_show_confirm(plan)
		TitleModel.ACTION_SETTINGS:
			settings_requested.emit()


func _on_confirm(id: StringName) -> void:
	if id == &"cancel":
		_hide_confirm()
		return
	var answer := model.confirm_new_game(id == &"keep")
	_hide_confirm()
	new_game_requested.emit(int(answer["slot"]), str(answer["difficulty"]))


func _show_confirm(plan: Dictionary) -> void:
	if _confirm_box == null:
		return
	if _prompt != null:
		_prompt.text = str(plan["prompt"])
	if _note != null:
		_note.text = str(plan["keep_note"])
		_note.visible = str(plan["keep_note"]) != ""
		UIWidgets.paint_state(self, _note,
				HudModel.STATE_WARNING if bool(plan["blocked_keep"]) else &"")
	var keep := _confirm_buttons.get(&"keep", null) as Button
	if keep != null:
		keep.visible = bool(plan["can_keep"])
	_confirm_box.visible = true
	if _buttons_box != null:
		_buttons_box.visible = false


func _hide_confirm() -> void:
	if _confirm_box != null:
		_confirm_box.visible = false
	if _buttons_box != null:
		_buttons_box.visible = true


func confirm_visible() -> bool:
	return _confirm_box != null and _confirm_box.visible


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

## Binds the live save service. `Object` on purpose — `ui/` never depends on
## `game/save_service.gd`'s type, which is what lets the tests stub it.
func bind_service(service: Object) -> void:
	if model != null:
		model.bind(service)
	refresh()


## Re-reads the slots and repaints CONTINUE. Cheap: `list_slots()` reads each
## file's header, never a city.
func refresh() -> void:
	if model == null:
		return
	var row := model.continue_row()
	if _meta != null:
		_meta.text = str(row["summary"])
		UIWidgets.paint_state(self, _meta,
				&"" if bool(row["enabled"]) else HudModel.STATE_OFFLINE)
	if _saved != null:
		_saved.text = str(row["saved_text"])
		_saved.visible = str(row["saved_text"]) != ""
	# Which door is the primary one is a function of the SAVES, and the saves are
	# only known once a service is bound — which happens after the buttons are
	# built. So the emphasis is re-derived here rather than baked in at build
	# time, or a returning player would be shown NEW CITY in the bright colour.
	for action_row: Dictionary in model.actions():
		var button := _buttons.get(action_row["action"], null) as Button
		if button == null:
			continue
		button.disabled = not bool(action_row["enabled"])
		button.theme_type_variation = &"PrimaryFAB" if bool(action_row["primary"]) \
				else &"GhostButton"
	_refresh_difficulty()


func is_open() -> bool:
	return _open


func open() -> void:
	if model != null:
		model.refresh()
	refresh()
	_hide_confirm()
	_set_visible(true)
	title_toggled.emit(true)


func close() -> void:
	_hide_confirm()
	_set_visible(false)
	title_toggled.emit(false)


func _set_visible(value: bool) -> void:
	_open = value
	if _panel != null:
		_panel.visible = value
	# The front door swallows every touch: there is no city behind it to pan.
	mouse_filter = Control.MOUSE_FILTER_STOP if value else Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func action_button(action: StringName) -> Button:
	if action == TitleModel.ACTION_DIFFICULTY:
		return _difficulty_button
	return _buttons.get(action, null)


func confirm_button(id: StringName) -> Button:
	return _confirm_buttons.get(id, null)


# ---------------------------------------------------------------------------
# The mark (doc 12 §2.2 · tools/gen_icon.py's SKYLINE space)
# ---------------------------------------------------------------------------

## Drawn on this Control itself rather than on a child, so it lands *behind* the
## card: a parent draws before its children. Nothing here animates, so the whole
## thing is painted once per resize and never per frame.
func _draw() -> void:
	if not _open or _skyline.is_empty() or size.x <= 0.0 or size.y <= 0.0:
		return
	var span := UIConfig.get_num(_skyline, "width", 4.2)
	var ground_y := UIConfig.get_num(_skyline, "ground_y", 1.0)
	if span <= 0.0 or ground_y <= 0.0:
		return
	var towers := _towers()
	var hero := clampi(UIConfig.get_int(_skyline, "hero", 0), 0, maxi(0, towers.size() - 1))
	var focus_x := span * 0.5
	if not towers.is_empty():
		var row: Array = towers[hero]
		focus_x = float(row[0]) + float(row[1]) * 0.5
	# **Where the hero goes, and why it is not the middle.** The card is centred,
	# so a centred hero puts the one amber window — the whole mark — behind it.
	# The tower is placed a fifth of the way in instead, and the scale is then
	# raised until the rest of the city still reaches both edges: cropped at both
	# ends, exactly as the launcher icon is, so the skyline reads as continuing
	# past the frame. Never below the authored height, so a tall phone gets a band
	# of city rather than a stripe.
	var frac := clampf(UIConfig.get_num(_skyline, "hero_x_frac", 0.22), 0.0, 1.0)
	var scale := UIConfig.get_num(_skyline, "height_dp", _DEFAULT_SKYLINE_H_DP) / ground_y
	scale = maxf(scale, size.x / span)
	if focus_x > 0.0:
		scale = maxf(scale, size.x * frac / focus_x)
	if span - focus_x > 0.0:
		scale = maxf(scale, size.x * (1.0 - frac) / (span - focus_x))
	# …and a viewport shorter than it is wide should not be all silhouette, as
	# long as backing off still covers the width.
	scale = maxf(minf(scale, size.y), size.x / span)
	# The clamp is the coverage guarantee: whatever the two rules above wanted,
	# the drawing may not leave a bare edge.
	var origin_x := maxf(minf(size.x * frac - focus_x * scale, 0.0),
			size.x - span * scale)
	var base_y := size.y

	_draw_sky()
	var silhouette: Color = _paint.get("silhouette", Color(0.02, 0.03, 0.06))
	var window_dark: Color = _paint.get("window_dark", Color(0.07, 0.14, 0.22))
	for index in towers.size():
		_draw_tower(towers[index], index, origin_x, base_y, scale, ground_y,
				silhouette, window_dark, index == hero)


func _towers() -> Array:
	var raw: Variant = _skyline.get("towers", [])
	return raw if raw is Array else []


func _draw_sky() -> void:
	var top: Color = _paint.get("sky_top", Color(0.03, 0.06, 0.11))
	var horizon: Color = _paint.get("sky_horizon", Color(0.15, 0.30, 0.47))
	var bands := maxi(2, UIConfig.get_int(_skyline, "sky_bands", 48))
	var band_h := size.y / float(bands)
	for i in bands:
		# The same eased ramp the icon uses, so the glow hugs the horizon rather
		# than washing the whole field.
		var t := pow(float(i) / float(bands - 1), 2.6)
		draw_rect(Rect2(0.0, float(i) * band_h, size.x, band_h + 1.0),
				top.lerp(horizon, t), true)


func _draw_tower(raw: Variant, index: int, origin_x: float, base_y: float,
		scale: float, ground_y: float, silhouette: Color, window_dark: Color,
		is_hero: bool) -> void:
	var row: Array = raw if raw is Array else []
	if row.size() < 3:
		return
	var x0 := float(row[0])
	var w := float(row[1])
	var roof := float(row[2])
	var crown := int(row[3]) if row.size() > 3 else CROWN_NONE
	var left := origin_x + x0 * scale
	var width := w * scale
	if left > size.x or left + width < 0.0:
		return   # off the crop — every window inside it would be too
	var top := base_y - (ground_y - roof) * scale
	draw_rect(Rect2(left, top, width, base_y - top), silhouette, true)
	_draw_crown(crown, left, width, top, scale, silhouette)
	_draw_windows(index, x0, w, roof, origin_x, base_y, scale, ground_y,
			window_dark, is_hero)


func _draw_crown(crown: int, left: float, width: float, top: float, scale: float,
		silhouette: Color) -> void:
	if crown == CROWN_STEP:
		var h := UIConfig.get_num(_skyline, "step_crown_h", 0.055) * scale
		draw_rect(Rect2(left + width * 0.22, top - h, width * 0.56, h), silhouette, true)
	elif crown == CROWN_SPIRE:
		var raw: Variant = _skyline.get("spire_crown", [0.062, 0.15, 0.198])
		var steps: Array = raw if raw is Array else [0.062, 0.15, 0.198]
		if steps.size() < 3:
			return
		var a := float(steps[0]) * scale
		var b := float(steps[1]) * scale
		var c := float(steps[2]) * scale
		draw_rect(Rect2(left + width * 0.20, top - a, width * 0.60, a), silhouette, true)
		draw_rect(Rect2(left + width * 0.455, top - b, width * 0.09, b - a),
				silhouette, true)
		draw_rect(Rect2(left + width * 0.487, top - c, width * 0.026, c - b),
				silhouette, true)


## The generator's own window grid, sieve included: a fixed integer sieve knocks
## out roughly one window in eleven so the facades read as inhabited rather than
## printed. No RNG — the same windows every launch, and the same ones the icon
## has.
func _draw_windows(index: int, x0: float, w: float, roof: float, origin_x: float,
		base_y: float, scale: float, ground_y: float, window_dark: Color,
		is_hero: bool) -> void:
	var pitch_x := UIConfig.get_num(_skyline, "win_pitch_x", 0.118)
	var pitch_y := UIConfig.get_num(_skyline, "win_pitch_y", 0.098)
	var win_w := UIConfig.get_num(_skyline, "win_w", 0.062)
	var win_h := UIConfig.get_num(_skyline, "win_h", 0.052)
	if pitch_x <= 0.0 or pitch_y <= 0.0:
		return
	var cols := maxi(1, int(round(w / pitch_x)))
	var span_top := roof + UIConfig.get_num(_skyline, "win_top_pad", 0.058)
	var span_bottom := ground_y - UIConfig.get_num(_skyline, "win_bottom_pad", 0.048)
	var rows := maxi(0, int((span_bottom - span_top) / pitch_y))
	if rows == 0:
		return
	var sieve_mod := maxi(1, UIConfig.get_int(_skyline, "sieve_mod", 11))
	var st := UIConfig.get_int(_skyline, "sieve_tower", 7)
	var sc := UIConfig.get_int(_skyline, "sieve_col", 13)
	var sr := UIConfig.get_int(_skyline, "sieve_row", 29)
	var lit_col := UIConfig.get_int(_skyline, "lit_col", 2)
	var lit_row := UIConfig.get_int(_skyline, "lit_row", 2)
	var step_x := w / float(cols)
	for ci in cols:
		var cx := x0 + step_x * (float(ci) + 0.5)
		for ri in rows:
			var lit := is_hero and ci == lit_col and ri == lit_row
			if not lit and (index * st + ci * sc + ri * sr) % sieve_mod == 0:
				continue
			var cy := span_top + pitch_y * (float(ri) + 0.5)
			var rect := Rect2(origin_x + (cx - win_w * 0.5) * scale,
					base_y - (ground_y - (cy - win_h * 0.5)) * scale,
					win_w * scale, win_h * scale)
			if lit:
				_draw_lit_window(rect)
			else:
				draw_rect(rect, window_dark, true)


## One window still burning. The glow is three translucent rings rather than a
## blur, because a Control has no framebuffer to blur and three rects read the
## same at this size.
func _draw_lit_window(rect: Rect2) -> void:
	var amber: Color = _paint.get("amber", Color(1.0, 0.69, 0.16))
	var core: Color = _paint.get("amber_core", Color(1.0, 0.93, 0.78))
	var centre := rect.get_center()
	var reach := maxf(rect.size.x, rect.size.y)
	for ring: Array in GLOW_RINGS:
		draw_circle(centre, reach * float(ring[0]), Color(amber, float(ring[1])))
	# Wider than its neighbours by the generator's own 9 %, and only wider: the
	# window is a slot of light, not a square.
	var grow_x := rect.size.x * 0.09
	draw_rect(rect.grow_individual(grow_x, 0.0, grow_x, 0.0), amber, true)
	draw_rect(Rect2(rect.position + rect.size * 0.22, rect.size * 0.56), core, true)
