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
## The city level whose era `relief_grants_used` is counting (doc 93 §AP4).
## Starts at 0, the founding level, so the first level-up opens the second era.
var relief_era_level: int = 0
## **WHAT THIS ERA'S EARLIER GRANTS ALREADY PAID — doc 93 §AS4 (Wave 21).**
## Dollars, reset with the allowance by [note_era], persisted because the ladder
## it caps is persisted.
##
## §AP4 authored `RELIEF_DAMAGE_FRACTION` at 0.35 with the argument *"0.35 < 1,
## so the grant never covers the restore bill it is measured against"*. That is
## true of ONE grant and false of an era: `relief_grants_per_era` is 3 on
## standard, and 3 × 0.35 = **1.05**. Doc 92 §60.4 measured it on the player's
## own slot 0 — **$305,827 of relief against a $296,438 restore bill, 1.03×** in
## fourteen game-days, and $618,010 across two eras. The one inequality the
## ruling rests on was false in the shipped build.
##
## This is the counter that makes each grant see what the era already paid; see
## [maybe_grant_relief] for the arithmetic and for why the revenue term is
## deliberately outside the cap.
var relief_era_paid: int = 0
## Set by [deserialize] when the save predates doc 93 §AP4, cleared by the one
## caller that acts on it. Never persisted and never read by the ladder itself:
## it exists so the migration is a MIGRATION — conditional on the save's shape —
## rather than a reset that runs on every load, which would make a save→load
## round trip diverge from an uninterrupted run and break constitution §5.
var relief_needs_era_migration: bool = false

## Doc 03 §2.5's revenue and repair rows, counted for life. `lifetime_street` is
## doc 06 §2.16's opportunity bounties and is its OWN row on purpose: folding
## street money into `lifetime_tax` would make the tax slider look like it moved
## when the player simply tapped more, and the budget sheet's whole job is to
## tell the player which lever did what. Counters migrate by appending at 0 and
## never renaming — `deserialize` walks the keys it has, so an older
## `ledger_totals` block restores the rows it carries and starts this one at
## zero, which is what a city that could not earn it genuinely had.
## **Two rows land here in Wave 19, together, on purpose** — doc 91 A91-D-37 and
## A91-D-100. Both were `_note_lifetime` arms that did not exist: `&"incident"`
## (what auto-dispatch has earned the city for life) and `&"restore"` (what the
## player has spent bringing ruins back). A91-D-100's own row says why they were
## left open and who closes them: this dictionary is captured into
## `canonical_capture().ledger_totals` and therefore into `state_hash()`, so
## adding a key moves ALL FOUR `profile_sim` baselines on both cities — and the
## row rules that they close "in a lane that holds the balance matrix … as one
## `ledger_totals` edit and one re-record", because doing them separately costs
## two re-records for one schema change. Wave 19 holds the matrix.
var lifetime: Dictionary = {
	"lifetime_tax": 0, "lifetime_tariff": 0, "lifetime_expense": 0,
	"lifetime_repairs": 0, "lifetime_foregone": 0, "lifetime_street": 0,
	"lifetime_dispatch": 0, "lifetime_restores": 0, "lifetime_relief": 0,
}

## **The city-services receipt book** (doc 03 §2.5, report 98 RR-78).
##
## A dispatch payout and a street collection are paid the instant they are
## earned — the player taps and the number moves, which is the whole point of
## the money pass — but they are still OPERATING revenue and doc 03's income
## statement has to name them. So the cash goes through `credit()` like any
## other credit, and the dollars are *also* tallied here by source until the
## next settlement reads them.
##
## `EconomySystem` books the tally as the `city_services` revenue line, includes
## it in `gross` and `net`, and then settles `revenue − services` in cash,
## because that cash has already moved. There is exactly one dollar and exactly
## one line; what differs is the moment.
##
## It is serialised (defaulting to 0 on any older save) because a save taken
## between a resolve and the hour's settlement would otherwise lose a line the
## income statement is about to print — and `save → load → advance` has to be
## bit-identical.
## The §2.5 city-services line's sub-grain. `contracts` joined in Wave 19 for
## doc 03 §2.5b's commissions board: the settlement's `services_total` is the SUM
## of this dictionary, so a source with no key here would move the balance and
## not the line, and the ledger would disagree with the treasury. Adding a key
## moves every determinism baseline (it is inside `serialize()` and therefore
## inside `state_hash()`), which is why the three LIFETIME arms doc 91 A91-D-37 /
## A91-D-100 / A91-D-108 owe are still deferred: they are a separate dictionary
## and a separate re-record, and they belong in one edit with each other.
var hour_city_services: Dictionary = {"dispatch": 0, "street": 0, "contracts": 0}

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


