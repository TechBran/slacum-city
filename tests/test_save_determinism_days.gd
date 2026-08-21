extends SimTest
## **The determinism gate, widened past the first game-day** (doc 91 A91-D-30,
## report 98 §26 RR-60).
##
## Constitution §5 says the same save plus the same elapsed time must produce the
## same outcome, and until this file every save → load → advance proof in the
## suite took its save inside the first game-day: `tests/test_milestone1.gd` at
## 2 h, `tests/test_save_service.gd` shorter still. The gate was real and the
## window it covered was smaller than a day — so a defect that needed a game-day
## of accumulated float history to become visible sat in the tree from before
## Wave 11 until Wave 13 without a single red test.
##
## What it was: `WaterDemandCache` maintains its three per-zone demand sums
## INCREMENTALLY (`set_demand` backs a building's old contribution out and adds
## the new one) while a restore rebuilds them with one clean forward pass. Same
## number, different float — 1 ULP on `com_base` after 24 game-hours of the
## founding city — and the two cities amplified that ULP apart within one further
## game-hour. Fixed by carrying the sums in the save, which is what
## `RoadNetwork` already does with its smoothed congestion for the same reason.
##
## So this file asserts the property the constitution always claimed, at save
## points a player actually reaches: **a city saved at 2 h, 26 h, 50 h or seven
## game-days, restored and advanced two further game-hours, is bit-identical to
## the city that was never saved.** On the founding city and on the benchmark
## city, because the two have different rosters and different zone counts and the
## defect was invisible on one of them at 26 h.
##
## It is the most expensive file in the suite and it is meant to be: it is the
## only instrument that can see this class of bug, every cheaper framing was
## tried by the reports that missed it, and the thing it guards is the one
## property this project does not trade. It is not, however, allowed to be
## careless with the suite's minutes — see `WEEK_H` for the one place the ageing
## is done on the coarse path, and why that is the truer question anyway.

const BENCH_CITY := "res://tests/fixtures/bench_city.json"

## Save points, in game-hours from founding, reached on the FINE path. 2 h is
## inside the first day — the window the old gate covered — and 26 h and 50 h are
## one and two day boundaries past it, which are the two the defect was first
## reproduced at.
const MILESTONES: Array[int] = [2, 26, 50]

## The benchmark city's list stops at the first day boundary, and the reason is
## honesty about the suite's minutes rather than a hole in the coverage: a fine
## game-hour on 1,500 buildings is ~40× one on the founding city, so 50 h on this
## arm is two minutes of wall clock for an assertion 26 h already makes. What the
## bench arm is FOR is a second city SHAPE — a different roster, a different zone
## count, a different graph — and crossing one day boundary on it is what proves
## the property is not a fact about the founding city's nine blocks.
const BENCH_MILESTONES: Array[int] = [2, 26]

## The fourth save point, and it is reached on the COARSE path on purpose. Seven
## game-days is 40,320 fine ticks and about four minutes of wall clock per city,
## which is not a price a suite should pay for one assertion — and it is not the
## honest shape of the question either. **A player reaches game-day seven by
## closing the app**, and doc 01's offline catch-up credits that on the coarse
## path using the same system code. So the week-old city is aged the way a
## week-old city is actually aged, the save is taken there, and the two-hour
## verification either side of the load runs FINE — which also makes this the
## only test in the tree that crosses the coarse→fine seam across a save.
const WEEK_H: int = 24 * 7

## Game-hours the restored twin and the reference are advanced before comparing.
## One is enough to see it and two is what report 98 RR-52 measured, so two.
const ADVANCE_H: float = 2.0


