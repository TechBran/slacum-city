class_name BuildingPanel
extends Control
## S5 of doc 12 §2.2, laid out per §2.9: header (name + level pips + condition),
## the 2×3 vitals grid, the four service-coverage tiles, and the upgrade block —
## cost, the **requirement checklist**, and an `UPGRADE` button that is disabled
## while any `✗` remains and whose subtitle names the first blocker.
##
## Dumb by construction: `BuildController.building_view()` computes every value
## and `RequirementFormatter` writes every requirement line, so this file holds
## no threshold, no gate and no copy. Each checklist row carries the `Fix this →`
## affordance of §2.7 — "the single most important teaching device in the game" —
## which this panel surfaces as a signal for the camera/panel router to act on.

signal closed
signal upgraded(result: Dictionary)             ## `upgrade_building` answered
signal fix_requested(fix_target: Dictionary)    ## `Fix this →` on a blocker row
## §2.9 item 6's three verbs. Each carries the sim's own `{ok, reason_code,
## payload}` so the shell can re-read the city rather than guess what moved.
signal repaired(result: Dictionary)             ## `cmd_repair_building` answered
signal priority_set(result: Dictionary)         ## `cmd_set_priority` answered
signal demolished(sim_id: String, result: Dictionary)  ## `cmd_demolish_building`
## Doc 05 §6's node ladder (doc 93 §J1). A water shell hosts one or more doc-05
## nodes and each has a capacity to buy; this fires with the sim's own answer,
## exactly as `upgraded` does for the doc-02 shell above it.
signal water_upgraded(node_id: String, result: Dictionary)
## S16's verb, on the panel of the building it is about (doc 12 §2.22 item 3).
## Carries `cmd_rush_construction`'s own answer, exactly as `upgraded` carries
## `upgrade_building`'s, so the shell re-reads the city rather than guessing.
signal rushed(sim_id: String, job_id: int, result: Dictionary)

## Doc 04 §4's operating verbs (Wave 17). `power_fixed` is the one-tap
## `POWER_CAPACITY` answer — the row whose `Fix this →` used to focus the camera
## on the building the player already had open — and `grid_upgraded` is a rung
## bought on the transformer or the feeder that feeds this building. Both carry
## the sim's own `{ok, reason_code, payload}` so the shell re-reads the city.
signal power_fixed(sim_id: String, result: Dictionary)
signal grid_upgraded(component_id: String, result: Dictionary)
signal grid_demolished(component_id: String, result: Dictionary)

const PALETTE_TYPE := "Palette"
## §2.9's `L1 L2 ▮L3▮ L4 L5` level pips — glyphs, not copy (A5 redundancy).
const PIP_ON := "▮"
## Every panel in the deck closes with this glyph and names itself in the tooltip.
const CLOSE_GLYPH := "✕"
## §2.9 item 6: `Demolish` is hold-to-confirm, because it is the one button in
## the deck that cannot be undone. The window is `data/ui.json.layout`'s, with
## the doc's own 800 ms as the floor if the key is missing.
const HOLD_TO_CONFIRM_MS_DEFAULT := 800.0

var config: UIConfig
var controller: BuildController

var _panel: PanelContainer
var _title: Label
var _close: Button
var _level: Label
var _vitals: GridContainer
var _coverage: GridContainer
var _upgrade_header: Label
var _upgrade_note: Label
var _checklist: VBoxContainer
var _upgrade_button: Button

## §2.22's inline progress block, built in code directly under the level pips —
## above the upgrade block, because while a project is in flight the question
## "when does THIS land" outranks "what comes after it".
var _progress: VBoxContainer
var _progress_title: Label
var _progress_bar: MeterBar
var _progress_percent: Label
var _progress_eta: Label
var _progress_crew: Label
var _progress_rush: Button
## S16's model, shared with the queue panel. Null until the shell binds one, and
## the block then never appears — the same degrade S4 and S5 already make.
var construction: ConstructionQueueModel
var _progress_job := -1

## §2.9 item 6's actions row, built in code below `UpgradeButton`.
var _actions: VBoxContainer
## Doc 05 §6's node block, built in code below the actions row.
var _water: VBoxContainer
var _water_rows: Dictionary = {}   # node id -> Button
## Doc 12 §2.9 D-70's POWER section, built in code below the water block.
var _power: VBoxContainer
var _power_rows: Dictionary = {}   # component id -> Button
var _power_remove_rows: Dictionary = {}   # component id -> Button
var _power_fix_button: Button
## The transformer the REMOVE row is armed for, `""` when nothing is armed. Same
## two-tap contract as the fix strip, and cleared by every re-render of a
## DIFFERENT building, so an armed row cannot follow the selection.
var _power_remove_armed := ""
## The `Fix this →` strip is a two-tap confirm: the first tap quotes, the second
## buys. This holds the sim id the strip is armed for, `""` when it is not armed
## — so a strip that is still on screen after the player selected a DIFFERENT
## building cannot spend money on that one.
var _power_fix_armed := ""
var _repair_button: Button
var _repair_note: Label
var _priority_row: HBoxContainer
var _priority_note: Label
var _demolish_button: Button
var _demolish_note: Label

var _sim_id := ""
var _touch_min := 48.0
var _spacing := 8.0
var _view: Dictionary = {}
var _hold_ms := HOLD_TO_CONFIRM_MS_DEFAULT
## Seconds the demolish button has been held, and the label it is overwriting
## while it counts. `< 0` when nothing is being held.
var _hold_elapsed := -1.0
var _priority_buttons: Dictionary = {}   # class name -> Button


