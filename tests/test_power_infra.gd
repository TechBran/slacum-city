extends SimTest
## The VISIBLE power layer (doc 04 §2.1 / §2.6 drawn by doc 11): pad placement
## and orientation, service-wire span endpoints, the distress-band mapping, and
## the draw-call shape §2.13 budgets.
##
## Everything below runs headless against `PowerInfraModel` (pure arithmetic) and
## a real `PowerGrid` (the two new read-only accessors). `PowerInfraView` is
## exercised for the things that are only true of the NODES — buffer sizes, the
## wire gate, the pad mesh — and nothing here needs a display.

const RENDER_JSON := "res://data/render.json"
const PAD_SHADER := "res://game/shaders/power_pad.gdshader"
const WIRE_SHADER := "res://game/shaders/power_wire.gdshader"
const SMOKE_SHADER := "res://game/shaders/power_smoke.gdshader"

const TILE_M := 8.0


func _render_data() -> Dictionary:
	return StarterCityLoader.read_json(RENDER_JSON)


func _model() -> PowerInfraModel:
	return PowerInfraModel.new(_render_data())


## A road probe over an explicit tile set — the tests say which tiles are road
## and nothing has to boot a world for it.
func _roads(tiles: Array) -> Callable:
	var set_of: Dictionary = {}
	for t: Vector2i in tiles:
		set_of[t] = true
	return func(tile: Vector2i) -> bool:
		return set_of.has(tile)


func _building(center: Vector3, footprint := Vector2(8.0, 8.0),
		height := 9.0) -> Dictionary:
	return {"world_pos": center, "footprint_m": footprint, "height_m": height}


func _row(id: String, state := "OK", energized := true, load_ratio := 0.2,
		condition := 1.0, temp_c := 30.0) -> Dictionary:
	return {"id": id, "state": state, "energized": energized,
			"load_ratio": load_ratio, "condition": condition, "temp_c": temp_c,
			"customers": 3, "level": 2}


# ------------------------------------------------------------- pad placement

func test_a_pad_stands_at_its_transformers_tile_centre() -> void:
	# Doc 04 stores a transformer as one tile; doc 11 draws every tile-placed
	# prop at that tile's CENTRE, on grade. Same expression as the streetlights
	# and the road slabs — a pad half a tile off would read as being in the road.
	var model := _model()
	model.build_topology([{"id": "T-01", "tile": Vector2i(10, 12), "level": 2}], {}, {})
	assert_eq(model.pad_count(), 1)
	var pad: PowerInfraModel.PadRec = model.pad(0)
	assert_almost_eq(pad.world_pos.x, 10.0 * TILE_M + TILE_M * 0.5, 0.001)
	assert_almost_eq(pad.world_pos.y, 0.0, 0.001, "pads stand on grade")
	assert_almost_eq(pad.world_pos.z, 12.0 * TILE_M + TILE_M * 0.5, 0.001)
	assert_eq(pad.chunk, Vector2i(0, 0), "84,100 is inside the first 128 m chunk")


func test_pads_come_out_in_ascending_id_order_whatever_order_they_arrive_in() -> void:
	# The pad buffer is uploaded in this order and the wire buckets index into
	# it. Two runs that built it differently would upload different buffers from
	# identical state, which is the renderer's half of determinism.
	var model := _model()
	model.build_topology([
		{"id": "T-09", "tile": Vector2i(3, 3), "level": 1},
		{"id": "T-02", "tile": Vector2i(5, 5), "level": 1},
		{"id": "T-11", "tile": Vector2i(7, 7), "level": 1},
	], {}, {})
	assert_eq(model.pad(0).id, "T-02")
	assert_eq(model.pad(1).id, "T-09")
	assert_eq(model.pad(2).id, "T-11")


func test_a_pads_doors_face_the_street() -> void:
	# `yaw_for` turns local +Z (the door face of the mesh) at the road. Four
	# single-road cases, each checked by rotating +Z and reading where it lands.
	var model := _model()
	var cases := {
		Vector2i(5, 4): Vector3(0.0, 0.0, -1.0),   # road to the north
		Vector2i(6, 5): Vector3(1.0, 0.0, 0.0),    # road to the east
		Vector2i(5, 6): Vector3(0.0, 0.0, 1.0),    # road to the south
		Vector2i(4, 5): Vector3(-1.0, 0.0, 0.0),   # road to the west
	}
	for road: Vector2i in cases:
		model.set_road_probe(_roads([road]))
		var yaw := model.yaw_for(Vector2i(5, 5))
		var facing := Basis.from_euler(Vector3(0.0, yaw, 0.0)) * Vector3(0.0, 0.0, 1.0)
		var want: Vector3 = cases[road]
		assert_true(facing.distance_to(want) < 0.001,
				"road at %s ⇒ door faces %s, got %s" % [road, want, facing])


func test_a_corner_pad_resolves_the_same_way_every_time() -> void:
	# Two roads adjacent is the NORMAL case on a grid city, so the tie-break is
	# not an edge case — it is most of them. Fixed priority −Z, +X, +Z, −X.
	var model := _model()
	model.set_road_probe(_roads([Vector2i(5, 4), Vector2i(6, 5)]))
	var north_wins := model.yaw_for(Vector2i(5, 5))
	assert_almost_eq(north_wins, model.yaw_towards(Vector2i(0, -1)), 0.0001,
			"north outranks east")
	model.set_road_probe(_roads([Vector2i(6, 5), Vector2i(5, 6)]))
	assert_almost_eq(model.yaw_for(Vector2i(5, 5)), model.yaw_towards(Vector2i(1, 0)),
			0.0001, "east outranks south")


