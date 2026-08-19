class_name UIAudit
extends RefCounted
## The scripted half of the UX sweep: walk a live `Control` tree and report every
## defect a player would notice but a unit test would not — text that does not
## fit its box, a `{placeholder}` nobody filled, a raw `ui_*` key that leaked
## through a missing string, a tap target under the A3 floor, a button with no
## accessibility name, and two targets sitting on top of each other.
##
## It exists because those defects are **geometry**, and geometry only exists
## once the theme, the fonts and the containers have run. `tools/ui_preview.gd`
## runs this over every screen at four device widths and prints what it finds;
## `tests/test_ui_audit.gd` runs the same walk headless so a regression fails the
## suite instead of waiting for the next screenshot.
##
## Every check answers one question: *would this look broken on a phone?* A check
## that cannot answer that without guessing is not in here — the walk is meant to
## have no false positives, so an engineer can treat any finding as a bug.

## Findings, worst first. Also the order `format()` prints them in.
const KIND_CLIPPED := &"clipped_text"
const KIND_UNDERSIZED := &"undersized"
const KIND_UNBOUNDED_CLIP := &"unbounded_clip"
const KIND_PLACEHOLDER := &"unresolved_placeholder"
const KIND_RAW_KEY := &"raw_string_key"
const KIND_TINY_TARGET := &"tiny_target"
const KIND_NO_TOOLTIP := &"no_tooltip"
const KIND_OFFSCREEN := &"offscreen"
const KIND_OVERLAP := &"overlapping_targets"

const KIND_ORDER: Array[StringName] = [
	KIND_CLIPPED, KIND_UNDERSIZED, KIND_UNBOUNDED_CLIP, KIND_PLACEHOLDER,
	KIND_RAW_KEY, KIND_TINY_TARGET, KIND_NO_TOOLTIP, KIND_OFFSCREEN, KIND_OVERLAP,
]

## The checks that need no rendered frame — text, and the promises a Control makes
## about its own width. `tests/test_ui_audit.gd` runs these; a headless run never
## flushes a `Container`'s sort, so every laid-out size there is zero.
const FRAME_FREE_KINDS: Array[StringName] = [
	KIND_UNBOUNDED_CLIP, KIND_PLACEHOLDER, KIND_RAW_KEY,
]

## Sub-pixel slack. A themed stylebox rounds its margins to whole dp and a
## container distributes leftovers, so a Control can miss its own minimum by a
## fraction without a player ever seeing it.
const EPSILON_PX := 1.0
## Two tap targets that share an edge are not overlapping; a real collision
## covers area. 24 dp² is half a fingertip's worth of pixels.
const OVERLAP_MIN_AREA := 24.0
## A raw key that leaked into a label looks like this.
const KEY_PATTERN := "^(ui|n)_[a-z0-9_]+$"


## Every finding in `root`'s subtree. `viewport_rect` is what `offscreen` is
## measured against — pass the visible rect of the viewport the tree is drawn in;
## an empty rect turns that one check off (a headless mount has no viewport).
static func walk(root: Node, touch_min_dp: float = 48.0,
		viewport_rect: Rect2 = Rect2()) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var targets: Array[Dictionary] = []
	_visit(root, root, out, targets, touch_min_dp, viewport_rect)
	_check_overlaps(targets, out)
	out.sort_custom(UIAudit._worse_first)
	return out


## The subset of `walk()` a frame-free run can trust. Same walk, filtered — the
## geometry findings are all "laid out 0×0" in a headless mount and would drown
## the real ones.
static func walk_frame_free(root: Node) -> Array[Dictionary]:
	return only(walk(root, 0.0, Rect2()), FRAME_FREE_KINDS)


static func _visit(node: Node, root: Node, out: Array[Dictionary],
		targets: Array[Dictionary], touch_min_dp: float,
		viewport_rect: Rect2) -> void:
	var control := node as Control
	if control != null:
		if not control.visible:
			return    # a hidden branch has no geometry worth judging
		_check_control(control, root, out, targets, touch_min_dp, viewport_rect)
	for child in node.get_children():
		_visit(child, root, out, targets, touch_min_dp, viewport_rect)


## The layer a Control belongs to: its topmost ancestor below `root`. `UIRoot`
## stacks HUD, panels, sheets, modals and the coach layer as siblings of the safe
## area, and a later layer draws over — and swallows the touches of — an earlier
## one. Two targets on different layers are therefore stacked *by design*, so the
## overlap check only compares targets that share one.
static func layer_of(node: Node, root: Node) -> Node:
	var current := node
	while current != null and current.get_parent() != root:
		current = current.get_parent()
	return current


