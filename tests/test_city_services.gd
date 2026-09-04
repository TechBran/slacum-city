extends SimTest
## Doc 03 §7 tests 47–49 — the money pass's three contracts (report 98 RR-78 / RR-79).
##
## The balance GATES (31 and 32) hold the sizing. This file holds the plumbing,
## and the plumbing is where a double-booking hides: a payout that reaches the
## treasury twice looks exactly like a payout that reaches it once, until
## somebody adds the two numbers up.
##
## Three things it proves, in the order they can break:
##   47  ONE DOLLAR, ONE LINE — the cash moves at the resolve, the ledger names
##       it at the settlement, and the settlement does not bank it again.
##   48  THE RECEIPT BOOK SURVIVES A SAVE — a save taken between the resolve and
##       the settlement must not drop the line the statement is about to print.
##   49  THE GRANTS ARE PAID ONCE AND ONLY FORWARD.

const ECONOMY_PATH := "res://data/economy.json"
const BUILDING_ECONOMY_PATH := "res://data/building_economy.json"
const SEED := 1337


func _curves() -> CostCurves:
	return CostCurves.load_from_files(BUILDING_ECONOMY_PATH, ECONOMY_PATH)


# ================================================= 47 one dollar, one line

## RR-78 half of doc 03 §7 test 33: doc 06's data carries no dollar, and the
## boot refuses one that does.
func test_no_payout_price_survives_in_doc_06s_data() -> void:
	var data := StarterCityLoader.read_json("res://data/incidents.json")
	assert_false(_has_key_anywhere(data, "reward_base"),
			"data/incidents.json carries reward_base at no depth (RR-78)")
	assert_true(IncidentCatalog.FORBIDDEN_KEYS.has("reward_base"),
			"and the catalog refuses it at boot, not just in CI")
	var smuggled := data.duplicate(true)
	var types: Dictionary = smuggled["types"]
	(types[types.keys()[0]] as Dictionary)["reward_base"] = 350
	var catalog := IncidentCatalog.new(smuggled, {}, {})
	assert_false(catalog.is_valid(),
			"a file that carries the price back must fail the boot: %s"
					% str(catalog.errors))
	# And doc 03 carries the six values the rows used to.
	var curves := _curves()
	for pair: Array in [["crime", 350.0], ["structure_fire", 900.0],
			["transformer_failure", 600.0], ["water_main_break", 500.0],
			["traffic_accident", 300.0], ["storm_damage", 400.0]]:
		assert_almost_eq(curves.dispatch_payout_base(String(pair[0])),
				float(pair[1]), 1e-9, "doc 03 prices %s" % String(pair[0]))


