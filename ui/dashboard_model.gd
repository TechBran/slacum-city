class_name DashboardModel
extends RefCounted
## The city dashboard (doc 12 §2.10, S8): the city's vitals as 48 dp bands with a
## sparkline each, plus the full-size chart behind whichever band is selected.
##
## Everything the Overview shows is already computed somewhere: `HudModel` owns
## the number formats, the thresholds and the four data states, and `HistoryModel`
## owns the ring the sparklines are drawn from. This class only decides which
## rows exist, in what order, and which series each one reads — so a band and its
## HUD chip can never disagree about whether the treasury is in trouble.
##
## The Economy tab is `BudgetModel`'s; this class carries it so the dashboard has
## one model to bind rather than two.
##
## Input is the same plain snapshot `HudModel.build_view()` takes, so the shell
## builds it once per refresh and hands it to both.

const TAB_OVERVIEW := &"overview"
const TAB_ECONOMY := &"economy"
const TAB_INFRASTRUCTURE := &"infrastructure"
const TAB_RESPONSE := &"response"

const _DEFAULT_TABS: Array[String] = ["overview", "economy", "infrastructure",
		"response"]
const _DEFAULT_WORST_N := 5
const _DEFAULT_DEPARTMENTS: Array[String] = ["fire", "police", "utility", "water",
		"construction"]
const _DEFAULT_INFRA_SECTIONS: Array[String] = ["power", "feeders", "transformers",
		"water"]
const _DEFAULT_TARGET_MIN := 8.0
const _DEFAULT_WARN_MULT := 1.25
const _DEFAULT_ROWS: Array[String] = ["population", "treasury", "net_income",
		"happiness", "stability", "grid", "water", "incidents"]
const _DEFAULT_SPARK_HOURS := 24
const _DEFAULT_CHART_HOURS := 168

## Row id → the `HistoryModel` series it charts. A row with no series (incidents)
## still gets its band and its value; it just has no line.
const ROW_SERIES := {
	"population": "population",
	"treasury": "treasury",
	"net_income": "net_per_hour",
	"happiness": "happiness",
	"stability": "stability",
	"grid": "power01",
	"water": "water01",
	"incidents": "",
}

## Row id → the deep link §2.10 gives it ("tapping a row deep-links (Grid → power
## overlay + close; Active incidents → drawer)"). `""` means the row only selects
## its chart, which is the right answer for a vital whose whole story is the
## chart underneath it.
const ROW_DEEPLINK := {
	"grid": "overlay/power",
	"water": "overlay/water",
	"incidents": "drawer",
}

## Which tab a row's *chip* opens (§2.10 puts the money on Economy). Kept apart
## from `ROW_DEEPLINK` on purpose: a chip tap arrives from outside the dashboard
## and may rebuild it, while a row tap arrives from a button inside the very
## container a rebuild would free.
const ROW_TAB := {
	"treasury": TAB_ECONOMY,
	"net_income": TAB_ECONOMY,
}

var history: HistoryModel
var budget: BudgetModel

var _cfg: UIConfig
var _dashboard: Dictionary = {}
var _hud: HudModel
var _tab: StringName = TAB_OVERVIEW
var _selected_row := ""
## The two feeds the shell publishes for the tabs that read a live system rather
## than the history ring. Both default to empty, and an empty feed is a tab that
## says so in words (A14) rather than a tab of zeroes.
var _infrastructure: Dictionary = {}
var _response: Dictionary = {}
## The Upkeep band's sim-side half: `CitySim.cmd_repair_all_worn(preview)`'s
## payload and `CitySim.building_repair_policy()`. Empty until the shell feeds
## it, and an empty feed draws the band with the loss half only — which is still
## the whole of PA-31 and is exactly what a shell that has not bound the batch
## verb should show.
var _upkeep: Dictionary = {}


func _init(cfg: UIConfig = null, p_history: HistoryModel = null,
		p_budget: BudgetModel = null) -> void:
	if cfg == null:
		return
	_cfg = cfg
	_dashboard = cfg.section("dashboard")
	_hud = HudModel.new(cfg)
	history = p_history if p_history != null else HistoryModel.new(cfg)
	budget = p_budget if p_budget != null else BudgetModel.new(cfg)
	var rows := row_ids()
	_selected_row = rows[0] if not rows.is_empty() else ""