static func _check_control(control: Control, root: Node, out: Array[Dictionary],
		targets: Array[Dictionary], touch_min_dp: float,
		viewport_rect: Rect2) -> void:
	var text := UIAudit.text_of(control)
	var path := UIAudit.path_of(control, root)

	if text != "":
		if text.contains("{") and text.contains("}"):
			out.append(_finding(KIND_PLACEHOLDER, path, control, text,
					"a template argument was never supplied"))
		var regex := RegEx.new()
		regex.compile(KEY_PATTERN)
		if regex.search(text) != null:
			out.append(_finding(KIND_RAW_KEY, path, control, text,
					"data/strings.en.json has no entry for this key"))
		var needed := UIAudit.needed_width(control, text)
		# A control that declared `elide()` — clipping, with an ellipsis and a
		# floor — is doing what it said it would as long as it got its floor. The
		# finding is for copy that is being cut *without* anyone having decided it
		# could be.
		var declared_elision := UIAudit.clips(control) \
				and control.custom_minimum_size.x > 1.0 \
				and control.size.x + EPSILON_PX >= control.custom_minimum_size.x
		if needed > 0.0 and control.size.x > 0.0 and not declared_elision \
				and needed > control.size.x + EPSILON_PX:
			out.append(_finding(KIND_CLIPPED, path, control, text,
					"needs %.0f px, has %.0f" % [needed, control.size.x]))
		# A Control that may clip tells Godot it needs **no** width — `Button`
		# reports 0 and `Label` reports 1 — so beside an `EXPAND_FILL` sibling it is
		# not shortened, it is erased. Clipping without a floor is therefore a bug
		# even before anything is laid out, which is what makes this the one width
		# check a frame-free test can make.
		if UIAudit.clips(control) and control.custom_minimum_size.x <= 1.0:
			out.append(_finding(KIND_UNBOUNDED_CLIP, path, control, text,
					"clips with no minimum width — use UIWidgets.elide()"))

	# What the container actually gave it against what it asked for. Catches a row
	# squeezed out of a fixed-height bar as well as a label crushed by a sibling.
	var wanted := control.get_combined_minimum_size()
	if control.size.x > 0.0 and control.size.y > 0.0 \
			and (control.size.x + EPSILON_PX < wanted.x
					or control.size.y + EPSILON_PX < wanted.y):
		out.append(_finding(KIND_UNDERSIZED, path, control, text,
				"minimum %.0f×%.0f, laid out %.0f×%.0f"
				% [wanted.x, wanted.y, control.size.x, control.size.y]))

	var button := control as Button
	if button == null or button.size.x <= 0.0 or button.size.y <= 0.0:
		return
	if not button.disabled:
		if button.size.x + EPSILON_PX < touch_min_dp \
				or button.size.y + EPSILON_PX < touch_min_dp:
			out.append(_finding(KIND_TINY_TARGET, path, button, text,
					"%.0f×%.0f under the %.0f dp floor"
					% [button.size.x, button.size.y, touch_min_dp]))
		var on_screen := visible_rect(button, root)
		if on_screen.size.x > 0.0 and on_screen.size.y > 0.0:
			targets.append({"path": path, "node": button, "rect": on_screen,
					"layer": layer_of(button, root)})
	if button.tooltip_text.strip_edges() == "":
		out.append(_finding(KIND_NO_TOOLTIP, path, button, text,
				"an unnamed target is invisible to a screen reader (A15)"))
	# Content inside a scroller is *meant* to run past the viewport — that is what
	# scrolling is. Only an unscrollable target that has left the screen is a bug.
	if viewport_rect.size.x > 0.0 and viewport_rect.size.y > 0.0 \
			and not _inside_scroller(button, root):
		var rect := button.get_global_rect()
		if not viewport_rect.encloses(rect):
			out.append(_finding(KIND_OFFSCREEN, path, button, text,
					"rect %s outside viewport %s" % [rect, viewport_rect]))


static func _inside_scroller(node: Node, root: Node) -> bool:
	var current := node.get_parent()
	while current != null and current != root:
		if current is ScrollContainer:
			return true
		current = current.get_parent()
	return false


## The part of a Control that is actually on screen: its rect, intersected with
## every clipping ancestor's. The tab scrolled half out of a strip is half a
## target, and the one scrolled fully out is not a target at all — comparing raw
## rects would report it colliding with whatever sits beyond the scroller's edge.
static func visible_rect(control: Control, root: Node) -> Rect2:
	var rect := control.get_global_rect()
	var current := control.get_parent()
	while current != null and current != root:
		var clipper := current as Control
		if clipper != null and (clipper.clip_contents or clipper is ScrollContainer):
			rect = rect.intersection(clipper.get_global_rect())
			if rect.size.x <= 0.0 or rect.size.y <= 0.0:
				return Rect2()
		current = current.get_parent()
	return rect


