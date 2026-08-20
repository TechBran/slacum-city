extends SimTest
## LIVING CONSTRUCTION (doc 11 §2.16) — the plant, the deliveries and the yard.
##
## Five things are pinned here, and they are the five that can break:
##
##   1. THE BODIES. Triangle budgets, the joint chain the shader walks, and the
##      surface codes it switches on. A mesh that carries a joint the shader
##      does not know about is a machine that draws in pieces.
##   2. THE LIFECYCLE. A lorry leaves a depot, drives REAL STREETS, arrives,
##      tips, and goes home — once per cadence, never two where one was meant,
##      and never a body left standing on the kerb after its trip.
##   3. THE YARD. Piles grow monotonically with deliveries at a fixed stage,
##      and come DOWN as the stages advance. That is the whole read: material
##      arrives, material is used.
##   4. THE FRONTAGE. A corner lot fronts on a FACE, never on the diagonal tile
##      between its two streets, and the lorry stops in front of the lot. This
##      one is here because a SCREENSHOT found it and no assertion could have:
##      the wrong tile still yields a valid frame, a valid route and a lorry on
##      real streets — it just parks past the lot's own corner.
##   5. HASH NEUTRALITY. This layer asks doc 10 for routes off the LIVE road
##      network, which walks the planner's LRU. `test_route_lookups_do_not_move
##      _the_state_hash` interleaves exactly those lookups into a running sim
##      and compares `state_hash()` against a clean run. If a future change to
##      the planner ever makes a renderer read observable, this is what goes
##      red — not a screenshot three waves later.

const RENDER_JSON := "res://data/render.json"

## Doc 11 §2.16's budgets. The plant is a hero prop at Z0 and a smudge at Z2,
## so it is allowed more than a car (90) and less than a building LOD0.
const EXCAVATOR_TRI_MAX := 520
const TIPPER_TRI_MAX := 480
const PROP_TRI_MAX := 260
## Five MultiMeshes: two machines, two pile kinds, one barricade bay.
const DRAW_CALL_MAX := 5


func _render_data() -> Dictionary:
	return StarterCityLoader.read_json(RENDER_JSON)


func _view(net: RoadNetwork) -> ConstructionVehicleView:
	var view := ConstructionVehicleView.new()
	view.setup(_render_data())
	view.set_road_network(net)
	return view


## Drive the route queue to empty (two sites resolve per frame by design).
func _settle(view: ConstructionVehicleView, frames: int = 40) -> void:
	for i in frames:
		view.refresh(0.0, -1.0, 0.0)


## Park the layer at an exact game-minute. `gm_per_s = 0` freezes the internal
## clock and `game_minutes = -1` skips the re-sync, so the test owns the time.
func _at(view: ConstructionVehicleView, gm: float) -> void:
	view.set_game_minutes(gm)
	view.refresh(0.0, -1.0, 0.0)


## A site one tile off a road on the starter network, so the frontage frame and
## the route both have something real to bite on.
func _site_next_to_road(net: RoadNetwork) -> Dictionary:
	var tiles: Array = net.graph.road_tiles_sorted()
	for t: Vector2i in tiles:
		for step: Vector2i in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1),
				Vector2i(-1, 0)]:
			var lot := t + step
			if net.graph.is_road_tile(lot):
				continue
			if lot.x < 1 or lot.y < 1:
				continue
			return {"lot": lot, "road": t,
					"centre": Vector3(float(lot.x) * 8.0 + 4.0, 0.0,
							float(lot.y) * 8.0 + 4.0)}
	return {}


# ---------------------------------------------------------------- 1: bodies

func test_machine_bodies_fit_their_triangle_budgets() -> void:
	var exc := ConstructionRigMesh.excavator().tri_count()
	assert_true(exc > 0 and exc <= EXCAVATOR_TRI_MAX,
			"excavator is %d tris, budget %d" % [exc, EXCAVATOR_TRI_MAX])
	var tip := ConstructionRigMesh.dump_truck().tri_count()
	assert_true(tip > 0 and tip <= TIPPER_TRI_MAX,
			"tipper is %d tris, budget %d" % [tip, TIPPER_TRI_MAX])
	for name: String in ["heap", "stack", "barrier"]:
		var builder := ConstructionRigMesh.pile_heap() if name == "heap" \
				else (ConstructionRigMesh.pile_stack() if name == "stack"
				else ConstructionRigMesh.barrier_bay())
		var tris := builder.tri_count()
		assert_true(tris > 0 and tris <= PROP_TRI_MAX,
				"%s prop is %d tris, budget %d" % [name, tris, PROP_TRI_MAX])


## The excavator's whole reason for existing is that it articulates. Every one
## of the four joints has to actually carry geometry, or the shader is moving
## nothing.
func test_excavator_carries_all_four_joints() -> void:
	var mesh := ConstructionRigMesh.excavator().to_mesh()
	var uv2s: PackedVector2Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	var seen: Dictionary = {}
	for uv2: Vector2 in uv2s:
		seen[int(round(uv2.x))] = true
	for j in 5:
		assert_true(seen.has(j), "excavator has geometry on joint %d" % j)