static func load_from_files() -> DashboardModel:
	return DashboardModel.new(UIConfig.load_from_files())


func config() -> UIConfig:
	return _cfg


## `{power01, water01}` on `[0, 1]`, exactly as `HudModel.ingest_service` takes
## them. The Grid and Water bands are the same reading as the ⚡/💧 chips and must
## not be able to disagree with them, so both models are fed from one shell call.
func ingest_service(snapshot: Dictionary) -> void:
	if _hud != null:
		_hud.ingest_service(snapshot)


# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

func tab_ids() -> Array[String]:
	return _string_list("tabs", _DEFAULT_TABS)


func row_ids() -> Array[String]:
	return _string_list("overview_rows", _DEFAULT_ROWS)


func _string_list(field: String, fallback: Array[String]) -> Array[String]:
	var raw: Variant = _dashboard.get(field, [])
	if not (raw is Array) or (raw as Array).is_empty():
		return fallback.duplicate()
	var out: Array[String] = []
	for value: Variant in (raw as Array):
		out.append(str(value))
	return out


func tabs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for tab_id: String in tab_ids():
		out.append({
			"id": StringName(tab_id),
			"label": UIWidgets.t(_cfg, "ui_dashboard_tab_%s" % tab_id),
			"selected": StringName(tab_id) == _tab,
		})
	return out


func tab() -> StringName:
	return _tab


func set_tab(tab_id: StringName) -> bool:
	if not tab_ids().has(String(tab_id)):
		return false
	_tab = tab_id
	return true


func selected_row() -> String:
	return _selected_row


func select_row(row_id: String) -> bool:
	if not row_ids().has(row_id):
		return false
	_selected_row = row_id
	return true


## Which band a HUD chip opens (`CityHUD.chip_activated` → "S8 dashboard,
## scrolled to it"). The chip ids and the row ids are deliberately near-identical;
## the two that differ are mapped here rather than being renamed on either side.
func row_for_chip(chip_id: StringName) -> String:
	var name := String(chip_id)
	if row_ids().has(name):
		return name
	if name == "grid" or name == "power":
		return "grid"
	var rows := row_ids()
	return rows[0] if not rows.is_empty() else ""


func spark_hours() -> int:
	return maxi(2, UIConfig.get_int(_dashboard, "spark_hours", _DEFAULT_SPARK_HOURS))


func chart_hours() -> int:
	return maxi(2, UIConfig.get_int(_dashboard, "chart_hours", _DEFAULT_CHART_HOURS))


# ---------------------------------------------------------------------------
# The view
# ---------------------------------------------------------------------------

## `snapshot` is `HudModel.build_view()`'s, verbatim. Returns
## `{tab, tabs, rows, chart, budget}`; `rows` is the Overview, `chart` the
## full-size line for the selected row, `budget` the Economy ledger.
func build_view(snapshot: Dictionary) -> Dictionary:
	var chips := _hud.chip_values(snapshot)
	var rows: Array[Dictionary] = []
	for row_id: String in row_ids():
		rows.append(_row(row_id, snapshot, chips))
	return {
		"tab": _tab,
		"tabs": tabs(),
		"rows": rows,
		"chart": chart(_selected_row),
		"budget": budget.breakdown(),
		"upkeep": upkeep_view(),
		"selected_row": _selected_row,
		"history_size": history.size(),
		"infrastructure": infrastructure_view(),
		"response": response_view(),
	}


# ---------------------------------------------------------------------------
# The Upkeep band (99-PA PA-31 + PA-33, doc 98 RR-149/RR-150)
#
# The audit's target for PA-31, in its own words: *whenever city-wide
# `f_condition < 0.95` the lost $/gh and the repair total are on one screen*.
# This is that screen. The band is three readings and one button:
#
#   1. **what wear costs**, per settled hour and per game-day, off doc 03's own
#      per-building rows (`BudgetModel.condition_loss`);
#   2. **how much of the taxed stock is below Good**, which is the subject of the
#      sentence and never the sentence itself;
#   3. **what the city's own repairable stock would cost to put right**, which is
#      a DIFFERENT and smaller set — doc 93 §Y1 means the city cannot buy a
#      private repair at any price, and a band that quoted one would be offering
#      a purchase that does not exist;
#   4. the button that buys (3), and the policy that would buy it every game-day
#      without being asked again.
# ---------------------------------------------------------------------------

