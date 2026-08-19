class_name LineChart
extends Control
## The dashboard's chart primitive (doc 12 §2.10): one polyline in a box, drawn
## with `_draw` and nothing else — no external library, no texture, no shader.
##
## It owns **no maths**. `HistoryModel.normalized()` fits the series into the
## unit square, headless and tested; this class multiplies those points by its
## own rect, flips y (screen y grows downward, a chart's does not) and strokes
## them. That is the whole class, and it is why the charts are testable without a
## viewport.
##
## Colour comes from the theme's generated `Palette` type (§4.3 — zero per-node
## style overrides), so a colourblind variant or an art repaint carries the
## charts with it. A5: the line is also drawn with a state-appropriate dash
## pattern from `data/ui.json.state_dash`, so a rising and a falling series are
## distinguishable with no colour vision at all.

const PALETTE_TYPE := "Palette"

const _DEFAULT_WIDTH_DP := 2.0
const _DEFAULT_BASELINE_ALPHA := 0.25

## Points in the unit square, oldest first — `HistoryModel.normalized().points`.
var points := PackedVector2Array()
## Which palette token the stroke takes (one of the four data states).
var state: StringName = HudModel.STATE_NORMAL
## Dash pattern `[on_dp, off_dp]` from `data/ui.json.state_dash`; `[1, 0]` is solid.
var dash: Array = [1, 0]

var line_width := _DEFAULT_WIDTH_DP
var fill_alpha := 0.0
var _baseline := true


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## The one call the dashboard makes. `shape` is a `HistoryModel.normalized()`
## result; `cfg` supplies the dash pattern for `state`.
func set_shape(shape: Dictionary, p_state: StringName, cfg: UIConfig = null) -> void:
	var raw: Variant = shape.get("points", PackedVector2Array())
	points = raw if raw is PackedVector2Array else PackedVector2Array()
	state = p_state
	dash = LineChart.dash_for(cfg, p_state)
	queue_redraw()


static func dash_for(cfg: UIConfig, p_state: StringName) -> Array:
	if cfg == null:
		return [1, 0]
	var block := cfg.section("state_dash")
	var raw: Variant = block.get(String(p_state), [1, 0])
	return raw if raw is Array and (raw as Array).size() >= 2 else [1, 0]


func set_baseline(enabled: bool) -> void:
	_baseline = enabled
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	if rect.size.x <= 1.0 or rect.size.y <= 1.0:
		return
	var stroke := _color(state, Color(1, 1, 1))
	if _baseline:
		var dim := _color(&"text_dim", Color(0.6, 0.6, 0.6))
		draw_line(Vector2(0.0, rect.size.y - 1.0), Vector2(rect.size.x, rect.size.y - 1.0),
				Color(dim, _DEFAULT_BASELINE_ALPHA), 1.0)
	if points.size() < 2:
		if points.size() == 1:
			draw_circle(_to_screen(points[0], rect), maxf(1.5, line_width), stroke)
		return
	var on_dp := maxf(0.0, float(dash[0]))
	var off_dp := maxf(0.0, float(dash[1]))
	for i in range(1, points.size()):
		var a := _to_screen(points[i - 1], rect)
		var b := _to_screen(points[i], rect)
		if off_dp <= 0.0:
			draw_line(a, b, stroke, line_width, true)
		else:
			_draw_dashed(a, b, stroke, on_dp, off_dp)


## Screen space: x runs left to right, y is flipped so 0 sits on the baseline.
## One pixel of inset top and bottom keeps a maximum from being clipped by the
## stroke's own width.
func _to_screen(point: Vector2, rect: Rect2) -> Vector2:
	var inset := line_width
	var usable := maxf(1.0, rect.size.y - inset * 2.0)
	return Vector2(point.x * rect.size.x,
			rect.size.y - inset - point.y * usable)


func _draw_dashed(a: Vector2, b: Vector2, color: Color, on_dp: float,
		off_dp: float) -> void:
	var span := a.distance_to(b)
	if span <= 0.0001:
		return
	var direction := (b - a) / span
	var travelled := 0.0
	var period := maxf(0.5, on_dp + off_dp)
	while travelled < span:
		var end := minf(travelled + on_dp, span)
		draw_line(a + direction * travelled, a + direction * end, color, line_width, true)
		travelled += period


func _color(token: StringName, fallback: Color) -> Color:
	if has_theme_color(token, PALETTE_TYPE):
		return get_theme_color(token, PALETTE_TYPE)
	return fallback