func _bench_sim(seed_value: int) -> CitySim:
	var sim := CitySim.new()
	sim.boot(seed_value,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(BENCH_CITY),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	return sim


## One reference timeline, four save points on it. The reference is advanced the
## same two game-hours the twin is after each comparison, so the +2 h it spends
## proving one milestone is part of the run that reaches the next — one 170-hour
## advance instead of four independent ones, and the milestones are therefore
## checked against a city with real history rather than four fresh ones.
func _walk(make: Callable, label: String, milestones: Array[int]) -> void:
	var live: CitySim = make.call()
	var now := 0.0
	for target in milestones:
		live.advance_hours(float(target) - now)
		now = float(target)
		var body: Dictionary = live.canonical_capture()
		var twin: CitySim = make.call()
		twin.restore_state(body)
		assert_eq(twin.state_hash(), live.state_hash(),
				"%s: restored at %d h must match at rest" % [label, target])
		live.advance_hours(ADVANCE_H)
		now += ADVANCE_H
		twin.advance_hours(ADVANCE_H)
		assert_eq(twin.state_hash(), live.state_hash(),
				("%s: a save taken at %d game-hours must replay bit-identically "
				+ "%.0f game-hours later (constitution §5)") % [label, target, ADVANCE_H])


func test_the_founding_city_replays_from_a_save_at_any_age() -> void:
	_walk(func() -> CitySim: return CitySim.boot_from_files(8191), "founding/8191",
			MILESTONES)


func test_the_benchmark_city_replays_from_a_save_at_any_age() -> void:
	_walk(func() -> CitySim: return _bench_sim(1337), "bench/1337", BENCH_MILESTONES)


## The week-old save, on both cities. See `WEEK_H` for why the ageing is coarse
## and the verification is fine.
func test_a_week_old_city_replays_from_its_save() -> void:
	var arms: Array = [
		["founding/8191", func() -> CitySim: return CitySim.boot_from_files(8191)],
		["bench/1337", func() -> CitySim: return _bench_sim(1337)],
	]
	for arm in arms:
		var label := String((arm as Array)[0])
		var make: Callable = (arm as Array)[1]
		var live: CitySim = make.call()
		live.advance_coarse_hours(WEEK_H)
		var twin: CitySim = make.call()
		twin.restore_state(live.canonical_capture())
		assert_eq(twin.state_hash(), live.state_hash(),
				"%s: a seven-game-day city restores at rest" % label)
		live.advance_hours(ADVANCE_H)
		twin.advance_hours(ADVANCE_H)
		assert_eq(twin.state_hash(), live.state_hash(),
				("%s: a save taken seven game-days in must replay bit-identically "
				+ "on the fine path (constitution §5)") % label)


## The mechanism, named — so a future reader who breaks it sees WHAT broke rather
## than only that a 256-bit digest moved.
##
## The sums are the one thing in the water section that is a function of the
## city's HISTORY rather than of its current state, which is exactly why they
## have to travel: at 26 game-hours the founding city's `com_base` differs in its
## last bit between a live run and a twin that re-derived it, and one game-hour
## later the two cities have measurably different water delivery.
func test_the_water_zone_sums_survive_the_round_trip_bit_for_bit() -> void:
	var live := CitySim.boot_from_files(8191)
	live.advance_hours(26.0)
	var before: Array = []
	for z: PressureZone in live.water.topology.zones:
		before.append([z.res_base, z.com_base, z.proc_base, z.building_count])
	assert_true(before.size() > 0, "the founding city has pressure zones to compare")
	var twin := CitySim.boot_from_files(8191)
	twin.restore_state(live.canonical_capture())
	var index := 0
	for z: PressureZone in twin.water.topology.zones:
		var was: Array = before[index]
		index += 1
		assert_true(is_same(z.res_base, float(was[0])),
				"zone %d res_base %.17f vs %.17f" % [z.index, z.res_base, float(was[0])])
		assert_true(is_same(z.com_base, float(was[1])),
				"zone %d com_base %.17f vs %.17f" % [z.index, z.com_base, float(was[1])])
		assert_true(is_same(z.proc_base, float(was[2])),
				"zone %d proc_base %.17f vs %.17f" % [z.index, z.proc_base, float(was[2])])
		assert_eq(z.building_count, int(was[3]), "zone %d building_count" % z.index)


## The second thing the week-old bench save turned up, named so a reader sees the
## mechanism: a **pending rebuild is work the city owes**, and a restored city
## that has already spent it stops agreeing about when the next one happens.
func test_a_pending_zone_rebuild_survives_the_round_trip() -> void:
	var live := CitySim.boot_from_files(8191)
	live.advance_hours(2.0)
	live.water.topology_dirty = true
	var twin := CitySim.boot_from_files(8191)
	twin.restore_state(live.canonical_capture())
	assert_true(twin.water.topology_dirty,
			"a rebuild the saved city still owed is still owed after the load")
	assert_eq(twin.state_hash(), live.state_hash(), "and nothing else moved")
	live.advance_hours(1.0)
	twin.advance_hours(1.0)
	assert_eq(twin.state_hash(), live.state_hash(),
			"so both cities re-stamp `last_rebuild_minutes` in the same game-minute")


## Doc 08 §2.8: the rung is ADDITIVE, so a body that predates it still loads, and
## it loads to exactly the city it loaded to before the rung existed — the sums
## get rebuilt, which is what a save that never wrote them down deserves.
func test_a_water_section_without_zone_sums_still_loads() -> void:
	var live := CitySim.boot_from_files(8191)
	live.advance_hours(26.0)
	var body: Dictionary = live.capture_state()
	var water: Dictionary = body["water"]
	assert_eq(int(water["section_version"]), 3, "the writer stamps the current rung")
	var demand: Dictionary = water["demand"]
	assert_true(demand.has("zone_sums"), "a v3 section carries the sums")
	assert_true(water.has("pending"), "and the rebuilds the city owes")
	demand.erase("zone_sums")
	water.erase("pending")
	water["section_version"] = 2
	var twin := CitySim.boot_from_files(8191)
	twin.restore_state(CitySim._encode_floats(body))
	var total := 0.0
	for z: PressureZone in twin.water.topology.zones:
		total += z.res_base + z.com_base + z.proc_base
	assert_true(total > 0.0,
			"a v2 water section restores its zone demand by rebuilding it")
