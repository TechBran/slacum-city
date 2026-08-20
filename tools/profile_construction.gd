extends SceneTree
## What does `ConstructionActivity.refresh()` cost, and does the pose cache
## change the picture? (doc 11 §2.16b, report 98 RR-32's open q1)
##
## RR-32 split `ConstructionVehicleView`'s 0.53 ms layer CPU at 20 sites into
## **0.32 ms of pose computation and 0.09 ms of upload**, and named the pose
## half as the next lever. This is the instrument for it — and it is deliberately
## NOT `tools/profile_frame.gd --sites=N`: that harness needs a display, times
## the whole layer including the MultiMesh upload, and carries a 1,500-building
## city's render stack in the same process. What is being measured here is a
## RefCounted class doing arithmetic, so it is measured **headless**, with the
## uploads and the renderer out of the room.
##
## **Both arms run in ONE process, alternating inside each round.** The cache is
## a property (`ConstructionActivity.pose_cache`), so the before arm and the
## after arm see the same warmed dictionaries, the same allocator state and the
## same machine load — which is the only way a sub-millisecond GDScript delta on
## a shared workstation is a measurement rather than an anecdote.
##
## It is a MEASURING instrument (constitution §3): it owns no constant that the
## game reads, boots the real `RoadNetwork` off `data/starter_city.json`, drives
## the real `ConstructionVehicleView`, and nothing in `sim/` or `game/` imports
## it.
##
## Usage:
##   ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
##       -s res://tools/profile_construction.gd -- [options]
##
##   --sites=N        sites stood up on the starter network   (default 20)
##   --frames=N       refreshes timed per arm per round       (default 2000)
##   --rounds=N       interleaved rounds                      (default 5)
##   --gm-step=F      game-minutes advanced per refresh       (default 0.0167,
##                    i.e. one 60 Hz frame at 1× — a game-minute is a real
##                    second, so this is the shipped cadence)
##   --stages=LIST    comma-separated stage ring, cycled over the sites
##                    (default 1,2,3,4,5,6 — every rung of the ladder at once)
##   --verify         additionally run the two arms over the SAME timeline and
##                    compare every emitted pose field for bit identity, which
##                    is the cache's contract
##   --quiet          table only

const RENDER_JSON := "res://data/render.json"
const STARTER := "res://data/starter_city.json"

var _opts: Dictionary = {}


func _initialize() -> void:
	_opts = _parse(OS.get_cmdline_user_args())
	if not String(_opts["error"]).is_empty():
		printerr("profile_construction: " + String(_opts["error"]))
		quit(2)
		return
	var sites := int(_opts["sites"])
	var view := _stand_up(sites)
	if view == null:
		printerr("profile_construction: could not stand up %d sites" % sites)
		quit(2)
		return
	if bool(_opts["verify"]):
		if has_cache(view.activity):
			_verify(view)
		else:
			print("  verify: this build has no pose cache — nothing to compare")
	_measure(view)
	quit(0)


# ------------------------------------------------------------------- the rig

## The doc 09 starter city's road network, exactly as the game boots it.
func _network() -> RoadNetwork:
	var loader := StarterCityLoader.new()
	loader.load_from(StarterCityLoader.read_json(STARTER))
	var net := RoadNetwork.new(loader.world.grid,
			RoadTunables.from_file("res://data/roads.json"), RngStreams.new(1337))
	net.bootstrap()
	return net


