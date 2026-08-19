extends SimTest
## `tools/qa_soak.gd` is a measuring instrument, so it is held to the same
## standard as one (doc 93 §E, the treatment `tests/test_playtest_harness.gd`
## gives the balance harness): its arithmetic is asserted, its session schedule
## is asserted against doc 01 §2.9's real-to-game conversion, and the resume
## schedule it plays is asserted against a **live city** — because the soak's
## whole claim is that the numbers it prints are the game's numbers.
##
## The soak run itself is not executed here: two real-hours-equivalent is a
## four-minute job and belongs in a nightly, not in an eight-minute suite. What
## is executed here is every part of it that could be silently wrong.

const QaSoak := preload("res://tools/qa_soak.gd")


func _opts(hours: float, speeds: Array[int], segment_min := 10.0,
		chunk_min := 5) -> Variant:
	var o := QaSoak.Options.new()
	o.hours = hours
	o.speeds = speeds
	o.segment_min = segment_min
	o.chunk_min = chunk_min
	return o


# ===========================================================================
# The session schedule
# ===========================================================================

## Doc 01 §2.9: one real second is sixty game-seconds, so one real second at 1x
## is one game-MINUTE. An hour of play at 1x is therefore 60 game-hours, and the
## soak's headline ("2 real-hours") has to mean that or the report is fiction.
func test_one_real_hour_at_1x_is_sixty_game_hours() -> void:
	var plan := QaSoak.plan_for(_opts(1.0, [1] as Array[int]))
	assert_almost_eq(float(plan["real_seconds"]), 3600.0, 0.001)
	assert_almost_eq(float(plan["game_hours"]), 60.0, 0.001,
			"3600 real seconds at 1x is 3600 game-minutes")
	assert_eq(int(plan["chunks"]), 720, "3600 game-minutes in 5-minute chunks")


func test_mixed_speeds_cycle_per_segment() -> void:
	# Six ten-minute segments over one hour, cycling 1,2,3 twice.
	var plan := QaSoak.plan_for(_opts(1.0, [1, 2, 3] as Array[int]))
	var chunks: Array = plan["chunk_list"]
	assert_eq(int(chunks[0]["speed"]), 1, "the first segment runs at 1x")
	var speeds: Dictionary = {}
	for chunk: Variant in chunks:
		var speed := int((chunk as Dictionary)["speed"])
		speeds[speed] = int(speeds.get(speed, 0)) + 1
	assert_eq(speeds.keys().size(), 3, "all three multipliers were used")
	# 600 real s per segment: 600 game-min at 1x, 1200 at 2x, 1800 at 3x, twice.
	assert_almost_eq(float(plan["game_hours"]), (600.0 + 1200.0 + 1800.0) * 2.0 / 60.0,
			0.001, "a 3x segment covers three times the game time of a 1x one")


func test_every_chunk_is_a_whole_number_of_ticks() -> void:
	var plan := QaSoak.plan_for(_opts(0.5, [1, 3] as Array[int]))
	for chunk: Variant in (plan["chunk_list"] as Array):
		var minutes := int((chunk as Dictionary)["minutes"])
		assert_true(minutes > 0)
		assert_eq(minutes * QaSoak.TICKS_PER_GAME_MINUTE % 1, 0)
		assert_eq(QaSoak.TICKS_PER_GAME_MINUTE, GameClock.TICKS_PER_HOUR / 60,
				"a game-minute is four fine ticks, same as doc 01")


