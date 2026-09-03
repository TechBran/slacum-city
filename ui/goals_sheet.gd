class_name GoalsSheet
extends Control
## S14 (doc 12 §2.19) — the goals sheet: what this city level wants, how far
## along each objective is, what the next level pays out, and what comes after.
##
## A full-screen modal on `ModalLayer`, same shape as S9: the scrim is the only
## `STOP` control while it is up, and Android BACK closes it first (§2.2).
##
## The whole screen is built in code from `GoalsModel`'s plain data, and it holds
## no copy, no threshold and no number of its own — it is the settings sheet's
## contract applied to a screen that has to look like a game rather than a
## preferences list. What it adds over that pattern is HIERARCHY, because this is
## the surface a player opens most after the HUD:
##
##     LEVEL 3  ─ the badge, the one number the eye lands on
##     The budget                      ─ the level's name, display type
##     Every building you own costs…   ─ one sentence of intent, muted
##     ▓▓▓▓▓▓░░░░  2 of 4 done         ─ the level bar
##     ─────────────────────────────
##     ✓  Build an apartment block
##     ○  Set the tax rate                          0/1
##     ○  Hold happiness at 70              ▓▓▓░  66/70
##     ─────────────────────────────
##     Or grow to 1,600 residents      ─ the ladder underneath, greyed
##     REACHING LEVEL 4 UNLOCKS        ─ the reward, in its own card
##       High-rise · Upgrades to level 4 · 6 blocks of land
##     Then: When it goes wrong        ─ the next level, named
##     ⓿ ➊ ➋ ➌ ● ○                    ─ the strip: where you are on the arc

signal sheet_toggled(open: bool)
## Wave 19's commissions band (doc 12 §2.19 D-90). Both carry the sim's own
## `{ok, reason_code, payload}` so the shell re-reads the city rather than
## predicting what a commission moved — the same contract S5's verbs use.
signal contract_accepted(result: Dictionary)
signal contract_claimed(result: Dictionary)

const SCRIM_ALPHA := 0.55
## The level bar and the per-objective bars. Both are `MeterBar`, which is the
## only bar in this project that can take a state colour without a per-node
## stylebox (doc 12 §4.3).
const LEVEL_BAR_H_DP := 10.0
const ROW_BAR_H_DP := 4.0
const ROW_BAR_W_DP := 56.0
## The tick and the empty circle. A5: the state is never colour alone.
const MARK_DONE := "✓"
const MARK_TODO := "○"

var config: UIConfig
var model: GoalsModel

var _scrim: ColorRect
var _panel: PanelContainer
var _title: Label
var _close: Button
var _body: VBoxContainer

var _level_badge: Label
## "You are Level 2 — completing these reaches Level 3." The one line that
## keeps the badge honest: the badge names the TARGET level, and a playtest
## (2026-08-21) showed a player reading it as the level they HELD, then filing
## the build sheet's correct Level-3 gate as a bug.
var _level_standing: Label
var _level_name: Label
var _level_intent: Label
var _level_teaches: Label
var _level_bar: MeterBar
var _level_count: Label
var _rows_box: VBoxContainer
var _backstop: Label
var _reward_card: PanelContainer
var _reward_title: Label
var _reward_lines: VBoxContainer
var _next_line: Label
var _ladder_box: HBoxContainer

var _row_nodes: Dictionary = {}   # objective id -> {mark, text, counter, bar}
## Wave 19's commissions band (doc 12 §2.19 D-90), built in code above the level
## card. It is the FIRST thing on the sheet because it is the only thing on it
## with a clock: a curriculum objective waits, and a commission does not. It is
## drawn whenever the board exists — empty included — because a header nobody
## ever sees is a feature nobody can find.
var _contracts_box: VBoxContainer
var _contracts_title: Label
var _contracts_note: Label
var _contract_active: PanelContainer
var _contract_active_client: Label
var _contract_active_text: Label
var _contract_active_bar: MeterBar
var _contract_active_count: Label
var _contract_active_clock: Label
var _contract_claim: Button
var _contract_offers: VBoxContainer
var _offer_buttons: Dictionary = {}   # contract id -> Button
var _touch_min := 48.0
var _spacing := 8.0
## Objectives that have just completed and are still pulsing, id -> seconds left.
var _celebrating: Dictionary = {}
var _pulse_s := 1.2
var _reduce_motion := false