## `count` lots, each one tile off a road, walked in ascending tile order so the
## same N sites come up on every run.
func _stand_up(count: int) -> ConstructionVehicleView:
	var net := _network()
	var view := ConstructionVehicleView.new()
	view.setup(StarterCityLoader.read_json(RENDER_JSON))
	view.set_road_network(net)
	view.max_sites = maxi(count, 1)
	var stages: Array = _opts["stages"]
	var placed := 0
	var seen: Dictionary = {}
	for t: Vector2i in net.graph.road_tiles_sorted():
		if placed >= count:
			break
		for step: Vector2i in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1),
				Vector2i(-1, 0)]:
			var lot := t + step
			if placed >= count or net.graph.is_road_tile(lot) or seen.has(lot):
				continue
			if lot.x < 1 or lot.y < 1:
				continue
			seen[lot] = true
			var id := 9000 + placed
			view.add_site(id, Vector3(float(lot.x) * 8.0 + 4.0, 0.0,
					float(lot.y) * 8.0 + 4.0), Vector2i(1, 1), 12.0 + float(placed))
			view.set_stage(id, int(stages[placed % stages.size()]))
			placed += 1
	# Two routes resolve per frame by design, so the queue needs draining before
	# a single game-minute is measured: a site with no route draws no lorry, and
	# timing that would be timing the cheap case.
	for i in placed + 8:
		view.refresh(0.0, -1.0, 0.0)
	if placed < count:
		return null
	# Wind the clock forward so the yards are full and lorries are on the road —
	# the same reason `profile_frame.gd --site-gm` defaults to 900.
	view.set_game_minutes(900.0)
	view.refresh(0.0, -1.0, 0.0)
	return view


# ----------------------------------------------------------------- the timing

func _measure(view: ConstructionVehicleView) -> void:
	var activity := view.activity
	var frames := int(_opts["frames"])
	var rounds := int(_opts["rounds"])
	var step := float(_opts["gm_step"])
	var start := activity_clock(view)
	var off: Array[float] = []
	var on: Array[float] = []
	for r in rounds:
		# Both arms walk the SAME timeline from the SAME start, so a difference
		# in the numbers cannot be a difference in what was drawn.
		off.append(_run(activity, start, frames, step, false))
		on.append(_run(activity, start, frames, step, true))
	if not bool(_opts["quiet"]):
		print("")
	print("=== ConstructionActivity.refresh — %d sites, %d frames/arm, %d rounds, "
			% [int(_opts["sites"]), frames, rounds]
			+ "%.4f gm/frame ===" % step)
	print("  round   cache off (ms/frame)   cache on (ms/frame)   delta        ")
	print("  ---------------------------------------------------------------")
	for r in rounds:
		print("  %-6d  %-21.4f  %-19.4f  %+.4f (%+.1f %%)"
				% [r + 1, off[r], on[r], on[r] - off[r],
				100.0 * (on[r] - off[r]) / maxf(off[r], 1e-9)])
	var mo := _mean(off)
	var mn := _mean(on)
	print("  ---------------------------------------------------------------")
	print("  mean    %-21.4f  %-19.4f  %+.4f (%+.1f %%)"
			% [mo, mn, mn - mo, 100.0 * (mn - mo) / maxf(mo, 1e-9)])
	print("  spread  %.4f..%.4f          %.4f..%.4f"
			% [off.min(), off.max(), on.min(), on.max()])
	var census := view.census()
	print("  census: %d excavators, %d tippers, %d heaps, %d stacks, %d barricades"
			% [int(census["excavator"]), int(census["tipper"]), int(census["heap"]),
			int(census["stack"]), int(census["barrier"])])


func activity_clock(view: ConstructionVehicleView) -> float:
	return view.game_minutes()


## One arm: `frames` refreshes at `step` game-minutes each, wall time per frame.
##
## The cache is reached DUCK-TYPED on purpose. The before-arm this tool's
## headline number is quoted against is a build that predates the cache, and the
## honest way to measure that is to drop `game/render/construction_activity.gd`
## from an older commit into the tree and run this unchanged — which a hard
## reference to `pose_cache` would turn into a parse error.
func _run(activity: ConstructionActivity, start: float, frames: int, step: float,
		cache: bool) -> float:
	_set_cache(activity, cache)
	# One untimed refresh so neither arm pays for the other's cold state.
	activity.refresh(start)
	var t0 := Time.get_ticks_usec()
	for i in frames:
		activity.refresh(start + float(i + 1) * step)
	var usec := Time.get_ticks_usec() - t0
	return float(usec) * 0.001 / float(maxi(frames, 1))


