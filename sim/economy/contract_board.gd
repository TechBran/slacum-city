class_name ContractBoard
extends RefCounted
## Doc 03 §2.5b — **THE COMMISSIONS BOARD**: work the city takes on a clock, and
## the biggest single thing a player can collect.
##
## **Why it exists,** in the player's own words after the 2026-09-03 overnight
## report: *"The crimes we stop are only a few hundred dollars — add a zero to
## that. 15,000 for one. And any other fun ideas to collect money in the game,
## something to actually DO to collect, other than tax revenue."*
##
## The first half of that sentence cannot be answered where it was asked. The
## street layer delivers 0.339 offers per game-hour, so a $15,000 pickup is
## $5,090/gh — **1.85× the whole net income of a level-6 city** (doc 92 §57.1).
## A number that size has to belong to something that happens about once a
## game-day, and this is that something.
##
## ── the loop ──────────────────────────────────────────────────────────────
##
## A CLIENT posts a commission to the board: a film unit that needs fresh street
## laid for a chase scene, a county that pays a retainer for incidents answered,
## an insurer that pays for stock brought back. The player **accepts** one — the
## city may hold exactly one at a time — which starts a deadline in game-hours.
## They then do the work with the verbs they already have. When the target is met
## the contract goes `ready` and the player **claims** it, which is when the money
## moves. After a claim the board is quiet for a cooldown, and that cooldown is
## the only thing bounding this layer's income.
##
## ── the four rules that keep it honest ────────────────────────────────────
##
## **1. Nothing here spawns value; a CLAIM is money.** A completed contract is a
## row with `state = ready` and nothing else has happened — no treasury, no
## district, no building. The same rule `OpportunitySystem` holds, for the same
## reason: this layer is a reward for attention, and an attention reward that
## pays itself is a rate with extra steps.
##
## **2. It is a FINE-PATH system.** `advance` does nothing at all when `online`
## is false: no offers appear, no deadline runs, no offer ages and no draw is
## taken. So a player who was away finds the board exactly as they left it —
## doc 08 §2.3 rule 9's fairness rule made structural rather than remembered —
## and the balance matrix, which runs the coarse step, cannot see this file.
##
## **3. It owns no dollar.** `data/contracts.json` says which commissions exist,
## what they ask for and how long they run; every dollar is
## `data/economy.json`'s `city_services.contract_payout`, read through
## `CostCurves` (C-07). A tier priced by nothing is a BOOT ERROR, not a silent
## $0 commission.
##
## **4. It invents no objective vocabulary.** Progress is counted off the same
## `EVENT_KINDS` table doc 09's curriculum uses, so a contract can only ask for
## something the game already knows how to notice — and a verb that grows a
## curriculum objective grows a contract kind for free.
##
## Deterministic by construction: one named stream (`contracts`, constitution
## §5), no clock of its own, sorted iteration, and every float that reaches a
## save goes through `CitySim`'s `~f~` encoder.

## Constitution §5's named stream for this system, and the only one it touches.
const STREAM_NAME := "contracts"

## C-07: `data/contracts.json` may carry no dollar, at any depth. The same guard
## `OpportunitySystem.FORBIDDEN_KEYS` puts on the street table and
## `IncidentCatalog.FORBIDDEN_KEYS` puts on `reward_base` — a price re-appearing
## in a sibling file is a boot error, not a second source of truth found six
## weeks later.
const FORBIDDEN_KEYS: Array[String] = ["reward", "payout", "base", "spread",
		"reward_city_level_k"]

## The one objective kind the curriculum does not have, because until Wave 19 no
## verb produced it. Merged over `GoalSystem.EVENT_KINDS` rather than replacing
## it, so every kind doc 09 can teach is a kind a client can pay for.
##
## `restore_buildings` counts the COMMAND, not the completion — the same reading
## `repair_buildings` takes — because a contract that ticked two game-hours after
## the tap would be a contract the player could not tell they were making
## progress on.
const EXTRA_EVENT_KINDS: Dictionary = {
	&"restore_buildings": {"event": &"restore_started_sim",
			"match_field": "", "match_key": "", "amount": ""},
}

