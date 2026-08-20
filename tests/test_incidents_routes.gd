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


# ===================================== the seam, and the fact that it is LIVE
#
# Everything above proves the provider works. This block pins what the shipped
# `CitySim` does with it, and since Wave 9 the answer is: **it constructs the
# ROUTER** (report 98 RR-26 / RR-27). Wave 8 held the wiring because doc 06 had
# no terminal rule for an incident nobody can answer and a full A\* quote was
# ~5 ms; both are ruled and both shipped, and `CitySim`'s comment at the seam
# carries the history.
#
# The pin is inverted rather than deleted, so a regression to the Chebyshev
# stand-in fails LOUDLY instead of quietly making every ETA a diagonal again.

func test_boot_puts_roads_before_incidents() -> void:
	# The ordering constraint the wiring rests on, landed ahead of the wiring:
	# incidents cannot be handed a router that does not exist yet, and roads is a
	# leaf with respect to incidents, so the swap costs nothing and is done.
	var sim := CitySim.boot_from_files(1337)
	assert_eq(str(sim.boot_errors), str(PackedStringArray()), "boots clean in the new order")
	assert_true(sim.roads != null and sim.incidents != null)
	assert_true(sim.incidents.fleet.size() > 0, "and the fleet still populated")


func test_the_router_is_what_the_shipped_sim_holds() -> void:
	var sim := CitySim.boot_from_files(1337)
	assert_true(sim.incidents.travel is RoadTravelTimeProvider,
			"the shipped sim must price dispatch on doc 10's router (RR-26/RR-27) "
			+ "— a fall back to the Chebyshev stand-in makes every ETA a "
			+ "diagonal again and silently un-does doc 06 §2.10")
	assert_true((sim.incidents.travel as RoadTravelTimeProvider).network == sim.roads,
			"and on THIS city's road network, not a detached one")
	# …and the whole fleet agrees on one provider.
	assert_true(sim.incidents.fleet.travel == sim.incidents.travel)
	assert_true(sim.incidents.dispatch.travel == sim.incidents.travel)
	# Doc 10's quote budget reaches doc 06 through the seam, so §2.10's
	# rank-then-quote pass is really bounded rather than nominally bounded.
	assert_eq(sim.incidents.travel.dispatch_candidates(), sim.roads.dispatch_candidates())
	assert_true(sim.incidents.travel.dispatch_candidates() > 0,
			"0 means `quote everyone`, which is the stand-in's answer")


## Doc 06 §2.11 gives every vehicle type its own `speed_mpgm`, and §2.10's
## `eta_minutes` passes it across the seam. Until Wave 9 this class ignored the
## dictionary and priced every trip on one fixed profile, so a fire engine (26)
## and a construction crew (18) were both quoted at a patrol car's 32.
func test_the_seam_honours_doc_06s_per_vehicle_speed() -> void:
	var sim := CitySim.boot_from_files(1337)
	var router := sim.roads.travel_time_provider()
	var from := Vector2i(39, 32)
	var to := Vector2i(47, 48)
	var fast: int = router.travel_gs(from, to, {"speed_mpgm": 32.0})
	var slow: int = router.travel_gs(from, to, {"speed_mpgm": 18.0})
	assert_true(fast < TravelTimeProvider.UNREACHABLE_GS and slow < TravelTimeProvider.UNREACHABLE_GS)
	assert_true(slow > fast,
			"a construction crew at 18 m/gm cannot arrive when a patrol car at 32 does "
			+ "(%d vs %d game-s)" % [slow, fast])
	# The same trip with the siren folded in is faster again, and it is the
	# PRODUCT doc 06 authors that reaches doc 10, not two separate multipliers.
	var siren: int = router.travel_gs(from, to,
			{"speed_mpgm": 26.0, "siren": true, "siren_mult": 1.25})
	var plain: int = router.travel_gs(from, to, {"speed_mpgm": 26.0})
	assert_true(siren < plain, "the siren buys time (%d vs %d game-s)" % [siren, plain])
	assert_eq(siren, router.travel_gs(from, to, {"speed_mpgm": 32.5}),
			"26 × 1.25 = 32.5 and there is only one speed at the seam")


