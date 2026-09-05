extends SceneTree
## **THE MOTION LAYER'S BUDGET AND ITS PROOF OF LIFE** (doc 11 §2.19).
##
## Doc 11 §2.18 published a 2/2/2/3/4/3 draw-call table for the DRESSING and
## `tests/test_land_works_view.gd` holds it. Wave 27 put machines on top of that
## dressing, so the table has to be re-taken with motion on — and the layer has
## to prove the thing it was asked for, which is that **it moves**.
##
## Three measurements, and they are the three the branch report quotes:
##
##   1. **The budget**, per phase and per concurrent block count: how many
##      buffers the dressing submits, how many the motion layer submits, the
##      total, the instance census and the node count. Draw calls on this pair
##      are bounded by the number of PROP AND MACHINE KINDS, never by the number
##      of blocks, and that is what the 1 / 3 / 8 columns exist to show.
##   2. **The motion proof**: the same phase photographed at `t`, `t + 15` and
##      `t + 45` GAME-MINUTES, reporting the largest translation any machine
##      made between frames. A layer that animates nothing reads 0.000 here, and
##      that is exactly what this layer read before this wave.
##   3. **The frame cost** of one `refresh` at each block count, best of N.
##
## Like every other tool in this directory it is a MEASURING INSTRUMENT: it owns
## no constant, reads `data/render.json` for everything, boots the real `CitySim`
## and is imported by nothing in `sim/`, `game/` or `ui/`.
##
## Usage (headless — it measures, it does not draw):
##   ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
##       -s res://tools/measure_land_motion.gd -- [options]
##
##   --blocks=1,3,8     concurrent developing blocks       (default 1,3,8)
##   --preset=NAME      performance | balanced | quality   (default balanced)
##   --progress=P       how far into each phase            (default 0.55)
##   --frames=A,B,C     game-minute offsets for the proof  (default 0,15,45)
##   --gm=M             the game-minute frame A is taken at (default 480)
##   --phase-gm=M       game-minutes a whole phase takes, for the proof's
##                      progress advance                   (default 300)
##   --repeats=N        timing repeats, best run wins      (default 40)
##
## `--phase-gm` is a HARNESS convention and not a game number: doc 09 §2.3 prices
## a phase in crew-hours and the clock it runs against is the queue's crewing, so
## there is no single "a phase takes M minutes" to read. 300 is five game-hours,
## which is the order of a real one, and it is only ever used to decide how far
## the WORK advances between the proof's three frames. The budget table and the
## frame cost do not touch it.

const RENDER_JSON := "res://data/render.json"
const PHASES: Array[StringName] = [
	&"SURVEY", &"CLEARING", &"GRADING", &"ROAD_INSTALL",
	&"UTILITY_CORRIDOR", &"FINAL_DEVELOPMENT",
]
const KINDS: Array[String] = ["dozer", "excavator", "tipper", "paver", "roller",
		"crew", "barrier"]

var _opts: Dictionary = {}
var _render: Dictionary = {}
var _sim: CitySim
var _blocks: Array[String] = []


func _initialize() -> void:
	_opts = _parse(OS.get_cmdline_user_args())
	_render = StarterCityLoader.read_json(RENDER_JSON)
	_sim = CitySim.boot_from_files(1337)
	if not _sim.boot_errors.is_empty():
		printerr("measure_land_motion: " + str(_sim.boot_errors))
		quit(2)
		return
	_sim.treasury.balance = 50_000_000
	for id: String in _sim.world.block_ids_sorted():
		if _sim.world.block(id).ownership_state == &"PURCHASABLE":
			_blocks.append(id)
	if _blocks.is_empty():
		printerr("measure_land_motion: the starter city has no purchasable block")
		quit(2)
		return
	_budget_table()
	_motion_proof()
	_frame_cost()
	quit(0)


# ---------------------------------------------------------------- 1. budget