func test_a_pad_with_no_road_anywhere_near_takes_the_fixed_yaw() -> void:
	# Deterministic, and deliberately NOT a hash of the id: a randomly-spun
	# cabinet in an otherwise aligned row is more conspicuous than an aligned one
	# facing nowhere.
	var model := _model()
	model.set_road_probe(_roads([Vector2i(40, 40)]))
	assert_almost_eq(model.yaw_for(Vector2i(5, 5)), 0.0, 0.0001)
	var no_probe := _model()
	assert_almost_eq(no_probe.yaw_for(Vector2i(5, 5)), 0.0, 0.0001,
			"and so does a model with no road data at all")


func test_a_diagonal_road_still_turns_the_cabinet() -> void:
	var model := _model()
	model.set_road_probe(_roads([Vector2i(6, 4)]))
	assert_almost_eq(model.yaw_for(Vector2i(5, 5)), model.yaw_towards(Vector2i(1, -1)),
			0.0001, "north-east diagonal, since no orthogonal neighbour is road")


# ------------------------------------------------------- service wire spans

func test_a_wire_runs_from_the_cabinet_riser_to_the_buildings_footprint() -> void:
	var model := _model()
	var center := Vector3(200.0, 0.0, 100.0)
	model.build_topology(
			[{"id": "T-01", "tile": Vector2i(10, 12), "level": 2}],
			{"B-1": _building(center, Vector2(16.0, 8.0), 5.50)},
			{"B-1": "T-01"})
	assert_eq(model.spans().size(), 1)
	var span: PowerInfraModel.SpanRec = model.spans()[0]
	var pad: PowerInfraModel.PadRec = model.pad(0)
	assert_true(span.from.distance_to(pad.riser) < 0.0001,
			"the wire leaves the cabinet at its riser, not at the pad's centre")
	assert_true(span.from.y > 1.5,
			"and the riser is above the cabinet, not on the ground")
	# The building spans x ∈ [192, 208], z ∈ [96, 104]; the riser is to the WEST
	# of it, so the drop lands on the west wall, `service_clearance_m` back off
	# it, and level with the RISER in z (not with the pad's centre — the riser is
	# on the cabinet's back face).
	assert_almost_eq(span.to.x, 192.0 - model.service_clearance_m, 0.001,
			"landed on the near wall, clear of it")
	assert_almost_eq(span.to.z, pad.riser.z, 0.001, "and level with the riser")
	assert_almost_eq(span.to.y, 5.50 - 0.90, 0.001,
			"at the building's own eave while that is under the ceiling")


func test_the_service_height_is_clamped_at_both_ends() -> void:
	var model := _model()
	model.build_topology(
			[{"id": "T-01", "tile": Vector2i(10, 12), "level": 2}],
			{
				"TALL": _building(Vector3(200.0, 0.0, 100.0), Vector2(16.0, 16.0), 84.0),
				"SITE": _building(Vector3(200.0, 0.0, 200.0), Vector2(16.0, 16.0), 2.0),
			},
			{"TALL": "T-01", "SITE": "T-01"})
	var by_id: Dictionary = {}
	for span: PowerInfraModel.SpanRec in model.spans():
		by_id[span.building_id] = span
	assert_almost_eq((by_id["TALL"] as PowerInfraModel.SpanRec).to.y,
			model.service_h_max, 0.001,
			"a tower gets a service ENTRANCE, not a wire to the roof")
	assert_almost_eq((by_id["SITE"] as PowerInfraModel.SpanRec).to.y,
			model.service_h_min, 0.001,
			"and a construction site gets a temporary pole")


func test_the_sag_is_proportional_to_the_span_and_capped() -> void:
	var model := _model()
	# 8 m away: sag is the fraction. 120 m away: sag hits the cap.
	model.build_topology(
			[{"id": "T-01", "tile": Vector2i(10, 10), "level": 5}],
			{
				"NEAR": _building(Vector3(84.0 + 20.0, 0.0, 84.0), Vector2(8.0, 8.0), 9.0),
				"FAR": _building(Vector3(84.0 + 200.0, 0.0, 84.0), Vector2(8.0, 8.0), 9.0),
			},
			{"NEAR": "T-01", "FAR": "T-01"})
	for span: PowerInfraModel.SpanRec in model.spans():
		var want := minf(model.sag_max_m, span.length() * model.sag_frac)
		assert_almost_eq(span.sag, want, 0.0001, span.building_id)
	assert_almost_eq(model.spans()[0].sag if model.spans()[0].building_id == "FAR"
			else model.spans()[1].sag, model.sag_max_m, 0.0001,
			"a long run hangs at the cap, not into the street")


func test_a_pads_whole_fan_lives_in_the_pads_chunk() -> void:
	# A wire bucket is gated as a unit. If a fan were split by each wire's own
	# midpoint, walking the camera across a chunk seam would leave half of one
	# transformer's drops hanging in the air.
	var model := _model()
	model.build_topology(
			[{"id": "T-01", "tile": Vector2i(15, 15), "level": 5}],
			{
				"A": _building(Vector3(124.0, 0.0, 124.0)),
				"B": _building(Vector3(180.0, 0.0, 124.0)),   # over the 128 m seam
			},
			{"A": "T-01", "B": "T-01"})
	var pad: PowerInfraModel.PadRec = model.pad(0)
	for span: PowerInfraModel.SpanRec in model.spans():
		assert_eq(span.chunk, pad.chunk, span.building_id)
	assert_eq((model.spans_by_chunk()[pad.chunk] as Array).size(), 2)


