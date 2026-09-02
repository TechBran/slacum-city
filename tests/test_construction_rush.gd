extends SimTest
## **The rush verb and the overview roster** — doc 02 §2.13, doc 03 §2.13(f),
## doc 93 §AA, report 98 §41 (RR-107…RR-110).
##
## The player's ask was two things at once: *"if we have buildings that are being
## upgraded or built on, those should have a queue that tells us what's actually
## being built and the progress tracker of that. And we also should have the
## ability to speed it up with cash."* The roster is the first half and
## `cmd_rush_construction` is the second, and the assertions below are the ones
## that separate a working valve from a plausible one.
##
## **The discriminating tests are the verb's own, and there are exactly four
## claims worth making** (report 98 RR-110):
##
##   1. the quote the roster draws is the dollar the treasury loses — no other
##      number is charged and nothing is charged on a refusal;
##   2. a rushed project and a naturally-finished one are the same building,
##      field for field, and the same event stream in the same order;
##   3. the price is doc 03 §2.5's contractor row carried to its limit, not a
##      new curve, and it lives in exactly one file;
##   4. the refusals refuse.
##
## Determinism is NOT asserted by a hash here and that is deliberate: no agent
## rushes, so the four `profile_sim` baselines cannot move, and the property this
## file owns instead is the one a baseline cannot see — a city that HAS rushed
## still replays from its save bit-identically.


const CORE_LO := 24
const CORE_HI := 88

## Everything a roster row must carry, and nothing else. The seam contract is
## verbatim on both branches, so an extra key here is as much of a break as a
## missing one — a field one side ships and the other does not expect is how a
## Wave-14 mismatch starts.
const ROW_KEYS: Array[String] = [
	"job_id", "source", "title_key", "ref", "tile", "level_from", "level_to",
	"progress01", "eta_gm", "crews", "rushable", "rush_cost",
]


static func _serviceable_lot(sim: CitySim, size: Vector2i = Vector2i.ONE) -> Vector2i:
	for z in range(CORE_LO, CORE_HI):
		for x in range(CORE_LO, CORE_HI):
			var t := Vector2i(x, z)
			if sim.world.grid.can_place(t, size) and sim.grid.would_serve(t):
				return t
	return Vector2i(-1, -1)


static func _rich_sim(seed_value: int = 4242) -> CitySim:
	var sim := CitySim.boot_from_files(seed_value)
	sim.treasury.balance = 5_000_000
	sim.progression.city_level = 5   # so the upgrade ladder is not the thing under test
	return sim


## A vacant core tile with a road one step away — doc 10 refuses a run that
## touches nothing, so this is where a player road can actually go.
static func _road_ready_tile(sim: CitySim) -> Vector2i:
	for z in range(CORE_LO, CORE_HI):
		for x in range(CORE_LO, CORE_HI):
			var t := Vector2i(x, z)
			if not sim.world.grid.can_place(t, Vector2i.ONE):
				continue
			for d in RoadGraph.DIRS:
				var q: Vector2i = t + d
				if TileGrid.in_bounds(q.x, q.y) \
						and sim.world.grid.road_class_at(q.x, q.y) != TileGrid.ROAD_NONE:
					return t
	return Vector2i(-1, -1)


## Put one doc 09 development phase in flight and return `{block, job_id}`.
##
## The starter city's nine blocks are all READY, so this buys a ring block — and
## `cmd_buy_block` auto-develops, which is what a player sees, so the phase is
## already running by the time the purchase returns.
static func _start_a_development_phase(sim: CitySim) -> Dictionary:
	for block_id in sim.world.block_ids_sorted():
		var block: LandBlock = sim.world.block(String(block_id))
		if block.is_ready():
			continue
		if not block.is_owned() and not bool(sim.cmd_buy_block(String(block_id))["ok"]):
			continue
		var live := sim.development.active_view(String(block_id))
		if live.is_empty():
			if not bool(sim.cmd_start_development(String(block_id))["ok"]):
				continue
			live = sim.development.active_view(String(block_id))
		if not live.is_empty() and int(live.get("job_id", 0)) > 0:
			return {"block": String(block_id), "job_id": int(live["job_id"])}
	return {}


