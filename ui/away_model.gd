class_name AwayModel
extends RefCounted
## WHILE YOU WERE AWAY (doc 12 §2.12, S11): what the city did while the app was
## in the background, and the one thing in it that still needs the player.
##
## ## Input contract
##
## One plain Dictionary, built by the shell on `AndroidLifecycle.resumed`. Every
## key is optional and the report degrades section by section rather than
## refusing to render — a resume that only knows how long it was is still a
## legitimate (and very short) report.
##
##     {
##       elapsed_wall_s:        float,   # AndroidLifecycle.resumed's argument
##       elapsed_game_minutes:  float,   # doc 01's CREDITED minutes (else derived)
##       capped:                bool,    # doc 01 credited less than really elapsed
##       cap_real_hours:        float,   # the cap in the unit the player slept in
##       cap_game_hours:        float,   # legacy spelling of the same cap, ÷60
##       before: {treasury:int, population:int, day_index:int,
##                stability:float, happiness:float},
##       after:  { … same keys … },
##       ledger: {taxes:float, expenses:float, net:float,
##                treasury_before:int, treasury_after:int},   # doc 03's, if known
##       events_digest: Array,           # sim bus events, verbatim, in order
##       unresolved:    Array,           # `IncidentModel` rows still open
##     }
##
## `before`/`after` are the whole of the "city change" section: everything else
## in it is a subtraction. `ledger` is doc 03's and is used verbatim when
## present; without it the treasury delta stands in for the net, which is true
## but coarser, and `has_ledger` says which the player is looking at.
##
## `events_digest` is **raw sim events** — the same dictionaries the alerts
## centre eats. Classification is not re-invented here: an event's priority
## class comes from `data/ui.json.alerts.events` through `AlertsModel.rule_for()`,
## so the report's idea of "a P1 happened" is by construction the same as the
## banner's. Doc 06's incident events carry no rule there, so they classify off
## their tier instead (T4+ ⇒ P1, T3 ⇒ P2), which is §2.4's own banding.
##
## ## Trigger
##
## §2.12: shown when `real_elapsed_seconds ≥ away_report.min_real_seconds` (120)
## **or** any P1/P2 event occurred offline; below that with nothing notable, the
## shell shows the toast `toast_text()` returns instead.

const CLASS_P1 := "p1"
const CLASS_P2 := "p2"
const CLASS_P3 := "p3"

const _DEFAULT_MIN_REAL_S := 120.0
const _DEFAULT_MAX_TIMELINE := 8
const _DEFAULT_MAX_UNRESOLVED := 3
const _SECONDS_PER_MINUTE := 60.0
const _MINUTES_PER_DAY := 1440.0

## Doc 01's mapping, restated as a comment rather than as a constant: 1 real
## second is 1 game-minute at 1×, so an elapsed wall time converts to game
## minutes one-for-one when the caller does not supply the credited figure.
const GAME_MINUTES_PER_REAL_SECOND := 1.0

var _cfg: UIConfig
var _away: Dictionary = {}
var _alerts: AlertsModel
var _input: Dictionary = {}


func _init(cfg: UIConfig = null) -> void:
	if cfg == null:
		return
	_cfg = cfg
	_away = cfg.section("away_report")
	_alerts = AlertsModel.new(cfg)


static func load_from_files() -> AwayModel:
	return AwayModel.new(UIConfig.load_from_files())


func min_real_seconds() -> float:
	return UIConfig.get_num(_away, "min_real_seconds", _DEFAULT_MIN_REAL_S)


func max_timeline_entries() -> int:
	return maxi(1, UIConfig.get_int(_away, "max_timeline_entries", _DEFAULT_MAX_TIMELINE))


func max_unresolved_shown() -> int:
	return maxi(1, UIConfig.get_int(_away, "max_unresolved_shown", _DEFAULT_MAX_UNRESOLVED))


# ---------------------------------------------------------------------------
# Classification — the alerts table, not a second opinion
# ---------------------------------------------------------------------------

## `p1` / `p2` / `p3` for one sim event. Doc 06's incident events are not in the
## alerts table (they reach the player through the drawer, not the feed), so they
## band off their tier the way §2.4 does.
func event_class(event: Dictionary) -> String:
	var type_name := str(event.get("type", ""))
	if type_name.begins_with("incident_"):
		var tier := int(event.get("tier", event.get("tier_peak", 0)))
		if tier <= 0:
			tier = HudModel.incident_tier(float(event.get("severity", 1.0)))
		if tier >= 4:
			return CLASS_P1
		return CLASS_P2 if tier == 3 else CLASS_P3
	if _alerts == null:
		return CLASS_P3
	var rule := _alerts.rule_for(event)
	return str(rule.get("class", CLASS_P3)) if not rule.is_empty() else CLASS_P3


