extends SimTest
## `sim/economy/contract_board.gd` — doc 03 §2.5b's commissions board (Wave 19;
## doc 92 §57.3, doc 93 §AQ3, report 98 §60 RR-170).
##
## The player asked for *"something to actually DO to collect, other than tax
## revenue"*, and for a single collection worth about $15,000. This file holds
## both halves: the LOOP (offered → accepted → worked → ready → claimed) and the
## three properties that stop a new income layer eating the game — its coarse
## contract, its one-at-a-time rule and the cooldown that bounds it.

const SEED := 1337
const DATA_PATH := "res://data/contracts.json"


func _board() -> ContractBoard:
	var board := ContractBoard.new(StarterCityLoader.read_json(DATA_PATH))
	board.bind_payouts(CostCurves.load_from_files())
	board.bind_stream(RngStreams.new(SEED))
	board.city_level = func() -> int: return 6
	return board


## Runs the board until it has posted `count` offers, or gives up. Answers the
## game-hours it took, so a test can say how long a player waits.
func _run_until_offers(board: ContractBoard, count: int, limit_h: int = 2000) -> int:
	for h in limit_h:
		board.advance(1.0, true)
		if board.offers().size() >= count:
			return h + 1
	return -1


# ---------------------------------------------------------------- the loop

## Offered → accepted → worked → ready → claimed, and the money moves at exactly
## one of those five steps.
func test_the_whole_loop_and_the_one_step_that_is_money() -> void:
	var sim := CitySim.boot_from_files(SEED)
	assert_true(sim.boot_errors.is_empty(), str(sim.boot_errors))
	sim.progression.city_level = 6
	var board := sim.contracts

	assert_true(_run_until_offers(board, 1) > 0, "the board posts something")
	var offer: Dictionary = board.offers()[0]
	assert_eq(String(offer["state"]), "offered")
	assert_true(int(offer["reward"]) > 0, "and it says what it pays before it is taken")

	var before := sim.treasury.balance
	var accepted := sim.cmd_accept_contract(int(offer["id"]))
	assert_true(bool(accepted["ok"]), str(accepted.get("reason_code", "")))
	assert_eq(sim.treasury.balance, before, "accepting is FREE — no deposit, by ruling")
	assert_true(board.has_active())
	assert_eq(String(board.active()["state"]), "active")
	assert_almost_eq(float(board.active()["remaining_h"]),
			float(offer["deadline_h"]), 1e-9, "the deadline starts at the accept")

	# Not finished yet: the claim refuses and says how far along it is.
	var early := sim.cmd_claim_contract(true)
	assert_false(bool(early["ok"]))
	assert_eq(String(early["reason_code"]), "E_CONTRACT_UNMET")
	assert_eq(int((early["payload"] as Dictionary)["progress"]), 0)

	_finish(sim, board)
	assert_true(board.is_ready(), "the target met makes it claimable")
	assert_eq(sim.treasury.balance, before,
			"and a READY contract has still paid nobody — a claim is the money")

	var reward := int(board.active()["reward"])
	var claimed := sim.cmd_claim_contract()
	assert_true(bool(claimed["ok"]), str(claimed.get("reason_code", "")))
	assert_eq(sim.treasury.balance, before + reward, "the tap is the money")
	assert_false(board.has_active(), "and the board is clear")
	assert_true(board.cooldown_hours() > 0.0, "with the quiet stretch running")
	sim.dispose()