## The tipper needs a chassis, a bed that hinges and a load that rides it —
## joints 0, 1 and 2, and nothing above, because the shader is told the chain
## stops there.
func test_tipper_carries_chassis_bed_and_load() -> void:
	var builder := ConstructionRigMesh.dump_truck()
	assert_eq(builder.max_joint(), 2, "tipper chain depth")
	var mesh := builder.to_mesh()
	var uv2s: PackedVector2Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	var seen: Dictionary = {}
	for uv2: Vector2 in uv2s:
		seen[int(round(uv2.x))] = true
	for j in 3:
		assert_true(seen.has(j), "tipper has geometry on joint %d" % j)


## Every vertex's surface code has to be one the shader's five branches know.
## A stray code lands on the last branch and draws a hubcap as a headlamp.
func test_surface_codes_are_all_known() -> void:
	var known := [ConstructionRigMesh.SURF_STEEL, ConstructionRigMesh.SURF_STOCK,
			ConstructionRigMesh.SURF_GLASS, ConstructionRigMesh.SURF_BEACON,
			ConstructionRigMesh.SURF_HEADLAMP]
	for builder: ConstructionRigMesh in [ConstructionRigMesh.excavator(),
			ConstructionRigMesh.dump_truck(), ConstructionRigMesh.pile_heap(),
			ConstructionRigMesh.pile_stack(), ConstructionRigMesh.barrier_bay()]:
		var uv2s: PackedVector2Array = builder.to_mesh() \
				.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
		for uv2: Vector2 in uv2s:
			assert_true(known.has(snappedf(uv2.y, 1.0)),
					"surface code %f is one of the shader's five" % uv2.y)


## The load is authored on the bed floor plane the shader squashes towards; if
## the two ever drift apart an empty lorry shows its load sunk through the bed.
func test_tipper_load_sits_on_the_floor_the_shader_squashes_to() -> void:
	var mesh := ConstructionRigMesh.dump_truck().to_mesh()
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv2s: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var lowest := INF
	for i in verts.size():
		if int(round(uv2s[i].x)) == int(ConstructionRigMesh.JOINT_2):
			lowest = minf(lowest, verts[i].y)
	assert_almost_eq(lowest, ConstructionRigMesh.TIP_LOAD_FLOOR_Y, 0.001,
			"the load's lowest vertex is the shader's squash plane")


## The dig loop has to close: the pose at the end of a cycle is the pose at the
## start, or every excavator in the city snaps once every seven seconds.
func test_dig_cycle_closes_and_stays_inside_its_envelopes() -> void:
	var start := ConstructionActivity.dig_pose(0.0)
	var end := ConstructionActivity.dig_pose(1.0)
	assert_almost_eq(start.r, end.r, 0.0005, "slew")
	assert_almost_eq(start.g, end.g, 0.0005, "boom")
	assert_almost_eq(start.b, end.b, 0.0005, "arm")
	assert_almost_eq(start.a, end.a, 0.0005, "bucket")
	for i in 41:
		var pose := ConstructionActivity.dig_pose(float(i) / 40.0)
		for channel: float in [pose.r, pose.g, pose.b, pose.a]:
			assert_true(channel >= 0.0 and channel <= 1.0,
					"joint channel %f stays inside 0..1" % channel)


# ------------------------------------------------------------- 2: the streets

func test_polyline_is_lane_offset_corner_rounded_and_monotone() -> void:
	var tiles: Array = []
	for x in range(4, 12):
		tiles.append(Vector2i(x, 6))
	for z in range(7, 12):
		tiles.append(Vector2i(11, z))
	var line := ConstructionActivity.polyline_from_tiles(tiles, 8.0, 0.1, 1.85)
	assert_true(line.size() > tiles.size(), "corner rounding adds points")
	var cum := ConstructionActivity.cumulative(line)
	for i in range(1, cum.size()):
		assert_true(cum[i] >= cum[i - 1], "cumulative length never goes backwards")
	assert_true(cum[cum.size() - 1] > 60.0, "the run is roughly its tile length")
	# The straight opening leg runs +X, so the lane is pushed to +Z by exactly
	# `lane_offset` — the same right-hand side doc 10's traffic keeps to.
	assert_almost_eq(line[0].z, 6.0 * 8.0 + 4.0 + 1.85, 0.05,
			"outbound lane is offset to the right of the centreline")
	assert_almost_eq(line[0].y, 0.1, 0.0001, "the line sits on the road surface")


func test_polyline_reverses_onto_the_other_lane() -> void:
	var out_tiles: Array = []
	for x in range(4, 12):
		out_tiles.append(Vector2i(x, 6))
	var home_tiles := out_tiles.duplicate()
	home_tiles.reverse()
	var a := ConstructionActivity.polyline_from_tiles(out_tiles, 8.0, 0.1, 1.85)
	var b := ConstructionActivity.polyline_from_tiles(home_tiles, 8.0, 0.1, 1.85)
	var centre := 6.0 * 8.0 + 4.0
	assert_true(a[0].z > centre and b[0].z < centre,
			"a lorry going out and a lorry coming back pass on opposite lanes")