## RR-85, the same contract one file further out: doc 06 §2.16's data carries no
## dollar either, the boot refuses one that comes back, and doc 03 carries the
## bands the rows used to.
##
## **This is the guard that would have caught the bug it was written after.**
## Until this wave `data/street.json` held the LIVE reward columns while
## `city_services.street_payout` held a dead placeholder set beside them — one
## feature, two price tables, and gate 32 was reading the one the game did not
## pay out of. A test that only checked doc 03's numbers were *present* would
## have passed on both days; this one checks that doc 06's are ABSENT, which is
## the half that can tell them apart.
func test_no_street_price_survives_in_doc_06s_data() -> void:
	var data := StarterCityLoader.read_json("res://data/street.json")
	for key in ["reward", "reward_city_level_k"]:
		assert_false(_has_key_anywhere(data, key),
				"data/street.json carries `%s` at no depth (RR-85)" % key)
		assert_true(OpportunitySystem.FORBIDDEN_KEYS.has(key),
				"and the spawner refuses `%s` at boot, not just in CI" % key)

	# A price put back is a BOOT ERROR, at any depth — the same shape
	# `IncidentCatalog` gives `reward_base`.
	var smuggled := data.duplicate(true)
	var kinds: Dictionary = smuggled["kinds"]
	(kinds["petty_crime"] as Dictionary)["reward"] = {"base": 260, "spread": 90}
	var refused := OpportunitySystem.new(smuggled)
	assert_false(refused.errors.is_empty(),
			"a street table that carries the price back must fail the boot")

	# The spread version of the same guard: the scalar in the spawn block.
	var smuggled_k := data.duplicate(true)
	(smuggled_k["spawn"] as Dictionary)["reward_city_level_k"] = 0.20
	assert_false(OpportunitySystem.new(smuggled_k).errors.is_empty(),
			"and so must the level scalar, which is a term in a dollar formula")

	# The shipped file itself is clean, and every kind it names is PRICED. An
	# unpriced kind is a boot error too, because a crook worth $0 is a bug that
	# looks exactly like a balance decision.
	var curves := _curves()
	var live := OpportunitySystem.new(data)
	live.bind_payouts(curves)
	assert_true(live.errors.is_empty(),
			"the shipped pair boots clean: %s" % str(live.errors))
	# **RE-PRICED, WAVE 19** (doc 92 §57.1, report 98 RR-169): the bands are the
	# migrated ones times 5/3 and `spawn.target_interval_h` is 1.50 -> 2.85 in the
	# same commit, so a single collection is worth 1.70x and the LAYER's income
	# per game-hour is unmoved ($181.65 -> $184.30, measured). These literals are
	# the shipped table and they are here for the same reason they were here
	# before: this file is the guard that doc 03 is the only place they live, and
	# a guard that read the value out of the file it is guarding would guard
	# nothing.
	for row: Array in [["petty_crime", 430.0, 155.0], ["loose_animal", 250.0, 100.0],
			["lost_valuables", 700.0, 300.0]]:
		var kind := String(row[0])
		assert_almost_eq(curves.street_payout_base(kind), float(row[1]), 1e-9,
				"doc 03 prices %s's floor" % kind)
		assert_almost_eq(curves.street_payout_spread(kind), float(row[2]), 1e-9,
				"and %s's spread" % kind)
	assert_almost_eq(curves.street_reward_city_level_k(), 0.25, 1e-9,
			"and the level scalar that used to sit in the spawn block")

	# A kind the price table does not know is refused rather than paid zero.
	var orphan := data.duplicate(true)
	var starved := OpportunitySystem.new(orphan)
	starved.bind_payouts(CostCurves.new({}, {"city_services": {"street_payout": {}}}))
	assert_false(starved.errors.is_empty(),
			"a kind nobody prices must fail the boot, not spawn for nothing")


## The cash moves NOW — the player taps and the number changes — and the hour's
## settlement then names it on `revenue.city_services` **without banking it a
## second time**. The check that separates "reported" from "paid twice" is the
## balance: it must move by the payout exactly once over the whole game-hour.
func test_a_payout_is_paid_once_and_reported_once() -> void:
	var sim := CitySim.boot_from_files(SEED)
	var before := sim.treasury.balance
	sim.incident_world.credit_city_service(500, "dispatch", "test")
	assert_eq(sim.treasury.balance, before + 500,
			"the money lands the moment it is earned, not at the hour boundary")
	assert_eq(int(sim.treasury.hour_city_services["dispatch"]), 500,
			"and the receipt book has it waiting for the settlement")

	var drained := sim.treasury.take_hour_city_services()
	assert_eq(int(drained["dispatch"]), 500)
	assert_eq(int(sim.treasury.hour_city_services["dispatch"]), 0,
			"a drained book is empty — a second settlement must not re-report it")

	# The settlement itself: `gross` and `net` include the line, and the treasury
	# is handed `revenue - city_services` because that cash already moved.
	var treasury := Treasury.new(_curves().economy_data(), {}, 25000)
	var economy := EconomySystem.new(_curves(), treasury)
	var snapshot := economy.settle_hour({
		"hour": 0, "buildings": [], "stations": [], "vehicles": [],
		"city_services": {"dispatch": 500, "street": 120},
		"founding_assistance": 0.0,
	})
	var revenue: Dictionary = snapshot["revenue"]
	assert_almost_eq(float(revenue["city_services"]), 620.0, 1e-9,
			"one line, both sources")
	assert_eq((revenue["city_services_by_source"] as Dictionary),
			{"dispatch": 500, "street": 120},
			"with the sub-grain nested, as tax_by_class is")
	assert_almost_eq(float(revenue["gross"]), 620.0, 1e-9,
			"it is operating revenue and the income statement says so")
	# An empty city has no expenses, so the ONLY thing that could reach the
	# balance here is the line itself — and it must not, because its cash moved
	# before this settlement ran.
	assert_eq(treasury.balance, 25000,
			"settling a reported-and-already-paid line must not bank it twice")


## RR-79's other half of the same settlement: `assistance` IS settled in cash,
## because unlike a payout it has not been paid yet.
func test_the_founding_grant_is_settled_in_cash() -> void:
	var treasury := Treasury.new(_curves().economy_data(), {}, 25000)
	var economy := EconomySystem.new(_curves(), treasury)
	economy.settle_hour({
		"hour": 0, "buildings": [], "stations": [], "vehicles": [],
		"city_services": {}, "founding_assistance": 172.0,
	})
	assert_eq(treasury.balance, 25000 + 172,
			"a grant nobody has paid yet is settled like any other revenue")