## Place a house and return its job row from the roster.
static func _place_house(sim: CitySim) -> Dictionary:
	var placed := sim.cmd_place_building("house", _serviceable_lot(sim))
	return {"sim_id": String(placed["payload"]["sim_id"]),
			"job_id": int(placed["payload"]["job_id"]),
			"cost": int(placed["payload"]["cost"])}


static func _row_for(sim: CitySim, job_id: int) -> Dictionary:
	for row in sim.construction_overview():
		if int(row["job_id"]) == job_id:
			return row
	return {}


static func _sorted_keys(d: Dictionary) -> Array:
	var out: Array = d.keys()
	out.sort()
	return out


static func _types(events: Array) -> Array[String]:
	var out: Array[String] = []
	for event: Dictionary in events:
		out.append(String(event.get("type", "")))
	return out


# =========================================================== the price, derived

func test_the_rush_rate_is_the_contractor_row_carried_to_its_limit() -> void:
	# doc 03 §2.13(f). NOT an invented number: §2.5's emergency contractor buys
	# (1 − 0.35) of a project's duration for a surcharge of (1.80 − 1) of its
	# cash price, so the published price of time is 0.80 / 0.65 per unit of full
	# duration. The cell in economy.json is that quotient to five decimals.
	var economy: Dictionary = StarterCityLoader.read_json("res://data/economy.json")
	var expenses: Dictionary = economy["expenses"]
	var surcharge := float(expenses["CONTRACTOR_SURCHARGE"])
	var time_fraction := float(expenses["CONTRACTOR_TIME_FRACTION"])
	var published := float(expenses["RUSH_SURCHARGE_PER_DURATION"])
	var derived := (surcharge - 1.0) / (1.0 - time_fraction)
	assert_almost_eq(published, derived, CostCurves.RUSH_DERIVATION_TOLERANCE,
			"the published rate IS 0.80 / 0.65, to the tolerance the loader checks")
	assert_almost_eq(published, 1.23077, 0.000005, "1.23077 as authored")
	# And the loader refuses a cell that has drifted away from its derivation —
	# which is what makes the constant safe to publish rather than compute.
	var mangled: Dictionary = economy.duplicate(true)
	(mangled["expenses"] as Dictionary)["RUSH_SURCHARGE_PER_DURATION"] = 2.0
	var broken := CostCurves.new(
			StarterCityLoader.read_json("res://data/building_economy.json"), mangled)
	assert_false(broken.is_valid(), "a drifted rush rate is a BOOT ERROR: %s"
			% str(broken.errors))


func test_a_full_length_rush_costs_a_meaningful_premium_of_the_cash_price() -> void:
	var curves := CostCurves.load_from_files()
	assert_true(curves.is_valid(), ", ".join(curves.errors))
	# A house: $1,200 of cash price over 2.0 crew-hours. Rushing the whole thing
	# quotes 1.23077 × 1,200 = 1,476.92 → $1,477 on top of what was already paid,
	# so an instantly-finished house costs 2.23× its sticker. Deliberately bad
	# value, inherited from §2.5 rather than re-argued.
	assert_eq(curves.rush_cost(1200, 2.0, 2.0), 1477, "full-length house rush")
	assert_eq(curves.rush_cost(180_000, 20.0, 20.0), 221_539,
			"a data centre's full-length rush, at the same rate")
	# Per hour saved, the rush and the contractor are the SAME price — which is
	# what stops either valve dominating the other.
	var contractor_surcharge := curves.contractor_cost(1200) - 1200
	assert_almost_eq(float(curves.rush_cost(1200, 2.0, 2.0)) * 0.65,
			float(contractor_surcharge), 1.0,
			"0.65 of a full rush IS the contractor's surcharge")