func test_sample_polyline_clamps_and_reads_its_heading() -> void:
	var line := PackedVector3Array([Vector3(0.0, 0.1, 0.0), Vector3(40.0, 0.1, 0.0)])
	var cum := ConstructionActivity.cumulative(line)
	var mid := ConstructionActivity.sample_polyline(line, cum, 20.0)
	assert_almost_eq(mid.x, 20.0, 0.001)
	assert_almost_eq(mid.w, 0.0, 0.001, "heading 0 rad is +X")
	assert_almost_eq(ConstructionActivity.sample_polyline(line, cum, -5.0).x, 0.0,
			0.001, "before the start clamps to the start")
	assert_almost_eq(ConstructionActivity.sample_polyline(line, cum, 900.0).x, 40.0,
			0.001, "past the end clamps to the end")


# --------------------------------------------------------- 3: the lifecycle

func test_a_site_resolves_a_depot_and_a_street_true_route() -> void:
	var net := RoadsTestRig.starter_network()
	var spot := _site_next_to_road(net)
	assert_false(spot.is_empty(), "the starter city has a lot beside a road")
	var view := _view(net)
	view.add_site(7, spot["centre"], Vector2i(1, 1), 12.0)
	_settle(view)
	var site: ConstructionActivity.Site = view.activity.sites[7]
	assert_true(site.frontage_ok, "the site found its street frontage")
	assert_eq(site.road_tile, spot["road"], "frontage is the nearest road tile")
	assert_true(site.has_route(), "and a route from a depot to it")
	assert_true(site.route_m > 8.0, "the depot is not next door")
	# Street-true: every metre of the run stands on a tile the road graph owns.
	var stray := 0
	var d := 0.0
	while d <= site.route_m:
		var p := ConstructionActivity.sample_polyline(site.to_site, site.to_site_cum, d)
		var tile := Vector2i(int(floor(p.x / 8.0)), int(floor(p.z / 8.0)))
		if not net.graph.is_road_tile(tile):
			stray += 1
		d += 2.0
	assert_eq(stray, 0, "every sample of the delivery run is on a road tile")


## REGRESSION (found by screenshot, not by assertion). A corner lot must front
## on a FACE. `RoadGraph.nearest_road_tile` answers Chebyshev-nearest, so a lot
## with streets on two sides is handed the DIAGONAL tile between them; the
## frontage frame still reads the right side by dominant axis, but the lorry's
## stop lands past the lot's own corner with the plant strung out after it.
func test_a_corner_lot_fronts_on_a_face_not_on_the_diagonal() -> void:
	var tiles := RoadsTestRig.line(Vector2i(10, 10), Vector2i(30, 10),
			RoadTunables.CLASS_STREET)
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(10, 10), Vector2i(10, 30),
			RoadTunables.CLASS_STREET))
	var net := RoadsTestRig.network_with(tiles)
	# A 2x2 lot tucked into the corner: tiles (11,11)…(12,12), so the diagonal
	# road tile (10,10) is exactly as Chebyshev-near as the two face tiles.
	var view := _view(net)
	view.add_site(91, Vector3(96.0, 0.0, 96.0), Vector2i(2, 2), 12.0)
	_settle(view)
	var site: ConstructionActivity.Site = view.activity.sites[91]
	assert_true(site.frontage_ok, "the corner lot found a frontage")
	assert_ne(site.road_tile, Vector2i(10, 10), "and it is not the diagonal tile")
	var faces := [Vector2i(11, 10), Vector2i(12, 10), Vector2i(10, 11), Vector2i(10, 12)]
	assert_true(faces.has(site.road_tile),
			"it is straight out from one of the lot's faces, got %s"
			% str(site.road_tile))
	assert_true(absf(site.stop_u) <= site.half_frontage + 0.01,
			"and the lorry stops in FRONT of the lot: |u| %.2f vs half-frontage %.2f"
			% [absf(site.stop_u), site.half_frontage])


## The depot override. The default is the road network's outer ring — where the
## streets leave the built city — but a caller that knows where material really
## comes from names the tiles instead, and every lorry then leaves from one.
func test_named_depots_replace_the_outer_ring_default() -> void:
	var net := RoadsTestRig.starter_network()
	var spot := _site_next_to_road(net)
	var tiles: Array = net.graph.road_tiles_sorted()
	var named: Array[Vector2i] = [tiles[tiles.size() / 3], tiles[tiles.size() / 2],
			tiles[(tiles.size() * 2) / 3]]
	var view := _view(net)
	view.set_depots(named)
	view.add_site(93, spot["centre"], Vector2i(1, 1), 12.0)
	_settle(view)
	var site: ConstructionActivity.Site = view.activity.sites[93]
	assert_true(site.has_route(), "the site still resolves a route")
	assert_true(named.has(site.depot_tile),
			"and it comes from a NAMED depot, got %s" % str(site.depot_tile))


