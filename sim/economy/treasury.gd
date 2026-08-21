class_name Treasury
extends RefCounted
## The city's money (doc 03 §2.1 precision rule, §2.10 recovery ladder).
##
## Balance is strictly whole dollars, `int64` (constitution §7). Per-building
## revenue is computed in float, summed for the whole city and rounded **once
## per settlement**; the sub-dollar remainder lives in
## `carry_millidollars : int64` so no money is created or destroyed by rounding
## (report 98 C-15 — doc 03's scheme is the only one in the project).
##
## The five-layer recovery ladder of §2.10 is a state machine here: austerity
## (layer 2), the automatic credit line (layer 3), the deferred-liability hard
## floor (layer 4) and State Emergency Assistance (layer 5). Layer 1 — the city
## revenue floor — lives in `EconomySystem`, because it shapes revenue before a
## dollar reaches this class.
##
## Nothing outside this class mutates the balance (doc 03 §5, non-negotiable
## contract): every earn/spend goes through `credit()` / `spend()`.

const MILLIDOLLARS_PER_DOLLAR := 1000

## Austerity blocks *new* commitments only; in-flight projects continue
## (doc 03 §2.10 layer 2 — never strand a half-built tower).
const AUSTERITY_BLOCKED_CATEGORIES: Array[StringName] = [
	&"construction", &"land", &"vehicle",
]

## doc 03 §2.9's `economic` row for `standard`, as a **compiled-in mirror**.
##
## The authority is `data/difficulty.json` behind `Difficulty` (§3.4, report 98
## C-17), and `CitySim` constructs this class with that file's row — this
## dictionary is only what a `Treasury` built with no difficulty argument falls
## back to, so a unit test that wants a nominal treasury does not have to open a
## data file to get one. `tests/test_difficulty.gd` asserts the two are the same
## twelve knobs with the same twelve values, so the mirror cannot drift.
const DIFFICULTY_STANDARD := {
	"M_rev": 1.00, "M_exp": 1.00, "M_land": 1.00, "M_dev": 1.00, "M_build": 1.00,
	"M_repair": 1.00, "starting_treasury": 25000, "OFF_TAU_HOURS": 90,
	"offline_damage_cap_fraction": 0.20, "REV_FLOOR_FRACTION": 0.18,
	"CREDIT_APR_PER_GAME_DAY": 0.008, "relief_grants_per_era": 3,
}

var balance: int = 0
var carry_millidollars: int = 0
var deferred_liability: int = 0
var credit_limit: int = 0

var austerity_active: bool = false
var austerity_entered_hour: int = -1
var relief_grants_used: int = 0
var relief_last_grant_hour: int = -1

var lifetime: Dictionary = {
	"lifetime_tax": 0, "lifetime_tariff": 0, "lifetime_expense": 0,
	"lifetime_repairs": 0, "lifetime_foregone": 0,
}

var _recovery: Dictionary = {}
var _difficulty: Dictionary = {}
var _events: Array[Dictionary] = []


func _init(economy: Dictionary = {}, difficulty_row: Dictionary = {},
		starting_balance: int = -1) -> void:
	_recovery = economy.get("recovery", {})
	apply_difficulty(difficulty_row, false)
	balance = starting_balance if starting_balance >= 0 \
			else int(_difficulty.get("starting_treasury", 0))
	credit_limit = int(_recovery.get("CREDIT_LIMIT_FLOOR", 0))


func difficulty() -> Dictionary:
	return _difficulty.duplicate()


## The ONE write path for doc 03 §2.9's `economic` row (C-17). `CitySim` hands it
## `Difficulty.row("economic")` at boot, again when a city is FOUNDED on a preset
## (doc 93 §K1), and again after a load — the preset is part of the city, so a
## restored city has to get its multipliers back before it settles an hour.
##
## `reset_balance` is the founding case and nothing else: a load must keep the
## dollars the save recorded, and a preset cannot be changed mid-city, so the
## only moment the starting treasury is authoritative is the moment before the
## first tick. Unknown knobs are refused rather than merged — a difficulty row
## is a fixed twelve-key shape and a typo that quietly added a thirteenth would
## read as a knob some system was failing to honour.
func apply_difficulty(row: Dictionary, reset_balance: bool) -> void:
	_difficulty = DIFFICULTY_STANDARD.duplicate()
	for key in row:
		if _difficulty.has(key):
			_difficulty[key] = row[key]
	if reset_balance:
		balance = int(_difficulty.get("starting_treasury", 0))


