extends SimTest
## S14's commissions band — doc 12 §2.19 D-90, doc 93 §AQ3, report 98 §60
## RR-170 / RR-173.
##
## **This is the door test.** `tests/test_contracts.gd` holds the board itself;
## everything here is about whether a player can find a commission, read what it
## pays before they agree to it, see how far along they are, and take the money.
##
## The 2026-09-03 report's last sentence is what the band answers: *"any other
## fun ideas to collect money in the game, something to actually DO to collect,
## other than tax revenue."* A verb with no door is this project's signature
## defect, and a verb whose door does not say what it pays is the same defect
## with a button on it.


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _mount(sim: CitySim) -> Dictionary:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	_tree().root.add_child(root)
	root.initialize()
	var cfg: UIConfig = root.config
	var controller := BuildController.new(sim, RequirementFormatter.new(cfg))
	var model := GoalsModel.new(sim, cfg, controller)
	var sheet := root.get_node_or_null("SafeArea/ModalLayer/GoalsSheet") as GoalsSheet
	if sheet != null:
		sheet.setup(cfg, model)
	return {"root": root, "sheet": sheet, "model": model}


func _unmount(mounted: Dictionary) -> void:
	var root: Node = mounted["root"]
	_tree().root.remove_child(root)
	root.free()


## Runs the real board until it posts, so every state below is one the game
## actually reaches rather than a hand-built row.
func _post_one(sim: CitySim) -> Dictionary:
	sim.progression.city_level = 6
	for h in 800:
		sim.contracts.advance(1.0, true)
		if not sim.contracts.offers().is_empty():
			break
	sim.contracts.drain_events()
	sim.bus.drain()
	var offers := sim.contracts.offers()
	return offers[0] if not offers.is_empty() else {}


func _finish(sim: CitySim) -> void:
	var row := sim.contracts.active()
	var rule := ContractBoard.rule_for(StringName(String(row["kind"])))
	var payload: Dictionary = {}
	if String(rule.get("amount", "")) != "":
		payload[String(rule["amount"])] = int(row["target"])
	for i in int(row["target"]):
		sim.bus.emit(StringName(String(rule["event"])), payload)
		if sim.contracts.is_ready():
			return


## The band exists, it is on the sheet a player already opens, and the money is
## on the button rather than only in a sentence.
func test_the_band_names_its_money_on_the_button() -> void:
	var sim := CitySim.boot_from_files(1337)
	var offer := _post_one(sim)
	assert_false(offer.is_empty(), "the board posts something")
	var mounted := _mount(sim)
	var sheet: GoalsSheet = mounted["sheet"]
	sheet.refresh()

	assert_true(sheet.contracts_band().visible, "the band is on the goals sheet")
	var button := sheet.offer_button(int(offer["id"]))
	assert_true(button != null, "the offer has an ACCEPT button of its own")
	assert_false(button.disabled, "and an idle board accepts")
	assert_true(button.text.find(RequirementFormatter.money(int(offer["reward"]))) >= 0,
			("what it pays is on the button's face, not only in a tooltip: %s")
					% button.text)
	_unmount(mounted)
	sim.dispose()


## The primary CLAIM is drawn while the work is unfinished and DISABLED, with the
## money still showing — the build-card pattern (§2.7): the number a player is
## working toward belongs on the control they are working toward.
func test_the_claim_is_drawn_dead_before_it_is_earned() -> void:
	var sim := CitySim.boot_from_files(1337)
	var offer := _post_one(sim)
	assert_true(bool(sim.cmd_accept_contract(int(offer["id"]))["ok"]))
	var mounted := _mount(sim)
	var sheet: GoalsSheet = mounted["sheet"]
	sheet.refresh()

	var claim := sheet.claim_button()
	assert_true(claim.visible, "the CLAIM is on screen from the moment work starts")
	assert_true(claim.disabled, "and dead until the target is met")
	assert_true(claim.text.find(RequirementFormatter.money(int(offer["reward"]))) >= 0,
			"with the price still on its face: %s" % claim.text)

	_finish(sim)
	sheet.refresh()
	assert_false(sheet.claim_button().disabled, "the work done makes it live")
	_unmount(mounted)
	sim.dispose()


## The tap is the money, and the sheet re-reads the city rather than predicting
## what it moved.
func test_the_tap_pays_and_the_band_re_reads() -> void:
	var sim := CitySim.boot_from_files(1337)
	var offer := _post_one(sim)
	assert_true(bool(sim.cmd_accept_contract(int(offer["id"]))["ok"]))
	_finish(sim)
	var mounted := _mount(sim)
	var sheet: GoalsSheet = mounted["sheet"]
	sheet.refresh()
	var before := sim.treasury.balance
	var reward := int(sim.contracts.active()["reward"])

	sheet.request_claim_contract()
	assert_eq(sim.treasury.balance, before + reward, "the tap is the money")
	assert_false(sim.contracts.has_active(), "and the board let go of it")
	_unmount(mounted)
	sim.dispose()


## A second offer while one is in hand is drawn REFUSED with the sim's own
## sentence under it — not hidden, because a player who cannot see the other
## commissions cannot tell that taking this one had a cost.
func test_a_second_offer_is_refused_in_words() -> void:
	var sim := CitySim.boot_from_files(1337)
	sim.progression.city_level = 6
	for h in 800:
		sim.contracts.advance(1.0, true)
		if sim.contracts.offers().size() >= 2:
			break
	sim.contracts.drain_events()
	sim.bus.drain()
	var offers := sim.contracts.offers()
	assert_true(offers.size() >= 2, "the board holds more than one offer")
	assert_true(bool(sim.cmd_accept_contract(int(offers[0]["id"]))["ok"]))

	var mounted := _mount(sim)
	var model: GoalsModel = mounted["model"]
	var view := model.contracts_view()
	var second: Dictionary = {}
	for row_variant: Variant in (view["offers"] as Array):
		if int((row_variant as Dictionary)["id"]) == int(offers[1]["id"]):
			second = row_variant
	assert_false(second.is_empty(), "the other offer is still drawn")
	assert_false(bool(second["ok"]), "and it is refused")
	assert_false(str((second["reason"] as Dictionary).get("body", "")).is_empty(),
			"in a sentence the player can read, not in a code")
	_unmount(mounted)
	sim.dispose()


## **An empty board still draws its header, and says why it is empty.** The
## first draft hid the band when there was nothing on it, which is wrong for this
## project specifically: a player who has never seen the header has no way to
## learn that commissions exist, and a feature nobody can discover is the defect
## doc 91 files over and over as `A91-D-19`.
func test_an_empty_board_still_says_it_is_there() -> void:
	var sim := CitySim.boot_from_files(1337)
	var mounted := _mount(sim)
	var sheet: GoalsSheet = mounted["sheet"]
	var model: GoalsModel = mounted["model"]
	sheet.refresh()
	assert_true(sim.contracts.offers().is_empty(),
			"a freshly booted city has posted nothing yet")
	assert_true(sheet.contracts_band().visible,
			"and the COMMISSIONS header is on screen anyway")
	assert_false(str(model.contracts_view()["note"]).is_empty(),
			"with a sentence under it saying the board is empty")
	_unmount(mounted)
	sim.dispose()