## One cadence, one lorry: out, tip, home, gone. The gaps matter as much as the
## presences — a body that never despawns is a body that piles up.
func test_one_delivery_runs_out_tips_and_comes_home() -> void:
	var net := RoadsTestRig.starter_network()
	var spot := _site_next_to_road(net)
	var view := _view(net)
	view.add_site(11, spot["centre"], Vector2i(1, 1), 12.0)
	_settle(view)
	var site: ConstructionActivity.Site = view.activity.sites[11]
	var leg := view.activity.leg_gm(site)
	var dump := view.activity.dump_gm
	var trip := view.activity.trip_gm(site)
	assert_true(trip > 0.0, "the site has a round trip to run")

	# Just before the first departure: an empty kerb.
	_at(view, site.offset_gm - 0.5)
	assert_eq(view.activity.truck_used, 0, "no lorry before the first departure")

	# Outbound, a quarter of the way: one lorry, loaded, bed down, near the
	# depot end of the run.
	_at(view, site.offset_gm + leg * 0.25)
	assert_eq(view.activity.truck_used, 1, "one lorry on the delivery run")
	var rolling: ConstructionActivity.Pose = view.activity.truck_poses[0]
	assert_almost_eq(rolling.custom.r, 0.0, 0.001, "bed is down while rolling")
	assert_almost_eq(rolling.custom.g, 1.0, 0.001, "and it is carrying a load")
	var depot_w := Vector3(float(site.depot_tile.x) * 8.0 + 4.0, 0.0,
			float(site.depot_tile.y) * 8.0 + 4.0)
	var quarter := rolling.origin.distance_to(depot_w)
	assert_true(quarter < site.route_m * 0.6,
			"a quarter of the way in it is still nearer the depot than the site")

	# Mid-dump: standing at the site with the bed up.
	_at(view, site.offset_gm + leg + dump * 0.5)
	assert_eq(view.activity.truck_used, 1, "the lorry is still there, tipping")
	var tipping: ConstructionActivity.Pose = view.activity.truck_poses[0]
	assert_true(tipping.custom.r > 0.6, "the bed is up")
	var site_end := ConstructionActivity.sample_polyline(site.to_site,
			site.to_site_cum, site.route_m)
	assert_true(tipping.origin.distance_to(
			Vector3(site_end.x, view.activity.road_top, site_end.z)) < 0.6,
			"and it is standing at the end of the run, not mid-street")

	# Homeward: bed down again, empty.
	_at(view, site.offset_gm + leg + dump + (leg * 0.5))
	assert_eq(view.activity.truck_used, 1, "one lorry on the way home")
	var homeward: ConstructionActivity.Pose = view.activity.truck_poses[0]
	assert_almost_eq(homeward.custom.r, 0.0, 0.001, "bed down for the road")
	assert_almost_eq(homeward.custom.g, 0.0, 0.001, "and the bed is empty")

	# After the trip and before the next departure: gone.
	_at(view, site.offset_gm + trip + (site.period_gm - trip) * 0.5)
	assert_eq(view.activity.truck_used, 0, "the lorry despawned at the depot")


## Two sites never run a convoy: the cadence and the phase are both hashed off
## the building id.
func test_two_sites_do_not_deliver_in_lockstep() -> void:
	var net := RoadsTestRig.starter_network()
	var spot := _site_next_to_road(net)
	var view := _view(net)
	view.add_site(101, spot["centre"], Vector2i(1, 1), 12.0)
	view.add_site(102, spot["centre"] + Vector3(0.0, 0.0, 8.0), Vector2i(1, 1), 12.0)
	_settle(view)
	var a: ConstructionActivity.Site = view.activity.sites[101]
	var b: ConstructionActivity.Site = view.activity.sites[102]
	assert_ne(a.period_gm, b.period_gm, "different cadences")
	assert_ne(a.offset_gm, b.offset_gm, "and different phases")


## The excavators are an EARLY-stage read: two while the ground is being opened,
## none once the building is topping out.
func test_excavators_thin_out_as_the_building_rises() -> void:
	var net := RoadsTestRig.starter_network()
	var spot := _site_next_to_road(net)
	var view := _view(net)
	view.add_site(21, spot["centre"], Vector2i(1, 1), 12.0)
	_settle(view)
	var counts: Array[int] = []
	for stage in range(1, 7):
		view.set_stage(21, stage)
		_at(view, 100.0)
		counts.append(view.activity.rig_used)
	assert_eq(counts[0], 2, "stage 1 opens the ground with two machines")
	assert_eq(counts[5], 0, "stage 6 has no digging left to do")
	for i in range(1, counts.size()):
		assert_true(counts[i] <= counts[i - 1],
				"the machine count never goes back up: %s" % str(counts))


## The barricades come down as the site finishes — the last visible beat of the
## cleanup story.
func test_the_work_zone_is_lifted_as_the_site_finishes() -> void:
	var net := RoadsTestRig.starter_network()
	var spot := _site_next_to_road(net)
	var view := _view(net)
	view.add_site(31, spot["centre"], Vector2i(2, 2), 24.0)
	_settle(view)
	view.set_stage(31, 1)
	_at(view, 50.0)
	var full := view.activity.barrier_used
	assert_true(full >= 3, "a two-tile frontage is fenced by several bays")
	view.set_stage(31, 6)
	_at(view, 50.0)
	assert_eq(view.activity.barrier_used, 1,
			"one token bay is left by the time the last lorry has gone")


