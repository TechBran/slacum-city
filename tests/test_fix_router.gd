extends SimTest
## `FixRouter` — PA-05's router half, tested per `FIX_*` kind.
##
## The audit's own acceptance criterion, quoted: *"every `CODE_TABLE` row's
## `fix_target`, built by the real `_check_params` against a booted sim, resolves
## or is `FIX_NONE` — never a silent null."* `test_no_real_checklist_row_falls_
## through_silently` below is that test, run against every building in the
## starter city.


func _sim() -> CitySim:
	return CitySim.boot_from_files()


func _target(kind: StringName, id: String) -> Dictionary:
	return {"kind": kind, "id": id}


# ------------------------------------------------------ the two dead branches

func test_a_transformer_id_on_a_BUILDING_row_now_moves_the_camera() -> void:
	# **PA-05, first half.** `build_controller.gd` fills `fix_target_id` from
	# `sim.grid.attachment_of(sim_id)`, which returns `T-nn`;
	# `requirement_formatter.gd` maps `POWER_CAPACITY` to a BUILDING kind; the
	# shell then did `sim.buildings.get(id)` and returned. Button depressed,
	# nothing happened, no toast, no haptic.
	var sim := _sim()
	var attached := String(sim.grid.attachment_of("APT-001"))
	var action := FixRouter.route(sim, _target(RequirementFormatter.FIX_BUILDING, attached))
	assert_eq(action["action"], FixRouter.ACTION_FOCUS)
	assert_true(action["world_pos"] is Vector3)
	assert_eq(action["world_pos"],
			WorldLocator.locate(sim, WorldLocator.KIND_COMPONENT, attached),
			"and it lands on the transformer, not on tile 0,0")


func test_an_empty_id_is_a_NAMED_refusal_not_a_silent_return() -> void:
	# **PA-05, second half.** `E_AVENUE`'s params carry no `fix_target_id`, so
	# the formatter emits `id == ""` and the shell's first line was
	# `if id == "" … return`. The panel drew the button anyway, because
	# `building_panel.gd` gates on `kind != FIX_NONE` alone.
	var sim := _sim()
	var action := FixRouter.route(sim,
			_target(RequirementFormatter.FIX_ROAD_SEGMENT, ""))
	assert_eq(action["action"], FixRouter.ACTION_NONE)
	assert_eq(action["reason"], FixRouter.REASON_EMPTY_ID,
			"the caller's params are wrong, and the router says so")
	assert_false(FixRouter.can_route(sim, _target(RequirementFormatter.FIX_ROAD_SEGMENT, "")),
			"and a panel that asked first would not have drawn the button")


func test_E_AVENUE_routes_once_its_params_carry_the_building() -> void:
	# The params half is `ui/build_controller.gd`'s (lane L): one added
	# `"fix_target_id": sim_id` on the `E_AVENUE` row. The ROUTER half is ready
	# for it now — a building id on a road-segment target answers the nearest
	# avenue.
	var sim := _sim()
	var action := FixRouter.route(sim,
			_target(RequirementFormatter.FIX_ROAD_SEGMENT, "APT-001"))
	assert_eq(action["action"], FixRouter.ACTION_FOCUS)
	var tile := TileGrid.tile_at(action["world_pos"] as Vector3)
	assert_eq(sim.world.grid.road_class_at(tile.x, tile.y), TileGrid.ROAD_AVENUE)


# ---------------------------------------------------------------- every kind

func test_a_building_target_focuses_its_lot_centre() -> void:
	var sim := _sim()
	var action := FixRouter.route(sim, _target(RequirementFormatter.FIX_BUILDING, "APT-001"))
	assert_eq(action["action"], FixRouter.ACTION_FOCUS)
	assert_almost_eq((action["world_pos"] as Vector3).x, 328.0, 0.001)


func test_a_block_target_focuses_the_block() -> void:
	var sim := _sim()
	var action := FixRouter.route(sim, _target(RequirementFormatter.FIX_BLOCK, "B_2_2"))
	assert_eq(action["action"], FixRouter.ACTION_FOCUS)
	assert_almost_eq((action["world_pos"] as Vector3).x, 320.0, 0.001)


func test_a_tile_target_focuses_the_tile() -> void:
	var sim := _sim()
	var action := FixRouter.route(sim, _target(RequirementFormatter.FIX_TILE, "10,12"))
	assert_eq(action["action"], FixRouter.ACTION_FOCUS)
	assert_almost_eq((action["world_pos"] as Vector3).x, 84.0, 0.001)


func test_a_district_target_focuses_the_district() -> void:
	var sim := _sim()
	var action := FixRouter.route(sim,
			_target(RequirementFormatter.FIX_DISTRICT, "D_DOWNTOWN"))
	assert_eq(action["action"], FixRouter.ACTION_FOCUS)
	assert_almost_eq((action["world_pos"] as Vector3).x, 512.0, 0.001)