func test_options_parse_every_flag() -> void:
	var o: Variant = QaSoak.Options.parse(PackedStringArray([
		"--hours=3", "--seed=7", "--sim-seed=99", "--speeds=1,4",
		"--segment-min=2", "--chunk-min=10", "--verbs-per-chunk=2.5",
		"--storm-every-h=3", "--saves=4", "--no-pause",
		"--max-object-slope=50", "--max-drift=1.5", "--out=/tmp/x.json", "--quiet"]))
	assert_true(o.errors.is_empty(), "every flag above is real: %s" % str(o.errors))
	assert_almost_eq(o.hours, 3.0, 0.0001)
	assert_eq(o.seed_value, 7)
	assert_eq(o.sim_seed, 99)
	assert_eq(o.speeds, [1, 4] as Array[int])
	assert_eq(o.chunk_min, 10)
	assert_eq(o.saves, 4)
	assert_false(o.pause)
	assert_almost_eq(o.max_drift, 1.5, 0.0001)
	assert_eq(o.out, "/tmp/x.json")
	assert_true(o.quiet)
	var bad: Variant = QaSoak.Options.parse(PackedStringArray(["--nonsense"]))
	assert_eq(bad.errors.size(), 1, "an unknown flag is an error, not a shrug")


# ===========================================================================
# The statistics the report is made of
# ===========================================================================

func test_slope_is_ordinary_least_squares() -> void:
	var xs: Array[float] = [0.0, 1.0, 2.0, 3.0, 4.0]
	var flat: Array[float] = [10.0, 10.0, 10.0, 10.0, 10.0]
	assert_almost_eq(QaSoak._slope(xs, flat), 0.0, 1e-9, "a flat series has no slope")
	var rising: Array[float] = [0.0, 3.0, 6.0, 9.0, 12.0]
	assert_almost_eq(QaSoak._slope(xs, rising), 3.0, 1e-9, "three per unit x")
	var noisy: Array[float] = [1.0, 2.0, 3.0, 4.0, 100.0]
	assert_true(QaSoak._slope(xs, noisy) > 3.0, "and it follows a late jump")
	assert_almost_eq(QaSoak._slope([1.0] as Array[float], [1.0] as Array[float]),
			0.0, 1e-9, "one sample cannot have a slope")
	assert_almost_eq(QaSoak._slope([2.0, 2.0] as Array[float],
			[1.0, 5.0] as Array[float]), 0.0, 1e-9, "nor can a degenerate x")


func test_percentile_and_decile_ratio() -> void:
	var values: Array[float] = []
	for i in 100:
		values.append(float(i))
	assert_almost_eq(QaSoak._percentile(values, 0.0), 0.0, 1e-9)
	assert_almost_eq(QaSoak._percentile(values, 1.0), 99.0, 1e-9)
	assert_almost_eq(QaSoak._percentile(values, 0.95), 94.0, 1.0)
	# The drift gate: last tenth over first tenth.
	assert_almost_eq(QaSoak._decile_mean(values, true), 4.5, 1e-9)
	assert_almost_eq(QaSoak._decile_mean(values, false), 94.5, 1e-9)
	assert_almost_eq(QaSoak._decile_ratio(values), 94.5 / 4.5, 1e-9)
	var steady: Array[float] = []
	for i in 50:
		steady.append(1000.0)
	assert_almost_eq(QaSoak._decile_ratio(steady), 1.0, 1e-9,
			"a run that does not drift reports exactly 1.00x")


func test_money_formatting_groups_and_signs() -> void:
	assert_eq(QaSoak._money(0.0), "$0")
	assert_eq(QaSoak._money(999.0), "$999")
	assert_eq(QaSoak._money(1000.0), "$1,000")
	assert_eq(QaSoak._money(1234567.0), "$1,234,567")
	assert_eq(QaSoak._money(-8510.0), "-$8,510")


# ===========================================================================
# The two things the soak asserts about a live city
# ===========================================================================

## The soak's save cycle claim, on a real mid-session city: capture → JSON →
## restore lands on the same `state_hash`, and both cities then advance
## identically. This is the constitution §5 identity the soak re-checks twice
## per run, asserted here once so a failure inside a four-minute soak is not the
## first anyone hears of it.
func test_save_load_advance_identity_mid_session() -> void:
	var sim := CitySim.boot_from_files(1337)
	sim.advance_hours(7.0)          # deliberately NOT an integer day
	sim.cmd_set_tax_level(mini(3, sim.tax_level_count() - 1))
	sim.advance_hours(1.5)
	sim.bus.drain()
	var before := sim.state_hash()

	var text := JSON.stringify(sim.canonical_capture())
	var restored := CitySim.boot_from_files(1337)
	restored.restore_state(JSON.parse_string(text))
	assert_eq(restored.state_hash(), before, "the reload is bit-identical")

	sim.advance_hours(2.0)
	restored.advance_hours(2.0)
	sim.bus.drain()
	restored.bus.drain()
	assert_eq(restored.state_hash(), sim.state_hash(),
			"and both cities take the next two hours the same way")


