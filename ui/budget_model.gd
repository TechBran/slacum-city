class_name BudgetModel
extends RefCounted
## The dashboard's Economy tab (doc 12 §2.10): the tax detent and the ledger of
## the hour that just settled.
##
## **Tax.** Doc 03 owns the ladder and `CitySim.cmd_set_tax_level(level, preview)`
## owns the arithmetic, including the preview: called with `preview = true` it
## computes the whole consequence — rate, `happiness_delta`, `growth_multiplier`
## — *and changes nothing*, and it reports `E_TAX_COOLDOWN` with
## `hours_remaining` when doc 03's cooldown is still running. So this class does
## not model tax at all; it holds one injected `Callable` with that exact
## signature, calls it with `preview = true` for every step of the stepper, and
## with `preview = false` only when the player presses APPLY. The UI therefore
## cannot show a number the sim would not produce (§4.4: "the UI never predicts
## success").
##
## **Ledger.** `feed_settlement()` takes doc 03's hourly settle snapshot verbatim
## — `{revenue: {...}, expenses: {...}, net}` — and turns it into two ordered
## lists of `{key, label, amount, text}`. It also accepts the smaller
## `economy_hour_settled` **bus event** (`{gross, expense, net}`), which is what
## the shell can wire without touching `sim/`: that gives the three totals and no
## breakdown, and `has_breakdown()` says which of the two arrived.
##
## No copy and no threshold is authored here: line labels resolve
## `ui_budget_revenue_<key>` / `ui_budget_expense_<key>` from
## `data/strings.en.json`, and which keys exist in which order is
## `data/ui.json.budget`.

const REASON_OK := &""
const REASON_NO_COMMAND := &"E_NO_COMMAND"

const _DEFAULT_REVENUE_KEYS: Array[String] = ["tax", "power_tariff", "water_tariff",
		"city_services", "assistance"]
const _DEFAULT_EXPENSE_KEYS: Array[String] = ["building_maint", "departments", "fleet",
		"vehicle_fuel", "grid", "generation_fuel", "water", "roads_repair", "debt"]

var _cfg: UIConfig
var _budget: Dictionary = {}
var _command := Callable()

var _level := 0
var _level_count := 1
var _rate := 0.0
var _pending := -1

var _settlement: Dictionary = {}
var _has_breakdown := false
## Revenue the treasury really took in that doc 03's settle snapshot does not
## carry. See `feed_side_revenue()`.
var _side: Dictionary = {}


func _init(cfg: UIConfig = null) -> void:
	if cfg == null:
		return
	_cfg = cfg
	_budget = cfg.section("budget")


static func load_from_files() -> BudgetModel:
	return BudgetModel.new(UIConfig.load_from_files())


## `Callable(level: int, preview: bool) -> Dictionary` — `CitySim.cmd_set_tax_level`
## itself, handed over by the shell. Its result is `CommandQueue`'s
## `{ok, reason_code, payload}`.
func set_tax_command(command: Callable) -> void:
	_command = command


## The sim's current detent: `sim.tax_level()`, `sim.tax_level_count()`,
## `sim.tax_rate`. Called every time the shell refreshes the dashboard, so a tax
## change made anywhere else lands here too.
func set_tax_state(level: int, level_count: int, rate: float) -> void:
	_level_count = maxi(1, level_count)
	_level = clampi(level, 0, _level_count - 1)
	_rate = rate
	if _pending < 0 or _pending >= _level_count:
		_pending = _level


func level() -> int:
	return _level


func level_count() -> int:
	return _level_count


func rate() -> float:
	return _rate


## The detent the stepper is sitting on, which is the committed one until the
## player moves it.
func pending_level() -> int:
	return _pending


# ---------------------------------------------------------------------------
# Tax stepper — preview first, always
# ---------------------------------------------------------------------------

## Move the stepper by `delta` detents (clamped to the ladder) and return the
## preview for where it landed. Nothing is committed.
func step(delta: int) -> Dictionary:
	_pending = clampi(_pending + delta, 0, _level_count - 1)
	return preview(_pending)


