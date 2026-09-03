extends SimTest
## `CitySim.cmd_salvage_building` — a ruin is worth something (Wave 19; doc 02
## §2.12's `destroyed → (removed)` row, doc 03 §2.5's `SALVAGE_FRACTION`,
## doc 12 §2.9 D-89, doc 93 §AQ2, report 98 RR-171).
##
## **The defect these tests close is the other half of `A91-D-99`.** Wave 18 gave
## doc 02 §2.12's `destroyed → planned` transition a caller after seventeen waves
## without one; the row under it, `destroyed → (removed)`, still had none. The
## queue kind was there (`ConstructionQueue.KINDS` carries `clear_rubble`), the
## queue panel rendered it, the notification scheduler exempted it — everything
## except a verb. So a ruin the player did not want to pay to restore could not
## be got rid of at all: `cmd_demolish_building` answers `E_STATE` on `destroyed`
## by construction, and that refusal is the first line of its own function.
##
## And it is the shape of the 2026-09-03 report: *"there's negative money … ALL
## of my buildings are destroyed right now."* Every priced verb in the game asks
## a player in that state for money they do not have. This one pays them.

const SEED := 1337


## The whole verb, end to end: a ruin, a quote, a tap, money, an empty lot.
func test_a_ruin_pays_and_the_lot_comes_back() -> void:
	var sim := CitySim.boot_from_files(SEED)
	var sim_id := _destroy_one(sim)
	assert_false(sim_id.is_empty(), "the fixture city has something to destroy")
	var b: Building = sim.buildings[sim_id]
	var level := maxi(b.level_at_destruction, 1)
	var type := String(b.archetype)

	var quote := sim.cmd_salvage_building(sim_id, true)
	assert_true(bool(quote["ok"]), str(quote.get("reason_code", "")))
	var payload: Dictionary = quote["payload"]
	assert_eq(int(payload["level"]), level, "valued at the level it fell down at")
	assert_true(int(payload["value"]) > 0, "and a ruin is worth something")
	# The quote carries the OTHER verb's price too, because the panel puts the
	# two side by side and a player deciding between them needs both numbers off
	# one call.
	assert_true(int(payload["restore_cost"]) > int(payload["value"]),
			("restoring ($%d) must cost more than salvaging pays ($%d), or the two "
					+ "verbs are a loop instead of a decision")
					% [int(payload["restore_cost"]), int(payload["value"])])

	var before := sim.treasury.balance
	var grid_id := b.id
	sim.bus.drain()
	var done := sim.cmd_salvage_building(sim_id)
	assert_true(bool(done["ok"]), str(done.get("reason_code", "")))
	assert_eq(sim.treasury.balance, before + int(payload["value"]),
			"paid exactly what it quoted")
	assert_false(sim.buildings.has(sim_id), "and the ruin is off the roster")

	# One event, the one every consumer already knows, with the `cause` that says
	# which verb did it. A second event for the same fact is a second thing to
	# keep in step.
	var removed := {}
	for event in sim.bus.drain():
		if StringName(String(event["type"])) == &"building_removed":
			removed = event
	assert_false(removed.is_empty(), "the renderer is told the ruin is gone")
	assert_eq(int(removed["building"]), grid_id, "by its RENDER id, not only its sim id")
	assert_eq(String(removed["cause"]), "salvaged",
			"and the cause distinguishes it from a demolition")
	assert_eq(int(removed["refund"]), int(payload["value"]))
	assert_eq(String(removed["archetype"]), sim.econ_curves.resolve_type(type),
			"the archetype the renderer needs to stop drawing")
	sim.dispose()


## The price is doc 03's, off the level the ruin fell down at, and nothing else.
func test_the_price_is_doc_03s_closed_form() -> void:
	var sim := CitySim.boot_from_files(SEED)
	var curves := sim.econ_curves
	var fraction := curves.salvage_fraction()

	# The three bounds the derivation is stated against
	# (`data/economy.json._salvage_derivation`), checked as inequalities so a
	# retune has to break one of them rather than a literal.
	assert_true(fraction < curves.demolition_refund_fraction(),
			("a WRECK (%.3f) may never be worth more than the same building "
					+ "knocked down intact (%.3f), or letting stock fall is a strategy")
					% [fraction, curves.demolition_refund_fraction()])
	assert_true(fraction < curves.restore_cost_fraction(),
			("salvaging (%.3f) may never pay for restoring (%.3f), or the two "
					+ "verbs are a money loop") % [fraction, curves.restore_cost_fraction()])
	# The arbitrage that already existed: restore at 0.20 and demolish at 0.25
	# nets 0.05 of capital per ruin (doc 91 A91-D-107). An honest verb has to pay
	# more than the exploit, or it gives the player a reason to run it.
	var arbitrage := curves.demolition_refund_fraction() - curves.restore_cost_fraction()
	assert_true(fraction > arbitrage,
			("salvage (%.3f) must dominate the restore-then-demolish arbitrage "
					+ "(%.3f), or the honest verb is the worse one")
					% [fraction, arbitrage])

	var sim_id := _destroy_one(sim)
	var b: Building = sim.buildings[sim_id]
	var level := maxi(b.level_at_destruction, 1)
	var type := String(b.archetype)
	var payload: Dictionary = sim.cmd_salvage_building(sim_id, true)["payload"]
	assert_eq(int(payload["value"]),
			CostCurves.round_half_up(float(curves.capital_value(type, level)) * fraction),
			"value = capital_value(level_at_destruction) × SALVAGE_FRACTION")
	# No difficulty multiplier: the presets scale what the city BUYS, never what
	# it is paid.
	assert_eq(int(payload["capital"]), curves.capital_value(type, level))
	sim.dispose()