func test_the_quote_falls_with_the_work_that_is_left() -> void:
	var curves := CostCurves.load_from_files()
	assert_eq(curves.rush_cost(1200, 2.0, 1.0), 739, "half done, half price (ceiled)")
	assert_eq(curves.rush_cost(1200, 2.0, 0.0), 0, "nothing left, nothing owed")
	# Ceiling, not §2.1's half-up, and this is the one price in the ladder that
	# rounds that way: a project at 99.9 % may not be finished for $0.
	assert_eq(curves.rush_cost(1200, 2.0, 0.0001), 1,
			"the last sliver still costs a dollar")


func test_no_other_data_file_carries_the_rush_price() -> void:
	# C-07's monopoly, asserted the way A91-D-40 says it has to be: by checking
	# ABSENCE. A test that only proves doc 03's cell is present and well-shaped
	# passes identically whether a second, live copy exists elsewhere.
	var dir := DirAccess.open("res://data")
	assert_true(dir != null, "res://data is readable")
	var offenders: PackedStringArray = []
	for file_name in dir.get_files():
		if not file_name.ends_with(".json") or file_name == "economy.json":
			continue
		var text := FileAccess.get_file_as_string("res://data/" + file_name)
		if text.contains("\"RUSH_SURCHARGE_PER_DURATION\""):
			offenders.append(file_name)
	assert_eq(str(offenders), "[]",
			"doc 03 §2.13(f)'s rate lives in data/economy.json and nowhere else")


# ============================================================= the roster shape

func test_the_roster_row_is_the_seam_contract_verbatim() -> void:
	var sim := _rich_sim()
	var house := _place_house(sim)
	var rows := sim.construction_overview()
	assert_true(rows.size() >= 1, "the house is in flight")
	var row := _row_for(sim, int(house["job_id"]))
	assert_false(row.is_empty(), "the placed house has a roster row")
	var keys: Array = row.keys()
	keys.sort()
	var expected := ROW_KEYS.duplicate()
	expected.sort()
	assert_eq(str(keys), str(expected), "the row carries exactly the contract's fields")
	assert_eq(row["source"], &"build")
	assert_eq(String(row["title_key"]), "ui_build_card_house")
	assert_eq(String(row["ref"]), String(house["sim_id"]))
	assert_eq(int(row["level_from"]), 0, "a build is not a level change")
	assert_eq(int(row["level_to"]), 0)
	assert_eq(int(row["crews"]), 1, "the MVP yard crew")
	assert_true(bool(row["rushable"]))
	assert_true(float(row["eta_gm"]) > 0.0, "a crewed job quotes an ETA")
	assert_true(typeof(row["tile"]) == TYPE_VECTOR2I, "tile is a Vector2i")
	assert_eq(row["tile"], (sim.buildings[String(house["sim_id"])] as Building).origin)


func test_the_roster_covers_every_machine_the_player_calls_construction() -> void:
	# The whole point of the roster: whatever is running it, if the player would
	# call it "being built", it is on this list. Buildings, upgrades, repairs,
	# roads and doc 09's development phases all ride doc 02 §2.13's ONE queue —
	# `cmd_upgrade_building` has no clock of its own — so the list is complete by
	# construction and this test is what says so out loud.
	var sim := _rich_sim()
	_place_house(sim)
	assert_true(bool(sim.cmd_place_road([_road_ready_tile(sim)],
			TileGrid.ROAD_STREET)["ok"]), "a road job joins the same queue")
	assert_false(_start_a_development_phase(sim).is_empty(), "a phase is in flight")
	var sources := {}
	for row in sim.construction_overview():
		sources[String(row["source"])] = true
	assert_true(sources.has("build"), "a building shell")
	assert_true(sources.has("road"), "a road job")
	assert_true(sources.has("block"), "a land-development phase")


func test_every_job_kind_has_a_published_source() -> void:
	# The map is total over the queue's own KINDS, so a new kind cannot reach the
	# roster as a word the UI branch was never told about.
	for kind: StringName in ConstructionQueue.KINDS:
		assert_true(CitySim.CONSTRUCTION_SOURCE_BY_KIND.has(kind),
				"kind %s has a published source word" % kind)