func set_pending_level(level_value: int) -> Dictionary:
	_pending = clampi(level_value, 0, _level_count - 1)
	return preview(_pending)


## `cmd_set_tax_level(level, true)` rendered. Works whether the command said ok
## (a legal move) or failed (`E_TAX_LEVEL_RANGE`, `E_TAX_COOLDOWN`) — a refused
## move still previews its numbers, and the note says in words why the APPLY
## button is off (A14).
func preview(level_value: int) -> Dictionary:
	if not _command.is_valid():
		return _view({}, false, REASON_NO_COMMAND, level_value)
	var result: Variant = _command.call(level_value, true)
	if not (result is Dictionary):
		return _view({}, false, REASON_NO_COMMAND, level_value)
	var record: Dictionary = result
	var payload: Variant = record.get("payload", {})
	return _view(payload if payload is Dictionary else {},
			bool(record.get("ok", false)),
			StringName(str(record.get("reason_code", ""))), level_value)


## Commit the stepper. Returns the same view shape with `applied` set, and
## re-syncs `level`/`rate` from the payload on success so the caller does not
## have to read the sim back.
func apply() -> Dictionary:
	if not _command.is_valid():
		var blocked := _view({}, false, REASON_NO_COMMAND, _pending)
		blocked["applied"] = false
		return blocked
	var result: Variant = _command.call(_pending, false)
	var record: Dictionary = result if result is Dictionary else {}
	var payload: Variant = record.get("payload", {})
	var ok := bool(record.get("ok", false))
	var view := _view(payload if payload is Dictionary else {}, ok,
			StringName(str(record.get("reason_code", ""))), _pending)
	view["applied"] = ok
	if ok:
		_level = int(view["level"])
		_rate = float(view["rate"])
		_pending = _level
	return view


func _view(payload: Dictionary, ok: bool, reason: StringName,
		level_value: int) -> Dictionary:
	var rate_value := float(payload.get("rate", _rate))
	var happiness := float(payload.get("happiness_delta", 0.0))
	var growth := float(payload.get("growth_multiplier", 1.0))
	var changed := bool(payload.get("changed", level_value != _level))
	var view := {
		"ok": ok,
		"reason": reason,
		"level": int(payload.get("level", level_value)),
		"level_count": _level_count,
		"rate": rate_value,
		"previous_rate": float(payload.get("previous_rate", _rate)),
		"happiness_delta": happiness,
		"growth_multiplier": growth,
		"changed": changed,
		"can_apply": ok and changed,
		"rate_text": BudgetModel.rate_text(rate_value),
		"level_text": UIWidgets.t_args(_cfg, "ui_budget_tax_level",
				{"level": int(payload.get("level", level_value)) + 1,
						"count": _level_count}),
		"happiness_text": UIWidgets.t_args(_cfg, "ui_budget_preview_happiness",
				{"delta": BudgetModel.signed(happiness, 1)}),
		"growth_text": UIWidgets.t_args(_cfg, "ui_budget_preview_growth",
				{"mult": "%.2f" % growth}),
		"happiness_state": BudgetModel.delta_state(happiness),
		"growth_state": BudgetModel.delta_state(growth - 1.0),
		"applied": false,
	}
	view["note"] = _note(view, payload, reason)
	return view


func _note(view: Dictionary, payload: Dictionary, reason: StringName) -> String:
	if reason == &"E_TAX_COOLDOWN":
		return UIWidgets.t_args(_cfg, "ui_budget_cooldown",
				{"hours": int(payload.get("hours_remaining", 0))})
	if reason == REASON_NO_COMMAND:
		return UIWidgets.t(_cfg, "ui_budget_unavailable")
	if reason == &"E_TAX_LEVEL_RANGE":
		return UIWidgets.t(_cfg, "ui_budget_out_of_range")
	if not bool(view["changed"]):
		return UIWidgets.t(_cfg, "ui_budget_unchanged")
	return ""


