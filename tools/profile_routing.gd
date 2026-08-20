extends SceneTree
## Doc 10 §2.14's routing budget, measured on a REAL booted city rather than on
## the synthetic reference map in `tests/test_roads_integration.gd`.
##
## It answers the one question that decided whether doc 06 §2.10's wiring could
## ship: **what does a dispatch quote cost on the benchmark city, and how many
## node expansions does it take?** The shape of the workload is the shape doc 06
## actually produces — a station tile to an incident tile, cold cache, emergency
## profile at `epsilon_critical`.
##
## Like every other tool here it is a MEASURING instrument: it boots the real
## `CitySim`, owns no constant of its own, and is never imported by `sim/`.
##
## Usage:
##   ~/.local/bin/godot --headless -s res://tools/profile_routing.gd -- [options]
##
##   --seed=N            RNG seed                              (default 1337)
##   --city=PATH         boot a different city file            (default starter)
##   --routes=N          quotes to time                        (default 120)
##   --epsilon=F         A* weighting (moves `routing.epsilon_critical`)
##   --candidates=K      rank every station on the O(1) estimate, quote the
##                       nearest K — doc 10 §2.14's rank-then-quote shape, which
##                       is the workload doc 06 §2.10 really produces
##   --hours=N           game-hours to age the city before measuring
##   --warm              do NOT drop the route cache between quotes
const STARTER_CITY := "res://data/starter_city.json"


func _initialize() -> void:
	var seed_value := 1337
	var city := STARTER_CITY
	var routes := 120
	var warm := false
	var epsilon := 1.0
	var candidates := 0
	var hours := 1
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--seed="):
			seed_value = int(arg.substr(7))
		elif arg.begins_with("--city="):
			city = arg.substr(7)
		elif arg.begins_with("--routes="):
			routes = int(arg.substr(9))
		elif arg == "--warm":
			warm = true
		elif arg.begins_with("--epsilon="):
			epsilon = float(arg.substr(10))
		elif arg.begins_with("--candidates="):
			candidates = int(arg.substr(13))
		elif arg.begins_with("--hours="):
			hours = int(arg.substr(8))

	var sim := _boot(seed_value, city)
	var net: RoadNetwork = sim.roads

	# A real city is not a fresh graph: run it so congestion, condition, closures
	# and the signal-power flags are the ones a live quote meets. `--hours` is
	# how a DEGRADED network gets measured — the case doc 06 §2.10's Wave-8 note
	# says the router falls over on.
	sim.advance_coarse_hours(hours, false)

	var origins := _station_tiles(sim)
	var targets := _target_tiles(sim)
	if origins.is_empty() or targets.is_empty():
		printerr("profile_routing: no origins (%d) or targets (%d)"
				% [origins.size(), targets.size()])
		quit(2)
		return

	# `travel_gs_for` takes its weighting from the profile's priority, so the
	# sweep moves the tunable rather than smuggling an override into the call —
	# which is also the only way the number it prints describes the shipped path.
	net.tun.epsilon_critical = epsilon
	var prof := RouteProfile.emergency(32.0, 0)
	net.travel_gs_for(origins[0], targets[0], prof)   # one untimed warm-up

	var total_us := 0
	var total_expansions := 0
	var total_minutes := 0.0
	var samples: Array[float] = []
	var unreachable := 0
	var quoted := 0
	for i in routes:
		var to: Vector2i = targets[(i * 7) % targets.size()]
		# `--candidates=K` reproduces doc 10 §2.14's RANK-THEN-QUOTE shape: rank
		# every station on the O(1) estimate, quote the nearest K. That is the
		# workload doc 06 §2.10 actually produces, and it is a different (much
		# shorter) distribution from "any station to any building".
		var picks: Array[Vector2i] = origins
		if candidates > 0:
			picks = _nearest(net, origins, to, prof, candidates)
		else:
			picks = [origins[i % origins.size()]] as Array[Vector2i]
		if not warm:
			net.planner.invalidate_all()
		for from: Vector2i in picks:
			# The SEAM call, not the raw search: `travel_gs_for` is what doc 06's
			# `RoadTravelTimeProvider` invokes, and it carries the route cache,
			# the re-price path and the whole-game-second rounding with it. A
			# measurement of `find_path` alone would flatter the number by
			# exactly the part dispatch cannot skip.
			var t0 := Time.get_ticks_usec()
			var gs := net.travel_gs_for(from, to, prof)
			var us := Time.get_ticks_usec() - t0
			total_us += us
			quoted += 1
			samples.append(float(us) / 1000.0)
			total_expansions += net.planner.expansions_last_call
			if gs >= 0:
				total_minutes += float(gs) / 60.0
			else:
				unreachable += 1
	samples.sort()
	routes = quoted

	print("profile_routing: %s  seed %d  %d game-hours  cache %s  eps %.4f  candidates %d"
			% [city, seed_value, hours, "warm" if warm else "cold", epsilon, candidates])
	print("  graph            : %d road tiles / %d nodes / %d edges"
			% [net.graph.road_tile_count(), net.graph.node_count(), net.graph.edge_count()])
	print("  routes           : %d  (%d unreachable)" % [routes, unreachable])
	print("  quote mean       : %.3f ms" % (float(total_us) / float(routes) / 1000.0))
	print("  quote median     : %.3f ms" % samples[samples.size() / 2])
	print("  quote p90        : %.3f ms" % samples[mini(samples.size() - 1,
			int(float(samples.size()) * 0.9))])
	print("  quote max        : %.3f ms" % samples[samples.size() - 1])
	print("  expansions mean  : %.1f" % (float(total_expansions) / float(routes)))
	print("  route minutes    : %.6f mean over %d reachable"
			% [total_minutes / maxf(1.0, float(routes - unreachable)), routes - unreachable])
	quit(0)


## Doc 10 §2.14's O(1) ranking pass, so the timed quotes are the ones §2.10
## would really have paid for.
static func _nearest(net: RoadNetwork, origins: Array[Vector2i], to: Vector2i,
		prof: RouteProfile, k: int) -> Array[Vector2i]:
	var scored: Array = []
	for from: Vector2i in origins:
		scored.append([net.estimate_eta_practical(from, to, prof), from.x, from.y])
	scored.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		if a[1] != b[1]:
			return a[1] < b[1]
		return a[2] < b[2])
	var out: Array[Vector2i] = []
	for i in mini(k, scored.size()):
		out.append(Vector2i(int(scored[i][1]), int(scored[i][2])))
	return out


static func _boot(seed_value: int, city: String) -> CitySim:
	if city == STARTER_CITY:
		return CitySim.boot_from_files(seed_value)
	var sim := CitySim.new()
	sim.boot(seed_value,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(city),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	for message in sim.boot_errors:
		printerr("profile_routing: " + String(message))
	return sim


## Where the trucks are: every unit's home tile, ascending by unit id.
static func _station_tiles(sim: CitySim) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var seen: Dictionary = {}
	for unit_id in sim.incidents.fleet.unit_ids():
		var u: Vehicle = sim.incidents.fleet.unit(int(unit_id))
		var key := "%d,%d" % [u.home_tile.x, u.home_tile.y]
		if seen.has(key):
			continue
		seen[key] = true
		out.append(u.home_tile)
	return out


## Where the incidents are: every building tile, ascending by building id, so a
## quote crosses the same city an incident would.
static func _target_tiles(sim: CitySim) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for building_id in sim.roster_ids():
		var b: Building = sim.buildings[building_id]
		out.append(b.origin)
	return out
