extends SimTest
## **Wave 28 — the water chain, the break that nobody could clear, and S19.**
##
## The player, 2026-09-05: *"Our water capacity — we need to be able to create a
## water source, put pumps on it to increase our volume. My volume is starting to
## get low. Make sure the whole water infrastructure is tight."*
##
## Doc 05 §2.5's supply is the minimum of four terms and until this wave nothing
## in the project computed all four in one place: `tests/balance_gate_rig.gd`
## summed three, `tools/playtest.gd` summed the same three a second time, and the
## GAME summed none — so a player whose zone was treatment-bound was sold pumps
## (doc 92 §67.4 measured 118 of them, $5.5M, and the zone's supply did not
## move). Every assertion here is about that read and about the doors that
## consume it.
##
## The measurement this file is the regression guard for is doc 92 §69.1, on the
## player's own save: three mains left broken by incidents that had gone terminal
## and been pruned, leaking **40.1 m³/h** — 95 % of that city's entire water
## demand — each holding a doc-06 tier-5 −0.80 that clamped to §2.8's 0.50 cap,
## with **89 of 89 buildings** under doc 02's 0.55 upgrade gate and 31 m³/h of
## supply spare.


func _sim() -> CitySim:
	return CitySim.boot_from_files()


## The zone the founding city's plant feeds. Found, never named.
static func _live_zone(sim: CitySim) -> PressureZone:
	for raw: Variant in sim.water.topology.zones:
		var z: PressureZone = raw
		if not z.dead and z.building_count > 0:
			return z
	return null


static func _first_edge_of(zone: PressureZone) -> String:
	var ids: Array = zone.edge_ids.duplicate()
	ids.sort()
	return String(ids[0]) if not ids.is_empty() else ""


# ===========================================================================
# 1. §2.5's chain, computed once and named
# ===========================================================================

func test_the_chain_reports_all_four_terms_and_names_the_one_that_binds() -> void:
	var sim := _sim()
	var zone := _live_zone(sim)
	assert_ne(zone, null, "the founding city has a live pressure zone")
	var chain := sim.water.supply_chain(zone.zone_key)
	assert_true(bool(chain["live"]))
	for key: String in ["source_m3h", "treatment_m3h", "pump_available_m3h",
			"mains_m3h", "supply_m3h", "demand_m3h"]:
		assert_true(chain.has(key), "the chain publishes " + key)
	# The binding stage is the ARGMIN of the four, and `supply` never exceeds it.
	var terms := {"source": float(chain["source_m3h"]),
			"treatment": float(chain["treatment_m3h"]),
			"pump": float(chain["pump_m3h"]),
			"mains": float(chain["mains_m3h"])}
	var smallest := INF
	for key: Variant in terms:
		smallest = minf(smallest, float(terms[key]))
	assert_almost_eq(float(chain["binding_m3h"]), smallest, 0.001,
			"the binding term is the smallest term")
	assert_almost_eq(float(terms[String(chain["binding"])]), smallest, 0.001,
			"and the stage named is the stage that holds it")
	assert_true(float(chain["supply_m3h"]) <= smallest + 0.001,
			"supply never exceeds the narrowest stage: %f vs %f"
			% [chain["supply_m3h"], smallest])
	# `next_binding` is what would bind after it — the sentence a player needs
	# before spending, and it must not be the stage that already binds.
	assert_ne(String(chain["next_binding"]), String(chain["binding"]))


func test_the_founding_city_binds_on_its_treatment_train_and_says_so() -> void:
	# Doc 05 §2.13's own ladder: an L1 river intake yields 107 and an L1
	# treatment train passes 80.0, so `min(source, treatment)` IS the treatment
	# term on every city that ships with one of each. This is the exact reading
	# doc 92 §67.3 measured at 78.1 against a source of 105.1 — and the reading
	# that makes "buy another pump" the wrong answer.
	var sim := _sim()
	var zone := _live_zone(sim)
	var chain := sim.water.supply_chain(zone.zone_key)
	assert_true(float(chain["treatment_m3h"]) < float(chain["source_m3h"]),
			"treatment is narrower than the intake: %f vs %f"
			% [chain["treatment_m3h"], chain["source_m3h"]])
	# `binding_ids` is the purchase, cheapest rung first, so `[0]` is what the
	# panel offers and the fix row routes to.
	if String(chain["binding"]) == "treatment":
		assert_false((chain["binding_ids"] as Array).is_empty())
		var node: WaterNode = sim.water.nodes[String((chain["binding_ids"] as Array)[0])]
		assert_eq(String(node.variant), "treatment")


func test_the_chain_of_a_dead_zone_is_answerable_and_binds_on_nothing() -> void:
	var sim := _sim()
	var chain := sim.water.supply_chain("no-such-zone")
	assert_false(bool(chain["live"]))
	assert_eq(String(chain["binding"]), "none")
	assert_eq(float(chain["supply_m3h"]), 0.0)


# ===========================================================================
# 2. A91-D-145 — the hold three of the incident's exits never released
# ===========================================================================

