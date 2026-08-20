class_name ThemeBuilder
extends RefCounted
## Builds the project's single `Theme` from `data/ui.json` (doc 12 §4.3).
##
## Doc 12: "`ui/theme/slacum_theme.tres` is the **only** `Theme` in the project.
## Zero per-node style overrides are permitted." Colour tokens are *generated at
## boot* from `data/ui.json.palette[colorblind_variant]`, so the theme is built
## here rather than hand-authored — the `.tres` is only ever a cached snapshot of
## what this class produces for the `default` variant.
##
## Also hosts `ThemeScaler` (doc 12 §4.2/§4.3): `scale_theme()` returns a
## duplicated Theme with every font size and every `*_minimum_size` / `margin` /
## `separation` constant multiplied by the text scale, rounded to whole dp with a
## floor of 1. Touch minimums are `ceil(48 · max(1.0, scale))`, or
## `ceil(56 · …)` when `larger_touch_targets` is on (accessibility gate A3).
##
## Godot has no theme property for `Control.custom_minimum_size`, so the 48 dp
## gate is expressed twice: the stylebox content margins here guarantee it for
## anything the theme draws, and `min_touch_size()` is what `UIRoot` stamps onto
## interactive leaves.

## Theme type used to publish the raw palette tokens, so any widget can look up
## `theme.get_color("critical", "Palette")` without a per-node override.
const PALETTE_TYPE := "Palette"

## Theme type variations of doc 12 §4.3, mapped to their Godot base type.
const TYPE_VARIATIONS := {
	"StatChip": "Button",
	"PrimaryFAB": "Button",
	"RailButton": "Button",
	"SeverityBadge": "PanelContainer",
	"SheetPanel": "PanelContainer",
	"SidePanel": "PanelContainer",
	"DrawerRow": "PanelContainer",
	"DangerButton": "Button",
	"GhostButton": "Button",
	"TabButton": "Button",
	"LegendRow": "PanelContainer",
	"CoachBubble": "PanelContainer",
	"ToastPanel": "PanelContainer",
	"AlertBanner": "PanelContainer",
	## S0's game name. The only consumer of `type_scale_dp.display`, which doc 12
	## §4.3 has published since the first draft and which nothing read until the
	## front door needed a wordmark. A variation rather than a per-node font
	## override, so it scales with A2's text setting like every other size here.
	"Wordmark": "Label",
}

## Which entry of `type_scale_dp` each variation reads.
const VARIATION_TYPE_SCALE := {
	"StatChip": "numeric",
	"PrimaryFAB": "label",
	"RailButton": "label",
	"SeverityBadge": "numeric",
	"SheetPanel": "body",
	"SidePanel": "body",
	"DrawerRow": "body",
	"DangerButton": "body",
	"GhostButton": "body",
	"TabButton": "label",
	"LegendRow": "label",
	"CoachBubble": "body",
	"ToastPanel": "body",
	"AlertBanner": "body",
	"Wordmark": "display",
}

const CONSTANT_SCALE_HINTS := ["minimum_size", "margin", "separation"]

const DEFAULT_TOUCH_MIN_DP := 48.0
const DEFAULT_TOUCH_LARGE_DP := 56.0
const DEFAULT_TOUCH_SPACING_DP := 8.0