func setup(cfg: UIConfig = null, p_model: GoalsModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	if p_model != null:
		model = p_model
	var defaults := config.section("defaults")
	_reduce_motion = bool(defaults.get("reduce_motion", false))
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_pulse_s = UIConfig.get_num(config.layout(), "unlock_pulse_s", 1.2)
	_bind_nodes()
	_build_static()
	refresh()
	close()
	set_process(true)


func _ready() -> void:
	if config == null:
		setup(UIRoot.config_from(self))


func _bind_nodes() -> void:
	_scrim = get_node_or_null("Scrim") as ColorRect
	_panel = get_node_or_null("Panel") as PanelContainer
	_title = get_node_or_null("Panel/Body/Header/Title") as Label
	_close = get_node_or_null("Panel/Body/Header/Close") as Button
	_body = get_node_or_null("Panel/Body/Scroll/Content") as VBoxContainer


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build_static() -> void:
	if _scrim != null:
		_scrim.color = UIWidgets.scrim_color(self, SCRIM_ALPHA)
	if _title != null:
		_title.text = UIWidgets.t(config, "ui_goals_title", "Goals")
		UIWidgets.elide(_title, _touch_min * 2.0)
	if _close != null:
		_close.theme_type_variation = &"GhostButton"
		_close.focus_mode = Control.FOCUS_NONE
		_close.custom_minimum_size = Vector2(_touch_min, _touch_min)
		_close.text = "✕"
		_close.tooltip_text = UIWidgets.t(config, "ui_goals_close", "Close goals")
		if not _close.pressed.is_connected(close):
			_close.pressed.connect(close)
	if _body == null:
		return
	UIWidgets.clear_children(_body)
	_body.add_theme_constant_override(&"separation", int(_spacing))
	_body.add_child(_build_contracts())
	_body.add_child(_build_level_card())
	_body.add_child(_build_rows())
	_body.add_child(_build_reward_card())
	_next_line = UIWidgets.label("Next", "", &"LegendRow", true)
	_body.add_child(_next_line)
	_body.add_child(_build_ladder())


## **THE COMMISSIONS BAND** (Wave 19; doc 03 §2.5b, doc 12 §2.19 D-90,
## report 98 §60 RR-170):
##
##     COMMISSIONS
##     ┌────────────────────────────────────────┐
##     │ State reconstruction office            │
##     │ Bring three buildings back             │
##     │ ▓▓▓▓▓▓▓░░░  2 / 3          21h left    │
##     │ [           CLAIM · $15,600          ] │
##     └────────────────────────────────────────┘
##     Neighbourhood watch · 4 pickups · 12h  [ ACCEPT · $1,120 ]
##     Film unit · 6 street tiles · 18h       [ ACCEPT · $980   ]
##
## **It is above the level card**, and that ordering is the ruling: everything
## else on this sheet waits for the player, and a commission is the only thing in
## the game with a deadline the player can lose. The band is drawn whenever the
## board exists; when there is nothing on it the note says so in a sentence,
## because a header a player never sees teaches them the feature is not there.
func _build_contracts() -> Container:
	_contracts_box = VBoxContainer.new()
	_contracts_box.name = "Contracts"
	_contracts_box.add_theme_constant_override(&"separation", int(_spacing * 0.5))
	_contracts_title = UIWidgets.label("ContractsTitle",
			UIWidgets.t(config, "ui_contract_band_title", "COMMISSIONS"),
			&"SeverityBadge")
	_contracts_box.add_child(_contracts_title)

	_contract_active = PanelContainer.new()
	_contract_active.name = "Active"
	_contract_active.theme_type_variation = &"DrawerRow"
	var box := VBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override(&"separation", int(_spacing * 0.5))
	_contract_active.add_child(box)
	_contract_active_client = UIWidgets.label("Client", "", &"LegendRow", true)
	_contract_active_client.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_contract_active_client)
	_contract_active_text = UIWidgets.label("Text", "", &"", true)
	_contract_active_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_contract_active_text)

	var bar_row := HBoxContainer.new()
	bar_row.name = "BarRow"
	bar_row.add_theme_constant_override(&"separation", int(_spacing))
	_contract_active_bar = MeterBar.new()
	_contract_active_bar.name = "Bar"
	_contract_active_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_contract_active_bar.custom_minimum_size = Vector2(_touch_min, LEVEL_BAR_H_DP)
	bar_row.add_child(_contract_active_bar)
	_contract_active_count = UIWidgets.label("Count", "", &"LegendRow")
	bar_row.add_child(_contract_active_count)
	box.add_child(bar_row)

	_contract_active_clock = UIWidgets.label("Clock", "", &"LegendRow", true)
	_contract_active_clock.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_contract_active_clock)

	# The claim is the money, so it is the one primary control on this sheet.
	# It is DRAWN while the work is unfinished and DISABLED — the build-card
	# pattern (§2.7): the price a player is working toward belongs on the button
	# they are working toward, not only in the sentence above it.
	_contract_claim = UIWidgets.button("Claim",
			UIWidgets.t(config, "ui_contract_claim", "CLAIM"),
			UIWidgets.t(config, "ui_contract_claim", "CLAIM"),
			Vector2(_touch_min * 2.0, _touch_min), &"PrimaryFAB")
	_contract_claim.pressed.connect(request_claim_contract)
	box.add_child(_contract_claim)
	_contracts_box.add_child(_contract_active)

	_contract_offers = VBoxContainer.new()
	_contract_offers.name = "Offers"
	_contract_offers.add_theme_constant_override(&"separation", int(_spacing * 0.5))
	_contracts_box.add_child(_contract_offers)

	_contracts_note = UIWidgets.label("ContractsNote", "", &"LegendRow", true)
	_contracts_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_contracts_box.add_child(_contracts_note)
	return _contracts_box