## True when this build HAS a pose cache at all — see `_run`.
static func has_cache(activity: ConstructionActivity) -> bool:
	return "pose_cache" in activity


static func _set_cache(activity: ConstructionActivity, on: bool) -> void:
	if not has_cache(activity):
		return
	activity.set("pose_cache", on)
	activity.call("invalidate_pose_cache")


static func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for v in values:
		total += v
	return total / float(values.size())


# ------------------------------------------------------------- the contract

## The cache's whole claim: the same timeline emits the same poses, field for
## field, bit for bit. `tests/test_construction_living.gd` owns the property
## test over random timelines; this is the same check at profiling scale, so a
## run that reports a speed-up has also shown it did not buy it with a lie.
func _verify(view: ConstructionVehicleView) -> void:
	var activity := view.activity
	var start := view.game_minutes()
	var step := float(_opts["gm_step"])
	var frames := mini(int(_opts["frames"]), 4000)
	var mismatches := 0
	var compared := 0
	for i in frames:
		var gm := start + float(i + 1) * step
		_set_cache(activity, false)
		activity.refresh(gm)
		var reference := _snapshot(activity)
		_set_cache(activity, true)
		# Walk the cache in from the frame BEFORE, so the compared frame is one
		# the cache has had a chance to serve rather than one it had to fill.
		activity.refresh(gm - step)
		activity.refresh(gm)
		var cached := _snapshot(activity)
		compared += 1
		if reference != cached:
			mismatches += 1
			if mismatches <= 3:
				printerr("  pose mismatch at gm %.4f" % gm)
	print("  verify: %d frames compared, %d mismatched" % [compared, mismatches])
	if mismatches > 0:
		quit(1)


## Every field of every emitted pose, in emission order. Pools and counts are
## walked by INDEX, not matched by identity: `Array == Array` in GDScript is a
## deep element-wise compare, so testing which pool this is would compare a
## thousand poses to answer a question about a reference.
static func _snapshot(activity: ConstructionActivity) -> Array:
	var counts: Array = [activity.truck_used, activity.rig_used, activity.heap_used,
			activity.stack_used, activity.barrier_used]
	var pools: Array = [activity.truck_poses, activity.rig_poses,
			activity.heap_poses, activity.stack_poses, activity.barrier_poses]
	var out: Array = [counts]
	for p in pools.size():
		var pool: Array = pools[p]
		for i in int(counts[p]):
			var pose: ConstructionActivity.Pose = pool[i]
			out.append([pose.origin, pose.basis, pose.custom, pose.tint])
	return out


# ------------------------------------------------------------------- options

func _parse(argv: PackedStringArray) -> Dictionary:
	var opts := {
		"sites": 20, "frames": 2000, "rounds": 5, "gm_step": 1.0 / 60.0,
		"stages": [1, 2, 3, 4, 5, 6], "verify": false, "quiet": false,
		"error": "",
	}
	for arg in argv:
		if arg.begins_with("--sites="):
			opts["sites"] = maxi(1, int(arg.substr(8)))
		elif arg.begins_with("--frames="):
			opts["frames"] = maxi(1, int(arg.substr(9)))
		elif arg.begins_with("--rounds="):
			opts["rounds"] = maxi(1, int(arg.substr(9)))
		elif arg.begins_with("--gm-step="):
			opts["gm_step"] = maxf(0.0, float(arg.substr(10)))
		elif arg.begins_with("--stages="):
			var ring: Array = []
			for part in arg.substr(9).split(",", false):
				ring.append(clampi(int(part), 1, 6))
			if ring.is_empty():
				opts["error"] = "--stages wants at least one stage"
			else:
				opts["stages"] = ring
		elif arg == "--verify":
			opts["verify"] = true
		elif arg == "--quiet":
			opts["quiet"] = true
		else:
			opts["error"] = "unknown option " + arg
	return opts
