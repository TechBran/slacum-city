extends SimTest
## Doc 05 §6's last three verbs and the two doors doc 93 §J1 rules for them:
## `cmd_upgrade_water_component` on the building panel of the shell that hosts
## the node, and `cmd_isolate_water_main` / `cmd_restore_water_main` on the
## incident drawer's expanded row.
##
## Same contract `tests/test_path_tool.gd` holds itself to: every assertion is
## about a DOOR, and every verdict is taken from a real `CitySim` rather than a
## stub, because the panel's answer and the command's answer have to be one code
## path. What the verbs themselves do is `tests/test_infra_verbs.gd`'s job and is
## not re-asserted here.


func _sim() -> CitySim:
	return CitySim.boot_from_files()


func _actions(sim: CitySim) -> WaterActions:
	return WaterActions.new(sim, RequirementFormatter.load_from_files())


## The authored shell that hosts more than one doc-05 node — doc 09 §2.9.4 gives
## `WTR-1` a source, a treatment train and a pump. Found, never named.
static func _multi_node_shell(sim: CitySim) -> String:
	var counts: Dictionary = {}
	for key: Variant in sim.water.nodes:
		var ref := (sim.water.nodes[key] as WaterNode).power_ref
		counts[ref] = int(counts.get(ref, 0)) + 1
	var best := ""
	var best_count := 0
	for key: Variant in counts:
		var id := str(key)
		if sim.buildings.has(id) and int(counts[key]) > best_count:
			best = id
			best_count = int(counts[key])
	return best


static func _junction(sim: CitySim) -> String:
	for key: Variant in sim.water.nodes:
		if (sim.water.nodes[key] as WaterNode).variant == &"junction":
			return str(key)
	return ""


# ===========================================================================
# 1. The node block — one row per node the shell hosts
# ===========================================================================

func test_only_a_water_shell_carries_a_node_block() -> void:
	var sim := _sim()
	var actions := _actions(sim)
	var shell := _multi_node_shell(sim)
	assert_ne(shell, "", "the starter city has a water site")
	assert_true(bool(actions.building_block(shell)["available"]))
	# Every other building in the city hosts nothing, and its panel is exactly
	# the panel it was.
	var others := 0
	for key: Variant in sim.buildings:
		var id := str(key)
		if id == shell or String((sim.buildings[id] as Building).archetype) \
				== "water_facility":
			continue
		assert_false(bool(actions.building_block(id)["available"]),
				"%s hosts no doc-05 node" % id)
		others += 1
	assert_true(others > 10, "and that was asserted over a real roster")


func test_the_block_lists_every_node_the_shell_hosts() -> void:
	var sim := _sim()
	var actions := _actions(sim)
	var shell := _multi_node_shell(sim)
	var rows: Array = actions.building_block(shell)["nodes"]
	assert_true(rows.size() >= 2,
			"doc 09 §2.9.4 puts a source, a treatment train and a pump on one site")
	var ids: PackedStringArray = []
	for entry: Variant in rows:
		var row: Dictionary = entry
		ids.append(str(row["node"]))
		assert_eq((sim.water.nodes[str(row["node"])] as WaterNode).power_ref, shell)
		assert_true(str(row["name_key"]).begins_with("ui_build_card_"), "G-8 key")
		assert_eq(int(row["level"]),
				(sim.water.nodes[str(row["node"])] as WaterNode).level)
	var sorted := ids.duplicate()
	sorted.sort()
	assert_eq(str(ids), str(sorted), "deterministic order")


func test_the_ladder_height_is_doc_05s_roster_under_its_own_flag() -> void:
	var sim := _sim()
	var actions := _actions(sim)
	assert_false(sim.water.data.flag("levels_4_5_enabled"),
			"this build ships with levels 4-5 gated")
	# `source` and `treatment` stop at 2, `pump` and `tank` at 3 — the roster's
	# own numbers, never a constant in ui/.
	assert_eq(actions.max_level_of("source"), 2)
	assert_eq(actions.max_level_of("treatment"), 2)
	assert_eq(actions.max_level_of("pump"), 3)
	assert_eq(actions.max_level_of("tank"), 3)