## A contract's three states. `offered` is on the board and unclaimed by the
## city; `active` is accepted and running against a deadline; `ready` is finished
## and waiting for the tap that pays.
const STATE_OFFERED := &"offered"
const STATE_ACTIVE := &"active"
const STATE_READY := &"ready"

# ------------------------------------------------------------- authored data
## `data/contracts.json board`, with the fallbacks a fixture-built board needs
## before `configure()`.
var offer_interval_h: float = 6.0
var max_offers: int = 2
var offer_lifetime_h: Array = [24.0, 36.0]
var cooldown_h_after_claim: float = 30.0
var _templates: Array = []

## Doc 03 §2.5b's price table, the ONLY place this system's dollars come from.
## Held whole rather than resolved through a `Callable` for the same reason
## `OpportunitySystem.payouts` is: it is a parsed data file that outlives every
## tick and holds no reference back to `CitySim`, so there is no cycle to break.
var payouts: CostCurves = null

## `func() -> int` — doc 09's city level. Asked at OFFER time and frozen onto the
## row, never at claim time: the money on the card is the money that is paid, the
## same freeze `OpportunitySystem` applies to a bounty at spawn.
var city_level: Callable = Callable()

## Boot errors, drained into `CitySim.boot_errors`. A tier no price table names,
## or a kind no evaluator knows, is a boot error — a commission worth $0 or one
## that can never progress looks exactly like a balance decision until somebody
## plays it.
var errors: PackedStringArray = []

# -------------------------------------------------------------- live state
var _offers: Array = []
var _active: Dictionary = {}
var _cooldown_h: float = 0.0
var _next_id: int = 1
var _rng: RandomNumberGenerator = null
var _events: Array[Dictionary] = []


func _init(table: Dictionary = {}) -> void:
	if not table.is_empty():
		configure(table)


## Parse `data/contracts.json`. Refuses a file that carries a price (C-07) and
## drops a template whose objective kind nothing can evaluate — DROPS rather than
## crashes, exactly as `GoalSystem` drops an unknown curriculum kind, because one
## bad row must not take the whole board down with it.
func configure(table: Dictionary) -> void:
	_assert_no_prices(table)
	var board: Dictionary = table.get("board", {})
	offer_interval_h = maxf(0.001, float(board.get("offer_interval_h", offer_interval_h)))
	max_offers = maxi(1, int(board.get("max_offers", max_offers)))
	cooldown_h_after_claim = maxf(0.0,
			float(board.get("cooldown_h_after_claim", cooldown_h_after_claim)))
	var life: Array = board.get("offer_lifetime_h", offer_lifetime_h)
	if life.size() == 2:
		offer_lifetime_h = [float(life[0]), float(life[1])]
	_templates = []
	for row_variant: Variant in table.get("templates", []):
		var row: Dictionary = row_variant
		var kind := StringName(String(row.get("kind", "")))
		if not knows_kind(kind):
			errors.append("data/contracts.json: template '%s' asks for objective kind "
					% String(row.get("id", "?"))
					+ "'%s', which no evaluator knows" % String(kind))
			continue
		_templates.append({
			"id": String(row.get("id", "")),
			"tier": String(row.get("tier", "minor")),
			"kind": kind,
			"match_key": String(row.get("match_key", "")),
			"target": maxi(1, int(row.get("target", 1))),
			"deadline_h": maxf(1.0, float(row.get("deadline_h", 24.0))),
			"min_city_level": maxi(1, int(row.get("min_city_level", 1))),
			"weight": maxf(0.0, float(row.get("weight", 1.0))),
			"client_key": String(row.get("client_key", "")),
			"text_key": String(row.get("text_key", "")),
		})
	# The draw order is a CONTRACT, not a list: `_pick_template` walks it, so a
	# reorder would re-associate the stream. Sorted by id, which is the one
	# ordering a JSON file cannot silently change under a reader.
	_templates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a["id"]) < String(b["id"]))


