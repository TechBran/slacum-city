extends SimTest
## Doc 03 §2.8b — **what the crews find while they dig a block out**, and the
## materials yard half of it (ruling 93 §AZ, doc 92 §66, report 98 §69 RR-210).
##
## Five things are held here, in the order they would go wrong:
##
##   1. **Only three phases pay, and each pays inside its published band.**
##      CLEARING, GRADING and UTILITY_CORRIDOR; SURVEY, ROAD_INSTALL and
##      FINAL_DEVELOPMENT yield nothing at all.
##   2. **The ceiling is a theorem, not a hope.** A block's cumulative yield is
##      clamped to `CEILING_FRACTION × its own six-phase bill`, so a block can
##      never pay for its own development — and the clamp is checked where it
##      actually bites, by walking a block up to its ceiling first.
##   3. **The split adds up.** `cash + stockpiled == value`, timber banks
##      nothing, the yard never exceeds its cap and nothing is lost when it is
##      full.
##   4. **The yard spends itself on the two phases the material is for**, at
##      most a quarter of the invoice, and says so on the bus.
##   5. **The money is on doc 03's line**, not only in the balance —
##      `hour_city_services.excavation` and `ledger_totals.lifetime_excavation` —
##      and the whole thing survives a save round trip.

const YIELD_PHASES: Array[StringName] = [&"CLEARING", &"GRADING", &"UTILITY_CORRIDOR"]
const BARREN_PHASES: Array[StringName] = [&"SURVEY", &"ROAD_INSTALL", &"FINAL_DEVELOPMENT"]


func _sim(seed_value: int = 1337) -> CitySim:
	var sim := CitySim.boot_from_files(seed_value)
	assert_eq(str(sim.boot_errors), "[]", "the city boots clean")
	sim.treasury.balance = 50_000_000
	return sim


## The cheapest block the city may buy right now — the same choice
## `tools/measure_land_works.gd` makes, so a test and the instrument look at the
## same block.
func _purchasable(sim: CitySim) -> String:
	var best := ""
	var best_price := 0
	for id: String in sim.world.block_ids_sorted():
		if sim.world.block(id).ownership_state != &"PURCHASABLE":
			continue
		if not bool(sim.world.purchase_allowed(id, sim.progression.city_level)["ok"]):
			continue
		var price := sim.economy.land_price(sim.land_price_inputs(id))
		if best == "" or price < best_price:
			best = id
			best_price = price
	return best


## Buy one block, develop it to READY, and hand back every `land_works_*` event
## the bus carried on the way.
func _develop(sim: CitySim, hours: int = 400) -> Dictionary:
	var block_id := _purchasable(sim)
	assert_ne(block_id, "", "the starter city has a block to buy")
	assert_true(bool(sim.cmd_buy_block(block_id, false, true)["ok"]))
	var finds: Array[Dictionary] = []
	var spends: Array[Dictionary] = []
	var charges: Array[Dictionary] = []
	for _h in hours:
		if sim.world.block(block_id).is_ready():
			break
		sim.advance_hours(1.0)
		for event: Dictionary in sim.bus.drain():
			match String(event.get("type", "")):
				"land_works_find":
					finds.append(event)
				"land_works_stockpile_spent":
					spends.append(event)
				"development_phase_charged":
					charges.append(event)
	return {"block": block_id, "finds": finds, "spends": spends, "charges": charges}


# ===========================================================================
# 1. Which phases pay, and how much
# ===========================================================================

func test_three_phases_pay_and_three_do_not() -> void:
	var sim := _sim()
	for phase: StringName in YIELD_PHASES:
		assert_false(sim.economy.works_yield_row(String(phase).to_lower()).is_empty(),
				"%s has a §2.8b row" % phase)
	for phase: StringName in BARREN_PHASES:
		assert_true(sim.economy.works_yield_row(String(phase).to_lower()).is_empty(),
				"%s yields nothing — a survey turns up no timber" % phase)
	# The three ids are doc 03's six-phase list, so a rename there breaks here
	# rather than silently pricing a phase that no longer exists.
	for row: Variant in sim.economy.works_yield_rows():
		assert_true(sim.economy.development_phase_index(
				String((row as Dictionary)["id"])) >= 0,
				"every works_yield row names a real §2.8 phase")
	sim.dispose()