func is_notable(event: Dictionary) -> bool:
	var cls := event_class(event)
	return cls == CLASS_P1 or cls == CLASS_P2


func notable_count(events: Array) -> int:
	var count := 0
	for raw: Variant in events:
		if raw is Dictionary and is_notable(raw as Dictionary):
			count += 1
	return count


## §2.12's trigger, exactly: long enough away, or something notable happened.
func should_show(input: Dictionary) -> bool:
	if float(input.get("elapsed_wall_s", 0.0)) >= min_real_seconds():
		return true
	var digest: Variant = input.get("events_digest", [])
	if digest is Array and notable_count(digest as Array) > 0:
		return true
	var unresolved: Variant = input.get("unresolved", [])
	return unresolved is Array and not (unresolved as Array).is_empty()


# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------

## The whole S11 view, section by section in §2.12's fixed order. Empty sections
## carry `visible = false` rather than being absent, so a view can bind them all
## once and never rebuild.
func build(input: Dictionary) -> Dictionary:
	_input = input.duplicate(true)
	var before: Dictionary = _block(input, "before")
	var after: Dictionary = _block(input, "after")
	var digest: Array = input.get("events_digest", []) if input.get(
			"events_digest", []) is Array else []
	var unresolved: Array = input.get("unresolved", []) if input.get(
			"unresolved", []) is Array else []
	return {
		"show": should_show(input),
		"header": _header(input),
		"needs_you": _needs_you(unresolved),
		"ledger": _ledger(input, before, after),
		"change": _change(before, after),
		"timeline": _timeline(digest),
		"toast": toast_text(input),
	}


func _block(input: Dictionary, key: String) -> Dictionary:
	var raw: Variant = input.get(key, {})
	return raw if raw is Dictionary else {}


func _header(input: Dictionary) -> Dictionary:
	var wall_s := maxf(0.0, float(input.get("elapsed_wall_s", 0.0)))
	var game_minutes := float(input.get("elapsed_game_minutes",
			wall_s * GAME_MINUTES_PER_REAL_SECOND))
	var days := game_minutes / _MINUTES_PER_DAY
	var out := {
		"title": UIWidgets.t(_cfg, "ui_away_header"),
		"elapsed_wall_s": wall_s,
		"elapsed_game_minutes": game_minutes,
		"game_days": days,
		"text": UIWidgets.t_args(_cfg, "ui_away_elapsed", {
			"away": HudModel.eta(int(round(wall_s))),
			"game": HudModel.eta(int(round(game_minutes * _SECONDS_PER_MINUTE))),
		}),
		"days_text": UIWidgets.t_args(_cfg, "ui_away_days",
				{"n": int(floor(days))}) if days >= 1.0 else "",
		"capped": bool(input.get("capped", false)),
		"capped_text": "",
	}
	if bool(out["capped"]):
		out["capped_text"] = UIWidgets.t_args(_cfg, "ui_away_capped",
				{"hours": _cap_real_hours(input)})
	return out


## The cap in the unit the player was away in (RR-162). The line used to quote
## `cap_game_hours` and render *"Your city ran for 720h — the maximum."* — city
## time, in a sentence about somebody's night. `CatchUpPlanner.plan` now carries
## `cap_real_hours` and that is what fills it; `cap_game_hours` is still accepted
## and converted, so a caller that has not been updated says something true
## rather than something absurd.
func _cap_real_hours(input: Dictionary) -> int:
	if input.has("cap_real_hours"):
		return maxi(1, int(round(float(input["cap_real_hours"]))))
	var game_hours := float(input.get("cap_game_hours", 0.0))
	if game_hours > 0.0:
		return maxi(1, int(round(game_hours / 60.0)))
	return 12


## §2.12 section 2: "only if non-empty, rendered first in CRITICAL styling, up to
## 3 unresolved incidents as §2.6 rows, each with a HANDLE NOW button". The rows
## arrive as `IncidentModel` rows, so they are already §2.6-shaped; ordering is
## worst tier first, then longest waiting, then id — the drawer's own key minus
## the escalation clock, which a resumed report has no live value for.
func _needs_you(unresolved: Array) -> Dictionary:
	var rows: Array[Dictionary] = []
	for raw: Variant in unresolved:
		if raw is Dictionary:
			rows.append((raw as Dictionary).duplicate(true))
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ta := int(a.get("tier", 0))
		var tb := int(b.get("tier", 0))
		if ta != tb:
			return ta > tb
		var wa := float(a.get("wait_min", a.get("age_min", 0.0)))
		var wb := float(b.get("wait_min", b.get("age_min", 0.0)))
		if not is_equal_approx(wa, wb):
			return wa > wb
		return int(a.get("id", 0)) < int(b.get("id", 0)))
	var cap := max_unresolved_shown()
	var shown := rows.slice(0, cap)
	return {
		"visible": not shown.is_empty(),
		"title": UIWidgets.t(_cfg, "ui_away_needs_you"),
		"rows": shown,
		"total": rows.size(),
		"hidden": maxi(0, rows.size() - shown.size()),
		"more_text": UIWidgets.t_args(_cfg, "ui_away_more",
				{"n": rows.size()}) if rows.size() > shown.size() else "",
		"action_text": UIWidgets.t(_cfg, "ui_away_handle_now"),
		"state": HudModel.STATE_CRITICAL,
	}


