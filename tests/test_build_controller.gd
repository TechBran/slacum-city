extends SimTest
## P1-33/P1-34's headless half: `BuildController` — the build sheet's card list,
## the placement state machine and its preflight verdicts, and the building
## panel's view model with the doc 12 §2.9 upgrade checklist.
##
## Every verdict is asserted against a **real `CitySim`**, because the whole
## point of the preflight is that it agrees with `cmd_place_building`: the same
## checks, the same order, the same answer, without charging the treasury.


func _sim() -> CitySim:
	return CitySim.boot_from_files()


func _controller(sim: CitySim) -> BuildController:
	return BuildController.new(sim, RequirementFormatter.load_from_files())


static func _serviceable_vacant_tile(sim: CitySim, size: Vector2i = Vector2i.ONE) -> Vector2i:
	for z in range(32, 80):
		for x in range(32, 80):
			var origin := Vector2i(x, z)
			if sim.world.grid.can_place(origin, size) and sim.grid.would_serve(origin):
				return origin
	return Vector2i(-1, -1)


# ===========================================================================
# Build sheet cards (doc 12 §2.7)
# ===========================================================================

func test_card_list_covers_the_twelve_archetypes() -> void:
	# Doc 12 §2.17's tutorial needs the answer to `E_UNSERVED` on the same sheet,
	# so the list is the twelve buildings PLUS doc 04 §2.1's placeable grid
	# roster — and, from Wave 5, doc 05 §6's placeable WATER roster beside it, on
	# one `infrastructure` tab. `component_domain` is what tells the three apart,
	# and which command a card's tap ends up in.
	var sim := _sim()
	var controller := _controller(sim)
	var cards := controller.cards()
	assert_eq(cards.size(), BuildingCatalog.ARCHETYPE_COUNT
			+ controller.grid_kinds().size() + controller.water_kinds().size(),
			"spec §43.2 MVP roster + doc 04's and doc 05's placeable components")
	var seen: Array[String] = []
	var buildings := 0
	var m_build := float(sim.treasury.difficulty().get("M_build", 1.0))
	for card: Dictionary in cards:
		assert_false(seen.has(str(card["id"])), "one card per id")
		seen.append(str(card["id"]))
		assert_true(int(card["cost"]) > 0, "%s quotes a build cost" % card["id"])
		match str(card["component_domain"]):
			"":
				buildings += 1
				assert_eq(int(card["cost"]),
						sim.econ_curves.build_cost(str(card["archetype"])),
						"cost is read from the economy table, never authored in the UI")
			BuildController.DOMAIN_GRID:
				assert_eq(int(card["cost"]), sim.econ_curves.grid_build_cost(
						str(card["component_kind"]), int(card["level"]), m_build),
						"and a grid component's comes from the same table, §2.13(b)")
			BuildController.DOMAIN_WATER:
				var kind := str(card["component_kind"])
				assert_eq(int(card["cost"]), sim.econ_curves.water_component_build_cost(
						sim.water.data.variant_cost_ratio(StringName(kind),
								str(controller.water_rules(kind).get("subtype", ""))),
						int(card["level"]), m_build),
						"and a water component's off doc 03 §8 water, C-07 unbroken")
		assert_true((card["footprint"] as Vector2i).x >= 1)
		assert_true(str(card["name_key"]).begins_with("ui_build_card_"), "G-8 key")
		assert_eq(str(card["category"]) == BuildController.CATEGORY_INFRASTRUCTURE,
				str(card["component_domain"]) != "",
				"every component sits on the infrastructure tab and nothing else does")
	assert_eq(buildings, BuildingCatalog.ARCHETYPE_COUNT)
	assert_true(seen.has("house") and seen.has("water_facility"))
	assert_true(seen.has("transformer"), "the card that answers E_UNSERVED")
	assert_true(seen.has("water_facility_pump"), "and the one that answers E_NO_MAIN")


func test_card_names_and_tabs_resolve_from_the_string_table() -> void:
	var sim := _sim()
	var cfg := UIConfig.load_from_files()
	for card: Dictionary in _controller(sim).cards():
		assert_true(cfg.has_string(str(card["name_key"])),
				"data/strings.en.json carries %s" % card["name_key"])
		assert_true(cfg.has_string(BuildController.category_tab_key(str(card["category"]))),
				"the %s tab has a label" % card["category"])


func test_cards_lock_on_min_city_level_but_stay_listed() -> void:
	# §2.7: "locked cards show a lock glyph and reveal the unlock condition on
	# tap" — they are never dropped from the sheet.
	var sim := _sim()
	var controller := _controller(sim)
	sim.progression.city_level = 0
	var locked_at_zero := 0
	for card: Dictionary in controller.cards():
		if bool(card["locked"]):
			locked_at_zero += 1
			assert_true(int(card["min_city_level"]) > 0)
	assert_true(locked_at_zero > 0, "the tall archetypes start locked")
	sim.progression.city_level = 5
	for card: Dictionary in controller.cards():
		assert_false(bool(card["locked"]), "%s unlocks at level 5" % card["archetype"])


func test_unaffordable_cards_are_not_locked() -> void:
	# An unaffordable card stays tappable so the requirement panel can explain
	# why (§2.7); only `min_city_level` locks.
	var sim := _sim()
	sim.progression.city_level = 5
	sim.treasury.spend(sim.treasury.balance, &"test_drain")
	for card: Dictionary in _controller(sim).cards():
		assert_false(bool(card["locked"]))
		assert_false(bool(card["affordable"]))


# ===========================================================================
# Placement state machine (doc 12 §2.2 S2 → S3)
# ===========================================================================

func test_enter_move_confirm_cancel_transitions() -> void:
	var sim := _sim()
	var controller := _controller(sim)
	assert_eq(controller.state, BuildController.STATE_IDLE)
	assert_false(controller.is_placing())
	assert_false(bool(controller.confirm()["ok"]), "confirm from IDLE is refused")

	assert_true(bool(controller.enter("house")["ok"]))
	assert_eq(controller.state, BuildController.STATE_PLACING)
	assert_eq(controller.size, Vector2i.ONE, "house footprint from the catalog")
	assert_false(controller.has_origin, "no ghost until the finger lands")
	assert_false(bool(controller.ghost()["visible"]))
	assert_false(bool(controller.confirm()["ok"]), "confirm before a target is refused")

	var origin := _serviceable_vacant_tile(sim)
	assert_true(origin.x >= 0, "the core has serviceable vacant lots")
	controller.move_to_tile(origin)
	assert_true(controller.has_origin)
	assert_true(controller.can_confirm())

	controller.cancel()
	assert_eq(controller.state, BuildController.STATE_IDLE)
	assert_eq(controller.archetype, "")
	assert_false(controller.has_origin)
	assert_false(bool(controller.ghost()["visible"]))
	assert_true(controller.verdict().is_empty(), "cancel leaves no stale verdict")
	# Cancel is idempotent — the Android back stack calls it blind.
	controller.cancel()
	assert_eq(controller.state, BuildController.STATE_IDLE)