## `{quote, policy, balance}` — `CitySim.cmd_repair_all_worn(true)`'s payload,
## `CitySim.building_repair_policy()`, and the treasury balance the button's
## affordability is judged against. The shell is the only holder of a sim, so the
## shell is the only thing that can fill this; this model still computes no
## engineering and prices nothing.
func feed_upkeep(snapshot: Dictionary) -> void:
	_upkeep = snapshot.duplicate(true)


func has_upkeep() -> bool:
	return not _upkeep.is_empty()


func upkeep_view() -> Dictionary:
	var loss := budget.condition_loss()
	var quote: Dictionary = _upkeep.get("quote", {})
	var policy: Dictionary = _upkeep.get("policy", {})
	var lost := float(loss["tax_lost_per_hour"])
	var count := int(quote.get("count", 0))
	var cost := int(quote.get("cost", 0))
	var balance := float(_upkeep.get("balance", 0.0))
	var view := {
		"has_data": bool(loss["has_data"]) or not quote.is_empty(),
		"title": UIWidgets.t(_cfg, "ui_dashboard_upkeep_title"),
		"loss_label": UIWidgets.t(_cfg, "ui_dashboard_upkeep_loss"),
		# The minus is the reading: this is money the city is NOT collecting.
		"loss_text": HudModel.money_signed(-int(round(lost))),
		"loss_per_day_text": HudModel.rate_per_day(-lost),
		"loss_state": HudModel.STATE_WARNING if lost > 0.0 else HudModel.STATE_NORMAL,
		"worn_text": UIWidgets.t_args(_cfg, "ui_dashboard_upkeep_worn",
				{"count": int(loss["worn"]), "total": int(loss["counted"])}),
		"tax_lost_per_hour": lost,
		"worn": int(loss["worn"]),
		"counted": int(loss["counted"]),
		"f_condition_mean": float(loss["f_condition_mean"]),
		"repair_count": count,
		"repair_cost": cost,
		# A button with nothing behind it is drawn as words, not as a dead
		# control (A14): "Nothing the city owns needs repair."
		"can_repair": count > 0 and float(cost) <= balance,
		"repair_text": UIWidgets.t_args(_cfg, "ui_dashboard_upkeep_repair",
				{"count": count, "amount": HudModel.money_exact(cost)}),
		"none_text": UIWidgets.t(_cfg, "ui_dashboard_upkeep_none"),
		"has_repair": count > 0,
		"unaffordable": count > 0 and float(cost) > balance,
	}
	view["policy_text"] = _upkeep_policy_text(policy)
	view.merge(_upkeep_policy_control(policy))
	return view


## What the city's standing auto-repair decision says, in one line. `off` is not
## a state to be ashamed of and is the shipped default (doc 98 RR-150), so it
## reads as a setting rather than as a warning.
func _upkeep_policy_text(policy: Dictionary) -> String:
	if policy.is_empty() or not bool(policy.get("enabled", false)):
		return UIWidgets.t(_cfg, "ui_dashboard_upkeep_policy_off")
	return UIWidgets.t_args(_cfg, "ui_dashboard_upkeep_policy_on", {
		"percent": HudModel.percent_text(
				float(policy.get("building_repair_threshold", 0.0)) * 100.0),
		"amount": HudModel.money_exact(int(policy.get("building_repair_daily_cap", 0))),
	})


## The DOOR for `CitySim.cmd_set_building_repair_policy` (99-PA PA-33, doc 98
## RR-150a). Two cycling faces, one per dial, and both ladders are the sim's —
## `building_repair_policy()` publishes `thresholds` (doc 02 §2.6's own band
## table, resolved off a real building's stamped rules) and `daily_caps` (doc 03
## `AUTO_REPAIR_DAILY_CAPS`). This model picks NO rung and authors NO dollar; it
## only says which rung is standing and what the next one would read as.
##
## A cycling ladder rather than a slider is A3: doc 03's caps are detents and a
## drag cannot land on one. `has_policy_control` is false when the shell has not
## bound the verb — the ladders arrive with the policy dictionary or not at all —
## and the band then draws `policy_text` as a sentence, which is the read-only
## contract `bind_upkeep` already documents.
func _upkeep_policy_control(policy: Dictionary) -> Dictionary:
	var bands: Array = policy.get("thresholds", [])
	var caps: Array = policy.get("daily_caps", [])
	var band := float(policy.get("building_repair_threshold", 0.0))
	var cap := int(policy.get("building_repair_daily_cap", 0))
	return {
		"has_policy_control": not bands.is_empty() and not caps.is_empty(),
		"policy_bands": bands,
		"policy_caps": caps,
		"policy_band": band,
		"policy_cap": cap,
		"policy_band_index": _ladder_index(bands, band),
		"policy_cap_index": _ladder_index(caps, cap),
		"policy_band_text": _upkeep_band_text(band),
		"policy_cap_text": _upkeep_cap_text(cap),
		# Doc 03's own default, forwarded untouched. `CityDashboard` spends it on
		# the one transition that needs a budget it does not yet have — `off` to a
		# live rung — so switching the policy on switches it on WITH something.
		"policy_default_cap": int(policy.get("default_daily_cap", 0)),
	}


