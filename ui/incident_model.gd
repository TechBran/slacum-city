class_name IncidentModel
extends RefCounted
## The incident drawer's feed (doc 12 §2.6): the live list of what is going wrong
## in the city, sorted the four ways the drawer's segmented control offers.
##
## Ingest is the `AlertsModel` shape — `feed(event)` takes a **sim bus event
## verbatim** (doc 06's `incident_created` / `incident_tier_changed` /
## `incident_assigned` / `incident_resolved` / `incident_failed` /
## `incident_abandoned`, plus doc 06's `unit_dispatched` / `unit_arrived` /
## `unit_returned`), and `feed_batch()` takes a whole `SimEventBus.drain()`. The
## events are the **spine**: they create, retier, assign and retire rows.
##
## Two numbers the drawer needs are not on any event, because doc 06 recomputes
## them continuously rather than announcing them: the escalation countdown and
## the assist ratio. Doc 06 publishes both on `IncidentSystem.snapshot()` — the
## array it wrote *for this drawer* — so this class takes a second, optional
## ingest: `refresh(rows)` merges those live numerics onto the rows the events
## already built, adopts anything the events missed (a loaded save, a UI brought
## up mid-city) and retires anything the sim no longer lists. Feeding events
## alone gives a correct list with no countdown; feeding both gives §2.6's
## "clock the player can read". Neither call needs the other to have happened.
##
## Nothing here holds a sim reference and nothing here is authored English: every
## row resolves `ui_incident_kind_<type>` and the `ui_drawer_*` keys from
## `data/strings.en.json` (G-8), and every threshold comes from `data/ui.json`.
##
## World positions work exactly as they do in `AlertsModel`: the sim speaks in
## tiles, so the shell injects a `locator` — `Callable(kind: StringName, id) ->
## Vector3` called as `(&"tile", Vector2i)` — and a row it cannot place simply
## has no `Jump to it` affordance.

## The four sort orders of §2.6's segmented control.
const SORT_PRIORITY := &"priority"
const SORT_NEAREST := &"nearest"
const SORT_NEWEST := &"newest"
const SORT_UNASSIGNED := &"unassigned"

const SORT_ORDERS: Array[StringName] = [SORT_PRIORITY, SORT_NEAREST, SORT_NEWEST,
		SORT_UNASSIGNED]

## Events that create or edit a row, and events that retire one.
const LIFECYCLE_EVENTS := ["incident_created", "incident_tier_changed",
		"incident_assigned", "incident_resolved", "incident_failed",
		"incident_abandoned", "unit_dispatched", "unit_arrived", "unit_returned"]
const TERMINAL_EVENTS := ["incident_resolved", "incident_failed", "incident_abandoned"]

## `feed()` returns this for an event that is not one of doc 06's.
const NOT_AN_INCIDENT := {}

const _DEFAULT_MAX_ROWS := 40
const _DEFAULT_TIER_PIPS := {"1": "▪", "2": "▴", "3": "▴▴", "4": "◆", "5": "✶"}
const _MINUTES_PER_HOUR := 60.0
const _INFINITY_H := 1.0e18

var _cfg: UIConfig
var _drawer: Dictionary = {}
var _thresholds: Dictionary = {}

var _rows: Dictionary = {}          # incident id:int -> row Dictionary
var _order: Array[int] = []         # insertion order, ascending id after a sort
var _now_h := 0.0
var _locator := Callable()
var _reference := Vector3.ZERO
var _sort: StringName = SORT_PRIORITY
var _selected := 0


func _init(cfg: UIConfig = null) -> void:
	if cfg == null:
		return
	_cfg = cfg
	_drawer = cfg.section("incident_drawer")
	_thresholds = cfg.section("thresholds")
	_sort = default_sort()


static func load_from_files() -> IncidentModel:
	return IncidentModel.new(UIConfig.load_from_files())


func config() -> UIConfig:
	return _cfg


## Doc 06's clock, in game-hours. Row age and the priority comparator's
## `waiting_s` are measured against it; the model never reads a clock itself.
func set_now_h(now_h: float) -> void:
	_now_h = now_h


