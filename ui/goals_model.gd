class_name GoalsModel
extends RefCounted
## S14's headless half (doc 12 §2.19) — the goals sheet and the HUD's goal chip,
## computed without a single `Node`.
##
## `GoalSystem` publishes the curriculum as plain data: which level is active,
## which objectives it carries, how far along each one is. This class turns that
## into a SCREEN: resolved copy, a counter per row, a progress ratio, the
## unlock the next level pays out, and the level strip down the side.
##
## **The reward row is READ, never authored.** "Level 3 unlocks High-rises" is not
## a sentence in a data file — it is `min_city_level` on doc 02's build cards,
## `min_city_level` on doc 09's land blocks, and the building level doc 02's
## upgrade ladder opens at that rung. All three are asked, so a retune of any of
## them moves this screen with it and cannot leave it lying.
##
## Holds the sim, like `BuildController` and `LandPanelModel` do — `ui/` reads the
## sim and issues commands; it is the SIM that may not know `ui/` exists.

## `data/ui.json.goals`, with the documented fallbacks.
const DEFAULT_MAX_REWARD_ROWS := 4
## U+00B7 MIDDLE DOT — the chip's `L2 · 2/3`, and the only punctuation in it.
const SEPARATOR := "·"

var sim: CitySim
var config: UIConfig
## Supplies the build-card table the reward row is read from. Optional: without
## one the reward row falls back to land and upgrade tiers, which are the two
## halves this class can read off the sim alone.
var controller: BuildController

var _goals_cfg: Dictionary = {}


func _init(p_sim: CitySim, p_config: UIConfig = null,
		p_controller: BuildController = null) -> void:
	sim = p_sim
	config = p_config
	controller = p_controller
	if config != null:
		_goals_cfg = config.section("goals")


# ---------------------------------------------------------------- the chip

## `{visible, text, level, label, pulse_key}` for doc 12 §2.4's goal chip.
##
## The chip RETIRES when the curriculum is finished, and that is a design
## decision rather than an optimisation: it is a teaching surface, it costs the
## top bar a chip's worth of width, and a player who has run every system in the
## game does not need to be told what to do next. `HudModel` reads `visible` and
## drops the chip out of the solve entirely, so the bar goes back to the
## seven-chip layout doc 12 §2.4 is written against.
func chip_view() -> Dictionary:
	if sim == null or sim.goals == null:
		return {"visible": false, "text": "", "level": 0, "label": ""}
	var level: int = sim.goals.active_level()
	if level == GoalSystem.LEVEL_COMPLETE:
		return {"visible": false, "text": "", "level": 0, "label": _t("ui_goals_title")}
	# The chip names BOTH levels — the one the city HOLDS and the one the goals
	# reach — because "L3 · 1/4" alone taught a level-2 player they were level 3
	# and the build sheet then looked broken when it asked for 3 (playtest,
	# 2026-08-21). `city→target` is the transition the card actually sells.
	var city_level: int = sim.progression.city_level
	return {
		"visible": true,
		"text": "L%d→%d %s %s" % [city_level, level, SEPARATOR, sim.goals.chip_text()],
		"level": level,
		"city_level": city_level,
		"label": _t("ui_goals_chip"),
	}


# --------------------------------------------------------------- the sheet