## `0.09` → `9%`, `0.095` → `9.5%` — doc 03 states the rate in basis points, so
## one decimal is the most a detent can ever need.
static func rate_text(rate_value: float) -> String:
	var percent := rate_value * 100.0
	var text := "%.1f" % percent
	if text.ends_with(".0"):
		text = text.substr(0, text.length() - 2)
	return text + "%"


## The HUD's own minus sign (§2.4 renders U+2212, not a hyphen).
static func signed(value: float, decimals: int = 0) -> String:
	var magnitude := String.num(absf(value), maxi(0, decimals))
	if value < 0.0:
		return HudModel.MINUS + magnitude
	return HudModel.PLUS + magnitude


static func delta_state(delta: float) -> StringName:
	if delta > 0.0:
		return HudModel.STATE_NORMAL
	if delta < 0.0:
		return HudModel.STATE_WARNING
	return HudModel.STATE_OFFLINE


# ---------------------------------------------------------------------------
# The settled hour
# ---------------------------------------------------------------------------

## Doc 03's settle snapshot, or the `economy_hour_settled` bus event. Both are
## accepted because the shell can reach the second one today (it is on the bus)
## and the first only once the coordinator publishes it.
func feed_settlement(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	_settlement = snapshot.duplicate(true)
	_has_breakdown = (snapshot.get("revenue", null) is Dictionary) \
			and (snapshot.get("expenses", null) is Dictionary)


## **Money the city took in that doc 03 never settled.** A resolved incident's
## bounty and a collected street opportunity both reach the treasury through
## `Treasury.credit(…, &"incident", …)` — a direct credit, outside
## `EconomySystem.settle_hour` — so no key of the settle snapshot has ever
## contained either, and the NET this ledger prints has been short by exactly
## that much on every hour a crew answered a call. `ui/street_model.gd` tallies
## the two off the bus per game-hour and hands them here.
##
## **The rule that retires this.** A key doc 03 *does* settle is taken from the
## snapshot and this tally is ignored for it, always — so the day the economy
## publishes `revenue.bounties`, the sim's number wins with no edit here and no
## chance of counting the same dollar twice.
##
## `{key: amount}`, in the settled hour's own units. Empty by default, so a shell
## that never calls this gets exactly the ledger it got before.
func feed_side_revenue(amounts: Dictionary) -> void:
	_side = amounts.duplicate()


func side_revenue() -> Dictionary:
	return _side.duplicate()


func has_settlement() -> bool:
	return not _settlement.is_empty()


func has_breakdown() -> bool:
	return _has_breakdown


func revenue_keys() -> Array[String]:
	return _keys("revenue_keys", _DEFAULT_REVENUE_KEYS)


func expense_keys() -> Array[String]:
	return _keys("expense_keys", _DEFAULT_EXPENSE_KEYS)


func _keys(field: String, fallback: Array[String]) -> Array[String]:
	var raw: Variant = _budget.get(field, [])
	if not (raw is Array) or (raw as Array).is_empty():
		return fallback.duplicate()
	var out: Array[String] = []
	for value: Variant in (raw as Array):
		out.append(str(value))
	return out


## `{revenue: [...], expenses: [...], gross, expense, net, ...}` — the whole
## Economy ledger, ready to bind. Lines whose amount is zero are dropped: an
## expense the city does not have is not a row that says `$0`.
func breakdown() -> Dictionary:
	var gross := 0.0
	var expense := 0.0
	var net := 0.0
	# What of the revenue column came from the side channel rather than from the
	# settle snapshot. It is added to `gross` and to `net` below: a row the
	# column shows but the total does not contain is a ledger that does not add
	# up, which is worse than the line being missing.
	var side_total := 0.0
	var revenue_rows: Array[Dictionary] = []
	var expense_rows: Array[Dictionary] = []
	var settled_revenue: Dictionary = _settlement["revenue"] if _has_breakdown else {}
	if _has_breakdown:
		var expenses: Dictionary = _settlement["expenses"]
		gross = float(settled_revenue.get("gross", 0.0))
		expense = float(expenses.get("total", 0.0))
		for key: String in expense_keys():
			var amount := float(expenses.get(key, 0.0))
			if not is_zero_approx(amount):
				expense_rows.append(_line("expense", key, amount))
	else:
		gross = float(_settlement.get("gross", 0.0))
		expense = float(_settlement.get("expense", 0.0))
	# The revenue column is walked once for both sources, in the file's authored
	# order, so a side line is not a footnote under the ledger — it is a row of
	# it, in the place the reader is already looking.
	for key: String in revenue_keys():
		var settled := settled_revenue.has(key)
		var amount := float(settled_revenue.get(key, 0.0)) if settled \
				else float(_side.get(key, 0.0))
		if is_zero_approx(amount):
			continue
		if not settled:
			side_total += amount
		# A ledger with no breakdown draws no rows at all (the Economy tab gates
		# the whole column on `has_breakdown`), so building them would be data
		# nothing reads. The total still moves: the money was still taken in.
		if not _has_breakdown:
			continue
		var line := _line("revenue", key, amount)
		line["settled"] = settled
		# Doc 03 §2.5a's founding assistance retires $589.71 a game-day and used
		# to do it in silence — PA-32 measured it as the largest single mover of
		# the net chip in the opening fortnight, with no toast, no log row and no
		# end date anywhere (doc 93 §Y4). No dollar moves for this: the row says
		# how many game-days of itself are left, on its own label, from the
		# count doc 03 now publishes in the settle snapshot.
		# **The taper, before it bites** (99-PA PA-32, doc 98 RR-148). RR-102 put
		# the COUNT on this row; the audit's finding was that a count alone does
		# not tell a player what the step is going to cost them. So the note now
		# carries all three of the numbers the sentence needs — what the grant
		# pays TODAY as a per-day rate (the unit the net chip is read in, not the
		# per-hour figure in the column beside it), which game-day it ends on,
		# and how many game-days that leaves — and none of them is authored here:
		# `per_day` is this row's own settled amount × 24 through
		# `HudModel.rate_per_day`, and `end_day` is the settled hour's own day
		# plus doc 03's published count.
		if key == "assistance":
			var days_left := int(_settlement.get("assistance_days_left", 0))
			line["days_left"] = days_left
			line["end_day"] = int(_settlement.get("hour", 0)) / 24 + days_left
			if days_left > 0:
				line["note"] = UIWidgets.t_args(_cfg, "ui_budget_assistance_days_left",
						{"per_day": str(line["per_day_text"]),
						"end_day": str(line["end_day"]),
						"days": str(days_left)})
		revenue_rows.append(line)
	net = float(_settlement.get("net", gross - expense)) + side_total
	gross += side_total
	return {
		"has_data": has_settlement() or not is_zero_approx(side_total),
		"has_breakdown": _has_breakdown,
		"hour": int(_settlement.get("hour", 0)),
		"revenue": revenue_rows,
		"expenses": expense_rows,
		"gross": gross,
		"expense": expense,
		"net": net,
		"side_revenue": side_total,
		# One column, one convention. `HudModel.money()`'s three-significant-digit
		# ladder is right on a fixed-width chip and wrong here: it printed the tax
		# line as `$12.5K` directly above `$4,120` of building upkeep, so the two
		# biggest numbers on the screen could not be compared without arithmetic.
		# And the total line is the *settled hour*, like every line above it — a
		# per-day net beside two per-hour figures is a unit error, not a summary.
		"gross_text": HudModel.money_exact(int(round(gross))),
		"expense_text": HudModel.money_exact(int(round(expense))),
		"net_text": HudModel.money_signed(int(round(net))),
		"net_per_day_text": HudModel.rate_per_day(net),
		"net_state": HudModel.STATE_NORMAL if net >= 0.0 else HudModel.STATE_WARNING,
	}


func _line(side: String, key: String, amount: float) -> Dictionary:
	return {
		"key": key,
		"side": side,
		"amount": amount,
		"label": UIWidgets.t(_cfg, "ui_budget_%s_%s" % [side, key]),
		"text": HudModel.money_exact(int(round(amount))),
		"per_day_text": HudModel.rate_per_day(amount),
	}