## Where `value` sits on `ladder`, or `0` when it sits nowhere. Floats are
## compared with the same 1e-6 tolerance `cmd_set_building_repair_policy` matches
## its rungs with, so a control can never disagree with the command about which
## rung is standing.
static func _ladder_index(ladder: Array, value: Variant) -> int:
	for i in ladder.size():
		if absf(float(ladder[i]) - float(value)) < 1e-6:
			return i
	return 0


## `off` / `below 85%` — the same words and the same percent the standing
## sentence above the control uses, because two vocabularies for one dial is how
## a player ends up believing there are two dials.
func _upkeep_band_text(band: float) -> String:
	if band <= 0.0:
		return UIWidgets.t(_cfg, "ui_dashboard_upkeep_policy_band_off")
	return UIWidgets.t_args(_cfg, "ui_dashboard_upkeep_policy_band",
			{"percent": HudModel.percent_text(band * 100.0)})


## `no budget` / `$10,000/day`. Zero gets words rather than `$0/day` for the
## reason RR-150's zero-budget rule exists: a budget of nothing is a decision
## the player made, and it reads as one.
func _upkeep_cap_text(cap: int) -> String:
	if cap <= 0:
		return UIWidgets.t(_cfg, "ui_dashboard_upkeep_policy_cap_none")
	return UIWidgets.t_args(_cfg, "ui_dashboard_upkeep_policy_cap",
			{"amount": HudModel.money_exact(cap)})


# ---------------------------------------------------------------------------
# Infrastructure (§2.10: "power gen/cap/load + worst 5 feeders, water
# supply/demand + worst 5 zones")
# ---------------------------------------------------------------------------

func worst_n() -> int:
	return maxi(1, UIConfig.get_int(_dashboard, "worst_n", _DEFAULT_WORST_N))


## The shell's one call per refresh:
##
##     {power:   PowerGrid.capacity_summary(),
##      feeders: PowerGrid.feeder_rows(),
##      transformers: PowerGrid.transformer_rows(),
##      water:   WaterSnapshot.build(...)}
##
## Rows are consumed exactly as those queries publish them — this model sorts and
## trims and formats, and computes no engineering of its own.
func feed_infrastructure(snapshot: Dictionary) -> void:
	_infrastructure = snapshot.duplicate(true)


func has_infrastructure() -> bool:
	return not _infrastructure.is_empty()


func infrastructure_view() -> Dictionary:
	var sections: Array[Dictionary] = []
	for section_id: String in _string_list("infrastructure_sections",
			_DEFAULT_INFRA_SECTIONS):
		match section_id:
			"power":
				sections.append(_power_section())
			"feeders":
				sections.append(_line_section("feeders", "feeders",
						"ui_dashboard_infra_feeders_title"))
			"transformers":
				sections.append(_line_section("transformers", "transformers",
						"ui_dashboard_infra_transformers_title"))
			"water":
				sections.append(_water_section())
	return {"sections": _with_glyphs(sections), "has_data": has_infrastructure()}


## A5: every state-coloured figure also carries its glyph, so the tab is legible
## in greyscale exactly like the HUD chips. Done in one pass here rather than in
## each row builder — the glyph is a property of the state, never of the row.
func _with_glyphs(sections: Array[Dictionary]) -> Array[Dictionary]:
	for section: Dictionary in sections:
		for value: Variant in (section["rows"] as Array):
			var row: Dictionary = value
			row["state_glyph"] = _hud.state_glyph(StringName(str(row.get("state", ""))))
	return sections