## Every kind this board can evaluate: doc 09's curriculum vocabulary plus
## [EXTRA_EVENT_KINDS]. Public so the guard test can assert the union rather
## than restate it.
static func knows_kind(kind: StringName) -> bool:
	return GoalSystem.EVENT_KINDS.has(kind) or EXTRA_EVENT_KINDS.has(kind)


static func rule_for(kind: StringName) -> Dictionary:
	if EXTRA_EVENT_KINDS.has(kind):
		return EXTRA_EVENT_KINDS[kind]
	return GoalSystem.EVENT_KINDS.get(kind, {})


## Bound AFTER `configure()`, because the check it performs is *"every tier this
## board can offer has a price"* — the same order `OpportunitySystem.bind_payouts`
## uses and for the same reason.
func bind_payouts(curves: CostCurves) -> void:
	payouts = curves
	if curves == null:
		return
	var seen: Dictionary = {}
	for row_variant: Variant in _templates:
		var tier := String((row_variant as Dictionary)["tier"])
		if seen.has(tier):
			continue
		seen[tier] = true
		if not curves.has_contract_payout(tier):
			errors.append("data/economy.json city_services.contract_payout prices no "
					+ "tier '%s', which data/contracts.json offers" % tier)


func bind_stream(streams: RngStreams) -> void:
	_rng = streams.stream(STREAM_NAME)


func _assert_no_prices(value: Variant, depth: int = 0) -> void:
	if value is Dictionary:
		for key in (value as Dictionary):
			if depth > 0 and FORBIDDEN_KEYS.has(String(key)):
				errors.append("data/contracts.json carries the price key '%s'; "
						% String(key)
						+ "every dollar belongs to data/economy.json "
						+ "city_services.contract_payout")
			_assert_no_prices((value as Dictionary)[key], depth + 1)
	elif value is Array:
		for entry in (value as Array):
			_assert_no_prices(entry, depth + 1)


func dispose() -> void:
	city_level = Callable()
	payouts = null
	_rng = null


# ----------------------------------------------------------------- the tick

## One board step. `dt_h` is the phase adapter's own period in game-hours, never
## an accumulated delta.
##
## **`online == false` returns immediately and draws NOTHING**, which is the
## whole of this system's coarse contract: no offer appears while the player is
## away, no deadline runs down, no offer ages out, and the `contracts` stream is
## not advanced by a single call. A player who closes the app mid-commission
## finds it with exactly the hours left they left it with.
func advance(dt_h: float, online: bool) -> void:
	if not online or dt_h <= 0.0:
		return
	if _cooldown_h > 0.0:
		_cooldown_h = maxf(0.0, _cooldown_h - dt_h)
	_age_active(dt_h)
	_age_offers(dt_h)
	_try_offer(dt_h)


## The accepted contract's deadline. An expiry costs the player NOTHING — no
## fee, no stability, no reputation — and that is ruled, not omitted (doc 93
## §AQ3): this layer exists because a playtester asked for something to DO, and a
## penalty for not finishing converts an opportunity into a chore. It would also
## tax precisely the player who put the phone down, which is the player doc 08
## §2.3 rule 9 promises not to punish.
##
## A `ready` contract does NOT expire. The work is done; the money is owed; the
## tap is a formality the player is entitled to take whenever they next look.
func _age_active(dt_h: float) -> void:
	if _active.is_empty() or StringName(String(_active["state"])) == STATE_READY:
		return
	_active["remaining_h"] = float(_active["remaining_h"]) - dt_h
	if float(_active["remaining_h"]) > 0.0:
		return
	var expired := _active
	_active = {}
	_emit(&"contract_expired", expired)


func _age_offers(dt_h: float) -> void:
	var kept: Array = []
	for row_variant: Variant in _offers:
		var row: Dictionary = row_variant
		row["remaining_h"] = float(row["remaining_h"]) - dt_h
		if float(row["remaining_h"]) > 0.0:
			kept.append(row)
		else:
			_emit(&"contract_withdrawn", row)
	_offers = kept