func drain_events() -> Array[Dictionary]:
	var out := _events
	_events = [] as Array[Dictionary]
	return out


# ------------------------------------------------------------ earn and spend

## Non-negative credits only; a negative "credit" is a spend and must say so.
func credit(amount: int, category: StringName = &"misc", reason: String = "") -> Dictionary:
	if amount < 0:
		return _fail(&"NEGATIVE_AMOUNT", {"amount": amount, "category": category})
	balance += amount
	_note_lifetime(category, amount)
	_emit(&"treasury_credited", {"amount": amount, "category": category, "reason": reason,
			"balance": balance})
	return {"ok": true, "reason_code": &"", "credited": amount, "balance": balance}


## Layer 4: the balance can never go below `-credit_limit`. Anything that would
## breach the floor is moved into `deferred_liability` instead — which accrues
## no interest, costs condition, and is repaid from positive net income.
func spend(amount: int, category: StringName = &"misc", reason: String = "") -> Dictionary:
	if amount < 0:
		return _fail(&"NEGATIVE_AMOUNT", {"amount": amount, "category": category})
	if austerity_active and AUSTERITY_BLOCKED_CATEGORIES.has(category):
		return _fail(&"AUSTERITY_BLOCKED", {"amount": amount, "category": category})
	var floor_balance := -credit_limit
	var was_positive := balance >= 0
	var affordable: int = maxi(0, balance - floor_balance)
	var charged: int = mini(amount, affordable)
	var deferred: int = amount - charged
	balance -= charged
	_note_lifetime(category, charged)
	if was_positive and balance < 0:
		_emit(&"credit_line_engaged", {"balance": balance, "credit_limit": credit_limit})
	if deferred > 0:
		deferred_liability += deferred
		var units := float(deferred) / 1000.0
		_emit(&"credit_limit_reached", {"balance": balance, "credit_limit": credit_limit})
		_emit(&"deferred_liability_accrued", {
			"amount": deferred, "total": deferred_liability,
			"condition_penalty_units": units,
			"condition_penalty_per_unit": float(_recovery.get(
					"DEFERRED_CONDITION_PENALTY_PER_1000", 0.0)),
			"condition_penalty_total": units * float(_recovery.get(
					"DEFERRED_CONDITION_PENALTY_PER_1000", 0.0)),
			"category": category, "reason": reason})
	return {"ok": deferred == 0, "reason_code": &"" if deferred == 0 else &"DEFERRED",
			"spent": charged, "deferred": deferred, "balance": balance}


func can_spend(amount: int, category: StringName = &"misc") -> bool:
	if austerity_active and AUSTERITY_BLOCKED_CATEGORIES.has(category):
		return false
	return balance - amount >= -credit_limit


# ---------------------------------------------------------------- settlement

## THE hourly settlement (doc 03 §2.1 precision rule). `revenue` and `expenses`
## are unrounded dollars-per-game-hour; the net is accumulated in millidollars
## and only whole dollars ever touch the balance.
##
## Deferred liability is repaid from positive net income *before* the treasury
## sees it (§2.10 layer 4).
func settle(revenue: float, expenses: float) -> Dictionary:
	var net := revenue - expenses
	var repaid := 0
	if net > 0.0 and deferred_liability > 0:
		var fraction := float(_recovery.get("DEFERRED_REPAY_FRACTION", 0.0))
		repaid = mini(deferred_liability, CostCurves.round_half_up(net * fraction))
		deferred_liability -= repaid
		net -= float(repaid)
		if deferred_liability == 0:
			_emit(&"deferred_liability_cleared", {"repaid": repaid})
	var millidollars := carry_millidollars + _to_millidollars(net)
	var whole := _floor_div(millidollars, MILLIDOLLARS_PER_DOLLAR)
	carry_millidollars = millidollars - whole * MILLIDOLLARS_PER_DOLLAR
	var was_positive := balance >= 0
	balance += whole
	if balance < -credit_limit:
		var overshoot := -credit_limit - balance
		balance = -credit_limit
		deferred_liability += overshoot
		_emit(&"deferred_liability_accrued", {"amount": overshoot, "total": deferred_liability,
				"category": &"settlement"})
	if was_positive and balance < 0:
		_emit(&"credit_line_engaged", {"balance": balance, "credit_limit": credit_limit})
	lifetime["lifetime_expense"] = int(lifetime["lifetime_expense"]) \
			+ CostCurves.round_half_up(expenses)
	_emit(&"economy_hour_settled", {"revenue": revenue, "expenses": expenses,
			"net": revenue - expenses, "deferred_repaid": repaid,
			"balance": balance, "carry_millidollars": carry_millidollars})
	return {"net": revenue - expenses, "applied_dollars": whole, "deferred_repaid": repaid,
			"carry_millidollars": carry_millidollars, "balance": balance}