func test_enter_refuses_unknown_and_locked_archetypes() -> void:
	var sim := _sim()
	var controller := _controller(sim)
	var unknown := controller.enter("stadium")
	assert_false(bool(unknown["ok"]))
	assert_eq(unknown["reason_code"], &"E_UNKNOWN_ARCHETYPE")
	assert_eq(controller.state, BuildController.STATE_IDLE)

	sim.progression.city_level = 0
	var locked := controller.enter("data_center")  # min_city_level 4
	assert_false(bool(locked["ok"]))
	assert_eq(locked["reason_code"], &"E_CITY_LEVEL")
	assert_eq(int(locked["payload"]["required_level"]), 4)
	assert_eq(controller.state, BuildController.STATE_IDLE, "a locked card never places")

	sim.progression.city_level = 4
	assert_true(bool(controller.enter("data_center")["ok"]), "unlocked at city level 4")


# ===========================================================================
# Validity (the preflight must agree with `cmd_place_building`)
# ===========================================================================

func test_valid_lot_reads_valid_and_charges_nothing() -> void:
	var sim := _sim()
	var controller := _controller(sim)
	var balance := sim.treasury.balance
	var buildings := sim.buildings.size()
	controller.enter("house")
	var verdict := controller.move_to_tile(_serviceable_vacant_tile(sim))
	assert_eq(str(verdict["verdict"]), String(BuildController.VERDICT_VALID))
	assert_true((verdict["failure"] as Dictionary).is_empty())
	assert_eq(str(controller.ghost()["state"]), String(HudModel.STATE_NORMAL))
	assert_eq(sim.treasury.balance, balance, "the preflight never charges")
	assert_eq(sim.buildings.size(), buildings, "and never stamps a tile")


func test_unowned_block_is_blocked() -> void:
	var sim := _sim()
	var controller := _controller(sim)
	controller.enter("house")
	var verdict := controller.move_to_tile(Vector2i(8, 8))  # undeveloped ring
	assert_eq(str(verdict["verdict"]), String(BuildController.VERDICT_BLOCKED))
	assert_eq(verdict["code"], &"E_NOT_OWNED")
	assert_false(controller.can_confirm())
	assert_eq(str(controller.ghost()["state"]), String(HudModel.STATE_CRITICAL))
	assert_true(str(verdict["failure"]["body"]).length() > 0, "the bar says why in words")
	# The command agrees.
	assert_eq(sim.cmd_place_building("house", Vector2i(8, 8))["reason_code"], &"E_NOT_OWNED")


func test_occupied_tile_is_blocked() -> void:
	var sim := _sim()
	var controller := _controller(sim)
	var occupied: Vector2i = (sim.buildings["H-001"] as Building).origin
	controller.enter("house")
	var verdict := controller.move_to_tile(occupied)
	assert_eq(verdict["code"], &"E_FOOTPRINT")
	assert_eq(sim.cmd_place_building("house", occupied)["reason_code"], &"E_FOOTPRINT")


func test_unserved_lot_is_blocked() -> void:
	# The tutorial lot sits 4 tiles from an L1 transformer (radius 3) — doc 04
	# §2.1 blocks it, and the ghost must say so before the player commits.
	var sim := _sim()
	var controller := _controller(sim)
	var lot: Vector2i = sim.loader.resolve_tag("tutorial_lot_a")["tile_global"]
	controller.enter("house")
	var verdict := controller.move_to_tile(lot)
	assert_eq(verdict["code"], &"E_UNSERVED")
	assert_eq(sim.cmd_place_building("house", lot)["reason_code"], &"E_UNSERVED")


func test_poor_treasury_is_blocked_with_the_numbers() -> void:
	var sim := _sim()
	var controller := _controller(sim)
	var origin := _serviceable_vacant_tile(sim)
	sim.treasury.spend(sim.treasury.balance - 100, &"test_drain")
	controller.enter("house")
	var verdict := controller.move_to_tile(origin)
	assert_eq(verdict["code"], &"E_FUNDS")
	var failure: Dictionary = verdict["failure"]
	assert_eq(str(failure["args"]["have"]), HudModel.money(100))
	assert_eq(str(failure["args"]["need"]),
			HudModel.money(sim.econ_curves.build_cost("house")))
	assert_eq(sim.cmd_place_building("house", origin)["reason_code"], &"E_FUNDS")


func test_verdict_recomputes_on_every_move() -> void:
	var sim := _sim()
	var controller := _controller(sim)
	controller.enter("house")
	assert_eq(controller.move_to_tile(Vector2i(8, 8))["code"], &"E_NOT_OWNED")
	assert_eq(str(controller.move_to_tile(_serviceable_vacant_tile(sim))["verdict"]),
			String(BuildController.VERDICT_VALID))
	assert_eq(controller.move_to_tile((sim.buildings["H-001"] as Building).origin)["code"],
			&"E_FOOTPRINT")


# ===========================================================================
# Confirm / commit
# ===========================================================================

func test_confirm_returns_the_command_arguments() -> void:
	var sim := _sim()
	var controller := _controller(sim)
	var origin := _serviceable_vacant_tile(sim)
	controller.enter("house")
	controller.move_to_tile(origin)
	var args := controller.confirm()
	assert_true(bool(args["ok"]))
	assert_eq(str(args["payload"]["archetype"]), "house")
	assert_eq(args["payload"]["origin"], origin)
	assert_eq(str(args["payload"]["variant"]), "")
	assert_eq(int(args["payload"]["cost"]), sim.econ_curves.build_cost("house"))
	# Those exact arguments satisfy the real command.
	var placed := sim.cmd_place_building(str(args["payload"]["archetype"]),
			args["payload"]["origin"], str(args["payload"]["variant"]))
	assert_true(bool(placed["ok"]), str(placed))


func test_confirm_is_refused_while_blocked() -> void:
	var sim := _sim()
	var controller := _controller(sim)
	controller.enter("house")
	controller.move_to_tile(Vector2i(8, 8))
	var args := controller.confirm()
	assert_false(bool(args["ok"]))
	assert_eq(args["reason_code"], &"E_NOT_OWNED")


func test_commit_places_and_leaves_placement_mode() -> void:
	var sim := _sim()
	var controller := _controller(sim)
	var origin := _serviceable_vacant_tile(sim)
	var balance := sim.treasury.balance
	controller.enter("house")
	controller.move_to_tile(origin)
	var result := controller.commit()
	assert_true(bool(result["ok"]), str(result))
	assert_eq(sim.treasury.balance, balance - int(result["payload"]["cost"]))
	assert_eq(controller.state, BuildController.STATE_IDLE, "the sheet closes on success")
	assert_true(sim.buildings.has(str(result["payload"]["sim_id"])))
	# A second commit on the same spot is refused by the sim, not by a stale ghost.
	controller.enter("house")
	controller.move_to_tile(origin)
	assert_eq(controller.verdict()["code"], &"E_FOOTPRINT")
	assert_false(bool(controller.commit()["ok"]))
	assert_eq(controller.state, BuildController.STATE_PLACING, "a refusal keeps the ghost")