func view() -> Dictionary:
	var out := {
		"complete": true, "level": 0, "city_level": 0,
		"title": _t("ui_goals_complete_title"), "intent": _t("ui_goals_complete_body"),
		"teaches": "", "rows": [], "done_count": 0, "total_count": 0,
		"ratio": 1.0,
		# `lines` is a PackedStringArray in BOTH branches on purpose: the view
		# casts it, and a plain Array here casts to null — an empty reward card
		# that looks exactly like a level which pays nothing.
		"reward": {"level": 0, "lines": PackedStringArray(), "empty": true},
		"next": {"has": false, "level": 0, "title": "", "intent": ""},
		"ladder": ladder(), "backstop": {"has": false},
	}
	if sim == null or sim.goals == null:
		return out
	out["city_level"] = sim.progression.city_level
	var goal_view: Dictionary = sim.goals.view()
	if bool(goal_view["complete"]):
		return out
	var level := int(goal_view["level"])
	out["complete"] = false
	out["level"] = level
	out["title"] = _t(str(goal_view["title_key"]))
	out["intent"] = _t(str(goal_view["intent_key"]))
	out["teaches"] = _t(str(goal_view["teaches_key"]))
	var rows: Array = []
	for raw: Variant in (goal_view["objectives"] as Array):
		rows.append(_row(raw as Dictionary))
	out["rows"] = rows
	out["done_count"] = int(goal_view["done_count"])
	out["total_count"] = int(goal_view["total_count"])
	out["ratio"] = float(out["done_count"]) / maxf(1.0, float(out["total_count"]))
	out["reward"] = reward(level)
	out["next"] = level_preview(level + 1)
	out["backstop"] = backstop(level)
	return out


# --------------------------------------------------- the commissions band

## S14's second band (Wave 19; doc 03 §2.5b, doc 12 §2.19 D-90, report 98 §60
## RR-170) — the commissions board, rendered.
##
## **Why it lives on the goals sheet and not on a screen of its own.** A
## commission is an objective that pays: it asks for a target, counts progress
## toward it and hands over something when it is met, which is the sentence S14
## already exists to say. Giving it a sheet would put two screens in the deck
## that answer *"what should I be doing?"*, and the 2026-09-03 report is from a
## player who could not find a reason to open the app — one more place to look is
## the opposite of the fix.
##
## Everything here is READ, never authored: the board's own rows, priced by doc
## 03, with `cmd_accept_contract(…, true)` and `cmd_claim_contract(true)` asked
## for the two gates so a button is never live on a rule `ui/` believes and the
## sim does not.
func contracts_view() -> Dictionary:
	var out := {"available": false, "active": {}, "offers": [] as Array,
			"cooldown_hours": 0.0, "note": ""}
	if sim == null or sim.contracts == null:
		return out
	out["available"] = true
	var board := sim.contracts
	out["cooldown_hours"] = board.cooldown_hours()
	if board.has_active():
		out["active"] = _contract_active_view(board.active())
	for row_variant: Variant in board.offers():
		out["offers"].append(_contract_offer_view(row_variant as Dictionary))
	# The one-line state sentence, and the three states it has to tell apart: a
	# board with something on it says nothing (the rows speak for it), a board
	# that is RESTING after a delivery says when the next one is posted, and an
	# EMPTY board says so — because the band is drawn either way and a header
	# over a gap is worse than a header over a sentence.
	if out["active"].is_empty() and (out["offers"] as Array).is_empty():
		out["note"] = _t_args("ui_contract_cooldown",
				{"time": UIWidgets.duration_text(config, board.cooldown_hours() * 60.0)}) \
				if board.cooldown_hours() > 0.0 else _t("ui_contract_none")
	return out


func _contract_active_view(row: Dictionary) -> Dictionary:
	var preview := sim.cmd_claim_contract(true)
	var ready := bool(preview["ok"])
	var target := maxi(1, int(row["target"]))
	return {
		"id": int(row["id"]),
		"client": _t(String(row["client_key"])),
		"text": _t(String(row["text_key"])),
		"tier": String(row["tier"]),
		"reward": int(row["reward"]),
		"reward_text": RequirementFormatter.money(int(row["reward"])),
		"progress": int(row["progress"]),
		"target": target,
		"ratio": clampf(float(row["progress"]) / float(target), 0.0, 1.0),
		"progress_text": _t_args("ui_contract_progress",
				{"done": int(row["progress"]), "total": target}),
		"ready": ready,
		# The clock, in the queue panel's own words — a player who reads `21h 30m`
		# on one screen and `21.5 hours` on another is reading two things.
		"remaining_text": _t_args("ui_contract_deadline",
				{"time": UIWidgets.duration_text(config,
						maxf(0.0, float(row["remaining_h"])) * 60.0)}),
	}