func test_a_full_development_pays_exactly_three_times_inside_the_band() -> void:
	var sim := _sim()
	var run := _develop(sim)
	var finds: Array = run["finds"]
	assert_eq(finds.size(), 3,
			"one find per credited phase, and no more: %s" % str(finds.size()))
	var block := sim.world.block(String(run["block"]))
	var d := float(sim.world.d_from_center(String(run["block"])))
	var m_dev := float(sim.treasury.difficulty().get("M_dev", 1.0))
	var seen: Array[String] = []
	for entry: Variant in finds:
		var find: Dictionary = entry
		var phase := String(find["phase"])
		seen.append(phase)
		var low := sim.economy.works_yield_value(phase.to_lower(),
				String(block.dev_terrain), d, block.arterial_connections, m_dev, 0.0)
		var high := sim.economy.works_yield_value(phase.to_lower(),
				String(block.dev_terrain), d, block.arterial_connections, m_dev, 1.0,
				bool(find["bonus"]))
		assert_true(int(find["value"]) >= low and int(find["value"]) <= high,
				"%s paid $%d, inside [$%d, $%d]" % [phase, int(find["value"]), low, high])
	seen.sort()
	assert_eq(str(seen), '["CLEARING", "GRADING", "UTILITY_CORRIDOR"]',
			"the three that pay are the three doc 03 §2.8b names")
	sim.dispose()


func test_the_same_seed_finds_the_same_things() -> void:
	# Constitution §5. The `land_works` stream is drawn twice per credited phase
	# in a fixed order, so two cities on one seed dig up the same city.
	var a := _sim(4242)
	var b := _sim(4242)
	var run_a := _develop(a)
	var run_b := _develop(b)
	assert_eq(str((run_a["finds"] as Array).map(func(e: Dictionary) -> int:
			return int(e["value"]))),
			str((run_b["finds"] as Array).map(func(e: Dictionary) -> int:
			return int(e["value"]))),
			"same seed, same finds")
	a.dispose()
	b.dispose()


# ===========================================================================
# 2. The ceiling
# ===========================================================================

func test_the_ceiling_is_below_the_road_it_pays_for_on_every_terrain() -> void:
	# Doc 92 §66.3's bound 1, as an inequality rather than a literal: the find
	# may never cover the ROAD_INSTALL phase the material is dug for, or the
	# infrastructure builds itself. Checked over every terrain doc 03 authors and
	# a distance range that covers the whole map.
	var sim := _sim()
	var ceiling := float(sim.economy.works_yield().get("CEILING_FRACTION", 0.0))
	assert_true(ceiling > 0.0, "the data file carries a ceiling at all")
	for terrain: String in (sim.economy.development_terrains()):
		for d: int in [0, 4, 8, 12]:
			var bill := sim.economy.development_total_cost(terrain, float(d))
			var road := sim.economy.development_phase_cost("road_install", terrain, float(d))
			assert_true(ceiling < float(road) / float(bill),
					"%s @ d=%d: ceiling %.4f < ROAD_INSTALL share %.4f"
					% [terrain, d, ceiling, float(road) / float(bill)])
	# Bound 2: the ground you dig may never be worth more than a whole building
	# taken apart (doc 03 §2.5's SALVAGE_FRACTION).
	assert_true(ceiling < sim.econ_curves.salvage_fraction(),
			"ceiling %.4f < SALVAGE_FRACTION %.4f"
			% [ceiling, sim.econ_curves.salvage_fraction()])
	sim.dispose()