func test_a_repair_target_is_a_VERB_with_a_price_on_it() -> void:
	# `E_CONDITION`'s fix is not a place, it is a PURCHASE. The router says which
	# verb and what it costs; the panel spends.
	var sim := _sim()
	var action := FixRouter.route(sim, _target(RequirementFormatter.FIX_REPAIR, "FIRE-1"))
	assert_eq(action["action"], FixRouter.ACTION_VERB)
	assert_eq(action["verb"], FixRouter.VERB_REPAIR)
	assert_eq((action["args"] as Dictionary)["sim_id"], "FIRE-1")
	assert_true(action.has("quote"), "a verb action always carries its quote")
	# FIRE-1 is at condition 1.0, so the quote REFUSES — and a refusal with a
	# reason is exactly what the strip needs to say "nothing to repair".
	var quote: Dictionary = action["quote"]
	assert_false(bool(quote["ok"]))
	assert_eq(quote["reason_code"], &"E_NOT_DAMAGED")


func test_a_power_target_opens_the_panel_pre_armed_on_the_component_that_binds() -> void:
	# `POWER_CAPACITY` is a purchase too (A91-D-54), and **its id is the
	# TRANSFORMER**, not the building: `build_controller.gd` fills it from
	# `sim.grid.attachment_of(sim_id)`. The router names the surface and the arm
	# rather than a camera move, carries the component as `binds_at`, and does
	# NOT pretend the component id is a building id — which is the bug PA-05 is.
	var sim := _sim()
	var binds_at := String(sim.grid.attachment_of("APT-001"))
	assert_eq(binds_at, "T-02", "the real payload for this row")
	var action := FixRouter.route(sim, _target(RequirementFormatter.FIX_POWER, binds_at))
	assert_eq(action["action"], FixRouter.ACTION_SHEET)
	assert_eq(action["sheet"], FixRouter.SHEET_BUILDING_PANEL)
	assert_eq(action["arm"], FixRouter.ARM_POWER_FIX)
	assert_eq(action["binds_at"], binds_at)
	assert_eq(action["world_pos"],
			WorldLocator.locate(sim, WorldLocator.KIND_COMPONENT, binds_at),
			"and the wall has a place, for a surface that wants to show it")
	assert_false(action.has("sim_id"),
			"the component id is NOT a building id and is never used as one")
	assert_false(action.has("quote"), "no building, no quote")


func test_a_power_target_quotes_only_when_the_caller_names_the_building() -> void:
	# The quote needs `cmd_fix_power_capacity(sim_id)`, and `sim_id` is a
	# BUILDING. A caller that knows it says so; the router never invents it.
	var sim := _sim()
	var action := FixRouter.route(sim, {"kind": RequirementFormatter.FIX_POWER,
			"id": String(sim.grid.attachment_of("APT-001")), "sim_id": "APT-001"})
	assert_eq(action["action"], FixRouter.ACTION_SHEET)
	assert_eq(action["sim_id"], "APT-001")
	assert_true(action.has("quote"))
	assert_eq(action["quote"]["reason_code"], &"E_NOT_BLOCKED",
			"APT-001 has headroom at L1, so the quote refuses by name")


# ---------------------------------------------------------------- refusals

func test_FIX_NONE_refuses_with_no_fix() -> void:
	var sim := _sim()
	var action := FixRouter.route(sim, _target(RequirementFormatter.FIX_NONE, "APT-001"))
	assert_eq(action["action"], FixRouter.ACTION_NONE)
	assert_eq(action["reason"], FixRouter.REASON_NO_FIX,
			"a row with no remedy is not a bug")
	assert_false(FixRouter.can_route(sim, _target(RequirementFormatter.FIX_NONE, "APT-001")))


func test_an_id_that_names_nothing_refuses_with_unresolved() -> void:
	var sim := _sim()
	for kind: StringName in [RequirementFormatter.FIX_BUILDING,
			RequirementFormatter.FIX_BLOCK, RequirementFormatter.FIX_DISTRICT,
			RequirementFormatter.FIX_REPAIR, RequirementFormatter.FIX_POWER]:
		# `FIX_POWER` resolves its id in ANY namespace (it is a component id in
		# practice), so the junk id has to name nothing anywhere.
		var action := FixRouter.route(sim, _target(kind, "NOPE-999"))
		assert_eq(action["reason"], FixRouter.REASON_UNRESOLVED,
				"%s with a junk id" % [kind])


func test_a_kind_the_router_has_never_met_refuses_by_name() -> void:
	var sim := _sim()
	var action := FixRouter.route(sim, _target(&"teleport", "APT-001"))
	assert_eq(action["reason"], FixRouter.REASON_UNKNOWN_KIND,
			"a new FIX_* added upstream fails loudly here")


func test_routing_before_boot_refuses_rather_than_crashing() -> void:
	var action := FixRouter.route(null, _target(RequirementFormatter.FIX_BUILDING, "APT-001"))
	assert_eq(action["reason"], FixRouter.REASON_NO_SIM)
	# FIX_NONE is answered before the sim is even consulted.
	assert_eq(FixRouter.route(null, _target(RequirementFormatter.FIX_NONE, ""))["reason"],
			FixRouter.REASON_NO_FIX)