func _contract_offer_view(row: Dictionary) -> Dictionary:
	var preview := sim.cmd_accept_contract(int(row["id"]), true)
	var ok := bool(preview["ok"])
	var reason: Dictionary = {}
	if not ok and controller != null and controller.formatter != null:
		reason = controller.formatter.format(preview["reason_code"],
				(preview.get("payload", {}) as Dictionary))
	return {
		"id": int(row["id"]),
		"client": _t(String(row["client_key"])),
		"text": _t(String(row["text_key"])),
		"tier": String(row["tier"]),
		"reward": int(row["reward"]),
		"reward_text": RequirementFormatter.money(int(row["reward"])),
		"target": int(row["target"]),
		"deadline_text": _t_args("ui_contract_window",
				{"time": UIWidgets.duration_text(config,
						float(row["deadline_h"]) * 60.0)}),
		"ok": ok,
		"reason": reason,
	}


## The two doors, through the same funnel every other verb in `ui/` uses: the
## real command, the sim's own answer, no prediction.
func accept_contract(contract_id: int) -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_CONTRACT", {})
	return sim.cmd_accept_contract(contract_id)


func claim_contract() -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_NO_CONTRACT", {})
	return sim.cmd_claim_contract()


## Args-taking sibling of `_t`, added with the commissions band because every
## line in it carries a number.
func _t_args(key: String, args: Dictionary) -> String:
	return UIWidgets.t_args(config, key, args, key)


## One objective row, rendered. `counter` is the readout the eye lands on; a
## counted objective shows `2/4`, a state objective shows the reading against the
## number it has to beat, and a finished one shows neither — it shows a tick.
func _row(obj: Dictionary) -> Dictionary:
	var target := float(obj["target"])
	var current := float(obj["current"])
	var kind := StringName(str(obj["kind"]))
	var done := bool(obj["done"])
	var counter := ""
	if not done:
		if GoalSystem.STATE_KINDS.has(kind):
			counter = "%s/%s" % [_number(kind, current), _number(kind, target)]
		else:
			counter = "%d/%d" % [int(current), int(target)]
	return {
		"id": str(obj["id"]),
		"text": UIWidgets.t_args(config, str(obj["text_key"]),
				{"target": _number(kind, target)}, str(obj["text_key"])),
		"current": current, "target": target, "done": done,
		"counter": counter,
		"ratio": 1.0 if done else clampf(current / maxf(target, 0.0001), 0.0, 1.0),
	}


## Population reads as a population, money as money, a fraction as a fraction —
## the readout has to be in the units the chip beside it is already using or the
## two disagree about the same city.
static func _number(kind: StringName, value: float) -> String:
	match kind:
		&"reach_population":
			return HudModel.pop(int(round(value)))
		&"reach_treasury":
			return HudModel.money(int(round(value)))
		&"reach_happiness", &"reach_stability":
			return str(int(round(value)))
	return str(int(round(value)))


# --------------------------------------------------------------- the reward

## What reaching `level` pays out, as sentences. Three real reads and no
## authored list: the build cards whose `min_city_level` is exactly this rung,
## the building level doc 02's upgrade ladder opens at it, and the land doc 09
## unlocks on it.
func reward(level: int) -> Dictionary:
	var lines: PackedStringArray = []
	for name in unlocked_card_names(level):
		lines.append(name)
	var tier := unlocked_upgrade_level(level)
	if tier > 0:
		lines.append(UIWidgets.t_args(config, "ui_goals_reward_upgrade",
				{"level": tier}, "Upgrades to level %d" % tier))
	var blocks := unlocked_block_count(level)
	if blocks > 0:
		lines.append(UIWidgets.t_args(config, "ui_goals_reward_land",
				{"count": blocks}, "%d blocks of land" % blocks))
	var cap := UIConfig.get_int(_goals_cfg, "max_reward_rows", DEFAULT_MAX_REWARD_ROWS)
	while lines.size() > cap:
		lines.remove_at(lines.size() - 1)
	return {"level": level, "lines": lines, "empty": lines.is_empty()}