## Progress counts only against an ACCEPTED contract. A player who does the work
## first gets nothing for it, and that is what makes "accept, then work" a
## decision rather than a formality.
func test_work_done_before_the_accept_counts_for_nothing() -> void:
	var sim := CitySim.boot_from_files(SEED)
	sim.progression.city_level = 6
	var board := sim.contracts
	assert_true(_run_until_offers(board, 1) > 0)
	var offer: Dictionary = board.offers()[0]

	# Do the work FIRST, while the offer is still only an offer — with the real
	# payload, so the assertion is about the ACCEPT gate and not about a payload
	# the counter would have ignored anyway.
	var rule := ContractBoard.rule_for(StringName(String(offer["kind"])))
	var step := _step_payload(offer)
	for i in 8:
		sim.bus.emit(StringName(String(rule["event"])), step)
	assert_true(bool(sim.cmd_accept_contract(int(offer["id"]))["ok"]))
	assert_eq(int(board.active()["progress"]), 0,
			"the counter starts at the accept, not at the offer")
	assert_false(board.is_ready())

	# …and the same payload DOES count once the commission is in hand, which is
	# what makes the assertion above a statement about the gate.
	sim.bus.emit(StringName(String(rule["event"])), step)
	assert_eq(int(board.active()["progress"]), 1,
			"the identical event counts the moment the city has agreed to the job")
	sim.dispose()


## One at a time, and the cooldown after a delivery is the layer's income bound.
func test_one_at_a_time_and_the_cooldown_is_the_bound() -> void:
	var sim := CitySim.boot_from_files(SEED)
	sim.progression.city_level = 6
	var board := sim.contracts
	assert_true(_run_until_offers(board, 2) > 0, "the board holds more than one offer")
	var offers := board.offers()
	assert_true(bool(sim.cmd_accept_contract(int(offers[0]["id"]))["ok"]))

	var second := sim.cmd_accept_contract(int(offers[1]["id"]), true)
	assert_false(bool(second["ok"]))
	assert_eq(String(second["reason_code"]), "E_CONTRACT_ACTIVE")

	_finish(sim, board)
	assert_true(bool(sim.cmd_claim_contract()["ok"]))
	var cooldown := board.cooldown_hours()
	assert_almost_eq(cooldown, board.cooldown_h_after_claim, 1e-9)

	# Nothing new is posted during it, so the quiet stretch is visible on the
	# board rather than only in a refusal.
	var posted := board.offers().size()
	for h in int(cooldown) - 1:
		board.advance(1.0, true)
	assert_true(board.offers().size() <= posted,
			"the board posts nothing while the cooldown runs")
	sim.dispose()


# ------------------------------------------------------- the offline contract

## **The coarse contract: zero draws, zero aging, zero offers.** This is doc 08
## §2.3 rule 9 made structural — the board does not run while the player is away
## — and it is also what keeps the balance matrix, which runs the coarse step,
## unable to see this system at all.
func test_the_board_does_not_run_while_the_player_is_away() -> void:
	var sim := CitySim.boot_from_files(SEED)
	sim.progression.city_level = 6
	var board := sim.contracts
	assert_true(_run_until_offers(board, 1) > 0)
	var offer: Dictionary = board.offers()[0]
	assert_true(bool(sim.cmd_accept_contract(int(offer["id"]))["ok"]))
	var remaining := float(board.active()["remaining_h"])
	var stream_state := sim.rng.stream(ContractBoard.STREAM_NAME).state
	var offers_before := board.offers().size()

	for h in 500:
		board.advance(1.0, false)

	assert_almost_eq(float(board.active()["remaining_h"]), remaining, 1e-9,
			"500 game-hours away and the deadline has not moved an hour")
	assert_eq(board.offers().size(), offers_before,
			"nothing was posted and nothing was withdrawn")
	assert_eq(sim.rng.stream(ContractBoard.STREAM_NAME).state, stream_state,
			"and the contracts stream was not advanced by a single draw")

	# **And the PROGRESS half, which `advance` cannot enforce on its own.**
	# `observe` runs synchronously from `SimEventBus.emit`, which fires during a
	# catch-up as readily as during a session — so without the `online` flag a
	# player who accepted "answer 5 incidents" and closed the app would come back
	# to a finished commission and an untouched deadline. That is a reward for
	# being away, which is the one thing doc 08 §2.3 rule 9 forbids outright.
	var active_row := board.active()
	var rule := ContractBoard.rule_for(StringName(String(active_row["kind"])))
	var step := _step_payload(active_row)
	for i in 20:
		sim.bus.emit(StringName(String(rule["event"])), step)
	assert_eq(int(board.active()["progress"]), 0,
			"twenty of the very events this commission counts, raised while the "
					+ "board is offline, moved it not one step")
	assert_false(board.is_ready())

	# …and it starts counting again the moment the player is back.
	board.advance(1.0, true)
	sim.bus.emit(StringName(String(rule["event"])), step)
	assert_eq(int(board.active()["progress"]), 1,
			"one online event, one step — the flag gates the counter, not the verb")
	sim.dispose()