## The three refusals, in the order the verb checks them, and the one that is
## deliberately absent.
func test_the_refusals_and_the_one_that_is_not_there() -> void:
	var sim := CitySim.boot_from_files(SEED)

	var unknown := sim.cmd_salvage_building("NO-SUCH-BUILDING", true)
	assert_false(bool(unknown["ok"]))
	assert_eq(String(unknown["reason_code"]), "E_UNKNOWN_BUILDING")

	# A STANDING building is the demolition verb's, not this one's — and the
	# refusal is the pair of the one `cmd_demolish_building` raises on a ruin.
	var standing := String(sim.roster_ids()[0])
	var wrong_state := sim.cmd_salvage_building(standing, true)
	assert_false(bool(wrong_state["ok"]))
	assert_eq(String(wrong_state["reason_code"]), "E_STATE")
	assert_eq(String(sim.cmd_demolish_building(_destroy_one(sim), true)["reason_code"]),
			"E_STATE", "and the two verbs cover each other's state exactly")

	# **No `E_FUNDS`, at any balance** — which is the whole point of the verb.
	# A city in the state the 2026-09-03 report describes is under water, and a
	# verb that refused it there would be the sixth door that opens only for
	# players who do not need it.
	var ruin := _destroy_one(sim)
	sim.treasury.balance = -50_000
	var broke := sim.cmd_salvage_building(ruin, true)
	assert_true(bool(broke["ok"]),
			"salvage quotes at a negative balance: %s" % str(broke.get("reason_code", "")))
	var paid := sim.cmd_salvage_building(ruin)
	assert_true(bool(paid["ok"]), "and commits there too")
	assert_true(sim.treasury.balance > -50_000, "moving the balance up")
	sim.dispose()


## A restore already in flight owns the lot, and the refusal is `E_STATE` rather
## than a job-in-flight code — because a lot with a rebuild on it is not a ruin
## any more. `Building.order_rebuild` moves `destroyed → planned →
## under_construction` in the same call the restore is committed in, so the state
## check is the only gate this verb needs and a second one would be unreachable.
func test_a_rebuild_in_flight_takes_the_lot_out_of_this_verbs_reach() -> void:
	var sim := CitySim.boot_from_files(SEED)
	var sim_id := _destroy_one(sim)
	assert_true(bool(sim.cmd_restore_building(sim_id)["ok"]), "the restore starts")
	assert_eq(String((sim.buildings[sim_id] as Building).state), "under_construction",
			"the ruin stopped being a ruin in the same call")
	var refused := sim.cmd_salvage_building(sim_id, true)
	assert_false(bool(refused["ok"]))
	assert_eq(String(refused["reason_code"]), "E_STATE")
	sim.dispose()


## The city that comes out the other side is a city, not a city with a hole in
## it: the same twelve steps a demolition takes, because it is the same function.
func test_salvage_leaves_the_same_city_a_demolition_would() -> void:
	var sim := CitySim.boot_from_files(SEED)
	var sim_id := _destroy_one(sim)
	var b: Building = sim.buildings[sim_id]
	var origin := b.origin
	assert_true(bool(sim.cmd_salvage_building(sim_id)["ok"]))

	assert_eq(sim.world.grid.building_at(origin.x, origin.y), 0,
			"the tiles are freed, so something else can be built there")
	assert_false(sim.grid.detach_building(sim_id),
			"the power service record was already detached by the removal")
	assert_true(sim.roster_ids().find(sim_id) < 0, "and the roster is invalidated")
	# An AUTHORED building owes the save a replay row, or the loader re-stamps it
	# on the next boot and the ruin comes back from the dead.
	var body: Dictionary = sim.canonical_capture()
	assert_true(str(body).find(sim_id) >= 0 or not sim_id.begins_with("P-"),
			"an authored removal is recorded for replay")

	# And the city still advances: the aggregates were refreshed inline, so the
	# next settled hour does not divide by a roster that moved.
	sim.advance_coarse_hours(2, false)
	assert_true(sim.boot_errors.is_empty())
	sim.dispose()


# ------------------------------------------------------------------ helpers

func _destroy_one(sim: CitySim) -> String:
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.state != &"active":
			continue
		b.ignite()
		b.burn_down(true, sim.clock.sim_time_minutes())
		return String(id)
	return ""