func test_every_title_key_the_roster_can_answer_resolves() -> void:
	# doc 12's rule: a namespaced key, and it names a real string. A roster that
	# hands `ui/` a key nothing translates renders as a blank line.
	var strings: Dictionary = StarterCityLoader.read_json("res://data/strings.en.json")
	var sim := _rich_sim()
	# The first house finishes so a second one can be UPGRADED; the road and the
	# development phase are opened after that, so all four live sources are on
	# the roster at the same instant.
	var first := _place_house(sim)
	sim.advance_hours(4.0)
	assert_eq((sim.buildings[String(first["sim_id"])] as Building).state, &"active")
	assert_true(bool(sim.cmd_upgrade_building(String(first["sim_id"]))["ok"]))
	_place_house(sim)
	sim.cmd_place_road([_road_ready_tile(sim)], TileGrid.ROAD_STREET)
	assert_false(_start_a_development_phase(sim).is_empty(), "a phase is in flight")
	var seen := {}
	for row in sim.construction_overview():
		var key := String(row["title_key"])
		assert_true(strings.has(key), "%s (source %s) resolves in strings.en.json"
				% [key, String(row["source"])])
		seen[String(row["source"])] = key
	assert_eq(str(_sorted_keys(seen)), str(["block", "build", "road", "upgrade"]),
			"four live sources were inspected, not one")
	# The five keys this branch authored are all present and namespaced.
	for key in ["ui_queue_title_project", "ui_queue_title_road_street",
			"ui_queue_title_road_avenue", "ui_queue_title_road_upgrade",
			"ui_queue_title_road_repair"]:
		assert_true(strings.has(key), "%s is authored" % key)


func test_the_roster_sorts_by_eta_with_the_uncrewed_last() -> void:
	var sim := _rich_sim()
	_place_house(sim)
	_place_house(sim)
	_place_house(sim)
	# Strip one job's crew: it now has no rate, so its ETA is −1 and it sorts to
	# the bottom rather than rendering as 0:00.
	var stripped := int(sim.construction.active_jobs()[0]["job_id"])
	sim.construction.release_crew(stripped, "YARD-CREW-1", "test")
	var rows := sim.construction_overview()
	assert_true(rows.size() >= 3)
	assert_eq(int(rows[rows.size() - 1]["job_id"]), stripped,
			"nothing is working it, so it goes last")
	assert_eq(float(rows[rows.size() - 1]["eta_gm"]), -1.0,
			"and it says so rather than quoting 0:00")
	assert_eq(int(rows[rows.size() - 1]["crews"]), 0)
	var previous := -1.0
	for i in rows.size() - 1:
		var eta := float(rows[i]["eta_gm"])
		assert_true(eta >= previous, "ETAs ascend")
		previous = eta


func test_the_upgrade_row_carries_the_level_pair() -> void:
	var sim := _rich_sim()
	var house := _place_house(sim)
	sim.advance_hours(6.0)
	var b: Building = sim.buildings[String(house["sim_id"])]
	assert_eq(b.state, &"active", "the shell finished")
	var upgraded := sim.cmd_upgrade_building(String(house["sim_id"]))
	assert_true(bool(upgraded["ok"]), str(upgraded))
	var row := _row_for(sim, int(upgraded["payload"]["job_id"]))
	assert_eq(row["source"], &"upgrade")
	assert_eq(int(row["level_from"]), 1)
	assert_eq(int(row["level_to"]), 2)
	assert_eq(String(row["title_key"]), "ui_build_card_house",
			"the noun is the building; `source` is what makes it an upgrade")


# ============================================ the quote IS the charge

func test_the_quote_the_roster_draws_is_the_dollar_the_treasury_loses() -> void:
	var sim := _rich_sim()
	var house := _place_house(sim)
	sim.advance_hours(0.5)   # a quarter of the way in, so the quote is a fraction
	var row := _row_for(sim, int(house["job_id"]))
	var quote := int(row["rush_cost"])
	assert_true(quote > 0, "a live project quotes a price")
	# The quote is exactly the remaining fraction of the full-length price.
	var remaining := sim.construction.remaining_crew_hours(int(house["job_id"]))
	var expected := sim.econ_curves.rush_cost(int(house["cost"]),
			float(sim.construction.job(int(house["job_id"]))["required_crew_hours"]),
			remaining)
	assert_eq(quote, expected, "the roster quotes CostCurves, not a second formula")
	var before := sim.treasury.balance
	var result := sim.cmd_rush_construction(house["job_id"])
	assert_true(bool(result["ok"]), str(result))
	assert_eq(int(result["cost"]), quote, "the command charges what the row quoted")
	assert_eq(String(result["err"]), "")
	assert_eq(sim.treasury.balance, before - quote,
			"the ledger line moves by exactly the quote — no rounding, no partial")