func test_a_block_at_its_ceiling_is_short_paid_and_says_so() -> void:
	# The clamp, driven where it bites. The block is walked to $10 under its own
	# ceiling before the pipeline is allowed to find anything, so whatever the
	# roll comes up with, the credit is exactly the headroom and the payload is
	# flagged `capped`.
	var sim := _sim()
	var block_id := _purchasable(sim)
	assert_true(bool(sim.cmd_buy_block(block_id, false, false)["ok"]))
	var block := sim.world.block(block_id)
	var d := float(sim.world.d_from_center(block_id))
	var m_dev := float(sim.treasury.difficulty().get("M_dev", 1.0))
	var ceiling := sim.economy.works_yield_ceiling(String(block.dev_terrain), d,
			block.arterial_connections, m_dev)
	block.works_yield_total = ceiling - 10
	var before := sim.treasury.balance
	sim._credit_land_works(block_id, &"CLEARING")
	assert_eq(block.works_yield_total, ceiling,
			"the block stops dead on its ceiling")
	assert_eq(sim.treasury.balance, before + 10,
			"…and is paid the headroom, not the roll")
	var flagged := false
	for event: Dictionary in sim.bus.drain():
		if String(event.get("type", "")) == "land_works_find":
			flagged = bool(event["capped"])
	assert_true(flagged, "the payload says it was clamped")
	# At the ceiling exactly, the next find is nothing at all — and emits
	# nothing, because a $0 receipt is not a receipt.
	var quiet_before := sim.treasury.balance
	sim._credit_land_works(block_id, &"GRADING")
	assert_eq(sim.treasury.balance, quiet_before, "a block at its ceiling pays nothing")
	assert_eq(block.works_yield_total, ceiling)
	sim.dispose()


func test_no_block_ever_pays_for_its_own_development() -> void:
	# The theorem, over a real run: the recovered total against the block's own
	# six-phase bill, which the ceiling bounds by construction.
	var sim := _sim(9001)
	var run := _develop(sim)
	var block := sim.world.block(String(run["block"]))
	var bill := sim.economy.development_total_cost(String(block.dev_terrain),
			float(sim.world.d_from_center(String(run["block"]))),
			block.arterial_connections,
			float(sim.treasury.difficulty().get("M_dev", 1.0)))
	assert_true(block.works_yield_total > 0, "the block did hand something back")
	assert_true(float(block.works_yield_total) <= float(bill)
			* float(sim.economy.works_yield().get("CEILING_FRACTION", 0.0)) + 0.5,
			"recovered $%d of a $%d bill — at or under the ceiling"
			% [block.works_yield_total, bill])
	sim.dispose()


# ===========================================================================
# 3. The split and the yard (ruling 93 §AZ3)
# ===========================================================================

func test_cash_plus_material_is_the_whole_find() -> void:
	var sim := _sim()
	var run := _develop(sim)
	for entry: Variant in (run["finds"] as Array):
		var find: Dictionary = entry
		assert_eq(int(find["amount"]) + int(find["stockpiled"]), int(find["value"]),
				"%s: cash + yard == value" % String(find["phase"]))
		if String(find["phase"]) == "CLEARING":
			assert_eq(int(find["stockpiled"]), 0,
					"timber is not road base — a clearing find is all cash")
		else:
			assert_true(int(find["stockpiled"]) > 0,
					"%s keeps a share as material" % String(find["phase"]))
	sim.dispose()


func test_a_full_yard_pays_the_remainder_in_cash_and_never_overflows() -> void:
	var sim := _sim()
	var block_id := _purchasable(sim)
	assert_true(bool(sim.cmd_buy_block(block_id, false, false)["ok"]))
	var cap := sim.economy.works_stockpile_cap()
	sim.works_stockpile = cap
	var before := sim.treasury.balance
	sim._credit_land_works(block_id, &"GRADING")
	assert_eq(sim.works_stockpile, cap, "the yard never exceeds its cap")
	var find := {}
	for event: Dictionary in sim.bus.drain():
		if String(event.get("type", "")) == "land_works_find":
			find = event
	assert_false(find.is_empty(), "the find still happened")
	assert_eq(int(find["stockpiled"]), 0, "…and banked nothing, because the yard is full")
	assert_eq(sim.treasury.balance - before, int(find["value"]),
			"nothing is lost: the whole find is paid in cash instead")
	sim.dispose()


func test_the_yard_pays_towards_the_two_phases_the_material_is_for() -> void:
	var sim := _sim()
	var cost := 8000
	var stock := 5000
	assert_eq(sim.economy.works_stockpile_offset("survey", cost, stock), 0,
			"a survey takes no fill")
	assert_eq(sim.economy.works_stockpile_offset("clearing", cost, stock), 0)
	assert_eq(sim.economy.works_stockpile_offset("final_development", cost, stock), 0)
	var quarter := int(round(float(cost)
			* float(sim.economy.works_yield().get("STOCKPILE_MAX_OFFSET_FRACTION", 0.0))))
	assert_eq(sim.economy.works_stockpile_offset("road_install", cost, stock), quarter,
			"a road install takes a quarter of its own invoice and no more")
	assert_eq(sim.economy.works_stockpile_offset("utility_corridor", cost, stock), quarter)
	assert_eq(sim.economy.works_stockpile_offset("road_install", cost, 300), 300,
			"…or whatever is actually standing in the yard, if that is less")
	assert_true(sim.economy.works_stockpile_offset("road_install", cost, 10_000_000) < cost,
			"the yard shortens an invoice; it can never replace one")
	sim.dispose()


