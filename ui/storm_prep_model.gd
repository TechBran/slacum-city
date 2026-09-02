class_name StormPrepModel
extends RefCounted
## **S17's headless half (doc 12 §2.24) — the Storm Prep window.**
##
## Doc 07 §2.7.7 gives the player seventy game-minutes between the warning and
## the cell, and six things they can do with them. At the Wave-17 fork there was
## no screen, no verb and no door: the alert said *"You have about {minutes}
## minutes to get ready"* and the player had nothing to get ready WITH (99-PA
## PA-26).
##
## This class turns `CitySim.storm_prep_overview()` into a SCREEN: the countdown
## in words, three readiness meters, six rows that each say what they cost and —
## when they are unavailable — WHY, and the Storm Ready line that tells the
## player what the whole window is for.
##
## Constitution §3 / doc 12 §1: pure `RefCounted`, no `Node`, no scene tree.
## Every string is a `data/strings.en.json` KEY, every number is formatted here
## and nowhere else, and it authors no threshold: the count that earns Storm
## Ready is `storm.reward.min_prep_actions`, read back through the overview.
##
## **Built against the CONTRACT, not against `CitySim`.** `provider` and `door`
## are Callables, so the screen can be laid out, measured and photographed by
## `tools/ui_preview.gd` with a fixture behind it — the lesson doc 91 A91-D-28
## wrote down, applied on the way in.

## `data/ui.json.storm_prep`, with the documented fallbacks.
const DEFAULT_ROW_H_DP := 72.0
const DEFAULT_METER_H_DP := 6.0
## A5: state is never colour alone. The glyph carries it too.
const MARK_TAKEN := "✓"
const MARK_OPEN := "○"
const MARK_SHUT := "—"

## Row states, which are also the doc 12 §2.5 tokens the row tints with.
const STATE_TAKEN := "taken"
const STATE_AVAILABLE := "available"
const STATE_BLOCKED := "blocked"

## The refusal codes this screen has copy for. Anything else falls back to the
## generic line rather than showing a code — a reason code is a developer's
## word, and doc 12 §1 says the player never reads one.
const REASON_KEYS := {
	"E_FUNDS": "ui_storm_reason_funds",
	"E_AUSTERITY": "ui_storm_reason_austerity",
	"E_ALREADY_TAKEN": "ui_storm_reason_taken",
	"E_NO_TARGET": "ui_storm_reason_target",
	"E_PREP_WINDOW": "ui_storm_reason_window",
	"E_NO_STORM": "ui_storm_reason_no_storm",
}

var config: UIConfig
## `func() -> Dictionary` — `CitySim.storm_prep_overview()`'s shape.
var provider: Callable = Callable()
## `func(action_id: String, target: Dictionary) -> Dictionary` —
## `CitySim.cmd_storm_prep_action()`'s shape.
var door: Callable = Callable()

var _cfg: Dictionary = {}


func _init(p_config: UIConfig = null, p_provider: Callable = Callable(),
		p_door: Callable = Callable()) -> void:
	config = p_config if p_config != null else UIConfig.load_from_files()
	provider = p_provider
	door = p_door
	_cfg = config.section("storm_prep")


func row_h_dp() -> float:
	return UIConfig.get_num(_cfg, "row_h_dp", DEFAULT_ROW_H_DP)


func meter_h_dp() -> float:
	return UIConfig.get_num(_cfg, "meter_h_dp", DEFAULT_METER_H_DP)


## Everything the sheet draws, in one read.
##
## `visible` is the whole screen's gate: no storm pending means no sheet, and a
## sheet that opened on an empty window would be a door onto a corridor.
func view() -> Dictionary:
	var raw: Dictionary = provider.call() if provider.is_valid() else {}
	var open := bool(raw.get("open", false))
	var taken: Array = raw.get("taken", [])
	var target := int(raw.get("min_prep_actions", 3))
	var rows: Array = []
	for entry in (raw.get("actions", []) as Array):
		rows.append(_row(entry as Dictionary, open))
	return {
		"visible": int(raw.get("event_uid", -1)) >= 0,
		"open": open,
		"title": config.t("ui_storm_prep_title"),
		"countdown": _countdown(raw),
		"severity": _severity_line(raw),
		"rows": rows,
		"taken_count": taken.size(),
		"target_count": target,
		"reward": _reward_line(taken.size(), target),
		"reward_met": taken.size() >= target,
		"meters": _meters(raw.get("readiness", {})),
	}


