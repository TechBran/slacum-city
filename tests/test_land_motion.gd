extends SimTest
## Doc 11 §2.19 — `LandMotion` and `LandMotionView`, the layer that answers the
## player's *"we need to actually show MOVEMENT over there"* (ruling doc 93 §BB,
## report 98 §71 RR-217..RR-220).
##
## Six things are held here, and the first one is the whole brief:
##
##   1. **IT MOVES.** The same phase read at three GAME-MINUTES with the same
##      camera and the same block: every phase that has a machine on it moves
##      that machine's body or its joints between every pair of frames. A layer
##      that animated nothing would read zero here, and that is exactly what
##      Wave 25's did — its own docstring said so.
##   2. **The ground follows the machine.** The brush count is monotone DOWN in
##      progress, the base is monotone UP, the trench is monotone UP and the
##      staged pipe is monotone DOWN; and the clump that goes is the clump the
##      dozers have driven over, not the clump with the lowest index.
##   3. **The two clocks do what they claim.** A pause parks every machine
##      exactly where it stands; a load or a catch-up puts the layer where the
##      SAVE says rather than where the frame counter got to.
##   4. **The budget**, per phase and per block count, as an explicit table —
##      doc 11 §2.19's own, taken by the suite so it cannot rot. Draw calls are
##      bounded by the number of KINDS and never by the number of blocks, and a
##      city with nothing in flight costs zero.
##   5. **The governor's order.** `particle_ratio` takes the crew first and the
##      second machine next; the machine doing the work is never taken.
##   6. **It cannot move the sim.** The same property `test_land_works_view.gd`
##      pins for the dressing, extended over the motion layer's reads.

const PHASES: Array[StringName] = [
	&"SURVEY", &"CLEARING", &"GRADING", &"ROAD_INSTALL",
	&"UTILITY_CORRIDOR", &"FINAL_DEVELOPMENT",
]
## Phases with at least one machine on the block. SURVEY has a survey party and
## no plant, which is doc 09 §2.3's own `construction_crew`.
const MACHINE_PHASES: Array[StringName] = [
	&"CLEARING", &"GRADING", &"ROAD_INSTALL", &"UTILITY_CORRIDOR",
	&"FINAL_DEVELOPMENT",
]
## The three game-minutes every motion claim in this file is read at.
const FRAME_GM: Array[float] = [480.0, 495.0, 525.0]


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _sim() -> CitySim:
	var sim := CitySim.boot_from_files(1337)
	sim.treasury.balance = 50_000_000
	return sim


func _some_block(sim: CitySim) -> String:
	for id: String in sim.world.block_ids_sorted():
		if sim.world.block(id).ownership_state == &"PURCHASABLE":
			return id
	return ""


func _blocks(sim: CitySim, count: int) -> Array[String]:
	var out: Array[String] = []
	for id: String in sim.world.block_ids_sorted():
		if out.size() >= count:
			break
		if sim.world.block(id).ownership_state == &"PURCHASABLE":
			out.append(id)
	return out


## The stack the shell builds: the dressing, the plant layer under it (so the
## haul lorry has a frontage to run to and the arrival has a street to drive on)
## and doc 10's live network for the player's own road runs.
func _stack(sim: CitySim, preset: String = "balanced") -> Dictionary:
	var render := StarterCityLoader.read_json("res://data/render.json")
	var plant := ConstructionVehicleView.new()
	_tree().root.add_child(plant)
	plant.setup(render)
	plant.set_road_network(sim.roads)
	var view := LandWorksView.new()
	_tree().root.add_child(view)
	view.setup(render)
	view.set_preset(preset, render)
	view.bind(sim.world, sim.development, sim.construction)
	view.set_plant(plant)
	view.set_roads(sim.roads)
	return {"view": view, "plant": plant}


func _drop(stack: Dictionary) -> void:
	var view: LandWorksView = stack["view"]
	var plant: ConstructionVehicleView = stack["plant"]
	_tree().root.remove_child(view)
	view.free()
	_tree().root.remove_child(plant)
	plant.free()


## Routes resolve `ROUTES_PER_FRAME` at a time, so a site registered this frame
## has no polyline yet. Wind the plant on until it does.
func _settle(stack: Dictionary) -> void:
	var plant: ConstructionVehicleView = stack["plant"]
	for _step in 16:
		plant.refresh(0.0, 0.0, 0.0)


func _pose(stack: Dictionary, block_id: String, phase: StringName,
		progress: float) -> void:
	var view: LandWorksView = stack["view"]
	view.feed_events([{"type": &"development_phase_started",
			"block": block_id, "phase": phase}])
	_settle(stack)
	view.force_progress(block_id, progress)
	view.refresh(0.0, 0.0, 0.0)


## Every machine origin and every joint channel this frame, in buffer order.
func _snapshot(view: LandWorksView) -> Dictionary:
	var m := view.motion.motion
	var pos: Array[Vector3] = []
	var joint: Array[Color] = []
	for row: Array in [[m.dozer_poses, m.dozer_used], [m.exc_poses, m.exc_used],
			[m.tipper_poses, m.tipper_used], [m.paver_poses, m.paver_used],
			[m.roller_poses, m.roller_used]]:
		var poses: Array = row[0]
		for i in int(row[1]):
			var pose: ConstructionActivity.Pose = poses[i]
			pos.append(pose.origin)
			joint.append(pose.custom)
	var crew: Array[Vector3] = []
	for i in m.crew_used:
		crew.append((m.crew_poses[i] as ConstructionActivity.Pose).origin)
	return {"pos": pos, "joint": joint, "crew": crew}