## One Bernoulli per step at `dt_h / offer_interval_h`, skipped entirely while
## the board is full or a cooldown is running — **two draws per successful offer
## and none on a quiet step**, all on the `contracts` stream.
##
## The cooldown suppresses OFFERS as well as accepts, so the quiet stretch after
## a claim is visible on the board rather than only in a refusal. That is the
## whole of the income bound: with one contract at a time, income cannot exceed
## one payout per `cooldown_h_after_claim`, whatever the player does.
func _try_offer(dt_h: float) -> void:
	if _rng == null or _cooldown_h > 0.0 or _offers.size() >= max_offers:
		return
	if _rng.randf() >= clampf(dt_h / offer_interval_h, 0.0, 1.0):
		return
	var template := _pick_template()
	if template.is_empty():
		return
	var level := maxi(1, _city_level())
	var u := _rng.randf()
	var life := lerpf(float(offer_lifetime_h[0]), float(offer_lifetime_h[1]), _rng.randf())
	var row := {
		"id": _next_id,
		"template": String(template["id"]),
		"tier": String(template["tier"]),
		"kind": String(template["kind"]),
		"match_key": String(template["match_key"]),
		"target": int(template["target"]),
		"progress": 0,
		"deadline_h": float(template["deadline_h"]),
		"remaining_h": life,
		"level": level,
		"reward": _reward_for(String(template["tier"]), level, u),
		"state": String(STATE_OFFERED),
		"client_key": String(template["client_key"]),
		"text_key": String(template["text_key"]),
	}
	_next_id += 1
	_offers.append(row)
	_emit(&"contract_offered", row)


## Weighted by the template's own `weight`, filtered to the rungs the city has
## reached. **The level gate is a BALANCE gate and not a difficulty curve**: the
## measured income series is flat from level 2 to level 5 and then triples
## (doc 92 §57.1.1), so the `major` tier's payout only fits inside the ruled
## share at the top rung and is refused below it.
func _pick_template() -> Dictionary:
	var level := maxi(1, _city_level())
	var weights := PackedFloat64Array()
	var total := 0.0
	for row_variant: Variant in _templates:
		var row: Dictionary = row_variant
		var w := float(row["weight"]) if int(row["min_city_level"]) <= level else 0.0
		# One client at a time: a template already on the board or in flight is
		# not offered again, so the board never reads as two copies of the same
		# job.
		if w > 0.0 and _template_in_play(String(row["id"])):
			w = 0.0
		weights.append(w)
		total += w
	if total <= 0.0:
		return {}
	var pick := _rng.randf() * total
	var running := 0.0
	for i in _templates.size():
		running += weights[i]
		if pick < running:
			return _templates[i]
	return _templates[_templates.size() - 1]


func _template_in_play(template_id: String) -> bool:
	if not _active.is_empty() and String(_active["template"]) == template_id:
		return true
	for row_variant: Variant in _offers:
		if String((row_variant as Dictionary)["template"]) == template_id:
			return true
	return false


## Doc 03 §2.5b's payout, frozen at OFFER time — level and all.
##
## `reward = round((base + spread·u) × (1 + CONTRACT_REWARD_CITY_LEVEL_K·(L−1)))`,
## the same shape doc 03 gives a street bounty, because a player who has learned
## to read one of them has learned to read both.
func _reward_for(tier: String, level: int, u: float) -> int:
	if payouts == null:
		return 0
	var band := payouts.contract_payout_base(tier) + payouts.contract_payout_spread(tier) * u
	var scaled := band * (1.0 + payouts.contract_reward_city_level_k() * float(level - 1))
	return maxi(0, int(floor(scaled + 0.5)))


func _city_level() -> int:
	return int(city_level.call()) if city_level.is_valid() else 1


# --------------------------------------------------------------- the counter