# -------------------------------------------------------------- 4: the yard

## The invariant the player actually reads: at a fixed stage, material only
## arrives. Sampled across four cadences of a real route.
func test_pile_growth_is_monotonic_at_a_fixed_stage() -> void:
	var net := RoadsTestRig.starter_network()
	var spot := _site_next_to_road(net)
	var view := _view(net)
	view.add_site(41, spot["centre"], Vector2i(1, 1), 12.0)
	_settle(view)
	var site: ConstructionActivity.Site = view.activity.sites[41]
	view.set_stage(41, 1)
	var last: Array[float] = [0.0, 0.0, 0.0]
	var last_total := 0.0
	var span := site.period_gm * 4.0
	for i in 241:
		var gm := site.offset_gm + span * float(i) / 240.0
		_at(view, gm)
		var total := view.activity.delivered_at(site, gm)
		assert_true(total >= last_total - 1e-5,
				"deliveries never go backwards (%f -> %f)" % [last_total, total])
		last_total = total
		for slot in ConstructionActivity.PILE_SLOTS:
			var fill := view.activity.pile_fill(site, slot, site.delivered)
			assert_true(fill >= last[slot] - 1e-5,
					"pile %d never shrinks at a fixed stage (%f -> %f)"
					% [slot, last[slot], fill])
			last[slot] = fill
	assert_true(last_total >= 3.0,
			"four cadences delivered at least three loads, got %f" % last_total)
	assert_true(last[0] > 0.0, "and the first heap is standing")


## …and the other half of the read: a stage CONSUMES what was delivered into
## it, and each stage holds less than the one before. Measured as the peak fill
## reached during an identical stretch of game time at each stage, which is the
## only fair comparison — comparing instants would only measure where in a
## cadence each sample landed.
func test_each_stage_holds_less_of_the_yard_than_the_one_before() -> void:
	var net := RoadsTestRig.starter_network()
	var spot := _site_next_to_road(net)
	var view := _view(net)
	view.add_site(43, spot["centre"], Vector2i(1, 1), 12.0)
	_settle(view)
	var site: ConstructionActivity.Site = view.activity.sites[43]
	var window := site.period_gm * 9.0
	var clock := site.offset_gm
	var peaks: Array[float] = []
	for stage in range(1, 7):
		view.set_stage(43, stage)
		# The stage change consumed the yard: nothing is standing yet.
		assert_almost_eq(view.activity.pile_fill(site, 0, site.delivered), 0.0,
				0.001, "stage %d starts from a cleared kerb" % stage)
		var peak := 0.0
		for i in 61:
			clock = site.offset_gm + window * float(stage - 1) \
					+ window * float(i) / 60.0
			_at(view, clock)
			peak = maxf(peak, view.activity.pile_fill(site, 0, site.delivered))
		peaks.append(peak)
	assert_true(peaks[0] > 0.4,
			"a site being dug keeps a real heap, got %f" % peaks[0])
	for i in range(1, peaks.size()):
		assert_true(peaks[i] <= peaks[i - 1] + 1e-6,
				"stage %d holds no more than stage %d (%f -> %f)"
				% [i + 1, i, peaks[i - 1], peaks[i]])
	assert_almost_eq(peaks[peaks.size() - 1], 0.0, 0.001,
			"and the kerb is clear by the time the site tops out")


## Cleanup reverses the flow: the lorry comes in empty and leaves loaded.
func test_cleanup_stages_haul_spoil_out_instead_of_material_in() -> void:
	var net := RoadsTestRig.starter_network()
	var spot := _site_next_to_road(net)
	var view := _view(net)
	view.add_site(47, spot["centre"], Vector2i(1, 1), 12.0)
	_settle(view)
	var site: ConstructionActivity.Site = view.activity.sites[47]
	view.set_stage(47, ConstructionActivity.CLEANUP_STAGE)
	var leg := view.activity.leg_gm(site)
	_at(view, site.offset_gm + leg * 0.4)
	assert_almost_eq((view.activity.truck_poses[0] as ConstructionActivity.Pose)
			.custom.g, 0.0, 0.001, "arrives empty")
	_at(view, site.offset_gm + leg + view.activity.dump_gm + leg * 0.4)
	assert_almost_eq((view.activity.truck_poses[0] as ConstructionActivity.Pose)
			.custom.g, 1.0, 0.001, "leaves with the spoil")


# ------------------------------------------------------ 5: budget & purity

func test_the_whole_layer_costs_five_draw_calls() -> void:
	var view := ConstructionVehicleView.new()
	view.setup(_render_data())
	assert_eq(view.layer_count(), DRAW_CALL_MAX,
			"doc 11 §2.16's budget: two machines, two pile kinds, one barricade")