func setup(cfg: UIConfig = null, p_controller: BuildController = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	if p_controller != null:
		controller = p_controller
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_hold_ms = maxf(1.0, UIConfig.get_num(config.layout(), "hold_to_confirm_ms",
			HOLD_TO_CONFIRM_MS_DEFAULT))
	_bind_nodes()
	_build_static()
	close()


func _ready() -> void:
	if config == null:
		# The root's parse, not a second one — see `CityHUD._ready()`.
		setup(UIRoot.config_from(self))


func _bind_nodes() -> void:
	_panel = get_node_or_null("Panel") as PanelContainer
	_title = get_node_or_null("Panel/Scroll/Body/Header/Title") as Label
	_close = get_node_or_null("Panel/Scroll/Body/Header/Close") as Button
	_level = get_node_or_null("Panel/Scroll/Body/Level") as Label
	_vitals = get_node_or_null("Panel/Scroll/Body/Vitals") as GridContainer
	_coverage = get_node_or_null("Panel/Scroll/Body/Coverage") as GridContainer
	_upgrade_header = get_node_or_null("Panel/Scroll/Body/UpgradeHeader") as Label
	_upgrade_note = get_node_or_null("Panel/Scroll/Body/UpgradeNote") as Label
	_checklist = get_node_or_null("Panel/Scroll/Body/Checklist") as VBoxContainer
	_upgrade_button = get_node_or_null("Panel/Scroll/Body/UpgradeButton") as Button


static func _clear_children(node: Node) -> void:
	if node == null:
		return
	for child in node.get_children():
		node.remove_child(child)
		child.free()


func _build_static() -> void:
	var panel_w := UIConfig.get_num(config.layout(), "side_panel_w_dp", 300.0)
	if _panel != null:
		_panel.theme_type_variation = &"SidePanel"
		_panel.custom_minimum_size = Vector2(panel_w, 0.0)
	if _close != null:
		_close.theme_type_variation = &"GhostButton"
		_close.focus_mode = Control.FOCUS_NONE
		_close.custom_minimum_size = Vector2(_touch_min, _touch_min)
		# The glyph, with the word in the tooltip — the shape every other close in
		# the deck uses (alerts, drawer, picker, saves, dashboard). This one was
		# the odd one out: a 48 dp square target rendering the word `Close`, which
		# reads as a different control from the ✕ on the panel beside it.
		_close.text = CLOSE_GLYPH
		_close.tooltip_text = _text("ui_building_close", "Close")
		if not _close.pressed.is_connected(close):
			_close.pressed.connect(close)
	if _upgrade_button != null:
		_upgrade_button.theme_type_variation = &"PrimaryFAB"
		_upgrade_button.focus_mode = Control.FOCUS_NONE
		_upgrade_button.custom_minimum_size = Vector2(_touch_min * 2.0, _touch_min)
		_upgrade_button.text = _text("ui_building_upgrade", "UPGRADE")
		_upgrade_button.tooltip_text = _upgrade_button.text
		if not _upgrade_button.pressed.is_connected(request_upgrade):
			_upgrade_button.pressed.connect(request_upgrade)
	# §2.9's 2×3 vitals grid, and the four coverage tiles as 2×2 — four in one row
	# does not fit a 300 dp column at any text scale.
	for grid: GridContainer in [_vitals, _coverage]:
		if grid != null:
			grid.columns = 2
			grid.add_theme_constant_override(&"h_separation", int(_spacing))
	if _checklist != null:
		_checklist.add_theme_constant_override(&"separation", int(_spacing))
	_build_actions()


## §2.9 item 6 — `Repair` · `Priority` · `Demolish`, built in code (doc 12 test
## 19: no `theme_override_*` in a scene file) and appended below the upgrade
## block, which is the order the doc lists them in.
##
## Idempotent: `setup()` runs twice in the real shell, once from
## `UIRoot.bring_up_screens()` and once from `game/main.gd`.
func _build_actions() -> void:
	if _upgrade_button == null:
		return
	var body := _upgrade_button.get_parent() as Control
	if body == null:
		return
	var existing := body.get_node_or_null("Actions") as VBoxContainer
	if existing != null:
		# Second `setup()` pass: re-bind rather than rebuild, exactly as
		# `_bind_nodes()` re-binds the authored half.
		_actions = existing
		_repair_button = existing.get_node_or_null("Repair") as Button
		_repair_note = existing.get_node_or_null("RepairNote") as Label
		_priority_note = existing.get_node_or_null("PriorityNote") as Label
		_priority_row = existing.get_node_or_null("Priority") as HBoxContainer
		_demolish_button = existing.get_node_or_null("Demolish") as Button
		_demolish_note = existing.get_node_or_null("DemolishNote") as Label
		_water = body.get_node_or_null("WaterNodes") as VBoxContainer
		_water_rows.clear()
		_bind_progress(body)

		_power = body.get_node_or_null("PowerSection") as VBoxContainer
		_power_rows.clear()
		_power_remove_rows.clear()
		return
	_build_progress(body)
	_actions = VBoxContainer.new()
	_actions.name = "Actions"
	_actions.add_theme_constant_override(&"separation", int(_spacing))
	body.add_child(_actions)

	_repair_button = UIWidgets.button("Repair", _text("ui_building_repair", "REPAIR"),
			_text("ui_building_repair", "REPAIR"),
			Vector2(_touch_min * 2.0, _touch_min), &"GhostButton")
	_repair_button.pressed.connect(request_repair)
	_actions.add_child(_repair_button)
	_repair_note = UIWidgets.label("RepairNote", "", &"LegendRow", true)
	_actions.add_child(_repair_note)

	_priority_note = UIWidgets.label("PriorityNote", "", &"LegendRow", true)
	_actions.add_child(_priority_note)
	_priority_row = HBoxContainer.new()
	_priority_row.name = "Priority"
	_priority_row.add_theme_constant_override(&"separation", int(_spacing))
	_actions.add_child(_priority_row)

	_demolish_button = UIWidgets.button("Demolish",
			_text("ui_building_demolish", "DEMOLISH"),
			_text("ui_building_demolish_hint", "Hold to confirm"),
			Vector2(_touch_min * 2.0, _touch_min), &"DangerButton")
	# Hold-to-confirm, so this is press/release rather than `pressed` — the one
	# button in the deck that cannot be undone must not fire on a mis-tap.
	_demolish_button.button_down.connect(_on_demolish_down)
	_demolish_button.button_up.connect(_on_demolish_up)
	_actions.add_child(_demolish_button)
	_demolish_note = UIWidgets.label("DemolishNote", "", &"LegendRow", true)
	_actions.add_child(_demolish_note)

	# Doc 05 §6's node block. BELOW the actions row and not inside it: the three
	# actions above act on the doc-02 SHELL, and this acts on the doc-05 nodes
	# the shell hosts — a different asset with a different ladder, which is
	# exactly why doc 93 §J1 ruled it a block of its own rather than a fourth
	# button on that row.
	_water = VBoxContainer.new()
	_water.name = "WaterNodes"
	_water.add_theme_constant_override(&"separation", int(_spacing))
	_water.visible = false
	body.add_child(_water)

	# --- Wave 17: doc 12 §2.9 D-70's POWER section -------------------------
	# Below the water block for the same reason the water block is below the
	# actions row: it is about a DIFFERENT asset. The three buttons above act on
	# this building; this section is the wire that feeds it — which transformer,
	# how loaded it is, and the two purchases (a bigger transformer, heavier
	# copper) that are the answer when it is full. Doc 04 §2.9's transfer rule
	# means that wire can change under the player, so it is read live and never
	# cached across a refresh.
	_power = VBoxContainer.new()
	_power.name = "PowerSection"
	_power.add_theme_constant_override(&"separation", int(_spacing))
	_power.visible = false
	body.add_child(_power)


## §2.22 item 3 — the queue's row, inline on the building it is about.
##
## **It reuses S16's model and S16's words, and that is the point.** A player who
## reads `about 12m left` on this panel and `about 12m left` in the queue is
## reading one fact; two screens computing their own ETA from the same seam is
## how they come to disagree by a minute and teach the player to trust neither.
## The widgets are the ones that already generalise — `MeterBar` (§2.6's clock,
## S14's level bar) and the build-card price face (§2.7) — rather than a second
## private copy of either.
##
## It sits directly under the level pips, ABOVE the upgrade block: while a
## project is in flight, "when does this land" outranks "what comes after it",
## and the upgrade button below is disabled anyway while the shell is busy.
func _build_progress(body: Control) -> void:
	_progress = VBoxContainer.new()
	_progress.name = "Progress"
	_progress.add_theme_constant_override(&"separation", int(_spacing * 0.5))
	_progress.visible = false
	body.add_child(_progress)
	# Under `Level`, which is the second authored child of the body.
	var level_index := _level.get_index() if _level != null else 0
	body.move_child(_progress, level_index + 1)

	_progress_title = UIWidgets.label("Title", "", &"SeverityBadge", true)
	_progress_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress.add_child(_progress_title)

	var clock := HBoxContainer.new()
	clock.name = "Clock"
	clock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clock.add_theme_constant_override(&"separation", int(_spacing))
	_progress.add_child(clock)
	_progress_bar = MeterBar.new()
	_progress_bar.name = "Bar"
	_progress_bar.custom_minimum_size = Vector2(_touch_min, 6.0)
	_progress_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	clock.add_child(_progress_bar)
	_progress_percent = UIWidgets.label("Percent", "")
	clock.add_child(_progress_percent)

	_progress_eta = UIWidgets.label("Eta", "", &"", true)
	_progress_eta.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress.add_child(_progress_eta)
	_progress_crew = UIWidgets.label("Crew", "", &"LegendRow", true)
	_progress.add_child(_progress_crew)

	_progress_rush = UIWidgets.button("Rush", "", "",
			Vector2(_touch_min * 2.0, _touch_min), &"PrimaryFAB")
	_progress_rush.clip_text = false
	_progress_rush.pressed.connect(request_rush)
	_progress.add_child(_progress_rush)


func _bind_progress(body: Control) -> void:
	_progress = body.get_node_or_null("Progress") as VBoxContainer
	if _progress == null:
		return
	_progress_title = _progress.get_node_or_null("Title") as Label
	_progress_bar = _progress.get_node_or_null("Clock/Bar") as MeterBar
	_progress_percent = _progress.get_node_or_null("Clock/Percent") as Label
	_progress_eta = _progress.get_node_or_null("Eta") as Label
	_progress_crew = _progress.get_node_or_null("Crew") as Label
	_progress_rush = _progress.get_node_or_null("Rush") as Button


# ---------------------------------------------------------------------------
# Binding
# ---------------------------------------------------------------------------

## Hands this panel S16's model — the SAME instance the queue panel holds, so
## the two can never publish different numbers for the same project. Unbound is
## the shipped default and it simply hides the block.
func bind_construction(model: ConstructionQueueModel) -> void:
	construction = model
	refresh()


func is_open() -> bool:
	return _panel != null and _panel.visible


func selected_id() -> String:
	return _sim_id


## Tap a building → this. An unknown id closes the panel rather than showing a
## stale one (§2.2: the panel exits on "tap map").
func show_building(sim_id: String) -> void:
	if controller == null:
		return
	if sim_id != _sim_id:
		# A new selection disarms both two-tap confirms. Two buildings can share
		# a transformer, so an armed REMOVE row that survived the selection would
		# take a street's lights out on what the player read as a first tap.
		_power_fix_armed = ""
		_power_remove_armed = ""
	var view := controller.building_view(sim_id)
	if not bool(view.get("exists", false)):
		close()
		return
	# `PanelLayer` shows one surface at a time (D-16). S4 landed beside this
	# panel on the same layer and the same right edge, so opening either one has
	# to put the other away — two 300 dp panels sharing an edge do not occlude,
	# they collide, and their tap targets collide with them.
	UIWidgets.close_siblings(self)
	_sim_id = sim_id
	_view = view
	if _panel != null:
		_panel.visible = true
	_render(view)


## Re-reads the sim for the currently selected building (after an upgrade, a
## tick, or a construction completion).
func refresh() -> void:
	if _sim_id != "" and is_open():
		show_building(_sim_id)


func close() -> void:
	if _panel != null:
		_panel.visible = false
	_sim_id = ""
	_view = {}
	closed.emit()


func view() -> Dictionary:
	return _view


## The right-edge column, solved against the display it is on — see
## `UIWidgets.side_panel_width`. A checklist row is a whole sentence, so this
## panel is the one most likely to want the full width of a phone.
func _apply_panel_width() -> void:
	if _panel == null or size.x <= 1.0:
		return
	var layout := config.layout()
	var width := UIWidgets.side_panel_width(size.x,
			_panel.get_combined_minimum_size().x,
			UIConfig.get_num(layout, "drawer_w_ratio", 0.34),
			UIConfig.get_num(layout, "side_panel_w_dp", 300.0),
			UIConfig.get_num(layout, "drawer_w_max_dp", 340.0),
			_touch_min)
	_panel.offset_left = -width


func _render(v: Dictionary) -> void:
	_apply_panel_width()
	if _title != null:
		_title.text = _text(str(v["name_key"]), str(v["name_fallback"]))
		_title.tooltip_text = _title.text
		# See `AlertsCenter`: the scene's `clip_text` alone would let the ✕ beside
		# it claim the whole header.
		UIWidgets.elide(_title, _touch_min * 2.0)
	if _level != null:
		_level.text = "%s  %s" % [BuildingPanel.level_pips(int(v["level"]),
				int(v["max_level"])), _text(str(v["state_key"]), String(v["state"]))]
	_render_progress()
	_render_vitals(v)
	_render_coverage(v)
	_render_upgrade(v)
	_render_actions(v)
	_render_water(v.get("water", {}))
	_render_power(v.get("power", {}))


## The queue's row for THIS building, or nothing at all.
##
## The lookup is by `ref` — the contract's own field, which is the queue's
## `target_ref` — and a building whose project the seam does not name simply has
## no block. That is the whole failure mode: no crash, no empty bar, no `0:00`.
func _render_progress() -> void:
	if _progress == null:
		return
	_progress_job = -1
	var row: Dictionary = construction.row_for_ref(_sim_id) if construction != null \
			and _sim_id != "" else {}
	_progress.visible = not row.is_empty()
	if row.is_empty():
		return
	_progress_job = int(row["job_id"])
	var kind := str(row["source_label"])
	if str(row["level_text"]) != "":
		kind = "%s · %s" % [kind, str(row["level_text"])]
	_progress_title.text = kind
	# A5: the stalled bar is hatched as well as amber — §2.6's held-clock channel,
	# and the ETA sentence beside it says the same thing in words (A14).
	_progress_bar.set_value(float(row["progress01"]), row["state"],
			not bool(row["working"]))
	_progress_percent.text = str(row["percent_text"])
	_apply_state_color(_progress_percent, row["state"])
	_progress_eta.text = str(row["eta_text"])
	_apply_state_color(_progress_eta, row["state"])
	_progress_crew.text = str(row["crew_text"])
	_progress_rush.visible = bool(row["rushable"])
	_progress_rush.text = str(row["rush_text"])
	_progress_rush.tooltip_text = str(row["rush_tooltip"])
	_progress_rush.disabled = not bool(row["affordable"])


## One tap, with the price on the face (§2.22's ruling). The door answers; the
## panel re-reads rather than predicting, and the toast, the chip pulse and the
## cue all arrive from the bus like every other rush.
func request_rush() -> void:
	if construction == null or _progress_job < 0:
		return
	var job := _progress_job
	var result := construction.rush(job)
	rushed.emit(_sim_id, job, result)
	construction.refresh()
	refresh()


## `L1 L2 ▮L3▮ L4 L5` (§2.9), the doc's row verbatim: only the current level is
## bracketed, and the digits carry the meaning so the row survives grayscale.
static func level_pips(level: int, max_level: int) -> String:
	var parts: PackedStringArray = []
	for i in range(1, maxi(max_level, 1) + 1):
		parts.append("%sL%d%s" % [PIP_ON, i, PIP_ON] if i == level else "L%d" % i)
	return " ".join(parts)


func _render_vitals(v: Dictionary) -> void:
	if _vitals == null:
		return
	BuildingPanel._clear_children(_vitals)
	for entry: Variant in (v["vitals"] as Array):
		var vital: Dictionary = entry
		var label := Label.new()
		label.name = "Label_" + str(vital["id"])
		label.text = _text(str(vital["label_key"]), str(vital["id"]).capitalize())
		_vitals.add_child(label)
		var value := Label.new()
		value.name = "Value_" + str(vital["id"])
		value.text = str(vital["value"])
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_vitals.add_child(value)


## Four 40 dp tiles (§2.9 item 4). Each carries the §2.5 state glyph as well as
## the colour, so the row survives grayscale (A5).
func _render_coverage(v: Dictionary) -> void:
	if _coverage == null:
		return
	BuildingPanel._clear_children(_coverage)
	var model := HudModel.new(config)
	for entry: Variant in (v["coverage"] as Array):
		var tile: Dictionary = entry
		var label := Label.new()
		label.name = "Coverage_" + str(tile["id"])
		var state: StringName = tile["state"]
		label.text = "%s %s %s" % [_text(str(tile["label_key"]), str(tile["id"]).capitalize()),
				model.state_glyph(state), str(tile["value"])]
		label.tooltip_text = str(tile.get("attachment", ""))
		_apply_state_color(label, state)
		_coverage.add_child(label)


func _render_upgrade(v: Dictionary) -> void:
	var upgrade: Dictionary = v["upgrade"]
	if _upgrade_header != null:
		if bool(upgrade["available"]):
			_upgrade_header.text = _text_args("ui_building_upgrade_to",
					{"level": int(upgrade["to_level"])},
					"Level %d" % int(upgrade["to_level"]))
		else:
			_upgrade_header.text = _text("ui_building_upgrade_unavailable", "")
	if _upgrade_note != null:
		_upgrade_note.text = _upgrade_note_text(upgrade)
	if _checklist != null:
		BuildingPanel._clear_children(_checklist)
		for entry: Variant in (upgrade["checklist"] as Array):
			_checklist.add_child(_build_check_row(entry))
	if _upgrade_button != null:
		# §2.9: disabled while any ✗ remains.
		_upgrade_button.disabled = not (bool(upgrade["available"]) and bool(upgrade["ok"]))
		_upgrade_button.tooltip_text = _upgrade_button.text


func _upgrade_note_text(upgrade: Dictionary) -> String:
	if not bool(upgrade["available"]):
		return _text("ui_building_upgrade_unavailable", "")
	var blocker: Dictionary = upgrade["blocked_by"]
	if not blocker.is_empty():
		return _text_args("ui_building_upgrade_blocked",
				{"first": str(blocker["title"])}, str(blocker["title"]))
	return "%s  %s" % [
		_text_args("ui_building_upgrade_cost", {"cost": str(upgrade["cost_text"])},
				str(upgrade["cost_text"])),
		_text("ui_building_upgrade_ready", ""),
	]


## One checklist line: `✓`/`✗` + the formatter's sentence + `Fix this →` when the
## blocker has a navigable target (§2.7).
func _build_check_row(entry: Variant) -> HBoxContainer:
	var row_data: Dictionary = entry
	var row := HBoxContainer.new()
	row.name = "Check_" + str(row_data["canonical"])
	row.add_theme_constant_override(&"separation", int(_spacing))

	var glyph := Label.new()
	glyph.name = "Glyph"
	glyph.text = str(row_data["glyph"])
	_apply_state_color(glyph, StringName(str(row_data["state"])))
	row.add_child(glyph)

	var body := Label.new()
	body.name = "Body"
	# `text` is the checklist voice: the requirement's name when it passes, the
	# whole formatter sentence when it does not.
	body.text = str(row_data.get("text", row_data["body"]))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(body)

	var fix: Dictionary = row_data["fix_target"]
	if not bool(row_data.get("ok", true)) \
			and str(fix["kind"]) != String(RequirementFormatter.FIX_NONE):
		var button := Button.new()
		button.name = "Fix"
		button.theme_type_variation = &"GhostButton"
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(_touch_min * 2.0, _touch_min)
		button.text = _text("ui_building_fix_this", "")
		button.tooltip_text = "%s %s" % [button.text, str(row_data["title"])]
		button.pressed.connect(_on_fix_pressed.bind(fix))
		row.add_child(button)
	return row


# ---------------------------------------------------------------------------
# §2.9 item 6 — the actions row
# ---------------------------------------------------------------------------

## `Repair` · `Priority` · `Demolish`. Every value comes from
## `BuildController.actions_view()`, which asks the three commands themselves
## with `preview = true`; this method decides only what is on screen.
func _render_actions(v: Dictionary) -> void:
	if _actions == null:
		return
	var actions: Dictionary = v.get("actions", {})
	_render_repair(actions.get("repair", {}))
	_render_priority(actions.get("priority", {}))
	_render_demolish(actions.get("demolish", {}))


## The repair affordance. It is **only drawn when there is something to buy** —
## doc 02 §2.6 refuses `E_NOT_DAMAGED` at condition 1.00 — and when it is drawn
## it always names the price and where the condition will land, because "repair"
## with no number is a button, not a decision.
func _render_repair(repair: Dictionary) -> void:
	if _repair_button == null or _repair_note == null:
		return
	var available := bool(repair.get("available", false))
	_repair_button.visible = available
	_repair_note.visible = available
	if not available:
		return
	_repair_button.text = _text_args("ui_building_repair_cost",
			{"cost": str(repair["cost_text"])}, _text("ui_building_repair", "REPAIR"))
	_repair_button.tooltip_text = _repair_button.text
	_repair_button.disabled = not bool(repair["ok"])
	var reason: Dictionary = repair.get("reason", {})
	if not reason.is_empty():
		_repair_note.text = str(reason["body"])
		_apply_state_color(_repair_note, StringName(str(reason["state"])))
		_repair_note.tooltip_text = _repair_note.text
		return
	# `85 % → 100 %`: the condition it is at and the condition doc 02 §2.12's
	# repair target will actually restore it to, which is 0.85 and not 1.00 once
	# a building has been DAMAGED rather than merely worn.
	_repair_note.text = _text_args("ui_building_repair_note",
			{"from": str(repair["condition_text"]), "to": str(repair["target_text"])},
			"%s → %s" % [str(repair["condition_text"]), str(repair["target_text"])])
	_repair_note.tooltip_text = _repair_note.text
	_apply_state_color(_repair_note, &"")


## Doc 04 §2.4's shed tier, as a segmented row — one 48 dp target per class, the
## live one painted the way every other "this one is selected" control in the
## deck is (`BuildSheet.select_category`, the drawer's sort segments).
func _render_priority(priority: Dictionary) -> void:
	if _priority_row == null or _priority_note == null:
		return
	var available := bool(priority.get("available", false))
	_priority_row.visible = available
	_priority_note.visible = available
	if not available:
		BuildingPanel._clear_children(_priority_row)
		_priority_buttons.clear()
		return
	_priority_note.text = _text("ui_building_priority_title", "")
	_priority_note.tooltip_text = _priority_note.text
	var classes: Array = priority.get("classes", [])
	var current := str(priority.get("current", ""))
	if _priority_buttons.size() != classes.size():
		BuildingPanel._clear_children(_priority_row)
		_priority_buttons.clear()
		for entry: Variant in classes:
			var priority_class := str(entry)
			var label := _text(BuildController.priority_key(priority_class),
					priority_class.capitalize())
			var button := UIWidgets.button("Priority_" + priority_class, label, label,
					Vector2(_touch_min, _touch_min), &"TabButton")
			button.toggle_mode = true
			button.pressed.connect(_on_priority_pressed.bind(priority_class))
			_priority_row.add_child(button)
			_priority_buttons[priority_class] = button
	for id: Variant in _priority_buttons:
		var button: Button = _priority_buttons[id]
		var selected := str(id) == current
		button.set_pressed_no_signal(selected)
		UIWidgets.paint_state(self, button, HudModel.STATE_NORMAL if selected else &"")


## §2.9 item 6's hold-to-confirm. The refund is quoted before the hold starts,
## broken out into what the standing capital returns and what the construction
## queue gives back on a job it is cancelling — those are two different pieces of
## news and a player about to lose a half-built tower should read both.
func _render_demolish(demolish: Dictionary) -> void:
	if _demolish_button == null or _demolish_note == null:
		return
	var available := bool(demolish.get("available", false))
	_demolish_button.visible = available
	_demolish_note.visible = available
	if not available:
		return
	_demolish_button.disabled = not bool(demolish["ok"])
	_demolish_button.text = _text("ui_building_demolish", "DEMOLISH")
	_demolish_button.tooltip_text = _text("ui_building_demolish_hint", "Hold to confirm")
	var reason: Dictionary = demolish.get("reason", {})
	if not reason.is_empty():
		_demolish_note.text = str(reason["body"])
		_apply_state_color(_demolish_note, StringName(str(reason["state"])))
		_demolish_note.tooltip_text = _demolish_note.text
		return
	var key := "ui_building_demolish_note_jobs" if int(demolish["cancelled_jobs"]) > 0 \
			else "ui_building_demolish_note"
	_demolish_note.text = _text_args(key, {"refund": str(demolish["refund_text"]),
			"jobs": int(demolish["cancelled_jobs"])}, str(demolish["refund_text"]))
	_demolish_note.tooltip_text = _demolish_note.text
	_apply_state_color(_demolish_note, &"")


## Doc 05 §6's node ladder, one row per node the shell hosts (doc 93 §J1). Drawn
## only for a building that hosts one — every other panel in the city is exactly
## as it was — and each row is a level strip, a capacity line and one button that
## quotes its own price. `WaterActions` computed every value from the verb's own
## `preview = true`; this method decides only what is on screen.
func _render_water(block: Dictionary) -> void:
	if _water == null:
		return
	var available := bool(block.get("available", false))
	_water.visible = available
	BuildingPanel._clear_children(_water)
	_water_rows.clear()
	if not available:
		return
	var header := UIWidgets.label("WaterHeader",
			_text("ui_water_nodes_title", ""))
	_water.add_child(header)
	for entry: Variant in (block.get("nodes", []) as Array):
		_water.add_child(_build_water_row(entry))


## One node: the level strip, what it draws and what state it is in, and — when
## there is a rung left — a button that names its own price with the whole gate
## under it.
func _build_water_row(entry: Variant) -> VBoxContainer:
	var node: Dictionary = entry
	var node_id := str(node["node"])
	var row := VBoxContainer.new()
	row.name = "WaterNode_" + node_id
	row.add_theme_constant_override(&"separation", int(_spacing))

	# The same `L1 L2 ▮L3▮` strip the shell's header uses, so a node's level and a
	# building's level are read the same way (A5: the digits carry it).
	var title := UIWidgets.label("Title", "%s  %s" % [
			_text(str(node["name_key"]), str(node["name_fallback"])),
			BuildingPanel.level_pips(int(node["level"]), int(node["max_level"]))])
	title.tooltip_text = node_id
	row.add_child(title)

	var micro := UIWidgets.label("Micro", _text_args("ui_water_node_micro",
			{"kw": RequirementFormatter.power(node["kw"]),
			"state": _text(str(node["state_key"]), str(node["state"]))},
			RequirementFormatter.power(node["kw"])), &"LegendRow", true)
	row.add_child(micro)

	var upgrade: Dictionary = node["upgrade"]
	if not bool(node.get("upgradeable", false)):
		# A junction: doc 05 §2.1 makes it a place where mains meet, not a
		# component, so it has no ladder — the row says so rather than showing a
		# button that can only ever refuse.
		row.add_child(UIWidgets.label("Note",
				_text("ui_water_node_not_upgradeable", ""), &"LegendRow", true))
		return row
	if not bool(upgrade["available"]):
		row.add_child(UIWidgets.label("Note",
				_text("ui_water_node_max_level", ""), &"LegendRow", true))
		return row

	var label := _text_args("ui_water_node_upgrade",
			{"cost": str(upgrade["cost_text"]), "level": int(upgrade["to_level"])},
			str(upgrade["cost_text"]))
	var button := UIWidgets.button("Upgrade_" + node_id, label, label,
			Vector2(_touch_min * 2.0, _touch_min), &"GhostButton")
	button.disabled = not bool(upgrade["ok"])
	button.pressed.connect(_on_water_upgrade_pressed.bind(node_id))
	row.add_child(button)
	_water_rows[node_id] = button

	# The whole gate, not just the first no — the same contract §2.9 item 5 makes
	# for the shell's checklist one block up.
	for check: Variant in (upgrade["checklist"] as Array):
		row.add_child(_build_check_row(check))
	return row


# --- Wave 17: doc 12 §2.9 D-70's POWER section -----------------------------
#
# What the user asked for in the two sentences that opened this wave: "feeders
# adding extra power to a building is not clear and I'm not sure it actually
# works", and "how the transformers feed power … doesn't seem to be working well
# at all". Both were true readings of a panel that never named the wire.
#
# The section is a LIST OF HOPS, nearest first — the transformer that feeds this
# building, the feeder that feeds it, the substation behind that — each with what
# it carries now, what it carries at the day's peak, how much is spare **in
# words**, and its own UPGRADE button with the price on its face. Under them: the
# next level's headroom answer, and the one-tap fix when the next level is
# blocked. Every value is `PowerActions`'; this method decides only what is on
# screen.

func _render_power(block: Dictionary) -> void:
	if _power == null:
		return
	var available := bool(block.get("available", false))
	_power.visible = available
	BuildingPanel._clear_children(_power)
	_power_rows.clear()
	_power_remove_rows.clear()
	_power_fix_button = null
	if not available:
		_power_fix_armed = ""
		_power_remove_armed = ""
		return
	_power.add_child(UIWidgets.label("PowerHeader", _text("ui_power_section_title", "")))
	if bool(block.get("unserved", false)):
		# No transformer at all. The most important line the section can draw,
		# and the only one that is drawn alone.
		var none := UIWidgets.label("Unserved",
				_text("ui_power_unserved", ""), &"LegendRow", true)
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_apply_state_color(none, HudModel.STATE_CRITICAL)
		_power.add_child(none)
		return
	var summary := UIWidgets.label("Draw", _text_args("ui_power_draw",
			{"kw": str(block["demand_text"]), "hops": int(block["hops"])},
			str(block["demand_text"])), &"LegendRow", true)
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_power.add_child(summary)
	if bool(block.get("shed", false)):
		var shed := UIWidgets.label("Shed", _text("ui_power_shed", ""), &"LegendRow", true)
		_apply_state_color(shed, HudModel.STATE_CRITICAL)
		_power.add_child(shed)
	for entry: Variant in (block.get("rows", []) as Array):
		_power.add_child(_build_power_hop(entry))
	var next: Dictionary = block.get("next_level", {})
	if bool(next.get("available", false)):
		var headroom := UIWidgets.label("NextLevel", _text_args(
				"ui_power_next_level_ok" if bool(next["ok"]) else "ui_power_next_level_short",
				{"level": int(next["to_level"]), "kw": str(next["delta_text"]),
				"short": str(next["deficit_text"]), "at": str(next["binds_at"])},
				str(next["delta_text"])), &"LegendRow", true)
		headroom.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_apply_state_color(headroom, HudModel.STATE_NORMAL if bool(next["ok"])
				else HudModel.STATE_WARNING)
		_power.add_child(headroom)
	_render_power_fix(block.get("fix", {}), str(block.get("sim_id", "")))


## One hop: what it is, what it carries, what is spare, and the purchase that
## makes it bigger. The button's face carries its price even when it is
## DISABLED — a button that hides its price while the player is broke teaches
## nothing about how much to save (doc 12 §2.7).
func _build_power_hop(entry: Variant) -> VBoxContainer:
	var hop: Dictionary = entry
	var component_id := str(hop["id"])
	var row := VBoxContainer.new()
	row.name = "PowerHop_" + component_id
	row.add_theme_constant_override(&"separation", int(_spacing))

	var title := UIWidgets.label("Title", _text_args("ui_power_hop",
			{"kind": _text(str(hop["name_key"]), str(hop["kind"])),
			"id": component_id, "customers": int(hop["customers"])},
			component_id))
	title.tooltip_text = component_id
	row.add_child(title)

	# The reading, in the order a player asks for it: what is spare, then the
	# two numbers that spare came from. The BAND word is what makes it readable
	# without the colour (A5).
	var load := UIWidgets.label("Load", _text_args("ui_power_hop_load",
			{"headroom": str(hop["headroom_text"]), "load": str(hop["load_text"]),
			"peak": str(hop["peak_text"]), "capacity": str(hop["capacity_text"]),
			"band": _text(str(hop["band_key"]), "")},
			"%s / %s" % [hop["peak_text"], hop["capacity_text"]]), &"LegendRow", true)
	load.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_apply_state_color(load, StringName(str(hop["band_state"])))
	row.add_child(load)

	var upgrade: Dictionary = hop.get("upgrade", {})
	if not bool(upgrade.get("available", false)):
		return row
	var label := _text_args("ui_power_upgrade",
			{"cost": str(upgrade["cost_text"]), "capacity": str(upgrade["to_capacity_text"])},
			str(upgrade["cost_text"]))
	var button := UIWidgets.button("Upgrade_" + component_id, label, label,
			Vector2(_touch_min * 2.0, _touch_min), &"GhostButton")
	button.disabled = not bool(upgrade["ok"])
	button.pressed.connect(_on_power_upgrade_pressed.bind(component_id))
	row.add_child(button)
	_power_rows[component_id] = button
	for check: Variant in (upgrade.get("checklist", []) as Array):
		row.add_child(_build_check_row(check))
	_add_power_remove(row, hop)
	return row


## The transformer's own removal, and therefore its MOVE — the verb the user
## asked for by name (*"the transformer should be able to be destroyed and moved
## — if we remove it the power goes out and we hurry to reconnect"*). It lives on
## the hop row because a transformer is not a thing the world pick can select; the
## building it feeds is the only door there is.
##
## **Two taps, and the second one names the casualties.** The first arms the row
## and re-labels it with how many buildings go dark and what the move back would
## cost (`replace_cost − refund`); the second calls the verb. Same shape as the
## fix strip, and the same reason as §2.9 item 6's hold-to-confirm on the
## building demolition: this is the other button in the deck that cannot be
## undone, and a mis-tap on it takes a street's lights out.
func _add_power_remove(row: VBoxContainer, hop: Dictionary) -> void:
	if String(hop["kind"]) != "transformer" or controller == null:
		return
	var component_id := str(hop["id"])
	var quote := controller.power.demolish_quote(component_id)
	if not bool(quote.get("available", false)):
		return
	var armed := _power_remove_armed == component_id
	var label := _text_args("ui_power_remove_confirm" if armed else "ui_power_remove",
			{"refund": str(quote["refund_text"]), "dark": int(quote["stranded"]),
			"move": str(quote["move_cost_text"])}, str(quote["refund_text"]))
	var button := UIWidgets.button("Remove_" + component_id, label, label,
			Vector2(_touch_min * 2.0, _touch_min), &"DangerButton")
	button.pressed.connect(_on_power_remove_pressed.bind(component_id))
	row.add_child(button)
	_power_remove_rows[component_id] = button


func _on_power_remove_pressed(component_id: String) -> void:
	if controller == null:
		return
	if _power_remove_armed != component_id:
		_power_remove_armed = component_id
		call_deferred("refresh")
		return
	_power_remove_armed = ""
	var result := controller.power.demolish(component_id)
	call_deferred("refresh")
	grid_demolished.emit(component_id, result)


## The `REMOVE` button of one hop, for a test that has to press one.
func power_remove_button(component_id: String) -> Button:
	return _power_remove_rows.get(component_id, null)


## The `Fix this →` strip: what one tap would buy, what it costs, and whether it
## clears the blocker. Two taps, never one — the first arms the strip and the
## second spends the money (doc 12 §2.7).
func _render_power_fix(fix: Dictionary, sim_id: String) -> void:
	if not bool(fix.get("available", false)):
		_power_fix_armed = ""
		return
	var armed := _power_fix_armed == sim_id and sim_id != ""
	var cost := str(fix.get("cost_text", ""))
	var label := _text_args("ui_power_fix_confirm" if armed else "ui_power_fix",
			{"cost": cost,
			"action": _text(str(fix.get("action_key", "")), str(fix.get("action", ""))),
			"component": str(fix.get("component", ""))}, cost)
	_power_fix_button = UIWidgets.button("PowerFix", label, label,
			Vector2(_touch_min * 2.0, _touch_min), &"GhostButton")
	_power_fix_button.disabled = not bool(fix.get("ok", false))
	_power_fix_button.pressed.connect(_on_power_fix_pressed.bind(sim_id))
	_power.add_child(_power_fix_button)
	var note := UIWidgets.label("PowerFixNote", _text_args("ui_power_fix_note",
			{"at": str(fix.get("binds_at", "")),
			"kind": _text("ui_power_kind_%s" % str(fix.get("binds_kind", "")),
					str(fix.get("binds_kind", "")))}, ""), &"LegendRow", true)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_power.add_child(note)
	if not bool(fix.get("clears", true)) and bool(fix.get("ok", false)):
		# Honest about a partial fix: one purchase per tap is a rule, and a strip
		# that implied otherwise would be selling a plan as a button.
		var partial := UIWidgets.label("PowerFixPartial",
				_text("ui_power_fix_partial", ""), &"LegendRow", true)
		partial.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_apply_state_color(partial, HudModel.STATE_WARNING)
		_power.add_child(partial)
	for check: Variant in (fix.get("checklist", []) as Array):
		_power.add_child(_build_check_row(check))


## The panel's own `Fix this →` button lives on the checklist row and routes
## through `_on_fix_pressed`; this is the strip's button. Both land here.
func _on_power_fix_pressed(sim_id: String) -> void:
	if controller == null or sim_id == "":
		return
	if _power_fix_armed != sim_id:
		_power_fix_armed = sim_id
		call_deferred("refresh")
		return
	_power_fix_armed = ""
	var result := controller.power.fix(sim_id)
	# Deferred for `_on_fix_pressed`'s reason: the button that fired this is
	# inside the section a refresh rebuilds.
	call_deferred("refresh")
	power_fixed.emit(sim_id, result)


func _on_power_upgrade_pressed(component_id: String) -> void:
	if controller == null:
		return
	var result := controller.power.upgrade(component_id)
	call_deferred("refresh")
	grid_upgraded.emit(component_id, result)


## The `UPGRADE` button of one hop, for a test or a coach mark that has to point
## at one — the power twin of `water_upgrade_button()`.
func power_upgrade_button(component_id: String) -> Button:
	return _power_rows.get(component_id, null)


func power_fix_button() -> Button:
	return _power_fix_button


func _on_water_upgrade_pressed(node_id: String) -> void:
	if controller == null:
		return
	var result := controller.upgrade_water_node(node_id)
	# Deferred for `_on_fix_pressed`'s reason: the button that fired this lives
	# inside the block a refresh rebuilds, and freeing an emitter while its own
	# signal is being emitted is a crash, not a redraw.
	call_deferred("refresh")
	water_upgraded.emit(node_id, result)


func _on_demolish_down() -> void:
	if _demolish_button == null or _demolish_button.disabled:
		return
	_hold_elapsed = 0.0
	set_process(true)


func _on_demolish_up() -> void:
	if _hold_elapsed >= 0.0:
		# Released early: the hold is abandoned and the label goes back to the
		# word. A partial hold demolishes nothing and says nothing.
		_hold_elapsed = -1.0
		_render_demolish((_view.get("actions", {}) as Dictionary).get("demolish", {}))
	set_process(false)


## Counts the hold out and fires once. Runs only while a finger is down, which is
## why `set_process` is toggled rather than left on — a panel that is not being
## held has nothing to advance.
func _process(delta: float) -> void:
	if _hold_elapsed < 0.0 or _demolish_button == null:
		set_process(false)
		return
	_hold_elapsed += delta * 1000.0
	var fraction := clampf(_hold_elapsed / _hold_ms, 0.0, 1.0)
	if fraction < 1.0:
		# The button counts itself down, so the hold is visible on the control
		# being held rather than somewhere else on the panel (A5: the progress is
		# in the label, not only in a colour).
		_demolish_button.text = _text_args("ui_building_demolish_holding",
				{"percent": HudModel.percent_text(fraction * 100.0)},
				_text("ui_building_demolish", "DEMOLISH"))
		return
	_hold_elapsed = -1.0
	set_process(false)
	request_demolish()


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

## The real command (doc 12 §4.4) — the UI never predicts success, it refreshes
## from whatever the sim answers.
func request_upgrade() -> void:
	if controller == null or _sim_id == "":
		return
	var result := controller.upgrade(_sim_id)
	refresh()
	upgraded.emit(result)


func request_repair() -> void:
	if controller == null or _sim_id == "":
		return
	var result := controller.repair(_sim_id)
	refresh()
	repaired.emit(result)


func _on_priority_pressed(priority_class: String) -> void:
	if controller == null or _sim_id == "":
		return
	var result := controller.set_priority(_sim_id, priority_class)
	refresh()
	priority_set.emit(result)


## The hold landed. The panel CLOSES on success, because the thing it was
## describing is gone and a stale panel over an empty lot is worse than no panel.
func request_demolish() -> void:
	if controller == null or _sim_id == "":
		return
	var target := _sim_id
	var result := controller.demolish(target)
	if bool(result["ok"]):
		close()
	else:
		refresh()
	demolished.emit(target, result)


## `Fix this →`. `E_CONDITION` is answered HERE rather than by the shell: its fix
## target is the building the player already has open, so focusing the camera on
## it — which is all the shell can do — moves nothing. The row's remedy is a
## repair, so the row buys one.
func _on_fix_pressed(fix_target: Dictionary) -> void:
	if StringName(str(fix_target.get("kind", ""))) == RequirementFormatter.FIX_POWER:
		# Same reason `E_CONDITION` is answered here: the fix target is the
		# building the player already has open, so the only thing the shell could
		# do with it — focus the camera — moves nothing (A91-D-54). The row arms
		# the confirm strip in the POWER section below; the strip spends.
		_power_fix_armed = _sim_id
		call_deferred("refresh")
		return
	if StringName(str(fix_target.get("kind", ""))) == RequirementFormatter.FIX_REPAIR:
		if controller == null or _sim_id == "":
			return
		# **Not `request_repair()`.** The button that fired this lives INSIDE the
		# checklist, and a refresh rebuilds the checklist — which frees the
		# emitter while its own signal is still being emitted ("Object was freed
		# or unreferenced while a signal is being emitted from it"). The command
		# runs now, because that is what the player asked for; the re-render
		# waits for the frame to finish.
		var result := controller.repair(_sim_id)
		call_deferred("refresh")
		repaired.emit(result)
		return
	fix_requested.emit(fix_target)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func upgrade_button() -> Button:
	return _upgrade_button


## The `UPGRADE` button of one doc-05 node's row, or null — the water twin of
## `upgrade_button()` above, for a test or a coach mark that has to point at one.
func water_upgrade_button(node_id: String) -> Button:
	return _water_rows.get(node_id, null)


func checklist_rows() -> Array[Node]:
	return _checklist.get_children() if _checklist != null else ([] as Array[Node])


func _text(key: String, fallback: String) -> String:
	if config != null and config.has_string(key):
		return config.t(key)
	return fallback


func _text_args(key: String, args: Dictionary, fallback: String) -> String:
	if config != null and config.has_string(key):
		return config.t(key, args)
	return fallback


func _apply_state_color(control: Control, state: StringName) -> void:
	if state == &"" or not has_theme_color(state, PALETTE_TYPE):
		control.remove_theme_color_override(&"font_color")
		return
	control.add_theme_color_override(&"font_color", get_theme_color(state, PALETTE_TYPE))