func test_a_junction_shows_a_row_and_no_button() -> void:
	var sim := _sim()
	var actions := _actions(sim)
	var junction := _junction(sim)
	assert_ne(junction, "")
	var row := actions.node_view(junction)
	assert_false(bool(row["upgradeable"]), "doc 05 §2.1: a junction has no ladder")
	assert_false(bool((row["upgrade"] as Dictionary)["available"]))
	assert_true((row["upgrade"] as Dictionary)["checklist"] is Array)
	assert_eq(((row["upgrade"] as Dictionary)["checklist"] as Array).size(), 0,
			"and therefore no gate to show")


# ===========================================================================
# 2. The upgrade row quotes the verb, and the verb is what runs
# ===========================================================================

func test_the_row_quotes_the_commands_own_preview() -> void:
	var sim := _sim()
	sim.treasury.balance = 2_000_000
	var actions := _actions(sim)
	var row := actions.node_view("WTR-2")
	var upgrade: Dictionary = row["upgrade"]
	var quote := sim.cmd_upgrade_water_component("WTR-2", true)
	assert_true(bool(quote["ok"]), str(quote))
	assert_eq(int(upgrade["cost"]), int(quote["payload"]["cost"]),
			"the panel never prices a thing itself (doc 12 §3.1 G-8)")
	assert_eq(int(upgrade["to_level"]), int(quote["payload"]["to_level"]))
	assert_true(bool(upgrade["ok"]))
	assert_eq(str(upgrade["cost_text"]),
			RequirementFormatter.money(int(quote["payload"]["cost"])))


func test_a_broke_city_shows_the_whole_gate_with_the_first_no_named() -> void:
	var sim := _sim()
	sim.treasury.balance = 0
	var actions := _actions(sim)
	var upgrade: Dictionary = actions.node_view("WTR-2")["upgrade"]
	assert_false(bool(upgrade["ok"]))
	assert_eq((upgrade["checklist"] as Array).size(), WaterActions.UPGRADE_CHECKS.size(),
			"§2.9 item 5: the whole checklist, passing rows included")
	var blocker: Dictionary = upgrade["blocked_by"]
	assert_eq(StringName(str(blocker["code"])), &"E_FUNDS")
	assert_true(str(blocker["body"]).length() > 0, "and it is a sentence")
	assert_false(str(blocker["body"]).contains("{"), "with no unfilled placeholder")


func test_the_button_runs_the_real_command() -> void:
	var sim := _sim()
	sim.treasury.balance = 2_000_000
	var actions := _actions(sim)
	var before: int = sim.treasury.balance
	var cost := int((actions.node_view("WTR-2")["upgrade"] as Dictionary)["cost"])
	assert_true(bool(actions.upgrade_node("WTR-2")["ok"]))
	assert_eq(before - sim.treasury.balance, cost, "the quote was the price")
	assert_eq((sim.water.nodes["WTR-2"] as WaterNode).level, 2)
	# And the row now describes the city that exists.
	assert_eq(int(actions.node_view("WTR-2")["level"]), 2)


func test_the_panel_binds_the_block_the_controller_computed() -> void:
	var sim := _sim()
	var controller := BuildController.new(sim, RequirementFormatter.load_from_files())
	var shell := _multi_node_shell(sim)
	var view := controller.building_view(shell)
	assert_true(view.has("water"), "S5's view model carries doc 05's block")
	assert_true(bool((view["water"] as Dictionary)["available"]))
	# And an ordinary building's does not, so no panel in the city grows a block
	# it has nothing to put in.
	for key: Variant in sim.buildings:
		var id := str(key)
		if String((sim.buildings[id] as Building).archetype) != "residential":
			continue
		assert_false(bool((controller.building_view(id)["water"]
				as Dictionary)["available"]))
		break


# ===========================================================================
# 3. §2.12's tactical pair — the drawer's fourth action
# ===========================================================================

func test_only_a_water_break_row_names_a_main() -> void:
	assert_eq(WaterActions.segment_of_row({}), "")
	assert_eq(WaterActions.segment_of_row(
			{"target_kind": "building", "target_id": "R-1"}), "",
			"a fire's target is a building and has no valve")
	assert_eq(WaterActions.segment_of_row(
			{"target_kind": "water_segment", "target_id": "M_TIE"}), "M_TIE")