func test_the_charge_is_whole_or_it_does_not_happen() -> void:
	# Doc 03 §2.10 layer 4 lets a spend DEFER past the credit floor. A rush may
	# not: a half-paid rush would buy a whole building. The gate is `can_spend`,
	# so the refusal happens before a dollar moves.
	var sim := _rich_sim()
	var house := _place_house(sim)
	var quote := int(_row_for(sim, int(house["job_id"]))["rush_cost"])
	sim.treasury.balance = -sim.treasury.credit_limit + quote - 1
	var before := sim.treasury.balance
	var before_deferred := sim.treasury.deferred_liability
	var refused := sim.cmd_rush_construction(house["job_id"])
	assert_false(bool(refused["ok"]))
	assert_eq(String(refused["err"]), "E_FUNDS")
	assert_eq(int(refused["cost"]), quote, "the quote rides in the refusal")
	assert_eq(sim.treasury.balance, before, "nothing was charged")
	assert_eq(sim.treasury.deferred_liability, before_deferred, "nothing was deferred")
	assert_false(sim.construction.job(int(house["job_id"])).is_empty(),
			"and the job is untouched")
	# One dollar more and it goes through.
	sim.treasury.balance = -sim.treasury.credit_limit + quote
	assert_true(bool(sim.cmd_rush_construction(house["job_id"])["ok"]))


func test_austerity_closes_the_valve() -> void:
	# A rush is a NEW commitment, so doc 03 §2.10 layer 2's austerity gate on the
	# `construction` category refuses it — the same answer `cmd_place_building`
	# gives — and the player is told the treasury cannot pay, with the quote.
	var sim := _rich_sim()
	var house := _place_house(sim)
	var quote := int(_row_for(sim, int(house["job_id"]))["rush_cost"])
	sim.treasury.austerity_active = true
	var before := sim.treasury.balance
	var refused := sim.cmd_rush_construction(house["job_id"])
	assert_false(bool(refused["ok"]))
	assert_eq(String(refused["err"]), "E_FUNDS")
	assert_eq(int(refused["cost"]), quote)
	assert_eq(sim.treasury.balance, before)


# =================================== a rushed finish IS a natural finish