func _power_section() -> Dictionary:
	var power: Variant = _infrastructure.get("power", {})
	var rows: Array[Dictionary] = []
	if power is Dictionary and not (power as Dictionary).is_empty():
		var block: Dictionary = power
		var supply := UIConfig.get_num(block, "supply_kw", 0.0)
		var demand := UIConfig.get_num(block, "demand_kw", 0.0)
		var headroom := UIConfig.get_num(block, "headroom_kw", supply - demand)
		var ratio := UIConfig.get_num(block, "load_ratio", 0.0)
		rows.append(_figure("supply", "ui_dashboard_infra_supply", power_text(supply),
				HudModel.STATE_NORMAL))
		rows.append(_figure("demand", "ui_dashboard_infra_demand",
				"%s  %s" % [power_text(demand), HudModel.percent_text(ratio * 100.0)],
				load_state(ratio)))
		rows.append(_figure("headroom", "ui_dashboard_infra_headroom",
				power_text(headroom),
				HudModel.STATE_CRITICAL if headroom <= 0.0 else HudModel.STATE_NORMAL))
		var over := UIConfig.get_int(block, "feeders_over", 0) \
				+ UIConfig.get_int(block, "transformers_over", 0)
		rows.append(_figure("over", "ui_dashboard_infra_over", str(over),
				HudModel.STATE_NORMAL if over == 0 else HudModel.STATE_WARNING))
		var shed := UIConfig.get_int(block, "shed_feeders", 0)
		rows.append(_figure("shed", "ui_dashboard_infra_shed", str(shed),
				HudModel.STATE_NORMAL if shed == 0 else HudModel.STATE_CRITICAL))
	return {
		"id": "power",
		"title": UIWidgets.t(_cfg, "ui_dashboard_infra_power_title"),
		"rows": rows,
		"empty_text": UIWidgets.t(_cfg, "ui_dashboard_no_grid"),
	}


## One feeder / transformer list, worst-first. "Worst" is the load ratio against
## the DERATED capacity — the number the protection pass trips on — with the id
## as the tiebreak so two equally loaded feeders never swap places between two
## refreshes of the same state.
func _line_section(section_id: String, feed_key: String,
		title_key: String) -> Dictionary:
	var raw: Variant = _infrastructure.get(feed_key, [])
	var source: Array = raw if raw is Array else []
	var sorted: Array = source.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra := UIConfig.get_num(a, "load_ratio", 0.0)
		var rb := UIConfig.get_num(b, "load_ratio", 0.0)
		if not is_equal_approx(ra, rb):
			return ra > rb
		return str(a.get("id", "")) < str(b.get("id", "")))
	var rows: Array[Dictionary] = []
	for value: Variant in sorted:
		if rows.size() >= worst_n():
			break
		if not (value is Dictionary):
			continue
		rows.append(_line_row(value as Dictionary))
	return {
		"id": section_id,
		"title": UIWidgets.t_args(_cfg, title_key, {"count": rows.size()}),
		"rows": rows,
		"empty_text": UIWidgets.t(_cfg, "ui_dashboard_no_grid"),
	}


func _line_row(row: Dictionary) -> Dictionary:
	var ratio := UIConfig.get_num(row, "load_ratio", 0.0)
	var customers := UIConfig.get_int(row, "customers", 0)
	var detail := UIWidgets.t_args(_cfg, "ui_dashboard_infra_customers",
			{"count": customers})
	var state := load_state(ratio)
	# A component that is OPEN or FAILED is not "lightly loaded", it is out — the
	# load ratio of a dead feeder is 0 and would otherwise read NORMAL.
	if not bool(row.get("energized", true)) or str(row.get("state", "OK")) != "OK":
		state = HudModel.STATE_OFFLINE
	elif bool(row.get("shed", false)):
		state = HudModel.STATE_CRITICAL
	return {
		"id": str(row.get("id", "")),
		"label": str(row.get("id", "")),
		"value": "%s  %s" % [HudModel.percent_text(ratio * 100.0),
				power_text(UIConfig.get_num(row, "headroom_kw", 0.0))],
		"detail": detail,
		"state": state,
	}


