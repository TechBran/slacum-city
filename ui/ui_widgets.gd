class_name UIWidgets
extends RefCounted
## The four lines every screen in `ui/` would otherwise repeat: build a touch
## target that already satisfies A3 and A15, build a label, resolve copy through
## `data/strings.en.json`, and paint one of the four state colours from the
## generated palette.
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
	out.clip_text = true
	if variation != &"":
		out.theme_type_variation = variation
	return out


static func label(node_name: String, text: String, variation: StringName = &"",
		wrap: bool = false) -> Label:
	var out := Label.new()
	out.name = node_name
	out.text = text
	out.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if wrap:
		out.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	else:
		out.clip_text = true
	if variation != &"":
		out.theme_type_variation = variation
	return out


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
static func paint_state(source: Control, target: Control, state: StringName) -> void:
	if target == null or source == null:
		return
	if state == &"" or not source.has_theme_color(state, PALETTE_TYPE):
		target.remove_theme_color_override(&"font_color")
		return
	target.add_theme_color_override(&"font_color",
			source.get_theme_color(state, PALETTE_TYPE))


## The scrim colour behind a modal: the palette's `bg` at the given alpha, so a
## colourblind variant or an art repaint carries it automatically.
static func scrim_color(source: Control, alpha: float) -> Color:
	var base := Color(0.0, 0.0, 0.0)
	if source != null and source.has_theme_color(&"bg", PALETTE_TYPE):
		base = source.get_theme_color(&"bg", PALETTE_TYPE)
	return Color(base.r, base.g, base.b, clampf(alpha, 0.0, 1.0))


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
