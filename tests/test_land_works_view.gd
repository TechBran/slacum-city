extends SimTest
## Doc 11 §2.18 — `LandWorksView`, the layer that finally draws doc 09 §2.3's
## pipeline (ruling 93 §AZ4, report 98 §69 RR-211).
##
## Four things are held here:
##
##   1. **The budget.** Draw calls and instances per block at every one of the
##      six phases, as an explicit table — this is the measurement doc 11 §2.18
##      publishes, taken by the suite rather than by hand, so it cannot rot. A
##      city with nothing in flight costs ZERO buffers.
##   2. **The phase reads.** Brush leaves as CLEARING runs, base is laid as
##      ROAD_INSTALL runs, the trench opens as UTILITY_CORRIDOR runs, and READY
##      leaves nothing behind.
##   3. **The plant.** Each phase sends the machine its crew type names, through
##      `ConstructionVehicleView`'s per-site profile, and the two
##      `construction_crew` phases send none.
##   4. **It cannot move the sim.** The view's reads are interleaved into a
##      running city and the state hash is compared against a city that never
##      had a view at all — constitution §3, the same property
##      `tests/test_construction_living.gd` pins for the plant layer.

const PHASES: Array[StringName] = [
	&"SURVEY", &"CLEARING", &"GRADING", &"ROAD_INSTALL",
	&"UTILITY_CORRIDOR", &"FINAL_DEVELOPMENT",
]


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _view(sim: CitySim = null) -> LandWorksView:
	var view := LandWorksView.new()
	view.setup(StarterCityLoader.read_json("res://data/render.json"))
	view.set_preset("balanced")
	if sim != null:
		view.bind(sim.world, sim.development, sim.construction)
	_tree().root.add_child(view)
	return view


func _drop(view: LandWorksView) -> void:
	_tree().root.remove_child(view)
	view.free()


func _sim() -> CitySim:
	var sim := CitySim.boot_from_files(1337)
	sim.treasury.balance = 50_000_000
	return sim


func _some_block(sim: CitySim) -> String:
	for id: String in sim.world.block_ids_sorted():
		if sim.world.block(id).ownership_state == &"PURCHASABLE":
			return id
	return ""


## Put one block at `phase` with `progress` in it, without running a city: the
## budget table has to be readable at an exact progress, and a real pipeline
## never sits still on one.
func _pose(view: LandWorksView, block_id: String, phase: StringName,
		progress: float) -> void:
	view.feed_events([{"type": &"development_phase_started", "block": block_id,
			"phase": phase}])
	var site: Variant = view.site_view(block_id)
	assert_false((site as Dictionary).is_empty(), "the view took the block")
	# Wave 27's named harness seam — see `LandWorksView.force_progress`. It also
	# pushes the phase and the progress into the motion layer, which is what
	# makes a photographed phase a photograph of the whole site.
	view.force_progress(block_id, progress)
	view.refresh(0.0)


# ===========================================================================
# 1. The budget (doc 11 §2.18's published table)
# ===========================================================================

func test_a_city_with_nothing_in_flight_costs_no_draw_calls() -> void:
	var sim := _sim()
	var view := _view(sim)
	view.refresh(0.016)
	assert_eq(view.site_count(), 0)
	assert_eq(view.active_buffers(), 0,
			"six buffers exist and none of them submits — RR-83's rule, which is"
			+ " the difference between a layer that costs nothing and a layer"
			+ " that costs six calls from boot")
	assert_eq(view.layer_count(), 6)
	_drop(view)
	sim.dispose()