## `opts`: {colorblind: String, text_scale: float, larger_touch_targets: bool}.
## Defaults come from `data/ui.json.defaults`, never from code.
static func build(cfg: UIConfig, opts: Dictionary = {}) -> Theme:
	var defaults := cfg.section("defaults")
	var variant := str(opts.get("colorblind", defaults.get("colorblind", "default")))
	var text_scale := float(opts.get("text_scale",
			UIConfig.get_num(defaults, "text_scale", 1.0)))
	var larger := bool(opts.get("larger_touch_targets",
			defaults.get("larger_touch_targets", false)))

	var palette := cfg.palette(variant)
	var type_scale := cfg.section("type_scale_dp")
	var layout := cfg.layout()

	var theme := Theme.new()
	var body := int(UIConfig.get_num(type_scale, "body", 14.0))
	theme.default_font_size = maxi(1, body)

	_apply_palette(theme, palette)

	var bg := _color(palette, "bg", "#0E1116")
	var surface := _color(palette, "surface", "#161B22")
	var surface_alt := _color(palette, "surface_alt", "#1E242D")
	var text := _color(palette, "text", "#E6EAF0")
	var text_dim := _color(palette, "text_dim", "#9AA3B0")
	var accent := _color(palette, "accent", "#4FA8FF")
	var critical := _color(palette, "critical", "#E5533D")

	var touch_min := touch_min_dp(cfg, text_scale, larger)
	var spacing := int(ceil(UIConfig.get_num(layout, "touch_spacing_min_dp",
			DEFAULT_TOUCH_SPACING_DP)))

	# --- base types ---------------------------------------------------------
	theme.set_color("font_color", "Label", text)
	theme.set_font_size("font_size", "Label", maxi(1, body))

	_button(theme, "Button", surface_alt, text, touch_min, body)
	_button(theme, "DangerButton", critical, bg, touch_min, body)
	_button(theme, "GhostButton", Color(surface_alt, 0.0), accent, touch_min, body)
	_button(theme, "PrimaryFAB", accent, bg, touch_min, body)
	_button(theme, "RailButton", surface, text, touch_min, body)
	_button(theme, "StatChip", surface, text, touch_min, body)
	_button(theme, "TabButton", Color(surface, 0.0), text_dim, touch_min, body)

	_panel(theme, "PanelContainer", surface, spacing)
	_panel(theme, "SheetPanel", surface, spacing)
	_panel(theme, "SidePanel", surface, spacing)
	_panel(theme, "DrawerRow", surface_alt, spacing)
	_panel(theme, "LegendRow", surface, spacing)
	_panel(theme, "CoachBubble", surface_alt, spacing)
	_panel(theme, "ToastPanel", surface_alt, spacing)
	_panel(theme, "AlertBanner", surface_alt, spacing)
	_panel(theme, "SeverityBadge", surface_alt, spacing)

	# --- type variations + their font sizes ---------------------------------
	for name: String in TYPE_VARIATIONS:
		theme.set_type_variation(StringName(name), StringName(TYPE_VARIATIONS[name]))
		var key: String = VARIATION_TYPE_SCALE.get(name, "body")
		var size := int(UIConfig.get_num(type_scale, key, float(body)))
		theme.set_font_size("font_size", name, maxi(1, size))
		if not theme.has_color("font_color", name):
			theme.set_color("font_color", name, text)

	# Container rhythm: A4 wants ≥ 8 dp between adjacent independent targets.
	for container: String in ["HBoxContainer", "VBoxContainer"]:
		theme.set_constant("separation", container, spacing)
	theme.set_constant("h_separation", "GridContainer", spacing)
	theme.set_constant("v_separation", "GridContainer", spacing)

	if not is_equal_approx(text_scale, 1.0):
		theme = scale_theme(theme, text_scale)
	return theme


## `ThemeScaler.build(base_theme, scale)` of doc 12 §4.3.
static func scale_theme(base: Theme, scale: float) -> Theme:
	var out: Theme = base.duplicate(true)
	out.default_font_size = maxi(1, int(round(float(base.default_font_size) * scale)))
	for type_name: String in out.get_font_size_type_list():
		for item: String in out.get_font_size_list(type_name):
			out.set_font_size(item, type_name,
					maxi(1, int(round(float(out.get_font_size(item, type_name)) * scale))))
	for type_name: String in out.get_constant_type_list():
		for item: String in out.get_constant_list(type_name):
			if not _scales_with_text(item):
				continue
			out.set_constant(item, type_name,
					maxi(1, int(round(float(out.get_constant(item, type_name)) * scale))))
	# Godot expresses a themed Control's minimum size through the stylebox content
	# margins, so they scale with the text or a 150% scale would clip (A2).
	for type_name: String in out.get_stylebox_type_list():
		for item: String in out.get_stylebox_list(type_name):
			var box := out.get_stylebox(item, type_name)
			if box == null:
				continue
			var copy: StyleBox = box.duplicate()
			copy.content_margin_left = maxf(1.0, round(copy.content_margin_left * scale))
			copy.content_margin_right = maxf(1.0, round(copy.content_margin_right * scale))
			copy.content_margin_top = maxf(1.0, round(copy.content_margin_top * scale))
			copy.content_margin_bottom = maxf(1.0, round(copy.content_margin_bottom * scale))
			out.set_stylebox(item, type_name, copy)
	return out