func test_the_segment_view_reads_the_main_the_sim_has() -> void:
	var sim := _sim()
	var actions := _actions(sim)
	assert_false(bool(actions.segment_view("NOPE")["exists"]),
			"a main the sim does not have draws no button")
	var view := actions.segment_view("M_TIE")
	assert_true(bool(view["exists"]))
	assert_true(bool(view["can_isolate"]))
	assert_false(bool(view["can_restore"]), "one control, two moods, never both")
	assert_eq(int(view["tiles"]), (sim.water.edges["M_TIE"] as WaterEdge).path.size())
	assert_true(float(view["work_minutes"]) > 0.0,
			"doc 05 §2.12's isolate work content, and the only figure it has")


func test_isolate_then_restore_flips_the_control() -> void:
	var sim := _sim()
	var actions := _actions(sim)
	assert_true(bool(actions.isolate("M_TIE")["ok"]))
	var isolated := actions.segment_view("M_TIE")
	assert_true(bool(isolated["isolated"]))
	assert_false(bool(isolated["can_isolate"]))
	assert_true(bool(isolated["can_restore"]))
	assert_true(bool(actions.restore("M_TIE")["ok"]))
	assert_true(bool(actions.segment_view("M_TIE")["can_isolate"]))
	# The refusals the drawer can raise both have copy.
	var formatter := RequirementFormatter.load_from_files()
	for code: StringName in [&"E_NOT_ISOLATED", &"E_UNKNOWN_MAIN"]:
		var row := formatter.format(code, {})
		assert_true(RequirementFormatter.is_known(code), "%s is in the table" % code)
		assert_false(str(row["body"]).contains("{"), "%s renders" % code)


func test_an_isolated_main_survives_a_save_round_trip() -> void:
	# Doc 05 state, and `WaterEdge.serialize()` has always carried it — which is
	# why doc 93 §J1's surface needs NO save-section bump. Asserted rather than
	# assumed, because the ruling turns on it.
	var sim := _sim()
	assert_true(bool(sim.cmd_isolate_water_main("M_TIE")["ok"]))
	var captured := sim.capture_state()
	var restored := CitySim.boot_from_files()
	restored.restore_state(captured.duplicate(true))
	assert_eq(String((restored.water.edges["M_TIE"] as WaterEdge).state), "isolated")
	assert_true(bool(_actions(restored).segment_view("M_TIE")["can_restore"]),
			"and the drawer offers RESTORE on the city that came back")


func test_a_repaired_main_comes_back_on_its_own() -> void:
	# The trap the ruling has to answer: an isolated main with no incident left
	# to open the drawer on. Doc 05's own repair path clears the flag, so the
	# only mains the drawer lets a player valve out are ones that un-valve
	# themselves when the crew finishes.
	var sim := _sim()
	sim.water.set_segment_broken("M_TIE", 0.6, "incident:1")
	assert_true(bool(sim.cmd_isolate_water_main("M_TIE")["ok"]))
	assert_eq(String((sim.water.edges["M_TIE"] as WaterEdge).state), "isolated")
	sim.water.set_segment_repaired("M_TIE")
	assert_eq(String((sim.water.edges["M_TIE"] as WaterEdge).state), "ok",
			"the repair is what restores it — the player cannot strand a main")


# ===========================================================================
# 4. The snapshot carries the target the drawer acts on
# ===========================================================================

func test_the_incident_snapshot_names_its_target() -> void:
	var sim := _sim()
	var incidents := sim.incidents
	var inc := incidents.spawn("water_main_break", "", Vector2i(40, 40),
			{"kind": "water_segment", "id": "M_TIE"}, 0.5, {"source": "test"})
	assert_ne(inc, null)
	var rows := incidents.snapshot()
	var found := false
	for entry: Variant in rows:
		var row: Dictionary = entry
		if int(row["id"]) != inc.id:
			continue
		found = true
		assert_eq(str((row["target_ref"] as Dictionary)["kind"]), "water_segment")
		assert_eq(str((row["target_ref"] as Dictionary)["id"]), "M_TIE")
	assert_true(found, "the row the drawer refreshes from")
	# And the model turns it into the two flat fields the drawer reads.
	var model := IncidentModel.new(UIConfig.load_from_files())
	model.refresh(rows)
	assert_eq(WaterActions.segment_of_row(model.row(inc.id)), "M_TIE")
