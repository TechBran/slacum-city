extends SimTest
## Wave 14 — **the tap and the payday** (doc 12 §2.21).
##
## The playtest that opened this wave said the quiet part out loud: "there's not
## a lot of downtime of absolutely nothing to do… these things just pop up
## periodically, so a user scrubbing around their town can actually see them and
## give them money". The sim spawns the things and the renderer draws them; what
## is under test here is everything between a finger landing on one and the
## player believing they got paid.
##
## Four claims, and each one failed a real reading of the game before it was a
## test:
##
##   1. **A finger on a dog catches the dog, not the house behind it.** The pick
##      was decided by tile ownership, and a collectable is a 32 dp sprite
##      standing on a tile a building already owns — so every tap on one opened
##      a building panel.
##   2. **A payday is felt.** `incident_resolved` has carried `reward` since doc
##      06 shipped and nothing has ever sounded it, toasted it or counted it:
##      the automatic dispatch the player asked to be paid for was already
##      paying, silently, which is indistinguishable from not paying.
##   3. **The ledger contains the money.** Bounties are direct treasury credits
##      and never pass `EconomySystem.settle_hour`, so the Economy tab's own NET
##      was short by exactly that much every hour a crew answered a call.
##   4. **The lesson is taught once.** Not a tutorial step — gate 21 counts
##      those, and the number of steps must not depend on what the director
##      happened to spawn.
##
## The sim-side roster (`sim.street.opportunity_near`) and the collect command
## land with the sim agent; every seam to them is exercised here through the two
## injection points `BuildController` exposes for exactly that reason, so this
## file proves the shell half against the contract rather than against a build.


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

## The roster the pick asks, standing in for `sim.street`. One row, one
## question, and a counter — the pick must ask **once** per tap, because it runs
## on a finger.
class FakeRoster extends RefCounted:
	var row: Dictionary = {}
	var calls := 0
	var last_radius := -1.0
	var last_point := Vector3.ZERO

	func opportunity_near(point: Vector3, radius_m: float) -> Dictionary:
		calls += 1
		last_point = point
		last_radius = radius_m
		return row.duplicate()


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _controller(sim: CitySim, roster: FakeRoster = null) -> BuildController:
	var controller := BuildController.new(sim)
	if roster != null:
		controller.street = roster
	return controller


## A point on the first building the starter city has, so "the opportunity won"
## and "the building won" are the same tap.
func _on_a_building(sim: CitySim, controller: BuildController) -> Dictionary:
	var ids := sim.buildings.keys()
	ids.sort()
	var building: Building = sim.buildings[str(ids[0])]
	return {
		"sim_id": str(ids[0]),
		"point": Vector3(float(building.origin.x) * controller.tile_m + 1.0, 0.0,
				float(building.origin.y) * controller.tile_m + 1.0),
	}


func _mount() -> UIRoot:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	_tree().root.add_child(root)
	root.initialize()
	return root


func _unmount(root: UIRoot) -> void:
	_tree().root.remove_child(root)
	root.free()


# ===========================================================================
# 1. The tap — pick priority (doc 12 §2.8's seam, extended)
# ===========================================================================

func test_a_tap_within_the_radius_catches_the_opportunity_not_the_building() -> void:
	var sim := CitySim.boot_from_files()
	var roster := FakeRoster.new()
	var controller := _controller(sim, roster)
	var spot := _on_a_building(sim, controller)
	# The building is still there and still resolvable — that is the whole point
	# of the priority: both answers are available and one of them is leaving.
	assert_eq(controller.sim_id_at_ground(spot["point"] as Vector3), str(spot["sim_id"]),
			"the tap really is on a building")
	roster.row = {"id": "opp_7", "kind": "loose_dog", "reward": 90,
			"world_pos": spot["point"]}
	controller.set_tap_radius_from(0.35)
	var pick := controller.pick_at_ground(spot["point"] as Vector3)
	assert_eq(pick["kind"], BuildController.PICK_OPPORTUNITY,
			"the dog wins the tap it is standing in")
	assert_eq(str(pick["id"]), "opp_7")
	assert_eq(int((pick["opportunity"] as Dictionary)["reward"]), 90,
			"the row rides along, so the shell needs no second query")
	assert_eq(roster.calls, 1, "one roster query per tap")