# ===========================================================================
# Ghost geometry
# ===========================================================================

func test_ghost_centres_the_footprint_on_the_pointed_tile() -> void:
	var sim := _sim()
	var controller := _controller(sim)
	sim.progression.city_level = 5
	controller.enter("power_facility")  # 3×3
	assert_eq(controller.size, Vector2i(3, 3))
	assert_eq(controller.centre_offset(), Vector2i(1, 1))
	var point := Vector3(40 * 8.0 + 4.0, 0.0, 44 * 8.0 + 4.0)
	controller.move_to_ground(point)
	assert_eq(controller.origin, Vector2i(39, 43), "a 3×3 ghost centres on the finger")
	var ghost := controller.ghost()
	assert_true(bool(ghost["visible"]))
	assert_eq(ghost["centre"] as Vector3,
			Vector3(39 * 8.0 + 12.0, 0.0, 43 * 8.0 + 12.0))
	assert_eq(BuildController.tile_at(Vector3(0.5, 0.0, 8.5), 8.0), Vector2i(0, 1))
	# 1×1 lands exactly under the finger.
	controller.enter("house")
	controller.move_to_ground(point)
	assert_eq(controller.origin, Vector2i(40, 44))


# ===========================================================================
# Picking (doc 12 §2.16 tap → panel)
# ===========================================================================

func test_tile_and_ground_picking_resolve_a_sim_id() -> void:
	var sim := _sim()
	var controller := _controller(sim)
	var b: Building = sim.buildings["H-001"]
	assert_eq(controller.sim_id_at_tile(b.origin), "H-001")
	assert_eq(controller.sim_id_at_ground(
			Vector3(b.origin.x * 8.0 + 4.0, 0.0, b.origin.y * 8.0 + 4.0)), "H-001")
	assert_eq(controller.sim_id_at_tile(_serviceable_vacant_tile(sim)), "",
			"empty ground selects nothing")
	assert_eq(controller.sim_id_at_tile(Vector2i(-5, -5)), "", "out of bounds is safe")


# ===========================================================================
# Building panel view model (doc 12 §2.9)
# ===========================================================================

func test_building_view_reports_live_stats() -> void:
	var sim := _sim()
	sim.advance_hours(1.0)
	var view := _controller(sim).building_view("H-001")
	assert_true(bool(view["exists"]))
	assert_eq(str(view["archetype"]), "house")
	assert_eq(int(view["max_level"]), 6,
			"a house carries doc 02 §2.14's sixth rung")
	# And an archetype that does NOT is not offered one.
	var station := _controller(sim).building_view("F-001")
	if bool(station.get("exists", false)):
		assert_eq(int(station["max_level"]), 5,
				"the fire station's ladder still stops at five")
	assert_eq((view["vitals"] as Array).size(), 6, "§2.9's 2×3 vitals grid")
	assert_eq((view["coverage"] as Array).size(), 4, "Power/Water/Police/Fire tiles")
	var power_tile: Dictionary = (view["coverage"] as Array)[0]
	assert_eq(str(power_tile["id"]), "power")
	assert_ne(str(power_tile["state"]), String(HudModel.STATE_OFFLINE),
			"the starter house is fed")
	assert_true(str(power_tile["attachment"]).length() > 0, "names its transformer")
	# PA-22: all four tiles are live. The three that are not power were hard-wired
	# to `✕ —` for eleven waves while the sim published every one of them, so
	# these assert the FOUNDING CITY's own numbers rather than the stale state.
	var by_slot: Dictionary = {}
	for tile: Dictionary in (view["coverage"] as Array):
		by_slot[str(tile["id"])] = tile
	# H-001 sits in `WTR-1-PMP` at doc 05's nominal 0.60, so the water tile reads
	# 60 % and NORMAL — the reading the pump station's own tile used to deny.
	var water_tile: Dictionary = by_slot["water"]
	assert_eq(str(water_tile["value"]),
			RequirementFormatter.percent(sim.water.pressure_at(
					sim.water.demand.access_tile("H-001"))))
	assert_eq(str(water_tile["state"]), String(HudModel.STATE_NORMAL))
	assert_eq(str(water_tile["zone"]), "WTR-1-PMP", "the tile names its zone")
	# H-001 is 32 tiles from POL-1 and 29 from FIRE-1, both outside an L1 radius:
	# OFFLINE with the real 0 %, and a reason that says no station reaches it.
	for slot: String in ["police", "fire"]:
		var tile: Dictionary = by_slot[slot]
		assert_eq(str(tile["state"]), String(HudModel.STATE_OFFLINE), slot)
		assert_eq(str(tile["reason_key"]), "ui_building_coverage_reason_none", slot)
	# …and the station's own lot is covered, which is what makes the tile a
	# teaching surface rather than a decoration.
	var at_station := _controller(sim).building_view("POL-1")
	for tile: Dictionary in (at_station["coverage"] as Array):
		if str(tile["id"]) != "police":
			continue
		assert_eq(str(tile["state"]), String(HudModel.STATE_NORMAL),
				"POL-1 covers its own lot")
		assert_eq(str(tile["station"]), "POL-1", "and the row names the station")
		assert_ne(str(tile["value"]), HudModel.NO_DATA)
	assert_eq(str(view["state_key"]), "ui_building_state_active")
	assert_false(view["condition_text"] == "")


func test_building_view_of_a_missing_building_is_safe() -> void:
	var view := _controller(_sim()).building_view("NOPE-999")
	assert_false(bool(view["exists"]))


func test_upgrade_checklist_shows_every_check_passing() -> void:
	var sim := _sim()
	sim.advance_hours(1.0)
	sim.progression.city_level = 1
	var view := _controller(sim).building_view("H-001")
	var upgrade: Dictionary = view["upgrade"]
	assert_true(bool(upgrade["ok"]), str(upgrade["checklist"]))
	assert_eq(int(upgrade["to_level"]), 2)
	assert_eq(int(upgrade["cost"]), sim.econ_curves.upgrade_cost("house", 1))
	var rows: Array = upgrade["checklist"]
	# Seven: the six that always ran plus `E_WATER_HEADROOM` (PA-24), which
	# `cmd_upgrade_building` has appended since doc 05's zones landed and this
	# checklist never listed. `E_AVENUE` is still absent below Level 4 (C-62).
	assert_eq(rows.size(), 7, "E_AVENUE is not a check below Level 4 (C-62)")
	for row: Dictionary in rows:
		assert_true(bool(row["ok"]))
		assert_eq(str(row["glyph"]), RequirementFormatter.GLYPH_PASS)
		assert_true(str(row["body"]).length() > 0, "a passing row still explains itself")
	assert_true((upgrade["blocked_by"] as Dictionary).is_empty())