## Exact total the treasury has been handed, in millidollars — `balance × 1000 +
## carry`. Used by the no-money-lost test (doc 03 §7 test 14).
func exact_millidollars() -> int:
	return balance * MILLIDOLLARS_PER_DOLLAR + carry_millidollars


# ----------------------------------------------------------- recovery ladder

## Layer 3: `credit_limit = max(CREDIT_LIMIT_FLOOR, CREDIT_LIMIT_DAYS × daily_gross_revenue)`.
func update_credit_limit(daily_gross_revenue: float) -> int:
	var days := float(_recovery.get("CREDIT_LIMIT_DAYS_OF_REVENUE", 0.0))
	credit_limit = maxi(int(_recovery.get("CREDIT_LIMIT_FLOOR", 0)),
			CostCurves.round_half_up(days * daily_gross_revenue))
	return credit_limit


## Layer 3: interest is booked by the caller as `E_debt` — never applied here,
## so it cannot be charged twice.
func debt_interest_per_hour() -> int:
	var apr := float(_difficulty.get("CREDIT_APR_PER_GAME_DAY", 0.0))
	return CostCurves.round_half_up(float(absi(mini(0, balance))) * apr / 24.0)


## Layer 2: enters at `treasury < 0`, exits at `treasury ≥ 0.5 × daily_gross_expense`.
func update_austerity(daily_gross_expense: float, hour: int) -> bool:
	if not austerity_active and balance < 0:
		austerity_active = true
		austerity_entered_hour = hour
		_emit(&"austerity_entered", {"hour": hour, "balance": balance})
	elif austerity_active:
		var exit_at := float(_recovery.get("AUSTERITY_EXIT_DAYS_OF_EXPENSE", 0.0)) \
				* daily_gross_expense
		if float(balance) >= exit_at:
			austerity_active = false
			austerity_entered_hour = -1
			_emit(&"austerity_exited", {"hour": hour, "balance": balance,
					"threshold": exit_at})
	return austerity_active


## Layer 2: every recurring expense line is scaled by this.
func austerity_expense_mult() -> float:
	return float(_recovery.get("AUSTERITY_EXPENSE_MULT", 1.0)) if austerity_active else 1.0


## Layer 2's other half: an austerity budget buys less maintenance, so doc 02
## §2.6 wear runs faster while it is engaged. `AUSTERITY_DECAY_MULT` was authored
## for this and had no reader until the ladder was wired (doc 92 F-7).
func austerity_decay_mult() -> float:
	return float(_recovery.get("AUSTERITY_DECAY_MULT", 1.0)) if austerity_active else 1.0


## Layer 4, without a charge: book a liability the city owes but the treasury
## may not pay right now. Used for work already in flight when austerity lands —
## doc 03 §2.10 layer 2 never strands a half-built tower, so the phase proceeds
## and the money is owed instead of silently forgiven.
func defer(amount: int, category: StringName = &"misc", reason: String = "") -> Dictionary:
	if amount <= 0:
		return {"ok": true, "reason_code": &"", "deferred": 0, "balance": balance}
	deferred_liability += amount
	var units := float(amount) / 1000.0
	_emit(&"deferred_liability_accrued", {
		"amount": amount, "total": deferred_liability,
		"condition_penalty_units": units,
		"condition_penalty_per_unit": float(_recovery.get(
				"DEFERRED_CONDITION_PENALTY_PER_1000", 0.0)),
		"condition_penalty_total": units * float(_recovery.get(
				"DEFERRED_CONDITION_PENALTY_PER_1000", 0.0)),
		"category": category, "reason": reason})
	return {"ok": false, "reason_code": &"DEFERRED", "deferred": amount, "balance": balance}