func test_the_building_still_wins_when_nothing_is_near() -> void:
	var sim := CitySim.boot_from_files()
	var roster := FakeRoster.new()          # answers {} — an empty street
	var controller := _controller(sim, roster)
	var spot := _on_a_building(sim, controller)
	controller.set_tap_radius_from(0.35)
	var pick := controller.pick_at_ground(spot["point"] as Vector3)
	assert_eq(pick["kind"], BuildController.PICK_BUILDING,
			"an empty street changes nothing about the old seam")
	assert_eq(str(pick["id"]), str(spot["sim_id"]))


func test_an_unwired_shell_never_picks_an_opportunity() -> void:
	# `tap_radius_m` is 0 until the shell converts 48 dp at the current zoom. A
	# build that never wires that must pick exactly as it did before — no
	# regression, just no street picks — so the roster is not even asked.
	var sim := CitySim.boot_from_files()
	var roster := FakeRoster.new()
	roster.row = {"id": "opp_1", "reward": 50}
	var controller := _controller(sim, roster)
	var spot := _on_a_building(sim, controller)
	assert_almost_eq(controller.tap_radius_m, 0.0, 0.0001)
	assert_eq(controller.pick_at_ground(spot["point"] as Vector3)["kind"],
			BuildController.PICK_BUILDING)
	assert_eq(roster.calls, 0, "a zero radius is not a query worth making")


func test_the_radius_is_48_dp_of_finger_at_the_current_zoom() -> void:
	var controller := BuildController.new(CitySim.boot_from_files())
	# Two zooms, an order of magnitude apart. A fixed metre radius would be
	# unusable at one end and a magnet at the other, which is the reason this
	# conversion exists at all.
	var close_in := controller.set_tap_radius_from(0.06)
	var far_out := controller.set_tap_radius_from(0.60)
	assert_almost_eq(close_in, 0.06 * BuildController.tap_dp(), 0.0001)
	assert_almost_eq(far_out, 0.60 * BuildController.tap_dp(), 0.0001)
	assert_true(far_out > close_in * 5.0,
			"zooming out widens the world radius, as it must")
	assert_almost_eq(BuildController.tap_dp(), 48.0, 0.0001,
			"data/ui.json.street.tap_dp is §2.1's touch target")


func test_the_roster_is_asked_with_the_point_and_the_radius() -> void:
	var roster := FakeRoster.new()
	var controller := _controller(CitySim.boot_from_files(), roster)
	controller.set_tap_radius_from(0.25)
	var point := Vector3(120.0, 0.0, 240.0)
	controller.pick_at_ground(point)
	assert_eq(roster.last_point, point)
	assert_almost_eq(roster.last_radius, 0.25 * BuildController.tap_dp(), 0.0001)


func test_a_row_beyond_the_radius_is_refused_here() -> void:
	# The roster is expected to filter. One that returns its nearest regardless
	# would otherwise make every tap in the city a collect — and that failure
	# would read as a broken building panel, not as a broken roster.
	var sim := CitySim.boot_from_files()
	var roster := FakeRoster.new()
	var controller := _controller(sim, roster)
	var spot := _on_a_building(sim, controller)
	var point: Vector3 = spot["point"]
	controller.set_tap_radius_from(0.20)          # ~9.6 m
	roster.row = {"id": "opp_far", "reward": 40,
			"world_pos": point + Vector3(400.0, 0.0, 0.0)}
	assert_eq(controller.pick_at_ground(point)["kind"], BuildController.PICK_BUILDING,
			"400 m away is not under the finger")
	# The same row, back inside the radius, is picked.
	roster.row["world_pos"] = point + Vector3(4.0, 0.0, 0.0)
	assert_eq(controller.pick_at_ground(point)["kind"],
			BuildController.PICK_OPPORTUNITY)


func test_an_anonymous_row_is_not_a_pick() -> void:
	# A collectable with no id cannot be handed to a command, so treating it as
	# a pick would eat the tap and open nothing — the worst outcome a pick has.
	var sim := CitySim.boot_from_files()
	var roster := FakeRoster.new()
	roster.row = {"kind": "loose_dog", "reward": 90}
	var controller := _controller(sim, roster)
	var spot := _on_a_building(sim, controller)
	controller.set_tap_radius_from(0.35)
	assert_eq(controller.pick_at_ground(spot["point"] as Vector3)["kind"],
			BuildController.PICK_BUILDING)