## The largest thing that changed between two snapshots — metres for a body,
## normalised channel units for a joint. `-1` when the two frames do not even
## hold the same bodies, which would be a different defect and must never read
## as motion.
func _moved(a: Dictionary, b: Dictionary) -> float:
	var pa: Array[Vector3] = a["pos"]
	var pb: Array[Vector3] = b["pos"]
	var ja: Array[Color] = a["joint"]
	var jb: Array[Color] = b["joint"]
	if pa.size() != pb.size() or ja.size() != jb.size():
		return -1.0
	var best := 0.0
	for i in pa.size():
		best = maxf(best, pa[i].distance_to(pb[i]))
	for i in ja.size():
		var ca: Color = ja[i]
		var cb: Color = jb[i]
		best = maxf(best, maxf(maxf(absf(ca.r - cb.r), absf(ca.g - cb.g)),
				maxf(absf(ca.b - cb.b), absf(ca.a - cb.a))))
	return best


# ===========================================================================
# 1. IT MOVES — the whole brief
# ===========================================================================

func test_every_working_phase_moves_between_three_game_minutes() -> void:
	# **The claim the player's sentence turns into**, and the one a verifier can
	# check by looking at three pictures: hold the block, the camera and the
	# WORK still, move only the clock, and every phase with a machine on it has
	# something in a different place.
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	var block_id := _some_block(sim)
	assert_ne(block_id, "")
	for phase: StringName in MACHINE_PHASES:
		_pose(stack, block_id, phase, 0.55)
		var frames: Array[Dictionary] = []
		for gm: float in FRAME_GM:
			view.motion.set_game_minutes(gm)
			view.motion.refresh(0.0, 0.0, 0.0)
			frames.append(_snapshot(view))
		for i in range(1, frames.size()):
			var d := _moved(frames[i - 1], frames[i])
			assert_true(d > 0.0005,
					("%s: nothing on the block moved between game-minute %.0f"
					+ " and %.0f (largest change %.5f) — this is the still"
					+ " Wave 25 shipped")
					% [phase, FRAME_GM[i - 1], FRAME_GM[i], d])
	_drop(stack)
	sim.dispose()


func test_the_crew_walks_on_the_clock_in_every_phase() -> void:
	# The crew is the one thing on the layer that is on NO phase's critical
	# path, so it is also the one thing that would silently stop moving without
	# a machine test noticing.
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	var block_id := _some_block(sim)
	for phase: StringName in PHASES:
		_pose(stack, block_id, phase, 0.55)
		view.motion.set_game_minutes(FRAME_GM[0])
		view.motion.refresh(0.0, 0.0, 0.0)
		var first: Array[Vector3] = _snapshot(view)["crew"]
		view.motion.set_game_minutes(FRAME_GM[2])
		view.motion.refresh(0.0, 0.0, 0.0)
		var last: Array[Vector3] = _snapshot(view)["crew"]
		assert_true(not first.is_empty(), "%s puts a crew on the block" % phase)
		assert_eq(first.size(), last.size())
		var best := 0.0
		for i in first.size():
			best = maxf(best, first[i].distance_to(last[i]))
		assert_true(best > 0.05,
				("%s: the crew is standing in exactly the same place 45"
				+ " game-minutes later (%.4f m)") % [phase, best])
	_drop(stack)
	sim.dispose()


func test_a_machine_advances_along_its_pass_as_the_work_advances() -> void:
	# The other half of the motion, and the half a load has to reproduce: the
	# position along a pass is a function of the JOB'S PROGRESS, so it is the
	# save that decides where the dozer is.
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	var block_id := _some_block(sim)
	for phase: StringName in [&"CLEARING", &"ROAD_INSTALL", &"UTILITY_CORRIDOR"]:
		var seen: Array[Vector3] = []
		for progress: float in [0.20, 0.50, 0.80]:
			_pose(stack, block_id, phase, progress)
			view.motion.set_game_minutes(FRAME_GM[0])
			view.motion.refresh(0.0, 0.0, 0.0)
			var pos: Array[Vector3] = _snapshot(view)["pos"]
			assert_true(not pos.is_empty(), "%s has a machine" % phase)
			seen.append(pos[0])
		assert_true(seen[0].distance_to(seen[1]) > 1.0
				and seen[1].distance_to(seen[2]) > 1.0,
				"%s: the machine has not moved along its pass — %s → %s → %s"
				% [phase, seen[0], seen[1], seen[2]])
	_drop(stack)
	sim.dispose()


# ===========================================================================
# 2. The ground follows the machine
# ===========================================================================