func test_a_yard_draw_is_announced_and_the_treasury_only_pays_the_net() -> void:
	var sim := _sim()
	var run := _develop(sim)
	var spends: Array = run["spends"]
	assert_true(spends.size() >= 1,
			"a block that graded before it paved drew on the yard at least once")
	for entry: Variant in spends:
		var spend: Dictionary = entry
		var phase := String(spend["phase"])
		assert_true(phase == "ROAD_INSTALL" or phase == "UTILITY_CORRIDOR",
				"the yard only pays towards the two phases it was dug for: %s" % phase)
		assert_true(int(spend["amount"]) > 0)
		assert_eq(int(spend["gross_cost"]) - int(spend["amount"]),
				_charge_for(run["charges"], phase, int(spend["gross_cost"])),
				"the charge the treasury saw is the gross less the yard draw")
	sim.dispose()


## The `development_phase_charged` amount for one phase of one gross invoice.
func _charge_for(charges: Array, phase: String, gross: int) -> int:
	for entry: Variant in charges:
		var charge: Dictionary = entry
		if String(charge["phase"]) == phase \
				and int(charge["cost"]) + int(charge["stockpile_offset"]) == gross:
			return int(charge["cost"])
	return -1


# ===========================================================================
# 4. Doc 03's line, and the save
# ===========================================================================

func test_the_money_lands_on_the_city_services_line_and_the_lifetime_row() -> void:
	var sim := _sim()
	var block_id := _purchasable(sim)
	assert_true(bool(sim.cmd_buy_block(block_id, false, false)["ok"]))
	var services_before := int(sim.treasury.hour_city_services["excavation"])
	var lifetime_before := int(sim.treasury.lifetime["lifetime_excavation"])
	var tax_before := int(sim.treasury.lifetime["lifetime_tax"])
	sim._credit_land_works(block_id, &"CLEARING")
	var cash := int(sim.treasury.hour_city_services["excavation"]) - services_before
	assert_true(cash > 0, "the find is on doc 03 §2.5's own sub-grain")
	assert_eq(int(sim.treasury.lifetime["lifetime_excavation"]) - lifetime_before, cash,
			"…and counted for life, on its own row")
	assert_eq(int(sim.treasury.lifetime["lifetime_tax"]), tax_before,
			"…and nowhere near the tax row, which is what makes the slider readable")
	sim.dispose()


func test_the_yield_survives_a_save_round_trip() -> void:
	var sim := _sim()
	var run := _develop(sim)
	var block_id := String(run["block"])
	var recovered := sim.world.block(block_id).works_yield_total
	var yard := sim.works_stockpile
	assert_true(recovered > 0)
	var body := sim.canonical_capture()
	assert_true(body.has("works_stockpile"), "the yard is in the body")
	assert_true((body["rng"] as Dictionary).has("land_works"),
			"…and the tenth named stream is (constitution §5)")
	assert_true((body["treasury"]["ledger_totals"] as Dictionary)
			.has("lifetime_excavation"), "…and doc 03 §2.5's own ledger row")
	var restored := CitySim.boot_from_files(1337)
	restored.restore_state(body)
	assert_eq(restored.world.block(block_id).works_yield_total, recovered,
			"the block remembers what it gave up — which is what makes the"
			+ " ceiling survive a reload instead of being paid twice")
	assert_eq(restored.works_stockpile, yard, "and the yard is still standing")
	assert_eq(restored.state_hash(), sim.state_hash())
	sim.dispose()
	restored.dispose()