func test_a_sim_with_no_street_roster_answers_null_rather_than_raising() -> void:
	# The roster lives in `sim/` and lands with the sim agent. Until it does,
	# `sim.get("street")` is the only thing between a fully wired shell and a
	# crash on every tap: a `CitySim` with no such member must answer null, and
	# the pick must fall straight through to the building. **No injected roster
	# here on purpose** — every other test in this section supplies one, which
	# means every other test in this section skips the line that would break.
	# A CitySim always carries `street` since the Wave-14 integration. Two
	# halves survive of the original premise: a NULL-sim controller (the world
	# every headless UI preview constructs) answers null and refuses cleanly;
	# and a LIVE roster with nothing spawned near the tap still lets the
	# building win, exactly as it always did.
	assert_eq(BuildController.new(null).street_roster(), null,
			"a null sim answers null, never raises")
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim)
	controller.set_tap_radius_from(0.35)
	var spot := _on_a_building(sim, controller)
	assert_eq(controller.pick_at_ground(spot["point"] as Vector3)["kind"],
			BuildController.PICK_BUILDING,
			"a live roster with nothing near picks exactly as it always did")


func test_land_still_answers_a_tap_on_unowned_ground() -> void:
	# The new arm sits in front of S4's; a street with nothing on it must leave
	# doc 12 §2.8 exactly as it was.
	var sim := CitySim.boot_from_files()
	var controller := _controller(sim, FakeRoster.new())
	controller.set_tap_radius_from(0.35)
	for id: Variant in sim.world.block_ids_sorted():
		var block: LandBlock = sim.world.block(String(id))
		if block.ownership_state != &"PURCHASABLE":
			continue
		var tile: Vector2i = block.grid * TileGrid.TILES_PER_BLOCK + Vector2i(3, 3)
		var pick := controller.pick_at_ground(Vector3(
				float(tile.x) * controller.tile_m + 1.0, 0.0,
				float(tile.y) * controller.tile_m + 1.0))
		assert_eq(pick["kind"], BuildController.PICK_BLOCK)
		assert_eq(str(pick["id"]), String(id))
		return
	assert_true(false, "the starter city has a block for sale")


# ===========================================================================
# 2. The collect command
# ===========================================================================

func test_a_build_with_no_collect_verb_refuses_rather_than_crashes() -> void:
	# Same premise shift as the roster test above: the verb exists on every
	# CitySim now, so the verbless world is the null sim.
	var controller := BuildController.new(null)
	var result := controller.collect_opportunity("opp_1")
	assert_false(bool(result["ok"]))
	assert_eq(result["reason_code"], BuildController.E_NO_COMMAND,
			"a sim without the verb is a refusal, never an error")


func test_the_collect_reaches_the_command_with_the_picked_id() -> void:
	var seen: Array[String] = []
	var controller := BuildController.new(CitySim.boot_from_files())
	controller.collect_command = func(id: String) -> Dictionary:
		seen.append(id)
		return {"ok": true, "reason_code": &"", "payload": {"reward": 120}}
	var result := controller.collect_opportunity("opp_9")
	assert_eq(str(seen), str(["opp_9"] as Array[String]))
	assert_true(bool(result["ok"]))
	assert_eq(int((result["payload"] as Dictionary)["reward"]), 120)


func test_an_empty_id_is_never_sent() -> void:
	var calls := [0]
	var controller := BuildController.new(CitySim.boot_from_files())
	controller.collect_command = func(_id: String) -> Dictionary:
		calls[0] += 1
		return {"ok": true}
	assert_false(bool(controller.collect_opportunity("")["ok"]))
	assert_eq(calls[0], 0)


# ===========================================================================
# 3. The payday — what a collect and a bounty should be worth to the senses
# ===========================================================================