func test_the_per_phase_budget_is_what_doc_11_publishes() -> void:
	# ONE block, `balanced`, at the middle of each phase. These are the numbers
	# doc 11 §2.18's table carries; a change to the layer that moves them has to
	# move the doc in the same commit.
	var sim := _sim()
	var view := _view(sim)
	var block_id := _some_block(sim)
	assert_ne(block_id, "")
	#
	# **RE-TAKEN IN WAVE 27** (doc 11 §2.19). The DRAW CALLS are unchanged —
	# 2/2/2/3/4/3 — and four instance counts moved by one or two, because four of
	# them are no longer a fraction of a budget but a count of what a MACHINE has
	# reached:
	#
	#   CLEARING brush 20 → 21   a clump stands until the dozers sweep over it
	#                            (`LandMotion.sweep_of`), and the first tenth of
	#                            the phase is the machines arriving
	#   ROAD_INSTALL pave 18→19  the paver's own position decides how many slabs
	#                            are behind it (`LandMotion.pave_state`)
	#   FINAL pave 54 → 55       the same, for the kerb machine, over a finished
	#                            36-slab base
	#   UTILITY trench 6 → 5     3 segments of cut (the trencher's position) plus
	#                            2 staged pipe bundles it has NOT reached yet.
	#                            Wave 25 drew a bundle beside every DUG segment,
	#                            which read as pipe coming out of the hole.
	var expected := {
		&"SURVEY": {"buffers": 2, "stake": 8, "brush": 40, "graded": 0,
				"spoil": 0, "pave": 0, "trench": 0},
		&"CLEARING": {"buffers": 2, "stake": 8, "brush": 21, "graded": 0,
				"spoil": 0, "pave": 0, "trench": 0},
		&"GRADING": {"buffers": 2, "stake": 0, "brush": 0, "graded": 1,
				"spoil": 3, "pave": 0, "trench": 0},
		&"ROAD_INSTALL": {"buffers": 3, "stake": 0, "brush": 0, "graded": 1,
				"spoil": 6, "pave": 19, "trench": 0},
		&"UTILITY_CORRIDOR": {"buffers": 4, "stake": 0, "brush": 0, "graded": 1,
				"spoil": 5, "pave": 36, "trench": 5},
		&"FINAL_DEVELOPMENT": {"buffers": 3, "stake": 0, "brush": 0, "graded": 1,
				"spoil": 3, "pave": 55, "trench": 0},
	}
	for phase: StringName in PHASES:
		_pose(view, block_id, phase, 0.5)
		var census := view.census()
		var want: Dictionary = expected[phase]
		for key: String in want:
			assert_eq(int(census[key]), int(want[key]),
					"%s.%s: %d (doc 11 §2.18's table says %d)"
					% [phase, key, int(census[key]), int(want[key])])
	_drop(view)
	sim.dispose()


func test_the_scatter_counts_follow_the_preset_and_nothing_else_does() -> void:
	var sim := _sim()
	var view := _view(sim)
	var block_id := _some_block(sim)
	_pose(view, block_id, &"SURVEY", 0.0)
	var balanced := view.census()
	view.set_preset("performance")
	view.refresh(0.0)
	var performance := view.census()
	assert_true(int(performance["brush"]) < int(balanced["brush"]),
			"the scrub thins on a phone: %d < %d"
			% [int(performance["brush"]), int(balanced["brush"])])
	assert_eq(int(performance["stake"]), int(balanced["stake"]),
			"…and the lot is still pegged out, because eight stakes is eight"
			+ " stakes on any device")
	_drop(view)
	sim.dispose()


# ===========================================================================
# 2. What each phase reads
# ===========================================================================

func test_the_brush_leaves_as_the_clearing_runs() -> void:
	var sim := _sim()
	var view := _view(sim)
	var block_id := _some_block(sim)
	_pose(view, block_id, &"CLEARING", 0.0)
	var start := int(view.census()["brush"])
	_pose(view, block_id, &"CLEARING", 0.5)
	var half := int(view.census()["brush"])
	_pose(view, block_id, &"CLEARING", 1.0)
	var done := int(view.census()["brush"])
	assert_true(start > half and half > done,
			"the block empties in front of the player: %d → %d → %d"
			% [start, half, done])
	assert_eq(done, 0, "a finished clearing leaves nothing standing")
	_drop(view)
	sim.dispose()


func test_the_base_and_the_trench_are_laid_as_their_phases_run() -> void:
	var sim := _sim()
	var view := _view(sim)
	var block_id := _some_block(sim)
	_pose(view, block_id, &"ROAD_INSTALL", 0.1)
	var early := int(view.census()["pave"])
	_pose(view, block_id, &"ROAD_INSTALL", 0.9)
	var late := int(view.census()["pave"])
	assert_true(late > early, "the base goes down as the job runs: %d → %d"
			% [early, late])
	_pose(view, block_id, &"UTILITY_CORRIDOR", 0.25)
	var trench_early := int(view.census()["trench"])
	_pose(view, block_id, &"UTILITY_CORRIDOR", 1.0)
	var trench_late := int(view.census()["trench"])
	assert_true(trench_late > trench_early,
			"the cut opens toward the block centre: %d → %d"
			% [trench_early, trench_late])
	assert_eq(int(view.census()["pave"]), 36,
			"…over base that is already down, all six runs of it")
	_drop(view)
	sim.dispose()