func _water_section() -> Dictionary:
	var water: Variant = _infrastructure.get("water", {})
	var rows: Array[Dictionary] = []
	var city: Dictionary = {}
	var zones: Array = []
	if water is Dictionary:
		var block: Dictionary = water
		var city_raw: Variant = block.get("city", {})
		city = city_raw if city_raw is Dictionary else {}
		var zones_raw: Variant = block.get("zones", [])
		zones = zones_raw if zones_raw is Array else []
	if not city.is_empty():
		rows.append(_figure("water_supply", "ui_dashboard_infra_water_supply",
				flow_text(UIConfig.get_num(city, "total_supply_m3h", 0.0)),
				HudModel.STATE_NORMAL))
		var demand := UIConfig.get_num(city, "total_demand_m3h", 0.0)
		var supply := UIConfig.get_num(city, "total_supply_m3h", 0.0)
		rows.append(_figure("water_demand", "ui_dashboard_infra_water_demand",
				flow_text(demand),
				HudModel.STATE_CRITICAL if demand > supply else HudModel.STATE_NORMAL))
		rows.append(_figure("storage", "ui_dashboard_infra_storage",
				HudModel.percent_text(UIConfig.get_num(city, "storage_frac", 0.0) * 100.0),
				pressure_state(UIConfig.get_num(city, "storage_frac", 1.0))))
	# §2.10's "worst 5 zones": lowest pressure first, id as the tiebreak.
	var sorted: Array = zones.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa := UIConfig.get_num(a, "pressure", 1.0)
		var pb := UIConfig.get_num(b, "pressure", 1.0)
		if not is_equal_approx(pa, pb):
			return pa < pb
		return str(a.get("zone_key", "")) < str(b.get("zone_key", "")))
	var listed := 0
	for value: Variant in sorted:
		if listed >= worst_n() or not (value is Dictionary):
			break
		var zone: Dictionary = value
		var pressure := UIConfig.get_num(zone, "pressure", 1.0)
		rows.append({
			"id": "zone_" + str(zone.get("zone_key", "")),
			"label": str(zone.get("zone_key", "")),
			"value": HudModel.percent_text(pressure * 100.0),
			"detail": UIWidgets.t_args(_cfg, "ui_dashboard_infra_customers",
					{"count": UIConfig.get_int(zone, "building_count", 0)}),
			"state": pressure_state(pressure),
		})
		listed += 1
	return {
		"id": "water",
		"title": UIWidgets.t_args(_cfg, "ui_dashboard_infra_water_title",
				{"count": listed}),
		"rows": rows,
		"empty_text": UIWidgets.t(_cfg, "ui_dashboard_no_water"),
	}


# ---------------------------------------------------------------------------
# Response (§2.10: "per-department unit roster with status, rolling-24 h average
# response time, incident throughput")
# ---------------------------------------------------------------------------

func response_departments() -> Array[String]:
	return _string_list("response_departments", _DEFAULT_DEPARTMENTS)


func response_target_min() -> float:
	return UIConfig.get_num(_dashboard, "response_target_min", _DEFAULT_TARGET_MIN)


## The shell's one call per refresh:
##
##     {units: [{id, type, department, status, station}],
##      stats: DispatchSystem.stats,
##      open: <active incident count>}
func feed_response(snapshot: Dictionary) -> void:
	_response = snapshot.duplicate(true)


func has_response() -> bool:
	return not _response.is_empty()