## A city-services receipt (doc 03 §2.5, RR-78): the same `credit()` as any
## other, plus a tally the hour's settlement will print on its own ledger line.
## `source` is `"dispatch"`, `"street"` or `"contracts"`; an unknown source is credited and
## tallied under `dispatch` rather than dropped, because losing the tally would
## make the line disagree with the balance.
## **The second `_note_lifetime` is not a double count, and it is a FIX** (Wave
## 15, report 98 RR-88). `credit()` above is handed the CATEGORY `city_services`,
## which `_note_lifetime` has no arm for; the lifetime row this feature promises
## is keyed on the SOURCE, and nothing was passing the source anywhere near it.
## So `ledger_totals.lifetime_street` — doc 03 §2.5's own named row, the one the
## comment two paragraphs up calls "its OWN row on purpose" — has read **zero on
## every city since the layer shipped**, while the cash it is supposed to count
## sat correctly in the balance. A counter that is always zero is worse than a
## missing one: it answers the question.
##
## `dispatch` gets nothing here and that is deliberate, not an oversight —
## `_note_lifetime` has no `&"incident"` arm to credit, doc 91 A91-D-37 is the
## row that would build one, and inventing a key here would put a lifetime
## counter in this file that doc 03 has not published.
func credit_city_service(amount: int, source: String,
		reason: String = "") -> Dictionary:
	var result := credit(amount, &"city_services", reason)
	if not bool(result.get("ok", false)):
		return result
	var key := source if hour_city_services.has(source) else "dispatch"
	hour_city_services[key] = int(hour_city_services[key]) + amount
	_note_lifetime(StringName(key), amount)
	return result


## Drained by `CitySim` once per settled game-hour, immediately before doc 03's
## settlement reads it. Returns the tally and resets the book.
func take_hour_city_services() -> Dictionary:
	var out := hour_city_services.duplicate()
	for key in hour_city_services:
		hour_city_services[key] = 0
	return out


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


## One published `data/economy.json recovery` constant, by name (Wave 19). The
## ladder's own code reads `_recovery` directly; this exists so a TEST, a gate or
## a balance instrument can quote the shipped number instead of restating it —
## a restated constant is a second source of truth that drifts silently, which is
## the failure C-07 exists to prevent for prices and which applies just as well
## to the fractions beside them.
func recovery_value(key: String, fallback: float = 0.0) -> float:
	return float(_recovery.get(key, fallback))


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