func test_an_unserved_building_has_no_wire() -> void:
	# `PowerGrid.attachment_map()` simply does not list it — doc 04 §2.1's
	# UNSERVED is the absence of an attachment, and the absence of a wire is
	# exactly what the player should see.
	var model := _model()
	model.build_topology(
			[{"id": "T-01", "tile": Vector2i(10, 10), "level": 1}],
			{"A": _building(Vector3(84.0, 0.0, 84.0)),
			"ORPHAN": _building(Vector3(600.0, 0.0, 600.0))},
			{"A": "T-01"})
	assert_eq(model.spans().size(), 1)
	assert_eq(model.spans()[0].building_id, "A")


func test_a_wire_to_a_transformer_that_is_gone_is_dropped_not_drawn_to_nowhere() -> void:
	var model := _model()
	model.build_topology(
			[{"id": "T-01", "tile": Vector2i(10, 10), "level": 1}],
			{"A": _building(Vector3(84.0, 0.0, 84.0))},
			{"A": "T-99"})
	assert_eq(model.spans().size(), 0)


func test_two_identical_builds_produce_identical_geometry() -> void:
	# The renderer's half of determinism: same grid ⇒ same buffers, byte for
	# byte, with no dependence on Dictionary insertion order.
	var a := _model()
	var b := _model()
	var transformers := [
		{"id": "T-03", "tile": Vector2i(9, 9), "level": 2},
		{"id": "T-01", "tile": Vector2i(4, 4), "level": 3},
	]
	var buildings := {
		"B-2": _building(Vector3(60.0, 0.0, 40.0)),
		"B-1": _building(Vector3(40.0, 0.0, 60.0)),
		"B-3": _building(Vector3(80.0, 0.0, 80.0)),
	}
	var attachments := {"B-3": "T-03", "B-1": "T-01", "B-2": "T-01"}
	a.build_topology(transformers, buildings, attachments)
	var reversed_transformers: Array = [transformers[1], transformers[0]]
	b.build_topology(reversed_transformers, buildings, attachments)
	assert_eq(a.spans().size(), b.spans().size())
	for i in a.spans().size():
		var sa: PowerInfraModel.SpanRec = a.spans()[i]
		var sb: PowerInfraModel.SpanRec = b.spans()[i]
		assert_eq(sa.building_id, sb.building_id, "span %d" % i)
		assert_eq(sa.from, sb.from, "span %d from" % i)
		assert_eq(sa.to, sb.to, "span %d to" % i)
		assert_eq(sa.sag, sb.sag, "span %d sag" % i)


func test_an_unchanged_grid_does_not_rebuild() -> void:
	# The view polls the topology every few seconds as a safety net (§2.9's
	# adoption re-parents a building without changing any count). On a settled
	# bench city that poll would otherwise free 49 MultiMesh nodes and rewrite
	# 1,500 span transforms for a byte-identical answer.
	var model := _model()
	var transformers := [{"id": "T-01", "tile": Vector2i(10, 10), "level": 2}]
	var buildings := {"B": _building(Vector3(110.0, 0.0, 84.0))}
	assert_true(model.build_topology(transformers, buildings, {"B": "T-01"}),
			"the first build is a build")
	assert_false(model.build_topology(transformers, buildings, {"B": "T-01"}),
			"the identical second one is not")
	# A re-attachment changes no count and IS a rebuild.
	transformers.append({"id": "T-02", "tile": Vector2i(11, 10), "level": 2})
	assert_true(model.build_topology(transformers, buildings, {"B": "T-01"}))
	assert_true(model.build_topology(transformers, buildings, {"B": "T-02"}),
			"an adoption re-parents a building and must reach the wire buffer")
	# …and the mark does not care what order the rows arrive in.
	var reversed_rows: Array = [transformers[1], transformers[0]]
	assert_false(model.build_topology(reversed_rows, buildings, {"B": "T-02"}),
			"the mark describes the grid's SHAPE, not an array's order")


func test_a_rebuild_keeps_the_ramp_state_of_a_pad_that_is_still_there() -> void:
	# Placing one transformer must not re-light the soot on every other pad in
	# the city.
	var model := _model()
	model.build_topology([{"id": "T-01", "tile": Vector2i(10, 10), "level": 1}], {}, {})
	model.apply_state([_row("T-01", "FAILED", false)])
	for _i in 40:
		model.advance(0.1)
	var charred := model.pad_of("T-01").char01
	assert_true(charred > 0.9, "the failed pad went black")
	model.build_topology([
		{"id": "T-01", "tile": Vector2i(10, 10), "level": 1},
		{"id": "T-02", "tile": Vector2i(20, 20), "level": 1},
	], {}, {})
	assert_almost_eq(model.pad_of("T-01").char01, charred, 0.0001,
			"the surviving pad kept its soot across the rebuild")
	assert_almost_eq(model.pad_of("T-02").char01, 0.0, 0.0001,
			"and the new one arrives clean")


# ---------------------------------------------------------- distress mapping

func test_the_distress_bands_are_doc_04s_own_bands() -> void:
	var model := _model()
	assert_almost_eq(model.warn_r, PowerGrid.OVERLAY_WARNING_R, 0.0,
			"WARNING is §5.10's, not a second copy")
	assert_almost_eq(model.critical_r, PowerGrid.OVERLAY_CRITICAL_R, 0.0)
	assert_almost_eq(model.hot_c, float((PowerGrid.HAZARD[&"transformer"] as Array)[0]),
			0.0, "the hot-winding line is §2.6's hazard knee")