func test_a_ready_block_leaves_nothing_behind() -> void:
	var sim := _sim()
	var view := _view(sim)
	var block_id := _some_block(sim)
	_pose(view, block_id, &"FINAL_DEVELOPMENT", 0.9)
	assert_true(view.active_buffers() > 0)
	view.feed_events([{"type": &"block_ready", "block": block_id}])
	view.refresh(0.0)
	assert_eq(view.site_count(), 0)
	assert_eq(view.active_buffers(), 0, "the block is ground now")
	assert_true(view.site_view(block_id).is_empty())
	_drop(view)
	sim.dispose()


func test_a_pipeline_that_let_go_without_an_event_is_dropped_by_the_poll() -> void:
	# `DevelopmentController.cancel_development` erases its record and emits
	# nothing — it has no door in the shell today, and a `restore_state` between
	# ticks does the same. A block that is back to UNDEVELOPED has nothing left
	# to draw and the poll is the only thing that can notice.
	var sim := _sim()
	var block_id := _some_block(sim)
	assert_true(bool(sim.cmd_buy_block(block_id, false, true)["ok"]))
	sim.advance_hours(0.25)
	var view := _view(sim)
	view.feed_events(sim.bus.drain())
	assert_eq(view.site_count(), 1)
	assert_true(bool(sim.development.cancel_development(block_id)["ok"]))
	assert_eq(sim.world.block(block_id).development_state, &"UNDEVELOPED",
			"a first-phase cancel puts the block back where it started")
	view.refresh(LandWorksView.POLL_INTERVAL_S)
	assert_eq(view.site_count(), 0, "…and the dressing goes with it")
	assert_eq(view.active_buffers(), 0)
	_drop(view)
	sim.dispose()


func test_the_view_adopts_a_pipeline_that_was_already_running() -> void:
	# The boot / load case: this view comes up over a city that is mid-phase and
	# has no events left to hear about it.
	var sim := _sim()
	var block_id := _some_block(sim)
	assert_true(bool(sim.cmd_buy_block(block_id, false, true)["ok"]))
	sim.advance_hours(6.0)
	sim.bus.drain()
	var view := _view(sim)
	view.adopt()
	view.refresh(0.0)
	assert_eq(view.site_count(), 1, "the block in flight is drawn")
	var site := view.site_view(block_id)
	assert_true(PHASES.has(StringName(String(site["phase"]))))
	assert_true(view.active_buffers() > 0)
	_drop(view)
	sim.dispose()


func test_progress_is_polled_from_the_views_own_set_and_never_from_the_map() -> void:
	# Ruling §AZ4's mechanical half: the poll walks `_sites`, which the events
	# populate, so a city with 49 blocks and one pipeline reads ONE block.
	var sim := _sim()
	var block_id := _some_block(sim)
	assert_true(bool(sim.cmd_buy_block(block_id, false, true)["ok"]))
	# `DevelopmentController` queues its own events and the REPORT phase
	# republishes them, so `development_phase_started` reaches the bus on the
	# first TICK after the purchase — which is exactly when the shell drains.
	sim.advance_hours(0.25)
	var view := _view(sim)
	view.feed_events(sim.bus.drain())
	assert_eq(view.site_count(), 1)
	assert_true(sim.world.block_ids_sorted().size() > 1,
			"the map really does have more blocks than the view is watching")
	var before := float(view.site_view(block_id)["progress"])
	sim.advance_hours(2.0)
	sim.bus.drain()
	# One poll interval of frames, and the progress moves without a single event.
	view.refresh(LandWorksView.POLL_INTERVAL_S)
	assert_true(float(view.site_view(block_id)["progress"]) > before,
			"the bar filled from a poll, not from a per-tick event")
	_drop(view)
	sim.dispose()


# ===========================================================================
# 3. The plant
# ===========================================================================