## One sim event, called synchronously from `CitySim`'s bus fan-out.
##
## Counts only against the ACCEPTED contract, and only while it is still running:
## a `ready` contract has already earned its money and a board full of offers is
## a board of things the player has not agreed to do. That is the rule that makes
## "accept, then work" a decision rather than a formality — a player who does the
## work first gets nothing for it, and finding that out once teaches the loop.
func observe(event: Dictionary) -> void:
	if _active.is_empty() or StringName(String(_active["state"])) != STATE_ACTIVE:
		return
	var rule := rule_for(StringName(String(_active["kind"])))
	if rule.is_empty():
		return
	if StringName(String(event.get("type", ""))) != StringName(String(rule["event"])):
		return
	var match_field := String(rule.get("match_field", ""))
	if match_field != "" and String(_active["match_key"]) != "":
		if String(event.get(match_field, "")) != String(_active["match_key"]):
			return
	var amount_field := String(rule.get("amount", ""))
	var amount := int(event.get(amount_field, 0)) if amount_field != "" else 1
	if amount <= 0:
		return
	_active["progress"] = mini(int(_active["target"]),
			int(_active["progress"]) + amount)
	if int(_active["progress"]) < int(_active["target"]):
		_emit(&"contract_progress", _active)
		return
	_active["state"] = String(STATE_READY)
	_emit(&"contract_ready", _active)


# ------------------------------------------------------------------ the verbs

## `CitySim.cmd_accept_contract`'s half. Answers the row or an empty dictionary;
## the refusal codes are the command's, because a refusal is a sentence the
## player reads and `sim/economy/` does not write copy.
func accept(offer_id: int) -> Dictionary:
	for i in _offers.size():
		var row: Dictionary = _offers[i]
		if int(row["id"]) != offer_id:
			continue
		_offers.remove_at(i)
		row["state"] = String(STATE_ACTIVE)
		row["remaining_h"] = float(row["deadline_h"])
		row["progress"] = 0
		_active = row
		_emit(&"contract_accepted", row)
		return row.duplicate()
	return {}


## Hands back the finished contract and starts the cooldown. The CREDIT is the
## command's, not this file's: `sim/economy/contract_board.gd` owns when a
## commission is done and `Treasury` owns every dollar that moves.
func claim() -> Dictionary:
	if _active.is_empty() or StringName(String(_active["state"])) != STATE_READY:
		return {}
	var claimed := _active
	_active = {}
	_cooldown_h = cooldown_h_after_claim
	_emit(&"contract_claimed", claimed)
	return claimed.duplicate()


# ------------------------------------------------------------------- readers

func offers() -> Array:
	var out: Array = []
	for row_variant: Variant in _offers:
		out.append((row_variant as Dictionary).duplicate())
	return out


func active() -> Dictionary:
	return _active.duplicate()


func has_active() -> bool:
	return not _active.is_empty()


func is_ready() -> bool:
	return not _active.is_empty() \
			and StringName(String(_active["state"])) == STATE_READY


func cooldown_hours() -> float:
	return _cooldown_h


func find_offer(offer_id: int) -> Dictionary:
	for row_variant: Variant in _offers:
		var row: Dictionary = row_variant
		if int(row["id"]) == offer_id:
			return row.duplicate()
	return {}


func drain_events() -> Array[Dictionary]:
	var out := _events
	_events = [] as Array[Dictionary]
	return out


func _emit(event_type: StringName, row: Dictionary) -> void:
	var payload := row.duplicate()
	payload["type"] = event_type
	_events.append(payload)


# ---------------------------------------------------------------- the save

## City section rung v9 (doc 08 §2.8). The WHOLE board persists — offers, the
## accepted contract with its progress and the hours left on it, the cooldown and
## the id counter — for the same reason the street roster does: a commission the
## player was three quarters of the way through and lost to a phone call is
## exactly the kind of small theft that makes a save feel unsafe.
func serialize() -> Dictionary:
	return {
		"next_id": _next_id,
		"cooldown_h": _cooldown_h,
		"active": _active.duplicate(),
		"offers": offers(),
	}


func deserialize(data: Dictionary) -> void:
	_offers = []
	_active = {}
	_cooldown_h = 0.0
	_next_id = 1
	if data.is_empty():
		return
	_next_id = maxi(1, int(data.get("next_id", 1)))
	_cooldown_h = maxf(0.0, float(data.get("cooldown_h", 0.0)))
	var active_row: Dictionary = data.get("active", {})
	if not active_row.is_empty():
		_active = active_row.duplicate()
	for row_variant: Variant in data.get("offers", []):
		_offers.append((row_variant as Dictionary).duplicate())