## Doc 03 §2.10 layer 5, **the bottom rung of the recovery ladder, which Wave 19
## gave a bottom** (doc 93 §AP4). Free, automatic, cooldowned, capped, and absent
## on crisis. All four §2.10 conditions must hold; returns the granted amount
## (0 = no grant).
##
## `outstanding_restore_cost` is doc 03's own price — `CostCurves`'s restore
## quote summed over the city's ACTUAL ruins — and it is passed in rather than
## computed here because this file may not walk a building roster. 0 means "no
## ruins", which reduces this function to exactly the pre-Wave-19 formula.
##
## **Two defects, one function** (doc 91 A91-D-103 / A91-D-104):
##
## 1. *the allowance had no era.* `relief_grants_used` was incremented,
##    persisted, and reset by nothing anywhere in the project, so
##    `relief_grants_per_era` was a LIFETIME allowance of three on standard —
##    for a game meant to be played for weeks. [note_era] is the reset, and the
##    era is a city level (see it for the derivation).
## 2. *the grant shrank with the disaster.* `1.5 × daily_gross_revenue` is
##    measured on the city AFTER the loss, so the worse the catastrophe the
##    smaller the relief; at the limit the 2026-09-03 report describes — every
##    building a ruin — gross revenue is near zero and the grant is `RELIEF_MIN`
##    against a restore bill in the hundreds of thousands. The `max()` below is
##    the fix: relief is the LARGER of what the city normally earns in a day and
##    a half and a fixed fraction of what it would cost to put the city back.
##
## **THE ANTI-FARM IS AN INEQUALITY, AND WAVE 21 MADE IT TRUE PER ERA — doc 93
## §AS4.** §AP4's argument was *"`RELIEF_DAMAGE_FRACTION < 1`, so the grant never
## covers the restore bill it is measured against"*. Read per GRANT that is
## sound; read per ERA it is false, because `relief_grants_per_era` is 3 and
## 3 × 0.35 = 1.05 — and doc 92 §60.4 measured the city collecting **1.03× its
## own restore bill** on the shipped build. The damage term is therefore charged
## against what this era has already paid ([relief_era_paid]):
##
##     damage_term = max(0, RELIEF_DAMAGE_FRACTION × bill − relief_era_paid)
##
## so however many grants an era holds, the damage side of relief sums to at most
## `RELIEF_DAMAGE_FRACTION × (the largest bill any of them was measured against)`
## — strictly below the bill, which is the sentence §AP4 meant to be writing. No
## new constant: the cap is the fraction that was already there, applied to the
## era instead of to the grant.
##
## **AND THE HEADING WAS STILL FALSE, BECAUSE THE FLOOR IS NOT A TERM — doc 93
## §AV2.** §AS4 capped the two TERMS and left `RELIEF_MIN` clamping the result
## from below, outside both. `RELIEF_MIN × relief_grants_per_era` is
## $8,000 × 3 = $24,000 of relief an era pays whatever it is measured against, so
## every bill under ~$24,615 was out-paid and a $2,000 one drew **12.0×** itself.
## The ERA CEILING in [maybe_grant_relief] is what closes it:
##
##     era_ceiling = max(revenue_term, outstanding_restore_cost)
##     grant       = min(max(revenue_term, damage_term, RELIEF_MIN),
##                       era_ceiling − relief_era_paid)
##
## **State the guarantee exactly, because the loose form is what went wrong the
## first time.** What is now true is *"an era's relief never exceeds the LARGER
## of what the city earns in a day and a half and the restore bill it was
## measured against"*. That is NOT the same sentence as *"an era never out-pays
## its bill"*, and the difference is the case where the bill is the smaller of
## the two: a city with no ruins and real revenue can still collect its revenue
## term, which is the pre-Wave-19 ladder and is meant to. Wherever the DAMAGE
## side is what is paying — which is every case §AP4's inequality was written
## about and every disaster this ladder exists for — the ceiling IS the bill and
## the era cannot out-pay it. The floor still lifts a single grant to
## `RELIEF_MIN` whenever there is room for it, which is every case the floor was
## written for.
##
## **The revenue term is deliberately outside the DAMAGE cap** — and inside the
## era ceiling, which is a different statement and not a retraction. `1.5 × daily
## gross` is the pre-Wave-19 ladder, it is measured on what the city EARNS rather
## than on what it lost, and it is what carries a city whose ruins are already
## restored; netting it against `RELIEF_DAMAGE_FRACTION × bill` would mean a city
## that used its relief well gets nothing the next time it is in trouble. The era
## ceiling does not do that, because it GROWS with the revenue term: a city that
## recovers re-opens its own room. It is separately bounded by the insolvency
## pair, the 120-game-hour cooldown, `relief_grants_per_era` and `RELIEF_MAX`.
##
## The rest of the gating is unchanged, and the bill SHRINKS as it is spent, so
## relief decays back to the revenue term as the city recovers.
func maybe_grant_relief(hour: int, daily_gross_revenue: float,
		trailing_net_24: float, outstanding_restore_cost: float = 0.0) -> int:
	if not relief_gates_pass(hour, trailing_net_24):
		return 0
	var revenue_term := float(_recovery.get("RELIEF_DAYS_OF_REVENUE", 0.0)) \
			* daily_gross_revenue
	var damage_allowance := float(_recovery.get("RELIEF_DAMAGE_FRACTION", 0.0)) \
			* maxf(0.0, outstanding_restore_cost)
	var damage_term := maxf(0.0, damage_allowance - float(relief_era_paid))
	# **THE FLOOR SAT OUTSIDE THE CAP, AND THREE OF THEM OUT-PAID THE BILL — doc
	# 93 §AV2.** `clampi(…, RELIEF_MIN, RELIEF_MAX)` lifts EVERY grant to $8,000,
	# and `relief_grants_per_era` is 3 on `standard`, so an era paid $24,000
	# however small the thing it was measured against: a $2,000 restore bill drew
	# **12.0× its own bill** (doc 92 §62.5). §AS4 charged the DAMAGE term against
	# the era and left the floor beside it, which is the one term that does not
	# shrink.
	#
	# The ceiling is what the grant is MEASURED ON — the larger of the revenue
	# term and the outstanding bill — and it is charged against the era, so the
	# floor may lift a grant but no longer multiply an era. It is the bill
	# itself and NOT `RELIEF_DAMAGE_FRACTION × bill`, because the fraction is
	# already the damage term's own cap and re-using it here would cut the
	# disaster case: on the player's slot 0 this line changes nothing at all
	# ($98,727 + $8,000 + $8,000, bit-identical, doc 92 §62.5), and it is the
	# small-bill case it closes.
	#
	# The revenue term stays outside the DAMAGE cap for the reason above and is
	# inside this one, which is not the same statement: a city that earns more
	# gets a bigger ceiling, so recovering re-opens the room rather than closing
	# it.
	var era_ceiling := maxf(revenue_term, maxf(0.0, outstanding_restore_cost))
	var era_room := maxf(0.0, era_ceiling - float(relief_era_paid))
	var grant: int = clampi(
			CostCurves.round_half_up(minf(maxf(maxf(revenue_term, damage_term),
					float(_recovery.get("RELIEF_MIN", 0))), era_room)),
			0, int(_recovery.get("RELIEF_MAX", 0)))
	# **A GRANT OF NOTHING IS NOT A GRANT.** The era's allowance is three real
	# rescues, and an ask that prices to zero may not burn one of them — that
	# would hand the ceiling a way to end the ladder early. The COOLDOWN is still
	# stamped, because the ask was made and `outstanding_restore_cost` is an
	# O(roster) walk the caller has already paid for: without it this branch
	# re-prices the whole roster every settled game-hour.
	if grant <= 0:
		relief_last_grant_hour = hour
		return 0
	relief_grants_used += 1
	relief_last_grant_hour = hour
	relief_era_paid += grant
	balance += grant
	_note_lifetime(&"relief", grant)
	_emit(&"relief_grant_awarded", {"hour": hour, "amount": grant,
		"grants_used": relief_grants_used, "balance": balance,
		"revenue_term": revenue_term, "damage_term": damage_term,
		"damage_allowance": damage_allowance, "era_paid": relief_era_paid,
		"outstanding_restore_cost": outstanding_restore_cost})
	return grant