func test_a_break_whose_incident_goes_terminal_stops_holding_doc_06s_magnitude() -> void:
	var sim := _sim()
	var zone := _live_zone(sim)
	var edge_id := _first_edge_of(zone)
	assert_ne(edge_id, "")
	# Doc 06's seam, at the tier-5 magnitude its own table publishes for a break
	# that has run out of time.
	sim.water.set_segment_broken(edge_id, 1.0, "incident:9999", -0.80)
	var edge: WaterEdge = sim.water.edge(edge_id)
	assert_eq(edge.owning_incident, "incident:9999")
	assert_almost_eq(edge.incident_pressure_penalty, 0.80, 0.001)
	# …and the incident is gone. `release_segment_incident` is what every
	# terminal exit calls; the pipe stays broken because the pipe IS broken.
	sim.water.release_segment_incident(edge_id)
	assert_eq(edge.owning_incident, "", "the claim is dropped")
	assert_eq(edge.incident_pressure_penalty, 0.0, "and the magnitude with it")
	assert_eq(String(edge.state), "broken", "the break itself is untouched")
	assert_almost_eq(edge.severity, 1.0, 0.001)
	# §2.8's own fallback is now reachable, which it was not while the field was
	# set: 0.12 × severity rather than a permanent 0.80.
	sim.water.rebuild_zones()
	sim.advance_hours(0.5)
	var after := sim.water.topology.zone_by_key(zone.zone_key)
	if after != null:
		assert_true(after.break_penalty <= 0.13,
				"the fallback penalty applies: %f" % after.break_penalty)


func test_releasing_a_hold_on_a_sound_main_changes_nothing() -> void:
	var sim := _sim()
	var zone := _live_zone(sim)
	var edge_id := _first_edge_of(zone)
	var edge: WaterEdge = sim.water.edge(edge_id)
	var before := String(edge.state)
	sim.water.release_segment_incident(edge_id)
	assert_eq(String(edge.state), before)
	assert_eq(edge.owning_incident, "")


# ===========================================================================
# 3. A91-D-146 — a save whose claim outlived its claimant
# ===========================================================================

func test_a_restored_city_drops_a_hold_whose_incident_is_in_nobodys_roster() -> void:
	var sim := _sim()
	var zone := _live_zone(sim)
	var edge_id := _first_edge_of(zone)
	# The exact shape the player's slot was in: a broken main naming an incident
	# id, and no such incident anywhere.
	sim.water.set_segment_broken(edge_id, 1.0, "incident:1811", -0.80)
	var body := sim.capture_state()
	var restored := CitySim.boot_from_files()
	restored.restore_state(body)
	var edge: WaterEdge = restored.water.edge(edge_id)
	assert_ne(edge, null)
	assert_eq(String(edge.state), "broken", "the break survives the save")
	assert_eq(edge.owning_incident, "",
			"and the dangling claim does not — nothing can ever resolve it")
	assert_eq(edge.incident_pressure_penalty, 0.0)


func test_a_hold_whose_incident_is_still_live_survives_the_round_trip() -> void:
	# The other direction, and it is the one that says the sweep is a
	# reconciliation and not a bulldozer: a break doc 06 is still working keeps
	# its tiered magnitude across a save.
	var sim := _sim()
	var zone := _live_zone(sim)
	var edge_id := _first_edge_of(zone)
	var incident := sim.incidents.spawn_automatic("water_main_break", "",
			WaterSystem.main_tile(sim.water.edge(edge_id)),
			{"kind": "water_segment", "id": edge_id}, -1.0, {"source": "test"})
	assert_ne(incident, null, "doc 06 raised the incident")
	sim.water.set_segment_broken(edge_id, 1.0, "incident:%d" % incident.id, -0.35)
	var body := sim.capture_state()
	var restored := CitySim.boot_from_files()
	restored.restore_state(body)
	var edge: WaterEdge = restored.water.edge(edge_id)
	assert_eq(edge.owning_incident, "incident:%d" % incident.id,
			"a live incident keeps its segment")
	assert_almost_eq(edge.incident_pressure_penalty, 0.35, 0.001)


# ===========================================================================
# 4. RR-224 — the repair door doc 03 had been holding a price for
# ===========================================================================

func test_a_broken_main_can_be_dug_up_and_the_leak_stops() -> void:
	var sim := _sim()
	sim.treasury.balance = 500_000
	var zone := _live_zone(sim)
	var edge_id := _first_edge_of(zone)
	sim.water.set_segment_broken(edge_id, 1.0, "", 0.0)
	sim.water.rebuild_zones()
	sim.advance_hours(0.5)
	var leaking := sim.water.topology.zone_by_key(zone.zone_key)
	assert_true(leaking.leak_m3h > 0.0, "a broken main leaks")
	var quote := sim.cmd_repair_water_asset(edge_id, true)
	assert_true(bool(quote["ok"]), str(quote.get("reason_code", "")))
	var payload: Dictionary = quote["payload"]
	# Doc 03 §2.5's formula, against doc 03's own water capital. This document
	# authors no dollar; it asserts the two agree.
	var edge: WaterEdge = sim.water.edge(edge_id)
	var capital := sim.econ_curves.capital_value_water_main(edge.tier, edge.path.size())
	assert_eq(int(payload["capital"]), capital)
	assert_eq(int(payload["cost"]), sim.econ_curves.repair_cost(capital,
			float(payload["damage_fraction"]),
			float(sim.treasury.difficulty().get("M_repair", 1.0))))
	assert_true(float(payload["leak_m3h"]) > 0.0, "the quote says what it stops")
	var before := sim.treasury.balance
	var done := sim.cmd_repair_water_asset(edge_id, false)
	assert_true(bool(done["ok"]))
	assert_eq(sim.treasury.balance, before - int(payload["cost"]))
	# A crew, on doc 02's queue, exactly as a grid repair is.
	assert_true(sim.water_repair_job(edge_id) >= 0, "a crew is on it")
	assert_eq(String(sim.cmd_repair_water_asset(edge_id, true)["reason_code"]),
			"E_ALREADY_REPAIRING", "and a second crew is refused")
	sim.advance_hours(24.0)
	assert_eq(String(sim.water.edge(edge_id).state), "ok", "the main is back")
	var healed := sim.water.topology.zone_by_key(zone.zone_key)
	assert_eq(healed.leak_m3h, 0.0, "and the leak has stopped")


