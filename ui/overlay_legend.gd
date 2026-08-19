class_name OverlayLegend
extends PanelContainer
## Doc 12 §2.5's `OverlayLegend`: the 200 dp card at the **top-left** carrying the
## active overlay's name, its state rows, and one to three overlay-specific
## aggregate lines. Collapsible to a pill, and the collapse persists per overlay.
##
## It exists because the legend used to live inside the chip strip, and the strip
## is a *control*: it is raised to pick an overlay and dismissed afterwards, which
## took the legend with it — so the reading the overlay exists to give was on
## screen only while the player was busy choosing a different one. Splitting them
## is the whole of report 98's "still open against doc 12" line for §2.5.
##
## Built entirely in code and parented by `OverlayRail`, which already spans the
## whole HUD layer, so `game/ui/ui_root.tscn` gains no node. Dumb by construction:
## `OverlayModel` owns the rows, the words, the collapse state and the aggregate
## lines; this turns them into Labels and reports taps.

signal collapse_toggled(mode: StringName, collapsed: bool)

const COLLAPSE_GLYPH := "▾"
const EXPAND_GLYPH := "▸"

var config: UIConfig
var model: OverlayModel

var _body: VBoxContainer
var _header: HBoxContainer
var _title: Label
var _toggle: Button
var _rows: VBoxContainer
var _summary: VBoxContainer
var _mode: StringName = OverlayModel.MODE_NONE
var _touch_min := 48.0
var _spacing := 8.0
## The rail's measurement of the real top bar; see `place()`.
var _reserved_top: float = -1.0
## Set by the rail when the raised chip strip has taken the whole left edge and
## there is no room beside it (a narrow phone at 130 % type). The card steps out
## of the way for as long as the strip is up rather than sharing a tap target
## with a chip or hanging off the display — and comes straight back when the
## strip is dismissed, which is one tap away and the thing the player is doing.
var _yielded: bool = false


func setup(cfg: UIConfig, p_model: OverlayModel) -> void:
	config = cfg
	model = p_model
	name = "OverlayLegend"
	theme_type_variation = &"SheetPanel"
	mouse_filter = Control.MOUSE_FILTER_PASS
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_build()
	place()
	visible = false


func _build() -> void:
	UIWidgets.clear_children(self)
	_body = VBoxContainer.new()
	_body.name = "Body"
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_theme_constant_override(&"separation", int(_spacing))
	add_child(_body)

	_header = HBoxContainer.new()
	_header.name = "Header"
	_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header.add_theme_constant_override(&"separation", int(_spacing))
	_body.add_child(_header)

	_title = UIWidgets.label("Title", "", &"LegendRow")
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header.add_child(_title)

	# A3: the fold control is a real tap target, not a 16 dp chevron. It is also
	# the only interactive thing on the card, so the card itself stays PASS and
	# never steals a tap meant for the city underneath it.
	_toggle = UIWidgets.button("Toggle", COLLAPSE_GLYPH, "",
			Vector2(_touch_min, _touch_min), &"GhostButton")
	_toggle.pressed.connect(_on_toggle)
	_header.add_child(_toggle)

	_rows = VBoxContainer.new()
	_rows.name = "Rows"
	_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_child(_rows)

	_summary = VBoxContainer.new()
	_summary.name = "Summary"
	_summary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_child(_summary)


## Top-left, under the top bar (§2.5). Re-solved on every repaint because the top
## bar's height is only knowable once the theme and the type scale have run —
## and it is not the authored `top_bar_h_dp`: on a 412 dp phone the chips wrap
## onto a second row (§2.4's `solve_top_bar`) and the bar is 118 dp tall, which
## is exactly how this card's fold button ended up sharing a tap target with the
## 💧 chip. `reserved_top` is the rail's measurement of the real bar; the
## authored constant is only the fallback.
## `left_override` is the rail's other measurement: on a short landscape box the
## raised chip strip grows up the left edge and reaches the card, and §2.5 puts
## both of them there. The strip wins its corner — it is the control the player
## is touching — and the card steps to the right of it rather than sharing a tap
## target with a chip.
func place(reserved_top: float = -1.0, left_override: float = -1.0) -> void:
	if config == null:
		return
	if reserved_top >= 0.0:
		_reserved_top = reserved_top
	reserved_top = _reserved_top
	var card := model.legend_card() if model != null else {}
	var layout := config.layout()
	var bar := reserved_top if reserved_top >= 0.0 \
			else UIConfig.get_num(layout, "top_bar_h_dp", 48.0)
	var top := bar + maxf(UIConfig.get_num(card, "top_dp", 8.0), _spacing)
	var left := UIConfig.get_num(card, "left_dp", 12.0)
	if left_override >= 0.0:
		left = left_override
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	offset_left = left
	offset_top = top
	# A width, never a height: the card is as tall as its rows, and a fixed
	# height would clip the fifth traffic band at 130 % text.
	var wanted := UIConfig.get_num(card, "w_dp", 200.0)
	custom_minimum_size = Vector2(wanted, 0.0)
	offset_right = left + maxf(wanted, get_combined_minimum_size().x)
	offset_bottom = top + get_combined_minimum_size().y


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

