extends SimTest
## Wave 24, doc 03 §2.5a / ruling 93 §AW3 — **the celebration grant's LEDGER and
## the back-pay that rides on it**, measured in doc 92 §63.4–§63.5 and shipped as
## report 98 §66 RR-199.
##
## The player's instruction, verbatim 2026-09-04: *"if a player has already
## passed level one and was supposed to get a million dollars, you should be
## able to collect it for all of them AUTOMATICALLY — you should just check if
## you have received it, and if you haven't, then you get it. That way we can
## keep one city going for a while."*
##
## Five claims, and every one of them is a way the feature could pay a player
## twice or short-change them once:
##
##  1. a city is paid the DIFFERENCE, never the whole rung and never nothing;
##  2. it is paid ONCE — a second load pays $0, forever;
##  3. it is never paid for a level it has not EARNED;
##  4. a legacy save is seeded with what its own binary paid, keyed on the save
##     section version, so the difference is a real difference;
##  5. the money arrives with a RECEIPT the player can read.

const SEED := 1337


func _curves() -> CostCurves:
	return CostCurves.load_from_files()


## The ledger itself: dollars per level, only ever upward, and a level it has
## never heard of has been paid nothing.
func test_the_grant_ledger_only_ever_adds() -> void:
	var treasury := Treasury.new()
	assert_eq(treasury.grant_paid(0), 0)
	assert_eq(treasury.grant_paid(3), 0, "an unheard-of level has been paid nothing")
	assert_eq(treasury.grant_paid(-1), 0, "and a nonsense one does not crash")
	treasury.note_grant_paid(3, 45_000)
	assert_eq(treasury.grant_paid(3), 45_000)
	assert_eq(treasury.grant_paid(1), 0, "the gap it grew through is zero, not blank")
	treasury.note_grant_paid(3, 955_000)
	assert_eq(treasury.grant_paid(3), 1_000_000, "a second receipt ADDS to the first")
	treasury.note_grant_paid(3, -500)
	treasury.note_grant_paid(3, 0)
	assert_eq(treasury.grant_paid(3), 1_000_000,
			"a receipt book that could go DOWN would be a way to be paid twice")


## The seed table: what a superseded build paid, chosen by the section version
## the body came from. Row `"0"` is the project's original ladder and row `"9"`
## is Wave 22's; the rule is *the highest key at or below the version*.
func test_the_superseded_table_is_chosen_by_save_version() -> void:
	var curves := _curves()
	# A v8 body — which is what the 2026-09-03 player save is — was paid the
	# original ladder, on the composed city level.
	assert_eq(curves.superseded_level_up_grant(1, 8), 2500)
	assert_eq(curves.superseded_level_up_grant(5, 8), 37000)
	assert_eq(curves.superseded_level_up_grant(1, 0), 2500, "and so was a v0 body")
	# A v9 body was paid Wave 22's, which is also the element-wise maximum of
	# every table that could have paid a v9 city — Wave 22 changed no shape, so
	# a v9 body may have been written either side of its merge, and crediting
	# the LARGER is what makes double payment impossible rather than unlikely.
	assert_eq(curves.superseded_level_up_grant(1, 9), 45000)
	assert_eq(curves.superseded_level_up_grant(7, 9), 5000000)
	assert_eq(curves.superseded_level_up_grant(10, 9), 0,
			"a level above the superseded ladder was paid nothing, not extrapolated")
	# A version above every published row still selects the highest row rather
	# than falling through to zero: a v11 save that somehow had no ledger was
	# paid at least what v9 paid.
	assert_eq(curves.superseded_level_up_grant(1, 25), 45000)


## Claim 3, and it is the one that keeps the whole feature honest: the walk stops
## at the CURRICULUM level. A city that climbed the population backstop to level
## 5 without opening the goals sheet is owed nothing, for exactly the reason
## ruling 93 §AU6 moved the live payment site off the composed level.
func test_arrears_are_never_paid_for_a_level_the_city_did_not_earn() -> void:
	var sim := CitySim.boot_from_files(SEED)
	sim.progression.city_level = 5
	sim.goals.earned_level = 0
	var before := sim.treasury.balance
	sim.bus.drain()
	sim._settle_grant_arrears()
	assert_eq(sim.treasury.balance, before,
			"a level reached on the population ladder is a permission, not a lesson")
	var receipts := 0
	for entry: Variant in sim.bus.drain():
		if String((entry as Dictionary).get("type", "")) == "level_up_grant_arrears_paid":
			receipts += 1
	assert_eq(receipts, 0, "and nothing is announced, because nothing happened")