## "Storm hits in 1h 10m" — or, once the cell is entering, the line that says
## the window has shut rather than a countdown to nothing.
func _countdown(raw: Dictionary) -> String:
	if not bool(raw.get("open", false)):
		return config.t("ui_storm_window_closed")
	return config.t("ui_storm_countdown", {
		"impact": UIWidgets.duration_text(config, int(raw.get("minutes_to_impact", 0))),
		"left": UIWidgets.duration_text(config, int(raw.get("minutes_left", 0))),
	})


## §2.6.2's `severity_mult` as a word, not a number. The player is never shown a
## multiplier; they are shown how hard this one is going to be.
func _severity_line(raw: Dictionary) -> String:
	var severity := float(raw.get("severity_mult", 0.0))
	if severity <= 0.0:
		return ""
	var key := "ui_storm_severity_moderate"
	if severity >= 1.25:
		key = "ui_storm_severity_severe"
	elif severity < 0.9:
		key = "ui_storm_severity_mild"
	return config.t(key)


func _reward_line(taken: int, target: int) -> String:
	if taken >= target:
		return config.t("ui_storm_reward_met")
	return config.t("ui_storm_reward_progress",
			{"taken": taken, "target": target, "left": target - taken})


## One action row: what it is, what it costs, whether it can be taken, and — the
## part that makes this a teaching screen — why not, in words.
func _row(raw: Dictionary, window_open: bool) -> Dictionary:
	var id := String(raw.get("id", ""))
	var taken := bool(raw.get("taken", false))
	var available := bool(raw.get("available", false))
	var state := STATE_BLOCKED
	var mark := MARK_SHUT
	if taken:
		state = STATE_TAKEN
		mark = MARK_TAKEN
	elif available:
		state = STATE_AVAILABLE
		mark = MARK_OPEN
	var cost := int(raw.get("cost", 0))
	return {
		"id": id,
		"title": config.t("ui_storm_action_%s" % id),
		"detail": config.t("ui_storm_action_%s_detail" % id),
		"cost": cost,
		"cost_text": config.t("ui_storm_cost_free") if cost <= 0 \
				else RequirementFormatter.money(cost),
		"state": state,
		"mark": mark,
		"enabled": available and not taken,
		"needs_target": bool(raw.get("needs_target", false)),
		"reason": "" if (taken or available) \
				else _reason_text(String(raw.get("reason_code", "")), window_open),
	}


func _reason_text(code: String, window_open: bool) -> String:
	if REASON_KEYS.has(code):
		return config.t(String(REASON_KEYS[code]))
	return "" if window_open else config.t("ui_storm_reason_window")


## The three readings §2.7.7's actions move, each as a labelled meter. They are
## the screen's argument: a player who cannot tell which button to press looks at
## which meter is short.
func _meters(readiness: Dictionary) -> Array:
	var lit := clampf(float(readiness.get("grid_powered_frac", 1.0)), 0.0, 1.0)
	var fill := clampf(float(readiness.get("water_fill", 1.0)), 0.0, 1.0)
	var idle := int(readiness.get("fleet_idle", 0))
	return [
		{"id": "grid", "label": config.t("ui_storm_meter_grid"),
				"ratio": lit, "value": RequirementFormatter.percent(lit)},
		{"id": "water", "label": config.t("ui_storm_meter_water"),
				"ratio": fill, "value": RequirementFormatter.percent(fill)},
		{"id": "fleet", "label": config.t("ui_storm_meter_fleet"),
				"ratio": clampf(float(idle) / 8.0, 0.0, 1.0),
				"value": config.t("ui_storm_meter_fleet_value", {"count": idle})},
	]


## Take one action. Returns the door's own result, unchanged: this class decides
## nothing about whether an action is allowed and never re-implements a gate.
func take(action_id: String, target: Dictionary = {}) -> Dictionary:
	if not door.is_valid():
		return {"ok": false, "reason_code": &"E_NO_DOOR", "payload": {}}
	return door.call(action_id, target)