func test_the_extents_are_monotone_in_progress() -> void:
	# Brush DOWN, base UP, trench UP, staged pipe DOWN. Every one of the four is
	# the count of something a machine has or has not reached, so every one of
	# them has to be monotone or the machine and the ground it changed have come
	# apart.
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	var block_id := _some_block(sim)
	var steps: Array[float] = [0.0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9, 1.0]

	var brush := -1
	for p: float in steps:
		_pose(stack, block_id, &"CLEARING", p)
		var now := int(view.census()["brush"])
		if brush >= 0:
			assert_true(now <= brush,
					"brush went UP at progress %.2f: %d → %d" % [p, brush, now])
		brush = now
	assert_eq(brush, 0, "a finished clearing leaves nothing standing")

	var pave := -1
	for p: float in steps:
		_pose(stack, block_id, &"ROAD_INSTALL", p)
		var now := int(view.census()["pave"])
		if pave >= 0:
			assert_true(now >= pave,
					"the base went DOWN at progress %.2f: %d → %d" % [p, pave, now])
		pave = now
	assert_eq(pave, 36, "…and a finished ROAD_INSTALL has all six runs laid")

	# The trench buffer carries the cut AND the staged pipe, so the two are
	# separated by the RULE that wrote them rather than by reading the buffer
	# back: a `MultiMesh` under the headless (dummy) rendering driver hands back
	# identity transforms and white colours, so a test that read one would be
	# asserting against the driver instead of against the layer.
	var trench := -1
	var pipe := 999
	for p: float in steps:
		_pose(stack, block_id, &"UTILITY_CORRIDOR", p)
		var counts := _trench_split(p)
		if trench >= 0:
			assert_true(int(counts["cut"]) >= trench,
					"the cut closed at progress %.2f" % p)
			assert_true(int(counts["pipe"]) <= pipe,
					"pipe appeared at progress %.2f: %d → %d"
					% [p, pipe, int(counts["pipe"])])
		trench = int(counts["cut"])
		pipe = int(counts["pipe"])
		assert_eq(int(view.census()["trench"]), trench + pipe,
				"the layer wrote exactly the cut and the pipe the rule says at"
				+ " progress %.2f" % p)
	assert_eq(trench, LandWorksView.DEF_TRENCH_SEGMENTS,
			"a finished corridor is open end to end")
	assert_eq(pipe, 0, "…and every bundle went in the ground")
	_drop(stack)
	sim.dispose()


## What `_lay_trench` must have written at this progress: `trench_dug` segments
## of cut, and a staged bundle beside every other segment the machine has NOT
## reached.
func _trench_split(progress: float) -> Dictionary:
	var segments := LandWorksView.DEF_TRENCH_SEGMENTS
	var dug := LandMotion.trench_dug(segments, LandMotion.pass_progress(progress))
	var pipe := 0
	for seg in range(dug, segments):
		if seg % LandWorksView.TRENCH_PIPE_EVERY == 0:
			pipe += 1
	return {"cut": dug, "pipe": pipe}


func test_the_clump_that_goes_is_the_clump_the_dozer_drove_over() -> void:
	# **Wave 25's defect, named.** The old rule kept the first
	# `budget × (1 − progress)` clumps BY INDEX, so the scrub left in hash order
	# — a field thinning evenly all over while two dozers were plainly working
	# one corner. Every surviving clump must now be one the sweep has not
	# reached, and the count is whatever that comes to.
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	var block_id := _some_block(sim)
	var site_id := _some_block(sim)
	var salt := absi(hash(site_id))
	var half := 64.0
	var budget := view.brush_budget
	for progress: float in [0.2, 0.5, 0.8]:
		_pose(stack, block_id, &"CLEARING", progress)
		var cleared := LandMotion.pass_progress(progress)
		# What the POSITIONAL rule says should still be standing, counted from
		# the same two static functions the layer writes with.
		var want := 0
		for i in budget:
			if LandMotion.sweep_of(LandMotion.brush_local(salt, i, half), half) > cleared:
				want += 1
		assert_eq(int(view.census()["brush"]), want,
				("at progress %.2f the layer drew %d clumps and the sweep rule"
				+ " says %d — an index rule would not agree")
				% [progress, int(view.census()["brush"]), want])
		# And the count really does depend on WHERE the clumps are: a fraction
		# rule would have drawn exactly this many, and it does not.
		var by_fraction := int(round(float(budget) * (1.0 - cleared)))
		if progress > 0.3:
			assert_ne(want, by_fraction,
					("the positional count and Wave 25's fraction count agree at"
					+ " progress %.2f (%d), so this test proves nothing")
					% [progress, want])
	# And the machines really are on the block, not parked at the frontage.
	var centre: Vector3 = view.site_view(block_id)["centre"]
	var pos: Array[Vector3] = _snapshot(view)["pos"]
	assert_true(not pos.is_empty(), "the dozers are out")
	for p: Vector3 in pos:
		assert_true(absf(p.x - centre.x) <= half and absf(p.z - centre.z) <= half,
				"a CLEARING machine at %s is outside its own block" % p)
	_drop(stack)
	sim.dispose()