# ============================================ 48 the receipt book and a save

## A save taken between a resolve and the hour's settlement must not lose the
## line the statement is about to print — and a save written before the money
## pass must restore to 0 rather than to garbage.
func test_the_receipt_book_survives_a_save() -> void:
	var treasury := Treasury.new(_curves().economy_data(), {}, 25000)
	treasury.credit_city_service(340, "dispatch", "incident_resolved")
	treasury.credit_city_service(180, "street", "petty_crime")
	var restored := Treasury.new(_curves().economy_data(), {}, 0)
	restored.deserialize(treasury.serialize())
	assert_eq(restored.hour_city_services, treasury.hour_city_services,
			"the pending line rides the save")
	assert_eq(restored.balance, treasury.balance)

	# An older save has no such key at all. 0 is the right answer there: those
	# cities booked the payout straight to the balance and had nothing pending.
	var old_save := treasury.serialize()
	old_save.erase("hour_city_services")
	var legacy := Treasury.new(_curves().economy_data(), {}, 0)
	legacy.deserialize(old_save)
	# **The KEY SET is the assertion, not a literal pair.** `hour_city_services`
	# grew a `contracts` source in Wave 19 (report 98 §60 RR-170) and this line
	# read the pair as a constant, so the file that guards doc 03's ledger was
	# the file a new ledger source broke. What must hold is the shape: every
	# source the live book knows, present and zeroed — which is what "an empty
	# book, not a missing one" always meant.
	var empty_book: Dictionary = {}
	for source: String in treasury.hour_city_services:
		empty_book[source] = 0
	assert_eq(legacy.hour_city_services, empty_book,
			"a pre-RR-78 save restores an empty book, not a missing one")
	assert_true(empty_book.has("dispatch") and empty_book.has("street"),
			"and the two sources RR-78 created are still in it")

	# An unknown source is tallied rather than dropped: losing the tally would
	# make the printed line disagree with the balance, which is the one failure
	# this whole design exists to prevent.
	var odd := Treasury.new(_curves().economy_data(), {}, 25000)
	odd.credit_city_service(90, "not_a_source", "")
	assert_eq(odd.balance, 25000 + 90)
	assert_eq(int(odd.hour_city_services["dispatch"]) + int(odd.hour_city_services["street"]),
			90, "every credited dollar is tallied somewhere")


# ================================================ 49 the grants, once, forward

func test_the_founding_assistance_tapers_on_a_clock() -> void:
	var curves := _curves()
	assert_almost_eq(curves.founding_assistance_per_hour(0), 172.0, 1e-9,
			"the founding day pays the whole civic bill")
	assert_almost_eq(curves.founding_assistance_per_hour(3),
			172.0 * (1.0 - 3.0 / 7.0), 1e-6)
	assert_almost_eq(curves.founding_assistance_per_hour(7), 0.0, 1e-9,
			"and it is exactly zero the day the clock runs out")
	assert_almost_eq(curves.founding_assistance_per_hour(99), 0.0, 1e-9,
			"and stays there")
	# It is doc 03 §2.12's own two civic lines and not a fit.
	var pacing: Dictionary = curves.economy_data()["pacing_guardrails"]
	assert_almost_eq(float(curves.grants()["FOUNDING_ASSISTANCE_PER_HOUR"]),
			float(pacing["STARTER_DEPARTMENTS_PER_HOUR"]) + 76.0, 1e-9,
			"172 = departments 96 + fleet 76, the founding ledger's own numbers")