## Two tap targets on top of each other **on the same layer** — a collision the
## player can actually hit wrong. Ancestor pairs are skipped (a row button that
## hosts its own label is one target, not two), and so are cross-layer pairs: a
## rail under an open modal is occluded, which is what a modal is for.
static func _check_overlaps(targets: Array[Dictionary], out: Array[Dictionary]) -> void:
	for i in targets.size():
		for j in range(i + 1, targets.size()):
			var a: Dictionary = targets[i]
			var b: Dictionary = targets[j]
			var node_a: Node = a["node"]
			var node_b: Node = b["node"]
			if a.get("layer", null) != b.get("layer", null):
				continue
			if node_a.is_ancestor_of(node_b) or node_b.is_ancestor_of(node_a):
				continue
			var overlap: Rect2 = (a["rect"] as Rect2).intersection(b["rect"] as Rect2)
			var area := overlap.size.x * overlap.size.y
			if area < OVERLAP_MIN_AREA:
				continue
			out.append(_finding(KIND_OVERLAP, str(a["path"]), node_a as Control,
					UIAudit.text_of(node_a as Control),
					"%s covers %.0f px² of %s at %s"
					% [str(a["rect"]), area, str(b["path"]), str(b["rect"])]))


static func _finding(kind: StringName, path: String, control: Control, text: String,
		detail: String) -> Dictionary:
	return {
		"kind": kind, "path": path, "text": text, "detail": detail,
		"rect": control.get_rect() if control != null else Rect2(),
	}


static func _worse_first(a: Dictionary, b: Dictionary) -> bool:
	var ia := KIND_ORDER.find(a["kind"])
	var ib := KIND_ORDER.find(b["kind"])
	if ia != ib:
		return ia < ib
	return str(a["path"]) < str(b["path"])


# ---------------------------------------------------------------------------
# Measurement
# ---------------------------------------------------------------------------

## The width this Control needs before its own clipping starts eating characters:
## the widest line of `text` in the font the theme gives it, plus the horizontal
## content margins of the stylebox it draws itself with. `0.0` means "not
## measurable" — no font yet, or the Control wraps and therefore cannot clip
## horizontally.
static func needed_width(control: Control, text: String) -> float:
	if control == null or text == "":
		return 0.0
	if UIAudit.wraps(control):
		return 0.0
	var font := control.get_theme_font(&"font")
	if font == null:
		return 0.0
	var font_size := control.get_theme_font_size(&"font_size")
	var widest := 0.0
	for line in text.split("\n"):
		widest = maxf(widest, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT,
				-1.0, font_size).x)
	return ceilf(widest + UIAudit.horizontal_padding(control))


## The horizontal content margins of the stylebox a Control draws its background
## with — the part of its width that is never available to text.
static func horizontal_padding(control: Control) -> float:
	if control == null:
		return 0.0
	var box: StyleBox = null
	if control is Button:
		box = control.get_theme_stylebox(&"normal")
	elif control is Label:
		box = control.get_theme_stylebox(&"normal")
	if box == null:
		return 0.0
	return box.content_margin_left + box.content_margin_right


## Does this Control shorten its own text rather than ask for the room it needs?
static func clips(control: Control) -> bool:
	if wraps(control):
		return false
	if control is Label:
		var label := control as Label
		return label.clip_text \
				or label.text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING
	if control is Button:
		var button := control as Button
		return button.clip_text \
				or button.text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING
	return false


static func wraps(control: Control) -> bool:
	if control is Label:
		return (control as Label).autowrap_mode != TextServer.AUTOWRAP_OFF
	if control is Button:
		return (control as Button).autowrap_mode != TextServer.AUTOWRAP_OFF
	return false


static func text_of(control: Control) -> String:
	if control is Button:
		return (control as Button).text
	if control is Label:
		return (control as Label).text
	return ""


static func path_of(node: Node, root: Node) -> String:
	if node == root:
		return "."
	var parts: PackedStringArray = []
	var current := node
	while current != null and current != root:
		parts.append(str(current.name))
		current = current.get_parent()
	parts.reverse()
	return "/".join(parts)


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

static func format(findings: Array, header: String = "") -> String:
	var lines: PackedStringArray = []
	if header != "":
		lines.append(header)
	if findings.is_empty():
		lines.append("  clean")
		return "\n".join(lines)
	for entry: Variant in findings:
		var row: Dictionary = entry
		# One finding is one line: a stacked tab's own newlines would otherwise
		# split its report across three, which every downstream grep gets wrong.
		var text := str(row["text"]).replace("\n", "⏎")
		lines.append("  [%s] %s%s — %s" % [String(row["kind"]), str(row["path"]),
				(" \"%s\"" % text) if text != "" else "", str(row["detail"])])
	return "\n".join(lines)


## Findings of the kinds a caller cares about — `tests/test_ui_audit.gd` gates on
## the four that are always bugs and reports the rest.
static func only(findings: Array, kinds: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Variant in findings:
		var row: Dictionary = entry
		if kinds.has(row["kind"]):
			out.append(row)
	return out
