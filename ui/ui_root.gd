class_name UIRoot
extends CanvasLayer
## The UI scaffold of doc 12 §4.1 — SafeArea, the layer stack, the Android back
## stack, and the one Theme. Deliberately empty of content: P1-32 fills
## `HUDLayer` and friends, this is the frame those screens hang on.
##
##     UIRoot (CanvasLayer, layer=10)
##     └── SafeArea (MarginContainer)
##         ├── MarkerLayer (Control, PASS)   projected world pins + selection ring
##         ├── HUDLayer    (Control, IGNORE) TopBar / LeftRail / RightRail / AlertStack
##         ├── PanelLayer  (Control, IGNORE) BuildingPanel, LandPanel, IncidentDrawer
##         ├── SheetLayer  (Control, IGNORE) BuildSheet, UnitPickerSheet, PlacementBar
##         ├── ModalLayer  (Control, STOP when populated)
##         └── CoachLayer  (Control, STOP when hard-gated)
##     └── ToastLayer (CanvasLayer, layer=20)
##
## Container `Control`s are `mouse_filter = IGNORE`; only leaf widgets and modal
## scrims are `STOP`. That is what guarantees an unconsumed touch falls through
## to `TouchRouter._unhandled_input` → `GestureRecognizer` → `CameraState`, and
## it is why the camera never has to inspect UI rects.
##
## All layout maths that can be expressed without a Node lives in the static
## functions below, so the breakpoint solver and the back stack are headless.
##
## The offsets baked into `game/ui/ui_root.tscn` are editor-time scaffolding that
## mirror the §2.3 geometry table; the HUD work in P1-32 re-derives every rect
## from `data/ui.json.layout` at runtime, so no tunable is owned by the scene.

const CANVAS_LAYER_UI := 10
const CANVAS_LAYER_TOAST := 20
const BACK_TO_MINIMISE_WINDOW_S := 2.0

## Android's density model: 160 dpi == 1 dp per px.
const DP_BASE_DPI := 160.0
const CONTENT_SCALE_MIN := 1.0
const CONTENT_SCALE_MAX := 4.0

enum Breakpoint { COMPACT, REGULAR, WIDE }

## Back-stack verdicts, in doc 12 §2.2 priority order.
const BACK_CLOSE_MODAL := &"close_modal"
const BACK_CLOSE_SHEET := &"close_sheet"
const BACK_CLOSE_PANEL := &"close_panel"
const BACK_CANCEL_PLACEMENT := &"cancel_placement"
const BACK_DESELECT := &"deselect"
const BACK_PROMPT_MINIMISE := &"prompt_minimise"
const BACK_MINIMISE := &"minimise"

signal back_requested(action: StringName)
signal breakpoint_changed(bp: Breakpoint)
signal safe_area_changed(rect: Rect2i)

@export var apply_content_scale: bool = true

var config: UIConfig
var theme_resource: Theme

var safe_area: MarginContainer
var marker_layer: Control
var hud_layer: Control
var panel_layer: Control
var sheet_layer: Control
var modal_layer: Control
var coach_layer: Control
var toast_layer: CanvasLayer

var current_breakpoint: Breakpoint = Breakpoint.REGULAR
var drawer_w_dp: int = 300

## Back-stack context, written by the screens as they open and close.
var placement_active := false
var selected_entity_id := ""

var _last_back_ms := -1.0e9


func _ready() -> void:
	initialize()


## Bring-up, split out of `_ready()` and idempotent: a headless test never
## reaches an idle frame, so `_ready` never fires there and the screens hanging
## off this scaffold would bind against a null config. Callers that mount the
## scene by hand call this once after `add_child()`.
func initialize() -> void:
	layer = CANVAS_LAYER_UI
	_bind_nodes()
	if config == null:
		config = UIConfig.load_from_files()
		if not config.is_valid():
			for message: String in config.errors:
				push_error("UIRoot: %s" % message)
	_apply_content_scale()
	rebuild_theme()
	_recompute_layout()
	var window := get_window()
	if window != null and not window.size_changed.is_connected(_recompute_layout):
		window.size_changed.connect(_recompute_layout)