func test_a_rushed_building_equals_a_naturally_finished_one() -> void:
	# The claim the whole design rests on: paying skips the WAIT, not the work.
	# Two cities, same seed, same house; one finishes it on the clock and one
	# buys the rest of the hours. The buildings must be indistinguishable.
	var natural := _rich_sim(9001)
	var rushed := _rich_sim(9001)
	var a := _place_house(natural)
	var b := _place_house(rushed)
	assert_eq(String(a["sim_id"]), String(b["sim_id"]), "same city, same id")
	natural.bus.drain()
	rushed.bus.drain()
	rushed.cmd_rush_construction(b["job_id"])
	var rushed_events := rushed.bus.drain()
	# Let the reference finish the same job the slow way.
	for i in 200:
		natural.advance_hours(0.05)
		if (natural.buildings[String(a["sim_id"])] as Building).state == &"active":
			break
	var natural_events := natural.bus.drain()
	var ba: Building = natural.buildings[String(a["sim_id"])]
	var bb: Building = rushed.buildings[String(b["sim_id"])]
	assert_eq(bb.state, ba.state, "state")
	assert_eq(bb.level, ba.level, "level")
	assert_eq(bb.pending_level, ba.pending_level, "pending_level")
	assert_eq(bb.condition, ba.condition, "condition")
	assert_eq(bb.max_level, ba.max_level, "max_level")
	assert_eq(str(bb.stats), str(ba.stats), "the stats row was re-read")
	assert_eq(bb.origin, ba.origin, "origin")
	assert_true(bb.state == &"active", "and it really did finish")
	# The queue is empty on both, and neither left a stage-pulse residue behind.
	assert_eq(rushed.construction.active_count(), natural.construction.active_count())
	assert_false(rushed._last_construction_stage.has(String(b["sim_id"])),
			"a rushed site clears its stage residue exactly as a natural one does")
	# The completion event stream: the rush adds its receipt and changes nothing
	# else. `building_completed` is what the translator, the notification binding
	# and doc 09's goals all watch, and it has to be the SAME event.
	var natural_types := _types(natural_events)
	var rushed_types := _types(rushed_events)
	assert_true(natural_types.has("building_completed"), str(natural_types))
	assert_true(rushed_types.has("building_completed"),
			"a rushed finish fires the natural completion event: %s" % str(rushed_types))
	assert_true(rushed_types.has("construction_rushed"), "plus the one new receipt")
	rushed_types.erase("construction_rushed")
	# Everything the natural finish emitted at the moment of completion, the
	# rushed one emitted too, in the same relative order.
	var natural_tail := natural_types.slice(
			natural_types.find("building_completed"))
	var rushed_tail := rushed_types.slice(rushed_types.find("building_completed"))
	assert_eq(str(rushed_tail), str(natural_tail),
			"same events, same order, from `building_completed` onward")


func test_the_receipt_names_the_job_the_price_and_the_source() -> void:
	var sim := _rich_sim()
	var house := _place_house(sim)
	var quote := int(_row_for(sim, int(house["job_id"]))["rush_cost"])
	sim.bus.drain()
	sim.cmd_rush_construction(house["job_id"])
	var receipt := {}
	for event in sim.bus.drain():
		if String(event["type"]) == "construction_rushed":
			receipt = event
	assert_false(receipt.is_empty(), "the event reached the batch")
	assert_eq(int(receipt["job"]), int(house["job_id"]))
	assert_eq(int(receipt["cost"]), quote)
	assert_eq(receipt["source"], &"build")


func test_a_rushed_development_phase_bills_the_next_one_in_the_same_breath() -> void:
	# doc 09's pipeline auto-submits the next phase the moment one lands, and doc
	# 03 §2.8 bills it in the SAME tick so the ledger never runs a phase behind
	# the site. A rush is a completion, so it owes the same invoice — which is
	# why `_charge_development_phases` is on the rush path and not only the tick.
	var sim := _rich_sim()
	var phase := _start_a_development_phase(sim)
	assert_false(phase.is_empty(), "a development phase is in flight")
	var target := String(phase["block"])
	var first_job := int(phase["job_id"])
	var row := _row_for(sim, first_job)
	assert_eq(row["source"], &"block", "a development phase reads as a BLOCK")
	assert_eq(String(row["title_key"]), "ui_land_phase_survey")
	assert_true(int(row["rush_cost"]) > 0, "a phase is priced off doc 03 §2.8")
	var before := sim.treasury.balance
	var result := sim.cmd_rush_construction(first_job)
	assert_true(bool(result["ok"]), str(result))
	var live := sim.development.active_view(target)
	assert_eq(int(live["phase_index"]), 1, "the pipeline moved on")
	var second_job := int(live["job_id"])
	assert_true(second_job > 0, "and the next phase was submitted")
	assert_eq(int((sim.construction.job(second_job)["assigned_crews"] as Dictionary).size()),
			1, "the next phase got its crew from the same charge pass")
	assert_true(sim.treasury.balance < before - int(result["cost"]),
			"the rush AND the next phase's invoice both landed")