## PA-24's gate. `E_WATER_HEADROOM` reached the player as nothing at all for
## eleven waves — no checklist row, no copy, and "Every requirement met." printed
## over six green ticks while `UPGRADE` stayed dead — because `UPGRADE_CHECKS`
## was hand-maintained beside a command that had grown a seventh gate. This reads
## the command's own source and refuses any code it can append that the panel
## cannot draw or the formatter cannot explain, so the next gate doc 02 grows
## cannot ship silent the way this one did.
func test_every_upgrade_blocker_the_command_raises_has_a_row_and_copy() -> void:
	var source := FileAccess.get_file_as_string("res://sim/city_sim.gd")
	assert_true(source.length() > 0, "city_sim.gd is readable")
	var start := source.find("func cmd_upgrade_building(")
	assert_true(start > 0, "found the command")
	var stop := source.find("\nfunc ", start + 1)
	var body := source.substr(start, stop - start)
	var codes: Array[String] = []
	for line: String in body.split("\n"):
		var trimmed := line.strip_edges()
		if not trimmed.begins_with("blockers.append(&\""):
			continue
		var code := trimmed.substr(18)
		code = code.substr(0, code.find("\""))
		if not codes.has(code):
			codes.append(code)
	assert_true(codes.size() >= 7,
			"doc 02 §2.11's gate raises at least seven codes, found %d" % codes.size())
	var cfg := UIConfig.load_from_files()
	for code: String in codes:
		assert_true(BuildController.UPGRADE_CHECKS.has(StringName(code)),
				"%s is a blocker `cmd_upgrade_building` appends and the checklist \
never draws" % code)
		assert_true(RequirementFormatter.is_known(code),
				"%s folds to UNKNOWN and prints its own code at the player" % code)
		assert_true(cfg.has_string(RequirementFormatter.string_key(code)),
				"%s has no body copy" % code)
		assert_true(cfg.has_string(RequirementFormatter.string_key(code, "_title")),
				"%s has no title copy" % code)


## PA-12. The panel quoted the RAW kW delta while `cmd_upgrade_building` asked
## doc 04 for `delta × headroom_safety.power`, so a player who bought exactly the
## quoted capacity was refused again with a smaller deficit — the user's
## "transformers do not visibly add capacity", from the panel's side.
func test_power_headroom_row_quotes_the_margin_the_gate_applies() -> void:
	var sim := _sim()
	sim.advance_hours(1.0)
	var controller := _controller(sim)
	var margin := controller.headroom_margin()
	assert_eq(margin, float((sim.catalog.rules()["headroom_safety"]
			as Dictionary)["power"]), "read from doc 02 §8, not authored in ui/")
	var b: Building = sim.buildings["H-001"]
	var next_stats: Dictionary = sim.catalog.stats(String(b.archetype), b.level + 1)
	var delta_kw := float(next_stats.get("power_demand_kw", 0.0)) \
			- float(b.stats.get("power_demand_kw", 0.0))
	assert_true(delta_kw > 0.0, "a level costs power")
	var params := controller._check_params("H-001", b, b.level + 1,
			(sim.cmd_upgrade_building("H-001", true).get("payload", {}) as Dictionary))
	var row: Dictionary = params[&"E_POWER_HEADROOM"]
	assert_eq(float(row["required_kw"]), delta_kw * margin,
			"the quote is the number the gate asks doc 04 for")
	# And the quote is the one the gate answers on: asking `power_headroom` for
	# exactly `required_kw` reproduces the command's own verdict.
	assert_eq(bool(sim.power_headroom("H-001", float(row["required_kw"]))["ok"]),
			not (sim.cmd_upgrade_building("H-001", true).get("payload", {})
					as Dictionary).get("blockers", []).has(&"E_POWER_HEADROOM"),
			"panel and gate agree on the same number")


func test_upgrade_checklist_names_the_blocker_in_words() -> void:
	var sim := _sim()
	sim.progression.city_level = 1
	var b: Building = sim.buildings["H-002"]
	b.condition = 0.40
	var upgrade: Dictionary = _controller(sim).building_view("H-002")["upgrade"]
	assert_false(bool(upgrade["ok"]))
	var condition_row: Dictionary = {}
	for row: Dictionary in (upgrade["checklist"] as Array):
		if str(row["canonical"]) == "E_CONDITION":
			condition_row = row
	assert_false(condition_row.is_empty(), "the condition check is listed")
	assert_false(bool(condition_row["ok"]))
	assert_true(str(condition_row["body"]).contains("40%"), condition_row["body"])
	assert_true(str(condition_row["body"]).contains("55%"),
			"the threshold comes from Building.MIN_CONDITION_TO_UPGRADE")
	assert_eq(str((upgrade["blocked_by"] as Dictionary)["canonical"]), "E_CONDITION")


func test_upgrade_checklist_quotes_the_power_deficit() -> void:
	# Doc 02 E2 on real starter data: L2→L3 is what the transformer cannot carry.
	var sim := _sim()
	sim.advance_hours(1.0)
	sim.progression.city_level = 2
	sim.treasury.credit(100_000, &"test_grant")
	assert_true(bool(sim.cmd_upgrade_building("APT-001")["ok"]))
	sim.advance_hours(12.0)
	sim.advance_hours(13.0)
	var upgrade: Dictionary = _controller(sim).building_view("APT-001")["upgrade"]
	assert_false(bool(upgrade["ok"]))
	assert_true(float(upgrade["deficit_kw"]) > 0.0)
	var blocker: Dictionary = upgrade["blocked_by"]
	assert_eq(str(blocker["canonical"]), "POWER_CAPACITY")
	assert_true(str(blocker["body"]).contains("kW") or str(blocker["body"]).contains("MW"),
			blocker["body"])
	assert_true(str(blocker["fix_target"]["id"]).length() > 0,
			"`Fix this →` routes to the transformer that said no")


func test_avenue_check_appears_only_from_level_four() -> void:
	var sim := _sim()
	sim.advance_hours(1.0)
	sim.progression.city_level = 5
	var b: Building = sim.buildings["H-001"]
	b.level = 3
	b.stats = sim.catalog.stats("house", 3)
	var controller := _controller(sim)
	var rows: Array = controller.building_view("H-001")["upgrade"]["checklist"]
	var has_avenue := false
	for row: Dictionary in rows:
		if str(row["canonical"]) == "E_AVENUE":
			has_avenue = true
	assert_true(has_avenue, "L3→L4 is where the avenue gate turns on")
	# The measured distance must agree with the sim's own radius test, or the
	# message would quote a number the gate did not use.
	var measured := controller.nearest_avenue_tiles(b.origin)
	assert_eq(measured <= BuildController.AVENUE_RADIUS_TILES,
			_avenue_within(sim, b.origin, BuildController.AVENUE_RADIUS_TILES))


static func _avenue_within(sim: CitySim, origin: Vector2i, radius: int) -> bool:
	for z in range(origin.y - radius, origin.y + radius + 1):
		for x in range(origin.x - radius, origin.x + radius + 1):
			if TileGrid.in_bounds(x, z) \
					and sim.world.grid.road_class_at(x, z) == TileGrid.ROAD_AVENUE:
				return true
	return false