## Same site, same clock, two independently built views: byte-identical poses.
## Nothing here may depend on frame history, allocation order or a wall clock.
func test_the_layer_is_a_pure_function_of_the_site_and_the_clock() -> void:
	var net := RoadsTestRig.starter_network()
	var spot := _site_next_to_road(net)
	var a := _view(net)
	var b := _view(RoadsTestRig.starter_network())
	for view: ConstructionVehicleView in [a, b]:
		view.add_site(61, spot["centre"], Vector2i(1, 1), 12.0)
		view.add_site(62, spot["centre"] + Vector3(16.0, 0.0, 0.0), Vector2i(1, 1), 30.0)
		_settle(view)
		view.set_stage(61, 2)
		view.set_stage(62, 3)
	for gm: float in [13.5, 77.0, 401.25]:
		_at(a, gm)
		_at(b, gm)
		assert_eq(a.activity.truck_used, b.activity.truck_used, "lorry count at %f" % gm)
		assert_eq(a.activity.rig_used, b.activity.rig_used, "machine count at %f" % gm)
		assert_eq(a.activity.heap_used, b.activity.heap_used, "heap count at %f" % gm)
		for i in a.activity.rig_used:
			var pa: ConstructionActivity.Pose = a.activity.rig_poses[i]
			var pb: ConstructionActivity.Pose = b.activity.rig_poses[i]
			assert_eq(pa.origin, pb.origin, "machine %d stands in one place" % i)
			assert_eq(pa.custom, pb.custom, "machine %d is at one point of its cycle" % i)
		for i in a.activity.truck_used:
			var ta: ConstructionActivity.Pose = a.activity.truck_poses[i]
			var tb: ConstructionActivity.Pose = b.activity.truck_poses[i]
			assert_eq(ta.origin, tb.origin, "lorry %d is at one point of its run" % i)


## A site with no street keeps its hoarding and gets no traffic — the honest
## answer, and it must not throw on the way to giving it.
func test_a_site_with_no_street_draws_nothing_and_says_so() -> void:
	var net := RoadsTestRig.network_with(RoadsTestRig.line(Vector2i(2, 2),
			Vector2i(2, 20), RoadTunables.CLASS_STREET))
	var view := _view(net)
	view.add_site(71, Vector3(90.0 * 8.0, 0.0, 90.0 * 8.0), Vector2i(1, 1), 10.0)
	_settle(view)
	var site: ConstructionActivity.Site = view.activity.sites[71]
	assert_false(site.frontage_ok, "no road within the snap radius, no frontage")
	assert_eq(view.activity.truck_used, 0)
	assert_eq(view.activity.barrier_used, 0)


## THE HASH GATE. This layer reads `RoadNetwork.route_tiles()` off the LIVE
## network, which touches the route planner's LRU cache. A cache the renderer
## has churned must still hand the sim exactly the numbers it would have got on
## its own — otherwise a renderer feature has moved the simulation, which is the
## one thing doc 00 does not allow.
##
## The comparison is a clean 6-hour run against the same 6 hours with a
## renderer's worth of route lookups interleaved at every hour boundary.
func test_route_lookups_do_not_move_the_state_hash() -> void:
	var clean := CitySim.boot_from_files()
	for i in 6:
		clean.advance_hours(1.0)
	var expected := clean.state_hash()

	var live := CitySim.boot_from_files()
	var profile := RouteProfile.construction(21.0)
	var tiles: Array = live.roads.graph.road_tiles_sorted()
	assert_true(tiles.size() > 32, "the starter city has streets to route on")
	var lookups := 0
	for i in 6:
		live.advance_hours(1.0)
		# Twenty sites, each resolving an out-and-back leg: the worst frame this
		# layer can present to the planner, repeated every game-hour.
		for k in 40:
			var from: Vector2i = tiles[(i * 977 + k * 131) % tiles.size()]
			var to: Vector2i = tiles[(i * 613 + k * 37) % tiles.size()]
			live.roads.route_tiles(from, to, profile)
			lookups += 1
	assert_eq(lookups, 240, "the probe actually ran")
	assert_eq(live.state_hash(), expected,
			"a renderer's route lookups leave the simulation bit-identical")


# ----------------------------------------------- 6: the gate faces the street

## §2.16's filed open item 4. `ConstructionSiteView` opened its gate on
## `hash01(id, 7) % 4` while the vehicle layer stood its plant, its barricades
## and its lorry stop on the REAL frontage — the two layers agreed one time in
## four, and a player looking at a site saw a coned-off lane in front of a solid
## hoarding panel with the gate round the back.
func test_the_hoarding_gate_can_be_put_on_the_frontage() -> void:
	var net := RoadsTestRig.network_with(RoadsTestRig.line(Vector2i(10, 20),
			Vector2i(30, 20), RoadTunables.CLASS_STREET))
	var plant := _view(net)
	# A lot one tile SOUTH of the corridor, so its frontage is -Z (side 0).
	var lot := Vector2i(20, 21)
	var centre := Vector3(float(lot.x) * 8.0 + 4.0, 0.0, float(lot.y) * 8.0 + 4.0)
	var side := plant.frontage_side(centre, Vector2i.ONE)
	assert_eq(side, 0, "the street is to the -Z of the lot")
	var hoard := ConstructionSiteView.new()
	hoard.setup(_render_data())
	hoard.add_site(88, centre, Vector2i.ONE, 24.0, side)
	assert_eq(hoard.gate_side_of(88), side, "the gate went on the frontage")
	# And the two layers now name the same face for the same site.
	plant.add_site(88, centre, Vector2i.ONE, 24.0)
	_settle(plant)
	assert_eq(plant.frontage_side(88), hoard.gate_side_of(88),
			"plant and hoarding agree on which way the site faces")
	hoard.free()
	plant.free()