func test_a_level_up_grant_is_paid_once_per_rung() -> void:
	var curves := _curves()
	assert_eq(curves.level_up_grant(0), 0, "the founding level celebrates nothing")
	# **RE-SCALED AGAIN in Wave 24 (doc 92 §63.1), and this time the player gave
	# two anchors instead of a band**: *"Start with one million dollars, and then
	# at level seven we give them seven million."* Those two anchors are the
	# whole curve — a straight run of step $1,000,000 is the only shape that hits
	# both with one constant — so the rule is `grant(k) = k × $1,000,000` and
	# THAT is what is asserted, not seven literals. Seven literals are seven
	# chances for the next re-scale to land on six of them.
	assert_eq(curves.level_up_grant(1), 1_000_000,
			"the player's first anchor: one million dollars at rung 1")
	assert_eq(curves.level_up_grant(7), 7_000_000,
			"and the second: seven million at the capstone")
	for level in range(1, 8):
		assert_eq(curves.level_up_grant(level), level * 1_000_000,
				("rung %d pays %d; the ladder the player named is k million "
						+ "dollars at rung k") % [level, curves.level_up_grant(level)])
	# **The step is CONSTANT and the ratio therefore FALLS** — 2.00 / 1.50 / 1.33
	# / 1.25 / 1.20 / 1.17 against doc 09 §2.11's own rung ratio of 2.25 — which
	# is the anti-farm half of §63.1: from rung 2 up the grant grows more slowly
	# than the city it lands on, so its share of that city falls by construction
	# and keeps falling faster. A ladder that ever grew at 2.25 or above would be
	# paying a player to climb, and this is the assertion that would catch it.
	for level in range(2, 8):
		var ratio := float(curves.level_up_grant(level)) \
				/ float(curves.level_up_grant(level - 1))
		assert_true(ratio < 2.25,
				("rung %d pays %.2f× rung %d; doc 09 §2.11's city grows 2.25× a "
						+ "rung, and a grant that grew faster would be a subsidy "
						+ "that compounds") % [level, ratio, level - 1])
	assert_eq(curves.level_up_grant(8), 0,
			"a level above the published ladder pays nothing rather than "
			+ "extrapolating itself")
	# **The curve rises and never doubles back**, which is the shape assertion
	# the old six-cell table never had and which a re-scale most needs: a rung
	# that paid less than the one below it would be the game asking the player
	# to stop climbing.
	var previous_grant := 0
	for level in range(1, GoalSystem.top_level() + 1):
		var grant := curves.level_up_grant(level)
		assert_true(grant > previous_grant,
				"rung %d pays more than rung %d" % [level, level - 1])
		previous_grant = grant
	# **Every rung of the ladder has a grant row**, asserted against
	# `GoalSystem.top_level()` rather than against a number, because this
	# project's signature defect is a level the ladder can reach that no data row
	# describes. A seventh curriculum rung with a six-cell grant table would have
	# celebrated the hardest level in the game by paying nothing.
	assert_eq(GoalSystem.top_level(),
			(curves.grants()["LEVEL_UP_GRANT_BY_CITY_LEVEL"] as Array).size() - 1,
			"the grant table has exactly one row per curriculum rung, plus the "
			+ "founding level's zero")
	assert_eq(GoalSystem.top_level(), ProgressionSystem.city_level_pop().size() - 1,
			"and the population ladder reaches the same top rung — "
			+ "`grant_level` clamps to it, so a curriculum rung above it could "
			+ "be earned in `GoalSystem` and never paid")

	# **The runtime half, on the CURRICULUM's transition** (Wave 22, ruling
	# 93 §AU6). The grant used to be paid from `publish_progression` on
	# `city_level_changed`; it is now paid when doc 09 §2.14's objectives for a
	# rung are met, because a grant is payment for a lesson and the population
	# backstop teaches none.
	var sim := CitySim.boot_from_files(SEED)
	var before := sim.treasury.balance
	var paid: Array[int] = []
	sim.bus.drain()
	sim._pay_level_up_grant(1)
	sim._pay_level_up_grant(2)
	for event_variant in sim.bus.drain():
		var event: Dictionary = event_variant
		if String(event.get("type", "")) == "level_up_grant_paid":
			paid.append(int(event["amount"]))
	assert_eq(paid, [1_000_000, 2_000_000] as Array[int], "both rungs, in order")
	assert_eq(sim.treasury.balance, before + 3_000_000)
	# **And the ledger recorded it** (Wave 24). This is the record the back-pay
	# settles against, and a payment that did not write to it would be a rung
	# the next load pays for a second time.
	assert_eq(sim.treasury.grant_paid(1), 1_000_000)
	assert_eq(sim.treasury.grant_paid(2), 2_000_000)
	# A second call for a rung already paid IN FULL pays nothing, and it is the
	# ledger and not the event queue that says so.
	sim._pay_level_up_grant(1)
	assert_eq(sim.treasury.balance, before + 3_000_000,
			"a rung already paid in full is paid nothing a second time")

	# **The population route pays NOTHING**, which is the whole of the Wave-22
	# change and the reason doc 92's balance matrix does not move: every scripted
	# agent in it climbs this ladder and none of them can read a goals sheet.
	var after := sim.treasury.balance
	sim.publish_progression([{"type": "city_level_changed", "from": 0, "to": 3}])
	assert_eq(sim.treasury.balance, after,
			"a city level crossed on the population ladder pays no celebration "
			+ "grant — the level is a permission, the grant is a lesson's fee")
	# …and it still opens an ERA, because an era IS a city level (doc 93 §AP4)
	# and a permission may not depend on how the level was reached.
	assert_eq(sim.treasury.relief_era_level, 3,
			"the era still opens on the composed level")