func test_the_grading_excavator_stands_at_the_heap_it_is_building() -> void:
	# The read of GRADING is "the heaps grow with the cut", and it only reads if
	# the machine is AT the heap that is growing. `_heap_spoil` raises
	# `round(budget × progress)` heaps in index order, so the newest is that
	# count minus one — measured on the RAW progress, because a machine measured
	# on the pass stands at a heap the dressing has not raised yet, alone in the
	# middle of a graded plane.
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	var block_id := _some_block(sim)
	var salt := absi(hash(block_id))
	var half := 64.0
	var heaps := view.spoil_budget
	# Sample in the middle of each heap's span, where the machine is parked
	# beside the one it has just finished raising rather than tracking to the
	# next.
	for k in heaps:
		var progress := (float(k) + 0.7) / float(heaps)
		_pose(stack, block_id, &"GRADING", progress)
		view.motion.refresh(0.0, 0.0, 0.0)
		var drawn := int(view.census()["spoil"])
		assert_eq(drawn, k + 1, "the dressing has raised %d heaps" % (k + 1))
		var newest := LandMotion.spoil_local(salt, drawn - 1, half)
		var centre: Vector3 = view.site_view(block_id)["centre"]
		var heap := centre + Vector3(newest.x, 0.0, newest.y)
		var machine: Vector3 = (view.motion.motion.exc_poses[0]
				as ConstructionActivity.Pose).origin
		# One machine length off the heap, no further.
		assert_true(machine.distance_to(heap) < 12.0,
				("at progress %.2f the excavator is %.1f m from the newest of %d"
				+ " heaps") % [progress, machine.distance_to(heap), drawn])
	# **And it WALKS between them.** Snapping to the newest heap put the machine
	# 119 m away in one step, which at 1× is a machine vanishing and reappearing
	# across the block every fifty seconds. Sampled at 1 % of the phase, no step
	# may be more than a machine length.
	# Sampled from the end of the ARRIVAL onward: the first tenth of the phase is
	# the machine driving up the street at a street's pace, which is 14 m of
	# honest travel per 1 % of the phase and is not what this is looking for.
	var previous := Vector3.INF
	for step in 91:
		var p := LandMotion.ARRIVE_FRAC \
				+ (1.0 - LandMotion.ARRIVE_FRAC) * float(step) / 90.0
		_pose(stack, block_id, &"GRADING", p)
		view.motion.refresh(0.0, 0.0, 0.0)
		var here: Vector3 = (view.motion.motion.exc_poses[0]
				as ConstructionActivity.Pose).origin
		if previous.x < INF:
			assert_true(previous.distance_to(here) < 20.0,
					"the excavator teleported %.1f m at progress %.2f"
					% [previous.distance_to(here), p])
		previous = here
	_drop(stack)
	sim.dispose()


func test_the_paver_is_at_the_edge_of_what_it_has_laid() -> void:
	# One walk, two answers (`LandMotion.pave_state`): the machine's pose and the
	# number of slabs behind it come out of the same traverse, so the screed can
	# never be more than one segment from the end of its own strip.
	var runs := LandMotion.template_runs(Vector3.ZERO, 64.0, 8.0)
	var legs := LandMotion.legs_of(runs)
	var total := LandMotion.legs_total(legs)
	var segments := LandMotion.PAVE_SEGMENTS
	for step in 21:
		var fill := float(step) / 20.0
		var state := LandMotion.pave_state(legs, total, segments, fill)
		var laid := int(state["laid"])
		assert_true(laid >= 0 and laid <= runs.size() * segments)
		if not bool(state["laying"]) or laid <= 0:
			continue
		# The far end of the last slab laid.
		var run_index := (laid - 1) / segments
		var seg_index := (laid - 1) % segments
		var a: Vector3 = runs[run_index]["a"]
		var b: Vector3 = runs[run_index]["b"]
		var end := a.lerp(b, float(seg_index + 1) / float(segments))
		var machine: Vector3 = state["pos"]
		var run_len := a.distance_to(b)
		assert_true(machine.distance_to(end) <= run_len / float(segments) + 0.01,
				("at fill %.2f the screed is %.2f m from the end of slab %d,"
				+ " which is more than one segment")
				% [fill, machine.distance_to(end), laid])
	assert_eq(int(LandMotion.pave_state(legs, total, segments, 1.0)["laid"]),
			runs.size() * segments, "a finished pass lays every run")
	assert_eq(int(LandMotion.pave_state(legs, total, segments, 0.0)["laid"]), 0)


func test_the_strip_does_not_grow_while_the_paver_repositions() -> void:
	# The joins are the interesting half: a machine driving from the end of one
	# run to the start of the next is not laying anything, and a count derived
	# from a plain fraction would have carried on regardless.
	var runs := LandMotion.template_runs(Vector3.ZERO, 64.0, 8.0)
	var legs := LandMotion.legs_of(runs)
	var total := LandMotion.legs_total(legs)
	var travel := 0
	for leg: Dictionary in legs:
		if not bool(leg["lay"]):
			travel += 1
	assert_true(travel > 0,
			"doc 10's template really does need the machine to reposition")
	var moved_while_travelling := false
	var travel_samples := 0
	var last := -1
	var was_travelling := false
	for step in 401:
		var fill := float(step) / 400.0
		var state := LandMotion.pave_state(legs, total, LandMotion.PAVE_SEGMENTS, fill)
		var laid := int(state["laid"])
		var travelling := not bool(state["laying"])
		if last >= 0:
			assert_true(laid >= last, "the strip un-laid itself at fill %.3f" % fill)
			# Both ends of the step have to be on the SAME travel leg: a step
			# that STARTED mid-slab finishes that slab as it leaves, and that
			# last segment is laid, not driven over.
			if travelling and was_travelling:
				travel_samples += 1
				if laid != last:
					moved_while_travelling = true
		last = laid
		was_travelling = travelling
	assert_true(travel_samples > 0,
			"the sample rate really did land twice inside a reposition")
	assert_false(moved_while_travelling,
			"the base grew on a leg the paver was only driving along")


# ===========================================================================
# 3. The two clocks
# ===========================================================================

