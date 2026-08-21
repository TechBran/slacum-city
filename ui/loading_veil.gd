class_name LoadingVeil
extends Control
## S15, the loading veil — doc 13 §2.9 / §2.9.1's `veil.show()`, doc 91 §20.2
## item 19. See `VeilModel` for what it draws and why the bar is a bar.
##
## **It is a veil and not a screen: it has no targets at all.** Every other
## surface in the deck ends in a `Button`, and every one of them is a row in the
## A3/A15 audit. This one is a scrim, a card, two labels and a `MeterBar`, and
## that is deliberate — doc 08's contract for a stepped restore is that *nothing*
## may tick, render against or query the sim between steps, and the veil is what
## enforces it. A control the player could press during a half-restored city
## would be the one thing that breaks the guarantee this screen exists to make.
## Its scrim therefore swallows input (`MOUSE_FILTER_STOP`) and offers none.
##
## **It is absent unless the shell asks.** Like S0, the scene authors it closed
## and nothing in `ui/` opens it — `UIRoot.present_veil_load()` does, and only
## `game/main.gd` and `tools/ui_preview.gd` call that. A headless mount that never
## asks never sees a veil, which is what keeps the other 53 preview states
## measuring the deck rather than measuring this.
##
## Code-built body over an authored two-node stub, the pattern every screen in
## `ui/` uses: the scene carries `Scrim` and `Center`, and everything inside the
## card is made here so it scales with A2 without a second copy of the layout
## living in a `.tscn`.

signal veil_toggled(open: bool)

## The scrim is heavier than a modal's (`SCRIM_ALPHA` 0.55 elsewhere): there is
## no city behind this one worth reading, and a half-restored world is precisely
## what it is for.
const SCRIM_ALPHA := 0.92
const DEFAULT_CARD_W_DP := 320.0
const DEFAULT_BAR_H_DP := 8.0
## §A5's redundancy channel on a progress bar: the fill is also a count of filled
## segments, so the reading survives with no colour vision at all.
const BAR_SEGMENTS := 5

var config: UIConfig
var model: VeilModel

var _scrim: ColorRect
var _center: CenterContainer
var _panel: PanelContainer
var _body: VBoxContainer
var _title: Label
var _detail: Label
var _bar: MeterBar

var _touch_min := 48.0
var _spacing := 8.0
var _card_w := DEFAULT_CARD_W_DP
var _bar_h := DEFAULT_BAR_H_DP
var _open := false