func test_the_router_drops_into_the_seam_with_no_other_change() -> void:
	# The one line, exercised. If this ever stops compiling or stops producing a
	# live dispatcher, the seam has rotted while nobody was using it — which is
	# precisely how it got two waves out of date the first time.
	var sim := CitySim.boot_from_files(1337)
	var wired := IncidentSystem.new(IncidentCatalog.load_from_files(),
			CityIncidentWorld.new(sim, IncidentCatalog.load_from_files()),
			RngStreams.new(1337), sim.roads.travel_time_provider())
	assert_true(wired.travel is RoadTravelTimeProvider)
	assert_true((wired.travel as RoadTravelTimeProvider).network == sim.roads)
	assert_true(wired.fleet.travel == wired.travel, "one provider, both consumers")
	assert_true(wired.dispatch.travel == wired.travel)
	assert_eq(wired.travel.dispatch_candidates(),
			sim.roads.dispatch_candidates(),
			"and doc 10's quote budget reaches doc 06 through the seam")


## The number the wiring would move: an ETA becomes a street distance, not a
## diagonal. The starter city's stations and its far corner are a real L, so the
## router's answer must be strictly longer than the crow-flies model's.
func test_etas_are_street_true_not_chebyshev() -> void:
	var sim := CitySim.boot_from_files(1337)
	var router := sim.roads.travel_time_provider()
	var from := Vector2i(39, 32)
	var to := Vector2i(47, 48)
	var profile := {"speed_mpgm": 32.0}
	var chebyshev := TravelTimeProvider.new().travel_gs(from, to, profile)
	var street: int = router.travel_gs(from, to, profile)
	assert_true(street < TravelTimeProvider.UNREACHABLE_GS, "the corner is reachable")
	assert_true(street > chebyshev,
			("a street route (%d game-s) must cost more than the diagonal it "
					+ "replaced (%d game-s)") % [street, chebyshev])


## Doc 10 §7 publishes FOUR things to doc 06, and when this class landed only one
## of them was overridden — so a provider that knew every street still answered
## doc 06's other three questions with the pre-router constants. All four are
## implemented now, whatever `CitySim` chooses to construct.
func test_the_other_three_published_inputs_are_live() -> void:
	var sim := CitySim.boot_from_files(1337)
	var provider := sim.roads.travel_time_provider()
	var on_street := Vector2i(39, 32)
	assert_almost_eq(provider.access_quality(on_street),
			sim.roads.access_quality(on_street), 1e-12,
			"access_quality is doc 10's, unrescaled (C-61)")
	# Off the map there is no street at all, and the answers degrade to the
	# pre-router defaults rather than to nonsense.
	var nowhere := Vector2i(-40, -40)
	assert_almost_eq(provider.access_quality(nowhere), 0.0, 1e-12)
	assert_almost_eq(provider.congestion_index(nowhere), 0.0, 1e-12)
	assert_almost_eq(provider.condition_hazard_mult(nowhere), 1.0, 1e-12)
	# On a street they are the edge's own numbers.
	var edge_id := sim.roads.edge_at_position(on_street)
	assert_true(edge_id >= 0, "the station tile snaps to a street")
	assert_almost_eq(provider.congestion_index(on_street),
			sim.roads.congestion_index(edge_id), 1e-12)
	assert_almost_eq(provider.condition_hazard_mult(on_street),
			sim.roads.condition_hazard_mult(edge_id), 1e-12)


## And they are not decorative: a collapsed street degrades doc 06's response
## through `access_factor`'s knee. This is the whole reason doc 06 asks doc 10
## the question at all.
func test_a_ruined_street_degrades_the_response_it_serves() -> void:
	var sim := CitySim.boot_from_files(1337)
	var router := sim.roads.travel_time_provider()
	var tile := Vector2i(39, 32)
	var before := router.access_quality(tile)
	assert_true(before >= 0.60,
			"the founding city's own fire station is well served (%.3f)" % before)
	# Ruin every road tile within snapping distance of the station.
	for dz in range(-6, 7):
		for dx in range(-6, 7):
			var t := Vector2i(tile.x + dx, tile.y + dz)
			if sim.roads.graph.is_road_tile(t):
				sim.roads.set_condition(t, 0.0)
	var after := router.access_quality(tile)
	assert_true(after < 0.60,
			("a collapsed street must fall through doc 06's 0.60 knee; "
					+ "measured %.3f") % after)
	assert_true(after < before, "and it must fall, not merely differ")


