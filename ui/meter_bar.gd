class_name MeterBar
extends Control
## A one-value bar drawn with `_draw`: the incident drawer's escalation clock
## (doc 12 §2.6) and any other "fraction of the way to something" the console
## needs.
##
## It exists so a filled bar can take one of the four data-state colours without
## a per-node stylebox override — doc 12 §4.3 permits exactly one Theme and zero
## per-node styles, and Godot's `ProgressBar` can only be recoloured by
## overriding its fill stylebox. Drawing it directly keeps that rule intact and
## costs two `draw_rect` calls.
##
## A5: the fill is *also* segmented into five ticks, so the value is readable as
## a count of filled segments with no colour vision at all — the same redundancy
## the tier badge gets from its digit.

const PALETTE_TYPE := "Palette"

const _TRACK_ALPHA := 0.30
const _DEFAULT_SEGMENTS := 5

var value01 := 0.0
var state: StringName = HudModel.STATE_NORMAL
var segments := _DEFAULT_SEGMENTS
## Frozen bars (§2.6's HELD) draw their track hatched rather than empty, so
## "nothing is happening here" reads differently from "it has not started yet".
var frozen := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_value(p_value01: float, p_state: StringName, p_frozen: bool = false) -> void:
	value01 = clampf(p_value01, 0.0, 1.0)
	state = p_state
	frozen = p_frozen
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	if rect.size.x <= 1.0 or rect.size.y <= 1.0:
		return
	var fill := _color(state, Color(1, 1, 1))
	draw_rect(rect, Color(fill, _TRACK_ALPHA), true)
	if value01 > 0.0:
		draw_rect(Rect2(Vector2.ZERO, Vector2(rect.size.x * value01, rect.size.y)),
				fill, true)
	# Segment ticks: the redundancy channel. Drawn over both track and fill in the
	# panel's own background colour so they read on either side of the boundary.
	var divider := _color(&"bg", Color(0, 0, 0))
	for i in range(1, maxi(1, segments)):
		var x := rect.size.x * float(i) / float(maxi(1, segments))
		draw_line(Vector2(x, 0.0), Vector2(x, rect.size.y), divider, 1.0)
	if frozen:
		# A held bar gets a full-height outline, which is what says "this clock is
		# stopped" without relying on the fill having turned green.
		draw_rect(rect, fill, false, 1.0)


func _color(token: StringName, fallback: Color) -> Color:
	if has_theme_color(token, PALETTE_TYPE):
		return get_theme_color(token, PALETTE_TYPE)
	return fallback