# ------------------------------------------------------------------ the save

## The whole board persists — a commission the player was three quarters through
## and lost to a phone call is exactly the kind of small theft that makes a save
## feel unsafe.
func test_a_save_taken_mid_commission_restores_it() -> void:
	var sim := CitySim.boot_from_files(SEED)
	sim.progression.city_level = 6
	var board := sim.contracts
	assert_true(_run_until_offers(board, 1) > 0)
	var offer: Dictionary = board.offers()[0]
	assert_true(bool(sim.cmd_accept_contract(int(offer["id"]))["ok"]))
	sim.bus.emit(StringName(String(ContractBoard.rule_for(
			StringName(String(offer["kind"])))["event"])),
			_step_payload(board.active()))
	var before := board.active()
	assert_true(int(before["progress"]) > 0,
			"the save is taken MID-commission, or it proves nothing")

	var body := sim.capture_state().duplicate(true)
	var revived := CitySim.boot_from_files(SEED)
	revived.restore_state(body)
	var after: Dictionary = revived.contracts.active()

	assert_eq(int(after["id"]), int(before["id"]), "same commission")
	assert_eq(int(after["progress"]), int(before["progress"]), "same progress")
	assert_eq(int(after["reward"]), int(before["reward"]), "same dollars")
	assert_almost_eq(float(after["remaining_h"]), float(before["remaining_h"]), 1e-6,
			"and the same hours left on it")
	assert_eq(revived.contracts.offers().size(), board.offers().size(),
			"the rest of the board came back too")
	sim.dispose()
	revived.dispose()


# ----------------------------------------------------------------- the guards

## C-07: `data/contracts.json` carries no dollar at any depth, and a price put
## back is a BOOT ERROR — the same guard `OpportunitySystem` puts on the street
## table and `IncidentCatalog` on `reward_base`.
func test_no_contract_price_survives_in_the_board_file() -> void:
	var data := StarterCityLoader.read_json(DATA_PATH)
	for key in ContractBoard.FORBIDDEN_KEYS:
		assert_false(_has_key_anywhere(data.get("templates", []), String(key)),
				"data/contracts.json carries `%s` at no depth" % String(key))

	var smuggled := data.duplicate(true)
	var templates: Array = smuggled["templates"]
	(templates[0] as Dictionary)["reward"] = 5000
	assert_false(ContractBoard.new(smuggled).errors.is_empty(),
			"a board file that carries a price back must fail the boot")

	# …and a tier the economy does not price is a boot error too, because a
	# commission worth $0 looks exactly like a balance decision.
	var unpriced := data.duplicate(true)
	((unpriced["templates"] as Array)[0] as Dictionary)["tier"] = "platinum"
	var board := ContractBoard.new(unpriced)
	board.bind_payouts(CostCurves.load_from_files())
	assert_false(board.errors.is_empty(), "an unpriced tier fails the boot")

	# The shipped pair boots clean.
	var live := ContractBoard.new(data)
	live.bind_payouts(CostCurves.load_from_files())
	assert_true(live.errors.is_empty(), str(live.errors))


## Every template asks for something the game already knows how to notice, and
## the board invents no vocabulary of its own beyond the one row Wave 18's
## restore made possible.
func test_every_commission_asks_for_a_verb_the_game_has() -> void:
	var data := StarterCityLoader.read_json(DATA_PATH)
	for row_variant: Variant in data["templates"]:
		var row: Dictionary = row_variant
		var kind := StringName(String(row["kind"]))
		assert_true(ContractBoard.knows_kind(kind),
				"template '%s' asks for '%s', which no evaluator knows"
						% [String(row["id"]), String(kind)])
	assert_eq(ContractBoard.EXTRA_EVENT_KINDS.size(), 1,
			("the board extends doc 09's vocabulary by exactly one row; anything "
					+ "more means an objective kind was invented here instead of in "
					+ "the curriculum that owns them"))