func test_the_gate_still_falls_back_to_the_hash_when_nobody_says() -> void:
	# Every pre-frontage call site omits the argument, and must draw exactly
	# what it drew before: `hash01(id, 7) % 4`.
	var hoard := ConstructionSiteView.new()
	hoard.setup(_render_data())
	for raw: Variant in [3, 17, 41, 99, 250]:
		var id := int(raw)
		hoard.add_site(id, Vector3(200.0, 0.0, 200.0), Vector2i.ONE, 20.0)
		var expected := int(ConstructionSiteView._hash01(id, 7) * 4.0) % 4
		assert_eq(hoard.gate_side_of(id), expected,
				"site %d keeps the hashed gate when no frontage is passed" % id)
		hoard.remove_site(id)
	hoard.free()


func test_a_re_route_moves_the_gate_with_it() -> void:
	# The route budget is two sites a frame, so the frontage can land AFTER the
	# hoarding went up — and a road edit can move it later. The signal is what
	# carries that across, and it must fire only when the side actually changes.
	var net := RoadsTestRig.network_with(RoadsTestRig.line(Vector2i(10, 20),
			Vector2i(30, 20), RoadTunables.CLASS_STREET))
	var plant := _view(net)
	var hoard := ConstructionSiteView.new()
	hoard.setup(_render_data())
	var seen: Array = []
	plant.site_frontage_changed.connect(func(id: int, side: int) -> void:
		seen.append([id, side])
		hoard.set_gate_side(id, side))
	var lot := Vector2i(20, 21)
	var centre := Vector3(float(lot.x) * 8.0 + 4.0, 0.0, float(lot.y) * 8.0 + 4.0)
	hoard.add_site(91, centre, Vector2i.ONE, 24.0)   # hashed, on purpose
	plant.add_site(91, centre, Vector2i.ONE, 24.0)
	_settle(plant)
	assert_eq(seen.size(), 1, "the frontage was announced once")
	assert_eq(hoard.gate_side_of(91), 0, "…and the gate turned to the street")
	_settle(plant)
	assert_eq(seen.size(), 1, "a settled site announces nothing further")
	# A lot on the far side of the same corridor fronts it from the other face.
	var lot2 := Vector2i(20, 19)
	var centre2 := Vector3(float(lot2.x) * 8.0 + 4.0, 0.0, float(lot2.y) * 8.0 + 4.0)
	hoard.add_site(92, centre2, Vector2i.ONE, 24.0)
	plant.add_site(92, centre2, Vector2i.ONE, 24.0)
	_settle(plant)
	assert_eq(plant.frontage_side(92), 2, "this one's street is to the +Z")
	assert_eq(hoard.gate_side_of(92), 2, "…and its gate followed the signal")
	hoard.free()
	plant.free()


# ═══════════════════ 6: the pose cache (doc 11 §2.16b, RR-42) ═══════════════
#
# The cache's WHOLE contract is that it changes nothing: the same sites at the
# same game-minutes emit the same poses, field for field, bit for bit, with it
# on and with it off. Everything below is that one claim, from three angles —
# a long scripted timeline, the two events that must invalidate it, and the
# tuning the schedule constants are derived from.

## `count` lots one tile off a road, walked in ascending tile order so the same
## lots come up on every run and both arms get the same city.
static func _lots_next_to_road(net: RoadNetwork, count: int) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for t: Vector2i in net.graph.road_tiles_sorted():
		if out.size() >= count:
			break
		for step: Vector2i in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1),
				Vector2i(-1, 0)]:
			var lot := t + step
			if out.size() >= count or net.graph.is_road_tile(lot) or seen.has(lot):
				continue
			if lot.x < 1 or lot.y < 1:
				continue
			seen[lot] = true
			out.append(Vector3(float(lot.x) * 8.0 + 4.0, 0.0, float(lot.y) * 8.0 + 4.0))
	return out


## Every field of every emitted pose, in emission order, as one comparable
## value. `Array` equality in GDScript is element-wise and recursive and every
## leaf here is a float-valued struct — so `==` on two of these is the bit
## identity the cache promises, not an approximation of it.
static func _pose_stream(activity: ConstructionActivity) -> Array:
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