func _bind_nodes() -> void:
	safe_area = get_node_or_null("SafeArea") as MarginContainer
	if safe_area == null:
		return
	marker_layer = safe_area.get_node_or_null("MarkerLayer") as Control
	hud_layer = safe_area.get_node_or_null("HUDLayer") as Control
	panel_layer = safe_area.get_node_or_null("PanelLayer") as Control
	sheet_layer = safe_area.get_node_or_null("SheetLayer") as Control
	modal_layer = safe_area.get_node_or_null("ModalLayer") as Control
	coach_layer = safe_area.get_node_or_null("CoachLayer") as Control
	toast_layer = get_node_or_null("ToastLayer") as CanvasLayer


## doc 12 §2.1: `Control` coordinates are dp on every device, matching Android's
## own model, so the 48 dp gate means the same thing everywhere.
func _apply_content_scale() -> void:
	if not apply_content_scale:
		return
	var window := get_window()
	if window == null:
		return
	window.content_scale_factor = clampf(
			DisplayServer.screen_get_dpi(0) / DP_BASE_DPI, CONTENT_SCALE_MIN, CONTENT_SCALE_MAX)


## Rebuilds the single Theme from `data/ui.json` for the current accessibility
## settings and applies it at the root (doc 12 §4.3 — no per-node overrides).
func rebuild_theme(opts: Dictionary = {}) -> Theme:
	if config == null:
		config = UIConfig.load_from_files()
	theme_resource = ThemeBuilder.build(config, opts)
	if safe_area != null:
		safe_area.theme = theme_resource
	return theme_resource


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_GO_BACK_REQUEST:
			handle_back()
		NOTIFICATION_WM_SIZE_CHANGED:
			_recompute_layout()


# ---------------------------------------------------------------------------
# Safe area and breakpoints
# ---------------------------------------------------------------------------

func _recompute_layout() -> void:
	if safe_area == null or config == null:
		return
	var layout := config.layout()
	var rect := _safe_area_rect()
	var bleed := int(UIConfig.get_num(layout, "safe_area_bleed_dp", 4.0))
	var window := get_window()
	var win: Vector2i = window.size if window != null else Vector2i(rect.size)
	safe_area.add_theme_constant_override("margin_left", rect.position.x + bleed)
	safe_area.add_theme_constant_override("margin_top", rect.position.y + bleed)
	safe_area.add_theme_constant_override("margin_right",
			maxi(0, win.x - rect.end.x) + bleed)
	safe_area.add_theme_constant_override("margin_bottom",
			maxi(0, win.y - rect.end.y) + bleed)
	safe_area_changed.emit(rect)

	var width_dp := float(rect.size.x)
	var bp := UIRoot.breakpoint_for(width_dp, layout)
	drawer_w_dp = UIRoot.drawer_width_dp(width_dp, layout)
	if bp != current_breakpoint:
		current_breakpoint = bp
		breakpoint_changed.emit(bp)


func _safe_area_rect() -> Rect2i:
	var rect := DisplayServer.get_display_safe_area()
	if rect.size.x <= 0 or rect.size.y <= 0:
		var window := get_window()
		var size: Vector2i = window.size if window != null else Vector2i(880, 400)
		rect = Rect2i(Vector2i.ZERO, size)
	return rect


## COMPACT < 700 dp · REGULAR 700–899 · WIDE ≥ 900 (doc 12 §2.1).
static func breakpoint_for(width_dp: float, layout: Dictionary) -> Breakpoint:
	var bps: Variant = layout.get("breakpoints_dp", {})
	var block: Dictionary = bps if bps is Dictionary else {}
	var compact_max := UIConfig.get_num(block, "compact_max", 699.0)
	var regular_max := UIConfig.get_num(block, "regular_max", 899.0)
	if width_dp <= compact_max:
		return Breakpoint.COMPACT
	if width_dp <= regular_max:
		return Breakpoint.REGULAR
	return Breakpoint.WIDE