## The resume schedule the soak plays, on a live city: `CatchUpPlanner.plan()`
## head-aligns before any coarse hour, so `TickScheduler.advance_coarse_n`'s
## hour-alignment assertion holds no matter what tick the player closed the app
## on. Driven across every misalignment 0..239 would be slow; the four sampled
## here are the boundaries plus two interior offsets, and the loop is the exact
## code a shell resume should run.
func test_planned_resume_advances_a_live_city_from_any_tick() -> void:
	for offset: int in [0, 1, 137, GameClock.TICKS_PER_HOUR - 1]:
		var sim := CitySim.boot_from_files(1337)
		sim.scheduler.advance_fine_n(offset)
		var before_tick := sim.clock.tick_index
		var plan := CatchUpPlanner.plan(45 * 60 * 1000, sim.clock.residual_game_ms,
				sim.clock.tick_index)
		assert_eq(CatchUpPlanner.segments_total_ticks(plan), int(plan["total_ticks"]),
				"the plan's segments sum to its total at offset %d" % offset)
		var seen_coarse := false
		for segment: Variant in (plan["segments"] as Array):
			var row: Dictionary = segment
			var count := int(row["count"])
			if String(row["kind"]) == "coarse":
				seen_coarse = true
				assert_eq(sim.clock.tick_index % GameClock.TICKS_PER_HOUR, 0,
						"a coarse segment starts hour-aligned at offset %d" % offset)
				sim.advance_coarse_hours(count)
			else:
				sim.scheduler.advance_fine_n(count)
		sim.clock.residual_game_ms = int(plan["new_residual_game_ms"])
		assert_true(seen_coarse, "45 minutes away is a coarse catch-up")
		assert_eq(sim.clock.tick_index - before_tick, int(plan["total_ticks"]),
				"the city advanced exactly the planned ticks at offset %d" % offset)
		sim.bus.drain()


## The sanity envelopes the soak checks every chunk are the ones the docs
## guarantee, not numbers invented by the harness.
func test_sanity_envelopes_match_the_shipped_ranges() -> void:
	var sim := CitySim.boot_from_files(1337)
	assert_true(sim.happiness.happiness >= QaSoak.HAPPINESS_RANGE.x
			and sim.happiness.happiness <= QaSoak.HAPPINESS_RANGE.y,
			"doc 09 §3.1's founding happiness sits inside the envelope")
	assert_true(sim.districts.city_stability >= QaSoak.STABILITY_RANGE.x
			and sim.districts.city_stability <= QaSoak.STABILITY_RANGE.y)
	assert_true(float(sim.treasury.balance) > QaSoak.TREASURY_FLOOR
			and float(sim.treasury.balance) < QaSoak.TREASURY_CEIL)
	assert_true(sim.population.city_population >= 0
			and sim.population.city_population < QaSoak.POPULATION_CEIL)
	for id: Variant in sim.buildings.keys():
		var b: Building = sim.buildings[String(id)]
		assert_true(b.condition >= 0.0 and b.condition <= 1.0,
				"%s boots with a legal condition" % String(id))


## The protected roster is real archetypes. A typo here would silently disarm
## the guard that keeps a soak from bulldozing the fire station.
func test_protected_archetypes_exist_in_the_catalog() -> void:
	var sim := CitySim.boot_from_files(1337)
	for archetype: String in QaSoak.PROTECTED_ARCHETYPES:
		assert_true(sim.catalog.has(archetype),
				"%s is a real archetype" % archetype)