func response_view() -> Dictionary:
	var raw: Variant = _response.get("units", [])
	var units: Array = raw if raw is Array else []
	var idle: Dictionary = {}
	var total: Dictionary = {}
	for value: Variant in units:
		if not (value is Dictionary):
			continue
		var unit: Dictionary = value
		var dept := str(unit.get("department", ""))
		total[dept] = int(total.get(dept, 0)) + 1
		if str(unit.get("status", "")) == "IDLE":
			idle[dept] = int(idle.get(dept, 0)) + 1
	var roster: Array[Dictionary] = []
	for dept: String in response_departments():
		var have := int(total.get(dept, 0))
		var free := int(idle.get(dept, 0))
		roster.append({
			"id": dept,
			"label": UIWidgets.t(_cfg, "ui_dashboard_dept_%s" % dept),
			"value": UIWidgets.t_args(_cfg, "ui_dashboard_response_idle",
					{"idle": free, "total": have}),
			"detail": "",
			"state": _roster_state(free, have),
		})
	var stats_raw: Variant = _response.get("stats", {})
	var stats: Dictionary = stats_raw if stats_raw is Dictionary else {}
	var times: Array[Dictionary] = []
	if int(stats.get("response_samples", 0)) > 0:
		var average := UIConfig.get_num(stats, "avg_response_min", 0.0)
		times.append(_figure("avg", "ui_dashboard_response_avg",
				"%d min" % int(round(average)), response_state(average)))
		var score := UIConfig.get_num(stats, "rolling_response_score", 1.0)
		times.append(_figure("score", "ui_dashboard_response_score",
				HudModel.percent_text(score * 100.0), _score_state(score)))
	times.append(_figure("resolved", "ui_dashboard_response_resolved",
			str(UIConfig.get_int(stats, "resolved_total", 0)), HudModel.STATE_NORMAL))
	var failed := UIConfig.get_int(stats, "failed_total", 0)
	times.append(_figure("failed", "ui_dashboard_response_failed", str(failed),
			HudModel.STATE_NORMAL if failed == 0 else HudModel.STATE_WARNING))
	var open_now := UIConfig.get_int(_response, "open", 0)
	times.append(_figure("open", "ui_dashboard_response_open", str(open_now),
			HudModel.STATE_NORMAL if open_now == 0 else HudModel.STATE_WARNING))
	var sections: Array[Dictionary] = [
			{
				"id": "roster",
				"title": UIWidgets.t(_cfg, "ui_dashboard_response_roster_title"),
				"rows": roster,
				"empty_text": UIWidgets.t(_cfg, "ui_dashboard_no_roster"),
			},
			{
				"id": "times",
				"title": UIWidgets.t(_cfg, "ui_dashboard_response_times_title"),
				"rows": times,
				"empty_text": UIWidgets.t(_cfg, "ui_dashboard_no_response_data"),
			},
	]
	return {"has_data": has_response(), "sections": _with_glyphs(sections)}


static func _roster_state(free: int, total: int) -> StringName:
	if total <= 0:
		return HudModel.STATE_OFFLINE
	if free <= 0:
		return HudModel.STATE_CRITICAL
	# More than half the department still in the bay is fine; exactly half or
	# fewer is the point at which one more call leaves the city short.
	return HudModel.STATE_NORMAL if free * 2 > total else HudModel.STATE_WARNING


func _score_state(score: float) -> StringName:
	if score >= 0.75:
		return HudModel.STATE_NORMAL
	return HudModel.STATE_WARNING if score >= 0.45 else HudModel.STATE_CRITICAL


## Doc 06's `target_response_min` is the grade; `response_warn_mult` is how far
## past it still reads as a warning rather than a failure.
func response_state(minutes: float) -> StringName:
	var target := response_target_min()
	if minutes <= target:
		return HudModel.STATE_NORMAL
	var warn := UIConfig.get_num(_dashboard, "response_warn_mult", _DEFAULT_WARN_MULT)
	return HudModel.STATE_WARNING if minutes <= target * warn \
			else HudModel.STATE_CRITICAL


# ---------------------------------------------------------------------------
# Shared shapes and units
# ---------------------------------------------------------------------------

func _figure(row_id: String, label_key: String, value: String,
		state: StringName) -> Dictionary:
	return {"id": row_id, "label": UIWidgets.t(_cfg, label_key), "value": value,
			"detail": "", "state": state}


## kW below a megawatt, MW above it — the same "three significant figures, one
## unit per surface" rule `HudModel.money` follows (D-18).
static func power_text(kw: float) -> String:
	if absf(kw) >= 1000.0:
		return "%.1f MW" % (kw / 1000.0)
	return "%d kW" % int(round(kw))


static func flow_text(m3h: float) -> String:
	if absf(m3h) >= 1000.0:
		return "%.1f k m³/h" % (m3h / 1000.0)
	return "%d m³/h" % int(round(m3h))


## Doc 04's own pickup ratio is 1.05; anything past it is on its way to tripping,
## and 0.90 is doc 02 §E2's upgrade gate — the point at which the player can no
## longer grow on that feeder.
static func load_state(ratio: float) -> StringName:
	if ratio >= 1.0:
		return HudModel.STATE_CRITICAL
	return HudModel.STATE_WARNING if ratio >= 0.90 else HudModel.STATE_NORMAL