func test_a_paused_city_parks_every_machine_where_it_stands() -> void:
	# `gm_per_s = 0` is what the shell passes while paused. The layer's clock
	# must not advance, and therefore nothing on it may move — over any number
	# of real frames, at any frame time.
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	var block_id := _some_block(sim)
	_pose(stack, block_id, &"GRADING", 0.4)
	view.motion.set_game_minutes(FRAME_GM[0])
	view.motion.refresh(0.0, 0.0, 0.0)
	var parked := _snapshot(view)
	for _frame in 30:
		view.motion.refresh(0.033, 0.5, 0.0, -1.0)
	assert_almost_eq(view.motion.game_minutes(), FRAME_GM[0], 0.0001,
			"a paused city does not advance this layer's clock")
	assert_almost_eq(_moved(parked, _snapshot(view)), 0.0, 0.00001,
			"half a second of paused frames moved something")
	_drop(stack)
	sim.dispose()


func test_a_load_puts_the_layer_where_the_save_says() -> void:
	# The catch-up case: the layer free-ran for a while, then the sim's own clock
	# arrives a long way from where the frame counter got to. It must snap onto
	# the SAVE, and the pose it snaps to must be the pose a layer that had been
	# there all along would hold — which is what makes this derivation and not
	# animation.
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	var block_id := _some_block(sim)
	_pose(stack, block_id, &"GRADING", 0.4)
	view.motion.set_game_minutes(FRAME_GM[2])
	view.motion.refresh(0.0, 0.0, 0.0)
	var truth := _snapshot(view)

	var reloaded := _stack(sim, "balanced")
	var other: LandWorksView = reloaded["view"]
	_pose(reloaded, block_id, &"GRADING", 0.4)
	for _frame in 20:
		other.motion.refresh(0.05, 0.5, 3.0, -1.0)   # free-running, nowhere near
	assert_true(absf(other.motion.game_minutes() - FRAME_GM[2])
			> LandMotionView.RESYNC_GM, "the free run really did drift")
	other.motion.refresh(0.0, 0.5, 3.0, FRAME_GM[2])
	assert_almost_eq(other.motion.game_minutes(), FRAME_GM[2], 0.0001)
	assert_almost_eq(_moved(truth, _snapshot(other)), 0.0, 0.0001,
			"a loaded city and a city that never reloaded draw the same site")
	_drop(reloaded)
	_drop(stack)
	sim.dispose()


func test_the_phase_layout_is_built_once_and_not_per_frame() -> void:
	# Doc 11 §2.16's RR-42 discipline, applied to the one expensive derivation in
	# this file: the six template runs, their lay/travel legs and the trench line
	# are fixed by the PHASE, not by the clock, and rebuilding them sixty times a
	# second at eight blocks would be hundreds of square roots a frame for
	# numbers that had not moved.
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	var block_id := _some_block(sim)
	_pose(stack, block_id, &"ROAD_INSTALL", 0.3)
	var site: LandMotion.Site = view.motion.motion.sites[block_id]
	var legs := site.run_legs
	var total := site.run_total
	assert_true(legs.size() > 6, "runs and the repositions between them")
	for frame in 40:
		view.motion.set_game_minutes(400.0 + float(frame))
		view.motion.refresh(0.016, 0.4, 1.0, -1.0)
		assert_true(is_same(legs, view.motion.motion.sites[block_id].run_legs),
				"the leg table was rebuilt on frame %d" % frame)
	assert_almost_eq(view.motion.motion.sites[block_id].run_total, total, 0.0001)
	# …and a PHASE change is what invalidates it.
	_pose(stack, block_id, &"UTILITY_CORRIDOR", 0.3)
	view.motion.refresh(0.016, 0.4, 1.0, -1.0)
	assert_false(is_same(legs, view.motion.motion.sites[block_id].run_legs),
			"a phase change did not rebuild the layout")
	_drop(stack)
	sim.dispose()


func test_every_new_body_is_inside_its_own_shaders_joint_array() -> void:
	# The shaders index a fixed uniform array off a per-vertex joint code, and an
	# out-of-range index into a uniform array is undefined behaviour rather than
	# an error — a driver-dependent garbage read, and the shape of bug that
	# reproduces on one phone. `tests/test_street_life.gd` pins this for the
	# crook, the dog and the goat; these are the four bodies Wave 27 added.
	for row: Array in [["dozer", LandMachineMesh.dozer()],
			["paver", LandMachineMesh.paver()],
			["roller", LandMachineMesh.roller()]]:
		var mesh: ConstructionRigMesh = row[1]
		assert_false(mesh.is_empty(), "%s has geometry" % String(row[0]))
		assert_true(mesh.max_joint() <= int(ConstructionRigMesh.JOINT_4),
				"%s carries joint %d and `construction_rig.gdshader` walks four"
				% [String(row[0]), mesh.max_joint()])
		assert_eq(mesh.max_joint(), int(ConstructionRigMesh.JOINT_1),
				("%s spends exactly ONE joint — doc 11 §2.19's bargain, and the"
				+ " reason the other three INSTANCE_CUSTOM channels are given a"
				+ " zero range") % String(row[0]))
	var worker := StreetLifeMesh.worker()
	assert_false(worker.is_empty(), "the crew figure has geometry")
	assert_true(worker.max_joint() < StreetLifeMesh.JOINT_SLOTS,
			"the crew figure carries joint %d against %d slots"
			% [worker.max_joint(), StreetLifeMesh.JOINT_SLOTS])
	assert_eq(worker.max_joint(), 5,
			"…and it is the crook's six joints in the crook's order, so one"
			+ " animator drives both")
	assert_eq(StreetLifeMesh.worker_pivots().size(), StreetLifeMesh.JOINT_SLOTS)
	assert_eq(StreetLifeMesh.worker_sel().size(), StreetLifeMesh.JOINT_SLOTS)