## Display names of every build card that becomes placeable at exactly `level`.
func unlocked_card_names(level: int) -> PackedStringArray:
	var out: PackedStringArray = []
	if controller == null:
		return out
	for card: Dictionary in controller.cards():
		if int(card["min_city_level"]) != level:
			continue
		out.append(UIWidgets.t(config, str(card["name_key"]),
				str(card["name_fallback"])))
	return out


## The building level doc 02's upgrade ladder opens at `level`, or 0. Asked of
## the catalog rather than of `data/building_rules.json`'s
## `min_city_level_by_level`, because the gate `cmd_upgrade_building` actually
## runs is the per-level `min_city_level` on the archetype's own row.
func unlocked_upgrade_level(level: int) -> int:
	if sim == null:
		return 0
	var best := 0
	for raw: Variant in sim.catalog.archetypes():
		var archetype := String(raw)
		# From rung 2 to the archetype's OWN top rung — five for the civic and
		# utility shells, six for doc 02 §2.14's growth stock. A fixed `6` here
		# would have made the tower tier invisible on the very card that is
		# supposed to announce it.
		for building_level in range(2, sim.catalog.max_level_of(archetype) + 1):
			var stats: Dictionary = sim.catalog.stats(archetype, building_level)
			if int(stats.get("min_city_level", -1)) == level:
				best = building_level if best == 0 else mini(best, building_level)
	return best


## How many land blocks doc 09 §2.5 opens at exactly `level`.
func unlocked_block_count(level: int) -> int:
	if sim == null:
		return 0
	var count := 0
	for block_id in sim.world.block_ids_sorted():
		var block: LandBlock = sim.world.block(String(block_id))
		if not block.is_owned() and block.min_city_level == level:
			count += 1
	return count


# ------------------------------------------------------- preview and ladder

## One level's name and intent, resolved — `{has, level, title, intent}`. The
## sheet asks for the NEXT level with it; the level-up toast asks for the one
## that just landed. Same question, two moments.
func level_preview(level: int) -> Dictionary:
	var row := GoalSystem.level_row(level)
	if row.is_empty():
		return {"has": false, "level": level, "title": "", "intent": ""}
	return {"has": true, "level": level, "title": _t(str(row["title_key"])),
			"intent": _t(str(row["intent_key"]))}


## The level strip: every rung of the curriculum with its state, plus level 0 —
## the tutorial — which is a real teaching beat and reads as a hole when the
## strip starts at 1.
func ladder() -> Array:
	var out: Array = []
	var earned: int = sim.goals.earned_level if sim != null and sim.goals != null else 0
	var active: int = sim.goals.active_level() if sim != null and sim.goals != null else 0
	out.append({"level": 0, "title": _t("ui_level_0_title"),
			"earned": true, "active": false})
	for raw: Variant in GoalSystem.levels():
		var row: Dictionary = raw
		var level := int(row["level"])
		out.append({"level": level, "title": _t(str(row["title_key"])),
				"earned": level <= earned, "active": level == active})
	return out


## Doc 09 §2.11's population rung for `level` — the OTHER route up, shown greyed
## under the objectives so the player can see that the ladder is still there and
## that the goals sheet is a shortcut through it rather than a gate on it.
func backstop(level: int) -> Dictionary:
	var thresholds := ProgressionSystem.city_level_pop()
	if level < 0 or level >= thresholds.size():
		return {"has": false}
	var target: int = thresholds[level]
	var current: int = sim.population.city_population if sim != null else 0
	if target <= 0 or current >= target:
		return {"has": false}
	return {"has": true, "target": target, "current": current,
			"text": UIWidgets.t_args(config, "ui_goals_backstop",
					{"target": HudModel.pop(target)}, "")}


func _t(key: String) -> String:
	return UIWidgets.t(config, key, key)