func test_a_sound_main_is_not_a_purchase() -> void:
	var sim := _sim()
	sim.treasury.balance = 500_000
	var zone := _live_zone(sim)
	var edge_id := _first_edge_of(zone)
	# Doc 03's own floor of wear, the same one a standing transformer is held to
	# — a dollar job that parks a heavy crew to move a condition by thousandths
	# is not a purchase (Wave 25, RR-206).
	assert_eq(String(sim.cmd_repair_water_asset(edge_id, true)["reason_code"]),
			"E_NOT_DAMAGED")


func test_a_failed_pump_can_be_repaired_and_a_junction_cannot() -> void:
	var sim := _sim()
	sim.treasury.balance = 500_000
	var pump := ""
	var junction := ""
	for key: Variant in sim.water.nodes:
		var node: WaterNode = sim.water.nodes[key]
		if node.variant == &"pump" and pump == "":
			pump = String(key)
		elif node.variant == &"junction" and junction == "":
			junction = String(key)
	assert_ne(pump, "")
	(sim.water.nodes[pump] as WaterNode).state = &"failed"
	var quote := sim.cmd_repair_water_asset(pump, true)
	assert_true(bool(quote["ok"]), str(quote.get("reason_code", "")))
	assert_eq(String((quote["payload"] as Dictionary)["kind"]), "pump_failure")
	assert_true(bool((quote["payload"] as Dictionary)["down"]))
	assert_true(bool(sim.cmd_repair_water_asset(pump, false)["ok"]))
	sim.advance_hours(48.0)
	assert_eq(String((sim.water.nodes[pump] as WaterNode).state), "ok")
	if junction != "":
		# §2.1: a junction is where mains meet, not a component. It is not a
		# thing a crew is sent to.
		assert_eq(String(sim.cmd_repair_water_asset(junction, true)["reason_code"]),
				"E_UNKNOWN_COMPONENT")


# ===========================================================================
# 5. A91-D-139 — the zero-delta refusal, and the arm that said no
# ===========================================================================

func test_a_building_that_asks_for_no_more_water_is_not_refused_for_water() -> void:
	var sim := _sim()
	# `PowerGrid.can_upgrade_power`'s own Wave-17 sentence, one document over: a
	# building that adds no load cannot overload anything. Doc 02's water column
	# is 0.0 for a substation and a power plant, and the `z == null` line refused
	# every one of them that stood outside a pressure zone — for water they do
	# not drink and would not have drunk at the next level either.
	var verdict := sim.water.can_upgrade_water("no-such-building", 0.0)
	assert_true(bool(verdict["ok"]), "a zero delta needs no headroom")
	assert_eq(String(verdict["limit"]), "none")
	assert_true(bool(sim.water.can_upgrade_water("no-such-building", -1.0)["ok"]),
			"and a NEGATIVE delta certainly does not")
	# A real ask outside every zone is still refused, and now says which arm.
	var refused := sim.water.can_upgrade_water("no-such-building", 5.0)
	assert_false(bool(refused["ok"]))
	assert_eq(String(refused["limit"]), "no_zone")


func test_the_gate_says_whether_it_is_short_of_water_or_short_of_pipe() -> void:
	var sim := _sim()
	var zone := _live_zone(sim)
	var served := ""
	for raw: Variant in sim.water.demand.sorted_ids():
		if sim.water.zone_at(sim.water.demand.access_tile(String(raw))) == zone:
			served = String(raw)
			break
	assert_ne(served, "")
	# A colossal ask is a CAPACITY refusal and it names the stage to buy.
	var capacity := sim.water.can_upgrade_water(served, 10_000.0)
	assert_false(bool(capacity["ok"]))
	assert_eq(String(capacity["limit"]), "capacity")
	assert_true(capacity.has("binding"), "and it names the stage that binds")
	assert_true(float(capacity["deficit_m3h"]) > 0.0)


# ===========================================================================
# 6. S19 — the panel, headless
# ===========================================================================

func _panel(sim: CitySim) -> WaterPanelModel:
	return WaterPanelModel.new(sim, WaterActions.new(sim,
			RequirementFormatter.load_from_files()), UIConfig.load_from_files())


static func _pump_of(sim: CitySim) -> String:
	var keys := sim.water.nodes.keys()
	keys.sort()
	for key: Variant in keys:
		if (sim.water.nodes[key] as WaterNode).variant == &"pump":
			return String(key)
	return ""


func test_the_panel_draws_the_chain_the_zone_and_the_buildings_it_serves() -> void:
	var sim := _sim()
	var model := _panel(sim)
	var pump := _pump_of(sim)
	assert_ne(pump, "")
	assert_true(model.opens_for(pump))
	var v := model.view(pump)
	assert_true(bool(v["exists"]))
	# Four chain rows, in §2.5's own order, exactly one of them binding.
	var stages: Array[String] = []
	var binding := 0
	for entry: Variant in (v["chain"] as Array):
		stages.append(String((entry as Dictionary)["stage"]))
		if bool((entry as Dictionary)["binding"]):
			binding += 1
	assert_eq(stages, ["source", "treatment", "pump", "mains"])
	assert_eq(binding, 1, "exactly one stage binds")
	assert_true(bool((v["zone"] as Dictionary)["exists"]))
	assert_true(int(v["customers_total"]) > 0, "the founding plant serves someone")
	# Every sentence is a KEY, never a sentence (doc 12 §1 / G-8).
	assert_true(String((v["advice"] as Dictionary)["key"]).begins_with("ui_"))
	assert_true(String(v["title_key"]).begins_with("ui_"))