func _budget_table() -> void:
	print("\n== doc 11 §2.19 — DRAW CALLS AND INSTANCES, preset %s =="
			% String(_opts["preset"]))
	print("%-19s %6s %6s %6s %6s %6s   %s"
			% ["phase", "blocks", "dress", "motion", "TOTAL", "nodes", "motion instances"])
	for count: int in (_opts["blocks"] as Array):
		var view := _make_view()
		var ids := _take(count)
		for phase: StringName in PHASES:
			for block_id: String in ids:
				_pose(view, block_id, phase, float(_opts["progress"]))
			view.refresh(0.0, 0.0, 0.0)
			var census := view.census()
			var motion: Dictionary = census["motion"]
			var parts: Array[String] = []
			for key: String in KINDS:
				var n := int(motion.get(key, 0))
				if n > 0:
					parts.append("%s %d" % [key, n])
			print("%-19s %6d %6d %6d %6d %6d   %s" % [phase, count,
					int(census["buffers"]), int(motion["buffers"]),
					int(census["total_buffers"]), _node_count(view),
					", ".join(PackedStringArray(parts))])
		# **The worst case is MIXED phases, not one phase eight times.** Every
		# block writes into the same thirteen buffers, so a city with one block
		# in each phase is where the draw-call ceiling actually lives — and it is
		# still bounded by the number of KINDS and not by the number of blocks.
		if ids.size() > 1:
			for i in ids.size():
				_pose(view, ids[i], PHASES[i % PHASES.size()],
						float(_opts["progress"]))
			view.refresh(0.0, 0.0, 0.0)
			var mixed := view.census()
			var mm: Dictionary = mixed["motion"]
			var mparts: Array[String] = []
			for key: String in KINDS:
				if int(mm.get(key, 0)) > 0:
					mparts.append("%s %d" % [key, int(mm[key])])
			print("%-19s %6d %6d %6d %6d %6d   %s" % ["<mixed phases>", count,
					int(mixed["buffers"]), int(mm["buffers"]),
					int(mixed["total_buffers"]), _node_count(view),
					", ".join(PackedStringArray(mparts))])
		# The empty city, taken from the SAME view so the claim is about this
		# layer and not about a different one that never had a block in it.
		view.clear()
		view.refresh(0.0, 0.0, 0.0)
		print("%-19s %6d %6d %6d %6d %6d   (RR-83: hidden, not merely empty)"
				% ["<nothing in flight>", count, view.active_buffers(),
				view.motion.active_buffers(), view.total_buffers(),
				_node_count(view)])
		_drop(view)


# ----------------------------------------------------------- 2. motion proof

func _motion_proof() -> void:
	var offsets: Array = _opts["frames"]
	var phase_gm := float(_opts["phase_gm"])
	print("\n== doc 11 §2.19 — IT MOVES: game-minutes %s, one phase = %.0f gm =="
			% [str(offsets), phase_gm])
	print("  machine dx / crew dx are METRES the furthest body travelled between"
			+ " two frames; joint is the largest change in a joint channel.")
	print("  `clock only` holds progress FIXED and moves only the clock, so it"
			+ " is what a paused-then-resumed city sees.")
	print("%-19s %5s %5s %9s %9s %9s   %9s %8s" % ["phase", "mach", "crew",
			"machine dx", "crew dx", "joint", "clock dx", "clk joint"])
	var view := _make_view()
	var block_id := _blocks[0]
	var base := float(_opts["progress"])
	for phase: StringName in PHASES:
		# 1. The real game: the clock and the work both advance.
		var frames: Array = []
		for offset: float in offsets:
			_pose(view, block_id, phase,
					clampf(base + offset / maxf(phase_gm, 1.0), 0.0, 1.0))
			view.motion.set_game_minutes(float(_opts["gm"]) + offset)
			view.motion.refresh(0.0, 0.0, 0.0)
			frames.append(_snapshot(view))
		# 2. The clock alone, at a frozen progress.
		var still: Array = []
		_pose(view, block_id, phase, base)
		for offset: float in offsets:
			view.motion.set_game_minutes(float(_opts["gm"]) + offset)
			view.motion.refresh(0.0, 0.0, 0.0)
			still.append(_snapshot(view))
		print("%-19s %5d %5d %9.3f %9.3f %9.4f   %9.3f %8.4f" % [phase,
				int((frames[0] as Dictionary)["machines"]),
				int((frames[0] as Dictionary)["crew_n"]),
				_worst(frames, "machine"), _worst(frames, "crew"),
				_worst(frames, "joint"),
				_worst(still, "machine"), _worst(still, "joint")])
	_drop(view)


## Machine origins, crew origins and joint channels this frame, in buffer order.
func _snapshot(view: LandWorksView) -> Dictionary:
	var motion := view.motion.motion
	var machine: Array[Vector3] = []
	var joint: Array[Color] = []
	for row: Array in [[motion.dozer_poses, motion.dozer_used],
			[motion.exc_poses, motion.exc_used],
			[motion.tipper_poses, motion.tipper_used],
			[motion.paver_poses, motion.paver_used],
			[motion.roller_poses, motion.roller_used]]:
		var poses: Array = row[0]
		for i in int(row[1]):
			var pose: ConstructionActivity.Pose = poses[i]
			machine.append(pose.origin)
			joint.append(pose.custom)
	var crew: Array[Vector3] = []
	for i in motion.crew_used:
		crew.append((motion.crew_poses[i] as ConstructionActivity.Pose).origin)
	return {"machine": machine, "crew": crew, "joint": joint,
			"machines": machine.size(), "crew_n": crew.size()}


## The largest movement of one body across a whole run of frames. Zero when two
## frames do not hold the same bodies — that would be a different defect and
## must never read as motion.
func _worst(frames: Array, key: String) -> float:
	var best := 0.0
	for i in range(1, frames.size()):
		var a: Array = (frames[i - 1] as Dictionary)[key]
		var b: Array = (frames[i] as Dictionary)[key]
		if a.size() != b.size():
			return 0.0
		for j in a.size():
			if key == "joint":
				var ca: Color = a[j]
				var cb: Color = b[j]
				best = maxf(best, maxf(maxf(absf(ca.r - cb.r), absf(ca.g - cb.g)),
						maxf(absf(ca.b - cb.b), absf(ca.a - cb.a))))
			else:
				best = maxf(best, (a[j] as Vector3).distance_to(b[j]))
	return best