func test_an_old_save_restores_to_an_empty_yard_and_a_clean_slate() -> void:
	# Doc 08 §2.8's rung 10, exercised: a v9 body has none of the three keys and
	# `_v9_to_v10` invents none of them.
	var sim := _sim()
	var body := sim.canonical_capture()
	body.erase("works_stockpile")
	for entry: Variant in (body["world_blocks"] as Array):
		(entry as Dictionary).erase("works_yield_total")
	var migrated := sim.migrate_save_section(body, 9)
	assert_false(migrated.has("works_stockpile"),
			"v9 → v10 invents no key — restore_state answers this one")
	var restored := CitySim.boot_from_files(1337)
	restored.restore_state(migrated)
	assert_eq(restored.works_stockpile, 0, "an absent yard is an empty yard")
	for id: String in restored.world.block_ids_sorted():
		assert_eq(restored.world.block(id).works_yield_total, 0,
				"…and a block dug out before anyone counted starts fresh")
		break
	sim.dispose()
	restored.dispose()


# ===========================================================================
# 5. The receipt (doc 12 §2.8 D-117)
# ===========================================================================

func test_the_toast_names_the_material_and_splits_the_money() -> void:
	var model := LandWorksModel.load_from_files()
	var cash_only := model.find_feedback({"type": &"land_works_find",
			"block": "B_3_5", "phase": "CLEARING", "material": "timber",
			"value": 540, "amount": 540, "stockpiled": 0, "bonus": false})
	assert_true(cash_only["toast"].contains("Timber"),
			"the material is a word, not an id: %s" % cash_only["toast"])
	assert_true(cash_only["toast"].contains("$540"))
	assert_eq(str(cash_only["flash_chip"]), "treasury")
	assert_eq(str(cash_only["haptic"]), "",
			"no buzz for something the hand had no part in (StreetModel's rule)")
	var split := model.find_feedback({"type": &"land_works_find",
			"block": "B_3_5", "phase": "GRADING", "material": "aggregate",
			"value": 450, "amount": 297, "stockpiled": 153, "bonus": false})
	assert_true(split["toast"].contains("$297") and split["toast"].contains("$153"),
			"a split find says both numbers, or the balance disagrees with the"
			+ " toast: %s" % split["toast"])
	var all_yard := model.find_feedback({"type": &"land_works_find",
			"block": "B_3_5", "phase": "GRADING", "material": "aggregate",
			"value": 200, "amount": 0, "stockpiled": 200, "bonus": false})
	assert_eq(str(all_yard["flash_chip"]), "",
			"the balance chip never pulses for a balance that did not move")
	assert_true(model.find_feedback({"type": &"something_else"}).is_empty())
	assert_eq(model.material_text("copper"), "An abandoned copper main")
	assert_eq(model.phase_text("ROAD_INSTALL"), "Roads",
			"the panel's own copy, not the pipeline's spelling")


func test_a_find_off_the_bus_reaches_the_toast_and_the_chip() -> void:
	# **The DOOR, not the model.** `find_feedback` above proves the sentence is
	# right; this proves the sentence reaches a screen — the same shape
	# `tests/test_ui_street.gd` uses for a bounty, and the difference between a
	# feature and a feature nobody wired.
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	(Engine.get_main_loop() as SceneTree).root.add_child(root)
	root.initialize()
	root.feed_events([{"type": &"land_works_find", "block": "B_3_5",
			"block_id": "B_3_5", "phase": "CLEARING", "material": "timber",
			"value": 540, "amount": 540, "stockpiled": 0, "bonus": false,
			"capped": false, "block_total": 540, "ceiling": 4292, "stockpile": 0}])
	assert_true(root.hud.model.chip_flashing(HudModel.CHIP_TREASURY),
			"the treasury acknowledges the deposit")
	assert_eq(root.toast_view.text(), "Timber — $540")
	assert_true(root.event_log.model.entries().size() > 0,
			"…and the log kept it, so the player can find it an hour later")
	(Engine.get_main_loop() as SceneTree).root.remove_child(root)
	root.free()