func test_upgrade_command_runs_and_the_view_refreshes() -> void:
	var sim := _sim()
	sim.advance_hours(1.0)
	sim.progression.city_level = 1
	var controller := _controller(sim)
	var balance := sim.treasury.balance
	var result := controller.upgrade("H-001")
	assert_true(bool(result["ok"]), str(result))
	assert_eq(int(result["payload"]["to_level"]), 2)
	assert_true(sim.treasury.balance < balance)
	# The refreshed panel now reads the in-progress state rather than a stale one.
	var after: Dictionary = controller.building_view("H-001")["upgrade"]
	assert_false(bool(after["ok"]), "an upgrade in progress blocks a second one")
	assert_eq(str((after["blocked_by"] as Dictionary)["canonical"]), "E_STATE")


func test_upgrade_of_a_missing_building_is_safe() -> void:
	var controller := _controller(_sim())
	var result := controller.upgrade("NOPE-999")
	assert_false(bool(result["ok"]))
	assert_eq(result["reason_code"], &"E_UNKNOWN_BUILDING")
	var view: Dictionary = controller.upgrade_view("NOPE-999")
	assert_false(bool(view["ok"]))
	assert_eq((view["checklist"] as Array).size(), 1, "one reason row, no fake checklist")


# ===========================================================================
# Scene binding — the S2/S3/S5 `Control`s hung on the UIRoot scaffold
# ===========================================================================
# These mount `game/ui/ui_root.tscn` in the headless tree so the bindings are
# exercised for real: doc 12 test 19's A3 (48 dp) and A15 (accessibility name)
# tree walk, and the card → ghost → PLACE flow end to end.

func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## Mounts the UI scaffold and wires both screens to `sim`. Free with `_unmount`.
func _mount(sim: CitySim) -> Dictionary:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false  # never touch the test runner's window
	_tree().root.add_child(root)
	# A test loop never reaches an idle frame, so `_ready` does not fire: the
	# scaffold and its screens are brought up explicitly, exactly as `main.gd`
	# does after `add_child()`.
	root.initialize()
	var cfg: UIConfig = root.config
	var controller := BuildController.new(sim, RequirementFormatter.new(cfg))
	var hud := root.get_node_or_null("SafeArea/HUDLayer") as CityHUD
	if hud != null:
		hud.setup(cfg)
	var sheet := root.get_node_or_null("SafeArea/SheetLayer/BuildSheet") as BuildSheet
	var panel := root.get_node_or_null("SafeArea/PanelLayer/BuildingPanel") as BuildingPanel
	if sheet != null:
		sheet.setup(cfg, controller)
	if panel != null:
		panel.setup(cfg, controller)
	return {"root": root, "sheet": sheet, "panel": panel, "controller": controller}


func _unmount(mounted: Dictionary) -> void:
	var root: Node = mounted["root"]
	_tree().root.remove_child(root)
	root.free()


func test_scene_carries_the_build_sheet_and_building_panel() -> void:
	var mounted := _mount(_sim())
	var sheet: BuildSheet = mounted["sheet"]
	var panel: BuildingPanel = mounted["panel"]
	assert_ne(sheet, null, "SafeArea/SheetLayer/BuildSheet is wired")
	assert_ne(panel, null, "SafeArea/PanelLayer/BuildingPanel is wired")
	assert_false(sheet.is_open(), "the sheet starts closed behind the FAB")
	assert_false(panel.is_open())
	# Three rosters now: the archetypes, the two component rosters, and the run
	# cards `PathTool` supplies for doc 12 §2.7's drag-path verbs.
	assert_eq(sheet.cards().size(), BuildingCatalog.ARCHETYPE_COUNT
			+ sheet.controller.grid_kinds().size()
			+ sheet.controller.water_kinds().size()
			+ sheet.path.cards().size())
	sheet.open()
	assert_true(sheet.is_open())
	assert_ne(sheet.card_button("house"), null, "the residential tab lists House")
	sheet.select_category("utility")
	assert_ne(sheet.card_button("substation"), null)
	assert_eq(sheet.card_button("house"), null, "tabs filter the card row")
	sheet.select_category(BuildController.CATEGORY_INFRASTRUCTURE)
	assert_ne(sheet.card_button("transformer"), null, "grid and water share the tab")
	assert_ne(sheet.card_button("water_facility_pump"), null)
	assert_ne(sheet.card_button("water_main_service"), null,
			"doc 12 §2.7 files the water main under Utility with the pumps it feeds")
	sheet.select_category(PathTool.CATEGORY_ROADS)
	assert_ne(sheet.card_button("road_street"), null, "the ROADS tab exists and lists Street")
	assert_ne(sheet.card_button("road_avenue"), null)
	assert_ne(sheet.card_button("road_widen"), null)
	assert_ne(sheet.card_button("road_remove"), null)
	assert_eq(sheet.card_button("house"), null, "and it lists only run cards")
	_unmount(mounted)


func test_a_tab_lists_footprints_before_runs_and_sells_last() -> void:
	# §2.7's "then cost" was written before a run card existed, and a run's
	# `cost` is a price PER TILE. Sorted together, `Feeder` at $110 a tile leads
	# the tab a player reaches by `E_UNSERVED` and `Transformer` — the answer to
	# that very refusal — falls to fourth. So the two kinds sort separately.
	var sim := CitySim.boot_from_files()
	var formatter := RequirementFormatter.load_from_files()
	var controller := BuildController.new(sim, formatter)
	var cards: Array[Dictionary] = controller.cards()
	cards.append_array(PathTool.new(sim, formatter).cards())
	cards.sort_custom(BuildController._card_less)
	var by_tab: Dictionary = {}
	for card: Dictionary in cards:
		var tab := str(card["category"])
		var rows: Array = by_tab.get(tab, [])
		rows.append(card)
		by_tab[tab] = rows
	assert_true(by_tab.has(BuildController.CATEGORY_INFRASTRUCTURE))
	var infra: Array = by_tab[BuildController.CATEGORY_INFRASTRUCTURE]
	assert_eq(str((infra[0] as Dictionary)["id"]), "transformer",
			"doc 93 §A: `cmd_place_grid_component` is THE game, so it leads its tab")
	for tab: Variant in by_tab:
		var seen_run := false
		# One running price per KIND, because the two kinds' prices are not the
		# same quantity — which is the whole reason they are sorted apart.
		var cheapest: Dictionary = {"footprint": -1, "run": -1}
		for entry: Variant in (by_tab[tab] as Array):
			var card: Dictionary = entry
			var is_run := str(card.get("path_verb", "")) != ""
			if is_run:
				seen_run = true
			else:
				assert_false(seen_run,
						"%s: no footprint card after a run card" % card["id"])
			if bool(card.get("refunds", false)):
				continue  # the card that PAYS is checked below, not here
			# …and within each kind the sheet is still a shop, cheapest first.
			var key := "run" if is_run else "footprint"
			assert_true(int(card["cost"]) >= int(cheapest[key]),
					"%s: %d after %d" % [card["id"], int(card["cost"]),
					int(cheapest[key])])
			cheapest[key] = int(card["cost"])
		if str(tab) == PathTool.CATEGORY_ROADS:
			var last: Dictionary = (by_tab[tab] as Array)[-1]
			assert_true(bool(last.get("refunds", false)),
					"the card that PAYS is last on its tab, never first")


