extends SimTest
## **Street-true vehicle routes** (doc 06 §2.11 over doc 10 §2.7).
##
## `Vehicle.update_motion` interpolated `route[0] → route[-1]`, so a fire engine
## crossed blocks in a straight line and never turned a corner: doc 10's router
## existed and dispatch did not use it. It does now — and the contract this file
## exists to hold is that giving it the real streets changed **where** a unit is,
## never **when** it arrives:
##
##   * `arrive_at_h` is still `TravelTimeProvider.eta_gs()` and nothing else;
##   * distance along the polyline is a constant fraction of ARC LENGTH, so
##     `s(depart) = 0` and `s(arrive) = length`, whatever shape the route is;
##   * `speed` is the REALISED metres/game-minute doc 11 §2.12 dead-reckons with;
##   * the whole thing degrades to the old straight line when the provider has no
##     street network, which is what keeps every doc 06 test that predates doc 10
##     meaningful.

const EPS := 1e-9


func _catalog() -> IncidentCatalog:
	return IncidentCatalog.load_from_files()


func _unit(speed_mpgm: float = 24.0) -> Vehicle:
	return Vehicle.from_type(1, {"type_id": "engine", "department": "fire",
			"speed_mpgm": speed_mpgm, "siren_mult": 1.0,
			"resolve_rate": {"fire": 1.0}}, "S1", Vector2i(0, 0))


# ------------------------------------------------------------- the motion law

## An L-shaped route: 4 tiles east, then 3 tiles south. 56 m of arc against 32 m
## of straight line — the exact case the old code drew as a diagonal.
func _l_route(u: Vehicle) -> void:
	u.route = [Vector2i(0, 0), Vector2i(4, 0), Vector2i(4, 3)]
	u.status = Vehicle.RESPONDING
	u.depart_h = 10.0
	u.arrive_at_h = 10.5


func test_polyline_is_walked_segment_by_segment() -> void:
	var u := _unit()
	_l_route(u)
	assert_almost_eq(u.route_length_m(), 56.0, EPS, "4 tiles + 3 tiles at 8 m")

	# Half the leg: 14 m along the 32 m first segment.
	u.update_motion(10.125)
	assert_eq(u.tile, Vector2i(2, 0), "still on the eastward leg")
	assert_almost_eq(u.heading, 0.0, 1e-6, "heading is +X while going east")
	assert_eq(u.route_segment, 0)
	assert_almost_eq(u.route_s_m, 14.0, 1e-6)

	# Past the corner: 42 m = 32 m + 10 m into the 24 m southward segment.
	u.update_motion(10.375)
	assert_eq(u.route_segment, 1, "on the second leg")
	assert_almost_eq(u.heading, PI / 2.0, 1e-6, "the unit TURNED — +Z, not a diagonal")
	assert_eq(u.tile, Vector2i(4, 1), "and it is on the street, not across the block")


func test_arrival_time_is_untouched_by_the_shape_of_the_route() -> void:
	var straight := _unit()
	straight.route = [Vector2i(0, 0), Vector2i(4, 3)]
	straight.status = Vehicle.RESPONDING
	straight.depart_h = 10.0
	straight.arrive_at_h = 10.5
	var bent := _unit()
	_l_route(bent)
	for t in [10.0, 10.1, 10.25, 10.5]:
		straight.update_motion(float(t))
		bent.update_motion(float(t))
		assert_almost_eq(straight.route_progress, bent.route_progress, EPS,
				"progress is a pure function of TIME, not of path length")
	straight.update_motion(10.5)
	bent.update_motion(10.5)
	assert_eq(bent.tile, Vector2i(4, 3), "the long way round still lands on time")
	assert_eq(straight.tile, bent.tile, "at the same place")


## C-67 / doc 11 §2.12: the renderer dead-reckons `pos + dir(heading) × speed`
## between snapshots, so a NOMINAL cruise speed would overshoot every pose and be
## yanked back. The realised speed is `arc length / duration`.
func test_speed_is_the_realised_speed() -> void:
	var u := _unit(24.0)
	_l_route(u)
	u.update_motion(10.1)
	assert_almost_eq(u.speed, 56.0 / 30.0, 1e-9,
			"56 m over 0.5 game-hours = 30 game-minutes")
	assert_ne(u.speed, u.effective_speed(),
			"and it is NOT the nominal cruise figure — doc 10 priced the route")


func test_degrades_to_the_straight_line_with_no_router() -> void:
	var u := _unit()
	u.route = [Vector2i(0, 0), Vector2i(10, 0)]
	u.status = Vehicle.RESPONDING
	u.depart_h = 0.0
	u.arrive_at_h = 1.0
	u.update_motion(0.5)
	assert_eq(u.tile, Vector2i(5, 0), "a two-point route is the old behaviour exactly")
	assert_almost_eq(u.route_progress, 0.5, EPS)


func test_route_cursor_round_trips_a_save() -> void:
	var u := _unit()
	_l_route(u)
	u.update_motion(10.375)
	var row := {"type_id": "engine", "speed_mpgm": 24.0, "siren_mult": 1.0}
	var back := Vehicle.deserialize(u.serialize(), row)
	assert_eq(back.route.size(), 3, "the polyline is persisted, not just its ends")
	assert_eq(back.route_segment, u.route_segment)
	assert_almost_eq(back.route_s_m, u.route_s_m, EPS)
	assert_eq(back.tile, u.tile)
	assert_almost_eq(back.heading, u.heading, EPS)
	# And a resumed unit keeps walking from where it was.
	back.update_motion(10.5)
	u.update_motion(10.5)
	assert_eq(back.tile, u.tile)