## Layer 5: free, automatic, cooldowned, capped, and absent on crisis.
## All four §2.10 conditions must hold; returns the granted amount (0 = no grant).
func maybe_grant_relief(hour: int, daily_gross_revenue: float,
		trailing_net_24: float) -> int:
	var allowed := int(_difficulty.get("relief_grants_per_era", 0))
	if relief_grants_used >= allowed:
		return 0
	var trigger := float(_recovery.get("RELIEF_TRIGGER_CREDIT_FRACTION", 0.5))
	if float(balance) > -trigger * float(credit_limit):
		return 0
	if trailing_net_24 > 0.0:
		return 0
	var cooldown := int(_recovery.get("RELIEF_COOLDOWN_HOURS", 0))
	if relief_last_grant_hour >= 0 and hour - relief_last_grant_hour < cooldown:
		return 0
	var grant: int = clampi(
			CostCurves.round_half_up(float(_recovery.get("RELIEF_DAYS_OF_REVENUE", 0.0))
					* daily_gross_revenue),
			int(_recovery.get("RELIEF_MIN", 0)), int(_recovery.get("RELIEF_MAX", 0)))
	relief_grants_used += 1
	relief_last_grant_hour = hour
	balance += grant
	_emit(&"relief_grant_awarded", {"hour": hour, "amount": grant,
			"grants_used": relief_grants_used, "balance": balance})
	return grant


# ------------------------------------------------------------- persistence

## The money half of doc 03 §3.3's `"economy"` save section. `EconomySystem`
## owns the rest of the section and merges this in.
func serialize() -> Dictionary:
	return {
		"treasury": balance,
		"revenue_carry_millidollars": carry_millidollars,
		"deferred_liability": deferred_liability,
		"credit_limit_cached": credit_limit,
		"austerity_active": austerity_active,
		"austerity_entered_hour": null if austerity_entered_hour < 0 else austerity_entered_hour,
		"relief_grants_used": relief_grants_used,
		"relief_last_grant_hour": null if relief_last_grant_hour < 0 else relief_last_grant_hour,
		"ledger_totals": lifetime.duplicate(),
	}


## NOTE: JSON numbers arrive as floats — every read casts (SaveSection contract).
func deserialize(data: Dictionary) -> void:
	balance = int(data.get("treasury", 0))
	carry_millidollars = int(data.get("revenue_carry_millidollars", 0))
	deferred_liability = int(data.get("deferred_liability", 0))
	credit_limit = int(data.get("credit_limit_cached", 0))
	austerity_active = bool(data.get("austerity_active", false))
	austerity_entered_hour = _nullable_int(data.get("austerity_entered_hour", null))
	relief_grants_used = int(data.get("relief_grants_used", 0))
	relief_last_grant_hour = _nullable_int(data.get("relief_last_grant_hour", null))
	var totals: Dictionary = data.get("ledger_totals", {})
	for key in lifetime:
		lifetime[key] = int(totals.get(key, 0))


# ---------------------------------------------------------------- plumbing

func _note_lifetime(category: StringName, amount: int) -> void:
	match category:
		&"tax":
			lifetime["lifetime_tax"] = int(lifetime["lifetime_tax"]) + amount
		&"tariff":
			lifetime["lifetime_tariff"] = int(lifetime["lifetime_tariff"]) + amount
		&"repair":
			lifetime["lifetime_repairs"] = int(lifetime["lifetime_repairs"]) + amount


func _fail(reason_code: StringName, payload: Dictionary) -> Dictionary:
	var out := {"ok": false, "reason_code": reason_code, "spent": 0, "deferred": 0,
			"credited": 0, "balance": balance}
	out.merge(payload)
	return out


func _emit(event_type: StringName, payload: Dictionary) -> void:
	var event := payload.duplicate()
	event["type"] = event_type
	_events.append(event)


static func _to_millidollars(dollars: float) -> int:
	return CostCurves.round_half_up(dollars * float(MILLIDOLLARS_PER_DOLLAR))


## Floor division that stays floor-ward for negatives (GDScript's `/` truncates).
static func _floor_div(numerator: int, denominator: int) -> int:
	var quotient := numerator / denominator
	if numerator % denominator != 0 and (numerator < 0) != (denominator < 0):
		quotient -= 1
	return quotient


static func _nullable_int(value: Variant) -> int:
	return -1 if value == null else int(value)