func test_a_crew_figure_never_flashes_or_leaves() -> void:
	# `street_life.gdshader` reads COLOR.a as the COLLECT flash and channel `.a`
	# as the leaving animation. A crew member is neither collected nor expired,
	# and a hi-vis vest that went white-hot would be a man being arrested.
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	var block_id := _some_block(sim)
	for phase: StringName in PHASES:
		_pose(stack, block_id, phase, 0.5)
		view.motion.refresh(0.0, 0.0, 0.0)
		var m := view.motion.motion
		assert_true(m.crew_used > 0)
		for i in m.crew_used:
			var pose: ConstructionActivity.Pose = m.crew_poses[i]
			assert_almost_eq(pose.tint.a, 0.0, 0.0001,
					"%s: a crew figure carries a collect flash" % phase)
			assert_almost_eq(pose.custom.a, 0.0, 0.0001,
					"%s: a crew figure is leaving" % phase)
	_drop(stack)
	sim.dispose()


## Renamed at the merge (Wave 27 verifier): this drives `LandWorksView.refresh`
## itself and proves the forwarding into `LandMotionView`. The wire FROM the shell
## is `game/main.gd`'s four-argument call, applied in the same merge commit; the
## suite never loads main.gd, so that wire is the lead's, and this name no longer
## claims it.
func test_the_view_forwards_the_clock_the_shell_hands_it() -> void:
	# The two clock arguments travel from `main.gd` through `LandWorksView` into
	# the motion layer, and the tests above drive the motion layer directly. This
	# is the one that proves the wire between them.
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	var block_id := _some_block(sim)
	assert_true(bool(sim.cmd_buy_block(block_id, false, true)["ok"]))
	sim.advance_hours(0.25)
	view.feed_events(sim.bus.drain())
	assert_eq(view.site_count(), 1)
	view.refresh(0.0, 0.4, 1.0, 777.0)
	assert_almost_eq(view.motion.game_minutes(), 777.0, 0.0001,
			"the shell's `game_minutes` reaches the motion layer")
	view.refresh(0.5, 0.4, 3.0, -1.0)
	assert_almost_eq(view.motion.game_minutes(), 778.5, 0.0001,
			"…and between pins it integrates at the SPEED, so 0.5 s at 3× is"
			+ " 1.5 game-minutes")
	_drop(stack)
	sim.dispose()


func test_the_same_block_is_the_same_on_every_device() -> void:
	# Nothing is persisted and no RNG is drawn, so two views built from nothing
	# but the same block id and the same two clocks have to agree bit for bit.
	var sim := _sim()
	var a := _stack(sim)
	var b := _stack(sim)
	var block_id := _some_block(sim)
	for phase: StringName in PHASES:
		_pose(a, block_id, phase, 0.62)
		_pose(b, block_id, phase, 0.62)
		var va: LandWorksView = a["view"]
		var vb: LandWorksView = b["view"]
		va.motion.set_game_minutes(FRAME_GM[1])
		vb.motion.set_game_minutes(FRAME_GM[1])
		va.motion.refresh(0.0, 0.0, 0.0)
		vb.motion.refresh(0.0, 0.0, 0.0)
		assert_almost_eq(_moved(_snapshot(va), _snapshot(vb)), 0.0, 0.000001,
				"%s differs between two views of the same block" % phase)
	_drop(b)
	_drop(a)
	sim.dispose()


# ===========================================================================
# 4. The budget (doc 11 §2.19's published table)
# ===========================================================================

func test_a_city_with_nothing_in_flight_costs_no_draw_calls() -> void:
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	view.refresh(0.016, 0.5, 1.0, 100.0)
	assert_eq(view.motion.active_buffers(), 0,
			"seven buffers exist and none of them submits — RR-83's rule")
	assert_eq(view.motion.layer_count(), 7)
	assert_eq(view.total_buffers(), 0)
	_drop(stack)
	sim.dispose()


func test_the_per_phase_budget_is_what_doc_11_publishes() -> void:
	# ONE block, `balanced`, at the middle of each phase. These are the numbers
	# doc 11 §2.19's table carries; a change that moves them has to move the doc
	# in the same commit.
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	var block_id := _some_block(sim)
	var expected := {
		&"SURVEY": {"buffers": 1, "total": 3, "crew": 2},
		&"CLEARING": {"buffers": 2, "total": 4, "dozer": 2, "crew": 3},
		&"GRADING": {"buffers": 3, "total": 5, "excavator": 1, "tipper": 1,
				"crew": 3},
		&"ROAD_INSTALL": {"buffers": 3, "total": 6, "paver": 1, "roller": 1,
				"crew": 3},
		&"UTILITY_CORRIDOR": {"buffers": 2, "total": 6, "excavator": 1, "crew": 4},
		&"FINAL_DEVELOPMENT": {"buffers": 2, "total": 5, "paver": 1, "crew": 3},
	}
	for phase: StringName in PHASES:
		_pose(stack, block_id, phase, 0.5)
		view.motion.set_game_minutes(FRAME_GM[0])
		view.motion.refresh(0.0, 0.0, 0.0)
		var census := view.census()
		var motion: Dictionary = census["motion"]
		var want: Dictionary = expected[phase]
		for key: String in want:
			var got := int(census["total_buffers"]) if key == "total" \
					else int(motion[key])
			assert_eq(got, int(want[key]),
					"%s.%s: %d (doc 11 §2.19's table says %d)"
					% [phase, key, got, int(want[key])])
	_drop(stack)
	sim.dispose()


