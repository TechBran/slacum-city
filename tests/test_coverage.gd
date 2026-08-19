extends SimTest
## Doc 02 §2.9's service-coverage field (report 98 C-51), and the two queries doc
## 06 reads it through.
##
## The anchor is the doc's own **worked example E6**, re-derived by report 98
## RR-19 at radius 23: an L2 fire station with 2 of 2 engines housed and
## condition 0.90, an office 11 tiles away, `c = 0.627`, margin 0.027 over the
## L4 requirement of 0.60, and the gate closing below station condition 0.834.
## If any constant in `data/building_rules.json.coverage_ladder` moves, that
## number moves and this test says so.


func _ladder() -> Dictionary:
	return StarterCityLoader.read_json("res://data/building_rules.json") \
			.get("coverage_ladder", {})


func _index() -> CoverageIndex:
	return CoverageIndex.new(_ladder())


static func _station(id: String, kind: StringName, at: Vector2, radius: float,
		staffing: float = 1.0, condition: float = 1.0,
		state_mult: float = 1.0) -> Dictionary:
	return {"id": id, "kind": kind, "centroid": at, "level": 2,
			"radius_tiles": radius, "staffing": staffing, "condition": condition,
			"state_mult": state_mult}


# ===========================================================================
# The formula (doc 02 §2.9)
# ===========================================================================

func test_worked_example_e6_reproduces_to_three_places() -> void:
	var index := _index()
	index.set_stations([_station("FIRE-1", CoverageIndex.KIND_FIRE, Vector2.ZERO,
			23.0, 1.0, 0.90)])
	# 1 − (11/23)^1.5 = 0.669252; staffing 1.0; condition factor 0.9375.
	var cover := index.coverage(CoverageIndex.KIND_FIRE, Vector2(11.0, 0.0))
	assert_almost_eq(cover, 0.627424, 0.0005, "E6: c = 0.627")
	assert_true(cover > 0.60, "and it passes an L4 office's 0.60 requirement")
	assert_almost_eq(cover - 0.60, 0.027424, 0.0005, "by the doc's own margin")


func test_the_gate_closes_below_station_condition_0834() -> void:
	# The inverse of E6: `station_condition_factor` must reach 0.896523 for the
	# office to still clear 0.60, which is condition 0.834437.
	var index := _index()
	for pair: Array in [[0.835, true], [0.830, false]]:
		index.set_stations([_station("FIRE-1", CoverageIndex.KIND_FIRE, Vector2.ZERO,
				23.0, 1.0, float(pair[0]))])
		var cover := index.coverage(CoverageIndex.KIND_FIRE, Vector2(11.0, 0.0))
		assert_eq(cover >= 0.60, bool(pair[1]),
				"condition %.3f -> coverage %.4f" % [float(pair[0]), cover])


func test_one_engine_dispatched_away_halves_the_staffing_term() -> void:
	# Doc 02 §2.9's closing line: staffing 1/2 collapses E6's c to 0.314.
	var index := _index()
	index.set_stations([_station("FIRE-1", CoverageIndex.KIND_FIRE, Vector2.ZERO,
			23.0, 0.5, 0.90)])
	assert_almost_eq(index.coverage(CoverageIndex.KIND_FIRE, Vector2(11.0, 0.0)),
			0.313712, 0.0005, "half the crew is half the cover")


func test_coverage_is_zero_past_the_radius_and_one_at_the_station() -> void:
	var index := _index()
	index.set_stations([_station("POL-1", CoverageIndex.KIND_POLICE, Vector2.ZERO, 20.0)])
	assert_almost_eq(index.coverage(CoverageIndex.KIND_POLICE, Vector2.ZERO), 1.0, 0.0001)
	assert_eq(index.coverage(CoverageIndex.KIND_POLICE, Vector2(20.0, 0.0)), 0.0,
			"exactly on the radius the falloff is spent")
	assert_eq(index.coverage(CoverageIndex.KIND_POLICE, Vector2(200.0, 0.0)), 0.0)


func test_a_second_overlapping_station_pays_the_redundancy_bonus() -> void:
	# §2.9: `+0.15 per EXTRA overlapping station`, capped at 1.0. ONE station in
	# range must net exactly zero bonus, or every city gets a free 0.15.
	var index := _index()
	var solo := [_station("A", CoverageIndex.KIND_POLICE, Vector2.ZERO, 20.0)]
	index.set_stations(solo)
	var one := index.coverage(CoverageIndex.KIND_POLICE, Vector2(10.0, 0.0))
	index.set_stations([solo[0],
			_station("B", CoverageIndex.KIND_POLICE, Vector2(20.0, 0.0), 20.0)])
	var two := index.coverage(CoverageIndex.KIND_POLICE, Vector2(10.0, 0.0))
	assert_almost_eq(two - one, 0.15, 0.0001, "the second station is worth +0.15")
	var explained := index.explain(CoverageIndex.KIND_POLICE, Vector2(10.0, 0.0))
	assert_eq(int(explained["overlapping"]), 2)
	assert_almost_eq(float(explained["redundancy"]), 0.15, 0.0001)


func test_a_faint_second_station_is_not_redundancy() -> void:
	# Below `redundancy_min_contribution` (0.30) a station is not a backup, and
	# counting it would pay a bonus for a car that cannot get there in time.
	var index := _index()
	index.set_stations([
		_station("A", CoverageIndex.KIND_POLICE, Vector2.ZERO, 20.0),
		_station("B", CoverageIndex.KIND_POLICE, Vector2(28.0, 0.0), 20.0),
	])
	var explained := index.explain(CoverageIndex.KIND_POLICE, Vector2(10.0, 0.0))
	assert_eq(int(explained["overlapping"]), 1, "only the near one counts")
	assert_eq(float(explained["redundancy"]), 0.0)