func test_the_severe_band_is_solved_from_the_hazard_table_not_picked() -> void:
	# hazard = h_cold + h_hot·stress³ per game-hour; SEVERE is where that
	# reaches 1.0/gh, i.e. odds-on to burn out inside the hour. With the shipped
	# transformer row at 25 °C that is r = 1.399. The point of the test is the
	# INVERSE: feed the ratio back through §2.6's own arithmetic and the hazard
	# has to come out at 1.0.
	var r := PowerInfraModel.severe_ratio()
	assert_almost_eq(r, 1.3988, 0.001, "solved band")
	var thermal: Array = PowerGrid.THERMAL[&"transformer"]
	var hazard: Array = PowerGrid.HAZARD[&"transformer"]
	var theta := float(thermal[0]) * r * r
	var temp := PowerInfraModel.REFERENCE_AMBIENT_C + theta
	var stress := maxf(0.0, (temp - float(hazard[0])) / float(hazard[1]))
	var h := float(hazard[3]) + float(hazard[2]) * pow(stress, 3)
	assert_almost_eq(h, PowerInfraModel.SEVERE_HAZARD_PER_GH, 0.002,
			"the band round-trips through doc 04 §2.6")
	assert_true(r < PowerGrid.XFMR_BURNOUT_R,
			"and it is well under §2.6's hard burnout ceiling")


func test_the_worn_band_is_where_the_condition_multiplier_doubles() -> void:
	# §2.6's `1 + 3(1−c)²`. At c = 0.4226 that is exactly 2.0.
	var c := PowerInfraModel.worn_condition_threshold()
	assert_almost_eq(1.0 + 3.0 * pow(1.0 - c, 2), 2.0, 0.0001)


func test_state_outranks_load_in_every_band() -> void:
	# A burned-out transformer with a stale 1.8 load ratio is CHARRED, not
	# SPARKING; a tripped one is DARK however hot it was a tick ago.
	var model := _model()
	assert_eq(model.distress_for("FAILED", false, 1.80, 0.2, 140.0),
			PowerInfraModel.DISTRESS_FAILED)
	assert_eq(model.distress_for("FAILED", true, 0.0, 1.0, 25.0),
			PowerInfraModel.DISTRESS_FAILED)
	assert_eq(model.distress_for("OPEN", true, 1.80, 1.0, 140.0),
			PowerInfraModel.DISTRESS_DARK)
	assert_eq(model.distress_for("OK", false, 1.80, 1.0, 140.0),
			PowerInfraModel.DISTRESS_DARK,
			"de-energized is dark even while the relay says OK")


func test_the_load_bands_map_onto_the_five_looks() -> void:
	var model := _model()
	assert_eq(model.distress_for("OK", true, 0.40, 1.0, 30.0),
			PowerInfraModel.DISTRESS_CLEAN)
	assert_eq(model.distress_for("OK", true, model.warn_r, 1.0, 30.0),
			PowerInfraModel.DISTRESS_STRESSED, "the WARNING band is inclusive")
	assert_eq(model.distress_for("OK", true, model.critical_r, 1.0, 30.0),
			PowerInfraModel.DISTRESS_TROUBLED, "and so is CRITICAL")
	assert_eq(model.distress_for("OK", true, model.severe_r, 1.0, 30.0),
			PowerInfraModel.DISTRESS_SEVERE)
	assert_eq(model.distress_for("OK", true, model.severe_r - 0.001, 1.0, 30.0),
			PowerInfraModel.DISTRESS_TROUBLED, "one ulp under is still TROUBLED")


func test_a_cold_but_worn_or_hot_transformer_still_reads_stressed() -> void:
	# The tell a player can act on BEFORE the incident fires. Load alone would
	# call both of these healthy.
	var model := _model()
	assert_eq(model.distress_for("OK", true, 0.10, 1.0, model.hot_c),
			PowerInfraModel.DISTRESS_STRESSED, "past §2.6's hazard knee")
	assert_eq(model.distress_for("OK", true, 0.10, model.worn_condition - 0.01, 25.0),
			PowerInfraModel.DISTRESS_STRESSED, "or simply old")


func test_only_the_bad_bands_smoke_and_only_the_worst_sparks() -> void:
	var model := _model()
	model.build_topology([
		{"id": "T-CLEAN", "tile": Vector2i(2, 2), "level": 1},
		{"id": "T-WARM", "tile": Vector2i(4, 2), "level": 1},
		{"id": "T-BAD", "tile": Vector2i(6, 2), "level": 1},
		{"id": "T-BURN", "tile": Vector2i(8, 2), "level": 1},
		{"id": "T-DEAD", "tile": Vector2i(10, 2), "level": 1},
		{"id": "T-DARK", "tile": Vector2i(12, 2), "level": 1},
	], {}, {})
	model.apply_state([
		_row("T-CLEAN", "OK", true, 0.30),
		_row("T-WARM", "OK", true, 0.80),
		_row("T-BAD", "OK", true, 1.10),
		_row("T-BURN", "OK", true, 1.90),
		_row("T-DEAD", "FAILED", false, 0.0),
		_row("T-DARK", "OPEN", false, 0.0),
	])
	var by_pad: Dictionary = {}
	var sparks: Dictionary = {}
	for puff: PowerInfraModel.PuffRec in model.puffs():
		var id := model.pad(puff.pad_index).id
		by_pad[id] = int(by_pad.get(id, 0)) + 1
		if puff.kind == 1:
			sparks[id] = true
	assert_false(by_pad.has("T-CLEAN"), "a healthy transformer does not smoke")
	assert_false(by_pad.has("T-WARM"), "and neither does a merely warm one")
	assert_false(by_pad.has("T-DARK"), "a de-energized one has nothing to burn")
	assert_true(by_pad.has("T-BAD"), "CRITICAL wisps")
	assert_true(by_pad.has("T-BURN"), "SEVERE pours")
	assert_true(by_pad.has("T-DEAD"), "and a burned one keeps a smoulder")
	assert_eq(sparks.keys(), ["T-BURN"], "only SEVERE arcs")