static func _scales_with_text(item: String) -> bool:
	for hint: String in CONSTANT_SCALE_HINTS:
		if item.contains(hint):
			return true
	return false


## A3: min 48 × 48 dp for every interactive Control, 56 dp with
## `larger_touch_targets`, never shrinking below that as text scales.
static func touch_min_dp(cfg: UIConfig, text_scale: float, larger: bool) -> int:
	var layout := cfg.layout()
	var base := UIConfig.get_num(layout,
			"touch_target_large_dp" if larger else "touch_target_min_dp",
			DEFAULT_TOUCH_LARGE_DP if larger else DEFAULT_TOUCH_MIN_DP)
	return int(ceil(base * maxf(1.0, text_scale)))


static func min_touch_size(cfg: UIConfig, text_scale: float, larger: bool) -> Vector2:
	var d := float(touch_min_dp(cfg, text_scale, larger))
	return Vector2(d, d)


static func _apply_palette(theme: Theme, palette: Dictionary) -> void:
	for token: String in palette:
		if token.begins_with("_"):
			continue
		theme.set_color(StringName(token), PALETTE_TYPE, _color(palette, token, "#FF00FF"))


static func _color(palette: Dictionary, token: String, fallback: String) -> Color:
	var raw: Variant = palette.get(token, fallback)
	var hex: String = raw if raw is String else fallback
	if not Color.html_is_valid(hex):
		push_warning("ThemeBuilder: invalid colour '%s' for token '%s'" % [hex, token])
		hex = fallback
	return Color.html(hex)


static func _button(theme: Theme, type_name: String, fill: Color, fg: Color,
		touch_min: int, font_size: int) -> void:
	# Vertical content margins are sized so a themed button's own minimum height
	# clears the 48 dp gate before any custom_minimum_size is applied.
	var pad_v := maxi(4, int(ceil((float(touch_min) - float(font_size) * 1.4) * 0.5)))
	var pad_h := maxi(8, pad_v)
	for state: String in ["normal", "hover", "pressed", "disabled", "focus"]:
		var box := StyleBoxFlat.new()
		box.bg_color = fill
		if state == "pressed":
			box.bg_color = fill.lightened(0.12)
		elif state == "disabled":
			box.bg_color = Color(fill, fill.a * 0.45)
		box.corner_radius_top_left = 6
		box.corner_radius_top_right = 6
		box.corner_radius_bottom_left = 6
		box.corner_radius_bottom_right = 6
		box.content_margin_left = pad_h
		box.content_margin_right = pad_h
		box.content_margin_top = pad_v
		box.content_margin_bottom = pad_v
		theme.set_stylebox(StringName(state), type_name, box)
	theme.set_color("font_color", type_name, fg)
	theme.set_color("font_hover_color", type_name, fg)
	theme.set_color("font_pressed_color", type_name, fg)
	theme.set_color("font_disabled_color", type_name, Color(fg, 0.45))
	theme.set_font_size("font_size", type_name, maxi(1, font_size))


static func _panel(theme: Theme, type_name: String, fill: Color, pad: int) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.corner_radius_top_left = 8
	box.corner_radius_top_right = 8
	box.corner_radius_bottom_left = 8
	box.corner_radius_bottom_right = 8
	box.content_margin_left = pad
	box.content_margin_right = pad
	box.content_margin_top = pad
	box.content_margin_bottom = pad
	theme.set_stylebox("panel", type_name, box)