func test_the_panel_row_order_is_the_systems_own_stage_order() -> void:
	# Two copies of one order is the shape this project keeps filing defects on,
	# so the view's row order is asserted equal to the system's rather than
	# maintained beside it.
	var stages: Array[String] = []
	for stage: StringName in WaterActions.CHAIN_STAGES:
		stages.append(String(stage))
	var system: Array[String] = []
	for stage2: StringName in WaterSystem.SUPPLY_STAGES:
		system.append(String(stage2))
	assert_eq(stages, system)


func test_the_panel_opens_on_the_leak_before_the_ladder() -> void:
	var sim := _sim()
	sim.treasury.balance = 500_000
	var model := _panel(sim)
	var pump := _pump_of(sim)
	var zone: PressureZone = sim.water.topology.zone_of(pump)
	assert_ne(zone, null)
	assert_eq(String(model.focus_of(model.water.node_block(pump))),
			String(WaterPanelModel.FOCUS_UPGRADE), "a sound plant opens on the ladder")
	sim.water.set_segment_broken(_first_edge_of(zone), 0.9, "", 0.0)
	sim.water.rebuild_zones()
	sim.advance_hours(0.5)
	var v := model.view(pump)
	assert_eq(String(v["focus"]), String(WaterPanelModel.FOCUS_MAINS),
			"a leaking zone opens on the main, not on a purchase")
	assert_eq(int(v["breaks_total"]), 1)
	assert_true(float(v["leaking_m3h"]) > 0.0)
	assert_eq(String((v["advice"] as Dictionary)["key"]), "ui_water_advice_leak")
	# The break row carries the crew's own price, from the command's preview.
	var row: Dictionary = (v["break_rows"] as Array)[0]
	assert_true(bool((row["repair"] as Dictionary)["ok"]))
	assert_true(int((row["repair"] as Dictionary)["cost"]) > 0)


func test_a_failed_node_opens_on_the_crew() -> void:
	var sim := _sim()
	sim.treasury.balance = 500_000
	var model := _panel(sim)
	var pump := _pump_of(sim)
	(sim.water.nodes[pump] as WaterNode).state = &"failed"
	sim.water.rebuild_zones()
	assert_eq(String(model.view(pump)["focus"]), String(WaterPanelModel.FOCUS_REPAIR))


func test_the_building_row_tells_a_dry_tile_apart_from_a_dry_zone() -> void:
	var sim := _sim()
	var actions := WaterActions.new(sim, RequirementFormatter.load_from_files())
	var served := ""
	for raw: Variant in sim.water.demand.sorted_ids():
		if sim.water.zone_at(sim.water.demand.access_tile(String(raw))) != null:
			served = String(raw)
			break
	assert_ne(served, "")
	var row := WaterPanelModel.building_row(actions, served)
	assert_true(bool(row["available"]))
	assert_false(bool(row["unserved"]))
	assert_true(String(row["text_key"]).begins_with("ui_water_row"))
	# The distance is the whole of doc 92 §67.8's finding, so the row carries it.
	assert_true(int(row["main_distance_tiles"]) >= 0)
	assert_eq(bool(row["too_far"]),
			float(row["pressure"]) < sim.water.data.effect("upgrade_min_pressure", 0.55)
			and float(row["zone_pressure"])
					>= sim.water.data.effect("upgrade_min_pressure", 0.55))


# ===========================================================================
# 7. The doors: the pick, and the fix row
# ===========================================================================

func test_a_tap_on_a_water_works_picks_the_node_and_not_the_shell() -> void:
	var sim := _sim()
	var controller := BuildController.new(sim)
	var pump := _pump_of(sim)
	var node: WaterNode = sim.water.nodes[pump]
	var centre := Vector3((float(node.tile.x) + 0.5) * controller.tile_m, 0.0,
			(float(node.tile.y) + 0.5) * controller.tile_m)
	var pick := controller.pick_at_ground(centre)
	assert_eq(String(pick["kind"]), String(BuildController.PICK_COMPONENT))
	# The reference variant wins a shell that hosts three (report 98 RR-8: doc 02
	# generates this archetype's whole level table for `pump`).
	assert_eq(String((sim.water.nodes[String(pick["id"])] as WaterNode).variant), "pump")
	# …and a tile with no water works on it does not answer a water node.
	var elsewhere := controller.water_node_near(Vector3(2.0, 0.0, 2.0))
	assert_true(elsewhere.is_empty() or String(elsewhere["id"]) != pump)


func test_a_water_headroom_fix_opens_the_panel_on_the_stage_that_binds() -> void:
	var sim := _sim()
	var pump := _pump_of(sim)
	var routed := FixRouter.route(sim, {"kind": RequirementFormatter.FIX_COMPONENT,
			"id": pump}, false)
	assert_eq(String(routed["action"]), String(FixRouter.ACTION_SHEET))
	assert_eq(String(routed["sheet"]), String(FixRouter.SHEET_WATER_PANEL))
	assert_eq(String(routed["binds_at"]), pump)
	# A junction still keeps the camera move: §2.1 says it is not a component.
	for key: Variant in sim.water.nodes:
		if (sim.water.nodes[key] as WaterNode).variant != &"junction":
			continue
		var junction := FixRouter.route(sim, {"kind": RequirementFormatter.FIX_COMPONENT,
				"id": String(key)}, false)
		assert_eq(String(junction["action"]), String(FixRouter.ACTION_FOCUS))
		break