func test_the_puff_cap_is_spent_worst_first() -> void:
	# Forty warm transformers and one on fire: the billboards go to the fire.
	var model := _model()
	model.puff_cap = 8
	var transformers: Array = []
	var rows: Array = []
	for i in 20:
		transformers.append({"id": "T-%02d" % i, "tile": Vector2i(2 + i, 2), "level": 1})
		rows.append(_row("T-%02d" % i, "OK", true, 1.10))
	transformers.append({"id": "T-ZZ", "tile": Vector2i(40, 2), "level": 1})
	rows.append(_row("T-ZZ", "OK", true, 2.00))
	model.build_topology(transformers, {}, {})
	model.apply_state(rows)
	var live := model.puffs()
	assert_eq(live.size(), 8, "the cap holds")
	assert_eq(model.pad(live[0].pad_index).id, "T-ZZ",
			"and the worst transformer in the city got the first billboard")


func test_a_repaired_transformer_visibly_washes_clean() -> void:
	# The player's ask, as a measurement: the fix has to LAND, over seconds, not
	# pop. Fail it, run the char to black, repair it, and watch it come back.
	var model := _model()
	model.build_topology([{"id": "T-01", "tile": Vector2i(10, 10), "level": 1}], {}, {})
	model.apply_state([_row("T-01", "FAILED", false)])
	for _i in 40:
		model.advance(0.1)
	var pad: PowerInfraModel.PadRec = model.pad_of("T-01")
	var charred := pad.char01
	assert_true(charred > 0.9, "burned black")
	assert_true(model.smoke_target_for(pad) > 0.0, "and still smouldering")
	# Doc 06's crew: `PowerGrid.repair_component` returns it at condition 0.85.
	model.apply_state([_row("T-01", "OK", true, 0.30, 0.85, 30.0)])
	assert_almost_eq(pad.char_target, 0.0, 0.0001, "nothing left to be sooty about")
	model.advance(0.1)
	var midway := pad.char01
	assert_true(midway > 0.05 and midway < charred,
			"it fades rather than snapping: %f" % midway)
	# `char_fall_s` is a time constant, so "clean" is a few of them away — 30 s
	# of render time is over twelve, which is what makes the assertion an
	# assertion about the RAMP and not about the tolerance.
	for _i in 300:
		model.advance(0.1)
	assert_almost_eq(pad.char01, 0.0, 0.001, "and ends up clean")
	assert_almost_eq(pad.smoke, 0.0, 0.001)
	assert_eq(model.puffs().size(), 0, "the plume is gone with it")


func test_a_failure_lands_faster_than_a_repair_clears() -> void:
	# Asymmetric on purpose (doc 11's `char_rise_s` / `char_fall_s`): a failure
	# is an event, a repair is a crew leaving.
	var model := _model()
	assert_true(model.char_rise_s < model.char_fall_s)
	model.build_topology([{"id": "T-01", "tile": Vector2i(1, 1), "level": 1}], {}, {})
	model.apply_state([_row("T-01", "FAILED", false)])
	model.advance(0.30)
	var rose := model.pad(0).char01
	model.apply_state([_row("T-01", "OK", true, 0.2, 0.85, 30.0)])
	var before := model.pad(0).char01
	model.advance(0.30)
	var fell := before - model.pad(0).char01
	assert_true(rose > fell, "%f up in 0.3 s against %f down" % [rose, fell])


func test_heat_climbs_with_the_load_and_is_zero_when_the_unit_is_dead() -> void:
	var model := _model()
	model.build_topology([{"id": "T-01", "tile": Vector2i(1, 1), "level": 1}], {}, {})
	var pad: PowerInfraModel.PadRec = model.pad(0)
	model.apply_state([_row("T-01", "OK", true, 0.30)])
	assert_almost_eq(pad.glow_target, 0.0, 0.0001, "nothing below the WARNING band")
	model.apply_state([_row("T-01", "OK", true, model.severe_r)])
	assert_almost_eq(pad.glow_target, 1.0, 0.0001, "full at SEVERE")
	model.apply_state([_row("T-01", "OK", true,
			(model.warn_r + model.severe_r) * 0.5)])
	assert_almost_eq(pad.glow_target, 0.5, 0.001, "linear in between")
	model.apply_state([_row("T-01", "FAILED", false, 1.9)])
	assert_almost_eq(pad.glow_target, 0.0, 0.0001, "a burned unit has no hum left")


# ------------------------------------------------------- the packed channel

func test_the_pad_buffer_packs_the_overlay_at_the_same_stride_the_buildings_use() -> void:
	# `power_pad.gdshader` and `building.gdshader` decode the overlay field with
	# the same expression. If the stride moved here they would disagree about
	# what CRITICAL means on the same tile.
	var model := _model()
	model.build_topology([{"id": "T-01", "tile": Vector2i(1, 1), "level": 1}], {}, {})
	model.apply_state([_row("T-01", "OK", true, 1.10)])
	var packed := model.pad_custom(0, 2).b
	assert_almost_eq(fmod(floor(packed / PowerInfraModel.OVERLAY_STRIDE), 4.0), 2.0,
			0.0001, "overlay state decodes")
	assert_almost_eq(fmod(packed, PowerInfraModel.OVERLAY_STRIDE),
			float(PowerInfraModel.DISTRESS_TROUBLED), 0.0001, "and so does the band")
	assert_true(PowerInfraModel.DISTRESS_COUNT < int(PowerInfraModel.OVERLAY_STRIDE),
			"the low field can never carry into the overlay field")