# ------------------- every power component has a place a truck can drive to

## **The defect real routing exposed.** `data/starter_city.json` spells a
## substation's and a plant's location `terminal`, not `tile`, so
## `CitySim._boot_power` added both with no location and doc 04's record
## defaulted to (0, 0). Doc 06 uses that record as the incident position, and
## the map corner has no street within snapping distance — so the router
## correctly answered `unreachable`, no unit was ever sent, and the failure
## escalated to destruction. Measured on the doc 92 rig, `balanced` seed 1337:
## one such failure on game-day 17 took the 50-game-day dark share from 8.7 % to
## 61.8 % and broke balance gates 18 and 18b.
func test_every_power_component_stands_somewhere_a_unit_can_reach() -> void:
	var sim := CitySim.boot_from_files(1337)
	for id in sim.grid.component_ids():
		var component: Dictionary = sim.grid.component(String(id))
		var tile: Vector2i = component["tile"]
		assert_ne(tile, Vector2i.ZERO,
				"power component %s (%s) is parked at the map origin"
						% [String(id), String(component["kind"])])
		assert_true(sim.roads.graph.nearest_road_tile(tile).x >= 0,
				"no street within snapping distance of %s at %s — doc 06 cannot "
						% [String(id), str(tile)] + "dispatch to it")


## And the authored terminals are the authored terminals, not something derived.
func test_the_authored_terminals_are_where_doc_09_put_them() -> void:
	var sim := CitySim.boot_from_files(1337)
	assert_eq(sim.grid.component("SUB-A")["tile"],
			StarterCityLoader.core_to_global(32, 18),
			"doc 09 §2.9.5 puts SUB-A's terminal here, and it is where a "
			+ "substation failure is answered")
	assert_eq(sim.grid.component("PLANT-1")["tile"],
			StarterCityLoader.core_to_global(39, 41))


## A save written before the fix carries (0, 0); a load must not restore it,
## because a boot-authored terminal is boot data and not player state.
func test_a_legacy_body_does_not_move_the_substation_back_to_the_origin() -> void:
	var sim := CitySim.boot_from_files(1337)
	var body := sim.canonical_capture()
	var grid_body: Dictionary = body["grid"]
	var touched := 0
	for row_variant in (grid_body["components"] as Array):
		var row: Dictionary = row_variant
		if String(row["id"]) == "SUB-A" or String(row["id"]) == "PLANT-1":
			row["tile"] = [0, 0]
			touched += 1
	assert_eq(touched, 2, "the fixture forged both terminal components")
	var restored := CitySim.boot_from_files(1337)
	restored.restore_state(body)
	assert_eq(restored.grid.component("SUB-A")["tile"],
			StarterCityLoader.core_to_global(32, 18),
			"the authored terminal is re-stamped on load")
	assert_eq(restored.grid.component("PLANT-1")["tile"],
			StarterCityLoader.core_to_global(39, 41))


## The consequence, end to end: fail the substation and a unit is actually sent.
func test_a_substation_failure_is_dispatchable() -> void:
	var sim := CitySim.boot_from_files(1337)
	var inc := sim.incidents.spawn_scripted_component_failure("SUB-A", 2.0,
			{"source": "test"})
	assert_true(inc != null, "the failure raised an incident")
	assert_eq(inc.tile, StarterCityLoader.core_to_global(32, 18),
			"…at the substation, not at the map origin")
	# The half that matters for the defect: doc 10 can find a route to where the
	# incident actually is. At (0, 0) it could not, and this is the assertion
	# that will fail the day somebody drops the terminal tile again.
	var router := sim.roads.travel_time_provider()
	var station := Vector2i(39, 32)      # the founding fire station
	assert_true(router.travel_gs(station, inc.tile) < TravelTimeProvider.UNREACHABLE_GS,
			"no street route from the fire station to the substation")
	for _h in 3:
		sim.advance_coarse_hours(1, false)
	assert_false(inc.unreachable, "dispatch could not reach it")
	assert_true(inc.assigned.size() > 0 or inc.is_terminal(),
			"a unit was sent (or the incident was already answered and closed)")