# ============== 50 the dispatcher's premium grows with the city (Wave 19)

## **RR-169 — a flat reward is a shrinking reward.**
##
## `dispatch_payout_base` never moved with the city: a resolved crime paid $595
## on game-day one and $595 on game-day three hundred, while the city's own net
## per real-minute went 537.7 → 2,755.4 (`MODEL_NET_PER_HOUR_BY_CITY_LEVEL`).
## The player found it from the outside: *"the crimes we stop are only a few
## hundred dollars."*
##
## Four claims, and the last two are the ones that keep the change out of the
## balance matrix and out of gate 31:
##
##   1. the curve is the authored one and it is exactly 1.50 at level 1, so a
##      founding city pays the number every anchor was measured with;
##   2. it is monotone and reaches 6.00× by the top of doc 09's ladder;
##   3. **auto-dispatch does not move at any level** — the premium is the only
##      thing that scales, so every control agent in the balance matrix earns
##      what it earned before this wave;
##   4. **an unpriced target does not move either** — `MORAL_HAZARD_UNPRICED_CEILING`
##      is derived from an avenue rebuild and an avenue does not get dearer
##      because the city levelled up, so the three types that ceiling holds keep
##      the flat premium gate 31(c)'s published table was fitted against.
func test_the_dispatchers_premium_grows_with_the_city_and_nothing_else_does() -> void:
	var curves := _curves()
	var services: Dictionary = curves.city_services()
	var base := float(services["MANUAL_DISPATCH_MULT"])
	var k := float(services["MANUAL_DISPATCH_LEVEL_K"])
	assert_almost_eq(curves.manual_dispatch_mult_at_level(1), base, 1e-9,
			"a founding city pays exactly the premium the anchors were measured with")
	assert_almost_eq(curves.manual_dispatch_mult_at_level(0), base, 1e-9,
			"and a level the ladder cannot reach is floored, never negative")
	var previous := 0.0
	for level in range(1, GoalSystem.top_level() + 1):
		var mult := curves.manual_dispatch_mult_at_level(level)
		assert_almost_eq(mult, base + k * float(level - 1), 1e-9,
				"the curve at level %d is the authored one" % level)
		assert_true(mult > previous, "and it is monotone at level %d" % level)
		previous = mult
	# The top of the ladder is READ, not written down: it was 6 and the assertion
	# said `6.00`, and Wave 22's seventh rung moved the answer to 6.90 without
	# moving one authored number (`base` 1.50 + `k` 0.90 × 6). A gate that names
	# a rung by number goes stale on the next wave that adds one.
	assert_almost_eq(curves.manual_dispatch_mult_at_level(GoalSystem.top_level()),
			base + k * float(GoalSystem.top_level() - 1), 1e-9,
			"and reaches the authored curve's own value at the top of doc 09's "
			+ "ladder — 6.90x at the seven-rung ladder Wave 22 published")

	# (3) and (4): the runtime, not the table. A booted city, one incident type
	# with a PRICED target and one with an unpriced one, at level 1 and at the top
	# rung of the ladder.
	var sim := CitySim.boot_from_files(SEED)
	var target := {"kind": "building", "id": String(sim.roster_ids()[0])}
	var road := {"kind": "road_edge", "id": "R-1"}
	var auto_low := sim.incident_world.dispatch_payout("crime", 1.0, false, target, 0.0)
	var road_low := sim.incident_world.dispatch_payout(
			"traffic_accident", 1.0, true, road, 0.0)
	sim.progression.city_level = GoalSystem.top_level()
	var auto_high := sim.incident_world.dispatch_payout("crime", 1.0, false, target, 0.0)
	var road_high := sim.incident_world.dispatch_payout(
			"traffic_accident", 1.0, true, road, 0.0)
	assert_eq(auto_high, auto_low,
			"auto-dispatch pays the same at level 1 and at the top of the ladder: the "
					+ "matrix's control agents never earn a premium and so never move")
	assert_eq(road_high, road_low,
			"and an unpriced target keeps the flat premium gate 31(c) is fitted to")
	sim.dispose()


# ------------------------------------------------------------------ helpers

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
