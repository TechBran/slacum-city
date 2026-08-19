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

const _DEFAULT_TABS: Array[String] = ["overview", "economy"]
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
		"selected_row": _selected_row,
		"history_size": history.size(),
	}


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