## The four §2.10 gates that do not need a price, split out of
## [maybe_grant_relief] so a caller can ask *"is it even worth pricing the
## damage?"* before walking a roster.
##
## This is a PERFORMANCE seam and it earns its keep: `update_recovery_ladder`
## runs once per settled game-hour, `outstanding_restore_cost()` is O(roster),
## and the bench city carries 1 500 buildings. On every city that is not deep in
## the credit line — which is every city, almost always — these four comparisons
## return false and the walk never happens. Splitting it also means the gates are
## stated exactly once and both callers read the same four.
func relief_gates_pass(hour: int, trailing_net_24: float) -> bool:
	if relief_grants_used >= int(_difficulty.get("relief_grants_per_era", 0)):
		return false
	var trigger := float(_recovery.get("RELIEF_TRIGGER_CREDIT_FRACTION", 0.5))
	if float(balance) > -trigger * float(credit_limit):
		return false
	if trailing_net_24 > 0.0:
		return false
	var cooldown := int(_recovery.get("RELIEF_COOLDOWN_HOURS", 0))
	if relief_last_grant_hour >= 0 and hour - relief_last_grant_hour < cooldown:
		return false
	return true


## Doc 93 §AP4: **an era is a city level.** `relief_grants_per_era` has carried
## that word since doc 03 §2.9 was authored and nothing in the project ever
## defined it, so the allowance was spent once and gone.
##
## A city level is the smallest honest definition available: the quantity is
## already tracked, already persisted, already composed from both routes by
## doc 93 §G1, and it only ever goes UP — so the allowance refreshes when the
## city demonstrably grew, and cannot be farmed by oscillating anything. Crisis
## stays at 0 per era, because crisis is a preset that is allowed to be lost.
##
## Called by `ProgressionSystem` on the same transition that pays
## `LEVEL_UP_GRANT_BY_CITY_LEVEL`. Idempotent: a level that has already opened
## an era opens nothing.
func note_era(city_level: int) -> void:
	if city_level <= relief_era_level:
		return
	relief_era_level = city_level
	relief_grants_used = 0
	# Doc 93 §AS4: the allowance and the money it may hand out are one thing, so
	# they reset together. A new era is a new bill, not a running total.
	relief_era_paid = 0


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
		"relief_era_level": relief_era_level,
		"relief_era_paid": relief_era_paid,
		"relief_last_grant_hour": null if relief_last_grant_hour < 0 else relief_last_grant_hour,
		"ledger_totals": lifetime.duplicate(),
		"hour_city_services": hour_city_services.duplicate(),
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
	relief_era_level = int(data.get("relief_era_level", 0))
	# Doc 93 §AS4. Absent on every save written before the cap, and 0 is the
	# honest reading there: those cities have no recorded era spend, so the first
	# grant after the load is capped at the full fraction of the bill and no
	# more — the same answer a city that had taken no grant yet would get.
	relief_era_paid = int(data.get("relief_era_paid", 0))
	## A save written BEFORE doc 93 §AP4 carries no `relief_era_level` at all,
	## and the flag says so for exactly one caller — see
	## `CitySim._restore_systems`, which is the only place that can know what
	## level the city reached. It is set on every load and consumed immediately,
	## never persisted.
	relief_needs_era_migration = not data.has("relief_era_level")
	relief_last_grant_hour = _nullable_int(data.get("relief_last_grant_hour", null))
	var totals: Dictionary = data.get("ledger_totals", {})
	for key in lifetime:
		lifetime[key] = int(totals.get(key, 0))
	# RR-78. Absent on every save written before the money pass, and 0 is the
	# right answer there: those cities booked the payout straight to the balance
	# and had no line waiting to be printed.
	var services: Dictionary = data.get("hour_city_services", {})
	for key in hour_city_services:
		hour_city_services[key] = int(services.get(key, 0))