func test_the_wire_buffer_carries_its_source_pads_state() -> void:
	# A run off a cooking transformer warms along its whole length, and it is the
	# PAD's phase so one fan animates as one thing.
	var model := _model()
	model.build_topology(
			[{"id": "T-01", "tile": Vector2i(10, 10), "level": 2}],
			{"B": _building(Vector3(110.0, 0.0, 84.0))},
			{"B": "T-01"})
	model.apply_state([_row("T-01", "OK", true, 1.90)])
	for _i in 60:
		model.advance(0.1)
	var wire := model.span_custom(0)
	var pad := model.pad_custom(0)
	assert_almost_eq(wire.r, pad.r, 0.0001, "same heat")
	assert_almost_eq(wire.a, pad.a, 0.0001, "same phase")
	assert_almost_eq(wire.b, pad.b, 0.0001, "same packed band")
	assert_almost_eq(wire.g, model.spans()[0].sag, 0.0001,
			"and the sag the vertex stage bends by")


func test_the_animation_phase_is_a_function_of_the_id_alone() -> void:
	# It has to survive a save/load round trip, and an id is the only thing about
	# a transformer that does.
	var a := PowerInfraModel.phase_for("T-042")
	assert_almost_eq(a, PowerInfraModel.phase_for("T-042"), 0.0)
	assert_ne(a, PowerInfraModel.phase_for("T-043"))
	assert_true(a >= 0.0 and a < 1.0)


func test_the_buffers_go_quiet_when_nothing_is_happening() -> void:
	# The pad buffer is city-wide and has no write budget behind it, so a settled
	# grid has to upload NOTHING. Every animation in this layer is a shader
	# function of sc_time; the CPU only writes when a ramp actually moves.
	var model := _model()
	model.build_topology([{"id": "T-01", "tile": Vector2i(1, 1), "level": 1}], {}, {})
	model.apply_state([_row("T-01", "OK", true, 0.30)])
	for _i in 60:
		model.advance(0.1)
	assert_true(model.take_dirty() or true)   # drain whatever the warm-up left
	model.advance(0.1)
	assert_false(model.take_dirty(), "a settled city writes no instance data")


# -------------------------------------------------- against a real PowerGrid

func _grid() -> PowerGrid:
	var grid := PowerGrid.new()
	grid.add_component("plant", &"plant_gas", {"level": 3})
	grid.add_component("sub", &"substation", {"level": 3})
	grid.add_component("f_1", &"feeder", {"conductor_class": 2, "parent": "sub"})
	grid.add_component("t_1", &"transformer",
			{"level": 3, "parent": "f_1", "tile": Vector2i(10, 10)})
	grid.add_component("t_2", &"transformer",
			{"level": 3, "parent": "f_1", "tile": Vector2i(20, 10)})
	return grid


func test_the_grid_hands_back_the_tile_it_stores_and_nothing_it_can_write_through() -> void:
	var grid := _grid()
	assert_eq(grid.component_tile("t_1"), Vector2i(10, 10))
	assert_eq(grid.component_tile("nope"), Vector2i.ZERO, "an unknown id is the origin")
	assert_eq(grid.component_tile("f_1"), Vector2i.ZERO,
			"a line has a route, not a tile")
	# Vector2i is a value type: mutating the returned copy cannot reach the graph.
	var tile := grid.component_tile("t_1")
	tile.x = 999
	assert_eq(grid.component_tile("t_1"), Vector2i(10, 10))


func test_the_attachment_map_is_the_service_graph_in_ascending_order() -> void:
	var grid := _grid()
	grid.attach_building("B-9", Vector2i(10, 11))
	grid.attach_building("B-1", Vector2i(20, 11))
	grid.attach_building("B-5", Vector2i(10, 12))
	var map := grid.attachment_map()
	assert_eq(map.keys(), ["B-1", "B-5", "B-9"], "sorted, so the buffer is stable")
	for building_id: String in map:
		assert_eq(String(map[building_id]), grid.attachment_of(building_id),
				"and agrees with the one-at-a-time query")
	grid.attach_building("B-FAR", Vector2i(90, 90))
	assert_false(grid.attachment_map().has("B-FAR"),
			"UNSERVED is the ABSENCE of a row, not an empty one")


func test_the_whole_layer_builds_off_a_live_grid() -> void:
	var grid := _grid()
	var buildings: Dictionary = {}
	for i in 4:
		var tile := Vector2i(10 + i, 11)
		grid.attach_building("B-%d" % i, tile)
		buildings["B-%d" % i] = _building(
				Vector3(tile.x * TILE_M + 4.0, 0.0, tile.y * TILE_M + 4.0))
	var transformers: Array = []
	for id: String in grid.component_ids_of_kind(&"transformer"):
		transformers.append({"id": id, "tile": grid.component_tile(id),
				"level": int(grid.component(id)["level"])})
	var model := _model()
	model.build_topology(transformers, buildings, grid.attachment_map())
	assert_eq(model.pad_count(), 2)
	assert_eq(model.spans().size(), 4, "one wire per attached building")
	for span: PowerInfraModel.SpanRec in model.spans():
		assert_eq(span.transformer_id, grid.attachment_of(span.building_id),
				"the wire goes where doc 04 says the service goes")
	model.apply_state(grid.transformer_rows())
	assert_eq(model.pad_of("t_1").distress, PowerInfraModel.DISTRESS_DARK,
			"an un-ticked grid has energized nothing yet")


# ------------------------------------------------------------- the view side

func _view() -> PowerInfraView:
	var view := PowerInfraView.new()
	view.setup(_render_data())
	return view