## §2.12 section 3. Doc 03's ledger when the shell has it, otherwise the treasury
## delta alone — stated as such, never dressed up as a revenue figure it is not.
func _ledger(input: Dictionary, before: Dictionary, after: Dictionary) -> Dictionary:
	var raw: Variant = input.get("ledger", {})
	var ledger: Dictionary = raw if raw is Dictionary else {}
	var treasury_before := int(ledger.get("treasury_before", before.get("treasury", 0)))
	var treasury_after := int(ledger.get("treasury_after", after.get("treasury", 0)))
	var has_ledger := ledger.has("taxes") or ledger.has("expenses") or ledger.has("net")
	var net := float(ledger.get("net", float(treasury_after - treasury_before)))
	var out := {
		"visible": has_ledger or treasury_before != treasury_after,
		"has_ledger": has_ledger,
		"title": UIWidgets.t(_cfg, "ui_away_ledger"),
		"taxes": float(ledger.get("taxes", 0.0)),
		"expenses": float(ledger.get("expenses", 0.0)),
		"net": net,
		"treasury_before": treasury_before,
		"treasury_after": treasury_after,
		"treasury_text": UIWidgets.t_args(_cfg, "ui_away_treasury", {
			"before": HudModel.money(treasury_before),
			"after": HudModel.money(treasury_after),
		}),
		"net_state": HudModel.STATE_NORMAL if net >= 0.0 else HudModel.STATE_WARNING,
		"text": "",
	}
	if has_ledger:
		out["text"] = UIWidgets.t_args(_cfg, "ui_away_ledger_line", {
			"taxes": HudModel.money(int(round(float(ledger.get("taxes", 0.0))))),
			"expenses": HudModel.money(int(round(float(ledger.get("expenses", 0.0))))),
			"net": HudModel.money(int(round(net))),
		})
	else:
		out["text"] = UIWidgets.t_args(_cfg, "ui_away_ledger_net",
				{"net": HudModel.money(int(round(net)))})
	return out


## §2.12 section 4: population, buildings, land, stability — each line dropped
## when the two snapshots do not disagree, so a quiet absence shows a short list
## rather than four zeroes.
func _change(before: Dictionary, after: Dictionary) -> Dictionary:
	var lines: Array[Dictionary] = []
	var pop_before := int(before.get("population", 0))
	var pop_after := int(after.get("population", pop_before))
	if pop_after != pop_before:
		lines.append({
			"id": "population",
			"text": UIWidgets.t_args(_cfg, "ui_away_population", {
				"before": HudModel.pop(pop_before),
				"after": HudModel.pop(pop_after),
				"delta": BudgetModel.signed(float(pop_after - pop_before)),
			}),
			"state": HudModel.STATE_NORMAL if pop_after >= pop_before
					else HudModel.STATE_WARNING,
		})
	var day_before := int(before.get("day_index", 0))
	var day_after := int(after.get("day_index", day_before))
	if day_after != day_before:
		lines.append({
			"id": "days",
			"text": UIWidgets.t_args(_cfg, "ui_away_day_index",
					{"day": day_after + 1, "n": day_after - day_before}),
			"state": HudModel.STATE_NORMAL,
		})
	for key: String in ["stability", "happiness"]:
		if not (before.has(key) and after.has(key)):
			continue
		var was := int(round(clampf(float(before[key]), 0.0, 1.0) * 100.0))
		var now := int(round(clampf(float(after[key]), 0.0, 1.0) * 100.0))
		if was == now:
			continue
		lines.append({
			"id": key,
			"text": UIWidgets.t_args(_cfg, "ui_away_%s" % key,
					{"before": was, "after": now}),
			"state": HudModel.STATE_NORMAL if now >= was else HudModel.STATE_WARNING,
		})
	return {
		"visible": not lines.is_empty(),
		"title": UIWidgets.t(_cfg, "ui_away_change"),
		"lines": lines,
	}