## `Callable(kind: StringName, id: Variant) -> Variant` — the same seam
## `AlertsModel` uses, called as `(&"tile", Vector2i)`. Anything but a `Vector3`
## reads as "no position", which costs the row its jump affordance and nothing
## else.
func set_locator(locator: Callable) -> void:
	_locator = locator


## Where `nearest` measures from — the camera focus, supplied by the shell.
func set_reference(world_pos: Vector3) -> void:
	_reference = world_pos


func default_sort() -> StringName:
	return StringName(str(_drawer.get("default_sort", String(SORT_PRIORITY))))


func sort_orders() -> Array[StringName]:
	var raw: Variant = _drawer.get("sort_orders", [])
	if not (raw is Array) or (raw as Array).is_empty():
		return SORT_ORDERS.duplicate()
	var out: Array[StringName] = []
	for value: Variant in (raw as Array):
		out.append(StringName(str(value)))
	return out


func sort_order() -> StringName:
	return _sort


func set_sort_order(order: StringName) -> bool:
	if not sort_orders().has(order):
		return false
	_sort = order
	return true


# ---------------------------------------------------------------------------
# Ingest — events are the spine
# ---------------------------------------------------------------------------

## One sim event in; the row it created or edited out, or `{}` when the event is
## not doc 06's. The returned row is the live entry, not a copy.
func feed(event: Dictionary) -> Dictionary:
	var type_name := str(event.get("type", ""))
	if not LIFECYCLE_EVENTS.has(type_name):
		return NOT_AN_INCIDENT
	var incident_id := int(event.get("incident_id", 0))
	# `unit_returned` is the one event with no incident on it — doc 06 emits it
	# from the fleet, which by then has already forgotten which incident the unit
	# was on. So it is addressed by unit id instead, below.
	if incident_id <= 0 and type_name != "unit_returned":
		return NOT_AN_INCIDENT
	if TERMINAL_EVENTS.has(type_name):
		var closing := _rows.get(incident_id, {}) as Dictionary
		_retire(incident_id)
		return closing
	if type_name == "unit_returned":
		return _release_unit(int(event.get("unit_id", 0)))
	var row := _row_for(incident_id, event)
	match type_name:
		"incident_created":
			_apply_created(row, event)
		"incident_tier_changed":
			row["severity"] = float(event.get("severity", row["severity"]))
			row["tier"] = int(event.get("tier", row["tier"]))
		"incident_assigned", "unit_dispatched":
			_add_unit(row, int(event.get("unit_id", 0)))
		"unit_arrived":
			_add_unit(row, int(event.get("unit_id", 0)))
			row["on_scene"] = int(row["on_scene"]) + 1
	_render(row)
	return row


## `unit_returned` names a unit, not an incident, so the row is found by looking
## for whoever has it.
func _release_unit(unit_id: int) -> Dictionary:
	if unit_id <= 0:
		return NOT_AN_INCIDENT
	for incident_id: int in _order:
		var row: Dictionary = _rows[incident_id]
		if not (row["assigned"] as Array).has(unit_id):
			continue
		_drop_unit(row, unit_id)
		_render(row)
		return row
	return NOT_AN_INCIDENT