func test_every_answer_carries_the_four_common_keys() -> void:
	var sim := _sim()
	for target: Dictionary in [_target(RequirementFormatter.FIX_NONE, ""),
			_target(RequirementFormatter.FIX_BUILDING, "APT-001"),
			_target(RequirementFormatter.FIX_POWER, "T-02"),
			_target(RequirementFormatter.FIX_REPAIR, "FIRE-1"),
			_target(&"teleport", "x")]:
		var action := FixRouter.route(sim, target)
		for key: String in ["action", "reason", "kind", "id"]:
			assert_true(action.has(key), "%s missing %s" % [target["kind"], key])


# ----------------------------------------------- the whole code table, for real

func test_every_declared_fix_kind_is_routed() -> void:
	# Totality over `RequirementFormatter`, not over the kinds the shell happens
	# to receive today: collect every distinct `fix` in `CODE_TABLE` and assert
	# none of them lands on `unknown_kind`.
	var sim := _sim()
	var kinds: Dictionary = {}
	for code: StringName in RequirementFormatter.codes():
		kinds[RequirementFormatter.fix_kind(code)] = true
	assert_true(kinds.size() >= 7, "the table declares at least the seven kinds")
	for kind: StringName in kinds:
		var action := FixRouter.route(sim, _target(kind, "APT-001"))
		assert_ne(action["reason"], FixRouter.REASON_UNKNOWN_KIND,
				"%s is declared in CODE_TABLE and unknown to the router" % [kind])
		assert_true(action.has("action"), "%s answered something" % [kind])


func test_no_real_checklist_row_falls_through_silently() -> void:
	# The audit's acceptance test, run against the REAL `_check_params` for every
	# building in the starter city: each row either has no fix (`FIX_NONE`), or
	# routes to an action, or refuses with a reason that names WHOSE bug it is.
	# `empty_id` is the params half (lane L); `unresolved` would be this lane's.
	var sim := _sim()
	var controller := BuildController.new(sim, RequirementFormatter.load_from_files())
	var rows_seen := 0
	var ids: Array = sim.buildings.keys()
	ids.sort()
	for sim_id: String in ids:
		var view: Dictionary = controller.upgrade_view(sim_id)
		for row: Dictionary in view.get("checklist", []):
			rows_seen += 1
			var action := FixRouter.route(sim, row["fix_target"], false)
			if String(action["action"]) != String(FixRouter.ACTION_NONE):
				continue
			assert_ne(action["reason"], FixRouter.REASON_UNRESOLVED,
					"%s row %s: id %s named nothing on the map"
							% [sim_id, row["canonical"], row["fix_target"]["id"]])
			assert_ne(action["reason"], FixRouter.REASON_UNKNOWN_KIND,
					"%s row %s: kind unknown to the router"
							% [sim_id, row["canonical"]])
	assert_true(rows_seen > 100, "the sweep actually ran (%d rows)" % rows_seen)


func test_the_checklist_sweep_still_finds_the_E_AVENUE_hole() -> void:
	# The params half is NOT this lane's, and the sweep must not pretend it is
	# fixed. `E_AVENUE` is a check only from level 4 (C-62), so upgrade a
	# building until the row appears, then assert the router names the hole.
	var sim := _sim()
	var formatter := RequirementFormatter.load_from_files()
	var row := formatter.format(&"E_AVENUE", {"avenue_distance_tiles": 9,
			"avenue_radius_tiles": 3, "to_level": 4, "tile": Vector2i(40, 33)})
	assert_eq(row["fix_target"]["kind"], RequirementFormatter.FIX_ROAD_SEGMENT)
	assert_eq(row["fix_target"]["id"], "", "the params half has not landed yet")
	assert_eq(FixRouter.route(sim, row["fix_target"])["reason"],
			FixRouter.REASON_EMPTY_ID)


# --------------------------------------------------------------- hash safety

func test_routing_never_moves_the_sim() -> void:
	# Every quote is a `preview: true` call, which returns before the first
	# mutation in both `cmd_repair_building` and `cmd_fix_power_capacity`.
	# Routing a fix target on a tap must not be a hash event.
	var sim := _sim()
	sim.advance_hours(3.0)
	var before := sim.state_hash()
	for target: Dictionary in [_target(RequirementFormatter.FIX_REPAIR, "FIRE-1"),
			{"kind": RequirementFormatter.FIX_POWER, "id": "T-02", "sim_id": "APT-001"},
			_target(RequirementFormatter.FIX_BUILDING, "APT-001"),
			_target(RequirementFormatter.FIX_ROAD_SEGMENT, "APT-001"),
			_target(RequirementFormatter.FIX_DISTRICT, "D_DOWNTOWN")]:
		FixRouter.route(sim, target)
	assert_eq(sim.state_hash(), before, "routing is a READ")