func test_a_collect_that_paid_sounds_a_coin_and_pulses_the_treasury() -> void:
	var model := StreetModel.new(_cfg())
	var feedback := model.collect_feedback(
			{"ok": true, "payload": {"reward": 140}}, {"reward": 140})
	assert_true(bool(feedback["ok"]))
	assert_eq(int(feedback["amount"]), 140)
	assert_eq(str(feedback["amount_text"]), "+$140")
	assert_true(bool(feedback["cue"]), "the coin is the whole point")
	assert_eq(str(feedback["flash_chip"]), HudModel.CHIP_TREASURY)
	assert_eq(feedback["haptic"], Haptics.CUE_DISPATCH)


func test_a_collect_reads_the_reward_off_the_pick_when_the_command_is_quiet() -> void:
	var model := StreetModel.new(_cfg())
	var feedback := model.collect_feedback({"ok": true, "payload": {}}, {"reward": 75})
	assert_eq(int(feedback["amount"]), 75,
			"the row the pick resolved already knew what it was worth")


func test_a_missing_collect_verb_says_nothing_at_all() -> void:
	# There is no story to tell a player about a feature that is not there.
	var model := StreetModel.new(_cfg())
	var feedback := model.collect_feedback(
			{"ok": false, "reason_code": BuildController.E_NO_COMMAND})
	assert_eq(str(feedback["toast"]), "")
	assert_false(bool(feedback["cue"]))
	assert_eq(feedback["haptic"], StringName(""))


func test_being_too_late_is_a_sentence_not_a_code() -> void:
	var model := StreetModel.new(_cfg())
	var feedback := model.collect_feedback({"ok": false, "reason_code": &"E_GONE"})
	assert_eq(str(feedback["toast"]), "Gone before you got there.")
	assert_false(bool(feedback["cue"]))
	assert_eq(feedback["haptic"], Haptics.CUE_BLOCKED)


func test_reduce_motion_gets_the_number_as_words() -> void:
	# The floating `+$` is doc 11's and it is motion, so A8 takes it away. The
	# payday must not become silent for an accessibility setting.
	var model := StreetModel.new(_cfg())
	assert_eq(str(model.collect_feedback({"ok": true, "payload": {"reward": 90}})["toast"]),
			"", "with motion on, the float carries the number")
	model.set_reduce_motion(true)
	assert_eq(str(model.collect_feedback({"ok": true, "payload": {"reward": 90}})["toast"]),
			"Collected — +$90")


func test_a_crime_bounty_says_what_the_player_asked_it_to_say() -> void:
	var model := StreetModel.new(_cfg())
	var feedback := model.bounty_feedback({"type": &"incident_resolved",
			"incident_type": "crime", "reward": 120})
	assert_eq(str(feedback["toast"]), "Crime stopped — +$120 bounty")
	assert_true(bool(feedback["cue"]))
	assert_eq(str(feedback["flash_chip"]), HudModel.CHIP_TREASURY)


func test_every_other_call_is_named_the_way_the_drawer_names_it() -> void:
	var model := StreetModel.new(_cfg())
	assert_eq(str(model.bounty_feedback({"incident_type": "structure_fire",
			"reward": 400})["toast"]), "Structure fire cleared — +$400 bounty")
	# An unknown kind is still a payday, and still gets a sentence.
	assert_eq(str(model.bounty_feedback({"incident_type": "sinkhole",
			"reward": 400})["toast"]), "Incident cleared — +$400 bounty")


func test_a_resolve_that_paid_nothing_is_not_a_payday() -> void:
	var model := StreetModel.new(_cfg())
	assert_true(model.bounty_feedback({"incident_type": "crime", "reward": 0}).is_empty(),
			"a self-resolving nuisance must not interrupt anything")


func test_a_trivial_bounty_pays_without_interrupting() -> void:
	var model := StreetModel.new(_cfg())
	var feedback := model.bounty_feedback({"incident_type": "traffic_accident",
			"reward": model.toast_min() - 1})
	assert_eq(str(feedback["toast"]), "",
			"below the floor the money lands and the sentence does not")
	assert_true(bool(feedback["cue"]), "the coin costs no attention")
	assert_eq(str(feedback["flash_chip"]), HudModel.CHIP_TREASURY)
	assert_almost_eq(float(model.live_revenue()[StreetModel.REVENUE_BOUNTIES]),
			float(model.toast_min() - 1), 0.001, "and it is still counted")