func test_a_rushed_road_job_lands_its_tiles() -> void:
	var sim := _rich_sim()
	var tiles := [_road_ready_tile(sim)]
	var placed := sim.cmd_place_road(tiles, TileGrid.ROAD_STREET)
	assert_true(bool(placed["ok"]), str(placed))
	var job_id := int(placed["payload"]["job_id"])
	var row := _row_for(sim, job_id)
	assert_eq(row["source"], &"road")
	assert_eq(String(row["title_key"]), "ui_queue_title_road_street")
	assert_eq(row["tile"], tiles[0], "the row focuses the first tile of the run")
	assert_true(bool(sim.cmd_rush_construction(job_id)["ok"]))
	for t: Vector2i in tiles:
		assert_almost_eq(sim.roads.condition_of(t), 1.0, 0.001,
				"a rushed road tile is a finished road tile")


# ================================================================== refusals

func test_the_refusals_refuse() -> void:
	var sim := _rich_sim()
	var house := _place_house(sim)
	var before := sim.treasury.balance

	var unknown := sim.cmd_rush_construction(999_999)
	assert_false(bool(unknown["ok"]))
	assert_eq(String(unknown["err"]), "E_UNKNOWN_JOB")
	assert_eq(int(unknown["cost"]), 0)

	# A job with no work in it at all is already complete and cannot be bought.
	var empty_job := sim.construction.submit(&"build", "NOWHERE", 0.0,
			&"construction_crew", {"sim_id": "NOWHERE", "cost": 500})
	var complete := sim.cmd_rush_construction(empty_job)
	assert_false(bool(complete["ok"]))
	assert_eq(String(complete["err"]), "E_JOB_COMPLETE")
	assert_eq(int(complete["cost"]), 0)

	# A job whose cash price does not resolve is not rushable, and the roster
	# says so on the row before the player can ever tap it.
	var unpriced := sim.construction.submit(&"build", "NOWHERE", 4.0)
	var unpriced_row := _row_for(sim, unpriced)
	assert_false(bool(unpriced_row["rushable"]))
	assert_eq(int(unpriced_row["rush_cost"]), 0)
	var not_rushable := sim.cmd_rush_construction(unpriced)
	assert_false(bool(not_rushable["ok"]))
	assert_eq(String(not_rushable["err"]), "E_NOT_RUSHABLE")

	assert_eq(sim.treasury.balance, before, "not one refusal charged a dollar")
	assert_false(sim.construction.job(int(house["job_id"])).is_empty(),
			"and the live job was never touched")


func test_the_id_coercion_at_the_door() -> void:
	# The Wave-14 String-id lesson: doc 12 §4.4's tap funnel carries ids as text.
	var sim := _rich_sim()
	var house := _place_house(sim)
	var quote := int(_row_for(sim, int(house["job_id"]))["rush_cost"])
	var result := sim.cmd_rush_construction(str(house["job_id"]))
	assert_true(bool(result["ok"]), "a String id is the same id: %s" % str(result))
	assert_eq(int(result["cost"]), quote)


func test_an_uncrewed_job_is_the_one_a_player_most_wants_to_buy() -> void:
	# doc 03 §2.5 calls this "paying to bypass the construction/crew queue", so a
	# job sitting at `blocked_reason = no_crew` is precisely the case the valve
	# exists for. It quotes and it completes.
	var sim := _rich_sim()
	var house := _place_house(sim)
	sim.construction.release_crew(int(house["job_id"]), "YARD-CREW-1", "preempted")
	var row := _row_for(sim, int(house["job_id"]))
	assert_eq(int(row["crews"]), 0)
	assert_eq(float(row["eta_gm"]), -1.0, "nothing is working it")
	assert_true(bool(row["rushable"]), "and it is still rushable")
	assert_true(int(row["rush_cost"]) > 0)
	assert_true(bool(sim.cmd_rush_construction(house["job_id"])["ok"]))
	assert_eq((sim.buildings[String(house["sim_id"])] as Building).state, &"active")


# =============================================== persistence and determinism

func test_a_city_that_has_rushed_still_replays_from_its_save() -> void:
	# Instant completion adds NO state — there is no per-job flag, no timer, no
	# second accumulator — so the property to prove is that the city on the far
	# side of a rush is an ordinary city: save, restore, advance, bit-identical.
	var live := _rich_sim(7777)
	var house := _place_house(live)
	live.advance_hours(0.4)
	assert_true(bool(live.cmd_rush_construction(house["job_id"])["ok"]))
	live.advance_hours(1.0)
	var twin := _rich_sim(7777)
	twin.restore_state(live.canonical_capture())
	assert_eq(twin.state_hash(), live.state_hash(),
			"a rushed city restores at rest")
	live.advance_hours(2.0)
	twin.advance_hours(2.0)
	assert_eq(twin.state_hash(), live.state_hash(),
			"and replays bit-identically two game-hours on (constitution §5)")


