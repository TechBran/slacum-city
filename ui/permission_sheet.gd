class_name PermissionSheet
extends Control
## The in-game rationale modal for `POST_NOTIFICATIONS` — doc 13 §2.7 step 3,
## rendered as a doc 12 modal (§2.2's full-screen sheet contract).
##
##     ┌────────────────────────────────────────────┐
##     │  Get told when your city is in trouble.    │
##     │                                            │
##     │  Storm warnings, major outages and         │
##     │  finished construction — nothing else.     │
##     │                                            │
##     │            [ NOT NOW ]   [ TURN ON ]       │
##     └────────────────────────────────────────────┘
##
## **Why a screen of our own in front of Android's.** The system dialog is
## one-shot: two dismissals and it never appears again for the life of the
## install, with no route back except the app's page in system settings. So the
## expensive thing is not the permission, it is the *ask*, and this modal exists
## to spend the ask only on a player who has already said yes. `PermissionFlow`
## decides whether to show it at all; this file decides nothing.
##
## **Three exits, and they are not the same exit.** TURN ON opens the system
## dialog. NOT NOW is an answer — it costs one of Android's two chances,
## deliberately, because treating a dismissal as "ask me later" is how an app
## nags. **BACK costs nothing**: doc 12 §2.2 makes BACK the universal "close the
## thing in front of me", and a player who reached for it did not answer a
## question — so it closes the sheet and the flow's counters do not move. That
## asymmetry is the whole reason `answered` is emitted by the two buttons and
## never by `close()`.
##
## Built in code rather than authored into `ui_root.tscn`, because it is the one
## modal that may be absent: off Android there is no permission to hold, and a
## sheet nobody can open is a node the tree does not need.

## The player answered. `accepted` true means TURN ON — the shell calls
## `PermissionFlow.accept()`; false means NOT NOW → `decline()`.
signal answered(accepted: bool)

const SCRIM_ALPHA := 0.55  ## §2.17's dim, the same one every modal scrim uses
## The two `PermissionFlow` reasons, re-exported so the shell can name the copy
## it wants without importing the state machine into a view.
const REASON_FIRST := PermissionFlow.REASON_FIRST
const REASON_MISSED_P1 := PermissionFlow.REASON_MISSED_P1

var config: UIConfig

var _scrim: ColorRect
var _panel: PanelContainer
var _title: Label
var _body: Label
var _accept: Button
var _decline: Button
var _reason := REASON_FIRST
var _touch_min := 48.0
var _spacing := 8.0


func setup(cfg: UIConfig = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_build()
	close()


func _ready() -> void:
	if config == null:
		setup(UIRoot.config_from(self))


func _build() -> void:
	if _panel != null:
		return
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_scrim = ColorRect.new()
	_scrim.name = "Scrim"
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.color = UIWidgets.scrim_color(self, SCRIM_ALPHA)
	add_child(_scrim)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.theme_type_variation = &"SheetPanel"
	# Centred, and narrower than the screen at every breakpoint: this is a
	# question, not a page, and a question that fills a phone reads as an error.
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.custom_minimum_size = Vector2(288.0, 0.0)
	add_child(_panel)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override(&"separation", int(_spacing))
	_panel.add_child(body)

	# No type variation, for the same reason S9's header has none: doc 12 §4.3
	# ships one Label size and the sheets distinguish their header by position
	# and copy, not by a font override nobody else has.
	_title = UIWidgets.label("Title", "", &"", true)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_title)

	_body = UIWidgets.label("Body", "", &"", true)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_body)

	# An `HFlowContainer` for D-47's reason: two buttons that do not fit side by
	# side stack instead of widening the sheet past the phone.
	var actions := HFlowContainer.new()
	actions.name = "Actions"
	actions.alignment = FlowContainer.ALIGNMENT_END
	actions.add_theme_constant_override(&"h_separation", int(_spacing))
	actions.add_theme_constant_override(&"v_separation", int(_spacing))
	body.add_child(actions)

	_decline = UIWidgets.button("Decline", _t("ui_permission_decline"), "",
			Vector2(maxf(_touch_min * 2.5, 120.0), _touch_min), &"GhostButton")
	_decline.pressed.connect(_on_answer.bind(false))
	actions.add_child(_decline)

	_accept = UIWidgets.button("Accept", _t("ui_permission_accept"), "",
			Vector2(maxf(_touch_min * 2.5, 120.0), _touch_min), &"PrimaryFAB")
	_accept.pressed.connect(_on_answer.bind(true))
	actions.add_child(_accept)


func _t(key: String) -> String:
	return UIWidgets.t(config, key)


# ---------------------------------------------------------------------------
# Open / close — the `is_open()` + `close()` pair `UIRoot`'s back stack walks
# ---------------------------------------------------------------------------

## `reason` is one of `PermissionFlow`'s two tokens. An unknown one falls back to
## the first-ask copy rather than showing an empty sheet.
func present(reason: String = REASON_FIRST) -> void:
	if _panel == null:
		setup(config)
	_reason = reason if reason == REASON_MISSED_P1 else REASON_FIRST
	if _title != null:
		_title.text = _t("ui_permission_title_%s" % _reason)
	if _body != null:
		_body.text = _t("ui_permission_body_%s" % _reason)
	UIWidgets.close_siblings(self)
	_set_visible(true)


func reason() -> String:
	return _reason


func is_open() -> bool:
	return _panel != null and _panel.visible


## BACK, or the shell taking the sheet away. Emits nothing: see the class doc —
## a dismissal that was not an answer must not spend one of Android's two.
func close() -> void:
	_set_visible(false)


func _on_answer(accepted: bool) -> void:
	_set_visible(false)
	answered.emit(accepted)


func _set_visible(value: bool) -> void:
	if _panel != null:
		_panel.visible = value
	if _scrim != null:
		_scrim.visible = value
		_scrim.mouse_filter = Control.MOUSE_FILTER_STOP if value \
				else Control.MOUSE_FILTER_IGNORE


func accept_button() -> Button:
	return _accept


func decline_button() -> Button:
	return _decline