## Claims 1, 2 and 5 on a live city, with no save file in the way: a ledger that
## records the OLD table, a settle that pays the difference, a second settle that
## pays nothing, and a receipt naming the rungs.
func test_arrears_pay_the_difference_once_and_print_a_receipt() -> void:
	var sim := CitySim.boot_from_files(SEED)
	var curves := sim.econ_curves
	sim.goals.earned_level = 3
	# What a Wave-22 city had been paid for rungs 1–3.
	var seeded := 0
	for level in range(1, 4):
		var paid := curves.superseded_level_up_grant(level, 9)
		sim.treasury.note_grant_paid(level, paid)
		seeded += paid
	assert_eq(seeded, 45000 + 65000 + 95000, "the Wave-22 rungs 1–3")

	var before := sim.treasury.balance
	sim.bus.drain()
	sim._settle_grant_arrears()
	var owed := 0
	for level in range(1, 4):
		owed += curves.level_up_grant(level)
	owed -= seeded
	assert_eq(sim.treasury.balance, before + owed,
			"the city is paid the DIFFERENCE: %d of a %d table" % [owed, owed + seeded])
	assert_eq(owed, 6_000_000 - 205_000, "$5,795,000 on the shipped table")
	# The ledger now records the whole rung, which is what makes the next line
	# true and what makes it true forever.
	for level in range(1, 4):
		assert_eq(sim.treasury.grant_paid(level), curves.level_up_grant(level),
				"rung %d is now paid in full" % level)

	var receipt: Dictionary = {}
	for entry: Variant in sim.bus.drain():
		var event: Dictionary = entry
		if String(event.get("type", "")) == "level_up_grant_arrears_paid":
			receipt = event
	assert_false(receipt.is_empty(), "the player is told what the money was for")
	assert_eq(receipt.get("levels"), [1, 2, 3] as Array[int], "and which rungs it covers")
	assert_eq(int(receipt.get("amount", 0)), owed)
	assert_eq(int(receipt.get("balance", 0)), sim.treasury.balance)

	# **Claim 2.** Idempotent by construction: the second settle recomputes the
	# same differences against a ledger that now records them.
	var after := sim.treasury.balance
	sim._settle_grant_arrears()
	sim._settle_grant_arrears()
	assert_eq(sim.treasury.balance, after, "a second load pays nothing, and a third")
	var second_receipts := 0
	for entry: Variant in sim.bus.drain():
		if String((entry as Dictionary).get("type", "")) == "level_up_grant_arrears_paid":
			second_receipts += 1
	assert_eq(second_receipts, 0, "and announces nothing")


## The live payment site and the arrears site share the ledger, so a rung that
## has just been earned and paid in play is not paid again by the next load —
## which is the interaction the two-site design could most easily get wrong.
func test_a_rung_paid_in_play_is_not_re_paid_by_a_load() -> void:
	var sim := CitySim.boot_from_files(SEED)
	sim.goals.earned_level = 2
	sim._pay_level_up_grant(1)
	sim._pay_level_up_grant(2)
	var after_play := sim.treasury.balance
	sim.bus.drain()
	sim._settle_grant_arrears()
	assert_eq(sim.treasury.balance, after_play,
			"the arrears walk finds both rungs settled and pays nothing")


## The merge verifier's farm vector F — the one of eight that paid: delete
## `grant_paid_by_level` from a native body and the walk re-paid $27,839,000.
## A native body with levels and no ledger is not a thing a v11 binary writes,
## so the walk now seeds it as PAID and pays nothing.
func test_a_native_body_with_its_ledger_stripped_is_not_paid_again() -> void:
	var sim := CitySim.boot_from_files(SEED)
	sim.goals.earned_level = 2
	sim._pay_level_up_grant(1)
	sim._pay_level_up_grant(2)
	var after_play := sim.treasury.balance
	sim.treasury.grant_paid_by_level = [] as Array[int]
	sim.treasury.grant_ledger_migrate_from = -1
	sim.bus.drain()
	sim._settle_grant_arrears()
	assert_eq(sim.treasury.balance, after_play, "a stripped ledger buys nothing")
	assert_eq(sim.treasury.grant_paid(2), sim.econ_curves.level_up_grant(2),
			"…and the ledger is re-seeded as paid, so the next load is a no-op too")
	assert_true(sim.bus.drain().is_empty(), "no receipt for money that did not move")