## One offer: who is asking, what for, how long it runs, and the money on the
## button. `HFlowContainer` and not an HBox, because at 130 % text with larger
## targets the sentence and a 48 dp button do not fit on one 360 dp line and a
## wrap is the difference between a readable row and a clipped one (D-80's rule).
func _build_offer_row(offer: Dictionary) -> Container:
	var panel := PanelContainer.new()
	panel.name = "Offer_" + str(offer["id"])
	panel.theme_type_variation = &"DrawerRow"
	var flow := HFlowContainer.new()
	flow.name = "Line"
	flow.add_theme_constant_override(&"h_separation", int(_spacing))
	flow.add_theme_constant_override(&"v_separation", int(_spacing * 0.5))
	panel.add_child(flow)

	var text := UIWidgets.label("Text", "%s · %s" % [str(offer["client"]),
			str(offer["deadline_text"])], &"", true)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	flow.add_child(text)

	var button := UIWidgets.button("Accept",
			UIWidgets.t_args(config, "ui_contract_accept_reward",
					{"reward": str(offer["reward_text"])},
					UIWidgets.t(config, "ui_contract_accept", "ACCEPT")),
			UIWidgets.t(config, "ui_contract_accept", "ACCEPT"),
			Vector2(_touch_min * 2.0, _touch_min), &"GhostButton")
	button.disabled = not bool(offer["ok"])
	var contract_id := int(offer["id"])
	button.pressed.connect(func() -> void: request_accept_contract(contract_id))
	flow.add_child(button)
	_offer_buttons[contract_id] = button

	var reason: Dictionary = offer.get("reason", {})
	if not reason.is_empty():
		var note := UIWidgets.label("Reason", str(reason.get("body", "")),
				&"LegendRow", true)
		note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		flow.add_child(note)
	return panel