# ------------------------------------------------------------ 3. frame cost

func _frame_cost() -> void:
	print("\n== doc 11 §2.19 — FRAME COST, best of %d ==" % int(_opts["repeats"]))
	print("%-19s %6s %10s %10s" % ["phase", "blocks", "usec", "usec/block"])
	for count: int in (_opts["blocks"] as Array):
		var view := _make_view()
		var ids := _take(count)
		for phase: StringName in PHASES:
			for block_id: String in ids:
				_pose(view, block_id, phase, float(_opts["progress"]))
			var best := INF
			for repeat in int(_opts["repeats"]):
				# The clock has to MOVE between samples, or a pose cache
				# somewhere downstream would be timed doing nothing.
				view.motion.set_game_minutes(float(repeat) * 0.37)
				var t0 := Time.get_ticks_usec()
				view.motion.refresh(0.016, 0.0, 0.0)
				best = minf(best, float(Time.get_ticks_usec() - t0))
			print("%-19s %6d %10.1f %10.1f"
					% [phase, count, best, best / float(maxi(count, 1))])
		_drop(view)


# ------------------------------------------------------------------ harness

## The whole stack the shell builds, minus the shell: the dressing, the plant
## layer under it (so the haul lorry has a frontage to run to and the arrival has
## a street to drive on) and doc 10's live road network.
func _make_view() -> LandWorksView:
	var plant := ConstructionVehicleView.new()
	root.add_child(plant)
	plant.setup(_render)
	plant.set_road_network(_sim.roads)
	var view := LandWorksView.new()
	root.add_child(view)
	view.setup(_render)
	view.set_preset(String(_opts["preset"]), _render)
	view.bind(_sim.world, _sim.development, _sim.construction)
	view.set_plant(plant)
	view.set_roads(_sim.roads)
	view.set_meta("plant", plant)
	return view


## Routes resolve two a frame (`ROUTES_PER_FRAME`), so a freshly registered site
## has no polyline on the frame it was added. Wind the plant forward until every
## site it holds has one.
func _settle_plant(view: LandWorksView) -> void:
	var plant: ConstructionVehicleView = view.get_meta("plant")
	for _step in 16:
		plant.refresh(0.0, 0.0, 0.0)


func _drop(view: LandWorksView) -> void:
	var plant: ConstructionVehicleView = view.get_meta("plant")
	root.remove_child(view)
	view.free()
	root.remove_child(plant)
	plant.free()


func _take(count: int) -> Array[String]:
	var out: Array[String] = []
	for i in mini(count, _blocks.size()):
		out.append(_blocks[i])
	return out


## Put one block at `phase` with `progress` in it, without running a city — a
## real pipeline never sits still on 0.55, and a phase measured at whatever the
## clock happened to reach would be a measurement of the harness.
func _pose(view: LandWorksView, block_id: String, phase: StringName,
		progress: float) -> void:
	view.feed_events([{"type": &"development_phase_started",
			"block": block_id, "phase": phase}])
	_settle_plant(view)
	view.force_progress(block_id, progress)
	view.refresh(0.0, 0.0, 0.0)


## Every node the pair costs — this view, its six dressing buffers, the motion
## view and its seven. It does NOT grow with the number of blocks, which is the
## claim doc 11 §2.19 publishes.
func _node_count(view: LandWorksView) -> int:
	return 1 + view.get_child_count() + view.motion.get_child_count()


func _parse(args: PackedStringArray) -> Dictionary:
	var out := {"blocks": [1, 3, 8] as Array, "preset": "balanced",
			"progress": 0.55, "frames": [0.0, 15.0, 45.0] as Array,
			"repeats": 40, "gm": 480.0, "phase_gm": 300.0}
	for raw: Variant in args:
		var arg := String(raw)
		if arg.begins_with("--blocks="):
			var picked: Array = []
			for part in arg.substr(9).split(",", false):
				picked.append(int(part))
			out["blocks"] = picked
		elif arg.begins_with("--preset="):
			out["preset"] = arg.substr(9)
		elif arg.begins_with("--progress="):
			out["progress"] = clampf(float(arg.substr(11)), 0.0, 1.0)
		elif arg.begins_with("--frames="):
			var offs: Array = []
			for part in arg.substr(9).split(",", false):
				offs.append(float(part))
			out["frames"] = offs
		elif arg.begins_with("--gm="):
			out["gm"] = float(arg.substr(5))
		elif arg.begins_with("--phase-gm="):
			out["phase_gm"] = maxf(1.0, float(arg.substr(11)))
		elif arg.begins_with("--repeats="):
			out["repeats"] = maxi(1, int(arg.substr(10)))
	return out