## Claim 4, end to end through the real migrator and the real save round trip:
## a body written at section version 8 is stamped, seeded from the ORIGINAL
## ladder, and paid the difference — and the body it writes back carries a real
## ledger, so the load after that pays nothing.
func test_a_v8_body_is_seeded_from_its_own_binarys_table() -> void:
	# `_v10_to_v11` is the rung that stamps. A body with a treasury block and no
	# ledger gets the version it came from; one that already has a ledger is
	# left exactly as it is.
	var stamped := CitySim._v10_to_v11({"treasury": {"treasury": 100}}, 8)
	assert_eq(int((stamped["treasury"] as Dictionary)["grant_ledger_bootstrap"]), 8,
			"the marker carries the VERSION, because what a city was paid "
			+ "depends on which binary paid it")
	var already := CitySim._v10_to_v11(
			{"treasury": {"grant_paid_by_level": [0, 1_000_000]}}, 9)
	assert_false((already["treasury"] as Dictionary).has("grant_ledger_bootstrap"),
			"a body that already has a ledger is not re-seeded")
	var fragment := CitySim._v10_to_v11({}, 8)
	assert_false(fragment.has("treasury"),
			"and a body with no treasury section is a fragment, not a city")

	# The whole ladder, from 8, on a real city body.
	var sim := CitySim.boot_from_files(SEED)
	sim.goals.earned_level = 5
	sim.progression.city_level = 5
	var body: Dictionary = sim.capture_state()
	(body["treasury"] as Dictionary).erase("grant_paid_by_level")
	body["section_version"] = 8
	var migrated := sim.migrate_save_section(body, 8)
	assert_eq(int((migrated["treasury"] as Dictionary)["grant_ledger_bootstrap"]), 8)

	var loaded := CitySim.boot_from_files(SEED)
	loaded.bus.drain()
	loaded.restore_state(migrated)
	# The original ladder's rungs 1–5 are $78,000; the shipped table's are
	# $15,000,000; the difference is what a returning city collects.
	assert_eq(loaded.treasury.grant_paid(1), 1_000_000)
	assert_eq(loaded.treasury.grant_paid(5), 5_000_000)
	var receipt: Dictionary = {}
	for entry: Variant in loaded.bus.drain():
		var event: Dictionary = entry
		if String(event.get("type", "")) == "level_up_grant_arrears_paid":
			receipt = event
	assert_false(receipt.is_empty(), "a migrated city is told what it collected")
	assert_eq(int(receipt.get("amount", 0)), 15_000_000 - 78_000,
			"$14,922,000: the shipped rungs 1–5 less the original ladder's 1–5")

	# And the body it writes back carries the ledger, so the NEXT load is a
	# no-op — which is the property that makes this safe to run on every load
	# rather than once behind a flag.
	var written: Dictionary = loaded.capture_state()
	assert_true((written["treasury"] as Dictionary).has("grant_paid_by_level"))
	var again := CitySim.boot_from_files(SEED)
	again.bus.drain()
	again.restore_state(written)
	assert_eq(again.treasury.balance, loaded.treasury.balance,
			"the second load pays $0 — idempotent across reloads")
	for entry: Variant in again.bus.drain():
		assert_true(String((entry as Dictionary).get("type", ""))
				!= "level_up_grant_arrears_paid",
				"and says nothing, because nothing happened")


## A v8 city that climbed the POPULATION ladder past its curriculum is the case
## the ledger's dollars-per-level shape exists for: the old rule paid it for
## every composed rung, so the seed has to record those rungs — but the new rule
## may not back-pay them, and must credit them the day the curriculum earns one.
func test_a_legacy_population_rung_is_recorded_but_not_back_paid() -> void:
	var sim := CitySim.boot_from_files(SEED)
	sim.goals.earned_level = 2
	sim.progression.city_level = 4
	var body: Dictionary = sim.capture_state()
	(body["treasury"] as Dictionary).erase("grant_paid_by_level")
	var migrated := sim.migrate_save_section(body, 8)

	var loaded := CitySim.boot_from_files(SEED)
	var before := loaded.treasury.balance
	loaded.restore_state(migrated)
	# Seeded to the COMPOSED level 4 — that is what the old binary paid.
	assert_eq(loaded.treasury.grant_paid(4), 22500,
			"rung 4 was paid by the population route and the ledger records it")
	# …but only rungs 1–2 are back-paid, because only those were EARNED.
	assert_eq(loaded.treasury.grant_paid(3), 9000,
			"rung 3 keeps its legacy record and gains nothing")
	var owed := (1_000_000 - 2500) + (2_000_000 - 7000)
	assert_eq(loaded.treasury.balance, before + owed,
			"only the earned rungs are settled: $%d" % owed)
	# And the day the curriculum finally earns rung 4, the legacy $22,500 is
	# credited against it rather than forgotten.
	loaded._pay_level_up_grant(4)
	assert_eq(loaded.treasury.grant_paid(4), 4_000_000)
	assert_eq(loaded.treasury.balance, before + owed + (4_000_000 - 22500),
			"the rung pays its difference, not its whole face value")


## A city founded on THIS build has no arrears, and the boot path must not
## invent any. The guard matters because `_settle_grant_arrears` runs on every
## restore and a fresh city is one `restore_state` away from being a loaded one.
func test_a_fresh_city_is_owed_nothing() -> void:
	var sim := CitySim.boot_from_files(SEED)
	var before := sim.treasury.balance
	sim.bus.drain()
	sim._settle_grant_arrears()
	assert_eq(sim.treasury.balance, before)
	assert_eq(sim.treasury.grant_paid_by_level, [] as Array[int],
			"and its ledger is empty rather than zero-filled")


## Back-pay is not a promotion: it settles rungs the city climbed in the past,
## and the eras those rungs opened were opened then. Doc 03 §2.10 layer 5's
## relief allowance must not refresh because a debt was paid.
func test_back_pay_opens_no_relief_era() -> void:
	var sim := CitySim.boot_from_files(SEED)
	sim.goals.earned_level = 5
	sim.treasury.relief_era_level = 1
	sim.treasury.relief_grants_used = 3
	sim._settle_grant_arrears()
	assert_eq(sim.treasury.relief_era_level, 1, "the era is where the city left it")
	assert_eq(sim.treasury.relief_grants_used, 3,
			"and the allowance is not refilled by an arrears payment")