## A whole `SimEventBus.drain()` batch. Returns only the rows it touched.
func feed_batch(events: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw: Variant in events:
		if not (raw is Dictionary):
			continue
		var row := feed(raw)
		if not row.is_empty():
			out.append(row)
	return out


## Doc 06's `IncidentSystem.snapshot()`, verbatim. This is the *whole* live set:
## a row the array does not carry is terminal and is retired, and a row it
## carries that the events never produced is adopted. Rows keep the fields the
## snapshot does not speak to (the kind glyph, the pin the player just tapped
## before the sim saw it), so calling this never loses UI state.
func refresh(snapshot_rows: Array) -> void:
	var seen: Dictionary = {}
	for raw: Variant in snapshot_rows:
		if not (raw is Dictionary):
			continue
		var record: Dictionary = raw
		var incident_id := int(record.get("id", 0))
		if incident_id <= 0:
			continue
		seen[incident_id] = true
		var row := _row_for(incident_id, {})
		if str(row["kind"]) == "":
			row["created_h"] = _now_h - float(record.get("wait_min", 0.0)) / _MINUTES_PER_HOUR
		row["kind"] = str(record.get("type", row["kind"]))
		row["subtype"] = str(record.get("subtype", row["subtype"]))
		IncidentModel._apply_target(row, record.get("target_ref", null))
		row["tier"] = int(record.get("tier", row["tier"]))
		row["severity"] = float(record.get("severity", row["severity"]))
		row["status"] = str(record.get("status", row["status"]))
		row["district"] = str(record.get("district_id", row["district"]))
		row["assist_ratio"] = float(record.get("assist_ratio", row["assist_ratio"]))
		row["progress"] = float(record.get("progress", row["progress"]))
		row["eta_min"] = float(record.get("escalation_eta_min", -1.0))
		row["priority"] = float(record.get("priority", row["priority"]))
		row["pinned"] = bool(record.get("pinned", row["pinned"]))
		row["acknowledged"] = bool(record.get("seen", row["acknowledged"]))
		row["unreachable"] = bool(record.get("unreachable", false))
		row["wait_min"] = float(record.get("wait_min", row["wait_min"]))
		var pos: Variant = record.get("pos", null)
		if pos is Array and (pos as Array).size() >= 2:
			row["tile"] = Vector2i(int((pos as Array)[0]), int((pos as Array)[1]))
			_resolve_focus(row)
		var assigned: Variant = record.get("assigned", null)
		if assigned is Array:
			var ids: Array[int] = []
			for value: Variant in (assigned as Array):
				ids.append(int(value))
			ids.sort()
			row["assigned"] = ids
		_render(row)
	for incident_id: int in _order.duplicate():
		if not seen.has(incident_id):
			_retire(incident_id)


func _row_for(incident_id: int, event: Dictionary) -> Dictionary:
	var existing: Variant = _rows.get(incident_id, null)
	if existing is Dictionary:
		return existing
	# A row can be born from any of the nine lifecycle events (a save loaded
	# mid-incident replays none of them), so the fields default to "unknown" and
	# `incident_created` / `refresh()` fill them in whenever they arrive.
	var row := {
		"id": incident_id,
		"kind": "",
		"subtype": "",
		# Doc 06's `target_ref`, split into two flat fields. It is what an action
		# on a row acts ON — doc 05 §2.12's isolate/restore needs the main's id,
		# and no other row field carries it.
		"target_kind": "",
		"target_id": "",
		"tier": 1,
		"severity": 1.0,
		"status": "",
		"district": "",
		"tile": Vector2i.ZERO,
		"world_pos": Vector3.ZERO,
		"has_focus": false,
		"assigned": [] as Array[int],
		"on_scene": 0,
		"created_h": _now_h,
		"wait_min": 0.0,
		"assist_ratio": 0.0,
		"progress": 0.0,
		"eta_min": -1.0,
		"priority": 0.0,
		"pinned": false,
		"acknowledged": false,
		"unreachable": false,
		# Rendered, refreshed by `_render`.
		"glyph": "", "title": "", "subtitle": "", "escalation_text": "",
		"age_text": "", "tier_pips": "", "tier_token": "tier1",
		"escalation01": 0.0, "held": false, "has_clock": false,
		"escalation_state": HudModel.STATE_NORMAL,
		"state": HudModel.STATE_NORMAL, "state_glyph": "",
		"assigned_count": 0, "age_min": 0.0, "selected": false,
	}
	_rows[incident_id] = row
	_order.append(incident_id)
	_order.sort()
	_trim()
	return row


## **The kind is `incident_type`, never `type`.** `IncidentSystem._emit()` stamps
## `event["type"] = <bus event name>` over whatever the payload had there, so an
## incident that named its own kind in `type` lost it on the way out. Doc 06 now
## names the field `incident_type` on the whole lifecycle (`incident_created` /
## `tier_changed` / `resolved` / `failed` / `abandoned`) — doc 92 pass-2 ruling 8,
## pre-1.0, no compatibility key. The two fallbacks below are for hand-built
## fixtures and for the `refresh()` snapshot rows, which key it as `type` because
## a snapshot row is not a bus event.
func _apply_created(row: Dictionary, event: Dictionary) -> void:
	row["kind"] = str(event.get("incident_type",
			event.get("type_id", event.get("kind", ""))))
	row["subtype"] = str(event.get("subtype", ""))
	IncidentModel._apply_target(row, event.get("target_ref", null))
	row["severity"] = float(event.get("severity", 1.0))
	row["tier"] = int(event.get("tier", HudModel.incident_tier(row["severity"])))
	row["district"] = str(event.get("district_id", ""))
	row["created_h"] = float(event.get("at_h", _now_h))
	var tile: Variant = event.get("tile", null)
	if tile is Array and (tile as Array).size() >= 2:
		row["tile"] = Vector2i(int((tile as Array)[0]), int((tile as Array)[1]))
	elif tile is Vector2i:
		row["tile"] = tile
	_resolve_focus(row)


## `{kind, id}` → the row's two flat fields. A `null` (an event or a fixture that
## does not carry one) leaves whatever the row already had, so a lifecycle event
## after `incident_created` never blanks the target the create supplied.
static func _apply_target(row: Dictionary, target: Variant) -> void:
	if not (target is Dictionary):
		return
	var ref: Dictionary = target
	row["target_kind"] = str(ref.get("kind", row["target_kind"]))
	row["target_id"] = str(ref.get("id", row["target_id"]))


func _add_unit(row: Dictionary, unit_id: int) -> void:
	if unit_id <= 0:
		return
	var ids: Array[int] = row["assigned"]
	if ids.has(unit_id):
		return
	ids.append(unit_id)
	ids.sort()


func _drop_unit(row: Dictionary, unit_id: int) -> void:
	var ids: Array[int] = row["assigned"]
	var at := ids.find(unit_id)
	if at >= 0:
		ids.remove_at(at)
	row["on_scene"] = maxi(0, int(row["on_scene"]) - 1)


func _retire(incident_id: int) -> void:
	_rows.erase(incident_id)
	var at := _order.find(incident_id)
	if at >= 0:
		_order.remove_at(at)
	if _selected == incident_id:
		_selected = 0


## Bounded like the alerts feed: a storm cascade cannot grow the drawer forever.
## The lowest-tier oldest row goes first, so a T5 is never the one dropped.
func _trim() -> void:
	var cap := maxi(1, UIConfig.get_int(_drawer, "max_rows", _DEFAULT_MAX_ROWS))
	while _order.size() > cap:
		var victim := _order[0]
		var worst := 6
		for incident_id: int in _order:
			var row: Dictionary = _rows[incident_id]
			if int(row["tier"]) < worst:
				worst = int(row["tier"])
				victim = incident_id
		_retire(victim)


func _resolve_focus(row: Dictionary) -> void:
	if not _locator.is_valid():
		return
	var world: Variant = _locator.call(&"tile", row["tile"])
	if world is Vector3:
		row["world_pos"] = world
		row["has_focus"] = true


# ---------------------------------------------------------------------------
# Derived values (doc 12 §2.6) — the escalation bar and the tier badge
# ---------------------------------------------------------------------------

## §2.6: `fill = severity − tier`, the fraction of the way to the next tier.
static func escalation_fill(severity: float, tier: int) -> float:
	return clampf(severity - float(tier), 0.0, 1.0)


## §2.6: "When `assist_ratio ≥ 1` the denominator is 0: the bar freezes, turns
## NORMAL green, its glyph becomes `●` and the label reads **HELD**."
##
## HELD is a statement about the *city* — enough units are on scene — so it is
## read from `assist_ratio` alone. A row with no countdown yet (events only, no
## snapshot) is **not** held: it is a T4 fire nobody has measured, and colouring
## it green would be the single worst lie this screen could tell.
func is_held(assist_ratio: float) -> bool:
	var gate := UIConfig.get_num(_thresholds, "escalation_bar_held_when_assist_ratio_ge", 1.0)
	return assist_ratio >= gate


## §2.6: "Below 25 % of remaining time (or under 0.25 tiers to go) the bar takes
## CRITICAL styling." HELD is always NORMAL — that is the whole point of it.
func escalation_state(fill: float, held: bool) -> StringName:
	if held:
		return HudModel.STATE_NORMAL
	var margin := UIConfig.get_num(_thresholds,
			"escalation_bar_critical_remaining_tiers", 0.25)
	if 1.0 - fill <= margin:
		return HudModel.STATE_CRITICAL
	return HudModel.STATE_WARNING


## A5: the tier digit is the primary redundancy channel and the glyph reinforces
## it, so the badge never needs colour to be read.
func tier_pips(tier: int) -> String:
	var raw: Variant = _drawer.get("tier_glyphs", _DEFAULT_TIER_PIPS)
	var glyphs: Dictionary = raw if raw is Dictionary else _DEFAULT_TIER_PIPS
	return str(glyphs.get(str(clampi(tier, 1, 5)), ""))


static func tier_token(tier: int) -> StringName:
	return StringName("tier%d" % clampi(tier, 1, 5))


func _render(row: Dictionary) -> void:
	var tier := clampi(int(row["tier"]), 1, 5)
	row["tier"] = tier
	var fill := IncidentModel.escalation_fill(float(row["severity"]), tier)
	var held := is_held(float(row["assist_ratio"]))
	var has_clock := float(row["eta_min"]) >= 0.0
	row["escalation01"] = fill
	row["held"] = held
	row["has_clock"] = has_clock
	row["escalation_state"] = escalation_state(fill, held)
	row["tier_pips"] = tier_pips(tier)
	row["tier_token"] = IncidentModel.tier_token(tier)
	row["glyph"] = kind_glyph(str(row["kind"]))
	row["title"] = kind_label(str(row["kind"]))
	row["state"] = _state_for(tier, held)
	row["state_glyph"] = _state_glyph(row["state"])
	row["assigned_count"] = (row["assigned"] as Array).size()
	row["age_min"] = maxf(0.0, (_now_h - float(row["created_h"])) * _MINUTES_PER_HOUR)
	row["age_text"] = _t("ui_drawer_age",
			{"age": HudModel.eta(int(round(float(row["age_min"]) * 60.0)))})
	row["subtitle"] = _subtitle(row)
	# The hole rule again: with no countdown the row says nothing about one
	# rather than printing `T4 in 0:00`.
	if held:
		row["escalation_text"] = _t("ui_drawer_held")
	elif has_clock:
		row["escalation_text"] = _t("ui_drawer_next_tier",
				{"tier": mini(tier + 1, 5),
						"eta": HudModel.eta(int(round(float(row["eta_min"]) * 60.0)))})
	else:
		row["escalation_text"] = ""


## The four data states, per row — the HUD chip's own incident banding (§2.4 P2:
## T4+ CRITICAL, T3 WARNING, below that NORMAL), so the chip and the drawer can
## never disagree about what a T3 means. HELD is NORMAL whatever the tier.
func _state_for(tier: int, held: bool) -> StringName:
	if held:
		return HudModel.STATE_NORMAL
	if tier >= 4:
		return HudModel.STATE_CRITICAL
	if tier == 3:
		return HudModel.STATE_WARNING
	return HudModel.STATE_NORMAL


func _state_glyph(state: StringName) -> String:
	var glyphs := _cfg.section("state_glyphs") if _cfg != null else {}
	return str(HudModel.STATE_GLYPH_CHARS.get(str(glyphs.get(String(state), "")), ""))


## The hole rule, same as the alerts feed: a district the sim did not name is
## dropped rather than rendered as `{district}`.
func _subtitle(row: Dictionary) -> String:
	var district := str(row["district"])
	var count := (row["assigned"] as Array).size()
	if district == "":
		return _t("ui_drawer_row_units", {"units": count}) if count > 0 \
				else _t("ui_drawer_row_no_units")
	if count > 0:
		return _t("ui_drawer_row_where", {"district": district, "units": count})
	return _t("ui_drawer_row_unassigned", {"district": district})


func kind_glyph(kind: String) -> String:
	var raw: Variant = _drawer.get("kind_glyphs", {})
	var glyphs: Dictionary = raw if raw is Dictionary else {}
	return str(glyphs.get(kind, str(glyphs.get("unknown", ""))))


func kind_label(kind: String) -> String:
	var key := "ui_incident_kind_%s" % kind
	if _cfg != null and _cfg.has_string(key):
		return _cfg.t(key)
	return _t("ui_incident_kind_unknown")


func _t(key: String, args: Dictionary = {}) -> String:
	return UIWidgets.t_args(_cfg, key, args) if not args.is_empty() \
			else UIWidgets.t(_cfg, key)


# ---------------------------------------------------------------------------
# Read side
# ---------------------------------------------------------------------------

## The drawer's list, in the current sort order. Rows are copies — the view may
## not edit the feed.
func rows(order: StringName = &"") -> Array[Dictionary]:
	var wanted := order if order != &"" else _sort
	var ids := _order.duplicate()
	match wanted:
		SORT_NEAREST:
			ids.sort_custom(_compare_nearest)
		SORT_NEWEST:
			ids.sort_custom(_compare_newest)
		SORT_UNASSIGNED:
			ids.sort_custom(_compare_unassigned)
		_:
			ids.sort_custom(_compare_priority)
	var out: Array[Dictionary] = []
	for incident_id: int in ids:
		var row: Dictionary = (_rows[incident_id] as Dictionary).duplicate(true)
		row["selected"] = incident_id == _selected
		out.append(row)
	return out


## §2.6's `Priority` comparator, verbatim:
##
##     key(i) = ( -tier, t_next_tier_h (INF when HELD), -waiting_s, id )
##     unassigned incidents sort before assigned ones of equal tier
func _compare_priority(a_id: int, b_id: int) -> bool:
	var a: Dictionary = _rows[a_id]
	var b: Dictionary = _rows[b_id]
	if int(a["tier"]) != int(b["tier"]):
		return int(a["tier"]) > int(b["tier"])
	var a_assigned := 1 if (a["assigned"] as Array).size() > 0 else 0
	var b_assigned := 1 if (b["assigned"] as Array).size() > 0 else 0
	if a_assigned != b_assigned:
		return a_assigned < b_assigned
	var a_next := _next_tier_h(a)
	var b_next := _next_tier_h(b)
	if not is_equal_approx(a_next, b_next):
		return a_next < b_next
	var a_wait := float(a["wait_min"])
	var b_wait := float(b["wait_min"])
	if not is_equal_approx(a_wait, b_wait):
		return a_wait > b_wait
	return a_id < b_id


func _next_tier_h(row: Dictionary) -> float:
	var eta := float(row["eta_min"])
	if eta < 0.0 or bool(row["held"]):
		return _INFINITY_H
	return eta / _MINUTES_PER_HOUR


func _compare_nearest(a_id: int, b_id: int) -> bool:
	var a: Dictionary = _rows[a_id]
	var b: Dictionary = _rows[b_id]
	var da := (a["world_pos"] as Vector3).distance_squared_to(_reference)
	var db := (b["world_pos"] as Vector3).distance_squared_to(_reference)
	if not is_equal_approx(da, db):
		return da < db
	return a_id < b_id


func _compare_newest(a_id: int, b_id: int) -> bool:
	var a: Dictionary = _rows[a_id]
	var b: Dictionary = _rows[b_id]
	if not is_equal_approx(float(a["created_h"]), float(b["created_h"])):
		return float(a["created_h"]) > float(b["created_h"])
	return a_id > b_id


func _compare_unassigned(a_id: int, b_id: int) -> bool:
	var a_assigned := 1 if (_rows[a_id]["assigned"] as Array).size() > 0 else 0
	var b_assigned := 1 if (_rows[b_id]["assigned"] as Array).size() > 0 else 0
	if a_assigned != b_assigned:
		return a_assigned < b_assigned
	return _compare_priority(a_id, b_id)


func row(incident_id: int) -> Dictionary:
	var found: Variant = _rows.get(incident_id, null)
	return (found as Dictionary).duplicate(true) if found is Dictionary else {}


func has(incident_id: int) -> bool:
	return _rows.has(incident_id)


func size() -> int:
	return _order.size()


func unassigned_count() -> int:
	var count := 0
	for incident_id: int in _order:
		if (_rows[incident_id]["assigned"] as Array).is_empty():
			count += 1
	return count


func unacknowledged_count() -> int:
	var count := 0
	for incident_id: int in _order:
		if not bool(_rows[incident_id]["acknowledged"]):
			count += 1
	return count


func worst_tier() -> int:
	var worst := 0
	for incident_id: int in _order:
		worst = maxi(worst, int(_rows[incident_id]["tier"]))
	return worst


## §2.6: the handle "Pulses at 1.2 Hz while any T4/T5 incident is unassigned."
func handle_pulses() -> bool:
	for incident_id: int in _order:
		var row: Dictionary = _rows[incident_id]
		if int(row["tier"]) >= 4 and (row["assigned"] as Array).is_empty():
			return true
	return false


## What the collapsed handle shows: the count, the worst-tier digit and the
## state the fill takes. Empty count reads OFFLINE, which is the fourth state
## doing its job rather than the handle vanishing.
func handle_view() -> Dictionary:
	var count := size()
	var worst := worst_tier()
	return {
		"count": count,
		"worst_tier": worst,
		"text": str(count),
		"digit": str(worst) if worst > 0 else "",
		"tier_token": IncidentModel.tier_token(worst) if worst > 0 else &"offline",
		"state": _state_for(worst, false) if count > 0 else HudModel.STATE_OFFLINE,
		"pulse": handle_pulses(),
		"tooltip": _t("ui_drawer_count", {"n": count}),
	}


## The `HudModel.build_view` incident block, straight off this feed, so the chip
## and the drawer are one number.
func hud_incidents() -> Dictionary:
	return {"count": size(), "worst_tier": worst_tier()}


## The §2.15 marker list: `[{id, position: Vector3, tier}]`, ready for
## `HudModel.project_markers()`.
func markers() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for incident_id: int in _order:
		var row: Dictionary = _rows[incident_id]
		if not bool(row["has_focus"]):
			continue
		out.append({"id": str(incident_id), "position": row["world_pos"],
				"tier": int(row["tier"])})
	return out


# ---------------------------------------------------------------------------
# Selection and the optimistic flags
# ---------------------------------------------------------------------------

func selected_id() -> int:
	return _selected


func select(incident_id: int) -> Dictionary:
	if not _rows.has(incident_id):
		_selected = 0
		return {}
	_selected = incident_id
	return row(incident_id)


func clear_selection() -> void:
	_selected = 0


## The two flags the player can flip faster than the sim answers. Both are
## written here optimistically and overwritten by the next `refresh()`, which is
## the sim's word — so a failed command self-corrects within a frame.
func set_pinned(incident_id: int, pinned: bool) -> bool:
	if not _rows.has(incident_id):
		return false
	(_rows[incident_id] as Dictionary)["pinned"] = pinned
	return true


func set_acknowledged(incident_id: int, acknowledged: bool = true) -> bool:
	if not _rows.has(incident_id):
		return false
	(_rows[incident_id] as Dictionary)["acknowledged"] = acknowledged
	return true


## What the view needs to emit `focus_requested(world_pos)`, and the id the
## dispatch commands take.
func focus_payload(incident_id: int) -> Dictionary:
	var found: Variant = _rows.get(incident_id, null)
	if not (found is Dictionary):
		return {}
	var record: Dictionary = found
	return {
		"id": incident_id,
		"has_focus": bool(record["has_focus"]),
		"world_pos": record["world_pos"],
		"tile": record["tile"],
		"tier": int(record["tier"]),
		"kind": str(record["kind"]),
		"title": str(record["title"]),
	}


func clear() -> void:
	_rows.clear()
	_order.clear()
	_selected = 0