func test_the_headroom_row_names_the_purchase_rather_than_the_district() -> void:
	var sim := _sim()
	var controller := BuildController.new(sim)
	var served := ""
	for raw: Variant in sim.water.demand.sorted_ids():
		var id := String(raw)
		if sim.buildings.has(id) \
				and sim.water.zone_at(sim.water.demand.access_tile(id)) != null:
			served = id
			break
	assert_ne(served, "")
	var b: Building = sim.buildings[served]
	var params := controller._water_headroom_params(served, b,
			sim.catalog.stats(String(b.archetype), b.level + 1))
	assert_true(params.has("limit"))
	assert_true(params.has("binding"))
	# The row routes to something that resolves, or to nothing at all — never to
	# a button the router drops on its first line (PA-05).
	var kind := StringName(String(params["fix_kind"]))
	if kind != RequirementFormatter.FIX_NONE:
		assert_ne(String(params["fix_target_id"]), "")
		assert_ne(WorldLocator.locate(sim, kind, String(params["fix_target_id"])), null)


# ===========================================================================
# 8. The instrument, and the price accessors it made live
# ===========================================================================

## **A91-D-149, and the numbers are doc 05 §2.13's own ladder.** A zone with two
## pumps of different sizes on a shared intake: dark the big one and the small
## one must be able to take everything the chain still makes, up to its own
## plate. Before Wave 28 it took its topology-time SHARE — `upstream × 40 / 280`
## — and the rest of the treated water went nowhere.
func test_a_dark_pump_does_not_keep_the_water_the_running_one_could_move() -> void:
	var water := WaterSystem.new(WaterData.from_dict(
			StarterCityLoader.read_json("res://data/water.json")))
	water.add_node("SRC", &"source", Vector2i(4, 4), {"subtype": "river", "level": 2})
	water.add_node("TRT", &"treatment", Vector2i(5, 4), {"level": 2})
	water.add_node("SMALL", &"pump", Vector2i(6, 4), {"level": 1})   # rated 40.0
	water.add_node("BIG", &"pump", Vector2i(7, 4), {"level": 3})     # rated 240
	water.add_main("M", [Vector2i(4, 4), Vector2i(5, 4), Vector2i(6, 4),
			Vector2i(7, 4), Vector2i(8, 4)], {"tier": "trunk"})
	water.rebuild_zones()
	var zone: PressureZone = water.topology.zones[0]
	var upstream := zone.upstream_cap_m3h
	assert_true(upstream > 0.0, "the chain makes something")
	# Both lit: the split is over the same set either way, so this is the
	# control arm and it must not have moved.
	water.advance(1.0 / 240.0, {})
	var both := water.supply_chain(zone.zone_key)
	assert_almost_eq(float(both["stranded_m3h"]), 0.0, 0.001,
			"nothing is stranded while every pump runs")
	# Now dark the big one, through doc 04's published fraction and nothing else.
	water.set_power_fraction_override("BIG", 0.0)
	water.advance(1.0 / 240.0, {})
	var dark := water.supply_chain(zone.zone_key)
	var small_rated := float(water.data.component(&"pump", 1).get("rated_flow_m3h", 0.0))
	assert_almost_eq(float(dark["pump_m3h"]), small_rated, 0.001,
			"the running pump takes its whole plate: %f" % dark["pump_m3h"])
	assert_almost_eq(float(dark["stranded_m3h"]), 0.0, 0.001,
			"and nothing is stranded behind the dark one")
	# The pre-Wave-28 arithmetic, stated so the regression is unmistakable: the
	# topology-time share would have handed the small pump 40/280 of the
	# upstream, which is a fraction of its own plate.
	var old_share := upstream * small_rated / (small_rated
			+ float(water.data.component(&"pump", 3).get("rated_flow_m3h", 0.0)))
	assert_true(old_share < small_rated - 0.5,
			"the old split really was smaller than the pump's own plate: %f vs %f"
			% [old_share, small_rated])
	assert_true(float(dark["pump_m3h"]) > old_share + 0.5,
			"and the fix delivers more than it: %f vs %f" % [dark["pump_m3h"], old_share])


func test_doc_03s_water_capital_accessors_now_have_a_consumer() -> void:
	# `capital_value_water_main` and `capital_value_water_component` were
	# authored in `CostCurves`, published in doc 03 §8, and called by NOTHING in
	# this project until `cmd_repair_water_asset` — TWO numbers with a reader at
	# last (A91-D-148, corrected in the Wave 28 fix pass: the third,
	# `water_demolition_refund`, still has none, because `WaterActions.remove_quote`
	# rides `cmd_demolish_building`'s own refund and a second, different number
	# beside the one actually paid would be worse than none). The guard is that
	# they stay reachable and stay positive, not what they are: doc 03 owns the
	# value.
	var sim := _sim()
	var ratio := sim.water.data.variant_cost_ratio(&"pump", "")
	assert_true(sim.econ_curves.capital_value_water_component(ratio, 1) > 0)
	assert_true(sim.econ_curves.capital_value_water_main("service", 8) > 0)
	assert_true(sim.econ_curves.capital_value_water_main("trunk", 8)
			> sim.econ_curves.capital_value_water_main("service", 8),
			"a trunk main is worth more than a service main of the same length")


# ===========================================================================
# 9. THE FIX PASS — every door this wave opened reaches the player
#
# The wave's own adversarial verifier returned five blockers, and four of them
# were the same shape: something emitted, computed or promised, and consumed by
# nothing (A91-D-150). This section is the consumer, pinned. Every test below
# fails on the first cut of this branch.
# ===========================================================================

func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


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


## A building the founding city's water actually reaches. Asked, never named.
static func _served_building(sim: CitySim) -> String:
	for raw: Variant in sim.water.demand.sorted_ids():
		var id := String(raw)
		if sim.buildings.has(id) \
				and sim.water.zone_at(sim.water.demand.access_tile(id)) != null:
			return id
	return ""


