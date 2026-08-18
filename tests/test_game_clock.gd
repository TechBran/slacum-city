extends SimTest
## Doc 01 T-01: calendar derivation.


func test_founding_moment() -> void:
	var clock := GameClock.new()
	assert_eq(clock.tick_index, 0)
	assert_eq(clock.day_index(), 0)
	assert_eq(clock.minute_of_day(), 360, "founded at 06:00")
	assert_eq(clock.hour_of_day(), 6)
	assert_eq(clock.day_of_week(), 0, "day 0 is Monday")
	assert_eq(clock.day_type(), 0)
	assert_eq(clock.season_index(), 0)
	assert_eq(clock.year_index(), 0)
	assert_eq(clock.day_phase(), &"DAWN")


func test_worked_example_918442() -> void:
	# Doc 01 §2.2: tick 918 442 is Saturday 16:50, day 159, summer, year 1.
	var clock := GameClock.new()
	clock.tick_index = 918442
	assert_eq(clock.day_index(), 159)
	assert_eq(clock.minute_of_day(), 1010, "16:50")
	assert_eq(clock.hour_of_day(), 16)
	assert_eq(clock.day_of_week(), 5, "Saturday")
	assert_eq(clock.day_type(), 1, "weekend")
	assert_eq(clock.season_index(), 1, "summer")
	assert_eq(clock.year_index(), 1)
	assert_eq(clock.day_phase(), &"EVENING_RUSH")


func test_day_wrap_5759_5760() -> void:
	var clock := GameClock.new()
	clock.tick_index = 5759
	assert_eq(clock.day_index(), 1, "founding offset pushes the wrap earlier than 24h of ticks")
	assert_eq(clock.minute_of_day(), 359)
	clock.tick_index = 5760
	assert_eq(clock.day_index(), 1)
	assert_eq(clock.minute_of_day(), 360, "exactly 06:00, one full day after founding")
	assert_eq(clock.day_of_week(), 1, "Tuesday")


func test_midnight_wrap_is_night() -> void:
	var clock := GameClock.new()
	# 23:00 on day 0: abs_minutes 1380 -> tick = (1380-360)*4
	clock.tick_index = (1380 - 360) * 4
	assert_eq(clock.hour_of_day(), 23)
	assert_eq(clock.day_phase(), &"NIGHT")
	# 02:00 on day 1: abs_minutes 1440+120
	clock.tick_index = (1440 + 120 - 360) * 4
	assert_eq(clock.hour_of_day(), 2)
	assert_eq(clock.day_phase(), &"NIGHT")


func test_sim_time_minutes_derivation() -> void:
	var clock := GameClock.new()
	clock.tick_index = 918442
	assert_eq(clock.sim_time_minutes(), 918442 / 4)


func test_fine_sample_hour_symmetry() -> void:
	# The 240 per-tick sample points of one hour must average exactly h + 0.5.
	var clock := GameClock.new()
	var total := 0.0
	for q in 240:
		clock.tick_index = q  # hour starting at founding (06:00)
		total += clock.fine_sample_hour()
	assert_almost_eq(total / 240.0, 6.5, 1e-9)


func test_serialize_roundtrip() -> void:
	var clock := GameClock.new()
	clock.tick_index = 918442
	clock.residual_game_ms = 4200
	var restored := GameClock.new()
	restored.deserialize(clock.serialize())
	assert_eq(restored.tick_index, 918442)
	assert_eq(restored.residual_game_ms, 4200)