func test_a_find_reaches_the_event_log_with_its_block_and_its_dollars() -> void:
	var log_model := EventLogModel.load_from_files()
	log_model.set_clock(9 * 60, 3)
	var row := log_model.feed({"type": &"land_works_find", "block": "B_3_5",
			"block_id": "B_3_5", "phase": "UTILITY_CORRIDOR", "material": "copper",
			"value": 1640, "amount": 1082, "stockpiled": 558, "bonus": true})
	assert_false(row.is_empty(), "doc 03 §2.8b's find has a log row")
	assert_eq(str(row["category"]), "economy")
	assert_true(str(row["title"]).contains("B_3_5"))
	assert_true(str(row["body"]).contains("$1,640"),
			"the log quotes the whole find, cash and material: %s" % str(row["body"]))
	var yard := log_model.feed({"type": &"land_works_stockpile_spent",
			"block": "B_3_5", "block_id": "B_3_5", "phase": "ROAD_INSTALL",
			"amount": 1160, "stockpile": 0, "gross_cost": 7500})
	assert_false(yard.is_empty(),
			"a smaller invoice is findable an hour later, or the ledger lies")
	assert_true(str(yard["title"]).contains("Roads"))
	assert_true(str(yard["body"]).contains("$1,160"))


func test_the_land_panel_publishes_the_band_before_you_buy() -> void:
	var sim := _sim()
	var model := LandPanelModel.new(sim)
	var block_id := _purchasable(sim)
	var view := model.block_view(block_id)
	var works: Dictionary = view["works"]
	var block := sim.world.block(block_id)
	var band := sim.economy.works_yield_band(String(block.dev_terrain),
			float(sim.world.d_from_center(block_id)), block.arterial_connections,
			float(sim.treasury.difficulty().get("M_dev", 1.0)))
	assert_eq(int(works["typical_low"]), int(band["low"]),
			"the panel quotes the economy's own band and restates no fraction")
	assert_eq(int(works["typical_high"]), int(band["high"]))
	assert_true(int(works["typical_low"]) > 0 and
			int(works["typical_high"]) > int(works["typical_low"]))
	var ids: Array[String] = []
	for entry: Variant in (works["rows"] as Array):
		ids.append(str((entry as Dictionary)["id"]))
	assert_eq(str(ids), '["typical"]',
			"land nobody owns shows the band and nothing else — `Recovered $0`"
			+ " is an answer to a question the panel is not asking")
	sim.dispose()


func test_the_land_panel_shows_what_this_block_gave_up_and_what_the_yard_holds() -> void:
	var sim := _sim()
	var run := _develop(sim)
	var model := LandPanelModel.new(sim)
	# A READY block does not open the panel (§2.8's entry rule), so the reading
	# is taken on the block's own record through `works_view` directly.
	var block := sim.world.block(String(run["block"]))
	var works := model.works_view(block,
			float(sim.world.d_from_center(String(run["block"]))),
			float(sim.treasury.difficulty().get("M_dev", 1.0)))
	assert_eq(int(works["recovered"]), block.works_yield_total)
	assert_eq(int(works["yard"]), sim.works_stockpile)
	var ids: Array[String] = []
	for entry: Variant in (works["rows"] as Array):
		ids.append(str((entry as Dictionary)["id"]))
	assert_true(ids.has("recovered"), "an owned block says what it gave up: %s" % str(ids))
	sim.dispose()


func test_a_pending_infrastructure_phase_quotes_the_yard_it_would_draw() -> void:
	var sim := _sim()
	var block_id := _purchasable(sim)
	assert_true(bool(sim.cmd_buy_block(block_id, false, true)["ok"]))
	sim.works_stockpile = 3000
	var view := LandPanelModel.new(sim).block_view(block_id)
	var quoted := 0
	for entry: Variant in (view["phases"] as Array):
		var phase: Dictionary = entry
		var offset := int(phase["stockpile_offset"])
		if String(phase["state"]) != String(LandPanelModel.PHASE_STATE_PENDING):
			assert_eq(offset, 0,
					"a phase that has already been charged never re-quotes a"
					+ " discount the player did not get")
			continue
		if String(phase["id"]) == "ROAD_INSTALL" or String(phase["id"]) == "UTILITY_CORRIDOR":
			assert_true(offset > 0, "%s quotes the yard" % String(phase["id"]))
			assert_eq(int(phase["cost_net"]), int(phase["cost"]) - offset)
			assert_true(str(phase["stockpile_offset_text"]).contains("$"))
			quoted += 1
		else:
			assert_eq(offset, 0, "%s takes no fill" % String(phase["id"]))
	assert_eq(quoted, 2, "both infrastructure phases quote it")
	sim.dispose()
