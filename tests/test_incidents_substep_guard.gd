extends SimTest
## **The fire-spread sub-step guard** (audit 91 D-15, taken Wave 8) and the
## property that makes it safe to take.
##
## `IncidentSystem._next_discontinuity_h()` used to put a breakpoint on the
## fire-spread grid every 1/12 game-hour whether or not anything was burning,
## and that one breakpoint set the integrator's sub-step count — the largest
## single term in the coarse step (doc 11 §2.13). The guard skips it when the
## live roster holds no `structure_fire`.
##
## The reason a guard is allowed at all is that `_roll_spread` **re-anchors its
## own grid**: it sets `_spread_next_h = now_h + interval` on every run,
## including the runs that find nothing to roll for. So the tests below are not
## about sub-step COUNTS (doc 11 measures those) — they are about the three
## things that would make the count a lie:
##
##   1. a quiet integrator really does stop splitting on the spread grid;
##   2. a fire that ignites does NOT get an extra roll for the quiet hours that
##      preceded it — its first roll is a full `interval` away, exactly as it
##      was before the guard;
##   3. a fire that is already burning still splits every `interval`, so the
##      hazard-rate model doc 06 §2.8 depends on is evaluated on its own grid.

const EPS := 1e-9


func _catalog() -> IncidentCatalog:
	return IncidentCatalog.load_from_files()


## A world with one burnable building and NOTHING else that can produce a
## discontinuity — no fleet events, no weather boundary, no district.
func _quiet_world() -> IncidentTestWorld:
	var world := IncidentTestWorld.new()
	world.add_district("D1", 1000.0, 1.0)
	world.add_building("B1", "house", 1, Vector2i(10, 10), "D1",
			{"fire_load": 20.0, "occupants": 2.0})
	return world


func _system(world: IncidentTestWorld) -> IncidentSystem:
	var system := IncidentSystem.new(_catalog(), world, RngStreams.new(1337))
	system.generation_enabled = false
	return system


func _interval() -> float:
	return _catalog().global_value("spread_roll_interval_h", 1.0 / 12.0)


# ------------------------------------------------- 1. the guard itself

func test_an_empty_roster_does_not_split_on_the_spread_grid() -> void:
	var system := _system(_quiet_world())
	# Nothing is burning, nothing is queued, the fleet is idle: the only
	# breakpoints left are the day/night boundary and the weather boundary, both
	# of which are hours away in this stub.
	var gap := system._next_discontinuity_h()
	assert_true(gap > _interval() + EPS,
			("with no fire live the next discontinuity is %.5f gh; the spread grid "
					+ "would have capped it at %.5f") % [gap, _interval()])


func test_a_live_fire_puts_the_spread_grid_back() -> void:
	var system := _system(_quiet_world())
	system.spawn("structure_fire", "", Vector2i(10, 10),
			{"kind": "building", "id": "B1"}, 1.0)
	var gap := system._next_discontinuity_h()
	assert_true(gap <= _interval() + EPS,
			"a burning city splits on the spread grid: %.5f gh" % gap)


## The predicate is TYPE, not tier and not status: a queued fire nobody has
## answered yet is exactly the fire most likely to spread.
func test_a_queued_fire_counts_as_live() -> void:
	var system := _system(_quiet_world())
	var inc := system.spawn("structure_fire", "", Vector2i(10, 10),
			{"kind": "building", "id": "B1"}, 1.0)
	assert_eq(inc.status, Incident.STATUS_QUEUED, "nobody was dispatched")
	assert_true(system._next_discontinuity_h() <= _interval() + EPS)


## …and a fire that has reached a terminal state does not, because
## `_roll_spread` skips it too. The two predicates have to agree or the guard
## would either skip a live roll or split for a dead one.
func test_a_resolved_fire_stops_holding_the_grid_open() -> void:
	var system := _system(_quiet_world())
	var inc := system.spawn("structure_fire", "", Vector2i(10, 10),
			{"kind": "building", "id": "B1"}, 1.0)
	assert_true(system._next_discontinuity_h() <= _interval() + EPS)
	inc.status = Incident.STATUS_RESOLVED
	assert_true(inc.is_terminal(), "the fixture put it in a terminal state")
	assert_true(system._next_discontinuity_h() > _interval() + EPS,
			"a terminal fire is not a live one")


# --------------------------------- 2. the property that makes it honest

## **The load-bearing test.** A fire ignites after a long quiet stretch during
## which the guard skipped every spread breakpoint. Its first roll must still be
## a full `interval` away — not immediate (which would hand it the whole quiet
## period's worth of hazard) and not late.
func test_a_fire_lit_after_a_quiet_stretch_waits_exactly_one_interval() -> void:
	var system := _system(_quiet_world())
	# Ten game-hours of nothing. With the guard these are a handful of sub-steps
	# rather than 120, and `_roll_spread` re-anchors on each one.
	system.advance_to(10.0)
	assert_true(system._spread_next_h > system.now_h - EPS,
			"the grid rode along with the integrator instead of going stale")
	system.spawn("structure_fire", "", Vector2i(10, 10),
			{"kind": "building", "id": "B1"}, 1.0)
	var gap := system._next_discontinuity_h()
	var expected := system._spread_next_h - system.now_h
	assert_almost_eq(gap, expected, EPS,
			"the first roll is the grid's own next tick")
	assert_true(expected > 0.0 and expected <= _interval() + EPS,
			("a fire lit at %.4f gh waits %.5f gh for its first spread roll; the "
					+ "interval is %.5f") % [system.now_h, expected, _interval()])


## And the grid is a GRID: consecutive rolls are one interval apart once a fire
## is burning, which is what `FireSpread.interval_probability(rate, interval)`
## prices.
func test_consecutive_rolls_are_one_interval_apart() -> void:
	var system := _system(_quiet_world())
	system.spawn("structure_fire", "", Vector2i(10, 10),
			{"kind": "building", "id": "B1"}, 1.0)
	# Short of `fire_burn_down_h` (0.5), so the fire is still live at the end.
	system.advance_to(0.2)
	var first := system._spread_next_h
	system.advance_to(first + EPS * 10.0)
	assert_almost_eq(system._spread_next_h - first, _interval(), 1e-6,
			"the roll re-armed exactly one interval later")


# ------------------------------------ 3. the cost, as an observable

## `substeps_taken` is the number every perf claim about this system has to
## quote (doc 11 §2.13). A quiet 12-game-hour stretch used to cost 144 sub-steps
## on the spread grid alone; it now costs the day/night boundary and nothing
## else. Asserted as a CEILING rather than an equality so a future breakpoint
## added for a good reason fails loudly instead of silently doubling the bill.
func test_a_quiet_half_day_is_a_handful_of_substeps() -> void:
	var system := _system(_quiet_world())
	var before := system.substeps_taken
	for h in 12:
		system.advance_to(float(h + 1))
	var taken := system.substeps_taken - before
	assert_true(taken <= 24,
			("12 quiet game-hours took %d sub-steps; the spread grid alone used to "
					+ "make that 144") % taken)
	assert_true(taken >= 12, "one sub-step per coarse hour is the floor")