## Doc 05 §2.8's own bands (`data/water.json.effects.bands`): 0.60 normal,
## 0.35 warn, 0.10 critical. Restated as the four §2.5 data states.
static func pressure_state(pressure: float) -> StringName:
	if pressure >= 0.60:
		return HudModel.STATE_NORMAL
	if pressure >= 0.35:
		return HudModel.STATE_WARNING
	return HudModel.STATE_CRITICAL if pressure >= 0.10 else HudModel.STATE_OFFLINE


func _row(row_id: String, snapshot: Dictionary, chips: Dictionary) -> Dictionary:
	var series_key := str(ROW_SERIES.get(row_id, ""))
	var value_text := ""
	var state: StringName = HudModel.STATE_OFFLINE
	var state_glyph := ""
	match row_id:
		"happiness":
			# Doc 09 publishes happiness on [0,1] like stability; §2.4's rule is
			# that the ×100 conversion happens once, at the point of display.
			var happiness := float(snapshot.get("happiness", -1.0))
			value_text = HudModel.NO_DATA if happiness < 0.0 \
					else HudModel.percent_text(float(_hud.stability_percent(happiness)))
			state = _hud.stability_state(happiness) if happiness >= 0.0 \
					else HudModel.STATE_OFFLINE
			state_glyph = _hud.state_glyph(state)
		_:
			var chip_id := "net_income" if row_id == "net_income" else row_id
			var chip: Variant = chips.get(chip_id, null)
			if chip is Dictionary:
				value_text = str((chip as Dictionary)["text_full"])
				state = (chip as Dictionary)["state"]
				state_glyph = str((chip as Dictionary)["state_glyph"])
	var spark := history.normalized(series_key, spark_hours()) if series_key != "" \
			else {"points": PackedVector2Array(), "count": 0, "min": 0.0, "max": 0.0,
					"first": 0.0, "last": 0.0, "delta": 0.0}
	return {
		"id": row_id,
		"label": UIWidgets.t(_cfg, "ui_dashboard_row_%s" % row_id),
		"value_text": value_text,
		"state": state,
		"state_glyph": state_glyph,
		"series": series_key,
		"spark": spark,
		"deeplink": str(ROW_DEEPLINK.get(row_id, "")),
		"selected": row_id == _selected_row,
	}


## The full-size chart for one row. `{points, min, max, count, title, min_text,
## max_text, delta_text, state}` — `count == 0` means "not enough history yet",
## which the view says in words rather than drawing an empty box.
func chart(row_id: String) -> Dictionary:
	var series_key := str(ROW_SERIES.get(row_id, ""))
	var hours := chart_hours()
	var shape: Dictionary = history.normalized(series_key, hours) if series_key != "" \
			else {"points": PackedVector2Array(), "count": 0, "min": 0.0, "max": 0.0,
					"first": 0.0, "last": 0.0, "delta": 0.0}
	var out := shape.duplicate()
	out["row"] = row_id
	out["series"] = series_key
	out["title"] = UIWidgets.t_args(_cfg, "ui_dashboard_chart_title",
			{"label": UIWidgets.t(_cfg, "ui_dashboard_row_%s" % row_id),
					"hours": mini(hours, maxi(1, history.size()))})
	out["min_text"] = _axis_text(row_id, float(shape["min"]))
	out["max_text"] = _axis_text(row_id, float(shape["max"]))
	out["delta_text"] = _axis_text(row_id, float(shape["delta"]), true)
	out["state"] = BudgetModel.delta_state(float(shape["delta"]))
	out["empty_text"] = UIWidgets.t(_cfg, "ui_dashboard_no_history")
	return out


## Axis labels speak each series' own units — money for the treasury, a percent
## for the four series the sim publishes on `[0,1]` (§2.4: the ×100 conversion
## happens once, at the point of display), a grouped integer for population.
func _axis_text(row_id: String, value: float, signed_value: bool = false) -> String:
	match row_id:
		"treasury":
			return HudModel.money(int(round(value)))
		"net_income":
			return HudModel.rate_per_day(value)
		"population":
			var rounded := int(round(value))
			return (HudModel.PLUS + HudModel.pop(rounded)) if signed_value and rounded > 0 \
					else HudModel.pop(rounded)
		"happiness", "stability", "grid", "water":
			return HudModel.percent_text(value * 100.0, signed_value)
	return BudgetModel.signed(value, 0) if signed_value else str(int(round(value)))