func test_persistent_screens_do_not_jam_the_back_stack() -> void:
	# The scaffold's back stack pops "whatever is on the layer"; a persistent
	# screen has to report its own open state or BACK would close the FAB.
	var mounted := _mount(_sim())
	var root: UIRoot = mounted["root"]
	var sheet: BuildSheet = mounted["sheet"]
	assert_eq(root.handle_back(0.0), UIRoot.BACK_PROMPT_MINIMISE,
			"nothing is open, so BACK falls through to the minimise prompt")
	sheet.open()
	assert_eq(root.handle_back(1.0), UIRoot.BACK_CLOSE_SHEET)
	assert_false(sheet.is_open(), "BACK closed the sheet, not freed it")
	assert_ne(root.get_node_or_null("SafeArea/SheetLayer/BuildSheet"), null,
			"the screen survives its own close")
	_unmount(mounted)


func test_every_interactive_control_meets_a3_and_a15() -> void:
	# doc 12 A3: min 48 × 48 dp for anything with a `pressed` signal.
	# doc 12 A15: `tooltip_text` is the accessibility name and is never blank.
	var sim := _sim()
	var mounted := _mount(sim)
	var sheet: BuildSheet = mounted["sheet"]
	var panel: BuildingPanel = mounted["panel"]
	sheet.open()
	panel.show_building("H-001")
	var root: UIRoot = mounted["root"]
	var minimum := float(ThemeBuilder.touch_min_dp(root.config, 1.0, false))
	var checked := 0
	var seen: Array[String] = []
	for node: Node in _walk(root):
		if not (node is Button):
			continue
		var button := node as Button
		checked += 1
		seen.append(str(button.name))
		assert_true(button.custom_minimum_size.x >= minimum,
				"%s is %d dp wide, needs %d" % [button.name, button.custom_minimum_size.x,
						minimum])
		assert_true(button.custom_minimum_size.y >= minimum,
				"%s is %d dp tall, needs %d" % [button.name, button.custom_minimum_size.y,
						minimum])
		assert_true(button.tooltip_text.length() > 0, "%s has an A15 name" % button.name)
	# The walk must actually have reached both new screens, not just the HUD.
	for expected: String in ["Fab", "Confirm", "Cancel", "Close", "UpgradeButton",
			"Tab_residential", "Card_house"]:
		assert_true(seen.has(expected), "the walk reached %s" % expected)
	assert_true(checked >= 20, "the whole UI was walked (%d buttons)" % checked)
	_unmount(mounted)


func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child: Node in node.get_children():
		out.append_array(_walk(child))
	return out


func test_card_tap_raises_the_placement_bar_and_place_commits() -> void:
	var sim := _sim()
	var mounted := _mount(sim)
	var sheet: BuildSheet = mounted["sheet"]
	var controller: BuildController = mounted["controller"]
	sheet.open()
	sheet.card_button("house").pressed.emit()
	assert_true(controller.is_placing(), "the card entered placement mode")
	assert_false(sheet.is_open(), "the sheet collapses into the PlacementBar")
	var bar := mounted["root"].get_node("SafeArea/SheetLayer/BuildSheet/PlacementBar") as Control
	var confirm := mounted["root"].get_node(
			"SafeArea/SheetLayer/BuildSheet/PlacementBar/Row/Confirm") as Button
	assert_true(bar.visible)

	# A blocked lot disables PLACE and says why in words (A14).
	sheet.move_ghost(Vector3(8 * 8.0 + 4.0, 0.0, 8 * 8.0 + 4.0))
	assert_true(confirm.disabled, "BLOCKED disables the commit button")
	# Read through the sheet, not by node path: the bar's two lines are stacked
	# into a `Copy` box at bring-up (doc 12 delta D-17).
	assert_true(sheet.placement_issue_text().length() > 0,
			"the bar names the reason")

	# A good lot enables it, and only the button commits.
	var origin := _serviceable_vacant_tile(sim)
	var balance := sim.treasury.balance
	sheet.move_ghost(Vector3(origin.x * 8.0 + 4.0, 0.0, origin.y * 8.0 + 4.0))
	assert_false(confirm.disabled)
	assert_eq(sim.treasury.balance, balance, "moving the ghost charges nothing")
	confirm.pressed.emit()
	assert_true(sim.treasury.balance < balance, "PLACE committed the build")
	assert_false(controller.is_placing())
	assert_false(bar.visible, "the bar retires with placement mode")
	_unmount(mounted)


func test_locked_card_explains_itself_instead_of_placing() -> void:
	var sim := _sim()
	sim.progression.city_level = 0
	var mounted := _mount(sim)
	var sheet: BuildSheet = mounted["sheet"]
	var refusals: Array[Dictionary] = []
	sheet.card_refused.connect(func(failure: Dictionary) -> void: refusals.append(failure))
	sheet.open()
	sheet.select_category("industrial")
	sheet.card_button("data_center").pressed.emit()
	assert_false((mounted["controller"] as BuildController).is_placing())
	assert_eq(refusals.size(), 1, "the tap was answered, not swallowed")
	assert_eq(str(refusals[0]["canonical"]), "CITY_LEVEL")
	var notice := mounted["root"].get_node(
			"SafeArea/SheetLayer/BuildSheet/Sheet/Body/Notice") as Label
	assert_true(notice.visible and notice.text.length() > 0, "the sheet shows the reason")
	_unmount(mounted)


func test_building_panel_renders_the_checklist_and_gates_upgrade() -> void:
	var sim := _sim()
	sim.advance_hours(1.0)
	sim.progression.city_level = 1
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	panel.show_building("H-001")
	assert_true(panel.is_open())
	assert_eq(panel.selected_id(), "H-001")
	assert_eq(panel.checklist_rows().size(), 7, "every check is listed, not just the first")
	assert_false(panel.upgrade_button().disabled, "no blockers, so UPGRADE is live")

	# Break one requirement and the button must lock behind it.
	(sim.buildings["H-001"] as Building).condition = 0.40
	panel.refresh()
	assert_true(panel.upgrade_button().disabled, "§2.9: disabled while any ✗ remains")
	# `Fix this →` on `E_CONDITION` is a PURCHASE, and since Wave 17 the city has
	# no repair to sell on a house (doc 02 §2.6a) — so the blocker row is drawn
	# and the button is not. The `E_STATE` row is the one that still carries an
	# affordance on any building, so the general claim is checked there.
	var fix_row := panel.get_node_or_null(
			"Panel/Scroll/Body/Checklist/Check_E_CONDITION/Fix") as Button
	assert_eq(fix_row, null,
			"private stock: the blocker is stated, no button is offered")
	assert_true(panel.checklist_rows().size() >= 6, "and the row itself is still there")

	# Repair it and the real command runs on the button press.
	(sim.buildings["H-001"] as Building).condition = 1.0
	panel.refresh()
	var results: Array[Dictionary] = []
	panel.upgraded.connect(func(result: Dictionary) -> void: results.append(result))
	var balance := sim.treasury.balance
	panel.upgrade_button().pressed.emit()
	assert_eq(results.size(), 1)
	assert_true(bool(results[0]["ok"]), str(results[0]))
	assert_true(sim.treasury.balance < balance)
	assert_true(panel.upgrade_button().disabled,
			"the refreshed panel reflects the upgrade in progress")
	_unmount(mounted)