# ---------------------------------------------------------------- plumbing

func _note_lifetime(category: StringName, amount: int) -> void:
	match category:
		&"tax":
			lifetime["lifetime_tax"] = int(lifetime["lifetime_tax"]) + amount
		&"tariff":
			lifetime["lifetime_tariff"] = int(lifetime["lifetime_tariff"]) + amount
		&"repair":
			lifetime["lifetime_repairs"] = int(lifetime["lifetime_repairs"]) + amount
		&"street":
			lifetime["lifetime_street"] = int(lifetime["lifetime_street"]) + amount
		# Wave 19, doc 91 A91-D-37 / A91-D-100. `dispatch` is the source key
		# `credit_city_service` already passes and this arm was the reason the
		# comment there says "dispatch gets nothing here"; `restore` is the
		# category `CitySim.cmd_restore_building` already spends under; `relief`
		# is doc 03 §2.10 layer 5's grant, counted so an assistance floor can
		# never be audited by guesswork.
		&"dispatch":
			lifetime["lifetime_dispatch"] = int(lifetime["lifetime_dispatch"]) + amount
		&"restore":
			lifetime["lifetime_restores"] = int(lifetime["lifetime_restores"]) + amount
		&"relief":
			lifetime["lifetime_relief"] = int(lifetime["lifetime_relief"]) + amount


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