## The head of the screen: the badge, the name, one sentence, and the bar.
func _build_level_card() -> Container:
	var card := PanelContainer.new()
	card.name = "LevelCard"
	card.theme_type_variation = &"DrawerRow"
	var box := VBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override(&"separation", int(_spacing * 0.5))
	card.add_child(box)

	var head := HBoxContainer.new()
	head.name = "Head"
	head.add_theme_constant_override(&"separation", int(_spacing))
	_level_badge = UIWidgets.label("Badge", "", &"Wordmark")
	head.add_child(_level_badge)
	_level_name = UIWidgets.label("Name", "", &"SeverityBadge")
	_level_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_level_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(_level_name)
	box.add_child(head)

	# The standing line ("You are Level 2 — completing these reaches Level 3")
	# is a SENTENCE, so it gets its own row under the head, on `Intent`'s terms:
	# wrap on, EXPAND_FILL. It used to sit INSIDE the head HBox with wrap on and
	# no expand flag, and an HBox hands a non-expanding wrapping label its
	# minimum width — one glyph — so the 2026-09-01 audit found it laid out ONE
	# CHARACTER PER LINE, 1,101 px tall, with the objectives pushed 540 dp down
	# the sheet on every box (production audit, new-player lens, P0).
	_level_standing = UIWidgets.label("Standing", "", &"Caption", true)
	_level_standing.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_level_standing)

	_level_intent = UIWidgets.label("Intent", "", &"", true)
	_level_intent.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_level_intent)

	_level_teaches = UIWidgets.label("Teaches", "", &"LegendRow", true)
	_level_teaches.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_level_teaches)

	var bar_row := HBoxContainer.new()
	bar_row.name = "BarRow"
	bar_row.add_theme_constant_override(&"separation", int(_spacing))
	_level_bar = MeterBar.new()
	_level_bar.name = "Bar"
	_level_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_level_bar.custom_minimum_size = Vector2(_touch_min, LEVEL_BAR_H_DP)
	bar_row.add_child(_level_bar)
	_level_count = UIWidgets.label("Count", "", &"LegendRow")
	bar_row.add_child(_level_count)
	box.add_child(bar_row)
	return card


func _build_rows() -> Container:
	var box := VBoxContainer.new()
	box.name = "Objectives"
	box.add_theme_constant_override(&"separation", int(_spacing * 0.5))
	_rows_box = VBoxContainer.new()
	_rows_box.name = "Rows"
	_rows_box.add_theme_constant_override(&"separation", int(_spacing * 0.5))
	box.add_child(_rows_box)
	_backstop = UIWidgets.label("Backstop", "", &"LegendRow", true)
	_backstop.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_backstop)
	return box


## One objective. The mark carries the state without colour (A5), the sentence
## takes the width, and the counter is right-aligned so the eye can run down the
## column of numbers rather than hunting for each one at the end of its line.
func _build_row(row: Dictionary) -> Container:
	var panel := PanelContainer.new()
	panel.name = "Row_" + str(row["id"])
	panel.theme_type_variation = &"DrawerRow"
	var line := HBoxContainer.new()
	line.name = "Line"
	line.add_theme_constant_override(&"separation", int(_spacing))
	panel.add_child(line)

	var mark := UIWidgets.label("Mark", MARK_TODO, &"SeverityBadge")
	mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(mark)

	var text := UIWidgets.label("Text", str(row["text"]), &"", true)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(text)

	var bar := MeterBar.new()
	bar.name = "Bar"
	bar.custom_minimum_size = Vector2(ROW_BAR_W_DP, ROW_BAR_H_DP)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(bar)

	var counter := UIWidgets.label("Counter", str(row["counter"]), &"SeverityBadge")
	counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	counter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(counter)

	_row_nodes[str(row["id"])] = {"panel": panel, "mark": mark, "text": text,
			"counter": counter, "bar": bar}
	return panel