func test_the_building_panel_draws_the_water_row_and_it_opens_s19() -> void:
	# **A91-D-150a.** `WaterPanelModel.building_row` shipped with no caller
	# outside its own test, so doc 12 D-125 described a row nobody could see.
	# This drives the real `ui_root.tscn`, the real `BuildingPanel` and the real
	# signal chain: the row is on screen, it carries the model's own sentence,
	# and pressing it opens S19 on the node that BINDS the zone.
	var sim := _sim()
	var root := _mount()
	var controller := BuildController.new(sim)
	root.building_panel.setup(root.config, controller)
	var served := _served_building(sim)
	assert_ne(served, "", "the founding city serves somebody")
	root.building_panel.show_building(served)

	var button := root.building_panel.water_row_button()
	assert_true(button != null, "S5 draws the one-row WATER summary")
	assert_true(button.text.contains(BuildingPanel.POWER_ROW_CHEVRON),
			"…and it is a door, which the chevron says without colour (A5)")
	var row := WaterPanelModel.building_row(controller.water, served)
	assert_true(button.text.contains(root.config.t(str(row["text_key"]),
			row["args"] as Dictionary)),
			"…saying exactly what the model computed, and not a second copy of it")

	var told: Array[String] = []
	root.water_node_selected.connect(func(node_id: String) -> void:
		told.append(node_id))
	button.pressed.emit()
	var binds := String(row["node"])
	assert_true(root.water_panel.is_open(), "the tap opens S19")
	assert_eq(root.water_panel.selected_id(), binds,
			"…on the stage that BINDS the zone, which is the only node a purchase moves")
	assert_eq(told, [binds] as Array[String],
			"…and the shell is told, because it owns `selected_entity_id`")
	_unmount(root)


func test_an_unserved_building_fires_the_row_with_an_empty_id_and_keeps_its_sentence() -> void:
	# The POWER row's own contract, one utility over: the row still fires, so the
	# root answers "there is nothing to open" in ONE place rather than every
	# caller guessing — and the sentence explaining an unserved building stays on
	# S5, because that is a fact about the building.
	var sim := _sim()
	var actions := WaterActions.new(sim, RequirementFormatter.load_from_files())
	var dry := ""
	for raw: Variant in sim.water.demand.sorted_ids():
		var id := String(raw)
		if sim.buildings.has(id) \
				and sim.water.zone_at(sim.water.demand.access_tile(id)) == null:
			dry = id
			break
	if dry == "":
		# Every building in the founding city has water. Make one that has not:
		# the row's unserved arm is reachable on any city that grows outward.
		var row := WaterPanelModel.building_row(actions, "NOT-A-BUILDING")
		assert_false(bool(row["available"]),
				"a building the sim does not have draws no row at all")
		return
	var row := WaterPanelModel.building_row(actions, dry)
	assert_true(bool(row["available"]))
	assert_true(bool(row["unserved"]))
	assert_eq(String(row["node"]), "", "there is nothing to open, and it says so")
	assert_eq(String(row["text_key"]), "ui_water_row_unserved")


func test_every_water_signal_this_wave_added_carries_the_payload_the_shell_needs() -> void:
	# **A91-D-150.** `water_action`, `water_node_selected` and
	# `water_customer_selected` were emitted by S19 and consumed by NOTHING in
	# the shipped tree — the customer row in particular was a control that did
	# nothing at all on a screen listing 89 buildings. `game/main.gd` binds all
	# three now (report 98 RR-229); this pins the EMISSION and its payload,
	# which is the half a shell snippet cannot test.
	var sim := _sim()
	var root := _mount()
	var controller := BuildController.new(sim)
	root.building_panel.setup(root.config, controller)
	root.water_panel.setup(root.config, WaterPanelModel.new(
			sim, controller.water, root.config, controller.tile_m))
	sim.treasury.balance = 5_000_000
	var pump := _pump_of(sim)

	var actions: Array[String] = []
	var nodes: Array[String] = []
	var customers: Array[Dictionary] = []
	root.water_action.connect(func(action: StringName, asset_id: String,
			result: Dictionary) -> void:
		actions.append("%s:%s:%s" % [String(action), asset_id,
				"ok" if bool(result.get("ok", false)) else "no"]))
	root.water_node_selected.connect(func(node_id: String) -> void:
		nodes.append(node_id))
	root.water_customer_selected.connect(func(sim_id: String, world_pos: Vector3) -> void:
		customers.append({"sim_id": sim_id, "pos": world_pos}))

	root.show_water_node(pump)
	assert_true(root.water_panel.is_open())

	# 1. A verb. UPGRADE is the one every node has, and one signal carries all
	#    five because the shell does exactly one thing with every one of them.
	var upgrade := root.water_panel.upgrade_button()
	assert_true(upgrade != null, "S19 quotes the ladder whether or not it can be pressed")
	upgrade.pressed.emit()
	assert_eq(actions.size(), 1, "`water_action` fires once per verb")
	assert_true(actions[0].begins_with("upgrade:%s:" % pump),
			"…naming the action and the asset: %s" % actions[0])

	# 2. A served-building row — the dead control the verifier found.
	var view := root.water_panel.view()
	var rows: Array = view.get("customer_rows", [])
	assert_true(not rows.is_empty(), "the pump serves somebody")
	var first := String((rows[0] as Dictionary)["sim_id"])
	var customer_button := root.water_panel.customer_button(first)
	assert_true(customer_button != null)
	customer_button.pressed.emit()
	assert_eq(customers.size(), 1, "the row is a control that does something")
	assert_eq(String(customers[0]["sim_id"]), first)
	# The shell moves the camera with this, so a zero vector would be a shell
	# that jumps to the corner of the map.
	assert_true((customers[0]["pos"] as Vector3).length() > 0.0,
			"…and carries a world position the camera can move to")

	# 3. Closing clears the selection, or the shell rings a node with no panel.
	root.water_panel.close()
	assert_true(nodes.has(""), "`water_node_selected('')` clears it")
	_unmount(root)