# ===========================================================================
# 4. The HUD chip's deposit pulse
# ===========================================================================

func test_the_treasury_chip_pulses_for_a_deposit_and_stops_on_its_own() -> void:
	var model := HudModel.new(_cfg())
	var snapshot := {"treasury": 40000, "net_per_hour": 12.0, "population": 900,
			"stability": 0.8, "incidents": 0}
	assert_false(bool((model.chip_values(snapshot)["treasury"] as Dictionary)["pulse"]),
			"a chip at rest does not pulse")
	model.flash_chip(HudModel.CHIP_TREASURY, 0.9)
	assert_true(bool((model.chip_values(snapshot)["treasury"] as Dictionary)["pulse"]))
	model.advance_flashes(0.5)
	assert_true(model.chip_flashing(HudModel.CHIP_TREASURY), "half way through")
	model.advance_flashes(0.5)
	assert_false(model.chip_flashing(HudModel.CHIP_TREASURY))
	assert_false(bool((model.chip_values(snapshot)["treasury"] as Dictionary)["pulse"]))


func test_a_second_deposit_extends_the_pulse_rather_than_stuttering_it() -> void:
	var model := HudModel.new(_cfg())
	model.flash_chip(HudModel.CHIP_TREASURY, 0.9)
	model.advance_flashes(0.6)
	model.flash_chip(HudModel.CHIP_TREASURY, 0.9)
	model.advance_flashes(0.5)
	assert_true(model.chip_flashing(HudModel.CHIP_TREASURY),
			"four collects in a row read as one continuous arrival")


func test_a_state_pulse_is_never_cancelled_by_a_deposit() -> void:
	var model := HudModel.new(_cfg())
	# A grid below 60 % pulses because of what it IS; the flash is OR'd on top.
	model.service_power01 = 0.2
	var snapshot := {"treasury": 100, "net_per_hour": -20.0, "population": 900,
			"stability": 0.4, "incidents": 0}
	assert_true(bool((model.chip_values(snapshot)["grid"] as Dictionary)["pulse"]))
	model.flash_chip(HudModel.CHIP_TREASURY, 0.9)
	var values := model.chip_values(snapshot)
	assert_true(bool((values["grid"] as Dictionary)["pulse"]))
	assert_true(bool((values["treasury"] as Dictionary)["pulse"]))


# ===========================================================================
# 5. Discovery — one mark, once, ever
# ===========================================================================

func test_the_first_opportunity_ever_raises_the_mark_and_the_second_does_not() -> void:
	var model := StreetModel.new(_cfg())
	var first := model.note_spawn({"type": StreetModel.EVENT_SPAWNED,
			"world_pos": Vector3(96.0, 0.0, 128.0)})
	assert_false(first.is_empty())
	assert_eq(str(first["text"]), "Something's happening on Main St — tap it.")
	assert_true(bool(first["has_pos"]))
	assert_eq(first["world_pos"], Vector3(96.0, 0.0, 128.0))
	assert_true(model.coached)
	assert_true(model.note_spawn({"type": StreetModel.EVENT_SPAWNED}).is_empty(),
			"a lesson taught twice is a lesson nobody trusts")


func test_a_live_tutorial_owes_the_mark_rather_than_eating_it() -> void:
	var model := StreetModel.new(_cfg())
	assert_true(model.note_spawn({"world_pos": Vector3(8.0, 0.0, 8.0)}, true).is_empty(),
			"two teachers must not talk at once")
	assert_false(model.coached)
	assert_true(model.coach_pending)
	var owed := model.take_pending()
	assert_false(owed.is_empty(), "the lesson is worth more late than never")
	assert_eq(owed["world_pos"], Vector3(8.0, 0.0, 8.0),
			"and it still points at the thing that raised it")
	assert_true(model.take_pending().is_empty(), "exactly once, still")


func test_the_one_shot_flag_survives_a_save_and_the_coordinates_do_not() -> void:
	var model := StreetModel.new(_cfg())
	model.note_spawn({"world_pos": Vector3(4.0, 0.0, 4.0)}, true)
	var state := model.capture_state()
	var restored := StreetModel.new(_cfg())
	restored.restore_state(state)
	assert_true(restored.coach_pending)
	var owed := restored.take_pending()
	assert_false(owed.is_empty())
	assert_false(bool(owed["has_pos"]),
			"a mark owed across a reload must not point at a street that emptied")