func test_draw_calls_are_bounded_by_kinds_and_not_by_blocks() -> void:
	# The claim that makes this layer affordable: eight blocks in eight
	# different phases still submit at most thirteen buffers between them,
	# because every block writes into the same thirteen.
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	var ids := _blocks(sim, 8)
	assert_true(ids.size() >= 6, "the starter city has blocks to develop")
	for i in ids.size():
		_pose(stack, ids[i], PHASES[i % PHASES.size()], 0.5)
	view.motion.set_game_minutes(FRAME_GM[0])
	view.motion.refresh(0.0, 0.0, 0.0)
	assert_eq(view.motion.motion.site_count(), ids.size())
	assert_true(view.total_buffers() <= 13,
			"%d buffers at %d mixed blocks — the ceiling is 6 dressing + 7 motion"
			% [view.total_buffers(), ids.size()])
	# And the node count is the same as it was with one block.
	assert_eq(view.get_child_count(), 7,
			"six dressing buffers plus the motion layer")
	assert_eq(view.motion.get_child_count(), 7)
	_drop(stack)
	sim.dispose()


# ===========================================================================
# 5. The governor and the presets
# ===========================================================================

func test_the_governor_takes_the_crew_before_the_machine() -> void:
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	var block_id := _some_block(sim)
	_pose(stack, block_id, &"GRADING", 0.5)
	view.motion.refresh(0.0, 0.0, 0.0)
	var full := view.census()["motion"] as Dictionary
	assert_eq(int(full["excavator"]), 1)
	assert_eq(int(full["tipper"]), 1)

	view.apply_governor({"particle_ratio": 0.6})
	view.motion.refresh(0.0, 0.0, 0.0)
	var thinned := view.census()["motion"] as Dictionary
	assert_true(int(thinned["crew"]) < int(full["crew"]),
			"the crew thins first: %d → %d"
			% [int(full["crew"]), int(thinned["crew"])])
	assert_eq(int(thinned["excavator"]), 1, "…and the machine is untouched")
	assert_eq(int(thinned["tipper"]), 1, "…and so is the lorry, at 0.60")

	view.apply_governor({"particle_ratio": 0.3})
	view.motion.refresh(0.0, 0.0, 0.0)
	var floor_row := view.census()["motion"] as Dictionary
	assert_eq(int(floor_row["tipper"]), 0,
			"the SECOND machine goes at the ladder's floor")
	assert_eq(int(floor_row["excavator"]), 1,
			"the machine doing the work is on no knob at all — a CLEARING with"
			+ " no dozer on it is the still this layer exists to close")
	assert_true(int(floor_row["crew"]) >= 1,
			"…and a site never has a machine on it with nobody there")

	view.apply_governor({"particle_ratio": 1.0})
	view.motion.refresh(0.0, 0.0, 0.0)
	assert_eq(int((view.census()["motion"] as Dictionary)["crew"]),
			int(full["crew"]), "and it all comes back")
	_drop(stack)
	sim.dispose()


func test_a_phone_gets_the_machine_and_fewer_men() -> void:
	var sim := _sim()
	var stack := _stack(sim, "performance")
	var view: LandWorksView = stack["view"]
	var block_id := _some_block(sim)
	_pose(stack, block_id, &"ROAD_INSTALL", 0.5)
	view.motion.refresh(0.0, 0.0, 0.0)
	var row := view.census()["motion"] as Dictionary
	assert_eq(int(row["paver"]), 1, "the machine laying the road is on no knob")
	assert_eq(int(row["roller"]), 0, "the follower is")
	assert_eq(int(row["crew"]), 2)
	_drop(stack)
	sim.dispose()


func test_every_preset_moves_the_crew_and_none_of_them_is_decoration() -> void:
	# **`crew` is a SCALE, not a ceiling**, and this is the cell that made it
	# one. The first draft shipped ceilings of 2 / 4 / 5; no phase wants more
	# than four, so `quality`'s could never bind and the row was decoration —
	# doc 93 §AZ2's own objection, in a render knob's clothes. Every preset now
	# has to move a number that some phase actually draws.
	var sim := _sim()
	var seen := {}
	for preset: String in ["performance", "balanced", "quality"]:
		var stack := _stack(sim, preset)
		var view: LandWorksView = stack["view"]
		var block_id := _some_block(sim)
		var row: Array[int] = []
		for phase: StringName in PHASES:
			_pose(stack, block_id, phase, 0.5)
			view.motion.refresh(0.0, 0.0, 0.0)
			row.append(int((view.census()["motion"] as Dictionary)["crew"]))
		seen[preset] = row
		_drop(stack)
	for i in PHASES.size():
		var low: int = (seen["performance"] as Array[int])[i]
		var mid: int = (seen["balanced"] as Array[int])[i]
		var high: int = (seen["quality"] as Array[int])[i]
		assert_true(low <= mid and mid <= high,
				"%s: the presets are not ordered — %d / %d / %d"
				% [PHASES[i], low, mid, high])
		assert_true(low >= 1, "%s: a phone still gets a man on the site" % PHASES[i])
	assert_ne(seen["performance"], seen["balanced"],
			"`performance` draws the same crew as `balanced`")
	assert_ne(seen["quality"], seen["balanced"],
			"`quality` draws the same crew as `balanced` — the row is decoration")
	assert_eq(seen["balanced"], [2, 3, 3, 3, 4, 3] as Array[int],
			"`balanced` is LandMotion.CREW_BY_PHASE exactly, because its scale is 1")
	assert_eq(seen["performance"], [1, 2, 2, 2, 2, 2] as Array[int])
	# UTILITY_CORRIDOR splits its gang between the head of the cut and the open
	# trench behind it, and the two halves must not each be scaled again — the
	# first draft did, and put SIX men on a four-man phase at `quality`.
	assert_eq(seen["quality"], [3, 4, 4, 4, 5, 4] as Array[int],
			"the split gang was double-scaled")
	sim.dispose()