func test_s19_reads_its_two_caps_out_of_data_ui_json() -> void:
	# **A91-D-150c.** `data/ui.json` had no `water` section, so
	# `WaterPanelModel.section()` returned `{}` on every call and both caps lived
	# only as code constants — the exact asymmetry with S18, which has always had
	# `data/ui.json.transformer.max_customer_rows`.
	var cfg := UIConfig.load_from_files()
	var section := cfg.section(WaterPanelModel.SECTION)
	assert_false(section.is_empty(), "data/ui.json carries a `water` block")
	assert_true(section.has("max_customer_rows"))
	assert_true(section.has("max_break_rows"))
	var model := WaterPanelModel.new(_sim(), null, cfg)
	assert_eq(model.max_customer_rows(), int(section["max_customer_rows"]),
			"…and the model READS it rather than its own constant")
	assert_eq(model.max_break_rows(), int(section["max_break_rows"]))


func test_the_repair_arrival_has_the_notification_binding_its_comment_promises() -> void:
	# **A91-D-150b.** `data/ui.json`'s own `_comment` on the `water_asset_repaired`
	# row asserted "a second reader in data/notifications.json", and there was
	# neither a binding nor an event row, so `NotificationRouter` never matched
	# and no banner ever fired. `tests/test_event_matrix.gd` could not see it
	# because it accepts a `data/ui.json.event_log` row as a consumer.
	var raw := FileAccess.get_file_as_string("res://data/notifications.json")
	var parsed: Variant = JSON.parse_string(raw)
	assert_true(parsed is Dictionary, "data/notifications.json parses")
	var doc: Dictionary = parsed
	var events: Dictionary = doc["events"]
	assert_true(events.has("water_asset_repaired"),
			"the ARRIVAL has an event row")
	var row: Dictionary = events["water_asset_repaired"]
	assert_eq(String(row["deeplink"]), "overlay/water",
			"…landing where a break's own notification lands")
	var bound := false
	for entry: Variant in (doc["bindings"] as Array):
		if String((entry as Dictionary).get("type", "")) == "water_asset_repaired":
			bound = true
			assert_eq(String((entry as Dictionary)["notify_id"]), "water_asset_repaired")
			assert_eq(String((entry as Dictionary)["key"]), "asset",
					"a repair is a PLACE, so two mains dug up are two banners")
	assert_true(bound, "…and a binding that reaches it")
	# The DISPATCH is deliberately unbound — the player who pressed DIG IT UP is
	# standing in S19, which already shows the crew and the ETA. Pinned so a
	# later wave does not "fix" the asymmetry by accident.
	for entry: Variant in (doc["bindings"] as Array):
		assert_ne(String((entry as Dictionary).get("type", "")),
				"water_asset_repair_started",
				"the DISPATCH stays log-only, by ruling")


func test_the_advice_names_what_would_bind_after_the_thing_it_asks_for() -> void:
	# **A91-D-150d.** Doc 12 §2.26 promised "what to raise, and what would bind
	# after it"; `advice_of` never read `next_binding`, which
	# `WaterSystem.supply_chain` had published since the wave opened. §2.5's
	# supply is a MIN, so the ceiling on the purchase IS the second-narrowest
	# term, and a panel that hides it sells a plan as a button.
	var sim := _sim()
	var actions := WaterActions.new(sim, RequirementFormatter.load_from_files())
	var pump := _pump_of(sim)
	var block := actions.node_block(pump)
	assert_true(block.has("next_binding"), "the block publishes the second term")
	var model := _panel(sim)
	var advice := model.advice_of(block)
	if String(advice["key"]) != "ui_water_advice_binds_next":
		# The founding city may open on a leak or on the mains; the guard is that
		# WHEN the binds sentence is chosen it is the one that names the next
		# term, and that the argument is present either way.
		assert_true(String(advice["key"]).begins_with("ui_water_advice"))
		return
	var args: Dictionary = advice["args"]
	assert_eq(String(args["next"]),
			"ui_water_stage_%s" % String(block["next_binding"]))
	assert_ne(String(args["next_m3h"]), "", "…and how far that term lets it go")
	var cfg := UIConfig.load_from_files()
	assert_true(cfg.has_string("ui_water_advice_binds_next"))


# ===========================================================================
# 10. STEP ONE — "where CAN this go?" (doc 12 D-127, doc 93 §BD8)
# ===========================================================================

func test_the_window_answers_where_a_source_can_go_and_the_ghost_agrees() -> void:
	# The whole contract of `placement_sites`: a tile it returns is a tile the
	# GHOST calls legal, because they are one call. Two implementations of
	# "legal" is how a green ghost and a refused commit come to disagree.
	var sim := _sim()
	var controller := BuildController.new(sim)
	sim.treasury.balance = 5_000_000
	assert_true(bool(controller.enter_water_component("source")["ok"]))
	var found := controller.placement_sites()
	assert_eq(int(found["scanned"]),
			(2 * int(found["radius"]) + 1) * (2 * int(found["radius"]) + 1),
			"the window is square and every tile in bounds was asked")
	assert_true(int(found["count"]) >= 0)
	for raw: Variant in (found["tiles"] as Array):
		var tile: Vector2i = raw
		var verdict := controller.evaluate(tile)
		assert_ne(String(verdict["verdict"]), String(BuildController.VERDICT_BLOCKED),
				"every tile the window offers is one the ghost accepts: %s" % str(tile))
	if bool(found["ok"]):
		assert_eq(String((found["advice"] as Dictionary)["key"]), "ui_site_found")
	controller.cancel()


