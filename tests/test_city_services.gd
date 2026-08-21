extends SimTest
## Doc 03 §7 tests 47–49 — the money pass's three contracts (report 98 RR-77 / RR-78).
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

## RR-77 half of doc 03 §7 test 33: doc 06's data carries no dollar, and the
## boot refuses one that does.
func test_no_payout_price_survives_in_doc_06s_data() -> void:
	var data := StarterCityLoader.read_json("res://data/incidents.json")
	assert_false(_has_key_anywhere(data, "reward_base"),
			"data/incidents.json carries reward_base at no depth (RR-77)")
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


## RR-78's other half of the same settlement: `assistance` IS settled in cash,
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
	assert_eq(legacy.hour_city_services, {"dispatch": 0, "street": 0},
			"a pre-RR-77 save restores an empty book, not a missing one")

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
	assert_eq(curves.level_up_grant(1), 2500)
	assert_eq(curves.level_up_grant(6), 83000)
	assert_eq(curves.level_up_grant(7), 0,
			"a level above the published ladder pays nothing rather than "
			+ "extrapolating itself")

	var sim := CitySim.boot_from_files(SEED)
	var before := sim.treasury.balance
	var paid: Array[int] = []
	sim.bus.drain()
	# One move that crosses TWO rungs: both are paid, because doc 93 §G1's
	# `max()` can jump a level and a rung that was earned must not be skipped.
	sim.publish_progression([{"type": "city_level_changed", "from": 0, "to": 2}])
	for event_variant in sim.bus.drain():
		var event: Dictionary = event_variant
		if String(event.get("type", "")) == "level_up_grant_paid":
			paid.append(int(event["amount"]))
	assert_eq(paid, [2500, 7000] as Array[int], "both rungs, in order")
	assert_eq(sim.treasury.balance, before + 9500)

	# And a rung is never sold twice — `city_level` is monotone, so a repeat
	# event for ground already covered pays nothing.
	var after := sim.treasury.balance
	sim.publish_progression([{"type": "city_level_changed", "from": 2, "to": 2}])
	assert_eq(sim.treasury.balance, after, "a rung already crossed pays nothing")


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