## The payoff card. It is a card and not a line because it is the ANSWER to the
## question the sheet exists for — "what do I get" — and doc 12 §2.13's
## progression moment is the one beat this deck had before this screen existed.
func _build_reward_card() -> Container:
	_reward_card = PanelContainer.new()
	_reward_card.name = "Reward"
	_reward_card.theme_type_variation = &"SeverityBadge"
	var box := VBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override(&"separation", int(_spacing * 0.5))
	_reward_card.add_child(box)
	_reward_title = UIWidgets.label("Title", "", &"LegendRow", true)
	_reward_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_reward_title)
	_reward_lines = VBoxContainer.new()
	_reward_lines.name = "Lines"
	_reward_lines.add_theme_constant_override(&"separation", 0)
	box.add_child(_reward_lines)
	return _reward_card


## The arc, as a strip: level 0 is the tutorial, and it is on the strip because
## the tutorial IS the first teaching beat — a strip that starts at 1 reads as
## though the player has not begun.
func _build_ladder() -> Container:
	var scroll := ScrollContainer.new()
	scroll.name = "LadderScroll"
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0.0, _touch_min)
	_ladder_box = HBoxContainer.new()
	_ladder_box.name = "Ladder"
	_ladder_box.add_theme_constant_override(&"separation", int(_spacing * 0.5))
	scroll.add_child(_ladder_box)
	return scroll


# ---------------------------------------------------------------------------
# Binding
# ---------------------------------------------------------------------------

## Re-reads the model. Cheap enough for the shell's HUD cadence — it walks a
## five-row objective list and a six-rung strip.
func refresh() -> void:
	if model == null or _body == null:
		return
	_apply_contracts(model.contracts_view())
	var view := model.view()
	var complete := bool(view["complete"])
	_level_badge.text = UIWidgets.t_args(config, "ui_goals_level",
			{"level": int(view["level"])}, "L%d" % int(view["level"])) if not complete \
			else UIWidgets.t(config, "ui_goals_complete_badge", "✦")
	_level_name.text = str(view["title"])
	var standing_city := int(view.get("city_level", 0))
	var standing_target := int(view["level"])
	if complete or standing_city == standing_target:
		_level_standing.visible = false
	else:
		_level_standing.visible = true
		_level_standing.text = UIWidgets.t_args(config,
				"ui_goals_standing_below" if standing_city < standing_target
				else "ui_goals_standing_above",
				{"city": standing_city, "level": standing_target})
	_level_intent.text = str(view["intent"])
	_level_teaches.text = str(view["teaches"])
	_level_teaches.visible = _level_teaches.text != ""
	_level_bar.set_value(float(view["ratio"]),
			HudModel.STATE_NORMAL if complete else HudModel.STATE_WARNING)
	_level_count.text = "" if complete else UIWidgets.t_args(config,
			"ui_goals_progress",
			{"done": int(view["done_count"]), "total": int(view["total_count"])},
			"%d of %d done" % [int(view["done_count"]), int(view["total_count"])])
	_apply_rows(view["rows"] as Array)
	var backstop: Dictionary = view["backstop"]
	_backstop.text = str(backstop.get("text", ""))
	_backstop.visible = bool(backstop.get("has", false)) and _backstop.text != ""
	_apply_reward(view["reward"] as Dictionary, int(view["level"]))
	var next_level: Dictionary = view["next"]
	_next_line.visible = bool(next_level["has"])
	if _next_line.visible:
		_next_line.text = UIWidgets.t_args(config, "ui_goals_next",
				{"title": str(next_level["title"])}, str(next_level["title"]))
	_apply_ladder(view["ladder"] as Array)