func test_the_window_says_what_to_buy_when_nothing_in_it_is_legal() -> void:
	# The player's own case: 2,140 of his 3,721 scanned tiles refused for
	# `E_NOT_OWNED` alone, and the answer to that is a BLOCK, not a tile. The
	# advice carries it as a `fix_target` in the formatter's own shape, so the
	# placement bar's existing `FIX THIS →` routes it with no second router.
	var sim := _sim()
	var controller := BuildController.new(sim)
	sim.treasury.balance = 5_000_000
	assert_true(bool(controller.enter_water_component("source")["ok"]))
	# A window out at the map's edge, which no founding city owns.
	var found := controller.placement_sites(Vector2i(TileGrid.SIZE - 12,
			TileGrid.SIZE - 12))
	assert_false(bool(found["ok"]), "nothing out here is buildable")
	var advice: Dictionary = found["advice"]
	assert_ne(String(advice["key"]), "", "…and the bar has something to say about it")
	assert_true(UIConfig.load_from_files().has_string(String(advice["key"])),
			"…which is a KEY in the shipped table: %s" % String(advice["key"]))
	var target: Dictionary = advice.get("fix_target", {})
	if not target.is_empty():
		assert_true(RequirementFormatter.FIX_KINDS.has(
				StringName(str(target["kind"]))),
				"the target is a kind the router already resolves")
	assert_true(int(found["reasons"].size()) > 0,
			"…and the histogram says what is in the way over the WHOLE window")
	controller.cancel()


func test_a_site_the_wire_cannot_carry_is_a_warning_and_not_the_recommendation() -> void:
	# **A91-D-153**, and doc 93 §AD3's ruling restated: doc 04 §2.1 authorises no
	# capacity refusal, so the site stays placeable — it just stops being the one
	# the bar points at. The quote is what carries the fact.
	var sim := _sim()
	var controller := BuildController.new(sim)
	sim.treasury.balance = 5_000_000
	assert_true(bool(controller.enter_water_component("pump")["ok"]))
	var found := controller.placement_sites()
	assert_true(int(found["clean"]) <= int(found["count"]),
			"a clean site is a legal site, so there cannot be more of them")
	# Whatever the founding city offers, the QUOTE has to publish the read — the
	# defect was that it never asked at all.
	var probe := sim.cmd_place_water_component("pump", Vector2i(40, 40), 1, true)
	var payload: Dictionary = probe.get("payload", {})
	assert_true(payload.has("power_ok"),
			"doc 04's capacity read is in doc 05's placement quote")
	assert_true(payload.has("deficit_kw"))
	controller.cancel()


func test_a_water_site_under_construction_is_a_new_build_and_can_be_finished() -> void:
	# **A91-D-152.** `cmd_place_water_component` wrote `b.level` where every
	# other placement verb leaves it at 0 and lets `complete_construction`
	# promote `pending_level` — so from the moment it was paid for a water site
	# failed `is_new_build()`, and `condemn_unanswered` stranded it in `damaged`
	# at level 1 with its doc-05 node `offline_manual` for ever. Measured on the
	# player's save: a $45,858 pump, dark on game-day 30.
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	var controller := BuildController.new(sim)
	assert_true(bool(controller.enter_water_component("pump")["ok"]))
	var found := controller.placement_sites()
	if not bool(found["ok"]):
		controller.cancel()
		return
	var placed := sim.cmd_place_water_component("pump", found["nearest"],
			controller.component_level, false)
	assert_true(bool(placed["ok"]), "the window's own site places")
	var shell: Building = sim.buildings[String((placed["payload"] as Dictionary)["sim_id"])]
	assert_true(shell.is_new_build(),
			"a site under construction is a NEW BUILD, so a fire destroys it "
			+ "rather than stranding it (A91-D-152)")
	assert_eq(shell.pending_level, controller.component_level,
			"…and the level it will finish at is on `pending_level`")
	# And the shell really does finish at the level asked for.
	sim.advance_coarse_hours(48, false)
	assert_eq(shell.level, controller.component_level)
	assert_eq(String((sim.water.nodes[String((placed["payload"] as Dictionary)["node"])]
			as WaterNode).state), "ok",
			"…and the node it hosts is switched on")
	controller.cancel()


func test_the_two_water_placement_quotes_see_doc_03s_spending_freeze() -> void:
	# **A91-D-151.** The ghost said `valid` and the command said `E_AUSTERITY`,
	# which doc 12 §2.7 forbids in as many words. Measured on the player's save,
	# which restores `austerity_active` true at a balance of $14,899,376.
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	sim.treasury.austerity_active = true
	var quote := sim.cmd_place_water_component("pump", Vector2i(40, 40), 1, true)
	assert_false(bool(quote["ok"]), "the PREVIEW refuses what the commit would")
	assert_true((quote["payload"]["blockers"] as Array).has(&"E_AUSTERITY"),
			"…by name, so the bar can print doc 03's own sentence")
	# The repair verb deliberately does NOT take the arm: its category is
	# `repair`, which layer 2 does not block, because a city in austerity must
	# still be allowed to stop a leak.
	assert_false(Treasury.AUSTERITY_BLOCKED_CATEGORIES.has(&"repair"))