func test_the_pad_mesh_stands_on_grade_and_carries_its_parts_in_colour_alpha() -> void:
	var view := _view()
	var tris := view.pad_triangle_count()
	assert_eq(tris, 204, "the authored cabinet, unchanged")
	var mesh: ArrayMesh = view._pad_mesh
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var lo := 1e9
	var hi := -1e9
	var parts: Dictionary = {}
	for i in verts.size():
		lo = minf(lo, verts[i].y)
		hi = maxf(hi, verts[i].y)
		parts[int(round(cols[i].a * 8.0))] = true
	assert_almost_eq(lo, 0.0, 0.001, "the pad sits ON grade, not in it")
	assert_almost_eq(hi, 1.80, 0.001, "and the bushings reach 1.80 m")
	for part in [PowerInfraView.PART_PAD, PowerInfraView.PART_CABINET,
			PowerInfraView.PART_LID, PowerInfraView.PART_FIN,
			PowerInfraView.PART_BUSHING]:
		assert_true(parts.has(part), "part %d is in the mesh" % part)
	view.free()


func test_part_ids_round_trip_through_an_eight_bit_colour_channel() -> void:
	# `floor(a * 8 + 0.5)` on a value that was written as `part / 8` and stored
	# as 8-bit unorm. Eight parts is the ceiling; a ninth would collide.
	for part in 8:
		var stored := float(int(round(float(part) / 8.0 * 255.0))) / 255.0
		assert_eq(int(floor(stored * 8.0 + 0.5)), part, "part %d" % part)


func test_the_wire_strip_is_one_instance_per_span() -> void:
	var view := _view()
	assert_eq(view.wire_triangle_count(), PowerInfraView.WIRE_SEGMENTS * 2,
			"two triangles per segment, and a whole span is ONE instance")
	view.free()


func test_a_healthy_city_is_one_draw_call_and_a_burning_one_is_two() -> void:
	# §2.13's budget for the whole layer is +10 at Z2. Wires are gated out at
	# that range by construction (see `wire_gate_m`), so what is left is the pad
	# buffer and — only when something is wrong — the distress buffer.
	var view := _view()
	view.apply_topology({
		"transformers": [
			{"id": "T-01", "tile": Vector2i(10, 10), "level": 2},
			{"id": "T-02", "tile": Vector2i(40, 40), "level": 2},
		],
		"buildings": {"B-1": _building(Vector3(110.0, 0.0, 84.0))},
		"attachments": {"B-1": "T-01"},
	})
	# A Z2 camera: 420 m out, so every wire bucket is far outside the gate.
	view.refresh(0.016, Vector3(84.0, 370.0, 84.0 - 200.0))
	assert_eq(view.draw_calls(), 1, "pads only")
	assert_eq(view.visible_wire_bucket_count(), 0, "no wires at Z2")
	view.apply_state([_row("T-01", "OK", true, 1.90), _row("T-02", "OK", true, 0.2)])
	view.refresh(0.016, Vector3(84.0, 370.0, 84.0 - 200.0))
	assert_eq(view.draw_calls(), 2, "pads plus the one distress buffer")
	assert_true(view.live_puff_count() > 0)
	view.apply_state([_row("T-01", "OK", true, 0.20), _row("T-02", "OK", true, 0.2)])
	assert_eq(view.draw_calls(), 1, "and it goes away again when the load does")
	view.free()


func test_a_wire_bucket_is_submitted_only_from_close_up() -> void:
	var view := _view()
	view.apply_topology({
		"transformers": [{"id": "T-01", "tile": Vector2i(10, 10), "level": 2}],
		"buildings": {"B-1": _building(Vector3(110.0, 0.0, 84.0))},
		"attachments": {"B-1": "T-01"},
	})
	assert_eq(view.wire_bucket_count(), 1)
	view.refresh(0.016, Vector3(84.0, 20.0, 84.0))
	assert_eq(view.visible_wire_bucket_count(), 1, "standing on it: drawn")
	view.refresh(0.016, Vector3(84.0 + 600.0, 300.0, 84.0))
	assert_eq(view.visible_wire_bucket_count(), 0, "600 m away: not drawn")
	assert_true(view.wire_gate_m < 150.0,
			"and the gate is inside doc 11 §2.5's NEAR boundary, so 'wires are "
			+ "a NEAR element' holds without mirroring the tier table")
	view.free()


func test_the_governor_only_ever_takes_the_plume() -> void:
	var view := _view()
	view.apply_topology({
		"transformers": [{"id": "T-01", "tile": Vector2i(10, 10), "level": 2}],
		"buildings": {}, "attachments": {},
	})
	view.apply_state([_row("T-01", "OK", true, 1.90)])
	var full := view.live_puff_count()
	assert_true(full > 0)
	view.apply_governor({"particle_ratio": 0.3})
	assert_true(view.live_puff_count() < full, "the plume thins")
	assert_true(view.live_puff_count() > 0, "but does not disappear")
	assert_eq(view.draw_calls(), 2, "and the pad buffer is untouched")
	view.free()


func test_the_wire_aabb_covers_the_sag_the_vertex_stage_adds() -> void:
	# The bucket is culled on this box, and the CPU-side mesh knows nothing
	# about the droop — a box drawn from the endpoints alone would pop the whole
	# fan out of view when the camera looked slightly up.
	var model := _model()
	model.build_topology(
			[{"id": "T-01", "tile": Vector2i(10, 10), "level": 5}],
			{"B": _building(Vector3(84.0 + 200.0, 0.0, 84.0))},
			{"B": "T-01"})
	var span: PowerInfraModel.SpanRec = model.spans()[0]
	var box := model.span_aabb([0])
	assert_true(box.position.y <= minf(span.from.y, span.to.y) - span.sag + 0.001,
			"the box reaches the bottom of the curve")
	assert_true(box.has_point(span.from) and box.has_point(span.to))