func _apply_rows(rows: Array) -> void:
	var wanted: Dictionary = {}
	for entry: Variant in rows:
		wanted[str((entry as Dictionary)["id"])] = true
	# Rebuild only when the row SET changes — a refresh on the HUD's cadence must
	# not drop and re-create five panels several times a second.
	var stale := _row_nodes.size() != wanted.size()
	if not stale:
		for id: Variant in _row_nodes:
			if not wanted.has(str(id)):
				stale = true
				break
	if stale:
		UIWidgets.clear_children(_rows_box)
		_row_nodes.clear()
		for entry: Variant in rows:
			_rows_box.add_child(_build_row(entry as Dictionary))
	for entry: Variant in rows:
		var row: Dictionary = entry
		var nodes: Dictionary = _row_nodes.get(str(row["id"]), {})
		if nodes.is_empty():
			continue
		var done := bool(row["done"])
		var mark: Label = nodes["mark"]
		mark.text = MARK_DONE if done else MARK_TODO
		(nodes["text"] as Label).text = str(row["text"])
		var counter: Label = nodes["counter"]
		counter.text = str(row["counter"])
		counter.visible = counter.text != ""
		var bar: MeterBar = nodes["bar"]
		bar.visible = not done and float(row["ratio"]) > 0.0
		bar.set_value(float(row["ratio"]), HudModel.STATE_WARNING)
		UIWidgets.paint_state(self, mark,
				HudModel.STATE_NORMAL if done else &"")


func _apply_reward(reward: Dictionary, level: int) -> void:
	var empty := bool(reward["empty"])
	_reward_title.text = UIWidgets.t_args(config, "ui_goals_reward",
			{"level": level + 1}, "") if not empty \
			else UIWidgets.t(config, "ui_goals_reward_none", "")
	UIWidgets.clear_children(_reward_lines)
	for line: Variant in (reward["lines"] as PackedStringArray):
		var label := UIWidgets.label("Line", "%s %s" % [GoalsModel.SEPARATOR, str(line)],
				&"", true)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_reward_lines.add_child(label)
	_reward_card.visible = _reward_title.text != "" or not empty


func _apply_ladder(rungs: Array) -> void:
	UIWidgets.clear_children(_ladder_box)
	for entry: Variant in rungs:
		var rung: Dictionary = entry
		var chip := UIWidgets.label("Rung%d" % int(rung["level"]),
				"%s %d" % [MARK_DONE if bool(rung["earned"]) else MARK_TODO,
						int(rung["level"])], &"StatChip")
		chip.custom_minimum_size = Vector2(0.0, _touch_min)
		chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		chip.tooltip_text = str(rung["title"])
		UIWidgets.paint_state(self, chip,
				HudModel.STATE_NORMAL if bool(rung["earned"])
				else (HudModel.STATE_WARNING if bool(rung["active"]) else &""))
		_ladder_box.add_child(chip)


## The band, in its four states: a commission running, a commission finished, a
## board of offers with nothing taken, and a board that is empty or resting.
##
## The whole band hides when there is nothing to say AND nothing to wait for,
## because a header over an empty box teaches a player to stop looking there.
func _apply_contracts(view: Dictionary) -> void:
	if _contracts_box == null:
		return
	var available := bool(view.get("available", false))
	var active: Dictionary = view.get("active", {})
	var offers: Array = view.get("offers", [])
	var note := str(view.get("note", ""))
	# **The band is drawn whenever the board exists, empty included**, and the
	# note is what carries the state. Hiding it when there is nothing on it was
	# the first draft and it is wrong for this project specifically: a player who
	# has never seen the header has no way to learn that commissions are a thing
	# the city does, and a feature nobody can discover is the defect doc 91 keeps
	# filing under `A91-D-19`. "No commissions on the board right now" is a
	# sentence; an absent header is not.
	_contracts_box.visible = available
	_contracts_title.visible = available
	_contracts_note.text = note
	_contracts_note.visible = note != ""

	_contract_active.visible = not active.is_empty()
	if not active.is_empty():
		_contract_active_client.text = str(active["client"])
		_contract_active_text.text = str(active["text"])
		_contract_active_bar.set_value(float(active["ratio"]),
				HudModel.STATE_NORMAL if bool(active["ready"]) else HudModel.STATE_WARNING)
		_contract_active_count.text = str(active["progress_text"])
		_contract_active_clock.text = str(active["remaining_text"])
		_contract_claim.text = UIWidgets.t_args(config, "ui_contract_claim_reward",
				{"reward": str(active["reward_text"])},
				UIWidgets.t(config, "ui_contract_claim", "CLAIM"))
		_contract_claim.tooltip_text = _contract_claim.text
		# Disabled with the money still on its face while the work is unfinished:
		# the number a player is working toward belongs on the control they are
		# working toward.
		_contract_claim.disabled = not bool(active["ready"])

	UIWidgets.clear_children(_contract_offers)
	_offer_buttons.clear()
	for offer_variant: Variant in offers:
		_contract_offers.add_child(_build_offer_row(offer_variant as Dictionary))