## §2.12 section 5: "max 8 labelled entries chosen by `(-peak_tier, -duration_h)`".
## With a raw digest the closest honest reading of that key is
## `(-class_rank, -count)`: the worst class first, then the loudest of it. Events
## of the same type collapse into one entry carrying a count, which is what makes
## `23 minor incidents` one line rather than 23.
func _timeline(digest: Array) -> Dictionary:
	var groups: Dictionary = {}
	var order: Array[String] = []
	for raw: Variant in digest:
		if not (raw is Dictionary):
			continue
		var event: Dictionary = raw
		var type_name := str(event.get("type", ""))
		if type_name == "":
			continue
		if not groups.has(type_name):
			groups[type_name] = {
				"type": type_name,
				"class": event_class(event),
				"count": 0,
				"first": event.duplicate(true),
			}
			order.append(type_name)
		var group: Dictionary = groups[type_name]
		group["count"] = int(group["count"]) + 1
		# The worst class any event of this type reached is the one that ranks it.
		var cls := event_class(event)
		if AwayModel._class_rank(cls) < AwayModel._class_rank(str(group["class"])):
			group["class"] = cls
	var rows: Array[Dictionary] = []
	for type_name: String in order:
		var group: Dictionary = groups[type_name]
		rows.append({
			"type": type_name,
			"class": str(group["class"]),
			"count": int(group["count"]),
			"label": _event_label(group["first"] as Dictionary, int(group["count"])),
			"state": AwayModel.class_state(str(group["class"])),
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra := AwayModel._class_rank(str(a["class"]))
		var rb := AwayModel._class_rank(str(b["class"]))
		if ra != rb:
			return ra < rb
		if int(a["count"]) != int(b["count"]):
			return int(a["count"]) > int(b["count"])
		return str(a["type"]) < str(b["type"]))
	var cap := max_timeline_entries()
	var shown := rows.slice(0, cap)
	return {
		"visible": not shown.is_empty(),
		"title": UIWidgets.t(_cfg, "ui_away_timeline"),
		"rows": shown,
		"total": rows.size(),
		"hidden": maxi(0, rows.size() - shown.size()),
		"more_text": UIWidgets.t_args(_cfg, "ui_away_more",
				{"n": rows.size()}) if rows.size() > shown.size() else "",
		"empty_text": UIWidgets.t(_cfg, "ui_away_nothing"),
	}


static func _class_rank(cls: String) -> int:
	match cls:
		CLASS_P1: return 0
		CLASS_P2: return 1
	return 2


static func class_state(cls: String) -> StringName:
	match cls:
		CLASS_P1: return HudModel.STATE_CRITICAL
		CLASS_P2: return HudModel.STATE_WARNING
	return HudModel.STATE_NORMAL


## Copy for one timeline row. An event the alerts table names resolves the same
## `n_<notify_id>_title` key a push would (G-8) so the report and the
## notification say one thing; anything else falls back to the incident kind.
func _event_label(event: Dictionary, count: int) -> String:
	var title := ""
	if _alerts != null:
		var rule := _alerts.rule_for(event)
		var notify_id := str(rule.get("notify_id", ""))
		if notify_id != "" and _cfg != null and _cfg.has_string("n_%s_title" % notify_id):
			title = _cfg.t("n_%s_title" % notify_id, {"count": count,
					"level": event.get("level", 0), "component": event.get("component", ""),
					"block": event.get("block_id", ""), "district": event.get("block_id", "")})
	if title == "" or title.contains("{"):
		var type_name := str(event.get("type", ""))
		var kind_key := "ui_incident_kind_%s" % str(event.get("type_id", event.get(
				"incident_type", event.get("kind", ""))))
		if _cfg != null and _cfg.has_string(kind_key):
			title = _cfg.t(kind_key)
		else:
			title = UIWidgets.t_args(_cfg, "ui_away_event", {"type": type_name})
	if count > 1:
		return "%s %s" % [title, UIWidgets.t_args(_cfg, "ui_alerts_repeat", {"n": count})]
	return title


## §2.12: "Below the threshold with no notable events, a toast (`Away 4m ·
## +$3.1K`) replaces it."
func toast_text(input: Dictionary) -> String:
	var wall_s := maxf(0.0, float(input.get("elapsed_wall_s", 0.0)))
	var before: Dictionary = _block(input, "before")
	var after: Dictionary = _block(input, "after")
	var delta := int(after.get("treasury", 0)) - int(before.get("treasury", 0))
	return UIWidgets.t_args(_cfg, "ui_away_toast", {
		"away": HudModel.eta(int(round(wall_s))),
		"delta": ("%s%s" % [HudModel.PLUS, HudModel.money(delta)]) if delta > 0
				else HudModel.money(delta),
	})


func last_input() -> Dictionary:
	return _input.duplicate(true)