func test_the_tallies_round_trip_through_the_save() -> void:
	var model := StreetModel.new(_cfg())
	model.bounty_feedback({"incident_type": "crime", "reward": 300})
	model.close_hour()
	model.collect_feedback({"ok": true, "payload": {"reward": 60}})
	var restored := StreetModel.new(_cfg())
	restored.restore_state(model.capture_state())
	assert_almost_eq(float(restored.side_revenue()[StreetModel.REVENUE_BOUNTIES]),
			300.0, 0.001)
	assert_almost_eq(float(restored.live_revenue()[StreetModel.REVENUE_STREET]),
			60.0, 0.001)


# ===========================================================================
# 6. The ledger — the two lines doc 03 does not settle
# ===========================================================================

func _settlement() -> Dictionary:
	return {
		"hour": 41,
		"revenue": {"tax": 5200.0, "power_tariff": 640.0, "gross": 5840.0},
		"expenses": {"building_maint": 2100.0, "total": 2100.0},
		"net": 3740.0,
	}


func test_the_ledger_shows_the_money_the_settle_snapshot_never_carried() -> void:
	var model := BudgetModel.new(_cfg())
	model.feed_settlement(_settlement())
	var before := model.breakdown()
	# Reconciled at the Wave-14 merge: the canonical rows are doc 03's SETTLED
	# `city_services` + `assistance`; the side-tally remains the fallback for a
	# build whose snapshot has not caught up, keyed by the same names.
	model.feed_side_revenue({"city_services": 900.0, "assistance": 150.0})
	var after := model.breakdown()
	var labels: PackedStringArray = []
	for entry: Variant in (after["revenue"] as Array):
		labels.append(str((entry as Dictionary)["label"]))
	assert_true(labels.has("City services"), "the services line: %s" % str(labels))
	assert_true(labels.has("State founding assistance"),
			"the assistance line: %s" % str(labels))
	# A row the column shows but the total does not contain is a ledger that does
	# not add up, which is worse than the line being missing.
	assert_almost_eq(float(after["gross"]) - float(before["gross"]), 1050.0, 0.001)
	assert_almost_eq(float(after["net"]) - float(before["net"]), 1050.0, 0.001)
	assert_almost_eq(float(after["side_revenue"]), 1050.0, 0.001)


func test_the_lines_read_in_the_authored_order_with_the_rest() -> void:
	var model := BudgetModel.new(_cfg())
	model.feed_settlement(_settlement())
	model.feed_side_revenue({"city_services": 900.0, "assistance": 150.0})
	var keys: PackedStringArray = []
	for entry: Variant in (model.breakdown()["revenue"] as Array):
		keys.append(str((entry as Dictionary)["key"]))
	assert_eq(str(keys), str(PackedStringArray(["tax", "power_tariff",
			"city_services", "assistance"])),
			"a side line is a row of the ledger, not a footnote under it")


func test_the_sim_wins_the_moment_doc_03_settles_the_key() -> void:
	# The rule that retires the tally: a key the snapshot carries is taken from
	# the snapshot, always, so the same dollar can never be counted twice.
	var model := BudgetModel.new(_cfg())
	var snapshot := _settlement()
	(snapshot["revenue"] as Dictionary)["bounties"] = 500.0
	model.feed_settlement(snapshot)
	model.feed_side_revenue({"bounties": 900.0})
	var ledger := model.breakdown()
	for entry: Variant in (ledger["revenue"] as Array):
		var row: Dictionary = entry
		if str(row["key"]) == "bounties":
			assert_almost_eq(float(row["amount"]), 500.0, 0.001,
					"doc 03's number, not the UI's guess")
			assert_true(bool(row["settled"]))
	assert_almost_eq(float(ledger["side_revenue"]), 0.0, 0.001)
	assert_almost_eq(float(ledger["net"]), 3740.0, 0.001, "and the net does not move")