# ------------------------------------------------------- the shader contract

func _src(path: String) -> String:
	return FileAccess.get_file_as_string(path)


## The shader with its `//` comments stripped — for the assertions that are
## about what the GPU RUNS. The scars in this layer are documented at length in
## the comments, and a naive `contains()` would trip over the very sentence
## explaining why the thing must not be there.
func _code_of(path: String) -> String:
	var out := ""
	for line in _src(path).split("\n"):
		var text := String(line)
		var comment := text.find("//")
		out += (text.substr(0, comment) if comment >= 0 else text) + "\n"
	return out


func test_every_shader_in_the_layer_reads_the_overlay_global() -> void:
	# The player's ask: the POWER overlay should light up the physical network,
	# not just the building tints. All three surfaces answer to `sc_overlay_mode`
	# and none of them WRITES it — doc 12's rail owns that.
	for path in [PAD_SHADER, WIRE_SHADER, SMOKE_SHADER]:
		var src := _src(path)
		assert_true(src.contains("global uniform int sc_overlay_mode;"),
				"%s reads the mode" % path)
		assert_true(src.contains("const int OVERLAY_MODE_POWER = 1;"),
				"%s knows which mode is POWER" % path)
		assert_false(src.contains("global_shader_parameter_get"),
				"%s never reads a global back (editor-only)" % path)


func test_the_pad_decodes_the_overlay_exactly_as_a_building_does() -> void:
	var pad := _src(PAD_SHADER)
	var building := _src("res://game/shaders/building.gdshader")
	assert_true(building.contains("return mod(floor(packed / 112.0), 4.0);"),
			"the building's decoder is still the 112 stride")
	assert_true(pad.contains("const float OVERLAY_STRIDE = 112.0;")
			and pad.contains("return mod(floor(packed / OVERLAY_STRIDE), 4.0);"),
			"and the pad's is the same expression over the same stride")
	assert_true(pad.contains("if (sc_overlay_mode > 0) {"),
			"one uniform branch guards the whole overlay pass, mode 0 untouched")


func test_the_pad_fetches_its_page_outside_every_branch() -> void:
	# texture() under divergent control flow has undefined derivatives on tiled
	# mobile GPUs. The one fetch is the first statement of fragment().
	var src := _src(PAD_SHADER)
	var body := src.substr(src.find("void fragment()"))
	var fetch := body.find("texture(")
	assert_true(fetch > 0, "there is a page fetch in fragment()")
	assert_eq(body.count("texture("), 1, "and exactly one")
	var first_branch := body.find("if (")
	assert_true(first_branch > fetch,
			"the fetch happens before the first branch in fragment()")


func test_instance_custom_is_flat_in_every_shader_that_unpacks_it() -> void:
	# Interpolating a packed integer walks it by a fraction of an ulp and
	# `mod(floor(p / 112.0), 4.0)` on 111.9999 reads 0 where it should read 1.
	for path in [PAD_SHADER, WIRE_SHADER, SMOKE_SHADER]:
		assert_true(_src(path).contains("varying flat vec4 v_custom;"),
				"%s carries INSTANCE_CUSTOM flat" % path)


func test_the_distress_layer_is_one_pass_for_smoke_and_sparks() -> void:
	var src := _src(SMOKE_SHADER)
	assert_true(src.contains("blend_premul_alpha"),
			"premultiplied alpha is what lets one pass be additive AND blended")
	assert_true(src.contains("sc_time"),
			"the animation is a function of the shader clock, not of a CPU sim")
	# One capped MultiMesh, not a particle node per troubled transformer: a
	# GPUParticles3D each would be one node, one process callback and one draw
	# call EACH on a layer whose whole budget is a couple of calls, and its state
	# would be wall-clock driven, so two runs of the same save would differ.
	assert_false(_src("res://game/render/power_infra_view.gd").contains("GPUParticles"),
			"no particle nodes in this layer")


func test_the_wire_holds_a_minimum_screen_width() -> void:
	var src := _src(WIRE_SHADER)
	assert_true(src.contains("uniform float min_px"))
	assert_true(src.contains("world_vertex_coords"),
			"the sag is a world-space displacement")
	assert_true(src.contains("float wpp = d * world_per_px_at_1m;"),
			"the screen-space term is ONE multiply against a uniform")


func test_the_wire_never_derives_its_width_from_a_vertex_stage_builtin() -> void:
	# A regression lock with a scar behind it. Both `PROJECTION_MATRIX[1][1]` and
	# `VIEWPORT_SIZE.y` COMPILE in a spatial vertex shader and neither carries a
	# usable value there on Forward Mobile: their product measured as zero, took
	# the shader's `max(1.0, …)` guard, and widened every service drop to ~130 m
	# of near-opaque black — the entire screen washed out at any close zoom.
	# `PowerInfraView._sync_viewport_h` computes the term on the CPU instead.
	var code := _code_of(WIRE_SHADER)
	assert_false(code.contains("VIEWPORT_SIZE"),
			"the vertex stage does not read VIEWPORT_SIZE")
	assert_false(code.contains("PROJECTION_MATRIX"),
			"nor PROJECTION_MATRIX")
	var src := _src(WIRE_SHADER)
	assert_true(src.contains("uniform float world_per_px_at_1m"),
			"it is handed 2·tan(fov/2)/height instead")
	assert_true(src.contains("uniform float max_radius_m"),
			"and a hard metre ceiling stands behind that, so a bad uniform can "
			+ "thin the picture but can never repaint it")
	assert_true(_src("res://game/render/power_infra_view.gd").contains(
			"2.0 * tan(deg_to_rad(_fov_deg * 0.5)) / h"),
			"the view computes it from doc 11's own authored FOV")