func test_each_phase_sends_the_machine_its_crew_type_names() -> void:
	var sim := _sim()
	var plant := ConstructionVehicleView.new()
	plant.setup(StarterCityLoader.read_json("res://data/render.json"))
	_tree().root.add_child(plant)
	var view := _view(sim)
	view.set_plant(plant)
	var block_id := _some_block(sim)
	var id := LandWorksView.plant_id_of(block_id)

	# SURVEY: a survey crew is two people and a tripod (doc 09 §2.3's
	# `construction_crew`), so no site is registered at all.
	_pose(view, block_id, &"SURVEY", 0.3)
	assert_false(plant.activity.sites.has(id),
			"no excavator turns up to look at a theodolite")

	# CLEARING / GRADING / UTILITY_CORRIDOR are `heavy_equipment_crew`: two
	# machines, and the lorries leave LOADED.
	for phase: StringName in [&"CLEARING", &"GRADING", &"UTILITY_CORRIDOR"]:
		_pose(view, block_id, phase, 0.3)
		var site: ConstructionActivity.Site = plant.activity.sites[id]
		assert_eq(plant.activity.excavator_count(site), 2,
				"%s runs two excavators" % phase)
		assert_true(plant.activity.hauling_out(site),
				"%s hauls what it dug OUT" % phase)

	# ROAD_INSTALL is `road_crew`: one machine, and the lorries arrive LOADED.
	_pose(view, block_id, &"ROAD_INSTALL", 0.3)
	var road_site: ConstructionActivity.Site = plant.activity.sites[id]
	assert_eq(plant.activity.excavator_count(road_site), 1)
	assert_false(plant.activity.hauling_out(road_site),
			"base and blacktop are DELIVERED")

	view.feed_events([{"type": &"block_ready", "block": block_id}])
	assert_false(plant.activity.sites.has(id), "the site leaves with the block")
	_drop(view)
	_tree().root.remove_child(plant)
	plant.free()
	sim.dispose()


func test_a_building_site_is_untouched_by_the_profile() -> void:
	# The whole risk of adding an override to a shipped class: a building must
	# read `EXCAVATORS_BY_STAGE` and `stage >= CLEANUP_STAGE` exactly as before.
	var activity := ConstructionActivity.new()
	var site := activity.add_site(7, Vector3.ZERO, Vector2i(2, 2), 12.0)
	for stage in range(1, 7):
		activity.set_stage(7, stage)
		assert_eq(activity.excavator_count(site),
				int(ConstructionActivity.EXCAVATORS_BY_STAGE[stage - 1]),
				"stage %d still reads the table" % stage)
		assert_eq(activity.hauling_out(site),
				stage >= ConstructionActivity.CLEANUP_STAGE,
				"stage %d still reads the ladder" % stage)


func test_a_land_plant_id_can_never_be_a_buildings() -> void:
	var sim := _sim()
	var highest := 0
	for id: String in sim.buildings:
		highest = maxi(highest, (sim.buildings[id] as Building).id)
	assert_true(highest < LandWorksView.PLANT_ID_BASE)
	for block_id: String in sim.world.block_ids_sorted():
		var plant_id := LandWorksView.plant_id_of(block_id)
		assert_true(LandWorksView.is_plant_id(plant_id))
		assert_true(plant_id >= LandWorksView.PLANT_ID_BASE)
	sim.dispose()


# ===========================================================================
# 4. It cannot move the sim
# ===========================================================================

func test_the_view_cannot_move_the_state_hash() -> void:
	# Constitution §3, the same property `test_construction_living.gd` pins for
	# the plant layer: a city advanced WITH this view reading it every tick must
	# hash identically to one that never had a view.
	var watched := _sim()
	var bare := _sim()
	var block_id := _some_block(watched)
	assert_true(bool(watched.cmd_buy_block(block_id, false, true)["ok"]))
	assert_true(bool(bare.cmd_buy_block(block_id, false, true)["ok"]))
	var view := _view(watched)
	view.set_focus(Vector3.ZERO)
	for _h in 40:
		watched.advance_hours(1.0)
		view.feed_events(watched.bus.drain())
		view.refresh(1.0)
		bare.advance_hours(1.0)
		bare.bus.drain()
	assert_true(view.site_count() > 0 or watched.world.block(block_id).is_ready(),
			"the arm really did drive a pipeline")
	assert_eq(watched.state_hash(), bare.state_hash(),
			"a renderer reads; it does not write")
	_drop(view)
	watched.dispose()
	bare.dispose()