func setup(cfg: UIConfig = null, p_model: VeilModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	model = p_model if p_model != null else VeilModel.new(config)
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	var veil_cfg := config.section("veil")
	_card_w = UIConfig.get_num(veil_cfg, "card_w_dp", DEFAULT_CARD_W_DP)
	_bar_h = UIConfig.get_num(veil_cfg, "bar_h_dp", DEFAULT_BAR_H_DP)
	_bind_nodes()
	_build_static()
	refresh()
	dismiss()
	if not resized.is_connected(_apply_card_box):
		resized.connect(_apply_card_box)
	set_process(true)


## Re-solved every frame the veil is up, for S0's reason: the copy changes under
## it (a step counter every frame, a phase switch once) and a container re-sorts
## on the NEXT idle pass, so the box solved inside the handler is measured
## against the layout that is going away. The veil is on screen for the length of
## a load and nothing else is; this costs one minimum-size query per frame of it.
func _process(_delta: float) -> void:
	if _open:
		_apply_card_box()


func _ready() -> void:
	if model == null:
		setup(UIRoot.config_from(self))


func _bind_nodes() -> void:
	_scrim = get_node_or_null("Scrim") as ColorRect
	_center = get_node_or_null("Center") as CenterContainer
	if _center == null:
		return
	_panel = _center.get_node_or_null("Panel") as PanelContainer
	if _panel == null:
		_panel = PanelContainer.new()
		_panel.name = "Panel"
		_panel.theme_type_variation = &"SheetPanel"
		_center.add_child(_panel)
	_body = _panel.get_node_or_null("Body") as VBoxContainer


func _build_static() -> void:
	if _scrim != null:
		_scrim.color = UIWidgets.scrim_color(self, SCRIM_ALPHA)
		# The veil is the only surface in the deck that must EAT input rather than
		# pass it through: doc 08 §2.15.2 says nothing may query the sim between
		# restore steps, and a tap that reaches the city underneath would.
		_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	if _panel == null:
		return
	if _body == null:
		_body = VBoxContainer.new()
		_body.name = "Body"
		_panel.add_child(_body)
	UIWidgets.clear_children(_body)
	_body.add_theme_constant_override(&"separation", int(_spacing))

	_title = UIWidgets.label("Title", "", &"", true)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body.add_child(_title)

	_bar = MeterBar.new()
	_bar.name = "Bar"
	_bar.segments = BAR_SEGMENTS
	_bar.custom_minimum_size = Vector2(_card_w, maxf(1.0, _bar_h))
	_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(_bar)

	_detail = UIWidgets.label("Detail", "", &"LegendRow", true)
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body.add_child(_detail)
	_apply_card_box()


## The card never outgrows the display (D-52): a `CenterContainer` lays its child
## out at exactly the child's minimum, and a minimum taller than the viewport
## hangs off both ends. Three short lines are nowhere near 340 dp today — this is
## here because the copy is translatable and the type scale is the player's.
func _apply_card_box() -> void:
	if _panel == null or _body == null or size.y <= 1.0:
		return
	# The WIDTH first, and the card is capped on that axis too — or a long city
	# name on a 640 dp box makes a card wider than the box it is centred in. The
	# bar carries it: it is the one child with a width of its own, and the two
	# labels wrap to whatever it settles on.
	if _bar != null:
		_bar.custom_minimum_size.x = minf(_card_w,
				maxf(_touch_min, size.x - _spacing * 4.0))
	# **The cap is load-bearing on the first frame, not decorative.** An
	# autowrapped `Label` reports a minimum HEIGHT shaped at the width it
	# currently has, Godot invalidates that cache through the message queue, and
	# on the frame the veil goes up neither label has been laid out yet — so the
	# body measures **771 dp**, one word to a line, against a 332 dp box. The
	# clamp holds the card inside the display for that one frame and `_process`
	# re-solves it to its real 93 dp on the next. Without `card_height()` here the
	# veil would hang off both edges of every box for a frame, which is exactly
	# D-52's defect with a shorter fuse.
	var content := _body.get_combined_minimum_size().y
	var box := _panel.get_theme_stylebox(&"panel")
	if box != null:
		content += box.content_margin_top + box.content_margin_bottom
	_panel.custom_minimum_size.y = UIWidgets.card_height(size.y, content,
			_spacing, _touch_min)


# ---------------------------------------------------------------------------
# The two phases
# ---------------------------------------------------------------------------

## Raise the veil over a stepped restore. `city` is what the player calls the
## thing being opened — the shell's slot label, because `ui/` has no slot list.
func present_load(city: String, total_steps: int) -> void:
	if model == null:
		setup()
	model.begin_load(city, total_steps)
	_set_open(true)
	refresh()


## Where the restore cursor has got to (`RestoreCursor.completed()`).
func advance_load(completed: int) -> void:
	if model == null:
		return
	model.advance_load(completed)
	refresh()


## Switch to (or raise) doc 13 §2.9's catch-up messaging. Answers false when the
## absence is beneath `VeilModel.min_steps()`, in which case the veil is down.
func present_catchup(hours: int, total_steps: int, capped: bool = false) -> bool:
	if model == null:
		setup()
	var up := model.begin_catchup(hours, total_steps, capped)
	_set_open(up)
	refresh()
	return up


func advance_catchup(completed: int) -> void:
	if model == null:
		return
	model.advance_catchup(completed)
	refresh()


## Down, whatever phase it was in. Idempotent.
func dismiss() -> void:
	if model != null:
		model.finish()
	_set_open(false)
	refresh()


func is_open() -> bool:
	return _open


func refresh() -> void:
	if model == null:
		return
	var view := model.build_view()
	if _title != null:
		_title.text = str(view["title"])
	if _detail != null:
		_detail.text = str(view["detail"])
		_detail.visible = _detail.text != ""
	if _bar != null:
		_bar.set_value(float(view["progress01"]), HudModel.STATE_NORMAL)
	_apply_card_box()


## Not guarded on `_open`: the scene authors the stub visible (an invisible
## branch has no geometry for the audit to judge, and `setup()` is what closes
## it), so the first call has to be allowed to disagree with the flag.
func _set_open(value: bool) -> void:
	var changed := _open != value
	_open = value
	visible = value
	if _scrim != null:
		_scrim.visible = value
	if _center != null:
		_center.visible = value
	if changed:
		veil_toggled.emit(value)