func test_the_rush_is_reproducible() -> void:
	# Same seed, same taps, same city — the verb draws no RNG and reads no clock.
	var hashes: Array[String] = []
	for run in 2:
		var sim := _rich_sim(31337)
		var house := _place_house(sim)
		sim.advance_hours(0.3)
		sim.cmd_rush_construction(house["job_id"])
		sim.advance_hours(1.0)
		hashes.append(sim.state_hash())
	assert_eq(hashes[0], hashes[1], "the rush is a deterministic command")


func test_the_roster_survives_a_save_and_still_points_at_real_tiles() -> void:
	# A91-D-47's guard from the other side: doc 10's own job record is what the
	# roster reads for a road job's geometry, so a road row still focuses a real
	# tile after a load — where the queue payload's own copy has degraded to text.
	var live := _rich_sim(2468)
	var tiles := [_road_ready_tile(live)]
	var placed := live.cmd_place_road(tiles, TileGrid.ROAD_STREET)
	assert_true(bool(placed["ok"]), str(placed))
	var job_id := int(placed["payload"]["job_id"])
	var twin := _rich_sim(2468)
	twin.restore_state(live.canonical_capture())
	var row := _row_for(twin, job_id)
	assert_false(row.is_empty(), "the road job survived the save")
	assert_eq(row["tile"], tiles[0], "and the row still points at a real tile")
	assert_true(bool(row["rushable"]), "and it is still priced")
	assert_eq(int(row["rush_cost"]), int(_row_for(live, job_id)["rush_cost"]),
			"at the same quote it had before the save")


func test_a_repair_is_on_the_roster_and_can_be_bought_out() -> void:
	# The fifth live kind, and the only one this file did not put on the roster.
	# `repair` is the case where "being built" is the player's word for something
	# that is not construction at all, so the row has to carry a resolving noun
	# and a real quote like every other row — and the rush has to land on
	# `on_construction_completed`'s REPAIR arm, which is a different branch of
	# the completion door from a build or an upgrade.
	var sim := _rich_sim()
	var b: Building = sim.buildings["H-001"]
	b.condition = 0.40
	var repair := sim.cmd_repair_building("H-001")
	assert_true(bool(repair["ok"]), str(repair))
	var job_id := int(repair["payload"]["job_id"])
	var row := _row_for(sim, job_id)
	assert_false(row.is_empty(), "a repair is a project the player is watching")
	assert_eq(String(row["source"]), "repair", "and it says what it is")
	assert_eq(String(row["ref"]), "H-001")
	assert_eq(int(row["level_from"]), 0, "a repair is not a level change")
	assert_eq(int(row["level_to"]), 0)
	assert_true(bool(row["rushable"]), "the repair bill is on the job record")
	var strings: Dictionary = StarterCityLoader.read_json("res://data/strings.en.json")
	assert_true(strings.has(String(row["title_key"])),
			"%s resolves" % String(row["title_key"]))
	# Buy it out: the quote is the charge, and the repair arm really ran.
	var quote := int(row["rush_cost"])
	assert_true(quote > 0, "a damaged house has a repair bill to be a fraction of")
	var before := sim.treasury.balance
	var rushed := sim.cmd_rush_construction(job_id)
	assert_true(bool(rushed["ok"]), str(rushed))
	assert_eq(int(rushed["cost"]), quote, "the roster's quote is the dollar taken")
	assert_eq(sim.treasury.balance, before - quote, "and nothing else moved")
	assert_eq(b.state, &"active", "repairing → active, through the same door")
	assert_true(b.condition > 0.40,
			"the condition really was restored: %f" % b.condition)
	assert_true(_row_for(sim, job_id).is_empty(), "and the row left the roster")