func test_a_ledger_with_no_side_revenue_is_the_ledger_it_always_was() -> void:
	var model := BudgetModel.new(_cfg())
	model.feed_settlement(_settlement())
	var ledger := model.breakdown()
	assert_almost_eq(float(ledger["gross"]), 5840.0, 0.001)
	assert_almost_eq(float(ledger["net"]), 3740.0, 0.001)
	assert_eq((ledger["revenue"] as Array).size(), 2, "zero lines are still dropped")


func test_the_tally_window_is_the_hour_the_ledger_is_showing() -> void:
	# "Revenue, last settled hour" must not contain a bounty paid four minutes
	# ago, in the hour that is still running.
	var model := StreetModel.new(_cfg())
	model.bounty_feedback({"incident_type": "crime", "reward": 200})
	assert_almost_eq(float(model.side_revenue()[StreetModel.REVENUE_BOUNTIES]), 0.0,
			0.001, "nothing has settled yet")
	model.close_hour()
	assert_almost_eq(float(model.side_revenue()[StreetModel.REVENUE_BOUNTIES]), 200.0,
			0.001)
	assert_almost_eq(float(model.live_revenue()[StreetModel.REVENUE_BOUNTIES]), 0.0,
			0.001, "and the new hour starts empty")


# ===========================================================================
# 7. The cue mapping (doc 11 §2.15's table, not a new mechanism)
# ===========================================================================

func _cues(model: AudioEvents) -> PackedStringArray:
	var out: PackedStringArray = []
	for cue: Dictionary in model.update(1.0 / 60.0, Vector3.ZERO, 0.0):
		out.append(str(cue["cue"]))
	return out


func test_the_shells_synthetic_cash_cue_reaches_the_coin() -> void:
	var model := AudioEvents.new(AudioConfig.load_from_files())
	model.feed({"type": AudioService.UI_CASH})
	assert_eq(_cues(model), PackedStringArray(["cash"]))


func test_a_resolved_incident_with_a_reward_sounds_the_same_coin() -> void:
	# This is the bounty half, and it needs no shell change at all: the payload
	# has carried `reward` since doc 06 shipped.
	var model := AudioEvents.new(AudioConfig.load_from_files())
	model.feed({"type": "incident_resolved", "incident_id": 4,
			"incident_type": "crime", "reward": 120})
	assert_eq(_cues(model), PackedStringArray(["cash"]))


func test_a_resolve_that_paid_nothing_makes_no_sound() -> void:
	var model := AudioEvents.new(AudioConfig.load_from_files())
	assert_true(model.feed({"type": "incident_resolved", "incident_id": 4,
			"reward": 0}).is_empty(), "no money, no coin")
	assert_eq(model.pending_count(), 0)


func test_two_paydays_inside_the_cooldown_are_one_coin() -> void:
	# The collect's command lands a tick after the tap, so the two doors can
	# arrive within a frame of each other; the shared identity is what stops a
	# double strike, and what keeps a sweep of four pickups countable.
	var model := AudioEvents.new(AudioConfig.load_from_files())
	model.feed({"type": AudioService.UI_CASH})
	model.feed({"type": "incident_resolved", "incident_id": 9, "reward": 300})
	assert_eq(_cues(model), PackedStringArray(["cash"]))


func test_the_coin_is_feedback_and_never_fades_with_distance() -> void:
	var cfg := AudioConfig.load_from_files()
	assert_eq(str(cfg.cue("cash").get("bus", "")), "UI",
			"the UI bus: a payday must not duck under the city bed")
	var model := AudioEvents.new(cfg)
	model.feed({"type": AudioService.UI_CASH})
	# 3 km from the listener, which would drop any positional cue outright.
	assert_eq(_cues(model), PackedStringArray(["cash"]))


func test_the_coin_is_a_real_asset_in_the_budget() -> void:
	var manifest: Dictionary = StarterCityLoader.read_json(
			"res://game/audio/generated/manifest.json")
	var found := {}
	for entry: Variant in (manifest.get("assets", []) as Array):
		var row: Dictionary = entry
		if str(row["name"]) == "cash":
			found = row
	assert_false(found.is_empty(), "run tools/gen_audio.py")
	assert_true(float(found["peak"]) > 0.05, "not a silent asset")
	assert_true(float(found["seconds"]) < 0.7,
			"a payday is faster than a purchase, on purpose")
	assert_true(int(manifest["total_bytes"]) <= int(manifest["budget_bytes"]),
			"still inside the 4.5 MiB budget with the coin in it")