## The active overlay. `none` hides the card outright — a legend for no overlay
## is a box of words about nothing.
func show_mode(mode: StringName) -> void:
	_mode = mode
	if mode == OverlayModel.MODE_NONE or model == null:
		visible = false
		return
	visible = not _yielded
	if visible:
		_repaint()


## See `_yielded`. Returns true when the visibility actually changed.
func set_yielded(value: bool) -> bool:
	if _yielded == value:
		return false
	_yielded = value
	visible = _mode != OverlayModel.MODE_NONE and not _yielded
	if visible:
		_repaint()
	return true


func is_yielded() -> bool:
	return _yielded


## Same mode, fresh numbers — what the shell calls after feeding new aggregates.
func refresh() -> void:
	if visible:
		_repaint()


func _repaint() -> void:
	var collapsed := model.is_legend_collapsed(_mode)
	var mode_name := UIWidgets.t(config, OverlayModel.label_key(_mode))
	_title.text = mode_name
	UIWidgets.elide(_title, _touch_min)
	_toggle.text = EXPAND_GLYPH if collapsed else COLLAPSE_GLYPH
	_toggle.tooltip_text = UIWidgets.t_args(config, "ui_overlay_legend_expand",
			{"name": mode_name}) if collapsed \
			else UIWidgets.t(config, "ui_overlay_legend_collapse")
	_rows.visible = not collapsed
	_summary.visible = not collapsed
	if collapsed:
		# Emptied, not merely hidden: a hidden `Container` still reports its own
		# minimum size, and §2.5's folded card is a 32 dp pill — not a 200 dp card
		# with invisible contents holding it open.
		UIWidgets.clear_children(_rows)
		UIWidgets.clear_children(_summary)
		place()
		return
	_fill_rows()
	_fill_summary()
	place()


func _fill_rows() -> void:
	UIWidgets.clear_children(_rows)
	for row: Dictionary in model.legend_rows_for(_mode):
		var row_id := String(row["band"]) if row.has("band") else String(row["state"])
		var line := UIWidgets.label("Row_" + row_id,
				("%s %s" % [str(row["glyph"]), _label(row)]).strip_edges())
		_rows.add_child(line)
		UIWidgets.paint_state(self, line, row["state"])


## §2.5's aggregate lines: name on the left, figure on the right, in the same
## shape as the dashboard's ledger so the eye reads down one column of numbers.
func _fill_summary() -> void:
	UIWidgets.clear_children(_summary)
	for line: Dictionary in model.summary_lines(_mode):
		var record := HBoxContainer.new()
		record.name = "Line_" + str(line.get("id", line.get("label", "")))
		record.mouse_filter = Control.MOUSE_FILTER_IGNORE
		record.add_theme_constant_override(&"separation", int(_spacing))
		var label := UIWidgets.elide(UIWidgets.label("Label",
				str(line.get("label", ""))), _touch_min) as Label
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		record.add_child(label)
		var value := UIWidgets.label("Value", str(line.get("value", "")))
		value.size_flags_horizontal = Control.SIZE_SHRINK_END
		UIWidgets.paint_state(self, value, StringName(str(line.get("state", ""))))
		record.add_child(value)
		_summary.add_child(record)


func _label(row: Dictionary) -> String:
	var mode_key := str(row.get("mode_label_key", ""))
	if mode_key != "" and config != null and config.has_string(mode_key):
		return config.t(mode_key)
	return UIWidgets.t(config, str(row["label_key"]))


func _on_toggle() -> void:
	var collapsed := model.toggle_legend_collapsed(_mode)
	_repaint()
	collapse_toggled.emit(_mode, collapsed)


# ---------------------------------------------------------------------------
# Helpers (the tests and the rail read the card through these)
# ---------------------------------------------------------------------------

func mode() -> StringName:
	return _mode


func is_collapsed() -> bool:
	return model != null and model.is_legend_collapsed(_mode)


## One legend line by its row id — a state token (`normal`…`offline`) or, in
## TRAFFIC, a band name (`clear`…`gridlock`).
func legend_row(row_id: StringName) -> Label:
	return _rows.get_node_or_null("Row_" + String(row_id)) as Label if _rows != null \
			else null


func summary_count() -> int:
	return _summary.get_child_count() if _summary != null else 0


func toggle_button() -> Button:
	return _toggle