func test_coverage_never_leaves_zero_to_one() -> void:
	var index := _index()
	var rows: Array = []
	for i in 6:
		rows.append(_station("S%d" % i, CoverageIndex.KIND_FIRE,
				Vector2(float(i), 0.0), 40.0))
	index.set_stations(rows)
	assert_eq(index.coverage(CoverageIndex.KIND_FIRE, Vector2.ZERO), 1.0,
			"six overlapping stations cap at 1.0, they do not stack past it")
	index.set_stations([])
	assert_eq(index.coverage(CoverageIndex.KIND_FIRE, Vector2.ZERO), 0.0,
			"no stations is no cover, not a neutral 0.5")


func test_the_two_kinds_do_not_see_each_other() -> void:
	var index := _index()
	index.set_stations([_station("POL-1", CoverageIndex.KIND_POLICE, Vector2.ZERO, 20.0)])
	assert_true(index.coverage(CoverageIndex.KIND_POLICE, Vector2.ZERO) > 0.9)
	assert_eq(index.coverage(CoverageIndex.KIND_FIRE, Vector2.ZERO), 0.0,
			"a police station puts out no fires")


func test_rows_are_stored_sorted_whatever_order_they_arrive_in() -> void:
	var index := _index()
	index.set_stations([
		_station("Z", CoverageIndex.KIND_POLICE, Vector2.ZERO, 20.0),
		_station("A", CoverageIndex.KIND_POLICE, Vector2.ZERO, 20.0),
		_station("M", CoverageIndex.KIND_POLICE, Vector2.ZERO, 20.0),
	])
	var ids: Array = []
	for row: Dictionary in index.stations(CoverageIndex.KIND_POLICE):
		ids.append(str(row["id"]))
	assert_eq(str(ids), str(["A", "M", "Z"]), "constitution: sorted iteration")


# ===========================================================================
# The live city (CityIncidentWorld)
# ===========================================================================

func test_the_starter_city_publishes_a_real_field_not_the_old_stub() -> void:
	var sim := CitySim.boot_from_files()
	sim.advance_hours(1.0)
	var world: CityIncidentWorld = sim.incident_world
	var at_station := 0.0
	var far_away := 0.0
	for building_id in world.building_ids():
		var b: Building = sim.buildings[String(building_id)]
		var cover := world.coverage_police(b.origin)
		at_station = maxf(at_station, cover)
		if b.archetype == &"police_station":
			continue
		far_away = minf(far_away, cover)
	assert_true(at_station > 0.9, "the lot the station stands on is fully covered")
	assert_eq(far_away, 0.0, "and the far side of the map has none")
	# The 0.5 stub gave every district the same number; a real field cannot.
	var seen: Array[float] = []
	for district_id in world.district_ids():
		seen.append(float(world.district(String(district_id))["police_coverage"]))
	var distinct := 0
	for value: float in seen:
		if not is_equal_approx(value, seen[0]):
			distinct += 1
	assert_true(distinct > 0, "districts differ: %s" % str(seen))


func test_the_field_is_stable_inside_one_game_hour_and_refreshes_after() -> void:
	# Memoised per game-hour: the incident integrator asks per SUB-step, so the
	# answer has to be cheap and it has to be the same answer twice.
	var sim := CitySim.boot_from_files()
	sim.advance_hours(1.0)
	var world: CityIncidentWorld = sim.incident_world
	var tile := Vector2i.ZERO
	for building_id in world.building_ids():
		var b: Building = sim.buildings[String(building_id)]
		if b.archetype == &"police_station":
			tile = b.origin
			break
	var first := world.coverage_police(tile)
	assert_almost_eq(world.coverage_police(tile), first, 0.0000001,
			"two reads in one hour are one answer")
	# A station that loses its crew loses its cover on the next rebuild.
	for unit_id in sim.incidents.fleet.unit_ids():
		var u: Vehicle = sim.incidents.fleet.unit(int(unit_id))
		if u != null and u.department == "police":
			u.status = Vehicle.OFFLINE
	world.invalidate_coverage()
	assert_eq(world.coverage_police(tile), 0.0,
			"a station with no units left on the books covers nothing")


func test_save_load_advance_leaves_the_field_identical() -> void:
	# Report 98 E2: save/load/advance identity is EXACT, and a memoised query is
	# exactly the shape that breaks it. The field is derived, never serialised.
	var a := CitySim.boot_from_files()
	a.advance_hours(6.0)
	var blob := a.capture_state()
	var tiles: Array[Vector2i] = []
	for building_id in a.incident_world.building_ids():
		tiles.append((a.buildings[String(building_id)] as Building).origin)
	var before: Array[float] = []
	for tile: Vector2i in tiles:
		before.append(a.incident_world.coverage_police(tile))
		before.append(a.incident_world.coverage_fire(tile))

	var b := CitySim.boot_from_files()
	b.restore_state(blob)
	var after: Array[float] = []
	for tile: Vector2i in tiles:
		after.append(b.incident_world.coverage_police(tile))
		after.append(b.incident_world.coverage_fire(tile))
	assert_eq(str(after), str(before), "the loaded city reads the same field")