# ===========================================================================
# 8. The scaffold — the four surfaces, wired
# ===========================================================================

func test_a_bounty_off_the_bus_reaches_the_toast_and_the_chip() -> void:
	var root := _mount()
	root.feed_events([{"type": &"incident_resolved", "incident_id": 3,
			"incident_type": "crime", "reward": 120, "tier_peak": 2, "at_h": 4.0}])
	assert_true(root.hud.model.chip_flashing(HudModel.CHIP_TREASURY),
			"the treasury acknowledges the deposit")
	assert_eq(root.toast_view.text(), "Crime stopped — +$120 bounty")
	assert_almost_eq(float(root.street.live_revenue()[StreetModel.REVENUE_BOUNTIES]),
			120.0, 0.001)
	_unmount(root)


func test_the_hour_boundary_hands_the_ledger_its_two_lines() -> void:
	var root := _mount()
	root.feed_events([
		{"type": &"incident_resolved", "incident_id": 3, "incident_type": "crime",
				"reward": 500},
		{"type": &"economy_hour_settled", "hour": 12, "gross": 10.0, "expense": 4.0,
				"net": 6.0},
	])
	assert_almost_eq(float(root.city_dashboard.model.budget.side_revenue()["bounties"]),
			500.0, 0.001, "the closed hour reached the Economy tab")
	_unmount(root)


func test_the_first_spawn_raises_the_mark_once() -> void:
	var root := _mount()
	root.feed_events([{"type": &"opportunity_spawned", "id": "opp_1",
			"world_pos": Vector3(64.0, 0.0, 64.0)}])
	assert_true(root.onboarding.notice_active(), "the player is told, once")
	assert_true(root.onboarding.mark().is_showing())
	root.onboarding.dismiss_notice()
	root.feed_events([{"type": &"opportunity_spawned", "id": "opp_2"}])
	assert_false(root.onboarding.notice_active(), "and never again")
	_unmount(root)


func test_the_mark_is_not_a_tutorial_step() -> void:
	# Gate 21 counts the curriculum. A mark raised by whatever the director
	# happened to spawn must not change that count, and must not gate anything.
	var root := _mount()
	var steps := root.onboarding.model.step_count()
	root.feed_events([{"type": &"opportunity_spawned", "id": "opp_1"}])
	assert_eq(root.onboarding.model.step_count(), steps)
	assert_false(root.onboarding.is_active(), "the step machine never started")
	assert_eq(root.onboarding.mark().mouse_filter, Control.MOUSE_FILTER_IGNORE,
			"a soft mark claims no touch outside its own bubble")
	_unmount(root)


func test_collecting_the_thing_takes_the_mark_down() -> void:
	var root := _mount()
	root.feed_events([{"type": &"opportunity_spawned", "id": "opp_1"}])
	assert_true(root.onboarding.notice_active())
	var feedback := root.report_collect({"ok": true, "payload": {"reward": 90}},
			{"reward": 90})
	assert_true(bool(feedback["cue"]), "the shell is told to sound the coin")
	assert_false(root.onboarding.notice_active(),
			"the player did the thing; the sentence has done its work")
	assert_true(root.hud.model.chip_flashing(HudModel.CHIP_TREASURY))
	_unmount(root)


func test_a_refused_collect_says_so_and_sounds_nothing() -> void:
	var root := _mount()
	var feedback := root.report_collect({"ok": false, "reason_code": &"E_GONE"})
	assert_false(bool(feedback["cue"]))
	assert_eq(root.toast_view.text(), "Gone before you got there.")
	_unmount(root)


func test_the_ui_save_section_carries_the_one_shot_flag() -> void:
	var root := _mount()
	root.feed_events([{"type": &"opportunity_spawned", "id": "opp_1"}])
	var state := root.capture_ui_state()
	assert_true((state["street"] as Dictionary)["coached"] as bool)
	var second := _mount()
	second.restore_ui_state(state)
	second.feed_events([{"type": &"opportunity_spawned", "id": "opp_2"}])
	assert_false(second.onboarding.notice_active(),
			"a reload does not re-teach a lesson")
	_unmount(second)
	_unmount(root)