func test_building_panel_closes_on_empty_ground() -> void:
	var sim := _sim()
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	panel.show_building("H-001")
	assert_true(panel.is_open())
	panel.show_building("NOPE-999")
	assert_false(panel.is_open(), "an unknown pick closes rather than showing stale data")
	assert_eq(panel.selected_id(), "")
	_unmount(mounted)


func test_level_pips_read_exactly_as_the_doc_writes_them() -> void:
	# §2.9's header row: `L1 L2 ▮L3▮ L4 L5`.
	assert_eq(BuildingPanel.level_pips(3, 5), "L1 L2 ▮L3▮ L4 L5")
	assert_eq(BuildingPanel.level_pips(1, 5), "▮L1▮ L2 L3 L4 L5")
	assert_eq(BuildingPanel.level_pips(0, 5), "L1 L2 L3 L4 L5",
			"a build in progress has no level yet")


# ===========================================================================
# §2.9 item 6 — the actions row (Wave 10). Repair / Priority / Demolish all
# shipped as sim verbs with no door (doc 92 §17.6); these are the doors.
# ===========================================================================

## Re-pointed onto a CITY asset in Wave 17 (doc 02 §2.6a): the police station is
## the city's to repair, the tutorial house is its owners'. The test below this
## one is the house's half.
func test_repair_is_absent_on_a_healthy_building_and_priced_on_a_worn_one() -> void:
	var sim := _sim()
	var controller := _controller(sim)
	var b: Building = sim.buildings["POL-1"]
	b.condition = 1.0
	var healthy: Dictionary = controller.actions_view("POL-1")["repair"]
	assert_false(bool(healthy["available"]),
			"doc 02 §2.6 refuses E_NOT_DAMAGED, so there is no button to press")

	b.condition = 0.60
	var worn: Dictionary = controller.actions_view("POL-1")["repair"]
	assert_true(bool(worn["available"]))
	assert_true(bool(worn["ok"]), "the founding treasury can afford one station repair")
	assert_eq(int(worn["cost"]), sim.econ_curves.repair_cost_building("police_station",
			maxi(b.level, 1), b.damage_fraction(),
			float(sim.treasury.difficulty().get("M_repair", 1.0))),
			"the price is doc 03 §2.5's, read through CostCurves")
	assert_almost_eq(float(worn["condition"]), 0.60, 0.0001)
	assert_almost_eq(float(worn["target"]), 1.0, 0.0001,
			"an `active` building repairs back to new (doc 02 §2.12)")


## Doc 02 §2.6a / doc 93 §Y3a — the whole of the user's "we shouldn't have to
## interrupt the gameplay to repair buildings because nothing actually happened".
## A private building has NO repair row at any condition, not a disabled one: the
## 2026-09-01 playtest counted the row on 260 private buildings in one 21-day
## city (doc 92 §43.1), and 260 disabled buttons is not an improvement on 260
## enabled ones.
func test_a_private_building_never_offers_a_repair_row() -> void:
	var sim := _sim()
	var controller := _controller(sim)
	var b: Building = sim.buildings["H-001"]
	assert_true(b.owner_maintained, "a house is private stock")
	for condition in [1.0, 0.90, 0.60, 0.34, 0.01]:
		b.condition = float(condition)
		var view: Dictionary = controller.actions_view("H-001")["repair"]
		assert_false(bool(view["available"]),
				"no REPAIR row at condition %.2f" % condition)
		assert_true((view["reason"] as Dictionary).is_empty(),
				"and nothing to read at condition %.2f" % condition)
	assert_eq(sim.cmd_repair_building("H-001")["reason_code"], &"E_OWNER_MAINTAINED",
			"the command still names the reason for the agents and the tests")


func test_the_panel_buys_the_repair_the_row_quoted() -> void:
	var sim := _sim()
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	(sim.buildings["POL-1"] as Building).condition = 0.55
	panel.show_building("POL-1")
	var quoted := int(((panel.view()["actions"] as Dictionary)["repair"]
			as Dictionary)["cost"])
	assert_true(quoted > 0)
	var results: Array[Dictionary] = []
	panel.repaired.connect(func(result: Dictionary) -> void: results.append(result))
	var before := sim.treasury.balance
	panel.request_repair()
	assert_eq(results.size(), 1)
	assert_true(bool(results[0]["ok"]), str(results[0]))
	assert_eq(before - sim.treasury.balance, quoted,
			"the panel charged exactly what it printed")
	# The refreshed panel must show the job, not a second one to buy.
	var after: Dictionary = (panel.view()["actions"] as Dictionary)["repair"]
	assert_false(bool(after["ok"]), "doc 02 §2.6's E_JOB_IN_FLIGHT, in the panel")
	assert_false((after["reason"] as Dictionary).is_empty(),
			"and it says so in words rather than by a dead button")
	_unmount(mounted)


func test_fix_this_on_condition_buys_the_repair_rather_than_moving_the_camera() -> void:
	# The row's fix target used to be the building the player already had open,
	# so `Fix this →` focused the camera on the thing under their thumb and did
	# nothing. `E_CONDITION`'s fix is a PURCHASE (RequirementFormatter.FIX_REPAIR).
	var sim := _sim()
	sim.advance_hours(1.0)
	sim.progression.city_level = 1
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	(sim.buildings["POL-1"] as Building).condition = 0.40
	panel.show_building("POL-1")
	var fix := panel.get_node_or_null(
			"Panel/Scroll/Body/Checklist/Check_E_CONDITION/Fix") as Button
	assert_ne(fix, null, "the blocker row still carries the affordance")
	var routed: Array[Dictionary] = []
	var repairs: Array[Dictionary] = []
	panel.fix_requested.connect(func(t: Dictionary) -> void: routed.append(t))
	panel.repaired.connect(func(result: Dictionary) -> void: repairs.append(result))
	fix.pressed.emit()
	assert_eq(routed.size(), 0, "nothing was handed to the camera router")
	assert_eq(repairs.size(), 1, "a repair was bought instead")
	assert_true(bool(repairs[0]["ok"]), str(repairs[0]))
	_unmount(mounted)


## The other half of the same row (doc 93 §Y3a). `E_CONDITION` still BLOCKS an
## upgrade on private stock — a worn building is a worn building — but there is
## no repair for the city to buy, so the row states the blocker and offers no
## button rather than offering one that refuses. A button that cannot work is
## the failure shape PA-24 filed on `E_WATER_HEADROOM`, in a new place.
func test_fix_this_is_absent_on_a_privately_maintained_building() -> void:
	var sim := _sim()
	sim.advance_hours(1.0)
	sim.progression.city_level = 1
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	var house: Building = sim.buildings["H-001"]
	assert_true(house.owner_maintained)
	house.condition = 0.40
	panel.show_building("H-001")
	var row := panel.get_node_or_null(
			"Panel/Scroll/Body/Checklist/Check_E_CONDITION")
	assert_ne(row, null, "the blocker is still stated")
	assert_eq(row.get_node_or_null("Fix"), null,
			"but there is no repair to sell, so there is no button")
	_unmount(mounted)