# ===========================================================================
# 6. The player's own road, and the sim it may not touch
# ===========================================================================

func test_a_player_laid_road_gets_a_crew_that_works_along_it() -> void:
	# Doc 10 does not stamp a road instantly — `cmd_place_road` submits a
	# `road_crew` job with crew-hours — so this pass is that job's own progress
	# drawn, not a decoration over an instant edit. If that ever changes, this
	# test is where it will be noticed.
	var sim := _sim()
	var stack := _stack(sim)
	var view: LandWorksView = stack["view"]
	var tiles := _fresh_road_run(sim)
	assert_true(tiles.size() >= 4, "found a run of empty tiles beside a street")
	var placed := sim.cmd_place_road(tiles, RoadTunables.CLASS_STREET)
	assert_true(bool(placed["ok"]), "the road was laid: " + str(placed))
	var job_id := int(placed["payload"]["job_id"])
	assert_true(sim.construction.progress(job_id) < 1.0,
			"…and it is a JOB with time in it, not a stamp")
	view.feed_events(sim.bus.drain())
	assert_eq(view.motion.motion.run_count(), 1, "the crew was dispatched")

	var seen: Array[Vector3] = []
	for progress: float in [0.1, 0.5, 0.9]:
		view.motion.motion.set_run(job_id, [], progress)
		view.motion.set_game_minutes(FRAME_GM[0])
		view.motion.refresh(0.0, 0.0, 0.0)
		var census := view.census()["motion"] as Dictionary
		assert_eq(int(census["paver"]), 1, "a screed on the run")
		assert_eq(int(census["roller"]), 1, "and a roller behind it")
		assert_eq(int(census["barrier"]), LandMotion.RUN_BARRIER_BAYS,
				"and the working end is shut")
		seen.append((view.motion.motion.paver_poses[0]
				as ConstructionActivity.Pose).origin)
	assert_true(seen[0].distance_to(seen[1]) > 1.0
			and seen[1].distance_to(seen[2]) > 1.0,
			"the crew works ALONG the run: %s → %s → %s"
			% [seen[0], seen[1], seen[2]])

	# The job finishing takes the crew away.
	sim.construction.force_complete(job_id)
	sim.advance_hours(0.25)
	view.feed_events(sim.bus.drain())
	view.refresh(LandWorksView.POLL_INTERVAL_S, 0.5, 1.0, 100.0)
	assert_eq(view.motion.motion.run_count(), 0,
			"a finished road has no crew on it")
	_drop(stack)
	sim.dispose()


## A short run of buildable tiles that touches an existing street — doc 10's own
## `E_NOT_CONNECTED` rule means a run that touches nothing is refused.
func _fresh_road_run(sim: CitySim) -> Array:
	for t: Vector2i in sim.roads.graph.road_tiles_sorted():
		for step: Vector2i in [Vector2i(0, 1), Vector2i(1, 0),
				Vector2i(0, -1), Vector2i(-1, 0)]:
			var run: Array = []
			for i in range(1, 6):
				var candidate := t + step * i
				var preview := sim.cmd_place_road([candidate],
						RoadTunables.CLASS_STREET, true)
				if not bool(preview["ok"]):
					break
				run.append(candidate)
			if run.size() >= 4:
				return run
	return []


func test_the_motion_layer_cannot_move_the_state_hash() -> void:
	# Constitution §3 and ruling doc 93 §BB: every choice this layer makes is a
	# hash of a published id and a clock, so a city advanced with the whole
	# layer reading it — machines, crews, road runs and all — hashes identically
	# to one that never had a view at all.
	var clean := _sim()
	var block_a := _some_block(clean)
	assert_true(bool(clean.cmd_buy_block(block_a, false, true)["ok"]))
	for _step in 8:
		clean.advance_hours(1.0)
		clean.bus.drain()
	var expected := clean.state_hash()
	clean.dispose()

	var watched := _sim()
	var stack := _stack(watched)
	var view: LandWorksView = stack["view"]
	var block_b := _some_block(watched)
	assert_eq(block_b, block_a, "the two cities are the same city")
	assert_true(bool(watched.cmd_buy_block(block_b, false, true)["ok"]))
	view.adopt()
	for _step in 8:
		watched.advance_hours(1.0)
		view.feed_events(watched.bus.drain())
		for _frame in 6:
			view.set_focus(Vector3(512.0, 0.0, 512.0))
			view.refresh(0.05, 0.4, 1.0,
					float(watched.clock.game_seconds()) / 60.0)
	assert_eq(watched.state_hash(), expected,
			"the motion layer moved the sim it is only allowed to read")
	_drop(stack)
	watched.dispose()