## **THE PLAYER'S NUMBER.** A `major` commission at the top of doc 09's ladder
## pays at least $15,000, and that is the whole reason this layer exists rather
## than a bigger street bounty.
func test_the_top_tier_pays_the_number_that_was_asked_for() -> void:
	var curves := CostCurves.load_from_files()
	var k := curves.contract_reward_city_level_k()
	var top := GoalSystem.top_level()
	var mult := 1.0 + k * float(top - 1)
	var floor_payout := curves.contract_payout_base("major") * mult
	var top_payout := (curves.contract_payout_base("major")
			+ curves.contract_payout_spread("major")) * mult
	assert_true(floor_payout >= 15000.0,
			("a major commission at level %d pays $%.0f at the FLOOR of its band; "
					+ "the player asked for 15,000 for one")
					% [top, floor_payout])
	assert_true(top_payout <= 25000.0,
			("…and $%.0f at the top of it, which must stay legible as one job "
					+ "rather than as a windfall") % top_payout)

	# The tier ladder is strictly increasing, or the board is offering the
	# player a choice that is not one.
	assert_true(curves.contract_payout_base("minor")
			< curves.contract_payout_base("standard"))
	assert_true(curves.contract_payout_base("standard")
			< curves.contract_payout_base("major"))


## The money lands on its own named ledger source, not folded into dispatch.
func test_the_money_lands_on_its_own_line() -> void:
	var sim := CitySim.boot_from_files(SEED)
	sim.progression.city_level = 6
	var board := sim.contracts
	assert_true(_run_until_offers(board, 1) > 0)
	assert_true(bool(sim.cmd_accept_contract(int(board.offers()[0]["id"]))["ok"]))
	_finish(sim, board)
	var reward := int(board.active()["reward"])
	assert_true(bool(sim.cmd_claim_contract()["ok"]))

	var services := sim.treasury.take_hour_city_services()
	assert_eq(int(services["contracts"]), reward,
			"the commission is its own sub-row of doc 03 §2.5's city-services line")
	assert_eq(int(services["dispatch"]), 0,
			"and it is NOT folded into dispatch, which gate 32(g) measures")
	sim.dispose()


# ------------------------------------------------------------------ helpers

## The payload one step of `kind` needs. Most kinds count one per event; the
## amount-bearing ones (`stamp_road_tiles` reads `tiles`) need the field, and a
## test that emitted a bare `{}` against one of those would assert nothing at
## all — it would be measuring a payload the counter correctly ignores.
static func _step_payload(row: Dictionary, amount: int = 1) -> Dictionary:
	var rule := ContractBoard.rule_for(StringName(String(row["kind"])))
	var out: Dictionary = {}
	if String(rule.get("match_field", "")) != "" and String(row["match_key"]) != "":
		out[String(rule["match_field"])] = String(row["match_key"])
	if String(rule.get("amount", "")) != "":
		out[String(rule["amount"])] = amount
	return out


## Drive the accepted contract to `ready` by emitting the event its kind counts.
func _finish(sim: CitySim, board: ContractBoard) -> void:
	var row := board.active()
	var rule := ContractBoard.rule_for(StringName(String(row["kind"])))
	var payload := _step_payload(row, int(row["target"]))
	for i in int(row["target"]):
		sim.bus.emit(StringName(String(rule["event"])), payload)
		if board.is_ready():
			return


func _has_key_anywhere(value: Variant, needle: String) -> bool:
	if value is Dictionary:
		for key in (value as Dictionary):
			if String(key) == needle:
				return true
			if _has_key_anywhere((value as Dictionary)[key], needle):
				return true
	elif value is Array:
		for entry in (value as Array):
			if _has_key_anywhere(entry, needle):
				return true
	return false