func test_the_pose_cache_streams_bit_identical_poses_over_a_random_timeline() -> void:
	# One SCRIPT, replayed on both arms: same sites, same game-minutes, same
	# stage changes, same focus gate. A difference in the two streams can
	# therefore only be the cache.
	#
	# The focus gate is in the script on purpose. It is what makes a site sit a
	# pass out and come back to find the pool slice it used to own handed to
	# somebody else — the one way a slice-index cache can be wrong that no
	# amount of steady-state running would ever show.
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var script: Array = []
	var gm := 900.0
	for step in 700:
		gm += rng.randf_range(0.004, 0.9)
		script.append({
			"gm": gm,
			# A stage change every so often — the pile datum, the machine count
			# and the barricade run all move with it.
			"stage": [rng.randi_range(0, 11), rng.randi_range(1, 6)] \
					if rng.randf() < 0.05 else [],
			"focus": Vector3(rng.randf_range(0.0, 600.0), 0.0,
					rng.randf_range(0.0, 600.0)),
			"radius": rng.randf_range(60.0, 900.0),
		})

	var streams: Array = []
	for cache: bool in [false, true]:
		var net := RoadsTestRig.starter_network()
		var view := _view(net)
		var lots := _lots_next_to_road(net, 12)
		for i in lots.size():
			view.add_site(700 + i, lots[i], Vector2i(1, 1), 12.0 + float(i))
			view.set_stage(700 + i, 1 + (i % 6))
		_settle(view, 30)
		view.activity.pose_cache = cache
		view.activity.invalidate_pose_cache()
		var stream: Array = []
		for entry: Dictionary in script:
			var change: Array = entry["stage"]
			if not change.is_empty():
				view.set_stage(700 + int(change[0]), int(change[1]))
			view.activity.refresh(float(entry["gm"]), entry["focus"],
					float(entry["radius"]))
			stream.append(_pose_stream(view.activity))
		streams.append(stream)
		view.free()

	assert_eq(int(streams[0].size()), int(streams[1].size()),
			"both arms ran the whole script")
	var first_bad := -1
	for i in int(streams[0].size()):
		if streams[0][i] != streams[1][i]:
			first_bad = i
			break
	assert_eq(first_bad, -1,
			"cached and uncached pose streams agree on every one of %d frames"
			% int(streams[0].size()))


func test_a_re_route_and_a_stage_change_both_drop_the_pose_cache() -> void:
	# The two events that move a cached pose without moving the clock. If either
	# failed to invalidate, this is the shape the bug would take: a site whose
	# yard and barricades are still drawn against the frontage it used to have.
	var net := RoadsTestRig.starter_network()
	var warm := _view(net)
	var cold := _view(RoadsTestRig.starter_network())
	var lots := _lots_next_to_road(net, 4)
	for view: ConstructionVehicleView in [warm, cold]:
		for i in lots.size():
			view.add_site(760 + i, lots[i], Vector2i(1, 1), 18.0)
		_settle(view, 20)
	cold.activity.pose_cache = false
	for gm: float in [900.0, 900.02, 900.04]:
		warm.activity.refresh(gm)
		cold.activity.refresh(gm)
	warm.set_stage(761, 5)
	cold.set_stage(761, 5)
	warm.activity.refresh(900.06)
	cold.activity.refresh(900.06)
	assert_eq(_pose_stream(warm.activity), _pose_stream(cold.activity),
			"a stage change re-derives the site")
	# A road edit drops the routes; a cached yard must not survive one.
	warm.activity.clear_route(762)
	cold.activity.clear_route(762)
	warm.activity.set_route(762, Vector2i(-1, -1), Vector2i(-1, -1), [], [])
	cold.activity.set_route(762, Vector2i(-1, -1), Vector2i(-1, -1), [], [])
	warm.activity.refresh(900.08)
	cold.activity.refresh(900.08)
	assert_eq(_pose_stream(warm.activity), _pose_stream(cold.activity),
			"a re-route re-derives the site")
	warm.free()
	cold.free()


func test_the_schedule_constants_survive_a_reconfigure() -> void:
	# `_reprice` settles the leg, the round trip and the trip window off the
	# route, once. `configure()` moves the tuning they are derived FROM, so a
	# site that already has a route has to be re-priced — otherwise a preview
	# harness that retunes live would drive lorries on yesterday's schedule.
	var net := RoadsTestRig.starter_network()
	var view := _view(net)
	var lots := _lots_next_to_road(net, 1)
	view.add_site(770, lots[0], Vector2i(1, 1), 20.0)
	_settle(view, 20)
	var site: ConstructionActivity.Site = view.activity.sites[770]
	assert_true(site.has_route(), "the site resolved a route")
	var before := view.activity.leg_gm(site)
	assert_true(before > 0.0, "…of non-zero length")
	var cfg: Dictionary = (_render_data().get("construction_vehicles", {}) as Dictionary).duplicate()
	cfg["truck_speed_mpgm"] = view.activity.truck_speed_mpgm * 2.0
	view.activity.configure(cfg, view.activity.tile_m)
	assert_almost_eq(view.activity.leg_gm(site), before * 0.5, 0.0001,
			"a lorry twice as fast takes half as long")
	assert_almost_eq(view.activity.trip_gm(site),
			view.activity.leg_gm(site) * 2.0 + view.activity.dump_gm, 0.0001,
			"and the round trip follows it")
	view.free()