# ------------------------------------------------------------------ the seam

## The base provider has no street network and says so with `[]`; the fleet then
## keeps the two-point route doc 06 has always used.
func test_base_provider_answers_no_polyline() -> void:
	var provider := TravelTimeProvider.new()
	assert_eq(provider.route_tiles(Vector2i(0, 0), Vector2i(9, 9)).size(), 0,
			"no router, no polyline")
	var fleet := FleetSystem.new(_catalog(), provider)
	assert_eq(fleet._polyline(Vector2i(1, 1), Vector2i(6, 4), {}),
			[Vector2i(1, 1), Vector2i(6, 4)],
			"and dispatch falls back to the straight segment")


## A polyline that does not start where the unit is standing would teleport it —
## the router snaps both endpoints to the nearest road tile, and doc 06 owns the
## two tiles that matter.
func test_polyline_endpoints_are_the_units_own() -> void:
	var fleet := FleetSystem.new(_catalog(), StubRouter.new())
	var out := fleet._polyline(Vector2i(0, 0), Vector2i(9, 9), {})
	assert_eq(out[0], Vector2i(0, 0), "starts where the unit stands")
	assert_eq(out[out.size() - 1], Vector2i(9, 9), "ends on the target")
	assert_true(out.size() > 2, "with the router's tiles in between")


class StubRouter extends TravelTimeProvider:
	func route_tiles(_from: Vector2i, _to: Vector2i, _profile: Dictionary = {}) -> Array:
		# Snapped to the kerb at both ends, as a real router answers.
		return [Vector2i(1, 0), Vector2i(5, 0), Vector2i(5, 8)]


# ------------------------------------------------------- over the real network

func _network() -> RoadNetwork:
	var sim := CitySim.boot_from_files(1337)
	return sim.roads


## The polyline and the duration come out of ONE planner cache entry, so the
## shape and the price can never describe two different trips.
func test_road_network_polyline_is_the_route_it_priced() -> void:
	var net := _network()
	var prof := net.default_profile()
	var a := Vector2i(39, 32)
	var b := Vector2i(47, 48)
	var tiles := net.route_tiles(a, b, prof)
	assert_true(tiles.size() >= 2, "the starter grid connects these two")
	var minutes := net.route_minutes(a, b, prof)
	assert_false(is_inf(minutes), "and it is priced")
	# Every tile on the answer is a road tile, and consecutive tiles are adjacent.
	for i in tiles.size():
		assert_true(net.graph.is_road_tile(tiles[i]),
				"tile %s on the route is not a road" % str(tiles[i]))
		if i > 0:
			var d: Vector2i = tiles[i] - tiles[i - 1]
			assert_true(maxi(absi(d.x), absi(d.y)) == 1,
					"the polyline is contiguous at step %d" % i)
	# The street route is at least as long as the crow flies. That is the whole
	# point: the old straight line under-drew the distance every time.
	var chebyshev := maxi(absi(b.x - a.x), absi(b.y - a.y))
	assert_true(tiles.size() - 1 >= chebyshev,
			"a street route is never shorter than the diagonal it replaced")
	assert_eq(net.route_tiles(Vector2i(-40, -40), Vector2i(-30, -30), prof).size(), 0,
			"off the map there is no route, and no polyline")


## End to end: a unit dispatched over the live road network drives streets, and
## arrives exactly when doc 10 said it would.
func test_dispatch_over_the_road_network_drives_streets() -> void:
	var net := _network()
	var provider := net.travel_time_provider()
	var fleet := FleetSystem.new(_catalog(), provider)
	fleet.populate_from_stations([{"id": "S1", "archetype": "fire_station",
			"level": 1, "tile": Vector2i(39, 32)}])
	assert_true(fleet.size() > 0, "the station housed at least one unit")
	var u: Vehicle = fleet.unit(int(fleet.unit_ids()[0]))
	fleet.now_h = 5.0
	var target := Vector2i(47, 48)
	var eta := fleet.eta_h(u, target)
	assert_false(is_inf(eta), "the target is reachable")
	assert_true(fleet.dispatch(u, 7, target, u.role if u.role != "" else "fire"))
	assert_almost_eq(u.arrive_at_h, 5.0 + eta, EPS,
			"arrival is the provider's answer, unchanged by the polyline")
	assert_true(u.route.size() > 2, "and the route is a street polyline")
	assert_eq(u.route[0], Vector2i(39, 32))
	assert_eq(u.route[u.route.size() - 1], target)
	# Midway the unit is on a road tile, not inside a block.
	fleet.advance_to(5.0 + eta * 0.5)
	assert_true(net.graph.is_road_tile(u.tile) or u.tile == target,
			"a unit halfway through its call is on a street")
	fleet.advance_to(u.arrive_at_h)
	assert_eq(u.status, Vehicle.ON_SCENE)
	assert_eq(u.tile, target, "and it is on scene, on time")