func test_priority_row_lists_doc_fours_classes_and_sets_one() -> void:
	var sim := _sim()
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	panel.show_building("H-001")
	var priority: Dictionary = (panel.view()["actions"] as Dictionary)["priority"]
	assert_true(bool(priority["available"]), "a served building carries a shed tier")
	var classes: Array = sim.grid_rules["priority"]["classes"]
	assert_eq((priority["classes"] as Array).size(), classes.size(),
			"the row is doc 04's roster, not a list authored in ui/")
	var results: Array[Dictionary] = []
	panel.priority_set.connect(func(result: Dictionary) -> void: results.append(result))
	var button := panel.get_node_or_null(
			"Panel/Scroll/Body/Actions/Priority/Priority_CRITICAL") as Button
	assert_ne(button, null, "one 48 dp target per class")
	button.pressed.emit()
	assert_eq(results.size(), 1)
	assert_true(bool(results[0]["ok"]), str(results[0]))
	assert_eq(String(sim.grid.priority_class_of("H-001")), "CRITICAL")
	assert_eq(str(((panel.view()["actions"] as Dictionary)["priority"]
			as Dictionary)["current"]), "CRITICAL",
			"and the refreshed row reads the sim, not the tap")
	_unmount(mounted)


func test_demolish_quotes_its_refund_and_only_fires_on_a_full_hold() -> void:
	var sim := _sim()
	var mounted := _mount(sim)
	var panel: BuildingPanel = mounted["panel"]
	panel.show_building("H-001")
	var demolish: Dictionary = (panel.view()["actions"] as Dictionary)["demolish"]
	assert_true(bool(demolish["available"]) and bool(demolish["ok"]))
	var refund := int(demolish["refund"])
	assert_eq(refund, int((sim.cmd_demolish_building("H-001", true)["payload"]
			as Dictionary)["refund"]), "the panel quotes the command's own refund")

	var fired: Array[String] = []
	panel.demolished.connect(func(sim_id: String, _r: Dictionary) -> void:
		fired.append(sim_id))
	var button := panel.get_node_or_null("Panel/Scroll/Body/Actions/Demolish") as Button
	assert_ne(button, null)
	# Half a hold demolishes nothing — the one irreversible button in the deck.
	button.button_down.emit()
	panel._process(0.4)
	assert_eq(fired.size(), 0, "800 ms means 800 ms")
	assert_true(sim.buildings.has("H-001"))
	button.button_up.emit()
	assert_eq(fired.size(), 0, "and letting go early abandons it")

	var before := sim.treasury.balance
	button.button_down.emit()
	panel._process(1.0)
	assert_eq(fired.size(), 1, "a full hold fires exactly once")
	assert_false(sim.buildings.has("H-001"), "and doc 02 §2.12 took the building")
	assert_eq(sim.treasury.balance - before, refund, "at the refund it quoted")
	assert_false(panel.is_open(), "the panel closes rather than describing a hole")
	_unmount(mounted)


# ===========================================================================
# §2.7's run flow, through the sheet the player actually touches
# ===========================================================================

func test_a_run_card_enters_the_path_tool_and_the_bar_is_two_step() -> void:
	var sim := _sim()
	var mounted := _mount(sim)
	var sheet: BuildSheet = mounted["sheet"]
	sheet.open()
	sheet.select_category(PathTool.CATEGORY_ROADS)
	sheet.card_button("road_street").pressed.emit()
	assert_true(sheet.is_placing(), "the shell asks ONE question about placement")
	assert_true(sheet.is_placing_path())
	assert_false(sheet.controller.is_placing(),
			"and the footprint machine stood down rather than running beside it")
	assert_true(sheet.path.is_aiming())

	var tile := _road_edge_tile(sim)
	sheet.move_ghost(Vector3(float(tile.x) * 8.0 + 4.0, 0.0, float(tile.y) * 8.0 + 4.0))
	assert_true(sheet.path.is_aiming(), "a ghost move is not a decision")
	sheet.confirm_placement()   # START
	assert_true(sheet.path.is_drawing(), "the primary button pinned the anchor")
	assert_eq(sheet.path.anchor, tile)

	# The left button is `↺` while drawing: it unpins rather than leaving.
	sheet._on_bar_cancel()
	assert_true(sheet.path.is_aiming())
	assert_true(sheet.is_placing_path(), "still holding the card")
	# …and CANCEL again from AIMING leaves for real.
	sheet._on_bar_cancel()
	assert_false(sheet.is_placing())
	_unmount(mounted)


func test_a_world_drag_draws_a_run_and_never_commits_on_finger_up() -> void:
	var sim := _sim()
	var mounted := _mount(sim)
	var sheet: BuildSheet = mounted["sheet"]
	assert_false(sheet.begin_world_drag(Vector3.ZERO),
			"with no run tool up the router declines and the camera pans")
	sheet.open()
	sheet.select_category(PathTool.CATEGORY_ROADS)
	sheet.card_button("road_street").pressed.emit()

	var tile := _road_edge_tile(sim)
	assert_true(sheet.begin_world_drag(
			Vector3(float(tile.x) * 8.0 + 4.0, 0.0, float(tile.y) * 8.0 + 4.0)),
			"the router claims the stroke")
	assert_true(sheet.path.is_drawing())
	assert_eq(sheet.path.anchor, tile, "anchored on the finger-DOWN tile")
	var head := tile + Vector2i(2, 0)
	assert_true(sheet.update_world_drag(
			Vector3(float(head.x) * 8.0 + 4.0, 0.0, float(head.y) * 8.0 + 4.0)))
	assert_eq(sheet.path.tiles().size(), 3)
	var before := sim.treasury.balance
	assert_true(sheet.end_world_drag())
	assert_eq(sim.treasury.balance, before,
			"§2.7: placement is never committed on finger-up")
	assert_true(sheet.path.is_drawing(), "the run stays, waiting for PLACE")
	_unmount(mounted)


## Free ground beside a road the founding city already built. Asked, never
## named — doc 09's map is data.
static func _road_edge_tile(sim: CitySim) -> Vector2i:
	for z in TileGrid.SIZE:
		for x in TileGrid.SIZE:
			if sim.world.grid.road_class_at(x, z) == TileGrid.ROAD_NONE:
				continue
			for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1),
					Vector2i(-1, 0), Vector2i(0, -1)]:
				var q := Vector2i(x, z) + d
				if not TileGrid.in_bounds(q.x, q.y):
					continue
				if sim.world.grid.road_class_at(q.x, q.y) != TileGrid.ROAD_NONE:
					continue
				if not sim.world.grid.can_place(q, Vector2i.ONE):
					continue
				var block := sim.world.block_of_tile(q.x, q.y)
				if block != null and block.is_ready():
					return q
	return Vector2i(56, 56)