## The two taps. Each runs the REAL command through the model, refreshes off the
## city the command left behind, and re-emits the sim's own answer — the shell
## needs it because a claim moves the treasury and a HUD that predicted the
## number would be predicting money.
func request_accept_contract(contract_id: int) -> void:
	if model == null:
		return
	var result := model.accept_contract(contract_id)
	call_deferred("refresh")
	contract_accepted.emit(result)


func request_claim_contract() -> void:
	if model == null:
		return
	var result := model.claim_contract()
	call_deferred("refresh")
	contract_claimed.emit(result)


## The band's controls, for `tests/test_ui_contracts.gd` and the preview harness.
func claim_button() -> Button:
	return _contract_claim


func offer_button(contract_id: int) -> Button:
	return _offer_buttons.get(contract_id, null) as Button


func contracts_band() -> Control:
	return _contracts_box


## The right-edge column, solved against the display it is on — see
## `goal_completed` names pulse once. A8 suppresses the motion entirely under
## `reduce_motion` — the tick and the toast still say what happened.
func celebrate(goal_id: String) -> void:
	if _reduce_motion or goal_id == "":
		return
	_celebrating[goal_id] = _pulse_s


func _process(delta: float) -> void:
	if _celebrating.is_empty():
		return
	for goal_id: Variant in _celebrating.keys():
		var left := float(_celebrating[goal_id]) - delta
		var nodes: Dictionary = _row_nodes.get(str(goal_id), {})
		if left <= 0.0 or nodes.is_empty():
			_celebrating.erase(goal_id)
			if not nodes.is_empty():
				(nodes["panel"] as Control).modulate.a = 1.0
			continue
		_celebrating[goal_id] = left
		(nodes["panel"] as Control).modulate.a = \
				0.55 + 0.45 * (0.5 + 0.5 * cos(TAU * (left / maxf(_pulse_s, 0.001))))


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _panel != null and _panel.visible


func open() -> void:
	UIWidgets.close_siblings(self)
	refresh()
	_set_visible(true)
	sheet_toggled.emit(true)


func close() -> void:
	_set_visible(false)
	sheet_toggled.emit(false)


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


func _set_visible(value: bool) -> void:
	if _panel != null:
		_panel.visible = value
	if _scrim != null:
		_scrim.visible = value
		_scrim.mouse_filter = Control.MOUSE_FILTER_STOP if value \
				else Control.MOUSE_FILTER_IGNORE


# ---------------------------------------------------------------------------
# Helpers for the tests and the screenshot harness
# ---------------------------------------------------------------------------

func row_ids() -> PackedStringArray:
	var out: PackedStringArray = []
	for id: Variant in _row_nodes:
		out.append(str(id))
	return out


func row_counter(goal_id: String) -> String:
	var nodes: Dictionary = _row_nodes.get(goal_id, {})
	return "" if nodes.is_empty() else str((nodes["counter"] as Label).text)


func row_mark(goal_id: String) -> String:
	var nodes: Dictionary = _row_nodes.get(goal_id, {})
	return "" if nodes.is_empty() else str((nodes["mark"] as Label).text)


func level_badge_text() -> String:
	return _level_badge.text if _level_badge != null else ""


func reward_line_count() -> int:
	return _reward_lines.get_child_count() if _reward_lines != null else 0


func ladder_rung_count() -> int:
	return _ladder_box.get_child_count() if _ladder_box != null else 0