## `drawer_w = clamp(round(0.34 * W), 260, 340)` (doc 12 §2.1).
static func drawer_width_dp(width_dp: float, layout: Dictionary) -> int:
	var ratio := UIConfig.get_num(layout, "drawer_w_ratio", 0.34)
	var lo := UIConfig.get_num(layout, "drawer_w_min_dp", 260.0)
	var hi := UIConfig.get_num(layout, "drawer_w_max_dp", 340.0)
	return int(clampf(round(ratio * width_dp), lo, hi))


# ---------------------------------------------------------------------------
# Android back stack (doc 12 §2.2) — one place, one order
# ---------------------------------------------------------------------------

## Pure resolver so the order is testable without a scene tree. `ctx` keys:
## `modal_open`, `sheet_open`, `panel_open`, `placement_active`, `has_selection`,
## `back_pressed_recently`.
static func resolve_back(ctx: Dictionary) -> StringName:
	if bool(ctx.get("modal_open", false)):
		return BACK_CLOSE_MODAL
	if bool(ctx.get("sheet_open", false)):
		return BACK_CLOSE_SHEET
	if bool(ctx.get("panel_open", false)):
		return BACK_CLOSE_PANEL
	if bool(ctx.get("placement_active", false)):
		return BACK_CANCEL_PLACEMENT
	if bool(ctx.get("has_selection", false)):
		return BACK_DESELECT
	if bool(ctx.get("back_pressed_recently", false)):
		return BACK_MINIMISE
	return BACK_PROMPT_MINIMISE


func back_context(now_ms: float) -> Dictionary:
	return {
		"modal_open": _has_open_child(modal_layer),
		"sheet_open": _has_open_child(sheet_layer),
		"panel_open": _has_open_child(panel_layer),
		"placement_active": placement_active,
		"has_selection": selected_entity_id != "",
		"back_pressed_recently":
			(now_ms - _last_back_ms) <= BACK_TO_MINIMISE_WINDOW_S * 1000.0,
	}


## Resolves one back press and emits `back_requested`. Screens listen and do the
## closing; this class only owns the order.
func handle_back(now_ms: float = -1.0) -> StringName:
	var t := now_ms if now_ms >= 0.0 else float(Time.get_ticks_msec())
	var action := UIRoot.resolve_back(back_context(t))
	_last_back_ms = t
	if action == BACK_CLOSE_MODAL:
		_close_last(modal_layer)
	elif action == BACK_CLOSE_SHEET:
		_close_last(sheet_layer)
	elif action == BACK_CLOSE_PANEL:
		_close_last(panel_layer)
	elif action == BACK_CANCEL_PLACEMENT:
		placement_active = false
	elif action == BACK_DESELECT:
		selected_entity_id = ""
	back_requested.emit(action)
	return action


## Is anything on this layer actually open?
##
## Two kinds of child live on a layer. A **transient** one is pushed when it
## opens and freed when it closes, so its mere presence means "open" — that was
## the P1-30 scaffold's only case. A **persistent** screen (`BuildSheet`,
## `BuildingPanel`, P1-33/P1-34) is authored into `ui_root.tscn` and is always
## present, because its FAB has to stay on screen while the sheet itself is shut;
## it answers `is_open()` for itself. Anything else counts as open while visible.
static func _has_open_child(node: Node) -> bool:
	if node == null:
		return false
	for child in node.get_children():
		if child.has_method("is_open"):
			if bool(child.call("is_open")):
				return true
			continue
		var control := child as Control
		if control == null or control.visible:
			return true
	return false


## Closes the topmost open child: a persistent screen is told to `close()`, a
## transient one is popped and freed. Returns true when something closed.
static func _close_last(node: Node) -> bool:
	if node == null:
		return false
	for i in range(node.get_child_count() - 1, -1, -1):
		var child := node.get_child(i)
		if child.has_method("is_open"):
			if not bool(child.call("is_open")):
				continue
			if child.has_method("close"):
				child.call("close")
				return true
			continue
		var control := child as Control
		if control != null and not control.visible:
			continue
		node.remove_child(child)
		child.queue_free()
		return true
	return false
